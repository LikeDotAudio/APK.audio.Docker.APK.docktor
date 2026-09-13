# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""🏃 The one way out of this process. Run a script, read what it prints.

OWNS starting one file from `DockTor/SRC/docker scripts/`, streaming
its output, lifting its @EVENT lines onto the bus, and returning its EXIT CODE —
which the streamer this replaced threw away, so the GUI printed a green tick
over a rebuild whose every compose call had failed.
MUST NOT REACQUIRE a compose command, a docker ps format string, a port or a
container name. Every one of those is in a script.

    run_management_script(name, args, on_line_callback, quiet, cancellable)
        -> (exit_code, text)
    cancel_running_scripts(reason) -> [names]   # what 🛑 reaches through
"""

import os
import re
import json
import time
import signal
import threading
import subprocess

from .paths import DOCKER_SCRIPTS_DIRECTORY, REPOSITORY_ROOT
from .bus import emit


# ---------------------------------------------------------------------------
# THE SCRIPT COLLECTION. Every docker verb lives in
# `DockTor/SRC/docker scripts/` as one executable file and this module
# RUNS them: nothing below spells a compose command, a format string, a port or
# a container name. A verb in a file is a verb you can run, diff and hand over;
# this module was the copy that drifted, because it could only be reached
# through a Tkinter window.
# WHAT STAYS HERE: the bus, the window, and the reading of what scripts print.
# ---------------------------------------------------------------------------
# DERIVED, NOT SPELLED, and not even joined here any more. A stale join pointed
# at a renamed directory SILENTLY — the failure is a FileNotFoundError from
# subprocess when a verb is pressed, not at import. paths.py owns the join now,
# so this name and api.py `scripts` field cannot answer differently.
DOCKER_SCRIPTS = DOCKER_SCRIPTS_DIRECTORY

def set_port_eviction(enabled):
    """Arm or disarm free-ports.sh for every script this process runs.

    --no-kaboom travels as ENVIRONMENT, not argv: it has to reach free-ports.sh
    through up.sh and rebuild-all.sh, and threading a flag down two levels of
    argv is how the middle one passes it to compose.
    A FUNCTION, not an argv read at import — this module used to sniff
    sys.argv[1:] as a side effect of being imported.
    """
    # UNSET rather than 0: _common.sh reads ${APKAUDIO_NO_KABOOM:-0}, so both
    # mean armed, and a leftover 0 looks like something set it deliberately.
    if enabled:
        os.environ.pop('APKAUDIO_NO_KABOOM', None)
    else:
        os.environ['APKAUDIO_NO_KABOOM'] = '1'

# The line shape _common.sh announce() writes. A script cannot publish for
# itself — no broker connection, and one per invocation would make every ps.sh a
# network act — so it says what happened on stdout and this puts it on the bus.
# A line that does not match is ordinary output, passed through untouched.
EVENT_LINE = re.compile(r'^@EVENT\s+([A-Z_]+)\s*(\{.*\})?\s*$')


# ---------------------------------------------------------------------------
# WHAT COUNTS AS AN ERROR LINE. One definition, because two would disagree: the
# log paints red with it and the copy dialog filters with it.
# THE ZERO-COUNTER RULE is the difficulty: verify.sh success line is
# `CONTAINER_TESTS: {"passed": 8, "failed": 0, "warnings": 0}`, so a plain
# search for "failed" paints a passing run red. `"key": 0` pairs are struck out
# before the words are read, leaving "failed": 2 matching and "failed": 0 not.
# ---------------------------------------------------------------------------
# LINES THAT SAY A WORD FROM THE LIST AND MEAN NOTHING BY IT: `debconf: unable
# to initialize frontend: Dialog` is apt without a tty, four times per RUN
# layer, and is how an errors-only copy of a WORKING build came back three
# hundred lines long. Checked BEFORE the words, so one list serves both the
# paint and the sieve in brief.py.
BENIGN_NOISE = (
    re.compile(r'^\s*debconf:\s*(?:unable to initialize frontend|falling back to '
               r'frontend|delaying package configuration|\(.*(?:ReadLine|controlling tty))'),
    re.compile(r'^\s*dpkg-preconfigure:\s*unable to re-open stdin'),
    re.compile(r'^\s*Extracting templates from packages'),
    re.compile(r'apt does not have a stable CLI interface'),
    re.compile(r'^\s*For more information about this (?:error|warning), try'),
    re.compile(r'^\s*=\s*note: for more information, see <http'),
    re.compile(r'debconf: \(This frontend requires'),
)


def is_benign_noise(line):
    """True for output that names a failure word while reporting nothing wrong."""
    return any(pattern.search(line) for pattern in BENIGN_NOISE)


ERROR_MARKERS = ('\u274c', '\u26a0', '\U0001f6a8')       # the emoji this GUI logs with
ZERO_COUNTER = re.compile(r'"[a-z_]+"\s*:\s*0\b')
NONZERO_EXIT = re.compile(r'"exit_code"\s*:\s*(?!0\b)-?\d+')
ERROR_WORDS = re.compile(
    r'\b(error|errno|failed|failing|failure|fatal|traceback|exception|panic|'
    r'refused|denied|unreachable|timed out|timeout|missing|not found|'
    r'cannot|could not|unable to)\b', re.IGNORECASE)


def is_error_line(line):
    """True if this log line reports something going wrong."""
    if is_benign_noise(line):
        return False
    if any(marker in line for marker in ERROR_MARKERS):
        return True
    if NONZERO_EXIT.search(line):
        return True
    # Underscores become spaces before the words are read: the @EVENT names are
    # the failures worth catching (SCRIPT_MISSING, RESOURCES_FAILED) and `_` is
    # a word character, so \bmissing\b does not match inside one.
    return bool(ERROR_WORDS.search(ZERO_COUNTER.sub('', line).replace('_', ' ')))


def relay_event_line(line):
    """Republish one `@EVENT NAME {json}` line onto the bus. True if it was one."""
    match = EVENT_LINE.match(line.strip())
    if not match:
        return False
    name, payload = match.group(1), match.group(2)
    try:
        details = json.loads(payload) if payload else {}
    except ValueError:
        details = {"raw": payload}
    emit(name, details)
    return True


# ---------------------------------------------------------------------------
# WHAT IS RUNNING RIGHT NOW, AND HOW TO STOP IT.
# THE STOP BUTTON IS NOT ANOTHER ACTION: api.ACTION_LOCK refuses a second verb
# rather than queueing it, which is right for a second BUILD and inverted for
# down and panic. One rebuild-all held the lock for eleven minutes and refused
# five presses of Stop with the bench already down.
# A SESSION, NOT A PROCESS: start_new_session=True puts each script in its own
# process group so the cancel can signal the GROUP — up.sh is a shell whose
# docker compose build child is what actually holds the ports.
# ⚠️ ONLY THE ACTION RUNS ARE REGISTERED. `cancellable` is passed by
#    run_reported() and nothing else, so the repaint ps.sh and stats.sh are not
#    in this table. It is also what gives a run its own session, and the two
#    must stay tied: a registered run without one would signal the group the
#    MANAGER is in.
# ---------------------------------------------------------------------------
_RUNNING = {}
_RUNNING_LOCK = threading.Lock()

# BUMPED ONCE PER CANCEL and read either side of a run, by whoever wants to know
# whether the failure it got back was a failure or a stop. A boolean on the run
# would lose the race: the record is gone from _RUNNING by the time the caller
# asks.
_CANCEL_EPOCH = 0


def cancel_epoch():
    """A counter that moves every time a cancel is issued. See run_action()."""
    return _CANCEL_EPOCH


def running_scripts():
    """The cancellable scripts this process has open right now, by name."""
    with _RUNNING_LOCK:
        return [run["name"] for run in _RUNNING.values()]


def _signal_group(process, signal_number):
    """Signal the script's whole process group. False if it had already gone."""
    try:
        os.killpg(os.getpgid(process.pid), signal_number)
        return True
    except (ProcessLookupError, PermissionError, OSError):
        return False


