#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🚀 Mount the ecosystem. Gates first, ports second, compose third.
#   ./up.sh            every stack
#   ./up.sh apk-audio  one service, still gated
# up -d --build across every compose project, core before node: the node agents
# connect to MQTT_HOST:1883, which the core stack publishes, and compose cannot
# express depends_on ACROSS projects, so the order lives in _common.sh.
# THE GATES REFUSE: a non-zero test-gates.sh stops this before anything builds.
# APKAUDIO_NO_GATES=1 only when debugging the gates themselves.
# APKAUDIO_NO_KABOOM=1 leaves a held port alone and lets compose report it.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

log_step "Enforcing upstream pre-build container test gates..."
if [ "${APKAUDIO_NO_GATES:-0}" = "1" ]; then
    log_warn "Test gates SKIPPED by APKAUDIO_NO_GATES=1."
elif ! "$MANAGEMENT_SCRIPTS_DIR/test-gates.sh"; then
    log_error "Mount cancelled: upstream pre-build test gates failed."
    exit 1
fi

log_step "Preparing the host (skills, ports)..."
# The broker config is COPYed into the image by Dockerfile.broker, so no host
# path is left to go missing between a reboot and an up.
prepare_for_up || exit 1

# WHICH NODE IS ABOUT TO BE MOUNTED: _common.sh decided at source time whether
# COMPOSE_NODE names the hardware overlay and said nothing, so a bench whose
# by-id path moved was skipped in silence and came up looking healthy.
node_hardware_report

if [ $# -gt 0 ]; then
    log_step "Starting service(s): $*"
    announce COMPOSE_RUN "{\"action\":\"up\",\"services\":\"$*\"}"
    "${COMPOSE_CORE[@]}" up -d --build "$@"
    status=$?
else
    log_step "Starting both container stacks..."
    announce COMPOSE_RUN "{\"action\":\"up\",\"services\":\"all\"}"
    for_each_stack forward up -d --build
    status=$?
fi

announce COMPOSE_RESULT "{\"action\":\"up\",\"exit_code\":$status}"
if [ $status -ne 0 ]; then
    log_error "Mount FAILED — compose exited $status. Read the output above."
    exit $status
fi

echo -e "\n${BOLD}${GREEN}✅ APK.audio Ecosystem Containers Active!${OFF}"

# Open browser to DockTor Web UI immediately after DockTor container is up
log_step "Loading DockTor Web UI (http://127.0.0.1:8765/)..."
python3 -c "import webbrowser; webbrowser.open('http://127.0.0.1:8765/')" 2>/dev/null || true

exit 0
