# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""What an idle DockTor may skip, and what it must still notice (PLAN-3319.01).

    cd PODS/Docktor/SRC && python3 -m unittest manager.test_readers_idle -v
"""

import unittest

from . import readers

LABEL = "apk.audio.managed_by=BareMetal-Manager"


class WatchdogFingerprint(unittest.TestCase):
    def test_launcher_churn_does_not_move_it(self):
        before = ("Broker-Mosquitto\trunning\t\n"
                  "DockTor\trunning\t\n"
                  "apk-dmm-34401a-devttyusb0\trunning\tBareMetal-Manager\n")
        after = ("DockTor\trunning\t\n"
                 "apk-appletv-44.44.44.156\trunning\tBareMetal-Manager\n"
                 "Broker-Mosquitto\trunning\t\n")
        self.assertEqual(readers._fingerprint_of(before, LABEL),
                         readers._fingerprint_of(after, LABEL))

    def test_a_stack_container_changing_state_moves_it(self):
        up = "Plugin-PING\trunning\t\napk-x\trunning\tBareMetal-Manager\n"
        down = "Plugin-PING\texited\t\napk-x\trunning\tBareMetal-Manager\n"
        self.assertNotEqual(readers._fingerprint_of(up, LABEL),
                            readers._fingerprint_of(down, LABEL))

    def test_a_stack_container_leaving_moves_it(self):
        self.assertNotEqual(readers._fingerprint_of("A\trunning\t\nB\trunning\t\n", LABEL),
                            readers._fingerprint_of("A\trunning\t\n", LABEL))

    def test_another_managers_label_value_is_still_counted(self):
        # Only the launcher named by the label is excused; a container some
        # other tool stamped with the same key is not ours to ignore.
        listing = "X\trunning\tSomebody-Else\n"
        self.assertEqual(readers._fingerprint_of(listing, LABEL), "X\trunning")

    def test_an_old_two_column_listing_still_parses(self):
        self.assertEqual(readers._fingerprint_of("B\texited\nA\trunning\n", LABEL),
                         "A\trunning\nB\texited")


class StorageDirectoryCache(unittest.TestCase):
    def test_a_found_folder_is_kept_past_a_minute(self):
        self.assertTrue(readers._storage_answer_fresh("/storage", 61))
        self.assertTrue(readers._storage_answer_fresh(
            "/storage", readers.STORAGE_DIR_FOUND_SECONDS - 1))

    def test_a_found_folder_is_asked_again_eventually(self):
        self.assertFalse(readers._storage_answer_fresh(
            "/storage", readers.STORAGE_DIR_FOUND_SECONDS))

    def test_a_refusal_is_retried_within_a_minute(self):
        self.assertTrue(readers._storage_answer_fresh("", 10))
        self.assertFalse(readers._storage_answer_fresh("", readers.STORAGE_DIR_SECONDS))

    def test_never_asked_is_never_fresh(self):
        self.assertFalse(readers._storage_answer_fresh(None, 0))


class CostSampler(unittest.TestCase):
    def test_the_beat_stays_inside_the_five_minute_trust_window(self):
        # Unreachable is dead / nothing unverified for 5 min is trusted: the
        # counted-gap rule is two beats, and two beats must stay under that.
        self.assertLessEqual(2 * readers.COST_SAMPLE_SECONDS, 300)


if __name__ == "__main__":
    unittest.main()
