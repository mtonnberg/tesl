package migrationtest

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func contractFixtureSource(t *testing.T) string {
	t.Helper()
	source, err := os.ReadFile("testdata/contract-v8.sql")
	if err != nil {
		t.Fatal(err)
	}
	return string(source)
}

// INV-SQL-SOURCE; TR-SQL-DOCUMENT.
func TestContractDocumentMatchesExecutedFixture(t *testing.T) {
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		root = filepath.Join("..", "..", "..", "..")
	}
	path := filepath.Join(root, "roadmap", "next", "database-migrations.md")
	document, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := renderContractDocument(string(document), contractFixtureSource(t))
	if err != nil {
		t.Fatal(err)
	}
	if os.Getenv("TESL_UPDATE_MIGRATION_SQL_DOCS") == "1" {
		if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
			t.Fatal(err)
		}
	} else if updated != string(document) {
		t.Fatal("documented contract differs from executed testdata/contract-v8.sql; run TESL_UPDATE_MIGRATION_SQL_DOCS=1 go test ./internal/migrationtest -run '^TestContractDocumentMatchesExecutedFixture$'")
	}
}

type contractHarness struct {
	f                  *databaseFixture
	coordinator, batch *pgx.Conn
	model              *Model
	steps              []fixtureStep
	heldJobs           bool
}

func newContractHarness(t *testing.T) *contractHarness {
	t.Helper()
	f := newDatabaseFixture(t)
	f.expanded(t, 8)
	f.exec(t, "set role "+f.worker)
	f.exec(t, `create table `+f.schema+`.notes (
		id int primary key, content text not null, "authorId" text not null,
		"legacyRank" numeric not null default 0, "createdAt" bigint not null default 0,
		"ownerId" text, "wordCount" numeric, _tesl_v smallint not null default 3)`)
	f.exec(t, `create function `+f.schema+`.tesl_mig_notes_g4() returns trigger language plpgsql
		set search_path=pg_catalog,`+f.schema+`,pg_temp as $$ begin
		if coalesce(nullif(current_setting('tesl.writer.notes',true),'')::int,0)<4
		and (new.content is distinct from old.content or new."authorId" is distinct from old."authorId")
		then new._tesl_v:=least(new._tesl_v,3); end if; return new; end $$`)
	f.exec(t, "create trigger tesl_mig_notes_g4 before update on "+f.schema+".notes for each row execute function "+f.schema+".tesl_mig_notes_g4()")
	f.exec(t, `create index notes_authorId_idx on `+f.schema+`.notes("authorId")`)
	f.exec(t, "create index notes_tesl_v_g4_idx on "+f.schema+".notes(id) where _tesl_v<4")
	f.exec(t, `insert into `+f.schema+`.notes(id,content,"authorId","ownerId","wordCount",_tesl_v)
		values (1,'hello world','a',null,null,3),(2,'untouched','b','b',999,4)`)
	f.exec(t, "reset role")
	f.exec(t, "insert into "+f.schema+".tesl_schema_entities(entity,generation,target_generation) values ('Note',3,4)")
	f.exec(t, "insert into "+f.schema+".tesl_jobs values ('pending',7,'pending'),('dead',7,'dead')")
	f.exec(t, "grant select,update on "+f.schema+".tesl_jobs to "+f.worker)
	f.exec(t, "insert into "+f.schema+".tesl_schema_index(name,state) values ('notes_authorid_idx','ready'),('notes_tesl_v_g4_idx','ready')")
	steps, err := readFixtureSteps(contractFixtureSource(t))
	if err != nil {
		t.Fatal(err)
	}
	m := NewModel(7, "migration-7")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "migration-8", Additive: true},
		Op{Kind: "row-add", ID: "1", Generation: 3}, Op{Kind: "row-add", ID: "2", Generation: 3}, Op{Kind: "backfill", ID: "2"},
		Op{Kind: "enqueue", ID: "pending", Version: 7}, Op{Kind: "enqueue", ID: "dead", Version: 7},
		Op{Kind: "claim", ID: "dead", Version: 7, Ticks: 1}, Op{Kind: "dead", ID: "dead", Version: 7, Attempt: 1})
	h := &contractHarness{f: f, model: m, steps: steps, batch: f.other(t)}
	f.execOn(t, h.batch, "set role "+f.worker)
	h.connectCoordinator(t)
	return h
}

