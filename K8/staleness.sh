#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# ⚡ Which images on this host were built before the code they were built FROM.
#   ./staleness.sh [--json|--report]
# The quiet failure: a container running a six-hour-old build of a file edited
# twenty minutes ago renders GREEN on every other surface of this tool.
# WHAT IS COMPARED IS THE DOCKERFILE COPY/ADD SOURCES, not the build context:
# three stacks declare `context: ../..`, so a newest-mtime-under-context rule
# would mark them stale on every edit anywhere in the repository.
#     Dockerfile.manager  ->  manager/, docker scripts/, Manager:docktor.py,
#                             brand.json, mqtt_broker_discovery.py
#     APK:Yo/Dockerfile   ->  Cargo.toml, src/
# AND ONLY THE STAGE THAT IS BUILT. Server:Discovery:NMOS/Docker/Dockerfile
# declares five stages and its services each name one with `target:`. Reading
# every COPY in the file and handing the lot to every service that shares it
# charged four containers with `conf/UserConfig.py`, which enters the
# `nmos-testing` stage and no other. That row cannot be cleared by doing what it
# asks: the rebuild succeeds, nothing in the service's own stage moved, the
# image is rightly unchanged, and the row comes back.
# So the stages are read as a GRAPH and walked from the one compose names, or
# from docker's own default of the last stage. `COPY --from=` is still never a
# path on disk; it is followed as an EDGE to the stage it names, whose own
# context COPYs then count -- which is how `bridge` keeps `bridge/src`, the Rust
# source of the one binary it copies out of `bridge-build`.
# COPY --from= is skipped: that source is an earlier BUILD STAGE, and resolving
# it against the context finds nothing or an unrelated file of the same name.
# MTIME, NOT THE GIT LOG — an uncommitted edit is the case that matters most and
# the one the git log calls clean.
# .dockerignore IS APPLIED: the root one keeps a 96 MB backend.log out of an
# image, under a directory the portal Dockerfile COPYs whole.
# TAB rows, no header:
#   STACK SERVICE CONTAINER IMAGE STALE IMAGE_BUILT CODE_CHANGED BEHIND_S NEWEST_FILE
# STALE is yes | no | unbuilt (declared, no such image — nothing to be stale) |
# unknown (THIS READER DECLINING: the Dockerfile was unreadable, or docker gave
# no readable build time; `why` says which).
# IMAGE_BUILT/CODE_CHANGED are ISO-8601 UTC, BEHIND_S the seconds of code the
# image is missing, NEWEST_FILE the one path that decided it (repo-relative, so
# a reader is not sent to grep a tree).
# --report carries the @EVENT line; tsv and json stay SILENT on the bus because
# they are polled on every dashboard refresh. report.py gates the event on
# CHANGE instead.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

MODE=tsv
case "${1:-}" in
    --json)   MODE=json;;
    --report) MODE=report;;
    "")       ;;
    *) log_error "Unknown option: $1"; echo "Usage: ./staleness.sh [--json|--report]"; exit 2;;
esac

# EVERY IMAGE ON THE HOST, ONCE — the alternative is an inspect per declared
# service, fifteen round trips per refresh. Used only to decide which refs EXIST;
# build times come from one inspect over the survivors, because docker images
# prints CreatedAt in the daemon local format and a timezone guess is wrong for
# one hour twice a year.
IMAGE_REFS="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)" || IMAGE_REFS=""

DOCKERS="$DOCKERS_DIR" \
REPO="$REPO_ROOT" \
IMAGES="$IMAGE_REFS" \
MODE="$MODE" \
python3 - <<'PY'
import os
import re
import json
import time
import glob
import datetime
import fnmatch
import subprocess

dockers = os.environ.get("DOCKERS") or ""
repo = os.environ.get("REPO") or ""
existing = {ref for ref in (os.environ.get("IMAGES") or "").splitlines()
            if ref and not ref.endswith(":<none>")}
mode = os.environ.get("MODE") or "tsv"

# Anchored the way stacks.sh anchors them: a `name:` under services: is a
# service key, a top-level one is the project. A stack ROOT carries a project;
# an overlay (.hardware/.host/.dev/.macvlan) does not.
PROJECT = re.compile(r'^name:\s*["\']?([^"\'\s#]+)', re.M)


