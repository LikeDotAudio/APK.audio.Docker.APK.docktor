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
if [ -n "${APKAUDIO_REPO:-}" ] && [ -d "$APKAUDIO_REPO/PODS" ]; then
    REPO_ROOT="$APKAUDIO_REPO"
    DOCKERS_DIR="$REPO_ROOT/PODS"
elif [ -n "${APKAUDIO_REPO:-}" ] && [ -d "$APKAUDIO_REPO/APK:PODS" ]; then
    REPO_ROOT="$APKAUDIO_REPO"
    DOCKERS_DIR="$REPO_ROOT/APK:PODS"
else
    if [ -d "$MANAGEMENT_SCRIPTS_DIR/../../POD:THIN" ] || [ -d "$MANAGEMENT_SCRIPTS_DIR/../../POD:APK_THIN" ]; then
        DOCKERS_DIR="$(cd "$MANAGEMENT_SCRIPTS_DIR/../.." && pwd)"
    elif [ -d "$MANAGEMENT_SCRIPTS_DIR/../../PODS" ]; then
        DOCKERS_DIR="$(cd "$MANAGEMENT_SCRIPTS_DIR/../../PODS" && pwd)"
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

# ── Compose files: <pod>/<stack>/Docker/<file>. The only place any of it is
# spelled. ⚠️ A wrong path does not raise — compose warns and carries on, so
# every stack reads as empty. Build contexts are repo-root-relative.
# ⚠️ AND THAT IS EXACTLY WHAT HAPPENED. The stacks moved down a rung into
#    POD:APK_THIN / POD:database / POD:databus / POD:protocols and these ten lines
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

# stack_dir <folder-name> — where a stack folder actually IS under APK:PODS.
# Dynamically finds the folder regardless of pod nesting depth.
stack_dir() {
    local want="$1" found
    if [ -d "$DOCKERS_DIR/$want" ]; then
        printf '%s' "$DOCKERS_DIR/$want"
        return 0
    fi
    found="$(find "$DOCKERS_DIR" -maxdepth 4 -type d -name "$want" 2>/dev/null | head -n 1)"
    if [ -n "$found" ]; then
        printf '%s' "$found"
        return 0
    fi
    printf '%s' "$DOCKERS_DIR/$want"
}

# stack_compose_file <stack-name> [compose-filename]
# Dynamically resolves a compose file for any stack.
stack_compose_file() {
    local want="$1" file="${2:-}" sdir
    sdir="$(stack_dir "$want")"
    if [ -n "$file" ]; then
        if [ -f "$sdir/Docker/$file" ]; then printf '%s' "$sdir/Docker/$file"; return 0; fi
        if [ -f "$sdir/$file" ]; then printf '%s' "$sdir/$file"; return 0; fi
    else
        if [ -f "$sdir/Docker/docker-compose.yml" ]; then printf '%s' "$sdir/Docker/docker-compose.yml"; return 0; fi
        if [ -f "$sdir/docker-compose.yml" ]; then printf '%s' "$sdir/docker-compose.yml"; return 0; fi
        local cand
        cand="$(find "$sdir" -maxdepth 2 -type f -name "docker-compose*.yml" 2>/dev/null | head -n 1)"
        if [ -n "$cand" ]; then printf '%s' "$cand"; return 0; fi
    fi
    return 1
}