func (h *contractHarness) connectCoordinator(t *testing.T) {
	t.Helper()
	h.coordinator = h.f.other(t)
	h.heldJobs = false
	h.f.execOn(t, h.coordinator, "set role "+h.f.worker)
	h.f.execOn(t, h.coordinator, "set lock_timeout='2s'")
	h.f.execOn(t, h.coordinator, "set search_path=''")
	// The recipe is one coordinator's work, serialized against competing boots.
	h.f.execOn(t, h.coordinator, "select pg_advisory_lock($1,2147483647)", h.f.fence)
}

func (h *contractHarness) bind(sql string) string {
	return strings.NewReplacer("notes_app", h.f.schema, ":fence_ns", fmt.Sprint(h.f.fence),
		":retirement_plan_hash", "'retirement'", ":protocol_level", "1", ":fence_domain", "'tesl-1'", ":holder", "'fixture'",
		":contract_hash", "'contract'", ":snapshot_hash", "'snapshot-9'", ":migration_hash", "'migration-9'", ":epoch_preserving", "true").Replace(sql)
}

func (h *contractHarness) constraintDefinition(name string) (string, bool, error) {
	var expression string
	var valid bool
	err := h.coordinator.QueryRow(h.f.ctx, `select pg_get_expr(c.conbin,c.conrelid),c.convalidated
		from pg_constraint c where c.conrelid=$1::regclass and c.conname=$2 and c.contype='c'`, h.f.schema+".notes", name).Scan(&expression, &valid)
	return expression, valid, err
}

func (h *contractHarness) ensureConstraint(name, expression string) error {
	// Parse the expected expression using this server and the same column types,
	// then compare both server-deparsed trees under the same empty search_path.
	// No text normalization guesses about parentheses, casts or name resolution.
	_, err := h.coordinator.Exec(h.f.ctx, `create temporary table tesl_expected_check ("wordCount" numeric,"ownerId" text,
		constraint expected check (`+expression+`))`)
	if err != nil {
		return err
	}
	defer func() { _, _ = h.coordinator.Exec(h.f.ctx, "drop table pg_temp.tesl_expected_check") }()
	var expected string
	err = h.coordinator.QueryRow(h.f.ctx, `select pg_get_expr(conbin,conrelid) from pg_constraint where conrelid='pg_temp.tesl_expected_check'::regclass and conname='expected'`).Scan(&expected)
	if err != nil {
		return err
	}
	actual, _, err := h.constraintDefinition(name)
	if errors.Is(err, pgx.ErrNoRows) {
		_, err = h.coordinator.Exec(h.f.ctx, "alter table "+h.f.schema+".notes add constraint "+pgx.Identifier{name}.Sanitize()+" check ("+expression+") not valid")
		return err
	}
	if err != nil {
		return err
	}
	if actual != expected {
		return fmt.Errorf("catalog drift: constraint %s is %s, expected %s", name, actual, expected)
	}
	return nil
}

