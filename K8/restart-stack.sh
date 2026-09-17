#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🔄 Restart ONE pod in place. The lasso's restart verb.
#   ./restart-stack.sh 'PROTOCOL:DEV:EMBER'
# `compose restart`: the containers that exist are stopped and started again,
# nothing is rebuilt, recreated or removed. A pod with no containers stays
# empty — up-stack.sh is the verb that makes them.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

STACK="${1:-}"
if [ -z "$STACK" ]; then
    log_error "Which pod? Name the directory under APK:PODS/."
    echo "Usage: ./restart-stack.sh 'PROTOCOL:DEV:EMBER'"
    echo "       ./stacks.sh   # the names, one per row"
    exit 2
fi

if ! compose_for_stack "$STACK"; then
    log_error "No compose file under APK:PODS/ is named by the pod '$STACK'."
    echo "  ./stacks.sh prints every pod this repository declares, one per row."
    exit 2
fi

# Same refusal as down-stack.sh: restarting the manager from inside it stops
# the container running this script, and the answer never comes back.
if [ "$STACK_COMPOSE_FILE" = "$MANAGER_COMPOSE_FILE" ] && [ -f /.dockerenv ]; then
    log_error "Refusing to restart the manager pod from inside the manager container."
    echo "  From a host terminal:  ./manager.sh restart"
    exit 2
fi

export APKAUDIO_REPO="${APKAUDIO_REPO:-$REPO_ROOT}"

log_step "Restarting $STACK..."
announce COMPOSE_RUN "{\"action\":\"restart-stack\",\"stack\":\"$STACK\"}"
"${STACK_COMPOSE[@]}" restart
status=$?
announce COMPOSE_RESULT "{\"action\":\"restart-stack\",\"stack\":\"$STACK\",\"exit_code\":$status}"

if [ $status -ne 0 ]; then
    log_error "Restarting $STACK reported errors (exit $status). Read the output above."
    exit $status
fi

echo -e "\n${BOLD}${GREEN}✅ $STACK restarted.${OFF}"
