#lang racket

(require "header.rkt" "arrayforth.rkt")

(define (list->linklist lst)
  (define (inner lst)
    (if (empty? lst)
        (linklist #f #f #f)
        (let* ([rest (inner (cdr lst))]
               [me (linklist #f (car lst) rest)])
          (when rest
            (set-linklist-prev! rest me))
          me)))
  
  (define start (inner lst))
  (define head (linklist #f #f start))
  (set-linklist-prev! start head)
  head)

(define (aforth-linklist ast)
  (cond
   [(list? ast)
    (list->linklist (for/list ([x ast]) (aforth-linklist x)))]

   [(forloop? ast)
    (forloop (forloop-init ast) 
	     (aforth-linklist (forloop-body ast))
	     (forloop-iter ast)
	     (forloop-from ast)
	     (forloop-to ast))]

   [(ift? ast)
    (ift (aforth-linklist (ift-t ast)))]

   [(iftf? ast)
    (iftf (aforth-linklist (iftf-t ast))
          (aforth-linklist (iftf-f ast)))]

   [(-ift? ast)
    (-ift (aforth-linklist (-ift-t ast)))]

   [(-iftf? ast)
    (-iftf (aforth-linklist (-iftf-t ast))
           (aforth-linklist (-iftf-f ast)))]

   [(funcdecl? ast)
    (funcdecl (funcdecl-name ast)
              (aforth-linklist (funcdecl-body ast)))]

   [(aforth? ast)
    (aforth (aforth-linklist (aforth-code ast))
	    (aforth-memsize ast) (aforth-bit ast) (aforth-indexmap ast))]

   [else ast]))

(define string-converter%
  (class object%
    (super-new)

    (define/public (visit ast)
      (cond
       [(linklist? ast)
        (define str "")
        (when (linklist-entry ast)
          (set! str (send this visit (linklist-entry ast))))
	(when (linklist-next ast)
	      (set! str (string-append str " " (send this visit (linklist-next ast)))))
	(string-trim str)]

       [(block? ast)
	(define body (block-body ast))
	(if (string? body)
	    body
	    (string-join body))]

       [(forloop? ast)
	(string-append (send this visit (forloop-init ast))
		       " for "
		       (send this visit (forloop-body ast))
		       " next")]

       [(ift? ast)
	(string-append "if " (send this visit (ift-t ast)))]

       [(iftf? ast)
	(string-append "if " (send this visit (iftf-t ast))
		       " then " (send this visit (iftf-f ast)))]

       [(-ift? ast)
	(string-append "-if " (send this visit (-ift-t ast)))]

       [(-iftf? ast)
	(string-append "-if " (send this visit (-iftf-t ast))
		       " then " (send this visit (-iftf-f ast)))]

       [(mult? ast)
	"mult"]

       [(funccall? ast)
	(funccall-name ast)]

       [else #f]))))

(define to-string (new string-converter%))

(define structure-extractor%
  (class object%
    (super-new)
    (define structure (make-hash))
    (define parent #f)

    
    (define/public (visit ast)
      (define (hash-structure)
	(define str (send to-string visit ast))
        (pretty-display str)
	(if (hash-has-key? structure str)
	    (hash-set! structure str (cons parent (hash-ref structure str)))
	    (hash-set! structure str (list parent))))

      (cond
       [(linklist? ast)
        (pretty-display `linklist?)
	(set! parent ast)
	(send this visit (linklist-entry ast))
	(when (linklist-next ast)
	      (send this visit (linklist-next ast)))]

       [(forloop? ast)
	(hash-structure)
        (send this visit (forloop-body ast))]

       [(ift? ast)
	(hash-structure)
	(send this visit (ift-t ast))]

       [(iftf? ast)
	(hash-structure)
	(send this visit (iftf-t ast))
	(send this visit (iftf-f ast))]

       [(-ift? ast)
	(hash-structure)
	(send this visit (-ift-t ast))]

       [(-iftf? ast)
	(hash-structure)
	(send this visit (-iftf-t ast))
	(send this visit (-iftf-f ast))]

       [(funcdecl? ast)
        (pretty-display `funcdecl?)
	(send this visit (funcdecl-body ast))]

       [(aforth? ast)
        (pretty-display `aforth)
	(send this visit (aforth-code ast))
	(findf (lambda (lst) (> (length lst) 1))
	       (hash-values structure))
	]
       
       [(list? ast)
        (raise "structure-extractor: please convert aforth structure to linklist first.")]
       
       [else void]))))


(define count 0)

;; mutate program by definig a new definition for the repeated sequences 
;; given as lst argument
(define (make-definition lst program)
  ;; args: list of linklists
  ;; return: true if their entries are the same
  (define (same? x)
    (let ([val (send to-string visit (linklist-entry (car x)))])
      (and (not (equal? val #f)) 
	   (andmap (lambda (a) (equal? val (send to-string visit (linklist-entry a))))
		   (cdr x)))))

  ;; return a pair of
  ;; 1) list of common insts
  ;; 2) list of different list of insts
  (define (common-prefix inst-lists)
    (if (empty? (car inst-lists))
        (cons (list)
              inst-lists)
        (let ([inst (caar inst-lists)])
          (if (andmap (lambda (x) (and (not (empty? x)) (equal? (car x) inst)))
                      (cdr inst-lists))
              ;; if not empty and the first element is the same
              (let ([res (common-prefix (map cdr inst-lists))])
                (cons (cons inst (car res))
                      (cdr res)))
              (cons (list)
                    inst-lists)))))

  ;; update block inside the linklists to the given code
  (define (update linklists inst-lists location)
    (for ([x-linklist linklists]
	  [x-code inst-lists])
	 ;; TODO update in, out, org
      (let* ([b (linklist-entry x-linklist)]
             [org (string-split (block-org b))])
        (set-block-body! b x-code)
        (if (equal? location `front)
            (set-block-org! b (string-join (take org (length x-code))))
            (set-block-org! b (string-join (drop org (- (length org) (length x-code))))))
        )))

  ;; return the first funcdecl in the given linklist
  (define (first-funcdecl-linklist lst)
    (if (funcdecl? (linklist-entry lst))
	lst
	(first-funcdecl-linklist (linklist-next lst))))

  ;; return new name for definition
  (define (new-def)
    (set! count (add1 count))
    (format "~arep" count))

  ;; the first common entries
  (define froms lst)
  ;; the lst common entries
  (define tos lst)

  ;; get previous entries in list of linklists x
  (define (get-from x)
    (if (same? x)
	(begin
	  (set! froms x) 
	  (get-from (map linklist-prev x)))
	x))

  ;; get next entries in list of linklists x
  (define (get-to x)
    (if (same? x)
	(begin
	  (set! tos x)
	  (get-to (map linklist-next x)))
	x))

  ;; the previous entries from the first common entries
  (define from-diffs (get-from (map linklist-prev lst)))
  ;; the next entries from the last common entries
  (define to-diffs (get-to (map linklist-next lst)))
  
  (define prefix #f)
  (define prefix-org #f)
  ;; check that it is a linklist that contains block
  (when (andmap (lambda (x) (and (linklist? x) (block? (linklist-entry x)))) 
	      from-diffs)
      ;; if not off the list
      (let* ([revs (map (lambda (x)
                          (let* ([insts (block-body (linklist-entry x))]
                                 [insts-list (if (list? insts) insts (string-split insts))])
                            (reverse insts-list)))
                        from-diffs)]
             [pair (common-prefix revs)])
	(update from-diffs (map reverse (cdr pair)) `front)
	;; TODO prefix-org
	(set! prefix (reverse (car pair)))
        (let ([first-insts (string-split (block-org (linklist-entry (car from-diffs))))])
          (set! prefix-org (drop first-insts (- (length first-insts) (length prefix)))))
        ))
  
  (define suffix #f)
  (define suffix-org #f)
  ;; check that it is a linklist that contains block
  (when (andmap (lambda (x) (and (linklist? x) (block? (linklist-entry x)))) 
	      to-diffs)
      ;; if not off the list
      (let* ([forwards (map (lambda (x)
			     (let* ([insts (block-body (linklist-entry x))]
                                    [insts-list (if (list? insts) insts (string-split insts))])
                               insts-list))
                            to-diffs)]
             [pair (common-prefix forwards)])
        (update to-diffs (cdr pair) `back)
	;; TODO suffix-org
	(set! suffix (car pair))
        (let ([first-insts (string-split (block-org (linklist-entry (car from-diffs))))])
          (set! prefix-org (take first-insts (length prefix))))
        ))

  (define new-name (new-def))
  (define from (car froms))
  (define to (car tos))
  (when prefix
	(set! from (linklist #f 
			     (block prefix 0 0 (aforth-memsize program) prefix-org)
			     from)))
  (when suffix
	(set! to (linklist to 
			   (block suffix 0 0 (aforth-memsize program) suffix-org)
			   #f)))
  ;; set head for from
  (define head (linklist #f #f from))
  (set-linklist-prev! from head)
  ;; set tail for to
  (set-linklist-next! to (linklist to #f #f))

  ;; insert new funcdecl into program
  (define def-entry (first-funcdecl-linklist (aforth-code program)))
  (define pre-entry (linklist-prev def-entry))
  (define new-entry (linklist pre-entry (funcdecl new-name head) def-entry))
  (set-linklist-next! pre-entry new-entry)
  (set-linklist-prev! def-entry new-entry)

  ;; replace common sequences wiht funccalls
  (for ([from from-diffs]
	[to to-diffs])
    (let ([new-linklist (linklist from (funccall new-name) to)])
      (set-linklist-next! from new-linklist)
      (set-linklist-prev! to new-linklist))))

(define program
  (aforth 
      (list 
        (vardecl '(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))
        (funcdecl "sumrotate"
          (list 
            (block
              "down b! @b left b! !b "
              0 0 #t
              "down b! @b left b! !b ")
          )
        )
        (funcdecl "main"
          (list 
            (forloop 
              (block
                "15 "
                0 1 #t
                "15 ")
              (list 
                (block
                  "0 16 b! !b 1 17 b! !b "
                  0 0 #t
                  "0 16 b! !b 1 17 b! !b ")
                (forloop 
                  (block
                    "15 "
                    0 1 #t
                    "15 ")
                  (list 
                    (block
                      "16 b! @b a! @ left b! !b "
                      0 0 #t
                      "16 b! @b a! @ left b! !b ")
                    (funccall "sumrotate")
                    (block
                      "16 b! @b 17 b! @b + 15 and 16 b! !b "
                      0 0 #t
                      "16 b! @b 17 b! @b + 15 and 16 b! !b ")
                  )
                  '(#f . #f) 0 16)
                (block
                  "1 16 b! !b 5 17 b! !b "
                  0 0 #t
                  "1 16 b! !b 5 17 b! !b ")
                (forloop 
                  (block
                    "15 "
                    0 1 #t
                    "15 ")
                  (list 
                    (block
                      "16 b! @b a! @ left b! !b "
                      0 0 #t
                      "16 b! @b a! @ left b! !b ")
                    (funccall "sumrotate")
                    (block
                      "16 b! @b 17 b! @b + 15 and 16 b! !b "
                      0 0 #t
                      "16 b! @b 17 b! @b + 15 and 16 b! !b ")
                  )
                  '(#f . #f) 16 32)
                (block
                  "5 16 b! !b 3 17 b! !b "
                  0 0 #t
                  "5 16 b! !b 3 17 b! !b ")
                (forloop 
                  (block
                    "15 "
                    0 1 #t
                    "15 ")
                  (list 
                    (block
                      "16 b! @b a! @ left b! !b "
                      0 0 #t
                      "16 b! @b a! @ left b! !b ")
                    (funccall "sumrotate")
                    (block
                      "16 b! @b 17 b! @b + 15 and 16 b! !b "
                      0 0 #t
                      "16 b! @b 17 b! @b + 15 and 16 b! !b ")
                  )
                  '(#f . #f) 32 48)
                (block
                  "0 16 b! !b 7 17 b! !b "
                  0 0 #t
                  "0 16 b! !b 7 17 b! !b ")
                (forloop 
                  (block
                    "15 "
                    0 1 #t
                    "15 ")
                  (list 
                    (block
                      "16 b! @b a! @ left b! !b "
                      0 0 #t
                      "16 b! @b a! @ left b! !b ")
                    (funccall "sumrotate")
                    (block
                      "16 b! @b 17 b! @b + 15 and 16 b! !b "
                      0 0 #t
                      "16 b! @b 17 b! @b + 15 and 16 b! !b ")
                  )
                  '(#f . #f) 48 64)
              )
              '(#f . #f) 0 16)
          )
        )
      )
    20 18 #hash((6 . 20) (0 . 0) (2 . 16) (3 . 17) (4 . 18) (5 . 19))))


(define extractor (new structure-extractor%))
(define linklist-program (aforth-linklist program))
(define same-structures (send extractor visit linklist-program))
(make-definition same-structures linklist-program)
(aforth-struct-print linklist-program)
