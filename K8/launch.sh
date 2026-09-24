#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🚀 Launch the bench and GET OUT OF THE WAY. The front door of K8:runner.py.
#   ./launch.sh                bring DockTor up, then ask IT to mount everything
#   ./launch.sh rebuild-all    same handover, a different verb on the far side
#   ./launch.sh --wait 20      how long to hold for the answer before letting go
#
# THE POINT OF THIS FILE IS WHERE THE OUTPUT GOES. A mount typed at a terminal
# printed ten minutes of docker build into THAT terminal: one screen, one
# process, and closing it lost the log — the same fault the Tkinter window was
# deleted for. So the terminal no longer runs the mount. It starts DockTor (the
# one stack that can SHOW a mount), raises the page, hands the verb to the
# running DockTor over its own HTTP API, and exits. From there every line —
# script stdout, the lifted @EVENT lines, the resource beat — lands in the
# execution / recovery / errors swimlanes of the web client, where every open
# tab sees the same build and no window owns it.
# TWO THINGS STILL PRINT HERE, AND BOTH ARE BOOTSTRAP: starting DockTor on a
# cold bench (nothing is serving yet, so there is nowhere else for it to go),
# and the one sentence saying where the rest of it went.
# WHAT THIS DOES NOT DO: gate, evict a port, name a container or spell a compose
# command. up.sh runs the gates on the far side — this file asks for a verb by
# NAME and the manager's own action table decides what that verb is.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# HOW LONG WE HOLD THE ANSWER OPEN, and it is not "how long the mount takes":
# an `up` runs for minutes and we are not waiting for it. This is the window in
# which a REFUSAL arrives — another action already holds the bench, or the verb
# is not in the table — because those come back at once and are worth printing
# where the person who typed this can see them.
REPLY_SECONDS=8
# How long a cold DockTor gets to build, start and bind before we give up on it.
MANAGER_WAIT_SECONDS=300

ACTION=""
# A VALUE-TAKING FLAG IS REFUSED WITHOUT ITS VALUE rather than defaulted: `shift
# 2` on a one-word tail shifts NOTHING and returns 1, and this loop would then
# read `--wait` forever.
while [ $# -gt 0 ]; do
    case "$1" in
        --wait|--manager-wait)
            if [ $# -lt 2 ]; then
                log_error "$1 takes a number of seconds, and none followed it."
                exit 1
            fi
            [ "$1" = "--wait" ] && REPLY_SECONDS="$2" || MANAGER_WAIT_SECONDS="$2"
            shift 2;;
        -h|--help)
            echo "Usage: ./launch.sh [action] [--wait SECONDS] [--manager-wait SECONDS]"
            echo "  action defaults to 'up'; it is a key in DockTor's action table"
            echo "  (up, rebuild-all, rebuild-core, down, verify, prune, …)."
            exit 0;;
        -*) log_error "Unknown option: $1"; exit 1;;
        *)  ACTION="$1"; shift;;
    esac
done
[ -z "$ACTION" ] && ACTION="up"

# wait_for_manager — hold until something ANSWERS on the manager URL.
# /api/health rather than a TCP probe, through manager_answering, for the reason
# stated there: the port is answered by whatever holds it.
wait_for_manager() {
    local deadline=$((SECONDS + MANAGER_WAIT_SECONDS)) said=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        manager_answering 2 && return 0
        sleep 2
        if [ $((SECONDS - said)) -ge 20 ]; then
            said=$SECONDS
            log_info "waiting for DockTor on $MANAGER_URL …"
        fi
    done
    return 1
}

# hand_over <action> — POST one verb to the running DockTor and LET GO.
# THE TIMEOUT IS THE MECHANISM, not an error case: the server runs the action in
# the thread holding this request, so closing the socket at REPLY_SECONDS leaves
# the run going and takes this terminal out of it. serve.py already absorbs the
# write to a client that left — see _send() — so nothing on the far side notices.
#   0  the action finished inside the window (a refusal, or a fast verb)
#   75 it is still running, which for `up` is the ordinary ending
#   1  the manager refused the request outright (no such action)
#   2  nothing answered
hand_over() {
    APK_URL="$MANAGER_URL" APK_ACTION="$1" APK_WAIT="$REPLY_SECONDS" \
    APK_ORIGIN="${APKAUDIO_ORDERED_BY:-launch.sh at a terminal}" python3 - <<'PY'
import json
import os
import socket
import urllib.error
import urllib.request

url = os.environ["APK_URL"].rstrip("/") + "/api/action/" + os.environ["APK_ACTION"]
body = json.dumps({"origin": os.environ["APK_ORIGIN"]}).encode("utf-8")
request = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(request, timeout=float(os.environ["APK_WAIT"])) as answer:
        payload = json.loads(answer.read(100_000) or b"{}")
except (socket.timeout, TimeoutError):
    # THE GOOD ENDING for anything that builds. Nothing was cancelled: the
    # connection went, the run did not.
    raise SystemExit(75)
except urllib.error.HTTPError as err:
    try:
        said = json.loads(err.read(100_000) or b"{}").get("error") or ""
    except Exception:
        said = ""
    print(said or "HTTP %s from %s" % (err.code, url))
    raise SystemExit(1)
except Exception as err:
    print(str(err))
    raise SystemExit(2)

message = payload.get("message") or ""
if message:
    print(message)
raise SystemExit(0 if payload.get("ok") else 1)
PY
}

