#!/usr/bin/env bash
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

# Test the real recursion-guard process scan against a tiny runner fixture.
# This exercises orphan detection without recursively running the full suite.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import os
import signal
import subprocess
import shlex
import sys
import tempfile
import time

root = Path(sys.argv[1])
passed = failed = 0


def cleanup_runner(process, release):
    # GNU timeout gives the copied runner a separate process group. Release
    # its barrier and let the guard reap it before removing the fixture.
    release.touch()
    try:
        process.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        # The guard owns a private session; never signal the test's group.
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.communicate(timeout=5)


with tempfile.TemporaryDirectory(prefix='repolens-process-detection.') as temporary:
    fixture = Path(temporary)
    tests = fixture / 'tests'
    tests.mkdir()
    guard = tests / 'test_run_all_recursion_guard.sh'
    guard.symlink_to(root / 'tests/test_run_all_recursion_guard.sh')
    # The guard copies this runner into its own corpus. Keep real discovery,
    # recursion checks and exit reporting, adding only a launch barrier so
    # candidate processes appear after the guard's initial snapshot.
    runner_source = (root / 'tests/run-all.sh').read_text()
    barrier = '''
pwd -P > {working_directory}
printf '%s\\n' "$$" > {runner_pid}
touch {started}
while [[ ! -e {release} ]]; do sleep 0.02; done
'''.format(working_directory=shlex.quote(str(fixture / 'runner-working-directory')),
           runner_pid=shlex.quote(str(fixture / 'runner-pid')),
           started=shlex.quote(str(fixture / 'runner-started')),
           release=shlex.quote(str(fixture / 'runner-release')))
    (tests / 'run-all.sh').write_text(runner_source.replace(
        'cd "$SCRIPT_DIR" || exit 1\n', 'cd "$SCRIPT_DIR" || exit 1\n' + barrier, 1))
    meta = tests / 'test_issue6_test27_fix.sh'
    meta.write_text('''#!/usr/bin/env bash
if [[ "${1:-}" == linger ]]; then read -r ignored; fi
exit 0
''')
    (fixture / 'check').write_text('import time; time.sleep(30)\n')
    other_checkout = fixture / 'other-checkout'
    other_checkout.mkdir()
    (other_checkout / 'check').write_text('import time; time.sleep(30)\n')
    cases = [
        ('cleanup after failure at the launch barrier', None, None, fixture, None),
        ('prompt mentioning runner commands', [sys.executable, '-c', 'import time; time.sleep(30)', 'make check', str(meta)], None, fixture, 0),
        ('make check in the isolated runner corpus', ['make', 'check'], sys.executable, None, 1),
        ('actual meta-test orphan with shell flags', ['bash', '-x', str(meta), 'linger'], None, fixture, 1),
        ('make check in another checkout', ['make', 'check'], sys.executable, other_checkout, 0),
    ]
    for name, argv, executable, candidate_cwd, expected in cases:
        runner = candidate = None
        try:
            for marker in ('runner-started', 'runner-release'):
                (fixture / marker).unlink(missing_ok=True)
            runner = subprocess.Popen(['bash', str(guard)], cwd=fixture,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      text=True, start_new_session=True)
            deadline = time.monotonic() + 10
            while not (fixture / 'runner-started').exists():
                assert runner.poll() is None, 'guard exited before runner started'
                assert time.monotonic() < deadline, 'runner fixture did not start'
                time.sleep(0.02)
            if expected is None:
                child_pid = int((fixture / 'runner-pid').read_text())
                cleanup_runner(runner, fixture / 'runner-release')
                assert not Path('/proc/{}/stat'.format(child_pid)).exists(), \
                    'runner child survived cleanup at the launch barrier'
                passed += 1
                print('PASS: ' + name)
                continue
            if candidate_cwd is None:
                candidate_cwd = Path((fixture / 'runner-working-directory').read_text().strip())
                (candidate_cwd / 'check').write_text('import time; time.sleep(30)\n')
            candidate = subprocess.Popen(argv, executable=executable, cwd=candidate_cwd,
                                         stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
            assert candidate.poll() is None, 'process fixture exited early'
            (fixture / 'runner-release').touch()
            output, _ = runner.communicate(timeout=15)
            assert runner.returncode == expected, output
            if expected:
                assert 'FAIL: run-all.sh left orphan processes running' in output, output
                assert str(candidate.pid) in output, 'actual process was not reported'
            passed += 1
            print('PASS: ' + name)
        except Exception as error:
            failed += 1
            print('FAIL: {}: {}'.format(name, error))
        finally:
            # Release a failed fixture even when its cleanup assertion fails.
            (fixture / 'runner-release').touch()
            # Popen retains each direct child's identity until wait reaps it.
            if candidate is not None:
                if candidate.poll() is None:
                    candidate.kill()
                candidate.wait(timeout=5)
            if runner is not None:
                cleanup_runner(runner, fixture / 'runner-release')
            if candidate is not None:
                candidate.stdin.close()
print('Results: {} passed, {} failed'.format(passed, failed))
sys.exit(bool(failed))
PY
