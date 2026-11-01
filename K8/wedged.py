#!/usr/bin/env python3
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""🧟 A container Docker cannot stop, and what a mount does about it (ROAD-3480).

FOUND 2026-11-01: a USB controller reset left Plugin-MIDI's process in
uninterruptible sleep (a thread in D state, wchan `usb_kill_urb`). `docker
stop` / `rm -f` then answer "tried to kill container, but did not receive an
exit event", and every mount of DISCOVERY.Engine recreated all ~37 plugins,
failed on that one stop (or on the name `/Plugin-MIDI` it still held), exited
1 and left every OTHER plugin in `Created`. The watchdog saw the stack down and
did it again every beat. Only a reboot clears such a process.

THIS FILE DECIDES; the shell (_common.sh mount_* functions) acts. Kept apart so
the decision is unit-tested with fakes (SRC/manager/test_wedged.py) and the
shell only runs compose.

    wedged.py assess --ps-json FILE [--compose-log FILE] [--record FILE]
        Which of this project's containers are wedged. Prints one
        `@EVENT WEDGED_CONTAINER {...}` per container (the bus lifts it) and one
        `EXCLUDE <service>` per service a retry must leave alone. Exit 0 when
        something is wedged, 1 when nothing is.
    wedged.py check [--record FILE] [--project P --service S] NAME
        Exit 0 when NAME (or any container of P/S) is wedged — for
        recreate_stale_builds, which must not force-recreate such a service.
    wedged.py exit-code FIRST N_WEDGED RETRY N_UNSTARTED
        Prints the mount's exit code (mount_exit) for mount_compose_up.

WHAT COUNTS AS WEDGED, any of:
  kill_failed    compose's own output named it in a stop/kill that got no exit
                 event (or "Error while Stopping");
  name_conflict  it holds the name a recreate needed and is still alive;
  d_state        a thread of its process tree sat in D state on two looks a
                 moment apart (one look is an ordinary disk wait);
  recorded       an earlier run saw one of the above for this same container
                 START (id + pid + StartedAt — a reboot restarts it fresh and
                 the record no longer applies).
