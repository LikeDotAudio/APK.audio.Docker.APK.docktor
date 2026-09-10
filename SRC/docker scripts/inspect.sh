#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🔍 docker inspect one container, raw JSON on stdout.
#   ./inspect.sh Storage-Portal
# The array docker returns, unwrapped to its single element — every caller was
# writing that [0] subscript itself.
# Exit 1 with nothing on stdout when the container is unknown, so a caller can
# test the status rather than parse an error that happens to be JSON.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

if [ -z "${1:-}" ]; then
    log_error "usage: inspect.sh <container-name-or-id>"
    exit 2
fi

raw="$(docker inspect "$1" 2>/dev/null)" || {
    log_error "Failed to inspect $1" >&2
    exit 1
}

[ -z "$raw" ] && { log_error "Failed to inspect $1" >&2; exit 1; }

printf '%s' "$raw" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[0], indent=2))'
