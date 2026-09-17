#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧱⚡ Rebuild ONE pod from scratch and put it back. The lasso's build verb.
#   ./rebuild-stack.sh 'PROTOCOL:DEV:EMBER'
# THREE VERBS NOW SCOPE TO ONE STACK and they are three different acts:
#   · up-stack.sh     mount it, building only what changed
#   · rebuild-stack.sh  THIS — build --no-cache, then force-recreate
#   · down-stack.sh   take it off the bench
# rebuild-all.sh is this for the whole bench, and it is ten minutes; the grid
# groups cards by pod and the question at a pod is nearly always about that pod.
# NO --remove-orphans, for the reason every other file here says no to it: five
# compose files share the project `apk-audio`, so the flag deletes the rest of
# the ecosystem.
# THE GATES REFUSE, as they do for every build path in this folder.
# ⚠️ THE OLD CONTAINERS ARE NOT REMOVED FIRST. --force-recreate replaces each in
#    turn, so a failed build leaves the pod RUNNING on its old image rather than
#    down — the opposite trade from rebuild-all.sh, and the right one when the
#    blast radius is one stack somebody chose.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

STACK="${1:-}"
if [ -z "$STACK" ]; then
    log_error "Which pod? Name the directory under APK:PODS/."
    echo "Usage: ./rebuild-stack.sh 'PROTOCOL:DEV:EMBER'"
    echo "       ./stacks.sh   # the names, one per row"
    exit 2
fi

if ! compose_for_stack "$STACK"; then
    log_error "No compose file under APK:PODS/ is named by the pod '$STACK'."
    echo "  ./stacks.sh prints every pod this repository declares, one per row."
    exit 2
fi

# Same refusal as up-stack.sh, and the same reason: compose would stop the
# container running this script between the stop and the start.
if [ "$STACK_COMPOSE_FILE" = "$MANAGER_COMPOSE_FILE" ] && [ -f /.dockerenv ]; then
    log_error "Refusing to rebuild the manager pod from inside the manager container."
    echo "  Press 🚨 PANIC twice, or from a host terminal run:  ./panic-reboot.sh"
    exit 2
fi

export APKAUDIO_REPO="${APKAUDIO_REPO:-$REPO_ROOT}"

log_step "Enforcing upstream pre-build container test gates..."
if [ "${APKAUDIO_NO_GATES:-0}" = "1" ]; then
    log_warn "Test gates SKIPPED by APKAUDIO_NO_GATES=1."
elif ! "$MANAGEMENT_SCRIPTS_DIR/test-gates.sh"; then
    log_error "Rebuild of $STACK cancelled: upstream pre-build test gates failed."
    exit 1
fi

log_step "Preparing the host (skills, this pod's ports)..."
synch_skills
if [ "${APKAUDIO_NO_KABOOM:-0}" = "1" ]; then
    log_warn "Port eviction disabled (--no-kaboom); compose will report any collision itself."
else
    # Scoped, for up-stack.sh's reason: a bench-wide eviction here would stop
    # healthy containers in every other pod to rebuild this one.
    "$MANAGEMENT_SCRIPTS_DIR/free-ports.sh" --stack "$STACK" \
        || log_warn "A port this pod publishes is still held; compose will say which."
fi

[ "$STACK_COMPOSE_FILE" = "$LOGGER_COMPOSE_FILE" ] || ensure_log_storage

log_step "Building $STACK from scratch (no cache)..."
announce COMPOSE_RUN "{\"action\":\"build --no-cache\",\"stack\":\"$STACK\"}"
"${STACK_COMPOSE[@]}" build --no-cache
status=$?
announce COMPOSE_RESULT "{\"action\":\"build --no-cache\",\"stack\":\"$STACK\",\"exit_code\":$status}"
if [ $status -ne 0 ]; then
    log_error "Build of $STACK FAILED (exit $status). Nothing was replaced; the pod is as it was."
    exit $status
fi

log_step "Mounting $STACK on the fresh images..."
announce COMPOSE_RUN "{\"action\":\"up --force-recreate\",\"stack\":\"$STACK\"}"
"${STACK_COMPOSE[@]}" up -d --force-recreate
status=$?
announce COMPOSE_RESULT "{\"action\":\"up --force-recreate\",\"stack\":\"$STACK\",\"exit_code\":$status}"
if [ $status -ne 0 ]; then
    log_error "$STACK rebuilt, but the replacement would not come up (exit $status)."
    exit $status
fi

clean_build_cache "the $STACK rebuild"

echo -e "\n${BOLD}${GREEN}✅ $STACK rebuilt from scratch and running.${OFF}"
