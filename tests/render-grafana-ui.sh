#!/usr/bin/env bash
# graph.dbslone.com must route to the live Grafana Service through the
# existing Istio Gateway. A missing VirtualService, the wrong Service, or a
# Gateway that does not exist is a 404.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/simplefbo-api-gateway"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to run this test" >&2
  exit 1
fi

default_render="$(helm template api-gateway "$CHART" --namespace simplefbo)"
disabled="$(helm template api-gateway "$CHART" --namespace simplefbo --set grafanaUi.enabled=false)"

if grep -qF "name: grafana-ui" <<<"$disabled"; then
  echo "FAIL: grafanaUi.enabled=false still rendered VirtualService grafana-ui" >&2
  exit 1
fi

GRAFANA_VS="$default_render" python3 - <<'PY'
import os
import sys

raw = os.environ["GRAFANA_VS"]
docs = [d.strip() for d in raw.split("\n---\n") if d.strip() and "kind:" in d]
grafana = None
for doc in docs:
    if "kind: VirtualService" not in doc:
        continue
    if "name: grafana-ui" in doc:
        grafana = doc
        break

if grafana is None:
    sys.stderr.write(
        "FAIL: visiting graph.dbslone.com cannot show Grafana because "
        "VirtualService grafana-ui was not rendered\n"
    )
    sys.exit(1)

if "graph.dbslone.com" not in grafana:
    sys.stderr.write(
        "FAIL: visiting graph.dbslone.com cannot show Grafana because "
        "the VirtualService does not list that host\n"
    )
    sys.exit(1)

if "grafana.monitoring.svc.cluster.local" not in grafana:
    sys.stderr.write(
        "FAIL: visiting graph.dbslone.com cannot show Grafana because "
        "the VirtualService does not route to grafana.monitoring\n"
    )
    sys.exit(1)

if "number: 80" not in grafana:
    sys.stderr.write(
        "FAIL: visiting graph.dbslone.com cannot show Grafana because "
        "the VirtualService does not target service port 80\n"
    )
    sys.exit(1)

gateways = []
in_gateways = False
for line in grafana.splitlines():
    stripped = line.strip()
    if stripped == "gateways:":
        in_gateways = True
        continue
    if in_gateways:
        if stripped.startswith("- "):
            gateways.append(stripped[2:].strip().strip('"').strip("'"))
            continue
        if stripped and not stripped.startswith("#"):
            break

if gateways != ["istio-ingress/api-gateway"]:
    sys.stderr.write(
        "FAIL: visiting graph.dbslone.com cannot show Grafana because "
        "the VirtualService is not bound only to istio-ingress/api-gateway "
        "(got: %s)\n" % (gateways or ["<none>"])
    )
    sys.exit(1)

print("OK: graph.dbslone.com Grafana VirtualService binds istio-ingress/api-gateway")
PY
