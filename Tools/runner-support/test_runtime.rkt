#lang racket/base
;; test_runtime.rkt — Chickadee's Racket grading runtime.
;;
;; The Racket member of the test_runtime family (.py/.R/.lua/.m/.hpp). Its shape
;; is dictated by one fact that no other language in the family has:
;;
;;   A STUDENT MODULE EXPORTS NOTHING.
;;
;; CS 135 and CS 115 submissions are HtDP teaching languages (`#lang htdp/bsl`
;; and friends), and such a module has no `provide` — so `(require "student.rkt")`
;; binds nothing at all. Everything below follows from working around that, and
;; each workaround was measured against a real `racket` before it was written,
;; because the obvious spelling fails in each case:
;;
;;   1. LOADING. `dynamic-require` the module for its side effect, then take
;;      `module->namespace` to reach its internal definitions. Requiring it
;;      normally yields an empty set of bindings, not an error — the silent kind.
;;
;;   2. DEFINEDNESS. Ask `namespace-mapped-symbols`, never
;;      `namespace-variable-value`. The latter returns its failure thunk for a
;;      perfectly good BSL binding (measured), so a defined function reads as
;;      missing and every case skips behind a guard that should have passed.
;;
;;   3. CALLING. Evaluate an APPLICATION FORM, never a bare identifier. BSL
;;      rejects a function reference outside operator position — the error reads
;;      "expected a function call, but there is no open parenthesis before this
;;      function" — so you cannot extract the procedure and apply it.
;;
;;   4. ARGUMENTS. Bind each value into the namespace and pass it BY NAME.
;;      Quoting is the natural spelling and BSL refuses it: `(quote (1 2 3))`
;;      fails with "expected the name of a symbol or () after the quote, but
;;      found a part". That is measured, and it would have broken silently for
;;      exactly the list-valued arguments a CS 135 assignment is made of.
;;
;; The payoff for all four: ONE generated test works unchanged against
;; `#lang htdp/bsl` and `#lang racket`, so the CS 135 and CS 136 dialects need
;; no separate authoring path.

(require racket/list racket/string racket/path)

(provide chickadee-load-student
         chickadee-defined?
         chickadee-call
         chickadee-passed
         chickadee-failed
         chickadee-errored
         chickadee-equal?
         chickadee-unordered-equal?
         chickadee-format
         chickadee-inputs
         chickadee-label
         chickadee-value
         chickadee-call/capture
         chickadee-type-name
         chickadee-stdout-matches?)

;; --- Test label ------------------------------------------------------------
;; The runner reads the label off the generated file's first `; Test:` line, and
;; results echo it back. Reading our own source keeps one source of truth.

