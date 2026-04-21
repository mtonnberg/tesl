#lang racket

(require "private/runtime.rkt")

(provide
 cli.args
 lookupPortArgument)

(define cli.args (tesl-cli-args))

(define (lookupPortArgument [args (tesl-cli-args)])
  (tesl-lookup-port-argument args))
