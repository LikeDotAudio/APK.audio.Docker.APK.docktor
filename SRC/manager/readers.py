# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""📖 Seven scripts print tables; these turn them into dicts.

OWNS parsing and the one-minute resource beat. Parsing is here rather than in
the scripts because the scripts have two audiences — this package and a person
at a terminal — and JSON serves the second badly. The field ORDER is the
contract: written at the top of each script, asserted by the slicing below,
which PADS rather than raises, so a docker version that drops a column costs a
blank field and not a dashboard.
Every function here is a script call. None of them knows what docker is.
"""

import os
import re
import time
import json
import threading

from .bus import emit
from .paths import DOCKERS_DIRECTORY
from .runner import run_management_script, is_any_script_running

RESOURCE_SAMPLE_SECONDS = 60

# Which containers are OURS, read off the compose files rather than guessed. The
# four-substring list it replaces made Storage-Broker ours and Storage-Portal a
# stranger — two containers of one stack drawn five cards apart.
# NOT A COMPOSE PATH: it globs for the files, so a renamed or added stack needs
# no edit. The hint list survives as a fallback for `docker run` containers,
# which declare their name nowhere a file can be read.
_COMPOSE_GLOB_DEPTH = 3
_CONTAINER_NAME = re.compile(r'^\s*container_name:\s*["\']?([^"\'\s#]+)', re.M)
_OURS_HINTS = ('apk', 'apkaudio', 'baremetal', 'spog', 'orchestrator')
_declared_names = None


def declared_container_names():
    """Every container name this repository compose files spell out.

    Read ONCE and cached: consulted per card per repaint, and the answer cannot
    change without a file changing. An unwalkable checkout returns the empty
    set, which costs the highlight and nothing else.
    """
    global _declared_names
    if _declared_names is None:
        names = set()
        try:
            for root, directories, files in os.walk(DOCKERS_DIRECTORY):
                depth = root[len(DOCKERS_DIRECTORY):].count(os.sep)
                if depth >= _COMPOSE_GLOB_DEPTH:
                    directories[:] = []
                    continue
                directories[:] = [d for d in directories if not d.startswith('.')]
                for filename in files:
                    if 'compose' not in filename.lower():
                        continue
                    if not filename.lower().endswith(('.yml', '.yaml')):
                        continue
                    with open(os.path.join(root, filename), encoding='utf-8',
                              errors='replace') as handle:
                        names.update(_CONTAINER_NAME.findall(handle.read()))
        except OSError:
            pass
        _declared_names = names
    return _declared_names


def is_ours(container_name):
    """Did this repository declare this container, or does it look like ours?"""
    if container_name in declared_container_names():
        return True
    lowered = (container_name or '').lower()
    return any(hint in lowered for hint in _OURS_HINTS)


def sample_resources(quiet=False):
    """One `docker stats` sample, parsed. The shape the RESOURCES event carries.

    `quiet` SUPPRESSES THE SCRIPT PAIR and every caller here passes it: RESOURCES
    is emitted on every successful tick and RESOURCES_FAILED on every failed one,
    so the series carries exactly one event per beat either way and a gap still
    reads as a stopped sampler. SCRIPT_START/SCRIPT_RESULT were a second and
    third copy of that beat, which is the budget the rest of this codebase
    already quotes as "the resource sampler ONE".
    ONE ROW PER *RUNNING* CONTAINER, WHICH IS NOT THE BENCH COUNT: docker stats
    reports what is running, ps.sh lists everything. That showed on the bus as
    RESOURCES 24 in the same beat STATUS_PUBLISHED said 25, the difference being
    a one-shot sitting Exited(0). Callers publish this length as `running_count`,
    never as a container count.
    """
    exit_code, output = run_management_script('stats.sh', quiet=quiet)
    if exit_code != 0:
        emit("RESOURCES_FAILED", {"exit_code": exit_code})
        return []
    rows = []
    for line in output.strip().splitlines():
        if not line or line.startswith('@EVENT '):
            continue
        part = (line.split('\t') + [''] * 7)[:7]
        rows.append({"name": part[0], "cpu_percent": part[1], "memory": part[2],
                     "memory_percent": part[3], "net_io": part[4],
                     "block_io": part[5], "pids": part[6]})
    return rows


# The answers, once. Module level rather than an argument or an lru_cache, so
# the whole process shares one — including the sampler thread.
_HOST_BOX = None

# The SAME script, on a clock. host.sh prints the core count and the free space
# in one docker info plus one df, and the two halves want opposite caching (the
# box facts are true for the life of the process, free space is only worth
# printing because it moves), so one short-lived cache of the raw rows serves
# both and a repaint pays for one script call.
# THIRTY SECONDS: a disk fills over minutes at the fastest, so a reading half a
# minute old is the same reading — while a fresh read on every two-second scan
# would put a daemon round trip on the cadence that runs during a rebuild.
HOST_READ_SECONDS = 30
_host_cache = {"at": 0.0, "rows": None}
_host_lock = threading.Lock()

# WHEN TO SAY SOMETHING AND HOW LOUDLY. Percentages of the filesystem under
# docker data root, deliberately well short of full: the point is to be read
# while a database can still WRITE. On 2026-09-09 the first signal anybody got
# was MariaDB failing to open ddl_recovery.log.
DISK_WARNING_PERCENT = 85
DISK_CRITICAL_PERCENT = 95


def _read_host_rows(quiet=True):
    """host.sh key/value rows as a dict, cached for HOST_READ_SECONDS.

    An empty dict when the script will not run: this decorates the page, and a
    probe that fails must not take the grid down. A FAILURE IS NOT CACHED — a
    docker that was down at first load comes back.
    """
    with _host_lock:
        rows = _host_cache["rows"]
        if rows is not None and time.time() - _host_cache["at"] < HOST_READ_SECONDS:
            return rows
        exit_code, output = run_management_script('host.sh', quiet=quiet)
        if exit_code != 0:
            return {}
        rows = {}
        for line in output.strip().splitlines():
            if not line or line.startswith('@EVENT '):
                continue
            key, _tab, value = line.partition('\t')
            rows[key.strip()] = value.strip()
        _host_cache["rows"] = rows
        _host_cache["at"] = time.time()
        return rows


def read_host_disk(quiet=True):
    """Free space on the filesystem docker data root sits on, and a verdict.

    THE NUMBER NOTHING HERE REPORTED: when the root filesystem filled on
    2026-09-09 the first thing that spoke was a database crash-looping, and
    three NetBox containers that exited in the same minute were down for hours
    because nothing said why.
    Returns {} when host.sh will not answer or prints no disk rows, rather than
    a dict of zeroes, so a caller can tell "nothing measured this" from
    "measured, and the disk is empty".
    Otherwise {"root", "filesystem", "total_kb", "used_kb", "available_kb",
    "used_percent", "level"} with `level` ok / warning / critical. The VERDICT is
    here rather than in each caller: one bench, one answer to "is this bad".
    """
    rows = _read_host_rows(quiet=quiet)
    percent = rows.get('disk_used_percent', '')
    if not percent.isdigit():
        return {}
    used_percent = int(percent)
    return {
        "root": rows.get('disk_root', ''),
        "filesystem": rows.get('disk_filesystem', ''),
        "total_kb": int(rows['disk_total_kb']) if rows.get('disk_total_kb', '').isdigit() else 0,
        "used_kb": int(rows['disk_used_kb']) if rows.get('disk_used_kb', '').isdigit() else 0,
        "available_kb": (int(rows['disk_available_kb'])
                         if rows.get('disk_available_kb', '').isdigit() else 0),
        "used_percent": used_percent,
        "level": ("critical" if used_percent >= DISK_CRITICAL_PERCENT
                  else "warning" if used_percent >= DISK_WARNING_PERCENT
                  else "ok"),
    }


def read_host(quiet=True):
    """What the DAEMON says this BOX is: {"cpus": int, "memory_bytes": int}.

    Either field is 0 when docker will not say. Returned together because they
    come off one docker info and are read by the same repaint.
    THE DENOMINATORS sample_resources() DOES NOT CARRY, or carries wrong: every
    cpu_percent is a share of ONE CORE, and nothing in a stats sample says how
    many the box has. The memory column looks like it does — docker reports an
    unconstrained container limit as the whole machine RAM — until one compose
    file sets mem_limit:, at which point the widest limit is a CONTAINER one and
    the ring silently divides by it.
    NOT os.cpu_count() AND NOT /proc/meminfo, which answer about THIS PROCESS:
    os.cpu_count() reads the caller affinity and cgroup, so a manager under
    `cpus: 2` would draw a twelve-core box as full at one sixth of load. docker
    info is answered by the daemon, about the host, and it is the same daemon
    whose percentages are being divided.
    CACHED FOR THE LIFE OF THE PROCESS (a running box grows no cores) because
    this is on a five-second repaint. A FAILURE IS NOT CACHED, and neither is a
    PARTIAL answer — an older host.sh prints ncpu and no memory_bytes.
    """
    global _HOST_BOX
    if _HOST_BOX is not None:
        return dict(_HOST_BOX)
    rows = _read_host_rows(quiet=quiet)
    cpus = rows.get('ncpu', '')
    memory = rows.get('memory_bytes', '')
    box = {"cpus": int(cpus) if cpus.isdigit() else 0,
           "memory_bytes": int(memory) if memory.isdigit() else 0}
    if box["cpus"] and box["memory_bytes"]:
        _HOST_BOX = box
    return dict(box)


def read_containers(quiet=False):
    """Every container: identity, health, ports, image, network mode, project.

    `quiet` IS THE AUTO-REFRESH TICK: suppress the two bus events, keep the exit
    code. A scan an operator asked for is news; the same scan on a clock is a
    repaint.
    Returns (containers, rows) — the dicts, and the raw lines the inventory
    event is deduplicated on. Raw lines are the comparison key on purpose: this
    function own padding can make two dicts equal when the output changed.
    """
    exit_code, output = run_management_script('ps.sh', quiet=quiet)
    if exit_code != 0:
        return [], []
    rows = [line for line in output.strip().splitlines()
            if line and not line.startswith('@EVENT ')]
    containers = []
    for row in rows:
        # SIX, and the padding is what makes the sixth safe to add: a docker
        # without the compose label yields '' rather than an IndexError.
        fields = (row.split('\t') + [''] * 6)[:6]
        containers.append({"name": fields[0], "status": fields[1],
                           "ports": fields[2], "image": fields[3],
                           "network_mode": fields[4], "project": fields[5]})
    return containers, rows


def read_stacks(quiet=True):
    """Every stack this repository declares, and whether it is on this host.

    THE ONE READER HERE THAT REPORTS ABSENCE. Every other function describes
    containers that exist, so a stack entirely gone renders as nothing at all —
    indistinguishable from a stack this repository never had.
    Returns [{"stack", "compose_file", "project", "driven", "declared",
    "present", "running", "absent", "stopped", "dark", "restorable"}] where
    `dark` is "not one of its declared containers exists" and `restorable` is
    `driven`, named for what it MEANS: whether a button here can bring it back.
    `stopped` IS NOT THE COMPLEMENT OF `running`: it is the declared containers
    that EXIST, are not running, and carry a restart: policy other than `no`.
    stacks.sh owns that rule.
    An empty list on failure, like every reader here.
    """
    exit_code, output = run_management_script('stacks.sh', quiet=quiet)
    if exit_code != 0:
        return []
    stacks = []
    seen = set()
    for line in output.strip().splitlines():
        if not line or line.startswith('@EVENT '):
            continue
        # NINE, padded, in stacks.sh header order. Same tolerance as every
        # parser here, which is also what lets a manager from this tree read an
        # older stacks.sh without the ninth column.
        f = (line.split('\t') + [''] * 9)[:9]
        # ONE COMPOSE FILE UNDER TWO NAMES IS ONE STACK. stacks.sh walks
        # APK:PODS/, where the compatibility symlinks (APK:docktor -> Docktor,
        # Server:Broker:MQTT -> POD:databus/…) sit beside the folders they name,
        # so a file arrived twice and the watchdog remounted it twice. First wins.
        real = os.path.realpath(f[1])
        if real in seen:
            continue
        seen.add(real)
        declared, present, running = (int(n) if n.isdigit() else 0 for n in f[4:7])
        absent = [name for name in f[7].split(',') if name]
        stopped = [name for name in f[8].split(',') if name]
        stacks.append({"stack": f[0], "compose_file": f[1], "project": f[2],
                       "driven": f[3] == 'yes', "restorable": f[3] == 'yes',
                       "declared": declared, "present": present,
                       "running": running, "absent": absent, "stopped": stopped,
                       "dark": bool(declared) and present == 0,
                       "manager": os.path.basename(f[1]) == 'docker-compose.manager.yml'})
    return stacks


def read_stale_images(quiet=False):
    """Every declared build, and whether its image predates the code behind it.

    read_stacks() finds a stack that is GONE; this finds one that is HERE and
    wrong — up, healthy, metered and green while running code that has since
    been edited. Nothing else here compares a build time to a source tree.
    Returns [{"stack", "service", "container", "image", "stale", "built",
    "changed", "behind", "newest"}]; `stale` is yes/no/unbuilt/unknown, `behind`
    is seconds of code the image is missing, `newest` the one path that decided
    it, repository-relative.
    An empty list on failure.
    """
    exit_code, output = run_management_script('staleness.sh', quiet=quiet)
    if exit_code != 0:
        return []
    rows = []
    for line in output.strip().splitlines():
        if not line or line.startswith('@EVENT '):
            continue
        # NINE, padded, in staleness.sh header order — a field that stops being
        # printed costs a blank, not an IndexError mid-repaint.
        f = (line.split('\t') + [''] * 9)[:9]
        rows.append({"stack": f[0], "service": f[1], "container": f[2],
                     "image": f[3], "stale": f[4], "built": f[5],
                     "changed": f[6],
                     "behind": int(f[7]) if f[7].lstrip('-').isdigit() else 0,
                     "newest": f[8]})
    return rows


def read_container_apps(container_name=None, quiet=False):
    """What is running INSIDE each container, keyed by container name.

    Returns {container: [{"app", "state", "detail"}, ...]}; `state` is
    running / idle / stopped / disabled / down, defined in apps.sh header, and
    `idle` exists because a periodic agent is SUPPOSED to be not-running most of
    the time.
    An empty dict on failure: this decorates cards.
    """
    exit_code, output = run_management_script('apps.sh',
                                              [container_name] if container_name else [],
                                              quiet=quiet)
    if exit_code != 0:
        return {}
    apps = {}
    for line in output.strip().splitlines():
        if not line or line.startswith('@EVENT '):
            continue
        fields = (line.split('\t') + [''] * 4)[:4]
        apps.setdefault(fields[0], []).append(
            {"app": fields[1], "state": fields[2], "detail": fields[3]})
    return apps


def read_app_plane(container_name=None, quiet=False):
    """The WHOLE of what each app plane said, keyed by container name.

    read_container_apps() is the same fetch rendered down to four fields for a
    card; this is the document behind it — every agent argv, pid, restartPolicy
    and lastExitAt, every $SYS counter, every tree URL and build stamp. Two
    readers over one script rather than two scripts.
    An empty dict on failure.
    """
    exit_code, output = run_management_script(
        'apps.sh', ['--json'] + ([container_name] if container_name else []),
        quiet=quiet)
    if exit_code != 0:
        return {}
    # `@EVENT ` lines are the runner own announcements interleaved with stdout,
    # and a JSON parser given one reports a syntax error at line 1.
    body = "\n".join(line for line in output.splitlines()
                     if not line.startswith('@EVENT '))
    try:
        return json.loads(body) if body.strip() else {}
    except ValueError:
        return {}


def read_container_api(container_name=None, quiet=True):
    """The ROUTES each container answers on, keyed by container name.

    api.sh --json in full: every route with its method, absolute URI and what it
    does, plus `how` — declared table, read out of a 404, or walked from a
    self-describing base path. A container with no HTTP surface comes back with
    an empty `routes` and a `reason`, and the pane prints the reason: "nothing
    here" and "nothing asked" look identical on a page.
    An empty dict on failure.
    """
    return _script_json('api.sh', container_name, quiet=quiet)


# The census holds a subscription open for a settle window, so it is the one
# read here that costs seconds — and it reads the WHOLE bus whatever container
# was asked about, because one subscription answers for every card. Caching is
# therefore the correct scope for the measurement, not an optimisation.
# SHORT, because a topic that went live twenty seconds ago must not still be
# drawn as retained. Long enough that clicking five cards runs one census.
BUS_CENSUS_SECONDS = 20
_bus_cache = {"at": 0.0, "document": None}
_bus_lock = threading.Lock()


def read_bus_topics(container_name=None, quiet=True):
    """What each container is PUBLISHING on the bus, keyed by container name.

    Returns {container: {"topics": [...], "broker", "observedSeconds", ...}}.
    Every row is a topic that arrived during the census, with the payload field
    that named its publisher beside it as evidence — MQTT cannot tell a
    subscriber who published, so a row with no identity is filed under the
    broker and nothing else.
    THE CONTAINER ARGUMENT SLICES, IT DOES NOT NARROW THE MEASUREMENT: the
    script takes the same four seconds for one container as for twelve.
    """
    with _bus_lock:
        fresh = (_bus_cache["document"] is not None
                 and time.time() - _bus_cache["at"] < BUS_CENSUS_SECONDS)
        if not fresh:
            _bus_cache["document"] = _script_json('topics.sh', None, quiet=quiet)
            _bus_cache["at"] = time.time()
        document = _bus_cache["document"]
    if container_name is None:
        return document
    return {container_name: document[container_name]} if container_name in document else {}


def read_container_purpose(container_name=None, quiet=True):
    """What each container IS and why the bench needs it, keyed by name.

    The one reader whose script measures nothing: purpose.sh is a written table,
    because a reason is not a probeable fact. Cheap enough to fetch per pane —
    no docker call, no network.
    """
    return _script_json('purpose.sh', container_name, quiet=quiet)


def _script_json(script, container_name=None, quiet=True):
    """One `--json` reader script, parsed. {} on any failure.

    `@EVENT ` lines are the runner own announcements interleaved with stdout,
    and a JSON parser given one reports a syntax error at line 1.
    """
    exit_code, output = run_management_script(
        script, ['--json'] + ([container_name] if container_name else []),
        quiet=quiet)
    if exit_code != 0:
        return {}
    body = "\n".join(line for line in output.splitlines()
                      if not line.startswith('@EVENT '))
    try:
        return json.loads(body) if body.strip() else {}
    except ValueError:
        return {}


def read_build_services(quiet=True):
    """Every declared build with what goes into it, from staleness.sh --json.

    [{"stack", "service", "container", "image", "compose_file", "context",
    "dockerfile", "target", "sources", ...}] — `sources` context-relative, the
    COPY/ADD paths of the stage that is built. An empty list on failure.
    """
    services = _script_json('staleness.sh', quiet=quiet).get("services")
    return services if isinstance(services, list) else []


def read_page_titles(uris, remembered_only=False):
    """The name each address answers with, keyed by the URI asked about.

    Returns {uri: {"title", "source", "fetched_at"}} with a key for every URI
    passed in — page-titles.sh prints a row whatever happened, so a caller never
    tests for absence, only for an empty title.
    `remembered_only` TOUCHES NO NETWORK: the cache answers in a millisecond so
    launchers are drawn with names immediately, while the live probe runs on the
    worker that was already fetching the app plane.
    """
    if not uris:
        return {}
    args = (['--remembered'] if remembered_only else []) + list(uris)
    exit_code, output = run_management_script('page-titles.sh', args, quiet=True)
    if exit_code != 0:
        return {}
    titles = {}
    for line in output.strip().splitlines():
        if not line or line.startswith('@EVENT '):
            continue
        fields = (line.split('\t') + [''] * 4)[:4]
        titles[fields[0]] = {"title": fields[1], "source": fields[2],
                             "fetched_at": fields[3]}
    return titles


def inspect_container_json(container_name, quiet=False):
    """`docker inspect` one container, decoded. None if it is not known.

    `quiet` for the auto-refresh repaint of a pane already open on it.
    """
    exit_code, output = run_management_script('inspect.sh', [container_name],
                                              quiet=quiet)
    if exit_code != 0 or not output.strip():
        return None
    try:
        return json.loads(output)
    except ValueError:
        return None


def start_resource_sampler(interval=RESOURCE_SAMPLE_SECONDS):
    """Publish a full resource sample every minute, for as long as this runs.

    Deliberately NOT the five-second repaint: that exists because a person is
    watching a screen, and a screen refresh must never become bus traffic. This
    is the record — it keeps going when nobody is looking and publishes every
    sample whether or not the numbers moved, because a flat CPU reading IS the
    news and a gap has to read as the sampler having stopped.
    The sample is taken quiet: one event per beat, not three saying the same.
    """
    def loop():
        while True:
            rows = sample_resources(quiet=True)
            # `running_count`, not `container_count`: these are docker stats
            # rows, and docker stats reports only running containers.
            emit("RESOURCES", {"interval_seconds": interval,
                               "running_count": len(rows),
                               "containers": rows})
            time.sleep(interval)
    thread = threading.Thread(target=loop, daemon=True, name="resource-sampler")
    thread.start()
    emit("RESOURCE_SAMPLER_STARTED", {"interval_seconds": interval})
    return thread


def run_prebuild_test_gates(on_line_callback=None):
    """The refusal law. False means the build must not proceed.

    up.sh, rebuild-all.sh and rebuild-core.sh run these gates themselves, so a
    caller about to run one of THOSE must not run this first — it would double
    every gate. This is for the callers that are not: the CLI bare `test`
    action, and the GUI button.
    """
    exit_code, _ = run_management_script('test-gates.sh',
                                         on_line_callback=on_line_callback)
    return exit_code == 0


def run_container_tests(on_line_callback=None):
    """The post-mount verification suite. False if anything FAILED (not warned)."""
    exit_code, _ = run_management_script('verify.sh',
                                         on_line_callback=on_line_callback)
    return exit_code == 0


WATCHDOG_ACTIVE = False


def watchdog_active():
    """True once start_watchdog has run in this process — the page reads it to
    stand its own countdown down, so one engine remounts a dark stack, not two."""
    return WATCHDOG_ACTIVE


def start_watchdog(interval=30):
    """Periodically inspect declared stacks and auto-remount any down/empty stacks.

    Pushes for 100% green lights across all driven ecosystem stacks.
    NOT THE MANAGER'S OWN STACK WHEN A TERMINAL MANAGER IS SERVING: that process
    holds 127.0.0.1:8765, so a DockTor container can only wait for the port, and
    remounting it every 30s is the loop that evicted the whole bench.
    """
    global WATCHDOG_ACTIVE
    WATCHDOG_ACTIVE = True
    containerised = os.path.exists("/.dockerenv")

    def loop():
        time.sleep(15)
        while True:
            try:
                if not is_any_script_running():
                    stack_list = read_stacks(quiet=True)
                    for s in stack_list:
                        if s.get("manager") and not containerised:
                            continue
                        if s.get("driven") and (s.get("dark") or (s.get("declared", 0) > 0 and s.get("running", 0) == 0)):
                            stack_name = s.get("stack")
                            if stack_name and not is_any_script_running():
                                emit("WATCHDOG_REMOUNTING_STACK", {"stack": stack_name, "reason": "stack_down"})
                                run_management_script('up-stack.sh', args=[stack_name], cancellable=True,
                                                      ordered_by=f"the DockTor watchdog ({stack_name} was down)")
                                time.sleep(10)
            except Exception as err:
                emit("WATCHDOG_ERROR", {"error": str(err)})
            time.sleep(interval)

    thread = threading.Thread(target=loop, daemon=True, name="watchdog-reconciler")
    thread.start()
    emit("WATCHDOG_STARTED", {"interval_seconds": interval})
    return thread



# ---------------------------------------------------------------- volumes
# 🗄️ THE THIRD THING THAT FILLS A DISK. The grid answers "is this container
# up", the donuts answer "who is eating the CPU", and neither can be read for
# the question that took this bench down on 2026-09-09: WHAT IS ON THE DISK AND
# WHAT IS GROWING. A size is only half of that — a volume at 157 MB is a fact,
# and a volume that was 90 MB this morning is the news — so these readings are
# WRITTEN DOWN as they are taken and the tab draws the series, not the number.
# WHERE THEY ARE WRITTEN IS THE POINT OF storage-volume.sh: a named docker
# volume whose bytes are a local folder in the checkout, so the series survives
# the container that wrote it and a person can open the file.
VOLUME_SAMPLE_SECONDS = 300
VOLUME_HISTORY_FILE = 'volume-history.jsonl'
# A sample is ~200 bytes and one every five minutes is ~2 MB a year. The cap is
# not about space; it is about a browser being handed a file it cannot draw.
VOLUME_HISTORY_MAX_BYTES = 4 * 1024 * 1024
VOLUME_HISTORY_KEEP_BYTES = 2 * 1024 * 1024

_volume_lock = threading.Lock()
_storage_dir_cache = {"path": None, "at": 0.0}
# WHEN THE LAST POINT WENT DOWN, so a browser polling the tab cannot turn a
# five-minute series into a five-second one. The sampler thread and a reader
# both write through record_volume_sample(); only the sampler passes no gap.
_last_sample_at = 0.0
STORAGE_DIR_SECONDS = 60


def storage_directory(quiet=True):
    """The folder this manager writes its own persistent state into.

    ASKED OF storage-volume.sh, NEVER DECIDED HERE. Inside the manager the
    answer is the mount (/storage) and outside it is the folder in the
    checkout; a second copy of that rule in Python is a second thing to get
    wrong, and the one that would be wrong is this one — it cannot see whether
    the volume is mounted without asking.
    '' when the script will not answer. Every caller treats that as "no history
    this run", which is what a bench with no docker has anyway.
    """
    with _volume_lock:
        if (_storage_dir_cache["path"] is not None
                and time.time() - _storage_dir_cache["at"] < STORAGE_DIR_SECONDS):
            return _storage_dir_cache["path"]
    exit_code, output = run_management_script('storage-volume.sh', ['--path'], quiet=quiet)
    path = ''
    if exit_code == 0:
        for line in output.splitlines():
            line = line.strip()
            if line and not line.startswith('@EVENT '):
                path = line
                break
    with _volume_lock:
        _storage_dir_cache["path"] = path
        _storage_dir_cache["at"] = time.time()
    return path


def _int(value, fallback=0):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return fallback


def read_volumes(quiet=True, fast=False):
    """volumes.sh, as a dict. The whole reading the VOLUMES tab is drawn from.

    FIELD ORDER IS THE CONTRACT and the slicing below PADS: a docker version
    that stops printing a column costs a blank field, never a dashboard.
    `size_bytes` of -1 means NOT MEASURED — `docker system df -v` skips every
    bind-backed volume, which is exactly the two this repository cares most
    about — and it is carried through as -1 rather than flattened to 0, because
    a bind volume drawn as empty is a lie a graph tells convincingly.
    """
    args = ['--fast'] if fast else []
    exit_code, output = run_management_script('volumes.sh', args, quiet=quiet)
    reading = {"taken_at": time.time(), "ok": exit_code == 0,
               "disk": {}, "usage": {}, "volumes": [], "storage": {}}
    if exit_code != 0:
        return reading

    for line in output.splitlines():
        if not line or line.startswith('@EVENT '):
            continue
        parts = line.rstrip('\n').split('\t')
        parts += [''] * (10 - len(parts))
        kind = parts[0]
        if kind == 'disk':
            reading["disk"] = {
                "data_root": parts[1],
                "total_bytes": _int(parts[2]),
                "used_bytes": _int(parts[3]),
                "available_bytes": _int(parts[4]),
                "used_percent": _int(parts[5]),
            }
        elif kind == 'usage':
            reading["usage"][parts[1]] = {
                "count": _int(parts[2]),
                "size_bytes": _int(parts[3]),
                "reclaimable_bytes": _int(parts[4]),
                "active": _int(parts[5]),
            }
        elif kind == 'volume':
            reading["volumes"].append({
                "name": parts[1],
                "driver": parts[2],
                "size_bytes": _int(parts[3], -1),
                "links": _int(parts[4]),
                "project": parts[5],
                "role": parts[6] or 'other',
                "mountpoint": parts[7],
                "device": parts[8],
                "measured": parts[9] or 'none',
            })
        elif kind == 'storage':
            reading["storage"][parts[1]] = parts[2]

    # BIGGEST FIRST, and an unmeasured volume last rather than first: -1 sorts
    # below zero, so the two volumes docker would not size would have led a
    # table whose whole job is "what is big".
    reading["volumes"].sort(key=lambda row: (row["size_bytes"] < 0, -row["size_bytes"]))
    measured = [row["size_bytes"] for row in reading["volumes"] if row["size_bytes"] >= 0]
    reading["totals"] = {
        "volume_count": len(reading["volumes"]),
        "measured_count": len(measured),
        "measured_bytes": sum(measured),
        "in_use": sum(1 for row in reading["volumes"] if row["links"] > 0),
    }
    return reading


def _history_path(quiet=True):
    folder = storage_directory(quiet=quiet)
    return os.path.join(folder, VOLUME_HISTORY_FILE) if folder else ''


def record_volume_sample(reading, quiet=True, min_gap=0):
    """Append one line to the series. Returns the path written, or ''.

    `min_gap` REFUSES A POINT that would land within N seconds of the last one.
    That is for the read path: the tab polls while somebody is looking at it,
    and a series sampled at the rate a person opens a page is a series about
    that person.

    ONE LINE PER SAMPLE, JSON, APPENDED — not a rewritten document. A rewrite
    loses every earlier sample the moment the disk this is measuring fills up,
    which is the sample nobody can afford to lose.
    THE PER-VOLUME SIZES ARE IN THE LINE, keyed by name, so the graph can
    isolate one volume over a week; unmeasured volumes are left OUT of the map
    rather than written as 0.
    """
    global _last_sample_at
    path = _history_path(quiet=quiet)
    if not path or not reading.get("ok"):
        return ''
    if min_gap and (time.time() - _last_sample_at) < min_gap:
        return ''
    usage = reading.get("usage", {})
    disk = reading.get("disk", {})
    point = {
        "t": int(reading.get("taken_at") or time.time()),
        "disk_used": disk.get("used_bytes", 0),
        "disk_total": disk.get("total_bytes", 0),
        "images": usage.get("images", {}).get("size_bytes", 0),
        "containers": usage.get("containers", {}).get("size_bytes", 0),
        "volumes": usage.get("volumes", {}).get("size_bytes", 0),
        "cache": usage.get("cache", {}).get("size_bytes", 0),
        "vols": {row["name"]: row["size_bytes"] for row in reading.get("volumes", [])
                 if row.get("size_bytes", -1) >= 0},
    }
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with _volume_lock:
            with open(path, 'a', encoding='utf-8') as history:
                history.write(json.dumps(point, separators=(',', ':')) + '\n')
            _trim_history(path)
    except OSError as err:
        emit("VOLUME_HISTORY_WRITE_FAILED", {"path": path, "error": str(err)})
        return ''
    _last_sample_at = time.time()
    return path


def _trim_history(path):
    """Keep the tail when the file grows past the cap. Called holding the lock.

    A rotation and not a delete: the samples that go are the OLDEST, and the
    first whole line after the cut is where reading resumes, so a half line is
    never parsed.
    """
    try:
        if os.path.getsize(path) <= VOLUME_HISTORY_MAX_BYTES:
            return
        with open(path, 'rb') as handle:
            handle.seek(-VOLUME_HISTORY_KEEP_BYTES, os.SEEK_END)
            handle.readline()                      # drop the partial first line
            tail = handle.read()
        with open(path, 'wb') as handle:
            handle.write(tail)
        emit("VOLUME_HISTORY_TRIMMED", {"path": path, "kept_bytes": len(tail)})
    except OSError:
        pass


def read_volume_history(hours=24, limit=1500, quiet=True):
    """The series back, newest last: {"points": [...], "path": str, "kept": n}.

    READS THE TAIL OF THE FILE, not the file: a year of samples is megabytes
    and a browser drawing 100 000 points draws a smear. `limit` is the number
    of points RETURNED and the thinning is by stride rather than by truncation
    — a graph of the last 200 samples of a week is a graph of Sunday.
    """
    path = _history_path(quiet=quiet)
    result = {"path": path, "points": [], "hours": hours, "total": 0}
    if not path or not os.path.exists(path):
        return result
    cutoff = time.time() - hours * 3600
    points = []
    try:
        with open(path, encoding='utf-8') as history:
            for line in history:
                line = line.strip()
                if not line:
                    continue
                try:
                    point = json.loads(line)
                except ValueError:
                    continue
                if point.get("t", 0) >= cutoff:
                    points.append(point)
    except OSError as err:
        emit("VOLUME_HISTORY_READ_FAILED", {"path": path, "error": str(err)})
        return result

    result["total"] = len(points)
    if len(points) > limit:
        # KEEP THE LAST POINT WHATEVER THE STRIDE: it is the only one that can
        # be compared with the number printed beside the graph, and a series
        # ending one stride short of now reads as a sampler that has stopped.
        stride = len(points) // limit + 1
        thinned = points[::stride]
        if thinned and thinned[-1] is not points[-1]:
            thinned.append(points[-1])
        points = thinned
    result["points"] = points
    return result


def start_volume_sampler(interval=VOLUME_SAMPLE_SECONDS):
    """Write one storage sample every five minutes, for as long as this runs.

    MINUTES AND NOT SECONDS: `docker system df -v` walks the volume tree, and
    the whole value of this series is that it is long rather than dense — the
    question is what grew this week.
    IT SKIPS A BEAT WHILE A SCRIPT IS RUNNING, for the reason the watchdog does:
    a rebuild is already asking the daemon for everything it has, and a sample
    taken mid-build measures a half-written image tree.
    """
    def loop():
        # The first sample is taken at once rather than after the interval: a
        # graph that is empty for five minutes after a restart reads as broken.
        while True:
            try:
                if not is_any_script_running():
                    reading = read_volumes(quiet=True)
                    if reading.get("ok"):
                        record_volume_sample(reading, quiet=True)
            except Exception as err:                       # pragma: no cover
                emit("VOLUME_SAMPLER_ERROR", {"error": str(err)})
            time.sleep(interval)

    thread = threading.Thread(target=loop, daemon=True, name="volume-sampler")
    thread.start()
    emit("VOLUME_SAMPLER_STARTED", {"interval_seconds": interval,
                                    "history": _history_path(quiet=True)})
    return thread
