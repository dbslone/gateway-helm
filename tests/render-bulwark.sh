#!/usr/bin/env bash
# Render the Bulwark chart and assert ArgoCD-ready defaults.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/bulwark"
APP_FILE="$ROOT/applications/bulwark.yaml"
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

if [[ ! -f "$APP_FILE" ]]; then
  fail "missing ArgoCD Application manifest: $APP_FILE"
fi
app_name="$(awk '$1=="name:" {print $2; exit}' "$APP_FILE")"
release_name="$(awk '$1=="releaseName:" {print $2; exit}' "$APP_FILE")"
if [[ -z "$release_name" ]]; then
  fail "applications/bulwark.yaml must set spec.source.helm.releaseName so ArgoCD does not pass the UI Application name (e.g. Bulwark) to helm --name-template"
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
if helm template Bulwark "$CHART" --namespace mail >/tmp/bulwark-helm-bad-release.txt 2>&1; then
  fail "helm accepted release name 'Bulwark'; expected the invalid-release-name error ArgoCD reported"
fi
if ! grep -q 'invalid release name' /tmp/bulwark-helm-bad-release.txt; then
  fail "expected helm to reject 'Bulwark' as an invalid release name"
fi

rendered="$(helm template bulwark "$CHART" --namespace mail)"

app_project="$(awk '$1=="project:" {print $2; exit}' "$APP_FILE")"
if [[ "$app_project" != "simplefbo" ]]; then
  fail "Application project is '$app_project'; the live app is in project simplefbo"
fi
assert_contains "$(cat "$APP_FILE")" "CreateNamespace=true"
assert_contains "$rendered" "kind: Deployment"
assert_not_contains "$rendered" "kind: Namespace"
assert_not_contains "$rendered" "kind: ClusterRole"
assert_not_contains "$rendered" "kind: ClusterRoleBinding"
assert_not_contains "$rendered" "kind: CustomResourceDefinition"
assert_contains "$rendered" "sidecar.istio.io/inject: \"false\""
assert_contains "$rendered" "image: \"ghcr.io/bulwarkmail/webmail:1.9.2\""
assert_contains "$rendered" "secretKeyRef:"
assert_contains "$rendered" "name: bulwark-session"
assert_contains "$rendered" "key: SESSION_SECRET"
assert_not_contains "$rendered" "kind: Secret"
assert_contains "$rendered" "kind: VirtualService"
assert_contains "$rendered" "istio-ingress/api-gateway"
assert_not_contains "$rendered" "api-gateway-https-on-80"
assert_contains "$rendered" "webmail.dbslone.com"
assert_contains "$rendered" "webmail.simplefbo.com"
assert_contains "$rendered" "kind: DestinationRule"
assert_contains "$rendered" "kind: PeerAuthentication"
assert_contains "$rendered" "mode: DISABLE"
# Same Gateway binding as Stalwart; do not hardcode metadata.namespace (ArgoCD destination mail).
st_rendered="$(helm template stalwart "$ROOT/charts/stalwart" --namespace mail)"
export BW_RENDERED="$rendered"
export ST_RENDERED="$st_rendered"
python3 <<'PY'
import os
import sys

def vs_docs(raw):
    return [c for c in raw.split("\n---\n") if "kind: VirtualService" in c]

def gateways(vs):
    lines = vs.splitlines()
    out = []
    in_gw = False
    for ln in lines:
        s = ln.strip()
        if s.startswith("gateways:"):
            in_gw = True
            continue
        if in_gw:
            if s.startswith("- "):
                out.append(s)
                continue
            if s and not s.startswith("#"):
                break
    return out

def metadata_has_namespace(vs):
    in_meta = False
    for ln in vs.splitlines():
        if ln.startswith("metadata:"):
            in_meta = True
            continue
        if in_meta:
            if ln.startswith("spec:") or ln.startswith("data:"):
                break
            if ln.strip().startswith("namespace:"):
                return True
    return False

