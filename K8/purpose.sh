#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📘 What each container IS, and why the bench needs it. The one copy.
#   ./purpose.sh                     every container
#   ./purpose.sh Broker-SqlCapture   one container
#   ./purpose.sh --json [container]  the same document, keyed by container
#   ./purpose.sh --check             every declared container has an entry or a label
# WHY THIS IS WRITTEN DOWN WHEN api.sh REFUSES TO BE: a reason is not a
# measurement. No probe can emit "this is the delta capture, and without it the
# bus keeps only the latest value of every topic and none of the history".
# THE HAZARD IS DRIFT, AND --check IS THE ANSWER: it walks every compose file
# under PODS/, takes every container_name:, and fails on an entry with no
# container or a container with no entry. No daemon needed, so `purpose.sh
# --check` runs on any checkout (the old check.sh container-purpose lane that
# called it was retired in 2240c51e5).
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

# THE PLUGINS' OWN WORDS (PLAN-3409.01). Every container carrying the
# audio.apk.purpose label, as docker has it now: name, labels, running. One
# docker call for the lot; none at all for --check, which reads compose files.
APK_PURPOSE_INSPECT=""
if [ "$MODE" != check ]; then
    _apk_ids="$(docker ps -aq --filter label=audio.apk.purpose 2>/dev/null)"
    if [ -n "$_apk_ids" ]; then
        # shellcheck disable=SC2086  # one id per word, on purpose
        APK_PURPOSE_INSPECT="$(docker inspect --format '{{.Name}}{{"\t"}}{{json .Config.Labels}}' $_apk_ids 2>/dev/null)"
    fi
    APK_PURPOSE_RUNNING="$(docker ps --format '{{.Names}}' 2>/dev/null)"
    unset _apk_ids
fi

