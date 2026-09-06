package teslrt

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func pgMigrationTypeSQL(name string) string {
	switch name {
	case "numeric", "float8", "text", "bool", "int4", "int8", "jsonb":
		return "pg_catalog." + name
	}
	return ""
}

func pgMigrationConstantInput(typ string, value PgMigrationCatalogConstant) (string, error) {
	switch value.Kind {
	case "int":
		if len(value.Value) > 131073 {
			return "", fmt.Errorf("migration numeric constant exceeds PostgreSQL capacity")
		}
		n, ok := new(big.Int).SetString(value.Value, 10)
		if typ == "numeric" && ok && n.String() == value.Value && len(strings.TrimPrefix(value.Value, "-")) <= 131072 {
			return value.Value, nil
		}
	case "float64":
		bits, err := strconv.ParseUint(value.Value, 16, 64)
		n := math.Float64frombits(bits)
		if typ == "float8" && len(value.Value) == 16 && err == nil && fmt.Sprintf("%016x", bits) == value.Value && !math.IsInf(n, 0) && !math.IsNaN(n) {
			return strconv.FormatFloat(n, 'g', -1, 64), nil
		}
	case "bool":
		if typ == "bool" && (value.Value == "true" || value.Value == "false") {
			return value.Value, nil
		}
	case "string":
		if typ == "text" && utf8.ValidString(value.Value) && !strings.ContainsRune(value.Value, 0) {
			return value.Value, nil
		}
	}
	return "", fmt.Errorf("unsupported migration constant %s for %s", value.Kind, typ)
}

func pgValidateMigrationCatalog(tables []PgMigrationCatalogTable) error {
	relations := map[string]bool{}
	for _, table := range tables {
		if !pgMigrationIdentifier(table.Name) || relations[table.Name] {
			return fmt.Errorf("invalid or duplicate expected migration table %q", table.Name)
		}
		relations[table.Name] = true
		primaryName := table.Name + "_pkey"
		if !pgMigrationIdentifier(primaryName) || relations[primaryName] {
			return fmt.Errorf("invalid or colliding migration primary-key index %q", primaryName)
		}
		relations[primaryName] = true
		columns := map[string]bool{}
		primary := 0
		for _, c := range table.Columns {
			if !pgMigrationIdentifier(c.Name) || columns[c.Name] || pgMigrationTypeSQL(c.Type) == "" {
				return fmt.Errorf("invalid expected migration column %s.%s", table.Name, c.Name)
			}
			columns[c.Name] = true
			if c.PrimaryKey {
				primary++
				if c.Nullable {
					return fmt.Errorf("nullable migration primary key %s.%s", table.Name, c.Name)
				}
			}
			if c.Default != nil {
				if _, err := pgMigrationConstantInput(c.Type, *c.Default); err != nil {
					return err
				}
			}
		}
		if primary != 1 {
			return fmt.Errorf("migration table %s requires exactly one primary-key column", table.Name)
		}
		for _, index := range table.Indexes {
			if !pgMigrationIdentifier(index.Name) || relations[index.Name] || len(index.Columns) == 0 || len(index.Columns) > 32 {
				return fmt.Errorf("invalid migration index %s.%s", table.Name, index.Name)
			}
			relations[index.Name] = true
			keys := map[string]bool{}
			for _, name := range index.Columns {
				if !columns[name] || keys[name] {
					return fmt.Errorf("invalid migration index key %s.%s", index.Name, name)
				}
				keys[name] = true
			}
		}
	}
	return nil
}

func pgMigrationColumnSQL(c PgMigrationCatalogColumn) (string, error) {
	if !pgMigrationIdentifier(c.Name) || pgMigrationTypeSQL(c.Type) == "" {
		return "", fmt.Errorf("invalid migration column")
	}
	column := quoteIdentifier(c.Name) + " " + pgMigrationTypeSQL(c.Type)
	if !c.Nullable {
		column += " NOT NULL"
	}
	if c.PrimaryKey {
		column += " PRIMARY KEY"
	}
	if c.Default != nil {
		input, err := pgMigrationConstantInput(c.Type, *c.Default)
		if err != nil {
			return "", err
		}
		// Use the same canonical literal spelling as migration DDL. Only
		// compiler literals and checked built-in types reach this expression.
		// Float strings preserve IEEE negative zero through the float input
		// function instead of first losing its sign in a numeric literal.
		if c.Default.Kind == "int" || c.Default.Kind == "bool" {
			column += " DEFAULT " + input
		} else {
			column += " DEFAULT '" + strings.ReplaceAll(input, "'", "''") + "'::" + pgMigrationTypeSQL(c.Type)
		}
	}
	return column, nil
}

