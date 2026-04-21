#lang racket

(require "private/runtime.rkt")

(provide env envInt)

(define (env name)
  (tesl-env name))

(define (envInt name default)
  (tesl-env-int-raw name default))
