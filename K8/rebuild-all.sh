#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧹⚡ Delete old, rebuild fresh, mount. The clean slate.
#   ./rebuild-all.sh
#   1. Down every stack, node before core.
#   2. Remove the named containers by hand — a renamed or orphaned instance
#      still holds the name compose is about to want.
#   3. Gates. Refusal stops here, with the stack already DOWN.
#   4. DOCKTOR, ALONE AND FIRST: build it, mount it, open its page. Everything
#      after this step is watched from a browser instead of a terminal.
#   5. build --no-cache, every other project.
#   6. up -d --force-recreate, core before node.
# ⚠️ THIS LEAVES THE BENCH DOWN IF IT FAILS AFTER STEP 1 and nothing rolls back.
#    The gates run at step 3 rather than step 0 because a gate failure is the one
#    outcome where you want the old containers gone rather than half-replaced.
# A Rust build from scratch takes minutes, and --no-cache means every time.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

log_step "1/6. Unmounting Old Container Stacks & Cleaning Orphans..."
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

log_step "2/6. Synchronizing Ecosystem Skills & Metadata..."
synch_skills

log_step "3/6. Enforcing Upstream Pre-Build Container Test Gates (PLAN-170.01)..."
if ! "$MANAGEMENT_SCRIPTS_DIR/test-gates.sh"; then
    log_error "Upstream pre-build test gates failed! Refusing docker build/mount."
    log_error "The old containers are already removed, so the stack is DOWN."
    exit 1
fi

# ── 4/6. DOCKTOR FIRST, AND THIS PHASE IS THE WHOLE REASON THE STEPS RENUMBERED.
# A clean rebuild is ten minutes of docker output, and the tool that draws what
# is happening was the LAST thing mounted — so the dashboard turned up after the
# thing it exists to watch, and the browser opened on the final line of the run.
# Now the manager is built and mounted before anything else is built, its site is
# raised the moment it answers, and the remaining eight stacks build and mount
# with the page already open and following the log.
# ⚠️ NOT FROM INSIDE THE MANAGER: compose would stop the container running this
#    script between the stop and the start — the same rule up-stack.sh and
#    rebuild.sh carry. From in there this phase is skipped and DockTor is
#    rebuilt from a host terminal, or by the PANIC reboot which swaps it.
log_step "4/6. Building and mounting DockTor FIRST, so it can show you the rest..."
if [ -f /.dockerenv ]; then
    log_warn "Running inside $MANAGER_CONTAINER — skipping the DockTor phase (it cannot replace itself)."
else
    "$MANAGEMENT_SCRIPTS_DIR/storage-volume.sh" --ensure >/dev/null \
        || log_warn "Storage volume not ready; compose will name what it could not mount."
    announce COMPOSE_RUN "{\"action\":\"build --no-cache\",\"services\":\"manager\"}"
    "${COMPOSE_MANAGER[@]}" build --no-cache
    manager_status=$?
    if [ $manager_status -ne 0 ]; then
        # NOT FATAL. A manager that will not build is not a reason to leave the
        # bench down — panic-reboot.sh says the same thing in the same words.
        log_error "DockTor build FAILED (exit $manager_status). Carrying on with the bench rebuild."
        announce COMPOSE_RESULT "{\"action\":\"build --no-cache\",\"services\":\"manager\",\"exit_code\":$manager_status}"
    else
        "${COMPOSE_MANAGER[@]}" up -d --force-recreate
        manager_status=$?
        announce COMPOSE_RESULT "{\"action\":\"build+up\",\"services\":\"manager\",\"exit_code\":$manager_status}"
        if [ $manager_status -eq 0 ]; then
            open_manager_site
        else
            log_error "DockTor did not come up (exit $manager_status). The bench rebuild continues without it."
        fi
    fi
    # Built and mounted: the two passes below must not do either again.
    export APKAUDIO_SKIP_STACKS="docktor"
fi

log_step "5/6. Building Fresh Container Images (No Cache)..."
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

log_step "6/6. Mounting Fresh Container Stack (Force Recreate)..."
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

# THE BROWSER WAS RAISED IN STEP 4, minutes ago, and has been drawing every step
# since. This line used to be where it opened — the end of the run, which is the
# one moment the page has nothing left to show you.
[ "${APKAUDIO_SITE_OPENED:-0}" = "1" ] || log_info "DockTor: $MANAGER_URL"

exec "$MANAGEMENT_SCRIPTS_DIR/status.sh"

