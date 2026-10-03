#!/usr/bin/env bash
# Reported: clicking Sign in on graph.dbslone.com returns to the same screen.
# The Sign in button opens /login. Redirecting that URL to / is the loop.
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
        "FAIL: clicking Sign in goes back to the same screen because "
        "VirtualService grafana-ui was not rendered\n"
    )
    sys.exit(1)

if "exact: /login" in grafana and "redirect:" in grafana:
    sys.stderr.write(
        "FAIL: clicking Sign in goes back to the same screen because "
        "/login redirects to /\n"
    )
    sys.exit(1)

if "grafana.monitoring.svc.cluster.local" not in grafana:
    sys.stderr.write(
        "FAIL: clicking Sign in goes back to the same screen because "
        "/login is not routed to Grafana\n"
    )
    sys.exit(1)

print("OK: graph.dbslone.com/login is served by Grafana instead of bouncing home")
PY