func (h *contractHarness) hook(t *testing.T, name string) error {
	t.Helper()
	f := h.f
	switch name {
	case "final-pass":
		rows, err := h.batch.Query(f.ctx, `select id,content,"authorId" from `+f.schema+`.notes where _tesl_v<4 order by id`)
		if err != nil {
			return err
		}
		type row struct {
			ID              int
			Content, Author string
		}
		values, err := pgx.CollectRows(rows, pgx.RowToStructByPos[row])
		if err != nil {
			return err
		}
		for _, value := range values {
			// Symbolic recipe fixture, not the eventual generated Tesl transform.
			_, err = h.batch.Exec(f.ctx, `update `+f.schema+`.notes set "ownerId"=$2,"wordCount"=$3,_tesl_v=4 where id=$1 and _tesl_v=3`, value.ID, value.Author, len(strings.Fields(value.Content)))
			if err != nil {
				return err
			}
			apply(t, h.model, Op{Kind: "backfill", ID: fmt.Sprint(value.ID)})
		}
	case "jobs-retire":
		_, err := h.batch.Exec(f.ctx, "update "+f.schema+".tesl_jobs set schema_version=8 where schema_version=7 and status in ('pending','dead')")
		if err != nil {
			return err
		}
		for _, id := range []string{"pending", "dead"} {
			if h.model.Jobs[id].Version < 8 {
				apply(t, h.model, Op{Kind: "restamp", ID: id, Version: 8})
			}
		}
	case "terminal-jobs":
		if !h.heldJobs {
			for _, key := range []int64{int64(f.fence)<<32 | 101, int64(f.fence)<<32 | 102} {
				if _, err := h.coordinator.Exec(f.ctx, "select pg_advisory_lock($1::bigint)", key); err != nil {
					return err
				}
			}
			h.heldJobs = true
		}
		var valid bool
		if err := h.coordinator.QueryRow(f.ctx, "select count(*)=2 and bool_and(terminal_version is null or terminal_version=8) from "+f.schema+".tesl_schema_index where name in ('notes_authorid_idx','notes_tesl_v_g4_idx')").Scan(&valid); err != nil {
			return err
		}
		if !valid {
			return fmt.Errorf("contract index jobs are missing or have a different removal version")
		}
		_, err := h.coordinator.Exec(f.ctx, "update "+f.schema+".tesl_schema_index set state='terminal',terminal_version=8 where name in ('notes_authorid_idx','notes_tesl_v_g4_idx')")
		return err
	case "wait-plan-switch":
		var pending int
		if err := h.coordinator.QueryRow(f.ctx, "select count(*) from "+f.schema+".tesl_schema_instances where version<=8 and compat_floor_seen<8").Scan(&pending); err != nil {
			return err
		}
		if pending != 0 {
			return fmt.Errorf("fixture has unacknowledged instances")
		}
	case "ensure-wordcount-check":
		return h.ensureConstraint("notes_wordcount_nn", `"wordCount" is not null`)
	case "ensure-owner-check":
		return h.ensureConstraint("notes_owner_nn", `"ownerId" is not null`)
	case "ensure-wordcount-proof":
		return h.ensureConstraint("notes_wordcount_nonnegative", `"wordCount">=0`)
	case "validate-wordcount-check", "validate-owner-check", "validate-wordcount-proof":
		constraint := map[string]string{"validate-wordcount-check": "notes_wordcount_nn", "validate-owner-check": "notes_owner_nn", "validate-wordcount-proof": "notes_wordcount_nonnegative"}[name]
		_, valid, err := h.constraintDefinition(constraint)
		if err != nil {
			return err
		}
		if !valid {
			_, err = h.coordinator.Exec(f.ctx, "alter table "+f.schema+".notes validate constraint "+constraint)
		}
		return err
	case "release-job-locks":
		if !h.heldJobs {
			return fmt.Errorf("contract dropped its job locks before completion")
		}
		for _, key := range []int64{int64(f.fence)<<32 | 102, int64(f.fence)<<32 | 101} {
			var unlocked bool
			if err := h.coordinator.QueryRow(f.ctx, "select pg_advisory_unlock($1::bigint)", key).Scan(&unlocked); err != nil {
				return err
			}
			if !unlocked {
				return fmt.Errorf("contract lost DDL-job lock")
			}
		}
		h.heldJobs = false
	default:
		return fmt.Errorf("unknown contract fixture hook %q", name)
	}
	return nil
}

