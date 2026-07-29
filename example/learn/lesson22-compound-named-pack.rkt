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
  (only-in tesl/tesl/prelude Int String Fact)
)


(provide IsPositive checkIsPositive IsSmall checkIsSmall IsAdmin checkIsAdmin makePositive makePositiveAndSmall makeWithAdminCargo makeWithProofOnReturnLine validateAndReturn checkIsPositive-signature checkIsSmall-signature checkIsAdmin-signature makePositive-signature makePositiveAndSmall-signature makeWithAdminCargo-signature makeWithProofOnReturnLine-signature validateAndReturn-signature)

(define IsAdmin 'IsAdmin)
(define IsPositive 'IsPositive)
(define IsSmall 'IsSmall)
(define IsSmall2 'IsSmall2)
(define IsSmall3 'IsSmall3)
(define IsSmall4 'IsSmall4)

(define-checker
  (checkIsPositive [n : Integer])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 42 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositive n) #:value *n) (reject "must be positive" #:http-code 400)))))

(define-checker
  (checkIsSmall [n : Integer])
  #:returns [n : Integer ::: (IsSmall n)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 50 (list (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall n) #:value *n) (reject "must be less than 100" #:http-code 400)))))

(define-checker
  (checkIsSmall_2 [x : Integer] [n : Integer])
  #:returns [n : Integer ::: (IsSmall2 n)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 58 (list (cons 'x *x) (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall2 n) #:value *n) (reject "must be less than 100" #:http-code 400)))))

(define-checker
  (checkIsSmall_3 [x : Integer] [n : Integer])
  #:returns [n : Integer ::: (IsSmall3 x)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 66 (list (cons 'x *x) (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall3 x) #:value *n) (reject "must be less than 100" #:http-code 400)))))

(define-checker
  (checkIsSmall_4 [x : Integer] [n : Integer])
  #:returns [x : Integer ::: (IsSmall4 x)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 74 (list (cons 'x *x) (cons 'n *n)) (lambda () (if (< *n 100) (accept (IsSmall4 x) #:value *x) (reject "must be less than 100" #:http-code 400)))))

(define-checker
  (checkIsAdmin [user : String])
  #:returns [user : String ::: (IsAdmin user)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 82 (list (cons 'user *user)) (lambda () (if (tesl-equal? *user "admin") (accept (IsAdmin user) #:value *user) (reject "admin only" #:http-code 401)))))

(define/pow
  (makePositive [n : Integer ::: (IsPositive n)])
  #:returns (? Integer _entity ::: (IsPositive _entity))
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 91 (list (cons 'n *n)) (lambda () n)))

(define/pow
  (shouldWork_makePositive [n : Integer ::: (IsPositive n)])
  #:returns [n : Integer ::: (IsPositive n)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 95 (list (cons 'n *n)) (lambda () n)))

(define/pow
  (makePositiveAndSmall [n : Integer ::: ((IsPositive n) && (IsSmall n))])
  #:returns (? Integer _entity ::: ((IsPositive _entity) && (IsSmall _entity)))
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 101 (list (cons 'n *n)) (lambda () n)))

(define/pow
  (makeWithAdminCargo [n : Integer ::: (IsPositive n)] [user : String ::: (IsAdmin user)])
  #:returns (? Integer _entity ::: ((IsPositive _entity) && (IsAdmin user)))
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 108 (list (cons 'n *n) (cons 'user *user)) (lambda () (attach-proof n (detach-all-proof user)))))

(define-trusted
  (provePositive [n : Integer])
  #:returns (Fact (IsPositive n))
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 113 (list (cons 'n *n)) (lambda () (trusted-proof (IsPositive n)))))

(define-trusted
  (shouldWarn_1 [n : Integer])
  #:returns (Fact (IsPositive n))
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 116 (list (cons 'n *n)) (lambda () (trusted-proof (IsPositive n)))))

(define/pow
  (makeWithProofOnReturnLine [n : Integer] [user : String ::: (IsAdmin user)])
  #:returns (? Integer _entity ::: ((IsPositive _entity) && (IsAdmin user)))
  (let ([p (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 120 (list (cons 'n *n) (cons 'user *user)) (lambda () (provePositive n)))]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 121 (list (cons 'p *p) (cons 'n *n) (cons 'user *user)) (lambda () (attach-proof n (list p (detach-all-proof user)))))))

(define/pow
  (validateAndReturn [n : Integer])
  #:returns (? Integer _entity ::: (IsPositive _entity))
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 134 (list (cons 'n *n)) (lambda () (let ([x (- *n 3)]) (let/check ([tesl-checked-0 (checkIsPositive x)]) (let ([validated tesl-checked-0]) validated))))))

(module+ test
  (require rackunit)
  (test-case "simple named pack"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 182 (list) (lambda () 5)))
  (define tesl-checked-1 (checkIsPositive n))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let p: ~a" (check-fail-message tesl-checked-1)))
  (define p tesl-checked-1)
  (define result (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 184 (list (cons 'p p) (cons 'n n)) (lambda () (makePositive p))))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 185 (list (cons 'result result) (cons 'p p) (cons 'n n)) (lambda () result))) 5)
    ))
  )

  (test-case "compound entity proofs"
    (call-with-fresh-memory-db '() (lambda ()
  (define tesl-checked-2 ((check-and checkIsPositive checkIsSmall) 5))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let ps: ~a" (check-fail-message tesl-checked-2)))
  (define ps tesl-checked-2)
  (define result (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 193 (list (cons 'ps ps)) (lambda () (makePositiveAndSmall ps))))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 194 (list (cons 'result result) (cons 'ps ps)) (lambda () result))) 5)
    ))
  )

  (test-case "entity establish with cargo"
    (call-with-fresh-memory-db '() (lambda ()
  (define n (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 198 (list) (lambda () 5)))
  (define tesl-checked-3 (checkIsPositive n))
  (when (check-fail? tesl-checked-3)
    (raise-user-error 'tesl-test "unexpected failure in let p: ~a" (check-fail-message tesl-checked-3)))
  (define p tesl-checked-3)
  (define adminStr (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 200 (list (cons 'p p) (cons 'n n)) (lambda () "admin")))
  (define tesl-checked-4 (checkIsAdmin adminStr))
  (when (check-fail? tesl-checked-4)
    (raise-user-error 'tesl-test "unexpected failure in let admin: ~a" (check-fail-message tesl-checked-4)))
  (define admin tesl-checked-4)
  (define result (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 202 (list (cons 'admin admin) (cons 'adminStr adminStr) (cons 'p p) (cons 'n n)) (lambda () (makeWithAdminCargo p admin))))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 203 (list (cons 'result result) (cons 'admin admin) (cons 'adminStr adminStr) (cons 'p p) (cons 'n n)) (lambda () result))) 5)
    ))
  )

  (test-case "establish on return line"
    (call-with-fresh-memory-db '() (lambda ()
  (define userId (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 207 (list) (lambda () "admin")))
  (define tesl-checked-5 (checkIsAdmin userId))
  (when (check-fail? tesl-checked-5)
    (raise-user-error 'tesl-test "unexpected failure in let userId_with_Proof: ~a" (check-fail-message tesl-checked-5)))
  (define userId_with_Proof tesl-checked-5)
  (define result (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 209 (list (cons 'userId_with_Proof userId_with_Proof) (cons 'userId userId)) (lambda () (makeWithProofOnReturnLine 42 userId_with_Proof))))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 210 (list (cons 'result result) (cons 'userId_with_Proof userId_with_Proof) (cons 'userId userId)) (lambda () result))) 42)
    ))
  )

  (test-case "validate and return"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 214 (list) (lambda () (validateAndReturn 5))))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson22-compound-named-pack.tesl" 215 (list (cons 'result result)) (lambda () result))) 2)
    ))
  )

)
