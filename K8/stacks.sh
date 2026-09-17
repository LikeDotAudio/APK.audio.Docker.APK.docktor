#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🗂️ Every stack this repository declares, and whether it is actually here.
#   ./stacks.sh [--json|--report]
# ps.sh answers "what containers exist". This answers what ps.sh cannot: what
# the repository DECLARED that is not here at all — a removed container leaves
# no row in docker ps -a, so a vanished stack renders as nothing.
# A STACK = a compose file under APK:PODS/ with a top-level `name:`. That key
# is what docker groups by, and it separates a stack ROOT from an OVERLAY
# (hardware/host/dev/macvlan declare no project and are a second -f).
# DRIVEN = the manager verbs (up, down, rebuild-all, panic, panic-reboot,
# manager) act on that compose file, read off the same variables those verbs
# expand. DARK AND NOT DRIVEN is the row an operator must be told about: nothing
# on this bench will bring it back.
# TAB rows, no header:
#   STACK COMPOSE_FILE PROJECT DRIVEN DECLARED PRESENT RUNNING ABSENT STOPPED
# DRIVEN yes/no; DECLARED/PRESENT/RUNNING counts; ABSENT the declared names with
# no container on the host; STOPPED the ones that exist and are not running
# (scoped by restart_policies below). COMPOSE_FILE is absolute — it is the
# argument of the command that fixes this.
# --report is the same answer as prose, so panic.sh and panic-reboot.sh say it
# in the same words instead of each holding a copy.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

MODE=tsv
case "${1:-}" in
    --json)   MODE=json;;
    --report) MODE=report;;
    "")       ;;
    *) log_error "Unknown option: $1"; echo "Usage: ./stacks.sh [--json|--report]"; exit 2;;
esac

# -a, because a stack whose containers all EXITED is present-but-stopped, which
# is different news from one whose containers are not there. Both lists are
# taken once — a per-stack docker ps asks the daemon six times for one answer.
PRESENT_NAMES="$(docker ps -a --format '{{.Names}}' 2>/dev/null)" || PRESENT_NAMES=""
RUNNING_NAMES="$(docker ps --format '{{.Names}}' 2>/dev/null)" || RUNNING_NAMES=""

# THE DRIVEN SET IS NOT TYPED HERE — these are the same variables the verbs
# expand, so a stack added to for_each_stack becomes driven here with no edit.
# ⚠️ A compose file added to _common.sh but NOT listed here reports as undriven,
#    the exact inversion of the fault this tool catches. Eleven files below:
#    the ten stacks (LOGGER STORAGE and the SQL cluster included) plus the
#    manager.
DOCKERS="$DOCKERS_DIR" \
PRESENT="$PRESENT_NAMES" \
RUNNING="$RUNNING_NAMES" \
DRIVEN="$COMPOSE_FILE
$SQLCLUSTER_COMPOSE_FILE
$BAREMETAL_COMPOSE_FILE
$MQTT_COMPOSE_FILE
$PORTAL_COMPOSE_FILE
$NMOS_COMPOSE_FILE
$NETBOX_COMPOSE_FILE
$AES70_COMPOSE_FILE
$EMBER_COMPOSE_FILE
$LOGGER_COMPOSE_FILE
$MANAGER_COMPOSE_FILE" \
MODE="$MODE" \
PLUGIN_ROLES="$APKAUDIO_PLUGIN_ROLES" \
python3 - <<'PY'
import os
import re
import json
import glob

dockers = os.environ.get("DOCKERS") or ""
present = {n for n in (os.environ.get("PRESENT") or "").splitlines() if n}
running = {n for n in (os.environ.get("RUNNING") or "").splitlines() if n}
driven = {os.path.realpath(p) for p in (os.environ.get("DRIVEN") or "").splitlines() if p}

