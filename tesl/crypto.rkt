#lang racket

;;; Tesl.Crypto — password storage, message authentication, digests, secrets.
;;;
;;; ┌───────────────────────────────────────────────────────────────────────┐
;;; │  EVERY PRIMITIVE HERE IS libsodium, UNMODIFIED.                       │
;;; │  Tesl's contribution is the type system around the primitives, never  │
;;; │  the primitives.  Nothing in this file implements cryptography; it     │
;;; │  marshals values across the FFI and chooses libsodium's own           │
;;; │  recommended parameters.                                              │
;;; └───────────────────────────────────────────────────────────────────────┘
;;;
;;; Concretely:
;;;   * password hashing  = `crypto_pwhash_str` / `_str_verify` / `_str_needs_rehash`
;;;                         (Argon2id, PHC string format, INTERACTIVE parameters
;;;                         read from the library at runtime — see "Upgrades")
;;;   * authentication    = `crypto_auth_hmacsha256_{init,update,final}`
;;;                         (the multi-part API, so a key of ANY length is
;;;                          handled per RFC 2104 rather than by us)
;;;   * digests           = `crypto_hash_sha256` / `crypto_hash_sha512`
;;;   * constant-time cmp = `sodium_memcmp`
;;;   * CSPRNG            = Racket's own `crypto-random-bytes` (racket/random),
;;;                         which is the OS CSPRNG — no FFI needed
;;;
;;; ── No knobs, deliberately ───────────────────────────────────────────────
;;; No algorithm choice, no work factor, no nonce, no salt, no encoding, no
;;; length reaches the caller.  Every knob is a place where a non-expert makes a
;;; wrong call and gets a plausible-looking result.  Experts get transparency
;;; through `tesl doc` and through the algorithm tag inside every stored
;;; artifact — not through parameters.
;;;
;;; ── Upgrades, and why they are free ──────────────────────────────────────
;;; The cost parameters are read from libsodium at call time
;;; (`crypto_pwhash_opslimit_interactive` / `_memlimit_interactive`), never
;;; hardcoded.  So upgrading libsodium silently strengthens every NEW hash,
;;; `Crypto.needsRehash` starts answering #t for old ones, and application code
;;; that was correct stays correct unmodified.  Stored data is never touched:
;;; a hash is one-way, so upgrade-on-login is not the weaker option, it is the
;;; only mechanism.  Verification accepts every scheme ever shipped because the
;;; algorithm and its parameters live inside each stored PHC string — which is
;;; also what makes a rolling deploy safe with no flag day.
;;;
;;; ── What this module does NOT do ─────────────────────────────────────────
;;; No general encrypt/decrypt, no raw AES/ChaCha, no cipher modes, no key
;;; custody.  See roadmap/next/tesl_crypto.md § "What we will not build".

(require ffi/unsafe
         ffi/unsafe/define
         racket/random                       ; crypto-random-bytes (OS CSPRNG)
         (only-in file/sha1 bytes->hex-string hex-string->bytes)
         net/base64
         "private/runtime.rkt"               ; Something / Nothing
         "../dsl/types.rkt"
         "../dsl/check.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach)
         (only-in "../dsl/capability.rkt" require-capabilities!)
         (only-in "random.rkt" random))      ; the SAME capability object

