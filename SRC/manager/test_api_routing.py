# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""api.run_action routes each verb to its one script, and refuses what it must
(2026-10-30 audit, DockTor #8). No script runs: run_reported is replaced.

    cd PODS/POD.manager/MANAGER.Docktor/SRC && python3 -m unittest manager.test_api_routing -v
"""

import os
import unittest
from unittest import mock

from manager import api, serve


class Routing(unittest.TestCase):
    def setUp(self):
        self.calls = []

        def fake_run(script, args, on_line_callback=None, ordered_by=None):
            self.calls.append((script, list(args)))
            return 0, ""

        patches = [mock.patch.object(api, "run_reported", fake_run),
                   mock.patch.object(api, "chat", lambda *_a, **_k: {"ok": True}),
                   mock.patch.object(api, "emit", lambda *_a, **_k: None),
                   mock.patch.object(api.QUEUE, "waiting", lambda: [])]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def test_every_script_named_by_a_table_exists(self):
        for table in (api.ACTIONS, api.CONTAINER_ACTIONS, api.STACK_ACTIONS):
            for key, row in table.items():
                path = os.path.join(api.DOCKER_SCRIPTS_DIRECTORY, row["script"])
                self.assertTrue(os.path.isfile(path), f"{key}: {path}")

    def test_unknown_verb_is_127_and_runs_nothing(self):
        code, _ = api.run_action("no-such-verb")
        self.assertEqual(code, 127)
        self.assertEqual(self.calls, [])

    def test_a_stack_verb_names_the_stack(self):
        code, _ = api.run_action("up-stack", name="DATABUS.Broker.MQTT", scope="stack")
        self.assertEqual(code, 0)
        self.assertEqual(self.calls, [("up-stack.sh", ["DATABUS.Broker.MQTT"])])

    def test_a_stack_verb_in_container_scope_is_refused(self):
        code, _ = api.run_action("up-stack", name="Plugin-PING", scope="container")
        self.assertEqual(code, 127)
        self.assertEqual(self.calls, [])

    def test_a_container_verb_carries_name_then_extra(self):
        key = next(iter(api.CONTAINER_ACTIONS))
        api.run_action(key, name="Plugin-PING", extra=["--tail", "5"])
        self.assertEqual(self.calls, [(api.CONTAINER_ACTIONS[key]["script"],
                                       ["Plugin-PING", "--tail", "5"])])

    def test_the_prompt_pattern_is_enforced_server_side(self):
        code, _ = api.run_action("kill-pid", extra=["1; rm -rf /"])
        self.assertEqual(code, 2)
        self.assertEqual(self.calls, [])
        code, _ = api.run_action("kill-pid", extra=["182129"])
        self.assertEqual(code, 0)
        self.assertEqual(self.calls, [("kill-pid.sh", ["182129"])])

    def test_a_bench_verb_without_a_prompt_ignores_extra(self):
        key = next(k for k, row in api.ACTIONS.items() if not row.get("prompt"))
        api.run_action(key, extra=["--evil"])
        self.assertEqual(self.calls, [(api.ACTIONS[key]["script"], list(api.ACTIONS[key]["args"]))])


class Versioned(unittest.TestCase):
    def test_v1_prefix_is_the_unversioned_route(self):
        self.assertEqual(serve._unversioned("/api/v1/health"), "/api/health")
        self.assertEqual(serve._unversioned("/api/v1"), "/api")
        self.assertEqual(serve._unversioned("/api/v9/health"), "/api/v9/health")

    def test_health_says_its_versions(self):
        health = api.health()
        self.assertEqual(health["api_version"], api.API_VERSION)
        self.assertIn("document_version", health)
        self.assertIn("contract_version", health)


if __name__ == "__main__":
    unittest.main()
