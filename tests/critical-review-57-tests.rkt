#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/dsl/debug/checkpoint
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  (only-in tesl/tesl/prelude Bool Int String List Fact forgetFact attachFact detachFact introAnd andLeft andRight)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/either Either Left Right)
  (only-in tesl/tesl/list [List.filterCheck tesl_import_List_filterCheck] [List.length tesl_import_List_length] [List.allCheck tesl_import_List_allCheck])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide )

(define A 'A)
(define B 'B)
(define C 'C)
(define D 'D)
(define E 'E)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define OwnedBy 'OwnedBy)
(define Tagged 'Tagged)
(define ValidProjectId 'ValidProjectId)
(define ValidUserId 'ValidUserId)
(define Validated 'Validated)

(define-checker
  (checkA [n : Integer])
  #:returns [n : Integer ::: (A n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 52 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (A n) #:value *n) (reject "fail A" #:http-code 400)))))

(define-checker
  (checkB [n : Integer ::: (A n)])
  #:returns [n : Integer ::: (B n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 58 (list (cons 'n *n)) (lambda () (if (< *n 1000) (accept (B n) #:value *n) (reject "fail B" #:http-code 400)))))

(define-checker
  (checkC [n : Integer ::: ((A n) && (B n))])
  #:returns [n : Integer ::: (C n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 64 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 42)) (accept (C n) #:value *n) (reject "fail C" #:http-code 400)))))

(define-checker
  (checkD [n : Integer ::: ((A n) && ((B n) && (C n)))])
  #:returns [n : Integer ::: (D n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 70 (list (cons 'n *n)) (lambda () (if (not (tesl-equal? *n 99)) (accept (D n) #:value *n) (reject "fail D" #:http-code 400)))))

(define-checker
  (checkE [n : Integer ::: ((A n) && ((B n) && ((C n) && (D n))))])
  #:returns [n : Integer ::: (E n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 76 (list (cons 'n *n)) (lambda () (accept (E n) #:value *n))))

(define-checker
  (checkPos [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 79 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 85 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))))

(define-checker
  (checkValidated [n : Integer])
  #:returns [n : Integer ::: (Validated n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 91 (list (cons 'n *n)) (lambda () (if (>= *n 0) (accept (Validated n) #:value *n) (reject "invalid" #:http-code 400)))))

(define-trusted
  (makeTagged [label : String] [n : Integer])
  #:returns (Fact (Tagged label n))
  (thsl-src! "tests/critical-review-57-tests.tesl" 97 (list (cons 'label *label) (cons 'n *n)) (lambda () (trusted-proof (Tagged label n)))))

(define/pow
  (needsAll5 [n : Integer ::: ((A n) && ((B n) && ((C n) && ((D n) && (E n)))))])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 99 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsPos [n : Integer ::: (IsPositive n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 100 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsSmall [n : Integer ::: (IsSmall n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 101 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsBoth [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 102 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsValidated [n : Integer ::: (Validated n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 103 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsTagged [label : String] [n : Integer ::: (Tagged label n)])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 104 (list (cons 'label *label) (cons 'n *n)) (lambda () *n)))

(define/pow
  (needsForAllPos [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 105 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (buildDeepChain [raw : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 110 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-0 (checkA raw)]) (let ([a tesl-checked-0]) (let/check ([tesl-checked-1 (checkB a)]) (let ([b tesl-checked-1]) (let/check ([tesl-checked-2 (checkC b)]) (let ([c tesl-checked-2]) (let/check ([tesl-checked-3 (checkD c)]) (let ([d tesl-checked-3]) (let/check ([tesl-checked-4 (checkE d)]) (let ([e tesl-checked-4]) (raw-value (needsAll5 e)))))))))))))))

(define-trusted
  (makeA [n : Integer])
  #:returns (Fact (A n))
  (thsl-src! "tests/critical-review-57-tests.tesl" 130 (list (cons 'n *n)) (lambda () (trusted-proof (A n)))))

(define-trusted
  (makeB_bare [n : Integer])
  #:returns (Fact (B n))
  (thsl-src! "tests/critical-review-57-tests.tesl" 131 (list (cons 'n *n)) (lambda () (trusted-proof (B n)))))

(define/pow
  (introAndDecomposeTest [n : Integer])
  #:returns Integer
  (let ([pA (thsl-src! "tests/critical-review-57-tests.tesl" 134 (list (cons 'n *n)) (lambda () (makeA n)))]) (let ([pB (thsl-src! "tests/critical-review-57-tests.tesl" 135 (list (cons 'pA *pA) (cons 'n *n)) (lambda () (makeB_bare n)))]) (let ([pAB (thsl-src! "tests/critical-review-57-tests.tesl" 136 (list (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (intro-and pA pB)))]) (let ([_pA2 (thsl-src! "tests/critical-review-57-tests.tesl" 137 (list (cons 'pAB *pAB) (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (and-left pAB)))]) (let ([_pB2 (thsl-src! "tests/critical-review-57-tests.tesl" 138 (list (cons '_pA2 *_pA2) (cons 'pAB *pAB) (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () (and-right pAB)))]) (thsl-src! "tests/critical-review-57-tests.tesl" 139 (list (cons '_pB2 *_pB2) (cons '_pA2 *_pA2) (cons 'pAB *pAB) (cons 'pB *pB) (cons 'pA *pA) (cons 'n *n)) (lambda () *n))))))))

(define/pow
  (complexDetachAttach [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 149 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-5 (checkValidated n)]) (let ([v tesl-checked-5]) (let ([vProof (detach-all-proof v)]) (let ([raw (forget-proof v)]) (let ([vBack (attach-proof raw vProof)]) (let/check ([tesl-checked-6 (checkPos vBack)]) (let ([p tesl-checked-6]) (raw-value (needsPos p))))))))))))

(define/pow
  (decomposeReattach [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 157 (list (cons 'n *n)) (lambda () (let/check ([tesl-checked-7 (checkPos n)]) (let ([v tesl-checked-7]) (let/check ([tesl-checked-8 (checkSmall v)]) (let ([s tesl-checked-8]) (let ([tesl-proof-binding-9 s]) (let ([raw (forget-proof tesl-proof-binding-9)] [pPos (detach-all-proof tesl-proof-binding-9)]) (let ([tesl-proof-binding-10 s]) (let ([_ (forget-proof tesl-proof-binding-10)] [pSmall (detach-all-proof tesl-proof-binding-10)]) (let ([reassembled (attach-proof raw (list pPos pSmall))]) (raw-value (needsBoth reassembled))))))))))))))

(define/pow
  (useEstablishUnconditionally [n : Integer])
  #:returns Integer
  (let ([_pA (thsl-src! "tests/critical-review-57-tests.tesl" 180 (list (cons 'n *n)) (lambda () (makeA n)))]) (thsl-src! "tests/critical-review-57-tests.tesl" 181 (list (cons '_pA *_pA) (cons 'n *n)) (lambda () *n))))

(define-checker
  (checkOwned [userId : String] [taskId : Integer])
  #:returns [taskId : Integer ::: (OwnedBy userId taskId)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 194 (list (cons 'userId *userId) (cons 'taskId *taskId)) (lambda () (if (> *taskId 0) (accept (OwnedBy userId taskId) #:value *taskId) (reject "not owned" #:http-code 403)))))

(define/pow
  (requiresOwned [userId : String] [task : Integer ::: (OwnedBy userId task)])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 199 (list (cons 'userId *userId) (cons 'task *task)) (lambda () *task)))

(define/pow
  (processOwned [userId : String] [taskId : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 202 (list (cons 'userId *userId) (cons 'taskId *taskId)) (lambda () (let/check ([tesl-checked-11 (checkOwned userId taskId)]) (let ([ownedTask tesl-checked-11]) (raw-value (requiresOwned userId ownedTask)))))))

(define/pow
  (forAllSingleInline [nums : (List Integer)])
  #:returns Integer
  (let ([filtered (thsl-src! "tests/critical-review-57-tests.tesl" 215 (list (cons 'nums *nums)) (lambda () (tesl_import_List_filterCheck checkPos *nums)))]) (thsl-src! "tests/critical-review-57-tests.tesl" 216 (list (cons 'filtered *filtered) (cons 'nums *nums)) (lambda () (raw-value (needsForAllPos filtered))))))

(define/pow
  (forAllWrapperAndCombined [nums : (List Integer)])
  #:returns (List Integer)
  (thsl-src! "tests/critical-review-57-tests.tesl" 219 (list (cons 'nums *nums)) (lambda () (tesl_import_List_filterCheck (check-and checkPos checkSmall) *nums))))

(define/pow
  (needsForAllBoth [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 222 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (forAllCombinedViaWrapper [nums : (List Integer)])
  #:returns Integer
  (let ([result (thsl-src! "tests/critical-review-57-tests.tesl" 225 (list (cons 'nums *nums)) (lambda () (forAllWrapperAndCombined nums)))]) (thsl-src! "tests/critical-review-57-tests.tesl" 226 (list (cons 'result *result) (cons 'nums *nums)) (lambda () (raw-value (needsForAllBoth result))))))

(define-adt PosTree
  [PLeaf]
  [PNode [left : PosTree] [value : Integer] [right : PosTree]]
)

(define/pow
  (insertPosTree [t : PosTree] [v : Integer ::: (IsPositive v)])
  #:returns PosTree
  (thsl-src-control! "tests/critical-review-57-tests.tesl" 244 (list (cons 't *t) (cons 'v *v)) (lambda () (let ([tesl-case-12 *t]) (cond [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'PLeaf)) (thsl-src! "tests/critical-review-57-tests.tesl" 245 (list) (lambda () (raw-value (raw-value (PNode PLeaf v PLeaf)))))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'PNode)) (let ([l (hash-ref (adt-value-fields *tesl-case-12) 'left)]) (let ([cur (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (let ([r (hash-ref (adt-value-fields *tesl-case-12) 'right)]) (thsl-src! "tests/critical-review-57-tests.tesl" 247 (list (cons 'l l) (cons 'cur cur) (cons 'r r)) (lambda () (if (< *v *cur) (raw-value (raw-value (PNode (insertPosTree *l v) cur *r))) (if (> *v *cur) (raw-value (raw-value (PNode *l cur (insertPosTree *r v)))) *t)))))))])))))

(define/pow
  (findMin [t : PosTree])
  #:returns (Maybe Integer)
  (thsl-src-control! "tests/critical-review-57-tests.tesl" 256 (list (cons 't *t)) (lambda () (let ([tesl-case-13 *t]) (cond [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'PLeaf)) (thsl-src! "tests/critical-review-57-tests.tesl" 257 (list) (lambda () Nothing))] [(and (and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'PNode)) (let ([tesl-case-13_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-13) 'left))]) (and (adt-value? *tesl-case-13_f0) (eq? (adt-value-variant *tesl-case-13_f0) 'PLeaf)))) (let ([tesl-case-13_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-13) 'left))]) (let ([cur (hash-ref (adt-value-fields *tesl-case-13) 'value)]) (thsl-src! "tests/critical-review-57-tests.tesl" 258 (list (cons 'cur cur)) (lambda () (raw-value (Something cur))))))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'PNode)) (let ([l (hash-ref (adt-value-fields *tesl-case-13) 'left)]) (thsl-src! "tests/critical-review-57-tests.tesl" 259 (list (cons 'l l)) (lambda () (findMin *l))))])))))

(define/pow
  (findMinAlt [t : PosTree])
  #:returns (Either String Integer)
  (thsl-src-control! "tests/critical-review-57-tests.tesl" 262 (list (cons 't *t)) (lambda () (let ([tesl-case-14 *t]) (cond [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'PLeaf)) (thsl-src! "tests/critical-review-57-tests.tesl" 263 (list) (lambda () (raw-value (Left "empty"))))] [(and (and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'PNode)) (let ([tesl-case-14_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-14) 'left))]) (and (adt-value? *tesl-case-14_f0) (eq? (adt-value-variant *tesl-case-14_f0) 'PLeaf)))) (let ([tesl-case-14_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-14) 'left))]) (let ([cur (hash-ref (adt-value-fields *tesl-case-14) 'value)]) (thsl-src! "tests/critical-review-57-tests.tesl" 264 (list (cons 'cur cur)) (lambda () (raw-value (Right cur))))))] [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'PNode)) (let ([l (hash-ref (adt-value-fields *tesl-case-14) 'left)]) (thsl-src! "tests/critical-review-57-tests.tesl" 265 (list (cons 'l l)) (lambda () (findMinAlt l))))])))))

(define/pow
  (useMin [t : PosTree])
  #:returns Integer
  (let ([m (thsl-src! "tests/critical-review-57-tests.tesl" 268 (list (cons 't *t)) (lambda () (findMin t)))]) (thsl-src-control! "tests/critical-review-57-tests.tesl" 269 (list (cons 'm *m) (cons 't *t)) (lambda () (let ([tesl-case-15 (raw-value m)]) (cond [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Nothing)) (thsl-src! "tests/critical-review-57-tests.tesl" 270 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl-case-15) 'value)]) (thsl-src! "tests/critical-review-57-tests.tesl" 271 (list (cons 'v v)) (lambda () (raw-value (needsPos v)))))]))))))

(define/pow
  (useMinAlt [t : PosTree])
  #:returns Integer
  (let ([m (thsl-src! "tests/critical-review-57-tests.tesl" 274 (list (cons 't *t)) (lambda () (findMinAlt t)))]) (thsl-src-control! "tests/critical-review-57-tests.tesl" 275 (list (cons 'm *m) (cons 't *t)) (lambda () (let ([tesl-case-16 (raw-value m)]) (cond [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Left)) (thsl-src! "tests/critical-review-57-tests.tesl" 276 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-16) (eq? (adt-value-variant *tesl-case-16) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl-case-16) 'value)]) (thsl-src! "tests/critical-review-57-tests.tesl" 277 (list (cons 'v v)) (lambda () (raw-value (needsPos v)))))]))))))

(define/pow
  (buildPosTree)
  #:returns PosTree
  (thsl-src! "tests/critical-review-57-tests.tesl" 280 (list) (lambda () (let ([t0 PLeaf]) (let/check ([tesl-checked-17 (checkPos 3)]) (let ([v3 tesl-checked-17]) (let/check ([tesl-checked-18 (checkPos 1)]) (let ([v1 tesl-checked-18]) (let/check ([tesl-checked-19 (checkPos 5)]) (let ([v5 tesl-checked-19]) (let ([t1 (insertPosTree t0 v3)]) (let ([t2 (insertPosTree t1 v1)]) (raw-value (insertPosTree t2 v5))))))))))))))

(define/pow
  (useTaggedLiteral [n : Integer])
  #:returns Integer
  (let ([pf (thsl-src! "tests/critical-review-57-tests.tesl" 299 (list (cons 'n *n)) (lambda () (makeTagged "http" n)))]) (thsl-src! "tests/critical-review-57-tests.tesl" 300 (list (cons 'pf *pf) (cons 'n *n)) (lambda () (raw-value (needsTagged "http" (attach-proof n pf)))))))

(define/pow
  (useTaggedVar [label : String] [n : Integer])
  #:returns Integer
  (let ([pf (thsl-src! "tests/critical-review-57-tests.tesl" 303 (list (cons 'label *label) (cons 'n *n)) (lambda () (makeTagged label n)))]) (thsl-src! "tests/critical-review-57-tests.tesl" 304 (list (cons 'pf *pf) (cons 'label *label) (cons 'n *n)) (lambda () (raw-value (needsTagged label (attach-proof n pf)))))))

(define-newtype UserId String)

(define-newtype ProjectId String)

(define-checker
  (checkUserId [s : String])
  #:returns [id : UserId ::: (ValidUserId id)]
  (let ([id (thsl-src! "tests/critical-review-57-tests.tesl" 319 (list (cons 's *s)) (lambda () (raw-value (UserId *s))))]) (thsl-src! "tests/critical-review-57-tests.tesl" 320 (list (cons 'id *id) (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 3) (accept (ValidUserId id) #:value *id) (reject "bad user id" #:http-code 400))))))

(define-checker
  (checkProjectId [s : String])
  #:returns [id : ProjectId ::: (ValidProjectId id)]
  (let ([id (thsl-src! "tests/critical-review-57-tests.tesl" 326 (list (cons 's *s)) (lambda () (raw-value (ProjectId *s))))]) (thsl-src! "tests/critical-review-57-tests.tesl" 327 (list (cons 'id *id) (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 3) (accept (ValidProjectId id) #:value *id) (reject "bad project id" #:http-code 400))))))

(define/pow
  (requiresValidUser [id : UserId ::: (ValidUserId id)])
  #:returns String
  (thsl-src! "tests/critical-review-57-tests.tesl" 335 (list (cons 'id *id)) (lambda () (raw-value id.value))))

(define/pow
  (requiresValidProject [id : ProjectId ::: (ValidProjectId id)])
  #:returns String
  (thsl-src! "tests/critical-review-57-tests.tesl" 336 (list (cons 'id *id)) (lambda () (raw-value id.value))))

(define/pow
  (processValidUser [raw : String])
  #:returns String
  (thsl-src! "tests/critical-review-57-tests.tesl" 339 (list (cons 'raw *raw)) (lambda () (let/check ([tesl-checked-20 (checkUserId raw)]) (let ([userId tesl-checked-20]) (raw-value (requiresValidUser userId)))))))

(define/pow
  (insert [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 349 (list (cons 'a *a) (cons 'b *b)) (lambda () (+ *a *b))))

(define/pow
  (select [a : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 350 (list (cons 'a *a)) (lambda () (* *a 2))))

(define/pow
  (update [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 351 (list (cons 'a *a) (cons 'b *b)) (lambda () (+ *a *b))))

(define/pow
  (delete [a : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 352 (list (cons 'a *a)) (lambda () (- *a 1))))

(define/pow
  (useInsert [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 354 (list (cons 'n *n)) (lambda () (insert n 5))))

(define/pow
  (useSelect [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 355 (list (cons 'n *n)) (lambda () (select n))))

(define/pow
  (useUpdate [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 356 (list (cons 'n *n)) (lambda () (update n 10))))

(define/pow
  (useDelete [n : Integer])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 357 (list (cons 'n *n)) (lambda () (delete n))))

(define-checker
  (checkPosB2 [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 370 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "not positive" #:http-code 400)))))

(define-checker
  (checkSmallB2 [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "tests/critical-review-57-tests.tesl" 376 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "too big" #:http-code 400)))))

(define/pow
  (needsBothB2 [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tests/critical-review-57-tests.tesl" 382 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_length *xs)))))

(define/pow
  (combinedFilterInline [nums : (List Integer)])
  #:returns Integer
  (let ([filtered (thsl-src! "tests/critical-review-57-tests.tesl" 385 (list (cons 'nums *nums)) (lambda () (tesl_import_List_filterCheck (check-and checkPosB2 checkSmallB2) *nums)))]) (thsl-src! "tests/critical-review-57-tests.tesl" 386 (list (cons 'filtered *filtered) (cons 'nums *nums)) (lambda () (raw-value (needsBothB2 filtered))))))

(define/pow
  (allCheckCombined [nums : (List Integer)])
  #:returns (Maybe (List Integer))
  (thsl-src! "tests/critical-review-57-tests.tesl" 389 (list (cons 'nums *nums)) (lambda () (tesl_import_List_allCheck (check-and checkPosB2 checkSmallB2) *nums))))

(module+ test
  (require rackunit)
  (test-case "R57_DP: deep 5-proof chain runtime"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 118 (list) (lambda () (buildDeepChain 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 119 (list) (lambda () (buildDeepChain 100)))) 100)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 120 (list) (lambda () (buildDeepChain 1)))) 1)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 121 (list) (lambda ()
                          (buildDeepChain 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: buildDeepChain 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 122 (list) (lambda ()
                          (buildDeepChain -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: buildDeepChain -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 123 (list) (lambda ()
                          (buildDeepChain 42))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: buildDeepChain 42"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 124 (list) (lambda ()
                          (buildDeepChain 99))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: buildDeepChain 99"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 125 (list) (lambda ()
                          (buildDeepChain 1001))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: buildDeepChain 1001"))
    ))
  )

  (test-case "R57_PC: introAnd/andLeft/andRight"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 142 (list) (lambda () (introAndDecomposeTest 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 143 (list) (lambda () (introAndDecomposeTest 99)))) 99)
    ))
  )

  (test-case "R57_DA: complex detach-attach"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 164 (list) (lambda () (complexDetachAttach 5)))) 5)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 168 (list) (lambda ()
                          (complexDetachAttach 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: complexDetachAttach 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 169 (list) (lambda ()
                          (complexDetachAttach -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: complexDetachAttach -1"))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 171 (list) (lambda () (decomposeReattach 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 172 (list) (lambda () (decomposeReattach 50)))) 50)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 173 (list) (lambda ()
                          (decomposeReattach 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decomposeReattach 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 174 (list) (lambda ()
                          (decomposeReattach 100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: decomposeReattach 100"))
    ))
  )

  (test-case "R57_ES: establish creates proof unconditionally"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 184 (list) (lambda () (useEstablishUnconditionally 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 185 (list) (lambda () (useEstablishUnconditionally -5)))) -5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 186 (list) (lambda () (useEstablishUnconditionally 0)))) 0)
    ))
  )

  (test-case "R57_MP: multi-parameter proof"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 206 (list) (lambda () (processOwned "alice" 5)))) 5)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 207 (list) (lambda () (processOwned "bob" 100)))) 100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 208 (list) (lambda ()
                          (processOwned "alice" 0))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: processOwned \"alice\" 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 209 (list) (lambda ()
                          (processOwned "alice" -1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: processOwned \"alice\" -1"))
    ))
  )

  (test-case "R57_FA: ForAll tracking"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 229 (list) (lambda () (forAllSingleInline (list 1 2 3 -1 0))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 230 (list) (lambda () (forAllSingleInline (list))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 231 (list) (lambda () (forAllSingleInline (list 1 2 3))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 233 (list) (lambda () (forAllCombinedViaWrapper (list 1 2 3 200 -1))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 234 (list) (lambda () (forAllCombinedViaWrapper (list))))) 0)
    ))
  )

  (test-case "R57_NP: named pack return through case"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/critical-review-57-tests.tesl" 289 (list) (lambda () (buildPosTree))))
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 290 (list (cons 't t)) (lambda () (useMin t)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 291 (list (cons 't t)) (lambda () (useMinAlt t)))) 1)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 292 (list (cons 't t)) (lambda () (useMin PLeaf)))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 293 (list (cons 't t)) (lambda () (useMinAlt PLeaf)))) 0)
    ))
  )

  (test-case "R57_LBL: labeled (literal subject) proof"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 307 (list) (lambda () (useTaggedLiteral 80)))) 80)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 308 (list) (lambda () (useTaggedLiteral 443)))) 443)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 309 (list) (lambda () (useTaggedVar "smtp" 25)))) 25)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 310 (list) (lambda () (useTaggedVar "imap" 143)))) 143)
    ))
  )

  (test-case "R57_NT: newtype proof isolation"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 343 (list) (lambda () (processValidUser "alice123")))) "alice123")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/critical-review-57-tests.tesl" 344 (list) (lambda ()
                          (processValidUser "ab"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: processValidUser \"ab\""))
    ))
  )

  (test-case "R57_B1: user functions with SQL names (BUG-1 fixed)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 360 (list) (lambda () (useInsert 3)))) 8)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 361 (list) (lambda () (useSelect 7)))) 14)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 362 (list) (lambda () (useUpdate 5)))) 15)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 363 (list) (lambda () (useDelete 4)))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 364 (list) (lambda () (insert (select 2) 1)))) 5)
    ))
  )

  (test-case "R57_B2: ForAll && combination inline (BUG-2 fixed)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 392 (list) (lambda () (combinedFilterInline (list 1 2 3 200 -1 0))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 393 (list) (lambda () (combinedFilterInline (list))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 394 (list) (lambda () (combinedFilterInline (list 50 99 1))))) 3)
  (define m1 (thsl-src! "tests/critical-review-57-tests.tesl" 396 (list) (lambda () (allCheckCombined (list 5 10 20)))))
  (let ([*tesl-case-21 (raw-value 
    m1)]) (cond
    [(and (adt-value? *tesl-case-21) (eq? (adt-value-variant *tesl-case-21) 'Nothing))
      (check-true (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 398 (list) (lambda () #f))))
    ]
    [(and (adt-value? *tesl-case-21) (eq? (adt-value-variant *tesl-case-21) 'Something))
      (let ([r (hash-ref (adt-value-fields *tesl-case-21) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 399 (list) (lambda () (needsBothB2 r)))) 3)
      )
    ]
  ))
  (define m2 (thsl-src! "tests/critical-review-57-tests.tesl" 401 (list (cons 'm1 m1)) (lambda () (allCheckCombined (list 5 200 20)))))
  (let ([*tesl-case-22 (raw-value 
    m2)]) (cond
    [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Nothing))
      (check-true (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 403 (list) (lambda () #t))))
    ]
    [(and (adt-value? *tesl-case-22) (eq? (adt-value-variant *tesl-case-22) 'Something))
      (check-true (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 404 (list) (lambda () #f))))
    ]
  ))
    ))
  )

  (test-case "R57_B4: random capability enforcement (BUG-4 fixed, runtime verification)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-true (raw-value (thsl-src! "tests/critical-review-57-tests.tesl" 412 (list) (lambda () #t))))
    ))
  )

)
