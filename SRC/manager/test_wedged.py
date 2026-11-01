# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""One container Docker cannot stop must not take its stack down (ROAD-3480).

K8/wedged.py's decision against fakes (no real docker), then mount_compose_up
from _common.sh end to end against a fake `docker` and a fake compose.

    cd PODS/POD.manager/MANAGER.Docktor/SRC && python3 -m unittest manager.test_wedged -v
"""

import importlib.util
import io
import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

K8 = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "K8"))
_spec = importlib.util.spec_from_file_location("wedged", os.path.join(K8, "wedged.py"))
wedged = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wedged)

MIDI_ID = "186a371de82de200b05c78bc7d0d87d2c70e9c41f71931d99a22bdd994ed3086"
NEW_ID = "4d71aca242b46577e3d1fe22aebb71d15406d97cd4c56f86ac0379d9bd0ad4c6"

# What compose printed on 2026-11-01, near enough.
COMPOSE_LOG = textwrap.dedent(f"""\
     Container Plugin-MIDI-wedged-usb  Recreate
     Container Plugin-MIDI-wedged-usb  Error while Stopping
    Error response from daemon: cannot stop container: {MIDI_ID}: tried to kill container, but did not receive an exit event
    """)
CONFLICT_LOG = ('Error response from daemon: Conflict. The container name "/Plugin-MIDI" '
                f'is already in use by container "{MIDI_ID}". You have to remove (or rename) '
                'that container to be able to reuse that name.\n')


def row(cid, name, service, state, project="apk-audio"):
    return {"ID": cid[:12], "Name": name, "Service": service, "State": state,
            "Project": project}


class FakeDocker:
    """inspect / tasks / by_labels from a table; tasks may change per look."""

    def __init__(self, containers, tasks=None):
        self.containers = containers          # ref -> info dict
        self.task_looks = tasks or {}         # id -> [look1, look2, ...]
        self.in_container = True

    def inspect(self, ref):
        for info in self.containers.values():
            if ref in (info["name"], info["id"]) or info["id"].startswith(ref):
                return dict(info)
        return None

    def tasks(self, info):
        looks = self.task_looks.get(info["id"], [])
        if not looks:
            return [], ""
        return (looks.pop(0) if len(looks) > 1 else looks[0]), "docker top"

    def by_labels(self, project, service):
        return [i["id"] for i in self.containers.values()
                if i.get("project") == project and i.get("service") == service]


def info(cid, name, status="running", pid=4242, started="t0", **extra):
    return {"id": cid, "name": name, "status": status, "pid": pid, "started": started, **extra}


D = [{"pid": 1, "tid": 7, "state": "D", "wchan": "usb_kill_urb", "comm": "tokio-rt-worker"}]
S = [{"pid": 1, "tid": 7, "state": "S", "wchan": "do_wait", "comm": "apk-midi"}]
NOSLEEP = lambda _s: None  # noqa: E731


class ComposeOutput(unittest.TestCase):
    def test_kill_failure_names_and_ids(self):
        f = wedged.failures_from_output(COMPOSE_LOG)
        self.assertIn(MIDI_ID, f["kill"])
        self.assertIn("Plugin-MIDI-wedged-usb", f["kill"])

    def test_name_conflict_names_the_holder(self):
        f = wedged.failures_from_output(CONFLICT_LOG)
        self.assertEqual(f["conflict"], {MIDI_ID})
        self.assertEqual(f["kill"], set())

    def test_a_clean_log_blames_nothing(self):
        f = wedged.failures_from_output(" Container Plugin-PTP  Started\n")
        self.assertEqual(f, {"kill": set(), "conflict": set()})

    def test_ps_json_both_shapes(self):
        one = {"ID": "abc", "Name": "n", "Service": "s", "State": "Running", "Project": "p"}
        self.assertEqual(wedged.parse_ps_json(json.dumps([one])),
                         wedged.parse_ps_json(json.dumps(one) + "\n"))
        self.assertEqual(wedged.parse_ps_json(json.dumps(one))[0]["State"], "running")


class ProcessTree(unittest.TestCase):
    def test_stat_with_spaces_in_comm(self):
        self.assertEqual(wedged.parse_stat("12 (tokio rt (x)) D 7 1 1"),
                         (12, "tokio rt (x)", "D", 7))

    def test_proc_walk_finds_a_d_thread_of_a_zombie_child(self):
        # docker-init (S) -> apk-midi leader (Z) whose worker thread is in D:
        # exactly the shape Plugin-MIDI-wedged-usb had.
        proc = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, proc)

        def task(pid, tid, comm, state, ppid, wchan, children=""):
            d = os.path.join(proc, str(pid), "task", str(tid))
            os.makedirs(d)
            for leaf, text in (("stat", f"{tid} ({comm}) {state} {ppid} 0 0\n"),
                               ("wchan", wchan), ("children", children)):
                with open(os.path.join(d, leaf), "w") as fh:
                    fh.write(text)

        task(100, 100, "docker-init", "S", 1, "do_wait", "101 ")
        task(101, 101, "apk-midi", "Z", 100, "0")
        task(101, 102, "tokio-rt-worker", "D", 100, "usb_kill_urb")
        tasks = wedged.proc_tasks(100, proc)
        self.assertEqual(len(tasks), 3)
        self.assertEqual([t["wchan"] for t in wedged.stuck(tasks)], ["usb_kill_urb"])

    def test_docker_top_rows(self):
        top = ("PID LWP STAT WCHAN COMMAND\n"
               "1527987 1527987 Zl - apk-midi\n"
               "1527987 1527996 Dl snd_seq_open.part.0 tokio-rt-worker\n")
        tasks = wedged.parse_top(top)
        self.assertEqual([t["wchan"] for t in wedged.stuck(tasks)], ["snd_seq_open.part.0"])
        self.assertEqual(tasks[0]["wchan"], "")


class Assess(unittest.TestCase):
    def rows(self):
        return [row(MIDI_ID, "Plugin-MIDI-wedged-usb", "midi", "running"),
                row("c" * 64, "50f2aa51d73e_Plugin-MIDI", "midi", "created"),
                row("a" * 64, "Plugin-PTP", "ptp", "created"),
                row("b" * 64, "Plugin-SNMP", "snmp", "running")]

    def docker(self, midi_tasks=None):
        return FakeDocker({
            "midi": info(MIDI_ID, "Plugin-MIDI-wedged-usb", project="apk-audio", service="midi"),
            "tmp": info("c" * 64, "50f2aa51d73e_Plugin-MIDI", status="created", pid=0),
            "ptp": info("a" * 64, "Plugin-PTP", status="created", pid=0),
            "snmp": info("b" * 64, "Plugin-SNMP")},
            {MIDI_ID: midi_tasks} if midi_tasks else {})

    def test_kill_failure_with_d_state_is_wedged_with_its_channel(self):
        found = wedged.assess(self.rows(), wedged.failures_from_output(COMPOSE_LOG),
                              self.docker([D, D]), {}, sleep=NOSLEEP)
        self.assertEqual([w["container"] for w in found], ["Plugin-MIDI-wedged-usb"])
        self.assertEqual(found[0]["reasons"], ["d_state", "kill_failed"])
        self.assertEqual(found[0]["wchan"], "usb_kill_urb")
        self.assertEqual(wedged.excluded_services(found), ["midi"])

    def test_kill_failure_alone_counts_when_the_channel_is_unreadable(self):
        # Inside DockTor: no host /proc, docker top answers nothing.
        found = wedged.assess(self.rows(), wedged.failures_from_output(COMPOSE_LOG),
                              self.docker(), {}, sleep=NOSLEEP)
        self.assertEqual(found[0]["reasons"], ["kill_failed"])
        self.assertIn("not readable", wedged.event_payload(found[0])["wchan"])
        self.assertIn("reboot", wedged.event_payload(found[0])["remedy"])

    def test_a_single_d_look_is_a_disk_wait_not_a_wedge(self):
        # Two midi containers -> both looked at; D on the first look only.
        found = wedged.assess(self.rows(), {"kill": set(), "conflict": set()},
                              self.docker([D, S]), {}, sleep=NOSLEEP)
        self.assertEqual(found, [])

    def test_persistent_d_without_any_failure_is_found(self):
        found = wedged.assess(self.rows(), {"kill": set(), "conflict": set()},
                              self.docker([D, D]), {}, sleep=NOSLEEP)
        self.assertEqual(found[0]["reasons"], ["d_state"])

    def test_a_container_that_did_stop_is_not_wedged(self):
        d = self.docker()
        d.containers["midi"]["status"] = "exited"
        found = wedged.assess(self.rows(), wedged.failures_from_output(COMPOSE_LOG), d, {},
                              sleep=NOSLEEP)
        self.assertEqual(found, [])

    def test_name_conflict_holder_is_left_out(self):
        found = wedged.assess(self.rows(), wedged.failures_from_output(CONFLICT_LOG),
                              self.docker(), {}, sleep=NOSLEEP)
        self.assertEqual(found[0]["reasons"], ["name_conflict"])

    def test_record_holds_for_the_same_start_only(self):
        record = wedged.remember({}, [{"full_id": MIDI_ID, "container": "Plugin-MIDI-wedged-usb",
                                       "service": "midi", "project": "apk-audio", "pid": 4242,
                                       "started": "t0", "wchan": "usb_kill_urb",
                                       "reasons": ["kill_failed"]}], now=1)
        rows = [row(MIDI_ID, "Plugin-MIDI", "midi", "running")]
        found = wedged.assess(rows, None, self.docker(), record, sleep=NOSLEEP)
        self.assertEqual(found[0]["reasons"], ["recorded"])
        self.assertEqual(found[0]["wchan"], "usb_kill_urb")
        # After a reboot the same id comes back with a new pid: not wedged.
        d = self.docker()
        d.containers["midi"]["pid"] = 9999
        self.assertEqual(wedged.assess(rows, None, d, record, sleep=NOSLEEP), [])

    def test_retry_plan_and_exit_codes(self):
        found = [{"service": "midi"}]
        self.assertEqual(wedged.retry_plan(["ptp", "midi", "snmp"], found), ["ptp", "snmp"])
        self.assertEqual(wedged.mount_exit(0, 0, 0, 0), 0)
        self.assertEqual(wedged.mount_exit(17, 0, 0, 0), 17)         # nothing wedged: compose's own
        self.assertEqual(wedged.mount_exit(1, 1, 0, 0), wedged.PARTIAL_EXIT)
        self.assertEqual(wedged.mount_exit(1, 1, 5, 0), 5)           # the retry failed
        self.assertEqual(wedged.mount_exit(1, 1, 0, 2), 1)           # some would not start

    def test_cli_assess_prints_events_and_excludes_and_records(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        ps = os.path.join(tmp, "ps.json")
        log = os.path.join(tmp, "compose.log")
        rec = os.path.join(tmp, "wedged.json")
        with open(ps, "w") as fh:
            fh.write("\n".join(json.dumps(r) for r in self.rows()))
        with open(log, "w") as fh:
            fh.write(COMPOSE_LOG)
        out = io.StringIO()
        code = wedged.cli_assess(["--ps-json", ps, "--compose-log", log, "--record", rec],
                                 docker=self.docker([D, D]), out=out)
        self.assertEqual(code, 0)
        lines = out.getvalue().splitlines()
        event = [l for l in lines if l.startswith("@EVENT WEDGED_CONTAINER ")]
        self.assertEqual(len(event), 1)
        self.assertEqual(json.loads(event[0].split(" ", 2)[2])["wchan"], "usb_kill_urb")
        self.assertIn("EXCLUDE midi", lines)
        with open(rec) as fh:
            self.assertIn(MIDI_ID, json.load(fh))

    def test_cli_check_by_service(self):
        d = self.docker([D, D])
        self.assertEqual(wedged.cli_check(["--project", "apk-audio", "--service", "midi",
                                           "50f2aa51d73e_Plugin-MIDI"], docker=d,
                                          out=io.StringIO()), 0)
        self.assertEqual(wedged.cli_check(["Plugin-SNMP"], docker=self.docker(),
                                          out=io.StringIO()), 1)


FAKE_DOCKER = r"""#!/usr/bin/env bash
# A daemon with one wedged container (Plugin-MIDI, pid 0 so /proc is never read).
# ps json lists ONE midi container, so the pre-check (duplicates + record) finds
# nothing on a first mount and the failure path is what runs.
echo "docker $*" >> "$FAKE_DIR/calls"
case "$1" in
  compose) [ "$2" = version ] && { echo "Docker Compose version v2.40.0"; exit 0; }; exit 0;;
  inspect)
    ref="${@: -1}"
    case "$ref" in
      Plugin-MIDI|aaaaaaaaaaaa*) echo "aaaaaaaaaaaa1111111111111111111111111111111111111111111111111111|/Plugin-MIDI|running|0|t0";;
      *) exit 1;;
    esac;;
  top)
    case "$2" in aaaaaaaaaaaa*|Plugin-MIDI)
      printf 'PID LWP STAT WCHAN COMMAND\n9 9 Zl - apk-midi\n9 10 Dl usb_kill_urb tokio-rt-worker\n';;
    esac;;
  start) touch "$FAKE_DIR/started.$2";;
  ps) ;;
  *) ;;
