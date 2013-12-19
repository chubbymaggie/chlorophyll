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
(define datadir "/home/mangpo/work/greensyn/testdata")
(define outdir #f)
(define path2src #f)

(define (set-outdir x)
  (set! outdir x)

  (define outdir-split (string-split outdir "/"))
  (define outdir-up-count (count (lambda (x) (equal? x "..")) outdir-split))
  (define outdir-down-count (- (length outdir-split) outdir-up-count))

  (define srcdir-split (string-split srcdir "/"))

  (define path-list (append (for/list ([i (in-range outdir-down-count)]) "..")
			    (reverse (take (reverse srcdir-split) outdir-up-count))))
  (set! path2src (string-join path-list "/"))
  )

(struct meminfo (addr virtual data))

