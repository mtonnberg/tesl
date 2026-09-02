package teslrt

import "testing"

// A tuple is a plain product: no tag, and the zero value is the pair of zero values.
// Emitted code constructs these as composite literals, so the field names and their
// order are part of the contract with the emitter.
func TestTupleHoldsBothComponents(t *testing.T) {
	pair := Tuple2[Int, string]{Tuple2First: FromInt64(3), Tuple2Second: "x"}
	if !Equal(pair.Tuple2First, FromInt64(3)) || pair.Tuple2Second != "x" {
		t.Fatalf("pair = %v", pair)
	}

	triple := Tuple3[Int, string, bool]{
		Tuple3First: FromInt64(1), Tuple3Second: "y", Tuple3Third: true}
	if !Equal(triple.Tuple3First, FromInt64(1)) || triple.Tuple3Second != "y" || !triple.Tuple3Third {
		t.Fatalf("triple = %v", triple)
	}
}

func TestTupleZeroValueIsTheZeroOfEachComponent(t *testing.T) {
	var pair Tuple2[Int, string]
	if !pair.Tuple2First.IsZero() || pair.Tuple2Second != "" {
		t.Fatalf("zero pair = %v", pair)
	}
}

// Copying a tuple copies its components: Tesl values are immutable, and a tuple
// holding a slice must not let two bindings share a mutable view by surprise.
func TestTupleCopyIsIndependentForValueComponents(t *testing.T) {
	original := Tuple2[Int, Int]{Tuple2First: FromInt64(1), Tuple2Second: FromInt64(2)}
	copied := original
	copied.Tuple2First = FromInt64(99)
	if !Equal(original.Tuple2First, FromInt64(1)) {
		t.Fatalf("copy mutated the original: %s", original.Tuple2First.String())
	}
}
