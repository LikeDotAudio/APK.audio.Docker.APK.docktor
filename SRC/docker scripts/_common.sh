#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧩 Shared docker/compose plumbing. SOURCED, never executed:
#     source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
# Gives: 9 compose arrays, repo paths, UID/GID, logging, announce().
# ⚠️ The compose vars are ARRAYS — always expand "${COMPOSE_X[@]}". Paths hold
#    spaces; an unquoted string word-splits into a bogus docker command.
# 📂 One verb per file beside this one:
#    STACK      up down rebuild-all rebuild-core panic panic-reboot up-stack
#    CONTAINER  restart rebuild exec logs inspect config-path
#    READERS    ps stats status disk host stacks staleness endpoints apps api
#               topics purpose page-titles
#    GATES      test-gates (pre-build) verify (post-mount)
#    MANAGER    manager
#    CLEANUP    free-ports clear-logs prune remove-other-containers
#               remove-dead-containers
#    RAW        compose

set -o pipefail

MANAGEMENT_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# APKAUDIO_REPO wins when set and valid; otherwise walk up. Dockerfile.manager
# COPYs this folder to /app, so inside the manager the walk lands outside the
# checkout (no compose files, no build context).
if [ -n "${APKAUDIO_REPO:-}" ] && [ -d "$APKAUDIO_REPO/APK:DOCKERS" ]; then
    REPO_ROOT="$APKAUDIO_REPO"
    DOCKERS_DIR="$REPO_ROOT/APK:DOCKERS"
else
    DOCKERS_DIR="$(cd "$MANAGEMENT_SCRIPTS_DIR/../../.." && pwd)"
    REPO_ROOT="$(cd "$DOCKERS_DIR/.." && pwd)"
fi

# Exported, not just assigned: Server:Ember/docker-compose.yml and
# docker-compose.manager.yml interpolate ${APKAUDIO_REPO} and Ember spells it
# `:?` — unset is a hard refusal at interpolation.
export APKAUDIO_REPO="$REPO_ROOT"

# ── Compose files: <stack>/Docker/<file>. The only place either half is
# spelled. ⚠️ A wrong path does not raise — compose warns and carries on, so
# every stack reads as empty. Build contexts are repo-root-relative.
COMPOSE_FILE="$DOCKERS_DIR/Server:Storage:SQL database/Docker/docker-compose.yml"
BAREMETAL_COMPOSE_FILE="$DOCKERS_DIR/APK:BareMetal/Docker/docker-compose.yml"
# Overridable so `check.sh node-hardware` can point it at fixtures; the
# hardware decision runs at source time, so that is the only way to test it.
BAREMETAL_HARDWARE_COMPOSE_FILE="${BAREMETAL_HARDWARE_COMPOSE_FILE:-$DOCKERS_DIR/APK:BareMetal/Docker/docker-compose.hardware.yml}"
BAREMETAL_ROOT="$DOCKERS_DIR/APK:BareMetal/SRC"
MQTT_COMPOSE_FILE="$DOCKERS_DIR/Server:Broker:MQTT/Docker/docker-compose.yml"
PORTAL_COMPOSE_FILE="$DOCKERS_DIR/APK:audio:WebPortal/Docker/docker-compose.yml"
NMOS_COMPOSE_FILE="$DOCKERS_DIR/Server:Discovery:NMOS/Docker/docker-compose.yml"
AES70_COMPOSE_FILE="$DOCKERS_DIR/PROTOCOL:DEV:AES70/Docker/docker-compose.yml"
NETBOX_COMPOSE_FILE="$DOCKERS_DIR/Server:Netbox/Docker/docker-compose.yml"
EMBER_COMPOSE_FILE="$DOCKERS_DIR/Server:Ember/Docker/docker-compose.yml"

GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; BLUE="\033[34m"
BOLD="\033[1m"; OFF="\033[0m"

log_info()  { echo -e "${BOLD}${GREEN}✓${OFF} $1"; }
log_warn()  { echo -e "${BOLD}${YELLOW}!${OFF} $1"; }
log_error() { echo -e "${BOLD}${RED}✗${OFF} $1"; }
log_step()  { echo -e "\n${BOLD}${BLUE}==> $1${OFF}"; }

# announce NAME [json] — one stdout line the bus can lift:
#     @EVENT PORT_EVICT_PROCESS {"port":8080,"pid":4412}
# docktor.py republishes @EVENT lines to
# APK.audio/System/ContainerManager. JSON optional, one line, passed as-is.
announce() {
    local name="$1"
    local payload="${2:-}"
    [ -z "$payload" ] && payload="{}"
    echo "@EVENT ${name} ${payload}"
}