esac
exit 0
"""

FAKE_COMPOSE = r"""#!/usr/bin/env bash
echo "compose $*" >> "$FAKE_DIR/calls"
args=" $* "
case "$args" in
  *" config --services "*) printf 'ptp\nsnmp\nmidi\n';;
  *" ps -a --status created "*)
    for n in Plugin-PTP:ptp Plugin-SNMP:snmp 50f2aa51d73e_Plugin-MIDI:midi; do
      [ -e "$FAKE_DIR/started.${n%%:*}" ] || printf '%s\t%s\n' "${n%%:*}" "${n##*:}"
    done;;
  *" ps -a --format json "*)
    echo '{"ID":"aaaaaaaaaaaa","Name":"Plugin-MIDI","Service":"midi","State":"running","Project":"apk-audio"}'
    echo '{"ID":"dddddddddddd","Name":"Plugin-PTP","Service":"ptp","State":"created","Project":"apk-audio"}'
    echo '{"ID":"eeeeeeeeeeee","Name":"Plugin-SNMP","Service":"snmp","State":"created","Project":"apk-audio"}';;
  *" up -d --build --no-deps "*) exit 0;;
  *" up -d --build "*)
    echo " Container Plugin-MIDI  Error while Stopping"
    echo "Error response from daemon: cannot stop container: aaaaaaaaaaaa1111111111111111111111111111111111111111111111111111: tried to kill container, but did not receive an exit event"
    exit 1;;
  *" up -d --no-build --no-deps "*) exit 0;;
