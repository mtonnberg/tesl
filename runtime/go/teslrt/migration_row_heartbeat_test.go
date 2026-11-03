package teslrt

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestRowHeartbeatAdmissionAndShutdown(t *testing.T) {
	h := &pgRowHeartbeat{done: make(chan struct{})}
	if h.check() == nil {
		t.Fatal("unregistered instance admitted")
	}
	h.status.Store(&pgRowHeartbeatStatus{at: time.Now()})
	if err := h.check(); err != nil {
		t.Fatal(err)
	}
	h.status.Store(&pgRowHeartbeatStatus{at: time.Now().Add(-pgRowHeartbeatFreshness - time.Second)})
	if h.check() == nil {
		t.Fatal("stale registration admitted")
	}
	h.status.Store(&pgRowHeartbeatStatus{failure: errors.New("connection lost")})
	if h.check() == nil {
		t.Fatal("failed renewal admitted")
	}
	h.status.Store(&pgRowHeartbeatStatus{at: time.Now()})
	if err := h.check(); err != nil {
		t.Fatalf("recovered registration refused: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel

	renewed, finish, closed := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		<-ctx.Done()
		h.status.Store(&pgRowHeartbeatStatus{at: time.Now()})
		close(renewed)
		<-finish
		close(h.done)
	}()
	go func() { h.close(); close(closed) }()
	<-renewed
	if h.check() == nil {
		t.Error("in-flight successful renewal readmitted while pool shutdown was still draining")
	}
	close(finish)
	<-closed
	if h.check() == nil {
		t.Fatal("in-flight successful renewal revived a closed pool")
	}
	h.close()
}
