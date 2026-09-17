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
#               restart-stack rebuild-stack down-stack
#    CONTAINER  restart rebuild exec logs inspect config-path
#    READERS    ps stats status disk host stacks staleness endpoints apps api
#               topics purpose page-titles
#    GATES      test-gates (pre-build) verify (post-mount)
#    MANAGER    manager
#    CLEANUP    free-ports clear-logs prune clean-build-cache
#               remove-other-containers remove-dead-containers
#    ☢️ NUKE     nuke -- the ONLY file here that deletes named volumes. Every
#               other cleanup verb is built around never touching them.
#    RAW        compose

set -o pipefail

# pwd -P: SRC/docker scripts is a symlink to ../K8, and the -d tests below walk
# `..` physically while a logical `cd .. && pwd` does not. Called through the
# link, the two disagreed and DOCKERS_DIR landed one level deep — which the
# manager compose file then baked into the container as APKAUDIO_REPO.
MANAGEMENT_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# APKAUDIO_REPO wins when set and valid; otherwise walk up. Dockerfile.manager
# COPYs this folder to /app, so inside the manager the walk lands outside the
# checkout (no compose files, no build context).
# DOCKTOR_DOCKERS_DIR names the stacks folder outright, for an estate laid out
# any other way. It is checked FIRST because it is the only answer a person gave.
# ⚠️ AN ESTATE IS NOT ALWAYS APK:PODS. A checkout that links DockTor beside
#    `<name>.pod/` folders (OneThing.Dockers/APPLICATION.pod/…) has neither
#    POD:APK nor APK:PODS, and the old fallback walked one rung too far — to the
#    checkout root, where every glob came back holding DockTor alone.
_docktor_parent="$(cd "$MANAGEMENT_SCRIPTS_DIR/../.." && pwd)"
_docktor_has_pods() {
    local candidate
    for candidate in "$1"/POD:* "$1"/*.pod; do
        [ -d "$candidate" ] && return 0
    done
    return 1
}
if [ -n "${DOCKTOR_DOCKERS_DIR:-}" ] && [ -d "$DOCKTOR_DOCKERS_DIR" ]; then
    DOCKERS_DIR="$(cd "$DOCKTOR_DOCKERS_DIR" && pwd -P)"
    REPO_ROOT="$(cd "$DOCKERS_DIR/.." && pwd)"
elif [ -n "${APKAUDIO_REPO:-}" ] && [ -d "$APKAUDIO_REPO/APK:PODS" ]; then
    REPO_ROOT="$APKAUDIO_REPO"
    DOCKERS_DIR="$REPO_ROOT/APK:PODS"
elif _docktor_has_pods "$_docktor_parent" \
     && [ ! -d "$_docktor_parent/POD:APK" ]; then
    DOCKERS_DIR="$_docktor_parent"
    REPO_ROOT="$(cd "$DOCKERS_DIR/.." && pwd)"
# DockTor filed INSIDE one of the pods (SUPPORT.pod/Docker.Backend.DockTor):
# its parent is a pod, and the estate is one rung further up. `*.pod` only —
# an APK:PODS checkout keeps the walk below, unchanged.
elif compgen -G "$_docktor_parent/../*.pod" >/dev/null \
     && [ "$(basename "$_docktor_parent")" != "${_docktor_parent%.pod}" ]; then
    DOCKERS_DIR="$(cd "$_docktor_parent/.." && pwd)"
    REPO_ROOT="$(cd "$DOCKERS_DIR/.." && pwd)"
else
    if [ -d "$MANAGEMENT_SCRIPTS_DIR/../../POD:APK" ]; then
        DOCKERS_DIR="$(cd "$MANAGEMENT_SCRIPTS_DIR/../.." && pwd)"
    elif [ -d "$MANAGEMENT_SCRIPTS_DIR/../../APK:PODS" ]; then
        DOCKERS_DIR="$(cd "$MANAGEMENT_SCRIPTS_DIR/../../APK:PODS" && pwd)"
    else
        DOCKERS_DIR="$(cd "$MANAGEMENT_SCRIPTS_DIR/../../.." && pwd)"
    fi
    # Invoked through a symlinked root name? Land on the real folder it names.
    if [ -L "$DOCKERS_DIR" ]; then
        DOCKERS_DIR="$(cd -P "$DOCKERS_DIR" && pwd)"
    fi
    REPO_ROOT="$(cd "$DOCKERS_DIR/.." && pwd)"
fi

# Exported, not just assigned: PROTOCOL:DEV:EMBER/docker-compose.yml and
# docker-compose.manager.yml interpolate ${APKAUDIO_REPO} and Ember spells it
# `:?` — unset is a hard refusal at interpolation.
export APKAUDIO_REPO="$REPO_ROOT"

# ── ESTATE_LAYOUT: `apk` (POD:*/<stack>/Docker/, the named arrays below) or
# `pods` (<name>.pod/<stack>/DOCKER/, no named arrays at all). In `pods` the
# stacks are DISCOVERED — see discovered_stacks() — because none of the ten
# names this file spells exists there, and a walk over missing files is ten
# compose errors that start nothing.
ESTATE_LAYOUT=apk
if ! compgen -G "$DOCKERS_DIR/POD:*" >/dev/null && compgen -G "$DOCKERS_DIR/*.pod" >/dev/null; then
    ESTATE_LAYOUT=pods
    # Exported so a container started from here (docker-compose.standalone.yml)
    # resolves the same folder: inside it, the walk from /app finds nothing.
    export DOCKTOR_DOCKERS_DIR="$DOCKERS_DIR"
    # The estate's own settings: `$DOCKERS_DIR/docktor.env`, KEY=VALUE lines,
    # `#` comments. Only DOCKTOR_* keys, and never over a value already in the
    # environment — a person typing a variable outranks a file. Read, not
    # sourced: nothing in it runs.
    if [ -f "$DOCKERS_DIR/docktor.env" ]; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            _line="${_line%%#*}"
            [[ "$_line" =~ ^[[:space:]]*(DOCKTOR_[A-Z0-9_]+)=(.*)$ ]] || continue
            _key="${BASH_REMATCH[1]}"
            _value="${BASH_REMATCH[2]}"
            _value="${_value%"${_value##*[![:space:]]}"}"
            _value="${_value#\"}"; _value="${_value%\"}"
            [ -n "${!_key+x}" ] || export "$_key=$_value"
        done < "$DOCKERS_DIR/docktor.env"
        unset _line _key _value
    fi
fi
unset -f _docktor_has_pods
unset _docktor_parent

# ── Compose files: <pod>/<stack>/Docker/<file>. The only place any of it is
# spelled. ⚠️ A wrong path does not raise — compose warns and carries on, so
# every stack reads as empty. Build contexts are repo-root-relative.
# ⚠️ AND THAT IS EXACTLY WHAT HAPPENED. The stacks moved down a rung into
#    POD:APK / POD:database / POD:databus / POD:protocols and these ten lines
#    kept the flat spellings, so ALL TEN named files that are not there. Nothing
#    said so, because nothing in this ecosystem treats a missing compose file as
#    an error: `up` mounted nothing and reported success, stacks.sh could not
#    match a DRIVEN path so every stack read `driven: no`, and the dashboard drew
#    the whole bench as stacks it cannot fix with a command to paste under each.
# SO EVERY PATH IS NOW A LIST, NEWEST SPELLING FIRST, and first_existing() takes
# the one that is on disk — the same shape the manager compose file below uses.
# A move costs a line at the top of a list instead of a silent empty bench.
first_existing() {
    local first="$1" candidate
    for candidate in "$@"; do
        [ -e "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    printf '%s' "$first"
}

# stack_dir <folder-name> — where a stack folder actually IS. The pods put
# every one of them under POD:APK / POD:database / POD:databus / POD:protocols,
# and a handful of names changed in the same move; this looks in the flat spot
# first (DockTor still lives there), then one rung down under any POD:.
# Prints the flat path when nothing matches, so a caller's error names what it
# wanted rather than an empty string.
stack_dir() {
    local want="$1" candidate
    [ -d "$DOCKERS_DIR/$want" ] && { printf '%s' "$DOCKERS_DIR/$want"; return 0; }
    for candidate in "$DOCKERS_DIR"/POD:*/"$want" "$DOCKERS_DIR"/*.pod/"$want"; do
        [ -d "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    printf '%s' "$DOCKERS_DIR/$want"
}

COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:database/DATABASE:server:SQL/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/DATABASE:server:SQL/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/Server:Storage:SQL database/Docker/docker-compose.yml")"
# THE REDUNDANT SQL SERVER — three Galera nodes behind SQL-Proxy. Every client
# of the database (Broker-SqlCapture, Storage-PHP) reaches it as sql-proxy:3306,
# so it mounts BEFORE core and mqtt. See APK:Documentation/🔍Audits/Cosmos DB.md.
SQLCLUSTER_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:database/DATABASE:cluster:SQL/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/DATABASE:cluster:SQL/Docker/docker-compose.yml")"
BAREMETAL_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:APK/APK:BareMetal/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/APK:BareMetal/Docker/docker-compose.yml")"
# Overridable so a hardware fixture can be pointed at; the hardware decision
# runs at source time, so that is the only way to test it.
BAREMETAL_HARDWARE_COMPOSE_FILE="${BAREMETAL_HARDWARE_COMPOSE_FILE:-$(first_existing \
    "$DOCKERS_DIR/POD:APK/APK:BareMetal/Docker/docker-compose.hardware.yml" \
    "$DOCKERS_DIR/APK:BareMetal/Docker/docker-compose.hardware.yml")}"
# NOT A COMPOSE FILE AND STILL LOAD-BEARING: test-gates.sh runs the node's own
# checks out of here, and a stale spelling turned the broker-candidate gate into
# `[Gate ABSENT]` — a gate that cannot find itself is a gate that stops testing
# and says so in a colour nobody stops for.
BAREMETAL_ROOT="$(first_existing \
    "$DOCKERS_DIR/POD:APK/APK:BareMetal/SRC" \
    "$DOCKERS_DIR/APK:BareMetal/SRC")"
MQTT_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:databus/DATABUS:Broker:MQTT/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/Server:Broker:MQTT/Docker/docker-compose.yml")"
# THE PORTAL STACK'S ROOT FILE IS THE BUS POD'S NOW. APK:audio:WebPortal became
# APK:web:Static (content only, its own container), and the file that declared
# Portal-Broker and `include:`d the four web stacks moved to the broker stack as
# docker-compose.portal-broker.yml. Same project, same containers.
PORTAL_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:databus/DATABUS:Broker:MQTT/Docker/docker-compose.portal-broker.yml" \
    "$DOCKERS_DIR/POD:APK/APK:audio:WebPortal/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/APK:audio:WebPortal/Docker/docker-compose.yml")"
# EVERY PLUGIN CONTAINER, by node role: APK:plugins:Build `include:`s each
# APK:plugin:* stack at the pod root. NOT in for_each_stack: nothing starts
# without COMPOSE_PROFILES naming a role, and the build is the whole plugin
# workspace — a verb that mounts "everything" should not also compile that.
# Reached by `compose.sh plugins …` and validated by verify.sh.
PLUGINS_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:APK/APK:plugins:Build/Docker/docker-compose.yml")"
NMOS_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:protocols/PROTOCOL:discovery:NMOS/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/Server:Discovery:NMOS/Docker/docker-compose.yml")"
AES70_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:protocols/PROTOCOL:DEV:AES70/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/PROTOCOL:DEV:AES70/Docker/docker-compose.yml")"
NETBOX_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:database/DATABASE:server:NETBOX/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/DATABASE:server:NETBOX/Docker/docker-compose.yml")"
EMBER_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:protocols/PROTOCOL:DEV:EMBER/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/PROTOCOL:DEV:EMBER/Docker/docker-compose.yml")"
# LOGGER STORAGE — owns the apk-audio-logs volume (APK:Documentation/LOGS) that
# every other stack mounts at /logs. The space in the folder name is real; every
# expansion of this path is quoted. THE TYPO IS ALSO A SPELLING: the folder was
# `DATABSE:volume:Log STORAGE` and is now `DATABASE:volume:Log STORAGE`, so both
# are listed rather than either being assumed corrected.
LOGGER_COMPOSE_FILE="$(first_existing \
    "$DOCKERS_DIR/POD:databus/DATABASE:volume:Log STORAGE/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/POD:databus/DATABSE:volume:Log STORAGE/Docker/docker-compose.yml" \
    "$DOCKERS_DIR/DATABSE:volume:Log STORAGE/Docker/docker-compose.yml")"
LOG_VOLUME_NAME="apk-audio-logs"

# ── DOCKTOR OWN PERSISTENT STORAGE. The same shape as the log volume above and
# for the same reason: a NAMED VOLUME whose bytes are a LOCAL FOLDER in the
# checkout, so `docker volume inspect` finds it by name and a person finds it
# with `ls`. An anonymous volume would hold the history where only docker can
# reach it, and a plain bind would not appear in the volume table this tool
# draws — the point of the tab is that the program storage is one of the
# volumes it is reporting on.
# ⚠️ THE COLONS ARE FINE HERE and nowhere near a bind: `driver_opts.device` is
#    a plain string to the local driver, which is why the log volume can name
#    `APK:Documentation/LOGS`. A compose `volumes:` SHORT FORM naming this path
#    would still split on the first colon — see the warning in
#    docker-compose.manager.yml.
# WHAT LIVES IN IT: volume-history.jsonl, the sample series the VOLUMES tab
# graphs. A series is only worth drawing if it outlives the container that
# wrote it, and /var/lib/docker is not somewhere a person can go and read it.
STORAGE_VOLUME_NAME="docktor-storage"
STORAGE_HOST_DIR="$REPO_ROOT/APK:Documentation/STORAGE/DockTor"
# Where docker-compose.manager.yml mounts it INSIDE the manager container. The
# scripts prefer this when it is a real mount, so the same code writes to the
# same bytes from the host and from inside the container.
STORAGE_MOUNT_DIR="/storage"
# A `pods` estate has no APK:Documentation, and `docktor-storage` is a
# host-wide name APK.audio's DockTor already binds — reusing it reads as a
# mismatch to both. Its own volume, in a folder the estate can gitignore.
if [ "$ESTATE_LAYOUT" = "pods" ]; then
    STORAGE_VOLUME_NAME="${DOCKTOR_STORAGE_VOLUME:-docktor-standalone-storage}"
    STORAGE_HOST_DIR="${DOCKTOR_STORAGE_DIR:-$DOCKERS_DIR/.docktor/storage}"
    export DOCKTOR_STORAGE_VOLUME="$STORAGE_VOLUME_NAME"
fi

GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; BLUE="\033[34m"
BOLD="\033[1m"; OFF="\033[0m"

log_info()  { echo -e "${BOLD}${GREEN}✓${OFF} $1"; }
log_warn()  { echo -e "${BOLD}${YELLOW}!${OFF} $1"; }
log_error() { echo -e "${BOLD}${RED}✗${OFF} $1"; }
log_step()  { echo -e "\n${BOLD}${BLUE}==> $1${OFF}"; }

# announce NAME [json] — one stdout line the bus can lift:
#     @EVENT PORT_EVICT_PROCESS {"port":8080,"pid":4412}
# K8:runner.py republishes @EVENT lines to
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

# ONE PROJECT FOR OURS (`apk-audio`): core, BareMetal, broker, the portal
# (web stacks), the plugins and the manager. nmos/aes70/netbox/ember keep their own — third-party source we
# drive but do not ship. Arrays stay separate because the stacks want opposite
# networking (bridge vs network_mode: host for multicast).
# ⚠️ Every named volume carries an explicit `name:`; a shared project would
#    otherwise repoint mariadb-data, broker-data and mqtt-exchange at empty
#    volumes. Do not drop one.
# ⚠️ `--remove-orphans` under a shared project deletes the other files'
#    containers. rebuild-all.sh and panic.sh omit it deliberately.
COMPOSE_SQLCLUSTER=("${COMPOSE_BASE[@]}" -f "$SQLCLUSTER_COMPOSE_FILE")
COMPOSE_CORE=("${COMPOSE_BASE[@]}" -f "$COMPOSE_FILE")
COMPOSE_NODE=("${COMPOSE_BASE[@]}" -f "$BAREMETAL_COMPOSE_FILE")
COMPOSE_MQTT=("${COMPOSE_BASE[@]}" -f "$MQTT_COMPOSE_FILE")
COMPOSE_PORTAL=("${COMPOSE_BASE[@]}" -f "$PORTAL_COMPOSE_FILE")
COMPOSE_PLUGINS=("${COMPOSE_BASE[@]}" -f "$PLUGINS_COMPOSE_FILE")
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
COMPOSE_LOGGER=("${COMPOSE_BASE[@]}" -f "$LOGGER_COMPOSE_FILE")

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

# ── THE 10 COMPOSE ARRAYS. All 9 stacks plus the manager are driven. The order
# below IS the dependency chain — compose cannot express depends_on across
# projects, so nothing else holds it. Pass `reverse` to anything tearing down:
#   logger FIRST, ahead of the manager — every other file declares the
#          apk-audio-logs volume `external: true`, and compose refuses an
#          external volume that does not exist yet. (The manager file declares
#          it non-external so the manager can always start; see that file.)
#   sqlcluster next — the SQL cluster; core's PHP tier and mqtt's sql-capture
#          both open sessions against sql-proxy, so it is up before either
#   core   next  — publishes 1883, the broker everyone else names
#   mqtt   next  — its sql-capture opens a session against sql-proxy
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
# ⚠️ EVERY SPELLING, AND THE LAST ONE IS THE WALK. Both of the two this file
#    used to carry were wrong at once — `APK:docktor` is not the folder (it is
#    `APK:Docktor`), and the relative fallback counted one `..` too many (K8/ is
#    directly under the stack root, so `../../Docker` is APK:PODS/Docker). The
#    variable therefore named a file that does not exist, and NOTHING SAID SO:
#    · stacks.sh puts this path in its DRIVEN set, so DockTor's own row read
#      `driven: no` — the dashboard drew it in the band for stacks nothing here
#      can fix, with a command to paste, beside a button it should have had.
#    · manager_compose_value() read an empty file, so MANAGER_CONTAINER fell
#      back to the literal `DockTor` and MANAGER_IMAGE to `docktor:local`.
#    · COMPOSE_MANAGER pointed `-f` at nothing, so every verb that mounts the
#      manager would have failed on the compose file rather than on anything
#      real.
#    A missing file here is silent by construction — compose warns, awk reads
#    nothing, a realpath still compares — which is why it is worth four
#    candidates and this comment.
for _candidate in \
    "$DOCKERS_DIR/APK:Docktor/Docker/docker-compose.manager.yml" \
    "$DOCKERS_DIR/APK:docktor/Docker/docker-compose.manager.yml" \
    "$DOCKERS_DIR/Docktor/Docker/docker-compose.manager.yml" \
    "$MANAGEMENT_SCRIPTS_DIR/../Docker/docker-compose.manager.yml" \
    "$MANAGEMENT_SCRIPTS_DIR/../../Docker/docker-compose.manager.yml"; do
    if [ -f "$_candidate" ]; then
        MANAGER_COMPOSE_FILE="$(cd "$(dirname "$_candidate")" && pwd)/$(basename "$_candidate")"
        break
    fi
done
unset _candidate
# Absent everywhere: keep the first spelling so the error names the path it
# wanted rather than an empty `-f`.
[ -z "${MANAGER_COMPOSE_FILE:-}" ] \
    && MANAGER_COMPOSE_FILE="$DOCKERS_DIR/APK:Docktor/Docker/docker-compose.manager.yml"
# A `pods` estate builds DockTor from this repository alone, under its own name
# and port. See docker-compose.standalone.yml.
# ⚠️ INSIDE THE CONTAINER there is no Docker/ beside K8/ (the image copies
#    K8, SRC and bin only), so the bound checkout is searched too. Missing it
#    there is not cosmetic: MANAGER_CONTAINER falls back to `DockTor` — another
#    estate's manager — and panic.sh would spare that one and kill this one.
if [ "$ESTATE_LAYOUT" = "pods" ]; then
    for _candidate in "$MANAGEMENT_SCRIPTS_DIR/../Docker/docker-compose.standalone.yml" \
                      "$DOCKERS_DIR"/*/Docker/docker-compose.standalone.yml \
                      "$DOCKERS_DIR"/*.pod/*/Docker/docker-compose.standalone.yml; do
        if [ -f "$_candidate" ]; then
            MANAGER_COMPOSE_FILE="$(cd "$(dirname "$_candidate")" && pwd)/$(basename "$_candidate")"
            break
        fi
    done
    unset _candidate
    # The APK.audio manager file sits beside it and declares `apk-audio`; in this
    # layout nothing drives it, so the readers are told to look past it.
    export DOCKTOR_IGNORE_COMPOSE="$(dirname "$MANAGER_COMPOSE_FILE")/docker-compose.manager.yml"
fi

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

# ── THE ADDRESS DOCKTOR ANSWERS ON, read off its compose file rather than
# typed. It was written `http://127.0.0.1:8765/` in up.sh, rebuild-all.sh,
# manager.sh and cli.py — four copies of a port that is declared in exactly one
# place, three rungs from anything that would notice them disagreeing.
MANAGER_PORT="$(manager_compose_value APK_MANAGER_PORT)"
[ -z "$MANAGER_PORT" ] && MANAGER_PORT=8765
MANAGER_URL="http://localhost:$MANAGER_PORT/"

# manager_answering [seconds] — is a DockTor serving on that port right now?
# /api/health and not a TCP probe: the port is answered by whatever holds it,
# and "something is listening" is not the question any caller here is asking.
manager_answering() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m "${1:-2}" "${MANAGER_URL}api/health" >/dev/null 2>&1
    else
        python3 -c "import sys,urllib.request;urllib.request.urlopen('${MANAGER_URL}api/health',timeout=${1:-2})" \
            >/dev/null 2>&1
    fi
}

# open_manager_site [seconds] — raise the dashboard AS SOON AS IT ANSWERS.
# THE POINT IS THE MOMENT. up.sh and rebuild-all.sh each opened a browser on
# their LAST line, which on a clean rebuild is ten minutes after the tool that
# would have shown you the build was up — and the one thing a person wants
# while a bench rebuilds is the page that draws it. DockTor is mounted first
# now; this is called the moment that mount returns, and it waits for the
# server inside the container to bind before spending the click.
# ONCE PER RUN, AND THE RUN IS THE PROCESS TREE: APKAUDIO_SITE_OPENED is
# EXPORTED, so rebuild-all.sh → up-stack.sh → here cannot open three tabs.
#   APKAUDIO_NO_OPEN=1   never open anything (CI, ssh, a second screen)
# NEVER FROM INSIDE THE CONTAINER: there is no browser there, and asking for one
# is how a service exits two seconds after it starts.
open_manager_site() {
    local waited=0 limit="${1:-45}"
    [ "${APKAUDIO_NO_OPEN:-0}" = "1" ] && return 0
    [ "${APKAUDIO_SITE_OPENED:-0}" = "1" ] && return 0
    [ -f /.dockerenv ] && return 0
    export APKAUDIO_SITE_OPENED=1

    while [ "$waited" -lt "$limit" ]; do
        if manager_answering 2; then
            # A DISPLAY IS NOT GUARANTEED and its absence is not a failure: over
            # ssh the URL is the whole answer, and a webbrowser call there opens
            # a text browser in the middle of the build log.
            if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
                log_info "DockTor is up — opening $MANAGER_URL"
                python3 -c "import webbrowser; webbrowser.open('$MANAGER_URL')" 2>/dev/null \
                    || xdg-open "$MANAGER_URL" >/dev/null 2>&1 \
                    || log_warn "Could not raise a browser. It is at $MANAGER_URL"
            else
                log_info "DockTor is up at $MANAGER_URL (no display here, so nothing was opened)"
            fi
            announce MANAGER_SITE_OPENED "{\"url\":\"$MANAGER_URL\",\"waited_seconds\":$waited}"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # NOT AN ERROR AND NOT SILENT. The mount may still be starting, and the
    # caller is usually in the middle of building eight more stacks.
    log_warn "DockTor did not answer on $MANAGER_URL within ${limit}s; carrying on."
    announce MANAGER_SITE_TIMEOUT "{\"url\":\"$MANAGER_URL\",\"waited_seconds\":$limit}"
    return 0
}

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
    if [ "$ESTATE_LAYOUT" = "pods" ]; then
        _for_each_discovered_stack "$@"
        return $?
    fi
    local direction="$1"; shift
    local worst=0 status
    local -a order

    # ⚠️ DOCKTOR IS FIRST UP AND LAST DOWN, and neither is a preference:
    #    · FIRST, because it is the only stack that can SHOW you the other
    #      nine mounting. Mounted second (it was, behind the logger) the
    #      dashboard arrived after the thing it exists to watch.
    #    · LAST DOWN, for the same reason read backwards: the tool that reports
    #      the teardown should not be the first thing to stop reporting.
    # The logger moving to second is safe and was checked: every other stack
    # declares apk-audio-logs `external: true` and needs LOGGER STORAGE first,
    # but docker-compose.manager.yml deliberately declares it itself — the
    # manager is what brings the logger back, so it must be able to start on a
    # bench where that volume does not exist yet.
    if [ "$direction" = "reverse" ]; then
        order=(node netbox ember aes70 nmos portal mqtt core sqlcluster logger docktor)
    else
        order=(docktor logger sqlcluster core mqtt portal nmos aes70 ember netbox node)
    fi

    # Name-indexed lookup, not an if-chain: an unmatched name must ERROR, and
    # an `else` would turn a typo into a silent fall-through to the last array.
    local -a compose
    for stack in "${order[@]}"; do
        if { [ "$stack" = "docktor" ] || [ "$stack" = "manager" ]; } && [ -f "/.dockerenv" ]; then
            log_warn "Skipping '$stack' (running inside manager container)"
            continue
        fi
        # APKAUDIO_SKIP_STACKS — names this walk leaves alone, space separated.
        # ONE CALLER AND ONE REASON: rebuild-all.sh builds and mounts DockTor
        # BEFORE it builds anything else, so the two passes after that must not
        # do it again — a second --no-cache build of the manager is minutes, and
        # the second `up` would swap the dashboard out from under the page it
        # just opened.
        if [[ " ${APKAUDIO_SKIP_STACKS:-} " == *" $stack "* ]]; then
            log_warn "Skipping '$stack' (APKAUDIO_SKIP_STACKS)"
            continue
        fi
        echo -e "\n── ${stack} ──"
        case "$stack" in
            docktor|manager) compose=("${COMPOSE_MANAGER[@]}");;
            logger) compose=("${COMPOSE_LOGGER[@]}");;
            sqlcluster) compose=("${COMPOSE_SQLCLUSTER[@]}");;
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

        # THE SITE OPENS THE MOMENT THE THING THAT SERVES IT IS UP, which is
        # here and nowhere else: this is the one place that knows a docktor
        # mount just succeeded, and the eight stacks after it take minutes.
        # Only for an `up` — a `build` produces no server and a `down` is the
        # opposite of an invitation.
        if [ $status -eq 0 ] && [ "$1" = "up" ] \
           && { [ "$stack" = "docktor" ] || [ "$stack" = "manager" ]; }; then
            open_manager_site
        fi
    done
    return $worst
}

