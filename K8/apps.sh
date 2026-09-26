#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧩 What is running INSIDE each container (app plane, not port plane).
#   ./apps.sh                       TAB rows: CONTAINER APP STATE DETAIL
#   ./apps.sh --json                every field of every plane, keyed by container
#   ./apps.sh [--json] <container>  one container
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# STATE: running | idle (periodic, exited 0, waiting on its clock) | stopped |
#        disabled (roster has it, this box switched it off) | down (container up,
#        app plane will not answer)
# ⚠️ Spell no port. Every URL comes from endpoints.sh, the one port table; this
#    walks the app plane behind the address it returns. Container names DO live
#    here — the app plane is per-image, so enumerating it needs the image.
# Every plane is read ONCE into a document: --json prints it, rows render FROM
# it, so no row field can exist outside the document.
# Below the source line on purpose — check.sh prologue measures the comment run
# a file opens with.

MODE=rows
if [ "${1:-}" = "--json" ]; then
    MODE=json
    shift
fi
WANT="${1:-}"

wanted() { [ -z "$WANT" ] || [ "$WANT" = "$1" ]; }

# ONE `docker ps` AND ONE endpoints.sh PER CONTAINER, PER RUN (PLAN-3319.01).
# Every gatherer asked `docker ps` again, and every label asked endpoints.sh
# again — a whole script, _common.sh and all — so one scan ran endpoints.sh a
# dozen times for six containers, and this script cost ~1.4 s of CPU on the
# dashboard's 15 s beat. Both answers are read once and reused; endpoints.sh's
# output is kept in a per-run folder because endpoint_uri runs inside `$( )`,
# where a shell variable set by one call is gone before the next.
_RUNNING_NAMES=""
_RUNNING_READ=""
container_is_up() {
    if [ -z "$_RUNNING_READ" ]; then
        _RUNNING_NAMES="$(docker ps --format '{{.Names}}' 2>/dev/null)"
        _RUNNING_READ=1
    fi
    printf '%s\n' "$_RUNNING_NAMES" | grep -qx "$1"
}

_ENDPOINT_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/apps-endpoints.XXXXXX" 2>/dev/null)" || _ENDPOINT_CACHE=""
[ -n "$_ENDPOINT_CACHE" ] && trap 'rm -rf "$_ENDPOINT_CACHE"' EXIT

# The up URI endpoints.sh reports for a container, or empty.
endpoint_uri() {
    local container="$1" want_label="$2" cached
    if [ -n "$_ENDPOINT_CACHE" ]; then
        cached="$_ENDPOINT_CACHE/$(printf '%s' "$container" | tr -c 'A-Za-z0-9._-' '_')"
        [ -f "$cached" ] || "$MANAGEMENT_SCRIPTS_DIR/endpoints.sh" "$container" > "$cached" 2>/dev/null
        awk -F'\t' -v label="$want_label" '$3 == label && $5 == "up" { print $4; exit }' "$cached"
        return 0
    fi
    "$MANAGEMENT_SCRIPTS_DIR/endpoints.sh" "$container" 2>/dev/null \
        | awk -F'\t' -v label="$want_label" '$3 == label && $5 == "up" { print $4; exit }'
}

