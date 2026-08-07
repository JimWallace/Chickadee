// APIServer/Services/CppPersonalizationDriver.swift
//
// The C++ personalization driver: evaluates an assignment's `=` expressions
// server-side, like the python3/Rscript/lua/octave-cli drivers — except C++
// has no interpreter, so the "driver" is a shell script that compiles a
// generated program with g++ and runs it (~0.3s per evaluation, measured;
// docs/cpp-support.md). The evaluator invokes it with `sh`, keeping one
// spawn shape for all five languages.
//
// Output protocol (shared with the other drivers): the LAST stdout line is a
// JSON object mapping each expression name to the value rendered as a
// LITERAL IN THIS LANGUAGE — the server parses nothing, it writes the text
// verbatim into `_ck_inputs.hpp`. The serializer therefore mirrors
// `JSONValue.cppLiteral`'s conventions exactly (LL suffix, `.0` forcing,
// `std::string(...)`, explicitly-typed vectors/maps).

import Core
import Foundation

enum CppPersonalizationDriver {

    /// The complete `.sh` driver: heredoc the C++ program, compile, exec.
    static func renderDriverScript(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportFiles: [String] = []
    ) -> String {
        let program = renderDriverProgram(
            staticVariables: staticVariables,
            expressions: expressions,
            supportFiles: supportFiles)
        return """
            #!/bin/sh
            # Auto-generated personalization driver. Do not edit.
            cat > .ck_personalize_driver.cpp <<'CHICKADEE_GENERATED_SOURCE'
            \(program)
            CHICKADEE_GENERATED_SOURCE
            g++ -std=c++20 -O0 .ck_personalize_driver.cpp -o .ck_personalize_driver 1>&2 || exit 3
            exec ./.ck_personalize_driver
            """ + "\n"
    }

