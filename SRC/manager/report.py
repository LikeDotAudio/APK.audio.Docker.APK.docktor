# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""📋 The bench state, said to every broker. And the wrapper that says it.

OWNS the retained topic tree (the bench in one document, the manager itself, a
topic per container and per app inside one), when a thing has moved enough to
be worth saying again, and run_reported() — one script run with a report either
side of it.
THE AUTO-REFRESH IS THE PRINCIPAL PUBLISHER: api.snapshot() calls
publish_refresh_status() once a scan has poked every device, the only moment
anything here knows the meters and the app plane. Every other caller knows
names and statuses and writes the roll-up alone.
IT CANNOT LIVE IN runner.py: read_containers() reaches docker BY CALLING
run_management_script('ps.sh'), so a report published from inside the runner
would run ps.sh, which would publish a report, which would run ps.sh again.
`say` IS A CALLBACK, NOT A LOG — the caller decides where the sentence goes,
and nowhere is one of the options."""

import os
import re
import sys
import json
import time
import threading

from . import palette
from .paths import BAREMETAL_ROOT
from .bus import (emit, STATUS_TOPIC, MANAGER_TOPIC, CONTAINERS_TOPIC,
                  SERVER_NAME, BROKER_HOST, BROKER_PORT)
from .runner import run_management_script
from .readers import read_containers


def broker_candidates(say=None):
    """(candidates, posture), or None having already said why not.

    THE ORDER IS NOT DECIDED HERE: mqtt_broker_discovery.candidates() is the one
    candidate list in this tree. The window this came from kept a second copy,
    a hard-coded [("127.0.0.1", 1883)], and that is what every broadcast
    actually published to.
    No fallback list, deliberately: BAREMETAL_ROOT degrades QUIETLY, so a stale
    spelling would cost the broker order without ever costing an error message.
    """
    try:
        sys.path.insert(0, os.path.join(BAREMETAL_ROOT, "Baremetal:Manager"))
        import mqtt_broker_discovery
        # `configured` IS THE EXISTING DOOR: candidates() already puts a shop
        # own broker ahead of the loopback and drops it when it IS the loopback,
        # so passing bus.BROKER_HOST through costs no second ordering rule — and
        # it is what makes the containerised manager reach the bench broker.
        configured = ((BROKER_HOST, BROKER_PORT)
                      if (BROKER_HOST, BROKER_PORT) != ("127.0.0.1", 1883) else None)
        # OUR LOOPBACK IS NOT THE BENCH. In a container 127.0.0.1 is the
        # container, where nothing has ever listened on 1883, so the loopback
        # candidate spent one ECONNREFUSED and one warning per report.
        # include_loopback is ignored unless `configured` is set, so a container
        # nobody told where the broker is still fails loudly.
        # PUBLIC FIRST, and this is the only caller in the tree that asks: the
        # audience is the DataBus display PUBLIC pane served from apk.audio,
        # which can reach neither this container nor the bench loopback — and a
        # local broker being DOWN is exactly the state a hosted page most needs
        # told, and the state a local-first list published nothing in.
        # It costs the double opt-in nothing: public_first is inert unless
        # allow_public AND APK_ALLOW_PUBLIC_BROKERS already put a public entry
        # in the list.
        # ⚠️ THE BROKER BRIDGE ALSO CARRIES THIS TOPIC, so a subscriber on
        #    test.mosquitto.org sees the status twice while both are up.
        #    Identical payload, same topic; do not "fix" it by deleting one —
        #    the direct publish works with the bench broker down, the bridge
        #    works before this manager exists.
        found = mqtt_broker_discovery.candidates(
            configured=configured, allow_public=True,
            include_loopback=not os.path.exists("/.dockerenv"),
            public_first=True)

        # ONE PUBLIC BROKER, NOT THREE. The shared list holds three because it
        # is a FALLBACK CHAIN and find_working_broker() stops at the first that
        # answers. This function publishes to EVERY entry, so the spares would
        # be two more strangers receiving this bench container names and host
        # ports with nobody reading. The one with a reader is the head of the
        # list: the PUBLIC pane connects to test.mosquitto.org and nothing else.
        first_public = next((row for row in found
                             if row[0] in {h for h, _, _ in
                                           mqtt_broker_discovery.PUBLIC_MQTT_BROKERS}), None)
        found = [row for row in found
                 if row[0] not in {h for h, _, _ in mqtt_broker_discovery.PUBLIC_MQTT_BROKERS}
                 or row is first_public]

        return (found,
                mqtt_broker_discovery.describe_posture(allow_public=True,
                                                       public_first=True))
    except Exception as err:
        emit("BROKER_DISCOVERY_FAILED", {"error": str(err), "root": BAREMETAL_ROOT})
        if say:
            say(f"⚠️ Broker discovery unavailable — {err}. Nothing broadcast; "
                f"expected mqtt_broker_discovery.py under {BAREMETAL_ROOT}/Baremetal:Manager.")
        return None


# ---------------------------------------------------------------------------
# THE TOPIC TREE:
#   …/ContainerManager/status                    the whole bench, one document
#   …/ContainerManager/Manager                   the publisher itself
#   …/ContainerManager/containers/<Stack>/<Name> one container, in full
#   …/ContainerManager/containers/<Stack>/<Name>/apps/<App>  one app inside it
# NOT ONE DOCUMENT: the roll-up is the right shape for "is the bench up" and the
# wrong one for everything else — a display that cares about Storage-Portal had
# to subscribe to the whole bench and filter, and an app plane going 5/5 -> 4/5
# was a diff inside a blob rather than a message on an address.
# THE STACK IS A LEVEL because the grid already groups by it (palette.group_of),
# so Storage-Portal is containers/Storage/Portal and containers/Storage/#
# watches a stack. A name with no separator is its own stack of one, so the tree
# is the same depth everywhere and a wildcard means one thing.
# A TOPIC THAT LOSES ITS SUBJECT IS TOMBSTONED with a zero-length retained
# publish: retained means the last message outlives its publisher, so a removed
# container would otherwise claim to be up for ever. Kept per-process rather
# than read back off the broker — a container removed while this process was NOT
# running keeps its topic until something removes it by hand.
# ---------------------------------------------------------------------------
_TOPIC_UNSAFE = re.compile(r"[+#/\s\x00]+")


def _segment(text):
    """One topic level. `+`, `#`, `/` and whitespace are the four that break it."""
    return _TOPIC_UNSAFE.sub("_", (text or "").strip()) or "unnamed"


def container_topic(name):
    """`Storage-Portal` -> `…/containers/Storage/Portal`. Stack, then container."""
    return (f"{CONTAINERS_TOPIC}/{_segment(palette.group_of(name))}"
            f"/{_segment(palette.leaf_of(name))}")


def app_topic(container_name, app_name):
    """The address of one app inside one container."""
    return f"{container_topic(container_name)}/apps/{_segment(app_name)}"


# ---------------------------------------------------------------------------
# WHAT A CONTAINER SAYS ABOUT ITSELF: the card the grid draws, minus the three
# fields only a browser can use (emoji, tone, pulse) and INCLUDING the app
# plane, which this topic used to drop — a card reading "APPS · 5/5 running"
# beside a status of only "Up 15 hours" is two readings of one container.
# `None` IS NOT `[]` AND NOT `0`: a report from a path that did not read the app
# plane or the meters carries null, because "nobody asked" and "asked, and there
# are none" are different facts and a subscriber reading a fast cadence silence
# as the second one sees every app having died.
# ---------------------------------------------------------------------------
_RESOURCE_FIELDS = ("cpu_percent", "memory", "memory_percent",
                    "net_io", "block_io", "pids")


def container_document(card):
    """One card as the bus sees it. Takes api.snapshot()'s row, or a thin dict."""
    sample = card.get("resources")
    apps = card.get("apps")
    return {
        "name": card.get("name", ""),
        "status": card.get("status", ""),
        "dead": bool(card.get("dead")) if "dead" in card else None,
        "ours": bool(card.get("ours")) if "ours" in card else None,
        "stack": card.get("group") or palette.group_of(card.get("name", "")),
        "image": card.get("image", ""),
        "network_mode": card.get("network_mode", ""),
        "project": card.get("project", ""),
        "ports": card.get("ports", ""),
        "published": list(card.get("published") or []) if "published" in card else None,
        "resources": ({field: sample.get(field) for field in _RESOURCE_FIELDS}
                      if sample else None),
        "apps": None if apps is None else [
            {"app": app.get("app", ""), "state": app.get("state", ""),
             "detail": app.get("detail", "")} for app in apps],
        "apps_total": None if apps is None else len(apps),
        "apps_running": None if apps is None else
                        sum(1 for app in apps if app.get("state") == "running"),
        # WHETHER THIS IS THE CODE ON DISK. The event beside this is the edge;
        # this is the level, so a subscriber joining an hour after
        # STACK_NEEDS_REBUILD can still learn the container is on the old build.
        # None, not False, when the reader did not run: a retained `false` would
        # state as fact something nobody checked.
        "staleness": ({field: (card.get("staleness") or {}).get(field)
                       for field in ("stale", "behind", "built", "changed", "newest")}
                      if card.get("staleness") else None),
    }


