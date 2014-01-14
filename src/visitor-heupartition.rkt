#lang racket

(require "header.rkt" "ast.rkt" "visitor-interface.rkt" "space-estimator.rkt")

(provide heuristic-partitioner% merge-sym-partition)

;;(define factor 0.95)

(define debug #t)

(define (merge-sym-partition n space flow-graph capacity 
			     refine-capacity part2capacity
			     conflict-list)
  (define sol-map (make-hash))
  (define conflict-map (make-hash))
  
  (when debug (pretty-display `(conflict-list ,conflict-list)))
  ;; Construct conflict-map
  (for ([lst conflict-list])
     (for* ([set-x lst]
            [set-y lst])
       (unless (equal? set-x set-y)
         (for* ([x set-x]
                [y set-y])
           (hash-set! conflict-map (cons x y) 1)
           (hash-set! conflict-map (cons y x) 1)))))
  (when debug (pretty-display `(conflict-map ,conflict-map)))

  (define (root place)
    (define parent (hash-ref sol-map place))
    ;(pretty-display `(root ,place ,parent))
    (if (equal? place parent)
        place
        (let ([r (root parent)])
          (hash-set! sol-map place r)
          r)))
  
  (define (point r1 r2)
    (hash-set! sol-map r1 r2)
    (hash-set! space r2 (+ (hash-ref space r1) (hash-ref space r2)))
    (hash-remove! space r1))
  
  (define (unify p1 p2 [scale 1])
    (when debug (pretty-display `(unify ,p1 ,p2)))
    (define r1 (root p1))
    (define r2 (root p2))
    (define limit
      (cond
       [(hash-has-key? part2capacity r1) (hash-ref part2capacity r1)]
       [(hash-has-key? part2capacity r2) (hash-ref part2capacity r2)]
       [else capacity]))
    (when debug (pretty-display `(root ,r1 ,r2 ,limit)))

    (when (and (not (equal? r1 r2))
               (or (symbolic? r1) (symbolic? r2))
               (not (hash-has-key? conflict-map (cons r1 r2)))
               (not (hash-has-key? conflict-map (cons r2 r1)))
               (< (+ (hash-ref space r1) (hash-ref space r2)) 
                  (inexact->exact (floor (* limit scale)))))
	  (when debug (pretty-display `(merge ,p1 ,p2)))
	  ;(pretty-display `(parents ,r1 ,r2))
          (if (or (and (hash-has-key? part2capacity r2) (symbolic? r1))
		  (not (symbolic? r2)))
              (point r1 r2)
              (point r2 r1))
	  ))


  (when debug
        (pretty-display "------------------ before merge sym partition ---------------------")
        (pretty-display space)
        (pretty-display `(flow-graph ,flow-graph ,(list? flow-graph))))

  ;; point to itself
  (for ([key (hash-keys space)])
       (hash-set! sol-map key key))

  (for ([e flow-graph])
       (unify (car e) (cdr e)))

  ;; post merge to reduce number of cores
  (define partitions (hash-keys space))
  (for* ([p1 partitions]
  	 [p2 partitions])
  	(when (and (hash-has-key? space p1) (hash-has-key? space p2))
  	      (unify p1 p2 0.7)))

  (define vals (hash-values sol-map))
  (define concrete-vals (list->set (filter (lambda (x) (not (symbolic? x))) vals)))
  (when debug (pretty-display `(concrete-vals ,concrete-vals)))
  (define counter 0)
  (define (next-counter)
    (if (set-member? concrete-vals counter)
        (begin
          (set! counter (add1 counter))
          (next-counter))
        counter))
  (pretty-display `(sol-map ,sol-map))

  (define concrete2sym (make-vector n #f))
  (for ([key (hash-keys sol-map)])
       ;(pretty-display `(key ,key))
       (let ([val (root key)])
         (if (symbolic? val)
	     (begin
               (hash-set! sol-map val (next-counter))
	       (pretty-display `(set-concrete2sym ,counter val))
	       (vector-set! concrete2sym counter val) ;; set concrete2sym
	       (when debug (pretty-display `(hash-set ,val ,counter)))
	       (hash-set! sol-map counter counter)
	       (set! counter (add1 counter))
	       (root key))
	     (when (equal? (vector-ref concrete2sym val) #f)
		   (vector-set! concrete2sym val val))))) ;; set concrete2sym
  
  (when debug
        (pretty-display "------------------ after merge sym partition ---------------------")
        (pretty-display sol-map))
  (cons sol-map concrete2sym))
  

(define heuristic-partitioner%
  (class* object% (visitor<%>)
    (super-new)
    (init-field [space (make-hash)])

    (struct graphset (graph set))
    (define function-network (make-hash))
    
    ;; Declare IO function: in(), out(data)
    (hash-set! function-network "in" (graphset (list) (set)))
    (hash-set! function-network "out" (graphset (list) (set)))

    (define (inc-space place sp)
      ;(pretty-display `(inc-space ,place))
      (if (is-a? place TypeExpansion%)
          (for ([p (get-field place-list place)])
               (inc-space p sp))
          (if (hash-has-key? space place)
              (hash-set! space place (+ (hash-ref space place) sp))
              (hash-set! space place sp))))

    (define (network p1 p2)
      (when debug (pretty-display `(network ,p1 ,p2)))
      (cond
       [(and (is-a? p1 TypeExpansion%) (is-a? p2 TypeExpansion%))
	(flatten
	 (for/list ([x (get-field place-list p1)]
		    [y (get-field place-list p2)])
		   (network x y)))]

       [(is-a? p1 TypeExpansion%)
        (network (car (get-field place-list p1)) p2)]

       [(is-a? p2 TypeExpansion%)
        (network (car (get-field place-list p2)) p1)]

       [(and (not (equal? p1 p2)) 
             ;; (not (equal? p1 (* 2 w)))
             ;; (not (equal? p2 (* 2 w)))
             (rosette-number? p1)
             (rosette-number? p2)
             (or (symbolic? p1) (symbolic? p2)))
        (when debug (pretty-display `(network-real ,p1 ,p2)))
	(list (cons (cons p1 p2) 1))
        ]

       [else (list)]))

    (define (multiply-weight graph w)
      (map (lambda (e) (cons (car e) (* (cdr e) w))) graph))

    (define (graph->list graph)
      (define h (make-hash))
      (for ([edge graph])
	   (let* ([e1 (car edge)]
		  [e2 (cons (cdr e1) (car e1))]
		  [w (cdr edge)])
	     (cond
	      [(hash-has-key? h e1)
	       (hash-set! h e1 (+ (hash-ref h e1) w))]
	      
	      [(hash-has-key? h e2)
	       (hash-set! h e2 (+ (hash-ref h e2) w))]

	      [else
	       (hash-set! h e1 w)])))

      (hash->list h))
	      
    
    (define/public (visit ast)
      (cond
       [(is-a? ast Num%)
        (when debug 
              (pretty-display (format "HUE: Num ~a" (send ast to-string))))
        (inc-space (get-field place-type ast) est-num)
        (graphset (list) (set (get-field place-type ast)))
        ]

       [(is-a? ast Array%)
        (when debug 
              (pretty-display (format "HUE: Array ~a" (send ast to-string))))
        (define index (get-field index ast))
        (define place-type (get-field place-type ast))
        (inc-space place-type est-acc-arr)

        ;; Infer place
        (send index infer-place place-type)
        (define index-ret (send index accept this))
        
        (graphset (append (graphset-graph index-ret)
			  (network place-type (get-field place-type index)))
		  (set-add (graphset-set index-ret) place-type))
        ]

       [(is-a? ast Var%)
        (when debug 
              (pretty-display (format "HUE: Var ~a" (send ast to-string))))
        (inc-space (get-field place-type ast) est-var)
        (graphset (list) (set (get-field place-type ast)))
        ]

       [(is-a? ast UnaExp%)
        (when debug 
              (pretty-display (format "HUE: UnaExp ~a" (send ast to-string))))
        (define e1 (get-field e1 ast))
        (define op (get-field op ast))
        
        ;; set place-type
        (define place-type (get-field place-type ast))
        
        ;; Infer place
        (send e1 infer-place place-type)
        (define e1-ret (send e1 accept this))
        
        (inc-space place-type (hash-ref space-map (get-field op op)))
	(graphset
	 (append (graphset-graph e1-ret)
		 (network place-type (get-field place-type e1)))
	 (set-add (graphset-set e1-ret) place-type))
        ]

       [(is-a? ast BinExp%)
        (when debug
              (pretty-display (format "HEU: BinExp% ~a, place-type = ~a" 
                                      (send ast to-string) (get-field place-type ast))))
        (define e1 (get-field e1 ast))
        (define e2 (get-field e2 ast))
        (define op (get-field op ast))
        
        ;; set place-type
        (define place-type (get-field place-type ast))
        (send e1 infer-place place-type)
        (send e2 infer-place place-type)
        (define e1-ret (send e1 accept this))
        (define e2-ret (send e2 accept this))
        
        (inc-space place-type (hash-ref space-map (get-field op op)))
	(graphset
	 (append
	  (graphset-graph e1-ret)
	  (graphset-graph e2-ret)
	  (network place-type (get-field place-type e1))
	  (network place-type (get-field place-type e2)))
	 (set-union (graphset-set e1-ret) (graphset-set e2-ret) (set place-type)))
        ]

       [(is-a? ast FuncCall%)
        (when debug 
              (pretty-display (format "HUE: FuncCall ~a" (send ast to-string))))
	(define funccall-ret (hash-ref function-network (get-field name ast)))
	(define networks (graphset-graph funccall-ret))
        (define places (graphset-set funccall-ret))

        ;; infer place-type
	(for ([param (get-field stmts (get-field args (get-field signature ast)))]
	      [arg (flatten-arg (get-field args ast))])
	     (send arg infer-place (get-field place-type param))
	     (set! networks 
		   (append networks
			   (network (get-field place-type arg) (get-field place-type param)))))
       
        ;; visit children
        (for ([arg (get-field args ast)])
	     (let ([arg-ret (send arg accept this)])
	       (set! networks (append networks (graphset-graph arg-ret)))
	       (set! places (set-union places (graphset-set arg-ret)))))
        (graphset networks places)
        ]

       [(is-a? ast Assign%)
        (when debug
              (pretty-display (format "HEU: Assign% ~a = ~a" 
                                      (send (get-field lhs ast) to-string)
                                      (send (get-field rhs ast) to-string))))
        (define lhs (get-field lhs ast))
        (define rhs (get-field rhs ast))

        ;; infer place
        (send rhs infer-place (get-field place-type lhs))
        (send lhs infer-place (get-field place-type rhs))

        (define rhs-ret (send rhs accept this))
        (define lhs-ret (send lhs accept this))

	(graphset
	 (append (graphset-graph lhs-ret)
		 (graphset-graph rhs-ret)
		 (network (get-field place-type lhs) (get-field place-type rhs)))
	 (set-union (graphset-set rhs-ret) (graphset-set lhs-ret)))
        ]

       [(is-a? ast VarDecl%)
        (define place (get-field place ast))
        (inc-space place (* (length (get-field var-list ast))
                            (if (is-a? ast Param%)
                                (add1 est-data)
                                est-data)))
        (graphset (list) (set place))
        ]

       [(is-a? ast ArrayDecl%)
        (define place-list (get-field place-list ast))
        (define last 0)
        (define place-set
          (for/set ([p place-list])
            (let* ([from (get-field from p)]
                   [to   (get-field to p)])
              (when (not (= from last))
                    (send ast bound-error))
              (set! last to)
              (inc-space (get-field place p) (* (- to from) est-data)) ; increase space
              (get-field place p)
              )))

        (when (not (= (get-field bound ast) last))
              (send ast bound-error))
	(graphset (list) place-set)
        ]

       [(is-a? ast For%)
        (define place-list (get-field place-list ast))
              
        (define last 0)
        
        (when (list? place-list)
              (for ([p place-list])
                   (let* ([from (get-field from p)]
                          [to   (get-field to p)])
                     (when (not (= from last))
                           (send ast bound-error))
                     (set! last to))))

        (define body-ret (send (get-field body ast) accept this))
	(graphset
	 (multiply-weight (graphset-graph body-ret) (- (get-field to ast) (get-field from ast)))
	 (graphset-set body-ret))
        ]

       [(is-a? ast If%)
        (define cond-ret (send (get-field condition ast) accept this))

        (define body-ret (send (get-field true-block ast) accept this))
        (when (get-field false-block ast)
	      (define false-ret (send (get-field false-block ast) accept this))
	      (set! body-ret 
		    (graphset 
		     (append (graphset-graph body-ret) (graphset-graph false-ret))
		     (set-union (graphset-set body-ret) (graphset-set false-ret)))))

	(define networks (append (graphset-graph cond-ret) (graphset-graph body-ret)))
        (for* ([a (graphset-set cond-ret)]
	       [b (graphset-set body-ret)])
	      (set! networks (append networks (network a b))))

	(graphset networks
		  (set-union (graphset-set cond-ret) (graphset-set body-ret)))
        ]

       [(is-a? ast While%)
        (define pre-ret (send (get-field pre ast) accept this))
        (define cond-ret (send (get-field condition ast) accept this))
        (define body-ret (send (get-field body ast) accept this))

	(define networks (append (graphset-graph cond-ret) 
				 (graphset-graph body-ret)
				 (graphset-graph pre-ret)))
        (for* ([a (graphset-set cond-ret)]
               [b (set-union (graphset-set body-ret) (graphset-set pre-ret))])
              (set! networks (append networks (network a b))))

	(graphset (multiply-weight networks (get-field bound ast))
		  (set-union (graphset-set pre-ret) (graphset-set cond-ret) (graphset-set body-ret)))
        ]

       [(is-a? ast Return%) (graphset (list) (set))]
       
       [(is-a? ast FuncDecl%)
        (when (get-field return ast)
              (send (get-field return ast) accept this))
	(define args-ret (send (get-field args ast) accept this))
        (define body-ret (send (get-field body ast) accept this))
	(hash-set! function-network (get-field name ast)
		   (graphset (append (graphset-graph args-ret) (graphset-graph body-ret))
			     (set-union (graphset-set args-ret) (graphset-set body-ret))))
	(graphset (list) (set))
	]

       [(is-a? ast Program%)
	(for/list ([stmt (get-field stmts ast)])
		  (send stmt accept this))

        (define sorted-edges (sort (graph->list (graphset-graph (hash-ref function-network "main")))
				   (lambda (x y) (> (cdr x) (cdr y)))))
        (pretty-display `(sorted-edges ,sorted-edges))
        (values space (map car sorted-edges) (get-field conflict-list ast))]

       [(is-a? ast Block%)
        (foldl (lambda (stmt all) 
		 (define stmt-ret (send stmt accept this))
		 (graphset
		  (append (graphset-graph all) (graphset-graph stmt-ret))
		  (set-union (graphset-set all) (graphset-set stmt-ret))))
               (graphset (list) (set)) (get-field stmts ast))]

       [else
        (raise (format "visitor-heupartition: unimplemented for ~a" ast))]
       ))))

      
