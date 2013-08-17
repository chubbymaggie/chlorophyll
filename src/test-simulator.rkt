#lang racket

(require "compiler.rkt")

(define result (list))

(define (test name input capacity)
  (set! result (cons 
                (cons name (test-simulate name input capacity))
                result)))

;(test "simple" "null" 256)

;(test "if"       "4_1" 512)
;(test "add"       "200" 1024)
;(test "add2"       "200" 1024)
;(test "function" "4_1" 512)
;(test "function" "4_2" 512)
;(test "matrixmult" "72" 400) ;capacity issue
;(test "pair1" "null" 512)
;(test "pair2" "null" 512)
;(test "pair3" "null" 512)
;(test "cluster" "null" 256)
;(test "while" "10" 256)

;(test "md5-full" "md5" 1400)

;(test "add_stream" "300" 512)
;(test "running-sum-stream" "300" 512)
;(test "two-streams" "300" 512)
;(test "three-streams" "300" 512)
;(test "three-pipelines" "300" 512)
(test "three-large-filters" "300" 512)
;(test "multiply-by-power-stream" "300" 512)

(for ([res (reverse result)])
  (pretty-display res))
