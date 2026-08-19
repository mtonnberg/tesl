package dap

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"sync/atomic"

	"tesl.dev/runtime/go/teslrt"
)

const controlClientMaxLine = 1 << 20

type controlResult struct {
	response teslrt.DebugControlResponse
	err      error
}

// ControlClient adapts a running teslrt control endpoint to DebugBackend.
// Requests are serialized; stopped events are consumed concurrently.
type ControlClient struct {
	connection net.Conn
	write      sync.Mutex
	mutex      sync.Mutex
	listener   teslrt.DebugListener
	pending    map[string]chan controlResult
	nextID     atomic.Uint64
	done       chan struct{}
	doneOnce   sync.Once
	closeOnce  sync.Once
	err        error
}

var _ DebugBackend = (*ControlClient)(nil)

func (client *ControlClient) SnapshotState() (teslrt.DebugSnapshot, error) {
	result, err := client.call(teslrt.DebugControlRequest{Command: "snapshot"})
	if err != nil {
		return teslrt.DebugSnapshot{}, err
	}
	var snapshot teslrt.DebugSnapshot
	if err := json.Unmarshal(result, &snapshot); err != nil {
		return teslrt.DebugSnapshot{}, fmt.Errorf("dap: decode debug snapshot: %w", err)
	}
	return snapshot, nil
}

func (client *ControlClient) Ping() error {
	_, err := client.call(teslrt.DebugControlRequest{Command: "ping"})
	return err
}

func (client *ControlClient) Detach() error {
	_, err := client.call(teslrt.DebugControlRequest{Command: "detach"})
	return err
}

func DialControlUnix(path string) (*ControlClient, error) {
	connection, err := net.Dial("unix", path)
	if err != nil {
		return nil, fmt.Errorf("dap: connect to Unix debug endpoint: %w", err)
	}
	return NewControlClient(connection)
}

func DialControlTCP(address string) (*ControlClient, error) {
	connection, err := net.Dial("tcp4", address)
	if err != nil {
		return nil, fmt.Errorf("dap: connect to TCP debug endpoint: %w", err)
	}
	return NewControlClient(connection)
}

func NewControlClient(connection net.Conn) (*ControlClient, error) {
	client := &ControlClient{
		connection: connection,
		pending:    make(map[string]chan controlResult),
		done:       make(chan struct{}),
	}
	go client.readLoop()
	result, err := client.call(teslrt.DebugControlRequest{Command: "handshake"})
	if err != nil {
		client.Close()
		return nil, err
	}
	var handshake teslrt.DebugHandshake
	if err := json.Unmarshal(result, &handshake); err != nil {
		client.Close()
		return nil, fmt.Errorf("dap: decode debug handshake: %w", err)
	}
	if handshake.Version != teslrt.DebugProtocolVersion || handshake.ABIVersion != teslrt.DebugABIVersion {
		client.Close()
		return nil, fmt.Errorf("dap: incompatible debug endpoint version %d/%d", handshake.Version, handshake.ABIVersion)
	}
	return client, nil
}

func (client *ControlClient) Attach(listener teslrt.DebugListener) func() {
	client.mutex.Lock()
	client.listener = listener
	client.mutex.Unlock()
	return func() {
		client.mutex.Lock()
		client.listener = nil
		client.mutex.Unlock()
	}
}

func (client *ControlClient) ClearBreakpoints() error {
	_, err := client.call(teslrt.DebugControlRequest{Command: "clear-breakpoints"})
	return err
}

func (client *ControlClient) SetBreakpointSpecs(specifications []teslrt.DebugBreakpointSpec) ([]teslrt.DebugBreakpointResult, error) {
	result, err := client.call(teslrt.DebugControlRequest{Command: "set-breakpoints", Breakpoints: specifications})
	if err != nil {
		return nil, err
	}
	var breakpoints []teslrt.DebugBreakpointResult
	if err := json.Unmarshal(result, &breakpoints); err != nil {
		return nil, fmt.Errorf("dap: decode breakpoint response: %w", err)
	}
	return breakpoints, nil
}

func (client *ControlClient) Pause() error {
	_, err := client.call(teslrt.DebugControlRequest{Command: "pause"})
	return err
}

func (client *ControlClient) Continue() error {
	_, err := client.call(teslrt.DebugControlRequest{Command: "continue"})
	return err
}

