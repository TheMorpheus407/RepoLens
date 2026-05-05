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

# Tests for issue #66/#67/#68/#69/#70/#71/#72: kubernetes lens integration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECURITY_CONTEXT_LENS_FILE="$SCRIPT_DIR/prompts/lenses/kubernetes/security-context.md"
NETWORK_POLICIES_LENS_FILE="$SCRIPT_DIR/prompts/lenses/kubernetes/network-policies.md"
RESOURCE_MANAGEMENT_LENS_FILE="$SCRIPT_DIR/prompts/lenses/kubernetes/resource-management.md"
IMAGE_SECURITY_LENS_FILE="$SCRIPT_DIR/prompts/lenses/kubernetes/image-security.md"
INGRESS_TLS_LENS_FILE="$SCRIPT_DIR/prompts/lenses/kubernetes/ingress-tls.md"
RBAC_LENS_FILE="$SCRIPT_DIR/prompts/lenses/kubernetes/rbac.md"
SECRETS_MANAGEMENT_LENS_FILE="$SCRIPT_DIR/prompts/lenses/kubernetes/secrets-management.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
COLORS_FILE="$SCRIPT_DIR/config/label-colors.json"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Missing: $needle"
  fi
}

assert_file_exists() {
  local desc="$1" filepath="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$filepath" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    File not found: $filepath"
  fi
}

echo ""
echo "=== Test Suite: kubernetes lenses (issues #66/#67/#68/#69/#70/#71/#72) ==="
echo ""

assert_file_exists "security-context lens prompt exists" "$SECURITY_CONTEXT_LENS_FILE"
assert_file_exists "network-policies lens prompt exists" "$NETWORK_POLICIES_LENS_FILE"
assert_file_exists "resource-management lens prompt exists" "$RESOURCE_MANAGEMENT_LENS_FILE"
assert_file_exists "image-security lens prompt exists" "$IMAGE_SECURITY_LENS_FILE"
assert_file_exists "ingress-tls lens prompt exists" "$INGRESS_TLS_LENS_FILE"
assert_file_exists "rbac lens prompt exists" "$RBAC_LENS_FILE"
assert_file_exists "secrets-management lens prompt exists" "$SECRETS_MANAGEMENT_LENS_FILE"

security_context_content=""
if [[ -f "$SECURITY_CONTEXT_LENS_FILE" ]]; then
  security_context_content="$(cat "$SECURITY_CONTEXT_LENS_FILE")"
fi

network_policies_content=""
if [[ -f "$NETWORK_POLICIES_LENS_FILE" ]]; then
  network_policies_content="$(cat "$NETWORK_POLICIES_LENS_FILE")"
fi

resource_management_content=""
if [[ -f "$RESOURCE_MANAGEMENT_LENS_FILE" ]]; then
  resource_management_content="$(cat "$RESOURCE_MANAGEMENT_LENS_FILE")"
fi

image_security_content=""
if [[ -f "$IMAGE_SECURITY_LENS_FILE" ]]; then
  image_security_content="$(cat "$IMAGE_SECURITY_LENS_FILE")"
fi

ingress_tls_content=""
if [[ -f "$INGRESS_TLS_LENS_FILE" ]]; then
  ingress_tls_content="$(cat "$INGRESS_TLS_LENS_FILE")"
fi

rbac_content=""
if [[ -f "$RBAC_LENS_FILE" ]]; then
  rbac_content="$(cat "$RBAC_LENS_FILE")"
fi

secrets_management_content=""
if [[ -f "$SECRETS_MANAGEMENT_LENS_FILE" ]]; then
  secrets_management_content="$(cat "$SECRETS_MANAGEMENT_LENS_FILE")"
fi

echo ""
echo "Test 1: security-context frontmatter is complete"
assert_contains "security-context id frontmatter" "id: security-context" "$security_context_content"
assert_contains "security-context domain frontmatter" "domain: kubernetes" "$security_context_content"
assert_contains "security-context name frontmatter" "name: Pod Security Context" "$security_context_content"
assert_contains "security-context role frontmatter" "role: Kubernetes Security Specialist" "$security_context_content"

echo ""
echo "Test 2: security-context body has required sections"
assert_contains "security-context expert focus section" "## Your Expert Focus" "$security_context_content"
assert_contains "security-context hunt section" "### What You Hunt For" "$security_context_content"
assert_contains "security-context investigate section" "### How You Investigate" "$security_context_content"

echo ""
echo "Test 3: security-context lens covers high-impact Kubernetes security controls"
for term in \
  "runAsNonRoot" \
  "allowPrivilegeEscalation" \
  "readOnlyRootFilesystem" \
  "capabilities" \
  "seccompProfile" \
  "hostPath" \
  "hostPID" \
  "hostNetwork" \
  "automountServiceAccountToken"; do
  assert_contains "security-context mentions $term" "$term" "$security_context_content"
done

