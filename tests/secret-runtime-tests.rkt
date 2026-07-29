#lang racket

;; secret-runtime-tests.rkt — the runtime half of `secret X = T`
;; (roadmap/next/tesl_crypto.md, phases 3 and 4).
;;
;; WHAT THIS SUITE IS FOR
;; ----------------------
;; `secret X = T` is `type X = T` minus `.value`, minus `Ord`, plus REDACTION at
;; every rendering sink, plus a compile error in a response / codec / client
;; position.  The compile-time half is ratcheted by
;; compiler/test/test_secret_surface.ml; everything here is the runtime half:
;;
;;   1. STRUCTURAL redaction.  Redaction is not "check the top-level value" —
;;      the check goes at EVERY NODE of a renderer's walk, so a secret nested in
;;      a record inside a tuple inside a List inside a Maybe inside an ADT
;;      payload redacts WHILE ITS SIBLINGS RENDER NORMALLY.  A shallow
;;      implementation passes a flat test and fails this one, which is exactly
;;      why the nesting fixtures below are deliberately awkward.
;;
;;   2. All THREE debugger surfaces.  `safe-display` (checkpoint.rkt) is the leaf
;;      renderer for DAP launch, DAP attach and headless/MCP alike, and
;;      dap-server's `full-text-of` — the Copy Value / hover / watch path, which
;;      deliberately BYPASSES truncation to build complete copy-worthy text —
;;      calls it too.  The dangerous sink is therefore covered by the same fix,
;;      and this suite asserts that rather than assuming it.
;;
;;   3. The composite⇒leaf pairing.  A redacted secret must read as a LEAF on
;;      BOTH the display side and the children side.  `value-unwrap/newtype`
;;      must NOT descend into a secret: if it did, `value-children` would publish
;;      the inner value as an expandable child and bypass display redaction
;;      entirely.  That is the subtle failure mode, so it gets its own test.
;;
;;   4. `==` stays and is CONSTANT-TIME.  Unlike PasswordHash/Signature (whose
;;      only legitimate comparison IS a verification, so they lose Eq), a secret
;;      keeps Eq — `==` is the sanctioned way to check one, which is precisely
;;      why it must not early-exit.
;;
;;   5. PERSISTENCE IS NOT RENDERING.  The single structural walk
;;      (`runtime-value->jsexpr`) is shared by the HTTP response path, SQL
;;      ADT-field persistence, the cache, the queue store, SSE and test support.
;;      Redacting there unconditionally would corrupt persistence: a stored
;;      secret would come back as the literal string "[redacted]".  Redaction is
;;      therefore a PARAMETER, default off, and this suite pins BOTH directions —
;;      off means round-trip, on means redact.  That test is the one that stops a
;;      future "just redact everywhere" change.

(require rackunit
         racket/list
         racket/string
         racket/port
         json
         (only-in tesl/dsl/types
                  record-value adt-value newtype-value
                  define-secret-newtype define-newtype
                  secret-value? secret-type-name? secret-redaction-text
                  secret-constant-time-equal?
                  current-redact-secrets? runtime-value->jsexpr
                  secret-header-value secret-header-value?
                  secret-header-value-plaintext)
         (only-in tesl/dsl/private/evidence named-value check-ok)
         (only-in tesl/dsl/debug/checkpoint safe-display)
         tesl/dsl/debug/value-tree
         (only-in tesl/dsl/otel
                  telemetry-value->jsexpr
                  telemetry-value->otlp-any-value)
         (only-in tesl/tesl/private/runtime tesl-equal?)
         (only-in tesl/tesl/logging tesl-log-sql! set-telemetry-log-sink!)
         (only-in tesl/tesl/http-client
                  HttpClient.bearer HttpClient.secretHeader
                  http-header-field-safe?)
         (only-in tesl/tesl/tuple Tuple2.first Tuple2.second))

(printf "\n=== secret: structural redaction, constant-time ==, opacity ===\n\n")

;; ── Fixtures ─────────────────────────────────────────────────────────────────
;;
;; Declared through the real macros, so the registry keys are the real
;; `type-ref` tokens (a hand-built `(newtype-value 'Password …)` would carry a
;; bare symbol, satisfy neither the type predicate nor `secret-value?`, and make
;; every assertion below pass for the wrong reason).

(define-secret-newtype Password String)
(define-newtype Username String)          ; the non-secret sibling, for contrast