    private static func renderDriverProgram(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportFiles: [String]
    ) -> String {
        var lines: [String] = [
            "// Auto-generated personalization driver. Do not edit.",
            "#include <cctype>",
            "#include <cmath>",
            "#include <cstdio>",
            "#include <cstdlib>",
            "#include <iostream>",
            "#include <limits>",
            "#include <map>",
            "#include <sstream>",
            "#include <string>",
            "#include <vector>",
            "",
            seedSource,
            "",
            serializerSource,
            "",
        ]
        if !supportFiles.isEmpty {
            lines.append("// Auto-included support files (instructor helpers + the extracted")
            lines.append("// reference solution), single-TU like the generated tests. `main` is")
            lines.append("// renamed so a main-bearing helper cannot collide with the driver's.")
            lines.append("#define main ck_support_main")
            for name in supportFiles {
                lines.append("#include \"\(name)\"")
            }
            lines.append("#undef main")
            lines.append("")
        }
        lines.append("// Static globals + section variables (in scope for expressions).")
        for variable in staticVariables {
            lines.append("inline const auto \(variable.name) = \(variable.value.cppLiteral);")
        }
        lines.append("")
        lines.append("int main() {")
        lines.append("    const long long seed = ck_seed();")
        lines.append("    (void)seed;")
        lines.append("    // Expressions bind in declared order, so later ones can reference")
        lines.append("    // earlier ones — same scoping as the other drivers.")
        var pairEmits: [String] = []
        for expression in expressions {
            lines.append("    auto \(expression.name) = (\(expression.expression));")
            pairEmits.append(
                "    ck_pairs.push_back(ck_json_string(\"\(expression.name)\") + \":\" "
                    + "+ ck_json_string(ck_literal(\(expression.name))));")
        }
        lines.append("    std::vector<std::string> ck_pairs;")
        lines.append(contentsOf: pairEmits)
        lines.append("    std::string ck_joined;")
        lines.append("    for (size_t ck_i = 0; ck_i < ck_pairs.size(); ++ck_i) {")
        lines.append("        if (ck_i) ck_joined += \",\";")
        lines.append("        ck_joined += ck_pairs[ck_i];")
        lines.append("    }")
        lines.append("    std::cout << \"{\" << ck_joined << \"}\\n\";")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// The shared seed fold — Horner base-16 over the hex digits of
    /// CHICKADEE_ASSIGNMENT_SEED, mod 2^31−1 — matching
    /// `chickadee_seed()` in the R/Lua/Octave runtimes digit for digit, so a
    /// student's seed is one number in every language.
    static let seedSource = #"""
        static long long ck_seed() {
            const char* raw = std::getenv("CHICKADEE_ASSIGNMENT_SEED");
            if (!raw) return 0;
            const long long modulus = 2147483647;
            long long acc = 0;
            bool any = false;
            for (const char* p = raw; *p; ++p) {
                unsigned char c = static_cast<unsigned char>(std::tolower(*p));
                int digit;
                if (c >= '0' && c <= '9') digit = c - '0';
                else if (c >= 'a' && c <= 'f') digit = 10 + (c - 'a');
                else continue;
                any = true;
                acc = (acc * 16 + digit) % modulus;
            }
            return any ? acc : 0;
        }
        """#

    /// `ck_literal(value)` — the value as C++ SOURCE, mirroring
    /// `JSONValue.cppLiteral`; plus `ck_json_string`, the JSON string encoder
    /// the output map rides in.
    static let serializerSource = #"""
        static std::string ck_json_string(const std::string& s) {
            std::string out = "\"";
            for (unsigned char c : s) {
                switch (c) {
                    case '"': out += "\\\""; break;
                    case '\\': out += "\\\\"; break;
                    case '\n': out += "\\n"; break;
                    case '\t': out += "\\t"; break;
                    case '\r': out += "\\r"; break;
                    default:
                        if (c < 0x20) {
                            char buf[8];
                            std::snprintf(buf, sizeof buf, "\\u%04x", c);
                            out += buf;
                        } else {
                            out += static_cast<char>(c);
                        }
                }
            }
            return out + "\"";
        }
        static std::string ck_cpp_string_escape(const std::string& s) {
            std::string out;
            for (unsigned char c : s) {
                switch (c) {
                    case '"': out += "\\\""; break;
                    case '\\': out += "\\\\"; break;
                    case '\n': out += "\\n"; break;
                    case '\t': out += "\\t"; break;
                    case '\r': out += "\\r"; break;
                    default:
                        if (c < 0x20 || c == 0x7F) {
                            char buf[8];
                            std::snprintf(buf, sizeof buf, "\\%03o", c);
                            out += buf;
                        } else {
                            out += static_cast<char>(c);
                        }
                }
            }
            return out;
        }
        static std::string ck_literal(bool v) { return v ? "true" : "false"; }
        static std::string ck_literal(const std::string& v) {
            return "std::string(\"" + ck_cpp_string_escape(v) + "\")";
        }
        static std::string ck_literal(const char* v) { return ck_literal(std::string(v)); }
        template <typename T>
            requires (std::is_integral_v<T> && !std::is_same_v<T, bool>)
        static std::string ck_literal(T v) {
            long long wide = static_cast<long long>(v);
            std::string digits = std::to_string(wide);
            if (wide > 2147483647LL || wide < -2147483648LL) digits += "LL";
            return digits;
        }
        template <typename T>
            requires std::is_floating_point_v<T>
        static std::string ck_literal(T v) {
            if (std::isnan(v)) return "std::nan(\"\")";
            if (std::isinf(v)) {
                return v < 0 ? "(-std::numeric_limits<double>::infinity())"
                             : "std::numeric_limits<double>::infinity()";
            }
            char buf[64];
            std::snprintf(buf, sizeof buf, "%.17g", static_cast<double>(v));
            std::string s(buf);
            if (s.find('.') == std::string::npos && s.find('e') == std::string::npos
                && s.find("inf") == std::string::npos && s.find("nan") == std::string::npos) {
                s += ".0";
            }
            return s;
        }
        template <typename T>
        static std::string ck_literal(const std::vector<T>& v);
        template <typename T>
        static std::string ck_literal(const std::map<std::string, T>& m);
        template <typename T>
        static std::string ck_element_type();
        template <> std::string ck_element_type<bool>() { return "bool"; }
        template <> std::string ck_element_type<std::string>() { return "std::string"; }
        template <typename T>
        std::string ck_element_type() {
            if constexpr (std::is_floating_point_v<T>) return "double";
            else if constexpr (std::is_integral_v<T>) return "long long";
            else return "auto";
        }
        template <typename T>
        static std::string ck_literal(const std::vector<T>& v) {
            std::string out = "std::vector<" + ck_element_type<T>() + ">{";
            for (size_t i = 0; i < v.size(); ++i) {
                if (i) out += ", ";
                out += ck_literal(v[i]);
            }
            return out + "}";
        }
        template <typename T>
        static std::string ck_literal(const std::map<std::string, T>& m) {
            std::string out = "std::map<std::string, " + ck_element_type<T>() + ">{";
            bool first = true;
            for (const auto& [key, value] : m) {
                if (!first) out += ", ";
                first = false;
                out += "{\"" + ck_cpp_string_escape(key) + "\", " + ck_literal(value) + "}";
            }
            return out + "}";
        }
        """#
}