def cancel_running_scripts(reason="", grace_seconds=8.0):
    """SIGTERM every running action process group; SIGKILL what outlives it.

    Returns the names cancelled, oldest first, or [].
    THE RUNS END THEMSELVES: nothing here joins a thread — killing the group
    closes the pipe run_management_script() is blocked reading, so its reader
    loop falls out and wait() returns the signal exit code in the thread that
    started it.
    """
    global _CANCEL_EPOCH
    with _RUNNING_LOCK:
        victims = list(_RUNNING.values())
        _CANCEL_EPOCH += 1
        for run in victims:
            run["cancelled"] = True
    if not victims:
        return []
    names = [run["name"] for run in victims]
    emit("SCRIPTS_CANCELLING", {"scripts": names, "reason": reason})
    for run in victims:
        _signal_group(run["process"], signal.SIGTERM)
    # ONE deadline for all of them: eight seconds is what a compose gets to
    # unwind, and three victims are not owed twenty-four.
    deadline = time.monotonic() + grace_seconds
    for run in victims:
        while run["process"].poll() is None and time.monotonic() < deadline:
            time.sleep(0.1)
    killed = []
    for run in victims:
        if run["process"].poll() is None and _signal_group(run["process"], signal.SIGKILL):
            killed.append(run["name"])
    emit("SCRIPTS_CANCELLED", {"scripts": names, "killed": killed, "reason": reason})
    return names


