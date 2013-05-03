#lang s-exp rosette

(require "header.rkt"
         "ast.rkt" "parser.rkt" "visitor-interface.rkt" "space-estimator.rkt" 
         "symbolic-dict.rkt")

(provide (all-defined-out))

(define debug #t)

(struct comminfo (msgs placeset firstast))

(define count-msg-interpreter%
  (class* object% (visitor<%>)
    (super-new)
    (init-field core-space 
                num-core 
                [env (make-hash)] 
                [places (make-cores #:capacity core-space #:max-cores num-core)]
		[known-stack (list #t)])
    
    ;; use this when we see @place(exp)
    (define (find-place ast [modify #t])
      (define place-exp (get-field place ast))

      (define (derive-place p)
        (cond
         [(is-a? p Var%) 
          (car (lookup env p))]
         
         [(is-a? p Array%)
          (cons (car (lookup env p)) (get-field index p))]
         
         [else
          (raise-syntax-error 'unsupported (format "place(~a) at src: l: ~a c: ~a"
                                                   (send p to-string)
                                                   (send p get-line)
                                                   (send p get-col)))]))

      (if (is-a? place-exp Place%)
          (let ([place (derive-place (get-field at place-exp))])
            (pretty-display (format "derive = ~a" place))
            (when modify
                  (set-field! place ast place))
            place)
          place-exp))
    
    (define (find-index place-obj)
      (let ([at (get-field at place-obj)])
	(if (is-a? at Array%)
	    (get-field index at)
	    at)))

    (define (find-place-type ast)
      (define place (find-place ast #f))
      (if (or (number? place) 
              (is-a? (cdr place) Base%))
          place
          (let ([place-exp (get-field place ast)]) ; Place%
            (cons place (find-index place-exp)))))

    ;; env dictionary map variable to (place . known-type)
    ;; place has 2 categories
    ;; 1) single place => integer
    ;; 2) place list   => (list_of_RangePlace%)

    ;; place-type has 2 categories
    ;; 1) single place => integer
    ;; 2) place list & index => (list_of_RangePlace% . index)

    ;;; Increase the used space of "place" by "add-space".
    (define (inc-space place add-space)
      ;(assert (or (number? place) (list? place)))
      (if (number? place)
          (cores-inc-space places place add-space)
          (for ([p place])
               (cores-inc-space places (get-field place p) add-space))))
    
    ;;; Increase the used space of "place" with op.
    (define (inc-space-with-op place op)
      (assert (or (number? place) (list? place)))
      ;TODO: change to (cores-add-op places place op)
      (if (number? place)
          (cores-inc-space places place (est-space op))
          (for ([p place])
               (cores-inc-space places (get-field place p) (est-space op)))))
    
    ;; Increase the used space of places in the given set by "add-space".
    ;; Used in body inside for and if.
    (define (inc-space-placeset placeset add-space)
      (define (loop placelist)
        (when (not (empty? placelist))
          (let* ([others (cdr placelist)]
                 [me (car placelist)])
            (loop others)
            (when (andmap (lambda (x) (not (equal? x me))) others) (inc-space me add-space)))))
        
      (loop (set->list placeset)))

    ;;; Count number of message passes. If there is a message pass, it also take up more space.
    (define (count-msg x-ast y-ast)
      ;(assert (and (is-a? x-ast Base%) (is-a? y-ast Base%)))

      (define (place-type? p)
	(or (number? p) (place-type-dist? p)))
      
      (define (place-type-dist? p)
        (and (pair? p) (and (and (list? (car p)) (is-a? (cdr p) Base%)))))
      
      ;; Return the place that a resides if a only lives in one place. 
      ;; Otherwise, return string representation of a.
      (define (get-str-rep a)
        ;(assert (place-type? a))
	(if (number? a)
	    a
            (let ([place-list (car a)]
                  [index (cdr a)])
              (if (= (length place-list) 1)
                  (get-field place (car place-list))
                  (format "~a . ~a" 
                          (place-list-to-string place-list)
                          (send index to-string))))))

      ;; Add comm space to cores
      (define (add-comm x)
	;(assert (place-type? x))
        (if (number? x)
             (inc-space x est-comm)
             (for ([p (car x)])
                  (inc-space (get-field place p) est-comm))))

      (define (same-place? a b)
	;(assert (and (place-type? a) (place-type? b)))
       
        (if (and (number? a) (number? b))
            (equal? a b)
            (if (and (place-type-dist? a) (place-type-dist? b))
                (let ([a-list (car a)]
                      [b-list (car b)]
                      [a-index (cdr a)]
                      [b-index (cdr b)])
                  (and (and (equal? (length a-list) (length b-list))
                            (equal? (send a-index to-string) (send b-index to-string)))
                       (andmap (lambda (a-p b-p) (send a-p equal-rangeplace? b-p))
                               a-list b-list)))
                ; if one of them is @any
                (or (and (is-a? a Place%) (equal? (get-field at a) "any"))
                    (and (is-a? b Place%) (equal? (get-field at b) "any")))))
        )

      ;; Return 1 if it is absolutly in one place
      ;;             or the index is known.
      ;; Return number of cores p resides in otherwise.
      (define (count-comm p)
	;(assert (place-type? p))
        (if (or (or (number? p)
                    (and (is-a? p Place%) (equal? (get-field at p) "any")))
                (and (get-field known-type (cdr p)) ; get known type of the index
		     (car known-stack))) ; get known type of the scope
            1
            (length (car p))))
      
      ;; x and y in form (cons place-list known-type)
      ;(pretty-display (send x-ast to-string))
      (define x (get-field place-type x-ast))
      (define x-comm (count-comm x))
      
      ;(pretty-display (send y-ast to-string))
      (define y (get-field place-type y-ast))
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
    
    (define/public (get-concrete-cores)
      (cores-evaluate places))

    (define/public (num-cores)
      (cores-count places))
      
    (define/public (visit ast)
      (cond
       [(is-a? ast Const%)
          (raise "error")
          (define place (find-place ast))
	  (inc-space place est-num) ; increase space
          (comminfo 0 (set place) ast)]

       [(is-a? ast Num%)
	  ;(define const (get-field n ast))
          (when debug (pretty-display (format ">> Num ~a" (send ast to-string))))

	  ;(send const accept this)
          (define place-type (find-place-type (get-field n ast)))
	  (set-field! place-type ast place-type)

          (comminfo 0 (to-place-set place-type) ast)]
       
       [(is-a? ast Array%)
          ;; lookup place from env
          (define place-known (lookup env ast))
          (define places (car place-known))
          (define known-type (cdr place-known))
          (set-field! known-type ast known-type)

	  (define index (get-field index ast))
	  (define index-ret (send index accept this))

          (when debug (pretty-display (format ">> Array ~a" (send ast to-string))))

          (if (= (length places) 1)
              ;; Array lives in only one place
              (set-field! place-type ast (get-field place (car places)))
	      (if (is-a? index Num%)
		  ;; Know exact index
		  (set-field! place-type ast (place-at places (send index get-value) ast))
		  ;; Pair of list of possible places and index
		  (set-field! place-type ast (cons places index))))

          (inc-space places est-acc-arr) ; not accurate

          (comminfo 
           (+ (comminfo-msgs index-ret) (count-msg index ast))
           (set-union (comminfo-placeset index-ret) (to-place-set places))
           (comminfo-firstast index-ret))
          ]

       [(is-a? ast Var%)
          ;; lookup place from env
          (define place-known (lookup env ast))
          (define place (car place-known))

          ;; place can be list if var is iterator
          ;; need to call to-place-type to turn place-list into (place-list . index)
          (set-field! place-type ast (to-place-type ast place))

          (set-field! known-type ast (cdr place-known))

          (when debug (pretty-display (format ">> Var ~a" (send ast to-string))))

          ;; no space taken for now
          ;; x[i] in loop => take no space, i can be on stack
          ;(inc-space (get-field place ast) est-var) ; doesn't work with place-list

          (comminfo 0 (to-place-set place) ast)
          ]

       [(is-a? ast Op%)
          (raise "error")
          (define place (find-place ast))
	  (inc-space-with-op place (get-field op ast)) ; increase space
	  (comminfo 0 (to-place-set place) ast)
          ]


       [(is-a? ast UnaExp%)
          (when debug (newline))
          (define e1 (get-field e1 ast))
          (define op (get-field op ast))
          (define e1-ret (send e1 accept this))
	  ;(define op-ret (send op accept this))
          
          ;; set place-type known-type
          (define place-type (find-place-type op))
          (set-field! place-type ast place-type)
          (set-field! known-type ast (get-field known-type e1))

	  ;; already set place type

          (when debug
                (pretty-display (format ">> UnaOp ~a" (send ast to-string))))
          
          (comminfo
           (+ (comminfo-msgs e1-ret) (count-msg ast e1))
           (set-union (comminfo-placeset e1-ret) (to-place-set place-type))
           (comminfo-firstast e1-ret))
          ]

       [(is-a? ast BinExp%)
          (when debug (newline))
          (define e1 (get-field e1 ast))
          (define e2 (get-field e2 ast))
          (define op (get-field op ast))
          (define e1-ret (send e1 accept this))
          (define e2-ret (send e2 accept this))
	  ;(define op-ret (send op accept this))

	  (pretty-display "here")
          
          ;; set place-type known-type
          (define place-type (find-place-type op))
	  (pretty-display "here")
          (set-field! place-type ast place-type)
          (set-field! known-type ast (and (get-field known-type e1) (get-field known-type e2)))
          ;; ^ problematic here
          
          (when debug
                (pretty-display (format ">> BinOp ~a" (send ast to-string))))

          (comminfo
           (+ (+ (+ (comminfo-msgs e1-ret) (comminfo-msgs e2-ret))
                 (count-msg ast e1))
              (count-msg ast e2))
           (set-union (set-union (comminfo-placeset e1-ret) (comminfo-placeset e2-ret)) (to-place-set place-type))
           (comminfo-firstast e1-ret))
          ]
                
       [(is-a? ast VarDecl%) 
          (define place (find-place ast))
	  (define known (get-field known ast))
          (define var-list (get-field var-list ast))
          
          ;; put vars into env
          (for ([var var-list])
               (dict-set! env var (cons place known)))

          (when debug
                (pretty-display (format ">> VarDecl ~a" var-list)))

	  ;; increase space for variable
          (inc-space place (* (length var-list) est-data)) ; increase space
          (comminfo 0 (set place) ast)
          ]

       [(is-a? ast ArrayDecl%)
          (define place-list (get-field place-list ast)) ; don't support place(x)
          (define known (get-field known ast))

          (when debug
                (pretty-display (format ">> ArrayDecl ~a" (get-field var ast))))

          ;; check boundaries
          (define last 0)

          (when (list? place-list)
                (for ([p place-list])
                     (let* ([from (get-field from p)]
                            [to   (get-field to p)])
                       (when (not (= from last))
                             (send ast bound-error))
                       (set! last to)
                       (inc-space (find-place p) (* (- to from) est-data)) ; increase space
                       ))

                (when (not (= (get-field bound ast) last))
                      (send ast bound-error)))
          
          ;; We might not need this. This is a dead code right now.
          (when (and (is-a? place-list Place%) 
                     (equal? (get-field at place-list) "any"))
            (raise-type-error (get-field var ast) "anything about @any" 
                              0 "Cannot assign @any for array."))
            

          ;; put array into env
          (dict-set! env (get-field var ast) (cons place-list known))

          (comminfo 0 (to-place-set place-list) ast)
          ]

       [(is-a? ast For%)
          (define place-list (get-field place-list ast)) ; don't allow place(x)

          (when debug
                (pretty-display (format ">> For ~a" (send (get-field iter ast) to-string))))

          ;; check boundaries
          (define last 0)
        
          (when (list? place-list)
              (for ([p place-list])
                   (let* ([from (get-field from p)]
                          [to   (get-field to p)])
                     (when (not (= from last))
                           (send ast bound-error))
                     (set! last to))))
		 ;(inc-space (get-field place p) est-for))) ; increase space

          ;; Add new scope for body.
          (define new-env (make-hash))
          (dict-set! new-env "__up__" env)
          (set! env new-env)

          ;; This "for" iterating pattern is satically known.
          (dict-set! env 
                     (get-field name (get-field iter ast))
                     (cons place-list #t))

          (define body-ret (send (get-field body ast) accept this))
          (define body-place-set (comminfo-placeset body-ret))
          
          ;(for ([p body-place-set])
          ;     (inc-space p est-for)) ; increase space (already accounts for i here)
          (inc-space-placeset body-place-set est-for)

          ;; Remove scope.
          (set! env (dict-ref env "__up__"))

          (comminfo
           (* (comminfo-msgs body-ret) (- (get-field to ast) (get-field from ast)))
           body-place-set
           (comminfo-firstast body-ret))
          ]

       [(is-a? ast If%)
        (define condition (get-field condition ast))
        (define condition-ret (send condition accept this))
        
	; push to stack
	(set! known-stack (cons (get-field known-type condition) known-stack))
        (define true-ret (send (get-field true-block ast) accept this))
        
        ; between condition and true-block
        (define ret
          (comminfo
           (+ (+ (count-msg condition (comminfo-firstast true-ret))
                 (comminfo-msgs condition-ret))
              ; *2 for 1) sending condition result to body
              ;        2) communication within body themselves
              (* 2 (comminfo-msgs true-ret)))
           (set-union (comminfo-placeset condition-ret) (comminfo-placeset true-ret))
           (comminfo-firstast condition-ret)))
        
        (define false-block (get-field false-block ast))
	; pop from stack
	(set! known-stack (cdr known-stack))
        
        (set! ret 
              (let ([false-block (get-field false-block ast)])
                (if false-block
                    ; between condition and false-block
                    (let ([false-ret (send false-block accept this)])
                      (comminfo
                       (+ (comminfo-msgs ret)
                          (+ (count-msg condition (comminfo-firstast false-ret))
                             (* 2 (comminfo-msgs false-ret))))
                       (set-union (comminfo-placeset ret) (comminfo-placeset false-ret))
                       (comminfo-firstast ret)))
                    ret)))
        
        ; increase space
        (inc-space-placeset (comminfo-placeset ret) est-if)
        ret]

       [(is-a? ast While%)
        (define condition (get-field condition ast))
        (define condition-ret (send condition accept this))
        
	; push to stack
	(set! known-stack (cons (get-field known-type condition) known-stack))
        (define body-ret (send (get-field body ast) accept this))
	; pop from stack
	(set! known-stack (cdr known-stack))

        ; increase space
        (inc-space-placeset (comminfo-placeset body-ret) est-while)

	(comminfo
	 (+ (comminfo-msgs condition-ret) 
	    (* (comminfo-msgs body-ret) (get-field bound ast)))
	 (set-union (comminfo-placeset condition-ret) (comminfo-placeset body-ret))
	 (comminfo-firstast condition-ret))]

       [(is-a? ast Assign%) 
          (when debug (newline))
          (define lhs (get-field lhs ast))
          (define rhs (get-field rhs ast))

          (when debug
                (pretty-display ">> Assign"))
          ;; Visit lhs
          (define lhs-ret (send lhs accept this))

          (define lhs-place-type (get-field place-type lhs))
          (define lhs-known-type (get-field known-type lhs))
	  (define lhs-name (get-field name lhs))

          ;; If rhs is a number, set place to be equal to lhs
          (when (is-a? rhs Num%) (send rhs infer-place lhs-place-type))

          ;; Visit rhs
          (define rhs-ret (send rhs accept this))

          ;; Update dynamic known type
          (define rhs-known-type (get-field known-type rhs))
          (when (and (not rhs-known-type) lhs-known-type)
                (set-field! known-type lhs #f)
		(let ([old (dict-ref env lhs-name)])
		  (dict-set! env lhs (cons (car old) #f))))

	  ;; Don't increase space
       
          (comminfo
           (+ (+ (comminfo-msgs rhs-ret) (comminfo-msgs lhs-ret)) (count-msg lhs rhs))
           (set-union (comminfo-placeset rhs-ret) (comminfo-placeset lhs-ret))
           (comminfo-firstast rhs-ret))
         ]

       [(is-a? ast Block%) 
          (foldl (lambda (stmt all) 
                   (let ([ret (send stmt accept this)])
                     (comminfo (+ (comminfo-msgs all) (comminfo-msgs ret))
                           (set-union (comminfo-placeset all) (comminfo-placeset ret))
                           (or (comminfo-firstast all) (comminfo-firstast ret)))))
                   (comminfo 0 (set) #f) (get-field stmts ast))]
       [else (raise "Error: count-msg-interpreter unimplemented!")]))
))
