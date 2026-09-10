#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
# ==============================================================================
# 🧹⚡ APK.audio Delete Old, Rebuild Fresh & Mount Stack — the named front door.
# ==============================================================================
# THE WORK IS IN `docker scripts/rebuild-all.sh`. This file exists because the
# name is what is written down — in APK:Documentation, in the manual, and in the
# GUI button that has said "Delete Old, Rebuild & Mount" since before the script
# collection existed — and a path people have memorised is worth keeping alive
# even after the code behind it moved.
#
# It is a forwarder, not a copy. It carried its own compose arrays, its own
# ordering rule and its own gate invocation until 2026-09-03, all of which said
# the same things as APK.audio:mount.sh and the Python manager in slightly
# different words.
#
# What rebuild-all.sh does, in order: down both projects node-first with
# --remove-orphans, remove the named containers by hand, synch skills, run the
# PLAN-170.01 gates, `build --no-cache` both, `up -d --force-recreate` both,
# then print the health of the result. It leaves the bench DOWN if it fails
# after the first step, and nothing rolls back — that is what "delete old" means.
#
# Usage:
#   ./APK:DOCKERS/DockTor/SRC/APK.audio:DeleteOldRebuildAndMount.sh
# ==============================================================================

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker scripts/rebuild-all.sh" "$@"
