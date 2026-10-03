#!/usr/bin/env bash
# Reported: https://graph.dbslone.com/login stays on the "Welcome to Grafana"
# screen. Grafana's own form is off, so that page has nothing to submit.
# /login must redirect to / instead of rendering the welcome screen.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/simplefbo-api-gateway"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to run this test" >&2
  exit 1
fi

RENDERED="$(helm template api-gateway "$CHART" --namespace simplefbo)"

RENDERED="$RENDERED" python3 - <<'PY'
import os
import sys

raw = os.environ["RENDERED"]
docs = [d.strip() for d in raw.split("\n---\n") if d.strip() and "kind:" in d]
grafana = None
for doc in docs:
    if "kind: VirtualService" in doc and "name: grafana-ui" in doc:
        grafana = doc
        break

if grafana is None:
    sys.stderr.write(
        "FAIL: graph.dbslone.com/login stays on Welcome to Grafana because "
        "VirtualService grafana-ui was not rendered\n"
    )
    sys.exit(1)

# The login route has to be a redirect that appears before the catch-all
# route to Grafana. Otherwise the browser renders the empty welcome screen.
lines = grafana.splitlines()
redirect_at = None
route_at = None
for i, line in enumerate(lines):
    if line.strip() == "redirect:" and redirect_at is None:
        redirect_at = i
    if line.strip() in ("route:", "- route:") and route_at is None:
        route_at = i

window = "\n".join(lines[max(0, (redirect_at or 0) - 8):(redirect_at or 0) + 6])
if redirect_at is None or "exact: /login" not in window or "uri: /" not in window:
    sys.stderr.write(
        "FAIL: graph.dbslone.com/login is stuck on the Welcome to Grafana "
        "screen because /login is not redirected to /\n"
    )
    sys.exit(1)

if route_at is None or redirect_at > route_at:
    sys.stderr.write(
        "FAIL: graph.dbslone.com/login is stuck on the Welcome to Grafana "
        "screen because the /login redirect is after the Grafana route\n"
    )
    sys.exit(1)

print("OK: graph.dbslone.com/login redirects home instead of the Welcome to Grafana screen")
PY
