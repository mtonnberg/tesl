package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"tesl.dev/runtime/go/internal/dap"
	"tesl.dev/runtime/go/teslrt"
)

type inspectSource struct {
	File string `json:"file"`
	Line int    `json:"line"`
}

type inspectBreakpoint struct {
	Line      int    `json:"line"`
	Condition string `json:"condition,omitempty"`
	Hit       string `json:"hit,omitempty"`
}

type inspectLocal struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Value string `json:"value"`
}

type inspectOutput struct {
	Version    int                     `json:"version"`
	Stopped    bool                    `json:"stopped"`
	Reason     string                  `json:"reason,omitempty"`
	Source     *inspectSource          `json:"source,omitempty"`
	Breakpoint *inspectBreakpoint      `json:"breakpoint,omitempty"`
	Locals     []inspectLocal          `json:"locals"`
	Domain     teslrt.DebugDomainState `json:"domain"`
	SQL        *teslrt.DebugSQLCapture `json:"sql,omitempty"`
}

type stringFlags []string

func (values *stringFlags) String() string { return strings.Join(*values, ",") }

func (values *stringFlags) Set(value string) error {
	if strings.TrimSpace(value) == "" {
		return fmt.Errorf("value must not be empty")
	}
	*values = append(*values, value)
	return nil
}

func main() {
	socket := flag.String("socket", "", "Unix debug socket")
	tcp := flag.String("tcp", "", "loopback debug address")
	file := flag.String("file", "", "Tesl source file to compile and inspect")
	compiler := flag.String("compiler", "", "Tesl compiler executable for source inspection")
	mode := flag.String("mode", "program", "source inspection mode: program or test")
	continueMode := flag.Bool("continue", false, "capture every breakpoint stop until target completion")
	operation := flag.String("operation", "snapshot", "snapshot, ping, or detach")
	timeoutMS := flag.Int("timeout-ms", 30000, "connection timeout in milliseconds")
	var breakAt stringFlags
	flag.Var(&breakAt, "break-at", "arm a breakpoint as FILE:LINE; repeatable")
	when := flag.String("when", "", "condition applied to each --break-at")
	hit := flag.String("hit", "", "hit condition applied to each --break-at")
	flag.Parse()
	if *file != "" {
		sourceInspect(*file, *compiler, *mode, breakAt, *when, *hit, *timeoutMS, *continueMode)
		return
	}
	if (*socket == "") == (*tcp == "") {
		fail("exactly one of -socket or -tcp is required")
	}
	if *timeoutMS < 1 {
		fail("-timeout-ms must be positive")
	}
	if *operation != "snapshot" && *operation != "ping" && *operation != "detach" {
		fail("unsupported operation %q", *operation)
	}

	connection, err := dial(*socket, *tcp, time.Duration(*timeoutMS)*time.Millisecond)
	if err != nil {
		fail("connect debug endpoint: %v", err)
	}
	client, err := dap.NewControlClient(connection)
	if err != nil {
		fail("handshake: %v", err)
	}
	defer client.Close()
	if len(breakAt) > 0 && *operation != "snapshot" {
		fail("--break-at is valid only with snapshot operation")
	}
	if len(breakAt) > 0 {
		specifications := make([]teslrt.DebugBreakpointSpec, 0, len(breakAt))
		for index, value := range breakAt {
			file, line, err := parseBreakpoint(value)
			if err != nil {
				fail("invalid --break-at #%d: %v", index+1, err)
			}
			specifications = append(specifications, teslrt.DebugBreakpointSpec{
				ID: fmt.Sprintf("inspect-bp-%d", index+1), File: file, Line: line,
				Condition: *when, Hit: *hit,
			})
		}
		results, err := client.SetBreakpointSpecs(specifications)
		if err != nil {
			fail("set breakpoints: %v", err)
		}
		for index, result := range results {
			if !result.Verified {
				fail("breakpoint #%d is not verified: %s", index+1, result.Message)
			}
		}
	}

	switch *operation {
	case "ping":
		if err := client.Ping(); err != nil {
			fail("ping: %v", err)
		}
		writeJSON(map[string]any{"version": 2, "ok": true})
	case "detach":
		if err := client.Detach(); err != nil {
			fail("detach: %v", err)
		}
		writeJSON(map[string]any{"version": 2, "detached": true})
	case "snapshot":
		var breakpoint *inspectBreakpoint
		if len(breakAt) > 0 {
			stopped := make(chan struct{}, 1)
			detach := client.Attach(func(event teslrt.DebugEvent) {
				if event.Kind == "stopped" {
					select {
					case stopped <- struct{}{}:
					default:
					}
				}
			})
			defer detach()
			select {
			case <-stopped:
			case <-time.After(time.Duration(*timeoutMS) * time.Millisecond):
				snapshot, err := client.SnapshotState()
				if err != nil {
					fail("snapshot after breakpoint timeout: %v", err)
				}
				writeJSON(snapshotOutput(snapshot, "breakpoint-not-hit", breakpointFromFlags(breakAt, *when, *hit)))
				return
			}
			breakpoint = breakpointFromFlags(breakAt, *when, *hit)
		}
		snapshot, err := client.SnapshotState()
		if err != nil {
			fail("snapshot: %v", err)
		}
		writeJSON(snapshotOutput(snapshot, "", breakpoint))
	}
}

