package teslrt

import (
	"crypto/tls"
	"fmt"
	"net"
	"net/smtp"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// `email E = Email { … }` and the two operations on it: `Email.send` and `startEmailWorker`.
//
// SENDING IS ENQUEUEING, not delivering. `Email.send` appends to an OUTBOX and returns; the
// worker delivers. That is Racket's shape (its send writes a `tesl_email_outbox` row, or
// appends to an in-memory list when no PostgreSQL runtime is bound) and it is the shape that
// makes a handler's latency independent of the mail server's.
//
// The retry rule is Racket's too: at most 5 attempts, the next one no sooner than
// 5 * 2^attempts minutes after the last — 5, 10, 20, 40, 80. A message that exhausts them is
// DEAD, not silently dropped: it stays in the outbox with that status, so it can be counted.
type EmailBodyTag int

const (
	EmailBodyText EmailBodyTag = iota
	EmailBodyHTML
	EmailBodyRich
)

// EmailBody is the `EmailBody(..)` ADT. It lives in the runtime for the reason Maybe does: it
// crosses module boundaries, and two packages declaring their own would be different Go types.
// The ADT is what makes a body-less email unconstructible — there is no variant for one.
type EmailBody struct {
	Tag  EmailBodyTag
	Text string
	HTML string
}

func TextBody(content string) EmailBody {
	return EmailBody{Tag: EmailBodyText, Text: content}
}

func HTMLBody(content string) EmailBody {
	return EmailBody{Tag: EmailBodyHTML, HTML: content}
}

func RichBody(text, html string) EmailBody {
	return EmailBody{Tag: EmailBodyRich, Text: text, HTML: html}
}

// EmailStatus is where a message is in its life. A DEAD message is kept rather than dropped:
// "we gave up on this one" is information the sender needs.
type EmailStatus int

const (
	EmailPending EmailStatus = iota
	EmailSent
	EmailDead
)

type EmailMessage struct {
	// id is the message's identity inside its outbox — the counterpart of the
	// `tesl_email_outbox` row id. The worker records THIS across the unlocked delivery
	// window, never a slice index: a prune or a reset that runs while a message is on the
	// wire rebuilds the slice, and an index taken before that points at a different message
	// (or past the end) afterwards. Assigned by the outbox; zero means "not yet".
	id         uint64
	claimToken string
	To         string
	Subject    string
	Body       EmailBody
	Status     EmailStatus
	Attempts   int
	// NextAttemptAt is when the worker may try again; zero means "now".
	NextAttemptAt time.Time
	SentAt        time.Time
}

// SmtpSettings is what the declaration's `smtp: SmtpConfig { … }` says.
type SmtpSettings struct {
	Host     string
	Port     int
	Username string
	Password string
	TLS      bool
}

// Outbox is one email declaration: its settings plus the messages waiting on them.
type Outbox struct {
	mutex    sync.Mutex
	settings SmtpSettings
	messages []EmailMessage
	// nextID is the last id handed out; ids start at 1 so a zero is always "unassigned".
	nextID uint64
	// started guards the worker, so a `startEmailWorker` called twice runs one.
	started bool
	// deliver is what the worker calls per message — DeliverEmail in production. A seam
	// rather than a direct call so the runtime's own tests can stand in a delivery that
	// stalls or traps without a network.
	deliver func(SmtpSettings, EmailMessage) error
	// backend is the DURABLE outbox — the `tesl_email_outbox` table — when the declaration
	// names a Postgres-backed database (`NewOutboxOn` in pgstores.go attaches it); nil
	// otherwise. Each operation asks `durable()` and uses the in-memory slice above when the
	// backend is absent or its database is not bound, so a `test` block without
	// `with database` keeps the in-memory outbox and a served program gets the table.
	backend outboxBackend
}

// outboxBackend is what a durable outbox answers. Like queueBackend it speaks this file's
// vocabulary (EmailMessage values, an error per delivery) and names no driver type.
type outboxBackend interface {
	active() bool
	// send stores a pending message. The CRLF check has already run.
	send(message EmailMessage)
	// claimDue takes up to `limit` due pending messages for THIS process, so two instances
	// never deliver the same one; a claimed message another instance crashed on is released
	// after a fixed window.
	claimDue(limit int) []EmailMessage
	// recordOutcome marks a claimed message sent, or counts a failed attempt with backoff
	// and, at emailMaxAttempts, dead.
	recordOutcome(message EmailMessage, err error) bool
	messages() []EmailMessage
	reset()
	prune(keep time.Duration)
}

func NewOutbox(settings SmtpSettings) *Outbox {
	return &Outbox{settings: settings, deliver: DeliverEmail}
}

// durable answers the backend this call runs against, or nil for the in-memory path.
func (outbox *Outbox) durable() outboxBackend {
	if backend := outbox.backend; backend != nil && backend.active() {
		return backend
	}
	return nil
}

// emailClaimBatch is how many due messages one durable delivery pass claims at a time.
const emailClaimBatch = 50

// emailMaxAttempts and the backoff below are tesl/email.rkt's, so a message that fails on one
// backend is retried on the same schedule by the other.
const emailMaxAttempts = 5

func emailRetryDelay(attempts int) time.Duration {
	return time.Duration(5*(1<<attempts)) * time.Minute
}

// emailPollInterval is how often the worker looks for due messages — Racket's 5 seconds.
const emailPollInterval = 5 * time.Second

// ── Deadlines ─────────────────────────────────────────────────────────────────
//
// The spec's rule is that EVERY outbound call has a deadline, so a hung upstream can never pin
// a worker indefinitely. SMTP is an outbound call: a server that accepts the TCP connection and
// never greets would otherwise block the (single) delivery goroutine forever, and with it every
// message behind the stalled one. The knobs are the mail counterpart of the HTTP client's, with
// the same defaults and the same shape (deployment tuning by environment variable, not a
// per-call argument):
//
//	TESL_SMTP_CONNECT_TIMEOUT_MS   10000   reaching the host
//	TESL_SMTP_TIMEOUT_MS           30000   the whole exchange: greeting through QUIT

func smtpConnectTimeoutMs() int { return envPositiveInt("TESL_SMTP_CONNECT_TIMEOUT_MS", 10000) }
func smtpTimeoutMs() int        { return envPositiveInt("TESL_SMTP_TIMEOUT_MS", 30000) }

// HeaderFieldSafe reports whether a header-bound field may be used as it stands. A CR or LF in
// a recipient or a subject would inject arbitrary RFC 2822 headers — Bcc exfiltration,
// spoofing, a forged body — and both fields are user-influenced.
//
// Rejecting beats sanitising: a newline in either field is always a bug or an attack, and
// stripping it would deliver a message the author did not write.
func HeaderFieldSafe(value string) bool {
	return !strings.ContainsAny(value, "\r\n")
}

// SendEmail enqueues one message. The CRLF guard runs HERE, at the boundary where the value
// enters the system, rather than at delivery: a rejected message must never reach the outbox,
// or it would sit there being retried.
func SendEmail(outbox *Outbox, to, subject string, body EmailBody) struct{} {
	for _, field := range []struct{ name, value string }{
		{"recipient", to}, {"subject", subject},
	} {
		if !HeaderFieldSafe(field.value) {
			panic("email " + field.name +
				" contains a CR/LF newline — header injection rejected")
		}
	}
	if backend := outbox.durable(); backend != nil {
		// The insert runs on the calling goroutine's open transaction when there is one
		// (the executor picks it up), which is what makes `Email.send` atomic with the
		// surrounding writes: a rolled-back handler leaves no row and sends no mail.
		backend.send(EmailMessage{To: to, Subject: subject, Body: body, Status: EmailPending})
		return struct{}{}
	}
	outbox.mutex.Lock()
	defer outbox.mutex.Unlock()
	outbox.nextID++
	outbox.messages = append(outbox.messages, EmailMessage{
		id: outbox.nextID, To: to, Subject: subject, Body: body, Status: EmailPending,
	})
	return struct{}{}
}

// StartEmailWorker starts delivery in the background: one goroutine polling every 5 seconds,
// exactly as the Racket worker does, and a second one dropping sent messages older than 24
// hours so a long-lived process does not accumulate them.
//
// Answers Tesl's Unit so the emitted `main` can return it like any other statement.
func StartEmailWorker(outbox *Outbox) struct{} {
	outbox.mutex.Lock()
	already := outbox.started
	outbox.started = true
	outbox.mutex.Unlock()
	if already {
		return struct{}{}
	}
	go runEmailWorker(outbox, emailPollInterval, nil)
	go func() {
		for {
			time.Sleep(time.Hour)
			pruneSentEmailGuarded(outbox, 24*time.Hour)
		}
	}()
	return struct{}{}
}

// runEmailWorker is the delivery loop: every `interval` it tries the due messages once, and
// it keeps going whatever happens inside an iteration. A `stop` of nil never fires, which is
// the production shape; the runtime's tests pass a channel so the loop can be ended.
//
// The recover is per ITERATION and it is what keeps a mail problem a mail problem. This loop
// runs on its own goroutine, and a panic on a goroutine that nothing recovers is fatal for the
// whole process — the HTTP server, the queue workers, everything — not just for the message
// that tripped it. Delivery itself already converts a trap into a failed attempt (see
// deliverPending); this outer guard is for anything else, and it reports rather than swallows,
// so a loop that keeps trapping is visible in the log.
func runEmailWorker(outbox *Outbox, interval time.Duration, stop <-chan struct{}) {
	for {
		select {
		case <-stop:
			return
		case <-time.After(interval):
		}
		runEmailWorkerIteration(outbox)
	}
}

func runEmailWorkerIteration(outbox *Outbox) {
	defer func() {
		if trap := recover(); trap != nil {
			fmt.Fprintf(os.Stderr, "tesl: email worker recovered from a trap: %v\n", trap)
		}
	}()
	deliverPending(outbox)
}

// deliverPending takes every message whose next attempt is due and tries it once.
//
// The lock is NOT held across delivery — a message on the wire must not stall `Email.send` in
// a request handler — and that is why the due messages are remembered by id. Between the
// unlock and the re-lock, PruneSentEmail or ResetOutbox may have rebuilt the slice; a message
// that is no longer there has its result dropped, since there is nothing left to attribute it
// to, and a message that has moved is found where it now is rather than where it was.
func deliverPending(outbox *Outbox) {
	if backend := outbox.durable(); backend != nil {
		deliverClaimed(outbox, backend)
		return
	}
	outbox.mutex.Lock()
	if outbox.settings.Host == "" {
		// No server configured — which is what an unset `SMTP_HOST` means. Messages STAY
		// pending rather than burning their five attempts against a host that does not
		// exist: the configuration is what is missing, not the mail.
		outbox.mutex.Unlock()
		return
	}
	pending := []EmailMessage{}
	for index := range outbox.messages {
		message := &outbox.messages[index]
		if message.Status != EmailPending || time.Now().Before(message.NextAttemptAt) {
			continue
		}
		if message.id == 0 {
			// A message placed in the store without going through SendEmail (the runtime's
			// own tests do this) still needs an identity to be found again by.
			outbox.nextID++
			message.id = outbox.nextID
		}
		pending = append(pending, *message)
	}
	settings := outbox.settings
	deliver := outbox.deliver
	if deliver == nil {
		deliver = DeliverEmail
	}
	outbox.mutex.Unlock()

	for _, message := range pending {
		err := deliverOne(deliver, settings, message)
		outbox.mutex.Lock()
		record := outbox.lookupLocked(message.id)
		if record == nil {
			// Pruned or reset while on the wire: no row to write the outcome to. The failure
			// is still worth a line — it happened — but there is nothing to retry.
			if err != nil {
				fmt.Fprintf(os.Stderr, "tesl: email delivery to %s failed (message no longer in the outbox): %v\n",
					message.To, err)
			}
			outbox.mutex.Unlock()
			continue
		}
		if err == nil {
			record.Status = EmailSent
			record.SentAt = time.Now()
		} else {
			record.Attempts++
			if record.Attempts >= emailMaxAttempts {
				record.Status = EmailDead
			} else {
				record.NextAttemptAt = time.Now().Add(emailRetryDelay(record.Attempts))
			}
			// The failure is reported rather than swallowed: a worker that silently drops
			// every message looks identical to one with nothing to do.
			fmt.Fprintf(os.Stderr, "tesl: email delivery to %s failed (attempt %d): %v\n",
				record.To, record.Attempts, err)
		}
		outbox.mutex.Unlock()
	}
}

// deliverClaimed is deliverPending against the durable outbox: only messages this process
// has CLAIMED are delivered, so several instances polling one table never send the same mail
// twice, and each outcome is written back to the row rather than to a slice. Batches are
// claimed until one comes back short, which bounds a pass to the backlog that was due when
// it started — a claimed message is invisible to the next claim, and a failed one is pushed
// past `now()`, so the loop cannot revisit a message within one pass.
func deliverClaimed(outbox *Outbox, backend outboxBackend) {
	outbox.mutex.Lock()
	settings := outbox.settings
	deliver := outbox.deliver
	outbox.mutex.Unlock()
	if settings.Host == "" {
		// Same rule as the in-memory path: no server configured means the messages wait.
		return
	}
	if deliver == nil {
		deliver = DeliverEmail
	}
	for {
		claimed := backend.claimDue(emailClaimBatch)
		for _, message := range claimed {
			// Durable backends carry their lease identity on the message so recordOutcome
			// can fence this exact attempt. Keep the carrier observable in memory-only
			// emitted runtimes too, where the PostgreSQL implementation is omitted.
			_ = message.claimToken
			err := deliverOne(deliver, settings, message)
			applied := backend.recordOutcome(message, err)
			if applied && err != nil {
				fmt.Fprintf(os.Stderr, "tesl: email delivery to %s failed (attempt %d): %v\n",
					message.To, message.Attempts+1, err)
			}
		}
		if len(claimed) < emailClaimBatch {
			return
		}
	}
}

// lookupLocked finds the message with `id`, or nil when it is gone. Caller holds the mutex;
// the pointer is into the slice and is only valid until the mutex is released.
func (outbox *Outbox) lookupLocked(id uint64) *EmailMessage {
	if id == 0 {
		return nil
	}
	for index := range outbox.messages {
		if outbox.messages[index].id == id {
			return &outbox.messages[index]
		}
	}
	return nil
}

// deliverOne runs one delivery and answers a trap as an ERROR, so a panicking delivery is a
// failed attempt — counted, backed off, eventually dead — and not the end of the worker.
func deliverOne(deliver func(SmtpSettings, EmailMessage) error, settings SmtpSettings, message EmailMessage) (err error) {
	defer func() {
		if trap := recover(); trap != nil {
			err = fmt.Errorf("email delivery trapped: %v", trap)
		}
	}()
	return deliver(settings, message)
}

// DeliverEmail sends ONE message over SMTP, building the same minimal RFC 2822 header the
// Racket runtime builds — From/To/Subject/MIME-Version plus a content type chosen by which
// half of the body is present, so an HTML body arrives as HTML.
func DeliverEmail(settings SmtpSettings, message EmailMessage) error {
	if !HeaderFieldSafe(message.To) || !HeaderFieldSafe(message.Subject) {
		return fmt.Errorf("email header contains a CR/LF newline")
	}
	// Which half is sent is decided by the VARIANT, not by which string happens to be
	// non-empty: an `HtmlBody ""` is still an HTML message, and asking the payload would
	// silently retype it as text.
	contentType := "text/plain; charset=utf-8"
	payload := message.Body.Text
	if message.Body.Tag == EmailBodyHTML || message.Body.Tag == EmailBodyRich {
		contentType = "text/html; charset=utf-8"
		payload = message.Body.HTML
	}
	header := "From: " + settings.Username + "\r\n" +
		"To: " + message.To + "\r\n" +
		"Subject: " + message.Subject + "\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: " + contentType + "\r\n"
	address := net.JoinHostPort(settings.Host, strconv.Itoa(settings.Port))

	// Not `smtp.Dial`: it has no deadline of any kind. The connection is dialed with the
	// connect timeout and then given ONE absolute deadline for the whole exchange, so a server
	// that accepts and never greets, or stalls halfway through DATA, hands back an i/o timeout
	// error — which the worker treats like any other failed attempt. The deadline is on the
	// raw connection, so it also covers the STARTTLS handshake layered over it.
	conn, err := net.DialTimeout("tcp", address, millisDuration(smtpConnectTimeoutMs()))
	if err != nil {
		return err
	}
	if err := conn.SetDeadline(time.Now().Add(millisDuration(smtpTimeoutMs()))); err != nil {
		_ = conn.Close()
		return err
	}
	client, err := smtp.NewClient(conn, settings.Host)
	if err != nil {
		_ = conn.Close()
		return err
	}
	defer func() { _ = client.Close() }()
	if settings.TLS {
		// STARTTLS with the server's own name verified: skipping verification here would
		// make the encryption decorative, since anything on the path could terminate it.
		if err := client.StartTLS(&tls.Config{
			ServerName: settings.Host,
			MinVersion: tls.VersionTLS12,
		}); err != nil {
			return err
		}
	}
	// Authenticate only when the server ASKS for it. A server that advertises no AUTH would
	// reject the command, and failing there would mean a relay that needs no credentials
	// could never be used.
	//
	// `smtp.PlainAuth` refuses to hand over the password on an unencrypted connection
	// (localhost aside). That is a deliberate floor and not worked around here: a credential
	// sent in the clear is readable by everything on the path.
	if supported, _ := client.Extension("AUTH"); supported && settings.Username != "" {
		auth := smtp.PlainAuth("", settings.Username, settings.Password, settings.Host)
		if err := client.Auth(auth); err != nil {
			return err
		}
	}
	if err := client.Mail(settings.Username); err != nil {
		return err
	}
	if err := client.Rcpt(message.To); err != nil {
		return err
	}
	writer, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := writer.Write([]byte(header + "\r\n" + payload)); err != nil {
		_ = writer.Close()
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}
	return client.Quit()
}

// PruneSentEmail drops delivered messages older than `keep`.
// pruneSentEmailGuarded is the background pruner's call: on a durable outbox the prune is a
// statement, and a database that is unreachable at that moment must not unwind this
// goroutine — an unrecovered panic here ended the whole process (the same class as the
// queue worker's store failure). Reported, and retried an hour later.
func pruneSentEmailGuarded(outbox *Outbox, keep time.Duration) {
	defer func() {
		if trap := recover(); trap != nil {
			fmt.Fprintf(os.Stderr, "tesl: email pruner could not reach the outbox store: %v\n", trap)
		}
	}()
	PruneSentEmail(outbox, keep)
}

func PruneSentEmail(outbox *Outbox, keep time.Duration) {
	if backend := outbox.durable(); backend != nil {
		backend.prune(keep)
		return
	}
	outbox.mutex.Lock()
	defer outbox.mutex.Unlock()
	// A FRESH slice rather than `outbox.messages[:0]`: reusing the backing array aliases the
	// store with a value that has already been read out of it, and nilaway reads the reuse as
	// a nil flow into the field.
	kept := make([]EmailMessage, 0, len(outbox.messages))
	for _, message := range outbox.messages {
		if message.Status == EmailSent && time.Since(message.SentAt) > keep {
			continue
		}
		kept = append(kept, message)
	}
	outbox.messages = kept
}

// ── Inspection seams ──────────────────────────────────────────────────────────
//
// Not Tesl-surface names: they exist so the runtime's own tests can assert what was enqueued,
// and so the per-test reset can empty an outbox the way it empties a table.

func OutboxMessages(outbox *Outbox) []EmailMessage {
	if backend := outbox.durable(); backend != nil {
		return backend.messages()
	}
	outbox.mutex.Lock()
	defer outbox.mutex.Unlock()
	out := make([]EmailMessage, len(outbox.messages))
	copy(out, outbox.messages)
	return out
}

func ResetOutbox(outbox *Outbox) {
	if backend := outbox.durable(); backend != nil {
		backend.reset()
		return
	}
	outbox.mutex.Lock()
	defer outbox.mutex.Unlock()
	// An EMPTY slice, not nil: the field is read by every other operation, and a nil there is
	// a nil flow into all of them as far as nilaway is concerned.
	outbox.messages = []EmailMessage{}
}
