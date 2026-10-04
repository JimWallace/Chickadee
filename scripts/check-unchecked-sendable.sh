#!/usr/bin/env bash
set -euo pipefail

# No `@unchecked Sendable` outside a Fluent model (CLAUDE.md, "Coding
# Conventions").
#
# The attribute switches the compiler's data-race check off for one type. It
# used to be allowed anywhere with a comment that named the invariant. Once
# the last non-model site became plainly `Sendable` (#2009), a comment was no
# longer a reason to allow one (#1927): every shared mutable state here is an
# actor or a `Mutex`, which the compiler can check.
#
# Fluent `Model` classes are exempt. They must be classes, and Fluent's
# property wrappers are the reason the conformance is unchecked. A model is
# recognised by `Model` in the conformance list before the attribute.

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
  offenders+="  $file:$line"$'\n'
done < <(grep -rnF --include='*.swift' '@unchecked Sendable' Sources/ || true)

if [ -n "$offenders" ]; then
  echo "ERROR: @unchecked Sendable outside a Fluent model, with or without a comment."
  echo
  printf '%s' "$offenders"
  echo
  echo "The attribute turns the compiler's data-race check off. Make the type"
  echo "an actor, give its state a Mutex, or make it plainly Sendable. Fluent"
  echo "Model classes are exempt."
  exit 1
fi

echo "check-unchecked-sendable: OK (no @unchecked Sendable outside a Fluent model)"
