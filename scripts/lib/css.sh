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
page_style_blocks() {
  local f
  for f in "$@"; do
    sed -n '/<style>/,/<\/style>/p' "$f"
  done
}
