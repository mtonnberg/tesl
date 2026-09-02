package teslrt

import (
	"errors"
	"net"
	"testing"
	"time"
)

// ── The worker against a misbehaving server ───────────────────────────────────
//
// email_test.go's fake SMTP server is a WELL-BEHAVED one. These are the other kind: a server
// that accepts the connection and never speaks, and a delivery that traps. Both used to be
// fatal for the whole process — the first by pinning the single delivery goroutine forever,
// the second through an unrecovered panic on a goroutine nothing was watching.

// silentSMTP accepts connections and never greets. Each accepted connection is handed out on
// `accepted` so a test can hold it, and release it, at the moment it chooses.
type silentSMTP struct {
	listener net.Listener
	accepted chan net.Conn
}

func startSilentSMTP(t *testing.T) *silentSMTP {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := &silentSMTP{listener: listener, accepted: make(chan net.Conn, 8)}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			server.accepted <- conn
		}
	}()
	t.Cleanup(func() { _ = listener.Close() })
	return server
}

func (server *silentSMTP) settings(t *testing.T) SmtpSettings {
	t.Helper()
	address, ok := server.listener.Addr().(*net.TCPAddr)
	if !ok {
		t.Fatalf("listener address is %T", server.listener.Addr())
	}
	return testSettings("127.0.0.1", address.Port)
}

func (server *silentSMTP) awaitConnection(t *testing.T) net.Conn {
	t.Helper()
	select {
	case conn := <-server.accepted:
		return conn
	case <-time.After(5 * time.Second):
		t.Fatal("the worker never connected")
		return nil
	}
}

// A server that accepts and never greets is answered with an error at the deadline, not with a
// delivery goroutine parked forever. `smtp.Dial` had no deadline at all; the spec's rule is
// that every outbound call has one.
func TestDeliverEmailTimesOutOnASilentServer(t *testing.T) {
	t.Setenv("TESL_SMTP_TIMEOUT_MS", "300")
	server := startSilentSMTP(t)
	started := time.Now()
	err := DeliverEmail(server.settings(t), EmailMessage{
		To: "to@example.com", Subject: "S", Body: TextBody("b"),
	})
	elapsed := time.Since(started)
	if err == nil {
		t.Fatal("delivery to a server that never greeted succeeded")
	}
	if elapsed > 2*time.Second {
		t.Fatalf("delivery took %v to give up on a silent server", elapsed)
	}
	var timeout interface{ Timeout() bool }
	if !errors.As(err, &timeout) || !timeout.Timeout() {
		t.Fatalf("the failure is %v, not a timeout", err)
	}
}

// The knobs follow the HTTP client's: an unset or nonsensical value is the default.
func TestSmtpTimeoutKnobs(t *testing.T) {
	t.Setenv("TESL_SMTP_CONNECT_TIMEOUT_MS", "")
	t.Setenv("TESL_SMTP_TIMEOUT_MS", "")
	if got := smtpConnectTimeoutMs(); got != 10000 {
		t.Fatalf("default connect timeout is %d ms", got)
	}
	if got := smtpTimeoutMs(); got != 30000 {
		t.Fatalf("default exchange timeout is %d ms", got)
	}
	t.Setenv("TESL_SMTP_TIMEOUT_MS", "-5")
	if got := smtpTimeoutMs(); got != 30000 {
		t.Fatalf("a negative exchange timeout was accepted: %d ms", got)
	}
	t.Setenv("TESL_SMTP_TIMEOUT_MS", "1500")
	if got := smtpTimeoutMs(); got != 1500 {
		t.Fatalf("the exchange timeout knob was ignored: %d ms", got)
	}
}

