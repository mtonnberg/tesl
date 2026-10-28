package teslrt

import (
	"strings"
	"testing"
)

func TestPgMigrationQualifiedFamilyNames(t *testing.T) {
	for _, family := range []string{"Schema.Todo", "Schema.MyTodos", "Schema.Todo_2", "TodoSchema", "MyTodosSchema", "Todo_2Schema"} {
		t.Run(family, func(t *testing.T) {
			if !pgMigrationFamily(family) {
				t.Fatal("compiler-supported family refused")
			}
			history := pgPlanTestHistory()
			history.HistoryJSON = strings.ReplaceAll(history.HistoryJSON, `"NotesSchema"`, `"`+family+`"`)
			history.Family = family
			if _, err := history.ExpansionPlan(1); err != nil {
				t.Fatalf("qualified compiled history did not decode: %v", err)
			}
		})
	}
	for _, family := range []string{"", "Schema", "Schema.", "Schema.todo", "schema.Todo", "Schema.Todo.VCurrent", "Schema.Todo.Other",
		"Schema.Todo/Outside", "Schema..Todo", "Todo", "todoSchema", "Todo.Schema", "Schema.Todo\x00", "Schema.Todö", "..Schema", "Schema.2Todo"} {
		t.Run("invalid/"+family, func(t *testing.T) {
			if pgMigrationFamily(family) {
				t.Fatal("invalid family accepted")
			}
			history := pgPlanTestHistory()
			// A malformed envelope must not acquire authority through registration
			// or the read-only plan decoder. No database connection is involved.
			history.HistoryJSON = strings.ReplaceAll(history.HistoryJSON, `"NotesSchema"`, `"`+family+`"`)
			history.Family = family
			if _, err := history.ExpansionPlan(1); err == nil {
				t.Fatal("invalid generated family reached a plan")
			}
			migrationRegistrationPanics(t, func() {
				registerCompiledMigrationHistory(history.Database, family, history.Namespace, history.CurrentVersion,
					history.SourceCompilerABI, history.StoredValueCompatibility, history.HistoryJSON)
			})
		})
	}
}

func TestPgMigrationQualifiedFamilyIsNotLegacyAlias(t *testing.T) {
	const qualified, legacy = "Schema.FamilyIdentityTest", "FamilyIdentityTestSchema"
	for _, family := range []string{qualified, legacy} {
		t.Cleanup(func() { compiledMigrationHistories.Delete(family) })
	}
	for _, family := range []string{qualified, legacy} {
		history := pgPlanTestHistory()
		history.HistoryJSON = strings.ReplaceAll(history.HistoryJSON, `"NotesSchema"`, `"`+family+`"`)
		registerCompiledMigrationHistory(history.Database, family, history.Namespace, history.CurrentVersion,
			history.SourceCompilerABI, history.StoredValueCompatibility, history.HistoryJSON)
	}
	for _, family := range []string{qualified, legacy} {
		db := NewDatabase("Main", PostgresConfig{Schema: "notes"}, nil)
		RegisterDatabaseMigrationHistory(db, family)
		history, ok := db.CompiledMigrationHistory()
		if !ok || history.Family != family {
			t.Fatalf("family identity was substituted: %+v", history)
		}
		if _, err := history.ExpansionPlan(1); err != nil {
			t.Fatalf("matching source identity refused: %v", err)
		}
		other := legacy
		if family == legacy {
			other = qualified
		}
		history.Family = other
		if _, err := history.ExpansionPlan(1); err == nil {
			t.Fatal("substituted family accepted the original envelope")
		}
		migrationRegistrationPanics(t, func() { RegisterDatabaseMigrationHistory(db, other) })
		after, _ := db.CompiledMigrationHistory()
		if after.Family != family {
			t.Fatal("refused alias changed the existing binding")
		}
	}
}
