package teslrt

// Result is Tesl's `Result ok err`: Ok carries the value, Err the failure. Like Maybe and
// Either it lives in the runtime because a Result crosses module boundaries, and it uses
// the same flat tag+payload shape the emitter generates for a user ADT.
//
// The zero value is an Ok holding the zero value of Ok — the tag order below — which is the
// one asymmetry worth stating: a zero Result reads as success. Emitted code never produces
// one (every construction names a constructor), and Tesl has no way to observe an
// uninitialised value, so this is a Go-level note rather than a semantic choice.
type Result[Ok any, Err any] struct {
	Tag      ResultTag
	OkValue  Ok
	ErrValue Err
}

// ResultTag identifies which side a Result holds. The constants are an enum-like set so the
// `exhaustive` linter can verify a switch over them.
type ResultTag int

const (
	ResultOk ResultTag = iota
	ResultErr
)

// MakeOk and MakeErr exist for hand-written runtime code and readable tests; emitted code
// writes the composite literal directly. They are not named `Ok`/`Err` because those are
// the FIELD-bearing type parameters above, and a function may not share a name with them.
func MakeOk[Ok any, Err any](value Ok) Result[Ok, Err] {
	return Result[Ok, Err]{Tag: ResultOk, OkValue: value}
}

func MakeErr[Ok any, Err any](failure Err) Result[Ok, Err] {
	return Result[Ok, Err]{Tag: ResultErr, ErrValue: failure}
}

// IsOk reports which side is held.
func (r Result[Ok, Err]) IsOk() bool {
	return r.Tag == ResultOk
}
