package teslrt

import "fmt"

// Check is the erased runtime result of a Tesl check. Proof identities remain a
// compiler concern; runtime retains only success/failure and the checked value.
type Check[T any] struct {
	value   T
	status  int
	message string
	ok      bool
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
