#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/dsl/debug/checkpoint
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  (only-in tesl/tesl/prelude Bool String)
  (only-in tesl/tesl/maybe Something Nothing)
  (only-in tesl/tesl/url Url [Url.parse tesl_import_Url_parse] [Url.host tesl_import_Url_host] [Url.port tesl_import_Url_port] [Url.scheme tesl_import_Url_scheme] [Url.path tesl_import_Url_path] [Url.effectivePort tesl_import_Url_effectivePort] [Url.userInfo tesl_import_Url_userInfo] [Url.toString tesl_import_Url_toString])
  (only-in tesl/tesl/net HostClass Loopback PrivateIp LinkLocal Cgnat Multicast Unspecified PublicIp DomainName InvalidHost [Net.classifyHost tesl_import_Net_classifyHost] [Net.normalizeHost tesl_import_Net_normalizeHost] [Net.isForbiddenHost tesl_import_Net_isForbiddenHost] [Net.isLoopback tesl_import_Net_isLoopback] [Net.isIpv4Mapped tesl_import_Net_isIpv4Mapped] [Net.isIpLiteral tesl_import_Net_isIpLiteral] [Net.isPrivate tesl_import_Net_isPrivate] [Net.isLinkLocal tesl_import_Net_isLinkLocal])
)


(provide )

(define/pow
  (hostOf [raw : String])
  #:returns String
  (thsl-src-control! "tests/url-net-tests.tesl" 43 (list (cons 'raw *raw)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Url_parse *raw))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/url-net-tests.tesl" 44 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([u (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/url-net-tests.tesl" 45 (list (cons 'u u)) (lambda () (raw-value (raw-value (tesl_import_Url_host *u))))))])))))

(define/pow
  (allowed [raw : String])
  #:returns Boolean
  (thsl-src-control! "tests/url-net-tests.tesl" 49 (list (cons 'raw *raw)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Url_parse *raw))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/url-net-tests.tesl" 50 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([u (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/url-net-tests.tesl" 51 (list (cons 'u u)) (lambda () (raw-value (not (raw-value (tesl_import_Net_isForbiddenHost (raw-value (tesl_import_Url_host *u)))))))))])))))

(define/pow
  (label [host : String])
  #:returns String
  (thsl-src-control! "tests/url-net-tests.tesl" 133 (list (cons 'host *host)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_Net_classifyHost *host))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Loopback)) (thsl-src! "tests/url-net-tests.tesl" 134 (list) (lambda () (raw-value "loopback")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'PrivateIp)) (thsl-src! "tests/url-net-tests.tesl" 135 (list) (lambda () (raw-value "private")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'LinkLocal)) (thsl-src! "tests/url-net-tests.tesl" 136 (list) (lambda () (raw-value "link-local")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Cgnat)) (thsl-src! "tests/url-net-tests.tesl" 137 (list) (lambda () (raw-value "cgnat")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Multicast)) (thsl-src! "tests/url-net-tests.tesl" 138 (list) (lambda () (raw-value "multicast")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Unspecified)) (thsl-src! "tests/url-net-tests.tesl" 139 (list) (lambda () (raw-value "unspecified")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'PublicIp)) (thsl-src! "tests/url-net-tests.tesl" 140 (list) (lambda () (raw-value "public")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'DomainName)) (thsl-src! "tests/url-net-tests.tesl" 141 (list) (lambda () (raw-value "name")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'InvalidHost)) (thsl-src! "tests/url-net-tests.tesl" 142 (list) (lambda () (raw-value "invalid")))])))))

