// Tools/runner-support/test_runtime.java
//
// The Java grading runtime: everything a generated Java test calls.
//
// WHY THE CLASS IS `ck` AND THE FILE IS `test_runtime.java`. Java requires a
// PUBLIC class to live in a file of its own name, so a public class here would
// have to be called `test_runtime` and every generated test would read
// `test_runtime.equal(...)`. A package-private class has no such rule, so the
// class is `ck` — matching the C++ runtime's `namespace ck` — and the file keeps
// the `test_runtime.` prefix that `EmbedRunnerSupportPlugin` discovers by shape.
//
// The cost of that choice, and it is load-bearing for the wrapper: javac's
// implicit source-path lookup finds a class only in a file NAMED for it, so it
// will never find `ck` in here on its own. Every generated wrapper therefore
// passes this file to javac EXPLICITLY, alongside the test. The student's class
// and `_ck_inputs.java` still resolve implicitly, because their filenames do
// match their class names.
//
// Package-private, not public, for a second reason: a student's own file cannot
// accidentally `import` it, and a name collision with a student class called
// `ck` is a compile error in their own submission rather than a silent
// override.

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;

class ck {

    private ck() {}

    // ---- the sentinel that makes the shell contract honest ----
    //
    // A student's `System.exit(0)` anywhere in their own code exits the JVM
    // with status 0, and the wrapper would read that as a PASS — every test in
    // the assignment, silently. This is the same hazard R (`quit()`), Lua
    // (`os.exit`) and Octave (`exit`) each had; the difference is that those
    // run in a kernel where the call can be masked, and Java's masking
    // mechanism (SecurityManager) is deprecated for removal, so there is
    // nothing to mask with.
    //
    // Instead every verdict prints this line before its result, and the wrapper
    // refuses to trust a run that did not emit it. Printing it HERE rather than
    // in the generated test is deliberate: a renderer cannot forget it.
    private static final String SENTINEL = "CK_SENTINEL";

    // ---- the shell contract's exit codes ----
    //
    // stdout carries one JSON object as the last non-empty line; stderr carries
    // detail. Exit 0 pass, 1 fail, 2 error — identical to every other runtime
    // here.
    static void passed(String msg) {
        System.out.println(SENTINEL);
        System.out.println("{\"shortResult\": \"" + jsonEscape(msg) + "\"}");
        System.out.flush();
        Runtime.getRuntime().halt(0);
    }

    static void failed(String msg) {
        System.out.println(SENTINEL);
        System.out.println("{\"shortResult\": \"" + jsonEscape(msg) + "\"}");
        System.out.flush();
        Runtime.getRuntime().halt(1);
    }

    static void errored(String msg) {
        // The sentinel goes out here too, even though no JSON follows. Without
        // it the wrapper could not tell a genuine error from a student's
        // premature exit, and would report the less specific of the two —
        // hiding the message this call exists to deliver.
        System.out.println(SENTINEL);
        System.out.flush();
        System.err.println(msg);
        System.err.flush();
        Runtime.getRuntime().halt(2);
    }

    // `halt`, not `exit`: `System.exit` runs shutdown hooks, and a student's
    // hook throwing or blocking would strand a verdict that has already been
    // printed. The streams are flushed explicitly above, so nothing is lost.

    // ---- equal: the cross-type comparison surface ----
    //
    // THE MOST IMPORTANT METHOD IN THIS FILE. `Integer.valueOf(1).equals(
    // Long.valueOf(1L))` is FALSE — boxed numeric equality in Java is
    // type-strict, and `List.equals` and `Map.equals` inherit that elementwise.
    // So an authored expected value of `1` compared against a student method
    // returning `long` would be a WRONG MARK, silently, on a correct
    // submission.
    //
    // The decisions match the other five runtimes: numbers compare
    // numerically across kinds (1 == 1.0), NaN equals NaN (so an authored NaN
    // is reachable at all), collections compare elementwise with the same
    // tolerance, and maps compare by key with values compared this way.
    //
    // Booleans are NOT numbers here. C++ had to promote them because
    // `std::cmp_equal` rejects `bool`; Java's `Boolean` is not a `Number` at
    // all, so `true == 1` is false — which is the answer an author writing
    // `expected: true` means.
    static boolean equal(Object a, Object b) {
        if (a == null || b == null) return a == b;
        if (a instanceof Number && b instanceof Number) {
            double x = ((Number) a).doubleValue();
            double y = ((Number) b).doubleValue();
            if (Double.isNaN(x) && Double.isNaN(y)) return true;
            return x == y;
        }
        if (a instanceof CharSequence && b instanceof CharSequence) {
            return a.toString().equals(b.toString());
        }
        if (a instanceof Map<?, ?> && b instanceof Map<?, ?>) {
            Map<?, ?> ma = (Map<?, ?>) a;
            Map<?, ?> mb = (Map<?, ?>) b;
            if (ma.size() != mb.size()) return false;
            for (Map.Entry<?, ?> e : ma.entrySet()) {
                Object key = e.getKey();
                // Keys are matched by this same relation rather than by
                // hashCode, so a student's Integer key still finds an author's
                // Long one. Linear, but a test's maps are small.
                Object match = null;
                boolean found = false;
                for (Map.Entry<?, ?> other : mb.entrySet()) {
                    if (equal(key, other.getKey())) {
                        match = other.getValue();
                        found = true;
                        break;
                    }
                }
                if (!found || !equal(e.getValue(), match)) return false;
            }
            return true;
        }
        List<Object> la = asListOrNull(a);
        List<Object> lb = asListOrNull(b);
        if (la != null && lb != null) {
            if (la.size() != lb.size()) return false;
            for (int i = 0; i < la.size(); i++) {
                if (!equal(la.get(i), lb.get(i))) return false;
            }
            return true;
        }
        return a.equals(b);
    }

