#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🗄️ WHAT IS ON THE DISK, BY VOLUME: the reading the VOLUMES tab draws.
#   ./volumes.sh          every volume with its size, plus the four totals
#   ./volumes.sh --fast   skip the sizes (one cheap call; `size_bytes` is -1)
# THREE QUESTIONS, ONE SNAPSHOT, and they are different questions:
#   · HOW BIG IS THE DISK and how much of it is gone      → the `disk` row
#   · WHAT IS DOCKER HOLDING, split four ways             → the `usage` rows
#   · WHICH VOLUME IS EATING IT                           → the `volume` rows
# The tab graphs the first two over time; the third is the table under the
# graph. disk.sh answers the first two already, in a shape made for a terminal;
# this file answers all three in one call, in bytes, so a series drawn from it
# has one unit and no parsing of `1.8T` in a browser.
# ⚠️ THE SIZES COST A WALK OF /var/lib/docker/volumes. `docker system df -v` is
#    seconds on a bench with real data and that is why --fast exists and why
#    nothing here runs on a five-second repaint. The sampler beat is minutes.
# FIELD ORDER IS THE CONTRACT (readers.py slices it, padding rather than
# raising), TAB separated, one row per line:
#   disk    <data_root> <total_bytes> <used_bytes> <available_bytes> <used_pct>
#   usage   <kind> <count> <size_bytes> <reclaimable_bytes> <active_count>
#           kind ∈ images | containers | volumes | cache
#   volume  <name> <driver> <size_bytes> <links> <project> <role> <mountpoint>
#           <device> <measured>
#           role ∈ storage | logs | ours | anonymous | other
#           measured ∈ docker | folder | none — HOW the size was got, and it
#           matters: `docker system df -v` SKIPS a bind-backed volume entirely
#           (it listed 17 of this bench's 18), so the log volume and DockTor's
#           own storage — the two that are folders — are exactly the ones it
#           cannot size. Those are walked with du. `none` is size -1, which is
#           "not measured" and never drawn as a zero.
#   storage <key> <value>        — storage-volume.sh, verbatim, for the pointer
# BYTES, NOT `157.1MB`: docker prints a human string per row and the tab needs
# to add them up. The conversion is here because it is a docker unit table
# (decimal for df, which is why kB is 1000 and KiB is 1024) and the package
# that reads this file is not allowed to know one.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

# `6.938GB (30%)` → 6938000000. The parenthetical is docker's share and is
# dropped; an empty or unparseable value is 0, never a blank field.
to_bytes() {
    printf '%s' "${1:-0}" | awk '{
        s = $0; sub(/ *\(.*\)$/, "", s); gsub(/ /, "", s)
        if (!match(s, /^[0-9.]+/)) { print 0; exit }
        n = substr(s, RSTART, RLENGTH); u = toupper(substr(s, RSTART + RLENGTH))
        m = 1
        if      (u == "KB")  m = 1000
        else if (u == "MB")  m = 1000000
        else if (u == "GB")  m = 1000000000
        else if (u == "TB")  m = 1000000000000
        else if (u == "KIB") m = 1024
        else if (u == "MIB") m = 1048576
        else if (u == "GIB") m = 1073741824
        else if (u == "TIB") m = 1099511627776
        printf "%.0f", n * m
    }'
}

# ── THE DISK ITSELF. df -Pk, not df -h: POSIX output is one line per filesystem
# with no wrapping, and kibibytes are a number rather than `1.8T`.
data_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
[ -z "$data_root" ] && data_root="/var/lib/docker"
if [ -d "$data_root" ]; then
    read -r _ total_kb used_kb avail_kb pct _ <<< "$(df -Pk "$data_root" | tail -n1)"
    printf 'disk\t%s\t%s\t%s\t%s\t%s\n' "$data_root" \
        "$((total_kb * 1024))" "$((used_kb * 1024))" "$((avail_kb * 1024))" "${pct%\%}"
fi

# ── THE FOUR TOTALS. One `docker system df` call; the -v walk below is a
# second and much slower one, which is why the totals are taken from the cheap
# call and not summed out of the volume rows: images and build cache are in
# neither, and they are most of it.
while IFS=$'\t' read -r type count active size reclaimable; do
    [ -z "$type" ] && continue
    case "$type" in
        Images)         kind=images;;
        Containers)     kind=containers;;
        "Local Volumes") kind=volumes;;
        "Build Cache")  kind=cache;;
        *)              kind="$(printf '%s' "$type" | tr 'A-Z ' 'a-z-')";;
    esac
    printf 'usage\t%s\t%s\t%s\t%s\t%s\n' "$kind" "${count:-0}" \
        "$(to_bytes "$size")" "$(to_bytes "$reclaimable")" "${active:-0}"
