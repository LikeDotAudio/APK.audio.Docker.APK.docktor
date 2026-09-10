#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🔄 Restart one container, without touching the rest of the bench.
#   ./restart.sh Storage-Broker [Storage-MariaDB …]
# docker restart, NOT a compose recreate: a recreate would re-run every
# up-shaped precondition (gates, skills synch, port eviction) for what is meant
# to be bouncing one process. It also STARTS a stopped container, so this is the
# single-container verb for both.
# ⚠️ IT PICKS UP NOTHING NEW: same image, environment and mounts. A changed
#    compose file needs up.sh, and a changed mosquitto_local.conf needs
#    `up.sh mqtt` — the broker config is COPYed into the image now, which is
#    what makes it survive a reboot.
# Exits non-zero if any named container fails; every one is attempted first.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

if [ $# -eq 0 ]; then
    log_error "usage: restart.sh <container-name-or-id> [more...]"
    exit 2
fi

worst=0
for container in "$@"; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        log_error "no such container: $container"
        announce CONTAINER_RESTART_FAILED "{\"container\":\"$container\",\"reason\":\"unknown\"}"
        worst=1
        continue
    fi

    log_step "Restarting $container"
    if docker restart "$container"; then
        log_info "$container restarted."
        announce CONTAINER_RESTARTED "{\"container\":\"$container\"}"
    else
        status=$?
        log_error "$container failed to restart (exit $status)."
        announce CONTAINER_RESTART_FAILED "{\"container\":\"$container\",\"exit_code\":$status}"
        worst=$status
    fi
done

exit $worst
