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

# RepoLens remote SSH lifecycle helpers.

REPOLENS_REMOTE_MASTER_ACTIVE="${REPOLENS_REMOTE_MASTER_ACTIVE:-0}"
REPOLENS_REMOTE_MASTER_CLOSED="${REPOLENS_REMOTE_MASTER_CLOSED:-0}"
REPOLENS_REMOTE_MASTER_RECONNECTS="${REPOLENS_REMOTE_MASTER_RECONNECTS:-0}"
REPOLENS_REMOTE_PREFLIGHT_OK="${REPOLENS_REMOTE_PREFLIGHT_OK:-0}"
REPOLENS_REMOTE_SSH_BASE_ARGS=()

remote_ssh_target() {
  local ssh_target="${REMOTE_HOST:-}"
  if [[ -n "${REMOTE_USER:-}" ]]; then
    ssh_target="${REMOTE_USER}@${REMOTE_HOST}"
  fi
  printf '%s\n' "$ssh_target"
}

remote_ssh_base_args() {
  REPOLENS_REMOTE_SSH_BASE_ARGS=(-o BatchMode=yes)

  if [[ -n "${REMOTE_KEY:-}" ]]; then
    REPOLENS_REMOTE_SSH_BASE_ARGS+=(-i "$REMOTE_KEY")
  fi
  if [[ -n "${REMOTE_PORT:-}" ]]; then
    REPOLENS_REMOTE_SSH_BASE_ARGS+=(-p "$REMOTE_PORT")
  fi
}

remote_preflight() {
  [[ -n "${REMOTE_TARGET:-}" ]] || return 0

  local remote_dir="${REMOTE_RUN_DIR:-${LOG_BASE:-}/.remote}"
  local preflight_log="$remote_dir/preflight.log"
  local ssh_target
  local ssh_args=()

  mkdir -p "$remote_dir"
  remote_ssh_base_args
  ssh_target="$(remote_ssh_target)"
  ssh_args=(
    "${REPOLENS_REMOTE_SSH_BASE_ARGS[@]}"
    -o ConnectTimeout=10
    -o ControlMaster=no
  )

  # shellcheck disable=SC2029 # Destination expands locally; remote command is fixed.
  ssh "${ssh_args[@]}" "$ssh_target" 'hostname && uname -a' > "$preflight_log" 2>&1
  local preflight_rc=$?
  if (( preflight_rc == 0 )); then
    REPOLENS_REMOTE_PREFLIGHT_OK=1
    log_info "Remote preflight captured: $preflight_log"
    return 0
  fi

  REPOLENS_REMOTE_PREFLIGHT_OK=0
  log_warn "Remote preflight failed for $REMOTE_TARGET (exit $preflight_rc); see $preflight_log"
  return "$preflight_rc"
}

_remote_master_check_once() {
  [[ -n "${REMOTE_TARGET:-}" ]] || return 0

  local ssh_target
  local ssh_args=()

  remote_ssh_base_args
  ssh_target="$(remote_ssh_target)"
  ssh_args=(
    "${REPOLENS_REMOTE_SSH_BASE_ARGS[@]}"
    -O check
    -S "$REPOLENS_REMOTE_SSH_SOCKET"
  )

  # shellcheck disable=SC2029 # Destination expands locally; no remote command is interpolated.
  ssh "${ssh_args[@]}" "$ssh_target" >/dev/null 2>&1
}

remote_open_master() {
  [[ -n "${REMOTE_TARGET:-}" ]] || return 0
  [[ -n "${REPOLENS_REMOTE_SSH_SOCKET:-}" ]] || return 1

  local ssh_target
  local ssh_args=()

  remote_ssh_base_args
  ssh_target="$(remote_ssh_target)"
  ssh_args=(
    "${REPOLENS_REMOTE_SSH_BASE_ARGS[@]}"
    -fN
    -M
    -S "$REPOLENS_REMOTE_SSH_SOCKET"
    -o ControlPersist=600
    -o ServerAliveInterval=30
  )

  # shellcheck disable=SC2029 # Destination expands locally; no remote command is interpolated.
  if ! ssh "${ssh_args[@]}" "$ssh_target" >/dev/null 2>&1; then
    REPOLENS_REMOTE_MASTER_ACTIVE=0
    log_warn "Remote ControlMaster open failed for $REMOTE_TARGET"
    return 1
  fi

  if ! _remote_master_check_once; then
    REPOLENS_REMOTE_MASTER_ACTIVE=0
    log_warn "Remote ControlMaster availability check failed for $REMOTE_TARGET"
    return 1
  fi

  REPOLENS_REMOTE_MASTER_ACTIVE=1
  REPOLENS_REMOTE_MASTER_CLOSED=0
  log_info "Remote ControlMaster opened: $REPOLENS_REMOTE_SSH_SOCKET"
  return 0
}

remote_check_master() {
  [[ -n "${REMOTE_TARGET:-}" ]] || return 0
  [[ "${REPOLENS_REMOTE_MASTER_ACTIVE:-0}" == "1" ]] || return 0

  if _remote_master_check_once; then
    return 0
  fi

  if (( ${REPOLENS_REMOTE_MASTER_RECONNECTS:-0} < 1 )); then
    REPOLENS_REMOTE_MASTER_RECONNECTS=$((REPOLENS_REMOTE_MASTER_RECONNECTS + 1))
    REPOLENS_REMOTE_MASTER_ACTIVE=0
    log_warn "Remote control socket lost; reopening"
    if remote_open_master; then
      return 0
    fi
  fi

  REPOLENS_REMOTE_MASTER_ACTIVE=0
  log_error "Remote control socket lost again; aborting remote run"
  if [[ -n "${SUMMARY_FILE:-}" && -f "${SUMMARY_FILE:-}" ]] && declare -F set_stop_reason >/dev/null 2>&1; then
    set_stop_reason "$SUMMARY_FILE" "remote-controlmaster-lost"
  fi
  return 1
}

remote_close_master() {
  [[ -n "${REMOTE_TARGET:-}" ]] || return 0

  if [[ "${REPOLENS_REMOTE_MASTER_CLOSED:-0}" != "1" && -n "${REPOLENS_REMOTE_SSH_SOCKET:-}" ]]; then
    local ssh_target
    local ssh_args=()

    remote_ssh_base_args
    ssh_target="$(remote_ssh_target)"
    ssh_args=(
      "${REPOLENS_REMOTE_SSH_BASE_ARGS[@]}"
      -O exit
      -S "$REPOLENS_REMOTE_SSH_SOCKET"
    )
    # shellcheck disable=SC2029 # Destination expands locally; no remote command is interpolated.
    ssh "${ssh_args[@]}" "$ssh_target" >/dev/null 2>&1 || true
  fi

  REPOLENS_REMOTE_MASTER_ACTIVE=0
  REPOLENS_REMOTE_MASTER_CLOSED=1

  if declare -F _cleanup_remote_control_socket >/dev/null 2>&1; then
    _cleanup_remote_control_socket || true
  fi
  return 0
}
