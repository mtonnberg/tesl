package teslrt

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"

	"github.com/jackc/pgx/v5"
)

func pgControlSession(ctx context.Context, tx pgx.Tx) error {
	_, err := tx.Exec(ctx, `set local search_path = ''; set local standard_conforming_strings = on;
set local DateStyle = 'ISO, YMD'; set local IntervalStyle = 'postgres'; set local TimeZone = 'UTC';
set local extra_float_digits = 3; set local bytea_output = 'hex'; set local lock_timeout = '2s'`)
	return err
}

func pgControlRoles(ctx context.Context, tx pgx.Tx, roles PgMigrationControlRoles, installer bool) error {
	owner, worker := roles.Owner, roles.Worker
	if !pgMigrationIdentifier(owner) || !pgMigrationIdentifier(worker) || owner == worker {
		return fmt.Errorf("migration control requires distinct valid control and worker roles")
	}
	if roles.Request != "" && (!pgMigrationIdentifier(roles.Request) || roles.Request == owner || roles.Request == worker) {
		return fmt.Errorf("worker migration topology requires distinct valid owner, worker and request roles")
	}
	var valid, canInstall, leaked bool
	err := tx.QueryRow(ctx, `select
 w.rolcanlogin and not c.rolcanlogin and not c.rolsuper and not c.rolcreaterole and not c.rolcreatedb and not c.rolreplication and not c.rolbypassrls
 and not pg_catalog.pg_has_role(w.oid,c.oid,'MEMBER')
 and not pg_catalog.pg_has_role(w.oid,(select datdba from pg_catalog.pg_database where datname=pg_catalog.current_database()),'MEMBER')
 and not exists (select 1 from pg_catalog.pg_roles p where pg_catalog.pg_has_role(w.oid,p.oid,'MEMBER')
   and (p.rolsuper or p.rolcreaterole or p.rolcreatedb or p.rolreplication or p.rolbypassrls or p.rolname in
     ('pg_write_all_data','pg_signal_backend','pg_execute_server_program','pg_read_server_files','pg_write_server_files','pg_checkpoint','pg_create_subscription','pg_maintain')))
 and not exists (select 1 from pg_catalog.pg_auth_members m where m.member=c.oid),
 pg_catalog.pg_has_role(current_user,c.oid,'MEMBER'),
 exists (select 1 from pg_catalog.pg_roles r where r.rolcanlogin and not r.rolsuper and not r.rolcreaterole
   and pg_catalog.pg_has_role(r.oid,c.oid,'MEMBER') and not ($3 and r.rolname=session_user))
 from pg_catalog.pg_roles c cross join pg_catalog.pg_roles w where c.rolname=$1 and w.rolname=$2`, owner, worker, installer).
		Scan(&valid, &canInstall, &leaked)
	if err != nil {
		return fmt.Errorf("migration control roles must be provisioned by the operator: %w", err)
	}
	if !valid || leaked {
		return fmt.Errorf("migration control role isolation is invalid: workers and long-lived logins must not have control-owner or administrative authority")
	}
	if installer && !canInstall {
		return fmt.Errorf("migration installation requires a short-lived identity with temporary control-owner membership")
	}
	if roles.Request != "" {
		var isolated bool
		if err := tx.QueryRow(ctx, `select r.rolcanlogin
 and not pg_catalog.pg_has_role(r.oid,(select oid from pg_catalog.pg_roles where rolname=$2),'MEMBER')
 and not pg_catalog.pg_has_role(r.oid,(select oid from pg_catalog.pg_roles where rolname=$3),'MEMBER')
 and not pg_catalog.pg_has_role(r.oid,(select datdba from pg_catalog.pg_database where datname=pg_catalog.current_database()),'MEMBER')
 and not exists (select 1 from pg_catalog.pg_roles p where pg_catalog.pg_has_role(r.oid,p.oid,'MEMBER')
   and (p.rolsuper or p.rolcreaterole or p.rolcreatedb or p.rolreplication or p.rolbypassrls or p.rolname in
     ('pg_write_all_data','pg_signal_backend','pg_execute_server_program','pg_read_server_files','pg_write_server_files','pg_checkpoint','pg_create_subscription','pg_maintain')))
 from pg_catalog.pg_roles r where r.rolname=$1`, roles.Request, owner, worker).Scan(&isolated); err != nil {
			return fmt.Errorf("migration request role must be provisioned by the operator: %w", err)
		}
		if !isolated {
			return fmt.Errorf("migration request role isolation is invalid: request logins must not have worker, control-owner or administrative authority")
		}
	}
	return nil
}

