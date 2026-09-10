# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
"""📡 The bus. One client, one topic, one line per thing that happened.

WHAT THIS MODULE OWNS. Publishing. It runs no script, reads no docker, and
imports nothing else in this package — emit() must never be able to start
another emit, and a bus that can call the thing it is reporting on is a bus
that can report on itself.

Everything else in the manager imports emit() from here, so this is the module
that decides the message shape, and it is BareMetal's rust.py shape on purpose:
a terminal carrying both this and the Rust backend reads as one log rather than
two conventions.
"""

import os
import json
import time
import atexit
import socket
import threading


# ---------------------------------------------------------------------------
# THE BUS. Every discovery, every run, every send says so ONCE, when it happens.
#
# Message shape is BareMetal's rust.py, and the printed line is byte-for-byte
# its format, so a terminal carrying both this and the Rust backend reads as one
# log rather than two conventions.
#
# Events are NOT retained. An event is a thing that happened; a late subscriber
# must not be told about it as though it were now. The retained half of this
# component is the STATUS_TOPIC tree below, and that half is published only when
# something actually CHANGES -- the whole bench used to go out on every refresh,
# which is how the same payload reached the broker several times a second while
# the bench sat still. The auto-refresh is a publisher again, and the difference
# is that report.py fingerprints each container's STATE -- not its meters and
# not the clock in its status string -- and sends only the ones that moved.
#
# emit() must never be able to start another emit: it publishes on its own
# client, to its own topic, and calls nothing else in this module.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# WHERE THE BROKER IS. Loopback, unless the environment says otherwise.
#
# THE MANAGER RUNS IN A CONTAINER NOW, AND THAT IS WHY THIS IS NOT A LITERAL.
# `127.0.0.1` inside a container is the container, so a hard-coded loopback made
# every broadcast from the containerised manager fail with ECONNREFUSED against
# a broker that was up and two hops away -- and fail QUIETLY, because a bus that
# cannot connect is designed to degrade rather than raise.
#
# TWO SPELLINGS ARE READ AND NEITHER IS NEW. `MQTT_HOST` is what the
# orchestrator's compose sets; `APK_MQTT_HOST` is what the heartbeat's does.
# This module accepts both rather than minting a third, and prefers the first
# because that is the one an operator on this bench has already typed.
BROKER_HOST = (os.environ.get("MQTT_HOST")
               or os.environ.get("APK_MQTT_HOST") or "127.0.0.1")
BROKER_PORT = int(os.environ.get("MQTT_PORT")
                  or os.environ.get("APK_MQTT_PORT") or 1883)

SERVER_NAME  = os.environ.get("SERVER_NAME", socket.gethostname() or "APKAudioServer")
TOPIC_ROOT   = os.environ.get("TOPIC_ROOT", "APK.audio/System")
EVENT_TOPIC  = f"{TOPIC_ROOT}/ContainerManager"
STATUS_TOPIC = f"{EVENT_TOPIC}/status"

# THE RETAINED TREE BENEATH THE ROLL-UP. `status` is the whole bench in one
# document and stays what it was; these two are the addresses of the things
# inside it -- the publisher itself, and one branch holding a topic per
# container and a topic per app running in one. report.py builds the leaves and
# its header says why they exist; the names live here because this module is
# where a topic of this component is spelled, and a second spelling elsewhere is
# how a subscriber ends up watching an address nothing publishes to.
MANAGER_TOPIC = f"{EVENT_TOPIC}/Manager"
CONTAINERS_TOPIC = f"{EVENT_TOPIC}/containers"

_event_client = None
_event_lock = threading.Lock()