# Dynamically resolve legacy stack variables
SQLCLUSTER_COMPOSE_FILE="$(stack_compose_file "DATABASE:server:SQL")"
COMPOSE_FILE="$SQLCLUSTER_COMPOSE_FILE"
BAREMETAL_COMPOSE_FILE="$(stack_compose_file "BareMetal")"
BAREMETAL_HARDWARE_COMPOSE_FILE="${BAREMETAL_HARDWARE_COMPOSE_FILE:-$(stack_compose_file "BareMetal" "docker-compose.hardware.yml")}"
BAREMETAL_ROOT="$(stack_dir "BareMetal")/SRC"
MQTT_COMPOSE_FILE="$(stack_compose_file "DATABUS:Broker:MQTT")"
PORTAL_COMPOSE_FILE="$(stack_compose_file "DATABUS:Broker:MQTT" "docker-compose.portal-broker.yml")"
PLUGINS_COMPOSE_FILE="$(stack_compose_file "discovery")"
[ -z "$PLUGINS_COMPOSE_FILE" ] && PLUGINS_COMPOSE_FILE="$(stack_compose_file "plugins:Build")"
# ── POD:protocols IS ONE STACK OF THREE CONTAINERS. Its pod-root compose file
# `include:`s the three below, and IT is what for_each_stack walks. The three
# keep their own variables because `compose.sh nmos`, verify.sh and
# panic-reboot.sh all name them, and because each is still mountable on its own
# (every one declares `name: protocols`, so it lands in the pod's project).
PROTOCOLS_COMPOSE_FILE="$(stack_compose_file "POD:protocols")"
NMOS_COMPOSE_FILE="$(stack_compose_file "PROTOCOL:discovery:NMOS")"
AES70_COMPOSE_FILE="$(stack_compose_file "PROTOCOL:DEV:AES70")"
NETBOX_COMPOSE_FILE="$(stack_compose_file "DATABASE:server:NETBOX")"
EMBER_COMPOSE_FILE="$(stack_compose_file "PROTOCOL:DEV:EMBER")"
LOGGER_COMPOSE_FILE="$(stack_compose_file "DATABASE:volume:Log STORAGE")"
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
if [ -d "$REPO_ROOT/Documentation/STORAGE/DockTor" ] || [ ! -d "$REPO_ROOT/APK:Documentation/STORAGE/DockTor" ]; then
    STORAGE_HOST_DIR="$REPO_ROOT/Documentation/STORAGE/DockTor"
else
    STORAGE_HOST_DIR="$REPO_ROOT/APK:Documentation/STORAGE/DockTor"
fi
# Where docker-compose.manager.yml mounts it INSIDE the manager container. The
# scripts prefer this when it is a real mount, so the same code writes to the
# same bytes from the host and from inside the container.
STORAGE_MOUNT_DIR="/storage"

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
# Dynamically register stacks from docktor.json
eval "$(python3 "$MANAGEMENT_SCRIPTS_DIR/config_helper.py" bash_eval apk-audio "$DOCKERS_DIR")"