# discovered_stacks — every stack root in a `pods` estate, one per line as
# `<stack>\t<compose file>`, in mount order: pods in DOCKTOR_POD_ORDER (space
# separated, `.pod` optional — usually set in the estate's docktor.env, since
# the order is a fact about its stacks, not about this tool), then any pod it
# does not name, alphabetically; stacks alphabetically inside a pod. DockTor's own file is left out — for_each_stack puts it first.
# A compose file with no top-level `name:` is an overlay, not a stack root.
discovered_stacks() {
    DOCKERS="$DOCKERS_DIR" MANAGER="$MANAGER_COMPOSE_FILE" ORDER="${DOCKTOR_POD_ORDER:-}" \
    python3 - <<'PY'
import glob, os, re
dockers = os.environ["DOCKERS"]
manager = os.path.realpath(os.environ.get("MANAGER") or "")
words = os.environ.get("ORDER", "").split()
order = [w if w.endswith(".pod") else w + ".pod" for w in words if w]
pods = sorted((os.path.basename(p) for p in glob.glob(os.path.join(dockers, "*.pod"))),
              key=lambda n: (order.index(n) if n in order else len(order), n.lower()))
project = re.compile(r'^name:', re.M)
for pod in pods:
    for folder in sorted(glob.glob(os.path.join(dockers, pod, "*")), key=str.lower):
        for sub in ("DOCKER", "Docker"):
            path = os.path.join(folder, sub, "docker-compose.yml")
            if not os.path.isfile(path) or os.path.realpath(path) == manager:
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                if project.search(handle.read()):
                    print("%s\t%s" % (os.path.basename(folder), path))
            break
PY
}

