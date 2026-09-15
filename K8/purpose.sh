#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📘 What each container IS, and why the bench needs it. The one copy.
#   ./purpose.sh                     every container
#   ./purpose.sh Broker-SqlCapture   one container
#   ./purpose.sh --json [container]  the same document, keyed by container
#   ./purpose.sh --check             every declared container has an entry
# WHY THIS IS WRITTEN DOWN WHEN api.sh REFUSES TO BE: a reason is not a
# measurement. No probe can emit "this is the delta capture, and without it the
# bus keeps only the latest value of every topic and none of the history".
# THE HAZARD IS DRIFT, AND --check IS THE ANSWER: it walks every compose file
# under APK:DOCKERS/, takes every container_name:, and fails on an entry with no
# container or a container with no entry. No daemon needed, so
# ./.apk.scripts/check.sh container-purpose runs it on any checkout.
# It walks compose files rather than docker ps: the set that matters is what
# this repository SHIPS, so a stranger container cannot redden the gate and a
# stack that is down cannot make its entry look spare.
# WRITING AN ENTRY: one line per field (tabs slice the row, so an embedded tab
# or newline is a corrupted row and the python below refuses it).
# Field 4 is a REASON, not a restatement — say what stops working, or what could
# not be known, without this container.
# Field 3 is what it IS, not what it is doing now: state, health, ports and
# restart counts are the measured rest of that pane.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

MODE=rows
case "${1:-}" in
    --json)  MODE=json;  shift ;;
    --check) MODE=check; shift ;;
esac
WANT="${1:-}"

export MODE WANT DOCKERS_DIR

python3 - <<'PY'
import json
import os
import re
import sys

MODE = os.environ.get("MODE", "rows")
WANT = os.environ.get("WANT", "")
DOCKERS_DIR = os.environ.get("DOCKERS_DIR", "")