func (h *contractHarness) runStep(t *testing.T, step fixtureStep) error {
	t.Helper()
	var err error
	switch step.Kind {
	case "sql":
		_, err = h.coordinator.Exec(h.f.ctx, h.bind(step.Text))
	case "zero":
		var count int
		err = h.coordinator.QueryRow(h.f.ctx, h.bind(step.Text)).Scan(&count)
		if err == nil && count != 0 {
			err = fmt.Errorf("%s postcondition: %d unfinished rows", step.Name, count)
		}
	case "hook":
		err = h.hook(t, step.Name)
	default:
		err = fmt.Errorf("unknown fixture step kind %q", step.Kind)
	}
	if err != nil {
		return fmt.Errorf("%s: %w", step.Name, err)
	}
	switch step.Name {
	case "fence-v7":
		apply(t, h.model, Op{Kind: "retire-begin", Version: 8})
	case "commit-retirement":
		apply(t, h.model, Op{Kind: "retire-commit", Version: 8})
	case "begin-contract":
		if h.model.Versions[8] == "expanded" {
			apply(t, h.model, Op{Kind: "contract-begin", Version: 8})
		}
	case "record-contracted":
		if h.model.Versions[8] == "contracting" {
			apply(t, h.model, Op{Kind: "contract-end", Version: 8})
		}
	case "expand-v9":
		apply(t, h.model, Op{Kind: "expand", Version: 9, Hash: "migration-9", Additive: true})
	}
	h.assertState(t)
	return nil
}

func (h *contractHarness) assertState(t *testing.T) {
	t.Helper()
	var floor, compat, current, oldColumns, trigger int
	err := h.f.conn.QueryRow(h.f.ctx, `select min_version,compat_floor,current,
		(select count(*) from pg_attribute where attrelid=$1::regclass and not attisdropped and attname in ('authorId','legacyRank')),
		(select count(*) from pg_trigger where tgrelid=$1::regclass and tgname='tesl_mig_notes_g4')
		from `+h.f.schema+`.tesl_schema_state`, h.f.schema+".notes").Scan(&floor, &compat, &current, &oldColumns, &trigger)
	if err != nil {
		t.Fatal(err)
	}
	if floor != h.model.Floor || compat != h.model.Compat || current != h.model.Expanded {
		t.Fatalf("contract state SQL=(%d,%d,%d), model=(%d,%d,%d)", floor, compat, current, h.model.Floor, h.model.Compat, h.model.Expanded)
	}
	if (oldColumns != 2 || trigger != 1) && compat < 8 {
		t.Fatal("destructive DDL preceded the plan switch")
	}
	var prematureDrop bool
	if err := h.f.conn.QueryRow(h.f.ctx, `select exists(select 1 from `+h.f.schema+`.tesl_schema_index
		where name in ('notes_authorid_idx','notes_tesl_v_g4_idx') and to_regclass($1||'.'||name) is null
		and (state<>'terminal' or terminal_version is distinct from 8 or terminal_version>$2))`, h.f.schema, compat).Scan(&prematureDrop); err != nil {
		t.Fatal(err)
	}
	if prematureDrop {
		t.Fatal("index drop preceded its exact terminal target and plan switch")
	}
	for _, id := range []string{"1", "2"} {
		var generation int
		if err := h.f.conn.QueryRow(h.f.ctx, "select _tesl_v from "+h.f.schema+".notes where id=$1::int", id).Scan(&generation); err != nil {
			t.Fatal(err)
		}
		if generation != h.model.Rows[id].Generation {
			t.Fatalf("row %s SQL generation %d differs from oracle %d", id, generation, h.model.Rows[id].Generation)
		}
	}
	if h.model.Versions[8] == "contracted" && (oldColumns != 0 || trigger != 0) {
		t.Fatal("contracted history published before destructive work finished")
	}
	var retired, contracting, contracted int
	if err := h.f.conn.QueryRow(h.f.ctx, `select
		count(*) filter(where version=7 and step='retired'),
		count(*) filter(where version=8 and step='contracting'),
		count(*) filter(where version=8 and step='contracted') from `+h.f.schema+`.tesl_schema_versions`).Scan(&retired, &contracting, &contracted); err != nil {
		t.Fatal(err)
	}
	if (retired == 1) != (h.model.Floor == 8) || (contracting == 1) != (h.model.Compat == 8) || (contracted == 1) != (h.model.Versions[8] == "contracted") {
		t.Fatalf("contract history SQL=(%d,%d,%d) disagrees with the oracle", retired, contracting, contracted)
	}
	for _, id := range []string{"pending", "dead"} {
		var version int
		var status string
		if err := h.f.conn.QueryRow(h.f.ctx, "select schema_version,status from "+h.f.schema+".tesl_jobs where id=$1", id).Scan(&version, &status); err != nil {
			t.Fatal(err)
		}
		if expected := h.model.Jobs[id]; version != expected.Version || status != expected.Status {
			t.Fatalf("job %s SQL=(%d,%s), model=(%d,%s)", id, version, status, expected.Version, expected.Status)
		}
	}
	if contracted == 1 {
		var settled bool
		err := h.f.conn.QueryRow(h.f.ctx, `select
			to_regclass($1||'.notes_authorid_idx') is null and to_regclass($1||'.notes_tesl_v_g4_idx') is null
			and to_regprocedure($1||'.tesl_mig_notes_g4()') is null
			and (select count(*)=2 and bool_and(attnotnull) from pg_attribute where attrelid=($1||'.notes')::regclass and attname in ('ownerId','wordCount'))
			and (select count(*)=1 and bool_and(convalidated) from pg_constraint where conrelid=($1||'.notes')::regclass and conname='notes_wordcount_nonnegative')
			and not exists(select 1 from pg_constraint where conrelid=($1||'.notes')::regclass and conname in ('notes_wordcount_nn','notes_owner_nn'))`, h.f.schema).Scan(&settled)
		if err != nil || !settled {
			t.Fatalf("contracted history has unfinished catalog work: %t %v", settled, err)
		}
	}
}

