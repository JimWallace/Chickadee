; Test: t
; Generated from pattern family "Family" [fam] spec_hash=8adb8f0c701a46e7 — edit the family, not this file.

#lang racket/base

(require "test_runtime.rkt")

(define x 1)
(define expected-type "int")
(define ns (chickadee-load-student))
(unless (chickadee-defined? ns 'classify)
  (chickadee-failed "`classify` is not defined"))

(define actual
  (with-handlers ([exn:fail? (lambda (e)
      (chickadee-failed (string-append "unexpected exception" "\n"
                         "  error:    " (exn-message e))))])
    (chickadee-call ns 'classify (list x))))

(define actual-type (chickadee-type-name actual))
(if (string=? actual-type expected-type)
    (chickadee-passed (string-append "Returned a " actual-type))
    (chickadee-failed (string-append                                "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                       "  expected: " expected-type "\n"
                       "  got:      " actual-type)))
