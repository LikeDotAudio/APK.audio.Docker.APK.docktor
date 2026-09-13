# Dockers — the philosophy

*What each container on this bench is, and why it is its own container rather than a
process inside another one. Counts measured 2026-09-10 on `APK-Shop` against the tree at
`f8564298e`; every claim below cites the file that already carries it.*

A **docker**, here, is one entry in a compose file under `APK:DOCKERS/<stack>/Docker/`. A
**stack** is a compose file that carries a top-level `name:` — that is not a convention,
it is the definition `stacks.sh`
reads, because `name:` is what docker itself groups containers by, and it is what separates
a stack ROOT from an overlay (`docker-compose.hardware.yml`, `.host.yml`, `.macvlan.yml`
declare no project and are meant to be a second `-f`).

Nine stacks. **Twenty-six containers declared, twenty-four of them on a default bench** —
the other two sit behind a `profiles:` key. **Five compose PROJECTS, not nine**: five stacks
declare `name: apk-audio` and clump as one group in `docker ps`, and the other four keep a
project each. Eleven named volumes, every one of them pinned by an explicit `name:`.

**Nothing here is split because splitting is the docker style.** Nine programs run inside
one container on this bench, and one image runs as two containers. Each law below is a
reason a boundary exists, and each cites both the file that already obeys it and the file
in the same tree that deliberately does the opposite.

---

## The bench at a glance

| stack | project | containers | why it is a stack of its own |
|---|---|---|---|
| `Server:Storage:SQL database/` | `apk-audio` | 5 | the state: MariaDB, its schema, the PHP that reads it, the nginx in front |
| `APK:audio:WebPortal/` | `apk-audio` | 2 | the bus and the clock of the central bench |
| `APK:BareMetal/` | `apk-audio` | 1 | the TERMINAL NODE image — one container per machine, host networking |
| `Server:Broker:MQTT/` | `apk-audio` | 2 | the bus as a subject: a broker to work on, and the thing that records it |
| `DockTor/` | `apk-audio` | 1 | the tool that looks at the others — the only holder of the docker socket |
| `Server:Discovery:NMOS/` | `nmos` | 4 (+2) | somebody else's specification furniture, plus the two devices we ship into it |
| `PROTOCOL:DEV:AES70/` | `aes70` | 2 | somebody else's library, on an interpreter this bench does not otherwise have |
| `Server:Ember/` | `ember` | 2 | a real Ember+ provider three of our own readers had been dialling for months |
| `Server:Netbox/` | `netbox` | 5 | the inventory, and a database nothing else may reach |

---

## 1. A container is a LIFETIME, not a program

> **The law.** Two programs go in two containers when they must be allowed to die
> separately. If they die together anyway, they are one container.

`Portal-Heartbeat` is the WebPortal stack's own image with a different `command:` — the
same build the removed orchestrator service used — and it is a service of its own for one
stated reason:

> *"Its own service and not a thread inside the orchestrator, because the orchestrator
> restarts whenever a panel rebuild goes wrong and a clock that stops when something
> unrelated stops is not a clock. Same image, so it costs a process and no extra build."*
> — `APK:audio:WebPortal/Docker/docker-compose.yml`

That is the whole test, and note what it does not say: nothing about separation of
concerns, nothing about one-process-per-container. It is a restart-domain argument, and it
is priced — a process, no second build.

**The counter-example is `Node-BareMetal`, and it is deliberate.** One container runs
**nine** agents (`SRC/agents.json`, measured 2026-09-10) under a supervisor that is PID 1.
They are not nine containers because they share the one thing a container boundary would
have to cut: a network stack with raw-packet capability on it, and the same `/dev`. Nine
host-networked containers with `NET_RAW`, `NET_ADMIN` and `NET_BIND_SERVICE` each is nine
copies of the privilege and one bench that still fails together.

The roster carries the same reasoning per agent, which is why it is data and not code:

