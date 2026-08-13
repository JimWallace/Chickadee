// test_runtime.hpp — Chickadee's C++ grading runtime.
//
// The C++ member of the test_runtime family (.py/.R/.lua/.m), with the shape
// the language dictates: a HEADER of templates rather than a loadable module,
// because C++ reaches other code at compile time. A generated test forms one
// translation unit: this header, then the student's file (copied by the
// wrapper to .ck_solution.cpp, with `main` renamed so a main-bearing
// submission still exposes its functions), then the test's own main().
//
// Everything here was measured before it was written — see
// docs/cpp-support.md. The two decisions that came from measurement:
//   * std::cmp_equal rejects bool BY DESIGN, so equality promotes bools
//     explicitly; without that, a JSON `true` literal is three compile
//     errors.
//   * stdout capture is fd-level (dup2), not rdbuf: printf-using students
//     must grade the same as cout-using ones.
//
// Outcome contract: pass/fail/error print a one-line shortResult JSON to
// stdout and exit 0/1/2 — the ordinary shell-script contract, carried by the
// binary the wrapper exec's.
#pragma once
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <type_traits>
#include <unistd.h>
#include <utility>
#include <vector>

namespace ck {

// ---- JSON escaping for shortResult payloads ----
inline std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
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
    return out;
}

// ---- the shell contract's exit codes ----
[[noreturn]] inline void passed(const std::string& msg) {
    std::cout << "{\"shortResult\": \"" << json_escape(msg) << "\"}\n";
    std::exit(0);
}
[[noreturn]] inline void failed(const std::string& msg) {
    std::cout << "{\"shortResult\": \"" << json_escape(msg) << "\"}\n";
    std::exit(1);
}
[[noreturn]] inline void errored(const std::string& msg) {
    std::cerr << msg << "\n";
    std::exit(2);
}

// ---- equal: the cross-type comparison surface ----
//
// The same equality decisions the other runtimes made, restated for a
// statically-typed language: 1 == 1.0 == true across numeric kinds, strings
// by value whatever their spelling (std::string, const char*, string_view),
// containers elementwise with cross-element-type tolerance so the author's
// vector<long long> matches the student's vector<int>.
template <typename A, typename B>
bool equal(const A& a, const B& b);

template <typename A, typename B>
    requires(std::is_arithmetic_v<A> && std::is_arithmetic_v<B>)
bool equal_impl(const A& a, const B& b, int) {
    if constexpr (std::is_floating_point_v<A> || std::is_floating_point_v<B>) {
        return static_cast<long double>(a) == static_cast<long double>(b);
    } else if constexpr (std::is_same_v<A, bool> || std::is_same_v<B, bool>) {
        // std::cmp_equal rejects bool by design; promote so true == 1 holds.
        return static_cast<long long>(a) == static_cast<long long>(b);
    } else {
        return std::cmp_equal(a, b);
    }
}

template <typename A, typename B>
    requires(std::is_convertible_v<A, std::string_view>
             && std::is_convertible_v<B, std::string_view>)
bool equal_impl(const A& a, const B& b, int) {
    return std::string_view(a) == std::string_view(b);
}

template <typename A, typename B>
bool equal_impl(const std::vector<A>& a, const std::vector<B>& b, int) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i)
        if (!equal(a[i], b[i])) return false;
    return true;
}

template <typename A, typename B>
bool equal_impl(const std::map<std::string, A>& a, const std::map<std::string, B>& b, int) {
    if (a.size() != b.size()) return false;
    auto it = b.begin();
    for (const auto& [key, value] : a) {
        if (it->first != key || !equal(value, it->second)) return false;
        ++it;
    }
    return true;
}

// Fallback: same-type operator==; different unrelated types are not equal.
template <typename A, typename B>
bool equal_impl(const A& a, const B& b, long) {
    if constexpr (std::is_same_v<A, B>) {
        return a == b;
    } else {
        return false;
    }
}

template <typename A, typename B>
bool equal(const A& a, const B& b) {
    return equal_impl(a, b, 0);
}

// approximateEquality's tolerance comparison.
template <typename A, typename B>
bool close(const A& a, const B& b, double tolerance) {
    return std::fabs(static_cast<double>(a) - static_cast<double>(b)) <= tolerance;
}

