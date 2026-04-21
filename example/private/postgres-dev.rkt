#lang racket

(require racket/string)

(provide default-postgres-host
         default-postgres-port
         default-postgres-database
         default-postgres-user
         resolve-postgres-host
         resolve-postgres-port
         resolve-postgres-database
         resolve-postgres-user
         resolve-postgres-password
         resolve-postgres-socket)

(define default-postgres-host "127.0.0.1")
(define default-postgres-port 55432)
(define default-postgres-database "tesl")
(define default-postgres-user "tesl")

(define (empty-string->false value)
  (if (and (string? value) (string=? (string-trim value) ""))
      #f
      value))

(define (parse-port raw who)
  (define maybe-port (and raw (string->number raw)))
  (unless (and maybe-port
               (integer? maybe-port)
               (<= 1 maybe-port 65535))
    (raise-user-error 'postgres-dev
                      (format "invalid ~a value ~a; expected an integer between 1 and 65535"
                              who
                              raw)))
  maybe-port)

(define (resolve-postgres-host)
  (or (empty-string->false (getenv "TESL_POSTGRES_HOST"))
      default-postgres-host))

(define (resolve-postgres-port)
  (define env-port (empty-string->false (getenv "TESL_POSTGRES_PORT")))
  (if env-port
      (parse-port env-port "TESL_POSTGRES_PORT")
      default-postgres-port))

(define (resolve-postgres-database)
  (or (empty-string->false (getenv "TESL_POSTGRES_DATABASE"))
      default-postgres-database))

(define (resolve-postgres-user)
  (or (empty-string->false (getenv "TESL_POSTGRES_USER"))
      default-postgres-user))

(define (resolve-postgres-password)
  (empty-string->false (getenv "TESL_POSTGRES_PASSWORD")))

(define (resolve-postgres-socket)
  (empty-string->false (getenv "TESL_POSTGRES_SOCKET")))