# Anchored at line start: a `name:` indented under services: is a service key,
# a top-level one is the project. That is the whole definition of a stack root.
PROJECT = re.compile(r'^name:\s*["\']?([^"\'\s#]+)', re.M)
CONTAINER = re.compile(r'^\s+container_name:\s*["\']?([^"\'\s#]+)', re.M)
# STOPPED is the third state: a declared container that EXISTS and is NOT
# RUNNING is in neither `absent` nor the `running` count, so nothing named it.
# NOT "every container that is not running" — Storage-Schema-Init and
# APK-NMOS-Facade carry restart: "no" because they are one-shots, and a column
# that fired on the happy path every poll would be learnt as noise. So STOPPED
# is scoped to the containers DOCKER WAS TOLD TO KEEP UP.
# The policy is read off the compose file per service block, because that is
# where the promise is made; docker inspect answers nothing about a service
# whose container is gone.
# Both keys are matched per line KEEPING THE INDENT — pairing a container with
# its own restart: needs to know which block each is in, and findall over the
# whole text throws that away.
CONTAINER_LINE = re.compile(r'^(\s+)container_name:\s*["\']?([^"\'\s#]+)')
RESTART_LINE = re.compile(r'^(\s+)restart:\s*["\']?([^"\'\s#]+)')
# A service behind `profiles:` is not part of the default stack, so it is
# DECLARED-BUT-NOT-EXPECTED: counted separately, never absent, dark or stopped.
# Otherwise NMOS-Testing and APK-NMOS-Facade sit in `absent` on a healthy bench.
# Read as a LINE, which is why the compose file writes the inline form
# `profiles: ["conformance"]`. The block form reads here as unprofiled — the
# same answer as before the key existed, and the safe direction to be wrong in.
PROFILE_LINE = re.compile(r'^(\s+)profiles:\s*(\S.*)$')

# Docker default when a service says nothing: no restart, so it belongs with
# the one-shots rather than the containers the daemon holds open.
DEFAULT_RESTART = "no"
NOT_HELD_OPEN = {"no", "none", ""}


def restart_policies(lines):
    """{container_name: restart policy} and the set of PROFILED container names.

    A SINGLE PASS OVER THE LINES, keyed on indentation rather than on a YAML
    parse, for the same reason the regexes above are regexes: this script is on
    the dashboard's two-second cadence and reads nine files every time, and
    every stack root here indents its service keys the same way. The indent of
    the FIRST `container_name:` defines the item level; anything shallower ends
    the block, anything deeper is inside some other key and is not ours.

    A file this cannot read yields an empty map, and an unknown policy is
    DEFAULT_RESTART -- the answer that raises no alarm. A parser that guessed
    the other way would report every one-shot on the bench as a fault.

    The profiled set rides along in this same pass rather than in a second one:
    both keys are per-service and this walk already knows which service block
    every line is in, which is the thing a `findall` over the whole text cannot.
    """
    item_indent = None
    for line in lines:
        match = CONTAINER_LINE.match(line)
        if match:
            item_indent = len(match.group(1))
            break
    if item_indent is None:
        return {}, set()
    policies = {}
    profiled = {}
    name = None
    policy = None
    has_profile = None
    for line in lines:
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        indent = len(line) - len(line.lstrip())
        if indent < item_indent:
            if name:
                policies[name] = policy or DEFAULT_RESTART
                if has_profile:
                    profiled[name] = has_profile
            name = policy = None
            has_profile = None
            continue
        if indent != item_indent:
            continue
        match = CONTAINER_LINE.match(line)
        if match:
            if name:
                policies[name] = policy or DEFAULT_RESTART
                if has_profile:
                    profiled[name] = has_profile
            name, policy = match.group(2), None
            # NOT reset here: profiles: may sit ABOVE container_name: in the
            # same block (it does in the NMOS file), so the flag is carried
            # across the pair and cleared when the block ends.
            continue
        if PROFILE_LINE.match(line):
            has_profile = [r.strip(" \"'") for r in PROFILE_LINE.match(line).group(2).strip("[] ").split(",")
                           if r.strip(" \"'")] or ["?"]
            continue
        match = RESTART_LINE.match(line)
        if match:
            policy = match.group(2)
    if name:
        policies[name] = policy or DEFAULT_RESTART
        if has_profile:
            profiled[name] = has_profile
    return policies, profiled

PLUGIN_ROLES = {r for r in (os.environ.get("PLUGIN_ROLES") or "").split(",") if r}