func (h *contractHarness) resume(t *testing.T) {
	t.Helper()
	// Recovery chooses its next step from the durable database, independently
	// of the reference model used to check each resulting transition.
	var current, floor int
	var contracted bool
	err := h.coordinator.QueryRow(h.f.ctx, "select current,min_version,exists(select 1 from "+h.f.schema+".tesl_schema_versions where version=8 and step='contracted') from "+h.f.schema+".tesl_schema_state").Scan(&current, &floor, &contracted)
	if err != nil {
		t.Fatal(err)
	}
	if current == 9 {
		return
	}
	start := "begin-retirement"
	if floor == 8 {
		start = "terminal-jobs"
	}
	if contracted {
		start = "add-archived"
	}
	running := false
	for _, step := range h.steps {
		running = running || step.Name == start
		if running {
			if err := h.runStep(t, step); err != nil {
				t.Fatalf("resume: %v\n%s", err, h.f.dump())
			}
		}
	}
}

// INV-CONTRACT, INV-FINAL, INV-FLOOR, INV-HISTORY, INV-DDL-TERMINAL, INV-SQL-SOURCE;
// TR-RETIRE, TR-CONTRACT, TR-BACKFILL, TR-RESTAMP, TR-CRASH, TR-EXPAND, TR-SQL-DOCUMENT.
func TestPostgresContractFixtureResumesAfterEveryStep(t *testing.T) {
	steps, err := readFixtureSteps(contractFixtureSource(t))
	if err != nil {
		t.Fatal(err)
	}
	for boundary := 0; boundary <= len(steps); boundary++ {
		name := "before-first"
		if boundary > 0 {
			name = steps[boundary-1].Name
		}
		t.Run(name, func(t *testing.T) {
			h := newContractHarness(t)
			for _, step := range h.steps[:boundary] {
				if err := h.runStep(t, step); err != nil {
					t.Fatalf("%v\n%s", err, h.f.dump())
				}
			}
			terminateBootstrapBackend(t, h.f, h.coordinator)
			apply(t, h.model, Op{Kind: "crash"})
			h.assertState(t)
			h.connectCoordinator(t)
			h.resume(t)
			h.assertState(t)
			var correct bool
			err := h.f.conn.QueryRow(h.f.ctx, `select count(*)=2 and bool_and("ownerId"=case id when 1 then 'a' else 'b' end)
				and bool_and("wordCount"=case id when 1 then 2 else 999 end) and bool_and("archivedAt" is null) from `+h.f.schema+`.notes`).Scan(&correct)
			if err != nil || !correct {
				t.Fatalf("recovery reinterpreted accepted rows or lost data: %t %v", correct, err)
			}
			for _, statement := range []string{`update ` + h.f.schema + `.notes set "wordCount"=-1 where id=1`, `update ` + h.f.schema + `.notes set "wordCount"=null where id=1`, `update ` + h.f.schema + `.notes set "ownerId"=null where id=1`} {
				if _, err := h.f.conn.Exec(h.f.ctx, statement); err == nil {
					t.Fatalf("settled constraints missing: %s", statement)
				}
			}
			if _, err := h.f.conn.Exec(h.f.ctx, "select "+h.f.schema+".tesl_admit(7)"); err == nil {
				t.Fatal("retired V7 admitted after contract")
			}
		})
	}
}

