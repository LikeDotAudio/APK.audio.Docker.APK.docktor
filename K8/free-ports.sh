#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 💥 KABOOM — take every port the stack is about to bind, by force.
#   ./free-ports.sh                         every port the driven files publish
#   ./free-ports.sh 8080 1883               only these
#   ./free-ports.sh --stack 'PROTOCOL:DEV:EMBER'  only what ONE stack publishes
#   ./free-ports.sh --list                  print what it WOULD take, evict nothing
# docker compose up does not negotiate for a published port: it fails that one
# container with "port is already allocated", leaves the rest running, and the
# reason is six screens back by the time anyone looks.
# THE TWO HOLDERS ARE NOT FOUND THE SAME WAY and the naming tools are not on
# every machine: a CONTAINER socket shows no owner, the manager image has no ss,
# and its busybox lsof ignores every flag. An empty pid list means ask Docker,
# never that the port is free.
# Ports are READ FROM THE COMPOSE FILES, never spelled here.
# --stack IS WHAT MAKES A PER-STACK REMOUNT SAFE: this script STOPS any container
# publishing a port it is asked to free, so a bench-wide call from up-stack.sh
# would stop healthy containers in seven stacks nobody pressed a button about.
# Exit 0 once every named port is free; 1 if any is still held (the caller may
# still proceed and let compose report the collision).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# --stack is parsed HERE and nowhere else; everything else on the command line
# belongs to the python reader and is handed through untouched.
ARGS=()
ONLY_STACK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --stack) ONLY_STACK="${2:-}"
                 [ -n "$ONLY_STACK" ] || { log_error "--stack needs a stack name."; exit 2; }
                 shift 2;;
        *)       ARGS+=("$1"); shift;;
    esac
done

# Narrowed by EMPTYING the others, not by a second list: the python reads eight
# named variables, so clearing seven leaves one file and the parser untouched.
if [ -n "$ONLY_STACK" ]; then
    if ! compose_for_stack "$ONLY_STACK"; then
        log_error "No compose file under APK:PODS/ is named by the stack '$ONLY_STACK'."
        exit 2
    fi
    BAREMETAL_COMPOSE_FILE="" MQTT_COMPOSE_FILE="" PORTAL_COMPOSE_FILE=""
    NMOS_COMPOSE_FILE="" AES70_COMPOSE_FILE="" NETBOX_COMPOSE_FILE=""
    EMBER_COMPOSE_FILE="" LOGGER_COMPOSE_FILE="" SQLCLUSTER_COMPOSE_FILE=""
    COMPOSE_FILE="$STACK_COMPOSE_FILE"
    log_info "Scoped to $ONLY_STACK -- only the ports that file publishes."
fi

# Python because three of the four steps are: bind a probe socket, read
# /proc/<pid>/cmdline, and expand ${PORT:-8080} the way compose does.
# ⚠️ ALL TEN DRIVEN FILES. A port declared by a stack missing from this list is
#    a port nothing frees and an up that fails on "address already in use" with
#    no account of who holds it. One name per driven array in _common.sh — add
#    the ninth here on the same commit.
COMPOSE_FILE="$COMPOSE_FILE" \
BAREMETAL_COMPOSE_FILE="$BAREMETAL_COMPOSE_FILE" \
MQTT_COMPOSE_FILE="$MQTT_COMPOSE_FILE" \
PORTAL_COMPOSE_FILE="$PORTAL_COMPOSE_FILE" \
NMOS_COMPOSE_FILE="$NMOS_COMPOSE_FILE" \
AES70_COMPOSE_FILE="$AES70_COMPOSE_FILE" \
NETBOX_COMPOSE_FILE="$NETBOX_COMPOSE_FILE" \
EMBER_COMPOSE_FILE="$EMBER_COMPOSE_FILE" \
LOGGER_COMPOSE_FILE="$LOGGER_COMPOSE_FILE" \
SQLCLUSTER_COMPOSE_FILE="$SQLCLUSTER_COMPOSE_FILE" \
ONLY_STACK_FILE="${ONLY_STACK:+$STACK_COMPOSE_FILE}" \
python3 - "${ARGS[@]}" <<'PY'
import os
import re
import socket
import subprocess
import sys
import time


