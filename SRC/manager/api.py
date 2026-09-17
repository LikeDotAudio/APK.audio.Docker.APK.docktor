# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""🔌 The manager as data. Every question the window used to answer, as JSON.

OWNS the route table: what may be asked, what may be done, the shape of each
answer. Opens no socket, writes no HTML — serve.py is the transport, web/ the
client, both replaceable without touching this file.
DOES NOT OWN docker. Every verb is one executable file in
`DockTor/SRC/docker scripts/`. No compose command, no format string,
no port, no container name here.
THE READ / ACT SPLIT IS THE SAFETY MODEL, enforced by the two tables below:
serve.py refuses a READ over POST and an ACTION over GET, so a prefetch, a
crawler or an <img src> elsewhere cannot stop a container.
ONE ACTION AT A TIME. ACTION_LOCK is held for a whole run and a second request
is REFUSED, not queued — a rebuild that starts twenty minutes late is worse
than one that never started.
EXCEPT `down` and `panic`, which carry `preempts`: they cancel the holder, wait,
then run. "Refused, another action is already running" answers a stop with the
reason for pressing it.
"""

import os
import re
import glob
import json
import time
import socket
import threading

from .paths import DOCKERS_DIRECTORY, DOCKER_SCRIPTS_DIRECTORY, REPOSITORY_ROOT
from .bus import emit
from . import palette
from .runner import (run_management_script, cancel_running_scripts,
                     cancel_epoch, running_scripts)
from .readers import (read_containers, read_container_apps, read_app_plane,
                      read_page_titles, sample_resources, inspect_container_json,
                      read_container_api, read_bus_topics, read_stacks,
                      read_container_purpose, read_stale_images, read_host,
                      read_host_disk, read_volumes, read_volume_history,
                      record_volume_sample, storage_directory,
                      VOLUME_SAMPLE_SECONDS)
from .diagnose import (diagnose_state, health_status, port_mappings,
                       network_addresses, service_endpoints, configuration_path)
from .report import publish_status_report, publish_refresh_status, run_reported
from .provenance import container_provenance
from .readers import watchdog_active


# ---------------------------------------------------------------------------
# WHO IS ANSWERING — a different question from whether anything is.
# network_mode: host puts the containerised manager and a terminal manager on
# the SAME 127.0.0.1:8765, and the compose file binds the checkout at its host
# path on both sides, so `repository_root` is identical by construction. Three
# probes asked only "does /api/health answer" and all three called a container
# healthy while it restart-looped, because a terminal manager answered for it.
# COMPUTED ONCE AT IMPORT: `containerised` is the /.dockerenv test, and the pid
# is the pid owning the socket — resolvable from inside this container only.
INSTANCE = {
    "pid": os.getpid(),
    "hostname": socket.gethostname(),
    "containerised": os.path.exists("/.dockerenv"),
}


# ---------------------------------------------------------------------------
# WHAT MAY BE DONE. One row per verb: script, fixed arguments, and whether the
# client must ask first.
# `confirm` IS A CLIENT HINT, NOT A CONTROL — it decides whether the browser
# raises a dialog and nothing here. What bounds these is that each is a file in
# docker scripts/ that already refuses what it should.
# EVERY ROW IS ONE run_reported CALL AND NO BRANCH: the window this replaces had
# a fallback on one of them, so the button did two things depending on checkout.
# NOTHING HERE GATES BEFORE CALLING — up.sh, rebuild-all.sh and rebuild-core.sh
# run the gates themselves, and a caller that gates first runs them twice.
# ---------------------------------------------------------------------------
ACTIONS = {
    "up": {
        "label": "🚀 Remount All Containers",
        "script": "up.sh", "args": [], "confirm": None,
        "done": "✅ Remount completed successfully.",
        "failed": "❌ Remount FAILED — up.sh exited {code}. Read the output above.",
    },
    "rebuild-all": {
        "label": "⚡ Rebuild All Dockers & Mount",
        "script": "rebuild-all.sh", "args": [],
        "confirm": "Delete every image and rebuild from scratch?\n\n"
                   "The containers are removed FIRST, so if the build fails the "
                   "bench is left DOWN. This takes many minutes.",
        "done": "✅ Delete Old, Rebuild & Mount completed successfully.",
        "failed": "❌ Rebuild FAILED — the script exited {code}.\n"
                  "   The old containers were already removed, so the stack is DOWN.\n"
                  "   Read the docker output above; nothing here was rolled back.",
    },
    "rebuild-core": {
        "label": "🔨 Rebuild Project Docker",
        "script": "rebuild-core.sh", "args": ["apk-audio"], "confirm": None,
        "done": "✅ Project docker rebuilt successfully.",
        "failed": "❌ Project rebuild FAILED — rebuild-core.sh exited {code}.",
    },
    # PREEMPTS. The confirm says so: cancelling a rebuild halfway is a
    # different act from stopping a settled bench, and the dialog is the only
    # place a person finds out which one this is.
    "down": {
        "label": "🛑 Stop All Containers",
        "script": "down.sh", "args": [], "preempts": True,
        "confirm": "Stop every container in both stacks?\n\nIf a build or a "
                   "remount is running, it is CANCELLED first — killed where it "
                   "stands, with nothing rolled back — and then everything is "
                   "stopped.",
        "done": "🛑 All containers stopped.",
        "failed": "❌ Teardown reported errors — down.sh exited {code}.",
    },
    "remove-other": {
        "label": "🗑️ Remove Other System Containers",
        "script": "remove-other-containers.sh", "args": [],
        "confirm": "Remove every container on this host that is NOT part of "
                   "APK.audio?\n\nThe keep-set is read from the compose files, "
                   "not from a name list.",
        "done": "✅ Other containers removed.",
        "failed": "❌ Sweep FAILED — remove-other-containers.sh exited {code}.",
    },
    # NO NAMES ARE PASSED: what is dead is docker state word at the moment the
    # sweep runs, not a five-second-old repaint.
    "clear-dead": {
        "label": "⚰️ Clear Dead Containers",
        "script": "remove-dead-containers.sh", "args": [],
        "confirm": "Remove every container that is not running?\n\n"
                   "Running containers are untouched, and no named volume is removed.",
        "done": "✅ Dead containers cleared.",
        "failed": "❌ Clear FAILED — remove-dead-containers.sh exited {code}.",
    },
    # TWO MEANINGS AND THE SCRIPT PICKS WHICH, which is why there is one row
    # and no branch: panic.sh spares the manager, so on a bench where nothing
    # else is left it escalates to rebooting the manager from the code.
    # THE CONFIRM SAYS BOTH — the mode is read off docker when the script runs,
    # so a dialog promising one would be lying half the time.
    "panic": {
        "label": "🚨 PANIC / SOS Emergency Stop",
        "script": "panic.sh", "args": ["PANIC_WEB"], "preempts": True,
        "confirm": "🚨 EMERGENCY PANIC\n\nAnything running is CANCELLED first.\n\n"
                   "FORCE KILL and unmount every container "
                   "instantly?\n\nThe container manager is spared — it is what "
                   "is presenting this page.\n\nIF NOTHING ELSE IS RUNNING, this "
                   "instead REBOOTS the manager: every image is rebuilt from the "
                   "code and swapped out underneath, this page included. That "
                   "takes minutes and the tab will go dark on the way.",
        "done": "🚨 Panic complete.",
        "failed": "🚨 Panic escalation exited {code} — read the output above.",
    },
    "verify": {
        "label": "🧪 Run Container Tests",
        "script": "verify.sh", "args": [], "confirm": None,
        "done": "✅ Container tests passed.",
        "failed": "❌ Container tests FAILED — verify.sh exited {code}.",
    },
    "gates": {
        "label": "🛡️ Pre-build Gates Only",
        "script": "test-gates.sh", "args": [], "confirm": None,
        "done": "✅ Pre-build gates passed.",
        "failed": "❌ Pre-build gates FAILED — the build must not proceed.",
    },
    "clear-logs": {
        "label": "🗑️ Clear All Docker Logs",
        "script": "clear-logs.sh", "args": [],
        "confirm": "TRUNCATE every container's log file on disk?",
        "done": "✅ All docker container log files cleared.",
        "failed": "❌ Truncate exited {code} — see the named files above.",
    },
    "free-ports": {
        "label": "💥 Free Every Published Port",
        "script": "free-ports.sh", "args": [],
        "confirm": "Kill whatever holds each published host port?",
        "done": "✅ Published host ports freed.",
        "failed": "❌ Port eviction exited {code}.",
    },
    "prune": {
        "label": "♻️ Reclaim Docker Storage",
        "script": "prune.sh", "args": [],
        "confirm": "Reclaim unused docker storage? Named volumes are never touched.",
        "done": "✅ Storage reclaimed.",
        "failed": "❌ Prune exited {code}.",
    },
    # THE BUTTON FOR AN ACT EVERY BUILD ALREADY PERFORMS: clean_build_cache in
    # _common.sh runs the same script after every successful build, so this row
    # is the sweep between builds — and the only way to ask for `--all`, which
    # is why it takes a confirm and the automatic one does not. NO IMAGE AND NO
    # CONTAINER IS TOUCHED; the running bench does not notice.
    "clean-cache": {
        "label": "🧽 Clean Build Cache",
        "script": "clean-build-cache.sh", "args": [],
        "confirm": "Drop the docker build cache?\n\nOnly the cache — no image, "
                   "no container and no volume is touched, and nothing running "
                   "is interrupted. The next build re-does whatever layers this "
                   "removes.",
        "done": "✅ Build cache cleaned.",
        "failed": "❌ Build cache clean exited {code}.",
    },
    "clean-cache-all": {
        "label": "🧼 Clean Build Cache (everything)",
        "script": "clean-build-cache.sh", "args": ["--all"],
        "confirm": "Drop EVERY byte of build cache?\n\nThis takes the warm "
                   "layers the next build would have reused as well, so the "
                   "next rebuild is a cold one — minutes, not seconds, on the "
                   "Rust images. Still no image, container or volume is "
                   "touched.",
        "done": "✅ Build cache emptied.",
        "failed": "❌ Build cache clean exited {code}.",
    },
    # THE ONE VERB THAT CREATES STORAGE RATHER THAN RECLAIMING IT, and the
    # button the VOLUMES tab points at when the pointer is red. It makes the
    # folder and the named volume that binds it; it REPAIRS NOTHING, because
    # re-pointing an existing volume means deleting it and the bytes under the
    # old folder are the series this tab draws. NO CONFIRM: a directory and a
    # volume record is the least destructive thing on this page.
    "storage-volume": {
        "label": "📦 Create DockTor Storage Volume",
        "script": "storage-volume.sh", "args": ["--ensure"], "confirm": None,
        "done": "✅ DockTor storage volume is in place.",
        "failed": "❌ Storage volume setup exited {code} — read the output above.",
    },
    # ── TWO VERBS ABOUT A HOST PROCESS RATHER THAN A CONTAINER, and this tool
    # has had a reason for them since the day it was containerised: a DockTor
    # started at a terminal holds 127.0.0.1:8765 on the host network stack, so
    # the CONTAINER manager can never bind and no remount can win. The dark
    # band has always said so — and then printed `kill <pid>` for a person to
    # paste. These are that sentence with a button under it.
    "list-pids": {
        "label": "🔎 What Holds the Manager Port",
        "script": "kill-pid.sh", "args": ["--list"], "confirm": None,
        "done": "✅ Listed above: what is listening, and every DockTor process.",
        "failed": "❌ Could not list processes — kill-pid.sh exited {code}.",
    },
    # THE ONLY ROW IN THIS TABLE THAT TAKES A VALUE FROM THE PERSON. `prompt`
    # is how the client knows to ask, and `pattern` is checked AGAIN in
    # run_action and a THIRD time in the script: this value reaches a signal,
    # and a client is not a place to enforce anything.
    "kill-pid": {
        "label": "🔪 Kill a Process (by pid)",
        "script": "kill-pid.sh", "args": [],
        "prompt": {
            "label": "Process id",
            "placeholder": "e.g. 182129",
            "pattern": "^[0-9]{1,7}$",
            "hint": "Press 🔎 first — it lists what holds the port, with pids.",
        },
        "confirm": "Send SIGTERM to this process (then SIGKILL if it ignores "
                   "it)?\n\nTHIS IS A HOST PROCESS, NOT A CONTAINER. If the pid "
                   "is the DockTor serving this page, that is a legitimate use "
                   "— it is how a terminal manager stands aside for the "
                   "container — but THIS TAB WILL GO DARK. The container takes "
                   "the socket within about five seconds; reload and it is "
                   "serving.",
        "done": "✅ The process is stopped.",
        "failed": "❌ kill-pid.sh exited {code} — read the output above. Exit 2 "
                  "means it REFUSED and signalled nothing.",
    },
    # ☢️ THE ONLY VERB IN THIS FILE THAT DELETES THE DATA. Every other cleanup
    # row is built around never touching a named volume — prune.sh says so in
    # its own header — and this one removes them by name, on purpose, along
    # with every container, image, network and byte of build cache on the host.
    # THREE DIALOGS, WHICH IS WHY `confirms` IS A LIST. One dialog is a speed
    # bump on a verb people press by accident; the third ask here is a DIFFERENT
    # QUESTION from the first (the data, not the containers), and the last one
    # will not arm its button until the word is typed — see `verify`.
    # THE DIALOGS ARE STILL ONLY A CLIENT HINT, and this is the row where that
    # would have mattered: what actually bounds it is that nuke.sh REFUSES
    # without --yes-nuke-everything and prints its rehearsal instead, so the
    # token in `args` is the consent and a caller that skipped the dialogs
    # cannot reach the destructive half by accident.
    # PREEMPTS, for down.sh's reason: a rebuild in flight is not a reason to
    # make somebody wait to empty the bench.
    "nuke": {
        "label": "☢️ NUKE EVERYTHING",
        "script": "nuke.sh", "args": ["--yes-nuke-everything", "NUKE_WEB"],
        "preempts": True,
        "verify": "NUKE",
        "confirms": [
            "☢️ NUKE EVERYTHING — 1 of 3\n\n"
            "Stop and REMOVE every container on this host, then delete every "
            "image, every network and all build cache.\n\n"
            "This is not a cleanup. Nothing is spared except the manager "
            "itself, which is the page you are reading this on.\n\n"
            "Anything running is CANCELLED first.",

            "☢️ NUKE EVERYTHING — 2 of 3\n\n"
            "THE NAMED VOLUMES GO TOO. That is the DATA:\n"
            "  · mariadb-data — the database\n"
            "  · broker-data · mqtt-exchange — retained bus state\n"
            "  · baremetal-state · gui-frames — the node's memory\n\n"
            "Every other button here refuses to touch these. This one deletes "
            "them by name. Nothing takes a backup, and NOTHING IN THIS "
            "REPOSITORY WILL BRING THE DATA BACK — a rebuild afterwards mounts "
            "EMPTY databases.",

            "☢️ NUKE EVERYTHING — 3 of 3\n\n"
            "Last ask. After this the bench is bare: every image rebuilds from "
            "the code, from nothing, and that takes many minutes on a good "
            "link.\n\n"
            "Containers, images and volumes belonging to OTHER work on this "
            "machine go as well — this is host-wide, not scoped to "
            "APK.audio.\n\n"
            "Type NUKE below if you mean it.",
        ],
        "done": "☢️ NUKE COMPLETE — docker is empty. The volumes are gone with "
                "everything else; what comes back is a bare bench.",
        "failed": "❌ Nuke exited {code} — read the output above for how far it "
                  "got. Exit 2 means it REFUSED and removed nothing.",
    },
    "phoenix": {
        "label": "🔥 Phoenix (Burn & Clean Rebuild)",
        "script": "phoenix.sh", "args": ["PHOENIX_WEB"],
        "preempts": True,
        "verify": "PHOENIX",
        "confirms": [
            "🔥 PHOENIX — 1 of 2\n\n"
            "This will delete EVERY container, image, network, build cache "
            "AND NAMED VOLUME (all local data) on this host, and then "
            "perform a clean rebuild from source code.\n\n"
            "Anything running is CANCELLED first.",

            "🔥 PHOENIX — 2 of 2\n\n"
            "Last ask before burning down and restarting.\n\n"
            "Type PHOENIX below to proceed.",
        ],
        "done": "🔥 PHOENIX COMPLETE — Ecosystem fully burned down and reborn fresh from code!",
        "failed": "❌ Phoenix exited {code} — read the output above.",
    },
    "disk": {
        "label": "💾 What Docker Is Holding",
        "script": "disk.sh", "args": [], "confirm": None,
        "done": "", "failed": "❌ disk.sh exited {code}.",
    },
}

# Verbs that take a CONTAINER NAME. Separate table because the arity differs
# and because each is scoped to one card, so a client with nothing selected
# cannot reach them.
CONTAINER_ACTIONS = {
    "restart": {
        "label": "🔄 Restart", "script": "restart.sh", "confirm": None,
        "done": "✅ {name} restarted.",
        "failed": "❌ Could not restart {name} — restart.sh exited {code}.",
    },
    # The compose file is asked of the CONTAINER, so this reaches a container
    # in a project neither compose array names.
    "rebuild": {
        "label": "🧱 Rebuild", "script": "rebuild.sh",
        "confirm": "Rebuild the image behind '{name}' and replace it?\n\n"
                   "Only this container is touched. The old one keeps running "
                   "until the build succeeds, so a failed build leaves the "
                   "bench as it is.",
        "done": "✅ {name} rebuilt and running.",
        "failed": "❌ Could not rebuild {name} — the script exited {code}.\n"
                  "   Read the output above; nothing else was touched.",
    },
    # NOT --force. The card said this was stopped; if the script finds it
    # running, the card was stale and the refusal is the right answer.
    "remove": {
        "label": "🗑️ Remove", "script": "remove-dead-containers.sh",
        "confirm": "Remove the container '{name}'?\n\nIts named volumes are not "
                   "touched. If it has started again since the card was drawn, "
                   "the removal is refused rather than forced.",
        "done": "✅ {name} removed.",
        "failed": "❌ Could not remove {name} — the script exited {code}.\n"
                  "   Read the output above; nothing else was touched.",
    },
    "logs": {
        "label": "📜 Logs", "script": "logs.sh", "confirm": None,
        "done": "", "failed": "❌ logs.sh exited {code}.",
    },
}

# Verbs that take a STACK NAME — the directory under APK:PODS/, which is
# what stacks.sh prints and what every dark row already carries. A third table
# for the CONTAINER_ACTIONS reason: different arity, scoped to one band row.
# WHY UP-STACK EXISTS: the dark-stack band button used to be `up` — the whole
# bench, eight compose files, minutes of build, for a row naming ONE stack — and
# on DockTor it rebuilt everything EXCEPT that stack, because
# for_each_stack does not drive the manager compose file. up-stack.sh resolves
# the name through compose_for_stack, so no stack compose command is spelled
# twice.
# THREE VERBS AT ONE POD, and the grid is why there are three: the cards are
# lassoed by pod now, so the unit a hand reaches for is the pod and not the
# bench. Each is one file in docker scripts/ and each refuses the manager pod
# from inside the manager, for the reason written in all three.
STACK_ACTIONS = {
    "up-stack": {
        "label": "🚀 Remount This Stack", "script": "up-stack.sh", "confirm": None,
        "done": "✅ {name} remounted.",
        "failed": "❌ Could not remount {name} — up-stack.sh exited {code}.\n"
                  "   Only that stack was touched; read the output above.",
    },
    # NOT up-stack WITH A FLAG: that one builds what changed and is the cheap
    # daily verb; this one is --no-cache and minutes, and the confirm is what
    # separates them at the button.
    "rebuild-stack": {
        "label": "🧱 Rebuild This Pod",
        "script": "rebuild-stack.sh",
        "confirm": "Rebuild every image in {name} from scratch?\n\n"
                   "--no-cache, so this takes minutes — a Rust pod longer. The "
                   "containers are replaced one at a time AFTER the build "
                   "succeeds, so a failed build leaves this pod running as it "
                   "is rather than down.",
        "done": "✅ {name} rebuilt from scratch and running.",
        "failed": "❌ Rebuild of {name} FAILED — rebuild-stack.sh exited {code}.\n"
                  "   Only that pod was touched; read the output above.",
    },
    # IN PLACE: compose restart, nothing rebuilt or recreated. The cheapest of
    # the four, for a pod that is up and merely wedged.
    "restart-stack": {
        "label": "🔄 Restart This Pod", "script": "restart-stack.sh", "confirm": None,
        "done": "✅ {name} restarted.",
        "failed": "❌ Could not restart {name} — restart-stack.sh exited {code}.\n"
                  "   Only that pod was touched; read the output above.",
    },
    # "DELETE" BECAUSE THAT IS WHAT IT DOES TO THE CONTAINERS — they are removed,
    # not paused. The volumes and images stay, and the confirm says so.
    "down-stack": {
        "label": "🗑️ Delete This Pod",
        "script": "down-stack.sh",
        "confirm": "Take {name} off the bench?\n\n"
                   "Its containers are stopped and removed. NO NAMED VOLUME is "
                   "touched and no image is deleted, so a remount brings it "
                   "back with its data — and nothing in any other pod is "
                   "stopped.",
        "done": "🛑 {name} is off the bench.",
        "failed": "❌ Could not stop {name} — down-stack.sh exited {code}.",
    },
}

# ONE ACTION AT A TIME, refused rather than queued. See the module header.
ACTION_LOCK = threading.Lock()

# How long a preempting verb waits for the lock after issuing the cancel. The
# cancel closes the pipe the runner is blocked reading, so a holder normally
# lets go within a beat; this ceiling turns a wedged holder into a refusal
# rather than a request that never answers.
PREEMPT_WAIT_SECONDS = 25.0


def confirmations(row):
    """Every dialog a client must raise for this verb, in order. Possibly none.

    ONE SHAPE FOR BOTH, so no client needs a branch: an ordinary verb writes
    `confirm` (a string, or None for the verbs that just run) and the rare one
    that earns more than one ask writes `confirms` (a list). Both arrive as a
    list, and `confirm` is still sent as its first entry so a client that only
    knows the old field asks once rather than not at all.
    """
    if row.get("confirms"):
        return list(row["confirms"])
    return [row["confirm"]] if row.get("confirm") else []


def action_table():
    """What the client may offer, and what it must ask before offering it.

    `preempts` travels to the client because the browser greys every button for
    the length of a run, and a stop that is greyed out during a rebuild does
    not exist. It is a hint about drawing; run_action() enforces it.
    `verify` is the word the LAST dialog demands be typed before its button
    arms — one verb has one, and a client that ignores it still asks three
    times. Like `confirm`, it bounds nothing: nuke.sh's own token does.
    """
    return {
        # `prompt` travels for the same kind of reason `verify` does: it tells a
        # client to ask for a value and what shape it has to be. It bounds
        # nothing — run_action() re-checks the pattern and kill-pid.sh checks it
        # a third time before the value goes anywhere near a signal.
        "actions": {key: {"label": row["label"],
                          "confirm": (confirmations(row) or [None])[0],
                          "confirms": confirmations(row),
                          "verify": row.get("verify"),
                          "prompt": row.get("prompt"),
                          "preempts": bool(row.get("preempts"))}
                    for key, row in ACTIONS.items()},
        # No container verb preempts: they are scoped to one card, and a stop
        # aimed at one container is not an escape hatch from a rebuild.
        "container_actions": {key: {"label": row["label"],
                                    "confirm": (confirmations(row) or [None])[0],
                                    "confirms": confirmations(row),
                                    "preempts": False}
                              for key, row in CONTAINER_ACTIONS.items()},
        # Nor does a stack verb, for the same reason one rung up.
        "stack_actions": {key: {"label": row["label"],
                                "confirm": (confirmations(row) or [None])[0],
                                "confirms": confirmations(row),
                                "preempts": False}
                          for key, row in STACK_ACTIONS.items()},
    }


# ---------------------------------------------------------------------------
# WHICH CONTAINERS ARE OURS. Docker own com.docker.compose.project label, tested
# against the project names the compose files declare.
# ⚠️ THIS DECIDES CARD ORDER AND NOTHING ELSE, which is the only reason a second
#    reading of the compose files is tolerable. The authoritative version — what
#    a SWEEP may delete — is remove-other-containers.sh. If this is ever asked to
#    gate a deletion it must be replaced by a call to that script, not extended.
# A container with no label is not a stranger by that alone: a hand-started
# apk-scratch still reads as ours on the name.
# ---------------------------------------------------------------------------
NAME_HINTS = ("apk", "apkaudio")


def declared_projects():
    """Every `name:` declared by a compose file under APK:PODS/.

    <stack>/Docker/, one rung deeper than the <stack>/ this globbed before the
    split. An empty answer raises nothing anywhere: is_ours() falls through to
    the name hints for every container, so the whole bench reads as strangers
    and the cards silently reorder.
    """
    projects = set()
    for path in glob.glob(os.path.join(DOCKERS_DIRECTORY, "*", "Docker",
                                       "docker-compose*.yml")):
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("name:"):
                        projects.add(line.split(":", 1)[1].strip().strip('"\''))
        except OSError:
            continue
    return projects


def is_ours(container, projects):
    project = (container.get("project") or "").strip()
    if project:
        return project in projects
    return any(hint in container["name"].lower() for hint in NAME_HINTS)


def _group_stack(cards):
    """The stack directory a group's cards come from, or None if they disagree.

    MAJORITY, NOT FIRST: a group is keyed on the container NAME, so a hand-run
    container called Storage-Scratch lands in the Storage group carrying no
    repo at all — and one such card must not be able to take the pod verbs away
    from the five that do come from a compose file.
    None when nothing in the group names a stack: the verbs are then drawn
    disabled, because there is no compose file for them to act on.
    """
    counts = {}
    for card in cards:
        repo = card.get("repo") or {}
        name = repo.get("name")
        if name:
            counts[name] = counts.get(name, 0) + 1
    if not counts:
        return None
    return max(counts, key=lambda name: (counts[name], name))


def snapshot(quiet=True, with_apps=True):
    """Every container, with its meters and its app plane, grouped by stack.

    ONE SCAN, THREE SCRIPTS: ps.sh for identity and health, stats.sh for the
    meters, apps.sh for what runs INSIDE. Joined here rather than by the client,
    which would render containers from one moment against meters from another.
    `with_apps` is False for the two-second cadence that runs while an action
    holds the bench: apps.sh curls a supervisor mid-restart.
    """
    containers, _rows = read_containers(quiet=quiet)
    stats = {row["name"]: row for row in sample_resources(quiet=quiet)}
    apps = read_container_apps(quiet=quiet) if with_apps else {}
    projects = declared_projects()
    # NOT ON THE FAST CADENCE: staleness.sh walks the COPY sources of every
    # Dockerfile — 1.28 s for all 17 declared builds here, filesystem work next
    # to a two-second beat. Same `with_apps` gate, same meaning: this is the
    # unhurried scan, and mid-rebuild the answer is changing anyway.
    staleness = {row["container"]: row
                 for row in (read_stale_images(quiet=quiet) if with_apps else [])
                 if row["container"]}

    stacks = read_stacks(quiet=quiet)
    stack_repo_map = {}
    repo_root = os.environ.get("APKAUDIO_REPO") or REPOSITORY_ROOT
    for s in stacks:
        stk = s["stack"]
        abs_stack_path = os.path.join(repo_root, "APK:PODS", stk)
        file_uri = f"file://{abs_stack_path}"
        repo_info = {"name": stk, "path": file_uri}
        if s.get("compose_file") and os.path.exists(s["compose_file"]):
            try:
                with open(s["compose_file"], encoding="utf-8", errors="replace") as handle:
                    for cname in re.findall(r'container_name:\s*["\']?([^"\'\s#]+)', handle.read()):
                        stack_repo_map[cname] = repo_info
            except OSError:
                pass
        if s.get("project") and s["project"] not in stack_repo_map:
            stack_repo_map[s["project"]] = repo_info

    cards = []
    for container in containers:
        name = container["name"]
        emoji, tone, pulse = palette.status_style(container["status"])
        row = dict(container)
        row.update({
            "emoji": emoji,
            "tone": tone,
            "pulse": pulse,
            "role": palette.role_emoji(name),
            "dead": palette.is_dead(container["status"]),
            "ours": is_ours(container, projects),
            "group": palette.group_of(name),
            "leaf": palette.leaf_of(name),
            "published": published_ports(container["ports"]),
            "apps": apps.get(name, []),
            "resources": stats.get(name),
            "staleness": staleness.get(name),
            "repo": stack_repo_map.get(name) or stack_repo_map.get(container.get("project")),
        })
        cards.append(row)

    # Our stacks first, then everything else, each alphabetical, ranked by
    # GROUP rather than per card — per-card ranking put Storage-Portal five
    # cards from Storage-Broker, because the old test was a name substring.
    groups = {}
    for card in cards:
        groups.setdefault(card["group"], []).append(card)
    HEX_HASH_PATTERN = re.compile(r"^[0-9a-fA-F]{8,64}$")
    ordered = sorted(groups,
                     key=lambda label: (bool(HEX_HASH_PATTERN.match(label)),
                                        not any(c["ours"] for c in groups[label]),
                                        label.lower()))
    # WHAT IS NOT HERE, alongside what is. Every key above describes a
    # container that EXISTS, and a grid of those cannot draw an absence: a stack
    # whose containers were all removed renders as nothing, indistinguishable
    # from a stack the repository never had.
    # ON EVERY SCAN, FAST CADENCE INCLUDED: stacks.sh is two docker ps calls and
    # six file reads, cheaper than the ps.sh above it, and the fast cadence runs
    # precisely while an action is emptying the bench.
    # ONE COLOUR PER STACK, decided over the whole bench rather than per group,
    # so adjacent stacks are never drawn alike. Keyed on `ordered` because that
    # is the order the grid lays them out.
    hues = palette.hues_for(ordered)
    document = {
        # `stack` IS WHAT THE POD VERBS TAKE, and it is NOT the label. A group is
        # `palette.group_of(name)` — a reading of the container's NAME, which is
        # how Storage-MariaDB and Storage-Portal come to sit together — while
        # up-stack.sh, rebuild-stack.sh and down-stack.sh all take the DIRECTORY
        # under APK:PODS/. The two differ on nearly every row ("Storage" is
        # `DATABASE:server:SQL`), so the client is handed the answer rather than
        # left to guess it from a label it must not parse.
        # READ OFF THE CARDS' OWN `repo`, which stack_repo_map built from the
        # container_name: lines in each compose file — so a group whose cards
        # come from one compose file gets that stack, and a group of containers
        # nothing here declares gets None and draws no verbs at all.
        "groups": [{"label": f"⚙️ MOUNTING ({label})" if HEX_HASH_PATTERN.match(label) else label,
                    "ours": any(c["ours"] for c in groups[label]),
                    "hue": hues[label],
                    "stack": _group_stack(groups[label]),
                    "containers": sorted(groups[label], key=lambda c: c["name"].lower())}
                   for label in ordered],
        "count": len(cards),
        "dead": sorted(c["name"] for c in cards if c["dead"]),
        "stacks": stacks,
        # WHETHER A VERB IS HOLDING THE BENCH: a stack that is dark DURING a
        # rebuild is not news, it is what a rebuild looks like from here.
        # Without this the band would alarm on every Rebuild & Remount, and a
        # warning that fires on the happy path is learnt as noise. ACTION_LOCK
        # is the server, so this is true for every tab.
        "action_running": ACTION_LOCK.locked(),
        # Pre-sliced for the client, so "which stacks are missing" has one
        # reading and it is this module.
        "dark_stacks": [row for row in stacks if row["dark"]],
        # WHO REMOUNTS A DARK STACK. With the server watchdog running, the page's
        # own countdown stands down: two engines on one dark stack each fired an
        # `up`, and every `up` evicted what the other had just started.
        "watchdog": watchdog_active(),
        # The third band half of the same list: dark_stacks is a stack with
        # nothing on the host, this is the container that IS on the host,
        # exited, carrying a restart policy that said it would not be. Flat and
        # of container names because that is the unit of the repair.
        # DECLARED AND DELIBERATELY NOT STARTED: plugin stacks whose role this
        # node does not run (APKAUDIO_PLUGIN_ROLES). Not a fault — the page
        # draws them grey with a start button, and nothing remounts them.
        "idle_stacks": [{"stack": row["stack"], "idle": row.get("idle", [])}
                        for row in stacks if row.get("idle") and not row["present"]],
        "stopped_containers": [{"stack": row["stack"], "container": name}
                               for row in stacks for name in row["stopped"]],
        # THE SECOND KIND OF WRONG, pre-sliced for the same reason:
        # dark_stacks is what the repository declares and this host lacks; this
        # is what the host HAS and the repository has moved past.
        # An `unbuilt` row is deliberately NOT here — that is dark_stacks news
        # one step earlier, and both bands saying it is the duplication the
        # dark-stack band was rewritten to stop.
        # ONLY THE ONES ACTUALLY HERE: the reader answers per DECLARED build, so
        # it also judges the image of a container that does not exist — and the
        # band this feeds says "up and healthy and running old code", of which
        # every word is false about an absent container.
        # `self` MARKS THE MANAGER'S OWN ROW: it is still news, but no button on
        # this page may rebuild it — a rebuild from inside kills the server
        # halfway (Exited 137, a `<id>_DockTor` left in Created). The client
        # shows it and leaves it out of every automatic or bulk rebuild.
        "stale_services": [dict(row, self=row["stack"] in {s["stack"] for s in stacks
                                                           if s.get("manager")})
                           for row in staleness.values()
                           if row["stale"] == "yes"
                           and row["container"] in {c["name"] for c in cards}],
        # THE BOX, BESIDE THE PROCESS. `manager` below is who serves this page;
        # this is what it serves it FROM. cpus and memory_bytes are the two
        # denominators the meters do not carry (docker calls one full core 100%
        # and reports an unconstrained container memory limit as the whole
        # machine), and `disk` is free space on the filesystem docker data root
        # sits on, with the verdict already taken. All three are cached behind
        # one script call: a docker info and a df twice a minute, nothing per
        # scan.
        "host": dict(read_host(quiet=quiet), disk=read_host_disk(quiet=quiet)),
        # THE PAGE HAS TO BE ABLE TO ACCUSE ITSELF: when DockTor is
        # the dark-and-driven stack, the likeliest reason is that a terminal
        # manager is holding the port the container needs, and no remount can
        # win it. The client cannot infer that, so the server says who it is.
        "manager": INSTANCE,
    }

    # THE REFRESH IS A PUBLISHER: everything above already poked docker and
    # every app plane, so this is the one moment the whole bench is known, and
    # the auto-refresh dropdown is therefore a source of status updates.
    # report.py gates it: only containers whose STATE moved are sent, on a
    # background thread.
    # NOT ON THE FAST CADENCE — those cards have no app plane, so publishing
    # them would blank the app half of every topic and fill it back a second
    # later.
    if with_apps:
        publish_refresh_status([container for group in document["groups"]
                                for container in group["containers"]])
    return document


def stacks(quiet=True):
    """Every declared stack, present or not. The answer /api/stacks serves.

    The same list snapshot() folds in, offered alone for a caller that wants
    only this — a terminal asking why a port is dead, without paying for a
    stats sample and an app plane per container.
    """
    rows = read_stacks(quiet=quiet)
    return {"stacks": rows,
            "dark": [row["stack"] for row in rows if row["dark"]],
            # The list that matters: dark AND driven by no verb here, so
            # nothing on this page will restart it.
            "unrestorable": [row["stack"] for row in rows
                             if row["dark"] and not row["restorable"]],
            # THE SECOND ABSENCE, and the cheaper one: still here, still
            # built, one docker start from back — and exited with a restart
            # policy that said it would not be. Flat and of CONTAINERS, because
            # three of NetBox five exited and two did not.
            "exited": [name for row in rows for name in row["stopped"]],
            # FREE SPACE ON THE CHEAP ENDPOINT: /api/stacks is what a terminal
            # asks when something is dead, and "the disk is full" is the answer
            # it could not get without knowing to look elsewhere. {} when
            # nothing measured it, never a zero.
            "disk": read_host_disk(quiet=quiet)}


def staleness(quiet=True):
    """Every declared build, and whether its image predates its code.

    The same rows snapshot() folds onto its cards, offered alone for a terminal
    or CI step asking "is anything running code that is not in the tree".
    `stale` is what a caller acts on; `unbuilt` sits beside it rather than
    folded in, because the two take different actions.
    """
    rows = read_stale_images(quiet=quiet)
    return {"services": rows,
            "stale": [row["container"] or row["service"]
                      for row in rows if row["stale"] == "yes"],
            "unbuilt": [row["stack"] for row in rows if row["stale"] == "unbuilt"],
            # THE WORST ONE: a caller that can act on one should act on the
            # one furthest from the truth.
            "behind_s": max([row["behind"] for row in rows] or [0])}


def published_ports(ports):
    """`1883 → 1883/tcp` for each publication, each said once.

    0.0.0.0:1883-> and [::]:1883-> are ONE publication on two address families;
    two rows doubled the height of every card to say it twice.
    """
    published = []
    for mapping in [m.strip() for m in (ports or "").split(",") if m.strip()]:
        halves = mapping.split("->")
        text = (f"{halves[0].rsplit(':', 1)[-1]} → {halves[1]}"
                if len(halves) == 2 else mapping)
        if text not in published:
            published.append(text)
    return published


def resources(quiet=True):
    """One docker stats sample, keyed by container name, and the box it is OF.

    host.cpus and host.memory_bytes ride the same route as the numbers they
    divide, or a consumer draws a ring before its denominators arrive. Both are
    the cached read, so this costs one docker stats after the first call.
    """
    return {"containers": {row["name"]: row for row in sample_resources(quiet=quiet)},
            "host": read_host(quiet=quiet)}


def container_detail(name, quiet=False):
    """Everything the detail pane used to render, as one document.

    THE APP PLANE IS FETCHED HERE, not by the client: it is up to three round
    trips (the endpoint table, the plane address, one HEAD per served tree), and
    a client making them would have to know the addresses — the port table this
    package spells nowhere.
    """
    data = inspect_container_json(name, quiet=quiet)
    if data is None:
        return None
    endpoints = service_endpoints(name, quiet=quiet)
    mappings = port_mappings(data)
    undeclared = undeclared_ports(endpoints, mappings)
    titles = read_page_titles([uri for _port, uri in undeclared]) if undeclared else {}
    state = data.get("State", {}) or {}
    config = data.get("Config", {}) or {}
    config_path = configuration_path(name, quiet=quiet)
    return {
        "name": name,
        # WHAT IT IS, beside what it is DOING: every other field here measures
        # the container in front of you and none answers "why is this here".
        # None when purpose.sh has no entry, which the pane prints as a
        # sentence rather than a blank.
        "purpose": read_container_purpose(name, quiet=quiet).get(name),
        "diagnosis": diagnose_state(data),
        "health": health_status(data),
        "state": {"status": state.get("Status", ""),
                  "running": bool(state.get("Running")),
                  "exit_code": state.get("ExitCode", 0),
                  "restarts": data.get("RestartCount", 0),
                  "oom_killed": bool(state.get("OOMKilled")),
                  "started_at": state.get("StartedAt", ""),
                  "finished_at": state.get("FinishedAt", "")},
        "created": data.get("Created", ""),
        "image": config.get("Image", ""),
        "entrypoint": config.get("Entrypoint") or [],
        "command": config.get("Cmd") or [],
        "ports": mappings,
        "networks": [{"name": net, "ip": ip} for net, ip in network_addresses(data)],
        "mac": ((data.get("NetworkSettings", {}) or {}).get("MacAddress")
                or next((detail.get("MacAddress") for detail in
                         ((data.get("NetworkSettings", {}) or {}).get("Networks", {}) or {}).values()
                         if detail.get("MacAddress")), "")),
        "endpoints": endpoints,
        "undeclared": [{"port": port, "uri": uri,
                        "title": titles.get(uri, {}).get("title", "")}
                       for port, uri in undeclared],
        "config_path": config_path,
        # WHERE IT COMES FROM: the GitHub home of the compose file, and a link for
        # every file and image that goes into the build. See provenance.py.
        "provenance": container_provenance(name, config_path, config.get("Image", ""),
                                           quiet=quiet),
        "plane": read_app_plane(name, quiet=quiet).get(name),
        "inspect": data,
    }


def undeclared_ports(endpoints, mappings):
    """[(port, uri)] for every published port the endpoint table misses.

    MATCHED ON THE PORT NUMBER, not the URI text: a substring test against a
    rendered label never matched a non-http endpoint, so MariaDB drew a
    mysql:// launcher AND an "Open Port 3306" beside it, both opening a browser
    at a wire protocol.
    """
    declared = set()
    for endpoint in endpoints:
        authority = endpoint["uri"].split("://", 1)[-1].split("/", 1)[0]
        authority = authority.rsplit("@", 1)[-1]          # drop any credentials
        if ":" in authority:
            declared.add(authority.rsplit(":", 1)[-1])

    undeclared, seen = [], set()
    for mapping in mappings:
        if "->" not in mapping:
            continue
        host_part = mapping.split("->")[0].strip()
        if ":" not in host_part:
            continue
        port = host_part.split(":")[-1]
        if port in declared or port in seen:
            continue
        seen.add(port)
        undeclared.append((port, f"http://localhost:{port}"))
    return undeclared


def endpoints(quiet=True):
    """Every address the ecosystem answers on, named where it has a name."""
    rows = service_endpoints(quiet=quiet)
    browsable = [row["uri"] for row in rows if row["kind"] == "open"]
    titles = read_page_titles(browsable, remembered_only=True) if browsable else {}
    for row in rows:
        row["title"] = titles.get(row["uri"], {}).get("title", "")
    return {"endpoints": rows}


# The file that built a container need not be inside the repository, so the
# read is BOUNDED to the checkout: a manager over HTTP that hands back any path
# the host can read is a file server.
def config_script(name, quiet=True):
    """The compose file or Dockerfile that built a container, and its text."""
    path = configuration_path(name, quiet=quiet)
    if not path:
        return {"container": name, "path": None, "text": None,
                "error": "config-path.sh could not say what built this container."}
    resolved = os.path.realpath(path if os.path.isabs(path)
                                else os.path.join(REPOSITORY_ROOT, path))
    root = os.path.realpath(REPOSITORY_ROOT) + os.sep
    if not resolved.startswith(root):
        return {"container": name, "path": path, "text": None,
                "error": "That file is outside this checkout; refusing to read it."}
    try:
        with open(resolved, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as err:
        return {"container": name, "path": path, "text": None, "error": str(err)}
    return {"container": name, "path": os.path.relpath(resolved, REPOSITORY_ROOT),
            "text": text, "error": None}


# ---------------------------------------------------------------------------
# THE MANAGER OWN ROUTE TABLE, AS DATA.
def volumes(quiet=True, hours=24, fast=False, with_history=True):
    """WHAT IS ON THE DISK, AND WHAT IT HAS BEEN DOING — /api/volumes.

    THREE ANSWERS IN ONE PAYLOAD because they are one question asked three
    ways, and a tab that fetched them separately would draw a graph of one
    moment against a table of another:
      · `disk` + `usage` — the totals. What docker is holding, split four ways,
        against the size of the filesystem holding it.
      · `volumes` — every volume, biggest first, with the size docker will
        admit to and how it was measured.
      · `history` — the same numbers every five minutes, back as far as the
        series goes. THE ONLY PART THAT ANSWERS "IS IT GROWING", which is the
        question a size cannot be read for.
    EVERY READ IS ALSO A SAMPLE, rate-limited: opening the tab on a bench whose
    sampler has not run yet writes the first point rather than showing an empty
    graph and an explanation.
    """
    reading = read_volumes(quiet=quiet, fast=fast)
    if reading.get("ok"):
        # A FIFTH of the sampler beat: enough that a person pressing refresh
        # sees their own point land, far too little to bend the series.
        record_volume_sample(reading, quiet=quiet, min_gap=VOLUME_SAMPLE_SECONDS / 5)
    reading["history"] = (read_volume_history(hours=hours, quiet=quiet)
                          if with_history else {"points": [], "path": "", "total": 0})
    reading["sample_seconds"] = VOLUME_SAMPLE_SECONDS
    # The pointer the tab draws even when docker is down: it is a folder and a
    # volume NAME, and the folder half is true whether or not a daemon answers.
    reading["storage"].setdefault("writing_to", storage_directory(quiet=quiet))
    return reading


def cost(quiet=True):
    """💲 WHAT THE BENCH HAS COST IN CPU — /api/cost. The ledger, summarised."""
    from .readers import read_cost_ledger, cost_summary
    return cost_summary(read_cost_ledger(quiet=quiet))


def set_cost(body, quiet=True):
    """POST /api/cost — {price_per_cpu_minute, currency} and/or {reset: true}."""
    from .readers import set_cost_price, cost_summary
    price = body.get("price_per_cpu_minute")
    try:
        price = None if price in (None, "") else float(price)
    except (TypeError, ValueError):
        return {"ok": False, "error": "price_per_cpu_minute must be a number."}
    ledger = set_cost_price(price=price, currency=body.get("currency"),
                            reset=bool(body.get("reset")), quiet=quiet)
    return {"ok": True, **cost_summary(ledger)}


# ---------------------------------------------------------------------------
# Here and not in serve.py because this module owns the route table and serve.py
# is the transport. The dispatcher reads these paths and check_manager_routes.py
# fails the build when the two disagree — a route table nothing checks gets
# believed after it stops being true.
# SERVED at GET /api/routes, because the manager draws a handles pane per
# container and the manager is a container: every other row there is a service
# describing itself, so api.sh needs no special case for this box.
# ---------------------------------------------------------------------------
ROUTES = (
    {"method": "GET", "path": "/api/health",
     "what": "the manager's own account of itself — answers before docker is asked"},
    {"method": "GET", "path": "/api/routes", "what": "this table"},
    {"method": "GET", "path": "/api/palette", "what": "the status colours and role emoji"},
    {"method": "GET", "path": "/api/actions",
     "what": "every verb the client may offer, with its label and its confirm text"},
    {"method": "GET", "path": "/api/containers",
     "what": "every container with its meters and app plane (&apps=0 for the fast scan)"},
    {"method": "GET", "path": "/api/resources",
     "what": "one docker stats sample, and the host core count and total RAM "
             "its percentages and byte totals are a share of"},
    {"method": "GET", "path": "/api/stacks",
     "what": "every stack the compose files DECLARE, whether its containers are "
             "here, which of them exited and were not restarted, whether any verb "
             "on this page can bring it back, and how full the disk under them is"},
    {"method": "GET", "path": "/api/staleness",
     "what": "whether each stack's image was built after the files its "
             "Dockerfile COPYs were last written -- a container can be ok and stale at once"},
    {"method": "GET", "path": "/api/endpoints", "what": "every address the ecosystem answers on"},
    {"method": "GET", "path": "/api/volumes",
     "what": "every volume with its size, the four docker totals, the disk "
             "under them and the sampled history of all of it (&hours=, &fast=1)"},
    {"method": "GET", "path": "/api/cost",
     "what": "the CPU cost meter: CPU-minutes and container up-minutes since it "
             "started, charged at the price per CPU-minute in force when burned"},
    {"method": "GET", "path": "/api/log", "what": "the execution log's tail (&n=)"},
    {"method": "GET", "path": "/api/stream", "what": "the execution log as Server-Sent Events"},
    {"method": "GET", "path": "/api/container/<name>",
     "what": "one container in full — diagnosis, ports, networks, app plane, inspect"},
    {"method": "GET", "path": "/api/surface/<name>",
     "what": "one container's HTTP routes and the bus topics it is publishing"},
    {"method": "GET", "path": "/api/config-script/<name>",
     "what": "the compose file or Dockerfile that built it, and its text"},
    {"method": "POST", "path": "/api/broadcast", "what": "publish the inventory to every broker"},
    {"method": "POST", "path": "/api/chat", "what": "one line onto the bus"},
    {"method": "POST", "path": "/api/cost",
     "what": "set the price per CPU-minute from now on ({price_per_cpu_minute}), "
             "or zero the meter ({reset: true})"},
    {"method": "POST", "path": "/api/log/clear", "what": "clear the execution log"},
    {"method": "POST", "path": "/api/action/<key>",
     "what": "run one verb from ACTIONS, from CONTAINER_ACTIONS when a "
             "container is named, or from STACK_ACTIONS when a stack is. "
             "ONE AT A TIME, refused rather than queued"},
)


def routes():
    """What this manager answers on, in the shape api.sh reads."""
    return {"component": "APK.audio DockTor API",
            "routes": [dict(row) for row in ROUTES]}


def surface(name, quiet=True):
    """One container HANDLES: the routes it answers, the topics it publishes.

    Two measurements fetched together because the pane asks one question — how
    do I talk to this thing — of which HTTP and the bus are the halves.
    NOT part of container_detail(): the census costs a settle window and the
    detail pane is fetched on every card click, so the client paints the detail
    and fills this in beneath it.
    """
    api_document = read_container_api(name, quiet=quiet).get(name)
    bus_document = read_bus_topics(name, quiet=quiet).get(name)
    return {
        "container": name,
        # None rather than {} on either half: "answers no HTTP" and "the
        # reader would not run" are different facts.
        "api": api_document,
        "bus": bus_document,
    }


def broadcast(say=None):
    """Publish the inventory to every broker, as the button used to."""
    result = publish_status_report("manual", say=say)
    if result is None:
        return {"ok": False, "error": "Broker discovery unavailable — nothing broadcast."}
    return {"ok": True, **result}


# ---------------------------------------------------------------------------
# CHAT. One line onto the bus from whoever is at the manager. Four lines and one
# topic; the Tkinter Toplevel it replaces was 60 lines of window around them,
# with a scrollback nothing persisted or read. The bus is the record.
# THE WORDS THAT MEAN PANIC ARE REPORTED, NOT ACTED ON: the flag comes back and
# the client offers the panic confirm, but a text field that can take the
# ecosystem down without a dialog is one somebody empties by accident.
# ---------------------------------------------------------------------------
CHAT_TOPIC = "APK.audio/System/Chat"
PANIC_WORDS = ("panic", "sos", "stop")


def chat(message):
    """Publish one chat line to the bus. Says whether it sounded like a panic."""
    text = (message or "").strip()
    if not text:
        return {"ok": False, "error": "Nothing to say."}
    payload = {"sender": "USER_CHAT", "message": text,
               "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    published = False
    try:
        import paho.mqtt.publish as publish
        publish.single(CHAT_TOPIC, json.dumps(payload), hostname="127.0.0.1",
                       port=1883, keepalive=2)
        published = True
    except Exception as err:
        emit("CHAT_PUBLISH_FAILED", {"topic": CHAT_TOPIC, "error": str(err)})
    emit("CHAT", payload)
    return {"ok": True, "topic": CHAT_TOPIC, "published": published,
            "sounds_like_panic": text.lower() in PANIC_WORDS}


def run_action(key, name=None, extra=(), on_line=None, scope="container",
               ordered_by=None):
    """Run one verb from the tables above. (exit_code, closing sentence).

    REFUSED, NOT QUEUED, when another action holds the bench — unless this verb
    carries `preempts`, in which case it CANCELS the holder and takes the bench.
    `name` is the argument and `scope` says which table it names. One parameter,
    not two, because the two are alternatives and never both.
    `ordered_by` names the hand on the button — a press, a countdown, a CLI
    verb — and is carried to every script the verb runs, so a container
    stopped three scripts down can say whose command it was.
    """
    if name is None:
        row = ACTIONS.get(key)
        args = list(row["args"]) if row else []
        # A ROW THAT ASKS FOR A VALUE TAKES EXACTLY ONE, AND IT IS CHECKED HERE.
        # `prompt.pattern` is in the payload so the client can mark a bad box
        # red; that is a courtesy, and this is the enforcement. A row without a
        # prompt ignores `extra` entirely — no verb in this table may be given
        # arguments it did not ask for.
        if row is not None and row.get("prompt") and extra:
            value = str(extra[0])
            if not re.fullmatch(row["prompt"].get("pattern", r"[^\n]{0,200}"), value):
                emit("ACTION_ARGUMENT_REFUSED", {"action": key, "value": value[:60]})
                return 2, (f"❌ {row['label']}: '{value[:60]}' is not a value this "
                           f"verb accepts, so nothing was run.")
            args = args + [value]
    else:
        row = (STACK_ACTIONS if scope == "stack" else CONTAINER_ACTIONS).get(key)
        args = [name, *extra] if row else []
    if row is None:
        return 127, f"❌ Unknown action: {key}"

    cancelled = []
    if not ACTION_LOCK.acquire(blocking=False):
        if not row.get("preempts"):
            return 111, ("⏳ Another action is already running. This one was refused "
                         "rather than queued — a rebuild that starts twenty minutes "
                         "after it was asked for is worse than one that did not start.")
        # THE CANCEL IS ISSUED WITHOUT THE LOCK, and has to be: the lock is
        # what the thing being cancelled is holding. Safe because
        # cancel_running_scripts() only signals — the holder notices its pipe
        # close, finishes, and releases below.
        cancelled = cancel_running_scripts(reason=key)
        emit("ACTION_PREEMPTED", {"action": key, "cancelled": cancelled})
        if on_line and cancelled:
            on_line("🛑 cancelling %s to make way for %s…\n"
                    % (", ".join(cancelled), row["label"]))
        if not ACTION_LOCK.acquire(timeout=PREEMPT_WAIT_SECONDS):
            emit("ACTION_PREEMPT_FAILED", {"action": key,
                                           "holding": running_scripts()})
            return 111, ("⏳ %s cancelled the running action, but the bench was "
                         "still held %.0fs later and nothing was run. Whatever is "
                         "holding it did not die on a signal — read the output "
                         "above." % (row["label"], PREEMPT_WAIT_SECONDS))

    # READ AFTER THE ACQUIRE: a preempting verb bumps the epoch on its way in,
    # and reading earlier would have every stop report itself as stopped.
    who = ordered_by or "an unnamed caller of the DockTor API"
    order = f"{row['label']}" + (f" — {name}" if name else "") + f", ordered by {who}"
    chat(f"🤖 DockTor Action: {order}")
    epoch_before = cancel_epoch()
    try:
        exit_code, _ = run_reported(row["script"], args, on_line_callback=on_line,
                                    ordered_by=order)
    finally:
        ACTION_LOCK.release()

    # A CANCELLED RUN IS NOT A FAILED ONE — "❌ Rebuild FAILED, exited -15"
    # reads as a broken build to whoever deliberately broke it.
    if exit_code != 0 and cancel_epoch() != epoch_before:
        msg = ("🛑 %s was CANCELLED by a stop pressed while it ran. "
               "Nothing was rolled back — read the output above for "
               "how far it got." % row["label"])
        chat(f"📢 DockTor Result: {msg}")
        return exit_code, msg

    template = row["done"] if exit_code == 0 else row["failed"]
    closing = template.format(code=exit_code, name=name or "")
    if cancelled:
        closing = "🛑 Cancelled first: %s\n%s" % (", ".join(cancelled), closing)
    chat(f"📢 DockTor Result: {closing}")
    return exit_code, closing


def health():
    """The manager's own account of itself. Answers before docker is asked."""
    return {
        "ok": True,
        "component": "APK.audio DockTor API",
        "repository_root": REPOSITORY_ROOT,
        "scripts": DOCKER_SCRIPTS_DIRECTORY,
        # WHO, not just what. Every caller that has to tell one manager from
        # another reads this and nothing else.
        "instance": INSTANCE,
        "actions": sorted(ACTIONS),
        "container_actions": sorted(CONTAINER_ACTIONS),
        "stack_actions": sorted(STACK_ACTIONS),
    }
