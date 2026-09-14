#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🔌 Every address this ecosystem answers on. The one copy of the port table.
#   ./endpoints.sh                 every endpoint
#   ./endpoints.sh Storage-Broker  one container
#   ./endpoints.sh --completeness  audit: every published port covered or excluded
# TAB rows, no header: CONTAINER KIND LABEL URI STATE
#   KIND  open (hand to a browser) | copy (mqtt://, mysql://, ws://)
#   STATE up | declared (compose publishes it, nothing bound) | down
# ONE ROW PER REACHABLE ADDRESS, not per published port: host-networked and
# macvlan containers publish nothing, so a port-reading table cannot see them.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

WANT="${1:-}"

# ── PORTS THIS TABLE DELIBERATELY DOES NOT CARRY ──────────────────────────────
# Data, not prose, so --completeness can read it: an exclusion is a port plus a
# reason. Two reasons and no third — `bench scaffolding` (a page this bench runs
# for itself) and `somebody else specification` (a mirror of another project).
# A port table listing every container a bench happens to run is a second
# docker ps, which ps.sh already is. Anything else wants a row, not a line here.
# Excluding does not hide: the dashboard draws a fallback launcher for every
# published port this table omits, named from page-titles.sh <title> read.
EXCLUDED_PORTS=(
    "3208|NMOS-Dev|bench scaffolding|the demo dashboard this bench runs for itself"
    "5000|NMOS-Testing|somebody else's specification|the AMWA conformance suite's GUI"
    "5001|NMOS-Testing|somebody else's specification|the Testing Facade the same suite reaches by name"
    "3220|AES70-Dev|somebody else's specification|a mirror of the AES70 project site"
    "3221|Ember-Provider|somebody else's specification|Lawo's own Ember+ specification PDFs"
)

