#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 💾 What docker is holding on this disk, and how much is reclaimable.
#   ./disk.sh
# TAB rows, no header: TYPE COUNT SIZE RECLAIMABLE, then the host filesystem
# docker data root sits on as a fifth row with TYPE `host`.
# rebuild-all.sh runs build --no-cache on every project, which writes a full
# layer set and reclaims nothing, and nothing else reported that cost — so the
# first sign was a build failing on ENOSPC with the bench already down.
# Read it before a rebuild. Pair with prune.sh.
# docker system df is one call; the per-object breakdown (-v) is a much slower
# second one and is not made here: this answers "is there room".
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

docker system df --format '{{.Type}}\t{{.TotalCount}}\t{{.Size}}\t{{.Reclaimable}}' || exit 1

# The data root, not /var/lib/docker: a daemon with data-root elsewhere puts the
# images on a different filesystem than the path everyone quotes.
data_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
if [ -n "$data_root" ] && [ -d "$data_root" ]; then
    read -r _ size used avail _ <<< "$(df -h "$data_root" | tail -n1)"
    printf 'host\t1\t%s\t%s free\n' "$size" "$avail"
    announce DOCKER_DISK "{\"data_root\":\"$data_root\",\"size\":\"$size\",\"used\":\"$used\",\"available\":\"$avail\"}"
fi
