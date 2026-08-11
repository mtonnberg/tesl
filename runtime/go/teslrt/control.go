package teslrt

// If evaluates and returns only the branch selected by condition.
func If[T any](condition bool, whenTrue, whenFalse func() T) T {
	if condition {
		return whenTrue()
	}
	return whenFalse()
}
