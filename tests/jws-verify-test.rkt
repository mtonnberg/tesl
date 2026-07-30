#lang racket/base

;;; Phase 2.5 (roadmap/next/ensure_sso_works.md) — RS256/ES256 JWS verification.
;;; Fixtures (RSA/EC keys + valid tokens) were generated once with the openssl
;;; CLI and embedded, so the suite is hermetic.  The adversarial refusals are the
;;; point: alg:none, HMAC-on-an-ID-token, alg-not-pinned, header key nomination,
;;; JWE, wrong kid, sub-2048 modulus, and a tampered payload must each be refused.

(require rackunit
         json
         racket/string
         (only-in "../tesl/crypto.rkt" base64url-encode)
         "../dsl/private/jws-verify.rkt")

(define RSA-JWK (string->jsexpr "{\"kty\":\"RSA\",\"kid\":\"rsa-1\",\"n\":\"v9AozHESm16JUXLcu1QX7MftsUHe2mchu8RrcL0vh8W_RPp7tyiMxyKA0hxcr3AmXoe17jL4PtnDTkw69lR1hY5l-Wspw_zpTMDxzAwZoY03kphOzYZ364BtDPinTs9TjfAXUm891PXvqn0OvnE7vsIkh1W2MfZyAOKGkI92EFw6whU0Jf0tVaJMiWrxCWrESq2RotWnq0fKvIoIPXlbxAg8c9ch2F3r0UYau7WHtyAvcxc_ILFgysEqET8TRJfv76Ne11t7o6g0pAKtN7-UR5PdlMTorYfHT6N7x6UUIuHe5PQC23U0uiY9NeNhnYipiHlBvuxi9ykLVfrJLuuXCQ\",\"e\":\"AQAB\"}"))
(define EC-JWK (string->jsexpr "{\"kty\":\"EC\",\"kid\":\"ec-1\",\"crv\":\"P-256\",\"x\":\"5U4zXJcwvKf7pzSsl3upW_g9xBOu5uIe195IhyxXQv0\",\"y\":\"cB9yXrI0e7eIF7nwc-tw2eI6PbFZGPxNuWYYyqDNe18\"}"))
(define JWKS (hasheq 'keys (list RSA-JWK EC-JWK)))

(define RS-TOKEN "eyJhbGciOiJSUzI1NiIsImtpZCI6InJzYS0xIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2lzc3Vlci5leGFtcGxlIiwic3ViIjoidXNlci0xIiwiYXVkIjoiY2xpZW50LTEifQ.qZWle9wGuxhcnYuQN9AJT4jNSZ5LXIFLO8DXwtRB_-yDyTh3UT9tYgO6HWt4kqupsOSArlWnjbAGS1UY3iDulrHPr7nZDv5BANZXlerA0MbIY4Ruyrqt3MpPAjVGMZAjdh4f12MvrdwYXPSvO1sF7bZL9QYqHafDjP3kDpINBw-S0qRiwENH0Nsi_IeLTFlKTdnmV1gbP6sg2vENmIzA3q6g1CI1xQfMIYZWayZCy5UzuMl35TOY90QoxRQS7c43otC5kgDu6rkLhhWPoN-2RYgzY_uYlLlrzqWnZQ45MOCE3vIB34dZuuFaMx4F5IMGYclZfQ7OCOVflEkyh_xFMg")
(define ES-TOKEN "eyJhbGciOiJFUzI1NiIsImtpZCI6ImVjLTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2lzc3Vlci5leGFtcGxlIiwic3ViIjoidXNlci0xIiwiYXVkIjoiY2xpZW50LTEifQ.JNoehu88Ko25m9rDZmOARwOkr_PojTdY84vDCC9UrVD_kuyuBnc02Yz9X9ANlscpL8LWjq1gnxDl8-sCBG4mLg")

(define ALGS '("RS256" "ES256"))
(define (b64u b) (base64url-encode b))
(define (mk-token header) ; craft a token whose signature is irrelevant (refused earlier)
  (string-append (b64u (jsexpr->bytes header)) "." (b64u #"{\"sub\":\"x\"}") "." "AAAA"))

;;; ── Positive paths ────────────────────────────────────────────────────────────
(test-case "a valid RS256 token verifies against its JWKS key"
  (check-equal? (verify-jws RS-TOKEN JWKS #:algs ALGS) #t))

(test-case "a valid ES256 token verifies (raw r||s converted to DER)"
  (check-equal? (verify-jws ES-TOKEN JWKS #:algs ALGS) #t))

;;; ── Algorithm confusion ───────────────────────────────────────────────────────
(test-case "alg:none is refused"
  (check-true (string? (verify-jws (mk-token (hasheq 'alg "none" 'kid "rsa-1")) JWKS #:algs ALGS))))

(test-case "an HMAC alg on an ID token is refused (sign-with-the-public-key)"
  (check-true (string? (verify-jws (mk-token (hasheq 'alg "HS256" 'kid "rsa-1")) JWKS #:algs ALGS))))

(test-case "an alg outside the pinned set is refused"
  (check-true (string? (verify-jws RS-TOKEN JWKS #:algs '("ES256"))))  ; RS token, ES-only pin
  (check-true (string? (verify-jws (mk-token (hasheq 'alg "RS384" 'kid "rsa-1")) JWKS #:algs ALGS))))

;;; ── Key nomination via the token header ───────────────────────────────────────
(test-case "a header nominating its own key (jwk/jku/x5u/x5c/crit) is refused"
  (for ([k (in-list '(jwk jku x5u x5c crit))])
    (check-true (string? (verify-jws (mk-token (hasheq 'alg "RS256" 'kid "rsa-1" k "x"))
                                     JWKS #:algs ALGS))
                (format "~a must be refused" k))))

;;; ── Structural refusals ───────────────────────────────────────────────────────
(test-case "a JWE (five-segment) token is refused, not unwrapped"
  (check-true (string? (verify-jws "a.b.c.d.e" JWKS #:algs ALGS))))

(test-case "an unknown kid is refused"
  (define other (hasheq 'keys (list EC-JWK)))  ; no rsa-1
  (check-true (string? (verify-jws RS-TOKEN other #:algs ALGS))))

(test-case "an under-2048-bit RSA modulus is refused"
  (define small (hasheq 'kty "RSA" 'kid "small" 'n (b64u (make-bytes 128 255)) 'e "AQAB")) ; 1024-bit
  (define jwks (hasheq 'keys (list small)))
  (define tok (mk-token (hasheq 'alg "RS256" 'kid "small")))
  (define r (verify-jws tok jwks #:algs ALGS))
  (check-true (string? r))
  (check-regexp-match #rx"2048" r))

;;; ── A tampered payload fails verification ─────────────────────────────────────
(test-case "flipping the payload breaks the signature"
  (define parts (string-split RS-TOKEN "."))
  (define tampered (string-append (car parts) "."
                                  (string-append "x" (substring (cadr parts) 1)) "."
                                  (caddr parts)))
  (check-equal? (verify-jws tampered JWKS #:algs ALGS) "signature verification failed"))

;;; ── es256-raw->der converter ─────────────────────────────────────────────────
(test-case "es256-raw->der needs exactly 64 bytes"
  (check-false (es256-raw->der (make-bytes 63 1)))
  (check-true (bytes? (es256-raw->der (make-bytes 64 1)))))
