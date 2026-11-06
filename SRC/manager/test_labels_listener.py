# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""The labels listener (the bridge-facing second door) exposes two reads and
nothing else: GET/HEAD /api/endpoints/labels (+ /api/v1 alias) and
/api/stack-containers?stack=<one stack> answer, every other path is 404,
every other method 405.

    cd PODS/POD.manager/MANAGER.Docktor/SRC && python3 -m unittest manager.test_labels_listener -v
"""

import http.client
import json
import os
import unittest
from unittest import mock

from manager import api, serve

ROWS = [{"container": "NMOS-Dev", "stack": "PROTOCOL.discovery.NMOS", "kind": "open",
         "url": "http://localhost:3211/x-nmos/query/v1.3/", "label": "Query", "purpose": "p",
         "running": True}]


SNAPSHOT = {"groups": [
    {"stack": "DATABASE.server.NETBOX", "label": "Netbox", "containers": [
        {"name": "Netbox-App", "status": "Up 2 hours (healthy)", "tone": "ok", "dead": False,
         "group": "Netbox", "leaf": "App", "image": "netbox:x", "ports": "127.0.0.1:8082->8080/tcp"},
        {"name": "Netbox-Worker", "status": "Exited (1)", "tone": "bad", "dead": True,
         "group": "Netbox", "leaf": "Worker", "image": "netbox:x", "ports": ""}]},
    {"stack": "CLOCK.Heartbeat", "label": "Plugins", "containers": [
        {"name": "Plugin-PTP", "status": "Up", "tone": "ok", "dead": False, "group": "Plugins", "leaf": "PTP"}]}]}


class LabelsListener(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.patch = mock.patch.object(api, "label_endpoints", return_value=ROWS)
        cls.calls = cls.patch.start()
        cls.snap = mock.patch.object(api, "snapshot", return_value=SNAPSHOT)
        cls.snap.start()
        serve._labels_cache.update(at=0.0, body=None)
        serve._snapshot_cache.update(at=0.0, groups=None)
        cls.httpd = serve.start_labels_listener(("127.0.0.1", 0))
        cls.port = cls.httpd.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.patch.stop()
        cls.snap.stop()

    def ask(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp.status, data, resp

    def test_the_one_read_answers(self):
        for path in ("/api/endpoints/labels", "/api/v1/endpoints/labels", "/api/endpoints/labels/"):
            status, data, resp = self.ask("GET", path)
            self.assertEqual(status, 200, path)
            self.assertEqual(json.loads(data), ROWS)
            self.assertEqual(resp.getheader("Content-Type"), "application/json")
        status, data, _ = self.ask("HEAD", "/api/endpoints/labels")
        self.assertEqual((status, data), (200, b""))

    def test_one_stack_answers_trimmed_rows(self):
        status, data, _ = self.ask("GET", "/api/stack-containers?stack=DATABASE.server.NETBOX")
        self.assertEqual(status, 200)
        rows = json.loads(data)
        self.assertEqual([r["name"] for r in rows], ["Netbox-App", "Netbox-Worker"])
        self.assertEqual([r["running"] for r in rows], [True, False])
        for r in rows:
            self.assertEqual(set(r), {"name", "group", "leaf", "status", "tone", "dead", "stack", "running"})
        self.assertEqual(json.loads(self.ask("GET", "/api/stack-containers?stack=Nope")[1]), [])

    def test_stack_query_is_one_plain_name(self):
        for q in ("", "?stack=", "?stack=a&stack=b", "?stack=X&all=1", "?stack=../x",
                  "?stack=a%20b", "?other=1"):
            self.assertEqual(self.ask("GET", "/api/stack-containers" + q)[0], 400, q)
        self.assertEqual(self.ask("POST", "/api/stack-containers?stack=X", body=b"{}")[0], 405)

    def test_every_other_path_is_404(self):
        for path in ("/", "/index.html", "/api/health", "/api/endpoints", "/api/routes",
                     "/api/containers", "/api/action/up", "/api/stream", "/api/log",
                     "/api/v2/endpoints/labels", "/api/endpoints/labels/../health",
                     "/api/endpoints/labelsX", "/manager.js", "/api/container/Plugin-PTP"):
            self.assertEqual(self.ask("GET", path)[0], 404, path)

    def test_every_other_method_is_405(self):
        for method in ("POST", "PUT", "DELETE", "PATCH", "OPTIONS", "TRACE", "BREW"):
            status, _, resp = self.ask(method, "/api/endpoints/labels", body=b"{}")
            self.assertEqual(status, 405, method)
            self.assertEqual(resp.getheader("Allow"), "GET, HEAD")
        self.assertEqual(self.ask("POST", "/api/action/panic", body=b"{}")[0], 405)

    def test_answers_are_cached(self):
        serve._labels_cache.update(at=0.0, body=None)
        self.calls.reset_mock()
        for _ in range(5):
            self.ask("GET", "/api/endpoints/labels")
        self.assertEqual(self.calls.call_count, 1)


class Address(unittest.TestCase):
    def test_default_is_the_docker0_gateway_on_8766(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(serve.labels_listener_address(), ("172.17.0.1", 8766))

    def test_settings_and_off(self):
        with mock.patch.dict(os.environ, {"APK_MANAGER_LABELS_BIND": "10.0.0.1",
                                          "APK_MANAGER_LABELS_PORT": "9000"}):
            self.assertEqual(serve.labels_listener_address(), ("10.0.0.1", 9000))
        for off in ("off", "", "OFF"):
            with mock.patch.dict(os.environ, {"APK_MANAGER_LABELS_BIND": off}):
                self.assertIsNone(serve.labels_listener_address())

    def test_an_address_it_cannot_bind_is_not_fatal(self):
        self.assertIsNone(serve.start_labels_listener(("203.0.113.9", 8766)))


if __name__ == "__main__":
    unittest.main()
