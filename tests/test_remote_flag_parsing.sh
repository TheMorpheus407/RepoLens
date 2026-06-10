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

# Tests for issue #196 - remote deploy CLI flag parsing.
#
# Behavioural contract:
#   - --remote is accepted only for deploy/server dry-runs.
#   - bare host, user@host, and user@host:port targets surface in dry-run
#     output with the resolved port.
#   - --remote-key must name an existing regular file.
#   - --remote-label is accepted as CLI plumbing for later remote auth work.
#   - --remote conflicts with --hosted and Android deploy targets.
#   - --help documents the remote flags.
#
# The tests drive the public CLI with fake agent and SSH binaries. Dry-run
# cases stay parse-only; the single-lens remote fixtures exercise the remote
# lifecycle without invoking a real model or SSH command.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPDIR="$(mktemp -d)"
CREATED_LOG_DIRS=()

# shellcheck disable=SC2329
_cleanup() {
  rm -rf "$TMPDIR"
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

assert_rc_zero() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected rc=0, got rc=$rc)"
  fi
}

assert_rc_nonzero() {
  local desc="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected non-zero rc, got rc=0)"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle' in: ${haystack:0:240})"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (unexpected '$needle' present in: ${haystack:0:240})"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected '$expected', got '$actual')"
  fi
}

record_run_id() {
  local log_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null | head -1 | awk '{print $3}' || true)"
  if [[ -n "${run_id:-}" ]]; then
    CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi
}

ssh_class_count() {
  local transcript="$1" class="$2"
  grep -F -c $'SSH_CALL\t'"$class"$'\t' "$transcript" 2>/dev/null || true
}

class_lines() {
  local transcript="$1" class="$2"
  grep -F $'SSH_CALL\t'"$class"$'\t' "$transcript" 2>/dev/null || true
}

batchmode_violation_count() {
  local violations="$1" class="$2"
  grep -F -c $'missing-batchmode\t'"$class"$'\t' "$violations" 2>/dev/null || true
}

