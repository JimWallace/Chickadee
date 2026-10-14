#!/usr/bin/env bash
set -euo pipefail

# Every swift-format configuration lists every rule, each one on or off.
#
# The `rules` object in a `.swift-format` file does not add to the tool's
# defaults. It replaces them, and a rule that the object does not name is off.
# For a long time the root file named four rules, so only those four ran, and
# about thirty default rules were silently off. Nothing showed it.
#
# This guard compares each configuration with the rule list of the installed
# swift-format (`dump-configuration`). It fails when a configuration omits a
# rule, which also catches a new rule that a toolchain upgrade adds, and when a
# configuration names a rule that the tool does not know.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

configs=(.swift-format)

# Prints the rule names in a configuration, one per line, sorted. A rule name
# starts with a capital letter; every other key in the file does not. The CI
# image has no python3 or jq, so this reads the JSON with grep and sed.
rule_names() {
  grep -oE '"[A-Z][A-Za-z]+"[[:space:]]*:[[:space:]]*(true|false)' \
    | sed -E 's/^"([A-Za-z]+)".*/\1/' | LC_ALL=C sort -u
}

known="$(swift-format dump-configuration | rule_names)"
if [ -z "$known" ]; then
  echo "check-swift-format-config: swift-format printed no rules."
  exit 1
fi

status=0
for config in "${configs[@]}"; do
  if [ ! -f "$config" ]; then
    echo "check-swift-format-config: $config is missing."
    status=1
    continue
  fi
  listed="$(rule_names <"$config")"
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    echo "$config: does not list the rule $rule. Name it with true or false."
    status=1
  done < <(LC_ALL=C comm -23 <(printf '%s\n' "$known") <(printf '%s\n' "$listed"))
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    echo "$config: lists the rule $rule, which swift-format does not know."
    status=1
  done < <(LC_ALL=C comm -13 <(printf '%s\n' "$known") <(printf '%s\n' "$listed"))
done

if [ "$status" -eq 0 ]; then
  echo "check-swift-format-config: every configuration lists every rule."
fi
exit "$status"
