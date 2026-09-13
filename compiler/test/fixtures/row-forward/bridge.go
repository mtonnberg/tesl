package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
)

func calibrationPlan[From, To any](db *Database, storage *PgRowStorage[From, To]) (*pgRowPhysicalPlan, *pgRowPhysicalEntity, error) {
	p, err := pgCompiledRowPhysicalPlan(db, 2)
	if err != nil {
		return nil, nil, err
	}
	d := storage.transform.registration.compiled.inventory.Transforms[storage.transform.registration.index]
	return p, p.entity(d.Entity), nil
}
func CalibrationRead[From, To any](ctx context.Context, db *Database, storage *PgRowStorage[From, To], key any) (value To, found bool, err error) {
	WithDatabase(db, func() {
		p, e, x := calibrationPlan(db, storage)
		if x != nil {
			err = x
			return
		}
		type result struct {
			v     To
			found bool
		}
		r, x := pgWithRowTransaction(ctx, db, p, e, false, func(a *pgRowTransactionAdmission) (result, error) {
			v, f, x := pgReadPhysicalRow(ctx, a, storage, key, false)
			return result{v, f}, x
		})
		value, found, err = r.v, r.found, x
	})
	return
}
func CalibrationInsert[From, To any](ctx context.Context, db *Database, storage *PgRowStorage[From, To], value To) (err error) {
	WithDatabase(db, func() {
		p, e, x := calibrationPlan(db, storage)
		if x != nil {
			err = x
			return
		}
		_, err = pgWithRowTransaction(ctx, db, p, e, true, func(a *pgRowTransactionAdmission) (struct{}, error) {
			row, err := pgMaterializePhysicalWrite(a, storage, value)
			if err != nil {
				return struct{}{}, err
			}
			return struct{}{}, pgInsertMaterializedPhysicalRow(ctx, a, row)
		})
	})
	return
}
func CalibrationUpdate[From, To any](ctx context.Context, db *Database, storage *PgRowStorage[From, To], key any, update func(To) To) (err error) {
	WithDatabase(db, func() {
		p, e, x := calibrationPlan(db, storage)
		if x != nil {
			err = x
			return
		}
		found, x := pgWithRowTransaction(ctx, db, p, e, true, func(a *pgRowTransactionAdmission) (bool, error) {
			return pgUpdatePhysicalRow(ctx, a, storage, key, update)
		})
		err = x
		if err == nil && !found {
			err = fmt.Errorf("missing row")
		}
	})
	return
}

func CalibrationCancelAfterDML[From, To any](db *Database, storage *PgRowStorage[From, To], value To) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	directory, err := os.MkdirTemp("", "row-cancel-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "s")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	prior, had := os.LookupEnv("TESL_MIGRATION_TEST_SOCKET")
	os.Setenv("TESL_MIGRATION_TEST_SOCKET", socket)
	defer func() {
		if had {
			os.Setenv("TESL_MIGRATION_TEST_SOCKET", prior)
		} else {
			os.Unsetenv("TESL_MIGRATION_TEST_SOCKET")
		}
	}()
	var reached atomic.Bool
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			func() {
				defer conn.Close()
				var event struct{ Name string }
				if json.NewDecoder(conn).Decode(&event) != nil {
					return
				}
				if event.Name == "row-target-after-dml" {
					reached.Store(true)
					cancel()
				}
				fmt.Fprintln(conn, "continue")
			}()
		}
	}()
	var operationErr error
	var caught any
	func() {
		defer func() { caught = recover() }()
		WithDatabase(db, func() {
			WithTransaction(func() { operationErr = CalibrationInsert(ctx, db, storage, value) /* intentionally swallowed */ })
		})
	}()
	if !reached.Load() || operationErr == nil || caught == nil {
		return fmt.Errorf("canceled write did not poison borrowed transaction: boundary=%t error=%v panic=%v", reached.Load(), operationErr, caught)
	}
	WithDatabase(db, func() {
		p, e, x := calibrationPlan(db, storage)
		if x != nil {
			err = x
			return
		}
		var setting string
		err = db.bound().pool.QueryRow(context.Background(), "select coalesce(pg_catalog.current_setting($1,true),'')", pgRowWriterSetting(p.namespace, e.identity)).Scan(&setting)
		if err == nil && setting != "" {
			err = fmt.Errorf("writer generation leaked after canceled operation: %s", setting)
		}
	})
	return err
}

func CalibrationReadThenUpdate[From, To any](ctx context.Context, db *Database, storage *PgRowStorage[From, To], key any, update func(To) To) (err error) {
	defer func() {
		if v := recover(); v != nil {
			err = fmt.Errorf("outer transaction failed: %v", v)
		}
	}()
	WithDatabase(db, func() {
		WithTransaction(func() {
			_, found, x := CalibrationRead(ctx, db, storage, key)
			if x != nil || !found {
				panic(fmt.Sprint(found, x))
			}
			if err = CalibrationUpdate(ctx, db, storage, key, update); err != nil {
				panic(err)
			}
		})
	})
	return
}
