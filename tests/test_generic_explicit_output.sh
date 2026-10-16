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


# repolens-r9-p4-2: explicit local output must deliver Generic findings.
# shellcheck disable=SC2034,SC2329 # Production callbacks consume fixture globals.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/core.sh"
# Reuse the local-only production driver fixture, without its scenario loop.
# shellcheck source=/dev/null
source <(awk '/^for scenario in / {exit} /^REPO=/ {next} {print}' "$REPO/tests/test_generic_long_focus.sh")
unset -f getconf mkdir mv cp mktemp check_component_limits
for lib in ledger local-dedupe human_review artifacts branch-scope; do
  # shellcheck source=/dev/null
  source "$REPO/lib/$lib.sh"
done
set -euo pipefail
optional_local_finalization() {
  # Execute the CLI's real delivery, dedupe, registry and report orchestration.
  # shellcheck source=/dev/null
  source <(sed -n '/^# --- Local-mode deterministic dedupe/,/^unset _local_registry_ready _duplicate_report_ready/p' "$REPO/repolens.sh")
}
LOG_BASE="$FIXTURE/run" OUTPUT_DIR="$FIXTURE/explicit findings" PROJECT_PATH="$FIXTURE/project"
OUTPUT_DIR_SET=true output_name_max=255 log_name_max=255 heartbeat_name_max=255
HEARTBEAT_DIR="$LOG_BASE/.heartbeats" SUMMARY_FILE="$LOG_BASE/summary.json"
completed_lenses_file="$LOG_BASE/.completed"
HUMAN_REVIEW=true REPOLENS_FINAL_STATE=finished ROUNDS=2 STRATEGY=waves
mkdir -p "$LOG_BASE/triage" "$PROJECT_PATH" "$OUTPUT_DIR" "$HEARTBEAT_DIR"
printf 'Check routing\n' > "$LOG_BASE/triage/investigation-seeds.txt"
: > "$completed_lenses_file"
: > "$LOG_BASE/agent-calls"
init_summary "$SUMMARY_FILE" probe "$PROJECT_PATH" bugreport mock '' '' local "$OUTPUT_DIR"
LENSES=(security/injection)
run_rounds 2 LENSES
calls_before="$(wc -l < "$LOG_BASE/agent-calls")"
grep -Fq 'Mock finding.' "$LOG_BASE/rounds/round-1/digest.md"
test "$(find "$LOG_BASE/rounds/round-1/lens-outputs" -name '*.md' -type f | wc -l)" -eq 1
# Explicit output must remain useful even when synthesis returns no clusters.
mkdir -p "$LOG_BASE/final"
printf '[]\n' > "$LOG_BASE/final/manifest.json"
optional_local_finalization
output_count="$(find "$OUTPUT_DIR" -name '*.md' -type f | wc -l)"
registry="$LOG_BASE/final/findings.jsonl"
printf 'GENERIC_DELIVERY explicit_files=%s registry_rows=%s\n' "$output_count" "$(wc -l < "$registry")"
test "$output_count" -eq 1
jq -se 'length == 1 and .[0].domain == "generic" and (.[0].lens | length > 0) and (.[0].title | contains("Mock finding."))' "$registry" >/dev/null
finding="$(jq -r .markdown_path "$registry")"
[[ "$finding" == "$OUTPUT_DIR/"* ]]
test -f "$finding"
grep -Fq 'Mock evidence.' "$finding"
grep -Fq 'Mock finding.' "$LOG_BASE/final/TODO.md"
grep -Fq 'Mock finding.' "$LOG_BASE/final/HUMAN_REVIEW.md"
registry_before="$(cat "$registry")"
run_rounds 2 LENSES
optional_local_finalization
test "$(wc -l < "$LOG_BASE/agent-calls")" -eq "$calls_before"
test "$(cat "$registry")" = "$registry_before"
# A file may carry several findings with the same hypothesis/title. Preserve
# both bodies and distinct registry identities instead of collapsing them.
raw="$(cat "$LOG_BASE/finding-paths")"
second="$(sed 's/Mock evidence\./Independent second-block evidence./' "$raw")"
printf '%s\n' "$second" >> "$raw"
optional_local_finalization
jq -se 'length == 2 and ([.[].id] | unique | length) == 2' "$registry" >/dev/null
while IFS= read -r delivered; do test -f "$delivered"; done < <(jq -r .markdown_path "$registry")
test "$(grep -rl 'Independent second-block evidence.' "$OUTPUT_DIR" --include='*.md' | wc -l)" -eq 1
# A nonempty private manifest is a different representation of raw evidence,
# not another local deliverable. It must not duplicate/hide the delivered files.
jq -n --arg source "$raw" '[{cluster_id:"private",title:"Synthesized duplicate representation",severity:"low",domain:"generic",lens:"broader-check-routing",root_cause_category:"test-gap",source_finding_paths:[$source],cross_link_actions:[],granularity:"independent",verification_status:"verified",body:"Mock evidence.",proposed_labels:[],dedup_against_existing:[]}]' > "$LOG_BASE/final/manifest.json"
optional_local_finalization
jq -se 'length == 2 and all(.title | contains("Mock finding."))' "$registry" >/dev/null

