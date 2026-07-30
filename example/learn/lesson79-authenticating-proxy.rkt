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
  (only-in tesl/tesl/prelude String)
  (only-in tesl/tesl/crypto Secret)
  (only-in tesl/tesl/proxy ProxyBound [Proxy.verifyBinding tesl_import_Proxy_verifyBinding])
)


(provide authorizeInternal authorizeInternal-signature)

(define/pow
  (internalOnly [bound : String ::: (ProxyBound bound)])
  #:returns String
  (thsl-src! "example/learn/lesson79-authenticating-proxy.tesl" 44 (list (cons 'bound *bound)) (lambda () (string-append "internal data for a proxy-bound request: " *bound))))

(define/pow
  (authorizeInternal [proxySecret : Secret] [presentedBinding : String])
  #:returns String
  (thsl-src! "example/learn/lesson79-authenticating-proxy.tesl" 51 (list (cons 'proxySecret *proxySecret) (cons 'presentedBinding *presentedBinding)) (lambda () (let/check ([tesl-checked-0 (tesl_import_Proxy_verifyBinding proxySecret presentedBinding)]) (let ([bound tesl-checked-0]) (raw-value (internalOnly bound)))))))
