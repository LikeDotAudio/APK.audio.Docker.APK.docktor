#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📄 The file that built a container. One path on stdout, or exit 1.
#   ./config-path.sh Storage-Portal
#   /…/APK:PODS/Server:Storage:SQL database/Docker/docker-compose.yml
# THE LABEL IS ASKED FIRST, THE NAME TABLE IS THE FALLBACK: compose stamps
# com.docker.compose.project.config_files onto every container it creates, and
# that is the file that ACTUALLY built this one — it survives a rename, it is
# right for a compose file this collection never heard of, and it cannot drift.
# The table below only answers for a container compose did not label, or one
# that is not running.
# Exit 1 with nothing on stdout when no configuration file can be named.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

if [ -z "${1:-}" ]; then
    log_error "usage: config-path.sh <container-name-or-id>"
    exit 2
fi

container="$1"

# 1. What compose recorded. The label is a comma-separated list; the first
#    existing entry wins.
labelled="$(docker inspect --format \
    '{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
    "$container" 2>/dev/null)"

if [ -n "$labelled" ] && [ "$labelled" != "<no value>" ]; then
    IFS=',' read -ra candidates <<< "$labelled"
    for candidate in "${candidates[@]}"; do
        candidate="${candidate#"${candidate%%[![:space:]]*}"}"   # ltrim
        candidate="${candidate%"${candidate##*[![:space:]]}"}"   # rtrim
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            exit 0
        fi
    done
fi

# 2. The name table. The compose path comes from _common.sh; the two Dockerfile
#    paths are spelled here because nothing else in the shell needs them. The
#    [ -f ] below is what makes a wrong rung cost nothing visible — it falls
#    through to the compose file and then to an empty answer.
#    A Dockerfile wins for the two services BUILT here, because that is the file
#    a person editing the image wants; the pulled images (mosquitto, mariadb)
#    resolve to the compose file that configures them.
lowered="$(printf '%s' "$container" | tr '[:upper:]' '[:lower:]')"

case "$lowered" in
    # THROUGH stack_dir(), NOT SPELLED: both of these named the flat pre-pod
    # layout, so `View Configuration Script / Dockerfile` on the two containers
    # that HAVE one resolved to a file that is not there — and the button that
    # exists to show you what built a container showed nothing.
    *baremetal*)
        path="$(stack_dir 'APK:BareMetal')/Docker/Dockerfile" ;;
    *portal*|*web*)
        path="$(stack_dir 'DATABASE:server:SQL')/Docker/Dockerfile" ;;
    *mariadb*|*maria*|*broker*|*mqtt*)
        path="$COMPOSE_FILE" ;;
    *)
        path="" ;;
esac

if [ -n "$path" ] && [ -f "$path" ]; then
    printf '%s\n' "$path"
    exit 0
fi

exit 1