def announce(name, payload):
    import json
    print(f"@EVENT {name} {json.dumps(payload, separators=(',', ':'))}", flush=True)


def capture(command):
    """Best effort command; returns stdout, or None if the tool could not run.

    ABSENT IS NOT EMPTY. Returning '' for a missing binary is what let a manager
    image with no `ss` in it read as a host where nothing holds the port. A
    caller that only wants text writes `capture(...) or ''`; a caller deciding
    whether it KNOWS anything has to be able to tell the two apart."""
    try:
        return subprocess.run(command, capture_output=True, text=True,
                              timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return None


def _ancestor_chain():
    """The scripts above this one, nearest first: `up.sh <- K8:runner.py serve`.

    READ FROM /proc, NOT PASSED: a stop that cannot say who asked for it is the
    question nobody can answer afterwards, and a hand-run `./up.sh` in a
    terminal sets no variable. The python below the heredoc is this script's
    own bash, so the walk starts at the grandparent."""
    links = []
    pid = os.getppid()
    for _ in range(8):
        try:
            with open(f'/proc/{pid}/stat', encoding='utf-8', errors='replace') as handle:
                parent = int(handle.read().rsplit(')', 1)[1].split()[1])
            with open(f'/proc/{pid}/cmdline', 'rb') as handle:
                argv = [a.decode(errors='replace') for a in handle.read().split(b'\0') if a]
        except (OSError, ValueError, IndexError):
            break
        if not argv or pid <= 1:
            break
        # ONE WORD PER LINK, TWO FOR A VERB: `up.sh`, `K8:runner.py serve`. A whole
        # argv is an editor's forty flags, and the reader wants the script name.
        # SPLIT ON SPACES ONLY FOR A ONE-STRING ARGV: Electron rewrites its argv
        # into one string. A real argv keeps its elements whole, or the
        # `docker scripts/` folder reads as a program called `docker`.
        parts = argv[0].split() if len(argv) == 1 else argv[:3]
        words = [os.path.basename(w) for w in parts]
        if words and words[0] in ('bash', 'sh', 'python3', 'python') and len(words) > 1:
            words = words[1:]
        words = [w for w in words if w and not w.startswith('-')][:2] or words[:1]
        link = ' '.join(words)[:60]
        if link and link != 'free-ports.sh' and (not links or links[-1] != link):
            links.append(link)
        pid = parent
    # FOUR IS ENOUGH to reach the manager or the terminal; past that it is the
    # desktop session, which never ordered anything.
    return ' <- '.join(links[:4]) or 'a shell with no parent script'


# WHO ASKED. APKAUDIO_ORDERED_BY is set by the manager (which button, which
# countdown, which CLI verb); the chain is what actually ran.
ORDERED_BY = os.environ.get('APKAUDIO_ORDERED_BY') or 'nobody named (run by hand)'
CHAIN = _ancestor_chain()
ORDER = f"received command from {ORDERED_BY} via {CHAIN}"


def port_is_free(port, host='127.0.0.1'):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind((host, port))
            return True
        except OSError:
            return False


def signallable(pid):
    """Whether evicting this pid is a thing we are allowed to do.

    TWO PIDS ARE NOT HOLDERS AND KILLING EITHER TAKES THE CALLER DOWN WITH IT.

    `pid=0` is not a process, and `os.kill(0, sig)` does not fail on it -- it
    is defined as "signal every process in the CALLER'S process group", which
    is free-ports.sh, rebuild-all.sh above it, and the manager's whole run. A
    rebuild died at step 5 with exit -15, after step 1 had already taken the
    bench down and with nothing left to roll it back. That 0 came out of a
    busybox `lsof`'s fd column and the header carries the account; the reader
    above is where it is now refused. THIS GUARD STAYS ANYWAY -- it is what
    makes the next misreading cost an error message rather than the bench.

    Anything else sharing our process group is the same act by a longer route.
    A holder we may legitimately evict is a stranger, never an ancestor."""
    if pid <= 0:
        return False
    try:
        return os.getpgid(pid) != os.getpgrp()
    except OSError:
        # Gone between the listing and here; nothing left to evict.
        return False


def pids_from_ss(port):
    """Holders per `ss`, or None if `ss` is not here to ask. `pid=` is its own
    unambiguous marker, so nothing else in the line can be mistaken for one."""
    out = capture(['ss', '-ltnpH', f'sport = :{port}'])
    if out is None:
        return None
    return {int(pid) for pid in re.findall(r'pid=(\d+)', out)}


def pids_from_lsof(port):
    """Holders per `lsof -t`, or None if what answered was not `lsof -t`.

    THE CONTRACT IS THE WHOLE CHECK: `-t` prints one pid per line and nothing
    else. Busybox's applet takes no options at all -- it ignored `-t`, the
    `-iTCP:<port>` filter and `-sTCP:LISTEN` together and printed four columns
    per line for every process in the container, so `.split()` harvested fd
    numbers as pids and handed `0` to os.kill. A line that is not a bare number
    means the tool answered a different question, and one such line invalidates
    the whole reading rather than the line: a filter that was ignored means the
    pids on the well-formed lines are not this port's either."""
    out = capture(['lsof', '-t', f'-iTCP:{port}', '-sTCP:LISTEN'])
    if out is None:
        return None
    pids = set()
    for line in out.splitlines():
        token = line.strip()
        if not token:
            continue
        if not token.isdigit():
            return None
        pids.add(int(token))
    return pids


def observed_holders(port):
    """Pids the tools here attribute to the port, or None if NONE OF THEM COULD
    ANSWER -- which is not the same as "nobody holds it" and must not collapse
    into it. `ss` first and `lsof` behind it, because an unprivileged `ss` names
    only our own processes and comes back empty on someone else's socket.

    The set is evidence, not a kill list; `processes_holding` is what may be
    signalled."""
    answered = False
    for reader in (pids_from_ss, pids_from_lsof):
        pids = reader(port)
        if pids is None:
            continue
        answered = True
        pids.discard(os.getpid())
        if pids:
            return pids
    return set() if answered else None


def processes_holding(port):
    """PIDs listening on the port that we may signal. Empty for a container, and
    empty for a host process seen from inside one -- see the note above."""
    return sorted(pid for pid in (observed_holders(port) or ()) if signallable(pid))


def describe_process(pid):
    try:
        with open(f'/proc/{pid}/cmdline', 'rb') as handle:
            return handle.read().replace(b'\0', b' ').decode(errors='replace').strip()
    except OSError:
        return f'pid {pid}'


# A HOST SIDE IS EITHER …:8080 OR …:5000-5001, and the second cost the whole
# bench its up. docker collapses consecutive published ports into a RANGE in the
# Ports column (NMOS-Testing prints 127.0.0.1:5000-5001->5000-5001/tcp), so a
# `:{port}$` match found nothing and both ports read as published by NO
# container. This then reported unreachable-holder, and prepare_for_up || exit 1
# in up.sh aborted before for_each_stack ran — no stack started, and the message
# blamed a host process that did not exist.
HOST_SIDE_PORT = re.compile(r':(\d+)(?:-(\d+))?$')


def _host_side_covers(host_side, port):
    """Does this mapping's host side publish `port`? Handles the range form."""
    match = HOST_SIDE_PORT.search(host_side.strip())
    if not match:
        return False
    first = int(match.group(1))
    last = int(match.group(2)) if match.group(2) else first
    return first <= int(port) <= last


def containers_publishing(port):
    """Container ids publishing the port. Matched against the Ports column,
    which reads like `127.0.0.1:8080->8080/tcp` or, for adjacent ports,
    `127.0.0.1:5000-5001->5000-5001/tcp`; only the host side (left of `->`) is
    ours to collide with -- the container side is inside its own namespace and
    colliding with it is not a thing that can happen."""
    found = []
    own = os.path.realpath(ONLY_STACK_FILE) if ONLY_STACK_FILE else ''
    for line in (capture(['docker', 'ps', '--format',
                          '{{.ID}}\t{{.Names}}\t{{.Ports}}\t'
                          '{{.Label "com.docker.compose.project.config_files"}}']) or '').splitlines():
        parts = line.split('\t')
        if len(parts) != 4:
            continue
        identifier, name, mappings, config_files = parts
        # THE STACK BEING MOUNTED IS NOT IN ITS OWN WAY. A per-stack remount
        # stopped its own healthy broker to "free" 1884, which dropped the
        # capture agent, which exited, which made the watchdog remount the
        # stack again — every thirty seconds. compose up keeps or recreates
        # its own containers; only a stranger on the port is evicted.
        if own and any(os.path.realpath(f) == own for f in config_files.split(',') if f):
            continue
        for mapping in mappings.split(','):
            host_side = mapping.split('->')[0]
            if '->' in mapping and _host_side_covers(host_side, port):
                found.append((identifier, name))
                break
    return found


ONLY_STACK_FILE = os.environ.get('ONLY_STACK_FILE', '')


def held_by_own_stack(port):
    """Is every container on this port one the scoped stack's compose file made?"""
    if not ONLY_STACK_FILE:
        return False
    own = os.path.realpath(ONLY_STACK_FILE)
    holders = 0
    for line in (capture(['docker', 'ps', '--format',
                          '{{.Ports}}\t{{.Label "com.docker.compose.project.config_files"}}']) or '').splitlines():
        mappings, _, config_files = line.partition('\t')
        if not any('->' in m and _host_side_covers(m.split('->')[0], port) for m in mappings.split(',')):
            continue
        if not any(os.path.realpath(f) == own for f in config_files.split(',') if f):
            return False
        holders += 1
    return holders > 0


def free_the_port(port):
    """Evict every holder of one port.

    Returns `(freed, reason)`. The reason is '' on success and otherwise names
    which of the two dead ends we reached, because they have different fixes:
    `unreachable-holder` is a port nothing here could even take hold of, and
    `held` is one that survived everything we were allowed to do to it."""
    if port_is_free(port):
        return True, ''
    if held_by_own_stack(port):
        print(f"    port {port} is held by this stack's own container -- left for compose", flush=True)
        return True, ''

    attempted = False

    for pid in processes_holding(port):
        attempted = True
        print(f"    \U0001f4a5 {ORDER} to kill {describe_process(pid)} (pid {pid}) "
              f"holding port {port}", flush=True)
        announce("PORT_EVICT_PROCESS", {"port": port, "pid": pid,
                                        "command": describe_process(pid),
                                        "ordered_by": ORDERED_BY, "chain": CHAIN})
        for sig in (15, 9):
            try:
                os.kill(pid, sig)
            except OSError:
                break
            for _ in range(20):
                if port_is_free(port):
                    return True, ''
                time.sleep(0.1)

    for identifier, name in containers_publishing(port):
        attempted = True
        print(f"    \U0001f4a5 {name} ({identifier}) {ORDER} to shut down "
              f"-- it publishes port {port}", flush=True)
        announce("PORT_EVICT_CONTAINER", {"port": port, "container": name,
                                          "id": identifier,
                                          "ordered_by": ORDERED_BY, "chain": CHAIN})
        capture(['docker', 'stop', '-t', '5', identifier])
        for _ in range(30):
            if port_is_free(port):
                return True, ''
            time.sleep(0.2)

    # A TIME_WAIT socket with no owner frees itself; give it a moment.
    for _ in range(20):
        if port_is_free(port):
            return True, ''
        time.sleep(0.1)
    if port_is_free(port):
        return True, ''
    return False, 'held' if attempted else 'unreachable-holder'


def expand_compose_value(token):
    """Resolve `${NAME:-default}`, `${NAME-default}` and `${NAME}` the way
    compose does, against the environment this process will hand it. Anything
    else comes back untouched, and a caller that wanted a number will find it
    is not one."""
    match = re.fullmatch(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-(.*))?\}', token)
    if not match:
        return token
    name, fallback = match.group(1), match.group(2)
    return os.environ.get(name) or (fallback if fallback is not None else '')