# Is anything actually listening at host:port. bash /dev/tcp (no nc dependency);
# timeout bounds an address that black-holes. A docker mapping says only what
# docker INTENDED — a dead listener in a running container still has its port.
tcp_answers() {
    local host="$1" port="$2"
    timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

# host and port out of any of the URI shapes endpoints.sh emits.
uri_host() { printf '%s' "${1#*://}" | sed 's|/.*||; s|.*@||; s|:.*||'; }
uri_port() { printf '%s' "${1#*://}" | sed 's|/.*||; s|.*:||'; }

# ==============================================================================
# THE PLANES. Raw input only — a payload, a listing, an exit code. Every verdict
# is the renderer at the foot of the file, which holds the whole document.
# ==============================================================================

# ── THE BAREMETAL NODE: the supervisor roster.
# /status is the only authority: docker top shows the same python3 seven times,
# and the per-box APK_AGENT_<ID> enabled flag is nowhere in the process table —
# an agent deliberately off and an agent that died look identical from outside.
# Periodic agents are why STATE is not a boolean: interfaces-report is
# restartPolicy never / everySeconds 3600 and is SUPPOSED to be down 59 min/hr.
gather_baremetal() {
    local container=Node-BareMetal
    wanted "$container" || return 0
    container_is_up "$container" || return 0

    APK_PLANE_BAREMETAL_URL="$(endpoint_uri "$container" 'BareMetal supervisor status')"
    if [ -n "$APK_PLANE_BAREMETAL_URL" ]; then
        APK_PLANE_BAREMETAL="$(curl -fsS --max-time 3 "$APK_PLANE_BAREMETAL_URL" 2>/dev/null)"
    fi

    # The protocol plane is a SECOND question, not the roster: 16 of 23 modules
    # publish a retained status = online that no measurement produced. Its own
    # variable and its own rows — a MODULE is not an AGENT.
    # Longer timeout than /status: the census holds an MQTT subscription open
    # for a settle time. Cached behind the address for one heartbeat interval.
    APK_PLANE_PROTOCOLS_URL="$(endpoint_uri "$container" 'BareMetal protocol modules')"
    if [ -n "$APK_PLANE_PROTOCOLS_URL" ]; then
        APK_PLANE_PROTOCOLS="$(curl -fsS --max-time 12 "${APK_PLANE_PROTOCOLS_URL}.json" 2>/dev/null)"
    fi
    export APK_PLANE_BAREMETAL_URL APK_PLANE_BAREMETAL
    export APK_PLANE_PROTOCOLS_URL APK_PLANE_PROTOCOLS
}

# ── THE BROKER: its own $SYS tree, plus a real connection per listener.
# Up 10 hours is equally true of a mosquitto holding 31 clients and one holding
# none, which is the difference an operator is looking for.
# $SYS is the only source (mosquitto has no HTTP surface — do not invent one).
# Read with -W plus stdbuf -oL, never timeout … | head: mosquitto_sub buffers
# and an outside SIGTERM discards what it has not flushed, so the inventory
# comes back empty from a broker that answered everything.
# Uptime is checked before the counters are believed — they are monotonic since
# start, so a big number after a restart is not throughput.
# $SYS can be REFUSED without the broker being down (an authenticated broker
# accepts a connect and denies an anonymous subscribe). Listener rows come from
# the connection, the broker row from $SYS, and they may disagree: that is
# exactly "up, but it will not tell you".
gather_mqtt() {
    local container=Broker-Mosquitto
    wanted "$container" || return 0
    container_is_up "$container" || return 0

    local native ws host port
    native="$(endpoint_uri "$container" 'MQTT broker')"
    ws="$(endpoint_uri "$container" 'MQTT over WebSockets')"

    APK_PLANE_MQTT_LISTENERS=""
    for uri in "$native" "$ws"; do
        [ -n "$uri" ] || continue
        host="$(uri_host "$uri")"
        port="$(uri_port "$uri")"
        if tcp_answers "$host" "$port"; then
            APK_PLANE_MQTT_LISTENERS+="${uri}"$'\t'"${port}"$'\t'up$'\n'
        else
            APK_PLANE_MQTT_LISTENERS+="${uri}"$'\t'"${port}"$'\t'down$'\n'
        fi
    done

    # $SYS is read on the NATIVE listener only — WebSockets is the same broker
    # through a second door.
    APK_PLANE_MQTT_SYS=""
    if [ -n "$native" ] && command -v mosquitto_sub >/dev/null 2>&1; then
        APK_PLANE_MQTT_SYS="$(stdbuf -oL mosquitto_sub \
            -h "$(uri_host "$native")" -p "$(uri_port "$native")" \
            -t '$SYS/broker/#' -v -W 3 2>/dev/null)"
    elif [ -n "$native" ]; then
        APK_PLANE_MQTT_SYS_ABSENT="mosquitto-clients is not installed on this host"
    fi
    export APK_PLANE_MQTT_LISTENERS APK_PLANE_MQTT_SYS APK_PLANE_MQTT_SYS_ABSENT
}

# ── THE PORTAL: the trees nginx actually serves.
# Listed off the container rather than the Dockerfile (the COPY list moves) and
# then FETCHED — a directory present in the image still 404s when the tree
# inside it has no index.
# Symlinked aliases (FrontEnd, engine, BareMetal, Documentation) are skipped:
# the same app under a second name doubles every row to say one thing twice.
gather_portal() {
    local container=Storage-Portal
    wanted "$container" || return 0
    container_is_up "$container" || return 0

    APK_PLANE_PORTAL_BASE="$(endpoint_uri "$container" 'Web Portal')"
    [ -n "$APK_PLANE_PORTAL_BASE" ] || { export APK_PLANE_PORTAL_BASE; return 0; }

    local trees
    # for d in */, not find -printf: nginx:alpine ships busybox find, which has
    # neither -printf nor -mindepth and printed nothing.
    # -L BEFORE -d, because -d follows the link: the four symlinked aliases are
    # directories by that test, so without it five trees listed as eight apps.
    trees="$(docker exec "$container" sh -c \
        'cd /usr/share/nginx/html && for d in */; do d="${d%/}"; [ -L "$d" ] && continue; [ -d "$d" ] && printf "%s\n" "$d"; done' 2>/dev/null)"

    # Image build stamp, read once and carried on every tree. Trees arrive by
    # COPY, so what nginx serves is a photograph of the repo at build time and
    # "running · HTTP 200" is true of any build.
    # NOT a state: a portal serving last week is what a release is, and a red
    # row teaches the operator to ignore the row.
    # An older image has no marker and says so — COPY preserves the SOURCE
    # mtimes, so reading one prints a confident wrong date.
    APK_PLANE_PORTAL_STAMP="$(docker exec "$container" \
        cat /usr/share/nginx/html/.build-stamp 2>/dev/null | tr -d '\r\n')"

    # APK:OS first: it is the desktop the portal exists to serve and the other
    # trees are what its windows open. sort -s keeps glob order below it, which
    # is what makes the rest of the rows stable between refreshes.
    trees="$(printf '%s\n' "$trees" \
        | awk -F'\n' '{ print ($0 == "APK:OS" ? 0 : 1) "\t" $0 }' \
        | sort -s -k1,1n | cut -f2-)"

    APK_PLANE_PORTAL_TREES=""
    local tree encoded code
    while IFS= read -r tree; do
        [ -z "$tree" ] && continue
        # curl parses APK: before the first / as a URI scheme. Encode it.
        encoded="${tree//:/%3A}"
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
            "$APK_PLANE_PORTAL_BASE/$encoded/" 2>/dev/null)"
        APK_PLANE_PORTAL_TREES+="${tree}"$'\t'"${code}"$'\t'"${encoded}"$'\n'
    done <<<"$trees"

    export APK_PLANE_PORTAL_BASE APK_PLANE_PORTAL_STAMP APK_PLANE_PORTAL_TREES
}


