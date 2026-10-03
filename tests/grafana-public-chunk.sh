#!/usr/bin/env bash
# Reported: graph.dbslone.com shows
# ChunkLoadError: Loading chunk 192 failed
# (https://graph.dbslone.com/public/build/alert-rules-toolbar-button.0d86c1adae7edb55ff76.js).
# Grafana loads that file as a credential-less script. Cloudflare Access must
# return the JavaScript, not the GitHub login page. The site root stays behind
# Access.
set -euo pipefail

chunk_url="https://graph.dbslone.com/public/build/alert-rules-toolbar-button.0d86c1adae7edb55ff76.js"
root_headers="$(mktemp)"
chunk_headers="$(mktemp)"
chunk_body="$(mktemp)"
trap 'rm -f "$root_headers" "$chunk_headers" "$chunk_body"' EXIT

curl -sI --max-time 20 "https://graph.dbslone.com/" >"$root_headers"
if ! grep -qi 'location:.*cloudflareaccess.com' "$root_headers"; then
  echo "FAIL: graph.dbslone.com no longer requires Cloudflare Access login" >&2
  cat "$root_headers" >&2
  exit 1
fi

curl -sS -D "$chunk_headers" --max-time 20 -o "$chunk_body" "$chunk_url"
status="$(awk 'BEGIN{code=""} /^HTTP/{code=$2} END{print code}' "$chunk_headers")"
ctype="$(awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' "$chunk_headers" | tr -d '\r')"

if grep -qi 'cloudflareaccess.com' "$chunk_headers" || grep -q 'cloudflareaccess.com' "$chunk_body"; then
  echo "FAIL: ChunkLoadError: Loading chunk 192 failed because ${chunk_url} is the Cloudflare Access login page" >&2
  exit 1
fi

if [[ "$status" != "200" || "$ctype" != text/javascript* ]]; then
  echo "FAIL: ChunkLoadError: Loading chunk 192 failed because ${chunk_url} returned HTTP ${status} ${ctype}" >&2
  exit 1
fi

if ! grep -q 'webpackChunkgrafana' "$chunk_body"; then
  echo "FAIL: ChunkLoadError: Loading chunk 192 failed because ${chunk_url} is not the Grafana chunk" >&2
  exit 1
fi

echo "OK: graph.dbslone.com Grafana chunk 192 is JavaScript and the site root still requires Access"
