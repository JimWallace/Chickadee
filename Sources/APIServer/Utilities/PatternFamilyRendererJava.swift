// APIServer/Utilities/PatternFamilyRendererJava.swift
//
// The Java half of the pattern-family renderer. Structured like the C++ one,
// and for the same reason: a generated Java case is a POSIX SHELL SCRIPT
// carrying its Java source in a quoted heredoc, which it compiles with javac
// and runs with java. The wrapper rides the original shell-script contract
// (exit 0/1/2, last stdout line as shortResult), so the runner needs no Java
// build dispatch and "no per-language build strategies in Swift" stays true.
//
// WHY A WRAPPER RATHER THAN A `.java` TEST. Java 11+ can run a source file
// directly (`java Test.java`), which would need no wrapper at all — except that
// source mode compiles EXACTLY ONE FILE. It cannot see the student's class or
// `test_runtime.java` (the launcher has no `--source-path`; measured). The
// wrapper's `javac` step can: it pulls the student's class and
// `_ck_inputs.java` in from the sourcepath on demand, and names
// `test_runtime.java` explicitly because that file's class is `ck` and implicit
// lookup only finds a class in a file named for it.
//
// Three differences from C++ worth knowing before editing:
//
//   * **No textual inclusion, and none needed.** C++ copies the submission to
//     `.ck_solution.cpp` and `#include`s it with `main` renamed. Java compiles
//     the student's file as its own unit, and a student's `main` cannot collide
//     because it lives in their class, not ours. Nothing is copied or renamed.
//   * **The class is named, not discovered.** Java has no free functions and a
//     public class must live in a file of its own name, so the family's
//     `function` field carries a qualified `Class.method` and the test says the
//     class out loud. A bare name is refused at save time.
//   * **Every test run is sentinel-checked.** A student's `System.exit(0)`
//     would otherwise make the JVM exit 0 and the case read as a pass. See
//     `test_runtime.java`.

import Core
import Foundation

// MARK: - Per-case Java rendering

/// Renders one enabled case of `family` as a shell wrapper + embedded Java.
func renderJavaPatternCase(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    let context = javaCallContext(for: family, case: c, perStudentNames: perStudentNames)
    let target = javaTargetCall(family.functionName)

    let body: String
    switch family.kind {
    case .boundaryEquality:
        body = javaEqualityBody(target: target, context: context, c: c, unordered: false)
    case .unorderedEquality:
        body = javaEqualityBody(target: target, context: context, c: c, unordered: true)
    case .approximateEquality:
        body = javaApproximateBody(target: target, context: context, c: c, family: family)
    case .variableEquality:
        body = javaVariableEqualityBody(family: family, context: context, c: c)
    case .returnTypeCheck:
        body = javaReturnTypeBody(target: target, context: context, c: c)
    case .exceptionExpected:
        body = javaExceptionBody(target: target, context: context, c: c)
    case .performanceThreshold:
        body = javaPerformanceBody(target: target, context: context, c: c)
    case .stdoutEquality:
        body = javaStdoutBody(target: target, context: context, c: c)
    case .differential:
        body = javaDifferentialBody(family: family, context: context, c: c)
    }

    let stem = "\(family.id)_\(c.key)"
    let className = javaGeneratedClassName(forStem: stem)
    let source = [
        javaGeneratedCaseHeader(family: family, case: c, specHash: specHash),
        "public class \(className) {",
        // The reference implementation is a class member, so it sits beside
        // main() rather than inside it.
        family.kind == .differential ? javaIndent(javaReferenceBlock(family)) : "",
        javaIndent(javaVariableDecls(sectionVariables: sectionVariables, family: family)),
        "    public static void main(String[] ckArgs) throws Exception {",
        javaIndent(javaIndent(context.declBlock + body)),
        "    }",
        "}",
    ]
    .filter { !$0.isEmpty }
    .joined(separator: "\n")

    return javaShellWrapper(embeddedSource: source, className: className)
}