(provide ;; types
         PasswordHash Signature Secret
         ;; proof predicate names (plain symbols, usable in Tesl annotations)
         HashFor PasswordVerified Authentic
         ;; password storage
         Crypto.hashPassword Crypto.checkPassword Crypto.needsRehash
         ;; message authentication
         Crypto.signWith Crypto.checkSignature
         Crypto.signatureHex Crypto.signatureFromHex
         Crypto.signatureBase64 Crypto.signatureFromBase64
         ;; digests
         Crypto.fingerprint Crypto.keyFingerprint
         ;; tokens
         Crypto.randomToken
         ;; expert aliases
         Crypto.hmacSha256 Crypto.sha256 Crypto.sha512
         ;; internal, for the seam tests and the constant-time == lowering
         crypto-constant-time-equal? crypto-max-password-bytes
         ;; internal, for tesl/proxy.rkt: generic proof-attach + constant-time
         ;; byte compare (Item A ProxyBound minting reuses the exact machinery).
         attach-proof-to constant-time-bytes=?
         ;; internal, for dsl/sso.rkt (Stage 2): raw digest/MAC/base64url helpers
         ;; used to build PKCE S256 challenges and the domain-separated
         ;; __Host-oauth cookie MAC.  NOT Tesl-surface names.
         sha256-bytes hmac-sha256-bytes base64url-encode
         ;; internal, for the SSO server clause's __Host-oauth MAC key: a Secret's
         ;; raw UTF-8 bytes.  NOT a Tesl-surface name.
         secret->bytes)

;; ════════════════════════════════════════════════════════════════════════════
;;  Lazy libsodium resolution
;; ════════════════════════════════════════════════════════════════════════════
;;
;; This MUST stay lazy.  `compiler/test/test_stdlib_runtime_binding.ml` walks
;; every stdlib .rkt with `dynamic-require <module> (void)` to enumerate its real
;; provides; a top-level `ffi-lib` that failed would abort that dump and fail the
;; seam test for EVERY module, not just this one.  `tesl/jwt.rkt` gets this wrong
;; (it requires `openssl/libcrypto`, which resolves at module instantiation);
;; we do not copy that.
;;
;; Resolution order:
;;   1. $TESL_LIBSODIUM — an absolute path baked in by the Nix wrappers and the
;;      dev shell (flake.nix `libsodiumPath`).  A `nix profile install` user has
;;      no libsodium on any ambient search path, and on macOS DYLD_LIBRARY_PATH
;;      is unreliable, so the absolute path is the only portable answer there.
;;   2. a plain `ffi-lib "libsodium"` lookup, for non-Nix installs — the Docker
;;      images (which apt-install libsodium-dev) and distro packages.  The
;;      version list covers Debian's libsodium23 and libsodium26 sonames plus the
;;      unversioned symlink.

(define install-hint
  (string-append
   "libsodium is required by Tesl.Crypto and could not be loaded.\n"
   "  • Nix:            it is declared in flake.nix; enter the dev shell, or\n"
   "                    reinstall the toolchain so $TESL_LIBSODIUM is set.\n"
   "  • Debian/Ubuntu:  apt-get install libsodium-dev\n"
   "  • Alpine:         apk add libsodium\n"
   "  • macOS/Homebrew: brew install libsodium\n"
   "  • or set TESL_LIBSODIUM to the absolute path of the shared library."))

