"""Offline safety regressions against the real setup-only writer.

Each fault changes a synthetic HOME path at a native syscall boundary. There are
no production hooks. Assertions describe the safety contract, not current output.
"""
import contextlib
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "setup_files", Path(os.environ["TEST_REPO"]) / "lib/setup-files.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class Safety(unittest.TestCase):
    def setUp(self):
        home = Path(os.environ["HOME"])
        self.assertTrue(str(home).startswith(os.environ["TEST_ROOT"] + "/"))
        self.temp = tempfile.TemporaryDirectory(dir=home)
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name) / "store"
        self.parent.mkdir()
        self.path = self.parent / "trust.json"
        self.original = b'{"saved":true}\n'
        self.path.write_bytes(self.original)
        self.request = {"path": str(self.path), "mode": "apply", "present": True,
                        "native": False, "expected": {"saved": True},
                        "proposed": {"saved": True, "added": True}}
        self.injected = False

    def call(self):
        output = io.StringIO()
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        mask = os.umask(0o077)
        try:
            with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(self.request))), \
                    contextlib.redirect_stdout(output):
                status = helper.main()
        finally:
            os.umask(mask)
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
        return status, json.loads(output.getvalue())

    def assert_refused(self, response, code):
        status, body = response
        self.assertTrue(self.injected, "fault was not injected")
        self.assertNotEqual(status, 0, "unsafe write was accepted")
        self.assertEqual(body["error"]["code"], code)
        self.assertEqual(body["result"]["applied_paths"], [],
                         "writer committed after a safety check became invalid")
        return body

    def at_final_destination_stat(self, action):
        real_stat = os.stat

        def stat_call(path, *args, **kwargs):
            # run() performs the last named-destination stat outside snapshot().
            frame = inspect.currentframe().f_back
            while frame is not None and frame.f_code.co_filename != helper.__file__:
                frame = frame.f_back
            caller = frame.f_code.co_name if frame is not None else None
            if path == self.path.name and caller == "run" and not self.injected:
                self.injected = True
                action()
            return real_stat(path, *args, **kwargs)
        return mock.patch.object(helper.os, "stat", side_effect=stat_call)

    def test_concurrent_edit_before_rename(self):
        edited = b'{"concurrent":"preserve me"}\n'
        # Inject at the last source read, after staging and backup creation.
        real_read = os.read
        reads = 0

        def read_call(fd, size):
            nonlocal reads
            data = real_read(fd, size)
            if data == self.original:
                reads += 1
                if reads == 7:
                    self.path.write_bytes(edited)
                    self.injected = True
            return data
        with mock.patch.object(helper.os, "read", side_effect=read_call):
            self.assert_refused(self.call(), "source_changed")
        self.assertEqual(self.path.read_bytes(), edited)

    def test_backup_edit_keeps_validated_baseline(self):
        edited = b'{"external":true}\n'
        real_write = os.write
        # The first write creates the backup. Change the original during it.
        def write_call(fd, data):
            count = real_write(fd, data)
            if not self.injected:
                self.injected = True
                self.path.write_bytes(edited)
            return count
        with mock.patch.object(helper.os, "write", side_effect=write_call):
            body = self.assert_refused(self.call(), "source_changed")
        self.assertEqual(self.path.read_bytes(), edited)
        self.assertEqual(len(body["result"]["backups"]), 1)
        backup = Path(body["result"]["backups"][0]["backup_path"])
        self.assertEqual(backup.read_bytes(), self.original)
        self.assertIn(str(backup), body["result"]["retained_paths"])

    def assert_incomplete_backup(self, response):
        status, body = response
        self.assertNotEqual(status, 0)
        self.assertEqual(body["result"]["backups"], [])
        retained = body["result"]["retained_paths"]
        self.assertEqual(len(retained), 1)
        self.assertIn(".dispatcher-backup.", retained[0])
        self.assertTrue(Path(retained[0]).is_file())
        self.assertEqual(self.path.read_bytes(), self.original)

    def test_backup_disk_full(self):
        with mock.patch.object(helper.os, "write", side_effect=OSError(28, "disk full")):
            self.assert_incomplete_backup(self.call())

    def test_backup_partial_write(self):
        real_write = os.write
        calls = 0
        def write_call(fd, data):
            nonlocal calls
            calls += 1
            if calls == 1:
                return real_write(fd, data[:3])
            raise OSError(28, "disk full")
        with mock.patch.object(helper.os, "write", side_effect=write_call):
            self.assert_incomplete_backup(self.call())

    def test_backup_signal(self):
        real_write = os.write
        def write_call(fd, data):
            real_write(fd, data[:3])
            os.kill(os.getpid(), signal.SIGTERM)
        with mock.patch.object(helper.os, "write", side_effect=write_call):
            self.assert_incomplete_backup(self.call())

    def test_backup_fsync_failure(self):
        with mock.patch.object(helper.os, "fsync", side_effect=OSError(28, "disk full")):
            self.assert_incomplete_backup(self.call())

    def test_directory_swap_before_rename(self):
        def swap():
            self.path.unlink()
            self.path.mkdir()
            (self.path / "sentinel").write_text("keep")
        with self.at_final_destination_stat(swap):
            self.assert_refused(self.call(), "source_changed")
        self.assertEqual((self.path / "sentinel").read_text(), "keep")

    def test_symlink_swap_before_rename(self):
        target = self.parent / "unrelated"
        target.write_bytes(b"keep")
        def swap():
            self.path.unlink()
            self.path.symlink_to(target)
        with self.at_final_destination_stat(swap):
            self.assert_refused(self.call(), "source_changed")
        self.assertTrue(self.path.is_symlink())
        self.assertEqual(target.read_bytes(), b"keep")

    def test_parent_swap_before_rename(self):
        moved = self.parent.with_name("old-store")
        def swap():
            self.parent.rename(moved)
            self.parent.mkdir()
            self.path.write_bytes(b'{"replacement":true}\n')
        with self.at_final_destination_stat(swap):
            self.assert_refused(self.call(), "parent_changed")
        self.assertEqual((moved / self.path.name).read_bytes(), self.original)
        self.assertEqual(self.path.read_bytes(), b'{"replacement":true}\n')

    def test_deadline_overrun_inside_inspection(self):
        self.request["native"] = True
        real_read = os.read
        clock = [100.0]
        def read_call(fd, size):
            data = real_read(fd, size)
            if b'"process_started_at"' in data and not self.injected:
                self.injected = True
                clock[0] += 3.0
            return data
        with mock.patch.object(helper.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(helper.time, "time", side_effect=lambda: clock[0]), \
                mock.patch.object(helper.os, "read", side_effect=read_call):
            body = self.assert_refused(self.call(), "lock_uncertain")
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertTrue(Path(str(self.path) + ".lock").is_dir())
        self.assertTrue(any(".dispatcher-owner." in p for p in body["result"]["retained_paths"]))

    def test_native_lock_replacement_inside_inspection(self):
        self.request["native"] = True
        lock = Path(str(self.path) + ".lock")
        old = self.parent / "old-lock"
        real_listdir = os.listdir
        def listdir_call(fd):
            entries = real_listdir(fd)
            if isinstance(fd, int) and not self.injected:
                self.injected = True
                lock.rename(old)
                lock.mkdir()
                (lock / "foreign-owner").write_text("keep")
            return entries
        with mock.patch.object(helper.os, "listdir", side_effect=listdir_call):
            body = self.assert_refused(self.call(), "lock_uncertain")
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual((lock / "foreign-owner").read_text(), "keep")
        self.assertIn(str(lock), body["result"]["retained_paths"])
        self.assertTrue(old.is_dir())

    def test_native_lock_replacement_before_rename(self):
        self.request["native"] = True
        lock = Path(str(self.path) + ".lock")
        old = self.parent / "old-lock"
        def swap():
            lock.rename(old)
            lock.mkdir()
            (lock / "foreign-owner").write_text("keep")
        with self.at_final_destination_stat(swap):
            self.assert_refused(self.call(), "lock_uncertain")
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual((lock / "foreign-owner").read_text(), "keep")
        self.assertTrue(old.is_dir())

    def test_deadline_overrun_at_final_destination_stat(self):
        self.request["native"] = True
        clock = [100.0]
        def expire():
            clock[0] += 3.0
        with mock.patch.object(helper.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(helper.time, "time", side_effect=lambda: clock[0]), \
                self.at_final_destination_stat(expire):
            self.assert_refused(self.call(), "lock_uncertain")
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertTrue(Path(str(self.path) + ".lock").is_dir())

    def test_signal_retains_uncommitted_evidence(self):
        self.request["native"] = True
        real_read = os.read
        def read_call(fd, size):
            data = real_read(fd, size)
            # The staged bytes are inspected only after acquiring the lock.
            if b'"added"' in data and not self.injected:
                self.injected = True
                os.kill(os.getpid(), signal.SIGTERM)
            return data
        with mock.patch.object(helper.os, "read", side_effect=read_call):
            body = self.assert_refused(self.call(), "interrupted")
        self.assertEqual(self.path.read_bytes(), self.original)
        retained = body["result"]["retained_paths"]
        self.assertIn(str(self.path) + ".lock", retained)
        for marker in (".dispatcher-owner.", ".dispatcher-backup.", ".dispatcher-new."):
            self.assertTrue(any(marker in p for p in retained), marker)
        for path in retained:
            self.assertTrue(Path(path).exists(), path)

    def test_signal_retains_committed_evidence(self):
        self.request["native"] = True
        real_replace = os.replace
        def replace_call(*args, **kwargs):
            real_replace(*args, **kwargs)
            self.injected = True
            # SIGTERM is blocked around replace + commit bookkeeping. The real
            # handler runs when the writer restores its signal mask.
            os.kill(os.getpid(), signal.SIGTERM)
        with mock.patch.object(helper.os, "replace", side_effect=replace_call):
            status, body = self.call()
        self.assertTrue(self.injected)
        self.assertEqual(status, 5)
        self.assertEqual(body["error"]["code"], "interrupted")
        self.assertEqual(body["result"]["applied_paths"], [str(self.path)])
        self.assertEqual(json.loads(self.path.read_bytes()), self.request["proposed"])
        retained = body["result"]["retained_paths"]
        self.assertIn(str(self.path) + ".lock", retained)
        self.assertTrue(any(".dispatcher-owner." in p for p in retained))
        self.assertTrue(any(".dispatcher-backup." in p for p in retained))
        self.assertFalse(any(".dispatcher-new." in p for p in retained))
        for path in retained:
            self.assertTrue(Path(path).exists(), path)


if __name__ == "__main__":
    unittest.main()
