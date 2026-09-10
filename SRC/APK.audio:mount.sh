#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
# ==============================================================================
# 🚀 APK.audio Master Ecosystem Mount — the named front door.
# ==============================================================================
# The whole ecosystem in one command:
#
#   1. MQTT Broker (Storage-Broker)          — house MQTT server (1883 & 9001)
#   2. APK.audio Web (Storage-Portal)        — web interface & MariaDB (3306 & 8080)
#   3. BareMetal Node (Node-BareMetal)       — supervisor + every bare-metal agent
#
# THIS FILE IS A DISPATCHER AND NOTHING ELSE. Every verb it names is one file in
# `docker scripts/` beside it, and the rules those files hold — the compose
# command array, the two projects, the start order, the port eviction, the
# PLAN-170.01 gates — are stated once in `docker scripts/_common.sh`.
#
# It used to carry its own copy of all of them, as did
# APK.audio:DeleteOldRebuildAndMount.sh and the Python in
# Manager:docktor.py. Three copies of a rule is three chances for one
# to be edited alone.
#
# Usage:
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh           # start everything
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh watch      # start, then live watch
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh status     # health of both stacks
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh rebuild    # clean rebuild + mount
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:mount.sh down       # stop everything
# ==============================================================================

set -e

MANAGEMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$MANAGEMENT_DIR/docker scripts"
MANAGER="$MANAGEMENT_DIR/../../Manager:docktor.py"

case "${1:-up}" in
    up)
        # up.sh runs the gates, synchs the skills, stages the broker config and
        # evicts the ports before compose binds. Nothing to add here.
        "$SCRIPTS/up.sh"
        "$SCRIPTS/status.sh"
        ;;
    watch)
        "$SCRIPTS/up.sh"
        "$SCRIPTS/status.sh"
        # The watcher is the manager's, not a `sleep` loop here: it also starts
        # the one-minute resource sampler, so watching the bench publishes it.
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
