#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📡 What each container is PUBLISHING on the data bus. Measured, not declared.
#   ./topics.sh                     every container
#   ./topics.sh Node-BareMetal      one container
#   ./topics.sh --json [container]  the whole census, keyed by container
# TAB rows, no header: CONTAINER TOPIC STATE IDENTITY DETAIL
# STATE is live (delivered inside the window, retain flag CLEAR — traffic now) |
# retained (handed over on subscribe, possibly hours old) | departed (an empty
# retained payload, MQTT only way of withdrawing a topic).
# ⚠️ NO TOPIC LITERAL IN THIS FILE, EVER. Topics are declared in four places
#    already; a fifth copy describing what OTHER programs publish would look
#    authoritative while being wrong. One subscription to `#`, and what arrives
#    is what prints.
# ATTRIBUTION IS BY WHAT THE PAYLOAD SAYS ABOUT ITSELF — MQTT does not carry the
# publisher and no care here can recover it. This ecosystem stamps its publishes:
#     {"source": "APK:BareMetal", …}   {"agent": "…_MQTT_Exchange", …}
#     {"sender": "APK.audio DockTor", …}
# IDENTITY_FIELDS is the key list; the winning key=value is printed as evidence,
# so an empty identity column is a row nobody should trust to a container.
# UNATTRIBUTED TOPICS ARE FILED UNDER THE BROKER, which is true of every topic.
# Dropping them would make a census of 70 print 30 and not say why.
# PUBLISHERS is the only written-down thing here, and every row carries the
# topic where that identity was MEASURED.
# WHAT THIS CANNOT SEE: subscriptions (invisible to another subscriber), and a
# publisher that is quiet during the window with no retained copy. The fix for
# the second is to hold a connection open in the manager, not to lengthen the
# wait.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

MODE=rows
if [ "${1:-}" = "--json" ]; then MODE=json; shift; fi
WANT="${1:-}"

# The broker address, from the one file that holds it. No port here, for the
# same reason api.sh has none.
APK_BROKER_URI="$("$MANAGEMENT_SCRIPTS_DIR/endpoints.sh" Broker-Mosquitto 2>/dev/null \
    | awk -F'\t' '$3 ~ /MQTT broker/ { print $4; exit }')"

APK_RUNNING="$(docker ps --format '{{.Names}}' 2>/dev/null)"

export APK_BROKER_URI APK_RUNNING MODE WANT

python3 - <<'PY'
import json
import os
import sys
import time

MODE = os.environ.get("MODE", "rows")
WANT = os.environ.get("WANT", "")
RUNNING = [n for n in os.environ.get("APK_RUNNING", "").splitlines() if n]
BROKER = os.environ.get("APK_BROKER_URI", "")

# HOW LONG TO LISTEN: long enough for the retained set to be delivered and a
# second-rate publisher to be heard once, short enough that clicking a card is
# not a wait. The retained replay arrives in well under a second here.
SETTLE = float(os.environ.get("APK_TOPICS_SETTLE", "4"))

# Read in order; the first present wins and is printed as the evidence.
IDENTITY_FIELDS = ("source", "agent", "sender", "publisher", "node", "hostname")

# identity string -> (container, where that identity was measured)
# EXACT, or the identity with an UNDERSCORED suffix: APK:BareMetal and
# APK:BareMetal_MQTT_Exchange are one node and two agents, but a bare prefix
# test would also swallow APK:BareMetalSomethingElse.
PUBLISHERS = (
    ("APK:BareMetal", "Node-BareMetal",
     "the `source` field on APK.audio/System/Protocols/*/config, published by "
     "every protocol manager the node supervises"),
    ("APK.audio DockTor", "DockTor",
     "the `sender` field report.py stamps on "
     "APK.audio/System/ContainerManager/status"),
)


def container_for(identity):
    if not identity:
        return None
    for value, container, _measured_at in PUBLISHERS:
        if identity == value or identity.startswith(value + "_"):
            return container
    return None


def identity_of(payload):
    """(field, value) the payload names itself with, or (None, None)."""
    try:
        document = json.loads(payload)
    except Exception:
        return None, None
    if not isinstance(document, dict):
        return None, None
    for field in IDENTITY_FIELDS:
        value = document.get(field)
        if isinstance(value, str) and value.strip():
            return field, value.strip()
    return None, None


