#lang racket/base
(require (for-syntax racket/base
                     "arr-util.rkt"
                     "helpers.rkt")
         "arity-checking.rkt"
         "kwd-info-struct.rkt"
         "blame.rkt"
         "misc.rkt"
         "prop.rkt"
         "guts.rkt"
         (prefix-in arrow: "arrow.rkt")
         (only-in racket/unsafe/ops
                  unsafe-chaperone-procedure
                  unsafe-impersonate-procedure))

(provide (for-syntax build-chaperone-constructor/real)
         procedure-arity-exactly/no-kwds
         ->-proj
         check-pre-cond
         check-post-cond
         pre-post/desc-result->string)

(define-for-syntax (build-chaperone-constructor/real this-args

                                                     ;; (listof (or/c #f stx))
                                                     ;; #f => syntactically known to be any/c
                                                     mandatory-dom-projs
                                                     
                                                     optional-dom-projs
                                                     mandatory-dom-kwds
                                                     optional-dom-kwds
                                                     pre pre/desc
                                                     rest
                                                     rngs
                                                     post post/desc)
  (define (nvars n sym) (generate-temporaries (for/list ([i (in-range n)]) sym)))
  (with-syntax ([(mandatory-dom-proj ...) (generate-temporaries mandatory-dom-projs)]
                [(optional-dom-proj ...) (generate-temporaries optional-dom-projs)]
                [(mandatory-dom-kwd-proj ...) (nvars (length mandatory-dom-kwds) 'mandatory-dom-proj)]
                [(optional-dom-kwd-proj ...) (nvars (length optional-dom-kwds) 'optional-dom-proj)]
                [(rng-proj ...) (if rngs (generate-temporaries rngs) '())]
                [(rest-proj ...) (if rest (generate-temporaries '(rest-proj)) '())])
    #`(λ (blame f neg-party blame-party-info rng-ctcs
                mandatory-dom-proj ...  
                optional-dom-proj ... 
                rest-proj ...
                mandatory-dom-kwd-proj ... 
                optional-dom-kwd-proj ... 
                rng-proj ...)
        #,(create-chaperone
           #'blame #'neg-party #'blame-party-info #'f #'rng-ctcs
           this-args
           (for/list ([id (in-list (syntax->list #'(mandatory-dom-proj ...)))]
                      [mandatory-dom-proj (in-list mandatory-dom-projs)])
             (and mandatory-dom-proj id))
           (syntax->list #'(optional-dom-proj ...))
           (map list 
                mandatory-dom-kwds
                (syntax->list #'(mandatory-dom-kwd-proj ...)))
           (map list 
                optional-dom-kwds
                (syntax->list #'(optional-dom-kwd-proj ...)))
           pre pre/desc
           (if rest (car (syntax->list #'(rest-proj ...))) #f)
           (if rngs (syntax->list #'(rng-proj ...)) #f)
           post post/desc))))


(define (check-pre-cond pre blame neg-party val)
  (with-contract-continuation-mark
   (cons blame neg-party)
   (unless (pre)
     (raise-blame-error (blame-swap blame)
                        #:missing-party neg-party
                        val "#:pre condition"))))

(define (check-post-cond post blame neg-party val)
  (with-contract-continuation-mark
   (cons blame neg-party)
   (unless (post)
     (raise-blame-error blame
                        #:missing-party neg-party
                        val "#:post condition"))))

(define (check-pre-cond/desc post blame neg-party val)
  (handle-pre-post/desc-string #t post blame neg-party val))
(define (check-post-cond/desc post blame neg-party val)
  (handle-pre-post/desc-string #f post blame neg-party val))
(define (handle-pre-post/desc-string pre? thunk blame neg-party val)
  (define condition-result (thunk))
  (cond
    [(equal? condition-result #t) 
     (void)]
    [else
     (define msg
       (pre-post/desc-result->string condition-result pre? '->*))
     (raise-blame-error (if pre? (blame-swap blame) blame)
                        #:missing-party neg-party
                        val "~a" msg)]))

(define (pre-post/desc-result->string condition-result pre? who)
  (cond
    [(equal? condition-result #f)
     (if pre?
         "#:pre condition"
         "#:post condition")]
    [(string? condition-result)
     condition-result]
    [(and (list? condition-result)
          (andmap string? condition-result))
     (apply
      string-append
      (let loop ([s condition-result])
        (cond
          [(null? s) '()]
          [(null? (cdr s)) s]
          [else (list* (car s)
                       "\n " 
                       (loop (cdr s)))])))]
    [else
     (error
      who
      "expected #:~a/desc to produce (or/c boolean? string? (listof string?)), got ~e"
      (if pre? "pre" "post")
      condition-result)]))

(define-for-syntax (create-chaperone blame neg-party blame-party-info
                                     val rng-ctcs
                                     this-args
                                     doms opt-doms
                                     req-kwds opt-kwds
                                     pre pre/desc
                                     dom-rest
                                     rngs
                                     post post/desc)
  (with-syntax ([blame blame]
                [val val])
    (with-syntax ([(pre ...) 
                   (cond
                     [pre
                      (list #`(check-pre-cond #,pre blame neg-party val))]
                     [pre/desc
                      (list #`(check-pre-cond/desc #,pre/desc blame neg-party val))]
                     [else null])]
                  [(post ...)
                   (cond
                     [post
                      (list #`(check-post-cond #,post blame neg-party val))]
                     [post/desc
                      (list #`(check-post-cond/desc #,post/desc blame neg-party val))]
                     [else null])])
      (with-syntax ([(this-param ...) this-args]
                    [(dom-x ...) (generate-temporaries doms)]
                    [(opt-dom-ctc ...) opt-doms]
                    [(opt-dom-x ...) (generate-temporaries opt-doms)]
                    [(rest-ctc rest-x) (cons dom-rest (generate-temporaries '(rest)))]
                    [(req-kwd ...) (map car req-kwds)]
                    [(req-kwd-ctc ...) (map cadr req-kwds)]
                    [(req-kwd-x ...) (generate-temporaries (map car req-kwds))]
                    [(opt-kwd ...) (map car opt-kwds)]
                    [(opt-kwd-ctc ...) (map cadr opt-kwds)]
                    [(opt-kwd-x ...) (generate-temporaries (map car opt-kwds))]
                    [(rng-late-neg-projs ...) (if rngs rngs '())]
                    [(rng-x ...) (if rngs (generate-temporaries rngs) '())])

        (define rng-checker
          (and rngs
               (with-syntax ([rng-len (length rngs)]
                             [rng-results #'(values (rng-late-neg-projs rng-x neg-party) ...)])
                 #'(case-lambda
                     [(rng-x ...)
                      (with-contract-continuation-mark
                       (cons blame neg-party)
                       (let ()
                         post ...
                         rng-results))]
                     [args
                      (arrow:bad-number-of-results blame val rng-len args
                                                   #:missing-party neg-party)]))))
        (define (wrap-call-with-values-and-range-checking stx assume-result-values?)
          (if rngs
              (if assume-result-values?
                  #`(let-values ([(rng-x ...) #,stx])
                      (with-contract-continuation-mark
                       (cons blame neg-party)
                       (let ()
                         post ...
                         (values (rng-late-neg-projs rng-x neg-party) ...))))
                  #`(call-with-values
                     (λ () #,stx)
                     #,rng-checker))
              stx))

          (let* ([min-method-arity (length doms)]
                 [max-method-arity (+ min-method-arity (length opt-doms))]
                 [min-arity (+ (length this-args) min-method-arity)]
                 [max-arity (+ min-arity (length opt-doms))]
                 [req-keywords (map (λ (p) (syntax-e (car p))) req-kwds)]
                 [opt-keywords (map (λ (p) (syntax-e (car p))) opt-kwds)]
                 [need-apply? (or dom-rest (not (null? opt-doms)))])
            (with-syntax ([(dom-projd-args ...)
                           (for/list ([dom (in-list doms)]
                                      [dom-x (in-list (syntax->list #'(dom-x ...)))])
                             (if dom
                                 #`(#,dom #,dom-x neg-party)
                                 dom-x))]
                          [basic-params
                           (cond
                             [dom-rest
                              #'(this-param ... 
                                 dom-x ...
                                 [opt-dom-x arrow:unspecified-dom] ...
                                 . 
                                 rest-x)]
                             [else
                              #'(this-param ... dom-x ... [opt-dom-x arrow:unspecified-dom] ...)])]
                          [opt+rest-uses
                           (for/fold ([i (if dom-rest #'(rest-ctc rest-x neg-party) #'null)])
                             ([o (in-list (reverse
                                           (syntax->list
                                            #'((opt-dom-ctc opt-dom-x neg-party) ...))))]
                              [opt-dom-x (in-list (reverse (syntax->list #'(opt-dom-x ...))))])
                             #`(let ([r #,i])
                                 (if (eq? arrow:unspecified-dom #,opt-dom-x) r (cons #,o r))))]
                          [(kwd-param ...)
                           (apply 
                            append
                            (map list
                                 (syntax->list #'(req-kwd ... opt-kwd ...))
                                 (syntax->list #'(req-kwd-x ... 
                                                  [opt-kwd-x arrow:unspecified-dom] ...))))]
                          [kwd-stx
                           (let* ([req-stxs
                                   (map (λ (s) (λ (r) #`(cons #,s #,r)))
                                        (syntax->list #'((req-kwd-ctc req-kwd-x neg-party) ...)))]
                                  [opt-stxs 
                                   (map (λ (x c) (λ (r) #`(maybe-cons-kwd #,c #,x #,r neg-party)))
                                        (syntax->list #'(opt-kwd-x ...))
                                        (syntax->list #'(opt-kwd-ctc ...)))]
                                  [reqs (map cons req-keywords req-stxs)]
                                  [opts (map cons opt-keywords opt-stxs)]
                                  [all-together-now (append reqs opts)]
                                  [put-in-reverse (sort all-together-now 
                                                        (λ (k1 k2) (keyword<? k2 k1))
                                                        #:key car)])
                             (for/fold ([s #'null])
                               ([tx (in-list (map cdr put-in-reverse))])
                               (tx s)))])
              
              (with-syntax ([kwd-lam-params
                             (if dom-rest
                                 #'(this-param ...
                                    dom-x ... 
                                    [opt-dom-x arrow:unspecified-dom] ...
                                    kwd-param ... . rest-x)
                                 #'(this-param ...
                                    dom-x ...
                                    [opt-dom-x arrow:unspecified-dom] ...
                                    kwd-param ...))]
                            [basic-return
                             (let ([inner-stx-gen
                                    (if need-apply?
                                        (λ (s) #`(apply values #,@s 
                                                        this-param ... 
                                                        dom-projd-args ... 
                                                        opt+rest-uses))
                                        (λ (s) #`(values 
                                                  #,@s 
                                                  this-param ...
                                                  dom-projd-args ...)))])
                               (if rngs
                                   (arrow:check-tail-contract rng-ctcs
                                                              blame-party-info
                                                              neg-party
                                                              (list rng-checker)
                                                              inner-stx-gen
                                                              #'(cons blame neg-party))
                                   (inner-stx-gen #'())))]
                            [(basic-unsafe-return
                              basic-unsafe-return/result-values-assumed
                              basic-unsafe-return/result-values-assumed/no-tail)
                             (let ()
                               (define (inner-stx-gen stuff assume-result-values? do-tail-check?)
                                 (define arg-checking-expressions
                                   (if need-apply?
                                       #'(this-param ... dom-projd-args ... opt+rest-uses)
                                       #'(this-param ... dom-projd-args ...)))
                                 (define the-call/no-tail-mark
                                   (cond
                                     [(for/and ([dom (in-list doms)])
                                        (not dom))
                                      (if need-apply?
                                          #`(apply val #,@arg-checking-expressions)
                                          #`(val #,@arg-checking-expressions))]
                                     [else
                                      (with-syntax ([(tmps ...) (generate-temporaries
                                                                 arg-checking-expressions)])
                                        #`(let-values ([(tmps ...)
                                                        (with-contract-continuation-mark
                                                         (cons blame neg-party)
                                                         (values #,@arg-checking-expressions))])
                                            #,(if need-apply?
                                                  #`(apply val tmps ...)
                                                  #`(val tmps ...))))]))
                                 (define the-call
                                   (if do-tail-check?
                                       #`(with-continuation-mark arrow:tail-contract-key
                                           (list* neg-party blame-party-info #,rng-ctcs)
                                           #,the-call/no-tail-mark)
                                       the-call/no-tail-mark))
                                 (cond
                                   [(null? (syntax-e stuff)) ;; surely there must a better way
                                    the-call/no-tail-mark]
                                   [else
                                    (wrap-call-with-values-and-range-checking
                                     the-call
                                     assume-result-values?)]))
                               (define (mk-return assume-result-values? do-tail-check?)
                                 (if do-tail-check?
                                     (if rngs
                                         (arrow:check-tail-contract
                                          rng-ctcs
                                          blame-party-info
                                          neg-party
                                          #'not-a-null
                                          (λ (x) (inner-stx-gen x assume-result-values? do-tail-check?))
                                          #'(cons blame neg-party))
                                         (inner-stx-gen #'() assume-result-values? do-tail-check?))
                                     (inner-stx-gen #'not-a-null assume-result-values? do-tail-check?)))
                               (list (mk-return #f #t) (mk-return #t #t) (mk-return #t #f)))]
                            [kwd-return
                             (let* ([inner-stx-gen
                                     (if need-apply?
                                         (λ (s k) #`(apply values 
                                                           #,@s #,@k 
                                                           this-param ...
                                                           dom-projd-args ...
                                                           opt+rest-uses))
                                         (λ (s k) #`(values #,@s #,@k 
                                                            this-param ...
                                                            dom-projd-args ...)))]
                                    [outer-stx-gen
                                     (if (null? req-keywords)
                                         (λ (s)
                                           #`(if (null? kwd-results)
                                                 #,(inner-stx-gen s #'())
                                                 #,(inner-stx-gen s #'(kwd-results))))
                                         (λ (s)
                                           (inner-stx-gen s #'(kwd-results))))])
                               #`(let ([kwd-results kwd-stx])
                                   #,(if rngs
                                         (arrow:check-tail-contract rng-ctcs
                                                                    blame-party-info
                                                                    neg-party
                                                                    (list rng-checker)
                                                                    outer-stx-gen
                                                                    #'(cons blame neg-party))
                                         (outer-stx-gen #'()))))])

                ;; Arrow contract domain checking is instrumented
                ;; both here, and in `arity-checking-wrapper'.
                ;; We need to instrument here, because sometimes
                ;; a-c-w doesn't wrap, and just returns us.
                ;; We need to instrument in a-c-w to count arity
                ;; checking time.
                ;; Overhead of double-wrapping has not been
                ;; noticeable in my measurements so far.
                ;;  - stamourv
                (with-syntax ([basic-lambda #'(λ basic-params
                                                (with-contract-continuation-mark
                                                 (cons blame neg-party)
                                                 (let ()
                                                   pre ... basic-return)))]
                              [basic-unsafe-lambda
                               #'(λ basic-params
                                   (let ()
                                     pre ... basic-unsafe-return))]
                              [basic-unsafe-lambda/result-values-assumed
                               #'(λ basic-params
                                   (let ()
                                     pre ... basic-unsafe-return/result-values-assumed))]
                              [basic-unsafe-lambda/result-values-assumed/no-tail
                               #'(λ basic-params
                                   (let ()
                                     pre ... basic-unsafe-return/result-values-assumed/no-tail))]
                              [kwd-lambda-name (gen-id 'kwd-lambda)]
                              [kwd-lambda #`(λ kwd-lam-params
                                              (with-contract-continuation-mark
                                               (cons blame neg-party)
                                               (let ()
                                                 pre ... kwd-return)))])
                  (cond
                    [(and (null? req-keywords) (null? opt-keywords))
                     #`(arrow:arity-checking-wrapper val 
                                                     blame neg-party
                                                     basic-lambda
                                                     basic-unsafe-lambda
                                                     basic-unsafe-lambda/result-values-assumed
                                                     basic-unsafe-lambda/result-values-assumed/no-tail
                                                     #,(and rngs (length rngs))
                                                     void
                                                     #,min-method-arity
                                                     #,max-method-arity
                                                     #,min-arity
                                                     #,(if dom-rest #f max-arity)
                                                     '(req-kwd ...)
                                                     '(opt-kwd ...))]
                    [(pair? req-keywords)
                     #`(arrow:arity-checking-wrapper val
                                                     blame neg-party
                                                     void #t #f #f #f
                                                     kwd-lambda
                                                     #,min-method-arity
                                                     #,max-method-arity
                                                     #,min-arity
                                                     #,(if dom-rest #f max-arity)
                                                     '(req-kwd ...)
                                                     '(opt-kwd ...))]
                    [else
                     #`(arrow:arity-checking-wrapper val 
                                                     blame neg-party
                                                     basic-lambda #t #f #f #f
                                                     kwd-lambda
                                                     #,min-method-arity
                                                     #,max-method-arity
                                                     #,min-arity
                                                     #,(if dom-rest #f max-arity)
                                                     '(req-kwd ...)
                                                     '(opt-kwd ...))])))))))))

(define (maybe-cons-kwd c x r neg-party)
  (if (eq? arrow:unspecified-dom x)
      r
      (cons (c x neg-party) r)))

(define (->-proj chaperone? ctc
                 ;; fields of the 'ctc' struct
                 min-arity doms kwd-infos rest pre? rngs post?
                 plus-one-arity-function chaperone-constructor
                 late-neg?)
  (define optionals-length (- (length doms) min-arity))
  (define mtd? #f) ;; not yet supported for the new contracts
  (define okay-to-do-only-arity-check?
    (and (not rest)
         (not pre?)
         (not post?)
         (null? kwd-infos)
         (not rngs)
         (andmap any/c? doms)
         (= optionals-length 0)))
  (λ (orig-blame)
    (define rng-blame (arrow:blame-add-range-context orig-blame))
    (define swapped-domain (blame-add-context orig-blame "the domain of" #:swap? #t))

    (define partial-doms
      (for/list ([dom (in-list doms)]
                 [n (in-naturals 1)])
        ((get/build-late-neg-projection dom)
         (blame-add-context orig-blame 
                            (format "the ~a argument of" (n->th n))
                            #:swap? #t))))
    (define partial-rest (and rest
                              ((get/build-late-neg-projection rest)
                               (blame-add-context orig-blame "the rest argument of"
                                                  #:swap? #t))))
    (define partial-ranges
      (if rngs
          (for/list ([rng (in-list rngs)])
            ((get/build-late-neg-projection rng) rng-blame))
          '()))
    (define partial-kwds 
      (for/list ([kwd-info (in-list kwd-infos)]
                 [kwd (in-list kwd-infos)])
        ((get/build-late-neg-projection (kwd-info-ctc kwd-info))
         (blame-add-context orig-blame
                            (format "the ~a argument of" (kwd-info-kwd kwd))
                            #:swap? #t))))
    (define man-then-opt-partial-kwds
      (append (for/list ([partial-kwd (in-list partial-kwds)]
                         [kwd-info (in-list kwd-infos)]
                         #:when (kwd-info-mandatory? kwd-info))
                partial-kwd)
              (for/list ([partial-kwd (in-list partial-kwds)]
                         [kwd-info (in-list kwd-infos)]
                         #:unless (kwd-info-mandatory? kwd-info))
                partial-kwd)))
    
    (define the-args (append partial-doms
                             (if partial-rest (list partial-rest) '())
                             man-then-opt-partial-kwds
                             partial-ranges))
    (define plus-one-constructor-args
      (append partial-doms
              man-then-opt-partial-kwds
              partial-ranges
              (if partial-rest (list partial-rest) '())))
    (define blame-party-info (arrow:get-blame-party-info orig-blame))
    (define (successfully-got-the-right-kind-of-function val neg-party)
      (define-values (chap/imp-func use-unsafe-chaperone-procedure?)
        (apply chaperone-constructor
               orig-blame val
               neg-party blame-party-info
               rngs the-args))
      (define chaperone-or-impersonate-procedure
        (if use-unsafe-chaperone-procedure?
            (if chaperone? unsafe-chaperone-procedure unsafe-impersonate-procedure)
            (if chaperone? chaperone-procedure impersonate-procedure)))
      (cond
        [chap/imp-func
         (if (or post? (not rngs))
             (chaperone-or-impersonate-procedure
              val
              chap/imp-func
              impersonator-prop:contracted ctc
              impersonator-prop:blame (blame-add-missing-party orig-blame neg-party))
             (chaperone-or-impersonate-procedure
              val
              chap/imp-func
              impersonator-prop:contracted ctc
              impersonator-prop:blame (blame-add-missing-party orig-blame neg-party)
              impersonator-prop:application-mark
              (cons arrow:tail-contract-key (list* neg-party blame-party-info rngs))))]
        [else val]))
    (cond
      [late-neg?
       (define (arrow-higher-order:lnp val neg-party)
         (cond
           [(do-arity-checking orig-blame val doms rest min-arity kwd-infos)
            =>
            (λ (f)
              (f neg-party))]
           [else
            (successfully-got-the-right-kind-of-function val neg-party)]))
       (if okay-to-do-only-arity-check?
           (λ (val neg-party)
             (cond
               [(procedure-arity-exactly/no-kwds val min-arity) val]
               [else (arrow-higher-order:lnp val neg-party)]))
           arrow-higher-order:lnp)]
      [else
       (define (arrow-higher-order:vfp val)
         (define-values (normal-proc proc-with-no-result-checking expected-number-of-results)
           (apply plus-one-arity-function orig-blame val plus-one-constructor-args))
         (wrapped-extra-arg-arrow 
          (cond
            [(do-arity-checking orig-blame val doms rest min-arity kwd-infos)
             =>
             values]
            [else
             (λ (neg-party)
               (successfully-got-the-right-kind-of-function val neg-party))])
          (if (equal? (procedure-result-arity val) expected-number-of-results)
              proc-with-no-result-checking
              normal-proc)))
       (if okay-to-do-only-arity-check?
           (λ (val)
             (cond
               [(procedure-arity-exactly/no-kwds val min-arity)
                (define-values (normal-proc proc-with-no-result-checking expected-number-of-results)
                  (apply plus-one-arity-function orig-blame val plus-one-constructor-args))
                (wrapped-extra-arg-arrow 
                 (λ (neg-party) val)
                 normal-proc)]
               [else (arrow-higher-order:vfp val)]))
           arrow-higher-order:vfp)])))

(define (procedure-arity-exactly/no-kwds val min-arity)
  (and (procedure? val)
       (equal? (procedure-arity val) min-arity)
       (let-values ([(man opt) (procedure-keywords val)])
         (and (null? man)
              (null? opt)))))
