#lang racket

;;; Tesl.Agent provider substrate (AI Tier-0 — Wave 2a).
;;;
;;; This module defines the *normalized provider response shape* that every
;;; LLM provider (anthropic / openai / local / mock) must produce, plus the
;;; concrete provider constructors.  A "provider" is a plain Racket procedure
;;; of one argument — a normalized REQUEST hash — returning a `llm-response`
;;; struct.  The agent core (tesl/agent.rkt) only ever sees this normalized
;;; shape on both sides, so it is fully provider-agnostic.
;;;
;;; Normalized REQUEST hash (built by the agent core, consumed by providers):
;;;   'system     : String           — system prompt
;;;   'max-tokens : Int
;;;   'messages   : (listof message) — conversation so far; a message is a hash
;;;                  (hash 'role "user"|"assistant"|"tool" 'content <content>)
;;;                  where content is either a String or a list of content
;;;                  blocks (tool_use / tool_result), already in normalized form.
;;;   'tools      : (listof tool-decl) — each (hash 'name 'description 'schema)
;;;                  where 'schema is a jsexpr (parsed JSON Schema object).
;;;
;;; Normalized RESPONSE (`llm-response`):
;;;   text        : String           — assistant text (may be "")
;;;   usage       : hash             — token accounting, e.g.
;;;                   (hash 'input N 'output M 'cache-read R 'cache-write W)
;;;   tool-calls  : (listof tool-call) — each `tool-call` carries the model's
;;;                   request to invoke a tool: id + name + args (parsed jsexpr).
;;;   stop-reason : symbol           — 'end-turn | 'tool-use | 'max-tokens
;;;                   | 'refusal | 'other
;;;
;;; Real providers call out over HTTP via tesl/http-client.rkt, so granting
;;; aiProvider (which implies httpClient) covers the network.  `call-provider`
;;; remains the single choke point through which the agent core invokes any
;;; provider.

(require json
         racket/runtime-path
         (only-in "../dsl/types.rkt" record-value-fields record-value?)
         (only-in "../dsl/private/evidence.rkt" raw-value)
         (only-in "../dsl/metrics.rkt"
                  metrics-active?
                  metric-counter-add!
                  metric-histogram-record!
                  duration-histogram-boundaries))

;; Resolve http-client.rkt relative to THIS source file (it sits beside us in
;; tesl/), not via the `tesl` collection or the CWD — so the dynamic-require
;; works regardless of where/how the process is launched.
(define-runtime-path http-client-source "http-client.rkt")

(provide (struct-out llm-response)
         (struct-out tool-call)
         make-mock-provider
         make-anthropic-provider
         make-openai-provider
         make-local-provider
         register-provider-metadata!
         call-provider
         ;; #23: SSE token-stream parsers (exported for offline unit tests).
         anthropic-parse-stream
         openai-parse-stream)

