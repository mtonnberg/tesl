package teslrt

import (
	"fmt"
	"strings"
	"sync"
)

// The outbound-HTTP test double.
//
// Without it, every handler or worker that talks to an external service has an untestable
// branch — and the branches most worth covering (an upstream 500, malformed JSON, a timeout)
// are exactly the ones a real upstream will not produce on demand. A test declares its
// answers up front:
//
//	stubHttp        "GET"  "https://rates.test/v1"  200 "{\"usd\":110}"
//	stubHttpFailure "POST" "https://rates.test/log" "connection refused"
//	stubHttpTimeout "GET"  "https://rates.test/slow"
//
// and asserts afterwards with httpCalled / httpCallCount / httpLastBody.
//
// SCOPE. The table is cleared at the top of every emitted test function, so rules and the
// call log cannot leak from one test block into the next — the isolation the Racket side gets
// from a parameter that unwinds with the test body. Go's `go test` runs a package's tests
// sequentially unless a test opts into t.Parallel, which emitted tests never do, so one
// package-level table is enough and a stub is visible to the goroutines a test starts
// (a queue worker's outbound call is the case that matters).
//
// PRODUCTION. `active` is false until an emitted test clears the table, and only a test file
// does that, so a production build can never answer a call from here. That is a weaker
// guarantee than Racket's (where the double lives in a module a production run does not
// instantiate at all) and it is the strongest one available inside a single Go package.
type httpStubRule struct {
	method  string
	url     string
	kind    httpStubKind
	status  int64
	payload string // the canned body, the failure message, or "" for a timeout
}

type httpStubKind int

const (
	httpStubRespond httpStubKind = iota
	httpStubFail
	httpStubTimeout
)

type httpStubCall struct {
	method string
	url    string
	body   string
}

var httpStubs = struct {
	mutex  sync.Mutex
	active bool
	rules  []httpStubRule
	calls  []httpStubCall
}{}

// ResetHttpStubs gives the current test a fresh, empty stub table. Emitted test functions
// call it before their first statement.
func ResetHttpStubs() {
	httpStubs.mutex.Lock()
	defer httpStubs.mutex.Unlock()
	httpStubs.active = true
	httpStubs.rules = nil
	httpStubs.calls = nil
}

func requireStubScope(who string) {
	if !httpStubs.active {
		panic(who + ": outbound-HTTP stubs are only available inside a test body.\n" +
			"  Call this from a `test`, `api-test`, or `load-test` block — the stub\n" +
			"  scope is created per test so nothing leaks between them.")
	}
}

// ── Declaring a stub ──────────────────────────────────────────────────────────

// StubHttp declares a canned response. Rules are consulted in DECLARATION order (first
// match wins), so a specific stub declared before a `"*"` catch-all keeps winning;
// re-declaring the exact same (method, url) pattern REPLACES the earlier rule in place, so a
// later line in the same test overrides an earlier one rather than being shadowed by it.
func StubHttp(method, target string, status Int, body string) struct{} {
	value, exact := status.Int64()
	if !exact {
		panic("stubHttp: expected an Int status")
	}
	return addHTTPStubRule("stubHttp", httpStubRule{
		method: method, url: target, kind: httpStubRespond, status: value, payload: body,
	})
}

// StubHttpFailure declares that the call fails the way a refused connection does.
func StubHttpFailure(method, target, message string) struct{} {
	return addHTTPStubRule("stubHttpFailure", httpStubRule{
		method: method, url: target, kind: httpStubFail, payload: message,
	})
}

// StubHttpTimeout declares that the call blows its deadline.
func StubHttpTimeout(method, target string) struct{} {
	return addHTTPStubRule("stubHttpTimeout", httpStubRule{
		method: method, url: target, kind: httpStubTimeout,
	})
}

func addHTTPStubRule(who string, rule httpStubRule) struct{} {
	requireStubScope(who)
	httpStubs.mutex.Lock()
	defer httpStubs.mutex.Unlock()
	for index, existing := range httpStubs.rules {
		if existing.method == rule.method && existing.url == rule.url {
			httpStubs.rules[index] = rule
			return struct{}{}
		}
	}
	httpStubs.rules = append(httpStubs.rules, rule)
	return struct{}{}
}

// ── Matching ──────────────────────────────────────────────────────────────────

// httpStubPatternMatches is deliberately NOT a regex: a stub pattern is a test fixture, and
// `*` plus a trailing-`*` prefix covers every shape the lessons need without putting a second
// pattern language into the surface. Method matching is case-insensitive; URL matching is not.
func httpStubPatternMatches(pattern, value string, foldCase bool) bool {
	if foldCase {
		pattern = strings.ToLower(pattern)
		value = strings.ToLower(value)
	}
	switch {
	case pattern == "*":
		return true
	case strings.HasSuffix(pattern, "*"):
		return strings.HasPrefix(value, strings.TrimSuffix(pattern, "*"))
	default:
		return pattern == value
	}
}