def unquote(value):
    """`"../.."` -> `../..`, and the comment after it dropped."""
    value = value.strip()
    if value[:1] in ('"', "'"):
        closing = value.find(value[0], 1)
        if closing > 0:
            return value[1:closing]
        return value[1:]
    return value.split('#')[0].strip()


def services_with_a_build(text):
    """[{service, context, dockerfile, target, image, container_name}] for one compose file.

    AN INDENTATION READER RATHER THAN A REGEX, because `build:` is the one key
    here whose value is a BLOCK -- `context:` and `dockerfile:` live under it,
    and a regex that finds `context:` anywhere in a service would also find one
    belonging to the service after it. stacks.sh gets away with regex because
    every key it wants is a scalar at a known depth. PyYAML would answer this in
    a line and is deliberately not imported: the manager image installs no pip
    packages, so a dependency here would work at a terminal and fail inside the
    container, which is the one place this has to run.
    """
    rows, current, in_services = [], None, False
    build_indent = None                       # set while inside a `build:` block
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        indent = len(raw) - len(raw.lstrip())
        stripped = raw.strip()

        if indent == 0:
            in_services = stripped.startswith('services:')
            if current:
                rows.append(current)
                current = None
            build_indent = None
            continue
        if not in_services:
            continue

        # A service key is the SHALLOWEST thing under services:. Two spaces in
        # every file here, but the depth is measured — a four-space file would
        # otherwise report no services and read as "nothing here builds".
        key = stripped.split(':', 1)[0]
        if re.match(r'^[A-Za-z0-9._-]+:$', stripped) and (
                current is None or indent <= current["_indent"]):
            if current:
                rows.append(current)
            current = {"service": key, "_indent": indent, "context": None,
                       "dockerfile": None, "target": None, "image": None,
                       "container_name": None}
            build_indent = None
            continue
        if current is None:
            continue

        if build_indent is not None and indent > build_indent:
            if stripped.startswith('context:'):
                current["context"] = unquote(stripped.split(':', 1)[1])
            elif stripped.startswith('dockerfile:'):
                current["dockerfile"] = unquote(stripped.split(':', 1)[1])
            elif stripped.startswith('target:'):
                # Which image of the several this Dockerfile declares. A key of
                # the build: block like the other two, and the only thing that
                # tells two services sharing a Dockerfile apart.
                current["target"] = unquote(stripped.split(':', 1)[1])
            continue
        build_indent = None

        if stripped.startswith('build:'):
            inline = unquote(stripped.split(':', 1)[1])
            if inline:
                current["context"] = inline    # `build: .`, the shorthand form
            else:
                build_indent = indent
        elif stripped.startswith('image:'):
            current["image"] = unquote(stripped.split(':', 1)[1])
        elif stripped.startswith('container_name:'):
            current["container_name"] = unquote(stripped.split(':', 1)[1])

    if current:
        rows.append(current)
    return [r for r in rows if r["context"]]


# COPY/ADD, both forms, continuations joined. The JSON-array form is not exotic
# here: Dockerfile.manager uses it for every COPY because its paths hold colons.
COPY_LINE = re.compile(r'^\s*(?:COPY|ADD)\s+(.*)$', re.I)
FROM_LINE = re.compile(r'^\s*FROM\s+(.*)$', re.I)
FLAG = re.compile(r'^--[A-Za-z-]+(?:=\S*)?$')


def operands_of(rest):
    """(flags, operands) for one COPY/ADD body, or (None, None) if unreadable.

    Both spellings: Dockerfile.manager uses the JSON-array form for every COPY
    because its paths contain a colon.
    """
    rest = rest.split('#')[0].strip()
    if not rest:
        return None, None
    if rest.startswith('['):
        try:
            parts = [str(part) for part in json.loads(rest)]
        except ValueError:
            return None, None
    else:
        parts = rest.split()
    flags = [part for part in parts if FLAG.match(part)]
    operands = [part for part in parts if not FLAG.match(part)]
    if len(operands) < 2:                     # a source and a destination, least
        return None, None
    return flags, operands


