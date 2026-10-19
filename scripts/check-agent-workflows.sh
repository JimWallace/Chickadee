#!/usr/bin/env bash
set -uo pipefail

# The CI agent workflows share one setup and one cleanup, and stay that way.
#
# Ten workflows run a Claude agent. Each one had its own copy of the setup
# and of the post-time cleanup, and the copies drifted: one model job held
# `issues: write`, one let the model post with no cleanup, and three had no
# deny list (#2711). Now .github/actions/claude-agent runs every agent and
# scripts/ci-agent-sanitize.sh cleans every post. This guard keeps a new
# workflow, or an edit, from bringing a copy back:
#
#   1. Only .github/actions/claude-agent/action.yml names
#      anthropics/claude-code-action.
#   2. Each step that uses ./.github/actions/claude-agent passes the job's own
#      token (github-token) and its own deny list (disallowed-tools).
#   3. No workflow that runs an agent asks for `id-token: write`. With it,
#      claude-code-action can trade for a Claude App token with write scopes.
#   4. No workflow holds its own copy of the credential pattern. The cleanup
#      is scripts/ci-agent-sanitize.sh.
#
# Deliberately grep and awk: format-lint runs an image with no python3.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 2

action=".github/actions/claude-agent/action.yml"
problems=""
add() { problems="${problems}$1"$'\n'; }

# Plain globs, not `git ls-files`: the format-lint image is the toolchain
# alone, and a checkout in a container can be a repository that git refuses.
shopt -s nullglob
workflows=(.github/workflows/*.yml .github/workflows/*.yaml)

if [ ! -f "$action" ]; then
  add "$action: missing. Every agent workflow runs its agent through it."
fi

while IFS= read -r file; do
  [ "$file" = "$action" ] && continue
  if grep -n 'anthropics/claude-code-action' "$file" > /dev/null; then
    add "$file: names anthropics/claude-code-action. Run the agent through ./.github/actions/claude-agent instead."
  fi
done < <(printf '%s\n' "${workflows[@]}"; find .github/actions -type f -name '*.y*ml')

while IFS= read -r file; do
  grep -q 'uses: \./\.github/actions/claude-agent' "$file" || continue
  # Each `uses:` step of the action must pass both inputs. The step ends at
  # the first line indented less than its `uses:` key: the next step or job.
  missing="$(awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function check() {
      if (in_step && !token) printf "%s:%d: a claude-agent step passes no github-token\n", FILENAME, start
      if (in_step && !deny) printf "%s:%d: a claude-agent step passes no disallowed-tools\n", FILENAME, start
      in_step = 0
    }
    in_step && $0 !~ /^[[:space:]]*$/ && indent($0) < step_indent { check() }
    /uses: \.\/\.github\/actions\/claude-agent/ {
      in_step = 1; start = NR; token = 0; deny = 0
      step_indent = indent($0)
      if ($0 ~ /^[[:space:]]*- /) step_indent += 2
    }
    in_step && /^[[:space:]]+github-token:[[:space:]]*\$\{\{ github\.token \}\}/ { token = 1 }
    in_step && /^[[:space:]]+disallowed-tools:[[:space:]]*[^[:space:]"\047]/ { deny = 1 }
    in_step && /^[[:space:]]+disallowed-tools:[[:space:]]*["\047][^"\047[:space:]]/ { deny = 1 }
    END { check() }
  ' "$file")"
  [ -n "$missing" ] && add "$missing"
  if grep -n 'id-token:[[:space:]]*write' "$file" > /dev/null; then
    add "$file: asks for id-token: write in a workflow that runs an agent. The agent uses the job's own token and needs no OIDC token."
  fi
done < <(printf '%s\n' "${workflows[@]}")

while IFS= read -r file; do
  if grep -n -F 'sk-ant-' "$file" > /dev/null; then
    add "$file: holds its own copy of the credential pattern. Clean agent text with scripts/ci-agent-sanitize.sh."
  fi
done < <(printf '%s\n' "${workflows[@]}")

if [ -n "$problems" ]; then
  printf '%s' "$problems"
  echo "See the header of $action for the rules (#2711)."
  exit 1
fi
echo "check-agent-workflows: OK"
