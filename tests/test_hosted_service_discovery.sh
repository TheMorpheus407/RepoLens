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

# Regression tests for issue #83: hosted discovery must report the container
# ports reachable from the Compose network, not only host-published ports.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/hosted.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/hosted-service-discovery.XXXXXX")"
trap 'rm -rf "$TMPDIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

DOCKER_CALL_LOG="$TMPDIR/docker-calls.log"
DOCKER_PS_JSON=""
DOCKER_PS_RC=0
DOCKER_PS_Q_OUTPUT=""
DOCKER_PS_Q_RC=0
DOCKER_INSPECT_RC=0
DOCKER_INSPECT_FORMAT_OUTPUT=""
DOCKER_INSPECT_JSON_OUTPUT=""

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
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle', got '${haystack:0:240}')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (did not expect '$needle')"
  fi
}

assert_zero_rc() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected rc=0, got rc=$rc)"
  fi
}

reset_docker_stub() {
  DOCKER_PS_JSON=""
  DOCKER_PS_RC=0
  DOCKER_PS_Q_OUTPUT=""
  DOCKER_PS_Q_RC=0
  DOCKER_INSPECT_RC=0
  DOCKER_INSPECT_FORMAT_OUTPUT=""
  DOCKER_INSPECT_JSON_OUTPUT=""
  : > "$DOCKER_CALL_LOG"
  HOSTED_SERVICES=""
  HOSTED_SERVICES_DETAIL=""
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced hosted helpers.
docker() {
  printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"

  if [[ "${1:-}" == "compose" ]]; then
    if [[ "$*" == *" ps --format json"* ]]; then
      printf '%s\n' "$DOCKER_PS_JSON"
      return "$DOCKER_PS_RC"
    fi
    if [[ "$*" == *" ps -q"* ]]; then
      printf '%s\n' "$DOCKER_PS_Q_OUTPUT"
      return "$DOCKER_PS_Q_RC"
    fi
  fi

  if [[ "${1:-}" == "inspect" ]]; then
    if [[ "$DOCKER_INSPECT_RC" -ne 0 ]]; then
      return "$DOCKER_INSPECT_RC"
    fi
    if [[ "$*" == *"--format"* ]]; then
      printf '%s\n' "$DOCKER_INSPECT_FORMAT_OUTPUT"
    else
      printf '%s\n' "$DOCKER_INSPECT_JSON_OUTPUT"
    fi
    return 0
  fi

  echo "unexpected docker invocation: $*" >&2
  return 127
}

run_discovery() {
  discover_services "$TMPDIR/compose.yml" "issue83"
}

docker_calls() {
  cat "$DOCKER_CALL_LOG"
}

echo ""
echo "=== Test Suite: hosted service discovery internal ports (issue #83) ==="
echo ""

echo "Test 1: parser exposes container ID and target port when the port is not published"
reset_docker_stub
parsed="$(_parse_service_json '{"Service":"web","Image":"example/web","ID":"web-container","Publishers":[{"URL":"","TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}')"
assert_contains "parser keeps service name" "web" "$parsed"
assert_contains "parser keeps image" "example/web" "$parsed"
assert_contains "parser exposes container id" "web-container" "$parsed"
assert_contains "parser exposes target port 80" "80" "$parsed"

