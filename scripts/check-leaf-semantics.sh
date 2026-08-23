#!/usr/bin/env bash
set -uo pipefail

# Leaf template semantics: idioms that LOOK right and silently do nothing.
#
# LeafKit resolves a keypath by walking dictionaries — `Dictionary+LeafData.swift`
# requires every intermediate component to be a dictionary — so a path whose
# receiver is an array or a string resolves to nil rather than erroring. It has
# no property resolution: `.isEmpty`, `.count`, `.first` and friends are Swift
# properties, not Leaf ones.
#
# Nil then flows two ways, and BOTH read as success:
#
#   #if(rows.isEmpty)   LeafSerializer's conditional guard is
#                       `(evaluated.bool ?? false) || (!evaluated.isNil && ...)`,
#                       so nil is false — the branch NEVER fires.
#   #if(!rows.isEmpty)  ParameterResolver's `.not` is `rhs.bool ?? !rhs.isNil`,
#                       so nil negates to true — the branch ALWAYS fires.
#
# Neither logs, neither 500s, and a render test still passes because the
# template resolves fine. It just resolves wrong. Thirty-three sites shipped
# this way: twenty-two empty states that never appeared (a "No submissions yet"
# replaced by a header-only table promising rows and listing none) and eleven
# blocks that always did (an "Auto-detected:" note with nothing after it, a
# Section picker on a course with no sections, empty badge containers).
#
# The working idiom is the built-in `count` TAG, which handles arrays and
# dictionaries properly (`LeafTag.swift`'s `Count`):
#
#     #if(count(rows) == 0):     instead of  #if(rows.isEmpty):
#     #if(count(rows) > 0):      instead of  #if(!rows.isEmpty):
#
# Note that the `isEmpty` TAG is not the fix — `#isEmpty(rows)` converts its
# parameter to a String and throws on an array.
#
# `count()` throws on a key that is missing or is not a collection, so it turns
# a typo into a 500 rather than another silent no-op. That is the point: loud
# while rendering beats silent forever. Before using it, confirm the receiver
# is a non-optional array on the context struct.
#
# THE ALLOWLIST. A path CAN legitimately end in one of these names when the
# receiver is an encoded struct that DECLARES a property of that name — the key
# is then a real dictionary member and resolves normally. Two exist:
#
#   bar.isEmpty     SparklineBar.isEmpty (AssignmentListContexts.swift) marks a
#                   zero-count bucket so the sparkline draws a faint baseline
#                   tick instead of nothing.
#   bucket.count    ActivityBucket.count (ActivityChartService.swift) is the
#                   distinct-active-users number for that bucket.
#
# Both are indistinguishable to a reader from the broken form, which is exactly
# why they are named here rather than left to be re-derived. Add a pair only
# after confirming the struct declares the property.
#
# The rule covers `isEmpty` and `count` and stops there. Those are the two a
# Swift author reaches for on a collection, and both fail silently. Adding
# speculative names (`first`, `uppercased`, …) would buy no evidence-backed
# coverage while widening the false-positive surface onto every struct that
# happens to declare one — and a guard that cries wolf gets weakened, not
# heeded.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

status=0

# Receiver.property pairs that resolve to a real encoded value. See the note
# above before adding one.
allowed_pairs="bar.isEmpty bucket.count"

# Swift property names Leaf cannot resolve on a collection or string. Each
# resolves to nil and is then silently swallowed by whatever consumes it.
swift_only_properties="isEmpty count"

for prop in $swift_only_properties; do
  # Match the property only where it terminates a dotted path inside a Leaf
  # tag's parameter list — `#if(x.isEmpty)`, `#(a.b.count)`. A bare word in
  # prose is not matched, so documentation describing the forbidden idiom does
  # not trip the guard that forbids it.
  while IFS= read -r line; do
    [ -n "$line" ] || continue

    # Strip every allowlisted pair for this property, then re-test. A line is
    # only clean if NOTHING unallowlisted remains, so an allowlisted receiver
    # cannot shelter a broken one beside it on the same line.
    remaining="$line"
    for pair in $allowed_pairs; do
      case "$pair" in
        *".${prop}")
          receiver="${pair%.*}"
          remaining="$(printf '%s' "$remaining" | sed -E "s/(^|[^A-Za-z0-9_])${receiver}\.${prop}\b/\1/g")"
          ;;
      esac
    done
    printf '%s' "$remaining" | grep -qE "#[a-zA-Z]*\([^)]*[A-Za-z0-9_]\.${prop}\b" || continue

    if [ $status -eq 0 ]; then
      echo "check-leaf-semantics: Leaf cannot resolve Swift properties on a collection." >&2
      echo "  The path resolves to nil, so a conditional on it silently never" >&2
      echo "  fires — or, negated, always fires. Use the count() tag instead:" >&2
      echo "    #if(count(rows) == 0):   not  #if(rows.isEmpty):" >&2
      echo "    #if(count(rows) > 0):    not  #if(!rows.isEmpty):" >&2
      echo "" >&2
    fi
    status=1
    echo "  $line" >&2
  done <<< "$(grep -rnE "#[a-zA-Z]*\([^)]*[A-Za-z0-9_]\.${prop}\b" Resources/Views/ 2>/dev/null || true)"
done

if [ $status -eq 0 ]; then
  echo "check-leaf-semantics: OK (no Swift property access in Leaf tag parameters)"
fi

exit $status
