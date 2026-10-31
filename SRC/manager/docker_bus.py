# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""🚪 Docker over the bus, for the discovery engine. DockTor is the only holder
of the Docker socket (Dockers golden rule, law 9), so the engine — which raises
and reaps plugin containers — asks here instead of mounting the socket or a
gate's.

    → APK.audio/System/ContainerManager/docker/request          (not retained)
        {"id": "7", "reply": "<REPLY_BASE>/<client>", "method": "GET",
         "path": "/containers/Plugin-PTP/json"}
    ← <REPLY_BASE>/<client>                                     (not retained)
        {"id": "7", "status": 200, "body": "<the daemon's body>"}

THE OLD APK-Docker-Gate's ALLOW-LIST, UNCHANGED (it was SRC/GATE/src/policy.rs
in DISCOVERY.Engine): inspect, start, stop?t=, kill?signal=, delete?force=&v=
for `^(Plugin-|APK-|apk-)[A-Za-z0-9_.-]+$` names, plus POST /apk/recreate/<n>,
which builds the create body from the inspect THIS process kept when it
executed that container — a requester never sends a body. Anything else is a
403, answered without asking the daemon. The reply topic must sit under
REPLY_BASE, so a request cannot make DockTor publish anywhere else.

OWNS its own MQTT client (bus.py's emit client registers no callbacks and is
for events only). Started by serve() — the long-running process — and by
nothing that exits in a second.
"""

import os
import re
import json
import socket
import threading
import http.client

from .bus import BROKER_HOST, BROKER_PORT, SERVER_NAME, emit

REQUEST_TOPIC = "APK.audio/System/ContainerManager/docker/request"
REPLY_BASE = "APK.audio/System/ContainerManager/docker/reply"
DOCKER_SOCKET = os.environ.get("APK_DOCKER_UPSTREAM", "/var/run/docker.sock")

_NAME = re.compile(r"^(Plugin-|APK-|apk-)[A-Za-z0-9_.-]+$")
_DIGITS = re.compile(r"^[0-9]{1,4}$")
_SIGNAL = re.compile(r"^[A-Z0-9]{1,12}$")
_BOOL = {"true", "false", "1", "0"}


def plugin_name(name):
    """A container the engine's launcher manages, and only those."""
    return len(name) <= 128 and bool(_NAME.match(name))


def _query_ok(query, allowed):
    if not query:
        return True
    for pair in query.split("&"):
        if "=" not in pair:
            return False
        key, value = pair.split("=", 1)
        check = allowed.get(key)
        if check is None or not check(value):
            return False
    return True


def decide(method, target):
    """('forward', keep_name|None) · ('recreate', name) · ('health', None) · ('deny', why)."""
    path, _, query = target.partition("?")
    deny = ("deny", f"{method} {target}: not one of the calls the engine makes")
    if not path.startswith("/"):
        return deny
    seg = path[1:].split("/")
    if method == "GET" and seg == ["apk", "health"] and not query:
        return ("health", None)
    if method == "POST" and len(seg) == 3 and seg[:2] == ["apk", "recreate"] and not query:
        return ("recreate", seg[2]) if plugin_name(seg[2]) else \
            ("deny", f"{method} {target}: not a plugin container name")
    if len(seg) >= 2 and seg[0] == "containers" and not plugin_name(seg[1]):
        return ("deny", f"{method} {target}: not a plugin container name")
    if len(seg) == 3 and seg[0] == "containers":
        verb = seg[2]
        if method == "GET" and verb == "json" and not query:
            return ("forward", None)
        if method == "POST" and verb == "start" and not query:
            return ("forward", None)
        if method == "POST" and verb == "stop" and _query_ok(query, {"t": _DIGITS.match}):
            return ("forward", None)
        if method == "POST" and verb == "kill" and _query_ok(query, {"signal": _SIGNAL.match}):
            return ("forward", None)
    if method == "DELETE" and len(seg) == 2 and seg[0] == "containers" \
            and _query_ok(query, {"force": _BOOL.__contains__, "v": _BOOL.__contains__}):
        return ("forward", seg[1])
    return deny


class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout=10):
        super().__init__("docker", timeout=timeout)
        self._path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._path)
        self.sock = sock


def daemon(method, target, body=None, upstream=None):
    """One call to the daemon: (status, body text) — dechunked by http.client.
    None when the daemon did not answer."""
    try:
        conn = _UnixHTTPConnection(upstream or DOCKER_SOCKET)
        headers = {"Content-Type": "application/json"}
        conn.request(method, target, body=body, headers=headers)
        resp = conn.getresponse()
        text = resp.read().decode("utf-8", "replace")
        conn.close()
        return resp.status, text
    except Exception:
        return None


def create_body_from_inspect(inspect):
    """The create body that rebuilds a container from its inspect: same image,
    command, env, labels, healthcheck, mounts, caps, devices and networks."""
    if not isinstance(inspect, dict) or not isinstance(inspect.get("Config"), dict) \
            or "HostConfig" not in inspect:
        return None
    body = dict(inspect["Config"])
    host = inspect["HostConfig"]
    body["HostConfig"] = host
    mode = (host or {}).get("NetworkMode") or ""
    if not (mode in ("host", "none") or mode.startswith("container:")):
        nets = (inspect.get("NetworkSettings") or {}).get("Networks") or {}
        if nets:
            body["NetworkingConfig"] = {"EndpointsConfig": {
                name: {"Aliases": (ep or {}).get("Aliases")} for name, ep in nets.items()}}
    return body


