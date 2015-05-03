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
                [helper-funcs (list)] 
                [data (make-vector (+ (meminfo-addr data-size) iter-size) 0)]
                [if-count 0] [while-count 0]
                [maxnum 1]
                ;; map virtual index to real index
                [index-map (make-hash)]
                [n-regs 0])

    (define debug #f)
    (define const-a (list #f))
    (define cond-onstack #f)
    (define in-pre #f)
    (define rotate #f)

    (define-syntax gen-block
      (syntax-rules ()
	[(gen-block)
	 (new-block (list) 0 0 (restrict #t #f #f #f) (list))]
	[(gen-block mem)
	 (new-block (list) 0 0 (restrict mem (car const-a) #f #f) (list))]
	[(gen-block a ... in out)
	 (new-block (list a ...) in out (restrict #t (car const-a) #f #f) (list a ...))]))

    (define-syntax gen-block-a
      (syntax-rules ()
	[(gen-block-a a ... in out)
	 (new-block (list a ...) in out (restrict #t #t #f #f) (list a ...))]))

    (define-syntax gen-block-in
      (syntax-rules ()
	[(gen-block a ... in out incnstr)
	 (new-block (list a ...) in out (restrict #t (car const-a) #f #f) incnstr 
                    (list a ...))]))

    (define-syntax gen-block-r
      (syntax-rules ()
	[(gen-block-r a ... in out)
         (new-block (list a ...) in out (restrict #t (car const-a) #f #t) (list a ...))]))
    
    (define-syntax gen-block-list
      (syntax-rules ()
	[(gen-block-list insts insts-org in out)
	 (new-block insts in out (restrict #t (car const-a) #f #f) insts-org)]
        ))

    (define-syntax gen-block-org
      (syntax-rules ()
	[(gen-block-org (a ...) (b ...) in out)
	 (new-block (list a ...) in out (restrict #t (car const-a) #f #f) (list b ...))]))
    
    (define (gen-block-store addr addr-org in)
      (if (= in 1)
          (new-block (list addr "b!" "!b") in 0 (restrict #t (car const-a) #f #f) 
                 (list addr-org "b!" "!b"))
          (if (car const-a)
              (new-block (append (list "a" "push" addr "a!") 
                             (for/list ([i (in-range in)]) "!+")
                             (list "pop" "a!"))
                     in 0 (restrict #t (car const-a) #f #f)
                     (append (list "a" "push" addr-org "a!") 
                             (for/list ([i (in-range in)]) "!+")
                             (list "pop" "a!")))
              (new-block (append (list addr "a!") 
                             (for/list ([i (in-range in)]) "!+"))
                     in 0 (restrict #t (car const-a) #f #f)
                     (append (list addr-org "a!") 
                             (for/list ([i (in-range in)]) "!+"))))))
      
    (define (gen-op op)
      (define (save-a code)
	(if (car const-a)
	    (append (list (gen-block-r "a" "push" 0 0))
		    code
		    (list (gen-block-r "pop" "a!" 0 0)))
	    code))

      (cond
       [(equal? op "~") (list (gen-block "-" 1 1))]
       [(equal? op "!") (list (gen-block "-" 1 1))]
       [(equal? op "*") (save-a (list (mult)))]

       [(equal? op "-") (list (gen-block "-" "1" "+" "+" 2 1))]
       [(equal? op "+") (list (gen-block "+" 2 1))]

       [(equal? op "<<") ;; x-1 for 2* unext
        (list (ift (list (gen-block "-1" "+" 1 1) 
                         (forloop (gen-block) (list (gen-block "2*" 1 1)) #f #f #f)
                         (gen-block "dup" 1 2)))
              (gen-block "drop" 1 0))]

       [(equal? op ">>") ;; x-1 for 2/ unext
        (list (ift (list (gen-block "-1" "+" 1 1) 
                         (forloop (gen-block) (list (gen-block "2/" 1 1)) #f #f #f)
                         (gen-block "dup" 1 2)))
              (gen-block "drop" 1 0))]

       [(equal? op ">>>") 
	(define-rotate
	  (list (iftf 
		 (save-a
		  (list (gen-block-a "-1" "+" "push" "push" "dup" "dup" "or" "dup" "a!" "pop" "pop" 
				     2 3)
			(forloop (gen-block) (list (gen-block-a "+*" 1 1)) #f #f #f)
			(gen-block "push" "drop" "pop" "a" 2 2)))
		 (list (gen-block "dup" "or" 1 1))
		 )))]
        

       [(equal? op "&") (list (gen-block "and" 2 1))]
       [(equal? op "^") (list (gen-block "or" 2 1))]
       [(equal? op "|") (list (gen-block "over" "-" "and" "+" 2 1))]
       ;; --u/mod: h l d - r q
       [(equal? op "/") (save-a (list (gen-block "push" "push" "0" "pop" "pop" "-" "1" "+" 2 3) 
				      (funccall "--u/mod") 
				      (gen-block "push" "drop" "pop" 2 1)))]
       [(equal? op "%") (save-a (list (gen-block "push" "push" "0" "pop" "pop" "-" "1" "+" 2 3) 
				      (funccall "--u/mod") 
				      (gen-block "drop" 1 0)))]
       [(equal? op "/%") (save-a (list (gen-block "push" "push" "0" "pop" "pop" "-" "1" "+" 2 3) 
				       (funccall "--u/mod")))]
       [(equal? op "*:2") (save-a (list (gen-block-a "a!" "0" "17" 2 3)
                                        (forloop (gen-block)
                                                 (list (gen-block "+*" 1 1)) #f #f #f)
                                        (gen-block "push" "drop" "pop" "a" 2 2)))]

       [(equal? op "*/17") (save-a (list (funccall "*.17")
					 (gen-block "push" "drop" "pop" 2 1)))]
       [(equal? op "*/16") (save-a (list (funccall "*.")
					 (gen-block "push" "drop" "pop" 2 1)))]
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

    ;;returns the port in node NODE for direction DIR
    ;;coordinates for NODE are from bottom left
    (define (port-from-node node dir)
      (let ([x (remainder node 100)]
            [y (quotient node 100)])
        (cond
         [(equal? dir `N)
          (if (= (modulo y 2) 0) "down" "up")]
         [(equal? dir `S)
          (if (= (modulo y 2) 0) "up" "down")]
         [(equal? dir `E)
          (if (= (modulo x 2) 0) "right" "left")]
         [(equal? dir `W)
          (if (= (modulo x 2) 0) "left" "right")]
         [(equal? dir `IO)
          "io"]
         [else (raise "port-from-node: invalid direction")])))

    (define (get-if-name)
      (set! if-count (add1 if-count))
      (format "~aif" if-count))

    (define (get-while-name)
      (set! while-count (add1 while-count))
      (format "~awhile" while-count))

    (define (define-if body)
      (define name (get-if-name))
      (define new-if (funcdecl name body #f))
      (set! helper-funcs (cons new-if helper-funcs))
      (list (funccall name)))

    (define (define-rotate body)
      (unless rotate
	      (set! rotate #t)
	      (set! helper-funcs (cons (funcdecl "rrotate" body #f) helper-funcs)))
      (list (funccall "rrotate")))

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

    (define (get-iter-org mem)
      (+ (meminfo-addr data-size) (meminfo-addr mem)))

    (define (drop-cond my-cond code)
      (if my-cond
          (begin
            ;(pretty-display ">>> DROP COND <<<")
            (set! cond-onstack #f)
            (prog-append (list (gen-block "drop" 1 0)) code)
            )
          code))

    (define (func-name name)
      (if (equal? (substring name 0 1) "_")
          (substring name 1)
          name))

    (define/public (visit ast)
      (cond
       [(is-a? ast VarDecl%)
        (if (string? (get-field address ast))
            (begin
              (set! n-regs (add1 n-regs))
              (list (gen-block "0" 0 1)))
            (list))]

       [(is-a? ast ArrayDecl%)
        (when debug
              (pretty-display (format "\nCODEGEN: VarDecl ~a" (get-field var ast))))
        (define init (get-field init ast))
        (when init ;(and (not virtual) init)
              (define address (get-field address ast))
              (for ([i (in-range (length init))]
                    [val init])
                   (vector-set! data (+ (meminfo-addr address) i) val)))

        (when debug
              (pretty-display (format "\nCODEGEN: VarDecl ~a (done)" (get-field var ast))))
        (list)
        ]

       [(is-a? ast Num%)
        (when debug 
              (pretty-display (format "\nCODEGEN: Num ~a" (send ast to-string))))
        (define n (get-field n (get-field n ast)))
        (when (> n maxnum)
              (set! maxnum n))
	(list (gen-block (number->string n) 0 1))]

       [(is-a? ast Array%)
        (when debug 
              (pretty-display (format "\nCODEGEN: Array ~a (1)" (send ast to-string))))
	(define index-ret (send (get-field index ast) accept this))

	(define offset (get-field offset ast))
	(define address (get-field address ast))
	(define opt (get-field opt ast))

        (define insts
          (if opt
              (list "@+")
              (let ([actual-addr (- (get-var address) offset)])
                (if (= actual-addr 0)
                    (list "b!" "@b")
                    (list (number->string actual-addr) "+" "b!" "@b")))))
        (define insts-org
          (if opt
              (list "@+")
              (let ([actual-addr-org (- (meminfo-addr address) offset)])
                (if (= actual-addr-org 0)
                    (list "b!" "@b")
                    (list (number->string actual-addr-org) "+" "b!" "@b")))))

        (define array-ret
          (list (gen-block-list insts insts-org 1 1)))

        
        (define ret
          (if opt
              array-ret
              (prog-append index-ret array-ret)))

        ;; (when debug 
        ;;       (pretty-display (format "\nCODEGEN: Array ~a (2) opt = ~a" 
        ;;                               (send ast to-string) opt))
        ;;       (aforth-struct-print ret)
        ;;       )
        ret
        ]

       [(is-a? ast Var%)
	(define address (get-field address ast))
        (when debug 
              (pretty-display (format "\nCODEGEN: Var ~a, address = ~a" 
                                      (send ast to-string) address)))

        (cond
         [(equal? address 't)
          (list (gen-block "dup" 0 1))]
         [(equal? address 's)
          (list (gen-block "over" 0 1))]
         [(not address)
          ;; already on stack
          (list)]
         [(meminfo-data address)
          ;; data
          (list (gen-block-org 
                 ((number->string (get-var address)) "b!" "@b")
                 ((number->string (meminfo-addr address)) "b!" "@b")
                 0 1))]
         [else
          ;; iter
          (list (gen-block-org 
                 ((number->string (get-iter address)) "b!" "@b")
                 ((number->string (get-iter-org address)) "b!" "@b")
                 0 1))])]

       [(is-a? ast UnaExp%)
        (when debug 
              (pretty-display (format "\nCODEGEN: UnaExp ~a" (send ast to-string))))
	(define e1-ret (send (get-field e1 ast) accept this))
	(define op (get-field op (get-field op ast)))

        (define op-ret
          (cond
           [(equal? op "-")
            (list (gen-block "-" "1" "+" 1 1))]
           [(equal? op "~")
            (list (gen-block "-" 1 1))]
           [else
            (raise (format "visitor-codegen: do not support unary-op ~a at line ~a"
                           op (send ast get-line)))]))

	(prog-append e1-ret op-ret)]

       [(and (is-a? ast BinExp%) 
             (member (get-field op (get-field op ast)) (list ">>" "<<"))
             (is-a? (get-field e2 ast) Num%)
             (< (get-field n (get-field n (get-field e2 ast))) 18))
        (when debug 
              (pretty-display (format "\nCODEGEN: BinExp Special ~a" (send ast to-string))))

        (define op (get-field op (get-field op ast)))
	(define e1-ret (send (get-field e1 ast) accept this))
        (define e2-n (get-field n (get-field n (get-field e2 ast))))
        
        (define shift (for/list ([i (in-range e2-n)]) (if (equal? op ">>") "2/" "2*")))

        (prog-append e1-ret (list (gen-block-list shift shift 1 1)))]

       [(is-a? ast BinExp%)
        (when debug 
              (pretty-display (format "\nCODEGEN: BinExp ~a" (send ast to-string))))

        (define op (get-field op (get-field op ast)))
	(define e1-ret (send (get-field e1 ast) accept this))
	(define e2-ret (send (get-field e2 ast) accept this))
        ;; (when debug 
        ;;       (pretty-display (format "\nCODEGEN: BinExp ~a (return)" 
        ;;                               (send ast to-string)))
        ;;       (aforth-struct-print (prog-append e1-ret e2-ret (gen-op op))))
	(prog-append e1-ret e2-ret (gen-op op))
        ]

       [(is-a? ast Recv%)
        (when debug 
              (pretty-display (format "\nCODEGEN: Recv ~a" (get-field port ast))))
        (define port (gen-port (get-field port ast)))
        (list (gen-block-in port "b!" "@b" 0 1 port))]

       [(is-a? ast Send%)
        (define my-cond cond-onstack)
        (define data (get-field data ast))
        (define send-cond (and (is-a? data Temp%) (equal? (get-field name data) "_cond")))
        (unless send-cond
                (set! cond-onstack #f))

        (when debug 
              (pretty-display (format "\nCODEGEN: Send ~a ~a" (get-field port ast) data)))
	(define data-ret (send data accept this))
        (define temp-ret
          (if send-cond
              (list (gen-block "dup" 1 2))
              (list (gen-block))))
        (define port (gen-port (get-field port ast)))
	(define send-ret (list (gen-block-in port "b!" "!b" 1 0 port)))

        (drop-cond (and (not send-cond) my-cond) (prog-append data-ret temp-ret send-ret))]

       [(and (is-a? ast FuncCall%)
	     (regexp-match #rx"digital_write" (get-field name ast)))
	(let* ([args (for/list ([arg (reverse (get-field args ast))])
		       (send arg get-value))]
	       [n-pins (length args)]
	       [io 0])
	  (when (= n-pins 4) ;;pin 4, bit 5
	    (set! io (arithmetic-shift (car args) 4))
	    (set! args (cdr args)))
	  (when (>= n-pins 3) ;;pin 3, bit 3
	    (set! io (bitwise-ior io (arithmetic-shift (car args) 2)))
	    (set! args (cdr args)))
	  (when (>= n-pins 2) ;;pin 2, bit 1
	    (set! io (bitwise-ior io (car args)))
	    (set! args (cdr args)))
	  (when (>= n-pins 1);; pin 1, bit 17
	    (set! io (bitwise-ior io (arithmetic-shift (car args) 16))))
	  (list (gen-block "io" "b!" (number->string io) "!b" 0 0)))]

       [(and (is-a? ast FuncCall%)
       	     (regexp-match #rx"digital_read" (get-field name ast)))
        (let* ([pin (send (car (get-field args ast)) get-value)]
       	       [mask (vector-ref (vector #x20000 #x2 #x4 #x20) pin)])
       	  (list (gen-block "io" "b!" "@b" (number->string mask) "and" 0 1)))]

       [(and (is-a? ast FuncCall%)
             (regexp-match #rx"digital_wakeup" (get-field name ast)))

        (let* ([state (send (car (get-field args ast)) get-value)]
               [io (number->string (if (= (modulo state 2) 1) 0 #x800))]
               [node (get-field fixed-node ast)]
               [port (if (or (> node 700) (< node 17)) "up" "left")])
          (if (member node digital-nodes)
              (list (gen-block "io" "b!" io "!b" port "!b" "@b" "drop" 0 0))
              (list (gen-block "io" "b!" io "!b" port "!b" "dup" "!b"  0 0))))]

       [(and (is-a? ast FuncCall%)
	     (regexp-match #rx"delay_ns" (get-field name ast)))
	(let* ([args (get-field args ast)]
	       [ns (send (car args) get-value)]
	       [volts (send (cadr args) get-value)]
	       ;; execution time at x volts relative to 1.8v at any temperature
	       ;; from DB002 page20
	       ;;   t = -0.6775*x^3 + 4.2904*x^2 - 9.4878*x + 8.1287
	       ;;typical empty micronext time is 2.4ns at 1.8v, 22deg Celsius
	       [unext-time (* 2.4 (+ (* -0.6775 volts volts volts)
				     (* 4.2904 volts volts)
				     (* -9.4878 volts)
				     8.1287))]
	       [iter (inexact->exact (floor (/ ns unext-time)))])
	  (list (gen-block (number->string iter) "for" "unext" 0 0)))]
       [(and (is-a? ast FuncCall%)
             (regexp-match #rx"delay_unext" (get-field name ast)))
        (list (forloop (send (car (get-field args ast)) accept this)
                       (list (gen-block)) #f #f #f))]

       [(is-a? ast FuncCall%)
        (define my-cond cond-onstack)
        (set! cond-onstack #f)

        (when debug 
              (pretty-display (format "\nCODEGEN: FuncCall ~a" (send ast to-string))))
        (define name (func-name (get-field name ast)))
        (define arg-code 
          (foldl (lambda (x all) (prog-append all (send x accept this)))
                 (list) (get-field args ast)))
        (define call-code
          (if (car const-a)
              (list (gen-block-r "a" "push" 0 0)
                    (funccall name)
                    (gen-block "pop" "a!" 0 0))
              (list (funccall name))))

        (drop-cond my-cond (prog-append arg-code call-code))
        ]

       [(is-a? ast Assign%)
        (define my-cond cond-onstack)
        (set! cond-onstack #f)

	(define lhs (get-field lhs ast))
	(define rhs (get-field rhs ast))
        (when (equal? (get-field name lhs) "_cond")
              (set! cond-onstack #t))
        (when debug 
              (pretty-display (format "\nCODEGEN: Assign ~a = ~a" 
				      (send lhs to-string) (send rhs to-string))))
	(define address (get-field address lhs))
	;(pretty-display `(address ,address))
        (define ret
	(if (is-a? lhs Array%)
	    (let* ([index-ret (send (get-field index lhs) accept this)]
		   [offset    (get-field offset lhs)]
		   [rhs-ret     (send rhs accept this)]
                   [actual-addr (- (get-var address) offset)]
                   [actual-addr-org (- (meminfo-addr address) offset)]
		   [opt (get-field opt lhs)]
                   [insts 
                    (if opt
                        (list "!+")
                        (if (= actual-addr 0)
                            (list "b!" "!b")
                            (list (number->string actual-addr) "+" "b!" "!b")))]
                   [insts-org 
                    (if opt
                        (list "!+")
                        (if (= actual-addr-org 0)
                            (list "b!" "!b")
                            (list (number->string actual-addr-org) "+" "b!" "!b")))])
              (if opt
                  (prog-append rhs-ret (list (gen-block-list insts insts-org 1 0)))
                  (prog-append rhs-ret index-ret (list (gen-block-list insts insts-org 2 0)))))
	    (let ([rhs-ret (send rhs accept this)])
		  (prog-append
		   rhs-ret
                   (cond
                    [(equal? address 't)
                     (list (gen-block "push" "drop" "pop" 2 1))]
                    [(not address)
                     ;; temp on stack
                     (list)]
                    [(meminfo-data address)
                     ;; data
                     (if (pair? (get-field type lhs))
                         ;; need to expand
                         (list 
                          (gen-block-store (number->string (get-var address))
                                           (number->string (meminfo-addr address))
                                           (cdr (get-field type lhs))))
                         (list
                          (gen-block-store (number->string (get-var address))
                                           (number->string (meminfo-addr address))
                                           1)))]
                    [else
                     ;; iter
                     (list (gen-block-org
                            ((number->string (get-iter address)) "b!" "!b")
                            ((number->string (get-iter-org address)) "b!" "!b")
                            1 0))
                     ])))))
        (drop-cond my-cond ret)
        ]

       [(is-a? ast Return%)
        (define my-cond cond-onstack)
        (set! cond-onstack #f)

        (when debug 
              (pretty-display (format "\nCODEGEN: Return")))

        (define val (get-field val ast))
        (define entries (if (list? val) (length val) 1))
	(define ret
	  (if (list? val)
	      (foldl (lambda (v all) (prog-append all (send v accept this)))
		     (list) val)
	      (send (get-field val ast) accept this)))

        (define drops (append (for/list ([i (in-range entries)]) "push")
                              (list "drop")
                              (for/list ([i (in-range entries)]) "pop")))

        (define drop-ret (list (if (= n-regs 1)
                                   (gen-block-list drops drops (add1 entries) entries)
                                   (gen-block))))

        (if (empty? ret)
            (set! ret drop-ret)
            (set! ret (prog-append ret drop-ret)))

        (for ([b ret])
             (set-restrict-mem! (block-cnstr b) #f))

        (drop-cond my-cond ret)
	]

       [(is-a? ast If%)
	;; not yet support && ||
        (when debug 
              (pretty-display (format "\nCODEGEN: If"))
	      )
        (set! in-pre #t)
        (define pre-ret 
	  (if (get-field pre ast)
	      (send (get-field pre ast) accept this)
	      (list (gen-block))))
        (set! in-pre #f)
	  
	(codegen-print pre-ret)
        (define cond-ret (send (get-field condition ast) accept this))
        (set! cond-onstack #f)
        (define true-ret (prog-append (list (gen-block "drop" 1 0))
                                      (send (get-field true-block ast) accept this)))
        (define false-ret 
          (if (get-field false-block ast)
              (prog-append (list (gen-block "drop" 1 0))
                           (send (get-field false-block ast) accept this))
              #f))

        (cond
         [(is-a? ast If!=0%)
          (if false-ret
              (define-if (prog-append pre-ret cond-ret (list (iftf true-ret false-ret))))
              (prog-append pre-ret cond-ret (list (ift true-ret))))
          ]

         [(is-a? ast If<0%)
          (if false-ret
              (define-if (prog-append pre-ret cond-ret (list (-iftf true-ret false-ret))))
              (prog-append pre-ret cond-ret (list (-ift true-ret))))
          ]

         [else
          (if false-ret
              (define-if (prog-append pre-ret cond-ret (list (iftf true-ret false-ret))))
              (prog-append pre-ret cond-ret (list (ift true-ret))))])]

       [(and (is-a? ast While%)
             (is-a? (get-field condition ast) Num%))
        (if (= (send (get-field condition ast) get-value) 0)
            (list)
            (let* ([exp (get-field condition ast)]
                   [name (get-while-name)]
                   [body (get-field body ast)]
                   [block (new Block%
                               [stmts (append (get-field stmts body)
                                              (list (new FuncCall%
                                                         [name name]
                                                         [args (list)])))])])
              (set! helper-funcs (cons (funcdecl name (send block accept this) #f)
                                       helper-funcs))
              (list (funccall name))))]

       [(is-a? ast While%)
	(define pre (get-field pre ast))
        (when debug 
              (pretty-display (format "\nCODEGEN: While"))
	      (pretty-display ">>> pre")
	      (send pre pretty-print)
	      (pretty-display "<<<")
	      )
	(define exp (get-field condition ast))
	(define name (get-while-name))
	(define body (get-field body ast))
	(define block (new Block% [stmts (append (get-field stmts body)
						 (list (new FuncCall% [name name] [args (list)])))]))
        (define empty-block (new Block% [stmts (list)]))

	;; desugar into if construct
	;; set name = while-name
	(define if-rep
	  (cond
	   [(is-a? ast While!=0%) 
	    (new If!=0% [pre pre] [condition exp] 
                 [true-block block] [false-block empty-block])]

	   [(is-a? ast While==0%)
	    (new If!=0% [pre pre] [condition exp] 
		 [true-block empty-block] [false-block block])]

	   [(is-a? ast While<0%)
	    (new If<0% [pre pre] [condition exp] 
                 [true-block block] [false-block empty-block])]
	    
	   [(is-a? ast While>=0%) 
	    (new If<0% [pre pre] [condition exp] 
		 [true-block empty-block] [false-block block])]

	   [else
	    (new If% [pre pre] [condition exp] 
                 [true-block block] [false-block empty-block])]))
	
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
        (define my-cond cond-onstack)
        (set! cond-onstack #f)

	(define array (get-field iter-type ast))

        (define from (get-field from ast))
        (define to (get-field to ast))
        (define addr-pair #f)
        
        ;; if no arrayaccess => no need to initialize
        (define init-ret
          (cond
           [(equal? array 0)
	    ;; same restriction on a
	    (set! const-a (cons (car const-a) const-a))
	    (set! addr-pair (cons #f #f))
            (gen-block (number->string (- to from 1)) 0 1)
            ]
           
           [(is-a? array Array%)
	    ;; constraint a
	    (set! const-a (cons #t const-a))
            (define offset (get-field offset array))
            (define address (get-field address array))
            (define actual-addr (- (get-var address) offset))
            (define actual-addr-org (- (meminfo-addr address) offset))
	    (set! addr-pair (cons (cons (number->string actual-addr) `opt)
				  (cons (number->string actual-addr-org) `opt)))
            (gen-block-org
             ((number->string (+ actual-addr from)) "a!" (number->string (- to from 1)))
             ((number->string (+ actual-addr-org from)) "a!" (number->string (- to from 1)))
             0 1)
            ]

           [else
	    ;; same restriction on a
            (define address (get-iter (get-field address ast)))
            (define address-str (number->string address))
            (define address-org (get-iter-org (get-field address ast)))
            (define address-org-str (number->string address-org))

	    (set! const-a (cons (car const-a) const-a))
	    (set! addr-pair (cons address-str address-org-str))
            (gen-block-org
             ((number->string from) address-str 
              "b!" "!b" (number->string (- to from 1)))
             ((number->string from) address-org-str
              "b!" "!b" (number->string (- to from 1)))
             0 1)
            ])) ;; loop bound
         
        (define body-ret (send (get-field body ast) accept this))
	;; pop restriction on a
	(set! const-a (cdr const-a))

        (define body-decor 
          (list (if (or (equal? array 0) (is-a? array Array%))
                    (gen-block)
                    (let* ([address (get-iter (get-field address ast))]
                           [address-str (number->string address)]
                           [address-org (get-iter-org (get-field address ast))]
                           [address-org-str (number->string address-org)])
                      (gen-block-org 
                       (address-str "b!" "@b" "1" "+" "!b")
                       (address-org-str "b!" "@b" "1" "+" "!b")
                       0 0)))))

        (drop-cond my-cond
                   (list (forloop init-ret (prog-append body-ret body-decor) 
                                  addr-pair from to)))
	]

       [(is-a? ast FuncDecl%)
	(when debug 
	      (pretty-display (format "\nCODEGEN: FuncDecl ~a" (get-field name ast))))

	(define decls (get-field stmts (get-field args ast)))
        (define name (func-name (get-field name ast)))
        
	(when debug
	      (pretty-display "ARGS:")
	      (for ([decl decls])
		   (pretty-display (format "~a ==> ~a" 
					   (get-field var-list decl) (get-field address decl)))))

	(define n-decls (length decls))

        (define mem-decls (filter (lambda (x) (meminfo? (get-field address x))) decls))
        (define n-mem-decls (length mem-decls))
        (set! n-regs (- n-decls n-mem-decls))
        (when (> n-regs 1)
              (raise "visitor-codegen: only support one variable on return stack"))

        ;; args
        (define args-ret
          (cond
           [(> n-mem-decls 0)
            (let* ([address (get-field address (last mem-decls))]
                   [code (append (list (number->string (get-var address)) "a!")
                                 (for/list ([decl (reverse decls)])
                                           (if (meminfo? (get-field address decl))
                                               "!+" "push"))
                                 (if (= n-regs 1) (list "pop") (list))
                                 )])
              (list (gen-block-list code code n-decls n-regs)))]
           
           [else
            (list (gen-block))]))
        
        ;; body
	(define body-ret (send (get-field body ast) accept this))

        ;; return
        (define return-ret
          (let ([b (if (or (= n-regs 0) 
                           ;; there is nothing to drop.
                           (get-field return ast) 
                           ;; if it not void, return% clears the return stack.
                           (equal? name "main")
                           ;; if main, just leave thing on stack.
                           )
                       (gen-block)
                       (gen-block "drop" 1 0))])
            ;; TODO: is setting memomy constraint to false in main too aggressive?
            (set-restrict-mem! (block-cnstr b) #f)
            (list b)))

        (define precond
          (and (get-field simple ast)
               (map (lambda (param) 
                      (let ([assume (get-field assume param)])
                        (and assume (cons (get-field op (get-field op assume))
                                          (send (get-field e2 assume) get-value)))))
                    decls)))
        
        (funcdecl name (prog-append args-ret body-ret return-ret) precond)]

       [(is-a? ast Program%)
        (when debug 
              (pretty-display (format "\nCODEGEN: Program")))

        (if (empty? (get-field stmts ast))
            #f
            
            ;; return list of function list
            (let ([main-funcs
                   (for/list ([decl (filter (lambda (x) (is-a? x FuncDecl%)) 
                                            (get-field stmts ast))])
                             (send decl accept this))])
              
              (dict-set! index-map 
                         (+ (meminfo-virtual data-size) iter-size)
                         (+ (meminfo-addr data-size) iter-size))
              (aforth (append (list (vardecl (vector->list data))) 
                              (reverse helper-funcs) 
                              main-funcs) 
                      (+ (get-var data-size) iter-size) 
		      18
                      ;(max (inexact->exact (floor (+ (/ (log maxnum) (log 2)) 2))) ga-bit)
                      (if virtual index-map #f))))
        ]

       [(is-a? ast Block%)
        (define ret
          (foldl (lambda (stmt all) (prog-append all (send stmt accept this)))
                 (list) (get-field stmts ast)))
        (if (and cond-onstack (not in-pre))
            (begin
              (set! cond-onstack #f)
              (prog-append ret (list (gen-block "drop" 1 0)))
              )
            ret)
        ]

       [else
	(raise (format "visitor-codegen: unimplemented for ~a" ast))]

       ))))
