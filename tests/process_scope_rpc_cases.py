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

"""Exercise the real supervisor protocol; retained test FDs clean red cases."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HELPER = sys.argv[1]


def wait_for(predicate, seconds=8):
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError('test lifecycle deadline exceeded')
        time.sleep(0.02)


def identity(fd):
    st = os.fstat(fd)
    return st.st_dev, st.st_ino


class RunningScope:
    def __init__(self, runtime, separate_parent=False, populated=True):
        self.runtime = runtime
        self.runtime.mkdir()
        self.nonce = uuid.uuid4().hex
        self.worker = self.server = self.parent = None
        self.scope_fd = self.parent_fd = None
        self.log = (runtime / 'supervisor.log').open('w')
        if separate_parent:
            self.parent = subprocess.Popen(
                [sys.executable, '-c', 'import sys; sys.stdin.read()'],
                stdin=subprocess.PIPE)
        caller = self.parent.pid if self.parent else os.getpid()
        try:
            self.server = subprocess.Popen(
                [sys.executable, HELPER, 'serve', str(runtime), self.nonce, str(caller)],
                stdout=self.log, stderr=self.log)
            wait_for(lambda: (runtime / 'server.ready').exists() or self.server.poll() is not None)
            assert self.server.poll() is None, 'supervisor failed to start'
            self.manifest = json.loads((runtime / 'manifest.json').read_text())
            self.path = Path(self.manifest['path'])
            self.parent_fd = os.open(str(self.path.parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            self.scope_fd = os.open(self.path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                    dir_fd=self.parent_fd)
            assert list(identity(self.scope_fd)) == self.manifest['identity']
            if populated:
                enrollment_fd = os.open('cgroup.procs', os.O_WRONLY | os.O_NOFOLLOW,
                                        dir_fd=self.scope_fd)
                try:
                    self.worker = subprocess.Popen([
                        sys.executable, '-c',
                        'import os,pathlib,signal,sys,time; '
                        'os.write(int(sys.argv[1]), b"0"); os.close(int(sys.argv[1])); '
                        'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                        'pathlib.Path(sys.argv[2]).touch(); time.sleep(120)',
                        str(enrollment_fd), str(runtime / 'worker.ready')],
                        pass_fds=(enrollment_fd,))
                finally:
                    os.close(enrollment_fd)
                wait_for(lambda: (runtime / 'worker.ready').exists())
                assert self.request('enroll', [str(self.worker.pid)])['ok']
                self.assert_populated()
        except BaseException:
            self.close()
            raise

    def connect(self):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(10)
        client.connect(str(self.runtime / 'control'))
        return client

    def payload(self, command, args=()):
        return json.dumps(dict(nonce=self.nonce, command=command, args=list(args))).encode() + b'\n'

    def request(self, command, args=()):
        with self.connect() as client:
            client.sendall(self.payload(command, args))
            with client.makefile('rb') as response:
                return json.loads(response.readline(4096))

    def disconnect(self, payload):
        with self.connect() as client:
            # Disable reply delivery before sending: no race with a fast server.
            client.shutdown(socket.SHUT_RD)
            client.sendall(payload)
            client.shutdown(socket.SHUT_WR)

    def assert_populated(self):
        assert self.request('state') == dict(ok=True, result='populated')
        assert self.server.poll() is None, 'supervisor exited after client disconnect'
        assert self.worker.poll() is None, 'read-only request stopped the worker'
        assert list(identity(self.scope_fd)) == self.manifest['identity']
        assert json.loads((self.runtime / 'manifest.json').read_text()) == self.manifest

    def drain(self):
        assert self.request('terminate', ['0']) == dict(ok=True, result='killed')
        self.worker.wait(timeout=5)
        assert self.request('state') == dict(ok=True, result='empty')
        assert self.request('destroy') == dict(ok=True, result='ok')
        assert self.server.wait(timeout=5) == 0
        assert not self.path.exists(), 'destroy left a cgroup behind'

    def close(self):
        # Test-owned retained directory descriptors are the cleanup authority
        # even when the unfixed supervisor crashes. Never signal numeric PIDs.
        if self.scope_fd is not None and self.path.exists():
            check = os.open(self.path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=self.parent_fd)
            try:
                assert identity(check) == identity(self.scope_fd)
                assert list(identity(check)) == self.manifest['identity']
                kill_fd = os.open('cgroup.kill', os.O_WRONLY | os.O_NOFOLLOW, dir_fd=self.scope_fd)
                try:
                    os.write(kill_fd, b'1')
                finally:
                    os.close(kill_fd)
            finally:
                os.close(check)
        for process in (self.worker, self.server, self.parent):
            if process is not None:
                # Popen owns unreaped direct children; this cannot alias a reused PID.
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
        if self.parent is not None:
            self.parent.stdin.close()
        if self.scope_fd is not None:
            if self.path.exists():
                wait_for(lambda: 'populated 0' in (self.path / 'cgroup.events').read_text())
                os.rmdir(self.path.name, dir_fd=self.parent_fd)
            os.close(self.scope_fd)
        if self.parent_fd is not None:
            os.close(self.parent_fd)
        self.log.close()


def valid_disconnect(scope):
    scope.disconnect(scope.payload('state'))
    scope.assert_populated()
    assert not (scope.runtime / 'terminal-error.json').exists()
    rejected = scope.request('destroy')
    assert not rejected['ok'] and 'populated' in rejected['error']
    scope.assert_populated()
    scope.drain()


def invalid_disconnect(scope):
    for payload in (b'', b'{bad json}\n', b'{"nonce":"wrong","command":"destroy","args":[]}\n'):
        scope.disconnect(payload)
        scope.assert_populated()
        diagnostic = json.loads((scope.runtime / 'terminal-error.json').read_text())
        assert not diagnostic['ok'] and diagnostic['error']
    assert 'nonce mismatch' in diagnostic['error']
    scope.drain()


def request_timeout(scope):
    with scope.connect() as stalled:
        stalled.sendall(b'{')
        started = time.monotonic()
        scope.assert_populated()  # Queued behind the incomplete request.
        assert 4 <= time.monotonic() - started < 8, 'request timeout was not bounded'
        with stalled.makefile('rb') as response:
            error = json.loads(response.readline(4096))
        assert not error['ok'] and 'timed out' in error['error']
    scope.drain()


def destroy_disconnect(scope):
    scope.disconnect(scope.payload('destroy'))
    assert scope.server.wait(timeout=5) == 0, 'destroy reply failure changed successful shutdown'
    assert not scope.path.exists()


def terminate_disconnect(scope):
    scope.disconnect(scope.payload('terminate', ['0']))
    assert scope.request('state') == dict(ok=True, result='empty')
    scope.worker.wait(timeout=5)
    assert scope.request('destroy') == dict(ok=True, result='ok')
    assert scope.server.wait(timeout=5) == 0
    assert not scope.path.exists()


def parent_death(scope):
    scope.disconnect(scope.payload('state'))
    scope.assert_populated()
    scope.parent.stdin.close()
    scope.parent.wait(timeout=5)
    assert scope.server.wait(timeout=5) == 0, 'parent-death cleanup lost its supervisor'
    scope.worker.wait(timeout=5)
    assert not scope.path.exists(), 'parent-death cleanup left a populated scope'


def long_runtime(scope):
    # Exercise both CLI socket endpoints with a pathname beyond sun_path's
    # limit, while keeping the filesystem-backed private control socket.
    assert len(os.fsencode(scope.runtime / 'control')) > 108
    assert (scope.runtime / 'control').is_socket()
    for command, expected in [('state', 'empty'), ('destroy', 'ok')]:
        result = subprocess.run(
            [sys.executable, HELPER, 'call', str(scope.runtime), scope.nonce, command],
            capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == expected
    assert scope.server.wait(timeout=5) == 0
    assert not scope.path.exists(), 'long runtime left a cgroup behind'


passed = failed = 0
with tempfile.TemporaryDirectory(prefix='repolens-scope-rpc-test.') as temporary:
    cases = [
        ('valid-disconnect', valid_disconnect, {}),
        ('invalid-disconnect', invalid_disconnect, {}),
        ('request-timeout', request_timeout, {}),
        ('terminate-disconnect', terminate_disconnect, {}),
        ('destroy-disconnect', destroy_disconnect, dict(populated=False)),
        ('parent-death-after-disconnect', parent_death, dict(separate_parent=True)),
        ('long-runtime-' + 'x' * 108, long_runtime, dict(populated=False)),
    ]
    for name, test, options in cases:
        scope = None
        try:
            scope = RunningScope(Path(temporary) / name, **options)
            test(scope)
            passed += 1
            print('PASS: ' + name)
        except Exception as error:
            failed += 1
            print('FAIL: {}: {}'.format(name, error))
            print((Path(temporary) / name / 'supervisor.log').read_text())
        finally:
            if scope is not None:
                scope.close()
print('Results: {} passed, {} failed'.format(passed, failed))
sys.exit(bool(failed))
