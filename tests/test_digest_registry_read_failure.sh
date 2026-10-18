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

# repolens-r13-p6-5: failed registry reads must preserve the last digest.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/core.sh"
# shellcheck source=/dev/null
source "$REPO/lib/rounds.sh"
FIXTURE="$(mktemp -d)"
trap 'chmod -R u+rwX "$FIXTURE"; rm -rf -- "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/config" "$FIXTURE/round-1/lens-outputs"
cat > "$FIXTURE/config/domains.json" <<'REGISTRY'
{
  "domains": [
    {
      "id": "security",
      "lenses": ["injection"]
    }
  ]
}
REGISTRY
_round_digest_repo_root() { printf '%s\n' "$FIXTURE"; }
printf -- '---\ntitle: Verified security finding\nseverity: high\ndomain: security\nlens_id: injection\nround: 1\nconfidence: high\n---\n## hypothesis\nMissing authorization\n## evidence\nsrc/auth.sh:1\n' > "$FIXTURE/round-1/lens-outputs/injection.md"
build_round_digest "$FIXTURE/round-1" || exit 1
grep -q 'Missing authorization' "$FIXTURE/round-1/digest.md"
original="$(sha256sum < "$FIXTURE/round-1/digest.md")"
audit_reader="$(declare -f _round_digest_audit_domains)"
lens_reader="$(declare -f _round_digest_registered_lenses)"
for failure in permission partial-audit partial-lenses; do
  case "$failure" in
    permission)
      chmod 000 "$FIXTURE/config/domains.json"
      if [[ -r "$FIXTURE/config/domains.json" ]]; then
        # Root can still read chmod-000 files; exercise the reader error contract.
        _round_digest_registered_lenses() { return 74; }
      fi
      ;;
    partial-audit) _round_digest_audit_domains() { printf 'security\n'; return 74; } ;;
    partial-lenses) _round_digest_registered_lenses() { printf 'security/injection\n'; return 74; } ;;
  esac
  rc=0
  build_round_digest "$FIXTURE/round-1" || rc=$?
  printf '%s: digest exit=%s (expected nonzero)\n' "$failure" "$rc"
  test "$rc" -ne 0
  test "$(sha256sum < "$FIXTURE/round-1/digest.md")" = "$original"
  chmod 600 "$FIXTURE/config/domains.json"
  eval "$audit_reader"
  eval "$lens_reader"
  build_round_digest "$FIXTURE/round-1" || exit 1
  test "$(sha256sum < "$FIXTURE/round-1/digest.md")" = "$original"
done
printf 'PASS: unreadable and partial registry reads fail without replacing the digest; repair resumes.\n'