def census():
    """Every topic that arrived in the window. {topic: grain}."""
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        return None, ("paho-mqtt is not installed here, so the bus cannot be "
                      "read. It is a best-effort pip in Dockerfile.manager; the "
                      "line above it says why the image still builds without it.")
    if not BROKER:
        return None, "endpoints.sh names no MQTT broker — is the broker up?"

    authority = BROKER.split("://", 1)[-1]
    host, _, port = authority.partition(":")
    grains = {}

    def on_message(_client, _userdata, message):
        payload = message.payload.decode("utf-8", "replace")
        grain = grains.setdefault(message.topic, {
            "topic": message.topic, "messages": 0, "bytes": 0,
            "retained": False, "live": False, "departed": False,
            "payload": "", "identityField": None, "identity": None})
        grain["messages"] += 1
        grain["bytes"] += len(message.payload)
        if message.retain:
            grain["retained"] = True
        else:
            # Flag CLEAR is traffic happening now; the retained replay arrives
            # with it SET, which is why these are two words on the page.
            grain["live"] = True
        grain["departed"] = payload == ""
        if payload:
            grain["payload"] = payload
            field, value = identity_of(payload)
            if value:
                grain["identityField"], grain["identity"] = field, value

    # paho 2.x REQUIRES a callback version and 1.x has no such attribute, so it
    # is asked for and only then passed. VERSION2 because VERSION1 warns on
    # stderr under 2.x, and a caller merging the streams gets a JSON parse error
    # rather than a note. on_message is the same under both.
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    except AttributeError:
        client = mqtt.Client()
    client.on_message = on_message
    try:
        client.connect(host, int(port or 1883), keepalive=10)
    except Exception as err:
        return None, "%s did not answer — %s" % (BROKER, err)
    # `#` DOES NOT INCLUDE $SYS, correctly: the broker own counters are
    # apps.sh work on the same card, and a census of what the ecosystem
    # publishes should not be half full of the broker bookkeeping.
    client.subscribe("#", qos=0)
    client.loop_start()
    time.sleep(SETTLE)
    client.loop_stop()
    try:
        client.disconnect()
    except Exception:
        pass
    return grains, None


grains, error = census()

documents = {}


def document_for(container):
    return documents.setdefault(container, {
        "container": container, "broker": BROKER,
        "observedSeconds": SETTLE, "topics": [], "error": error})


# The broker is the bus: every topic is filed under it, attributed or not.
if "Broker-Mosquitto" in RUNNING:
    document_for("Broker-Mosquitto")

if error:
    for container in RUNNING:
        if container in ("Broker-Mosquitto",) or container in documents:
            document_for(container)
else:
    for topic in sorted(grains):
        grain = grains[topic]
        state = ("departed" if grain["departed"]
                 else "live" if grain["live"] else "retained")
        row = {"topic": topic, "state": state,
               "messages": grain["messages"], "bytes": grain["bytes"],
               "identityField": grain["identityField"],
               "identity": grain["identity"]}
        if "Storage-Broker" in RUNNING:
            document_for("Storage-Broker")["topics"].append(row)
        owner = container_for(grain["identity"])
        if owner and owner in RUNNING:
            document_for(owner)["topics"].append(row)

if WANT:
    documents = {k: v for k, v in documents.items() if k == WANT}

if MODE == "json":
    print(json.dumps(documents, indent=2))
else:
    for container in sorted(documents):
        document = documents[container]
        if document.get("error") and not document["topics"]:
            print("\t".join([container, "—", "absent", "", document["error"]]))
            continue
        if not document["topics"]:
            print("\t".join([container, "—", "absent", "",
                             "nothing on the bus named this container as its "
                             "publisher in %gs" % SETTLE]))
            continue
        for row in document["topics"]:
            evidence = ("%s=%s" % (row["identityField"], row["identity"])
                        if row["identity"] else "")
            print("\t".join([container, row["topic"], row["state"], evidence,
                             "%d message(s) · %d B" % (row["messages"], row["bytes"])]))
PY