echo ""
echo "Test 4: network-policies frontmatter is complete"
assert_contains "network-policies id frontmatter" "id: network-policies" "$network_policies_content"
assert_contains "network-policies domain frontmatter" "domain: kubernetes" "$network_policies_content"
assert_contains "network-policies name frontmatter" "name: NetworkPolicy Coverage & Correctness" "$network_policies_content"
assert_contains "network-policies role frontmatter" "role: Kubernetes Network Segmentation Specialist" "$network_policies_content"

echo ""
echo "Test 5: network-policies body has required sections"
assert_contains "network-policies expert focus section" "## Your Expert Focus" "$network_policies_content"
assert_contains "network-policies hunt section" "### What You Hunt For" "$network_policies_content"
assert_contains "network-policies investigate section" "### How You Investigate" "$network_policies_content"

echo ""
echo "Test 6: network-policies lens covers key NetworkPolicy risks"
for term in \
  "NetworkPolicy" \
  "default-deny" \
  "podSelector" \
  "namespaceSelector" \
  "Egress" \
  "DNS" \
  "ipBlock" \
  "0.0.0.0/0" \
  "169.254.169.254"; do
  assert_contains "network-policies mentions $term" "$term" "$network_policies_content"
done

echo ""
echo "Test 7: Kubernetes domain is registered once"
kubernetes_domain_count="$(jq '[.domains[] | select(.id == "kubernetes")] | length' "$DOMAINS_FILE")"
assert_eq "one kubernetes domain" "1" "$kubernetes_domain_count"

echo ""
echo "Test 8: Kubernetes domain is mode-less default audit coverage"
kubernetes_mode="$(jq -r '.domains[] | select(.id == "kubernetes") | .mode // "null"' "$DOMAINS_FILE")"
assert_eq "no mode field" "null" "$kubernetes_mode"

echo ""
echo "Test 9: Kubernetes domain contains all lenses in stable order"
kubernetes_lenses="$(jq -r '.domains[] | select(.id == "kubernetes") | .lenses | join(",")' "$DOMAINS_FILE")"
assert_eq "registered lens list" "security-context,network-policies,resource-management,image-security,ingress-tls,rbac,secrets-management" "$kubernetes_lenses"

echo ""
echo "Test 10: Kubernetes label color is configured"
kubernetes_color="$(jq -r '.kubernetes // empty' "$COLORS_FILE")"
assert_eq "kubernetes label color" "326ce5" "$kubernetes_color"

echo ""
echo "Test 11: Audit-like mode resolution includes all Kubernetes lenses"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
for lens in kubernetes/security-context kubernetes/network-policies kubernetes/resource-management kubernetes/image-security kubernetes/ingress-tls kubernetes/rbac kubernetes/secrets-management; do
  if grep -qxF "$lens" <<< "$audit_lenses"; then
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: audit mode includes $lens"
  else
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: audit mode should include $lens"
  fi
done

echo ""
echo "Test 12: Exclusive modes do not include Kubernetes lenses"
for mode in discover deploy opensource content; do
  mode_lenses="$(jq -r --arg mode "$mode" \
    '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
  for lens in kubernetes/security-context kubernetes/network-policies kubernetes/resource-management kubernetes/image-security kubernetes/ingress-tls kubernetes/rbac kubernetes/secrets-management; do
    if grep -qxF "$lens" <<< "$mode_lenses"; then
      FAIL=$((FAIL + 1))
      TOTAL=$((TOTAL + 1))
      echo "  FAIL: $mode mode should not include $lens"
    else
      PASS=$((PASS + 1))
      TOTAL=$((TOTAL + 1))
      echo "  PASS: $mode mode excludes $lens"
    fi
  done
done

echo ""
echo "Test 13: resource-management frontmatter is complete"
assert_contains "resource-management id frontmatter" "id: resource-management" "$resource_management_content"
assert_contains "resource-management domain frontmatter" "domain: kubernetes" "$resource_management_content"
assert_contains "resource-management name frontmatter" "name: Kubernetes Resource Management" "$resource_management_content"
assert_contains "resource-management role frontmatter" "role: Kubernetes Resource Management Analyst" "$resource_management_content"

echo ""
echo "Test 14: resource-management body has required sections"
assert_contains "resource-management expert focus section" "## Your Expert Focus" "$resource_management_content"
assert_contains "resource-management hunt section" "### What You Hunt For" "$resource_management_content"
assert_contains "resource-management investigate section" "### How You Investigate" "$resource_management_content"

echo ""
echo "Test 15: resource-management lens covers Kubernetes resource management risks"
for term in \
  "HorizontalPodAutoscaler" \
  "PodDisruptionBudget" \
  "resources.requests" \
  "resources.limits" \
  "requests.cpu" \
  "LimitRange" \
  "ResourceQuota" \
  "StatefulSet" \
  "minReplicas" \
  "stabilizationWindowSeconds"; do
  assert_contains "resource-management mentions $term" "$term" "$resource_management_content"
done

echo ""
echo "Test 16: image-security frontmatter is complete"
assert_contains "image-security id frontmatter" "id: image-security" "$image_security_content"
assert_contains "image-security domain frontmatter" "domain: kubernetes" "$image_security_content"
assert_contains "image-security name frontmatter" "name: Kubernetes Image Security" "$image_security_content"
assert_contains "image-security role frontmatter" "role: Container Image Analyst" "$image_security_content"

