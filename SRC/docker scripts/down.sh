#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🛑 Stop every container stack, node before core.
#   ./down.sh                     stop everything
#   ./down.sh --remove-orphans    extra compose flags pass through
# Reverse of up.sh order: the node agents report to the broker the core stack
# owns, so the node exits before the bus rather than spending the teardown
# reconnecting to a socket that has gone.
# NO PORT EVICTION: down binds nothing, and freeing ports on the way down would
# stop the containers this is about to ask compose to stop.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

log_step "Stopping all APK.audio container stacks..."
announce COMPOSE_RUN "{\"action\":\"down\",\"args\":\"$*\"}"
for_each_stack reverse down "$@"
status=$?
announce COMPOSE_RESULT "{\"action\":\"down\",\"exit_code\":$status}"

if [ $status -ne 0 ]; then
    log_error "Teardown reported errors — compose exited $status."
    exit $status
fi
echo -e "\n${BOLD}🛑 All containers stopped.${OFF}"
