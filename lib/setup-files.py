"""Internal setup-only file writer. Input and output are JSON on standard streams.

Run with python3 -I and an absolute script path. No agent or package is invoked.
"""
import sys
sys.dont_write_bytecode = True

import datetime
import json
import os
import secrets
import signal
import stat
import subprocess
import time


class Failure(Exception):
    def __init__(self, status, code, message):
        self.status, self.code, self.message = status, code, message


def identity(info):
    return info.st_dev, info.st_ino


def json_equal(left, right):
    # Python considers True == 1. JSON trust decisions must not do so.
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is type(right) and left == right
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(json_equal(left[key], right[key]) for key in left)
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(json_equal(a, b) for a, b in zip(left, right))
    return left == right


def interrupted(signum, frame):
    raise Failure(5, "interrupted", "Setup interrupted; inspect retained evidence")


class Writer:
    def __init__(self, request):
        self.request = request
        self.path = request["path"]
        if (not isinstance(self.path, str) or not self.path.startswith("/")
                or any(part in ("", ".", "..") for part in self.path.split("/")[1:])
                or "\x00" in self.path or "\n" in self.path):
            raise Failure(3, "unsafe_parent", "Destination must be a safe absolute path")
        self.parent, self.name = os.path.split(self.path)
        self.fd = None
        self.chain = None
        self.backups = []
        self.applied = []
        self.retained = []
        self.created = []
        self.lock_active = False
        self.lock_id = None
        self.lock_started = None
        self.lock_wall_started = None
        self.owner = None
        self.owner_id = None
        self.owner_bytes = None
        self.lock_name = self.name + ".lock"

    def open_parent(self, create=False):
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        chain = [identity(os.fstat(fd))]
        current = ""
        try:
            for part in self.parent.split("/")[1:]:
                if not part:
                    continue
                current += "/" + part
                try:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except FileNotFoundError:
                    if not create:
                        raise
                    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
                    try:
                        os.mkdir(part, 0o700, dir_fd=fd)
                        self.created.append(current)
                    finally:
                        signal.pthread_sigmask(signal.SIG_SETMASK, previous)
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
                chain.append(identity(os.fstat(fd)))
            return fd, chain
        except BaseException:
            os.close(fd)
            raise

    def parent_guard(self):
        try:
            fd, chain = self.open_parent()
            os.close(fd)
        except OSError as exc:
            raise Failure(5 if self.lock_active or self.applied else 3,
                          "parent_changed", "Physical parent is no longer safe") from exc
        if chain != self.chain:
            raise Failure(5 if self.lock_active or self.applied else 3,
                          "parent_changed", "Physical parent identity changed")

    def snapshot(self, name):
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise Failure(3, "source_changed", "Source is no longer a safe regular file") from exc
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode):
                raise Failure(3, "source_changed", "Source is not a regular file")
            chunks = []
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
            after = os.fstat(fd)
            named = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            signature = lambda info: (identity(info), info.st_mode, info.st_size,
                                      info.st_mtime_ns, info.st_ctime_ns)
            if signature(before) != signature(after) or signature(after) != signature(named):
                raise Failure(3, "source_changed", "Source changed during inspection")
            return b"".join(chunks), signature(after), stat.S_IMODE(after.st_mode)
        finally:
            os.close(fd)

    def same_source(self):
        self.parent_guard()
        if self.snapshot(self.name) != self.original:
            raise Failure(3, "source_changed", "Source changed since the validated snapshot")
        self.parent_guard()

    def private_file(self, name, content, mode=0o600):
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=self.fd)
            self.retained.append(self.parent + "/" + name)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        try:
            view = memoryview(content)
            while view:
                count = os.write(fd, view)
                if count <= 0:
                    raise OSError("Private file write made no progress")
                view = view[count:]
            os.fchmod(fd, mode)
            os.fsync(fd)
            return identity(os.fstat(fd))
        finally:
            os.close(fd)

    def time_guard(self):
        elapsed = time.monotonic() - self.lock_started
        wall_elapsed = time.time() - self.lock_wall_started
        # Wall time also detects suspension on hosts whose monotonic clock stops
        # during sleep. A clock jump is uncertainty, not permission to continue.
        if elapsed < 0 or elapsed >= 2.0 or wall_elapsed < 0 or wall_elapsed >= 2.0:
            raise Failure(5, "lock_uncertain", "Native lock deadline expired; lock retained")

    def lock_guard(self):
        self.time_guard()
        self.parent_guard()
        self.time_guard()
        try:
            info = os.stat(self.lock_name, dir_fd=self.fd, follow_symlinks=False)
            if not stat.S_ISDIR(info.st_mode) or identity(info) != self.lock_id:
                raise Failure(5, "lock_uncertain", "Native lock identity changed")
            fd = os.open(self.lock_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
            try:
                if identity(os.fstat(fd)) != self.lock_id or os.listdir(fd):
                    raise Failure(5, "lock_uncertain", "Native lock is not the same empty directory")
            finally:
                os.close(fd)
            again = os.stat(self.lock_name, dir_fd=self.fd, follow_symlinks=False)
            if identity(again) != self.lock_id or not stat.S_ISDIR(again.st_mode):
                raise Failure(5, "lock_uncertain", "Native lock changed during inspection")
            owner = self.snapshot(self.owner)
            if owner is None or owner[0] != self.owner_bytes or owner[1][0] != self.owner_id:
                raise Failure(5, "lock_uncertain", "Native lock sidecar identity or token changed")
        except OSError as exc:
            raise Failure(5, "lock_uncertain", "Cannot verify native lock ownership") from exc
        except Failure as exc:
            if exc.status != 5:
                raise Failure(5, "lock_uncertain", "Cannot verify native lock sidecar") from exc
            raise
        self.time_guard()

    def acquire(self):
        token = secrets.token_hex(16)
        # Process inspection is outside the native critical section.
        started = subprocess.run(["/bin/ps", "-p", str(os.getpid()), "-o", "lstart="],
                                 check=True, capture_output=True, text=True, timeout=1,
                                 env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}).stdout.strip()
        if not started:
            raise Failure(6, "process_identity", "Cannot inspect setup process identity")
        self.owner = self.name + ".dispatcher-owner." + token + ".json"
        self.owner_bytes = (json.dumps({"schema_version": 1, "pid": os.getpid(),
                            "process_started_at": started, "token": token,
                            "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}) + "\n").encode()
        self.owner_id = self.private_file(self.owner, self.owner_bytes)
        self.parent_guard()
        self.lock_wall_started = time.time()
        self.lock_started = time.monotonic()
        self.retained.append(self.path + ".lock")
        self.lock_active = True  # A signal during mkdir must retain ambiguous evidence.
        try:
            os.mkdir(self.lock_name, 0o700, dir_fd=self.fd)
        except FileExistsError as exc:
            self.lock_active = False
            self.retained.remove(self.path + ".lock")
            raise Failure(3, "native_lock_busy", "Native pi lock exists; never reclaimed") from exc
        self.time_guard()
        self.lock_id = identity(os.stat(self.lock_name, dir_fd=self.fd, follow_symlinks=False))
        self.lock_guard()

    def release(self):
        self.lock_guard()
        os.rmdir(self.lock_name, dir_fd=self.fd)
        self.time_guard()
        self.lock_active = False
        self.retained.remove(self.path + ".lock")
        self.parent_guard()
        owner = self.snapshot(self.owner)
        if owner is None or owner[0] != self.owner_bytes or owner[1][0] != self.owner_id:
            raise Failure(5, "lock_uncertain", "Released native lock; sidecar changed")
        os.unlink(self.owner, dir_fd=self.fd)
        self.retained.remove(self.parent + "/" + self.owner)

    def run(self):
        mode = self.request["mode"]
        if mode not in ("apply", "dry-run") or type(self.request["present"]) is not bool or type(self.request["native"]) is not bool:
            raise Failure(3, "invalid_input", "Invalid file-writer mode or flags")
        proposed = (json.dumps(self.request["proposed"], ensure_ascii=False, allow_nan=False) + "\n").encode()
        self.fd, self.chain = self.open_parent(create=mode == "apply")
        self.original = self.snapshot(self.name)
        if self.request["present"] != (self.original is not None):
            raise Failure(3, "source_changed", "Source presence changed since preview")
        if self.original is not None:
            try:
                actual = json.loads(self.original[0])
            except (ValueError, UnicodeError) as exc:
                raise Failure(3, "source_changed", "Source JSON changed since preview") from exc
            if not json_equal(actual, self.request["expected"]):
                raise Failure(3, "source_changed", "Source JSON changed since preview")
        self.same_source()
        if mode == "dry-run":
            return
        token = secrets.token_hex(16)
        if self.original is not None:
            backup = self.name + ".dispatcher-backup." + token
            backup_id = self.private_file(backup, self.original[0])
            saved = self.snapshot(backup)
            if (saved is None or saved[0] != self.original[0]
                    or saved[1][0] != backup_id or saved[2] != 0o600):
                raise Failure(6, "backup_failed", "Private backup bytes or identity do not match snapshot")
            self.parent_guard()
            self.backups.append({"path": self.path, "backup_path": self.parent + "/" + backup})
            self.same_source()
        stage = self.name + ".dispatcher-new." + token
        stage_id = self.private_file(stage, proposed, self.original[2] if self.original else 0o600)
        self.same_source()
        if self.request["native"]:
            self.acquire()
        # All operations from acquire through release use only native Python APIs.
        self.same_source()
        if self.lock_active:
            self.lock_guard()
        staged = self.snapshot(stage)
        if staged is None or staged[0] != proposed or staged[1][0] != stage_id:
            raise Failure(3, "staging_changed", "Staged file changed")
        self.same_source()
        if self.lock_active:
            self.lock_guard()
        # Check the named destination immediately before rename. A directory or
        # symlink must never be accepted as the destination inspected above.
        try:
            destination = os.stat(self.name, dir_fd=self.fd, follow_symlinks=False)
        except FileNotFoundError:
            destination = None
        if self.original is None:
            unchanged = destination is None
        else:
            unchanged = (destination is not None and stat.S_ISREG(destination.st_mode)
                         and identity(destination) == self.original[1][0])
        if not unchanged:
            raise Failure(3, "source_changed", "Destination inode or type changed before replacement")
        # Destination inspection can block or observe a concurrent directory move.
        # Recheck both parent and lock after it, before committing the rename.
        self.parent_guard()
        if self.lock_active:
            self.lock_guard()
        # Delay handled signals only for rename plus the commit record. Report a
        # committed rename even when a signal arrives inside the native call.
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            os.replace(stage, self.name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
            self.applied.append(self.path)
            self.retained.remove(self.parent + "/" + stage)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        if self.lock_active:
            self.lock_guard()
        self.parent_guard()
        named = os.stat(self.name, dir_fd=self.fd, follow_symlinks=False)
        if not stat.S_ISREG(named.st_mode) or identity(named) != stage_id:
            raise Failure(5, "destination_changed", "Destination changed after replacement")
        if self.lock_active:
            self.lock_guard()
            self.release()
        self.parent_guard()

    def result(self):
        return {"backups": self.backups, "applied_paths": self.created + self.applied,
                "retained_paths": self.retained}


def main():
    os.umask(0o077)
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    writer = None
    status, code, message = 0, None, None
    try:
        request = json.load(sys.stdin)
        writer = Writer(request)
        writer.run()
    except Failure as exc:
        status, code, message = exc.status, exc.code, exc.message
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        status, code, message = 6, "file_write_failed", "Safe file preparation or write failed"
    # A definite source conflict can release a positively verified lock. Signals,
    # expired deadlines, and all ownership uncertainty retain it unchanged.
    if writer is not None and writer.lock_active and status == 3:
        try:
            writer.release()
        except (Failure, OSError):
            status, code, message = 5, "lock_uncertain", "Conflict detected; native lock release is uncertain"
    if writer is not None and (writer.lock_active or writer.applied) and status:
        status = 5
    result = writer.result() if writer is not None else {"backups": [], "applied_paths": [], "retained_paths": []}
    # Never release on an exception or signal. Retain evidence for human inspection.
    if writer is not None and writer.fd is not None:
        os.close(writer.fd)
    print(json.dumps({"ok": status == 0, "result": result,
                      "error": None if status == 0 else {"code": code, "message": message}}))
    return status


if __name__ == "__main__":
    sys.exit(main())
