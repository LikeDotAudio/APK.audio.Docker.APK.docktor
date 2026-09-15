#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🛡️ The upstream pre-build gates, as a command.
#   ./test-gates.sh
# Every gate that must pass BEFORE a build or mount, exiting non-zero if any
# fails. Nothing here starts, stops or builds a container: a gate that could
# change the thing it judges is not a gate.
# THE REFUSAL IS THE POINT — up.sh, rebuild-all.sh and rebuild-core.sh each run
# this first and abort on a non-zero exit.
# A MISSING GATE SCRIPT IS NEITHER A PASS NOR A FAILURE: it is reported ABSENT
# and counted, so "0 gates ran" reads as a broken checkout.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

echo "🛡️ Enforcing Upstream Pre-Build Container Test Gates (PLAN-170.01)..."
echo "======================================================================"

failed=()
ran=0
absent=0

# One gate: a label, the service it speaks for, and the script that decides.
run_gate() {
    local label="$1" service="$2" script="$3"
    if [ ! -f "$script" ]; then
        log_warn "[Gate ABSENT] $label — no script at $script"
        announce TEST_GATE_ABSENT "{\"gate\":\"$label\",\"script\":\"$script\"}"
        absent=$((absent + 1))
        return 0
    fi
    ran=$((ran + 1))
    local output
    if output="$( cd "$REPO_ROOT" && python3 "$script" 2>&1 )"; then
        echo "  ✓ [Gate Pass] $label"
    else
        echo "  ✗ [Gate FAIL] $label:"
        echo "$output" | sed 's/^/      /'
        failed+=("$service")
    fi
}

run_gate "MQTT Broker candidate order verified." \
         "apkaudio-broker" \
         "$BAREMETAL_ROOT/test/check-broker-candidates.py"

run_gate "Static boot snapshots verified." \
         "apk-audio (Static Boot)" \
         "$REPO_ROOT/.apk.scripts/check_static_boot.py"

if [ ${#failed[@]} -gt 0 ]; then
    echo "======================================================================"
    echo "💥 REFUSING DOCKER BUILD / MOUNT: ${#failed[@]} upstream test gate(s) FAILED!"
    echo "   Failed Services: $(IFS=', '; echo "${failed[*]}")"
    echo "   Build cancelled in accordance with PLAN-170.01 refusal law."
    echo
    announce TEST_GATES_REFUSED "{\"failed\":${#failed[@]},\"ran\":$ran}"
    exit 1
fi

announce TEST_GATES_PASSED "{\"gates\":$ran,\"absent\":$absent}"
echo "  ✅ All $ran upstream pre-build container test gates PASSED ($absent absent)."
echo "======================================================================"
echo
