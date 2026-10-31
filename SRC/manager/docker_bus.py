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
executed that container. Anything else is a 403, answered without asking the
daemon.

THE INSTRUMENT LAUNCHER'S THREE (2026-10-30, NODE.BareMetal BM-11: the node
holds no socket any more and asks here, as apkaudio-baremetal-launcher):
  GET  /containers/json?all=<bool>&filters={"label":["apk.audio.role=instrument"]}
       — that filter and no other, re-encoded by DockTor before forwarding
  GET  /images/<instrument image>/json — only the instrument image(s)
  POST /apk/instrument/<name> with "body": the create document — the ONE call
       that carries a body, and it is checked field by field (instrument_problems)
       before /containers/create is asked: `^apk-` name, the instrument image,
       host networking, the instrument role label, binds only under the
       INSTRUMENTS and PLUGINS trees, and no other HostConfig key at all (no
       Privileged, CapAdd, Devices, PidMode…). It may not claim a compose or
       `apk.audio.protected` label, so it can never pass for Broker-Mosquitto
       or any stack container. The inspect is kept, so /apk/recreate works. The reply topic must sit under
REPLY_BASE, so a request cannot make DockTor publish anywhere else.

OWNS its own MQTT session (bus.py's emit client registers no callbacks and is
for events only), built by bus.new_client — one constructor for the package —
under its own broker identity (CREDENTIAL_PREFIX below). Started by serve() — the long-running process — and by
nothing that exits in a second.
"""

import os
import re
import json
import socket
import threading
import http.client
import urllib.parse

from .bus import BROKER_HOST, BROKER_PORT, SERVER_NAME, emit, new_client, credentials

from .bus import CONTRACT_ROOT, contract_topic

# THE CONTRACTS' FAMILIES (containerManagerDockerRequest / …Reply), NOT
# bus.TOPIC_ROOT: TOPIC_ROOT is an operator override for the event tree, and the
# engine spells this pair as a wire constant (DISCOVERY.Engine
# launcher/docker/bus.rs), so it must not move with it.
REQUEST_TOPIC = contract_topic("containerManagerDockerRequest",
                               f"{CONTRACT_ROOT}/System/ContainerManager/docker/request")
REPLY_BASE = contract_topic("containerManagerDockerReply",
                            f"{CONTRACT_ROOT}/System/ContainerManager/docker/reply/_",
                            client="_")[:-2]
# WHO MAY ASK (2026-10-30 audit, DockTor #2). MQTT 3.1.1 does not tell a
# subscriber who published, so the line is drawn AT THE BROKER: under
# DATABUS.Broker.MQTT SRC/acl.local only apkaudio-docker-engine may publish
# REQUEST_TOPIC and only apkaudio-docktor may hear it or write under REPLY_BASE.
# This client connects as that identity from these two variables; unset, it
# connects anonymously, which works only on a broker without the operator ACL
# and is said out loud at start (DOCKER_BUS_SERVING "authenticated": false).
CREDENTIAL_PREFIX = "APK_DOCKTOR_MQTT"
DOCKER_SOCKET = os.environ.get("APK_DOCKER_UPSTREAM", "/var/run/docker.sock")

_NAME = re.compile(r"^(Plugin-|APK-|apk-)[A-Za-z0-9_.-]+$")
_INSTRUMENT_NAME = re.compile(r"^apk-[a-z0-9_.-]+$")
INSTRUMENT_LABEL = ("apk.audio.role", "instrument")
INSTRUMENT_FILTER = {"label": ["apk.audio.role=instrument"]}
_RESTART = {"no", "unless-stopped", "always", "on-failure"}
_CREATE_KEYS = {"Image", "Env", "Labels", "Cmd", "HostConfig"}
_HOST_KEYS = {"NetworkMode", "RestartPolicy", "Mounts", "Binds"}
_MOUNT_KEYS = {"Type", "Source", "Target", "ReadOnly"}
# Labels an instrument may not carry: compose's own (it would pass for a stack
# container, the broker's included) and the protected marker DockTor's
# scripts leave alone.
_FORBIDDEN_LABEL_PREFIXES = ("com.docker.compose.", "apk.audio.protected")


def instrument_images():
    """The image(s) an instrument container may run: APK_INSTRUMENT_IMAGE
    (comma-separated), else apk-plugins:local — the launcher's own default."""
    raw = os.environ.get("APK_INSTRUMENT_IMAGE") or "apk-plugins:local"
    return {part.strip() for part in raw.split(",") if part.strip()}


