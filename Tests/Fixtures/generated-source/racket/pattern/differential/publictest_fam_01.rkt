; Test: d
; Generated from pattern family "Family" [fam] spec_hash=66f8c7ded2bab2b1 — edit the family, not this file.

#lang racket/base

(require "test_runtime.rkt")

(define x 18.49)

; Instructor's reference implementation, rendered verbatim.
(define (ck_ref_classify x) 1)

(define expected
  (with-handlers ([exn:fail? (lambda (e)
      (chickadee-errored (string-append "the reference implementation raised" "\n"
                         "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                         "  error:    " (exn-message e))))])
    (apply ck_ref_classify (list x))))

(define ns (chickadee-load-student))
(unless (chickadee-defined? ns 'classify)
  (chickadee-failed "`classify` is not defined"))

(define actual
  (with-handlers ([exn:fail? (lambda (e)
      (chickadee-failed (string-append "unexpected exception" "\n"
                         "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                         "  error:    " (exn-message e))))])
    (chickadee-call ns 'classify (list x))))

(if (chickadee-equal? actual expected)
    (chickadee-passed (string-append "Returned " (chickadee-format actual)))
    (chickadee-failed (string-append "wrong value" "\n"
                       "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                       "  expected: " (chickadee-format expected) "\n"
                       "  got:      " (chickadee-format actual))))
