# Architecture — MANAGER.Docktor

How to use DockTor and how it works inside. Bus topics and the HTTP surface in full:
[CONTRACTS.md](../CONTRACTS.md).

← [Wiki home](../README.md)

## Use

```sh
./K8:runner.py                                                    # APK.audio root door: launch
python3 'PODS/POD.manager/MANAGER.Docktor/bin/K8:runner.py' serve --open
PODS/POD.manager/MANAGER.Docktor/K8/manager.sh up|down|restart|logs|status|url
PODS/POD.manager/MANAGER.Docktor/K8/up-stack.sh 'PROTOCOL.DEV.EMBER'
```

Page: `http://localhost:8765/`. `GET /api/routes` lists the API.

## Three layers

1. **Verbs — `K8/*.sh`.** One docker verb per file. `_common.sh` holds the shared rules: compose arrays,
   stack order, `is_protected_container`, `ensure_broker`, `plugin_roles_declared`, `MANAGER_URL`.
   `SRC/docker scripts` is a symlink to `../K8` (the in-image name).
2. **Package — `SRC/manager/`.** Import order `paths` → `bus` → `palette` → `runner` → `brief` →
   `readers` → `diagnose` → `report` → `api` → `serve` → `cli` (module map in `__init__.py`).
   - `paths.py` — the named rungs (`DOCKERS_DIRECTORY`, `DOCKER_SCRIPTS_DIRECTORY`, `REPOSITORY_ROOT`).
   - `bus.py` — `BROKER_HOST`/`BROKER_PORT`, `emit()`; owns publishing.
   - `runner.py` — `run_management_script()`; parses `@EVENT` lines out of script output.
   - `readers.py` — every `read_*()` that turns a script's output into data (containers, stacks, volumes,
     cost ledger, page titles…).
   - `diagnose.py` — `diagnose_state()`: a container's state into a colour and a sentence.
   - `report.py` — the retained topic tree; `run_reported()` wraps a script run with bus reporting.
   - `api.py` — `action_table()`, `ROUTES`, `run_action()`, `chat()`; `command_queue.py` serialises
     actions.
   - `serve.py` — `ManagerHandler` / `ManagerServer` (stdlib `ThreadingHTTPServer`), `LogStream` (SSE).
   - `cli.py` — terminal verbs, `USAGE`.
3. **Client — `SRC/manager/web/`.** `index.html`, `manager.css`, `manager.js`; no framework, no build.
   Served from `WEB_ROOT` (`serve.py`).

## Data flow of one action

Browser `POST /api/action/<key>` → `api.run_action()` → `CommandQueue` (one at a time) →
`report.run_reported()` → `runner.run_management_script()` → `K8/<verb>.sh`. Each output line goes to the
execution log (SSE `/api/stream`) and each `@EVENT` line to `emit()` → `APK.audio/System/ContainerManager`.
The exit code comes back with the text; a refresh re-reads containers and republishes changed retained
state.

## The container

`Docker/Dockerfile.manager`: `docker:27-cli` + python3 + compose + mosquitto-clients + paho-mqtt; it COPYs
`SRC/manager`, `K8` and `bin/K8:runner.py` into `/app/APK:DOCKERS/…`, plus `contracts/tokens/brand.json` and
BareMetal's `mqtt_broker_discovery.py`. `CMD` runs `K8:runner.py serve`.

`Docker/docker-compose.manager.yml` (project `apk-audio`, service `manager`, container `DockTor`):
`network_mode: host`, `init: true`, binds `127.0.0.1:8765`, mounts the Docker socket and the checkout at the
same absolute path (`APKAUDIO_REPO`, set by `K8/manager.sh up`), plus log and storage volumes.
Healthcheck: `/api/health`.

## Files

| Path | Role |
|---|---|
| `bin/K8:runner.py`, `bin/docktor` | front doors (`launch` by default; `docktor` defaults to `serve`) |
| `SRC/manager/` | the package above |
| `K8/` | the verbs |
| `K8/config_helper.py` | config reader for the scripts |
| `SRC/APK.audio:mount.sh`, `SRC/APK.audio:DeleteOldRebuildAndMount.sh` | named front doors into `K8/` |
| `SRC/page-titles.json` | remembered page titles for endpoint cards |
| `SRC/manager/test_readers_idle.py` | readers stay quiet at idle |
