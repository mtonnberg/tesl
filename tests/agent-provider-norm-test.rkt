#lang racket

;;; AI Tier-0 — provider NORMALIZATION layer unit tests (tesl/agent-provider.rkt).
;;;
;;; The whole point of agent-provider.rkt is that EVERY provider — Anthropic,
;;; OpenAI, local (OpenAI-compatible), and the mock — collapses a vendor-specific
;;; wire response into ONE internal shape: `llm-response`
;;;     (text usage tool-calls stop-reason)
;;; where each tool-call is (tool-call id name args) with args a PARSED jsexpr.
;;;
;;; These tests feed CANNED vendor response bodies (the exact JSON shape the
;;; real APIs return) and assert both vendors normalize to the SAME internal
;;; shape.  The single most error-prone divergence is that OpenAI returns
;;; `tool_calls[].function.arguments` as a JSON *string* while Anthropic returns
;;; `tool_use.input` as a native JSON object — both must parse to the identical
;;; jsexpr.  We also cover usage-token mapping, every stop-reason (incl. refusal
;;; and max-tokens), the request-shaping direction, HTTP error surfacing, and the
;;; mock provider.
;;;
;;; The real providers POST over HTTP via tesl/http-client.rkt, so rather than
;;; reach into private normalize functions we exercise the PUBLIC provider
;;; procedures end-to-end against a tiny in-process localhost HTTP server that
;;; replies with the canned body.  This is fully deterministic and offline —
;;; no real network, no API keys — and it also lets us capture the request body
;;; the provider sent, so we can assert request normalization too.
;;;
;;; Run (from repo, collection `tesl`+`dsl` on PLTCOLLECTS):
;;;     raco test tests/agent-provider-norm-test.rkt

(require racket/tcp
         json
         rackunit
         "../tesl/agent-provider.rkt"
         "../dsl/capability.rkt"
         (only-in "../tesl/http-client.rkt" httpClient))

