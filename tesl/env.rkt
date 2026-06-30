#lang racket

(require "private/runtime.rkt"
         (only-in "../dsl/capability.rkt" define-capability))

;; Reading the environment is an effect; a function that calls env/envInt/
;; envString/requireEnv in its body must declare `requires [envRead]` (enforced by
;; validation_capabilities). Named envRead, not env, to avoid clashing with the
;; `env` function below.
(define-capability envRead)

(provide env envInt envString requireEnv envRead)

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
