#lang racket

(require "private/runtime.rkt")

(provide env envInt envString)

(define (env name)
  (tesl-env name))

(define (envInt name default)
  (tesl-env-int-raw name default))

(define (envString name default)
  (tesl-env-string-raw name default))
