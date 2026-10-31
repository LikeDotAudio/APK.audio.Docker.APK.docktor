#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# ✅ DockTor's checks, as one command (2026-10-30 audit, DockTor #3).
#     ./check.sh            unit tests + static checks
#     ./check.sh --gates    … and K8/test-gates.sh (the pre-build gates; starts nothing)
# Run by hand before a push — the root CI deliberately verifies nothing. Starts,
# stops and builds nothing: every lane reads files or runs Python in-process.
#   1  python -m py_compile over SRC/manager
#   2  the unit tests (docker bus, readers, report documents vs schemas/,
#      bus identity, api routing), with the checkout's contracts/python on
#      PYTHONPATH so the contracts-spelling test runs, not skips
#   3  bash -n over every K8 verb
#   4  docker compose config -q for the manager compose file
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0
ok()  { echo "✅ $*"; }
bad() { echo "❌ $*"; fail=$((fail + 1)); }

python3 -m py_compile "$HERE"/SRC/manager/*.py && ok "py_compile SRC/manager" || bad "py_compile"
CONTRACTS="$ROOT/contracts/python"
if out="$(cd "$HERE/SRC" && PYTHONPATH="${CONTRACTS}${PYTHONPATH:+:$PYTHONPATH}" \
            python3 -m unittest discover -s manager -t . -p 'test_*.py' 2>&1)"; then
    ok "unit tests ($(grep -oE '^Ran [0-9]+ tests' <<<"$out"))"
else
    bad "unit tests"; tail -30 <<<"$out"
fi
for f in "$HERE"/K8/*.sh; do bash -n "$f" || bad "bash -n $f"; done && ok "bash -n K8/*.sh"
APKAUDIO_REPO="$ROOT" docker compose -f "$HERE/Docker/docker-compose.manager.yml" config -q \
    && ok "compose config" || bad "compose config"
if [ "${1:-}" = --gates ]; then
    "$HERE/K8/test-gates.sh" && ok "test-gates.sh" || bad "test-gates.sh"
fi
echo "— $fail failed"
[ "$fail" -eq 0 ]