> *"`enabled` is the DEFAULT, and every entry can be overridden per box with
> `APK_AGENT_<ID>=on|off` … A terminal machine with no puck on it turns spacenavigator off
> without a second image."* — `APK:BareMetal/SRC/agents.json`

**Both halves of the heartbeat decision are written where they are read.** It is a
container in the WebPortal stack and `"enabled": false` in the node's roster, and the
roster says why:

> *"OFF by default … The metronome is ONE clock for the whole bench: every terminal machine
> beating its own would put N phase-locked publishers on the same topics, and a subscriber
> cannot tell them apart."*

## 2. A container is a NETWORK POSTURE

> **The law.** Two services that need opposite networking cannot share a container, and no
> project name changes that — `network_mode` is a per-service setting.

Three postures exist here and none of them is DHCP; docker ships no DHCP client in any
bundled driver, so no container in this repository is ever handed a lease.

| posture | who | the container's address |
|---|---|---|
| bridge + `127.0.0.1:` mappings | the portal, both brokers, NMOS, AES70, Ember, NetBox | `172.2x.0.x`, NAT'd |
| `network_mode: host` | `Node-BareMetal`, `DockTor` | none — it IS the host |
| macvlan, alongside the bridge | `Server:Storage:SQL database/docker-compose.macvlan.yml` | its own `44.44.44.x`, static |

**Multicast does not cross a docker bridge.** That single fact decides three boundaries on
this bench: the node is host-networked, `Protocol-nmos` cannot live in the NMOS stack at
all, and `discover` in the AES70 workbench needs `docker-compose.host.yml`. The failure it
prevents is not a loud one:

> *"The failure is subtle rather than obvious: the DNS-SD agent still finds whatever the
> host advertises and resolves every address to the bridge gateway, so devices look
> discovered, at the wrong address, and no LAN instrument ever appears."*
> — `APK:BareMetal/Docker/docker-compose.yml`

**And the posture decides what a variable means.** `MQTT_HOST` on a host-networked node is
`127.0.0.1`; on a bridged container it is `host.docker.internal` with an `extra_hosts`
entry. One name carrying both values, exported in a shell that has no network mode, is
what PLAN-351.01 measured: `mqtt-store` at 22 restarts, `protocols` `unknown`, the node
`degraded`, nothing loud. Both stacks now read a name of their own —
`APK_BAREMETAL_MQTT_HOST` and `APK_NMOS_MQTT_HOST` — and default it per posture.

## 3. A container is a RUNTIME FLOOR

> **The law.** When two pieces of one product need different interpreters, toolchains or
> base images, the boundary is already drawn; drawing it in the compose file is only
> writing it down.

`Storage-Portal` and `Storage-PHP` serve one website and are two containers because
`nginx:alpine` has no PHP interpreter — a `COPY` of the API into the portal image would
serve the front controller as text. `Storage-PHP` publishes nothing at all:

> *"the interpreter is not exposed to the LAN the way the broker and the database above are
> — nginx is the only thing that can reach it."*
> — `Server:Storage:SQL database/Docker/docker-compose.yml`

The same law explains the other three "why is this not just a folder" stacks:

- **AES70** — `requires-python = ">=3.12"` is upstream's floor, and pip enforces it by
  failing at resolution naming the *package*, so on a 3.11 bench the cause reads as a
  broken dependency. The container IS the interpreter.
- **Ember** — the provider is a C++ build, and `cmake` cannot run on this source on the
  host at all: *"Run cmake against `Server:Ember/` on the host and GNU make stops with
  `target pattern contains no '%'` — a colon is make's rule separator."* Inside the image
  the source is at `/opt/ember` and make is content.
- **NetBox** — five upstream images, no Dockerfile, nothing built and nothing bound. Two
  Valkeys and a Postgres are not our runtime at all.

## 4. Someone else's software gets its own PROJECT

> **The law.** The `apk-audio` project is the group a reader takes to be things we ship.
> Software that is somebody else's, run as a bench instrument, keeps a project of its own —
> being *driven* by our verbs does not fold it into our project.

