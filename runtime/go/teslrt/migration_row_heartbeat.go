package teslrt

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
)

const pgRowHeartbeatInterval = 5 * time.Second
const pgRowHeartbeatFreshness = 15 * time.Second

type pgRowHeartbeatStatus struct {
	at      time.Time
	failure error
}
type pgRowHeartbeat struct {
	cancel context.CancelFunc
	done   chan struct{}
	stop   sync.Once
	closed atomic.Bool
	status atomic.Pointer[pgRowHeartbeatStatus]
}

// verifiedRequest is owned by this function from entry, including every failure
// path. Only initializeRowPostgres can supply it, after complete Request startup
// verification. Reconnects and Inline startup always perform full verification.
func pgStartRowHeartbeat(startup context.Context, db *PostgresDB, original *pgx.ConnConfig, verifiedRequest *pgx.Conn) (*pgRowHeartbeat, error) {
	conn := verifiedRequest
	started := false
	defer func() {
		if !started && conn != nil {
			cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = conn.Close(cleanup)
		}
	}()
	if verifiedRequest != nil && (db.migration == nil || db.migration.roles.Request == "" || original.User != db.migration.roles.Request || verifiedRequest.Config().User != original.User) {
		return nil, fmt.Errorf("row heartbeat transfer requires the verified Request connection")
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	config := original.Copy()
	config.RuntimeParams["application_name"] = "tesl-app:" + hex.EncodeToString(nonce[:])
	// Recovery proves the same immutable owner and fresh server admission, but
	// cannot depend on the failed monitor whose connectivity it is restoring.
	// This local view is never published or used for application operations.
	registration := &PostgresDB{schema: db.schema, migration: db.migration}
	connect := func(ctx context.Context) (*pgx.Conn, error) {
		conn, err := pgx.ConnectConfig(ctx, config)
		if err != nil {
			return nil, err
		}
		if err := pgVerifyMigrationConnection(ctx, conn, registration); err != nil {
			cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = conn.Close(cleanup)
			return nil, err
		}
		return conn, nil
	}
	renew := func(ctx context.Context, conn *pgx.Conn) error {
		_, err := conn.Exec(ctx, "select "+pgx.Identifier{db.schema, "tesl_heartbeat"}.Sanitize()+"($1,1,(select compat_floor from "+pgx.Identifier{db.schema, "tesl_schema_state"}.Sanitize()+" where id=1))", db.migration.version)
		return err
	}
	var err error
	if conn == nil {
		conn, err = connect(startup)
		if err != nil {
			return nil, err
		}
	} else {
		// The startup connection has not executed application work. Give it
		// this monitor's distinct process identity before initial registration.
		if _, err := conn.Exec(startup, "select pg_catalog.set_config('application_name',$1,false)", config.RuntimeParams["application_name"]); err != nil {
			return nil, err
		}
	}
	if err := renew(startup, conn); err != nil {
		return nil, err
	}
	// The pool is process-scoped and cached across WithDatabase calls. This
	// monitor has the same lifetime; request-scope cancellation must not stop it.
	service, cancel := context.WithCancel(context.Background())
	monitor := &pgRowHeartbeat{cancel: cancel, done: make(chan struct{})}
	monitor.status.Store(&pgRowHeartbeatStatus{at: time.Now()})
	started = true
	go func() {
		defer close(monitor.done)
		defer func() {
			if conn != nil {
				cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				_ = conn.Close(cleanup)
			}
		}()
		ticker := time.NewTicker(pgRowHeartbeatInterval)
		defer ticker.Stop()
		for {
			select {
			case <-service.Done():
				return
			case <-ticker.C:
			}
			query, stop := context.WithTimeout(service, 5*time.Second)
			if conn == nil || conn.IsClosed() {
				conn, err = connect(query)
			} else {
				err = nil
			}
			if err == nil {
				err = renew(query, conn)
			}
			stop()
			if err != nil {
				monitor.status.Store(&pgRowHeartbeatStatus{failure: err})
			} else {
				monitor.status.Store(&pgRowHeartbeatStatus{at: time.Now()})
			}
		}
	}()
	return monitor, nil
}
func (monitor *pgRowHeartbeat) close() {
	if monitor == nil {
		return
	}
	monitor.stop.Do(func() {
		monitor.closed.Store(true)
		monitor.status.Store(&pgRowHeartbeatStatus{failure: errors.New("row request pool is closed")})
		monitor.cancel()
		<-monitor.done
		monitor.status.Store(&pgRowHeartbeatStatus{failure: errors.New("row request pool is closed")})
	})
}
func (monitor *pgRowHeartbeat) check() error {
	if monitor == nil {
		return nil
	}
	if monitor.closed.Load() {
		return fmt.Errorf("row request pool is closed")
	}
	status := monitor.status.Load()
	if status == nil {
		return fmt.Errorf("row instance registration is unavailable")
	}
	if status.failure != nil {
		return fmt.Errorf("row instance renewal failed: %w", status.failure)
	}
	if time.Since(status.at) > pgRowHeartbeatFreshness {
		return fmt.Errorf("row instance registration is stale")
	}
	return nil
}

// This is the destruction hook for a row request pool. A scope release does not
// destroy the process cache; actual destruction always cancels the monitor first.
func (db *PostgresDB) closeRowPool() {
	if db == nil {
		return
	}
	db.rowHeartbeat.close()
	if db.pool != nil {
		db.pool.Close()
	}
}
