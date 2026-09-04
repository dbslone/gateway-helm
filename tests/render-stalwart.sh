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
# Reported: ArgoCD "repository not accessible" / parse
# " https://github.com/dbslone/gateway-helm": first path segment in URL cannot
# contain colon. A leading space makes Go treat the value as a relative path.
repo_url="$(awk '$1=="repoURL:" {
  sub(/^[[:space:]]*repoURL:[[:space:]]*/, "")
  gsub(/^["'\'']|["'\'']$/, "")
  print
  exit
}' "$APP_FILE")"
repo_url_ok() {
  local url="$1"
  [[ "$url" == "${url#"${url%%[![:space:]]*}"}" && "$url" == "${url%"${url##*[![:space:]]}"}" ]] || return 1
  python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse
url = sys.argv[1]
parsed = urlparse(url)
if url != url.strip() or parsed.scheme != "https" or parsed.netloc != "github.com":
    sys.exit(1)
PY
}
if ! repo_url_ok "$repo_url"; then
  fail "repoURL '$repo_url' is not usable; ArgoCD error: parse \"${repo_url}\": first path segment in URL cannot contain colon"
fi
if [[ "$repo_url" != "https://github.com/dbslone/gateway-helm.git" ]]; then
  fail "Application repoURL is '$repo_url'; ArgoCD will not reuse the connected simplefbo-api-gateway repo unless this is https://github.com/dbslone/gateway-helm.git (git@... is treated as a different, unconnected repo)"
fi
if repo_url_ok " https://github.com/dbslone/gateway-helm"; then
  fail "expected the reported ArgoCD URL (leading space, no .git) to be rejected"
fi
if helm template Stalwart "$CHART" --namespace mail >/tmp/stalwart-helm-bad-release.txt 2>&1; then
  fail "helm accepted release name 'Stalwart'; expected the invalid-release-name error ArgoCD reported"
fi
if ! grep -q 'invalid release name' /tmp/stalwart-helm-bad-release.txt; then
  fail "expected helm to reject 'Stalwart' as an invalid release name"
fi

rendered="$(helm template stalwart "$CHART" --namespace mail)"

# Reported: ArgoCD sync fails with
# "resource :Namespace is not permitted in project simplefbo".
# CreateNamespace=true on the Application creates `mail`; the chart must not
# emit a cluster-scoped Namespace (or other cluster-scoped kinds).
app_project="$(awk '$1=="project:" {print $2; exit}' "$APP_FILE")"
if [[ "$app_project" != "simplefbo" ]]; then
  fail "Application project is '$app_project'; the live app is in project simplefbo"
fi
assert_contains "$(cat "$APP_FILE")" "CreateNamespace=true"
assert_contains "$rendered" "kind: StatefulSet"
assert_not_contains "$rendered" "kind: Namespace"
assert_not_contains "$rendered" "kind: ClusterRole"
assert_not_contains "$rendered" "kind: ClusterRoleBinding"
assert_not_contains "$rendered" "kind: CustomResourceDefinition"
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
# Reported: Bulwark /setup "Couldn't connect to that address" for
# https://mail.dbslone.com because the JMAP session advertised
# apiUrl https://stalwart-0/jmap/ (pod hostname) instead of the public URL.
assert_contains "$rendered" "name: STALWART_PUBLIC_URL"
assert_contains "$rendered" "value: \"https://mail.dbslone.com\""
assert_contains "$rendered" "kind: DestinationRule"
assert_contains "$rendered" "kind: PeerAuthentication"
assert_contains "$rendered" "mode: DISABLE"
assert_contains "$rendered" "name: stalwart-mail"
assert_contains "$rendered" "type: LoadBalancer"
# Reported: live spec.externalIPs is empty and hostPort never bound LAN :25.
# Mail exposure is MetalLB 10.0.1.5; copy the Istio LAN hop outside this chart.
assert_not_contains "$rendered" "externalIPs:"
assert_not_contains "$rendered" "hostPort:"
assert_not_contains "$rendered" "kubernetes.io/hostname: serv1-kube"
if grep -E '^[[:space:]]+(values:|parameters:|valuesObject:)' "$APP_FILE"; then
  fail "applications/stalwart.yaml must not set helm values/parameters overlays (they hide git chart diffs)"
fi
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

# Reported: changing resources.requests.cpu in values.yaml is not reflected
# in the ArgoCD helm chart diff. That is the bug if the StatefulSet ignores
# .Values.resources (hardcoded cpu, or values not interpolated). Render must
# match values.yaml, and --set must replace it.
values_cpu="$(awk '
  $1=="resources:" {inres=1; next}
  inres && /^[^[:space:]]/ {exit}
  inres && $1=="requests:" {inreq=1; next}
  inres && $1=="limits:" {inreq=0; next}
  inreq && $1=="cpu:" {print $2; exit}
' "$CHART/values.yaml")"
if [[ -z "$values_cpu" ]]; then
  fail "charts/stalwart/values.yaml has no resources.requests.cpu"
fi
sts_cpu="$(awk '
  $1=="kind:" && $2=="StatefulSet" {sts=1}
  sts && /^---$/ {exit}
  sts && $1=="cpu:" {print $2; exit}
' <<<"$rendered")"
if [[ "$sts_cpu" != "$values_cpu" ]]; then
  fail "reported: values.yaml cpu '$values_cpu' was not inserted into the StatefulSet (got '${sts_cpu:-empty}')"
fi
chart_ver="$(awk '$1=="version:" {print $2; exit}' "$CHART/Chart.yaml")"
assert_contains "$rendered" "helm.sh/chart: stalwart-${chart_ver}"
override_cpu="124m"
override="$(helm template stalwart "$CHART" --namespace mail --set resources.requests.cpu="$override_cpu")"
override_sts_cpu="$(awk '
  $1=="kind:" && $2=="StatefulSet" {sts=1}
  sts && /^---$/ {exit}
  sts && $1=="cpu:" {print $2; exit}
' <<<"$override")"
if [[ "$override_sts_cpu" != "$override_cpu" ]]; then
  fail "reported: --set resources.requests.cpu=$override_cpu did not appear in the StatefulSet (got '${override_sts_cpu:-empty}')"
fi
if [[ "$values_cpu" != "$override_cpu" ]]; then
  # The override render must not keep the values.yaml cpu on the StatefulSet.
  override_sts_block="$(awk '
    $1=="kind:" && $2=="StatefulSet" {sts=1}
    sts && /^---$/ {exit}
    sts {print}
  ' <<<"$override")"
  if grep -qE "^[[:space:]]+cpu:[[:space:]]+${values_cpu}$" <<<"$override_sts_block"; then
    fail "reported: StatefulSet still has values.yaml cpu '$values_cpu' after --set resources.requests.cpu=$override_cpu"
  fi
fi

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

# Default render includes credentialed CORS for Bulwark on webmail.*.
assert_contains "$rendered" "corsPolicy:"
assert_contains "$rendered" "allowCredentials: true"
assert_contains "$rendered" "https://webmail.dbslone.com"
assert_contains "$rendered" "https://webmail.simplefbo.com"
assert_contains "$rendered" "Access-Control-Allow-Origin"
assert_contains "$rendered" "if-match"

# CORS can be disabled without dropping the VirtualService.
no_cors="$(helm template stalwart "$CHART" --namespace mail --set virtualService.cors.enabled=false)"
assert_contains "$no_cors" "kind: VirtualService"
assert_contains "$no_cors" "mail.dbslone.com"
assert_not_contains "$no_cors" "corsPolicy:"
assert_not_contains "$no_cors" "webmail.dbslone.com"
assert_not_contains "$no_cors" "allowCredentials: true"

# helm lint (warning-only notes are ok; fail on errors)
if ! helm lint "$CHART" >/tmp/stalwart-helm-lint.txt 2>&1; then
  cat /tmp/stalwart-helm-lint.txt >&2
  fail "helm lint failed"
fi

echo "OK: stalwart helm templates"
