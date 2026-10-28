package teslrt

import "testing"

func TestRowContractCommandTargetAndSelection(t *testing.T) {
	for _, args := range [][]string{{"--schema", "contract"}, {"--schema", "contract", "2"}, {"--schema", "contract", "V1"}, {"--schema", "contract", "V02"}, {"--schema", "contract", "V+2"}, {"--schema", "contract", "V2147483647"}, {"--schema", "contract", "V2", "V3"}, {"--schema", "contract", "V2", "--worker", "a"}, {"--schema", "contract", "V2", "--json", "--json"}} {
		if _, handled, err := pgParseSchemaCommand(args); !handled || err == nil {
			t.Fatalf("invalid Contract target accepted: %v", args)
		}
	}
	c, handled, err := pgParseSchemaCommand([]string{"--schema", "contract", "V2", "--database", "App.Main", "--json"})
	if err != nil || !handled || c.verb != "contract" || c.targetVersion != 2 || c.database != "App.Main" || !c.json {
		t.Fatal(c, handled, err)
	}
	// A target is never inferred from a database's current version or an omitted
	// argument: the maintenance command names the exact checked contraction.
	c, _, err = pgParseSchemaCommand([]string{"--schema", "status"})
	if err != nil || c.targetVersion != 0 {
		t.Fatal(c, err)
	}
}
