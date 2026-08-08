; Test: v
; Generated from pattern family "Family" [fam] spec_hash=3e7d072c983cd304 — edit the family, not this file.

#lang racket/base

(require "test_runtime.rkt")

(define expected 3)
(define ns (chickadee-load-student))
(unless (chickadee-defined? ns 'classify)
  (chickadee-failed "`classify` is not defined"))

(define actual
  (with-handlers ([exn:fail? (lambda (e)
      (chickadee-failed (string-append "the variable could not be read" "\n"
                         "  error:    " (exn-message e))))])
    (chickadee-value ns 'classify)))

(if (chickadee-equal? actual expected)
    (chickadee-passed (string-append "classify = " (chickadee-format actual)))
    (chickadee-failed (string-append "wrong value" "\n"
                                                      "  expected: " (chickadee-format expected) "\n"
                       "  got:      " (chickadee-format actual))))
