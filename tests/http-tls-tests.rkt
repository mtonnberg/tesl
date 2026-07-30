#lang racket

;;; Phase -1 regression suite (roadmap/next/ensure_sso_works.md):
;;; outbound HTTPS must authenticate its TLS peer.
;;;
;;; Three properties are asserted:
;;;   1. Ratchet — no bare `#:ssl? #t` literal survives in tesl/http-client.rkt
;;;      (comments stripped), so no second "don't verify" opt-out can reappear.
;;;   2. Behaviour — an HTTPS peer presenting an untrusted (self-signed)
;;;      certificate is REFUSED by default, even on loopback.
;;;   3. The single development escape — engages for a loopback host only, and
;;;      only when TESL_HTTP_TLS_INSECURE_DEV is set and TESL_DEPLOYED is not.

(require rackunit
         racket/runtime-path
         openssl
         (only-in "../dsl/capability.rkt" with-capabilities)
         (only-in "../tesl/http-client.rkt"
                  httpClient
                  HttpClient.get
                  HttpResponse?
                  tls-insecure-dev-escape?
                  host-loopback?))

(define-runtime-path http-client-src "../tesl/http-client.rkt")

;;; ── 1. Ratchet: no bare `#:ssl? #t` in code (comments stripped) ──────────────

(define (strip-line-comments src)
  ;; Racket line comments start with `;`. Drop everything from the first `;`
  ;; that is not inside a string. This is coarse but sufficient: the literal we
  ;; forbid never appears inside a string in this file.
  (string-join
   (for/list ([line (in-list (string-split src "\n"))])
     (let ([idx (let loop ([i 0] [in-str #f])
                  (cond
                    [(>= i (string-length line)) #f]
                    [(char=? (string-ref line i) #\") (loop (add1 i) (not in-str))]
                    [(and (not in-str) (char=? (string-ref line i) #\;)) i]
                    [else (loop (add1 i) in-str)]))])
       (if idx (substring line 0 idx) line)))
   "\n"))

(test-case "ratchet: no bare `#:ssl? #t` literal remains in http-client.rkt"
  (define code (strip-line-comments (file->string http-client-src)))
  (check-false (regexp-match? #rx"#:ssl\\?[ \t]+#t" code)
               "a bare non-verifying `#:ssl? #t` reappeared in outbound HTTP code")
  (check-true (regexp-match? #rx"ssl-secure-client-context" code)
              "the verifying client context must be used"))

;;; ── helper: a local TLS server presenting a self-signed certificate ──────────

;; Self-signed cert/key generated once (CN=tesl-test-selfsigned, 100y). Untrusted
;; by any store, so a verifying client must refuse it.
(define self-signed-cert #<<CERT
-----BEGIN CERTIFICATE-----
MIIDITCCAgmgAwIBAgIURSnrIExgDHKpZDO/Hr2Nv6nvmPowDQYJKoZIhvcNAQEL
BQAwHzEdMBsGA1UEAwwUdGVzbC10ZXN0LXNlbGZzaWduZWQwIBcNMjYwNzMwMTU0
MzE4WhgPMjEyNjA3MDYxNTQzMThaMB8xHTAbBgNVBAMMFHRlc2wtdGVzdC1zZWxm
c2lnbmVkMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtLBHzS0P0Kt/
QmhOCr0Oy/ysw4vZ8QFUQ4x3YUA0TmTpkO8/i1hHykh9fzVeiTWxVIooVGuS3qaL
NsUWk0LDJs4toYBtflEfaHe+LxjxSGSfMkUy3frSKJu+sJwb0EIMfv4gQS6fmZ/O
OAnuXPazZMBBx9Czu7uYMYJaob3VaH5khN1H+lELgVDtOBWaejwSa4uwTA1FaAAK
IEF+MYO50ThR9nCzsGZvTterI8fAqF0t96uskQKEd3thJJfSxjHpGmlP4g+hx4+E
JkBKAUiwi+YFQ+AWGGfYuDFFr4QPM3oPg9tQgedFAKrCGu8zg94PR68TZwqZkEJl
SQ8rpntJGwIDAQABo1MwUTAdBgNVHQ4EFgQUaYCxLflyiZapYgl16alxekykhvAw
HwYDVR0jBBgwFoAUaYCxLflyiZapYgl16alxekykhvAwDwYDVR0TAQH/BAUwAwEB
/zANBgkqhkiG9w0BAQsFAAOCAQEAkU2UwITuvHbw3WNURB6cDBMf3g5L6LtRGauR
EPiNc5uNlZGZHQMQmsqDJzN6qtakGsJsSMQtfLww6UkCmdm9NeVeQVp4FHB02KR1
HyxgXmKbpfigyD2/3SV0m6YX466FatAl6IKY7VdVpehHI1FVZ5DzwnFABQMo3TEB
+o5fseH3HM2dACdAz5kiNxubG+L8Xd3O8V0au3PGaRivV8LArAGXxlOycoqqauwj
ymk8QxWWEx3x6a+M+2YsBX8TzGuAUKVu4R6bfF7BUHYsT0xCAyFdBe6m43vjfLns
tDpwj1JY9R9GbNGow8ueOIV2yfh7suPQDcJfhTgWTkFCfFgQJg==
-----END CERTIFICATE-----
CERT
)
(define self-signed-key #<<KEY
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC0sEfNLQ/Qq39C
aE4KvQ7L/KzDi9nxAVRDjHdhQDROZOmQ7z+LWEfKSH1/NV6JNbFUiihUa5Lepos2
xRaTQsMmzi2hgG1+UR9od74vGPFIZJ8yRTLd+tIom76wnBvQQgx+/iBBLp+Zn844
Ce5c9rNkwEHH0LO7u5gxglqhvdVofmSE3Uf6UQuBUO04FZp6PBJri7BMDUVoAAog
QX4xg7nROFH2cLOwZm9O16sjx8CoXS33q6yRAoR3e2Ekl9LGMekaaU/iD6HHj4Qm
QEoBSLCL5gVD4BYYZ9i4MUWvhA8zeg+D21CB50UAqsIa7zOD3g9HrxNnCpmQQmVJ
Dyume0kbAgMBAAECggEAAMVp1Dw95e/9b8A4AqXsHL6POP+gf/23j6XXUpc7QerL
VmUdZwMkin5egfItds9ywMyDWVmvyEeuSDiog06UvG/2On5TH7SWU9QcmZRB+PZs
LLY/5KBv6i1z/GP5XtB3v8kAET2MmW0lrHaNlmCVKZ5qb9rG3mVYENbTrsuh6aHy
nz3U90Z5eOQAfrZ3rsT58OQ9z0u876P459K0s0kbmWoXAb3I3P6TsgPAvn7fYYWm
4edRPEyCfjB8aIP03WMNEJWDU+rQeLdab+XBFcJDZTYg9TV1+jA1zyRY5VH/+R24
BmSCwPnrxN68NK8sIP46ETH4uMmWCNoTwnmwnNSDzQKBgQDkjErVebQkW/Z1OjPF
vAL82G4xjQ1vIUB9yLS1CtMVq20BLnyFdiLHcb3FpMvCdCngOj4uJGh50nkBpJOn
EXK9BkowqQa91ZT53rEeKUb+29wjqNyKBJMj+Nt1nHCf8PX6Aht1FesMR3x0Rbzp
MQkVzT547+mieXQ0+A9jbLwsDwKBgQDKZFdQcqnynmAQpQtL9+wZ0HRC2oFRZjnJ
HrOSVaK+Nl7WSjQ+uLehGTCh/xs5nA2XL2DrPA0ZG0fveFw8yCLMIGgOz9UBTBwU
5VvusSe4NY3MnI19kj2ZDwDXbSRfgKt+kaRyuiwMbsQQTyFBHGoEKq9IliYpfEw1
2fga2xU2NQKBgGudb6NDUkKIlu0uAbDKzbFXC9QDMd8xDhfsSMKynSAn/wS+ad3B
+bBl61DEPzmJzyoI4ryBYjxykY3ne6sAOUGuU4LEJCuBBUv+wvGLyCU7S1XzLh1C
+DHI/TVM+28kW/5jvaANOQcoJf7t030OHNQKN69kcGOTwtcqMrzDN3ubAoGAXV5x
EYH0eSMrOkKJtaBIYZhTKkxXgE/itK/fM9Eh5RJ8KevNsmnQ/Rb74qAn1Sny8x4+
Xgc0G7MEOquSEdBajUUd/EdRAuozwkgVY0aDBm5eXliSxa1jkWrkfn2xXAWmGBvk
e7D7hTjMZqG6u6j6F7YBa0EpldXr6qQF243aeUkCgYEA1RFIQXSerM+npEIPiToe
Dcg/4QpJbwXpqwzbDfEvIj1H+iOhaZqpMoszoqNSl5Pb4fWTeOVK06HHEyIbH2u2
KXZ9sralNuIx7uRXsxCarvuFWB7yIBSLqpik3lh0YxtDb4Aa6OZzTJqgsz9qFIGi
93IYEGLCGkXyODPrSSgti90=
-----END PRIVATE KEY-----
KEY
)

(define (with-selfsigned-tls-server proc)
  (define tmp (make-temporary-file "tesl-tls-~a" 'directory))
  (define cert-path (build-path tmp "cert.pem"))
  (define key-path  (build-path tmp "key.pem"))
  (call-with-output-file cert-path (lambda (o) (write-string self-signed-cert o)) #:exists 'replace)
  (call-with-output-file key-path  (lambda (o) (write-string self-signed-key o))  #:exists 'replace)
  (define ctx (ssl-make-server-context))
  (ssl-load-certificate-chain! ctx cert-path)
  (ssl-load-private-key! ctx key-path)
  (define listener (ssl-listen 0 4 #t "127.0.0.1" ctx))
  (define-values (_lh port _rh _rp) (ssl-addresses listener #t))
  ;; A trivial one-shot HTTPS responder thread, tolerant of a client that drops
  ;; the connection mid-handshake (the refusal case).
  (define server-thread
    (thread
     (lambda ()
       (let loop ()
         (with-handlers ([exn:fail? (lambda (_e) (void))])
           (define-values (in out) (ssl-accept listener))
           (with-handlers ([exn:fail? (lambda (_e) (void))])
             (read-line in)
             (write-string "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi" out)
             (flush-output out))
           (close-input-port in)
           (close-output-port out))
         (loop)))))
  (dynamic-wind
   void
   (lambda () (proc port))
   (lambda ()
     (kill-thread server-thread)
     (ssl-close listener)
     (delete-directory/files tmp))))

;;; ── 2. A self-signed HTTPS peer is refused by default (loopback included) ─────

(test-case "verifying context refuses a self-signed peer, even on loopback"
  (parameterize ([current-environment-variables
                  (make-environment-variables)])  ; no dev escape, no deploy flag
    (with-selfsigned-tls-server
     (lambda (port)
       (with-capabilities (httpClient)
         (check-exn
          (lambda (e)
            (and (exn:fail? e)
                 (regexp-match? #rx"(?i:certificate|verify|ssl|tls)"
                                (exn-message e))
                 (not (regexp-match? #rx"invalid URL" (exn-message e)))))
          (lambda ()
            (HttpClient.get (format "https://127.0.0.1:~a/" port) '()))
          "a self-signed peer must be refused when verification is on"))))))

;;; ── 3. The single development escape ─────────────────────────────────────────

(test-case "dev escape: engages for loopback only, gated by env"
  ;; No env set → never engages.
  (parameterize ([current-environment-variables (make-environment-variables)])
    (check-false (tls-insecure-dev-escape? "127.0.0.1"))
    (check-false (tls-insecure-dev-escape? "example.com")))
  ;; Env set → engages for loopback, refuses routable hosts.
  (parameterize ([current-environment-variables
                  (make-environment-variables
                   #"TESL_HTTP_TLS_INSECURE_DEV" #"1")])
    (check-true  (tls-insecure-dev-escape? "127.0.0.1"))
    (check-true  (tls-insecure-dev-escape? "localhost"))
    (check-false (tls-insecure-dev-escape? "example.com")
                 "the escape must never engage for a routable host"))
  ;; Env set but deployed → refuses everywhere.
  (parameterize ([current-environment-variables
                  (make-environment-variables
                   #"TESL_HTTP_TLS_INSECURE_DEV" #"1"
                   #"TESL_DEPLOYED" #"1")])
    (check-false (tls-insecure-dev-escape? "127.0.0.1")
                 "the escape must refuse in a deployed build")))

(test-case "dev escape lets a loopback self-signed peer connect"
  (with-selfsigned-tls-server
   (lambda (port)
     (parameterize ([current-environment-variables
                     (make-environment-variables
                      #"TESL_HTTP_TLS_INSECURE_DEV" #"1")])
       (with-capabilities (httpClient)
         (define resp (HttpClient.get (format "https://127.0.0.1:~a/" port) '()))
         (check-true (HttpResponse? resp)
                     "with the loopback dev escape, a self-signed peer connects"))))))

(test-case "host-loopback? classifies hosts"
  (check-true  (host-loopback? "127.0.0.1"))
  (check-true  (host-loopback? "127.5.6.7"))
  (check-true  (host-loopback? "localhost"))
  (check-true  (host-loopback? "::1"))
  (check-false (host-loopback? "example.com"))
  (check-false (host-loopback? "10.0.0.1")))

;;; ── 3. Wrong-hostname refusal (issue #47's second scenario, hermetic) ────────
;;;
;;; The #47 probe used `wrong.host.badssl.com`: a certificate whose CHAIN is
;;; valid but whose name does not match the connected host.  This reproduces
;;; that offline: a self-signed cert for `wrong.example` is TRUSTED as a root by
;;; the client (so chain verification passes and is removed as a variable), then
;;; a connection is made to `127.0.0.1` — the only remaining check that can fail
;;; is the hostname, and it must.  It exercises `ssl-secure-client-context` (the
;;; same verify + verify-hostname recipe `ssl-secure-client-context` uses).

(define wrong-host-cert #<<CERT
-----BEGIN CERTIFICATE-----
MIIDLTCCAhWgAwIBAgIUadr2Jv7WevVmzdw++GjO0Vvdp80wDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNd3JvbmcuZXhhbXBsZTAgFw0yNjA3MzExMjA2MThaGA8y
MTI2MDcwNzEyMDYxOFowGDEWMBQGA1UEAwwNd3JvbmcuZXhhbXBsZTCCASIwDQYJ
KoZIhvcNAQEBBQADggEPADCCAQoCggEBAK6thdmPRcLGy9LjqH5fcQtwp5N8o6jo
roMRNZyaAv4UgfCq6jhvJNXh66Z1UQ7V9BvA6rZEW7sJAfS1tgedWRjJb2Bq79lw
u5HRu1vqHq6FUmZd8Uc9wgnknhGzzA+8aMUoOAGF3gpSguguZT1Wn177K6gEkCUH
znCtOHTVkZjuR2iW5bkWEMw7nw/5Eesf+ngyqfXfsKIbVda4irBFcN9tN6LwuyMc
BINJz333FukLDVi/rDm8bSfyY9xiyMvjrYYS3Vom4/9qnj5XAaefV1u11iPnvc7R
HXWpaio3nQLeF2Bj+IrI5pzeM0JQ7bx7tCMs0+5lReMEATeDBUPIP20CAwEAAaNt
MGswHQYDVR0OBBYEFP76819Nn8bOroNDfcwGQscCzUr0MB8GA1UdIwQYMBaAFP76
819Nn8bOroNDfcwGQscCzUr0MA8GA1UdEwEB/wQFMAMBAf8wGAYDVR0RBBEwD4IN
d3JvbmcuZXhhbXBsZTANBgkqhkiG9w0BAQsFAAOCAQEAFE2XPey1qQu28gbvpBpu
LTrulpvF08f7iD8rZqBZI7i4R9iUg4JaWvfSwB3C51b0qdo2s/rOrunhlR3qXKiK
CXgsMpZZQSMBPflF1EtQnj7ZJXtJd6N1RLiWhBOfBiluR7/d94n9WCh42W5lCE4e
+LP/vKtEFfiMpj/XI3V2YdeUADtCf4GLhXmri4RF+tjGmF0Idzmj5bdyIwJsHVhw
GXqtghHtJ4+STvYWhghRvWR3nNuNY/mwYX8NpU6oSGwT7BJlZIzP4mL/1UuH2x/6
Ho8Q1Ew5dmPxXHt9s2hUjp46o3ta7OAzl5qngGt2N+ZIERWbLx02esbazzJDNXyf
BQ==
-----END CERTIFICATE-----
CERT
)

(define wrong-host-key #<<KEY
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCurYXZj0XCxsvS
46h+X3ELcKeTfKOo6K6DETWcmgL+FIHwquo4byTV4eumdVEO1fQbwOq2RFu7CQH0
tbYHnVkYyW9gau/ZcLuR0btb6h6uhVJmXfFHPcIJ5J4Rs8wPvGjFKDgBhd4KUoLo
LmU9Vp9e+yuoBJAlB85wrTh01ZGY7kdoluW5FhDMO58P+RHrH/p4Mqn137CiG1XW
uIqwRXDfbTei8LsjHASDSc999xbpCw1Yv6w5vG0n8mPcYsjL462GEt1aJuP/ap4+
VwGnn1dbtdYj573O0R11qWoqN50C3hdgY/iKyOac3jNCUO28e7QjLNPuZUXjBAE3
gwVDyD9tAgMBAAECggEAAv+qB6bjpXtuVQzX5JU0uNF7xvtT/6PS87HHJugnX7ZC
js1YVib3cmsY9ZyqHX+VyXB4dwtHPCVkXo+VdAuVQVZ2yc0FTzbxS60NabZR185t
sH0xp/bK81PQMEycFtg10jwTTg9jVTkIHP5sDF0qQRj0m0NMynlhMNBuK+YmaMtO
hckcgZtvgLSE+VR2r1k0eQ8Uact20748AswwT1JTpblk0k7A+YdXIOXivf/FPhXn
Tj1lVdjESGApitGiA7GR+w2drV3q96yUTi4p3PVfKPVKQ2eOEwgqPpZXVAEm4ml7
boHE/3lMAf7bZH490uf56+BXnBdKVIwVzMqIx2q6TwKBgQDrdvlXVVOwQ/lqQZ6q
XmAlz2pw+Iajeq7NokOZ+C/oz9hKEogxwJuqVicH9hKM4J/1RAVFb+iwqVo3ISQs
PCgHeYDFLEnqxR79sA15OOsY/phlsAqeUIYLws1vzCkgFZH490T/MBn8N1oRpPhN
ja6bplRiPTSHsseSGOycncOhDwKBgQC96WjlMhZY5NSOQ5ViDOFJkldR3nJH3He4
pcq3EUxDHt3Ltk8uztINcNN7YSi69FhhEqJpTRhXzsQ01GWTRZFeGg4NSyluu1VF
Eu887RDkEZEDI8tdBf/imvKvtDv02+u5xmIhTB5ZlNOiNZ84qrGq3Nche5xnb0jB
jM3MkQBfwwKBgA3FepXSBsADab3+MoJyXJs5g1cyIeXD0h9ywxNpQZwTM+o5JUAL
rM8MlOHRUYptxM06ejhycCCM9xrMVGpF5m1xfMeLbJNPjh12Q4N4gb+HfHBOGIDj
4sMjVJKaVTlsKYpvI9js/kgTELCBfohCphiyZLMOM1lQan2v+X67d2qfAoGATmZA
LnYJ8bKt6PkPf0XP715he+O4C+CA8BJJaF/UutTQPVvKvokVAAV22LVYai2bGp/l
ulDgXsd2ClUwhaavh0h8SpKfzR266uQRLXa0hWKXGdO6DXH/m93ZmB1wrvnnC29R
bWuOD+83mvxF+c/FvsKicSklfTHcuEJXZz7pB58CgYBTmCkk8ZwOn2I/JNv5NixW
sj17Fwq77emQkoS3YH4nZEoCScIrc1hbNTa9dAKQa/g1aYmzJ4qz18nX8qXQMUEh
XHC4Q5L+ICouXZGMv8ivixluGaHHvNkTP/Abk79iuvjMnv5gX23ivm/OlTCr0JXx
s0iU5yP/Ub5+ksL4mxoorg==
-----END PRIVATE KEY-----
KEY
)

(test-case "verifying context refuses a chain-trusted cert served for the wrong host"
  (define tmp (make-temporary-file "tesl-tls-wrong-~a" 'directory))
  (define cert-path (build-path tmp "cert.pem"))
  (define key-path  (build-path tmp "key.pem"))
  (call-with-output-file cert-path (lambda (o) (write-string wrong-host-cert o)) #:exists 'replace)
  (call-with-output-file key-path  (lambda (o) (write-string wrong-host-key o))  #:exists 'replace)
  (define sctx (ssl-make-server-context))
  (ssl-load-certificate-chain! sctx cert-path)
  (ssl-load-private-key! sctx key-path)
  (define listener (ssl-listen 0 4 #t "127.0.0.1" sctx))
  (define-values (_lh port _rh _rp) (ssl-addresses listener #t))
  (define server-thread
    (thread
     (lambda ()
       (let loop ()
         (with-handlers ([exn:fail? (lambda (_e) (void))])
           (define-values (in out) (ssl-accept listener))
           (with-handlers ([exn:fail? (lambda (_e) (void))]) (close-input-port in) (close-output-port out)))
         (loop)))))
  (dynamic-wind
   void
   (lambda ()
     ;; A verifying, hostname-checking client context that TRUSTS our test
     ;; root, so the chain is valid and the hostname is the only thing left to
     ;; check (`ssl-secure-client-context` is sealed and cannot take a test
     ;; root, so we reproduce its recipe: verify + verify-hostname).
     (define cctx (ssl-make-client-context 'auto))
     (ssl-set-verify! cctx #t)
     (ssl-set-verify-hostname! cctx #t)
     (ssl-load-verify-source! cctx cert-path)
     (check-exn
      (lambda (e)
        (and (exn:fail? e)
             (regexp-match? #rx"(?i:host|name|certificate|verify|ssl|tls)" (exn-message e))))
      (lambda ()
        (define-values (in out) (ssl-connect "127.0.0.1" port cctx))
        (close-input-port in) (close-output-port out))
      "a cert served for wrong.example must be refused when connecting to 127.0.0.1"))
   (lambda ()
     (kill-thread server-thread)
     (ssl-close listener)
     (delete-directory/files tmp))))
