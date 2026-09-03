#!/usr/bin/env bash
# Index packaged charts in temp/ for the gh-pages helm repo.
# When temp/ is missing or has no .tgz (Chart.yaml-only checkout), skip.
# The old inline `helm repo index ./temp` failed with:
#   Error: open .../src/temp/index.yaml: no such file or directory
set -euo pipefail

TEMP_DIR="${TEMP_DIR:-./temp}"
DEST_DIR="${DEST_DIR:-../dest}"
DEST_INDEX="${DEST_INDEX:-$DEST_DIR/index.yaml}"
HELM_REPO_URL="${HELM_REPO_URL:?HELM_REPO_URL is required}"

shopt -s nullglob
packages=("$TEMP_DIR"/*.tgz)
if [[ ! -d "$TEMP_DIR" ]] || [[ ${#packages[@]} -eq 0 ]]; then
  echo "SKIP: no packaged charts in $TEMP_DIR; not running helm repo index"
  exit 0
fi

mkdir -p "$DEST_DIR/helm" ./helm/

if [[ -f "$DEST_INDEX" ]]; then
  helm repo index "$TEMP_DIR" --merge "$DEST_INDEX" --url "$HELM_REPO_URL"
else
  helm repo index "$TEMP_DIR" --url "$HELM_REPO_URL"
fi

shopt -s extglob
cp -pr "$TEMP_DIR"/!(index.yaml) "$DEST_DIR/helm/"
cp -pr "$TEMP_DIR"/!(index.yaml) ./helm/
cp -pr "$TEMP_DIR/index.yaml" "$DEST_DIR/"
echo "Published helm index from ${#packages[@]} package(s)"
