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

# Behavioral tests for issues #271 and #272: every RepoLens-owned remote SSH lifecycle
# operation must stay non-interactive and must carry the shared parsed SSH
# options across preflight, ControlMaster open/check, reconnect, and close.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/remote-lifecycle-batchmode.XXXXXX")"
CREATED_LOG_DIRS=()

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
_cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMPROOT" 2>/dev/null || true
  local d
  for d in "${CREATED_LOG_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap _cleanup EXIT

record_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected '$expected', got '$actual')"
  fi
}

assert_nonzero() {
  local desc="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected non-zero rc, got 0)"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle' in: ${haystack:0:260})"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (unexpected '$needle' present in: ${haystack:0:260})"
  fi
}

assert_lt() {
  local desc="$1" left="$2" right="$3"
  if [[ "$left" =~ ^[0-9]+$ && "$right" =~ ^[0-9]+$ && "$left" -lt "$right" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected $left < $right)"
  fi
}

assert_order() {
  local desc="$1" first="$2" second="$3"
  if [[ "$first" =~ ^[0-9]+$ && "$second" =~ ^[0-9]+$ && "$first" -lt "$second" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected line ${first:-missing} before ${second:-missing})"
  fi
}

parse_run_id() {
  local log_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null | head -1 | awk '{print $3}'
}

record_run_id() {
  local log_file="$1" run_id
  run_id="$(parse_run_id "$log_file")"
  if [[ -n "${run_id:-}" ]]; then
    CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi
}

ssh_class_count() {
  local transcript="$1" class="$2"
  grep -F -c $'SSH_CALL\t'"$class"$'\t' "$transcript" 2>/dev/null || true
}

agent_count() {
  local transcript="$1"
  grep -F -c $'AGENT_CALL\t' "$transcript" 2>/dev/null || true
}

nth_line_for_class() {
  local transcript="$1" class="$2" nth="$3"
  awk -v class="$class" -v nth="$nth" '
    $0 ~ ("^SSH_CALL\t" class "\t") {
      count += 1
      if (count == nth) {
        print NR
        exit
      }
    }
  ' "$transcript" 2>/dev/null
}

first_agent_line() {
  local transcript="$1"
  awk '$0 ~ /^AGENT_CALL\t/ { print NR; exit }' "$transcript" 2>/dev/null
}

class_lines() {
  local transcript="$1" class="$2"
  grep -F $'SSH_CALL\t'"$class"$'\t' "$transcript" 2>/dev/null || true
}

batchmode_violation_count() {
  local violations="$1" class="$2"
  grep -F -c $'missing-batchmode\t'"$class"$'\t' "$violations" 2>/dev/null || true
}

assert_class_count_at_least() {
  local desc="$1" transcript="$2" class="$3" minimum="$4"
  local count
  count="$(ssh_class_count "$transcript" "$class")"
  if [[ "$count" =~ ^[0-9]+$ && "$count" -ge "$minimum" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected at least $minimum '$class' calls, got $count)"
  fi
}

assert_all_class_lines_contain() {
  local desc="$1" transcript="$2" class="$3" needle="$4"
  local lines missing=0
  lines="$(class_lines "$transcript" "$class")"
  if [[ -z "$lines" ]]; then
    record_fail "$desc (no '$class' calls recorded)"
    return
  fi
  while IFS= read -r line; do
    [[ "$line" == *"$needle"* ]] || missing=$((missing + 1))
  done <<< "$lines"
  if [[ "$missing" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc ($missing '$class' call(s) missing '$needle')"
  fi
}

transcript_field() {
  local transcript="$1" prefix="$2" field="$3"
  awk -F '\t' -v prefix="$prefix" -v field="$field" '
    $1 == prefix {
      for (i = 2; i <= NF; i++) {
        if ($i ~ ("^" field "=")) {
          sub(("^" field "="), "", $i)
          print $i
          exit
        }
      }
    }
  ' "$transcript" 2>/dev/null
}

setup_fake_tools() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
if [[ -n "${FAKE_SSH_TRANSCRIPT:-}" ]]; then
  printf 'AGENT_CALL\tREPOLENS_REMOTE_SSH_SOCKET=%s\tREPOLENS_REMOTE_TARGET=%s\tREPOLENS_REMOTE_LABEL=%s\n' \
    "${REPOLENS_REMOTE_SSH_SOCKET:-}" \
    "${REPOLENS_REMOTE_TARGET:-}" \
    "${REPOLENS_REMOTE_LABEL:-}" >> "$FAKE_SSH_TRANSCRIPT"
fi
printf '%s\n' "Analysis complete. No findings."
printf '%s\n' "DONE"
exit 0
SH
  chmod +x "$bin_dir/codex"

  cat > "$bin_dir/ssh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

transcript="${FAKE_SSH_TRANSCRIPT:-}"
state_dir="${FAKE_SSH_STATE_DIR:-}"
scenario="${FAKE_SSH_SCENARIO:-normal}"
batchmode_violations="${FAKE_SSH_BATCHMODE_VIOLATIONS:-}"
mkdir -p "$state_dir"

class="unknown"
operation=""
socket_path=""
control_path=""
has_master=0
has_fN=0
has_f=0
has_N=0
has_preflight=0
has_control_master_auto=0
has_batchmode=0
prev=""

for arg in "$@"; do
  if [[ "$prev" == "-O" ]]; then
    operation="$arg"
  elif [[ "$prev" == "-S" ]]; then
    socket_path="$arg"
  elif [[ "$prev" == "-o" ]]; then
    case "$arg" in
      BatchMode=yes) has_batchmode=1 ;;
      ControlMaster=auto) has_control_master_auto=1 ;;
      ControlPath=*) control_path="${arg#ControlPath=}" ;;
    esac
  fi
  case "$arg" in
    -oBatchMode=yes) has_batchmode=1 ;;
    -M) has_master=1 ;;
    -fN) has_fN=1 ;;
    -f) has_f=1 ;;
    -N) has_N=1 ;;
    "hostname && uname -a") has_preflight=1 ;;
  esac
  prev="$arg"