# netbox_auth_header [key] — the ONE spelling of NetBox's auth header.
#     -H "$(netbox_auth_header)"   |   APK_NETBOX_HEADER="$(netbox_auth_header)"
# NetBox returns 403 for malformed, unprivileged AND anonymous alike, so a
# second spelling turns a typo into an apparent permissions fault.
# No key → prints nothing, returns 1 (callers must then send NO header).
# `Token`, not `Bearer`: the form NetBox 3 and 4 both accept.
# Key comes from NETBOX_API_TOKEN. Never written down in this repo.
netbox_auth_header() {
    local key="${1:-${NETBOX_API_TOKEN:-}}"
    [ -n "$key" ] || return 1
    printf 'Authorization: Token %s\n' "$key"
}

# Compose command, resolved once.
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    COMPOSE_BASE=(docker compose)
elif command -v docker-compose &>/dev/null; then
    COMPOSE_BASE=(docker-compose)
else
    log_error "Docker / Docker Compose is not installed or not running."
    exit 1
fi

# ONE PROJECT FOR OURS (`apk-audio`): core, BareMetal, broker, WebPortal and
# the manager. nmos/aes70/netbox/ember keep their own — third-party source we
# drive but do not ship. Arrays stay separate because the stacks want opposite
# networking (bridge vs network_mode: host for multicast).
# ⚠️ Every named volume carries an explicit `name:`; a shared project would
#    otherwise repoint mariadb-data, broker-data and mqtt-exchange at empty
#    volumes. Do not drop one.
# ⚠️ `--remove-orphans` under a shared project deletes the other files'
#    containers. rebuild-all.sh and panic.sh omit it deliberately.
COMPOSE_CORE=("${COMPOSE_BASE[@]}" -f "$COMPOSE_FILE")
COMPOSE_NODE=("${COMPOSE_BASE[@]}" -f "$BAREMETAL_COMPOSE_FILE")
COMPOSE_MQTT=("${COMPOSE_BASE[@]}" -f "$MQTT_COMPOSE_FILE")
COMPOSE_PORTAL=("${COMPOSE_BASE[@]}" -f "$PORTAL_COMPOSE_FILE")
COMPOSE_NMOS=("${COMPOSE_BASE[@]}" -f "$NMOS_COMPOSE_FILE")

# NMOS conformance harness (nmos-testing + the facade that depends on it) is
# behind `profiles: ["conformance"]` — 732 MB of that stack's 1,087, off by
# default. Space-separated, unquoted, so a second profile costs no code:
#     APK_NMOS_PROFILES=conformance ./up.sh
if [ -n "${APK_NMOS_PROFILES:-}" ]; then
    for _apk_nmos_profile in ${APK_NMOS_PROFILES}; do
        COMPOSE_NMOS+=(--profile "$_apk_nmos_profile")
    done
    unset _apk_nmos_profile
fi
COMPOSE_AES70=("${COMPOSE_BASE[@]}" -f "$AES70_COMPOSE_FILE")
COMPOSE_NETBOX=("${COMPOSE_BASE[@]}" -f "$NETBOX_COMPOSE_FILE")
COMPOSE_EMBER=("${COMPOSE_BASE[@]}" -f "$EMBER_COMPOSE_FILE")

# ── Hardware overlay (docker-compose.hardware.yml): the only thing that hands
# Node-BareMetal its device nodes and turns on the agents that read them.
# Included only when EVERY device source it declares exists on this host — a
# `devices:` source that is absent makes the daemon REFUSE the container, so an
# unconditional overlay would kill the node on every bench without the puck.
# Sources are read out of the overlay, never copied here.
# APK_NODE_HARDWARE=on forces in, off forces out, auto (default) probes.
# Nothing prints at source time (parsed readers source this too): the decision
# lands in NODE_HARDWARE_OVERLAY / NODE_HARDWARE_WHY, said by
# node_hardware_report().

# Source half of each `- "SOURCE:TARGET"` under the overlay's `devices:`.
# Commented-out lines are skipped — the overlay ships optional devices commented.
node_hardware_devices() {
    [ -f "$BAREMETAL_HARDWARE_COMPOSE_FILE" ] || return 0
    awk '
        /^[[:space:]]*devices:[[:space:]]*$/  { in_dev = 1; next }
        in_dev && /^[[:space:]]*#/            { next }
        in_dev && /^[[:space:]]*$/            { next }
        in_dev && /^[[:space:]]*-[[:space:]]/ {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/"/, "", line)
            sub(/:.*$/, "", line)
            if (line != "") print line
            next
        }
        in_dev                                { in_dev = 0 }
    ' "$BAREMETAL_HARDWARE_COMPOSE_FILE" 2>/dev/null
}

