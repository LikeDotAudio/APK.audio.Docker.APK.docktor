#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🚨♻️ The second press of PANIC — reboot the manager, rebuild the bench.
#   ./panic-reboot.sh [sender] [--dry-run]        # safe to run by hand from the host
# panic.sh spares the manager, so on a bench where nothing else runs the only
# thing a second press can mean is the manager itself.
#   1. Rebuild the manager image FROM THE CHECKOUT and force-recreate it, so the
#      page comes back first and comes back new.
#   2. rebuild-all.sh: every other image from the code, stacks remounted.
#   3. stacks.sh --report — name the stacks that did NOT come back. Step 2
#      remounts the eight compose files for_each_stack drives, and the panic
#      before it removed containers host-wide, so anything with no verb behind
#      it is gone and stays gone.
#   4. staleness.sh --report — what came back still running the old code.
# THE MANAGER GOES FIRST ON PURPOSE: step 2 takes minutes (--no-cache over a Rust
# workspace) and the operator is looking at a dead tab for all of it.
# ⚠️ MUST NOT RUN INSIDE THE CONTAINER IT RECREATES. A compose client inside that
#    container is killed between the stop and the start, leaving the old gone and
#    the new never started. panic.sh starts this DETACHED as a sibling off the
#    manager own image, or in line when the panic came from a host terminal.
# NOT rebuild-all.sh with one more line: that verb runs the pre-build gates and
# REFUSES to build when they fail, which is right for the bench and wrong for
# the tool you are trying to get back on screen. Step 1 gates on nothing.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

DRY_RUN=0
SENDER=""
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1;;
        -*) log_error "Unknown option: $arg"
            echo "Usage: ./panic-reboot.sh [sender] [--dry-run]"; exit 2;;
        *)  [ -z "$SENDER" ] && SENDER="$arg";;
    esac
done
SENDER="${SENDER:-PANIC_REBOOT}"

if [ "$DRY_RUN" = "1" ]; then
    echo "🧪 PANIC REBOOT --dry-run — rehearsal for rebuilding $MANAGER_CONTAINER and the stacks this tool drives"
else
    echo "🚨♻️  PANIC REBOOT — rebuilding $MANAGER_CONTAINER and the stacks this tool drives, from the code"
fi
echo "============================================================"

# The one export the manager compose file has no default for: source and target
# of its repository bind are one variable, and :? fails the file rather than
# mounting the checkout where the daemon does not share it.
export APKAUDIO_REPO="$REPO_ROOT"

if [ "$DRY_RUN" = "1" ]; then
    log_step "PANIC REBOOT --dry-run: what a real reboot would rebuild and swap"
    echo "  Nothing is killed, removed, built, mounted or broadcast by this run."
    echo ""
    log_step "1/3. Rehearsal: DockTor swap"
    echo "  Container:    $MANAGER_CONTAINER"
    echo "  Compose file: $MANAGER_COMPOSE_FILE"
    echo "  Command:      ${COMPOSE_MANAGER[*]} up -d --build --force-recreate"
    echo "  Action:       Would rebuild $MANAGER_CONTAINER from code and force-recreate container."
    echo ""
    log_step "2/3. Rehearsal: Upstream pre-build test gates (rebuild-all.sh step 3)"
    "$MANAGEMENT_SCRIPTS_DIR/test-gates.sh" || true
    echo ""
    log_step "3/3. Rehearsal: Stack images and services that rebuild-all.sh would build (--no-cache)"

    order=(logger core mqtt portal nmos aes70 ember netbox node)
    for stack in "${order[@]}"; do
        case "$stack" in
            logger) compose=("${COMPOSE_LOGGER[@]}");;
            core)   compose=("${COMPOSE_CORE[@]}");;
            mqtt)   compose=("${COMPOSE_MQTT[@]}");;
            portal) compose=("${COMPOSE_PORTAL[@]}");;
            nmos)   compose=("${COMPOSE_NMOS[@]}");;
            aes70)  compose=("${COMPOSE_AES70[@]}");;
            netbox) compose=("${COMPOSE_NETBOX[@]}");;
            ember)  compose=("${COMPOSE_EMBER[@]}");;
            node)   compose=("${COMPOSE_NODE[@]}");;
        esac

        cfg_json="$("${compose[@]}" config --format json 2>/dev/null)"
        build_svcs=$(python3 -c "import sys, json; d=json.loads(sys.argv[1]); svcs=[k for k,v in d.get('services',{}).items() if 'build' in v]; print(', '.join(svcs) if svcs else 'none (pre-built images)')" "$cfg_json" 2>/dev/null || echo "error parsing compose config")
        all_svcs=$(python3 -c "import sys, json; d=json.loads(sys.argv[1]); svcs=list(d.get('services',{}).keys()); print(', '.join(svcs))" "$cfg_json" 2>/dev/null || echo "error parsing compose config")
        echo "  • Stack ${stack}:"
        echo "      all services: ${all_svcs}"
        echo "      rebuilds:     ${build_svcs}"
    done
    echo ""
    log_step "The bench as it stands today"
    "$MANAGEMENT_SCRIPTS_DIR/stacks.sh" || true

    announce PANIC_REBOOT_DRY_RUN "{\"sender\":\"$SENDER\",\"manager\":\"$MANAGER_CONTAINER\",\"repo\":\"$REPO_ROOT\"}"
    echo -e "\n🧪 DRY RUN COMPLETE — nothing was stopped, built, swapped or remounted."
    echo "   Run without --dry-run to actually press it."
    exit 0