(define (chickadee-label)
  (define path (find-system-path 'run-file))
  (with-handlers ([exn:fail? (lambda (_) "test")])
    (define line
      (for/first ([l (in-lines (open-input-file (current-test-path)))]
                  #:when (regexp-match #rx"^;+ *Test:" l))
        l))
    (if line
        (string-trim (regexp-replace #rx"^;+ *Test: *" line ""))
        (path->string (file-name-from-path path)))))

(define (current-test-path)
  (find-system-path 'run-file))

;; --- Result reporting ------------------------------------------------------
;; The shell-script contract: exit 0/1/2, and the LAST non-empty stdout line is
;; read as JSON. Detail goes to stderr, which the runner captures as longResult.

(define (emit status short [err #f])
  (printf "{\"status\":~a,\"shortResult\":~a,\"test\":~a~a}\n"
          (json-string status)
          (json-string short)
          (json-string (chickadee-label))
          (if err (format ",\"error\":~a" (json-string err)) "")))

;; Hand-rolled rather than `json`'s `write-json`: this file is loaded by every
;; generated test, and the strings it emits are short. Escapes cover what a
;; failure message can actually contain.
(define (json-string s)
  (define str (if (string? s) s (format "~a" s)))
  (string-append
   "\""
   (apply string-append
          (for/list ([ch (in-string str)])
            (cond [(char=? ch #\") "\\\""]
                  [(char=? ch #\\) "\\\\"]
                  [(char=? ch #\newline) "\\n"]
                  [(char=? ch #\return) "\\r"]
                  [(char=? ch #\tab) "\\t"]
                  [(char<? ch #\space) (format "\\u~a" (~hex (char->integer ch)))]
                  [else (string ch)])))
   "\""))

(define (~hex n)
  (define s (number->string n 16))
  (string-append (make-string (max 0 (- 4 (string-length s))) #\0) s))

(define (chickadee-passed [message #f])
  (emit "pass" (or message (format "~a: passed" (chickadee-label))))
  (exit 0))

(define (chickadee-failed [message "failed"])
  (emit "fail" (format "~a: ~a" (chickadee-label) message) message)
  (eprintf "~a\n" message)
  (exit 1))

(define (chickadee-errored [message "error"])
  (emit "error" (format "~a: ~a" (chickadee-label) message) message)
  (eprintf "~a\n" message)
  (exit 2))

;; --- Locating and loading the submission -----------------------------------

;; Names that are never the student's module.
(define (reserved-name? base)
  (or (string=? base "test_runtime.rkt")
      (string=? base "_ck_inputs.rkt")
      (regexp-match? #rx"test" base)))

;; The runner writes `.chickadee_student_module` on every job. Unlike Lua, we
;; CAN list a directory, so a scan backs the hint up — same posture as R and
;; Python.
(define (chickadee-student-file)
  (define hinted
    (and (file-exists? ".chickadee_student_module")
         (let ([named (string-trim (file->line ".chickadee_student_module"))])
           (and (not (string=? named ""))
                (let ([base (path->string (file-name-from-path (string->path named)))])
                  (and (regexp-match? #rx"[.]rkt$" base)
                       (not (reserved-name? base))
                       (file-exists? base)
                       base))))))
  (or hinted
      (and (file-exists? "solution.rkt") "solution.rkt")
      (let ([candidates
             (sort (for/list ([p (in-list (directory-list))]
                              #:when (let ([b (path->string p)])
                                       (and (regexp-match? #rx"[.]rkt$" b)
                                            (not (reserved-name? b)))))
                     (path->string p))
                   string<?)])
        (and (pair? candidates) (first candidates)))))

(define (file->line path)
  (call-with-input-file path (lambda (in) (or (read-line in) ""))))

;; Returns the submission's namespace. Errors (rather than fails) when there is
;; nothing to grade — a missing submission is not a wrong answer.
(define (chickadee-load-student)
  (define file (chickadee-student-file))
  (unless file
    (chickadee-errored "No Racket submission file was found to grade."))
  (define complete (path->string (path->complete-path file)))
  (with-handlers
      ([exn:fail?
        (lambda (e)
          ;; A submission that does not compile is a FAILURE of the test, not a
          ;; runner error: the student's own syntax error is the finding.
          (chickadee-failed
           (format "Your submission could not be loaded: ~a" (exn-message e))))])
    (define mp `(file ,complete))
    (dynamic-require mp #f)
    (module->namespace mp)))

;; See note 2 in the header: this is the only definedness test that works for a
;; teaching-language module.
(define (chickadee-defined? ns name)
  (and (memq name (namespace-mapped-symbols ns)) #t))

;; See notes 3 and 4: application form, arguments bound by name.
(define (chickadee-call ns name args)
  (define arg-names
    (for/list ([i (in-range (length args))])
      (string->symbol (format "ck-arg~a" i))))
  (for ([n (in-list arg-names)] [v (in-list args)])
    (namespace-set-variable-value! n v #t ns))
  (eval (cons name arg-names) ns))

;; A module-level VALUE (not a function). Safe to evaluate bare: BSL's
;; operator-position restriction applies to procedures, not to data bindings —
;; `(define x 5)` then `x` is legal there. Used by `variableEquality`.
(define (chickadee-value ns name)
  (eval name ns))

;; Calls the student's function with stdout captured, for `stdoutEquality`.
;; Returns (values printed-string result).
(define (chickadee-call/capture ns name args)
  (define out (open-output-string))
  (define result (parameterize ([current-output-port out]) (chickadee-call ns name args)))
  (values (get-output-string out) result))

;; The neutral type names pattern families use, mapped onto Racket's predicates.
;; Racket has no "int" distinct from a whole flonum in the way Python does, so
;; `integer?` deliberately accepts 5.0 — a student who computed a whole number
;; by division has not made a type error.
(define (chickadee-type-name v)
  (cond [(and (number? v) (integer? v)) "int"]
        [(number? v) "float"]
        [(string? v) "str"]
        [(boolean? v) "bool"]
        [(list? v) "list"]
        [(hash? v) "dict"]
        [else (format "~a" (let-values ([(t _) (values (object-name v) #f)]) (or t "value")))]))

;; --- Per-student inputs ----------------------------------------------------

(define (chickadee-inputs)
  (if (file-exists? "_ck_inputs.rkt")
      (with-handlers ([exn:fail? (lambda (_) (hash))])
        (dynamic-require `(file ,(path->string (path->complete-path "_ck_inputs.rkt")))
                         'ck-inputs))
      (hash)))

;; --- Comparison ------------------------------------------------------------

;; `equal?` is WRONG for grading numbers: Racket distinguishes exact from
;; inexact, so `(equal? 25 25.0)` is #f and a student returning a flonum where
;; the expectation is an integer would be marked wrong for being right. `=`
;; compares across the exactness boundary, so numbers take that path.
;;
;; NaN matches NaN, matching Octave's `isequaln` posture: an expectation of NaN
;; is asking "is this not-a-number", and `=` alone answers #f to that.
(define (chickadee-equal? a b)
  (cond
    [(and (real? a) (real? b))
     (cond [(and (nan? a) (nan? b)) #t]
           [(or (nan? a) (nan? b)) #f]
           [else (= a b)])]
    [(and (list? a) (list? b))
     (and (= (length a) (length b)) (andmap chickadee-equal? a b))]
    [(and (hash? a) (hash? b))
     (and (= (hash-count a) (hash-count b))
          (for/and ([(k v) (in-hash a)])
            (and (hash-has-key? b k) (chickadee-equal? v (hash-ref b k)))))]
    [(and (vector? a) (vector? b))
     (chickadee-equal? (vector->list a) (vector->list b))]
    [else (equal? a b)]))

(define (nan? x) (and (real? x) (not (= x x))))

;; Order-insensitive comparison for `unorderedEquality`. Quadratic, which is the
;; right trade at test sizes and avoids requiring the elements be sortable.
(define (chickadee-unordered-equal? a b)
  (and (list? a) (list? b)
       (= (length a) (length b))
       (let loop ([remaining b] [items a])
         (cond
           [(null? items) #t]
           [else
            (define idx
              (for/first ([(v i) (in-indexed remaining)]
                          #:when (chickadee-equal? (car items) v))
                i))
            (and idx
                 (loop (append (take remaining idx) (drop remaining (add1 idx)))
                       (cdr items)))]))))

;; Compares captured stdout against an expectation, ignoring surrounding
;; whitespace. A runtime helper rather than inline `string-trim` in the
;; generated test: generated tests are `#lang racket/base`, which does NOT
;; export `string-trim` — that lives in `racket/string`. Keeping the comparison
;; here means a generated case needs exactly one require.
(define (chickadee-stdout-matches? printed expected)
  (define (trim s)
    (define str (if (string? s) s (format "~a" s)))
    (define chars (string->list str))
    (define (drop-ws lst) (if (and (pair? lst) (char-whitespace? (car lst))) (drop-ws (cdr lst)) lst))
    (list->string (reverse (drop-ws (reverse (drop-ws chars))))))
  (string=? (trim printed) (trim expected)))

;; One-line, student-readable rendering. `~s` is the write form, so strings keep
;; their quotes and a returned "25" is distinguishable from 25 in a failure
;; message — the whole point of showing the value back.
(define (chickadee-format v)
  (format "~s" v))
