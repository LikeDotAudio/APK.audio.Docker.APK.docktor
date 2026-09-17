#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🚀 Mount ONE stack. Gates first, its own ports second, its own compose third.
#   ./up-stack.sh 'PROTOCOL:DEV:EMBER'
# up.sh is the bench verb (eight compose files, core before node, minutes of
# build). This is the same act scoped to one stack, because the dashboard offers
# a fix PER STACK and had only the bench-wide verb behind it — the fix for
# DockTor rebuilt the other eight and did not touch the manager
# compose file at all, since for_each_stack does not drive it.
# THE ARGUMENT IS THE DIRECTORY UNDER APK:PODS/ (PROTOCOL:DEV:EMBER,
# DockTor), which is what stacks.sh prints. compose_for_stack turns it
# into the same ARRAY the bench-wide verbs expand, so the node arrives with its
# hardware overlay and the manager with its own file.
# THE GATES STILL REFUSE: one stack is not a reason to build ungated. Set
# APKAUDIO_NO_GATES=1 only when debugging the gates.
# THE PORT EVICTION IS SCOPED and that is not an optimisation: free-ports.sh
# stops any container publishing a port it is asked to free, so a bench-wide run
# here would stop healthy containers in seven other stacks.
# APKAUDIO_NO_KABOOM=1 leaves a held port alone and lets compose report it.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

STACK="${1:-}"
if [ -z "$STACK" ]; then
    log_error "Which stack? Name the directory under APK:PODS/."
    echo "Usage: ./up-stack.sh 'PROTOCOL:DEV:EMBER'"
    echo "       ./stacks.sh   # the names, one per row"
    exit 2
fi

if ! compose_for_stack "$STACK"; then
    log_error "No compose file under APK:PODS/ is named by the stack '$STACK'."
    echo "  ./stacks.sh prints every stack this repository declares, one per row,"
    echo "  and the first column is the name this verb takes."
    exit 2
fi

# THE ONE STACK THAT CANNOT RECREATE ITSELF: compose up on the manager stops the
# container running this script between the stop and the start. From a host
# terminal it is safe; from inside it is refused and panic-reboot.sh is named.
if [ "$STACK_COMPOSE_FILE" = "$MANAGER_COMPOSE_FILE" ] && [ -f /.dockerenv ]; then
    log_error "Refusing to remount the manager stack from inside the manager container."
    echo "  This script would stop the container it is running in, halfway through,"
    echo "  leaving the old manager gone and the new one never started."
    echo "  Press 🚨 PANIC twice, or from a host terminal run:"
    echo "      ./panic-reboot.sh"
    exit 2
fi

# The one export the manager compose file has no default for, harmless to the
# other eight: source and target of its repository bind are one variable, and
# :? fails the file rather than mounting the checkout somewhere the daemon does
# not share it.
export APKAUDIO_REPO="${APKAUDIO_REPO:-$REPO_ROOT}"

echo "🚀 Mounting one stack: $STACK"
echo "   $STACK_COMPOSE_FILE"
echo "============================================================"

log_step "Enforcing upstream pre-build container test gates..."
if [ "${APKAUDIO_NO_GATES:-0}" = "1" ]; then
    log_warn "Test gates SKIPPED by APKAUDIO_NO_GATES=1."
elif ! "$MANAGEMENT_SCRIPTS_DIR/test-gates.sh"; then
    log_error "Mount cancelled: upstream pre-build test gates failed."
    exit 1
fi

log_step "Preparing the host (skills, this stack's ports)..."
synch_skills
if [ "${APKAUDIO_NO_KABOOM:-0}" = "1" ]; then
    log_warn "Port eviction disabled (--no-kaboom); compose will report any collision itself."
else
    # NOT || exit 1. up.sh aborts the bench because the alternative is eight
    # stacks failing one at a time; here there is one compose run and its own
    # error is the clearer report.
    "$MANAGEMENT_SCRIPTS_DIR/free-ports.sh" --stack "$STACK" \
        || log_warn "A port this stack publishes is still held; compose will say which."
fi

# Which node is about to be mounted, on the one stack where that has an answer.
# Silent for the other eight.
[ "$STACK_COMPOSE_FILE" = "$BAREMETAL_COMPOSE_FILE" ] && node_hardware_report

# Every stack mounts the external log volume; LOGGER STORAGE owns it.
[ "$STACK_COMPOSE_FILE" = "$LOGGER_COMPOSE_FILE" ] || ensure_log_storage

log_step "Starting $STACK..."
announce COMPOSE_RUN "{\"action\":\"up-stack\",\"stack\":\"$STACK\"}"
"${STACK_COMPOSE[@]}" up -d --build
status=$?

announce COMPOSE_RESULT "{\"action\":\"up-stack\",\"stack\":\"$STACK\",\"exit_code\":$status}"
if [ $status -ne 0 ]; then
    log_error "Mount of $STACK FAILED — compose exited $status. Read the output above."
    exit $status
fi

clean_build_cache "the $STACK mount"

echo -e "\n${BOLD}${GREEN}✅ $STACK is mounted.${OFF}"
exit 0