def published_host_ports():
    """Host ports the driven compose projects publish, read from the compose
    files rather than spelled again here."""
    ports = set()
    for compose_file in (os.environ.get('COMPOSE_FILE', ''),
                         os.environ.get('BAREMETAL_COMPOSE_FILE', ''),
                         os.environ.get('MQTT_COMPOSE_FILE', ''),
                         os.environ.get('PORTAL_COMPOSE_FILE', ''),
                         os.environ.get('NMOS_COMPOSE_FILE', ''),
                         os.environ.get('AES70_COMPOSE_FILE', ''),
                         os.environ.get('NETBOX_COMPOSE_FILE', ''),
                         os.environ.get('EMBER_COMPOSE_FILE', ''),
                         os.environ.get('LOGGER_COMPOSE_FILE', ''),
                         os.environ.get('SQLCLUSTER_COMPOSE_FILE', '')):
        if not compose_file or not os.path.exists(compose_file):
            continue
        try:
            with open(compose_file, encoding='utf-8') as handle:
                text = handle.read()
        except OSError:
            continue
        # - "1883:1883", - "127.0.0.1:8080:8080", and the one that matters:
        # - "${PORT:-8080}:80". The host port is the field before the container
        # port. THE INTERPOLATED FORM IS WHY THIS READS THE FILE RATHER THAN A
        # LIST — a literal-only match drops 8080 and reports success having
        # checked nothing. A range (8000-8010:...) is deliberately NOT matched:
        # evicting a range is a bigger act than this is allowed to be.
        for entry in re.findall(r'^\s*-\s*"?([^"\s]+):\d+(?:/\w+)?"?\s*(?:#.*)?$',
                                text, re.MULTILINE):
            # EXPAND BEFORE SPLITTING: ${PORT:-8080} carries a colon of its
            # own, so splitting first yields -8080} — not a number, silently
            # dropped, 8080 uncovered.
            host_port = expand_compose_value(entry).rsplit(':', 1)[-1]
            if host_port.isdigit():
                ports.add(int(host_port))
    return sorted(ports)