# WHAT COUNTS AS A CHANGE, AND IT IS NOT THE CLOCK. docker ps writes STATUS as
# `Up 41 seconds`, CPU% differs on every sample by definition, and an app detail
# carries `4 clients · up 3 days` — fingerprinting any of those republishes the
# bench several times a minute to say it has not moved. So the fingerprint is
# the STATE: status with its duration struck out, image, network mode, published
# ports, and each app name and state. Meters, durations and details ride in the
# payload and trigger nothing; the heartbeat refreshes them.
_ELAPSED = re.compile(r"\b(?:about\s+|less\s+than\s+)?(?:an?\s+)?\d*\s*"
                      r"(?:second|minute|hour|day|week|month|year)s?\b", re.I)


def _state_of(document):
    """The half of a container document that is allowed to trigger a publish."""
    status = _ELAPSED.sub(" ", document.get("status") or "")
    status = re.sub(r"\bago\b", " ", status, flags=re.I)
    return json.dumps([
        " ".join(status.split()),
        document.get("image"),
        document.get("network_mode"),
        sorted(document.get("published") or []),
        sorted([app.get("app", ""), app.get("state", "")]
               for app in document.get("apps") or []),
        # THE VERDICT, NOT THE MEASUREMENT: `stale` is yes/no/unbuilt, while
        # `behind` grows by a second every second, so fingerprinting it would
        # republish that container on every scan for as long as it stayed stale.
        # built, changed and newest ride in the payload like the meters.
        (document.get("staleness") or {}).get("stale"),
    ], sort_keys=True, default=str)


