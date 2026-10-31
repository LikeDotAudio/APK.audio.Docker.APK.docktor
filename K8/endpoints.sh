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

# --- Infrastructure stacks: NO HAND ROWS (2026-10-30 audit, DockTor #4) -----
# Broker-Mosquitto, Storage-Portal, SQL-Proxy, Netbox-App, NMOS-Dev and
# Ember-Provider describe their own endpoints with audio.apk.purpose +
# audio.apk.endpoint.<n> labels in their owners' compose files, and the label
# block below prints them. The 20 rows this file used to keep for them (and
# their reasons) live in those compose files now. AES70's and NMOS's bench
# scaffolding still has no rows; see EXCLUDED_PORTS.

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

# --- Discovery Engine, from 'APK:discovery/Docker/docker-compose.yml' ---------
# Host-networked container: listens on APK_DISCOVERY_HTTP_PORT (default 8120).
if [ -z "$WANT" ] || [ "$WANT" = "APK-Discovery-Engine" ]; then
    disc_port="${APK_DISCOVERY_HTTP_PORT:-8120}"
    disc_url="http://127.0.0.1:${disc_port}"

    if [ "$(docker inspect APK-Discovery-Engine --format '{{.State.Running}}' 2>/dev/null)" != true ]; then
        disc_state="down"
    else
        disc_health="$(docker inspect APK-Discovery-Engine \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null)"
        case "$disc_health" in
            healthy) disc_state="up" ;;
            ?*)      disc_state="declared" ;;
            *)       if curl -fsS --max-time 2 "$disc_url/status" >/dev/null 2>&1; then
                         disc_state="up"
                     else
                         disc_state="declared"
                     fi ;;
        esac
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        APK-Discovery-Engine open "Discovery Status & Equipment Dashboard" "${disc_url}/" "$disc_state"

    printf '%s\t%s\t%s\t%s\t%s\n' \
        APK-Discovery-Engine open "Discovery Activity & Event Log" \
        "${disc_url}/api/events" "$disc_state"

    printf '%s\t%s\t%s\t%s\t%s\n' \
        APK-Discovery-Engine open "Discovery REST API / Status" \
        "${disc_url}/status" "$disc_state"
fi

