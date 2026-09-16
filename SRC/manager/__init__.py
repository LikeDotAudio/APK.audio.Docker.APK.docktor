# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""🐳 APK.audio DockTor — the API and the BUS. Not the docker.

An HTTP API over the ecosystem containers, a browser client served from the
same origin, and a --cli mode of the same verbs.
OWNS: the API (every question, as JSON, over HTTP) · the client (three files
under web/, no framework, no build step) · the bus (everything that happens is
announced on APK.audio/System/ContainerManager as it happens) · running one
script from the collection and reading what it prints.
DOES NOT OWN, AND MUST NOT REACQUIRE: every docker verb lives in
`APK:PODS/Docktor/SRC/docker scripts/`, one executable file each, listed in
that folder _common.sh header. No compose command, no docker ps format string,
no port, no container name.

    runner.run_management_script(name, args, on_line_callback) -> (exit_code, text)

is the ONLY way out of this process. The exit code is half its return value on
purpose: the streamer it replaces threw it away, and the GUI printed a green
tick over a rebuild whose every compose call had failed.
⚠️ THERE IS NO `gui/` AND THERE MUST NOT BE ONE AGAIN. It was eight modules and
   2,850 lines that each imported tkinter: one screen, one process, a DISPLAY
   requirement so it could not run where the containers run, and every table it
   held inside a widget-building method, so none could be tested.
THE @EVENT PROTOCOL: a script holds no broker connection, so it writes
`@EVENT NAME {json}` on stdout and runner.relay_event_line() puts it on the bus
while the same line goes to the screen. One thing said once — terminal, bus, and
every browser tab, since serve.py registers a bus sink.
THE MODULE MAP, deepest first; each imports only from the ones above it:
    paths      where everything is; the brand accent
    bus        emit(); one client, one topic, the sinks. Imports nothing of ours
    palette    what a state MEANS and how it is drawn. Imports paths only
    runner     run one script, stream it, relay its events, return its code
    brief      a build output condensed to emoji and a moving bar. Pure
    readers    ps / stats / inspect / apps, parsed; the resource beat
    diagnose   what an inspect payload MEANS; the endpoint and config tables
    report     the retained status payload, and run-with-a-report-either-side
    api        the route table: what may be asked, what may be done
    serve      sockets, routing, the shared execution log, the static client
    cli        argument -> script name; `serve` is one of them
    web/       index.html, manager.css, manager.js. No framework, no CDN
NOTHING HERE IMPORTS A GUI TOOLKIT and nothing needs a DISPLAY: importing on a
headless box must not raise, and `serve` must run there — that box is where the
containers are.
⚠️ THE PACKAGE DIRECTORY HAS NO COLON IN IT, which is why it exists here: every
   top-level directory in this repository does, a colon is not a legal module
   identifier, and the entry script puts this colon-free parent on sys.path. Do
   not rename it to match its neighbours.
"""
