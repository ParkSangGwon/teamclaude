#!/bin/bash
# Writes a throwaway config that points the app at scripts/demo-server.mjs and
# prints its path. The accounts mirror the fixture the demo server serves; there
# are no tokens in it. Use: TEAMCLAUDE_CONFIG="$(scripts/demo-config.sh 3458)" swift run TeamClaudeBar
set -euo pipefail
port="${1:-3458}"
dir="$(mktemp -d "${TMPDIR:-/tmp}/teamclaude-demo.XXXXXX")"
cat > "$dir/config.json" <<JSON
{
  "proxy": { "port": $port, "apiKey": "tc-demo-key", "sessionDetail": true },
  "switchThreshold": 0.98,
  "distributeSessions": false,
  "quotaProbeSeconds": 300,
  "routes": [{ "name": "fable", "match": ["*fable*"], "accounts": [] }],
  "accounts": [
    { "name": "alice@example.com", "type": "oauth", "orgName": "Example Org", "priority": 0, "accountUuid": "00000000-0000-4000-8000-000000000001" },
    { "name": "bob@example.com", "type": "oauth", "orgName": "Example Org", "priority": 1, "accountUuid": "00000000-0000-4000-8000-000000000002" }
  ]
}
JSON
chmod 600 "$dir/config.json"
echo "$dir/config.json"
