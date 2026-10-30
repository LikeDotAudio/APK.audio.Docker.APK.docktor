# 🐳 MANAGER.Docktor — the container manager: scripts, API, browser client, bus

DockTor runs the bench. Every docker verb is one shell script in `K8/`; a Python package (`SRC/manager/`)
serves those scripts as an HTTP API with a browser client, runs them from a terminal, and announces everything
that happens on the bus. It is the only container that holds the Docker socket.

| | |
|---|---|
| **Family** | MANAGER — runs the pods |
| **Category** | Container manager: bash verbs + Python HTTP API/SSE + vanilla-JS client + MQTT publisher |
| **Pipeline Stage** | Operations — outside the audio pipeline; it starts, stops, rebuilds, verifies and reports every other stack |
| **Web Portal Entry** | `http://localhost:8765/` (bind `127.0.0.1`, `APK_MANAGER_PORT`); `GET /api/routes` lists the API |
| **Compose project** | `apk-audio` (`Docker/docker-compose.manager.yml`, service `manager`, container `DockTor`) |
| **Pod** | `PODS/POD.manager/` |

**Wiki:** [Documentation/README.md](Documentation/README.md) — principles, architecture, delivery, audits.

## Layout

| Path | What |
|---|---|
| `bin/K8:runner.py` | The front door. Bare: **launch** — start DockTor if nothing serves, open the page, hand `up` to it over the API, exit. Also `serve`, `status`, `up`, `down`, `endpoints`, … (the `CLI_ACTIONS` tables in `SRC/manager/cli.py`) |
| `bin/docktor` | Same package, defaults to `serve` |
| `SRC/manager/` | The package (`paths` → `bus` → `palette` → `runner` → `brief` → `readers` → `diagnose` → `report` → `api` → `serve` → `cli`; module map in `__init__.py`). `web/` is the client: `index.html`, `manager.css`, `manager.js`, no framework, no build |
| `K8/*.sh` | One verb per file (`up`, `down`, `up-stack`, `rebuild-all`, `rebuild-stack`, `endpoints`, `verify`, `test-gates`, `free-ports`, `panic`, `nuke`, `phoenix`, `volumes`, …). `_common.sh` holds the shared rules: compose arrays, stack order, `is_protected_container`, `ensure_broker`, `MANAGER_URL` |
| `K8/config_helper.py` | Config reader for the scripts |
| `SRC/docker scripts` | Symlink → `../K8` (the in-image name) |
| `SRC/APK.audio:mount.sh`, `SRC/APK.audio:DeleteOldRebuildAndMount.sh` | Named front doors that dispatch to `K8/` (`up`/`watch`/`status`/`rebuild`/`down`, and `rebuild-all.sh`) |
| `Docker/Dockerfile.manager`, `Docker/docker-compose.manager.yml` | The DockTor image and container |
| `Documentation/CONTRACTS.md` | DockTor's bus topics and HTTP surface |
| `Documentation/🏛Philosophy/` | Copies of the ecosystem's Dockers and Tests doctrine (canonical copies: `Documentation/🏛Philosophy/` in APK.audio) |
| `Documentation/🔍Audits/` | Dated audit records (history, not current state) |

## The container

`docker:27-cli` + python3 + compose + mosquitto-clients + paho-mqtt. `network_mode: host`, `init: true`.
Mounts: `/var/run/docker.sock`; the checkout at **the same absolute path** on both sides (`APKAUDIO_REPO`), so
build contexts it hands the daemon resolve to the same bytes; `apk-audio-logs` (binds
`Documentation/LOGS`) and `docktor-storage` (binds `Documentation/STORAGE/DockTor`). Healthcheck: `/api/health`
reports a containerised instance whose PID is alive.

⚠️ **The dashboard runs the scripts baked into the image**, at `/app/APK:DOCKERS/APK:docktor/SRC/docker scripts/`,
not the bind-mounted checkout. After editing `K8/*.sh`, rebuild DockTor: `K8/up-stack.sh docktor` (or
`K8/manager.sh up`), then check with `curl -s localhost:8765/api/endpoints`.

## Run

```sh
python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8:runner.py'               # launch: DockTor, the page, the mount
python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8:runner.py' serve --open  # the manager in this terminal
PODS/POD.manager/MANAGER.Docktor/K8/manager.sh up|down|restart|logs|status|url
PODS/POD.manager/MANAGER.Docktor/K8/up-stack.sh 'PROTOCOL.DEV.EMBER'      # one stack
```

`manager.sh up` is what sets `APKAUDIO_REPO`; the compose file refuses to start without it.

## HTTP API (`SRC/manager/api.py` `ROUTES`)

`GET /api/{health,routes,palette,actions,containers,resources,stacks,staleness,endpoints,volumes,cost,log,stream,queue}`,
`GET /api/{container,surface,ping,config-script}/<name>`, `POST /api/{queue/cancel,chat,cost,log/clear}`,
`POST /api/action/<key>`. Action keys (`action_table()`):

- bench: `up`, `rebuild-all`, `rebuild-core`, `down`, `remove-other`, `clear-dead`, `panic`, `verify`, `gates`,
  `clear-logs`, `free-ports`, `prune`, `clean-cache`, `clean-cache-all`, `storage-volume`, `list-pids`,
  `kill-pid`, `nuke`, `phoenix`, `disk`
