//go:build tesl_migration_test

package teslrt

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestPgStagePreparationWorkerRegistrationBoundary(t *testing.T) {
	root := pgStagePrograms(t)
	f, _ := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	f.ctx = ctx
	pgStageInstall(t, f, root, "v2")
	stop := pgRowAdditiveWorker(t, f, root, "v2")
	pgAwaitStageIndexes(t, f, 2)
	stop()
	original := pgStageSnapshot(t, f)
	type registration struct {
		id, snapshot, physical, table, index, job string
		doc                                       []byte
		version, ordinal                          int
		columns                                   []string
	}
	rows, err := f.worker.Query(ctx, `select s.stage_id,s.descriptor,s.source_snapshot,s.introduced_version,s.physical_hash,s.table_name,s.index_name,s.job_id,j.ordinal,j.key_columns
 from notes.tesl_schema_stages s join notes.tesl_schema_index j on j.id=s.job_id order by s.stage_id`)
	if err != nil {
		t.Fatal(err)
	}
	var seeds []registration
	for rows.Next() {
		var seed registration
		if err := rows.Scan(&seed.id, &seed.doc, &seed.snapshot, &seed.version, &seed.physical, &seed.table, &seed.index, &seed.job, &seed.ordinal, &seed.columns); err != nil {
			t.Fatal(err)
		}
		seeds = append(seeds, seed)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	rows.Close()
	if len(seeds) != 2 {
		t.Fatal("fixture requires two different legitimate stage/index bindings", len(seeds))
	}
	call := func(seed registration) error {
		_, err := f.worker.Exec(ctx, `select notes.tesl_register_stage_preparation($1,$2,$3,$4,$5,$6,$7,$8)`,
			seed.id, seed.doc, seed.snapshot, seed.version, seed.job, seed.physical, seed.table, seed.index)
		return err
	}
	// Empty the pending inventory as fixture setup so unique constraints and
	// immutable-row replay checks cannot accidentally mask missing authorization.
	// Every adversarial call below is on the real Worker login, with real jobs.
	if _, err := f.installer.Exec(ctx, `delete from notes.tesl_schema_stages`); err != nil {
		t.Fatal(err)
	}
	refuse := func(t *testing.T, seed registration, reason string) {
		t.Helper()
		err := call(seed)
		var pgerr *pgconn.PgError
		if !errors.As(err, &pgerr) || pgerr.Code != "P0001" || !strings.Contains(pgerr.Message, reason) {
			t.Fatalf("expected mutation-boundary refusal %q, got %v", reason, err)
		}
		var count int
		if err := f.worker.QueryRow(ctx, `select count(*) from notes.tesl_schema_stages`).Scan(&count); err != nil || count != 0 {
			t.Fatal("rejected Worker call persisted stage state", count, err)
		}
	}
	decode := func(raw []byte) pgRowCanonical {
		t.Helper()
		node, _, err := pgReadRowCanonical(hex.EncodeToString(raw))
		if err != nil {
			t.Fatal(err)
		}
		return node
	}
	base := seeds[0]
	t.Run("fake-id", func(t *testing.T) {
		bad := base
		bad.id = strings.Repeat("0", 64)
		refuse(t, bad, "protected stage identity")
	})
	t.Run("mutated-descriptor", func(t *testing.T) {
		bad := base
		node := decode(base.doc)
		node.children[7] = pgRowAtom("int8")
		bad.doc = []byte(pgRowEncode(node))
		refuse(t, bad, "not a direct member")
	})
	t.Run("coherently-rehashed-descriptor", func(t *testing.T) {
		bad := base
		node := decode(base.doc)
		semantic := &node.children[2]
		semantic.children[4].children[1] = pgRowAtom("tesl-stored-value-v1:" + strings.Repeat("0", 64))
		document := pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("snapshot"), *semantic)
		bad.id = fmt.Sprintf("%x", sha256.Sum256([]byte(pgRowEncode(document))))
		node.children[1] = pgRowAtom(bad.id)
		bad.doc = []byte(pgRowEncode(node))
		if _, err := pgParseStagePreparations(pgRowList(node)); err != nil {
			t.Fatal("attack must have a coherent semantic ID and valid descriptor framing", err)
		}
		refuse(t, bad, "not a direct member")
	})
	t.Run("descriptor-from-other-stage", func(t *testing.T) {
		bad := base
		bad.id, bad.doc = seeds[1].id, seeds[1].doc
		refuse(t, bad, "protected stage identity/table/index/key")
	})
	t.Run("other-index-with-original-job", func(t *testing.T) {
		bad := seeds[1]
		bad.job = base.job
		refuse(t, bad, "exact registered nonunique job")
	})
	t.Run("wrong-job-columns", func(t *testing.T) {
		if _, err := f.installer.Exec(ctx, `update notes.tesl_schema_index set key_columns=$1 where id=$2`, seeds[1].columns, base.job); err != nil {
			t.Fatal(err)
		}
		refuse(t, base, "protected stage identity/table/index/key")
		if _, err := f.installer.Exec(ctx, `update notes.tesl_schema_index set key_columns=$1 where id=$2`, base.columns, base.job); err != nil {
			t.Fatal(err)
		}
	})

	var physical []byte
	if err := f.installer.QueryRow(ctx, `select contract from notes.tesl_row_physical where version=$1`, base.version).Scan(&physical); err != nil {
		t.Fatal(err)
	}
	// Synthetic protected plans isolate structural membership from all other
	// checks. Keep hashes and job/receipt linkage coherent and put the exact
	// candidate bytes inside an atom, a nested list, or a different root field.
	// Merely searching the protected byte string would authorize these attacks.
	for _, placement := range []string{"inside-atom", "nested-list", "different-field"} {
		t.Run(placement, func(t *testing.T) {
			node := decode(physical)
			body := &node.children[3]
			switch placement {
			case "inside-atom":
				body.children[8] = pgRowList(pgRowAtom(string(base.doc)))
			case "nested-list":
				body.children[8] = pgRowList(pgRowList(decode(base.doc)))
			case "different-field":
				body.children[6] = pgRowList(decode(base.doc))
				body.children[8] = pgRowList()
			}
			altered := []byte(pgRowEncode(node))
			if !bytes.Contains(altered, base.doc) {
				t.Fatal("fixture lacks the embedded descriptor")
			}
			bad := base
			bad.physical = fmt.Sprintf("%x", sha256.Sum256(altered))
			bad.job = pgMigrationObjectHash(bad.physical, base.ordinal)
			setPlan := func(doc []byte, hash, oldJob, newJob string) {
				t.Helper()
				if _, err := f.installer.Exec(ctx, `update notes.tesl_row_physical set contract=$1,contract_hash=$2 where version=$3`, doc, hash, base.version); err != nil {
					t.Fatal(err)
				}
				if _, err := f.installer.Exec(ctx, `update notes.tesl_schema_expansions set artefact_hash=$1 where version=$2`, hash, base.version); err != nil {
					t.Fatal(err)
				}
				if _, err := f.installer.Exec(ctx, `update notes.tesl_schema_index set id=$1 where id=$2`, newJob, oldJob); err != nil {
					t.Fatal(err)
				}
				if _, err := f.installer.Exec(ctx, `update notes.tesl_schema_expansion_objects set operation_hash=$1 where version=$2 and ordinal=$3`, newJob, base.version, base.ordinal); err != nil {
					t.Fatal(err)
				}
			}
			setPlan(altered, bad.physical, base.job, bad.job)
			refuse(t, bad, "not a direct member")
			setPlan(physical, base.physical, bad.job, base.job)
		})
	}
	for _, seed := range seeds {
		if err := call(seed); err != nil {
			t.Fatal("legitimate Worker registration", err)
		}
		if err := call(seed); err != nil {
			t.Fatal("exact registration replay", err)
		}
	}
	if pgStageSnapshot(t, f) != original {
		t.Fatal("legitimate registration/replay changed the original descriptor/provenance")
	}

	t.Run("parser-bounds-and-privileges", func(t *testing.T) {
		for _, malformed := range []string{
			"l01:s0:", "l1:s4:abc", "l0:trailing", "l1:x0:",
			"l1000001:", "l2147483648:", strings.Repeat("l1:", 514) + "l0:",
		} {
			if _, err := f.installer.Exec(ctx, `select notes.tesl_stage_canonical_children($1)`, []byte(malformed)); err == nil {
				t.Fatalf("malformed/unbounded canonical tree accepted: %.40q", malformed)
			}
		}
		if _, err := f.worker.Exec(ctx, `select notes.tesl_stage_canonical_children($1)`, []byte("l0:")); err == nil {
			t.Fatal("Worker may not call the owner-only parser helper")
		}
	})
}
