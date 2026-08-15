package teslrt

import (
	"bufio"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

func testSettings(host string, port int) SmtpSettings {
	return SmtpSettings{Host: host, Port: port, Username: "sender@example.com", TLS: false}
}

func TestSendEmailEnqueuesPending(t *testing.T) {
	outbox := NewOutbox(testSettings("", 0))
	SendEmail(outbox, "to@example.com", "Hello", TextBody("body"))
	messages := OutboxMessages(outbox)
	if len(messages) != 1 {
		t.Fatalf("the outbox holds %d messages", len(messages))
	}
	got := messages[0]
	if got.To != "to@example.com" || got.Subject != "Hello" || got.Body.Text != "body" {
		t.Fatalf("enqueued %+v", got)
	}
	if got.Status != EmailPending || got.Attempts != 0 {
		t.Fatalf("a fresh message is %+v, not an untried pending one", got)
	}
}

// Sending is ENQUEUEING: the call returns without touching the network, which is why an
// outbox with an unreachable server still accepts messages.
func TestSendEmailKeepsOrder(t *testing.T) {
	outbox := NewOutbox(testSettings("", 0))
	for _, subject := range []string{"first", "second", "third"} {
		SendEmail(outbox, "to@example.com", subject, TextBody("b"))
	}
	messages := OutboxMessages(outbox)
	for index, want := range []string{"first", "second", "third"} {
		if messages[index].Subject != want {
			t.Fatalf("message %d is %q, want %q", index, messages[index].Subject, want)
		}
	}
}

func TestSendEmailRejectsHeaderInjection(t *testing.T) {
	for _, injection := range []struct {
		name, to, subject string
	}{
		{"newline in recipient", "to@example.com\nBcc: attacker@evil.test", "Hi"},
		{"carriage return in recipient", "to@example.com\rBcc: attacker@evil.test", "Hi"},
		{"newline in subject", "to@example.com", "Hi\nBcc: attacker@evil.test"},
		{"CRLF in subject", "to@example.com", "Hi\r\nContent-Type: text/html"},
	} {
		t.Run(injection.name, func(t *testing.T) {
			outbox := NewOutbox(testSettings("", 0))
			defer func() {
				if recover() == nil {
					t.Fatal("the injection was accepted")
				}
				// The rejected message must not be in the outbox: an accepted-then-failing
				// message would sit there being retried.
				if messages := OutboxMessages(outbox); len(messages) != 0 {
					t.Fatalf("a rejected message was enqueued: %+v", messages)
				}
			}()
			SendEmail(outbox, injection.to, injection.subject, TextBody("b"))
		})
	}
}

func TestHeaderFieldSafe(t *testing.T) {
	for _, safe := range []string{"to@example.com", "Subject with spaces", "ünïcode", ""} {
		if !HeaderFieldSafe(safe) {
			t.Fatalf("%q was rejected", safe)
		}
	}
	for _, unsafe := range []string{"a\nb", "a\rb", "a\r\nb", "\n", "trailing\n"} {
		if HeaderFieldSafe(unsafe) {
			t.Fatalf("%q was accepted", unsafe)
		}
	}
}

func TestEmailBodyVariants(t *testing.T) {
	text := TextBody("plain")
	if text.Tag != EmailBodyText || text.Text != "plain" || text.HTML != "" {
		t.Fatalf("TextBody is %+v", text)
	}
	html := HTMLBody("<b>x</b>")
	if html.Tag != EmailBodyHTML || html.HTML != "<b>x</b>" || html.Text != "" {
		t.Fatalf("HtmlBody is %+v", html)
	}
	rich := RichBody("plain", "<b>x</b>")
	if rich.Tag != EmailBodyRich || rich.Text != "plain" || rich.HTML != "<b>x</b>" {
		t.Fatalf("RichBody is %+v", rich)
	}
}

// ── A fake SMTP server ────────────────────────────────────────────────────────
//
// Enough of RFC 5321 to accept one message and hand back what it received. The delivery
// path is where the header is BUILT, so asserting on the bytes is the only way to know an
// HTML body arrives as HTML rather than as text with tags in it.

type fakeSMTP struct {
	listener net.Listener
	// received is the DATA payload of the last message, header included.
	received chan string
	// advertiseAuth turns the AUTH extension on, which is what makes the client offer
	// credentials at all.
	advertiseAuth bool
}

func startFakeSMTP(t *testing.T, advertiseAuth bool) *fakeSMTP {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := &fakeSMTP{listener: listener, received: make(chan string, 4), advertiseAuth: advertiseAuth}
	go server.serve()
	t.Cleanup(func() { _ = listener.Close() })
	return server
}

func (server *fakeSMTP) addressParts(t *testing.T) (string, int) {
	t.Helper()
	host, port, err := net.SplitHostPort(server.listener.Addr().String())
	if err != nil {
		t.Fatalf("address: %v", err)
	}
	number := 0
	if _, err := fmt.Sscanf(port, "%d", &number); err != nil {
		t.Fatalf("port: %v", err)
	}
	return host, number
}

func (server *fakeSMTP) serve() {
	for {
		conn, err := server.listener.Accept()
		if err != nil {
			return
		}
		go server.handle(conn)
	}
}

func (server *fakeSMTP) handle(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	reader := bufio.NewReader(conn)
	write := func(line string) { _, _ = conn.Write([]byte(line + "\r\n")) }
	write("220 fake ESMTP")
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return
		}
		command := strings.ToUpper(strings.TrimSpace(line))
		switch {
		case strings.HasPrefix(command, "EHLO"):
			if server.advertiseAuth {
				write("250-fake")
				write("250 AUTH PLAIN")
			} else {
				write("250 fake")
			}
		case strings.HasPrefix(command, "HELO"):
			write("250 fake")
		case strings.HasPrefix(command, "AUTH"):
			write("235 accepted")
		case strings.HasPrefix(command, "MAIL"), strings.HasPrefix(command, "RCPT"):
			write("250 ok")
		case strings.HasPrefix(command, "STARTTLS"):
			// Not supported by this server: the point of the test that reaches here is that
			// the client REFUSES to continue in the clear.
			write("502 STARTTLS not available")
		case strings.HasPrefix(command, "DATA"):
			write("354 send it")
			var payload strings.Builder
			for {
				dataLine, err := reader.ReadString('\n')
				if err != nil {
					return
				}
				if dataLine == ".\r\n" {
					break
				}
				payload.WriteString(dataLine)
			}
			server.received <- payload.String()
			write("250 queued")
		case strings.HasPrefix(command, "QUIT"):
			write("221 bye")
			return
		default:
			write("250 ok")
		}
	}
}