THE WAIT CHANNEL is read from the host's /proc when this runs on the host. In
the DockTor container /proc is another pid namespace (State.Pid there may be
an unrelated process), so `docker top` is asked instead, and when that answers
nothing the event says the channel was not readable from here.
"""

import json
import os
import re
import subprocess
import sys
import time

PARTIAL_EXIT = 3          # up-stack.sh: some services up, wedged ones left
LIVE_STATES = {"running", "removing", "restarting", "paused", "dead"}

# The daemon's words, as compose relays them. Ids are 12..64 hex.
_KILL_ID = re.compile(
    r"cannot (?:stop|kill|remove) container:?\s*([0-9a-f]{12,64})"
    r".*?(?:did not receive an exit event|tried to kill)", re.I)
_KILL_NAME = re.compile(r"Container\s+(\S+)\s+Error while (?:Stopping|Killing|Removing)", re.I)
_CONFLICT = re.compile(
    r'container name "/([^"]+)" is already in use by container "([0-9a-f]{12,64})"', re.I)
_ANY_KILL = re.compile(r"did not receive an exit event", re.I)
_HEX = re.compile(r"\b[0-9a-f]{12,64}\b")


# ------------------------------------------------------------ compose output
def failures_from_output(text):
    """What the compose output blames: {"kill": set(refs), "conflict": set(refs)}.
    A ref is a container name or an id (prefix)."""
    kill, conflict = set(), set()
    for line in (text or "").splitlines():
        for m in _KILL_ID.finditer(line):
            kill.add(m.group(1))
        for m in _KILL_NAME.finditer(line):
            kill.add(m.group(1))
        if _ANY_KILL.search(line) and not _KILL_ID.search(line):
            # A daemon wording this file does not know yet: keep its ids.
            kill.update(_HEX.findall(line))
        for m in _CONFLICT.finditer(line):
            conflict.add(m.group(2))
    return {"kill": kill, "conflict": conflict}


def parse_ps_json(text):
    """`docker compose ps -a --format json` — an array (old compose) or one
    object per line (2.21+). Rows normalised to ID, Name, Service, State,
    Project."""
    text = (text or "").strip()
    if not text:
        return []
    if text.startswith("["):
        raw = json.loads(text)
    else:
        raw = [json.loads(line) for line in text.splitlines() if line.strip()]
    rows = []
    for r in raw:
        rows.append({"ID": r.get("ID", ""), "Name": r.get("Name", ""),
                     "Service": r.get("Service", ""),
                     "State": (r.get("State") or "").lower(),
                     "Project": r.get("Project", "")})
    return rows


def resolve(ref, rows):
    """The row a name or id (prefix) means, or None."""
    for r in rows:
        if ref == r["Name"] or ref.lstrip("/") == r["Name"]:
            return r
    for r in rows:
        if r["ID"] and (r["ID"].startswith(ref) or ref.startswith(r["ID"])):
            return r
    return None


# ------------------------------------------------------------ process tree
def parse_stat(line):
    """(pid, comm, state, ppid) from one /proc/<pid>/stat line; comm may hold
    spaces and parentheses, so split at the LAST ')'."""
    head, _, tail = line.rpartition(")")
    pid, _, comm = head.partition(" (")
    fields = tail.split()
    return int(pid), comm, fields[0], int(fields[1])


def _read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return None


def proc_tasks(root_pid, proc="/proc"):
    """Every thread of root_pid and its descendants:
    [{"pid","tid","state","wchan","comm"}]. [] when /proc cannot see it."""
    out, todo, seen = [], [int(root_pid)], set()
    while todo:
        pid = todo.pop()
        if pid in seen or pid <= 0:
            continue
        seen.add(pid)
        tdir = os.path.join(proc, str(pid), "task")
        try:
            tids = sorted(os.listdir(tdir), key=int)
        except (OSError, ValueError):
            continue
        for tid in tids:
            stat = _read(os.path.join(tdir, tid, "stat"))
            if not stat:
                continue
            try:
                _p, comm, state, _pp = parse_stat(stat.strip())
            except (ValueError, IndexError):
                continue
            wchan = (_read(os.path.join(tdir, tid, "wchan")) or "").strip()
            out.append({"pid": pid, "tid": int(tid), "state": state,
                        "wchan": "" if wchan == "0" else wchan, "comm": comm})
            for child in (_read(os.path.join(tdir, tid, "children")) or "").split():
                if child.isdigit():
                    todo.append(int(child))
    return out


def parse_top(text):
    """`docker top C -eLo pid,lwp,stat,wchan:64,comm` → the same task dicts."""
    out = []
    for line in (text or "").splitlines()[1:]:
        parts = line.split(None, 4)
        if len(parts) < 4 or not parts[0].isdigit():
            continue
        wchan = parts[3] if parts[3] != "-" else ""
        out.append({"pid": int(parts[0]), "tid": int(parts[1]) if parts[1].isdigit() else 0,
                    "state": parts[2][:1], "wchan": wchan,
                    "comm": parts[4] if len(parts) > 4 else ""})
    return out


def stuck(tasks):
    """The tasks in uninterruptible sleep."""
    return [t for t in tasks if t["state"].startswith("D")]


# ------------------------------------------------------------ docker access
def _run(argv, timeout=15):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return 1, ""
    return done.returncode, done.stdout


class Docker:
    """The two questions asked of the daemon. Tests pass a fake."""

    def __init__(self, run=_run, proc="/proc", in_container=None):
        self.run = run
        self.proc = proc
        self.in_container = (os.path.exists("/.dockerenv")
                             if in_container is None else in_container)

    def inspect(self, ref):
        """{"id","name","status","pid","started"} or None."""
        code, out = self.run(["docker", "inspect", "-f",
                              "{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.Pid}}|{{.State.StartedAt}}",
                              ref])
        if code != 0 or not out.strip():
            return None
        cid, name, status, pid, started = (out.strip().splitlines()[0].split("|") + [""] * 5)[:5]
        return {"id": cid, "name": name.lstrip("/"), "status": status,
                "pid": int(pid) if pid.isdigit() else 0, "started": started}

    def tasks(self, info):
        """(tasks, source). Host /proc first — only on the host, never in a
        container where the pid means something else — then `docker top`."""
        if info.get("pid") and not self.in_container:
            got = proc_tasks(info["pid"], self.proc)
            if got:
                return got, "proc"
        code, out = self.run(["docker", "top", info["id"] or info["name"],
                              "-eLo", "pid,lwp,stat,wchan:64,comm"])
        got = parse_top(out) if code == 0 else []
        return got, ("docker top" if got else "")

    def by_labels(self, project, service):
        code, out = self.run(["docker", "ps", "-aq",
                              "--filter", f"label=com.docker.compose.project={project}",
                              "--filter", f"label=com.docker.compose.service={service}"])
        return out.split() if code == 0 else []


def persistent_d(docker, info, sleep=time.sleep, gap=0.7):
    """(stuck tasks seen on BOTH looks, source). The second look only when the
    first saw any D, so a healthy container costs one look."""
    first, source = docker.tasks(info)
    d1 = stuck(first)
    if not d1:
        return [], source
    sleep(gap)
    second, _ = docker.tasks(info)
    again = {t["tid"] for t in stuck(second)}
    return [t for t in d1 if t["tid"] in again], source


# ------------------------------------------------------------ the record
def load_record(path):
    if not path:
        return {}
    try:
        with open(path) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_record(path, record):
    if not path:
        return
    try:
        tmp = f"{path}.tmp{os.getpid()}"
        with open(tmp, "w") as fh:
            json.dump(record, fh, indent=1, sort_keys=True)
        os.replace(tmp, path)
    except OSError:
        pass


def record_applies(entry, info):
    """The same container START the record was written for — a reboot gives the
    same id a new pid and StartedAt, and the old verdict no longer holds."""
    return bool(entry and info and entry.get("pid") == info.get("pid")
                and entry.get("started") == info.get("started")
                and info.get("status") in LIVE_STATES)


# ------------------------------------------------------------ the decision
def assess(rows, failures, docker, record=None, sleep=time.sleep):
    """The wedged containers among `rows`, newest evidence first.

    Candidates: what the compose output blamed, what the record names, and
    every container of a service that has more than one (the renamed
    Plugin-MIDI-wedged-usb beside a fresh Plugin-MIDI). Only those are looked
    at — a healthy project costs nothing.
    Returns [{"container","id","service","project","state","reasons",
              "threads","wchan","source"}]."""
    record = record if record is not None else {}
    failures = failures or {"kill": set(), "conflict": set()}
    reasons = {}

    def blame(row, why):
        if row is not None:
            reasons.setdefault(row["ID"] or row["Name"], (row, set()))[1].add(why)

    for ref in failures.get("kill", ()):
        blame(resolve(ref, rows), "kill_failed")
    for ref in failures.get("conflict", ()):
        blame(resolve(ref, rows), "name_conflict")
    per_service = {}
    for r in rows:
        per_service.setdefault(r["Service"], []).append(r)
    for r in rows:
        if len(per_service.get(r["Service"], ())) > 1 and r["State"] in LIVE_STATES:
            reasons.setdefault(r["ID"] or r["Name"], (r, set()))
    for r in rows:
        if any(r["ID"] and (cid.startswith(r["ID"]) or r["ID"].startswith(cid)) for cid in record):
            reasons.setdefault(r["ID"] or r["Name"], (r, set()))

    found = []
    for _key, (row, why) in reasons.items():
        info = docker.inspect(row["ID"] or row["Name"])
        if info is None or info["status"] not in LIVE_STATES:
            continue          # gone or stopped after all: nothing holds the stack
        threads, source = persistent_d(docker, info, sleep=sleep)
        why = set(why)
        if threads:
            why.add("d_state")
        entry = record.get(info["id"])
        if record_applies(entry, info):
            why.add("recorded")
        if not why:
            continue
        wchan = sorted({t["wchan"] for t in threads if t["wchan"]}) \
            or ([entry["wchan"]] if record_applies(entry, info) and entry.get("wchan") else [])
        found.append({"container": info["name"], "id": info["id"][:12],
                      "full_id": info["id"], "pid": info["pid"], "started": info["started"],
                      "service": row["Service"], "project": row["Project"],
                      "state": info["status"], "reasons": sorted(why),
                      "threads": [{"tid": t["tid"], "comm": t["comm"], "wchan": t["wchan"]}
                                  for t in threads],
                      "wchan": ",".join(wchan) if wchan else "",
                      "source": source})
    return found


def excluded_services(found):
    return sorted({w["service"] for w in found if w["service"]})


def retry_plan(services, found):
    """The services a retry brings up: all asked-for ones minus the wedged."""
    out = set(excluded_services(found))
    return [s for s in services if s not in out]


def mount_exit(first_status, wedged, retry_status, unstarted):
    """The mount's exit code.
      0  compose was clean
      first_status  nothing wedged explains the failure: report compose's own
      PARTIAL_EXIT  wedged services left alone, everything else is up
      retry_status / 1  the retry itself failed, or some container would not start
    """
    if first_status == 0:
        return 0
    if not wedged:
        return first_status
    if retry_status != 0:
        return retry_status
    if unstarted:
        return 1
    return PARTIAL_EXIT


def remember(record, found, now=None):
    """Write each wedged container into the record (keyed by full id)."""
    now = now if now is not None else time.time()
    for w in found:
        record[w["full_id"]] = {"name": w["container"], "service": w["service"],
                                "project": w["project"], "pid": w["pid"],
                                "started": w["started"], "wchan": w["wchan"],
                                "reasons": w["reasons"], "at": int(now)}
    return record


def event_payload(w):
    channel = w["wchan"] or ("not readable from here (no host /proc; docker top gave none)"
                             if not w["source"] else "none seen in D state")
    return {"container": w["container"], "id": w["id"], "service": w["service"],
            "project": w["project"], "state": w["state"], "reasons": w["reasons"],
            "wchan": channel, "threads": w["threads"],
            "remedy": "Its process is in uninterruptible sleep in the kernel; docker cannot "
                      "stop or remove it. A reboot clears it. The rest of the stack is "
                      "brought up without this service."}


# ------------------------------------------------------------ CLI
def _arg(argv, flag, default=None):
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def cli_assess(argv, docker=None, out=sys.stdout):
    docker = docker or Docker()
    rows = parse_ps_json(_read(_arg(argv, "--ps-json", "")) or "")
    failures = failures_from_output(_read(_arg(argv, "--compose-log", "")) or "")
    record_path = _arg(argv, "--record")
    record = load_record(record_path)
    found = assess(rows, failures, docker, record)
    for w in found:
        print("@EVENT WEDGED_CONTAINER " + json.dumps(event_payload(w)), file=out)
        print(f"✗ {w['container']} ({w['service']}) cannot be stopped: "
              f"{', '.join(w['reasons'])}; wait channel {event_payload(w)['wchan']}. "
              "A reboot clears it.", file=out)
    for svc in excluded_services(found):
        print(f"EXCLUDE {svc}", file=out)
    if found:
        save_record(record_path, remember(record, found))
    return 0 if found else 1


def cli_check(argv, docker=None, out=sys.stdout):
    docker = docker or Docker()
    record = load_record(_arg(argv, "--record"))
    project, service = _arg(argv, "--project"), _arg(argv, "--service")
    refs = [a for i, a in enumerate(argv)
            if not a.startswith("--") and (i == 0 or argv[i - 1] not in
                                           ("--record", "--project", "--service"))]
    if project and service:
        refs += docker.by_labels(project, service)
    for ref in dict.fromkeys(refs):
        info = docker.inspect(ref)
        if info is None or info["status"] not in LIVE_STATES:
            continue
        if record_applies(record.get(info["id"]), info):
            print(f"{info['name']} is recorded wedged since its last failed stop", file=out)
            return 0
        threads, _ = persistent_d(docker, info)
        if threads:
            print(f"{info['name']} has a thread in D state "
                  f"({','.join(sorted({t['wchan'] for t in threads if t['wchan']})) or '?'})", file=out)
            return 0
    return 1


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    verb, rest = argv[0], argv[1:]
    if verb == "assess":
        return cli_assess(rest)
    if verb == "check":
        return cli_check(rest)
    if verb == "exit-code":
        # exit-code FIRST N_WEDGED RETRY N_UNSTARTED → prints the mount's code
        first, wedged, retry, unstarted = (int(x) for x in rest[:4])
        print(mount_exit(first, wedged, retry, unstarted))
        return 0
    print(f"unknown verb {verb}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