export MODE WANT DOCKERS_DIR APK_PURPOSE_INSPECT APK_PURPOSE_RUNNING

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

    # --- DATABASE.server.SQL -- the core stack ---------------------------------
    "Storage-PHP": (
        "The interpreter behind /api/*",
        "php-fpm on 9000, published to nothing: it is reachable only from the compose "
        "network, and nginx fastcgi_passes the named endpoints to it. It reaches the "
        "database as `sql-proxy` (SCAN_DB_HOST), and its code is COPYed into the image, "
        "so editing an endpoint needs `up -d --build` and never a bare restart.",
        "The portal beside it is nginx over static trees and cannot execute anything. "
        "Without this tier nginx returned the PHP SOURCE of the corpus endpoints, the "
        "front end's JSON.parse threw on it, and the Scanalyze tab reported the "
        "database offline while the database was healthy two containers away."),

    "Storage-Portal": (
        "The web shell on 8080 -- the front door",
        "nginx serving the built front end: the shell, the widget engine and the apps "
        "its windows open, with /api/* routed through to Storage-PHP. The tree it "
        "serves is a photograph taken at build time, so a page edit reaches it on "
        "`up -d --build` and not on a restart.",
        "It is the address a person is given for this ecosystem, and the one the deploy "
        "to apk.audio mirrors. Everything else on the bench is something this page "
        "talks to."),

    # --- DATABASE.server.SQL -- consolidated SQL server (1 server / 3 cluster) ---
    "SQL-Node-1": (
        "Primary MariaDB node (1 server mode seed, and Galera cluster founder)",
        "MariaDB 11.4 on its own `sql-node-1-data` volume, reachable only on the compose network. "
        "In 'PROXY 1 server' mode, it serves all traffic behind SQL-Proxy. In 'PROXY 3 cluster' "
        "mode, it founds the Galera cluster that nodes 2 and 3 join.",
        "The database of record. Behind SQL-Proxy, whether running as a single server or "
        "as a 3-node Galera cluster, all clients connect transparently to sql-proxy:3306."),

    "SQL-Node-2": (
        "Galera node 2 of 3 (enabled in 'PROXY 3 cluster' mode)",
        "MariaDB 11.4 with Galera replication on its own `sql-node-2-data` volume, "
        "started after SQL-Node-1 (service_started, never service_healthy -- a joiner "
        "cannot be healthy until a Primary exists) and joining it by state transfer.",
        "The second copy is what makes a node failure a non-event: two of three is "
        "still a Primary, so writes continue while one node restarts. Down to one "
        "node the cluster loses quorum and stops accepting writes."),

    "SQL-Node-3": (
        "Galera node 3 of 3 (enabled in 'PROXY 3 cluster' mode)",
        "MariaDB 11.4 with Galera replication on its own `sql-node-3-data` volume, "
        "joining the cluster after SQL-Node-2, and the first node compose stops.",
        "The third vote. Galera needs a majority to stay Primary, and three nodes is "
        "the smallest count that survives losing any one of them."),

    "SQL-Proxy": (
        "The one database address: sql-proxy:3306",
        "ProxySQL in front of the SQL server tier (1 server or 3 Galera nodes). It sends every query "
        "to a single writer and moves the writer when that node dies; healthy means it has one. "
        "Published to the host only on loopback, 127.0.0.1:3306.",
        "Clients name one host and never learn which node is alive. Without it "
        "Broker-SqlCapture fails name resolution on sql-proxy and exits, "
        "Storage-PHP loses the database, and a node failure becomes every client's "
        "problem instead of the proxy's."),

    "SQL-Schema-Init": (
        "The cluster schema, applied on every up. Runs once and exits",
        "A one-shot on the node image (restart: no) that applies the delta-capture "
        "and scanalyzer schemas through SQL-Proxy, then checks that every object each "
        "file creates exists. Exited (0) is its success state.",
        "It is why an empty cluster -- after a nuke, or on a new machine -- has the "
        "bus_delta and corpus tables the capture agent and the portal expect, without "
        "anyone running SQL by hand."),

    "SQL-Backup": (
        "Nightly hot backup, and the cluster's tool shell",
        "Runs mariadb-backup from a Synced node at 07:30 UTC into a HOST directory "
        "(/srv/apk-audio/sql-backups), keeping seven files, reading the node datadirs "
        "through read-only mounts. The cluster tools live in it too: `docker exec "
        "SQL-Backup cluster-status.sh` reports WHOLE or DEGRADED and names the writer.",
        "Galera replicates mistakes as faithfully as data, so three nodes are not a "
        "backup. The files land outside Docker, which is what lets them survive the "
        "volume deletion a nuke performs."),

    # --- Server:Broker:MQTT -- the bus stack -----------------------------------
    "Broker-Mosquitto": (
        "The house MQTT bus -- the one broker",
        "The pulled eclipse-mosquitto:2.0 image with SRC/mosquitto_local.conf "
        "bind-mounted read-only from DATABUS.Broker.MQTT (not baked: no compose file "
        "builds Docker/Dockerfile.broker yet, and the broker's PRINCIPLES.md records that "
        "bend of Dockers law 8). Native MQTT on 127.0.0.1:1883, MQTT over WebSockets on "
        "127.0.0.1:9001; it answers to mqtt, broker, mosquitto, Storage-Broker and "
        "Portal-Broker on the compose network. Protected: DockTor never stops or "
        "removes it, and ensure_broker raises it first and alone.",
        "This is the bus every other process on the bench actually speaks on: the "
        "manager's MQTT_HOST names it, the front ends subscribe over 9001, and the "
        "delta capture records it. The bus is not a passive transport -- a VISA Write "
        "topic executes SCPI on real hardware -- which is why its anonymous config and "
        "a loopback bind are a pair."),

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

    "Portal-Heartbeat": (
        "The metronome of the bench",
        "The Missions Heartbeat timer, running as its own container (APK:clock:Heartbeat) "
        "with no ports at all -- it only ever speaks to the broker. Which tiers it "
        "actually beats is decided by the retained switches under .../Heartbeat/Enable/, "
        "written by the Missions panel, so it is started once and then left alone.",
        "It is a separate service rather than a thread inside the orchestrator because "
        "the orchestrator restarts whenever a panel rebuild goes wrong, and a clock that "
        "stops when something unrelated stops is not a clock."),

    # --- WEB.Traffic-Router / OsApi / Static -- the web tier ------------------------
    "Portal-Gateway": (
        "The web tier's front door: one origin on 443",
        "Caddy, published on ${APK_GATEWAY_BIND:-127.0.0.1}:443. It routes /api/os/* "
        "and the legacy /api/* to Portal-OsApi, /mqtt to Portal-Broker's WebSockets, "
        "/manager/* to DockTor, /api/frames/* to the orchestrator on the BareMetal "
        "node, and everything else to Portal-WebStatic, and it requires auth on writes.",
        "It gives the editor, the OS shell, the bus and DockTor one origin, so no page "
        "guesses which server it is talking to and no browser hits a mixed-origin "
        "wall. The other two web containers publish no ports; without this one the "
        "web tier cannot be reached at all."),

    "Portal-OsApi": (
        "The OS shell's API: server.py as a container",
        "Python on the compose bridge serving /api/os/* (and the older unprefixed "
        "/api/*) behind Portal-Gateway, publishing no port. The APK:OS and APK:FrontEnd "
        "trees are in the image at /srv/portal; artifacts and GANTT data are kept on "
        "named volumes.",
        "Portal-WebStatic can only hand out files. Everything the OS shell does that "
        "changes something -- saving an artifact, editing the GANTT -- is an API call "
        "this container answers."),

    "Portal-WebStatic": (
        "The web tier's files",
        "nginx over APK:FrontEnd at /, APK:OS and the Softapps a browser can open "
        "as-is, all COPYed into the image. No API and no ports: it sits behind "
        "Portal-Gateway, and a JS or CSS edit is a fast image rebuild.",
        "It is every page the portal shows. Without it the gateway still answers but "
        "has nothing to serve outside /api and /manager."),

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

    # --- PROTOCOL.DEV.AES70 ----------------------------------------------------
    "AES70-Dev": (
        "The AES70 workbench and offline documentation on 3220",
        "AES70py -- a pure-Python AES70/OCA CONTROLLER speaking OCP.1 over TCP -- "
        "installed editable into Python 3.12, plus Nginx serving an offline mirror of "
        "the AES70 project site on 3220.",
        "It provides both the AES70py development environment and the offline "
        "AES70 documentation in a single container."),

    # --- PROTOCOL.DEV.EMBER ----------------------------------------------------------
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

    # --- APK:plugin:* -- NOT HERE (PLAN-3409.01) ---------------------------------
    # A plugin container says what it is in its own compose file, as the labels
    # audio.apk.purpose / .what / .why, and this script reads them (LABELLED
    # below). A list of plugins here went stale the day a plugin was added.
    "APK-Discovery-Engine": (
        "Network discovery engine and dynamic plugin supervisor. Role: discovery",
        "apk-discovery-engine: passive network sniffer that watches the LAN for PTP clock "
        "packets, SAP stream announcements, and mDNS service broadcasts. It publishes device "
        "presence documents and discovery events to MQTT, and auto-launches matching plugin "
        "containers via the Docker socket on demand.",
        "Without the discovery engine, hardware and network streams on the LAN are invisible "
        "until configured by hand, and protocol plugins cannot auto-launch when devices appear."),

    "APK-Docker-Gate": (
        "The engine's one door to the Docker socket",
        "The apk-docker-gate binary from the plugins image, and the only holder of "
        "/var/run/docker.sock in the discovery stack. No network at all: it answers on a "
        "unix socket in the apk-docker-gate volume, which only the engine also mounts, "
        "with no capabilities and a read-only root. It keeps the inspects it needs to "
        "recreate an executed plugin on a volume nothing else mounts.",
        "It is what lets the discovery engine launch and execute plugin containers "
        "without the engine itself holding root on the host: the socket stays behind "
        "one small process with no network to be reached over."),

    "Node-FramesRelay": (
        "Unix-socket doors from the gateway to the host loopback",
        "A node:22-alpine relay on the host network that listens on one socket per door "
        "in /run/apk-frames (frames.sock, node.sock, aes67.sock) and dials that door's "
        "loopback port: the orchestrator's frames API, the supervisor's /plugins gateway "
        "on 8100, and the AES67 plugin's UI on 8130.",
        "A host firewall drops connections from a bridge to the host, so Portal-Gateway "
        "could not reach host-networked services on 127.0.0.1; a socket in a shared "
        "volume crosses the namespaces without crossing the firewall. Without it "
        "/api/frames and /plugins answer 502 through the gateway."),

    "Scanalyzer-API": (
        "Scanalyzer's corpus API (php-fpm)",
        "php-fpm on scan-api:9000, no published port. The gateway and Storage-Portal "
        "both reach it over FastCGI on apk-audio_default for the three Scanalyzer API "
        "names; it reads the corpus through sql-proxy.",
        "Without it the Scanalyzer soft app has no corpus behind it: its /scan-api and "
        "relative api/*.php calls fail at the gateway and the portal."),

    # --- APK:Yo ----------------------------------------------------------------
    "apk-yo": (
        "The chat hub: WebSockets on one side, the bus on the other",
        "A Rust WebSocket server on 8150 (WS_PORT; not 8080, which is Storage-Portal's) "
        "that accepts device connections into named "
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


# --- LABELLED: what a container says about itself (PLAN-3409.01) ------------
# Three labels on the compose service, the plugin's own words:
#   audio.apk.purpose        one line: what it is          -> the role field
#   audio.apk.purpose.what   what runs, and how            -> what
#   audio.apk.purpose.why    what stops working without it -> why
# Read from, first to last, the first that answers winning per container:
#   1. docker inspect of the containers that exist (APK_PURPOSE_INSPECT)
#   2. the compose files under PODS/, when this checkout has them (the
#      manager image does not) -- which also gives the role: its `profiles:`
#   3. the retained `incoming/api` document a running plugin publishes, its
#      `description` field, for a container a compose file declares and
#      neither 1 nor 2 describes. NO RUNNER PUBLISHES `description` YET, so
#      today this answers nothing; it is asked only when 1, 2 and the table
#      all miss a declared name, which --check holds at zero.
LABEL = "audio.apk.purpose"
SERVICE = re.compile(r'^  ([A-Za-z0-9_.-]+):\s*$')


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value.replace("$$", "$")


def compose_services(root):
    """{container_name: {"labels": {...}, "profiles": [...], "file": path}}, read line by line."""
    found = {}
    if not root or not os.path.isdir(root):
        return found
    for base, directories, files in os.walk(root):
        directories[:] = [d for d in directories if not d.startswith('.')
                          and d not in ('node_modules', 'target')]
        for filename in files:
            if 'compose' not in filename.lower() or not filename.lower().endswith(('.yml', '.yaml')):
                continue
            path = os.path.join(base, filename)
            try:
                with open(path, encoding='utf-8', errors='replace') as handle:
                    lines = handle.read().splitlines()
            except OSError:
                continue
            inside, service, in_labels = False, None, False

            def flush():
                if service and service.get("name"):
                    found.setdefault(service["name"], dict(service, file=os.path.relpath(path, root)))

            for line in lines:
                if not line.strip() or line.lstrip().startswith('#'):
                    continue
                if re.match(r'^\S', line):
                    flush()
                    inside, service, in_labels = line.startswith('services:'), None, False
                    continue
                if not inside:
                    continue
                if SERVICE.match(line):
                    flush()
                    service, in_labels = {"name": None, "labels": {}, "profiles": []}, False
                    continue
                if service is None:
                    continue
                m = re.match(r'^    ([A-Za-z_]+):\s*(.*)$', line)
                if m:
                    key, value = m.group(1), m.group(2)
                    in_labels = key == 'labels' and not value
                    if key == 'container_name':
                        service["name"] = unquote(value)
                    elif key == 'profiles':
                        service["profiles"] = [unquote(x) for x in value.strip('[] ').split(',') if x.strip()]
                    continue
                if in_labels:
                    m = re.match(r'^      ([A-Za-z0-9_.-]+):\s*(.*)$', line)
                    if m:
                        service["labels"][m.group(1)] = unquote(m.group(2))
            flush()
    return found


def from_labels(labels):
    if not labels or not labels.get(LABEL):
        return None
    return {"role": labels[LABEL], "what": labels.get(LABEL + ".what", ""),
            "why": labels.get(LABEL + ".why", "")}


def squash(name):
    return re.sub(r'[^a-z0-9]', '', name.lower())


def bus_descriptions(names):
    """{container: description} from retained incoming/api, for names nothing labels."""
    if not names:
        return {}
    import subprocess
    host = os.environ.get("MQTT_HOST") or "127.0.0.1"
    port = os.environ.get("MQTT_PORT") or "1883"
    try:
        out = subprocess.run(["mosquitto_sub", "-h", host, "-p", port, "-v", "-W", "1",
                              "-t", "APK.audio/System/Protocols/+/incoming/api"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    by_token = {}
    for line in out.splitlines():
        _topic, _, payload = line.partition(" ")
        try:
            document = json.loads(payload)
        except ValueError:
            continue
        if isinstance(document, dict) and document.get("token") and \
                isinstance(document.get("description"), str) and document["description"].strip():
            by_token[squash(document["token"])] = document["description"].strip()
    # A container is matched to a token by its name after the first dash,
    # squashed: NMOS_CONTROL and nmos-control are one word.
    return {n: by_token[squash(n.split('-', 1)[-1])] for n in names
            if '-' in n and squash(n.split('-', 1)[-1]) in by_token}


DECLARED = compose_services(DOCKERS_DIR)
LABELLED = {}
for line in os.environ.get("APK_PURPOSE_INSPECT", "").splitlines():
    name, _, labels = line.partition("\t")
    try:
        document = from_labels(json.loads(labels or "null"))
    except ValueError:
        document = None
    if document:
        LABELLED[name.lstrip("/")] = document
for name, service in DECLARED.items():
    if name not in LABELLED and name not in PURPOSE:
        document = from_labels(service["labels"])
        if document:
            LABELLED[name] = document
if MODE != "check":
    running = [n for n in os.environ.get("APK_PURPOSE_RUNNING", "").splitlines() if n]
    # ONLY NAMES A COMPOSE FILE DECLARES. The bus is asked about containers
    # this checkout knows and nothing else describes; asked about every
    # unlabelled running container it ran on every call -- the bench always
    # has strangers and per-device children -- and `-W 1` made each one cost a
    # full second for an answer no runner publishes yet (DISCOVERY.Engine
    # RUNNER api.rs carries no `description`). With every declared container
    # described (--check), this list is empty and no broker is dialled.
    unknown = [n for n in running if n not in PURPOSE and n not in LABELLED
               and n in DECLARED and (not WANT or n == WANT)]
    for name, description in bus_descriptions(unknown).items():
        LABELLED[name] = {"role": description, "what": "", "why": ""}
for name, document in LABELLED.items():
    profiles = DECLARED.get(name, {}).get("profiles") or []
    if profiles and "Role:" not in document["role"]:
        document["role"] = "%s. Role: %s" % (document["role"].rstrip("."), ", ".join(profiles))
    for field in ("role", "what", "why"):
        document[field] = " ".join(document[field].split())   # a label is a line


# --check — the coverage gate. The compose files decide the set.
CONTAINER_NAME = re.compile(r'^\s*container_name:\s*["\']?([^"\'\s#]+)', re.M)


def declared_containers(root):
    """Every `container_name:` any compose file under PODS/ spells out."""
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
        sys.stderr.write("purpose.sh --check: no PODS directory at %r\n"
                         % DOCKERS_DIR)
        sys.exit(1)

    declared = declared_containers(DOCKERS_DIR)
    described = set(PURPOSE) | set(LABELLED)
    missing = sorted(set(declared) - described)
    stale = sorted(set(PURPOSE) - set(declared))

    for name in missing:
        print("MISSING  %-24s declared by %s, with no audio.apk.purpose label and no entry here"
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
for name, document in LABELLED.items():
    if name not in documents and (not WANT or name == WANT):
        documents[name] = dict(document, container=name)

if MODE == "json":
    print(json.dumps(documents, indent=2))
else:
    for name in sorted(documents):
        row = documents[name]
        print("\t".join([name, row["role"], row["what"], row["why"]]))
PY
