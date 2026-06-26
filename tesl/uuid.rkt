#lang racket

;;; Tesl.UUID — universally unique identifier generation and validation.
;;;
;;; The `uuid` capability gates all UUID generation (v4, v7).
;;; UUID.validate is a pure check function and requires no capability.
;;;
;;; Usage:
;;;   import Tesl.UUID exposing [uuid, UUID.v4, UUID.v7, UUID.validate, IsUuid]
;;;   fn makeId() -> String requires [uuid] = UUID.v4()

(require racket/random
         racket/string
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

;; Format a byte as a two-character lowercase hex string.
(define (byte->hex b)
  (let ([s (number->string b 16)])
    (if (= (string-length s) 1)
        (string-append "0" s)
        s)))

;; Format 16 bytes as a UUID string: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
(define (bytes->uuid-string bs)
  (string-append
   (byte->hex (bytes-ref bs 0))
   (byte->hex (bytes-ref bs 1))
   (byte->hex (bytes-ref bs 2))
   (byte->hex (bytes-ref bs 3))
   "-"
   (byte->hex (bytes-ref bs 4))
   (byte->hex (bytes-ref bs 5))
   "-"
   (byte->hex (bytes-ref bs 6))
   (byte->hex (bytes-ref bs 7))
   "-"
   (byte->hex (bytes-ref bs 8))
   (byte->hex (bytes-ref bs 9))
   "-"
   (byte->hex (bytes-ref bs 10))
   (byte->hex (bytes-ref bs 11))
   (byte->hex (bytes-ref bs 12))
   (byte->hex (bytes-ref bs 13))
   (byte->hex (bytes-ref bs 14))
   (byte->hex (bytes-ref bs 15))))

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
  (define bs (bytes-copy (crypto-random-bytes 16)))
  ;; Set version 4: byte[6] = 0x40 | (byte[6] & 0x0F)
  (bytes-set! bs 6 (bitwise-ior #x40 (bitwise-and (bytes-ref bs 6) #x0f)))
  ;; Set variant bits: byte[8] = 0x80 | (byte[8] & 0x3F)
  (bytes-set! bs 8 (bitwise-ior #x80 (bitwise-and (bytes-ref bs 8) #x3f)))
  (bytes->uuid-string bs))

;; ── UUID v7 (time-ordered) ───────────────────────────────────────────────────

;; Generate a version 7 (time-ordered) UUID.
;; Bytes 0-5: 48-bit big-endian Unix timestamp in milliseconds.
;; Bytes 6-7: version nibble 0x7 in high nibble + 12 random bits.
;; Byte 8:    variant bits 0x80 | (6 random bits).
;; Bytes 9-15: 56 random bits.
;; Requires the `uuid` capability.
(define (UUID.v7)
  (require-capabilities! (list uuid))
  (define ts (inexact->exact (floor (current-inexact-milliseconds))))
  (define rand-bs (bytes-copy (crypto-random-bytes 10)))
  (define bs (make-bytes 16 0))
  ;; Pack 48-bit timestamp big-endian into bytes 0-5.
  (bytes-set! bs 0 (bitwise-and (arithmetic-shift ts -40) #xff))
  (bytes-set! bs 1 (bitwise-and (arithmetic-shift ts -32) #xff))
  (bytes-set! bs 2 (bitwise-and (arithmetic-shift ts -24) #xff))
  (bytes-set! bs 3 (bitwise-and (arithmetic-shift ts -16) #xff))
  (bytes-set! bs 4 (bitwise-and (arithmetic-shift ts -8)  #xff))
  (bytes-set! bs 5 (bitwise-and ts                        #xff))
  ;; Bytes 6-15: random data from rand-bs
  (bytes-copy! bs 6 rand-bs 0 10)
  ;; Set version 7: byte[6] = 0x70 | (byte[6] & 0x0F)
  (bytes-set! bs 6 (bitwise-ior #x70 (bitwise-and (bytes-ref bs 6) #x0f)))
  ;; Set variant bits: byte[8] = 0x80 | (byte[8] & 0x3F)
  (bytes-set! bs 8 (bitwise-ior #x80 (bitwise-and (bytes-ref bs 8) #x3f)))
  (bytes->uuid-string bs))

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
