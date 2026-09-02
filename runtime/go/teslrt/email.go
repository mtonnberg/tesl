package teslrt

import (
	"crypto/tls"
	"fmt"
	"net/smtp"
	"os"
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
	To       string
	Subject  string
	Body     EmailBody
	Status   EmailStatus
	Attempts int
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
	// started guards the worker, so a `startEmailWorker` called twice runs one.
	started bool
}

func NewOutbox(settings SmtpSettings) *Outbox {
	return &Outbox{settings: settings}
}

// emailMaxAttempts and the backoff below are tesl/email.rkt's, so a message that fails on one
// backend is retried on the same schedule by the other.
const emailMaxAttempts = 5

func emailRetryDelay(attempts int) time.Duration {
	return time.Duration(5*(1<<attempts)) * time.Minute
}

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
	outbox.mutex.Lock()
	defer outbox.mutex.Unlock()
	outbox.messages = append(outbox.messages, EmailMessage{
		To: to, Subject: subject, Body: body, Status: EmailPending,
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
	go func() {
		for {
			time.Sleep(5 * time.Second)
			deliverPending(outbox)
		}
	}()
	go func() {
		for {
			time.Sleep(time.Hour)
			PruneSentEmail(outbox, 24*time.Hour)
		}
	}()
	return struct{}{}
}

// deliverPending takes every message whose next attempt is due and tries it once.
func deliverPending(outbox *Outbox) {
	outbox.mutex.Lock()
	if outbox.settings.Host == "" {
		// No server configured — which is what an unset `SMTP_HOST` means. Messages STAY
		// pending rather than burning their five attempts against a host that does not
		// exist: the configuration is what is missing, not the mail.
		outbox.mutex.Unlock()
		return
	}
	due := []int{}
	for index, message := range outbox.messages {
		if message.Status == EmailPending && !time.Now().Before(message.NextAttemptAt) {
			due = append(due, index)
		}
	}
	settings := outbox.settings
	pending := make([]EmailMessage, len(due))
	for slot, index := range due {
		pending[slot] = outbox.messages[index]
	}
	outbox.mutex.Unlock()

	for slot, message := range pending {
		err := DeliverEmail(settings, message)
		outbox.mutex.Lock()
		index := due[slot]
		record := &outbox.messages[index]
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
	address := fmt.Sprintf("%s:%d", settings.Host, settings.Port)

	client, err := smtp.Dial(address)
	if err != nil {
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
func PruneSentEmail(outbox *Outbox, keep time.Duration) {
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
	outbox.mutex.Lock()
	defer outbox.mutex.Unlock()
	out := make([]EmailMessage, len(outbox.messages))
	copy(out, outbox.messages)
	return out
}

func ResetOutbox(outbox *Outbox) {
	outbox.mutex.Lock()
	defer outbox.mutex.Unlock()
	// An EMPTY slice, not nil: the field is read by every other operation, and a nil there is
	// a nil flow into all of them as far as nilaway is concerned.
	outbox.messages = []EmailMessage{}
}
