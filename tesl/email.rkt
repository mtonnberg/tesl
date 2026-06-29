#lang racket

;;; Email runtime for Tesl — outbox pattern with SMTP delivery.
;;;
;;; Email.send writes to tesl_email_outbox inside the current database
;;; transaction (outbox pattern). A background worker thread (started by
;;; startEmailWorker) polls for pending rows and delivers via SMTP.
;;;
;;; Key design decisions:
;;;   - Email.send is non-blocking: it just inserts a row.
;;;   - If the surrounding transaction rolls back, no row is inserted and
;;;     no email is ever sent (true transactional semantics).
;;;   - Delivery is retried with exponential backoff (5m * 2^attempts).
;;;   - After 5 failed attempts the row is marked 'dead'.
;;;   - Delivered rows are deleted after 24 hours by a cleanup thread.
;;;   - In-memory fallback (no DB) stores emails in a list for tests.
;;;
;;; Capability: "email" (not name-specific, unlike cache).

(require db
         net/smtp
         net/head
         openssl
         racket/format
         racket/match
         racket/string
         (only-in "../dsl/capability.rkt"
                  define-capability
                  require-capabilities!
                  current-capabilities)
         (only-in "../dsl/private/check-runtime.rkt"
                  raw-value
                  named-value?)
         (only-in "../dsl/private/domain-registry.rkt"
                  domain-registry-add!
                  register-background-thread!)
         (only-in "../dsl/sql.rkt"
                  current-database-runtime
                  database-runtime-connection
                  database-runtime-database
                  database-spec-backend
                  database-schema-name)
         (for-syntax racket/base syntax/parse))

(provide
 ;; Capability
 email
 ;; Macro to declare an email configuration
 define-email
 ;; EmailBody ADT constructors (Racket-facing names, used by the emitter)
 TextBody
 HtmlBody
 RichBody
 ;; EmailBody ADT helpers
 make-text-body
 make-html-body
 make-rich-body
 email-body-text
 email-body-html
 ;; Email operations
 send-email!
 start-email-worker!
 ;; Struct accessors (tests)
 (struct-out email-spec))

;; ── Capability ───────────────────────────────────────────────────────────────

(define-capability email)

;; ── Data structures ───────────────────────────────────────────────────────────

