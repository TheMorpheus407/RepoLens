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


# Crash recovery must retain the exact cleanup pointer until owned backups are
# removed, including after a completed rollback. Never sweep other runs' stages.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "$REPO" <<'PYTEST'
import copy
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile

spec = importlib.util.spec_from_file_location("generic_output", Path(sys.argv[1]) / "lib/generic_output.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def projections(root):
    """Capture public bytes without counting private backups or another stage."""
    return {p.relative_to(root): p.read_bytes() for p in (root / "generic").rglob("*.md")}

def case_cleanup(scenario):
    """Kill an owned child at a precise terminal-journal/cleanup boundary."""
    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary)
        root = base / "output"
        root.mkdir()
        receipt = base / "receipt.json"
        pending = base / "receipt.json.pending"
        old = [dict(source="/private/raw.md", relative="round-1/lens-outputs/probe.md", segment=i,
                    frontmatter="domain: generic\nlens_id: probe\nseverity: high\n",
                    body="Original evidence\n" * 1000, title="Finding", lens="probe") for i in (1, 2)]
        module.publish(old, root, receipt, "run")
        before_files, before_receipt = projections(root), receipt.read_bytes()
        plan = copy.deepcopy(old)
        for row in plan:
            row["body"] = "Updated evidence\n" * 1000
        plan.append(dict(plan[0], segment=3))
        foreign = root / ".generic-delivery-foreign"
        foreign.mkdir()
        (foreign / "sentinel").write_text("another transaction\n")
        pid = os.fork()
        if pid == 0:
            real_unlink, real_rmtree, real_replace = Path.unlink, module.shutil.rmtree, module.os.replace
            def unlink(path, *args, **kwargs):
                """Terminate just after the pending record is actually removed."""
                result = real_unlink(path, *args, **kwargs)
                if scenario == "after-pending-unlink" and path == pending:
                    os.kill(os.getpid(), signal.SIGKILL)
                return result
            def rmtree(path, *args, **kwargs):
                """Terminate before cleanup or after deleting one owned backup."""
                path = Path(path)
                if path.parent == root and path.name.startswith(".generic-delivery-"):
                    if scenario in ("partial-cleanup", "rollback-cleanup"):
                        backup = next(path.glob("backup-*"))
                        real_unlink(backup)
                    if scenario == "after-stage-removal":
                        real_rmtree(path, *args, **kwargs)
                    if scenario != "after-pending-unlink":
                        os.kill(os.getpid(), signal.SIGKILL)
                return real_rmtree(path, *args, **kwargs)
            def replace(source, destination):
                """Start a real rollback after one successful public mutation."""
                result = real_replace(source, destination)
                if Path(source).name.startswith("new-"):
                    if scenario == "rollback-cleanup":
                        raise OSError("fixture publication failure")
                    if scenario == "legacy-intent":
                        os.kill(os.getpid(), signal.SIGKILL)
                return result
            Path.unlink, module.shutil.rmtree, module.os.replace = unlink, rmtree, replace
            try:
                module.publish(plan, root, receipt, "run")
            except BaseException as error:
                print(f"Unexpected child outcome: {error}", file=sys.stderr, flush=True)
                os._exit(2)
            os._exit(0)
        _, status = os.waitpid(pid, 0)
        assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGKILL, status
        interrupted_files, interrupted_receipt = projections(root), receipt.read_bytes()
        if scenario == "legacy-intent":
            # Existing runs have intent records without a phase field.
            journal = json.loads(pending.read_text())
            journal.pop("phase", None)
            pending.write_text(json.dumps(journal))
            module._recover_pending(root, receipt, pending, "run")
            assert projections(root) == before_files and receipt.read_bytes() == before_receipt
            assert not pending.exists() and set(root.glob(".generic-delivery-*")) == {foreign}
            module.publish(plan, root, receipt, "run")
            assert len(projections(root)) == 3
            print("PASS: Generic cleanup recovery legacy-intent")
            return
        if scenario == "rollback-cleanup":
            assert interrupted_files == before_files, "rollback did not restore original files"
            assert interrupted_receipt == before_receipt, "rollback did not restore receipt"
        else:
            assert len(interrupted_files) == 3, "publication did not finish before cleanup"
            assert len(json.loads(interrupted_receipt)) == 3, "receipt did not commit new plan"
            assert all(data.endswith(plan[0]["body"].encode()) for data in interrupted_files.values())
        if scenario != "after-pending-unlink":
            assert pending.exists(), "cleanup lost its pending journal"
            assert json.loads(pending.read_text()).get("phase") == "cleanup", "cleanup lacks terminal phase"
        if scenario == "after-stage-removal":
            assert not Path(json.loads(pending.read_text())["stage"]).exists(), "stage deletion did not complete"
        if scenario == "edited-after-commit":
            # Terminal cleanup does not need the old public hashes or backups.
            # Keep edits to both a projection and the receipt byte-for-byte.
            target = next((root / "generic").rglob("*.md"))
            target.write_bytes(target.read_bytes() + b"User edit after commit\n")
            receipt.write_bytes(receipt.read_bytes() + b"\n")
            interrupted_files, interrupted_receipt = projections(root), receipt.read_bytes()
        if scenario.startswith("guard-"):
            journal = json.loads(pending.read_text())
            invalid = dict(journal)
            obstruction = None
            if scenario == "guard-run":
                invalid["run_id"] = "another-run"
            elif scenario == "guard-root":
                invalid["root"] = str(base / "another-output")
            elif scenario == "guard-phase":
                invalid["phase"] = "unknown"
            elif scenario == "guard-stage":
                obstruction = root / ".generic-delivery-linked"
                obstruction.symlink_to(foreign, target_is_directory=True)
                invalid["stage"] = str(obstruction)
            elif scenario == "guard-receipt-stage":
                obstruction = base / ".generic-receipt-linked"
                obstruction.symlink_to(foreign / "sentinel")
                invalid["receipt_stage"] = str(obstruction)
            pending.write_text(json.dumps(invalid))
            try:
                module._recover_pending(root, receipt, pending, "run")
            except ValueError:
                pass
            else:
                raise AssertionError("unsafe cleanup record accepted")
            assert projections(root) == interrupted_files and receipt.read_bytes() == interrupted_receipt
            assert pending.exists() and Path(journal["stage"]).is_dir()
            assert (foreign / "sentinel").read_text() == "another transaction\n"
            if obstruction is not None:
                obstruction.unlink()
            pending.write_text(json.dumps(journal))
        # Recover directly first: cleanup must preserve the already committed or
        # restored publications, even when one rollback backup was deleted.
        module._recover_pending(root, receipt, pending, "run")
        assert projections(root) == interrupted_files, "cleanup replay changed public files"
        assert receipt.read_bytes() == interrupted_receipt, "cleanup replay changed receipt"
        assert not pending.exists(), "cleanup journal not retired"
        assert set(root.glob(".generic-delivery-*")) == {foreign}, "orphaned owned backups"
        assert not list(base.glob(".generic-receipt-*")), "orphaned receipt staging"
        assert (foreign / "sentinel").read_text() == "another transaction\n"
        module.publish(plan, root, receipt, "run")
        published, published_receipt = projections(root), receipt.read_bytes()
        assert len(published) == 3 and len(json.loads(published_receipt)) == 3
        module.publish(plan, root, receipt, "run")
        assert projections(root) == published and receipt.read_bytes() == published_receipt
        assert set(root.glob(".generic-delivery-*")) == {foreign}, "retry retained backups"
        assert (foreign / "sentinel").read_text() == "another transaction\n"
        print(f"PASS: Generic cleanup recovery {scenario}")

failures = 0
for scenario in ("after-pending-unlink", "before-cleanup", "partial-cleanup", "rollback-cleanup",
                 "after-stage-removal", "edited-after-commit",
                 "legacy-intent", "guard-run", "guard-root", "guard-phase", "guard-stage", "guard-receipt-stage"):
    try:
        case_cleanup(scenario)
    except AssertionError as error:
        failures += 1
        print(f"FAIL: {scenario}: {error}")
print(f"Generic cleanup recovery: {failures} failures")
sys.exit(bool(failures))
PYTEST
