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
from pathlib import Path
import signal
import sys
import tempfile

spec = importlib.util.spec_from_file_location("generic_output", Path(sys.argv[1]) / "lib/generic_output.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
scenarios = [sys.argv[2]] if sys.argv[2] else ["new", "update", "retire", "receipt", "ownership-update", "ownership-retire"]
for scenario in scenarios:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "output"
        root.mkdir()
        receipt = Path(temporary) / "receipt.json"
        plan = [dict(source="/private/raw.md", relative="round-1/lens-outputs/probe.md", segment=1,
                     frontmatter="domain: generic\nlens_id: probe\nseverity: high\n",
                     body="## evidence\noriginal evidence\n", title="Finding", lens="probe")]
        if scenario != "new":
            module.publish(plan, root, receipt, "run")
        if scenario.startswith("ownership-"):
            path = next(root.rglob("*.md"))
            original = path.read_text()
            identity = json.loads(receipt.read_text())[str(path.relative_to(root))]
            path.write_text(original.replace(f"generic_source_id: {identity}", "generic_source_id: edited")
                            + f"\nUser example in body:\ngeneric_source_id: {identity}\n")
            before = path.read_bytes()
            old_receipt = receipt.read_bytes()
            try:
                module.publish([] if scenario.endswith("retire") else plan, root, receipt, "run")
            except ValueError:
                pass
            else:
                raise AssertionError("edited frontmatter was accepted as owned")
            assert path.read_bytes() == before
            assert receipt.read_bytes() == old_receipt
        else:
            before = {p.relative_to(root): p.read_bytes() for p in root.rglob("*.md")}
            old_receipt = receipt.read_bytes() if receipt.exists() else None
            changed = copy.deepcopy(plan)
            changed[0]["body"] = "## evidence\nupdated evidence\n"
            if scenario == "receipt":
                changed.append(dict(changed[0], segment=2))
            if scenario == "retire":
                changed = []
            real_replace, real_unlink = module.os.replace, Path.unlink
            fired = []
            def interrupted(signum, frame):
                raise InterruptedError("signal after filesystem mutation")
            old_handler = signal.signal(signal.SIGTERM, interrupted)
            def replace(source, destination):
                real_replace(source, destination)
                if not fired and ((scenario == "receipt" and Path(destination) == receipt)
                                  or (scenario != "receipt" and Path(destination).suffix == ".md")):
                    fired.append(True)
                    signal.raise_signal(signal.SIGTERM)
            def unlink(path, *args, **kwargs):
                real_unlink(path, *args, **kwargs)
                if not fired and scenario == "retire" and path.suffix == ".md":
                    fired.append(True)
                    signal.raise_signal(signal.SIGTERM)
            module.os.replace, Path.unlink = replace, unlink
            try:
                try:
                    module.publish(changed, root, receipt, "run")
                except InterruptedError:
                    pass
                else:
                    raise AssertionError("signal was not injected")
            finally:
                module.os.replace, Path.unlink = real_replace, real_unlink
                signal.signal(signal.SIGTERM, old_handler)
            assert fired
            after = {p.relative_to(root): p.read_bytes() for p in root.rglob("*.md")}
            assert after == before, f"{scenario}: incomplete file rollback"
            assert (receipt.read_bytes() if receipt.exists() else None) == old_receipt, "receipt did not roll back"
            assert not list(root.glob(".generic-delivery-*"))
            module.publish(changed, root, receipt, "run")
        print(f"Generic publication boundary passed: {scenario}")
PYTEST
