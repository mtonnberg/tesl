#lang racket

; Sentinel bindings — importing Tesl.Telemetry makes telemetry usage explicit.
; The telemetry statement is ambient (no capability required). These markers
; ensure the module origin is visible in imports for discoverability.

(provide telemetry initTelemetry)

(define telemetry 'telemetry)
(define initTelemetry 'initTelemetry)
