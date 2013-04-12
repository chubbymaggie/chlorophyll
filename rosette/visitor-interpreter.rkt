#lang s-exp rosette

(require "header.rkt"
         "ast.rkt" "parser.rkt" "visitor-interface.rkt" "space-estimator.rkt" 
         "symbolic-dict.rkt")

(provide (all-defined-out))

(define debug #f)

(define count-msg-interpreter%
  (class* object% (visitor<%>)
    (super-new)
    (init-field core-space num-core [env (make-hash)] [places (make-cores #:capacity core-space #:max-cores num-core)])

    ;; env dictionary map variable to (place . known-type)
    ;; place has 2 categories
    ;; 1) single place => integer
    ;; 2) place list   => (list_of_RangPlace% . index)

    ;;; Increase the used space of "place" by "add-space".
    (define (inc-space place add-space)
      (assert (or (number? place) (list? place)))
      (if (number? place)
          (cores-inc-space places place add-space)
          (for ([p place])
               (cores-inc-space places (get-field place p) add-space))))
    
    (define (inc-space-with-op place op)
      (assert (or (number? place) (list? place)))
      ;TODO: change to (cores-add-op places place op)
      (if (number? place)
          (cores-inc-space places place (est-space op))
          (for ([p place])
               (cores-inc-space places (get-field place p) (est-space op)))))

    ;;; Count number of message passes. If there is a message pass, it also take up more space.
    (define (count-msg x-ast y-ast)
      (assert (and (is-a? x-ast Base%) (is-a? y-ast Base%)))

      (define (place-type? p)
	(or (number? p) 
	    (and (and (list? (car p)) (is-a? (cdr p) Base%)))))
      
      ;; Return the place that a resides if a only lives in one place. 
      ;; Otherwise, return string representation of a.
      (define (get-str-rep a)
	(if (number? a)
	    a
	    (if (= (length (car a)) 1)
		(get-field place (car a))
		(format "~a . ~a" 
			(place-list-to-string (car a)) 
			(send (cdr a) to-string)))))

      ;; Add comm space to cores
      (define (add-comm x)
	(assert (place-type? x))
        (if (number? x)
             (inc-space x est-comm)
             (for ([p (car x)])
                  (inc-space (get-field place p) est-comm))))

      (define (same-place? a b)
	(assert (and (place-type? a) (place-type? b)))
	(pretty-display (format "a=~a" (get-str-rep a)))
	(pretty-display (format "b=~a" (get-str-rep b)))
	(equal? (get-str-rep a) (get-str-rep b)))

      ;; x is in form (cons place-list known-type)
      (define (count-comm p)
	(assert (place-type? p))
	(if (number? p)
	    1
	    (if (get-field known-type (cdr p)) ;; get known type of the index
		1
		(length (car p)))))
      
      (define x (get-field place x-ast))
      (define y (get-field place y-ast))
      (define x-comm (count-comm x))
      (define y-comm (count-comm y))

      (cond 
        ;[(equal? x 0) 0] ;any
        ;[(equal? y 0) 0] ;any

        ;; if x and y are the same place.
        [(same-place? x y) 0]

	;; if x and y are in a single core.
	[(and (= x-comm 1) (= y-comm 1))
         (add-comm x)
         (add-comm y)
         (when debug (pretty-display "COMM + 1"))
	 1]

        ;; if x or y is in multiple cores.
        [else 
         (add-comm x)
         (add-comm y)
         (when debug (pretty-display (format "COMM + ~a + ~a" x-comm y-comm)))
         (+ x-comm y-comm)])) ;; TODO: not 1 if it's not an array of statically known

    (define (lookup env ast)
      (dict-ref env (get-field name ast)
                (lambda ()
                  (if (dict-has-key? env "__up__")
                      (lookup (dict-ref env "__up__") ast)
                      (send ast not-found-error)))))
    
    (define (place-at places index ast)
      (when (empty? places)
            (send ast index-out-of-bound index))
      (let* ([current (car places)]
             [from    (get-field from current)]
             [to      (get-field to current)])
        (if (and (>= index from) (< index to))
            (get-field place current)
            (place-at (cdr places) index ast))))
        
    
    (define/public (assert-capacity)
      (cores-assert places))

    (define/public (display-used-space)
      (display-cores places))

    (define/public (num-cores)
      (cores-count places))
      
    (define/public (visit ast)
      (cond
       [(is-a? ast Const%)
	  (inc-space (get-field place ast) est-num) ; increase space
	  0]

       [(is-a? ast Num%)
	  (define const (get-field n ast))
          (when debug (pretty-display (format "Num ~a" (send ast to-string))))

	  (send const accept this)
	  (set-field! place-type ast (get-field place))
          0]
       
       [(is-a? ast Array%)
          ;; lookup place from env
          (define place-known (lookup env ast))
          (define places (car place-known))
          (define known-type (cdr place-known))
          (set-field! known-type ast known-type)

	  (define index (get-field index ast))
	  (define index-count (send index accept this))

          (when debug (pretty-display (format ">> Array ~a" (send ast to-string))))

          (if (= (length places) 1)
              ;; Array lives in only one place
              (set-field! place-type ast (get-field place (car places)))
	      (if (is-a? index Num%)
		  ;; Know exact index
		  (set-field! place-type ast (place-at places (get-field n index) ast))
		  ;; Pair of list of possible places and index
		  (set-field! place-type ast (cons places index))))

          (inc-space places est-acc-arr) ; not accurate
          
          (+ index-count (count-msg index ast))]

       [(is-a? ast Var%)
          ;; lookup place from env
          (define place-known (lookup env ast))
          (set-field! place-type ast (car place-known))
          (set-field! known-type ast (cdr place-known))

          (when debug (pretty-display (format ">> Var ~a" (send ast to-string))))

          ;; no space taken for now
          ;; x[i] in loop => take no space, i can be on stack
          ;(inc-space (get-field place ast) est-var) ; doesn't work with place-list
          0]

       [(is-a? ast Op%)
	  (inc-space-with-op (get-field place ast) (get-field place op ast)) ; increase space
	  0]


       [(is-a? ast UnaExp%)
          (when debug (newline))
          (define e1 (get-field e1 ast))
          (define e1-count (send e1 accept this))
	  (send op accept this)
          
          ;; set known type
          (set-field! known-type ast (get-field known-type e1))

	  ;; already set place type

          (when debug
                (pretty-display (format ">> UnaOp ~a" (send ast to-string))))
          
          (+ e1-count (count-msg ast e1))]

       [(is-a? ast BinExp%)
          (when debug (newline))
          (define e1 (get-field e1 ast))
          (define e2 (get-field e2 ast))
          (define e1-count (send e1 accept this))
          (define e2-count (send e2 accept this))
	  (send op accept this)
          
          ;; set known type
          (set-field! known-type ast (and (get-field known-type e1) (get-field known-type e2)))

          (when debug
                (pretty-display (format ">> BinOp ~a" (send ast to-string))))

          (+ (+ (+ e1-count e2-count)
                      (count-msg ast e1))
                   (count-msg ast e2))]
                
       [(is-a? ast VarDecl%) 
          (define place (get-field place ast))
	  (define known (get-field known ast))
          (define var-list (get-field var-list ast))
          
          ;; put vars into env
          (for ([var var-list])
               (dict-set! env var (cons place known)))

          (when debug
                (pretty-display (format ">> VarDecl ~a" var-list)))

	  ;; increase space for variable
          (inc-space place (* (length var-list) est-data)) ; increase space

          0]

       [(is-a? ast ArrayDecl%)
          (define place-list (get-field place-list ast))
          (define known (get-field known ast))

          (when debug
                (pretty-display (format ">> ArrayDecl ~a" (get-field var ast))))

          ;; check boundaries
          (define last 0)

          (for ([p place-list])
	       (let* ([from (get-field from p)]
		      [to   (get-field to p)])
		 (when (not (= from last))
		       (send ast bound-error))
		 (set! last to)
		 (inc-space (get-field place p) (* (- to from) est-data)) ; increase space
	       ))

          (when (not (= (get-field bound ast) last))
                (send ast bound-error))

          ;; put array into env
          (dict-set! env (get-field var ast) (cons place-list known))

          0]

       [(is-a? ast For%)
          (define place-list (get-field place-list ast))

          (when debug
                (pretty-display (format ">> For ~a" (send (get-field iter ast) to-string))))

          ;; check boundaries
          (define last 0)
        
          (for ([p place-list])
	       (let* ([from (get-field from p)]
		      [to   (get-field to p)])
		 (when (not (= from last))
		       (send ast bound-error))
		 (set! last to)
		 (inc-space (get-field place p) est-for))) ; increase space

          ;; Add new scope for body.
          (define new-env (make-hash))
          (dict-set! new-env "__up__" env)
          (set! env new-env)

          ;; This "for" iterating pattern is satically known.
          (dict-set! env 
                     (get-field name (get-field iter ast))
                     (cons (cons place-list (get-field iter ast)) #t))

          (define num-msgs (send (get-field body ast) accept this))

          ;; Remove scope.
          (set! env (dict-ref env "__up__"))

          (* num-msgs (- (get-field to ast) (get-field from ast)))
          ]

       [(is-a? ast Assign%) 
          (when debug (newline))
          (define lhs (get-field lhs ast))
          (define rhs (get-field rhs ast))

          (when debug
                (pretty-display ">> Assign"))
          ;; Visit lhs
          (send lhs accept this)

          (define lhs-place-type (get-field place-type lhs))
          (define lhs-known-type (get-field known-type lhs))

          ;; If rhs is a number, set place to be equal to lhs
          (when (is-a? rhs Num%) (send rhs infer-place lhs-place))

          ;; Visit rhs
          (define rhs-count (send rhs accept this))

          ;; Update dynamic known type
          (define rhs-known-type (get-field known-type rhs))
	  (define lhs-name (get-field name rhs))
          (when (and (not rhs-known-type) lhs-known-type)
                (set-field! known-type lhs #f)
		(let ([old (dict-ref env lhs-name)])
		  (dict-set! env lhs (cons (car old) #f))))

	  ;; Don't increase space
       
          (+ rhs-count (count-msg lhs rhs))
        ]

       [(is-a? ast Block%) 
          (foldl (lambda (stmt sum) (+ sum (send stmt accept this))) 
                 0 
                 (get-field stmts ast))]
       [else (raise "Error: count-msg-interpreter unimplemented!")]))
))

