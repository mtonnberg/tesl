package teslrt

// Tuple2 and Tuple3 are Tesl's anonymous products. They live in the runtime for the
// same reason Maybe does: a tuple crosses module boundaries, so two emitted packages
// declaring their own would be incompatible Go types.
//
// Unlike Maybe they carry NO tag — a single-variant type has nothing to discriminate,
// and a tag would be a wasted word in a value used as a lightweight pair. The emitter
// knows this shape and matches `Tuple2 x y -> …` by binding the fields directly
// instead of switching.
//
// Field names are the ones the emitter derives for a constructor's payload
// (constructor name + field name), so `Tuple2.first p` emits as `p.Tuple2First`.
type Tuple2[A any, B any] struct {
	Tuple2First  A
	Tuple2Second B
}

type Tuple3[A any, B any, C any] struct {
	Tuple3First  A
	Tuple3Second B
	Tuple3Third  C
}