done < <(docker system df --format '{{.Type}}\t{{.TotalCount}}\t{{.Active}}\t{{.Size}}\t{{.Reclaimable}}' 2>/dev/null)

# ── PER VOLUME. Two calls joined on the name, because neither says everything:
# `system df -v` has the SIZE and the link count and no driver or mountpoint,
# `volume ls` has those and the labels and no size. --fast skips the first.
declare -A VOLUME_SIZE=()
declare -A VOLUME_LINKS=()
if [ $FAST -eq 0 ]; then
    while IFS=$'\t' read -r name size links; do
        [ -z "$name" ] && continue
        VOLUME_SIZE["$name"]="$(to_bytes "$size")"
        VOLUME_LINKS["$name"]="${links:-0}"
    done < <(docker system df -v --format '{{range .Volumes}}{{.Name}}	{{.Size}}	{{.Links}}
{{end}}' 2>/dev/null)
fi

# 64 hex characters is docker's own name for a volume nobody named — the ones
# a `docker run -v /data` leaves behind. Worth a role of its own: they are
# usually the surprise in the table.
is_anonymous() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# THE FOLDER WALK, and it is deliberately on a leash. du on a volume holding a
# database is unbounded work, so it runs ONLY for the volumes docker would not
# size (the bind-backed ones, which are folders in the checkout and small by
# construction) and it gives up after five seconds rather than holding the tab.
folder_size() {
    local path="$1"
    [ -n "$path" ] && [ -d "$path" ] && [ -r "$path" ] || return 1
    timeout 5 du -sb "$path" 2>/dev/null | cut -f1
}

# ⚠️ THE FIELDS BELOW ARE SEPARATED BY US (0x1f) AND NOT BY A TAB, and the
# character in the template is a real one — `docker volume ls` turns a written
# `\t` into a tab, `docker volume inspect` hands the two characters to Go's
# template engine, which prints them verbatim.
# ⚠️ A TAB COULD NOT DO THIS JOB ANYWAY: tab is IFS WHITESPACE, so `IFS=$'\t'
#    read` COLLAPSES a run of them and an EMPTY FIELD VANISHES. Every volume
#    docker did not create from a bind has an empty `device`, so its labels slid
#    into the device column and the table reported a mountpoint of
#    `com.docker.volume.anonymous=`. US is not whitespace; a run of two is two
#    fields, one of them empty, which is what an empty field has to be.
# ONE CALL FOR EVERY FIELD A VOLUME HAS. `docker volume ls` cannot print the
# bind device, and the device is the whole answer for the two volumes that are
# folders — so this is inspect over every name rather than ls plus an inspect
# each, which on eighteen volumes was eighteen round trips to the daemon.
volume_names="$(docker volume ls -q 2>/dev/null)"
if [ -n "$volume_names" ]; then
while IFS=$'\x1f' read -r name driver mount device labels; do
    [ -z "$name" ] && continue
    project=""
    case "$labels" in
        *com.docker.compose.project=*)
            project="${labels#*com.docker.compose.project=}"
            project="${project%%,*}"
            ;;
    esac

    if [ "$name" = "$STORAGE_VOLUME_NAME" ]; then role=storage
    elif [ "$name" = "$LOG_VOLUME_NAME" ]; then   role=logs
    elif is_anonymous "$name"; then               role=anonymous
    elif [ -n "$project" ] || [[ "$name" == *apk* ]] || [[ "$name" == *baremetal* ]]; then
        role=ours
    else                                          role=other
    fi

    size="${VOLUME_SIZE[$name]:--1}"
    links="${VOLUME_LINKS[$name]:-0}"
    measured=docker
    if [ "$size" = "-1" ]; then
        measured=none
        if [ $FAST -eq 0 ]; then
            walked="$(folder_size "${device:-$mount}")"
            if [ -n "$walked" ]; then
                size="$walked"
                measured=folder
            fi
        fi
    fi
    printf 'volume\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "${driver:-local}" "$size" "$links" "$project" "$role" \
        "$mount" "$device" "$measured"
done < <(docker volume inspect \
            --format '{{.Name}}{{.Driver}}{{.Mountpoint}}{{index .Options "device"}}{{range $k,$v := .Labels}}{{$k}}={{$v}},{{end}}' \
            $volume_names 2>/dev/null)
fi

# ── THE POINTER. Not restated here: storage-volume.sh owns every one of these
# fields, and this is its report with a column in front of it.
"$MANAGEMENT_SCRIPTS_DIR/storage-volume.sh" 2>/dev/null \
    | sed 's/^/storage\t/'
