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

set -uo pipefail

changed_files="$(cat)"
pr_body="${PR_BODY:-}"

if grep -qiF '[skip changelog]' <<< "$pr_body"; then
  echo "CHANGELOG gate skipped by [skip changelog] marker."
  exit 0
fi

if grep -qx 'CHANGELOG.md' <<< "$changed_files"; then
  echo "CHANGELOG.md was touched."
  exit 0
fi

echo "PR did not touch CHANGELOG.md. Add an [Unreleased] entry or include [skip changelog] in the PR body." >&2
exit 1
