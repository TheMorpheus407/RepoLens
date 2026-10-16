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

# Regression: repolens-r6-p2-4. Field separators cannot collide with literal pipes.
# shellcheck disable=SC2329
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/lib/rounds.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
LENSES_DIR="$REPO/prompts/lenses" MODE=bugreport REPOLENS_META_ORCH_DISPATCH_CAP=8
cat > "$FIXTURE/input" <<'DATA'
LENS: injection role=deeper focus="src/a|src/b" anchor="prior7" exclude="checks"
LENS: injection role=deeper focus="src/a" anchor="src/b|prior7" exclude="checks"
GENERIC: role=broader focus="a|b" anchor="c" exclude="d"
GENERIC: role=broader focus="a" anchor="b|c" exclude="d"
DATA
# Readers must preserve distinct tuples even without the parser staging step.
[[ "$(_rounds_meta_dispatch_lens_entries "$FIXTURE/input" | wc -l)" -eq 2 ]]
[[ "$(_rounds_meta_dispatch_generic_entries "$FIXTURE/input" | wc -l)" -eq 2 ]]
# Duplicate exact tuples remain deduplicated; four distinct requests survive.
cat "$FIXTURE/input" "$FIXTURE/input" > "$FIXTURE/repeated"
_rounds_meta_parse_output "$FIXTURE/repeated" "$FIXTURE/dispatch" "$FIXTURE/hypotheses"
[[ "$(grep -c '^LENS:' "$FIXTURE/dispatch")" -eq 2 ]]
[[ "$(grep -c '^GENERIC:' "$FIXTURE/dispatch")" -eq 2 ]]
[[ "$(_rounds_meta_dispatch_lens_entries "$FIXTURE/dispatch" | wc -l)" -eq 2 ]]
[[ "$(_rounds_meta_dispatch_generic_entries "$FIXTURE/dispatch" | wc -l)" -eq 2 ]]
echo 'Results: distinct pipe-valued requests survive parser and readers'
