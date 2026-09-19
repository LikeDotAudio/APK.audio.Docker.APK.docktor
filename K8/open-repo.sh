#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📂 Inspect or open Git repositories for the microservices.
# Usage:
#   ./open-repo.sh                             list all 10 microservice Git repos
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
# Three names changed in the same move and are corrected here: the broker is
# DATABUS:Broker:MQTT, NMOS is PROTOCOL:discovery:NMOS, and APK:Yo is
# APK:YoControl. LOGGER STORAGE is added because it is a stack like the others
# and was the one nobody could open at all.
declare -A REPO_MAP=(
    ["mqtt"]="DATABUS:Broker:MQTT|$(stack_dir 'DATABUS:Broker:MQTT')"
    ["apk-mqtt-broker"]="DATABUS:Broker:MQTT|$(stack_dir 'DATABUS:Broker:MQTT')"
    ["sql"]="DATABASE:server:SQL|$(stack_dir 'DATABASE:server:SQL')"
    ["apk-sql-database"]="DATABASE:server:SQL|$(stack_dir 'DATABASE:server:SQL')"
    ["sqlcluster"]="DATABASE:cluster:SQL|$(stack_dir 'DATABASE:cluster:SQL')"
    ["nmos"]="PROTOCOL:discovery:NMOS|$(stack_dir 'PROTOCOL:discovery:NMOS')"
    ["apk-nmos-discovery"]="PROTOCOL:discovery:NMOS|$(stack_dir 'PROTOCOL:discovery:NMOS')"
    ["ember"]="PROTOCOL:DEV:EMBER|$(stack_dir 'PROTOCOL:DEV:EMBER')"
    ["apk-ember-server"]="PROTOCOL:DEV:EMBER|$(stack_dir 'PROTOCOL:DEV:EMBER')"
    ["netbox"]="DATABASE:server:NETBOX|$(stack_dir 'DATABASE:server:NETBOX')"
    ["apk-netbox-server"]="DATABASE:server:NETBOX|$(stack_dir 'DATABASE:server:NETBOX')"
    ["docktor"]="APK:Docktor|$(stack_dir 'APK:Docktor')"
    ["apk-docktor"]="APK:Docktor|$(stack_dir 'APK:Docktor')"
    ["aes70"]="PROTOCOL:DEV:AES70|$(stack_dir 'PROTOCOL:DEV:AES70')"
    ["apk-protocol-aes70"]="PROTOCOL:DEV:AES70|$(stack_dir 'PROTOCOL:DEV:AES70')"
    ["baremetal"]="APK:BareMetal|$(stack_dir 'APK:BareMetal')"
    ["apk-baremetal"]="APK:BareMetal|$(stack_dir 'APK:BareMetal')"
    ["yo"]="APK:YoControl|$(stack_dir 'APK:YoControl')"
    ["apk-yo"]="APK:YoControl|$(stack_dir 'APK:YoControl')"
    ["logger"]="DATABASE:volume:Log STORAGE|$(stack_dir 'DATABASE:volume:Log STORAGE')"
    # The WebPortal repository is APK:web:Frontend-Assets now; both old keys still open it.
    ["static"]="APK:web:Frontend-Assets|$(stack_dir 'APK:web:Frontend-Assets')"
    ["webportal"]="APK:web:Frontend-Assets|$(stack_dir 'APK:web:Frontend-Assets')"
    ["apk-webportal"]="APK:web:Frontend-Assets|$(stack_dir 'APK:web:Frontend-Assets')"
    ["plugins"]="APK:plugins:Build|$(stack_dir 'APK:plugins:Build')"
)

if [ -z "$QUERY" ]; then
    echo -e "\n📂 \033[1mAPK.audio Microservice Git Repositories\033[0m\n"
    printf "%-22s %-36s %-45s\n" "KEY / NAME" "SUBMODULE PATH" "STANDALONE GIT REPO PATH"
    printf "%-22s %-36s %-45s\n" "----------------------" "------------------------------------" "---------------------------------------------"
    
    for key in mqtt sql nmos ember netbox docktor aes70 baremetal yo logger static plugins; do
        IFS="|" read -r subpath repopath <<< "${REPO_MAP[$key]}"
        printf "\033[36m%-22s\033[0m %-36s %-45s\n" "$key" "APK:PODS/$subpath" "$repopath"
    done

    echo -e "\n\033[33mUsage:\033[0m python3 'APK:PODS/K8:runner.py' open <name> [--open]"
    echo "Example: python3 'APK:PODS/K8:runner.py' open mqtt"
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
    echo "Available keys: mqtt, sql, nmos, ember, netbox, docktor, aes70, baremetal, yo, webportal"
    exit 1
fi

IFS="|" read -r SUBMODULE_REL STANDALONE_PATH <<< "$MATCH"
SUBMODULE_FULL="$DOCKERS_DIR/$SUBMODULE_REL"

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
