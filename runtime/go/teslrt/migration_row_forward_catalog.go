package teslrt

import (
	"context"
	"crypto/sha256"
	"fmt"
	"reflect"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgRowInvalidation struct {
	entity   *pgRowPhysicalEntity
	window   *pgRowPhysicalWindow
	name     string
	function pgMigrationControlFunction
}

func pgRowInvalidationFor(namespace string, entity *pgRowPhysicalEntity, window *pgRowPhysicalWindow) pgRowInvalidation {
	name := fmt.Sprintf("tesl_row_invalidate_%x", sha256.Sum256([]byte(fmt.Sprintf("%s\x00%s\x00%d", namespace, entity.identity, window.targetGeneration))))[:52]
	comparisons := []string{}
	for _, name := range window.invalidation {
		comparisons = append(comparisons, "NEW."+quoteIdentifier(name)+" is distinct from OLD."+quoteIdentifier(name))
	}
	condition := "TG_OP='INSERT'"
	if len(comparisons) > 0 {
		condition += " or " + strings.Join(comparisons, " or ")
	}
	setting := pgRowWriterSetting(namespace, entity.identity)
	body := fmt.Sprintf("\nbegin\n if coalesce(nullif(pg_catalog.current_setting('%s',true),''),'0')::integer < %d and (%s) then\n NEW.\"_tesl_v\" := least(NEW.\"_tesl_v\",%d);\n end if;\n return NEW;\nend", setting, window.targetGeneration, condition, window.previousGeneration)
	return pgRowInvalidation{entity: entity, window: window, name: name, function: pgMigrationControlFunction{name: name, arguments: "", result: "trigger", volatility: "volatile", body: body}}
}

func pgExecuteRowInvalidation(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, spec pgRowInvalidation) error {
	if _, err := tx.Exec(ctx, pgControlFunctionSQL(namespace, roles.Worker, spec.function)); err != nil {
		return err
	}
	function := pgx.Identifier{namespace, spec.name}.Sanitize() + "()"
	if _, err := tx.Exec(ctx, "revoke all on function "+function+" from public; create trigger "+quoteIdentifier(spec.name)+" before insert or update on "+pgx.Identifier{namespace, spec.entity.table}.Sanitize()+" for each row execute function "+function); err != nil {
		return err
	}
	return nil
}

// Compare the complete trigger/function observation, including the server's
// canonical rendering of the closed body and every attribute.
func pgVerifyRowInvalidation(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, actual *pgCatalogTable, spec pgRowInvalidation) error {
	if len(actual.Triggers) != 1 || actual.Triggers[0] != spec.name || len(actual.TriggerDefinitions) != 1 {
		return fmt.Errorf("row invalidation trigger inventory differs")
	}
	var definition, qualified string
	if err := tx.QueryRow(ctx, "select pg_catalog.format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I()', $1::text,$2::text,$3::text,$2::text,$1::text), pg_catalog.format('%I.%I',$2::text,$1::text)", spec.name, namespace, spec.entity.table).Scan(&definition, &qualified); err != nil {
		return err
	}
	expected := pgCatalogTrigger{
		Relation: pgCatalogRelationReference{Namespace: namespace, Name: spec.entity.table, Kind: "r"}, Name: spec.name, Definition: definition, Enabled: "O", Type: 23, Columns: []int{},
		Function: pgCatalogTriggerFunction{
			Namespace: namespace, Name: spec.name, Owner: roles.Worker, Language: "plpgsql", Kind: "f", Result: "trigger", Source: spec.function.body, Definition: "CREATE OR REPLACE FUNCTION " + qualified + "()\n RETURNS trigger\n LANGUAGE plpgsql\n SECURITY DEFINER\n SET search_path TO ''\nAS $function$" + spec.function.body + "$function$\n",
			Volatility: "v", Parallel: "u", SecurityDefiner: true, Cost: 100,
			ArgumentTypes: []pgCatalogTypeReference{}, AllArgumentTypes: []pgCatalogTypeReference{}, TransformTypes: []pgCatalogTypeReference{},
			ResultType: pgCatalogTypeReference{Namespace: "pg_catalog", Name: "trigger", Kind: "p"}, Configuration: []string{`search_path=""`},
			ACL: []pgCatalogFunctionACL{{Grantor: roles.Worker, Grantee: roles.Worker, Privilege: "EXECUTE"}}, Roles: []pgCatalogFunctionRole{},
		},
	}
	observed := actual.TriggerDefinitions[0]
	if !reflect.DeepEqual(observed, expected) {
		return fmt.Errorf("row invalidation trigger/function definition, identity, configuration or ACL differs")
	}
	return nil
}

func pgVerifyRowForwardCatalog(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, roles PgMigrationControlRoles, baselineCount int, forward *pgRowForwardManifest, completed int) error {
	if forward == nil {
		return pgVerifyRowPhysicalCatalog(ctx, tx, b, roles, baselineCount)
	}
	if baselineCount != len(b.entities) || completed < 0 || completed > len(forward.operations) {
		return fmt.Errorf("invalid committed physical operation prefix")
	}
	catalog := make([]PgMigrationCatalogTable, len(b.entities))
	for i, entity := range b.entities {
		catalog[i] = entity.catalog
		catalog[i].Columns = slices.Clone(entity.catalog.Columns)
	}
	triggers := map[string]pgRowInvalidation{}
	checks := map[string]map[string]pgRowNotNullProof{}
	history := []*pgRowForwardManifest{}
	for m := forward; m != nil; m = m.previous {
		history = append(history, m)
	}
	slices.Reverse(history)
	for _, manifest := range history {
		prefix := manifest.completed
		if manifest == forward {
			prefix = completed
		}
		if prefix < 0 || prefix > len(manifest.operations) {
			return fmt.Errorf("invalid expansion catalog prefix")
		}
		for _, operation := range manifest.operations[:prefix] {
			if operation.column != nil {
				found := false
				for i := range catalog {
					if catalog[i].Name == operation.entity.table {
						catalog[i].Columns = append(catalog[i].Columns, operation.column.catalog)
						found = true
						break
					}
				}
				if !found {
					return fmt.Errorf("physical operation targets missing baseline entity")
				}
			} else if operation.window != nil {
				triggers[operation.entity.table] = pgRowInvalidationFor(b.history.Namespace, operation.entity, operation.window)
			} else {
				return fmt.Errorf("unknown physical operation")
			}
		}
		c := manifest.contraction
		if c == nil {
			continue
		}
		if c.contract == nil || c.completed < 0 || c.completed > len(c.contract.operations) {
			return fmt.Errorf("invalid Contract catalog prefix")
		}
		for _, op := range c.contract.operations[:c.completed] {
			entity := manifest.plan.entity(op.children[1].value)
			if entity == nil {
				return fmt.Errorf("row Contract references missing entity")
			}
			table := (*PgMigrationCatalogTable)(nil)
			for i := range catalog {
				if catalog[i].Name == entity.table {
					table = &catalog[i]
					break
				}
			}
			if table == nil {
				return fmt.Errorf("row Contract references missing physical table")
			}
			switch op.children[0].value {
			case "add-not-null-check", "validate-not-null-check", "drop-not-null-check":
				inventory := checks[entity.table]
				if inventory == nil {
					inventory = map[string]pgRowNotNullProof{}
					checks[entity.table] = inventory
				}
				tag := op.children[0].value
				if tag == "add-not-null-check" {
					proof := pgRowNotNullProofNode(op.children[3])
					if _, exists := inventory[proof.name]; exists {
						return fmt.Errorf("row nullability proof already exists")
					}
					inventory[proof.name] = proof
				} else {
					before := pgRowNotNullProofNode(op.children[2])
					if actual, exists := inventory[before.name]; !exists || actual != before {
						return fmt.Errorf("row nullability proof predecessor differs")
					}
					if tag == "drop-not-null-check" {
						delete(inventory, before.name)
					} else {
						inventory[before.name] = pgRowNotNullProofNode(op.children[3])
					}
				}
			case "drop-invalidation":
				spec, ok := triggers[entity.table]
				if !ok || spec.window.targetGeneration != entity.generation {
					return fmt.Errorf("row Contract invalidation differs from installed window")
				}
				delete(triggers, entity.table)
			case "drop-index":
				name := op.children[2].children[0].value
				found := false
				table.Indexes = slices.DeleteFunc(slices.Clone(table.Indexes), func(index PgMigrationCatalogIndex) bool {
					if index.Name == name {
						found = true
						return true
					}
					return false
				})
				if !found {
					return fmt.Errorf("row Contract index is absent")
				}
			case "drop-column":
				name := op.children[2].children[0].value
				found := false
				table.Columns = slices.DeleteFunc(slices.Clone(table.Columns), func(column PgMigrationCatalogColumn) bool {
					if column.Name == name {
						found = true
						return true
					}
					return false
				})
				if !found {
					return fmt.Errorf("row Contract column is absent")
				}
			case "set-not-null", "relax-retired-nullability":
				name := op.children[2].children[0].value
				found := false
				for i := range table.Columns {
					if table.Columns[i].Name == name {
						relax := op.children[0].value == "relax-retired-nullability"
						if table.Columns[i].Nullable == relax {
							return fmt.Errorf("row Contract nullability predecessor differs")
						}
						table.Columns[i].Nullable = relax
						found = true
						break
					}
				}
				if !found {
					return fmt.Errorf("row Contract tightened column is absent")
				}
			case "set-insert-generation":
				found := false
				for i := range table.Columns {
					if table.Columns[i].Name == "_tesl_v" {
						old := table.Columns[i].Default
						if old == nil || old.Kind != "int" || old.Value != op.children[2].value {
							return fmt.Errorf("row Contract marker default predecessor differs")
						}
						table.Columns[i].Default = &PgMigrationCatalogConstant{Kind: "int", Value: op.children[3].value}
						found = true
						break
					}
				}
				if !found {
					return fmt.Errorf("row Contract marker is absent")
				}
			default:
				return fmt.Errorf("unknown checked Contract operation")
			}
		}
	}

	return pgVerifyRowCatalogSet(ctx, tx, b, roles, catalog, triggers, checks)
}
