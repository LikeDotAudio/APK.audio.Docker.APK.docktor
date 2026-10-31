# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""One paho constructor, credentials by prefix, the docker bus under its own
broker identity (2026-10-30 audit, DockTor #2 and #5).

    cd PODS/POD.manager/MANAGER.Docktor/SRC && python3 -m unittest manager.test_bus_identity -v
"""

import os
import unittest
from unittest import mock

from manager import bus, docker_bus, api


class Credentials(unittest.TestCase):
    def test_both_set_is_a_credential(self):
        with mock.patch.dict(os.environ, {"APK_DOCKTOR_MQTT_USERNAME": "apkaudio-docktor",
                                          "APK_DOCKTOR_MQTT_PASSWORD": "pw"}):
            self.assertEqual(bus.credentials("APK_DOCKTOR_MQTT"), ("apkaudio-docktor", "pw"))

    def test_half_set_or_blank_is_anonymous(self):
        for env in ({"APK_DOCKTOR_MQTT_USERNAME": "apkaudio-docktor"},
                    {"APK_DOCKTOR_MQTT_PASSWORD": "pw"},
                    {"APK_DOCKTOR_MQTT_USERNAME": "  ", "APK_DOCKTOR_MQTT_PASSWORD": "pw"}):
            with mock.patch.dict(os.environ, env, clear=True):
                self.assertIsNone(bus.credentials("APK_DOCKTOR_MQTT"))

    def test_the_prefixes_do_not_leak_into_each_other(self):
        with mock.patch.dict(os.environ, {"APK_MQTT_USERNAME": "house", "APK_MQTT_PASSWORD": "pw"},
                             clear=True):
            self.assertEqual(bus.credentials(), ("house", "pw"))
            self.assertIsNone(bus.credentials(docker_bus.CREDENTIAL_PREFIX))


class FakeClient:
    def __init__(self, client_id=None, **_kw):
        self.client_id, self.auth = client_id, None

    def username_pw_set(self, user, password):
        self.auth = (user, password)


class OneConstructor(unittest.TestCase):
    def test_new_client_applies_the_prefix_credentials(self):
        try:
            import paho.mqtt.client as mqtt
        except ImportError:                                     # pragma: no cover
            self.skipTest("no paho")
        with mock.patch.object(mqtt, "Client", FakeClient), \
             mock.patch.dict(os.environ, {"APK_DOCKTOR_MQTT_USERNAME": "apkaudio-docktor",
                                          "APK_DOCKTOR_MQTT_PASSWORD": "pw"}, clear=True):
            self.assertEqual(bus.new_client("x", "APK_DOCKTOR_MQTT").auth, ("apkaudio-docktor", "pw"))
            self.assertIsNone(bus.new_client("y").auth)

    def test_the_docker_bus_uses_its_own_identity(self):
        self.assertEqual(docker_bus.CREDENTIAL_PREFIX, "APK_DOCKTOR_MQTT")
        self.assertEqual(docker_bus.REQUEST_TOPIC, "APK.audio/System/ContainerManager/docker/request")
        self.assertEqual(docker_bus.REPLY_BASE, "APK.audio/System/ContainerManager/docker/reply")

    def test_the_topics_are_the_contracts_spelling(self):
        try:
            from apkaudio_contracts import families
        except ImportError:                                     # pragma: no cover
            self.skipTest("apkaudio_contracts not importable here")
        if os.environ.get("TOPIC_ROOT"):
            self.skipTest("TOPIC_ROOT overrides the event tree")
        self.assertEqual(bus.EVENT_TOPIC, families.topic("containerManagerEvent"))
        self.assertEqual(bus.STATUS_TOPIC, families.topic("containerManagerStatus"))
        self.assertEqual(bus.MANAGER_TOPIC, families.topic("containerManagerManager"))
        # containers/ is the branch above containerManagerContainer's {stack}/{name} leaves.
        self.assertEqual(families.topic("containerManagerContainer", stack="s", name="n"),
                         f"{bus.CONTAINERS_TOPIC}/s/n")
        self.assertEqual(api.CHAT_TOPIC, families.topic("systemChat"))
        self.assertEqual(docker_bus.REQUEST_TOPIC, families.topic("containerManagerDockerRequest"))
        self.assertEqual(f"{docker_bus.REPLY_BASE}/x",
                         families.topic("containerManagerDockerReply", client="x"))
        self.assertEqual(bus.contract_topic("no-such-family", "fallback"), "fallback")

    def test_chat_goes_through_the_bus_session(self):
        with mock.patch.object(api, "bus_publish", return_value=True) as sent, \
             mock.patch.object(api, "emit"):
            out = api.chat("hello")
        self.assertTrue(out["published"])
        self.assertEqual(sent.call_args[0][0], api.CHAT_TOPIC)


if __name__ == "__main__":
    unittest.main()
