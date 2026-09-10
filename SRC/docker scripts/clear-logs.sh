#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧹 Truncate every container json log file on disk. Containers keep running.
#   ./clear-logs.sh
# docker logs has no truncate, so the only way to reclaim the space is to empty
# the file docker appends to (.LogPath). TRUNCATE, not delete — docker holds the
# file open, so removing it frees nothing and leaves the daemon writing to an
# unlinked inode.
# Root may be required (/var/lib/docker is root-owned on most installs); a
# permission failure is reported per file rather than aborting the sweep.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

ids="$(docker ps -qa)"
if [ -z "$ids" ]; then
    log_info "No containers on this host; nothing to truncate."
    exit 0
fi

cleared=0
skipped=0
while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ -f "$path" ] && truncate -s 0 "$path" 2>/dev/null; then
        cleared=$((cleared + 1))
    else
        skipped=$((skipped + 1))
        log_warn "could not truncate $path (try with sudo)"
    fi
done <<< "$(docker inspect --format '{{.LogPath}}' $ids 2>/dev/null)"

announce DOCKER_LOGS_CLEARED "{\"cleared\":$cleared,\"skipped\":$skipped}"
log_info "Truncated $cleared docker log file(s); $skipped skipped."
[ $skipped -eq 0 ]
