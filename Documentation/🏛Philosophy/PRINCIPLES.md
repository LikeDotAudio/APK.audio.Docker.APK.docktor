# Principles — MANAGER.Docktor

The principles DockTor keeps, each pointed at the code that keeps it. Ecosystem rules are not repeated:
the Dockers and Tests doctrine is in this lane's `Dockers/` and `Tests/` copies (canonical:
`Documentation/🏛Philosophy/` at the APK.audio root).

← [Wiki home](../README.md)

## Every docker verb is one file; Python never runs docker

The package holds no compose command, `docker ps` format, port or container name. The only way out is
`run_management_script()` (`SRC/manager/runner.py:220`), which runs one `K8/*.sh` and returns
`(exit_code, text)` — the exit code is half the answer, so a failed rebuild is never drawn green.

## A new verb is a row, not a branch

`CLI_ACTIONS` / `CLI_ACTIONS_WITH_ARGS` (`SRC/manager/cli.py:33`, `:48`) for the terminal; `action_table()`
(`SRC/manager/api.py:514`) for the browser; `ROUTES` (`SRC/manager/api.py:1094`) is the HTTP surface and is
served back by `GET /api/routes`.

## One build, every screen

`launch` (the bare `K8:runner.py`) starts DockTor if nothing serves and hands the verb to it over the API,
so the build lands in the shared execution log (SSE `/api/stream`, `LogStream` in `SRC/manager/serve.py:57`)
— `K8/launch.sh`. One action runs at a time; the rest wait in `CommandQueue`
(`SRC/manager/command_queue.py:31`).

## Say it once: terminal, bus, browser

Scripts print `@EVENT NAME {json}`; the runner relays it to `APK.audio/System/ContainerManager` through
`emit()` (`SRC/manager/bus.py:133`). Every publish — events, retained state, chat — goes to `BROKER_HOST`
(`SRC/manager/bus.py:37`, `MQTT_HOST`/`APK_MQTT_HOST`), never a literal loopback: `chat()` in `api.py`
was the last one that broke this and now imports it.

## Events are not retained; state is, and only on change

Events go out with `retain=False` (`bus.py:159`). Retained container state is fingerprinted and published
when it moves, and tombstoned with a zero-length retained message when its subject goes
(`SRC/manager/report.py:114`, `publish_refresh_status()` at `:309`).

## One container holds the socket, on loopback

DockTor is the only container that mounts `/var/run/docker.sock`. Its API stops containers and has no
authentication, so it binds `127.0.0.1` (`APK_MANAGER_BIND` in `Docker/docker-compose.manager.yml`,
`serve(bind="127.0.0.1")` at `SRC/manager/serve.py:692`). The discovery engine, which raises and reaps plugin
containers, mounts no socket of its own: it asks DockTor over the bus (`SRC/manager/docker_bus.py`), and DockTor
answers only the five container calls for `^(Plugin-|APK-|apk-)` names plus a recreate from an inspect it kept.

WHO MAY ASK IS THE BROKER'S CALL, not DockTor's (2026-10-30 audit): MQTT 3.1.1 does not tell a subscriber who
published, so a check inside DockTor would be a check of nothing. DockTor's docker-bus session connects as its
own identity (`apkaudio-docktor`), and DATABUS.Broker.MQTT's operator ACL lets only `apkaudio-docker-engine`
publish the request. The HTTP API stays unauthenticated **by design**: on host networking the loopback bind is
the boundary, and widening it needs an authenticating proxy in front (`serve.py` says so at start).

## The bus and the manager are protected

`is_protected_container()` (`K8/_common.sh:673`) keeps DockTor and Broker-Mosquitto out of every routine
verb; `ensure_broker()` (`K8/_common.sh:713`) brings the broker up first and alone — with the
operator ACL overlay (`DATABUS.Broker.MQTT/Docker/docker-compose.operator.yml`) once the bench has minted
`SRC/operator/passwd` and `acl`, so a broker the owner put on that ACL never comes back without it
(`broker_compose_files`); `K8/up-stack.sh` refuses to recreate the manager from inside itself. Only `nuke.sh --yes-nuke-everything
--include-manager`, typed at a host terminal, takes DockTor.