# THE NODE'S ROLE, AND THE DEFAULT THAT WAS DOCUMENTED BUT NEVER WRITTEN.
# A terminal node declares its ROLE, not its plugins (APK:discovery/README.md
# "Node roles"): every plugin container sits behind a `profiles:` naming its
# role, so an EMPTY role list selects NO profile and starts nothing but the one
# profile-less service, DESKTOP_MONITOR. Compose still exits 0 — it did
# everything it was asked — which is how `✅ APK:discovery is mounted.` came to
# be printed over an APK-Discovery-Engine that was never created, and why
# stacks.sh then drew the whole stack as `idle` rather than as a fault.
# AN EXPLICIT COMPOSE_PROFILES WINS, so the compose-native way of saying it
# still works and stacks.sh reports the same set that actually ran. Otherwise
# the README's third row, "the lot".
#     APKAUDIO_PLUGIN_ROLES=discovery,l2 ./up-stack.sh 'APK:discovery'
# THE THREE OPT-INS ARE DELIBERATELY NOT IN THE DEFAULT — each needs a value
# before its container does anything: `switches` (APK_NETGEAR_HOST /
# APK_TRENDNET_HOST), `netbox-sync` (NETBOX_API_TOKEN_WRITE) and `puck` (a
# SpaceNavigator plugged in). Neither is `build`: those two services exist to
# be BUILT, and their `command: ["true"]` would leave two exited containers
# behind every `up`.
export APKAUDIO_PLUGIN_ROLES="${APKAUDIO_PLUGIN_ROLES:-${COMPOSE_PROFILES:-discovery,l2,sound,control,vendors,instruments}}"
for _apk_role in ${APKAUDIO_PLUGIN_ROLES//,/ }; do COMPOSE_PLUGINS+=(--profile "$_apk_role"); done
unset _apk_role

# NMOS conformance harness (nmos-testing + the facade that depends on it) is
# behind `profiles: ["conformance"]` — 732 MB of that stack's 1,087, off by
# default. Space-separated, unquoted, so a second profile costs no code:
#     APK_NMOS_PROFILES=conformance ./up.sh
# ⚠️ BOTH ARRAYS, and that is not belt and braces: COMPOSE_PROTOCOLS is what
#    for_each_stack mounts (the pod root includes the NMOS file), COMPOSE_NMOS is
#    what `compose.sh nmos` and verify.sh reach for. A profile added to only one
#    of them is a conformance suite that comes up under `up.sh` and is invisible
#    to `compose.sh nmos ps`, or the reverse.
if [ -n "${APK_NMOS_PROFILES:-}" ]; then
    for _apk_nmos_profile in ${APK_NMOS_PROFILES}; do
        COMPOSE_NMOS+=(--profile "$_apk_nmos_profile")
        COMPOSE_PROTOCOLS+=(--profile "$_apk_nmos_profile")
    done
    unset _apk_nmos_profile
fi

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

# ── CONTAINERS THIS ECOSYSTEM STARTED THAT COMPOSE CANNOT SEE.
# ⚠️ `docker compose down` STOPS ONLY WHAT A COMPOSE FILE DECLARES, and that is
#    not the whole bench any more. Node-BareMetal's instrument launcher
#    (POD:APK_THICK/APK:BareMetal/SRC/Baremetal:Manager/instrument_launcher.py)
#    creates a container PER DISCOVERED INSTRUMENT straight through
#    /var/run/docker.sock. Those containers carry `apk.audio.*` labels and NO
#    `com.docker.compose.project` at all, so every compose verb in this folder
#    walks straight past them — which is how "🛑 Stop All Containers" came to
#    leave 44 running and how the bench then looked like something was
#    restarting them behind a watchdog that was switched off.
# THEY ALSO RESTART THEMSELVES, TWICE OVER, and neither is DockTor's doing:
#   · the launcher gives every one `RestartPolicy: unless-stopped`, so the
#     DAEMON brings a killed one back (instrument_launcher.py:212-215);
#   · each instrument worker republishes presence every 10 s, and any record
#     whose status is not `running` is re-launched on the next message
#     (instrument_launcher.py:489). `docker stop` alone therefore does not hold
#     WHILE NODE-BAREMETAL IS UP — which is why this is called AFTER the compose
#     walk has already taken the node down, and never before it.
# STOP, NOT REMOVE. `unless-stopped` means a stopped container stays stopped
# across a daemon restart, and leaving it in place is what lets the launcher
# ADOPT it on the way back up (instrument_launcher.py:589) instead of building
# a replacement.
# THE SELECTOR IS THE LABEL THE LAUNCHER SETS, never a name pattern: the names
# are slugs built from whatever VISA/mDNS handed over, and a `*inst*` glob would
# be a promise about strangers' names as much as ours.
APKAUDIO_UNMANAGED_LABEL="${APKAUDIO_UNMANAGED_LABEL:-apk.audio.managed_by=BareMetal-Manager}"

# stop_unmanaged_containers [--dry-run] — stop every running container carrying
# APKAUDIO_UNMANAGED_LABEL. Never fails the caller: a teardown that already
# stopped the stacks must not report failure because one instrument was gone by
# the time we asked. Prints nothing and announces nothing when there are none —
# the ordinary case on a bench with no instruments on it.
stop_unmanaged_containers() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    local -a names=()
    mapfile -t names < <(docker ps --filter "label=$APKAUDIO_UNMANAGED_LABEL" \
        --format '{{.Names}}' 2>/dev/null)
    [ ${#names[@]} -eq 0 ] && return 0

    log_step "Stopping ${#names[@]} container(s) compose does not declare (label $APKAUDIO_UNMANAGED_LABEL)"
    printf '   • %s\n' "${names[@]}"
    if [ $dry -eq 1 ]; then
        log_warn "--dry-run: nothing stopped."
        return 0
    fi
    docker stop "${names[@]}" >/dev/null 2>&1 || true
    announce UNMANAGED_STOPPED "{\"label\":\"$APKAUDIO_UNMANAGED_LABEL\",\"count\":${#names[@]}}"
    log_info "Stopped ${#names[@]} launcher-created container(s)."
    return 0
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

    # ⚠️ DOCKTOR IS FIRST UP AND LAST DOWN, and neither is a preference:
    #    · FIRST, because it is the only stack that can SHOW you the other
    #      stacks mounting.
    #    · MQTT MOSQUITTO (DATABUS:Broker:MQTT) IS SECOND UP (FIRST AFTER DOCKTOR),
    #      so the central message bus is alive before any storage, baremetal,
    #      or protocol services attempt to announce or connect.
    #    · LAST DOWN, for the same reason read backwards: the tool that reports
    #      the teardown should not be the first thing to stop reporting, and the
    #      bus remains available for teardown telemetry until right before DockTor.
    if [ "$direction" = "reverse" ]; then
        order=("${DOCKTOR_STACKS_REVERSE[@]}")
    else
        order=("${DOCKTOR_STACKS_FORWARD[@]}")
    fi

    # Name-indexed lookup, not an if-chain: an unmatched name must ERROR, and
    # an `else` would turn a typo into a silent fall-through to the last array.
    local -a compose
    for stack in "${order[@]}"; do
        if { [ "$stack" = "docktor" ] || [ "$stack" = "manager" ] || [ "$stack" = "APK:Docktor" ]; } && [ -f "/.dockerenv" ]; then
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
        if compose_for_stack "$stack"; then
            compose=("${STACK_COMPOSE[@]}")
        else
            log_error "for_each_stack: no such stack '$stack'"
            worst=2
            continue
        fi
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

# apply_stack_profiles — put THIS stack's `--profile` flags on STACK_COMPOSE.
# WHY A FUNCTION AND NOT A FIFTH BRANCH: compose_for_stack resolves a name four
# different ways and only the FOURTH ever selected a profile. `APK:discovery`
# resolves the SECOND way — COMPOSE_BY_NAME_APK_discovery, registered from
# docktor.json — whose array is the bare `docker compose -f …`, so up-stack.sh
# ran the plugin stack profile-less and started the one service that carries no
# role. Every branch calls this before it returns.
# ONLY THE PLUGIN STACK. Every other stack's profiles are opt-in on purpose and
# must not be switched on by being looked at: PROTOCOL:discovery:NMOS keeps the
# conformance harness behind one (732 MB of that stack's 1,087, off unless
# APK_NMOS_PROFILES asks), and the plugin file's own `build` profile is two
# services that exist to be built, never run.
# THE ROLES ARE NOT IN THIS FILE, which is the other half of why grepping it
# would not do: the plugin stack `include:`s twenty-two APK:plugin:* files and
# each one declares its own, so the file itself names `discovery` and `build`
# and nothing else. APKAUDIO_PLUGIN_ROLES is the list; see its default above.
# IDEMPOTENT — the `plugins` alias hands over COMPOSE_PLUGINS, which already
# carries the same flags from the role loop, so a second pass adds none.
apply_stack_profiles() {
    [ -n "${PLUGINS_COMPOSE_FILE:-}" ] || return 0
    [ "${STACK_COMPOSE_FILE:-}" = "$PLUGINS_COMPOSE_FILE" ] || return 0
    case " ${STACK_COMPOSE[*]} " in *" --profile "*) return 0;; esac
    local _role
    for _role in ${APKAUDIO_PLUGIN_ROLES//,/ }; do STACK_COMPOSE+=(--profile "$_role"); done
    return 0
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
    local want="$1"
    STACK_COMPOSE=()

    # 1. If want is an existing compose file path on disk
    if [ -f "$want" ]; then
        STACK_COMPOSE=("${COMPOSE_BASE[@]}" -f "$want")
        STACK_COMPOSE_FILE="$want"
        apply_stack_profiles
        return 0
    fi

    # 2. Check dynamic COMPOSE_BY_NAME variable from config_helper.py
    local clean_name="${want//:/_}"
    clean_name="${clean_name//-/_}"
    clean_name="${clean_name// /_}"
    clean_name="${clean_name//./_}"
    local array_name="COMPOSE_BY_NAME_${clean_name}[@]"
    local file_var="${clean_name}_COMPOSE_FILE"
    if declare -p "COMPOSE_BY_NAME_${clean_name}" &>/dev/null; then
        eval "STACK_COMPOSE=(\"\${${array_name}}\")"
        STACK_COMPOSE_FILE="${!file_var:-$(stack_compose_file "$want")}"
        apply_stack_profiles
        return 0
    fi

    # 3. Check legacy aliases
    case "$want" in
        core)       STACK_COMPOSE=("${COMPOSE_CORE[@]}"); STACK_COMPOSE_FILE="$COMPOSE_FILE"; return 0;;
        node)       STACK_COMPOSE=("${COMPOSE_NODE[@]}"); STACK_COMPOSE_FILE="$BAREMETAL_HARDWARE_COMPOSE_FILE"; return 0;;
        sqlcluster) STACK_COMPOSE=("${COMPOSE_SQLCLUSTER[@]}"); STACK_COMPOSE_FILE="$SQLCLUSTER_COMPOSE_FILE"; return 0;;
        mqtt)       STACK_COMPOSE=("${COMPOSE_MQTT[@]}"); STACK_COMPOSE_FILE="$MQTT_COMPOSE_FILE"; return 0;;
        portal)     STACK_COMPOSE=("${COMPOSE_PORTAL[@]}"); STACK_COMPOSE_FILE="$PORTAL_COMPOSE_FILE"; return 0;;
        plugins)    STACK_COMPOSE=("${COMPOSE_PLUGINS[@]}"); STACK_COMPOSE_FILE="$PLUGINS_COMPOSE_FILE"; apply_stack_profiles; return 0;;
        nmos)       STACK_COMPOSE=("${COMPOSE_NMOS[@]}"); STACK_COMPOSE_FILE="$NMOS_COMPOSE_FILE"; return 0;;
        aes70)      STACK_COMPOSE=("${COMPOSE_AES70[@]}"); STACK_COMPOSE_FILE="$AES70_COMPOSE_FILE"; return 0;;
        netbox)     STACK_COMPOSE=("${COMPOSE_NETBOX[@]}"); STACK_COMPOSE_FILE="$NETBOX_COMPOSE_FILE"; return 0;;
        ember)      STACK_COMPOSE=("${COMPOSE_EMBER[@]}"); STACK_COMPOSE_FILE="$EMBER_COMPOSE_FILE"; return 0;;
        protocols)  STACK_COMPOSE=("${COMPOSE_PROTOCOLS[@]}"); STACK_COMPOSE_FILE="$PROTOCOLS_COMPOSE_FILE"; return 0;;
        logger)     STACK_COMPOSE=("${COMPOSE_LOGGER[@]}"); STACK_COMPOSE_FILE="$LOGGER_COMPOSE_FILE"; return 0;;
        manager|docktor) STACK_COMPOSE=("${COMPOSE_MANAGER[@]}"); STACK_COMPOSE_FILE="$MANAGER_COMPOSE_FILE"; return 0;;
    esac

    # 4. Dynamic discovery under DOCKERS_DIR
    local found
    found="$(stack_compose_file "$want")"
    if [ -z "$found" ]; then
        found="$(find "$DOCKERS_DIR" -maxdepth 5 -type f \( -name "$want" -o -name "$want.yml" -o -name "docker-compose.${want}.yml" \) 2>/dev/null | head -n 1)"
    fi
    if [ -n "$found" ] && [ -f "$found" ]; then
        STACK_COMPOSE=("${COMPOSE_BASE[@]}" -f "$found")
        STACK_COMPOSE_FILE="$found"
        if [ -z "${COMPOSE_PROFILES:-}" ]; then
            local roles
            roles="$(grep -oE '^[[:space:]]*profiles:[[:space:]]*\[[^]]*\]' "$found" \
                     | sed -E 's/.*\[//; s/\]//; s/[[:space:]"'"'"']//g' | tr '\n' ',' | sed 's/,$//')"
            [ -n "$roles" ] && export COMPOSE_PROFILES="$roles"
        fi
        apply_stack_profiles
        return 0
    fi
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

# ensure_log_storage — bring LOGGER STORAGE up unless the log volume already
# exists. For the verbs that mount ONE stack or ONE container (up-stack.sh,
# rebuild.sh): for_each_stack already puts the logger first, but a single-stack
# mount on a fresh bench would otherwise fail on "external volume
# apk-audio-logs not found". Never exits; a failure is said and left to compose.
ensure_log_storage() {
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
