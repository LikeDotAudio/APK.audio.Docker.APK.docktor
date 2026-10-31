# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""Every broker credential a stack's compose file asks for is forwarded by
DockTor's own compose env, so a dashboard or watchdog remount (compose run
INSIDE DockTor) cannot bring a stack back with blank credentials (go-live
2026-10-30: the engine lost APK_DOCKER_BUS_MQTT_* that way).

    cd PODS/POD.manager/MANAGER.Docktor/SRC && python3 -m unittest manager.test_forwarded_env -v

Derived from the tree, not listed: every `APK_…MQTT…_USERNAME/_PASSWORD` name
in any compose file under PODS/ must appear as a key of the manager's
`environment:`. Skips when run outside a checkout (the image has no PODS/).
"""

import os
import re
import unittest

from .paths import DOCKERS_DIRECTORY, MANAGEMENT_DIRECTORY

NAME = re.compile(r"\b(APK_[A-Z0-9_]*MQTT[A-Z0-9_]*_(?:USERNAME|PASSWORD))\b")
MANAGER_COMPOSE = os.path.join(MANAGEMENT_DIRECTORY, "Docker", "docker-compose.manager.yml")


def compose_files(root):
    for here, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ("node_modules", "target", ".git")]
        for f in files:
            if re.match(r"(docker-)?compose.*\.ya?ml$|.*\.compose\.ya?ml$|plugin-base\.yml$", f) \
                    or (f.endswith((".yml", ".yaml")) and os.path.basename(here) == "Docker"):
                yield os.path.join(here, f)


def forwarded():
    keys = set()
    with open(MANAGER_COMPOSE, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"^\s+(APK_[A-Z0-9_]+):", line)
            if m:
                keys.add(m.group(1))
    return keys


class Forwarded(unittest.TestCase):
    def test_every_stack_credential_is_forwarded(self):
        if not os.path.isdir(os.path.join(DOCKERS_DIRECTORY, "POD.THICK")):
            self.skipTest("not a checkout")
        have = forwarded()
        missing = {}
        for path in compose_files(DOCKERS_DIRECTORY):
            if os.path.abspath(path) == os.path.abspath(MANAGER_COMPOSE):
                continue
            try:
                text = open(path, encoding="utf-8").read()
            except (OSError, UnicodeDecodeError):
                continue
            for line in text.splitlines():
                if line.lstrip().startswith("#"):
                    continue
                for name in NAME.findall(line):
                    if name not in have:
                        missing.setdefault(name, os.path.relpath(path, DOCKERS_DIRECTORY))
        self.assertEqual(missing, {}, "add these to Docker/docker-compose.manager.yml environment")

    def test_the_known_identities_are_there(self):
        for name in ("APK_DOCKER_BUS_MQTT_PASSWORD", "APK_LAUNCHER_MQTT_PASSWORD",
                     "APK_MACHINE_MQTT_PASSWORD", "APK_MQTT_OPERATOR_PASSWORD",
                     "APK_DOCKTOR_MQTT_PASSWORD", "APK_MQTT_PASSWORD"):
            self.assertIn(name, forwarded())


if __name__ == "__main__":
    unittest.main()
