package migrationtest

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// ProcessController applies the same deterministic schedule to independently
// compiled programs. The private Unix socket carries event names only, never SQL
// parameters or row values. Every arrival gets its own bounded connection.
type ProcessController struct {
	listener net.Listener
	schedule *Schedule
	ctx      context.Context
	cancel   context.CancelFunc
	workers  sync.WaitGroup
	mu       sync.Mutex
	errors   []error
}

func ListenProcesses(ctx context.Context, socket string, schedule *Schedule) (*ProcessController, error) {
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	p := &ProcessController{listener: listener, schedule: schedule, ctx: ctx, cancel: cancel}
	p.workers.Go(func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				if ctx.Err() == nil {
					p.record(err)
				}
				return
			}
			p.workers.Go(func() { p.arrive(conn) })
		}
	})
	return p, nil
}

func (p *ProcessController) arrive(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	stop := context.AfterFunc(p.ctx, func() { _ = conn.Close() })
	defer stop()
	if err := conn.SetDeadline(time.Now().Add(30 * time.Second)); err != nil {
		p.record(err)
		return
	}
	var request struct {
		Version    int    `json:"version"`
		Name       string `json:"name"`
		Actor      string `json:"actor"`
		Occurrence int    `json:"occurrence"`
	}
	decoder := json.NewDecoder(io.LimitReader(conn, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		p.record(fmt.Errorf("migration event decode: %w", err))
		return
	}
	if request.Version != 1 || request.Name == "" || request.Actor == "" || request.Occurrence < 1 {
		p.record(fmt.Errorf("invalid migration event: %+v", request))
		return
	}
	event := Event{request.Name, request.Actor, request.Occurrence}
	ctx, cancel := context.WithTimeout(p.ctx, 30*time.Second)
	defer cancel()
	if err := p.schedule.Hit(ctx, event); err != nil {
		p.record(err)
		return
	}
	if _, err := io.WriteString(conn, "continue\n"); err != nil {
		p.record(err)
	}
}

func (p *ProcessController) record(err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.errors = append(p.errors, err)
}

// Close cancels paused arrivals and joins all goroutines. Callers inspect Errors
// after joining, so a protocol error cannot get lost during test teardown.
func (p *ProcessController) Close() {
	p.cancel()
	_ = p.listener.Close()
	p.workers.Wait()
}

func (p *ProcessController) Errors() []error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]error(nil), p.errors...)
}
