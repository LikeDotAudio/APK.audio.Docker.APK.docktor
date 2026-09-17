#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🐳 DockTor itself — start it, stop it, or find out where it is.
#   ./manager.sh [up|down|restart|logs|status|url]
#     up     build if needed, start, print the URL
#     logs   follow it
# What this adds over `docker compose -f …` by hand is the one thing a compose
# file cannot default: APKAUDIO_REPO must equal the checkout absolute path on the
# HOST, because docker-compose.manager.yml binds the repository at that path on
# BOTH sides so a context this container hands the daemon resolves to the same
# bytes.
# ⚠️ NO --remove-orphans, EVER: the project is shared with the four other
#    apk-audio stacks, so the flag would delete the ecosystem this watches.
# panic-reboot.sh also starts the manager, off the same COMPOSE_MANAGER array. If
# `up` here grows a precondition, so does step 1 there.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# The compose file, the array AND THE URL are _common.sh's: panic.sh and
# panic-reboot.sh need the same three, and a second copy here is a second place
# to be right. The port in the copy that used to live on this line was a
# literal; the one in _common.sh is read out of the compose file.

# The one export this script exists for. REPO_ROOT is walked from the script own
# location, so it is right after a rename and on somebody else checkout.
export APKAUDIO_REPO="$REPO_ROOT"

case "${1:-up}" in
    up|start)
        log_step "Starting DockTor"
        echo "  repository bound at: $APKAUDIO_REPO"
        # THE FOLDER BEFORE THE MOUNT. docker-compose.manager.yml declares
        # `docktor-storage` as a local volume bound to a folder, and compose
        # will happily CREATE that volume against a directory that is not
        # there — the failure lands later, on a container that will not start,
        # naming a device instead of a missing folder. --ensure is idempotent
        # and does nothing on the second run.
        # The storage volume lives under APK:Documentation; a `pods` estate's
        # standalone compose file declares none.
        if [ "$ESTATE_LAYOUT" != "pods" ]; then
            "$MANAGEMENT_SCRIPTS_DIR/storage-volume.sh" --ensure \
                || log_warn "Storage volume not ready; compose will name what it could not mount."
        fi

        # --build every time: the package is COPYed into the image rather than
        # bound, so a manager started without a build runs last week code
        # while the checkout beside it has this week.
        "${COMPOSE_MANAGER[@]}" up -d --build
        status=$?
        announce MANAGER_UP "{\"url\":\"$MANAGER_URL\",\"repo\":\"$APKAUDIO_REPO\",\"exit_code\":$status}"
        # STARTING IT AND SHOWING IT ARE ONE GESTURE. `manager.sh up` is how a
        # person starts this tool by hand, and the next thing they did every
        # time was type the URL — which this printed and did not open.
        [ $status -eq 0 ] && open_manager_site
        exit $status
        ;;
    down|stop)
        log_step "Stopping DockTor"
        "${COMPOSE_MANAGER[@]}" down
        status=$?
        announce MANAGER_DOWN "{\"exit_code\":$status}"
        exit $status
        ;;
    restart|bounce)
        "${COMPOSE_MANAGER[@]}" restart
        exit $?
        ;;
    logs|log)
        "${COMPOSE_MANAGER[@]}" logs -f --tail 200
        exit $?
        ;;
    status|ps)
        "${COMPOSE_MANAGER[@]}" ps
        # A container that is UP is not a manager that ANSWERS, so the state
        # word is read off its own /api/health.
        # AND AN ANSWER HERE MAY NOT BE THIS CONTAINER: the manager runs
        # network_mode: host, so this URL is the bench loopback and a manager
        # started at a terminal answers it identically — this verb printed
        # "API answering" over a restart-looping container for that reason.
        # `instance` in the payload is who answered.
        who="$(curl -fsS --max-time 4 "${MANAGER_URL}api/health" 2>/dev/null | python3 -c '
import json, sys
try:
    instance = json.load(sys.stdin).get("instance")
except Exception:
    raise SystemExit(0)
# THREE ANSWERS, NOT TWO: a manager older than the `instance` key answers
# without saying who it is, and calling that "a terminal" would be a guess
# printed as a finding.
if not isinstance(instance, dict):
    print("unidentified\t?\t?")
else:
    print("%s\t%s\t%s" % ("container" if instance.get("containerised") else "terminal",
                           instance.get("pid", "?"), instance.get("hostname", "?")))
' 2>/dev/null)"
        kind="${who%%$'\t'*}"
        rest="${who#*$'\t'}"
        case "$kind" in
            container)
                log_info "API answering on $MANAGER_URL — this container (pid ${rest%%$'\t'*})"
                ;;
            terminal)
                log_warn "${MANAGER_URL}api/health is answered by a manager started at a TERMINAL"
                log_warn "  (pid ${rest%%$'\t'*} on ${rest##*$'\t'}), not by the container above."
                log_warn "  It holds the port; the container waits for it. Ctrl+C that process."
                ;;
            unidentified)
                log_warn "${MANAGER_URL}api/health answers, but does not say WHICH manager it is."
                log_warn "  Its code predates the \`instance\` key, so it is older than this"
                log_warn "  checkout. Restart whichever manager is on 8765 and ask again."
                ;;
            *)
                log_warn "Container is listed above but ${MANAGER_URL}api/health did not answer."
                ;;
        esac
        exit 0
        ;;
    url)
        echo "$MANAGER_URL"
        exit 0
        ;;
    *)
        log_error "Unknown action: $1"
        echo "Usage: ./manager.sh [up|down|restart|logs|status|url]"
        exit 1
        ;;
esac
