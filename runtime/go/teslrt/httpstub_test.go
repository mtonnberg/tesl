package teslrt

import (
	"fmt"
	"strings"
	"testing"
)

// The stub table is package-level state that emitted tests clear at their top; the runtime's
// own suite has to put it back afterwards, or a later test in this package would find stubs
// active and its network calls intercepted.
func withStubs(t *testing.T) {
	t.Helper()
	ResetHttpStubs()
	t.Cleanup(func() {
		httpStubs.mutex.Lock()
		defer httpStubs.mutex.Unlock()
		httpStubs.active = false
		httpStubs.rules = nil
		httpStubs.calls = nil
	})
}

func trapMessage(t *testing.T, thunk func()) string {
	t.Helper()
	var message string
	func() {
		defer func() {
			recovered := recover()
			if recovered == nil {
				t.Fatal("expected a trap")
			}
			message = fmt.Sprint(recovered)
		}()
		thunk()
	}()
	return message
}

func TestStubbedResponseAnswersWithoutTheNetwork(t *testing.T) {
	withStubs(t)
	_ = StubHttp("GET", "https://rates.test/v1", FromInt64(200), `{"usd":110}`)
	response := HttpGet("https://rates.test/v1", noHeaders())
	if value, _ := response.Status.Int64(); value != 200 {
		t.Fatalf("status = %s", response.Status.String())
	}
	if response.Body != `{"usd":110}` {
		t.Fatalf("body = %q", response.Body)
	}
}

func TestStubMatchingCoversMethodWildcardAndPrefix(t *testing.T) {
	withStubs(t)
	_ = StubHttp("GET", "https://rates.test/v1", FromInt64(200), "get-answer")
	_ = StubHttp("POST", "https://rates.test/v1", FromInt64(201), "post-answer")
	if got := HttpGet("https://rates.test/v1", noHeaders()).Body; got != "get-answer" {
		t.Fatalf("GET body = %q", got)
	}
	if got := HttpPost("https://rates.test/v1", noHeaders(), "x").Body; got != "post-answer" {
		t.Fatalf("POST body = %q", got)
	}

	withStubs(t)
	_ = StubHttp("*", "https://rates.test/*", FromInt64(200), "wildcard")
	for _, target := range []string{"https://rates.test/v1", "https://rates.test/v2?since=1"} {
		if got := HttpGet(target, noHeaders()).Body; got != "wildcard" {
			t.Fatalf("%s body = %q", target, got)
		}
	}
	// A method is matched case-insensitively; a URL is not.
	if got := HttpPut("https://rates.test/v1", noHeaders(), "x").Body; got != "wildcard" {
		t.Fatalf("PUT body = %q", got)
	}
}

// Declaration order decides, so a specific stub declared before a catch-all keeps winning.
func TestFirstDeclaredStubWins(t *testing.T) {
	withStubs(t)
	_ = StubHttp("GET", "https://rates.test/v1", FromInt64(200), "specific")
	_ = StubHttp("*", "*", FromInt64(500), "catch-all")
	if got := HttpGet("https://rates.test/v1", noHeaders()).Body; got != "specific" {
		t.Fatalf("specific body = %q", got)
	}
	if got := HttpGet("https://rates.test/other", noHeaders()); got.Body != "catch-all" {
		t.Fatalf("catch-all body = %q", got.Body)
	}
}

// Re-declaring the same pattern REPLACES the rule in place rather than being shadowed by the
// earlier one, so a later line in the same test overrides an earlier one.
func TestRestubbingReplacesInPlace(t *testing.T) {
	withStubs(t)
	_ = StubHttp("GET", "https://rates.test/v1", FromInt64(200), "first")
	_ = StubHttp("GET", "https://rates.test/v1", FromInt64(200), "second")
	if got := HttpGet("https://rates.test/v1", noHeaders()).Body; got != "second" {
		t.Fatalf("body = %q", got)
	}
	// Replacement keeps the rule's POSITION, so it still beats a catch-all declared after it.
	withStubs(t)
	_ = StubHttp("GET", "https://rates.test/v1", FromInt64(200), "specific")
	_ = StubHttp("*", "*", FromInt64(500), "catch-all")
	_ = StubHttp("GET", "https://rates.test/v1", FromInt64(200), "replaced")
	if got := HttpGet("https://rates.test/v1", noHeaders()).Body; got != "replaced" {
		t.Fatalf("body = %q", got)
	}
}