/// The 0-point existence guard other kinds depend on.
///
/// TWO CHECKS, because Java splits the question C++ answers in one. Referencing
/// `Class.class` forces javac to resolve the class — a missing one is a compile
/// error, reported as a FAILURE (exit 1) like every other language's guard,
/// since a missing submission class is the student's to fix. The METHOD is then
/// checked reflectively at run time: its parameter types are unknown here (the
/// guard is family-level and has no case), so a compile-time reference to it
/// cannot be written, and a name match over the declared methods is the honest
/// equivalent.
func renderJavaExistenceGuard(family: PatternFamily, specHash: String) -> String {
    let stem = "\(family.id)_\(patternExistenceGuardCaseKey)"
    let className = javaGeneratedClassName(forStem: stem)
    let target = family.functionName
    guard let qualified = javaQualifiedFunction(target) else {
        // Unreachable through authoring — the validator refuses an unqualified
        // Java target — but total, and loud rather than plausible.
        return javaShellWrapper(
            embeddedSource: """
                \(javaComment("Generated by Chickadee — existence guard for family '\(family.id)'."))
                public class \(className) {
                    public static void main(String[] ckArgs) {
                        ck.errored("`\(target)` is not a qualified Java Class.method name.");
                    }
                }
                """,
            className: className)
    }
    let source = """
        \(javaComment("Generated by Chickadee — existence guard for family '\(family.id)'."))
        \(javaComment("spec_hash: \(specHash)"))
        public class \(className) {
            public static void main(String[] ckArgs) {
                Class<?> ckClass = \(qualified.className).class;
                boolean ckFound = false;
                boolean ckPrivate = false;
                for (java.lang.reflect.Method ckM : ckClass.getDeclaredMethods()) {
                    if (!ckM.getName().equals("\(qualified.methodName)")) continue;
                    ckFound = true;
                    int ckMods = ckM.getModifiers();
                    if (java.lang.reflect.Modifier.isPrivate(ckMods)) { ckPrivate = true; continue; }
                    if (java.lang.reflect.Modifier.isStatic(ckMods)) {
                        ck.passed("\(target) is defined");
                    }
                }
                // Found, but not callable the way every generated case calls it.
                // Reported separately because "is not defined" sent a student
                // hunting for a method that is right there.
                if (ckPrivate) {
                    ck.failed("`\(target)` is `private`; the tests call it from another class.");
                }
                if (ckFound) {
                    ck.failed("`\(target)` is defined but not `static`; the tests call it as `\(target)(...)`.");
                }
                ck.failed("`\(target)` is not defined");
            }
        }
        """
    return javaShellWrapper(
        embeddedSource: source,
        className: className,
        compileFailureIsTestFailure: true,
        compileFailureMessage:
            "`\(target)` is not defined (or the submission does not compile)")
}

// MARK: - The shell wrapper

/// The wrapper every generated Java case is.
///
/// `set -e` is deliberately absent. The first version had it, and a FAILING
/// case exited at the `java` line before printing the failure message the test
/// had just produced — a wrong-submission run that said nothing at all. It is
/// the exact defect the runbook's "execute the pass AND the fail path" rule
/// exists to catch.
private func javaShellWrapper(
    embeddedSource: String,
    className: String,
    compileFailureIsTestFailure: Bool = false,
    compileFailureMessage: String = ""
) -> String {
    // The build log goes to a file and is emitted only when the compile FAILS.
    // Sent straight to stderr it also rode a SUCCESSFUL compile into the
    // student's `longResult` — so a passing test displayed javac's
    // "uses unchecked or unsafe operations" note as though it were output
    // worth reading (#1349).
    let compileCommand = "javac -encoding UTF-8 -cp . -d . \(className).java test_runtime.java"
    let compileStep: String
    if compileFailureIsTestFailure {
        compileStep = """
            if ! \(compileCommand) 2>.ck_build_log; then
                cat .ck_build_log 1>&2
                printf '%s\\n' \(shellSingleQuoted("{\"shortResult\": \"\(compileFailureMessage)\"}"))
                exit 1
            fi
            """
    } else {
        compileStep = """
            if ! \(compileCommand) 2>.ck_build_log; then
                cat .ck_build_log 1>&2
                exit 2
            fi
            """
    }
    return """
        #!/bin/sh
        # Generated by Chickadee — do not edit. The Java source below is the
        # test; this wrapper compiles it with the injected runtime and runs it
        # under the ordinary shell-script contract. javac pulls the student's
        # class and _ck_inputs.java in from the sourcepath on demand, so
        # nothing here has to locate or copy the submission.
        cat > \(shellSingleQuoted("\(className).java")) <<'\(generatedSourceHeredocDelimiter)'
        \(embeddedSource)
        \(generatedSourceHeredocDelimiter)
        \(compileStep)
        ck_out=$(java -cp . \(className))
        ck_rc=$?
        # The sentinel check. Without it, a student's own System.exit(0)
        # anywhere in their code exits the JVM with status 0 and this case —
        # every case — reads as a pass. Java's masking mechanism
        # (SecurityManager) is deprecated for removal, so the test prints a line
        # only it can print and the wrapper refuses a run that lacks it.
        if ! printf '%s\\n' "$ck_out" | grep -q '^CK_SENTINEL$'; then
            echo "The test did not run to completion. Does the submission call System.exit?" 1>&2
            exit 2
        fi
        printf '%s\\n' "$ck_out" | grep -v '^CK_SENTINEL$'
        exit $ck_rc
        """ + "\n"
}

