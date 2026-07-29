#lang racket/base

;;; ═══════════════════════════════════════════════════════════════════════════
;;;  tests/crypto-runtime-tests.rkt — Tesl.Crypto runtime conformance
;;; ═══════════════════════════════════════════════════════════════════════════
;;;
;;; The verification bar from roadmap/next/tesl_crypto.md, in executable form.
;;; Read the four headline ideas before changing anything here:
;;;
;;;  1. KNOWN-ANSWER, not round-trip.  A broken digest round-trips perfectly.
;;;     Every digest and MAC is checked against a published vector (NIST FIPS
;;;     180-4 for SHA-2, RFC 4231 for HMAC-SHA256), so an implementation that is
;;;     self-consistently wrong fails here.
;;;
;;;  2. THE COST-PARAMETER REGRESSION IS THE TEST MOST LIKELY TO MATTER.
;;;     Known-answer tests pass fine against a build whose Argon2id work factor
;;;     silently collapsed to nothing — and that is a total security failure that
;;;     looks like everything working.  So we assert wall-clock time AND the
;;;     memory limit the library reports.
;;;
;;;  3. TIMING EQUALISATION IS A SECURITY PROPERTY, so it is tested, not
;;;     asserted in a comment.  Verifying against `Nothing` (no user row) must
;;;     cost the same as verifying against a real hash, or the login endpoint
;;;     enumerates registered email addresses.
;;;
;;;  4. THE DOCUMENTED LIMITS ARE RATCHETS.  "Foreign bcrypt is not verifiable"
;;;     is a promise about behaviour; it gets a test so it cannot quietly become
;;;     untrue in either direction.
;;;
;;; Run: raco test tests/crypto-runtime-tests.rkt
;;; Env: TESL_LIBSODIUM (set by the nix dev shell and the installed wrappers)

(require rackunit
         racket/string
         racket/list
         ffi/unsafe
         ffi/unsafe/define
         net/base64
         (only-in file/sha1 bytes->hex-string)
         (only-in "../dsl/capability.rkt" current-capabilities)
         (only-in "../dsl/types.rkt"
                  secret-value? newtype-value? newtype-value-value
                  newtype-value-type-name
                  type-ref? type-ref-name
                  Something Nothing)
         (only-in "../dsl/private/evidence.rkt"
                  check-ok? check-fail? check-ok-value check-ok-facts
                  check-fail-message check-fail-status raw-value)
         (only-in "../dsl/private/check-runtime.rkt" current-evidence-env)
         (rename-in "../tesl/random.rkt" [random random-capability])
         "../tesl/crypto.rkt")

;; Every capability-gated call runs inside this.
(define-syntax-rule (with-random body ...)
  (parameterize ([current-capabilities (list random-capability)]) body ...))

(define (plain v)
  (let ([r (raw-value v)])
    (if (newtype-value? r) (newtype-value-value r) r)))

;; ═══════════════════════════════════════════════════════════════════════════
;;  1. Known-answer vectors — digests
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; NIST FIPS 180-4 / the SHA-2 example set.  These are the canonical published
;; values; do not "fix" a failure by editing them.