Four stacks are outside: `nmos`, `aes70`, `ember`, `netbox`. `_common.sh` states it as two
decisions rather than one omission, and NetBox adds a second reason that is about blast
radius rather than about reading:

> *"`--remove-orphans` IS NOW A WEAPON. Under a shared project every container from the
> other files is an orphan of the file you passed, so the flag deletes the rest of the
> ecosystem."* — `_common.sh`

Four of NetBox's five containers hold or serve `netbox_postgres-data`, which *is* the
inventory. A flag typed against another compose file must not be able to reach it.

**The counter-example is the bridge, and it was asked as a defect and answered NO.**
`APK-NMOS-Bridge` is ours and it lives inside the specification's stack:

> *"'Ours lives inside a stack of the specification's furniture' was asked as a defect
> (PLAN-428.01) and answered NO on 2026-09-07: the seam it proposed is ownership, the seam
> anybody wants is optionality, and `nmos-registry` sits on opposite sides of the two."*

The naming carries the ownership instead — `APK-NMOS-Bridge` rather than `NMOS-…`, an
`apkaudio-` image, `APK:audio:` on every label it writes into the registry — and the one
thing that would have been lost by splitting is the only enforced cross-service dependency
on the bench: `depends_on: nmos-registry: condition: service_healthy`. Compose cannot
express that across files.

## 5. Optional weight is a `profiles:` key, not a sixth compose file

> **The law.** A container nobody needs on a normal day is declared in the same file and
> switched off, not moved somewhere a person has to remember.

`NMOS-Testing` is **732 MB of that stack's 1,087** and `APK-NMOS-Facade` is the thing it
drives; both carry `profiles: ["conformance"]`, so no verb here starts them without
`APK_NMOS_PROFILES=conformance` (PLAN-948.01). The reader agrees with the compose file
rather than guessing: `stacks.sh` counts a profiled service as **declared to compose and
not to the bench**, so it is never `absent`, never dark, never `stopped` — which is what
keeps a healthy bench from reporting two faults it does not have.

## 6. A one-shot EXITS, and the compose file says so

> **The law.** `restart: "no"` on anything that finishes. A finished one-shot sitting
> `Exited (0)` is the happy path, and every reader on this bench has to know that.

`Storage-Schema-Init` runs on every `up` and exits:

> *"IDEMPOTENT, WHICH IS WHAT LETS IT RUN EVERY TIME. Every statement in
> `schema.scanalyzer.mariadb.sql` is `CREATE TABLE IF NOT EXISTS` … `restart: "no"` — a
> one-shot that has finished its work has EXITED, and `unless-stopped` would restart it
> forever."*

It is also the answer to a cross-stack ownership question, which is the interesting half:
`Broker-SqlCapture` in the *broker* stack needs the `delta-capture` schema, authored in
*APK:BareMetal*, in a database owned by the *storage* stack. One container applies every
schema in that database including the ones it did not author — because "who applies the
schema" has to have exactly one answer. Before PLAN-999.01 nothing on the `up` path applied
it: it was hand-applied twice, each `down -v` threw it away, and the capture restart-looped
`unless-stopped` for ever against a database that could never satisfy it.

**The readers were taught the same rule.** `stacks.sh` scopes its `stopped` column to
containers whose compose file promised `restart:` — *"a column that named them would fire on
the happy path every poll, and a warning that fires on the happy path is learnt as noise and
then does not work on the day it is true."*

## 7. The state is a volume, and every volume is pinned by name

> **The law.** Compose derives a volume's real name from the project. Any stack that might
> ever share a project pins `name:` explicitly, and the pinned name is the one already on
> disk.

Eleven named volumes, and **four separate `broker-data` keys** that would have collapsed
onto one another when the stacks folded into `apk-audio`:

