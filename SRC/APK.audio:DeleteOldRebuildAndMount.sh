#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧹⚡ Delete old, rebuild fresh and mount — the named front door.
#   ./APK:PODS/Docktor/SRC/APK.audio:DeleteOldRebuildAndMount.sh
# A FORWARDER, NOT A COPY. The work is in `docker scripts/rebuild-all.sh`; this
# file exists because the name is what is written down — in the docs, the manual
# and the button — and a memorised path is worth keeping alive after the code
# behind it moved. It carried its own compose arrays, ordering rule and gate
# invocation until 2026-09-03.
# ⚠️ rebuild-all.sh leaves the bench DOWN if it fails after the first step, and
#    nothing rolls back. That is what "delete old" means.

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker scripts/rebuild-all.sh" "$@"
