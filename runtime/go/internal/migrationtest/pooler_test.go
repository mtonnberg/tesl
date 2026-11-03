package migrationtest

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// startPooler owns a private Unix-only PgBouncer. Installation/control DDL still
// uses the direct fixture connection, as a worker's session fence requires.
func startPooler(t *testing.T, f *databaseFixture, mode string) *pgx.ConnConfig {
	t.Helper()
	if os.Getenv("TESL_MIGRATION_TEST_POOLERS") != "1" {
		t.Skip("set TESL_MIGRATION_TEST_POOLERS=1 to run PgBouncer session/transaction tests")
	}
	binary, err := exec.LookPath("pgbouncer")
	if err != nil {
		t.Fatal("PgBouncer matrix requested but pgbouncer is unavailable: ", err)
	}
	upstream, err := pgx.ParseConfig(f.dsn)
	if err != nil {
		t.Fatal(err)
	}
	dir, err := os.MkdirTemp("", "tesl-pooler-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	quote := func(value string) string {
		if strings.ContainsAny(value, "\r\n\x00") {
			t.Fatal("pooler connection values cannot contain line breaks or NUL")
		}
		return "'" + strings.ReplaceAll(value, "'", "''") + "'"
	}
	// auth_type=any is confined to a private mode-0700 Unix socket directory and
	// one forced upstream user. No TCP listener or existing role is modified.
	size := 2
	if mode == "transaction" {
		size = 1 // Force different clients to borrow the exact same backend.
	}
	password := ""
	if upstream.Password != "" {
		password = " password=" + quote(upstream.Password)
	}
	config := fmt.Sprintf(`[databases]
migration = host=%s port=%d dbname=%s user=%s%s
[pgbouncer]
listen_addr =
listen_port = 6432
unix_socket_dir = %s
auth_type = any
pool_mode = %s
default_pool_size = %d
max_client_conn = 16
max_prepared_statements = 0
server_reset_query = DISCARD ALL
`, quote(upstream.Host), upstream.Port, quote(upstream.Database), quote(upstream.User), password, dir, mode, size)
	path := filepath.Join(dir, "pgbouncer.ini")
	if err := os.WriteFile(path, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	log, err := os.Create(filepath.Join(dir, "pgbouncer.log"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(f.ctx, binary, path)
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Start(); err != nil {
		_ = log.Close()
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		select {
		case <-exited:
		case <-time.After(5 * time.Second):
			t.Error("PgBouncer did not exit after kill")
		}
		_ = log.Close()
	})
	client := upstream.Copy()
	client.Host, client.Port, client.Database = dir, 6432, "migration"
	client.TLSConfig, client.Fallbacks = nil, nil
	// Transaction pooling cannot retain a named prepared statement between
	// transactions. This is the same unnamed extended protocol the app needs.
	client.DefaultQueryExecMode = pgx.QueryExecModeExec
	readyCtx, cancel := context.WithTimeout(f.ctx, 10*time.Second)
	defer cancel()
	readLog := func() string {
		output, _ := os.ReadFile(log.Name())
		text := string(output)
		if upstream.Password != "" {
			text = strings.ReplaceAll(text, quote(upstream.Password), "'[redacted]'")
			text = strings.ReplaceAll(text, upstream.Password, "[redacted]")
		}
		return text
	}
	for {
		conn, err := pgx.ConnectConfig(readyCtx, client)
		if err == nil {
			_ = conn.Close(readyCtx)
			return client
		}
		select {
		case <-exited:
			t.Fatalf("PgBouncer exited during startup: %s", readLog())
		case <-readyCtx.Done():
			t.Fatalf("PgBouncer readiness: %v\n%s", err, readLog())
		default:
		}
	}
}

// INV-FENCE, INV-READ, INV-FLOOR, INV-ATOMIC-WRITE; TR-WRITE, TR-RETIRE, TR-ADMIT.
// This validates the transaction protocol under real pooling, including backend
// reuse. Generated migration admission and prepared-plan retry are later gates.
func TestPostgresPoolerAdmissionTransactions(t *testing.T) {
	for _, mode := range []string{"session", "transaction"} {
		t.Run(mode, func(t *testing.T) {
			f := newDatabaseFixture(t)
			config := startPooler(t, f, mode)
			f.expanded(t, 8)
			f.exec(t, "create table "+f.schema+".notes (id int primary key)")
			connect := func() *pgx.Conn {
				t.Helper()
				conn, err := pgx.ConnectConfig(f.ctx, config)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() {
					ctx, cancel := context.WithTimeout(context.Background(), time.Second)
					defer cancel()
					_ = conn.Close(ctx)
				})
				return conn
			}
			writer := connect()
			tx, err := writer.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(f.ctx) }()
			var writerPID, floor int
			if err := tx.QueryRow(f.ctx, "select pg_backend_pid()").Scan(&writerPID); err != nil {
				t.Fatal(err)
			}
			if _, err := tx.Exec(f.ctx, "select pg_advisory_xact_lock_shared($1,7)", f.fence); err != nil {
				t.Fatal(err)
			}
			if err := tx.QueryRow(f.ctx, "select "+f.schema+".tesl_admit(7)").Scan(&floor); err != nil || floor != 7 {
				t.Fatalf("old writer admission: %d, %v", floor, err)
			}
			retirer := f.other(t)
			ctx, cancel := context.WithCancel(f.ctx)
			defer cancel()
			retired := make(chan error, 1)
			go func() {
				_, err := retirer.Exec(ctx, fmt.Sprintf("begin; select pg_advisory_xact_lock(%d,7); select %s.tesl_advance_floor(7,8,'retire',1,'tesl-1','fixture'); commit", f.fence, f.schema))
				retired <- err
			}()
			for {
				var waiting bool
				if err := f.conn.QueryRow(ctx, "select exists(select 1 from pg_locks where pid=$1 and locktype='advisory' and not granted)", retirer.PgConn().PID()).Scan(&waiting); err != nil {
					t.Fatalf("%v\n%s", err, f.dump())
				}
				if waiting {
					break
				}
				select {
				case err := <-retired:
					t.Fatalf("retirement passed pooled writer's shared fence: %v", err)
				default:
				}
			}
			if _, err := tx.Exec(ctx, "insert into "+f.schema+".notes values (1)"); err != nil {
				t.Fatal(err)
			}
			if err := tx.Commit(ctx); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-retired:
				if err != nil {
					t.Fatal(err)
				}
			case <-ctx.Done():
				t.Fatalf("retirement: %v\n%s", ctx.Err(), f.dump())
			}
			borrower := connect()
			read, err := borrower.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = read.Rollback(ctx) }()
			var borrowerPID, rows int
			if err := read.QueryRow(ctx, "select pg_backend_pid(),count(*) from "+f.schema+".notes").Scan(&borrowerPID, &rows); err != nil || rows != 1 {
				t.Fatalf("pooled read: rows=%d, %v", rows, err)
			}
			if (mode == "transaction") != (writerPID == borrowerPID) {
				t.Fatalf("pool did not exercise requested backend ownership: mode=%s, writer=%d, borrower=%d", mode, writerPID, borrowerPID)
			}
			if err := read.QueryRow(ctx, "select "+f.schema+".tesl_admit(7)").Scan(&floor); err == nil || !strings.Contains(err.Error(), "is retired") {
				t.Fatalf("pooled stale version admitted or wrong error: %v", err)
			}
			if err := read.Rollback(ctx); err != nil {
				t.Fatal(err)
			}
			if err := borrower.QueryRow(ctx, "select "+f.schema+".tesl_admit(8)").Scan(&floor); err != nil {
				t.Fatalf("refused transaction leaked failure into the next pooled request: %v", err)
			}
			var held int
			if err := f.conn.QueryRow(ctx, "select count(*) from pg_locks where pid=$1 and locktype='advisory'", writerPID).Scan(&held); err != nil || held != 0 {
				t.Fatalf("shared transaction fence leaked into pooled backend: locks=%d, %v", held, err)
			}
		})
	}
}
