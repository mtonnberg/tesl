package teslrt

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// This is an operational bound, not a static termination proof. Generated
// migration call graphs spend fuel at function entries and loop iterations.
// Intrinsic calls are not forcibly preempted; no detached computation is allowed
// to outlive the transaction and publish a late result.
const migrationExecutionFuel = 100000
const migrationExecutionDepth = 128
const migrationExecutionTime = 2 * time.Second

type migrationExecutionFailure struct{ reason string }

func (e migrationExecutionFailure) Error() string { return "migration execution stopped: " + e.reason }

type migrationExecutionBudget struct {
	ctx      context.Context
	deadline time.Time
	fuel     int
	depth    int
}

var migrationExecutionBudgets sync.Map
var migrationExecutions atomic.Int64

func migrationNoop() {}

// Nested callback/fixture scopes share their caller's budget and cannot renew
// fuel. Each goroutine owns its counters; unrelated request execution is isolated.
func BeginMigrationExecution(contexts ...context.Context) func() {
	id := goroutineID()
	if _, active := migrationExecutionBudgets.Load(id); active {
		return migrationNoop
	}
	ctx := context.Background()
	if len(contexts) > 0 && contexts[0] != nil {
		ctx = contexts[0]
	}
	budget := &migrationExecutionBudget{ctx: ctx, deadline: time.Now().Add(migrationExecutionTime), fuel: migrationExecutionFuel}
	migrationExecutionBudgets.Store(id, budget)
	migrationExecutions.Add(1)
	return func() {
		migrationExecutionBudgets.Delete(id)
		migrationExecutions.Add(-1)
	}
}

func migrationCurrentBudget() *migrationExecutionBudget {
	if migrationExecutions.Load() == 0 {
		return nil
	}
	value, found := migrationExecutionBudgets.Load(goroutineID())
	if !found {
		return nil
	}
	return value.(*migrationExecutionBudget)
}

func MigrationStep() {
	budget := migrationCurrentBudget()
	if budget == nil {
		return
	}
	if err := budget.ctx.Err(); err != nil {
		panic(migrationExecutionFailure{err.Error()})
	}
	budget.fuel--
	if budget.fuel < 0 {
		panic(migrationExecutionFailure{"fuel exhausted"})
	}
	if time.Now().After(budget.deadline) {
		panic(migrationExecutionFailure{"deadline exceeded"})
	}
}

func MigrationEnter() func() {
	MigrationStep()
	budget := migrationCurrentBudget()
	if budget == nil {
		return migrationNoop
	}
	if budget.depth >= migrationExecutionDepth {
		panic(migrationExecutionFailure{fmt.Sprintf("call depth exceeds %d", migrationExecutionDepth)})
	}
	budget.depth++
	return func() { budget.depth-- }
}