func (server *fakeSMTP) awaitMessage(t *testing.T) string {
	t.Helper()
	select {
	case payload := <-server.received:
		return payload
	case <-time.After(5 * time.Second):
		t.Fatal("no message reached the server")
		return ""
	}
}

func TestDeliverEmailSendsATextMessage(t *testing.T) {
	server := startFakeSMTP(t, false)
	host, port := server.addressParts(t)
	settings := testSettings(host, port)
	message := EmailMessage{To: "to@example.com", Subject: "Plain", Body: TextBody("hello there")}
	if err := DeliverEmail(settings, message); err != nil {
		t.Fatalf("delivery failed: %v", err)
	}
	payload := server.awaitMessage(t)
	for _, want := range []string{
		"From: sender@example.com", "To: to@example.com", "Subject: Plain",
		"MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "hello there",
	} {
		if !strings.Contains(payload, want) {
			t.Fatalf("the message is missing %q:\n%s", want, payload)
		}
	}
}

// An HTML body arrives as HTML — the content type follows the VARIANT.
func TestDeliverEmailSendsHTMLForAnHTMLBody(t *testing.T) {
	server := startFakeSMTP(t, false)
	host, port := server.addressParts(t)
	message := EmailMessage{To: "to@example.com", Subject: "Rich", Body: RichBody("plain", "<h1>rich</h1>")}
	if err := DeliverEmail(testSettings(host, port), message); err != nil {
		t.Fatalf("delivery failed: %v", err)
	}
	payload := server.awaitMessage(t)
	if !strings.Contains(payload, "Content-Type: text/html; charset=utf-8") {
		t.Fatalf("a rich body was sent as text:\n%s", payload)
	}
	if !strings.Contains(payload, "<h1>rich</h1>") {
		t.Fatalf("the HTML half was not sent:\n%s", payload)
	}
}

// An EMPTY HTML body is still an HTML message: the variant decides, not which string is
// non-empty.
func TestDeliverEmailKeepsAnEmptyHTMLBodyHTML(t *testing.T) {
	server := startFakeSMTP(t, false)
	host, port := server.addressParts(t)
	message := EmailMessage{To: "to@example.com", Subject: "Empty", Body: HTMLBody("")}
	if err := DeliverEmail(testSettings(host, port), message); err != nil {
		t.Fatalf("delivery failed: %v", err)
	}
	if payload := server.awaitMessage(t); !strings.Contains(payload, "text/html") {
		t.Fatalf("an empty HTML body was retyped as text:\n%s", payload)
	}
}