# ---------------------------------------------------------------------------
# SINKS. A second audience for the same event, registered by a caller that has
# one -- the HTTP server registers the log stream every browser is watching, so
# an event raised by a `--cli` verb, a script's @EVENT line or the resource
# sampler reaches an open manager tab without any of them knowing a tab exists.
#
# A SINK MAY NOT RAISE AND MAY NOT PUBLISH. It is called inside emit(), so an
# exception from one would lose the event for the broker as well, and a sink
# that emitted would recurse -- the same rule the module header states about
# emit() never being able to start another emit. Both are enforced here rather
# than trusted: the call is wrapped, and the sink is handed the finished
# message dict rather than anything it could publish through.
# ---------------------------------------------------------------------------
_sinks = []


def add_sink(sink):
    """Register `sink(message_dict)`, called for every emit() from now on."""
    _sinks.append(sink)
    return sink

def _event_publisher():
    """One long-lived client, built on first use. None when there is no broker.

    connect(), NOT connect_async(). This process is usually SHORT: `--cli status`
    emits four events and exits inside a second. An async connect had not
    completed by then, so every event printed to the terminal and none of them
    reached the broker -- the worst of both, a tool that reports it published
    and did not. A blocking connect behind a 0.4s socket probe cannot hang the
    GUI on a dead broker, and cannot claim a send it did not make.
    """
    global _event_client
    if _event_client is not None:
        return _event_client
    try:
        import paho.mqtt.client as mqtt
    except Exception:
        return None
    try:
        with socket.create_connection((BROKER_HOST, BROKER_PORT), timeout=0.4):
            pass
    except Exception:
        return None
    client_id = f"ContainerManager_{SERVER_NAME}_{os.getpid()}"
    try:
        # VERSION2 first, and it is safe to prefer here BECAUSE this client
        # registers no callbacks -- it only publishes. The two API versions
        # differ solely in callback signatures, so the choice costs nothing and
        # keeps paho 2.x from printing a deprecation warning over the tool's
        # own output. VERSION1 and then the bare constructor remain the fallback
        # for older paho, which is what is installed on the terminal nodes.
        try:
            client = mqtt.Client(client_id=client_id,
                                 callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
        except (AttributeError, TypeError, ValueError):
            try:
                client = mqtt.Client(client_id=client_id,
                                     callback_api_version=mqtt.CallbackAPIVersion.VERSION1)
            except AttributeError:
                client = mqtt.Client(client_id=client_id)
        client.connect(BROKER_HOST, BROKER_PORT, 60)
        client.loop_start()
        atexit.register(_close_event_publisher)
        _event_client = client
    except Exception:
        _event_client = None
    return _event_client

def _close_event_publisher():
    """Drain and hang up. Without this the last event of a short run is lost."""
    global _event_client
    client, _event_client = _event_client, None
    if client is None:
        return
    try:
        client.loop_stop()
        client.disconnect()
    except Exception:
        pass

def emit(event, details=None):
    """Publish one thing that happened, and print it in the house format."""
    message = {
        "servername": SERVER_NAME,
        # WHO. `servername` alone is not identity: a GUI and a headless watcher
        # on one machine publish the same name to the same topic, and a reader
        # then sees one series whose interval makes no sense -- 42s and 9.6s
        # between samples that are each a minute apart. This is the fault
        # PLAN-296.01 names for the Missions tree; it is not repeated here.
        "pid": os.getpid(),
        "root": TOPIC_ROOT,
        "topic": EVENT_TOPIC,
        "timestamp": time.time(),
        "event": event,
        "details": details or {},
    }
    print(f"\U0001F4E1 [Server: {SERVER_NAME} | Root: {TOPIC_ROOT} | Topic: {EVENT_TOPIC}] "
          f"{event}: {json.dumps(message['details'])}")
    for sink in _sinks:
        try:
            sink(message)
        except Exception:
            pass
    with _event_lock:
        client = _event_publisher()
        if client is None:
            return message
        try:
            info = client.publish(EVENT_TOPIC, json.dumps(message), retain=False)
            info.wait_for_publish(timeout=2)
        except Exception as err:
            print(f"\u26A0\uFE0F MQTT Publish Error: {err}")
    return message
