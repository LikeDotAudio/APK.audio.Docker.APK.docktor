#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📂 Inspect or open Git repositories for the microservices.
# Usage:
#   ./open-repo.sh                             list the microservice Git repos
#   ./open-repo.sh <name|path>                 show Git status/log for a specific repo
#   ./open-repo.sh <name|path> --open          open repository folder in system file manager / editor

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

OPEN_GUI=0
QUERY=""

for arg in "$@"; do
    case "$arg" in
        --open|-o) OPEN_GUI=1;;
        -*)        log_warn "Unknown option: $arg";;
        *)         [ -z "$QUERY" ] && QUERY="$arg";;
    esac
done

# ⚠️ EVERY PATH HERE GOES THROUGH stack_dir(), AND NONE IS SPELLED WHOLE. This
# table held twenty absolute paths in the flat pre-pod layout, so after the move
# every one of them named a directory that is not there and `open <name>`
# answered "not found" for the entire ecosystem. The folder NAME is what this
# table is about; WHERE that folder sits has one answer and it is in _common.sh.
# Every key names a folder that exists under PODS today (POD.x / GROUP.name):
# DATABUS.Broker.MQTT, PROTOCOL.discovery.NMOS, MANAGER.Docktor, NODE.BareMetal,
# CONTROL.YoControl, WEB.Frontend-Assets and DISCOVERY.Engine (the plugin host).
# An APK:-era name here resolves to a PODS/<name> that is not there. LOGGER
# STORAGE is a stack like the others.
declare -A REPO_MAP=(
    ["mqtt"]="DATABUS.Broker.MQTT|$(stack_dir 'DATABUS.Broker.MQTT')"
    ["apk-mqtt-broker"]="DATABUS.Broker.MQTT|$(stack_dir 'DATABUS.Broker.MQTT')"
    ["sql"]="DATABASE.server.SQL|$(stack_dir 'DATABASE.server.SQL')"
    ["apk-sql-database"]="DATABASE.server.SQL|$(stack_dir 'DATABASE.server.SQL')"
    ["sqlcluster"]="DATABASE.server.SQL|$(stack_dir 'DATABASE.server.SQL')"
    ["nmos"]="PROTOCOL.discovery.NMOS|$(stack_dir 'PROTOCOL.discovery.NMOS')"
    ["apk-nmos-discovery"]="PROTOCOL.discovery.NMOS|$(stack_dir 'PROTOCOL.discovery.NMOS')"
    ["ember"]="PROTOCOL.DEV.EMBER|$(stack_dir 'PROTOCOL.DEV.EMBER')"
    ["apk-ember-server"]="PROTOCOL.DEV.EMBER|$(stack_dir 'PROTOCOL.DEV.EMBER')"
    ["netbox"]="DATABASE.server.NETBOX|$(stack_dir 'DATABASE.server.NETBOX')"
    ["apk-netbox-server"]="DATABASE.server.NETBOX|$(stack_dir 'DATABASE.server.NETBOX')"
    ["docktor"]="MANAGER.Docktor|$(stack_dir 'MANAGER.Docktor')"
    ["apk-docktor"]="MANAGER.Docktor|$(stack_dir 'MANAGER.Docktor')"
    ["aes70"]="PROTOCOL.DEV.AES70|$(stack_dir 'PROTOCOL.DEV.AES70')"
    ["apk-protocol-aes70"]="PROTOCOL.DEV.AES70|$(stack_dir 'PROTOCOL.DEV.AES70')"
    ["baremetal"]="NODE.BareMetal|$(stack_dir 'NODE.BareMetal')"
    ["apk-baremetal"]="NODE.BareMetal|$(stack_dir 'NODE.BareMetal')"
    ["yo"]="CONTROL.YoControl|$(stack_dir 'CONTROL.YoControl')"
    ["apk-yo"]="CONTROL.YoControl|$(stack_dir 'CONTROL.YoControl')"
    ["logger"]="DATABASE.volume.Log-STORAGE|$(stack_dir 'DATABASE.volume.Log-STORAGE')"
    # The WebPortal repository is WEB.Frontend-Assets now; both old keys still open it.
    ["static"]="WEB.Frontend-Assets|$(stack_dir 'WEB.Frontend-Assets')"
    ["webportal"]="WEB.Frontend-Assets|$(stack_dir 'WEB.Frontend-Assets')"
    ["apk-webportal"]="WEB.Frontend-Assets|$(stack_dir 'WEB.Frontend-Assets')"
    ["plugins"]="DISCOVERY.Engine|$(stack_dir 'DISCOVERY.Engine')"
)

if [ -z "$QUERY" ]; then
    echo -e "\n📂 \033[1mAPK.audio Microservice Git Repositories\033[0m\n"
    printf "%-22s %-36s %-45s\n" "KEY / NAME" "SUBMODULE PATH" "STANDALONE GIT REPO PATH"
    printf "%-22s %-36s %-45s\n" "----------------------" "------------------------------------" "---------------------------------------------"
    
    for key in mqtt sql nmos ember netbox docktor aes70 baremetal yo logger static plugins; do
        IFS="|" read -r subpath repopath <<< "${REPO_MAP[$key]}"
        printf "\033[36m%-22s\033[0m %-36s %-45s\n" "$key" "PODS/${repopath#"$DOCKERS_DIR"/}" "$repopath"
    done

    echo -e "\n\033[33mUsage:\033[0m python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8:runner.py' open <name> [--open]"
    echo "Example: python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8:runner.py' open mqtt"
    exit 0
fi

# Resolve query
LOOKUP_KEY="$(echo "$QUERY" | tr '[:upper:]' '[:lower:]')"
MATCH="${REPO_MAP[$LOOKUP_KEY]:-}"

if [ -z "$MATCH" ]; then
    # Try fuzzy match
    for k in "${!REPO_MAP[@]}"; do
        if [[ "$k" == *"$LOOKUP_KEY"* ]]; then
            MATCH="${REPO_MAP[$k]}"
            break
        fi
    done
fi

if [ -z "$MATCH" ]; then
    log_error "Could not resolve repository for '$QUERY'."
    echo "Available keys: mqtt, sql, nmos, ember, netbox, docktor, aes70, baremetal, yo, logger, webportal, plugins"
    exit 1
fi

IFS="|" read -r SUBMODULE_REL STANDALONE_PATH <<< "$MATCH"
SUBMODULE_FULL="$STANDALONE_PATH"  # stack_dir already placed the folder in its pod

echo -e "\n🔍 \033[1mRepository Information: $QUERY\033[0m"
echo -e "📁 Submodule Path: \033[36m$SUBMODULE_FULL\033[0m"
echo -e "📦 Standalone Repo: \033[36m$STANDALONE_PATH\033[0m"

if [ -d "$STANDALONE_PATH" ]; then
    echo -e "\n📊 \033[1mGit Branch & Recent Commits (Standalone Repo):\033[0m"
    git -C "$STANDALONE_PATH" status -sb || true
    echo -e "\n📜 \033[1mRecent Commits:\033[0m"
    git -C "$STANDALONE_PATH" log -n 3 --oneline || true
fi

if [ "$OPEN_GUI" = "1" ]; then
    log_step "Opening $STANDALONE_PATH in system file manager / editor..."
    if command -v code &>/dev/null; then
        code "$STANDALONE_PATH"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$STANDALONE_PATH"
    else
        log_warn "Neither 'code' nor 'xdg-open' found. Path: $STANDALONE_PATH"
    fi
fi
