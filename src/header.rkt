#lang s-exp rosette

(require (only-in rosette [sym? symbolic?]))
(require (only-in racket foldl log))

(provide symbolic? foldl log rosette-number?
         (all-defined-out))

(define global-sol (sat (hash)))
(define (set-global-sol sol)
  (set! global-sol sol))

(define (rosette-number? x) (number? x))

(define-syntax-rule (evaluate-with-sol x)
  ;(evaluate x))
  (evaluate x global-sol))


(define max-bit 18)
(define n-bit 16)

(define node-offset 10)
(define block-offset 800)
(define procs 8)
(define check-interval 60)
(define distributed #t)
(define max-unroll 20)
(define accurate-flow #t)

(define srcdir "/home/mangpo/work/greensyn/src")
(define outdir #f)
(define datadir "/home/mangpo/work/greensyn/testdata")

(define (set-outdir x)
  (set! outdir x)
  )

(struct meminfo (addr virtual data))

