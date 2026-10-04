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
#   bucket.count    ActivityBucket.count (UserActivityChartService.swift) is the
#                   distinct-active-users number for that bucket.
#
# Both are indistinguishable to a reader from the broken form, which is exactly
# why they are named here rather than left to be re-derived. Add a pair only
# after confirming the struct declares the property.
#
# A SECOND IDIOM THAT LOOKS RIGHT: a line comment. Leaf has none.
# `LeafLexer.lexCheckTagIndicator` pops the `#`, peeks the next character, and
# takes the tag path only when it is a letter or an open paren — so a `#`
# followed by a slash emits a raw `#` and returns to raw state. The rest of the
# line is raw text, which means the "comment" does not disappear, it PRINTS:
# into the page, into any fragment the partial serves, and any markup inside it
# is emitted for real. It is the same rule that makes `C#` and `id="#main"`
# inert, seen from the other side — "passes through as text" is invisible only
# inside an HTML comment.
#
# It shipped once, as a thirteen-line header on `_leaderboard-body.leaf` that
# rendered above the results and rode every five-second refresh, with an
# unclosed heading tag in it. Render tests could not see it (the template
# resolves, it just resolves wrong), which is this file's whole subject.
# Comment a template with an HTML comment, as the other partials do.
#
# A THIRD: Leaf tag syntax inside an HTML comment. Leaf's lexer has no notion
# of an HTML comment, so `<!-- ... -->` is raw text to it and a tag written
# there is lexed as if it stood in the markup. A structural tag name with no
# parameter list is a 500 at render; an interpolation prints the real context
# value into the served HTML. CLAUDE.md records the full table. An unknown
# `#word` (a CSS id in prose) is inert, so only the interpolation opener and
# the structural tag names are rejected.
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

# Every template, at any depth, in a stable order.
leaf_files=()
while IFS= read -r f; do
  leaf_files+=("$f")
done < <(find Resources/Views -name '*.leaf' | LC_ALL=C sort)

# Receiver.property pairs that resolve to a real encoded value. See the note
# above before adding one.
allowed_pairs="bar.isEmpty bucket.count"

# Swift property names Leaf cannot resolve on a collection or string. Each
# resolves to nil and is then silently swallowed by whatever consumes it.
swift_only_properties="isEmpty count"

# Every Leaf tag parameter list in the templates, one line per template line
# that has any: "file:line:params". The list ends at the parenthesis that
# CLOSES it, counted by depth, so `#if(count(rows) > 0 && other.isEmpty)` is
# read whole. A regex that stopped at the first `)` read only `count(rows` and
# let the compound shape through, and the count() fix is exactly what produces
# that shape. POSIX awk only: the CI image has mawk.
tag_parameters="$(
  awk '
    {
      line = $0; n = length(line); i = 1; out = ""
      while (i <= n) {
        if (substr(line, i, 1) != "#") { i++; continue }
        j = i + 1
        while (j <= n && substr(line, j, 1) ~ /[A-Za-z]/) j++
        if (j > n || substr(line, j, 1) != "(") { i++; continue }
        depth = 1; k = j + 1
        while (k <= n && depth > 0) {
          c = substr(line, k, 1)
          if (c == "(") depth++
          else if (c == ")") depth--
          k++
        }
        out = out " " substr(line, j + 1, k - j - 1)
        i = k
      }
      if (out != "") print FILENAME ":" FNR ":" out
    }
  ' "${leaf_files[@]}"
)"