NODE_HARDWARE_OVERLAY=""
NODE_HARDWARE_WHY=""
_node_hardware_decide() {
    local dev declared=0
    case "${APK_NODE_HARDWARE:-auto}" in
        on)  NODE_HARDWARE_OVERLAY="$BAREMETAL_HARDWARE_COMPOSE_FILE"
             NODE_HARDWARE_WHY="forced on by APK_NODE_HARDWARE=on"
             return 0;;
        off) NODE_HARDWARE_WHY="forced off by APK_NODE_HARDWARE=off"
             return 0;;
    esac
    if [ ! -f "$BAREMETAL_HARDWARE_COMPOSE_FILE" ]; then
        NODE_HARDWARE_WHY="no overlay file"
        return 0
    fi
    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        declared=1
        if [ ! -e "$dev" ]; then
            NODE_HARDWARE_WHY="not present: $dev"
            return 0
        fi
    done < <(node_hardware_devices)
    # An overlay declaring no device is only its environment block: agents on
    # against hardware nobody handed over, which is a restart loop.
    if [ "$declared" != 1 ]; then
        NODE_HARDWARE_WHY="overlay declares no device"
        return 0
    fi
    NODE_HARDWARE_OVERLAY="$BAREMETAL_HARDWARE_COMPOSE_FILE"
    NODE_HARDWARE_WHY="every declared device is present"
}
_node_hardware_decide
# An `if`, not `[ … ] && …`: this file is SOURCED, so a false trailing test
# returns 1 and kills a caller under `set -e` on a bench with no puck.
if [ -n "$NODE_HARDWARE_OVERLAY" ]; then
    COMPOSE_NODE+=(-f "$NODE_HARDWARE_OVERLAY")
fi

# node_hardware_report — say the decision out loud. Mounting verbs (up,
# rebuild-all) and reporting ones (status, verify) call it; parsed readers
# (ps, stats, config-path) must not. Never fails, never exits.
# No puck is the ordinary case and reads informational. Emphasis is for the two
# answers where bench and decision may DISAGREE: forced by APK_NODE_HARDWARE,
# or an unreadable overlay.
node_hardware_report() {
    local overlay_name
    overlay_name="$(basename "$BAREMETAL_HARDWARE_COMPOSE_FILE")"

    if [ -n "$NODE_HARDWARE_OVERLAY" ]; then
        case "$NODE_HARDWARE_WHY" in
            forced*)
                log_warn "Node hardware overlay ENGAGED by override -- $overlay_name ($NODE_HARDWARE_WHY)."
                echo "  Nothing was probed. Node-BareMetal will ask for every device the overlay"
                echo "  declares, and compose fails the node if one of them is absent."
                echo "  Unset APK_NODE_HARDWARE to hand the answer back to the probe."
                ;;
            *)
                log_info "Node hardware overlay engaged -- $overlay_name ($NODE_HARDWARE_WHY)."
                ;;
        esac
        return 0
    fi

    case "$NODE_HARDWARE_WHY" in
        "not present: "*)
            log_info "Node hardware overlay not engaged -- ${NODE_HARDWARE_WHY#not present: } is absent."
            echo "  Node-BareMetal comes up with no device nodes and its hardware agents off."
            echo "  That is the ordinary answer on a bench with nothing plugged in."
            echo "  If the device IS plugged in, the PATH is what moved -- compare it against"
            echo "  \`ls -l /dev/input/by-id/\`, then: APK_NODE_HARDWARE=on ./up.sh"
            ;;
        forced*)
            log_warn "Node hardware overlay NOT engaged by override -- $NODE_HARDWARE_WHY."
            echo "  The bench was not probed, so a device that IS present is being ignored."
            echo "  Unset APK_NODE_HARDWARE to hand the answer back to the probe."
            ;;
        *)
            # Both are faults in the declaration rather than facts about the
            # bench, so both earn emphasis a missing puck does not.
            log_warn "Node hardware overlay NOT engaged -- $NODE_HARDWARE_WHY."
            echo "  Expected at: $BAREMETAL_HARDWARE_COMPOSE_FILE"
            ;;
    esac
    return 0
}