done

if [[ "$has_preflight" -eq 1 ]]; then
  class="preflight"
elif [[ "$operation" == "check" ]]; then
  class="check"
elif [[ "$operation" == "exit" ]]; then
  class="close"
elif [[ "$has_master" -eq 1 && ( "$has_fN" -eq 1 || ( "$has_f" -eq 1 && "$has_N" -eq 1 ) ) ]]; then
  class="open"
fi

call_count_file="$state_dir/call-count"
call_count="$(cat "$call_count_file" 2>/dev/null || printf '0')"
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$call_count_file"

check_index=""
if [[ "$class" == "check" ]]; then
  check_count_file="$state_dir/check-count"
  check_index="$(cat "$check_count_file" 2>/dev/null || printf '0')"
  check_index=$((check_index + 1))
  printf '%s\n' "$check_index" > "$check_count_file"
fi

if [[ -n "$transcript" ]]; then
  {
    printf 'SSH_CALL\t%s\tcall=%s' "$class" "$call_count"
    [[ -n "$check_index" ]] && printf '\tcheck=%s' "$check_index"
    for arg in "$@"; do
      printf '\t%s' "$arg"
    done
    printf '\n'
  } >> "$transcript"
fi

case "$class" in
  preflight|open|check|close)
    if [[ "$has_batchmode" -ne 1 ]]; then
      if [[ -n "$batchmode_violations" ]]; then
        {
          printf 'missing-batchmode\t%s\tcall=%s' "$class" "$call_count"
          [[ -n "$check_index" ]] && printf '\tcheck=%s' "$check_index"
          printf '\n'
        } >> "$batchmode_violations"
      fi
      printf '%s\n' "fake ssh: $class missing -o BatchMode=yes" >&2
      exit 64
    fi
    ;;
esac

if [[ "$class" == "preflight" && "$has_control_master_auto" -eq 1 && -n "$control_path" ]]; then
  mkdir -p "$(dirname "$control_path")"
  : > "$control_path"
fi

if [[ "$class" == "open" && -n "$socket_path" && -e "$socket_path" ]]; then
  printf '%s\n' "simulated ControlMaster socket conflict" >&2
  exit 255
fi

if [[ "$class" == "open" && -n "$socket_path" ]]; then
  mkdir -p "$(dirname "$socket_path")"
  : > "$socket_path"
fi

