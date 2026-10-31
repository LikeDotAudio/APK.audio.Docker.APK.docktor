# Delivery — MANAGER.Docktor

How DockTor is built, tested and shipped, and where it lands.

← [Wiki home](../README.md)

## Where it lands

The **DockTor** container on each bench host: image built from `Docker/Dockerfile.manager` with the
APK.audio root as context, run by `Docker/docker-compose.manager.yml` (compose project `apk-audio`).
Page and API at `http://localhost:8765/` — loopback only, there is no public URL.

## Build and ship

1. Commit here; push this submodule (`.apk.scripts/deploy_all.py` at the APK.audio root pushes every
   submodule) and bump the pointer in the root.
2. Rebuild the image on the bench: `K8/up-stack.sh docktor` or `K8/manager.sh up`. The dashboard runs the
   **copy baked into the image** (`/app/APK:DOCKERS/APK:docktor/SRC/…`), so edits to `K8/*.sh`,
   `SRC/manager/*.py` or `web/` take effect only after this rebuild. `up-stack.sh` refuses to recreate the
   manager from inside DockTor; run it from a host terminal.
3. Check: `curl -s localhost:8765/api/health` and `curl -s localhost:8765/api/endpoints`.

## Test

```sh
./check.sh              # py_compile, every unit test (36), bash -n K8/*.sh, compose config; starts nothing
./check.sh --gates      # … plus K8/test-gates.sh
K8/naming.sh            # includes plugin-includes.sh
K8/test-gates.sh        # pre-build gates (against a bench)
K8/verify.sh            # post-mount checks (against a running bench)
```

Smoke (`.apk.scripts/smoke.py`): HEAD is on origin — [SMOKE.md](../%F0%9F%A7%A9Manual%20and%20Artifacts/SMOKE.md).

## Not automated

- No CI workflow (the root CI verifies nothing by design); `./check.sh` is run by hand before a push.
- Nothing rebuilds the DockTor image when this repo changes; a stale image keeps running old scripts.
- `verify.sh` and `test-gates.sh` need a live Docker host and are run by hand or from the dashboard.

## Delivered from the 2026-10-30 audit

DockTor is the bench's container manager (`docker-compose.manager.yml`, container `DockTor`). Everything below
reaches the dashboard only after the owner rebuilds it (`K8/up-stack.sh MANAGER.Docktor` from a host shell —
the dashboard runs its baked copy). Verified: `./check.sh` (36 unit tests, bash -n, compose config: 0 failed) and
`docker build -f Docker/Dockerfile.manager .` with the unit tests run inside the image (OK, `api_version` 1,
`contract_version` 0.2.0).

- **Docker bus behind a broker identity** — `docker_bus.py` connects as `apkaudio-docktor`
  (`APK_DOCKTOR_MQTT_USERNAME`/`_PASSWORD`, passed through `docker-compose.manager.yml`), and
  DATABUS.Broker.MQTT's operator ACL (same batch, its DELIVERY) lets only `apkaudio-docker-engine` publish
  `ContainerManager/docker/request` and only DockTor hear it or reply — a bus client can no longer stop or kill a
  `Plugin-*` container. Broker-Mosquitto stays protected: nothing here restarts it. **Takes effect on the owner's
  next mint + broker restart with the operator overlay**, and needs the engine's credentials first (handoff to
  DISCOVERY.Engine, `launcher/docker/bus.rs`), or the engine loses Docker. Tests: `test_bus_identity.py`; the ACL
  itself by the broker's `SRC/test_operator_acl.sh` checks 10–14. The HTTP API on :8765 stays unauthenticated
  and loopback-only — Kept by design (PRINCIPLES.md: host networking, the bind is the boundary, `serve.py` warns
  that widening needs an authenticating proxy).
- **Schemas for the retained documents + a test + one check command** — `SRC/manager/schemas/` holds JSON Schemas
  for `status`, `Manager`, `containers/…` and `…/apps/…`; `report.py` gained `status_document()` and
  `app_document()` builders and `test_report_documents.py` validates every builder's output (dependency-free
  validator). `./check.sh` runs it with all unit tests, bash -n and compose config (`--gates` adds
  `K8/test-gates.sh`). No new CI gating: the root CI verifies nothing by design.
- **One paho constructor, chat through the bus** — `bus.new_client()` builds every session (event,
  docker bus) with one credential rule; `api.chat()` publishes on `bus.py`'s event session instead of a
  `publish.single` of its own; `report.py` sends `APK_MQTT_*` credentials to our brokers only. The event and
  docker-bus sessions stay two on purpose: the second carries its own broker identity and callbacks.
- **Legacy path candidates deleted** — `paths.py` keeps one spelling each for the BareMetal SRC and the brand
  token (the image now stages both at the same relative places as the checkout); the eight pre-2026-10-16
  spellings are gone.
