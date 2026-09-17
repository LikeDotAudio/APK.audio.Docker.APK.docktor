#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧽 Drop the BuildKit build cache — the layers a build wrote and then left.
#   ./clean-build-cache.sh          the cache no image needs any more
#   ./clean-build-cache.sh --all    EVERY byte, warm layers included
# THIS IS THE CACHE, NOT THE IMAGES. `docker builder prune` removes build
# records under /var/lib/docker/buildkit; the image a build just produced is a
# different object and is never touched, so a container started from it keeps
# running and a clean here can never unmount the bench.
# ⚠️ THE DEFAULT IS THE DANGLING HALF AND THAT IS DELIBERATE. `--all` is
#    `builder prune -a`, which throws away the warm layers the NEXT build would
#    have reused: a Rust compile that took twenty seconds off the cache takes
#    minutes again. Right when the disk is full, wrong on every other day.
# WHY IT IS ITS OWN FILE rather than a flag on prune.sh: every build path ends
# with it (rebuild.sh, rebuild-core.sh, rebuild-all.sh, up.sh, up-stack.sh, via
# clean_build_cache in _common.sh), and prune.sh also sweeps stopped containers
# and dangling images — acts a build has no business performing on its way out.
# prune.sh still cleans the cache too; it calls this file for it, so the wording
# and the reclaimed-bytes line have ONE spelling.
# Never fails a build: the caller treats a non-zero here as a warning, because a
# daemon that would not prune is not a reason to call a good image bad.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

if [ $ALL -eq 1 ]; then
    log_step "Build cache — ALL of it, including layers the next build would reuse"
    output="$(docker builder prune -af 2>&1)"
else
    log_step "Build cache — the records nothing references any more"
    output="$(docker builder prune -f 2>&1)"
fi
status=$?

# The id list is one line per deleted record and can run to hundreds; the tail
# is where the total is. Print the whole thing only when it is short enough to
# read, which is also the case where it says something other than "0B".
lines="$(printf '%s\n' "$output" | wc -l)"
if [ "$lines" -le 40 ]; then
    printf '%s\n' "$output"
else
    printf '%s\n' "$output" | tail -n 5
    log_info "($((lines - 5)) more cache records deleted above.)"
fi

if [ $status -ne 0 ]; then
    log_warn "docker builder prune exited $status — the cache was left as it is."
    announce BUILD_CACHE_CLEAN_FAILED "{\"all\":$ALL,\"exit_code\":$status}"
    exit $status
fi

# BuildKit says `Total:  1.2GB`; the older builder says `Total reclaimed space:
# 1.2GB`. Both spellings, because which one answers depends on the daemon and a
# missed match would report every clean as having freed nothing.
reclaimed="$(printf '%s\n' "$output" \
    | sed -n -e 's/^Total reclaimed space:[[:space:]]*//p' -e 's/^Total:[[:space:]]*//p' \
    | tail -n 1)"
[ -z "$reclaimed" ] && reclaimed="0B"

announce BUILD_CACHE_CLEANED "{\"all\":$ALL,\"reclaimed\":\"$reclaimed\"}"
log_info "Build cache cleaned — $reclaimed reclaimed."