func sourceInspect(file, compiler, mode string, breakAt []string, when, hit string, timeoutMS int, continueMode bool) {
	if len(breakAt) == 0 {
		fail("source inspection requires at least one --break-at LINE spec")
	}
	if mode != "program" && mode != "test" {
		fail("--mode must be program or test")
	}
	absFile, err := filepath.Abs(file)
	if err != nil {
		fail("resolve source file: %v", err)
	}
	workingDir := filepath.Dir(absFile)
	specifications, err := sourceBreakpointSpecs(absFile, breakAt, when, hit)
	if err != nil {
		fail("parse breakpoint: %v", err)
	}
	arguments := map[string]any{
		"program": absFile,
		"cwd":     workingDir,
		"mode":    mode,
	}
	if compiler != "" {
		arguments["compiler"] = compiler
	}
	payload, err := json.Marshal(arguments)
	if err != nil {
		fail("encode launch arguments: %v", err)
	}
	target := dap.NewProcessTarget()
	defer func() { _ = target.Close() }()
	exited := make(chan struct{}, 1)
	var targetOutput strings.Builder
	target.SetEventListener(func(event dap.TargetEvent) {
		switch event.Event {
		case "output":
			if body, ok := event.Body.(map[string]string); ok {
				targetOutput.WriteString(body["output"])
			}
		case "exited":
			select {
			case exited <- struct{}{}:
			default:
			}
		}
	})
	backend, err := target.LaunchBackend(payload)
	if err != nil {
		fail("launch Go debug target: %v", err)
	}
	client, ok := backend.(*dap.ControlClient)
	if !ok {
		fail("Go debug target did not return a control client")
	}
	if client == nil {
		fail("Go debug target did not return a control client")
	}
	stopped := make(chan teslrt.DebugFrame, 1)
	detach := client.Attach(func(event teslrt.DebugEvent) {
		if event.Kind == "stopped" {
			select {
			case stopped <- event.Frame:
			default:
			}
		}
	})
	defer detach()
	results, err := client.SetBreakpointSpecs(specifications)
	if err != nil {
		fail("set breakpoints: %v", err)
	}
	for index, result := range results {
		if !result.Verified {
			fail("breakpoint #%d is not verified: %s", index+1, result.Message)
		}
	}
	if err := client.ConfigurationDone(); err != nil {
		fail("finish breakpoint configuration: %v", err)
	}
	if continueMode {
		snapshots := make([]inspectOutput, 0, len(specifications))
		completed := false
		deadline := time.NewTimer(time.Duration(timeoutMS) * time.Millisecond)
		defer deadline.Stop()
		for {
			select {
			case <-stopped:
				snapshot, err := client.SnapshotState()
				if err != nil {
					fail("snapshot: %v", err)
				}
				snapshots = append(snapshots, snapshotOutput(snapshot, "", breakpointFromSnapshot(snapshot, breakAt, when, hit)))
				if err := client.Continue(); err != nil {
					fail("continue Go debug target: %v", err)
				}
			case <-exited:
				completed = true
				writeJSON(map[string]any{"mode": "continue", "snapshots": snapshots, "completed": completed})
				return
			case <-deadline.C:
				writeJSON(map[string]any{"mode": "continue", "snapshots": snapshots, "completed": completed})
				return
			}
		}
	}
	select {
	case <-stopped:
		snapshot, err := client.SnapshotState()
		if err != nil {
			fail("snapshot: %v\n%s", err, strings.TrimSpace(targetOutput.String()))
		}
		writeJSON(snapshotOutput(snapshot, "", breakpointFromSnapshot(snapshot, breakAt, when, hit)))
		_ = client.Continue()
	case <-time.After(time.Duration(timeoutMS) * time.Millisecond):
		snapshot, err := client.SnapshotState()
		if err != nil {
			fail("snapshot after breakpoint timeout: %v", err)
		}
		writeJSON(snapshotOutput(snapshot, "breakpoint-not-hit", breakpointFromSourceFlags(breakAt, when, hit)))
	}
}