// unorderedEquality: pairwise-greedy over equal, multiset-correct, and
// cross-element-type like everything else here.
template <typename A, typename B>
bool unordered_equal(const std::vector<A>& a, const std::vector<B>& b) {
    if (a.size() != b.size()) return false;
    std::vector<bool> used(b.size(), false);
    for (const auto& x : a) {
        bool matched = false;
        for (size_t j = 0; j < b.size(); ++j) {
            if (!used[j] && equal(x, b[j])) {
                used[j] = true;
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    return true;
}

// ---- format: how a value appears in a shortResult ----
inline std::string format(const std::string& v) { return "\"" + v + "\""; }
inline std::string format(const char* v) { return format(std::string(v)); }
inline std::string format(std::string_view v) { return format(std::string(v)); }
inline std::string format(bool v) { return v ? "true" : "false"; }
template <typename T>
    requires std::is_arithmetic_v<T>
std::string format(T v) {
    std::ostringstream os;
    os << v;
    return os.str();
}
template <typename T>
std::string format(const std::vector<T>& v) {
    std::string out = "[";
    for (size_t i = 0; i < v.size(); ++i) {
        if (i) out += ", ";
        out += format(v[i]);
    }
    return out + "]";
}
template <typename T>
std::string format(const std::map<std::string, T>& m) {
    std::string out = "{";
    bool first = true;
    for (const auto& [key, value] : m) {
        if (!first) out += ", ";
        first = false;
        out += "\"" + key + "\": " + format(value);
    }
    return out + "}";
}
// Anything else: name the situation rather than guess a rendering.
// Constrained away from everything the overloads above serve, or an `int`
// would be ambiguous between this and the arithmetic template.
template <typename T>
    requires(!std::is_arithmetic_v<std::decay_t<T>>
             && !std::is_convertible_v<T, std::string_view>)
std::string format(const T&) {
    return "(value)";
}

// ---- stdout capture for stdoutEquality ----
//
// fd-level (dup2 to a temp file), so printf AND std::cout are captured.
// rdbuf-swapping misses printf, and a course cannot control which one a
// student reaches for.
class CaptureStdout {
    int saved_ = -1;
    static constexpr const char* path_ = ".ck_stdout_capture";

  public:
    CaptureStdout() {
        std::fflush(stdout);
        std::cout.flush();
        saved_ = dup(1);
        int tmp = open(path_, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        // A capture we cannot set up must not read as "the student printed
        // nothing": that fails a correct submission for a harness problem.
        // Un-checked, a failed open made this `dup2(-1, 1)` and every
        // comparison ran against an empty string.
        if (saved_ < 0 || tmp < 0) {
            if (tmp >= 0) ::close(tmp);
            errored("Could not capture stdout for this test.");
        }
        dup2(tmp, 1);
        // Qualified: inside namespace ck, a bare `close` is ck::close (the
        // tolerance comparison), not POSIX close(2).
        ::close(tmp);
    }

    /// Puts the real stdout back, if it is still redirected. Idempotent.
    ///
    /// THE DESTRUCTOR IS THE POINT. A throw from the student's code unwinds
    /// past `finish()`, and the enclosing catch handler then reports its
    /// verdict — which, with fd 1 still pointing at the capture file, was
    /// written into that file and never reached the runner. stdout came back
    /// empty, so the shell contract synthesized a bare "failed" with no
    /// reason for what was an ordinary exception.
    void restore() {
        if (saved_ < 0) return;
        std::fflush(stdout);
        std::cout.flush();
        dup2(saved_, 1);
        ::close(saved_);
        saved_ = -1;
    }

    ~CaptureStdout() { restore(); }

    std::string finish() {
        restore();
        std::ifstream in(path_);
        std::string captured(
            (std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        in.close();
        // The capture file is an implementation detail of this class, not an
        // artefact the next test should be able to see.
        std::remove(path_);
        return captured;
    }
};

// ---- exceptionExpected's trichotomy ----
enum class ThrowOutcome { threwMatching, threwOther, returned };
template <typename F>
ThrowOutcome expect_throw(F&& f, std::string_view messageSubstring, std::string& what) {
    try {
        f();
        return ThrowOutcome::returned;
    } catch (const std::exception& e) {
        what = e.what();
        return what.find(messageSubstring) != std::string::npos ? ThrowOutcome::threwMatching
                                                                : ThrowOutcome::threwOther;
    } catch (...) {
        what = "(a non-std exception)";
        return messageSubstring.empty() ? ThrowOutcome::threwMatching : ThrowOutcome::threwOther;
    }
}

// ---- returnTypeCheck's cross-language type names ----
//
// Matches the value's STATIC type against the authored, language-neutral
// type name ("int", "float", "str", "bool", "list", "dict") — decltype-based,
// no RTTI, so the answer is the overload-resolution truth rather than a
// mangled runtime string.
template <typename T>
bool type_matches(std::string_view expected) {
    using D = std::decay_t<T>;
    if (expected == "bool") return std::is_same_v<D, bool>;
    if (expected == "int") return std::is_integral_v<D> && !std::is_same_v<D, bool>;
    if (expected == "float") return std::is_floating_point_v<D>;
    if (expected == "str")
        return std::is_same_v<D, std::string> || std::is_same_v<D, std::string_view>
            || std::is_same_v<D, const char*> || std::is_same_v<D, char*>;
    if (expected == "list") {
        if constexpr (requires { typename D::value_type; }) {
            return std::is_same_v<D, std::vector<typename D::value_type>>;
        } else {
            return false;
        }
    }
    if (expected == "dict") {
        if constexpr (requires {
                          typename D::key_type;
                          typename D::mapped_type;
                      }) {
            return std::is_same_v<
                D, std::map<typename D::key_type, typename D::mapped_type>>;
        } else {
            return false;
        }
    }
    return false;
}

// The static type's human name for failure messages, best-effort.
template <typename T>
std::string type_name() {
    using D = std::decay_t<T>;
    if constexpr (std::is_same_v<D, bool>) return "bool";
    else if constexpr (std::is_integral_v<D>) return "int";
    else if constexpr (std::is_floating_point_v<D>) return "float";
    else if constexpr (std::is_same_v<D, std::string> || std::is_same_v<D, const char*>
                       || std::is_same_v<D, char*> || std::is_same_v<D, std::string_view>)
        return "str";
    else if constexpr (requires { typename D::mapped_type; }) return "dict";
    else if constexpr (requires { typename D::value_type; }) return "list";
    else return "(another type)";
}

}  // namespace ck
