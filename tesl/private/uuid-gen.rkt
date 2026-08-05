#lang racket

;;; UUID byte-packing — the ONE implementation, shared by the capability-gated
;;; stdlib surface (`Tesl.UUID` / tesl/uuid.rkt) and by runtime internals that
;;; must mint ids WITHOUT a user capability (the queue's job ids).
;;;
;;; A leaf module on purpose: it requires only `racket/random`, so any runtime
;;; module can require it with no cycle risk, and there is exactly one place
;;; where the version/variant nibbles are set.
;;;
;;; This is NOT a stdlib surface module — it has no Tesl module name, no entry in
;;; Emit_racket.module_path_table, and no export row.  User code reaches v4/v7
;;; only through `Tesl.UUID`, which keeps the `uuid` capability check.

(require racket/random)

(provide uuid-v4-string
         uuid-v7-string)

;; Format a byte as a two-character lowercase hex string.
(define (byte->hex b)
  (let ([s (number->string b 16)])
    (if (= (string-length s) 1)
        (string-append "0" s)
        s)))

;; Format 16 bytes as a UUID string: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
(define (bytes->uuid-string bs)
  (define (hx i) (byte->hex (bytes-ref bs i)))
  (string-append
   (hx 0) (hx 1) (hx 2) (hx 3) "-"
   (hx 4) (hx 5) "-"
   (hx 6) (hx 7) "-"
   (hx 8) (hx 9) "-"
   (hx 10) (hx 11) (hx 12) (hx 13) (hx 14) (hx 15)))

;; Version 4 (random) UUID.
;; Version nibble: byte[6] high nibble = 0x4
;; Variant bits:   byte[8] = 0x80 | (low 6 bits of byte[8])
(define (uuid-v4-string)
  (define bs (bytes-copy (crypto-random-bytes 16)))
  (bytes-set! bs 6 (bitwise-ior #x40 (bitwise-and (bytes-ref bs 6) #x0f)))
  (bytes-set! bs 8 (bitwise-ior #x80 (bitwise-and (bytes-ref bs 8) #x3f)))
  (bytes->uuid-string bs))

;; Version 7 (time-ordered) UUID.
;; Bytes 0-5: 48-bit big-endian Unix timestamp in milliseconds.
;; Bytes 6-7: version nibble 0x7 in high nibble + 12 random bits.
;; Byte 8:    variant bits 0x80 | (6 random bits).
;; Bytes 9-15: 56 random bits.
(define (uuid-v7-string)
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
  (bytes-set! bs 6 (bitwise-ior #x70 (bitwise-and (bytes-ref bs 6) #x0f)))
  (bytes-set! bs 8 (bitwise-ior #x80 (bitwise-and (bytes-ref bs 8) #x3f)))
  (bytes->uuid-string bs))
