#lang racket

(require json
         (for-syntax racket/base syntax/parse))

(provide
 (struct-out telemetry-event)
 current-telemetry-context
 current-telemetry-events
 current-telemetry-service-name
 current-telemetry-endpoint
 current-telemetry-consumers
 make-console-telemetry-consumer
 init-opentelemetry!
 call-with-telemetry-context
 telemetry-event!
 log-info!
 drain-telemetry!)

(struct telemetry-event (service-name endpoint message attributes timestamp-ms) #:transparent)

(define current-telemetry-context (make-parameter '()))
(define current-telemetry-events (make-parameter '()))
(define current-telemetry-service-name (make-parameter "tesl"))
(define current-telemetry-endpoint (make-parameter #f))
(define current-telemetry-consumers (make-parameter '()))
(define global-telemetry-log (box '()))

(define (telemetry-key->json-key key)
  (cond
    [(symbol? key) key]
    [(keyword? key) (string->symbol (keyword->string key))]
    [(bytes? key) (string->symbol (bytes->string/utf-8 key))]
    [(string? key) (string->symbol key)]
    [else (string->symbol (~a key))]))

(define (telemetry-value->jsexpr value)
  (cond
    [(hash? value)
     (for/hash ([(key item) (in-hash value)])
       (values (telemetry-key->json-key key)
               (telemetry-value->jsexpr item)))]
    [(list? value)
     (map telemetry-value->jsexpr value)]
    [(vector? value)
     (list->vector (map telemetry-value->jsexpr (vector->list value)))]
    [(symbol? value)
     (symbol->string value)]
    [(keyword? value)
     (keyword->string value)]
    [(bytes? value)
     (bytes->string/utf-8 value)]
    [else value]))

(define (telemetry-event->jsexpr event)
  (hash 'service (telemetry-event-service-name event)
        'endpoint (or (telemetry-event-endpoint event) "")
        'message (telemetry-event-message event)
        'timestampMs (telemetry-event-timestamp-ms event)
        'attributes
        (for/hash ([entry (in-list (telemetry-event-attributes event))])
          (values (telemetry-key->json-key (car entry))
                  (telemetry-value->jsexpr (cdr entry))))))

(define (make-console-telemetry-consumer #:port [port (current-error-port)])
  (lambda (event)
    (displayln (jsexpr->string (telemetry-event->jsexpr event)) port)
    (flush-output port)))

(define (init-opentelemetry! #:service-name service-name
                             #:endpoint [endpoint #f]
                             #:console? [console? #f]
                             #:console-port [console-port (current-error-port)]
                             #:consumers [consumers '()])
  (current-telemetry-service-name service-name)
  (current-telemetry-endpoint endpoint)
  (current-telemetry-context '())
  (current-telemetry-events '())
  (current-telemetry-consumers
   (append consumers
           (if console?
               (list (make-console-telemetry-consumer #:port console-port))
               '())))
  (set-box! global-telemetry-log '())
  (void))

(define (call-with-telemetry-context additions thunk)
  (parameterize ([current-telemetry-context
                  (append (current-telemetry-context) additions)])
    (thunk)))

(define (emit-telemetry-event! message attributes)
  (define event
    (telemetry-event (current-telemetry-service-name)
                     (current-telemetry-endpoint)
                     message
                     (append (current-telemetry-context) attributes)
                     (current-inexact-milliseconds)))
  (current-telemetry-events (cons event (current-telemetry-events)))
  (set-box! global-telemetry-log (cons event (unbox global-telemetry-log)))
  (for ([consumer (in-list (current-telemetry-consumers))])
    (with-handlers ([exn:fail? (lambda (_exn) (void))])
      (consumer event)))
  event)

(define-syntax (telemetry-event! stx)
  (syntax-parse stx
    [(_ message:expr)
     #'(emit-telemetry-event! message '())]
    [(_ message:expr #:attributes ([key value] ...))
     (define keys (for/list ([k (syntax->list #'(key ...))])
                    (syntax->datum k)))
     (with-syntax ([(quoted-key ...)
                    (for/list ([k keys])
                      #`'#,k)])
       #'(emit-telemetry-event! message
                                (list (cons quoted-key value) ...)))]))

(define-syntax-rule (log-info! message rest ...)
  (telemetry-event! message rest ...))

(define (drain-telemetry!)
  (define events (reverse (unbox global-telemetry-log)))
  (set-box! global-telemetry-log '())
  events)