# ensure_external_networks <compose file>... — create every network a file
# declares `external: true` that this host does not have yet. Compose refuses
# to start a stack on a missing external network and will not create one, so
# on a fresh machine NOTHING mounts until somebody runs `docker network create`
# by hand. Only for `up`-shaped verbs; never removes anything.
ensure_external_networks() {
    local network
    python3 - "$@" <<'PY' | sort -u | while IFS= read -r network; do
import re, sys
for path in sys.argv[1:]:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    inside, key, name, external = False, None, None, False
    def flush():
        if key and external:
            print(name or key)
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            if inside:
                flush()
            inside, key, name, external = line.startswith("networks:"), None, None, False
            continue
        if not inside:
            continue
        match = re.match(r'^  ([^\s#][^:]*):\s*$', line)
        if match:
            flush()
            key, name, external = match.group(1).strip(), None, False
            continue
        match = re.match(r'^\s{4,}external:\s*(\S+)', line)
        if match:
            external = match.group(1).strip("\"'").lower() == "true"
            continue
        match = re.match(r'^\s{4,}name:\s*["\']?([^"\'\s#]+)', line)
        if match:
            name = match.group(1)
    if inside:
        flush()
PY
        [ -n "$network" ] || continue
        docker network inspect "$network" >/dev/null 2>&1 && continue
        log_warn "External network '$network' is missing -- creating it."
        docker network create "$network" >/dev/null \
            || log_error "Could not create network '$network'; compose will say what that stops."
    done
    return 0
}