if [[ "$class" == "preflight" ]]; then
  printf '%s\n' "remote-preflight-host"
  printf '%s\n' "Linux remote-preflight 6.1.0-test #1 SMP"
fi

if [[ "$scenario" == "lifecycle-close-fails" && "$class" == "close" ]]; then
  printf '%s\n' "simulated close failure" >&2
  exit 99
fi

if [[ "$scenario" == "post-open-check-fails" && "$class" == "check" && "$check_index" == "1" ]]; then
  printf '%s\n' "simulated post-open ControlMaster check failure" >&2
  [[ -n "$socket_path" ]] && rm -f -- "$socket_path"
  exit 255
fi

if [[ "$scenario" == "reconnect-once" && "$class" == "check" && "$check_index" == "2" ]]; then
  printf '%s\n' "simulated lost ControlMaster" >&2
  [[ -n "$socket_path" ]] && rm -f -- "$socket_path"
  exit 255
fi

if [[ "$scenario" == "abort-second-loss" && "$class" == "check" \
      && ( "$check_index" == "2" || "$check_index" == "4" ) ]]; then
  printf '%s\n' "simulated repeated ControlMaster loss" >&2
  [[ -n "$socket_path" ]] && rm -f -- "$socket_path"
  exit 255
fi

exit 0
SH
  chmod +x "$bin_dir/ssh"
}

run_repolens_remote() {
  local project="$1" run_log="$2" transcript="$3" scenario="$4"
  shift 4

  : > "$transcript"
  rm -rf "$TMPDIR/fake-ssh-state"
  mkdir -p "$TMPDIR/fake-ssh-state"

  set +e
  PATH="$FAKE_BIN:$PATH" \
  FAKE_SSH_TRANSCRIPT="$transcript" \
  FAKE_SSH_STATE_DIR="$TMPDIR/fake-ssh-state" \
  FAKE_SSH_SCENARIO="$scenario" \
    bash "$REPOLENS" \
      --project "$project" \
      --agent codex \
      --mode deploy \
      --deploy-target server \
      --local \
      --yes \
      "$@" \
      > "$run_log" 2>&1
  local rc=$?
  set +e
  record_run_id "$run_log"
  return "$rc"
}

echo ""
echo "=== Test Suite: remote SSH lifecycle BatchMode (issues #271/#272) ==="
echo ""

FAKE_BIN="$TMPDIR/bin"
setup_fake_tools "$FAKE_BIN"

PROJECT="$TMPDIR/server-project"
mkdir -p "$PROJECT"
printf '%s\n' "# server deploy target" > "$PROJECT/README.md"

REMOTE_KEY="$TMPDIR/remote key with spaces"
printf '%s\n' "fake private key" > "$REMOTE_KEY"

DEPLOYMENT_LENS_COUNT="$(jq -r '.domains[] | select(.id=="deployment") | .lenses[]' "$SCRIPT_DIR/config/domains.json" | wc -l | tr -d ' ')"

run_fake_ssh_missing_batchmode() {
  local desc="$1" output_file="$2"
  shift 2

  PATH="$FAKE_BIN:$PATH" \
  FAKE_SSH_TRANSCRIPT="$MISSING_BATCHMODE_TRANSCRIPT" \
  FAKE_SSH_STATE_DIR="$MISSING_BATCHMODE_STATE" \
  FAKE_SSH_SCENARIO="normal" \
  FAKE_SSH_BATCHMODE_VIOLATIONS="$MISSING_BATCHMODE_VIOLATIONS" \
    ssh "$@" > "$output_file" 2>&1
  local rc=$?

  assert_nonzero "$desc" "$rc"
}

echo "Test 0: fake ssh rejects every lifecycle class that omits BatchMode"
MISSING_BATCHMODE_TRANSCRIPT="$TMPDIR/missing-batchmode.transcript"
MISSING_BATCHMODE_VIOLATIONS="$TMPDIR/missing-batchmode.violations"
MISSING_BATCHMODE_STATE="$TMPDIR/fake-ssh-state-missing-batchmode"
MISSING_BATCHMODE_CONTROL_DIR="$TMPDIR/missing-batchmode-control"
MISSING_BATCHMODE_SOCKET="$MISSING_BATCHMODE_CONTROL_DIR/cm.sock"
: > "$MISSING_BATCHMODE_TRANSCRIPT"
: > "$MISSING_BATCHMODE_VIOLATIONS"
rm -rf "$MISSING_BATCHMODE_STATE" "$MISSING_BATCHMODE_CONTROL_DIR"
mkdir -p "$MISSING_BATCHMODE_STATE" "$MISSING_BATCHMODE_CONTROL_DIR"

