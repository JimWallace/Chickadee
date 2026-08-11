// APIServer/Services/JavaPersonalizationDriver.swift
//
// The Java personalization driver: evaluates an assignment's `=` expressions
// server-side, like the python3/Rscript/lua/octave-cli drivers — except Java,
// like C++, has no interpreter to hand an expression to, so the "driver" is a
// shell script that compiles a generated program with javac and runs it. The
// evaluator invokes it with `sh`, keeping one spawn shape for every language.
//
// Output protocol (shared with the other drivers): the LAST stdout line is a
// JSON object mapping each expression name to the value rendered as a LITERAL
// IN THIS LANGUAGE — the server parses nothing, it writes the text verbatim
// into `_ck_inputs.java`. The serializer therefore mirrors
// `JSONValue.javaLiteral`'s conventions exactly (`L` only past int32, `.0`
// forcing, `Arrays.asList`, the LinkedHashMap form, and never a
// backslash-u escape).
//
// WHY NOT SINGLE-FILE SOURCE MODE. `java Driver.java` would skip the compile
// step and looks tempting — but it compiles exactly ONE file, and the driver
// must be compiled alongside the assignment's `.java` support helpers (the
// instructor's code and the extracted reference solution) for an expression to
// call them. That is the same limitation that makes GENERATED TESTS `.sh`
// wrappers rather than `.java` files.

import Core
import Foundation

enum JavaPersonalizationDriver {

    /// The complete `.sh` driver: heredoc the Java program, compile it with the
    /// support files, run it.
    static func renderDriverScript(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportFiles: [String] = []
    ) -> String {
        let program = renderDriverProgram(
            staticVariables: staticVariables,
            expressions: expressions)
        // Support files are named on the javac command line rather than
        // `#include`d as C++ does, because Java has no textual inclusion: each
        // is its own compilation unit and its classes land on the classpath for
        // the driver to call.
        let sources = (["CkPersonalizeDriver.java"] + supportFiles)
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        return """
            #!/bin/sh
            # Auto-generated personalization driver. Do not edit.
            cat > CkPersonalizeDriver.java <<'CHICKADEE_GENERATED_SOURCE'
            \(program)
            CHICKADEE_GENERATED_SOURCE
            javac -d . \(sources) 1>&2 || exit 3
            exec java -cp . CkPersonalizeDriver
            """ + "\n"
    }

