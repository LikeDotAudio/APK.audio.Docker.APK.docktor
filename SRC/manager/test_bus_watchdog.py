# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
"""bus_watchdog: the packet codecs, the browser-shaped upgrade, and the bark edges."""
import unittest

from manager import bus_watchdog as bw


class Codecs(unittest.TestCase):
    def test_mqtt_packets_split_and_keep_the_tail(self):
        a = bw.mqtt_publish("t", b"hello")
        pk, rest = bw.mqtt_packets(bytearray(a + bytes([0x20, 2, 0, 0])))
        self.assertEqual([p[0] for p in pk], [3, 2])
        self.assertTrue(pk[0][1].endswith(b"hello"))
        pk, rest = bw.mqtt_packets(bytearray(a[:3]))
        self.assertEqual(pk, [])
        self.assertEqual(bytes(rest), a[:3])

    def test_long_remaining_length(self):
        big = bw.mqtt_publish("t", b"x" * 300)
        pk, rest = bw.mqtt_packets(bytearray(big))
        self.assertEqual(len(pk), 1)
        self.assertEqual(len(rest), 0)

    def test_server_frames_unmasked_and_partial(self):
        f = bytes([0x82, 3]) + b"abc" + bytes([0x82, 126]) + (200).to_bytes(2, "big") + b"y" * 200
        frames, rest = bw.ws_frames(bytearray(f + bytes([0x82])))
        self.assertEqual([len(p) for _, p in frames], [3, 200])
        self.assertEqual(bytes(rest), bytes([0x82]))

    def test_client_frames_are_masked(self):
        fr = bw.ws_frame(b"abc")
        self.assertTrue(fr[1] & 0x80)

    def test_upgrade_is_browser_shaped(self):
        req = bw.upgrade_request("ws://127.0.0.1:8080/mqtt", 6144).decode()
        self.assertIn("GET /mqtt HTTP/1.1", req)
        self.assertIn("Sec-WebSocket-Protocol: mqtt", req)
        self.assertIn("Origin: http://127.0.0.1:8080", req)
        cookie = [l for l in req.split("\r\n") if l.startswith("Cookie: ")][0]
        self.assertGreater(len(cookie), 4096, "past the broker's limit, as Chrome's was")
        self.assertLess(len(cookie), 8192, "under nginx's header line limit")


class Bark(unittest.TestCase):
    def setUp(self):
        self.events, self.t = [], [1000.0]
        self.state = dict(bw.STATE)

    def run_beat(self, fail=None):
        def probe(url):
            if fail:
                raise bw.Fail(*fail)
            return 0.01
        return bw.beat(self.state, probe, lambda e, d: self.events.append((e, d)), lambda: self.t[0], "ws://x/mqtt")

    def test_up_is_silent(self):
        self.assertTrue(self.run_beat())
        self.assertEqual(self.events, [])

    def test_down_once_then_repeat_then_ok(self):
        self.run_beat(("upgrade", "HTTP/1.1 502 Bad Gateway"))
        self.t[0] += 60
        self.run_beat(("upgrade", "HTTP/1.1 502 Bad Gateway"))
        self.assertEqual([e for e, _ in self.events], ["BUS_WATCHDOG_DOWN"])
        self.assertEqual(self.events[0][1]["step"], "upgrade")
        self.assertEqual(self.events[0][1]["problem"], "broker_unreachable")
        self.t[0] += bw.REPEAT
        self.run_beat(("upgrade", "x"))
        self.assertEqual([e for e, _ in self.events], ["BUS_WATCHDOG_DOWN"] * 2)
        self.t[0] += 30
        self.run_beat()
        self.assertEqual(self.events[-1][0], "BUS_WATCHDOG_OK")
        self.assertGreaterEqual(self.events[-1][1]["down_seconds"], bw.REPEAT)


if __name__ == "__main__":
    unittest.main()
