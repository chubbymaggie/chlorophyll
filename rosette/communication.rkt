#lang racket

(require "visitor-comminsert.rkt" "visitor-unroll.rkt")

(provide (all-defined-out))

;; 1) Insert communication route to send-path field.
;; 2) Convert partition ID to actual core ID.
;; Note: given AST is mutate.
(define (insert-comm ast routing-table part2core)
  (define commcode-inserter (new commcode-inserter% 
                                 [routing-table routing-table]
                                 [part2core part2core]))

  (send ast accept commcode-inserter))

;; Unroll for loop according to array distributions of variables inside its body.
;; Note: given AST is mutated.
(define (unroll ast)
  (define for-unroller (new loop-unroller%))
  (send ast accept for-unroller)
  )