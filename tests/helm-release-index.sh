#!/usr/bin/env bash
# Reported issue: Release Helm Charts fails with
#   helm repo index ./temp --merge ../dest/index.yaml --url ...
#   Error: open .../src/temp/index.yaml: no such file or directory
#
# That happens when the job runs without packaged charts in temp/
# (for example a Chart.yaml-only push). The workflow must skip indexing
# instead of calling helm repo index on a missing temp/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/helm.yaml"
SCRIPT="$ROOT/scripts/release-helm-index.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [[ ! -f "$WF" ]]; then
  fail "missing $WF"
fi

if grep -qF "charts/simplefbo-api-gateway/Chart.yaml" "$WF"; then
  fail "Release Helm Charts ran on a Chart.yaml bump with no temp/ and failed: open .../src/temp/index.yaml: no such file or directory. Do not trigger on Chart.yaml; only temp/** (packaged charts) or workflow_dispatch"
fi

if grep -q "helm repo index ./temp" "$WF" && ! grep -q "release-helm-index.sh" "$WF"; then
  fail "helm.yaml still inlines helm repo index ./temp; that errors with no such file or directory when temp/ is missing. Use scripts/release-helm-index.sh"
fi

if [[ ! -x "$SCRIPT" && ! -f "$SCRIPT" ]]; then
  fail "missing $SCRIPT (indexes temp/ or skips when it is empty)"
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to run this test" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src" "$work/dest"
# Repo checkout has charts but no temp/ — the reported GitHub Actions layout.
cp "$SCRIPT" "$work/src/release-helm-index.sh"
chmod +x "$work/src/release-helm-index.sh"

# The buggy command (what CI ran) must be the reported error.
set +e
err="$(
  cd "$work/src"
  helm repo index ./temp --merge ../dest/index.yaml --url https://example.invalid/helm/ 2>&1
)"
old_rc=$?
set -e
if [[ "$old_rc" -eq 0 ]]; then
  fail "expected helm repo index ./temp to fail without temp/, matching the Actions error"
fi
if ! grep -q 'no such file or directory' <<<"$err" || ! grep -q 'temp/index.yaml' <<<"$err"; then
  fail "expected the reported error 'temp/index.yaml: no such file or directory', got: $err"
fi

# Fixed script: empty src (no temp/) must exit 0 and not print that error.
out="$(
  cd "$work/src"
  HELM_REPO_URL=https://example.invalid/helm/ DEST_INDEX=../dest/index.yaml \
    ./release-helm-index.sh 2>&1
)" || fail "release-helm-index.sh exited $? on missing temp/; must skip. output: $out"
if grep -q 'no such file or directory' <<<"$out"; then
  fail "release-helm-index.sh still reported a missing file on empty temp/: $out"
fi
if ! grep -qi 'skip' <<<"$out"; then
  fail "expected a skip message when temp/ has no packaged charts, got: $out"
fi

# With a packaged chart, index.yaml is written (no merge file required).
mkdir -p "$work/src/temp"
helm package "$ROOT/charts/simplefbo-api-gateway" -d "$work/src/temp" >/dev/null
out="$(
  cd "$work/src"
  HELM_REPO_URL=https://example.invalid/helm/ DEST_INDEX=../dest/index.yaml \
    ./release-helm-index.sh 2>&1
)" || fail "release-helm-index.sh failed with a packaged chart: $out"
if [[ ! -f "$work/src/temp/index.yaml" ]]; then
  fail "expected temp/index.yaml after indexing a packaged chart"
fi
if [[ ! -f "$work/dest/index.yaml" ]]; then
  fail "expected dest/index.yaml to be copied for gh-pages"
fi

echo "OK: helm release index skips missing temp/ (no temp/index.yaml error)"
