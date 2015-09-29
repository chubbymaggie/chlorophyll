#lang s-exp rosette

(require "header.rkt"
         "ast.rkt" "ast-util.rkt"
         "partition-storage.rkt"
         "visitor-collector.rkt" 
         "visitor-evaluator.rkt"
         "visitor-flow.rkt"
         "visitor-heupartition.rkt"
         "visitor-interpreter.rkt" 
         "visitor-loopbound.rkt"
         "visitor-placetype.rkt"
	 "visitor-postunroll.rkt"
         "visitor-printer.rkt"
         "visitor-rename.rkt"
         "visitor-unroll.rkt"
         )

(require rosette/solver/kodkod/kodkod)
(require rosette/solver/smt/z3)

(provide optimize-comm (struct-out result))

;; struct used to return result from optimize-comm
(struct result (msgs cores ast))

(define (optimize-comm my-ast #:name [name "temp"]
                        #:cores [num-core 144] 
                        #:capacity [capacity 256] 
                        #:refine-capacity [refine-capacity (make-vector num-core #f)]
                        #:refine-info [refine-info #f]
                        #:max-msgs [max-msgs #f]
			#:synthesis [synthesis #t]
                        #:verbose [verbose #f])
  
  ;; Define printer
  (define concise-printer (new printer% [out #t]))
  
  ;; Collect real physical places
  ;; (define collector (new place-collector% 
  ;;                        [collect? (lambda(x) (and (number? x) (not (symbolic? x))))]))
  ;; (define place-set (send my-ast accept collector))
  ;; (when verbose
  ;;   (pretty-display "\n=== Places ===")
  ;;   (pretty-print place-set))
  
  ;; Convert distinct abstract partitions into distinct numbers
  ;; and different symbolic vars for different holes
  ;; (define converter (new partition-to-number% [num-core num-core] [real-place-set place-set]))
  ;; (send my-ast accept converter)
  ;; (when verbose
  ;;   (pretty-display "\n=== After string -> number ===")
  ;;   (send my-ast pretty-print)
  ;;   (send my-ast accept concise-printer))

  ;; Place type linker
  (send my-ast accept (new placetype-linker%))
  (when verbose
    (pretty-display "=== After placetype linker  ===")
    (send my-ast pretty-print)
    )

  ;; Unroll
  (define start-loopbound (current-seconds))
  (send my-ast accept (new loopbound-computer%))
  (define stop-loopbound (current-seconds))
  (with-output-to-file #:exists 'truncate (format "~a/~a.time" outdir name)
    (lambda ()
      (pretty-display (format "loopbound time: ~a s" (- stop-loopbound start-loopbound)))))

  (when verbose
    (pretty-display "=== After bound compute  ===")
    (send my-ast pretty-print)
    )
  (send my-ast accept (new loop-unroller% [program my-ast]))
  (when verbose
    (pretty-display "=== After unroll  ===")
    (send my-ast pretty-print)
    )
  (send my-ast accept (new post-unroller%))
  (when verbose
    (pretty-display "=== After func-remover  ===")
    (send my-ast pretty-print)
    )

  (current-solver (new kodkod-incremental%))
  ;(current-solver (new z3%))
  ;(current-solver (new kodkod%))

  (current-bitwidth 32)
  
  ;; Count number of messages
  (define cores (make-cores #:capacity capacity #:max-cores num-core))
  (define interpreter (new count-msg-interpreter% [places cores]))
  
  ;; Place holder for solution
  (define num-msg #f)
  (define partial-hash (make-hash))

  
  (define (solve-function func-ast refine-capacity refine-part2capacity)
    (define start (current-seconds))
    (define comm-result (send func-ast accept interpreter))

    (let* ([nodes (list->vector (set->list (get-field used-io-nodes interpreter)))]
	   [len (vector-length nodes)])
      (for ([i (in-range len)])
	(for ([j (in-range (add1 i) len)])
	  (assert (not (equal? (hash-ref node-to-symbolic-core
					 (vector-ref nodes i))
			       (hash-ref node-to-symbolic-core
					 (vector-ref nodes j))))))))

    (cores-refine cores part2capacity)

    (set! num-msg (comminfo-msgs comm-result))
    
    (when verbose
      (pretty-display "\n=== After interpreter ===")
      (send my-ast pretty-print))
      ;(send my-ast accept concise-printer))

    (when verbose (pretty-display `(num-msg , num-msg)))
    
    (define num-cores (cores-count cores)) 
    (define lowerbound 0)
    (define upperbound max-msgs)
    (define middle (if upperbound 
                       (floor (/ (+ lowerbound upperbound) 2))
                       #f))
    (define best-sol #f)
    
    (define (update-global-sol)
      ;; Unify solutions symbolically. Use this when solve function by function
      #|(define unified-hash (make-hash))
      (define concrete-to-sym (make-hash))
      
      (for ([mapping (solution->list global-sol)])
        (let ([key (car mapping)]
              [val (evaluate (cdr mapping) best-sol)])
          (hash-set! concrete-to-sym val key)
          (hash-set! unified-hash key val)))
      
      (for ([mapping (solution->list best-sol)])
        (let ([key (car mapping)]
              [val (evaluate (cdr mapping) best-sol)])
          (when (not (hash-has-key? unified-hash key))
            (hash-set! concrete-to-sym val key)
            (hash-set! unified-hash key val))))
      
      (if (equal? (get-field name func-ast) "main")
          (set-global-sol (sat (make-immutable-hash (hash->list unified-hash))))
          (let ([global-hash (make-hash)])
            (hash-for-each unified-hash 
                           (lambda (key val) 
                             (hash-set! global-hash key (hash-ref concrete-to-sym val))))
            (set-global-sol (sat (make-immutable-hash (hash->list global-hash))))))   

      ;; Unify solutions concretely. Don't use this
      (for ([mapping (solution->list best-sol)])
        (let ([key (car mapping)]
              [val (cdr mapping)])
          (when (not (hash-has-key? partial-hash key))
            (hash-set! partial-hash key val))))
        
      (set-global-sol (sat (make-immutable-hash (hash->list partial-hash)))|#
      
      ;; Use this when solve the entire program at once.
      (set-global-sol best-sol)
      (cores-evaluate cores)
      (define stop (current-seconds))
      
      
      (when verbose
        (pretty-display "\n=== Update Global Solution ===")
        (send func-ast accept concise-printer) 
        (pretty-display global-sol)
        (display-cores cores)
        (pretty-display (format "synthesis time = ~a sec" (- stop start)))
	(with-output-to-file #:exists 'append (format "~a/~a.time" outdir name)
	  (lambda ()
	    (pretty-display (format "partition time: ~a s" (- stop start)))))
      )
      )
    
    (define t 0)
      
                
    ;; (define (inner-loop)
    ;;   (pretty-display (format "num-msg <= ~a" middle))
    ;;   #|(if middle
    ;;       (solve-with-sol (assert (<= num-msg middle)) global-sol)
    ;;       (solve-with-sol (assert #t) global-sol))|#
    ;;   (set! t (current-seconds))
    ;;   (if middle
    ;;       (solve (assert (<= num-msg middle)))
    ;;       (solve (assert #t)))
    ;;   (pretty-display `(solve-time ,(- (current-seconds) t)))
    ;;   (set! upperbound (evaluate num-msg))
    ;;   (set! middle (floor (/ (+ lowerbound upperbound) 2)))
      
    ;;   (set! best-sol (current-solution))
      
    ;;   ;; display
    ;;   (pretty-display (format "# messages = ~a" (evaluate num-msg)))
    ;;   (pretty-display (format "# cores = ~a" (evaluate num-cores)))
      
    ;;   ;; recored best-so-far solution
    ;;   (let ([saved-sol global-sol])
    ;;     (set-global-sol best-sol)
    ;;     (with-output-to-file #:exists 'truncate (format "~a/~a.bestsofar" outdir name)
    ;;       (lambda () 
    ;;         (pretty-display (format "# messages = ~a" (evaluate num-msg)))
    ;;         (send my-ast accept concise-printer)
    ;;         (display-cores cores)))
    ;;     (set-global-sol saved-sol))
      
    ;;   (if (< lowerbound upperbound)
    ;;       (inner-loop)
    ;;       (update-global-sol))
    ;;   )
    
    ;; (define (outter-loop)
    ;;   (with-handlers* 
    ;;    ([exn:fail? (lambda (e) 
    ;;                  (pretty-display `(solve-time ,(- (current-seconds) t)))
    ;;                  (if (and upperbound (or (equal? (exn-message e)
    ;;                                                  "solve: no satisfying execution found")
    ;;                                          (equal? (exn-message e)
    ;;                                                  "assert: failed")))
    ;;                      (begin
    ;;                        (set! lowerbound (add1 middle))
    ;;                        (set! middle (floor (/ (+ lowerbound upperbound) 2)))
    ;;                        (if (< lowerbound upperbound)
    ;;                            (outter-loop)
    ;;                            (update-global-sol)))
    ;;                      (begin
    ;;                        (pretty-display e)
    ;;                        (raise e))))])
    ;;    (inner-loop)))

    (define (inner-loop)
      (set! t (current-seconds))
      (assert (< num-msg (evaluate num-msg)))
      (solve #t)

      (pretty-display `(solve-time ,(- (current-seconds) t)))
      (set! best-sol (current-solution))
      
      ;; display
      (pretty-display (format "# messages = ~a" (evaluate num-msg)))
      (pretty-display (format "# cores = ~a" (evaluate num-cores)))
      
      (inner-loop))

    (define (outter-loop)
      (with-handlers* 
       ([exn:fail? (lambda (e) 
                     (pretty-display `(solve-time ,(- (current-seconds) t)))
                     (if (or (equal? (exn-message e)
                                     "solve: no satisfying execution found")
                             (equal? (exn-message e)
                                     "assert: failed"))
                         (begin
                           (update-global-sol)
                           (clear-asserts)
			   (current-solution (empty-solution))
                           (comminfo-placeset comm-result)
                           )
                         (begin
                           (pretty-display e)
                           (raise e))))])
       (solve #t)
       (set! best-sol (current-solution))
       (inner-loop)))
    
    (outter-loop)
    )

  ;; For iterative refinement.
  (define refine-part2sym (if refine-info (car refine-info) (make-vector num-core #f)))
  (define part2capacity (if refine-info (cdr refine-info) (make-hash)))
  (define new-part2sym (make-vector num-core #f))
 
  ;; Construct part2capacity
  (for ([part (in-range num-core)])
       (let ([sym (vector-ref refine-part2sym part)]
	     [cap (vector-ref refine-capacity part)])
	 (when (and (not (equal? sym #f))
		    (or (not (hash-has-key? part2capacity sym))
			(> (hash-ref part2capacity sym) cap)))
		 (hash-set! part2capacity sym cap))))
    
  (cond
   [synthesis
    (pretty-display "Running partitioning synthesizer ...")
    (send interpreter assert-conflict my-ast)

    (define placeset #f)
    (for ([decl (get-field stmts my-ast)])
	 (if 
	  ;;(is-a? decl FuncDecl%) ;; Use this for solving function by function
	  (and (is-a? decl FuncDecl%) (equal? (get-field name decl) "main"))
	  (begin
	    (set! placeset (solve-function decl refine-capacity part2capacity))
	    (when verbose (pretty-display "------------------------------------------------")))
	  (send decl accept interpreter)))

    (unless placeset
	    (raise "Check if your program has function 'main'"))

    ;; Construct new-part2sym.
    (for ([p placeset])
         (unless (symbolic? p) (vector-set! new-part2sym p p)))

    (pretty-display global-sol)
    (for ([sol-pair (solution->list global-sol)])
         (let ([node (cdr sol-pair)])
           (when (and (>= node 0) (< node num-core))
                 (equal? (vector-ref new-part2sym (cdr sol-pair)) #f)
                 (vector-set! new-part2sym (cdr sol-pair) (car sol-pair)))))
    ]

   [else
    (pretty-display "Running heuristic partitioner ...")
    (define heu-start (current-seconds))
    (define-values (space network conflict-list) 
      (send my-ast accept (new heuristic-partitioner%)))
    (define result (merge-sym-partition num-core space network capacity 
					refine-capacity part2capacity
					conflict-list my-ast))
    (set-global-sol (sat (make-immutable-hash (hash->list (car result)))))
    (set! new-part2sym (cdr result))
    
    (with-output-to-file #:exists 'append (format "~a/~a.time" outdir name)
      (lambda ()
	(pretty-display (format "heuristic partition time: ~a s" 
				(- (current-seconds) heu-start)))))])

  (let ([evaluator (new symbolic-evaluator% [num-cores num-core])])
    (send my-ast pretty-print)
    (send my-ast accept evaluator)
    )

  (with-output-to-file #:exists 'truncate (format "~a/~a.part" outdir name)
    (lambda () (send my-ast accept concise-printer)))
  
  (pretty-display "\n=== Final Solution ===")
  (send my-ast accept concise-printer)
  (display-cores cores)
  
  (when verbose
    (pretty-display "\n=== After evaluate ===")
    (send my-ast accept concise-printer)
    ;(send my-ast pretty-print)
    )
  
  (cons new-part2sym part2capacity)
)

#|
(define t (current-seconds))
(define my-ast (parse "../tests/add-pair.cll"))
(result-msgs (optimize-comm my-ast #:cores 16 #:capacity 300 #:verbose #t))
(pretty-display (format "partitioning time = ~a" (- (current-seconds) t)))
|#
