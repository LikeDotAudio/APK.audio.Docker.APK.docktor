#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🔧 Every ROUTE a container answers on. The handles, not the addresses.
#   ./api.sh                     every container
#   ./api.sh Node-BareMetal      one container
#   ./api.sh --json [container]  the whole document, keyed by container
# TAB rows, no header: CONTAINER METHOD PATH URI STATE WHAT
# STATE is open (a GET a browser can follow) | verb (it CHANGES something —
# never handed to a browser as a link) | absent (no HTTP routes; PATH says why).
# ⚠️ NOT ONE ROUTE IS WRITTEN DOWN HERE. A route table is longer than a port
#    table and drifts faster, so every row is something a running service said:
#   DECLARED         the service serves its own table (Node-BareMetal GET /api,
#                    the manager GET /api/routes).
#   SELF-DESCRIBING  an NMOS base path answers with its children — IS-04 own
#                    convention, implemented by nmos-cpp.
#   THE 404          Node-BareMetal lists its paths in a 404 body, and did so
#                    before it had /api. Kept as the fallback so a node that has
#                    not been rebuilt is not reported as having no API.
# A container with no routes STILL GETS A ROW: "nothing here" and "nothing
# asked" look identical on a page. A broker handles are topics (topics.sh) and a
# database handles are tables.
# THE WALK IS ONE LEVEL DEEP, deliberately: an NMOS Query API child collection
# holds one entry per resource (60 senders here), so a second level is an
# inventory, not an API.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

MODE=rows
if [ "${1:-}" = "--json" ]; then MODE=json; shift; fi
WANT="${1:-}"

# The endpoint table, verbatim. endpoints.sh is the one copy of the port table;
# a `down` row is skipped because a route table read off an address nothing
# answers on is a guess.
APK_ENDPOINTS="$("$MANAGEMENT_SCRIPTS_DIR/endpoints.sh" ${WANT:+"$WANT"} 2>/dev/null)"

# Which containers exist now, so a reason-row prints for a container that is up
# and not for one removed an hour ago.
APK_RUNNING="$(docker ps --format '{{.Names}}' 2>/dev/null)"

# The NetBox Authorization header, built once by _common.sh::netbox_auth_header
# and carried in as a whole `Name: Value` line (curl own format). Empty when no
# token is set, which the reader turns into a row rather than a malformed
# header: NetBox refuses `Authorization: Token ` with the same 403 as a real
# credential lacking permission.
APK_NETBOX_HEADER="$(netbox_auth_header || true)"

export APK_ENDPOINTS APK_RUNNING MODE WANT APK_NETBOX_HEADER

python3 - <<'PY'
import json
import os
import urllib.error
import urllib.request

MODE = os.environ.get("MODE", "rows")
WANT = os.environ.get("WANT", "")
RUNNING = [n for n in os.environ.get("APK_RUNNING", "").splitlines() if n]

# Every endpoint row endpoints.sh printed, as (container, kind, label, uri, state).
ENDPOINTS = [tuple((line.split("\t") + [""] * 5)[:5])
             for line in os.environ.get("APK_ENDPOINTS", "").splitlines() if line]

TIMEOUT = 4


def fetch(uri, timeout=TIMEOUT, headers=None):
    """(status, body) for one GET, or (None, error-text). Never raises.

    A 404 IS A RESULT AND NOT A FAILURE here — the node's route list arrives in
    the body of one. urllib raises on it, so the HTTPError is unwrapped back
    into the pair every caller already handles.

    `headers` exists for the one service on this bench that will not describe
    itself to an anonymous caller. A 403 is a result too, and the reader that
    passes a credential is the reader that can tell the two apart.
    """
    request = urllib.request.Request(
        uri, headers=dict({"Accept": "application/json"}, **(headers or {})))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as answer:
            return answer.status, answer.read(400_000).decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        try:
            return err.code, err.read(400_000).decode("utf-8", "replace")
        except Exception:
            return err.code, ""
    except Exception as err:
        return None, str(err)


def as_json(body):
    try:
        return json.loads(body)
    except Exception:
        return None


def uri_of(container, label):
    for row in ENDPOINTS:
        if row[0] == container and row[2] == label and row[4] == "up":
            return row[3]
    return None


def http_endpoints(container):
    """Every `up` http:// endpoint declared for one container."""
    return [row for row in ENDPOINTS
            if row[0] == container and row[4] == "up" and row[3].startswith("http")]


def route(method, path, uri, state, what):
    return {"method": method, "path": path, "uri": uri, "state": state, "what": what}