run_fake_ssh_missing_batchmode "Preflight without BatchMode is rejected by fake ssh" \
  "$TMPDIR/missing-batchmode-preflight.out" \
  -i "$REMOTE_KEY" \
  -p 2222 \
  -o ConnectTimeout=10 \
  -o ControlMaster=no \
  deploy@remote.example \
  'hostname && uname -a'

run_fake_ssh_missing_batchmode "ControlMaster open without BatchMode is rejected by fake ssh" \
  "$TMPDIR/missing-batchmode-open.out" \
  -i "$REMOTE_KEY" \
  -p 2222 \
  -fN \
  -M \
  -S "$MISSING_BATCHMODE_SOCKET" \
  -o ControlPersist=600 \
  -o ServerAliveInterval=30 \
  deploy@remote.example

run_fake_ssh_missing_batchmode "Post-open ControlMaster check without BatchMode is rejected by fake ssh" \
  "$TMPDIR/missing-batchmode-post-open-check.out" \
  -i "$REMOTE_KEY" \
  -p 2222 \
  -O check \
  -S "$MISSING_BATCHMODE_SOCKET" \
  deploy@remote.example

run_fake_ssh_missing_batchmode "Inter-lens ControlMaster check without BatchMode is rejected by fake ssh" \
  "$TMPDIR/missing-batchmode-inter-lens-check.out" \
  -i "$REMOTE_KEY" \
  -p 2222 \
  -O check \
  -S "$MISSING_BATCHMODE_SOCKET" \
  deploy@remote.example

run_fake_ssh_missing_batchmode "ControlMaster close without BatchMode is rejected by fake ssh" \
  "$TMPDIR/missing-batchmode-close.out" \
  -i "$REMOTE_KEY" \
  -p 2222 \
  -O exit \
  -S "$MISSING_BATCHMODE_SOCKET" \
  deploy@remote.example

assert_eq "Preflight missing-BatchMode violation is recorded independently" \
  "1" "$(batchmode_violation_count "$MISSING_BATCHMODE_VIOLATIONS" "preflight")"
assert_eq "ControlMaster open missing-BatchMode violation is recorded independently" \
  "1" "$(batchmode_violation_count "$MISSING_BATCHMODE_VIOLATIONS" "open")"
assert_eq "Both post-open and inter-lens check missing-BatchMode violations are recorded" \
  "2" "$(batchmode_violation_count "$MISSING_BATCHMODE_VIOLATIONS" "check")"
assert_eq "ControlMaster close missing-BatchMode violation is recorded independently" \
  "1" "$(batchmode_violation_count "$MISSING_BATCHMODE_VIOLATIONS" "close")"
assert_eq "Rejected preflight call is transcribed before BatchMode rejection" \
  "1" "$(ssh_class_count "$MISSING_BATCHMODE_TRANSCRIPT" "preflight")"
assert_eq "Rejected ControlMaster open call is transcribed before BatchMode rejection" \
  "1" "$(ssh_class_count "$MISSING_BATCHMODE_TRANSCRIPT" "open")"
assert_eq "Both rejected ControlMaster check calls are transcribed before BatchMode rejection" \
  "2" "$(ssh_class_count "$MISSING_BATCHMODE_TRANSCRIPT" "check")"
assert_eq "Rejected ControlMaster close call is transcribed before BatchMode rejection" \
  "1" "$(ssh_class_count "$MISSING_BATCHMODE_TRANSCRIPT" "close")"

