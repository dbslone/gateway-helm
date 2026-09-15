#!/usr/bin/env bash
# Reported: Helm templates step "Mail stack charts must not be in this repo"
# fails with: line 1: tests/no-mail-stack.sh: Permission denied
#
# GitHub Actions `run: tests/no-mail-stack.sh` execs the file. Git tracks it as
# 100644 (not executable), so the runner cannot start it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/helm-templates.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [[ ! -f "$WF" ]]; then
  fail "missing $WF"
fi

if [[ ! -f "$ROOT/tests/no-mail-stack.sh" ]]; then
  fail "missing tests/no-mail-stack.sh"
fi

# The reported job must still exist.
if ! grep -q 'Mail stack charts must not be in this repo' "$WF"; then
  fail "helm-templates.yml no longer has the reported step Mail stack charts must not be in this repo"
fi

wf_text="$(cat "$WF")"

# Direct `run: tests/foo.sh` requires the git executable bit. `bash tests/foo.sh` does not.
while IFS= read -r line; do
  script="${line#*run: }"
  script="${script%%[[:space:]]*}"
  case "$script" in
    tests/*.sh)
      path="$ROOT/$script"
      uses_bash=0
      if grep -Eq "run:[[:space:]]+bash[[:space:]]+$script" <<<"$wf_text"; then
        uses_bash=1
      fi
      if [[ "$uses_bash" -eq 0 ]]; then
        if [[ ! -x "$path" ]]; then
          fail "Mail stack charts must not be in this repo fails with line 1: $script: Permission denied because $script is not executable and helm-templates.yml runs it without bash"
        fi
        if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          mode="$(git -C "$ROOT" ls-files -s -- "$script" | awk '{print $1}')"
          if [[ -n "$mode" && "$mode" != "100755" ]]; then
            fail "Mail stack charts must not be in this repo fails with line 1: $script: Permission denied because git mode is $mode (not 100755) and helm-templates.yml runs it without bash"
          fi
        fi
      fi
      ;;
  esac
done < <(grep -E 'run:[[:space:]]+(bash[[:space:]]+)?tests/[^[:space:]]+\.sh' "$WF" || true)

if ! grep -Eq 'run:[[:space:]]+bash[[:space:]]+tests/no-mail-stack\.sh' "$WF"; then
  fail "Mail stack charts must not be in this repo fails with line 1: tests/no-mail-stack.sh: Permission denied"
fi

echo "OK: Mail stack CI script is runnable (no Permission denied)"
