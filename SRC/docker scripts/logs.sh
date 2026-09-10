#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📜 Read one container log. The tail, not the stream.
#   ./logs.sh Storage-Portal          last 200 lines
#   ./logs.sh Storage-Portal 1000     last 1000
#   ./logs.sh Storage-Portal all      everything docker still holds
# BOUNDED BY DEFAULT AND NEVER --follow: every caller reads a pipe until it
# closes, and docker logs -f never closes. The GUI is the one that hangs
# invisibly — the button appears to do nothing.
# --timestamps because a container log without them cannot be lined up against
# the bus, which is most of what reading a log here is for.
# Exit 1 when the container is not known, so a caller can test the status.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

if [ -z "${1:-}" ]; then
    log_error "usage: logs.sh <container-name-or-id> [lines|all]"
    exit 2
fi

container="$1"
lines="${2:-200}"

if ! docker inspect "$container" >/dev/null 2>&1; then
    log_error "no such container: $container"
    exit 1
fi

announce CONTAINER_LOGS_READ "{\"container\":\"$container\",\"lines\":\"$lines\"}"

# stderr folded into stdout: a container has ONE chronology, and reading two
# streams is how a traceback prints after the line that recovered from it.
docker logs --timestamps --tail "$lines" "$container" 2>&1
