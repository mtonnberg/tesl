package teslrt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func pgRowBaselineReady(t *testing.T, f *pgControlTestFixture, db *Database) *pgRowBaseline {
	t.Helper()
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
	b, err := pgCompiledRowBaseline(db)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
func pgRowBaselineRead(t *testing.T, f *pgControlTestFixture, conn *pgx.Conn, b *pgRowBaseline) error {
	t.Helper()
	return pgControlSnapshotMode(f.ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error { _, _, err := pgReadRowBaselineState(f.ctx, tx, b, f.roles, false); return err })
}
func TestPgRowBaselineCatalogDriftRefusesEveryEntrypoint(t *testing.T) {
	for _, change := range []struct{ name, sql string }{
		{"marker absent", `alter table notes_app.notes drop column _tesl_v`},
		{"marker nullable", `alter table notes_app.notes alter column _tesl_v drop not null`},
		{"marker wrong scalar", `alter table notes_app.notes alter column _tesl_v type integer`},
		{"marker wrong default", `alter table notes_app.notes alter column _tesl_v set default 2`},
		{"marker no default", `alter table notes_app.notes alter column _tesl_v drop default`},
		{"marker function default", `alter table notes_app.notes alter column _tesl_v set default length('x')`},
		{"marker identity", `alter table notes_app.notes alter column _tesl_v drop default; alter table notes_app.notes alter column _tesl_v add generated always as identity`},
		{"extra column", `alter table notes_app.notes add column extra text`},
		{"extra queue relation", `create table notes_app.tesl_jobs(id integer)`},
		{"extra relation", `create table notes_app.extra(id integer)`},
		{"extra function", `create function notes_app.extra() returns integer language sql as 'select 1'`},
		{"entity generation", `update notes_app.tesl_row_entities set generation=2`},
		{"insert generation", `update notes_app.tesl_row_entities set generation=2,insert_generation=2`},
		{"source family", `update notes_app.tesl_row_versions set family='another'`},
		{"entity logical identity", `update notes_app.tesl_row_entities set entity='Other'`},
		{"missing entity inventory", `delete from notes_app.tesl_row_entities`},
		{"missing baseline", `delete from notes_app.tesl_row_baseline`},
		{"extra version", `insert into notes_app.tesl_row_versions select 2,family,schema_snapshot,schema_snapshot_hash,storage_snapshot,storage_snapshot_hash,inventory_hash,catalog_hash,entity_count,queue_count,facility_count,compiler_abi,stored_value_compatibility from notes_app.tesl_row_versions`},
	} {
		t.Run(change.name, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			db := pgRowBaselineFixture(t, f)
			b := pgRowBaselineReady(t, f, db)
			if _, err := f.installer.Exec(f.ctx, change.sql); err != nil {
				t.Fatal("mutation", err)
			}
			if err := pgRowBaselineRead(t, f, request, b); err == nil {
				t.Fatal("read-only admission accepted drift")
			}
			if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err == nil {
				t.Fatal("installer retry accepted drift")
			}
			if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err == nil {
				t.Fatal("worker accepted drift")
			}
		})
	}
}
func TestPgRowBaselineRefusesLegacyFormatsAndLookalikes(t *testing.T) {
	for _, kind := range []string{"empty3", "populated3", "private4", "lookalike"} {
		t.Run(kind, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			switch kind {
			case "empty3":
				f.install(t, 1)
			case "populated3":
				f.install(t, 1)
				f.expand(t, 1)
				f.call(t, `insert into notes_app.notes(id,active) values('retained',true)`)
			case "private4":
				h := pgQueueCandidateTestHistory(t, false)
				if _, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles); err != nil {
					t.Fatal(err)
				}
			case "lookalike":
				if _, err := f.installer.Exec(f.ctx, `create schema notes_app;create table notes_app.tesl_row_baseline(id integer)`); err != nil {
					t.Fatal(err)
				}
			}
			db := pgRowBaselineFixture(t, f)
			if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err == nil {
				t.Fatal("adopted preexisting namespace")
			}
			var marker bool
			if err := f.installer.QueryRow(f.ctx, `select exists(select 1 from information_schema.columns where table_schema='notes_app' and table_name='notes' and column_name='_tesl_v')`).Scan(&marker); err != nil || marker {
				t.Fatal("refused installer added marker", marker, err)
			}
			if kind == "populated3" {
				var count int
				if err := f.installer.QueryRow(f.ctx, `select count(*) from notes_app.notes where id='retained' and active`).Scan(&count); err != nil || count != 1 {
					t.Fatal("changed data", count, err)
				}
			}
		})
	}
}
func TestPgRowBaselinePoolReconnectPinsPhysicalAndControlIdentity(t *testing.T) {
	for _, kind := range []string{"uuid", "format", "marker", "worker membership"} {
		t.Run(kind, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			db := pgRowBaselineFixture(t, f)
			pgRowBaselineReady(t, f, db)
			WithDatabase(db, func() {
				opened := db.bound()
				if opened == nil {
					t.Fatal("pool missing")
				}
				defer opened.pool.Close()
				if got := PgCount(opened, `select count(*) from notes_app.notes`, nil); got.String() != "0" {
					t.Fatal(got)
				}
				sql := `update notes_app.tesl_schema_meta set database_uuid='11111111-1111-1111-1111-111111111111'`
				switch kind {
				case "format":
					sql = `update notes_app.tesl_schema_meta set format_version=3`
				case "marker":
					sql = `alter table notes_app.notes alter column _tesl_v set default 2`
				case "worker membership":
					sql = "grant " + quoteIdentifier(f.roles.Worker) + " to " + quoteIdentifier(f.roles.Request)
				}
				if _, err := f.installer.Exec(f.ctx, sql); err != nil {
					t.Fatal(err)
				}
				opened.pool.Reset()
				ctx, cancel := context.WithTimeout(f.ctx, 200*time.Millisecond)
				defer cancel()
				if err := opened.pool.Ping(ctx); err == nil {
					t.Fatal("replacement pool accepted drift")
				}
				if opened.pool.Stat().AcquiredConns() != 0 {
					t.Fatal("rejected connection leaked lease")
				}
			})
		})
	}
}
func TestPgRowBaselineEmbeddedAndEmptyInventory(t *testing.T) {
	for _, empty := range []bool{false, true} {
		t.Run(fmt.Sprint(empty), func(t *testing.T) {
			f := pgNewControlTest(t)
			db := pgRowBaselineFixtureWith(t, f, func(h *PgCompiledMigrationHistory, base, companion map[string]any) {
				if !empty {
					return
				}
				schema := pgRowList(pgRowAtom("stored-value-semantics"), pgRowAtom(h.StoredValueCompatibility), pgRowList(pgRowAtom("closure"), pgRowList(), pgRowList()))
				schemaHex, schemaHash := rowTestDoc("snapshot", schema)
				storageHex, storageHash := rowTestDoc("migration", pgRowList(pgRowAtom("postgres-storage-v1"), schema, pgRowList()))
				v := rowTestVersion(base, 1)
				v["schemaContract"], v["schemaSnapshotHash"], v["storageContract"], v["storageSnapshotHash"], v["entities"] = schemaHex, schemaHash, storageHex, storageHash, []any{}
			})
			if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
				t.Fatal(err)
			}
			WithDatabase(db, func() {
				opened := db.bound()
				defer opened.pool.Close()
				var current int
				if err := opened.pool.QueryRow(f.ctx, `select current from notes_app.tesl_schema_state`).Scan(&current); err != nil || current != 1 {
					t.Fatal(current, err)
				}
			})
			b, err := pgCompiledRowBaseline(db)
			if err != nil {
				t.Fatal(err)
			}
			if err := pgRowBaselineRead(t, f, f.worker, b); err != nil {
				t.Fatal(err)
			}
		})
	}
}
func TestPgRowBaselineSchemaCommandsAndAliasSelection(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	h, _ := db.CompiledMigrationHistory()
	alias := "teslmodapp." + h.Database
	RegisterDatabaseIdentity(alias, db)
	t.Cleanup(func() { databaseIdentities.Delete(alias) })
	selected, _, err := pgSelectSchemaDatabase("")
	if err != nil || selected != db {
		t.Fatal("same-pointer alias made selection ambiguous", err)
	}
	other := NewDatabase("Other", PostgresConfig{}, nil)
	other.migrationHistory = &PgCompiledMigrationHistory{Database: "Other.Main", Family: "Other"}
	databaseIdentities.Store("Other.Main", other)
	defer databaseIdentities.Delete("Other.Main")
	if _, _, err := pgSelectSchemaDatabase(""); err == nil {
		t.Fatal("distinct owners no longer ambiguous")
	}
	if selected, _, err := pgSelectSchemaDatabase(h.Database); err != nil || selected != db {
		t.Fatal("explicit owner selection", err)
	}
	databaseIdentities.Delete("Other.Main")
	var output bytes.Buffer
	cmd := pgSchemaCommand{verb: "install", worker: f.roles.Worker, request: f.roles.Request, json: true}
	db.Config.DDLConnection = f.installer.Config().ConnString()
	if err := pgRunRowSchemaCommand(f.ctx, cmd, &output, db); err != nil {
		t.Fatal(err)
	}
	var report pgSchemaInstallation
	if err := json.Unmarshal(output.Bytes(), &report); err != nil || report.CurrentVersion != 0 {
		t.Fatal(output.String(), err)
	}
	db.Config.DDLConnection = f.worker.Config().ConnString()
	ctx, cancel := context.WithCancel(f.ctx)
	defer cancel()
	ready := make(chan []byte, 1)
	done := make(chan error, 1)
	go func() {
		done <- pgRunRowSchemaCommand(ctx, pgSchemaCommand{verb: "worker", json: true}, pgRowReadyWriter{ready}, db)
	}()
	select {
	case payload := <-ready:
		if !bytes.Contains(payload, []byte(`"schema-worker-ready"`)) {
			t.Fatal(string(payload))
		}
	case err := <-done:
		t.Fatal("worker ended before ready", err)
	case <-f.ctx.Done():
		t.Fatal("worker timeout")
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err := pgRunRowSchemaCommand(f.ctx, pgSchemaCommand{verb: "status", json: true}, &output, db); err != nil {
		t.Fatal(err)
	}
	var status PgMigrationStatus
	if err := json.Unmarshal(output.Bytes(), &status); err != nil || status.FormatVersion != 5 || status.CurrentVersion != 1 {
		t.Fatal(output.String(), err)
	}
	if db.bound() != nil {
		t.Fatal("schema command opened application pool")
	}
	if err := pgRunRowSchemaCommand(f.ctx, pgSchemaCommand{verb: "worker"}, pgSchemaBrokenWriter{}, db); err == nil {
		t.Fatal("worker swallowed ready output failure")
	}
}

type pgRowReadyWriter struct{ ready chan<- []byte }

func (w pgRowReadyWriter) Write(data []byte) (int, error) {
	w.ready <- append([]byte(nil), data...)
	return len(data), nil
}
func TestRowBaselineRefusesLegacySmallintCatalog(t *testing.T) {
	err := pgValidateMigrationCatalog([]PgMigrationCatalogTable{{Name: "notes", Columns: []PgMigrationCatalogColumn{{Name: "id", Type: "int2", PrimaryKey: true}}}})
	if err == nil {
		t.Fatal("format-3 catalog gained generation-marker scalar authority")
	}
}
func TestPgRowBaselineRefusesWrongRuntimePrincipal(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	b := pgRowBaselineReady(t, f, db)
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, request, db, f.roles); err == nil || !strings.Contains(err.Error(), "exact Worker login") {
		t.Fatal("request reached worker execution", err)
	}
	if _, err := pgWaitForRowBaseline(f.ctx, f.worker, b, f.roles); err == nil || !strings.Contains(err.Error(), "exact Request login") {
		t.Fatal("worker reached request admission", err)
	}
	ctx, cancel := context.WithCancel(f.ctx)
	cancel()
	if _, err := pgWaitForRowBaseline(ctx, request, b, f.roles); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if err := pgRunRowSchemaCommand(f.ctx, pgSchemaCommand{verb: "install", worker: "other", request: f.roles.Request}, io.Discard, db); err == nil {
		t.Fatal("wrong installer role accepted")
	}
}

