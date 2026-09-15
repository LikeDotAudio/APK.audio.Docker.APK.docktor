#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# ☢️  NUKE — the end of the bench. Every container, every image, every VOLUME,
#    every network, every byte of build cache on this host. Not a cleanup: this
#    is the verb that leaves docker as empty as the day it was installed.
#      ./nuke.sh                          REHEARSAL. Names the dead, removes nothing, exits 2
#      ./nuke.sh --yes-nuke-everything    the press
#      ./nuke.sh --yes-nuke-everything --include-manager   take the manager too (host only)
#
# ⚠️ THIS DELETES NAMED VOLUMES, WHICH IS THE WHOLE POINT AND THE WHOLE DANGER.
#    prune.sh refuses them in its own words — mariadb-data, broker-data,
#    baremetal-state, mqtt-exchange and gui-frames are this ecosystem's STATE,
#    and `docker volume prune` counts them as unused whenever the stack is down.
#    Every other script in this folder is built around never touching them.
#    This one exists because sometimes you do mean it. There is no undo, no
#    backup taken here, and nothing in this repository will bring the DATA back
#    — a remount rebuilds empty databases, not yours.
# ⚠️ HOST-WIDE, NOT SCOPED TO THIS PROJECT. Containers, images and volumes that
#    belong to other work on this machine go too. The rehearsal names them
#    separately for exactly that reason; read it before pressing.
#
# WHY A TOKEN AND NOT A PROMPT: this runs from the web client, from the CLI and
# from a terminal, and only one of those three can read an answer from a tty.
# The token is the consent, so the act is the same act however it was reached,
# and a bare `./nuke.sh` on a live bench is a REPORT rather than an accident.
# The web client asks three times before it sends the token; see api.py.
#
# THE MANAGER IS SPARED BY DEFAULT, for panic.sh's reason: it serves the page
# the button was pressed on and it is the process running this script.
# --include-manager lifts that, and is REFUSED from inside the manager — the
# removal would kill this shell mid-run and leave the nuke half-finished, with
# the images still on disk and no page left to say so.
#
# ORDER IS NOT DECORATION. Volumes cannot be removed while a container holds
# them and images cannot be removed while a container is built on them, so
# containers go first, then volumes, then images, then the caches. The final
# `system prune` is a sweeper for what the daemon created behind our backs, not
# the mechanism — an operator reading the log should see each class named.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

CONSENT=0
DRY_RUN=0
INCLUDE_MANAGER=0
SENDER=""
for arg in "$@"; do
    case "$arg" in
        --yes-nuke-everything) CONSENT=1;;
        --include-manager)     INCLUDE_MANAGER=1;;
        --dry-run|-n)          DRY_RUN=1;;
        -*) log_error "Unknown option: $arg"
            echo "Usage: ./nuke.sh [--yes-nuke-everything] [sender] [--include-manager] [--dry-run]"
            exit 2;;
        *)  [ -z "$SENDER" ] && SENDER="$arg";;
    esac
done
SENDER="${SENDER:-NUKE_SCRIPT}"

# NO CONSENT IS A REHEARSAL, NOT AN ERROR MESSAGE. A refusal that only says
# "pass --yes-nuke-everything" teaches the flag; this one shows the bill first.
[ "$CONSENT" = "1" ] || DRY_RUN=1

if [ "$INCLUDE_MANAGER" = "1" ] && [ -f /.dockerenv ]; then
    log_error "--include-manager cannot be run from inside the manager."
    echo "  Removing $MANAGER_CONTAINER would kill this script where it stands, leaving"
    echo "  the images and caches on disk and no page left to report it."
    echo "  Run it from a host terminal, or nuke without --include-manager and then"
    echo "  ./manager.sh down."
    announce NUKE_REFUSED "{\"sender\":\"$SENDER\",\"reason\":\"include-manager from inside the manager\"}"
    exit 2
fi

if [ "${MANAGER_NAME_GUESSED:-0}" = "1" ] && [ "$INCLUDE_MANAGER" = "0" ]; then
    log_warn "Could not read container_name: from $MANAGER_COMPOSE_FILE."
    echo "  Sparing '$MANAGER_CONTAINER' on the guessed name. If the manager is called"
    echo "  something else on this bench, this nuke will take it with the rest."
    announce NUKE_MANAGER_NAME_GUESSED "{\"assumed\":\"$MANAGER_CONTAINER\"}"
fi

# ── The census. Taken ONCE, before anything, and printed whether this is a
# rehearsal or the press: the rehearsal IS this list, and the real run wants
# the same list in the log as the record of what was standing beforehand.
if [ "$INCLUDE_MANAGER" = "1" ]; then
    mapfile -t DOOMED < <(docker ps -aq 2>/dev/null)