## Destruction needs consent typed by a person

`nuke` without `--yes-nuke-everything` only rehearses, and nothing in the CLI supplies that token
(`K8/nuke.sh`). In the browser the last confirm of a destructive verb needs a typed word (`ask()` /
`askAll()` in `SRC/manager/web/manager.js`).

## A plugin describes itself; DockTor keeps no plugin table

Roles are read off plugin compose `profiles:` (`plugin_roles_declared()`, `K8/_common.sh:348`); purpose and
endpoints off `audio.apk.*` labels, then the compose files, then (only for a declared container nothing else
describes) a plugin's retained `incoming/api` (`K8/purpose.sh`, `K8/endpoints.sh`). `K8/plugin-includes.sh` (run by `K8/naming.sh`) fails when the engine's
include list and the `PLUGINS/` folder disagree, or when an included file's shared volume block drifts from
`plugin-base.yml`'s (one drifted copy breaks every plugin's `include:`).

## One walker finds every stack

`config_helper.compose_files()` (`K8/config_helper.py`) is the only thing that looks for
`<stack>/Docker/docker-compose*.yml`, at any depth; `stacks.sh`, `staleness.sh`, `remove-other-containers.sh`,
`api.declared_projects()` and `config_helper` itself all ask it. A fixed number of rungs is a glob that matches
nothing in silence. `stacks.sh` leaves out `PLUGINS/`: a plugin's lifecycle belongs to the discovery engine, and
the watchdog would otherwise remount every plugin the engine executed.

Membership is read off the parent's own `include:` block, never typed: a stack that another stack's primary
`docker-compose.yml` `include:`s (a `POD.<x>` root, or `DISCOVERY.Engine` for every `PLUGIN.*`) is walked by
`up`/`down`/`rebuild-all` only through that parent (`config_helper.included_files()`), stays `driven` in
`stacks.sh`, and is still reachable by its own name in `up-stack.sh`. The broker's `portal-broker` overlay is not a
primary file, so the web stacks it includes are still walked on their own. A folder whose name starts with `_`
(`PLUGINS/_template`) is a support folder, never a stack: it is not walked, and asking for it by name or path
(`up-stack.sh _template`) is refused by `compose_for_stack`.

## Every image signs itself with its repository's commit

`stamp_image_rev` (`K8/_common.sh`) exports `APK_IMAGE_REV` (short HEAD of the repository holding the stack's
compose file, `-dirty` for uncommitted tracked changes, `unstamped` when git cannot answer) and `APK_IMAGE_BUILT`
before `up-stack.sh`, `rebuild-stack.sh` and each stack of `for_each_stack` builds. A value the caller exported
first is a pin and wins. The DockTor image carries `git` for this.

## Where the code still falls short

- The dashboard runs the scripts **baked into the image**, not the bind-mounted checkout: an edit to
  `K8/*.sh` does nothing until DockTor is rebuilt (see [DELIVERY](../%F0%9F%8C%8DPublishing/DELIVERY.md)).
  Kept by design: the image must be a whole program — a manager that is only the mount starts, finds no code
  and exits (Dockerfile header).
- In-image paths still say `APK:DOCKERS` / `APK:docktor` (`Docker/Dockerfile.manager`); the host checkout's root
  is `PODS/`. Kept by design: nothing outside the image resolves them, and `paths.py` walks from `__file__`.
- Until `apkaudio_contracts` carries the broker-candidate module and the brand token, the image still COPYs
  NODE.BareMetal's `mqtt_broker_discovery.py` and `contracts/tokens/brand.json` (handoff to contracts filed);
  `brokers.py` already prefers the package.
- No runner publishes a `description` in `incoming/api` yet, so `K8/purpose.sh`'s third source answers nothing.
- `K8/purpose.sh` still keeps a written table for containers that are not plugins.
