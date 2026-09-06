package migrationtest

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Build actual compiler variants in an isolated source tree. No ABI or history
// bytes in the emitted program are patched, and the working checkout is never
// edited. B differs only in query implementation source; C changes the declared
// stored-value semantics. Both still run the full checker and normal emitter.
func buildMigrationCompilerVariants(t *testing.T, ctx context.Context, root string) (string, string, string) {
	t.Helper()
	clone := t.TempDir()
	for _, directory := range []string{"compiler/lib", "compiler/bin", "compiler/gen", "runtime/go/teslrt"} {
		err := filepath.WalkDir(filepath.Join(root, directory), func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			relative, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			target := filepath.Join(clone, relative)
			if entry.IsDir() {
				return os.MkdirAll(target, 0700)
			}
			if !entry.Type().IsRegular() {
				t.Fatalf("unexpected special compiler input: %s", path)
			}
			contents, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			return os.WriteFile(target, contents, 0600)
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	project, err := os.ReadFile(filepath.Join(root, "compiler/dune-project"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(clone, "compiler/dune-project"), project, 0600); err != nil {
		t.Fatal(err)
	}
	// The ordinary build generator requires regular documentation inputs inside
	// its repository root. Copy those bytes rather than linking outside the clone;
	// documentation remains excluded from execution ABI and value compatibility.
	copyDocumentation := func(relative string) {
		t.Helper()
		path := filepath.Join(root, relative)
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() {
			t.Fatalf("compiler documentation input is not a regular file: %s (%v)", relative, err)
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(clone, relative), contents, 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"LANGUAGE-SPEC.md", "README.md", "INSTALL.md"} {
		copyDocumentation(name)
	}
	for _, directory := range []string{
		"manual", "dev-docs", "example", "example/learn", "example/intro",
		"example/kanel", "example/chat", "example/medical-journal_wip",
	} {
		info, err := os.Lstat(filepath.Join(root, directory))
		// gen_docs skips optional example/doc directories absent from the checkout.
		if os.IsNotExist(err) && directory != "manual" && directory != "example" {
			continue
		}
		if err != nil || !info.IsDir() {
			t.Fatalf("compiler documentation directory is not a real directory: %s (%v)", directory, err)
		}
		if err := os.MkdirAll(filepath.Join(clone, directory), 0700); err != nil {
			t.Fatal(err)
		}
		entries, err := os.ReadDir(filepath.Join(root, directory))
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if !entry.IsDir() && (strings.HasSuffix(entry.Name(), ".md") || strings.HasSuffix(entry.Name(), ".tesl")) {
				copyDocumentation(filepath.Join(directory, entry.Name()))
			}
		}
	}
	edit := func(name, old, replacement string) {
		t.Helper()
		path := filepath.Join(clone, "compiler/lib", name)
		source, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if old == "" {
			source = append(source, replacement...)
		} else {
			if strings.Count(string(source), old) != 1 {
				t.Fatalf("compiler compatibility test edit no longer identifies one declaration in %s", name)
			}
			source = []byte(strings.Replace(string(source), old, replacement, 1))
		}
		if err := os.WriteFile(path, source, 0600); err != nil {
			t.Fatal(err)
		}
	}
	build := func(name string) string {
		t.Helper()
		command := exec.CommandContext(ctx, "dune", "build", "bin/main.exe", "-j", "2")
		command.Dir = filepath.Join(clone, "compiler")
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("build compiler %s: %v\n%s", name, err, out)
		}
		contents, err := os.ReadFile(filepath.Join(clone, "compiler/_build/default/bin/main.exe"))
		if err != nil {
			t.Fatal(err)
		}
		binary := filepath.Join(t.TempDir(), "compiler-"+name)
		if err := os.WriteFile(binary, contents, 0700); err != nil {
			t.Fatal(err)
		}
		return binary
	}
	baseline := build("a")
	edit("compiler_query.ml", "", "\n(* Compiler-upgrade regression: query-only build change. *)\n")
	compatible := build("b")
	edit("migration_abi.ml", `let stored_value_semantics_revision = "tesl-stored-value-semantics-5"`,
		`let stored_value_semantics_revision = "tesl-stored-value-semantics-incompatible-test"`)
	incompatible := build("c")
	return baseline, compatible, incompatible
}

func frozenMigrationSources(t *testing.T, project string) map[string][]byte {
	t.Helper()
	result := map[string][]byte{}
	err := filepath.WalkDir(project, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || strings.Contains(path, "v-current") || !strings.HasSuffix(path, ".tesl") {
			return nil
		}
		name, err := filepath.Rel(project, path)
		if err != nil {
			return err
		}
		// A has completed V2 and currently targets V3. Its V2 migration is
		// frozen, including its closure seal; V3 is still an editable target.
		if !strings.HasPrefix(name, "schema/") && name != "migrations/additive-notes/v2.tesl" {
			return nil
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		result[name] = contents
		return nil
	})
	if err != nil || len(result) < 5 {
		t.Fatalf("frozen source fixture: %d files, %v", len(result), err)
	}
	return result
}

func assertChangedFrozenSourceRefuses(t *testing.T, ctx context.Context, compiler, project, entry string, frozen map[string][]byte) {
	t.Helper()
	for _, name := range []string{"schema/additive-notes/v1/notes.tesl", "migrations/additive-notes/v2.tesl"} {
		original, ok := frozen[name]
		if !ok {
			t.Fatalf("missing frozen compiler-upgrade source: %s", name)
		}
		path := filepath.Join(project, name)
		if err := os.WriteFile(path, append(append([]byte(nil), original...), "\n# Same meaning, different recorded bytes.\n"...), 0600); err != nil {
			t.Fatal(err)
		}
		assertMigrationCompilerRefuses(t, ctx, compiler, project, entry)
		if err := os.WriteFile(path, original, 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func assertFrozenMigrationSources(t *testing.T, project string, expected map[string][]byte) {
	t.Helper()
	for name, contents := range expected {
		actual, err := os.ReadFile(filepath.Join(project, name))
		if err != nil || !bytes.Equal(actual, contents) {
			t.Fatalf("compiler upgrade rewrote frozen source %s: %v", name, err)
		}
	}
}

func assertMigrationCompilerRefuses(t *testing.T, ctx context.Context, compiler, project, entry string) {
	t.Helper()
	command := exec.CommandContext(ctx, compiler, "agent-context", filepath.Join(project, entry))
	command.Dir = project
	out, err := command.CombinedOutput()
	if err == nil || !strings.Contains(string(out), "MIG013") {
		t.Fatalf("incompatible compiler accepted sealed source history: %v\n%s", err, out)
	}
}

func assertMigrationBuildRefuses(t *testing.T, ctx context.Context, compiler, project, entry string) {
	t.Helper()
	// Ordinary diagnostics judge sources under the current compiler. The
	// production build additionally checks authority to interpret stored values.
	output := filepath.Join(t.TempDir(), "refused-build")
	command := exec.CommandContext(ctx, compiler, filepath.Join(project, entry), "--out", output)
	command.Dir = project
	out, err := command.CombinedOutput()
	if err == nil || !strings.Contains(string(out), "MIG013") {
		t.Fatalf("incompatible compiler built sealed source history: %v\n%s", err, out)
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Fatalf("refused compatibility published build output: %v", err)
	}
}

func interruptLessonExpansion(t *testing.T, ctx context.Context, binary string, environment []string, boundary Event) {
	t.Helper()
	// Stop after the actual A executor commits its immutable intent, before
	// any DDL. B must not resume it even though its stored-value contract agrees.
	directory, err := os.MkdirTemp("", "tesl-upgrade-crash-")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.RemoveAll(directory) }()
	socket := filepath.Join(directory, "control.sock")
	schedule := NewSchedule(nil)
	if err := schedule.Pause(boundary); err != nil {
		t.Fatal(err)
	}
	controller, err := ListenProcesses(ctx, socket, schedule)
	if err != nil {
		t.Fatal(err)
	}
	defer controller.Close()
	command := exec.CommandContext(ctx, binary)
	command.Env = append(append([]string(nil), environment...), "TESL_MIGRATION_TEST_SOCKET="+socket, "TESL_MIGRATION_TEST_ACTOR=compiler-a", "NOTES_HTTP_PORT=0")
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	waited := false
	defer func() {
		if !waited {
			_ = command.Process.Kill()
			_ = command.Wait()
		}
	}()
	bounded, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := schedule.Await(bounded, boundary); err != nil {
		t.Fatal(err)
	}
	if err := command.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	err = command.Wait()
	waited = true
	if err == nil {
		t.Fatal("interrupted expansion exited successfully")
	}
	if err := schedule.Release(boundary); err != nil {
		t.Fatal(err)
	}
	// The killed peer may reject the final controller acknowledgement. It
	// cannot execute another SQL statement after Wait has joined the process.
}

func migrationUpgradeSnapshot(t *testing.T, ctx context.Context, conn *pgx.Conn) string {
	t.Helper()
	var snapshot string
	err := conn.QueryRow(ctx, `select jsonb_build_object(
 'meta',(select jsonb_agg(to_jsonb(m) order by id) from additive_notes.tesl_schema_meta m),
 'state',(select jsonb_agg(to_jsonb(s) order by id) from additive_notes.tesl_schema_state s),
 'history',(select jsonb_agg(to_jsonb(v) order by version,step,seq) from additive_notes.tesl_schema_versions v),
 'intents',(select jsonb_agg(to_jsonb(e) order by version) from additive_notes.tesl_schema_expansions e),
 'objects',(select jsonb_agg(to_jsonb(o) order by version,ordinal) from additive_notes.tesl_schema_expansion_objects o),
 'rows',(select jsonb_agg(to_jsonb(n) order by id) from additive_notes.lesson_migration_notes n),
 'columns',(select jsonb_agg(to_jsonb(c) order by table_name,ordinal_position) from information_schema.columns c where table_schema='additive_notes'))::text`).Scan(&snapshot)
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func assertMigrationStartupRefuses(t *testing.T, ctx context.Context, binary string, environment []string, conn *pgx.Conn, reason string) {
	t.Helper()
	before := migrationUpgradeSnapshot(t, ctx, conn)
	bounded, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	command := exec.CommandContext(bounded, binary)
	command.Env = append(append([]string(nil), environment...), "NOTES_HTTP_PORT=0")
	out, err := command.CombinedOutput()
	if err == nil || bounded.Err() != nil || !strings.Contains(strings.ToLower(string(out)), reason) {
		t.Fatalf("incompatible startup did not refuse before serving: %v\n%s", err, out)
	}
	if after := migrationUpgradeSnapshot(t, ctx, conn); after != before {
		t.Fatal("refused compiler startup changed schema, rows, history or durable progress")
	}
}

func assertMigrationBuildProvenance(t *testing.T, ctx context.Context, conn *pgx.Conn, abiA, abiB, compatibility string) {
	t.Helper()
	rows, err := conn.Query(ctx, "select version,source_abi,stored_value_compatibility from additive_notes.tesl_schema_expansions order by version")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		var version int
		var actualABI, actualCompatibility string
		if err := rows.Scan(&version, &actualABI, &actualCompatibility); err != nil {
			t.Fatal(err)
		}
		count++
		expectedABI := abiA
		if version == 4 {
			expectedABI = abiB
		}
		if version != count || actualABI != expectedABI || actualCompatibility != compatibility {
			t.Fatalf("compiler upgrade relabelled recorded provenance: V%d ABI=%s contract=%s", version, actualABI, actualCompatibility)
		}
	}
	if err := rows.Err(); err != nil || count != 4 {
		t.Fatalf("incomplete compiler-upgrade history: %d, %v", count, err)
	}
	var mismatches int
	err = conn.QueryRow(ctx, `select count(*) from additive_notes.tesl_schema_versions v
 join additive_notes.tesl_schema_expansions e using(version)
 where v.source_abi <> e.source_abi or v.stored_value_compatibility <> e.stored_value_compatibility`).Scan(&mismatches)
	if err != nil || mismatches != 0 {
		t.Fatalf("lifecycle provenance changed: %d, %v", mismatches, err)
	}
}
