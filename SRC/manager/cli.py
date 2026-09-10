# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
"""⌨️ The terminal half. One action, one script — the table IS the mapping.

WHAT THIS MODULE OWNS. Turning an argument into a script name. A new verb is a
row in one of the two tables below and a file in the collection, never a branch
that runs docker.

IT IS NO LONGER "THE HEADLESS HALF", BECAUSE THERE IS NO OTHER KIND. The other
surface was a Tkinter window that needed a DISPLAY; it is now `serve.py`, an
HTTP API that runs anywhere this does. `serve` is a verb in this table for that
reason — the server is one more thing you can ask this file for, not a separate
program with its own front door.

TWO TABLES, AND THE DIFFERENCE IS ARITY. `CLI_ACTIONS` verbs take no argument
and are given a fixed one; `CLI_ACTIONS_WITH_ARGS` verbs forward whatever is
left on the command line, because `logs Storage-Portal 500` cannot be
expressed by a table that only holds a script name.

`test` and `up` do not both gate. up.sh runs the gates itself; `test` is the way
to run them WITHOUT mounting, which is what APK.audio:mount.sh beside us shells
out to this package for.

`logs` READS and `clear-logs` TRUNCATES. It was the other way round until
2026-09-03 — `logs` was mapped to clear-logs.sh, and there was no way to read a
container's log at all — which put the destructive act behind the innocuous
word. Anything that called `logs` expecting a truncate now gets a read; that is
a break, and it is the safe direction to break in.
"""

import os
import sys
import time

from .bus import emit
from .runner import run_management_script
from .readers import (sample_resources, start_resource_sampler,
                      run_prebuild_test_gates, run_container_tests)


# Verb -> (banner, script, fixed arguments). Takes nothing from the user.
CLI_ACTIONS = {
    ('up', 'remount', 'mount', 'start'): ("🚀 Remounting APK.audio containers...", 'up.sh', []),
    ('rebuild', 'clean'): ("⚡ Clean rebuilding APK.audio containers...", 'rebuild-all.sh', []),
    ('down', 'stop'): ("🛑 Stopping APK.audio containers...", 'down.sh', []),
    ('sos', 'panic'): ("🚨 Emergency SOS Panic Stop...", 'panic.sh', ['PANIC_CLI']),
    ('gates',): ("🛡️ Running pre-build gates only...", 'test-gates.sh', []),
    ('verify',): ("🧪 Verifying the running ecosystem...", 'verify.sh', []),
    ('ports',): ("💥 Freeing every published host port...", 'free-ports.sh', []),
    ('clear-logs', 'truncate-logs'): ("🧹 Truncating docker log files...", 'clear-logs.sh', []),
    ('log-rates', 'log-sizes', 'log-stats'): ("📊 Sampling container log sizes and growth rates...", 'log-rates.sh', []),
    ('disk', 'df'): ("💾 What docker is holding on this disk...", 'disk.sh', []),
    ('endpoints', 'urls'): ("🔌 Every address this ecosystem answers on...", 'endpoints.sh', []),
    ('apps', 'agents'): ("🧩 What is running inside each container...", 'apps.sh', []),
}