func pgCreateMigrationProbe(ctx context.Context, tx pgx.Tx, name string, table PgMigrationCatalogTable) (*pgCatalogTable, error) {
	var columns []string
	for _, c := range table.Columns {
		column, err := pgMigrationColumnSQL(c)
		if err != nil {
			return nil, err
		}
		columns = append(columns, column)
	}
	qualified := pgx.Identifier{"pg_temp", name}.Sanitize()
	if _, err := tx.Exec(ctx, "CREATE TEMPORARY TABLE "+qualified+" ("+strings.Join(columns, ",")+")"); err != nil {
		return nil, err
	}
	for i, index := range table.Indexes {
		keys := make([]string, len(index.Columns))
		for j, key := range index.Columns {
			keys[j] = quoteIdentifier(key)
		}
		unique := ""
		if index.Unique {
			unique = "UNIQUE "
		}
		if _, err := tx.Exec(ctx, "CREATE "+unique+"INDEX "+quoteIdentifier(name+"_i"+strconv.Itoa(i))+" ON "+qualified+
			" USING btree ("+strings.Join(keys, ",")+")"); err != nil {
			return nil, err
		}
	}
	var namespace string
	if err := tx.QueryRow(ctx, "SELECT nspname FROM pg_catalog.pg_namespace WHERE oid=pg_catalog.pg_my_temp_schema()").Scan(&namespace); err != nil {
		return nil, err
	}
	probe, err := pgReadMigrationTable(ctx, tx, namespace, name)
	if err != nil {
		return nil, err
	}
	if probe == nil {
		return nil, fmt.Errorf("temporary migration comparison table disappeared")
	}
	probe.Name = table.Name
	for i := range probe.Indexes {
		index := &probe.Indexes[i]
		if index.Primary {
			index.Name = table.Name + "_pkey"
			continue
		}
		ordinal, err := strconv.Atoi(strings.TrimPrefix(index.Name, name+"_i"))
		if err != nil || ordinal < 0 || ordinal >= len(table.Indexes) {
			return nil, fmt.Errorf("unexpected temporary comparison index")
		}
		index.Name = table.Indexes[ordinal].Name
	}
	return probe, nil
}

var pgNumericTypmod = regexp.MustCompile(`^numeric\([0-9]+,-?[0-9]+\)$`)
var pgCharacterTypmod = regexp.MustCompile(`^(?:character varying|character)\([0-9]+\)$`)

// Extra-column probes accept a bounded set of built-in storage contexts. Types
// outside this list, including every domain/array/user type, require adoption.
func pgCatalogColumnTypeSQL(c pgCatalogColumn) (string, bool) {
	if c.TypeNamespace != "pg_catalog" || c.TypeKind != "b" || pgCatalogBaseType(c.Type) == "" {
		return "", false
	}
	if c.Typmod == -1 {
		return "pg_catalog." + quoteIdentifier(c.Type), true
	}
	if c.Type == "numeric" && pgNumericTypmod.MatchString(c.TypeSQL) {
		return "pg_catalog." + c.TypeSQL, true
	}
	if (c.Type == "varchar" || c.Type == "bpchar") && pgCharacterTypmod.MatchString(c.TypeSQL) {
		start := strings.IndexByte(c.TypeSQL, '(')
		return "pg_catalog." + quoteIdentifier(c.Type) + c.TypeSQL[start:], true
	}
	return "", false
}

func pgBenignExtraColumn(ctx context.Context, tx pgx.Tx, c pgCatalogColumn) (bool, error) {
	typeSQL, supported := pgCatalogColumnTypeSQL(c)
	if !supported || c.Generated != "" || c.Identity != "" || c.Collation != c.TypeCollation {
		return false, nil
	}
	if c.Default == nil {
		return !c.Required, nil
	}
	literal, ok := parsePgCatalogLiteral(*c.Default, c.Type)
	if !ok {
		return false, nil
	}
	if _, err := tx.Exec(ctx, "SAVEPOINT tesl_constant_probe"); err != nil {
		return false, err
	}
	name := quoteIdentifier("tesl_constant_" + rand.Text())
	required := ""
	if c.Required {
		required = " NOT NULL"
	}
	_, probeErr := tx.Exec(ctx, "CREATE TEMPORARY TABLE pg_temp."+name+" (value "+typeSQL+required+")")
	if probeErr == nil {
		var input any
		if literal.input != nil {
			input = *literal.input
		}
		inputType := literal.inputType
		if inputType == "" {
			inputType = c.Type
		}
		_, probeErr = tx.Exec(ctx, "INSERT INTO pg_temp."+name+" (value) VALUES ($1::pg_catalog."+quoteIdentifier(inputType)+")", input)
	}
	if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT tesl_constant_probe"); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, "RELEASE SAVEPOINT tesl_constant_probe"); err != nil {
		return false, err
	}
	if probeErr == nil {
		return true, nil
	}
	var pgErr *pgconn.PgError
	if errors.As(probeErr, &pgErr) && (strings.HasPrefix(pgErr.Code, "22") || pgErr.Code == "23502") {
		return false, nil
	}
	return false, probeErr
}
