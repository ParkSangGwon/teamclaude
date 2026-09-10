#!/bin/bash
# Renders the popover and every settings pane to PNG through the app's
# TEAMCLAUDE_BAR_SNAPSHOT mode, against a throwaway headless proxy: no real
# config, no real accounts, no network. Entry point: `make -C macos snapshots`.
#
#   SNAPSHOT_DIR  where the PNGs go (default: macos/dist/snapshots)
#   SCRATCH       swift --scratch-path, for a build that must not share .build
#   SWIFT         swift executable (default: swift)
set -euo pipefail

macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(dirname "$macos_dir")"
out="${SNAPSHOT_DIR:-$macos_dir/dist/snapshots}"
swift_bin="${SWIFT:-swift}"
scratch=()
if [ -n "${SCRATCH:-}" ]; then scratch=(--scratch-path "$SCRATCH"); fi

command -v node >/dev/null || { echo "snapshots: node is not on PATH" >&2; exit 1; }

"$swift_bin" build -c release --package-path "$macos_dir" "${scratch[@]}" --product TeamClaudeBar
bin="$("$swift_bin" build -c release --package-path "$macos_dir" "${scratch[@]}" --show-bin-path)/TeamClaudeBar"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/teamclaude-snapshots.XXXXXX")"
proxy_pid=""
app_pid=""
cleanup() {
  if [ -n "$app_pid" ]; then kill "$app_pid" 2>/dev/null || true; fi
  if [ -n "$proxy_pid" ]; then kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

free_port() {
  node -e 'const s = require("node:net").createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });'
}
port="$(free_port)"
dead_upstream="$(free_port)"
config="$tmp/config.json"
cat > "$config" <<JSON
{
  "proxy": { "port": $port, "apiKey": "tc-snapshot-key" },
  "upstream": "http://127.0.0.1:$dead_upstream",
  "upstreamProxy": false,
  "accounts": [{ "name": "api-test", "type": "apikey", "apiKey": "sk-ant-api03-placeholder" }]
}
JSON
chmod 600 "$config"

TEAMCLAUDE_CONFIG="$config" TEAMCLAUDE_DISABLE_AUTOUPDATE=1 \
  node "$repo/src/index.js" server --headless >"$tmp/proxy.log" 2>&1 &
proxy_pid=$!
up=""
for _ in $(seq 1 100); do
  if curl -sf "http://127.0.0.1:$port/teamclaude/status" >/dev/null 2>&1; then up=1; break; fi
  if ! kill -0 "$proxy_pid" 2>/dev/null; then break; fi
  sleep 0.2
done
if [ -z "$up" ]; then
  echo "snapshots: the proxy did not answer on port $port within 20 s" >&2
  cat "$tmp/proxy.log" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
TEAMCLAUDE_CONFIG="$config" TEAMCLAUDE_BAR_SNAPSHOT="$out" TEAMCLAUDE_DISABLE_AUTOUPDATE=1 \
  "$bin" >"$tmp/app.log" 2>&1 &
app_pid=$!
for _ in $(seq 1 150); do
  if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
  sleep 0.2
done
if kill -0 "$app_pid" 2>/dev/null; then
  echo "snapshots: the app did not quit within 30 s, killing it" >&2
  kill "$app_pid" 2>/dev/null || true
fi
wait "$app_pid" 2>/dev/null || true
app_pid=""

kill "$proxy_pid" 2>/dev/null || true
wait "$proxy_pid" 2>/dev/null || true
proxy_pid=""

count="$(find "$out" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
if [ "$count" = "0" ]; then
  echo "snapshots: no PNG was written to $out" >&2
  cat "$tmp/app.log" >&2
  exit 1
fi
ls -l "$out"/*.png
