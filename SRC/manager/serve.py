# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""🌐 The transport. One stdlib HTTP server over api.py, and the shared log.

OWNS sockets, routing, the SSE log stream and the static files under web/. It
decides nothing about docker: every route is one call into api.py, which is one
call into a file in docker scripts/.
STDLIB ONLY, AS A REQUIREMENT: this is the tool you reach for when the bench is
broken, and a manager that needs pip install first is down when it is wanted.
THE EXECUTION LOG IS SHARED STATE: every line — script stdout, a lifted @EVENT,
the resource sample, a verb someone ran in a terminal against this package —
lands in LOG and is pushed to every subscriber. Two tabs show the same build.
⚠️ SECURITY — READ BEFORE CHANGING THE BIND. This API stops containers,
   rebuilds images, truncates logs and force-kills the bench, with NO
   AUTHENTICATION. The 127.0.0.1 default is the pair to that, exactly as
   allow_anonymous true pairs with a loopback bind in the broker configs here.
   Widening it without an authenticating proxy hands the bench to the network.
GET READS, POST ACTS, enforced here rather than trusted to the client.
"""

import sys
import os
import json
import time
import errno
import queue
import socket
import threading
import urllib.parse
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import api, palette
from .brief import LogBrief
from .bus import add_sink, emit
from .paths import MANAGER_PACKAGE
from .runner import is_error_line

WEB_ROOT = os.path.join(MANAGER_PACKAGE, "web")

# The floor is not a preference: a full scan is four scripts against every
# container and takes a second or two, so below five seconds the server spends
# more time scanning than answering.
MIN_SCAN_SECONDS = 5

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}


class LogStream:
    """The one execution log, and everyone watching it.

    A RING, NOT A FILE: what a person wants after a failed rebuild is the last
    few hundred lines. Four thousand records is about two full rebuilds.
    A SUBSCRIBER THAT STOPS READING IS DROPPED, not waited for — a full bounded
    queue means the socket is gone or the tab is frozen, and the alternative is
    a build that blocks on a browser.
    """

    RING = 4000
    QUEUE = 2000

    def __init__(self):
        self._records = deque(maxlen=self.RING)
        self._subscribers = []
        self._lock = threading.Lock()
        self._seq = 0

    def publish(self, kind, text, tone=None):
        """kind is `line`, `bar`, `bardone` or `clear`. Returns the record."""
        with self._lock:
            self._seq += 1
            record = {"seq": self._seq, "at": time.time(), "kind": kind,
                      "text": text,
                      "tone": tone or ("hot" if is_error_line(text) else None)}
            if kind == "clear":
                self._records.clear()
            self._records.append(record)
            dead = []
            for subscriber in self._subscribers:
                try:
                    subscriber.put_nowait(record)
                except queue.Full:
                    dead.append(subscriber)
            for subscriber in dead:
                self._subscribers.remove(subscriber)
        return record

    def subscribe(self, replay=400):
        """A queue, primed with the tail so a tab opened mid-build is not blank."""
        subscriber = queue.Queue(maxsize=self.QUEUE)
        with self._lock:
            for record in list(self._records)[-replay:]:
                try:
                    subscriber.put_nowait(record)
                except queue.Full:
                    break
            self._subscribers.append(subscriber)
        return subscriber

    def unsubscribe(self, subscriber):
        with self._lock:
            if subscriber in self._subscribers:
                self._subscribers.remove(subscriber)

    def tail(self, count=400):
        with self._lock:
            return list(self._records)[-count:]


LOG = LogStream()


# Where an event detail stops being a line and starts being a document.
# RESOURCES carries a full stats row per container — 2.4 KB with nine of them,
# once a minute — and pasted whole it is the only thing in the log. The bus
# still carries every byte; this is the READING of it.
EVENT_DETAIL_LIMIT = 200


def _bus_sink(message):
    """Every bus event on the shared log, in the house format.

    Registered once at import, so an @EVENT lifted off a script stdout reaches
    an open browser without the runner knowing a browser exists.
    LONG PAYLOADS ARE ELIDED, NOT DROPPED, and the count is what survives: what
    a person reads a resource sample for is that it HAPPENED and how many
    containers it covered.
    """
    details = message.get("details") or {}
    text = json.dumps(details)
    if len(text) > EVENT_DETAIL_LIMIT:
        keys = ", ".join(f"{k}={details[k]}" for k in details
                         if isinstance(details[k], (int, float, str))
                         and len(str(details[k])) < 40)
        # AN EVENT WHOSE PAYLOAD IS ALL LISTS SURVIVED THIS AS `{}`. The filter
        # above keeps scalars, which is right for RESOURCES; STACKS_STRANDED
        # carries three lists and no scalar, so the one line announcing three
        # unrestorable stacks read `STACKS_STRANDED: {}`. Naming each list by
        # its LENGTH is the same reading applied to the same shape.
        if not keys:
            keys = ", ".join(f"{k}×{len(v)}" for k, v in details.items()
                             if isinstance(v, (list, tuple, dict)))
        text = f"{{{keys}}} …{len(text)} bytes on the bus"
    LOG.publish("line", f"\U0001F4E1 {message['event']}: {text}")


add_sink(_bus_sink)


class StreamedRun:
    """One action output, condensed, onto the shared log.

    brief.LogBrief is the condenser the Tkinter log pane used and it is pure —
    one raw line in, zero or more display events out — so it is reused verbatim.
    A docker build says the same thing four thousand times.
    """

    def __init__(self):
        self.brief = LogBrief()

    def __call__(self, chunk):
        for raw in chunk.splitlines():
            for kind, text in self.brief.feed(raw):
                LOG.publish(kind, text)


class ManagerHandler(BaseHTTPRequestHandler):
    server_version = "DockTor/1.0"
    protocol_version = "HTTP/1.1"

    # ------------------------------------------------------------------
    # Replies. A CLIENT THAT LEFT IS NOT A FAILURE, and that is all this flag
    # records: /api/containers is a full scan and takes a second or two, so a
    # tab reloaded or closed inside that window aborts the fetch and the answer
    # lands on a socket nobody holds.
    # ------------------------------------------------------------------
    client_gone = False

    def _send(self, code, body, content_type="application/json; charset=utf-8"):
        payload = body if isinstance(body, bytes) else body.encode("utf-8")
        # THE SOCKET WRITE IS CAUGHT HERE AND NOWHERE ELSE, so a broken pipe
        # can never reach a route handler except-clause. Two things went wrong
        # when it could: it was emitted as API_READ_FAILED, so a closed tab
        # published a container-management fault to every subscriber; and the
        # recovery wrote a SECOND response, the 500, to the same dead socket —
        # raising again, or appending a 500 after a 200 on a keep-alive
        # connection where the next request reads it as its own answer.
        # end_headers writes too (HTTP/1.1 buffers the status line and headers
        # and flushes there), so the guard starts at send_response.
        # NOTHING ELSE IS SWALLOWED: a broken pipe from a docker subprocess
        # three levels down still reaches the handler.
        try:
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            # This server holds no cookie and no session, so a stale answer is
            # all a cache could contribute. The grid is a live reading.
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            self.client_gone = True
            # This connection carries no more requests; without it the handler
            # loop reads the next one off a socket that has gone.
            self.close_connection = True

    def _json(self, payload, code=200):
        self._send(code, json.dumps(payload, default=str))

    def _error(self, code, message):
        # A refusal is worth nothing to a client that is no longer listening,
        # and attempting it is what desynchronised the stream above.
        if self.client_gone:
            return
        self._json({"ok": False, "error": message}, code=code)

    def log_message(self, fmt, *args):
        """Silence. The execution log is the record; an access log on stderr is
        a second one nobody reads, at a line per two-second scan."""

    # ------------------------------------------------------------------
    # GET — reads only. Nothing reachable here changes the bench.
    # ------------------------------------------------------------------
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        route = parsed.path.rstrip("/") or "/"
        params = urllib.parse.parse_qs(parsed.query)

        if not route.startswith("/api"):
            return self._static(route)

        try:
            if route == "/api/health":
                return self._json(api.health())
            if route == "/api/routes":
                return self._json(api.routes())
            if route == "/api/palette":
                return self._json(palette.as_json())
            if route == "/api/actions":
                return self._json(api.action_table())
            if route == "/api/containers":
                with_apps = params.get("apps", ["1"])[0] != "0"
                return self._json(api.snapshot(quiet=True, with_apps=with_apps))
            if route == "/api/stacks":
                return self._json(api.stacks())
            if route == "/api/staleness":
                return self._json(api.staleness())
            if route == "/api/resources":
                return self._json(api.resources(quiet=True))
            if route == "/api/endpoints":
                return self._json(api.endpoints(quiet=True))
            if route == "/api/log":
                return self._json({"records": LOG.tail(int(params.get("n", ["400"])[0]))})
            if route == "/api/stream":
                return self._stream()
            if route.startswith("/api/container/"):
                name = urllib.parse.unquote(route[len("/api/container/"):])
                detail = api.container_detail(name, quiet=params.get("live", ["0"])[0] == "1")
                if detail is None:
                    return self._error(404, f"docker does not know a container named {name}.")
                return self._json(detail)
            if route.startswith("/api/surface/"):
                name = urllib.parse.unquote(route[len("/api/surface/"):])
                return self._json(api.surface(name))
            if route.startswith("/api/config-script/"):
                name = urllib.parse.unquote(route[len("/api/config-script/"):])
                return self._json(api.config_script(name))
        except Exception as err:                            # pragma: no cover
            # _send has already absorbed a departed client, so anything here
            # failed to READ the bench rather than to answer it.
            if not self.client_gone:
                emit("API_READ_FAILED", {"route": route, "error": str(err)})
            return self._error(500, str(err))

        # Names what would have been accepted, off the one table, so a refusal
        # is a route table and not just a rejection.
        return self._error(404, "No such route: %s. This manager answers: %s"
                           % (route, ", ".join(row["path"] for row in api.ROUTES
                                               if row["method"] == "GET")))

    # ------------------------------------------------------------------
    # POST — the verbs. Every one of them is a file in `docker scripts/`.
    # ------------------------------------------------------------------
    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        route = parsed.path.rstrip("/") or "/"
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            return self._error(400, "Body was not JSON.")

        if route == "/api/broadcast":
            return self._json(api.broadcast(say=lambda text: LOG.publish("line", text)))

        if route == "/api/chat":
            result = api.chat(body.get("message"))
            if result.get("ok"):
                LOG.publish("line", f"\U0001F4AC [chat] {body.get('message')}")
            return self._json(result)

        if route == "/api/log/clear":
            LOG.publish("clear", "")
            return self._json({"ok": True})

        if route.startswith("/api/action/"):
            key = urllib.parse.unquote(route[len("/api/action/"):])
            container = body.get("container")
            # THE THIRD SCOPE: a verb aimed at ONE STACK names the directory
            # under APK:DOCKERS/, and `scope` tells api.run_action which table
            # the name belongs to. `container` wins when a client sends both —
            # it is narrower, and a request naming both has contradicted itself.
            stack = None if container else body.get("stack")
            target = container or stack
            extra = [str(a) for a in (body.get("args") or [])]
            table = (api.CONTAINER_ACTIONS if container
                     else api.STACK_ACTIONS if stack else api.ACTIONS)
            if key not in table:
                return self._error(404, f"No such action: {key}")
            LOG.publish("line", f"⚡ {table[key]['label']}"
                                + (f" — {target}" if target else "") + "…")
            stream = StreamedRun()
            exit_code, closing = api.run_action(key, name=target, extra=extra,
                                                on_line=stream,
                                                scope="stack" if stack else "container")
            if closing:
                LOG.publish("line", closing)
            return self._json({"ok": exit_code == 0, "exit_code": exit_code,
                               "message": closing}, code=200 if exit_code == 0 else 200)

        return self._error(404, "No such route: %s. This manager accepts POST at: %s"
                           % (route, ", ".join(row["path"] for row in api.ROUTES
                                               if row["method"] == "POST")))

    # ------------------------------------------------------------------
    # The log stream.
    # ------------------------------------------------------------------
    def _stream(self):
        """Server-Sent Events. One connection per tab, held open.

        A KEEPALIVE COMMENT EVERY 15 SECONDS: an idle bench is the normal case
        and a proxy or a sleeping laptop drops a silent connection. Two bytes
        EventSource ignores.
        """
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        subscriber = LOG.subscribe()
        try:
            while True:
                try:
                    record = subscriber.get(timeout=15)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    continue
                self.wfile.write(f"data: {json.dumps(record)}\n\n".encode("utf-8"))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            LOG.unsubscribe(subscriber)

    # ------------------------------------------------------------------
    # The client. Four files, served from beside this module.
    # ------------------------------------------------------------------
    def _static(self, route):
        relative = "index.html" if route == "/" else route.lstrip("/")
        # The client is four files in one directory and no request has reason
        # to leave it. realpath BEFORE the prefix test, so `..` and a symlink
        # are both refused rather than only the first.
        resolved = os.path.realpath(os.path.join(WEB_ROOT, relative))
        if not resolved.startswith(os.path.realpath(WEB_ROOT) + os.sep):
            return self._error(403, "Outside the client directory.")
        if not os.path.isfile(resolved):
            return self._error(404, f"No such file: {relative}")
        content_type = CONTENT_TYPES.get(os.path.splitext(resolved)[1],
                                         "application/octet-stream")
        with open(resolved, "rb") as handle:
            self._send(200, handle.read(), content_type)


class ManagerServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        """A departed client is not an error, on the read side either.

        _send absorbs the write that breaks mid-answer; this is the other half,
        reached when the answer fitted the socket buffer and left cleanly, the
        connection stayed open, and the next read finds the peer gone.
        socketserver default prints a full traceback per occurrence — one every
        few seconds from every tab ever closed.
        ONLY THE DISCONNECT FAMILY: anything else is a real fault in a handler
        thread and still prints.
        """
        if not isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            super().handle_error(request, client_address)
    # Without this a restart inside the TIME_WAIT window fails with "Address
    # already in use" on a port nothing is listening on, which sends a person
    # hunting a process that is gone. It is also what makes EADDRINUSE below
    # MEAN something: with the socket reused, only a live listener produces it.
    allow_reuse_address = True


def probe_manager(bind, port, timeout=1.5):
    """Ask whoever holds the port whether they are a manager.

    Returns the incumbent /api/health payload, or None (refused connection,
    timeout, non-manager, unparseable). Never raises: this runs on the failure
    path of a bind.
    """
    # 0.0.0.0 is where it LISTENS, not an address to call. Loopback is the one
    # address every bind this server accepts can be reached on.
    host = "127.0.0.1" if bind in ("0.0.0.0", "::", "") else bind
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/api/health",
                                    timeout=timeout) as answer:
            payload = json.loads(answer.read(65536).decode("utf-8", "replace"))
    except Exception:
        return None
    return payload if isinstance(payload, dict) and payload.get("actions") else None


# WHETHER THERE IS A HUMAN AND A SCREEN. Used only to decide whether a deferral
# raises the incumbent page itself. All three must hold: no browser inside a
# container, no tty under systemd or compose, no display on a headless bench.
def _can_raise_a_browser():
    if os.path.exists("/.dockerenv"):
        return False
    if not sys.stdout.isatty():
        return False
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


# HOW LONG THE CONTAINER HOLDS THE DOOR AND HOW OFTEN IT SAYS SO. Five seconds
# is the cadence docker was already retrying at when this was a restart loop;
# the difference is that one process does the waiting, so the reason is written
# once and the retries are a line a minute rather than a fresh container.
PORT_WAIT_SECONDS = 5
PORT_WAIT_QUIET_EVERY = 12

# The third answer _defer_to_incumbent can give, beside the two exit codes:
# "this process is the one that has to own this socket, so wait for it".
WAIT_FOR_PORT = "wait"


def _describe(health):
    """`a container` / `a terminal manager (pid 462769 on APK-Shop)`.

    Reads `instance` from a /api/health payload. A manager older than that key
    answers `an unidentified manager`, the honest reading of a payload that
    does not say.
    """
    instance = (health or {}).get("instance")
    if not isinstance(instance, dict):
        return "an unidentified manager"
    where = "a containerised manager" if instance.get("containerised") else "a terminal manager"
    pid, host = instance.get("pid"), instance.get("hostname")
    return f"{where} (pid {pid} on {host})" if pid and host else where


# A SECOND MANAGER DEFERS TO THE FIRST — UNLESS IT IS THE CONTAINER, the one
# process here that has to own the socket.
# A person launching from a terminal is asking to USE a manager, not to own the
# port, and a refused bind reaching them as a nine-frame OSError reads as a
# broken tool.
# ⚠️ IT IS NEVER RIGHT INSIDE THE CONTAINER, and it used to happen: deferring
#    returns 0, restart: unless-stopped restarts a container that exits 0, and
#    the polite answer became an unbounded restart loop (9 restarts and
#    climbing) while the dashboard drew DockTor as "1 declared, none
#    present" and the remount log said it succeeded. Both were true: compose
#    created the container every time and it stood down every time, because a
#    terminal manager held 127.0.0.1:8765.
def _defer_to_incumbent(bind, port, url, open_browser, err):
    """The port was taken. Decide whether that satisfied the request.

    Returns the exit code — 0 when a manager already answers and this process
    was free to stand down, 1 when a non-manager holds the port — or
    WAIT_FOR_PORT when this is the containerised manager, which must not exit.
    """
    health = probe_manager(bind, port)
    incumbent = _describe(health) if health else "something that is not a DockTor"

    # THE CONTAINER WAITS FOR ANY HOLDER, not only another manager: its port is
    # APK_MANAGER_PORT in a compose file, so "serve elsewhere: --port N+1" is
    # advice it cannot take, and exiting lands on restart: unless-stopped either
    # way.
    if api.INSTANCE["containerised"]:
        emit("MANAGER_PORT_HELD_AGAINST_CONTAINER",
             {"bind": bind, "port": port, "error": str(err),
              "incumbent": (health or {}).get("instance")})
        print(f"⛔ {port} on {bind} is held by {incumbent}, and this manager is "
              f"the container.")
        print("   The container is the one that is supposed to own this socket, so it")
        print("   will WAIT here rather than stand down — standing down exits 0, and")
        print("   `restart: unless-stopped` turns that into a restart loop nobody sees.")
        print(f"   Free the port and this one takes it within {PORT_WAIT_SECONDS}s. Until")
        print("   then this container is UNHEALTHY, which is the truth: it is not serving.")
        return WAIT_FOR_PORT

    if health is None:
        emit("MANAGER_PORT_TAKEN", {"bind": bind, "port": port, "error": str(err)})
        print(f"⛔ Port {port} on {bind} is held by {incumbent}.")
        print(f"   {err}")
        print(f"   Serve elsewhere:  --port {port + 1}")
        return 1

    # WHERE it is serving from used to be the whole answer to "why is one
    # already up", on the reasoning that a foreign repository root means the
    # incumbent is the container. That could not be right: the compose file
    # binds the checkout at its host path on both sides, so the roots are equal
    # by construction. `instance` separates them; the root still answers "which
    # checkout", which is a real question on a machine with two.
    root = health.get("repository_root") or "?"

    emit("MANAGER_ALREADY_SERVING", {"bind": bind, "port": port, "url": url,
                                     "repository_root": root,
                                     "incumbent": health.get("instance"),
                                     "host": socket.gethostname()})
    print(f"🐳 {incumbent.capitalize()} is already serving — {url}")
    print(f"   Its repository root is {root}.")

    # THE URL IS THE WHOLE ANSWER HERE, SO OPEN IT: the socket is held by a
    # manager already doing the job, and a person who typed the launcher asked
    # to USE one. Printing an address and stopping made them copy it into a
    # browser every time, which is why --open is not required on this branch.
    if open_browser or _can_raise_a_browser():
        import webbrowser
        webbrowser.open_new_tab(url)
        print(f"   Raised in a browser. --port {port + 1} runs a second one.")
    else:
        print("   Nothing to do. Add --open to raise it in a browser, or "
              f"--port {port + 1} to run a second one.")
    return 0


def _bind_or_wait(bind, port, url, open_browser):
    """Bind the socket, waiting out a port another manager holds.

    Returns a bound ManagerServer, or an exit code when this process is allowed
    to stand down. The loop is here rather than in docker restart policy
    because docker destroys the container between attempts, and a reason
    printed by a container that no longer exists is a reason nobody reads.
    """
    attempt = 0
    while True:
        try:
            return ManagerServer((bind, port), ManagerHandler)
        except OSError as err:
            if err.errno != errno.EADDRINUSE:
                raise
            if attempt == 0:
                outcome = _defer_to_incumbent(bind, port, url, open_browser, err)
                if outcome is not WAIT_FOR_PORT:
                    return outcome
            elif attempt % PORT_WAIT_QUIET_EVERY == 0:
                # Once a minute, not every five seconds: the point of moving
                # this loop in-process was to stop it filling the log.
                print(f"   still waiting for {bind}:{port} — "
                      f"{attempt * PORT_WAIT_SECONDS}s")
            attempt += 1
            time.sleep(PORT_WAIT_SECONDS)


def serve(bind="127.0.0.1", port=8765, open_browser=False):
    """Run the manager API and its client until interrupted.

    A TAKEN PORT IS NOT AUTOMATICALLY A FAULT, and what it is depends on who
    this process is: a terminal manager stands down and returns 0 when another
    already answers; the CONTAINERISED manager waits for the socket instead.
    THE RESOURCE SAMPLER IS STARTED HERE — the once-a-minute beat that publishes
    a full stats sample belongs to whichever process is the long-running one.
    """
    from .readers import start_resource_sampler

    url = f"http://{'localhost' if bind in ('0.0.0.0', '127.0.0.1', '::') else bind}:{port}/"
    httpd = _bind_or_wait(bind, port, url, open_browser)
    if isinstance(httpd, int):
        return httpd
    emit("MANAGER_SERVING", {"bind": bind, "port": port, "url": url,
                             "host": socket.gethostname()})
    LOG.publish("line", f"\U0001F310 DockTor API on {url}")
    if bind not in ("127.0.0.1", "localhost", "::1"):
        LOG.publish("line", "⚠️ Bound beyond loopback. This API has no "
                            "authentication and can stop and rebuild the bench — "
                            "put an authenticating proxy in front of it.")
    start_resource_sampler()

    if open_browser:
        # Opt-in, and never in a container: there is no browser there, and
        # asking for one is how a service exits two seconds after it starts.
        import webbrowser
        threading.Thread(target=lambda: (time.sleep(0.4), webbrowser.open_new_tab(url)),
                         daemon=True).start()

    print(f"🐳 APK.audio DockTor — {url}")
    print("   Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        emit("MANAGER_STOPPED", {"bind": bind, "port": port})
        httpd.server_close()
    return 0
