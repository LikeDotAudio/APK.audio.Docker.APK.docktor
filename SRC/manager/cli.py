# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""⌨️ The terminal half. One action, one script — the table IS the mapping.

OWNS turning an argument into a script name. A new verb is a row in one of the
two tables below plus a file in the collection, never a branch that runs docker.
TWO TABLES, AND THE DIFFERENCE IS ARITY: CLI_ACTIONS verbs take no argument and
are given a fixed one; CLI_ACTIONS_WITH_ARGS verbs forward whatever is left,
because `logs Storage-Portal 500` cannot be expressed by a script name alone.
`serve` is a verb here because the server is one more thing you can ask this
file for, not a separate program.
`test` and `up` do not both gate: up.sh runs the gates itself, and `test` is
the way to run them WITHOUT mounting.
`logs` READS and `clear-logs` TRUNCATES. It was the other way round, which put
the destructive act behind the innocuous word.
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
    ('fetch-and-run', 'sync-repos', 'clone-and-run', 'repos'): ("🐙 Fetching Git repositories and launching Docker stacks...", 'fetch-and-run.sh'),
    ('open', 'open-repo', 'git-open', 'repo'): ("📂 Opening/inspecting microservice Git repository...", 'open-repo.sh'),
    ('sos', 'panic', 'panic-reboot', '--panic', '-p'): ("🚨 Emergency SOS Panic Stop...", 'panic.sh'),
    ('logs', 'log'): ("📜 Reading container log...", 'logs.sh'),
    ('restart', 'bounce'): ("🔄 Restarting container...", 'restart.sh'),
    # NOT the bare `rebuild` above, which is the whole-bench one: this builds
    # the one service the named container is, in the project that container
    # records, and leaves the rest of the bench alone.
    ('rebuild-one', 'rebuild-container'): ("🧱 Rebuilding container...", 'rebuild.sh'),
    ('exec', 'shell', 'sh'): ("🐚 Running inside container...", 'exec.sh'),
    ('inspect',): ("🔍 Inspecting container...", 'inspect.sh'),
    ('config-path', 'dockerfile'): ("📄 Resolving what built this container...", 'config-path.sh'),
    # WITH ARGS although it takes none by default: a bare `purpose` prints all
    # 28 paragraphs, and `purpose Storage-PHP` is the question somebody has.
    ('purpose', 'what', 'why'): ("📘 What this container is, and why the bench needs it...",
                                 'purpose.sh'),
    ('prune',): ("♻️  Reclaiming unused docker storage...", 'prune.sh'),
    # WITH ARGS for `--fast`, which is the same reading without the sizes: the
    # size walk is the expensive half and a terminal asking "which volumes
    # exist" should not pay for it.
    ('volumes', 'volume', 'storage-usage'): (
        "🗄️  Every volume, the four docker totals and the disk under them...",
        'volumes.sh'),
    # The pointer the VOLUMES tab draws, and the one verb that CREATES storage:
    # `--ensure` makes the folder and the named volume that binds it, a bare
    # call only reports. See storage-volume.sh for why it never re-points one.
    ('storage', 'storage-volume'): (
        "📦 DockTor's own persistent storage — the folder that is a volume...",
        'storage-volume.sh'),
    # WITH ARGS for `--all`, which is a different act from the bare verb: the
    # bare one drops what the last build superseded, `--all` drops the warm
    # layers the next build would have reused. Every build path already ends
    # with the bare one — see clean_build_cache in _common.sh — so this verb is
    # for the sweep you ask for between builds.
    ('clean-cache', 'clear-cache', 'build-cache'): (
        "🧽 Cleaning the docker build cache...", 'clean-build-cache.sh'),
    # WITH ARGS because the sweep and the single kill are one verb: no name
    # takes every stopped container, a name takes that one, --force means a
    # running one. The behaviour is the script to decide.
    ('clear-dead', 'dead', 'reap'): ("⚰️  Removing stopped containers...",
                                    'remove-dead-containers.sh'),
    # WITH ARGS AND NO FIXED ONES, which is the whole safety of it here: the
    # consent token is nuke.sh's own, and a bare `nuke` therefore reaches the
    # script WITHOUT it and prints the rehearsal. Nothing in this file may
    # supply --yes-nuke-everything — the web client does, after three dialogs,
    # and a terminal has the operator to type it.
    ('nuke',): ("☢️  NUKE — every container, image, VOLUME and cache on this host...",
                'nuke.sh'),
    ('phoenix', '--phoenix', '--Phoenix', 'burn', '--burn'): (
        "🔥 PHOENIX — Burning it all down and rebuilding the ecosystem from scratch...",
        'phoenix.sh'),
}

