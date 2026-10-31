# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""The retained ContainerManager documents hold the shape schemas/ says (2026-10-30 audit, #3).

    cd PODS/POD.manager/MANAGER.Docktor/SRC && python3 -m unittest manager.test_report_documents -v

The OS dashboards parse these four documents; Documentation/CONTRACTS.md names
the fields, schemas/*.schema.json pins them, and this proves report.py's
builders produce what the schemas say. The validator is the subset of JSON
Schema those files use (type, required, properties, additionalProperties,
const, enum, items, minimum, pattern, $ref to a sibling file), so the test
needs no package the image does not carry.
"""

import json
import os
import re
import unittest

from . import report
from .bus import DOCUMENT_VERSION, STATUS_TOPIC, MANAGER_TOPIC, CONTAINERS_TOPIC

SCHEMAS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schemas")
_TYPES = {"object": dict, "array": list, "string": str, "boolean": bool,
          "null": type(None), "number": (int, float), "integer": int}


def _schema(name):
    with open(os.path.join(SCHEMAS, name), encoding="utf-8") as fh:
        return json.load(fh)


def _is(value, kind):
    if kind in ("integer", "number") and isinstance(value, bool):
        return False
    return isinstance(value, _TYPES[kind])


def problems(value, schema, where="$"):
    """Every way `value` breaks `schema`, as readable strings."""
    if "$ref" in schema:
        return problems(value, _schema(schema["$ref"]), where)
    out = []
    kinds = schema.get("type")
    if kinds is not None:
        kinds = kinds if isinstance(kinds, list) else [kinds]
        if not any(_is(value, k) for k in kinds):
            return [f"{where}: {type(value).__name__} is not {kinds}"]
    if "const" in schema and value != schema["const"]:
        out.append(f"{where}: {value!r} != {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        out.append(f"{where}: {value!r} not in {schema['enum']}")
    if "minimum" in schema and _is(value, "number") and value < schema["minimum"]:
        out.append(f"{where}: {value} < {schema['minimum']}")
    if "pattern" in schema and isinstance(value, str) and not re.search(schema["pattern"], value):
        out.append(f"{where}: {value!r} does not match {schema['pattern']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                out.append(f"{where}: missing {key}")
        props = schema.get("properties", {})
        for key, item in value.items():
            if key in props:
                out += problems(item, props[key], f"{where}.{key}")
            elif schema.get("additionalProperties") is False:
                out.append(f"{where}: unexpected {key}")
    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            out += problems(item, schema["items"], f"{where}[{i}]")
    return out


FULL_CARD = {
    "name": "Storage-Portal", "status": "Up 3 hours (healthy)", "dead": False, "ours": True,
    "group": "Storage", "image": "storage-portal:local", "network_mode": "apk-audio_default",
    "project": "apk-audio", "ports": "127.0.0.1:8080->80/tcp", "published": ["8080"],
    "resources": {"cpu_percent": "0.12%", "memory": "40MiB / 31GiB", "memory_percent": "0.1%",
                  "net_io": "1kB / 2kB", "block_io": "0B / 0B", "pids": "3"},
    "apps": [{"app": "nginx", "state": "running", "detail": "4 clients"}],
    "staleness": {"stale": "no", "behind": 0, "built": "2026-10-30T10:00:00Z",
                  "changed": "2026-10-30T09:00:00Z", "newest": "x"},
}
THIN_CARD = {"name": "Plugin-PING", "status": "Exited (0) 2 minutes ago"}


class Documents(unittest.TestCase):
    def assertValid(self, document, schema_file):
        self.assertEqual(problems(document, _schema(schema_file)), [])

    def test_container_document_full_and_thin(self):
        for card in (FULL_CARD, THIN_CARD):
            self.assertValid(report.container_document(card), "container.schema.json")

    def test_status_document_with_query_and_response(self):
        docs = [report.container_document(c) for c in (FULL_CARD, THIN_CARD)]
        status = report.status_document("after", docs, query={"script": "up.sh", "argv": ["up.sh"]},
                                        response={"exit_code": 0, "ok": True, "duration_s": 1.5})
        self.assertValid(status, "status.schema.json")
        self.assertValid(report.status_document("refresh", []), "status.schema.json")

    def test_manager_document(self):
        docs = [report.container_document(c) for c in (FULL_CARD, THIN_CARD)]
        manager = report.manager_document("heartbeat", docs, [("127.0.0.1", 1883, "Local")],
                                          docs[:1], ["Gone-One"])
        self.assertValid(manager, "manager.schema.json")
        self.assertEqual(manager["topics"], {"status": STATUS_TOPIC, "manager": MANAGER_TOPIC,
                                             "containers": CONTAINERS_TOPIC})

    def test_app_document(self):
        doc = report.container_document(FULL_CARD)
        self.assertValid(report.app_document(doc, doc["apps"][0], "2026-10-30T10:00:00Z"),
                         "app.schema.json")

    def test_every_document_carries_the_one_version(self):
        for name in ("container", "status", "manager", "app"):
            self.assertEqual(_schema(f"{name}.schema.json")["properties"]["doc_version"],
                             {"const": DOCUMENT_VERSION})

    def test_the_validator_rejects_a_broken_document(self):
        broken = report.container_document(FULL_CARD)
        broken["apps_total"] = "one"
        del broken["image"]
        self.assertEqual(len(problems(broken, _schema("container.schema.json"))), 2)


if __name__ == "__main__":
    unittest.main()