stacks = []
# TWO RUNGS, NOT ONE. It was `<stack>/Docker/<file>` after the 2026-09-06 split
# and is `POD:<pod>/<stack>/Docker/<file>` since the pods landed — and DockTor's
# own stack still sits at the first depth, so BOTH are walked rather than either
# replaced. With only the shallow glob this file reported a repository of ONE
# stack (the manager) and the dashboard drew a bench with nothing on it.
# ⚠️ A GLOB THAT MATCHES NOTHING IS NOT AN ERROR IN PYTHON, which is the whole
#    reason this went unnoticed: a wrong rung reads exactly like a repo that
#    declares no stacks. `seen` is what keeps a file found by both patterns —
#    or through a compatibility symlink — from being counted twice.
seen_paths = set()
patterns = (os.path.join(dockers, "*", "Docker", "docker-compose*.yml"),
            os.path.join(dockers, "*", "*", "Docker", "docker-compose*.yml"))
for path in sorted({p for pattern in patterns for p in glob.glob(pattern)}):
    real_path = os.path.realpath(path)
    if real_path in seen_paths:
        continue
    seen_paths.add(real_path)
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        continue
    project = PROJECT.search(text)
    if not project:
        continue                      # an overlay, not a stack root
    all_declared = CONTAINER.findall(text)
    policies, profiled = restart_policies(text.splitlines())
    # DECLARED means "this bench is supposed to be running it". A profiled
    # service is declared to COMPOSE and not to the bench, so it is removed
    # once here and no derivation below has to remember the exception.
    # A PLUGIN IN A ROLE THIS NODE RUNS IS EXPECTED, NOT OPTIONAL. The roles
    # are APKAUDIO_PLUGIN_ROLES (_common.sh, every role by default); a plugin
    # outside them is `idle` — declared, deliberately not started — and the
    # page draws it grey rather than red.
    enabled = lambda n: n in profiled and any(r in PLUGIN_ROLES for r in profiled[n])
    declared = [name for name in all_declared if name not in profiled or enabled(name)]
    optional = [name for name in all_declared if name in profiled and not enabled(name)]
    absent = [name for name in declared if name not in present]
    stacks.append({
        # The grandparent: the parent of every compose file is the literal
        # Docker/. staleness.sh walks the same way.
        "stack": os.path.basename(os.path.dirname(os.path.dirname(path))),
        "compose_file": path,
        "project": project.group(1),
        # EVERY APK:plugin:* STACK IS DRIVEN: up-stack.sh finds it by name and
        # switches on its own roles, so a button here can bring it back.
        "driven": os.path.realpath(path) in driven
                  or os.path.basename(os.path.dirname(os.path.dirname(path))).startswith("APK:plugin:"),
        "declared": declared,
        # The profiled ones, and whichever are switched on. Named rather than
        # counted because the only question is WHICH — a conformance suite left
        # running after a pass is 732 MB and a published 5000/5001.
        "optional": optional,
        "optional_present": [n for n in optional if n in present],
        "idle": ["%s:%s" % (n, "|".join(profiled.get(n) or [])) for n in optional if n not in present],
        "present": [n for n in declared if n in present],
        "running": [n for n in declared if n in running],
        "absent": absent,
        # PRESENT, NOT RUNNING, AND MEANT TO BE RUNNING. Derived here so no
        # caller has to subtract two lists and remember the one-shot exemption.
        "stopped": [n for n in declared
                    if n in present and n not in running
                    and policies.get(n, DEFAULT_RESTART).lower() not in NOT_HELD_OPEN],
        # DARK is "not one of its containers exists". A stack missing one of
        # five is a container down; missing all five is a stack GONE, and only
        # the second is worth interrupting an operator over.
        "dark": bool(declared) and not any(n in present for n in declared),
    })

# Dark-and-undriven first: the rows nothing in this tool can fix must be read
# before the rest.
stacks.sort(key=lambda s: (not (s["dark"] and not s["driven"]),
                           not s["dark"], s["stack"].lower()))

mode = os.environ.get("MODE") or "tsv"

