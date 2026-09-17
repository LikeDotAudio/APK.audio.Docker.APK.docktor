#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📦 DockTor's own persistent storage: a LOCAL FOLDER that IS a NAMED VOLUME.
#   ./storage-volume.sh            say where it is and whether docker has it
#   ./storage-volume.sh --ensure   make the folder, create the volume if missing
#   ./storage-volume.sh --path     ONE line: the directory to write into, here
# THE POINTER THE VOLUMES TAB DRAWS. Three things that must agree and until this
# file existed did not have one place to agree in:
#   · a folder in the checkout            APK:Documentation/STORAGE/DockTor
#   · a docker volume by name             docktor-storage
#   · a path inside the manager container  /storage
# The local driver with `type=none,o=bind,device=<folder>` is what ties the
# first two together — the same construction the log volume uses, so `docker
# volume ls` lists the program storage beside the ecosystem's and the VOLUMES
# tab has something to point at.
# ⚠️ CREATING IT IS NOT THE SAME AS MOUNTING IT. docker-compose.manager.yml
#    declares the volume and mounts it at /storage; this file exists for the
#    bench where the manager runs from a TERMINAL and for the first run, where
#    nothing has been up yet to create it. A volume that already exists is left
#    exactly as it is — docker will not re-point an existing volume at a new
#    device, and silently running on the OLD folder is the failure that would
#    cause, so a mismatch is REPORTED and not repaired.
# --path IS THE ONE ANSWER TO "WHERE DO I WRITE": inside the container the
# mount is the answer and the host folder is not reachable under that name;
# from a terminal it is the folder. Read by readers.py, which must not decide
# this for itself — that would be the second spelling.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# THE MOUNT WINS WHEN IT IS REAL. `-d` alone is not enough: /storage exists in
# the image as an empty directory so the mount has somewhere to land, and
# writing the history into the IMAGE would lose it on the next rebuild — which
# is the exact thing this volume is for. A mountpoint has a device of its own.
storage_path() {
    if [ -d "$STORAGE_MOUNT_DIR" ] && mountpoint -q "$STORAGE_MOUNT_DIR" 2>/dev/null; then
        printf '%s' "$STORAGE_MOUNT_DIR"
    elif [ -d "$STORAGE_MOUNT_DIR" ] && [ -f /.dockerenv ] && [ -w "$STORAGE_MOUNT_DIR" ]; then
        # No mountpoint(1) in a slim image. Inside a container /storage is the
        # mount by construction; outside one it never exists.
        printf '%s' "$STORAGE_MOUNT_DIR"
    else
        printf '%s' "$STORAGE_HOST_DIR"
    fi
}

if [ "${1:-}" = "--path" ]; then
    storage_path
    echo
    exit 0
fi

ENSURE=0
[ "${1:-}" = "--ensure" ] && ENSURE=1

device=""
if docker volume inspect "$STORAGE_VOLUME_NAME" >/dev/null 2>&1; then
    exists=1
    device="$(docker volume inspect --format '{{index .Options "device"}}' "$STORAGE_VOLUME_NAME" 2>/dev/null)"
    [ "$device" = "<no value>" ] && device=""
    mountpoint_path="$(docker volume inspect --format '{{.Mountpoint}}' "$STORAGE_VOLUME_NAME" 2>/dev/null)"
else
    exists=0
    mountpoint_path=""
fi

if [ $ENSURE -eq 1 ]; then
    # THE FOLDER FIRST. The local driver binds lazily — `docker volume create`
    # succeeds naming a directory that is not there and the failure lands on
    # the container that mounts it, minutes later and in somebody else's log.
    if [ ! -d "$STORAGE_HOST_DIR" ]; then
        log_step "Creating the storage folder: $STORAGE_HOST_DIR"
        mkdir -p "$STORAGE_HOST_DIR" || {
            log_error "Could not create $STORAGE_HOST_DIR"
            announce STORAGE_VOLUME_FAILED "{\"reason\":\"mkdir\",\"folder\":\"$STORAGE_HOST_DIR\"}"
            exit 1
        }
    fi

    if [ $exists -eq 0 ]; then
        log_step "Creating the named volume $STORAGE_VOLUME_NAME → $STORAGE_HOST_DIR"
        docker volume create --driver local \
            --opt type=none --opt o=bind --opt device="$STORAGE_HOST_DIR" \
            --label com.apkaudio.role=docktor-storage \
            "$STORAGE_VOLUME_NAME" >/dev/null || {
            log_error "docker refused to create $STORAGE_VOLUME_NAME."
            announce STORAGE_VOLUME_FAILED "{\"reason\":\"create\",\"volume\":\"$STORAGE_VOLUME_NAME\"}"
            exit 1
        }
        exists=1
        device="$STORAGE_HOST_DIR"
        mountpoint_path="$STORAGE_HOST_DIR"
        announce STORAGE_VOLUME_CREATED "{\"volume\":\"$STORAGE_VOLUME_NAME\",\"folder\":\"$STORAGE_HOST_DIR\"}"
        log_info "$STORAGE_VOLUME_NAME created."
    elif [ -n "$device" ] && [ "$device" != "$STORAGE_HOST_DIR" ]; then
        # SAID, NOT FIXED. See the header: re-pointing means deleting the
        # volume, and the bytes under the old folder are the history.
        log_warn "$STORAGE_VOLUME_NAME already points at $device, not $STORAGE_HOST_DIR."
        echo "  Nothing was changed. To move it:  docker volume rm $STORAGE_VOLUME_NAME"
        echo "  (the samples under $device stay on disk; copy them across first)"
        announce STORAGE_VOLUME_MISMATCH "{\"volume\":\"$STORAGE_VOLUME_NAME\",\"device\":\"$device\",\"expected\":\"$STORAGE_HOST_DIR\"}"
    else
        log_info "$STORAGE_VOLUME_NAME already exists, pointing where it should."
    fi
fi

# THE REPORT, and it is the same six fields whether or not --ensure ran. TSV,
# one key per line, because readers.py reads this and a person reads it too.
bound=0
[ -n "$device" ] && [ "$device" = "$STORAGE_HOST_DIR" ] && bound=1
printf 'volume\t%s\n'      "$STORAGE_VOLUME_NAME"
printf 'folder\t%s\n'      "$STORAGE_HOST_DIR"
printf 'mount\t%s\n'       "$STORAGE_MOUNT_DIR"
printf 'writing_to\t%s\n'  "$(storage_path)"
printf 'exists\t%s\n'      "$exists"
printf 'bound\t%s\n'       "$bound"
printf 'device\t%s\n'      "$device"
printf 'mountpoint\t%s\n'  "$mountpoint_path"
printf 'folder_exists\t%s\n' "$([ -d "$STORAGE_HOST_DIR" ] && echo 1 || echo 0)"
printf 'writable\t%s\n'    "$([ -w "$(storage_path)" ] 2>/dev/null && echo 1 || echo 0)"
