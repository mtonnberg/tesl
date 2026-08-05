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
  (only-in tesl/tesl/prelude Bool String)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.slice tesl_import_String_slice] [String.toUpper tesl_import_String_toUpper])
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/crypto Secret [Crypto.signWith tesl_import_Crypto_signWith] [Crypto.checkSignature tesl_import_Crypto_checkSignature] [Crypto.signatureHex tesl_import_Crypto_signatureHex] [Crypto.signatureFromHex tesl_import_Crypto_signatureFromHex] [Crypto.signatureBase64 tesl_import_Crypto_signatureBase64] [Crypto.signatureFromBase64 tesl_import_Crypto_signatureFromBase64])
  (only-in tesl/tesl/api-test statusOk)
)


(provide WebhookServer)

(define RawBody 'RawBody)
(define SignedBySender 'SignedBySender)

(define/pow
  (makeSecret [s : String])
  #:returns Secret
  (thsl-src! "tests/webhook-signature-tests.tesl" 55 (list (cons 's *s)) (lambda () (raw-value (Secret *s)))))

(define/pow
  (senderKey)
  #:returns Secret
  (thsl-src! "tests/webhook-signature-tests.tesl" 58 (list) (lambda () (raw-value (makeSecret "webhook-signature-tests-sender-key")))))

(define/pow
  (otherSenderKey)
  #:returns Secret
  (thsl-src! "tests/webhook-signature-tests.tesl" 61 (list) (lambda () (raw-value (makeSecret "webhook-signature-tests-other-sender-key")))))

(define/pow
  (hexSignature [key : Secret] [payload : String])
  #:returns String
  (thsl-src! "tests/webhook-signature-tests.tesl" 70 (list (cons 'key *key) (cons 'payload *payload)) (lambda () (raw-value (tesl_import_Crypto_signatureHex (raw-value (tesl_import_Crypto_signWith *key *payload)))))))

(define/pow
  (base64Signature [key : Secret] [payload : String])
  #:returns String
  (thsl-src! "tests/webhook-signature-tests.tesl" 73 (list (cons 'key *key) (cons 'payload *payload)) (lambda () (raw-value (tesl_import_Crypto_signatureBase64 (raw-value (tesl_import_Crypto_signWith *key *payload)))))))

(define-record Ack
  [seen : String]
)

(define (tesl-codec-encode-Ack _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'seen (tesl-encode-prim-string (raw-value (hash-ref _fields 'seen)))
  ))
(register-type-codec! 'Ack tesl-codec-encode-Ack (list ))

(define-record Base64Ack
  [seen : String]
)

(define (tesl-codec-encode-Base64Ack _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'seen (tesl-encode-prim-string (raw-value (hash-ref _fields 'seen)))
  ))
(register-type-codec! 'Base64Ack tesl-codec-encode-Base64Ack (list ))

(define-record RawEcho
  [raw : String]
  [hex : String]
  [base64 : String]
)

(define (tesl-codec-encode-RawEcho _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'raw (tesl-encode-prim-string (raw-value (hash-ref _fields 'raw)))
        'hex (tesl-encode-prim-string (raw-value (hash-ref _fields 'hex)))
        'base64 (tesl-encode-prim-string (raw-value (hash-ref _fields 'base64)))
  ))
