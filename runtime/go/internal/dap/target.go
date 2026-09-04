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

	"tesl.dev/runtime/go/teslrt"
)

const targetConnectTimeout = 10 * time.Second

type ProcessTarget struct {
	mutex         sync.Mutex
	command       *exec.Cmd
	waitDone      chan struct{}
	processErr    error
	cleanup       func()
	client        *ControlClient
	eventMutex    sync.Mutex
	eventListener func(TargetEvent)
}

type processLaunchArguments struct {
	Program      string            `json:"program"`
	Args         []string          `json:"args,omitempty"`
	Cwd          string            `json:"cwd,omitempty"`
	Env          map[string]string `json:"env,omitempty"`
	Compiler     string            `json:"compiler,omitempty"`
	Mode         string            `json:"mode,omitempty"`
	OutDir       string            `json:"outDir,omitempty"`
	DebugSocket  string            `json:"debugSocket,omitempty"`
	DebugAddress string            `json:"debugAddress,omitempty"`
	DebugPort    int               `json:"debugPort,omitempty"`
	TestName     string            `json:"testName,omitempty"`
	TestKind     string            `json:"testKind,omitempty"`
}

type processAttachArguments struct {
	Project string `json:"project,omitempty"`
	Socket  string `json:"socket,omitempty"`
	Address string `json:"address,omitempty"`
	Port    int    `json:"port,omitempty"`
	// Token authenticates a TCP attach. When omitted alongside an explicit
	// address/port, it is read from <project>/.tesl-stuff/debug.token if project is set.
	Token string `json:"token,omitempty"`
}

// ProjectEndpoint is the attach endpoint discovered under <project>/.tesl-stuff/:
// either a Unix socket, or a loopback address plus the token that authenticates it.
type ProjectEndpoint struct {
	Socket  string
	Address string
	Token   string
}

// DiscoverProjectEndpoint prefers the Unix socket, then falls back to the TCP
// port file, which the runtime always writes together with its token file.
func DiscoverProjectEndpoint(project string) (ProjectEndpoint, error) {
	stuff := filepath.Join(project, ".tesl-stuff")
	socket := filepath.Join(stuff, "debug.sock")
	if _, err := os.Stat(socket); err == nil {
		return ProjectEndpoint{Socket: socket}, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return ProjectEndpoint{}, fmt.Errorf("inspect debug socket: %w", err)
	}
	portPath := filepath.Join(stuff, teslrt.DebugPortFile)
	contents, err := os.ReadFile(portPath) // #nosec G304 -- read only the selected project's debug port.
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ProjectEndpoint{}, fmt.Errorf("no debug endpoint under %s", stuff)
		}
		return ProjectEndpoint{}, fmt.Errorf("read debug port: %w", err)
	}
	port := strings.TrimSpace(string(contents))
	if _, err := strconv.Atoi(port); err != nil || port == "" {
		return ProjectEndpoint{}, fmt.Errorf("debug port file %s is not a port number", portPath)
	}
	token, err := ReadDebugToken(filepath.Join(stuff, teslrt.DebugTokenFile))
	if err != nil {
		return ProjectEndpoint{}, err
	}
	return ProjectEndpoint{Address: "127.0.0.1:" + port, Token: token}, nil
}

// ReadDebugToken reads the credential the runtime wrote beside its port file.
func ReadDebugToken(path string) (string, error) {
	contents, err := os.ReadFile(path) // #nosec G304 -- read only the selected project's debug token.
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("debug endpoint is TCP but %s is missing; the runtime writes it beside %s", path, teslrt.DebugPortFile)
		}
		return "", fmt.Errorf("read debug token: %w", err)
	}
	token := strings.TrimSpace(string(contents))
	if err := teslrt.ValidateDebugToken(token); err != nil {
		return "", fmt.Errorf("%s: %w", path, err)
	}
	return token, nil
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
	program, programArgs, cleanup, err := target.prepareProgram(arguments, cwd)
	if err != nil {
		return nil, err
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
		cleanup()
		return nil, err
	}
	programCleanup := cleanup
	cleanup = func() {
		endpoint.cleanup()
		programCleanup()
	}
	for name, value := range endpoint.environment {
		environment = setEnvironment(environment, name, value)
	}
	command := exec.Command(program, programArgs...) // #nosec G204 -- target is an explicit local debug launch.
	command.Dir = cwd
	command.Env = environment
	configureChildProcess(command)
	target.mutex.Lock()
	target.processErr = nil
	target.mutex.Unlock()
	stdout, err := command.StdoutPipe()
	if err != nil {
		cleanup()
		return nil, fmt.Errorf("capture debug program stdout: %w", err)
	}
	if stdout == nil {
		cleanup()
		return nil, errors.New("capture debug program stdout: pipe is nil")
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		cleanup()
		return nil, fmt.Errorf("capture debug program stderr: %w", err)
	}
	if stderr == nil {
		cleanup()
		return nil, errors.New("capture debug program stderr: pipe is nil")
	}
	if err := command.Start(); err != nil {
		cleanup()
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
	target.cleanup = cleanup
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
		client, err = DialControlTCP(arguments.Address, attachToken(arguments))
	case arguments.Port > 0:
		client, err = DialControlTCP("127.0.0.1:"+strconv.Itoa(arguments.Port), attachToken(arguments))
	case arguments.Project != "":
		client, err = dialProjectEndpoint(arguments.Project)
	default:
		err = errors.New("attach requires project, socket, address, or port")
	}
	if err != nil {
		return nil, err
	}
	target.mutex.Lock()
	target.client = client
	target.mutex.Unlock()
	return client, nil
}

