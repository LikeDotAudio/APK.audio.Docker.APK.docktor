# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""GET /api/endpoints/labels: the label-driven endpoint list (owner decision
2026-10-30), shaped from endpoints.sh --labels. No docker: the script's output
is handed in.

    cd PODS/POD.manager/MANAGER.Docktor/SRC && python3 -m unittest manager.test_label_endpoints -v
"""

import json
import unittest
from unittest import mock

from manager import api

SAMPLE = [
    {"name": "NMOS-Dev", "running": True, "labels": {
        "audio.apk.purpose": "NMOS registry and node",
        "audio.apk.endpoint.1": "open http://localhost:3211/x-nmos/query/v1.3/ NMOS IS-04 Query API",
        "audio.apk.endpoint.10": "open http://localhost:3218/x-nmos/node/v1.3/self NMOS Node (bridge)",
        "audio.apk.endpoint.2": "copy ws://localhost:3213/ NMOS IS-04 Query WebSocket",
        "com.docker.compose.project.working_dir": "/repo/PODS/POD.protocols/PROTOCOL.discovery.NMOS/Docker"}},
    {"name": "Plugin-PTP", "running": False, "labels": {
        "audio.apk.purpose": "PTP clocks", "audio.apk.endpoint.1": "bogus nothing here",
        "audio.apk.endpoint.2": "copy  mqtt://127.0.0.1:1883/APK.audio/x"}},
]


class Shape(unittest.TestCase):
    def test_rows_in_label_order_with_stack_and_purpose(self):
        rows = api.label_endpoints_from(SAMPLE)
        self.assertEqual([r["url"] for r in rows if r["container"] == "NMOS-Dev"],
                         ["http://localhost:3211/x-nmos/query/v1.3/", "ws://localhost:3213/",
                          "http://localhost:3218/x-nmos/node/v1.3/self"])
        first = rows[0]
        self.assertEqual(set(first), {"container", "stack", "kind", "url", "label", "purpose", "running"})
        self.assertEqual(first["stack"], "PROTOCOL.discovery.NMOS")
        self.assertEqual(first["kind"], "open")
        self.assertEqual(first["label"], "NMOS IS-04 Query API")
        self.assertEqual(first["purpose"], "NMOS registry and node")

    def test_a_malformed_label_is_skipped_and_spacing_is_normalised(self):
        ptp = [r for r in api.label_endpoints_from(SAMPLE) if r["container"] == "Plugin-PTP"]
        self.assertEqual(len(ptp), 1)
        self.assertEqual((ptp[0]["kind"], ptp[0]["url"], ptp[0]["label"], ptp[0]["running"]),
                         ("copy", "mqtt://127.0.0.1:1883/APK.audio/x", "", False))
        self.assertTrue(ptp[0]["stack"])          # falls back to the grid's group

    def test_the_route_runs_the_script_and_survives_its_failure(self):
        with mock.patch.object(api, "run_management_script", return_value=(0, json.dumps(SAMPLE))) as run:
            self.assertEqual(len(api.label_endpoints()), 4)
        self.assertEqual(run.call_args[0][:2], ("endpoints.sh", ["--labels"]))
        with mock.patch.object(api, "run_management_script", return_value=(1, "boom")):
            self.assertEqual(api.label_endpoints(), [])
        self.assertIn("/api/endpoints/labels", [r["path"] for r in api.ROUTES])


if __name__ == "__main__":
    unittest.main()