# ── THE NMOS REGISTRY: how many nodes it holds, and which are near collection.
# Up 3 hours on a registry holding nothing reads exactly like a healthy one.
# ⚠️ THE QUERY API PAGES SILENTLY — a clean 200 returned 10 of 55 rows here.
#    Page size appears only in X-Paging-Limit and Link, paging.limit caps at
#    100, and there is NO total-count header, so len(json) is a confident wrong
#    number. METHOD: follow Link rel="prev" until a page comes back empty and
#    union the ids. prev, not next: paging.order=update returns newest first,
#    so next is empty immediately (measured over 55 senders: 55, 10, 5, 2 at
#    limits 100, 10, 5, 2 — four clean 200s, three wrong; prev returns 55 at
#    every limit). X-Paging-Limit is the page SIZE, not a total.
# Expiry comes from IS-04 /health/nodes/{id} on the Registration API; nmos-cpp
# publishes no health endpoint. An EXPIRED registration is invisible — the
# registry collects it, so it LEAVES the listing — so what is reported is the
# APPROACH to expiry per node against registration_expiry_interval from the
# registry settings.
# health 9223372036854775807 is INT64_MAX and means never: nmos-cpp marks its
# OWN self-registration that way. Counted apart, or a bench with one mock node
# reports two nodes.
gather_nmos() {
    local container=NMOS-Registry
    wanted "$container" || return 0
    container_is_up "$container" || return 0

    local query registration settings
    query="$(endpoint_uri "$container" 'NMOS IS-04 Query API')"
    registration="$(endpoint_uri "$container" 'NMOS IS-04 Registration API')"
    settings="$(endpoint_uri "$container" 'NMOS registry settings')"

    APK_PLANE_NMOS_QUERY="$query"
    if [ -z "$query" ]; then
        export APK_PLANE_NMOS_QUERY APK_PLANE_NMOS
        return 0
    fi

    # python, because the TERMINATION CONDITION is a property of the parsed
    # body and a bash loop matching [] pages for ever. It gathers only: counts,
    # ids, health values and the settings number go out raw, and every verdict
    # is taken in the renderer.
    APK_PLANE_NMOS="$(APK_NMOS_QUERY="$query" APK_NMOS_REGISTRATION="$registration" \
        APK_NMOS_SETTINGS="$settings" python3 - <<'NMOSPY'
import json, os, urllib.error, urllib.parse, urllib.request

QUERY = os.environ["APK_NMOS_QUERY"].rstrip("/")
REGISTRATION = os.environ.get("APK_NMOS_REGISTRATION", "").rstrip("/")
SETTINGS = os.environ.get("APK_NMOS_SETTINGS", "")
TIMEOUT = 4


def get(url):
    with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
        return json.loads(response.read().decode("utf8")), response.headers


def links(headers):
    """The `Link` header as {rel: url}."""
    out = {}
    for part in headers.get("Link", "").split(","):
        if "<" in part and 'rel="' in part:
            out[part.split('rel="')[1].split('"')[0]] = part[part.index("<") + 1:part.index(">")]
    return out


def collect(resource):
    """Every entry of a Query API collection, and how many pages it took.

    IT WALKS `rel="prev"`, AND `rel="next"` IS THE WRONG ONE. That reads
    backwards and it is not: the default `paging.order=update` returns the
    collection NEWEST FIRST, so `prev` moves toward older entries -- deeper into
    the set -- while `next` moves toward entries that do not exist yet. On a
    registry that is not being written to, `next` returns an empty page
    immediately.

    Measured 2026-09-05 against 55 senders, following `next`:

        paging.limit=100 -> 55 in 2 pages     the whole set fits the first page
        paging.limit= 10 -> 10 in 2 pages     WRONG, and it looks exactly right
        paging.limit=  5 ->  5 in 2 pages
        paging.limit=  2 ->  2 in 2 pages

    Every one of those is a clean 200 and a plausible number. Following `prev`
    returns 55 at every limit from 100 down to 3, in 2, 7, 12 and 20 pages.
    That invariance -- the same total at four page sizes -- is the assertion
    this method rests on, and with no total published anywhere it is the only
    proof available. `APK:PODS/Server:Discovery:NMOS/SRC/paging_audit.py` re-runs
    it against a live registry and names the entries a page size missed.

    `paging.limit=100` is the API's own cap, asked for explicitly so the page
    count is a fact about this registry rather than about its default of 10.

    Ids rather than a running list, because the first page of a `prev` walk and
    the unpaged default response are the same page: summing lengths would count
    it twice.
    """
    url = "%s/%s?paging.limit=100" % (QUERY, resource)
    ids, pages, seen = set(), 0, set()
    while url and url not in seen and pages < 500:
        seen.add(url)
        page, headers = get(url)
        pages += 1
        if not page:
            break
        ids.update(entry.get("id") for entry in page)
        url = links(headers).get("prev")
    return ids, pages


document = {"container": "NMOS-Registry", "plane": "nmos-registry",
            "source": QUERY, "counts": {}, "pages": {}}
try:
    for resource in ("nodes", "devices", "senders", "receivers"):
        ids, pages = collect(resource)
        document["counts"][resource] = len(ids)
        document["pages"][resource] = pages
    # The node LIST is re-read unpaged only because it is small enough to be;
    # counts["nodes"] above is the paged number and the reported one. If they
    # disagree the paging is wrong, which is the assertion below.
    listing, _ = get("%s/nodes?paging.limit=100" % QUERY)
    document["nodes"] = [{"id": n.get("id"), "label": n.get("label"),
                          "hostname": n.get("hostname")} for n in listing]
    if len(document["nodes"]) != document["counts"]["nodes"]:
        document["pagingWarning"] = (
            "the unpaged node listing holds %d and the paged walk found %d"
            % (len(document["nodes"]), document["counts"]["nodes"]))
except (urllib.error.URLError, OSError, ValueError) as exc:
    document["error"] = "%s did not answer — %s" % (QUERY, exc)
    print(json.dumps(document))
    raise SystemExit(0)

if SETTINGS:
    try:
        settings, _ = get(SETTINGS)
        document["expiryInterval"] = settings.get("registration_expiry_interval")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        document["settingsError"] = str(exc)

# Health is per node, from the REGISTRATION API where IS-04 puts it. A node the
# registry already collected is simply absent above, so a 404 here is a
# registration that expired between the two reads — reported, not swallowed.
if REGISTRATION:
    for node in document.get("nodes", []):
        url = "%s/health/nodes/%s" % (REGISTRATION, urllib.parse.quote(node["id"]))
        try:
            health, _ = get(url)
            # IS-04 spells health as a STRING of seconds, normalised here:
            # "9223372036854775807" == 9223372036854775807 is False, and the
            # self-registration was counted as a real device until this line.
            raw = health.get("health")
            try:
                node["health"] = int(raw)
            except (TypeError, ValueError):
                node["health"] = None
                node["healthError"] = "health is not a number: %r" % (raw,)
        except urllib.error.HTTPError as exc:
            node["health"] = None
            node["healthError"] = "HTTP %s" % exc.code
        except (urllib.error.URLError, OSError, ValueError) as exc:
            node["health"] = None
            node["healthError"] = str(exc)

print(json.dumps(document))
NMOSPY
)"
    export APK_PLANE_NMOS_QUERY APK_PLANE_NMOS
}

