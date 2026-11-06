# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
"""THE BROWSER'S BUS, WATCHED FROM THE BENCH.

2026-11-06: every page on :8080 showed NO BUS for hours while the broker was
healthy, curl got 101 and a node client read 37k messages in 2 s. Chrome sends
every localhost app's cookies with the websocket upgrade; past ~4 KB of headers
the broker's listener hangs up, the portal answers 502, and nothing on the
server side noticed because nothing on the server side dials like a browser.

This does. Every APK_BUS_WATCHDOG_SECONDS (60) it opens the same-origin bus a
page opens (APK_BUS_WATCHDOG_URL, default ws://127.0.0.1:<PORT 8080>/mqtt) with
a browser's headers — Origin, a Chrome User-Agent, permessage-deflate and a
6 KB Cookie (past the broker's ~4 KB; under nginx's 8 KB line limit, as a real
browser's is) — then does an MQTT round trip: CONNECT, SUBSCRIBE to a private
topic, PUBLISH to it, and waits for its own message to come back. Anything
short of the echo is a failure, named by the step that failed.

It barks on DockTor's event stream (and so on the bus, via emit): BUS_WATCHDOG_DOWN
once per outage, again every APK_BUS_WATCHDOG_REPEAT_SECONDS (600) while it
lasts, BUS_WATCHDOG_OK when it is back. The page's own half is apk-bus.js's
watchdog (WEB.Frontend-Assets), which says so on the page itself.

Standard library only: a websocket client in ~60 lines is cheaper than a
dependency in the manager image.
"""
import base64
import os
import socket
import struct
import threading
import time
import urllib.parse

from .bus import emit

INTERVAL = int(os.environ.get("APK_BUS_WATCHDOG_SECONDS", "60") or 60)
REPEAT = int(os.environ.get("APK_BUS_WATCHDOG_REPEAT_SECONDS", "600") or 600)
TIMEOUT = float(os.environ.get("APK_BUS_WATCHDOG_TIMEOUT", "5") or 5)
COOKIE_BYTES = int(os.environ.get("APK_BUS_WATCHDOG_COOKIE_BYTES", "6144") or 6144)
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/154.0.0.0 Safari/537.36 apk-docktor-bus-watchdog")


def default_url():
    return os.environ.get("APK_BUS_WATCHDOG_URL") or \
        f"ws://127.0.0.1:{os.environ.get('PORT', '8080')}/mqtt"


class Fail(Exception):
    """One failed step: `step` is what the operator reads first."""

    def __init__(self, step, detail):
        super().__init__(f"{step}: {detail}")
        self.step, self.detail = step, detail


# ---- MQTT 3.1.1 packets (only what the round trip needs) --------------------

def _rl(n):
    out = bytearray()
    while True:
        b, n = n % 128, n // 128
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _s(text):
    b = text.encode()
    return struct.pack("!H", len(b)) + b


def mqtt_connect(client_id, keepalive=30):
    body = _s("MQTT") + bytes([4, 0x02]) + struct.pack("!H", keepalive) + _s(client_id)
    return bytes([0x10]) + _rl(len(body)) + body


def mqtt_subscribe(pid, topic):
    body = struct.pack("!H", pid) + _s(topic) + bytes([0])
    return bytes([0x82]) + _rl(len(body)) + body


def mqtt_publish(topic, payload):
    body = _s(topic) + payload
    return bytes([0x30]) + _rl(len(body)) + body


MQTT_DISCONNECT = bytes([0xE0, 0])


def mqtt_packets(buf):
    """Split whole packets off the front of buf: ([(type, body)], rest)."""
    out, i = [], 0
    while i + 2 <= len(buf):
        mult, n, j = 1, 0, i + 1
        while True:
            if j >= len(buf):
                return out, buf[i:]
            b = buf[j]
            n += (b & 0x7F) * mult
            mult *= 128
            j += 1
            if not b & 0x80:
                break
        if j + n > len(buf):
            break
        out.append((buf[i] >> 4, bytes(buf[j:j + n])))
        i = j + n
    return out, buf[i:]


# ---- websocket framing --------------------------------------------------------

