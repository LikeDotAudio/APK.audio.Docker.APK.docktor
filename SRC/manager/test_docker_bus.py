# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""The engine's Docker over the bus: the old gate's allow-list, the kept
inspect, the recreate — against a fake daemon that chunks like Docker 29."""

import os
import json
import shutil
import socketserver
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler

from manager import docker_bus
from manager.docker_bus import DockerBus, decide, REPLY_BASE


class _FakeDaemon(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    seen = []

    def _answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        self.seen.append(f"{self.command} {self.path} {body}")
        if self.command == "GET" and self.path == "/_ping":
            status, text = 200, "OK"
        elif self.command == "GET" and self.path.endswith("/json"):
            status, text = 200, json.dumps({
                "Config": {"Image": "apk-plugins:local", "Cmd": ["apk-ptp"]},
                "HostConfig": {"NetworkMode": "host"},
                "NetworkSettings": {"Networks": {"host": {}}}})
        elif self.command == "POST" and self.path.startswith("/containers/create"):
            status, text = 201, '{"Id":"abc"}'
        else:
            status, text = 204, ""
        self.send_response(status)
        if text:
            data = text.encode()
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(data), data))
        else:
            self.send_header("Content-Length", "0")
            self.end_headers()

    do_GET = do_POST = do_DELETE = _answer

    def address_string(self):
        return "fake"

    def log_message(self, *args):
        pass


class _UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class DockerBusTests(unittest.TestCase):

    def test_the_engine_calls_pass_for_plugin_names(self):
        self.assertEqual(decide("GET", "/containers/Plugin-PTP/json"), ("forward", None))
        self.assertEqual(decide("POST", "/containers/Plugin-PTP/start"), ("forward", None))
        self.assertEqual(decide("POST", "/containers/APK-Discovery-Engine/stop?t=5"), ("forward", None))
        self.assertEqual(decide("POST", "/containers/apk-chromecast-44.44.44.151/kill?signal=SIGKILL"),
                         ("forward", None))
        self.assertEqual(decide("DELETE", "/containers/Plugin-PTP?force=true&v=true"),
                         ("forward", "Plugin-PTP"))
        self.assertEqual(decide("POST", "/apk/recreate/Plugin-PTP"), ("recreate", "Plugin-PTP"))
        self.assertEqual(decide("GET", "/apk/health"), ("health", None))

    def test_everything_else_is_refused(self):
        for m, t in [
            ("GET", "/images/json"), ("GET", "/containers/json"),
            ("POST", "/containers/create?name=Plugin-PTP"), ("POST", "/containers/Plugin-PTP/exec"),
            ("GET", "/containers/Broker-Mosquitto/json"), ("POST", "/containers/Broker-Mosquitto/stop?t=5"),
            ("POST", "/containers/DockTor/stop?t=5"),
            ("DELETE", "/containers/Node-BareMetal?force=true"), ("POST", "/containers/PLUGIN-PTP/start"),
            ("POST", "/containers/Plugin-PTP/stop?t=5&signal=KILL"),
            ("POST", "/containers/Plugin-PTP/kill?signal=$(reboot)"),
            ("GET", "/v1.47/containers/Plugin-PTP/json"), ("POST", "/apk/recreate/Broker-Mosquitto"),
            ("GET", "/containers/Plugin-PTP/json?size=1"), ("PUT", "/containers/Plugin-PTP/archive"),
            ("GET", "/containers/Plugin-/json"), ("GET", "/containers/Plugin-a%2F..%2Fx/json"),
        ]:
            self.assertEqual(decide(m, t)[0], "deny", f"{m} {t} must be refused")

    def test_forwards_keeps_and_recreates_against_a_daemon(self):
        tmp = tempfile.mkdtemp(prefix="docktor-bus-")
        try:
            sock = os.path.join(tmp, "daemon.sock")
            server = _UnixServer(sock, _FakeDaemon)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            _FakeDaemon.seen = []
            bus = DockerBus(upstream=sock, kept_dir=os.path.join(tmp, "kept"))

            self.assertEqual(bus.answer("GET", "/images/json")[0], 403)
            self.assertEqual(_FakeDaemon.seen, [], "refused before the daemon hears of it")

            status, body = bus.answer("GET", "/containers/Plugin-PTP/json")
            self.assertEqual(status, 200)
            self.assertIn("apk-plugins:local", json.loads(body)["Config"]["Image"])

            self.assertEqual(bus.answer("POST", "/apk/recreate/Plugin-PTP")[0], 404)
            self.assertEqual(bus.answer("DELETE", "/containers/Plugin-PTP?force=true&v=true")[0], 204)
            self.assertTrue(os.path.exists(os.path.join(tmp, "kept", "Plugin-PTP.json")))
            self.assertEqual(bus.answer("POST", "/apk/recreate/Plugin-PTP")[0], 204)
            create = [l for l in _FakeDaemon.seen if l.startswith("POST /containers/create?name=Plugin-PTP")]
            self.assertTrue(create and "apk-ptp" in create[0] and '"HostConfig"' in create[0], _FakeDaemon.seen)
            self.assertTrue(any(l.startswith("POST /containers/Plugin-PTP/start") for l in _FakeDaemon.seen))
            self.assertEqual(bus.answer("GET", "/apk/health")[0], 200)

            # The bus envelope: replies only under REPLY_BASE.
            topic, payload = bus.handle(json.dumps({"id": "7", "reply": f"{REPLY_BASE}/eng",
                                                    "method": "POST", "path": "/containers/Plugin-PTP/start"}))
            self.assertEqual(topic, f"{REPLY_BASE}/eng")
            self.assertEqual(json.loads(payload), {"id": "7", "status": 204, "body": ""})
            self.assertIsNone(bus.handle(json.dumps({"id": "7", "reply": "APK.audio/elsewhere",
                                                     "method": "GET", "path": "/apk/health"})))
            self.assertIsNone(bus.handle("not json"))
            server.shutdown()
            server.server_close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_a_create_body_carries_network_endpoints_but_not_addresses(self):
        b = docker_bus.create_body_from_inspect({
            "Config": {"Image": "apk-plugins:local"},
            "HostConfig": {"NetworkMode": "apk-audio_default", "CapAdd": ["NET_RAW"]},
            "NetworkSettings": {"Networks": {"apk-audio_default": {"Aliases": ["r"], "IPAddress": "1.2.3.4"}}}})
        self.assertEqual(b["NetworkingConfig"]["EndpointsConfig"]["apk-audio_default"], {"Aliases": ["r"]})
        self.assertIsNone(docker_bus.create_body_from_inspect({"message": "No such container"}))


if __name__ == "__main__":
    unittest.main()