private func javaGeneratedCaseHeader(
    family: PatternFamily, case c: PatternCase, specHash: String
) -> String {
    let label = c.label.isEmpty ? "" : " (\(c.label))"
    return """
        \(javaComment("Generated by Chickadee — pattern family '\(family.id)', case '\(c.key)'\(label)."))
        \(javaComment("Edit the family, not this file. spec_hash: \(specHash)"))
        """
}

/// The call prefix for the family's target.
///
/// Java targets are qualified `Class.method`, so the rendered call is the name
/// as authored. An unqualified name cannot be called at all — it is refused at
/// save time — and renders here as an undefined identifier so a leak is a
/// compile error rather than a plausible wrong call.
func javaTargetCall(_ functionName: String) -> String {
    javaQualifiedFunction(functionName) != nil
        ? functionName : "CK_UNQUALIFIED_JAVA_TARGET_\(functionName)"
}

/// Section + family variables as static fields. Java forbids redeclaring a name
/// in one scope, so the `family > section` shadowing the dynamic languages get
/// from later-assignment-wins is spelled here by emitting the family's value
/// and FILTERING the section duplicate out — the same rule C++ needs.
private func javaVariableDecls(
    sectionVariables: [FamilyVariable], family: PatternFamily
) -> String {
    var seen = Set<String>()
    var declarations: [String] = []
    for variable in family.variables + sectionVariables
    where seen.insert(variable.name).inserted {
        let literal = variable.value.javaLiteral
        declarations.append(
            "static final \(javaDeclaredType(forLiteral: literal)) \(variable.name) = \(literal);")
    }
    return declarations.joined(separator: "\n")
}

// MARK: - Call context

/// The rendered pieces a kind body composes: argument bindings, the call's
/// argument list, and the Java expression fragment that previews the inputs in
/// a failure message.
struct JavaCallContext {
    let declBlock: String  // "var x = ...;" lines opening main(), or ""
    let callArgs: String  // "x, y"
    let inputLine: String  // Java expr: "input: x=..., y=...\n" (or no-input)
    let usesInputs: Bool  // any per-student reference
    let expectedExpression: String  // per-student ref, variable ref, or literal
}