def read_stages(text):
    """Every stage in a Dockerfile, in file order, as a graph.

    {name, base, sources, uses}: the `AS` name lowercased (docker matches stage
    names case-insensitively) or None; what the stage is FROM; the context paths
    its own COPY/ADD lines take; and the stages it copies OUT of, by name or by
    the index `--from=0` spells.

    A COPY WITH `--from=` CONTRIBUTES AN EDGE AND NO PATH. Its source is a path
    inside another stage, so resolving it against the build context finds
    nothing or an unrelated file of the same name. What it does say is that the
    other stage is part of this image, and copy_sources() walks there.
    """
    stages = []
    for line in text.splitlines():
        from_match = FROM_LINE.match(line)
        if from_match:
            words = [word for word in from_match.group(1).split('#')[0].split()
                     if not FLAG.match(word)]
            if not words:
                continue
            name = (words[-1].lower()
                    if len(words) >= 3 and words[-2].lower() == 'as' else None)
            stages.append({"name": name, "base": words[0].lower(),
                           "sources": [], "uses": []})
            continue
        copy_match = COPY_LINE.match(line)
        if not copy_match or not stages:
            continue                          # a COPY before any FROM is not ours
        flags, operands = operands_of(copy_match.group(1))
        if operands is None:
            continue
        origin = ""
        for flag in flags:
            if flag.lower().startswith('--from='):
                origin = flag.split('=', 1)[1].strip().lower()
        if origin:
            stages[-1]["uses"].append(origin)
        else:
            stages[-1]["sources"].extend(operands[:-1])   # last one is the dest
    return stages