# THE TABLE: container -> (role, what it is, why it is needed).
# Ordered by stack, the way the compose files are.
PURPOSE = {

    # --- Server:Storage:SQL database -- the core stack -------------------------
    "Storage-Broker": (
        "The house MQTT bus",
        "A mosquitto 2.0 broker built from Dockerfile.broker with its config COPYed in "
        "rather than bind-mounted, so it carries its own settings through a reboot with "
        "no host path to go missing. It serves native MQTT on 1883 and MQTT over "
        "WebSockets on 9001 -- the second one is what lets a browser tab be a client.",
        "This is the bus every other process on the bench actually speaks on: the "
        "manager's MQTT_HOST names it, the front ends subscribe over 9001, and the "
        "delta capture records it. Three mosquittos run here and only this one keeps "
        "1883/9001, so an address is also an answer to which broker it reached. The bus "
        "is not a passive transport -- a VISA Write topic executes SCPI on real "
        "hardware -- which is why its open config and a narrow bind are a pair."),

    "Storage-MariaDB": (
        "The SQL database of record",
        "MariaDB 11.4 holding the `apkaudio` database on the pinned `mariadb-data` "
        "volume: the Scanalyzer corpus tables and the bus_delta history live in it. Its "
        "healthcheck asks --innodb_initialized rather than the port, because a server "
        "still replaying InnoDB logs is listening and not yet usable.",
        "It is the only durable store on the bench. The corpus endpoints the portal "
        "serves read from it and the delta capture writes to it, so a bench without it "
        "has a Scanalyze tab that reports offline and a bus whose history goes "
        "nowhere."),

    "Storage-PHP": (
        "The interpreter behind /api/*",
        "php-fpm on 9000, published to nothing: it is reachable only from the compose "
        "network, and nginx fastcgi_passes the named endpoints to it. It reaches the "
        "database as `mariadb` by service name, and its code is COPYed into the image, "
        "so editing an endpoint needs `up -d --build` and never a bare restart.",
        "The portal beside it is nginx over static trees and cannot execute anything. "
        "Without this tier nginx returned the PHP SOURCE of the corpus endpoints, the "
        "front end's JSON.parse threw on it, and the Scanalyze tab reported the "
        "database offline while the database was healthy two containers away."),

    "Storage-Schema-Init": (
        "The schema, applied on every up. Runs once and exits",
        "A one-shot that runs the tracked .sql schemas through the PHP image that "
        "already carries them. Every statement is CREATE TABLE IF NOT EXISTS, so it is "
        "a no-op against a live corpus and a full provision against an empty one. Its "
        "restart policy is `no` because a one-shot that has finished has exited -- an "
        "Exited (0) here is the success state and not a stopped service.",
        "It is the only thing on the `up` path that provisions the shared database, "
        "including schemas it did not author: Broker-SqlCapture exits 1 while its "
        "`bus_type` table is missing. That schema used to be hand-applied, and every "
        "`down -v` threw it away and left the capture restart-looping forever against a "
        "database that could never satisfy it. A new table belongs in this service, "
        "never in a `docker exec` that cannot survive a volume recreation."),

    "Storage-Portal": (
        "The web shell on 8080 -- the front door",
        "nginx serving the built front end: the shell, the widget engine and the apps "
        "its windows open, with /api/* routed through to Storage-PHP. The tree it "
        "serves is a photograph taken at build time, so a page edit reaches it on "
        "`up -d --build` and not on a restart.",
        "It is the address a person is given for this ecosystem, and the one the deploy "
        "to apk.audio mirrors. Everything else on the bench is something this page "
        "talks to."),

    # --- Server:Broker:MQTT -- the bus stack -----------------------------------
    "Broker-Mosquitto": (
        "The bus stack's own broker, on 1884/9002",
        "A second mosquitto 2.0, mounting its config read-only from the folder every "
        "broker config in this repository lives in. It listens on 1883/9001 inside the "
        "container like the others; only the host side is renumbered, so all three "
        "brokers can run at once.",
        "It is the broker you bring up when the bus itself is the thing being worked "
        "on -- one you can reconfigure, restart and break without touching the one the "
        "whole bench is talking on. It is not a second house bus: nothing defaults to "
        "it."),

    "Broker-SqlCapture": (
        "The delta capture -- the bus, written down",
        "A Rust agent that subscribes to the bus and writes a row every time a topic's "
        "value CHANGED, carrying what it changed from. It is the DeltaEngine that used "
        "to run only in-process inside the orchestrator, now a container of its own "
        "beside the broker. `--host mqtt` is passed rather than defaulted, and it "
        "points at the bus that carries the bench's traffic rather than at this stack's "
        "own quiet broker.",
        "MQTT retains only the latest value of a topic; this is the only thing on the "
        "bench that keeps the history, and the SQL behind every question of the form "
        "'when did that change, and what was it before'. Pointed at the wrong broker it "
        "fails silently and calmly -- the name resolves, the healthcheck is green, and "
        "`observed 0` is indistinguishable from a quiet bench."),

    # --- APK:audio:WebPortal ---------------------------------------------------
    "Portal-Broker": (
        "The portal stack's broker, on 1885/9003",
        "The third mosquitto. It mounts the CONTAINER variant of the broker config -- "
        "the one that binds every interface with anonymous access -- which is why both "
        "of its published ports carry a 127.0.0.1 prefix. Services in its own stack "
        "reach it as `broker:1883` on the compose network.",
        "The WebPortal stack is a broker and a heartbeat, and this is the broker half: "
        "it is what the heartbeat beside it publishes to when this stack is brought up "
        "on its own."),

    "Portal-Heartbeat": (
        "The metronome of the bench",
        "The Missions Heartbeat timer, running as its own container from the portal "
        "image with no ports at all -- it only ever speaks to the broker. Which tiers it "
        "actually beats is decided by the retained switches under .../Heartbeat/Enable/, "
        "written by the Missions panel, so it is started once and then left alone.",
        "It is a separate service rather than a thread inside the orchestrator because "
        "the orchestrator restarts whenever a panel rebuild goes wrong, and a clock that "
        "stops when something unrelated stops is not a clock."),

    # --- APK:BareMetal -- the terminal machine ---------------------------------
    "Node-BareMetal": (
        "The terminal machine itself -- one container per bench",
        "The supervised node: the agent supervisor on 8100, the orchestrator that "
        "answers 8000, and the protocol agents under them. It runs `network_mode: host` "
        "because a terminal machine's job is to see the LAN -- multicast does not cross "
        "a docker bridge, so mDNS/DNS-SD, SAP, PTP and AVDECC all go quiet behind one. "
        "The image signs itself with the commit it was built from, because nothing here "
        "is bind-mounted and the image IS the deployment.",
        "This is the container that actually talks to the hardware in the room, and the "
        "one whose supervisor's status page says which agents are alive. The HTTP API "
        "the portal's shell calls on 8000 is agent #25 inside it -- there is no separate "
        "orchestrator container, and there must not be a second declaration of one. The "
        "single line a new machine edits is its broker address."),

    "Node-BareMetal-Broker": (
        "The standalone bench's own broker",
        "An overlay service, brought in only with docker-compose.broker.yml, running "
        "mosquitto on the host network with the AUTHENTICATED config: anonymous access "
        "off, a password file and an ACL file. The credentials are minted by "
        ".apk.scripts/broker_credentials.sh, and without them mosquitto exits at "
        "startup rather than coming up open.",
        "It is for a terminal machine that IS the bench -- no house broker to report to, "
        "or none reachable yet. It carries authentication rather than a loopback bind "
        "because under host networking there is no port mapping to hide behind. A node "
        "that reports to a central broker must not run this: that is a second broker on "
        "1883 with nothing publishing to it."),

    # --- DockTor -----------------------------------------------------
    "DockTor": (
        "This dashboard -- the tool that looks at the others",
        "The container manager: an HTTP API over the scripts in `docker scripts/`, and "
        "the page you are reading. It is the one service in this repository that holds "
        "/var/run/docker.sock, it binds the checkout at the same absolute path the "
        "daemon knows it by, and it joins the host's network stack so that `localhost` "
        "here means what it means in your browser.",
        "Every other stack runs a workload; this one runs the instrument. The socket IS "
        "the privilege -- a container holding it can start any container as any user -- "
        "so this API has no authentication and its bind stays on loopback, which are two "
        "halves of one decision. Bridged instead of host-networked it painted a healthy "
        "bench as entirely down, because every probe went to its own empty loopback."),

    # --- Server:Discovery:NMOS -- the specification's furniture, and two of ours -
    "NMOS-Dev": (
        "The consolidated NMOS Workbench (Registry, Node, Sandbox & Bridge)",
        "Consolidated single container running nmos-cpp registry, mock node, sandbox dashboard (Nginx), and apkaudio-nmos-bridge.",
        "It hosts IS-04 Registration/Query & IS-09 System APIs, 5 mock Senders & Receivers, the 3208 Sandbox UI, and the DataBus MQTT-NMOS bridge."),

    "NMOS-Testing": (
        "The AMWA conformance suite",
        "The industry's own NMOS Testing Tool, pinned by digest rather than by `latest` "
        "so that a green lane means a green lane against a stated version of the rules. "
        "It binds a dozen mock services for a device under test to call back into, and "
        "deliberately publishes only its GUI and its API.",
        "It is the grader: `check.sh nmos-rig` and the controller lane drive it, and its "
        "verdict is the closest thing to an outside opinion this bench has. It is also "
        "the largest thing in the stack, which is why it is the candidate for a "
        "`profiles:` key rather than for a compose file of its own."),

    "APK-NMOS-Facade": (
        "The controller under test -- ours",
        "The Testing Facade of our NMOS control implementation, standing still so the "
        "AMWA Controller suites can drive it. It publishes nothing and is reached only "
        "by the suite on this network; it answers 405 to anything that is not the POST "
        "the suite makes, which is why its healthcheck deliberately does not use "
        "--fail. Its restart policy is `no` so that a crash stays visible.",
        "A Controller test grades a controller by BEING CALLED BY IT, not by calling it: "
        "the suite stands up its own mock registry and node and asks this facade "
        "questions. So the device under test is a client, and it has to sit somewhere "
        "the suite can reach -- which on this bench means inside this network, because "
        "the firewall drops bridge-to-host."),

    # --- Server:Netbox -- the inventory ----------------------------------------
    "Netbox-App": (
        "The DCIM/IPAM of record",
        "NetBox itself, upstream's image with every setting written out as an "
        "environment variable and a superuser created on first boot. Published on "
        "loopback only, with development credentials that are in a public repository -- "
        "the narrow bind and the weak password are one decision, not two.",
        "It stores what the bench IS rather than what it is doing: racks, devices, "
        "interfaces, IP addresses and cable runs. The bus says what is happening now and "
        "forgets; this says what is installed, and it is what the network displays and "
        "the probe read to know which switch a port belongs to. A writer here cannot "
        "re-point a stream -- what a writer here can do is make the inventory disagree "
        "with the room, which is the one thing an inventory is for."),

    "Netbox-Worker": (
        "The background jobs behind NetBox",
        "The same NetBox image running `manage.py rqworker` against the job queue. It "
        "has no listener at all: it takes its work off the queue rather than off a "
        "socket, which is why nothing is published for it and why its own log says "
        "little.",
        "Without it webhooks, scripts and report runs sit in the queue and the UI "
        "reports them as pending for ever -- a failure that is silent in the web "
        "container's log. Whether the work is actually being taken is read as "
        "`rq-workers-running` off the app's status API, never from the fact that a "
        "container named worker is running."),

    "Netbox-Postgres": (
        "The database under NetBox",
        "PostgreSQL 18, publishing nothing: it is reached by service name from inside "
        "the netbox network, or with `exec.sh Netbox-Postgres psql -U netbox`. Its "
        "volume is the inventory, which is why this stack keeps its own compose project "
        "where a stray --remove-orphans typed against another file cannot reach it.",
        "It holds the inventory itself. The rest of this stack is replaceable from an "
        "image pull; this container's volume is not, and losing it loses what the room "
        "is made of."),

    "Netbox-Valkey": (
        "The job queue NetBox hands work to",
        "A Valkey (Redis-compatible) instance run with append-only persistence on, "
        "holding the RQ queue that Netbox-App writes into and Netbox-Worker reads from. "
        "Nothing is published.",
        "It is persisted deliberately: a background job that evaporates on restart is a "
        "job nobody ran. That is also why it cannot be the same instance as the cache "
        "beside it -- one server cannot hold two opposite persistence policies, however "
        "much two database numbers make it look like it could."),

    "Netbox-Valkey-Cache": (
        "The cache NetBox is allowed to lose",
        "The second Valkey, deliberately not persisted, holding NetBox's caching layer "
        "and nothing else. Nothing is published.",
        "It is the container in this stack whose data is meant to be thrown away, and "
        "saying so is the point of it being separate: an operator can flush or recreate "
        "it without wondering whether a queued job went with it."),

    # --- PROTOCOL:DEV:AES70 ----------------------------------------------------
    "AES70-Dev": (
        "The AES70 workbench and offline documentation on 3220",
        "AES70py -- a pure-Python AES70/OCA CONTROLLER speaking OCP.1 over TCP -- "
        "installed editable into Python 3.12, plus Nginx serving an offline mirror of "
        "the AES70 project site on 3220.",
        "It provides both the AES70py development environment and the offline "
        "AES70 documentation in a single container."),

    # --- PROTOCOL:DEV:EMBER ----------------------------------------------------------
    "Ember-Provider": (
        "A real Ember+ provider on 9000 and offline specification docs on 3221",
        "The embserver provider, serving a GLOW tree on S101/TCP 9000 from CSV files "
        "bound read-only, plus Nginx serving Lawo's offline Ember+ specification PDFs on 3221. "
        "Its select loop re-reads CSVs every 250 ms and pushes changes to subscribers. "
        "Three CSVs provide three Control Surface nodes (baseline sample, APK.audio console, "
        "and BER torture values).",
        "It provides both the Ember+ protocol provider and the offline specification "
        "documentation in a single consolidated container."),

    # --- DATABSE:volume:Log STORAGE -- LOGGER STORAGE --------------------------
    "Logger-Storage": (
        "The owner of the bench-wide log volume, APK:Documentation/LOGS",
        "A busybox container that holds the apk-audio-logs named volume, bound to "
        "APK:Documentation/LOGS in the checkout, opens /logs to every uid (mode 1777) "
        "and then sleeps. Every other container mounts the same volume at /logs and is "
        "told its own folder by APKAUDIO_LOG_DIR=/logs/<container_name>.",
        "Every other stack declares the volume external, so this is what has to exist "
        "before anything else mounts -- for_each_stack starts it first. Log files "
        "written under /logs survive rebuilds, panics and nukes of the containers, "
        "because they live in the checkout rather than in any container."),

    # --- APK:Yo ----------------------------------------------------------------
    "apk-yo": (
        "The chat hub: WebSockets on one side, the bus on the other",
        "A Rust WebSocket server on 8080 that accepts device connections into named "
        "rooms, broadcasts a message to everyone in a room, and relays the same traffic "
        "to and from the APK.audio/Yo/chat topics on the MQTT bus. It runs on the host "
        "network and reads its broker address from the environment.",
        "It is how a touch panel, a SPOG dashboard, a WebPortal tab and a hardware node "
        "say something to each other in words rather than in parameters -- one room a "
        "person and a machine can both be in, tied to the bus so that anything already "
        "listening to the bus can hear it."),
}


