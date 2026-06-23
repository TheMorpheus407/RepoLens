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

# RepoLens — Risk ranking
# Shared per-finding risk score used by the human-triage artifacts (SUMMARY
# Top-N, TODO / NEEDS_REVIEW / DUPLICATES generators, --human-review). Sourced,
# never executed directly. Pure: function-only, no top-level side effects, no
# global mutation, safe under `set -uo pipefail`.
#
# DEPENDENCY: reuses severity_rank / severity_normalize from lib/core.sh — do
# NOT reimplement severity handling. Callers must `source lib/core.sh` before
# this file.
set -uo pipefail

# _risk_confidence_normalize <confidence>
#   Resolves a raw confidence input to a numeric weight in [0, 1].
#     - numeric in [0,1]          -> the value, verbatim
#     - numeric < 0               -> clamped to 0
#     - numeric > 1               -> clamped to 1
#     - authoring aliases         -> low=0.33, medium=0.66, high=1.0
#     - missing / empty / invalid -> the documented default (0.5)
#   The 0.5 default is a neutral midpoint: today `confidence` is `null` for
#   every registry record (lib/ledger.sh), so unscored findings must not be
#   buried (default 0.0) — a critical-but-unscored finding scoring 1.5 sits
#   sensibly between high-certain (2.0) and medium-certain (1.0).
#   Pure; prints one line; never errors.
_risk_confidence_normalize() {
  local conf="${1:-}"

  # Trim leading/trailing whitespace.
  conf="${conf#"${conf%%[![:space:]]*}"}"
  conf="${conf%"${conf##*[![:space:]]}"}"

  case "${conf,,}" in
    low) printf '0.33\n'; return 0 ;;
    medium) printf '0.66\n'; return 0 ;;
    high) printf '1.0\n'; return 0 ;;
  esac

  # Accept plain decimals only (e.g. 1, 0.5, .5, -0.3). Scientific notation,
  # NaN, bare signs and other junk fall through to the default.
  if [[ "$conf" =~ ^-?[0-9]+(\.[0-9]+)?$ || "$conf" =~ ^-?\.[0-9]+$ ]]; then
    LC_ALL=C awk -v c="$conf" 'BEGIN {
      if (c < 0) c = 0; else if (c > 1) c = 1
      printf "%s\n", c
    }'
    return 0
  fi

  printf '0.5\n'
}

# finding_risk_score <severity> <confidence>
#   Prints risk = severity_rank(severity) x confidence as a fixed-precision
#   float (%.4f) on one line. Higher means triage sooner; order with
#   `sort -rn` (descending) or `sort -g`.
#
#   severity:   critical|high|medium|low (any case, optional [..] wrapper —
#               normalized via severity_normalize/severity_rank). Invalid or
#               missing severity -> rank 0 -> score 0.0000 (never crashes).
#   confidence: float in [0,1] (clamped), the aliases low|medium|high, or
#               missing/invalid -> default 0.5. See _risk_confidence_normalize.
#
#   NOTE: severity_rank is 0-based (low=0), so risk(low, c) == 0.0000 for every
#   confidence — confidence cannot order findings within the `low` band.
#
#   Pure: no side effects, no globals, safe under `set -u`. Always returns 0.
finding_risk_score() {
  local severity="${1:-}" confidence="${2:-}" rank conf

  rank="$(severity_rank "$severity")" || rank=0
  conf="$(_risk_confidence_normalize "$confidence")"

  LC_ALL=C awk -v r="$rank" -v c="$conf" 'BEGIN { printf "%.4f\n", r * c }'
}