func pgControlNamespace(ctx context.Context, tx pgx.Tx, namespace, owner, worker string) (bool, error) {
	var actualOwner string
	var unsafe bool
	err := tx.QueryRow(ctx, `select r.rolname, exists (
 select 1 from pg_catalog.aclexplode(coalesce(n.nspacl,pg_catalog.acldefault('n',n.nspowner))) a
 where a.privilege_type='CREATE' and a.grantee<>n.nspowner and a.grantee<>(select oid from pg_catalog.pg_roles where rolname=$2))
 from pg_catalog.pg_namespace n join pg_catalog.pg_roles r on r.oid=n.nspowner where n.nspname=$1`, namespace, worker).
		Scan(&actualOwner, &unsafe)
	if err == pgx.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if actualOwner != owner || unsafe {
		return true, fmt.Errorf("migration namespace %q has a different owner or an unauthorized CREATE grant", namespace)
	}
	return true, nil
}

func pgControlTableExists(ctx context.Context, tx pgx.Tx, namespace, name string) (bool, error) {
	var exists bool
	err := tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_class c
 join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname=$1 and c.relname=$2)`, namespace, name).Scan(&exists)
	return exists, err
}

func pgControlTableACL(ctx context.Context, tx pgx.Tx, namespace, name, worker string) error {
	var unsafe bool
	err := tx.QueryRow(ctx, `select exists (
 select 1 from pg_catalog.aclexplode(coalesce(c.relacl,pg_catalog.acldefault('r',c.relowner))) a
 where a.privilege_type<>'SELECT' and a.grantee<>c.relowner) or exists (
 select 1 from pg_catalog.pg_attribute col cross join lateral pg_catalog.aclexplode(col.attacl) a
 where col.attrelid=c.oid and a.privilege_type<>'SELECT' and a.grantee<>c.relowner)
 or pg_catalog.has_table_privilege($3,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
 or pg_catalog.has_any_column_privilege($3,c.oid,'INSERT,UPDATE,REFERENCES')
 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname=$1 and c.relname=$2`, namespace, name, worker).Scan(&unsafe)
	if err != nil {
		return err
	}
	if unsafe {
		return fmt.Errorf("protected migration table %s.%s grants write authority outside its control owner", namespace, name)
	}
	return nil
}

// Compare actual and temporary expected tables under the same server and session
// settings. Control objects have no benign-extra-column exception: every column,
// constraint and index belongs to the versioned format. Live defaults are never
// executed, and the temporary object is dropped before returning.
func pgControlTableCatalog(ctx context.Context, tx pgx.Tx, namespace, owner, worker string, spec pgMigrationControlTable) error {
	actual, err := pgReadMigrationTable(ctx, tx, namespace, spec.name)
	if err != nil {
		return err
	}
	if actual == nil {
		return fmt.Errorf("protected migration table %s.%s is missing", namespace, spec.name)
	}
	name := "tesl_control_probe_" + rand.Text()
	if _, err := tx.Exec(ctx, "create temporary table "+quoteIdentifier(name)+" ("+spec.columns+") on commit drop"); err != nil {
		return err
	}
	var temporary string
	if err := tx.QueryRow(ctx, "select nspname from pg_catalog.pg_namespace where oid=pg_catalog.pg_my_temp_schema()").Scan(&temporary); err != nil {
		return err
	}
	expected, err := pgReadMigrationTable(ctx, tx, temporary, name)
	if err != nil {
		return err
	}
	if expected == nil {
		return fmt.Errorf("migration control comparison object disappeared")
	}
	expected.Name, expected.Owner, expected.Persistence = spec.name, owner, "p"
	if !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
		return fmt.Errorf("protected migration table %s.%s differs from control format %d", namespace, spec.name, pgMigrationControlFormat)
	}
	if err := pgControlTableACL(ctx, tx, namespace, spec.name, worker); err != nil {
		return err
	}
	if err := pgControlSequences(ctx, tx, namespace, spec.name, temporary, name, owner, worker); err != nil {
		return err
	}
	_, err = tx.Exec(ctx, "drop table "+pgx.Identifier{temporary, name}.Sanitize())
	return err
}

type pgControlSequence struct {
	Column, Owner              string
	Type                       uint32
	Start, Increment, Min, Max int64
	Cache                      int64
	Cycle, Unsafe              bool
}

func pgReadControlSequences(ctx context.Context, tx pgx.Tx, namespace, table, worker string) ([]pgControlSequence, error) {
	rows, err := tx.Query(ctx, `select a.attname,r.rolname,s.seqtypid,s.seqstart,s.seqincrement,s.seqmin,s.seqmax,s.seqcache,s.seqcycle,
 exists (select 1 from pg_catalog.aclexplode(coalesce(q.relacl,pg_catalog.acldefault('S',q.relowner))) grant_entry
   where grant_entry.grantee<>q.relowner and grant_entry.privilege_type<>'SELECT')
 or pg_catalog.has_sequence_privilege($3,q.oid,'USAGE,UPDATE')
 from pg_catalog.pg_class t join pg_catalog.pg_namespace n on n.oid=t.relnamespace
 join pg_catalog.pg_depend d on d.refclassid='pg_catalog.pg_class'::pg_catalog.regclass and d.refobjid=t.oid
   and d.classid='pg_catalog.pg_class'::pg_catalog.regclass and d.deptype in ('a','i')
 join pg_catalog.pg_sequence s on s.seqrelid=d.objid
 join pg_catalog.pg_class q on q.oid=s.seqrelid join pg_catalog.pg_roles r on r.oid=q.relowner
 join pg_catalog.pg_attribute a on a.attrelid=t.oid and a.attnum=d.refobjsubid
 where n.nspname=$1 and t.relname=$2 order by a.attname`, namespace, table, worker)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[pgControlSequence])
}

func pgControlSequences(ctx context.Context, tx pgx.Tx, namespace, table, temporary, probe, owner, worker string) error {
	actual, err := pgReadControlSequences(ctx, tx, namespace, table, worker)
	if err != nil {
		return err
	}
	expected, err := pgReadControlSequences(ctx, tx, temporary, probe, worker)
	if err != nil {
		return err
	}
	for i := range expected {
		expected[i].Owner, expected[i].Unsafe = owner, false
	}
	if !reflect.DeepEqual(actual, expected) {
		return fmt.Errorf("protected migration sequence for %s.%s has a different definition, owner or write grant", namespace, table)
	}
	return nil
}

func pgControlFunctionSQL(namespace, owner string, fn pgMigrationControlFunction) string {
	return "create function " + pgx.Identifier{namespace, fn.name}.Sanitize() + "(" + fn.arguments + ") returns " + fn.result +
		" language plpgsql " + fn.volatility + " security definer set search_path = '' as '" + strings.ReplaceAll(fn.body, "'", "''") + "';\n" +
		"alter function " + pgx.Identifier{namespace, fn.name}.Sanitize() + "(" + pgControlArgumentTypes(fn) + ") owner to " + quoteIdentifier(owner)
}

func pgControlArgumentTypes(fn pgMigrationControlFunction) string {
	arguments := strings.Split(fn.arguments, ",")
	for i, argument := range arguments {
		fields := strings.Fields(argument)
		arguments[i] = fields[len(fields)-1]
	}
	return strings.Join(arguments, ",")
}

func pgControlFunctionCatalog(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, fn pgMigrationControlFunction) error {
	var actual struct {
		Owner, Language, Kind, Arguments, Result, Volatility, Parallel, Body string
		SecurityDefiner, Strict, Leakproof, SetReturning, Unsafe             bool
		Configuration                                                        []string
		Support                                                              uint32
	}
	var encoded []byte
	err := tx.QueryRow(ctx, `select pg_catalog.jsonb_build_object(
 'Owner',r.rolname,'Language',l.lanname,'Kind',p.prokind,'Arguments',pg_catalog.pg_get_function_arguments(p.oid),
 'Result',pg_catalog.pg_get_function_result(p.oid),'Volatility',p.provolatile,'Parallel',p.proparallel,'Support',p.prosupport::bigint,'Body',p.prosrc,
 'SecurityDefiner',p.prosecdef,'Strict',p.proisstrict,'Leakproof',p.proleakproof,'SetReturning',p.proretset,
 'Configuration',p.proconfig,'Unsafe',exists (
   select 1 from pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
   where a.grantee<>p.proowner and (a.grantee not in (select oid from pg_catalog.pg_roles where rolname=any($4::text[])) or a.is_grantable))
   or exists (select 1 from unnest($4::text[]) expected(role) where not exists (
     select 1 from pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
     join pg_catalog.pg_roles grantee on grantee.oid=a.grantee where grantee.rolname=expected.role and a.privilege_type='EXECUTE' and not a.is_grantable)))
 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
 join pg_catalog.pg_roles r on r.oid=p.proowner join pg_catalog.pg_language l on l.oid=p.prolang
 where n.nspname=$1 and p.proname=$2 and pg_catalog.oidvectortypes(p.proargtypes)=$3`,
		namespace, fn.name, strings.ReplaceAll(pgControlArgumentTypes(fn), ",", ", "), pgControlFunctionRoles(roles, fn)).Scan(&encoded)
	if err != nil {
		return fmt.Errorf("protected migration function %s.%s is missing or unreadable: %w", namespace, fn.name, err)
	}
	if err := json.Unmarshal(encoded, &actual); err != nil {
		return err
	}
	if actual.Owner != roles.Owner || actual.Language != "plpgsql" || actual.Kind != "f" || actual.Arguments != fn.arguments ||
		actual.Result != fn.result || actual.Volatility != fn.volatility[:1] || actual.Parallel != "u" || actual.Support != 0 || actual.Body != fn.body ||
		!actual.SecurityDefiner || actual.Strict || actual.Leakproof || actual.SetReturning || actual.Unsafe ||
		!reflect.DeepEqual(actual.Configuration, []string{`search_path=""`}) {
		return fmt.Errorf("protected migration function %s.%s differs from its definition, owner or execution grants", namespace, fn.name)
	}
	return nil
}

func pgControlFunctionRoles(roles PgMigrationControlRoles, fn pgMigrationControlFunction) []string {
	principals := []string{roles.Worker}
	if roles.Request != "" && (fn.name == "tesl_admit" || fn.name == "tesl_heartbeat") {
		principals = append(principals, roles.Request)
	}
	return principals
}
