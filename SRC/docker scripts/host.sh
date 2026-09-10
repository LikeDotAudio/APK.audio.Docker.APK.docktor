#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🖥️ The daemon own account of the BOX, not of anything running on it.
#   ./host.sh
# TAB key/value rows, no header: ncpu, memory_bytes, then disk_root,
# disk_filesystem, disk_total_kb, disk_used_kb, disk_available_kb and
# disk_used_percent for the filesystem docker data root sits on.
# NOT nproc AND NOT os.cpu_count(): every percentage stats.sh prints is a share
# of ONE CORE, so the denominator has to be the one the daemon measures against.
# nproc and os.cpu_count() answer from the CALLING process affinity and cgroup,
# so a manager under a cpus: limit would report the limit and the ring above it
# would claim a full box on an idle one. docker info is answered by the daemon.
# The RAM half is here for the same reason: docker reports an unconstrained
# container memory limit as the whole machine, which holds only while nothing
# sets a limit. One mem_limit: makes the widest limit a CONTAINER one, and the
# ring then divides by 2 GiB on a 32 GiB box with no warning.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# ONE docker info, not three: core count, total memory and data root come out of
# the same round trip. readers.read_host() caches the two box facts for the life
# of the manager process (a running box grows no cores) while the disk rows are
# re-read, since the whole point of them is a number that moves.
info="$(docker info --format '{{.NCPU}}	{{.MemTotal}}	{{.DockerRootDir}}')" || exit 1
IFS=$'\t' read -r ncpu mem_total data_root <<< "$info"
printf 'ncpu\t%s\n' "$ncpu"
printf 'memory_bytes\t%s\n' "$mem_total"

# WHY THIS IS MORE THAN ONE FIELD: on 2026-09-09 the root filesystem filled and
# every writer failed in the same minute — journald, rsyslog, MariaDB mid-DDL —
# and three NetBox containers were still down hours later. The first signal a
# person got was a database refusing to start, which is the last place free
# space should surface.
# THE FILESYSTEM UNDER THE DAEMON DATA ROOT, not /: a daemon with data-root
# elsewhere puts the images on a different filesystem than the path everyone
# quotes.
# KIBIBYTES AND -P, NOT -h: df -h rounds to 1.4T, which cannot be compared
# against a threshold, and wraps long device names. The caller formats.
# A data root the daemon did not name, or one this process cannot see, is not an
# error — report the filesystem holding / and say which one it was.
[ -n "$data_root" ] && [ -d "$data_root" ] || data_root=/

if fs_row="$(df -Pk "$data_root" 2>/dev/null | tail -n1)"; then
    read -r fs total used avail pct _ <<< "$fs_row"
    printf 'disk_root\t%s\n' "$data_root"
    printf 'disk_filesystem\t%s\n' "$fs"
    printf 'disk_total_kb\t%s\n' "$total"
    printf 'disk_used_kb\t%s\n' "$used"
    printf 'disk_available_kb\t%s\n' "$avail"
    printf 'disk_used_percent\t%s\n' "${pct%\%}"
fi
