#!/usr/bin/env bash
# Reported issue: https://webmail.dbslone.com/setup returns Cloudflare 520.
#
# Kemp sends a TLS ClientHello to Istio HTTP :80 for webmail (mail is HTTP on
# the same port). Envoy's HTTP codec then fails with NO_REQUEST_LINE_IN_REQUEST.
# The gateway chart must terminate TLS on :80 and pin the HTTP chain to
# raw_buffer so a ClientHello cannot match the match-all HTTP chain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GW_CHART="$ROOT/charts/simplefbo-api-gateway"
BW_CHART="$ROOT/charts/bulwark"
ST_CHART="$ROOT/charts/stalwart"
URL="${WEBMAIL_URL:-https://webmail.dbslone.com/setup}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to run this test" >&2
  exit 1
fi

gw_rendered="$(helm template gateway "$GW_CHART" --namespace istio-ingress)"
echo "$gw_rendered" | grep -q 'kind: EnvoyFilter' || fail "expected EnvoyFilter https-on-80 (Helm must terminate Kemp TLS on :80 or /setup 520s)"
echo "$gw_rendered" | grep -q 'name: https-on-80' || fail "expected EnvoyFilter metadata.name https-on-80"
echo "$gw_rendered" | grep -q 'transport_protocol: tls' || fail "expected TLS filter chain on :80"
echo "$gw_rendered" | grep -q 'transport_protocol: raw_buffer' || fail "HTTP :80 chain must match raw_buffer only (match-all HTTP chain is the 520: ClientHello hits the HTTP codec)"
echo "$gw_rendered" | grep -q 'envoy.filters.listener.http_inspector' || fail "expected http_inspector so non-HTTP Kemp payloads do not use the HTTP codec"
echo "$gw_rendered" | grep -q 'default_filter_chain:' || fail "expected default_filter_chain TLS so unclassified :80 bytes are terminated as TLS (the 520)"
echo "$gw_rendered" | grep -q 'http/1.1' || fail "HTTP :80 chain must require application_protocols http/1.1"
echo "$gw_rendered" | grep -q 'envoy.filters.listener.tls_inspector' || fail "expected tls_inspector on :80"
echo "$gw_rendered" | grep -q 'envoy.filters.listener.proxy_protocol' || fail "expected optional PROXY protocol (Kemp may prepend it)"
echo "$gw_rendered" | grep -q 'allow_requests_without_proxy_protocol: true' || fail "PROXY must be optional so mail HTTP :80 still works"
echo "$gw_rendered" | grep -q 'kubernetes://simplefbo-cf-tls' || fail "expected origin cert SDS kubernetes://simplefbo-cf-tls on the :80 TLS chain"
if ! grep -q 'httpsOnHttpPort:' "$GW_CHART/values.yaml"; then
  fail "httpsOnHttpPort must be enabled in gateway values so ArgoCD applies the filter"
fi

bw="$(helm template bulwark "$BW_CHART" --namespace mail)"
st="$(helm template stalwart "$ST_CHART" --namespace mail)"
export BW_RENDERED="$bw"
export ST_RENDERED="$st"
python3 <<'PY'
import os
import sys

bw, st = os.environ["BW_RENDERED"], os.environ["ST_RENDERED"]

def vs_docs(raw):
    return [c for c in raw.split("\n---\n") if "kind: VirtualService" in c]

bw_vs, st_vs = vs_docs(bw), vs_docs(st)
if len(bw_vs) != 1:
    sys.stderr.write(f"FAIL: expected exactly 1 Bulwark VirtualService, got {len(bw_vs)}\n")
    sys.exit(1)
b, s = bw_vs[0], st_vs[0]
if "namespace: mail" not in b:
    sys.stderr.write("FAIL: Bulwark VirtualService must set metadata.namespace: mail\n")
    sys.exit(1)
if "istio-ingress/api-gateway" not in b or "istio-ingress/api-gateway" not in s:
    sys.stderr.write("FAIL: Bulwark and Stalwart must bind istio-ingress/api-gateway\n")
    sys.exit(1)
if "api-gateway-https-on-80" in b:
    sys.stderr.write("FAIL: Bulwark VirtualService must not bind api-gateway-https-on-80\n")
    sys.exit(1)
if "bulwark.mail.svc.cluster.local" not in b:
    sys.stderr.write("FAIL: destination must be bulwark.mail.svc.cluster.local\n")
    sys.exit(1)
if "webmail.dbslone.com" not in b:
    sys.stderr.write("FAIL: VirtualService must list webmail.dbslone.com\n")
    sys.exit(1)
gateways = [ln.strip() for ln in b.splitlines() if ln.strip().startswith("- istio-ingress/")]
if gateways != ["- istio-ingress/api-gateway"]:
    sys.stderr.write(f"FAIL: Bulwark gateways must be only api-gateway, got {gateways}\n")
    sys.exit(1)
PY

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required to probe $URL"
fi

if [[ "${SKIP_WEBMAIL_LIVE:-}" == "1" ]]; then
  echo "OK: helm assertions for TLS-on-:80 raw_buffer (live $URL probe skipped)"
  exit 0
fi

tmp="$(mktemp)"
status="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 25 -A 'Mozilla/5.0' "$URL" || true)"
body="$(head -c 200 "$tmp" | tr '\n' ' ')"
rm -f "$tmp"

if [[ "$status" == "520" ]] || grep -qi 'error code: 520' <<<"$body"; then
  fail "$URL returned Cloudflare 520 (Kemp TLS ClientHello still hitting Istio HTTP codec). Got status=$status body=$body"
fi

if [[ ! "$status" =~ ^(200|301|302|303|307|308)$ ]]; then
  fail "$URL expected Bulwark setup (2xx/3xx), got HTTP $status body=$body"
fi

echo "OK: webmail origin $URL -> HTTP $status"
