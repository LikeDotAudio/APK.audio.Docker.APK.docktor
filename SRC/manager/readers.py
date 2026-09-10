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
from .runner import run_management_script

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
    for line in output.strip().splitlines():
        if not line or line.startswith('@EVENT '):
            continue
        # NINE, padded, in stacks.sh header order. Same tolerance as every
        # parser here, which is also what lets a manager from this tree read an
        # older stacks.sh without the ninth column.
        f = (line.split('\t') + [''] * 9)[:9]
        declared, present, running = (int(n) if n.isdigit() else 0 for n in f[4:7])
        absent = [name for name in f[7].split(',') if name]
        stopped = [name for name in f[8].split(',') if name]
        stacks.append({"stack": f[0], "compose_file": f[1], "project": f[2],
                       "driven": f[3] == 'yes', "restorable": f[3] == 'yes',
                       "declared": declared, "present": present,
                       "running": running, "absent": absent, "stopped": stopped,
                       "dark": bool(declared) and present == 0})
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