# Every published host port that is neither in the table nor excluded above.
# The published set is free-ports.sh --list (reads docker port, so declared/down
# rows are valid input); the covered set is re-read from THIS file own rows, so
# the check has no second copy of the answer to agree with.
# Measured 2026-09-10: 25 published, 21 covered, 5 named-excluded, 0 unaccounted.
# IT FAILS, NEVER SKIPS — an unaccounted port is the drift this exists to catch.
port_table_completeness() {
    local published covered excluded=() unaccounted=() port
    published="$("$MANAGEMENT_SCRIPTS_DIR/free-ports.sh" --list 2>/dev/null | awk '{print $1}' | sort -n -u)"
    if [ -z "$published" ]; then
        log_error "free-ports.sh --list named no published port; there is nothing to audit."
        return 1
    fi
    # This script again with no argument, so the covered set is the rows it
    # really prints. {host} is substituted by then.
    covered="$(bash "${BASH_SOURCE[0]}" 2>/dev/null \
               | awk -F'\t' '{print $4}' | grep -oE ':[0-9]+' | tr -d ':' | sort -n -u)"

    for row in "${EXCLUDED_PORTS[@]}"; do
        excluded+=("${row%%|*}")
    done

    for port in $published; do
        grep -qx "$port" <<< "$covered" && continue
        printf '%s\n' "${excluded[@]}" | grep -qx "$port" && continue
        unaccounted+=("$port")
    done

    echo "published: $(wc -w <<< "$published"), covered by a row: $(wc -w <<< "$covered"), deliberately excluded: ${#excluded[@]}"
    for row in "${EXCLUDED_PORTS[@]}"; do
        IFS='|' read -r port container reason detail <<< "$row"
        printf '  excluded %-6s %-14s %s — %s\n' "$port" "$container" "$reason" "$detail"
    done

    if [ ${#unaccounted[@]} -eq 0 ]; then
        log_info "Every published port is either a row in this table or a named exclusion."
        return 0
    fi
    log_error "Published with no row and no exclusion: ${unaccounted[*]}"
    echo "  Either give it a row above, or add it to EXCLUDED_PORTS with the reason it is not one."
    return 1
}

if [ "$WANT" = "--completeness" ]; then
    port_table_completeness
    exit $?
fi

# The host port a container publishes for <container-port>/tcp, or empty.
# docker port answers from the running container, the only thing that knows
# what ${PORT:-8080} resolved to.
published_port() {
    local container="$1" container_port="$2"
    docker port "$container" "$container_port" 2>/dev/null \
        | head -n1 | sed 's/.*://' 
}

# Every macvlan address a container holds, one per line, or nothing.
# Matched on the DRIVER, not the network name: apk-audio_lan is a bridge until
# its driver says otherwise, and the overlay merges under the project name.
macvlan_addresses() {
    local container="$1" net
    for net in $(docker inspect "$container" \
                 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null); do
        [ "$(docker network inspect "$net" --format '{{.Driver}}' 2>/dev/null)" = macvlan ] || continue
        docker inspect "$container" \
            --format "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" 2>/dev/null
    done
}

# The LAN row for one endpoint: the address every OTHER machine must use, which
# is why the macvlan overlay exists.
# A second discovery path, not a wider docker port: a macvlan container
# publishes nothing (its address IS its NIC), so docker port is empty for ever.
# `copy`, NEVER `open`: a macvlan child and its parent NIC cannot see each
# other, so this address is unreachable from THIS host until
# .apk.scripts/macvlan_shim.sh up has run.
# The port is the CONTAINER own — there is no mapping to read.
# State by a REAL connection, not by the address existing: docker inspect
# reports what Docker INTENDED, which is true whether or not anything answers.
lan_endpoints() {
    local container="$1" cport="$2" label="$3" template="$4" ip port state uri
    port="${cport%%/*}"

    for ip in $(macvlan_addresses "$container"); do
        [ -n "$ip" ] || continue
        # bash /dev/tcp, so no dependency on nc in whatever image this runs
        # in; timeout bounds an unshimmed macvlan address that black-holes.
        if timeout 2 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
            state="up"
        elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
            state="declared"
        else
            state="down"
        fi
        uri="${template//\{port\}/$port}"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$container" copy "$label · LAN" "${uri//\{host\}/$ip}" "$state"
    done
}

# emit_endpoint <container> <container-port> <declared-host-port> <kind> <label> <uri-template>
# The template carries {port}, substituted with whatever is really bound and
# falling back to the compose-declared port. A row prints either way — an
# endpoint that is down is still an endpoint.
emit_endpoint() {
    local container="$1" cport="$2" declared="$3" kind="$4" label="$5" template="$6"
    [ -n "$WANT" ] && [ "$WANT" != "$container" ] && return 0

    local port state
    port="$(published_port "$container" "$cport")"
    if [ -n "$port" ]; then
        state="up"
    else
        port="$declared"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
            state="declared"
        else
            state="down"
        fi
    fi

    local uri="${template//\{port\}/$port}"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$container" "$kind" "$label" "${uri//\{host\}/localhost}" "$state"

    lan_endpoints "$container" "$cport" "$label" "$template"
}

# --- the core stack, from 'Server:Storage:SQL database/docker-compose.yml' ---------
emit_endpoint Storage-Portal        80/tcp   "${PORT:-8080}" open \
    "Web Portal" "http://{host}:{port}"

# The portal own status URL: a second row on the SAME port. docker port is asked
# once and both rows are built from the answer, so a portal published elsewhere
# moves both. A row is an ADDRESS, and one container can answer two.
# `open`: unlike the broker and the database, this one is a page.
emit_endpoint Storage-Portal        80/tcp   "${PORT:-8080}" open \
    "Portal status page" "http://{host}:{port}/status.html"

emit_endpoint Storage-Broker          1883/tcp 1883 copy \
    "MQTT broker" "mqtt://{host}:{port}"

emit_endpoint Storage-Broker          9001/tcp 9001 copy \
    "MQTT over WebSockets" "ws://{host}:{port}"

emit_endpoint Storage-MariaDB 3306/tcp 3306 copy \
    "MariaDB" \
    "mysql://${MARIADB_USER:-apkaudio}:${MARIADB_PASSWORD:-DEV.DB}@{host}:{port}/${MARIADB_DATABASE:-apkaudio}"

# --- the second and third brokers -----------------------------------------
# Three mosquittos, three addresses. Numbered off Storage-Broker (1884/9002 and
# 1885/9003, in the compose files that own them) so all three can run; a bare
# port number in the fallback launcher would not say WHICH bus it opens.
# `copy` for all: mqtt:// and ws:// are not things a browser opens.
emit_endpoint Broker-Mosquitto 1883/tcp 1884 copy \
    "MQTT broker (Server:Broker:MQTT)" "mqtt://{host}:{port}"

emit_endpoint Broker-Mosquitto 9001/tcp 9002 copy \
    "MQTT over WebSockets (Server:Broker:MQTT)" "ws://{host}:{port}"

emit_endpoint Portal-Broker 1883/tcp 1885 copy \
    "MQTT broker (WebPortal)" "mqtt://{host}:{port}"

emit_endpoint Portal-Broker 9001/tcp 9003 copy \
    "MQTT over WebSockets (WebPortal)" "ws://{host}:{port}"

# --- the NMOS bench, from 'Server:Discovery:NMOS/docker-compose.yml' ------
# WHICH ROWS EXIST AND WHY NOT ALL OF THEM. That stack is the specification
# furniture and runs under its own project; "is it ours" and "is it an address
# this ecosystem answers on" are different questions and this file asks only the
# second. The registry and the node are what everything here talks to, so they
# get rows.
# NMOS-Sandbox and NMOS-Testing do NOT: bench scaffolding. Open by hand:
#     xdg-open http://127.0.0.1:3208/     # sandbox dashboard
#     xdg-open http://127.0.0.1:5000/     # AMWA testing GUI
# Their ports live in EXCLUDED_PORTS at the head of this file, which is what
# --completeness reads; the dashboard fallback launcher still finds them by
# <title>. These rows exist because these ports serve JSON and therefore have
# no <title> to fall back on — they drew as "Open Port 3211".
# UNPUBLISHED PORTS ARE NOT ROWS: 1883, 8010-8011, 11000-11001 and 5353/udp are
# image defaults conf/registry.json overrides, or mDNS. docker port is empty for
# them, so a row would read declared for ever against a working container.
# EVERY URI BELOW IS A PATH THAT ANSWERS 200, not a bare host:port.

# Consolidated NMOS-Dev container: IS-04 Reg + Query, IS-09 System, IS-04 Node, IS-05/IS-07, and DataBus bridge.
emit_endpoint NMOS-Dev 3211/tcp 3211 open \
    "NMOS IS-04 Query API" "http://{host}:{port}/x-nmos/query/v1.3/"

emit_endpoint NMOS-Dev 3210/tcp 3210 open \
    "NMOS IS-04 Registration API" "http://{host}:{port}/x-nmos/registration/v1.3/"

emit_endpoint NMOS-Dev 3213/tcp 3213 copy \
    "NMOS IS-04 Query WebSocket" "ws://{host}:{port}/"

emit_endpoint NMOS-Dev 10641/tcp 10641 open \
    "NMOS IS-09 System API" "http://{host}:{port}/x-nmos/system/v1.0/"

emit_endpoint NMOS-Dev 3209/tcp 3209 open \
    "NMOS registry settings" "http://{host}:{port}/settings/all"

emit_endpoint NMOS-Dev 3212/tcp 3212 open \
    "NMOS IS-04 Node API" "http://{host}:{port}/x-nmos/node/v1.3/self"

emit_endpoint NMOS-Dev 3215/tcp 3215 copy \
    "NMOS IS-05 Connection API" "http://{host}:{port}/x-nmos/connection/v1.1/"

emit_endpoint NMOS-Dev 3216/tcp 3216 open \
    "NMOS IS-07 Events API" "http://{host}:{port}/x-nmos/events/v1.0/"

emit_endpoint NMOS-Dev 3217/tcp 3217 copy \
    "NMOS IS-07 Events WebSocket" "ws://{host}:{port}/"

emit_endpoint NMOS-Dev 3218/tcp 3218 open \
    "NMOS IS-04 Node API (DataBus bridge)" "http://{host}:{port}/x-nmos/node/v1.3/self"

# --- PROTOCOL:DEV:AES70 ---------------------------------------------------
# NO ROWS. aes70py-dev publishes nothing; aes70-site publishes 3220 but is a
# mirror of somebody else project site — bench scaffolding, same standard as
# NMOS-Sandbox. 3220 is in EXCLUDED_PORTS; the fallback launcher still finds it.

# --- NetBox, from 'Server:Netbox/docker-compose.yml' ----------------------
# ONE CONTAINER OF FIVE HAS AN ADDRESS. Netbox-Postgres, Netbox-Valkey and
# Netbox-Valkey-Cache publish nothing by design — reached by service name on
# that stack network. Use `exec.sh Netbox-Postgres psql -U netbox`.
# The three rows below are the SAME port, asked once, so a NetBox published
# elsewhere moves all three.
# All three need a login and say so in their own words (measured 2026-09-06:
# / and /graphql/ redirect 302 to login, /api/ answers 403 with NetBox own
# message). Hence open, not copy: a browser CAN use them, it is just asked who
# it is.
emit_endpoint Netbox-App 8080/tcp 8081 open \
    "NetBox" "http://{host}:{port}/"

emit_endpoint Netbox-App 8080/tcp 8081 open \
    "NetBox REST API" "http://{host}:{port}/api/"

emit_endpoint Netbox-App 8080/tcp 8081 open \
    "NetBox GraphQL" "http://{host}:{port}/graphql/"

# --- PROTOCOL:DEV:EMBER ---------------------------------------------------------
# ONE ROW, NOT TWO. ember-docs publishes 3221 and serves Lawo specification
# PDFs — somebody else specification, so it is in EXCLUDED_PORTS.
# copy, not open: S101 is a framed TCP stream. Ember+/S101 has no registered URI
# scheme, so this names the protocol rather than claiming a standard.
emit_endpoint Ember-Provider 9000/tcp 9000 copy \
    "Ember+ provider (S101)" "ember+s101://{host}:{port}"

# --- the node, from 'APK:BareMetal/docker-compose.yml' --------------------
# NOT emit_endpoint: docker port returns nothing for a host-networked container,
# so the published-port lookup would print down against a healthy node for ever.
# The supervisor port is APK_STATUS_PORT, bound to loopback by APK_STATUS_BIND.
# AND NOT A CURL FROM HERE. DockTor runs this script inside itself on the
# apk-audio_default bridge, so its 127.0.0.1 is its own loopback while the
# supervisor listens on the HOST one — two namespaces that never meet, and the
# node read declared while answering 200 the whole time. State comes off the
# socket like every other row; the compose healthcheck is a urlopen of THIS URL,
# so docker has already run the probe and is holding the result.
# The URI is still the HOST loopback, which is the address whoever clicks it has.
if [ -z "$WANT" ] || [ "$WANT" = "Node-BareMetal" ]; then
    node_port="${APK_STATUS_PORT:-8100}"
    node_url="http://127.0.0.1:${node_port}/status"

    # Running FIRST and separately: a stopped container keeps the last health
    # its checks recorded, so health alone reports declared against a node that
    # is not there. Empty when docker has no such container.
    if [ "$(docker inspect Node-BareMetal --format '{{.State.Running}}' 2>/dev/null)" != true ]; then
        node_state="down"
    else
        # Empty, not a template error, when the image declares no healthcheck:
        # .State.Health is nil and dereferencing it fails the whole call.
        node_health="$(docker inspect Node-BareMetal \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null)"
        case "$node_health" in
            healthy) node_state="up" ;;
            # starting through the boot grace, unhealthy after its retries:
            # running and not answering, which is what declared means here.
            ?*)      node_state="declared" ;;
            # No healthcheck to read, so nothing is left but the address —
            # right on the host, wrong from the manager. Kept because a
            # degraded row beats no row; fires only if the healthcheck goes.
            *)       if curl -fsS --max-time 2 "$node_url" >/dev/null 2>&1; then
                         node_state="up"
                     else
                         node_state="declared"
                     fi ;;
        esac
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        Node-BareMetal open "BareMetal supervisor status" "$node_url" "$node_state"

    # The protocol plane, same port and same process. Its state is taken from
    # the row above rather than probed again: a census holds a broker
    # subscription open for a settle time. If the supervisor answers, this
    # address exists.
    printf '%s\t%s\t%s\t%s\t%s\n' \
        Node-BareMetal open "BareMetal protocol modules" \
        "http://127.0.0.1:${node_port}/protocols" "$node_state"
fi