# ── THE 9 COMPOSE ARRAYS. All 8 stacks plus the manager are driven. The order
# below IS the dependency chain — compose cannot express depends_on across
# projects, so nothing else holds it. Pass `reverse` to anything tearing down:
#   core   first — publishes 1883, the broker everyone else names
#   mqtt   next  — its sql-capture opens a session against core's MariaDB
#   portal next  — its orchestrator agents connect to a broker at boot
#   nmos   next  — independent; ordered only for a stable log
#   aes70  next  — independent
#   ember  next  — independent
#   netbox next  — independent (own Postgres and queue, speaks to no broker)
#   node   last  — 10 agents dial MQTT_HOST:1883 the moment they start
# ⚠️ nmos/aes70/netbox/ember declare no dependency in either direction; their
#    position is about log order only. Do not grow a depends_on across a
#    project boundary — compose cannot hold one and only this note would.
# Three mosquittos coexist by numbering the HOST ports: 1883/9001 storage,
# 1884/9002 broker, 1885/9003 portal.
# A 9th stack costs an array, an ordering position and a stated reason here.

# ── The manager's identity, read off docker-compose.manager.yml rather than
# typed: panic.sh needs the container NOT to kill, manager.sh needs the compose
# file, and a second spelling of `DockTor` turns the spare into a kill.
# Walked from DOCKERS_DIR (the bound checkout), not from this folder —
# Dockerfile.manager does not COPY the compose file, so /app has no such path.
# The fallback literal is deliberate: an unset name makes panic.sh's exclusion
# match nothing and the panic takes the manager with it.
MANAGER_COMPOSE_FILE="$DOCKERS_DIR/DockTor/Docker/docker-compose.manager.yml"
[ -f "$MANAGER_COMPOSE_FILE" ] \
    || MANAGER_COMPOSE_FILE="$MANAGEMENT_SCRIPTS_DIR/../../Docker/docker-compose.manager.yml"

manager_compose_value() {
    [ -f "$MANAGER_COMPOSE_FILE" ] || return 0
    awk -v key="$1" '
        $0 ~ "^[[:space:]]+" key ":" {
            value = substr($0, index($0, ":") + 1)
            sub(/[[:space:]]*#.*$/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/^["'"'"']|["'"'"']$/, "", value)
            if (length(value)) { print value; exit }
        }' "$MANAGER_COMPOSE_FILE"
}

MANAGER_CONTAINER="$(manager_compose_value container_name)"
MANAGER_IMAGE="$(manager_compose_value image)"
if [ -z "$MANAGER_CONTAINER" ]; then
    MANAGER_CONTAINER="DockTor"
    MANAGER_NAME_GUESSED=1
fi
[ -z "$MANAGER_IMAGE" ] && MANAGER_IMAGE="docktor:local"

COMPOSE_MANAGER=("${COMPOSE_BASE[@]}" -f "$MANAGER_COMPOSE_FILE")

# containers_except_manager <ps-args...> — ids of every container but the
# manager (`docker ps -q` includes it, and panic.sh killed its own process).
# Matched on NAME: the manager shares the `apk-audio` project with the stacks
# it manages, and NMOS is outside that project, so no label separates them.
containers_except_manager() {
    docker ps "$@" --format '{{.ID}}\t{{.Names}}' 2>/dev/null \
        | awk -F'\t' -v skip="$MANAGER_CONTAINER" '$2 != skip && length($1) { print $1 }'
}

# The node runs as the invoking host user (`user:` in its compose file) so
# agent writes through a mount are not root-owned.
# AN EXPORTED VALUE WINS; `id -u` is the fallback, not the answer. The manager
# is a root container (it holds docker.sock), so `id -u` there is 0 and would
# overwrite the 1000 docker-compose.manager.yml passes in. Cost of getting it
# wrong: Node-BareMetal writes root-owned files into a tracked tree, and AES70
# takes the ids as BUILD ARGS, so `useradd -u 0` collides, `|| true` swallows
# it, and the image ships with no `aes70` user for its own `USER aes70`.
export APKAUDIO_UID="${APKAUDIO_UID:-$(id -u)}"
export APKAUDIO_GID="${APKAUDIO_GID:-$(id -g)}"

# for_each_stack <direction> <compose args...>
# `up` runs core→node, `down` the reverse (pass `reverse`); see the ordering
# note above. Returns the LAST NON-ZERO exit code, not the last one — a down
# that failed on the node and passed on the core is a failed down.
for_each_stack() {
    local direction="$1"; shift
    local worst=0 status
    local -a order

    if [ "$direction" = "reverse" ]; then
        order=(node netbox ember aes70 nmos portal mqtt core)
    else
        order=(core mqtt portal nmos aes70 ember netbox node)
    fi

    # Name-indexed lookup, not an if-chain: an unmatched name must ERROR, and
    # an `else` would turn a typo into a silent fall-through to the last array.
    local -a compose
    for stack in "${order[@]}"; do
        echo -e "\n── ${stack} ──"
        case "$stack" in
            core)   compose=("${COMPOSE_CORE[@]}");;
            mqtt)   compose=("${COMPOSE_MQTT[@]}");;
            portal) compose=("${COMPOSE_PORTAL[@]}");;
            nmos)   compose=("${COMPOSE_NMOS[@]}");;
            aes70)  compose=("${COMPOSE_AES70[@]}");;
            netbox) compose=("${COMPOSE_NETBOX[@]}");;
            ember)  compose=("${COMPOSE_EMBER[@]}");;
            node)   compose=("${COMPOSE_NODE[@]}");;
            *)      log_error "for_each_stack: no such stack '$stack'"; worst=2; continue;;
        esac
        "${compose[@]}" "$@"
        status=$?
        [ $status -ne 0 ] && worst=$status
    done
    return $worst
}

