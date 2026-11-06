package teslrt

import (
	"context"
	"fmt"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestRowControlSpecCacheIsolationAndEviction(t *testing.T) {
	var cache pgRowFunctionSpecCache
	want := pgBuildRowControlFunctions("notes")
	first := cache.get("notes")
	if len(first) == 0 {
		t.Fatal("cached specifications are empty")
	}
	if !reflect.DeepEqual(first, want) {
		t.Fatal("cached specifications differ from independently built SQL")
	}
	first[0].body = "tampered"
	if !reflect.DeepEqual(cache.get("notes"), want) {
		t.Fatal("caller mutated shared specifications")
	}
	for i := range 32 {
		name := fmt.Sprintf("namespace_%d", i)
		if !reflect.DeepEqual(cache.get(name), pgBuildRowControlFunctions(name)) {
			t.Fatal("namespace or eviction changed SQL", name)
		}
	}
	if !reflect.DeepEqual(cache.get("notes"), want) {
		t.Fatal("evicted namespace did not rebuild exactly")
	}
	var workers sync.WaitGroup
	for range 8 {
		workers.Go(func() {
			for range 8 {
				got := cache.get("notes")
				if len(got) == 0 {
					t.Error("concurrent lookup returned empty specifications")
					return
				}
				if !reflect.DeepEqual(got, want) {
					t.Error("concurrent lookup changed SQL")
				}
				got[0].body = "private mutation"
			}
		})
	}
	workers.Wait()
}

var rowSpecBenchmarkResult []pgMigrationControlFunction

func BenchmarkRowControlSpecifications(b *testing.B) {
	b.Run("rebuild", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			rowSpecBenchmarkResult = pgBuildRowControlFunctions("notes")
		}
	})
	b.Run("cached-copy", func(b *testing.B) {
		var cache pgRowFunctionSpecCache
		cache.get("notes")
		b.ReportAllocs()
		for b.Loop() {
			rowSpecBenchmarkResult = cache.get("notes")
		}
	})
}

func TestPgMigrationControlBatchedFunctions(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	functions := pgMigrationControlFunctions(f.namespace)
	if len(functions) == 0 {
		t.Fatal("control function inventory is empty")
	}
	check := func(tx pgx.Tx) error { return pgControlFunctionCatalogs(f.ctx, tx, f.namespace, f.roles, functions) }
	if err := pgControlTransaction(f.ctx, f.worker, false, check); err != nil {
		t.Fatal(err)
	}
	for _, index := range []int{0, len(functions) / 2, len(functions) - 1} {
		t.Run(fmt.Sprintf("missing-%d", index), func(t *testing.T) {
			tx, err := f.installer.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			if err := pgControlSession(f.ctx, tx); err != nil {
				t.Fatal(err)
			}
			fn := functions[index]
			if _, err := tx.Exec(f.ctx, "drop function "+pgx.Identifier{f.namespace, fn.name}.Sanitize()+"("+pgControlArgumentTypes(fn)+")"); err != nil {
				t.Fatal(err)
			}
			if err := check(tx); err == nil {
				t.Fatal("missing function accepted", fn.name)
			}
		})
	}
	tx, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if err := pgControlSession(f.ctx, tx); err != nil {
		t.Fatal(err)
	}
	if err := check(tx); err != nil {
		t.Fatal(err)
	}
	fn := functions[len(functions)/2]
	if _, err := tx.Exec(f.ctx, "alter function "+pgx.Identifier{f.namespace, fn.name}.Sanitize()+"("+pgControlArgumentTypes(fn)+") security invoker"); err != nil {
		t.Fatal(err)
	}
	if err := check(tx); err == nil {
		t.Fatal("successful inspection cached a later changed function")
	}
}

func TestPgMigrationControlFunctionInspectionTiming(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	functions := pgMigrationControlFunctions(f.namespace)
	for _, batch := range []bool{false, true, true, false} {
		started := time.Now()
		err := pgControlTransaction(f.ctx, f.worker, false, func(tx pgx.Tx) error {
			for range 5 {
				if batch {
					if err := pgControlFunctionCatalogs(f.ctx, tx, f.namespace, f.roles, functions); err != nil {
						return err
					}
				} else {
					for _, fn := range functions {
						if err := pgControlFunctionCatalog(f.ctx, tx, f.namespace, f.roles, fn); err != nil {
							return err
						}
					}
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("batch=%t functions=%d snapshots=5 elapsed=%s", batch, len(functions), time.Since(started))
	}
}
