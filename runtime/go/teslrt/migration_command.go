package teslrt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgSchemaCommand struct {
	verb, database, worker string
	json                   bool
}

func pgParseSchemaCommand(args []string) (pgSchemaCommand, bool, error) {
	var command pgSchemaCommand
	position := -1
	for i, arg := range args {
		if arg == "--schema" || strings.HasPrefix(arg, "--schema=") {
			position = i
			break
		}
	}
	if position < 0 {
		return command, false, nil
	}
	if position != 0 || args[0] != "--schema" || len(args) < 2 || (args[1] != "status" && args[1] != "install") {
		return command, true, fmt.Errorf("usage: app --schema status [--database Module.Database] [--json]\n       app --schema install --worker ROLE [--database Module.Database] [--json]")
	}
	command.verb = args[1]
	for i := 2; i < len(args); i++ {
		switch args[i] {
		case "--database":
			if command.database != "" || i+1 == len(args) || strings.HasPrefix(args[i+1], "--") || args[i+1] == "" {
				return command, true, fmt.Errorf("--database requires one compiled database identity")
			}
			i++
			command.database = args[i]
		case "--worker":
			if command.verb != "install" || command.worker != "" || i+1 == len(args) || strings.HasPrefix(args[i+1], "--") || !pgMigrationIdentifier(args[i+1]) {
				return command, true, fmt.Errorf("install requires one --worker ROLE naming the application's operator-provisioned login")
			}
			i++
			command.worker = args[i]
		case "--json":
			if command.json {
				return command, true, fmt.Errorf("--json may appear only once")
			}
			command.json = true
		default:
			return command, true, fmt.Errorf("unexpected schema %s argument %q", command.verb, args[i])
		}
	}
	if command.verb == "install" && command.worker == "" {
		return command, true, fmt.Errorf("install requires --worker ROLE; the installer connection must not become the application login")
	}
	return command, true, nil
}

func pgSelectSchemaDatabase(selector string) (*Database, PgCompiledMigrationHistory, error) {
	type candidate struct {
		database *Database
		history  PgCompiledMigrationHistory
	}
	var candidates []candidate
	databaseIdentities.Range(func(_, value any) bool {
		database, ok := value.(*Database)
		if !ok {
			return true
		}
		if history, versioned := database.CompiledMigrationHistory(); versioned {
			candidates = append(candidates, candidate{database, history})
		}
		return true
	})
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].history.Database < candidates[j].history.Database })
	var names []string
	for _, candidate := range candidates {
		names = append(names, candidate.history.Database)
		if candidate.history.Database == selector || selector == "" && len(candidates) == 1 {
			return candidate.database, candidate.history, nil
		}
	}
	if len(names) == 0 {
		return nil, PgCompiledMigrationHistory{}, fmt.Errorf("this binary has no versioned PostgreSQL database")
	}
	return nil, PgCompiledMigrationHistory{}, fmt.Errorf("select a compiled database with --database: %s", strings.Join(names, ", "))
}

func pgRunSchemaCommand(command pgSchemaCommand, out io.Writer) (resultErr error) {
	database, history, err := pgSelectSchemaDatabase(command.database)
	if err != nil {
		return err
	}
	if database.Config.Schema != history.Namespace {
		return fmt.Errorf("migration namespace disagrees with connection")
	}
	if _, err := history.ExpansionPlan(1); err != nil {
		return err
	}
	config, err := pgx.ParseConfig(postgresDSN(database.Config))
	if err != nil {
		return err
	}
	roles := pgMigrationRoles(database.Config, config.User)
	if command.verb == "install" {
		roles.Worker = command.worker
	}
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	conn, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		return err
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), pgLeaseTimeout())
		defer stop()
		resultErr = errors.Join(resultErr, conn.Close(cleanup))
	}()
	if command.verb == "install" {
		state, err := InstallPgCompiledMigrationControl(ctx, conn, history, roles)
		if err != nil {
			return err
		}
		return pgWriteSchemaInstallation(out, command.json, history, state)
	}
	status, err := InspectPgMigrationStatus(ctx, conn, history, roles)
	if err != nil {
		return err
	}
	if command.json {
		if err := json.NewEncoder(out).Encode(status); err != nil {
			return err
		}
	} else {
		var text strings.Builder
		fmt.Fprintf(&text, "%s: binary V%d; namespace %q\n", status.Database, status.BinaryVersion, status.Namespace)
		if !status.Present {
			text.WriteString("Migration control is not installed.\n")
		} else {
			if status.CurrentVersion == 0 {
				fmt.Fprintf(&text, "Initial installation of V%d is incomplete.\n", status.InstallingVersion)
			} else {
				fmt.Fprintf(&text, "Database V%d; oldest admitted V%d; installed from V%d.\n", status.CurrentVersion, status.MinVersion, status.InitialVersion)
			}
			for _, expansion := range status.Expansions {
				steps := strings.Join(expansion.Steps, ", ")
				if steps == "" {
					steps = "expanding"
				}
				fmt.Fprintf(&text, "V%d: %d/%d objects; %s\n", expansion.Version, expansion.Completed, expansion.Total, steps)
			}
			for _, instance := range status.Instances {
				fmt.Fprintf(&text, "%q: V%d; last heartbeat %s\n", instance.Instance, instance.Version, instance.LastSeen.Format("2006-01-02T15:04:05Z"))
			}
		}
		if _, err := io.WriteString(out, text.String()); err != nil {
			return err
		}
	}
	if status.HistoryError != "" {
		return fmt.Errorf("compiled migration history differs: %s", status.HistoryError)
	}
	return nil
}

type pgSchemaInstallation struct {
	Version           int    `json:"version"`
	Kind              string `json:"kind"`
	Database          string `json:"database"`
	Namespace         string `json:"namespace"`
	DatabaseUUID      string `json:"databaseUuid"`
	BinaryVersion     int    `json:"binaryVersion"`
	InitialVersion    int    `json:"initialVersion"`
	CurrentVersion    int    `json:"currentVersion"`
	InstallingVersion int    `json:"installingVersion"`
}

func pgWriteSchemaInstallation(out io.Writer, asJSON bool, history PgCompiledMigrationHistory, state PgMigrationControlState) error {
	if asJSON {
		return json.NewEncoder(out).Encode(pgSchemaInstallation{Version: 1, Kind: "schema-install", Database: history.Database,
			Namespace: history.Namespace, DatabaseUUID: state.DatabaseUUID, BinaryVersion: history.CurrentVersion,
			InitialVersion: state.InitialVersion, CurrentVersion: state.Current, InstallingVersion: state.InstallingVersion})
	}
	_, err := fmt.Fprintf(out, "%s: migration control verified; namespace %q; installation origin V%d.\nRevoke the installer's temporary control-owner membership before starting the application.\nApplication boot performs pending storage installation and additive expansion.\n", history.Database, history.Namespace, state.InitialVersion)
	return err
}

// RunSchemaCommand is called by the generated main before application startup.
// Without --schema it is inert. A handled command must terminate that main even
// when it fails, so a misspelled operator command cannot accidentally serve.
func RunSchemaCommand(args []string, stdout, stderr io.Writer) (handled bool, exitCode int) {
	command, handled, err := pgParseSchemaCommand(args)
	if !handled {
		return false, 0
	}
	if stdout == nil || stderr == nil {
		return true, 2
	}
	if err == nil {
		err = pgRunSchemaCommand(command, stdout)
	}
	if err != nil {
		_, _ = fmt.Fprintln(stderr, "schema:", err)
		return true, 2
	}
	return true, 0
}
