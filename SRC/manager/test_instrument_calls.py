# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""The instrument launcher's three calls (NODE.BareMetal BM-11): the instrument
list, the instrument image inspect, and the checked POST /apk/instrument/<name>.

    cd PODS/POD.manager/MANAGER.Docktor/SRC && python3 -m unittest manager.test_instrument_calls -v
"""

import copy
import json
import os
import shutil
import tempfile
import threading
import unittest
import urllib.parse
from unittest import mock

from manager import docker_bus
from manager.docker_bus import DockerBus, decide, instrument_problems, REPLY_BASE
from manager.test_docker_bus import _FakeDaemon, _UnixServer

ROOT = "/srv/APK.audio"
INSTRUMENTS = f"{ROOT}/PODS/POD.THICK/INSTRUMENTS"
PLUGINS = f"{ROOT}/PODS/POD.THICK/PLUGINS"
ENV = {"APKAUDIO_REPO": ROOT, "APK_INSTRUMENT_IMAGE": "", "APK_INSTRUMENT_BIND_ROOTS": ""}
FILTER = urllib.parse.quote(json.dumps({"label": ["apk.audio.role=instrument"]}))


def good_body():
    """What NODE.BareMetal's docktor_client.create_container sends."""
    return {
        "Image": "apk-plugins:local",
        "Env": ["APK_INSTRUMENT_FAMILY=DMM", "MQTT_HOST=127.0.0.1"],
        "Labels": {"apk.audio.role": "instrument", "apk.audio.family": "DMM",
                   "apk.audio.managed_by": "BareMetal-Manager"},
        "Cmd": ["apk-instrument", "--model", "34401A"],
        "HostConfig": {
            "NetworkMode": "host", "RestartPolicy": {"Name": "unless-stopped"},
            "Mounts": [
                {"Type": "bind", "Source": INSTRUMENTS, "Target": "/instruments", "ReadOnly": False},
                {"Type": "bind", "Source": INSTRUMENTS, "Target": "/APK:PODS/POD:APK_THICK/APK:INSTRUMENTS",
                 "ReadOnly": False},
                {"Type": "bind", "Source": PLUGINS, "Target": "/plugins", "ReadOnly": False},
                {"Type": "bind", "Source": f"{INSTRUMENTS}/DMM/34401A", "Target": "/instrument",
                 "ReadOnly": False},
            ],
        },
    }


class Decide(unittest.TestCase):
    def test_the_three_calls_are_admitted(self):
        self.assertEqual(decide("GET", f"/containers/json?all=1&filters={FILTER}"), ("list", None))
        self.assertEqual(decide("GET", f"/containers/json?all=0&filters={FILTER}"), ("list", None))
        with mock.patch.dict(os.environ, ENV):
            self.assertEqual(decide("GET", "/images/apk-plugins%3Alocal/json"), ("forward", None))
        self.assertEqual(decide("POST", "/apk/instrument/apk-dmm-34401a-my1"),
                         ("instrument", "apk-dmm-34401a-my1"))

    def test_any_other_list_or_image_is_refused(self):
        other = urllib.parse.quote(json.dumps({"label": ["com.docker.compose.project=apk-audio"]}))
        wider = urllib.parse.quote(json.dumps({"label": ["apk.audio.role=instrument"], "name": ["x"]}))
        with mock.patch.dict(os.environ, ENV):
            for m, t in [("GET", "/containers/json"), ("GET", "/containers/json?all=1"),
                         ("GET", f"/containers/json?all=1&filters={other}"),
                         ("GET", f"/containers/json?all=1&filters={wider}"),
                         ("GET", f"/containers/json?all=1&filters={FILTER}&size=1"),
                         ("GET", f"/containers/json?all=yes&filters={FILTER}"),
                         ("GET", "/images/eclipse-mosquitto%3A2.0.22/json"), ("GET", "/images/json"),
                         ("GET", "/images/apk-plugins%3Alocal/history"),
                         ("POST", "/apk/instrument/apk-x?force=1"), ("GET", "/apk/instrument/apk-x")]:
                self.assertEqual(decide(m, t)[0], "deny", f"{m} {t}")


