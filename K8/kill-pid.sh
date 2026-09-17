#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🔪 Kill ONE process on the HOST, by pid. Not a container — a process.
#   ./kill-pid.sh 144822           TERM, then KILL if it is still there
#   ./kill-pid.sh 144822 --term    TERM only; report what is left
#   ./kill-pid.sh --list           what is holding the manager port, with pids
# THE PROCESS THIS EXISTS FOR IS A DOCKTOR STARTED AT A TERMINAL. It holds
# 127.0.0.1:8765 on the host network stack, so the CONTAINER manager can never
# bind — the dashboard says so on its own dark-stack row and then printed a
# command to paste. This is that command, as a verb, so the hand that reads the
# sentence can act on it.
# ⚠️ IT CAN KILL THE PROCESS SERVING THE PAGE YOU PRESSED IT ON, and that is a
#    USE, not an accident: it is how a terminal manager stands aside for the
#    container. The page goes dark; the container takes the socket within about
#    five seconds and a reload is served by it. The client dialog says this.
# ⚠️ WHAT IT WILL NOT DO:
#    · pid 1 — on a host that is init, in a container it is the container.
#    · ITSELF or its own shell: killing the script mid-run leaves whatever it
#      was about to verify unverified.
#    · A pid that is not a running process, which is said rather than assumed
#      to be "already dead" — a bad number and a finished process are different
#      answers and only one of them means you were looking at stale state.
# EVERY KILL IS ANNOUNCED WITH WHAT IT WAS: the command line is read BEFORE the
# signal, because afterwards there is nothing left to ask.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# --list first: it takes no pid and is the half that answers "which one?".
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "--who" ]; then
    log_step "What is holding the manager port ($MANAGER_PORT)"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | awk -v port=":$MANAGER_PORT" 'NR==1 || index($4, port)'
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$MANAGER_PORT" -sTCP:LISTEN 2>/dev/null
    else
        log_warn "Neither ss nor lsof is here; nothing can be listed."
    fi
    echo
    log_step "Every DockTor process on this host"
    # The runner by name, not by port: a manager that failed to bind is exactly
    # the one worth finding, and it holds no port to be found by.
    ps -eo pid,user,etime,args 2>/dev/null | grep -E "[K]8:runner\.py|[m]anager\.serve" || echo "  none"
    exit 0
fi

PID="${1:-}"
MODE="${2:-}"

if [ -z "$PID" ]; then
    log_error "Which pid?"
    echo "Usage: ./kill-pid.sh <pid> [--term]"
    echo "       ./kill-pid.sh --list     # what holds $MANAGER_PORT, and every DockTor"
    exit 2
fi

# A NUMBER, AND ONLY A NUMBER. This value arrives from a text box in a browser;
# anything else reaching `kill` would be a shell injection with a signal on the
# end of it.
case "$PID" in
    ''|*[!0-9]*)
        log_error "Not a pid: '$PID'. It has to be a positive whole number."
        announce PID_KILL_REFUSED "{\"pid\":\"$PID\",\"reason\":\"not_numeric\"}"
        exit 2
        ;;
esac

if [ "$PID" -eq 1 ]; then
    log_error "Refusing to kill pid 1 — that is init on a host and the container itself in one."
    announce PID_KILL_REFUSED "{\"pid\":$PID,\"reason\":\"pid_1\"}"
    exit 2
fi

if [ "$PID" -eq "$$" ] || [ "$PID" -eq "$PPID" ]; then
    log_error "Refusing to kill this script (pid $$) or the shell that started it (pid $PPID)."
    announce PID_KILL_REFUSED "{\"pid\":$PID,\"reason\":\"self\"}"
    exit 2
fi

if ! kill -0 "$PID" 2>/dev/null; then
    # TWO DIFFERENT ANSWERS AND THEY ARE NOT THE SAME NEWS: a pid that never
    # existed means the number is wrong; one that exists and is not ours means
    # the manager is not running as the user who owns it.
    if [ -d "/proc/$PID" ]; then
        log_error "pid $PID exists but belongs to another user — this process may not signal it."
        echo "  From a terminal that owns it:  kill $PID"
        announce PID_KILL_REFUSED "{\"pid\":$PID,\"reason\":\"not_permitted\"}"
        exit 1
    fi
    log_warn "No process with pid $PID is running. Nothing was signalled."
    announce PID_KILL_ABSENT "{\"pid\":$PID}"
    exit 0
fi

# READ IT BEFORE KILLING IT. Afterwards there is nothing left to ask, and a log
# line saying only "killed 144822" is a line nobody can audit.
command_line="$(ps -p "$PID" -o args= 2>/dev/null | head -n1)"
owner="$(ps -p "$PID" -o user= 2>/dev/null | tr -d ' ')"
[ -z "$command_line" ] && command_line="(unreadable)"

log_step "Killing pid $PID"
echo "  user:    ${owner:-unknown}"
echo "  command: $command_line"
echo "  ordered by: ${APKAUDIO_ORDERED_BY:-a terminal}"
announce PID_KILL "{\"pid\":$PID,\"user\":\"$owner\",\"ordered_by\":\"${APKAUDIO_ORDERED_BY:-a terminal}\"}"

kill -TERM "$PID" 2>/dev/null

# TERM IS A REQUEST AND THE GRACE IS THE POINT: a DockTor asked to stop closes
# its socket, which is the whole reason to prefer it — a -9 leaves the port in
# the kernel for the next process to trip over.
waited=0
while [ $waited -lt 5 ] && kill -0 "$PID" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
done

if ! kill -0 "$PID" 2>/dev/null; then
    log_info "pid $PID stopped after ${waited}s (SIGTERM)."
    announce PID_KILLED "{\"pid\":$PID,\"signal\":\"TERM\",\"waited_seconds\":$waited}"
    exit 0
fi

if [ "$MODE" = "--term" ]; then
    log_warn "pid $PID is still running after ${waited}s and --term says stop there."
    announce PID_KILL_SURVIVED "{\"pid\":$PID,\"signal\":\"TERM\"}"
    exit 1
fi

log_warn "pid $PID ignored SIGTERM for ${waited}s — sending SIGKILL."
kill -KILL "$PID" 2>/dev/null
sleep 1
if kill -0 "$PID" 2>/dev/null; then
    log_error "pid $PID survived SIGKILL. It is unkillable from here — most likely uninterruptible IO, or not ours."
    announce PID_KILL_FAILED "{\"pid\":$PID,\"signal\":\"KILL\"}"
    exit 1
fi
log_info "pid $PID killed (SIGKILL)."
announce PID_KILLED "{\"pid\":$PID,\"signal\":\"KILL\",\"waited_seconds\":$waited}"
