#!/usr/bin/env bash
# Reported: Helm chart doesn't show any diff to apply in ArgoCD.
# Gateway, EnvoyFilter, and VirtualServices had no helm.sh/chart labels, so a
# Chart.yaml bump produced no App Diff on the ingress objects (only the clerk
# ConfigMap label moved, if anything).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/simplefbo-api-gateway"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to run this test" >&2
  exit 1
fi

chart_ver="$(awk '$1=="version:" {print $2; exit}' "$CHART/Chart.yaml")"
export RENDERED
RENDERED="$(helm template api-gateway "$CHART" --namespace simplefbo)"

python3 - "$chart_ver" <<'PY'
import os
import sys

ver = sys.argv[1]
want = f"helm.sh/chart: gateway-{ver}"
raw = os.environ["RENDERED"]
docs = [d.strip() for d in raw.split("\n---\n") if d.strip() and "kind:" in d]
tracked = ("Gateway", "EnvoyFilter", "VirtualService", "ConfigMap")
missing = []
found = {k: 0 for k in tracked}
for doc in docs:
    kind = name = None
    in_meta = False
    meta_lines = []
    for line in doc.splitlines():
        if line.startswith("kind:"):
            kind = line.split(":", 1)[1].strip()
        if line.startswith("metadata:"):
            in_meta = True
            continue
        if in_meta and (line.startswith("spec:") or line.startswith("data:")):
            break
        if in_meta:
            meta_lines.append(line)
            if line.strip().startswith("name:"):
                name = line.split(":", 1)[1].strip()
    if kind not in tracked:
        continue
    found[kind] += 1
    if want not in "\n".join(meta_lines):
        missing.append(f"{kind}/{name or '?'}")
if found.get("Gateway", 0) < 1:
    sys.stderr.write("FAIL: expected a Gateway in the render\n")
    sys.exit(1)
if found.get("EnvoyFilter", 0) < 1:
    sys.stderr.write("FAIL: expected EnvoyFilter https-on-80 in the render\n")
    sys.exit(1)
if missing:
    sys.stderr.write(
        "FAIL: ArgoCD App Diff stays empty for these resources because they "
        f"omit {want}: " + ", ".join(missing) + "\n"
    )
    sys.exit(1)
print(
    f"OK: helm.sh/chart gateway-{ver} on Gateway, EnvoyFilter, VirtualService, ConfigMap"
)
PY