    private static func renderDriverProgram(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression]
    ) -> String {
        var lines: [String] = [
            "// Auto-generated personalization driver. Do not edit.",
            "import java.util.ArrayList;",
            "import java.util.Collection;",
            "import java.util.List;",
            "import java.util.Map;",
            "",
            "public class CkPersonalizeDriver {",
            "",
            seedSource,
            "",
            serializerSource,
            "",
            "    public static void main(String[] ckArgs) throws Exception {",
            "        final long seed = ckSeed();",
            "        List<String> ckPairs = new ArrayList<String>();",
            "        // Static globals + section variables, in scope for expressions.",
        ]
        for variable in staticVariables {
            lines.append("        \(binding(name: variable.name, value: variable.value.javaLiteral));")
        }
        lines.append("        // Expressions bind in declared order, so later ones can reference")
        lines.append("        // earlier ones — same scoping as the other drivers.")
        for expression in expressions {
            lines.append("        \(binding(name: expression.name, value: "(\(expression.expression))"));")
            lines.append(
                "        ckPairs.add(ckJsonString(\"\(expression.name)\") + \":\" "
                    + "+ ckJsonString(ckLiteral(\(expression.name))));")
        }
        lines.append("        StringBuilder ckJoined = new StringBuilder();")
        lines.append("        for (int ckI = 0; ckI < ckPairs.size(); ckI++) {")
        lines.append("            if (ckI > 0) ckJoined.append(\",\");")
        lines.append("            ckJoined.append(ckPairs.get(ckI));")
        lines.append("        }")
        lines.append("        System.out.println(\"{\" + ckJoined + \"}\");")
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// One local binding. `var` is Java's `auto`, so each value keeps the
    /// natural type its expression has — which is what lets a later expression
    /// use an earlier one arithmetically.
    ///
    /// The one shape `var` cannot infer is a bare `null`, which has only the
    /// null type; that binds as `Object` instead. Reachable whenever an author
    /// writes a global whose value is JSON null, which is an ordinary thing to
    /// do, so it is handled rather than left to produce a compile error the
    /// instructor cannot read.
    private static func binding(name: String, value: String) -> String {
        value == "null" ? "Object \(name) = null" : "var \(name) = \(value)"
    }

    /// The shared seed fold — Horner base-16 over the hex digits of
    /// CHICKADEE_ASSIGNMENT_SEED, mod 2^31−1 — matching `chickadee_seed()` in
    /// the R/Lua/Octave runtimes and `ck_seed()` in the C++ one digit for
    /// digit, so a student's seed is one number in every language.
    ///
    /// Java has `BigInteger` and would not need a fold at all. It uses one
    /// anyway: base R has no bignum, and every language matches R rather than
    /// each doing its best.
    static let seedSource = #"""
            private static long ckSeed() {
                String raw = System.getenv("CHICKADEE_ASSIGNMENT_SEED");
                if (raw == null) return 0L;
                final long modulus = 2147483647L;
                long acc = 0L;
                boolean any = false;
                for (int i = 0; i < raw.length(); i++) {
                    int digit = Character.digit(raw.charAt(i), 16);
                    if (digit < 0) continue;
                    any = true;
                    acc = (acc * 16L + digit) % modulus;
                }
                return any ? acc : 0L;
            }
        """#

    /// `ckLiteral(value)` — the value as Java SOURCE, mirroring
    /// `JSONValue.javaLiteral`; plus `ckJsonString`, the JSON string encoder the
    /// output map rides in.
    ///
    /// Two encoders that look alike and are not: `ckJavaString` produces JAVA
    /// SOURCE (octal escapes, never backslash-u, because javac processes those
    /// in the lexer and a newline escape would break the generated file), while
    /// `ckJsonString` produces a JSON string for the protocol line. Conflating
    /// them would corrupt one or the other.
    static let serializerSource = #"""
            private static String ckJsonString(String s) {
                StringBuilder out = new StringBuilder("\"");
                for (int i = 0; i < s.length(); i++) {
                    char c = s.charAt(i);
                    if (c == '\\' || c == '"') out.append('\\').append(c);
                    else if (c == '\n') out.append("\\n");
                    else if (c == '\r') out.append("\\r");
                    else if (c == '\t') out.append("\\t");
                    else if (c < 0x20 || c == 0x7F) out.append(String.format("\\u%04x", (int) c));
                    else out.append(c);
                }
                return out.append('"').toString();
            }

            private static String ckJavaString(String s) {
                StringBuilder out = new StringBuilder("\"");
                for (int i = 0; i < s.length(); i++) {
                    char c = s.charAt(i);
                    if (c == '\\' || c == '"') out.append('\\').append(c);
                    else if (c == '\n') out.append("\\n");
                    else if (c == '\r') out.append("\\r");
                    else if (c == '\t') out.append("\\t");
                    else if (c < 0x20 || c == 0x7F) out.append(String.format("\\%03o", (int) c));
                    else out.append(c);
                }
                return out.append('"').toString();
            }

            private static String ckLiteral(Object v) {
                if (v == null) return "null";
                if (v instanceof Boolean) return ((Boolean) v) ? "true" : "false";
                if (v instanceof Double || v instanceof Float) {
                    double d = ((Number) v).doubleValue();
                    if (Double.isNaN(d)) return "Double.NaN";
                    if (Double.isInfinite(d)) {
                        return d < 0 ? "Double.NEGATIVE_INFINITY" : "Double.POSITIVE_INFINITY";
                    }
                    String s = String.valueOf(d);
                    return (s.contains(".") || s.contains("e") || s.contains("E")) ? s : s + ".0";
                }
                if (v instanceof Number) {
                    long n = ((Number) v).longValue();
                    return (n > 2147483647L || n < -2147483648L) ? (n + "L") : String.valueOf(n);
                }
                if (v instanceof Character || v instanceof CharSequence) {
                    return ckJavaString(v.toString());
                }
                if (v instanceof Map<?, ?>) {
                    StringBuilder out =
                        new StringBuilder("new java.util.LinkedHashMap<String, Object>() {{ ");
                    for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) {
                        out.append("put(")
                           .append(ckJavaString(String.valueOf(e.getKey())))
                           .append(", ")
                           .append(ckLiteral(e.getValue()))
                           .append("); ");
                    }
                    return out.append("}}").toString();
                }
                List<Object> items = null;
                if (v instanceof Collection<?>) {
                    items = new ArrayList<Object>((Collection<?>) v);
                } else if (v.getClass().isArray()) {
                    int n = java.lang.reflect.Array.getLength(v);
                    items = new ArrayList<Object>(n);
                    for (int i = 0; i < n; i++) items.add(java.lang.reflect.Array.get(v, i));
                }
                if (items != null) {
                    StringBuilder out = new StringBuilder("java.util.Arrays.asList(");
                    for (int i = 0; i < items.size(); i++) {
                        if (i > 0) out.append(", ");
                        out.append(ckLiteral(items.get(i)));
                    }
                    return out.append(")").toString();
                }
                // Nothing else has an honest Java rendering. Emitting an
                // undefined identifier makes the NEXT compile fail loudly
                // rather than writing a plausible-looking wrong value into
                // _ck_inputs.java — the same backstop posture as the renderers.
                return "CK_UNRENDERABLE_VALUE_OF_TYPE_" + v.getClass().getSimpleName();
            }
        """#
}
