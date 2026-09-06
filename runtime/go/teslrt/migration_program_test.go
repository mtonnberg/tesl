package teslrt

import (
	"crypto/sha256"
	"fmt"
	"sync"
	"testing"
)

func compiledHistoryFixture(t *testing.T, suffix string) (string, *Database) {
	t.Helper()
	family := fmt.Sprintf("Fixture%xSchema", sha256.Sum256([]byte(suffix)))
	t.Cleanup(func() { compiledMigrationHistories.Delete(family) })
	registerCompiledMigrationHistory("Config.Main", family, "app_space", 8, "actual-compiler-abi", pgTestStoredValueCompatibility, `{"fixture":true}`)
	return family, NewDatabase("Main", PostgresConfig{Schema: "app_space"}, nil)
}

func migrationRegistrationPanics(t *testing.T, f func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Error("invalid compiled history registration succeeded")
		}
	}()
	f()
}

func TestCompiledMigrationHistoryIsSourceInformation(t *testing.T) {
	var missing *Database
	if _, ok := missing.CompiledMigrationHistory(); ok {
		t.Fatal("nil database has history")
	}
	family, database := compiledHistoryFixture(t, "Source")
	if _, ok := database.CompiledMigrationHistory(); ok {
		t.Fatal("unbound database has history")
	}
	if RegisterDatabaseMigrationHistory(database, family) != database {
		t.Fatal("registration replaced the connection")
	}
	info, ok := database.CompiledMigrationHistory()
	if !ok || info.Database != "Config.Main" || info.Family != family || info.Namespace != "app_space" ||
		info.CurrentVersion != 8 || info.SourceCompilerABI != "actual-compiler-abi" || info.StoredValueCompatibility != pgTestStoredValueCompatibility || info.HistoryJSON != `{"fixture":true}` {
		t.Fatalf("lost compiler information: %+v", info)
	}
	info.CurrentVersion = 100
	info.HistoryJSON = "changed by consumer"
	again, _ := database.CompiledMigrationHistory()
	if again.CurrentVersion != 8 || again.HistoryJSON != `{"fixture":true}` || database.open != nil {
		t.Fatal("inspection changed compiled history or connected to the database")
	}
}

func TestCompiledMigrationHistoryRefusesMissingOrConflictingBindings(t *testing.T) {
	family, database := compiledHistoryFixture(t, "Bindings")
	migrationRegistrationPanics(t, func() { RegisterDatabaseMigrationHistory(nil, family) })
	migrationRegistrationPanics(t, func() { RegisterDatabaseMigrationHistory(database, "MissingSchema") })
	migrationRegistrationPanics(t, func() {
		RegisterDatabaseMigrationHistory(NewDatabase("Other", PostgresConfig{Schema: "other"}, nil), family)
	})
	RegisterDatabaseMigrationHistory(database, family)
	migrationRegistrationPanics(t, func() {
		registerCompiledMigrationHistory("Other.Main", family, "app_space", 8, "actual-compiler-abi", pgTestStoredValueCompatibility, `{"fixture":true}`)
	})
	other, _ := compiledHistoryFixture(t, "OtherBindings")
	migrationRegistrationPanics(t, func() { RegisterDatabaseMigrationHistory(database, other) })
	info, _ := database.CompiledMigrationHistory()
	if info.Database != "Config.Main" || info.Family != family {
		t.Fatal("failed registration changed the original binding")
	}
}

func TestCompiledMigrationHistoryRegistrationCanRace(t *testing.T) {
	family, database := compiledHistoryFixture(t, "Concurrent")
	var group sync.WaitGroup
	for range 40 {
		group.Go(func() {
			registerCompiledMigrationHistory("Config.Main", family, "app_space", 8, "actual-compiler-abi", pgTestStoredValueCompatibility, `{"fixture":true}`)
			RegisterDatabaseMigrationHistory(database, family)
			if info, ok := database.CompiledMigrationHistory(); !ok || info.CurrentVersion != 8 {
				t.Error("concurrent inspection observed an incomplete binding")
			}
		})
	}
	group.Wait()
}

func TestCompiledMigrationHistoryRejectsIncompleteGeneratedMetadata(t *testing.T) {
	for _, version := range []int{-1, 0, 2147483647} {
		t.Run(fmt.Sprint(version), func(t *testing.T) {
			migrationRegistrationPanics(t, func() {
				registerCompiledMigrationHistory("App.Main", "InvalidSchema", "space", version, "abi", pgTestStoredValueCompatibility, "json")
			})
		})
	}
	for _, fields := range [][5]string{{"", "A", "space", "abi", "json"}, {"App.Main", "Invalid", "space", "abi", "json"},
		{"App.Main", "InvalidSchema", "", "abi", "json"}, {"App.Main", "InvalidSchema", "space", "", "json"},
		{"App.Main", "InvalidSchema", "space", "abi", ""}} {
		migrationRegistrationPanics(t, func() {
			registerCompiledMigrationHistory(fields[0], fields[1], fields[2], 1, fields[3], pgTestStoredValueCompatibility, fields[4])
		})
	}
}