log_step "Launching APK.audio — DockTor first, then the bench from inside it"
announce LAUNCH_START "{\"action\":\"$ACTION\",\"url\":\"$MANAGER_URL\"}"

if manager_answering 2; then
    log_info "DockTor already answers on $MANAGER_URL"
else
    log_info "Nothing answers on $MANAGER_URL yet — starting DockTor."
    log_info "  This build is the only output that lands in this terminal."
    # THE SITE IS RAISED BY US, NOT BY THE CHILD: open_manager_site opens once
    # per process TREE (APKAUDIO_SITE_OPENED is exported), and a variable the
    # child exports is not set in this shell — so letting manager.sh open it and
    # then opening it here is two tabs. Set for the child only, so the one call
    # that raises the page is the one below, after we know it answers.
    if ! APKAUDIO_SITE_OPENED=1 "$MANAGEMENT_SCRIPTS_DIR/manager.sh" up; then
        log_error "DockTor would not start, so nothing was handed to it."
        announce LAUNCH_FAILED "{\"action\":\"$ACTION\",\"stage\":\"manager\"}"
        exit 1
    fi
    if ! wait_for_manager; then
        log_error "DockTor did not answer on $MANAGER_URL within ${MANAGER_WAIT_SECONDS}s."
        log_error "  Its container may be up and not serving: 'manager.sh status' says which."
        announce LAUNCH_FAILED "{\"action\":\"$ACTION\",\"stage\":\"bind\"}"
        exit 1
    fi
fi

# WHO IS ABOUT TO RUN IT. A manager started at a terminal answers this URL
# exactly as well as the container does (network_mode: host), and it is worth
# saying: its swimlanes hold the same output, but it also prints into whatever
# terminal it was started in, and it is the reason the container cannot bind.
read -r kind pid host <<<"$(manager_instance)"
case "$kind" in
    container) log_info "Handing '$ACTION' to the DockTor container (pid $pid).";;
    terminal)  log_warn "The manager on $MANAGER_URL was started at a TERMINAL (pid $pid on $host)."
               log_warn "  It takes the verb and shows it on the same page; it also holds the port"
               log_warn "  the container wants. Ctrl+C it and run this again for the container.";;
    unidentified)
               log_warn "$MANAGER_URL answers without saying WHICH manager it is — its code"
               log_warn "  predates the \`instance\` key. The verb still goes to it.";;
    # EMPTY, AND IT IS A DIFFERENT THING FROM THE ABOVE: it answered the probe a
    # second ago and did not answer this read. The handover below is what finds
    # out whether that mattered, so this says what was seen and nothing more.
    *)         log_warn "$MANAGER_URL answered a moment ago and did not answer this read.";;
esac

# THE PAGE, BEFORE THE VERB. The browser is what the output is going into, so it
# is raised first — a tab opened after the build started would miss its own
# first minute, and the log stream replays only its tail.
open_manager_site

hand_over "$ACTION"
status=$?
case "$status" in
    75) log_info "🚀 '$ACTION' is running INSIDE DockTor — every line of it is in the"
        log_info "   execution log at $MANAGER_URL, and this terminal is free."
        announce LAUNCH_HANDED_OFF "{\"action\":\"$ACTION\",\"url\":\"$MANAGER_URL\"}"
        exit 0;;
    0)  log_info "'$ACTION' finished before this terminal let go. It is in the log at $MANAGER_URL."
        announce LAUNCH_COMPLETED "{\"action\":\"$ACTION\",\"url\":\"$MANAGER_URL\"}"
        exit 0;;
    1)  log_error "DockTor refused '$ACTION' — the reason is above, and nothing was run."
        announce LAUNCH_REFUSED "{\"action\":\"$ACTION\"}"
        exit 1;;
    *)  log_error "Could not reach DockTor on $MANAGER_URL to hand it '$ACTION'."
        announce LAUNCH_FAILED "{\"action\":\"$ACTION\",\"stage\":\"handover\"}"
        exit 1;;
esac