echo ""
echo "Test 0b: fake ssh accepts ControlMaster close when BatchMode is present"
VALID_CLOSE_TRANSCRIPT="$TMPDIR/valid-close-batchmode.transcript"
VALID_CLOSE_VIOLATIONS="$TMPDIR/valid-close-batchmode.violations"
VALID_CLOSE_STATE="$TMPDIR/fake-ssh-state-valid-close"
VALID_CLOSE_CONTROL_DIR="$TMPDIR/valid-close-control"
VALID_CLOSE_SOCKET="$VALID_CLOSE_CONTROL_DIR/cm.sock"
VALID_CLOSE_OUTPUT="$TMPDIR/valid-close-batchmode.out"
: > "$VALID_CLOSE_TRANSCRIPT"
: > "$VALID_CLOSE_VIOLATIONS"
rm -rf "$VALID_CLOSE_STATE" "$VALID_CLOSE_CONTROL_DIR"
mkdir -p "$VALID_CLOSE_STATE" "$VALID_CLOSE_CONTROL_DIR"

PATH="$FAKE_BIN:$PATH" \
FAKE_SSH_TRANSCRIPT="$VALID_CLOSE_TRANSCRIPT" \
FAKE_SSH_STATE_DIR="$VALID_CLOSE_STATE" \
FAKE_SSH_SCENARIO="normal" \
FAKE_SSH_BATCHMODE_VIOLATIONS="$VALID_CLOSE_VIOLATIONS" \
  ssh \
    -o BatchMode=yes \
    -i "$REMOTE_KEY" \
    -p 2222 \
    -O exit \
    -S "$VALID_CLOSE_SOCKET" \
    deploy@remote.example \
    > "$VALID_CLOSE_OUTPUT" 2>&1
valid_close_rc=$?

assert_eq "ControlMaster close with BatchMode is accepted by fake ssh" "0" "$valid_close_rc"
assert_eq "Accepted ControlMaster close records no missing-BatchMode violation" \
  "0" "$(batchmode_violation_count "$VALID_CLOSE_VIOLATIONS" "close")"
assert_eq "Accepted ControlMaster close is classified once" \
  "1" "$(ssh_class_count "$VALID_CLOSE_TRANSCRIPT" "close")"
assert_all_class_lines_contain "Accepted ControlMaster close keeps BatchMode=yes" \
  "$VALID_CLOSE_TRANSCRIPT" "close" $'\t-o\tBatchMode=yes\t'

echo ""
echo "Test 1: lifecycle SSH argv keeps BatchMode, parsed target, key, and cleanup semantics"
LOG1="$TMPDIR/lifecycle.log"
TRANSCRIPT1="$TMPDIR/lifecycle.transcript"
run_repolens_remote "$PROJECT" "$LOG1" "$TRANSCRIPT1" "lifecycle-close-fails" \
  --focus service-health \
  --remote deploy@remote.example:2222 \
  --remote-key "$REMOTE_KEY" \
  --remote-label "Lifecycle Target"
rc1=$?
out1="$(cat "$LOG1")"
ssh_transcript1="$(grep -F $'SSH_CALL\t' "$TRANSCRIPT1" 2>/dev/null || true)"

assert_eq "Remote deploy exits 0 even when ssh -O exit fails during cleanup" "0" "$rc1"
assert_not_contains "Remote deploy run does not call real ssh" "Could not resolve hostname" "$out1"
assert_class_count_at_least "Preflight ssh call is recorded" "$TRANSCRIPT1" "preflight" 1
assert_class_count_at_least "ControlMaster open ssh call is recorded" "$TRANSCRIPT1" "open" 1
assert_class_count_at_least "Post-open and inter-lens check calls are recorded" "$TRANSCRIPT1" "check" 2
assert_class_count_at_least "ControlMaster close ssh call is recorded" "$TRANSCRIPT1" "close" 1

for class in preflight open check close; do
  assert_all_class_lines_contain "$class uses BatchMode=yes" "$TRANSCRIPT1" "$class" $'\t-o\tBatchMode=yes\t'
  assert_all_class_lines_contain "$class preserves parsed port" "$TRANSCRIPT1" "$class" $'\t-p\t2222\t'
  assert_all_class_lines_contain "$class preserves --remote-key" "$TRANSCRIPT1" "$class" $'\t-i\t'"$REMOTE_KEY"$'\t'
  assert_all_class_lines_contain "$class uses parsed user@host without raw :port destination" "$TRANSCRIPT1" "$class" $'\tdeploy@remote.example'
done

