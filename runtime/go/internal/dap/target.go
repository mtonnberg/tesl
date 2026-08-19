package dap

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const targetConnectTimeout = 10 * time.Second

type ProcessTarget struct {
	mutex         sync.Mutex
	command       *exec.Cmd
	waitDone      chan struct{}
	processErr    error
	client        *ControlClient
	eventMutex    sync.Mutex
	eventListener func(TargetEvent)
}

type processLaunchArguments struct {
	Program      string            `json:"program"`
	Args         []string          `json:"args,omitempty"`
	Cwd          string            `json:"cwd,omitempty"`
	Env          map[string]string `json:"env,omitempty"`
	DebugSocket  string            `json:"debugSocket,omitempty"`
	DebugAddress string            `json:"debugAddress,omitempty"`
	DebugPort    int               `json:"debugPort,omitempty"`
	TestName     string            `json:"testName,omitempty"`
	TestKind     string            `json:"testKind,omitempty"`
}

type processAttachArguments struct {
	Socket  string `json:"socket,omitempty"`
	Address string `json:"address,omitempty"`
	Port    int    `json:"port,omitempty"`
}

func NewProcessTarget() *ProcessTarget { return &ProcessTarget{} }

func (target *ProcessTarget) SetEventListener(listener func(TargetEvent)) {
	target.eventMutex.Lock()
	target.eventListener = listener
	target.eventMutex.Unlock()
}

func (target *ProcessTarget) Launch(arguments json.RawMessage) error {
	_, err := target.LaunchBackend(arguments)
	return err
}

func (target *ProcessTarget) Attach(arguments json.RawMessage) error {
	_, err := target.AttachBackend(arguments)
	return err
}

func (target *ProcessTarget) LaunchBackend(data json.RawMessage) (DebugBackend, error) {
	var arguments processLaunchArguments
	if len(data) > 0 {
		if err := json.Unmarshal(data, &arguments); err != nil {
			return nil, fmt.Errorf("invalid launch arguments: %w", err)
		}
	}
	if arguments.Program == "" {
		return nil, errors.New("launch requires program")
	}
	cwd := arguments.Cwd
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("get launch directory: %w", err)
		}
	}
	if !filepath.IsAbs(arguments.Program) && filepath.Dir(arguments.Program) != "." {
		arguments.Program = filepath.Join(cwd, arguments.Program)
	}
	environment := os.Environ()
	for name, value := range arguments.Env {
		environment = setEnvironment(environment, name, value)
	}
	if arguments.TestName != "" {
		environment = setEnvironment(environment, "TESL_TEST_NAME", arguments.TestName)
	}
	if arguments.TestKind != "" {
		environment = setEnvironment(environment, "TESL_TEST_KIND", arguments.TestKind)
	}
	endpoint, err := launchEndpoint(arguments, cwd)
	if err != nil {
		return nil, err
	}
	for name, value := range endpoint.environment {
		environment = setEnvironment(environment, name, value)
	}
	command := exec.Command(arguments.Program, arguments.Args...)
	command.Dir = cwd
	command.Env = environment
	target.mutex.Lock()
	target.processErr = nil
	target.mutex.Unlock()
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("capture debug program stdout: %w", err)
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("capture debug program stderr: %w", err)
	}
	if err := command.Start(); err != nil {
		return nil, fmt.Errorf("start debug program: %w", err)
	}
	waitDone := make(chan struct{})
	go func() {
		err := command.Wait()
		target.mutex.Lock()
		target.processErr = err
		close(waitDone)
		target.mutex.Unlock()
	}()
	go target.streamOutput(stdout, "stdout")
	go target.streamOutput(stderr, "stderr")
	target.mutex.Lock()
	target.command = command
	target.waitDone = waitDone
	target.mutex.Unlock()
	client, err := waitForControlEndpoint(endpoint, command, waitDone, target.processError)
	if err != nil {
		_ = target.Close()
		return nil, err
	}
	target.mutex.Lock()
	target.client = client
	target.mutex.Unlock()
	go target.watchProcess(waitDone)
	return client, nil
}

func (target *ProcessTarget) AttachBackend(data json.RawMessage) (DebugBackend, error) {
	var arguments processAttachArguments
	if len(data) > 0 {
		if err := json.Unmarshal(data, &arguments); err != nil {
			return nil, fmt.Errorf("invalid attach arguments: %w", err)
		}
	}
	var client *ControlClient
	var err error
	switch {
	case arguments.Socket != "":
		client, err = DialControlUnix(arguments.Socket)
	case arguments.Address != "":
		client, err = DialControlTCP(arguments.Address)
	case arguments.Port > 0:
		client, err = DialControlTCP("127.0.0.1:" + strconv.Itoa(arguments.Port))
	default:
		err = errors.New("attach requires socket, address, or port")
	}
	if err != nil {
		return nil, err
	}
	target.mutex.Lock()
	target.client = client
	target.mutex.Unlock()
	return client, nil
}