- **Versioned API and documents** — `api.API_VERSION` (1) and every route under `/api/v1/…`;
  `bus.DOCUMENT_VERSION` (1) as `doc_version` in every retained document; `/api/health` reports
  `api_version`, `document_version` and `contract_version`. Tests in `test_api_routing.py`.
- **api.py routing tests** — `test_api_routing.py`: every table's script exists; unknown verb 127; stack verb
  names its stack; a stack verb in container scope refused; container verb argument order; the kill-pid prompt
  pattern enforced server side; a bench verb without a prompt ignores extra arguments.
- **Contracts package adopted** — the image pip-installs `apkaudio_contracts`; `bus.py` takes ROOT and
  `broker_auth`, `docker_bus.py` the `containerManagerDocker*` families, and `test_bus_identity.py` holds every
  DockTor topic equal to the contracts' builders.
- **Hand endpoint rows yield to labels** — `K8/endpoints.sh` skips its hand rows for any container that carries
  `audio.apk.purpose` + `audio.apk.endpoint.*` labels, and the plugin-config row is now for `Plugin-*`/`Worker-*`
  only. Broker-Mosquitto's labels are in (DATABUS.Broker.MQTT); the other owners' are handoffs (see IMPROVEMENTS).
- **Kept by design** — DockTor runs the baked copy of `K8/*.sh` (an edit needs a rebuild; the image must be a
  whole program, Dockerfile header), and the in-image `/app/APK:DOCKERS/APK:docktor` spellings (nothing outside
  the image resolves them).

### From the SDK/contracts audit (2026-10-30, LOOSE-sdk-manager-docktor)

- **WB-04 broker sessions authenticate** — delivered in the round above: `bus.credentials()`/`bus.new_client()`
  apply `APK_MQTT_USERNAME`/`APK_MQTT_PASSWORD` (via `apkaudio_contracts.broker_auth`) to the event session,
  `report.py` passes `auth=` to `publish.multiple` for our brokers only, chat rides the event session, the docker
  bus has its own identity (`APK_DOCKTOR_MQTT_*`), and `docker-compose.manager.yml` passes all four variables.
  Tests: `test_bus_identity.py`.
- **WB-04 ContainerManager topics from the contracts** — the families exist now (W01: `containerManagerEvent`,
  `…Status`, `…Manager`, `…Container`, `…App`, `…DockerRequest`, `…DockerReply`); `docker_bus.py` builds its pair
  with them and `test_bus_identity.py` holds `bus.py`'s event/status/Manager topics and the docker pair equal to
  the builders. The engine side already builds with credentials (`launcher/docker/bus.rs`
  `APK_DOCKER_BUS_MQTT_*`, W02). **Open: `APK.audio/System/Chat`** has no contract family yet — Waiting on
  contracts (handoff filed); `api.py` spells it from the contracts' ROOT until then.
- `K8/topics.sh` attributes the agent id `BareMetal_MQTT_Exchange` (DATABUS.agent.MQTT's new AgentHeartbeat at
  `System/Agents/…`) to Node-BareMetal.

### For NODE.BareMetal BM-11 (2026-10-30): the instrument launcher asks DockTor

- **Three more docker-bus calls, checked** — `docker_bus.py` admits the instrument list (only the
  `apk.audio.role=instrument` filter, re-encoded), the instrument image inspect (only `APK_INSTRUMENT_IMAGE`,
  default `apk-plugins:local`), and a new `POST /apk/instrument/<name>` whose body `instrument_problems()` checks
  field by field before `/containers/create` (rules in CONTRACTS.md: `^apk-` name, instrument image, host
  networking, the role label, no compose/protected labels, no HostConfig key beyond NetworkMode/RestartPolicy/
  Mounts/Binds, binds only under the INSTRUMENTS and PLUGINS trees). Broker-Mosquitto stays out of reach: its
  name, image and compose labels are all refused. The inspect is kept so `/apk/recreate` works. The compose file
  passes `APK_INSTRUMENT_IMAGE` / `APK_INSTRUMENT_BIND_ROOTS`. Tests: `test_instrument_calls.py` (7: admitted
  calls, 11 refused shapes, 22 refused create documents, binds, settings, and the envelope against a fake daemon).
  Live after the owner rebuilds DockTor; the asker `apkaudio-baremetal-launcher` is admitted by
  DATABUS.Broker.MQTT's operator ACL (same batch).

### Final round (2026-10-30)

