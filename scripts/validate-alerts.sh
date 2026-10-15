#!/usr/bin/env bash
# Validates infrastructure/alerts/hiyall.rules.yml. With promtool installed (it ships with Prometheus) this is
# `promtool check rules`, which also parses every PromQL expression. Without it, a structure check runs: it cannot
# parse PromQL, so it says so; install promtool before relying on the rules.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="${1:-$root/infrastructure/alerts/hiyall.rules.yml}"
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$file"
  exit 0
fi
echo "validate-alerts: promtool is not installed; running the structure check only (PromQL is NOT parsed)" >&2
python3 -I - "$file" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
problems = []
if "\t" in text:
    problems.append("a tab character (YAML indents with spaces)")
if not re.search(r"(?m)^groups:\s*$", text):
    problems.append("no top-level `groups:`")
groups = re.findall(r"(?m)^  - name: (\S+)\s*$", text)
if not groups:
    problems.append("no group (`- name:`)")
# Split into rule blocks: from each `- alert:` to the next one or the next group.
blocks = re.split(r"(?m)^      - (?=alert:)", text)[1:]
if not blocks:
    problems.append("no rule (`- alert:`)")
seen = set()
for b in blocks:
    name = re.match(r"alert: (\S+)", b).group(1)
    if name in seen:
        problems.append("duplicate alert name %s" % name)
    seen.add(name)
    m = re.search(r"(?m)^        expr: (\|\n(?:          .*\n?)+|.+)$", b)
    if not m:
        problems.append("%s has no expr" % name)
        continue
    expr = m.group(1)
    for o, c in ("()", "[]", "{}"):
        if expr.count(o) != expr.count(c):
            problems.append("%s: unbalanced %s%s in expr" % (name, o, c))
    if expr.count('"') % 2:
        problems.append("%s: odd number of quotes in expr" % name)
    if not re.search(r"(?m)^        labels: \{severity: (page|ticket)\}", b):
        problems.append("%s has no severity label (page or ticket)" % name)
    for key in ("summary", "description", "runbook"):
        if not re.search(r"(?m)^          %s: \"" % key, b):
            problems.append("%s has no %s annotation" % (name, key))
if problems:
    print("alert rules: structure problems:")
    for p in problems:
        print("  - " + p)
    sys.exit(1)
print("alert rules: structure OK (%d alerts in %d groups; promtool not run)" % (len(seen), len(groups)))
PY
