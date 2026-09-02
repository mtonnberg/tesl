package teslrt

import "fmt"

// Check is the erased runtime result of a Tesl check. Proof identities remain a
// compiler concern; runtime retains only success/failure and the checked value.
type Check[T any] struct {
	value   T
	status  int
	message string
	ok      bool
	// shape marks "the JSON is not this shape" as opposed to "this value is invalid"; see
	// RejectShape. It is a FLAG rather than a reserved status, because the status is also what
	// a leaked rejection writes on the wire, and a sentinel status of 0 there is not a
	// response — `WriteHeader(0)` panics.
	shape bool
}

func Accept[T any](value T) Check[T] {
	return Check[T]{value: value, ok: true}
}

func Reject[T any](status int, message string) Check[T] {
	return Check[T]{status: status, message: message}
}

func (result Check[T]) OK() bool {
	return result.ok
}

func (result Check[T]) Value() (T, bool) {
	return result.value, result.ok
}

func (result Check[T]) Status() int {
	return result.status
}

func (result Check[T]) Message() string {
	return result.message
}

// MustCheck unwraps a statically expected successful check and fails closed if
// a caller ignored rejection propagation.
func MustCheck[T any](result Check[T]) T {
	if !result.ok {
		panic(fmt.Sprintf("Tesl check rejected with status %d: %s", result.status, result.message))
	}
	return result.value
}

// RequestRejection is a check rejection consumed inside a HANDLER body. It travels as a
// panic because a handler's Go signature returns its value type, with nowhere to put a
// failure — and the router turns it back into a response carrying the check's own status.
//
// That is the Racket behaviour, not an invention: `dsl/web.rkt` installs the
// raise-on-escaping-failure wrapper for every function kind EXCEPT `handler`, so a
// rejection reached in a handler body flows out as the response's status (422, 404, …)
// rather than as a server error. Reporting 500 there would turn "you sent an invalid age"
// into "this server is broken".
type RequestRejection struct {
	Status  int
	Message string
}

// Error makes a rejection print as its MESSAGE wherever a panic value is formatted — which is
// what a failed job records (`runJob` keeps `fmt.Sprint(recovered)` as the attempt's error).
// Racket records `check-fail-message` there, the bare text, so a struct dump would be a
// different string on the two backends for the same program.
func (rejection RequestRejection) Error() string {
	return rejection.Message
}

// MustCheckRequest is `MustCheck` at the request boundary: same unwrapping, but a rejection
// answers the client instead of crashing the request.
func MustCheckRequest[T any](result Check[T]) T {
	if !result.ok {
		panic(RequestRejection{Status: result.status, Message: result.message})
	}
	return result.value
}

// RejectShape reports that the JSON simply is not this shape — a missing or mistyped field —
// as opposed to a VALIDATION failure from a `via` or cross-check, which carries the status the
// check itself chose.
//
// The distinction is load-bearing when a codec has several alternatives. Racket's
// registry loop treats a raised decode exception as "try the next decoder" while a
// check failure is remembered (the FIRST one wins) and still lets a later alternative
// succeed. Collapsing the two would report "required field \"userName\" not found" —
// the last alternative's shape complaint — in place of the real 400 the first
// alternative's check produced.
// A shape rejection still carries 400, so a decoder with no alternatives behind it (a DERIVED
// record decoder) can answer the client with it directly.
func RejectShape[T any](message string) Check[T] {
	return Check[T]{status: 400, message: message, shape: true}
}

// IsShapeMismatch reports whether a failure means "not this shape" rather than "this
// value is invalid".
func (result Check[T]) IsShapeMismatch() bool {
	return !result.ok && result.shape
}