USAGE = """Usage: python3 'APK:PODS/K8:runner.py' <action> [args] [--no-kaboom]

  serve [--bind H] [--port N] [--open] [--defer]
                       the HTTP API and its browser client. THIS IS THE
                       DEFAULT: a bare invocation runs it on
                       http://127.0.0.1:8765/. The bind is loopback because
                       this API stops containers and has no authentication;
                       the two are a pair. `--open` raises the client in a
                       browser. When the port is ALREADY held by a manager,
                       a terminal launch replaces it: a container is rebuilt
                       and remounted from this checkout (manager.sh up), a
                       terminal manager on this host is killed and this one
                       serves. `--defer` leaves the incumbent alone.
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
  volumes [--fast]     every docker volume with its size, the four totals
                       (images / containers / volumes / cache) and the
                       filesystem under them. `--fast` skips the size walk.
  storage [--ensure]   where DockTor keeps its own state: a local folder that
                       is also a named docker volume. `--ensure` creates both.
                       The VOLUMES tab in the browser draws this pointer and
                       graphs the series kept in it.
  clean-cache [--all]  drop the BuildKit build cache. EVERY BUILD ALREADY DOES
                       THIS on the way out (the dangling half); --all takes the
                       warm layers too, so the next build starts from nothing.
                       APKAUDIO_BUILD_CACHE_CLEAN=off|all changes what the
                       automatic sweep after a build does.
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
  fetch-and-run <urls|dirs…> [--build] [--rebuild]
                       clone/pull a list of Git repositories or local paths,
                       locate their docker-compose files, and bring up stacks.
                       Pass `--file repos.txt` to read a list of repos.
  sos | panic | --panic [--dry-run]
                       emergency stop -- kills everything but the manager,
                       and on an already-empty bench reboots the manager
                       instead, rebuilding every image from the code.
                       Pass `--dry-run` to rehearse without touching containers.
  nuke                 REHEARSAL by default: what a nuke would remove, and
                       nothing removed. ☢️ THE PRESS IS
                       `nuke --yes-nuke-everything`, which deletes every
                       container, image, network, cache AND NAMED VOLUME on
                       this host. The volumes are the data; nothing here
                       backs them up and nothing here restores them.
                       --include-manager takes the manager too (host only)
  phoenix | --Phoenix  🔥 PHOENIX — burn it all down and start all over.
                       Deletes every container, image, network, cache AND
                       NAMED VOLUME (all local data) on this host, then
                       performs a clean rebuild and remount from source code.

Every action runs one file from 'APK:PODS/Docktor/SRC/docker scripts/';
run them directly too."""


def _stream(line):
    """Print as it arrives. A build whose output appears only when it finishes
    is a build that looks hung for ten minutes."""
    print(line, end='', flush=True)


def _can_raise_a_browser():
    if os.path.exists("/.dockerenv"):
        return False
    if not sys.stdout.isatty():
        return False
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def _already_serving(url="http://127.0.0.1:8765/api/health"):
    """Is a DockTor answering RIGHT NOW? Two seconds, and never an exception."""
    try:
        import urllib.request
        urllib.request.urlopen(url, timeout=2).read(1)
        return True
    except Exception:
        return False