assert_all_class_lines_contain "Preflight uses ConnectTimeout=10" "$TRANSCRIPT1" "preflight" $'\t-o\tConnectTimeout=10\t'
assert_all_class_lines_contain "Preflight disables ControlMaster creation" "$TRANSCRIPT1" "preflight" $'\t-o\tControlMaster=no\t'
preflight_transcript1="$(class_lines "$TRANSCRIPT1" "preflight")"
assert_not_contains "Preflight does not use ControlMaster=auto" "ControlMaster=auto" "$preflight_transcript1"
assert_not_contains "Preflight does not pass the RepoLens ControlPath" "ControlPath=" "$preflight_transcript1"
assert_all_class_lines_contain "ControlMaster open uses -fN" "$TRANSCRIPT1" "open" $'\t-fN\t'
assert_all_class_lines_contain "ControlMaster open uses -M" "$TRANSCRIPT1" "open" $'\t-M\t'
assert_all_class_lines_contain "ControlMaster open uses -S socket" "$TRANSCRIPT1" "open" $'\t-S\t'
assert_all_class_lines_contain "ControlMaster open uses ControlPersist=600" "$TRANSCRIPT1" "open" $'\t-o\tControlPersist=600\t'
assert_all_class_lines_contain "ControlMaster open uses ServerAliveInterval=30" "$TRANSCRIPT1" "open" $'\t-o\tServerAliveInterval=30\t'
assert_all_class_lines_contain "ControlMaster checks use -O check" "$TRANSCRIPT1" "check" $'\t-O\tcheck\t'
assert_all_class_lines_contain "ControlMaster checks use -S socket" "$TRANSCRIPT1" "check" $'\t-S\t'
assert_all_class_lines_contain "ControlMaster close uses -O exit" "$TRANSCRIPT1" "close" $'\t-O\texit\t'
assert_all_class_lines_contain "ControlMaster close uses -S socket" "$TRANSCRIPT1" "close" $'\t-S\t'
assert_not_contains "Lifecycle ssh calls do not pass raw host:port as destination" "deploy@remote.example:2222" "$ssh_transcript1"

preflight_line="$(nth_line_for_class "$TRANSCRIPT1" "preflight" 1)"
open_line="$(nth_line_for_class "$TRANSCRIPT1" "open" 1)"
post_check_line="$(nth_line_for_class "$TRANSCRIPT1" "check" 1)"
inter_check_line="$(nth_line_for_class "$TRANSCRIPT1" "check" 2)"
agent_line="$(first_agent_line "$TRANSCRIPT1")"
close_line="$(nth_line_for_class "$TRANSCRIPT1" "close" 1)"
assert_order "Preflight runs before ControlMaster open" "$preflight_line" "$open_line"
assert_order "ControlMaster open runs before post-open check" "$open_line" "$post_check_line"
assert_order "Post-open check runs before inter-lens check" "$post_check_line" "$inter_check_line"
assert_order "Inter-lens check runs before the agent" "$inter_check_line" "$agent_line"
assert_order "ControlMaster close runs after the agent" "$agent_line" "$close_line"

agent_socket="$(transcript_field "$TRANSCRIPT1" "AGENT_CALL" "REPOLENS_REMOTE_SSH_SOCKET")"
agent_target="$(transcript_field "$TRANSCRIPT1" "AGENT_CALL" "REPOLENS_REMOTE_TARGET")"
agent_label="$(transcript_field "$TRANSCRIPT1" "AGENT_CALL" "REPOLENS_REMOTE_LABEL")"
assert_contains "Agent receives exported remote SSH socket" "/" "$agent_socket"
assert_eq "Agent receives exported raw remote target" "deploy@remote.example:2222" "$agent_target"
assert_eq "Agent receives exported remote label" "Lifecycle Target" "$agent_label"

run_id1="$(parse_run_id "$LOG1")"
preflight_log1="$SCRIPT_DIR/logs/$run_id1/.remote/preflight.log"
if [[ -f "$preflight_log1" ]] && grep -Fq "remote-preflight-host" "$preflight_log1"; then
  record_pass "Preflight stdout is captured under logs/<run-id>/.remote/preflight.log"
else
  record_fail "Preflight stdout is captured under logs/<run-id>/.remote/preflight.log (file=$preflight_log1)"
