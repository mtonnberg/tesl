package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

// This private candidate describes only the invalidation mechanism. It is not
// authority to install a trigger, trust a row marker, or admit a predecessor.
// Publication also requires an immutable registered generation descriptor,
// exact catalog verification, and generated writes that materialize the entire
// target row before setting the transaction-local writer generation.
type pgRowGenerationInvalidation struct {
	namespace, table string
	previous, target int
	sources          []string
}

func pgNewRowGenerationInvalidation(namespace, table string, previous, target int, sources []string) (pgRowGenerationInvalidation, error) {
	var empty pgRowGenerationInvalidation
	if !pgMigrationIdentifier(namespace) || !pgMigrationIdentifier(table) ||
		previous < 1 || previous >= 32767 || target < 2 || target > 32767 || target != previous+1 || len(sources) == 0 || len(sources) > 1599 {
		return empty, fmt.Errorf("row invalidation requires a table, consecutive smallint generations and source columns")
	}
	columns := slices.Clone(sources)
	slices.Sort(columns)
	for i, source := range columns {
		if !pgMigrationIdentifier(source) || source == "_tesl_v" || i > 0 && source == columns[i-1] {
			return empty, fmt.Errorf("row invalidation requires distinct physical source columns excluding the generation marker")
		}
	}
	return pgRowGenerationInvalidation{namespace, table, previous, target, columns}, nil
}

func (rule pgRowGenerationInvalidation) digest() string {
	// All members have JSON encodings; the fixed tuple/domain makes field order,
	// namespace boundaries and generation identity explicit. Columns are sorted.
	encoded, _ := json.Marshal([]any{"tesl-row-invalidation-v1", rule.namespace, rule.table, rule.previous, rule.target, rule.sources})
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:])
}

func (rule pgRowGenerationInvalidation) functionName() string {
	// PostgreSQL identifiers are limited to 63 bytes. The complete descriptor
	// hash must still be checked at registration; an object name is not identity.
	return "tesl_iv_" + rule.digest()[:48]
}

func (rule pgRowGenerationInvalidation) writerSetting() string {
	// All transitions on this table share a setting. Namespace separation also
	// prevents one entity's materialization from suppressing another's trigger.
	encoded, _ := json.Marshal([]string{"tesl-row-writer-v1", rule.namespace, rule.table})
	digest := sha256.Sum256(encoded)
	return "tesl.writer_" + hex.EncodeToString(digest[:])
}

func (rule pgRowGenerationInvalidation) body() string {
	predicates := make([]string, len(rule.sources))
	for i, source := range rule.sources {
		column := pgx.Identifier{source}.Sanitize()
		predicates[i] = "new." + column + " is distinct from old." + column
	}
	return "begin\n" +
		" if coalesce(nullif(pg_catalog.current_setting('" + rule.writerSetting() + "',true),'')::pg_catalog.int4,0) < " + strconv.Itoa(rule.target) +
		" and (" + strings.Join(predicates, " or ") + ") then\n" +
		"  new.\"_tesl_v\" := least(new.\"_tesl_v\"," + strconv.Itoa(rule.previous) + ");\n" +
		" end if;\n return new;\nend;"
}

func (rule pgRowGenerationInvalidation) statements() ([]string, error) {
	// Revalidate at the SQL boundary, including zero values. No caller can obtain
	// an executable statement from an incomplete descriptor.
	checked, err := pgNewRowGenerationInvalidation(rule.namespace, rule.table, rule.previous, rule.target, rule.sources)
	if err != nil {
		return nil, err
	}
	function := pgx.Identifier{checked.namespace, checked.functionName()}.Sanitize()
	table := pgx.Identifier{checked.namespace, checked.table}.Sanitize()
	// An escape literal handles quotes, backslashes and dollar delimiters inside
	// quoted column names independently of standard_conforming_strings.
	body := "E'" + strings.NewReplacer("\\", "\\\\", "'", "''").Replace(checked.body()) + "'"
	return []string{
		"create function " + function + "() returns pg_catalog.trigger language plpgsql volatile called on null input security invoker parallel unsafe set search_path='' as " + body,
		"revoke all on function " + function + "() from public",
		"create trigger " + pgx.Identifier{checked.functionName()}.Sanitize() + " before update on " + table + " for each row execute function " + function + "()",
	}, nil
}

// Check one observed trigger against a previously checked descriptor. The
// descriptor's persisted provenance, table storage, admission and role profile
// remain separate caller obligations. In particular, this does not remove the
// production catalog's refusal of all unrecorded triggers.
func (rule pgRowGenerationInvalidation) checkTrigger(actual pgCatalogTrigger, owner string) error {
	checked, err := pgNewRowGenerationInvalidation(rule.namespace, rule.table, rule.previous, rule.target, rule.sources)
	if err != nil {
		return err
	}
	if !pgMigrationIdentifier(owner) {
		return fmt.Errorf("row invalidation requires an exact recorded function owner")
	}
	if actual.Relation != (pgCatalogRelationReference{Namespace: checked.namespace, Name: checked.table, Kind: "r"}) ||
		actual.Name != checked.functionName() || actual.Type != 19 || actual.Enabled != "O" ||
		actual.Internal || actual.Deferrable || actual.InitiallyDeferred || actual.HasCondition ||
		len(actual.Columns) != 0 || actual.ArgumentCount != 0 || actual.ArgumentsHex != "" ||
		actual.OldTransitionTable != nil || actual.NewTransitionTable != nil || actual.Constraint != nil ||
		actual.ConstraintRelation != nil || actual.ConstraintIndex != nil || actual.Parent != nil {
		return fmt.Errorf("row invalidation trigger differs from its exact BEFORE UPDATE ROW contract")
	}
	f := actual.Function
	if f.Namespace != checked.namespace || f.Name != checked.functionName() || f.Owner != owner ||
		f.Language != "plpgsql" || f.Kind != "f" || f.ResultType != (pgCatalogTypeReference{Namespace: "pg_catalog", Name: "trigger", Kind: "p"}) ||
		f.Source != checked.body() || f.Binary != nil || f.SQLBody != nil ||
		f.Volatility != "v" || f.Parallel != "u" || f.SecurityDefiner || f.Strict || f.Leakproof || f.SetReturning ||
		f.Cost != 100 || f.Rows != 0 || f.ArgumentCount != 0 || f.DefaultCount != 0 ||
		f.Arguments != "" || f.IdentityArguments != "" || f.ArgumentDefaults != nil ||
		len(f.ArgumentTypes) != 0 || len(f.AllArgumentTypes) != 0 || len(f.ArgumentModes) != 0 || len(f.ArgumentNames) != 0 ||
		f.VariadicType != nil || len(f.TransformTypes) != 0 || f.Support != nil ||
		!slices.Equal(f.Configuration, []string{`search_path=""`}) {
		return fmt.Errorf("row invalidation function differs from its exact generated definition")
	}
	if len(f.ACL) != 1 || f.ACL[0] != (pgCatalogFunctionACL{Grantor: owner, Grantee: owner, Privilege: "EXECUTE"}) {
		return fmt.Errorf("row invalidation function privileges differ from its owner-only contract")
	}
	// Definition/Result are deparsed presentations of the attributes checked
	// above, not SQL to parse or execute. Effective role memberships are checked
	// by the deployment role verifier; exact ACL comparison is not its replacement.
	return nil
}