# Verb -> (banner, script). Everything after the verb is forwarded verbatim.
CLI_ACTIONS_WITH_ARGS = {
    ('logs', 'log'): ("📜 Reading container log...", 'logs.sh'),
    ('restart', 'bounce'): ("🔄 Restarting container...", 'restart.sh'),
    # NOT the bare `rebuild` above, which is the whole-bench one. The verbs
    # differ by a suffix because the two acts differ by everything: this one
    # builds the one service the named container is, in the project that
    # container records, and leaves the rest of the bench alone.
    ('rebuild-one', 'rebuild-container'): ("🧱 Rebuilding container...", 'rebuild.sh'),
    ('exec', 'shell', 'sh'): ("🐚 Running inside container...", 'exec.sh'),
    ('inspect',): ("🔍 Inspecting container...", 'inspect.sh'),
    ('config-path', 'dockerfile'): ("📄 Resolving what built this container...", 'config-path.sh'),
    # WITH ARGS although it takes none by default, because the useful call is
    # the one-container one: a bare `purpose` prints all 28 paragraphs, which is
    # a page, and `purpose Storage-PHP` is the question somebody actually has.
    ('purpose', 'what', 'why'): ("📘 What this container is, and why the bench needs it...",
                                 'purpose.sh'),
    ('prune',): ("♻️  Reclaiming unused docker storage...", 'prune.sh'),
    # WITH ARGS because the sweep and the single kill are one verb: no name
    # takes every stopped container, a name takes that one, and `--force` is
    # how a running container is meant. Three tables' worth of behaviour is
    # the script's to decide, which is why it is one row here.
    ('clear-dead', 'dead', 'reap'): ("⚰️  Removing stopped containers...",
                                    'remove-dead-containers.sh'),
}

USAGE = """Usage: python3 'Manager:docktor.py' <action> [args] [--no-kaboom]

  serve [--bind H] [--port N] [--open]
                       the HTTP API and its browser client. THIS IS THE
                       DEFAULT: a bare invocation runs it on
                       http://127.0.0.1:8765/. The bind is loopback because
                       this API stops containers and has no authentication;
                       the two are a pair. `--open` raises the client in a
                       browser; when the port is ALREADY held by a manager
                       there is nothing else to do, so a run from a terminal
                       with a display opens it without being asked.
  status | ps          health of both stacks and the node
  watch                the above on a 3s loop, publishing a resource sample
  up | down            mount / unmount the ecosystem
  rebuild              delete old, build --no-cache, mount
  test                 the pre-build gates AND the running-bench suite
  gates | verify       one half of `test` each
  resources | stats    one docker stats sample, published on the bus
  endpoints            every address the ecosystem answers on
  apps | agents        what is running INSIDE each one — the node's agent
                       roster and the portal's served trees
  disk                 what docker is holding; read it before a rebuild
  prune [--all]        reclaim it (never volumes — see prune.sh)
  clear-dead [name…]   remove every container that is not running (or just
                       the named ones; --force for a running one, --dry-run)
  logs <container> [n] read a container's log
  restart <container>  bounce one container without touching the bench
  rebuild-one <c>      build the image behind one container and replace it,
                       from the compose file that container records
  exec <container> […] run a command inside one
  inspect <container>  its docker inspect payload
  config-path <c>      the compose file or Dockerfile that built it
  purpose [<c>]        what each container IS and why the bench needs it --
                       the written table, and `--check` is its coverage gate
  clear-logs           TRUNCATE every container's log file on disk
  log-rates            sample log size and live growth rate per container
  ports                free every published host port
  sos | panic          emergency stop -- kills everything but the manager,
                       and on an already-empty bench reboots the manager
                       instead, rebuilding every image from the code

Every action runs one file from 'APK:DOCKERS/DockTor/SRC/docker scripts/';
run them directly too."""


def _stream(line):
    """Print as it arrives. A build whose output appears only when it finishes
    is a build that looks hung for ten minutes."""
    print(line, end='', flush=True)