func (target *ProcessTarget) Close() error {
	target.mutex.Lock()
	client := target.client
	command := target.command
	waitDone := target.waitDone
	target.client = nil
	target.command = nil
	target.waitDone = nil
	target.mutex.Unlock()
	if client != nil {
		client.Close()
	}
	if command == nil || command.Process == nil || command.ProcessState != nil {
		return nil
	}
	_ = command.Process.Kill()
	if waitDone != nil {
		select {
		case <-waitDone:
		case <-time.After(time.Second):
			return errors.New("timed out waiting for debug program to exit")
		}
	}
	return nil
}

func (target *ProcessTarget) streamOutput(reader io.ReadCloser, category string) {
	defer reader.Close()
	buffer := make([]byte, 32<<10)
	for {
		count, err := reader.Read(buffer)
		if count > 0 {
			target.notify(TargetEvent{Event: "output", Body: map[string]string{
				"category": category, "output": string(buffer[:count]),
			}})
		}
		if err != nil {
			return
		}
	}
}

func (target *ProcessTarget) watchProcess(waitDone <-chan struct{}) {
	<-waitDone
	err := target.processError()
	exitCode := 0
	if err != nil {
		exitCode = 1
		if exitError, ok := err.(*exec.ExitError); ok {
			exitCode = exitError.ExitCode()
		}
	}
	target.notify(TargetEvent{Event: "exited", Body: map[string]int{"exitCode": exitCode}})
	target.notify(TargetEvent{Event: "terminated", Body: map[string]int{"exitCode": exitCode}})
}

func (target *ProcessTarget) notify(event TargetEvent) {
	target.eventMutex.Lock()
	listener := target.eventListener
	target.eventMutex.Unlock()
	if listener != nil {
		listener(event)
	}
}

type launchEndpointSpec struct {
	socket      string
	address     string
	environment map[string]string
}

func launchEndpoint(arguments processLaunchArguments, cwd string) (launchEndpointSpec, error) {
	if arguments.DebugAddress != "" {
		if arguments.DebugPort > 0 {
			return launchEndpointSpec{}, errors.New("launch cannot set both debugAddress and debugPort")
		}
		_, port, err := splitAddress(arguments.DebugAddress)
		if err != nil {
			return launchEndpointSpec{}, err
		}
		return launchEndpointSpec{address: arguments.DebugAddress, environment: map[string]string{
			"TESL_DEBUG": "1", "TESL_DEBUG_PORT": strconv.Itoa(port),
		}}, nil
	}
	if arguments.DebugPort > 0 {
		return launchEndpointSpec{address: "127.0.0.1:" + strconv.Itoa(arguments.DebugPort), environment: map[string]string{
			"TESL_DEBUG": "1", "TESL_DEBUG_PORT": strconv.Itoa(arguments.DebugPort),
		}}, nil
	}
	socket := arguments.DebugSocket
	if socket == "" {
		socket = filepath.Join(cwd, ".tesl-stuff", "debug.sock")
	}
	return launchEndpointSpec{socket: socket, environment: map[string]string{
		"TESL_DEBUG": "1", "TESL_DEBUG_ROOT": cwd, "TESL_DEBUG_SOCKET": socket,
	}}, nil
}

func splitAddress(address string) (string, int, error) {
	separator := strings.LastIndex(address, ":")
	if separator <= 0 || separator == len(address)-1 {
		return "", 0, fmt.Errorf("invalid debug address %q", address)
	}
	port, err := strconv.Atoi(address[separator+1:])
	if err != nil || port <= 0 || port > 65535 {
		return "", 0, fmt.Errorf("invalid debug address %q", address)
	}
	return address[:separator], port, nil
}

func waitForControlEndpoint(endpoint launchEndpointSpec, command *exec.Cmd, waitDone <-chan struct{}, processError func() error) (*ControlClient, error) {
	deadline := time.Now().Add(targetConnectTimeout)
	for time.Now().Before(deadline) {
		var client *ControlClient
		var err error
		if endpoint.socket != "" {
			client, err = DialControlUnix(endpoint.socket)
		} else {
			client, err = DialControlTCP(endpoint.address)
		}
		if err == nil {
			return client, nil
		}
		select {
		case <-waitDone:
			return nil, fmt.Errorf("debug program exited before control endpoint: %w", processError())
		case <-time.After(25 * time.Millisecond):
		}
	}
	return nil, fmt.Errorf("timed out waiting for debug endpoint for process %d", command.Process.Pid)
}

func (target *ProcessTarget) processError() error {
	target.mutex.Lock()
	defer target.mutex.Unlock()
	return target.processErr
}

func setEnvironment(environment []string, name, value string) []string {
	prefix := name + "="
	filtered := environment[:0]
	for _, entry := range environment {
		if !strings.HasPrefix(entry, prefix) {
			filtered = append(filtered, entry)
		}
	}
	return append(filtered, prefix+value)
}
