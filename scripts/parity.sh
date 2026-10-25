#!/bin/bash
set -euo pipefail

SCRATCH="${SCRATCH:-$HOME/.cache/macmax-build}"
MAC_AUDIT="${MAC_AUDIT_SH:-$HOME/agent-os/skills/mac-audit/bin/mac-audit.sh}"
MACMAX="${MACMAX_CLI:-$SCRATCH/release/MacMaxCLI}"
PARITY_DIR="$SCRATCH/parity"

if [ ! -f "$MAC_AUDIT" ]; then
    echo "skipped: mac-audit.sh not found"
    exit 0
fi

if [ ! -x "$MACMAX" ]; then
    swift build -c release --product MacMaxCLI --scratch-path "$SCRATCH"
fi

mkdir -p "$PARITY_DIR"
SCRIPT_REPORT="$PARITY_DIR/report.md"
SCRIPT_JSON="$PARITY_DIR/script-summary.json"
MACMAX_JSON="$PARITY_DIR/macmax.json"

script_started="$(date +%s)"
set +e
"$MAC_AUDIT" -o "$SCRIPT_REPORT" --json-summary >"$SCRIPT_JSON"
script_status=$?
set -e
if [ "$script_status" -gt 2 ]; then
    echo "parity: FAILED"
    echo "mac-audit.sh exited $script_status"
    exit 1
fi

macmax_started="$(date +%s)"
set +e
"$MACMAX" audit --json >"$MACMAX_JSON"
macmax_status=$?
set -e
if [ "$macmax_status" -eq 3 ]; then
    echo "parity: FAILED"
    echo "macmax audit verdict is unknown"
    exit 1
fi
if [ "$macmax_status" -gt 3 ]; then
    echo "parity: FAILED"
    echo "macmax audit exited $macmax_status"
    exit 1
fi
if [ $((macmax_started - script_started)) -gt 60 ]; then
    echo "parity: FAILED"
    echo "audit start times were more than 60 seconds apart"
    exit 1
fi

python3 - "$SCRIPT_REPORT" "$SCRIPT_JSON" "$MACMAX_JSON" <<'PY'
import json
import re
import sys

report_path, summary_path, macmax_path = sys.argv[1:]

def load_json_output(path):
    text = open(path, encoding="utf-8").read().strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        for line in reversed(text.splitlines()):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                pass
    raise ValueError("no JSON object in " + path)

def number(value):
    try:
        return float(str(value).rstrip("%"))
    except (TypeError, ValueError):
        return None

LIVE_SAMPLE_RULES = {"cpu_idle", "kernel_cpu", "swap_in_rate", "disk_iops"}

def finding_near_threshold(finding, relative_tolerance=0.05):
    evidence = {item.get("key"): item.get("value") for item in finding.get("evidence", [])}
    measured = number(evidence.get("value"))
    threshold = number(evidence.get("threshold"))
    if measured is None or threshold is None:
        return False
    tolerance = max(abs(threshold) * relative_tolerance, 0.000001)
    return abs(measured - threshold) <= tolerance

def script_near_threshold(message, rule, relative_tolerance=0.05):
    measured_values = [float(value) for value in re.findall(r"(?<![A-Za-z])\d+(?:\.\d+)?", message)]
    thresholds = rule.get("thresholds", [])
    defaults = [number(item.get("default", item.get("default_value"))) for item in thresholds]
    for measured in measured_values:
        for threshold in defaults:
            if threshold is not None:
                tolerance = max(abs(threshold) * relative_tolerance, 0.000001)
                if abs(measured - threshold) <= tolerance:
                    return True
    return False

try:
    macmax = load_json_output(macmax_path)
    summary = load_json_output(summary_path)
except (OSError, ValueError, json.JSONDecodeError) as error:
    print("parity: FAILED")
    print("invalid JSON: " + str(error))
    sys.exit(1)

rules = macmax.get("rules", [])
rules_by_id = {rule.get("rule_id"): rule for rule in rules}
patterns = []
for rule in rules:
    pattern = rule.get("script_pattern")
    if pattern:
        try:
            patterns.append((rule["rule_id"], re.compile(pattern)))
        except re.error as error:
            print("parity: FAILED")
            print("invalid pattern for %s: %s" % (rule.get("rule_id", "unknown"), error))
            sys.exit(1)

script_findings = []
line_pattern = re.compile(r"^\s*\d+\. \[(CRIT|WARN|INFO)\] (.*?)\s+->\s+.*$")
with open(report_path, encoding="utf-8") as report:
    for line in report:
        match = line_pattern.match(line.rstrip("\n"))
        if match:
            script_findings.append((match.group(1).lower(), match.group(2)))

mac_findings = {(item.get("rule_id"), item.get("severity")): item
                for item in macmax.get("findings", [])}
failed = False
for severity, message in script_findings:
    matches = [rule_id for rule_id, pattern in patterns if pattern.fullmatch(message)]
    if len(matches) != 1:
        print("unmatched: %s [%s]" % (message, severity))
        failed = True
        continue
    rule_id = matches[0]
    finding = mac_findings.get((rule_id, severity))
    if finding is not None:
        print("checked: %s %s" % (rule_id, severity))
        continue
    same_rule = next((item for item in macmax.get("findings", [])
                      if item.get("rule_id") == rule_id), None)
    script_close = script_near_threshold(message, rules_by_id.get(rule_id, {}))
    macmax_close = same_rule is not None and finding_near_threshold(same_rule)
    if rule_id in LIVE_SAMPLE_RULES:
        script_close = script_near_threshold(message, rules_by_id.get(rule_id, {}), 0.50)
        macmax_close = same_rule is not None and finding_near_threshold(same_rule, 0.50)
        if script_close and (same_rule is None or macmax_close):
            print("parity noisy: %s" % rule_id)
            continue
    elif script_close or macmax_close:
        print("near threshold: %s" % rule_id)
        continue

    print("missing: %s %s" % (rule_id, severity))
    failed = True

comparisons = [
    ("uptime_d", 0.0, False),
    ("claude_stale", 0.0, False),
    ("procs", 0.05, True),
    ("swap_gb", 0.1, False),
    ("disk_free_pct", 1.0, False),
]
mac_summary = macmax.get("summary", macmax)
for key, tolerance, relative in comparisons:
    left, right = number(summary.get(key)), number(mac_summary.get(key))
    if left is None or right is None:
        print("summary missing: %s" % key)
        failed = True
        continue
    allowed = abs(left) * tolerance if relative else tolerance
    if abs(left - right) > allowed:
        print("summary mismatch: %s script=%s macmax=%s" % (key, left, right))
        failed = True
    else:
        print("summary checked: %s" % key)

script_crit = sum(1 for severity, _ in script_findings if severity == "crit")
script_warn = sum(1 for severity, _ in script_findings if severity == "warn")
mac_crit = sum(1 for item in macmax.get("findings", []) if item.get("severity") == "crit")
mac_warn = sum(1 for item in macmax.get("findings", []) if item.get("severity") == "warn")
print("counts: script crit=%d warn=%d; macmax crit=%d warn=%d" %
      (script_crit, script_warn, mac_crit, mac_warn))
print("parity: FAILED" if failed else "parity: ok")
sys.exit(1 if failed else 0)
PY