class Validation(unittest.TestCase):
    def setUp(self):
        p = mock.patch.dict(os.environ, ENV)
        p.start()
        self.addCleanup(p.stop)

    def test_the_launchers_document_passes(self):
        self.assertEqual(instrument_problems("apk-dmm-34401a-my1", good_body()), [])
        self.assertEqual(instrument_problems("apk-appletv-44.44.44.156", good_body()), [])

    def test_every_way_out_is_refused(self):
        def bad(name="apk-dmm-x", **change):
            body = copy.deepcopy(good_body())
            for path, value in change.items():
                *parents, leaf = path.split("__")
                node = body
                for key in parents:
                    node = node[key]
                if value is KeyError:
                    node.pop(leaf, None)
                else:
                    node[leaf] = value
            return instrument_problems(name, body)

        cases = {
            "broker name": bad(name="Broker-Mosquitto"),
            "Plugin- name": bad(name="Plugin-PTP"),
            "upper case": bad(name="apk-DMM"),
            "slash": bad(name="apk-a/../b"),
            "other image": bad(Image="alpine:latest"),
            "the broker's image": bad(Image="broker-mosquitto:local"),
            "bridge network": bad(HostConfig__NetworkMode="bridge"),
            "privileged": bad(HostConfig__Privileged=True),
            "cap add": bad(HostConfig__CapAdd=["SYS_ADMIN"]),
            "devices": bad(HostConfig__Devices=[{"PathOnHost": "/dev/mem"}]),
            "pid host": bad(HostConfig__PidMode="host"),
            "no role label": bad(Labels={"apk.audio.family": "DMM"}),
            "protected label": instrument_problems("apk-x", {**good_body(), "Labels": {
                    "apk.audio.role": "instrument", "apk.audio.protected": "true"}}),
            "compose label": instrument_problems("apk-x", {**good_body(), "Labels": {
                "apk.audio.role": "instrument", "com.docker.compose.service": "mosquitto"}}),
            "extra top-level key": bad(Entrypoint=["/bin/sh"]),
            "volume mount": bad(HostConfig__Mounts=[{"Type": "volume", "Source": "apk-audio-mqtt_broker-data",
                                                     "Target": "/x"}]),
            "socket bind": bad(HostConfig__Mounts=[{"Type": "bind", "Source": "/var/run/docker.sock",
                                                    "Target": "/var/run/docker.sock"}]),
            "escape by ..": bad(HostConfig__Mounts=[{"Type": "bind", "Source": f"{INSTRUMENTS}/../../..",
                                                     "Target": "/x"}]),
            "sibling prefix": bad(HostConfig__Mounts=[{"Type": "bind", "Source": f"{INSTRUMENTS}-evil",
                                                       "Target": "/x"}]),
            "bind propagation": bad(HostConfig__Mounts=[{"Type": "bind", "Source": PLUGINS, "Target": "/p",
                                                         "BindOptions": {"Propagation": "rshared"}}]),
            "binds outside": bad(HostConfig__Binds=["/etc:/etc:ro"]),
            "env not a list": bad(Env={"A": "1"}),
            "restart policy": bad(HostConfig__RestartPolicy={"Name": "sometimes"}),
        }
        for label, problems in cases.items():
            self.assertTrue(problems, f"{label} must be refused")

    def test_binds_under_the_trees_pass(self):
        body = good_body()
        body["HostConfig"]["Binds"] = [f"{PLUGINS}:/plugins:ro", f"{INSTRUMENTS}/DMM:/instrument"]
        self.assertEqual(instrument_problems("apk-x", body), [])

    def test_the_roots_and_images_are_settings(self):
        with mock.patch.dict(os.environ, {"APK_INSTRUMENT_BIND_ROOTS": "/a:b/INSTRUMENTS;/c/PLUGINS",
                                          "APK_INSTRUMENT_IMAGE": "apk-plugins:local, apk-plugins:test"}):
            self.assertEqual(docker_bus.instrument_bind_roots(), ["/a:b/INSTRUMENTS", "/c/PLUGINS"])
            self.assertEqual(docker_bus.instrument_images(), {"apk-plugins:local", "apk-plugins:test"})


class AgainstADaemon(unittest.TestCase):
    def test_create_list_image_and_refusals(self):
        tmp = tempfile.mkdtemp(prefix="docktor-inst-")
        try:
            sock = os.path.join(tmp, "daemon.sock")
            server = _UnixServer(sock, _FakeDaemon)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            _FakeDaemon.seen = []
            bus = DockerBus(upstream=sock, kept_dir=os.path.join(tmp, "kept"))
            with mock.patch.dict(os.environ, ENV):
                bad = good_body()
                bad["HostConfig"]["Privileged"] = True
                topic, payload = bus.handle(json.dumps({"id": "1", "reply": f"{REPLY_BASE}/baremetal-launcher-h-1",
                                                        "method": "POST", "path": "/apk/instrument/apk-dmm-x",
                                                        "body": bad}))
                self.assertEqual(json.loads(payload)["status"], 403)
                self.assertEqual(_FakeDaemon.seen, [], "refused before the daemon hears of it")

                topic, payload = bus.handle(json.dumps({"id": "2", "reply": f"{REPLY_BASE}/baremetal-launcher-h-1",
                                                        "method": "POST", "path": "/apk/instrument/apk-dmm-x",
                                                        "body": good_body()}))
                self.assertEqual(json.loads(payload)["status"], 201)
                create = [l for l in _FakeDaemon.seen if l.startswith("POST /containers/create?name=apk-dmm-x ")]
                self.assertTrue(create and '"NetworkMode": "host"' in create[0], _FakeDaemon.seen)
                self.assertTrue(os.path.exists(os.path.join(tmp, "kept", "apk-dmm-x.json")),
                                "the inspect is kept so /apk/recreate works")

                _FakeDaemon.seen = []
                status, _ = bus.answer("GET", f"/containers/json?all=1&filters={FILTER}")
                self.assertEqual(status, 204)    # the fake answers 204 to a list
                self.assertEqual(_FakeDaemon.seen, [f"GET /containers/json?all=1&filters={FILTER} "])
                self.assertEqual(bus.answer("GET", "/images/apk-plugins%3Alocal/json")[0], 200)

                # A body on any other verb is refused, not ignored.
                self.assertEqual(bus.answer("POST", "/containers/Plugin-PTP/start", {"x": 1})[0], 403)
            server.shutdown()
            server.server_close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