def ws_frame(payload, opcode=0x2):
    mask = os.urandom(4)
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack("!H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack("!Q", n)
    return head + mask + bytes(b ^ mask[k % 4] for k, b in enumerate(payload))


def ws_frames(buf):
    """Split whole server frames (unmasked) off buf: ([(opcode, payload)], rest)."""
    out = []
    while len(buf) >= 2:
        op, n, i = buf[0] & 0x0F, buf[1] & 0x7F, 2
        if n == 126:
            if len(buf) < 4:
                break
            n, i = struct.unpack("!H", buf[2:4])[0], 4
        elif n == 127:
            if len(buf) < 10:
                break
            n, i = struct.unpack("!Q", buf[2:10])[0], 10
        if buf[1] & 0x80:
            i += 4  # a server never masks; skip it if one does
        if len(buf) < i + n:
            break
        out.append((op, bytes(buf[i:i + n])))
        buf = buf[i + n:]
    return out, buf


def upgrade_request(url, cookie_bytes=COOKIE_BYTES):
    u = urllib.parse.urlsplit(url)
    host = u.netloc
    key = base64.b64encode(os.urandom(16)).decode()
    cookie = "apk_bus_watchdog=" + "x" * max(0, cookie_bytes - 17)
    lines = [
        f"GET {u.path or '/'} HTTP/1.1", f"Host: {host}", "Upgrade: websocket", "Connection: Upgrade",
        f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13", "Sec-WebSocket-Protocol: mqtt",
        "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits",
        f"Origin: http://{host}", f"User-Agent: {UA}", f"Cookie: {cookie}",
    ]
    return ("\r\n".join(lines) + "\r\n\r\n").encode()


# ---- one probe ----------------------------------------------------------------

def probe(url=None, timeout=TIMEOUT, cookie_bytes=COOKIE_BYTES, connect=socket.create_connection):
    """One browser-shaped round trip. Returns seconds taken; raises Fail(step, detail)."""
    url = url or default_url()
    u = urllib.parse.urlsplit(url)
    started = time.monotonic()
    deadline = started + timeout
    try:
        sock = connect((u.hostname, u.port or 80), timeout)
    except OSError as err:
        raise Fail("tcp", f"{u.hostname}:{u.port or 80} {err}")
    try:
        sock.settimeout(timeout)
        sock.sendall(upgrade_request(url, cookie_bytes))
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(4096)
            if not chunk:
                raise Fail("upgrade", "closed before answering")
            head += chunk
        status_line, _, rest = head.partition(b"\r\n")
        if b" 101" not in status_line:
            raise Fail("upgrade", status_line.decode(errors="replace").strip()
                       + f" (headers ~{cookie_bytes // 1024} KB, as a browser sends)")
        buf = bytearray(rest.split(b"\r\n\r\n", 1)[1])
        mbuf = bytearray()
        topic = f"APK.audio/System/Watchdog/Bus/{socket.gethostname()}-{os.getpid()}"
        nonce = os.urandom(8).hex().encode()
        sock.sendall(ws_frame(mqtt_connect(f"apk-docktor-buswatch-{os.getpid()}")))
        step = "connack"
        while True:
            if time.monotonic() > deadline:
                raise Fail(step, f"no answer in {timeout:g} s")
            frames, buf = ws_frames(buf)
            for op, payload in frames:
                if op == 0x8:
                    raise Fail(step, "broker closed the websocket")
                if op in (0x0, 0x2):
                    mbuf += payload
            packets, mbuf = mqtt_packets(mbuf)
            for ptype, body in packets:
                if ptype == 2 and step == "connack":
                    if len(body) < 2 or body[1] != 0:
                        raise Fail("connack", f"refused, code {body[1] if len(body) > 1 else '?'}")
                    step = "suback"
                    sock.sendall(ws_frame(mqtt_subscribe(1, topic)))
                elif ptype == 9 and step == "suback":
                    step = "echo"
                    sock.sendall(ws_frame(mqtt_publish(topic, nonce)))
                elif ptype == 3 and step == "echo" and body.endswith(nonce):
                    try:
                        sock.sendall(ws_frame(MQTT_DISCONNECT))
                    except OSError:
                        pass
                    return time.monotonic() - started
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                raise Fail(step, f"no answer in {timeout:g} s")
            if not chunk:
                raise Fail(step, "connection closed")
            buf += chunk
    except OSError as err:
        raise Fail("socket", str(err))
    finally:
        try:
            sock.close()
        except OSError:
            pass


# ---- the loop -----------------------------------------------------------------

STATE = {"ok": None, "url": None, "since": None, "last": None, "error": None, "step": None, "seconds": None}


def beat(state=STATE, probe_fn=probe, emit_fn=emit, now=time.time, url=None):
    """One check; barks on the edges (and every REPEAT while down)."""
    url = url or default_url()
    state["url"] = url
    try:
        took = probe_fn(url)
    except Fail as f:
        first = state["ok"] is not False
        if first:
            state["since"] = now()
        state.update(ok=False, error=f.detail, step=f.step)
        if first or now() - (state["last"] or 0) >= REPEAT:
            state["last"] = now()
            emit_fn("BUS_WATCHDOG_DOWN", {
                "url": url, "step": f.step, "error": f.detail, "since": state["since"],
                "problem": "broker_unreachable",
                "hint": "A browser cannot reach the bus the way pages dial it. Check Broker-Mosquitto, "
                        "then Storage-Portal's /mqtt location (SRC/nginx.conf) — curl without big headers can pass while browsers fail."})
        return False
    if state["ok"] is False:
        emit_fn("BUS_WATCHDOG_OK", {"url": url, "down_seconds": int(now() - (state["since"] or now())),
                                    "round_trip_ms": int(took * 1000)})
    state.update(ok=True, error=None, step=None, since=None, last=None, seconds=took)
    return True


def start_bus_watchdog(interval=INTERVAL):
    if interval <= 0:
        return None

    def loop():
        time.sleep(20)
        while True:
            try:
                beat()
            except Exception as err:  # never let the watcher die
                emit("BUS_WATCHDOG_ERROR", {"error": str(err)})
            time.sleep(interval)

    t = threading.Thread(target=loop, daemon=True, name="bus-watchdog")
    t.start()
    emit("BUS_WATCHDOG_STARTED", {"interval_seconds": interval, "url": default_url()})
    return t
