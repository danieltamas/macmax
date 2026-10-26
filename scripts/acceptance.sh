#!/usr/bin/env bash
# End-to-end checks on the built CLI, against this Mac.
#   mcp   the MCP server over stdio: initialize, tools/list, every tool called, stdout carries JSON-RPC only,
#         no tool can act, a bad call is -32602, and the CLI exit codes for usage errors.
# Usage: acceptance.sh [mcp]   (SCRATCH defaults to $HOME/.cache/macmax-build; build first)
set -euo pipefail
scratch=${SCRATCH:-$HOME/.cache/macmax-build}
# Not `macmax`: on a case-insensitive disk that name is the app binary.
cli=$scratch/debug/MacMaxCLI
[[ -x $cli ]] || { echo "acceptance: build first, $cli is missing" >&2; exit 2; }

mcp() {
  local out lines home
  # A scratch home: agent access is off by default, so the run turns it on for itself and leaves the real config alone.
  home=$(mktemp -d); chmod 700 "$home"
  trap 'rm -rf "$home"' RETURN
  printf '{"agent_access": true}\n' > "$home/config.json"
  out=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"snapshot","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"history","arguments":{"metric":"cpu","range":"7d"}}}' \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"cleanup_preview","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"top_apps","arguments":{"limit":"x"}}}' \
    | MACMAX_HOME="$home" "$cli" mcp)
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [[ $lines -eq 7 ]] || { echo "acceptance: expected 7 replies (the notification gets none), got $lines" >&2; exit 1; }
  printf '%s' "$out" | /usr/bin/python3 -I -c '
import json, sys
replies = {}
for line in sys.stdin.read().splitlines():
    message = json.loads(line)  # a non-JSON line on stdout fails here
    assert message["jsonrpc"] == "2.0"
    replies[message["id"]] = message
assert replies[1]["result"]["serverInfo"]["name"] == "macmax"
tools = replies[2]["result"]["tools"]
names = sorted(t["name"] for t in tools)
assert len(names) == 10, names
for tool in tools:
    assert tool["annotations"]["readOnlyHint"] is True and tool["annotations"]["destructiveHint"] is False, tool["name"]
    assert not any(word in tool["name"] for word in ("kill", "quit", "delete", "write", "stop", "end", "trash")), tool["name"]
for id in (3, 4, 5):
    result = replies[id]["result"]
    assert result["isError"] is False
    data = result["structuredContent"]
    assert {"source", "generated_at", "data_note"} <= set(data), id
    assert json.loads(result["content"][0]["text"]) == data
assert replies[6]["error"]["code"] == -32602
assert replies[7]["error"]["code"] == -32602
print("acceptance: mcp ok (%d tools, 3 calls, 2 invalid calls refused)" % len(names))
'
}

access_off() {
  local home out
  home=$(mktemp -d); chmod 700 "$home"
  trap 'rm -rf "$home"' RETURN
  out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"snapshot","arguments":{}}}' \
    | MACMAX_HOME="$home" "$cli" mcp)
  printf '%s' "$out" | /usr/bin/python3 -I -c '
import json, sys
result = json.loads(sys.stdin.read())["result"]
assert result["isError"] is True and "Agent access is off" in result["content"][0]["text"]
assert "structuredContent" not in result
print("acceptance: agent access off blocks tool calls")
'
}

usage() {
  local code=0
  "$cli" bogus >/dev/null 2>&1 || code=$?
  [[ $code -eq 64 ]] || { echo "acceptance: unknown command exited $code, expected 64" >&2; exit 1; }
  echo "acceptance: usage exit code ok"
}

case ${1:-mcp} in
  mcp) mcp; access_off; usage ;;
  *) echo "usage: acceptance.sh [mcp]" >&2; exit 2 ;;
esac
