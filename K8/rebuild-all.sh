#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧹⚡ Delete old, rebuild fresh, mount. The clean slate.
#   ./rebuild-all.sh
#   1. Down every stack, node before core.
#   2. Remove the named containers by hand — a renamed or orphaned instance
#      still holds the name compose is about to want.
#   3. Gates. Refusal stops here, with the stack already DOWN.
#   4. build --no-cache, every project.
#   5. up -d --force-recreate, core before node.
# ⚠️ THIS LEAVES THE BENCH DOWN IF IT FAILS AFTER STEP 1 and nothing rolls back.
#    The gates run at step 3 rather than step 0 because a gate failure is the one
#    outcome where you want the old containers gone rather than half-replaced.
# A Rust build from scratch takes minutes, and --no-cache means every time.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

log_step "1/5. Unmounting Old Container Stacks & Cleaning Orphans..."
# NO --remove-orphans: five of the nine compose files share the project
# apk-audio, so the flag would have the node down delete the core stack out from
# under the loop that is about to bring it down itself. The by-name sweep below
# is what catches a container compose has lost track of.
for_each_stack reverse down || log_warn "Compose down completed with warnings."

# By NAME, because a container compose has lost track of still owns the name.
docker rm -f Storage-MariaDB Storage-Portal Storage-Broker Node-BareMetal \
             Broker-Mosquitto Broker-SqlCapture Node-BareMetal-Broker \
             Portal-Broker Portal-Orchestrator Portal-Heartbeat \
             apkaudio-mariadb apkaudio-broker apk_audio_web \
             Ember-Docs Ember-Provider AES70-Site \
             2>/dev/null || true

log_step "2/5. Synchronizing Ecosystem Skills & Metadata..."
synch_skills

log_step "3/5. Enforcing Upstream Pre-Build Container Test Gates (PLAN-170.01)..."
if ! "$MANAGEMENT_SCRIPTS_DIR/test-gates.sh"; then
    log_error "Upstream pre-build test gates failed! Refusing docker build/mount."
    log_error "The old containers are already removed, so the stack is DOWN."
    exit 1
fi

log_step "4/5. Building Fresh Container Images (No Cache)..."
announce COMPOSE_RUN "{\"action\":\"build --no-cache\",\"services\":\"all\"}"
# ⚠️ $? INSIDE `if ! cmd; then` IS THE NEGATION EXIT CODE, ALWAYS 0. A failed
#    build announced exit_code: 0, printed "Build FAILED (exit 0)" and exited 0,
#    so the manager reported a success over a bench it had just taken down. Take
#    the status from the command itself, the way step 5 does.
for_each_stack forward build --no-cache
status=$?
announce COMPOSE_RESULT "{\"action\":\"build --no-cache\",\"exit_code\":$status}"
if [ $status -ne 0 ]; then
    log_error "Build FAILED (exit $status). Nothing was rolled back; the stack is DOWN."
    exit $status
fi

log_step "5/5. Mounting Fresh Container Stack (Force Recreate)..."
# The same report up.sh prints: this is the other mounting verb, and a
# --force-recreate is where a device that appeared since the last mount is picked
# up or lost. BEFORE the mount, because a failed build never reaches status.sh.
node_hardware_report
if [ "${APKAUDIO_NO_KABOOM:-0}" != "1" ]; then
    "$MANAGEMENT_SCRIPTS_DIR/free-ports.sh"
fi
announce COMPOSE_RUN "{\"action\":\"up --force-recreate\",\"services\":\"all\"}"
for_each_stack forward up -d --force-recreate
status=$?
announce COMPOSE_RESULT "{\"action\":\"up --force-recreate\",\"exit_code\":$status}"
if [ $status -ne 0 ]; then
    log_error "Mount FAILED (exit $status) after a successful build. The images are fresh; the stack is not up."
    exit $status
fi

# AFTER THE MOUNT, not after step 4: pruning between the build and the up would
# hold the bench down for the length of the sweep, and the cache is no smaller
# for having been dropped a minute earlier. This is the build that leaves the
# most behind — --no-cache writes a full layer set for every project and
# reclaims nothing on its own.
clean_build_cache "the clean rebuild"

echo -e "\n${BOLD}${GREEN}✅ APK.audio Ecosystem Successfully Rebuilt & Mounted!${OFF}\n"

# Open browser to DockTor Web UI immediately after DockTor stack is up
log_step "Loading DockTor Web UI (http://127.0.0.1:8765/)..."
python3 -c "import webbrowser; webbrowser.open('http://127.0.0.1:8765/')" 2>/dev/null || true

exec "$MANAGEMENT_SCRIPTS_DIR/status.sh"