(test-case "SHA-256 known-answer vectors (NIST)"
  (check-equal? (Crypto.sha256 "abc")
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  (check-equal? (Crypto.sha256 "")
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  (check-equal? (Crypto.sha256 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"))

(test-case "SHA-512 known-answer vectors (NIST)"
  (check-equal?
   (Crypto.sha512 "abc")
   (string-append "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                  "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"))
  (check-equal?
   (Crypto.sha512 "")
   (string-append "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
                  "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")))

(test-case "Crypto.fingerprint IS SHA-256, and is stable"
  ;; fingerprint is the friendly name for the same primitive; if the two ever
  ;; disagree, one of them changed algorithm without the other.
  (check-equal? (Crypto.fingerprint "abc") (Crypto.sha256 "abc"))
  (check-equal? (Crypto.fingerprint "hello") (Crypto.fingerprint "hello"))
  (check-not-equal? (Crypto.fingerprint "hello") (Crypto.fingerprint "hellp"))
  ;; hex, lowercase, 64 chars
  (check-equal? (string-length (Crypto.fingerprint "x")) 64)
  (check-true (regexp-match? #rx"^[0-9a-f]+$" (Crypto.fingerprint "x"))))

;; ═══════════════════════════════════════════════════════════════════════════
;;  2. Known-answer + cross-implementation — HMAC-SHA256
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; We use libsodium's MULTI-PART HMAC API precisely so that RFC 2104 key handling
;; (a short key zero-padded to the block, a key longer than the block hashed
;; first) is done by the library rather than by us.  The key-length boundary is
;; therefore the thing worth testing hardest.
;;
;; Two layers, because the published vectors alone cannot reach far enough:
;;
;;   * RFC 4231 vectors, for the cases whose exact key bytes are expressible.
;;     `Crypto.signWith` takes a Tesl `String`, so the key crosses as UTF-8 — and
;;     cases 3-7 of RFC 4231 use 0xaa / 0xdd key bytes, which UTF-8 encodes as
;;     TWO bytes each.  Those vectors are simply unreachable through this API, so
;;     asserting them here would be asserting a different computation.
;;
;;   * an INDEPENDENT IMPLEMENTATION as an oracle: OpenSSL libcrypto, which is
;;     already a dependency (tesl/jwt.rkt reaches it for exactly this primitive).
;;     Comparing libsodium against libcrypto over keys that straddle the 64-byte
;;     block boundary covers the RFC's actual concern more thoroughly than its
;;     five reachable vectors do, and a bug would have to exist identically in
;;     both libraries to slip through.

(define (sig-of key data)
  (Crypto.signatureHex (Crypto.signWith (Secret key) data)))

(test-case "HMAC-SHA256 RFC 4231 case 1 — 20-byte key (published vector)"
  ;; key = 0x0b x 20.  U+000B is single-byte in UTF-8, so this vector IS reachable.
  (check-equal? (sig-of (make-string 20 #\u0B) "Hi There")
                "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"))

(test-case "HMAC-SHA256 RFC 4231 case 2 — short (4-byte) key (published vector)"
  (check-equal? (sig-of "Jefe" "what do ya want for nothing?")
                "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))

;; ── The independent oracle ──────────────────────────────────────────────────
(define-values (libcrypto-hmac libcrypto-available?)
  (with-handlers ([exn:fail? (lambda (_) (values #f #f))])
    (define lib (dynamic-require 'openssl/libcrypto 'libcrypto))
    (define EVP_sha256 (get-ffi-obj 'EVP_sha256 lib (_fun -> _pointer)))
    (define HMAC (get-ffi-obj 'HMAC lib
                              (_fun _pointer _bytes _int _bytes _int _bytes
                                    (_ptr o _uint) -> _pointer)))
    (values (lambda (key-bytes data-bytes)
              (define out (make-bytes 32))
              (HMAC (EVP_sha256) key-bytes (bytes-length key-bytes)
                    data-bytes (bytes-length data-bytes) out)
              (bytes->hex-string out))
            #t)))

(test-case "HMAC-SHA256 agrees with OpenSSL libcrypto across the block boundary"
  (if (not libcrypto-available?)
      ;; Not a silent pass: say so, so a CI run that lost libcrypto is visible.
      (printf "  NOTE: libcrypto unavailable — cross-implementation HMAC oracle skipped\n")
      (for* ([klen (in-list '(0 1 31 32 63 64 65 100 131 200))]
             [msg  (in-list (list "" "a" "Hi There"
                                  (make-string 1000 #\z)))])
        ;; ASCII keys, so the UTF-8 encoding is byte-for-byte what we intend.
        (define key (make-string klen #\k))
        (check-equal? (sig-of key msg)
                      (libcrypto-hmac (string->bytes/utf-8 key)
                                      (string->bytes/utf-8 msg))
                      (format "libsodium and libcrypto disagree at keylen=~a msglen=~a"
                              klen (string-length msg))))))

(test-case "HMAC-SHA256 agrees with OpenSSL libcrypto on random inputs"
  (when libcrypto-available?
    (for ([_ (in-range 50)])
      ;; ASCII-only so both sides see identical bytes.
      (define (rnd n)
        (list->string (for/list ([_ (in-range n)])
                        (integer->char (+ 32 (random 95))))))
      (define key (rnd (random 200)))
      (define msg (rnd (random 500)))
      (check-equal? (sig-of key msg)
                    (libcrypto-hmac (string->bytes/utf-8 key)
                                    (string->bytes/utf-8 msg))))))

;; ═══════════════════════════════════════════════════════════════════════════
;;  3. Password storage — Argon2id
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "hashPassword produces a PHC-formatted Argon2id string"
  (define h (with-random (Crypto.hashPassword "correct horse battery staple")))
  (define phc (plain h))
  (check-true (string-prefix? phc "$argon2id$v=19$")
              (format "expected an Argon2id PHC string, got: ~a" phc))
  ;; PHC shape: $id$version$params$salt$hash — 6 fields when split on $
  (check-equal? (length (string-split phc "$" #:trim? #f)) 6)
  ;; salt and hash segments are non-empty
  (define fields (string-split phc "$"))
  (check-true (> (string-length (list-ref fields 3)) 0))
  (check-true (> (string-length (list-ref fields 4)) 0)))

(test-case "every hash of the same password differs (a random salt is drawn)"
  (define a (plain (with-random (Crypto.hashPassword "same"))))
  (define b (plain (with-random (Crypto.hashPassword "same"))))
  (check-not-equal? a b "identical hashes mean the salt is not random"))

(test-case "checkPassword accepts the right password and rejects the wrong one"
  (define h (with-random (Crypto.hashPassword "s3cret!")))
  (define good (Crypto.checkPassword (Something h) "s3cret!"))
  (define bad  (Crypto.checkPassword (Something h) "s3cret"))
  (check-true (check-ok? good) "the correct password must verify")
  (check-true (check-fail? bad) "the wrong password must not verify")
  (check-equal? (check-fail-status bad) 401))

(test-case "checkPassword mints a PasswordVerified fact, and only on success"
  (define h (with-random (Crypto.hashPassword "pw")))
  (define ok (Crypto.checkPassword (Something h) "pw"))
  (check-true (check-ok? ok))
  (define facts (check-ok-facts ok))
  (check-equal? (length facts) 1)
  (check-equal? (car (car facts)) 'PasswordVerified
                (format "expected a PasswordVerified fact, got ~a" facts)))

(test-case "a missing user row (Nothing) fails, and never mints a fact"
  (define r (Crypto.checkPassword Nothing "anything"))
  (check-true (check-fail? r))
  (check-equal? (check-fail-status r) 401))

(test-case "the 401 message is IDENTICAL for a wrong password and a missing user"
  ;; The message is part of the user-enumeration surface: if it differs, an
  ;; attacker learns which addresses are registered without timing anything.
  (define h (with-random (Crypto.hashPassword "pw")))
  (define wrong   (Crypto.checkPassword (Something h) "nope"))
  (define missing (Crypto.checkPassword Nothing       "nope"))
  (check-equal? (check-fail-message wrong) (check-fail-message missing)))

;; ═══════════════════════════════════════════════════════════════════════════
;;  3b. Argument normalisation — a real bug this file caught
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; A Tesl stdlib function does NOT necessarily receive its argument as the value.
;; The GDP machinery may hand over the SUBJECT NAME — a bare symbol like
;; 'stored2859 — which `raw-value` resolves through `current-evidence-env`; the
;; argument may also arrive wrapped in a named-value or a check-ok.
;;
;; The first version of Crypto.checkPassword tested `Something?` on the
;; UNRESOLVED argument. Every direct call worked, every unit test passed, and the
;; failure appeared only from real emitted Tesl code — as a type-contract
;; violation deep inside the FFI marshalling, nowhere near the cause. That is the
;; worst possible failure signature for a security primitive, so it gets a test
;; at the exact shape rather than a comment.

(test-case "checkPassword resolves a GDP subject-name argument, not just a value"
  (define h (with-random (Crypto.hashPassword "pw")))
  (define subject 'stored-under-test)
  (parameterize ([current-evidence-env (hash subject (Something h))])
    (define ok (Crypto.checkPassword subject "pw"))
    (check-true (check-ok? ok)
                "a subject NAME must resolve to its value before Something? is tested")
    (check-true (check-fail? (Crypto.checkPassword subject "wrong")))))

(test-case "checkPassword resolves a Nothing handed over as a subject name"
  ;; The timing-equalisation path must survive the same indirection, or a missing
  ;; user row silently takes the fast branch again.
  (define subject 'missing-under-test)
  (parameterize ([current-evidence-env (hash subject Nothing)])
    (define r (Crypto.checkPassword subject "guess"))
    (check-true (check-fail? r))
    (check-equal? (check-fail-status r) 401)))

;; ═══════════════════════════════════════════════════════════════════════════
;;  4. THE COST-PARAMETER REGRESSION TEST
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; The test most likely to be skipped and most likely to matter.  A build whose
;; work factor collapsed passes every other test in this file.
;;
;; Two independent assertions, because either alone is defeatable:
;;   * WALL CLOCK — a real Argon2id at INTERACTIVE parameters cannot finish in
;;     single-digit milliseconds on any machine.  The floor is deliberately far
;;     below the ~80 ms observed on the dev box so a fast CI runner does not
;;     produce a flaky failure, while still being orders of magnitude above what
;;     a collapsed work factor would cost.
;;   * DECLARED MEMORY — we ask libsodium what it will use, and require it to be
;;     at least the OWASP Argon2id floor.  This catches a parameter regression
;;     that a fast machine could hide from the clock.

(define-values (sodium-memlimit sodium-opslimit)
  (let ()
    (define lib
      (or (let ([p (getenv "TESL_LIBSODIUM")])
            (and p (not (string=? p "")) (ffi-lib p #:fail (lambda () #f))))
          (ffi-lib "libsodium" '("26" "23" #f) #:fail (lambda () #f))))
    (if lib
        (values ((get-ffi-obj 'crypto_pwhash_memlimit_interactive lib (_fun -> _size)))
                ((get-ffi-obj 'crypto_pwhash_opslimit_interactive lib (_fun -> _size))))
        (values 0 0))))

(test-case "COST REGRESSION: the declared Argon2id memory limit meets the OWASP floor"
  ;; OWASP Password Storage Cheat Sheet: Argon2id m=19456 KiB (19 MiB), t=2, p=1.
  ;; libsodium's INTERACTIVE is m=65536 KiB (64 MiB), t=2 — comfortably above.
  (check-true (>= sodium-memlimit (* 19456 1024))
              (format "Argon2id memory limit collapsed to ~a bytes (OWASP floor is ~a)"
                      sodium-memlimit (* 19456 1024)))
  (check-true (>= sodium-opslimit 2)
              (format "Argon2id opslimit collapsed to ~a (floor is 2)" sodium-opslimit)))

(test-case "COST REGRESSION: hashPassword actually spends the time"
  ;; Take the best of three: we are guarding against a collapsed work factor,
  ;; not measuring performance, so the FASTEST run is the honest one to bound —
  ;; a scheduling hiccup can only make a run slower, never faster.
  (define times
    (for/list ([_ (in-range 3)])
      (define t0 (current-inexact-milliseconds))
      (with-random (Crypto.hashPassword "benchmark"))
      (- (current-inexact-milliseconds) t0)))
  (define fastest (apply min times))
  (check-true (>= fastest 15.0)
              (format (string-append
                       "hashPassword took only ~a ms — the Argon2id work factor has "
                       "collapsed. This is a total security failure that looks like "
                       "everything working. Times: ~a")
                      (real->decimal-string fastest 2) times)))

;; ═══════════════════════════════════════════════════════════════════════════
;;  5. THE TIMING-EQUALISATION TEST
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "verifying against Nothing costs the same as against a real hash"
  ;; Warm the lazily-built dummy hash first, so its one-off construction cost is
  ;; not what we measure.
  (void (Crypto.checkPassword Nothing "warmup"))
  (define h (with-random (Crypto.hashPassword "realpassword")))
  (define (time-of thunk)
    ;; median of 5, to damp scheduler noise without being fooled by one outlier
    (define ts (sort (for/list ([_ (in-range 5)])
                       (define t0 (current-inexact-milliseconds))
                       (thunk)
                       (- (current-inexact-milliseconds) t0))
                     <))
    (list-ref ts 2))
  (define t-missing (time-of (lambda () (Crypto.checkPassword Nothing "guess"))))
  (define t-present (time-of (lambda () (Crypto.checkPassword (Something h) "guess"))))
  ;; Both must be real work — a microsecond answer means one path skipped the
  ;; hash entirely, which is exactly the enumeration leak.
  (check-true (> t-missing 5.0)
              (format "the no-user path returned in ~a ms — it is not hashing"
                      (real->decimal-string t-missing 2)))
  (check-true (> t-present 5.0))
  ;; And they must be within a factor of 2 of each other.  A tight absolute
  ;; bound would be flaky on shared CI; a factor-of-2 bound still fails loudly if
  ;; one path stops hashing, which is the only regression that matters.
  (define ratio (/ (max t-missing t-present) (min t-missing t-present)))
  (check-true (< ratio 2.0)
              (format (string-append
                       "missing-user verification took ~a ms and existing-user ~a ms "
                       "(ratio ~a). A login endpoint with this difference enumerates "
                       "registered addresses.")
                      (real->decimal-string t-missing 2)
                      (real->decimal-string t-present 2)
                      (real->decimal-string ratio 2))))

;; ═══════════════════════════════════════════════════════════════════════════
;;  6. Cross-implementation verification, and the documented limits
;; ═══════════════════════════════════════════════════════════════════════════

;; PHC base64: standard alphabet, NO padding.
(define (phc-b64 bs)
  (regexp-replace* #rx"=+$" (bytes->string/utf-8 (base64-encode bs #"")) ""))

;; Build an Argon2id PHC string libsodium did NOT emit: parameters it would never
;; choose (m=19456, the argon2-cffi/OWASP default rather than libsodium's 65536),
;; a salt of our choosing, and a hand-assembled envelope.  If this verifies, a
;; migration from a foreign Argon2id store works.
(define foreign-argon2id
  (let ()
    (define lib
      (or (let ([p (getenv "TESL_LIBSODIUM")])
            (and p (not (string=? p "")) (ffi-lib p #:fail (lambda () #f))))
          (ffi-lib "libsodium" '("26" "23" #f) #:fail (lambda () #f))))
    (and lib
         (let* ([pwhash (get-ffi-obj 'crypto_pwhash lib
                                     (_fun _bytes _ullong _bytes _ullong
                                           _bytes _ullong _size _int -> _int))]
                [alg    ((get-ffi-obj 'crypto_pwhash_alg_argon2id13 lib (_fun -> _int)))]
                [salt   (make-bytes 16 65)]     ; "AAAA…" — deliberately not random
                [out    (make-bytes 32)]
                [m-kib  19456])
           (pwhash out 32 #"foreign password" 16 salt 2 (* m-kib 1024) alg)
           (format "$argon2id$v=19$m=~a,t=2,p=1$~a$~a"
                   m-kib (phc-b64 salt) (phc-b64 out))))))

(test-case "a FOREIGN Argon2id hash (non-libsodium parameters) verifies"
  (when foreign-argon2id
    (define ok (Crypto.checkPassword (Something (PasswordHash foreign-argon2id))
                                     "foreign password"))
    (check-true (check-ok? ok)
                (format "failed to verify a foreign Argon2id PHC string: ~a"
                        foreign-argon2id))
    (define bad (Crypto.checkPassword (Something (PasswordHash foreign-argon2id))
                                      "wrong password"))
    (check-true (check-fail? bad))))

(test-case "a foreign hash with WEAKER parameters is flagged by needsRehash"
  ;; This is the rolling-upgrade guarantee: old hashes keep verifying AND are
  ;; identified as needing a re-mint on next login.  Untested, it is an
  ;; intention rather than a property.
  (when foreign-argon2id
    (check-true (Crypto.needsRehash (PasswordHash foreign-argon2id))
                "an m=19456 hash must need rehashing against m=65536")))

(test-case "a hash minted with the CURRENT parameters does not need rehashing"
  (define h (with-random (Crypto.hashPassword "current")))
  (check-false (Crypto.needsRehash h)))

(test-case "DOCUMENTED LIMIT: foreign bcrypt is NOT verifiable"
  ;; libsodium's crypto_pwhash_str_verify parses $argon2i$ and $argon2id$ and
  ;; nothing else.  This is a real migration constraint, so it is a ratchet:
  ;; if a future libsodium or a Tesl change makes bcrypt verifiable, this test
  ;; fails and the DOCS get updated deliberately rather than by accident.
  (define r (Crypto.checkPassword
             (Something (PasswordHash
                         "$2b$12$K2CtDP7zSGOKgLLZxrhMEeIOFPTNXbLcrJZG.LnaCqAJoJ8LzXBrK"))
             "password"))
  (check-true (check-fail? r) "bcrypt is documented as NOT verifiable"))

(test-case "DOCUMENTED LIMIT: foreign scrypt ($7$) is NOT verifiable either"
  ;; The roadmap claimed scrypt and PBKDF2 would verify.  They do not:
  ;; libsodium keeps scrypt behind a SEPARATE
  ;; crypto_pwhash_scryptsalsa208sha256_str_verify with its own $7$ format, and
  ;; has no PBKDF2 at all.  Recorded as a test so the doc and the behaviour
  ;; cannot drift apart again.
  (define r (Crypto.checkPassword
             (Something (PasswordHash
                         "$7$C6..../....SodiumChloride$kBGj9fHznVYFQMEn/qDCfrDevf9YDtcDdKvEqHJLV8D"))
             "pleaseletmein"))
  (check-true (check-fail? r)))

(test-case "an unparseable stored hash needs rehashing rather than crashing"
  (check-true (Crypto.needsRehash (PasswordHash "not a hash at all")))
  (check-true (check-fail? (Crypto.checkPassword
                            (Something (PasswordHash "not a hash at all")) "x"))))

;; ═══════════════════════════════════════════════════════════════════════════
;;  7. The input-length bound
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "an over-long password is REJECTED, not truncated"
  ;; libsodium imposes no bound (crypto_pwhash_passwd_max is 2^32-1), so an
  ;; unbounded memory-hard hash on an unauthenticated endpoint is a free
  ;; amplifier.  Rejection, never truncation: silent truncation is the bcrypt
  ;; 72-byte bug.
  (define over (make-string (add1 crypto-max-password-bytes) #\a))
  (define r (with-random (Crypto.hashPassword over)))
  (check-true (check-fail? r))
  (check-equal? (check-fail-status r) 400)
  (check-true (regexp-match? #rx"too long" (check-fail-message r))))

(test-case "a password exactly AT the bound is accepted"
  (define at (make-string crypto-max-password-bytes #\a))
  (define h (with-random (Crypto.hashPassword at)))
  (check-false (check-fail? h))
  (check-true (check-ok? (Crypto.checkPassword (Something h) at))))

(test-case "the bound is on BYTES, not characters (multi-byte input)"
  ;; A CJK character costs 3 bytes in UTF-8; the bound must count bytes, because
  ;; bytes are what the hash consumes.
  (define s (make-string 400 #\u4E2D))   ; 400 chars = 1200 bytes > 1024
  (define r (with-random (Crypto.hashPassword s)))
  (check-true (check-fail? r) "1200 bytes of UTF-8 must exceed a 1024-BYTE bound"))

(test-case "the over-long check also guards checkPassword, not just hashPassword"
  ;; The DoS vector is a long CANDIDATE against a short stored hash — an attacker
  ;; controls the candidate, never the stored value.
  (define h (with-random (Crypto.hashPassword "short")))
  (define r (Crypto.checkPassword (Something h)
                                  (make-string (* 4 crypto-max-password-bytes) #\a)))
  (check-true (check-fail? r))
  (check-equal? (check-fail-status r) 400))

;; ═══════════════════════════════════════════════════════════════════════════
;;  8. Signatures
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "a signature round-trips through hex and verifies"
  (define k (Secret "shared-webhook-secret"))
  (define payload "{\"id\":\"evt_1\",\"amount\":4200}")
  (define sig (Crypto.signWith k payload))
  (define ok (Crypto.checkSignature k sig payload))
  (check-true (check-ok? ok))
  ;; the inbound path: hex out of a header, back into a Signature
  (define reparsed (Crypto.signatureFromHex (Crypto.signatureHex sig)))
  (check-true (check-ok? (Crypto.checkSignature k reparsed payload))))

(test-case "checkSignature mints an Authentic fact naming the payload"
  (define k (Secret "k"))
  (define ok (Crypto.checkSignature k (Crypto.signWith k "p") "p"))
  (check-true (check-ok? ok))
  (check-equal? (car (car (check-ok-facts ok))) 'Authentic))

(test-case "a tampered payload does not verify"
  (define k (Secret "k"))
  (define sig (Crypto.signWith k "amount=100"))
  (check-true (check-fail? (Crypto.checkSignature k sig "amount=999"))))

(test-case "the wrong key does not verify"
  (define sig (Crypto.signWith (Secret "right") "payload"))
  (check-true (check-fail? (Crypto.checkSignature (Secret "wrong") sig "payload"))))

(test-case "a malformed inbound signature fails closed, it does not raise"
  ;; A webhook sender can put anything in that header.  Every one of these must
  ;; be a 401, never a 500 and never an exception escaping the handler.
  (define k (Secret "k"))
  (for ([junk (in-list '("" "zz" "not-hex" "deadbeef" "0" "ffff"))])
    (define r (Crypto.checkSignature k (Crypto.signatureFromHex junk) "payload"))
    (check-true (check-fail? r) (format "expected a clean failure for ~s" junk))
    (check-equal? (check-fail-status r) 401)))

(test-case "a signature of the correct LENGTH but wrong content fails"
  ;; Guards against a length-only comparison.
  (define k (Secret "k"))
  (define real (Crypto.signatureHex (Crypto.signWith k "payload")))
  (define flipped
    (string-append (if (char=? (string-ref real 0) #\0) "1" "0")
                   (substring real 1)))
  (check-equal? (string-length flipped) (string-length real))
  (check-true (check-fail? (Crypto.checkSignature
                            k (Crypto.signatureFromHex flipped) "payload"))))

(test-case "hmacSha256 is the same function as signWith (expert alias)"
  (define k (Secret "k"))
  (check-equal? (Crypto.signatureHex (Crypto.hmacSha256 k "m"))
                (Crypto.signatureHex (Crypto.signWith k "m"))))

;; ═══════════════════════════════════════════════════════════════════════════
;;  9. Tokens
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "randomToken is 256 bits, base64url, and unique"
  (define ts (with-random (for/list ([_ (in-range 200)]) (Crypto.randomToken))))
  ;; 32 bytes base64url without padding = 43 characters
  (for ([t (in-list ts)])
    (check-equal? (string-length t) 43 (format "unexpected token length: ~s" t))
    (check-true (regexp-match? #rx"^[A-Za-z0-9_-]+$" t)
                (format "token is not URL-safe: ~s" t)))
  ;; 200 draws from a 256-bit space must all differ
  (check-equal? (length (remove-duplicates ts)) 200
                "randomToken produced a duplicate — the CSPRNG is broken"))

(test-case "randomToken requires the random capability"
  (check-exn exn:fail?
             (lambda () (parameterize ([current-capabilities '()])
                          (Crypto.randomToken)))))

(test-case "hashPassword requires the random capability (it draws a salt)"
  (check-exn exn:fail?
             (lambda () (parameterize ([current-capabilities '()])
                          (Crypto.hashPassword "pw")))))

(test-case "checkPassword requires NO capability (it is pure)"
  (define h (with-random (Crypto.hashPassword "pw")))
  (parameterize ([current-capabilities '()])
    (check-true (check-ok? (Crypto.checkPassword (Something h) "pw")))))

;; ═══════════════════════════════════════════════════════════════════════════
;;  10. Key fingerprints
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "keyFingerprint is short, stable, and distinguishes keys"
  (check-equal? (Crypto.keyFingerprint (Secret "k1"))
                (Crypto.keyFingerprint (Secret "k1")))
  (check-not-equal? (Crypto.keyFingerprint (Secret "k1"))
                    (Crypto.keyFingerprint (Secret "k2")))
  (check-equal? (string-length (Crypto.keyFingerprint (Secret "k1"))) 16))

(test-case "keyFingerprint is domain-separated from fingerprint"
  ;; Without domain separation, logging a key's fingerprint would publish
  ;; SHA-256(key) — a value an attacker can compare against a rainbow table of
  ;; candidate keys.  The label makes the two namespaces disjoint.
  (check-not-equal? (Crypto.keyFingerprint (Secret "secretvalue"))
                    (substring (Crypto.fingerprint "secretvalue") 0 16)))

;; ═══════════════════════════════════════════════════════════════════════════
;;  11. Constant-time comparison
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "the constant-time compare agrees with equality"
  (check-true  (crypto-constant-time-equal? (Secret "abc") (Secret "abc")))
  (check-false (crypto-constant-time-equal? (Secret "abc") (Secret "abd")))
  (check-false (crypto-constant-time-equal? (Secret "abc") (Secret "abcd")))
  (check-false (crypto-constant-time-equal? (Secret "") (Secret "x")))
  (check-true  (crypto-constant-time-equal? (Secret "") (Secret ""))))

;; ═══════════════════════════════════════════════════════════════════════════
;;  12. Secrecy of the types
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "PasswordHash and Secret are registered SECRET; Signature is not"
  (define h (with-random (Crypto.hashPassword "pw")))
  (check-true (secret-value? h)          "PasswordHash must be secret")
  (check-true (secret-value? (Secret "k")) "Secret must be secret")
  ;; A MAC tag is public data — publishing it is the entire point, and redacting
  ;; it would make webhook debugging impossible.
  (check-false (secret-value? (Crypto.signWith (Secret "k") "m"))
               "Signature must NOT be secret"))

(test-case "the secret marker is per-type, not per-value"
  ;; A plain String, an Int, a list: none of these are secret just because a
  ;; secret exists somewhere in the program.
  (check-false (secret-value? "a plain string"))
  (check-false (secret-value? 42))
  (check-false (secret-value? (list 1 2 3))))

(test-case "a secret's type name survives for the debugger's type column"
  ;; The VALUE is redacted; the TYPE is not. Showing `Secret` as the type of a
  ;; redacted node is what makes the redaction legible rather than confusing.
  (define s (Secret "k"))
  (check-true (newtype-value? s))
  ;; The token is a `type-ref` prefab (owner + name) for a module-owned type, so
  ;; read the name the way the debugger's renderer does.
  (define tn (newtype-value-type-name s))
  (check-equal? (if (type-ref? tn) (type-ref-name tn) tn) 'Secret))
