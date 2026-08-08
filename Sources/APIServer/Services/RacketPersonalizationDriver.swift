// APIServer/Services/RacketPersonalizationDriver.swift
//
// The Racket sibling of the Python/R/Lua/Octave/C++ personalization drivers:
// a script the evaluator runs with `racket` that evaluates each `=` expression
// server-side and prints, as its LAST stdout line, a JSON map
// `name → <value rendered as Racket source>`.
//
// The Swift return path parses that last line identically for every language,
// so only the bytes below differ.

import Core
import Foundation

enum RacketPersonalizationDriver {

    /// The shared seed fold — Horner base-16 over the hex digits of
    /// CHICKADEE_ASSIGNMENT_SEED, mod 2^31−1 — matching `chickadee_seed()` in
    /// the R/Lua/Octave runtimes and `ck_seed()` in the C++ driver digit for
    /// digit, so a student's seed is one number in every language.
    static let seedSource = #"""
        (define (ck-seed)
          (define raw (getenv "CHICKADEE_ASSIGNMENT_SEED"))
          (cond
            [(not raw) 0]
            [else
             (define modulus 2147483647)
             (define-values (acc any)
               (for/fold ([acc 0] [any #f]) ([ch (in-string (string-downcase raw))])
                 (define digit
                   (cond [(char<=? #\0 ch #\9) (- (char->integer ch) (char->integer #\0))]
                         [(char<=? #\a ch #\f) (+ 10 (- (char->integer ch) (char->integer #\a)))]
                         [else #f]))
                 (if digit
                     (values (modulo (+ (* acc 16) digit) modulus) #t)
                     (values acc any))))
             (if any acc 0)]))
        """#

    /// `ck-literal` renders a runtime value as Racket SOURCE, mirroring
    /// `JSONValue.racketLiteral` so a value round-trips into a generated test
    /// unchanged. `ck-json-string` is the JSON encoder the output map rides in.
    static let literalSource = #"""
        (define (ck-literal v)
          (cond
            [(eq? v 'null) "'null"]
            [(boolean? v) (if v "#t" "#f")]
            [(and (number? v) (exact-integer? v)) (number->string v)]
            [(and (real? v) (nan? v)) "+nan.0"]
            [(and (real? v) (infinite? v)) (if (negative? v) "-inf.0" "+inf.0")]
            [(real? v) (let ([s (number->string (exact->inexact v))]) s)]
            [(string? v) (ck-json-string v)]
            [(list? v)
             (if (null? v) "(list)"
                 (string-append "(list " (string-join (map ck-literal v) " ") ")"))]
            [(vector? v) (ck-literal (vector->list v))]
            [(hash? v)
             (if (zero? (hash-count v)) "(hash)"
                 (string-append
                  "(hash "
                  (string-join
                   (for/list ([k (in-list (sort (hash-keys v) string<? #:key (lambda (x) (format "~a" x))))])
                     (string-append (ck-json-string (format "~a" k)) " " (ck-literal (hash-ref v k))))
                   " ")
                  ")"))]
            [else (ck-json-string (format "~a" v))]))

        (define (ck-json-string s)
          (string-append
           "\""
           (apply string-append
                  (for/list ([ch (in-string s)])
                    (cond [(char=? ch #\") "\\\""]
                          [(char=? ch #\\) "\\\\"]
                          [(char=? ch #\newline) "\\n"]
                          [(char=? ch #\return) "\\r"]
                          [(char=? ch #\tab) "\\t"]
                          [(char<? ch #\space)
                           (let* ([h (number->string (char->integer ch) 16)]
                                  [pad (make-string (max 0 (- 4 (string-length h))) #\0)])
                             (string-append "\\u" pad h))]
                          [else (string ch)])))
           "\""))
        """#

    /// The whole driver.
    ///
    /// Expressions evaluate in a namespace seeded with `racket` plus `seed`,
    /// the support helpers and the static variables — the same scope model the
    /// other drivers build. Each expression's own result is bound before the
    /// next runs, so a later expression can reference an earlier one.
    static func render(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportFiles: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("#lang racket")
        lines.append(";; Auto-generated personalization driver. Do not edit.")
        lines.append("(require racket/string racket/list)")
        lines.append("")
        lines.append(seedSource)
        lines.append("")
        lines.append(literalSource)
        lines.append("")
        lines.append(";; The scope every expression is evaluated in.")
        lines.append("(define ns (make-base-namespace))")
        lines.append("(namespace-set-variable-value! 'seed (ck-seed) #t ns)")
        lines.append("")
        if !supportFiles.isEmpty {
            lines.append(";; Auto-loaded support files (instructor .rkt helpers).")
            lines.append(";; A broken helper is ignored here; a missing name surfaces as an")
            lines.append(";; error only if an expression actually references it.")
            for name in supportFiles {
                let literal = JSONValue.string(name).racketLiteral
                lines.append("(with-handlers ([(lambda (_) #t) void])")
                lines.append("  (let* ([mp `(file ,(path->string (path->complete-path \(literal))))])")
                lines.append("    (dynamic-require mp #f)")
                lines.append("    (let ([sns (module->namespace mp)])")
                lines.append("      (for ([sym (in-list (namespace-mapped-symbols sns))])")
                lines.append("        (with-handlers ([(lambda (_) #t) void])")
                lines.append(
                    "          (namespace-set-variable-value! sym (eval sym sns) #t ns))))))")
            }
            lines.append("")
        }
        if !staticVariables.isEmpty {
            lines.append(";; Static globals + section variables (in scope for expressions).")
            for v in staticVariables {
                lines.append(
                    "(namespace-set-variable-value! '\(racketArgumentName(v.name)) \(v.value.racketLiteral) #t ns)")
            }
            lines.append("")
        }
        lines.append(";; Per-student expressions, evaluated in declared order.")
        lines.append("(define ck-results '())")
        for e in expressions {
            let nameLiteral = JSONValue.string(e.name).racketLiteral
            // The expression text is embedded as a Racket STRING literal and
            // read at run time, so an instructor's quotes and backslashes
            // cannot break out of the driver's own source.
            let bodyLiteral = JSONValue.string(e.expression).racketLiteral
            lines.append("(let* ([ck-src \(bodyLiteral)]")
            lines.append("       [ck-form (with-handlers")
            lines.append("                  ([(lambda (_) #t)")
            lines.append("                    (lambda (ex)")
            lines.append("                      (error 'chickadee \"expression ~a: ~a\" \(nameLiteral) ex))])")
            lines.append("                  (read (open-input-string ck-src)))]")
            lines.append("       [ck-value (eval ck-form ns)])")
            lines.append(
                "  (namespace-set-variable-value! '\(racketArgumentName(e.name)) ck-value #t ns)")
            lines.append("  (set! ck-results (cons (cons \(nameLiteral) ck-value) ck-results)))")
        }
        lines.append("")
        lines.append(";; The LAST stdout line: a JSON map name -> Racket-source literal.")
        lines.append(";; Earlier instructor output is ignored by the Swift reader.")
        lines.append("(displayln")
        lines.append("  (string-append")
        lines.append("   \"{\"")
        lines.append("   (string-join")
        lines.append("    (for/list ([pair (in-list (reverse ck-results))])")
        lines.append("      (string-append (ck-json-string (car pair)) \":\"")
        lines.append("                     (ck-json-string (ck-literal (cdr pair)))))")
        lines.append("    \",\")")
        lines.append("   \"}\"))")
        return lines.joined(separator: "\n") + "\n"
    }
}
