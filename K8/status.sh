#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📊 Health of every stack, plus what is running INSIDE each container.
#   ./status.sh
# compose ps answers whether the CONTAINERS are up. It cannot answer whether the
# AGENTS inside the node are, and the node healthcheck probes the supervisor
# /status — so a healthy BareMetal with a dead orchestrator is a real state.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# The agent roster is apps.sh; this prints what that returns. It used to curl
# 127.0.0.1:8100/status here, which was a second spelling of the supervisor port
# and the only copy, so the dashboard card needed a third.
log_step "Container Ecosystem Health"
for_each_stack forward ps

apps="$("$MANAGEMENT_SCRIPTS_DIR/apps.sh" 2>/dev/null)"
if [ -n "$apps" ]; then
    log_step "Inside the containers"
    # awk, not a bash loop with a $current variable: the container heading has
    # to change on the first row of each group.
    printf '%s\n' "$apps" | awk -F'\t' '
        $1 != seen { printf "\n  %s\n", $1; seen = $1 }
        { printf "     %-20s %-9s %s\n", $2, $3, $4 }'
else
    log_warn "No app plane answered. The node's supervisor and the portal are the"
    echo "  two that have one; check ./endpoints.sh for whether either is up."
fi

# The hardware agents are not in the roster above: the overlay is what hands
# the node its devices AND turns those agents on, so an absent puck reads as
# agents missing from the list. Last, because it explains the list.
log_step "Node hardware"
node_hardware_report
