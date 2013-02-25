#lang s-exp rosette

(require "ast.rkt" "parser.rkt" "visitor-interpreter.rkt" "visitor-variables.rkt")

(configure [bitwidth 10])

;; Concrete version
(define (concrete)
  (define my-ast (ast-from-file "examples/concrete.mylang"))
  (define interpreter (new count-msg-interpreter%))
  (define num-msg (send my-ast accept interpreter))
  (send my-ast pretty-print)
  (pretty-display (format "# messages = ~a" num-msg))
  (send interpreter display-used-space)
  )

;(concrete)

;; current-solution doesn't like me :(
(define (simple-syn)
  (define my-ast (ast-from-file "examples/symbolic.mylang"))
  (define interpreter (new count-msg-interpreter% [core-space 256] [num-core 3]))
  (define num-msg (send my-ast accept interpreter))
  (send my-ast pretty-print)
  (pretty-display (format "# messages = ~a" num-msg))
  ;(send interpreter display-used-space)
  (solve (assert (= num-msg 3)))
  (current-solution)
  )

;(simple-syn)

;; this part verify that solve should be able to find a solution.
(define (foo)
  (define my-ast (ast-from-file "examples/symbolic.mylang"))
  (define interpreter (new count-msg-interpreter% [core-space 256] [num-core 3]))
  (define num-msg (send my-ast accept interpreter))
  (send my-ast pretty-print)
  ;(send interpreter display-used-space)
  (pretty-display (format "# messages = ~a" num-msg))
  ;(send interpreter assert-capacity)
  (assert (= num-msg 3))
)

(define (unsat-core)
  (define-values (out asserts) (with-asserts (foo)))
  asserts

  (send (current-solver) clear)
  (send/apply (current-solver) assert asserts)
  (send (current-solver) debug)
  )

;(unsat-core)

(define (simple-syn2)
  (define my-ast (ast-from-file "examples/symbolic.mylang"))
  (define interpreter (new count-msg-interpreter% [core-space 256] [num-core 3]))
  (define num-msg (send my-ast accept interpreter))
  (send my-ast pretty-print)
  (pretty-display (format "# messages = ~a" num-msg))
  
  (let ([collector (new var-collector%)])
    (pretty-display (send my-ast accept collector))
    (synthesize #:forall (set->list (send my-ast accept collector))
                #:assume #t
                #:guarantee (assert #t))
    )
  
  ;(send interpreter display-used-space)
  ;(solve (assert (= num-msg 3)))
  (current-solution)
  )

(define (test)
  (define my-ast (ast-from-file "examples/3.lego"))
  (define interpreter (new count-msg-interpreter% [core-space 256] [num-core 16]))
  (define num-msg (send my-ast accept interpreter))
  (send my-ast pretty-print)
  (pretty-display (format "# messages = ~a" num-msg))
  
  ;; solve 1
  (solve (assert (< num-msg 10)))
  (pretty-print (current-solution))
  (send interpreter display-used-space #t)
  (pretty-print (format "# messages = ~a" (evaluate num-msg)))
  (pretty-print (format "# cores = ~a" (evaluate (send interpreter num-cores))))
  
  ;; solve 2
  (solve (assert (< num-msg 5)))
  (pretty-print (current-solution))
  (send interpreter display-used-space #t)
  (pretty-print (format "# messages = ~a" (evaluate num-msg)))
  (pretty-print (format "# cores = ~a" (evaluate (send interpreter num-cores))))
  )

;(test)

(define (optimize-space)
  (define my-ast (ast-from-file "examples/3.lego"))
  (define interpreter (new count-msg-interpreter% [core-space 256] [num-core 16]))
  (define best-num-msg 256)
  (define best-num-cores 144)
  (define best-sol #f)
  
  (define num-msg (send my-ast accept interpreter))
  (define num-cores (send interpreter num-cores))
  
  (define (loop)
    ;(solve (assert (< num-cores best-num-cores)))
    ;(set! best-num-cores (evaluate num-cores))
    (solve (assert (< num-msg best-num-msg)))
    (set! best-num-msg (evaluate num-msg))
    
    (set! best-sol (current-solution))
    
    ;; display
    (pretty-print best-sol)
    (send interpreter display-used-space #t)
    (pretty-print (format "# messages = ~a" (evaluate num-msg)))
    (pretty-print (format "# cores = ~a" (evaluate num-cores)))
    (loop)
  )
  
  (loop)
  )

(optimize-space)