func (client *ControlClient) Step(mode teslrt.DebugStepMode) error {
	command := map[teslrt.DebugStepMode]string{
		teslrt.DebugStepIn: "step-in", teslrt.DebugStepOver: "step-over", teslrt.DebugStepOut: "step-out",
	}[mode]
	if command == "" {
		return errors.New("dap: invalid step mode")
	}
	_, err := client.call(teslrt.DebugControlRequest{Command: command})
	return err
}

func (client *ControlClient) Snapshot() (teslrt.DebugFrame, bool, error) {
	snapshot, err := client.SnapshotState()
	return snapshot.Frame, snapshot.Paused, err
}

func (client *ControlClient) StackSnapshot() ([]teslrt.DebugFrame, error) {
	snapshot, err := client.SnapshotState()
	if err != nil {
		return nil, err
	}
	return snapshot.Stack, nil
}

func (client *ControlClient) Close() {
	client.closeOnce.Do(func() {
		_ = client.connection.Close()
		client.finish(errors.New("dap: debug control client closed"))
	})
}

func (client *ControlClient) call(request teslrt.DebugControlRequest) (json.RawMessage, error) {
	request.ID = strconv.FormatUint(client.nextID.Add(1), 10)
	response := make(chan controlResult, 1)
	client.mutex.Lock()
	if client.err != nil {
		err := client.err
		client.mutex.Unlock()
		return nil, err
	}
	client.pending[request.ID] = response
	client.mutex.Unlock()
	client.write.Lock()
	err := json.NewEncoder(client.connection).Encode(request)
	client.write.Unlock()
	if err != nil {
		client.finish(err)
		return nil, err
	}
	select {
	case result := <-response:
		if result.err != nil {
			return nil, result.err
		}
		if result.response.Error != nil {
			return nil, fmt.Errorf("dap: debug control %s: %s", result.response.Error.Code, result.response.Error.Message)
		}
		return result.response.Result, nil
	case <-client.done:
		// A detach response is followed by an intentional connection close. The read loop can
		// publish both at nearly the same time; prefer a response already queued before reporting
		// the endpoint's EOF.
		select {
		case result := <-response:
			if result.err != nil {
				return nil, result.err
			}
			if result.response.Error != nil {
				return nil, fmt.Errorf("dap: debug control %s: %s", result.response.Error.Code, result.response.Error.Message)
			}
			return result.response.Result, nil
		default:
		}
		client.mutex.Lock()
		err := client.err
		client.mutex.Unlock()
		if err == nil {
			err = errors.New("dap: debug control client stopped")
		}
		return nil, err
	}
}

func (client *ControlClient) readLoop() {
	scanner := bufio.NewScanner(client.connection)
	scanner.Buffer(make([]byte, 4096), controlClientMaxLine)
	for scanner.Scan() {
		line := scanner.Bytes()
		var event struct {
			Event string `json:"event"`
		}
		if err := json.Unmarshal(line, &event); err != nil {
			client.finish(fmt.Errorf("dap: decode debug control message: %w", err))
			return
		}
		if event.Event != "" {
			var stopped teslrt.DebugStoppedEvent
			if err := json.Unmarshal(line, &stopped); err != nil {
				client.finish(fmt.Errorf("dap: decode stopped event: %w", err))
				return
			}
			client.mutex.Lock()
			listener := client.listener
			client.mutex.Unlock()
			if listener != nil {
				listener(teslrt.DebugEvent{Kind: stopped.Event, Frame: stopped.Frame, Stack: stopped.Stack})
			}
			continue
		}
		var response teslrt.DebugControlResponse
		if err := json.Unmarshal(line, &response); err != nil {
			client.finish(fmt.Errorf("dap: decode debug control response: %w", err))
			return
		}
		client.mutex.Lock()
		pending := client.pending[response.ID]
		delete(client.pending, response.ID)
		client.mutex.Unlock()
		if pending != nil {
			pending <- controlResult{response: response}
		}
	}
	if err := scanner.Err(); err != nil {
		client.finish(err)
	} else {
		client.finish(errors.New("dap: debug control endpoint closed"))
	}
}

func (client *ControlClient) finish(err error) {
	client.doneOnce.Do(func() {
		client.mutex.Lock()
		client.err = err
		pending := client.pending
		client.pending = make(map[string]chan controlResult)
		client.mutex.Unlock()
		close(client.done)
		for _, response := range pending {
			response <- controlResult{err: err}
		}
	})
}
