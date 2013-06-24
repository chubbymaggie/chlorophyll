#lang s-exp rosette

(require racket/class)
(require parser-tools/lex
         (prefix-in re- parser-tools/lex-sre)
         parser-tools/yacc)

(require "header.rkt"
         "visitor-interface.rkt")

(provide (except-out (all-defined-out) inc))

;;;;;;;;;;;;;;;;;;;;;;;;;; Helper Functions ;;;;;;;;;;;;;;;;;;;;;;;;

(define (get-sym)
  (define-symbolic* sym-place number?)
  sym-place)

(define (inc space)
  (string-append space "  "))

(define (at-any? x)
  (or (equal? x #f) (and (is-a? x Place%) (equal? (get-field at x) "any"))))

(define (at-io? x)
  (and (is-a? x Place%) (equal? (get-field at x) "io")))

(define (place-type? p)
  (or (number? p) (place-type-dist? p)))

(define (place-type-dist? p)
  (and (pair? p) (and (and (list? (car p)) (is-a? (cdr p) Base%)))))

;; list -> string
(define (list-to-string items [core #f])
  (if (empty? items)
      ""
      (foldl (lambda (item str) 
	       (if core (format "~a, ~a_~a" str item core) (format "~a, ~a" str item)))
	     (if core
		 (format "~a_~a" (car items) core)
		 (format "~a" (car items)))
	     (cdr items))))

;; ast-list -> string
(define (ast-list-to-string ast-list)
  (if (empty? ast-list)
      ""
      (foldl (lambda (ast str) (string-append (string-append str ", ") (send ast to-string))) 
	     (send (car ast-list) to-string) 
	     (cdr ast-list))))

;; place-list -> string
(define (place-list-to-string place-list [out #f])
  (foldl (lambda (p str) (string-append (string-append str ", ") (send p to-string out))) 
         (send (car place-list) to-string out) 
         (cdr place-list)))

;; place-type, place-list -> string
(define (place-to-string place [out #t])
  (cond
   [(is-a? place Place%)
    (send place to-string)]

   [(list? place)
    (format "{~a}" (place-list-to-string place out))]

   [(pair? place)
    (format "{~a; ~a}" 
            (place-list-to-string (car place) out) 
            (send (cdr place) to-string))]

   [(is-a? place TypeExpansion%)
    (let ([place-list (get-field place-list place)])
      (format "(~a)"
              (foldl (lambda (p str) (format "~a, ~a" str (place-to-string p)))
                     (place-to-string (car place-list))
                     (cdr place-list))))]

   [else
    (let ([p (evaluate-with-sol place)])
      (if (and out (symbolic? p)) "??" p))]
   ))

;; path-list -> string
(define (path-list-to-string place-list [out #f])
  (foldl (lambda (p str) (string-append (string-append str ", ") 
                                        (send p path-to-string)))
         (send (car place-list) path-to-string) 
         (cdr place-list)))

(define (send-path-to-string path)
  (cond
   [(place-type-dist? path)
    (format "{~a; ~a}" 
            (path-list-to-string (car path)) 
            (send (cdr path) to-string))]

   [(list? path)
    path]

   [else
    (raise (format "send-path-to-string: unimplemented for ~a" path))]))

;; evaluate place
(define (concrete-place place)
  ;; (define (all-equal? ref l)
  ;;   (andmap (lambda (x) (= (get-field place x) ref)) l))

  ;; (define (compress p)
  ;;   (let ([ref (get-field place (car p))])
  ;;     (if (all-equal? ref (cdr p))
  ;; 	  ref
  ;; 	  p)))

  (define (compress p)
    (define (compress-inner l)
      (if (empty? (cdr l))
	  l
	  (let ([first (car l)]
		[rest (compress-inner (cdr l))])
	  (if (= (get-field place first) (get-field place (car rest)))
	      (begin
		;; merge
		(set-field! from (car rest) (get-field from first))
		rest)
	      (cons first rest)))))
    
    (let ([ret (compress-inner p)])
      (if (= (length ret) 1)
	  (get-field place (car ret))
	  ret)))

  (cond
   [(number? place)
    (evaluate-with-sol place)]
   
   [(is-a? place Place%) 
    place]
   
   [(list? place)
    (for ([p place])
	 (send p to-concrete))
    (compress place)]
   
   [(pair? place)
    (let ([ret (concrete-place (car place))])
      (if (number? ret)
	  ret
	  (cons ret (cdr place))))]

   [(is-a? place TypeExpansion%)
    (set-field! place-list place 
		(map (lambda (x) (concrete-place x)) (get-field place-list place)))
    place]

   [else
    place]
   ))
    
      
;; number, place-list, place-type -> set
(define (to-place-set place)
  (cond
   [(number? place)
    (set place)]
   [(list? place)
    (foldl (lambda (p place-set) (set-add place-set (get-field place p)))
           (set) place)]
   [(pair? place)
    (to-place-set (car place))]
   [(or (at-any? place) (at-io? place))
    (set)]
   [(is-a? place TypeExpansion%)
    place]
   [else (raise (format "to-place-set: unimplemented for ~a" place))]))

;; number, place-list -> place-type
(define (to-place-type ast place)
  (cond
   [(or 
     (number? place) 
     (is-a? place Place%)
     (equal? place #f))
    place]

   [(list? place)
    (cons place ast)]
   
   [else (raise (format "to-place-type: unimplemented for ~a" place))]))

;; (define (clone-place place)
;;   (cond
;;    [(number? place)          place]
;;    [(list? place)            (map (lambda (x) (send x clone)) place)]
;;    [(place-type-dist? place) (cons (clone-place (car place)) (clone-place (cdr place)))]
;;    [(is-a? place Base%)      (send place clone)]
;;    [else                     (raise (format "clone-place: unimplemented for ~a" place))]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; AST ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define Base%
  (class object%
    (super-new)2
    (init-field [pos #f] [send-path #f] [convert #f] [expect 1])   

    (abstract pretty-print)

    (define/public (print-send-path indent)
      (when send-path
            (pretty-display (format "~a(send-path ~a)" (inc indent) 
                                    (send-path-to-string send-path)))))

    (define/public (accept v)
      (send v visit this))

    (define/public (get-line)
      (position-line pos))

    (define/public (get-col)
      (position-col pos))
    ))

(define Place%
  (class Base%
    (super-new)
    (init-field at)
    (inherit-field pos)

    ;; (define/public (clone)
    ;;   (new Place% [at (if (is-a? at Base%) (send at clone) at)]))

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(Place:~a)" indent (if (is-a? at Base%)
							(send at to-string)
							at))))
    
    (define/public (to-string)
      (if (equal? at "any")
	  "any"
	  (format "place(~a)" (if (is-a? at Base%) (send at to-string) at)))
      )

    (define/public (illegal-place)
      (define string (to-string))
      (raise (format "~a is illegal. It is clusterd array. Error at src: l:~a c:~a"
		     string (position-line pos) (position-col pos))))
    ))

(define Livable%
  (class Base%
    (super-new)
    (init-field [place (get-sym)])

    (define/public (get-place)
      (evaluate-with-sol place))
    (define/public (set-place new-place)
      (set! place new-place))

    (define/public (to-concrete)
      (set! place (concrete-place place)))
    ))



(define LivableGroup%
  (class Base%
    (super-new)
    (init-field place-list) ; doesn't have to be list

    (define/public (to-concrete)
      (set! place-list (concrete-place place-list)))
))

(define Exp%
  (class Base%
    (super-new)
    (init-field [known-type #f] [place-type #f] [cluster #f] [expand 1] [type #f])

    (define/public (infer-place [p place-type])
      ;(pretty-display `(infer-place ,p ,place-type))
      (when (at-any? place-type)
            (set! place-type p)))

    (define/public (get-place-known)
      (cons place-type known-type))

    (define/public (set-place-known x)
      (set! place-type (car x))
      (set! known-type (cdr x)))

    (define/public (get-known-type)
      known-type)

    (define/public (get-place)
      (place-to-string place-type))

    (define/public (to-concrete)
      (set! place-type (concrete-place place-type)))

    ;; This is used to construct place-type representation.
    (abstract to-string clone)

  ))

(define Scope%
  (class Base%
    (super-new)
    (init-field [body-placeset (set)] [parent #f])

    (define/public (print-body-placeset indent)
      (when body-placeset
            (pretty-display (format "~a(body-placeset ~a)" (inc indent) body-placeset))))))


(define Num%
  (class Exp%
    (inherit-field known-type place-type pos expect expand)
    (super-new [known-type #t] [type "int"] [expand 1])
    (init-field n)
    (inherit print-send-path)

    (define/public (get-value)
      (get-field n n))
    
    (define/override (pretty-print [indent ""])
      ;; (pretty-display (format "~a(Num:~a @~a (known=~a))" 
      ;;   		      indent (get-field n n) (place-to-string place-type) known-type))
      (pretty-display (format "~a(Num:~a @~a (expand=~a/~a))" 
			      indent (get-field n n) (place-to-string place-type) 
                              expand expect))
      (print-send-path indent))

    (define/override (to-string) (send n to-string))

    (define/override (clone)
      (new Num% [n (send n clone)] [pos pos]))
    ))

(define Var%
  (class Exp%
    (super-new)
    (inherit-field type known-type place-type pos expand expect)
    (init-field name [sub #f] [address #f])
    (inherit print-send-path)
    
    (define/override (clone)
      (new Var% [name name] [known-type known-type] [place-type place-type] [pos pos]
           [expand expand] [expect expect] [type type]))

    (define/override (pretty-print [indent ""])
      ;; (pretty-display (format "~a(Var:~a @~a (known=~a))" 
      ;;   		      indent name (place-to-string place-type) known-type))
      (pretty-display (format "~a(Var:~a @~a (expand=~a/~a))" 
                              indent name (place-to-string place-type)
                              expand expect))
      (print-send-path indent))

    (define/override (to-string) name)

    (define/public (not-found-error)
      (raise-syntax-error 'undefined
			  (format "'~a' error at src: l:~a c:~a" 
				  name
				  (position-line pos) 
				  (position-col pos))))

    (define/public (partition-mismatch part expect)
      (raise-mismatch-error 'data-partition
			    (format "number of data partitions at '~a' is ~a, expect <= ~a" 
				    name part expect)
			    (format "error at src  l:~a c:~a" (position-line pos) (position-col pos))))
    ))

(define Temp%
  (class Var%
    (super-new)))

(define Array%
  (class Var%
    (super-new)
    (inherit-field known-type place-type pos name expand expect)
    (init-field index [offset 0])
    (inherit print-send-path)

    (define/override (pretty-print [indent ""])
      ;; (pretty-display (format "~a(Array:~a @~a (known=~a))" 
      ;;   		      indent name (place-to-string place-type) known-type))
      (pretty-display (format "~a(Array:~a @~a (expand=~a/~a))" 
			      indent name (place-to-string place-type)
                              expand expect))
      (print-send-path indent)
      (when (> offset 0)
	    (pretty-display (format "~a(offset: ~a)" (inc indent) offset)))
      (send index pretty-print (inc indent)))

    (define/override (to-string)
      (if (> offset 0)
	  (format "~a[(~a)-~a]" name (send index to-string) offset)
	  (format "~a[~a]" name (send index to-string)))
      )

    (define/override (clone)
      (new Array% [name name] [index (send index clone)] [offset offset] [known-type known-type] [place-type place-type] [pos pos]))

    (define/public (index-out-of-bound index)
      (raise-range-error 'array "error at src" "" index 
			 (format "l:~a c:~a" (position-line pos) (position-col pos))
			 0 3))
    ))

;; AST for Binary opteration. 
(define BinExp%
  (class Exp%
    (super-new)
    (inherit-field known-type place-type)
    (init-field op e1 e2)
    (inherit print-send-path)
        
    (define/override (clone)
      (new BinExp% [op (send op clone)] [e1 (send e1 clone)] [e2 (send e2 clone)]
	   [known-type known-type] [place-type place-type]))

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(BinExp: @~a (known=~a)" 
			      indent (place-to-string place-type) known-type))
      (print-send-path indent)
      (send op pretty-print (inc indent))
      (send e1 pretty-print (inc indent))
      (send e2 pretty-print (inc indent))
      (pretty-display (format "~a)" indent)))

    (define/override (infer-place [p place-type])
      (when (at-any? place-type)
            (set! place-type p))
      (send e1 infer-place p)
      (send e2 infer-place p))

    (define/override (to-string)
      (format "(~a ~a ~a)" (send e1 to-string) (send op to-string) (send e2 to-string)))

    ))

;; AST for Unary opteration. 
(define UnaExp%
  (class Exp%
    (super-new)
    (inherit-field known-type place-type)
    (init-field op e1)
    (inherit print-send-path)

    (define/override (clone)
      (new UnaExp% [op (send op clone)] [e1 (send op clone)] [known-type known-type] [place-type place-type]))
    
    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(UnaOp: @~a (known=~a)" 
			      indent (place-to-string place-type) known-type))
      (print-send-path indent)
      (send op pretty-print (inc indent))
      (send e1 pretty-print (inc indent))
      (pretty-display (format "~a)" indent)))

    (define/override (infer-place [p place-type])
      (when (at-any? place-type)
            (set! place-type p))
      (send e1 infer-place p))

    (define/override (to-string)
      (format "(~a ~a)" (send op to-string) (send e1 to-string)))
    
    ))

(define FuncCall%
  (class Exp%
    (super-new)
    (inherit-field known-type place-type pos expand expect)
    (init-field name args [signature #f] [is-stmt #f])
    (inherit print-send-path)

    (define/override (clone)
      (raise (format "Funtion call '~a' cannot be cloned" name)))

    (define/public (copy-at core)
      (new FuncCall% [name name] 
           [args (filter (lambda (x) 
                           (let ([send-path (get-field send-path x)])
                             (or (not send-path) (= (last send-path) core))))
                         args)]
           [known-type known-type]
           [place-type place-type]
           [signature signature]))

    (define/override (pretty-print [indent ""])
      ;; (pretty-display (format "~a(FuncCall: ~a @~a (known=~a)" 
      ;;   		      indent name (evaluate-with-sol place-type) known-type))
      (pretty-display (format "~a(FuncCall: ~a @~a (expand=~a/~a)" 
			      indent name (evaluate-with-sol place-type)
                              expand expect))
      (print-send-path indent)
      (for ([arg args])
	   (send arg pretty-print (inc indent)))
      (pretty-display (format "~a)" indent)))

    (define/override (to-string)
      (format "~a(~a)" name (ast-list-to-string args)))

    (define/public (not-found-error)
      (raise-syntax-error 'undefined-function
			  (format "'~a' error at src: l:~a c:~a" 
				  name
				  (position-line pos) 
				  (position-col pos))))

    (define/public (partition-mismatch part expect)
      (raise-mismatch-error 'data-partition
			    (format "number of data partitions at '~a' is ~a, expect <= ~a" 
				    name part expect)
			    (format "error at src  l:~a c:~a" (position-line pos) (position-col pos))))

    (define/public (type-mismatch type entry)
      (raise-mismatch-error 'mismatch
			    (format "expect ~a data partitions but function '~a' returns ~a\n"
				    entry name type)
			    (format "error at src  l:~a c:~a" (position-line pos) (position-col pos))))
  
    (define/public (args-mismatch l)
      (raise-mismatch-error 'mismatch
			    (format "function ~a expects ~a arguments, but ~a arguments are given\n"
				    name l (length args))
			    (format "error at src  l:~a c:~a" (position-line pos) (position-col pos))))
    ))


(define Const%
  (class Livable%
    (super-new)
    (inherit-field place pos)
    (init-field n)
    (inherit get-place print-send-path)

    (define/public (clone)
      (new Const% [n n] [place place] [pos pos]))

    (define/public (inter-place p)
      (set! place p))
    
    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(Const:~a @~a)" indent n (get-place)))
      (print-send-path indent))

    (define/public (to-string) (number->string n))

))

(define Op%
  (class Livable%
    (super-new)
    (init-field op)
    (inherit-field pos)
    (inherit get-place print-send-path)

    (define/public (clone)
      (new Op% [op op] [pos pos]))
    
    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(Op:~a @~a)" indent op (get-place)))
      (print-send-path indent))

    (define/public (to-string) op)
    
    ))

(define VarDecl%
  (class Livable%
    (super-new)
    (inherit-field place pos)
    (init-field var-list type [known #t])
    (inherit get-place print-send-path)

    (define/public (infer-place p)
      (when (at-any? place)
            (set! place p)))

    ;; (define/public (copy)
    ;;   ;(pretty-display `(copy vardecl ,var-list ,type))
    ;;   (new VarDecl% [var-list var-list] [type type] [known known] [place place]))

    ;; (define/public (clone)
    ;;   (new VarDecl% [var-list var-list] [type type] [known known] 
    ;; 	   [place (clone-place place)]))

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(VARDECL ~a ~a @~a (known=~a))" 
                              indent type var-list place known))
      (print-send-path indent))

    (define/public (partition-mismatch)
      (raise-mismatch-error 'data-partition
			    (format "number of data partitions and places at '~a'" var-list)
			    (format "error at src  l:~a c:~a" (position-line pos) (position-col pos))))
  ))

(define ReturnDecl%
  (class VarDecl%
    (super-new)))

(define TempDecl%
  (class VarDecl%
    (super-new)))

(define Param%
  (class VarDecl%
    (super-new)
    (init-field [place-type #f] [known-type #t])
    (inherit-field var-list type known place)

    (define/public (set-known val)
      (set! known val)
      (set! known-type val))

    (define/override (infer-place [p place-type])
      (when (at-any? place-type)
            (set! place p)
            (set! place-type p)))
    
    ;; (define/override (copy)
    ;;   (new Param% [var-list var-list] [type type] [known known] [place place] 
    ;; 	   [known-type known-type] [place-type place-type]))

    ;; (define/override (clone)
    ;;   (new Param% [var-list var-list] [type type] [known known] 
    ;; 	   [place (clone-place place)]))

    (define/public (to-string)
      (format "param:~a" (car var-list)))
    
    (define/override (to-concrete)
      (super to-concrete)
      (set! place-type (concrete-place place-type))
      (set! place (concrete-place place)))))

(define RangePlace%
  (class Livable%
    (super-new)
    (inherit-field place send-path)
    (init-field from to)
    (inherit get-place)

    ;; (define/public (clone)
    ;;   (new RangePlace% [from from] [to to] [place (if (is-a? place Base%) (send place clone) place)]))

    (define/override (pretty-print)
      (pretty-display (to-string)))

    (define/public (equal-rangeplace? other)
      (and (and (equal? from (get-field from other))
                (equal? to   (get-field to   other)))
           (equal? place (get-field place other))))
    
    (define/public (to-string [out #f])
      (let* ([place (get-place)]
	     [print (if (and out (symbolic? place)) "??" place)])
	(format "[~a:~a]=~a" from to print)))

    (define/public (path-to-string)
      (format "[~a:~a]=~a" from to send-path))
    
    ))

(define TypeExpansion%
  (class Base%
    (super-new)
    (init-field place-list)

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(Place-type-expansion ~a)" place-list)))))

(define For%
  (class Scope%
    (super-new)
    (init-field iter from to body place-list known [address #f])
    (inherit print-send-path print-body-placeset)

    (define/public (to-concrete)
      (set! place-list (concrete-place place-list)))

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(FOR ~a from ~a to ~a) @{~a}" 
			      indent (send iter to-string) from to 
                              (place-to-string place-list)))
      (print-body-placeset indent)
      (print-send-path indent)
      (send body pretty-print (inc indent)))

))

(define ArrayDecl%
  (class LivableGroup%
    (super-new)
    (inherit-field pos place-list)
    (init-field var type bound cluster [known #t])
    (inherit print-send-path)
    
    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(ARRAYDECL ~a ~a @{~a} (known=~a) (cluster=~a)" 
                              indent type var
			      place-list
                              ;(place-to-string place-list)
                              known cluster))
      (print-send-path indent))

    (define/public (bound-error)
      (raise-mismatch-error 'mismatch 
        (format "array boundaries at place annotation of '~a' " var)
	(format "error at src:  l:~a c:~a" (position-line pos) (position-col pos))))

    ))

(define Assign%
  (class Base%
    (super-new)
    (init-field lhs rhs [ignore #f] [nocomm #f])

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(ASSIGN" indent))
      (send lhs pretty-print (inc indent))
      (send rhs pretty-print (inc indent))
      )

  ))

(define Return%
  (class Base%
    (super-new)
    (init-field val)

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(RETURN" indent))
      (if (list? val)
          (for ([x val])
               (send x pretty-print (inc indent)))
          (send val pretty-print (inc indent))))
    ))

(define If%
  (class Scope%
    (super-new)
    (init-field condition true-block [false-block #f])
    (inherit print-send-path)

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(IF" indent))
      (print-send-path indent)
      (send condition pretty-print (inc indent))
      (send true-block pretty-print (inc indent))
      (when false-block (send false-block pretty-print (inc indent))))
))

(define While%
  (class Scope%
    (super-new)
    (init-field condition body bound)
    (inherit print-send-path)

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(WHILE" indent))
      (print-send-path indent)
      (send condition pretty-print (inc indent))
      (send body pretty-print (inc indent)))

))

(define Block%
  (class Base%
     (super-new)
     (init-field stmts [parent #f])

     ;; (define/public (copy)
     ;;   (new Block% [stmts (map (lambda (x) (send x copy)) stmts)]))

     (define/override (pretty-print [indent ""])
       (for ([stmt stmts])
            (send stmt pretty-print indent)))

))

(define FuncDecl%
  (class Scope%
    (super-new)
    (init-field name args body return [temps (list)] [return-print #f])
    (inherit-field pos body-placeset)
    (inherit print-body-placeset)
    ;; args = list of VarDecl%
    ;; return = VarDecl%

    ;; clone everything but body is empty
    ;; (define/public (clone)
    ;;   (new FuncDecl% [name name] 
    ;; 	   [args (send args clone)] 
    ;; 	   [body (new Block% [stmts (list)])]
    ;; 	   [body-placeset body-placeset]
    ;; 	   [return (send return clone)]))

    (define/override (pretty-print [indent ""])
      (pretty-display (format "(FUNCTION ~a" name))
      (print-body-placeset indent)
      (send return pretty-print (inc indent))
      (send args pretty-print (inc indent))
      (send body pretty-print (inc indent)))

    (define/public (not-found-error)
      (raise-syntax-error 'undefined-function
			  (format "'~a' error at src: l:~a c:~a" 
				  name
				  (position-line pos) 
				  (position-col pos))))
    ))

(define Program%
  (class Block%
    (super-new)
    ))

(define Send%
  (class Base%
    (super-new)
    (init-field data port)
    
    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(SEND to:~a" indent port))
      (send data pretty-print (inc indent)))))

(define Recv%
  (class Exp%
    (super-new)
    (init-field port)

    (define/override (clone)
      (raise "clone is not supported for Recv%."))

    (define/override (pretty-print [indent ""])
      (pretty-display (format "~a(RECV from:~a)" indent port)))

    (define/override (to-string)
      (format "read(~a)" port))))
    


