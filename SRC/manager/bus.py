# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""📡 The bus. One client, one topic, one line per thing that happened.

OWNS publishing. Runs no script, reads no docker, imports nothing else in this
package — emit() must never be able to start another emit.
Everything else imports emit() from here, so this module decides the message
shape, and it is BareMetal rust.py shape on purpose: a terminal carrying both
this and the Rust backend reads as one log.
"""

import os
import json
import time
import atexit
import socket
import threading


# ---------------------------------------------------------------------------
# THE BUS. Every discovery, run and send says so ONCE, when it happens.
# Events are NOT retained: an event is a thing that happened, and a late
# subscriber must not be told about it as though it were now. The retained half
# is the STATUS_TOPIC tree below, published only when something CHANGES —
# report.py fingerprints each container STATE, not its meters and not the clock
# in its status string, and sends only what moved.
# emit() publishes on its own client to its own topic and calls nothing else in
# this module.
# ---------------------------------------------------------------------------
# WHERE THE BROKER IS: loopback unless the environment says otherwise, and NOT
# a literal because the manager runs in a container — 127.0.0.1 there is the
# container, so a hard-coded loopback made every broadcast fail QUIETLY with
# ECONNREFUSED against a broker two hops away.
# TWO SPELLINGS ARE READ AND NEITHER IS NEW: MQTT_HOST is what the orchestrator
# compose sets, APK_MQTT_HOST what the heartbeat does. Both, rather than a
# third, preferring the first.
BROKER_HOST = (os.environ.get("MQTT_HOST")
               or os.environ.get("APK_MQTT_HOST") or "127.0.0.1")
BROKER_PORT = int(os.environ.get("MQTT_PORT")
                  or os.environ.get("APK_MQTT_PORT") or 1883)

SERVER_NAME  = os.environ.get("SERVER_NAME", socket.gethostname() or "APKAudioServer")
TOPIC_ROOT   = os.environ.get("TOPIC_ROOT", "APK.audio/System")
EVENT_TOPIC  = f"{TOPIC_ROOT}/ContainerManager"
STATUS_TOPIC = f"{EVENT_TOPIC}/status"

# THE RETAINED TREE BENEATH THE ROLL-UP. `status` is the whole bench in one
# document; these two are the addresses of the things inside it — the publisher,
# and one branch holding a topic per container and per app. report.py builds the
# leaves; the names live here because this module is where a topic of this
# component is spelled.
MANAGER_TOPIC = f"{EVENT_TOPIC}/Manager"
CONTAINERS_TOPIC = f"{EVENT_TOPIC}/containers"

_event_client = None
_event_lock = threading.Lock()

# ---------------------------------------------------------------------------
# SINKS. A second audience for the same event, registered by a caller that has
# one — the HTTP server registers the log stream every browser watches, so an
# event from a --cli verb, a script @EVENT line or the resource sampler reaches
# an open tab without any of them knowing a tab exists.
# A SINK MAY NOT RAISE AND MAY NOT PUBLISH: it is called inside emit(), so an
# exception would lose the event for the broker too and a publish would recurse.
# Enforced here — the call is wrapped, and the sink is handed the finished
# message dict rather than anything it could publish through.
# ---------------------------------------------------------------------------
_sinks = []


def add_sink(sink):
    """Register `sink(message_dict)`, called for every emit() from now on."""
    _sinks.append(sink)
    return sink

def _event_publisher():
    """One long-lived client, built on first use. None when there is no broker.

    connect(), NOT connect_async(): this process is usually SHORT (`--cli
    status` emits four events and exits inside a second), and an async connect
    had not completed by then — every event printed and none reached the
    broker. A blocking connect behind a 0.4s socket probe cannot hang on a dead
    broker and cannot claim a send it did not make.
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
        # VERSION2 first, safe to prefer BECAUSE this client registers no
        # callbacks — the two API versions differ solely in callback
        # signatures, so the choice costs nothing and keeps paho 2.x from
        # printing a deprecation warning over the tool own output. VERSION1
        # and the bare constructor remain the fallback for older paho.
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
        # WHO. `servername` alone is not identity: a GUI and a headless
        # watcher on one machine publish the same name to the same topic, and a
        # reader then sees one series whose interval makes no sense.
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