// The outbox is RESET while a message is on the wire. The worker recorded slice indices across
// the unlocked delivery window, so when the failure came back it wrote through an index into a
// slice that had been emptied: index out of range, on the worker goroutine, fatal for the
// process. Now the message is looked up by id, found gone, and its result dropped.
func TestDeliverPendingSurvivesAResetMidDelivery(t *testing.T) {
	t.Setenv("TESL_SMTP_TIMEOUT_MS", "5000")
	server := startSilentSMTP(t)
	outbox := NewOutbox(server.settings(t))
	SendEmail(outbox, "a@example.com", "S", TextBody("b"))
	SendEmail(outbox, "b@example.com", "S", TextBody("b"))

	finished := make(chan any, 1)
	go func() {
		defer func() { finished <- recover() }()
		deliverPending(outbox)
	}()
	conn := server.awaitConnection(t)
	// The worker is now blocked on the greeting. Empty the store underneath it.
	ResetOutbox(outbox)
	// Then fail the delivery: the worker resumes and goes to record the outcome.
	_, _ = conn.Write([]byte("500 go away\r\n"))
	_ = conn.Close()
	// The second message's connection is the same story.
	second := server.awaitConnection(t)
	_, _ = second.Write([]byte("500 go away\r\n"))
	_ = second.Close()

	select {
	case trap := <-finished:
		if trap != nil {
			t.Fatalf("the worker trapped after a mid-delivery reset: %v", trap)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the worker did not return")
	}
	if messages := OutboxMessages(outbox); len(messages) != 0 {
		t.Fatalf("a reset outbox holds %+v", messages)
	}
	// The outbox is still a working outbox afterwards.
	SendEmail(outbox, "c@example.com", "S", TextBody("b"))
	if got := OutboxMessages(outbox); len(got) != 1 || got[0].Attempts != 0 {
		t.Fatalf("the outbox after the race holds %+v", got)
	}
}

// The subtler shape of the same bug: a PRUNE (not a reset) shifts the slice while a message is
// on the wire, and the stale index then lands the outcome on a DIFFERENT message — the failure
// is counted against a message that was never attempted. Identity by id puts it where it
// belongs.
func TestDeliverPendingAttributesToTheRightMessageAfterAPrune(t *testing.T) {
	t.Setenv("TESL_SMTP_TIMEOUT_MS", "5000")
	server := startSilentSMTP(t)
	outbox := NewOutbox(server.settings(t))
	// Index 0: a sent message old enough to be pruned. Index 1: the one that is due.
	// Index 2: pending but NOT due — the innocent bystander a stale index would point at
	// once index 0 is gone.
	outbox.messages = []EmailMessage{
		{id: 1, To: "old@example.com", Status: EmailSent, SentAt: time.Now().Add(-48 * time.Hour)},
	}
	outbox.nextID = 1
	SendEmail(outbox, "due@example.com", "S", TextBody("b"))
	SendEmail(outbox, "later@example.com", "S", TextBody("b"))
	outbox.mutex.Lock()
	outbox.messages[2].NextAttemptAt = time.Now().Add(time.Hour)
	outbox.mutex.Unlock()

	finished := make(chan any, 1)
	go func() {
		defer func() { finished <- recover() }()
		deliverPending(outbox)
	}()
	conn := server.awaitConnection(t)
	PruneSentEmail(outbox, 24*time.Hour)
	_, _ = conn.Write([]byte("500 go away\r\n"))
	_ = conn.Close()
	select {
	case trap := <-finished:
		if trap != nil {
			t.Fatalf("the worker trapped after a mid-delivery prune: %v", trap)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the worker did not return")
	}

	messages := OutboxMessages(outbox)
	if len(messages) != 2 {
		t.Fatalf("the pruned outbox holds %+v", messages)
	}
	byRecipient := map[string]EmailMessage{}
	for _, message := range messages {
		byRecipient[message.To] = message
	}
	if due := byRecipient["due@example.com"]; due.Attempts != 1 || due.Status != EmailPending {
		t.Fatalf("the attempted message is %+v, want one failed attempt", due)
	}
	if later := byRecipient["later@example.com"]; later.Attempts != 0 {
		t.Fatalf("the failure was attributed to a message that was never attempted: %+v", later)
	}
}

// A delivery that TRAPS is a failed attempt — counted, backed off, and eventually dead, exactly
// like one that returns an error — and the worker loop carries on to the next tick. Before, the
// panic unwound the worker goroutine with nothing to recover it, which ends the process.
func TestEmailWorkerSurvivesATrappingDelivery(t *testing.T) {
	outbox := NewOutbox(testSettings("127.0.0.1", 1))
	outbox.deliver = func(SmtpSettings, EmailMessage) error {
		panic("simulated trap inside delivery")
	}
	stop := make(chan struct{})
	loopEnded := make(chan struct{})
	go func() {
		defer close(loopEnded)
		runEmailWorker(outbox, 5*time.Millisecond, stop)
	}()
	defer func() {
		close(stop)
		select {
		case <-loopEnded:
		case <-time.After(5 * time.Second):
			t.Fatal("the worker loop did not stop")
		}
	}()

	awaitAttempt := func(recipient string) EmailMessage {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			for _, message := range OutboxMessages(outbox) {
				if message.To == recipient && message.Attempts > 0 {
					return message
				}
			}
			time.Sleep(5 * time.Millisecond)
		}
		t.Fatalf("the worker never attempted %s", recipient)
		return EmailMessage{}
	}

	SendEmail(outbox, "first@example.com", "S", TextBody("b"))
	first := awaitAttempt("first@example.com")
	if first.Status != EmailPending || first.Attempts != 1 {
		t.Fatalf("a trapped delivery left the message as %+v, want one failed attempt", first)
	}
	if !first.NextAttemptAt.After(time.Now()) {
		t.Fatalf("a trapped delivery was not backed off: %+v", first)
	}
	// The proof that the LOOP survived: a message sent after the trap is still attempted.
	SendEmail(outbox, "second@example.com", "S", TextBody("b"))
	if second := awaitAttempt("second@example.com"); second.Attempts != 1 {
		t.Fatalf("after a trap the worker attempted %+v", second)
	}
}

// The trap-to-error conversion follows the state machine all the way: five traps make a dead
// message, not a dead process.
func TestTrappingDeliveryExhaustsAttemptsToDead(t *testing.T) {
	outbox := NewOutbox(testSettings("127.0.0.1", 1))
	outbox.deliver = func(SmtpSettings, EmailMessage) error { panic("always") }
	SendEmail(outbox, "to@example.com", "S", TextBody("b"))
	for range emailMaxAttempts {
		deliverPending(outbox)
		outbox.mutex.Lock()
		outbox.messages[0].NextAttemptAt = time.Time{}
		outbox.mutex.Unlock()
	}
	final := OutboxMessages(outbox)[0]
	if final.Status != EmailDead || final.Attempts != emailMaxAttempts {
		t.Fatalf("after %d trapping attempts the message is %+v", emailMaxAttempts, final)
	}
}

// The outer guard covers a trap OUTSIDE delivery too — anything an iteration might do wrong is
// reported on stderr and the next tick still happens. A nil outbox is the bluntest way to make
// the iteration itself fail.
func TestEmailWorkerIterationRecoversAnyTrap(t *testing.T) {
	defer func() {
		if trap := recover(); trap != nil {
			t.Fatalf("the iteration guard let a trap through: %v", trap)
		}
	}()
	runEmailWorkerIteration(nil)
}

// Messages enqueued through SendEmail carry distinct, monotonically increasing ids: the identity
// the worker relies on across the unlocked window.
func TestSendEmailAssignsDistinctIds(t *testing.T) {
	outbox := NewOutbox(testSettings("", 0))
	for range 3 {
		SendEmail(outbox, "to@example.com", "S", TextBody("b"))
	}
	messages := OutboxMessages(outbox)
	seen := map[uint64]bool{}
	var previous uint64
	for _, message := range messages {
		if message.id == 0 {
			t.Fatalf("an enqueued message has no id: %+v", message)
		}
		if seen[message.id] || message.id <= previous {
			t.Fatalf("ids are not distinct and increasing: %+v", messages)
		}
		seen[message.id] = true
		previous = message.id
	}
	// Ids are never reused after a reset: a message from before the reset can then never be
	// mistaken for one enqueued after it.
	ResetOutbox(outbox)
	SendEmail(outbox, "to@example.com", "S", TextBody("b"))
	if got := OutboxMessages(outbox)[0].id; got <= previous {
		t.Fatalf("an id was reused after a reset: %d <= %d", got, previous)
	}
}