# compose_for_stack <stack directory name> — fill STACK_COMPOSE with ONE
# stack's compose command (up-stack.sh's lookup, behind the dashboard's
# per-stack fix button; up.sh would rebuild the other eight instead).
# The name is the directory under APK:DOCKERS/ — what stacks.sh prints — and is
# derived from the compose paths, so a renamed folder needs no edit here.
# Arrays are copied whole, so COMPOSE_NODE keeps its hardware overlay.
# Returns 1 with STACK_COMPOSE empty for an unknown name: callers must refuse
# rather than default to remounting something nobody asked for.
compose_for_stack() {
    local want="$1" entry name file dir
    STACK_COMPOSE=()
    for entry in \
        "COMPOSE_CORE|$COMPOSE_FILE" \
        "COMPOSE_NODE|$BAREMETAL_COMPOSE_FILE" \
        "COMPOSE_MQTT|$MQTT_COMPOSE_FILE" \
        "COMPOSE_PORTAL|$PORTAL_COMPOSE_FILE" \
        "COMPOSE_NMOS|$NMOS_COMPOSE_FILE" \
        "COMPOSE_AES70|$AES70_COMPOSE_FILE" \
        "COMPOSE_NETBOX|$NETBOX_COMPOSE_FILE" \
        "COMPOSE_EMBER|$EMBER_COMPOSE_FILE" \
        "COMPOSE_MANAGER|$MANAGER_COMPOSE_FILE"; do
        name="${entry%%|*}"
        file="${entry#*|}"
        dir="$(basename "$(dirname "$(dirname "$file")")")"
        if [ "$dir" = "$want" ]; then
            eval "STACK_COMPOSE=(\"\${${name}[@]}\")"
            STACK_COMPOSE_FILE="$file"
            return 0
        fi
    done
    return 1
}

# ⚠️ THERE IS NO stage_mqtt_config() AND MUST NOT BE ONE. The broker COPYs its
# config in Dockerfile.broker. Never reintroduce a host bind for it: /tmp is
# cleared on reboot, and the daemon creates a missing bind source as a
# root-owned DIRECTORY that mosquitto cannot start over and the host user
# cannot delete.

# synch_skills — rebuild .claude/skills from .apk.skills before a mount.
# Serve-anyway: a failed synch does not block the mount. Exit 2 ≠ exit 1 —
# 2 means part of the source was unreadable, so the tree is short but looks
# intact.
synch_skills() {
    local script="$REPO_ROOT/.apk.skills/synch.py"
    if [ ! -f "$script" ]; then
        announce SKILLS_SYNCH_MISSING "{\"script\":\"$script\"}"
        return 0
    fi
    ( cd "$REPO_ROOT" && python3 "$script" --quiet )
    local status=$?
    announce SKILLS_SYNCHED "{\"script\":\"$script\",\"exit_code\":$status}"
    if [ $status -eq 2 ]; then
        log_error "skills synch could not READ part of .apk.skills/. It retired nothing, so"
        echo "  the mount is intact but may be short of what the tree holds. Mounting anyway"
        echo "  -- fix the permissions it named and re-run: npm run skills:synch"
    elif [ $status -ne 0 ]; then
        log_warn "skills synch exited $status; the mount may be stale. Mounting anyway."
    fi
    return 0
}

# prepare_for_up — what an up-shaped action owes before compose binds.
# Only for actions that BIND: down/ps/logs take no port, and evicting for them
# would stop the very stack being asked about.
prepare_for_up() {
    synch_skills
    if [ "${APKAUDIO_NO_KABOOM:-0}" = "1" ]; then
        log_warn "Port eviction disabled (--no-kaboom); compose will report any collision itself."
    else
        "$MANAGEMENT_SCRIPTS_DIR/free-ports.sh"
    fi
}
