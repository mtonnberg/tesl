package teslrt

import (
	"context"
	"strings"
	"testing"
)

func migrationBudgetFailure(run func()) (message string) {
	defer func() {
		if value := recover(); value != nil {
			if failure, ok := value.(migrationExecutionFailure); ok {
				message = failure.Error()
			}
		}
	}()
	run()
	return ""
}

func TestMigrationBudgetStopsLoopAndClearsScope(t *testing.T) {
	message := migrationBudgetFailure(func() {
		defer BeginMigrationExecution()()
		for {
			MigrationStep()
		}
	})
	if !strings.Contains(message, "exhausted") && !strings.Contains(message, "deadline") {
		t.Fatal(message)
	}
	if migrationCurrentBudget() != nil {
		t.Fatal("failed execution leaked budget")
	}
}

func TestMigrationBudgetNestedScopeDoesNotRenewFuel(t *testing.T) {
	defer BeginMigrationExecution()()
	budget := migrationCurrentBudget()
	budget.fuel = 1
	defer BeginMigrationExecution()()
	MigrationStep()
	if message := migrationBudgetFailure(MigrationStep); !strings.Contains(message, "fuel") {
		t.Fatal(message)
	}
}

func TestMigrationBudgetCancellationAndRecursion(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	message := migrationBudgetFailure(func() { defer BeginMigrationExecution(ctx)(); MigrationStep() })
	if !strings.Contains(message, "canceled") {
		t.Fatal(message)
	}
	var recursive func()
	recursive = func() { defer MigrationEnter()(); recursive() }
	message = migrationBudgetFailure(func() { defer BeginMigrationExecution()(); recursive() })
	if !strings.Contains(message, "depth") {
		t.Fatal(message)
	}
}

func TestMigrationBudgetDoesNotInheritAcrossGoroutines(t *testing.T) {
	defer BeginMigrationExecution()()
	budget := migrationCurrentBudget()
	budget.fuel = 0
	done := make(chan bool, 1)
	go func() { MigrationStep(); done <- migrationCurrentBudget() == nil }()
	if !<-done {
		t.Fatal("unrelated execution inherited budget")
	}
}
