#lang racket

(require racket/cmdline
         racket/path
         racket/string)

(define repo-root (simplify-path (current-directory)))
(define pass-count 0)
(define fail-count 0)
(define tesl-files '())

(define (display-path path)
  (path->string (find-relative-path repo-root (simplify-path path))))

(define (tesl->rkt-path tesl-path)
  (define text (path->string tesl-path))
  (unless (string-suffix? text ".tesl")
    (raise-user-error 'example-test-batch "expected a .tesl path, got ~a" text))
  (string->path (string-append (substring text 0 (- (string-length text) 5)) ".rkt")))

(define (replace-all text from to)
  (if (string=? from "")
      text
      (regexp-replace* (regexp (regexp-quote from)) text to)))

(define (rewrite-output text rkt-path tesl-path)
  (define abs-rkt (path->string (simplify-path rkt-path)))
  (define rel-rkt (display-path rkt-path))
  (define abs-tesl (path->string (simplify-path tesl-path)))
  (define rel-tesl (display-path tesl-path))
  (define rewritten (replace-all text abs-rkt abs-tesl))
  (replace-all rewritten rel-rkt rel-tesl))

(define (emit-output-block text)
  (unless (string=? text "")
    (for ([line (in-list (string-split text "\n" #:trim? #f))])
      (unless (string=? line "")
        (printf "       ~a\n" line)))))

(define (test-output-indicates-failure? text)
  (regexp-match? #px"(^|\n)(FAILURE|ERROR)(\n|$)" text))

(define (run-one tesl-file)
  (define tesl-path (simplify-path (path->complete-path (string->path tesl-file) repo-root)))
  (define rkt-path (simplify-path (path->complete-path (tesl->rkt-path tesl-path) repo-root)))
  (define shown-path (display-path tesl-path))
  ; Print arrow without newline so we can overwrite it on success (tty only).
  (when (terminal-port? (current-output-port))
    (printf "  →  ~a" shown-path)
    (flush-output))

  (define combined-output (open-output-string))
  (define caught-exn-message #f)

  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (set! caught-exn-message (exn-message exn)))])
    (parameterize ([current-output-port combined-output]
                   [current-error-port combined-output]
                   [current-namespace (make-base-namespace)])
      (dynamic-require `(submod (file ,(path->string rkt-path)) test) #f)))

  (define rewritten-output (rewrite-output (get-output-string combined-output) rkt-path tesl-path))
  (define rewritten-exn (and caught-exn-message (rewrite-output caught-exn-message rkt-path tesl-path)))
  (define failed? (or rewritten-exn (test-output-indicates-failure? rewritten-output)))
  (define has-output? (or (not (string=? rewritten-output "")) rewritten-exn))

  (if (and (not has-output?) (terminal-port? (current-output-port)))
      ; Clean pass with no output: overwrite the arrow with the result symbol.
      (if failed?
          (begin (set! fail-count (add1 fail-count))
                 (printf "\r  \033[31m✗\033[0m  ~a\n" shown-path))
          (begin (set! pass-count (add1 pass-count))
                 (printf "\r  \033[32m✓\033[0m  ~a\n" shown-path)))
      ; Has output (or not a tty): finish the arrow line, emit output, then result.
      (begin
        (when (terminal-port? (current-output-port))
          (printf "\n"))
        (emit-output-block rewritten-output)
        (when rewritten-exn
          (emit-output-block rewritten-exn))
        (if failed?
            (begin (set! fail-count (add1 fail-count))
                   (printf "  \033[31m✗\033[0m  ~a\n" shown-path))
            (begin (set! pass-count (add1 pass-count))
                   (printf "  \033[32m✓\033[0m  ~a\n" shown-path)))))
  (flush-output))

(command-line
 #:program "example-test-batch"
 #:args files
 (set! tesl-files files))

(for ([tesl-file (in-list tesl-files)])
  (run-one tesl-file))

(printf "TESL_TEST_BATCH_SUMMARY pass=~a fail=~a\n" pass-count fail-count)
(flush-output)
(exit (if (zero? fail-count) 0 1))
