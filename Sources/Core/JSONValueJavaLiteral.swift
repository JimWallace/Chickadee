// Core/JSONValueJavaLiteral.swift
//
// Rendering a JSONValue as a Java expression, for generated pattern-family
// tests. Split from JSONValue.swift for length; same shape as the other five
// literal renderers.

import Foundation

extension JSONValue {

    /// Render this value as a Java expression.
    ///
    /// Java is the SECOND statically-typed target, and it lands on the opposite
    /// answer to C++ for the question that shaped `cppLiteral`. C++ needs a
    /// type for every literal, so `[1, "two"]` has no honest rendering and is
    /// refused at save time. Java has `Object`, autoboxing and generics, so
    /// `Arrays.asList(1, "two")` is a `List<Object>` and every JSONValue shape
    /// renders. **There is deliberately no `javaRenderabilityIssue`** — the
    /// question C++ has to ask does not arise here, and inventing a refusal
    /// table to mirror the neighbour would reject values Java can express.
    ///
    /// Three rules, each of which is a measured trap rather than a preference:
    ///
    ///   - **Integers render as `int` when they fit in `int`, `L`-suffixed
    ///     otherwise.** This is the one place a wrong choice fails to build:
    ///     Java widens `int` to `long`/`double` implicitly but does NOT narrow,
    ///     so a `long`-typed literal handed to a student's `f(int x)` is
    ///     "possible lossy conversion" and the test never compiles. C++'s
    ///     `LL`-suffix rule looks identical and fails in the opposite
    ///     direction, which is why this is stated rather than copied.
    ///   - **Arrays always use `Arrays.asList(...)`, never `List.of(...)`.**
    ///     `List.of` throws `NullPointerException` on a null element, so a JSON
    ///     null inside an array would turn an authored case into a runtime
    ///     error instead of a value. One form for every array means the null
    ///     case cannot be reached by a branch nobody tested.
    ///   - **Objects use an insertion-ordered `LinkedHashMap`**, for the same
    ///     reason: `Map.of` / `Map.ofEntries` reject null values. Map equality
    ///     is order-independent, so the ordering is for readable failure
    ///     messages rather than correctness.
    ///
    /// Everything renders fully qualified (`java.util.Arrays`, not `Arrays`),
    /// because these expressions are pasted into generated sources whose import
    /// list is not under this function's control — `_ck_inputs.java` in
    /// particular is a pure data file with no imports at all.
    public var javaLiteral: String {
        switch self {
        case .null:
            // Java has a null. Unlike C++, nothing needs refusing — but the
            // *static type* of a bare `null` is the null type, so a value that
            // may be null is rendered into an `Object`-typed context by
            // `renderInputsFile` rather than an inferred one.
            return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i):
            // See the doc above: `L` only past `int`, because narrowing is a
            // compile error and widening is not.
            return (i > Int(Int32.max) || i < Int(Int32.min)) ? "\(i)L" : String(i)
        case .double(let d):
            // The boxed constants, not `0.0/0.0`: a division by zero in a
            // constant-folded context is a compile-time error for integers and
            // merely surprising for doubles, and these spellings say what they
            // mean. They need no import.
            if d.isNaN { return "Double.NaN" }
            if d.isInfinite {
                return d < 0 ? "Double.NEGATIVE_INFINITY" : "Double.POSITIVE_INFINITY"
            }
            let s = String(d)
            return (s.contains(".") || s.contains("e") || s.contains("E")) ? s : s + ".0"
        case .string(let s):
            return encodeJavaString(s)
        case .array(let a):
            // `Arrays.asList`, always — see the doc. An empty array is
            // `java.util.Arrays.asList()`, a legal zero-arg varargs call
            // yielding an empty `List<Object>`.
            let inner = a.map(\.javaLiteral).joined(separator: ", ")
            return "java.util.Arrays.asList(\(inner))"
        case .object(let o):
            // Anonymous-subclass ("double brace") initialisation, which is the
            // only self-contained Java *expression* that builds an ordered map
            // admitting null values. It is legal in a static field initialiser
            // and in a method body alike, and `AbstractMap.equals` compares it
            // equal to a student's `HashMap` with the same entries.
            let pairs = o.sorted { $0.key < $1.key }
            guard !pairs.isEmpty else {
                return "new java.util.LinkedHashMap<String, Object>()"
            }
            let puts = pairs.map { "put(\(JSONValue.string($0.key).javaLiteral), \($0.value.javaLiteral)); " }
            return "new java.util.LinkedHashMap<String, Object>() {{ " + puts.joined() + "}}"
        }
    }
}