def instrument_bind_roots():
    """Host directories an instrument may bind from: APK_INSTRUMENT_BIND_ROOTS
    (newline- or `;`-separated, because these paths may hold colons), else the
    checkout's PODS/POD.THICK/INSTRUMENTS and PODS/POD.THICK/PLUGINS under
    APKAUDIO_REPO (the host path the manager is bound at)."""
    raw = os.environ.get("APK_INSTRUMENT_BIND_ROOTS")
    if raw:
        roots = [r.strip() for r in re.split(r"[;\n]", raw) if r.strip()]
    else:
        repo = os.environ.get("APKAUDIO_REPO")
        if not repo:
            from .paths import REPOSITORY_ROOT
            repo = REPOSITORY_ROOT
        roots = [os.path.join(repo, "PODS", "POD.THICK", "INSTRUMENTS"),
                 os.path.join(repo, "PODS", "POD.THICK", "PLUGINS")]
    return [os.path.normpath(r) for r in roots if os.path.isabs(r)]


def _under(path, roots):
    if not isinstance(path, str) or not os.path.isabs(path) or "\x00" in path:
        return False
    if ".." in path.split("/"):
        return False
    norm = os.path.normpath(path)
    return any(norm == root or norm.startswith(root.rstrip("/") + "/") for root in roots)


def _target_ok(target):
    return (isinstance(target, str) and os.path.isabs(target) and ".." not in target.split("/")
            and "\x00" not in target and os.path.normpath(target) not in ("/", "/var/run/docker.sock"))


def instrument_problems(name, body):
    """Every reason `body` may not become instrument container `name` ([] = ok)."""
    out = []
    if not (isinstance(name, str) and len(name) <= 128 and _INSTRUMENT_NAME.match(name)):
        out.append("name must match ^apk-[a-z0-9_.-]+$")
    if not isinstance(body, dict):
        return out + ["body must be an object"]
    extra = set(body) - _CREATE_KEYS
    if extra:
        out.append(f"keys not allowed: {sorted(extra)}")
    if body.get("Image") not in instrument_images():
        out.append(f"Image must be one of {sorted(instrument_images())}")
    env = body.get("Env", [])
    if not (isinstance(env, list) and all(isinstance(e, str) and "=" in e for e in env)):
        out.append("Env must be a list of KEY=value strings")
    cmd = body.get("Cmd")
    if cmd is not None and not (isinstance(cmd, list) and all(isinstance(c, str) for c in cmd)):
        out.append("Cmd must be a list of strings")
    labels = body.get("Labels")
    if not (isinstance(labels, dict) and all(isinstance(k, str) and isinstance(v, str)
                                              for k, v in labels.items())):
        out.append("Labels must be an object of strings")
        labels = {}
    if labels.get(INSTRUMENT_LABEL[0]) != INSTRUMENT_LABEL[1]:
        out.append("Labels must carry apk.audio.role=instrument")
    bad = sorted(k for k in labels if k.startswith(_FORBIDDEN_LABEL_PREFIXES))
    if bad:
        out.append(f"labels not allowed: {bad}")
    host = body.get("HostConfig")
    if not isinstance(host, dict):
        return out + ["HostConfig must be an object"]
    extra = set(host) - _HOST_KEYS
    if extra:
        out.append(f"HostConfig keys not allowed: {sorted(extra)}")
    if host.get("NetworkMode") != "host":
        out.append("NetworkMode must be host")
    restart = host.get("RestartPolicy", {"Name": "no"})
    if not (isinstance(restart, dict) and set(restart) <= {"Name", "MaximumRetryCount"}
            and restart.get("Name") in _RESTART):
        out.append("RestartPolicy not allowed")
    roots = instrument_bind_roots()
    mounts = host.get("Mounts", [])
    if not isinstance(mounts, list):
        out.append("Mounts must be a list")
        mounts = []
    for i, mount in enumerate(mounts):
        if not (isinstance(mount, dict) and set(mount) <= _MOUNT_KEYS and mount.get("Type") == "bind"
                and _under(mount.get("Source"), roots) and _target_ok(mount.get("Target"))
                and isinstance(mount.get("ReadOnly", False), bool)):
            out.append(f"Mounts[{i}] must be a bind from under {roots}")
    binds = host.get("Binds", [])
    if not isinstance(binds, list):
        out.append("Binds must be a list")
        binds = []
    for i, bind in enumerate(binds):
        # src:dst[:ro|rw] — split from the RIGHT, since a source may hold colons.
        parts = bind.rsplit(":", 2) if isinstance(bind, str) else []
        if len(parts) == 3 and parts[2] not in ("ro", "rw"):
            parts = bind.rsplit(":", 1)
        src, dst = (parts[0], parts[1]) if len(parts) >= 2 else (None, None)
        if not (_under(src, roots) and _target_ok(dst)):
            out.append(f"Binds[{i}] must be a bind from under {roots}")
    return out
