# Email Support

## Goal

Native email/SMTP support similar to queues — not just simple functions, but reliability guarantees via the outbox pattern.

## Design

**Outbox pattern.** `Email.send` writes to a `tesl_email_outbox` table inside the current database transaction. A background worker thread reads pending rows and sends via SMTP. This means:

- If the surrounding transaction rolls back, the email is never sent (atomicity)
- If SMTP fails, the worker retries with exponential backoff (reliability)
- Email is never lost even if the server crashes mid-send (durability)
- The outbox table is a regular (logged) PostgreSQL table, not unlogged — emails must survive crashes

This is the same pattern used for job queues, applied to email delivery.

**Email configuration as a declaration.** SMTP credentials, the backing database, and configuration are declared at the module level as an `email` block. Multiple email configurations can coexist.

**`startEmailWorker` in main.** The background delivery worker must be started explicitly in the `main` function (same pattern as `startWorkers`).

## Syntax

```tesl
email AppEmail {
  database: MainDB
  smtp {
    host: env("SMTP_HOST")
    port: 587
    username: env("SMTP_USER")
    password: env("SMTP_PASS")
    tls: true
  }
}

fn sendWelcomeEmail(to: String, name: String) -> Unit 
  requires [email] =
  Email.send AppEmail {
    to: to
    subject: "Welcome to our service!"
    text: "Hello ${name}, welcome!"
    html: "<h1>Hello ${name}</h1>"
  }

# In main:
startEmailWorker AppEmail
```

## Operations

```tesl
Email.send EmailName {     # -> Unit (fire-and-queue, non-blocking)
  to: String
  subject: String
  text: String              # optional
  html: String              # optional
}

startEmailWorker EmailName  # -> Unit (starts background delivery thread)
```

## Implementation Details

**PostgreSQL schema (regular logged table for durability):**
```sql
CREATE TABLE IF NOT EXISTS tesl_email_outbox (
  id              bigserial     PRIMARY KEY,
  to_address      text          NOT NULL,
  subject         text          NOT NULL,
  text_body       text,
  html_body       text,
  status          text          NOT NULL DEFAULT 'pending',
  attempts        integer       NOT NULL DEFAULT 0,
  created_at      timestamptz   NOT NULL DEFAULT NOW(),
  next_attempt_at timestamptz
)
```

**Worker thread model (two threads):**
- **Poller thread:** Every 5s, queries for `pending` rows with `SKIP LOCKED`, calls SMTP delivery, marks `sent` on success or increments `attempts` + sets `next_attempt_at` on failure (exponential backoff: `5m * 2^attempts`)
- **Cleanup thread:** Every hour, deletes `sent` rows older than 24h

**Retry policy:** After 5 failed attempts, row is marked `dead` and not retried. Dead rows are visible for inspection.

**Racket SMTP:** `net/smtp` (`smtp-send-message`). TLS via `openssl`.

**Transactional sends:** `Email.send` inside a `withTransaction` block is atomic with the surrounding DB writes. If the transaction aborts, no email row is inserted. This prevents sending emails for events that didn't actually happen.

## Capability

The capability is `email` (not name-specific, unlike cache). A module that sends email declares `requires [email]`. If name-specific capability is desired in the future, it can be added as `requires [email AppEmail]`.

## Test target

At least 120 tests across OCaml compiler tests (`compiler/test/test_email.ml`), Racket runtime tests (`tests/email-test.rkt`), and .tesl test files (`tests/email-tests.tesl`).

New lesson: `example/learn/lesson32.tesl`