# DECLARED — the service hands back its own route table: one object per route
# with method, path and what. A service that answers /api with something else is
# skipped and the 404 fallback runs.
def declared(base, index_path):
    status, body = fetch(base.rstrip("/") + index_path)
    if status != 200:
        return None, ("%s answered %s" % (index_path, status if status else body))
    document = as_json(body)
    rows = document.get("routes") if isinstance(document, dict) else None
    if not isinstance(rows, list):
        return None, "%s did not answer a route table" % index_path
    out = []
    for row in rows:
        if not isinstance(row, dict) or not row.get("path"):
            continue
        method = (row.get("method") or "GET").upper()
        out.append(route(method, row["path"], base.rstrip("/") + row["path"].split("<")[0],
                         "open" if method in ("GET", "HEAD") else "verb",
                         row.get("what") or ""))
    return out, None


# THE 404 — a refusal that names what would have been accepted.
def from_refusal(base):
    status, body = fetch(base.rstrip("/") + "/-what-routes-are-there")
    document = as_json(body) if body else None
    paths = document.get("paths") if isinstance(document, dict) else None
    if not isinstance(paths, list):
        return None
    return [route("GET", p, base.rstrip("/") + p.split("<")[0], "open", "")
            for p in paths if isinstance(p, str)]


# SELF-DESCRIBING — IS-04 convention: a base path answers with its children.
def children(container):
    rows = []
    for _container, _kind, label, uri, _state in http_endpoints(container):
        status, body = fetch(uri)
        if status != 200:
            continue
        document = as_json(body)
        if not isinstance(document, list) or not all(isinstance(c, str) for c in document):
            continue
        base = uri if uri.endswith("/") else uri + "/"
        rows.append(route("GET", base.split("://", 1)[-1].split("/", 1)[-1].rstrip("/") or "/",
                          uri, "open", label))
        for child in document:
            rows.append(route("GET", "…/" + child.rstrip("/"), base + child, "open", ""))
    return rows


# THE READERS: one per container with a route surface, one REASON each for the
# containers without. A reason names what the container IS; the state word beside
# it comes from whether the container is running at all.
def baremetal():
    base = uri_of("Node-BareMetal", "BareMetal supervisor status")
    if not base:
        return None
    base = base.rsplit("/status", 1)[0]
    rows, why = declared(base, "/api")
    if rows:
        return {"container": "Node-BareMetal", "source": base + "/api",
                "how": "declared", "routes": rows}
    fallback = from_refusal(base)
    if fallback:
        return {"container": "Node-BareMetal", "source": base,
                "how": "404", "routes": fallback,
                "note": "read off a refusal — this node predates GET /api (%s)" % why}
    return {"container": "Node-BareMetal", "source": base, "how": "none",
            "routes": [], "error": why}


def manager():
    # The manager answers about itself, over HTTP rather than by import: the
    # container being asked is the one that answers, so a manager on an older
    # image reports the routes IT has.
    if "DockTor" not in RUNNING:
        return None
    port = os.environ.get("APK_MANAGER_PORT", "8765")
    base = "http://127.0.0.1:%s" % port
    rows, why = declared(base, "/api/routes")
    if rows is None:
        return {"container": "DockTor", "source": base + "/api/routes",
                "how": "none", "routes": [], "error": why}
    return {"container": "DockTor", "source": base + "/api/routes",
            "how": "declared", "routes": rows}


def nmos(container):
    if container not in RUNNING:
        return None
    rows = children(container)
    if not rows:
        return None
    return {"container": container, "how": "self-describing",
            "source": "each declared endpoint's own base path", "routes": rows}


