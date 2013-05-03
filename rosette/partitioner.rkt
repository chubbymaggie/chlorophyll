#lang s-exp rosette

(require "header.rkt"
         "ast.rkt" 
         "parser.rkt" 
         "visitor-interpreter.rkt" 
         "visitor-collector.rkt" 
         "visitor-rename.rkt"
         "visitor-printer.rkt")

(provide optimize-comm (struct-out result))

;; Set bidwidth for rosette
;(configure [bitwidth bitwidth])

;; struct used to return result from optimize-comm
(struct result (msgs cores))

;; Concrete version
(define (concrete)
  (define my-ast (ast-from-file "examples/test.cll"))
  (define collector (new place-collector% 
                         [collect? (lambda(x) 
                                     (and (and (number? x) (not (symbolic? x)))
                                          (not (is-a? x Place%))))
                                   ]))
  (define place-set (send my-ast accept collector))
  (pretty-print place-set)
  (define converter (new partition-to-number% [num-core 16] [real-place-set place-set]))
  (send my-ast accept converter)
  (send my-ast pretty-print)
  
  (define interpreter (new count-msg-interpreter% [core-space 256] [num-core 4]))
  (define num-msg (send my-ast accept interpreter))
  ;(send my-ast pretty-print)
  (pretty-display (format "# messages = ~a" num-msg))
  (send interpreter display-used-space)
  )

;(concrete)

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
  (define my-ast (ast-from-file "examples/simple-hole.cll"))
  (define interpreter (new count-msg-interpreter% [core-space 256] [num-core 3]))
  (define num-msg (send my-ast accept interpreter))
  (send my-ast pretty-print)
  (pretty-display (format "# messages = ~a" num-msg))
  
  (let ([collector (new place-collector% [collect? symbolic?])])
    (pretty-display (send my-ast accept collector))
    (synthesize #:forall (set->list (send my-ast accept collector))
                #:assume #t
                #:guarantee (assert #t))
    )
  
  ;(send interpreter display-used-space)
  ;(solve (assert (= num-msg 3)))
  (current-solution)
  )

;;; AST printer
;;; (send my-ast pretty-print)

;;; Concise printer
;;; (define concise-printer (new printer%))
;;; (send my-ast accept concise-printer)

(define (optimize-comm file 
                        #:cores [best-num-cores 144] 
                        #:capacity [capacity 256] 
                        #:max-msgs [best-num-msg #f])
  
  #|(let ([bitwidth (+ (inexact->exact (ceiling 
                    (/ (log (max best-num-cores capacity best-num-msg)) (log 2)))) 10)])
      
    ;; Set bidwidth for rosette
    (pretty-display (format "bidwidth = ~a" bitwidth))
    (configure [bitwidth bitwidth]))|#
  (configure [bitwidth 32])
  
  ;; Define printer
  (define concise-printer (new printer%))
  
  ;; Easy inference happens here
  (define my-ast (ast-from-file file))
  (pretty-display "=== Original AST ===")
  (send my-ast pretty-print)
  
  ;; Collect real physical places
  (define collector (new place-collector% 
                         [collect? (lambda(x) (and (number? x) (not (symbolic? x))))]))
  (define place-set (send my-ast accept collector))
  (pretty-display "\n=== Places ===")
  (pretty-print place-set)
  
  ;; Convert distinct abstract partitions into distinct numbers
  ;; and different symbolic vars for different holes
  (define converter (new partition-to-number% [num-core 16] [real-place-set place-set]))
  (send my-ast accept converter)
  (pretty-display "\n=== After string -> number ===")
  (send my-ast pretty-print)
  
  ;; Count number of messages
  (define interpreter (new count-msg-interpreter% [core-space capacity] [num-core best-num-cores]))
  (define best-sol #f)
  
  (define num-msg (comminfo-msgs (send my-ast accept interpreter)))
  (define num-cores (send interpreter num-cores))
  
  (define (loop)
    ;(solve (assert (< num-cores best-num-cores)))
    ;(set! best-num-cores (evaluate num-cores))
    (if best-num-msg
      (solve (assert (< num-msg best-num-msg)))
      (solve (assert #t)))
    (set! best-num-msg (evaluate num-msg))
    
    (set! best-sol (current-solution))
    
    ;; display
    ;(send my-ast accept concise-printer)
    ;(send interpreter display-used-space)
    (pretty-display (format "# messages = ~a" (evaluate num-msg)))
    (pretty-display (format "# cores = ~a" (evaluate num-cores)))
    (loop)
  )
  
  ;void
  (with-handlers* ([exn:fail? (lambda (e) 
                                (pretty-display "\n=== Solution ===")
                                (send my-ast accept concise-printer) 
                                (pretty-display best-sol)
                                (send interpreter display-used-space)
				(result (evaluate num-msg) (send interpreter get-concrete-cores)))])
                  (loop))
  )

(result-msgs 
 (optimize-comm "examples/add.cll" #:cores 8 #:capacity 256))