echo ""
echo "Test 2: discover_services uses NDJSON TargetPort values for scanner URLs"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","Publishers":[{"URL":"","TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"api","Image":"example/api","ID":"api-id","Ports":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
run_discovery
assert_eq "compact service list uses internal ports" "web:80,api:8080" "$HOSTED_SERVICES"
assert_contains "web detail uses service name and internal port" "http://web:80 (" "$HOSTED_SERVICES_DETAIL"
assert_contains "api detail uses service name and internal port" "http://api:8080" "$HOSTED_SERVICES_DETAIL"
assert_contains "internal detail is labelled internal" "(internal" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "internal-only services are not described as unpublished" "no published port" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 3: host-published ports are secondary when target port differs"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"web","Image":"example/web","ID":"web-id","Publishers":[{"URL":"0.0.0.0","TargetPort":80,"PublishedPort":8080,"Protocol":"tcp"}]}'
run_discovery
assert_eq "compact service list prefers Docker-network port" "web:80" "$HOSTED_SERVICES"
assert_contains "detail points scanners at target port" "http://web:80 (" "$HOSTED_SERVICES_DETAIL"
assert_contains "detail preserves host-published port as metadata" "published host port 8080" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "detail does not point scanner at host-published port" "http://web:8080" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 4: discovery falls back to docker inspect ExposedPorts"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"worker","Image":"example/worker","ID":"worker-id","Publishers":[]}'
DOCKER_INSPECT_FORMAT_OUTPUT="$(cat <<'EOF_FORMAT'
9000/udp
9090/tcp
EOF_FORMAT
)"
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{"9000/udp":{},"9090/tcp":{}}}}]'
run_discovery
assert_eq "compact service list uses inspected TCP exposed port" "worker:9090" "$HOSTED_SERVICES"
assert_contains "detail uses inspected TCP port" "http://worker:9090" "$HOSTED_SERVICES_DETAIL"
assert_contains "inspect fallback is labelled internal" "(internal" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 5: discovery resolves container ID before inspect when Compose JSON omits it"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"api","Image":"example/api","Publishers":[]}'
DOCKER_PS_Q_OUTPUT='api-container'
DOCKER_INSPECT_FORMAT_OUTPUT='8080/tcp'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{"8080/tcp":{}}}}]'
run_discovery
calls="$(docker_calls)"
assert_eq "compact service list uses inspected port after ID lookup" "api:8080" "$HOSTED_SERVICES"
assert_contains "service-specific ps -q resolves missing ID" "ps -q api" "$calls"
assert_contains "resolved container ID is inspected" "api-container" "$calls"

echo ""
echo "Test 6: inspect failures are non-fatal and leave an explicit no-port detail"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"job","Image":"example/job","ID":"job-id","Publishers":[]}'
DOCKER_INSPECT_RC=42
run_discovery
rc=$?
assert_zero_rc "discover_services tolerates inspect failure" "$rc"
assert_eq "compact service list falls back to none" "job:none" "$HOSTED_SERVICES"
assert_contains "detail uses discovered-port wording" "no discovered port" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 7: JSON array compose output still uses internal target ports"
reset_docker_stub
DOCKER_PS_JSON='[{"Service":"web","Image":"example/web","ID":"web-id","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]},{"Service":"api","Image":"example/api","ID":"api-id","Ports":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}]'
run_discovery
assert_eq "array output compact list uses internal ports" "web:80,api:8080" "$HOSTED_SERVICES"
assert_contains "array output has web internal URL" "http://web:80 (" "$HOSTED_SERVICES_DETAIL"
assert_contains "array output has api internal URL" "http://api:8080" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 8: published-only metadata remains a fallback when no internal port is known"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"admin","Image":"example/admin","ID":"admin-id","Publishers":[{"URL":"0.0.0.0","PublishedPort":9443,"Protocol":"tcp"}]}'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{}}}]'
run_discovery
assert_eq "compact service list falls back to published port" "admin:9443" "$HOSTED_SERVICES"
assert_contains "detail points at published fallback port" "http://admin:9443" "$HOSTED_SERVICES_DETAIL"
assert_contains "detail labels published-only fallback" "(published, example/admin)" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 9: Ports[].PrivatePort is accepted as an internal port"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"legacy","Image":"example/legacy","ID":"legacy-id","Ports":[{"PrivatePort":5000,"PublishedPort":0,"Protocol":"tcp"}]}'
run_discovery
assert_eq "compact service list uses private port" "legacy:5000" "$HOSTED_SERVICES"
assert_contains "detail uses private port URL" "http://legacy:5000" "$HOSTED_SERVICES_DETAIL"
assert_contains "private port detail is labelled internal" "(internal" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 10: Compose UDP ports are ignored for HTTP scanner URLs"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"metrics","Image":"example/metrics","ID":"metrics-id","Publishers":[{"TargetPort":8125,"PublishedPort":8125,"Protocol":"udp"},{"TargetPort":9090,"PublishedPort":0,"Protocol":"tcp"}]}'
run_discovery
assert_eq "compact service list skips UDP and uses TCP target" "metrics:9090" "$HOSTED_SERVICES"
assert_contains "detail uses TCP target port" "http://metrics:9090" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "detail does not use UDP port" "http://metrics:8125" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "=========================================="
echo "Results: $PASS/$TOTAL passed ($FAIL failed)"
echo "=========================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
