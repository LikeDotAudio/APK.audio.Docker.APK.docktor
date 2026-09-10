#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🚨 PANIC / SOS — force kill the bench and release every port. No confirmation.
#   ./panic.sh [sender] [--dry-run]     # a dry run rehearses and exits 0
# ⚠️ THE MANAGER IS SPARED: it serves the page the button was pressed on and is
#    the process running this script.
# Two meanings, read off the bench rather than chosen by the caller:
#   STOP    something other than the manager is running — kill it all, spare
#           the manager, leave the page up to say so.
#   REBOOT  only the manager is left, so the escalation left is the manager
#           itself: panic-reboot.sh, handed off DETACHED (see below).
# STOP escalation, each step because the one before it can fail to finish:
#   1. Broadcast on APK.audio/System/Panic.
#   2. down --volumes --timeout 0 on every stack, node first.
#   3. docker kill every running container on the host EXCEPT the manager.
#   4. docker rm -f every container on the host EXCEPT the manager.
#   5. Say which stacks that emptied that NOTHING HERE WILL BRING BACK.
# Steps 3-4 are NOT scoped to this project, deliberately: a panic on a shared
# box takes other containers with it, and --dry-run names them and removes
# nothing. The manager is the one exclusion, by name.
# Step 5 stays even though for_each_stack now drives all eight stacks: it is
# what will say so the next time a ninth compose file arrives without a ninth
# array. It runs AFTER the kill — a warning ahead of a panic goes unread.
# The reboot is handed to a DETACHED SIBLING because a compose up that replaces
# the container its own client runs in dies halfway through the swap. The
# sibling is not --rm-ed: its output is the only account of the rebuild.
# The panic does not touch the retained status topic — that payload is the wrong
# shape and permanent, so later subscribers read a finished emergency as now.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# ARGUMENTS: --dry-run may appear anywhere; the first non-flag is the sender.
# A rehearsal exists because the destructive half could not otherwise be
# measured on a shared host — it answers WHAT WOULD GO and WHAT WOULD NOT COME
# BACK without taking the bench out from under anybody.
DRY_RUN=0
SENDER=""
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1;;
        -*) log_error "Unknown option: $arg"
            echo "Usage: ./panic.sh [sender] [--dry-run]"; exit 2;;
        *)  [ -z "$SENDER" ] && SENDER="$arg";;
    esac
done
SENDER="${SENDER:-PANIC_SCRIPT}"
REBOOT_CONTAINER="${MANAGER_CONTAINER}-Panic-Reboot"

if [ "${MANAGER_NAME_GUESSED:-0}" = "1" ]; then
    log_warn "Could not read container_name: from $MANAGER_COMPOSE_FILE."
    echo "  Sparing '$MANAGER_CONTAINER' on the guessed name. If the manager is called"
    echo "  something else on this bench, this panic will take it with the rest."
    announce PANIC_MANAGER_NAME_GUESSED "{\"assumed\":\"$MANAGER_CONTAINER\"}"
fi

