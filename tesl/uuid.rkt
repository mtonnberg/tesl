#lang racket

;;; Tesl.UUID — universally unique identifier generation and validation.
;;;
;;; The `uuid` capability gates all UUID generation (v4, v7).
;;; UUID.validate is a pure check function and requires no capability.
;;;
;;; Usage:
;;;   import Tesl.UUID exposing [uuid, UUID.v4, UUID.v7, UUID.validate, IsUuid]
;;;   fn makeId() -> String requires [uuid] = UUID.v4()

(require racket/string
         (only-in "private/uuid-gen.rkt" uuid-v4-string uuid-v7-string)
         "../dsl/check.rkt"
         "../dsl/types.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach)
         (only-in "../dsl/capability.rkt" define-capability require-capabilities!))

(provide
 uuid
 IsUuid
 UUID.v4
 UUID.v7
 UUID.validate
 uuidV4Codec
 uuidV7Codec)

;; ── Capability ───────────────────────────────────────────────────────────────

(define-capability uuid)

;; ── Proof predicate ──────────────────────────────────────────────────────────

(define IsUuid 'IsUuid)

;; ── Internal helpers ─────────────────────────────────────────────────────────

;; The byte packing (version/variant nibbles, 48-bit v7 timestamp) lives in
;; tesl/private/uuid-gen.rkt, which the queue's job-id minter shares: the
;; runtime must be able to mint an id WITHOUT the user-facing `uuid` capability,
;; and one copy of the nibble rules is the point.

;; UUID validity regexp: 8-4-4-4-12 lowercase or uppercase hex digits.
(define uuid-regexp
  #px"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

;; Helper: attach IsUuid proof to a value.
(define (attach-uuid-proof value)
  (define nv (ensure-named 'IsUuid value))
  (define subj (named-value-name nv))
  (attach nv (list (detached-proof `(IsUuid ,subj) (hash subj value)))))

;; ── UUID v4 (random) ─────────────────────────────────────────────────────────

;; Generate a version 4 (random) UUID.
;; Requires the `uuid` capability.
;;
;; Version nibble: byte[6] high nibble = 0x4
;; Variant bits:   byte[8] = 0x80 | (low 6 bits of byte[8])
(define (UUID.v4)
  (require-capabilities! (list uuid))
  (uuid-v4-string))

;; ── UUID v7 (time-ordered) ───────────────────────────────────────────────────

;; Generate a version 7 (time-ordered) UUID.
;; Bytes 0-5: 48-bit big-endian Unix timestamp in milliseconds.
;; Bytes 6-7: version nibble 0x7 in high nibble + 12 random bits.
;; Byte 8:    variant bits 0x80 | (6 random bits).
;; Bytes 9-15: 56 random bits.
;; Requires the `uuid` capability.
(define (UUID.v7)
  (require-capabilities! (list uuid))
  (uuid-v7-string))

;; ── UUID.validate ────────────────────────────────────────────────────────────

;; Validate a string as a well-formed UUID.
;; Pure — no capability required.
;; Returns check-ok with IsUuid proof on success, check-fail on invalid input.
(define (UUID.validate s)
  (define raw (raw-value s))
  (define str (if (string? raw) raw (format "~a" raw)))
  (if (regexp-match? uuid-regexp str)
      (let* ([nv    (attach-uuid-proof str)]
             [subj  (named-value-name nv)]
             [fact  `(IsUuid ,subj)])
        (check-ok nv (list fact) (hash subj str)))
      (check-fail "not a valid UUID" 400 #f)))

;; ── JSON codecs ──────────────────────────────────────────────────────────────

;; uuidV4Codec: (encoder . decoder) pair for UUID v4 strings.
;; Encoder: identity — a UUID is already a string in JSON.
;; Decoder: validates the input is a well-formed UUID string.
(define uuidV4Codec
  (cons
   ;; encoder: String -> jsexpr (a Racket string passes through)
   (lambda (v) (raw-value v))
   ;; decoder: jsexpr -> Result
   (lambda (v)
     (cond
       [(not (string? v))
        (check-fail "expected a string for UUID" 400 #f)]
       [(not (regexp-match? uuid-regexp v))
        (check-fail "not a valid UUID v4" 400 #f)]
       [else
        (check-ok v '() (hash))]))))

;; uuidV7Codec: same as uuidV4Codec — validates UUID format.
;; The distinction between v4 and v7 is in generation, not representation.
(define uuidV7Codec
  (cons
   (lambda (v) (raw-value v))
   (lambda (v)
     (cond
       [(not (string? v))
        (check-fail "expected a string for UUID" 400 #f)]
       [(not (regexp-match? uuid-regexp v))
        (check-fail "not a valid UUID v7" 400 #f)]
       [else
        (check-ok v '() (hash))]))))