func TestStubbedFailureAndTimeoutTrapLikeTheRealThing(t *testing.T) {
	withStubs(t)
	_ = StubHttpFailure("GET", "https://rates.test/down", "connection refused")
	message := trapMessage(t, func() { _ = HttpGet("https://rates.test/down", noHeaders()) })
	if message != "HttpClient: HTTP GET to https://rates.test/down failed: connection refused" {
		t.Fatalf("failure trap = %q", message)
	}

	_ = StubHttpTimeout("GET", "https://rates.test/slow")
	message = trapMessage(t, func() { _ = HttpGet("https://rates.test/slow", noHeaders()) })
	if message != "HttpClient: HTTP GET to https://rates.test/slow timed out after 30000ms" {
		t.Fatalf("timeout trap = %q", message)
	}
}

// Once a test declares its first stub, an unmatched call is a loud failure rather than a
// silent live request.
func TestUnmatchedCallFailsLoudlyAndIsStillRecorded(t *testing.T) {
	withStubs(t)
	_ = StubHttp("GET", "https://rates.test/v1", FromInt64(200), "ok")
	message := trapMessage(t, func() { _ = HttpGet("https://elsewhere.test/v1", noHeaders()) })
	for _, want := range []string{"no stub matches GET https://elsewhere.test/v1",
		"declared: GET https://rates.test/v1 -> status 200", "hint: add `stubHttp"} {
		if !strings.Contains(message, want) {
			t.Fatalf("trap %q does not mention %q", message, want)
		}
	}
	if !HttpCalled("GET", "https://elsewhere.test/v1") {
		t.Fatal("the unmatched call was not recorded")
	}
}

func TestCallLogCountsAndLastBody(t *testing.T) {
	withStubs(t)
	_ = StubHttp("*", "*", FromInt64(200), "ok")
	_ = HttpGet("https://rates.test/v1", noHeaders())
	_ = HttpGet("https://rates.test/v1", noHeaders())
	_ = HttpPost("https://rates.test/log", noHeaders(), `{"event":"sync"}`)

	if count, _ := HttpCallCount("GET", "https://rates.test/v1").Int64(); count != 2 {
		t.Fatalf("GET count = %d", count)
	}
	if count, _ := HttpCallCount("POST", "https://rates.test/log").Int64(); count != 1 {
		t.Fatalf("POST count = %d", count)
	}
	if count, _ := HttpCallCount("GET", "https://rates.test/log").Int64(); count != 0 {
		t.Fatalf("mismatched method counted %d", count)
	}
	if count, _ := HttpCallCount("*", "*").Int64(); count != 3 {
		t.Fatalf("total count = %d", count)
	}
	if body := HttpLastBody("POST", "https://rates.test/log"); body != `{"event":"sync"}` {
		t.Fatalf("last body = %q", body)
	}
	message := trapMessage(t, func() { _ = HttpLastBody("PUT", "https://rates.test/log") })
	if !strings.Contains(message, "no outbound PUT call matched") ||
		!strings.Contains(message, "calls made: GET https://rates.test/v1") {
		t.Fatalf("trap = %q", message)
	}
}

// The table is cleared per test block, so neither a rule nor a call log entry survives into
// the next one.
func TestResetClearsRulesAndCalls(t *testing.T) {
	withStubs(t)
	_ = StubHttp("GET", "https://leak.test/v1", FromInt64(200), "from the first block")
	_ = HttpGet("https://leak.test/v1", noHeaders())

	ResetHttpStubs()
	if count, _ := HttpCallCount("*", "*").Int64(); count != 0 {
		t.Fatalf("call log survived the reset: %d", count)
	}
	if HttpCalled("GET", "https://leak.test/v1") {
		t.Fatal("httpCalled sees the previous block's call")
	}
	_ = StubHttp("GET", "https://other.test/v1", FromInt64(200), "ok")
	message := trapMessage(t, func() { _ = HttpGet("https://leak.test/v1", noHeaders()) })
	if !strings.Contains(message, "no stub matches") {
		t.Fatalf("the previous block's rule survived: %q", message)
	}
}

// Outside a test body there is no scope, and stubbing is refused rather than silently
// installing a rule a production run could match against.
func TestStubbingOutsideATestBodyIsRefused(t *testing.T) {
	httpStubs.mutex.Lock()
	httpStubs.active = false
	httpStubs.mutex.Unlock()
	message := trapMessage(t, func() { _ = StubHttp("GET", "*", FromInt64(200), "x") })
	if !strings.Contains(message, "only available inside a test body") {
		t.Fatalf("trap = %q", message)
	}
	// With no scope the client goes to the network, so nothing here can intercept a call.
	if _, stubbed := httpStubAnswer("GET", "https://rates.test/v1", nil); stubbed {
		t.Fatal("an inactive stub table answered a call")
	}
}