# WHICH PANIC THIS IS. Asked of docker once, before anything is killed — after
# step 3 the answer is "nothing is running" in either mode.
mapfile -t OTHERS < <(containers_except_manager)
if [ ${#OTHERS[@]} -gt 0 ]; then
    MODE=STOP
else
    MODE=REBOOT
fi

# The banner says which of the two this is first: a rehearsal that opens with
# the same red siren as a real press reads as an outage.
if [ "$DRY_RUN" = "1" ]; then
    echo "🧪 PANIC --dry-run — mode $MODE ($(( ${#OTHERS[@]} )) container(s) other than $MANAGER_CONTAINER running)"
else
    echo "🚨 PANIC — mode $MODE ($(( ${#OTHERS[@]} )) container(s) other than $MANAGER_CONTAINER running)"
fi
echo "============================================================"

# THE REHEARSAL. Nothing in this block removes anything. It answers off
# docker ps -a and stacks.sh --json — the same facts steps 3-5 act on — and
# splits the kill list the only way that matters on a shared host: containers
# this repository declares (the remount brings them back) and containers it does
# not (nothing here will ever restart them).
if [ "$DRY_RUN" = "1" ]; then
    log_step "PANIC --dry-run: what a real press would do to THIS bench"
    echo "  Nothing is killed, removed, broadcast or rebuilt by this run."

    STACKS_JSON="$("$MANAGEMENT_SCRIPTS_DIR/stacks.sh" --json 2>/dev/null)" \
    PS_ALL="$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null)" \
    MANAGER="$MANAGER_CONTAINER" \
    PANIC_MODE="$MODE" \
    python3 - <<'PY'
import os
import json

manager = os.environ.get("MANAGER") or ""
mode = os.environ.get("PANIC_MODE") or "?"

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

# Declared name -> the stack that declares it. stacks.sh is the one reader of
# the compose files; a second parse here would be a second thing to keep in step.
declares = {name: s for s in stacks for name in s["declared"]}

doomed = [row for row in on_host if row[0] != manager]
ours = sorted(row for row in doomed if row[0] in declares)
theirs = sorted(row for row in doomed if row[0] not in declares)

print("")
print("  mode              %s" % mode)
print("  spared, by name   %s" % manager)
print("  steps 3 and 4     would remove %d container(s)" % len(doomed))
print("")

if ours:
    print("  DECLARED BY THIS REPOSITORY \u2014 the remount is meant to bring these back:")
    for name, status in ours:
        print("     %-30s %-22s %s" % (name, status[:22], declares[name]["stack"]))
else:
    print("  \u2713 No container this repository declares is on this host.")
print("")

if theirs:
    print("  \U0001f6a7 NOT DECLARED BY THIS REPOSITORY. A panic removes host-wide, and")
    print("     NOTHING IN THIS FOLDER WILL BRING THESE BACK:")
    for name, status in theirs:
        print("     %-30s %s" % (name, status[:22]))
else:
    print("  \u2713 Nothing on this host is outside what this repository declares.")
print("")

driven = sorted(s["stack"] for s in stacks if s["driven"])
stranded = sorted(s["stack"] for s in stacks if not s["driven"])
print("  The remount behind the kill drives %d of the %d declared stack(s)."
      % (len(driven), len(stacks)))
if stranded:
    print("  \u26a0 IT DRIVES NONE OF THESE, so a press strands them: %s"
          % ", ".join(stranded))
else:
    print("  \u2713 Every stack this repository declares is driven by it.")
PY

    log_step "The bench as it stands, before anything"
    "$MANAGEMENT_SCRIPTS_DIR/stacks.sh" || true

    announce PANIC_DRY_RUN "{\"sender\":\"$SENDER\",\"mode\":\"$MODE\",\"removed\":0}"
    echo -e "\n\U0001f9ea DRY RUN COMPLETE \u2014 nothing was killed, removed, broadcast or rebuilt."
    echo "   Run without --dry-run to actually press it."
    exit 0
fi

# 1. Broadcast. Best effort: the broker is one of the things about to be killed.
payload="{\"sender\":\"$SENDER\",\"action\":\"EMERGENCY_STOP_ALL\",\"mode\":\"$MODE\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
if command -v mosquitto_pub &>/dev/null; then
    mosquitto_pub -h 127.0.0.1 -p 1883 -t "APK.audio/System/Panic" -m "$payload" -k 2 2>/dev/null \
        && announce PANIC "{\"sender\":\"$SENDER\",\"action\":\"EMERGENCY_STOP_ALL\",\"mode\":\"$MODE\"}" \
        || announce PANIC_BROADCAST_FAILED "{\"sender\":\"$SENDER\",\"error\":\"mosquitto_pub failed\"}"
else
    announce PANIC_BROADCAST_FAILED "{\"sender\":\"$SENDER\",\"error\":\"mosquitto_pub not installed\"}"
fi

# 2. Every project down, node before core. The manager is in no compose file
# here, so no exclusion is needed — down only touches the services of its -f.
# ⚠️ --remove-orphans is deliberately absent: five of the nine files share the
#    project apk-audio, so it would delete the containers this loop is still
#    walking, and the manager is an orphan of every one of them.
for_each_stack reverse down --volumes --timeout 0 || true

# 3 & 4. Everything else on the host, the manager excepted. || true because an
# empty list is a docker syntax error, not a no-op, and an empty host is success.
running="$(containers_except_manager)"
[ -n "$running" ] && docker kill $running >/dev/null 2>&1 || true
all="$(containers_except_manager -a)"
[ -n "$all" ] && docker rm -f $all >/dev/null 2>&1 || true

# 5. What that emptied and will not refill. Asked after the fact, so it
# describes the bench as the operator will find it. || true: a panic that
# aborted on its own report would leave the bench half-killed.
log_step "Stacks this panic emptied"
"$MANAGEMENT_SCRIPTS_DIR/stacks.sh" --report || true

# 5b. Which surviving images are already out of date. A panic removes no images,
# and the next thing the operator is invited to press rebuilds all of them, so
# which ones NEED it is the question this moment answers most cheaply. This is
# the mode that puts STACKS_STALE on the bus.
log_step "Images already older than the code"
"$MANAGEMENT_SCRIPTS_DIR/staleness.sh" --report || true

if [ "$MODE" = "STOP" ]; then
    announce PANIC_COMPLETE "{\"sender\":\"$SENDER\",\"mode\":\"STOP\",\"spared\":\"$MANAGER_CONTAINER\"}"
    echo -e "\n🔴 PANIC STOP COMPLETE: every container force-killed except $MANAGER_CONTAINER."
    echo "   The manager is still up — it is what is presenting this page."
    echo "   🚨 Press PANIC again on an empty bench to reboot the manager itself and"
    echo "      rebuild every image from the code."
    exit 0
fi

# REBOOT. Nothing but the manager was running, so the escalation left is it.
# THE CODE, NOT THE COPY IN THE IMAGE: Dockerfile.manager COPYs this folder to
# /app and the reboot rebuilds from the checkout, so when this script IS the
# /app copy the sibling is pointed at the same relative path under the bound
# repository. The COPY preserves the path below the root, so one strip both ways.
REBOOT_SCRIPT="$MANAGEMENT_SCRIPTS_DIR/panic-reboot.sh"
case "$MANAGEMENT_SCRIPTS_DIR" in
    /app/*)
        from_checkout="$REPO_ROOT/${MANAGEMENT_SCRIPTS_DIR#/app/}/panic-reboot.sh"
        [ -f "$from_checkout" ] && REBOOT_SCRIPT="$from_checkout"
        ;;
esac

# A reboot needs the checkout, and the manager runs without it on purpose (a
# machine that only watches binds no repository). Nothing to build from there,
# so the escalation degrades to a plain restart.
if [ ! -f "$REBOOT_SCRIPT" ] || [ ! -d "$DOCKERS_DIR" ]; then
    log_warn "No checkout bound here — $REBOOT_SCRIPT is not readable."
    echo "  Rebuilding from the code is not possible; restarting $MANAGER_CONTAINER as it is."
    announce PANIC_REBOOT_DEGRADED "{\"sender\":\"$SENDER\",\"reason\":\"no checkout\",\"script\":\"$REBOOT_SCRIPT\"}"
    docker restart "$MANAGER_CONTAINER" >/dev/null 2>&1 || true
    exit 0
fi

# On the host there is nothing to detach from: a panic typed in a terminal is
# not inside the container it recreates. /.dockerenv is docker own marker —
# present in the manager, absent on the host.
if [ ! -f /.dockerenv ]; then
    announce PANIC_REBOOT_INLINE "{\"sender\":\"$SENDER\"}"
    exec "$REBOOT_SCRIPT" "$SENDER"
fi

log_step "Handing the reboot to a detached sibling container"
echo "  $MANAGER_CONTAINER cannot recreate itself: the swap kills the client doing it."
docker rm -f "$REBOOT_CONTAINER" >/dev/null 2>&1 || true

# --mount, NEVER -v: every repo path crosses a : in some directory and the short
# form reports "too many colons" on a path the daemon resolves fine.
# --network host to match the manager, so localhost means the host on both sides
# of the rebuild the way endpoints.sh assumes.
if docker run -d \
        --name "$REBOOT_CONTAINER" \
        --network host \
        --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
        --mount "type=bind,source=$REPO_ROOT,target=$REPO_ROOT" \
        --workdir "$REPO_ROOT" \
        --env APKAUDIO_REPO="$REPO_ROOT" \
        --env APKAUDIO_UID="$APKAUDIO_UID" \
        --env APKAUDIO_GID="$APKAUDIO_GID" \
        --env APKAUDIO_NO_KABOOM="${APKAUDIO_NO_KABOOM:-0}" \
        "$MANAGER_IMAGE" \
        bash "$REBOOT_SCRIPT" "$SENDER" >/dev/null 2>&1; then
    announce PANIC_REBOOT_HANDOFF "{\"sender\":\"$SENDER\",\"container\":\"$REBOOT_CONTAINER\",\"image\":\"$MANAGER_IMAGE\"}"
    echo -e "\n🚨 PANIC REBOOT HANDED OFF to $REBOOT_CONTAINER."
    echo "   It rebuilds $MANAGER_CONTAINER from the code and swaps it out underneath this"
    echo "   page — THIS TAB WILL STOP ANSWERING FOR A MOMENT AND THEN COME BACK NEW."
    echo "   Every other image is rebuilt from the code and remounted behind it."
    echo "   Watch it with:  docker logs -f $REBOOT_CONTAINER"
    exit 0
fi

# The sibling would not start — no image, no socket, a daemon gone away. A
# restart is still a reboot of the manager and needs none of what just failed.
log_error "Could not start $REBOOT_CONTAINER from $MANAGER_IMAGE."
announce PANIC_REBOOT_HANDOFF_FAILED "{\"sender\":\"$SENDER\",\"container\":\"$REBOOT_CONTAINER\",\"image\":\"$MANAGER_IMAGE\"}"
echo "  Falling back to a plain restart of $MANAGER_CONTAINER — no rebuild."
docker restart "$MANAGER_CONTAINER" >/dev/null 2>&1 || true
exit 1
