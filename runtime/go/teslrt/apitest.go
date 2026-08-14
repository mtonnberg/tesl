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
	Status  Int
	Body    string
	Headers Dict[string, string]
}

// ApiRequest dispatches one request and captures the response. `body` is sent as-is;
// `cookies` are `name=value` pairs.
func ApiRequest(server Server, method, path, body string, cookies ...string) ApiResponse {
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	// A REQUEST cookie is just `name=value` on the wire — it carries none of the
	// Secure/HttpOnly/SameSite attributes a response cookie does, so the header is built
	// directly rather than through http.Cookie (which would also make gosec flag a
	// missing-attributes issue that cannot apply here).
	if len(cookies) > 0 {
		request.Header.Set("Cookie", strings.Join(cookies, "; "))
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	result := recorder.Result()
	raw, _ := io.ReadAll(result.Body)
	headers := DictEmpty[string, string]()
	for name, values := range result.Header {
		if len(values) > 0 {
			headers = DictInsert(headers, strings.ToLower(name), values[0], stringKeyLess)
		}
	}
	return ApiResponse{
		Status:  FromInt64(int64(result.StatusCode)),
		Body:    string(raw),
		Headers: headers,
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