fi

control_dir="$(dirname "$agent_socket")"
if [[ -n "$agent_socket" && ! -e "$agent_socket" && ! -d "$control_dir" ]]; then
  record_pass "Remote cleanup removes socket files even when ssh close exits non-zero"
else
  record_fail "Remote cleanup removes socket files even when ssh close exits non-zero (socket=$agent_socket dir=$control_dir)"
fi

echo ""
echo "Test 1b: failed post-open availability check aborts before agents run"
LOG1B="$TMPDIR/post-open-check-failure.log"
TRANSCRIPT1B="$TMPDIR/post-open-check-failure.transcript"
run_repolens_remote "$PROJECT" "$LOG1B" "$TRANSCRIPT1B" "post-open-check-fails" \
  --focus service-health \
  --remote deploy@remote.example:2222 \
  --remote-key "$REMOTE_KEY"
rc1b=$?
out1b="$(cat "$LOG1B")"
open_count1b="$(ssh_class_count "$TRANSCRIPT1B" "open")"
check_count1b="$(ssh_class_count "$TRANSCRIPT1B" "check")"
agent_count1b="$(agent_count "$TRANSCRIPT1B")"

assert_nonzero "Remote deploy exits non-zero when the post-open check fails" "$rc1b"
assert_eq "Post-open check failure attempts one ControlMaster open" "1" "$open_count1b"
assert_eq "Post-open check failure attempts one availability check" "1" "$check_count1b"
assert_eq "Post-open check failure aborts before any agent runs" "0" "$agent_count1b"
assert_contains "Post-open check failure is logged" "Remote ControlMaster availability check failed" "$out1b"
assert_all_class_lines_contain "Failed post-open check still uses BatchMode=yes" "$TRANSCRIPT1B" "check" $'\t-o\tBatchMode=yes\t'
assert_all_class_lines_contain "Failed post-open open still uses BatchMode=yes" "$TRANSCRIPT1B" "open" $'\t-o\tBatchMode=yes\t'

echo ""
echo "Test 2: first lost inter-lens master check reconnects once and continues"
LOG2="$TMPDIR/reconnect.log"
TRANSCRIPT2="$TMPDIR/reconnect.transcript"
run_repolens_remote "$PROJECT" "$LOG2" "$TRANSCRIPT2" "reconnect-once" \
  --domain deployment \
  --remote deploy@remote.example:2222 \
  --remote-key "$REMOTE_KEY"
rc2=$?
out2="$(cat "$LOG2")"
open_count2="$(ssh_class_count "$TRANSCRIPT2" "open")"
agent_count2="$(agent_count "$TRANSCRIPT2")"

assert_eq "Remote deploy exits 0 after one lost ControlMaster check" "0" "$rc2"
assert_eq "Exactly one reconnect opens the ControlMaster a second time" "2" "$open_count2"
assert_eq "All deployment lenses still run after the single reconnect" "$DEPLOYMENT_LENS_COUNT" "$agent_count2"
assert_contains "Reconnect path logs that the remote control socket is reopening" "reopening" "$out2"
assert_all_class_lines_contain "Reconnect checks also use BatchMode=yes" "$TRANSCRIPT2" "check" $'\t-o\tBatchMode=yes\t'
assert_all_class_lines_contain "Reopen also uses BatchMode=yes" "$TRANSCRIPT2" "open" $'\t-o\tBatchMode=yes\t'

echo ""
echo "Test 3: a second lost inter-lens master check aborts remaining lenses"
LOG3="$TMPDIR/second-loss.log"
TRANSCRIPT3="$TMPDIR/second-loss.transcript"
run_repolens_remote "$PROJECT" "$LOG3" "$TRANSCRIPT3" "abort-second-loss" \
  --domain deployment \
  --remote deploy@remote.example:2222 \
  --remote-key "$REMOTE_KEY"
rc3=$?
open_count3="$(ssh_class_count "$TRANSCRIPT3" "open")"
agent_count3="$(agent_count "$TRANSCRIPT3")"