# Distinct dispatches whose canonical slugs coincide and a repeated round own
# separate outputs, even when their titles and citations are identical.
printf 'GENERIC: role=broader focus="Check routing" anchor="first"\nGENERIC: role=broader focus="Check routing" anchor="second"\n' > "$LOG_BASE/extra-dispatch.md"
parsed="$(_rounds_meta_dispatch_generic_entries "$LOG_BASE/extra-dispatch.md")"
mapfile -t EXTRA <<< "$parsed"
CURRENT_ROUND_INDEX=1 CURRENT_ROUND_TOTAL=2
completed_lenses_file="$LOG_BASE/.rounds/round-1.lenses.completed"
for entry in "${EXTRA[@]}"; do run_lens "$entry" || exit 1; done
CURRENT_ROUND_INDEX=2
completed_lenses_file="$LOG_BASE/.rounds/round-2.lenses.completed"
run_lens "${EXTRA[0]}" || exit 1
optional_local_finalization
jq -se 'length == 5 and ([.[].id] | unique | length) == 5' "$registry" >/dev/null
# Private evidence and recursive verifier discovery remain unchanged.
verifier_probe=discovery
run_verifier "$RUN_ID"
test "$(jq length "$LOG_BASE/final/verification.json")" -eq 4

# Refuse a directory symlink without leaking writes outside the chosen root.
# Prior registry/CSV/reports remain byte-identical on failed delivery. Resume
# retries the saved raw evidence after repair, without any new agent work.
receipt_hash="$(sha256sum "$LOG_BASE/.rounds/round-1.lenses.completed" "$LOG_BASE/.rounds/round-2.lenses.completed")"
calls_before="$(wc -l < "$LOG_BASE/agent-calls")"
reports_before="$(sha256sum "$LOG_BASE/final/"{findings.jsonl,findings.csv,TODO.md,SUMMARY.md,NEEDS_REVIEW.md,DUPLICATES.md,HUMAN_REVIEW.md})"
mkdir "$FIXTURE/outside"
mv "$OUTPUT_DIR/generic" "$FIXTURE/saved-generic"
ln -s "$FIXTURE/outside" "$OUTPUT_DIR/generic"
optional_local_finalization 2> "$FIXTURE/delivery-error"
grep -Fq 'Generic delivery incomplete' "$FIXTURE/delivery-error"
test "$(find "$FIXTURE/outside" -type f | wc -l)" -eq 0
test "$(sha256sum "$LOG_BASE/final/"{findings.jsonl,findings.csv,TODO.md,SUMMARY.md,NEEDS_REVIEW.md,DUPLICATES.md,HUMAN_REVIEW.md})" = "$reports_before"
rm "$OUTPUT_DIR/generic"
mv "$FIXTURE/saved-generic" "$OUTPUT_DIR/generic"
optional_local_finalization
test "$(wc -l < "$LOG_BASE/agent-calls")" -eq "$calls_before"
test "$(sha256sum "$LOG_BASE/.rounds/round-1.lenses.completed" "$LOG_BASE/.rounds/round-2.lenses.completed")" = "$receipt_hash"
jq -se 'length == 5' "$registry" >/dev/null
# Exercise publication failures after a real file replacement and after stale
# retirement. Every earlier publication and the receipt must roll back intact.
python3 -B - "$REPO" "$FIXTURE" <<'PYTRANSACTION'
import copy
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("generic_output", Path(sys.argv[1]) / "lib/generic_output.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
fixture = Path(sys.argv[2])
for failure in ("second-file", "receipt-after-update", "receipt-after-retirement", "interrupt-after-update"):
    root = fixture / failure
    root.mkdir()
    receipt = fixture / f"{failure}.json"
    plan = [dict(source="/private/source.md", relative="round-1/lens-outputs/source.md",
                 segment=i, frontmatter="domain: generic\nlens_id: probe\nseverity: low\n",
                 body=f"## evidence\nOriginal evidence {i}\n", title=f"Finding {i}", lens="probe")
            for i in (1, 2)]
    module.publish(plan, root, receipt, "run")
    (root / "user-authored.md").write_text("Preserve this unrelated finding.\n")
    before = {p.relative_to(root): p.read_bytes() for p in root.rglob("*.md")}
    old_receipt = receipt.read_bytes()
    changed = copy.deepcopy(plan)
    for row in changed:
        row["body"] = "## evidence\nChanged evidence\n"
    if failure == "receipt-after-retirement":
        changed = changed[:1]
    real_replace = module.os.replace
    replaced = []
    def fail_once(source, destination):
        destination = Path(destination)
        should_fail = (failure in ("second-file", "interrupt-after-update") and destination.suffix == ".md" and len(replaced) == 1)
        should_fail = should_fail or (failure.startswith("receipt-") and destination == receipt)
        if should_fail and not getattr(fail_once, "failed", False):
            fail_once.failed = True
            if failure == "interrupt-after-update":
                raise KeyboardInterrupt("fixture interrupted publication")
            raise OSError("fixture promotion failure")
        real_replace(source, destination)
        if destination.suffix == ".md":
            replaced.append(destination)
    module.os.replace = fail_once
    try:
        try:
            module.publish(changed, root, receipt, "run")
        except (OSError, KeyboardInterrupt):
            pass
        else:
            raise AssertionError("injected publication failure was ignored")
    finally:
        module.os.replace = real_replace
    assert fail_once.failed
    assert {p.relative_to(root): p.read_bytes() for p in root.rglob("*.md")} == before
    assert receipt.read_bytes() == old_receipt
    assert not list(root.glob(".generic-delivery-*"))
    module.publish(changed, root, receipt, "run")
    assert (root / "user-authored.md").read_text() == "Preserve this unrelated finding.\n"
    assert len(list((root / "generic").rglob("*.md"))) == len(changed)
    print(f"Generic publication rollback/retry passed: {failure}")
PYTRANSACTION
printf 'Generic explicit-output regression passed.\n' 