batchmode_violation_total() {
  local violations="$1"
  grep -F -c $'missing-batchmode\t' "$violations" 2>/dev/null || true
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

assert_all_class_lines_not_contains() {
  local desc="$1" transcript="$2" class="$3" needle="$4"
  local lines present=0
  lines="$(class_lines "$transcript" "$class")"
  if [[ -z "$lines" ]]; then
    record_fail "$desc (no '$class' calls recorded)"
    return
  fi
  while IFS= read -r line; do
    [[ "$line" != *"$needle"* ]] || present=$((present + 1))
  done <<< "$lines"
  if [[ "$present" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc ($present '$class' call(s) unexpectedly contained '$needle')"
  fi
}

# ---------------------------------------------------------------------------
# Fake agent + fixtures
# ---------------------------------------------------------------------------

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
if [[ -n "${FAKE_CLAUDE_ENV_LOG:-}" ]]; then
  {
    printf 'REMOTE_TARGET=%s\n' "${REMOTE_TARGET:-}"
    printf 'REMOTE_USER=%s\n' "${REMOTE_USER:-}"
    printf 'REMOTE_HOST=%s\n' "${REMOTE_HOST:-}"
    printf 'REMOTE_PORT=%s\n' "${REMOTE_PORT:-}"
    printf 'REMOTE_KEY=%s\n' "${REMOTE_KEY:-}"
    printf 'REMOTE_LABEL=%s\n' "${REMOTE_LABEL:-}"
    printf 'REPOLENS_REMOTE_TARGET=%s\n' "${REPOLENS_REMOTE_TARGET:-}"
    printf 'REPOLENS_REMOTE_LABEL=%s\n' "${REPOLENS_REMOTE_LABEL:-}"
    printf 'REPOLENS_REMOTE_SSH_SOCKET=%s\n' "${REPOLENS_REMOTE_SSH_SOCKET:-}"
    printf 'REPOLENS_REMOTE_SSH_CONTROL_DIR=%s\n' "${REPOLENS_REMOTE_SSH_CONTROL_DIR:-}"
    if [[ -n "${REPOLENS_REMOTE_SSH_CONTROL_DIR:-}" && -d "$REPOLENS_REMOTE_SSH_CONTROL_DIR" ]]; then
      printf 'REPOLENS_REMOTE_SSH_CONTROL_DIR_MODE=%s\n' "$(stat -c '%a' "$REPOLENS_REMOTE_SSH_CONTROL_DIR")"
      printf 'REPOLENS_REMOTE_SSH_CONTROL_DIR_OWNER=%s\n' "$(stat -c '%u' "$REPOLENS_REMOTE_SSH_CONTROL_DIR")"
      if [[ -f "${REPOLENS_LOG_BASE:-}/.remote/control-dir" ]]; then
        printf 'REPOLENS_REMOTE_CONTROL_DIR_METADATA=%s\n' "$(cat "$REPOLENS_LOG_BASE/.remote/control-dir")"
      fi
    fi
  } >> "$FAKE_CLAUDE_ENV_LOG"
fi
printf '%s\n' DONE
exit 0
SH
chmod +x "$FAKE_BIN/claude"

cat > "$FAKE_BIN/ssh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

transcript="${FAKE_SSH_TRANSCRIPT:-}"
state_dir="${FAKE_SSH_STATE_DIR:-}"
batchmode_violations="${FAKE_SSH_BATCHMODE_VIOLATIONS:-}"

class="unknown"
operation=""
socket_path=""
has_master=0
has_fN=0
has_f=0
has_N=0
has_preflight=0
has_batchmode=0
prev=""

for arg in "$@"; do
  if [[ "$prev" == "-O" ]]; then
    operation="$arg"
  elif [[ "$prev" == "-S" ]]; then
    socket_path="$arg"
  elif [[ "$prev" == "-o" && "$arg" == "BatchMode=yes" ]]; then
    has_batchmode=1
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

call_count=1
if [[ -n "$state_dir" ]]; then
  mkdir -p "$state_dir"
  call_count_file="$state_dir/call-count"
  call_count="$(cat "$call_count_file" 2>/dev/null || printf '0')"
  call_count=$((call_count + 1))
  printf '%s\n' "$call_count" > "$call_count_file"
fi

if [[ -n "$transcript" ]]; then
  {
    printf 'SSH_CALL\t%s\tcall=%s' "$class" "$call_count"
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
        printf 'missing-batchmode\t%s\tcall=%s\n' "$class" "$call_count" >> "$batchmode_violations"
      fi
      printf '%s\n' "fake ssh: $class missing -o BatchMode=yes" >&2
      exit 64
    fi
    ;;
esac

if [[ "$class" == "open" && -n "$socket_path" ]]; then
  if [[ -e "$socket_path" ]]; then
    printf '%s\n' "simulated ControlMaster socket conflict" >&2
    exit 255
  fi
  mkdir -p "$(dirname "$socket_path")"
  : > "$socket_path"
fi

if [[ "$class" == "close" && -n "$socket_path" ]]; then
  rm -f -- "$socket_path"
fi

if [[ "$class" == "preflight" ]]; then
  printf '%s\n' "remote-flag-preflight-host"
  printf '%s\n' "Linux remote-flag-preflight 6.1.0-test #1 SMP"
fi

exit 0
SH
chmod +x "$FAKE_BIN/ssh"
export PATH="$FAKE_BIN:$PATH"

PLAIN_DIR="$TMPDIR/plain-target"
mkdir -p "$PLAIN_DIR"
printf '%s\n' "# plain target" > "$PLAIN_DIR/README.md"

APK_DIR="$TMPDIR/apk-target"
mkdir -p "$APK_DIR/app/build/outputs/apk/debug"
: > "$APK_DIR/app/build/outputs/apk/debug/app-debug.apk"
DIRECT_APK="$APK_DIR/app/build/outputs/apk/debug/app-debug.apk"

REMOTE_KEY="$TMPDIR/id_ed25519"
printf '%s\n' "fake private key for CLI validation only" > "$REMOTE_KEY"

REMOTE_KEY_DIR="$TMPDIR/key-dir"
mkdir -p "$REMOTE_KEY_DIR"

run_repolens() {
  local project="$1" log_file="$2"
  shift 2
  set +e
  bash "$REPOLENS" \
    --project "$project" \
    --agent claude \
    "$@" \
    >"$log_file" 2>&1
  local rc=$?
  set -e
  record_run_id "$log_file"
  return "$rc"
}

run_dry_deploy() {
  local project="$1" log_file="$2"
  shift 2
  run_repolens "$project" "$log_file" \
    --mode deploy \
    --local \
    --dry-run \
    --yes \
    "$@"
}

run_fake_ssh_missing_batchmode() {
  local desc="$1" output_file="$2"
  shift 2

  set +e
  PATH="$FAKE_BIN:$PATH" \
  FAKE_SSH_TRANSCRIPT="$MISSING_BATCHMODE_TRANSCRIPT" \
  FAKE_SSH_BATCHMODE_VIOLATIONS="$MISSING_BATCHMODE_VIOLATIONS" \
  FAKE_SSH_STATE_DIR="$MISSING_BATCHMODE_STATE" \
    ssh "$@" >"$output_file" 2>&1
  local rc=$?
  set -e

  assert_rc_nonzero "$desc" "$rc"
}

echo ""
echo "=== Test Suite: remote deploy CLI flag parsing (issue #196) ==="
echo ""

# ===========================================================================
# Test 0: fixture fake ssh rejects lifecycle calls missing BatchMode
# ===========================================================================
echo "Test 0: fake ssh rejects lifecycle calls missing BatchMode"
MISSING_BATCHMODE_TRANSCRIPT="$TMPDIR/missing-batchmode.transcript"
MISSING_BATCHMODE_VIOLATIONS="$TMPDIR/missing-batchmode.violations"
MISSING_BATCHMODE_STATE="$TMPDIR/fake-ssh-state-missing-batchmode"
MISSING_BATCHMODE_CONTROL_DIR="$TMPDIR/missing-batchmode-control"
MISSING_BATCHMODE_SOCKET="$MISSING_BATCHMODE_CONTROL_DIR/cm.sock"
: > "$MISSING_BATCHMODE_TRANSCRIPT"
: > "$MISSING_BATCHMODE_VIOLATIONS"
rm -rf "$MISSING_BATCHMODE_STATE" "$MISSING_BATCHMODE_CONTROL_DIR"
mkdir -p "$MISSING_BATCHMODE_STATE" "$MISSING_BATCHMODE_CONTROL_DIR"

if [[ -x "$FAKE_BIN/ssh" ]]; then
  record_pass "flag parsing fixture installs fake ssh"

  run_fake_ssh_missing_batchmode "preflight without BatchMode is rejected" \
    "$TMPDIR/missing-batchmode-preflight.out" \
    -i "$REMOTE_KEY" \
    -p 2222 \
    -o ConnectTimeout=10 \
    -o ControlMaster=no \
    ubuntu@host.example.com \
    'hostname && uname -a'

  run_fake_ssh_missing_batchmode "ControlMaster open without BatchMode is rejected" \
    "$TMPDIR/missing-batchmode-open.out" \
    -i "$REMOTE_KEY" \
    -p 2222 \
    -fN \
    -M \
    -S "$MISSING_BATCHMODE_SOCKET" \
    -o ControlPersist=600 \
    -o ServerAliveInterval=30 \
    ubuntu@host.example.com

  run_fake_ssh_missing_batchmode "ControlMaster check without BatchMode is rejected" \
    "$TMPDIR/missing-batchmode-check.out" \
    -i "$REMOTE_KEY" \
    -p 2222 \
    -O check \
    -S "$MISSING_BATCHMODE_SOCKET" \
    ubuntu@host.example.com

  run_fake_ssh_missing_batchmode "ControlMaster close without BatchMode is rejected" \
    "$TMPDIR/missing-batchmode-close.out" \
    -i "$REMOTE_KEY" \
    -p 2222 \
    -O exit \
    -S "$MISSING_BATCHMODE_SOCKET" \
    ubuntu@host.example.com

  assert_eq "preflight missing-BatchMode violation is recorded" \
    "1" "$(batchmode_violation_count "$MISSING_BATCHMODE_VIOLATIONS" "preflight")"
  assert_eq "ControlMaster open missing-BatchMode violation is recorded" \
    "1" "$(batchmode_violation_count "$MISSING_BATCHMODE_VIOLATIONS" "open")"
  assert_eq "ControlMaster check missing-BatchMode violation is recorded" \
    "1" "$(batchmode_violation_count "$MISSING_BATCHMODE_VIOLATIONS" "check")"
  assert_eq "ControlMaster close missing-BatchMode violation is recorded" \
    "1" "$(batchmode_violation_count "$MISSING_BATCHMODE_VIOLATIONS" "close")"
  assert_eq "rejected preflight call is transcribed" \
    "1" "$(ssh_class_count "$MISSING_BATCHMODE_TRANSCRIPT" "preflight")"
  assert_eq "rejected ControlMaster open call is transcribed" \
    "1" "$(ssh_class_count "$MISSING_BATCHMODE_TRANSCRIPT" "open")"
  assert_eq "rejected ControlMaster check call is transcribed" \
    "1" "$(ssh_class_count "$MISSING_BATCHMODE_TRANSCRIPT" "check")"
  assert_eq "rejected ControlMaster close call is transcribed" \
    "1" "$(ssh_class_count "$MISSING_BATCHMODE_TRANSCRIPT" "close")"
else
  record_fail "flag parsing fixture installs fake ssh (missing $FAKE_BIN/ssh)"
fi

# ===========================================================================
# Test 1: --help documents the remote flags near deploy/hosted options
# ===========================================================================
echo "Test 1: help output lists remote deploy flags"
HELP_LOG="$TMPDIR/help.log"
set +e
bash "$REPOLENS" --help >"$HELP_LOG" 2>&1
help_rc=$?
set -e
help_out="$(cat "$HELP_LOG")"

assert_rc_zero "--help exits zero" "$help_rc"
assert_contains "help lists --remote" "--remote <ssh-target>" "$help_out"
assert_contains "help lists --remote-key" "--remote-key <path>" "$help_out"
assert_contains "help lists --remote-label" "--remote-label <text>" "$help_out"

# ===========================================================================
# Test 2: dry-run without --remote keeps the remote line absent
# ===========================================================================
echo ""
echo "Test 2: deploy dry-run without --remote does not show a remote target"
LOG2="$TMPDIR/run2.log"
run_dry_deploy "$PLAIN_DIR" "$LOG2" || rc2=$?
rc2="${rc2:-0}"
out2="$(cat "$LOG2")"

assert_rc_zero "plain deploy dry-run exits zero" "$rc2"
assert_contains "plain deploy reaches dry-run completion" "Dry run complete" "$out2"
assert_not_contains "plain deploy has no remote target line" "Remote target:" "$out2"

# ===========================================================================
# Test 3: bare host defaults to port 22
# ===========================================================================
echo ""
echo "Test 3: --remote bare host defaults to port 22"
LOG3="$TMPDIR/run3.log"
run_dry_deploy "$PLAIN_DIR" "$LOG3" --remote host.example.com || rc3=$?
rc3="${rc3:-0}"
out3="$(cat "$LOG3")"

assert_rc_zero "bare host remote exits zero" "$rc3"
assert_contains "bare host remote line includes default port" \
  "Remote target: host.example.com:22" "$out3"
assert_contains "bare host reaches dry-run completion" "Dry run complete" "$out3"

# ===========================================================================
# Test 4: user@host defaults to port 22
# ===========================================================================
echo ""
echo "Test 4: --remote user@host defaults to port 22"
LOG4="$TMPDIR/run4.log"
run_dry_deploy "$PLAIN_DIR" "$LOG4" --remote ubuntu@host.example.com || rc4=$?
rc4="${rc4:-0}"
out4="$(cat "$LOG4")"

assert_rc_zero "user host remote exits zero" "$rc4"
assert_contains "user host remote line includes default port" \
  "Remote target: ubuntu@host.example.com:22" "$out4"
assert_contains "user host reaches dry-run completion" "Dry run complete" "$out4"

# ===========================================================================
# Test 5: user@host:port preserves the explicit port without duplication
# ===========================================================================
echo ""
echo "Test 5: --remote user@host:port preserves explicit port"
LOG5="$TMPDIR/run5.log"
run_dry_deploy "$PLAIN_DIR" "$LOG5" --remote ubuntu@host.example.com:2222 || rc5=$?
rc5="${rc5:-0}"
out5="$(cat "$LOG5")"

assert_rc_zero "user host port remote exits zero" "$rc5"
assert_contains "user host port remote line includes explicit port" \
  "Remote target: ubuntu@host.example.com:2222" "$out5"
assert_not_contains "explicit port is not duplicated in dry-run output" \
  "ubuntu@host.example.com:2222:2222" "$out5"

# ===========================================================================
# Test 6: host:port without a user preserves the explicit port
# ===========================================================================
echo ""
echo "Test 6: --remote host:port preserves explicit port"
LOG6="$TMPDIR/run6.log"
run_dry_deploy "$PLAIN_DIR" "$LOG6" --remote host.example.com:2200 || rc6=$?
rc6="${rc6:-0}"
out6="$(cat "$LOG6")"

assert_rc_zero "host port remote exits zero" "$rc6"
assert_contains "host port remote line includes explicit port" \
  "Remote target: host.example.com:2200" "$out6"
assert_not_contains "host port output does not invent a remote user" \
  "@host.example.com:2200" "$out6"

# ===========================================================================
# Test 7: --remote-key accepts an existing regular file and is surfaced
# ===========================================================================
echo ""
echo "Test 7: --remote-key accepts an existing key file"
LOG7="$TMPDIR/run7.log"
run_dry_deploy "$PLAIN_DIR" "$LOG7" \
  --remote ubuntu@host.example.com \
  --remote-key "$REMOTE_KEY" \
  --remote-label "Production host" || rc7=$?
rc7="${rc7:-0}"
out7="$(cat "$LOG7")"

assert_rc_zero "remote key file exits zero" "$rc7"
assert_contains "remote key line includes the exact key path" \
  "Remote target: ubuntu@host.example.com:22 (key: $REMOTE_KEY)" "$out7"
assert_not_contains "remote-label is accepted, not rejected as unknown" \
  "Unknown argument: --remote-label" "$out7"

# ===========================================================================
# Test 8: missing --remote-key path fails
# ===========================================================================
echo ""
echo "Test 8: --remote-key rejects a missing file"
LOG8="$TMPDIR/run8.log"
run_dry_deploy "$PLAIN_DIR" "$LOG8" \
  --remote host.example.com \
  --remote-key "$TMPDIR/missing-key" || rc8=$?
rc8="${rc8:-0}"
out8="$(cat "$LOG8")"

assert_rc_nonzero "missing remote key exits non-zero" "$rc8"
assert_contains "missing remote key reports validation failure" \
  "Remote key file does not exist or is not a regular file" "$out8"

# ===========================================================================
# Test 9: directory --remote-key path fails regular-file validation
# ===========================================================================
echo ""
echo "Test 9: --remote-key rejects directories"
LOG9="$TMPDIR/run9.log"
run_dry_deploy "$PLAIN_DIR" "$LOG9" \
  --remote host.example.com \
  --remote-key "$REMOTE_KEY_DIR" || rc9=$?
rc9="${rc9:-0}"
out9="$(cat "$LOG9")"

assert_rc_nonzero "directory remote key exits non-zero" "$rc9"
assert_contains "directory remote key reports validation failure" \
  "Remote key file does not exist or is not a regular file" "$out9"

# ===========================================================================
# Test 10: --remote is deploy-mode only
# ===========================================================================
echo ""
echo "Test 10: --remote is rejected outside deploy mode"
LOG10="$TMPDIR/run10.log"
run_repolens "$SCRIPT_DIR" "$LOG10" \
  --mode audit \
  --local \
  --dry-run \
  --yes \
  --remote host.example.com || rc10=$?
rc10="${rc10:-0}"
out10="$(cat "$LOG10")"

assert_rc_nonzero "--remote outside deploy exits non-zero" "$rc10"
assert_contains "--remote outside deploy reports deploy-mode requirement" \
  "--remote requires --mode deploy" "$out10"

# ===========================================================================
# Test 11: --remote and --hosted are mutually exclusive before Docker checks
# ===========================================================================
echo ""
echo "Test 11: --remote conflicts with --hosted"
LOG11="$TMPDIR/run11.log"
run_dry_deploy "$PLAIN_DIR" "$LOG11" --remote host.example.com --hosted || rc11=$?
rc11="${rc11:-0}"
out11="$(cat "$LOG11")"

assert_rc_nonzero "--remote with hosted exits non-zero" "$rc11"
assert_contains "--remote with hosted reports mutual exclusion" \
  "--remote and --hosted are mutually exclusive" "$out11"
assert_not_contains "--remote with hosted does not fail on Docker first" \
  "--hosted requires Docker" "$out11"

# ===========================================================================
# Test 12: --remote conflicts with Android deploy target classification
# ===========================================================================
echo ""
echo "Test 12: --remote conflicts with Android deploy targets"
LOG12="$TMPDIR/run12.log"
run_dry_deploy "$DIRECT_APK" "$LOG12" --remote host.example.com || rc12=$?
rc12="${rc12:-0}"
out12="$(cat "$LOG12")"

assert_rc_nonzero "--remote with direct APK exits non-zero" "$rc12"
assert_contains "--remote with direct APK reports android incompatibility" \
  "--remote is incompatible with android deploy targets" "$out12"

# ===========================================================================
# Test 13: malformed SSH target fails validation
# ===========================================================================
echo ""
echo "Test 13: malformed --remote target is rejected"
LOG13="$TMPDIR/run13.log"
run_dry_deploy "$PLAIN_DIR" "$LOG13" --remote ubuntu@bad/host || rc13=$?
rc13="${rc13:-0}"
out13="$(cat "$LOG13")"

assert_rc_nonzero "malformed remote target exits non-zero" "$rc13"
assert_contains "malformed remote target reports invalid target" \
  "Invalid --remote target: ubuntu@bad/host" "$out13"

# ===========================================================================
# Test 14: non-numeric SSH target port fails validation
# ===========================================================================
echo ""
echo "Test 14: non-numeric --remote port is rejected"
LOG14="$TMPDIR/run14.log"
run_dry_deploy "$PLAIN_DIR" "$LOG14" --remote host.example.com:ssh || rc14=$?
rc14="${rc14:-0}"
out14="$(cat "$LOG14")"

assert_rc_nonzero "non-numeric remote port exits non-zero" "$rc14"
assert_contains "non-numeric remote port reports invalid port" \
  "Invalid --remote port: ssh" "$out14"

# ===========================================================================
# Test 15: parsed remote state is exported to a real agent invocation
# ===========================================================================
echo ""
echo "Test 15: parsed remote variables are exported to the agent environment"
LOG15="$TMPDIR/run15.log"
ENV15="$TMPDIR/claude-env15.log"
SSH15_TRANSCRIPT="$TMPDIR/ssh15.transcript"
SSH15_VIOLATIONS="$TMPDIR/ssh15.violations"
SSH15_STATE="$TMPDIR/fake-ssh-state15"
: > "$SSH15_TRANSCRIPT"
: > "$SSH15_VIOLATIONS"
rm -rf "$SSH15_STATE"
mkdir -p "$SSH15_STATE"
FAKE_CLAUDE_ENV_LOG="$ENV15" \
FAKE_SSH_TRANSCRIPT="$SSH15_TRANSCRIPT" \
FAKE_SSH_BATCHMODE_VIOLATIONS="$SSH15_VIOLATIONS" \
FAKE_SSH_STATE_DIR="$SSH15_STATE" \
  run_repolens "$PLAIN_DIR" "$LOG15" \
  --mode deploy \
  --local \
  --yes \
  --focus service-health \
  --remote ubuntu@host.example.com:2222 \
  --remote-key "$REMOTE_KEY" \
  --remote-label "Production host" || rc15=$?
rc15="${rc15:-0}"
out15="$(cat "$LOG15")"
env15="$(cat "$ENV15" 2>/dev/null || true)"

assert_rc_zero "single-lens remote deploy run exits zero" "$rc15"
assert_contains "remote deploy run completed the selected lens" \
  "DONE x1" "$out15"
assert_contains "agent env includes REMOTE_TARGET" \
  "REMOTE_TARGET=ubuntu@host.example.com:2222" "$env15"
assert_contains "agent env includes REMOTE_USER" \
  "REMOTE_USER=ubuntu" "$env15"
assert_contains "agent env includes REMOTE_HOST" \
  "REMOTE_HOST=host.example.com" "$env15"
assert_contains "agent env includes REMOTE_PORT" \
  "REMOTE_PORT=2222" "$env15"
assert_contains "agent env includes REMOTE_KEY" \
  "REMOTE_KEY=$REMOTE_KEY" "$env15"
assert_contains "agent env includes REMOTE_LABEL" \
  "REMOTE_LABEL=Production host" "$env15"
assert_contains "agent env includes prompt remote target" \
  "REPOLENS_REMOTE_TARGET=ubuntu@host.example.com:2222" "$env15"
assert_contains "agent env includes prompt remote label" \
  "REPOLENS_REMOTE_LABEL=Production host" "$env15"
expected_socket15_hash="$(printf '%s' 'user=ubuntu|host=host.example.com|port=2222' | sha256sum)"
expected_socket15_hash="${expected_socket15_hash%% *}"
expected_socket15_hash="${expected_socket15_hash:0:16}"
run15_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$LOG15" | head -1 | awk '{print $3}')"
expected_run15_hash="$(printf '%s' "$run15_id" | sha256sum)"
expected_run15_hash="${expected_run15_hash%% *}"
expected_run15_hash="${expected_run15_hash:0:8}"
socket15="$(awk -F= '$1=="REPOLENS_REMOTE_SSH_SOCKET"{print $2}' "$ENV15" | tail -1)"
socket15_dir="$(dirname "$socket15")"
assert_contains "agent env includes target-bound prompt SSH socket setting" \
  "/cm-${expected_socket15_hash}-${expected_run15_hash}.sock" "$socket15"
assert_contains "agent env SSH socket directory is a secure runtime dir" \
  "/rl-cm-${expected_run15_hash}." "$socket15_dir"
assert_not_contains "agent env SSH socket does not use predictable legacy directory" \
  "/tmp/repolens-ssh-" "$socket15"
assert_not_contains "agent env SSH socket does not use the old none placeholder" \
  "REPOLENS_REMOTE_SSH_SOCKET=none" "$env15"
if (( ${#socket15} < 90 )); then
  record_pass "agent env SSH socket path is length-bounded"
else
  record_fail "agent env SSH socket path is length-bounded (length=${#socket15}, path=$socket15)"
fi
assert_contains "agent env exports SSH control dir" \
  "REPOLENS_REMOTE_SSH_CONTROL_DIR=$socket15_dir" "$env15"
assert_contains "agent sees SSH control dir mode 0700" \
  "REPOLENS_REMOTE_SSH_CONTROL_DIR_MODE=700" "$env15"
assert_contains "agent sees SSH control dir owned by current uid" \
  "REPOLENS_REMOTE_SSH_CONTROL_DIR_OWNER=$(id -u)" "$env15"
metadata15="$(cat "$SCRIPT_DIR/logs/$run15_id/.remote/control-dir" 2>/dev/null || true)"
assert_eq "remote control dir metadata records socket directory" "$socket15_dir" "$metadata15"
if [[ -x "$FAKE_BIN/ssh" ]]; then
  assert_class_count_at_least "single-lens remote deploy records preflight ssh call" \
    "$SSH15_TRANSCRIPT" "preflight" 1
  assert_class_count_at_least "single-lens remote deploy records ControlMaster open ssh call" \
    "$SSH15_TRANSCRIPT" "open" 1
  assert_class_count_at_least "single-lens remote deploy records ControlMaster check ssh call" \
    "$SSH15_TRANSCRIPT" "check" 1
  assert_class_count_at_least "single-lens remote deploy records ControlMaster close ssh call" \
    "$SSH15_TRANSCRIPT" "close" 1
  for class in preflight open check close; do
    assert_all_class_lines_contain "$class lifecycle call uses BatchMode=yes" \
      "$SSH15_TRANSCRIPT" "$class" $'\t-o\tBatchMode=yes\t'
    assert_all_class_lines_contain "$class lifecycle call preserves parsed port" \
      "$SSH15_TRANSCRIPT" "$class" $'\t-p\t2222\t'
    assert_all_class_lines_contain "$class lifecycle call preserves --remote-key" \
      "$SSH15_TRANSCRIPT" "$class" $'\t-i\t'"$REMOTE_KEY"$'\t'
    assert_all_class_lines_contain "$class lifecycle call uses parsed user@host destination" \
      "$SSH15_TRANSCRIPT" "$class" $'\tubuntu@host.example.com'
  done
  ssh_transcript15="$(grep -F $'SSH_CALL\t' "$SSH15_TRANSCRIPT" 2>/dev/null || true)"
  assert_not_contains "single-lens lifecycle does not pass raw host:port as SSH destination" \
    "ubuntu@host.example.com:2222" "$ssh_transcript15"
  assert_eq "single-lens remote deploy records no missing-BatchMode violations" \
    "0" "$(batchmode_violation_total "$SSH15_VIOLATIONS")"
else
  record_fail "single-lens remote deploy is covered by fake ssh lifecycle transcript (missing $FAKE_BIN/ssh)"
fi

# ===========================================================================
# Test 15b: unsafe persisted remote control-dir metadata fails closed
# ===========================================================================
echo ""
echo "Test 15b: unsafe persisted remote control-dir metadata is rejected"
BAD_RESUME_ID="remote-bad-control-dir-$$"
BAD_RESUME_DIR="$SCRIPT_DIR/logs/$BAD_RESUME_ID"
mkdir -p "$BAD_RESUME_DIR/.remote"
CREATED_LOG_DIRS+=("$BAD_RESUME_DIR")
printf '%s\n' "$SCRIPT_DIR" > "$BAD_RESUME_DIR/.remote/control-dir"
LOG15B="$TMPDIR/run15b.log"
run_repolens "$PLAIN_DIR" "$LOG15B" \
  --mode deploy \
  --local \
  --yes \
  --focus service-health \
  --remote ubuntu@host.example.com:2222 \
  --resume "$BAD_RESUME_ID" || rc15b=$?
rc15b="${rc15b:-0}"
out15b="$(cat "$LOG15B")"

assert_rc_nonzero "unsafe persisted control dir exits non-zero" "$rc15b"
assert_contains "unsafe persisted control dir reports failure" \
  "Unsafe persisted remote SSH control socket directory: $SCRIPT_DIR" "$out15b"

# ===========================================================================
# Test 16: --remote-label pipe text cannot inject template variables
# ===========================================================================
echo ""
echo "Test 16: --remote-label with pipe text remains literal"
LOG16="$TMPDIR/run16.log"
ENV16="$TMPDIR/claude-env16.log"
SSH16_TRANSCRIPT="$TMPDIR/ssh16.transcript"
SSH16_VIOLATIONS="$TMPDIR/ssh16.violations"
SSH16_STATE="$TMPDIR/fake-ssh-state16"
: > "$SSH16_TRANSCRIPT"
: > "$SSH16_VIOLATIONS"
rm -rf "$SSH16_STATE"
mkdir -p "$SSH16_STATE"
FAKE_CLAUDE_ENV_LOG="$ENV16" \
FAKE_SSH_TRANSCRIPT="$SSH16_TRANSCRIPT" \
FAKE_SSH_BATCHMODE_VIOLATIONS="$SSH16_VIOLATIONS" \
FAKE_SSH_STATE_DIR="$SSH16_STATE" \
  run_repolens "$PLAIN_DIR" "$LOG16" \
  --mode deploy \
  --local \
  --yes \
  --focus service-health \
  --remote ubuntu@host.example.com:2222 \
  --remote-label "Prod|REPOLENS_REMOTE_TARGET=" || rc16=$?
rc16="${rc16:-0}"
out16="$(cat "$LOG16")"
env16="$(cat "$ENV16" 2>/dev/null || true)"

assert_rc_zero "pipe label remote deploy run exits zero" "$rc16"
assert_contains "pipe label deploy run completed the selected lens" \
  "DONE x1" "$out16"
assert_contains "pipe label preserves prompt remote target in agent env" \
  "REPOLENS_REMOTE_TARGET=ubuntu@host.example.com:2222" "$env16"
assert_contains "pipe label is literal in prompt remote label env" \
  "REPOLENS_REMOTE_LABEL=Prod|REPOLENS_REMOTE_TARGET=" "$env16"
if [[ -x "$FAKE_BIN/ssh" ]]; then
  assert_class_count_at_least "pipe-label remote deploy records preflight ssh call" \
    "$SSH16_TRANSCRIPT" "preflight" 1
  assert_class_count_at_least "pipe-label remote deploy records ControlMaster open ssh call" \
    "$SSH16_TRANSCRIPT" "open" 1
  assert_class_count_at_least "pipe-label remote deploy records ControlMaster check ssh call" \
    "$SSH16_TRANSCRIPT" "check" 1
  assert_class_count_at_least "pipe-label remote deploy records ControlMaster close ssh call" \
    "$SSH16_TRANSCRIPT" "close" 1
  for class in preflight open check close; do
    assert_all_class_lines_contain "pipe-label $class lifecycle call uses BatchMode=yes" \
      "$SSH16_TRANSCRIPT" "$class" $'\t-o\tBatchMode=yes\t'
    assert_all_class_lines_contain "pipe-label $class lifecycle call preserves parsed port" \
      "$SSH16_TRANSCRIPT" "$class" $'\t-p\t2222\t'
    assert_all_class_lines_contain "pipe-label $class lifecycle call uses parsed user@host destination" \
      "$SSH16_TRANSCRIPT" "$class" $'\tubuntu@host.example.com'
    assert_all_class_lines_not_contains "pipe-label $class lifecycle call does not require --remote-key" \
      "$SSH16_TRANSCRIPT" "$class" $'\t-i\t'
  done
  assert_eq "pipe-label remote deploy records no missing-BatchMode violations" \
    "0" "$(batchmode_violation_total "$SSH16_VIOLATIONS")"
else
  record_fail "pipe-label remote deploy is covered by fake ssh lifecycle transcript (missing $FAKE_BIN/ssh)"
fi

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