def _open_browser_immediately():
    """Raise the dashboard ONLY IF THERE IS ONE, and say so if there is not.

    IT USED TO OPEN UNCONDITIONALLY, on the first line of `up` and `rebuild` —
    which on the bench those verbs exist for (nothing mounted yet) is a browser
    tab that says ERR_CONNECTION_REFUSED while the build it was meant to show
    runs for ten minutes behind it.
    THE SCRIPTS OWN THE OTHER HALF NOW: DockTor is the first stack
    for_each_stack mounts, and open_manager_site() in _common.sh raises the page
    the moment it answers. APKAUDIO_SITE_OPENED is how the two halves agree on
    one tab — set here when this one opens it, read there.
    """
    if os.environ.get("APKAUDIO_SITE_OPENED") == "1":
        return
    if not _can_raise_a_browser() or not _already_serving():
        # Not "no browser": the mount is about to raise one itself.
        return
    os.environ["APKAUDIO_SITE_OPENED"] = "1"
    try:
        import webbrowser
        webbrowser.open_new_tab("http://127.0.0.1:8765/")
    except Exception:
        pass


def run_cli_mode(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    args = [a for a in argv if a not in ('--cli', '--no-kaboom')]
    action = args[0].lower() if args else 'status'
    rest = args[1:]
    # WHO ASKED, for free-ports.sh to print beside every stop. setdefault: a
    # CLI run launched by something that already named itself keeps that name.
    os.environ.setdefault('APKAUDIO_ORDERED_BY',
                          "the terminal: K8:runner.py " + " ".join(argv or ['status']))

    # THE PAGE IS WORTH HAVING OPEN FOR THESE, and for a rebuild it is the whole
    # point — but only when there is already something to open. A cold bench
    # gets its tab from the mount itself, seconds after DockTor binds, because
    # DockTor is what for_each_stack mounts first.
    if action in ('rebuild', 'clean', 'up', 'remount', 'mount', 'start', 'rebuild-one', 'rebuild-container'):
        _open_browser_immediately()


    for names, (banner, script, script_args) in CLI_ACTIONS.items():
        if action in names:
            print(banner)
            exit_code, _ = run_management_script(script, script_args,
                                                 on_line_callback=_stream)
            sys.exit(exit_code)

    for names, (banner, script) in CLI_ACTIONS_WITH_ARGS.items():
        if action in names:
            print(banner)
            # `exec` must NOT be streamed through a pipe: it asks for a
            # terminal when stdin is one, and reading its output line by line
            # takes that terminal away. os.execvp hands the process over.
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
        # The gates AND the suite: `test` is what mount.sh calls to decide
        # whether to build, so either failing must fail it.
        gates_ok = run_prebuild_test_gates(on_line_callback=_stream)
        tests_ok = run_container_tests(on_line_callback=_stream)
        sys.exit(0 if (gates_ok and tests_ok) else 1)

    if action == 'serve':
        # THE DEFAULT VERB — a bare `K8:runner.py` inserts it.
        # LOOPBACK UNLESS TOLD OTHERWISE, and serve.py header says why: this
        # API stops containers and rebuilds images with no authentication, so
        # the bind is the only control there is. --bind is for the container
        # case, where compose publishes the port on 127.0.0.1.
        from .serve import serve
        bind, port, open_browser, takeover = '127.0.0.1', 8765, False, True
        remaining = list(rest)
        while remaining:
            word = remaining.pop(0)
            if word in ('--open', '--browser'):
                open_browser = True
            elif word == '--defer':
                takeover = False
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
        sys.exit(serve(bind=bind, port=port, open_browser=open_browser,
                       takeover=takeover))

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
# CLI invocation from a bare `python3 …K8:runner.py`. Built from the tables rather
# than typed again: it WAS typed again in main(), and a verb added to the table
# but not to that list opened a Tkinter window instead of running.
KNOWN_ACTIONS = (
    {name for names in CLI_ACTIONS for name in names}
    | {name for names in CLI_ACTIONS_WITH_ARGS for name in names}
    | {'test', '--test', 'check', 'resources', 'stats', 'watch', 'status', 'ps',
       'serve'}
)
