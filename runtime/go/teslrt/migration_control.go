package teslrt

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// PgMigrationControlRoles names operator-provisioned roles. Owner must be a
// no-login control owner; Worker must have no administrative or owner membership.
type PgMigrationControlRoles struct{ Owner, Worker, Request string }

type PgMigrationControlVersion struct {
	Version, Sequence                                        int
	Step, SnapshotHash, ArtifactHash, SourceABI, FenceDomain string
	StoredValueCompatibility                                 string
	Protocol                                                 int
	EpochPreserving                                          *bool
}

// PgMigrationControlState is returned only after catalog, ownership, grants and
// function checks. Reading it is not authority to admit a request later: each
// transaction still needs the permanent raising admission function.
type PgMigrationControlState struct {
	Present                                                    bool
	DatabaseUUID                                               string
	Format, InitialVersion, Current, MinVersion, CompatFloor   int
	InstallingVersion, FenceNamespace, RetirementProtocolFloor int
	MaxObservedProtocol                                        int
	FenceDomain                                                string
	Versions                                                   []PgMigrationControlVersion
}

func pgMigrationSessionLock(ctx context.Context, conn *pgx.Conn, namespace, key int, exclusive bool, f func() error) (resultErr error) {
	if conn == nil || conn.IsClosed() || conn.PgConn().TxStatus() != 'I' {
		return fmt.Errorf("migration coordination requires an idle, exclusively borrowed connection")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// Acquire before opening the repeatable-read snapshot. Taking an xact lock
	// as the first SELECT would still capture a stale snapshot before waiting
	// for another installer's commit, then miss its newly created namespace.
	suffix := "_shared"
	if exclusive {
		suffix = ""
	}
	if _, err := conn.Exec(ctx, "select pg_catalog.pg_advisory_lock"+suffix+"($1::integer,$2::integer)", namespace, key); err != nil {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = conn.Close(cleanup) // Acquisition may have succeeded before cancellation.
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var released bool
		if err := conn.QueryRow(cleanup, "select pg_catalog.pg_advisory_unlock"+suffix+"($1::integer,$2::integer)", namespace, key).Scan(&released); err != nil || !released {
			if err == nil {
				err = fmt.Errorf("session no longer owns the lock")
			}
			resultErr = errors.Join(resultErr, fmt.Errorf("release migration coordination lock: %w", err))
			_ = conn.Close(cleanup)
		}
	}()
	return f()
}

func pgControlTransaction(ctx context.Context, conn *pgx.Conn, exclusive bool, f func(pgx.Tx) error) error {
	return pgMigrationSessionLock(ctx, conn, 32341, 0, exclusive, func() error {
		return pgControlSnapshot(ctx, conn, f)
	})
}

func pgControlSnapshot(ctx context.Context, conn *pgx.Conn, f func(pgx.Tx) error) (resultErr error) {
	return pgControlSnapshotMode(ctx, conn, pgx.ReadWrite, f)
}

func pgControlSnapshotMode(ctx context.Context, conn *pgx.Conn, access pgx.TxAccessMode, f func(pgx.Tx) error) (resultErr error) {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: access})
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			resultErr = errors.Join(resultErr, err)
			_ = conn.Close(cleanup)
		}
	}()
	if err := pgControlSession(ctx, tx); err != nil {
		return err
	}
	var server int
	if err := tx.QueryRow(ctx, "select pg_catalog.current_setting('server_version_num')::integer").Scan(&server); err != nil {
		return err
	}
	if server < 140000 || server >= 190000 {
		return fmt.Errorf("migration control supports PostgreSQL 14 through 18, got %d", server)
	}
	return f(tx)
}

// InstallPgMigrationControl creates only protected control objects, not entity
// tables. Its caller is the short-lived installer with operator-controlled
// temporary Owner membership; the operator must revoke that membership afterward.
// A production worker cannot invoke this installer. Existing objects are checked
// and never adopted by name. The initial installation target is immutable.
func InstallPgMigrationControl(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, initialVersion int) (PgMigrationControlState, error) {
	return pgInstallMigrationControl(ctx, conn, namespace, roles, initialVersion, nil)
}

