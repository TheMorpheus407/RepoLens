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
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
source "$REPO/lib/rounds.sh" || exit 1
FIXTURE="$(mktemp -d)" || exit 1
trap 'rm -rf "$FIXTURE"' EXIT
LENSES_DIR="$REPO/prompts/lenses" MODE=bugreport REPOLENS_META_ORCH_DISPATCH_CAP=8
cat > "$FIXTURE/input" <<'DATA' || exit 1
LENS: injection role=deeper focus="src/query builder.sh:10" anchor="prior finding 7" exclude="already checked auth"
GENERIC: role=broader focus="related query code" anchor="prior finding 8" exclude="already checked retries"
DATA
_rounds_meta_parse_output "$FIXTURE/input" "$FIXTURE/dispatch" "$FIXTURE/hypotheses" || exit 1
lens="$(_rounds_meta_dispatch_lens_entries "$FIXTURE/dispatch")" || exit 1
[[ "$lens" == 'security/injection|deeper|src/query builder.sh:10|prior finding 7|already checked auth' ]] || exit 1
generic="$(_rounds_meta_dispatch_generic_entries "$FIXTURE/dispatch")" || exit 1
[[ "$generic" == 'generic/broader-related-query-code|broader|related query code|prior finding 8|already checked retries' ]] || exit 1
# All supported delimiters may enclose values containing the other quotes.
cat > "$FIXTURE/input" <<'DATA' || exit 1
LENS: injection role="deep investigation" focus='say "hello" here' anchor=`prior "user's" finding` exclude="already 'checked' auth"
GENERIC: role='wide investigation' focus=`say "it's ready" here` anchor='prior "finding" 8' exclude="already 'checked' retries"
DATA
expected_lens="$(_rounds_meta_dispatch_lens_entries "$FIXTURE/input")" || exit 1
expected_generic="$(_rounds_meta_dispatch_generic_entries "$FIXTURE/input")" || exit 1
_rounds_meta_parse_output "$FIXTURE/input" "$FIXTURE/dispatch" "$FIXTURE/hypotheses" || exit 1
[[ "$(_rounds_meta_dispatch_lens_entries "$FIXTURE/dispatch")" == "$expected_lens" ]] || exit 1
[[ "$(_rounds_meta_dispatch_generic_entries "$FIXTURE/dispatch")" == "$expected_generic" ]] || exit 1
echo 'Results: quoted LENS and GENERIC attributes round-trip intact'

# Rationale separators inside every supported quote delimiter are data.
for quote in '"' "'" '`'; do
  printf 'LENS: injection role=deeper focus=%ssrc/a - copy.sh:10%s anchor=%sprior - 7%s exclude=%schecked - auth%s - investigate - now\n' \
    "$quote" "$quote" "$quote" "$quote" "$quote" "$quote" > "$FIXTURE/input" || exit 1
  printf 'GENERIC: role=broader focus=%srelated - code%s anchor=%sprior - 8%s exclude=%schecked - retries%s - investigate - now\n' \
    "$quote" "$quote" "$quote" "$quote" "$quote" "$quote" >> "$FIXTURE/input" || exit 1
  expected_lens='security/injection|deeper|src/a - copy.sh:10|prior - 7|checked - auth'
  expected_generic='generic/broader-related-code|broader|related - code|prior - 8|checked - retries'
  [[ "$(_rounds_meta_dispatch_lens_entries "$FIXTURE/input")" == "$expected_lens" ]] || exit 1
  [[ "$(_rounds_meta_dispatch_generic_entries "$FIXTURE/input")" == "$expected_generic" ]] || exit 1
  _rounds_meta_parse_output "$FIXTURE/input" "$FIXTURE/dispatch" "$FIXTURE/hypotheses" || exit 1
  [[ "$(_rounds_meta_dispatch_lens_entries "$FIXTURE/dispatch")" == "$expected_lens" ]] || exit 1
  [[ "$(_rounds_meta_dispatch_generic_entries "$FIXTURE/dispatch")" == "$expected_generic" ]] || exit 1
done
printf 'Results: quoted rationale separators survive parsing and rereading\n'

# An attribute-looking fragment inside another value cannot supply a key.
cat > "$FIXTURE/input" <<'DATA' || exit 1
LENS: injection role=deeper focus='trace anchor="decoy" here' anchor=real exclude=checked
GENERIC: role=broader focus='trace anchor="decoy" here' anchor=real exclude=checked
DATA
lens="$(_rounds_meta_dispatch_lens_entries "$FIXTURE/input")" || exit 1
[[ "$lens" == 'security/injection|deeper|trace anchor="decoy" here|real|checked' ]] || exit 1
_rounds_meta_parse_output "$FIXTURE/input" "$FIXTURE/dispatch" "$FIXTURE/hypotheses" || exit 1
[[ "$(_rounds_meta_dispatch_lens_entries "$FIXTURE/dispatch")" == "$lens" ]] || exit 1
[[ "$(_rounds_meta_extract_kv anchor 'focus="trace anchor=decoy here" anchor=real')" == real ]] || exit 1
generic="$(_rounds_meta_dispatch_generic_entries "$FIXTURE/dispatch")" || exit 1
[[ "$generic" == 'generic/broader-trace-anchor-decoy-here|broader|trace anchor="decoy" here|real|checked' ]] || exit 1
printf 'Results: quoted attribute contents cannot override sibling fields\n'