func TestPgRowBaselineCompleteSourceQueueAndRuntimeFacilityAbsence(t *testing.T) {
	for _, kind := range []string{"declared queue", "declared cache", "unsealed app", "later additive", "wrong owner"} {
		t.Run(kind, func(t *testing.T) {
			f := pgNewControlTest(t)
			db := pgRowBaselineFixtureConfigured(t, f, func(h *PgCompiledMigrationHistory, base, companion map[string]any) {
				if kind == "declared queue" {
					v := rowTestVersion(base, 1)
					reader := &pgMigrationWireReader{}
					schema := pgRowDocument(reader, v["schemaContract"].(string), v["schemaSnapshotHash"].(string), "snapshot")
					ref := pgRowTypeReference(h.Family, "Jobs")
					ref.children[1] = pgRowAtom("value")
					closure := &schema.children[2]
					closure.children[1].children = append(closure.children[1].children, ref)
					closure.children[2].children = append(closure.children[2].children, pgRowList(ref, pgRowList(pgRowAtom("queue-schema"), ref, pgRowList())))
					slices.SortFunc(closure.children[1].children, func(a, b pgRowCanonical) int { return strings.Compare(pgRowEncode(a), pgRowEncode(b)) })
					slices.SortFunc(closure.children[2].children, func(a, b pgRowCanonical) int { return strings.Compare(pgRowEncode(a), pgRowEncode(b)) })
					v["schemaContract"], v["schemaSnapshotHash"] = rowTestDoc("snapshot", schema)
					storage := pgRowDocument(reader, v["storageContract"].(string), v["storageSnapshotHash"].(string), "migration")
					storage.children[1] = schema
					v["storageContract"], v["storageSnapshotHash"] = rowTestDoc("migration", storage)
				}
				if kind == "later additive" {
					v := rowTestVersion(base, 1)
					next := map[string]any{}
					for key, value := range v {
						next[key] = value
					}
					next["version"] = 2
					rowTestDB(base)["versions"] = []any{v, next}
					orig := rowTestDB(base)["origins"].([]any)[0].(map[string]any)
					other := map[string]any{}
					for key, value := range orig {
						other[key] = value
					}
					other["initialVersion"] = 2
					rowTestDB(base)["origins"] = []any{orig, other}
					h.CurrentVersion = 2
					rowTestDB(base)["currentVersion"] = 2
					rowTestDB(companion)["currentVersion"] = 2
				}
			}, func(db *Database) {
				if kind == "declared cache" {
					pgRegisterMigrationFacility(db, "cache", "ActualAppCache")
				}
			})
			if kind == "unsealed app" { // A newly linked pointer has not passed App closure.
				fresh := NewDatabase("Unsealed", db.Config, nil)
				fresh.migrationHistory = db.migrationHistory
				databaseIdentities.Store(db.migrationHistory.Database, fresh)
				db = fresh
			}
			if kind == "wrong owner" {
				fresh := NewDatabase("Wrong", db.Config, nil)
				fresh.migrationHistory = db.migrationHistory
				db = fresh
			}
			if _, err := pgCompiledRowBaseline(db); err == nil {
				t.Fatal("source baseline guard accepted unsupported inventory/owner")
			}
			// A nil connection would panic if the source guard reached PostgreSQL.
			if _, err := InstallPgCompiledRowBaseline(f.ctx, nil, db, f.roles); err == nil {
				t.Fatal("unsupported baseline reached installation")
			}
			var exists bool
			if err := f.installer.QueryRow(f.ctx, `select exists(select 1 from pg_catalog.pg_namespace where nspname='notes_app')`).Scan(&exists); err != nil || exists {
				t.Fatal("source refusal had SQL effects", exists, err)
			}
		})
	}
}
func TestPgRowBaselineConcurrentInstallerAndWorkerConverge(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	for _, stage := range []string{"installer", "worker"} {
		t.Run(stage, func(t *testing.T) {
			config := f.installer.Config().Copy()
			if stage == "worker" {
				config = f.worker.Config().Copy()
			}
			one, err := pgx.ConnectConfig(f.ctx, config)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = one.Close(context.Background()) }()
			two, err := pgx.ConnectConfig(f.ctx, config)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = two.Close(context.Background()) }()
			type outcome struct {
				state PgMigrationControlState
				err   error
			}
			done := make(chan outcome, 2)
			start := make(chan struct{})
			for _, conn := range []*pgx.Conn{one, two} {
				go func() {
					<-start
					var state PgMigrationControlState
					var err error
					if stage == "installer" {
						state, err = InstallPgCompiledRowBaseline(f.ctx, conn, db, f.roles)
					} else {
						state, err = ExecutePgCompiledRowBaseline(f.ctx, conn, db, f.roles)
					}
					done <- outcome{state, err}
				}()
			}
			close(start)
			a, b := <-done, <-done
			if a.err != nil || b.err != nil || a.state.DatabaseUUID != b.state.DatabaseUUID || a.state.Format != 5 || a.state.Current != b.state.Current {
				t.Fatal("concurrent baseline diverged", a, b)
			}
		})
	}
}