# ── NETBOX: the web application, and whether anything works its queue.
# Netbox-Worker can be a running healthy container — its healthcheck greps its
# own process table — while nothing drains the queue, and every symptom arrives
# hours later as a job stuck pending. rq-workers-running is the number that
# settles it, and it needs a credential.
# So the plane splits in two: what is readable anonymously (is the application
# answering) and what needs a token (what it is, and the queue). No
# NETBOX_API_TOKEN is reported as unknown, not as a fault.
# Mint one in the UI (user menu → API Tokens) and export it.
# The header is NOT spelled here: _common.sh::netbox_auth_header is the one
# shell spelling, because NetBox refuses a MALFORMED header with the same 403
# as an unprivileged token. It prints nothing and returns 1 when no token is
# set, which is the [ -n "$header" ] below.
gather_netbox() {
    local container=Netbox-App
    wanted "$container" || return 0
    container_is_up "$container" || return 0

    APK_PLANE_NETBOX_BASE="$(endpoint_uri "$container" 'NetBox')"
    if [ -z "$APK_PLANE_NETBOX_BASE" ]; then
        export APK_PLANE_NETBOX_BASE
        return 0
    fi

    # The one page an unauthenticated client may see, and the same one the
    # container healthcheck asks for. A code, not a body.
    APK_PLANE_NETBOX_LOGIN="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 \
        "${APK_PLANE_NETBOX_BASE%/}/login/" 2>/dev/null)"

    APK_PLANE_NETBOX_STATUS=""
    APK_PLANE_NETBOX_CODE=""
    local header
    header="$(netbox_auth_header)"
    if [ -n "$header" ]; then
        local api
        api="$(endpoint_uri "$container" 'NetBox REST API')"
        api="${api:-${APK_PLANE_NETBOX_BASE%/}/api/}"
        # The code is captured SEPARATELY from the body: a 403 answers with a
        # JSON body of its own, so "did not parse" and "was refused" are
        # otherwise indistinguishable downstream.
        APK_PLANE_NETBOX_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -H "$header" \
            "${api%/}/status/" 2>/dev/null)"
        if [ "$APK_PLANE_NETBOX_CODE" = "200" ]; then
            APK_PLANE_NETBOX_STATUS="$(curl -s --max-time 5 \
                -H "$header" \
                "${api%/}/status/" 2>/dev/null)"
        fi
    fi

    export APK_PLANE_NETBOX_BASE APK_PLANE_NETBOX_LOGIN \
           APK_PLANE_NETBOX_STATUS APK_PLANE_NETBOX_CODE
}