    /// Collections and Java arrays alike, as an ordered list — or null when the
    /// value is neither. Arrays are included because a student writing
    /// `int[] f()` is writing ordinary Java, and their result would otherwise
    /// compare by identity and never match anything.
    private static List<Object> asListOrNull(Object v) {
        if (v instanceof Collection<?>) return new ArrayList<Object>((Collection<?>) v);
        if (v != null && v.getClass().isArray()) {
            int n = java.lang.reflect.Array.getLength(v);
            List<Object> out = new ArrayList<Object>(n);
            for (int i = 0; i < n; i++) out.add(java.lang.reflect.Array.get(v, i));
            return out;
        }
        return null;
    }

    /// Floating-point closeness for approximateEquality. Absolute tolerance,
    /// matching every other runtime here.
    static boolean close(Object a, Object b, double tolerance) {
        if (!(a instanceof Number) || !(b instanceof Number)) return equal(a, b);
        double x = ((Number) a).doubleValue();
        double y = ((Number) b).doubleValue();
        if (Double.isNaN(x) && Double.isNaN(y)) return true;
        return Math.abs(x - y) <= tolerance;
    }

    /// Multiset equality for unorderedEquality: greedy pairwise matching under
    /// `equal`, which is correct for a multiset because `equal` is an
    /// equivalence on the values it accepts.
    static boolean unorderedEqual(Object a, Object b) {
        List<Object> la = asListOrNull(a);
        List<Object> lb = asListOrNull(b);
        if (la == null || lb == null) return false;
        if (la.size() != lb.size()) return false;
        List<Object> remaining = new ArrayList<Object>(lb);
        for (Object item : la) {
            boolean matched = false;
            for (int i = 0; i < remaining.size(); i++) {
                if (equal(item, remaining.get(i))) {
                    remaining.remove(i);
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        return true;
    }

    // ---- format: how a value appears in a shortResult ----
    //
    // Strings keep their quotes, so a returned "25" is distinguishable from 25
    // — the same rule the other runtimes follow.
    static String format(Object v) {
        if (v == null) return "null";
        if (v instanceof CharSequence) return "\"" + v + "\"";
        if (v instanceof Map<?, ?>) {
            StringBuilder out = new StringBuilder("{");
            boolean first = true;
            for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) {
                if (!first) out.append(", ");
                first = false;
                out.append(format(e.getKey())).append(": ").append(format(e.getValue()));
            }
            return out.append("}").toString();
        }
        List<Object> list = asListOrNull(v);
        if (list != null) {
            StringBuilder out = new StringBuilder("[");
            for (int i = 0; i < list.size(); i++) {
                if (i > 0) out.append(", ");
                out.append(format(list.get(i)));
            }
            return out.append("]").toString();
        }
        return String.valueOf(v);
    }

    // ---- stdout capture for stdoutEquality ----
    //
    // `System.setOut`, which is the rdbuf-level answer rather than C++'s
    // fd-level dup2 — and adequate here in a way it is not in C++, because Java
    // has no `printf`-to-file-descriptor path that bypasses `System.out` for
    // ordinary student code. A student would have to open FileDescriptor.out
    // themselves to escape it, which is not something an intro submission does
    // by accident.
    //
    // The verdict methods above are unaffected: they run after `endCapture`
    // restores the real stream.
    private static PrintStream savedOut;
    private static ByteArrayOutputStream captureBuffer;

    static void beginCapture() {
        savedOut = System.out;
        captureBuffer = new ByteArrayOutputStream();
        System.setOut(new PrintStream(captureBuffer, true, java.nio.charset.StandardCharsets.UTF_8));
    }

    static String endCapture() {
        System.out.flush();
        String captured = captureBuffer.toString(java.nio.charset.StandardCharsets.UTF_8);
        System.setOut(savedOut);
        captureBuffer = null;
        return captured;
    }

    // ---- exceptionExpected's trichotomy ----

    /// A unit of student work that may throw anything, including a checked
    /// exception. `Callable` would force the generated test to handle
    /// `Exception`; this interface declares `Throwable` so the renderer emits
    /// no try/catch of its own.
    interface Thunk {
        Object run() throws Throwable;
    }

    static final int THREW_MATCHING = 0;
    static final int THREW_OTHER = 1;
    static final int RETURNED = 2;

    /// Runs `f` and classifies the outcome. `detail[0]` receives the exception's
    /// message (or its type name when the message is null, which Java
    /// exceptions commonly have and which would otherwise print as "null").
    static int expectThrow(Thunk f, String messageSubstring, String[] detail) {
        try {
            f.run();
            return RETURNED;
        } catch (Throwable t) {
            String what = t.getMessage();
            if (what == null || what.isEmpty()) what = t.getClass().getSimpleName();
            detail[0] = what;
            // The substring is matched against the type name TOO, so an author
            // can write "IllegalArgumentException" and have it match an
            // exception carrying an unrelated message — the type is what a
            // Java author names when they mean "this kind of error".
            boolean matches =
                messageSubstring == null
                    || messageSubstring.isEmpty()
                    || what.contains(messageSubstring)
                    || t.getClass().getSimpleName().contains(messageSubstring)
                    || t.getClass().getName().contains(messageSubstring);
            return matches ? THREW_MATCHING : THREW_OTHER;
        }
    }

    // ---- returnTypeCheck's cross-language type names ----
    //
    // Matches the value's RUNTIME class against the authored, language-neutral
    // name ("int", "float", "str", "bool", "list", "dict"). C++ answers this
    // from the static type via decltype; Java cannot, because a generated test
    // binds the student's result to `Object` and the static type is erased
    // there. The runtime class is the honest answer for a boxed value, and it
    // is what a student sees when they print it.
    //
    // `long` and `int` both answer "int", and `float` and `double` both answer
    // "float": these are the language-neutral kinds shared with Python and R,
    // not Java's own type names, so width is deliberately not part of it.
    static boolean typeMatches(Object v, String expected) {
        return typeName(v).equals(expected);
    }

    static String typeName(Object v) {
        if (v == null) return "(null)";
        if (v instanceof Boolean) return "bool";
        if (v instanceof Double || v instanceof Float) return "float";
        if (v instanceof Number) return "int";
        if (v instanceof CharSequence || v instanceof Character) return "str";
        if (v instanceof Map<?, ?>) return "dict";
        if (v instanceof Collection<?> || v.getClass().isArray()) return "list";
        return "(another type)";
    }

    // ---- the per-student seed ----
    //
    // Base-16 Horner fold over the hex digits of CHICKADEE_ASSIGNMENT_SEED, mod
    // 2^31-1 — digit-for-digit the same reduction as the R, Lua, Octave, C++
    // and Racket runtimes, so a student's seed is one number in every language.
    // Non-hex characters are skipped; an absent or digitless value is 0.
    //
    // Java has BigInteger and would not need the fold, but the fold is the
    // contract: base R has no bignum, and every other language matches R rather
    // than each doing its best.
    static long seed() {
        String raw = System.getenv("CHICKADEE_ASSIGNMENT_SEED");
        if (raw == null) return 0L;
        long acc = 0L;
        for (int i = 0; i < raw.length(); i++) {
            int digit = Character.digit(raw.charAt(i), 16);
            if (digit < 0) continue;
            acc = (acc * 16L + digit) % 2147483647L;
        }
        return acc;
    }

    // ---- JSON string escaping for the shortResult line ----
    //
    // Note this escapes for JSON, not for Java source. It never emits a
    // backslash-u escape for a control character — not because JSON forbids it
    // (it does not), but because these bytes are read back by a JSON parser
    // that is happy with the short forms, and keeping to them means the
    // generated line stays readable in a log.
    private static String jsonEscape(String s) {
        StringBuilder out = new StringBuilder(s.length() + 16);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '\\': out.append("\\\\"); break;
                case '"': out.append("\\\""); break;
                case '\n': out.append("\\n"); break;
                case '\r': out.append("\\r"); break;
                case '\t': out.append("\\t"); break;
                default:
                    if (c < 0x20 || c == 0x7F) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
            }
        }
        return out.toString();
    }
}