// INV-CONTRACT, INV-SQL-SOURCE; TR-CONTRACT, TR-SQL-DOCUMENT.
func TestPostgresContractConstraintComparatorUsesServerSemantics(t *testing.T) {
	h := newContractHarness(t)
	for _, expression := range []string{`"wordCount" IS NOT NULL`, `(("wordCount") is not null)`} {
		if err := h.ensureConstraint("notes_wordcount_nn", expression); err != nil {
			t.Fatal(err)
		}
	}
	_, valid, err := h.constraintDefinition("notes_wordcount_nn")
	if err != nil || valid {
		t.Fatalf("new CHECK was not left NOT VALID: %t %v", valid, err)
	}
	if err := h.ensureConstraint("notes_wordcount_nn", `"wordCount">=0`); err == nil || !strings.Contains(err.Error(), "catalog drift") {
		t.Fatalf("different CHECK adopted: %v", err)
	}
	if err := h.hook(t, "unknown"); err == nil {
		t.Fatal("unknown fixture hook silently skipped")
	}
}

// INV-DDL-TERMINAL, INV-CONTRACT; TR-INDEX-TERMINAL, TR-CONTRACT.
func TestPostgresContractRefusesChangedIndexRemovalIdentity(t *testing.T) {
	h := newContractHarness(t)
	for _, step := range h.steps {
		if step.Name == "terminal-jobs" {
			break
		}
		if err := h.runStep(t, step); err != nil {
			t.Fatal(err)
		}
	}
	h.f.exec(t, "update "+h.f.schema+".tesl_schema_index set state='terminal',terminal_version=9 where name='notes_authorid_idx'")
	if err := h.hook(t, "terminal-jobs"); err == nil || !strings.Contains(err.Error(), "different removal version") {
		t.Fatalf("adopted an index job belonging to a different contract: %v", err)
	}
	var unchanged bool
	err := h.f.conn.QueryRow(h.f.ctx, `select
		(select terminal_version=9 from `+h.f.schema+`.tesl_schema_index where name='notes_authorid_idx') and
		(select state='ready' and terminal_version is null from `+h.f.schema+`.tesl_schema_index where name='notes_tesl_v_g4_idx') and
		to_regclass($1||'.notes_authorid_idx') is not null and to_regclass($1||'.notes_tesl_v_g4_idx') is not null`, h.f.schema).Scan(&unchanged)
	if err != nil || !unchanged {
		t.Fatalf("refused contract changed its catalog or job evidence: %t %v", unchanged, err)
	}
	for _, assignment := range []string{"terminal_version=null", "terminal_version=0", "terminal_version=2147483647", "state='pending'"} {
		if _, err := h.f.conn.Exec(h.f.ctx, "update "+h.f.schema+".tesl_schema_index set "+assignment+" where name='notes_authorid_idx'"); err == nil {
			t.Fatalf("accepted inconsistent terminal evidence: %s", assignment)
		}
	}
}
