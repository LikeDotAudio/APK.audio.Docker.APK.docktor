# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
"""🐳 APK.audio DockTor — the API and the BUS. Not the docker.

An HTTP API over the APK.audio ecosystem's containers, a browser client served
from the same origin, and a `--cli` mode of the same verbs: the MQTT broker,
MariaDB, the nginx Portal, the NMOS rig and the BareMetal node.

WHAT THIS PACKAGE OWNS
  · the API — every question the tool can answer, as JSON, over HTTP
  · the client — three files under `web/`, no framework and no build step
  · the bus — everything that happens is announced on
    APK.audio/System/ContainerManager as it happens
  · running one script from the collection, and reading what it prints

WHAT IT DOES NOT OWN, AND MUST NOT REACQUIRE. Every docker verb lives in
`APK:DOCKERS/DockTor/SRC/docker scripts/` — one executable file each, listed in
that folder's `_common.sh` header. There is no compose command in this package,
no `docker ps` format string, no port number and no container name. If a change
here wants one of those, it belongs in a script; the reason is that the compose
rules were written out three times, and this was the copy that could only be
reached through a GUI, so it was the copy that drifted.

    runner.run_management_script(name, args, on_line_callback) -> (exit_code, text)

is the ONLY way out of this process. The exit code is half its return value on
purpose: the streamer it replaces threw it away, and the GUI printed a green
tick over a rebuild whose every compose call had failed (PLAN-297.01).

THERE IS NO `gui/` AND THERE MUST NOT BE ONE AGAIN. It was eight modules and
2,850 lines that each imported tkinter, and the window was the reason the tool
was worse than the scripts under it: it ran on one screen in one process, it
needed a DISPLAY so it could not run where the containers run, and every table
it held — the exit codes, the endpoints, the ports — lived inside a method that
was also building widgets, so none of them could be tested and all of them
drifted. `Manager:docktor.py`'s header carries the full account.

THE @EVENT PROTOCOL. A script cannot publish for itself — it holds no broker
connection. So it writes `@EVENT NAME {json}` on stdout, and
`runner.relay_event_line()` puts it on the bus while the same line goes to the
screen. One thing said once, readable in a terminal, on the bus, and — since
`serve.py` registers a bus sink — in every browser tab that has the manager open.

THE MODULE MAP, deepest first — each imports only from the ones above it:

    paths      where everything is; the brand accent
    bus        emit(); one client, one topic, and the sinks. Imports nothing of ours.
    palette    what a state MEANS and what it is drawn as. Imports paths only.
    runner     run one script, stream it, relay its events, return its code
    brief      a build's output condensed to emoji and a moving bar. Pure.
    readers    ps / stats / inspect / apps, parsed; the one-minute resource beat
    diagnose   what an inspect payload MEANS; the endpoint and config tables
    report     the retained status payload, and run-with-a-report-either-side
    api        the route table: what may be asked, what may be done
    serve      sockets, routing, the shared execution log, the static client
    cli        argument -> script name; `serve` is one of them
    web/       index.html, manager.css, manager.js. No framework, no CDN.

NOTHING IN THIS PACKAGE IMPORTS A GUI TOOLKIT, and nothing needs a DISPLAY.
Importing it on a headless box must not raise, and `serve` must run there —
that box is where the containers are.

THE PACKAGE DIRECTORY HAS NO COLON IN IT, AND THAT IS THE REASON IT EXISTS HERE.
Every top-level directory in this repository does, and a colon is not a legal
module identifier, so a package under `APK:DOCKERS/` can be imported only
because THIS directory is colon-free and the entry script puts its parent
`DockTor/SRC/` on sys.path. The parent may be renamed or moved — it
was renamed on 2026-09-04 and gained the `SRC/` rung on 2026-09-06 — but do not
rename this one to match its colon-bearing neighbours: a colon is not a legal
module identifier.
"""
