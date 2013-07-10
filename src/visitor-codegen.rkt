#lang racket

(require "header.rkt"
         "ast.rkt" 
	 "ast-util.rkt"
	 "visitor-interface.rkt"
         "arrayforth.rkt")

(provide (all-defined-out))

(define code-generator%
  (class* object% (visitor<%>)
    (super-new)
    (init-field data-size iter-size core w h virtual
		[x (floor (/ core w))] [y (modulo core w)]
                [helper-funcs (list)] [if-count 0] [while-count 0]
                [maxnum 1]
                ;; map virtual index to real index
                [index-map (make-hash)])

    (define debug #f)

    (define (is-temp? name)
      (regexp-match #rx"_temp" name))
      
    (define (gen-op op)
      (cond
       [(equal? op "~") (list (gen-block "-" 1 1))]
       [(equal? op "!") (list (gen-block "-" 1 1))]
       [(equal? op "*") (list (mult))]
       [(equal? op "-") (list (gen-block "-" "1" "." "+" "." "+" 2 1))]
       [(equal? op "+") (list (gen-block "." "+" 2 1))]
       [(equal? op ">>") (list (gen-block "dup" "dup" "or" "-" "." "+" 1 1) 
			       (forloop (gen-block) (list (gen-block "2/" 1 1))))] 
       ;; x-1 for 2/ unext
       [(equal? op "<<") (list (gen-block "dup" "dup" "or" "-" "." "+" 1 1) 
			       (forloop (gen-block) (list (gen-block "2*" 1 1))))] 
       ;; x-1 for 2* unext
       [(equal? op "&") (list (gen-block "and" 2 1))]
       [(equal? op "^") (list (gen-block "or" 2 1))]
       [(equal? op "|") (list (gen-block "over" "-" "and" "." "+" 2 1))]
       [else (raise (format "visitor-codegen: gen-op: unimplemented for ~a" op))]))

    (define (gen-port port)
      ;(pretty-display `(gen-port ,port))
      (cond
       [(equal? port `N)
	(if (= (modulo x 2) 0) "up" "down")]
       [(equal? port `S)
	(if (= (modulo x 2) 0) "down" "up")]
       [(equal? port `E)
	(if (= (modulo y 2) 0) "right" "left")]
       [(equal? port `W)
	(if (= (modulo y 2) 0) "left" "right")]
       [(equal? port `IO)
        "io"]))

    (define (get-if-name)
      (set! if-count (add1 if-count))
      (format "~aif" if-count))

    (define (get-while-name)
      (set! while-count (add1 while-count))
      (format "~awhile" while-count))

    (define (define-if body)
      (define name (get-if-name))
      (define new-if (funcdecl name body))
      (set! helper-funcs (cons new-if helper-funcs))
      (list (funccall name)))

    (define (get-op exp)
      (get-field op (get-field op exp)))

    (define (get-e1 exp)
      (get-field e1 exp))

    (define (get-e2 exp)
      (get-field e2 exp))

    (define (binop-equal? exp str)
      (and (is-a? exp BinExp%) (equal? (get-op exp) str)))
    
    (define (minus e1 e2)
      (if (and (is-a? e2 Num%) (= 0 (get-field n (get-field n e2))))
	  e1
	  (new BinExp% [op (new Op% [op "-"])] [e1 e1] [e2 e2])))

    (define (get-var mem)
      ;(pretty-display `(index-map ,(meminfo-virtual mem) ,(meminfo-addr mem)))
      (dict-set! index-map (meminfo-virtual mem) (meminfo-addr mem))
      (if virtual (meminfo-virtual mem) (meminfo-addr mem)))

    (define (get-iter mem)
      (define reduce (+ (meminfo-virtual data-size) (meminfo-virtual mem)))
      (define actual (+ (meminfo-addr data-size) (meminfo-virtual mem)))
      (dict-set! index-map reduce actual)
      (if virtual reduce actual))

    (define/public (visit ast)
      (cond
       [(or (is-a? ast VarDecl%)
	    (is-a? ast ArrayDecl%))
	(list)]

       [(is-a? ast Num%)
        (when debug 
              (pretty-display (format "\nCODEGEN: Num ~a" (send ast to-string))))
        (define n (get-field n (get-field n ast)))
        (when (> n maxnum)
              (set! maxnum n))
	(list (gen-block (number->string n) 0 1))]

       [(is-a? ast Array%)
        (when debug 
              (pretty-display (format "\nCODEGEN: Array ~a" (send ast to-string))))
	(define index-ret (send (get-field index ast) accept this))

	(define offset (get-field offset ast))
	(define offset-ret 
	  (if (> offset 0)
	      (list (gen-block (number->string offset) "-" "1" "." "+" "." "+" 1 1))
	      (list (gen-block))))

	(define address (get-field address ast))
	(define array-ret (list (gen-block (number->string (get-var address)) "." "+" "a!" "@" 1 1)))

	(prog-append index-ret offset-ret array-ret)]

       [(is-a? ast Var%)
        (when debug 
              (pretty-display (format "\nCODEGEN: Var ~a" (send ast to-string))))
	(define address (get-field address ast))
	(if address
	    ;; push on the stack
	    (if (meminfo-data address)
		;; data
		(list (gen-block (number->string (get-var address)) "a!" "@" 0 1))
		;; iter
		(list (gen-block (number->string (get-iter address)) "a!" "@" 0 1)))
	    ;; already on the stack
	    (list))]

       [(is-a? ast UnaExp%)
        (when debug 
              (pretty-display (format "\nCODEGEN: UnaExp ~a" (send ast to-string))))
	(define e1-ret (send (get-field e1 ast) accept this))
	(define op (get-field op (get-field op ast)))
	(prog-append e1-ret (gen-op op))]

       [(is-a? ast BinExp%)
        (when debug 
              (pretty-display (format "\nCODEGEN: BinExp ~a" (send ast to-string))))
	(define e1-ret (send (get-field e1 ast) accept this))
	(define e2-ret (send (get-field e2 ast) accept this))
	(define op (get-field op (get-field op ast)))
	(prog-append e1-ret e2-ret (gen-op op))]

       [(is-a? ast Recv%)
        (when debug 
              (pretty-display (format "\nCODEGEN: Recv ~a" (get-field port ast))))
        (list (gen-block (gen-port (get-field port ast)) "a!" "@" 0 1))]

       [(is-a? ast Send%)
        (define data (get-field data ast))
        (when debug 
              (pretty-display (format "\nCODEGEN: Send ~a ~a" (get-field port ast) data)))
	(define data-ret (send data accept this))
        (define temp-ret
          (if (is-a? data Temp%)
              (list (gen-block "dup" 1 2))
              (list (gen-block))))
	(define send-ret (list (gen-block (gen-port (get-field port ast)) "a!" "!" 1 0)))
        (prog-append data-ret temp-ret send-ret)]

       [(is-a? ast FuncCall%)
        (when debug 
              (pretty-display (format "\nCODEGEN: FuncCall ~a" (send ast to-string))))
	;; (define args (get-field args ast))
	;; (define n-temp (count is-temp? args))
	;; (define move (block (for/list ([i n-temp]) "push") n-temp 0))
	;; (define arg-ret 
	;;   (foldl (lambda (arg all) (prog-append all (send arg accept this))) 
	;; 	 (list) args))
	(list (funccall (get-field name ast)))]

       [(is-a? ast Assign%)
	(define lhs (get-field lhs ast))
	(define rhs (get-field rhs ast))
        (when debug 
              (pretty-display (format "\nCODEGEN: Assign ~a = ~a" 
				      (send lhs to-string) (send rhs to-string))))
	(define address (get-field address lhs))
	;(pretty-display `(address ,address))
	(if (is-a? lhs Array%)
	    (let* ([index-ret (send (get-field index lhs) accept this)]
		   [offset (get-field offset lhs)]
		   [offset-ret (if (> offset 0)
				   (list (gen-block (number->string offset) "-" "1" "." "+" "." "+" 1 1))
				   (list (gen-block)))]
		   [rhs-ret (send rhs accept this)])
	      (prog-append 
	       rhs-ret
	       index-ret
	       offset-ret
	       (list (gen-block (number->string (get-var address)) 
                                "." "+" "a!" "!" 2 0))))
	    (let ([rhs-ret (send rhs accept this)])
		  (prog-append
		   rhs-ret
		   (if address
		       (if (meminfo-data address)
			   ;; data
			   (list (gen-block (number->string (get-var address)) 
                                            "a!" "!" 1 0))
			   ;; iter
			   (list (gen-block 
                                  (number->string (get-iter address))
                                  "a!" "!" 1 0)))
		       ;; temp on stack
		       (list)))))]

       [(is-a? ast Return%)
        (when debug 
              (pretty-display (format "\nCODEGEN: Return")))
        (define val (get-field val ast))
	(define ret
	  (if (list? val)
	      (foldl (lambda (v all) (prog-append all (send v accept this)))
		     (list) val)
	      (send (get-field val ast) accept this)))

	(if (empty? ret)
	    (list (gen-block #f))
	    (begin
	      (set-block-mem! (last ret) #f)
	      ret))
	]

       [(is-a? ast If%)
        (when debug 
              (pretty-display (format "\nCODEGEN: If")))
	;; not yet support && ||
        (define cond-ret (send (get-field condition ast) accept this))
        (define true-ret (send (get-field true-block ast) accept this))
        (define false-ret 
          (if (get-field false-block ast)
              (send (get-field false-block ast) accept this)
              #f))

        (cond
         [(is-a? ast If!=0%)
          (if false-ret
              (define-if (prog-append cond-ret (list (iftf true-ret false-ret))))
              (prog-append cond-ret (list (ift true-ret))))
          ]

         [(is-a? ast If<0%)
          (if false-ret
              (define-if (prog-append cond-ret (list (-iftf true-ret false-ret))))
              (prog-append cond-ret (list (-ift true-ret))))
          ]

         [else
          (if false-ret
              (define-if (prog-append cond-ret (list (iftf true-ret false-ret))))
              (prog-append cond-ret (list (ift true-ret))))])]
       
       [(is-a? ast While%)
	(define exp (get-field condition ast))
	(define name (get-while-name))
	(define body (get-field body ast))
	(define block (new Block% [stmts (append (get-field stmts body)
						 (list (new FuncCall% [name name] [args (list)])))]))

	;; desugar into if construct
	;; set name = while-name
	(define if-rep
	  (cond
	   [(is-a? ast While!=0%) 
	    (new If!=0% [condition exp] [true-block block])]

	   [(is-a? ast While==0%)
	    (new If!=0% [condition exp] 
		 [true-block (new Block% [stmts (list)])]
		 [false-block block])]

	   [(is-a? ast While<0%)
	    (new If<0% [condition exp] [true-block block])]
	    
	   [(is-a? ast While>=0%) 
	    (new If<0% [condition exp] 
		 [true-block (new Block% [stmts (list)])]
		 [false-block block])]

	   [else
	    (new If% [condition exp] [true-block block])]))
	
	(define if-ret (send if-rep accept this))
	;; (pretty-display "~~~~~~~~~~~~~~~~~~~~~~")
	;; (pretty-display "AST")
	;; (send if-rep pretty-print)

	;; (pretty-display "RESULT")
	;; (codegen-print if-ret)
	;; (pretty-display "~~~~~~~~~~~~~~~~~~~~~~")

	(unless (funccall? (car if-ret))
		(define-if if-ret))

        ;; rename last function declaration to while-name
        (set-funcdecl-name! (car helper-funcs) name)

	(list (funccall name))
	]

       [(is-a? ast For%)
        (define from (get-field from ast))
        (define to (get-field to ast))
        (define address (get-iter (get-field address ast)))
        (define address-str (number->string address))
        
        (define init-ret (gen-block (number->string from) address-str "a!" "!" 
                                    (number->string (- to from 1)) 0 1)) ;; loop bound
         
        (define body-ret (send (get-field body ast) accept this))
        (define body-decor (list (gen-block address-str "a!" "@" "1" "." "+" "!" 0 0)))

        (list (forloop init-ret (prog-append body-ret body-decor)))
	]

       [(is-a? ast FuncDecl%)
	(define decls (get-field stmts (get-field args ast)))
	(define n-decls (length decls))
	(define body-ret (send (get-field body ast) accept this))

	(if (> n-decls 0)
	    (let* ([address (get-field address (last decls))]
		   [args-ret (list
			      (block (append 
				      (list (number->string (get-var address)) "a!")
				      (for/list ([i (in-range n-decls)]) "!+")) n-decls 0 #t))])
	      (funcdecl (get-field name ast) (prog-append args-ret body-ret)))
	    (funcdecl (get-field name ast) body-ret))]

       [(is-a? ast Program%)
	;; return list of function list
        (define main-funcs
          (for/list ([decl (filter (lambda (x) (is-a? x FuncDecl%)) 
                                   (get-field stmts ast))])
            (send decl accept this)))

        (dict-set! index-map 
                   (+ (meminfo-virtual data-size) iter-size)
                   (+ (meminfo-addr data-size) iter-size))
        (aforth (append (reverse helper-funcs) main-funcs) 
                (+ (get-var data-size) iter-size) 
                (max (inexact->exact (floor (+ (/ (log maxnum) (log 2)) 2))) ga-bit)
                index-map)
        ]

       [(is-a? ast Block%)
	(foldl (lambda (stmt all) (prog-append all (send stmt accept this)))
	       (list) (get-field stmts ast))]

       [else
	(raise (format "visitor-codegen: unimplemented for ~a" ast))]

       ))))
