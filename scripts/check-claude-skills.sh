#!/usr/bin/env bash
set -uo pipefail

# Every Claude Code skill in .claude/skills/ follows the Agent Skills authoring
# rules, and has evaluations.
#
# The rules come from Anthropic's "Skill authoring best practices"
# (platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices).
# The platform refuses some of them at upload time; Claude Code does not, so
# nothing else here would catch a skill that breaks one. Per skill:
#
#   * SKILL.md opens with a frontmatter block.
#   * `name` is the directory name, at most 64 characters of lowercase letters,
#     digits and hyphens, and it does not contain "anthropic" or "claude".
#   * `description` is not empty, is at most 1,024 characters, and holds no XML
#     tag. It is the only text Claude sees when it decides to load the skill.
#   * The body after the frontmatter is at most 500 lines. Put more detail in a
#     file that the body links to.
#   * Each relative Markdown link in SKILL.md names a file that exists.
#   * .claude/skill-evals/<name>/ holds at least three evaluation scenarios.
#     Each is a .json file with "skills", "query" and "expected_behavior", and
#     its "skills" names this skill. The scenarios live outside the skill
#     directory so that an agent under test does not read the expected answers.
#
# An evaluation directory with no skill is an error too, so the set cannot go
# stale.
#
# Pure grep/sed/awk: the format-lint container has no python3 or jq.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 2

skills_dir=".claude/skills"
evals_dir=".claude/skill-evals"
max_body_lines=500
max_description=1024
min_evals=3

errors=0
fail() {
    echo "ERROR: $1"
    errors=$((errors + 1))
}

# Prints the frontmatter of $1 (the lines between the first two `---` lines),
# or nothing when the file does not open with `---`.
frontmatter() {
    awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$1"
}

# Prints the value of top-level key $2 in frontmatter text $1. A folded or
# literal block value (`key: >` or `key: |`) is its indented lines joined
# with single spaces.
frontmatter_value() {
    awk -v key="$2" '
        found && /^[^[:space:]]/ { exit }
        found { sub(/^[[:space:]]+/, ""); value = value (value == "" ? "" : " ") $0; next }
        index($0, key ":") == 1 {
            rest = substr($0, length(key) + 2)
            sub(/^[[:space:]]+/, "", rest)
            if (rest ~ /^[>|][-+]?$/) { found = 1; next }
            print rest
            exit
        }
        END { if (found) print value }
    ' <<<"$1"
}

checked=0
for skill_md in "$skills_dir"/*/SKILL.md; do
    [ -e "$skill_md" ] || continue
    checked=$((checked + 1))
    skill_dir="$(dirname "$skill_md")"
    dir_name="$(basename "$skill_dir")"

    front="$(frontmatter "$skill_md")"
    if [ -z "$front" ]; then
        fail "$skill_md: no frontmatter block. The file must open with a line of three hyphens."
        continue
    fi

    name="$(frontmatter_value "$front" name)"
    if [ "$name" != "$dir_name" ]; then
        fail "$skill_md: name '$name' is not the directory name '$dir_name'."
    fi
    if ! [[ "$name" =~ ^[a-z0-9-]{1,64}$ ]]; then
        fail "$skill_md: name '$name' must be 1 to 64 lowercase letters, digits or hyphens."
    fi
    if [[ "$name" == *anthropic* || "$name" == *claude* ]]; then
        fail "$skill_md: name '$name' contains a reserved word (anthropic, claude)."
    fi

    description="$(frontmatter_value "$front" description)"
    if [ -z "$description" ]; then
        fail "$skill_md: description is empty. Say what the skill does and when to use it."
    elif [ "${#description}" -gt "$max_description" ]; then
        fail "$skill_md: description is ${#description} characters; the limit is $max_description."
    fi
    if grep -qE '<[A-Za-z/][^>]*>' <<<"$description"; then
        fail "$skill_md: description contains an XML tag."
    fi

    front_lines="$(wc -l <<<"$front")"
    total_lines="$(wc -l <"$skill_md")"
    body_lines=$((total_lines - front_lines - 2))
    if [ "$body_lines" -gt "$max_body_lines" ]; then
        fail "$skill_md: body is $body_lines lines; the limit is $max_body_lines. Move detail to a linked file."
    fi

    # Relative links only: a URL, a mail link or an in-page anchor is skipped,
    # and an anchor on a file link is cut before the file is checked.
    while IFS= read -r target; do
        case "$target" in
            http://* | https://* | mailto:* | '#'*) continue ;;
        esac
        path="${target%%#*}"
        if [ ! -e "$skill_dir/$path" ]; then
            fail "$skill_md: link target '$target' does not exist."
        fi
    done < <(grep -oE '\]\([^) ]+\)' "$skill_md" | sed -E 's/^\]\((.*)\)$/\1/')

    eval_count=0
    for eval_file in "$evals_dir/$dir_name"/*.json; do
        [ -e "$eval_file" ] || continue
        eval_count=$((eval_count + 1))
        for key in skills query expected_behavior; do
            if ! grep -q "\"$key\"[[:space:]]*:" "$eval_file"; then
                fail "$eval_file: no \"$key\" key."
            fi
        done
        if ! grep -q "\"$dir_name\"" "$eval_file"; then
            fail "$eval_file: \"skills\" does not name '$dir_name'."
        fi
    done
    if [ "$eval_count" -lt "$min_evals" ]; then
        fail "$skill_md: $eval_count evaluation scenarios in $evals_dir/$dir_name/; at least $min_evals are required."
    fi
done

for eval_dir in "$evals_dir"/*/; do
    [ -d "$eval_dir" ] || continue
    eval_name="$(basename "$eval_dir")"
    if [ ! -f "$skills_dir/$eval_name/SKILL.md" ]; then
        fail "$eval_dir: evaluations for a skill that does not exist."
    fi
done

if [ "$checked" -eq 0 ]; then
    fail "no skills found in $skills_dir/."
fi

if [ "$errors" -gt 0 ]; then
    echo "check-claude-skills: $errors error(s)."
    exit 1
fi
echo "check-claude-skills: $checked skills pass."
