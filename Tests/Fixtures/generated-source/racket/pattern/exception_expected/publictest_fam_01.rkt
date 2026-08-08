; Test: e
; Generated from pattern family "Family" [fam] spec_hash=af181e8a5562a736 — edit the family, not this file.

#lang racket/base

(require "test_runtime.rkt")

(define x -1)
(define expected-error "ValueError")
(define ns (chickadee-load-student))
(unless (chickadee-defined? ns 'classify)
  (chickadee-failed "`classify` is not defined"))

(define outcome
  (with-handlers ([exn:fail? (lambda (e) (cons 'raised (exn-message e)))])
    (cons 'returned (chickadee-call ns 'classify (list x)))))

(cond
  [(eq? (car outcome) 'returned)
   (chickadee-failed (string-append "expected an error\n"
                      "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                      "  expected: " expected-error "\n"
                      "  got:      " (chickadee-format (cdr outcome))))]
  [(or (string=? expected-error "")
       (regexp-match? (regexp (regexp-quote expected-error)) (cdr outcome)))
   (chickadee-passed "Raised the expected error")]
  [else
   (chickadee-failed (string-append                               "  expected: " expected-error "\n"
                      "  error:    " (cdr outcome)))])
