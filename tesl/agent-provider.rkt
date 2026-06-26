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
         (only-in "../dsl/private/evidence.rkt" raw-value))

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
         call-provider)

;;; A single tool invocation requested by the model.
;;;   id   : String  — provider-assigned call id (echoed back in tool_result)
;;;   name : String  — the tool name the model wants to call
;;;   args : jsexpr  — the parsed JSON arguments object
(struct tool-call (id name args) #:transparent)

;;; The normalized response shape produced by every provider.
(struct llm-response (text usage tool-calls stop-reason) #:transparent)

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
  (lambda (_request)
    (when (>= calls total)
      (raise-user-error
       'mockProvider
       "mock provider exhausted: ~a call(s) made but only ~a scripted response(s)"
       (add1 calls) total))
    (define resp (list-ref script calls))
    (set! calls (add1 calls))
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
  (lambda (request)
    (define body
      (hash 'model model
            'max_tokens (hash-ref request 'max-tokens 1024)
            'system (hash-ref request 'system "")
            'messages (anthropic-messages (hash-ref request 'messages '()))
            'tools (anthropic-tools (hash-ref request 'tools '()))))
    (define-values (status raw)
      (http-post-json endpoint
                      (list (cons "x-api-key" api-key)
                            (cons "anthropic-version" anthropic-version)
                            (cons "content-type" "application/json"))
                      body))
    (define j (parse-json-body 'anthropic raw))
    (when (>= status 400)
      (raise-user-error 'anthropic "API error (HTTP ~a): ~a" status raw))
    (anthropic-normalize j)))

(define (anthropic-tools tools)
  (for/list ([t (in-list tools)])
    (hash 'name (hash-ref t 'name)
          'description (hash-ref t 'description "")
          'input_schema (hash-ref t 'schema (hash 'type "object")))))

;; Normalized messages -> Anthropic content blocks.  A normalized message whose
;; content is a list already carries provider-agnostic block hashes (kind tagged).
(define (anthropic-messages messages)
  (for/list ([m (in-list messages)])
    (define role (hash-ref m 'role))
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
  (lambda (request)
    (define body
      (hash 'model model
            'max_tokens (hash-ref request 'max-tokens 1024)
            'messages (openai-messages (hash-ref request 'system "")
                                       (hash-ref request 'messages '()))
            'tools (openai-tools (hash-ref request 'tools '()))))
    (define-values (status raw)
      (http-post-json endpoint
                      (list (cons "authorization" (string-append "Bearer " api-key))
                            (cons "content-type" "application/json"))
                      body))
    (define j (parse-json-body 'openai raw))
    (when (>= status 400)
      (raise-user-error 'openai "API error (HTTP ~a): ~a" status raw))
    (openai-normalize j)))

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
  (make-openai-provider api-key model endpoint))

;;; ── The single choke point ─────────────────────────────────────────────────
;;; call-provider : provider request -> llm-response
;;; The agent core never invokes a provider procedure directly; everything goes
;;; through here, giving later waves one place for retries / telemetry / cost.
(define (call-provider provider request)
  (define resp (provider request))
  (unless (llm-response? resp)
    (raise-user-error 'agent
                      "provider returned ~e, expected an llm-response" resp))
  resp)