func TestPgRowBaselineRetainedIndexNamesAreExact(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db := pgRowBaselineFixtureWith(t, f, func(_ *PgCompiledMigrationHistory, base, _ map[string]any) {
		v := rowTestVersion(base, 1)
		reader := &pgMigrationWireReader{}
		storage := pgRowDocument(reader, v["storageContract"].(string), v["storageSnapshotHash"].(string), "migration")
		storage.children[2].children[0].children[2] = pgRowList(pgRowList(pgRowAtom("notes_title"), pgRowList(pgRowAtom("title")), pgRowBoolNode(false)))
		v["storageContract"], v["storageSnapshotHash"] = rowTestDoc("migration", storage)
	})
	b := pgRowBaselineReady(t, f, db)
	if err := pgRowBaselineRead(t, f, request, b); err != nil {
		t.Fatal("correct exact index refused", err)
	}
	if _, err := f.worker.Exec(f.ctx, `alter index notes_app.notes_title rename to equivalent_but_unrecorded`); err != nil {
		t.Fatal(err)
	}
	if err := pgRowBaselineRead(t, f, request, b); err == nil || !strings.Contains(err.Error(), "index identity") {
		t.Fatal("same-shape different retained name accepted", err)
	}
}

func TestPgRowBaselineSharedEnvelopeKeepsDatabaseOwnersSeparate(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	h, base, companion := rowTestFixture(t)
	h.Namespace = f.namespace
	h.CurrentVersion = 1
	first := rowTestDB(base)
	first["namespace"] = h.Namespace
	first["currentVersion"] = 1
	first["versions"] = first["versions"].([]any)[:1]
	first["origins"] = first["origins"].([]any)[:1]
	firstCompanion := rowTestDB(companion)
	firstCompanion["namespace"] = h.Namespace
	firstCompanion["currentVersion"] = 1
	firstCompanion["transforms"] = []any{}
	var second, secondCompanion map[string]any
	if err := json.Unmarshal([]byte(rowTestJSON(t, first)), &second); err != nil || second == nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(rowTestJSON(t, firstCompanion)), &secondCompanion); err != nil || secondCompanion == nil {
		t.Fatal(err)
	}
	other := h
	other.Database += "Second"
	other.Family = strings.TrimSuffix(h.Family, "Schema") + "SecondSchema"
	other.Namespace = "other_app"
	second["database"], second["family"], second["namespace"] = other.Database, other.Family, other.Namespace
	secondCompanion["database"], secondCompanion["family"], secondCompanion["namespace"] = other.Database, other.Family, other.Namespace
	var rewrite func(pgRowCanonical) pgRowCanonical
	rewrite = func(node pgRowCanonical) pgRowCanonical {
		if node.atom {
			if node.value == h.Family {
				node.value = other.Family
			}
			return node
		}
		for i, child := range node.children {
			node.children[i] = rewrite(child)
		}
		return node
	}
	secondVersion := second["versions"].([]any)[0].(map[string]any)
	updateContract := func(object map[string]any, bytesKey, hashKey string) {
		node, _, err := pgReadRowCanonical(object[bytesKey].(string))
		if err != nil {
			t.Fatal(err)
		}
		node = rewrite(node)
		object[bytesKey], object[hashKey] = rowTestDoc(node.children[2].value, node.children[3])
	}
	updateContract(secondVersion, "schemaContract", "schemaSnapshotHash")
	updateContract(secondVersion, "storageContract", "storageSnapshotHash")
	updateContract(secondVersion["entities"].([]any)[0].(map[string]any), "typeContract", "typeContractHash")
	base["databases"] = []any{first, second}
	companion["databases"] = []any{firstCompanion, secondCompanion}
	h.HistoryJSON = rowTestJSON(t, base)
	other.HistoryJSON = h.HistoryJSON
	for _, history := range []PgCompiledMigrationHistory{h, other} {
		registerCompiledMigrationHistory(history.Database, history.Family, history.Namespace, 1, history.SourceCompilerABI, history.StoredValueCompatibility, history.HistoryJSON)
	}
	registerCompiledRowHistory(rowTestJSON(t, companion))
	t.Cleanup(func() {
		pgMigrationRegistrations.Lock()
		defer pgMigrationRegistrations.Unlock()
		delete(compiledRowRegistrations, compiledRowHistories[other.Family])
		delete(compiledRowHistories, other.Family)
		delete(pgMigrationClosedFamilies, other.Family)
		compiledMigrationHistories.Delete(other.Family)
		databaseIdentities.Delete(other.Database)
	})
	config := f.worker.Config()
	makeDB := func(history PgCompiledMigrationHistory) *Database {
		db := RegisterDatabaseMigrationHistory(RegisterDatabaseIdentity(history.Database, NewDatabase(history.Database, PostgresConfig{DBName: config.Database, User: f.roles.Request, Host: config.Host, Port: int(config.Port), Schema: history.Namespace, ControlOwner: f.roles.Owner, MigrationTopology: "Worker", RequestRole: f.roles.Request, WorkerRole: f.roles.Worker, DDLConnection: config.ConnString()}, nil)), history.Family)
		if err := PreflightApplicationDatabases(db); err != nil {
			t.Fatal(err)
		}
		pgRowBaselineReady(t, f, db)
		return db
	}
	one, two := makeDB(h), makeDB(other)
	WithDatabase(one, func() {
		firstPool := one.bound()
		defer firstPool.pool.Close()
		WithDatabase(two, func() {
			secondPool := two.bound()
			defer secondPool.pool.Close()
			if firstPool == secondPool || firstPool.pool == secondPool.pool || firstPool.schema != "notes_app" || secondPool.schema != "other_app" {
				t.Fatal("one shared source envelope aliased distinct Database owners")
			}
			PgExec(firstPool, `insert into notes_app.notes(id,title) values(1,'first owner')`, nil)
			PgExec(secondPool, `insert into other_app.notes(id,title) values(2,'second owner')`, nil)
			if PgCount(firstPool, `select count(*) from notes_app.notes where id=1 and title='first owner'`, nil).String() != "1" || PgCount(secondPool, `select count(*) from other_app.notes where id=2 and title='second owner'`, nil).String() != "1" {
				t.Fatal("owner-specific CRUD did not stay isolated")
			}
			if firstPool.migration.databaseUUID == secondPool.migration.databaseUUID || firstPool.migration.fenceNamespace == secondPool.migration.fenceNamespace {
				t.Fatal("distinct namespaces shared admission identity")
			}
		})
	})
}