# --- Plugins: the endpoints each container DECLARES (PLAN-3409.01) ----------
# No plugin is named in this file. A plugin's compose service carries
#     audio.apk.purpose: "<one line>"                       (purpose.sh reads it)
#     audio.apk.endpoint.<n>: "<open|copy> <uri> <label>"   one row each
# and this block reads them back with docker inspect, so a new plugin brings its
# own rows. Compose resolves ${VAR:-default} inside a label, so a port that is
# a setting (AES67's APK_AES67_HTTP_PORT) is the port the container really has.
# STATE: down when the container is not running; an `open` http(s) row is
# fetched (2 s) and reads up or declared by the answer; any other row of a
# running container reads up, as the plugin rows always did.
# Every running labelled container also gets its public config topic as a row.
mapfile -t plugin_ids < <(docker ps -aq --filter "label=audio.apk.purpose" 2>/dev/null)
if [ ${#plugin_ids[@]} -gt 0 ]; then
    while IFS=$'\t' read -r p_cont p_running p_labels; do
        p_cont="${p_cont#/}"
        [ -n "$WANT" ] && [ "$WANT" != "$p_cont" ] && continue
        # The public config row is a PLUGIN/WORKER convention (runner config
        # at System/Config/<token>); infrastructure that labels its endpoints
        # (Broker-Mosquitto, …) has no such topic, so it gets no such row.
        if [ "$p_running" = true ] && [[ "$p_cont" == Plugin-* || "$p_cont" == Worker-* ]]; then
            proto_lower="$(echo "${p_cont#*-}" | tr '[:upper:]' '[:lower:]')"
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$p_cont" copy "Plugin public config API" \
                "mqtt://127.0.0.1:1883/APK.audio/System/Config/${proto_lower}" "up"
        fi
        while IFS=' ' read -r e_kind e_uri e_label; do
            [ -n "$e_uri" ] || continue
            if [ "$p_running" != true ]; then
                e_state="down"
            elif [ "$e_kind" = open ] && [[ "$e_uri" == http* ]]; then
                if curl -fksS --max-time 2 -o /dev/null "$e_uri" 2>/dev/null; then
                    e_state="up"
                else
                    e_state="declared"
                fi
            else
                e_state="up"
            fi
            printf '%s\t%s\t%s\t%s\t%s\n' "$p_cont" "$e_kind" "$e_label" "$e_uri" "$e_state"
        done < <(python3 -c '
import json, sys
labels = json.loads(sys.argv[1] or "null") or {}
keys = [k for k in labels if k.startswith("audio.apk.endpoint.")]
for key in sorted(keys, key=lambda k: (len(k), k)):
    print(" ".join(labels[key].split()))
' "$p_labels")
    done < <(docker inspect --format '{{.Name}}{{"\t"}}{{.State.Running}}{{"\t"}}{{json .Config.Labels}}' \
                 "${plugin_ids[@]}" 2>/dev/null | sort)
fi

# --- Discovered Instruments (PODS/POD:APK_THICK/APK:INSTRUMENTS) ---------
# For each running instrument container (labeled apk.audio.role=instrument or apk-*),
# link to its public API spec in OsApi and its WebSocket / SCPI sockets.
mapfile -t inst_containers < <(docker ps --filter "label=apk.audio.role=instrument" --format '{{.Names}}' 2>/dev/null)
if [ ${#inst_containers[@]} -eq 0 ]; then
    mapfile -t inst_containers < <(docker ps --filter "name=^apk-" --format '{{.Names}}' 2>/dev/null | grep -vE "^(apk-discovery-engine|apk-audio)" || true)
fi

for c_inst in "${inst_containers[@]}"; do
    [ -n "$WANT" ] && [ "$WANT" != "$c_inst" ] && continue
    fam="$(docker inspect "$c_inst" --format '{{index .Config.Labels "apk.audio.family"}}' 2>/dev/null)"
    mod="$(docker inspect "$c_inst" --format '{{index .Config.Labels "apk.audio.model"}}' 2>/dev/null)"
    res="$(docker inspect "$c_inst" --format '{{index .Config.Labels "apk.audio.resource"}}' 2>/dev/null)"
    proto="$(docker inspect "$c_inst" --format '{{index .Config.Labels "apk.audio.protocol"}}' 2>/dev/null)"
    if [ -z "$mod" ] || [ "$mod" = "Unknown" ] || [ "$mod" = "generic" ]; then
        # Fallback to name parsing
        c_stripped="${c_inst#apk-}"
        c_stripped="${c_stripped#inst-}"
        fam="$(echo "$c_stripped" | cut -d'-' -f1)"
        mod="$(echo "$c_stripped" | cut -d'-' -f2)"
    fi
    if [ -n "$mod" ] && [ "$mod" != "Unknown" ] && [ "$mod" != "generic" ]; then
        api_link="http://localhost:8080/api/instrument/api?model=${mod}&family=${fam}"
        spec_link="http://localhost:8080/api/instrument/${fam}/${mod}/${mod}.api.json"
        ws_link="ws://localhost:15000/ws/instrument/${fam}/${mod}"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$c_inst" open "Specification (${fam}/${mod})" "$api_link" "up"
        # Status and GUI are THIS box, not the model: named by the protocol and
        # resource its container is labelled with (OsApi instrument_page.py).
        if [ -n "$proto" ] && [ -n "$res" ]; then
            box_q="$(python3 -c 'import sys,urllib.parse as u; print(u.urlencode(dict(zip(("protocol","resource","model","family"), sys.argv[1:]))))' "$proto" "$res" "$mod" "$fam")"
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$c_inst" open "Status (${res})" "http://localhost:8080/api/instrument/status?${box_q}" "up"
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$c_inst" open "GUI (${res})" "http://localhost:8080/api/instrument/gui?${box_q}" "up"
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$c_inst" open "Public API Spec (${mod}.api.json)" "$spec_link" "up"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$c_inst" copy "Instrument WebSocket socket" "$ws_link" "up"
    fi
    inst_ip="$(echo "$res" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
    if [ -n "$inst_ip" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$c_inst" copy "SCPI raw socket" "tcp://${inst_ip}:5025" "up"
    fi
done

