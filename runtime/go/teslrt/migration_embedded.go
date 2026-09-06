package teslrt

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"github.com/jackc/pgx/v5"
)

// The request pool remains cached across database scopes. Only the Embedded
// executor belongs to active scopes; nested or overlapping users share one
// generation, and the last release joins it before a successor may start.
type pgEmbeddedIndexService struct {
	mutex      sync.Mutex
	config     *pgx.ConnConfig
	history    PgCompiledMigrationHistory
	roles      PgMigrationControlRoles
	expected   PgMigrationControlState
	settings   pgIndexWorkerSettings
	generation *pgEmbeddedIndexGeneration
	failure    error
}

type pgEmbeddedIndexGeneration struct {
	ctx      context.Context
	stop     context.CancelFunc
	ready    chan struct{}
	done     chan struct{}
	released chan struct{}
	refs     int
	stopping bool
	err      error
}

func pgEmbeddedContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
}

// The initial scope is reserved before initialization publishes the pool. From
// this call onward the service exclusively owns conn and stop, even on failure.
func pgStartEmbeddedIndexService(ctx context.Context, stop context.CancelFunc, conn *pgx.Conn, config *pgx.ConnConfig,
	history PgCompiledMigrationHistory, roles PgMigrationControlRoles, expected PgMigrationControlState,
	settings pgIndexWorkerSettings) (*pgEmbeddedIndexService, func(), error) {
	service := &pgEmbeddedIndexService{config: config.Copy(), history: history, roles: roles, expected: expected, settings: settings}
	service.mutex.Lock()
	generation := service.startLocked(ctx, stop, conn)
	service.mutex.Unlock()
	release, err := service.await(generation)
	return service, release, err
}

func (service *pgEmbeddedIndexService) startLocked(ctx context.Context, stop context.CancelFunc, conn *pgx.Conn) *pgEmbeddedIndexGeneration {
	generation := &pgEmbeddedIndexGeneration{ctx: ctx, stop: stop, ready: make(chan struct{}), done: make(chan struct{}), released: make(chan struct{}), refs: 1}
	service.generation = generation
	go service.run(generation, conn)
	return generation
}

func (service *pgEmbeddedIndexService) run(generation *pgEmbeddedIndexGeneration, conn *pgx.Conn) {
	var err error
	if conn == nil {
		conn, err = service.connect(generation.ctx)
	}
	if err == nil && conn != nil {
		err = pgRunMigrationIndexWorkerWithSettings(generation.ctx, conn, service.config, service.history, service.roles, service.expected,
			func(PgMigrationControlState) error {
				if err := generation.ctx.Err(); err != nil {
					return err
				}
				close(generation.ready)
				return nil
			}, service.settings)
	}
	// The executor normally closes its connection, including its tagged backend
	// set. This also covers preflight errors before it takes its first session.
	if conn != nil && !conn.IsClosed() {
		cleanup, cancel := context.WithTimeout(context.Background(), service.settings.cleanup)
		closeErr := conn.Close(cleanup)
		cancel()
		if err == nil {
			err = closeErr
		}
	}
	if err == nil && generation.ctx.Err() == nil {
		err = fmt.Errorf("Embedded migration executor stopped unexpectedly")
	}
	service.mutex.Lock()
	generation.err = err
	if err != nil {
		// Cleanup failures also remain permanent: starting another generation
		// would otherwise assume the old backend set had disappeared.
		service.failure = err
	}
	close(generation.done)
	service.mutex.Unlock()
	if err != nil {
		select {
		case <-generation.ready:
			_, _ = fmt.Fprintf(os.Stderr, "database: %s Embedded migration executor stopped: %v\n", service.history.Database, err)
		default:
		}
	}
}

func (service *pgEmbeddedIndexService) connect(ctx context.Context) (*pgx.Conn, error) {
	for ctx.Err() == nil {
		connect, cancel := context.WithTimeout(ctx, service.settings.query)
		conn, err := pgx.ConnectConfig(connect, service.config.Copy())
		cancel()
		if ctx.Err() != nil && conn == nil {
			// No executor session or DDL was started. A canceled scope must not
			// turn a temporary connection outage into a permanent pool failure.
			return nil, nil
		}
		if err == nil || !pgIndexCanReconnect(err) {
			return conn, err
		}
		if err := pgIndexWait(ctx, service.settings.poll); err != nil {
			return nil, nil
		}
	}
	return nil, nil
}

func (service *pgEmbeddedIndexService) acquire() (func(), error) {
	for {
		service.mutex.Lock()
		if service.failure != nil {
			err := service.failure
			service.mutex.Unlock()
			return nil, err
		}
		generation := service.generation
		if generation != nil && generation.stopping {
			service.mutex.Unlock()
			<-generation.released
			continue
		}
		if generation == nil {
			ctx, stop := pgEmbeddedContext()
			generation = service.startLocked(ctx, stop, nil)
		} else {
			generation.refs++
		}
		service.mutex.Unlock()
		return service.await(generation)
	}
}

// A reserved scope may wait for the process-wide binding after readiness. Check
// again at publication so it cannot enter after its shared service has failed
// or received a shutdown signal while a preceding scope was draining.
func (service *pgEmbeddedIndexService) check() error {
	service.mutex.Lock()
	defer service.mutex.Unlock()
	if service.failure != nil {
		return service.failure
	}
	if service.generation == nil {
		return fmt.Errorf("Embedded migration service has no active scope owner")
	}
	return service.generation.ctx.Err()
}

func (service *pgEmbeddedIndexService) await(generation *pgEmbeddedIndexGeneration) (func(), error) {
	release := sync.OnceFunc(func() { service.release(generation) })
	select {
	case <-generation.ready:
	case <-generation.done:
	case <-generation.ctx.Done():
	}
	service.mutex.Lock()
	err := generation.err
	if err == nil {
		err = generation.ctx.Err()
	}
	service.mutex.Unlock()
	if err != nil {
		release()
		return nil, err
	}
	return release, nil
}

func (service *pgEmbeddedIndexService) release(generation *pgEmbeddedIndexGeneration) {
	service.mutex.Lock()
	generation.refs--
	if generation.refs != 0 {
		service.mutex.Unlock()
		return
	}
	generation.stopping = true
	generation.stop()
	service.mutex.Unlock()
	// pgRunMigrationIndexWorker joins its DDL actor and uses bounded independent
	// cleanup contexts. Do not abandon it or let another scope reuse its sessions.
	<-generation.done
	service.mutex.Lock()
	service.generation = nil
	close(generation.released)
	service.mutex.Unlock()
}
