#lang racket
(provide
 (all-from-out "mk-fo.rkt")
 prune/stream
 prune/goal
 dnf/stream
 dnf/goal

 strip/stream
 strip/state
 pretty/state
 pretty/stream
 pretty/goal

 parallel-step-simple
 parallel-step

 mature/step
 stream-take/step
 run/step-simplify
 run/step
 run*/step
 step
 
 drive/policy
 drive/stdio
 drive/depth-policy
 drive/depth-stdio

 step-counter
 step-reset-and-print!
 step-reset!
 step-count!

 explore/stream
 explore/stream-take
 explore
 explore-take)

(require "microk-fo.rkt")
(require "mk-fo.rkt")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Propagate shallow constraints and prune failures.
(define (prune/stream s)
  (match s
    ((mplus s1 s2) (match (prune/stream s1)
                     (#f (prune/stream s2))
                     (s1 (match (prune/stream s2)
                           (#f s1)
                           (s2 (mplus s1 s2))))))
    ((bind s g)    (match (prune/stream s)
                     (#f          #f)
                     (`(,st . #f) (prune/goal st g))
                     ((pause st g1)
                      (match (prune/goal st g)
                        (#f           #f)
                        ((pause st g) (pause st (conj g1 g)))))
                     (s (match (prune/goal empty-state g)
                          (#f          #f)
                          ((pause _ _) (bind s g))))))
    ((pause st g)  (prune/goal st g))
    (`(,st . ,s)   `(,st . ,(prune/stream s)))
    (s             s)))

(define (prune/goal st g)
  (define (prune/term t) (walk* t (state-sub st)))
  (match g
    ((disj g1 g2)
     (match (prune/goal st g1)
       (#f (prune/goal st g2))
       ((pause st1 g1)
        (match (prune/goal st g2)
          (#f           (pause st1 g1))
          ((pause _ g2) (pause st (disj g1 g2)))))))
    ((conj g1 g2)
     (match (prune/goal st g1)
       (#f            #f)
       ((pause st g1) (match (prune/goal st g2)
                        (#f            #f)
                        ((pause st g2) (pause st (conj g1 g2)))))))
    ((relate thunk d) (pause st (relate thunk (prune/term d))))
    ((== t1 t2)
     (let ((t1 (prune/term t1)) (t2 (prune/term t2)))
       (match (unify t1 t2 st)
         (#f          #f)
         (st          (pause st (== t1 t2))))))
    ((=/= t1 t2)
     (let ((t1 (prune/term t1)) (t2 (prune/term t2)))
       (match (disunify t1 t2 st)
         (#f          #f)
         (st          (pause st (=/= t1 t2))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Transform into Disjunctive Normal Form.
(define (dnf/stream s)
  (define (push-pause st g)
    (match g
      ((disj g1 g2) (mplus (push-pause st g1) (push-pause st g2)))
      (g            (pause st g))))
  (match s
    ((bind s g)
     (let loop1 ((s (dnf/stream s)) (g (dnf/goal g)))
       (define (loop2 s g)
         (match g
           ((disj ga gb) (mplus (loop2 s ga) (loop2 s gb)))
           (g            (bind s g))))
       (match s
         ((mplus sa sb) (mplus (loop1 sa g) (loop1 sb g)))
         (`(,st . ,s)   (mplus (push-pause st g) (loop1 s g)))
         (s             (loop2 s g)))))
    ((pause st g)  (push-pause st (dnf/goal g)))
    ((mplus s1 s2) (mplus (dnf/stream s1) (dnf/stream s2)))
    (`(,st . ,s)   `(,st . ,(dnf/stream s)))
    (s             s)))

(define (dnf/goal g)
  (match g
    ((conj g1 g2)
     (let loop1 ((g1 (dnf/goal g1)) (g2 (dnf/goal g2)))
       (define (loop2 g1 g2)
         (match g2
           ((disj g2a g2b) (disj (loop2 g1 g2a) (loop2 g1 g2b)))
           (g2             (conj g1 g2))))
       (match g1
         ((disj g1a g1b) (disj (loop1 g1a g2) (loop1 g1b g2)))
         (g1             (loop2 g1 g2)))))
    ((disj g1 g2) (disj (dnf/goal g1) (dnf/goal g2)))
    (g            g)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Pretty formatting
(define (strip/stream s)
  (match s
    ((mplus s1 s2) (mplus (strip/stream s1) (strip/stream s2)))
    ((bind s g)    (bind  (strip/stream s)  g))
    ((pause st g)  (pause (strip/state st)  g))
    (`(,st . ,s)   `(,(strip/state st) . ,(strip/stream s)))
    (#f            #f)))

(define (strip/state st)
  (state `((,initial-var . ,(walk* initial-var (state-sub st))))))

(define (pretty/state st)
  `(state ,(map (lambda (vt) `(== ,(car vt) ,(walk* (car vt) (state-sub st))))
                (state-sub st))))

(define (pretty/stream s)
  (match s
    ((mplus s1 s2) `(mplus ,(pretty/stream s1) ,(pretty/stream s2)))
    ((bind s g)    `(bind  ,(pretty/stream s)  ,(pretty/goal empty-state g)))
    ((pause st g)  `(pause ,(pretty/state st)  ,(pretty/goal st g)))
    (`(,st . ,s)   `(cons  ,(pretty/state st)  ,(pretty/stream s)))
    (#f            #f)))

(define (pretty/goal st g)
  (define (pretty/term t) (walk* t (state-sub st)))
  (match g
    ((disj g1 g2)     `(disj ,(pretty/goal st g1) ,(pretty/goal st g2)))
    ((conj g1 g2)     `(conj ,(pretty/goal st g1) ,(pretty/goal st g2)))
    ((== t1 t2)       `(== ,(pretty/term t1) ,(pretty/term t2)))
    ((relate thunk d) `(relate ,(pretty/term (cdr d))))))

;; Parallel step
(define (parallel-step-simple s)
  (define (parallel-start st g)
    (match g
      ((disj g1 g2)     (parallel-step-simple (mplus (pause st g1)
                                                     (pause st g2))))
      ((conj g1 g2)     (parallel-step-simple (bind (pause st g1) g2)))
      ((relate thunk _) (pause st (thunk)))
      ((== t1 t2)       (unify t1 t2 st))))
  (define (parallel-expand g)
    (let loop ((g g))
      (match g
        ((conj g1 g2)     (conj (loop g1) (loop g2)))
        ((relate thunk _) (thunk))
        (_                g))))
  (match s
    ((mplus s1 s2)
     (let ((s1 (if (mature? s1) s1 (parallel-step-simple s1))))
       (cond ((not s1)   s2)
             ((pair? s1) (cons (car s1) (mplus s2 (cdr s1))))
             (else       (mplus s2 s1)))))
    ((bind s g)
     (let ((s (if (mature? s) s (parallel-step-simple s))))
       (cond ((not s)   #f)
             ((pair? s) (parallel-step-simple (mplus (pause (car s) g)
                                                     (bind (cdr s) g)))

                        )
             (else      (bind s (parallel-expand g))))))
    ((pause st g) (parallel-start st g))
    (_            s)))

(define (parallel-step s)
  (parallel-step-simple (prune/stream (dnf/stream s))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Step-parameterized miniKanren run interface
(define (mature/step step s)
  (if (mature? s) s (mature/step step (step s))))
(define (stream-take/step step n s)
  (if (eqv? 0 n) '()
      (let ((s (mature/step step s)))
        (if (pair? s)
            (cons (car s) (stream-take/step step (and n (- n 1)) (cdr s)))
            '()))))

(define (simplify s)
  (prune/stream (dnf/stream s)))
(define-syntax run/step-simplify
  (syntax-rules ()
    ((_ step n body ...) (map reify/initial-var (stream-take/step
                                                 (lambda (s) (simplify (step s))) n (simplify (query body ...)))))))
(define-syntax run/step
  (syntax-rules ()
    ((_ step n body ...) (map reify/initial-var (stream-take/step
                                                 step n (query body ...))))))
(define-syntax run*/step
  (syntax-rules () ((_ step body ...) (run/step step #f body ...))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Interactive query exploration
(define (pprint v)        (pretty-print v (current-output-port) 1))
(define (pprint/string v) (with-output-to-string (lambda () (pprint v))))
(define (pprint/margin margin prefix v)
  (define indent (string-append "\n" margin
                                (make-string (string-length prefix) #\space)))
  (define body (string-replace (string-trim (pprint/string v)) "\n" indent))
  (displayln (string-append margin prefix body)))

(define (stream->choices s)
  (let loop ((s (prune/stream (dnf/stream s))))
    (match s
      ((mplus s1 s2) (append (loop s1) (loop s2)))
      (#f            '())
      (`(,st . ,s)   (cons st (loop s)))
      (s             (list s)))))

(define (walked-term t st) (walk* t (state-sub st)))

(define (goal->constraints st g)
  (match g
    ((conj g1 g2) (append (goal->constraints st g1) (goal->constraints st g2)))
    ((relate _ d) (list (walked-term (cdr d) st)))
    ((=/= t1 t2)  `(,(list '=/= (walked-term t1 st) (walked-term t2 st))))
    (_            '())))  ;; == information has already been added to st.

(define (explore/stream step qvars s)
  (define margin "| ")
  (define (pp prefix v) (pprint/margin margin prefix v))
  (define (pp/qvars vs)
    (define (qv-prefix qv) (string-append " " (symbol->string qv) " = "))
    (define qv-prefixes (and qvars (map qv-prefix qvars)))
    (if qv-prefixes
        (for-each (lambda (prefix v) (pp prefix v)) qv-prefixes vs)
        (for-each (lambda (v) (pp " " v)) vs)))
  (define (print-choice s)
    (match s
      ((pause st g)
       (pp/qvars (walked-term initial-var st))
       (define cxs (walked-term (goal->constraints st g) st))
       (unless (null? cxs)
         (displayln (string-append margin " Constraints:"))
         (for-each (lambda (v) (pp " * " v)) cxs))
       (when (null? cxs)
         (displayln (string-append margin " No constraints"))))))
  (let loop ((s (stream->choices s)) (undo '()))
    (define previous-choice
      (and (pair? undo)
           (let* ((i.s (car undo)) (i (car i.s)) (s (cdr i.s)))
             (list-ref (dropf s state?) (- i 1)))))
    (define results (takef s state?))
    (define choices (dropf s state?))
    (display "\n========================================")
    (displayln "========================================")
    (unless (= (length results) 0)
      (printf "Number of results: ~a\n" (length results))
      (for-each (lambda (st)
                  (pp/qvars (walked-term initial-var st))
                  (newline))
                results))
    (when (and previous-choice (null? results))
      (printf "Previous Choice:\n")
      (print-choice previous-choice)
      (newline))
    (printf "Current Depth: ~a\n" (length undo))
    (if (= 0 (length choices))
        (if (= (length results) 0)
            (printf "Choice FAILED!  Undo to continue.\n")
            (printf "No more choices available.  Undo to continue.\n"))
        (printf "Number of Choices: ~a\n" (length choices)))
    (for-each (lambda (i s)
                (printf (string-append "\n" margin "Choice ~s:\n") (+ i 1))
                (print-choice s))
              (range (length choices)) choices)
    (printf "\n[h]elp, [u]ndo, or choice number> \n")
    (define (invalid)
      (displayln "\nInvalid command or choice number.\nHit enter to continue.")
      (read-line) (read-line)
      (loop s undo))
    (define i (read))
    (cond ((eof-object? i) (newline))
          ((or (eq? i 'h) (eq? i 'help))
           (displayln
            (string-append "\nType either the letter 'u' or the"
                           " number following one of the listed choices."
                           "\nHit enter to continue."))
           (read-line) (read-line)
           (loop s undo))
          ((and (or (eq? i 'u) (eq? i 'undo)) (pair? undo))
           (loop (cdar undo) (cdr undo)))
          ((and (integer? i) (<= 1 i) (<= i (length choices)))
           (loop (stream->choices (step (list-ref choices (- i 1))))
                 (cons (cons i s) undo)))
          (else (invalid)))))

(define (explore/stream-take step qvars s)
  (define margin "")
  (define (pp prefix v) (pprint/margin margin prefix v))
  (define (pp/qvars vs)
    (define (qv-prefix qv) (string-append " " (symbol->string qv) " = "))
    (define qv-prefixes (and qvars (map qv-prefix qvars)))
    (if qv-prefixes
        (for-each (lambda (prefix v) (pp prefix v)) qv-prefixes vs)
        (for-each (lambda (v) (pp " " v)) vs)))
  (define (print-choice s)
    (match s
      ((pause st g)
       (pp/qvars (walked-term initial-var st))
       (define cxs (walked-term (goal->constraints st g) st))
       (unless (null? cxs)
         (displayln (string-append margin " Constraints:"))
         (for-each (lambda (v) (pp " * " v)) cxs))
       (when (null? cxs)
         (displayln (string-append margin " No constraints"))))))
  (let loop ((s (stream->choices s)) (undo '()))
    (define results (takef s state?))
    (define choices (dropf s state?))
    (unless (= (length results) 0)
      (printf "Number of results: ~a\n" (length results))
      (for-each (lambda (st)
                  (pp/qvars (walked-term initial-var st))
                  (newline))
                results))
    (printf "Current Depth: ~a\n" (length undo))
    (if (= 0 (length choices))
        (if (= (length results) 0)
            (printf "Choice FAILED!  Undo to continue.\n")
            (printf "Finished in steps: ~a\n" step-counter))
        (printf "Number of Choices: ~a\n" (length choices)))
    (for-each (lambda (i s)
                (printf (string-append "\n" margin "Choice ~s:\n") (+ i 1))
                (print-choice s))
              (range (length choices)) choices)
    (unless (> (length results) 0)
      (printf "\n[h]elp, [u]ndo, or choice number> \n")
      (define (invalid)
        (displayln "\nInvalid command or choice number.")
        (loop s undo))
      (define i (read))
      (cond ((eof-object? i) (newline))
            ((or (eq? i 'h) (eq? i 'help))
             (displayln
              (string-append "\nType either the letter 'u' or the"
                             " number following one of the listed choices."))
             (loop s undo))
            ((and (or (eq? i 'u) (eq? i 'undo)) (pair? undo))
             (loop (cdar undo) (cdr undo)))
            ((and (integer? i) (<= 1 i) (<= i (length choices)))
             (loop (stream->choices (step (list-ref choices (- i 1))))
                   (cons (cons i s) undo)))
            (else (invalid))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Define explore state to maintain the data held at every step
;; when exploring
;; https://wiki.haskell.org/Zipper
(struct explore-context (index siblings choices parent) #:prefab)
(struct explore-node (index choices expanded-choices) #:prefab)
;;       a
;;    /--|--\
;;   b   c   d
;;  / \
;; e   @
;; would be modeled as (@ as current context):
;; (1 '(e) (0 '(c d) (-1 '(a) 'top)))
(struct explore-loc (tree context) #:prefab)
(define explore-top 'X-TOP)
(define (init-explore query)
  (let ([choices (stream->choices query)])
    (explore-loc (explore-node -1 choices '()) explore-top)))

(define (expand-choice choice step)
  (let* ([expanded-choices (stream->choices (step choice))])
    (cond
      [(null? expanded-choices) '()]
      [(and (= 1 (length expanded-choices)) (not (state? (car expanded-choices))))
       (expand-choice (car expanded-choices) step)]
      [else expanded-choices])))
(define (expand-choice-node choices step i)
  (explore-node i (expand-choice (list-ref choices i) step) '()))
(define (expand/depth node step depth)
  (define choices (explore-node-choices node))
  (if (and (= 1 (length choices)) (not (state? (car choices))))
    (expand/depth (expand-choice-node choices step 0) step depth)
    (if (<= depth 0)
      node
      (let* ([deep-exp-chs (map (lambda (xn) (expand/depth xn step (- depth 1))) (explore-node-expanded-choices node))]
             [exp-indices (map explore-node-index deep-exp-chs)]
             [to-expand-indices (remove* exp-indices (range (length choices)))]
             [new-exp-chs (map (lambda (i) (expand/depth (expand-choice-node choices step i) step (- depth 1))) to-expand-indices)])
        (explore-node (explore-node-index node) choices (append deep-exp-chs new-exp-chs))))))
(define (init-tree/depth query step depth)
  (let* ([choices (stream->choices query)]
         [node (explore-node -1 choices '())]
         [deep-node (expand/depth node step depth)])
    (explore-loc deep-node explore-top)))

;; tree manipulation
(define (explore-choice exp-loc step choice)
  (match exp-loc
    [(explore-loc (explore-node i chs xchs) parent)
     (let*-values ([(x-ind) (index-where xchs (lambda (xn) (= choice (explore-node-index xn))))]
                   [(xc hes) (if (not x-ind) (values '() xchs) (split-at xchs x-ind))]
                   [(expanded-node) (if x-ind (list-ref xchs x-ind) (expand-choice-node chs step choice))]
                   [(expanded-context) (explore-context choice (append xc hes) chs parent)])
       (explore-loc expanded-node expanded-context))]))
(define (explore-choice/depth exp-loc step choice depth)
  (define tree (explore-loc-tree exp-loc))
  (define choices (explore-node-choices tree))
  (match exp-loc
    [(explore-loc (explore-node i chs xchs) parent)
     (let*-values ([(x-ind) (index-where xchs (lambda (xn) (= choice (explore-node-index xn))))]
                   [(xc hes) (if (not x-ind) (values '() xchs) (split-at xchs x-ind))]
                   [(expanded-node) (if x-ind (list-ref xchs x-ind) (expand/depth (expand-choice-node chs step choice) step depth))]
                   [(expanded-context) (explore-context choice (append xc hes) chs parent)])
       (explore-loc expanded-node expanded-context))]))
(define (explore-multi-choice/depth exp-loc step choices depth)
  (match exp-loc
    [(explore-loc n p)
     (if (> (length choices) 1)
       (explore-multi-choice/depth (explore-choice exp-loc step (car choices)) step (cdr choices) depth)
       (explore-choice/depth exp-loc step (car choices) depth))]))
(define (explore-undo exp-loc)
  (match exp-loc
    [(explore-loc tree (explore-context i siblings ch ctx))
     (explore-loc (explore-node i ch (cons tree siblings)) ctx)]
    [(explore-loc t 'X-TOP) (explore-loc t 'X-TOP)]))

;; pretty-print functions
(define (pp/qvars qvars vs margin)
  (define (qv-prefix qv) (string-append " " (symbol->string qv) " = "))
  (define qv-prefixes (and qvars (map qv-prefix qvars)))
  (if qv-prefixes
      (for-each (lambda (prefix v) (pprint/margin margin prefix v)) qv-prefixes vs)
      (for-each (lambda (v) (pprint/margin margin " " v)) vs)))
(define (pprint-choice s qvars margin)
  (match s
    [(pause st g)
      (pp/qvars qvars (walked-term initial-var st) margin)
      (define cxs (walked-term (goal->constraints st g) st))
      (unless (null? cxs)
        (displayln (string-append margin "Constraints:"))
        (for-each (lambda (v) (pprint/margin margin " * " v)) cxs))
      (when (null? cxs)
        (displayln (string-append margin "No constraints"))
        (newline))]))
(define (pprint-result s qvars margin)
  (pp/qvars qvars (walked-term initial-var s) margin)
  (newline))
(define (pprint-choices choices qvars)
  (define chs (dropf choices state?))
  (define results (takef choices state?))
  (when (and (= 0 (length chs)) (null? results))
    (printf "No more choices available. Undo to continue.\n"))
  (unless (null? chs)
    (printf "Number of Choices: ~a\n" (length chs))
    (for-each (lambda (i s)
                (printf (string-append "Choice ~s:\n") (+ i 1))
                (pprint-choice s qvars ""))
              (range (length chs)) chs))
  (unless (null? results)
    (printf "Number of results: ~a\n" (length results))
    (for-each (lambda (st)
                (pprint-result st qvars ""))
              results)))
(define (pp-ch/depth node qvars depth prefix)
  (define options (explore-node-expanded-choices node))
  (define choices (explore-node-choices node))
  (define results (takef (explore-node-choices node) state?))
  (define margin (list->string (make-list (string-length prefix) #\space)))
  (newline)
  (when (and (= 0 (length options)) (not (non-empty-string? prefix)) (null? results))
    (printf "No more choices available. Undo to continue.\n"))
  (unless (null? options)
    (printf (string-append margin "Number of Choices: ~a\n") (length options))
    (for-each (lambda (n)
                (let* ([i (explore-node-index n)]
                       [next-prefix (string-append prefix (~a (+ i 1)) ".")]
                       [choice (list-ref choices i)]
                       [is-result (state? choice)])
                  (printf (string-append "\n" margin "Choice " prefix "~s:\n") (+ i 1))
                  (if is-result
                    (pprint-result choice qvars margin)
                    (pprint-choice (list-ref choices i) qvars margin))
                  (when (and (> depth 0) (not is-result))
                    (pp-ch/depth n qvars (- depth 1) next-prefix))))
              options))
  (unless (null? results)
    (printf (string-append margin "Number of results: ~a\n") (length results))
    (for-each (lambda (st)
                (displayln (string-append margin "Result:"))
                (pprint-result st qvars margin))
              results)))
(define (pprint-choices/depth node qvars depth)
  (pp-ch/depth node qvars depth ""))

;; policy-print, policy-read, policy-done?
(define (pp/explore-tree exp-loc qvars)
  (define tree (explore-loc-tree exp-loc))
  #| (printf "Tree: ~s\n" tree) |#
  #| (printf "Context: ~s\n" (explore-loc-context exp-loc)) |#
  (pprint-choices (explore-node-choices tree) qvars))
(define (pp-explore-tree/depth exp-loc qvars depth)
  (define tree (explore-loc-tree exp-loc))
  (pprint-choices/depth tree qvars depth))
(define (explore-tree-input)
  (printf "\n[u]ndo, or choice number> \n")
  (read))
(define (explore-tree-finished? exp-loc)
  (let* ([tree (explore-loc-tree exp-loc)]
         [choices (explore-node-choices tree)]
         [finished-index (index-where
                           choices
                           (lambda (x) (state? x)))]
        [valid-index (exact-nonnegative-integer? finished-index)])
    valid-index))
(define (explore-tree-input-depth)
  (printf "\n[u]ndo, or choices (period-separated)>\n")
  (define input (read))
  (string-split (~s input) "."))

(define (drive/policy step qvars policy-print policy-read policy-done? init-state)
  (let loop ([s init-state])
    (policy-print s qvars)
    (unless (policy-done? s)
      (let* ([input (policy-read)]
             [tree (explore-loc-tree s)])
        (loop
          (cond
            [(and (integer? input) (<= 1 input) (<= input (length (explore-node-choices tree))))
             (explore-choice s step (- input 1))]
            [(or (eq? input 'u) (eq? input 'undo)) (explore-undo s)]
            [else s]))))))

(define (drive/depth-policy step qvars policy-print policy-read policy-done? init-state depth)
  (let loop ([s init-state])
    (policy-print s qvars depth)
    (unless (policy-done? s)
      (let* ([input (policy-read)]
             [choices (map (lambda (i) (- (or (string->number i) 1) 1)) input)]
             [tree (explore-loc-tree s)])
        (loop
          (cond
            [(andmap (lambda (x) (and (integer? x) (<= 0 x))) choices)
             (explore-multi-choice/depth s step choices depth)]
            [(or (eq? (car input) 'u) (eq? (car input) 'undo)) (explore-undo s)]
            [else s]))))))

(define-syntax drive/stdio
  (syntax-rules (query)
    [(_ step (query (qvars ...) body ...))
     (drive/policy
       step
       '(qvars ...) 
       pp/explore-tree
       explore-tree-input
       explore-tree-finished? 
       (init-explore (query (qvars ...) body ...)))]))

(define DEPTH 3)

(define-syntax drive/depth-stdio
  (syntax-rules (query)
    [(_ step (query (qvars ...) body ...))
     (drive/depth-policy
       step
       '(qvars ...) 
       pp-explore-tree/depth
       explore-tree-input-depth
       explore-tree-finished? 
       (init-tree/depth (query (qvars ...) body ...) step DEPTH)
       DEPTH)]))

(define-syntax explore
  (syntax-rules (query)
    ((_ step (query (qvars ...) body ...))
     (begin (printf "Using step procedure: ~s\nExploring query:\n~s\n"
                    'step '(query (qvars ...) body ...))
            (explore/stream step '(qvars ...) (query (qvars ...) body ...))))
    ((_ step stream) (explore/stream step #f stream))))

(define-syntax explore-take
  (syntax-rules (query)
    ((_ step (query (qvars ...) body ...))
     (begin (printf "Using step procedure: ~s\nExploring query:\n~s\n"
                    'step '(query (qvars ...) body ...))
            (explore/stream-take step '(qvars ...) (query (qvars ...) body ...))))
    ((_ step stream) (explore/stream-take step #f stream))))