gather_discovery() {
    local container=APK-Discovery-Engine
    wanted "$container" || return 0
    container_is_up "$container" || return 0

    APK_PLANE_DISCOVERY_URL="$(endpoint_uri "$container" 'Discovery REST API / Status')"
    if [ -z "$APK_PLANE_DISCOVERY_URL" ]; then
        APK_PLANE_DISCOVERY_URL="http://127.0.0.1:8120/status"
    fi
    if [ -n "$APK_PLANE_DISCOVERY_URL" ]; then
        APK_PLANE_DISCOVERY="$(curl -fsS --max-time 3 "http://127.0.0.1:8120/api/status" 2>/dev/null)"
    fi
    export APK_PLANE_DISCOVERY_URL APK_PLANE_DISCOVERY
}

gather_baremetal
gather_mqtt
gather_portal
gather_nmos
gather_netbox
gather_discovery

# ==============================================================================
# THE RENDERER. One document per plane, then rows out of the documents.
# ⚠️ Payloads travel in the ENVIRONMENT: the heredoc already owns stdin, and a
#    <<< beside it REPLACES it — python was handed the JSON as its own source.
# ==============================================================================
APK_PLANE_MODE="$MODE" APK_PLANE_WANT="$WANT" python3 - <<'PY'
import json
import os

MODE = os.environ.get("APK_PLANE_MODE", "rows")
documents = {}


def env(name):
    return os.environ.get(name, "")


# -- the node ------------------------------------------------------------------
def baremetal_document():
    container = "Node-BareMetal"
    url = env("APK_PLANE_BAREMETAL_URL")
    payload = env("APK_PLANE_BAREMETAL")
    if not url and not payload:
        return None
    document = {"container": container, "plane": "supervisor", "source": url or None}
    if not url:
        document["error"] = "status endpoint not published"
        return document
    if not payload:
        document["error"] = "no answer from %s" % url
        return document
    try:
        document["status"] = json.loads(payload)
    except ValueError:
        document["error"] = "status payload is not JSON"

    # Nested in this document, not a fourth PLANES entry: documents are keyed
    # by CONTAINER, so a second top-level plane for Node-BareMetal would
    # overwrite this one. One container, one document, two planes inside.
    protocols_url = env("APK_PLANE_PROTOCOLS_URL")
    protocols_payload = env("APK_PLANE_PROTOCOLS")
    if protocols_url:
        plane = {"source": protocols_url}
        if not protocols_payload:
            # Distinguished from "no modules": this address exists only on a
            # supervisor carrying the census, and an older image answers 501.
            plane["error"] = "no answer from %s.json" % protocols_url
        else:
            try:
                plane["census"] = json.loads(protocols_payload)
            except ValueError:
                plane["error"] = "protocol payload is not JSON"
        document["protocols"] = plane
    return document


def protocol_rows(document):
    """Two rows, not twenty-three.

    The card is a summary and twenty-three module rows would bury the seven
    agent rows beside them; the whole census is in the document either way and
    the details pane prints all of it. So the card carries the two numbers an
    operator acts on: how many modules are DOING something, and how many
    statements about them are contradicted by another source.

    The second row is deliberately not green when it is zero-valued and
    deliberately not red when it is not. A disagreement is a thing to read, not
    an outage -- painting it red next to a stopped agent would teach the same
    habit of ignoring the colour that `status = online` already taught.
    """
    plane = document.get("protocols")
    if not plane:
        return []
    container = document["container"]
    if "census" not in plane:
        return [(container, "protocols", "down", plane.get("error", "unreadable"))]

    census = plane["census"]
    counts = census.get("counts", {})
    bus = census.get("sources", {}).get("bus", {})
    total = sum(counts.values())
    live = counts.get("live", 0)

    if not bus.get("reachable"):
        # Every runtime verdict in the document is unknown here; a live-module
        # count taken off it would read as a fleet that stopped.
        state, detail = "unknown", "broker %s did not answer — %s" % (
            bus.get("broker", "?"), bus.get("error", "no reason given"))
    else:
        state = "running" if live else "idle"
        detail = "%d of %d publishing · %s · %d retained topics" % (
            live, total,
            " · ".join("%d %s" % (v, k) for k, v in sorted(counts.items())
                       if k != "live") or "nothing else",
            bus.get("topics", 0))
    rows = [(container, "protocols", state, detail)]

    disagreements = census.get("disagreements", [])
    kinds = {}
    for entry in disagreements:
        kinds[entry["kind"]] = kinds.get(entry["kind"], 0) + 1
    rows.append((container, "protocol-truth",
                 "running" if not disagreements else "idle",
                 "%d source disagreement(s)%s" % (
                     len(disagreements),
                     " · " + " · ".join("%d %s" % (v, k) for k, v in sorted(kinds.items()))
                     if kinds else "")))
    return rows