_DIGITS = re.compile(r"^[0-9]{1,4}$")
_SIGNAL = re.compile(r"^[A-Z0-9]{1,12}$")
_BOOL = {"true", "false", "1", "0"}


def plugin_name(name):
    """A container the engine's launcher manages, and only those."""
    return len(name) <= 128 and bool(_NAME.match(name))


def _instrument_list_query(query):
    """all=<bool> and filters = exactly the instrument label filter, nothing else."""
    try:
        pairs = urllib.parse.parse_qs(query, keep_blank_values=True, strict_parsing=True)
    except ValueError:
        return False
    if set(pairs) - {"all", "filters"} or "filters" not in pairs:
        return False
    if any(len(v) != 1 for v in pairs.values()):
        return False
    if "all" in pairs and pairs["all"][0] not in _BOOL:
        return False
    try:
        return json.loads(pairs["filters"][0]) == INSTRUMENT_FILTER
    except ValueError:
        return False


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
    """('forward', keep_name|None) · ('recreate', name) · ('health', None) ·
    ('list', None) · ('instrument', name) · ('deny', why)."""
    path, _, query = target.partition("?")
    deny = ("deny", f"{method} {target}: not one of the calls the engine makes")
    if not path.startswith("/"):
        return deny
    seg = path[1:].split("/")
    # THE INSTRUMENT LAUNCHER'S THREE (module docstring).
    if method == "GET" and seg == ["containers", "json"]:
        return ("list", None) if _instrument_list_query(query) else \
            ("deny", f"{method} {target}: only the instrument-label list is answered")
    if method == "GET" and len(seg) == 3 and seg[0] == "images" and seg[2] == "json" and not query:
        image = urllib.parse.unquote(seg[1])
        return ("forward", None) if image in instrument_images() else \
            ("deny", f"{method} {target}: not the instrument image")
    if method == "POST" and len(seg) == 3 and seg[:2] == ["apk", "instrument"] and not query:
        return ("instrument", seg[2])
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

    def instrument(self, name, body):
        """POST /apk/instrument/<name>: create one instrument container, checked."""
        problems = instrument_problems(name, body)
        if problems:
            print(f"🚫 [DOCKER-BUS] refused instrument {name}: {'; '.join(problems)}")
            return 403, json.dumps({"message": f"refused by DockTor: {'; '.join(problems)}"})
        created = daemon("POST", f"/containers/create?name={name}", json.dumps(body), self.upstream)
        if not created:
            return 502, json.dumps({"message": "the daemon did not answer"})
        if created[0] == 201:
            self.keep(name)
            print(f"🎛️  [DOCKER-BUS] created instrument {name}")
        return created

    def list_instruments(self, target):
        """The instrument list, re-encoded here: only the instrument filter goes out."""
        _path, _, query = target.partition("?")
        pairs = urllib.parse.parse_qs(query)
        everything = pairs.get("all", ["0"])[0] in ("1", "true")
        canonical = (f"/containers/json?all={'1' if everything else '0'}&filters="
                     + urllib.parse.quote(json.dumps(INSTRUMENT_FILTER)))
        result = daemon("GET", canonical, upstream=self.upstream)
        return result if result else (502, json.dumps({"message": "the daemon did not answer"}))

    def answer(self, method, target, body=None):
        kind, arg = decide(method, target)
        if body is not None and kind != "instrument":
            return 403, json.dumps({"message": f"refused by DockTor: {method} {target} takes no body"})
        if kind == "instrument":
            return self.instrument(arg, body)
        if kind == "list":
            return self.list_instruments(target)
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
        status, body = self.answer(method, path, req.get("body"))
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
    client = new_client(client_id, CREDENTIAL_PREFIX)
    authenticated = credentials(CREDENTIAL_PREFIX) is not None
    if not authenticated:
        print(f"⚠️ [DOCKER-BUS] {CREDENTIAL_PREFIX}_USERNAME/_PASSWORD unset: answering "
              "anonymously, so any bus client can ask — set them on a bench with the operator ACL")

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
    emit("DOCKER_BUS_SERVING", {"request": REQUEST_TOPIC, "socket": DOCKER_SOCKET,
                                "authenticated": authenticated})
    return client
