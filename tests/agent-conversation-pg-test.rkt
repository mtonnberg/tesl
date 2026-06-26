#lang racket

;;; AI Tier-0 Wave 2b — conversation persistence on a REAL (temporary) PostgreSQL.
;;;
;;; Proves the developer-owned persistence path: a multi-turn conversation's
;;; history (serialized by `conversationJson`) is stored in the developer's OWN
;;; entity, reloaded with `conversationFrom`, and the reloaded thread feeds the
;;; NEXT turn — i.e. turn 2 (after a store/reload round-trip) still sees turn 1.
;;;
;;; The agent runtime is NOT coupled to any entity schema: the test owns the
;;; `ConversationRow` entity and does the insert/select itself. Deterministic
;;; (mock provider, no network). Skips cleanly when initdb/pg_ctl are absent.

(require db
         rackunit
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/sql.rkt"
         "../dsl/types.rkt"
         "../tesl/agent.rkt"
         "private/postgres-test-support.rkt")

;;; The developer's OWN entity for persisting a conversation thread.
(define-entity ConversationRow
  #:table conversation_rows
  #:primary-key id
  [Id id : String]
  [History history : String])

(define (run-conversation-persistence-tests cfg)
  (define host (hash-ref cfg 'host))
  (define port (hash-ref cfg 'port))
  (define db-name (hash-ref cfg 'database))
  (define user (hash-ref cfg 'user))

  (define-database ConvDb
    #:backend postgres
    #:database db-name
    #:user user
    #:server host
    #:port port
    #:schema agent_conv_test
    #:entities ConversationRow)

  ;; The mock scripts two distinct replies — one per turn.
  (define agent
    (defineAgent (mockProvider (list "Reply about turn one"
                                     "Reply about turn two"))
                 "You are a persistence-test bot."
                 128))

  (call-with-database
   ConvDb
   (lambda ()
     (with-capabilities (aiProvider db-write db-read)

       ;; ── Turn 1: converse, then PERSIST the serialized history. ──────────────
       (define turn1 (converse (newConversation agent) "first user question"))
       (define conv1 (turnConversation turn1))
       (check-equal? (replyText (turnReply turn1)) "Reply about turn one")
       (check-equal? (conversationLength conv1) 2)

       (define history-json (conversationJson conv1))
       (insert-one! ConversationRow
                    (hash 'id "conv-1" 'history history-json))

       ;; ── Reload from PG (a fresh process would do exactly this). ─────────────
       (define row
         (select-one (from ConversationRow)
                     (where (==. (ConversationRow-id) "conv-1"))))
       (check-true (named-value? row))
       (define stored-history (hash-ref (raw-value row) 'history))

       ;; The persisted history carries turn 1's user prompt AND assistant reply.
       (check-true (string-contains? stored-history "first user question"))
       (check-true (string-contains? stored-history "Reply about turn one"))

       ;; ── Continue the RELOADED thread — turn 2 must still see turn 1. ────────
       (define reloaded (conversationFrom agent stored-history))
       (check-equal? (conversationLength reloaded) 2)

       (define turn2 (converse reloaded "second user question"))
       (define conv2 (turnConversation turn2))
       (check-equal? (replyText (turnReply turn2)) "Reply about turn two")
       ;; History accumulated across the store/reload boundary: 2 (turn1) + 2.
       (check-equal? (conversationLength conv2) 4)

       ;; The final transcript fed forward carries BOTH turns' content — proving
       ;; the reloaded history threaded into turn 2.
       (define final-history (conversationJson conv2))
       (check-true (string-contains? final-history "first user question"))
       (check-true (string-contains? final-history "Reply about turn one"))
       (check-true (string-contains? final-history "second user question"))))))

(define (run-all)
  (if (not (postgres-tooling-available?))
      (displayln "Skipping agent-conversation-pg-test.rkt because initdb/pg_ctl are not available")
      (call-with-temporary-postgres run-conversation-persistence-tests)))

(run-all)