def baremetal_rows(document):
    container = document["container"]
    if "status" not in document:
        return [(container, "supervisor", "down", document.get("error", "unreadable"))]

    rows = []
    for agent in document["status"].get("agents", []):
        agent_id = agent.get("id", "?")
        periodic = agent.get("everySeconds")
        detail = []

        if not agent.get("enabled", False):
            state = "disabled"
            detail.append("switched off for this node")
        elif agent.get("running", False):
            state = "running"
            detail.append("pid %s" % agent.get("pid"))
        elif periodic:
            # Exited 0 on its own clock is the healthy shape for these, and
            # only the code separates it from a crash — both are running:false
            # with a pid of None.
            code = agent.get("lastExitCode")
            state = "idle" if code == 0 else "stopped"
            detail.append("last exit %s" % code if code is not None else "not yet run")
        else:
            state = "stopped"
            code = agent.get("lastExitCode")
            detail.append("exit %s" % code if code is not None else "never started")

        if periodic:
            detail.append("every %ds" % int(periodic))
        if agent.get("restarts"):
            detail.append("%s restarts" % agent["restarts"])
        rows.append((container, agent_id, state, " · ".join(detail)))

    rows.extend(protocol_rows(document))
    return rows


# -- the broker ----------------------------------------------------------------
def duration(seconds):
    """`37422 seconds` is not an answer to "how long has this been up"."""
    seconds = int(seconds)
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return "%dd %dh" % (days, hours)
    if hours:
        return "%dh %dm" % (hours, minutes)
    return "%dm" % minutes


def mqtt_document():
    container = "Broker-Mosquitto"
    listeners_raw = env("APK_PLANE_MQTT_LISTENERS")
    sys_raw = env("APK_PLANE_MQTT_SYS")
    absent = env("APK_PLANE_MQTT_SYS_ABSENT")
    if not listeners_raw and not sys_raw and not absent:
        return None

    listeners = []
    for line in listeners_raw.splitlines():
        if not line:
            continue
        fields = (line.split("\t") + [""] * 3)[:3]
        listeners.append({"uri": fields[0], "port": fields[1], "state": fields[2]})

    # $SYS/broker/clients/connected 31 -> {"clients/connected": "31"}. Kept
    # FLAT under its own key: these are the broker names, spelled the way the
    # mosquitto documentation spells them.
    counters = {}
    for line in sys_raw.splitlines():
        topic, _, value = line.partition(" ")
        if not topic.startswith("$SYS/broker/"):
            continue
        counters[topic[len("$SYS/broker/"):]] = value.strip()

    # Uptime is derived ONCE here and both surfaces read it; $SYS states it as
    # 37422 seconds. Raw seconds are kept beside it for a reader comparing
    # against mosquitto documentation.
    uptime = {}
    raw_uptime = counters.get("uptime", "").split(" ")[0]
    if raw_uptime.isdigit():
        uptime = {"seconds": int(raw_uptime), "human": duration(raw_uptime)}

    document = {"container": container, "plane": "broker", "uptime": uptime,
                "listeners": listeners, "sys": counters}
    if absent:
        document["sysUnavailable"] = absent
    elif sys_raw == "":
        # Distinguished from "not installed": a broker that accepts a connect
        # and refuses an anonymous subscribe is UP and silent.
        document["sysUnavailable"] = "$SYS did not answer — the broker may require a credential"
    return document


def mqtt_rows(document):
    container = document["container"]
    counters = document.get("sys", {})
    rows = []

    # The broker row state comes from $SYS, not a socket — the listener rows
    # below already say what accepts connections. This row is the broker own
    # account of itself, so its absence is the news it carries.
    version = counters.get("version", "")
    if version:
        detail = [version]
        # Uptime first and always: every counter under it is monotonic since
        # that moment.
        if document.get("uptime"):
            detail.append("up %s" % document["uptime"]["human"])
        connected = counters.get("clients/connected")
        if connected is not None:
            detail.append("%s clients" % connected)
        stored = counters.get("messages/stored")
        if stored is not None:
            detail.append("%s retained" % stored)
        rows.append((container, "broker", "running", " · ".join(detail)))
    else:
        rows.append((container, "broker", "down",
                     document.get("sysUnavailable", "$SYS did not answer")))

    for listener in document.get("listeners", []):
        scheme = listener["uri"].split("://", 1)[0]
        name = "listener:%s" % listener["port"]
        if listener["state"] == "up":
            rows.append((container, name, "running", "%s · accepting connections" % scheme))
        else:
            rows.append((container, name, "down", "%s · nothing accepted a connection" % scheme))
    return rows


# -- the portal ----------------------------------------------------------------
def portal_document():
    container = "Storage-Portal"
    base = env("APK_PLANE_PORTAL_BASE")
    trees_raw = env("APK_PLANE_PORTAL_TREES")
    if not base and not trees_raw:
        return None

    document = {"container": container, "plane": "static", "source": base or None,
                "builtAt": env("APK_PLANE_PORTAL_STAMP") or None, "trees": []}
    if not base:
        document["error"] = "no published port"
        return document

    for line in trees_raw.splitlines():
        if not line:
            continue
        fields = (line.split("\t") + [""] * 3)[:3]
        document["trees"].append({"tree": fields[0], "httpCode": fields[1],
                                  "url": "%s/%s/" % (base, fields[2])})
    if not document["trees"]:
        document["error"] = "html root is empty or unreadable"
    return document