def is_any_script_running():
    """True if any management script is currently running."""
    with _RUNNING_LOCK:
        return bool(_RUNNING)


def run_management_script(name, args=(), on_line_callback=None, quiet=False,
                          cancellable=False):
    """Run one script from the collection; return (exit_code, combined output).

    THE EXIT CODE IS PART OF THE RETURN VALUE. The streamer this replaces threw
    it away and its one caller announced success unconditionally, so a rebuild
    whose every compose invocation failed still printed the green tick.
    stderr is folded into stdout, so the failure and the output that led to it
    arrive in one order rather than two.
    `quiet` SUPPRESSES THE TWO BUS EVENTS, NOT THE EXIT CODE: a screen refresh
    is not telemetry, and announcing SCRIPT_START/SCRIPT_RESULT per repaint put
    24 messages a minute on the topic against the resource sampler ONE — the
    series a gap in has to read as a stopped sampler. SCRIPT_MISSING is NOT
    suppressed: a script that is not there is news at any beat.
    `cancellable` PUTS THIS RUN WHERE A STOP CAN REACH IT. Only the action path
    passes it.
    """
    script = os.path.join(DOCKER_SCRIPTS, name)
    if not os.path.exists(script):
        message = f"\u274c missing management script: {script}\n"
        if on_line_callback:
            on_line_callback(message)
        emit("SCRIPT_MISSING", {"script": script})
        return 127, message

    argv = [script, *args]
    if not quiet:
        emit("SCRIPT_START", {"script": name, "argv": argv})
    process = subprocess.Popen(
        argv,
        cwd=REPOSITORY_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        # ITS OWN PROCESS GROUP, so a cancel signals the compose and cargo
        # children as well as the shell above them.
        # TIED TO `cancellable`, and both directions matter:
        #   a group of its own that nothing can cancel is a REGRESSION — at a
        #   terminal Ctrl-C reaches the foreground group, and a CLI rebuild-all
        #   in its own session would keep building after the operator broke out;
        #   a cancellable run WITHOUT its own group is worse — killpg would
        #   reach the manager group and take the manager down with the script.
        start_new_session=cancellable,
    )
    record = {"name": name, "process": process, "cancelled": False}
    if cancellable:
        with _RUNNING_LOCK:
            _RUNNING[process.pid] = record

    output_lines = []
    try:
        for line in iter(process.stdout.readline, ''):
            if not line:
                continue
            output_lines.append(line)
            # An @EVENT line is CONSUMED, not forwarded: emit() prints its own
            # 📡 line for the same event, so passing the raw one through put
            # every event on screen twice in two spellings.
            if relay_event_line(line):
                continue
            if on_line_callback:
                on_line_callback(line)
        process.stdout.close()
        process.wait()
    finally:
        # DEREGISTERED EVEN ON THE WAY OUT OF AN EXCEPTION: a record left
        # behind is a dead pid a later cancel would signal, and pids get reused.
        with _RUNNING_LOCK:
            _RUNNING.pop(process.pid, None)
    if record["cancelled"]:
        # SAID AS WELL AS, NOT INSTEAD OF, SCRIPT_RESULT — everything reading
        # the result line goes on reading it, and gets the signal negative exit
        # code, which is the truth about how the run ended.
        emit("SCRIPT_CANCELLED", {"script": name, "exit_code": process.returncode})
    if not quiet:
        emit("SCRIPT_RESULT", {"script": name, "exit_code": process.returncode})
    return process.returncode, "".join(output_lines)