func TestDeliverEmailAuthenticatesWhenTheServerAsks(t *testing.T) {
	server := startFakeSMTP(t, true)
	host, port := server.addressParts(t)
	settings := testSettings(host, port)
	settings.Password = "secret"
	// PlainAuth allows an unencrypted connection to a LOCALHOST server only, which is what
	// this is; against a remote host it would refuse, and that refusal is deliberate.
	if err := DeliverEmail(settings, EmailMessage{
		To: "to@example.com", Subject: "Auth", Body: TextBody("b"),
	}); err != nil {
		t.Fatalf("delivery failed: %v", err)
	}
	server.awaitMessage(t)
}

// A server that cannot do STARTTLS while the declaration says `tls: true` is a FAILURE, not
// a quiet downgrade to plaintext.
func TestDeliverEmailRefusesToDowngradeFromTLS(t *testing.T) {
	server := startFakeSMTP(t, false)
	host, port := server.addressParts(t)
	settings := testSettings(host, port)
	settings.TLS = true
	err := DeliverEmail(settings, EmailMessage{To: "to@example.com", Subject: "S", Body: TextBody("b")})
	if err == nil {
		t.Fatal("the connection continued in the clear")
	}
}

func TestDeliverEmailRejectsHeaderInjection(t *testing.T) {
	server := startFakeSMTP(t, false)
	host, port := server.addressParts(t)
	err := DeliverEmail(testSettings(host, port), EmailMessage{
		To: "to@example.com\nBcc: attacker@evil.test", Subject: "S", Body: TextBody("b"),
	})
	if err == nil {
		t.Fatal("a forged header was delivered")
	}
}

func TestDeliverEmailReportsAnUnreachableServer(t *testing.T) {
	// Port 1 on the loopback interface: nothing listens there.
	err := DeliverEmail(testSettings("127.0.0.1", 1), EmailMessage{
		To: "to@example.com", Subject: "S", Body: TextBody("b"),
	})
	if err == nil {
		t.Fatal("delivery to a closed port succeeded")
	}
}

// ── The worker's rules ────────────────────────────────────────────────────────

func TestDeliverPendingMarksSent(t *testing.T) {
	server := startFakeSMTP(t, false)
	host, port := server.addressParts(t)
	outbox := NewOutbox(testSettings(host, port))
	SendEmail(outbox, "to@example.com", "S", TextBody("b"))
	deliverPending(outbox)
	server.awaitMessage(t)
	messages := OutboxMessages(outbox)
	if messages[0].Status != EmailSent {
		t.Fatalf("a delivered message is %+v", messages[0])
	}
	// A sent message is not delivered twice.
	deliverPending(outbox)
	select {
	case payload := <-server.received:
		t.Fatalf("the message was sent again:\n%s", payload)
	case <-time.After(200 * time.Millisecond):
	}
}

func TestDeliverPendingBacksOffThenGivesUp(t *testing.T) {
	outbox := NewOutbox(testSettings("127.0.0.1", 1))
	SendEmail(outbox, "to@example.com", "S", TextBody("b"))
	for attempt := 1; attempt < emailMaxAttempts; attempt++ {
		deliverPending(outbox)
		message := OutboxMessages(outbox)[0]
		if message.Attempts != attempt {
			t.Fatalf("after %d rounds the message has %d attempts", attempt, message.Attempts)
		}
		if message.Status != EmailPending {
			t.Fatalf("the message gave up after %d attempts", attempt)
		}
		wait := time.Until(message.NextAttemptAt)
		if want := emailRetryDelay(attempt); wait > want || wait < want-time.Minute {
			t.Fatalf("attempt %d waits %v, want about %v", attempt, wait, want)
		}
		// A message whose next attempt is in the future is SKIPPED, so the backoff has to be
		// cleared for the next round — which is itself the rule under test.
		before := OutboxMessages(outbox)[0].Attempts
		deliverPending(outbox)
		if after := OutboxMessages(outbox)[0].Attempts; after != before {
			t.Fatalf("a backed-off message was retried early (%d -> %d)", before, after)
		}
		outbox.mutex.Lock()
		outbox.messages[0].NextAttemptAt = time.Time{}
		outbox.mutex.Unlock()
	}
	deliverPending(outbox)
	final := OutboxMessages(outbox)[0]
	if final.Status != EmailDead {
		t.Fatalf("after %d attempts the message is %+v", emailMaxAttempts, final)
	}
	// A dead message is KEPT, and not retried.
	deliverPending(outbox)
	if again := OutboxMessages(outbox)[0]; again.Attempts != emailMaxAttempts {
		t.Fatalf("a dead message was retried: %+v", again)
	}
}

