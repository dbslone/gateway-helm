#!/usr/bin/env bash
# Reported issue: https://webmail.dbslone.com/setup returns Cloudflare error 520
# after the Bulwark chart (0.1.1) and gateway cleanup were applied on the cluster.
#
# Cluster path is healthy: LAN Istio serves /setup as 200 and / as 307. Cloudflare
# still 520s because Kemp (192.168.7.184) delivers a non-HTTP payload
# (NO_REQUEST_LINE_IN_REQUEST). Mail from the same Kemp IP arrives as HTTP GET
# with Host: mail.dbslone.com.
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

# Gateway chart must not install a webmail-only EnvoyFilter; mail/vault do not
# have one, and TLS-on-:80 did not stop Cloudflare 520.
gw_rendered="$(helm template gateway "$GW_CHART" --namespace istio-ingress)"
if grep -q 'kind: EnvoyFilter' <<<"$gw_rendered"; then
  fail "simplefbo-api-gateway must not render an EnvoyFilter (mail/vault use the Gateway as-is; https-on-80 did not clear the 520)"
fi
if grep -q 'httpsOnHttpPort' "$GW_CHART/values.yaml"; then
  fail "httpsOnHttpPort must not remain in gateway values (it was webmail-only and did not match other services)"
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
    docs = []
    for chunk in raw.split("\n---\n"):
        if "kind: VirtualService" not in chunk:
            continue
        docs.append(chunk)
    return docs

bw_vs = vs_docs(bw)
st_vs = vs_docs(st)
if len(bw_vs) != 1:
    sys.stderr.write(f"FAIL: expected exactly 1 Bulwark VirtualService, got {len(bw_vs)}\n")
    sys.exit(1)
if len(st_vs) < 1:
    sys.stderr.write("FAIL: expected Stalwart VirtualService to compare gateway binding\n")
    sys.exit(1)

b, s = bw_vs[0], st_vs[0]
if "namespace: mail" not in b:
    sys.stderr.write(
        "FAIL: Bulwark VirtualService must set metadata.namespace: mail so "
        "helm template | kubectl apply cannot land in default (that leftover "
        "VS bound webmail to api-gateway-https-on-80)\n"
    )
    sys.exit(1)
if "istio-ingress/api-gateway" not in b:
    sys.stderr.write("FAIL: Bulwark VirtualService must bind istio-ingress/api-gateway like mail/vault\n")
    sys.exit(1)
if "api-gateway-https-on-80" in b:
    sys.stderr.write(
        "FAIL: Bulwark VirtualService must not bind api-gateway-https-on-80 "
        "(that Gateway does not exist; mail/vault do not use it)\n"
    )
    sys.exit(1)
if "bulwark.mail.svc.cluster.local" not in b:
    sys.stderr.write("FAIL: Bulwark VirtualService destination must be bulwark.mail.svc.cluster.local\n")
    sys.exit(1)
if "webmail.dbslone.com" not in b:
    sys.stderr.write("FAIL: Bulwark VirtualService must list webmail.dbslone.com (the host that 520s)\n")
    sys.exit(1)
# Same gateway as Stalwart — not a second listener or extra Gateway.
if "istio-ingress/api-gateway" not in s:
    sys.stderr.write("FAIL: Stalwart comparison VirtualService missing istio-ingress/api-gateway\n")
    sys.exit(1)
gateways = [ln.strip() for ln in b.splitlines() if ln.strip().startswith("- istio-ingress/")]
if gateways != ["- istio-ingress/api-gateway"]:
    sys.stderr.write(f"FAIL: Bulwark gateways must be only api-gateway like Stalwart, got {gateways}\n")
    sys.exit(1)
PY

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required to probe $URL"
fi

if [[ "${SKIP_WEBMAIL_LIVE:-}" == "1" ]]; then
  echo "OK: Bulwark VS matches Stalwart gateway binding (live $URL probe skipped)"
  exit 0
fi

tmp="$(mktemp)"
status="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 25 -A 'Mozilla/5.0' "$URL" || true)"
body="$(head -c 200 "$tmp" | tr '\n' ' ')"
rm -f "$tmp"

if [[ "$status" == "520" ]] || grep -qi 'error code: 520' <<<"$body"; then
  fail "$URL returned Cloudflare 520. After chart sync, Istio still never sees HTTP Host webmail.dbslone.com or path /setup (NO_REQUEST_LINE_IN_REQUEST from Kemp 192.168.7.184). LAN https://webmail.dbslone.com/setup is 200. Got status=$status body=$body"
fi

if [[ ! "$status" =~ ^(200|301|302|303|307|308)$ ]]; then
  fail "$URL expected Bulwark setup (2xx/3xx), got HTTP $status body=$body"
fi

echo "OK: webmail origin $URL -> HTTP $status"
