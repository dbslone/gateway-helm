#!/usr/bin/env bash
# Render the Stalwart chart and assert ArgoCD-ready defaults.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/stalwart"
APP_FILE="$ROOT/applications/stalwart.yaml"
# Helm release names (ArgoCD --name-template) must be DNS-1123, lowercase, ≤53 chars.
HELM_RELEASE_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$'

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

# Reported: ArgoCD "Unable to create application" because helm --name-template
# was "Stalwart". That name must never be used as the Application name or
# helm.releaseName; helm itself rejects it before templates render.
if [[ ! -f "$APP_FILE" ]]; then
  fail "missing ArgoCD Application manifest: $APP_FILE"
fi
app_name="$(awk '$1=="name:" {print $2; exit}' "$APP_FILE")"
release_name="$(awk '$1=="releaseName:" {print $2; exit}' "$APP_FILE")"
if [[ -z "$release_name" ]]; then
  fail "applications/stalwart.yaml must set spec.source.helm.releaseName so ArgoCD does not pass the UI Application name (e.g. Stalwart) to helm --name-template"
fi
assert_helm_release_name() {
  local name="$1"
  local label="$2"
  if [[ -z "$name" || ${#name} -gt 53 ]] || ! [[ "$name" =~ $HELM_RELEASE_RE ]]; then
    fail "$label '$name' is not a valid Helm release name. ArgoCD error: invalid release name, must match regex ^[a-z0-9]([-a-z0-9]*[a-z0-9])? and length must not be longer than 53"
  fi
}
assert_helm_release_name "$app_name" "Application metadata.name"
assert_helm_release_name "$release_name" "helm.releaseName"
# Reported: creating the app fails because ArgoCD already has gateway-helm connected
# as HTTPS for simplefbo-api-gateway; git@... is a different unconnected repo URL.
repo_url="$(awk '$1=="repoURL:" {print $2; exit}' "$APP_FILE")"
if [[ "$repo_url" != "https://github.com/dbslone/gateway-helm.git" ]]; then
  fail "Application repoURL is '$repo_url'; ArgoCD will not reuse the connected simplefbo-api-gateway repo unless this is https://github.com/dbslone/gateway-helm.git (git@... is treated as a different, unconnected repo)"
fi
if helm template Stalwart "$CHART" --namespace mail >/tmp/stalwart-helm-bad-release.txt 2>&1; then
  fail "helm accepted release name 'Stalwart'; expected the invalid-release-name error ArgoCD reported"
fi
if ! grep -q 'invalid release name' /tmp/stalwart-helm-bad-release.txt; then
  fail "expected helm to reject 'Stalwart' as an invalid release name"
fi

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