class DockerBus:
    """Answers one request at a time: (status, body) for a request dict."""

    def __init__(self, upstream=None, kept_dir=None):
        self.upstream = upstream or DOCKER_SOCKET
        self.kept_dir = kept_dir

    def _kept_dir(self):
        if self.kept_dir:
            return self.kept_dir
        explicit = os.environ.get("APK_DOCKER_KEPT_DIR")
        if explicit:
            return explicit
        from .readers import storage_directory
        storage = storage_directory()
        return os.path.join(storage, "docker-kept") if storage else ""

    def _kept_path(self, name):
        folder = self._kept_dir()
        return os.path.join(folder, f"{name}.json") if folder else ""

    def keep(self, name):
        answer = daemon("GET", f"/containers/{name}/json", upstream=self.upstream)
        path = self._kept_path(name)
        if answer and answer[0] == 200 and path:
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(answer[1])
            except OSError as err:
                print(f"⚠️ [DOCKER-BUS] could not keep {name}'s config: {err}")

    def recreate(self, name):
        path = self._kept_path(name)
        try:
            with open(path, encoding="utf-8") as fh:
                inspect = json.load(fh)
        except (OSError, ValueError):
            return 404, json.dumps({"message": f"no kept config for {name}"})
        body = create_body_from_inspect(inspect)
        if body is None:
            return 502, json.dumps({"message": f"the kept config for {name} is not an inspect"})
        created = daemon("POST", f"/containers/create?name={name}", json.dumps(body), self.upstream)
        # 409: it exists already (a second answerer, or a race) — just start it.
        if not created or created[0] not in (201, 409):
            return 502, json.dumps({"message": f"create {name} answered {created}"})
        started = daemon("POST", f"/containers/{name}/start", upstream=self.upstream)
        if started and started[0] in (204, 304):
            print(f"♻️  [DOCKER-BUS] recreated {name} from its kept config")
            return 204, ""
        return 502, json.dumps({"message": f"created {name} but start answered {started}"})

    def answer(self, method, target):
        kind, arg = decide(method, target)
        if kind == "deny":
            print(f"🚫 [DOCKER-BUS] refused {arg}")
            return 403, json.dumps({"message": f"refused by DockTor: {arg}"})
        if kind == "health":
            ok = daemon("GET", "/_ping", upstream=self.upstream)
            return (200, "OK") if ok and ok[0] == 200 else (503, "")
        if kind == "recreate":
            return self.recreate(arg)
        if arg:
            self.keep(arg)
        result = daemon(method, target, upstream=self.upstream)
        return result if result else (502, json.dumps({"message": "the daemon did not answer"}))

    def handle(self, payload):
        """(reply topic, reply payload) for one request payload, or None."""
        try:
            req = json.loads(payload)
            rid, reply = str(req["id"]), str(req["reply"])
            method, path = str(req["method"]), str(req["path"])
        except (ValueError, KeyError, TypeError):
            return None
        if not reply.startswith(REPLY_BASE + "/") or "#" in reply or "+" in reply:
            return None
        status, body = self.answer(method, path)
        return reply, json.dumps({"id": rid, "status": status, "body": body})


def start_docker_bus():
    """Subscribe to REQUEST_TOPIC and answer every request. A thread per
    request: a recreate takes a second, and an inspect must not queue behind it."""
    try:
        import paho.mqtt.client as mqtt
    except Exception:
        print("⚠️ [DOCKER-BUS] no paho: the engine cannot reach Docker")
        return None
    if not os.path.exists(DOCKER_SOCKET):
        print(f"⚠️ [DOCKER-BUS] no {DOCKER_SOCKET}: not answering the engine")
        return None
    bus = DockerBus()
    client_id = f"DockTor_docker_{SERVER_NAME}_{os.getpid()}"
    try:
        client = mqtt.Client(client_id=client_id,
                             callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
    except (AttributeError, TypeError, ValueError):
        client = mqtt.Client(client_id=client_id)

    def on_connect(c, *_args, **_kw):
        c.subscribe(REQUEST_TOPIC, qos=1)

    def work(payload):
        out = bus.handle(payload)
        if out:
            client.publish(out[0], out[1], qos=1, retain=False)

    def on_message(_c, _u, msg):
        threading.Thread(target=work, args=(msg.payload,), daemon=True).start()

    client.on_connect = on_connect
    client.on_message = on_message
    client.reconnect_delay_set(1, 10)
    try:
        client.connect_async(BROKER_HOST, BROKER_PORT, 30)
        client.loop_start()
    except Exception as err:
        print(f"⚠️ [DOCKER-BUS] could not reach the broker: {err}")
        return None
    emit("DOCKER_BUS_SERVING", {"request": REQUEST_TOPIC, "socket": DOCKER_SOCKET})
    return client
