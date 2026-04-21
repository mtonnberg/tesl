#lang racket
(require (rename-in racket/base
                    [read racket-read]
                    [read-syntax racket-read-syntax])
         racket/path
         racket/port
         racket/string
         racket/runtime-path)

(provide tesl-read
         tesl-read-syntax
         tesl-get-info)

(define-runtime-path reader-dir ".")

(define repo-root
  (simplify-path (build-path reader-dir ".." "..")))

(define ocaml-binary-path
  (build-path repo-root "compiler" "_build" "default" "bin" "main.exe"))

(define (source-path->path src)
  (cond
    [(path? src) src]
    [(string? src) (string->path src)]
    [else
     (raise-user-error 'tesl-reader
                       "expected a filesystem-backed source path, got ~a"
                       src)]))

(define (compile-module-source src)
  (define full-src (simplify-path (source-path->path src)))
  (unless (file-exists? ocaml-binary-path)
    (raise-user-error
     'tesl-reader
     "Tesl compiler not found — build it with: cd compiler && dune build bin/main.exe"))
  (define-values (proc stdout stdin stderr)
    (subprocess #f #f #f
                (path->string ocaml-binary-path)
                (path->string full-src)))
  (close-output-port stdin)
  (define generated (port->string stdout))
  (define errors    (port->string stderr))
  (subprocess-wait proc)
  (define status (subprocess-status proc))
  (unless (zero? status)
    (raise-user-error
     'tesl-reader
     (string-trim
      (if (string=? (string-trim errors) "")
          "the Tesl compiler exited with an empty error message"
          errors))))
  generated)

(define (generated->module-syntax src generated)
  (parameterize ([read-accept-reader #t])
    (racket-read-syntax src (open-input-string generated))))

(define (consume-input! in)
  (when (input-port? in)
    (port->string in)
    (void)))

(define (tesl-read in)
  (consume-input! in)
  (syntax->datum (tesl-read-syntax (object-name in) #f)))

(define (tesl-read-syntax src in)
  (consume-input! in)
  (generated->module-syntax src (compile-module-source src)))

(define (tesl-get-info _src _mod _line _col _pos)
  (lambda (_key default)
    default))