echo ""
echo "Test 17: image-security body has required sections"
assert_contains "image-security expert focus section" "## Your Expert Focus" "$image_security_content"
assert_contains "image-security hunt section" "### What You Hunt For" "$image_security_content"
assert_contains "image-security investigate section" "### How You Investigate" "$image_security_content"

echo ""
echo "Test 18: image-security lens covers Kubernetes image supply chain risks"
for term in \
  ":latest" \
  "imagePullPolicy" \
  "IfNotPresent" \
  "Always" \
  "imagePullSecrets" \
  "initContainers" \
  "sha256" \
  "docker.io" \
  "ghcr.io" \
  "Kyverno" \
  "cosign"; do
  assert_contains "image-security mentions $term" "$term" "$image_security_content"
done

echo ""
echo "Test 19: ingress-tls frontmatter is complete"
assert_contains "ingress-tls id frontmatter" "id: ingress-tls" "$ingress_tls_content"
assert_contains "ingress-tls domain frontmatter" "domain: kubernetes" "$ingress_tls_content"
assert_contains "ingress-tls name frontmatter" "name: Ingress TLS & Transport Security" "$ingress_tls_content"
assert_contains "ingress-tls role frontmatter" "role: Kubernetes Ingress Security Specialist" "$ingress_tls_content"

echo ""
echo "Test 20: ingress-tls body has required sections"
assert_contains "ingress-tls expert focus section" "## Your Expert Focus" "$ingress_tls_content"
assert_contains "ingress-tls hunt section" "### What You Hunt For" "$ingress_tls_content"
assert_contains "ingress-tls investigate section" "### How You Investigate" "$ingress_tls_content"

echo ""
echo "Test 21: ingress-tls lens covers Kubernetes Ingress transport security risks"
for term in \
  "Ingress" \
  "tls" \
  "cert-manager.io/cluster-issuer" \
  "cert-manager.io/issuer" \
  "ssl-redirect" \
  "hsts" \
  "max-age" \
  "includeSubDomains" \
  "preload" \
  "proxy-body-size" \
  "limit-rps" \
  "proxy-read-timeout" \
  "backend-protocol" \
  "kubernetes_ingress_v1"; do
  assert_contains "ingress-tls mentions $term" "$term" "$ingress_tls_content"
done

echo ""
echo "Test 22: rbac frontmatter is complete"
assert_contains "rbac id frontmatter" "id: rbac" "$rbac_content"
assert_contains "rbac domain frontmatter" "domain: kubernetes" "$rbac_content"
assert_contains "rbac name frontmatter" "name: RBAC & ServiceAccount Least Privilege" "$rbac_content"
assert_contains "rbac role frontmatter" "role: Kubernetes RBAC Security Specialist" "$rbac_content"

echo ""
echo "Test 23: rbac body has required sections"
assert_contains "rbac expert focus section" "## Your Expert Focus" "$rbac_content"
assert_contains "rbac hunt section" "### What You Hunt For" "$rbac_content"
assert_contains "rbac investigate section" "### How You Investigate" "$rbac_content"

echo ""
echo "Test 24: rbac lens covers Kubernetes RBAC and ServiceAccount risks"
for term in \
  "ClusterRoleBinding" \
  "RoleBinding" \
  "cluster-admin" \
  "ServiceAccount" \
  "verbs: [\"*\"]" \
  "resources: [\"*\"]" \
  "serviceAccountName" \
  "automountServiceAccountToken" \
  "secrets" \
  "pods/exec" \
  "audit policy" \
  "RequestResponse"; do
  assert_contains "rbac mentions $term" "$term" "$rbac_content"
done

echo ""
echo "Test 25: secrets-management frontmatter is complete"
assert_contains "secrets-management id frontmatter" "id: secrets-management" "$secrets_management_content"
assert_contains "secrets-management domain frontmatter" "domain: kubernetes" "$secrets_management_content"
assert_contains "secrets-management name frontmatter" "name: Kubernetes Secrets Management" "$secrets_management_content"
assert_contains "secrets-management role frontmatter" "role: Kubernetes Secrets Specialist" "$secrets_management_content"

echo ""
echo "Test 26: secrets-management body has required sections"
assert_contains "secrets-management expert focus section" "## Your Expert Focus" "$secrets_management_content"
assert_contains "secrets-management hunt section" "### What You Hunt For" "$secrets_management_content"
assert_contains "secrets-management investigate section" "### How You Investigate" "$secrets_management_content"

echo ""
echo "Test 27: secrets-management lens covers Kubernetes secret lifecycle risks"
for term in \
  "kind: Secret" \
  "stringData" \
  "SealedSecret" \
  "SOPS" \
  "ExternalSecret" \
  "SecretStore" \
  "secretKeyRef" \
  "secretRef" \
  "envFrom" \
  "ConfigMap" \
  "automountServiceAccountToken" \
  "resourceNames" \
  "refreshInterval" \
  "rotation"; do
  assert_contains "secrets-management mentions $term" "$term" "$secrets_management_content"
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

exit 0
