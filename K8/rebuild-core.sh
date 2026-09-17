#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🔨 Rebuild and restart ONE service in the core project, leaving the rest up.
#   ./rebuild-core.sh            default service: apk-audio
#   ./rebuild-core.sh mariadb
# build then up -d for a single service in the apk-audio project. The BareMetal
# node is deliberately untouched: different project, different image, and a
# minutes-long Rust compile a targeted portal rebuild has no reason to pay.
# Still gated: a narrower build is not an unchecked one.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

SERVICE="${1:-apk-audio}"

log_step "Enforcing upstream pre-build container test gates..."
if ! "$MANAGEMENT_SCRIPTS_DIR/test-gates.sh"; then
    log_error "Rebuild cancelled: upstream pre-build test gates failed."
    exit 1
fi

log_step "Preparing the host (skills, broker config, ports)..."
# A failed prepare is a refused up, not a warning: it fails on a broker config
# that could not be staged, and compose would bind the daemon empty stand-in
# over mosquitto.conf and start a broker that exits.
prepare_for_up || exit 1

log_step "Rebuilding '$SERVICE' in project apk-audio..."
announce COMPOSE_RUN "{\"action\":\"build\",\"services\":\"$SERVICE\"}"
"${COMPOSE_CORE[@]}" build "$SERVICE" || { status=$?; log_error "Build failed (exit $status)."; exit $status; }
"${COMPOSE_CORE[@]}" up -d "$SERVICE"
status=$?
announce COMPOSE_RESULT "{\"action\":\"build+up\",\"services\":\"$SERVICE\",\"exit_code\":$status}"
[ $status -ne 0 ] && { log_error "Restart of '$SERVICE' failed (exit $status)."; exit $status; }

clean_build_cache "the '$SERVICE' rebuild"

echo -e "\n${BOLD}${GREEN}✅ '$SERVICE' rebuilt and running.${OFF}"