// attachToken resolves the credential for an explicit TCP attach: the token
// argument, else the project's token file (the editor's `port` + default
// `project` configuration), else nothing — the endpoint will refuse.
func attachToken(arguments processAttachArguments) string {
	if arguments.Token != "" || arguments.Project == "" {
		return arguments.Token
	}
	token, err := ReadDebugToken(filepath.Join(arguments.Project, ".tesl-stuff", teslrt.DebugTokenFile))
	if err != nil {
		return ""
	}
	return token
}

func dialProjectEndpoint(project string) (*ControlClient, error) {
	endpoint, err := DiscoverProjectEndpoint(project)
	if err != nil {
		return nil, err
	}
	if endpoint.Socket != "" {
		return DialControlUnix(endpoint.Socket)
	}
	return DialControlTCP(endpoint.Address, endpoint.Token)
}

func (target *ProcessTarget) Close() error {
	target.mutex.Lock()
	client := target.client
	command := target.command
	waitDone := target.waitDone
	cleanup := target.cleanup
	target.client = nil
	target.command = nil
	target.waitDone = nil
	target.cleanup = nil
	target.mutex.Unlock()
	if client != nil {
		client.Close()
	}
	if command == nil || command.Process == nil || command.ProcessState != nil {
		if cleanup != nil {
			cleanup()
		}
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
	if cleanup != nil {
		cleanup()
	}
	return nil
}

func (target *ProcessTarget) streamOutput(reader io.ReadCloser, category string) {
	defer func() { _ = reader.Close() }()
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
	target.mutex.Lock()
	cleanup := target.cleanup
	target.cleanup = nil
	target.mutex.Unlock()
	if cleanup != nil {
		cleanup()
	}
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

func (target *ProcessTarget) prepareProgram(arguments processLaunchArguments, cwd string) (string, []string, func(), error) {
	if strings.ToLower(filepath.Ext(arguments.Program)) != ".tesl" {
		return arguments.Program, arguments.Args, func() {}, nil
	}

	outDir := arguments.OutDir
	cleanupDir := ""
	if outDir == "" {
		var err error
		cleanupDir, err = os.MkdirTemp("", "tesl-go-debug-")
		if err != nil {
			return "", nil, nil, fmt.Errorf("create generated Go directory: %w", err)
		}
		outDir = filepath.Join(cleanupDir, "generated")
	} else if !filepath.IsAbs(outDir) {
		outDir = filepath.Join(cwd, outDir)
	}
	cleanup := func() {
		if cleanupDir != "" {
			_ = os.RemoveAll(cleanupDir)
		}
	}
	fail := func(err error) (string, []string, func(), error) {
		cleanup()
		return "", nil, nil, err
	}

	compiler := arguments.Compiler
	if compiler == "" {
		compiler = os.Getenv("TESL_COMPILER")
	}
	if compiler == "" {
		compiler = "tesl"
	}
	emitCommand := exec.Command(compiler, "--backend", "go", arguments.Program, "--out", outDir, "--debug") // #nosec G204,G702 -- compiler is an explicit local tool.
	emitCommand.Dir = cwd
	if output, err := emitCommand.CombinedOutput(); err != nil {
		return fail(fmt.Errorf("emit debug Go for %s: %w\n%s", arguments.Program, err, strings.TrimSpace(string(output))))
	}

	binary, buildArgs, err := generatedGoBuild(outDir, arguments.Mode)
	if err != nil {
		return fail(err)
	}
	buildCommand := exec.Command("go", buildArgs...) // #nosec G204 -- build arguments come from the generated local module.
	buildCommand.Dir = outDir
	if output, err := buildCommand.CombinedOutput(); err != nil {
		return fail(fmt.Errorf("build debug Go for %s: %w\n%s", arguments.Program, err, strings.TrimSpace(string(output))))
	}
	return binary, arguments.Args, cleanup, nil
}

func generatedGoBuild(outDir, mode string) (string, []string, error) {
	binary := filepath.Join(outDir, "tesl-debug-target")
	if mode == "test" {
		matches, err := filepath.Glob(filepath.Join(outDir, "internal", "*", "module_test.go"))
		if err != nil {
			return "", nil, fmt.Errorf("find generated Go test package: %w", err)
		}
		if len(matches) != 1 {
			return "", nil, fmt.Errorf("expected one generated Go test package, found %d", len(matches))
		}
		packageDir := filepath.Dir(matches[0])
		relative, err := filepath.Rel(outDir, packageDir)
		if err != nil {
			return "", nil, fmt.Errorf("resolve generated Go test package: %w", err)
		}
		return binary, []string{"test", "-c", "-o", binary, "./" + filepath.ToSlash(relative)}, nil
	}
	return binary, []string{"build", "-o", binary, "./cmd/app"}, nil
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
	token       string
	environment map[string]string
	cleanup     func()
}

// launchEndpoint chooses the child's control endpoint. For TCP launches the
// launcher mints the token itself and hands it to the child through
// teslrt.DebugTokenEnv, so it can dial without waiting for the token file.
func launchEndpoint(arguments processLaunchArguments, cwd string) (launchEndpointSpec, error) {
	if arguments.DebugAddress != "" || arguments.DebugPort > 0 {
		if arguments.DebugAddress != "" && arguments.DebugPort > 0 {
			return launchEndpointSpec{}, errors.New("launch cannot set both debugAddress and debugPort")
		}
		address, port := arguments.DebugAddress, arguments.DebugPort
		if address != "" {
			var err error
			if _, port, err = splitAddress(address); err != nil {
				return launchEndpointSpec{}, err
			}
		} else {
			address = "127.0.0.1:" + strconv.Itoa(port)
		}
		token, err := teslrt.NewDebugToken()
		if err != nil {
			return launchEndpointSpec{}, err
		}
		environment := map[string]string{
			"TESL_DEBUG": "1", "TESL_DEBUG_PORT": strconv.Itoa(port), "TESL_DEBUG_ROOT": cwd,
			teslrt.DebugTokenEnv: token,
		}
		if strings.EqualFold(filepath.Ext(arguments.Program), ".tesl") {
			environment["TESL_DEBUG_WAIT"] = "1"
		}
		return launchEndpointSpec{address: address, token: token, environment: environment, cleanup: func() {}}, nil
	}
	socket := arguments.DebugSocket
	cleanup := func() {}
	if socket == "" {
		// Unix sockaddr paths are short (typically 104-108 bytes). Keep launch
		// endpoints in a private, owner-only runtime directory rather than under a
		// potentially deep workspace or TMPDIR.
		directory, err := shortDebugDirectory()
		if err != nil {
			return launchEndpointSpec{}, err
		}
		cleanup = func() { _ = os.RemoveAll(directory) }
		socket = filepath.Join(directory, "control.sock")
	}
	environment := map[string]string{
		"TESL_DEBUG": "1", "TESL_DEBUG_ROOT": cwd, "TESL_DEBUG_SOCKET": socket,
	}
	if strings.EqualFold(filepath.Ext(arguments.Program), ".tesl") {
		environment["TESL_DEBUG_WAIT"] = "1"
	}
	return launchEndpointSpec{socket: socket, environment: environment, cleanup: cleanup}, nil
}

func shortDebugDirectory() (string, error) {
	bases := []string{os.TempDir()}
	if filepath.Clean(os.TempDir()) != filepath.Clean("/tmp") {
		bases = append(bases, "/tmp")
	}
	var lastErr error
	for _, base := range bases {
		directory, err := os.MkdirTemp(base, "tesl-debug-")
		if err != nil {
			lastErr = err
			continue
		}
		if len([]byte(filepath.Join(directory, "control.sock"))) <= 100 {
			return directory, nil
		}
		_ = os.RemoveAll(directory)
		lastErr = errors.New("runtime directory exceeds the Unix socket path limit")
	}
	return "", fmt.Errorf("create private debug endpoint directory: %w", lastErr)
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
			client, err = DialControlTCP(endpoint.address, endpoint.token)
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
	pid := 0
	if command.Process != nil {
		pid = command.Process.Pid
	}
	return nil, fmt.Errorf("timed out waiting for debug endpoint for process %d", pid)
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