/// The Java type to DECLARE a field or variable holding `literal`.
///
/// WHY THIS PARSES A LITERAL INSTEAD OF ASKING THE VALUE. `_ck_inputs.java` is
/// written from text, not from `JSONValue`s: per-student values are computed by
/// the personalization driver, which reports each one as *already-rendered Java
/// source*, and `renderInputsFile` receives `[String: String]`. So at the point
/// the field must be declared there is no value left to ask.
///
/// The alternative was to declare every field `Object`, which is what the first
/// version did — and it does not compile at the call site. Java will not pass an
/// `Object` to a student's `f(int x)`, so every generated test that used a
/// per-student input would need a cast to a type the renderer cannot know.
/// Natural types make the ordinary case work with no cast at all, and Java's
/// widening (`int` → `long` → `double`) covers the rest.
///
/// This is safe to do by inspection because the grammar is CLOSED: every string
/// reaching here was produced by `javaLiteral` above or by the driver's
/// `ckLiteral`, which mirrors it deliberately. `JavaLiteralTypingTests` pins
/// that every `javaLiteral` output classifies to a type that actually holds it.
/// An unrecognised shape falls back to `Object`, which compiles for any use that
/// does not need a primitive — the safe direction.
public func javaDeclaredType(forLiteral literal: String) -> String {
    let trimmed = literal.trimmingCharacters(in: .whitespaces)
    if trimmed == "null" { return "Object" }
    if trimmed == "true" || trimmed == "false" { return "boolean" }
    if trimmed.hasPrefix("\"") { return "String" }
    if trimmed.hasPrefix("Double.") { return "double" }
    if trimmed.hasPrefix("java.util.Arrays.asList") { return "java.util.List<Object>" }
    if trimmed.hasPrefix("new java.util.LinkedHashMap") { return "java.util.Map<String, Object>" }
    // Numbers. The `L` suffix is the renderer's own marker for "too wide for
    // int", so it decides long-vs-int without re-deriving the bound.
    let numeric = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
    if let first = numeric.first, first.isNumber {
        if numeric.hasSuffix("L") { return "long" }
        if numeric.contains(".") || numeric.lowercased().contains("e") { return "double" }
        return "int"
    }
    return "Object"
}

/// Java string literals take C-style escapes — with one rule that has no
/// analogue in any other language here and breaks the source file when missed.
///
/// **Never emit a backslash-u escape.** Java processes unicode escapes in the
/// *lexer*, before it knows what a string literal is, so the escape for a
/// newline becomes an actual line break in the middle of a string and the file
/// fails to compile with "unclosed string literal" — measured, not theorised.
/// (This doc deliberately spells that escape out in words rather than writing
/// it, because a Swift doc comment is no safer a place for it.) Control
/// characters therefore use
/// the named escapes where they exist and exactly-three-digit octal otherwise,
/// which stops at three digits by rule (the same reason C++'s encoder avoids
/// `\x`).
///
/// Non-ASCII passes through as UTF-8 source bytes; `javac` reads UTF-8 source
/// by default on every platform Chickadee grades on.
private func encodeJavaString(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += #"\\"#
        case "\"": out += #"\""#
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 || ch.value == 0x7F {
                out += String(format: "\\%03o", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out + "\""
}