func sourceBreakpointSpecs(file string, values []string, when, hit string) ([]teslrt.DebugBreakpointSpec, error) {
	result := make([]teslrt.DebugBreakpointSpec, 0, len(values))
	for _, value := range values {
		chunks := []string{value}
		if !strings.Contains(value, ":") {
			chunks = strings.Split(value, ",")
		}
		for _, chunk := range chunks {
			chunk = strings.TrimSpace(chunk)
			if chunk == "" {
				continue
			}
			line, condition, hitCondition, err := parseSourceBreakpoint(chunk, when, hit)
			if err != nil {
				return nil, err
			}
			result = append(result, teslrt.DebugBreakpointSpec{
				ID: fmt.Sprintf("inspect-bp-%d", len(result)+1), File: file, Line: line,
				Condition: condition, Hit: hitCondition,
			})
		}
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("no valid breakpoint specs")
	}
	return result, nil
}

func parseSourceBreakpoint(value, defaultCondition, defaultHit string) (int, string, string, error) {
	lineText, suffix := value, ""
	if separator := strings.IndexByte(value, ':'); separator >= 0 {
		lineText, suffix = value[:separator], strings.TrimSpace(value[separator+1:])
	}
	line, err := strconv.Atoi(strings.TrimSpace(lineText))
	if err != nil || line < 1 {
		return 0, "", "", fmt.Errorf("expected positive LINE, got %q", value)
	}
	if suffix == "" || isColumn(suffix) {
		return line, defaultCondition, defaultHit, nil
	}
	if isHit(suffix) {
		return line, defaultCondition, suffix, nil
	}
	return line, suffix, defaultHit, nil
}

func isColumn(value string) bool {
	_, err := strconv.Atoi(strings.TrimSpace(value))
	return err == nil
}

func isHit(value string) bool {
	value = strings.TrimSpace(value)
	for _, operator := range []string{"==", ">=", "<=", ">", "<", "%"} {
		if strings.HasPrefix(value, operator) {
			_, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(value, operator)))
			return err == nil
		}
	}
	return false
}

func breakpointFromSourceFlags(values []string, condition, hit string) *inspectBreakpoint {
	if len(values) == 0 {
		return nil
	}
	first, _, _ := strings.Cut(values[0], ",")
	line, parsedCondition, parsedHit, err := parseSourceBreakpoint(first, condition, hit)
	if err != nil {
		return nil
	}
	return &inspectBreakpoint{Line: line, Condition: parsedCondition, Hit: parsedHit}
}

func breakpointFromSnapshot(snapshot teslrt.DebugSnapshot, values []string, condition, hit string) *inspectBreakpoint {
	breakpoint := breakpointFromSourceFlags(values, condition, hit)
	if breakpoint == nil {
		breakpoint = &inspectBreakpoint{}
	}
	breakpoint.Line = snapshot.Frame.Location.Line
	return breakpoint
}

func snapshotOutput(snapshot teslrt.DebugSnapshot, reason string, breakpoints ...*inspectBreakpoint) inspectOutput {
	locals := make([]inspectLocal, 0, len(snapshot.Frame.Locals))
	for _, local := range snapshot.Frame.Locals {
		locals = append(locals, inspectLocal{Name: local.Name, Type: local.Type, Value: local.Value.Display})
	}
	output := inspectOutput{
		Version: 2, Stopped: snapshot.Paused, Reason: reason, Locals: locals,
		Domain: snapshot.Runtime.Domain, SQL: snapshot.Runtime.SQL,
	}
	if len(breakpoints) > 0 {
		output.Breakpoint = breakpoints[0]
	}
	if snapshot.Frame.Location.File != "" || snapshot.Frame.Location.Line != 0 {
		output.Source = &inspectSource{File: snapshot.Frame.Location.File, Line: snapshot.Frame.Location.Line}
	}
	return output
}

func breakpointFromFlags(values []string, condition, hit string) *inspectBreakpoint {
	if len(values) == 0 {
		return nil
	}
	_, line, err := parseBreakpoint(values[0])
	if err != nil {
		return nil
	}
	return &inspectBreakpoint{Line: line, Condition: condition, Hit: hit}
}

func parseBreakpoint(value string) (string, int, error) {
	separator := strings.LastIndexByte(value, ':')
	if separator <= 0 || separator == len(value)-1 {
		return "", 0, fmt.Errorf("expected FILE:LINE")
	}
	line, err := strconv.Atoi(value[separator+1:])
	if err != nil || line < 1 {
		return "", 0, fmt.Errorf("line must be a positive integer")
	}
	return value[:separator], line, nil
}

func dial(socket, tcp string, timeout time.Duration) (net.Conn, error) {
	if socket != "" {
		return net.DialTimeout("unix", socket, timeout)
	}
	return net.DialTimeout("tcp4", tcp, timeout)
}

func writeJSON(value any) {
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		fail("write JSON: %v", err)
	}
}

func fail(format string, arguments ...any) {
	_, _ = fmt.Fprintf(os.Stderr, "tesl-debug-inspect: "+format+"\n", arguments...)
	os.Exit(1)
}