bw_vs, st_vs = vs_docs(os.environ["BW_RENDERED"]), vs_docs(os.environ["ST_RENDERED"])
if len(bw_vs) != 1:
    sys.stderr.write(f"FAIL: expected exactly 1 Bulwark VirtualService, got {len(bw_vs)}\n")
    sys.exit(1)
if not st_vs:
    sys.stderr.write("FAIL: expected a Stalwart VirtualService to compare gateways\n")
    sys.exit(1)
b, s = bw_vs[0], st_vs[0]
if metadata_has_namespace(b):
    sys.stderr.write("FAIL: Bulwark VirtualService must not hardcode metadata.namespace (match Stalwart)\n")
    sys.exit(1)
bg, sg = gateways(b), gateways(s)
want = ["- istio-ingress/api-gateway"]
if bg != want:
    sys.stderr.write(f"FAIL: Bulwark gateways must be only api-gateway, got {bg}\n")
    sys.exit(1)
if sg != want:
    sys.stderr.write(f"FAIL: Stalwart gateways must be only api-gateway, got {sg}\n")
    sys.exit(1)
if "bulwark.mail.svc.cluster.local" not in b:
    sys.stderr.write("FAIL: destination must be bulwark.mail.svc.cluster.local\n")
    sys.exit(1)
PY
assert_contains "$rendered" "kind: PersistentVolumeClaim"
assert_contains "$rendered" "storage: \"1Gi\""
assert_contains "$rendered" "path: /api/health"
assert_contains "$rendered" "name: JMAP_SERVERS"
assert_contains "$rendered" "https://mail.dbslone.com"
assert_contains "$rendered" "https://mail.simplefbo.com"
assert_contains "$rendered" "JMAP_SERVER_AUTO_PICK_BY_DOMAIN"
assert_contains "$rendered" "STALWART_FEATURES"
assert_contains "$rendered" "SETTINGS_SYNC_ENABLED"
assert_not_contains "$rendered" "JMAP_SERVER_URL"
# Browser talks to public mail hosts; a cluster Service URL would fail in the client.
if grep -q 'JMAP_SERVERS' <<<"$rendered" && grep -q 'svc.cluster.local' <<<"$(awk '
  $1=="name:" && $2=="JMAP_SERVERS" {keep=1}
  keep && $1=="value:" {print; exit}
' <<<"$rendered")"; then
  fail "JMAP_SERVERS must be a public URL, not a cluster Service name"
fi
assert_contains "$rendered" "automountServiceAccountToken: false"
assert_not_contains "$rendered" "NET_BIND_SERVICE"

if grep -E '^[[:space:]]+(values:|parameters:|valuesObject:)' "$APP_FILE"; then
  fail "applications/bulwark.yaml must not set helm values/parameters overlays (they hide git chart diffs)"
fi

chart_ver="$(awk '$1=="version:" {print $2; exit}' "$CHART/Chart.yaml")"
assert_contains "$rendered" "helm.sh/chart: bulwark-${chart_ver}"

# Chart-managed session secret when no existingSecret is provided.
with_secret="$(helm template bulwark "$CHART" --namespace mail \
  --set session.existingSecret= \
  --set session.secret=test-session-secret)"
assert_contains "$with_secret" "kind: Secret"
assert_contains "$with_secret" "SESSION_SECRET: \"test-session-secret\""
assert_contains "$with_secret" "name: bulwark-session"

# Istio VS can be disabled independently.
no_vs="$(helm template bulwark "$CHART" --namespace mail --set virtualService.enabled=false)"
assert_not_contains "$no_vs" "kind: VirtualService"
assert_not_contains "$no_vs" "kind: DestinationRule"
assert_not_contains "$no_vs" "kind: PeerAuthentication"
assert_contains "$no_vs" "kind: Deployment"

# helm lint (warning-only notes are ok; fail on errors)
if ! helm lint "$CHART" >/tmp/bulwark-helm-lint.txt 2>&1; then
  cat /tmp/bulwark-helm-lint.txt >&2
  fail "helm lint failed"
fi

echo "OK: bulwark helm templates"
