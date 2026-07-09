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
  (only-in tesl/tesl/telemetry telemetry)
  (only-in tesl/tesl/queue queueRead FromQueue FromDeadQueue)
  (only-in (file "KanelModels.rkt") NotifyPayload)
)


(provide notifyWorker deadNotifyWorker notifyWorkerCap notifyWorker-signature deadNotifyWorker-signature)

(define-capability notifyWorkerCap (implies queueRead))

(define/pow
  (notifyWorker [job : NotifyPayload ::: (FromQueue (Id == jobId) job)])
  #:capabilities [notifyWorkerCap]
  #:returns NotifyPayload
  (let ([_ (thsl-src! "example/kanel/KanelNotify.tesl" 22 (list (cons 'job *job)) (lambda () (telemetry-event! "kanel.email.sent" #:attributes (["recipient" (raw-value job.recipientEmail)] ["subject" (raw-value job.subject)]))))]) (thsl-src! "example/kanel/KanelNotify.tesl" 25 (list (cons 'job *job)) (lambda () *job))))

(define/pow
  (deadNotifyWorker [job : NotifyPayload ::: (FromDeadQueue (Id == jobId) job)])
  #:capabilities [notifyWorkerCap]
  #:returns NotifyPayload
  (let ([_ (thsl-src! "example/kanel/KanelNotify.tesl" 29 (list (cons 'job *job)) (lambda () (telemetry-event! "kanel.email.failed" #:attributes (["recipient" (raw-value job.recipientEmail)] ["subject" (raw-value job.subject)]))))]) (thsl-src! "example/kanel/KanelNotify.tesl" 30 (list (cons 'job *job)) (lambda () *job))))
