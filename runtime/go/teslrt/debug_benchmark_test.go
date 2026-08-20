package teslrt

import "testing"

func BenchmarkCheckpointUnattached(b *testing.B) {
	debugger := NewDebugger()
	frame := DebugFrame{
		Version: DebugABIVersion, ID: "benchmark", Function: "benchmark",
		Location: SourceLocation{File: "benchmark.tesl", Line: 1, Column: 1},
	}
	b.ResetTimer()
	for range b.N {
		debugger.Checkpoint(frame)
	}
}

func BenchmarkDebugEnterLeaveUnattached(b *testing.B) {
	debugger := NewDebugger()
	frame := DebugFrame{
		Version: DebugABIVersion, ID: "benchmark", Function: "benchmark",
		Location: SourceLocation{File: "benchmark.tesl", Line: 1, Column: 1},
	}
	b.ResetTimer()
	for range b.N {
		scope := debugger.Enter(frame)
		scope.Leave()
	}
}