assert_nonzero "Remote deploy exits non-zero after a second lost ControlMaster check" "$rc3"
assert_eq "Second loss does not open more than the initial master plus one reconnect" "2" "$open_count3"
assert_lt "Second loss aborts before all deployment lenses run" "$agent_count3" "$DEPLOYMENT_LENS_COUNT"
assert_all_class_lines_contain "Second-loss checks still use BatchMode=yes" "$TRANSCRIPT3" "check" $'\t-o\tBatchMode=yes\t'

echo ""
echo "Test 4: remote_close_master is idempotent after cleanup"
TRANSCRIPT4="$TMPDIR/close-idempotent.transcript"
RESULT4="$TMPDIR/close-idempotent.result"
CLOSE_CONTROL_DIR="$TMPDIR/close-idempotent-control"
CLOSE_SOCKET="$CLOSE_CONTROL_DIR/cm.sock"
: > "$TRANSCRIPT4"
rm -rf "$TMPDIR/fake-ssh-state-close" "$CLOSE_CONTROL_DIR"
mkdir -p "$TMPDIR/fake-ssh-state-close" "$CLOSE_CONTROL_DIR"
: > "$CLOSE_SOCKET"

set +e
(
  set -uo pipefail
  PATH="$FAKE_BIN:$PATH"
  export FAKE_SSH_TRANSCRIPT="$TRANSCRIPT4"
  export FAKE_SSH_STATE_DIR="$TMPDIR/fake-ssh-state-close"
  export FAKE_SSH_SCENARIO="normal"
  # shellcheck disable=SC2034 # Read by sourced lib/remote.sh.
  REMOTE_TARGET="deploy@remote.example:2222"
  # shellcheck disable=SC2034 # Read by sourced lib/remote.sh.
  REMOTE_USER="deploy"
  # shellcheck disable=SC2034 # Read by sourced lib/remote.sh.
  REMOTE_HOST="remote.example"
  # shellcheck disable=SC2034 # Read by sourced lib/remote.sh.
  REMOTE_PORT="2222"
  # shellcheck disable=SC2034 # Read by sourced lib/remote.sh.
  REPOLENS_REMOTE_SSH_SOCKET="$CLOSE_SOCKET"
  REPOLENS_REMOTE_SSH_CONTROL_DIR="$CLOSE_CONTROL_DIR"
  REPOLENS_REMOTE_MASTER_ACTIVE=1
  REPOLENS_REMOTE_MASTER_CLOSED=0
  # shellcheck disable=SC1091 # Runtime path is built from SCRIPT_DIR in this fixture.
  source "$SCRIPT_DIR/lib/remote.sh"
  # shellcheck disable=SC2329 # Invoked indirectly by remote_close_master.
  _cleanup_remote_control_socket() {
    rm -rf -- "$REPOLENS_REMOTE_SSH_CONTROL_DIR"
  }

  remote_close_master
  first_rc=$?
  remote_close_master
  second_rc=$?
  printf '%s\t%s\t%s\t%s\n' \
    "$first_rc" \
    "$second_rc" \
    "$REPOLENS_REMOTE_MASTER_CLOSED" \
    "$REPOLENS_REMOTE_MASTER_ACTIVE" > "$RESULT4"
)
direct_close_rc=$?
set +e

if [[ "$direct_close_rc" -eq 0 && -f "$RESULT4" ]]; then
  IFS=$'\t' read -r close_first_rc close_second_rc close_closed close_active < "$RESULT4"
else
  close_first_rc="missing"
  close_second_rc="missing"
  close_closed="missing"
  close_active="missing"
fi
close_count4="$(ssh_class_count "$TRANSCRIPT4" "close")"

assert_eq "First direct remote_close_master call returns 0" "0" "$close_first_rc"
assert_eq "Second direct remote_close_master call returns 0" "0" "$close_second_rc"
assert_eq "remote_close_master marks the master closed" "1" "$close_closed"
assert_eq "remote_close_master clears the active flag" "0" "$close_active"
assert_eq "Second remote_close_master call does not issue another ssh -O exit" "1" "$close_count4"
if [[ ! -e "$CLOSE_SOCKET" && ! -d "$CLOSE_CONTROL_DIR" ]]; then
  record_pass "remote_close_master cleanup remains complete after a second call"
else
  record_fail "remote_close_master cleanup remains complete after a second call (socket=$CLOSE_SOCKET dir=$CLOSE_CONTROL_DIR)"
fi

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