private func javaCallContext(
    for family: PatternFamily, case c: PatternCase, perStudentNames: Set<String>
) -> JavaCallContext {
    let argNames: [String] = {
        if !family.paramNames.isEmpty { return family.paramNames }
        return c.args.indices.map { "arg_\($0 + 1)" }
    }()
    let provided: [Bool] = {
        guard !c.argsProvided.isEmpty else { return Array(repeating: true, count: argNames.count) }
        return (0..<argNames.count).map { i in i < c.argsProvided.count ? c.argsProvided[i] : true }
    }()
    let varRefs: [String?] = {
        guard !c.argVarRefs.isEmpty else { return Array(repeating: nil, count: argNames.count) }
        return (0..<argNames.count).map { i in i < c.argVarRefs.count ? c.argVarRefs[i] : nil }
    }()

    var usesInputs = false
    func reference(_ name: String) -> String {
        if perStudentNames.contains(name) {
            usesInputs = true
            return "_ck_inputs.\(name)"
        }
        return name
    }

    var declLines: [String] = []
    var callParts: [String] = []
    var previewParts: [String] = []
    for (idx, name) in argNames.enumerated() {
        guard idx < provided.count ? provided[idx] : true else {
            // Java has no keyword arguments: an omission ends the list and the
            // matching overload takes over — the same partial call a student
            // could write themselves.
            break
        }
        if let refName = idx < varRefs.count ? varRefs[idx] : nil {
            declLines.append(javaBinding(name: name, value: reference(refName)))
        } else if idx < c.args.count {
            declLines.append(javaBinding(name: name, value: c.args[idx].javaLiteral))
        }
        callParts.append(name)
        previewParts.append("\"\(name)=\" + ck.format(\(name))")
    }

    let inputLine: String
    if previewParts.isEmpty {
        inputLine = "\"\(GeneratedMessage.input)(no input)\\n\""
    } else {
        let joined = previewParts.joined(separator: " + \", \" + ")
        inputLine = "\"\(GeneratedMessage.input)\" + \(joined) + \"\\n\""
    }

    let expectedExpression: String
    if let ref = c.expectedVarRef {
        expectedExpression = reference(ref)
    } else {
        expectedExpression = c.expected.javaLiteral
    }

    return JavaCallContext(
        declBlock: declLines.isEmpty ? "" : declLines.joined(separator: "\n") + "\n",
        callArgs: callParts.joined(separator: ", "),
        inputLine: inputLine,
        usesInputs: usesInputs,
        expectedExpression: expectedExpression
    )
}

/// One local binding. `var` is Java's `auto`, so each argument keeps the
/// natural type its literal or its `_ck_inputs` field has — which is what lets
/// the student's own overload resolution run unmodified.
///
/// The one shape `var` cannot infer is a bare `null`, which has only the null
/// type; that binds as `Object`. Reachable whenever a case authors a null
/// argument, which is ordinary, so it is handled rather than left to produce a
/// compile error an instructor cannot read.
private func javaBinding(name: String, value: String) -> String {
    value == "null" ? "Object \(name) = null;" : "var \(name) = \(value);"
}

// MARK: - Shared kind-body helpers

/// The reference call, in its own try/catch so a throwing reference is reported
/// as a broken TEST rather than a broken submission.
func javaDifferentialExpected(family: PatternFamily, context: JavaCallContext) -> String {
    """
    Object expected = null;
    try {
        expected = \(family.differentialReferenceName)(\(context.callArgs));
    } catch (Throwable ckRefE) {
        ck.errored("\(GeneratedMessage.referenceFailed)\\n"
            + \(context.inputLine)
            + "\(GeneratedMessage.error)" + ckRefE);
    }
    """
}

/// The instructor's reference implementation, rendered verbatim as a member of
/// the generated test class.
private func javaReferenceBlock(_ family: PatternFamily) -> String {
    [
        javaComment("Instructor's reference implementation, rendered verbatim."),
        family.referenceImplementation ?? "",
    ].joined(separator: "\n")
}

/// Wraps a body in the shared unexpected-exception handler: a throw from the
/// student's code is a graded FAIL with the same first line every other
/// language uses, never a stack trace on stderr and a nonzero exit nobody
/// explains.
///
/// `Throwable`, not `Exception`: a student's `assert`, a `StackOverflowError`
/// from runaway recursion, or an `OutOfMemoryError` are all things an intro
/// submission produces, and every one of them is the submission's fault rather
/// than the harness's.
func javaGuarded(_ inner: String, inputLine: String) -> String {
    """
    try {
    \(javaIndent(inner))
    } catch (Throwable ckE) {
        ck.failed("\(GeneratedMessage.unexpectedException)\\n"
            + \(inputLine)
            + "\(GeneratedMessage.error)" + ckE);
    }
    """
}

// MARK: - Small utilities

func javaIndent(_ block: String) -> String {
    block.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : "    \($0)" }
        .joined(separator: "\n")
}