# ---------------------------------------------------------------------------
# THE REFRESH AS A PUBLISHER, and the gate that makes it safe.
# The auto-refresh already pokes every device once a cadence and then threw the
# answer at one browser. It is the only moment the whole bench is known.
# IT PUBLISHES WHAT MOVED, NOT WHAT IT SAW: each container is fingerprinted on
# its STATE and only the ones that differ from what this process last published
# go out, so a bench sitting still costs one dict comparison per scan.
# AND IT PUBLISHES ANYWAY EVERY REFRESH_HEARTBEAT_SECONDS, because the payload
# carries meters and durations the fingerprint ignores; change alone would leave
# a retained CPU reading from whenever the container last restarted. The floor
# is readers.RESOURCE_SAMPLE_SECONDS, the beat this bench already has.
# ON A BACKGROUND THREAD, because discovery reaches a public broker and a scan
# is on the browser critical path. One at a time: a publish still in flight when
# the next scan lands means the bench is moving faster than the broker can be
# told, and skipping loses nothing — the fingerprint is not recorded until a
# round is actually sent.
# ---------------------------------------------------------------------------
REFRESH_HEARTBEAT_SECONDS = int(os.environ.get("APK_STATUS_HEARTBEAT_SECONDS") or 60)

_PROCESS_STARTED = time.time()
_refresh_lock = threading.Lock()
_refresh = {"states": {}, "topics": {}, "app_topics": {},
            "published_at": 0.0, "scanned_at": 0.0, "interval": None,
            "thread": None}


