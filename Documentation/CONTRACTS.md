# Contract Bindings — `MANAGER.Docktor`

Part of the **APK.audio** contracts framework (`contracts/` at the APK.audio repository root:
`@apkaudio/contracts` for TypeScript, `apkaudio-contracts` for Rust, `apkaudio_contracts` for Python).
DockTor's image pip-installs `apkaudio_contracts` from `contracts/python`. `SRC/manager/bus.py` takes the root and
`broker_auth` from it, `docker_bus.py` the `containerManagerDockerRequest`/`…Reply` families, and
`test_bus_identity.py` holds every DockTor topic equal to the contracts' spelling (a host `--cli` run without the
package uses the same literals).

---

## Bus — `APK.audio/System/ContainerManager` (no `System/Protocols/…` mailbox)

`TOPIC_ROOT` defaults to `APK.audio/System` (env `TOPIC_ROOT`). Broker: `MQTT_HOST` / `APK_MQTT_HOST`, else
`127.0.0.1`; port `MQTT_PORT` / `APK_MQTT_PORT`, else `1883`.

| Topic | Retain | Published by | What |
|---|---|---|---|
| `…/ContainerManager` | no | `bus.emit()` | every event as it happens: `{servername, pid, root, topic, timestamp, event, details}`. Scripts raise them by printing `@EVENT NAME {json}` |
| `…/ContainerManager/status` | yes | `report.py` | the whole bench in one document |
| `…/ContainerManager/Manager` | yes | `report.py` | the publisher itself |
| `…/ContainerManager/containers/<Stack>/<Name>` | yes | `report.py` | one container, in full |
| `…/ContainerManager/containers/<Stack>/<Name>/apps/<App>` | yes | `report.py` | one app inside it |
| `APK.audio/System/Chat` (`CHAT_TOPIC` in `api.py`, not under `TOPIC_ROOT`) | no | `POST /api/chat`, every action start/result | one human-readable line; published on `bus.py`'s event session (same broker, same credentials) |

**Every retained document carries `doc_version` (`bus.DOCUMENT_VERSION`, now 1)** and has a JSON Schema in
`SRC/manager/schemas/` — `status.schema.json`, `manager.schema.json`, `container.schema.json`, `app.schema.json`.
`SRC/manager/test_report_documents.py` builds each with `report.py`'s own builders and validates it. A field
removed or changing meaning bumps `DOCUMENT_VERSION`; a field added does not.

Credentials: `APK_MQTT_USERNAME`/`APK_MQTT_PASSWORD` for the event session and the retained status (sent to our
brokers only, never a public one); blank is anonymous.

Retained topics are published only when the container's **state** fingerprint changes, and a topic whose subject
disappears is tombstoned with a zero-length retained payload.

### Docker for the discovery engine — `SRC/manager/docker_bus.py`

DockTor is the only holder of the Docker socket (Dockers golden rule, law 9), so the discovery engine asks here.
Started by `serve()` (the long-running process), on its own session (built by `bus.new_client`) under its own
broker identity: `APK_DOCKTOR_MQTT_USERNAME`/`APK_DOCKTOR_MQTT_PASSWORD` (`apkaudio-docktor`).

**Who may ask is decided at the broker.** MQTT 3.1.1 does not tell a subscriber who published. Under
DATABUS.Broker.MQTT's operator ACL (`SRC/acl.local`) only `apkaudio-docker-engine` may publish the request and only
`apkaudio-docktor` may hear it or write a reply; anonymous clients and the operator are denied both. On the plain
anonymous broker this session connects anonymously and says so (`DOCKER_BUS_SERVING` `"authenticated": false`).

| Topic | Retain | Direction | What |
|---|---|---|---|
| `APK.audio/System/ContainerManager/docker/request` | no | engine → DockTor | `{id, reply, method, path}`; never a body |
| `APK.audio/System/ContainerManager/docker/reply/<client>` | no | DockTor → engine | `{id, status, body}` — the daemon's status and body, or DockTor's 403 |

Allowed (the old `APK-Docker-Gate` list): `GET /containers/<n>/json`, `POST /containers/<n>/start`,
`…/stop?t=<digits>`, `…/kill?signal=<SIG>`, `DELETE /containers/<n>?force=&v=` (the inspect is kept first in
`<storage>/docker-kept/<n>.json`, or `APK_DOCKER_KEPT_DIR`), `POST /apk/recreate/<n>` (create + start from that kept
inspect; 404 when none), `GET /apk/health` (the daemon's `/_ping`) — for `^(Plugin-|APK-|apk-)[A-Za-z0-9_.-]+$`
names only. Anything else is a 403 without asking the daemon; a `reply` outside `…/docker/reply/` gets no answer.

**The instrument launcher's three** (NODE.BareMetal `docktor_client.py`, identity `apkaudio-baremetal-launcher`;
BM-11 — the node holds no socket):

| Call | Admitted when |
|---|---|
| `GET /containers/json?all=<bool>&filters={"label":["apk.audio.role=instrument"]}` | exactly that filter (no other key); DockTor re-encodes it before forwarding |
| `GET /images/<image>/json` | `<image>` (URL-decoded) is an instrument image: `APK_INSTRUMENT_IMAGE` (comma-separated), default `apk-plugins:local` |
| `POST /apk/instrument/<name>` + `"body"`: the create document | `docker_bus.instrument_problems()` is empty: name `^apk-[a-z0-9_.-]+$`; keys only `Image Env Labels Cmd HostConfig`; the instrument image; `Labels["apk.audio.role"] == "instrument"` and no `com.docker.compose.*` / `apk.audio.protected` label; `HostConfig` keys only `NetworkMode` (= `host`), `RestartPolicy`, `Mounts`, `Binds` — so no `Privileged`, `CapAdd`, `Devices`, `PidMode`…; every mount a `bind` (keys `Type Source Target ReadOnly`) whose source is under the INSTRUMENTS or PLUGINS host tree (`APK_INSTRUMENT_BIND_ROOTS`, default `<APKAUDIO_REPO>/PODS/POD.THICK/{INSTRUMENTS,PLUGINS}`), no `..`. Answers the daemon's `201 {"Id"}` (or 409); the inspect is kept so `/apk/recreate/<name>` works |

`"body"` on any other call is a 403. Tests: `SRC/manager/test_instrument_calls.py`.
Tests: `SRC/manager/test_docker_bus.py`.

## HTTP — `127.0.0.1:8765`

The route table is `ROUTES` in `SRC/manager/api.py` and is served at `GET /api/routes`. No authentication; the
loopback bind is the control.

## Script protocol

`runner.run_management_script(name, args, on_line)` → `(exit_code, text)`. A line matching
`^@EVENT\s+([A-Z_]+)\s*(\{.*\})?\s*$` is lifted onto the bus; every line also goes to the screen / SSE log.

## Validation

The contracts validator runs from the repository root: `npm --prefix contracts run validate`.
