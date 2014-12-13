#lang racket

(require "header.rkt"
         "ast.rkt" "ast-util.rkt" "visitor-interface.rkt")

(provide (all-defined-out))

;; Insert temp for a function call whose return type is a tuple 
;; that is NOT an argument to another function.
(define temp-inserter%
  (class* object% (visitor<%>)
    (super-new)
    (init-field [count 0] [new-decls (list)])
    (define replace #f)
    (define debug #f)

    (struct entry (temp type expand))

    (define (push-scope)
      (set! new-decls (cons (list) new-decls)))

    (define (pop-scope)
      (define ret (car new-decls))
      (set! new-decls (cdr new-decls))
      ret)

    (define (add-decl x)
      (set! new-decls (cons (cons x (car new-decls))
                            (cdr new-decls))))

    (define (get-temp type expand expect place-type compact)
      (let* ([temp (format "_temp_~a" count)]
	     [temp-decl (if (> expand 1)
			    ;; no expansion in desugar step
			    (new TempDecl% [var-list (list temp)]
				 [type (cons type expand)] ; packed type
				 [place place-type] 
				 [expect expand]
                                 [compact compact]) 
			    (new TempDecl% [var-list (list temp)]
				 [type type] ; native type
				 [place place-type] 
				 [expect expand]
                                 [compact compact]))])
	
        (set! count (add1 count))
        (add-decl temp-decl)
        
        ;; temp for funccall:
        ;; let func() -> int::2
        ;; temp = func() 
        ;; type(temp) = (cons int 2)
        ;; expect(temp) = 1

        ;; don't set known-type
        (let* ([tmp1 (new Temp% [name temp] [type type] [expand expand] [expect expand] 
                          [place-type place-type] [compact compact])]
               [tmp2 (new Temp% [name temp] [type type] [expand expand] [expect expect]
                          [place-type place-type] [compact compact])])
        (values tmp1 tmp2))))

    (define/public (visit ast)

      (cond
        [(or (is-a? ast Num%)
             (is-a? ast Var%))
         (when debug (pretty-display (format "TEMPINSERT: ~a" (send ast to-string))))
         (cons (list) ast)
	 ]
        
        [(is-a? ast UnaExp%)
         (when debug (pretty-display (format "TEMPINSERT: ~a" (send ast to-string))))
         (set! replace #f)
         (define e1-ret (send (get-field e1 ast) accept this))
         (cons (car e1-ret) ast)
	 ]
        
        [(is-a? ast BinExp%)
         (when debug (pretty-display (format "TEMPINSERT: ~a" (send ast to-string))))
         (set! replace #f)
         (define e1-ret (send (get-field e1 ast) accept this))
         (set! replace #f)
         (define e2-ret (send (get-field e2 ast) accept this))
         (set-field! e1 ast (cdr e1-ret))
         (set-field! e2 ast (cdr e2-ret))

         (define place (get-field place (get-field op ast)))
         (if (member (get-field op (get-field op ast)) (list "/%" "*:2" ">>:2" ">>>"))
             (let-values 
                 ([(tmp1 tmp2) 
                   (get-temp "int" 2 2 (new TypeExpansion%
                                            [place-list (list place place)])
                             #t)])
               ;; send expect = 1 so that it doesn't get expanded in desugarin step
               (set-field! expect tmp1 1)
               (let ([stmt1 (new AssignTemp% [lhs tmp1] [rhs ast])])
                 (cons (append (car e1-ret) (car e1-ret) (list stmt1)) tmp2)))
             (cons (append (car e1-ret) (car e2-ret)) ast))
         ]
        
        [(is-a? ast FuncCall%)
         (when debug (pretty-display (format "TEMPINSERT: FuncCall ~a" (send ast to-string))))
	 (define (tempify arg param)
	   (set! replace #t)
	   (pretty-display (format "  param:~a" (get-field var-list param)))
	   (send arg accept this))

         ;; my-arg is ture if this funcall is an argument to another funccall.
	 (define my-arg replace)
         (define signature (get-field signature ast))
         (define return-place (and (get-field return signature)
                                   (get-field place (get-field return signature))))
	 (define params (get-field stmts (get-field args (get-field signature ast))))
	 (define tempified (map tempify (get-field args ast) params))
         (define new-stmts (map car tempified))
         (define new-args  (map cdr tempified))
         (set-field! args ast new-args)

         ;; mark to inc-space in visitor-interpreter
         (define expanded-return (typeexpansion->list return-place))
         (set-field! place-type ast expanded-return)
         (when (and my-arg (is-a? return-place TypeExpansion%))
               (set-field! might-need-storage ast #t))

         ;; only insert temp for function call that is not an argument of another
         ;; function call AND return type is a tuple type.
         (if (get-field is-stmt ast)
             (list new-stmts ast)
             (if (and (not my-arg) 
                      (is-a? return-place TypeExpansion%))
                 ;; return (list of stmts . ast)
                 (let-values 
                     ([(tmp1 tmp2) 
                       (get-temp
                        (get-field type ast) 
                        (get-field expand ast)
                        (get-field expect ast)
                        return-place
                        #t)])
                   ;; send expect = 1 so that it doesn't get expanded in desugaring step
                   (set-field! expect tmp1 1)
                   (let ([stmt1 (new AssignTemp% [lhs tmp1] [rhs ast])])
                     (cons (list new-stmts stmt1) tmp2)))
                 ;; return list of stmts
                 (cons new-stmts ast)))]
               

	[(is-a? ast Recv%)
         (cons (list) ast)
	 ]

	[(is-a? ast Send%)
	 (set! replace #f)
	 (define data-ret (send (get-field data ast) accept this))
	 (set-field! data ast (cdr data-ret))
	 (list (car data-ret) ast)]
        
        [(or (is-a? ast VarDecl%)
             (is-a? ast ArrayDecl%))
         ast]
        
        [(is-a? ast Assign%)
         (when debug (pretty-display (format "TEMPINSERT: Assign")))
         ;; No need to add temp in the case the return value of the function
         ;; will be store in an variable.
	 (set! replace #f)
         (define lhs-ret (send (get-field lhs ast) accept this))
	 (set! replace #f)
         (define rhs-ret (send (get-field rhs ast) accept this))
         
         (set-field! lhs ast (cdr lhs-ret))
         (set-field! rhs ast (cdr rhs-ret))
         
         (list (car lhs-ret) (car rhs-ret) ast)]

	[(is-a? ast Return%)
	 (set! replace #f)
         (define val-ret (send (get-field val ast) accept this))
         (set-field! val ast (cdr val-ret))
         (list (car val-ret) ast)]
        
        [(is-a? ast If%)
	 (set! replace #f)
         (define cond-ret (send (get-field condition ast) accept this))
         (send (get-field true-block ast) accept this)
         (let ([false-block (get-field false-block ast)])
           (when false-block
             (send false-block accept this)))
         
         (set-field! condition ast (cdr cond-ret))
         
         (list (car cond-ret) ast)]
        
        [(is-a? ast While%)
	 (set! replace #f)
         (define cond-ret (send (get-field condition ast) accept this))
         (send (get-field body ast) accept this)
         
	 (set-field! stmts (get-field pre ast) (flatten (car cond-ret)))
         (set-field! condition ast (cdr cond-ret))
         (list ast)]
        
        [(is-a? ast For%)
         (push-scope)
         (define body (get-field body ast))
         (send body accept this)
         (define decls (pop-scope))
         (set-field! stmts body (append decls (get-field stmts body)))
         ast]
        
        [(is-a? ast FuncDecl%)
         (when debug (pretty-display (format "TEMPINSERT: FuncDecl ~a" 
                                             (get-field name ast))))
         (push-scope)
         (define body (get-field body ast))
         (send body accept this)
         (define decls (pop-scope))
         (set-field! stmts body (append decls (get-field stmts body)))
         ast]
        
        [(is-a? ast Block%)
         (set-field! stmts ast
                     (flatten (map (lambda (x) (send x accept this))
                                   (get-field stmts ast))))
         

         ast
         ]
        
        [else
         (raise (format "visitor-tempinsert: unimplemented for ~a" ast))]
        
        ))))

       