| the key, in four compose files | pinned to |
|---|---|
| `Server:Storage:SQL database/docker-compose.yml` | `apk-audio_broker-data` |
| `APK:audio:WebPortal/docker-compose.yml` | `apkaudio_broker-data` |
| `Server:Broker:MQTT/docker-compose.yml` | `apk-audio-mqtt_broker-data` |
| `APK:BareMetal/docker-compose.broker.yml` (overlay) | `apkaudio-baremetal_broker-data` |

`apkaudio-baremetal_baremetal-state` holds the MQTT exchange database — *"not a cache"* —
and `prune.sh` refuses volumes for exactly this reason, in its own words: *"`docker volume
prune` counts a volume as unused whenever no container is attached RIGHT NOW"*, which on a
bench that has just been stopped is all of them.

## 8. Configuration is COPYed into the image, because a bind cannot be spelled

> **The law.** No compose bind mount in this repository may name a source path containing a
> colon, and every directory under the checkout has one. Configuration therefore goes in at
> build time, and the price is `--build` on every `up`.

Measured 2026-09-04 on Docker 29.1.3: compose re-serialises even the long `type: bind` form
back into `source:target:mode` on its way to the daemon, which refuses the lot. There is no
spelling that fixes compose.

The consequence is a property of every container here worth stating plainly: **a container
on this bench is a photograph of the tree at build time.** Editing `conf/`, `aes70py/` or an
API endpoint and pressing restart changes nothing — the image is the same image. That is
what `⚡ N containers are running an image that was built before the code inside it` on the
manager's dashboard is measuring, and what `staleness.sh` compares: the image's build time
against the newest file its Dockerfile COPYs in.

**The two exceptions are exceptions to the PATH, not to the law.** The checkout root is the
one useful path in this repository with no colon in it, so `DockTor` and
`Ember-Provider` bind *the root* and reach their file underneath. Ember does it because the
CSVs are re-read by a running provider every 250 ms — a file edited on the host is served
within about a second, no rebuild, no restart — and the manager does it because
`docker compose build` hands the DAEMON a context path, so the checkout must exist at the
same absolute path on both sides. `${APKAUDIO_REPO}` is spelled identically as source and
target for that reason: *"they are not allowed to differ, and writing them twice is how they
come to."*

## 9. One container holds the docker socket, and the mount IS the privilege

> **The law.** The tool that starts, stops and rebuilds the bench is a container like the
> rest, and it is the only one with `/var/run/docker.sock`.

> *"a container with this socket can start any container it likes as any user it likes, so
> the mount IS the privilege and `user:` would not reduce it."*
> — `DockTor/Docker/docker-compose.manager.yml`

Two consequences are load-bearing and both are one line each. `APK_MANAGER_BIND:
127.0.0.1` — on the host network there is no port mapping left to confine it, so that line
is the only thing between an unauthenticated rebuild API and the LAN. And the manager is
spared by `panic.sh`, because it is the process running the script and the page the button
is on; the second press of panic is a *different script*, started detached as a sibling
container, since a compose client cannot survive recreating the container it runs in.

---

## The roll call

### `Server:Storage:SQL database/` — the state · project `apk-audio`

| container | image | published | why it is its own |
|---|---|---|---|
| `Storage-MariaDB` | `mariadb:11.4` | `3306`, every interface | the engine; the volume `apk-audio_mariadb-data` is the corpus |
| `Storage-PHP` | `storage-php:local` | nothing | php-fpm — `nginx:alpine` has no interpreter (law 3) |
| `Storage-Schema-Init` | `storage-php:local` | nothing | a one-shot; `restart: "no"`; owns every schema in the database (law 6) |
| `Storage-Portal` | `storage-portal:local` | `8080 → 80` | nginx and the static trees |
| `Storage-Broker` | `storage-broker:local` | `1883` / `9001`, every interface | the bus every other process on the bench actually speaks on |

`Storage-Broker` is `restart: always` and not `unless-stopped`, and its config is baked
into the image by `Server:Broker:MQTT/Docker/Dockerfile.broker`. That is the fix for a real
outage: the config used to be staged into `/tmp` and bound, `/tmp` is cleared on reboot, and
the daemon creates a missing bind source as a root-owned directory — so the broker came back
with a directory over its config and refused every connection on 1883 until `sudo rm -rf`.

**Read the SECURITY NOTE at the top of that compose file before touching a port.**
`allow_anonymous true` and a loopback bind are a PAIR, and only the second half was ever a
control; this stack publishes on all interfaces. The bus is not a passive transport —
publishing to `APK.audio/System/Protocols/visa/Device/+/+/+/Write` executes that payload as
SCPI on real lab hardware.

### `APK:audio:WebPortal/` — the bus and the clock · project `apk-audio`

| container | image | published | why it is its own |
|---|---|---|---|
| `Portal-Broker` | `eclipse-mosquitto:2.0` | `1885` → 1883, `9003` → 9001, loopback | a second bus is a real second bus, so it is renumbered rather than shared |
| `Portal-Heartbeat` | `portal-heartbeat:local` | nothing | law 1 — a clock that stops when a panel rebuild stops is not a clock |

**There is no `orchestrator:` service here and that is the decision.** It declared one for
months and it never started once: the node declares the same program in `agents.json` and
runs `network_mode: host`, so its agent binds the host's 8000 and every `up` of this file
ended in `address already in use`. *"Two declarations of one program is not a port clash to
renumber"* — both mounted and wrote the same `Gui_Frames`, so a WYSIWYG save landing in one
was invisible to the other's cache.

### `APK:BareMetal/` — the terminal node · project `apk-audio`

One container, `Node-BareMetal`, `network_mode: host`, `NET_RAW` + `NET_ADMIN` +
`NET_BIND_SERVICE`, running as the invoking host user. Nine agents under a supervisor that
is PID 1; the status server answers `127.0.0.1:8100`. Two overlays beside it:
`docker-compose.broker.yml` (this node runs its own mosquitto) and
`docker-compose.hardware.yml` (`/dev/input`, `/dev/serial`, `/dev/snd`).

**The only thing a new terminal machine is told is where the bus is.** A reinstall copies
the compose file and sets `APK_BAREMETAL_MQTT_HOST`. Everything else about a terminal
machine is the same everywhere, which is the point of shipping one image — and it is why
this stack is one container and not nine (law 1).

### `Server:Broker:MQTT/` — the bus as a subject · project `apk-audio`

| container | image | published | why it is its own |
|---|---|---|---|
| `Broker-Mosquitto` | `eclipse-mosquitto:2.0` | `1884` / `9002`, loopback | a broker to work ON, not the house broker |
| `Broker-SqlCapture` | `broker-sqlcapture:local` | nothing | records what changed on the bus, and when |

This folder held four mosquitto configs that three other stacks mounted, and started
nothing. `apkaudio-sql`'s DeltaEngine already existed and only ever ran in-process inside
the orchestrator; here it is a container beside the broker it listens to (PLAN-298.01).

**The database is deliberately not in this stack** — *"a second mariadb here would be a
second copy of the one table that is supposed to be the timeline."* And the capture's
default host is `mqtt`, the *storage* stack's broker, not the one this stack starts:
capturing its own broker recorded nothing but the agent's own status echo, and
`bus_delta` held 0 rows across 45 sessions while the bus itself was busy. *"The failure is
silent and reads as calm."*

### `DockTor/` — the tool · project `apk-audio`

One container, `DockTor`, host-networked, holding the socket and the checkout. It is
the ninth compose file and the one `for_each_stack` does not drive — `manager.sh` and
`panic-reboot.sh` are its verbs, for the recursion reason in law 9. Its API is the
dashboard the rest of this ecosystem is watched from, and `up-stack.sh` refuses to remount
this stack from inside it.

### `Server:Discovery:NMOS/` — the specification bench · project `nmos`

| container | image | published | what it is |
|---|---|---|---|
| `NMOS-Registry` | `nmos-cpp:local` | 3209 · 3210 · 3211 · 3213 · 10641 | IS-04 Registration + Query, IS-09 System |
| `NMOS-Node` | `nmos-cpp:local` | 3212 · 3215 · 3216 · 3217 | the mock device — 55 senders, 55 receivers |
| `NMOS-Sandbox` | `nmos-sandbox:local` | 3208 | nginx holding the dashboard |
| `APK-NMOS-Bridge` | `apkaudio-nmos-bridge:local` | 3218, loopback | **ours** — one NMOS Device per element the DataBus carries |
| `NMOS-Testing` | `nmos-testing:local` | 5000 · 5001 | the AMWA suite — `profiles: ["conformance"]`, 732 MB |
| `APK-NMOS-Facade` | `apkaudio-nmos-facade:local` | nothing | **ours** — the controller under test; profiled, `restart: "no"` |

Registry and node are **one image**; the entrypoint's `RUN_NODE` test picks the binary. Both
upstream bases are pinned by digest — `rhastie/nmos-cpp@sha256:c54c8de…` and
`amwa/nmos-testing@sha256:99a411d…` — never by tag, because *"`latest` on a conformance suite
means the gate's meaning changes without a commit."*

### `PROTOCOL:DEV:AES70/` — the AES70 workbench · project `aes70`

| container | image | published | why |
|---|---|---|---|
| `AES70-Dev` | `aes70py-dev:local` (250 MB) | nothing | a controller is a client — it publishes nothing by definition |
| `AES70-Site` | `aes70py-site:local` (64.5 MB) | `3220 → 80` | aes70py.org mirrored, 8 pages, offline |

**What decided that this starts with the bench**, when *"a developer might want it"* is not
a reason to start a container everywhere: `AES70-Site` publishes a page somebody at the
bench opens, and *"a page that is only there when somebody remembered to type a compose
command is a page nobody finds."* The workbench container rides along because neither
declares a dependency in either direction.

### `Server:Ember/` — the Ember+ bench · project `ember`

| container | image | published | why |
|---|---|---|---|
| `Ember-Provider` | `ember-provider:local` | `9000`, loopback | a real GLOW tree over S101/TCP |
| `Ember-Docs` | `ember-docs:local` | `3221 → 80` | Lawo's three specification PDFs, offline |

This stack exists because three readers in this repository had been dialling `127.0.0.1:9000`
for months — a protocol tester, an agent's `config.ini` published retained on the bus, and a
BER reader tested only against hand-written fixtures. *"A port the ecosystem's own code names
is not a port to leave to whoever remembered a compose command."*

### `Server:Netbox/` — the inventory · project `netbox`

| container | image | published |
|---|---|---|
| `Netbox-App` | `netboxcommunity/netbox:v4.7.0-5.1.0` | `8081 → 8080`, loopback |
| `Netbox-Worker` | same | nothing |
| `Netbox-Postgres` | `postgres:18-alpine` | nothing |
| `Netbox-Valkey` | `valkey/valkey:9.1-alpine` | nothing |
| `Netbox-Valkey-Cache` | `valkey/valkey:9.1-alpine` | nothing |

Five upstream images, five digests pinned in `upstream.json`, no Dockerfile and no bind
mount — the simplest stack here to reason about, because every decision it makes is a line
in its own compose file. **Nothing on the bench waits for it and it waits for nothing:** it
brings its own database and its own queue and speaks to no broker. Its place in
`for_each_stack` is about a stable log; do not grow a `depends_on` across that boundary,
because compose cannot express one across projects.

---

## What is deliberately NOT a container

- **The node's nine agents** (law 1). They share a network stack and a `/dev`; splitting
  them multiplies the privilege and changes nothing about how they fail.
- **`APK:API/`** — PHP source living under the storage stack because that is the stack it is
  written against, and in no image at all. `Server:Storage:SQL database/Dockerfile` copies
  static trees into `nginx:alpine`; a `COPY` of this folder would serve the front controller
  as a text file. Two things run it: cPanel's PHP on `apk.audio`, and a test lane locally.
- **`Protocol-nmos`** — an IS-04/IS-09 mDNS discovery browser with no binary, driven by the
  orchestrator's discovery worker under host networking. It cannot be in the NMOS stack
  (law 2), and `lib.rs` declares `STATUS = "discovery-only"`: APK.audio calls no NMOS HTTP
  API at all.

---

## Current drift

Measured 2026-09-10 on this bench. These are findings, not laws.

| what | measurement |
|---|---|
| a tenth compose file that is not a stack | `APK:Yo/Docker/docker-compose.yml` carries **no top-level `name:`**, so by this tree's own definition it is an overlay: `stacks.sh` skips it, no verb drives it, and `panic.sh` would remove its container host-wide with nothing to bring it back |
| …and its port is already taken | it declares `ports: "8080:8080"` on `network_mode: host`, and `8080` is `Storage-Portal`'s. Two of the three postures in law 2 in one service block |
| ~~stray output in the checkout root~~ **MOVED 2026-09-11** | two files whose NAMES contained a backslash — `ember-csv-logs\log_2026-9-6.log` and `…-7.log` — which is the shape of the Windows-backslash defect `Server:Ember/`'s own table documents. `WORKDIR /var/lib/ember` is what contains it inside the image, so these were written by something running outside one. They now sit in `APK:Documentation/LOGS/ember-csv-logs/`, renamed to the path upstream meant to write; that lane's `INDEX.md` declares where an application log file is allowed to land and keeps the original spellings. **The cause is closed too**: `include/Logger.hpp` took the one APK.audio edit in that vendored tree — a writable-first resolution of `$EMBER_LOG_DIR` → the LOGS lane via `$APKAUDIO_REPO` → relative `ember-csv-logs/`, joined with a forward slash. The container still takes the third branch by design (read-only checkout, `/var/lib/ember` scratch). Argued at `upstream.json`'s `the_one_edit` and at the Dockerfile's third-defect block |
| prose against a roster that shrank | `APK:DOCKERS/README.md` still calls the orchestrator *"agent #25 of `agents.json`"*; the roster is **9** entries, of which 2 are disabled by default |
| one image is 1.23 GB | `storage-portal:local` — nginx plus static trees — against `aes70py-site:local`'s **64.5 MB** for the same nginx job. All three repo-root contexts share one `/.dockerignore` and none of them can trim the context for itself (README rule 3) |

---

## Where to start

**Adding a tenth stack is a fixed price, and it is seven files.** `Server:Ember` paid it in
PLAN-670.01 and AES70 before it; the list is in `_common.sh`'s own note:

1. `_common.sh` — the compose file path, its array, its per-stack verdict paragraph, and
   its row in `compose_for_stack` (which is what `up-stack.sh` and `free-ports.sh --stack`
   resolve a stack name through).
2. `for_each_stack` — a name in the order, forward and reverse.
3. `compose.sh`, `free-ports.sh`, `verify.sh`, `stacks.sh`, and both panic scripts.
4. If the compose file interpolates anything with `:?`, the `export` that fills it.

**And before writing the compose file, answer these four in its header:**

- What must be allowed to die without taking the rest with it? (law 1)
- What networking does it need, and what does that make `MQTT_HOST` mean inside it? (law 2)
- Is any of it somebody else's software? Then it is a project of its own. (law 4)
- What in it is optional on a normal bench? That is a `profiles:` key. (law 5)

**Reading one:** start at the top-level `name:`. If it is `apk-audio`, the containers you
are looking at are grouped with four other files and `--remove-orphans` would delete them.
Then read the volume keys — if one has no pinned `name:`, it is one project fold away from
being handed an empty one.

**Related:** `APK:DOCKERS/README.md` for the file-by-file
account · `Bare Metal` for the node's own laws ·
`ARCHITECTURE.md` for the rings ·
`Hazards` for what happens when these are ignored.
