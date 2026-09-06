package teslrt

// pgCatalogTrigger is a catalog observation, never a permitted-trigger list.
// Type retains PostgreSQL's complete timing/event/row bit mask, including any
// future bits. Definition is PostgreSQL's deparse of the whole trigger and its
// WHEN expression: pg_get_expr cannot deparse every OLD/NEW trigger condition.
// References use qualified identities rather than installation-specific OIDs.
type pgCatalogTrigger struct {
	Relation                                              pgCatalogRelationReference
	Name, Definition, Enabled                             string
	Type                                                  int
	Internal, Deferrable, InitiallyDeferred, HasCondition bool
	Columns                                               []int
	ArgumentCount                                         int
	ArgumentsHex                                          string
	OldTransitionTable, NewTransitionTable                *string
	Constraint                                            *pgCatalogTriggerConstraint
	ConstraintRelation, ConstraintIndex                   *pgCatalogRelationReference
	Parent                                                *pgCatalogTriggerReference
	Function                                              pgCatalogTriggerFunction
}

type pgCatalogRelationReference struct{ Namespace, Name, Kind string }
type pgCatalogTriggerReference struct{ Namespace, Table, Name string }
type pgCatalogTriggerConstraint struct {
	Namespace, Name, Kind                              string
	Deferrable, InitiallyDeferred, Validated, Enforced bool
	Relation, ReferencedRelation                       *pgCatalogRelationReference
}
type pgCatalogFunctionReference struct{ Namespace, Name, IdentityArguments string }
type pgCatalogTypeReference struct{ Namespace, Name, Kind string }
type pgCatalogFunctionACL struct {
	Grantor, Grantee, Privilege string
	Grantable                   bool
}

// Effective facts are requested explicitly for declared deployment roles. An
// unrelated role added elsewhere in the cluster does not alter this observation.
// These facts complement the actual ACL, including PUBLIC and grant options;
// neither alone proves that a function or deployment role is safe.
type pgCatalogFunctionRole struct {
	Role                                                             string
	Exists, Superuser, CanLogin, CreateRole                          bool
	Execute, GrantExecute, MemberOfOwner, InheritsOwner, CanSetOwner bool
	SchemaUsage, SchemaCreate                                        bool
}

type pgCatalogTriggerFunction struct {
	Namespace, Name, Owner, Language                 string
	Kind, Arguments, IdentityArguments, Result       string
	Source, Definition                               string
	Binary, SQLBody                                  *string
	Volatility, Parallel                             string
	SecurityDefiner, Strict, Leakproof, SetReturning bool
	Cost, Rows                                       float64
	ArgumentCount, DefaultCount                      int
	ArgumentTypes, AllArgumentTypes                  []pgCatalogTypeReference
	ArgumentModes, ArgumentNames                     []string
	ArgumentDefaults                                 *string
	ResultType                                       pgCatalogTypeReference
	VariadicType                                     *pgCatalogTypeReference
	TransformTypes                                   []pgCatalogTypeReference
	Support                                          *pgCatalogFunctionReference
	Configuration                                    []string
	ACL                                              []pgCatalogFunctionACL
	Roles                                            []pgCatalogFunctionRole `json:",omitempty"`
}