fi

announce PANIC_REBOOT_START "{\"sender\":\"$SENDER\",\"manager\":\"$MANAGER_CONTAINER\",\"repo\":\"$REPO_ROOT\"}"

log_step "1/2. Rebuilding DockTor from the code and swapping it out"
echo "  repository bound at: $APKAUDIO_REPO"
# --build AND --force-recreate: --build alone reuses a container whose image tag
# has not changed, and docktor:local is rebuilt in place, so compose sees
# the same reference and leaves the old container on the old layers.
announce COMPOSE_RUN "{\"action\":\"up --build --force-recreate\",\"services\":\"manager\"}"
"${COMPOSE_MANAGER[@]}" up -d --build --force-recreate
manager_status=$?
announce COMPOSE_RESULT "{\"action\":\"up --build --force-recreate\",\"services\":\"manager\",\"exit_code\":$manager_status}"

if [ $manager_status -ne 0 ]; then
    log_error "The manager did not come back (exit $manager_status)."
    echo "  Read the build output above. The bench rebuild below is attempted anyway:"
    echo "  a manager that will not build is not a reason to leave the stacks down."
    announce PANIC_REBOOT_MANAGER_FAILED "{\"sender\":\"$SENDER\",\"exit_code\":$manager_status}"
else
    log_info "$MANAGER_CONTAINER rebuilt from the code and running."
    announce PANIC_REBOOT_MANAGER_UP "{\"sender\":\"$SENDER\",\"container\":\"$MANAGER_CONTAINER\"}"
fi

log_step "2/2. Rebuilding every other image from the code and remounting"
echo "  This is rebuild-all.sh: gates, build --no-cache, up --force-recreate."
echo "  It takes minutes, and it leaves the bench DOWN if it fails after the first step."
"$MANAGEMENT_SCRIPTS_DIR/rebuild-all.sh"
bench_status=$?
announce PANIC_REBOOT_BENCH_RESULT "{\"sender\":\"$SENDER\",\"exit_code\":$bench_status}"

worst=0
[ $manager_status -ne 0 ] && worst=$manager_status
[ $bench_status -ne 0 ] && worst=$bench_status
announce PANIC_REBOOT_COMPLETE "{\"sender\":\"$SENDER\",\"manager_exit\":$manager_status,\"bench_exit\":$bench_status}"

if [ $worst -eq 0 ]; then
    # SCOPED, and the scope is the point: this rebuilt the manager and the
    # stacks for_each_stack drives, not "the bench". Saying so is what makes the
    # report below read as the rest of the answer.
    echo -e "\n${BOLD}${GREEN}✅ PANIC REBOOT COMPLETE — the manager and the stacks this tool drives are rebuilt from the code.${OFF}\n"
else
    log_error "PANIC REBOOT finished with failures (manager $manager_status, bench $bench_status)."
fi

# 3. What is still missing, measured AFTER the remount: a stack step 2 brought
# back does not appear, one that never had a verb does. || true — an account of
# the reboot, not a gate on it.
log_step "Stacks this reboot did not restore"
"$MANAGEMENT_SCRIPTS_DIR/stacks.sh" --report || true

# 4. Whether the rebuild took. Anything STILL older than its sources after step
# 2 means the build missed a file — a cache layer that should have been busted, a
# COPY naming a path that moved — which a green REBUILD COMPLETE would hide.
# The one automated caller of the STACKS_STALE mode, and the moment the answer
# should be "nothing". || true.
log_step "Images still older than the code after the rebuild"
"$MANAGEMENT_SCRIPTS_DIR/staleness.sh" --report || true

exit $worst
