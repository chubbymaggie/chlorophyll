#lang s-exp rosette

(require "header.rkt" "ast-util.rkt" "visitor-flow.rkt")

(provide (all-defined-out) (struct-out layoutinfo))

(struct layoutinfo (routes part2core core2part))

(define (display-edges edges n w h)
  (pretty-display (format "~a ~a ~a" n w h))
  (for ([e edges])
       (pretty-display (format "~a ~a ~a" (edge-x e) (edge-y e) (edge-w e)))))

(define (index x y w)
  (+ (* x w) y))

(define (route core-a core-b w)
  (let ([a-x (floor (/ core-a w))]
        [a-y (modulo core-a w)]
        [b-x (floor (/ core-b w))]
        [b-y (modulo core-b w)])
    
    (define (move-y x y)
      (cond 
        [(< y b-y)
         (cons (index x y w) (move-y x (add1 y)))]
        [(> y b-y)
         (cons (index x y w) (move-y x (sub1 y)))]
        [else
         (list (index x y w))]))
    
    (define (move-x x y)
      (cond 
        [(< x b-x)
         (cons (index x y w) (move-x (add1 x) y))]
        [(> x b-x)
         (cons (index x y w) (move-x (sub1 x) y))]
        [else
         (move-y x y)]))
    
    (move-x a-x a-y)))
  
;; Gnerate (w x h + 1) x (w x h + 1) table
;; w x h corresponds to io
(define (gen-route flow-graph part2core w h)
  ;; Mapping partitions to cores in form of x*w + y
  (define n-1 (* w h))
  (define n (add1 n-1))
  
  ;; Mapping pair of partitions to route
  (define core2route (make-vector n #f))
  (for ([i (in-range n-1)])
    (vector-set! core2route i (make-vector n #f))
    (for ([j (in-range n-1)])
      (unless (= i j)
        (vector-2d-set! core2route n i j (route i j w)))))
  #|
  (for ([comm flow-graph])
    (let* ([a-core (vector-ref part2core (edge-x comm))]
           [b-core (vector-ref part2core (edge-y comm))]
           [path (route a-core b-core w)])
      (unless (vector-ref core2route a-core)
        (vector-set! core2route a-core (make-vector n #f)))
      (unless (vector-ref core2route b-core)
        (vector-set! core2route b-core (make-vector n #f)))
      
      (vector-2d-set! core2route n a-core b-core path)
      (vector-2d-set! core2route n b-core a-core (reverse path))))|#

  (vector-set! core2route n-1 (make-vector n #f))
  (for ([i (in-range n)])
       (vector-2d-set! core2route n i n-1 (list i n-1))
       (vector-2d-set! core2route n n-1 i (list n-1 i)))
  
  core2route)

(define (layout ast num-cores w h name weight)
  ;; Generate flow graph represented by a list of edges
  (define flow-gen (new flow-generator%))
  (define flow-graph (send ast accept flow-gen))
  
  (with-output-to-file #:exists 'truncate (format "~a/~a.graph" outdir name)
    (lambda () (display-edges flow-graph num-cores w h)))
  
  ;; Convert a list of edges into a matrix
  (with-output-to-string 
   (lambda () (system (format "./qap/graph2matrix.py ~a/~a.graph ~a > ~a/~a.dat" 
			      outdir name 
			      (if weight "--weight" "--noweight")
			      outdir name))))
  
  (with-output-to-file #:exists 'append (format "~a/~a.dat" outdir name)
    (lambda () 
      (define fix (make-vector (* w h)))
      (vector-set! fix (* w 2) (* w h))
      ;; (vector-set! fix (* w 3) 5)
      ;; (vector-set! fix (add1 (* w 2)) 6)
      (for ([i (in-range (* w h))])
           (display (vector-ref fix i)) (display " "))
      (newline)))
  
  ;; Mapping from cores to partitions
  (define start (current-seconds))
  (define core2part
    ;; Output of sa_qap starts from 1, but we want to start from 0.
    (map (lambda (x)
           (sub1 (string->number x)))
         (string-split
          (last (string-split
                 (with-output-to-string
                  (lambda () (system (format "./qap/sa_qap ~a/~a.dat 10000000 3" outdir name))))
                 "\n")))))
  (define stop (current-seconds))
  (with-output-to-file #:exists 'append (format "~a/~a.time" outdir name)
    (lambda ()
      (pretty-display (format "layout time: ~a s" (- stop start)))))

  (with-output-to-file #:exists 'truncate (format "~a/~a.layout" outdir name)
    (lambda () (display core2part)))

  (define n (* w h))
  (define part2core (make-vector n #f))
  (for ([partition core2part]
        [index (range n)])
       (vector-set! part2core partition index))
  
  ;; Create map from pair of core (x1,y1) (x2,y2) to routing
  (define routing-table (gen-route flow-graph part2core w h))

  (layoutinfo routing-table part2core (list->vector core2part))
  )
