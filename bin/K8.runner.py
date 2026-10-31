#!/usr/bin/env python3
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""☸️ APK.audio K8 runner — the front door to DockTor. The work is in the package.

Runs every verb in MANAGER.Docktor/K8/ (up, down, rebuild, ports, logs...) from a
terminal, or serves them as the DockTor HTTP API and browser client. It was
Manager:docktor.py until 2026-09-15; renamed because running the K8 scripts is
what it does.
A BARE INVOCATION LAUNCHES AND LETS GO. It starts DockTor if nothing is
serving, raises its page in a browser, hands the mount to the RUNNING DockTor
over its own API, and EXITS — so the ten minutes of docker build land in the
execution / recovery / errors swimlanes on that page, where every open tab sees
the same build and closing this terminal loses none of it. A terminal that owns
the build is the one-screen-one-process fault the window below was deleted for;
this file no longer creates one. `launch.sh` is the verb, and the only output
that still arrives here is the bootstrap of DockTor itself on a cold bench,
because until it is up there is nowhere else for it to go.
The browser client has a VOLUMES reading beside Cards / Donuts / Ports: the
storage pointer, a graph of every size over time with an isolating legend, and
the volume table. Its series is sampled server-side every five minutes into
DockTor own named volume — see 'docker scripts/storage-volume.sh'.
⚠️ THERE IS NO WINDOW ANY MORE AND THERE MUST NOT BE ONE AGAIN. This was a
   Tkinter dashboard — 2,850 lines across eight modules — and the window was the
   whole reason the tool was worse than the scripts under it:
   · ONE SCREEN, ONE PROCESS: a rebuild watched from the bench was invisible
     anywhere else, and closing the window lost its log.
   · A DISPLAY, OR NOTHING: the manager could not run where the containers run.
   · TABLES REACHABLE ONLY THROUGH A WIDGET: the exit-code table, the endpoint
     list and the port table lived inside methods that also built Tk widgets, so
     nothing could test them and every one drifted — into two dead tabs, and
     into a launcher with MariaDB password spelled into the URI.
   · A FRONT END NOBODY COULD SEE FROM THE THING IT MANAGES.
Now serve.py is the transport, api.py the route table, web/ the client, each
replaceable without touching the others.
THIS FILE IS A LAUNCHER AND NOTHING ELSE: it puts DockTor/SRC/ on the path,
decides server-or-terminal, and hands over.
⚠️ THE PACKAGE DIRECTORY IS `manager`, WITH NO COLON IN IT. A colon is not a
   legal module identifier, so the importable name has to be colon-free while
   the directory holding it need not be — which is why the parent could be
   renamed and pushed down into SRC/ without breaking the import. The
   colon-bearing part stays on the sys.path ENTRY and never in the name after
   `import`.
Every docker verb lives in `DockTor/SRC/docker scripts/` — one executable file
each. No compose command, no docker ps format string, no port, no container name
in any Python here.
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py'             # launch: DockTor, the page, the mount
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py' launch rebuild-all   # same handover, other verb
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py' serve --open         # the manager HERE, foreground
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py' status      # every stack + node
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py' up          # gated mount
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py' endpoints   # every address
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py' disk        # before a rebuild
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py' volumes     # every volume, with its size
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py' storage     # DockTor own storage volume
  python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8.runner.py' clean-cache # the build cache, by hand
                                  # (every build already drops it on the way
                                  #  out -- APKAUDIO_BUILD_CACHE_CLEAN=off|all)
  --no-kaboom                     # reaches the scripts as APKAUDIO_NO_KABOOM=1
"""

import os
import sys

# `DockTor/SRC/`, not the package itself: `import manager` needs the directory
# ABOVE it on the path. sys.path rather than PYTHONPATH deliberately —
# PYTHONPATH splits on `:` and this entry carries two of them, so an exported one
# would be parsed into four directories that do not exist.
# ⚠️ THIS IS THE ONE PLACE THE FOLDER NAMES ARE SPELLED; everything else walks up
#    from its own __file__. A rename broke exactly this line and one other, and
#    the SRC/ split broke this line and paths.py. If the folders move again,
#    those two are the search. The failure is loud, at import:
#    ModuleNotFoundError: No module named 'manager'.
#    EVERY SPELLING THE FOLDER HAS HAD IS IN THE LIST, AND THE LIST IS WHY THE
#    LAUNCHER STOPPED WORKING ONCE: it held 'Docktor' and 'APK:docktor' while
#    the folder on disk was 'APK:Docktor', so both probes missed by a letter of
#    case and a bare `K8.runner.py` died at the import above — no server, no
#    CLI, no message but the ModuleNotFoundError. A missing entry is a silent
#    miss, so the loop ends by taking the first candidate and letting the import
#    name the directory it could not find.
#    SINCE 2026-10-16 THIS FILE LIVES IN DockTor's OWN bin/, so `../SRC` is the
#    answer in the checkout; the sibling spellings are for the image, where
#    Dockerfile.manager COPYs it to /app/APK:DOCKERS/ beside APK:docktor/.
_HERE = os.path.dirname(os.path.abspath(__file__))
_DOCKTOR_NAMES = ('..', 'APK:docktor', 'Docktor', 'APK:Docktor', 'APK:DOCKTOR')
docktor_src = os.path.join(_HERE, _DOCKTOR_NAMES[0], 'SRC')
for _name in _DOCKTOR_NAMES:
    _candidate = os.path.join(_HERE, _name, 'SRC')
    if os.path.isdir(os.path.join(_candidate, 'manager')):
        docktor_src = _candidate
        break
sys.path.insert(0, docktor_src)

from manager import cli, runner                                   # noqa: E402


def main():
    # Said here rather than sniffed at import inside the package. The flag has
    # to reach free-ports.sh through up.sh, and it travels as ENVIRONMENT
    # because threading it down two levels of argv is how the middle one ends up
    # passing it to compose.
    runner.set_port_eviction('--no-kaboom' not in sys.argv[1:])

    # A BARE INVOCATION LAUNCHES. It used to open a window when there was a
    # display and print a table when there was not, so one command did two
    # different things on two machines and the useful one needed an X server.
    # Then it SERVED, which was right about where the dashboard should come
    # from and wrong about which process should be it: the manager people want
    # is the container, and a terminal one holds the port that container needs.
    # `launch` starts that container, opens the page and gives the mount to it.
    # ANY OTHER ARGUMENT MEANS TERMINAL — not "any argument this file
    # recognises", which was the old rule and failed in both directions: a verb
    # added to the CLI table but missed in the list opened a window instead of
    # running, and a MISSPELLED verb opened a window too, so the usage text
    # could never be reached on a machine with a display. cli.run_cli_mode()
    # rejects a word that is not in the tables.
    if not [a for a in sys.argv[1:] if a != '--no-kaboom']:
        sys.argv.insert(1, 'launch')
    cli.run_cli_mode()


if __name__ == '__main__':
    main()