# _for_each_discovered_stack — for_each_stack for a `pods` estate. Same
# contract: `reverse` tears down, the worst exit code wins, DockTor is first up
# and last down, APKAUDIO_SKIP_STACKS is honoured.
_for_each_discovered_stack() {
    local direction="$1"; shift
    local worst=0 status stack file
    local -a names=() files=() order=()
    while IFS=$'\t' read -r stack file; do
        [ -n "$file" ] || continue
        names+=("$stack"); files+=("$file")
    done < <(discovered_stacks)

    if [ "$1" = "up" ]; then
        ensure_external_networks "${files[@]}"
    fi

    local i
    if [ "$direction" = "reverse" ]; then
        for (( i=${#names[@]}-1; i>=0; i-- )); do order+=("$i"); done
        order+=(docktor)
    else
        order=(docktor)
        for (( i=0; i<${#names[@]}; i++ )); do order+=("$i"); done
    fi

    for i in "${order[@]}"; do
        if [ "$i" = "docktor" ]; then
            stack=docktor
            if [ -f "/.dockerenv" ]; then
                log_warn "Skipping '$stack' (running inside manager container)"
                continue
            fi
        else
            stack="${names[$i]}"
        fi
        if [[ " ${APKAUDIO_SKIP_STACKS:-} " == *" $stack "* ]]; then
            log_warn "Skipping '$stack' (APKAUDIO_SKIP_STACKS)"
            continue
        fi
        echo -e "\n── ${stack} ──"
        if [ "$i" = "docktor" ]; then
            "${COMPOSE_MANAGER[@]}" "$@"
        else
            "${COMPOSE_BASE[@]}" -f "${files[$i]}" "$@"
        fi
        status=$?
        [ $status -ne 0 ] && worst=$status
        if [ $status -eq 0 ] && [ "$1" = "up" ] && [ "$i" = "docktor" ]; then
            open_manager_site
        fi
    done
    return $worst
}

# compose_for_stack <stack directory name> — fill STACK_COMPOSE with ONE
# stack's compose command (up-stack.sh's lookup, behind the dashboard's
# per-stack fix button; up.sh would rebuild the other eight instead).
# The name is the directory under APK:PODS/ — what stacks.sh prints — and is
# derived from the compose paths, so a renamed folder needs no edit here.
# Arrays are copied whole, so COMPOSE_NODE keeps its hardware overlay.
# Returns 1 with STACK_COMPOSE empty for an unknown name: callers must refuse
# rather than default to remounting something nobody asked for.
compose_for_stack() {
    local want="$1" entry name file dir
    STACK_COMPOSE=()
    for entry in \
        "COMPOSE_SQLCLUSTER|$SQLCLUSTER_COMPOSE_FILE" \
        "COMPOSE_CORE|$COMPOSE_FILE" \
        "COMPOSE_NODE|$BAREMETAL_COMPOSE_FILE" \
        "COMPOSE_MQTT|$MQTT_COMPOSE_FILE" \
        "COMPOSE_PORTAL|$PORTAL_COMPOSE_FILE" \
        "COMPOSE_NMOS|$NMOS_COMPOSE_FILE" \
        "COMPOSE_AES70|$AES70_COMPOSE_FILE" \
        "COMPOSE_NETBOX|$NETBOX_COMPOSE_FILE" \
        "COMPOSE_EMBER|$EMBER_COMPOSE_FILE" \
        "COMPOSE_LOGGER|$LOGGER_COMPOSE_FILE" \
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

    # THE POD-ROOT STACKS HAVE NO ARRAY, AND MUST NOT NEED ONE. Every container
    # is its own repository at APK:PODS/POD:<pod>/<Stack>/ (Docker/ + SRC/), and
    # there are thirty of them — a hand-kept array per stack is the table that
    # goes stale the day a plugin is split. Without this, stacks.sh listed
    # APK:web:Gateway and up-stack.sh answered "No compose file … is named by the
    # stack" for the very name it printed (2026-09-17).
    # Only the stack's own docker-compose.yml: an overlay (*.host.yml) is a choice
    # the caller makes, not something a name implies.
    local found
    # `DOCKER/` and `*.pod` too: an estate that spells the compose folder in
    # capitals and its pods as `<name>.pod` is the same shape with other words.
    for found in "$DOCKERS_DIR"/POD:*/"$want"/Docker/docker-compose.yml \
                 "$DOCKERS_DIR"/"$want"/Docker/docker-compose.yml \
                 "$DOCKERS_DIR"/*.pod/"$want"/DOCKER/docker-compose.yml \
                 "$DOCKERS_DIR"/*.pod/"$want"/Docker/docker-compose.yml \
                 "$DOCKERS_DIR"/"$want"/DOCKER/docker-compose.yml; do
        [ -f "$found" ] || continue
        STACK_COMPOSE=("${COMPOSE_BASE[@]}" -f "$found")
        STACK_COMPOSE_FILE="$found"
        # A PLUGIN STACK DECLARES ITS SERVICE UNDER A NODE ROLE (profiles:), so a
        # bare `up` would start nothing and report success. Naming the stack IS
        # the request for it: switch on that file's own roles, unless the caller
        # already chose some.
        if [ -z "${COMPOSE_PROFILES:-}" ]; then
            local roles
            roles="$(grep -oE '^[[:space:]]*profiles:[[:space:]]*\[[^]]*\]' "$found" \
                     | sed -E 's/.*\[//; s/\]//; s/[[:space:]"'"'"']//g' | tr '\n' ',' | sed 's/,$//')"
            [ -n "$roles" ] && export COMPOSE_PROFILES="$roles"
        fi
        return 0
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
    # DOCKTOR_APK_INTEGRATIONS=off: .apk.skills is APK.audio's; nothing to synch.
    case "${DOCKTOR_APK_INTEGRATIONS:-on}" in off|0|false|no) return 0 ;; esac
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

# ensure_log_storage — bring LOGGER STORAGE up unless the log volume already
# exists. For the verbs that mount ONE stack or ONE container (up-stack.sh,
# rebuild.sh): for_each_stack already puts the logger first, but a single-stack
# mount on a fresh bench would otherwise fail on "external volume
# apk-audio-logs not found". Never exits; a failure is said and left to compose.
ensure_log_storage() {
    # No LOGGER STORAGE in this estate (a `pods` layout): nothing to bring up.
    [ -f "$LOGGER_COMPOSE_FILE" ] || return 0
    if docker volume inspect "$LOG_VOLUME_NAME" >/dev/null 2>&1; then
        return 0
    fi
    log_warn "Log volume $LOG_VOLUME_NAME is missing -- mounting LOGGER STORAGE first."
    "${COMPOSE_LOGGER[@]}" up -d \
        || log_error "LOGGER STORAGE did not come up; compose will name the missing volume below."
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

# clean_build_cache [what] — the sweep every build path ends with. `what` is
# only the word that goes in the log line and the event.
# ⚠️ IT RUNS AFTER A BUILD SUCCEEDS AND NOWHERE ELSE. After a FAILED build the
#    cache is the half-finished work the next attempt resumes from, so throwing
#    it away turns one broken build into two slow ones.
# THE DEFAULT IS THE DANGLING HALF: the layers this build superseded go, the
# layers the next build would reuse stay. Two knobs, both read here so no build
# script spells them:
#   APKAUDIO_BUILD_CACHE_CLEAN=off   leave the cache alone entirely
#   APKAUDIO_BUILD_CACHE_CLEAN=all   every byte — slow next build, empty disk
# NEVER NON-ZERO. A daemon that would not prune is not a reason to call a good
# image bad, and this is called after the build has already been reported.
clean_build_cache() {
    local what="${1:-build}"
    case "${APKAUDIO_BUILD_CACHE_CLEAN:-dangling}" in
        off|no|0|keep)
            log_warn "Build cache left in place (APKAUDIO_BUILD_CACHE_CLEAN=${APKAUDIO_BUILD_CACHE_CLEAN})."
            return 0
            ;;
        all|-a|--all)
            log_step "Cleaning the build cache after $what (ALL of it)..."
            "$MANAGEMENT_SCRIPTS_DIR/clean-build-cache.sh" --all \
                || log_warn "Build cache clean reported a problem; $what itself was fine."
            ;;
        *)
            log_step "Cleaning the build cache after $what..."
            "$MANAGEMENT_SCRIPTS_DIR/clean-build-cache.sh" \
                || log_warn "Build cache clean reported a problem; $what itself was fine."
            ;;
    esac
    return 0
}
