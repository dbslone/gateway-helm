#!/usr/bin/env bash
# Render the Stalwart chart and assert ArgoCD-ready defaults.
set -euo pipefail

CHART="$(cd "$(dirname "$0")/../charts/stalwart" && pwd)"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to run this test" >&2
  exit 1
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -qF -- "$needle" <<<"$haystack"; then
    fail "expected to find: $needle"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if grep -qF -- "$needle" <<<"$haystack"; then
    fail "did not expect to find: $needle"
  fi
}

rendered="$(helm template stalwart "$CHART" --namespace mail)"

assert_contains "$rendered" "kind: StatefulSet"
assert_contains "$rendered" "kind: Namespace"
assert_contains "$rendered" "istio-injection: disabled"
assert_contains "$rendered" "sidecar.istio.io/inject: \"false\""
assert_contains "$rendered" "name: stalwart-config"
assert_contains "$rendered" '"@type": "RocksDb"'
assert_contains "$rendered" '"path": "/var/lib/stalwart"'
assert_contains "$rendered" "image: \"stalwartlabs/stalwart:v0.16.20\""
assert_contains "$rendered" "secretRef:"
assert_contains "$rendered" "name: stalwart-recovery-admin"
assert_not_contains "$rendered" "kind: Secret"
assert_contains "$rendered" "kind: VirtualService"
assert_contains "$rendered" "istio-ingress/api-gateway"
assert_contains "$rendered" "mail.dbslone.com"
assert_contains "$rendered" "mail.simplefbo.com"
assert_contains "$rendered" "kind: DestinationRule"
assert_contains "$rendered" "kind: PeerAuthentication"
assert_contains "$rendered" "mode: DISABLE"
assert_contains "$rendered" "name: stalwart-mail"
assert_contains "$rendered" "type: LoadBalancer"
assert_contains "$rendered" "name: tcp-smtp"
assert_contains "$rendered" "targetPort: smtp"
assert_contains "$rendered" "name: tcp-imaps"
assert_contains "$rendered" "port: 993"
assert_contains "$rendered" "volumeClaimTemplates"
assert_contains "$rendered" "storage: \"20Gi\""
assert_contains "$rendered" "name: stalwart-domains"
assert_contains "$rendered" "dbslone.com"
assert_contains "$rendered" "simplefbo.com"
assert_not_contains "$rendered" "kind: Job"
assert_contains "$rendered" "NET_BIND_SERVICE"
assert_contains "$rendered" "path: /healthz/live"
assert_contains "$rendered" "path: /healthz/ready"
assert_contains "$rendered" "--config"
assert_contains "$rendered" "/etc/stalwart/config.json"

# Chart-managed secret when no existingSecret is provided.
with_password="$(helm template stalwart "$CHART" --namespace mail \
  --set recoveryAdmin.existingSecret= \
  --set recoveryAdmin.password=test-password)"
assert_contains "$with_password" "kind: Secret"
assert_contains "$with_password" "STALWART_RECOVERY_ADMIN: \"admin:test-password\""
assert_contains "$with_password" "name: stalwart-env"

# Domain apply Job is opt-in so a failed CLI run cannot block ArgoCD.
with_apply="$(helm template stalwart "$CHART" --namespace mail --set domainsApply.enabled=true)"
assert_contains "$with_apply" "kind: Job"
assert_contains "$with_apply" "name: stalwart-apply-domains"
assert_contains "$with_apply" "argocd.argoproj.io/hook: Sync"
assert_contains "$with_apply" "apply"
assert_contains "$with_apply" "/plan/domains.ndjson"
assert_contains "$with_apply" "STALWART_URL"
assert_contains "$with_apply" "http://stalwart.mail.svc.cluster.local:8080"

# Mail LB and Istio VS can be disabled independently.
minimal="$(helm template stalwart "$CHART" --namespace mail \
  --set mailLoadBalancer.enabled=false \
  --set virtualService.enabled=false)"
assert_not_contains "$minimal" "name: stalwart-mail"
assert_not_contains "$minimal" "kind: VirtualService"
assert_not_contains "$minimal" "kind: DestinationRule"
assert_not_contains "$minimal" "kind: PeerAuthentication"
assert_contains "$minimal" "kind: StatefulSet"

# helm lint (warning-only notes are ok; fail on errors)
if ! helm lint "$CHART" >/tmp/stalwart-helm-lint.txt 2>&1; then
  cat /tmp/stalwart-helm-lint.txt >&2
  fail "helm lint failed"
fi

echo "OK: stalwart helm templates"
