package teslrt

import (
	"strings"
	"testing"
)

type queueConversionTestOld struct{ text string }
type queueConversionTestNew struct{ text string }

// Pipeline mechanics are calibrated independently of source registration. The
// compiled application tests exercise the only exported binding constructor.
func queueConversionPipeline(calls *[4]int) *CompiledQueueConversion[queueConversionTestOld, queueConversionTestNew] {
	return &CompiledQueueConversion[queueConversionTestOld, queueConversionTestNew]{
		source: &pgQueueConversionSource{fromVersion: 1, toVersion: 2, spec: pgQueueConversionSourceSpec{digest: "test-source"}},
		decode: func(raw any) Check[queueConversionTestOld] {
			calls[0]++
			text, err := DecodeStringField(raw, "old")
			if err != nil {
				return Reject[queueConversionTestOld](400, "private decoder detail")
			}
			return Accept(queueConversionTestOld{text})
		},
		convert: func(old queueConversionTestOld) Migrated[queueConversionTestNew] {
			calls[1]++
			if old.text == "reject" {
				return Migrated[queueConversionTestNew]{Tag: MigratedReject, RejectReason: "checked rejection"}
			}
			return Migrated[queueConversionTestNew]{Tag: MigratedRow, RowValue: queueConversionTestNew{old.text}}
		},
		encode: func(value queueConversionTestNew) any { calls[2]++; return map[string]any{"new": value.text} },
		targetDecode: func(raw any) Check[queueConversionTestNew] {
			calls[3]++
			text, err := DecodeStringField(raw, "new")
			if err != nil {
				return Reject[queueConversionTestNew](400, "private target detail")
			}
			return Accept(queueConversionTestNew{text})
		},
	}
}

func TestQueueConversionPipelineStagesAndOwnership(t *testing.T) {
	for _, test := range []struct {
		name, input, kind string
		calls             [4]int
	}{
		{"accepted", `{"old":"kept"}`, "converted", [4]int{1, 1, 1, 1}},
		{"rejected", `{"old":"reject"}`, "migration-rejected", [4]int{1, 1, 0, 0}},
		{"malformed-json", `{`, "payload-invalid", [4]int{}},
		{"wrong-old-shape", `{"new":"kept"}`, "payload-invalid", [4]int{1, 0, 0, 0}},
	} {
		t.Run(test.name, func(t *testing.T) {
			var calls [4]int
			converter := queueConversionPipeline(&calls)
			input := []byte(test.input)
			result, err := converter.Convert(1, input)
			if err != nil || result.Kind() != test.kind || calls != test.calls {
				t.Fatal(result, calls, err)
			}
			if result.Original() != test.input || result.SourceDigest() != "test-source" || result.SourceVersion() != 1 || result.TargetVersion() != 2 {
				t.Fatal("outcome lost exact input/source identity", result)
			}
			input[0] = '!'
			if result.Original() != test.input {
				t.Fatal("outcome aliases caller bytes")
			}
			if result.Kind() != "converted" && result.Payload() != "" {
				t.Fatal("rejected data acquired output bytes")
			}
			if result.Kind() == "payload-invalid" && result.Reason() != "" {
				t.Fatal("decoder details escaped")
			}
		})
	}
}

func TestQueueConversionPipelineTrapsDoNotReturnPartialOutput(t *testing.T) {
	for _, stage := range []string{"decode", "convert", "encode", "target-decode"} {
		t.Run(stage, func(t *testing.T) {
			var calls [4]int
			converter := queueConversionPipeline(&calls)
			switch stage {
			case "decode":
				converter.decode = func(any) Check[queueConversionTestOld] { panic("private payload sentinel") }
			case "convert":
				converter.convert = func(queueConversionTestOld) Migrated[queueConversionTestNew] { panic("private payload sentinel") }
			case "encode":
				converter.encode = func(queueConversionTestNew) any { panic("private payload sentinel") }
			case "target-decode":
				converter.targetDecode = func(any) Check[queueConversionTestNew] { panic("private payload sentinel") }
			}
			result, err := converter.Convert(1, []byte(`{"old":"kept"}`))
			if err == nil || strings.Contains(err.Error(), "sentinel") || result.Kind() != "" || result.Payload() != "" || result.SourceDigest() != "" {
				t.Fatal("trap leaked detail or a usable result", result, err)
			}
		})
	}
}

func TestQueueConversionPipelineEncodingAndTagRefusals(t *testing.T) {
	for _, failure := range []string{"invalid-tag", "unencodable", "undecodable-target"} {
		t.Run(failure, func(t *testing.T) {
			var calls [4]int
			converter := queueConversionPipeline(&calls)
			switch failure {
			case "invalid-tag":
				converter.convert = func(queueConversionTestOld) Migrated[queueConversionTestNew] {
					return Migrated[queueConversionTestNew]{Tag: MigratedTag(77)}
				}
			case "unencodable":
				converter.encode = func(queueConversionTestNew) any { return func() {} }
			case "undecodable-target":
				converter.encode = func(queueConversionTestNew) any { return map[string]any{"wrong": "shape"} }
			}
			result, err := converter.Convert(1, []byte(`{"old":"kept"}`))
			if err == nil || result.Kind() != "" || result.Payload() != "" {
				t.Fatal("invalid target acquired output", result, err)
			}
		})
	}
}

func TestQueueConversionPipelineRefusesBeforeCallingUnboundCode(t *testing.T) {
	var calls [4]int
	converter := queueConversionPipeline(&calls)
	for _, version := range []int{-1, 0, 2, 99} {
		if _, err := converter.Convert(version, []byte(`{"old":"kept"}`)); err == nil {
			t.Fatal("foreign source accepted", version)
		}
	}
	if calls != [4]int{} {
		t.Fatal("wrong source invoked callbacks", calls)
	}
	var empty CompiledQueueConversion[queueConversionTestOld, queueConversionTestNew]
	var absent *CompiledQueueConversion[queueConversionTestOld, queueConversionTestNew]
	for _, value := range []*CompiledQueueConversion[queueConversionTestOld, queueConversionTestNew]{&empty, absent} {
		if value.SourceVersion() != 0 {
			t.Fatal("unbound adapter has a version")
		}
		if _, err := value.Convert(1, nil); err == nil {
			t.Fatal("unbound adapter accepted")
		}
	}
}
