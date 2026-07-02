#lang racket

(require rackunit
         racket/file
         racket/match
         racket/port
         racket/runtime-path
         racket/string
         "../dsl/check.rkt"
         (only-in "../tesl/maybe.rkt" Something Nothing)
         "../example/document-api.rkt")

(define-runtime-path check-path "../dsl/check.rkt")
(define-runtime-path tesl-compiler-path "../compiler/_build/default/bin/main.exe")
(define-runtime-path todo-api-source-path "../example/todo-api.tesl")

(define (write-temp-file pattern contents)
  (define output-path (make-temporary-file pattern))
  (call-with-output-file output-path
    #:exists 'truncate
    (lambda (out)
      (display contents out)))
  output-path)

(define (run-command executable args)
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f (path->string executable) args))
  (close-output-port stdin)
  (define out (port->string stdout))
  (define err (port->string stderr))
  (subprocess-wait proc)
  (values (subprocess-status proc) out err))

(define (compile-tesl-module source-path)
  (define-values (status generated errors)
    (run-command tesl-compiler-path
                 (list (path->string source-path))))
  (unless (zero? status)
    (error 'port-test
           (string-append "tesl compiler failed: "
                          (if (string=? (string-trim errors) "")
                              "no compiler stderr"
                              (string-trim errors)))))
  (write-temp-file "tesl-port-test-~a.rkt" generated))

(define todo-api-compiled-path
  (compile-tesl-module todo-api-source-path))

(define (todo-module-value symbol-name)
  (dynamic-require `(file ,(path->string todo-api-compiled-path)) symbol-name))

(define (todo-internal symbol-name)
  (dynamic-require `(file ,(path->string todo-api-compiled-path)) #f)
  (parameterize ([current-namespace (module->namespace `(file ,(path->string todo-api-compiled-path)))])
    (namespace-variable-value
     symbol-name
     #t
     (lambda ()
       (error 'port-test "missing internal binding ~a" symbol-name)))))

(define todo-resolve-example-port
  (todo-module-value 'resolveExamplePort))

(define parse-todo-port-string
  (todo-internal 'parsePortString))

(define (todo-export symbol-name)
  (dynamic-require `(file ,(path->string check-path)) symbol-name))

(define todo-check-ok? (todo-export 'check-ok?))
(define todo-check-ok-value (todo-export 'check-ok-value))
(define todo-check-fail? (todo-export 'check-fail?))
(define todo-facts-of (todo-export 'facts-of))

(check-equal? (resolve-example-port '() #:tesl-port #f #:port #f) 8085)
(check-equal? (resolve-example-port '("--port" "9001") #:tesl-port "9002" #:port "9003") 9001)
(check-equal? (resolve-example-port '("--port=9004") #:tesl-port "9002" #:port "9003") 9004)
(check-equal? (resolve-example-port '() #:tesl-port "9010" #:port "9020") 9010)
(check-equal? (resolve-example-port '() #:tesl-port #f #:port "9020") 9020)
(check-exn exn:fail:user? (lambda () (resolve-example-port '("--port") #:tesl-port #f #:port #f)))
(check-exn exn:fail:user? (lambda () (resolve-example-port '() #:tesl-port "abc" #:port #f)))
(check-exn exn:fail:user? (lambda () (resolve-example-port '() #:tesl-port #f #:port "70000")))

;; resolveExamplePort now takes (teslPort portEnv) — the CLI arg was removed with
;; the whole Tesl.Cli module (config is env-vars-only). Precedence:
;; TESL_TODO_API_PORT (teslPort) → PORT (portEnv) → default 8086.
(check-equal? (todo-resolve-example-port Nothing Nothing) 8086)
(check-equal? (todo-resolve-example-port (Something "9102") (Something "9103")) 9102)
(check-equal? (todo-resolve-example-port (Something "9110") (Something "9120")) 9110)
(check-equal? (todo-resolve-example-port Nothing (Something "9120")) 9120)

(define parsed-todo-port
  (parse-todo-port-string "9201" "test"))
(check-true (todo-check-ok? parsed-todo-port))
(check-equal? (todo-check-ok-value parsed-todo-port) 9201)
(match (todo-facts-of parsed-todo-port)
  [`((ValidPort ,token))
   (check-true (symbol? token))]
  [other
   (error 'port-test "unexpected todo port proof shape: ~a" other)])

(check-true (todo-check-fail? (todo-resolve-example-port (Something "abc") Nothing)))
(check-true (todo-check-fail? (todo-resolve-example-port Nothing (Something "70000"))))
(check-true (todo-check-fail? (parse-todo-port-string "abc" "test")))
(check-true (todo-check-fail? (parse-todo-port-string "70000" "test")))
