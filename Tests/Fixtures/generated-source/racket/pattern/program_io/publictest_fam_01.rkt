; Test: io
; Generated from pattern family "Family" [fam] spec_hash=eb00ef813bc014b0 — edit the family, not this file.

#lang racket/base

(require "test_runtime.rkt")
(require racket/string)

(define stdin-text "3\n4\n")
(define expected "7")

(define file (chickadee-student-file))
(unless file (chickadee-errored "No Racket submission file was found to run."))

(define (ck-normalize text)
  (define lines (map string-trim-right (string-split text "\n" #:trim? #f)))
  (let loop ([ls (reverse lines)])
    (if (and (pair? ls) (string=? (car ls) ""))
        (loop (cdr ls))
        (string-join (reverse ls) "\n"))))
(define (string-trim-right s) (string-trim s #:left? #f))

(define ck-error #f)
(define printed
  (let ([out (open-output-string)])
    (parameterize ([current-input-port (open-input-string stdin-text)]
                   [current-output-port out]
                   [current-namespace (make-base-namespace)]
                   [exit-handler (lambda (code) (raise 'chickadee-exit))])
      (with-handlers ([(lambda (e) (eq? e 'chickadee-exit)) void]
                      [exn:fail? (lambda (e) (set! ck-error (exn-message e)))])
        (dynamic-require `(file ,(path->string (path->complete-path file))) #f)))
    (get-output-string out)))

(when ck-error
  (chickadee-failed (string-append "unexpected exception" "\n"
                     "  input:    " (chickadee-format stdin-text) "\n"
                     "  got:      " (chickadee-format (ck-normalize printed)) "\n"
                     "  error:    " ck-error)))

(define ok (string=? (ck-normalize printed) (ck-normalize expected)))
(if ok
    (chickadee-passed "Printed the expected output")
    (chickadee-failed (string-append "wrong output" "\n"
                       "  input:    " (chickadee-format stdin-text) "\n"
                       "  expected: " (chickadee-format expected) "\n"
                       "  got:      " (chickadee-format (ck-normalize printed)))))
