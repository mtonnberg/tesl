// Package childprocess owns a command and all of its descendants.
package childprocess

import (
	"os/exec"
	"sync"
)

type Child struct {
	Command *exec.Cmd
	mu      sync.Mutex
	kill    func()
	close   func()
}

func Start(command *exec.Cmd) (*Child, error) {
	return start(command, false)
}

// StartLauncher owns a selected native frontend while permitting its explicit
// managed PostgreSQL process to outlive the frontend on Windows.
func StartLauncher(command *exec.Cmd) (*Child, error) {
	return start(command, true)
}

func start(command *exec.Cmd, launcher bool) (*Child, error) {
	configure(command)
	if err := command.Start(); err != nil {
		return nil, err
	}
	kill, close, err := attach(command, launcher)
	if err != nil {
		_ = command.Process.Kill()
		_ = command.Wait()
		return nil, err
	}
	return &Child{Command: command, kill: kill, close: close}, nil
}

func (child *Child) Kill() {
	child.mu.Lock()
	defer child.mu.Unlock()
	if child.kill != nil {
		child.kill()
	}
}

func (child *Child) Wait() error {
	err := child.Command.Wait()
	child.mu.Lock()
	defer child.mu.Unlock()
	if child.close != nil {
		child.close()
		child.close = nil
		child.kill = nil
	}
	return err
}
