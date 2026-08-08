; Test: p
; Generated from pattern family "Family" [fam] spec_hash=373c736715269bba — edit the family, not this file.

#lang racket/base

(require "test_runtime.rkt")

(define x 1)
(define budget-ms 0.5)
(define ns (chickadee-load-student))
(unless (chickadee-defined? ns 'classify)
  (chickadee-failed "`classify` is not defined"))

(define start (current-inexact-milliseconds))
(with-handlers ([exn:fail? (lambda (e)
    (chickadee-failed (string-append "unexpected exception" "\n"
                       "  error:     " (exn-message e))))])
  (chickadee-call ns 'classify (list x)))
(define elapsed (- (current-inexact-milliseconds) start))

(if (<= elapsed budget-ms)
    (chickadee-passed (format "Completed in ~ams" (round elapsed)))
    (chickadee-failed (string-append "too slow\n"
                       "  input:    " (string-append "x=" (chickadee-format x)) "\n"
                       "  threshold: " (format "~ams" budget-ms) "\n"
                       "  elapsed:   " (format "~ams" (round elapsed)))))
