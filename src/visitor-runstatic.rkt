#lang s-exp rosette

(require "header.rkt"
         "ast.rkt" 
         "ast-util.rkt"
         "parser.rkt"
         "visitor-interface.rkt")

(provide static-runner%)

(define static-runner%
  (class* object% (visitor<%>)
    (super-new)
    (init-field [env (make-hash)] ;; map varname -> (type, value)
                )

    (define debug #f)
    (declare env "__globalinputsrc__" 
             (new ConcreteFilterDecl% [name "__globalinputsrc__"]
                  [args (new Block% [stmts (list)])]
                  [arg-values (list)]
                  [body (new Block% [stmts (list)])]
                  [abstract (void)]
                  [input (void)]
                  [output (new VarDecl% [var-list (list "#output")]
                               [type "int"] ;; TODO: make it generic
                               [place (new Place% [at "io"])]
                               [known #f])]))
    (declare env "__globaloutputdst__"
             (new ConcreteFilterDecl% [name "__globaloutputdst__"]
                  [args (new Block% [stmts (list)])]
                  [arg-values (list)]
                  [body (new Block% [stmts (list)])]
                  [abstract (void)]
                  [input (void)]
                  [output (new VarDecl% [var-list (list "#output")]
                               [type "int"] ;; TODO: make it generic
                               [place (new Place% [at "io"])]
                               [known #f])]))
    (declare env "__previous__" (lookup-name env "__globalinputsrc__"))
    
    ;; IO functions are not available in static code
                 
    (define (push-scope)
      ;(pretty-display `(push-scope))
      (let ([new-env (make-hash)])
        (dict-set! new-env "__up__" env)
        (set! env new-env)))

    (define (pop-scope)
      ;(pretty-display `(pop-scope))
      (set! env (dict-ref env "__up__")))
    
    (define/public (visit ast)
      (cond
       [(is-a? ast Const%) (cons "int" (get-field n ast))]
       [(is-a? ast Num%) (get-field n ast)]

       [(is-a? ast Op%)
        (case (get-field op ast)
          ;; TODO: Type checks (are they even necessary? Ask Mangpo)
          [("+") (λ (v1 v2) (cons "int" (+ (cdr v1) (cdr v2))))]
          [("-") (λ (v1 v2) (cons "int" (- (cdr v1) (cdr v2))))]
          ;; ...
          )]

       [(is-a? ast Array%)
        (raise "visitor-runstatic: arrays not supported yet. TODO!")]

       [(is-a? ast Var%)
        (lookup env ast)]

       [(is-a? ast UnaExp%)
        (define e1 (get-field e1 ast))
        (define op (get-field op ast))
        
        (define v1 (send e1 accept this))
        (define op-func (send op accept this))
        
        (op-func v1)]
       
       [(is-a? ast BinExp%)
        (define e1 (get-field e1 ast))
        (define e2 (get-field e2 ast))
        (define op (get-field op ast))
        
        (define v1 (send e1 accept this))
        (define v2 (send e2 accept this))
        (define op-func (send op accept this))
        
        (op-func v1 v2)]

       [(is-a? ast VarDecl%)
        (define type (car (get-field place-type ast)))
        (define var-list (get-field var-list ast))
        
        ;; put vars into env
        (for ([var var-list])
          (declare env var (cons type (void))))
        
        (void)]

       [(is-a? ast ArrayDecl%)
        (raise "visitor-runstatic: arrays not supported yet. TODO!")]

       [(is-a? ast For%)
        (raise "visitor-runstatic: for loops not supported yet. TODO!")]

       [(is-a? ast If%)
        (raise "visitor-runstatic: if statements not supported yet. TODO!")]

       [(is-a? ast While%)
        (raise "visitor-runstatic: while loops not supported yet. TODO!")]

       [(is-a? ast Assign%)
        (define lhs (get-field lhs ast))
        (define rhs (get-field rhs ast))
        
        (define var (send lhs accept this))
        (define value (send rhs accept this))
        (update env var value)
        
        (void)]

       [(is-a? ast Return%)
        (raise "visitor-runstatic: return not supported yet. TODO!")]

       [(is-a? ast Program%)
        (define stmts (get-field stmts ast))
        
        ;; update env front to back
        (for ([stmt stmts])
          (when (is-a? stmt CallableDecl%)
              (declare env (get-field name stmt) stmt)))
        
        ;; run Main()
        (define main
          (first (filter (λ (stmt) (and (is-a? stmt StaticCallableDecl%)
                                        (equal? (get-field name stmt) "Main")))
                         stmts)))
        (define filters (send main accept this))
        
        ;; remove abstract filter and static declarations from program
        (set! stmts
              (filter (λ (stmt)
                        (not (or (is-a? stmt AbstractFilterDecl%)
                                 (is-a? stmt StaticCallableDecl%))))
                      stmts))
        (set-field! stmts ast stmts)
        
        ;; add concrete filter declarations
        (set! stmts (append stmts filters))
        (set-field! stmts ast stmts)
        
	(void)]

       [(is-a? ast Block%) 
        (flatten (for/list ([stmt (get-field stmts ast)])
          (send stmt accept this)))]

       [(is-a? ast PipelineDecl%)
        (pretty-display (format "RUNSTATIC: PipelineDecl ~a" ast))
        (push-scope)
        (define filters (send (get-field body ast) accept this))
        (set-field! output-dst (last filters) (lookup-name env "__globaloutputdst__"))
        (set-field! input-src (lookup-name env "__globaloutputdst__") (last filters))
        (pop-scope)
        filters
        ]
       
       [(is-a? ast Add%)
        (pretty-display (format "RUNSTATIC: Add ~a" ast))
        (define call (get-field call ast))
        (define decl (get-field signature call))
        (define arg-values (map (λ (exp) (send exp accept this))
                                (get-field args call)))
        
        (define filters
          (cond
            [(is-a? decl AbstractFilterDecl%)
             (define filter (new ConcreteFilterDecl%
                                 [abstract decl]
                                 [arg-values arg-values]
                                 ;;
                                 [name (get-field name decl)]
                                 [input (get-field input decl)]
                                 [output (get-field output decl)]
                                 [args (get-field args decl)]
                                 [body (get-field body decl)]
                                 ))
             (list filter)]
            [(is-a? decl FuncDecl%)
             (raise (format "visitor-runstatic: tried to add function as a stream in ~a" ast))]
            [else (raise (format "visitor-runstatic: unimplemented add call to ~a" decl))]
            ))
        
        (set-field! output-dst (lookup-name env "__previous__") (first filters))
        (set-field! input-src (first filters) (lookup-name env "__previous__"))
        (update-name env "__previous__" (last filters))
        
        filters
        ]
       
       [(is-a? ast FuncDecl%)
        (raise "visitor-runstatic: function declarations not supported yet. TODO!")]
       
       [(is-a? ast FuncCall%)
        (raise "visitor-runstatic: function calls inside static code is not supported yet, TODO!")]
       
       [else (raise (format "visitor-runstatic: unimplemented for ~a" ast))]))
))