if mode == "json":
    print(json.dumps({
        "stacks": stacks,
        "dark": [s["stack"] for s in stacks if s["dark"]],
        "unrestorable": [s["stack"] for s in stacks if s["dark"] and not s["driven"]],
        # FLAT and of CONTAINERS, because the caller restarts containers, not
        # stacks: three of NetBox five exited and two did not.
        "stopped": [n for s in stacks for n in s["stopped"]],
        "optional_present": [n for s in stacks for n in s["optional_present"]],
    }, indent=2))
elif mode == "report":
    # THE ONLY VOICE IN THIS FILE — addressed to whoever pressed the button,
    # and printed after it finished: a warning ahead of a panic is unread.
    stranded = [s for s in stacks if s["dark"] and not s["driven"]]
    dark_driven = [s for s in stacks if s["dark"] and s["driven"]]
    stopped = [s for s in stacks if s["stopped"]]
    # The event belongs to --report only, so panic.sh and panic-reboot.sh both
    # put it on the bus without holding a copy of the payload. tsv/json stay
    # silent: they are polled on every dashboard refresh.
    print("@EVENT STACKS_STRANDED %s" % json.dumps(
        {"stranded": [s["stack"] for s in stranded],
         "containers": [n for s in stranded for n in s["absent"]],
         "dark_but_driven": [s["stack"] for s in dark_driven],
         "stopped": [n for s in stopped for n in s["stopped"]]},
        separators=(",", ":")))
    if not stranded and not dark_driven and not stopped:
        print("\u2713 Every stack this repository declares has containers on this host, "
              "and every one of them is running.")
    # NOT a warning: an optional container that is up is somebody conformance
    # pass. Saying which one is how anybody finds out it was left behind.
    switched_on = [n for s in stacks for n in s["optional_present"]]
    if switched_on:
        print("")
        print("\u2139 Switched on beyond the default bench: %s"
              % ", ".join(switched_on))
    if dark_driven:
        print("")
        print("\u26a0 DARK, AND THIS TOOL DRIVES THEM \u2014 a remount should have "
              "brought these back:")
        for s in dark_driven:
            print("   %s \u2014 %d container(s) declared, none present: %s"
                  % (s["stack"], len(s["declared"]), ", ".join(s["absent"])))
    if stopped:
        # BEFORE the stranded block: this is the cheaper and likelier half —
        # an exited container is one docker start from back.
        print("")
        print("\u26a0 PRESENT, AND NOT RUNNING \u2014 these exited and nothing "
              "brought them back:")
        for s in stopped:
            print("   %s \u2014 %s" % (s["stack"], ", ".join(s["stopped"])))
        print("")
        print("   docker start %s"
              % " ".join(n for s in stopped for n in s["stopped"]))
        print("   ...or ask why they stopped first: a full disk exits every writer")
        print("   on the box at once, and `./host.sh` says whether that is what this is.")
        print("   One-shots -- the services that carry `restart: \"no\"` -- are not here.")
    if stranded:
        total = sum(len(s["absent"]) for s in stranded)
        print("")
        print("\U0001f6a7 %d STACK(S), %d CONTAINER(S), THAT NOTHING HERE WILL "
              "RESTART." % (len(stranded), total))
        print("   These compose files are not driven by any verb in this folder, and a")
        print("   panic removes containers host-wide. They are down until somebody says:")
        for s in stranded:
            print("")
            print("   %s  (project %s) \u2014 %s"
                  % (s["stack"], s["project"], ", ".join(s["absent"])))
            print("     docker compose -f '%s' up -d --build" % s["compose_file"])
        print("")
        print("   Why they are not driven is written in _common.sh beside the arrays")
        print("   for the ones that are. If one of these SHOULD come back with the")
        print("   bench, that is the file to change \u2014 not this report.")
else:
    for s in stacks:
        print("\t".join([
            s["stack"], s["compose_file"], s["project"],
            "yes" if s["driven"] else "no",
            str(len(s["declared"])), str(len(s["present"])), str(len(s["running"])),
            ",".join(s["absent"]),
            ",".join(s["stopped"]),
            ",".join(s["idle"]),
        ]))
PY