func TestEmailRetryDelayDoubles(t *testing.T) {
	for attempts, want := range map[int]time.Duration{
		0: 5 * time.Minute, 1: 10 * time.Minute, 2: 20 * time.Minute,
		3: 40 * time.Minute, 4: 80 * time.Minute,
	} {
		if got := emailRetryDelay(attempts); got != want {
			t.Fatalf("after %d attempts the delay is %v, want %v", attempts, got, want)
		}
	}
}

// An unset SMTP_HOST is a missing CONFIGURATION, not a delivery failure: the messages wait
// rather than burning their attempts against a host that does not exist.
func TestDeliverPendingLeavesMessagesAloneWithNoHost(t *testing.T) {
	outbox := NewOutbox(testSettings("", 0))
	SendEmail(outbox, "to@example.com", "S", TextBody("b"))
	deliverPending(outbox)
	message := OutboxMessages(outbox)[0]
	if message.Status != EmailPending || message.Attempts != 0 {
		t.Fatalf("a message with no configured server is %+v", message)
	}
}

func TestPruneSentEmailKeepsWhatMatters(t *testing.T) {
	outbox := NewOutbox(testSettings("", 0))
	outbox.messages = []EmailMessage{
		{To: "old@example.com", Status: EmailSent, SentAt: time.Now().Add(-48 * time.Hour)},
		{To: "recent@example.com", Status: EmailSent, SentAt: time.Now()},
		{To: "pending@example.com", Status: EmailPending},
		{To: "dead@example.com", Status: EmailDead},
	}
	PruneSentEmail(outbox, 24*time.Hour)
	kept := []string{}
	for _, message := range OutboxMessages(outbox) {
		kept = append(kept, message.To)
	}
	want := []string{"recent@example.com", "pending@example.com", "dead@example.com"}
	if strings.Join(kept, ",") != strings.Join(want, ",") {
		t.Fatalf("the outbox kept %v, want %v", kept, want)
	}
}

func TestStartEmailWorkerStartsOnce(t *testing.T) {
	outbox := NewOutbox(testSettings("", 0))
	StartEmailWorker(outbox)
	StartEmailWorker(outbox)
	outbox.mutex.Lock()
	defer outbox.mutex.Unlock()
	if !outbox.started {
		t.Fatal("the worker did not start")
	}
}

// The returned slice is a COPY: a caller reading the outbox cannot mutate the store.
func TestOutboxMessagesIsACopy(t *testing.T) {
	outbox := NewOutbox(testSettings("", 0))
	SendEmail(outbox, "to@example.com", "S", TextBody("b"))
	messages := OutboxMessages(outbox)
	messages[0].To = "elsewhere@example.com"
	if again := OutboxMessages(outbox); again[0].To != "to@example.com" {
		t.Fatalf("the store was mutated through the copy: %+v", again[0])
	}
}

func TestResetOutboxEmptiesTheStore(t *testing.T) {
	outbox := NewOutbox(testSettings("", 0))
	SendEmail(outbox, "to@example.com", "S", TextBody("b"))
	ResetOutbox(outbox)
	if messages := OutboxMessages(outbox); len(messages) != 0 {
		t.Fatalf("the outbox still holds %+v", messages)
	}
	// Usable afterwards: the reset drops the messages, it does not poison the outbox.
	SendEmail(outbox, "to@example.com", "S", TextBody("b"))
	if len(OutboxMessages(outbox)) != 1 {
		t.Fatal("the outbox was unusable after a reset")
	}
}

// One outbox, many goroutines: an emitted program sends from concurrent request handlers.
// Run with -race, which the gate does.
func TestOutboxIsSafeUnderConcurrentUse(t *testing.T) {
	outbox := NewOutbox(testSettings("", 0))
	var waiting sync.WaitGroup
	for worker := range 8 {
		waiting.Add(1)
		go func() {
			defer waiting.Done()
			for index := range 32 {
				SendEmail(outbox, fmt.Sprintf("w%d-%d@example.com", worker, index), "S", TextBody("b"))
				OutboxMessages(outbox)
				deliverPending(outbox)
			}
		}()
	}
	waiting.Wait()
	if got := len(OutboxMessages(outbox)); got != 8*32 {
		t.Fatalf("the outbox holds %d messages, want %d", got, 8*32)
	}
}
