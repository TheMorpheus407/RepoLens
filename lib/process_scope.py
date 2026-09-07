#!/usr/bin/env python3
# Copyright 2025-2026 Bootstrap Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Owned cgroup v2 lifecycle. No PID/PGID is used as signal authority.

The server retains directory descriptors until an empty scope is destroyed.
TERM uses pidfds opened and membership-checked while recursively frozen;
cgroup.kill provides the atomic recursive escalation. This is lifecycle
containment, not protection against deliberate same-UID cgroup migration.
"""
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import sys
import time
import uuid

BOUND = 5.0


def wait_for(predicate, seconds=BOUND):
    end = time.monotonic() + seconds
    while True:
        if predicate():
            return
        if time.monotonic() >= end:
            raise RuntimeError("bounded kernel transition timed out")
        time.sleep(0.02)


def membership(pid):
    for line in Path('/proc/{}/cgroup'.format(pid)).read_text().splitlines():
        if line.startswith('0::'):
            return line[3:]
    raise RuntimeError('unified cgroup v2 membership unavailable')


def unescape_mount(value):
    return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), value)


def current_cgroup():
    member = membership(os.getpid())
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        before, after = line.split(' - ', 1)
        if after.split()[0] != 'cgroup2':
            continue
        fields = before.split()
        root, mount = map(unescape_mount, (fields[3], fields[4]))
        if member == root or member.startswith(root.rstrip('/') + '/'):
            suffix = member[len(root.rstrip('/')):].lstrip('/')
            return Path(mount, suffix).resolve(), member
    raise RuntimeError('current cgroup v2 membership cannot be resolved')


def identity(fd):
    st = os.fstat(fd)
    return [st.st_dev, st.st_ino]


def open_dir(path, dir_fd=None):
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)


def read_at(fd, name):
    file_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
    with os.fdopen(file_fd) as stream:
        return stream.read()


def write_at(fd, name, value):
    file_fd = os.open(name, os.O_WRONLY | os.O_NOFOLLOW, dir_fd=fd)
    with os.fdopen(file_fd, 'w') as stream:
        stream.write(str(value))


def alive(pidfd):
    return not select.select([pidfd], [], [], 0)[0]


class Scope:
    def __init__(self, nonce, caller):
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            raise RuntimeError('Python 3.9+ with Linux pidfds is required')
        self.parent, parent_member = current_cgroup()
        self.parent_fd = open_dir(str(self.parent))
        self.name = 'repolens-' + uuid.uuid4().hex
        self.path = self.parent / self.name
        self.member = parent_member.rstrip('/') + '/' + self.name
        self.caller = caller
        self.caller_fd = os.pidfd_open(caller)
        self.nonce = nonce
        self.fd = None
        self.worker = None
        try:
            os.mkdir(self.name, mode=0o700, dir_fd=self.parent_fd)
            self.fd = open_dir(self.name, self.parent_fd)
            self.id = identity(self.fd)
            self.manifest = dict(path=str(self.path), identity=self.id, nonce=nonce)
            for name in ('cgroup.procs', 'cgroup.events', 'cgroup.freeze', 'cgroup.kill'):
                fd = os.open(name, (os.O_RDONLY if name == 'cgroup.events' else os.O_WRONLY)
                             | os.O_NOFOLLOW, dir_fd=self.fd)
                os.close(fd)
            self.validate()
        except BaseException:
            if self.fd is not None:
                os.close(self.fd)
            try:
                os.rmdir(self.name, dir_fd=self.parent_fd)
            except OSError:
                pass
            os.close(self.parent_fd)
            raise

    def validate(self):
        # Opening and validating the path cannot change our retained authority.
        check = open_dir(str(self.path))
        try:
            if identity(check) != self.id or identity(self.fd) != self.id:
                raise RuntimeError('cgroup identity mismatch')
        finally:
            os.close(check)
        if alive(self.caller_fd):
            try:
                caller_member = membership(self.caller)
            except FileNotFoundError:
                if alive(self.caller_fd):
                    raise
            else:
                if alive(self.caller_fd) and (caller_member == self.member or caller_member.startswith(self.member + '/')):
                    raise RuntimeError('caller belongs to worker scope')
        # Exact child of the originally retained delegated parent.
        check = open_dir(self.name, self.parent_fd)
        try:
            if identity(check) != self.id:
                raise RuntimeError('cgroup parent identity mismatch')
        finally:
            os.close(check)

    def events(self):
        self.validate()
        return dict(line.split() for line in read_at(self.fd, 'cgroup.events').splitlines())

    def populated(self):
        return self.events()['populated'] == '1'

    def verify_member(self, pid):
        self.validate()
        if pid == self.caller or pid == os.getpid():
            raise RuntimeError('cannot enroll caller or scope supervisor')
        # The callback is gated and cannot fork/exit normally before enrollment.
        worker = os.pidfd_open(pid)
        try:
            if not alive(worker):
                raise RuntimeError('gated callback exited before enrollment')
            if membership(pid) != self.member or not alive(worker):
                raise RuntimeError('callback enrollment verification failed')
            self.validate()
            wait_for(self.populated)
        except BaseException:
            os.close(worker)
            raise
        self.worker = worker

    def freeze(self, value):
        self.validate()
        write_at(self.fd, 'cgroup.freeze', value)
        wait_for(lambda: self.events()['frozen'] == str(value))

    def member_fds(self):
        # cgroup.freeze recursively covers descendants, including child cgroups.
        pending = [os.dup(self.fd)]
        pinned = []
        try:
            while pending:
                directory = pending.pop()
                try:
                    for entry in os.listdir(directory):
                        try:
                            child = open_dir(entry, directory)
                        except NotADirectoryError:
                            continue
                        pending.append(child)
                    for raw in read_at(directory, 'cgroup.procs').split():
                        try:
                            member_fd = os.pidfd_open(int(raw))
                        except ProcessLookupError:
                            continue
                        try:
                            member = membership(int(raw))
                            contained = member == self.member or member.startswith(self.member + '/')
                            # Rechecking the pidfd after /proc excludes numeric reuse
                            # even if an external SIGKILL raced the frozen snapshot.
                            if contained and alive(member_fd):
                                pinned.append(member_fd)
                                member_fd = None
                        except FileNotFoundError:
                            pass
                        finally:
                            if member_fd is not None:
                                os.close(member_fd)
                finally:
                    os.close(directory)
            return pinned
        except BaseException:
            for fd in pending + pinned:
                os.close(fd)
            raise

    def terminate(self, grace, force=lambda: False):
        self.validate()
        killed = False
        if self.populated():
            self.freeze(1)
            pinned = []
            try:
                pinned = self.member_fds()
                self.validate()
                for fd in pinned:
                    try:
                        signal.pidfd_send_signal(fd, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            finally:
                for fd in pinned:
                    os.close(fd)
                self.freeze(0)
            try:
                wait_for(lambda: not self.populated() or force(), grace)
            except RuntimeError:
                pass
            if self.populated():
                self.validate()
                write_at(self.fd, 'cgroup.kill', 1)
                killed = True
            wait_for(lambda: not self.populated())
        return 'killed' if killed else 'empty'

    def destroy(self):
        self.validate()
        if self.populated():
            raise RuntimeError('refusing to destroy a populated scope')
        # Remove empty nested cgroups from deepest first, using retained FDs.
        def remove_children(directory):
            for name in os.listdir(directory):
                try:
                    child = open_dir(name, directory)
                except NotADirectoryError:
                    continue
                try:
                    remove_children(child)
                    os.rmdir(name, dir_fd=directory)
                finally:
                    os.close(child)
        remove_children(self.fd)
        os.rmdir(self.name, dir_fd=self.parent_fd)
        self.close()

    def close(self):
        for fd in (self.worker, self.fd, self.parent_fd, self.caller_fd):
            if fd is not None:
                os.close(fd)
        self.worker = self.fd = self.parent_fd = self.caller_fd = None


def probe():
    scope = Scope(uuid.uuid4().hex, os.getpid())
    enrollment_fd = os.open('cgroup.procs', os.O_WRONLY | os.O_NOFOLLOW, dir_fd=scope.fd)
    child = subprocess.Popen([sys.executable, '-c',
                              'import os,signal,sys; os.write(int(sys.argv[1]), b"0"); '
                              'os.close(int(sys.argv[1])); print("ENROLLED", flush=True); '
                              'signal.signal(signal.SIGTERM, signal.SIG_IGN); sys.stdin.read()', str(enrollment_fd)],
                             pass_fds=(enrollment_fd,), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    os.close(enrollment_fd)
    try:
        wait_for(lambda: bool(select.select([child.stdout], [], [], 0)[0]))
        if os.read(child.stdout.fileno(), len(b'ENROLLED\n')) != b'ENROLLED\n':
            raise RuntimeError('probe self-enrollment failed')
        scope.verify_member(child.pid)
        scope.freeze(1)
        signal.pidfd_send_signal(scope.worker, signal.SIGTERM)
        scope.freeze(0)
        # Always exercise the recursive kill primitive during capability probing.
        scope.validate()
        write_at(scope.fd, 'cgroup.kill', 1)
        wait_for(lambda: not scope.populated())
        child.wait(timeout=BOUND)
        scope.destroy()
    except BaseException:
        # Popen retains this unreaped direct child's identity; no PID reuse.
        child.kill()
        child.wait(timeout=BOUND)
        try:
            scope.destroy()
        except Exception:
            scope.close()
        raise
    finally:
        child.stdin.close()
        child.stdout.close()


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


def serve(runtime, nonce, caller):
    # The orchestrator owns signal policy. Its foreground process-group signals
    # must not kill the supervisor before it can drain nested groups/sessions.
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    scope = Scope(nonce, caller)
    parent_fd = os.pidfd_open(caller)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(runtime / 'control'))
    server.listen(1)
    server.settimeout(0.2)
    atomic_json(runtime / 'manifest.json', scope.manifest)
    (runtime / 'server.ready').touch()
    terminal = False
    try:
        while True:
            if not alive(parent_fd):
                # Parent disappeared: clean using retained identity, never its PID.
                if json.loads((runtime / 'manifest.json').read_text()) != scope.manifest:
                    raise RuntimeError('parent exited with invalid scope manifest; diagnostics retained')
                scope.terminate(0)
                scope.destroy()
                break
            try:
                connection, _ = server.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(BOUND)
                try:
                    request = json.loads(connection.makefile('rb').readline(4096))
                    if request['nonce'] != nonce:
                        raise ValueError('scope nonce mismatch')
                    if json.loads((runtime / 'manifest.json').read_text()) != scope.manifest:
                        raise ValueError('scope manifest identity mismatch')
                    command, args = request['command'], request['args']
                    scope.validate()
                    result = 'ok'
                    if command == 'enrollment-file':
                        result = str(scope.path / 'cgroup.procs')
                    elif command == 'verify-enrollment-file':
                        # The parent holds this verified descriptor across fork;
                        # child self-enrollment writes 0, never a numeric PID.
                        if int(args[0]) != caller:
                            raise RuntimeError('enrollment descriptor owner mismatch')
                        inherited = os.stat('/proc/{}/fd/{}'.format(caller, int(args[1])))
                        own = os.stat('cgroup.procs', dir_fd=scope.fd, follow_symlinks=False)
                        if (inherited.st_dev, inherited.st_ino) != (own.st_dev, own.st_ino):
                            raise RuntimeError('enrollment descriptor identity mismatch')
                    elif command == 'enroll':
                        scope.verify_member(int(args[0]))
                    elif command == 'state':
                        result = ('populated' if scope.worker is not None and alive(scope.worker) else 'orphaned') if scope.populated() else 'empty'
                    elif command == 'terminate':
                        result = scope.terminate(float(args[0]), lambda: (runtime / 'force-kill').exists() and (runtime / 'force-kill').read_text().strip() == nonce)
                    elif command == 'destroy':
                        scope.destroy()
                        terminal = True
                    else:
                        raise ValueError('unknown scope command')
                    response = dict(ok=True, result=result)
                except Exception as exc:
                    response = dict(ok=False, error=str(exc))
                    # Preserve the object and diagnostics; never guess at cleanup.
                    atomic_json(runtime / 'terminal-error.json', response)
                connection.sendall(json.dumps(response).encode() + b'\n')
            if terminal:
                break
    finally:
        server.close()
        os.close(parent_fd)
        if scope.fd is not None:
            scope.close()


def call(runtime, nonce, command, args):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(BOUND * 4 + (float(args[0]) if command == 'terminate' else 0))
        client.connect(str(runtime / 'control'))
        client.sendall(json.dumps(dict(nonce=nonce, command=command, args=args)).encode() + b'\n')
        response = json.loads(client.makefile('rb').readline(4096))
    if not response['ok']:
        raise RuntimeError(response['error'])
    print(response['result'])


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'probe':
            probe()
        elif sys.argv[1] == 'serve':
            serve(Path(sys.argv[2]), sys.argv[3], int(sys.argv[4]))
        elif sys.argv[1] == 'call':
            call(Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5:])
        else:
            raise ValueError('unknown backend operation')
    except Exception as error:
        print('process scope: {}'.format(error), file=sys.stderr)
        sys.exit(1)
