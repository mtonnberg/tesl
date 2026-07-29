#lang racket/base

;;; The outbound-HTTP interception SEAM — and deliberately nothing else.
;;;
;;; `tesl/http-client.rkt` is production code and must not depend on the test
;;; framework, so it cannot reach into `dsl/test-support.rkt` (which is required
;;; only from a module's `(module+ test …)` submodule).  This module is the one
;;; neutral place both sides can see: it holds a single parameter and no logic.
;;;
;;;   * PRODUCTION.  Nothing outside the test framework ever installs a hook, so
;;;     `(current-outbound-http-hook)` is #f and the client takes the real
;;;     network path after one `if`.  The stub REGISTRY, the URL matcher, the
;;;     canned responses and the call log all live in `dsl/test-support.rkt`,
;;;     which a production `racket app.rkt` never instantiates — the double does
;;;     not exist in a production build, only this three-line seam does.
;;;
;;;   * TESTS.  `call-with-fresh-memory-db` (dsl/test-support.rkt) wraps every
;;;     `test` / `api-test` / `load-test` body and `parameterize`s this to a
;;;     dispatcher closed over a FRESH registry.  Because it is a parameter, the
;;;     scope is dynamic: it unwinds with the test body, so no stub and no
;;;     recorded call can leak into the next test.
;;;
;;; Hook contract — (hook mode method url headers body) where
;;;   mode    : 'unary (HttpClient.get/post/put/delete) | 'stream (http-post-stream)
;;;   method  : the uppercase HTTP method string
;;;   url     : the full request URL string
;;;   headers : the outbound headers as a list of (name value) 2-element lists
;;;   body    : the request body string, or #f when there is none
;;; and the result is either
;;;   #f                            — no stub is in force; do the real request
;;;   (hash 'status Int 'body String 'headers (list (list name value) …))
;;;                                 — answer with this canned response
;;; or the hook RAISES (an `exn:fail:user` shaped exactly like the client's own
;;; errors) to inject a connection failure or a timeout.

(provide current-outbound-http-hook)

(define current-outbound-http-hook (make-parameter #f))