def copy_sources(dockerfile, target=None):
    """The context paths that actually enter ONE image, context-relative.

    `target` is compose's `target:` -- the stage this service builds. Docker's
    default when it is unset is the LAST stage, and that is the default here, so
    a single-stage Dockerfile answers exactly as it did before.

    The walk is over the stage graph: the target's own COPYs, then the stages it
    is FROM and the stages it copies out of, transitively. A reference naming no
    stage in this file is an external base image and ends that branch.
    """
    try:
        with open(dockerfile, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return None
    text = re.sub(r'\\\s*\n', ' ', text)      # join continuations first
    stages = read_stages(text)
    if not stages:
        return []
    by_name = {stage["name"]: stage for stage in stages if stage["name"]}
    by_index = {str(i): stage for i, stage in enumerate(stages)}

    if target:
        start = by_name.get(target.lower())
        if start is None:
            # A target this file does not declare: the build itself would fail,
            # so there is no right answer. Over-report rather than under-report
            # -- a false "rebuild me" is recoverable, a missed edit is the fault
            # this whole file exists to catch.
            return [source for stage in stages for source in stage["sources"]]
    else:
        start = stages[-1]

    sources, seen, queue = [], set(), [start]
    while queue:
        stage = queue.pop()
        if id(stage) in seen:
            continue
        seen.add(id(stage))
        sources.extend(stage["sources"])
        for reference in [stage["base"]] + stage["uses"]:
            other = by_name.get(reference) or by_index.get(reference)
            if other is not None:
                queue.append(other)
    return sources


def ignore_rules(context):
    """`.dockerignore` for this context, as (pattern, negated) pairs.

    Only the subset docker's own matcher shares with fnmatch is implemented, and
    that is enough for the list in this repository: `**/node_modules`, `.git`,
    `**/*.log`. A pattern this cannot read is KEPT rather than dropped, so the
    failure mode is a file counted that docker would have skipped -- a false
    "rebuild me", which is recoverable, rather than a missed edit, which is the
    fault being fixed.
    """
    rules = []
    try:
        with open(os.path.join(context, '.dockerignore'),
                  encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                negated = line.startswith('!')
                rules.append((line[1:].strip() if negated else line, negated))
    except OSError:
        pass
    return rules


def ignored(relative, rules):
    """Whether docker would leave this context-relative path out of the tar."""
    verdict = False
    for pattern, negated in rules:
        candidate = pattern[3:] if pattern.startswith('**/') else pattern
        hit = (fnmatch.fnmatch(relative, pattern)
               or fnmatch.fnmatch(os.path.basename(relative), candidate)
               or any(fnmatch.fnmatch(part, candidate)
                      for part in relative.split(os.sep)))
        if hit:
            verdict = not negated
    return verdict


def newest(paths, context, rules):
    """(mtime, path) of the most recently touched file among `paths`.

    Walks directories, skips what .dockerignore skips, and prunes an ignored
    directory rather than descending it -- `**/target` under a Rust crate is
    tens of thousands of files that cannot change the answer.
    """
    best_time, best_path = 0.0, None
    for source in paths:
        for candidate in sorted(glob.glob(os.path.join(context, source))) or \
                [os.path.join(context, source)]:
            if not os.path.exists(candidate):
                continue
            if os.path.isfile(candidate):
                relative = os.path.relpath(candidate, context)
                if ignored(relative, rules):
                    continue
                stamp = os.path.getmtime(candidate)
                if stamp > best_time:
                    best_time, best_path = stamp, candidate
                continue
            for root, directories, files in os.walk(candidate):
                directories[:] = [
                    d for d in directories
                    if not ignored(os.path.relpath(os.path.join(root, d), context), rules)]
                for name in files:
                    full = os.path.join(root, name)
                    if ignored(os.path.relpath(full, context), rules):
                        continue
                    try:
                        stamp = os.path.getmtime(full)
                    except OSError:
                        continue
                    if stamp > best_time:
                        best_time, best_path = stamp, full
    return best_time, best_path


# WHEN EACH IMAGE WAS BUILT. One inspect over the refs that exist, in argument
# order, so answers zip back onto the rows that asked. Pre-filtering against
# docker images is what makes the order reliable — inspect fails on a missing
# ref, and one failure mid-list shifts every later timestamp onto the wrong row.
def built_at(refs):
    wanted = [r for r in refs if r in existing]
    if not wanted:
        return {}
    try:
        result = subprocess.run(
            ["docker", "image", "inspect", "-f", "{{.Created}}"] + wanted,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return {}
    lines = [l for l in result.stdout.splitlines() if l.strip()]
    if len(lines) != len(wanted):
        return {}
    return dict(zip(wanted, lines))


def parse_iso(value):
    """Docker's RFC-3339 as a POSIX timestamp, or 0.0 when it will not read.

    NANOSECONDS ARE TRUNCATED TO MICROSECONDS, which is the whole reason this is
    not one strptime call: the daemon prints nine fractional digits
    (`...14.290670524Z`) and `%f` accepts at most six, so the unmodified string
    fails both shapes and every image reads as having no build time -- which
    lands as `unknown` on every row rather than as an error anybody would see.
    """
    text = value.strip()
    text = re.sub(r'\.(\d{6})\d*', r'.\1', text)
    text = re.sub(r'Z$', '+0000', text)
    text = re.sub(r'([+-]\d{2}):(\d{2})$', r'\1\2', text)
    for shape in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.datetime.strptime(text, shape).timestamp()
        except ValueError:
            continue
    return 0.0


def iso(stamp):
    if not stamp:
        return ""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp))


rows = []
# <stack>/Docker/<file>. A glob that matches nothing is not an error in Python,
# so a wrong rung reads as a repository that declares no stacks.
for path in sorted(glob.glob(os.path.join(dockers, "*", "Docker",
                                          "docker-compose*.yml"))):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        continue
    if not PROJECT.search(text):
        continue                              # an overlay, not a stack root
    # The stack is the GRANDPARENT: the parent of every compose file is the
    # literal directory Docker, so a basename of the parent named every stack
    # on the bench "Docker" — fifteen rows of one word.
    stack = os.path.basename(os.path.dirname(os.path.dirname(path)))
    for service in services_with_a_build(text):
        context = os.path.normpath(
            os.path.join(os.path.dirname(path), service["context"]))
        dockerfile = os.path.join(context, service["dockerfile"] or "Dockerfile")
        rows.append({
            "stack": stack, "service": service["service"],
            "container": service["container_name"] or "",
            "image": service["image"] or "",
            "compose_file": path, "context": context, "dockerfile": dockerfile,
            "target": service["target"] or "",
        })

stamps = built_at([r["image"] for r in rows if r["image"]])

for row in rows:
    sources = copy_sources(row["dockerfile"], row["target"])
    # CARRIED IN --json, context-relative: provenance.py links each one to the
    # repository that owns it, off this same stage walk rather than a second parser.
    row["sources"] = sources or []
    if sources is None:
        row.update({"stale": "unknown", "built": 0.0, "changed": 0.0,
                    "behind": 0, "newest": "",
                    "why": "its Dockerfile could not be read"})
        continue
    changed, newest_path = newest(sources, row["context"], ignore_rules(row["context"]))
    row["changed"] = changed
    row["newest"] = os.path.relpath(newest_path, repo) if newest_path and repo else (newest_path or "")
    built = parse_iso(stamps.get(row["image"], "")) if row["image"] else 0.0
    row["built"] = built
    if not row["image"] or row["image"] not in existing:
        # NOT STALE — UNBUILT. No image means no old code running; calling it
        # stale tells an operator to rebuild something never built.
        row.update({"stale": "unbuilt", "behind": 0,
                    "why": "no image on this host"})
        continue
    if not built:
        row.update({"stale": "unknown", "behind": 0,
                    "why": "the image has no readable build time"})
        continue
    behind = int(changed - built)
    row["behind"] = max(behind, 0)
    row["stale"] = "yes" if behind > 0 else "no"
    row["why"] = ("its code changed after it was built" if behind > 0
                  else "current")

# Stale rows first, furthest behind at the top: a reader acting on one row
# should be acting on the one that is most wrong.
rows.sort(key=lambda r: (r["stale"] != "yes", -r["behind"], r["stack"].lower()))

stale = [r for r in rows if r["stale"] == "yes"]
unbuilt = [r for r in rows if r["stale"] == "unbuilt"]


def human(seconds):
    if seconds < 90:
        return "%ds" % seconds
    if seconds < 5400:
        return "%dm" % round(seconds / 60)
    if seconds < 172800:
        return "%.1fh" % (seconds / 3600)
    return "%.1f days" % (seconds / 86400)


if mode == "json":
    print(json.dumps({
        "services": [{k: v for k, v in r.items() if not k.startswith('_')}
                     for r in rows],
        "stale": [r["stack"] for r in stale],
        "stale_containers": [r["container"] for r in stale if r["container"]],
        "unbuilt": [r["stack"] for r in unbuilt],
    }, indent=2, default=str))
elif mode == "report":
    # The event belongs to --report only (same rule as stacks.sh STACKS_STRANDED)
    # so a verb that runs this puts it on the bus without holding the payload,
    # and the polled tsv mode stays silent.
    print("@EVENT STACKS_STALE %s" % json.dumps(
        {"stale": [r["stack"] for r in stale],
         "containers": [r["container"] for r in stale if r["container"]],
         "images": [r["image"] for r in stale],
         "behind_s": max([r["behind"] for r in stale] or [0]),
         "newest": stale[0]["newest"] if stale else ""},
        separators=(",", ":")))
    if not stale and not unbuilt:
        print("✓ Every image on this host was built from the code that is on disk.")
    if stale:
        print("")
        print("⚡ %d IMAGE(S) ARE OLDER THAN THE CODE THEY WERE BUILT FROM."
              % len(stale))
        print("   These containers are running code that is no longer in the tree.")
        print("   Rebuild & Remount, or the per-container Rebuild, replaces them:")
        for r in stale:
            print("")
            print("   %s  (%s) — %s behind"
                  % (r["stack"], r["image"] or r["service"], human(r["behind"])))
            print("      built %s · code changed %s"
                  % (iso(r["built"]), iso(r["changed"])))
            print("      newest: %s" % r["newest"])
    if unbuilt:
        print("")
        print("\U0001f6a7 %d DECLARED BUILD(S) HAVE NO IMAGE ON THIS HOST."
              % len(unbuilt))
        for r in unbuilt:
            print("   %s — %s was never built here"
                  % (r["stack"], r["image"] or r["service"]))
else:
    for r in rows:
        print("\t".join([
            r["stack"], r["service"], r["container"], r["image"], r["stale"],
            iso(r["built"]), iso(r["changed"]), str(r["behind"]), r["newest"],
        ]))
PY