;;; A single tool invocation requested by the model.
;;;   id   : String  — provider-assigned call id (echoed back in tool_result)
;;;   name : String  — the tool name the model wants to call
;;;   args : jsexpr  — the parsed JSON arguments object
(struct tool-call (id name args) #:transparent)

;;; The normalized response shape produced by every provider.
(struct llm-response (text usage tool-calls stop-reason) #:transparent)

;;; ── Provider metadata (metrics) ──────────────────────────────────────────────
;;; Providers are opaque closures, so the provider kind + model strings the
;;; constructors close over would be unreachable at the call-provider choke
;;; point.  Each constructor registers its closure here (weak keys: a dropped
;;; provider must stay collectable).  Lookup failure degrades to "unknown" —
;;; metrics must never constrain what counts as a provider (askWith accepts any
;;; procedure).
(define provider-metadata (make-weak-hasheq))

(define (register-provider-metadata! proc provider-name model)
  (hash-set! provider-metadata proc (cons provider-name model))
  proc)

;;; Backwards/ergonomic constructor: a bare text reply with no tools.
(define (text-response text [usage (hash)])
  (llm-response text usage '() 'end-turn))

;;; ── Mock provider ────────────────────────────────────────────────────────────
;;;
;;; make-mock-provider : (listof (or/c string? llm-response?)) -> provider
;;;
;;; Returns a deterministic provider procedure.  Each call returns the next
;;; scripted response by call index (0, 1, 2, ...).  A scripted entry that is a
;;; bare string is wrapped into a text `llm-response`; an entry that is already
;;; an `llm-response` is returned as-is — this is how a test scripts a
;;; tool-call sequence (return an llm-response whose tool-calls is non-empty and
;;; stop-reason is 'tool-use, then a later entry with the final text).
;;;
;;; Calling past the end of the script raises a user error: that is a
;;; test-authoring bug (more provider round-trips than scripted), and surfacing
;;; it deterministically is more useful than silently repeating.
(define (make-mock-provider scripted-responses)
  (define script
    (for/list ([r (in-list scripted-responses)])
      (cond
        [(llm-response? r) r]
        [(string? r) (text-response r)]
        [else (raise-user-error
               'mockProvider
               "scripted response must be a String or llm-response, got ~e" r)])))
  (define total (length script))
  (define calls 0)
  (lambda (request)
    (when (>= calls total)
      (raise-user-error
       'mockProvider
       "mock provider exhausted: ~a call(s) made but only ~a scripted response(s)"
       (add1 calls) total))
    (define resp (list-ref script calls))
    (set! calls (add1 calls))
    ;; #23: simulate token streaming so a streaming chat UI (and tests) exercise
    ;; the delta path with no real API.  Split the reply into word/space chunks
    ;; (concatenation reproduces the text exactly) and emit each as a delta.  Only
    ;; for a text turn — a tool-use step streams no user-facing text, like a real
    ;; provider.
    (define on-delta (and (hash? request) (hash-ref request 'on-delta #f)))
    (when (and on-delta (llm-response? resp) (null? (llm-response-tool-calls resp)))
      (for ([chunk (in-list (regexp-match* #px"\\s+|\\S+" (llm-response-text resp)))])
        (on-delta chunk)))
    resp))

;;; ── HTTP plumbing shared by the real providers ───────────────────────────────
;;;
;;; Real providers POST a JSON body and read back a JSON response.  They go
;;; through tesl/http-client.rkt's `HttpClient.post` so the network is gated by
;;; httpClient exactly like every other outbound call.  We `dynamic-require` it
;;; to avoid a load-time cycle (agent.rkt also requires http-client.rkt for the
;;; capability) and so the mock-only test path never touches net code.
(define (http-post-json url headers-alist body-jsexpr)
  (define post
    (dynamic-require http-client-source 'HttpClient.post))
  ;; headers as Tesl Tuple2 list (2-element lists), body as a JSON string.
  (define header-list
    (for/list ([h (in-list headers-alist)]) (list (car h) (cdr h))))
  (define body-str (jsexpr->string body-jsexpr))
  (define resp (post url header-list body-str))
  (define fields (record-value-fields (raw-value resp)))
  (define status (raw-value (hash-ref fields 'status)))
  (define body (raw-value (hash-ref fields 'body)))
  (values status body))

;;; Parse a JSON response body, raising a localized error on malformed JSON.
(define (parse-json-body who body-str)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (raise-user-error who "provider returned non-JSON body: ~a"
                                       (exn-message e)))])
    (string->jsexpr body-str)))

(define (jref h key [default #f])
  (if (hash? h) (hash-ref h key default) default))

;;; ── #23: token streaming (Server-Sent Events) ────────────────────────────────
;;;
;;; When a request carries an `on-delta` callback (set by the agentic loop for the
;;; converseStreaming / agentRun path), the real providers request the streaming
;;; API (`stream: true`) and invoke `on-delta` with each text delta as the model
;;; generates it — so an SSE chat UI can render incremental output.  The parsers
;;; accumulate the deltas back into the SAME `llm-response` a blocking call would
;;; return (text + tool-calls + usage + stop-reason), so the agentic loop, tool
;;; dispatch, and transcript threading are all unchanged.  Parsers are pure over
;;; an input port, so they unit-test against canned SSE bytes (no network).

;; Open a streaming POST and hand the response body port to `parse`, which reads
;; SSE and returns an llm-response.  The port is closed when parsing finishes.
(define (stream-post who url headers-alist body-jsexpr parse)
  (define post-stream (dynamic-require http-client-source 'http-post-stream))
  (define header-list (for/list ([h (in-list headers-alist)]) (list (car h) (cdr h))))
  (define-values (status port)
    (post-stream url header-list (jsexpr->string body-jsexpr)))
  (dynamic-wind
   void
   (lambda ()
     (when (>= status 400)
       (raise-user-error who "API error (HTTP ~a): ~a" status (port->string port)))
     (parse port))
   (lambda () (with-handlers ([exn:fail? void]) (close-input-port port)))))

;; Call (on-data payload-string) for each SSE `data:` line, stopping at EOF or a
;; `[DONE]` sentinel (OpenAI).  `event:`/`id:`/comment/blank lines are skipped.
(define (for-each-sse-data port on-data)
  (let loop ()
    (define line (read-line port 'any))
    (unless (eof-object? line)
      (define t (string-trim line))
      (cond
        [(string=? t "") (loop)]
        [(and (>= (string-length t) 5) (string=? (substring t 0 5) "data:"))
         (define payload (string-trim (substring t 5)))
         (unless (string=? payload "[DONE]")
           (on-data payload)
           (loop))]
        [else (loop)]))))

;; Parse an Anthropic streaming response (message_start / content_block_delta
;; text_delta + input_json_delta / message_delta) into an llm-response.
(define (anthropic-parse-stream port on-delta)
  (define text-acc (open-output-string))
  (define tool-blocks (make-hash))   ; index -> mutable hash: 'id 'name 'json(output-string)
  (define tool-order '())
  (define usage (box (hash 'input 0 'output 0 'cache-read 0 'cache-write 0)))
  (define stop (box 'other))
  (define (bump-usage u)
    (define a (unbox usage))
    (set-box! usage
              (hash 'input       (max (hash-ref a 'input 0)       (jref u 'input_tokens 0))
                    'output      (max (hash-ref a 'output 0)      (jref u 'output_tokens 0))
                    'cache-read  (max (hash-ref a 'cache-read 0)  (jref u 'cache_read_input_tokens 0))
                    'cache-write (max (hash-ref a 'cache-write 0) (jref u 'cache_creation_input_tokens 0)))))
  (for-each-sse-data port
    (lambda (payload)
      (define j (with-handlers ([exn:fail? (lambda (_e) #f)]) (string->jsexpr payload)))
      (when (hash? j)
        (define ty (jref j 'type))
        (cond
          [(equal? ty "message_start")
           (bump-usage (jref (jref j 'message (hash)) 'usage (hash)))]
          [(equal? ty "content_block_start")
           (define cb (jref j 'content_block (hash)))
           (when (equal? (jref cb 'type) "tool_use")
             (define idx (jref j 'index 0))
             (hash-set! tool-blocks idx
                        (hash 'id (jref cb 'id "") 'name (jref cb 'name "")
                              'json (open-output-string)))
             (set! tool-order (append tool-order (list idx))))]
          [(equal? ty "content_block_delta")
           (define d (jref j 'delta (hash)))
           (cond
             [(equal? (jref d 'type) "text_delta")
              (define t (jref d 'text ""))
              (write-string t text-acc)
              (on-delta t)]
             [(equal? (jref d 'type) "input_json_delta")
              (define blk (hash-ref tool-blocks (jref j 'index 0) #f))
              (when blk (write-string (jref d 'partial_json "") (hash-ref blk 'json)))])]
          [(equal? ty "message_delta")
           (define sr (jref (jref j 'delta (hash)) 'stop_reason))
           (when sr (set-box! stop (anthropic-stop-reason sr)))
           (bump-usage (jref j 'usage (hash)))]
          [else (void)]))))
  (define tool-calls
    (for/list ([idx (in-list tool-order)])
      (define blk (hash-ref tool-blocks idx))
      (define js (string-trim (get-output-string (hash-ref blk 'json))))
      (define args (if (> (string-length js) 0)
                       (with-handlers ([exn:fail? (lambda (_e) (hash))]) (string->jsexpr js))
                       (hash)))
      (tool-call (hash-ref blk 'id) (hash-ref blk 'name) args)))
  (llm-response (get-output-string text-acc) (unbox usage) tool-calls (unbox stop)))

;; Parse an OpenAI streaming response (choices[].delta.content / .tool_calls,
;; finish_reason, optional usage) into an llm-response.
(define (openai-parse-stream port on-delta)
  (define text-acc (open-output-string))
  (define tool-blocks (make-hash))   ; index -> mutable hash: 'id 'name 'args(output-string)
  (define tool-order '())
  (define stop (box 'other))
  (define usage (box (hash 'input 0 'output 0 'cache-read 0 'cache-write 0)))
  (for-each-sse-data port
    (lambda (payload)
      (define j (with-handlers ([exn:fail? (lambda (_e) #f)]) (string->jsexpr payload)))
      (when (hash? j)
        (define cs (jref j 'choices '()))
        (define choice (if (pair? cs) (first cs) (hash)))
        (define delta (jref choice 'delta (hash)))
        (define content (jref delta 'content #f))
        (when (and (string? content) (> (string-length content) 0))
          (write-string content text-acc)
          (on-delta content))
        (for ([tc (in-list (jref delta 'tool_calls '()))])
          (define idx (jref tc 'index 0))
          (unless (hash-has-key? tool-blocks idx)
            (hash-set! tool-blocks idx (hash 'id "" 'name "" 'args (open-output-string)))
            (set! tool-order (append tool-order (list idx))))
          (define blk (hash-ref tool-blocks idx))
          (define fn (jref tc 'function (hash)))
          (when (jref tc 'id)   (hash-set! tool-blocks idx (hash-set blk 'id (jref tc 'id))))
          (define blk2 (hash-ref tool-blocks idx))
          (when (jref fn 'name) (hash-set! tool-blocks idx (hash-set blk2 'name (jref fn 'name))))
          (define blk3 (hash-ref tool-blocks idx))
          (define a (jref fn 'arguments))
          (when (string? a) (write-string a (hash-ref blk3 'args))))
        (define fr (jref choice 'finish_reason))
        (when fr (set-box! stop (openai-stop-reason fr (positive? (hash-count tool-blocks)))))
        (define u (jref j 'usage #f))
        (when (hash? u)
          (set-box! usage
                    (hash 'input (jref u 'prompt_tokens 0)
                          'output (jref u 'completion_tokens 0)
                          'cache-read 0 'cache-write 0))))))
  (define tool-calls
    (for/list ([idx (in-list tool-order)])
      (define blk (hash-ref tool-blocks idx))
      (define js (string-trim (get-output-string (hash-ref blk 'args))))
      (define args (if (> (string-length js) 0)
                       (with-handlers ([exn:fail? (lambda (_e) (hash))]) (string->jsexpr js))
                       (hash)))
      (tool-call (hash-ref blk 'id) (hash-ref blk 'name) args)))
  (llm-response (get-output-string text-acc) (unbox usage) tool-calls (unbox stop)))

;;; ── Anthropic provider ────────────────────────────────────────────────────────
;;;
;;; POST https://api.anthropic.com/v1/messages
;;; headers: x-api-key, anthropic-version, content-type
;;; tools[]: {name, description, input_schema}
;;; response content[] carries text blocks and tool_use blocks; usage carries
;;; input/output + cache_creation/cache_read tokens; stop_reason mapped.
(define anthropic-version "2023-06-01")
(define (make-anthropic-provider api-key model
                                 [endpoint "https://api.anthropic.com/v1/messages"])
  (register-provider-metadata!
   (lambda (request)
    (define on-delta (and (hash? request) (hash-ref request 'on-delta #f)))
    (define headers
      (list (cons "x-api-key" api-key)
            (cons "anthropic-version" anthropic-version)
            (cons "content-type" "application/json")))
    (define base-body
      (hash 'model model
            'max_tokens (hash-ref request 'max-tokens 1024)
            'system (hash-ref request 'system "")
            'messages (anthropic-messages (hash-ref request 'messages '()))
            'tools (anthropic-tools (hash-ref request 'tools '()))))
    (cond
      ;; #23: token streaming — request stream:true and forward text deltas.
      [on-delta
       (stream-post 'anthropic endpoint headers (hash-set base-body 'stream #t)
                    (lambda (port) (anthropic-parse-stream port on-delta)))]
      [else
       (define-values (status raw) (http-post-json endpoint headers base-body))
       (define j (parse-json-body 'anthropic raw))
       (when (>= status 400)
         (raise-user-error 'anthropic "API error (HTTP ~a): ~a" status raw))
       (anthropic-normalize j)]))
   "anthropic" model))

(define (anthropic-tools tools)
  (for/list ([t (in-list tools)])
    (hash 'name (hash-ref t 'name)
          'description (hash-ref t 'description "")
          'input_schema (hash-ref t 'schema (hash 'type "object")))))

;; Normalized messages -> Anthropic content blocks.  A normalized message whose
;; content is a list already carries provider-agnostic block hashes (kind tagged).
;;
;; #21: the runtime's canonical transcript uses OpenAI's convention — a tool
;; result is its own message with `role: "tool"` (see run-loop + openai-messages).
;; Anthropic has no "tool" role: a tool_result is a content block sent back under
;; `role: "user"` (the two allowed roles are "user"/"assistant").  Passing "tool"
;; through verbatim made every tool-use turn fail with HTTP 400
;; ("Unexpected role \"tool\""), so `asTool` was unusable on the anthropic
;; provider.  Remap "tool" -> "user" here; the tool_result content block itself is
;; already emitted correctly by [anthropic-block].
(define (anthropic-role role)
  (if (equal? role "tool") "user" role))
(define (anthropic-messages messages)
  (for/list ([m (in-list messages)])
    (define role (anthropic-role (hash-ref m 'role)))
    (define content (hash-ref m 'content))
    (cond
      [(string? content) (hash 'role role 'content content)]
      [else (hash 'role role
                  'content (map anthropic-block content))])))

(define (anthropic-block b)
  (case (hash-ref b 'kind)
    [(text)        (hash 'type "text" 'text (hash-ref b 'text))]
    [(tool-use)    (hash 'type "tool_use" 'id (hash-ref b 'id)
                         'name (hash-ref b 'name) 'input (hash-ref b 'args))]
    [(tool-result) (hash 'type "tool_result"
                         'tool_use_id (hash-ref b 'id)
                         'content (hash-ref b 'content)
                         'is_error (hash-ref b 'is-error #f))]
    [else (raise-user-error 'anthropic "unknown content block kind ~e" b)]))

(define (anthropic-normalize j)
  (define content (jref j 'content '()))
  (define text
    (apply string-append
           (for/list ([blk (in-list content)]
                      #:when (equal? (jref blk 'type) "text"))
             (jref blk 'text ""))))
  (define tool-calls
    (for/list ([blk (in-list content)]
               #:when (equal? (jref blk 'type) "tool_use"))
      (tool-call (jref blk 'id "") (jref blk 'name "") (jref blk 'input (hash)))))
  (define u (jref j 'usage (hash)))
  (define usage
    (hash 'input (jref u 'input_tokens 0)
          'output (jref u 'output_tokens 0)
          'cache-read (jref u 'cache_read_input_tokens 0)
          'cache-write (jref u 'cache_creation_input_tokens 0)))
  (llm-response text usage tool-calls
                (anthropic-stop-reason (jref j 'stop_reason))))

(define (anthropic-stop-reason s)
  (cond
    [(equal? s "end_turn") 'end-turn]
    [(equal? s "tool_use") 'tool-use]
    [(equal? s "max_tokens") 'max-tokens]
    [(equal? s "refusal") 'refusal]
    [else 'other]))

;;; ── OpenAI provider ────────────────────────────────────────────────────────────
;;;
;;; POST .../v1/chat/completions
;;; tools[]: {type:"function", function:{name, description, strict:true, parameters}}
;;; response choices[].message.tool_calls[].function.arguments is a JSON STRING
;;; → must be parsed.  usage prompt_tokens/completion_tokens.
(define (make-openai-provider api-key model
                              [endpoint "https://api.openai.com/v1/chat/completions"])
  (register-provider-metadata!
   (lambda (request)
    (define on-delta (and (hash? request) (hash-ref request 'on-delta #f)))
    (define headers
      (list (cons "authorization" (string-append "Bearer " api-key))
            (cons "content-type" "application/json")))
    (define base-body
      (hash 'model model
            'max_tokens (hash-ref request 'max-tokens 1024)
            'messages (openai-messages (hash-ref request 'system "")
                                       (hash-ref request 'messages '()))
            'tools (openai-tools (hash-ref request 'tools '()))))
    (cond
      ;; #23: token streaming — stream:true + ask for usage in the final chunk.
      [on-delta
       (stream-post 'openai endpoint headers
                    (hash-set* base-body 'stream #t
                               'stream_options (hash 'include_usage #t))
                    (lambda (port) (openai-parse-stream port on-delta)))]
      [else
       (define-values (status raw) (http-post-json endpoint headers base-body))
       (define j (parse-json-body 'openai raw))
       (when (>= status 400)
         (raise-user-error 'openai "API error (HTTP ~a): ~a" status raw))
       (openai-normalize j)]))
   "openai" model))

(define (openai-tools tools)
  (for/list ([t (in-list tools)])
    (hash 'type "function"
          'function (hash 'name (hash-ref t 'name)
                          'description (hash-ref t 'description "")
                          'strict #t
                          'parameters (hash-ref t 'schema (hash 'type "object"))))))

(define (openai-messages system messages)
  (define sys (if (and (string? system) (> (string-length system) 0))
                  (list (hash 'role "system" 'content system)) '()))
  (append sys
          (for/list ([m (in-list messages)])
            (define role (hash-ref m 'role))
            (define content (hash-ref m 'content))
            (cond
              [(string? content) (hash 'role role 'content content)]
              [else (openai-structured-message role content)]))))

;; OpenAI represents an assistant tool call differently from a tool result.
(define (openai-structured-message role blocks)
  (cond
    [(equal? role "tool")
     ;; tool result: one block -> a tool message
     (define b (first blocks))
     (hash 'role "tool" 'tool_call_id (hash-ref b 'id)
           'content (hash-ref b 'content))]
    [else
     (define text-blocks (filter (lambda (b) (eq? (hash-ref b 'kind) 'text)) blocks))
     (define tu (filter (lambda (b) (eq? (hash-ref b 'kind) 'tool-use)) blocks))
     (hash 'role role
           'content (apply string-append (map (lambda (b) (hash-ref b 'text)) text-blocks))
           'tool_calls (for/list ([b (in-list tu)])
                         (hash 'id (hash-ref b 'id) 'type "function"
                               'function (hash 'name (hash-ref b 'name)
                                               'arguments (jsexpr->string (hash-ref b 'args))))))]))

(define (openai-normalize j)
  (define choices (jref j 'choices '()))
  (define msg (if (pair? choices) (jref (first choices) 'message (hash)) (hash)))
  (define text (or (jref msg 'content) ""))
  (define raw-calls (jref msg 'tool_calls '()))
  (define tool-calls
    (for/list ([c (in-list raw-calls)])
      (define fn (jref c 'function (hash)))
      (define args-str (jref fn 'arguments "{}"))
      (tool-call (jref c 'id "")
                 (jref fn 'name "")
                 ;; OpenAI gives arguments as a JSON *string* — parse it.
                 (parse-json-body 'openai args-str))))
  (define u (jref j 'usage (hash)))
  (define usage
    (hash 'input (jref u 'prompt_tokens 0)
          'output (jref u 'completion_tokens 0)
          'cache-read (jref (jref u 'prompt_tokens_details (hash)) 'cached_tokens 0)
          'cache-write 0))
  (define finish (if (pair? choices) (jref (first choices) 'finish_reason) #f))
  (llm-response (if (string? text) text "") usage tool-calls
                (openai-stop-reason finish (pair? tool-calls))))

(define (openai-stop-reason finish has-tools?)
  (cond
    [has-tools? 'tool-use]
    [(equal? finish "stop") 'end-turn]
    [(equal? finish "tool_calls") 'tool-use]
    [(equal? finish "length") 'max-tokens]
    [(equal? finish "content_filter") 'refusal]
    [else 'other]))

;;; ── Local provider ───────────────────────────────────────────────────────────
;;;
;;; An explicit endpoint, OpenAI-compatible wire format by default.  This is the
;;; escape hatch for self-hosted / OpenAI-compatible servers (llama.cpp, vLLM,
;;; Ollama's /v1, etc.): the developer supplies the endpoint explicitly.
(define (make-local-provider endpoint model [api-key ""])
  ;; Re-register under "local" so metrics distinguish self-hosted endpoints
  ;; from api.openai.com even though the wire format is shared.
  (register-provider-metadata! (make-openai-provider api-key model endpoint)
                               "local" model))

;;; ── The single choke point ─────────────────────────────────────────────────
;;; call-provider : provider request -> llm-response
;;; The agent core never invokes a provider procedure directly; everything goes
;;; through here, giving later waves one place for retries / telemetry / cost.
(define (call-provider provider request)
  (define metric-start (and (metrics-active?) (current-inexact-milliseconds)))
  (define resp (provider request))
  (unless (llm-response? resp)
    (raise-user-error 'agent
                      "provider returned ~e, expected an llm-response" resp))
  ;; Metrics: LLM call count + latency + token usage, all from this one choke
  ;; point.  Usage was already normalized by every provider ('input/'output/
  ;; 'cache-read/'cache-write) and then only aggregated per-conversation — the
  ;; per-call counters here are what make cost visible over time.
  (when metric-start
    (define meta (hash-ref provider-metadata provider #f))
    (define attrs
      (list (cons "gen_ai.provider.name" (if meta (car meta) "unknown"))
          (cons "gen_ai.request.model" (if meta (cdr meta) "unknown"))))
    (metric-counter-add! "tesl.agent.calls" 1 attrs)
    (metric-histogram-record!
     "gen_ai.client.operation.duration"
     (/ (- (current-inexact-milliseconds) metric-start) 1000.0)
     attrs
     #:unit "s"
     #:boundaries duration-histogram-boundaries)
    (define usage (llm-response-usage resp))
    (when (hash? usage)
      (for ([(token-type count) (in-hash usage)])
        (when (and (number? count) (positive? count))
          (metric-counter-add! "gen_ai.client.token.usage" count
                               (cons (cons "gen_ai.token.type" (~a token-type))
                                     attrs))))))
  resp)