# ---------------------------------------------------------------------------
# THE BUS HAS TO SAY "REBUILD THIS", AND ONCE.
# A container running code no longer on disk is the one fault here with no
# symptom: up, healthy, meters moving. staleness.sh is the comparison, and this
# is where a card turning stale becomes an event.
# AN EDGE, NOT A LEVEL: staleness is TRUE CONTINUOUSLY from the save until
# somebody rebuilds, often hours, so a per-scan publish would put the same
# "rebuild me" on the broker every cadence all day. The SET of stale containers
# is remembered and only a container that has just JOINED it raises
# STACK_NEEDS_REBUILD.
# THE RECOVERY IS AN EVENT TOO, or a subscriber told to rebuild has to poll to
# find out it took, and the last word on the bus about a healthy container is a
# complaint.
# NOT RETAINED: "this went stale" happened at a time, and a late subscriber must
# not be handed it as though it were now. The retained half is the card.
# ---------------------------------------------------------------------------
_stale_seen = set()
_stale_lock = threading.Lock()


def announce_staleness(cards):
    """Raise STACK_NEEDS_REBUILD for whatever has just gone stale, once each.

    `cards` is api.snapshot() rows carrying read_stale_images() verdicts.
    Returns (newly_stale, recovered).
    A card with no `staleness` key was built by the fast cadence and is IGNORED
    rather than read as current: "no verdict" means "not asked", and reading it
    as "not stale" would announce a recovery every time a rebuild started.
    """
    judged = {card["name"]: card.get("staleness") for card in cards
              if card.get("staleness")}
    if not judged:
        return (), ()
    stale = {name for name, verdict in judged.items()
             if verdict.get("stale") == "yes"}
    with _stale_lock:
        newly_stale = sorted(stale - _stale_seen)
        # ONLY THE ONES THIS SCAN JUDGED may be cleared: a container that
        # vanished mid-rebuild is absent from `judged` and keeps its place, or
        # this raises a recovery for an image nobody rebuilt and then the
        # complaint again when the container comes back.
        recovered = sorted((_stale_seen - stale) & set(judged))
        _stale_seen.difference_update(recovered)
        _stale_seen.update(newly_stale)
    for name in newly_stale:
        verdict = judged[name]
        emit("STACK_NEEDS_REBUILD", {
            "container": name,
            "stack": verdict.get("stack"),
            "image": verdict.get("image"),
            "behind_s": verdict.get("behind"),
            "built": verdict.get("built"),
            "changed": verdict.get("changed"),
            # THE FILE THAT DECIDED IT: "Node-BareMetal is stale" sends a
            # reader to guess; the path is the whole answer, in one field.
            "newest": verdict.get("newest"),
            "say": f"YO — {name} is running code older than the tree. Rebuild it.",
        })
    for name in recovered:
        verdict = judged[name]
        emit("STACK_REBUILT", {"container": name, "stack": verdict.get("stack"),
                               "image": verdict.get("image"),
                               "say": f"{name} is current again."})
    return newly_stale, recovered


