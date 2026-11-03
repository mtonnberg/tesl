//go:build tesl_migration_test

package teslrt

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgStageGuardReviewedAuthorityBoundary(t *testing.T) {
	root := os.Getenv("TESL_STAGE_GUARD_PROGRAMS")
	if root == "" {
		t.Skip("compiled stage lifecycle programs required")
	}
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f, _ := pgNewWorkerTest(t)
	f.namespace = "notes"
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	pgStageInstall(t, f, root, "v3-contract")
	if out, err := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "catch-up", "--json").CombinedOutput(); err != nil {
		t.Fatalf("setup: %v %s", err, out)
	}
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"stage-contract-after-intent", 1}})
	defer pauses[0].resume()
	cmd := pgRowAdditiveCommand(f, root, "v3-contract", "--schema", "contract", "V3", "--json")
	cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	var output pgRowAppOutput
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	joined := false
	defer func() {
		if !joined {
			_ = cmd.Process.Kill()
			<-done
		}
	}()
	select {
	case <-pauses[0].arrived:
	case err := <-done:
		joined = true
		t.Fatalf("source capture: %v %s", err, output.String())
	case <-ctx.Done():
		t.Fatal("source capture timeout")
	}
	var contract, settled, physical []byte
	var abi, compat string
	if err := f.installer.QueryRow(ctx, `select c.contract,c.settled,c.compiler_abi,p.contract,p.stored_value_compatibility from notes.tesl_schema_stage_contracts c join notes.tesl_row_physical p on p.version=c.version where c.version=3`).Scan(&contract, &settled, &abi, &physical, &compat); err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(ctx, `delete from notes.tesl_schema_stage_contracts where version=3`); err != nil {
		t.Fatal(err)
	}
	decode := func(raw []byte) pgRowCanonical {
		t.Helper()
		n, _, err := pgReadRowCanonical(hex.EncodeToString(raw))
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	digest := func(raw []byte) string { return fmt.Sprintf("%x", sha256.Sum256(raw)) }
	invoke := func(c, s pgRowCanonical) error {
		rawSettled := []byte(pgRowEncode(s))
		body := &c.children[3]
		body.children[7] = pgRowAtom(digest(rawSettled))
		behavior := pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("contract"), pgRowList(pgRowAtom("tesl-stage-promotion-v1"), body.children[9]))
		body.children[5] = pgRowAtom(digest([]byte(pgRowEncode(behavior))))
		raw := []byte(pgRowEncode(c))
		_, err := f.worker.Exec(ctx, `select notes.tesl_register_stage_contract(3,$1,$2,$3,$4,$5)`, raw, digest(raw), rawSettled, digest(rawSettled), abi)
		return err
	}
	for _, kind := range []string{"retarget", "nested-operation", "omitted-stage", "settled-marker"} {
		c, s := decode(contract), decode(settled)
		switch kind {
		case "retarget":
			c.children[3].children[9].children[0].children[2].children[2].children[0] = pgRowAtom("forged_unique")
		case "nested-operation":
			c.children[3].children[9].children[0] = pgRowAtom(pgRowEncode(c.children[3].children[9].children[0]))
		case "omitted-stage":
			c.children[3].children[9].children = c.children[3].children[9].children[1:]
		case "settled-marker":
			s.children[3].children[6].children[0].children[3] = pgRowAtom("99")
		}
		if err := invoke(c, s); err == nil {
			t.Fatal("forged reviewed authority accepted", kind)
		}
		var count int
		if err := f.worker.QueryRow(ctx, `select count(*) from notes.tesl_schema_stage_contracts`).Scan(&count); err != nil || count != 0 {
			t.Fatal("forged authority mutated state", kind, count, err)
		}
	}
	if err := invoke(decode(contract), decode(settled)); err != nil {
		t.Fatal("legitimate reviewed source rejected", err)
	}
	if _, err := f.worker.Exec(ctx, `select notes.tesl_stage_handoff(3,$1)`, digest(contract)); err == nil || !strings.Contains(err.Error(), "retirement") {
		t.Fatal("premature handoff", err)
	}
	// A coherent V4 shape is still not authority without physical enforcement.
	candidate := decode(settled)
	base := decode(physical).children[3]
	candidate.children[3].children[0] = pgRowAtom("tesl-retained-physical-version-v11")
	candidate.children[3].children[3] = pgRowAtom("4")
	candidate.children[3].children = append(candidate.children[3].children, base.children[8], pgRowList(pgRowAtom("staged-unique-reliance-v1"), pgRowAtom("3"), base.children[9]))
	raw := []byte(pgRowEncode(candidate))
	if _, err := f.worker.Exec(ctx, `select notes.tesl_register_row_physical(4,$1,$2,$3,$4,$5,0,true)`, digest(settled), raw, digest(raw), abi, compat); err == nil || !strings.Contains(err.Error(), "durable enforcement") {
		t.Fatal("premature V4 physical registration", err)
	}
	var unique int
	if err := f.worker.QueryRow(ctx, `select count(*) from notes.tesl_schema_index where is_unique`).Scan(&unique); err != nil || unique != 0 {
		t.Fatal("premature targets were registered", unique, err)
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	<-done
	joined = true
	pauses[0].resume()
}