esac
exit 0
"""


@unittest.skipUnless(shutil.which("bash"), "needs bash")
class MountComposeUp(unittest.TestCase):
    """mount_compose_up from _common.sh, against the fakes above."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        bindir = os.path.join(self.dir, "bin")
        os.makedirs(bindir)
        for name, body in (("docker", FAKE_DOCKER), ("fakecompose", FAKE_COMPOSE)):
            path = os.path.join(bindir, name)
            with open(path, "w") as fh:
                fh.write(body)
            os.chmod(path, 0o755)
        self.env = {**os.environ, "PATH": bindir + os.pathsep + os.environ["PATH"],
                    "FAKE_DIR": self.dir,
                    "APKAUDIO_WEDGED_RECORD": os.path.join(self.dir, "wedged.json")}
        self.env.pop("APK_COMMON_CONFIG_EVAL", None)

    def mount(self):
        common = os.path.join(K8, "_common.sh")
        script = (f'source "{common}" >/dev/null 2>&1; STACK_COMPOSE=(fakecompose); '
                  'mount_compose_up DISCOVERY.Engine; echo "EXIT=$?"')
        return subprocess.run(["bash", "-c", script], env=self.env, capture_output=True,
                              text=True, timeout=60)

    def calls(self):
        with open(os.path.join(self.dir, "calls")) as fh:
            return fh.read().splitlines()

    def test_the_rest_comes_up_without_the_wedged_service(self):
        done = self.mount()
        out = done.stdout + done.stderr
        self.assertIn(f"EXIT={wedged.PARTIAL_EXIT}", out, out)
        self.assertIn("@EVENT WEDGED_CONTAINER", out)
        self.assertIn("usb_kill_urb", out)
        self.assertIn("@EVENT MOUNT_PARTIAL", out)
        calls = self.calls()
        self.assertIn("compose up -d --no-build --no-deps ptp snmp", calls)
        self.assertTrue(os.path.exists(os.path.join(self.dir, "started.Plugin-PTP")))
        self.assertTrue(os.path.exists(os.path.join(self.dir, "started.Plugin-SNMP")))
        self.assertFalse(os.path.exists(os.path.join(self.dir, "started.50f2aa51d73e_Plugin-MIDI")))

    def test_the_next_mount_leaves_it_out_from_the_start(self):
        self.mount()
        os.remove(os.path.join(self.dir, "calls"))
        done = self.mount()
        out = done.stdout + done.stderr
        self.assertIn(f"EXIT={wedged.PARTIAL_EXIT}", out, out)
        self.assertIn("@EVENT MOUNT_SKIPPING_WEDGED", out)
        calls = self.calls()
        self.assertIn("compose up -d --build --no-deps ptp snmp", calls)
        self.assertNotIn("compose up -d --build", calls)


if __name__ == "__main__":
    unittest.main()
