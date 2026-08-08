; Test: u
; Generated from pattern family "Family" [fam] spec_hash=742f48b545094cfb — edit the family, not this file.

#lang racket/base

(require "test_runtime.rkt")

(define x 1)
(define expected (list 1 2))
(define ns (chickadee-load-student))
(unless (chickadee-defined? ns 'classify)
  (chickadee-failed "`classify` is not defined"))

(define actual
  (with-handlers ([exn:fail? (lambda (e)
      (chickadee-failed (string-append "unexpected exception" "\n"
                         "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                         "  error:    " (exn-message e))))])
    (chickadee-call ns 'classify (list x))))

(if (chickadee-unordered-equal? actual expected)
    (chickadee-passed (string-append "Returned " (chickadee-format actual)))
    (chickadee-failed (string-append 
                       "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                       "  expected: " (chickadee-format expected) "\n"
                       "  got:      " (chickadee-format actual))))
