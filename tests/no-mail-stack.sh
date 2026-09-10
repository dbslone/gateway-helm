#!/usr/bin/env bash
# Stalwart (and Bulwark, its JMAP webmail) are no longer part of this
# deployment. This fails if those charts, ArgoCD apps, or CI jobs come back.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

must_be_gone() {
  local path="$1"
  if [[ -e "$ROOT/$path" ]]; then
    fail "$path is still in gateway-helm; Stalwart/Bulwark were removed from the deployment"
  fi
}

must_be_gone charts/stalwart
must_be_gone charts/bulwark
must_be_gone applications/stalwart.yaml
must_be_gone applications/bulwark.yaml
must_be_gone tests/render-stalwart.sh
must_be_gone tests/render-bulwark.sh

wf="$ROOT/.github/workflows/helm-templates.yml"
if [[ ! -f "$wf" ]]; then
  fail "missing $wf"
fi
if grep -Eq 'render-stalwart|render-bulwark|charts/stalwart|charts/bulwark' "$wf"; then
  fail "helm-templates.yml still references the mail stack charts"
fi

readme="$ROOT/README.md"
if [[ -f "$readme" ]] && grep -Eq 'charts/stalwart|charts/bulwark|applications/stalwart|applications/bulwark' "$readme"; then
  fail "README.md still documents the mail stack charts"
fi

echo "OK: Stalwart and Bulwark are not in the gateway-helm deployment"
