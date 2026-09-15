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

declare -A REPO_MAP=(
    ["mqtt"]="Server:Broker:MQTT|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/Server:Broker:MQTT"
    ["apk-mqtt-broker"]="Server:Broker:MQTT|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/Server:Broker:MQTT"
    ["sql"]="DATABASE:server:SQL|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/DATABASE:server:SQL"
    ["apk-sql-database"]="DATABASE:server:SQL|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/DATABASE:server:SQL"
    ["nmos"]="Server:Discovery:NMOS|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/Server:Discovery:NMOS"
    ["apk-nmos-discovery"]="Server:Discovery:NMOS|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/Server:Discovery:NMOS"
    ["ember"]="PROTOCOL:DEV:EMBER|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/PROTOCOL:DEV:EMBER"
    ["apk-ember-server"]="PROTOCOL:DEV:EMBER|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/PROTOCOL:DEV:EMBER"
    ["netbox"]="DATABASE:server:NETBOX|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/DATABASE:server:NETBOX"
    ["apk-netbox-server"]="DATABASE:server:NETBOX|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/DATABASE:server:NETBOX"
    ["docktor"]="APK:docktor|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/APK:docktor"
    ["apk-docktor"]="APK:docktor|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/APK:docktor"
    ["aes70"]="PROTOCOL:DEV:AES70|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/PROTOCOL:DEV:AES70"
    ["apk-protocol-aes70"]="PROTOCOL:DEV:AES70|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/PROTOCOL:DEV:AES70"
    ["baremetal"]="APK:BareMetal|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/APK:BareMetal"
    ["apk-baremetal"]="APK:BareMetal|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/APK:BareMetal"
    ["yo"]="APK:Yo|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/APK:Yo"
    ["apk-yo"]="APK:Yo|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/APK:Yo"
    ["webportal"]="APK:audio:WebPortal|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/APK:audio:WebPortal"
    ["apk-webportal"]="APK:audio:WebPortal|/home/anthony/Documents/GitProjects/APK.audio/APK:DOCKERS/APK:audio:WebPortal"
)

if [ -z "$QUERY" ]; then
    echo -e "\n📂 \033[1mAPK.audio Microservice Git Repositories\033[0m\n"
    printf "%-22s %-36s %-45s\n" "KEY / NAME" "SUBMODULE PATH" "STANDALONE GIT REPO PATH"
    printf "%-22s %-36s %-45s\n" "----------------------" "------------------------------------" "---------------------------------------------"
    
    for key in mqtt sql nmos ember netbox docktor aes70 baremetal yo webportal; do
        IFS="|" read -r subpath repopath <<< "${REPO_MAP[$key]}"
        printf "\033[36m%-22s\033[0m %-36s %-45s\n" "$key" "APK:DOCKERS/$subpath" "$repopath"
    done

    echo -e "\n\033[33mUsage:\033[0m python3 Manager:docktor.py open <name> [--open]"
    echo "Example: python3 Manager:docktor.py open mqtt"
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
