#!/usr/bin/env bash
# GitHub removes Node 20 from Actions runners on 2026-09-23. Workflows that
# still run JavaScript actions on Node 20 fail after that date. gateway-helm
# CI must force Node 24 and must not pin azure/setup-helm@v1.1 (Node 20 era).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF_DIR="$ROOT/.github/workflows"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

shopt -s nullglob
workflows=("$WF_DIR"/*.yml "$WF_DIR"/*.yaml)
if [[ ${#workflows[@]} -eq 0 ]]; then
  fail "no GitHub Actions workflows under .github/workflows"
fi

for wf in "${workflows[@]}"; do
  rel="${wf#"$ROOT/"}"
  text="$(cat "$wf")"

  if grep -q 'ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION' <<<"$text"; then
    fail "$rel opts back into Node 20 (ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION); GitHub removes Node 20 on 2026-09-23"
  fi

  if ! grep -q 'FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true' <<<"$text"; then
    fail "$rel still runs JavaScript actions on Node 20; set FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true so Actions use Node 24"
  fi

  if ! grep -q 'actions/setup-node@v7' <<<"$text"; then
    fail "$rel does not install Node.js 24 (missing actions/setup-node@v7)"
  fi

  if ! grep -Eq 'node-version: ["'\'']?24["'\'']?' <<<"$text"; then
    fail "$rel does not pin node-version: 24"
  fi

  if grep -Eq 'azure/setup-helm@v1(\.|$)' <<<"$text"; then
    fail "$rel still uses azure/setup-helm@v1 which runs on Node 20; use azure/setup-helm@v4"
  fi
done

echo "OK: gateway-helm GitHub Actions use Node.js 24"
