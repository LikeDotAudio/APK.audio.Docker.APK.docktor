#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🔥 Phoenix — Burn it all down and rise from the ashes.
#    Nukes every container, image, volume, network and cache on this host,
#    then clean-rebuilds and remounts the entire ecosystem from scratch.
#      ./phoenix.sh
#      ./phoenix.sh --include-manager
#      ./phoenix.sh --dry-run
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

log_step "🔥 PHOENIX — 1/2. Burning down every container, image, volume & cache..."

# Pass consent flag --yes-nuke-everything to nuke.sh plus any user args
"$MANAGEMENT_SCRIPTS_DIR/nuke.sh" --yes-nuke-everything "$@"
nuke_status=$?

if [ $nuke_status -ne 0 ]; then
    if [ $nuke_status -eq 2 ]; then
        log_warn "Nuke phase completed with rehearsal/refusal exit code ($nuke_status). Stopping Phoenix sequence."
    else
        log_error "Nuke phase failed with exit code ($nuke_status). Aborting Phoenix sequence."
    fi
    exit $nuke_status
fi

log_step "🔥 PHOENIX — 2/2. Rising from the ashes: Clean Rebuilding & Mounting Ecosystem..."
"$MANAGEMENT_SCRIPTS_DIR/rebuild-all.sh"
rebuild_status=$?

if [ $rebuild_status -ne 0 ]; then
    log_error "Phoenix rebuild phase failed with exit code ($rebuild_status)."
    exit $rebuild_status
fi

echo -e "\n${BOLD}${GREEN}🔥 PHOENIX COMPLETE — Ecosystem fully burned down and reborn fresh from code!${OFF}\n"