def fault(field, text):
    """A row is a line. Refuse a field that cannot be one rather than print it.

    THE READER SLICES ON TABS, so a tab inside a field silently shifts every
    field after it and a newline splits one container into two rows -- both of
    which arrive at the pane as text that is merely wrong rather than as an
    error. Nothing here is user input; this is the gate on the table's own
    editing, which is exactly when the mistake gets made.
    """
    if "\t" in text or "\n" in text:
        sys.stderr.write("purpose.sh: %s contains a tab or a newline\n" % field)
        return True
    return False


bad = False
for container, (role, what, why) in PURPOSE.items():
    for field, text in (("role", role), ("what", what), ("why", why)):
        bad = fault("%s/%s" % (container, field), text) or bad
if bad:
    sys.exit(2)


# --check — the coverage gate. The compose files decide the set.
CONTAINER_NAME = re.compile(r'^\s*container_name:\s*["\']?([^"\'\s#]+)', re.M)


def declared_containers(root):
    """Every `container_name:` any compose file under APK:DOCKERS/ spells out."""
    names = {}
    for base, directories, files in os.walk(root):
        directories[:] = [d for d in directories if not d.startswith('.')]
        for filename in files:
            if 'compose' not in filename.lower():
                continue
            if not filename.lower().endswith(('.yml', '.yaml')):
                continue
            path = os.path.join(base, filename)
            with open(path, encoding='utf-8', errors='replace') as handle:
                for name in CONTAINER_NAME.findall(handle.read()):
                    names.setdefault(name, os.path.relpath(path, root))
    return names


