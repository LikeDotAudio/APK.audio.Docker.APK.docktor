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

# `up -d --build` IS A BUILD PATH. It rebuilds whatever Dockerfile changed and
# leaves the superseded layers behind exactly as rebuild-all.sh does, so the
# same sweep belongs here — after the mount, and never after a failed one.
clean_build_cache "the mount"

echo -e "\n${BOLD}${GREEN}✅ APK.audio Ecosystem Containers Active!${OFF}"

# THE BROWSER IS NOT OPENED HERE ANY MORE. It was, on this line — the last line
# of a run that mounts ten stacks — so the page that draws a mount arrived after
# the mount. DockTor is first in for_each_stack now and open_manager_site() is
# called the moment ITS up returns, which on a cold bench is a minute in rather
# than ten. On a run that never reached DockTor this says where it would be.
[ "${APKAUDIO_SITE_OPENED:-0}" = "1" ] || log_info "DockTor: $MANAGER_URL"

exit 0