def publish_refresh_status(cards):
    """The auto-refresh report, once the scan has finished poking everything.

    `cards` is api.snapshot() rows in grid order. Returns the phase published:
    "refresh" when something moved, "heartbeat" when the floor came round, None
    when nothing changed and it was not time.
    """
    # BEFORE THE CHANGE-GATE, and that ordering is the point: editing a source
    # file moves NO container state, so a staleness check behind the
    # not-moved-and-not-beat return would fire only when something else happened
    # to move at the same moment — and nothing else moving is the case this
    # exists to catch.
    announce_staleness(cards)
    documents = [container_document(card) for card in cards]
    states = {document["name"]: _state_of(document) for document in documents}
    now = time.time()
    with _refresh_lock:
        if _refresh["scanned_at"]:
            _refresh["interval"] = round(now - _refresh["scanned_at"], 3)
        _refresh["scanned_at"] = now
        thread = _refresh["thread"]
        if thread is not None and thread.is_alive():
            return None
        previous = _refresh["states"]
        moved = [d for d in documents if states[d["name"]] != previous.get(d["name"])]
        gone = sorted(set(previous) - set(states))
        beat = (now - _refresh["published_at"]) >= REFRESH_HEARTBEAT_SECONDS
        if not moved and not gone and not beat:
            return None
        phase = "refresh" if (moved or gone) else "heartbeat"
        # A HEARTBEAT REFRESHES EVERYTHING; a change republishes only its own
        # container. Same call, different list.
        sending = documents if phase == "heartbeat" else moved
        _refresh["states"] = states
        _refresh["published_at"] = now
        thread = threading.Thread(target=_publish_refresh, name="ContainerManager-status",
                                  args=(phase, documents, sending, gone), daemon=True)
        _refresh["thread"] = thread
    thread.start()
    return phase


def _publish_refresh(phase, documents, sending, gone):
    """The thread body. Nothing here may raise into the scan that started it."""
    try:
        publish_status_report(phase, containers=documents,
                              per_container=sending, retired=gone, announce=False)
    except Exception as err:                                   # pragma: no cover
        emit("STATUS_PUBLISH_FAILED", {"phase": phase, "error": str(err)})


def manager_document(phase, documents, brokers, sending, retired):
    """What the manager says about ITSELF, on a topic of its own.

    Until this existed the only way to tell a quiet bus from a dead manager was
    that the containers stopped changing — which is also what a working bench
    looks like.
    """
    apps = [app for document in documents for app in (document.get("apps") or [])]
    return {
        "sender": "APK.audio DockTor",
        "servername": SERVER_NAME,
        "pid": os.getpid(),
        "status": "active",
        "phase": phase,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "uptime_s": round(time.time() - _PROCESS_STARTED, 1),
        "topics": {"status": STATUS_TOPIC, "manager": MANAGER_TOPIC,
                   "containers": CONTAINERS_TOPIC},
        "containers": {
            "total": len(documents),
            "dead": sum(1 for d in documents if d.get("dead")),
            "ours": sum(1 for d in documents if d.get("ours")),
        },
        "apps": {"total": len(apps),
                 "running": sum(1 for a in apps if a.get("state") == "running")},
        # THE CADENCE IS OBSERVED, NOT DECLARED: the dropdown that sets it is
        # in a browser and there may be several. What this process can honestly
        # report is how long it has been between the last two scans.
        "scan_interval_s": _refresh["interval"],
        "heartbeat_s": REFRESH_HEARTBEAT_SECONDS,
        "brokers": [f"{b[0]}:{b[1]}" for b in brokers],
        "published": {"containers": len(sending),
                      "apps": sum(len(d.get("apps") or []) for d in sending),
                      "retired": len(retired)},
    }


