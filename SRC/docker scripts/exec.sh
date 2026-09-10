#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🐚 Run a command inside a container. Interactive when a terminal is attached.
#   ./exec.sh Storage-Portal                    a shell
#   ./exec.sh Node-BareMetal ls /app            one command
# -it IS CONDITIONAL: docker exec -it demands a TTY, and this collection is run
# from a pipe as often as from a terminal, where a hard -it fails with "the input
# device is not a TTY" and reads as a docker problem.
# THE SHELL IS PROBED, NOT ASSUMED: bash exists in some of these images and not
# others, and exec … bash on an image without it fails with an OCI error naming
# no shell. bash first, sh second.
# Nothing here is announced on the bus: what a person types into a container is
# not an ecosystem event, and it may include credentials.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

if [ -z "${1:-}" ]; then
    log_error "usage: exec.sh <container-name-or-id> [command...]"
    exit 2
fi

container="$1"; shift

if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    log_error "$container is not running; exec needs a running container."
    exit 1
fi

flags=(-i)
[ -t 0 ] && flags=(-it)

if [ $# -gt 0 ]; then
    exec docker exec "${flags[@]}" "$container" "$@"
fi

for shell in /bin/bash /bin/sh; do
    if docker exec "$container" test -x "$shell" 2>/dev/null; then
        exec docker exec "${flags[@]}" "$container" "$shell"
    fi
done

log_error "no /bin/bash or /bin/sh in $container; pass a command explicitly."
exit 1