func TestPgRowBaselineStatusDoesNotInventPendingIntent(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	b, err := pgCompiledRowBaseline(db)
	if err != nil {
		t.Fatal(err)
	}
	status, err := pgRowSchemaStatus(f.ctx, f.worker, b, f.roles)
	if err != nil || !status.Present || len(status.Expansions) != 0 || status.CurrentVersion != 0 {
		t.Fatal("status invented work before Worker intent", status, err)
	}
	var human bytes.Buffer
	if err := pgRunRowSchemaCommand(f.ctx, pgSchemaCommand{verb: "status"}, &human, db); err != nil || !strings.Contains(human.String(), "0/1 marker-bearing entities") {
		t.Fatal(human.String(), err)
	}
}

func TestPgRowBaselineCompilerOwnerBindingIsExact(t *testing.T) {
	for _, kind := range []string{"namespace", "actual pointer"} {
		t.Run(kind, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			db := pgRowBaselineFixture(t, f)
			if _, err := pgCompiledRowBaseline(db); err != nil {
				t.Fatal("valid owner", err)
			}
			if kind == "namespace" {
				db.Config.Schema = "foreign"
			} else {
				databaseIdentities.Store(db.migrationHistory.Database, NewDatabase("Other", db.Config, nil))
			}
			if _, err := pgCompiledRowBaseline(db); err == nil || !strings.Contains(err.Error(), "another database connection") {
				t.Fatal("compiler owner was replaced without refusal", err)
			}
		})
	}
}