property_header_printed=""
for prop in $swift_only_properties; do
  # Match the property only where it terminates a dotted path inside a Leaf
  # tag's parameter list — `#if(x.isEmpty)`, `#(a.b.count)`. A bare word in
  # prose is not matched, so documentation describing the forbidden idiom does
  # not trip the guard that forbids it.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    params="${rest#*:}"

    # Strip every allowlisted pair for this property, then re-test. A line is
    # only clean if NOTHING unallowlisted remains, so an allowlisted receiver
    # cannot shelter a broken one beside it on the same line.
    remaining="$params"
    for pair in $allowed_pairs; do
      case "$pair" in
        *".${prop}")
          receiver="${pair%.*}"
          remaining="$(printf '%s' "$remaining" | sed -E "s/(^|[^A-Za-z0-9_])${receiver}\.${prop}\b/\1/g")"
          ;;
      esac
    done
    grep -qE "[A-Za-z0-9_]\.${prop}\b" <<< "$remaining" || continue

    if [ -z "$property_header_printed" ]; then
      echo "check-leaf-semantics: Leaf cannot resolve Swift properties on a collection." >&2
      echo "  The path resolves to nil, so a conditional on it silently never" >&2
      echo "  fires — or, negated, always fires. Use the count() tag instead:" >&2
      echo "    #if(count(rows) == 0):   not  #if(rows.isEmpty):" >&2
      echo "    #if(count(rows) > 0):    not  #if(!rows.isEmpty):" >&2
      echo "" >&2
      property_header_printed=1
    fi
    status=1
    echo "  ${file}:${lineno}:$(sed -n "${lineno}p" "$file")" >&2
  done <<< "$(grep -E "[A-Za-z0-9_]\.${prop}\b" <<< "$tag_parameters" || true)"
done

# The line-comment rule. The forbidden sequence is BUILT rather than written,
# so this script's own prose describing it cannot trip a future guard that
# scans more than templates — the trap CLAUDE.md records twice, where a guard
# matched its own documentation.
tag_indicator='#'
line_comment_opener="${tag_indicator}/"
line_comment_header_printed=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [ -z "$line_comment_header_printed" ]; then
    line_comment_header_printed=1
    echo "check-leaf-semantics: Leaf has no line-comment syntax." >&2
    echo "  A tag indicator followed by a slash lexes as RAW TEXT, so the" >&2
    echo "  comment renders into the page — and into any fragment the" >&2
    echo "  template serves — with any markup inside it emitted for real." >&2
    echo "  Use an HTML comment, as the other partials do." >&2
    echo "" >&2
  fi
  status=1
  echo "  $line" >&2
done <<< "$(grep -rn -- "$line_comment_opener" Resources/Views/ 2>/dev/null || true)"

# The HTML-comment rule. The text between each comment opener and closer is
# collected across lines, and a hit is reported at the line it is on. As with
# the line-comment rule, the forbidden sequences are built, not written.
structural_tags="extend|endextend|export|endexport|import|if|elseif|else|endif|for|endfor|while|endwhile"
comment_hits="$(
  awk -v ind="$tag_indicator" -v tags="$structural_tags" '
    FNR == 1 { incomment = 0 }
    {
      line = $0; text = ""
      while (length(line)) {
        if (incomment) {
          p = index(line, "-->")
          if (p == 0) { text = text " " line; line = "" }
          else { text = text " " substr(line, 1, p - 1); line = substr(line, p + 3); incomment = 0 }
        } else {
          p = index(line, "<!--")
          if (p == 0) { line = "" }
          else { line = substr(line, p + 4); incomment = 1 }
        }
      }
      if (text == "") next
      interp = ind "("
      structural = ind "(" tags ")([^A-Za-z0-9_]|$)"
      if (index(text, interp) > 0 || text ~ structural) print FILENAME ":" FNR ":" $0
    }
  ' "${leaf_files[@]}"
)"
if [ -n "$comment_hits" ]; then
  status=1
  echo "check-leaf-semantics: Leaf tag syntax inside an HTML comment." >&2
  echo "  Leaf does not know HTML comments, so a tag there runs as if it were" >&2
  echo "  in the markup: a structural tag name is a 500 at render, and an" >&2
  echo "  interpolation prints the real value into the page. Describe the tag" >&2
  echo "  in words instead, for example \"the extend\"." >&2
  echo "" >&2
  printf '%s\n' "$comment_hits" | sed 's/^/  /' >&2
fi

if [ $status -eq 0 ]; then
  echo "check-leaf-semantics: OK (no Swift property access, line comments or tags in HTML comments in templates)"
fi

exit $status