else
    mapfile -t DOOMED < <(containers_except_manager -a)
fi
mapfile -t VOLUMES < <(docker volume ls -q 2>/dev/null)
mapfile -t IMAGES  < <(docker image ls -aq 2>/dev/null | sort -u)

if [ "$DRY_RUN" = "1" ]; then
    echo "🧪 NUKE --dry-run — nothing is removed by this run"
else
    echo "☢️  NUKE — every container, image, volume and cache on this host"
fi
echo "============================================================"
echo "  containers      ${#DOOMED[@]}"
echo "  volumes         ${#VOLUMES[@]}   ⚠️  THE DATA. Deleted, not pruned."
echo "  images          ${#IMAGES[@]}"
if [ "$INCLUDE_MANAGER" = "1" ]; then
    echo "  spared          NOTHING — $MANAGER_CONTAINER goes too (--include-manager)"
else
    echo "  spared          $MANAGER_CONTAINER, and its image while it holds one"
fi

log_step "What docker is holding right now"
"$MANAGEMENT_SCRIPTS_DIR/disk.sh" || true

# THE REHEARSAL SPLITS THE LIST THE ONLY WAY THAT MATTERS on a shared host:
# what this repository declares (a remount brings the CONTAINERS back, empty)
# and what it does not (nothing here will ever restart those).
if [ "$DRY_RUN" = "1" ]; then
    log_step "Named volumes that would be DELETED"
    if [ ${#VOLUMES[@]} -gt 0 ]; then
        docker volume ls --format '  {{.Name}}\t{{.Driver}}' 2>/dev/null || true
        echo ""
        log_warn "There is no undo and nothing here takes a backup. A remount after this"
        echo "  builds EMPTY databases — the rows are gone with the volume."
    else
        log_info "No volumes on this host."
    fi

    log_step "Containers that would be removed"
    if [ ${#DOOMED[@]} -gt 0 ]; then
        STACKS_JSON="$("$MANAGEMENT_SCRIPTS_DIR/stacks.sh" --json 2>/dev/null)" \
        PS_ALL="$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null)" \
        MANAGER="$MANAGER_CONTAINER" \
        SPARE_MANAGER="$([ "$INCLUDE_MANAGER" = "1" ] && echo 0 || echo 1)" \
        python3 - <<'PY'
import os
import json

manager = os.environ.get("MANAGER") or ""
spare = os.environ.get("SPARE_MANAGER") == "1"

on_host = []
for line in (os.environ.get("PS_ALL") or "").splitlines():
    if not line:
        continue
    parts = line.split("\t")
    on_host.append((parts[0], parts[1] if len(parts) > 1 else "?"))

try:
    stacks = json.loads(os.environ.get("STACKS_JSON") or "")["stacks"]
except Exception:
    stacks = []

# stacks.sh is the one reader of the compose files; a second parse here would
# be a second thing to keep in step with a renamed service.
declares = {name: s for s in stacks for name in s["declared"]}

doomed = [row for row in on_host if not (spare and row[0] == manager)]
ours = sorted(row for row in doomed if row[0] in declares)
theirs = sorted(row for row in doomed if row[0] not in declares)

if ours:
    print("  DECLARED BY THIS REPOSITORY — a remount brings these back EMPTY:")
    for name, status in ours:
        print("     %-30s %-22s %s" % (name, status[:22], declares[name]["stack"]))
else:
    print("  ✓ No container this repository declares is on this host.")
print("")
if theirs:
    print("  🚧 NOT DECLARED BY THIS REPOSITORY, and NOTHING IN THIS FOLDER WILL")
    print("     BRING THESE BACK — container, image or volume:")
    for name, status in theirs:
        print("     %-30s %s" % (name, status[:22]))
else:
    print("  ✓ Nothing on this host is outside what this repository declares.")
PY
    else
        log_info "No containers on this host."
    fi

    announce NUKE_DRY_RUN "{\"sender\":\"$SENDER\",\"containers\":${#DOOMED[@]},\"volumes\":${#VOLUMES[@]},\"images\":${#IMAGES[@]}}"
    echo ""
    if [ "$CONSENT" = "1" ]; then
        echo "🧪 DRY RUN COMPLETE — nothing was removed. Drop --dry-run to press it."
    else
        log_error "REFUSED: nothing was removed, because consent was not given."
        echo "  This is the rehearsal. To actually do it:"
        echo "      ./nuke.sh --yes-nuke-everything"
    fi
    exit 2
fi

# ── 1. Say so on the bus, before the broker is one of the casualties.
payload="{\"sender\":\"$SENDER\",\"action\":\"NUKE_EVERYTHING\",\"containers\":${#DOOMED[@]},\"volumes\":${#VOLUMES[@]},\"images\":${#IMAGES[@]},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
if command -v mosquitto_pub &>/dev/null; then
    mosquitto_pub -h 127.0.0.1 -p 1883 -t "APK.audio/System/Panic" -m "$payload" -k 2 2>/dev/null \
        && announce NUKE_STARTED "$payload" \
        || announce NUKE_BROADCAST_FAILED "{\"sender\":\"$SENDER\",\"error\":\"mosquitto_pub failed\"}"
else
    announce NUKE_STARTED "$payload"
fi

# ── 2. Compose's own teardown first, so each project's networks and orphans go
# the way compose expects rather than being swept up later by id.
# --remove-orphans is still absent, for _common.sh's reason: five files share
# the project apk-audio and it would delete the containers this loop is still
# walking. Everything is going anyway; the sweeps below are what guarantee it.
log_step "Stopping every stack (compose down --volumes)"
for_each_stack reverse down --volumes --timeout 0 || true

# ── 3. Every container on the host. `|| true` throughout: an empty argument
# list is a docker syntax error, not a no-op, and an already-empty host is
# success, not a reason to stop half way through a nuke.
log_step "Killing and removing every container"
if [ "$INCLUDE_MANAGER" = "1" ]; then
    running="$(docker ps -q 2>/dev/null)"
    [ -n "$running" ] && docker kill $running >/dev/null 2>&1 || true
    all="$(docker ps -aq 2>/dev/null)"
else
    running="$(containers_except_manager)"
    [ -n "$running" ] && docker kill $running >/dev/null 2>&1 || true
    all="$(containers_except_manager -a)"
fi
[ -n "$all" ] && docker rm -f $all >/dev/null 2>&1 || true
log_info "$(docker ps -aq 2>/dev/null | wc -l) container(s) left."

# ── 4. THE VOLUMES. The line that makes this file different from prune.sh.
# `docker volume rm`, by name, in full knowledge — not `volume prune`, which
# would do the same thing while reading as housekeeping.
log_step "Deleting every named volume — THE DATA"
removed_volumes=0
for volume in "${VOLUMES[@]}"; do
    [ -n "$volume" ] || continue
    if docker volume rm -f "$volume" >/dev/null 2>&1; then
        echo "  ☠️  $volume"
        removed_volumes=$((removed_volumes + 1))
    else
        log_warn "$volume could not be removed — something still holds it."
    fi
done
log_info "$removed_volumes volume(s) deleted."

# ── 5. Every image. In use by the spared manager is the one refusal expected
# here, and it is not an error: the manager is still running on it.
log_step "Removing every image"
[ ${#IMAGES[@]} -gt 0 ] && docker rmi -f "${IMAGES[@]}" >/dev/null 2>&1 || true
docker image prune -af >/dev/null 2>&1 || true
log_info "$(docker image ls -aq 2>/dev/null | sort -u | wc -l) image(s) left."

# ── 6. The rest of what docker is holding: networks, build cache, and a final
# system sweep for anything created while the steps above were running.
log_step "Networks"
docker network prune -f || true
log_step "Build cache"
docker builder prune -af || true
log_step "Sweeping whatever is left"
docker system prune -af --volumes || true

# ── 7. What that emptied, and what it will not refill. After the fact, so it
# describes the bench as the operator will find it.
log_step "Stacks this nuke emptied"
"$MANAGEMENT_SCRIPTS_DIR/stacks.sh" --report || true

log_step "What docker is holding now"
"$MANAGEMENT_SCRIPTS_DIR/disk.sh" || true

announce NUKE_COMPLETE "{\"sender\":\"$SENDER\",\"containers_removed\":${#DOOMED[@]},\"volumes_removed\":$removed_volumes,\"images_removed\":${#IMAGES[@]},\"manager_included\":$INCLUDE_MANAGER}"

echo ""
if [ "$INCLUDE_MANAGER" = "1" ]; then
    echo "☢️  NUKE COMPLETE. Docker is empty — the manager included."
    echo "   Nothing is serving anything. Bring it back from a host terminal:"
    echo "      ./manager.sh up      then      ./rebuild-all.sh"
else
    echo "☢️  NUKE COMPLETE. Docker is empty except $MANAGER_CONTAINER, which is what is"
    echo "   presenting this page."
    echo "   ⚡ Rebuild All Dockers & Mount is the way back: every image builds from the"
    echo "      code, from nothing, and takes many minutes."
fi
echo "   ⚠️  THE VOLUMES ARE GONE. What comes back is an EMPTY bench — new databases,"
echo "      no history, no retained broker state. Nothing here restores data."