func TestPgRowBaselineRetainedIndexNamesBindTheirExactShapes(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db := pgRowBaselineFixtureWith(t, f, func(_ *PgCompiledMigrationHistory, base, _ map[string]any) {
		v := rowTestVersion(base, 1)
		reader := &pgMigrationWireReader{}
		storage := pgRowDocument(reader, v["storageContract"].(string), v["storageSnapshotHash"].(string), "migration")
		storage.children[2].children[0].children[2] = pgRowList(pgRowList(pgRowAtom("notes_id"), pgRowList(pgRowAtom("id")), pgRowBoolNode(true)), pgRowList(pgRowAtom("notes_title"), pgRowList(pgRowAtom("title")), pgRowBoolNode(false)))
		v["storageContract"], v["storageSnapshotHash"] = rowTestDoc("migration", storage)
	})
	b := pgRowBaselineReady(t, f, db)
	if err := pgRowBaselineRead(t, f, request, b); err != nil {
		t.Fatal("correct two-index baseline refused", err)
	}
	if _, err := f.worker.Exec(f.ctx, `alter index notes_app.notes_id rename to temporary_name; alter index notes_app.notes_title rename to notes_id; alter index notes_app.temporary_name rename to notes_title`); err != nil {
		t.Fatal(err)
	}
	if err := pgRowBaselineRead(t, f, request, b); err == nil || !strings.Contains(err.Error(), "index identity") {
		t.Fatal("same name and shape sets lost their exact associations", err)
	}
}
