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


# Catchable preparation failures clean private copies before returning. Failed
# cleanup retains the exact recovery pointer and never sweeps another run.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "$REPO" "${1:-}" <<'PYTEST'
import copy
import errno
import importlib.util
import json
from pathlib import Path
import signal
import sys
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("generic_output", Path(sys.argv[1]) / "lib/generic_output.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def projections(root):
    """Snapshot public files without including transaction backups."""
    return {p.relative_to(root): p.read_bytes() for p in (root / "generic").rglob("*.md")}

def case_error(scenario):
    """Catchable preparation faults must release copied content immediately."""
    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary)
        root = base / "output"
        root.mkdir()
        receipt = base / "receipt.json"
        pending = receipt.with_suffix(".json.pending")
        old = [dict(source="/private/raw.md", relative="round-1/lens-outputs/probe.md", segment=1,
                    frontmatter="domain: generic\nlens_id: probe\nseverity: high\n",
                    body="Original evidence\n" * 1000, title="Finding", lens="probe")]
        module.publish(old, root, receipt, "run")
        before_files, before_receipt = projections(root), receipt.read_bytes()
        plan = copy.deepcopy(old)
        plan[0]["body"] = "Updated evidence\n" * 1000
        plan.append(dict(plan[0], segment=2))
        foreign = root / ".generic-delivery-foreign"
        foreign.mkdir()
        (foreign / "sentinel").write_text("another transaction\n")
        fault = OSError(errno.ENOSPC, "injected preparation failure")
        fired = []
        real_copy, real_write = module.shutil.copy2, Path.write_text
        real_rmtree = module.shutil.rmtree
        cleanup_attempts = []
        real_dump, real_pending = module.json.dump, module._write_pending

        def fail():
            fired.append(True)
            if scenario.endswith("-signal"):
                signal.raise_signal(signal.SIGTERM)
            raise fault

        def copy2(source, destination, *args, **kwargs):
            result = real_copy(source, destination, *args, **kwargs)
            name = Path(destination).name
            if ((scenario in ("backup", "cleanup-error") and name.startswith("backup-"))
                    or (scenario == "receipt-backup" and name == "receipt-before")):
                fail()
            return result

        def write_text(path, *args, **kwargs):
            result = real_write(path, *args, **kwargs)
            if scenario == "new" and path.name.startswith("new-"):
                fail()
            return result

        def dump(value, stream, *args, **kwargs):
            if scenario == "receipt-write" and "phase" not in value:
                stream.write("{partial receipt")
                fail()
            return real_dump(value, stream, *args, **kwargs)

        def write_pending(path, journal):
            phase = journal["phase"]
            if scenario == "rollback-intent" and phase == "rollback":
                fail()
            real_pending(path, journal)
            if ((scenario == "preparing-signal" and phase == "preparing")
                    or (scenario == "rollback-signal" and phase == "rollback")):
                fail()

        def rmtree(path, *args, **kwargs):
            cleanup_attempts.append(Path(path))
            if scenario == "cleanup-error":
                raise OSError("cleanup unavailable")
            return real_rmtree(path, *args, **kwargs)

        def interrupted(_signum, _frame):
            raise fault

        handler = signal.signal(signal.SIGTERM, interrupted)
        try:
            with patch.object(module.shutil, "copy2", copy2), patch.object(Path, "write_text", write_text), \
                    patch.object(module.json, "dump", dump), patch.object(module, "_write_pending", write_pending), \
                    patch.object(module.shutil, "rmtree", rmtree):
                try:
                    module.publish(plan, root, receipt, "run")
                except OSError as error:
                    assert error is fault, f"original failure replaced: {error}"
                else:
                    raise AssertionError("preparation failure was swallowed")
        finally:
            signal.signal(signal.SIGTERM, handler)
        assert fired == [True], "fault injection must fire exactly once"
        assert len(cleanup_attempts) == 1, "preparation did not attempt immediate cleanup"
        assert projections(root) == before_files, "preparation changed public files"
        assert receipt.read_bytes() == before_receipt, "preparation changed public receipt"
        if scenario == "cleanup-error":
            assert pending.exists(), "failed cleanup lost its recovery pointer"
            journal = json.loads(pending.read_text())
            assert journal["phase"] == "preparing"
            assert list(Path(journal["stage"]).glob("backup-*")), "failed cleanup lost owned backups"
            module._recover_pending(root, receipt, pending, "run")
        assert not pending.exists(), "catchable failure retained its pending journal"
        assert set(root.glob(".generic-delivery-*")) == {foreign}, "catchable failure retained finding copies"
        assert not list(base.glob(".generic-receipt-*")), "catchable failure retained receipt staging"
        assert not list(base.glob(".generic-intent-*")), "catchable failure retained intent staging"
        assert (foreign / "sentinel").read_text() == "another transaction\n"
        module.publish(plan, root, receipt, "run")
        assert len(projections(root)) == 2
        assert all(data.endswith(plan[0]["body"].encode()) for data in projections(root).values())
        assert set(root.glob(".generic-delivery-*")) == {foreign}
        assert not pending.exists()
        print(f"PASS: Generic preparation error {scenario}")

scenarios = [sys.argv[2]] if sys.argv[2] else [
    "backup", "new", "receipt-write", "receipt-backup", "rollback-intent",
    "preparing-signal", "rollback-signal", "cleanup-error"]
failures = 0
for scenario in scenarios:
    try:
        case_error(scenario)
    except AssertionError as error:
        failures += 1
        print(f"FAIL: {scenario}: {error}")
print(f"Generic preparation errors: {failures} failures")
sys.exit(bool(failures))
PYTEST
