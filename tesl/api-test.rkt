#lang racket

(require json
         racket/list
         racket/string
         "../dsl/types.rkt"
         (only-in "../dsl/private/check-runtime.rkt" raw-value)
         "../dsl/test-support.rkt"
         "queue.rkt")

(provide
 HttpResponse
 JsonValue
 JsonNull
 SseStream
 statusOk
 statusClientError
 statusServerError
 jsonInt
 jsonString
 jsonBool
 jsonArray
 jsonObject
 jsonLength
 isNull
 isNotNull
 includesWhere
 excludesWhere
 hasLength
 isEmpty
 isNotEmpty
 arrayAt
 hasField
 fieldAt
 bodyField
 jsonContains
 subscribe
 collect
 JobResult JobResult? JobOk JobFailed JobOk? JobFailed? JobOk-job JobFailed-job JobFailed-error
 processNextJob
 processNextDeadJob
 drainQueue
 pendingJobCount
 expectJobOk
 expectJobFailed)

(define HttpResponse 'HttpResponse)
(define JsonValue 'JsonValue)
(define JsonNull 'null)
(define SseStream 'SseStream)

(define-adt (JobResult job error)
  [JobOk job]
  [JobFailed job error])

(define subscribe api-test-subscribe)
(define collect api-test-collect)

(define (api-test-normalize-json value)
  (define raw (runtime-value->jsexpr value))
  (cond
    [(hash? raw)
     (for/hash ([(key val) (in-hash raw)])
       (values (if (symbol? key) (symbol->string key) key)
               (api-test-normalize-json val)))]
    [(list? raw)
     (map api-test-normalize-json raw)]
    [(vector? raw)
     (map api-test-normalize-json (vector->list raw))]
    [else raw]))

(define (api-test-format-json value)
  (with-handlers ([exn:fail? (lambda (_e) (~a value))])
    (jsexpr->string (api-test-normalize-json value))))

(define (api-test-json-type-name value)
  (define normalized (api-test-normalize-json value))
  (cond
    [(hash? normalized)   (format "Object ~a" (api-test-format-json normalized))]
    [(list? normalized)   (format "Array ~a" (api-test-format-json normalized))]
    [(string? normalized) (format "String ~s" normalized)]
    [(boolean? normalized) (format "Bool ~a" normalized)]
    [(number? normalized) (format "Number ~a" normalized)]
    [(eq? normalized 'null) "Null"]
    [else (~a normalized)]))

(define (ensure-json-array who value)
  (define normalized (api-test-normalize-json value))
  (unless (list? normalized)
    (raise-user-error who "expected a JSON array, got ~a" (api-test-json-type-name normalized)))
  normalized)

(define (ensure-json-object who value)
  (define normalized (api-test-normalize-json value))
  (unless (hash? normalized)
    (raise-user-error who "expected a JSON object, got ~a" (api-test-json-type-name normalized)))
  normalized)

(define (ensure-json-string who value)
  (define normalized (api-test-normalize-json value))
  (unless (string? normalized)
    (raise-user-error who "expected a JSON string, got ~a" (api-test-json-type-name normalized)))
  normalized)

(define (ensure-json-int who value)
  (define normalized (api-test-normalize-json value))
  (unless (integer? normalized)
    (raise-user-error who "expected a JSON integer, got ~a" (api-test-json-type-name normalized)))
  normalized)

(define (ensure-json-bool who value)
  (define normalized (api-test-normalize-json value))
  (unless (boolean? normalized)
    (raise-user-error who "expected a JSON boolean, got ~a" (api-test-json-type-name normalized)))
  normalized)

(define (statusOk status)
  (and (integer? status) (<= 200 status 299)))

(define (statusClientError status)
  (and (integer? status) (<= 400 status 499)))

(define (statusServerError status)
  (and (integer? status) (<= 500 status 599)))

(define (jsonInt value)
  (ensure-json-int 'jsonInt value))

(define (jsonString value)
  (ensure-json-string 'jsonString value))

(define (jsonBool value)
  (ensure-json-bool 'jsonBool value))

(define (jsonArray value)
  (ensure-json-array 'jsonArray value))

(define (jsonObject value)
  (ensure-json-object 'jsonObject value))

(define (jsonLength value)
  (define normalized (api-test-normalize-json value))
  (cond
    [(list? normalized) (length normalized)]
    [(hash? normalized) (hash-count normalized)]
    [(string? normalized) (string-length normalized)]
    [else
     (raise-user-error 'jsonLength "expected an array, object, or string, got ~a" (api-test-json-type-name normalized))]))

(define (isNull value)
  (define normalized (api-test-normalize-json value))
  (or (eq? normalized 'null)
      (equal? normalized "null")))

(define (isNotNull value)
  (not (isNull value)))

(define (hasLength expected value)
  (= expected (jsonLength value)))

(define (isEmpty value)
  (= 0 (jsonLength value)))

(define (isNotEmpty value)
  (not (isEmpty value)))

(define (arrayAt index value)
  (define xs (ensure-json-array 'arrayAt value))
  (when (or (< index 0) (>= index (length xs)))
    (raise-user-error 'arrayAt "index ~a is out of range for array of length ~a" index (length xs)))
  (list-ref xs index))

(define (hasField field value)
  (hash-has-key? (ensure-json-object 'hasField value) field))

(define (fieldAt field value)
  (define obj (ensure-json-object 'fieldAt value))
  (if (hash-has-key? obj field)
      (hash-ref obj field)
      'null))

(define (bodyField field response)
  (fieldAt field (api-test-field-access-ref response 'body)))

(define (jsonContains needle value)
  (define normalized-needle (api-test-normalize-json needle))
  (define normalized-value  (api-test-normalize-json value))
  (cond
    [(and (string? normalized-needle) (string? normalized-value))
     (not (false? (string-contains? normalized-value normalized-needle)))]
    [else
     (api-test-json-match? normalized-needle normalized-value)]))

(define (ensure-pattern-object who pattern)
  (define normalized (api-test-normalize-json pattern))
  (unless (hash? normalized)
    (raise-user-error who "expected a JSON object pattern, got ~a" (api-test-json-type-name normalized)))
  normalized)

(define (match-array-pattern? who pattern value negate?)
  (define normalized-pattern (ensure-pattern-object who pattern))
  (define xs (ensure-json-array who value))
  (define (matching-element? element)
    (unless (hash? element)
      (raise-user-error who "expected every array element to be a JSON object, got ~a" (api-test-json-type-name element)))
    (for ([key (in-list (hash-keys normalized-pattern))])
      (unless (hash-has-key? element key)
        (define suggestions (sort (map ~a (hash-keys element)) string<?))
        (raise-user-error who
                          "looking for field ~s but element does not have it\nelement: ~a\ntip: did you mean one of: ~a"
                          key
                          (api-test-format-json element)
                          (string-join (map ~s suggestions) ", "))))
    (for/and ([(key expected) (in-hash normalized-pattern)])
      (api-test-json-match? expected (hash-ref element key))))
  (define matched? (for/or ([element (in-list xs)]) (matching-element? element)))
  (if negate? (not matched?) matched?))

(define (includesWhere pattern value)
  (match-array-pattern? 'includesWhere pattern value #f))

(define (excludesWhere pattern value)
  (match-array-pattern? 'excludesWhere pattern value #t))

(define (lookup-worker-handler who queue-s bindings named-job)
  (when (null? bindings)
    (raise-user-error who
                      "queue ~a does not have a registered ~a in this module"
                      (queue-spec-name queue-s)
                      (if (eq? who 'processNextDeadJob) "deadWorker" "worker")))
  (define raw-job (raw-value named-job))
  (define maybe-job-type (and (record-value? raw-job) (record-value-type raw-job)))
  (cond
    [maybe-job-type
     (or (for/or ([binding (in-list bindings)])
           (and (equal? (car binding) maybe-job-type) (cdr binding)))
         (raise-user-error who
                           "queue ~a has no handler for job type ~a"
                           (queue-spec-name queue-s)
                           maybe-job-type))]
    [(= (length bindings) 1)
     (cdar bindings)]
    [else
     (raise-user-error who
                       "queue ~a has multiple handlers and the job payload is not a record value"
                       (queue-spec-name queue-s))]))

(define (queue-result->job-result who queue-s raw-result)
  (unless raw-result
    (raise-user-error who
                      "queue ~a is empty — expected at least one pending job\nhint: did the HTTP action that enqueues the job run and return a success status?"
                      (queue-spec-name queue-s)))
  (case (hash-ref raw-result 'kind #f)
    [(ok)
     (JobOk (hash-ref raw-result 'job))]
    [(failed)
     (JobFailed (hash-ref raw-result 'job)
                (hash-ref raw-result 'error))]
    [else
     (raise-user-error who "unexpected queue result ~a" raw-result)]))

(define (processNextJob queue-s)
  (define bindings (lookup-api-test-workers queue-s))
  (define raw-result
    (process-next-job/result!
     queue-s
     (lambda (named-job)
       ((lookup-worker-handler 'processNextJob queue-s bindings named-job) named-job))))
  (queue-result->job-result 'processNextJob queue-s raw-result))

(define (processNextDeadJob queue-s)
  (define bindings (lookup-api-test-dead-workers queue-s))
  (define raw-result
    (process-next-dead-job/result!
     queue-s
     (lambda (named-job)
       ((lookup-worker-handler 'processNextDeadJob queue-s bindings named-job) named-job))))
  (queue-result->job-result 'processNextDeadJob queue-s raw-result))

(define (drainQueue queue-s)
  (define bindings (lookup-api-test-workers queue-s))
  (let loop ([acc '()] [count 0])
    (when (>= count 1000)
      (raise-user-error 'drainQueue
                        "drainQueue hit its safety limit of 1000 jobs on queue ~a"
                        (queue-spec-name queue-s)))
    (define raw-result
      (process-next-job/result!
       queue-s
       (lambda (named-job)
         ((lookup-worker-handler 'drainQueue queue-s bindings named-job) named-job))))
    (if raw-result
        (loop (cons (queue-result->job-result 'drainQueue queue-s raw-result) acc)
              (add1 count))
        (reverse acc))))

(define (pendingJobCount queue-s)
  (pending-job-count queue-s))

(define (expectJobOk result)
  (cond
    [(JobOk? result) (JobOk-job result)]
    [(JobFailed? result)
     (raise-user-error 'expectJobOk
                       "expected JobOk but worker failed with ~a"
                       (api-test-format-json (JobFailed-error result)))]
    [else
     (raise-user-error 'expectJobOk "expected JobResult, got ~a" result)]))

(define (expectJobFailed result)
  (cond
    [(JobFailed? result) (JobFailed-error result)]
    [(JobOk? result)
     (raise-user-error 'expectJobFailed
                       "expected JobFailed but worker succeeded with job ~a"
                       (api-test-format-json (JobOk-job result)))]
    [else
     (raise-user-error 'expectJobFailed "expected JobResult, got ~a" result)]))
