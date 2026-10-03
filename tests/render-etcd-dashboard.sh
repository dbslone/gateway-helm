#!/usr/bin/env bash
# The spinning-disk outage starts with a slow etcd WAL fsync. A dashboard that
# does not chart that duration would miss the failure until Patroni drops its
# lock and Postgres is already unreachable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/simplefbo-api-gateway"
DASHBOARD="$CHART/dashboards/etcd-disk.json"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to run this test" >&2
  exit 1
fi

python3 - "$DASHBOARD" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as fh:
    dash = json.load(fh)

blob = json.dumps(dash)
required = [
    "etcd_disk_wal_fsync_duration_seconds_bucket",
    "etcd_disk_backend_commit_duration_seconds_bucket",
    "etcd_request_duration_seconds_bucket",
    "apiserver_request_duration_seconds_bucket",
    "etcd_server_has_leader",
    "Patroni",
]
missing = [item for item in required if item not in blob]
if missing:
    sys.stderr.write(
        "FAIL: the etcd dashboard would miss the spinning-disk failure "
        "because it does not chart: %s\n" % ", ".join(missing)
    )
    sys.exit(1)

if '"value": 0.01' not in blob:
    sys.stderr.write(
        "FAIL: the etcd dashboard would miss a slow spinning disk because "
        "WAL fsync is not marked at etcd's 10ms warning\n"
    )
    sys.exit(1)

if dash.get("uid") != "etcd-disk":
    sys.stderr.write(
        "FAIL: the etcd dashboard uid is %r, expected etcd-disk\n" % dash.get("uid")
    )
    sys.exit(1)
PY

default_render="$(helm template api-gateway "$CHART" --namespace simplefbo)"
disabled="$(helm template api-gateway "$CHART" --namespace simplefbo --set etcdDashboard.enabled=false)"

if grep -qF "name: etcd-disk-grafana-dashboard" <<<"$disabled"; then
  echo "FAIL: etcdDashboard.enabled=false still rendered the etcd dashboard ConfigMap" >&2
  exit 1
fi

ETCD_CM="$default_render" python3 - <<'PY'
import os
import sys

raw = os.environ["ETCD_CM"]
docs = [d.strip() for d in raw.split("\n---\n") if d.strip() and "kind:" in d]
cm = None
for doc in docs:
    if "kind: ConfigMap" not in doc:
        continue
    if "name: etcd-disk-grafana-dashboard" in doc:
        cm = doc
        break

if cm is None:
    sys.stderr.write(
        "FAIL: Grafana cannot show the etcd disk dashboard because "
        "ConfigMap etcd-disk-grafana-dashboard was not rendered\n"
    )
    sys.exit(1)

for needle, why in (
    ("namespace: monitoring", "it is not created in the monitoring namespace Grafana watches"),
    ("grafana_dashboard: \"1\"", "it is missing the grafana_dashboard label the sidecar selects"),
    ("grafana_folder: etcd", "it is missing the folder annotation"),
    ("etcd_disk_wal_fsync_duration_seconds_bucket", "the WAL fsync query is not in the ConfigMap"),
):
    if needle not in cm:
        sys.stderr.write(
            "FAIL: Grafana cannot show the etcd disk dashboard because %s\n" % why
        )
        sys.exit(1)

print("OK: etcd disk dashboard ConfigMap charts WAL fsync and is labeled for Grafana")
PY
