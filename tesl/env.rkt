#lang racket

(require "private/runtime.rkt"
         (only-in "../dsl/capability.rkt"
                  define-capability require-capabilities! current-capabilities))

;; Reading the environment is an effect; a function that calls env/envInt/
;; envString/requireEnv in its body must declare `requires [envRead]` (enforced by
;; validation_capabilities). Named envRead, not env, to avoid clashing with the
;; `env` function below.
(define-capability envRead)

(provide env envInt envString requireEnv envRead
         current-env-bootstrap? with-env-bootstrap)

;; CAP-2: a user-level env read must enforce its own capability at runtime, like
;; time.rkt / random.rkt / dsl/sql.rkt already do.  Previously env reads had ZERO
;; runtime guard, so the static envRead check (validation_capabilities) was the
;; SOLE enforcer — any static hole (e.g. an effect laundered through a built-in
;; constructor before CAP-1 was closed) became a fully silent env-secret read.
;;
;; A3: env reads assert envRead UNCONDITIONALLY — exactly like time/random —
;; EXCEPT inside an explicit bootstrap-trust marker.  The previous guard excused
;; the read whenever `current-capabilities` was empty ('()), using ambient
;; emptiness as a syntactic PROXY for "module-load bootstrap".  That proxy was a
;; fail-open: any genuine execution context that happened to run under an empty
;; ambient (e.g. an auth/check body under a server that granted no capabilities)
;; read env secrets with NO envRead grant.  Trust must be POSITIVE, not the
;; absence of a grant.
;;
;; The ONLY trusted env-read context is module-load bootstrap of top-level
;; declarative config/agent blocks, marked explicitly by the emitter (never by
;; ambient emptiness).  `current-env-bootstrap?` is #f by default and cannot be
;; set from Tesl source — only emit_racket's emit_agent wraps a top-level agent
;; config expression with `with-env-bootstrap`, so the one-time module-load
;; provider read (e.g. `requireEnv "…"` in an agent block) still loads while
;; every runtime env read stays guarded.
;;
;; DDatabase/DEmail config env reads are UNAFFECTED: they lower through
;; emit_postgres_value to the raw `tesl-env-*` helpers (tesl-env-raw /
;; tesl-env-int-raw / tesl-env-string-raw), which never call
;; ensure-env-capability!.  Handler / worker / main bodies run under the
;; serve/main grant (a non-empty ambient that includes envRead), so their reads
;; pass the unconditional assert.
(define current-env-bootstrap? (make-parameter #f))
(define-syntax-rule (with-env-bootstrap body ...)
  (parameterize ([current-env-bootstrap? #t]) body ...))

(define (ensure-env-capability!)
  (unless (current-env-bootstrap?)
    (require-capabilities! (list envRead))))

(define (env name)
  (ensure-env-capability!)
  (tesl-env name))

(define (envInt name default)
  (ensure-env-capability!)
  (tesl-env-int-raw name default))

(define (envString name default)
  (ensure-env-capability!)
  (tesl-env-string-raw name default))

;; requireEnv : String -> String — read an env var as a raw String, failing if it
;; is unset (the String-returning counterpart to `env`, which returns Maybe).
(define (requireEnv name)
  (ensure-env-capability!)
  (tesl-env-raw name))