- **Nothing of another repo's copied in (DockTor #1)** — contracts 36273b972 ships `broker_candidates` and the
  brand/state tokens as package data, so `brokers.py` imports `apkaudio_contracts.broker_candidates` only and
  `paths.py` takes `ACCENT` from `apkaudio_contracts.tokens.BRAND_ACCENT_HEX`; the image's COPYs of NODE.BareMetal's
  `mqtt_broker_discovery.py` and `contracts/tokens/brand.json` are deleted, along with `BAREMETAL_ROOT`. A host run
  without the package installed uses the checkout's own `contracts/python` (put on `sys.path` in `paths.py`, one
  place). Verified: 43 unit tests with and without contracts on `PYTHONPATH`; `docker build` + the tests inside the
  image (accent `#f4902c`, `apkaudio_contracts.broker_candidates`).
- **System/Chat from the contract (WB-04)** — delivered by the peer session in `c4600d5` (`systemChat` family).
- **`x-apk-every-role: true` (for PLUGIN.MACHINE)** — `K8/plugin-includes.sh` accepts this top-level marker for a
  plugin that must run on every node: its services carry no `profiles:` (compose starts them under any role), and
  a `profiles:` line under the marker is the new `every role` error. Checked: the helpers on a sample file; the
  current tree still passes.
- **apk-yo purpose** — `K8/purpose.sh` now describes CONTROL.YoControl as the bus chat agent with an opt-in
  WebSocket on WS_PORT, built from its own repo.
- **NetBox port read, not restated** — `K8/endpoints.sh` takes Netbox-App's declared port from
  DATABASE.server.NETBOX's `"127.0.0.1:<port>:8080"` line.

### Go-live of the operator ACL (2026-10-30, owner-approved, run by the coordinator)

- **Live** — Broker-Mosquitto runs the operator overlay; DockTor's docker-bus session is authenticated
  (`DOCKER_BUS_SERVING "authenticated": true`); an engine-identity `docker/request` round trip answers 200; an
  anonymous `docker/#` subscriber receives nothing. The "takes effect after the owner restarts" notes above are
  now history.
- **Remounts keep their credentials** — a watchdog remount of DISCOVERY.Engine (compose run inside DockTor) had
  brought the engine back with blank `APK_DOCKER_BUS_MQTT_*` and Plugin-MACHINE with blank `APK_MACHINE_MQTT_*`.
  `docker-compose.manager.yml` now forwards every stack identity (`APK_DOCKER_BUS_MQTT_*`, `APK_LAUNCHER_MQTT_*`,
  `APK_MACHINE_MQTT_*`, `APK_MQTT_OPERATOR_*`, beside `APK_DOCKTOR_MQTT_*` and `APK_MQTT_*`), so every up-stack,
  rebuild or watchdog remount inside DockTor interpolates them. Values come from the exported
  `~/.apk.secrets.env` when DockTor is started, never from git. `test_forwarded_env.py` fails when any compose
  file under PODS/ names an `APK_…MQTT…_USERNAME/_PASSWORD` the manager does not forward (it fails on the old
  compose). DockTor recreated from a host shell with the envelope exported: all six identities present.
- **Instruments are never compose services** — instruments run `apk-plugins:local`, which compose built, so a
  container inherited its `com.docker.compose.*` labels. `instrument()` now reads the image's labels and sets
  each `com.docker.compose.*` one to `""` in the create (`blank_inherited_compose_labels`); the requester still
  may not send any. Tests in `test_instrument_calls.py`.
- **Broker endpoint rows removed** — Broker-Mosquitto carries its `audio.apk.endpoint.*` labels live, so its two
  hand rows in `K8/endpoints.sh` are gone; the label block prints the same two rows.
- **Hand-kept endpoint table gone (DockTor #4)** — Storage-Portal, SQL-Proxy, Netbox-App, NMOS-Dev and
  Ember-Provider were recreated with their `audio.apk.endpoint.*` labels (checked with `docker inspect`), so their
  18 hand rows, and the now-unused `emit_endpoint` / `self_described` / `published_port` / `lan_endpoints`
  helpers, are deleted from `K8/endpoints.sh`. The label block prints the same rows (2+1+3+10+1, plus the
  broker's 2), and `endpoints.sh --completeness` still accounts for every published port. The dashboard picks this
  up when DockTor is rebuilt (it runs its baked K8 copy).

### Label-driven endpoint list (owner decision 2026-10-30)

- **`GET /api/endpoints/labels`** — read-only JSON array `[{container, stack, kind, url, label, purpose,
  running}]` built from the `audio.apk.endpoint.*` / `audio.apk.purpose` labels (`K8/endpoints.sh --labels` →
  `api.label_endpoints_from`). Listed in `/api/routes`; `/api/v1/…` alias. Tests: `test_label_endpoints.py`
  (shape, order, stack, malformed labels, script failure); against the live bench it returns 33 rows. Reaches the
  dashboard after the next DockTor rebuild (baked copy). Browsers off the bench reach it only once
  WEB.Traffic-Router adds a read-only path — handoff filed (the gateway deliberately does not route DockTor, and
  a bridged Caddy cannot dial the host loopback DockTor binds); NMOS.Server's consumption is a handoff to P07.

