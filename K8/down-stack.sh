#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🛑 Take ONE pod off the bench. The lasso's stop verb.
#   ./down-stack.sh 'PROTOCOL:DEV:EMBER'
#   ./down-stack.sh 'PROTOCOL:DEV:EMBER' --volumes    ⚠️ ALSO ITS NAMED VOLUMES
# down.sh stops everything; this stops the one pod somebody pointed at, which is
# the unit the card grid draws and therefore the unit people reach for.
# ⚠️ NO --remove-orphans. Five of the compose files share the project
#    `apk-audio`, so the flag would take the rest of the ecosystem down with the
#    pod. This is the same refusal rebuild-all.sh and down.sh carry.
# ⚠️ --volumes IS THE DATA AND IT IS NEVER THE DEFAULT. `compose down -v` removes
#    the volumes this file declares — for the SQL pod that is the database, for
#    the broker its retained state. Nothing here backs them up. The web client
#    does not offer it; a person at a terminal has to type it.
# THE IMAGES ARE LEFT ALONE: this is a stop, not a reclaim. prune.sh and
# clean-build-cache.sh are the verbs that free space.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

STACK="${1:-}"
WITH_VOLUMES=0
[ "${2:-}" = "--volumes" ] && WITH_VOLUMES=1

if [ -z "$STACK" ]; then
    log_error "Which pod? Name the directory under APK:PODS/."
    echo "Usage: ./down-stack.sh 'PROTOCOL:DEV:EMBER'"
    echo "       ./stacks.sh   # the names, one per row"
    exit 2
fi

if ! compose_for_stack "$STACK"; then
    log_error "No compose file under APK:PODS/ is named by the pod '$STACK'."
    echo "  ./stacks.sh prints every pod this repository declares, one per row."
    exit 2
fi

# THE POD THAT CANNOT STOP ITSELF. down on the manager stack kills the container
# running this script, so the answer would never come back and the bench would
# be left with no tool. panic.sh is the verb that means "stop everything but me".
if [ "$STACK_COMPOSE_FILE" = "$MANAGER_COMPOSE_FILE" ] && [ -f /.dockerenv ]; then
    log_error "Refusing to stop the manager pod from inside the manager container."
    echo "  It would kill the container answering this request, mid-answer."
    echo "  From a host terminal:  ./manager.sh down"
    exit 2
fi

export APKAUDIO_REPO="${APKAUDIO_REPO:-$REPO_ROOT}"

log_step "Stopping $STACK..."
announce COMPOSE_RUN "{\"action\":\"down-stack\",\"stack\":\"$STACK\",\"volumes\":$WITH_VOLUMES}"
if [ $WITH_VOLUMES -eq 1 ]; then
    log_warn "--volumes: the named volumes this pod declares are being REMOVED with it."
    "${STACK_COMPOSE[@]}" down --volumes
else
    "${STACK_COMPOSE[@]}" down
fi
status=$?
announce COMPOSE_RESULT "{\"action\":\"down-stack\",\"stack\":\"$STACK\",\"exit_code\":$status}"

if [ $status -ne 0 ]; then
    log_error "Stopping $STACK reported errors (exit $status). Read the output above."
    exit $status
fi

echo -e "\n${BOLD}${GREEN}✅ $STACK is off the bench.${OFF}"
[ $WITH_VOLUMES -eq 0 ] && echo "  Its named volumes were NOT touched; its images are still here."
