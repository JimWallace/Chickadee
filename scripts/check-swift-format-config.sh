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

configs=(.swift-format Tests/.swift-format)

defaults="$(swift-format dump-configuration)"

status=0
for config in "${configs[@]}"; do
  if [ ! -f "$config" ]; then
    echo "check-swift-format-config: $config is missing."
    status=1
    continue
  fi
  if ! DEFAULTS="$defaults" python3 - "$config" <<'EOF'
import json, os, sys

path = sys.argv[1]
known = set(json.loads(os.environ["DEFAULTS"])["rules"])
listed = set(json.load(open(path)).get("rules", {}))

missing = sorted(known - listed)
unknown = sorted(listed - known)
for rule in missing:
    print(f"{path}: does not list the rule {rule}. Name it with true or false.")
for rule in unknown:
    print(f"{path}: lists the rule {rule}, which swift-format does not know.")
sys.exit(1 if missing or unknown else 0)
EOF
  then
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "check-swift-format-config: every configuration lists every rule."
fi
exit "$status"
