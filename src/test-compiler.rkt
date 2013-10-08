#lang racket

(require "compiler.rkt")

;(compile-to-IR "../tests/run/offset.cll" "test" 
;               343 "null" 7 6 #:verbose #t)

;(compile-and-optimize "../examples/test.cll" "test" 
;                      256 "null" #:w 4 #:h 2 #:opt #f)
;(compile-and-optimize "../tests/run/array.cll" "array" 
;                      256 "null" #:opt #t)
;(compile-and-optimize "../tests/run/offset.cll" "offset" 
;                      256 "null" #:opt #t)
;(compile-and-optimize "../tests/run/function-out.cll" "function" 
;                      256 "null" #:opt #f)
;(compile-and-optimize "../tests/run/function-pair1.cll" "function_pair" 
;                      256 "null" #:opt #f)
;(compile-and-optimize "../tests/run/while-noio.cll" "whilenoio" 
;                      256 "null" #:opt #f)
;(compile-and-optimize "../tests/run/add-noio.cll" "addnoio" 
;                      256 "null" #:opt #f)
;(compile-and-optimize "../tests/run/matrixmult4-dup.cll" "matrix" 
;                      220 "null" #:w 5 #:h 4 #:opt #t)
;(compile-and-optimize "../examples/leftrotate.cll" "leftrotate" 
;                     256 "null" #:w 10 #:h 5 #:opt #t)

(compile-and-optimize "../tests/run/md5-3.cll" "md3" 
                     1024 "null" #:w 8 #:h 8 #:opt #t)
(compile-and-optimize "../tests/run/md5.cll" "md1" 
		      400 "null" #:w 8 #:h 8 #:opt #t)
;(compile-and-optimize "../tests/run/md5-2.cll" "md2" 
;                     400 "null" #:w 10 #:h 5 #:opt #t)

;(compile-and-optimize "../tests/run/ssd_simple22.cll" "ssd_simple2" 
;                     256 "null" #:w 8 #:h 5 #:opt #t)
;(compile-and-optimize "../tests/run/swap.cll" "swap" 
;                      256 "null" #:w 8 #:h 8 #:opt #t)
