#lang racket

(require "private/runtime.rkt")

(provide env envInt envString requireEnv)

(define (env name)
  (tesl-env name))

(define (envInt name default)
  (tesl-env-int-raw name default))

(define (envString name default)
  (tesl-env-string-raw name default))

;; requireEnv : String -> String — read an env var as a raw String, failing if it
;; is unset (the String-returning counterpart to `env`, which returns Maybe).
(define (requireEnv name)
  (tesl-env-raw name))
