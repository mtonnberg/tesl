package teslrt

import (
	"slices"
	"testing"
)

func TestRowProjectionWireVersionAndCompleteness(t *testing.T) {
	for _, scenario := range []string{"valid", "v1-extra", "v2-missing", "unknown-version", "duplicate", "unknown-field", "partial", "null", "wrong-direction-count"} {
		t.Run(scenario, func(t *testing.T) {
			history, _, companion := rowTestFixture(t)
			companion["version"] = 2
			transform := rowTestTransform(companion)
			transform["sourceProjection"] = []string{"title", "id"}
			transform["targetProjection"] = []string{"id", "title"}
			switch scenario {
			case "valid":
			case "v1-extra":
				companion["version"] = 1
			case "v2-missing":
				delete(transform, "sourceProjection")
			case "unknown-version":
				companion["version"] = 4
			case "duplicate":
				transform["sourceProjection"] = []string{"id", "id"}
			case "unknown-field":
				transform["sourceProjection"] = []string{"title", "unknown"}
			case "partial":
				transform["sourceProjection"] = []string{"id"}
			case "null":
				transform["targetProjection"] = nil
			case "wrong-direction-count":
				transform["targetProjection"] = []string{"id", "title", "extra"}
			default:
				t.Fatal("unknown test scenario")
			}
			inventories, err := pgReadRowCompanion(history, rowTestJSON(t, companion))
			if scenario != "valid" {
				if err == nil {
					t.Fatal("malformed projection accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			descriptor := inventories[0].Transforms[0]
			if !slices.Equal(descriptor.SourceProjection, []string{"title", "id"}) || !slices.Equal(descriptor.TargetProjection, []string{"id", "title"}) {
				t.Fatal("decoder order was sorted or swapped")
			}
			rowTestRegister(t, history, companion)
			inventory, err := history.RowSourceInventory()
			if err != nil {
				t.Fatal(err)
			}
			inventory.Transforms[0].SourceProjection[0] = "changed"
			again, err := history.RowSourceInventory()
			if err != nil || again.Transforms[0].SourceProjection[0] != "title" {
				t.Fatal("projection readback mutated private descriptor", err)
			}
		})
	}
}
func TestZeroRowStorageRefuses(t *testing.T) {
	var storage *PgRowStorage[struct{}, struct{}]
	if _, err := storage.SourceProjection().CheckOrder(nil); err == nil {
		t.Fatal("zero projection accepted")
	}
	if _, err := storage.Decode(PgRowProjectionPlan{}, nil); err == nil {
		t.Fatal("zero decoder ran")
	}
	if _, err := storage.DecodeTarget(PgRowProjectionPlan{}, nil); err == nil {
		t.Fatal("zero target decoder ran")
	}
	if _, err := storage.Encode(struct{}{}); err == nil {
		t.Fatal("zero encoder ran")
	}
	if _, err := storage.EncodeSource(struct{}{}); err == nil {
		t.Fatal("zero source encoder ran")
	}
	if _, err := (PgEncodedRow{}).Parameters(PgRowProjectionPlan{}); err == nil {
		t.Fatal("zero encoded values accepted")
	}
	migrationRegistrationPanics(t, func() { RegisterCompiledRowStorage[struct{}, struct{}](nil, nil, nil, nil, nil) })
}
