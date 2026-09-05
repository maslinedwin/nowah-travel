#!/usr/bin/python3
"""Adversarial tests for bin/nowah-sync's state I/O and process boundaries.

Run: python3 tests/state_io_test.py   (no network; the dev origin points at a
closed port so every request fails fast and the offline paths are exercised.)
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "nowah-sync")
HELPER = os.path.normpath(HELPER)
PY = "/usr/bin/python3"
TOKEN = "nowah_dev_" + "a" * 43


def run(state_home, *args, env=None, timeout=30):
    environ = {
        "HOME": state_home,
        "XDG_STATE_HOME": state_home,
        # Unreachable origin: network paths fail fast, offline logic is exercised.
        "NOWAH_DEV_API_ORIGIN": "https://127.0.0.1:9",
        "NOWAH_DEV_CONSENT": "1",
    }
    if env:
        environ.update(env)
    return subprocess.run(
        [PY, HELPER, *args], env=environ, capture_output=True, timeout=timeout, text=False
    )


class StateIoTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.state = os.path.join(self.home, "nowah-omarchy-dev")

    def leaf(self, name):
        return os.path.join(self.state, name)

    def status(self):
        with open(self.leaf("status.json")) as fh:
            return json.load(fh)

    def seed(self):
        run(self.home, "disconnect")

    # --- blocker 1: unsafe opens -------------------------------------------

    def test_fifo_as_state_dir_does_not_block(self):
        os.mkfifo(self.state)
        started = time.monotonic()
        proc = run(self.home, "refresh", timeout=15)
        self.assertLess(time.monotonic() - started, 10, "must not block on a FIFO")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(b"state dir", proc.stderr)

    def test_fifo_as_leaf_does_not_block_and_is_refused(self):
        self.seed()
        os.mkfifo(self.leaf("token"))
        started = time.monotonic()
        proc = run(self.home, "refresh", timeout=15)
        self.assertLess(time.monotonic() - started, 10, "must not block on a FIFO leaf")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(self.status()["auth"]["state"], "signed_out")

    def test_fifo_as_status_is_refused_by_reader_and_replaced_by_publish(self):
        self.seed()
        os.unlink(self.leaf("status.json"))
        os.mkfifo(self.leaf("status.json"))
        started = time.monotonic()
        proc = run(self.home, "read-snapshot", timeout=15)
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, b"")
        run(self.home, "disconnect")
        self.assertTrue(stat.S_ISREG(os.lstat(self.leaf("status.json")).st_mode))

    def test_symlinked_leaf_is_never_followed(self):
        self.seed()
        victim = os.path.join(self.home, "victim")
        with open(victim, "w") as fh:
            fh.write("PRECIOUS")
        os.symlink(victim, self.leaf("token"))
        self.assertEqual(run(self.home, "refresh").returncode, 0)
        with open(victim) as fh:
            self.assertEqual(fh.read(), "PRECIOUS", "victim must be untouched")
        self.assertEqual(self.status()["auth"]["state"], "signed_out")

    def test_publish_replaces_a_symlink_without_touching_its_target(self):
        self.seed()
        victim = os.path.join(self.home, "victim2")
        with open(victim, "w") as fh:
            fh.write("PRECIOUS")
        os.unlink(self.leaf("status.json"))
        os.symlink(victim, self.leaf("status.json"))
        self.assertEqual(run(self.home, "disconnect").returncode, 0)
        with open(victim) as fh:
            self.assertEqual(fh.read(), "PRECIOUS")
        self.assertTrue(stat.S_ISREG(os.lstat(self.leaf("status.json")).st_mode))

    def test_hardlinked_leaf_is_refused(self):
        self.seed()
        other = os.path.join(self.home, "other")
        with open(other, "w") as fh:
            json.dump({"origin": "https://127.0.0.1:9", "token": TOKEN}, fh)
        os.link(other, self.leaf("token"))
        self.assertEqual(run(self.home, "refresh").returncode, 0)
        self.assertEqual(self.status()["auth"]["state"], "signed_out", "nlink != 1 must be rejected")

    def test_symlinked_state_dir_is_refused(self):
        real = os.path.join(self.home, "real")
        os.mkdir(real)
        os.symlink(real, self.state)
        proc = run(self.home, "refresh")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(b"state dir", proc.stderr)

    # --- blocker 2: no PATH-resolved tools ---------------------------------

    def test_works_with_an_empty_path(self):
        self.seed()
        proc = run(self.home, "disconnect", env={"PATH": ""})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.status()["auth"]["state"], "signed_out")
        proc = run(self.home, "read-snapshot", env={"PATH": ""})
        self.assertEqual(proc.returncode, 0)
        self.assertIn(b'"version":1', proc.stdout)

    def test_launch_refuses_off_origin_and_non_app_paths(self):
        for bad in ("https://evil.example/x", "//evil.example", "/x\nnewline", "x" * 400):
            proc = run(self.home, "launch", bad)
            self.assertNotEqual(proc.returncode, 0, "must refuse %r" % bad)

    # --- blocker 3: exact-size snapshot bound -------------------------------

    def test_reader_accepts_the_cap_and_rejects_one_byte_more(self):
        self.seed()
        cap = 256 * 1024
        payload = b'{"pad":"' + b"a" * (cap - 11) + b'"}\n'
        self.assertEqual(len(payload), cap)
        with open(self.leaf("status.json"), "wb") as fh:
            fh.write(payload)
        proc = run(self.home, "read-snapshot")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(len(proc.stdout), cap)

        with open(self.leaf("status.json"), "wb") as fh:
            fh.write(payload + b"x")
        proc = run(self.home, "read-snapshot")
        self.assertEqual(proc.returncode, 2, "one byte over the cap must be rejected")
        self.assertEqual(proc.stdout, b"")

    # --- credential handling ------------------------------------------------

    def test_wrong_origin_token_is_deleted(self):
        self.seed()
        with open(self.leaf("token"), "w") as fh:
            json.dump({"origin": "https://evil.example", "token": TOKEN}, fh)
        self.assertEqual(run(self.home, "refresh").returncode, 0)
        self.assertFalse(os.path.exists(self.leaf("token")))
        self.assertEqual(self.status()["auth"]["error"], "origin_mismatch")

    def test_offline_refresh_preserves_previous_trips(self):
        self.seed()
        doc = self.status()
        doc["trips"] = [{"id": "t1", "destinationCity": "Tokyo"}]
        doc["auth"]["state"] = "signed_in"
        with open(self.leaf("status.json"), "w") as fh:
            json.dump(doc, fh)
        with open(self.leaf("token"), "w") as fh:
            json.dump({"origin": "https://127.0.0.1:9", "token": TOKEN}, fh)
        self.assertEqual(run(self.home, "refresh").returncode, 0)
        after = self.status()
        self.assertEqual(after["auth"]["state"], "signed_in")
        self.assertEqual(len(after["trips"]), 1)
        self.assertEqual(after["lastSync"]["ok"], False)

    def test_hostile_carried_state_is_reschemad(self):
        self.seed()
        doc = self.status()
        doc["auth"]["state"] = "pairing"
        doc["auth"]["pairing"] = {"userCode": "<b>EVIL</b>", "verificationUrl": "https://evil.example/x",
                                  "expiresAt": "2099-01-01T00:00:00Z", "interval": "zzz"}
        doc["trips"] = [{"id": "../evil?x", "name": "<img src=x>"}, 5, {"id": "ok", "name": "n" * 500}]
        with open(self.leaf("status.json"), "w") as fh:
            json.dump(doc, fh)
        self.assertEqual(run(self.home, "refresh").returncode, 0)
        after = self.status()
        self.assertEqual(after["auth"]["state"], "signed_out")
        self.assertIsNone(after["auth"]["pairing"])

    def test_pairing_state_survives_only_with_a_valid_carried_code(self):
        self.seed()
        doc = self.status()
        doc["auth"]["state"] = "pairing"
        doc["auth"]["pairing"] = {
            "userCode": "ABCD-EFGH",
            "verificationUrl": "https://app.nowah.xyz/device?code=ABCD-EFGH",
            "expiresAt": "2099-01-01T00:00:00Z", "interval": 5}
        with open(self.leaf("status.json"), "w") as fh:
            json.dump(doc, fh)
        self.assertEqual(run(self.home, "refresh").returncode, 0)
        after = self.status()
        self.assertEqual(after["auth"]["state"], "pairing")
        self.assertEqual(after["auth"]["pairing"]["userCode"], "ABCD-EFGH")

    def test_pairing_expiry_is_utc_regardless_of_local_timezone(self):
        import time as _t
        self.seed()
        doc = self.status()
        expires = _t.strftime("%Y-%m-%dT%H:%M:%SZ", _t.gmtime(_t.time() + 600))
        doc["auth"]["state"] = "pairing"
        doc["auth"]["pairing"] = {"userCode": "ABCD-EFGH",
                                  "verificationUrl": "https://app.nowah.xyz/device?code=ABCD-EFGH",
                                  "expiresAt": expires, "interval": 5}
        with open(self.leaf("status.json"), "w") as fh:
            json.dump(doc, fh)
        for tz in ("UTC", "Europe/Berlin", "Asia/Tokyo", "America/Los_Angeles", "Pacific/Auckland"):
            self.assertEqual(run(self.home, "refresh", env={"TZ": tz}).returncode, 0)
            self.assertEqual(self.status()["auth"]["state"], "pairing", "live pairing dropped under TZ=" + tz)

    def test_disconnect_removes_the_credential_even_while_another_run_holds_the_lock(self):
        import fcntl
        self.seed()
        with open(self.leaf("token"), "w") as fh:
            json.dump({"origin": "https://127.0.0.1:9", "token": TOKEN}, fh)
        dfd = os.open(self.state, os.O_RDONLY | os.O_DIRECTORY)
        fcntl.flock(dfd, fcntl.LOCK_EX)
        try:
            proc = run(self.home, "disconnect", timeout=60)
        finally:
            fcntl.flock(dfd, fcntl.LOCK_UN)
            os.close(dfd)
        self.assertEqual(proc.returncode, 0)
        self.assertFalse(os.path.exists(self.leaf("token")), "the credential must be gone regardless of the lock")

    def test_pair_start_fails_loudly_when_the_state_is_busy(self):
        import fcntl
        self.seed()
        dfd = os.open(self.state, os.O_RDONLY | os.O_DIRECTORY)
        fcntl.flock(dfd, fcntl.LOCK_EX)
        try:
            proc = run(self.home, "pair-start", timeout=90)
        finally:
            fcntl.flock(dfd, fcntl.LOCK_UN)
            os.close(dfd)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(b"busy", proc.stderr)

    def test_dev_override_requires_explicit_consent(self):
        proc = subprocess.run(
            [PY, HELPER, "refresh"],
            env={"HOME": self.home, "XDG_STATE_HOME": self.home,
                 "NOWAH_DEV_API_ORIGIN": "https://dev-api.nowah.xyz"},
            capture_output=True, timeout=30)
        self.assertEqual(proc.returncode, 2)
        self.assertIn(b"NOWAH_DEV_CONSENT", proc.stderr)

    def test_state_dir_and_leaves_are_private(self):
        self.seed()
        self.assertEqual(stat.S_IMODE(os.stat(self.state).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.leaf("status.json")).st_mode), 0o600)

    def test_no_temp_leaves_remain(self):
        self.seed()
        run(self.home, "refresh")
        leftovers = [n for n in os.listdir(self.state) if n.startswith(".tmp.")]
        self.assertEqual(leftovers, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
