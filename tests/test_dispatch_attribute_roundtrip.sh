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

# Regression: repolens-r6-p2-3. Each accepted quoted value reaches dispatch intact.
# shellcheck disable=SC2329
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/lib/rounds.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
LENSES_DIR="$REPO/prompts/lenses" MODE=bugreport REPOLENS_META_ORCH_DISPATCH_CAP=8
cat > "$FIXTURE/input" <<'DATA'
LENS: injection role=deeper focus="src/query builder.sh:10" anchor="prior finding 7" exclude="already checked auth"
GENERIC: role=broader focus="related query code" anchor="prior finding 8" exclude="already checked retries"
DATA
_rounds_meta_parse_output "$FIXTURE/input" "$FIXTURE/dispatch" "$FIXTURE/hypotheses"
lens="$(_rounds_meta_dispatch_lens_entries "$FIXTURE/dispatch")"
[[ "$lens" == 'security/injection|deeper|src/query builder.sh:10|prior finding 7|already checked auth' ]]
generic="$(_rounds_meta_dispatch_generic_entries "$FIXTURE/dispatch")"
[[ "$generic" == 'generic/broader-related-query-code|broader|related query code|prior finding 8|already checked retries' ]]
# All supported delimiters may enclose values containing the other quotes.
cat > "$FIXTURE/input" <<'DATA'
LENS: injection role="deep investigation" focus='say "hello" here' anchor=`prior "user's" finding` exclude="already 'checked' auth"
GENERIC: role='wide investigation' focus=`say "it's ready" here` anchor='prior "finding" 8' exclude="already 'checked' retries"
DATA
expected_lens="$(_rounds_meta_dispatch_lens_entries "$FIXTURE/input")"
expected_generic="$(_rounds_meta_dispatch_generic_entries "$FIXTURE/input")"
_rounds_meta_parse_output "$FIXTURE/input" "$FIXTURE/dispatch" "$FIXTURE/hypotheses"
[[ "$(_rounds_meta_dispatch_lens_entries "$FIXTURE/dispatch")" == "$expected_lens" ]]
[[ "$(_rounds_meta_dispatch_generic_entries "$FIXTURE/dispatch")" == "$expected_generic" ]]
echo 'Results: quoted LENS and GENERIC attributes round-trip intact'