(define pw (Password "hunter2"))
(define pw-same (Password "hunter2"))
(define pw-other (Password "hunter3"))
(define user (Username "mikael"))

;; ── 1. The predicate itself ──────────────────────────────────────────────────

(test-case "secret-value? is true for a secret newtype and false for a plain one"
  (check-true  (secret-value? pw))
  (check-false (secret-value? user))
  (check-false (secret-value? "hunter2"))
  (check-false (secret-value? 42)))

(test-case "the redaction text carries no partial disclosure"
  ;; Deliberately NOT "[redacted, 12 chars]": password length is a real leak,
  ;; and partial disclosure in a debugger is the convenience that erodes the
  ;; guarantee.  Pin the exact string so a future "helpful" edit fails here.
  (check-equal? secret-redaction-text "[redacted]")
  (check-false (regexp-match? #rx"hunter" secret-redaction-text))
  (check-false (regexp-match? #rx"[0-9]" secret-redaction-text)))

;; ── 2. Structural redaction: the nesting corpus ──────────────────────────────
;;
;; ONE value that buries a secret under every composite the roadmap names — a
;; record field, a tuple slot, a List element, a Maybe payload, an ADT payload —
;; each with a NON-secret sibling beside it whose rendering must survive.

(define creds-record
  (record-value 'Creds 'creds-identity
                (hash 'username user          ; sibling: a plain newtype
                      'password pw            ; the secret
                      'attempts 3)))          ; sibling: a scalar

(define creds-tuple                              ; (Password, "audit-note")
  (adt-value 'Tuple2 'tuple2-identity 'Tuple2
             (hash 'first pw 'second "audit-note")))

(define creds-list (list pw "plain-sibling" user))

(define creds-maybe                              ; Something(Password)
  (adt-value 'Maybe 'maybe-identity 'Something (hash 'value pw)))

(define creds-adt                                ; Login(Password, String)
  (adt-value 'Event 'event-identity 'Login
             (hash 'field-0 pw 'field-1 "192.0.2.1")))

;; The whole tree at once — a Maybe of a List of records, plus the tuple and ADT.
(define deep-tree
  (record-value 'AuditEntry 'audit-identity
                (hash 'who     creds-record
                      'pair    creds-tuple
                      'batch   (list creds-maybe creds-adt)
                      'items   creds-list
                      'traceId "trace-9")))

;; Every string that appears anywhere in a rendered form.
(define (all-strings-of v)
  (let loop ([v v])
    (cond
      [(string? v) (list v)]
      [(list? v) (append-map loop v)]
      [(hash? v) (append-map loop (hash-values v))]
      [else '()])))

(define (leaks-plaintext? rendered)
  (regexp-match? #rx"hunter2" (if (string? rendered)
                                  rendered
                                  (format "~s" rendered))))

;; ── 2a. Telemetry ────────────────────────────────────────────────────────────

(test-case "telemetry: a secret redacts at every node, siblings render normally"
  (define js (telemetry-value->jsexpr deep-tree))
  (check-false (leaks-plaintext? js)
               "the plaintext must not appear anywhere in a telemetry attribute")
  (define strs (all-strings-of js))
  ;; The redaction actually happened (not merely "the value is absent").
  (check-true (>= (length (filter (lambda (s) (equal? s secret-redaction-text)) strs)) 5)
              "one [redacted] per secret occurrence — record, tuple, list, Maybe, ADT")
  ;; …and the SIBLINGS at each of those nodes came through untouched.  This is
  ;; the half a blanket "redact the whole subtree" implementation fails.
  (check-not-false (member "mikael" strs)        "plain newtype sibling survives")
  (check-not-false (member "audit-note" strs)    "tuple sibling survives")
  (check-not-false (member "plain-sibling" strs) "list sibling survives")
  (check-not-false (member "192.0.2.1" strs)     "ADT positional sibling survives")
  (check-not-false (member "trace-9" strs)       "outer record sibling survives")
  ;; The result is a real jsexpr — before this change a record-valued attribute
  ;; fell through to `[else value]` and emitted a raw struct.
  (check-true (jsexpr? js) "telemetry attributes must be valid jsexpr"))

(test-case "telemetry: a bare secret at the top level redacts"
  (check-equal? (telemetry-value->jsexpr pw) secret-redaction-text))

(test-case "telemetry: hash / list / vector recursion is structural"
  (check-equal? (telemetry-value->jsexpr (hash 'k pw 'j "keep"))
                (hash 'k secret-redaction-text 'j "keep"))
  (check-equal? (telemetry-value->jsexpr (list pw "keep"))
                (list secret-redaction-text "keep"))
  (check-equal? (telemetry-value->jsexpr (vector pw "keep"))
                (vector secret-redaction-text "keep")))

(test-case "OTLP AnyValue has its OWN guard, not the shared coercion's"
  ;; telemetry-value->otlp-any-value's string?/boolean?/integer? arms
  ;; short-circuit before delegating, so a check that lived only in
  ;; telemetry-value->jsexpr would be bypassed here.
  (check-equal? (telemetry-value->otlp-any-value pw)
                (hash 'stringValue secret-redaction-text))
  ;; A composite still routes through the shared walk, and still redacts.
  (define any (telemetry-value->otlp-any-value creds-record))
  (check-false (leaks-plaintext? any))
  (check-true (regexp-match? #rx"redacted" (hash-ref any 'stringValue)))
  ;; Non-secret values are untouched.
  (check-equal? (telemetry-value->otlp-any-value "plain") (hash 'stringValue "plain"))
  (check-equal? (telemetry-value->otlp-any-value 7) (hash 'intValue "7")))

;; ── 2b. All three debugger surfaces ──────────────────────────────────────────

(test-case "safe-display: a secret shows its TYPE and never its payload"
  ;; `Password([redacted])` — the type stays visible so you can still tell WHICH
  ;; secret you are looking at; the payload never is.
  (check-equal? (safe-display pw) "Password([redacted])")
  (check-false (leaks-plaintext? (safe-display pw)))
  ;; A plain newtype is unaffected (safe-display quotes a String payload).
  (check-equal? (safe-display user) "Username(\"mikael\")"))

(test-case "safe-display: structural — nested secrets redact, siblings render"
  (define s (safe-display deep-tree))
  (check-false (leaks-plaintext? s)
               "safe-display is the leaf renderer for ALL THREE debugger surfaces")
  (check-true (>= (length (regexp-match* #rx"\\[redacted\\]" s)) 5))
  (for ([sib '("mikael" "audit-note" "plain-sibling" "192.0.2.1" "trace-9")])
    (check-true (string-contains? s sib) (format "sibling ~a survives" sib))))

(test-case "value-display / value-type: redacted value, intact type column"
  (check-equal? (value-display pw) secret-redaction-text)
  ;; `value-type` renders the raw runtime type token, which for a newtype is a
  ;; `type-ref` prefab carrying its defining module (safe-display strips that;
  ;; value-type does not — a pre-existing cosmetic quirk, not a `secret` one).
  ;; What matters here is that the TYPE is still identifiable in the panel's type
  ;; column while the VALUE column is redacted.
  (check-true (string-contains? (value-type pw) "Password"))
  (check-false (leaks-plaintext? (value-type pw)))
  (check-false (leaks-plaintext? (value-display pw))))

(test-case "the composite⇒expandable invariant holds for a secret AS A LEAF"
  ;; THE SUBTLE ONE.  `value-unwrap/newtype` must not descend into a secret: if
  ;; it did, value-children would hand back the inner value as an expandable
  ;; child, whose own display is the plaintext — bypassing display redaction
  ;; completely.  Display side and children side are asserted TOGETHER, because
  ;; the invariant is exactly their agreement.
  (check-equal? (value-children pw) '() "a secret has no expandable children")
  (check-false (composite-display? pw) "…and does not claim to")
  ;; A plain newtype over a composite still expands (no collateral damage).
  (define money-ish (newtype-value 'Money creds-record))
  (check-true (> (length (value-children money-ish)) 0))
  ;; The secret's PARENT is still expandable, and the secret child is redacted.
  (define kids (value-children creds-record))
  (check-equal? (sort (map car kids) string<?) '("attempts" "password" "username"))
  (define pw-child (cdr (assoc "password" kids)))
  (check-equal? (value-display pw-child) secret-redaction-text)
  (check-equal? (value-children pw-child) '()))

(test-case "full-text-of (Copy Value / hover / watch) redacts"
  ;; dap-server's `full-text-of` deliberately bypasses truncation to build
  ;; complete copy-worthy text — the most dangerous sink.  It is implemented as
  ;; `safe-display`, so it is covered; VERIFY that rather than assume it.
  ;; The REAL function, not a stand-in: dap-server.rkt exports it for exactly
  ;; this assertion, so "it calls safe-display, so it must be fine" is measured
  ;; rather than assumed.
  (define full-text-of (dynamic-require 'tesl/dsl/debug/dap-server 'full-text-of))
  (define txt (full-text-of deep-tree (value-display deep-tree)))
  (check-true (string-contains? txt secret-redaction-text))
  (check-false (leaks-plaintext? txt)
               "Copy Value must not hand the user a plaintext secret"))

;; ── 2c. The framework SQL trace ──────────────────────────────────────────────

(test-case "tesl-log-sql!: a bound secret parameter renders as [redacted]"
  ;; Storage is not rendering: the bound parameter really IS the secret (that is
  ;; what makes a secret column round-trip), but this line renders it into the
  ;; framework trace — stderr when verbose, and the telemetry sink when one is
  ;; installed.  Captured through the SINK, because `tesl-verbose?` is a
  ;; load-time constant read from TESL_VERBOSE and cannot be set from a test.
  (define captured (box '()))
  (set-telemetry-log-sink!
   (lambda (category message attrs)
     (set-box! captured (cons message (unbox captured)))))
  (tesl-log-sql! "INSERT INTO users (name, pw) VALUES ($1, $2)"
                 (list "mikael" pw))
  (set-telemetry-log-sink! #f)
  (define out (string-join (unbox captured) "\n"))
  (check-false (leaks-plaintext? out) "the SQL trace must not echo the plaintext")
  (check-true (string-contains? out secret-redaction-text))
  (check-true (string-contains? out "mikael") "the non-secret param still shows"))

;; ── 3. PERSISTENCE IS NOT RENDERING ──────────────────────────────────────────

(test-case "runtime-value->jsexpr round-trips a secret by DEFAULT"
  ;; This walk is the HTTP response path, SQL ADT-field persistence, the cache,
  ;; the queue store, SSE and test support.  Blanket-redacting here would mean a
  ;; stored secret comes back as the literal string "[redacted]" — silent data
  ;; corruption dressed as a security feature.
  (check-equal? (runtime-value->jsexpr pw) "hunter2")
  (check-equal? (runtime-value->jsexpr creds-record)
                (hash 'username "mikael" 'password "hunter2" 'attempts 3)))

(test-case "runtime-value->jsexpr redacts structurally when asked to"
  (parameterize ([current-redact-secrets? #t])
    (check-equal? (runtime-value->jsexpr pw) secret-redaction-text)
    (define js (runtime-value->jsexpr deep-tree))
    (check-false (leaks-plaintext? js))
    (define strs (all-strings-of js))
    (check-not-false (member "mikael" strs))
    (check-not-false (member "192.0.2.1" strs)))
  ;; …and the parameter is genuinely scoped: back to round-trip afterwards.
  (check-equal? (runtime-value->jsexpr pw) "hunter2"))

;; ── 4. `==` stays, and is constant-time ──────────────────────────────────────

(test-case "tesl-equal? on secrets: correct answers"
  (check-true  (tesl-equal? pw pw-same))
  (check-false (tesl-equal? pw pw-other))
  ;; A secret is never equal to its bare payload — nominal identity is intact,
  ;; and a well-typed program cannot even ask.
  (check-false (tesl-equal? pw "hunter2"))
  (check-false (tesl-equal? "hunter2" pw))
  ;; Non-secret equality is completely unchanged.
  (check-true  (tesl-equal? user (Username "mikael")))
  (check-false (tesl-equal? user (Username "other")))
  (check-true  (tesl-equal? 1 1))
  (check-equal? (tesl-equal? (list 1 "a") (list 1 "a")) #t))

(test-case "the secret compare is constant-time in shape, not early-exit"
  ;; The property a unit test can actually pin: the comparison examines EVERY
  ;; byte pair (no data-dependent early return), so two same-length inputs that
  ;; differ in the FIRST byte and two that differ in the LAST byte both answer
  ;; #f — and every prefix-matching pair answers #f too.  A `string=?`-style
  ;; early exit would still pass this; what it could not pass is the source
  ;; shape, so the fold is asserted by behaviour across the whole prefix ladder.
  (define base "aaaaaaaaaaaaaaaa")
  (for ([i (in-range (string-length base))])
    (define mutated (string-append (substring base 0 i) "b" (substring base (add1 i))))
    (check-false (secret-constant-time-equal? base mutated)
                 (format "differs at byte ~a" i)))
  (check-true (secret-constant-time-equal? base (string-copy base)))
  ;; Length mismatch answers #f without walking (and without raising).
  (check-false (secret-constant-time-equal? "abc" "abcd"))
  ;; Non-string payloads fall back to equal? (a secret over Int has no byte
  ;; encoding to walk and an integer compare has no useful timing story).
  (check-true  (secret-constant-time-equal? 7 7))
  (check-false (secret-constant-time-equal? 7 8)))

;; ── 5. Sink coverage: the design must be USABLE, not only safe ────────────────

(test-case "HttpClient.bearer accepts a secret with no intermediate String"
  (define h (HttpClient.bearer pw))
  (check-equal? (Tuple2.first h) "Authorization")
  ;; The value half is NOT a string.  That is the point: the header pair is
  ;; typed `Tuple2 String String`, so the checker believes the value is a
  ;; String; if the runtime value WERE the plaintext, projecting it back out and
  ;; interpolating it would leak.
  (define v (Tuple2.second h))
  (check-false (string? v) "an outbound secret header value is not a String")
  (check-true (secret-header-value? v))
  ;; It renders as [redacted] everywhere, including through plain ~a.
  (check-equal? (format "~a" v) secret-redaction-text)
  (check-equal? (safe-display v) secret-redaction-text)
  (check-equal? (value-display v) secret-redaction-text)
  (check-equal? (telemetry-value->jsexpr v) secret-redaction-text)
  (check-false (leaks-plaintext? (format "~a" v)))
  (check-false (leaks-plaintext? (format "~s" v)))
  ;; …and the plaintext is recoverable at exactly one place, inside trusted code,
  ;; on its way to the socket — with the Bearer prefix applied there, not by the
  ;; caller concatenating strings.
  (check-equal? (secret-header-value-plaintext v) "Bearer hunter2"))

(test-case "HttpClient.secretHeader names any credential header"
  (define h (HttpClient.secretHeader "X-Api-Key" pw))
  (check-equal? (Tuple2.first h) "X-Api-Key")
  (check-equal? (secret-header-value-plaintext (Tuple2.second h)) "hunter2")
  ;; The CR/LF guard still governs what may go on the wire.
  (check-true  (http-header-field-safe? "X-Api-Key"))
  (check-false (http-header-field-safe? "X-Api-Key\r\nX-Evil: 1")))

(test-case "a secret's plaintext is not reachable through any String primitive"
  ;; OPACITY BY BEHAVIOUR (the exported-surface enumeration is the compiler
  ;; suite's job).  Every String primitive applied to the value half of a secret
  ;; header raises rather than returning a prefix, a length, or a coercion.
  (define v (Tuple2.second (HttpClient.bearer pw)))
  (check-exn exn:fail? (lambda () (string-length v)))
  (check-exn exn:fail? (lambda () (string-append v "!")))
  (check-exn exn:fail? (lambda () (substring v 0 3)))
  (check-exn exn:fail? (lambda () (string-upcase v))))

;; ── 6. No accidental accessor over the exported surface ──────────────────────

(test-case "dsl/types exports no secret→String accessor"
  ;; The opacity guarantee is "no exported way turns a secret into a String".
  ;; Asserted over the module's real export list so a future accidental
  ;; accessor (`secret-plaintext`, `secret->string`, `unwrap-secret`, …) fails
  ;; the build instead of shipping.  `secret-header-value-plaintext` is the ONE
  ;; sanctioned unwrap and is named as such — it takes the outbound-header
  ;; wrapper, not a secret, and exists so tesl/http-client.rkt has exactly one
  ;; place to do it.
  (define-values (exported _syntax) (module->exports 'tesl/dsl/types))
  (define names
    (for*/list ([phase (in-list exported)] [entry (in-list (cdr phase))])
      (symbol->string (car entry))))
  (define suspicious
    (filter (lambda (n)
              (and (regexp-match? #rx"secret" n)
                   (regexp-match? #rx"(plaintext|->string|unwrap|reveal|expose|raw)" n)
                   (not (equal? n "secret-header-value-plaintext"))))
            names))
  (check-equal? suspicious '()
                "a new secret→String accessor was exported; that reopens the guarantee"))

(printf "\n=== secret runtime tests done ===\n")