// This is part of pgMigrationCatalogSQL, not a second query: table, trigger,
// function and requested role observations share one statement snapshot even
// when the caller uses READ COMMITTED. Only catalog deparsers run; source, SQL
// bodies, defaults and trigger arguments are data and are never executed.
const pgMigrationTriggerCatalogSQL = `coalesce((select jsonb_agg(jsonb_build_object(
 'Relation',jsonb_build_object('Namespace',n.nspname,'Name',c.relname,'Kind',c.relkind),
 'Name',t.tgname,'Definition',pg_catalog.pg_get_triggerdef(t.oid,false),'Type',t.tgtype,
 'Enabled',t.tgenabled,'Internal',t.tgisinternal,'Deferrable',t.tgdeferrable,'InitiallyDeferred',t.tginitdeferred,
 'Columns',t.tgattr::smallint[],'ArgumentCount',t.tgnargs,'ArgumentsHex',pg_catalog.encode(t.tgargs,'hex'),
 'HasCondition',t.tgqual is not null,'OldTransitionTable',t.tgoldtable,'NewTransitionTable',t.tgnewtable,
 'Constraint',case when k.oid is not null then jsonb_build_object(
  'Namespace',kn.nspname,'Name',k.conname,'Kind',k.contype,'Deferrable',k.condeferrable,
  'InitiallyDeferred',k.condeferred,'Validated',k.convalidated,
  'Enforced',coalesce((to_jsonb(k)->>'conenforced')::boolean,true),
  'Relation',case when kr.oid is not null then jsonb_build_object('Namespace',krn.nspname,'Name',kr.relname,'Kind',kr.relkind) end,
  'ReferencedRelation',case when kf.oid is not null then jsonb_build_object('Namespace',kfn.nspname,'Name',kf.relname,'Kind',kf.relkind) end) end,
 'ConstraintRelation',case when cr.oid is not null then jsonb_build_object('Namespace',crn.nspname,'Name',cr.relname,'Kind',cr.relkind) end,
 'ConstraintIndex',case when ci.oid is not null then jsonb_build_object('Namespace',cin.nspname,'Name',ci.relname,'Kind',ci.relkind) end,
 'Parent',case when parent.oid is not null then jsonb_build_object('Namespace',parentn.nspname,'Table',parentr.relname,'Name',parent.tgname) end,
 'Function',jsonb_build_object(
  'Namespace',pn.nspname,'Name',p.proname,'Owner',pr.rolname,'Language',l.lanname,'Kind',p.prokind,
  'Arguments',pg_catalog.pg_get_function_arguments(p.oid),'IdentityArguments',pg_catalog.pg_get_function_identity_arguments(p.oid),
  'Result',pg_catalog.pg_get_function_result(p.oid),'Source',p.prosrc,'Binary',p.probin,'SQLBody',p.prosqlbody::text,
  'Definition',pg_catalog.pg_get_functiondef(p.oid),'Volatility',p.provolatile,'Parallel',p.proparallel,
  'SecurityDefiner',p.prosecdef,'Strict',p.proisstrict,'Leakproof',p.proleakproof,'SetReturning',p.proretset,
  'Cost',p.procost,'Rows',p.prorows,'ArgumentCount',p.pronargs,'DefaultCount',p.pronargdefaults,
  'ArgumentTypes',coalesce((select jsonb_agg(jsonb_build_object('Namespace',n.nspname,'Name',a.typname,'Kind',a.typtype) order by v.ordinality)
    from unnest(p.proargtypes::oid[]) with ordinality v(oid,ordinality) join pg_catalog.pg_type a on a.oid=v.oid
    join pg_catalog.pg_namespace n on n.oid=a.typnamespace),'[]'::jsonb),
  'AllArgumentTypes',coalesce((select jsonb_agg(jsonb_build_object('Namespace',n.nspname,'Name',a.typname,'Kind',a.typtype) order by v.ordinality)
    from unnest(p.proallargtypes) with ordinality v(oid,ordinality) join pg_catalog.pg_type a on a.oid=v.oid
    join pg_catalog.pg_namespace n on n.oid=a.typnamespace),'[]'::jsonb),
  'ArgumentModes',p.proargmodes,'ArgumentNames',p.proargnames,'ArgumentDefaults',p.proargdefaults::text,
  'ResultType',jsonb_build_object('Namespace',rtn.nspname,'Name',rt.typname,'Kind',rt.typtype),
  'VariadicType',case when vt.oid is not null then jsonb_build_object('Namespace',vtn.nspname,'Name',vt.typname,'Kind',vt.typtype) end,
  'TransformTypes',coalesce((select jsonb_agg(jsonb_build_object('Namespace',n.nspname,'Name',a.typname,'Kind',a.typtype) order by v.ordinality)
    from unnest(p.protrftypes) with ordinality v(oid,ordinality) join pg_catalog.pg_type a on a.oid=v.oid
    join pg_catalog.pg_namespace n on n.oid=a.typnamespace),'[]'::jsonb),
  'Support',case when support.oid is not null then jsonb_build_object('Namespace',supportn.nspname,'Name',support.proname,
    'IdentityArguments',pg_catalog.pg_get_function_identity_arguments(support.oid)) end,
  'Configuration',p.proconfig,
  'ACL',coalesce((select jsonb_agg(jsonb_build_object(
    'Grantor',coalesce(grantor.rolname,a.grantor::text),
    'Grantee',case when a.grantee=0 then 'PUBLIC' else coalesce(grantee.rolname,a.grantee::text) end,
    'Privilege',a.privilege_type,'Grantable',a.is_grantable)
    order by coalesce(grantor.rolname,a.grantor::text),case when a.grantee=0 then 'PUBLIC' else coalesce(grantee.rolname,a.grantee::text) end,a.privilege_type,a.is_grantable)
    from pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
    left join pg_catalog.pg_roles grantor on grantor.oid=a.grantor left join pg_catalog.pg_roles grantee on grantee.oid=a.grantee),'[]'::jsonb),
  'Roles',coalesce((select jsonb_agg(jsonb_build_object(
    'Role',requested.name,'Exists',r.oid is not null,'Superuser',r.rolsuper,'CanLogin',r.rolcanlogin,'CreateRole',r.rolcreaterole,
    'Execute',pg_catalog.has_function_privilege(r.oid,p.oid,'EXECUTE'),
    'GrantExecute',pg_catalog.has_function_privilege(r.oid,p.oid,'EXECUTE WITH GRANT OPTION'),
    'MemberOfOwner',pg_catalog.pg_has_role(r.oid,p.proowner,'MEMBER'),
    'InheritsOwner',pg_catalog.pg_has_role(r.oid,p.proowner,'USAGE'),
    'CanSetOwner',pg_catalog.pg_has_role(r.oid,p.proowner,case when pg_catalog.current_setting('server_version_num')::integer>=160000 then 'SET' else 'MEMBER' end),
    'SchemaUsage',pg_catalog.has_schema_privilege(r.oid,p.pronamespace,'USAGE'),
    'SchemaCreate',pg_catalog.has_schema_privilege(r.oid,p.pronamespace,'CREATE')) order by requested.name)
    from unnest($3::text[]) requested(name) left join pg_catalog.pg_roles r on r.rolname=requested.name),'[]'::jsonb)
 )) order by t.tgname)
 from pg_catalog.pg_trigger t
 join pg_catalog.pg_proc p on p.oid=t.tgfoid join pg_catalog.pg_namespace pn on pn.oid=p.pronamespace
 join pg_catalog.pg_roles pr on pr.oid=p.proowner join pg_catalog.pg_language l on l.oid=p.prolang
 join pg_catalog.pg_type rt on rt.oid=p.prorettype join pg_catalog.pg_namespace rtn on rtn.oid=rt.typnamespace
 left join pg_catalog.pg_type vt on vt.oid=p.provariadic left join pg_catalog.pg_namespace vtn on vtn.oid=vt.typnamespace
 left join pg_catalog.pg_proc support on support.oid=p.prosupport left join pg_catalog.pg_namespace supportn on supportn.oid=support.pronamespace
 left join pg_catalog.pg_constraint k on k.oid=t.tgconstraint left join pg_catalog.pg_namespace kn on kn.oid=k.connamespace
 left join pg_catalog.pg_class kr on kr.oid=k.conrelid left join pg_catalog.pg_namespace krn on krn.oid=kr.relnamespace
 left join pg_catalog.pg_class kf on kf.oid=k.confrelid left join pg_catalog.pg_namespace kfn on kfn.oid=kf.relnamespace
 left join pg_catalog.pg_class cr on cr.oid=t.tgconstrrelid left join pg_catalog.pg_namespace crn on crn.oid=cr.relnamespace
 left join pg_catalog.pg_class ci on ci.oid=t.tgconstrindid left join pg_catalog.pg_namespace cin on cin.oid=ci.relnamespace
 left join pg_catalog.pg_trigger parent on parent.oid=t.tgparentid
 left join pg_catalog.pg_class parentr on parentr.oid=parent.tgrelid left join pg_catalog.pg_namespace parentn on parentn.oid=parentr.relnamespace
 where t.tgrelid=c.oid),'[]'::jsonb)`
