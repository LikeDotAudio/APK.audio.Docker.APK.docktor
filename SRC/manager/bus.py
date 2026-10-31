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
# THE ROOT IS THE CONTRACTS' (apkaudio_contracts.ROOT, pip-installed into the
# image from contracts/python). A host `--cli` run without the package keeps
# the same literal, so the two cannot disagree while the contract says APK.audio.
try:
    from apkaudio_contracts import ROOT as CONTRACT_ROOT
except Exception:
    CONTRACT_ROOT = "APK.audio"
TOPIC_ROOT   = os.environ.get("TOPIC_ROOT", f"{CONTRACT_ROOT}/System")


def contract_topic(family, fallback, **args):
    """The contracts' spelling of one topic family (apkaudio_contracts.families,
    W01's builders), or `fallback` when the package is absent or older than the
    family. test_bus_identity holds every fallback equal to the contract."""
    try:
        from apkaudio_contracts import families
        return families.topic(family, **args)
    except Exception:
        return fallback
EVENT_TOPIC  = f"{TOPIC_ROOT}/ContainerManager"
STATUS_TOPIC = f"{EVENT_TOPIC}/status"

# THE RETAINED TREE BENEATH THE ROLL-UP. `status` is the whole bench in one
# document; these two are the addresses of the things inside it — the publisher,
# and one branch holding a topic per container and per app. report.py builds the
# leaves; the names live here because this module is where a topic of this
# component is spelled.
MANAGER_TOPIC = f"{EVENT_TOPIC}/Manager"
# THE SHAPE VERSION OF EVERY RETAINED ContainerManager DOCUMENT (status,
# Manager, containers/…, …/apps/…), carried as `doc_version` in each and pinned
# by SRC/manager/schemas/*.schema.json (2026-10-30 audit, DockTor #3/#7).
# Bump it when a field is removed or changes meaning; adding a field is not a
# bump. A reader that sees a number it does not know can say so instead of
# drawing a half-understood card.
DOCUMENT_VERSION = 1
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

# ---------------------------------------------------------------------------
# THE ONE PAHO CONSTRUCTOR (2026-10-30 audit, DockTor #5). The event client
# below, docker_bus.py's request/reply client and the chat line all come from
# here, so every session on this process speaks to BROKER_HOST:BROKER_PORT and
# authenticates by the same rule.
# CREDENTIALS BY PREFIX: `<prefix>_USERNAME` + `<prefix>_PASSWORD`, both set or
# anonymous. The default prefix is the house pair APK_MQTT_* (what
# apkaudio_contracts.broker_auth reads); docker_bus passes APK_DOCKTOR_MQTT, its
# own broker identity, because the operator ACL lets only apkaudio-docktor hear
# ContainerManager/docker/request (DATABUS.Broker.MQTT SRC/acl.local).
# Never from a config file: those are published to the bus retained.
# ---------------------------------------------------------------------------
def credentials(prefix="APK_MQTT"):
    """(username, password) from `<prefix>_USERNAME`/`_PASSWORD`, else None."""
    env = {"APK_MQTT_USERNAME": os.environ.get(f"{prefix}_USERNAME") or "",
           "APK_MQTT_PASSWORD": os.environ.get(f"{prefix}_PASSWORD") or ""}
    try:
        from apkaudio_contracts import broker_auth
        return broker_auth.credentials(env)
    except Exception:
        user, password = env["APK_MQTT_USERNAME"], env["APK_MQTT_PASSWORD"]
        return (user, password) if user.strip() and password else None


def new_client(client_id, prefix="APK_MQTT"):
    """A paho client with credentials applied. Raises ImportError without paho.

    VERSION2 first: the two callback API versions differ only in callback
    signatures, and every callback registered in this package takes *args.
    VERSION1 and the bare constructor remain the fallback for older paho."""
    import paho.mqtt.client as mqtt
    try:
        client = mqtt.Client(client_id=client_id,
                             callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
    except (AttributeError, TypeError, ValueError):
        try:
            client = mqtt.Client(client_id=client_id,
                                 callback_api_version=mqtt.CallbackAPIVersion.VERSION1)
        except AttributeError:
            client = mqtt.Client(client_id=client_id)
    creds = credentials(prefix)
    if creds:
        client.username_pw_set(creds[0], creds[1])
    return client


def publish(topic, payload, retain=False):
    """One message on the event client's broker. True when it went out."""
    with _event_lock:
        client = _event_publisher()
        if client is None:
            return False
        try:
            info = client.publish(topic, payload, retain=retain)
            info.wait_for_publish(timeout=2)
            return True
        except Exception:
            return False


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
        import paho.mqtt.client  # noqa: F401 — no paho, no bus, no error
    except Exception:
        return None
    try:
        with socket.create_connection((BROKER_HOST, BROKER_PORT), timeout=0.4):
            pass
    except Exception:
        return None
    client_id = f"ContainerManager_{SERVER_NAME}_{os.getpid()}"
    try:
        client = new_client(client_id)
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