if MODE == "check":
    if not DOCKERS_DIR or not os.path.isdir(DOCKERS_DIR):
        # A HARD FAILURE, NOT A SKIP: the manager image carries this folder
        # without the compose files, so a --check from inside the container
        # cannot see the set it is checking against.
        sys.stderr.write("purpose.sh --check: no APK:DOCKERS directory at %r\n"
                         % DOCKERS_DIR)
        sys.exit(1)

    declared = declared_containers(DOCKERS_DIR)
    missing = sorted(set(declared) - set(PURPOSE))
    stale = sorted(set(PURPOSE) - set(declared))

    for name in missing:
        print("MISSING  %-24s declared by %s, and this table says nothing about it"
              % (name, declared[name]))
    for name in stale:
        print("STALE    %-24s has an entry here and is declared by no compose file"
              % name)
    print("%d declared container(s), %d described, %d missing, %d stale"
          % (len(declared), len(declared) - len(missing), len(missing), len(stale)))
    sys.exit(1 if (missing or stale) else 0)


# The two reading modes.
documents = {name: {"container": name, "role": role, "what": what, "why": why}
             for name, (role, what, why) in PURPOSE.items()
             if not WANT or name == WANT}

if MODE == "json":
    print(json.dumps(documents, indent=2))
else:
    for name in sorted(documents):
        row = documents[name]
        print("\t".join([name, row["role"], row["what"], row["why"]]))
PY