func (rule httpStubRule) matches(method, target string) bool {
	return httpStubPatternMatches(rule.method, method, true) &&
		httpStubPatternMatches(rule.url, target, false)
}

// httpStubAnswer is the seam tesl/http-client.rkt reaches through its hook parameter.
// `false` means no stub is in force, which is only possible when the test declared no stubs
// at all — so an existing test that really wants the network behaves as before. Once a test
// declares its first stub, an unmatched call is a loud failure instead of a silent live
// request.
func httpStubAnswer(method, target string, body *string) (HttpResponse, bool) {
	httpStubs.mutex.Lock()
	if !httpStubs.active {
		httpStubs.mutex.Unlock()
		return HttpResponse{}, false
	}
	sent := ""
	if body != nil {
		sent = *body
	}
	// The call is recorded BEFORE it is matched, so `httpCalled` sees a call that then failed
	// for want of a stub — which is what a test asserting on the failure needs.
	httpStubs.calls = append(httpStubs.calls,
		httpStubCall{method: strings.ToUpper(method), url: target, body: sent})
	rules := make([]httpStubRule, len(httpStubs.rules))
	copy(rules, httpStubs.rules)
	httpStubs.mutex.Unlock()

	if len(rules) == 0 {
		return HttpResponse{}, false
	}
	for _, rule := range rules {
		if !rule.matches(method, target) {
			continue
		}
		switch rule.kind {
		case httpStubTimeout:
			// Byte-for-byte the message the real deadline produces, so a test written against
			// the stub matches what production logs.
			panic(fmt.Sprintf("HttpClient: HTTP %s to %s timed out after %dms",
				strings.ToUpper(method), target, httpReadTimeoutMs()))
		case httpStubFail:
			panic(fmt.Sprintf("HttpClient: HTTP %s to %s failed: %s",
				strings.ToUpper(method), target, rule.payload))
		case httpStubRespond:
			return HttpResponse{
				Status:  FromInt64(rule.status),
				Body:    rule.payload,
				Headers: []Tuple2[string, string]{},
			}, true
		}
	}
	panic(fmt.Sprintf("HttpClient: no stub matches %s %s\n"+
		"  This test declared outbound-HTTP stubs, so no call reaches the network.\n"+
		"  declared: %s\n"+
		"  hint: add `stubHttp %q %q 200 \"…\"`, or widen a pattern with a trailing *.",
		strings.ToUpper(method), target, describeHTTPStubRules(rules),
		strings.ToUpper(method), target))
}

func describeHTTPStubRules(rules []httpStubRule) string {
	if len(rules) == 0 {
		return "(none)"
	}
	described := make([]string, 0, len(rules))
	for _, rule := range rules {
		switch rule.kind {
		case httpStubRespond:
			described = append(described,
				fmt.Sprintf("%s %s -> status %d", rule.method, rule.url, rule.status))
		case httpStubFail:
			described = append(described,
				fmt.Sprintf("%s %s -> failure %q", rule.method, rule.url, rule.payload))
		case httpStubTimeout:
			described = append(described, fmt.Sprintf("%s %s -> timeout", rule.method, rule.url))
		}
	}
	return strings.Join(described, "\n            ")
}

// ── Asserting on the calls made ───────────────────────────────────────────────

func matchingHTTPCalls(who, method, target string) []httpStubCall {
	requireStubScope(who)
	httpStubs.mutex.Lock()
	defer httpStubs.mutex.Unlock()
	matched := make([]httpStubCall, 0, len(httpStubs.calls))
	for _, call := range httpStubs.calls {
		if httpStubPatternMatches(method, call.method, true) &&
			httpStubPatternMatches(target, call.url, false) {
			matched = append(matched, call)
		}
	}
	return matched
}

func HttpCallCount(method, target string) Int {
	return FromInt64(int64(len(matchingHTTPCalls("httpCallCount", method, target))))
}

func HttpCalled(method, target string) bool {
	return len(matchingHTTPCalls("httpCalled", method, target)) > 0
}

// HttpLastBody is the body of the most recent matching call, or a trap naming the calls that
// were made — a test asserting on a body it never sent is a broken test, not a false one.
func HttpLastBody(method, target string) string {
	matched := matchingHTTPCalls("httpLastBody", method, target)
	if len(matched) == 0 {
		panic(fmt.Sprintf("httpLastBody: no outbound %s call matched %q\n  calls made: %s",
			method, target, describeHTTPCallsMade()))
	}
	return matched[len(matched)-1].body
}

func describeHTTPCallsMade() string {
	httpStubs.mutex.Lock()
	defer httpStubs.mutex.Unlock()
	if len(httpStubs.calls) == 0 {
		return "(none)"
	}
	described := make([]string, 0, len(httpStubs.calls))
	for _, call := range httpStubs.calls {
		described = append(described, call.method+" "+call.url)
	}
	return strings.Join(described, ", ")
}
