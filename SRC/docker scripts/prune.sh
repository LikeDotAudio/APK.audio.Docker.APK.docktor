#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# ♻️  Reclaim what docker is holding and nothing is using.
#   ./prune.sh          dangling images + stopped containers + build cache
#   ./prune.sh --all    ALSO every image no running container references
# ⚠️ NAMED VOLUMES ARE NEVER TOUCHED. This ecosystem state lives in five of them
#    (mariadb-data, broker-data, baremetal-state, mqtt-exchange, gui-frames) and
#    docker volume prune counts a volume as unused whenever nothing is attached
#    RIGHT NOW — so running it while the stack is down deletes the database and
#    reports it as reclaimed space. No flag here will do it; use
#    `docker volume rm` by name and mean it.
# --all is image prune -a, which also removes the base images the next build
# pulls again: right when the disk is full, wrong on a slow link.
# Read disk.sh before and after.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

log_step "Stopped containers"
docker container prune -f

log_step "Build cache"
docker builder prune -f

if [ $ALL -eq 1 ]; then
    log_step "Every unreferenced image (--all)"
    docker image prune -af
else
    log_step "Dangling images"
    docker image prune -f
fi

log_warn "Named volumes were NOT pruned — mariadb-data, broker-data, baremetal-state,"
echo "  mqtt-exchange and gui-frames are this ecosystem's state and read as 'unused'"
echo "  whenever the stack is down. Remove one by name if you really mean to."

announce DOCKER_PRUNED "{\"images_all\":$ALL}"

log_step "What is left"
"$MANAGEMENT_SCRIPTS_DIR/disk.sh"