def run_cli_mode(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    args = [a for a in argv if a not in ('--cli', '--no-kaboom')]
    action = args[0].lower() if args else 'status'
    rest = args[1:]

    for names, (banner, script, script_args) in CLI_ACTIONS.items():
        if action in names:
            print(banner)
            exit_code, _ = run_management_script(script, script_args,
                                                 on_line_callback=_stream)
            sys.exit(exit_code)

    for names, (banner, script) in CLI_ACTIONS_WITH_ARGS.items():
        if action in names:
            print(banner)
            # `exec` is the one that must NOT be streamed through a pipe: it
            # asks for a terminal when stdin is one, and reading its output
            # line by line takes that terminal away. os.execvp hands the
            # process over instead, so an interactive shell stays interactive.
            if action in ('exec', 'shell', 'sh'):
                script_path = os.path.join(
                    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    'docker scripts', script)
                emit("SCRIPT_START", {"script": script, "argv": [script_path, *rest]})
                os.execvp(script_path, [script_path, *rest])
            exit_code, _ = run_management_script(script, rest,
                                                 on_line_callback=_stream)
            sys.exit(exit_code)

    if action in ('test', '--test', 'check'):
        # The gates AND the suite. `test` is what mount.sh calls to decide
        # whether to build, and what a person runs to ask if the bench is well;
        # both gates failing and the suite failing must fail it.
        gates_ok = run_prebuild_test_gates(on_line_callback=_stream)
        tests_ok = run_container_tests(on_line_callback=_stream)
        sys.exit(0 if (gates_ok and tests_ok) else 1)

    if action == 'serve':
        # THE DEFAULT VERB. A bare `docktor.py` inserts it, so this is
        # the branch a person who typed nothing reaches.
        #
        # LOOPBACK UNLESS TOLD OTHERWISE, and serve.py's header says why at
        # length: this API stops containers and rebuilds images and has no
        # authentication, so the bind is the only control there is. `--bind` is
        # for the container case, where compose publishes the port on 127.0.0.1
        # and the container boundary is what makes it safe.
        from .serve import serve
        bind, port, open_browser = '127.0.0.1', 8765, False
        remaining = list(rest)
        while remaining:
            word = remaining.pop(0)
            if word in ('--open', '--browser'):
                open_browser = True
            elif word == '--bind' and remaining:
                bind = remaining.pop(0)
            elif word == '--port' and remaining:
                port = int(remaining.pop(0))
            elif word.isdigit():
                port = int(word)
            else:
                print(f"Unknown option for serve: {word}\n")
                print(USAGE)
                sys.exit(1)
        sys.exit(serve(bind=bind, port=port, open_browser=open_browser))

    if action in ('resources', 'stats'):
        rows = sample_resources()
        emit("RESOURCES", {"interval_seconds": 0, "one_shot": True,
                           "running_count": len(rows), "containers": rows})
        for row in rows:
            print(f"{row['name']:<24} {row['cpu_percent']:<10} "
                  f"{row['memory']:<24} {row['memory_percent']:<10} {row['net_io']}")
        sys.exit(0)

    if action == 'watch':
        print("👁️ Continuous Live Container Status Watcher (Ctrl+C to stop)...\n")
        start_resource_sampler()
        try:
            while True:
                os.system('clear' if os.name != 'nt' else 'cls')
                print("🐳 APK.audio DockTor (Live Watcher)")
                print("=" * 60)
                run_management_script('status.sh', on_line_callback=_stream)
                time.sleep(3)
        except KeyboardInterrupt:
            print("\nWatcher stopped.")
            sys.exit(0)

    if action in ('status', 'ps'):
        print("🐳 APK.audio DockTor (CLI Mode)\n")
        exit_code, _ = run_management_script('status.sh', on_line_callback=_stream)
        sys.exit(exit_code)

    print(f"Unknown action: {action}\n")
    print(USAGE)
    sys.exit(1)


# Every word above that reaches the dispatcher, so the entry script can tell a
# CLI invocation from a bare `python3 …docktor.py` that wants a window.
# Built from the tables rather than typed a second time: the list WAS typed a
# second time in main(), and a verb added to the table but not to that list
# opened a Tkinter window instead of running.
KNOWN_ACTIONS = (
    {name for names in CLI_ACTIONS for name in names}
    | {name for names in CLI_ACTIONS_WITH_ARGS for name in names}
    | {'test', '--test', 'check', 'resources', 'stats', 'watch', 'status', 'ps',
       'serve'}
)