def netbox():
    """NetBox describes its whole API at /api/ — to a caller that has logged in.

    SELF-DESCRIBING, LIKE THE NMOS ONE, AND SHAPED DIFFERENTLY. IS-04 answers a
    base path with a JSON ARRAY of child names; the Django REST Framework root
    answers with an OBJECT of name → absolute URL. Both are the service saying
    what it has, which is the rule this file is built on, so this reads the
    object rather than adding NetBox to `children()` and teaching that function
    a second shape.

    NO TOKEN IS A ROW, NOT AN ABSENCE. Anonymous callers get 403 (measured
    2026-09-06), and a container that answers "who are you" is the opposite of
    a container with no API — printing nothing for it would say the wrong one.
    """
    container = "Netbox-App"
    if container not in RUNNING:
        return None
    base = uri_of(container, "NetBox REST API")
    if not base:
        return None

    # NOT SPELLED HERE: the header arrives whole from
    # _common.sh::netbox_auth_header and is split back into the pair urllib
    # wants.
    name, _sep, value = os.environ.get("APK_NETBOX_HEADER", "").partition(": ")
    if not value:
        return {"container": container, "how": "authenticated", "routes": [],
                "source": base,
                "reason": "NetBox requires a login for everything but /login/. "
                          "Dev login: APKaudio / APKaudio1234! (or admin / admin). "
                          "Mint a token in the UI and export NETBOX_API_TOKEN; "
                          "the UI, the API and GraphQL are all in the address "
                          "table above."}

    status, body = fetch(base, headers={name: value})
    document = as_json(body) if status == 200 else None
    if not isinstance(document, dict):
        return {"container": container, "how": "none", "routes": [], "source": base,
                "error": "%s answered %s" % (base, status if status else body)}

    rows = [route("GET", "/api/", base, "open", "the API root — every branch below")]
    for name, uri in sorted(document.items()):
        if not isinstance(uri, str):
            continue
        rows.append(route("GET", "/api/%s/" % name, uri, "open", ""))
    return {"container": container, "how": "self-describing", "source": base,
            "routes": rows}


# These four are named because their handles are NOT HTTP at all, and no probe
# can emit the sentence "its handles are topics" — that is a fact about what the
# software IS. Every HTTP container is discovered from the endpoint table.
NOT_HTTP = {
    "Storage-Broker":  "MQTT, not HTTP — this container's handles are topics, "
                       "and they are in the BUS section beside this one.",
    "SQL-Proxy":       "The MySQL wire protocol, not HTTP — ProxySQL in front of "
                       "the three Galera nodes; its handles are schemas and "
                       "tables, reached with the mysql:// URI above.",
    "SQL-Node-1":      "A Galera node — MySQL wire protocol, nothing published. "
                       "Clients go through SQL-Proxy, never to a node.",
    "SQL-Node-2":      "A Galera node — MySQL wire protocol, nothing published. "
                       "Clients go through SQL-Proxy, never to a node.",
    "SQL-Node-3":      "A Galera node — MySQL wire protocol, nothing published. "
                       "Clients go through SQL-Proxy, never to a node.",
    "SQL-Backup":      "No network surface: a nightly mariadb-backup to "
                       "/srv/apk-audio/sql-backups, and the shell for "
                       "cluster-status.sh and restore-verify.sh.",
    "Storage-MariaDB": "The MySQL wire protocol, not HTTP — its handles are "
                       "schemas and tables, reached with the mysql:// URI above.",
    "Storage-PHP":     "FastCGI on 9000, and nothing published — it is reached "
                       "THROUGH the portal, which is why it has no address a "
                       "browser can follow.",
    "Storage-Portal":  "nginx serving files, so there is no route table to ask "
                       "for: the trees it serves ARE its surface, and the app "
                       "plane above measures each one.",
    "Netbox-Worker":   "No listener at all — it takes its work off the queue in "
                       "Netbox-Valkey rather than off a socket. Whether it is "
                       "doing so is `rq-workers-running` on Netbox-App's app "
                       "plane, not anything askable here.",
    "Netbox-Postgres": "The PostgreSQL wire protocol, not HTTP, and nothing is "
                       "published: it is reached by service name from inside "
                       "the `netbox` network, or with "
                       "`exec.sh Netbox-Postgres psql -U netbox`.",
    "Netbox-Valkey":   "The Redis protocol, not HTTP — its handles are the job "
                       "queue's keys. Nothing is published.",
    "Netbox-Valkey-Cache": "The Redis protocol again, and this one holds only "
                       "cache: it is the container whose data is meant to be "
                       "thrown away. Nothing is published.",
}

documents = {}
for build in (baremetal, manager, netbox):
    document = build()
    if document and (not WANT or document["container"] == WANT):
        documents[document["container"]] = document

for container in ("NMOS-Dev", "NMOS-Registry", "NMOS-Node"):
    if WANT and container != WANT:
        continue
    document = nmos(container)
    if document:
        documents[container] = document

for container, reason in NOT_HTTP.items():
    if WANT and container != WANT:
        continue
    if container in RUNNING and container not in documents:
        documents[container] = {"container": container, "how": "not-http",
                                "routes": [], "reason": reason}

if MODE == "json":
    print(json.dumps(documents, indent=2))
else:
    for container in sorted(documents):
        document = documents[container]
        if not document["routes"]:
            print("\t".join([container, "—", document.get("reason")
                             or document.get("error") or "no route table",
                             "", "absent", document["how"]]))
            continue
        for row in document["routes"]:
            print("\t".join([container, row["method"], row["path"], row["uri"],
                             row["state"], row["what"]]))
PY
