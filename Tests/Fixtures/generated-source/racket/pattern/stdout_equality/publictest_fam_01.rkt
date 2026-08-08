; Test: s
; Generated from pattern family "Family" [fam] spec_hash=fc8371b5e923b61d — edit the family, not this file.

#lang racket/base

(require "test_runtime.rkt")

(define x 1)
(define expected "hello")
(define ns (chickadee-load-student))
(unless (chickadee-defined? ns 'classify)
  (chickadee-failed "`classify` is not defined"))

(define printed
  (with-handlers ([exn:fail? (lambda (e)
      (chickadee-failed (string-append "unexpected exception" "\n"
                         "  error:    " (exn-message e))))])
    (let-values ([(out _) (chickadee-call/capture ns 'classify (list x))])
      out)))

(if (chickadee-stdout-matches? printed expected)
    (chickadee-passed "Printed the expected output")
    (chickadee-failed (string-append                                "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                       "  expected: " (chickadee-format expected) "\n"
                       "  got:      " (chickadee-format printed))))
