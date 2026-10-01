#!/usr/bin/env bash
set -euo pipefail

# Every `@unchecked Sendable` outside a Fluent model carries a comment that
# says why (CLAUDE.md, "Coding Conventions").
#
# The attribute switches the compiler's data-race check off for one type. The
# comment is the replacement for that check: it names the invariant a reader
# must keep when they edit the type. A site without one is a type nobody can
# safely change.
#
# Fluent `Model` classes are exempt. They must be classes, Fluent's property
# wrappers are the reason the conformance is unchecked, and the comment would
# be the same sentence on every model. A model is recognised by `Model` in
# the conformance list before the attribute.
#
# A comment counts when a `//` line within three lines of the declaration
# mentions `Sendable`; the house shape is `// @unchecked Sendable: <reason>`
# on the line after.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

offenders=""
checked=0
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"
  text="${rest#*:}"
  # A comment that mentions the attribute is not a declaration.
  if printf '%s' "$text" | grep -qE '^[[:space:]]*//'; then continue; fi
  # Fluent models are exempt (see above): `Model` is a conformance on the
  # declaration line, before the attribute, with any others between.
  if printf '%s' "$text" | grep -qE '(^|[:,])[[:space:]]*Model[[:space:]]*,.*@unchecked[[:space:]]+Sendable'; then continue; fi
  checked=$((checked + 1))
  start=$((line - 3))
  [ "$start" -lt 1 ] && start=1
  end=$((line + 3))
  if sed -n "${start},${end}p" "$file" | grep -E '^[[:space:]]*//' | grep -q 'Sendable'; then continue; fi
  offenders+="  $file:$line"$'\n'
done < <(grep -rnF --include='*.swift' '@unchecked Sendable' Sources/ || true)

if [ -n "$offenders" ]; then
  echo "ERROR: @unchecked Sendable without a comment explaining why."
  echo
  printf '%s' "$offenders"
  echo
  echo "The attribute turns the compiler's data-race check off. Say which"
  echo "invariant keeps the type safe, as '// @unchecked Sendable: <reason>' on"
  echo "the line after the declaration, or make the type an actor or give it a"
  echo "Mutex. Fluent Model classes are exempt."
  exit 1
fi

echo "check-unchecked-sendable: OK ($checked non-model site(s), all commented)"
