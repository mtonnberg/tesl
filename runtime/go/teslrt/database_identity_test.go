package teslrt

import "testing"

func TestDatabaseIdentityResolvesExactApplicationOwner(t *testing.T) {
	t.Parallel()
	left, right := &Database{Name: "Db"}, &Database{Name: "Db"}
	for identity, database := range map[string]*Database{t.Name() + ".Left.Db": left, t.Name() + ".Right.Db": right} {
		t.Cleanup(func() { databaseIdentities.Delete(identity) })
		if RegisterDatabaseIdentity(identity, database) != database || ResolveDatabaseIdentity(identity) != database {
			t.Fatal("database identity lost its application owner")
		}
		if RegisterDatabaseIdentity(identity, database) != database {
			t.Fatal("same registration is not idempotent")
		}
	}
}

func TestDatabaseIdentityRefusesMissingOrConflictingBindings(t *testing.T) {
	t.Parallel()
	identity := t.Name() + ".App.Db"
	first := RegisterDatabaseIdentity(identity, &Database{Name: "Db"})
	t.Cleanup(func() { databaseIdentities.Delete(identity) })
	for name, action := range map[string]func(){
		"missing":  func() { ResolveDatabaseIdentity(identity + ".missing") },
		"empty":    func() { RegisterDatabaseIdentity("", first) },
		"nil":      func() { RegisterDatabaseIdentity(identity, nil) },
		"conflict": func() { RegisterDatabaseIdentity(identity, &Database{Name: "Other"}) },
	} {
		t.Run(name, func(t *testing.T) {
			defer func() {
				if recover() == nil {
					t.Fatal("invalid binding accepted")
				}
				if ResolveDatabaseIdentity(identity) != first {
					t.Fatal("refused binding replaced the database")
				}
			}()
			action()
		})
	}
}
