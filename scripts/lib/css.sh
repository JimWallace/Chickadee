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

# Prints the page CSS of the named Elementary views (.swift files), in order.
# A view holds its page CSS in a PageStyle("""...""") literal. Its body is
# printed between <style> and </style> lines, so a caller reads every view's
# page CSS as a run of style blocks.
page_style_blocks() {
  local f
  for f in "$@"; do
    awk '
      /PageStyle\(/ { pending = 1 }
      pending && !inblock && /"""/ { inblock = 1; pending = 0; print "<style>"; next }
      inblock && /"""/ { inblock = 0; print "</style>"; next }
      inblock { print }
    ' "$f"
  done
}

# Prints the Elementary view files that hold a PageStyle block, one per line,
# in a stable order. These are the page CSS the style guards read.
swift_page_style_files() {
  grep -rlE 'PageStyle\(' Sources/APIServer/Views --include='*.swift' 2>/dev/null \
    | while IFS= read -r f; do grep -q '"""' "$f" && printf '%s\n' "$f"; done \
    | LC_ALL=C sort
}

# Prints every Elementary view source file, one per line, in a stable order.
# Every page is built from these. The guards that grep markup source read
# them; the rules that need rendered markup are in
# Tests/APITests/RenderedMarkupRules.swift.
swift_view_files() {
  find Sources/APIServer/Views -name '*.swift' | LC_ALL=C sort
}

# swift_call_literals NEEDLE SEP FILE...
#
# For each call in the Swift files whose text starts with NEEDLE (which ends
# inside the call's argument list, e.g. `.class(` or
# `.custom(name: "style", value:`), prints `file:line<TAB>literals`: the text
# of every string literal among the call's arguments, joined with SEP.
#
# The walk tracks strings, interpolations and parentheses, so it reads a call
# that spans lines, a value concatenated with `+` (SEP ""), every literal of a
# ternary (`.class(open ? "a b" : "a")`, SEP " "), and a literal inside an
# interpolation (`"card \(open ? "is-open" : "")"`). An interpolation becomes
# `_` in the literal around it. A value held in a variable is out of reach;
# the rendered-page rules (Tests/APITests/RenderedMarkupRules.swift) read it.
swift_call_literals() {
  local needle="$1" sep="$2"
  shift 2
  awk -v needle="$needle" -v sep="$sep" '
    FNR == 1 && NR > 1 { walk(text, prev) }
    FNR == 1 { text = ""; prev = FILENAME }
    { text = text $0 "\n" }
    END { if (NR > 0) walk(text, prev) }
    function walk(text, file,   n, i, p, top, mode, depth, seg, ch, out, nested, line, start, pre) {
      n = length(text); i = 1; line = 1
      while (i <= n) {
        p = index(substr(text, i), needle)
        if (p == 0) break
        pre = substr(text, i, p - 1); line += gsub(/\n/, "\n", pre)
        i += p - 1 + length(needle); start = line
        # A stack of modes: "c" is code, with a paren depth; "s" is a string.
        # A literal of the call itself is at depth 2 of the stack; one inside
        # an interpolation is deeper, and is printed after the call literals
        # so it never splits a concatenated value.
        top = 1; mode[1] = "c"; depth[1] = 1; out = ""; nested = ""
        while (i <= n && top > 0) {
          ch = substr(text, i, 1)
          if (ch == "\n") line++
          if (mode[top] == "c") {
            if (ch == "\"") { top++; mode[top] = "s"; seg[top] = "" }
            else if (ch == "(") depth[top]++
            else if (ch == ")") { depth[top]--; if (depth[top] == 0) top-- }
            i++
          } else if (ch == "\\") {
            if (substr(text, i + 1, 1) == "(") { seg[top] = seg[top] "_"; top++; mode[top] = "c"; depth[top] = 1 }
            i += 2
          } else if (ch == "\"" || ch == "\n") {
            if (top == 2) out = (out == "") ? seg[top] : out sep seg[top]
            else nested = (nested == "") ? seg[top] : nested " " seg[top]
            top--; i++
          } else { seg[top] = seg[top] ch; i++ }
        }
        if (nested != "") out = (out == "") ? nested : out " " nested
        print file ":" start "\t" out
      }
    }
  ' "$@"
}
