; Test: b
; Generated from pattern family "Family" [fam] spec_hash=8fff023f74a1087a — edit the family, not this file.

#lang racket/base

(require "test_runtime.rkt")

(define x 18.49)
(define expected 1)
(define tolerance 1e-06)
(define ns (chickadee-load-student))
(unless (chickadee-defined? ns 'classify)
  (chickadee-failed "`classify` is not defined"))

(define actual
  (with-handlers ([exn:fail? (lambda (e)
      (chickadee-failed (string-append "unexpected exception" "\n"
                         "  error:    " (exn-message e))))])
    (chickadee-call ns 'classify (list x))))

(unless (and (real? actual) (real? expected))
  (chickadee-failed (string-append                              "  expected: " (chickadee-format expected) "\n"
                     "  got:      " (chickadee-format actual))))
(define delta (abs (- actual expected)))
(if (<= delta tolerance)
    (chickadee-passed (string-append "Returned " (chickadee-format actual)))
    (chickadee-failed (string-append                                "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                       "  expected: " (chickadee-format expected) "\n"
                       "  got:      " (chickadee-format actual) "\n"
                       "  delta:    " (chickadee-format delta))))