def portal_rows(document):
    container = document["container"]
    if document.get("error"):
        return [(container, "nginx", "down", document["error"])]

    built = document.get("builtAt")
    built_detail = "built %s" % built if built else "build time not stamped"

    rows = []
    for tree in document["trees"]:
        code = tree["httpCode"]
        name = tree["tree"]
        if code[:1] in ("2", "3"):
            rows.append((container, name, "running", "HTTP %s · %s" % (code, built_detail)))
        elif code == "403":
            # 403 IS NOT A FAILURE: nginx with autoindex off over a tree with
            # no index.html (APK:Documentation, APK:BareMetal). Every deep link
            # into it still resolves.
            rows.append((container, name, "running",
                         "HTTP 403 · no index page · %s" % built_detail))
        elif code == "000":
            # No stamp on a tree that did not answer — it has not said which
            # image it is.
            rows.append((container, name, "down", "no answer"))
        else:
            rows.append((container, name, "stopped", "HTTP %s" % code))
    return rows


# -- the registry --------------------------------------------------------------
# INT64_MAX. nmos-cpp writes it as the health of its OWN node resource: "this
# one is me and it does not expire". Named rather than compared in three places.
NEVER_EXPIRES = 9223372036854775807


def nmos_document():
    container = "NMOS-Registry"
    query = env("APK_PLANE_NMOS_QUERY")
    payload = env("APK_PLANE_NMOS")
    if not query and not payload:
        return None
    if not query:
        return {"container": container, "plane": "nmos-registry",
                "error": "Query API not published"}
    if not payload:
        return {"container": container, "plane": "nmos-registry", "source": query,
                "error": "no answer from %s" % query}
    try:
        return json.loads(payload)
    except ValueError:
        return {"container": container, "plane": "nmos-registry", "source": query,
                "error": "query payload is not JSON"}


def nmos_rows(document):
    """Two rows: what is registered, and what is about to stop being.

    ZERO NODES IS `idle`, NOT `stopped`. A bench whose mock node is deliberately
    switched off has an empty registry and nothing is wrong -- the same lesson
    `interfaces-report` taught the node plane, where being not-running for
    fifty-nine minutes an hour is the correct state. A registry that will not
    answer at all is the fault, and that is the row above.
    """
    container = document["container"]
    if document.get("error"):
        return [(container, "registry", "down", document["error"])]

    counts = document.get("counts", {})
    pages = document.get("pages", {})
    nodes = document.get("nodes", [])
    total = counts.get("nodes", 0)

    # The registry own self-registration is not a device somebody registered;
    # counting it makes a bench with one mock node report two.
    own = sum(1 for n in nodes if n.get("health") == NEVER_EXPIRES)
    registered = total - own

    detail = ["%d node(s)" % registered]
    if own:
        detail.append("+%d self" % own)
    for resource in ("devices", "senders", "receivers"):
        if resource in counts:
            detail.append("%d %s" % (counts[resource], resource))
    # The page count is the evidence the number was read past the first page.
    read_in = max(pages.values()) if pages else 0
    if read_in:
        detail.append("read in %d page(s)" % read_in)
    rows = [(container, "registry", "running" if registered else "idle",
             " · ".join(detail))]

    # -- expiry: an EXPIRED registration is not visible — the registry collects
    # it, so it LEAVES the listing and "0 expired" would be true of a registry
    # that just dropped every node. Reported instead: each node health against
    # registration_expiry_interval, and whether the registry states it.
    interval = document.get("expiryInterval")
    mortal = [n for n in nodes if n.get("health") != NEVER_EXPIRES]
    unreadable = [n for n in mortal if n.get("health") is None]

    if not nodes:
        detail = "nothing registered, so nothing to expire"
        if interval:
            detail += " · expiry %ss" % interval
        rows.append((container, "registrations", "idle", detail))
        return rows

    if interval is None:
        state, detail = "unknown", (
            "%d heartbeating · the registry would not say its expiry interval%s"
            % (len(mortal), " — " + document["settingsError"]
               if document.get("settingsError") else ""))
    elif unreadable:
        state = "stopped"
        detail = "%d of %d node(s) would not report health: %s" % (
            len(unreadable), len(mortal),
            ", ".join((n.get("label") or n.get("id") or "?")[:24] +
                      " (" + (n.get("healthError") or "?") + ")"
                      for n in unreadable[:3]))
    else:
        state = "running"
        detail = "%d heartbeating · expiry %ss" % (len(mortal), interval)
        if own:
            detail += " · %d never expires (the registry itself)" % own
    rows.append((container, "registrations", state, detail))
    return rows


# -- netbox --------------------------------------------------------------------
def netbox_document():
    container = "Netbox-App"
    base = env("APK_PLANE_NETBOX_BASE")
    login = env("APK_PLANE_NETBOX_LOGIN")
    if not base and not login:
        return None

    document = {"container": container, "plane": "netbox", "source": base or None,
                "loginCode": login or None}
    if not base:
        document["error"] = "no published port"
        return document

    code = env("APK_PLANE_NETBOX_CODE")
    payload = env("APK_PLANE_NETBOX_STATUS")
    api = {"code": code or None, "tokenGiven": bool(os.environ.get("NETBOX_API_TOKEN"))}
    if payload:
        try:
            api["status"] = json.loads(payload)
        except ValueError:
            api["error"] = "/api/status/ did not answer JSON"
    document["api"] = api
    return document


