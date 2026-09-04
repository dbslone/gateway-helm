#!/usr/bin/env bash
# Reported issue: https://webmail.dbslone.com returns Cloudflare error 520
# (origin closed the connection without a valid HTTP response).
#
# Cloudflare Full SSL sends a TLS ClientHello. Kemp forwards that (often with a
# PROXY header) to Istio :80 and/or :443 for hostnames without an SSL vhost.
# :80 HTTP codec → NO_REQUEST_LINE_IN_REQUEST; :443 + PROXY → TLS alert
# protocol_version. Cloudflare surfaces either as 520.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/simplefbo-api-gateway"
URL="${WEBMAIL_URL:-https://webmail.dbslone.com/}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to run this test" >&2
  exit 1
fi

rendered="$(helm template gateway "$CHART" --namespace istio-ingress)"

# Istio refuses HTTP+HTTPS on Gateway port 80, so TLS-on-:80 is an EnvoyFilter
# that terminates a ClientHello instead of parsing it as HTTP/1.1 (the 520).
echo "$rendered" | grep -q 'kind: EnvoyFilter' || fail "expected EnvoyFilter for TLS-on-:80"
echo "$rendered" | grep -q 'name: https-on-80' || fail "expected EnvoyFilter metadata.name https-on-80"
echo "$rendered" | grep -q 'transport_protocol: tls' || fail "expected TLS filter chain match on :80"
echo "$rendered" | grep -q 'envoy.filters.listener.tls_inspector' || fail "expected tls_inspector on :80 so HTTP and TLS can share the port"
echo "$rendered" | grep -q 'envoy.filters.listener.proxy_protocol' || fail "expected optional PROXY protocol (Kemp prepends it; without it TLS-on-:80/:443 still 520s)"
echo "$rendered" | grep -q 'allow_requests_without_proxy_protocol: true' || fail "PROXY protocol must be optional so LAN/non-Kemp HTTP still works"
echo "$rendered" | grep -q 'kubernetes://simplefbo-cf-tls' || fail "expected origin cert SDS kubernetes://simplefbo-cf-tls on the :80 TLS chain"
# Kemp catch-all sends PROXY+TLS to :443 (LAN :443 without PROXY returns 307 for
# webmail; PROXY+TLS on :443 used to TLS-alert → Cloudflare 520).
python3 -c '
import sys
text = sys.stdin.read()
if "portNumber: 443" not in text:
    sys.stderr.write("FAIL: EnvoyFilter must match listener port 443 so PROXY+TLS from Kemp does not 520\n")
    sys.exit(1)
# The 443 patch must be proxy_protocol, not only the :80 TLS chain.
idx = text.find("portNumber: 443")
window = text[max(0, idx-400): idx+400]
if "envoy.filters.listener.proxy_protocol" not in window and "ProxyProtocol" not in window:
    sys.stderr.write("FAIL: port 443 EnvoyFilter patch must insert optional PROXY protocol\n")
    sys.exit(1)
' <<<"$rendered" || fail "expected optional PROXY protocol on :443 (PROXY+TLS there TLS-alerts and Cloudflare 520s)"
if ! grep -q 'webmail.dbslone.com' "$CHART/values.yaml"; then
  fail "httpsOnHttpPort must list webmail.dbslone.com (the host that returned Cloudflare 520)"
fi

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required to probe $URL"
fi

if [[ "${SKIP_WEBMAIL_LIVE:-}" == "1" ]]; then
  echo "OK: helm assertions for TLS-on-:80 and PROXY on :443 (live $URL probe skipped)"
  exit 0
fi

tmp="$(mktemp)"
status="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 25 -A 'Mozilla/5.0' "$URL" || true)"
body="$(head -c 200 "$tmp" | tr '\n' ' ')"
rm -f "$tmp"

if [[ "$status" == "520" ]] || grep -qi 'error code: 520' <<<"$body"; then
  fail "$URL returned Cloudflare 520 (Kemp sent a non-HTTP payload to Istio :80, or PROXY+TLS to :443 without the proxy_protocol filter). Got status=$status body=$body"
fi

if [[ ! "$status" =~ ^(200|301|302|303|307|308)$ ]]; then
  fail "$URL expected a browser-loadable 2xx/3xx from Bulwark, got HTTP $status body=$body"
fi

echo "OK: webmail origin $URL -> HTTP $status"
