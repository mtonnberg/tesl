//go:build tesl_migration_test

package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type pgContractABIIdentity struct {
	CompilerABI   string `json:"compilerAbi"`
	Compatibility string `json:"storedValueCompatibility"`
}

func TestPgRowEmptyContractABI(t *testing.T) {
	root := os.Getenv("TESL_ROW_CONTRACT_ABI_PROGRAMS")
	if root == "" {
		t.Skip("independently rebuilt A/B compiler applications required")
	}
	identity := func(name string) pgContractABIIdentity {
		t.Helper()
		raw, err := os.ReadFile(filepath.Join(root, name))
		if err != nil {
			t.Fatal(err)
		}
		var value pgContractABIIdentity
		if err = json.Unmarshal(raw, &value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	a, b := identity("identity.json"), identity("identity-b.json")
	if a.CompilerABI == b.CompilerABI || a.CompilerABI == "" || b.CompilerABI == "" || a.Compatibility == "" || a.Compatibility != b.Compatibility {
		t.Fatal("A/B fixtures require distinct actual builds and unchanged stored-value compatibility", a, b)
	}
	for _, scenario := range []string{"completed-empty-retirement", "completed-materialized-retirement", "retirement-wins-waiting-first-writer", "first-writer-wins-retirement"} {
		t.Run(scenario, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.namespace = "notes"
			ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
			t.Cleanup(cancel)
			f.ctx = ctx
			run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
			call := func(base, method, path string, status int) string {
				return pgCallRowAccessApp(t, ctx, base, method, path, status)
			}
			run("v1", "install")
			run("v1", "worker")
			run("v2", "worker")
			first := pgStartRowAccessApp(t, f, root, "v2")
			second := pgStartRowAccessApp(t, f, root, "v2b")
			call(first, "GET", "/all", 200)
			call(second, "GET", "/all", 200)
			processing := func(want string) {
				t.Helper()
				var abi string
				err := request.QueryRow(ctx, "select coalesce((select compiler_abi from notes.tesl_row_processing where version=2),'')").Scan(&abi)
				if err != nil || abi != want {
					t.Fatal("unexpected durable processing ABI", abi, want, err)
				}
			}
			audit := func() string {
				t.Helper()
				var value string
				err := f.worker.QueryRow(ctx, `select jsonb_build_object(
     'retirement',(select to_jsonb(v) from notes.tesl_schema_versions v where version=2 and step='retired'),
     'finality',(select jsonb_agg(to_jsonb(v) order by entity,generation) from notes.tesl_row_finality v),
     'contract',(select to_jsonb(v) from notes.tesl_row_contracts v where version=2))::text`).Scan(&value)
				if err != nil {
					t.Fatal(err)
				}
				return value
			}
			verifyRetired := func() {
				t.Helper()
				var abi string
				var minimum int
				err := f.worker.QueryRow(ctx, "select source_abi,(select min_version from notes.tesl_schema_state where id=1) from notes.tesl_schema_versions where version=2 and step='retired'").Scan(&abi, &minimum)
				if err != nil || abi != a.CompilerABI || minimum != 2 {
					t.Fatal("retirement lost actual A provenance or floor", abi, minimum, err)
				}
			}
			processing("")
			if strings.HasPrefix(scenario, "completed-") {
				wantProcessing, insertPath := "", "/one"
				if scenario == "completed-materialized-retirement" {
					call(first, "POST", "/one", 200)
					wantProcessing, insertPath = a.CompilerABI, "/two"
				}
				processing(wantProcessing)
				run("v2", "contract")
				verifyRetired()
				freshB := pgStartRowAccessApp(t, f, root, "v2b")
				call(freshB, "GET", "/all", 200)
				processing(wantProcessing)
				before := audit()
				call(second, "GET", "/all", 200)
				call(second, "POST", insertPath, 200)
				call(second, "PUT", "/one", 200)
				call(first, "GET", "/all", 200)
				call(second, "GET", "/all", 200)
				run("v2b", "contract")
				processing(wantProcessing)
				if after := audit(); after != before {
					t.Fatal("compatible B write/resume relabeled historical retirement", before, after)
				}
				return
			}
			boundary := "row-contract-before-retirement"
			if scenario == "retirement-wins-waiting-first-writer" {
				boundary = "row-contract-after-abi"
			}
			pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{boundary, 1}})[0]
			command := pgForwardNativeCommand(f, root, "v2", "contract")
			command.Env = append(command.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			var output pgRowAppOutput
			command.Stdout = &output
			command.Stderr = &output
			if err := command.Start(); err != nil {
				t.Fatal(err)
			}
			completed := make(chan error, 1)
			reaped := make(chan struct{})
			go func() { completed <- command.Wait(); close(completed); close(reaped) }()
			t.Cleanup(func() {
				pause.resume()
				select {
				case <-reaped:
				default:
					_ = command.Process.Kill()
					<-reaped
				}
			})
			select {
			case <-pause.arrived:
			case err := <-completed:
				t.Fatal("A missed retirement boundary", err, output.String())
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			if scenario == "first-writer-wins-retirement" {
				call(second, "POST", "/one", 200)
				processing(b.CompilerABI)
				pause.resume()
				select {
				case err := <-completed:
					if err == nil || !strings.Contains(output.String(), "retirement executor differs from processing ABI") {
						t.Fatal("A retirement ignored B's committed first write", err, output.String())
					}
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
				var retired, minimum int
				if err := f.worker.QueryRow(ctx, "select (select count(*) from notes.tesl_schema_versions where version=2 and step='retired'),min_version from notes.tesl_schema_state where id=1").Scan(&retired, &minimum); err != nil || retired != 0 || minimum != 1 {
					t.Fatal("failed retirement published authority", retired, minimum, err)
				}
				call(second, "GET", "/all", 200)
				call(first, "GET", "/all", 503)
				processing(b.CompilerABI)
				return
			}
			// The coordinator holds ABI coordination before taking its fresh retirement snapshot.
			result := make(chan error, 1)
			go func() { result <- pgContractABIPost(ctx, second+"/one") }()
			pgWaitContractABIBlock(t, f, ctx, f.roles.Request, "%tesl_row_check_abi%")
			pause.resume()
			select {
			case err := <-result:
				if err != nil {
					t.Fatal("waiting B first write", err)
				}
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			select {
			case err := <-completed:
				if err != nil {
					t.Fatal("A retirement", err, output.String())
				}
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			verifyRetired()
			processing("")
			before := audit()
			run("v2b", "contract")
			call(first, "GET", "/all", 200)
			call(second, "GET", "/all", 200)
			if after := audit(); after != before {
				t.Fatal("waiting B write/resume changed A history", before, after)
			}
		})
	}
}

func pgWaitContractABIBlock(t *testing.T, f *pgControlTestFixture, ctx context.Context, role, query string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		var waiting int
		err := f.installer.QueryRow(ctx, "select count(*) from pg_catalog.pg_stat_activity where datname=current_database() and usename=$1 and wait_event_type='Lock' and query like $2", role, query).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		if waiting > 0 {
			return
		}
		if time.Now().After(deadline) {
			rows, err := f.installer.Query(ctx, "select usename,coalesce(wait_event_type,''),coalesce(wait_event,''),left(query,220) from pg_catalog.pg_stat_activity where datname=current_database() and usename in ($1,$2)", f.roles.Request, f.roles.Worker)
			if err == nil {
				for rows.Next() {
					var user, kind, event, sql string
					if rows.Scan(&user, &kind, &event, &sql) == nil {
						t.Log("active migration SQL", user, kind, event, sql)
					}
				}
				rows.Close()
			}
			t.Fatal("actual SQL did not reach expected lock wait", role, query)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func pgContractABIPost(ctx context.Context, url string) error {
	req, err := http.NewRequestWithContext(ctx, "POST", url, nil)
	if err != nil {
		return err
	}
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = response.Body.Close() }()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return err
	}
	if response.StatusCode != 200 {
		return fmt.Errorf("first write status %d: %s", response.StatusCode, body)
	}
	return nil
}
