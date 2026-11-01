# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""The watchdog backs off a remount that keeps failing the same way (ROAD-3480).

    cd PODS/POD.manager/MANAGER.Docktor/SRC && python3 -m unittest manager.test_remount_backoff -v
"""

import unittest

from . import readers

WEDGED = ("✗ Plugin-MIDI (midi) cannot be stopped: kill_failed; wait channel usb_kill_urb.\n"
          "Error response from daemon: cannot stop container: 186a371de82d: tried to kill "
          "container, but did not receive an exit event\n"
          "✗ Mount of DISCOVERY.Engine FAILED — compose exited 1. Read the output above.\n")


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class RemountBackoff(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.b = readers.RemountBackoff(base=30, cap=600, forget=3600, clock=self.clock)

    def test_a_stack_never_failed_is_due(self):
        self.assertEqual(self.b.due("X"), (True, None))

    def test_same_failure_doubles_up_to_the_cap(self):
        delays = []
        for _ in range(8):
            entry = self.b.record("X", 1, WEDGED)
            delays.append(entry["delay"])
            self.clock.now += entry["delay"]
        self.assertEqual(delays, [30, 60, 120, 240, 480, 600, 600, 600])

    def test_not_due_until_the_wait_is_over(self):
        self.b.record("X", 1, WEDGED)
        self.b.record("X", 1, WEDGED)          # 60 s
        self.clock.now += 59
        ok, left = self.b.due("X")
        self.assertFalse(ok)
        self.assertAlmostEqual(left, 1)
        self.clock.now += 1
        self.assertEqual(self.b.due("X"), (True, None))

    def test_ids_and_timings_do_not_make_a_failure_new(self):
        self.b.record("X", 1, WEDGED)
        other = WEDGED.replace("186a371de82d", "4d71aca242b4").replace("exited 1", "exited 1")
        entry = self.b.record("X", 1, other + "took 12.5s\n")
        self.assertTrue(entry["same"])
        self.assertEqual(entry["failures"], 2)

    def test_a_different_failure_starts_over(self):
        self.b.record("X", 1, WEDGED)
        self.b.record("X", 1, WEDGED)
        entry = self.b.record("X", 1, "✗ Mount cancelled: upstream pre-build test gates failed.\n")
        self.assertFalse(entry["same"])
        self.assertEqual(entry["delay"], 30)
        entry = self.b.record("X", 17, "✗ Mount cancelled: upstream pre-build test gates failed.\n")
        self.assertFalse(entry["same"])        # another exit code is another failure

    def test_success_clears_it(self):
        self.b.record("X", 1, WEDGED)
        self.b.record("X", 1, WEDGED)
        self.assertIsNone(self.b.record("X", 0, ""))
        self.assertEqual(self.b.due("X"), (True, None))
        self.assertEqual(self.b.record("X", 1, WEDGED)["delay"], 30)

    def test_an_old_failure_is_forgotten(self):
        self.b.record("X", 1, WEDGED)
        self.clock.now += 3601
        self.assertFalse(self.b.record("X", 1, WEDGED)["same"])

    def test_stacks_are_independent(self):
        self.b.record("X", 1, WEDGED)
        self.b.record("X", 1, WEDGED)
        self.assertEqual(self.b.due("Y"), (True, None))

    def test_the_reason_names_the_wedge(self):
        out = WEDGED + '@EVENT WEDGED_CONTAINER {"container": "Plugin-MIDI"}\n'
        self.assertIn("cannot stop", readers._backoff_reason(1, out))
        self.assertIn("partially", readers._backoff_reason(readers.MOUNT_PARTIAL_EXIT, ""))
        self.assertIn("FAILED", readers._backoff_reason(1, WEDGED))


if __name__ == "__main__":
    unittest.main()