- per container: `restart`, `rebuild`, `remove`, `logs` · per stack: `up-stack`, `rebuild-stack`,
  `restart-stack`, `down-stack`
- protected (never stopped/removed): `manager` (DockTor), `broker` (Broker-Mosquitto)

One action runs at a time; the rest queue (`/api/queue`).

## Testing

Measured 2026-10-30:

- `cd SRC && python3 -m pytest -q manager/test_readers_idle.py` — 10 passed.
- `python3 -c "import manager.api, manager.serve, manager.cli"` from `SRC/` — imports headless, no display.
- `bash -n` passes on every `K8/*.sh` and `SRC/*.sh`; every script named in `cli.py` / `api.py` exists.
- Against a running bench: `K8/test-gates.sh` (pre-build gates) and `K8/verify.sh` (post-mount checks).

## Philosophy

What DockTor actually does, and where:

- **Every docker verb is one file, and Python never runs docker.** No compose command, `docker ps` format, port or
  container name in the package; `runner.run_management_script()` is the only way out —
  `SRC/manager/__init__.py`, `SRC/manager/runner.py`, `K8/`.
- **A new verb is a row, not a branch** — `CLI_ACTIONS` / `CLI_ACTIONS_WITH_ARGS` in `SRC/manager/cli.py`.
- **The exit code is half the answer.** `run_management_script` returns `(exit_code, text)` so a failed rebuild
  is never drawn as a green tick — `SRC/manager/__init__.py`.
- **No window, ever.** The Tkinter dashboard was deleted; the API, transport and client are separable and run
  headless where the containers are — `bin/K8:runner.py`, `SRC/manager/serve.py`.
- **One build, every screen.** `launch` hands the verb to the running DockTor so the build lands in the shared
  execution log (SSE `/api/stream`) instead of one terminal — `SRC/manager/cli.py`, `K8/launch.sh`.
- **Say it once: terminal, bus, browser.** Scripts print `@EVENT NAME {json}`; the runner relays it to
  `APK.audio/System/ContainerManager` while it goes to the screen — `SRC/manager/runner.py`, `SRC/manager/bus.py`.
- **Events are not retained; state is, and only on change.** Retained status is fingerprinted per container
  state and tombstoned with an empty payload when its subject goes — `SRC/manager/bus.py`, `SRC/manager/report.py`.
- **One container holds the socket, on loopback** (Dockers law 9): API bound to `127.0.0.1` because it stops
  containers and has no authentication — `Docker/docker-compose.manager.yml`, `serve` usage in `cli.py`.
- **The bus and the manager are protected.** No routine verb stops DockTor or Broker-Mosquitto; `ensure_broker`
  brings the broker up first and alone; `up-stack.sh` refuses to recreate the manager from inside itself; only
  `nuke.sh --yes-nuke-everything --include-manager`, from a host terminal, takes DockTor — `K8/_common.sh`,
  `K8/up-stack.sh`, `K8/nuke.sh`.
- **Destruction needs consent typed by a person.** `nuke` without `--yes-nuke-everything` only rehearses, and
  nothing in the CLI supplies the token — `SRC/manager/cli.py`, `K8/nuke.sh`.
- **Never `--remove-orphans`.** The project is shared with the stacks it watches — `K8/manager.sh` header.
- **A role selects plugins; a plugin is never named in a list here.** The node's roles are read off the
  `profiles:` of the plugin compose files (`desktop` among them since PLAN-3410.01) — `plugin_roles_declared`
  in `K8/_common.sh`.
- **The engine's include list and the PLUGINS/ folder agree, or the check fails.** Each plugin compose says
  `x-apk-plugin: true` or `x-apk-standalone: "<why>"`; `K8/plugin-includes.sh` (run by `K8/naming.sh`) fails on
  an unmarked file, a marked one the list misses, a dangling path, a marked service with no profile
  (PLAN-3395.01), or an included file whose `apk-audio-logs` / `mac-lookup-cache` volume block differs from
  `Docker/plugin-base.yml`'s — `include:` refuses the whole engine stack over one such copy.
- **A plugin describes itself; DockTor keeps no plugin table.** Each plugin compose service carries
  `audio.apk.purpose` (+ `.what`, `.why`) and `audio.apk.endpoint.<n>: "<open|copy> <uri> <label>"`;
  `K8/purpose.sh` and `K8/endpoints.sh` read them with `docker inspect`, then the compose files on disk, then,
  for a declared container neither describes, a plugin's retained `incoming/api` `description` (no runner
  publishes one yet). The written table in `purpose.sh` is for the containers
  that are not plugins (PLAN-3409.01).

## Roadmap

No plans live here. Open work for DockTor is on the ecosystem roadmap,
`Documentation/🛣Roadmap/roadmap.htm` in the APK.audio repository.

<!-- wiki:smoke -->
**Smoke test** — ✅ PASS 1/1 since 2026-10-30 12:51 EDT — [results](Documentation/%F0%9F%A7%A9Manual%20and%20Artifacts/SMOKE.md)
<!-- /wiki:smoke -->
