(** Declarative schema for configuration blocks (database / queue / channel /
    cache / email and their nested sub-blocks).

    This is the SINGLE SOURCE OF TRUTH for what fields each config block accepts,
    their value shape, whether they are required, and a one-line doc.  It drives:

    - {!Validation_structural.check_config_field_schema} — colon-required and
      unknown-field diagnostics; and
    - the LSP [--config-context-json] query (hover + completion for fields).

    The parser ({!Parser}) captures every field the user actually wrote into the
    block's [raw_fields] (see {!Ast.config_field}); this module says what SHOULD
    be there. *)

(** A field's value shape.  [Scalar]'s string is a human type label shown in
    hover (e.g. ["String"], ["Int"], ["postgres"], ["env(...)"]).  [Block] names
    a nested sub-schema (its fields live in another {!schema}); [Params] is the
    [key(name: T, ...)] form.  [Block] and [Params] are written WITHOUT a colon
    (e.g. [postgres { ... }], [key(userId: String)]); every [Scalar] field is
    written [name: value] and the colon is required. *)
type kind =
  | Scalar of string  (** colon-required;  the string is a type label for hover *)
  | Block  of string  (** colon-exempt;    the string names the nested sub-schema *)
  | Params            (** colon-exempt;    the [key(...)] param-list form *)

type field = {
  fname    : string;
  kind     : kind;
  required : bool;
  doc      : string;
}

type schema = {
  sname  : string;
  fields : field list;
}

let scalar ?(required=false) fname label doc = { fname; kind = Scalar label; required; doc }
let block  ?(required=false) fname sub doc   = { fname; kind = Block sub;    required; doc }

(* ── The schemas ─────────────────────────────────────────────────────────── *)

let database_schema = {
  sname = "database";
  fields = [
    scalar "backend"  "postgres" "Storage backend (currently always `postgres`).";
    scalar ~required:true "schema" "String" "Postgres schema name the entities live in.";
    scalar "entities" "[Entity]" "Entities (tables) stored in this database.";
    block  ~required:true "postgres" "postgres" "Postgres connection settings.";
  ];
}

let postgres_schema = {
  sname = "postgres";
  fields = [
    scalar "dbName"   "String" "Database name (logical DB), e.g. `env(\"DB_NAME\")`.";
    scalar "user"     "String" "Connection user, e.g. `env(\"DB_USER\")`.";
    scalar "password" "String" "Connection password, e.g. `env(\"DB_PASS\")`.";
    scalar "host"     "String" "Server host, e.g. `env(\"DB_HOST\")`.";
    scalar "port"     "Int" "Server port, e.g. `envInt(\"PORT\", 5432)`.";
    scalar "socket"   "String" "Unix socket path (alternative to host/port).";
  ];
}

let retry_schema = {
  sname = "retry";
  fields = [
    scalar "maxAttempts"  "Int" "Maximum delivery attempts before dead-lettering.";
    scalar "backoff"      "exponential | fixed" "Backoff strategy between retries.";
    scalar "initialDelay" "Int" "Initial delay (seconds) before the first retry.";
  ];
}

let queue_schema = {
  sname = "queue";
  fields = [
    scalar ~required:true "database" "Database" "Database backing this queue's job storage.";
    scalar ~required:true "jobs"     "[JobType]" "Job types this queue carries.";
    block  "retry"    "retry" "Retry policy for failed jobs.";
    (* The three retry knobs are also accepted flattened at the queue top level. *)
    scalar "maxAttempts"  "Int" "Maximum delivery attempts (or nest under `retry`).";
    scalar "backoff"      "exponential | fixed" "Backoff strategy (or nest under `retry`).";
    scalar "initialDelay" "Int" "Initial retry delay (or nest under `retry`).";
  ];
}

let channel_schema = {
  sname = "channel";
  fields = [
    { fname = "key";      kind = Params; required = false;
      doc = "Channel key parameters, e.g. `key(userId: String)`." };
    { fname = "keyParams"; kind = Params; required = false;
      doc = "Channel key parameters (alias of `key`)." };
    scalar ~required:true "database" "Database" "Database backing this channel.";
    scalar ~required:true "payload"  "Type" "Payload type published on this channel.";
  ];
}

let cache_schema = {
  sname = "cache";
  fields = [
    scalar ~required:true "database" "Database" "Database backing this cache.";
    scalar "defaultTtl" "Int" "Default time-to-live in seconds.";
    scalar ~required:true "valueType"  "Type" "Type of values stored in the cache.";
  ];
}

let smtp_schema = {
  sname = "smtp";
  fields = [
    scalar ~required:true "host" "env(...)" "SMTP server host.";
    scalar "port"     "Int" "SMTP server port (default 587).";
    scalar "username" "env(...)" "SMTP auth username.";
    scalar "password" "env(...)" "SMTP auth password.";
    scalar "tls"      "Bool" "Whether to use TLS (default true).";
  ];
}

let email_schema = {
  sname = "email";
  fields = [
    scalar ~required:true "database" "Database" "Database backing the email outbox.";
    block  ~required:true "smtp" "smtp" "SMTP connection settings.";
  ];
}

let all_schemas = [
  database_schema; postgres_schema; retry_schema; queue_schema;
  channel_schema; cache_schema; smtp_schema; email_schema;
]

(* ── Lookups ─────────────────────────────────────────────────────────────── *)

let schema_for (name : string) : schema option =
  List.find_opt (fun s -> s.sname = name) all_schemas

let field_in (s : schema) (fname : string) : field option =
  List.find_opt (fun f -> f.fname = fname) s.fields

let is_colon_required (f : field) : bool =
  match f.kind with Scalar _ -> true | Block _ | Params -> false

(** A short, human label for a field's value shape, for diagnostics/hover. *)
let kind_label (f : field) : string =
  match f.kind with
  | Scalar lbl -> lbl
  | Block sub  -> sub ^ " { … }"
  | Params     -> "(…)"

(** The top-level schema for a config declaration, if it is one of the
    schema-validated kinds.  Returns [(schema, raw_fields)]. *)
let top_schema_of_decl (d : Ast.top_decl) : (schema * Ast.config_field list) option =
  match d with
  (* New typed-record syntax (`= Database { … }`) is validated by the config
     type-checker, not this raw-fields schema pass — skip it here. *)
  | Ast.DDatabase r when r.Ast.config_expr <> None -> None
  | Ast.DQueue r    when r.Ast.config_expr <> None -> None
  | Ast.DChannel r  when r.Ast.config_expr <> None -> None
  | Ast.DEmail r    when r.Ast.config_expr <> None -> None
  | Ast.DCache r    when r.Ast.config_expr <> None -> None
  | Ast.DDatabase r -> Option.map (fun s -> (s, r.Ast.raw_fields)) (schema_for "database")
  | Ast.DQueue r    -> Option.map (fun s -> (s, r.Ast.raw_fields)) (schema_for "queue")
  | Ast.DChannel r  -> Option.map (fun s -> (s, r.Ast.raw_fields)) (schema_for "channel")
  | Ast.DCache r    -> Option.map (fun s -> (s, r.Ast.raw_fields)) (schema_for "cache")
  | Ast.DEmail r    -> Option.map (fun s -> (s, r.Ast.raw_fields)) (schema_for "email")
  | _ -> None
