package teslrt

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestTransactionExecutorsRefuseAnotherDatabase(t *testing.T) {
	owner, other := &PostgresDB{}, &PostgresDB{}
	tx := &debugFailingTransaction{execTag: pgconn.NewCommandTag("UPDATE 1")}
	key := goroutineID()
	openTransactions.Store(key, pgTransactionBinding{database: owner, transaction: tx})
	defer openTransactions.Delete(key)
	if currentTransactionFor(owner) != tx || currentTransaction() != tx {
		t.Fatal("transaction lost its owning connection")
	}
	entered := false
	WithDatabase(&Database{open: owner}, func() { entered = true })
	if !entered {
		t.Fatal("same-database scope did not reuse its current transaction")
	}
	if got := PgExec(owner, "update owner", nil); got != 1 {
		t.Fatalf("owning executor returned %d", got)
	}
	for name, call := range map[string]func(){
		"query":                   func() { PgQuery(other, "select other", nil, func(pgx.CollectableRow) (int, error) { return 0, nil }) },
		"exec":                    func() { PgExec(other, "update other", nil) },
		"count":                   func() { PgCount(other, "select count(*)", nil) },
		"scalar":                  func() { PgScalar(other, "select value", nil, func(pgx.Row) (int, error) { return 0, nil }) },
		"money":                   func() { PgSumMoney(other, "select sum(value)", nil, "Entity", "value") },
		"truncate":                func() { PgTruncate(other, "other") },
		"database scope":          func() { WithDatabase(&Database{open: other}, func() { t.Error("entered another database scope") }) },
		"unopened database scope": func() { WithDatabase(&Database{}, func() { t.Error("entered unopened database scope") }) },
		"pubsub":                  func() { (&pgPubsub{database: &Database{open: other}}).publish("channel", "key", "{}") },
	} {
		t.Run(name, func(t *testing.T) {
			// t.Run runs in a new goroutine, so explicitly establish its owner.
			childKey := goroutineID()
			openTransactions.Store(childKey, pgTransactionBinding{database: owner, transaction: tx})
			defer openTransactions.Delete(childKey)
			failure := recoverDebugSQLFailure(call)
			if failure == nil || !strings.Contains(fmt.Sprint(failure), "another database") {
				t.Fatalf("cross-database executor was not refused before SQL: %v", failure)
			}
		})
	}
	if failure := recoverDebugSQLFailure(func() { WithTransaction(func() { t.Error("nested body ran") }) }); failure == nil || !strings.Contains(fmt.Sprint(failure), "already open") {
		t.Fatalf("nested transaction attempted to borrow a pool: %v", failure)
	}
}

func TestTransactionDatabaseIdentityIsGoroutineLocal(t *testing.T) {
	var group sync.WaitGroup
	for range 20 {
		group.Go(func() {
			key := goroutineID()
			if currentTransaction() != nil {
				t.Error("inherited another goroutine's transaction")
			}
			database := &PostgresDB{}
			tx := &debugFailingTransaction{}
			openTransactions.Store(key, pgTransactionBinding{database: database, transaction: tx})
			defer openTransactions.Delete(key)
			if currentTransactionFor(database) != tx {
				t.Error("lost goroutine-local database identity")
			}
		})
	}
	group.Wait()
	if currentTransaction() != nil {
		t.Fatal("child transaction escaped its goroutine")
	}
}

func TestCrossDatabaseTransactionRollsBackOnItsOwnServer(t *testing.T) {
	first := liveDatabase(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	admin, err := pgx.Connect(ctx, postgresDSN(first.Config))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = admin.Close(context.Background()) }()
	name := "tesl_tx_" + strings.ReplaceAll(UUIDv7(), "-", "")
	if _, err := admin.Exec(ctx, "create database "+quoteIdentifier(name)); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := admin.Exec(cleanup, "drop database "+quoteIdentifier(name)+" with (force)"); err != nil {
			t.Errorf("remove isolated transaction database: %v", err)
		}
	}()
	second := &Database{Name: "Second", Config: first.Config, Tables: first.Tables}
	second.Config.DBName, second.Config.PoolSize = name, 1
	WithDatabase(first, func() {
		PgTruncate(first.bound(), "books")
		WithDatabase(second, func() {
			defer second.bound().pool.Close()
			const insert = `insert into "teslgotest"."books"(id,title,pages) values ($1,'test',1)`
			failure := recoverDebugSQLFailure(func() {
				WithTransaction(func() {
					PgExec(second.bound(), insert, []any{"own"})
					PgExec(first.bound(), insert, []any{"wrong-server"})
				})
			})
			if failure == nil || !strings.Contains(fmt.Sprint(failure), "another database") {
				t.Fatalf("cross-server write was not refused: %v", failure)
			}
			for _, database := range []*Database{first, second} {
				if got := PgCount(database.bound(), `select count(*) from "teslgotest"."books"`, nil); !Equal(got, FromInt64(0)) {
					t.Fatalf("write escaped rollback on %s: %s", database.Name, got.String())
				}
			}
			// With only one pool connection, nested refusal must happen before
			// waiting for a second lease. The outer transaction can still commit.
			WithTransaction(func() {
				failure := recoverDebugSQLFailure(func() { WithTransaction(func() { t.Error("nested body ran") }) })
				if failure == nil || !strings.Contains(fmt.Sprint(failure), "already open") {
					t.Fatalf("size-one pool nested refusal: %v", failure)
				}
				PgExec(second.bound(), insert, []any{"committed"})
			})
			if got := PgCount(second.bound(), `select count(*) from "teslgotest"."books"`, nil); !Equal(got, FromInt64(1)) {
				t.Fatal("refusal damaged the next transaction")
			}
		})
	})
}
