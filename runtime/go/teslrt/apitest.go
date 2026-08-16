package teslrt

import (
	"io"
	"net/http/httptest"
	"strings"
)

// In-process driving of an emitted server, for Tesl's `api-test` blocks.
//
// The request never leaves the process — no socket, no port to collide with — which is
// what makes these usable as ordinary `go test` cases. Racket's api-tests dispatch the
// same way (`dispatch-api-test-request` calls the server's own router rather than opening
// a connection), so the two backends exercise the same layer.
type ApiResponse struct {
	Status Int
	// The body as a PARSED JSON value, not as text.  An api-test inspects it without types
	// (`resp.body.userId`), which is the ergonomics the Racket surface has:
	// `api-test-field-access-ref` normalises the response and hands back the parsed body, so a
	// raw string here would have made every assertion a string-compare against serialised
	// JSON — a different language for the same test.
	Body    JsonValue
	Headers Dict[string, string]
}

// ApiRequest dispatches one request and captures the response. `body` is sent as-is;
// `cookies` are `name=value` pairs; `headers` are sent as written, which is what the
// `headers { … }` modifier means — a test signing its own payload puts the tag in a header, and
// a header value is transport text, not JSON.
func ApiRequest(server Server, method, path, body string, cookies []string,
	headers []Tuple2[string, string]) ApiResponse {
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	// A REQUEST cookie is just `name=value` on the wire — it carries none of the
	// Secure/HttpOnly/SameSite attributes a response cookie does, so the header is built
	// directly rather than through http.Cookie (which would also make gosec flag a
	// missing-attributes issue that cannot apply here).
	if len(cookies) > 0 {
		request.Header.Set("Cookie", strings.Join(cookies, "; "))
	}
	for _, header := range headers {
		// Added rather than set: a test may send the same header twice deliberately, and the
		// server side is what decides which value wins.
		request.Header.Add(header.Tuple2First, header.Tuple2Second)
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	result := recorder.Result()
	raw, _ := io.ReadAll(result.Body)
	// The RESPONSE headers, as the Dict an api-test reads: last-wins on a repeated name, the
	// same rule NewHttpRequest applies inbound.
	//
	// SET-COOKIE is the ONE exception, and it is chosen rather than accidental. A response
	// that both sets and clears a cookie is completely ordinary — the SSO callback emits
	//
	//	Set-Cookie: __Host-session=<token>; …      ← the session it just minted
	//	Set-Cookie: __Host-oauth=; Max-Age=0       ← the spent in-flight state
	//
	// and last-wins made the surviving line the CLEARED cookie, so feeding it back carried
	// no session and the very next request 401'd. A wrong-but-plausible value rather than an
	// error, which reads as "the login flow is broken" instead of "the harness dropped a
	// header". So the surviving line is the FIRST that actually sets something; with only
	// clears present the last one still wins. Racket's `response-headers->hash` decides the
	// same way, in one place, so `responseCookie` needs no rule of its own.
	responseHeaders := DictEmpty[string, string]()
	for name, values := range result.Header {
		if len(values) == 0 {
			continue
		}
		surviving := values[len(values)-1]
		if strings.EqualFold(name, "Set-Cookie") {
			for _, line := range values {
				if cookieLineSetsAValue(line) {
					surviving = line
					break
				}
			}
		}
		responseHeaders = DictInsert(responseHeaders, strings.ToLower(name),
			surviving, stringKeyLess)
	}
	return ApiResponse{
		Status:  FromInt64(int64(result.StatusCode)),
		Body:    JsonParseBody(string(raw)),
		Headers: responseHeaders,
	}
}

// The status predicates Tesl.ApiTest exposes.
func StatusOk(status Int) bool          { return statusInRange(status, 200, 300) }
func StatusClientError(status Int) bool { return statusInRange(status, 400, 500) }
func StatusServerError(status Int) bool { return statusInRange(status, 500, 600) }

func statusInRange(status Int, low, high int64) bool {
	value, ok := status.Int64()
	return ok && value >= low && value < high
}

// cookieLineSetsAValue reports whether a `Set-Cookie` line assigns a non-empty value. A
// `Max-Age=0` clear assigns none, so it can never shadow a real cookie.
func cookieLineSetsAValue(line string) bool {
	// Cut at the first `;` rather than indexing a split: a split result is a slice whose
	// emptiness nothing here guarantees to a reader (or to nilaway), and the pair is
	// everything before the first attribute either way.
	pair := line
	if at := strings.Index(line, ";"); at >= 0 {
		pair = line[:at]
	}
	pair = strings.TrimSpace(pair)
	at := strings.Index(pair, "=")
	return at >= 0 && len(pair) > at+1
}
