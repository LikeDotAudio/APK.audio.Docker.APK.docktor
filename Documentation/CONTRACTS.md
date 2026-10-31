# Contract Bindings — `MANAGER.Docktor`

Part of the **APK.audio** contracts framework (`contracts/` at the APK.audio repository root:
`@apkaudio/contracts` for TypeScript, `apkaudio-contracts` for Rust, `apkaudio_contracts` for Python).
DockTor does not import `apkaudio_contracts`; its topics are spelled once, in `SRC/manager/bus.py`.

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
| `APK.audio/System/Chat` (`CHAT_TOPIC` in `api.py`, not under `TOPIC_ROOT`) | no | `POST /api/chat`, every action start/result | one human-readable line; published to `127.0.0.1:1883` directly, not via `bus.py`'s broker settings |

Retained topics are published only when the container's **state** fingerprint changes, and a topic whose subject
disappears is tombstoned with a zero-length retained payload.

### Docker for the discovery engine — `SRC/manager/docker_bus.py`

DockTor is the only holder of the Docker socket (Dockers golden rule, law 9), so the discovery engine asks here.
Started by `serve()` (the long-running process), on its own client.

| Topic | Retain | Direction | What |
|---|---|---|---|
| `APK.audio/System/ContainerManager/docker/request` | no | engine → DockTor | `{id, reply, method, path}`; never a body |
| `APK.audio/System/ContainerManager/docker/reply/<client>` | no | DockTor → engine | `{id, status, body}` — the daemon's status and body, or DockTor's 403 |

Allowed (the old `APK-Docker-Gate` list): `GET /containers/<n>/json`, `POST /containers/<n>/start`,
`…/stop?t=<digits>`, `…/kill?signal=<SIG>`, `DELETE /containers/<n>?force=&v=` (the inspect is kept first in
`<storage>/docker-kept/<n>.json`, or `APK_DOCKER_KEPT_DIR`), `POST /apk/recreate/<n>` (create + start from that kept
inspect; 404 when none), `GET /apk/health` (the daemon's `/_ping`) — for `^(Plugin-|APK-|apk-)[A-Za-z0-9_.-]+$`
names only. Anything else is a 403 without asking the daemon; a `reply` outside `…/docker/reply/` gets no answer.
Tests: `SRC/manager/test_docker_bus.py`.

## HTTP — `127.0.0.1:8765`

The route table is `ROUTES` in `SRC/manager/api.py` and is served at `GET /api/routes`. No authentication; the
loopback bind is the control.

## Script protocol

`runner.run_management_script(name, args, on_line)` → `(exit_code, text)`. A line matching
`^@EVENT\s+([A-Z_]+)\s*(\{.*\})?\s*$` is lifted onto the bus; every line also goes to the screen / SSE log.

## Validation

The contracts validator runs from the repository root: `npm --prefix contracts run validate`.
