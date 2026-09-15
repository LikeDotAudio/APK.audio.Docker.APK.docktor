#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🚀 APK.audio master ecosystem mount — the named front door.
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh            start everything
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh watch      start, then live watch
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh status     health of every stack
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh rebuild    clean rebuild + mount
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh down       stop everything
# THIS FILE IS A DISPATCHER AND NOTHING ELSE. Every verb it names is one file in
# `docker scripts/` beside it, and the rules those files hold — the compose
# arrays, the projects, the order, the port eviction, the gates — are stated once
# in _common.sh. It used to carry its own copy of all of them.

set -e

MANAGEMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$MANAGEMENT_DIR/docker scripts"
MANAGER="$MANAGEMENT_DIR/../../K8:runner.py"

case "${1:-up}" in
    up)
        # up.sh runs the gates, synchs the skills and evicts the ports before
        # compose binds. Nothing to add here.
        "$SCRIPTS/up.sh"
        "$SCRIPTS/status.sh"
        ;;
    watch)
        "$SCRIPTS/up.sh"
        "$SCRIPTS/status.sh"
        # The watcher is the manager, not a sleep loop here: it also starts the
        # one-minute resource sampler, so watching the bench publishes it.
        python3 "$MANAGER" watch
        ;;
    status)  "$SCRIPTS/status.sh";;
    rebuild) "$SCRIPTS/rebuild-all.sh";;
    down)    "$SCRIPTS/down.sh";;
    test)    "$SCRIPTS/test-gates.sh" && "$SCRIPTS/verify.sh";;
    *)
        echo "Usage: $0 {up|watch|status|rebuild|down|test}"
        echo
        echo "Every verb above is one file in 'docker scripts/'; run them directly too:"
        ls -1 "$SCRIPTS" | grep -v '^_' | sed 's/^/  /'
        exit 1
        ;;
esac
