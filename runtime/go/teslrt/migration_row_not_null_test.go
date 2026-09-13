package teslrt

import (
	"testing"
)

func TestPgRowStagedNotNullCatalogBindsExactProof(t *testing.T) {
	for _, test := range []struct {
		name, sql     string
		valid, accept bool
	}{
		{"exact quoted physical column", `check ("user" is not null) not valid`, false, true},
		{"missing validation", `check ("user" is not null) not valid`, true, false},
		{"unexpected validation", `check ("user" is not null)`, false, false},
		{"validated exact", `check ("user" is not null)`, true, true},
		{"same carrier different column", `check (other is not null) not valid`, false, false},
		{"weaker null proof", `check ("user" is not null or other is not null) not valid`, false, false},
		{"inheritance differs", `check ("user" is not null) no inherit not valid`, false, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := pgNewControlTest(t)
			if _, err := f.installer.Exec(f.ctx, `create schema proof_probe;create table proof_probe.sample("user" bigint,other bigint);alter table proof_probe.sample add constraint exact_proof `+test.sql); err != nil {
				t.Fatal(err)
			}
			tx, err := f.installer.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(f.ctx) }()
			actual, err := pgReadMigrationTable(f.ctx, tx, "proof_probe", "sample")
			if err != nil || actual == nil {
				t.Fatal(err)
			}
			err = pgVerifyRowNotNullProofs(f.ctx, tx, "proof_probe", actual, map[string]pgRowNotNullProof{"exact_proof": {name: "exact_proof", physical: "user", validated: test.valid}})
			if (err == nil) != test.accept {
				t.Fatal("exact staged proof acceptance", test.accept, err)
			}
			if test.accept && len(actual.Constraints) != 0 {
				t.Fatal("exact proof not isolated from complete base comparison")
			}
		})
	}
	t.Run("equivalent renamed proof cannot substitute", func(t *testing.T) {
		f := pgNewControlTest(t)
		if _, err := f.installer.Exec(f.ctx, `create schema proof_probe;create table proof_probe.sample("user" bigint);alter table proof_probe.sample add constraint other_name check ("user" is not null) not valid`); err != nil {
			t.Fatal(err)
		}
		tx, err := f.installer.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(f.ctx) }()
		actual, err := pgReadMigrationTable(f.ctx, tx, "proof_probe", "sample")
		if err != nil || actual == nil {
			t.Fatal(err)
		}
		if err := pgVerifyRowNotNullProofs(f.ctx, tx, "proof_probe", actual, map[string]pgRowNotNullProof{"exact_proof": {name: "exact_proof", physical: "user"}}); err == nil {
			t.Fatal("equivalent renamed proof substituted")
		}
	})
}
