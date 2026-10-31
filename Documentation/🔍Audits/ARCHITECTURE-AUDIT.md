# 🔍 Architecture audit — MANAGER.Docktor (2026-10-30)

Audited against the APK.audio multi-repo architecture standard: coupling, boundaries, duplication, contracts.
← [Audits](INDEX.md) · Improvements: [🛣Roadmap/IMPROVEMENTS.md](../%F0%9F%9B%A3Roadmap/IMPROVEMENTS.md)

## Bounded context
DockTor, the bench's container manager and the only holder of the Docker socket. It does stack up/down/rebuild, status, endpoints, logs, gates and panic, and acts as a Docker-over-MQTT proxy for the discovery engine. It is a Python package (`SRC/manager`, about 7,000 lines) with an HTTP API and web UI on `127.0.0.1:8765`, driving about 55 bash verbs in `K8/` (about 13,000 lines). 103 tracked files, about 23,000 lines. Sampled: `Docker/Dockerfile.manager`, `Docker/docker-compose.manager.yml`, `SRC/manager/{paths,bus,docker_bus,report,api,serve}.py` (topics, imports, sys.path), `K8/endpoints.sh`, `K8/test-gates.sh` header, the two `test_*.py`, [CONTRACTS.md](../CONTRACTS.md). Not read line by line: `web/manager.js` (3,912 lines), most K8 verbs.

## Context map
| Talks to | How (topic / endpoint / file / import) | Relationship |
|---|---|---|
| Docker daemon | `/var/run/docker.sock` mount, raw socket client (`SRC/manager/docker_bus.py:99-102`), `docker compose` CLI | External, owned exclusively |
| Every stack in `PODS/` | the checkout is bind-mounted at its host path. K8 verbs run each stack's `Docker/docker-compose.yml`, read `audio.apk.purpose*` / `audio.apk.endpoint.*` labels (`K8/endpoints.sh:362-398`), and keep 20 hand rows in `emit_endpoint` (`K8/endpoints.sh:170-…`) | Upstream to everything. Partly label-driven (Published Language), partly a shared table |
| NODE.BareMetal | Dockerfile COPYs `PODS/POD.THICK/NODE.BareMetal/SRC/Baremetal:Manager/mqtt_broker_discovery.py` (transitional); `brokers.py` imports it only when `apkaudio_contracts.broker_candidates` is absent | Shared Kernel by file copy (unversioned), on its way into the contracts package |
| root `contracts/` | Dockerfile pip-installs `contracts/python` (`apkaudio_contracts`, versioned) — topic root, families, `broker_auth`; still COPYs `contracts/tokens/brand.json`, read by `paths.py` with no fallback | Shared Kernel as a versioned package (+ one token file) |
| DISCOVERY.Engine | `APK.audio/System/ContainerManager/docker/request` → `…/docker/reply/<client>` (`docker_bus.py`), with an allow-list of `Plugin-|APK-|apk-` names; DockTor connects as `apkaudio-docktor`, and the broker's operator ACL admits only `apkaudio-docker-engine` as the asker | Customer–Supplier over the bus, authorized at the broker |
| OS / dashboards | retained `APK.audio/System/ContainerManager/{status,Manager,containers/<Stack>/<Name>[/apps/<App>]}` (each with `doc_version`), events on `…/ContainerManager`, `APK.audio/System/Chat` | Published Language ([CONTRACTS.md](../CONTRACTS.md), JSON Schemas in `SRC/manager/schemas/`, tested) |
| PLUGIN.* | `K8/new-plugin.sh` scaffolds from `POD.THICK/PLUGINS/_template`. `K8/plugin-includes.sh` enforces the include/`drift` rules | Governs (Open Host for the plugin convention) |
| Broker-Mosquitto | protected: brought up first and alone, never stopped (house rule) | Conformist |

## Scorecard
| Category | Score (0–3) | Finding |
|---|---|---|
| Coupling & Cohesion | 2 | The contracts arrive as the versioned `apkaudio_contracts` package and `paths.py` has one spelling per path; two files are still COPYed (BareMetal's broker list, the brand token) until the package carries them, and 18 hand endpoint rows wait on their owners' labels. The whole-checkout mount plus the socket is intrinsic to the job |
| Boundary Integrity | 3 | The Docker-over-bus proxy is allow-listed, reply-confined, and now authorized at the broker (only `apkaudio-docker-engine` may ask). The HTTP API is loopback-only and unauthenticated by design (host networking; PRINCIPLES) |
| Duplication Control | 3 | One paho constructor (`bus.new_client`) and one credential rule; chat rides the event session; topics come from the contracts' families and a test holds them equal; endpoints yield to labels |
| Testing & Contracts | 3 | 36 unit tests over docker bus, readers, report documents vs JSON Schemas, bus identity and API routing; `./check.sh` runs them with bash -n and compose config |
| Change management | 3 | `API_VERSION` + `/api/v1/…`, `doc_version` in every retained document, `contract_version` in `/api/health`; legacy path spellings removed. Baked K8 scripts and in-image `APK:DOCKERS` spellings are kept by design (PRINCIPLES) |
Score key: 3 meets the standard · 2 minor gaps · 1 significant gaps · 0 absent / violated.

## Findings
1. **Good: one socket holder.** `docker_bus.py` replaces the old APK-Docker-Gate. Only inspect, start, stop, kill, delete and `/apk/recreate/<n>` on `^(Plugin-|APK-|apk-)…$` names are allowed, everything else is a 403 without asking the daemon, and replies are confined to `REPLY_BASE`. Since this audit the asker is authorized at the broker. `test_docker_bus.py` covers it.
2. **Good: self-describing containers.** `K8/endpoints.sh` reads `audio.apk.endpoint.<n>` labels from `docker inspect`, so plugins declare their own endpoints, and a labelled container's labels now win over any hand row.
3. **Good: secure by default.** `APK_MANAGER_BIND=127.0.0.1` is baked into the image, with the reason given (host networking means no boundary). `serve.py` warns that widening the bind needs an authenticating proxy.
4. **Two files still copied in.** `Docker/Dockerfile.manager` COPYs NODE.BareMetal's `mqtt_broker_discovery.py` and `contracts/tokens/brand.json` (both marked TRANSITIONAL). Waiting on foundation W01: the contracts package to carry the broker-candidate module and the brand token (handoff filed); `brokers.py` already prefers the package.
5. **Hand-kept port table, shrinking.** `K8/endpoints.sh` still carries 20 `emit_endpoint` rows for other repos' containers; Broker-Mosquitto's two go once its labels are live, and the other 18 wait on their owners' labels (handoffs filed). DATABASE.server.NETBOX's probe still parses this file to find its own port.

6. **Chat outside every contract family.** `APK.audio/System/Chat` (`api.py` `CHAT_TOPIC`) is spelled from the contracts' ROOT but no family declares it (SDK/contracts audit WB-04). Waiting on contracts (handoff filed).

Findings on the `sys.path` call sites, the legacy path spellings, the two MQTT clients and the chat bypass, the unauthenticated docker bus, the thin tests and the missing versions were delivered — see [🌍Publishing/DELIVERY.md](../%F0%9F%8C%8DPublishing/DELIVERY.md).