requested = [int(a) for a in sys.argv[1:] if a.isdigit()]
ports = requested or published_host_ports()

# --list exists so the port SET can be checked without the eviction, the one
# part of this script that cannot be undone.
if '--list' in sys.argv[1:]:
    for port in ports:
        print(f"{port}\t{'free' if port_is_free(port) else 'HELD'}")
    sys.exit(0)
held = [port for port in ports if not port_is_free(port)]

if not held:
    announce("PORTS_CLEAR", {"ports": ports})
    sys.exit(0)

announce("PORTS_HELD", {"ports": held})
still_held = []
for port in held:
    freed, reason = free_the_port(port)
    if not freed:
        if reason == 'unreachable-holder':
            # The one failure that is not this script to fix. Name the host
            # command: the reader is looking at a container stdout and the
            # eviction has to happen somewhere else entirely.
            print(f"    ⚠️  port {port} is held and nothing here can take hold of it: "
                  f"no process this side may signal owns the socket, and no container "
                  f"publishes the port. From inside the manager that is what a HOST "
                  f"process looks like -- evict it on the host:", flush=True)
            print(f"           ss -ltnp 'sport = :{port}'   # name it, then kill that pid",
                  flush=True)
        else:
            print(f"    ⚠️  port {port} is still held and could not be freed; "
                  f"compose will report the collision below.", flush=True)
        announce("PORT_EVICT_FAILED", {"port": port, "reason": reason})
        still_held.append(port)

sys.exit(1 if still_held else 0)
PY
