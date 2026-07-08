#lang racket

;;; Tesl.Agent — Money-typed tool-argument decoding (audit gap: the `money`
;;; branch of tesl-agent-decode-args had no direct coverage; a decode bug
;;; would only surface inside a full mock agent loop).
;;;
;;; Drives tesl-agent-decode-args (the validator the declarative
;;; `agent { tools: [fn...] }` lowering installs) directly with money-tagged
;;; specs.  Contract pinned here:
;;;   - a Money tool param arrives as {minorUnits: <exact int>, currency:
;;;     <ISO 4217 code>} and decodes to a tesl-money struct;
;;;   - EXTRA keys (e.g. an enriched `display` echoed back by the model) are
;;;     tolerated, both inside the money object and at the top level;
;;;   - a non-object value, a missing minorUnits/currency, a non-integer
;;;     minorUnits, or an unknown currency code all RAISE (the tool-call loop
;;;     turns that into an is_error tool_result the model can retry).

(require rackunit
         json
         (only-in "../tesl/agent.rkt" tesl-agent-decode-args)
         (only-in "../dsl/private/money-core.rkt"
                  tesl-money? tesl-money-minor-units tesl-money-currency
                  tesl-currency-code))

(define (decode args-jsexpr specs)
  (tesl-agent-decode-args (jsexpr->string args-jsexpr) specs))

;; ── Happy path ──────────────────────────────────────────────────────────────

(let ([vals (decode (hash 'amount (hash 'minorUnits 1050 'currency "USD"))
                    (list (cons "amount" 'money)))])
  (check-equal? (length vals) 1)
  (define m (first vals))
  (check-true (tesl-money? m) "money arg decodes to a tesl-money")
  (check-equal? (tesl-money-minor-units m) 1050)
  (check-equal? (tesl-currency-code (tesl-money-currency m)) "USD"))

;; zero-minor-digit currency and a negative amount both pass through
(let ([vals (decode (hash 'refund (hash 'minorUnits -300 'currency "JPY"))
                    (list (cons "refund" 'money)))])
  (check-equal? (tesl-money-minor-units (first vals)) -300)
  (check-equal? (tesl-currency-code (tesl-money-currency (first vals))) "JPY"))

;; mixed spec: values come back in SPEC order, money among primitives
(let ([vals (decode (hash 'qty 3
                          'total (hash 'minorUnits 250 'currency "SEK")
                          'label "invoice")
                    (list (cons "label" 'string)
                          (cons "total" 'money)
                          (cons "qty"   'int)))])
  (check-equal? (first vals) "invoice")
  (check-equal? (tesl-money-minor-units (second vals)) 250)
  (check-equal? (tesl-currency-code (tesl-money-currency (second vals))) "SEK")
  (check-equal? (third vals) 3))

;; extra keys tolerated: inside the money object AND at the top level
(let ([vals (decode (hash 'amount (hash 'minorUnits 5
                                        'currency "SEK"
                                        'display "0.05 SEK")
                          'unrelated "ignored")
                    (list (cons "amount" 'money)))])
  (check-equal? (tesl-money-minor-units (first vals)) 5))

;; ── Error paths (each raises; the agent loop maps these to is_error) ────────

;; the money value is not an object
(check-exn #px"argument amount must be an object \\{minorUnits, currency\\}"
           (lambda () (decode (hash 'amount 1050)
                              (list (cons "amount" 'money)))))
(check-exn #px"must be an object"
           (lambda () (decode (hash 'amount "10.50 USD")
                              (list (cons "amount" 'money)))))

;; missing keys
(check-exn #px"argument amount is missing minorUnits"
           (lambda () (decode (hash 'amount (hash 'currency "USD"))
                              (list (cons "amount" 'money)))))
(check-exn #px"argument amount is missing currency"
           (lambda () (decode (hash 'amount (hash 'minorUnits 1050))
                              (list (cons "amount" 'money)))))

;; non-integer minorUnits: a float major-unit amount is the classic model
;; mistake ("10.50") — both the number and the string form must raise
(check-exn #px"argument amount must have integer minorUnits"
           (lambda () (decode (hash 'amount (hash 'minorUnits 10.5
                                                  'currency "USD"))
                              (list (cons "amount" 'money)))))
(check-exn #px"argument amount must have integer minorUnits"
           (lambda () (decode (hash 'amount (hash 'minorUnits "1050"
                                                  'currency "USD"))
                              (list (cons "amount" 'money)))))

;; unknown / malformed currency codes (case-sensitive ISO 4217)
(check-exn #px"argument amount has unknown currency code: XXQ"
           (lambda () (decode (hash 'amount (hash 'minorUnits 1
                                                  'currency "XXQ"))
                              (list (cons "amount" 'money)))))
(check-exn #px"unknown currency code"
           (lambda () (decode (hash 'amount (hash 'minorUnits 1
                                                  'currency "usd"))
                              (list (cons "amount" 'money)))))
;; a non-string currency (numeric ISO code) is also "unknown"
(check-exn #px"unknown currency code"
           (lambda () (decode (hash 'amount (hash 'minorUnits 1
                                                  'currency 840))
                              (list (cons "amount" 'money)))))

;; outer envelope errors, unchanged by the money tag
(check-exn #px"missing required argument: amount"
           (lambda () (decode (hash) (list (cons "amount" 'money)))))
(check-exn #px"arguments were not valid JSON"
           (lambda () (tesl-agent-decode-args "not json"
                                              (list (cons "amount" 'money)))))
(check-exn #px"expected a JSON object of arguments"
           (lambda () (tesl-agent-decode-args "[1,2]"
                                              (list (cons "amount" 'money)))))

(printf "agent-money-tools-tests: money tool-arg decode contract pinned\n")