(define sodium-lib
  (delay
    (define from-env
      (let ([p (getenv "TESL_LIBSODIUM")])
        (and p (not (string=? p "")) (ffi-lib p #:fail (lambda () #f)))))
    (define lib
      (or from-env
          (ffi-lib "libsodium" '("26" "23" #f) #:fail (lambda () #f))
          (raise-user-error 'Tesl.Crypto "~a" install-hint)))
    ;; sodium_init must be called once before any other function, and is
    ;; idempotent: 0 = initialised now, 1 = already initialised, -1 = failed.
    (define init (get-ffi-obj 'sodium_init lib (_fun -> _int)))
    (when (negative? (init))
      (raise-user-error 'Tesl.Crypto "sodium_init() failed; libsodium is unusable"))
    lib))

;; Bind one libsodium symbol as a memoised thunk, so nothing touches the library
;; until the first actual call.  (`define-ffi-definer` would resolve eagerly.)
(define-syntax-rule (define-sodium id type)
  (define id
    (let ([cached #f])
      (lambda args
        (unless cached
          (set! cached (get-ffi-obj 'id (force sodium-lib) type)))
        (apply cached args)))))

;; ── Password hashing (Argon2id, PHC string format) ──────────────────────────
(define-sodium crypto_pwhash_strbytes              (_fun -> _size))
(define-sodium crypto_pwhash_opslimit_interactive  (_fun -> _size))
(define-sodium crypto_pwhash_memlimit_interactive  (_fun -> _size))
(define-sodium crypto_pwhash_str
  (_fun _bytes    ; char out[crypto_pwhash_STRBYTES]
        _bytes    ; const char * const passwd
        _ullong   ; unsigned long long passwdlen
        _ullong   ; unsigned long long opslimit
        _size     ; size_t memlimit
        -> _int))
(define-sodium crypto_pwhash_str_verify
  (_fun _bytes _bytes _ullong -> _int))   ; NUL-terminated str, passwd, passwdlen
(define-sodium crypto_pwhash_str_needs_rehash
  (_fun _bytes _ullong _size -> _int))    ; NUL-terminated str, opslimit, memlimit

;; ── HMAC-SHA256, multi-part API ─────────────────────────────────────────────
;; The one-shot `crypto_auth_hmacsha256` demands a key of EXACTLY 32 bytes and
;; would push RFC 2104's key padding/hashing onto us.  The multi-part API's
;; `_init` takes a keylen and does it correctly for any length, so we use that.
;; Verified against RFC 4231 test cases 1, 2, 3 and 6 (the >block-size key).
(define-sodium crypto_auth_hmacsha256_statebytes (_fun -> _size))
(define-sodium crypto_auth_hmacsha256_init   (_fun _bytes _bytes _size -> _int))
(define-sodium crypto_auth_hmacsha256_update (_fun _bytes _bytes _ullong -> _int))
(define-sodium crypto_auth_hmacsha256_final  (_fun _bytes _bytes -> _int))

;; ── Digests ─────────────────────────────────────────────────────────────────
(define-sodium crypto_hash_sha256 (_fun _bytes _bytes _ullong -> _int))
(define-sodium crypto_hash_sha512 (_fun _bytes _bytes _ullong -> _int))

;; ── Constant-time comparison ────────────────────────────────────────────────
(define-sodium sodium_memcmp (_fun _bytes _bytes _size -> _int))

;; ════════════════════════════════════════════════════════════════════════════
;;  Types
;; ════════════════════════════════════════════════════════════════════════════
;;
;; PasswordHash — the stored PHC string.  SECRET: a stolen hash is offline
;;   attackable, so it must not appear in a log, a trace, a debugger or a
;;   response.  Opaque: no caller-callable constructor (there is deliberately no
;;   `"PasswordHash", mono (t_fun [t_string] …)` row in stdlib_env, so
;;   `PasswordHash "hunter2"` is a T001 unknown-constructor error) and no Eq
;;   (a hand comparison would route around Crypto.checkPassword).
;;
;; Secret — key material.  SECRET.  Minted by `Env.requireSecret`, by a `secret`
;;   column, or by a user's own `secret MyKey = String` declaration.
;;
;; Signature — a MAC tag.  NOT secret: publishing it is the entire point, and
;;   redacting it in a debugger would make webhook debugging impossible.  It has
;;   no Eq, because its only legitimate comparison IS a verification.
(define-secret-newtype PasswordHash String)
(define-secret-newtype Secret       String)
(define-newtype        Signature    String)

;; ── Proof predicate name symbols ────────────────────────────────────────────
;; Usable in Tesl annotations:
;;   hash ::: HashFor plaintext          (this hash is of THAT plaintext)
;;   stored ::: PasswordVerified stored  (a password was checked against it)
;;   payload ::: Authentic payload       (this payload's MAC verified)
(define HashFor          'HashFor)
(define PasswordVerified 'PasswordVerified)
(define Authentic        'Authentic)

;; ════════════════════════════════════════════════════════════════════════════
;;  Internal helpers
;; ════════════════════════════════════════════════════════════════════════════

;; Unwrap a (possibly proof-bearing, possibly newtype-wrapped) value to a plain
;; Racket string.  This is the ONLY place a secret becomes a bare string, and it
;; is inside the trusted body — which is the whole design.
(define (raw-str s)
  (define v (raw-value s))
  (if (newtype-value? v) (newtype-value-value v) v))

(define (secret->bytes s) (string->bytes/utf-8 (raw-str s)))

(define (attach-proof-to pred-name value)
  (define nv (ensure-named pred-name value))
  (define subj (named-value-name nv))
  (attach nv (list (detached-proof `(,pred-name ,subj) (hash subj value)))))

;; The documented maximum password length, in BYTES of UTF-8.
;;
;; libsodium imposes no bound of its own (`crypto_pwhash_passwd_max` reports
;; 2^32-1, and a 100 KB "password" hashes happily), so an unbounded memory-hard
;; hash on an unauthenticated login endpoint is a free amplification attack.
;; 1024 bytes accepts every real passphrase — including CJK, where one character
;; costs 3 bytes — while capping the work at one hash.  Over the bound is a
;; rejection, never a truncation: silent truncation is precisely the bcrypt
;; 72-byte bug.
(define crypto-max-password-bytes 1024)

(define (password-bytes who s)
  (define b (string->bytes/utf-8 (raw-str s)))
  (if (> (bytes-length b) crypto-max-password-bytes)
      (check-fail (format (string-append
                           "password is too long: ~a bytes, maximum is ~a. "
                           "Reject over-long input at the request boundary; "
                           "hashing it is a denial-of-service amplifier.")
                          (bytes-length b) crypto-max-password-bytes)
                  400 '())
      b))

;; libsodium's PHC strings are NUL-terminated C strings in a fixed-size buffer.
(define (c-string-of buf)
  (bytes->string/utf-8 (car (regexp-match #rx#"^[^\0]*" buf))))

(define (nul-terminated str)
  (bytes-append (string->bytes/utf-8 str) (bytes 0)))

;; Constant-time byte comparison.  Length inequality is decided WITHOUT calling
;; sodium_memcmp (which requires equal lengths); that leaks only the length,
;; which is inherent and is not the secret.
(define (constant-time-bytes=? a b)
  (and (= (bytes-length a) (bytes-length b))
       (zero? (sodium_memcmp a b (bytes-length a)))))

;; The hook the `==` lowering uses for secret-typed operands, so the familiar
;; operator keeps working and the timing leak does not exist.
(define (crypto-constant-time-equal? a b)
  (constant-time-bytes=? (string->bytes/utf-8 (raw-str a))
                         (string->bytes/utf-8 (raw-str b))))

(define (sha256-bytes b)
  (define out (make-bytes 32))
  (crypto_hash_sha256 out b (bytes-length b))
  out)

(define (sha512-bytes b)
  (define out (make-bytes 64))
  (crypto_hash_sha512 out b (bytes-length b))
  out)

(define (hmac-sha256-bytes key-bytes data-bytes)
  (define st (make-bytes (crypto_auth_hmacsha256_statebytes)))
  (crypto_auth_hmacsha256_init st key-bytes (bytes-length key-bytes))
  (crypto_auth_hmacsha256_update st data-bytes (bytes-length data-bytes))
  (define out (make-bytes 32))
  (crypto_auth_hmacsha256_final st out)
  out)

;; base64url without padding (RFC 4648 §5) — URL-safe and header-safe, so a
;; randomToken can go in a path, a query string or a header unescaped.
(define (base64url-encode bstr)
  (define b64 (bytes->string/utf-8 (base64-encode bstr #"")))
  (regexp-replace* #rx"=+$"
                   (string-replace (string-replace b64 "+" "-") "/" "_")
                   ""))

;; ════════════════════════════════════════════════════════════════════════════
;;  Password storage
;; ════════════════════════════════════════════════════════════════════════════

;; Crypto.hashPassword : String -> PasswordHash ::: HashFor plaintext
;;
;; Argon2id at libsodium's INTERACTIVE parameters, read from the library so an
;; upgrade strengthens new hashes with no application change.  Draws a random
;; salt, hence `requires [random]`.
;;
;; The `::: HashFor plaintext` half is COMPILE-TIME ONLY: the fact is about the
;; argument, and Tesl proofs are erased, so there is nothing to attach at
;; runtime.  What it buys is that `storeNewPassword user np (hashPassword
;; oldPassword)` does not compile — see example/learn's change-password lesson.
(define (Crypto.hashPassword plaintext)
  (require-capabilities! (list random))
  (define pw (password-bytes 'Crypto.hashPassword plaintext))
  (if (check-fail? pw)
      pw
      (let ([out (make-bytes (crypto_pwhash_strbytes))])
        (define rc (crypto_pwhash_str out pw (bytes-length pw)
                                      (crypto_pwhash_opslimit_interactive)
                                      (crypto_pwhash_memlimit_interactive)))
        (unless (zero? rc)
          ;; The documented failure is out-of-memory: Argon2id at INTERACTIVE
          ;; wants 64 MiB.  Say so, rather than "returned -1".
          (raise-user-error 'Crypto.hashPassword
                            (string-append
                             "libsodium crypto_pwhash_str failed (rc=~a). The usual cause is "
                             "that the process could not allocate the ~a MiB Argon2id needs; "
                             "raise the container memory limit.")
                            rc
                            (quotient (crypto_pwhash_memlimit_interactive) (* 1024 1024))))
        (PasswordHash (c-string-of out)))))

;; A dummy hash used ONLY to equalise timing when there is no user row.
;;
;; Generated lazily with the CURRENT parameters and cached, rather than
;; hardcoded: a hardcoded constant would drift from the live parameters on a
;; libsodium upgrade and silently reintroduce the timing difference it exists to
;; remove.  The first `Nothing` verification pays for one extra hash; every
;; later one is free.
(define timing-equaliser
  (delay
    (define pw (crypto-random-bytes 32))
    (define out (make-bytes (crypto_pwhash_strbytes)))
    (crypto_pwhash_str out pw (bytes-length pw)
                       (crypto_pwhash_opslimit_interactive)
                       (crypto_pwhash_memlimit_interactive))
    (c-string-of out)))

;; Crypto.checkPassword : Maybe PasswordHash -> String
;;                     -> ok stored ::: PasswordVerified stored | fail 401
;;
;; Takes a `Maybe` deliberately.  `checkPassword` is normally reached only when a
;; user row exists, so a missing user would return in microseconds while an
;; existing one costs ~80 ms of deliberate work — and the login endpoint would
;; leak which email addresses are registered.  Accepting `Nothing` and hashing
;; against a dummy makes a missing user and a wrong password cost the same.  The
;; caller does not have to know that this problem exists, which is the point.
(define (Crypto.checkPassword stored candidate)
  (define pw (password-bytes 'Crypto.checkPassword candidate))
  ;; `raw-value` FIRST, before any predicate test.  A parameter does not
  ;; necessarily arrive as its value: the GDP machinery may hand over the
  ;; SUBJECT NAME (a bare symbol such as 'stored2859) which `raw-value` resolves
  ;; through `current-evidence-env`, and it may also arrive wrapped in a
  ;; named-value or check-ok.  Testing `Something?` on the unresolved form
  ;; silently falls through to the fallback branch and then trips on a
  ;; type contract deep inside the FFI marshalling — which is exactly what
  ;; happened while writing lesson64.  Every stdlib function in this tree
  ;; normalises its arguments on the first line for this reason
  ;; (`tesl/string.rkt`'s `raw-str` is the same idiom).
  (define stored* (raw-value stored))
  (cond
    [(check-fail? pw) pw]
    [else
     (define phc
       (cond
         [(Nothing? stored*) (force timing-equaliser)]
         [(Something? stored*) (raw-str (Something-value stored*))]
         ;; Tolerate a bare PasswordHash: a `Maybe` column read may already have
         ;; been unwrapped by the caller's `case`, and failing closed here would
         ;; turn a working login into a 500.
         [else (raw-str stored*)]))
     (define ok? (zero? (crypto_pwhash_str_verify (nul-terminated phc)
                                                  pw (bytes-length pw))))
     ;; A wrong password and a missing user return the SAME message, because the
     ;; message is part of the enumeration surface.
     (if (and ok? (not (Nothing? stored*)))
         (let* ([nv   (attach-proof-to 'PasswordVerified stored)]
                [subj (named-value-name nv)]
                [fact `(PasswordVerified ,subj)])
           (check-ok nv (list fact) (hash subj stored)))
         (check-fail "invalid credentials" 401 '()))]))

;; Crypto.needsRehash : PasswordHash -> Bool
;;
;; #t when the stored hash was minted with weaker parameters than the current
;; ones, or in a format this libsodium cannot parse at all (a foreign hash, or
;; one from a scheme we have dropped) — in both cases the right move on the next
;; successful login is to re-mint, so both answer #t.
;;
;; Tesl deliberately does NOT perform the rehash: a crypto function writing to
;; the database would be a hidden effect and would couple this module to the data
;; model.  It is one explicit line in the application.
(define (Crypto.needsRehash stored)
  (not (zero? (crypto_pwhash_str_needs_rehash
               (nul-terminated (raw-str stored))
               (crypto_pwhash_opslimit_interactive)
               (crypto_pwhash_memlimit_interactive)))))

;; ════════════════════════════════════════════════════════════════════════════
;;  Message authentication
;; ════════════════════════════════════════════════════════════════════════════

;; Crypto.signWith : Secret -> String -> Signature
;;
;; HMAC-SHA256.  Configuration first, subject last, so `payload |> signWith key`
;; reads correctly and `Crypto.signWith key` partially applies into a reusable
;; signer.
;;
;; Deliberately NOT called `sign`: this is SYMMETRIC authentication.  If
;; asymmetric signing (Ed25519, also in libsodium) is ever added it needs the
;; bare name, and having the symmetric one squatting there invites exactly the
;; wrong inference — "I signed it, so anyone can verify it".
(define (Crypto.signWith key payload)
  (Signature
   (bytes->hex-string
    (hmac-sha256-bytes (string->bytes/utf-8 (raw-str key))
                       (string->bytes/utf-8 (raw-str payload))))))

;; Crypto.checkSignature : Secret -> Signature -> String
;;                       -> ok payload ::: Authentic payload | fail 401
;;
;; The constant-time compare lives in here, where it cannot be got wrong, which
;; is why there is no `constantTimeEquals` on the surface at all.
(define (Crypto.checkSignature key sig payload)
  (define payload-bytes (string->bytes/utf-8 (raw-str payload)))
  (define expected (hmac-sha256-bytes (string->bytes/utf-8 (raw-str key))
                                      payload-bytes))
  (define actual
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (hex-string->bytes (raw-str sig))))
  (if (and actual (constant-time-bytes=? expected actual))
      (let* ([nv   (attach-proof-to 'Authentic payload)]
             [subj (named-value-name nv)]
             [fact `(Authentic ,subj)])
        (check-ok nv (list fact) (hash subj payload)))
      (check-fail "signature does not match" 401 '())))

;; Crypto.signatureHex : Signature -> String
;;
;; The transport form, for putting a signature you produced into a header or a
;; body.  A MAC tag is public data, so this is not an unwrap of a secret.
;;
;; It DOES make `Crypto.signatureHex a == Crypto.signatureHex b` expressible,
;; which is a timing-unsafe MAC comparison — the classic bug.  That is why
;; SEC002 exists: comparing a signatureHex result is a Security diagnostic with
;; a machine-applicable fix pointing at Crypto.checkSignature.
(define (Crypto.signatureHex sig)
  (raw-str sig))

;; Crypto.signatureFromHex : String -> Signature
;;
;; The inbound half: a webhook's signature arrives as a hex string in a header
;; (Stripe, GitHub), and `checkSignature` needs it as a Signature.  Parsing an
;; untrusted tag is safe — a Signature can still not be compared, and it can
;; still only be consumed by a verification.
(define (Crypto.signatureFromHex hex)
  (Signature (raw-str hex)))

;; Crypto.signatureBase64 : Signature -> String
;;
;; The base64 transport form.  Standard Webhooks (Svix and, by convention, a
;; growing set of senders) puts the tag in `webhook-signature: v1,<base64>`, so
;; a Tesl app talking to such a receiver needs base64, not hex.  Same status as
;; `signatureHex`: a tag is public data, not a secret, and comparing two of
;; these by hand is the SEC004 timing bug — verify with `checkSignature`.
(define (Crypto.signatureBase64 sig)
  (bytes->string/utf-8 (base64-encode (hex-string->bytes (raw-str sig)) #"")))

;; Crypto.signatureFromBase64 : String -> Signature
;;
;; The inbound half for a base64 tag (Standard Webhooks).  Parsing an untrusted
;; tag is safe — a Signature still cannot be compared and can only be consumed
;; by a verification; malformed input fails the verification cleanly.
(define (Crypto.signatureFromBase64 b64)
  (Signature (bytes->hex-string (base64-decode (string->bytes/utf-8 (raw-str b64))))))

;; ════════════════════════════════════════════════════════════════════════════
;;  Digests
;; ════════════════════════════════════════════════════════════════════════════

;; Crypto.fingerprint : String -> String
;;
;; A stable content digest — ETags, cache keys, dedup, idempotency keys.
;; SHA-256, hex.  Not for passwords: a fast digest of a password is exactly the
;; mistake `hashPassword` exists to prevent.
(define (Crypto.fingerprint content)
  (bytes->hex-string (sha256-bytes (string->bytes/utf-8 (raw-str content)))))

;; Crypto.keyFingerprint : Secret -> String
;;
;; "Did I load the right key?" — a short, non-reversible identifier that is safe
;; to log and to show in a deploy check.  SSH has identified keys this way for
;; thirty years.
;;
;; Domain-separated (the label is hashed in) so this value can never coincide
;; with `Crypto.fingerprint` of the same string, and truncated to 8 bytes so it
;; reads as an identifier rather than as something to compare cryptographically.
;; It is NOT proof of key possession.
;;
;; "Safe to log" is a TRADE, not a free property, and publishing it (Tesl stamps
;; it as every JWT's `kid`) makes the trade explicit: this is a 64-bit function
;; of the key, so it is an offline key-guess oracle costing one SHA-256 per
;; candidate — irrelevant against a generated `Secret`, but it makes a GUESSABLE
;; key cheaper to confirm — and two systems showing the same fingerprint
;; demonstrably share a key.  See the `kid` note in `tesl/jwt.rkt`.
(define key-fingerprint-label #"tesl-key-fingerprint-v1\0")

(define (Crypto.keyFingerprint key)
  (bytes->hex-string
   (subbytes (sha256-bytes (bytes-append key-fingerprint-label
                                         (string->bytes/utf-8 (raw-str key))))
             0 8)))

;; ════════════════════════════════════════════════════════════════════════════
;;  Tokens
;; ════════════════════════════════════════════════════════════════════════════

;; Crypto.randomToken : () -> String
;;
;; 256 bits from the OS CSPRNG, base64url-encoded (43 characters, URL-safe, no
;; padding).  There is no length parameter, on purpose: a caller who can pass 4
;; will.  Use it for a session id, a reset token, a fresh API key — and store
;; only its `fingerprint`, never the token itself.
(define (Crypto.randomToken)
  (require-capabilities! (list random))
  (base64url-encode (crypto-random-bytes 32)))

;; ════════════════════════════════════════════════════════════════════════════
;;  Expert aliases
;; ════════════════════════════════════════════════════════════════════════════
;; The friendly name is the one a newcomer can pick correctly from the name
;; alone; these exist so an expert who already knows what they want can say it,
;; and so a code search for "hmac" or "sha256" lands somewhere useful.  They are
;; never required to write correct code.
(define Crypto.hmacSha256 Crypto.signWith)

(define (Crypto.sha256 content)
  (bytes->hex-string (sha256-bytes (string->bytes/utf-8 (raw-str content)))))

(define (Crypto.sha512 content)
  (bytes->hex-string (sha512-bytes (string->bytes/utf-8 (raw-str content)))))
