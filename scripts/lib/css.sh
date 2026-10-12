#!/usr/bin/env bash
# css.sh — CSS text helpers shared by the style guards. Sourced by
# check-class-resolution.sh, check-design-tokens.sh, check-maintenance-palette.sh,
# check-styles.sh and check-ui-vocabulary.sh; not executable on its own.
#
# There were six comment strippers (#1982): two multi-line awk copies of one
# algorithm, three single-line sed expressions, and one grep filter that
# matched nothing. A single-line strip keeps every line of a multi-line comment
# but the first, so a guard read the sheet's prose as rules: class resolution
# counted 19 names as defined that appear only in comments, among them the
# retired admin-section, so a template using it passed.

# Prints its input (the files named as arguments, or stdin) with every
# /* ... */ comment removed, including one that spans lines. A comment-only
# line prints as an empty line, so line numbers stay aligned with the source.
strip_css_comments() {
  awk '
    {
      line = $0; out = ""
      while (length(line) > 0) {
        if (incomment) {
          p = index(line, "*/")
          if (p == 0) { line = "" } else { line = substr(line, p + 2); incomment = 0 }
        } else {
          p = index(line, "/*")
          if (p == 0) { out = out line; line = "" }
          else { out = out substr(line, 1, p - 1); line = substr(line, p + 2); incomment = 1 }
        }
      }
      print out
    }
  ' "$@"
}

# Prints every <style> ... </style> block of the named templates, in order.
# An Elementary view (a .swift file) holds its page CSS in a
# PageStyle("""...""") literal instead; its body is printed between <style>
# and </style> lines, so every caller reads both kinds the same way.
page_style_blocks() {
  local f
  for f in "$@"; do
    case "$f" in
      *.swift)
        awk '
          /PageStyle\(/ { pending = 1 }
          pending && !inblock && /"""/ { inblock = 1; pending = 0; print "<style>"; next }
          inblock && /"""/ { inblock = 0; print "</style>"; next }
          inblock { print }
        ' "$f"
        ;;
      *) sed -n '/<style>/,/<\/style>/p' "$f" ;;
    esac
  done
}

# Templates that no route renders any more: their page moved to an Elementary
# view, and the template stays only because PageArchetypeTests reads it as an
# archetype exemplar (docs/ui-design.md). Their page CSS lives in the Swift
# view now, so the page-CSS rules skip the template copy rather than count the
# same rules twice. The list shrinks to nothing when the exemplars move to
# Swift (docs/elementary-spike.md); never add a template that is still served.
retired_exemplar_templates="Resources/Views/admin-user.leaf Resources/Views/register.leaf Resources/Views/alerts.leaf"

# Prints the templates whose page CSS the style guards read: every template
# except the retired exemplars above.
served_style_templates() {
  local f
  for f in Resources/Views/*.leaf; do
    case " $retired_exemplar_templates " in *" $f "*) ;; *) printf '%s\n' "$f" ;; esac
  done
}

# Prints the Elementary view files that hold a PageStyle block, one per line,
# in a stable order. The style guards add these to the templates they read.
swift_page_style_files() {
  grep -rlE 'PageStyle\(' Sources/APIServer/Views --include='*.swift' 2>/dev/null \
    | while IFS= read -r f; do grep -q '"""' "$f" && printf '%s\n' "$f"; done \
    | LC_ALL=C sort
}