;;; ── In-process canned HTTP server ────────────────────────────────────────────
;;;
;;; `with-canned-endpoint` binds an ephemeral localhost port, serves exactly ONE
;;; request with the supplied JSON body + status, captures the request body the
;;; client POSTed into `req-box`, and passes the URL to the body thunk.  Single
;;; request is all a provider call makes; the listener is torn down after.
(define (with-canned-endpoint resp-jsexpr proc
                              #:status [status 200]
                              #:req-box [req-box (box #f)])
  (define listener (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_la port _ra _rp) (tcp-addresses listener #t))
  (define server
    (thread
     (lambda ()
       (with-handlers ([exn:fail? void])
         (define-values (in out) (tcp-accept listener))
         ;; read request line + headers, note Content-Length
         (define clen 0)
         (let loop ()
           (define line (read-line in 'any))
           (unless (or (eof-object? line) (string=? line ""))
             (when (regexp-match? #rx"^(?i:content-length):" line)
               (set! clen (or (string->number
                               (string-trim (substring line (add1 (or (for/first ([i (in-range (string-length line))]
                                                                                   #:when (char=? (string-ref line i) #\:)) i) 0)))))
                              0)))
             (loop)))
         (when (> clen 0)
           (set-box! req-box (bytes->string/utf-8 (read-bytes clen in))))
         (define payload (string->bytes/utf-8 (jsexpr->string resp-jsexpr)))
         (fprintf out
                  "HTTP/1.1 ~a STATUS\r\nContent-Type: application/json\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
                  status (bytes-length payload))
         (write-bytes payload out)
         (flush-output out)
         (close-output-port out)
         (close-input-port in)))))
  (define url (format "http://127.0.0.1:~a/v1/endpoint" port))
  (dynamic-wind
   void
   (lambda () (proc url))
   (lambda ()
     (kill-thread server)
     (with-handlers ([exn:fail? void]) (tcp-close listener)))))

;;; Drive a provider against a canned body and return its `llm-response`.
;;; `make` is a 1-arg constructor: endpoint -> provider (api-key/model pre-bound).
(define (normalize make resp-jsexpr
                   #:status [status 200]
                   #:req-box [req-box (box #f)]
                   #:request [request (hash 'system "sys" 'max-tokens 256
                                            'messages '() 'tools '())])
  (with-canned-endpoint
    resp-jsexpr
    (lambda (url)
      (define provider (make url))
      (with-capabilities (httpClient)
        (call-provider provider request)))
    #:status status #:req-box req-box))

(define (anthropic-of url) (make-anthropic-provider "test-key" "claude-test" url))
(define (openai-of    url) (make-openai-provider    "test-key" "gpt-test"    url))
(define (local-of     url) (make-local-provider     url "local-model" "test-key"))

;;; Convenience: project a list of tool-calls to comparable tuples.
(define (calls->tuples tcs)
  (for/list ([tc (in-list tcs)])
    (list (tool-call-id tc) (tool-call-name tc) (tool-call-args tc))))

;;; Structural jsexpr equality that ignores hash KIND (hash vs hasheq).
;;; `string->jsexpr` produces hasheq objects, so a parsed arg hash is hasheq
;;; while an `(hash ...)` literal is equal?-keyed — not `equal?` to each other
;;; even with identical contents.  This helper compares by content/shape only,
;;; which is the right notion for "same normalized JSON value".
(define (jsexpr=? a b)
  (cond
    [(and (hash? a) (hash? b))
     (and (= (hash-count a) (hash-count b))
          (for/and ([(k v) (in-hash a)])
            (and (hash-has-key? b k) (jsexpr=? v (hash-ref b k)))))]
    [(and (list? a) (list? b))
     (and (= (length a) (length b))
          (andmap jsexpr=? a b))]
    [else (equal? a b)]))

;; rackunit binary check using jsexpr=?
(define-check (check-jsexpr=? actual expected)
  (unless (jsexpr=? actual expected)
    (with-check-info (['actual actual] ['expected expected])
      (fail-check))))

;;; ── Canned bodies ────────────────────────────────────────────────────────────
;;;
;;; The SAME logical turn expressed in each vendor's wire format: assistant says
;;; "Let me check." then calls tool `getWeather` with {"city":"Paris","days":3}.

(define anthropic-tooluse-body
  (hash 'id "msg_1"
        'type "message"
        'role "assistant"
        'content (list (hash 'type "text" 'text "Let me check.")
                       (hash 'type "tool_use"
                             'id "toolu_abc"
                             'name "getWeather"
                             'input (hash 'city "Paris" 'days 3)))
        'usage (hash 'input_tokens 42
                     'output_tokens 17
                     'cache_read_input_tokens 8
                     'cache_creation_input_tokens 5)
        'stop_reason "tool_use"))

;; OpenAI: arguments is a JSON *string*, content may be null, usage uses
;; prompt_tokens/completion_tokens and a nested prompt_tokens_details.cached_tokens.
(define openai-tooluse-body
  (hash 'id "chatcmpl_1"
        'object "chat.completion"
        'choices (list
                  (hash 'index 0
                        'finish_reason "tool_calls"
                        'message (hash 'role "assistant"
                                       'content "Let me check."
                                       'tool_calls
                                       (list (hash 'id "call_xyz"
                                                   'type "function"
                                                   'function (hash 'name "getWeather"
                                                                   'arguments "{\"city\":\"Paris\",\"days\":3}"))))))
        'usage (hash 'prompt_tokens 42
                     'completion_tokens 17
                     'prompt_tokens_details (hash 'cached_tokens 8))))

;; Plain text turn (no tools), each vendor.
(define anthropic-text-body
  (hash 'content (list (hash 'type "text" 'text "Hello there."))
        'usage (hash 'input_tokens 3 'output_tokens 4)
        'stop_reason "end_turn"))

(define openai-text-body
  (hash 'choices (list (hash 'finish_reason "stop"
                             'message (hash 'role "assistant" 'content "Hello there.")))
        'usage (hash 'prompt_tokens 3 'completion_tokens 4)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. tool-call normalization: Anthropic native object == OpenAI JSON string
;;; ════════════════════════════════════════════════════════════════════════════

(define a-resp (normalize anthropic-of anthropic-tooluse-body))
(define o-resp (normalize openai-of    openai-tooluse-body))

(test-case "both vendors produce exactly one tool-call"
  (check-equal? (length (llm-response-tool-calls a-resp)) 1 "anthropic 1 tool-call")
  (check-equal? (length (llm-response-tool-calls o-resp)) 1 "openai 1 tool-call"))

(test-case "tool-call name normalizes identically"
  (define a (first (llm-response-tool-calls a-resp)))
  (define o (first (llm-response-tool-calls o-resp)))
  (check-equal? (tool-call-name a) "getWeather")
  (check-equal? (tool-call-name o) "getWeather")
  (check-equal? (tool-call-name a) (tool-call-name o) "same name"))

(test-case "tool-call args parse to the SAME jsexpr (object vs JSON-string)"
  (define a (first (llm-response-tool-calls a-resp)))
  (define o (first (llm-response-tool-calls o-resp)))
  ;; The whole crux: OpenAI's arguments arrives as a STRING and must be parsed
  ;; into the same hash Anthropic delivers as a native object.
  (check-pred hash? (tool-call-args a) "anthropic args is a parsed object")
  (check-pred hash? (tool-call-args o) "openai args parsed from JSON string")
  (check-equal? (hash-ref (tool-call-args a) 'city) "Paris")
  (check-equal? (hash-ref (tool-call-args o) 'city) "Paris")
  (check-equal? (hash-ref (tool-call-args a) 'days) 3)
  (check-equal? (hash-ref (tool-call-args o) 'days) 3)
  (check-equal? (tool-call-args a) (tool-call-args o) "fully equal arg hashes")
  ;; and definitely NOT left as a raw string
  (check-false (string? (tool-call-args o)) "openai args must be parsed, not a string"))

(test-case "tool-call id is carried through from each vendor's field"
  (check-equal? (tool-call-id (first (llm-response-tool-calls a-resp))) "toolu_abc")
  (check-equal? (tool-call-id (first (llm-response-tool-calls o-resp))) "call_xyz"))

(test-case "assistant text accompanying a tool call is preserved"
  (check-equal? (llm-response-text a-resp) "Let me check.")
  (check-equal? (llm-response-text o-resp) "Let me check.")
  (check-equal? (llm-response-text a-resp) (llm-response-text o-resp)))

(test-case "stop-reason is 'tool-use for both vendors on a tool call"
  (check-equal? (llm-response-stop-reason a-resp) 'tool-use)
  (check-equal? (llm-response-stop-reason o-resp) 'tool-use)
  (check-equal? (llm-response-stop-reason a-resp) (llm-response-stop-reason o-resp)))

(test-case "the normalized tool-call TUPLES match across vendors except the vendor id"
  ;; name + args are vendor-agnostic; only the id string differs.
  (define a (first (calls->tuples (llm-response-tool-calls a-resp))))
  (define o (first (calls->tuples (llm-response-tool-calls o-resp))))
  (check-equal? (cdr a) (cdr o) "name+args identical")
  (check-not-equal? (car a) (car o) "ids are vendor-specific"))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. usage-token normalization
;;; ════════════════════════════════════════════════════════════════════════════

(test-case "usage maps to canonical input/output/cache-read/cache-write keys"
  (for ([r (list a-resp o-resp)] [who '(anthropic openai)])
    (define u (llm-response-usage r))
    (check-pred hash? u (format "~a usage is a hash" who))
    (check-true (hash-has-key? u 'input)       (format "~a has 'input" who))
    (check-true (hash-has-key? u 'output)      (format "~a has 'output" who))
    (check-true (hash-has-key? u 'cache-read)  (format "~a has 'cache-read" who))
    (check-true (hash-has-key? u 'cache-write) (format "~a has 'cache-write" who))))

(test-case "input/output token counts match across vendors"
  (check-equal? (hash-ref (llm-response-usage a-resp) 'input) 42)
  (check-equal? (hash-ref (llm-response-usage o-resp) 'input) 42)
  (check-equal? (hash-ref (llm-response-usage a-resp) 'output) 17)
  (check-equal? (hash-ref (llm-response-usage o-resp) 'output) 17)
  (check-equal? (hash-ref (llm-response-usage a-resp) 'input)
                (hash-ref (llm-response-usage o-resp) 'input))
  (check-equal? (hash-ref (llm-response-usage a-resp) 'output)
                (hash-ref (llm-response-usage o-resp) 'output)))

(test-case "cache-read maps from each vendor's distinct cache field"
  ;; anthropic: cache_read_input_tokens ; openai: prompt_tokens_details.cached_tokens
  (check-equal? (hash-ref (llm-response-usage a-resp) 'cache-read) 8)
  (check-equal? (hash-ref (llm-response-usage o-resp) 'cache-read) 8)
  (check-equal? (hash-ref (llm-response-usage a-resp) 'cache-read)
                (hash-ref (llm-response-usage o-resp) 'cache-read)))

(test-case "cache-write: anthropic carries creation tokens, openai defaults 0"
  (check-equal? (hash-ref (llm-response-usage a-resp) 'cache-write) 5
                "anthropic cache_creation_input_tokens")
  (check-equal? (hash-ref (llm-response-usage o-resp) 'cache-write) 0
                "openai has no creation field -> 0"))

(test-case "missing usage fields default to 0, never crash"
  (define a (normalize anthropic-of
                       (hash 'content (list (hash 'type "text" 'text "x"))
                             'stop_reason "end_turn")))   ;; no 'usage at all
  (define u (llm-response-usage a))
  (check-equal? (hash-ref u 'input) 0)
  (check-equal? (hash-ref u 'output) 0)
  (check-equal? (hash-ref u 'cache-read) 0)
  (check-equal? (hash-ref u 'cache-write) 0))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. plain-text turns
;;; ════════════════════════════════════════════════════════════════════════════

(define a-text (normalize anthropic-of anthropic-text-body))
(define o-text (normalize openai-of    openai-text-body))

(test-case "plain text turn: text equal, no tool-calls, 'end-turn stop"
  (check-equal? (llm-response-text a-text) "Hello there.")
  (check-equal? (llm-response-text o-text) "Hello there.")
  (check-equal? (llm-response-text a-text) (llm-response-text o-text))
  (check-equal? (llm-response-tool-calls a-text) '() "anthropic no tools")
  (check-equal? (llm-response-tool-calls o-text) '() "openai no tools")
  (check-equal? (llm-response-stop-reason a-text) 'end-turn)
  (check-equal? (llm-response-stop-reason o-text) 'end-turn)
  (check-equal? (llm-response-stop-reason a-text) (llm-response-stop-reason o-text)))

(test-case "anthropic concatenates multiple text blocks in order"
  (define r (normalize anthropic-of
                       (hash 'content (list (hash 'type "text" 'text "foo ")
                                            (hash 'type "text" 'text "bar"))
                             'usage (hash) 'stop_reason "end_turn")))
  (check-equal? (llm-response-text r) "foo bar"))

(test-case "openai null content normalizes to empty string"
  (define r (normalize openai-of
                       (hash 'choices (list (hash 'finish_reason "stop"
                                                  'message (hash 'role "assistant"
                                                                 'content (json-null))))
                             'usage (hash))))
  (check-equal? (llm-response-text r) "")
  (check-pred string? (llm-response-text r)))

(test-case "openai empty choices array degrades gracefully"
  (define r (normalize openai-of (hash 'choices '() 'usage (hash))))
  (check-equal? (llm-response-text r) "")
  (check-equal? (llm-response-tool-calls r) '())
  (check-equal? (llm-response-stop-reason r) 'other))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. stop-reason coverage (incl. refusal & max-tokens) — both vendors
;;; ════════════════════════════════════════════════════════════════════════════

(define (anthropic-stop body-stop)
  (llm-response-stop-reason
   (normalize anthropic-of
              (hash 'content (list (hash 'type "text" 'text "x"))
                    'usage (hash) 'stop_reason body-stop))))

(define (openai-stop finish)
  (llm-response-stop-reason
   (normalize openai-of
              (hash 'choices (list (hash 'finish_reason finish
                                         'message (hash 'role "assistant" 'content "x")))
                    'usage (hash)))))

(test-case "anthropic stop_reason mapping table"
  (check-equal? (anthropic-stop "end_turn")   'end-turn)
  (check-equal? (anthropic-stop "tool_use")   'tool-use)
  (check-equal? (anthropic-stop "max_tokens") 'max-tokens)
  (check-equal? (anthropic-stop "refusal")    'refusal)
  (check-equal? (anthropic-stop "stop_sequence") 'other "unknown -> 'other")
  (check-equal? (anthropic-stop "pause_turn")    'other))

(test-case "openai finish_reason mapping table"
  (check-equal? (openai-stop "stop")           'end-turn)
  (check-equal? (openai-stop "length")         'max-tokens)
  (check-equal? (openai-stop "content_filter") 'refusal)
  (check-equal? (openai-stop "function_call")  'other "legacy -> 'other"))

(test-case "refusal stop-reason agrees across vendors"
  (check-equal? (anthropic-stop "refusal") (openai-stop "content_filter"))
  (check-equal? (anthropic-stop "refusal") 'refusal))

(test-case "max-tokens stop-reason agrees across vendors"
  (check-equal? (anthropic-stop "max_tokens") (openai-stop "length"))
  (check-equal? (anthropic-stop "max_tokens") 'max-tokens))

(test-case "openai tool_calls present forces 'tool-use even with finish=stop"
  ;; openai-normalize keys 'tool-use off the presence of parsed tool-calls.
  (define r (normalize openai-of
                       (hash 'choices (list (hash 'finish_reason "stop"
                                                  'message (hash 'role "assistant"
                                                                 'content (json-null)
                                                                 'tool_calls
                                                                 (list (hash 'id "c1" 'type "function"
                                                                             'function (hash 'name "f" 'arguments "{}"))))))
                             'usage (hash))))
  (check-equal? (llm-response-stop-reason r) 'tool-use)
  (check-equal? (length (llm-response-tool-calls r)) 1))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. multiple tool calls in one turn — both vendors, same normalized list
;;; ════════════════════════════════════════════════════════════════════════════

(define anthropic-multi
  (hash 'content (list (hash 'type "tool_use" 'id "t1" 'name "alpha" 'input (hash 'n 1))
                       (hash 'type "tool_use" 'id "t2" 'name "beta"  'input (hash 'n 2)))
        'usage (hash 'input_tokens 1 'output_tokens 1)
        'stop_reason "tool_use"))

(define openai-multi
  (hash 'choices (list (hash 'finish_reason "tool_calls"
                             'message (hash 'role "assistant" 'content (json-null)
                                            'tool_calls
                                            (list (hash 'id "c1" 'type "function"
                                                        'function (hash 'name "alpha" 'arguments "{\"n\":1}"))
                                                  (hash 'id "c2" 'type "function"
                                                        'function (hash 'name "beta"  'arguments "{\"n\":2}"))))))
        'usage (hash 'prompt_tokens 1 'completion_tokens 1)))

(test-case "two tool calls preserved in order with parsed args (both vendors)"
  (define a (llm-response-tool-calls (normalize anthropic-of anthropic-multi)))
  (define o (llm-response-tool-calls (normalize openai-of    openai-multi)))
  (check-equal? (length a) 2)
  (check-equal? (length o) 2)
  (check-equal? (map tool-call-name a) '("alpha" "beta"))
  (check-equal? (map tool-call-name o) '("alpha" "beta"))
  (check-jsexpr=? (map tool-call-args a) (list (hash 'n 1) (hash 'n 2)))
  (check-jsexpr=? (map tool-call-args o) (list (hash 'n 1) (hash 'n 2)))
  (check-jsexpr=? (map tool-call-args a) (map tool-call-args o)))

(test-case "openai non-trivial nested args parse correctly from JSON string"
  (define o (llm-response-tool-calls
             (normalize openai-of
                        (hash 'choices (list (hash 'finish_reason "tool_calls"
                                                   'message (hash 'role "assistant" 'content (json-null)
                                                                  'tool_calls
                                                                  (list (hash 'id "c1" 'type "function"
                                                                              'function (hash 'name "save"
                                                                                              'arguments "{\"items\":[1,2,3],\"meta\":{\"ok\":true},\"name\":\"x\"}"))))))
                              'usage (hash)))))
  (define args (tool-call-args (first o)))
  (check-equal? (hash-ref args 'items) '(1 2 3))
  (check-jsexpr=? (hash-ref args 'meta) (hash 'ok #t))
  (check-equal? (hash-ref args 'name) "x"))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. request shaping (the OTHER direction the normalizer owns)
;;; ════════════════════════════════════════════════════════════════════════════

(test-case "anthropic request body carries model/system/max_tokens at top level"
  (define rb (box #f))
  (normalize anthropic-of anthropic-text-body #:req-box rb
             #:request (hash 'system "be terse" 'max-tokens 99 'messages '() 'tools '()))
  (define j (string->jsexpr (unbox rb)))
  (check-equal? (hash-ref j 'model) "claude-test")
  (check-equal? (hash-ref j 'system) "be terse")
  (check-equal? (hash-ref j 'max_tokens) 99)
  (check-equal? (hash-ref j 'messages) '()))

(test-case "openai request hoists system prompt into a leading system message"
  (define rb (box #f))
  (normalize openai-of openai-text-body #:req-box rb
             #:request (hash 'system "be terse" 'max-tokens 99 'messages '() 'tools '()))
  (define j (string->jsexpr (unbox rb)))
  (check-equal? (hash-ref j 'model) "gpt-test")
  (check-equal? (hash-ref j 'max_tokens) 99)
  (define msgs (hash-ref j 'messages))
  (check-equal? (length msgs) 1 "system folded into messages")
  (check-equal? (hash-ref (first msgs) 'role) "system")
  (check-equal? (hash-ref (first msgs) 'content) "be terse"))

(test-case "openai omits system message when system prompt is empty"
  (define rb (box #f))
  (normalize openai-of openai-text-body #:req-box rb
             #:request (hash 'system "" 'max-tokens 10 'messages '() 'tools '()))
  (define j (string->jsexpr (unbox rb)))
  (check-equal? (hash-ref j 'messages) '() "no empty system message injected"))

(test-case "anthropic tool declarations become input_schema-shaped tools[]"
  (define rb (box #f))
  (define schema (hash 'type "object" 'properties (hash 'q (hash 'type "string"))))
  (normalize anthropic-of anthropic-text-body #:req-box rb
             #:request (hash 'system "s" 'max-tokens 10 'messages '()
                             'tools (list (hash 'name "search" 'description "find" 'schema schema))))
  (define j (string->jsexpr (unbox rb)))
  (define t (first (hash-ref j 'tools)))
  (check-equal? (hash-ref t 'name) "search")
  (check-equal? (hash-ref t 'description) "find")
  (check-jsexpr=? (hash-ref t 'input_schema) schema))

(test-case "openai tool declarations wrap under function with strict + parameters"
  (define rb (box #f))
  (define schema (hash 'type "object" 'properties (hash 'q (hash 'type "string"))))
  (normalize openai-of openai-text-body #:req-box rb
             #:request (hash 'system "s" 'max-tokens 10 'messages '()
                             'tools (list (hash 'name "search" 'description "find" 'schema schema))))
  (define j (string->jsexpr (unbox rb)))
  (define t (first (hash-ref j 'tools)))
  (check-equal? (hash-ref t 'type) "function")
  (define fn (hash-ref t 'function))
  (check-equal? (hash-ref fn 'name) "search")
  (check-equal? (hash-ref fn 'description) "find")
  (check-equal? (hash-ref fn 'strict) #t "openai marks strict")
  (check-jsexpr=? (hash-ref fn 'parameters) schema))

(test-case "anthropic string message content passes through verbatim"
  (define rb (box #f))
  (normalize anthropic-of anthropic-text-body #:req-box rb
             #:request (hash 'system "s" 'max-tokens 10
                             'messages (list (hash 'role "user" 'content "ping"))
                             'tools '()))
  (define j (string->jsexpr (unbox rb)))
  (define m (first (hash-ref j 'messages)))
  (check-equal? (hash-ref m 'role) "user")
  (check-equal? (hash-ref m 'content) "ping"))

(test-case "anthropic structured tool-result block maps to tool_result type"
  (define rb (box #f))
  (normalize anthropic-of anthropic-text-body #:req-box rb
             #:request (hash 'system "s" 'max-tokens 10
                             'messages (list (hash 'role "user"
                                                   'content (list (hash 'kind 'tool-result
                                                                        'id "tr1"
                                                                        'content "42"
                                                                        'is-error #f))))
                             'tools '()))
  (define j (string->jsexpr (unbox rb)))
  (define blk (first (hash-ref (first (hash-ref j 'messages)) 'content)))
  (check-equal? (hash-ref blk 'type) "tool_result")
  (check-equal? (hash-ref blk 'tool_use_id) "tr1")
  (check-equal? (hash-ref blk 'content) "42")
  (check-equal? (hash-ref blk 'is_error) #f))

(test-case "openai tool-result block becomes a role:tool message"
  (define rb (box #f))
  (normalize openai-of openai-text-body #:req-box rb
             #:request (hash 'system "s" 'max-tokens 10
                             'messages (list (hash 'role "tool"
                                                   'content (list (hash 'kind 'tool-result
                                                                        'id "tr1"
                                                                        'content "42"))))
                             'tools '()))
  (define j (string->jsexpr (unbox rb)))
  ;; system prompt folds in first, so the tool message is last
  (define m (last (hash-ref j 'messages)))
  (check-equal? (hash-ref m 'role) "tool")
  (check-equal? (hash-ref m 'tool_call_id) "tr1")
  (check-equal? (hash-ref m 'content) "42"))

(test-case "openai assistant tool-use block re-serializes args back to a JSON string"
  (define rb (box #f))
  (normalize openai-of openai-text-body #:req-box rb
             #:request (hash 'system "" 'max-tokens 10
                             'messages (list (hash 'role "assistant"
                                                   'content (list (hash 'kind 'text 'text "calling")
                                                                  (hash 'kind 'tool-use 'id "c1"
                                                                        'name "f" 'args (hash 'x 1)))))
                             'tools '()))
  (define j (string->jsexpr (unbox rb)))
  (define m (first (hash-ref j 'messages)))
  (check-equal? (hash-ref m 'role) "assistant")
  (check-equal? (hash-ref m 'content) "calling")
  (define tc (first (hash-ref m 'tool_calls)))
  (check-equal? (hash-ref tc 'id) "c1")
  (check-equal? (hash-ref tc 'type) "function")
  ;; args must be a STRING on the wire for OpenAI, round-tripping to the object
  (define args-str (hash-ref (hash-ref tc 'function) 'arguments))
  (check-pred string? args-str "openai serializes args to a JSON string")
  (check-jsexpr=? (string->jsexpr args-str) (hash 'x 1)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. HTTP error surfacing — a 4xx/5xx body must raise, not normalize
;;; ════════════════════════════════════════════════════════════════════════════

(test-case "anthropic raises a localized error on HTTP 400"
  (check-exn
   (lambda (e) (and (exn:fail? e) (regexp-match? #rx"HTTP 400" (exn-message e))))
   (lambda () (normalize anthropic-of (hash 'error "bad request") #:status 400))))

(test-case "openai raises a localized error on HTTP 500"
  (check-exn
   (lambda (e) (and (exn:fail? e) (regexp-match? #rx"HTTP 500" (exn-message e))))
   (lambda () (normalize openai-of (hash 'error "boom") #:status 500))))

(test-case "error message names the offending provider"
  (check-exn
   (lambda (e) (regexp-match? #rx"anthropic" (exn-message e)))
   (lambda () (normalize anthropic-of (hash 'error "x") #:status 429)))
  (check-exn
   (lambda (e) (regexp-match? #rx"openai" (exn-message e)))
   (lambda () (normalize openai-of (hash 'error "x") #:status 401))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. the LOCAL provider is OpenAI-wire-compatible
;;; ════════════════════════════════════════════════════════════════════════════

(test-case "local provider normalizes an OpenAI-shaped tool-call body identically"
  (define r (normalize local-of openai-tooluse-body))
  (check-equal? (llm-response-text r) "Let me check.")
  (check-equal? (llm-response-stop-reason r) 'tool-use)
  (define tc (first (llm-response-tool-calls r)))
  (check-equal? (tool-call-name tc) "getWeather")
  (check-jsexpr=? (tool-call-args tc) (hash 'city "Paris" 'days 3))
  (check-equal? (tool-call-id tc) "call_xyz"))

(test-case "local provider matches openai provider on the SAME body"
  (define rl (normalize local-of openai-tooluse-body))
  (define ro (normalize openai-of openai-tooluse-body))
  (check-equal? (llm-response-text rl) (llm-response-text ro))
  (check-equal? (calls->tuples (llm-response-tool-calls rl))
                (calls->tuples (llm-response-tool-calls ro)))
  (check-equal? (llm-response-usage rl) (llm-response-usage ro))
  (check-equal? (llm-response-stop-reason rl) (llm-response-stop-reason ro)))

(test-case "local provider request uses the OpenAI wire format"
  (define rb (box #f))
  (normalize local-of openai-text-body #:req-box rb
             #:request (hash 'system "sys" 'max-tokens 5 'messages '() 'tools '()))
  (define j (string->jsexpr (unbox rb)))
  (check-equal? (hash-ref j 'model) "local-model")
  ;; system folded into a leading system message (OpenAI shape)
  (check-equal? (hash-ref (first (hash-ref j 'messages)) 'role) "system"))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. the MOCK provider — deterministic, no network, same normalized shape
;;; ════════════════════════════════════════════════════════════════════════════

(test-case "mock provider wraps a bare string into an end-turn text llm-response"
  (define mp (make-mock-provider (list "alpha" "beta")))
  (define r1 (mp (hash)))
  (check-pred llm-response? r1)
  (check-equal? (llm-response-text r1) "alpha")
  (check-equal? (llm-response-tool-calls r1) '())
  (check-equal? (llm-response-stop-reason r1) 'end-turn)
  (check-equal? (llm-response-usage r1) (hash) "default empty usage"))

(test-case "mock provider returns scripted responses by call index"
  (define mp (make-mock-provider (list "one" "two" "three")))
  (check-equal? (llm-response-text (mp (hash))) "one")
  (check-equal? (llm-response-text (mp (hash))) "two")
  (check-equal? (llm-response-text (mp (hash))) "three"))

(test-case "mock provider passes through a pre-built llm-response (tool-call script)"
  (define scripted
    (llm-response "thinking"
                  (hash 'input 1 'output 2)
                  (list (tool-call "id1" "doThing" (hash 'k "v")))
                  'tool-use))
  (define mp (make-mock-provider (list scripted "done")))
  (define r1 (mp (hash)))
  (check-equal? (llm-response-stop-reason r1) 'tool-use)
  (check-equal? (length (llm-response-tool-calls r1)) 1)
  (check-equal? (tool-call-name (first (llm-response-tool-calls r1))) "doThing")
  (check-equal? (tool-call-args (first (llm-response-tool-calls r1))) (hash 'k "v"))
  ;; second call advances to the text response
  (check-equal? (llm-response-text (mp (hash))) "done"))

(test-case "mock provider tool-call shape matches the real-provider shape"
  ;; A mock tool-call and an anthropic-normalized tool-call are indistinguishable
  ;; at the type level — that is what makes mock a faithful test double.
  (define mp (make-mock-provider
              (list (llm-response "" (hash) (list (tool-call "toolu_abc" "getWeather"
                                                             (hash 'city "Paris" 'days 3))) 'tool-use))))
  (define mock-tc (first (llm-response-tool-calls (mp (hash)))))
  (define real-tc (first (llm-response-tool-calls a-resp)))
  (check-equal? (tool-call-id mock-tc) (tool-call-id real-tc))
  (check-equal? (tool-call-name mock-tc) (tool-call-name real-tc))
  (check-jsexpr=? (tool-call-args mock-tc) (tool-call-args real-tc)))

(test-case "mock provider raises a user error when the script is exhausted"
  (define mp (make-mock-provider (list "only")))
  (check-equal? (llm-response-text (mp (hash))) "only")
  (check-exn
   (lambda (e) (and (exn:fail? e) (regexp-match? #rx"exhausted" (exn-message e))))
   (lambda () (mp (hash)))))

(test-case "mock provider rejects a non-string / non-llm-response script entry"
  (check-exn
   (lambda (e) (and (exn:fail? e)
                    (regexp-match? #rx"String or llm-response" (exn-message e))))
   (lambda () (make-mock-provider (list 42)))))

(test-case "mock provider ignores the request argument (pure by index)"
  (define mp (make-mock-provider (list "x" "y")))
  ;; wildly different requests, still index-driven
  (check-equal? (llm-response-text (mp (hash 'anything 1))) "x")
  (check-equal? (llm-response-text (mp 'not-even-a-hash)) "y"))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. call-provider choke point invariants
;;; ════════════════════════════════════════════════════════════════════════════

(test-case "call-provider returns the provider's llm-response unchanged"
  (define resp (llm-response "hi" (hash 'input 1) '() 'end-turn))
  (define prov (lambda (_req) resp))
  (check-eq? (call-provider prov (hash)) resp "passes the same struct through"))

(test-case "call-provider rejects a provider that returns a non-llm-response"
  (check-exn
   (lambda (e) (and (exn:fail? e)
                    (regexp-match? #rx"expected an llm-response" (exn-message e))))
   (lambda () (call-provider (lambda (_req) "just a string") (hash)))))

(test-case "call-provider forwards the request hash to the provider"
  (define seen (box #f))
  (define prov (lambda (req) (set-box! seen req) (llm-response "" (hash) '() 'end-turn)))
  (call-provider prov (hash 'marker 123))
  (check-equal? (unbox seen) (hash 'marker 123)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 11. struct + export sanity
;;; ════════════════════════════════════════════════════════════════════════════

(test-case "llm-response struct is transparent with the documented field order"
  (define r (llm-response "t" (hash 'input 5) (list (tool-call "i" "n" (hash))) 'tool-use))
  (check-equal? (llm-response-text r) "t")
  (check-equal? (llm-response-usage r) (hash 'input 5))
  (check-equal? (llm-response-stop-reason r) 'tool-use)
  (check-pred llm-response? r)
  (check-false (llm-response? "nope")))

(test-case "tool-call struct is transparent with id/name/args accessors"
  (define tc (tool-call "id1" "tool" (hash 'a 1)))
  (check-equal? (tool-call-id tc) "id1")
  (check-equal? (tool-call-name tc) "tool")
  (check-equal? (tool-call-args tc) (hash 'a 1))
  (check-pred tool-call? tc)
  (check-false (tool-call? (llm-response "" (hash) '() 'end-turn))))

(test-case "provider constructors all produce callable procedures"
  (check-pred procedure? (make-mock-provider '("x")))
  (check-pred procedure? (make-anthropic-provider "k" "m"))
  (check-pred procedure? (make-openai-provider "k" "m"))
  (check-pred procedure? (make-local-provider "http://x" "m"))
  (check-pred procedure? call-provider))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 12. cross-vendor end-to-end equivalence (the headline guarantee)
;;; ════════════════════════════════════════════════════════════════════════════

(test-case "FULL equivalence: same logical turn, identical normalized shape (modulo id)"
  (define a (normalize anthropic-of anthropic-tooluse-body))
  (define o (normalize openai-of    openai-tooluse-body))
  ;; text
  (check-equal? (llm-response-text a) (llm-response-text o))
  ;; usage: the cross-vendor fields agree (input/output/cache-read).  cache-write
  ;; is an Anthropic-only concept (prompt-cache creation), so it is NOT expected
  ;; to match — see the dedicated cache-write test above.
  (for ([k '(input output cache-read)])
    (check-equal? (hash-ref (llm-response-usage a) k)
                  (hash-ref (llm-response-usage o) k)
                  (format "usage key ~a" k)))
  ;; stop-reason
  (check-equal? (llm-response-stop-reason a) (llm-response-stop-reason o))
  ;; tool-calls: name + args identical, id intentionally vendor-specific
  (define at (first (llm-response-tool-calls a)))
  (define ot (first (llm-response-tool-calls o)))
  (check-equal? (tool-call-name at) (tool-call-name ot))
  (check-jsexpr=? (tool-call-args at) (tool-call-args ot)))