(struct email-spec
  (name         ; symbol
   database     ; ignored at runtime (resolved via current-database-runtime)
   smtp-host    ; string
   smtp-port    ; integer
   smtp-username ; string
   smtp-password ; string
   smtp-tls      ; boolean
   ;; In-memory fallback: (mutable (listof hash))
   store)
  #:transparent)

;; ── PostgreSQL helpers ───────────────────────────────────────────────────────

(define (pg-active?)
  (define r (current-database-runtime))
  (and r (eq? (database-spec-backend (database-runtime-database r)) 'postgres)))

(define (pg-conn)
  (database-runtime-connection (current-database-runtime)))

(define (pg-schema)
  (database-schema-name (database-runtime-database (current-database-runtime))))

(define (pg-table schema table)
  (~a "\"" schema "\".\"" table "\""))

;; ── EmailBody ADT ─────────────────────────────────────────────────────────────
;;
;; EmailBody is the three valid body shapes — makes no-body emails impossible
;; to construct at the type level.
;;
;;   TextBody content     — plain text only
;;   HtmlBody content     — HTML only
;;   RichBody text html   — both plain text and HTML

(define (make-text-body content) (list 'TextBody content))
(define (make-html-body content) (list 'HtmlBody content))
(define (make-rich-body text html) (list 'RichBody text html))

;; Racket-name aliases used by the Tesl emitter (EConstructor emits the name verbatim)
(define (TextBody content) (make-text-body content))
(define (HtmlBody content) (make-html-body content))
(define (RichBody text html) (make-rich-body text html))

(define (email-body-text body)
  (match body
    [(list 'TextBody t) t]
    [(list 'RichBody t _) t]
    [_ #f]))

(define (email-body-html body)
  (match body
    [(list 'HtmlBody h) h]
    [(list 'RichBody _ h) h]
    [_ #f]))

;; ── define-email macro ────────────────────────────────────────────────────────
;;
;; Emitted by the OCaml compiler as:
;;   (define-email AppEmail #:database MainDB
;;     #:smtp-host (tesl-env-raw "SMTP_HOST")
;;     #:smtp-port 587
;;     #:smtp-username (tesl-env-raw "SMTP_USER")
;;     #:smtp-password (tesl-env-raw "SMTP_PASS")
;;     #:smtp-tls #t)

(define-syntax (define-email stx)
  (syntax-parse stx
    [(_ name:id
        (~optional (~seq #:database _db:id) #:defaults ([_db #'#f]))
        #:smtp-host host:expr
        #:smtp-port port:expr
        #:smtp-username username:expr
        #:smtp-password password:expr
        #:smtp-tls tls:expr)
     #'(define name
         (let ([spec (email-spec 'name _db
                                 (or host "localhost")
                                 port
                                 (or username "")
                                 (or password "")
                                 tls
                                 (box '()))])
           ;; Register the LIVE email-spec so the DAP debugger can show the outbox
           ;; (pending / sent / dead counts) even when it is not a paused-frame local.
           (domain-registry-add! 'emails spec)
           spec))]))

;; ── send-email! ───────────────────────────────────────────────────────────────
;;
;; Inserts a row into tesl_email_outbox (PostgreSQL) or appends to in-memory
;; store (tests/dev). Non-blocking.

(define (send-email! email-s #:to to #:subject subject #:body body)
  (require-capabilities! (list email))
  (define raw-to (if (named-value? to) (raw-value to) to))
  (define raw-subj (if (named-value? subject) (raw-value subject) subject))
  (define to-str (~a raw-to))
  (define subj-str (~a raw-subj))
  (define text-str (email-body-text body))
  (define html-str (email-body-html body))
  (cond
    [(pg-active?)
     (define schema (pg-schema))
     (query-exec (pg-conn)
       (format "insert into ~a (to_address, subject, text_body, html_body)
                values ($1, $2, $3, $4)"
               (pg-table schema "tesl_email_outbox"))
       to-str subj-str
       (or text-str sql-null)
       (or html-str sql-null))]
    [else
     ;; In-memory fallback
     (define entry (hash 'to to-str 'subject subj-str
                         'text text-str 'html html-str
                         'status 'pending 'attempts 0))
     (set-box! (email-spec-store email-s)
               (append (unbox (email-spec-store email-s)) (list entry)))]))

;; ── SMTP delivery ─────────────────────────────────────────────────────────────

(define (deliver-email! email-s to-str subj-str text-str html-str)
  (define host     (email-spec-smtp-host email-s))
  (define port     (email-spec-smtp-port email-s))
  (define username (email-spec-smtp-username email-s))
  (define password (email-spec-smtp-password email-s))
  (define use-tls? (email-spec-smtp-tls email-s))
  ;; Build a minimal RFC2822 header
  (define header
    (~a "From: " username "\r\n"
        "To: " to-str "\r\n"
        "Subject: " subj-str "\r\n"
        "MIME-Version: 1.0\r\n"
        (if html-str
            (~a "Content-Type: text/html; charset=utf-8\r\n")
            (~a "Content-Type: text/plain; charset=utf-8\r\n"))))
  (define body (or html-str text-str ""))
  ;; smtp-send-message handles STARTTLS if tls? is #t.  net/smtp wants the
  ;; header as a string and the message body as a (listof (or/c string? bytes?))
  ;; — NOT a single combined bytes blob (that fails the arity match and the
  ;; worker silently swallows the exn, so nothing is ever delivered).
  (smtp-send-message
   host
   username
   (list to-str)
   header
   (list body)
   #:port-no port
   #:auth-user username
   #:auth-passwd password
   #:tls-encode (if use-tls?
                    (lambda (p . _)
                      (ports->ssl-ports p p #:mode 'connect
                                         #:encrypt 'tls))
                    #f)))

;; ── Retry backoff ─────────────────────────────────────────────────────────────

;; next_attempt_at = NOW() + (5 * 2^attempts) minutes
(define (retry-interval-minutes attempts)
  (* 5 (expt 2 attempts)))

;; ── Worker threads ────────────────────────────────────────────────────────────

(define MAX-ATTEMPTS 5)

;; Start the background delivery worker for one email-spec.
;; Thread 1 — Poller (every 5s): dequeues pending rows, delivers, marks sent/dead.
;; Thread 2 — Cleanup (every 1h): deletes sent rows older than 24h.
(define (start-email-worker! email-s)
  (require-capabilities! (list email))
  (define db-runtime (current-database-runtime))

  ;; Poller thread
  ;; register-background-thread! records the handle for DAP stop-the-world
  ;; (no-op unless TESL_DEBUG is set); previously fire-and-forget.
  (register-background-thread!
   (thread
   (lambda ()
     (let loop ()
       (sleep 5)
       (with-handlers ([exn:fail? void])
         (parameterize ([current-capabilities (list email)]
                        [current-database-runtime db-runtime])
           (cond
             [(pg-active?)
              (define schema (pg-schema))
              (define conn (pg-conn))
              ;; Stuck-row recovery: if a worker instance crashed mid-delivery,
              ;; rows remain 'processing'. Reset them to 'pending' after 5 minutes.
              (query-exec conn
                (format "update ~a
                         set status = 'pending', updated_at = now()
                         where status = 'processing'
                           and updated_at < now() - interval '5 minutes'"
                        (pg-table schema "tesl_email_outbox")))
              ;; Atomic claim: SELECT + UPDATE in a single CTE so no second
              ;; instance can claim the same row between the two statements.
              (define rows
                (query-rows conn
                  (format "with claimed as (
                             select id from ~a
                             where status = 'pending'
                               and (next_attempt_at is null or next_attempt_at <= now())
                             order by created_at asc
                             limit 10
                             for update skip locked
                           )
                           update ~a
                           set status = 'processing', updated_at = now()
                           from claimed
                           where ~a.id = claimed.id
                           returning ~a.id,
                                     to_address, subject, text_body, html_body, attempts"
                          (pg-table schema "tesl_email_outbox")
                          (pg-table schema "tesl_email_outbox")
                          (pg-table schema "tesl_email_outbox")
                          (pg-table schema "tesl_email_outbox"))))
              (for ([row (in-list rows)])
                (define id       (vector-ref row 0))
                (define to-str   (vector-ref row 1))
                (define subj-str (vector-ref row 2))
                (define text-str (let ([v (vector-ref row 3)])
                                   (if (sql-null? v) #f v)))
                (define html-str (let ([v (vector-ref row 4)])
                                   (if (sql-null? v) #f v)))
                (define attempts (vector-ref row 5))
                (with-handlers
                    ([exn:fail?
                      (lambda (_e)
                        ;; Delivery failed — increment attempts, schedule retry or mark dead
                        (define new-attempts (add1 attempts))
                        (if (>= new-attempts MAX-ATTEMPTS)
                            (query-exec conn
                              (format "update ~a
                                       set status = 'dead', updated_at = now()
                                       where id = $1"
                                      (pg-table schema "tesl_email_outbox"))
                              id)
                            (let ([interval (retry-interval-minutes new-attempts)])
                              (query-exec conn
                                (format "update ~a
                                         set status = 'pending', attempts = $1,
                                             next_attempt_at = now() + ($2 || ' minutes')::interval,
                                             updated_at = now()
                                         where id = $3"
                                        (pg-table schema "tesl_email_outbox"))
                                new-attempts (~a interval) id))))])
                  (deliver-email! email-s to-str subj-str text-str html-str)
                  ;; Success: mark sent
                  (query-exec conn
                    (format "update ~a set status = 'sent', updated_at = now() where id = $1"
                            (pg-table schema "tesl_email_outbox"))
                    id)))]
             [else
              ;; In-memory fallback: try to deliver each pending entry
              (define store (email-spec-store email-s))
              (define entries (unbox store))
              (define updated
                (map (lambda (entry)
                       (if (eq? (hash-ref entry 'status) 'pending)
                           (with-handlers ([exn:fail?
                                            (lambda (_)
                                              (define att (add1 (hash-ref entry 'attempts 0)))
                                              (hash-set (hash-set entry 'attempts att)
                                                        'status
                                                        (if (>= att MAX-ATTEMPTS) 'dead 'pending)))])
                             (deliver-email! email-s
                                             (hash-ref entry 'to "")
                                             (hash-ref entry 'subject "")
                                             (hash-ref entry 'text #f)
                                             (hash-ref entry 'html #f))
                             (hash-set entry 'status 'sent))
                           entry))
                     entries))
              (set-box! store updated)])))
       (loop)))))

  ;; Cleanup thread: delete sent rows older than 24h (every 1h)
  ;; register-background-thread! records the handle for DAP stop-the-world
  ;; (no-op unless TESL_DEBUG is set); previously fire-and-forget.
  (register-background-thread!
   (thread
   (lambda ()
     (let loop ()
       (sleep 3600)
       (with-handlers ([exn:fail? void])
         (parameterize ([current-database-runtime db-runtime])
           (when (pg-active?)
             (define schema (pg-schema))
             (query-exec (pg-conn)
               (format "delete from ~a
                        where status = 'sent'
                          and created_at < now() - interval '24 hours'"
                       (pg-table schema "tesl_email_outbox"))))))
       (loop))))))