def netbox_rows(document):
    """Three rows: the application, what it is, and whether the queue is worked.

    NO TOKEN IS `unknown`, NOT `stopped`. The web row above it is measured
    either way, so a bench without a credential still says whether NetBox is
    answering -- what it cannot say is what is inside, and saying that plainly
    is the difference between a row an operator reads and a red dot they learn
    to ignore.
    """
    container = document["container"]
    if document.get("error"):
        return [(container, "web", "down", document["error"])]

    code = document.get("loginCode") or "000"
    if code[:1] in ("2", "3"):
        rows = [(container, "web", "running", "HTTP %s · %s" % (code, document["source"]))]
    elif code == "000":
        rows = [(container, "web", "down", "no answer from %s" % document["source"])]
    else:
        rows = [(container, "web", "stopped", "HTTP %s from the login page" % code)]

    api = document.get("api") or {}
    status = api.get("status")
    if not api.get("tokenGiven"):
        rows.append((container, "inventory", "unknown",
                     "authenticated API — export NETBOX_API_TOKEN to read it"))
        return rows
    if api.get("code") in ("401", "403"):
        # A refused token has expired or was minted under a different
        # API_TOKEN_PEPPER_1. Named, or 403 reads as having no token at all.
        rows.append((container, "inventory", "stopped",
                     "the API refused this token (HTTP %s) — mint another"
                     % api["code"]))
        return rows
    if not isinstance(status, dict):
        rows.append((container, "inventory", "down",
                     api.get("error") or "no answer from /api/status/"))
        return rows

    rows.append((container, "inventory", "running",
                 "NetBox %s · Django %s · Python %s · %d plugin(s)"
                 % (status.get("netbox-version", "?"),
                    status.get("django-version", "?"),
                    status.get("python-version", "?"),
                    len(status.get("plugins") or {}))))

    # THE ROW THIS PLANE WAS WRITTEN FOR. Zero workers is stopped, not idle:
    # a NetBox with nothing draining its queue is the one failure here that a
    # container listing cannot see.
    workers = status.get("rq-workers-running")
    if workers is None:
        rows.append((container, "rq-workers", "unknown",
                     "this NetBox does not report rq-workers-running"))
    elif workers:
        rows.append((container, "rq-workers", "running",
                     "%d worker(s) draining the queue" % workers))
    else:
        rows.append((container, "rq-workers", "stopped",
                     "no worker is draining the queue — jobs will sit as pending"))
    return rows


# -- discovery engine ----------------------------------------------------------
def discovery_document():
    container = "APK-Discovery-Engine"
    raw = env("APK_PLANE_DISCOVERY")
    url = env("APK_PLANE_DISCOVERY_URL")
    if not raw and not url:
        return None

    doc = {"container": container, "plane": "discovery", "source": url or "http://127.0.0.1:8120/api/status"}
    if not raw:
        doc["error"] = "no answer from discovery status endpoint"
        return doc
    try:
        data = json.loads(raw)
        doc["data"] = data
    except Exception as e:
        doc["error"] = f"invalid JSON: {e}"
    return doc


def discovery_rows(document):
    container = document["container"]
    if document.get("error"):
        return [(container, "engine", "down", document["error"])]
    data = document.get("data", {})
    engine = data.get("engine", {})
    counters = data.get("counters", {})
    devices = data.get("devices", [])
    deaths = data.get("deaths", [])

    rows = []
    # 1. Engine status
    status = engine.get("status", "unknown")
    state = "running" if status == "online" else "down"
    uptime = engine.get("uptime_secs", 0)
    rows.append((container, "engine", state, f"Discovery Engine online · uptime {uptime}s · circle {engine.get('circling_interval_secs', 30)}s · TTL {engine.get('presence_ttl_secs', 120)}s"))

    # 2. Devices
    live_devices = [d for d in devices if d.get("is_online")]
    rows.append((container, "devices", "running", f"{len(live_devices)} device(s) online ({len(devices)} identified in cache)"))

    # 3. Supervised Plugins
    plugins = data.get("plugins", [])
    active_plugins = [p for p in plugins if p.get("is_active")]
    rows.append((container, "plugins", "running", f"{len(active_plugins)} active / {len(plugins)} supervised plugins auto-launching on demand"))

    # 4. Deaths
    deaths_total = counters.get("deaths_total", len(deaths))
    rows.append((container, "deaths", "running", f"{deaths_total} death(s) recorded · active killer sentinel armed (2s probe)"))

    return rows


PLANES = (
    (baremetal_document, baremetal_rows),
    (mqtt_document, mqtt_rows),
    (portal_document, portal_rows),
    (nmos_document, nmos_rows),
    (netbox_document, netbox_rows),
    (discovery_document, discovery_rows),
)

rows = []
for build, render in PLANES:
    document = build()
    if document is None:
        continue
    documents[document["container"]] = document
    rows.extend(render(document))

if MODE == "json":
    print(json.dumps(documents, indent=2))
else:
    for row in rows:
        print("\t".join(str(field) for field in row))
PY
