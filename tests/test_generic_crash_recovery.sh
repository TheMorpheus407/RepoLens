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


set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "$REPO" "${1:-}" <<'PYTEST'
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
scenarios = [sys.argv[2]] if sys.argv[2] else [
    "new", "added", "update", "retire", "before-receipt", "after-receipt",
    "new-after-receipt", "changed-plan", "edited", "symlink", "unowned", "recovery-kill", "wrong-run", "wrong-output"]
for scenario in scenarios:
    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary)
        root = base / "output"
        root.mkdir()
        receipt = base / "receipt.json"
        plan = [dict(source="/private/raw.md", relative="round-1/lens-outputs/probe.md", segment=1,
                     frontmatter="domain: generic\nlens_id: probe\nseverity: high\n",
                     body="## evidence\noriginal evidence\n", title="Finding", lens="probe")]
        original = copy.deepcopy(plan)
        if scenario in ("added", "update", "retire", "before-receipt", "after-receipt", "recovery-kill"):
            module.publish(plan, root, receipt, "run")
            plan[0]["body"] = "## evidence\nupdated evidence\n"
        if scenario in ("added", "before-receipt", "after-receipt"):
            plan.append(dict(plan[0], segment=2))
        if scenario == "retire":
            plan = []
        (root / "user.md").write_text("unrelated user content\n")
        old_receipt = receipt.read_bytes() if receipt.exists() else None
        old_files = {p.relative_to(root): p.read_bytes() for p in root.rglob("*.md")}

        def kill_publisher(recovering=False):
            pid = os.fork()
            if pid == 0:
                real_replace, real_unlink = module.os.replace, Path.unlink
                def replace(source, destination):
                    destination = Path(destination)
                    if scenario == "before-receipt" and destination == receipt:
                        os.kill(os.getpid(), signal.SIGKILL)
                    real_replace(source, destination)
                    at_receipt = scenario in ("after-receipt", "new-after-receipt") and destination == receipt
                    at_file = destination.suffix == ".md" and scenario not in ("before-receipt", "after-receipt", "new-after-receipt", "retire")
                    if scenario == "added":
                        at_file = destination.name == "002.md"
                    if at_receipt or at_file:
                        os.kill(os.getpid(), signal.SIGKILL)
                def unlink(path, *args, **kwargs):
                    real_unlink(path, *args, **kwargs)
                    if scenario == "retire" and path.suffix == ".md":
                        os.kill(os.getpid(), signal.SIGKILL)
                module.os.replace, Path.unlink = replace, unlink
                try:
                    module.publish(original if recovering else plan, root, receipt, "run")
                except BaseException as error:
                    print(f"child publisher failed: {error}", file=sys.stderr, flush=True)
                    os._exit(2)
                os._exit(0)
            _, status = os.waitpid(pid, 0)
            assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGKILL, status

        kill_publisher()
        if scenario in ("edited", "symlink"):
            target = next((root / "generic").rglob("*.md"))
            if scenario == "edited":
                # Retaining the correct embedded marker is insufficient proof.
                target.write_text(target.read_text() + "user edit after crash\n")
            else:
                outside = base / "outside.md"
                outside.write_text("outside content\n")
                target.unlink()
                target.symlink_to(outside)
        elif scenario == "unowned":
            # A future planned path with matching content/marker was never reserved.
            target = next((root / "generic").rglob("*.md"))
            unknown = target.with_name("002.md")
            unknown.write_text(target.read_text())
            plan.append(dict(plan[0], segment=2))
        elif scenario == "changed-plan":
            plan = []
        elif scenario == "recovery-kill":
            # Die while restoring an updated projection, then recover once more.
            kill_publisher(recovering=True)
            plan = original

        before_retry = {p.relative_to(root): p.read_bytes() for p in root.rglob("*.md")}
        retry_receipt = receipt.read_bytes() if receipt.exists() else None
        if scenario in ("edited", "symlink", "unowned", "wrong-run", "wrong-output"):
            destination = root
            if scenario == "wrong-output":
                destination = base / "different-output"
                destination.mkdir()
            try:
                module.publish(plan, destination, receipt, "different-run" if scenario == "wrong-run" else "run")
            except ValueError:
                pass
            else:
                raise AssertionError(f"{scenario}: unsafe crash recovery accepted")
            if scenario == "unowned":
                assert unknown.read_bytes() == before_retry[unknown.relative_to(root)]
            else:
                assert {p.relative_to(root): p.read_bytes() for p in root.rglob("*.md")} == before_retry
            assert (receipt.read_bytes() if receipt.exists() else None) == retry_receipt
            if scenario == "symlink":
                assert outside.read_text() == "outside content\n"
            print(f"Generic crash recovery protected: {scenario}")
            continue

        module.publish(plan, root, receipt, "run")
        files = list((root / "generic").rglob("*.md"))
        assert len(files) == len(plan), f"{scenario}: incorrect projection count"
        assert len(json.loads(receipt.read_text())) == len(plan)
        for row in plan:
            delivered = next(p for p in files if p.name == f"{row['segment']:03d}.md")
            assert delivered.read_text().endswith(row["body"])
        assert (root / "user.md").read_text() == "unrelated user content\n"
        assert not list(root.glob(".generic-delivery-*")), "stale crash backups"
        assert not list(base.glob(".generic-receipt-*")), "stale receipt staging"
        before_repeat = {p.relative_to(root): p.read_bytes() for p in root.rglob("*.md")}
        receipt_repeat = receipt.read_bytes()
        module.publish(plan, root, receipt, "run")
        assert {p.relative_to(root): p.read_bytes() for p in root.rglob("*.md")} == before_repeat
        assert receipt.read_bytes() == receipt_repeat
        if scenario == "recovery-kill":
            assert before_repeat == old_files
            assert receipt_repeat == old_receipt
        print(f"Generic crash recovery passed: {scenario}")
PYTEST