def publish_status_report(phase, query=None, response=None, say=None, announce=True,
                          containers=None, per_container=None, retired=()):
    """Publish the inventory, and what was asked of it, to every broker.

    `phase` is "manual", "before", "after", "refresh" or "heartbeat"; `query`
    the command about to run or just run; `response` its exit code. Both ride in
    the SAME retained payload as the inventory, so a late subscriber gets the
    state and the command that produced it together.
    `containers` IS THE SCAN THAT ALREADY HAPPENED: a caller holding
    api.snapshot() rows passes the documents and no script runs here. That is
    the auto-refresh path, and the only one whose payload can carry the meters
    and the app plane. Without it the inventory is read here QUIETLY, because a
    loud read would announce SCRIPT_START and SCRIPT_RESULT for the ps.sh behind
    every report.
    `per_container` IS WHAT GETS ITS OWN TOPIC and is empty by default: an
    action before/after report knows names and statuses only, so publishing it
    per-container would blank the meters and the app plane on every container
    topic. The leaves are only written by a caller that measured them.
    """
    found = broker_candidates(say=say)
    if found is None:
        return None
    candidate_brokers, posture = found
    if announce and say:
        say(f"\U0001f4cb Broker order: {posture}")
    emit("BROKERS_DISCOVERED", {"count": len(candidate_brokers),
                                "brokers": [f"{b[0]}:{b[1]}" for b in candidate_brokers]})

    containers_info = containers
    if containers_info is None:
        containers_info = []
        try:
            for container in read_containers(quiet=True)[0]:
                containers_info.append(container_document(container))
        except Exception:
            pass

    payload_dict = {
        "sender": "APK.audio DockTor",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "status": "active",
        "phase": phase,
        "total_containers": len(containers_info),
        "containers": containers_info,
    }
    if query is not None:
        payload_dict["query"] = query
    if response is not None:
        payload_dict["response"] = response

    sending = list(per_container or [])
    # ONE CONNECTION, EVERY TOPIC: publish.multiple() opens the socket once. A
    # publish.single() per leaf is a connect and disconnect per app.
    messages = [(STATUS_TOPIC, json.dumps(payload_dict, indent=2)),
                (MANAGER_TOPIC, json.dumps(
                    manager_document(phase, containers_info, candidate_brokers,
                                     sending, retired), indent=2))]
    published_apps = 0
    for document in sending:
        name = document["name"]
        topic = container_topic(name)
        messages.append((topic, json.dumps(document, indent=2)))
        live_apps = set()
        for app in document.get("apps") or []:
            leaf = app_topic(name, app.get("app", ""))
            live_apps.add(leaf)
            messages.append((leaf, json.dumps(
                {"container": name, "stack": document.get("stack"),
                 "app": app.get("app", ""), "state": app.get("state", ""),
                 "detail": app.get("detail", ""),
                 "timestamp": payload_dict["timestamp"]}, indent=2)))
            published_apps += 1
        # An app that left this container plane — switched off in the roster or
        # removed from it — loses its topic here rather than at the next
        # container-level tombstone, which never comes while the container is
        # fine.
        for stale in sorted(_refresh["app_topics"].get(name, set()) - live_apps):
            messages.append((stale, ""))
        if document.get("apps") is not None:
            _refresh["app_topics"][name] = live_apps
        _refresh["topics"][name] = topic
    for name in retired:
        messages.append((_refresh["topics"].pop(name, container_topic(name)), ""))
        for stale in sorted(_refresh["app_topics"].pop(name, set())):
            messages.append((stale, ""))

    # WHICH HOSTS ARE NOT OURS, asked of the shared list rather than matched on
    # a name here, so a public broker is still named in exactly one place.
    public_hosts = set()
    try:
        import mqtt_broker_discovery
        public_hosts = {row[0] for row in mqtt_broker_discovery.PUBLIC_MQTT_BROKERS}
    except Exception:
        pass

    reached = []
    for broker in candidate_brokers:
        host, port = broker[0], broker[1]
        desc = broker[2] if len(broker) > 2 else host
        # RETAINED ON OUR OWN BROKERS, NEVER ON A STRANGER — the same split the
        # broker bridge makes with bridge_outgoing_retain false. A retained
        # publish outlives the process that wrote it: 11 topics of this bench
        # were read back off test.mosquitto.org with no publisher connected,
        # five still claiming "active": true from tabs closed the day before,
        # and clearing them is a write to somebody else machine that does not
        # undo the disclosure. This payload carries container names and host
        # ports. The cost is seconds of blank on the PUBLIC pane.
        retain = host not in public_hosts
        # A TOMBSTONE IS ONLY MEANINGFUL WHERE WE RETAIN: on a stranger broker
        # nothing was retained, so a zero-length message is not a delete — it is
        # a live subscriber handed an empty document.
        outgoing = [row for row in messages if retain or row[1]]
        try:
            import paho.mqtt.publish as publish
            # RETAINED ON OUR BROKERS, the pair to publishing only on change:
            # the inventory goes out when it MOVES, and without the retain flag
            # a subscriber joining between two changes learns nothing until the
            # next one, which may be hours. State is retained; events are not.
            publish.multiple([{"topic": topic, "payload": body,
                               "qos": 0, "retain": retain}
                              for topic, body in outgoing],
                             hostname=host, port=port, keepalive=3)
            emit("STATUS_PUBLISHED", {"broker": f"{host}:{port}", "description": desc,
                                      "topic": STATUS_TOPIC, "phase": phase,
                                      "retained": retain,
                                      "topics": len(outgoing),
                                      "per_container": len(sending),
                                      "apps": published_apps,
                                      "retired": len(retired),
                                      # `containers_total`, spelled the way the
                                      # retained document spells it: the
                                      # RESOURCES beat beside it counts only
                                      # what is RUNNING, so two names and two
                                      # quantities let a subscriber tell a
                                      # stopped one-shot from a lost row.
                                      "containers_total": len(containers_info)})
            reached.append(f"{host}:{port}")
            if announce and say:
                say(f"\U0001f4e1 Broadcasted status to MQTT broker {desc} ({host}:{port}) "
                    f"on topic '{STATUS_TOPIC}' — {len(outgoing)} topics, "
                    f"{len(sending)} container(s), {published_apps} app(s)")
        except Exception as err:
            emit("STATUS_PUBLISH_FAILED", {"broker": f"{host}:{port}", "error": str(err)})
            if say:
                say(f"⚠️ Failed to reach MQTT server {host}:{port} — {err}")
    return {"topic": STATUS_TOPIC, "phase": phase, "posture": posture,
            "brokers": [f"{b[0]}:{b[1]}" for b in candidate_brokers],
            "published_to": reached, "containers": len(containers_info),
            "topics": len(messages), "per_container": len(sending),
            "apps": published_apps, "retired": len(retired)}


def run_reported(name, args=(), on_line_callback=None):
    """run_management_script, with a status report either side of it.

    THE WRAPPER IS THE ONE CALL: the action surface keeps one
    run_management_script per action and no branch, so the two reports live in
    the single place every action already goes through rather than at eight call
    sites that would drift.
    NEITHER REPORT WRITES A PER-CONTAINER TOPIC — both read ps.sh and nothing
    else, and the app plane in particular must not be read here because apps.sh
    curls a supervisor an action is restarting. The scan that follows carries
    the leaves.
    """
    query = {"script": name, "argv": [name, *args]}
    publish_status_report("before", query=query, announce=False)
    started = time.time()
    # cancellable=True IS WHAT MAKES 🛑 REACHABLE: this wrapper is the action
    # path and its only caller, so registering here registers exactly the runs a
    # stop may tear down and none of the screen own reads.
    exit_code, output = run_management_script(name, args, cancellable=True,
                                              on_line_callback=on_line_callback)
    response = {"exit_code": exit_code,
                "ok": exit_code == 0,
                "duration_s": round(time.time() - started, 3)}
    publish_status_report("after", query=query, response=response, announce=False)
    return exit_code, output
