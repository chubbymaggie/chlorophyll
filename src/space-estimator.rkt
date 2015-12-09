#lang racket

(provide (all-defined-out))

(define est-data1 4)
(define est-data2 8)
(define est-num 5)
(define est-var 4) ; @p a! @ . addr
(define est-comm 8) ; @p a! ! . up
(define est-acc-arr 4) ; @p @p . + a! @
(define est-for 8) ; 32 @p a! ! . | @p a! @ 1 . + ! . (20)
(define est-if 8) ;; call => 4 ;; :def if _ ; ] then _ ; => 4
(define est-while 8) ;; :while _ if _ while ; then ;
(define est-funccall 4)
(define est-funcreturn 18) ;; data & 0 a! ! 0 a! @

(define space-map 
  #hash(("~" . 1)
	("!" . 1)
        ("*" . 25) ; @p 17 for +* unext, (20 + 31)/2 = 25
        ("/" . 24)
        ("%" . 18)
        ("/%" . 17) 
	("*/17" . 7)
	("*/16" . 7)
        ("*:2" . 20)
        ("+" . 2)  ; . +
        ("-" . 10) ; - @p . + 1 . +
        (">>" . 12)
        ("<<" . 12)
        (">>>" . 37)
        ("<" . 10) ; a < b --> a - b < 0       - @p . + num . + -if
        ("<=" . 10) ; a <= b --> a - b - 1 < 0  - @p . + num -if
        (">=" . 10)
        (">" . 10)
        ("==" . 10) ; a == b   - @p . + num . + if
        ("!=" . 10)
        ("&" . 1)
        ("^" . 1)
        ("|" . 5) ; over - and . +
        ("&&" . 2) ; if(c1 && c2) { a } --> c1 if c2 if a then then
        ("||" . 6) ; if(c1 || c2) { a } --> c1 if call ;
))

(define (est-space x)
  (dict-ref space-map x))