// InstallPgCompiledMigrationControl binds installation to the binary's checked
// history. A fresh database starts at the current revision; a retry retains and
// validates the actual protected origin and every persisted step. Validation and
// installation share the installer lock and snapshot, including before commit.
// The same operator-provisioned roles and temporary membership rules apply as to
// InstallPgMigrationControl. No entity DDL or role administration runs here.
func InstallPgCompiledMigrationControl(ctx context.Context, conn *pgx.Conn, history PgCompiledMigrationHistory, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	if _, err := history.ExpansionPlan(history.CurrentVersion); err != nil {
		return PgMigrationControlState{}, err
	}
	return pgInstallMigrationControl(ctx, conn, history.Namespace, roles, history.CurrentVersion, func(tx pgx.Tx, state PgMigrationControlState) error {
		plan, err := history.ExpansionPlan(state.InitialVersion)
		if err != nil {
			return err
		}
		intents, err := pgReadExpansionIntents(ctx, tx, history.Namespace)
		if err != nil {
			return err
		}
		return pgVerifyExpansionHistory(state, plan, intents)
	})
}

func pgInstallMigrationControl(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, initialVersion int,
	verify func(pgx.Tx, PgMigrationControlState) error) (PgMigrationControlState, error) {
	var state PgMigrationControlState
	if !pgMigrationIdentifier(namespace) || strings.HasPrefix(namespace, "pg_") || initialVersion < 1 || initialVersion > 2147483646 {
		return state, fmt.Errorf("invalid migration namespace or installation version")
	}
	err := pgControlTransaction(ctx, conn, true, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles, true); err != nil {
			return err
		}
		exists, err := pgControlNamespace(ctx, tx, namespace, roles.Owner, roles.Worker)
		if err != nil {
			return err
		}
		if exists {
			present, err := pgControlTableExists(ctx, tx, namespace, "tesl_schema_meta")
			if err != nil {
				return err
			}
			if present {
				state, err = pgInspectControl(ctx, tx, namespace, roles)
				if err == nil && verify != nil {
					err = verify(tx, state)
				}
				return err // Inspection rolls back its temporary comparison objects.
			}
			var occupied bool
			if err := tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname=$1)
 or exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname=$1)`, namespace).Scan(&occupied); err != nil {
				return err
			}
			if occupied {
				return fmt.Errorf("namespace %s contains pre-versioning objects; use an explicit adoption plan", namespace)
			}
		}
		if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
			return err
		}
		if !exists {
			if _, err := tx.Exec(ctx, "create schema "+quoteIdentifier(namespace)); err != nil {
				return err
			}
		}
		registry, err := pgControlTableExists(ctx, tx, "public", pgMigrationFenceRegistry.name)
		if err != nil {
			return err
		}
		if !registry {
			if _, err := tx.Exec(ctx, "create table public."+pgMigrationFenceRegistry.name+" ("+pgMigrationFenceRegistry.columns+")"); err != nil {
				return err
			}
		}
		if err := pgControlTableCatalog(ctx, tx, "public", roles.Owner, roles.Worker, pgMigrationFenceRegistry); err != nil {
			return err
		}
		readers := quoteIdentifier(roles.Worker)
		if roles.Request != "" {
			readers += "," + quoteIdentifier(roles.Request)
		}
		if _, err := tx.Exec(ctx, "grant usage on schema public to "+readers+
			"; grant select on public.tesl_fence_namespaces to "+readers); err != nil {
			return err
		}
		for _, spec := range pgMigrationControlTables {
			if _, err := tx.Exec(ctx, "create table "+pgx.Identifier{namespace, spec.name}.Sanitize()+" ("+spec.columns+")"); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, "grant select on "+pgx.Identifier{namespace, spec.name}.Sanitize()+" to "+readers); err != nil {
				return err
			}
		}
		for _, fn := range pgMigrationControlFunctions(namespace) {
			if _, err := tx.Exec(ctx, pgControlFunctionSQL(namespace, roles.Owner, fn)); err != nil {
				return err
			}
			qualified := pgx.Identifier{namespace, fn.name}.Sanitize() + "(" + pgControlArgumentTypes(fn) + ")"
			grantees := pgControlFunctionRoles(roles, fn)
			for i := range grantees {
				grantees[i] = quoteIdentifier(grantees[i])
			}
			if _, err := tx.Exec(ctx, "revoke all on function "+qualified+" from public; grant execute on function "+qualified+" to "+strings.Join(grantees, ",")); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, "grant usage, create on schema "+quoteIdentifier(namespace)+" to "+quoteIdentifier(roles.Worker)); err != nil {
			return err
		}
		if roles.Request != "" {
			if _, err := tx.Exec(ctx, "grant usage on schema "+quoteIdentifier(namespace)+" to "+quoteIdentifier(roles.Request)); err != nil {
				return err
			}
		}
		ns := quoteIdentifier(namespace) + "."
		if _, err := tx.Exec(ctx, `with allocated as (
 insert into public.tesl_fence_namespaces(database_uuid) values (pg_catalog.gen_random_uuid()) returning database_uuid,fence_ns)
 insert into `+ns+`tesl_schema_meta(id,format_version,database_uuid,initial_version,max_observed_protocol,retirement_protocol_floor,fence_ns,fence_domain)
 select 1,$1,database_uuid,$2,1,1,fence_ns,'tesl-1' from allocated`, pgMigrationControlFormat, initialVersion); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_schema_state(id,min_version,current,installing_version,compat_floor) values (1,0,0,$1,0)", initialVersion); err != nil {
			return err
		}
		state, err = pgInspectControl(ctx, tx, namespace, roles)
		if err != nil {
			return err
		}
		if verify != nil {
			if err := verify(tx, state); err != nil {
				return err
			}
		}
		migrationBoundary("control-before-commit")
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		migrationBoundary("control-after-commit")
		return nil
	})
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return state, nil
}

// InspectPgMigrationControl observes the protected format on an idle connection.
// It creates only temporary comparison objects and rolls them back. It does not
// run bootstrap, repair grants, adopt existing objects or advance lifecycle state.
func InspectPgMigrationControl(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	var state PgMigrationControlState
	if !pgMigrationIdentifier(namespace) || strings.HasPrefix(namespace, "pg_") {
		return state, fmt.Errorf("invalid migration namespace")
	}
	err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles, false); err != nil {
			return err
		}
		exists, err := pgControlNamespace(ctx, tx, namespace, roles.Owner, roles.Worker)
		if err != nil || !exists {
			return err
		}
		state, err = pgInspectControl(ctx, tx, namespace, roles)
		return err
	})
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return state, nil
}

func pgInspectControl(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	return pgInspectControlMode(ctx, tx, namespace, roles, false)
}

func pgInspectControlReadOnly(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	return pgInspectControlMode(ctx, tx, namespace, roles, true)
}

func pgInspectControlMode(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, readOnly bool) (PgMigrationControlState, error) {
	var state PgMigrationControlState
	inspectTable, principal := pgControlTableCatalog, roles.Worker
	if readOnly {
		inspectTable, principal = pgControlTableCatalogReadOnly, roles.Request
	}
	if exists, err := pgControlNamespace(ctx, tx, namespace, roles.Owner, roles.Worker); err != nil || !exists {
		if err == nil {
			err = fmt.Errorf("migration control namespace is missing")
		}
		return state, err
	}
	if err := inspectTable(ctx, tx, "public", roles.Owner, principal, pgMigrationFenceRegistry); err != nil {
		return state, err
	}
	for _, spec := range pgMigrationControlTables {
		if err := inspectTable(ctx, tx, namespace, roles.Owner, principal, spec); err != nil {
			return state, err
		}
		if spec.name == "tesl_schema_meta" {
			var format int
			if err := tx.QueryRow(ctx, "select format_version from "+quoteIdentifier(namespace)+".tesl_schema_meta where id=1").Scan(&format); err != nil {
				return state, fmt.Errorf("migration control format is unavailable: %w", err)
			}
			if format != pgMigrationControlFormat {
				return state, fmt.Errorf("unsupported migration control format %d; format %d with stored-value compatibility is required; no automatic upgrade is available", format, pgMigrationControlFormat)
			}
		}
	}
	for _, fn := range pgMigrationControlFunctions(namespace) {
		if err := pgControlFunctionCatalog(ctx, tx, namespace, roles, fn); err != nil {
			return state, err
		}
	}
	var functionCount int
	if err := tx.QueryRow(ctx, `select pg_catalog.count(*) from pg_catalog.pg_proc p
 join pg_catalog.pg_namespace n on n.oid=p.pronamespace join pg_catalog.pg_roles r on r.oid=p.proowner
 where n.nspname=$1 and r.rolname=$2`, namespace, roles.Owner).Scan(&functionCount); err != nil {
		return state, err
	}
	if functionCount != len(pgMigrationControlFunctions(namespace)) {
		return state, fmt.Errorf("migration control namespace contains an unrecorded control-owned function")
	}
	ns := quoteIdentifier(namespace) + "."
	err := tx.QueryRow(ctx, `select m.format_version,m.database_uuid::text,m.initial_version,m.max_observed_protocol,m.retirement_protocol_floor,m.fence_ns,m.fence_domain,
 s.current,s.min_version,s.compat_floor,coalesce(s.installing_version,0)
 from `+ns+`tesl_schema_meta m cross join `+ns+`tesl_schema_state s where m.id=1 and s.id=1 and
 exists(select 1 from public.tesl_fence_namespaces f where f.database_uuid=m.database_uuid and f.fence_ns=m.fence_ns)`).
		Scan(&state.Format, &state.DatabaseUUID, &state.InitialVersion, &state.MaxObservedProtocol, &state.RetirementProtocolFloor, &state.FenceNamespace, &state.FenceDomain,
			&state.Current, &state.MinVersion, &state.CompatFloor, &state.InstallingVersion)
	if err != nil {
		return state, fmt.Errorf("migration control singleton or its registry identity is missing: %w", err)
	}
	if state.Format != pgMigrationControlFormat || state.FenceDomain != "tesl-1" || state.RetirementProtocolFloor != 1 || state.MaxObservedProtocol < 1 ||
		state.InitialVersion < 1 || state.InitialVersion > 2147483646 || state.Current < 0 || state.Current > 2147483646 ||
		state.MinVersion < 0 || state.MinVersion > state.Current || state.CompatFloor < 0 || state.CompatFloor > state.Current ||
		(state.Current == 0 && (state.InstallingVersion != state.InitialVersion || state.MinVersion != 0 || state.CompatFloor != 0)) ||
		(state.Current != 0 && (state.Current < state.InitialVersion || state.MinVersion != state.InitialVersion || state.InstallingVersion != 0 || state.CompatFloor != state.InitialVersion)) {
		return state, fmt.Errorf("migration control state is inconsistent or uses an unsupported format/protocol")
	}
	rows, err := tx.Query(ctx, "select version,seq,step,coalesce(snapshot_hash,''),artefact_hash,source_abi,fence_domain,stored_value_compatibility,protocol_level,epoch_preserving from "+ns+"tesl_schema_versions order by version,step,seq")
	if err != nil {
		return state, err
	}
	state.Versions, err = pgx.CollectRows(rows, pgx.RowToStructByPos[PgMigrationControlVersion])
	if err != nil {
		return state, err
	}
	state.Present = true
	return state, nil
}