(register-type-codec! 'RawEcho tesl-codec-encode-RawEcho (list ))

(define-auther
  (hexSignedWebhook [request : HttpRequest])
  #:returns [payload : String ::: (SignedBySender payload)]
  (thsl-src-control! "tests/webhook-signature-tests.tesl" 127 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "x-signature" (raw-value request.headers)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/webhook-signature-tests.tesl" 128 (list) (lambda () (reject "no signature" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([hex (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/webhook-signature-tests.tesl" 130 (list (cons 'hex hex)) (lambda () (let/check ([tesl-checked-1 (tesl_import_Crypto_checkSignature (senderKey) (raw-value (tesl_import_Crypto_signatureFromHex (raw-value hex))) (raw-value request.body))]) (let ([verified tesl-checked-1]) (accept (SignedBySender verified) #:value *verified))))))])))))

(define-auther
  (base64SignedWebhook [request : HttpRequest])
  #:returns [payload : String ::: (SignedBySender payload)]
  (thsl-src-control! "tests/webhook-signature-tests.tesl" 134 (list (cons 'request *request)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "webhook-signature" (raw-value request.headers)))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/webhook-signature-tests.tesl" 135 (list) (lambda () (reject "no signature" #:http-code 401)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([b64 (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tests/webhook-signature-tests.tesl" 137 (list (cons 'b64 b64)) (lambda () (let/check ([tesl-checked-3 (tesl_import_Crypto_checkSignature (senderKey) (raw-value (tesl_import_Crypto_signatureFromBase64 (raw-value b64))) (raw-value request.body))]) (let ([verified tesl-checked-3]) (accept (SignedBySender verified) #:value *verified))))))])))))

(define-auther
  (rawBodyEcho [request : HttpRequest])
  #:returns [raw : String ::: (RawBody raw)]
  (thsl-src! "tests/webhook-signature-tests.tesl" 144 (list (cons 'request *request)) (lambda () (accept RawBody #:value (raw-value request.body)))))

(define-handler
  (hexEvent [payload : String ::: (SignedBySender payload)])
  #:returns Ack
  (thsl-src! "tests/webhook-signature-tests.tesl" 149 (list (cons 'payload *payload)) (lambda () (Ack #:seen *payload))))

(define-handler
  (base64Event [payload : String ::: (SignedBySender payload)])
  #:returns Base64Ack
  (thsl-src! "tests/webhook-signature-tests.tesl" 152 (list (cons 'payload *payload)) (lambda () (Base64Ack #:seen *payload))))

(define-handler
  (echoRawBody [raw : String ::: (RawBody raw)])
  #:returns RawEcho
  (thsl-src! "tests/webhook-signature-tests.tesl" 155 (list (cons 'raw *raw)) (lambda () (RawEcho #:raw *raw #:hex (hexSignature (senderKey) raw) #:base64 (base64Signature (senderKey) raw)))))

(define WebhookServer-sse-routes '())
(define-api WebhookApi
  [hexEvent :
    (Auth [payload : String ::: (SignedBySender payload)] #:via hexSignedWebhook)
    :> "hook"
    :> "hex"
    :> (Post JSON Ack)
    ]
  [base64Event :
    (Auth [payload : String ::: (SignedBySender payload)] #:via base64SignedWebhook)
    :> "hook"
    :> "base64"
    :> (Post JSON Base64Ack)
    ]
  [echoRawBody :
    (Auth [raw : String ::: (RawBody raw)] #:via rawBodyEcho)
    :> "echo"
    :> (Post JSON RawEcho)
    ]
)

(define-server WebhookServer
  #:api WebhookApi
  [hexEvent hexEvent]
  [base64Event base64Event]
  [echoRawBody echoRawBody]
)

(module+ test
  (require rackunit)
  (test-case "the auth block sees the bytes that arrived"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define e (thsl-src! "tests/webhook-signature-tests.tesl" 217 (list) (lambda () (dispatch-api-test-request WebhookServer 'post (list "echo") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 218 (list (cons 'e e)) (lambda () (statusOk (raw-value (api-test-field-access-ref e 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 219 (list (cons 'e e)) (lambda () (api-test-field-access-ref (api-test-field-access-ref e 'body) 'raw)))) "{\"event\":\"ping\"}")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a correct hex signature authenticates the webhook"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 227 (list) (lambda () "{\"event\":\"ping\"}")))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 228 (list (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") (hexSignature (senderKey) payload)) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 229 (list (cons 'r r) (cons 'payload payload)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 230 (list (cons 'r r) (cons 'payload payload)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'seen)))) payload)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "no signature header is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 234 (list) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 235 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an empty hex signature is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 239 (list) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") "") #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 240 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "malformed hex is a 401, not a 500"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define notHex (thsl-src! "tests/webhook-signature-tests.tesl" 246 (list) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") "zzzz-not-hex-at-all") #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 247 (list (cons 'notHex notHex)) (lambda () (api-test-field-access-ref notHex 'status)))) 401)
            (define oddLength (thsl-src! "tests/webhook-signature-tests.tesl" 248 (list (cons 'notHex notHex)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") "abc") #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 249 (list (cons 'oddLength oddLength) (cons 'notHex notHex)) (lambda () (api-test-field-access-ref oddLength 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a truncated but valid-prefix signature is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 253 (list) (lambda () "{\"event\":\"ping\"}")))
            (define full (thsl-src! "tests/webhook-signature-tests.tesl" 254 (list (cons 'payload payload)) (lambda () (hexSignature (senderKey) (raw-value payload)))))
            (define truncated (thsl-src! "tests/webhook-signature-tests.tesl" 255 (list (cons 'full full) (cons 'payload payload)) (lambda () (tesl_import_String_slice (raw-value full) 0 32))))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 256 (list (cons 'truncated truncated) (cons 'full full) (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") truncated) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 257 (list (cons 'r r) (cons 'truncated truncated) (cons 'full full) (cons 'payload payload)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a signature from the wrong key is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 261 (list) (lambda () "{\"event\":\"ping\"}")))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 262 (list (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") (hexSignature (otherSenderKey) payload)) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 263 (list (cons 'r r) (cons 'payload payload)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a body tampered with after signing is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define signedPayload (thsl-src! "tests/webhook-signature-tests.tesl" 269 (list) (lambda () "{\"event\":\"ping\"}")))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 270 (list (cons 'signedPayload signedPayload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") (hexSignature (senderKey) signedPayload)) #:body (tesl-hash (string->symbol "event") "pong") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 271 (list (cons 'r r) (cons 'signedPayload signedPayload)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a signature for another event does not replay onto this one"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define other (thsl-src! "tests/webhook-signature-tests.tesl" 277 (list) (lambda () "{\"event\":\"charge.refunded\"}")))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 278 (list (cons 'other other)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") (hexSignature (senderKey) other)) #:body (tesl-hash (string->symbol "event") "charge.succeeded") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 279 (list (cons 'r r) (cons 'other other)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an upper-cased hex tag still verifies"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 287 (list) (lambda () "{\"event\":\"ping\"}")))
            (define shouty (thsl-src! "tests/webhook-signature-tests.tesl" 288 (list (cons 'payload payload)) (lambda () (tesl_import_String_toUpper (hexSignature (senderKey) (raw-value payload))))))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 289 (list (cons 'shouty shouty) (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") shouty) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 290 (list (cons 'r r) (cons 'shouty shouty) (cons 'payload payload)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 291 (list (cons 'r r) (cons 'shouty shouty) (cons 'payload payload)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'seen)))) payload)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a correct base64 signature authenticates the webhook"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 299 (list) (lambda () "{\"event\":\"ping\"}")))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 300 (list (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "base64") #:headers (tesl-hash (string->symbol "webhook-signature") (base64Signature (senderKey) payload)) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 301 (list (cons 'r r) (cons 'payload payload)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 302 (list (cons 'r r) (cons 'payload payload)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'seen)))) payload)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "malformed base64 is a 401, not a 500"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define notB64 (thsl-src! "tests/webhook-signature-tests.tesl" 306 (list) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "base64") #:headers (tesl-hash (string->symbol "webhook-signature") "!!!not-base64!!!") #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 307 (list (cons 'notB64 notB64)) (lambda () (api-test-field-access-ref notB64 'status)))) 401)
            (define empty (thsl-src! "tests/webhook-signature-tests.tesl" 308 (list (cons 'notB64 notB64)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "base64") #:headers (tesl-hash (string->symbol "webhook-signature") "") #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 309 (list (cons 'empty empty) (cons 'notB64 notB64)) (lambda () (api-test-field-access-ref empty 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a base64 signature from the wrong key is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 313 (list) (lambda () "{\"event\":\"ping\"}")))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 314 (list (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "base64") #:headers (tesl-hash (string->symbol "webhook-signature") (base64Signature (otherSenderKey) payload)) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 315 (list (cons 'r r) (cons 'payload payload)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a tampered body is a 401 in the base64 transport too"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define signedPayload (thsl-src! "tests/webhook-signature-tests.tesl" 319 (list) (lambda () "{\"event\":\"ping\"}")))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 320 (list (cons 'signedPayload signedPayload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "base64") #:headers (tesl-hash (string->symbol "webhook-signature") (base64Signature (senderKey) signedPayload)) #:body (tesl-hash (string->symbol "event") "pong") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 321 (list (cons 'r r) (cons 'signedPayload signedPayload)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a hex tag on the base64 route is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 329 (list) (lambda () "{\"event\":\"ping\"}")))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 330 (list (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "base64") #:headers (tesl-hash (string->symbol "webhook-signature") (hexSignature (senderKey) payload)) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 331 (list (cons 'r r) (cons 'payload payload)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a base64 tag on the hex route is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 335 (list) (lambda () "{\"event\":\"ping\"}")))
            (define r (thsl-src! "tests/webhook-signature-tests.tesl" 336 (list (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") (base64Signature (senderKey) payload)) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 337 (list (cons 'r r) (cons 'payload payload)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the wrong header name is a 401 on both routes"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 343 (list) (lambda () "{\"event\":\"ping\"}")))
            (define hexRoute (thsl-src! "tests/webhook-signature-tests.tesl" 344 (list (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "webhook-signature") (hexSignature (senderKey) payload)) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 345 (list (cons 'hexRoute hexRoute) (cons 'payload payload)) (lambda () (api-test-field-access-ref hexRoute 'status)))) 401)
            (define b64Route (thsl-src! "tests/webhook-signature-tests.tesl" 346 (list (cons 'hexRoute hexRoute) (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "base64") #:headers (tesl-hash (string->symbol "x-signature") (base64Signature (senderKey) payload)) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 347 (list (cons 'b64Route b64Route) (cons 'hexRoute hexRoute) (cons 'payload payload)) (lambda () (api-test-field-access-ref b64Route 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a refused webhook leaves the next good one alone"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 351 (list) (lambda () "{\"event\":\"ping\"}")))
            (define bad (thsl-src! "tests/webhook-signature-tests.tesl" 352 (list (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") "deadbeef") #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 353 (list (cons 'bad bad) (cons 'payload payload)) (lambda () (api-test-field-access-ref bad 'status)))) 401)
            (define good (thsl-src! "tests/webhook-signature-tests.tesl" 354 (list (cons 'bad bad) (cons 'payload payload)) (lambda () (dispatch-api-test-request WebhookServer 'post (list "hook" "hex") #:headers (tesl-hash (string->symbol "x-signature") (hexSignature (senderKey) payload)) #:body (tesl-hash (string->symbol "event") "ping") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 355 (list (cons 'good good) (cons 'bad bad) (cons 'payload payload)) (lambda () (statusOk (raw-value (api-test-field-access-ref good 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 356 (list (cons 'good good) (cons 'bad bad) (cons 'payload payload)) (lambda () (api-test-field-access-ref (api-test-field-access-ref good 'body) 'seen)))) payload)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "HMAC-SHA256 is deterministic and key-separated"
    (call-with-fresh-memory-db '() (lambda ()
  (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 186 (list) (lambda () "{\"event\":\"ping\"}")))
  (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 187 (list (cons 'payload payload)) (lambda () (hexSignature (senderKey) payload)))) (hexSignature (senderKey) payload))
  (check-not-equal? (thsl-src! "tests/webhook-signature-tests.tesl" 188 (list (cons 'payload payload)) (lambda () (hexSignature (senderKey) payload))) (hexSignature (otherSenderKey) payload))
  (check-equal? (raw-value (thsl-src! "tests/webhook-signature-tests.tesl" 190 (list (cons 'payload payload)) (lambda () (tesl_import_String_length (raw-value (hexSignature (senderKey) payload)))))) 64)
    ))
  )

  (test-case "hex and base64 are two encodings of the same tag"
    (call-with-fresh-memory-db '() (lambda ()
  (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 194 (list) (lambda () "{\"event\":\"ping\"}")))
  (define hex (thsl-src! "tests/webhook-signature-tests.tesl" 195 (list (cons 'payload payload)) (lambda () (hexSignature (senderKey) payload))))
  (define b64 (thsl-src! "tests/webhook-signature-tests.tesl" 196 (list (cons 'hex hex) (cons 'payload payload)) (lambda () (base64Signature (senderKey) payload))))
  (check-not-equal? (thsl-src! "tests/webhook-signature-tests.tesl" 197 (list (cons 'b64 b64) (cons 'hex hex) (cons 'payload payload)) (lambda () hex)) b64)
  (check-true (thsl-src! "tests/webhook-signature-tests.tesl" 200 (list (cons 'b64 b64) (cons 'hex hex) (cons 'payload payload)) (lambda () (tesl-lt? (raw-value (tesl_import_String_length (raw-value b64))) (raw-value (tesl_import_String_length (raw-value hex)))))))
    ))
  )

  (test-case "a one-character change to the payload changes the tag"
    (call-with-fresh-memory-db '() (lambda ()
  (define payload (thsl-src! "tests/webhook-signature-tests.tesl" 204 (list) (lambda () "{\"event\":\"ping\"}")))
  (define tampered (thsl-src! "tests/webhook-signature-tests.tesl" 205 (list (cons 'payload payload)) (lambda () "{\"event\":\"pong\"}")))
  (check-not-equal? (thsl-src! "tests/webhook-signature-tests.tesl" 206 (list (cons 'tampered tampered) (cons 'payload payload)) (lambda () (hexSignature (senderKey) payload))) (hexSignature (senderKey) tampered))
    ))
  )

)