(module+ test
  (require rackunit)
  (test-case "port smuggling: the port never rides along inside the host"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 56 (list) (lambda () (hostOf "https://localhost:6379/hook")))) "localhost")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 57 (list) (lambda () (allowed "https://localhost:6379/hook")))) #f)
    ))
  )

  (test-case "case: hostnames are case-insensitive"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 61 (list) (lambda () (hostOf "https://LOCALHOST/hook")))) "localhost")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 62 (list) (lambda () (allowed "https://LOCALHOST/hook")))) #f)
    ))
  )

  (test-case "trailing-dot FQDN resolves identically, so it compares identically"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 66 (list) (lambda () (hostOf "https://localhost./hook")))) "localhost")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 67 (list) (lambda () (allowed "https://localhost./hook")))) #f)
    ))
  )

  (test-case "alternate IP-literal encodings are decoded, not passed through"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 71 (list) (lambda () (hostOf "https://2130706433/hook")))) "127.0.0.1")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 72 (list) (lambda () (allowed "https://2130706433/hook")))) #f)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 73 (list) (lambda () (hostOf "https://[::ffff:127.0.0.1]/hook")))) "127.0.0.1")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 74 (list) (lambda () (allowed "https://[::ffff:127.0.0.1]/hook")))) #f)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 75 (list) (lambda () (raw-value (tesl_import_Net_isIpv4Mapped "[::ffff:127.0.0.1]"))))) #t)
    ))
  )

  (test-case "userinfo is parsed out, so a trusted-looking name cannot pose as the host"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 81 (list) (lambda () (hostOf "https://trusted.example.com@127.0.0.1/x")))) "127.0.0.1")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 82 (list) (lambda () (allowed "https://trusted.example.com@127.0.0.1/x")))) #f)
  (let ([*tesl-case-3 (raw-value 
    (raw-value (tesl_import_Url_parse "https://trusted.example.com@127.0.0.1/x")))]) (cond
    [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 84 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something))
      (let ([u (hash-ref (adt-value-fields *tesl-case-3) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 85 (list) (lambda () (raw-value (tesl_import_Url_userInfo (raw-value u)))))) (raw-value (Something "trusted.example.com")))
      )
    ]
  ))
    ))
  )

  (test-case "components come back canonical and separated"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([*tesl-case-4 (raw-value 
    (raw-value (tesl_import_Url_parse "HTTPS://Example.COM:8443/a/b?x=1#frag")))]) (cond
    [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 92 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something))
      (let ([u (hash-ref (adt-value-fields *tesl-case-4) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 93 (list) (lambda () (raw-value (tesl_import_Url_scheme (raw-value u)))))) "https")
      )
    ]
  ))
  (let ([*tesl-case-5 (raw-value 
    (raw-value (tesl_import_Url_parse "HTTPS://Example.COM:8443/a/b?x=1#frag")))]) (cond
    [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 95 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something))
      (let ([u (hash-ref (adt-value-fields *tesl-case-5) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 96 (list) (lambda () (raw-value (tesl_import_Url_host (raw-value u)))))) "example.com")
      )
    ]
  ))
  (let ([*tesl-case-6 (raw-value 
    (raw-value (tesl_import_Url_parse "HTTPS://Example.COM:8443/a/b?x=1#frag")))]) (cond
    [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 98 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something))
      (let ([u (hash-ref (adt-value-fields *tesl-case-6) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 99 (list) (lambda () (raw-value (tesl_import_Url_port (raw-value u)))))) (raw-value (Something 8443)))
      )
    ]
  ))
  (let ([*tesl-case-7 (raw-value 
    (raw-value (tesl_import_Url_parse "HTTPS://Example.COM:8443/a/b?x=1#frag")))]) (cond
    [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 101 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Something))
      (let ([u (hash-ref (adt-value-fields *tesl-case-7) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 102 (list) (lambda () (raw-value (tesl_import_Url_path (raw-value u)))))) "/a/b")
      )
    ]
  ))
    ))
  )

  (test-case "a written port wins, otherwise the scheme default"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([*tesl-case-8 (raw-value 
    (raw-value (tesl_import_Url_parse "https://example.com/x")))]) (cond
    [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 107 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Something))
      (let ([u (hash-ref (adt-value-fields *tesl-case-8) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 108 (list) (lambda () (raw-value (tesl_import_Url_port (raw-value u)))))) Nothing)
      )
    ]
  ))
  (let ([*tesl-case-9 (raw-value 
    (raw-value (tesl_import_Url_parse "https://example.com/x")))]) (cond
    [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 110 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something))
      (let ([u (hash-ref (adt-value-fields *tesl-case-9) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 111 (list) (lambda () (raw-value (tesl_import_Url_effectivePort (raw-value u)))))) (raw-value (Something 443)))
      )
    ]
  ))
    ))
  )

  (test-case "re-serializing yields the string that was checked"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([*tesl-case-10 (raw-value 
    (raw-value (tesl_import_Url_parse "https://LOCALHOST.:8443/a?q=1")))]) (cond
    [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 116 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Something))
      (let ([u (hash-ref (adt-value-fields *tesl-case-10) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 117 (list) (lambda () (raw-value (tesl_import_Url_toString (raw-value u)))))) "https://localhost:8443/a?q=1")
      )
    ]
  ))
    ))
  )

  (test-case "ambiguous or unsafe-to-guess URLs are refused outright"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 121 (list) (lambda () (raw-value (tesl_import_Url_parse "mailto:someone@example.com"))))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 122 (list) (lambda () (raw-value (tesl_import_Url_parse "https://exa mple.com/"))))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 123 (list) (lambda () (raw-value (tesl_import_Url_parse "https://host:/p"))))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 124 (list) (lambda () (raw-value (tesl_import_Url_parse "https://host:70000/"))))) Nothing)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 125 (list) (lambda () (raw-value (tesl_import_Url_parse "https://a:1:2/p"))))) Nothing)
    ))
  )

  (test-case "every range classifies, in every spelling"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 145 (list) (lambda () (label "127.0.0.1")))) "loopback")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 146 (list) (lambda () (label "LOCALHOST.")))) "loopback")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 147 (list) (lambda () (label "0177.0.0.1")))) "loopback")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 148 (list) (lambda () (label "[::1]")))) "loopback")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 149 (list) (lambda () (label "10.1.2.3")))) "private")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 150 (list) (lambda () (label "[fd12:3456::1]")))) "private")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 151 (list) (lambda () (label "169.254.169.254")))) "link-local")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 152 (list) (lambda () (label "[::ffff:a9fe:a9fe]")))) "link-local")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 153 (list) (lambda () (label "100.64.0.1")))) "cgnat")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 154 (list) (lambda () (label "224.0.0.1")))) "multicast")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 155 (list) (lambda () (label "0.0.0.0")))) "unspecified")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 156 (list) (lambda () (label "8.8.8.8")))) "public")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 157 (list) (lambda () (label "[2606:4700:4700::1111]")))) "public")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 158 (list) (lambda () (label "example.com")))) "name")
    ))
  )

  (test-case "unvouchable hosts fail closed rather than reading as a name"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 162 (list) (lambda () (label "exa mple.com")))) "invalid")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 163 (list) (lambda () (label "999.999.999.999")))) "invalid")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 164 (list) (lambda () (label "")))) "invalid")
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 165 (list) (lambda () (raw-value (tesl_import_Net_isForbiddenHost "999.999.999.999"))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 166 (list) (lambda () (raw-value (tesl_import_Net_normalizeHost "exa mple.com"))))) Nothing)
    ))
  )

  (test-case "normalizeHost is what you compare and store"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 170 (list) (lambda () (raw-value (tesl_import_Net_normalizeHost "LOCALHOST."))))) (raw-value (Something "localhost")))
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 171 (list) (lambda () (raw-value (tesl_import_Net_normalizeHost "2130706433"))))) (raw-value (Something "127.0.0.1")))
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 172 (list) (lambda () (raw-value (tesl_import_Net_normalizeHost "[::FFFF:127.0.0.1]"))))) (raw-value (Something "127.0.0.1")))
    ))
  )

  (test-case "the predicates agree with the classification"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 176 (list) (lambda () (raw-value (tesl_import_Net_isLoopback "2130706433"))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 177 (list) (lambda () (raw-value (tesl_import_Net_isPrivate "192.168.1.1"))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 178 (list) (lambda () (raw-value (tesl_import_Net_isLinkLocal "169.254.169.254"))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 179 (list) (lambda () (raw-value (tesl_import_Net_isIpLiteral "8.8.8.8"))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 180 (list) (lambda () (raw-value (tesl_import_Net_isIpLiteral "example.com"))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 181 (list) (lambda () (raw-value (tesl_import_Net_isLoopback "localhost"))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 182 (list) (lambda () (raw-value (tesl_import_Net_isIpLiteral "localhost"))))) #f)
    ))
  )

  (test-case "a plain public URL is allowed"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 186 (list) (lambda () (allowed "https://api.example.com/webhook")))) #t)
  (check-equal? (raw-value (thsl-src! "tests/url-net-tests.tesl" 187 (list) (lambda () (hostOf "https://api.example.com/webhook")))) "api.example.com")
    ))
  )

)
