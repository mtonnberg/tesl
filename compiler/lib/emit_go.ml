(** Experimental Go backend. It intentionally supports a narrow pure subset and
    rejects everything else before writing an incomplete project. *)

open Ast

type mode = Release | Debug

type artifact = {
  path : string;
  contents : string;
}

type emit_error = {
  loc : Location.loc;
  message : string;
}

type go_type =
  | TInt
  | TFloat
  | TString
  | TBool
  | TUnit
  | TNewtype of newtype_info
  | TRecord of record_info
  | TAdt of adt_info * go_type list
  | TList of go_type
  | TDict of go_type * go_type
  | TSet of go_type
  | TParam of string
  (* A FUNCTION VALUE: `f: Int -> Int` as a parameter, or a lambda passed around.  The
     capability row on the arrow is compile-time (the checker propagates it), so only the
     domain and codomain survive. *)
  | TFunc of go_type list * go_type
  (* The UNTYPED api-test view of a JSON value.  Inside an `api-test` block a response body
     is inspected without types — `resp.body.userId` is deliberately untyped, and the checker
     types it as a fresh variable so the assertion reads like the JSON it checks.  That
     ergonomics is by design, so the emitter carries a dynamic value here rather than
     inventing a typed view the source never asked for. *)
  (* A DIMENSIONED quantity.  It renders as `float64` — the dimension lives in the compiler's
     type layer and erases — but it is a distinct type HERE, because that is the only thing
     that tells `rate * quantity` (a rate materialising into money) from `rate * scalar` (a
     rate rescaled): at run time both are floats, and Racket tells them apart by consulting the
     type its checker recorded. *)
  | TQuantity
  | TJson
  (* The api-test handle on an SSE subscription: `let stream = subscribe "/events/ada"`.  It
     is a live connection to the emitted server, not a value the program could construct, so
     the only things it supports are the `collect` verbs. *)
  | TStream
  | TCheck of go_type
  | TFailure
  (* An ADT type argument NOTHING constrains: `Left "e"` says what its Left payload is and
     says nothing at all about the Right one, and a value written that way may never meet a
     context that settles it (`Either.withDefault 99 (Left "err")` reads only the Left side).
     The parameter has no inhabitants there — the variant that would carry one is not the
     variant in hand — so any Go type serves, and it renders as the empty struct.

     It behaves as a WILDCARD in type comparison, and every merge prefers the other side, so
     the moment a sibling value or an expectation does settle the parameter, that type wins.
     What it must never do is claim to BE a type: nothing is emitted from a `TAnon` except
     `struct{}`, and no field, column or signature is ever accepted on its authority — those
     paths compare against a declared type, which is never anonymous. *)
  | TAnon

and newtype_info = {
  tesl_name : string;
  (* The package that DECLARES this type.  A reference from another package has to be
     qualified, and only the declaring package may emit the declaration. *)
  owner : string;
  go_name : string;
  base : go_type;
  (* A `secret` newtype.  Its payload is a `teslrt.SecretString`, which prints as
     "[redacted]" through every fmt verb, and equality on it is CONSTANT TIME — a secret
     that leaked through a log line or a timing difference would be a secret in name only. *)
  secret : bool;
  loc : Location.loc;
}

and record_info = {
  rec_tesl_name : string;
  rec_owner : string;
  rec_go_name : string;
  mutable rec_fields : (string * go_type) list;
  (* True when some field carries a PROOF annotation.  Proofs erase, so this changes nothing
     about the emitted struct — it matters in exactly one place: a property test's generator,
     which must not fabricate a value the field's proof claims something about. *)
  rec_proof_fields : bool;
  rec_loc : Location.loc;
}

(* A Tesl ADT becomes one flat Go value struct: an enum tag plus each variant's
   payload under a variant-qualified field name.  A tag keeps the emitted `switch`
   checkable by the `exhaustive` linter, which a Go type switch would not be. *)
and adt_info = {
  adt_tesl_name : string;
  adt_owner : string;
  adt_go_name : string;
  adt_tag_type : string;
  (* Tesl type parameters in declaration order, paired with the Go type-parameter
     names they render as. A generic ADT is only ever referenced instantiated. *)
  adt_params : (string * string) list;
  mutable adt_variants : variant_info list;
  adt_loc : Location.loc;
  (* A runtime-provided ADT (today only `Maybe`) is referenced, never declared: the
     emitter must not write its type, tag constants, or methods. *)
  adt_builtin : bool;
}

and variant_info = {
  var_ctor : string;
  var_tag : string;
  mutable var_fields : (string * go_type) list;
  (* Explicit Go field names, for a runtime-provided type whose struct is written by
     hand.  Empty means "derive from the constructor and field names". *)
  var_go_fields : (string * string) list;
  var_loc : Location.loc;
}

type signature = {
  params : go_type list;
  result : go_type;
  go_name : string;
  (* True when the function declares `cookieCap`, i.e. it may write to the response and so
     takes the request scope as its first parameter.  The `requires` clause IS the marker:
     the checker forces it to propagate to every caller, so no call-graph pass is needed. *)
  sig_needs_scope : bool;
  (* Empty for a runtime function (already spelled `teslrt.X`) and for the module being
     emitted; otherwise the package that declares it. *)
  sig_owner : string;
}

(* The package currently being emitted.  A reference to a name owned by another package
   is qualified with the owner; a reference to one's own package is bare, since Go
   forbids self-qualification.  This is a ref rather than a threaded parameter because
   `go_type` is called from ~40 sites; it is set once per module in compile_project and
   read nowhere else. *)
let current_package = ref ""

let qualified owner name =
  if owner = "" || owner = !current_package then name else owner ^ "." ^ name

(* A stdlib leaf whose Go function takes CONSTANTS the source does not write — the ISO code
   behind `Money.usd`, the label behind `MoneyRate.perHour`.  The constants ride on the
   signature's Go name after a `#`, and are appended to the call in the order they were
   registered: argument first, then what the declaration decided.  Rendered as an integer when
   they read as one and as a Go string otherwise, which is the whole vocabulary this needs
   (a numerator, a denominator, a currency code, a unit label). *)
let baked_call go_name arguments =
  match String.split_on_char '#' go_name with
  | [] -> invalid_arg "empty Go call name"
  | base :: [] -> Printf.sprintf "%s(%s)" base (String.concat ", " arguments)
  | base :: baked ->
    let literal text =
      let numeric =
        text <> ""
        && (let ok = ref true in
            String.iteri (fun index c ->
              if not ((c >= '0' && c <= '9') || (c = '-' && index = 0)) then ok := false) text;
            !ok)
      in
      if numeric then text else Printf.sprintf "%S" text
    in
    Printf.sprintf "%s(%s)" base
      (String.concat ", " (arguments @ List.map literal baked))

exception Unsupported of emit_error

let unsupported loc fmt =
  Printf.ksprintf (fun message -> raise (Unsupported { loc; message })) fmt

(* Emitted identifiers are the most visible surface of the "if Tesl does not work
   out you hold plain Go code" argument: a reviewer should read `Area(r)`, not
   `Tesl_area(tesl_r)`.  Names therefore keep their Tesl spelling and are only
   altered when they would collide with a Go keyword, a predeclared identifier, an
   imported package name, the emitter's own `tesl…` namespace, or another emitted
   name in the same package. *)
let go_keywords = [
  "break"; "case"; "chan"; "const"; "continue"; "default"; "defer"; "else";
  "fallthrough"; "for"; "func"; "go"; "goto"; "if"; "import"; "interface"; "map";
  "package"; "range"; "return"; "select"; "struct"; "switch"; "type"; "var";
]

let go_predeclared = [
  "any"; "bool"; "byte"; "comparable"; "complex64"; "complex128"; "error"; "float32";
  "float64"; "int"; "int8"; "int16"; "int32"; "int64"; "rune"; "string"; "uint";
  "uint8"; "uint16"; "uint32"; "uint64"; "uintptr"; "true"; "false"; "iota"; "nil";
  "append"; "cap"; "clear"; "close"; "complex"; "copy"; "delete"; "imag"; "len";
  "make"; "max"; "min"; "new"; "panic"; "print"; "println"; "real"; "recover";
]

(* Package names the emitted files import, plus the emitter's own namespace: every
   generated helper, temporary, and field the emitter introduces is spelled
   `tesl…`/`Tesl…`, so a Tesl name in that namespace is renamed rather than risking
   a silent capture. *)
let go_emitter_owned =
  ["fmt"; "os"; "strconv"; "testing"; "teslrt";
   (* The PostgreSQL driver's two packages: a row scanner names both, so a Tesl module called
      `Pgx` would otherwise capture one of them. *)
   "pgx"; "pgtype"]

let sanitize_chars name =
  let b = Buffer.create (String.length name) in
  String.iter (fun c ->
    let valid =
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
      || c = '_' || (c >= '0' && c <= '9')
    in
    if valid then Buffer.add_char b c
    else Buffer.add_string b (Printf.sprintf "_x%02x_" (Char.code c))) name;
  let value = Buffer.contents b in
  if value = "" then "tesl"
  else if value.[0] >= '0' && value.[0] <= '9' then "_" ^ value
  else value

let reserved_go_ident name =
  let lowered = String.lowercase_ascii name in
  List.mem lowered go_keywords
  || List.mem lowered go_predeclared
  || List.mem lowered go_emitter_owned
  || (String.length name >= 4 && String.sub lowered 0 4 = "tesl")

let go_ident ~exported name =
  let cleaned = sanitize_chars name in
  let cased =
    if exported then String.capitalize_ascii cleaned
    else String.uncapitalize_ascii cleaned
  in
  if reserved_go_ident cased then cased ^ "_" else cased

(** A local, parameter, or pattern binder. Tesl rejects shadowing a top-level name,
    so these cannot collide with an emitted package-level name. *)
let local_ident name = go_ident ~exported:false name

(* Package-level names are minted through one table so two Tesl names can never
   render to the same Go identifier. *)
(* `r.Width` rather than `(r).Width`: the parentheses are only needed when the object
   is a compound expression. *)
let selector_operand value =
  let simple =
    value <> ""
    && (let ok = ref true in
        String.iteri (fun index c ->
          let valid =
            (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
            || ((c >= '0' && c <= '9' || c = '.') && index > 0)
          in
          if not valid then ok := false) value;
        !ok)
  in
  if simple then value else "(" ^ value ^ ")"

let unique_ident taken candidate =
  let rec loop candidate =
    if Hashtbl.mem taken candidate then loop (candidate ^ "_")
    else begin Hashtbl.add taken candidate (); candidate end
  in
  loop candidate

let package_name name =
  let b = Buffer.create (String.length name) in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    then Buffer.add_char b (Char.lowercase_ascii c)) name;
  let value = Buffer.contents b in
  "teslmod" ^ value

(* JSON string/number rendering for an api-test body template.  Separate from `go_quote`,
   which escapes for GO source: here the escapes are JSON's, and the result is then quoted
   for Go as ordinary text. *)
let json_quote value =
  let b = Buffer.create (String.length value + 2) in
  Buffer.add_char b '"';
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c when Char.code c < 0x20 ->
      Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char b c) value;
  Buffer.add_char b '"';
  Buffer.contents b

(* JSON has no Inf/NaN, so a template carrying one is a compile error rather than invalid
   JSON on the wire. *)
let json_float value =
  if Float.is_nan value || Float.is_integer value = false && Float.is_finite value = false
  then invalid_arg "api-test body: JSON has no representation for NaN or Infinity"
  else if Float.is_integer value && Float.abs value < 1e15 then
    Printf.sprintf "%.1f" value
  else Printf.sprintf "%.17g" value

(* An api-test JSON TEMPLATE: `{ "k": v }` / `[ … ]` / a scalar written literally.  Answers the
   JSON text, or None when the expression is not a constant template.  Used both for a request
   BODY and for a comparison against a response — `expect resp.body == [ { "text": "a" } ]`
   compares against a template, since a JSON array of objects is not a Tesl value. *)
let rec literal_json expr =
    match expr with
    | ELit { lit = LString text; _ } -> Some (json_quote text)
    | ELit { lit = LInt n; _ } -> Some (string_of_int n)
    | ELit { lit = LBigInt text; _ } -> Some text
    | ELit { lit = LBool b; _ } -> Some (if b then "true" else "false")
    | ELit { lit = LFloat f; _ } -> Some (json_float f)
    (* A NEGATIVE number in a template is a unary minus over a literal, not a literal — JSON
       has no such distinction, so `{ "value": -5 }` renders as the number it reads as.  Only
       a literal operand qualifies: anything else is a computation, and a template is a
       constant. *)
    | EUnop { op = UNeg; arg; _ } ->
      (match arg with
       | ELit { lit = (LInt _ | LBigInt _ | LFloat _); _ } ->
         Option.map (fun text -> "-" ^ text) (literal_json arg)
       | _ -> None)
    | EConstructor { name = "True"; args = []; _ } -> Some "true"
    | EConstructor { name = "False"; args = []; _ } -> Some "false"
    | EList { elems; _ } ->
      let rendered = List.map literal_json elems in
      if List.for_all Option.is_some rendered then
        Some ("[" ^ String.concat "," (List.map Option.get rendered) ^ "]")
      else None
    | ERecord { fields; _ } ->
      let rendered = List.map (fun (key, field_value) ->
        Option.map (fun text -> json_quote key ^ ":" ^ text) (literal_json field_value))
        fields in
      if List.for_all Option.is_some rendered then
        Some ("{" ^ String.concat "," (List.map Option.get rendered) ^ "}")
      else None
    | _ -> None

(* The comparison half of the template rule: only a CONTAINER literal is a template, since a
   scalar one is an ordinary Tesl value and compares as one.  A request BODY still renders any
   literal, scalar included — there the whole body IS the JSON text being sent. *)
let template_json expr =
  match expr with
  | EList _ | ERecord _ -> literal_json expr
  | _ -> None

let go_quote value =
  let b = Buffer.create (String.length value + 2) in
  Buffer.add_char b '"';
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c when Char.code c < 0x20 || Char.code c >= 0x7f ->
      Buffer.add_string b (Printf.sprintf "\\x%02x" (Char.code c))
    | c -> Buffer.add_char b c) value;
  Buffer.add_char b '"';
  Buffer.contents b

(* A DECLARATION-config scalar, as the desugar leaves it: either a literal, or one of the
   three environment reads rendered into an intermediate spelling (`env("SMTP_HOST")`).  The
   read has to survive to run time — a deployment sets those variables, and a value baked in
   at compile time would be the build machine's — so it becomes the runtime call.

   An `env` with nothing set answers "", which is the same absent-is-empty rule
   `tesl/private/runtime.rkt` applies (`empty-string->false`, then `(or … "")` at the use). *)
let go_config_value loc value =
  let unquote s =
    let n = String.length s in
    if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2) else s
  in
  let prefixed prefix =
    String.length value > String.length prefix
    && String.sub value 0 (String.length prefix) = prefix
    && value.[String.length value - 1] = ')'
  in
  let inner prefix =
    String.sub value (String.length prefix)
      (String.length value - String.length prefix - 1)
  in
  if prefixed "env(" then
    Printf.sprintf "teslrt.EnvString(%s, \"\")" (go_quote (unquote (inner "env(")))
  else if prefixed "envString(" then
    (match String.index_opt (inner "envString(") ',' with
     | Some comma ->
       let raw = inner "envString(" in
       let name = unquote (String.trim (String.sub raw 0 comma)) in
       let fallback =
         unquote (String.trim (String.sub raw (comma + 1) (String.length raw - comma - 1)))
       in
       Printf.sprintf "teslrt.EnvString(%s, %s)" (go_quote name) (go_quote fallback)
     | None -> Printf.sprintf "teslrt.EnvString(%s, \"\")" (go_quote (inner "envString(")))
  (* An INTEGER read in a string-valued config field: the desugar only produces this
     spelling for a numeric field, so reaching it here means the field was misread. *)
  else if prefixed "envInt(" then
    unsupported loc "Go backend cannot read `%s` as a text configuration value" value
  else go_quote value

(* The same, for a NUMERIC configuration field (a port).  `envInt` carries its own fallback,
   which is what makes an unset variable a documented default rather than a zero. *)
let go_config_int loc value =
  let prefixed prefix =
    String.length value > String.length prefix
    && String.sub value 0 (String.length prefix) = prefix
    && value.[String.length value - 1] = ')'
  in
  let inner prefix =
    String.sub value (String.length prefix)
      (String.length value - String.length prefix - 1)
  in
  let unquote s =
    let n = String.length s in
    if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2) else s
  in
  if prefixed "envInt(" then
    (match String.index_opt (inner "envInt(") ',' with
     | Some comma ->
       let raw = inner "envInt(" in
       let name = unquote (String.trim (String.sub raw 0 comma)) in
       let fallback = String.trim (String.sub raw (comma + 1) (String.length raw - comma - 1)) in
       Printf.sprintf "teslrt.PgPort(%s, %s)" (go_quote name) fallback
     | None -> unsupported loc "Go backend cannot read `%s` as a numeric configuration value"
                 value)
  else
    match int_of_string_opt value with
    | Some number -> string_of_int number
    | None -> unsupported loc
      "Go backend cannot read `%s` as a numeric configuration value" value

let directive_file file =
  let file = if file = "" then "generated.tesl" else Filename.basename file in
  String.map (function '\n' | '\r' -> '_' | c -> c) file

let line_directive loc =
  let line = max 1 (loc.Location.start.line + 1) in
  Printf.sprintf "//line %s:%d\n" (directive_file loc.Location.file) line

let primitive_type_of_type_expr = function
  | TName { name = "Int"; _ } -> TInt
  | TName { name = "Float"; _ } -> TFloat
  | TName { name = "String"; _ } -> TString
  | TName { name = "Bool"; _ } -> TBool
  | TName { name = "Unit"; _ } -> TUnit
  | TName { name; loc } ->
    unsupported loc "Go backend newtype base `%s` is not a direct scalar type" name
  | TVar { name; loc } -> unsupported loc "Go backend does not support type variable `%s` yet" name
  | TApp { loc; _ } -> unsupported loc "Go backend does not support applied types yet"
  | TFun { loc; _ } -> unsupported loc "Go backend does not support function values yet"
  | TTuple { loc; _ } -> unsupported loc "Go backend does not support tuple types yet"

(* An `entity` is a record PLUS a store.  The row type is an ordinary struct — that is
   what a query returns and what `insert` takes — and the store is one package-level
   table variable, since an entity belongs to exactly one database.  Both live here so a
   query can find the table from the entity name alone. *)
type entity_info = {
  ent_tesl_name : string;
  ent_row : record_info;
  (* The package-level `var XTable = teslrt.NewTable[X]()`, qualified by its owner when
     referenced from another package. *)
  ent_table_var : string;
  ent_owner : string;
  ent_primary_key : string;
  (* The SQL table the entity names (`entity Note table "notes"`), and any `@db(type)` a field
     overrides its column type with.  The COLUMNS themselves are derived from the row's fields
     (`entity_columns`), which are not resolved until every type in the module is. *)
  ent_table_name : string;
  ent_db_types : (string * string) list;
  (* The declared indexes.  A plain one is a performance hint with no observable effect; a
     UNIQUE one is an invariant both stores enforce, so it reaches the emitted code. *)
  ent_indexes : entity_index list;
  (* The Postgres-backed database that manages this entity, if one does.  `None` covers both
     "declared in a Memory database" and "declared in none": either way the rows live in the
     table variable and nothing else, which is the emission that has always been produced. *)
  ent_database : database_info option;
  (* Whether some `database` block NAMES this entity.  It decides ONE thing: whether a test
     block starts from an empty table.  Racket clears the stores of REGISTERED databases —
     an entity in no `database` declaration is in none of them — so a file without a
     declaration shares one store across its test blocks, which is documented behaviour a
     corpus lesson relies on (`unique index [name]` refusing a second row inserted by a later
     block).  The Go side truncated every table unconditionally, so the same program's tests
     passed here and failed there; this flag is what makes the two agree.

     Mutable because a `database` block may name an entity DECLARED in another module, and
     the entity records are shared by reference across packages — the flag then travels with
     the entity rather than having to be recovered from the declaration. *)
  mutable ent_in_database : bool;
  ent_loc : Location.loc;
}

(* One column, as the SQL side sees it.  `col_name` is the snake_case column `dsl/sql.rkt`
   derives from the field key, which is what a table created by the Racket backend is already
   named by — deriving it differently here would make the two backends unable to share one. *)
and column_info = {
  col_field : string;
  col_name : string;
  col_sql_type : string;
  col_nullable : bool;
  col_primary_key : bool;
  (* The Go type the column reads back as, which decides both how a value is BOUND and how a
     row is SCANNED. *)
  col_type : go_type;
}

(* A statement under construction.  Arguments are appended in the order their placeholders are
   minted, which is the order the driver binds them. *)
and sql_arguments = { mutable sql_args : string list }

(* A `database D = Database { … }`, with what a connection to it needs. *)
and database_info = {
  db_tesl_name : string;
  db_backend : string;              (* "memory" | "postgres" *)
  db_schema : string;
  db_entities : string list;
  db_config : (string * string) list;
  (* The package-level `var DDatabase = &teslrt.Database{…}`; "" for a Memory database, which
     has no emitted form. *)
  db_go_var : string;
  db_owner : string;
  db_loc : Location.loc;
}

(* A `queue` is a job STORE plus the wiring from job type to worker.  Like an entity's
   table it is one package-level variable; unlike one, it also carries the dispatch a
   test's `processNextJob` needs, which is why the worker names live here. *)
type queue_info = {
  qu_tesl_name : string;
  qu_go_var : string;
  qu_owner : string;
  (* Every (job type, worker, dead-letter worker) the declaration wires up, in declaration
     order.  A queue may carry SEVERAL job types — the store holds a payload as `any` and the
     emitter passes a dispatcher that type-switches, which is what queue.go was written
     for. *)
  qu_jobs : (string * string * string option) list;
  (* The FIRST wiring, which is what the single-payload surfaces use: an api-test's
     `processNextJob` answers a `JobResult` of ONE job type, and no reading of a multi-type
     queue gives it two. *)
  qu_job_type : string;            (* the job record's Tesl name *)
  qu_worker : string;              (* the worker function's Tesl name *)
  qu_dead_worker : string option;
  qu_max_attempts : int;
  qu_loc : Location.loc;
}

(* A `cache C = Cache { … }` is one package-level store plus the type of what it holds.
   The DATABASE it names is inert here for the same reason a `database` declaration is: the
   Racket cache reads its own in-memory hash until something binds a PostgreSQL runtime, and
   nothing does that without `with database`. *)
type cache_info = {
  ca_tesl_name : string;
  ca_go_var : string;
  ca_owner : string;
  ca_value : go_type;
  (* `defaultTtl:` in seconds, or 0 when the declaration omits one — baked in for the reason
     a queue's `maxAttempts` is: the expiry rule belongs to the declaration, and a `Cache.set`
     with no TTL of its own is exactly the call that asks for it. *)
  ca_default_ttl : int;
  ca_loc : Location.loc;
}

(* An `email E = Email { … }` is one package-level OUTBOX plus the SMTP settings to deliver
   from it.  The settings are strings the DECLARATION fixed — a literal, or an `env "…"` read
   that happens at start-up — so they are baked into the store's initialiser exactly as a
   queue's `maxAttempts` is.

   The database it names is inert here for the reason a cache's is: the Racket runtime keeps
   its outbox in memory until something binds a PostgreSQL runtime, and nothing does that
   without `with database`. *)
type email_info = {
  em_tesl_name : string;
  em_go_var : string;
  em_owner : string;
  (* Already rendered as Go expressions, since a config value may be an `env` read. *)
  em_host : string;
  em_port : int;
  em_username : string;
  em_password : string;
  em_tls : bool;
  em_loc : Location.loc;
}

(* An `sseChannel C(key: String) = SseChannel { … }` is one package-level channel: the
   listeners currently registered, keyed by the channel KEY.  The key is what makes a channel
   per-entity — `RunEvents(runId)` reaches the subscribers of that run and no others — and a
   channel declared with no key parameter is the broadcast case of the same rule.

   The DATABASE it names is inert here for the reason a cache's is: the Racket channel keeps its
   listeners in memory, and the PostgreSQL fan-out only exists to reach OTHER processes. *)
type channel_info = {
  ch_tesl_name : string;
  ch_go_var : string;
  ch_owner : string;
  ch_payload : go_type;
  (* The declaration's key parameters.  Zero or one today; more would need a composite key,
     which the surface has no syntax for. *)
  ch_key_params : int;
  ch_loc : Location.loc;
}

(** Named nominal types the emitter can resolve: scalar newtypes and records. *)
type type_table = {
  newtypes : (string, newtype_info) Hashtbl.t;
  records : (string, record_info) Hashtbl.t;
  adts : (string, adt_info) Hashtbl.t;
  entities : (string, entity_info) Hashtbl.t;
  (* Keyed by the QUEUE's name and again by its job type: `enqueue` names the job type,
     while an api-test verb names the queue. *)
  queues : (string, queue_info) Hashtbl.t;
  (* Declared caches, by name — the four `Cache.*` leaves all name one. *)
  caches : (string, cache_info) Hashtbl.t;
  (* Declared emails, by name — `Email.send E { … }` and `startEmailWorker E` both name one. *)
  emails : (string, email_info) Hashtbl.t;
  (* Declared SSE channels, by name — `publish C(key) …` and an `sse` route both name one. *)
  channels : (string, channel_info) Hashtbl.t;
  (* Types with a hand-written `codec` block, and the PACKAGE whose file emits it.  A codec
     is emitted once, by the module that declares it, so a reference from another package has
     to be qualified — and a type with no entry here has no hand-written codec, which is what
     says the decoder is derived locally instead. *)
  codecs : (string, string) Hashtbl.t;
  (* Module-level constants: a NAME and its Go spelling, referenced bare rather than called.
     They live here rather than in `signatures` because a signature describes something that is
     APPLIED, and a const that resolved through that table would be indistinguishable from a
     nullary function — whose bare mention is a partial application the emitter refuses. *)
  consts : (string, go_type * string) Hashtbl.t;
  (* A `database` declaration by NAME.  A Memory-backed one has no emitted form at all — a
     Racket `define-database` is inert until something CONNECTS to it, and the store a Memory
     database names IS the entity's table variable.  A Postgres-backed one becomes a
     package-level `teslrt.Database` holding what a connection needs, because there the
     declaration decides a real server, a real schema and a real set of tables. *)
  databases : (string, database_info) Hashtbl.t;
  (* Type names that stand for another type OUTRIGHT, with no wrapper of their own: a
     dimensioned quantity is a Float (the dimension lives in the compiler's type layer and
     erases there), and `MoneyPerDuration` is the runtime's one rate type under a name that
     says which denominator it carries.  Consulted before the nominal tables, so an alias
     never needs a Go declaration of its own. *)
  aliases : (string, go_type) Hashtbl.t;
}

(* The table for the module being emitted.  A ref for the same reason `current_package`
   is one: the type family threads `signatures` only, and a lambda's PARAMETER
   ANNOTATION has to be resolvable where a fold's accumulator type is settled — that is
   the only thing that determines the type of `List.foldl (fn(acc: List Int, …) -> …) []
   xs`, the idiomatic list-rebuilding fold.  Set once per module beside
   `current_package`. *)
let current_types : type_table option ref = ref None

(* Module functions whose body performs a PROOF OPERATION (`detachFact` and friends), by
   name.  Those operations erase here, so nothing in them can fail at run time — which
   matters for exactly one shape: a test asserting that calling such a function FAILS, as
   Racket's runtime does when a value carries more than one proof.  Populated per module,
   read where that assertion is emitted. *)
let proof_op_functions : (string, string) Hashtbl.t = Hashtbl.create 8

(* The module's own function declarations, by name.  `asTool fn` derives a tool's JSON
   schema and its argument decode from the fn's PARAMETER LIST — the names as well as the
   types — and the signature table carries only types.  Populated per module beside
   `proof_op_functions`, for the same reason: the declaration is what the emitter needs and
   the expression walker has only a name. *)
let current_functions : (string, func_decl) Hashtbl.t = Hashtbl.create 16

(* The type parameters a GENERIC function declares, by function name: the Tesl type variable
   paired with the Go type-parameter name it renders as.  `fn isEmpty(xs: List a) -> Bool`
   becomes `func IsEmpty[A any](xs []A) bool`, and the variables are collected from the
   declaration in order of first appearance so the Go parameter list is deterministic.

   Kept beside the signature rather than in it because a signature is built at 23 sites and
   only a module's own `fn` declarations can be generic — everything else registers a
   monomorphic row.  Populated per module, like `current_functions`. *)
let current_type_params : (string, (string * string) list) Hashtbl.t = Hashtbl.create 16

(* The type variables a declaration mentions, in order of first appearance, paired with the
   Go type-parameter name each renders as: `A`, `B`, … by position.  Positional rather than
   derived from the Tesl name, because two variables spelled `a` and `acc` would otherwise
   both want `A`, and a type parameter that collides is not a type parameter. *)
let rec return_spec_type_exprs = function
  | RetPlain { ty; _ } | RetNamedPack { ty; _ } -> [ty]
  | RetAttached { binding; _ } -> [binding.type_expr]
  | RetForAll { elem_ty; _ } | RetMaybeForAll { elem_ty; _ }
  | RetSetForAll { elem_ty; _ } | RetMaybeSetForAll { elem_ty; _ } -> [elem_ty]
  | RetMaybeAttached { outer_ty = Some outer; binding; _ } -> [outer; binding.type_expr]
  | RetMaybeAttached { binding; _ } -> [binding.type_expr]
  | RetForAllDictValues { key_ty; val_ty; _ } | RetForAllDictKeys { key_ty; val_ty; _ } ->
    [key_ty; val_ty]
  | RetExists { body; _ } -> return_spec_type_exprs body

let type_variables_of ?(subjects=[]) type_exprs =
  let seen = ref [] in
  let rec walk ty =
    match ty with
    (* A lowercase name inside a PROOF is a value — `Fact (AlwaysValid33 n)` names the
       parameter `n`, not a type — and a proof erases here, so nothing under it is a type at
       all.  `subjects` catches the same thing from the other side: a name that is one of the
       function's own parameters is a value wherever it appears. *)
    | TVar { name; _ } ->
      if not (List.mem name !seen || List.mem name subjects) then seen := !seen @ [name]
    | TApp { head = TName { name = "Fact"; _ }; _ } -> ()
    | TApp { head; arg; _ } -> walk head; walk arg
    | TFun { dom; cod; _ } -> walk dom; walk cod
    | TTuple { elems; _ } -> List.iter walk elems
    | TName _ -> ()
  in
  List.iter walk type_exprs;
  List.mapi (fun index name ->
    (name, String.make 1 (Char.chr (Char.code 'A' + index)))) !seen

(* The module's `capturer` declarations.  A path capture may name one instead of writing
   its codec and check inline, and an endpoint offered as a TOOL has to run the same check
   the HTTP path does — so the declaration has to be reachable from the expression emitter,
   not just from the server emission that already has the list in hand. *)
let current_capturers : capture_form list ref = ref []

(* Record name → each field's PROOF PREDICATE, where it has one.  A property generator for
   such a record cannot draw from the whole range: `Int ::: IsPositive n` would hand the
   property a value its own annotation says is impossible.  The record table carries only
   "some field has a proof"; the predicate NAME is what says which draw to use, and it lives
   in the declaration. *)
let current_field_proofs : (string, (string * string) list) Hashtbl.t = Hashtbl.create 8

(* Record name → the check its RECORD-LEVEL invariant names.  A generated value has to
   satisfy it, and no fieldwise draw can guarantee a relation BETWEEN fields, so the
   generator redraws until the check accepts — rejection sampling, the same 100 attempts
   Racket allows before it skips the iteration. *)
let current_record_invariants : (string, string * string list) Hashtbl.t = Hashtbl.create 8

(* `serverTools S user` and `humanActions S user`: which of the server's endpoints each CALL
   SITE gets.  The decision is the CHECKER's and is per site — an endpoint is included only
   where the user value's declared proof covers its auth predicates, so the same server
   yields different tool sets to an admin and to a plain user — and the two sets partition
   the server's endpoints.  Keyed by the call site's line and column, the way the Racket
   backend reads the same metadata. *)
let server_tools_sites : (int * int, string * string list) Hashtbl.t = Hashtbl.create 8
let human_actions_sites : (int * int, string * string list) Hashtbl.t = Hashtbl.create 8

(* Every non-SSE endpoint of every server declared in this module, in handler order: the
   tool name (the bound handler), its description, its derived JSON schema, and the endpoint
   itself.  Both call forms read this and filter it by the site tables above. *)
let server_tools_endpoints
  : (string, (string * string * string * api_endpoint) list) Hashtbl.t = Hashtbl.create 4

(* A cache by NAME.  Every `Cache.*` operation names a declared cache, and the declaration is
   where the value type and the store live. *)
let cache_of_name loc name =
  match Option.bind !current_types (fun types -> Hashtbl.find_opt types.caches name) with
  | Some info -> info
  | None -> unsupported loc "Go backend cannot resolve cache `%s`" name

(* A channel by NAME.  `publish` and an `sse` route both name a declared one, and the
   declaration is where the listener registry and the payload type live. *)
let channel_of_name loc name =
  match Option.bind !current_types (fun types -> Hashtbl.find_opt types.channels name) with
  | Some info -> info
  | None -> unsupported loc "Go backend cannot resolve sse channel `%s`" name

(* An email by NAME.  `Email.send` and `startEmailWorker` both name a declared one, and the
   declaration is where the outbox and the SMTP settings live. *)
let email_of_name loc name =
  match Option.bind !current_types (fun types -> Hashtbl.find_opt types.emails name) with
  | Some info -> info
  | None -> unsupported loc "Go backend cannot resolve email `%s`" name

(* `with database D { … }` is the only place a database DECLARATION becomes observable: it
   binds the store the body's queries run against.  On the Memory backend that store IS the
   entity's table variable, so the block adds nothing at run time and the body is emitted as
   it stands.  A Postgres-backed database is a different store, and emitting the body
   unchanged would read the in-memory table while the same program on Racket reads the
   server — the two backends would then disagree about what a query ANSWERS, which is worse
   than not compiling.  So it is refused, and the whole corpus is unaffected: every
   `with database` in it names a Memory-backed database.
   Only databases declared in the module being emitted are known here; one reached across a
   module boundary is not, and it is also not something the corpus does. *)
let database_of_name database_name =
  Option.bind !current_types (fun types -> Hashtbl.find_opt types.databases database_name)

(* The Postgres-backed database `with database D` binds, if it is one.  A Memory-backed D
   answers None, and the body is emitted exactly as it always was. *)
let postgres_database loc database_name =
  match database_of_name database_name with
  | Some info when info.db_backend = "postgres" ->
    if info.db_go_var = "" then unsupported loc
      "Go backend cannot reach Postgres-backed database `%s` from this module" database_name;
    Some info
  | _ -> None

(* `transaction { … }` groups statements that must commit together.  With nothing connected it
   adds NOTHING at run time — Racket's `call-with-queue-transaction` is `(thunk)` unless a
   PostgreSQL connection is active — and against a connected server it is a real BEGIN/COMMIT
   on the connection the block itself opens.

   WHICH server that is, is decided at run time rather than here: Racket keeps ONE
   `current-database-runtime`, so a `transaction` opens one on whatever `with database` has
   bound, and the emitted form says exactly that (`teslrt.WithTransaction`).  A module with two
   database declarations therefore needs no disambiguation, because only one of them can be
   bound when the block is entered. *)
let module_has_postgres_database () =
  match !current_types with
  | None -> false
  | Some types ->
    Hashtbl.fold (fun _ (info : database_info) found -> found || info.db_backend = "postgres")
      types.databases false

(* The server an `api-test` block drives, while its statements are being emitted.  A
   request verb (`get "/path"`) only means something inside such a block, and this is what
   tells the emitter which server it addresses. *)
let current_api_server : string option ref = ref None

(* Where the api-test response record lives in the record table.  It shares the Tesl name
   `HttpResponse` with `Tesl.HttpClient`'s outbound response — the checker has one opaque
   type for both, since field access on either is untyped — but the two have different
   RUNTIME shapes, and a module may import both.  So the api-test shape is keyed by a string
   no Tesl type name can spell, and the plain name is left for the outbound one, which is the
   only one an annotation can mention. *)
(* The go.sum for the ONE dependency emitted code can take: `golang.org/x/crypto/argon2`, for
   password storage (see `password.go`).  Pinned here rather than fetched, so an emitted project
   builds without a network round trip deciding what it got, and checked against
   `runtime/go/go.sum` by a seam test so the two cannot drift. *)
let password_dependency_go_sum =
  "golang.org/x/crypto v0.55.0 h1:+KWHjbgOaAQ66dh/YlkZKHlz9ZUlq61AFirAR9ntP8M=\n\
   golang.org/x/crypto v0.55.0/go.mod h1:uq0V9dE/fzQuJtbnL+2EhWOE63vo164FY8xqEnV9xis=\n\
   golang.org/x/sys v0.47.0 h1:o7XGOvZQCADBQQ4Y7VNq2dRWQR7JmOUW8Kxx4ZsNgWs=\n\
   golang.org/x/sys v0.47.0/go.mod h1:4GL1E5IUh+htKOUEOaiffhrAeqysfVGipDYzABqnCmw=\n"

(* The pinned PostgreSQL driver, for a program that declares a Postgres-backed database.  Same
   discipline as `password_dependency_go_sum`: written here rather than fetched, so an emitted
   project builds without a network round trip deciding what it got. *)
let postgres_dependency_go_mod =
  "\nrequire github.com/jackc/pgx/v5 v5.10.0\n\n\
   require (\n\
   \tgithub.com/jackc/pgpassfile v1.0.0 // indirect\n\
   \tgithub.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect\n\
   \tgithub.com/jackc/puddle/v2 v2.2.2 // indirect\n\
   \tgolang.org/x/sync v0.22.0 // indirect\n\
   \tgolang.org/x/text v0.41.0 // indirect\n\
   )\n"

let postgres_dependency_go_sum =
  "github.com/jackc/pgpassfile v1.0.0 h1:/6Hmqy13Ss2zCq62VdNG8tM1wchn8zjSGOBJ6icpsIM=\n\
   github.com/jackc/pgpassfile v1.0.0/go.mod h1:CEx0iS5ambNFdcRtxPj5JhEz+xB6uRky5eyVu/W2HEg=\n\
   github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 h1:iCEnooe7UlwOQYpKFhBabPMi4aNAfoODPEFNiAnClxo=\n\
   github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761/go.mod h1:5TJZWKEWniPve33vlWYSoGYefn3gLQRzjfDlhSJ9ZKM=\n\
   github.com/jackc/pgx/v5 v5.10.0 h1:VhSvgU2jSli8o3AqIEOTJr7rZwAEUVo4E4XhR94Zfr0=\n\
   github.com/jackc/pgx/v5 v5.10.0/go.mod h1:mal1tBGAFfLHvZzaYh77YS/eC6IX9OWbRV1QIIM0Jn4=\n\
   github.com/jackc/puddle/v2 v2.2.2 h1:PR8nw+E/1w0GLuRFSmiioY6UooMp6KJv0/61nB7icHo=\n\
   github.com/jackc/puddle/v2 v2.2.2/go.mod h1:vriiEXHvEE654aYKXXjOvZM39qJ0q+azkZFrfEOc3H4=\n\
   golang.org/x/sync v0.22.0 h1:SZjpbeLmrCk4xhRSZFNZW5gFUeCeFgjekvI/+gfScek=\n\
   golang.org/x/sync v0.22.0/go.mod h1:9xrNwdLfx4jkKbNva9FpL6vEN7evnE43NNNJQ2LF3+0=\n\
   golang.org/x/text v0.41.0 h1:vz/seA0lnX87Othu2f/0L24RcgrXD9/YFTSuGjj3rH8=\n\
   golang.org/x/text v0.41.0/go.mod h1:jvf1O8ajNzZqhSrQBPbutR/EB83Cc0CFrezNQIwbb5M=\n"

let api_response_key = "HttpResponse (api-test)"

(* The JSON encoder for a value of a given type, as a Go function NAME.  A forward reference
   because the encoder machinery is defined with the codecs, far below the expression emitter —
   and one expression needs it: `publish`, whose payload crosses the wire as JSON exactly as a
   response body does.  Assigned once, where `value_encoder` is defined. *)
let value_encoder_hook : (go_type -> string) ref =
  ref (fun _ -> invalid_arg "value encoder used before the codec layer was ready")

(* Tesl type names that have their OWN codec in the module being emitted.  A value with a
   codec encodes through it; anything else falls back to the generic wire shape below. *)
let current_codec_types : string list ref = ref []

(* Codec entry points are EXPORTED: they are the boundary API — the server layer calls
   them, and a user who ejects Tesl calls them directly.  They would also read as unused
   in a module that only declares codecs, which the `unused` linter rightly rejects. *)
let codec_encode_name type_name = "Encode" ^ go_ident ~exported:true type_name ^ "JSON"

(* A codec REFERENCE, as opposed to its definition: the codec lives in the package that
   declared it, so a use from another package carries that package's prefix.  A type with no
   hand-written codec answers its bare name — that decoder is derived into the using package,
   which is where the reference is. *)
let codec_owner name =
  match !current_types with
  | Some types -> Hashtbl.find_opt types.codecs name
  | None -> None
let codec_decode_name type_name = "Decode" ^ go_ident ~exported:true type_name ^ "JSON"

let codec_encode_ref type_name =
  match codec_owner type_name with
  | Some owner -> qualified owner (codec_encode_name type_name)
  | None -> codec_encode_name type_name

let codec_decode_ref type_name =
  match codec_owner type_name with
  | Some owner -> qualified owner (codec_decode_name type_name)
  | None -> codec_decode_name type_name

(* Defined here rather than beside the codec EMITTER below because `decodeAs` needs the
   reference: a model's structured output decodes through the very same codec an HTTP
   request body does, and that expression is emitted long before the codec layer. *)

(* True while emitting somewhere that HAS a request scope in hand: a function that declares a
   cookie-writing capability, or a handler adapter.  A test body has none — Racket agrees, since
   a test has no HTTP response to attach a cookie to — so a call there passes `nil`, and the
   runtime's own "no HTTP response to attach a cookie to" trap is what a test writing a cookie
   gets.  Without this, an emitted test that called a scope-taking function referenced a
   `teslScope` that does not exist there. *)
let current_scope_in_hand = ref false

(* True while a HANDLER's body is being emitted.  A check rejection consumed there must
   ANSWER the client with its own status rather than trap: `dsl/web.rkt` installs the
   raise-on-escaping-failure wrapper for every function kind except `handler`, so a
   rejection reached in a handler body is the response on the Racket side too.  Set around
   the body, since the consumption site is where the choice is made. *)
let current_handler_body = ref false

(* Set when an empty list literal fell back to its DEFAULT element type because nothing
   constrained it.  The tolerance paths (an `if` branch, a `case` arm, a sibling element)
   consult this so a defaulted type never outranks a real one: `if c then [] else ["a"]`
   must be `List String`, not a type error. *)
let used_empty_default = ref false

(* Types [expr], reporting whether the result relied on the empty-list default. *)
(* `add 1` where `add` takes two arguments is a function of the remaining one.  Go has no
   partial application, so the emitter goes through a runtime combinator that supplies the
   leading arguments and closes over the rest.  The family stops at three parameters because
   that is what the surface reaches for; anything wider is refused rather than guessed at. *)
(* Read a generic call's TYPE ARGUMENTS off the types it is applied to: `boxMap33 f box`
   with `f : Int -> String` and `box : Box33 Int` binds A to Int and B to String.

   Collection only — the FIRST binding for a parameter wins, and nothing is verified here.
   Verification is the caller's, and it does it the honest way: substitute the bindings into
   each declared parameter and check the argument against THAT, so a second occurrence that
   disagrees is an ordinary argument-type mismatch rather than a special rule. *)
let rec collect_type_arguments bindings want got =
  match want, got with
  | TParam name, actual ->
    if not (List.mem_assoc name !bindings) then bindings := (name, actual) :: !bindings
  | TList want_inner, TList got_inner
  | TSet want_inner, TSet got_inner
  | TCheck want_inner, TCheck got_inner -> collect_type_arguments bindings want_inner got_inner
  | TDict (want_key, want_value), TDict (got_key, got_value) ->
    collect_type_arguments bindings want_key got_key;
    collect_type_arguments bindings want_value got_value
  | TAdt (want_info, want_args), TAdt (got_info, got_args)
    when want_info.adt_go_name = got_info.adt_go_name
         && List.length want_args = List.length got_args ->
    List.iter2 (collect_type_arguments bindings) want_args got_args
  | TFunc (want_params, want_result), TFunc (got_params, got_result)
    when List.length want_params = List.length got_params ->
    List.iter2 (collect_type_arguments bindings) want_params got_params;
    collect_type_arguments bindings want_result got_result
  | _ -> ()

let partial_application_combinator ~supplied ~total =
  match supplied, total with
  | 1, 2 -> Some "teslrt.Apply1Of2"
  | 1, 3 -> Some "teslrt.Apply1Of3"
  | 2, 3 -> Some "teslrt.Apply2Of3"
  | _ -> None

let typed_with_default type_of expr =
  let saved = !used_empty_default in
  used_empty_default := false;
  let result = try Some (type_of expr) with Unsupported _ -> None in
  let defaulted = !used_empty_default in
  used_empty_default := saved;
  result, defaulted

(* What a compiled module offers its importers: the very tables it emitted from.  A
   dependent reuses these exact info records rather than re-deriving them, so the two
   cannot disagree about a type's Go name, its fields, or its identity — `go_type`
   equality is structural, and two separately-derived records would compare unequal even
   when they describe the same Tesl type. *)
type module_exports = {
  ex_module : string;
  ex_package : string;
  ex_types : type_table;
  ex_signatures : (string, signature) Hashtbl.t;
}

(* Whether a compiled dependency is the module an import names.

   A LIFTED stdlib module is the one case where the two spellings differ: it is imported by
   its full dotted name (`import Tesl.CivilTime`) and DECLARES itself by the trailing segment
   (`module CivilTime`), which is also how every call site spells it
   (`CivilTime.fromParts`).  So they match on that segment — and only under the `Tesl.`
   prefix, so no local module can be picked up by a partial name. *)
let dependency_named (dependency : module_exports) import_name =
  dependency.ex_module = import_name
  || (String.length import_name > 5 && String.sub import_name 0 5 = "Tesl."
      && dependency.ex_module = String.sub import_name 5 (String.length import_name - 5)
      && not (String.contains dependency.ex_module '.'))

let rec flatten_type_app args = function
  | TApp { head; arg; _ } -> flatten_type_app (arg :: args) head
  | head -> head, args

(** [params] is the type-parameter scope: non-empty only while resolving the field
    types of a generic ADT's own variants. Everywhere else a type variable has no
    Go rendering and is rejected. *)
let rec type_of_type_expr ?(params=[]) types ty =
  let recur = type_of_type_expr ~params types in
  match ty with
  (* An ALIAS resolves first: it is not a type of its own, so nothing downstream should see
     the name. *)
  | TName { name; _ } when Hashtbl.mem types.aliases name -> Hashtbl.find types.aliases name
  | TName { name = "Int"; _ } -> TInt
  | TName { name = "Float"; _ } -> TFloat
  | TName { name = "String"; _ } -> TString
  | TName { name = "Bool"; _ } -> TBool
  | TName { name = "Unit"; _ } -> TUnit
  | TName { name; loc } ->
    (* A type may be written QUALIFIED (`Sandbox3.S3Record2`), which is how a module
       imported without an `exposing` list is referred to.  The tables are keyed by the
       bare Tesl name — the qualification says which module it came from, and the checker
       has already verified that it is in scope — so the prefix is dropped here. *)
    let name = match String.rindex_opt name '.' with
      | Some index
        when not (Hashtbl.mem types.newtypes name || Hashtbl.mem types.records name
                  || Hashtbl.mem types.adts name) ->
        String.sub name (index + 1) (String.length name - index - 1)
      | _ -> name
    in
    (match Hashtbl.find_opt types.newtypes name, Hashtbl.find_opt types.records name,
           Hashtbl.find_opt types.adts name with
     | Some info, _, _ -> TNewtype info
     | None, Some info, _ -> TRecord info
     | None, None, Some info ->
       if info.adt_params <> [] then unsupported loc
         "Go backend requires `%s` to be applied to %d type argument(s)"
         name (List.length info.adt_params);
       TAdt (info, [])
     | None, None, None -> unsupported loc "Go backend does not support type `%s` yet" name)
  | TVar { name; loc } ->
    (match List.assoc_opt name params with
     | Some go_name -> TParam go_name
     | None -> unsupported loc "Go backend does not support type variable `%s` yet" name)
  | TApp { loc; _ } ->
    let head, args = flatten_type_app [] ty in
    (match head with
     | TName { name = "List"; _ } ->
       (match args with
        | [element] -> TList (recur element)
        | _ -> unsupported loc "Go backend requires `List` to be applied to 1 type argument")
     | TName { name = "Dict"; _ } ->
       (match args with
        | [key; value] -> TDict (recur key, recur value)
        | _ -> unsupported loc "Go backend requires `Dict` to be applied to 2 type arguments")
     | TName { name = "Set"; _ } ->
       (match args with
        | [element] -> TSet (recur element)
        | _ -> unsupported loc "Go backend requires `Set` to be applied to 1 type argument")
     | TName { name; _ } ->
       (match Hashtbl.find_opt types.adts name with
        | Some info ->
          if List.length args <> List.length info.adt_params then unsupported loc
            "Go backend requires `%s` to be applied to %d type argument(s)"
            name (List.length info.adt_params);
          TAdt (info, List.map recur args)
        | None ->
          (* `Fact P` is a DETACHED PROOF: a first-class witness produced by `establish`
             and consumed by `attachFact`.  It erases like every other proof — the runtime
             comment in dsl/private/check-runtime.rkt states the rule outright ("the proof
             is asserted without re-checking — correctness is guaranteed by the
             compile-time type system"), and LANGUAGE-SPEC 16.9 gives a proof no runtime
             structure.  So it becomes a zero-size value that carries nothing. *)
          if name = "Fact" then TUnit
          else unsupported loc "Go backend does not support applied type `%s` yet" name)
     | _ -> unsupported loc "Go backend does not support applied types yet")
  (* `a -> b` is a FUNCTION VALUE.  The arrow's capability row is compile-time — the checker
     propagates it to callers and it has no runtime form — so only the domain and codomain
     survive.  A curried arrow (`a -> b -> c`) flattens into ONE Go signature, which is the
     shape the call sites emit. *)
  | TFun { dom; cod; _ } ->
    let rec flatten acc = function
      | TFun { dom; cod; _ } -> flatten (recur dom :: acc) cod
      | result -> List.rev acc, recur result
    in
    let params, result = flatten [recur dom] cod in
    TFunc (params, result)
  | TTuple { loc; _ } -> unsupported loc "Go backend does not support tuple types yet"

let rec type_of_return_spec ?(params=[]) types = function
  | RetPlain { ty; _ } -> type_of_type_expr ~params types ty
  | RetAttached { binding; _ } -> TCheck (type_of_type_expr ~params types binding.type_expr)
  (* `List T ::: ForAll P` is a TYPE-LEVEL contract with zero runtime structure
     (LANGUAGE-SPEC 16.9: "at runtime, the list is a plain list with no per-element
     proof structs"), so it erases to the list itself.  The frontend has already
     discharged the proof; nothing is erased that was not checked. *)
  | RetForAll { elem_ty; _ } -> TList (type_of_type_expr ~params types elem_ty)
  | RetMaybeForAll { elem_ty; loc; _ } ->
    (match Hashtbl.find_opt types.adts "Maybe" with
     | Some info -> TAdt (info, [TList (type_of_type_expr ~params types elem_ty)])
     | None -> unsupported loc
       "Go backend needs `Tesl.Maybe` imported for a `Maybe (List … ::: ForAll …)` return")
  (* `-> T ? P` is a proof-carrying return.  A proof has no runtime structure in Go — the
     frontend has already discharged it, exactly as for `ForAll` above — so it erases to
     the value's own type.  Racket does keep a wrapper (`attach-proof-to`), but every read
     there goes through `raw-value`, so the wrapper is an implementation detail of that
     backend rather than part of the value.
     The parser puts the FIRST `? P` in `entity_proof` whether or not it is a provenance
     proof, so that field cannot tell the two apart here.  It does not need to: a `FromDb`
     provenance proof erases by the same rule as every other proof — it records WHERE a
     value came from for the checker, and the checker has already used it.  (This used to
     be justified by "entities are refused before this point", which stopped being true
     when the DB slice landed; the rule above is the real reason.) *)
  | RetNamedPack { ty; _ } -> type_of_type_expr ~params types ty
  (* Every remaining proof-bearing return is the same erasure applied to a different
     container: the proof is a TYPE-LEVEL contract with no runtime structure, so what comes
     back is the Maybe, the Set or the Dict itself. *)
  (* `-> Wrapper (T ? P)`.  The proof erases, so the result is the WRAPPER applied to the
     value's own type — and the wrapper is not always `Maybe`: `Either String (Int ?
     IsPositive)` is the same shape with another, and reading it as a Maybe answered a type
     the function does not return. *)
  | RetMaybeAttached { outer_ty = Some outer; _ } -> type_of_type_expr ~params types outer
  | RetMaybeAttached { binding; loc; _ } ->
    (match Hashtbl.find_opt types.adts "Maybe" with
     | Some info -> TAdt (info, [type_of_type_expr ~params types binding.type_expr])
     | None -> unsupported loc
       "Go backend needs `Tesl.Maybe` imported for a `Maybe (… ::: …)` return")
  | RetSetForAll { elem_ty; _ } -> TSet (type_of_type_expr ~params types elem_ty)
  | RetMaybeSetForAll { elem_ty; loc; _ } ->
    (match Hashtbl.find_opt types.adts "Maybe" with
     | Some info -> TAdt (info, [TSet (type_of_type_expr ~params types elem_ty)])
     | None -> unsupported loc
       "Go backend needs `Tesl.Maybe` imported for a `Maybe (Set … ::: ForAll …)` return")
  | RetForAllDictValues { key_ty; val_ty; _ }
  | RetForAllDictKeys { key_ty; val_ty; _ } ->
    TDict (type_of_type_expr ~params types key_ty, type_of_type_expr ~params types val_ty)
  (* An EXISTENTIAL return (`-> exists taskId: String => Task ? FromDb (Id == taskId)`) hides
     the witness from the caller's proof context.  The witness is a proof SUBJECT, not a
     value the caller receives — the body still returns the same value it would without the
     `exists` — so the type is the inner spec's and the quantifier erases.  Soundness here is
     the CHECKER's: it is what refuses to let a packed witness be forwarded where the fact
     does not hold (issue #73), and it runs before this point. *)
  | RetExists { body; _ } -> type_of_return_spec ~params types body

let rec go_type = function
  | TInt -> "teslrt.Int"
  | TFloat -> "float64"
  | TString -> "string"
  | TBool -> "bool"
  | TUnit -> "struct{}"
  | TNewtype info -> qualified info.owner info.go_name
  | TRecord info -> qualified info.rec_owner info.rec_go_name
  | TAdt (info, []) -> qualified info.adt_owner info.adt_go_name
  | TAdt (info, args) ->
    Printf.sprintf "%s[%s]" (qualified info.adt_owner info.adt_go_name)
      (String.concat ", " (List.map go_type args))
  | TList element -> "[]" ^ go_type element
  | TDict (key, value) ->
    Printf.sprintf "teslrt.Dict[%s, %s]" (go_type key) (go_type value)
  | TSet element -> Printf.sprintf "teslrt.Set[%s]" (go_type element)
  | TParam name -> name
  | TFunc (params, result) ->
    (* `func(A, B) R`.  A Unit result is written as the empty struct like any other value,
       so a function value and a named function agree on shape. *)
    Printf.sprintf "func(%s) %s"
      (String.concat ", " (List.map go_type params)) (go_type result)
  | TQuantity -> "float64"
  | TJson -> "teslrt.JsonValue"
  | TStream -> "*teslrt.SseTestStream"
  | TCheck ty -> Printf.sprintf "teslrt.Check[%s]" (go_type ty)
  (* An unconstrained type argument has no values, so the empty struct is as good a
     witness as any — and the smallest. *)
  | TAnon -> "struct{}"
  | TFailure -> invalid_arg "Go failure has no standalone type"

(* A conjunction (or disjunction) of ONE is that one comparison: wrapping it in parentheses
   is what gofmt then takes back off, and an emitted file gofmt would rewrite is a gate
   failure rather than a style opinion. *)
let joined_comparison separator = function
  | [only] -> only
  | parts -> "(" ^ String.concat separator parts ^ ")"

(* Type equality that TERMINATES on a RECURSIVE ADT.  `=` cannot: a recursive type's
   `adt_info` contains field types that point back at it, and OCaml's structural equality
   walks a cycle forever (it must honour NaN, so it cannot take the physical-equality
   shortcut `compare` takes).  Two ADTs are the same type when they are the same
   DECLARATION — the emitter shares one `adt_info` per declaration, and the Go name is that
   record's identity — applied to the same arguments. *)
let rec type_equal left right =
  match left, right with
  (* An unconstrained type argument is compatible with whatever settles it: it has no
     values, so no comparison between the two can ever be observed. *)
  | TAnon, _ | _, TAnon -> true
  | TAdt (left_info, left_args), TAdt (right_info, right_args) ->
    left_info.adt_go_name = right_info.adt_go_name
    && left_info.adt_owner = right_info.adt_owner
    && List.length left_args = List.length right_args
    && List.for_all2 type_equal left_args right_args
  | TRecord left_info, TRecord right_info ->
    left_info.rec_go_name = right_info.rec_go_name
    && left_info.rec_owner = right_info.rec_owner
  | TNewtype left_info, TNewtype right_info ->
    left_info.go_name = right_info.go_name && left_info.owner = right_info.owner
  | TList left, TList right | TSet left, TSet right | TCheck left, TCheck right ->
    type_equal left right
  | TDict (left_key, left_value), TDict (right_key, right_value) ->
    type_equal left_key right_key && type_equal left_value right_value
  | TFunc (left_params, left_result), TFunc (right_params, right_result) ->
    List.length left_params = List.length right_params
    && List.for_all2 type_equal left_params right_params
    && type_equal left_result right_result
  | TParam left, TParam right -> left = right
  | TInt, TInt | TFloat, TFloat | TString, TString | TBool, TBool | TUnit, TUnit
  | TQuantity, TQuantity | TJson, TJson | TStream, TStream | TFailure, TFailure -> true
  (* A QUANTITY and a Float are the same Go type, and the checker has already decided which
     dimensions a program's arithmetic produces — a dimensionless ratio IS a Float there. So
     they are interchangeable where a type is CHECKED; they stay distinct where one is
     INFERRED, which is what keeps `rate * quantity` and `rate * scalar` different
     operations. *)
  | TQuantity, TFloat | TFloat, TQuantity -> true
  | _ -> false

let type_unequal left right = not (type_equal left right)

(* How to compare an OPAQUE runtime record — one this backend sees no fields of.  Walking
   its zero visible fields would answer `true` for ANY two of them, which is not "equal" but
   "nothing was compared", so a record that is not on this list is REFUSED rather than
   answered.  (That refusal found a real one: `zone a == zone b` inside `Tesl.CivilTime` was
   a tautology, and two dates read in different calendars passed for the same one.)

   `Value` means Go's own `==` says what "the same" means.  A `Func` names a runtime
   comparison, which is what a record holding a `teslrt.Int` needs: an Int holds a `*big.Int`
   and is deliberately not comparable — it carries a `[0]func()` so Go says so. *)
type runtime_equality = EqualByValue | EqualByFunc of string

let runtime_record_equality go_name =
  match go_name with
  (* A name, an offset and a flag: two of them are the same zone exactly when those agree. *)
  | "teslrt.TimeZone" -> Some EqualByValue
  (* A URL's port is an Int, so its parts are compared by the runtime. *)
  | "teslrt.Url" -> Some (EqualByFunc "teslrt.UrlEqual")
  | _ -> None

let comparable_runtime_record go_name = runtime_record_equality go_name <> None


(* Whether a type still has an ANONYMOUS argument in it — one no value has settled. *)
let rec has_anon ty =
  match ty with
  | TAnon -> true
  | TAdt (_, args) -> List.exists has_anon args
  | TList inner | TSet inner | TCheck inner -> has_anon inner
  | TDict (key, value) -> has_anon key || has_anon value
  | TFunc (params, result) -> List.exists has_anon params || has_anon result
  | TInt | TFloat | TQuantity | TString | TBool | TUnit | TNewtype _ | TRecord _
  | TJson | TStream | TParam _ | TFailure -> false

(* Two readings of the SAME value, combined so that each keeps what the other does not know:
   `[Left "e", Right 1]` types its first element `Either String ?` and its second
   `Either ? Int`, and the list's element type is `Either String Int` — the one type both
   elements can actually have.  Only an anonymous side ever gives way; a genuine
   disagreement is left as it is, for the caller's own comparison to reject. *)
let rec merge_anon left right =
  match left, right with
  | TAnon, other | other, TAnon -> other
  | TAdt (info, left_args), TAdt (_, right_args)
    when List.length left_args = List.length right_args ->
    TAdt (info, List.map2 merge_anon left_args right_args)
  | TList left_inner, TList right_inner -> TList (merge_anon left_inner right_inner)
  | TSet left_inner, TSet right_inner -> TSet (merge_anon left_inner right_inner)
  | TCheck left_inner, TCheck right_inner -> TCheck (merge_anon left_inner right_inner)
  | TDict (left_key, left_value), TDict (right_key, right_value) ->
    TDict (merge_anon left_key right_key, merge_anon left_value right_value)
  | settled, _ -> settled

let record_field_go_name name = go_ident ~exported:true name

(* `!(!(x))` is a staticcheck finding (SA4013) on emitted code, so negation
   cancels an existing top-level `!(...)` instead of stacking on it.  The scan
   skips Go string literals, where a parenthesis is data rather than structure. *)
let paren_wraps_whole value from =
  let length = String.length value in
  let rec scan index depth in_string escaped =
    if index >= length then false
    else
      let c = value.[index] in
      if in_string then
        if escaped then scan (index + 1) depth true false
        else if c = '\\' then scan (index + 1) depth true true
        else if c = '"' then scan (index + 1) depth false false
        else scan (index + 1) depth true false
      else match c with
        | '"' -> scan (index + 1) depth true false
        | '(' -> scan (index + 1) (depth + 1) false false
        | ')' ->
          if depth = 1 then index = length - 1 else scan (index + 1) (depth - 1) false false
        | _ -> scan (index + 1) depth false false
  in
  from + 1 < length && value.[from] = '(' && scan from 0 false false

(* A float literal is never emitted bare.  Go folds UNTYPED constant arithmetic
   EXACTLY — `0.1 + 0.2` becomes 0.3, where Racket gives 0.30000000000000004 — so every
   literal is emitted as a typed float64 value and each operation rounds per-op, as it
   must.  Two further reasons a bare literal will not do: Go constants have no negative
   zero, and a typed constant that overflows is a COMPILE error where Racket yields
   ±inf.0. *)
let emit_float_literal value =
  if Float.is_nan value then "math.NaN()"
  else if Float.is_integer value && Float.abs value = Float.infinity then
    if value > 0.0 then "math.Inf(1)" else "math.Inf(-1)"
  else if value = 0.0 && 1.0 /. value < 0.0 then "math.Copysign(0, -1)"
  else
    (* Shortest decimal that round-trips: Go parses decimal exactly, and `%h` (hex
       float) would round-trip too but reads as `0x1p+1` in code a human is supposed to
       own after ejecting. *)
    let shortest =
      let rec attempt = function
        | [] -> Printf.sprintf "%.17g" value
        | digits :: rest ->
          let text = Printf.sprintf "%.*g" digits value in
          if float_of_string text = value then text else attempt rest
      in
      attempt [1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11; 12; 13; 14; 15; 16; 17]
    in
    Printf.sprintf "float64(%s)" shortest

let negate_bool value =
  let length = String.length value in
  if length > 3 && value.[0] = '!' && paren_wraps_whole value 1 then
    String.sub value 2 (length - 3)
  else if paren_wraps_whole value 0 then "!" ^ value
  else Printf.sprintf "!(%s)" value

(* Only strips a parenthesis pair that wraps the WHOLE expression, so `(a) && (b)`
   survives intact. *)
let strip_outer_parens value =
  if paren_wraps_whole value 0 then String.sub value 1 (String.length value - 2)
  else value

(* Records hold teslrt.Int values, which are non-comparable by construction, so
   Go `==` on a record struct is a compile error rather than a wrong answer.
   Record equality is therefore always emitted field by field. *)
(* The tag is EXPORTED: an ADT provided by the runtime — or, later, by another emitted
   module — is matched from a different package, where an unexported field would be
   invisible. *)
let adt_tag_field = "Tag"

(* Every variant's payload lives in one flat struct, so a payload field is named
   after its constructor: `Pending (reason: String)` becomes `PendingReason`. *)
(* A RECURSIVE payload field — `Add left: Expr right: Expr` inside `Expr` — cannot be held
   by value: a Go struct containing itself has no finite size.  Such a field is declared as a
   POINTER, filled through `teslrt.Boxed` at construction and read through `teslrt.Unboxed`
   everywhere else, so the indirection lives in two named calls rather than in the shape of
   every emitted expression.
   Only a DIRECT self-reference needs it.  `children: List Expr` does not — a slice is
   already a reference — and neither does a Dict or Set of them.  A self-reference nested
   inside another VALUE type (`inner: Maybe Expr`) would, and is refused instead: boxing it
   would need the indirection inside the other type's own layout. *)
let adt_self_field (info : adt_info) field_ty =
  match field_ty with
  (* A field of the declaration's OWN type is boxed, at whatever instantiation it names.
     `Node left: (Tree Int)` inside `Tree a` is the one Tesl actually writes and it is just as
     infinite BY VALUE as `Tree a` would be — a `Tree[int]` holding a `Tree[int]` has no
     size — so it needs the same pointer.  Go itself accepts the declaration once the field
     is a pointer: an instantiation cycle is only rejected when the type ARGUMENT grows
     (`T[*A]` inside `T[A]`), and a constant one does not. *)
  | TAdt (other, _) -> other.adt_go_name = info.adt_go_name
  | _ -> false

(* Whether a variant's payload field is boxed, asked by NAME.  A value site sees the field
   type with the ADT's type arguments SUBSTITUTED IN (`MyTree Int` rather than `MyTree a`),
   and that substituted type no longer looks like the declaration's own instantiation — so
   the question has to be asked of the DECLARED field, which is where the pointer was
   decided. *)
let adt_self_payload (info : adt_info) variant field_name =
  match List.assoc_opt field_name variant.var_fields with
  | Some declared_ty -> adt_self_field info declared_ty
  | None -> false

let variant_field_go_name variant name =
  match List.assoc_opt name variant.var_go_fields with
  | Some go_name -> go_name
  | None -> go_ident ~exported:true variant.var_ctor ^ go_ident ~exported:true name

(* A single-variant ADT has nothing to discriminate: it needs no tag field, matching
   binds its payload directly, and equality is field-wise like a record's. *)
let single_variant info =
  match info.adt_variants with
  | [variant] -> Some variant
  | _ -> None

let find_variant info ctor =
  List.find_opt (fun variant -> variant.var_ctor = ctor) info.adt_variants

let rec substitute_type bindings ty =
  match ty with
  | TParam name -> (match List.assoc_opt name bindings with Some ty -> ty | None -> ty)
  | TAdt (info, args) -> TAdt (info, List.map (substitute_type bindings) args)
  | TCheck inner -> TCheck (substitute_type bindings inner)
  | TList element -> TList (substitute_type bindings element)
  | TDict (key, value) -> TDict (substitute_type bindings key, substitute_type bindings value)
  | TSet element -> TSet (substitute_type bindings element)
  | TFunc (params, result) ->
    TFunc (List.map (substitute_type bindings) params, substitute_type bindings result)
  | TJson | TStream | TQuantity -> ty
  | TInt | TFloat | TString | TBool | TUnit | TNewtype _ | TRecord _ | TFailure | TAnon -> ty

(** A variant's payload types with the ADT's type arguments substituted in. *)
(* The parameter types a call to [name] is checked and emitted against.  For an ordinary
   function they are the declared ones; for a GENERIC function they are the declared ones
   with its type parameters filled in from the arguments, which is what lets a lambda
   argument be emitted as `func(teslrt.Int) string` rather than as `func(A) B`. *)
let instantiated_call_types type_of_argument loc name (signature : signature) args =
  match Hashtbl.find_opt current_type_params name with
  | None | Some [] -> signature.params, signature.result
  | Some declared ->
    if List.length args <> List.length signature.params then
      unsupported loc "Go backend requires a fully-applied call to the generic function `%s`"
        name;
    let bindings = ref [] in
    List.iter2 (fun arg want ->
      collect_type_arguments bindings want (type_of_argument arg)) args signature.params;
    List.iter (fun (tesl, go) ->
      if not (List.mem_assoc go !bindings) then unsupported loc
        "Go backend cannot infer the type argument `%s` of `%s` from its arguments" tesl name)
      declared;
    (List.map (substitute_type !bindings) signature.params,
     substitute_type !bindings signature.result)

let variant_field_types info args variant =
  if info.adt_params = [] || args = [] then variant.var_fields
  else
    let bindings = List.map2 (fun (_, go_param) arg -> go_param, arg) info.adt_params args in
    List.map (fun (name, ty) -> name, substitute_type bindings ty) variant.var_fields

(* Comparator helpers hoisted to package level, keyed by their generated name so the
   same comparator is defined once per file.  Reset and flushed by whichever file is being
   emitted; the tests file is in the same package but gets its own copies, because a
   helper defined in module.go and used only from the test would read as unused there. *)
let pending_helpers : (string, string) Hashtbl.t = Hashtbl.create 16

(* Helpers that cannot be named after a type (a `sortBy` key lambda is per-call-site) are
   named by their own SOURCE: every function body is emitted twice — once assuming it
   loops, then flat if no self tail call materialised — so a counter minted a fresh name
   per pass and left unreferenced helpers behind, which the `unused` linter rightly
   rejected.  Keying by source makes the second pass reuse the first pass's name. *)
let helper_names : (string, string) Hashtbl.t = Hashtbl.create 16

(* Helper names module.go already declared.  module_test.go is in the SAME package, so a
   second copy there is a redeclaration; it references these instead. *)
let module_helpers : (string, unit) Hashtbl.t = Hashtbl.create 16

(* [signature] is everything after the name — `(teslX, teslY string) bool` — and [body] is
   the returned expression.  The two together are the identity of the helper. *)
(* Like `remember_helper` but for a body that is a STATEMENT sequence rather than one
   expression — a combined check has to inspect the first result before running the next. *)
let remember_helper_stmts ~prefix ~signature ~body =
  let key = prefix ^ "\x00" ^ signature ^ "\x00" ^ body in
  match Hashtbl.find_opt helper_names key with
  | Some name -> name
  | None ->
    let name = Printf.sprintf "%s%d" prefix (Hashtbl.length helper_names + 1) in
    Hashtbl.replace helper_names key name;
    Hashtbl.replace pending_helpers name
      (Printf.sprintf "\nfunc %s%s {\n%s}\n" name signature body);
    name

let remember_helper ~prefix ~signature ~body =
  let key = prefix ^ "\x00" ^ signature ^ "\x00" ^ body in
  match Hashtbl.find_opt helper_names key with
  | Some name -> name
  | None ->
    let name = Printf.sprintf "%s%d" prefix (Hashtbl.length helper_names + 1) in
    Hashtbl.replace helper_names key name;
    Hashtbl.replace pending_helpers name
      (Printf.sprintf "\nfunc %s%s {\n\treturn %s\n}\n" name signature body);
    name

(* The helper's name must be INJECTIVE over Go types: stripping punctuation alone made
   `[]teslrt.Int` and `teslrt.Int` collide on `TeslrtInt`, so a `List (List Int)`
   comparison silently reused the `Int` comparator and Go rejected the call.  The
   structural markers are spelled out before the punctuation is dropped. *)
let helper_suffix ty =
  let text = go_type ty in
  let text =
    let buffer = Buffer.create (String.length text + 8) in
    let length = String.length text in
    let index = ref 0 in
    while !index < length do
      (* A marker is followed by a separator so the next segment capitalises: the name is
         read by whoever ejects, and `SliceOfTeslrtInt` beats `SliceOfteslrtInt`. *)
      if !index + 1 < length && text.[!index] = '[' && text.[!index + 1] = ']' then begin
        Buffer.add_string buffer "SliceOf."; index := !index + 2
      end else if !index + 3 < length && String.sub text !index 4 = "map[" then begin
        Buffer.add_string buffer "MapOf."; index := !index + 4
      end else begin
        Buffer.add_char buffer text.[!index]; incr index
      end
    done;
    Buffer.contents buffer
  in
  let buffer = Buffer.create (String.length text) in
  let capitalize = ref true in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') then begin
      Buffer.add_char buffer (if !capitalize then Char.uppercase_ascii c else c);
      capitalize := false
    end else capitalize := true) text;
  Buffer.contents buffer

(* Every comparator is hoisted into a named package-level function rather than passed as
   an inline func literal.  An inline literal reads well, but go/printer keeps one on a
   single line only while it judges the body "small enough", and that threshold is not
   something the emitter can predict: a comparator over a nested collection crosses it, and
   so does a plain two-field tuple comparison once the type names are long.  Each time, gofmt
   reformats the emitted file — which the gate treats as an emitter bug, correctly.  Hoisting
   is deterministic at every size and depth, costs one named function per element type, and
   reads at least as well in code someone owns after ejecting. *)
let comparator kind ty body =
  let name = Printf.sprintf "tesl%s%s" kind (helper_suffix ty) in
  if not (Hashtbl.mem pending_helpers name) then
    Hashtbl.replace pending_helpers name
      (Printf.sprintf "\nfunc %s(teslX, teslY %s) bool {\n\treturn %s\n}\n"
         name (go_type ty) body);
  name

let rec element_equal_func element =
  comparator "Equal" element (equal_expr element "teslX" "teslY")

and element_less_func element =
  comparator "Less" element (ordered_expr element "<" "teslX" "teslY")

(* The ordering Dict and Set use for KEYS, which is NOT the user-visible ordering.  Both
   are sorted, so their binary search reads key equivalence off the comparator — "neither
   side is less" means "same key" — and that equivalence must match the equality the
   language uses, or lookup itself is wrong.  For Float the two orderings genuinely
   differ: IEEE makes every NaN comparison false (so a NaN key matches whatever the search
   probes first) and treats -0.0 and +0.0 as equal (while `FloatEqual` distinguishes
   them).  `List.sort` and user comparisons keep plain IEEE. *)
and element_key_less_func element =
  comparator "KeyLess" element (ordered_key_expr element "teslX" "teslY")

and ordered_key_expr ty left right =
  match ty with
  | TFloat | TQuantity -> Printf.sprintf "teslrt.FloatKeyLess(%s, %s)" left right
  (* A Float-backed newtype inherits the key comparator, so it must be unwrapped here
     rather than delegated to `ordered_expr`. *)
  | TNewtype info ->
    ordered_key_expr info.base (Printf.sprintf "%s.Value" (selector_operand left))
      (Printf.sprintf "%s.Value" (selector_operand right))
  | _ -> ordered_expr ty "<" left right

and equal_expr ty left right =
  match ty with
  | TInt -> Printf.sprintf "teslrt.Equal(%s, %s)" left right
  (* Float equality is Racket `equal?`, not IEEE `==`: NaN equals NaN and 0.0 does not
     equal -0.0.  Both are inverted from Go's `==`, so `==` is never emitted. *)
  | TFloat | TQuantity -> Printf.sprintf "teslrt.FloatEqual(%s, %s)" left right
  (* A Bool compared with a LITERAL is the value itself, or its negation: `p.Archived ==
     false` is a staticcheck finding (S1002), and a lint finding on emitted code is an
     emitter bug rather than something to suppress.  Written this way the emitted predicate
     also reads the way a Go author would have written it. *)
  | TBool when right = "true" -> left
  | TBool when left = "true" -> right
  | TBool when right = "false" -> "!" ^ selector_operand left
  | TBool when left = "false" -> "!" ^ selector_operand right
  | TString | TBool | TUnit | TAnon -> Printf.sprintf "(%s == %s)" left right
  (* A SECRET compares in CONSTANT TIME: comparing its payload with `==` would leak a prefix
     through how long the comparison took, which is the classic way a token check betrays the
     token.  Racket's `secret-constant-time-equal?` says the same thing. *)
  | TNewtype info when info.secret ->
    Printf.sprintf "teslrt.SecretEqual(%s.Value, %s.Value)"
      (selector_operand left) (selector_operand right)
  | TNewtype info ->
    equal_expr info.base (Printf.sprintf "%s.Value" (selector_operand left))
      (Printf.sprintf "%s.Value" (selector_operand right))
  | TRecord info ->
    (match info.rec_fields with
     (* An OPAQUE record is compared as a Go VALUE.  Walking its zero visible fields would
        answer `true` for any two of them — which is how `zone a == zone b` became a
        tautology and let two dates in different calendars pass for the same one. *)
     | [] when runtime_record_equality info.rec_go_name = Some EqualByValue ->
       Printf.sprintf "(%s == %s)" left right
     | [] when comparable_runtime_record info.rec_go_name ->
       (match runtime_record_equality info.rec_go_name with
        | Some (EqualByFunc go) -> Printf.sprintf "%s(%s, %s)" go left right
        | _ -> invalid_arg "Go opaque-record equality validated before emission")
     | [] -> invalid_arg "Go equality on an opaque record is rejected before emission"
     | fields ->
       let parts = List.map (fun (name, field_ty) ->
         let field = record_field_go_name name in
         equal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
           (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
       joined_comparison " && " parts)
  | TAdt (info, args) when single_variant info <> None ->
    (match single_variant info with
     | Some variant ->
       (match variant_field_types info args variant with
        | [] -> "true"
        | fields ->
          let parts = List.map (fun (name, field_ty) ->
            let field = variant_field_go_name variant name in
            equal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
              (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
          joined_comparison " && " parts)
     | None -> assert false)
  (* A module-declared, non-generic ADT gets a generated `TeslEqual` method: it keeps
     the comparison site short.  A runtime-provided or generic one cannot — a method
     needs a type the module declares, and `teslrt.Maybe` is neither — so its payload
     comparison is inlined instead.  No tag SWITCH is needed for that: "same tag, and
     for each variant either the tag differs or the payload matches" says the same
     thing as a conjunction, which Go can express as an expression. *)
  | TAdt (info, _) when not info.adt_builtin && info.adt_params = [] ->
    Printf.sprintf "%s.TeslEqual(%s)" (selector_operand left) right
  | TAdt (info, args) ->
    let tag_equal =
      Printf.sprintf "%s.%s == %s.%s"
        (selector_operand left) adt_tag_field (selector_operand right) adt_tag_field
    in
    let payloads = List.filter_map (fun variant ->
      match variant_field_types info args variant with
      | [] -> None
      | fields ->
        let parts = List.map (fun (name, field_ty) ->
          let field = variant_field_go_name variant name in
          equal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
            (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
        Some (Printf.sprintf "(%s.%s != %s || %s)"
                (selector_operand left) adt_tag_field
                (qualified info.adt_owner variant.var_tag)
                (String.concat " && " parts))) info.adt_variants in
    "(" ^ String.concat " && " (tag_equal :: payloads) ^ ")"
  (* A generic Go function cannot compare a `T`, so the element comparison is passed
     in: the emitter knows the concrete element type at every call site. *)
  | TList element ->
    Printf.sprintf "teslrt.ListEqualBy(%s, %s, %s)" left right (element_equal_func element)
  (* Both dicts are stored in key order, so one pass compares them. *)
  | TDict (key, value) ->
    Printf.sprintf "teslrt.DictEqualBy(%s, %s, %s, %s)" left right
      (element_equal_func key) (element_equal_func value)
  | TSet element ->
    Printf.sprintf "teslrt.SetEqualBy(%s, %s, %s)" left right (element_equal_func element)
  | TFunc _ | TParam _ | TCheck _ | TFailure | TStream ->
    invalid_arg "Go equality on this type is rejected before emission"
  | TJson -> invalid_arg "Go api-test JSON equality goes through JsonEqual"

and unequal_expr ty left right =
  match ty with
  | TInt -> Printf.sprintf "!teslrt.Equal(%s, %s)" left right
  | TFloat | TQuantity -> Printf.sprintf "!teslrt.FloatEqual(%s, %s)" left right
  | TString | TBool | TUnit | TAnon -> Printf.sprintf "(%s != %s)" left right
  | TNewtype info when info.secret ->
    Printf.sprintf "!teslrt.SecretEqual(%s.Value, %s.Value)"
      (selector_operand left) (selector_operand right)
  | TNewtype info ->
    unequal_expr info.base (Printf.sprintf "%s.Value" (selector_operand left))
      (Printf.sprintf "%s.Value" (selector_operand right))
  | TRecord info ->
    (* De Morgan is applied here rather than negating the conjunction: emitted
       `!(a && b)` is a golangci-lint finding (staticcheck QF1001). *)
    (match info.rec_fields with
     | [] when runtime_record_equality info.rec_go_name = Some EqualByValue ->
       Printf.sprintf "(%s != %s)" left right
     | [] when comparable_runtime_record info.rec_go_name ->
       (match runtime_record_equality info.rec_go_name with
        | Some (EqualByFunc go) -> Printf.sprintf "!%s(%s, %s)" go left right
        | _ -> invalid_arg "Go opaque-record equality validated before emission")
     | [] -> invalid_arg "Go equality on an opaque record is rejected before emission"
     | fields ->
       let parts = List.map (fun (name, field_ty) ->
         let field = record_field_go_name name in
         unequal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
           (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
       joined_comparison " || " parts)
  | TAdt (info, args) when single_variant info <> None ->
    (match single_variant info with
     | Some variant ->
       (match variant_field_types info args variant with
        | [] -> "false"
        | fields ->
          let parts = List.map (fun (name, field_ty) ->
            let field = variant_field_go_name variant name in
            unequal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
              (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
          joined_comparison " || " parts)
     | None -> assert false)
  | TAdt (info, _) when not info.adt_builtin && info.adt_params = [] ->
    Printf.sprintf "!%s.TeslEqual(%s)" (selector_operand left) right
  (* De Morgan applied to the inlined runtime/generic ADT equality above, for the same
     reason records and single-variant ADTs get it: `negate_bool` would emit
     `!(a && b)`, which staticcheck rejects as QF1001, and a lint finding on emitted code
     is an emitter bug by contract.  "Same tag AND every variant's payload matches"
     negates to "tags differ OR some variant's tag is held and its payload differs". *)
  | TAdt (info, args) ->
    let tag_unequal =
      Printf.sprintf "%s.%s != %s.%s"
        (selector_operand left) adt_tag_field (selector_operand right) adt_tag_field
    in
    let payloads = List.filter_map (fun variant ->
      match variant_field_types info args variant with
      | [] -> None
      | fields ->
        let parts = List.map (fun (name, field_ty) ->
          let field = variant_field_go_name variant name in
          unequal_expr field_ty (Printf.sprintf "%s.%s" (selector_operand left) field)
            (Printf.sprintf "%s.%s" (selector_operand right) field)) fields in
        Some (Printf.sprintf "(%s.%s == %s && %s)"
                (selector_operand left) adt_tag_field
                (qualified info.adt_owner variant.var_tag)
                (String.concat " || " parts))) info.adt_variants in
    "(" ^ String.concat " || " (tag_unequal :: payloads) ^ ")"
  | TList element ->
    Printf.sprintf "!teslrt.ListEqualBy(%s, %s, %s)" left right (element_equal_func element)
  | TDict (key, value) ->
    Printf.sprintf "!teslrt.DictEqualBy(%s, %s, %s, %s)" left right
      (element_equal_func key) (element_equal_func value)
  | TSet element ->
    Printf.sprintf "!teslrt.SetEqualBy(%s, %s, %s)" left right (element_equal_func element)
  | TFunc _ | TParam _ | TCheck _ | TFailure | TStream ->
    invalid_arg "Go equality on this type is rejected before emission"
  | TJson -> invalid_arg "Go api-test JSON equality goes through JsonEqual"

and ordered_expr ty op left right =
  match ty with
  | TInt -> Printf.sprintf "(teslrt.Compare(%s, %s) %s 0)" left right op
  (* Ordering, unlike equality, IS plain IEEE in both backends. *)
  | TFloat | TQuantity | TString -> Printf.sprintf "(%s %s %s)" left op right
  (* A BOOL orders false before true — Racket sorts `#f` first, and a `order p.done asc`
     column is exactly the shape that asks. *)
  | TBool ->
    let rank value = Printf.sprintf "teslrt.BoolRank(%s)" value in
    Printf.sprintf "(%s %s %s)" (rank left) op (rank right)
  | TNewtype info ->
    ordered_expr info.base op (Printf.sprintf "%s.Value" (selector_operand left))
      (Printf.sprintf "%s.Value" (selector_operand right))
  | TUnit | TRecord _ | TAdt _ | TList _ | TDict _ | TSet _ | TParam _
  | TFunc _ | TJson | TStream | TCheck _ | TFailure | TAnon ->
    invalid_arg "Go ordering requires an ordered scalar type"

let rec supports_ordering = function
  | TInt | TFloat | TQuantity | TString -> true
  (* A secret must not be ORDERED: sorting or comparing them leaks their relative values,
     and there is no use for it. *)
  | TNewtype info -> (not info.secret) && supports_ordering info.base
  | TBool | TUnit | TRecord _ | TAdt _ | TList _ | TDict _ | TSet _ | TParam _
  | TFunc _ | TJson | TStream | TCheck _ | TFailure | TAnon -> false

(* Ordering INSIDE A QUERY admits one type the value language does not: a Bool.  PostgreSQL
   orders boolean columns (false before true) and `dsl/sql.rkt` reproduces that in its own
   comparison layer (`ordered-comparison-result`) — while Racket's value-level `<` refuses a
   boolean outright (`tesl-ord-operand` raises).  So the two are separate predicates here as
   well: `order t.done asc` sorts, and `List.sort` over a `List Bool` is still refused. *)
let rec supports_column_ordering = function
  | TBool -> true
  | TNewtype info -> (not info.secret) && supports_column_ordering info.base
  | other -> supports_ordering other

(* A generic ADT has no comparable Go form: `TeslEqual` would have to dispatch
   `teslrt.Equal` for whatever the type parameter was instantiated with, which Go
   generics cannot express without an interface the thin-runtime invariant forbids.
   Equality on such a type is therefore rejected before emission. *)
(* `seen` carries the ADTs already being answered for, so a RECURSIVE type terminates:
   `Expr` is comparable exactly when its non-recursive payloads are, and asking the same
   question about the same type again cannot change that answer. *)
let rec supports_equality_seen seen ty =
  let supports_equality ty = supports_equality_seen seen ty in
  match ty with
  | TInt | TFloat | TQuantity | TString | TBool | TUnit | TAnon -> true
  | TNewtype info -> supports_equality info.base
  (* NO fields here means OPAQUE, not empty: comparing zero fields would answer `true`,
     which is not "equal" but "nothing was compared". *)
  | TRecord { rec_fields = []; rec_go_name; _ } -> comparable_runtime_record rec_go_name
  | TRecord info -> List.for_all (fun (_, ty) -> supports_equality ty) info.rec_fields
  | TAdt (info, _) when List.mem info.adt_go_name seen -> true
  | TAdt (info, args) ->
    let seen = info.adt_go_name :: seen in
    let supports_equality ty = supports_equality_seen seen ty in
    (match single_variant info with
     (* A single-variant type compares field-wise, so it stays comparable even when
        generic: the emitter knows the instantiation at the comparison site. *)
     | Some variant ->
       List.for_all (fun (_, ty) -> supports_equality ty)
         (variant_field_types info args variant)
     | None ->
       (* A multi-variant type is comparable when every payload it could hold is —
          generic or not, since the instantiation is known at the comparison site. *)
       List.for_all (fun variant ->
         List.for_all (fun (_, ty) -> supports_equality ty)
           (variant_field_types info args variant)) info.adt_variants)
  | TList element -> supports_equality element
  | TDict (key, value) -> supports_equality key && supports_equality value
  | TSet element -> supports_equality element
  | TFunc _ | TJson | TStream | TParam _ | TCheck _ | TFailure -> false

let supports_equality ty = supports_equality_seen [] ty

let record_info_of_signature signatures name =
  match Hashtbl.find_opt signatures name with
  (* A record LITERAL is written with the TYPE's own name.  A capitalised function that
     merely ANSWERS a record — `FixedOffset 60` answers a `TimeZone` — parses as a
     constructor too, and reading it as a literal would demand `FixedOffset { … }` of a
     program that is already right. *)
  | Some { result = TRecord info; _ } when info.rec_tesl_name = name -> Some info
  | _ -> None

(* ─── SQL ──────────────────────────────────────────────────────────────────────
   A query is ordinary application syntax in the surface tree, so its structure is
   recovered by {!Sql_query} — the same module the Racket backend and the checker use.
   Nothing about the shape of a query is re-derived here; this only decides which Go
   the recovered structure renders to. *)
type sql_form =
  | SqlSelect of Sql_query.sql_select_seed * Sql_query.sql_clause list
  | SqlInsert of Sql_query.sql_insert
  | SqlInsertMany of string * string            (* list binding, entity *)
  | SqlUpsert of Sql_query.sql_upsert
  | SqlUpdate of Sql_query.sql_update
  | SqlDelete of Sql_query.sql_delete_seed * Sql_query.sql_clause list

(* The three surface shapes a query arrives in: a plain application, an application
   wrapped in the comparison that a `where` predicate parses as, and — for the
   multi-line forms — an underscore-`let` chain.  Tried in the same order as the Racket
   backend's guards, so the two agree on what a given tree means. *)
let recognise_sql expr =
  let first_of options = List.fold_left (fun found next ->
    match found with Some _ -> found | None -> next ()) None options in
  match expr with
  | EApp _ | EBinop _ ->
    first_of [
      (fun () -> Option.map (fun (seed, clauses) -> SqlSelect (seed, clauses))
        (Sql_query.extract_select_query expr));
      (fun () -> Option.map (fun insert -> SqlInsert insert)
        (Sql_query.parse_insert_expr expr));
      (fun () -> Option.map (fun (list_var, entity) -> SqlInsertMany (list_var, entity))
        (Sql_query.parse_insert_many_expr expr));
      (fun () -> Option.map (fun upsert -> SqlUpsert upsert)
        (Sql_query.parse_upsert_expr expr));
      (fun () -> Option.map (fun (seed, clauses) -> SqlDelete (seed, clauses))
        (Sql_query.extract_delete_query expr));
    ]
  | ELet _ ->
    first_of [
      (fun () -> Option.map (fun update -> SqlUpdate update) (Sql_query.extract_update expr));
      (fun () -> Option.map (fun (seed, clauses) -> SqlDelete (seed, clauses))
        (Sql_query.extract_delete expr));
      (fun () -> Option.map (fun (seed, clauses) -> SqlSelect (seed, clauses))
        (Sql_query.extract_multiline_select_query expr));
    ]
  | _ -> None

(* A query names its entity, and the entity carries both its row type and its store.
   `Tesl.Database`'s own names (`Database`, `Memory`) never reach here — a query's `from`
   is always a declared entity — so failing to find one is a compile error, not a
   fallback. *)
let entity_of_query loc name =
  match Option.bind !current_types (fun types -> Hashtbl.find_opt types.entities name) with
  | Some info -> info
  | None -> unsupported loc "Go backend cannot resolve entity `%s`" name

(* A queue is found by the JOB TYPE (`enqueue`) or by its own name (an api-test verb); the
   table holds both keys. *)
let queue_of_job_type loc name =
  match Option.bind !current_types (fun types -> Hashtbl.find_opt types.queues name) with
  | Some info -> info
  | None -> unsupported loc "Go backend cannot resolve a queue for `%s`" name

(* An api-test queue verb takes the QUEUE as its only argument, written as a bare name
   (`pendingJobCount SendQueue`), which parses as a constructor. *)
(* A variant may be applied with LABELLED fields — `Node { left: l, value: v, right: r }` —
   rather than positionally.  The declaration is what fixes the order, so the labels are
   resolved against it here, once, and both the type rule and the emitter see the positional
   list they already know how to handle.  A missing or unknown label is refused rather than
   filled in: a constructor with a field left out is not a value. *)
let variant_positional_args loc (variant : variant_info) args =
  match args with
  | [ERecord { fields; _ }] when variant.var_fields <> [] ->
    List.iter (fun (label, _) ->
      if not (List.mem_assoc label variant.var_fields) then
        unsupported loc "Go backend constructor `%s` has no field `%s`" variant.var_ctor label)
      fields;
    List.map (fun (name, _) ->
      match List.assoc_opt name fields with
      | Some value -> value
      | None -> unsupported loc
        "Go backend constructor `%s` is missing field `%s`" variant.var_ctor name)
      variant.var_fields
  | _ -> args

let queue_argument args =
  match args with
  | [EConstructor { name; args = []; _ }] | [EVar { name; _ }] -> Some name
  | _ -> None

let job_result_type signatures loc (info : queue_info) =
  let payload =
    match Option.bind !current_types
            (fun types -> Hashtbl.find_opt types.records info.qu_job_type) with
    | Some row -> TRecord row
    | None -> unsupported loc "Go backend cannot resolve job type `%s`" info.qu_job_type
  in
  match Hashtbl.find_opt signatures "JobOk" with
  | Some { result = TAdt (adt, _); _ } -> TAdt (adt, [payload])
  | _ -> unsupported loc
    "Go backend needs `JobResult` imported from `Tesl.ApiTest` for `processNextJob`"

(* The Go form of a combined check: one helper that runs the conjuncts in order, stops at the
   first rejection and passes each checked value to the next — Racket's `check-and`, minus the
   fact merging, which erases.  Minted once and shared by both positions a conjunction can be
   written in: applied to a value (`check (a && b) x`) and passed as a callback
   (`List.allCheck (a && b) xs`). *)
(* [conjuncts] is one entry per conjunct: its name and the Go TYPES of the arguments the
   program supplied to it — `checkAtLeast 0 && checkAtMost 100` captures one apiece.  Those
   become parameters of the helper rather than values baked into it: the helper is cached by
   its source, and a captured value is a run-time expression the call site owns. *)
let combined_check_helper signatures element conjuncts =
  let go_of name = match Hashtbl.find_opt signatures name with
    | Some (signature : signature) -> qualified signature.sig_owner signature.go_name
    | None -> invalid_arg "combined check validated before emission"
  in
  let checked = go_type element in
  let body = Buffer.create 256 in
  let captured = ref 0 in
  let parameters = ref [] in
  List.iteri (fun index (name, capture_types) ->
    let arguments = List.map (fun capture_type ->
      let parameter = Printf.sprintf "teslCapture%d" !captured in
      incr captured;
      parameters := (parameter, capture_type) :: !parameters;
      parameter) capture_types in
    let temporary = Printf.sprintf "teslStep%d" index in
    let subject =
      if index = 0 then "teslValue"
      else Printf.sprintf "teslrt.MustCheck(teslStep%d)" (index - 1) in
    Printf.bprintf body "\t%s := %s(%s)\n" temporary (go_of name)
      (String.concat ", " (arguments @ [subject]));
    if index < List.length conjuncts - 1 then
      Printf.bprintf body
        "\tif !%s.OK() {\n\t\treturn teslrt.Reject[%s](%s.Status(), %s.Message())\n\t}\n"
        temporary checked temporary temporary
    else
      Printf.bprintf body "\treturn %s\n" temporary) conjuncts;
  let signature_text =
    String.concat ", "
      (Printf.sprintf "teslValue %s" checked
       :: List.rev_map (fun (parameter, capture_type) ->
            Printf.sprintf "%s %s" parameter (go_type capture_type)) !parameters)
  in
  remember_helper_stmts ~prefix:"teslCheckAll"
    ~signature:(Printf.sprintf "(%s) teslrt.Check[%s]" signature_text checked)
    ~body:(Buffer.contents body)

(* `check (checkA && checkB) x` — a COMBINED check.  Racket's `check-and` runs the first,
   short-circuits on rejection, and passes the checked value to the next; the facts are
   merged into one conjunction.  Here the facts erase, so what is left is the sequencing. *)
let rec check_conjuncts expr =
  match expr with
  | EBinop { op = BAnd; left; right; _ } ->
    (match check_conjuncts left, check_conjuncts right with
     | Some left_names, Some right_names -> Some (left_names @ right_names)
     | _ -> None)
  | EVar { name; _ } -> Some [name]
  | _ -> None

(* The same conjunction, with each conjunct's SUPPLIED arguments kept: `checkAtLeast 0 &&
   checkAtMost 100` is two checks the program has partially applied, and the values it
   supplied belong to the call site rather than to the conjunction. *)
let rec check_conjunct_calls expr =
  match expr with
  | EBinop { op = BAnd; left; right; _ } ->
    (match check_conjunct_calls left, check_conjunct_calls right with
     | Some left_calls, Some right_calls -> Some (left_calls @ right_calls)
     | _ -> None)
  | EVar { name; _ } -> Some [name, []]
  | EApp _ ->
    (* Spelled out rather than through `flatten_app`, which is defined with the expression
       walkers below. *)
    let rec flatten supplied = function
      | EApp { fn; arg; _ } -> flatten (arg :: supplied) fn
      | head -> head, supplied
    in
    (match flatten [] expr with
     | EVar { name; _ }, (_ :: _ as supplied) -> Some [name, supplied]
     | _ -> None)
  | _ -> None

(* Does this expression READ the named binding?  Asked of a `set` value on a Postgres-backed
   entity, where the value becomes a bound parameter and so cannot mention the row. *)
let rec mentions_variable name expr =
  match expr with
  | EVar { name = other; _ } -> other = name
  | _ ->
    Ast_visitor.fold_children
      (fun found child -> found || mentions_variable name child) false expr

let entity_column loc (info : entity_info) field =
  match List.assoc_opt field info.ent_row.rec_fields with
  | Some ty -> ty
  | None -> unsupported loc "Go backend: entity `%s` has no column `%s`"
    info.ent_tesl_name field

(* ─── SQL schema ──────────────────────────────────────────────────────────────
   Everything a Postgres-backed entity needs to name itself in a statement.  The rules are
   `dsl/sql.rkt`'s rather than fresh ones: a table created by the Racket backend and read by
   this one is the whole point of having two, so a column name or a column TYPE that differed
   would make the two unable to share a database. *)

(* A field key becomes its column name the way `camel->snake` does it, acronyms included:
   `userID` is `user_id`, not `user_i_d`. *)
let camel_to_snake text =
  let buffer = Buffer.create (String.length text + 4) in
  let length = String.length text in
  String.iteri (fun index char ->
    let upper = char >= 'A' && char <= 'Z' in
    if upper && index > 0 then begin
      let previous = text.[index - 1] in
      let previous_lower =
        (previous >= 'a' && previous <= 'z') || (previous >= '0' && previous <= '9') in
      let previous_upper = previous >= 'A' && previous <= 'Z' in
      let next_lower =
        index + 1 < length && text.[index + 1] >= 'a' && text.[index + 1] <= 'z' in
      if previous_lower || (previous_upper && next_lower) then Buffer.add_char buffer '_'
    end;
    Buffer.add_char buffer (Char.lowercase_ascii char)) text;
  Buffer.contents buffer

(* An identifier is quoted with its embedded quotes doubled, which is a quoted SQL identifier's
   only escape.  Identifiers here come from the PROGRAM — an entity's declared table, a field's
   key — never from a request, and quoting is what keeps that true if one ever does. *)
let sql_ident name =
  "\"" ^ String.concat "\"\"" (String.split_on_char '"' name) ^ "\""

(* PostgreSQL truncates an identifier at 63 BYTES and only emits a NOTICE, so two derived names
   sharing a 63-byte prefix would collide and `if not exists` would then match the WRONG index.
   `dsl/sql.rkt` truncates deterministically with an FNV-1a-32 suffix instead; this is the same
   function, because a name derived differently on the two backends would leave a shared table
   with two indexes doing one job. *)
let fnv1a_32 text =
  let hash = ref 0x811c9dc5 in
  String.iter (fun char ->
    hash := ((!hash lxor Char.code char) * 16777619) land 0xffffffff) text;
  !hash

let truncate_sql_identifier name =
  if String.length name <= 63 then name
  else begin
    let suffix = Printf.sprintf "_%x" (fnv1a_32 name) in
    String.sub name 0 (63 - String.length suffix) ^ suffix
  end

(* `Maybe X` is the nullable column; everything else is NOT NULL. *)
let maybe_element = function
  | TAdt (info, [inner]) when info.adt_tesl_name = "Maybe" -> Some inner
  | _ -> None

(* The column type a Tesl type maps to.  `Int` is NUMERIC because a Tesl integer is unbounded
   and BIGINT is exactly where that stops being true; `PosixMillis` is the ONE deliberate
   BIGINT exception, named as such in `dsl/sql.rkt` and contractual for existing tables. *)
let rec column_sql_type ty =
  match ty with
  | TInt -> Some "NUMERIC"
  | TFloat -> Some "DOUBLE PRECISION"
  | TString -> Some "TEXT"
  | TBool -> Some "BOOLEAN"
  | TNewtype { tesl_name = "PosixMillis"; _ } -> Some "BIGINT"
  | TNewtype { tesl_name = "Int32"; _ } -> Some "INTEGER"
  | TNewtype info -> column_sql_type info.base
  (* An ADT column is JSONB holding the value's own wire shape (`{"tag":…}`), which is what
     `dsl/sql.rkt` writes — a column written by one backend has to be readable by the other. *)
  | TAdt (info, _) when info.adt_tesl_name <> "Maybe" -> Some "JSONB"
  | _ -> (match maybe_element ty with Some inner -> column_sql_type inner | None -> None)

let entity_columns (info : entity_info) =
  List.map (fun (field, ty) ->
    let sql_type = match List.assoc_opt field info.ent_db_types with
      | Some declared -> String.uppercase_ascii declared
      | None ->
        (match column_sql_type ty with
         | Some text -> text
         | None -> unsupported info.ent_loc
           "Go backend does not support column `%s.%s` on a Postgres-backed database yet"
           info.ent_tesl_name field)
    in
    { col_field = field;
      col_name = camel_to_snake field;
      col_sql_type = sql_type;
      col_nullable = maybe_element ty <> None;
      col_primary_key = field = info.ent_primary_key;
      col_type = ty })
    info.ent_row.rec_fields

(* `"schema"."table"`, or the bare table when the declaration names no schema. *)
let sql_qualified_table (database : database_info) (info : entity_info) =
  if database.db_schema = "" then sql_ident info.ent_table_name
  else sql_ident database.db_schema ^ "." ^ sql_ident info.ent_table_name

let sql_column_of loc (info : entity_info) field =
  match List.find_opt (fun (column : column_info) -> column.col_field = field)
          (entity_columns info) with
  | Some column -> column
  | None -> unsupported loc "Go backend: entity `%s` has no column `%s`"
    info.ent_tesl_name field

(* The tag is EXPORTED: an ADT provided by the runtime (or, later, by another
   emitted module) is matched from a different package, where an unexported field
   would be invisible. *)
(* `Tesl.List` leaves are element-polymorphic, so they cannot be fixed signatures
   like the String leaves.  Arity and argument ORDER come from tesl/list.tesl:
   `take n xs`, `member x xs`, `append xs ys`. *)
type list_leaf = {
  leaf_name : string;
  leaf_go : string;
  leaf_arity : int;
  (* How the result type is built from the element type of the list argument. *)
  (* `Inner` is for a leaf over a list OF lists, whose result is the inner list. *)
  leaf_result : [ `Int | `Bool | `Same | `MaybeElement | `MaybeSame | `Inner ];
  (* Which extra closure the runtime function takes, if any. *)
  leaf_closure : [ `None | `Equal | `Less ];
  (* Index of the argument that is the list, and of a non-list argument to check. *)
  leaf_list_index : int;
}

let list_leaves = [
  { leaf_name = "List.length"; leaf_go = "teslrt.ListLength"; leaf_arity = 1;
    leaf_result = `Int; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.isEmpty"; leaf_go = "teslrt.ListIsEmpty"; leaf_arity = 1;
    leaf_result = `Bool; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.head"; leaf_go = "teslrt.ListHead"; leaf_arity = 1;
    leaf_result = `MaybeElement; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.last"; leaf_go = "teslrt.ListLast"; leaf_arity = 1;
    leaf_result = `MaybeElement; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.tail"; leaf_go = "teslrt.ListTail"; leaf_arity = 1;
    leaf_result = `MaybeSame; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.reverse"; leaf_go = "teslrt.ListReverse"; leaf_arity = 1;
    leaf_result = `Same; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.sum"; leaf_go = "teslrt.ListSum"; leaf_arity = 1;
    leaf_result = `Int; leaf_closure = `None; leaf_list_index = 0 };
  (* Of NO element the product is 1, not 0 — `(apply * '())` — so the empty list is the
     identity here the way it is the zero for `sum`. *)
  { leaf_name = "List.product"; leaf_go = "teslrt.ListProduct"; leaf_arity = 1;
    leaf_result = `Int; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.append"; leaf_go = "teslrt.ListAppend"; leaf_arity = 2;
    leaf_result = `Same; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.take"; leaf_go = "teslrt.ListTake"; leaf_arity = 2;
    leaf_result = `Same; leaf_closure = `None; leaf_list_index = 1 };
  { leaf_name = "List.drop"; leaf_go = "teslrt.ListDrop"; leaf_arity = 2;
    leaf_result = `Same; leaf_closure = `None; leaf_list_index = 1 };
  { leaf_name = "List.member"; leaf_go = "teslrt.ListMemberBy"; leaf_arity = 2;
    leaf_result = `Bool; leaf_closure = `Equal; leaf_list_index = 1 };
  { leaf_name = "List.contains"; leaf_go = "teslrt.ListMemberBy"; leaf_arity = 2;
    leaf_result = `Bool; leaf_closure = `Equal; leaf_list_index = 1 };
  { leaf_name = "List.unique"; leaf_go = "teslrt.ListUniqueBy"; leaf_arity = 1;
    leaf_result = `Same; leaf_closure = `Equal; leaf_list_index = 0 };
  { leaf_name = "List.sort"; leaf_go = "teslrt.ListSortBy"; leaf_arity = 1;
    leaf_result = `Same; leaf_closure = `Less; leaf_list_index = 0 };
  (* `flatten` is `concat` under another name, per the stdlib docs. *)
  { leaf_name = "List.concat"; leaf_go = "teslrt.ListConcat"; leaf_arity = 1;
    leaf_result = `Inner; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.flatten"; leaf_go = "teslrt.ListConcat"; leaf_arity = 1;
    leaf_result = `Inner; leaf_closure = `None; leaf_list_index = 0 };
  { leaf_name = "List.maximum"; leaf_go = "teslrt.ListMaximum"; leaf_arity = 1;
    leaf_result = `MaybeElement; leaf_closure = `Less; leaf_list_index = 0 };
  { leaf_name = "List.minimum"; leaf_go = "teslrt.ListMinimum"; leaf_arity = 1;
    leaf_result = `MaybeElement; leaf_closure = `Less; leaf_list_index = 0 };
]

let list_leaf name = List.find_opt (fun leaf -> leaf.leaf_name = name) list_leaves

(* Dict leaves are polymorphic in both key and value, so like the list leaves they are
   typed per call site rather than by a fixed signature.  Every one that has to find a
   key takes the key ORDERING the emitter supplies — the same device used for list
   equality and sorting. *)
type dict_leaf = {
  dict_name : string;
  dict_go : string;
  dict_arity : int;
  dict_result : [ `Dict | `MaybeValue | `Value | `CheckDict | `Int | `Bool | `Keys | `Values
                | `Pairs ];
  dict_needs_order : bool;
}

let dict_leaves = [
  { dict_name = "Dict.empty"; dict_go = "teslrt.DictEmpty"; dict_arity = 0;
    dict_result = `Dict; dict_needs_order = false };
  { dict_name = "Dict.singleton"; dict_go = "teslrt.DictSingleton"; dict_arity = 2;
    dict_result = `Dict; dict_needs_order = false };
  { dict_name = "Dict.insert"; dict_go = "teslrt.DictInsert"; dict_arity = 3;
    dict_result = `Dict; dict_needs_order = true };
  (* `requireKey` answers the same dict plus a `HasKey` proof, which erases — so what is left is
     a check whose REJECTION is the point, and `get` is the total read the proof licenses. *)
  { dict_name = "Dict.requireKey"; dict_go = "teslrt.DictRequireKey"; dict_arity = 2;
    dict_result = `CheckDict; dict_needs_order = true };
  { dict_name = "Dict.get"; dict_go = "teslrt.DictGet"; dict_arity = 2;
    dict_result = `Value; dict_needs_order = true };
  { dict_name = "Dict.lookup"; dict_go = "teslrt.DictLookup"; dict_arity = 2;
    dict_result = `MaybeValue; dict_needs_order = true };
  { dict_name = "Dict.member"; dict_go = "teslrt.DictMember"; dict_arity = 2;
    dict_result = `Bool; dict_needs_order = true };
  { dict_name = "Dict.remove"; dict_go = "teslrt.DictRemove"; dict_arity = 2;
    dict_result = `Dict; dict_needs_order = true };
  (* `Dict.delete` is `Dict.remove` under another name — tesl/dict.rkt defines it as
     exactly that, so both spellings reach one implementation here too. *)
  { dict_name = "Dict.delete"; dict_go = "teslrt.DictRemove"; dict_arity = 2;
    dict_result = `Dict; dict_needs_order = true };
  (* LEFT-BIASED: a key in both keeps the FIRST dict's value.  It is also the one leaf whose
     arguments are two dicts, so the rotation below leaves it alone — swapping them would
     silently reverse the bias. *)
  { dict_name = "Dict.union"; dict_go = "teslrt.DictUnion"; dict_arity = 2;
    dict_result = `Dict; dict_needs_order = true };
  { dict_name = "Dict.size"; dict_go = "teslrt.DictSize"; dict_arity = 1;
    dict_result = `Int; dict_needs_order = false };
  { dict_name = "Dict.isEmpty"; dict_go = "teslrt.DictIsEmpty"; dict_arity = 1;
    dict_result = `Bool; dict_needs_order = false };
  { dict_name = "Dict.keys"; dict_go = "teslrt.DictKeys"; dict_arity = 1;
    dict_result = `Keys; dict_needs_order = false };
  { dict_name = "Dict.values"; dict_go = "teslrt.DictValues"; dict_arity = 1;
    dict_result = `Values; dict_needs_order = false };
  { dict_name = "Dict.toList"; dict_go = "teslrt.DictToList"; dict_arity = 1;
    dict_result = `Pairs; dict_needs_order = false };
  { dict_name = "Dict.fromList"; dict_go = "teslrt.DictFromList"; dict_arity = 1;
    dict_result = `Dict; dict_needs_order = true };
]

let dict_leaf name = List.find_opt (fun leaf -> leaf.dict_name = name) dict_leaves

(* Set leaves.  `set_result` says how the result is built from the element type; the Set
   argument keeps its Tesl position, since the runtime signatures were written to match
   (`SetInsert(value, s, less)`). *)
type set_leaf = {
  set_name : string;
  set_go : string;
  set_arity : int;
  set_result : [ `Set | `Int | `Bool | `Elements ];
  set_needs_order : bool;
  (* Index of the Set argument, or -1 when there is none (`Set.empty`). *)
  set_index : int;
}

let set_leaves = [
  { set_name = "Set.empty"; set_go = "teslrt.SetEmpty"; set_arity = 0;
    set_result = `Set; set_needs_order = false; set_index = -1 };
  { set_name = "Set.singleton"; set_go = "teslrt.SetSingleton"; set_arity = 1;
    set_result = `Set; set_needs_order = false; set_index = -1 };
  { set_name = "Set.member"; set_go = "teslrt.SetMember"; set_arity = 2;
    set_result = `Bool; set_needs_order = true; set_index = 1 };
  { set_name = "Set.insert"; set_go = "teslrt.SetInsert"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 1 };
  { set_name = "Set.remove"; set_go = "teslrt.SetRemove"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 1 };
  { set_name = "Set.delete"; set_go = "teslrt.SetRemove"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 1 };
  { set_name = "Set.size"; set_go = "teslrt.SetSize"; set_arity = 1;
    set_result = `Int; set_needs_order = false; set_index = 0 };
  { set_name = "Set.isEmpty"; set_go = "teslrt.SetIsEmpty"; set_arity = 1;
    set_result = `Bool; set_needs_order = false; set_index = 0 };
  { set_name = "Set.toList"; set_go = "teslrt.SetToList"; set_arity = 1;
    set_result = `Elements; set_needs_order = false; set_index = 0 };
  { set_name = "Set.fromList"; set_go = "teslrt.SetFromList"; set_arity = 1;
    set_result = `Set; set_needs_order = true; set_index = -1 };
  { set_name = "Set.union"; set_go = "teslrt.SetUnion"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 0 };
  { set_name = "Set.intersection"; set_go = "teslrt.SetIntersection"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 0 };
  { set_name = "Set.difference"; set_go = "teslrt.SetDifference"; set_arity = 2;
    set_result = `Set; set_needs_order = true; set_index = 0 };
  { set_name = "Set.isSubset"; set_go = "teslrt.SetIsSubset"; set_arity = 2;
    set_result = `Bool; set_needs_order = true; set_index = 0 };
]

let set_leaf name = List.find_opt (fun leaf -> leaf.set_name = name) set_leaves

(* `Tuple2.first p` is a field read dressed as a call: the accessors are the only way
   to reach a tuple's components, since a tuple has no user-visible field syntax. *)
let tuple_accessor = function
  | "Tuple2.first" -> Some ("Tuple2", "first")
  | "Tuple2.second" -> Some ("Tuple2", "second")
  | "Tuple3.first" -> Some ("Tuple3", "first")
  | "Tuple3.second" -> Some ("Tuple3", "second")
  | "Tuple3.third" -> Some ("Tuple3", "third")
  | _ -> None

(* The higher-order leaves lower to an emitted LOOP rather than a runtime helper: a Go
   func value passed into a generic helper costs an indirect call per element and
   blocks inlining, and these are hot-path functions.  A lambda argument's body is
   inlined into the loop (no closure, no call), a named function becomes a direct
   call. *)
type hof =
  | HofMap | HofFilter | HofFoldl | HofFoldr | HofAny | HofAll | HofFilterCheck
  | HofAllCheck | HofZip | HofFind | HofFilterMap | HofConcatMap | HofSortBy
  | HofEmptyForAll | HofSetFilterCheck | HofSetAllCheck | HofDictFilterCheckValues
  | HofDictFilterCheckKeys | HofCount

let higher_order_leaf = function
  | "List.map" -> Some HofMap
  | "List.filter" -> Some HofFilter
  | "List.foldl" -> Some HofFoldl
  | "List.foldr" -> Some HofFoldr
  | "List.any" -> Some HofAny
  | "List.all" -> Some HofAll
  | "List.filterCheck" -> Some HofFilterCheck
  | "List.allCheck" -> Some HofAllCheck
  | "List.zip" -> Some HofZip
  | "List.find" -> Some HofFind
  | "List.filterMap" -> Some HofFilterMap
  | "List.concatMap" -> Some HofConcatMap
  | "List.sortBy" -> Some HofSortBy
  (* `List.emptyForAll check` is the EMPTY list carrying the `ForAll` the check would have
     proved of every element — vacuously true, and the proof erases, so what is left is an
     empty slice.  It takes the check only to name the element type. *)
  | "List.emptyForAll" -> Some HofEmptyForAll
  (* `List.count p xs` is `List.filter` that keeps only the TALLY, so it allocates nothing. *)
  | "List.count" -> Some HofCount
  (* The Set counterparts of `List.filterCheck`/`List.allCheck`: the same rules, rebuilt as a
     set. *)
  | "Set.filterCheck" -> Some HofSetFilterCheck
  | "Set.allCheck" -> Some HofSetAllCheck
  (* The Dict counterparts: the entries whose VALUE — or whose KEY — passes the check. *)
  | "Dict.filterCheckValues" -> Some HofDictFilterCheckValues
  | "Dict.filterCheckKeys" -> Some HofDictFilterCheckKeys
  | _ -> None

let higher_order_leaf_names =
  ["List.map"; "List.filter"; "List.foldl"; "List.foldr"; "List.any"; "List.all";
   "List.filterCheck"; "List.allCheck"; "List.zip"; "List.find"; "List.filterMap";
   "List.concatMap"; "List.sortBy"; "List.emptyForAll"; "List.count";
   "Set.filterCheck"; "Set.allCheck"; "Dict.filterCheckValues"; "Dict.filterCheckKeys"]

let hof_arity = function
  | HofFoldl | HofFoldr -> 3
  | HofFind | HofFilterMap | HofConcatMap | HofSortBy -> 2
  | HofMap | HofFilter | HofAny | HofAll | HofFilterCheck | HofAllCheck | HofZip
  | HofSetFilterCheck | HofSetAllCheck | HofDictFilterCheckValues
  | HofDictFilterCheckKeys | HofCount -> 2
  | HofEmptyForAll -> 1

(* Every constructor is registered in the signature table under its own name, so a
   constructor application resolves without knowing its ADT up front. *)
let adt_ctor_of_signature signatures name =
  match Hashtbl.find_opt signatures name with
  | Some { result = TAdt (info, _); _ } ->
    (match find_variant info name with
     | Some variant -> Some (info, variant)
     | None -> None)
  | _ -> None

(* The payload of a `publish C(key) Ctor { … }`: the parser splits the constructor from its
   literal, and rebuilding the application is what lets the ordinary paths emit it — the same
   reason the Racket emitter rebuilds it there.

   Which application depends on what the constructor IS.  A record type takes the literal as it
   stands (`Notice { message: … }` is a record construction).  An ADT VARIANT takes its payload
   POSITIONALLY, so the literal's fields are reordered into the variant's declared order — the
   labels are the author's documentation, and the constructor's own order is what decides which
   payload slot each value lands in. *)
(* Is this Go type the runtime's MONEY RATE — money per quantity?  Every rate alias registers
   the same runtime type under its own name, so the NAME is what says which denominator the
   rate carries, and the type is what says it is a rate at all. *)
let is_money_rate = function
  | TRecord info -> info.rec_go_name = "teslrt.MoneyRate"
  | _ -> false

let is_money = function
  | TRecord info -> info.rec_tesl_name = "Money" && info.rec_go_name = "teslrt.Money"
  | _ -> false

(* The rate algebra, decided from the operand types:
     money / quantity  → a RATE, whose denominator the expectation names;
     rate  * quantity  → MONEY, the one place a rate materialises (and so the one rounding);
     rate  * scalar    → a rate, rescaled exactly.
   `rate * float` is ambiguous between the last two — both are a rate and a float at run time —
   so it is settled the way Racket settles it: by what the RESULT is expected to be. *)
let money_rate_binop ?expected op left_ty right_ty =
  ignore expected;
  match op with
  | BMul when is_money_rate left_ty && right_ty = TQuantity -> Some `Consume
  | BMul when left_ty = TQuantity && is_money_rate right_ty -> Some `ConsumeFlipped
  | BMul when is_money_rate left_ty && right_ty = TFloat -> Some `Scale
  | BMul when left_ty = TFloat && is_money_rate right_ty -> Some `ScaleFlipped
  | BDiv when is_money left_ty && right_ty = TQuantity -> Some `Divide
  | _ -> None

(* Arithmetic on DIMENSIONED quantities.  The dimensions themselves are the checker's business
   — it is what rejects `length + mass` and what makes `length / duration` a speed — so what is
   decided here is only which operand shapes are arithmetic at all: quantity with quantity, and
   quantity scaled by a plain number. *)
let quantity_binop op left_ty right_ty =
  let quantity ty = ty = TQuantity in
  match op with
  | BAdd | BSub when quantity left_ty && quantity right_ty -> true
  | BMul | BDiv when quantity left_ty && (quantity right_ty || right_ty = TFloat) -> true
  | BMul when left_ty = TFloat && quantity right_ty -> true
  (* A scalar over a quantity INVERTS the dimension — `1.0 / period` is a frequency — which
     the checker works out; here it is the same float division. *)
  | BDiv when left_ty = TFloat && quantity right_ty -> true
  | _ -> false

let publish_payload_expr signatures loc ctor payload =
  match payload, adt_ctor_of_signature signatures ctor with
  | ERecord { fields; _ }, Some (_, variant) ->
    let argument name = match List.assoc_opt name fields with
      | Some value -> value
      | None -> unsupported loc "Go backend `%s` has no value for field `%s`" ctor name
    in
    List.fold_left (fun applied (name, _) ->
      EApp { fn = applied; arg = argument name; loc })
      (EConstructor { name = ctor; args = []; loc })
      variant.var_fields
  | ERecord _, None ->
    EApp { fn = EConstructor { name = ctor; args = []; loc }; arg = payload; loc }
  | _ -> payload

let lookup_env loc name env =
  match List.assoc_opt name env with
  | Some ty -> ty
  | None -> unsupported loc "Go backend cannot resolve value `%s`" name

let rec flatten_app args = function
  | EApp { fn; arg; _ } -> flatten_app (arg :: args) fn
  | head -> head, args

(* `String.length s` parses as a field access over the module name (`String` is a
   UIDENT, so it is an EConstructor).  Normalising it to the qualified name lets the
   ordinary call path resolve it against the stdlib signature table. *)
let normalize_call_head = function
  | EField { obj = EConstructor { name = module_name; args = []; _ }; field; loc } ->
    EVar { name = module_name ^ "." ^ field; loc }
  | head -> head

let normalize_call_args params args =
  match params, args with
  | [], [EConstructor { name = "Unit"; args = []; _ }]
  | [], [EList { elems = []; _ }] -> []
  | _ -> args

let expect_fail_call fn arg loc =
  let args = match arg with
    | EList { elems = []; _ } -> []
    | _ ->
      let head, rest = flatten_app [] arg in
      head :: rest
  in
  List.fold_left (fun call arg -> EApp { fn = call; arg; loc }) fn args

let bool_literal_value = function
  | ELit { lit = LBool value; _ } -> Some value
  | EConstructor { name = "True"; args = []; _ } -> Some true
  | EConstructor { name = "False"; args = []; _ } -> Some false
  | _ -> None

(* `check f a b` — a CHECK APPLICATION.  Two things depend on telling one apart from an
   ordinary call: its type (the check's value, not its `Check`), and — inside another
   check — that a rejection must PROPAGATE rather than trap. *)
let check_application signatures expr =
  match expr with
  | EApp _ ->
    let rec flatten acc = function
      | EApp { fn; arg; _ } -> flatten (arg :: acc) fn
      | head -> head, acc
    in
    (match flatten [] expr with
     | EVar { name = "check"; _ }, (callee :: args) ->
       (* The callee is NORMALISED first: a stdlib name is written `Crypto.checkSignature`,
          which parses as a field read on a constructor rather than as one identifier.  Without
          this, `let v = check Crypto.checkSignature …` inside a check or an `auth` fell through
          to the non-propagating path and emitted `MustCheck` — a PANIC where the request should
          have answered 401, i.e. a verification failure crashed the request instead of
          rejecting it. *)
       (match normalize_call_head callee with
        | EVar { name; _ } ->
          (match Hashtbl.find_opt signatures name with
           | Some ({ result = TCheck _; _ } as signature)
             when List.length args = List.length signature.params -> Some (signature, args)
           | _ -> None)
        | _ -> None)
     | _ -> None)
  | _ -> None

(* The type of a query.  A `select` yields rows, `selectOne` a `Maybe` row, and the
   write forms yield either the row they wrote or nothing at all — which is Tesl's `Unit`
   and Go's empty struct.  The aggregate and grouped forms are refused rather than
   guessed: each needs its own comparison or arithmetic over a column type. *)
let type_of_sql_form signatures loc form =
  let maybe_of inner =
    match adt_ctor_of_signature signatures "Nothing" with
    | Some (info, _) -> TAdt (info, [inner])
    | None -> unsupported loc
      "Go backend `selectOne` yields a Maybe; import `Tesl.Maybe`"
  in
  match form with
  | SqlSelect (seed, _) ->
    let info = entity_of_query loc seed.entity in
    let row = TRecord info.ent_row in
    (match seed.kind with
     | SelectMany -> TList row
     | SelectOne -> maybe_of row
     | SelectCount -> TInt
     (* A scalar aggregate speaks in its COLUMN's type — a sum of Money is Money — which is
        what the checker infers too (select_aggregate_field_type).  MAX/MIN are OPTIONAL:
        over no matching row they have no value of that type, and SUM does (zero). *)
     | SelectSum field -> entity_column loc info field
     | SelectMax field | SelectMin field -> maybe_of (entity_column loc info field)
     (* A GROUPED aggregate answers one (bucket, value) pair per group.  The bucket's type is
        the key's: a plain column groups by that column, and a `Time.trunc*` bucket by the
        instant the bucket starts at, which is the same `PosixMillis` the column holds. *)
     | SelectCountBy | SelectSumBy _ ->
       let key = match seed.group_by with
         | [GField field] | [GTimeTrunc (_, _, field)] -> entity_column loc info field
         | [] -> unsupported loc "Go backend requires `groupBy` on a grouped aggregate"
         | _ -> unsupported loc
           "Go backend does not support `groupBy` on more than one key yet"
       in
       let value = match seed.kind with
         | SelectSumBy field -> entity_column loc info field
         | _ -> TInt
       in
       (match Hashtbl.find_opt signatures "Tuple2" with
        | Some { result = TAdt (tuple, _); _ } -> TList (TAdt (tuple, [key; value]))
        | _ -> unsupported loc
          "Go backend needs `Tesl.Tuple` imported for a grouped aggregate"))
  | SqlInsert insert -> TRecord (entity_of_query loc insert.entity).ent_row
  (* `insertMany` is typed as the entity by the checker but RETURNS nothing on Racket
     (`insert-many!` ends in `(void)`), so the only sound reading of its result here is
     `Unit`: a program that bound and used it would be broken on the other backend. *)
  | SqlInsertMany (_, entity) -> ignore (entity_of_query loc entity); TUnit
  (* An `upsert` is typed UNIT, which is what the checker types it as: the Racket form
     answers the stored row, but a program that bound and used it would not type-check, so
     the only reading both backends agree on is that it answers nothing. *)
  | SqlUpsert upsert -> ignore (entity_of_query loc upsert.entity); TUnit
  | SqlUpdate update ->
    if update.returning_one then TRecord (entity_of_query loc update.entity).ent_row
    else TUnit
  | SqlDelete (seed, _) ->
    ignore (entity_of_query loc seed.entity);
    if not seed.with_result then TUnit
    else
      (* `DeleteResult` is runtime-provided and registered by the import that names it, so a
         module that deletes with a result and does not import it is refused HERE rather than
         emitting a reference to a type it never brought in. *)
      (match Option.bind !current_types
               (fun types -> Hashtbl.find_opt types.adts "DeleteResult") with
       | Some info -> TAdt (info, [])
       | None -> unsupported loc
         "Go backend `deleteAndReturnResult` answers a `DeleteResult`; import \
          `Tesl.DB exposing [DeleteResult(..)]`")

(* A stand-in for the ADT info a scalar `case` does not have.  The scalar path never reads it;
   it exists so the two paths can share one `let` binding rather than duplicating every arm
   walk below. *)
let adt_placeholder_info = {
  adt_tesl_name = ""; adt_owner = ""; adt_go_name = ""; adt_tag_type = "";
  adt_params = []; adt_variants = []; adt_loc = Location.dummy_loc "";
  adt_builtin = true;
}

(* A `case` may discriminate a SCALAR as well as an ADT — `case a + b of 0 -> … | _ -> …` — and
   then the arms are literal patterns plus a catch-all rather than constructors.  Which scalars:
   the ones with an equality this backend emits (a newtype included, comparing its payload).
   `Float` is deliberately absent: comparing a float for equality is the bug the Float slice
   refuses elsewhere, and a `case` over one would hide it behind pattern syntax. *)
let scalar_case_type = function
  | TInt | TString | TBool -> true
  | TNewtype info -> (match info.base with TInt | TString | TBool -> true | _ -> false)
  | _ -> false

(* Bindings a scalar arm introduces.  A literal binds nothing, a variable binds the scrutinee,
   and a constructor pattern is refused — there is no ADT here to name a constructor of. *)
let scalar_pattern_bindings _loc scrut_ty pattern =
  match pattern with
  | PWild -> []
  | PVar name -> [name, scrut_ty]
  | PLit _ -> []
  (* `True`/`False` parse as nullary CONSTRUCTORS, but over a Bool scrutinee they are the two
     literals — Racket matches them the same way. *)
  | PNullary { ctor = ("True" | "False"); _ } -> []
  | PNullary { ctor; loc } | PCon { ctor; loc; _ } ->
    unsupported loc "Go backend `case` over a scalar cannot match constructor `%s`" ctor

(* The known `initTelemetry` keywords.  Named here so a keyword in VALUE position (a user binding
   spelled `console`, say) is not silently taken as the next keyword — the bug the Racket emitter
   documents at the same place. *)
let init_telemetry_keywords =
  [ "service"; "endpoint"; "console"; "metrics"; "metricsInterval"; "traces"; "traceRatio" ]

let init_telemetry_keyword = function
  | EVar { name; _ } when List.mem name init_telemetry_keywords -> Some name
  | _ -> None

(* ── `asTool`: a typed function wrapped as a tool ────────────────────────────
   The schema, the argument decode and the dispatch all come from ONE place — the
   function's parameter list — so the three cannot describe different arguments.  The
   checker has already restricted a tool function's parameters to the agent primitives; the
   refusals below are what keeps this emitter total rather than guessing for a type the
   checker later admits. *)

let agent_tool_prim loc (binding : binding) =
  match Validation_common.agent_prim_of_type_expr binding.type_expr with
  | Some prim -> prim
  | None ->
    unsupported loc
      "Go backend cannot derive a tool schema for parameter `%s`: its type is not one a \
       model can be asked for" binding.name

(* The JSON Schema object a tool function's parameters describe.  It is model GUIDANCE — the
   validator below is what actually rejects bad arguments — but it is the only channel that
   reaches the model, which is why the per-primitive descriptions ride along in it. *)
let agent_tool_schema loc (params : binding list) =
  let properties = List.map (fun (binding : binding) ->
    Printf.sprintf "%s:%s" (go_quote binding.name)
      (Validation_common.agent_prim_schema_prop (agent_tool_prim loc binding))) params in
  let required = List.map (fun (binding : binding) -> go_quote binding.name) params in
  Printf.sprintf "{\"type\":\"object\",\"properties\":{%s},\"required\":[%s]}"
    (String.concat "," properties) (String.concat "," required)

(* The runtime reader for one argument.  Each answers the parameter's OWN Go type, so the
   dispatch below asserts the type the function already declared rather than a wire shape. *)
let agent_tool_arg_reader loc (binding : binding) =
  match agent_tool_prim loc binding with
  | Validation_common.APString -> "teslrt.ToolArgString"
  | Validation_common.APInt -> "teslrt.ToolArgInt"
  | Validation_common.APFloat -> "teslrt.ToolArgFloat"
  | Validation_common.APBool -> "teslrt.ToolArgBool"
  | Validation_common.APPosixMillis -> "teslrt.ToolArgPosixMillis"
  | Validation_common.APMoney -> "teslrt.ToolArgMoney"
  (* A dimensioned quantity IS a float at run time; its unit lives in the compiler's type
     layer and rides to the model in the schema. *)
  | Validation_common.APQuantity _ -> "teslrt.ToolArgFloat"

(* ── `serverTools`: an endpoint's tool-input schema ──────────────────────────
   One required property per capture and one for the body binder, in handler argument
   order.  It is model GUIDANCE, best-effort by design: the endpoint's own decode is what
   actually validates, and `{}` — accept anything — is the honest answer for a shape this
   cannot describe. *)

let rec server_tool_body_schema (codecs : codec_form list) (ty : type_expr) : string =
  match Validation_common.agent_prim_of_type_expr ty with
  | Some prim -> Validation_common.agent_prim_schema_prop prim
  | None ->
    (match ty with
     | TApp { head = TName { name = "List"; _ }; arg; _ } ->
       Printf.sprintf "{\"type\":\"array\",\"items\":%s}" (server_tool_body_schema codecs arg)
     | TName { name; _ } ->
       (match List.find_opt (fun (codec : codec_form) -> codec.type_name = name) codecs with
        | Some codec -> server_tool_codec_schema codecs codec
        | None -> "{}")
     | _ -> "{}")

and server_tool_codec_schema (codecs : codec_form list) (codec : codec_form) : string =
  match codec.from_json with
  | FromJsonAlts (alternative :: _) ->
    let fields = List.filter_map (function
      | DecodeField { json_key; codec = field_codec; _ } -> Some (json_key, field_codec)
      | _ -> None) alternative in
    let property field_codec = match field_codec with
      | "stringCodec" -> "{\"type\":\"string\"}"
      | "intCodec" -> "{\"type\":\"integer\"}"
      | "floatCodec" -> "{\"type\":\"number\"}"
      | "boolCodec" -> "{\"type\":\"boolean\"}"
      | other ->
        (match List.find_opt (fun (c : codec_form) ->
                 c.name = other || c.type_name = other) codecs with
         | Some nested -> server_tool_codec_schema codecs nested
         | None -> "{}")
    in
    Printf.sprintf "{\"type\":\"object\",\"properties\":{%s},\"required\":[%s]}"
      (String.concat "," (List.map (fun (key, field_codec) ->
         Printf.sprintf "%s:%s" (go_quote key) (property field_codec)) fields))
      (String.concat "," (List.map (fun (key, _) -> go_quote key) fields))
  | _ -> "{}"

let server_tool_endpoint_schema (codecs : codec_form list) (endpoint : api_endpoint) : string =
  let properties =
    List.map (fun (capture : api_capture) ->
      capture.binding.name,
      (match Validation_common.agent_prim_of_type_expr capture.binding.type_expr with
       | Some prim -> Validation_common.agent_prim_schema_prop prim
       | None -> "{\"type\":\"string\"}")) endpoint.captures
    @ (match ep_body endpoint with
       | Some (binding : binding) ->
         [ binding.name, server_tool_body_schema codecs binding.type_expr ]
       | None -> [])
  in
  Printf.sprintf "{\"type\":\"object\",\"properties\":{%s},\"required\":[%s]}"
    (String.concat "," (List.map (fun (name, schema) ->
       Printf.sprintf "%s:%s" (go_quote name) schema) properties))
    (String.concat "," (List.map (fun (name, _) -> go_quote name) properties))

let rec type_of_expr signatures env expr =
  match expr with
  | ELit { lit = LInt _ | LBigInt _; _ } -> TInt
  | ELit { lit = LString _; _ } -> TString
  | ELit { lit = LBool _; _ } -> TBool
  | ELit { lit = LFloat _; _ } -> TFloat
  | ELit { lit = LInterp segments; _ } ->
    List.iter (function
      | ILiteral _ -> ()
      | IExpr expr ->
        (match type_of_expr signatures env expr with
         | TString | TInt | TBool | TFloat -> ()
         | _ -> unsupported (Checker.expr_loc expr)
           "Go backend interpolation supports String, Int, Float, and Bool only")) segments;
    TString
  | EVar { name; loc } ->
    (* A bare function name is a function VALUE, which the Go subset has no
       representation for.  Emitting a call here would diverge from the Racket
       backend, which hands back a procedure. *)
    (match List.assoc_opt name env, Hashtbl.find_opt signatures name with
     | Some ty, _ -> ty
     (* A module-level CONSTANT is referenced bare, so it resolves here rather than through the
        call paths — after a local binding, which may shadow it. *)
     | None, _ when Option.bind !current_types (fun types ->
                      Hashtbl.find_opt types.consts name) <> None ->
       (match Option.bind !current_types (fun types -> Hashtbl.find_opt types.consts name) with
        | Some (ty, _) -> ty
        | None -> assert false)
     (* A named function referred to WITHOUT arguments is a function value: Go spells that
        the same way (the function's own name), so the type is its signature read as an
        arrow.  A check is excluded — its `Check` result is not an ordinary value. *)
     | None, Some { params = (_ :: _ as params); result = (TCheck _ as result); _ } ->
       ignore params; ignore result;
       unsupported loc "Go backend does not support a `check` as a function value"
     | None, Some { params = (_ :: _ as params); result; _ } -> TFunc (params, result)
     | None, Some _ -> unsupported loc "Go backend does not support function `%s` as a value" name
     | None, None -> lookup_env loc name env)
  | EConstructor { name = "True" | "False"; args = []; _ } -> TBool
  | EConstructor { name = "Unit"; args = []; _ } -> TUnit
  (* A bare capitalised name that resolves to a CONSTANT — a currency (`Usd`) is spelled like
     a constructor and is a value, not a call. *)
  | EConstructor { name; args = []; _ }
    when Option.bind !current_types (fun types -> Hashtbl.find_opt types.consts name) <> None ->
    (match Option.bind !current_types (fun types -> Hashtbl.find_opt types.consts name) with
     | Some (ty, _) -> ty
     | None -> assert false)
  | EConstructor { name; args; loc } when adt_ctor_of_signature signatures name <> None ->
    let info, variant = match adt_ctor_of_signature signatures name with
      | Some pair -> pair
      | None -> assert false
    in
    type_of_variant_application signatures env loc info variant args
  | EConstructor { name; args; loc } ->
    (match Hashtbl.find_opt signatures name with
     | Some { params = [base]; result = (TNewtype _ as result); _ } ->
       (match args with
        | [arg] when type_of_expr signatures env arg = base -> result
        | [_] -> unsupported loc "Go backend newtype constructor `%s` argument type mismatch" name
        | _ -> unsupported loc "Go backend requires a fully-applied newtype constructor `%s`" name)
     (* A capitalised name whose signature ANSWERS a record it does not NAME: `FixedOffset 60`
        answers a `TimeZone`.  The surface spells a zone constructor that way, so it parses as
        a constructor, but it is an ordinary call. *)
     | Some ({ result = TRecord record; _ } as signature)
       when record.rec_tesl_name <> name
            && List.length signature.params = List.length args ->
       List.iter2 (fun arg want ->
         if type_unequal (type_of_arg signatures env want arg) want then
           unsupported loc "Go backend constructor `%s` argument type mismatch" name)
         args signature.params;
       signature.result
     (* A proof term: `ValidPort port` applies a FACT, which erases to the zero-size proof.
        Its arguments are proof subjects, so nothing is evaluated. *)
     | Some { params = []; result = TUnit; go_name = "struct{}{}"; _ } -> TUnit
     | _ -> unsupported loc "Go backend does not support constructor `%s` yet" name)
  (* A query's type comes from its ENTITY and its form, not from a signature: `select`
     and friends are surface syntax rather than functions. *)
  | (EApp _ | EBinop _ | ELet _) as sql when recognise_sql sql <> None ->
    let loc = Checker.expr_loc sql in
    (match recognise_sql sql with
     | Some form -> type_of_sql_form signatures loc form
     | None -> assert false)
  | EApp { loc; _ } as app ->
    let head, args = flatten_app [] app in
    let head = normalize_call_head head in
    (match head with
     | EVar { name = "#record-update#"; _ } ->
       (match args with
        | [ERecord { fields; _ }] -> type_of_record_update signatures env loc fields
        | _ -> unsupported loc "Go backend cannot resolve this record update")
     | EConstructor { name; args = constructor_args; _ }
       when record_info_of_signature signatures name <> None ->
       let info = match record_info_of_signature signatures name with
         | Some info -> info
         | None -> assert false
       in
       (match constructor_args @ args with
        | [ERecord { fields; _ }] ->
          check_record_literal signatures env loc info fields;
          TRecord info
        | _ -> unsupported loc "Go backend requires a `%s { field: value }` record literal" name)
     | EConstructor { name; args = constructor_args; _ }
       when adt_ctor_of_signature signatures name <> None ->
       let info, variant = match adt_ctor_of_signature signatures name with
         | Some pair -> pair
         | None -> assert false
       in
       type_of_variant_application signatures env loc info variant
         (variant_positional_args loc variant (constructor_args @ args))
     (* `exists name => body` parses as `make-witness (name body)`: the witness is a proof
        SUBJECT, not a value the caller receives, so the package erases to its body. *)
     | EVar { name = "make-witness"; _ } ->
       (match args with
        | [EApp { arg = body; _ }] -> type_of_expr signatures env body
        | [body] -> type_of_expr signatures env body
        | _ -> unsupported loc "Go backend cannot resolve this existential package")
     | EVar { name = "check"; _ }
       when (match args with
             | conjunction :: _ ->
               (match check_conjunct_calls conjunction with
                | Some (_ :: _ :: _) -> true
                | _ -> false)
             | [] -> false) ->
       (* Every conjunct is a check over the SAME type, since each one's result feeds the
          next; the combined result is that type, exactly as for a single check.  A conjunct
          may be PARTIALLY APPLIED, in which case its last parameter is the checked one. *)
       let names = match args with
         | conjunction :: _ ->
           List.map fst (Option.value (check_conjunct_calls conjunction) ~default:[])
         | [] -> []
       in
       let value_ty = List.fold_left (fun expected name ->
         match Hashtbl.find_opt signatures name with
         (* The CHECKED parameter is the last one; anything before it the program supplied. *)
         | Some { params = (_ :: _ as params); result = TCheck result; _ }
           when (match List.rev params with
                 | subject :: _ -> subject = result
                 | [] -> false)
                && (expected = None || expected = Some result) -> Some result
         | Some { params = (_ :: _); result = TCheck _; _ } ->
           unsupported loc
             "Go backend combined check `%s` does not check the same type as the others" name
         | Some _ -> unsupported loc "`%s` is not a check" name
         | None -> unsupported loc "Go backend cannot resolve check `%s`" name) None names
       in
       (match value_ty, args with
        | Some want, [_; argument] ->
          if type_unequal (type_of_arg signatures env want argument) want then
            unsupported (Checker.expr_loc argument)
              "Go backend combined check argument type mismatch";
          want
        | Some _, _ -> unsupported loc
          "Go backend requires a combined check applied to exactly one value"
        | None, _ -> unsupported loc "Go backend cannot resolve this combined check")
     | EVar { name = "check"; _ } ->
       (match List.map normalize_call_head args with
        | EVar { name; _ } :: call_args ->
          (match Hashtbl.find_opt signatures name with
            | Some { params; result = TCheck result; _ } ->
             if List.length params <> List.length call_args then
               unsupported loc "Go backend requires a fully-applied check `%s`" name;
             List.iter2 (fun arg want ->
               let got = type_of_arg signatures env want arg in
               (* One relaxation, and only for the password plaintext: `checkPassword` takes the
                  raw password, which a program normally holds as a `secret Password = String`.
                  Racket's `raw-str` unwraps any newtype there, and the emitter unwraps the same
                  two shapes at the call site — so accepting a newtype over String here is
                  agreement with the other backend, not looseness. *)
               let password_plaintext =
                 name = "Crypto.checkPassword" && want = TString
                 && (match got with TNewtype info -> info.base = TString | _ -> false)
               in
               if type_unequal got want && not password_plaintext then
                 unsupported (Checker.expr_loc arg) "Go backend check `%s` argument type mismatch" name)
               call_args params;
             result
           (* A stdlib leaf that IS a check — `check Dict.requireKey key d`.  Its signature is
              a placeholder, since a container leaf is typed per call site, so the leaf's own
              type rule decides whether this is a check at all. *)
           | Some _ when dict_leaf name <> None ->
             let leaf = match dict_leaf name with Some leaf -> leaf | None -> assert false in
             (match type_of_dict_leaf signatures env loc leaf call_args with
              | TCheck result -> result
              | _ -> unsupported loc "`%s` is not a check" name)
           | Some _ -> unsupported loc "`%s` is not a check" name
           | None -> unsupported loc "Go backend cannot resolve check `%s`" name)
         | _ -> unsupported loc "Go backend requires `check` followed by a named check function")
      | EVar { name = "not"; _ } when not (Hashtbl.mem signatures "not") ->
       (match args with
        | [arg] when type_of_expr signatures env arg = TBool -> TBool
        | [_] -> unsupported loc "Go backend `not` requires Bool"
         | _ -> unsupported loc "Go backend requires a fully-applied call to `not`")
      | EConstructor { name; args = constructor_args; _ } ->
        (match Hashtbl.find_opt signatures name with
         | Some { params = [base]; result = (TNewtype _ as result); _ } ->
           let args = constructor_args @ args in
           (match args with
            | [arg] when type_of_expr signatures env arg = base -> result
            | [_] ->
              unsupported loc "Go backend newtype constructor `%s` argument type mismatch" name
            | _ ->
              unsupported loc "Go backend requires a fully-applied newtype constructor `%s`" name)
         | Some ({ result = TRecord record; _ } as signature)
           when record.rec_tesl_name <> name
                && List.length signature.params = List.length (constructor_args @ args) ->
           List.iter2 (fun arg want ->
             if type_unequal (type_of_arg signatures env want arg) want then
               unsupported loc "Go backend constructor `%s` argument type mismatch" name)
             (constructor_args @ args) signature.params;
           signature.result
         (* An APPLIED fact — the proof term `ValidPort port` — erases to the zero proof. *)
         | Some { params = []; result = TUnit; go_name = "struct{}{}"; _ } -> TUnit
         | _ -> unsupported loc "Go backend does not support constructor `%s` yet" name)
      | EVar { name; _ } when set_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match set_leaf name with Some leaf -> leaf | None -> assert false in
       (* No expectation is available here; `Set.empty` resolves through type_of_arg,
          which is the path that carries one. *)
       type_of_set_leaf signatures env loc leaf args None
      | EVar { name; _ } when dict_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match dict_leaf name with Some leaf -> leaf | None -> assert false in
       type_of_dict_leaf signatures env loc leaf args
      | EVar { name; _ } when tuple_accessor name <> None ->
       let owner, field = match tuple_accessor name with
         | Some pair -> pair
         | None -> assert false
       in
       (match args with
        | [tuple] ->
          (match type_of_expr signatures env tuple with
           | TAdt (info, type_args) when info.adt_tesl_name = owner ->
             (match single_variant info with
              | Some variant ->
                (match List.assoc_opt field (variant_field_types info type_args variant) with
                 | Some ty -> ty
                 | None -> unsupported loc "Go backend `%s` has no component `%s`" owner field)
              | None -> unsupported loc "Go backend `%s` is not a tuple" owner)
           | _ -> unsupported loc "Go backend `%s` requires a `%s` argument" name owner)
        | _ -> unsupported loc "Go backend requires `%s` applied to 1 argument" name)
      (* The GDP proof combinators erase: a proof has no runtime content, so `attachFact`
         and `forgetFact` are the identity on their value and `detachFact`/`introAnd`/
         `andLeft`/`andRight` produce the zero-size proof value. *)
      | EVar { name = ("forgetFact" | "attachFact") ; _ } when args <> [] ->
        type_of_expr signatures env (List.hd args)
      (* A request verb inside an `api-test` drives the server under test. *)
      | EVar { name = ("get" | "post" | "put" | "delete" | "patch"); _ }
        when !current_api_server <> None ->
        (match !current_types with
         | Some types ->
           (match Hashtbl.find_opt types.records api_response_key with
            | Some info -> TRecord info
            | None -> unsupported loc
              "Go backend needs `Tesl.ApiTest` imported for a request in an api-test")
         | None -> unsupported loc "Go backend cannot resolve the api-test response type")
      (* `subscribe "/path"` opens a live stream against the server under test; the handle it
         answers supports nothing but `collect`. *)
      | EVar { name = "subscribe"; _ } when !current_api_server <> None ->
        (match args with
         | path :: _ ->
           if type_of_expr signatures env path <> TString then
             unsupported loc "Go backend api-test `subscribe` takes a String path";
           TStream
         | [] -> unsupported loc "Go backend api-test `subscribe` needs a path")
      (* `collect stream count N timeout Tms` answers the events as an untyped JSON array, so
         the same `isNotEmpty`/`includesWhere` assertions a body gets apply to it. *)
      | EVar { name = "collect"; _ } ->
        (match args with
         | stream :: _ ->
           if type_of_expr signatures env stream <> TStream then
             unsupported loc "Go backend `collect` takes a stream from `subscribe`";
           TJson
         | [] -> unsupported loc "Go backend `collect` needs a stream")
      (* The api-test queue verbs name a QUEUE, which the emitter resolves statically; their
        result types come from the queue's job type. *)
     (* The verb may be handed the queue as a VALUE rather than by name — `fn listDead(q:
        EmailQueue)` takes one as a parameter.  Only `deadJobs` reads the store without
        needing the job type, so it is the one that works on a value; the others resolve
        their dispatcher statically from the declaration and still take the name. *)
     | EVar { name = "deadJobs"; _ }
       when (match args with
             | [argument] ->
               (match typed_with_default (type_of_expr signatures env) argument with
                | Some (TRecord info), _ ->
                  Option.fold ~none:false ~some:(fun types -> Hashtbl.mem types.queues info.rec_tesl_name)
                    !current_types
                | _ -> false)
             | _ -> false) ->
       (match Option.bind !current_types (fun types -> Hashtbl.find_opt types.records "DeadJob") with
        | Some row -> TList (TRecord row)
        | None -> unsupported loc
          "Go backend `deadJobs` answers a `List DeadJob`; import `Tesl.Queue`")
     | EVar { name = ("pendingJobCount" | "drainQueue" | "processNextJob"
                     | "processNextDeadJob" | "deadJobs") as verb; _ }
       when queue_argument args <> None ->
       let info = match queue_argument args with
         | Some name -> queue_of_job_type loc name
         | None -> assert false
       in
       (match verb with
        | "pendingJobCount" -> TInt
        | "drainQueue" -> TUnit
        (* The dead-letter contents.  `DeadJob` is opaque — a test counts the list or
           requeues from it, which is all the Racket surface allows either. *)
        | "deadJobs" ->
          (match Option.bind !current_types (fun types ->
                   Hashtbl.find_opt types.records "DeadJob") with
           | Some row -> TList (TRecord row)
           | None -> unsupported loc
             "Go backend needs `deadJobs` imported from `Tesl.Queue`")
        | _ -> job_result_type signatures loc info)
     (* The secret-accepting header builders.  Their secret parameter is deliberately NOT
        matched against a fixed type: every `secret` newtype is a distinct Go type, and the
        generic call path demands an exact match, so the argument is checked here and unwrapped
        at the emit site.  A plain String is accepted for the same reason Racket accepts one. *)
     (* `hashPassword`/`checkPassword` take the PLAINTEXT, which is normally a
        `secret Password = String` — Racket's `raw-str` unwraps any newtype, so the Go side
        accepts the same two shapes and hands the runtime a `SecretString` either way.  The
        plaintext therefore never appears as an ordinary string at the call site. *)
     | EVar { name = ("Crypto.hashPassword" | "Crypto.checkPassword") as leaf; _ } ->
       let signature = match Hashtbl.find_opt signatures leaf with
         | Some signature -> signature
         | None -> unsupported loc "Go backend cannot resolve function `%s`" leaf
       in
       let plaintext = match leaf, args with
         | "Crypto.hashPassword", [plaintext] -> plaintext
         | "Crypto.checkPassword", [stored; plaintext] ->
           (match signature.params with
            | want :: _ ->
              if type_unequal (type_of_arg signatures env want stored) want then
                unsupported (Checker.expr_loc stored)
                  "Go backend `Crypto.checkPassword` takes a `Maybe PasswordHash`"
            | [] -> ());
           plaintext
         | _ -> unsupported loc "Go backend `%s` is applied to the wrong arity" leaf
       in
       (match type_of_expr signatures env plaintext with
        | TString -> ()
        | TNewtype info when info.base = TString -> ()
        | _ -> unsupported (Checker.expr_loc plaintext)
          "Go backend `%s` takes a String or a newtype over String" leaf);
       signature.result
     (* `initTelemetry service "x" endpoint "y" console True` is a KEYWORD surface that parses as
        a plain application, so the arguments arrive as an alternating stream of keyword names and
        values.  It configures the telemetry sink and answers Unit. *)
     | EVar { name = "initTelemetry"; _ } ->
       List.iter (fun value -> ignore (init_telemetry_keyword value)) args;
       TUnit
     | EVar { name = "decodeAs"; _ } when agent_form signatures "decodeAs" "teslrt.DecodeAs" ->
       let _, _, decoded = agent_decode_as_parts signatures env loc args in
       decoded
     | EVar { name = "tool"; _ } when agent_form signatures "tool" "teslrt.ToolOf" ->
       ignore (agent_tool_parts signatures env loc args);
       agent_opaque signatures loc "Tool"
     | EVar { name = "asTool"; _ } when agent_form signatures "asTool" "teslrt.ToolOf#asTool" ->
       let declaration : func_decl = agent_astool_decl loc args in
       (* The schema derivation is the total one: a parameter type a model cannot be asked
          for is refused HERE, at the wiring site, rather than at emission. *)
       ignore (agent_tool_schema declaration.loc declaration.params);
       let types = match !current_types with
         | Some types -> types
         | None -> unsupported loc "Go backend cannot resolve `asTool` here"
       in
       (* The tool_result the model reads is TEXT, so the function has to answer one. *)
       (match type_of_return_spec types declaration.return_spec with
        | TString -> ()
        | _ -> unsupported loc
          "Go backend `asTool %s` needs the function to answer a String" declaration.name);
       agent_opaque signatures loc "Tool"
     | EVar { name = "askFor"; _ } when agent_form signatures "askFor" "teslrt.AskFor" ->
       let _, _, _, _, decoded = agent_ask_for_parts signatures env loc args in
       decoded
     | EVar { name = ("serverTools" | "humanActions") as form; _ }
       when agent_form signatures form
              (if form = "serverTools" then "teslrt.ServerTools" else "teslrt.HumanActions") ->
       ignore (agent_endpoint_tools signatures env loc form args);
       TList (agent_opaque signatures loc "Tool")
     | EVar { name = "agentRun"; _ } when agent_form signatures "agentRun" "teslrt.AgentRun" ->
       (match args with
        | [agent; prompt; publisher] ->
          if type_unequal (type_of_expr signatures env agent)
               (agent_opaque signatures loc "Agent") then
            unsupported (Checker.expr_loc agent) "Go backend `agentRun` takes an Agent";
          if type_of_expr signatures env prompt <> TString then
            unsupported (Checker.expr_loc prompt) "Go backend `agentRun` takes a String prompt";
          agent_publisher_type signatures env loc "the `agentRun` publisher" publisher;
          agent_opaque signatures loc "AgentReply"
        | _ -> unsupported loc
          "Go backend `agentRun` takes an agent, a prompt and a publisher")
     | EVar { name = "converseStreaming"; _ }
       when agent_form signatures "converseStreaming" "teslrt.ConverseStreaming" ->
       (match args with
        | [conversation; prompt; publish] ->
          if type_unequal (type_of_expr signatures env conversation)
               (agent_opaque signatures loc "Conversation") then
            unsupported (Checker.expr_loc conversation)
              "Go backend `converseStreaming` takes a Conversation";
          if type_of_expr signatures env prompt <> TString then
            unsupported (Checker.expr_loc prompt)
              "Go backend `converseStreaming` takes a String prompt";
          agent_publisher_type signatures env loc "the `converseStreaming` publisher" publish;
          agent_opaque signatures loc "ConversationTurn"
        | _ -> unsupported loc
          "Go backend `converseStreaming` takes a conversation, a prompt and a publisher")
     | EVar { name = ("HttpClient.bearer" | "HttpClient.secretHeader") as leaf; _ } ->
       let signature = match Hashtbl.find_opt signatures leaf with
         | Some signature -> signature
         | None -> unsupported loc "Go backend cannot resolve function `%s`" leaf
       in
       let secret = match leaf, args with
         | "HttpClient.bearer", [secret] -> secret
         | "HttpClient.secretHeader", [name; secret] ->
           if type_of_expr signatures env name <> TString then
             unsupported (Checker.expr_loc name)
               "Go backend `HttpClient.secretHeader` takes a String header name";
           secret
         | _ -> unsupported loc "Go backend `%s` is applied to the wrong arity" leaf
       in
       (match type_of_expr signatures env secret with
        | TNewtype info when info.secret -> ()
        | TString -> ()
        | _ -> unsupported (Checker.expr_loc secret)
          "Go backend `%s` takes a `secret` over String" leaf);
       signature.result
     | EVar { name = ("expectJobOk" | "expectJobFailed") as verb; _ } ->
       (match args with
        | [result] ->
          (match type_of_expr signatures env result with
           (* `expectJobOk` answers the JOB; `expectJobFailed` answers the ERROR, which is a
              String — `tesl/api-test.rkt` returns `JobFailed-error` there, and answering the
              payload instead made `expect isNotNull err` compare a job struct. *)
           | TAdt (info, [payload]) when info.adt_tesl_name = "JobResult" ->
             if verb = "expectJobFailed" then TString else payload
           | _ -> unsupported loc
             "Go backend `expectJobOk` takes the result of `processNextJob`")
        | _ -> unsupported loc "Go backend requires `expectJobOk` applied to 1 argument")
     (* The api-test JSON surface.  Every one of these takes the UNTYPED value, and the
        argument order is Tesl's (needle/index/field first), matching tesl/api-test.rkt. *)
     | EVar { name = ("isNull" | "isNotNull" | "isEmpty" | "isNotEmpty"); _ } -> TBool
     | EVar { name = ("hasField" | "hasLength" | "jsonContains"
                     | "includesWhere" | "excludesWhere"); _ } -> TBool
     | EVar { name = "jsonLength"; _ } -> TInt
     | EVar { name = "jsonInt"; _ } -> TInt
     | EVar { name = "jsonString"; _ } -> TString
     | EVar { name = "jsonBool"; _ } -> TBool
     | EVar { name = ("arrayAt" | "fieldAt" | "bodyField" | "jsonArray" | "jsonObject"); _ } ->
       TJson
     | EVar { name = ("statusOk" | "statusClientError" | "statusServerError"); _ } -> TBool
      (* `Http.clearSessionCookie()` returns Unit and writes to the response. *)
      | EVar { name = "Http.clearSessionCookie"; _ } -> TUnit
      (* The session transport.  `setSessionCookie` writes the ONE blessed cookie (Unit, and it
         needs the response scope); `sessionToken` reads it back, so the fixed name is written
         down once instead of at every call site, where a typo is a permanent 401. *)
      | EVar { name = "Http.setSessionCookie"; _ } when args <> [] ->
        List.iter (fun arg -> ignore (type_of_expr signatures env arg)) args;
        TUnit
      | EVar { name = ("Http.sessionToken" | "responseCookie") as reader; _ } when args <> [] ->
        let inner = match reader with
          | "Http.sessionToken" ->
            (match Option.bind !current_types (fun types ->
                     Hashtbl.find_opt types.newtypes "JwtToken") with
             | Some info -> TNewtype info
             | None -> unsupported loc
               "Go backend `Http.sessionToken` needs `Tesl.JWT`'s `JwtToken` type")
          | _ -> TString
        in
        List.iter (fun arg -> ignore (type_of_expr signatures env arg)) args;
        (match adt_ctor_of_signature signatures "Nothing" with
         | Some (info, _) -> TAdt (info, [inner])
         | None -> unsupported loc
           "Go backend `%s` yields a Maybe; import `Tesl.Maybe`" reader)
      | EVar { name = ("detachFact" | "introAnd" | "andLeft" | "andRight"); _ } -> TUnit
      | EVar { name; _ } when higher_order_leaf name <> None && Hashtbl.mem signatures name ->
       let hof = match higher_order_leaf name with Some hof -> hof | None -> assert false in
       type_of_hof signatures env loc name hof args
      (* `List.range` and `List.repeat` CONSTRUCT a list rather than consuming one, so
         they carry no list argument for the leaf table to read an element type from.
         `range` is always `List Int`; `repeat` takes its element from its first
         argument.  Their counts carry an `IsNonNegative` proof that erases, so nothing
         about the count survives to the emitted call. *)
      | EVar { name = "List.range"; _ } when Hashtbl.mem signatures "List.range" ->
        if List.length args <> 2 then
          unsupported loc "Go backend requires `List.range` applied to 2 argument(s)";
        List.iter (fun arg ->
          if type_of_expr signatures env arg <> TInt then
            unsupported loc "Go backend `List.range` takes two Ints") args;
        TList TInt
      (* The `Tesl.Either` combinators.  Each is typed from its Either argument's two
         payloads; the three that take a FUNCTION are typed through the same
         `type_of_callable` every higher-order leaf uses. *)
      | EVar { name = ("Either.isLeft" | "Either.isRight" | "Either.fromLeft"
                      | "Either.fromRight" | "Either.toMaybe" | "Either.withDefault"
                      | "Either.fromMaybe" | "Either.map" | "Either.mapLeft"
                      | "Either.andThen") as name; _ } when Hashtbl.mem signatures name ->
        let arity = match name with
          | "Either.isLeft" | "Either.isRight" | "Either.fromLeft" | "Either.fromRight"
          | "Either.toMaybe" -> 1
          | _ -> 2
        in
        if List.length args <> arity then
          unsupported loc "Go backend requires `%s` applied to %d argument(s)" name arity;
        let maybe_of inner =
          match adt_ctor_of_signature signatures "Nothing" with
          | Some (info, _) -> TAdt (info, [inner])
          | None -> unsupported loc
            "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" name
        in
        let either_of left right =
          match adt_ctor_of_signature signatures "Left" with
          | Some (info, _) -> TAdt (info, [left; right])
          | None -> unsupported loc
            "Go backend `%s` returns an Either; import `Tesl.Either`" name
        in
        let payloads index =
          match type_of_expr signatures env (List.nth args index) with
          | TAdt (info, [left; right]) when info.adt_tesl_name = "Either" -> left, right
          | _ -> unsupported loc "Go backend `%s` requires an Either argument" name
        in
        (match name with
         | "Either.isLeft" | "Either.isRight" -> ignore (payloads 0); TBool
         | "Either.fromLeft" -> maybe_of (fst (payloads 0))
         | "Either.fromRight" | "Either.toMaybe" -> maybe_of (snd (payloads 0))
         | "Either.withDefault" ->
           let _, right = payloads 1 in
           let default_ty = type_of_arg signatures env right (List.nth args 0) in
           if type_unequal default_ty right then
             unsupported loc "Go backend `%s` default has an unsupported type" name;
           (* `Either.withDefault 99 (Left "err")` reads only the Left side, so the Either
              argument never says what a Right would hold.  The DEFAULT says, and it is the
              same value the call answers with. *)
           (match right with TAnon -> default_ty | settled -> settled)
         (* The one that takes a Maybe rather than an Either: the left value is what a
            Nothing has none of. *)
         | "Either.fromMaybe" ->
           (match type_of_expr signatures env (List.nth args 1) with
            | TAdt (info, [right]) when info.adt_tesl_name = "Maybe" ->
              either_of (type_of_expr signatures env (List.nth args 0)) right
            | _ -> unsupported loc "Go backend `%s` requires a Maybe argument" name)
         | "Either.map" ->
           let left, right = payloads 1 in
           either_of left (type_of_callable signatures env loc name (List.nth args 0) [right])
         | "Either.mapLeft" ->
           let left, right = payloads 1 in
           either_of (type_of_callable signatures env loc name (List.nth args 0) [left]) right
         | _ ->
           let left, right = payloads 1 in
           (match type_of_callable signatures env loc name (List.nth args 0) [right] with
            | TAdt (info, [inner_left; inner_right])
              when info.adt_tesl_name = "Either" && inner_left = left ->
              either_of left inner_right
            | _ -> unsupported loc
              "Go backend `%s` needs a function returning an Either with the same Left type"
              name))
      (* `Either.partition` consumes a list of Either and answers BOTH sides as a Tuple2, so
         its result mentions two element types rather than one — which is why it is not a
         list-leaf-table entry. *)
      | EVar { name = "Either.partition"; _ } when Hashtbl.mem signatures "Either.partition" ->
        if List.length args <> 1 then
          unsupported loc "Go backend requires `Either.partition` applied to 1 argument(s)";
        (* `Either.partition []` has no element to read either side from, and neither side is
           observable: the answer is two empty lists whatever they hold.  So the argument is
           typed as a list of Either with both sides anonymous rather than taking the empty
           list's Int default, which would read as "a list of Int" and be refused. *)
        let argument_type = match List.nth args 0 with
          | EList { elems = []; _ } ->
            (match adt_ctor_of_signature signatures "Left" with
             | Some (info, _) -> TList (TAdt (info, [TAnon; TAnon]))
             | None -> unsupported loc
               "Go backend `Either.partition` takes an Either; import `Tesl.Either`")
          | argument -> type_of_expr signatures env argument
        in
        (match argument_type with
         | TList (TAdt (info, [left; right])) when info.adt_tesl_name = "Either" ->
           (match Hashtbl.find_opt signatures "Tuple2" with
            | Some { result = TAdt (tuple, _); _ } ->
              TAdt (tuple, [TList left; TList right])
            | _ -> unsupported loc
              "Go backend needs `Tesl.Tuple` imported for `Either.partition`")
         | _ -> unsupported loc
           "Go backend `Either.partition` requires a List (Either a b) argument")
      | EVar { name = "List.repeat"; _ } when Hashtbl.mem signatures "List.repeat" ->
        if List.length args <> 2 then
          unsupported loc "Go backend requires `List.repeat` applied to 2 argument(s)";
        if type_of_expr signatures env (List.nth args 1) <> TInt then
          unsupported loc "Go backend `List.repeat` takes a count as its second argument";
        TList (type_of_expr signatures env (List.nth args 0))
      | EVar { name; _ } when list_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match list_leaf name with Some leaf -> leaf | None -> assert false in
       type_of_list_leaf signatures env loc leaf args
      (* Calling a FUNCTION VALUE — a parameter or a `let`-bound lambda.  Its type says the
         arity, and a partial application is refused rather than curried: Go has no partial
         application, and inventing a closure would hide the arity mismatch. *)
      | EVar { name; _ } when (match List.assoc_opt name env with
                               | Some (TFunc _) -> true | _ -> false) ->
        let params, result = match List.assoc_opt name env with
          | Some (TFunc (params, result)) -> params, result
          | _ -> assert false
        in
        if List.length args <> List.length params then
          unsupported loc
            "Go backend requires the function value `%s` applied to %d argument(s)"
            name (List.length params);
        List.iter2 (fun arg want ->
          if type_unequal (type_of_arg signatures env want arg) want then
            unsupported (Checker.expr_loc arg)
              "Go backend call through `%s` has an unsupported argument type" name)
          args params;
        result
      | EVar { name; _ } ->
       (match Hashtbl.find_opt signatures name with
        | None -> unsupported loc "Go backend cannot resolve function `%s`" name
        | Some signature ->
          let args = normalize_call_args signature.params args in
          let supplied = List.length args in
          let total = List.length signature.params in
          if supplied > total then
            unsupported loc "Go backend requires a fully-applied call to `%s`" name;
          if supplied < total then begin
            (* PARTIALLY applied: the arguments given are checked against the leading
               parameters, and the value is a function of the rest. *)
            if signature.sig_needs_scope then unsupported loc
              "Go backend cannot partially apply `%s`: it takes the request scope" name;
            if partial_application_combinator ~supplied ~total = None then
              unsupported loc
                "Go backend supports partial application up to three parameters; `%s` takes %d"
                name total
          end;
          (* A GENERIC callee is INSTANTIATED first: its type parameters are read off the
             argument types, and everything after that is the ordinary check against a
             parameter list with no variables left in it. *)
          let instantiated_params, instantiated_result =
            instantiated_call_types (type_of_expr signatures env) loc name signature args in
          let leading = List.filteri (fun index _ -> index < supplied) instantiated_params in
          List.iter2 (fun arg want ->
            let got = type_of_arg signatures env want arg in
            if type_unequal got want then unsupported (Checker.expr_loc arg)
              "Go backend call to `%s` has an unsupported argument type" name)
            args leading;
          if supplied = total then instantiated_result
          else
            (* CURRIED: `blend 1` is a function of `b` answering a function of `c`, not a
               two-argument function.  That is the surface's shape and the Racket runtime's —
               a flat `withA 2 3` is an arity error there — so a flat call to a partially
               applied value is refused here rather than quietly accepted. *)
            List.fold_right (fun param answer -> TFunc ([param], answer))
              (List.filteri (fun index _ -> index >= supplied) instantiated_params)
              instantiated_result)
     (* A call through any FUNCTION-VALUED expression — a record field holding one, say —
        not just through a name. *)
     | head when (match type_of_expr signatures env head with TFunc _ -> true | _ -> false) ->
       let params, result = match type_of_expr signatures env head with
         | TFunc (params, result) -> params, result
         | _ -> assert false
       in
       if List.length args <> List.length params then
         unsupported loc "Go backend requires this function value applied to %d argument(s)"
           (List.length params);
       List.iter2 (fun arg want ->
         if type_unequal (type_of_arg signatures env want arg) want then
           unsupported (Checker.expr_loc arg)
             "Go backend call through a function value has an unsupported argument type")
         args params;
       result
     | _ -> unsupported loc "Go backend supports calls to named functions only")
  | EBinop { op; left; right; loc; _ } ->
    (* A DEFAULTED empty list yields to a real type here for the same reason it does in an
       `if` branch: `List.reverse words == []` compares `List String`, not the default. *)
    let left_result, left_defaulted = typed_with_default (type_of_expr signatures env) left in
    let right_result, right_defaulted = typed_with_default (type_of_expr signatures env) right in
    let left_ty, right_ty = match left_result, right_result with
      | Some left_ty, Some right_ty when left_defaulted && not right_defaulted ->
        ignore left_ty; right_ty, right_ty
      | Some left_ty, Some right_ty when right_defaulted && not left_defaulted ->
        ignore right_ty; left_ty, left_ty
      | Some left_ty, Some right_ty -> left_ty, right_ty
      (* One side carries no type of its OWN — a bare `Nothing`, a nullary constructor of a
         generic ADT — so the other side's type instantiates it, the same rule an expectation
         applies at a call argument.  Without this, `maybeThing != Nothing` was refused while
         `maybeThing == Nothing` compiled, because only the `==` path routed the operands
         through the expectation. *)
      | Some left_ty, None -> left_ty, type_of_arg signatures env left_ty right
      | None, Some right_ty -> type_of_arg signatures env right_ty left, right_ty
      | _ ->
        (* Nothing to reconcile: re-type so the original error is reported. *)
        type_of_expr signatures env left, type_of_expr signatures env right
    in
    (* The MONEY-RATE algebra is the one place two different types multiply or divide, so it
       answers before the same-type rule below.  `money / quantity` needs its denominator
       named by the expectation, since a quantity is a Float here and carries no dimension —
       that is what a rate's declared type (`MoneyPerDuration`) is for. *)
    (* Quantity arithmetic answers a quantity, whatever mix of quantity and scalar it took. *)
    begin if quantity_binop op left_ty right_ty then TQuantity else
    match money_rate_binop op left_ty right_ty with
     | Some (`Consume | `ConsumeFlipped) ->
       (match Option.bind !current_types (fun types ->
                Hashtbl.find_opt types.records "Money") with
        | Some money -> TRecord money
        | None -> unsupported loc "Go backend needs `Money`; import `Tesl.Money`")
     | Some (`Scale | `ScaleFlipped) ->
       if is_money_rate left_ty then left_ty else right_ty
     | Some `Divide ->
       (* A quantity is a Float at run time and carries no dimension, so only the DECLARED
          type of the result says which unit the rate is per — which is what makes an
          unannotated `money / quantity` unemittable rather than merely unchecked. *)
       unsupported loc
         "Go backend needs the rate's declared type here (`MoneyPerDuration` and friends)"
     | None ->
    (* An UNTYPED api-test value compares against anything: `expect resp.body.age == 7` is
       the point of the dynamic view, and on Racket both sides are ordinary values by then.
       Only equality is allowed — ordering an untyped value has no meaning the source can
       rely on. *)
    if (left_ty = TJson || right_ty = TJson) && type_unequal left_ty right_ty then begin
      match op with
      | BEq | BNeq -> ()
      (* `"payload: " ++ r.body` splices the STRING the JSON holds, which is the coercion
         the concat emitter already applies to that side — the same rule that lets an
         api-test build a path out of a value read from a previous response. *)
      | BConcat -> ()
      | _ -> unsupported loc
        "Go backend supports `==` / `!=` / `++` on an api-test JSON value, not this operator"
    end
    else if type_unequal left_ty right_ty then
      unsupported loc "Go backend binary operands have different types";
    (match op with
     | BAdd | BSub | BMul | BDiv ->
       (match left_ty with
        | TInt -> TInt
        | TFloat -> TFloat
        | _ -> unsupported loc "Go backend arithmetic requires Int or Float")
     | BMod ->
       (* Racket's `modulo`/`remainder` are integer operations; a Float `%` does not
          exist in Go either. *)
       if left_ty <> TInt then unsupported loc "Go backend `%%` requires Int";
       TInt
     | BConcat ->
       (* An api-test may build a path out of a value read from a previous RESPONSE
          (`"/things/" ++ created.body.id`).  That side is untyped JSON by design, and it is
          the STRING it holds that belongs in the path — the same coercion Racket applies when
          it splices a body field into a path. *)
       if left_ty <> TString && left_ty <> TJson then
         unsupported loc "Go backend ++ requires String";
       TString
     | BAnd | BOr ->
       if left_ty <> TBool then unsupported loc "Go backend boolean operator requires Bool";
       TBool
     | BEq | BNeq ->
       (* A generic ADT (or anything holding a type parameter) has no comparable Go
          form, so equality on it fails closed rather than reaching the emitter. *)
       if not (supports_equality left_ty) then unsupported loc
         "Go backend does not support equality on this type yet";
       TBool
      | BLt | BLe | BGt | BGe ->
        if not (supports_ordering left_ty) then
          unsupported loc "Go backend ordering supports Int, String, and their scalar newtypes only";
        TBool)
    end
  | EUnop { op; arg; loc } ->
    let arg_ty = type_of_expr signatures env arg in
    (match op with
     | UNeg ->
       (match arg_ty with
        | TInt -> TInt
        | TFloat -> TFloat
        (* Negating a quantity keeps its dimension: -length is a length. *)
        | TQuantity -> TQuantity
        | _ -> unsupported loc "Go backend unary - requires Int or Float")
     | UNot -> if arg_ty <> TBool then unsupported loc "Go backend ! requires Bool"; TBool)
  | EIf { cond; then_; else_; loc } ->
    if type_of_expr signatures env cond <> TBool then
      unsupported loc "Go backend if condition must be Bool";
    (* A branch can be UNDER-CONSTRAINED on its own while the other settles the type —
       `if isEmpty s then [] else [s]`, the body of a `concatMap` lambda.  Whichever branch
       types supplies the type, and the other is then checked against it through
       `type_of_arg`, which is the expectation the emitter passes down anyway.  Same
       tolerance as `case` arms; if NEITHER branch types, the first one is re-typed so the
       real reason is what gets reported. *)
    let attempt expr = typed_with_default (type_of_expr signatures env) expr in
    let then_result, then_defaulted = attempt then_ in
    let else_result, else_defaulted = attempt else_ in
    (match then_result, else_result with
     | Some TFailure, Some TFailure -> TFailure
     | Some TFailure, Some ty | Some ty, Some TFailure -> ty
     (* A DEFAULTED branch yields to a real type: `if c then [] else ["a"]`. *)
     | Some _, Some ty when then_defaulted && not else_defaulted -> ty
     | Some ty, Some _ when else_defaulted && not then_defaulted -> ty
     | Some left, Some right when type_equal left right -> left
     | Some _, Some _ -> unsupported loc "Go backend if branches have different types"
     | Some ty, None | None, Some ty ->
       let other = if then_result = None then then_ else else_ in
       if type_unequal (type_of_arg signatures env ty other) ty then
         unsupported loc "Go backend if branches have different types";
       ty
     | None, None -> type_of_expr signatures env then_)
  | ELet { name; value; body; _ } ->
    let value_ty = type_of_expr signatures env value in
    type_of_expr signatures ((name, value_ty) :: env) body
  (* `Set.empty` takes no arguments, so it parses as a bare field access over the module
     name rather than a call.  Normalising it here lets the leaf tables resolve it. *)
  | EField _ when (match normalize_call_head expr with
                   | EVar { name; _ } ->
                     (set_leaf name <> None || dict_leaf name <> None)
                     && Hashtbl.mem signatures name
                   | _ -> false) ->
    (match normalize_call_head expr with
     | EVar { name; loc } ->
       (match set_leaf name, dict_leaf name with
        | Some leaf, _ -> type_of_set_leaf signatures env loc leaf [] None
        | _, Some leaf -> type_of_dict_leaf signatures env loc leaf []
        | None, None -> assert false)
     | _ -> assert false)
  (* `Int32.minValue` is a stdlib VALUE written with a dot, so it parses as a field read over
     the module name — the same shape `normalize_call_head` fixes in call position.  Nothing
     else reaches here with a bare module name as the object. *)
  | EField { obj = EConstructor { name = module_name; args = []; _ }; field; _ }
    when Option.bind !current_types (fun types ->
           Hashtbl.find_opt types.consts (module_name ^ "." ^ field)) <> None ->
    (match Option.bind !current_types (fun types ->
             Hashtbl.find_opt types.consts (module_name ^ "." ^ field)) with
     | Some (ty, _) -> ty
     | None -> assert false)
  | EField { obj; field; loc } ->
    (match type_of_expr signatures env obj, field with
     | TNewtype info, "value" -> info.base
     | TNewtype info, _ ->
       unsupported loc "Go backend newtype `%s` has no field `%s`" info.tesl_name field
     | TRecord info, _ -> record_field_type loc info field
     (* A field read on an UNTYPED JSON value stays untyped: `resp.body.user.id` is a chain
        of dynamic reads, and a missing key is null rather than an error — the same shape
        `api-test-field-access-ref` gives on Racket. *)
     | TJson, _ -> TJson
     | _ -> unsupported loc "Go backend does not support field `%s` yet" field)
  | ECase { scrut; arms; loc } ->
    let scrut_ty = type_of_expr signatures env scrut in
    let info, type_args = match scrut_ty with
      | TAdt (info, args) -> info, args
      | ty when scalar_case_type ty ->
        (* Handled by the scalar path below; these are never read. *)
        adt_placeholder_info, []
      | _ -> unsupported loc
        "Go backend supports `case` over a module ADT or a scalar (Int, String, Bool)"
    in
    if arms = [] then unsupported loc "Go backend requires at least one `case` arm";
    let arm_envs = List.map (fun (arm : case_arm) ->
      let bindings =
        if scalar_case_type scrut_ty then scalar_pattern_bindings loc scrut_ty arm.pattern
        else pattern_bindings loc info type_args arm.pattern in
      let arm_env = bindings @ env in
      (match arm.guard with
       | None -> ()
       | Some guard ->
         if type_of_expr signatures arm_env guard <> TBool then
           unsupported (Checker.expr_loc guard) "Go backend `case` guard must be Bool");
      arm_env, arm) arms in
    (* An arm can be UNDER-CONSTRAINED on its own while a sibling settles the case's
       type: `case … of Nothing -> Nothing | Something x -> Something (x + 1)` — a bare
       `Nothing` carries no type argument, but the other arm gives `Maybe Int`.  Such an
       arm is skipped here and later emitted against the resolved type, the same way an
       `if` branch is.  Nothing is lost by skipping: every arm is still emitted, so an arm
       that is genuinely unsupported raises there instead. *)
    let arm_results = List.map (fun (arm_env, (arm : case_arm)) ->
      typed_with_default (type_of_expr signatures arm_env) arm.body) arm_envs in
    (* A defaulted arm yields to a real one, for the same reason an `if` branch does. *)
    let has_real = List.exists (fun (result, defaulted) -> result <> None && not defaulted)
      arm_results in
    let arm_types = List.map (fun (result, defaulted) ->
      if has_real && defaulted then None else result) arm_results in
    (match List.filter_map (fun ty -> ty) arm_types with
     | [] ->
       (* No arm types on its own — report from the first, which raises the real reason. *)
       (match arm_envs with
        | (arm_env, arm) :: _ -> type_of_expr signatures arm_env arm.body
        | [] -> unsupported loc "Go backend requires at least one `case` arm")
     | types ->
       List.fold_left (fun acc ty ->
         match acc, ty with
         | TFailure, ty | ty, TFailure -> ty
         | left, right when type_equal left right -> left
         | _ -> unsupported loc "Go backend `case` arms have different types")
         TFailure types)
  (* `let (v ::: pf) = y` DECOMPOSES a proof-carrying value: `v` is the value and `pf` the
     proof, which erases like every other proof (LANGUAGE-SPEC 16.9 gives a proof no runtime
     structure).  So the binding is the value itself and `pf` is the zero-size proof value —
     it exists because later code names it, e.g. `attachFact x pf`. *)
  | ELetProof { value_name; proof_name; value; body; _ } ->
    let value_ty = type_of_expr signatures env value in
    type_of_expr signatures
      ((proof_name, TUnit) :: (value_name, value_ty) :: env) body
  | ERecord { type_hint = Some name; fields; loc } ->
    (match record_info_of_signature signatures name with
     | Some info -> check_record_literal signatures env loc info fields; TRecord info
     | None -> unsupported loc "Go backend does not support record type `%s` yet" name)
  | ERecord { type_hint = None; loc; _ } ->
    unsupported loc "Go backend cannot infer the record type of this literal"
  (* An empty list literal whose element type NOTHING constrains.  Every path that can
     supply one runs first — an expectation from the call argument, the function's return
     type, a `let` tail, an `if` branch, a `case` arm, a sibling element, a fold's callback
     or accumulator, a leaf's own signature — so reaching here means the program genuinely
     never says what the list would hold: `expect List.reverse [] == []`, where both sides
     are empty.
     Such a program is legal Tesl and Racket runs it, so refusing to compile the module
     over it is a divergence with no upside (maintainer, 2026-08-13).  The element type is
     unobservable in exactly this situation — the list has no elements to read — and if the
     surrounding context did demand a specific type, Go's own type checker rejects the
     emitted code at build time rather than letting a wrong choice ship silently. *)
  | EList { elems = []; _ } -> used_empty_default := true; TList TInt
  | EList { elems; loc } ->
    (* An element may be under-constrained on its own — a nested `[]`, a bare `Nothing` —
       while its SIBLINGS settle the element type: `[[1, 2], [], [3]]`.  So the type comes
       from the first element that types, and the rest are checked AGAINST it through
       `type_of_arg`, which is the same expectation the emitter passes down per element.
       If no element types on its own, the first one is re-typed to report the real
       reason. *)
    let inferred = List.fold_left (fun found elem ->
      match found with
      | Some _ -> found
      | None ->
        (match typed_with_default (type_of_expr signatures env) elem with
         | Some ty, false -> Some ty
         | _ -> None))
      None elems in
    (* Nothing but defaulted elements: take the default rather than failing. *)
    let inferred = match inferred with
      | Some _ -> inferred
      | None -> fst (typed_with_default (type_of_expr signatures env) (List.hd elems))
    in
    let element = match inferred with
      | Some element -> element
      | None -> type_of_expr signatures env (List.hd elems)
    in
    (* An element that types may still leave an ADT argument anonymous, and a LATER element
       may be the one that settles it.  Only walked when there is something to settle. *)
    let element =
      if not (has_anon element) then element
      else List.fold_left (fun found elem ->
        if not (has_anon found) then found
        else match typed_with_default (type_of_expr signatures env) elem with
          | Some ty, false -> merge_anon found ty
          | _ -> found) element elems
    in
    List.iter (fun elem ->
      if type_unequal (type_of_arg signatures env element elem) element then
        unsupported (Checker.expr_loc elem)
          "Go backend list literal elements have different types") elems;
    ignore loc;
    TList element
  (* `ok value ::: P` and the bare attachment `value ::: proof` are the same NODE, and the
     spelling is what says which is meant: the first is a check's answer (a `Check`), the second
     an ordinary value whose proof erases.  Reading both as a `Check` made
     `let reat = v ::: proof` a `Check[Int]` and the next call rejected its own argument;
     reading both as the value made `let outcome = if … then ok n ::: P else fail …` an `Int`
     where the check's result type was required.  The parser records the spelling. *)
  | EOk { value; keyword = false; _ } -> type_of_expr signatures env value
  | EOk { value; _ } -> TCheck (type_of_expr signatures env value)
  | EFail { message; loc; _ } ->
    if type_of_expr signatures env message <> TString then
      unsupported loc "Go backend check failure message must be String";
    TFailure
  (* `with database D { … }` names the store the body's queries run against.  With
     `backend: Memory` that store IS the entity's table variable, so the block adds
     nothing at run time and types as its body. *)
  | EWithDatabase { body; _ } -> type_of_expr signatures env body
  (* `enqueue` is a statement: the job id stays inside the store, as it does on Racket. *)
  | EEnqueue { payload; _ } -> ignore (type_of_expr signatures env payload); TUnit
  (* A `telemetry "name" { … }` block is a STATEMENT: it records a signal and answers Unit, so a
     function carrying one has the type it would have without it — which is the property every
     telemetry test in the corpus asserts. *)
  | ETelemetry { fields; _ } ->
    List.iter (fun (_, value) -> ignore (type_of_expr signatures env value)) fields;
    TUnit
  (* The startup chain `main` lowers to.  A capability scope is compile-time only, so it types
     as its body; `startWorkers` and `serve` are statements. *)
  | EWithCapabilities { body; _ } -> type_of_expr signatures env body
  | EStartWorkers _ -> TUnit
  | EServe { port; _ } -> ignore (type_of_expr signatures env port); TUnit
  (* The `Tesl.Cache` operations.  Each names a DECLARED cache, so the value type comes from
     the declaration rather than from the call site: `Cache.get C k` answers
     `Maybe <valueType>` whatever the caller expected, which is what keeps a miss and a
     wrong-shaped hit different things. *)
  | ECacheGet { cache_name; key; loc } ->
    let info = cache_of_name loc cache_name in
    if type_of_expr signatures env key <> TString then
      unsupported loc "Go backend `Cache.get` takes a String key";
    (match adt_ctor_of_signature signatures "Nothing" with
     | Some (maybe, _) -> TAdt (maybe, [info.ca_value])
     | None -> unsupported loc "Go backend `Cache.get` answers a Maybe; import `Tesl.Maybe`")
  | ECacheSet { cache_name; key; value; ttl; loc } ->
    let info = cache_of_name loc cache_name in
    if type_of_expr signatures env key <> TString then
      unsupported loc "Go backend `Cache.set` takes a String key";
    if type_unequal (type_of_arg signatures env info.ca_value value) info.ca_value then
      unsupported loc "Go backend `Cache.set` value does not match cache `%s`'s declared type"
        cache_name;
    (match ttl with
     | Some ttl when type_of_expr signatures env ttl <> TInt ->
       unsupported loc "Go backend `Cache.set` takes a TTL in whole seconds"
     | _ -> ());
    TUnit
  | ECacheDelete { cache_name; key; loc } ->
    ignore (cache_of_name loc cache_name);
    if type_of_expr signatures env key <> TString then
      unsupported loc "Go backend `Cache.delete` takes a String key";
    TUnit
  | ECacheInvalidate { cache_name; prefix; loc } ->
    ignore (cache_of_name loc cache_name);
    if type_of_expr signatures env prefix <> TString then
      unsupported loc "Go backend `Cache.invalidate` takes a String prefix";
    TUnit
  (* `Email.send E { to: … subject: … body: … }` ENQUEUES: it answers Unit, and the worker is
     what delivers.  The recipient and the subject are header-bound, so both are Strings and
     nothing else — a value that had to be rendered first would be rendered by whose rules? *)
  | ESendEmail { email_name; to_; subject; body; loc } ->
    ignore (email_of_name loc email_name);
    if type_of_expr signatures env to_ <> TString then
      unsupported loc "Go backend `Email.send` takes a String recipient";
    if type_of_expr signatures env subject <> TString then
      unsupported loc "Go backend `Email.send` takes a String subject";
    (match type_of_expr signatures env body with
     | TAdt (info, []) when info.adt_tesl_name = "EmailBody" -> ()
     | _ -> unsupported loc
       "Go backend `Email.send` takes an `EmailBody`; import `Tesl.Email exposing [EmailBody(..)]`");
    TUnit
  | EStartEmailWorker { email_name; loc } ->
    ignore (email_of_name loc email_name);
    TUnit
  (* `transaction { … }` types as its body: the block groups statements, it does not produce a
     value of its own. *)
  | EWithTransaction { body; _ } -> type_of_expr signatures env body
  (* `publish C(key) Payload { … }` answers Unit: it hands the event to the listeners on that
     key and returns, which is what keeps a handler's latency independent of its subscribers. *)
  | EPublish { channel_name; key; event_ctor; payload; loc } ->
    let info = channel_of_name loc channel_name in
    (match key with
     | Some key_expr ->
       if info.ch_key_params = 0 then unsupported loc
         "Go backend channel `%s` takes no key" channel_name;
       if type_of_expr signatures env key_expr <> TString then unsupported loc
         "Go backend channel key must be a String"
     | None ->
       if info.ch_key_params <> 0 then unsupported loc
         "Go backend channel `%s` needs its key" channel_name);
    (match payload with
     | Some payload_expr ->
       let built = publish_payload_expr signatures loc event_ctor payload_expr in
       if type_unequal (type_of_arg signatures env info.ch_payload built) info.ch_payload then
         unsupported loc "Go backend payload does not match channel `%s`'s declared type"
           channel_name
     | None -> unsupported loc "Go backend requires a payload for `publish %s`" channel_name);
    TUnit
  (* A LAMBDA's type comes from its annotated parameters plus its inferred body.  Tesl
     requires the annotation, so nothing is guessed. *)
  | ELambda { params; body; loc } ->
    let types = match !current_types with
      | Some types -> types
      | None -> unsupported loc "Go backend cannot resolve a lambda's parameter types here"
    in
    let param_types = List.map (fun (binding : binding) ->
      type_of_type_expr types binding.type_expr) params in
    let lambda_env =
      List.map2 (fun (binding : binding) ty -> binding.name, ty) params param_types @ env in
    TFunc (param_types, type_of_expr signatures lambda_env body)

(* A nullary constructor of a generic ADT carries no argument to infer its type
   arguments from (`Empty` for `Labeled a`), so where a type is expected — a call
   argument — that expectation instantiates it.  Anywhere else it fails closed. *)
(* Types a list-leaf call from the element type of its list argument.  The same table
   drives emission, so arity and argument order cannot drift between the two. *)
and type_of_list_leaf signatures env loc leaf args =
  if List.length args <> leaf.leaf_arity then
    unsupported loc "Go backend requires `%s` applied to %d argument(s)"
      leaf.leaf_name leaf.leaf_arity;
  (* Two kinds of leaf can accept an EMPTY list literal with nothing to infer from.
     `List.sum` has the element FIXED by its own signature (`List Int`).  `List.isEmpty`
     and `List.length` return a Bool/Int, so the element type is UNOBSERVABLE: the emitted
     call behaves identically whatever it is, and picking one cannot change a result.
     A leaf whose result mentions the element (`List.reverse []`) is NOT in this set — there
     the choice would be a guess, so it still fails closed. *)
  let fixed_element = match leaf.leaf_name, leaf.leaf_result with
    | ("List.sum" | "List.product" | "List.isEmpty" | "List.length"), _ -> Some TInt
    (* `concat []`/`flatten []` take a list OF LISTS, so the default has to be one. *)
    | _, `Inner -> Some (TList TInt)
    | _ -> None
  in
  let arg_types = List.mapi (fun index arg ->
    match arg, fixed_element with
    | EList { elems = []; _ }, Some element when index = leaf.leaf_list_index -> TList element
    | _ -> type_of_expr signatures env arg) args in
  let element = match List.nth arg_types leaf.leaf_list_index with
    | TList element -> element
    | _ -> unsupported loc "Go backend `%s` requires a List argument" leaf.leaf_name
  in
  (* The non-list argument is the element itself (member/contains) or a count. *)
  List.iteri (fun index arg_ty ->
    if index <> leaf.leaf_list_index then begin
      let want = match leaf.leaf_name with
        | "List.take" | "List.drop" -> TInt
        | "List.append" -> TList element
        | _ -> element
      in
      if type_unequal arg_ty want then unsupported loc
        "Go backend `%s` argument %d has an unsupported type" leaf.leaf_name (index + 1)
    end) arg_types;
  if (leaf.leaf_name = "List.sum" || leaf.leaf_name = "List.product") && element <> TInt then
    unsupported loc "Go backend `%s` requires a List Int" leaf.leaf_name;
  (match leaf.leaf_closure with
   | `Equal ->
     if not (supports_equality element) then unsupported loc
       "Go backend `%s` needs comparable elements" leaf.leaf_name
   | `Less ->
     if not (supports_ordering element) then unsupported loc
       "Go backend `%s` needs ordered elements" leaf.leaf_name
   | `None -> ());
  let maybe_of inner =
    match adt_ctor_of_signature signatures "Nothing" with
    | Some (info, _) -> TAdt (info, [inner])
    | None -> unsupported loc
      "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" leaf.leaf_name
  in
  (match leaf.leaf_result with
   | `Int -> TInt
   | `Bool -> TBool
   | `Same -> TList element
   | `MaybeElement -> maybe_of element
   | `MaybeSame -> maybe_of (TList element)
   | `Inner ->
     (match element with
      | TList inner -> TList inner
      | _ -> unsupported loc "Go backend `%s` requires a List of Lists" leaf.leaf_name))

(* A function ARGUMENT is either a lambda (whose parameter types come from the call
   site, so the declared annotations need no resolving here) or a named function. *)
and type_of_callable signatures env loc what callable param_types =
  match callable with
  (* A COMBINED check passed as the callback: `List.allCheck (isPositive && isSmall) xs`.
     Every conjunct checks the same type and the result is that type's `Check`, exactly as
     for `check (a && b) x` — the difference is only where it is applied. *)
  (* A conjunction whose conjuncts may be PARTIALLY APPLIED — `checkAtLeast 0 &&
     checkAtMost 100`.  The supplied arguments belong to the call site; what has to hold of
     each conjunct is that its LAST parameter and its result are the element type, which is
     what makes the sequencing well-formed. *)
  | EBinop { op = BAnd; _ } when (match check_conjunct_calls callable with
                                  | Some (_ :: _ :: _) -> true | _ -> false) ->
    let calls = Option.value (check_conjunct_calls callable) ~default:[] in
    let element = match param_types with
      | [element] -> element
      | _ -> unsupported loc "Go backend `%s` applies a combined check to one value" what
    in
    List.iter (fun (name, supplied) ->
      match Hashtbl.find_opt signatures name with
      | Some { params; result = TCheck result; _ }
        when List.length params = List.length supplied + 1
             && (match List.rev params with subject :: _ -> subject = element | [] -> false)
             && result = element ->
        List.iteri (fun index argument ->
          let want = List.nth params index in
          if type_unequal (type_of_arg signatures env want argument) want then
            unsupported (Checker.expr_loc argument)
              "Go backend combined check `%s` argument %d has an unsupported type"
              name (index + 1)) supplied
      | Some { result = TCheck _; _ } -> unsupported loc
        "Go backend combined check `%s` does not check the same type as the others" name
      | Some _ -> unsupported loc "`%s` is not a check" name
      | None -> unsupported loc "Go backend cannot resolve check `%s`" name) calls;
    TCheck element
  | ELambda { params; body; _ } ->
    if List.length params <> List.length param_types then
      unsupported loc "Go backend `%s` needs a %d-parameter function" what
        (List.length param_types);
    let env = List.map2 (fun (binding : binding) ty -> binding.name, ty) params param_types @ env in
    type_of_expr signatures env body
  | EVar { name; _ } ->
    (match Hashtbl.find_opt signatures name with
     | Some signature ->
       if signature.params <> param_types then unsupported loc
         "Go backend `%s` function argument has unsupported parameter types" what;
       signature.result
     (* A LOCAL holding a function — `let addThree = add28 3` then `List.map addThree xs`.
        It is not in the signature table because it is not a declaration; the binding's own
        type is what says it can be called. *)
     | None ->
       (match List.assoc_opt name env with
        | Some (TFunc (params, result)) ->
          if params <> param_types then unsupported loc
            "Go backend `%s` function argument has unsupported parameter types" what;
          result
        | _ -> unsupported loc "Go backend cannot resolve function `%s`" name))
  | EApp _ ->
    (* A partial application supplied AT the call site — `List.filterCheck (checkFn
       arg) xs`.  The loop supplies the remaining arguments, so this needs no general
       function-value support: the emitted call is still fully applied. *)
    let head, supplied = flatten_app [] callable in
    let head = normalize_call_head head in
    (match head with
     | EVar { name; _ } ->
       (match Hashtbl.find_opt signatures name with
        | Some signature ->
          let count = List.length supplied in
          if count >= List.length signature.params then unsupported loc
            "Go backend `%s` function argument is already fully applied" what;
          let prefix = List.filteri (fun index _ -> index < count) signature.params in
          let rest = List.filteri (fun index _ -> index >= count) signature.params in
          List.iter2 (fun arg want ->
            if type_unequal (type_of_expr signatures env arg) want then unsupported loc
              "Go backend `%s` partial application argument type mismatch" what)
            supplied prefix;
          if rest <> param_types then unsupported loc
            "Go backend `%s` function argument has unsupported parameter types" what;
          signature.result
        | None -> unsupported loc "Go backend cannot resolve function `%s`" name)
     | _ -> unsupported loc "Go backend `%s` takes a lambda or a named function" what)
  | _ ->
    unsupported loc "Go backend `%s` takes a lambda or a named function" what

and type_of_hof signatures env loc what hof args =
  if List.length args <> hof_arity hof then
    unsupported loc "Go backend requires `%s` applied to %d argument(s)" what (hof_arity hof);
  (* A stdlib function passed as the callback — `List.sortBy String.length words` — parses
     as a field access over the module name, so it is normalised to the resolvable name
     before anything tries to treat it as a callable. *)
  let args = match args with
    | callable :: rest -> normalize_call_head callable :: rest
    | [] -> args
  in
  (* Where the CALLBACK declares the element type.  `foldl` takes (accumulator, element)
     and `foldr` takes (element, accumulator); every other leaf's callback takes the
     element first. *)
  let element_position = match hof with HofFoldl -> 1 | _ -> 0 in
  let element_from_callable () =
    match List.nth args 0 with
    | ELambda { params; _ } ->
      (match !current_types, List.nth_opt params element_position with
       | Some types, Some (binding : binding) ->
         (try Some (type_of_type_expr types binding.type_expr) with Unsupported _ -> None)
       | _ -> None)
    | EVar { name; _ } ->
      (match Hashtbl.find_opt signatures name with
       | Some signature -> List.nth_opt signature.params element_position
       | None -> None)
    | _ -> None
  in
  (* `List.map f []` and friends: an EMPTY list literal carries no element type, and the
     callback's declared parameter is what says what the list would have held. *)
  let list_of index =
    match List.nth args index with
    | EList { elems = []; _ } when element_from_callable () <> None ->
      (match element_from_callable () with Some element -> element | None -> assert false)
    | arg ->
      (match type_of_expr signatures env arg with
       | TList element -> element
       | _ -> unsupported loc "Go backend `%s` requires a List argument" what)
  in
  match hof with
  | HofMap ->
    let element = list_of 1 in
    TList (type_of_callable signatures env loc what (List.nth args 0) [element])
  | HofFilter | HofAny | HofAll ->
    let element = list_of 1 in
    if type_of_callable signatures env loc what (List.nth args 0) [element] <> TBool then
      unsupported loc "Go backend `%s` needs a Bool-returning function" what;
    (match hof with HofFilter -> TList element | _ -> TBool)
  | HofFind ->
    let element = list_of 1 in
    if type_of_callable signatures env loc what (List.nth args 0) [element] <> TBool then
      unsupported loc "Go backend `%s` needs a Bool-returning function" what;
    (match adt_ctor_of_signature signatures "Nothing" with
     | Some (info, _) -> TAdt (info, [element])
     | None -> unsupported loc
       "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" what)
  (* `filterMap`'s callback returns `Maybe b`, and the result is `List b`: the element is
     kept when the TAG is Something, never by the payload's truthiness — Racket's own
     implementation got that wrong and dropped `Something False`. *)
  | HofFilterMap ->
    let element = list_of 1 in
    (match type_of_callable signatures env loc what (List.nth args 0) [element] with
     | TAdt (info, [inner]) when info.adt_tesl_name = "Maybe" -> TList inner
     | _ -> unsupported loc "Go backend `%s` needs a Maybe-returning function" what)
  | HofConcatMap ->
    let element = list_of 1 in
    (match type_of_callable signatures env loc what (List.nth args 0) [element] with
     | TList inner -> TList inner
     | _ -> unsupported loc "Go backend `%s` needs a List-returning function" what)
  (* `sortBy` orders by a KEY function rather than a comparator, and the key is what has
     to be ordered.  The result keeps the element type (and mints `IsSorted`, which
     erases). *)
  | HofSortBy ->
    let element = list_of 1 in
    let key = type_of_callable signatures env loc what (List.nth args 0) [element] in
    if not (supports_ordering key) then unsupported loc
      "Go backend `%s` needs a key function returning an ordered type" what;
    TList element
  | HofZip ->
    let left = list_of 0 and right = list_of 1 in
    (match Hashtbl.find_opt signatures "Tuple2" with
     | Some { result = TAdt (info, _); _ } -> TList (TAdt (info, [left; right]))
     | _ -> unsupported loc
       "Go backend needs `Tesl.Tuple` imported for `%s`" what)
  (* The element type comes from the CHECK, since there is no list to read it from. *)
  (* The element type is the CHECK's own parameter type: there is no list to read it from, and
     probing the callable against a made-up argument type would reject the very check that names
     it.  A lambda is refused for the same reason — its parameter annotation is the only thing
     that could say, and a `check` cannot be written as one. *)
  | HofEmptyForAll ->
    (* A CONJUNCTION names the element type through its first conjunct: every conjunct
       checks the same type, which is what makes the sequencing well-formed at all. *)
    let named = match check_conjunct_calls (List.nth args 0) with
      | Some ((first, _) :: _) -> Some first
      | _ ->
        (match normalize_call_head (List.nth args 0) with
         | EVar { name; _ } -> Some name
         | _ -> None)
    in
    (match named with
     | Some name ->
       (match Hashtbl.find_opt signatures name with
        | Some { params = [element]; result = TCheck checked; _ } when checked = element ->
          TList element
        | _ -> unsupported loc
          "Go backend `%s` takes a named `check` function over the element type" what)
     | None -> unsupported loc "Go backend `%s` takes a named `check` function" what)
  (* `List.count p xs` answers how many elements satisfy p — a Bool-returning function, like
     `filter`, but nothing is kept. *)
  | HofCount ->
    let element = list_of 1 in
    if type_of_callable signatures env loc what (List.nth args 0) [element] <> TBool then
      unsupported loc "Go backend `%s` needs a Bool-returning function" what;
    TInt
  | HofSetFilterCheck | HofSetAllCheck ->
    let element = match type_of_expr signatures env (List.nth args 1) with
      | TSet element -> element
      | _ -> unsupported loc "Go backend `%s` requires a Set argument" what
    in
    let result = type_of_callable signatures env loc what (List.nth args 0) [element] in
    if result <> TCheck element then unsupported loc
      "Go backend `%s` takes a `check` function over the element type" what;
    (match hof with
     | HofSetFilterCheck -> TSet element
     (* `allCheck` answers the whole set or nothing at all — the Maybe IS the verdict. *)
     | _ ->
       (match adt_ctor_of_signature signatures "Nothing" with
        | Some (info, _) -> TAdt (info, [TSet element])
        | None -> unsupported loc
          "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" what))
  (* The check runs on the VALUE; the key rides along untouched, so the result is a dict of
     the same type. *)
  | HofDictFilterCheckValues | HofDictFilterCheckKeys ->
    let key, value = match type_of_expr signatures env (List.nth args 1) with
      | TDict (key, value) -> key, value
      | _ -> unsupported loc "Go backend `%s` requires a Dict argument" what
    in
    let checked = match hof with HofDictFilterCheckKeys -> key | _ -> value in
    let result = type_of_callable signatures env loc what (List.nth args 0) [checked] in
    if result <> TCheck checked then unsupported loc
      "Go backend `%s` takes a `check` function over the %s type" what
      (match hof with HofDictFilterCheckKeys -> "key" | _ -> "value");
    if not (supports_ordering key) then unsupported loc
      "Go backend `%s` needs ordered keys" what;
    TDict (key, value)
  | HofFilterCheck | HofAllCheck ->
    let element = list_of 1 in
    let result = type_of_callable signatures env loc what (List.nth args 0) [element] in
    if result <> TCheck element then unsupported loc
      "Go backend `%s` takes a `check` function over the element type" what;
    (match hof with
     | HofFilterCheck -> TList element
     | _ ->
       (match adt_ctor_of_signature signatures "Nothing" with
        | Some (info, _) -> TAdt (info, [TList element])
        | None -> unsupported loc
          "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" what))
  | HofFoldl | HofFoldr ->
    let element = list_of 2 in
    (* An EMPTY list literal as the initial accumulator carries no element type of its
       own, and it is the idiomatic init for a fold that rebuilds a list
       (`List.foldr prependInt [] ns`).  A NAMED callback settles it: the fold requires
       f's result to BE the accumulator, so the declared result type is the accumulator
       type.  A lambda's parameter annotations are not in scope here, so a lambda with a
       bare `[]` still fails closed rather than guessing. *)
    let declared_accumulator () =
      let resolve name = match Hashtbl.find_opt signatures name with
        | Some signature -> Some signature.result
        | None -> None
      in
      match List.nth args 0 with
      | EVar { name; _ } -> resolve name
      | EApp _ ->
        let head, _ = flatten_app [] (List.nth args 0) in
        (match normalize_call_head head with
         | EVar { name; _ } -> resolve name
         | _ -> None)
      | _ -> None
    in
    (* A lambda annotates its parameters, so the accumulator position says what the
       empty init cannot. *)
    let annotated_accumulator () =
      match List.nth args 0, !current_types with
      | ELambda { params; _ }, Some types ->
        let position = match hof with HofFoldr -> 1 | _ -> 0 in
        (match List.nth_opt params position with
         | Some (binding : binding) ->
           (try Some (type_of_type_expr types binding.type_expr) with Unsupported _ -> None)
         | None -> None)
      | _ -> None
    in
    (* `Dict.empty`/`Set.empty` as the init are the same case as `[]`: an empty container
       written in place carries no key/element type, and the callback's accumulator is what
       says what it would have held. *)
    let untyped_init = match normalize_call_head (List.nth args 1) with
      | EList { elems = []; _ } -> true
      | EVar { name = ("Dict.empty" | "Set.empty"); _ } -> true
      | _ -> false
    in
    let accumulator =
      if untyped_init then
        (match declared_accumulator () with
         | Some ty -> ty
         | None ->
           (match annotated_accumulator () with
            | Some ty -> ty
            | None -> type_of_expr signatures env (List.nth args 1)))
      else type_of_expr signatures env (List.nth args 1)
    in
    (* `foldl`'s callback takes (accumulator, element); `foldr`'s takes them the other way
       round, per the stdlib signatures. *)
    let params = match hof with
      | HofFoldr -> [element; accumulator]
      | _ -> [accumulator; element]
    in
    let result = type_of_callable signatures env loc what (List.nth args 0) params in
    if type_unequal result accumulator then unsupported loc
      "Go backend `%s` must return its accumulator type" what;
    accumulator

and constructor_head expr =
  match expr with
  | EConstructor { name; args; _ } -> Some (name, args)
  | EApp _ ->
    (match flatten_app [] expr with
     | EConstructor { name; args; _ }, rest -> Some (name, args @ rest)
     | _ -> None)
  | _ -> None

(* A set leaf's element type comes from its Set argument, from the element it is given
   (`Set.singleton`), from the list (`Set.fromList`), or — for `Set.empty`, which has
   neither — from the expectation, like `Nothing`. *)
and type_of_set_leaf signatures env loc leaf args expected =
  let args = normalize_call_args (List.init leaf.set_arity (fun _ -> TUnit)) args in
  if List.length args <> leaf.set_arity then
    unsupported loc "Go backend requires `%s` applied to %d argument(s)"
      leaf.set_name leaf.set_arity;
  (* `Set.insert x Set.empty`: the empty set carries no element type, and the value being
     inserted is what says what it would have held — the same rule `Dict.insert` gets. *)
  let is_set_empty expr =
    match normalize_call_head expr with EVar { name = "Set.empty"; _ } -> true | _ -> false in
  let element =
    if leaf.set_index >= 0 then
      match List.nth args leaf.set_index with
      | argument when is_set_empty argument && leaf.set_index = 1 ->
        type_of_expr signatures env (List.nth args 0)
      (* A leaf whose result does NOT mention the element — `isEmpty`, `size` — behaves
         identically whatever the set holds, so a bare `Set.empty` there is answered rather
         than refused: picking an element type cannot change the result.  A leaf that DOES
         mention it (`Set.toList Set.empty`) still fails closed, because the choice would
         be a guess.  This is the rule `List.isEmpty []` already gets. *)
      | argument when is_set_empty argument
                      && (leaf.set_name = "Set.isEmpty" || leaf.set_name = "Set.size") -> TInt
      | argument ->
        (match type_of_expr signatures env argument with
         | TSet element -> element
         | _ -> unsupported loc "Go backend `%s` requires a Set argument" leaf.set_name)
    else match leaf.set_name, expected with
      | "Set.empty", Some (TSet element) -> element
      | "Set.empty", _ ->
        unsupported loc "Go backend cannot infer the element type of `Set.empty`"
      | "Set.singleton", _ -> type_of_expr signatures env (List.nth args 0)
      | "Set.fromList", _ ->
        (match type_of_expr signatures env (List.nth args 0) with
         | TList element -> element
         | _ -> unsupported loc "Go backend `%s` requires a List argument" leaf.set_name)
      | _ -> unsupported loc "Go backend cannot resolve `%s`" leaf.set_name
  in
  if leaf.set_needs_order && not (supports_ordering element) then
    unsupported loc "Go backend `%s` needs ordered elements" leaf.set_name;
  (* Check the non-Set arguments: an element for member/insert/remove, a Set for the
     algebra. *)
  List.iteri (fun index arg ->
    if index <> leaf.set_index then begin
      let want = match leaf.set_name with
        | "Set.union" | "Set.intersection" | "Set.difference" | "Set.isSubset" -> TSet element
        | "Set.fromList" -> TList element
        | _ -> element
      in
      if type_unequal (type_of_arg signatures env want arg) want then unsupported loc
        "Go backend `%s` argument %d has an unsupported type" leaf.set_name (index + 1)
    end) args;
  (match leaf.set_result with
   | `Set -> TSet element
   | `Int -> TInt
   | `Bool -> TBool
   | `Elements -> TList element)

(* A dict leaf's types come from its Dict argument — except `Dict.empty`, which has no
   argument at all and so takes its type from the expectation, like `Nothing`. *)
and type_of_dict_leaf signatures env loc leaf args =
  let args = normalize_call_args (List.init leaf.dict_arity (fun _ -> TUnit)) args in
  if List.length args <> leaf.dict_arity then
    unsupported loc "Go backend requires `%s` applied to %d argument(s)"
      leaf.dict_name leaf.dict_arity;
  (* `Dict.insert k v Dict.empty`: the empty dict carries no key or value type of its own,
     and the OTHER two arguments are exactly what say what it would have held.  This is the
     same rule an empty list literal gets from a callback's parameter. *)
  let is_dict_empty expr =
    match normalize_call_head expr with EVar { name = "Dict.empty"; _ } -> true | _ -> false in
  let pair_of index =
    match leaf.dict_name, List.nth args index with
    | "Dict.insert", argument when is_dict_empty argument && index = 2 ->
      type_of_expr signatures env (List.nth args 0),
      type_of_expr signatures env (List.nth args 1)
    | _ ->
      (match typed_with_default (type_of_expr signatures env) (List.nth args index) with
       | Some (TDict (key, value)), _ -> key, value
       (* A leaf whose result mentions NEITHER the key nor the value — `isEmpty`, `size` —
          answers the same whatever the dict holds, so a bare `Dict.empty` there is given a
          pair rather than refused: the choice cannot change the result.  This is the rule
          `List.isEmpty []` and `Set.isEmpty Set.empty` already get. *)
       | _ when leaf.dict_name = "Dict.isEmpty" || leaf.dict_name = "Dict.size" -> TInt, TInt
       | _ -> unsupported loc "Go backend `%s` requires a Dict argument" leaf.dict_name)
  in
  let maybe_of inner =
    match adt_ctor_of_signature signatures "Nothing" with
    | Some (info, _) -> TAdt (info, [inner])
    | None -> unsupported loc
      "Go backend `%s` returns a Maybe; import `Tesl.Maybe`" leaf.dict_name
  in
  match leaf.dict_name with
  | "Dict.empty" ->
    unsupported loc "Go backend cannot infer the key and value types of `Dict.empty`"
  (* The one leaf that BUILDS a dict from a key and a value rather than taking one. *)
  | "Dict.singleton" ->
    let key = type_of_expr signatures env (List.nth args 0) in
    let value = type_of_expr signatures env (List.nth args 1) in
    if not (supports_ordering key) then unsupported loc
      "Go backend `%s` needs ordered keys" leaf.dict_name;
    TDict (key, value)
  | "Dict.fromList" ->
    (match type_of_expr signatures env (List.nth args 0) with
     | TList (TAdt (info, [key; value])) when info.adt_tesl_name = "Tuple2" ->
       if not (supports_ordering key) then unsupported loc
         "Go backend `%s` needs ordered keys" leaf.dict_name;
       TDict (key, value)
     | _ -> unsupported loc
       "Go backend `%s` requires a List (Tuple2 k v) argument" leaf.dict_name)
  | _ ->
    (* The Dict is the LAST argument in every remaining leaf. *)
    let key, value = pair_of (leaf.dict_arity - 1) in
    if leaf.dict_needs_order && not (supports_ordering key) then
      unsupported loc "Go backend `%s` needs ordered keys" leaf.dict_name;
    (match leaf.dict_name with
     | "Dict.insert" ->
       if type_of_arg signatures env key (List.nth args 0) <> key then unsupported loc
         "Go backend `%s` key has an unsupported type" leaf.dict_name;
       if type_of_arg signatures env value (List.nth args 1) <> value then unsupported loc
         "Go backend `%s` value has an unsupported type" leaf.dict_name
     | "Dict.lookup" | "Dict.member" | "Dict.remove" | "Dict.delete" | "Dict.requireKey"
     | "Dict.get" ->
       if type_of_arg signatures env key (List.nth args 0) <> key then unsupported loc
         "Go backend `%s` key has an unsupported type" leaf.dict_name
     (* Both operands are dicts, and they must be the SAME dict type: a union of
        `Dict String Int` with `Dict String Bool` has no value type to answer with. *)
     | "Dict.union" ->
       if pair_of 0 <> (key, value) then unsupported loc
         "Go backend `%s` needs both dicts to have the same key and value types"
         leaf.dict_name
     | _ -> ());
    (match leaf.dict_result with
     | `Dict -> TDict (key, value)
     | `MaybeValue -> maybe_of value
     | `Value -> value
     | `CheckDict -> TCheck (TDict (key, value))
     | `Int -> TInt
     | `Bool -> TBool
     | `Keys -> TList key
     | `Values -> TList value
     | `Pairs ->
       (match Hashtbl.find_opt signatures "Tuple2" with
        | Some { result = TAdt (info, _); _ } -> TList (TAdt (info, [key; value]))
        | _ -> unsupported loc
          "Go backend `%s` returns tuples; import `Tesl.Tuple`" leaf.dict_name))

(* ── `Tesl.Agent`: the forms a signature cannot describe ─────────────────────
   Five of the module's leaves take something a `params`/`result` row has no way to say: a
   literal TYPE NAME (`decodeAs`), a FUNCTION VALUE (a tool's validator and dispatch,
   `askFor`'s decoder, a publisher).  Each is registered with a placeholder signature whose
   Go name identifies it, recognised by [agent_form], and typed and emitted from what it was
   actually given.

   The placeholder is what makes the recognition safe: a module that declares its own `tool`
   never reaches these arms, because its signature is its own. *)
and agent_form signatures name go =
  match Hashtbl.find_opt signatures name with
  | Some signature -> signature.go_name = go
  | None -> false

and agent_opaque signatures loc name =
  match Hashtbl.find_opt signatures name with
  | Some { result = TRecord info; _ } -> TRecord info
  | _ -> unsupported loc "Go backend `Tesl.Agent` needs its `%s` type" name

(* `decodeAs "T" json`: the type is a literal at the call site, so the decoder is chosen at
   COMPILE time and the name survives only in the failure message. *)
and agent_decode_as_parts signatures env loc args =
  match args with
  | [ELit { lit = LString type_name; _ }; json] ->
    (match type_of_expr signatures env json with
     | TString -> ()
     | _ -> unsupported (Checker.expr_loc json)
       "Go backend `decodeAs` takes the JSON as a String");
    if codec_owner type_name = None then
      unsupported loc
        "Go backend `decodeAs \"%s\"` needs `%s` to have a `codec`: the decode goes through \
         the same one an HTTP request body does" type_name type_name;
    let types = match !current_types with
      | Some types -> types
      | None -> unsupported loc "Go backend cannot resolve `decodeAs` here"
    in
    type_name, json, type_of_type_expr types (TName { name = type_name; loc })
  | _ -> unsupported loc
    "Go backend `decodeAs` takes a literal type name and a JSON String \
     (`decodeAs \"MyType\" json`)"

(* A named function in VALUE position.  Go accepts one here — these are the only places the
   surface passes a function that is not a lambda — but not one that needs the request
   scope: its Go signature has a parameter the caller cannot supply. *)
and agent_function_ref signatures loc what expr =
  match expr with
  | EVar { name; _ } | EConstructor { name; args = []; _ } ->
    (match Hashtbl.find_opt signatures name with
     | Some { sig_needs_scope = true; _ } ->
       unsupported loc "Go backend cannot pass `%s` as %s: it takes the request scope" name what
     | Some signature -> signature
     | None -> unsupported loc "Go backend cannot resolve function `%s`" name)
  | _ -> unsupported (Checker.expr_loc expr) "Go backend %s must be a named function" what

(* `tool name description schema validator dispatch`.  The validator and the dispatch meet at
   a type only they two mention — the tool's VALIDATED argument — and the runtime erases it
   into the pair of closures, so the one thing to establish here is that they agree. *)
and agent_tool_parts signatures env loc args =
  match args with
  | [name; description; schema; validator; dispatch] ->
    List.iter (fun (label, text) ->
      match type_of_expr signatures env text with
      | TString -> ()
      | _ -> unsupported (Checker.expr_loc text)
        "Go backend `tool` takes a String %s" label)
      [ "name", name; "description", description; "JSON schema", schema ];
    let validate = agent_function_ref signatures loc "a tool validator" validator in
    let argument = match agent_tool_dispatch signatures env loc dispatch with
      | `Direct signature | `Captured (signature, _) -> agent_dispatch_argument loc signature
    in
    (match validate.params with
     | [TString] when not (type_unequal validate.result argument) -> ()
     | _ -> unsupported loc
       "Go backend `tool` takes a validator `String -> a` and a dispatch `a -> String` over \
        the same `a`");
    name, description, schema, validator, dispatch
  | _ -> unsupported loc
    "Go backend `tool` takes a name, a description, a JSON-schema String, a validator and a \
     dispatch"

(* The type the validator hands the dispatch: the dispatch's LAST parameter, since anything
   before it was captured by the program. *)
and agent_dispatch_argument loc (signature : signature) =
  match List.rev signature.params with
  | argument :: _ when signature.result = TString -> argument
  | _ -> unsupported loc "Go backend `tool` takes a dispatch answering a String"

(* A tool dispatch is a named function, optionally PARTIALLY APPLIED to the arguments the
   program supplies itself.  That partial application is load-bearing rather than a
   convenience: it is what lets a tool be built per turn around a value the model never
   sees — the conversation it belongs to, the user it acts for — so the model chooses only
   what the schema describes. *)
and agent_tool_dispatch signatures env loc dispatch =
  let head, captured = flatten_app [] dispatch in
  match captured with
  | [] -> `Direct (agent_function_ref signatures loc "a tool dispatch" dispatch)
  | [one] ->
    let signature = agent_function_ref signatures loc "a tool dispatch" head in
    (match signature.params with
     | [first; _] ->
       if type_unequal (type_of_arg signatures env first one) first then
         unsupported (Checker.expr_loc one)
           "Go backend cannot capture this argument in a tool dispatch: it is not the type \
            the function declares";
       `Captured (signature, one)
     | _ -> unsupported loc
       "Go backend `tool` supports a dispatch partially applied to ONE captured argument")
  | _ -> unsupported loc
    "Go backend `tool` supports a dispatch partially applied to ONE captured argument"

(* `asTool fn` derives all three of a tool's parts from the function's declaration, which is
   why it needs the declaration and not just the signature. *)
and agent_astool_decl loc args =
  match args with
  | [EVar { name; _ }] | [EConstructor { name; args = []; _ }] ->
    (match Hashtbl.find_opt current_functions name with
     | Some declaration -> declaration
     | None -> unsupported loc
       "Go backend `asTool` supports a function declared in this module; `%s` is not one" name)
  | _ -> unsupported loc
    "Go backend `asTool` takes a bare function reference (`asTool myFn`)"

(* `askFor agent prompt decoder retries` answers whatever the DECODER answers — the retry
   loop exists to produce that value, so its type is the decoder's result. *)
and agent_ask_for_parts signatures env loc args =
  match args with
  | [agent; prompt; decoder; retries] ->
    let expect what ty expr =
      if type_unequal (type_of_expr signatures env expr) ty then
        unsupported (Checker.expr_loc expr) "Go backend `askFor` takes %s" what
    in
    expect "an Agent" (agent_opaque signatures loc "Agent") agent;
    expect "a String prompt" TString prompt;
    expect "an Int retry count" TInt retries;
    let decode = agent_function_ref signatures loc "an `askFor` decoder" decoder in
    (match decode.params with
     | [TString] -> ()
     | _ -> unsupported loc "Go backend `askFor` takes a decoder `String -> a`");
    agent, prompt, decoder, retries, decode.result
  | _ -> unsupported loc
    "Go backend `askFor` takes an agent, a prompt, a decoder and a retry count"

(* A step publisher is a Tesl `String -> Unit`, written either as a lambda or as a named
   function.  Both reach Go as the same function type, so the only thing to settle is that
   the shape is that one. *)
(* `serverTools S user` / `humanActions S user`: the server, the user, and the endpoints
   THIS call site gets.  The site tables are the checker's per-call-site decision; a missing
   entry means the emitter and the checker disagree about what the module contains, which is
   a compiler bug rather than a program one, so it fails rather than emitting an empty set —
   an empty tool list would read as "this user may do nothing" and be silently wrong. *)
and agent_endpoint_tools signatures env loc form args =
  let server_ref, user = match args with
    | [server_ref; user] -> server_ref, user
    | _ -> unsupported loc
      "Go backend `%s` takes a server and an authenticated user (`%s MyServer user`)"
      form form
  in
  let server_name = match server_ref with
    | EConstructor { name; args = []; _ } | EVar { name; _ } -> name
    | _ -> unsupported loc
      "Go backend `%s` takes a bare reference to a server declared in this module" form
  in
  let endpoints = match Hashtbl.find_opt server_tools_endpoints server_name with
    | Some endpoints -> endpoints
    | None -> unsupported loc
      "Go backend `%s %s` — no such server in this module" form server_name
  in
  let sites = if form = "serverTools" then server_tools_sites else human_actions_sites in
  let key = loc.Location.start.line, loc.Location.start.col in
  let names = match Hashtbl.find_opt sites key with
    | Some (_, names) -> names
    | None -> unsupported loc
      "Go backend has no checker decision for this `%s` call site" form
  in
  let selected = List.filter (fun (name, _, _, _) -> List.mem name names) endpoints in
  server_name, user, type_of_expr signatures env user, selected

and agent_publisher_type signatures env loc what expr =
  let ok = match expr with
    | ELambda _ ->
      (match type_of_expr signatures env expr with
       | TFunc ([TString], TUnit) -> true
       | _ -> false)
    | _ ->
      let signature = agent_function_ref signatures loc what expr in
      signature.params = [TString] && signature.result = TUnit
  in
  if not ok then
    unsupported (Checker.expr_loc expr)
      "Go backend %s takes a `String -> Unit` function" what

and type_of_arg signatures env want arg =
  match arg with
  (* A check may DELEGATE to another check in tail position: `check parseAge raw = … check
     checkAge parsed`.  The delegate's own `Check` IS this check's result — that is what
     Racket's `let/check`-based lowering does when the tail is the inner call — so the
     expectation is satisfied by the check's VALUE type. *)
  | _ when (match check_application signatures arg, want with
            | Some ({ result = TCheck inner; _ }, _), TCheck expected_inner ->
              inner = expected_inner
            | _ -> false) -> want
  (* A COMBINED check delegates the same way: `check checkBoth(n) -> … = check (checkA &&
     checkB) n` hands back the conjunction's own `Check`.  Typed here rather than in
     `type_of_expr` for the reason the single-check case is: only the EXPECTATION says whether
     this position wants the check or its value. *)
  | _ when (match want, flatten_app [] arg with
            | TCheck inner, (EVar { name = "check"; _ }, (conjunction :: _)) ->
              (match check_conjuncts conjunction with
               | Some (_ :: _ :: _) ->
                 not (type_unequal (type_of_expr signatures env arg) inner)
               | _ -> false)
            | _ -> false) -> want
  (* `f <| value ::: pf` attaches a detached proof at the call site.  It parses as the same
     node as a check's `ok value ::: P`, and the two are told apart by what is EXPECTED: a
     check's tail wants a `Check`, an ordinary parameter wants the value.  The proof erases,
     so the argument is just the value. *)
  | EOk { value; _ } when (match want with TCheck _ -> false | _ -> true) ->
    type_of_arg signatures env want value
  (* A check's tail: the expectation is what says this `ok value ::: P` is a check result. *)
  | EOk { value; _ } ->
    (match want with
     | TCheck inner -> TCheck (type_of_arg signatures env inner value)
     | _ -> assert false)
  (* A `check` whose declared return is a plain VALUE — `-> Maybe (v: Int ::: IsPositive v)`
     — has a body that IS that value: there is no `ok` to write, because the proof rides
     inside the `Something`.  So a body satisfying the check's inner type satisfies the
     check, and — the part that matters — the INNER type is what the body's branches are
     typed against, which is what lets a bare `Nothing` in one of them find its element. *)
  | _ when (match want with
            | TCheck inner ->
              (match typed_with_default (type_of_arg signatures env inner) arg with
               | Some got, _ -> not (type_unequal got inner)
               | None, _ -> false)
            | _ -> false) -> want
  (* A check's VALUE satisfies an expectation of its base type: the rejection becomes a
     failure at the point of use (see the `MustCheck` emission). *)
  | EApp _ when (match want with TCheck _ -> false | _ -> true)
                && (try type_equal (type_of_expr signatures env arg) (TCheck want)
                    with Unsupported _ -> false) -> want
  (* An empty list literal has no element to infer from: the expectation supplies it. *)
  | EList { elems = []; _ } when (match want with TList _ -> true | _ -> false) -> want
  (* Neither does a list whose elements are ALL under-constrained (`[Nothing, Nothing]`):
     the expectation belongs to each element, exactly as it belongs to each `if` branch. *)
  | EList { elems; _ } when (match want with TList _ -> true | _ -> false) ->
    (match want with
     | TList element ->
       List.iter (fun elem ->
         if type_unequal (type_of_arg signatures env element elem) element then
           unsupported (Checker.expr_loc elem)
             "Go backend list element has an unsupported type") elems;
       want
     | _ -> assert false)
  (* The expectation belongs to each BRANCH, and a branch is exactly where an
     under-constrained constructor sits. *)
  (* `Set.empty` and `Dict.empty` have no argument to infer an element type from, so the
     expectation supplies it — the same rule as an empty list literal and a nullary
     constructor.  Both are spelled as a bare name, since they take no arguments. *)
  | _ when (match normalize_call_head arg, want with
            | EVar { name = "Set.empty"; _ }, TSet _ -> true
            | EVar { name = "Dict.empty"; _ }, TDict _ -> true
            | _ -> false) -> want
  (* An UNTYPED api-test value where a String is wanted: what a `String.*` leaf reads is the
     string the JSON holds, which is the same coercion `++` already applies to it — and the
     shape these tests are written in (`String.contains r.body.names "x"`).  Only inside an
     api-test, which is the only place the untyped view exists. *)
  | _ when want = TString && !current_api_server <> None
           && (match typed_with_default (type_of_expr signatures env) arg with
               | Some TJson, _ -> true
               | _ -> false) -> want
  (* `Dict.fromList []` builds an empty dict from an empty list of pairs, and neither says
     anything about the key or the value — so the expectation does, exactly as it does for
     `Dict.empty`.  `Set.fromList []` is the same shape over one element type. *)
  | _ when (match flatten_app [] arg with
            | head, [EList { elems = []; _ }] ->
              (match normalize_call_head head, want with
               | EVar { name = "Dict.fromList"; _ }, TDict _ -> true
               | EVar { name = "Set.fromList"; _ }, TSet _ -> true
               | _ -> false)
            | _ -> false) -> want
  | EIf { cond; then_; else_; loc } ->
    if type_of_expr signatures env cond <> TBool then
      unsupported loc "Go backend if condition must be Bool";
    (match type_of_arg signatures env want then_, type_of_arg signatures env want else_ with
     | TFailure, ty | ty, TFailure -> ty
     | left, right when type_equal left right -> left
     | _ -> unsupported loc "Go backend if branches have different types")
  (* The money-rate algebra, where the EXPECTATION is what settles it: `money / quantity` has
     no denominator without the declared rate type, and `rate * float` is a rescale when a rate
     is expected and a materialised amount when money is.  Racket settles both the same way,
     from the result type its checker recorded. *)
  | EBinop { op; left; right; _ }
    when (match money_rate_binop ~expected:want op
                  (try type_of_expr signatures env left with Unsupported _ -> TFailure)
                  (try type_of_expr signatures env right with Unsupported _ -> TFailure) with
          | Some _ -> true | None -> false) ->
    let left_ty = type_of_expr signatures env left in
    let right_ty = type_of_expr signatures env right in
    (match money_rate_binop ~expected:want op left_ty right_ty with
     | Some (`Scale | `ScaleFlipped) -> if is_money_rate left_ty then left_ty else right_ty
     | Some `Divide ->
       if not (is_money_rate want) then unsupported (Checker.expr_loc left)
         "Go backend `money / quantity` answers a rate; annotate the result";
       want
     | Some (`Consume | `ConsumeFlipped) | None -> type_of_expr signatures env arg)
  (* A MULTI-LINE query is an underscore-`let` chain, so it must be recognised BEFORE the
     chain is peeled: typing the first link on its own reads `update p in E` as a call to a
     function named `update`, which is what it looked like to the emitter for as long as the
     query was written in a `fn` body rather than a test block. *)
  | (ELet _ | EApp _ | EBinop _) when recognise_sql arg <> None ->
    type_of_expr signatures env arg
  (* A `let` chain passes the expectation THROUGH to its tail, the same way the tail
     emitter does.  Without this, one `let` before an `if` was enough to lose it, and an
     under-constrained tail (`[]`, `Nothing`, `Set.empty`) failed for no reason the author
     could see — the very shape a list-building function has. *)
  | ELet { name; value; body; _ } ->
    let inferred = type_of_expr signatures env value in
    let ty = if inferred = TFailure then want else inferred in
    type_of_arg signatures ((name, ty) :: env) want body
  (* The expectation belongs to each ARM for the same reason it belongs to each `if`
     branch. *)
  | ECase { scrut; arms; loc } ->
    let scrut_ty = type_of_expr signatures env scrut in
    let info, type_args = match scrut_ty with
      | TAdt (info, args) -> info, args
      | ty when scalar_case_type ty -> adt_placeholder_info, []
      | _ -> unsupported loc
        "Go backend supports `case` over a module ADT or a scalar (Int, String, Bool)"
    in
    if arms = [] then unsupported loc "Go backend requires at least one `case` arm";
    List.fold_left (fun acc (arm : case_arm) ->
      let arm_env =
        (if scalar_case_type scrut_ty then scalar_pattern_bindings loc scrut_ty arm.pattern
         else pattern_bindings loc info type_args arm.pattern) @ env in
      (match arm.guard with
       | None -> ()
       | Some guard ->
         if type_of_expr signatures arm_env guard <> TBool then
           unsupported (Checker.expr_loc guard) "Go backend `case` guard must be Bool");
      match acc, type_of_arg signatures arm_env want arm.body with
      | TFailure, ty | ty, TFailure -> ty
      | left, right when type_equal left right -> left
      | _ -> unsupported loc "Go backend `case` arms have different types") TFailure arms
  | _ ->
    (* A constructor cannot always infer its ADT's type arguments from its own
       arguments — `Nothing` supplies none, and `Left e` never mentions the Right
       parameter — so where a type is expected, that expectation instantiates it. *)
    (match constructor_head arg, want with
     | Some (name, supplied), TAdt (info, (_ :: _ as type_args)) ->
       (match adt_ctor_of_signature signatures name with
        | Some (owner, variant) when owner.adt_tesl_name = info.adt_tesl_name ->
          let expected = variant_field_types info type_args variant in
          if List.length supplied <> List.length expected then
            unsupported (Checker.expr_loc arg)
              "Go backend requires constructor `%s.%s` applied to %d argument(s)"
              info.adt_tesl_name variant.var_ctor (List.length expected);
          List.iter2 (fun value (field, field_ty) ->
            if type_unequal (type_of_arg signatures env field_ty value) field_ty then
              unsupported (Checker.expr_loc value)
                "Go backend constructor field `%s.%s` has an unsupported value type"
                variant.var_ctor field) supplied expected;
          want
        | _ -> type_of_expr signatures env arg)
     | _ -> type_of_expr signatures env arg)

(* A constructor application determines the ADT's type arguments: each parameter is
   read off the argument whose declared field type IS that parameter.  A parameter
   that appears in no field (or only nested inside another type) cannot be inferred
   here, and the application is rejected rather than guessed at. *)
and type_of_variant_application signatures env loc info variant args =
  if List.length args <> List.length variant.var_fields then
    unsupported loc "Go backend requires constructor `%s.%s` applied to %d argument(s)"
      info.adt_tesl_name variant.var_ctor (List.length variant.var_fields);
  (* For a NON-generic ADT the field types are known before the arguments are typed, so
     each argument is typed AGAINST its field — which is what lets an under-constrained
     argument (`Wrapped Nothing`, `Wrapped []`) take its type from the field it fills
     rather than having to carry one of its own. *)
  let declared_fields = variant_field_types info [] variant in
  let arg_types =
    if info.adt_params = [] then
      List.map2 (fun arg (_, field_ty) -> type_of_arg signatures env field_ty arg)
        args declared_fields
    else List.map (type_of_expr signatures env) args in
  let type_args = List.map (fun (tesl_param, go_param) ->
    let rec find fields types =
      match fields, types with
      | (_, TParam candidate) :: _, arg_ty :: _ when candidate = go_param -> Some arg_ty
      | _ :: fields, _ :: types -> find fields types
      | _, _ -> None
    in
    match find variant.var_fields arg_types with
    | Some ty -> ty
    | None ->
      (* The parameter appears in NO field of the variant in hand — `Left e` says nothing
         about the Right side — so this application cannot settle it and no value of it can
         exist here.  It stays ANONYMOUS rather than being guessed at or refused: an
         expectation or a sibling value settles it if either one does, and if neither does
         it renders as the empty struct, which is a witness for a type with no values.

         A parameter that DOES appear in a field but could not be read off its argument is a
         different situation — the argument is there and its type disagreed — and it keeps
         the refusal, because guessing there would paper over a real mismatch. *)
      let mentions_param (_, field_ty) =
        let rec mentions ty = match ty with
          | TParam name -> name = go_param
          | TAdt (_, args) -> List.exists mentions args
          | TList inner | TSet inner | TCheck inner -> mentions inner
          | TDict (key, value) -> mentions key || mentions value
          | TFunc (params, result) -> List.exists mentions params || mentions result
          | TInt | TFloat | TQuantity | TString | TBool | TUnit | TNewtype _ | TRecord _
          | TJson | TStream | TFailure | TAnon -> false
        in
        mentions field_ty
      in
      if List.exists mentions_param variant.var_fields then
        unsupported loc
          "Go backend cannot infer type argument `%s` of `%s` from constructor `%s`"
          tesl_param info.adt_tesl_name variant.var_ctor
      else TAnon) info.adt_params in
  let expected = variant_field_types info type_args variant in
  List.iter2 (fun got (name, want) ->
    if type_unequal got want then
      unsupported loc "Go backend constructor field `%s.%s` has an unsupported value type"
        variant.var_ctor name) arg_types expected;
  TAdt (info, type_args)

(* Returns the bindings a pattern introduces, rejecting every pattern shape the
   emitter cannot lower rather than binding it to the wrong payload field. *)
and pattern_bindings _loc info type_args pattern =
  match pattern with
  | PWild -> []
  | PVar name -> [name, TAdt (info, type_args)]
  | PLit { loc; _ } ->
    unsupported loc "Go backend does not support literal patterns over `%s` yet"
      info.adt_tesl_name
  | PNullary { ctor; loc } ->
    (match find_variant info ctor with
     | None ->
       unsupported loc "Go backend cannot resolve constructor `%s` of `%s`" ctor info.adt_tesl_name
     | Some variant ->
       if variant.var_fields <> [] then
         unsupported loc "Go backend requires constructor pattern `%s` to bind its %d field(s)"
           ctor (List.length variant.var_fields);
       [])
  | PCon { ctor; fields; loc } ->
    (match find_variant info ctor with
     | None ->
       unsupported loc "Go backend cannot resolve constructor `%s` of `%s`" ctor info.adt_tesl_name
     | Some variant ->
       if List.length fields <> List.length variant.var_fields then
         unsupported loc "Go backend requires constructor pattern `%s` to bind its %d field(s)"
           ctor (List.length variant.var_fields);
       (* Sub-patterns bind POSITIONALLY, matching the Racket backend: the pattern's
          own key is a binder name, not necessarily the declared field name. *)
       (* A sub-pattern may itself be a constructor (`Neg (Lit n)`) or a literal
          (`RGB { r = 255, … }`): what it BINDS is whatever its own sub-patterns bind, and
          what it TESTS is settled at emission.  So this walks the nesting and collects the
          binders; the shapes it cannot type — a constructor pattern over something that is
          not an ADT, a literal over a type with no literal form — fail closed here. *)
       let rec sub_bindings field_ty sub =
         match sub with
         | PWild -> []
         | PVar name -> [name, field_ty]
         | PNullary { ctor; loc } ->
           (match field_ty with
            | TAdt (sub_info, _) ->
              (match find_variant sub_info ctor with
               | Some sub_variant ->
                 if sub_variant.var_fields <> [] then unsupported loc
                   "Go backend requires constructor pattern `%s` to bind its %d field(s)"
                   ctor (List.length sub_variant.var_fields);
                 []
               | None -> unsupported loc
                 "Go backend cannot resolve constructor `%s` of `%s`" ctor
                 sub_info.adt_tesl_name)
            | _ -> unsupported loc
              "Go backend cannot match constructor `%s` against a non-ADT field" ctor)
         | PCon { ctor; fields = sub_fields; loc } ->
           (match field_ty with
            | TAdt (sub_info, sub_args) ->
              (match find_variant sub_info ctor with
               | Some sub_variant ->
                 if List.length sub_fields <> List.length sub_variant.var_fields then
                   unsupported loc
                     "Go backend requires constructor pattern `%s` to bind its %d field(s)"
                     ctor (List.length sub_variant.var_fields);
                 List.concat (List.mapi (fun sub_index (_, deeper) ->
                   let _, deeper_ty =
                     List.nth (variant_field_types sub_info sub_args sub_variant) sub_index in
                   sub_bindings deeper_ty deeper) sub_fields)
               | None -> unsupported loc
                 "Go backend cannot resolve constructor `%s` of `%s`" ctor
                 sub_info.adt_tesl_name)
            | _ -> unsupported loc
              "Go backend cannot match constructor `%s` against a non-ADT field" ctor)
         | PLit { value; loc } ->
           (match field_ty, value with
            | TInt, (LInt _ | LBigInt _) | TString, LString _ | TBool, LBool _ -> []
            | _ ->
              unsupported loc "Go backend cannot match this literal against the field type")
       in
       List.concat (List.mapi (fun index (_key, sub) ->
         let _, field_ty = List.nth (variant_field_types info type_args variant) index in
         sub_bindings field_ty sub) fields))

and record_field_type loc info field =
  match List.assoc_opt field info.rec_fields with
  | Some ty -> ty
  | None ->
    unsupported loc "Go backend record `%s` has no field `%s`" info.rec_tesl_name field

and reject_duplicate_fields loc what fields =
  let rec loop = function
    | [] -> ()
    | (name, _) :: rest ->
      if List.mem_assoc name rest then
        unsupported loc "Go backend %s repeats field `%s`" what name;
      loop rest
  in
  loop fields

(* A record literal must mention every declared field exactly once: Go's zero
   value would otherwise silently stand in for a missing Tesl field. *)
and check_record_literal signatures env loc info fields =
  reject_duplicate_fields loc "record literal" fields;
  List.iter (fun (name, _) ->
    if not (List.mem_assoc name info.rec_fields) then
      unsupported loc "Go backend record `%s` has no field `%s`" info.rec_tesl_name name)
    fields;
  List.iter (fun (name, want) ->
    match List.assoc_opt name fields with
    | None ->
      unsupported loc "Go backend record literal for `%s` is missing field `%s`"
        info.rec_tesl_name name
    | Some value ->
      let got = type_of_arg signatures env want value in
      if type_unequal got want then
        unsupported (Checker.expr_loc value)
          "Go backend record field `%s.%s` has an unsupported value type"
          info.rec_tesl_name name)
    info.rec_fields

and record_update_parts loc fields =
  match List.assoc_opt "__base__" fields with
  | None -> unsupported loc "Go backend cannot resolve the record being updated"
  | Some base ->
    let updates = List.filter (fun (name, _) -> name <> "__base__") fields in
    if updates = [] then unsupported loc "Go backend record update sets no field";
    base, updates

and type_of_record_update signatures env loc fields =
  let base, updates = record_update_parts loc fields in
  match type_of_expr signatures env base with
  | TRecord info ->
    reject_duplicate_fields loc "record update" updates;
    List.iter (fun (name, value) ->
      let want = record_field_type loc info name in
      let got = type_of_expr signatures env value in
      if type_unequal got want then
        unsupported (Checker.expr_loc value)
          "Go backend record update `%s.%s` has an unsupported value type"
          info.rec_tesl_name name) updates;
    TRecord info
  | _ -> unsupported loc "Go backend record update requires a record value"

(* A `case` arm as the emitter needs it: the pattern, its optional guard, and a CLOSURE that
   emits the body.  A closure rather than the body itself because the body's type depends on
   the context — an expression for an ordinary `case`, a statement list inside a test block —
   and the discrimination logic is identical either way. *)
let arm_pattern (pattern, _, _) = pattern
let arm_guard (_, guard, _) = guard
let arm_body (_, _, body) = body

let rec emit_expr ?expected ?(indent="") signatures env expr =
  let emit = emit_expr ~indent signatures env in
  match expr with
  | ELit { lit = LInt value; _ } -> Printf.sprintf "teslrt.FromInt64(%d)" value
  | ELit { lit = LBigInt value; _ } ->
    Printf.sprintf "teslrt.MustParseDecimal(%s)" (go_quote value)
  (* Inside an api-test a string LITERAL is a template: `"thing-{id}"` splices the block's
     bindings, and `expect r.body == "thing-{id}"` compares against what it renders to.  The
     SPLIT is the shared one (`emit_api_test_string`), so a literal that only looks like a
     slot — `"{}"`, `"{\"id\": 1}"` — stays the two characters it is. *)
  | ELit { lit = LString _; _ } as literal when api_test_interpolates literal ->
    emit_api_test_string ~indent signatures env literal
  | ELit { lit = LString value; _ } -> go_quote value
  | ELit { lit = LBool value; _ } -> if value then "true" else "false"
  | ELit { lit = LFloat value; _ } -> emit_float_literal value
  | ELit { lit = LInterp segments; _ } -> emit_interp ~indent signatures env segments
  | EVar { name; loc } ->
    (match List.assoc_opt name env, Hashtbl.find_opt signatures name with
     | Some _, _ -> local_ident name
     | None, _ when Option.bind !current_types (fun types ->
                      Hashtbl.find_opt types.consts name) <> None ->
       (match Option.bind !current_types (fun types -> Hashtbl.find_opt types.consts name) with
        | Some (_, go_name) -> go_name
        | None -> assert false)
     (* A named function used as a VALUE is its own Go name; the type rule has already
        established that this is a function type and not a check. *)
     | None, Some signature when (match type_of_expr signatures env expr with
                                  | TFunc _ -> true | _ -> false) ->
       qualified signature.sig_owner signature.go_name
     | None, Some _ -> unsupported loc "Go backend does not support function `%s` as a value" name
     | None, None -> local_ident name)
  | EConstructor { name = "True"; args = []; _ } -> "true"
  | EConstructor { name = "False"; args = []; _ } -> "false"
  | EConstructor { name = "Unit"; args = []; _ } -> "struct{}{}"
  | EConstructor { name; args = []; _ }
    when Option.bind !current_types (fun types -> Hashtbl.find_opt types.consts name) <> None ->
    (match Option.bind !current_types (fun types -> Hashtbl.find_opt types.consts name) with
     | Some (_, go_name) -> go_name
     | None -> assert false)
  | EConstructor { name; args; _ } when adt_ctor_of_signature signatures name <> None ->
    let owner, variant = match adt_ctor_of_signature signatures name with
      | Some pair -> pair
      | None -> assert false
    in
    (* The expected type instantiates the ADT whenever it is available: a
       constructor's own arguments need not mention every type parameter. *)
    let result = match expected with
      | Some (TAdt (info, (_ :: _)) as want) when info.adt_tesl_name = owner.adt_tesl_name -> want
      | _ -> type_of_expr signatures env expr
    in
    emit_variant_literal ~indent signatures env result variant args
  | EConstructor { name; args; loc } ->
    (match Hashtbl.find_opt signatures name with
     | Some { params = [_]; result = (TNewtype _ as result); _ } ->
       ignore (type_of_expr signatures env expr);
       (match args with
        | [arg] ->
          let payload = emit arg in
          let payload = match result with
            | TNewtype info when info.secret ->
              Printf.sprintf "teslrt.MakeSecret(%s)" payload
            | _ -> payload
          in
          Printf.sprintf "%s{Value: %s}" (go_type result) payload
        | _ -> unsupported loc "Go backend requires a fully-applied newtype constructor `%s`" name)
     (* The capitalised call: an ordinary call, emitted as one. *)
     | Some ({ result = TRecord record; go_name; _ } as signature)
       when record.rec_tesl_name <> name
            && List.length signature.params = List.length args ->
       ignore (type_of_expr signatures env expr);
       Printf.sprintf "%s(%s)" go_name
         (String.concat ", " (List.map2 (fun arg want ->
            emit_expr ~expected:want ~indent signatures env arg) args signature.params))
     (* A proof term erases: `ValidPort port` is the zero-size proof value. *)
     | Some { params = []; result = TUnit; go_name = "struct{}{}"; _ } -> "struct{}{}"
     | _ -> unsupported loc "Go backend cannot emit constructor `%s`" name)
  | (EApp _ | EBinop _ | ELet _) as sql when recognise_sql sql <> None ->
    (match recognise_sql sql with
     | Some form -> emit_sql_form ~indent signatures env (Checker.expr_loc sql) form
     | None -> assert false)
  (* A CHECK's value used where its base type is expected — `fn validateId(s: String) ->
     String = UUID.validate s`.  The check is the only thing that can answer here, so its
     rejection has to be the failure: `MustCheck` traps, which is what the same program does
     on Racket (its `expectFail` on this shape catches a failure, not a returned record).
     Inside a HANDLER body the rejection becomes the request's own answer instead. *)
  | EApp _ when (match expected with
                 | Some want when (match want with TCheck _ -> false | _ -> true) ->
                   (try type_equal (type_of_expr signatures env expr) (TCheck want)
                    with Unsupported _ -> false)
                 | _ -> false) ->
    Printf.sprintf "teslrt.%s(%s)"
      (if !current_handler_body then "MustCheckRequest" else "MustCheck")
      (emit_expr ~indent signatures env expr)
  | EApp { loc; _ } as app ->
    let head, args = flatten_app [] app in
    let head = normalize_call_head head in
    (match head with
     | EVar { name = "#record-update#"; _ } ->
       (match args with
        | [ERecord { fields; _ }] ->
          ignore (type_of_expr signatures env app);
          emit_record_update ~indent signatures env loc fields
        | _ -> unsupported loc "Go backend cannot emit this record update")
     | EConstructor { name; args = constructor_args; _ }
       when record_info_of_signature signatures name <> None ->
       let info = match record_info_of_signature signatures name with
         | Some info -> info
         | None -> assert false
       in
       (match constructor_args @ args with
        | [ERecord { fields; _ }] ->
          ignore (type_of_expr signatures env app);
          emit_record_literal ~indent signatures env info fields
        | _ -> unsupported loc "Go backend cannot emit record literal `%s`" name)
     | EConstructor { name; args = constructor_args; _ }
       when adt_ctor_of_signature signatures name <> None ->
       let owner, variant = match adt_ctor_of_signature signatures name with
         | Some pair -> pair
         | None -> assert false
       in
       let result = match expected with
         | Some (TAdt (info, (_ :: _)) as want)
           when info.adt_tesl_name = owner.adt_tesl_name -> want
         | _ -> type_of_expr signatures env app
       in
       emit_variant_literal ~indent signatures env result variant
         (variant_positional_args loc variant (constructor_args @ args))
     (* A COMBINED check: run each in turn, short-circuiting on the first rejection and
        feeding the checked value to the next — Racket's `check-and`, with the fact merge
        dropped because facts erase.  Hoisted into a helper so the call site stays one
        expression whatever the number of conjuncts. *)
      (* The existential package erases to its body. *)
      | EVar { name = "make-witness"; _ } ->
        (match args with
         | [EApp { arg = body; _ }] | [body] ->
           ignore (type_of_expr signatures env app);
           emit_expr ?expected ~indent signatures env body
         | _ -> unsupported loc "Go backend cannot emit this existential package")
     | EVar { name = "check"; _ }
       when (match args with
             | conjunction :: _ ->
               (match check_conjunct_calls conjunction with
                | Some (_ :: _ :: _) -> true
                | _ -> false)
             | [] -> false) ->
       let value_ty = type_of_expr signatures env app in
       let calls = match args with
         | conjunction :: _ -> Option.value (check_conjunct_calls conjunction) ~default:[]
         | [] -> []
       in
       let captured = List.map (fun (name, supplied) ->
         let leading = match Hashtbl.find_opt signatures name with
           | Some signature ->
             List.filteri (fun index _ -> index < List.length supplied) signature.params
           | None -> List.map (fun _ -> value_ty) supplied
         in
         name, leading, List.combine supplied leading) calls in
       let helper = combined_check_helper signatures value_ty
         (List.map (fun (name, leading, _) -> name, leading) captured) in
       let argument = match args with
         | [_; argument] -> argument
         | _ -> unsupported loc
           "Go backend requires a combined check applied to exactly one value"
       in
       let capture_arguments = List.concat_map (fun (_, _, pairs) ->
         List.map (fun (value, want) ->
           emit_expr ~expected:want ~indent signatures env value) pairs) captured in
       let applied =
         Printf.sprintf "%s(%s)" helper
           (String.concat ", "
              (emit_expr ~expected:value_ty ~indent signatures env argument
               :: capture_arguments))
       in
       (match expected with
        (* A CHECK's tail: the combined check's own `Check` IS this check's result, so it is
           handed straight back — the same delegation a single-check tail performs.  Unwrapping
           here would turn a rejection into a trap, and the caller would never see the status
           the conjunct chose. *)
        | Some (TCheck inner) when not (type_unequal inner value_ty) -> applied
        | _ ->
          Printf.sprintf "teslrt.%s(%s)"
            (if !current_handler_body then "MustCheckRequest" else "MustCheck") applied)
     | EVar { name = "check"; _ } when (match List.map normalize_call_head args with
                                         | EVar { name; _ } :: _ ->
                                           dict_leaf name <> None
                                           && (match Hashtbl.find_opt signatures name with
                                               | Some { result = TCheck _; _ } -> false
                                               | Some _ -> true | None -> false)
                                         | _ -> false) ->
       (* `check Dict.requireKey key d`: the leaf builds the Check, and `check` is what turns
          a rejection into the request's answer — the same two halves as a named check. *)
       let call_args = match List.map normalize_call_head args with
         | _ :: call_args -> call_args
         | [] -> []
       in
       let leaf = match List.map normalize_call_head args with
         | EVar { name; _ } :: _ ->
           (match dict_leaf name with Some leaf -> leaf | None -> assert false)
         | _ -> assert false in
       let checked = type_of_dict_leaf signatures env loc leaf call_args in
       Printf.sprintf "teslrt.%s(%s)"
         (if !current_handler_body then "MustCheckRequest" else "MustCheck")
         (emit_dict_leaf ~indent signatures env loc leaf call_args checked None)
     | EVar { name = "check"; _ } ->
       (match List.map normalize_call_head args with
        | EVar { name; _ } :: call_args ->
          ignore (type_of_expr signatures env app);
           let signature = match Hashtbl.find_opt signatures name with
             | Some signature -> signature
             | None -> unsupported loc "Go backend cannot resolve check `%s`" name
           in
           Printf.sprintf "teslrt.%s(%s(%s))"
             (if !current_handler_body then "MustCheckRequest" else "MustCheck")
             (qualified signature.sig_owner signature.go_name)
              (String.concat ", " (List.map2
                 (emit_leaf_argument ~indent signatures env name)
                 signature.params call_args))
         | _ -> unsupported loc "Go backend requires a named check function")
      | EVar { name = "not"; _ } when not (Hashtbl.mem signatures "not") ->
       ignore (type_of_expr signatures env app);
       (match args with
         | [arg] -> emit_negated ~indent signatures env arg
         | _ -> assert false)
      | EConstructor { name; args = constructor_args; _ } ->
        (match Hashtbl.find_opt signatures name with
         | Some { result = (TNewtype _ as result); _ } ->
           ignore (type_of_expr signatures env app);
           (match constructor_args @ args with
            | [arg] ->
              (* A secret's payload goes in through `MakeSecret`, so the plaintext is held by
                 the redacting carrier from the moment it is constructed. *)
              let payload = match result with
                | TNewtype info when info.secret ->
                  Printf.sprintf "teslrt.MakeSecret(%s)" (emit arg)
                | _ -> emit arg
              in
              Printf.sprintf "%s{Value: %s}" (go_type result) payload
            | _ -> assert false)
         | Some ({ result = TRecord record; go_name; _ } as signature)
           when record.rec_tesl_name <> name
                && List.length signature.params
                   = List.length (constructor_args @ args) ->
           ignore (type_of_expr signatures env app);
           Printf.sprintf "%s(%s)" go_name
             (String.concat ", " (List.map2 (fun arg want ->
                emit_expr ~expected:want ~indent signatures env arg)
                (constructor_args @ args) signature.params))
         (* A proof term erases: `ValidPort port` is the zero-size proof value. *)
         | Some { params = []; result = TUnit; go_name = "struct{}{}"; _ } -> "struct{}{}"
         | _ -> unsupported loc "Go backend cannot emit constructor `%s`" name)
      | EVar { name; _ } when set_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match set_leaf name with Some leaf -> leaf | None -> assert false in
       (* Same rule as the Dict leaves: a leaf with nothing to read an element off takes the
          expected type, and only fails when there is none. *)
       let result = match typed_with_default (type_of_expr signatures env) app, expected with
         | (Some ty, false), _ -> ty
         | _, Some (TSet _ as want) -> want
         | _ -> type_of_expr signatures env app
       in
       emit_set_leaf ~indent signatures env loc leaf args result expected
      | EVar { name; _ } when dict_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match dict_leaf name with Some leaf -> leaf | None -> assert false in
       (* `Dict.fromList []` has no pair to read a key or a value off, so where a Dict is
          EXPECTED that is what the result is — the same rule `Dict.empty` gets. *)
       let result = match typed_with_default (type_of_expr signatures env) app, expected with
         | (Some ty, false), _ -> ty
         | _, Some (TDict _ as want) -> want
         | _ -> type_of_expr signatures env app
       in
       emit_dict_leaf ~indent signatures env loc leaf args result expected
      | EVar { name; _ } when tuple_accessor name <> None ->
       let field = match tuple_accessor name with
         | Some (_, field) -> field
         | None -> assert false
       in
       ignore (type_of_expr signatures env app);
       (match args with
        | [tuple] ->
          let variant = match type_of_expr signatures env tuple with
            | TAdt (info, _) ->
              (match single_variant info with
               | Some variant -> variant
               | None -> invalid_arg "tuple accessor validated before emission")
            | _ -> invalid_arg "tuple accessor validated before emission"
          in
          Printf.sprintf "%s.%s" (selector_operand (emit tuple))
            (variant_field_go_name variant field)
        | _ -> invalid_arg "tuple accessor validated before emission")
      | EVar { name = ("forgetFact" | "attachFact"); _ } when args <> [] ->
        (* The value passes through; the proof operand disappears with the proof. *)
        emit (List.hd args)
      | EVar { name = ("get" | "post" | "put" | "delete" | "patch") as verb; _ }
        when !current_api_server <> None ->
        let server = match !current_api_server with Some s -> s | None -> assert false in
        (* `post "/p" body { … } cookie c headers { … }` — the modifiers arrive as
           keyword/value pairs in the flat argument list, the same shape the Racket api-test
           emitter scans for. *)
        let path, request_body, cookie, request_headers = match args with
          | path :: rest ->
            let rec scan body cookie headers = function
              | EVar { name = "body"; _ } :: value :: more -> scan (Some value) cookie headers more
              | EVar { name = "cookie"; _ } :: value :: more -> scan body (Some value) headers more
              | EVar { name = "headers"; _ } :: value :: more -> scan body cookie (Some value) more
              | _ :: more -> scan body cookie headers more
              | [] -> body, cookie, headers
            in
            let body, cookie, headers = scan None None None rest in
            path, body, cookie, headers
          | [] -> unsupported loc "Go backend api-test request needs a path"
        in
        (* `cookie` is one `name=value` string — the wire form, since a REQUEST cookie carries
           none of the attributes a response cookie does — and `headers { … }` is a template
           whose values are Strings rather than JSON: they go on the wire as written. *)
        let cookies = match cookie with
          | None -> "nil"
          (* Two spellings, one wire form.  `cookie "name=value"` writes the pair itself;
             `cookie { "name": value }` names the parts, which is what a test does when the
             value is computed (`mintSession "alice"`).  Both become `name=value`. *)
          | Some (ERecord { fields; _ }) ->
            Printf.sprintf "[]string{%s}"
              (String.concat ", " (List.map (fun (name, value) ->
                 let emitted =
                   if type_of_expr signatures env value = TString then
                     emit_api_test_string ~indent signatures env value
                   else unsupported (Checker.expr_loc value)
                     "Go backend api-test cookie `%s` must be a String" name
                 in
                 Printf.sprintf "%s + %s" (go_quote (name ^ "=")) emitted) fields))
          | Some value ->
            Printf.sprintf "[]string{%s}"
              (emit_api_test_string ~indent signatures env value)
        in
        let headers = match request_headers with
          | None -> "nil"
          | Some (ERecord { fields; _ }) ->
            Printf.sprintf "[]teslrt.Tuple2[string, string]{%s}"
              (String.concat ", " (List.map (fun (name, value) ->
                 let emitted =
                   if type_of_expr signatures env value = TString then
                     emit_api_test_string ~indent signatures env value
                   else unsupported (Checker.expr_loc value)
                     "Go backend api-test header `%s` must be a String" name
                 in
                 Printf.sprintf "{Tuple2First: %s, Tuple2Second: %s}" (go_quote name) emitted)
                 fields))
          (* A DICT of headers: `headers (onHost())`.  The surface takes either a literal
             template or a `Dict String String`, and a shared helper — the one every test in
             a `publicOrigin` server needs for its Host header — answers the second. *)
          | Some other when type_of_expr signatures env other = TDict (TString, TString) ->
            Printf.sprintf "teslrt.DictToList(%s)"
              (emit_expr ~expected:(TDict (TString, TString)) ~indent signatures env other)
          | Some other -> unsupported (Checker.expr_loc other)
            "Go backend api-test `headers` must be a `{ \"name\": value }` template or a \
             `Dict String String`"
        in
        Printf.sprintf "teslrt.ApiRequest(%s, %S, %s, %s, %s, %s)" server
          (String.uppercase_ascii verb)
          (emit_api_test_string ~indent signatures env path)
          (match request_body with
           | None -> "\"\""
           | Some value -> emit_api_test_body ~indent signatures env value)
          cookies headers
      (* `subscribe "/path"` opens a real connection to the server under test and reads the
         stream — the route lookup, the auth check and every declared capture check run, which
         is what makes a refused subscription fail the test where it is written. *)
      | EVar { name = "subscribe"; _ } when !current_api_server <> None ->
        let server = match !current_api_server with Some s -> s | None -> assert false in
        let path, cookie = match args with
          | path :: rest ->
            let rec scan cookie = function
              | EVar { name = "cookie"; _ } :: value :: more -> scan (Some value) more
              | _ :: more -> scan cookie more
              | [] -> cookie
            in
            path, scan None rest
          | [] -> unsupported loc "Go backend api-test `subscribe` needs a path"
        in
        let cookies = match cookie with
          | None -> "nil"
          | Some value ->
            Printf.sprintf "[]string{%s}"
              (emit_api_test_string ~indent signatures env value)
        in
        Printf.sprintf "teslrt.SubscribeStream(%s, %s, %s)" server
          (emit_api_test_string ~indent signatures env path) cookies
      (* `collect stream …` — the three shapes Racket's `api-test-collect` implements: wait for
         a COUNT, wait UNTIL a matching event, or take whatever arrives within the timeout. The
         first two treat a timeout as a test failure; the third does not, since "nothing was
         published" is exactly what it may be asserting. *)
      | EVar { name = "collect"; _ } ->
        let stream, count, until, timeout = match args with
          | stream :: rest ->
            let rec scan count until timeout = function
              | EVar { name = "count"; _ } :: value :: more -> scan (Some value) until timeout more
              | EVar { name = "until"; _ } :: value :: more -> scan count (Some value) timeout more
              | EVar { name = "timeout"; _ } :: value :: more -> scan count until (Some value) more
              | _ :: more -> scan count until timeout more
              | [] -> count, until, timeout
            in
            let count, until, timeout = scan None None None rest in
            stream, count, until, timeout
          | [] -> unsupported loc "Go backend `collect` needs a stream"
        in
        ignore (type_of_expr signatures env app);
        let stream = emit_expr ~expected:TStream ~indent signatures env stream in
        let millis = match timeout with
          | Some value -> emit_expr ~expected:TInt ~indent signatures env value
          | None -> unsupported loc "Go backend `collect` needs a `timeout`"
        in
        (match count, until with
         | Some _, Some _ -> unsupported loc
           "Go backend `collect` takes `count` or `until`, not both"
         | Some count, None ->
           Printf.sprintf "teslrt.CollectCount(%s, %s, %s)" stream
             (emit_expr ~expected:TInt ~indent signatures env count) millis
         | None, Some until ->
           (* The `until` pattern is a template like an api-test body, matched by containment
              against each event — the same rule `includesWhere` follows. *)
           let pattern = match until with
             | ERecord _ as template ->
               Printf.sprintf "teslrt.JsonParseBody(%s).JsonRaw()"
                 (emit_api_test_body ~indent signatures env template)
             | other -> unsupported (Checker.expr_loc other)
               "Go backend `collect … until` takes a `{ \"field\": value }` pattern"
           in
           Printf.sprintf "teslrt.CollectUntil(%s, %s, %s)" stream pattern millis
         | None, None -> Printf.sprintf "teslrt.CollectWithin(%s, %s)" stream millis)
      (* `deadJobs` handed the queue as a VALUE — see the matching note in the type rule.
         It reads the store and runs no worker, so it needs no dispatcher and therefore no
         job type: the queue itself is enough. *)
      | EVar { name = "deadJobs"; _ }
        when (match args with
              | [argument] ->
                (match typed_with_default (type_of_expr signatures env) argument with
                 | Some (TRecord info), _ ->
                   Option.fold ~none:false
                     ~some:(fun types -> Hashtbl.mem types.queues info.rec_tesl_name)
                     !current_types
                 | _ -> false)
              | _ -> false) ->
        ignore (type_of_expr signatures env app);
        Printf.sprintf "teslrt.DeadJobs(%s)" (emit (List.hd args))
      (* The api-test queue verbs.  The worker runs through a DISPATCHER closure: the store
         holds payloads as `any` because a queue may carry several job types, and the emitter
         is what knows which one this queue carries. *)
      | EVar { name = ("pendingJobCount" | "drainQueue" | "processNextJob"
                      | "processNextDeadJob" | "deadJobs") as verb; _ }
        when queue_argument args <> None ->
        let info = match queue_argument args with
          | Some name -> queue_of_job_type loc name
          | None -> assert false
        in
        ignore (type_of_expr signatures env app);
        let queue = qualified info.qu_owner info.qu_go_var in
        let row_go = match Option.bind !current_types
                             (fun types -> Hashtbl.find_opt types.records info.qu_job_type) with
          | Some row -> go_type (TRecord row)
          | None -> unsupported loc "Go backend cannot resolve job type `%s`" info.qu_job_type
        in
        let dead = verb = "processNextDeadJob" in
        (* Every job type the queue carries, paired with the worker that runs it.  One queue
           may carry several, and the dispatcher below type-switches over them — which is
           what the store's `any` payload is for.  The dead-letter dispatcher covers only the
           job types that declare a dead-letter worker; a queue with none at all cannot run
           `processNextDeadJob` and says so. *)
        let wirings = List.filter_map (fun (job_type, worker, dead_worker) ->
          match dead, dead_worker with
          | false, _ -> Some (job_type, worker)
          | true, Some dead_worker -> Some (job_type, dead_worker)
          | true, None -> None) info.qu_jobs in
        if wirings = [] then unsupported loc
          "Go backend: queue `%s` has no dead-letter worker" info.qu_tesl_name;
        let row_of job_type =
          match Option.bind !current_types
                  (fun types -> Hashtbl.find_opt types.records job_type) with
          | Some row -> go_type (TRecord row)
          | None -> unsupported loc "Go backend cannot resolve job type `%s`" job_type
        in
        let worker_of worker =
          match Hashtbl.find_opt signatures worker with
          | Some signature -> qualified signature.sig_owner signature.go_name
          | None -> unsupported loc "Go backend cannot resolve worker `%s`" worker
        in
        (* The dispatcher is spliced as an ARGUMENT inside the wrapper closure, so its body
           sits one level deeper than the wrapper's statements.

           The FIRST job type is also the one the `JobResult` carries, so its case captures
           the job.  Another type running is not an error — the queue carries it on purpose —
           but a `processNextJob` that answered a `JobResult` holding the zero value of the
           wrong type would be, so the capture is only claimed where it is true. *)
        let inner = indent ^ "\t" in
        let dispatcher =
          let cases = List.mapi (fun index (job_type, worker) ->
            let capture =
              if index = 0 then Printf.sprintf "%s\t\tteslJob = teslTyped\n" inner else "" in
            Printf.sprintf "%s\tcase %s:\n%s%s\t\t_ = %s(teslTyped)\n"
              inner (row_of job_type) capture inner (worker_of worker)) wirings in
          Printf.sprintf
            "func(teslPayload any) teslrt.JobOutcome {\n%s\tswitch teslTyped := teslPayload.(type) {\n%s%s\tdefault:\n%s\t\tpanic(\"%s: unexpected job payload\")\n%s\t}\n%s\treturn teslrt.JobOutcome{OK: true}\n%s}"
            inner (String.concat "" cases) inner inner info.qu_tesl_name inner inner inner
        in
        (match verb with
         | "pendingJobCount" -> Printf.sprintf "teslrt.PendingJobCount(%s)" queue
         (* `deadJobs` reads the store; no worker runs, so the dispatcher is unused here. *)
         | "deadJobs" -> Printf.sprintf "teslrt.DeadJobs(%s)" queue
         | "drainQueue" ->
           (* A drain is a statement; the count it reports is not surfaced in Tesl. *)
           Printf.sprintf
             "(func() struct{} {\n%s\tvar teslJob %s\n%s\t_ = teslJob\n%s\t_ = teslrt.DrainQueue(%s, %s, 1000)\n%s\treturn struct{}{}\n%s}())"
             indent row_go indent indent queue dispatcher indent indent
         | _ ->
           let runner = if verb = "processNextDeadJob" then "ProcessNextDeadJob"
                        else "ProcessNextJob" in
           (* The claimed job is captured so the result can carry it, which is what
              `expectJobOk` reads — and what `JobFailed job error` needs too. *)
           String.concat "" [
             Printf.sprintf "(func() teslrt.JobResult[%s] {\n" row_go;
             Printf.sprintf "%s\tvar teslJob %s\n" indent row_go;
             Printf.sprintf "%s\tteslOutcome := teslrt.%s(%s, %s)\n"
               indent runner queue dispatcher;
             Printf.sprintf "%s\tif !teslOutcome.Ran {\n" indent;
             Printf.sprintf "%s\t\tpanic(teslrt.EmptyQueue(%s, %s))\n"
               indent (go_quote info.qu_tesl_name) (go_quote verb);
             Printf.sprintf "%s\t}\n" indent;
             Printf.sprintf "%s\tif !teslOutcome.OK {\n" indent;
             Printf.sprintf "%s\t\treturn teslrt.JobFailed(teslJob, teslOutcome.Message)\n" indent;
             Printf.sprintf "%s\t}\n" indent;
             Printf.sprintf "%s\treturn teslrt.JobOk(teslJob)\n" indent;
             Printf.sprintf "%s}())" indent;
           ])
      (* `initTelemetry` configures the sink, once, from `main`.  Its keyword surface parses as a
         plain application, so the arguments are folded back into keyword/value pairs here — each
         keyword's value being every token up to the next KNOWN keyword, so `endpoint ep()` stays
         the call it is written as rather than binding the function value and dropping the rest
         (the bug the Racket emitter records at the same place). *)
      | EVar { name = "initTelemetry"; _ } ->
        let rec pairs acc = function
          | [] -> List.rev acc
          | keyword :: rest ->
            (match init_telemetry_keyword keyword with
             | None -> pairs acc rest
             | Some name ->
               let rec take value_acc = function
                 | (next :: _) as more when init_telemetry_keyword next <> None ->
                   List.rev value_acc, more
                 | value :: more -> take (value :: value_acc) more
                 | [] -> List.rev value_acc, []
               in
               let values, more = take [] rest in
               let value = match values with
                 | [] -> unsupported loc
                   "Go backend `initTelemetry` keyword `%s` has no value" name
                 | [ single ] -> single
                 | fn :: arguments ->
                   (* `endpoint ep ()` / `service f x` re-folded into the call it spells. *)
                   List.fold_left (fun applied argument ->
                     EApp { fn = applied; arg = argument; loc = Checker.expr_loc argument })
                     fn arguments
               in
               pairs ((name, value) :: acc) more)
        in
        let settings = pairs [] args in
        let setting name = List.assoc_opt name settings in
        let string_of name = match setting name with
          | None -> go_quote ""
          | Some value -> emit_expr ~expected:TString ~indent signatures env value
        in
        let bool_of name default = match setting name with
          | None -> if default then "true" else "false"
          | Some value -> strip_outer_parens (emit_expr ~expected:TBool ~indent signatures env value)
        in
        let int_of name default = match setting name with
          | None -> string_of_int default
          | Some value ->
            Printf.sprintf "teslrt.MillisOf(%s)"
              (emit_expr ~expected:TInt ~indent signatures env value)
        in
        let float_of name default = match setting name with
          | None -> default
          | Some value -> emit_expr ~expected:TFloat ~indent signatures env value
        in
        (* Metrics default ON and traces OFF, matching `init-opentelemetry!`: an aggregated
           counter is cheap, while spans are per-request and unaggregated, so their volume is
           opt-in. *)
        Printf.sprintf "teslrt.InitTelemetry(%s, %s, %s, %s, %s, %s, %s)"
          (string_of "service") (string_of "endpoint")
          (bool_of "console" false) (bool_of "metrics" true) (bool_of "traces" false)
          (int_of "metricsInterval" 60000) (float_of "traceRatio" "1.0")
      (* The secret-accepting header builders.  They are the sanctioned sink for a `secret`,
         so the ARGUMENT is where the unwrapping happens: a secret newtype hands over its
         payload, and a plain String is wrapped on the way in — which is what
         `make-secret-header` accepts on Racket too.  The runtime then holds the plaintext
         behind an unguessable handle, so what the returned `Tuple2 String String` carries is
         not the secret itself. *)
      (* The password plaintext reaches the runtime as a `SecretString`: a secret newtype hands
         over its payload, a plain newtype is unwrapped and re-wrapped, and a String is wrapped.
         Nothing at the call site holds it as a bare string. *)
      | EVar { name = ("Crypto.hashPassword" | "Crypto.checkPassword") as leaf; _ }
        when args <> [] ->
        ignore (type_of_expr signatures env app);
        let plaintext_argument value =
          let emitted = emit value in
          match type_of_expr signatures env value with
          | TNewtype info when info.secret ->
            Printf.sprintf "%s.Value" (selector_operand emitted)
          | TNewtype _ ->
            Printf.sprintf "teslrt.MakeSecret(%s.Value)" (selector_operand emitted)
          | TString -> Printf.sprintf "teslrt.MakeSecret(%s)" emitted
          | _ -> unsupported loc
            "Go backend `%s` takes a String or a newtype over String" leaf
        in
        (match leaf, args with
         | "Crypto.hashPassword", [plaintext] ->
           Printf.sprintf "teslrt.HashPassword(%s)" (plaintext_argument plaintext)
         | "Crypto.checkPassword", [stored; plaintext] ->
           Printf.sprintf "teslrt.CheckPassword(%s, %s)"
             (emit stored) (plaintext_argument plaintext)
         | _ -> unsupported loc "Go backend `%s` is applied to the wrong arity" leaf)
      (* ── `Tesl.Agent`: the forms a signature cannot describe ──────────────
         Typed in `type_of_expr` by the matching arms; here each renders to the runtime
         call, with the pieces a signature could not carry — a chosen decoder, a function
         reference, a derived tool — supplied from the same places the typing read them. *)
      | EVar { name = "decodeAs"; _ } when agent_form signatures "decodeAs" "teslrt.DecodeAs" ->
        let type_name, json, _ = agent_decode_as_parts signatures env loc args in
        Printf.sprintf "teslrt.DecodeAs(%s, %s, %s)"
          (go_quote type_name) (emit_expr ~expected:TString ~indent signatures env json)
          (codec_decode_ref type_name)
      | EVar { name = "tool"; _ } when agent_form signatures "tool" "teslrt.ToolOf" ->
        let name, description, schema, validator, dispatch =
          agent_tool_parts signatures env loc args in
        let text value = emit_expr ~expected:TString ~indent signatures env value in
        let dispatch_go = match agent_tool_dispatch signatures env loc dispatch with
          | `Direct signature -> qualified signature.sig_owner signature.go_name
          | `Captured (signature, value) ->
            Printf.sprintf "teslrt.ToolDispatchWith(%s, %s)"
              (qualified signature.sig_owner signature.go_name) (emit value)
        in
        Printf.sprintf "teslrt.ToolOf(%s, %s, %s, %s, %s)"
          (text name) (text description) (text schema)
          (agent_function_go signatures loc "a tool validator" validator) dispatch_go
      | EVar { name = "asTool"; _ } when agent_form signatures "asTool" "teslrt.ToolOf#asTool" ->
        ignore (type_of_expr signatures env app);
        emit_astool ~indent signatures (agent_astool_decl loc args)
      | EVar { name = "serverTools"; _ }
        when agent_form signatures "serverTools" "teslrt.ServerTools" ->
        ignore (type_of_expr signatures env app);
        let _, user, user_type, selected =
          agent_endpoint_tools signatures env loc "serverTools" args in
        let emitted_user = emit user in
        Printf.sprintf "[]teslrt.Tool{%s}"
          (String.concat ", " (List.map (fun (name, description, schema, endpoint) ->
             emit_endpoint_tool signatures loc name description schema endpoint
               user_type emitted_user) selected))
      | EVar { name = "humanActions"; _ }
        when agent_form signatures "humanActions" "teslrt.HumanActions" ->
        ignore (type_of_expr signatures env app);
        let server_name, _, _, selected =
          agent_endpoint_tools signatures env loc "humanActions" args in
        Printf.sprintf "teslrt.HumanActions(%s, []teslrt.HumanActionSpec{%s})"
          (go_quote server_name)
          (String.concat ", " (List.map (fun (name, description, schema, _) ->
             Printf.sprintf "teslrt.HumanActionOf(%s, %s, %s)"
               (go_quote name) (go_quote description) (go_quote schema)) selected))
      | EVar { name = "askFor"; _ } when agent_form signatures "askFor" "teslrt.AskFor" ->
        let agent, prompt, decoder, retries, _ = agent_ask_for_parts signatures env loc args in
        Printf.sprintf "teslrt.AskFor(%s, %s, %s, %s)"
          (emit agent) (emit_expr ~expected:TString ~indent signatures env prompt)
          (agent_function_go signatures loc "an `askFor` decoder" decoder)
          (emit_expr ~expected:TInt ~indent signatures env retries)
      | EVar { name = "agentRun"; _ } when agent_form signatures "agentRun" "teslrt.AgentRun" ->
        ignore (type_of_expr signatures env app);
        (match args with
         | [agent; prompt; publisher] ->
           Printf.sprintf "teslrt.AgentRun(%s, %s, %s)"
             (emit agent) (emit_expr ~expected:TString ~indent signatures env prompt)
             (agent_publisher_go ~indent signatures env loc
                "the `agentRun` publisher" publisher)
         | _ -> unsupported loc "Go backend `agentRun` is applied to the wrong arity")
      | EVar { name = "converseStreaming"; _ }
        when agent_form signatures "converseStreaming" "teslrt.ConverseStreaming" ->
        ignore (type_of_expr signatures env app);
        (match args with
         | [conversation; prompt; publish] ->
           Printf.sprintf "teslrt.ConverseStreaming(%s, %s, %s)"
             (emit conversation) (emit_expr ~expected:TString ~indent signatures env prompt)
             (agent_publisher_go ~indent signatures env loc
                "the `converseStreaming` publisher" publish)
         | _ -> unsupported loc
           "Go backend `converseStreaming` is applied to the wrong arity")
      | EVar { name = ("HttpClient.bearer" | "HttpClient.secretHeader") as leaf; _ }
        when args <> [] ->
        ignore (type_of_expr signatures env app);
        let secret_argument value =
          let emitted = emit value in
          match type_of_expr signatures env value with
          | TNewtype info when info.secret ->
            Printf.sprintf "%s.Value" (selector_operand emitted)
          | TString -> Printf.sprintf "teslrt.MakeSecret(%s)" emitted
          | _ -> unsupported loc
            "Go backend `%s` takes a `secret` over String" leaf
        in
        (match leaf, args with
         | "HttpClient.bearer", [secret] ->
           Printf.sprintf "teslrt.HttpBearer(%s)" (secret_argument secret)
         | "HttpClient.secretHeader", [name; secret] ->
           Printf.sprintf "teslrt.HttpSecretHeader(%s, %s)"
             (emit_expr ~expected:TString ~indent signatures env name)
             (secret_argument secret)
         | _ -> unsupported loc "Go backend `%s` is applied to the wrong arity" leaf)
      | EVar { name = ("expectJobOk" | "expectJobFailed") as verb; _ } when args <> [] ->
        ignore (type_of_expr signatures env app);
        Printf.sprintf "teslrt.%s(%s)"
          (if verb = "expectJobOk" then "ExpectJobOk" else "ExpectJobFailed")
          (emit (List.hd args))
      (* The api-test JSON surface.  The runtime keeps Tesl's argument order, so the arguments
         go through unshuffled; `bodyField` is `fieldAt` on the response's body. *)
      | EVar { name = ("isNull" | "isNotNull" | "isEmpty" | "isNotEmpty" | "jsonLength"
                      | "jsonInt" | "jsonString" | "jsonBool" | "jsonArray" | "jsonObject"
                      | "hasField" | "hasLength" | "arrayAt" | "fieldAt" | "jsonContains"
                      | "includesWhere" | "excludesWhere"
                      | "bodyField") as verb; _ } ->
        ignore (type_of_expr signatures env app);
        (* The RESPONSE positions (`bodyField resp`) hand the value over as it is. *)
        let json_argument index =
          match List.nth_opt args index with
          | Some argument -> emit argument
          | None -> unsupported loc "Go backend requires `%s` applied to its argument(s)" verb
        in
        (* The INSPECTED positions take any value, not only a JSON handle: Racket's predicates
           normalise whatever they are given (`api-test-normalize-json` runs the value→jsexpr
           walk first), so `hasField "k" job` on a plain record and `isNotNull err` on a String
           are legitimate assertions there.  Such a value is wrapped through its own encoder,
           which is the shape that walk produces. *)
        let json_value_argument index =
          match List.nth_opt args index with
          | Some argument ->
            (match type_of_expr signatures env argument with
             | TJson -> emit argument
             | ty ->
               (* A type with no wire shape (a check, a stream, a function) has nothing to
                  inspect, so it is refused by name rather than crashing the emitter. *)
               let encoder =
                 try !value_encoder_hook ty with Invalid_argument _ ->
                   unsupported loc
                     "Go backend `%s` cannot inspect a `%s` as JSON" verb (go_type ty)
               in
               Printf.sprintf "teslrt.JsonValueOf(%s(%s))" encoder
                 (emit_expr ~expected:ty ~indent signatures env argument))
          | None -> unsupported loc "Go backend requires `%s` applied to its argument(s)" verb
        in
        let string_argument index =
          match List.nth_opt args index with
          | Some argument -> emit_expr ~expected:TString ~indent signatures env argument
          | None -> unsupported loc "Go backend requires `%s` applied to its argument(s)" verb
        in
        let int_argument index =
          match List.nth_opt args index with
          | Some argument -> emit_expr ~expected:TInt ~indent signatures env argument
          | None -> unsupported loc "Go backend requires `%s` applied to its argument(s)" verb
        in
        (* `isNull` / `isNotNull` are the two verbs that take a value RATHER than a JSON
           handle as well: Racket normalises whatever it is given, so `isNotNull err` on a
           plain String is a legitimate assertion there.  The value goes through its own
           encoder, which is the shape the normalising walk would have produced. *)
        (match verb with
         | "isNull" -> Printf.sprintf "teslrt.JsonIsNull(%s)" (json_value_argument 0)
         | "isNotNull" -> Printf.sprintf "teslrt.JsonIsNotNull(%s)" (json_value_argument 0)
         | "isEmpty" -> Printf.sprintf "teslrt.JsonIsEmpty(%s)" (json_value_argument 0)
         | "isNotEmpty" -> Printf.sprintf "teslrt.JsonIsNotEmpty(%s)" (json_value_argument 0)
         | "jsonLength" -> Printf.sprintf "teslrt.JsonLength(%s)" (json_value_argument 0)
         | "jsonInt" -> Printf.sprintf "teslrt.JsonAsInt(%s)" (json_value_argument 0)
         | "jsonString" -> Printf.sprintf "teslrt.JsonAsString(%s)" (json_value_argument 0)
         | "jsonBool" -> Printf.sprintf "teslrt.JsonAsBool(%s)" (json_value_argument 0)
         (* `jsonArray`/`jsonObject` assert the shape and hand the value back; the assertion
            happens inside the length/field helpers that follow, so the value passes through. *)
         | "jsonArray" | "jsonObject" -> json_value_argument 0
         | "hasField" ->
           Printf.sprintf "teslrt.JsonHasField(%s, %s)" (string_argument 0)
             (json_value_argument 1)
         | "hasLength" ->
           Printf.sprintf "teslrt.JsonHasLength(%s, %s)" (int_argument 0)
             (json_value_argument 1)
         | "arrayAt" ->
           Printf.sprintf "teslrt.JsonArrayAt(%s, %s)" (int_argument 0)
             (json_value_argument 1)
         | "fieldAt" ->
           Printf.sprintf "teslrt.JsonFieldAt(%s, %s)" (string_argument 0)
             (json_value_argument 1)
         | "bodyField" ->
           Printf.sprintf "teslrt.JsonFieldAt(%s, %s.Body)"
             (string_argument 0) (selector_operand (json_argument 1))
         (* `includesWhere { "field": value } events`: the PATTERN is a template like an
            api-test body, matched against each element by containment — so an element carrying
            an id and a timestamp the test does not pin still matches. *)
         | "includesWhere" | "excludesWhere" ->
           let pattern = match List.nth_opt args 0 with
             | Some (ERecord _ as template) ->
               Printf.sprintf "teslrt.JsonParseBody(%s).JsonRaw()"
                 (emit_api_test_body ~indent signatures env template)
             | Some _ ->
               Printf.sprintf "%s.JsonRaw()" (selector_operand (json_value_argument 0))
             | None -> unsupported loc "Go backend requires `%s` applied to 2 arguments" verb
           in
           Printf.sprintf "teslrt.Json%s(%s, %s)"
             (if verb = "includesWhere" then "IncludesWhere" else "ExcludesWhere")
             pattern (json_value_argument 1)
         | _ ->
           (* jsonContains: the needle is an ordinary Tesl value, compared structurally. *)
           let needle = match List.nth_opt args 0 with
             | Some argument ->
               (match type_of_expr signatures env argument with
                | TJson -> emit argument
                | TString | TInt | TBool | TFloat -> emit argument
                | _ -> unsupported loc
                  "Go backend `jsonContains` takes a scalar or an api-test value as its needle")
             | None -> unsupported loc "Go backend requires `jsonContains` applied to 2 arguments"
           in
           Printf.sprintf "teslrt.JsonContains(%s, %s)" needle (json_argument 1))
      | EVar { name = ("statusOk" | "statusClientError" | "statusServerError") as predicate; _ } ->
        let go_name = match predicate with
          | "statusOk" -> "StatusOk"
          | "statusClientError" -> "StatusClientError"
          | _ -> "StatusServerError"
        in
        Printf.sprintf "teslrt.%s(%s)" go_name
          (String.concat ", " (List.map (fun arg ->
             emit_expr ~expected:TInt ~indent signatures env arg) args))
      (* The cookie writer targets the response the scope owns. *)
      | EVar { name = "Http.clearSessionCookie"; _ } ->
        "teslrt.ClearSessionCookie(teslScope)"
      | EVar { name = "Http.setSessionCookie"; _ } when args <> [] ->
        ignore (type_of_expr signatures env app);
        Printf.sprintf "teslrt.SetSessionCookie(teslScope, %s)" (emit (List.hd args))
      | EVar { name = ("Http.sessionToken" | "responseCookie") as reader; _ } when args <> [] ->
        ignore (type_of_expr signatures env app);
        Printf.sprintf "teslrt.%s(%s)"
          (if reader = "Http.sessionToken" then "SessionToken" else "ResponseCookie")
          (emit (List.hd args))
      | EVar { name = ("detachFact" | "introAnd" | "andLeft" | "andRight"); _ } ->
        List.iter (fun arg -> ignore (type_of_expr signatures env arg)) args;
        "struct{}{}"
      | EVar { name; _ } when higher_order_leaf name <> None && Hashtbl.mem signatures name ->
       let hof = match higher_order_leaf name with Some hof -> hof | None -> assert false in
       emit_hof ~indent signatures env loc name hof args
         (type_of_expr signatures env app)
      (* The Either combinators.  The plain ones are runtime calls; the three that take a
         function are emitted INLINE — a callback is inlined rather than passed as a Go func
         value, the same rule the list leaves follow, and an Either has one payload so there
         is no loop, only the two arms. *)
      | EVar { name = ("Either.isLeft" | "Either.isRight" | "Either.fromLeft"
                      | "Either.fromRight" | "Either.toMaybe" | "Either.withDefault"
                      | "Either.fromMaybe") as name; _ } when Hashtbl.mem signatures name ->
        let result = type_of_expr signatures env app in
        (* `Either.withDefault 99 (Left "err")` is the one of these whose two arguments have
           to AGREE: the Either argument never mentions its Right side, and the default is
           what settles it.  Emitting the constructor on its own inference would build an
           `Either[string, struct{}]` for a call whose other argument makes it
           `Either[string, teslrt.Int]`, which Go rejects — rightly, since they are two
           types.  So the settled type is handed to the argument as its expectation. *)
        let emit_argument index arg =
          if name <> "Either.withDefault" || index <> 1 then emit arg
          else match type_of_expr signatures env arg with
            | TAdt (info, [left; TAnon]) ->
              emit_expr ~expected:(TAdt (info, [left; result])) ~indent signatures env arg
            | _ -> emit arg
        in
        let go = match name with
          | "Either.isLeft" -> "teslrt.EitherIsLeft"
          | "Either.isRight" -> "teslrt.EitherIsRight"
          | "Either.fromLeft" -> "teslrt.EitherFromLeft"
          | "Either.fromRight" -> "teslrt.EitherFromRight"
          | "Either.toMaybe" -> "teslrt.EitherToMaybe"
          | "Either.withDefault" -> "teslrt.EitherWithDefault"
          | _ -> "teslrt.EitherFromMaybe"
        in
        Printf.sprintf "%s(%s)" go (String.concat ", " (List.mapi emit_argument args))
      | EVar { name = ("Either.map" | "Either.mapLeft" | "Either.andThen") as name; _ }
        when Hashtbl.mem signatures name ->
        let result = type_of_expr signatures env app in
        let left_type, right_type = match result with
          | TAdt (_, [left; right]) -> go_type left, go_type right
          | _ -> invalid_arg "Either combinator validated before emission"
        in
        let callable = normalize_call_head (List.nth args 0) in
        let payload = match type_of_expr signatures env (List.nth args 1) with
          | TAdt (_, [left; right]) -> if name = "Either.mapLeft" then left else right
          | _ -> invalid_arg "Either combinator validated before emission"
        in
        let depth = String.length indent in
        let inner = indent ^ "\t" in
        let body_indent = inner ^ "\t" in
        let subject = Printf.sprintf "teslEither%d" depth in
        let binder = match callable_binders callable [Printf.sprintf "teslValue%d" depth] with
          | [binder] -> binder
          | _ -> invalid_arg "Either combinator validated before emission"
        in
        (* `mapLeft` transforms the LEFT arm and passes the right through; the other two are
           the mirror image. *)
        let left_side = name = "Either.mapLeft" in
        let transformed_tag = if left_side then "EitherLeft" else "EitherRight" in
        let transformed_field = if left_side then "LeftValue" else "RightValue" in
        let passthrough_field = if left_side then "RightValue" else "LeftValue" in
        let applied =
          emit_applied ~indent:body_indent signatures env callable [payload] [binder] in
        (* `andThen`'s function already answers an Either, so its arm returns it as it is. *)
        let rebuilt =
          if name = "Either.andThen" then applied
          else Printf.sprintf "teslrt.%s[%s, %s](%s)"
            (if left_side then "Left" else "Right") left_type right_type applied
        in
        let passthrough = Printf.sprintf "teslrt.%s[%s, %s](%s.%s)"
          (if left_side then "Right" else "Left") left_type right_type subject passthrough_field in
        let bind = if binder = "_"
          then Printf.sprintf "%s_ = %s.%s\n" body_indent subject transformed_field
          else Printf.sprintf "%s%s := %s.%s\n" body_indent binder subject transformed_field in
        Printf.sprintf
          "(func() %s {\n%s%s := %s\n%sif %s.Tag == teslrt.%s {\n%s%sreturn %s\n%s}\n%sreturn %s\n%s}())"
          (go_type result) inner subject
          (emit_expr ~indent:inner signatures env (List.nth args 1))
          inner subject transformed_tag
          bind body_indent rebuilt
          inner
          inner passthrough indent
      | EVar { name = "Either.partition"; _ } when Hashtbl.mem signatures "Either.partition" ->
        (* The empty-list case needs its element type spelled out, for the reason the typing
           side gives: `[]` alone would emit a `[]teslrt.Int`. *)
        (match type_of_expr signatures env app, List.nth args 0 with
         | TAdt (_, [TList left; TList right]), (EList { elems = []; _ } as empty) ->
           let element = match adt_ctor_of_signature signatures "Left" with
             | Some (info, _) -> TList (TAdt (info, [left; right]))
             | None -> invalid_arg "Either.partition validated before emission"
           in
           Printf.sprintf "teslrt.EitherPartition(%s)"
             (emit_expr ~expected:element ~indent signatures env empty)
         | _ -> Printf.sprintf "teslrt.EitherPartition(%s)" (emit (List.nth args 0)))
      | EVar { name = ("List.range" | "List.repeat") as name; _ }
        when Hashtbl.mem signatures name ->
        ignore (type_of_expr signatures env app);
        let go = if name = "List.range" then "teslrt.ListRange" else "teslrt.ListRepeat" in
        Printf.sprintf "%s(%s)" go (String.concat ", " (List.map emit args))
      | EVar { name; _ } when list_leaf name <> None && Hashtbl.mem signatures name ->
       let leaf = match list_leaf name with Some leaf -> leaf | None -> assert false in
       ignore (type_of_expr signatures env app);
       let element = match List.nth args leaf.leaf_list_index with
         | EList { elems = []; _ } when leaf.leaf_result = `Inner -> TList TInt
         | EList { elems = []; _ }
           when List.mem leaf.leaf_name
                  ["List.sum"; "List.product"; "List.isEmpty"; "List.length"] -> TInt
         | arg ->
           (match type_of_expr signatures env arg with
            | TList element -> element
            | _ -> invalid_arg "list leaf validated before emission")
       in
       let emitted = List.mapi (fun index arg ->
         match arg with
         | EList { elems = []; _ } when index = leaf.leaf_list_index ->
           emit_expr ~expected:(TList element) ~indent signatures env arg
         | _ -> emit arg) args in
       let emitted = match leaf.leaf_closure with
         | `None -> emitted
         | `Equal -> emitted @ [element_equal_func element]
         | `Less -> emitted @ [element_less_func element]
       in
       Printf.sprintf "%s(%s)" leaf.leaf_go (String.concat ", " emitted)
      (* A call through a function VALUE is an ordinary Go call on the binding. *)
      | EVar { name; _ } when (match List.assoc_opt name env with
                               | Some (TFunc _) -> true | _ -> false) ->
        let params = match List.assoc_opt name env with
          | Some (TFunc (params, _)) -> params
          | _ -> assert false
        in
        ignore (type_of_expr signatures env app);
        Printf.sprintf "%s(%s)" (local_ident name)
          (String.concat ", " (List.map2 (fun arg want ->
             emit_expr ~expected:want ~indent signatures env arg) args params))
      | EVar { name; _ } ->
       let signature = match Hashtbl.find_opt signatures name with
         | Some signature -> signature
         | None -> unsupported loc "Go backend cannot resolve function `%s`" name
       in
       let args = normalize_call_args signature.params args in
       ignore (type_of_expr signatures env app);
       let instantiated_params, _ =
         instantiated_call_types (type_of_expr signatures env) loc name signature args in
       let supplied = List.length args in
       let total = List.length instantiated_params in
       let leading = List.filteri (fun index _ -> index < supplied) instantiated_params in
       let emitted = List.map2 (fun arg want ->
         emit_leaf_argument ~indent signatures env name want arg) args leading in
       if supplied < total then
         (* Partially applied: the runtime combinator closes over what was given. *)
         (match partial_application_combinator ~supplied ~total with
          | Some combinator ->
            Printf.sprintf "%s(%s, %s)" combinator
              (qualified signature.sig_owner signature.go_name) (String.concat ", " emitted)
          | None -> unsupported loc
            "Go backend supports partial application up to three parameters; `%s` takes %d"
            name total)
       else
       (* A callee that may write to the response takes the request scope FIRST.  The
          caller always has one to pass: the checker requires it to declare `cookieCap`
          too, which is what gave the caller its own scope parameter. *)
       let scope_argument =
         if not signature.sig_needs_scope then []
         else if !current_scope_in_hand then [ "teslScope" ] else [ "nil" ]
       in
       baked_call (qualified signature.sig_owner signature.go_name)
          (scope_argument @ emitted)
      (* The same call, emitted: the head is an expression of func type. *)
      | head when (match type_of_expr signatures env head with TFunc _ -> true | _ -> false) ->
        let params = match type_of_expr signatures env head with
          | TFunc (params, _) -> params
          | _ -> assert false
        in
        ignore (type_of_expr signatures env app);
        Printf.sprintf "%s(%s)" (selector_operand (emit head))
          (String.concat ", " (List.map2 (fun arg want ->
             emit_expr ~expected:want ~indent signatures env arg) args params))
     | _ -> unsupported loc "Go backend supports calls to named functions only")
  (* One side is an UNTYPED api-test value: compare structurally through the runtime, with the
     typed side ENCODED the same way a response body is, so the two directions cannot disagree
     about what a value looks like as JSON. *)
  | EBinop { op = (BEq | BNeq) as op; left; right; loc; _ }
    (* Tolerantly: one side may carry no type of its own — a bare `Nothing`, a `Left e` that
       says nothing about the Right parameter — and asking whether THAT side is untyped JSON
       must not be what refuses the comparison. *)
    when (let json side =
            match typed_with_default (type_of_expr signatures env) side with
            | Some TJson, _ -> true
            | _ -> false
          in
          json left <> json right) ->
    let json_side, typed_side =
      if type_of_expr signatures env left = TJson then left, right else right, left in
    let typed_ty = type_of_expr signatures env typed_side in
    (* The typed side is handed over in the shape the runtime compares against: a scalar as
       itself, a newtype unwrapped, a list lifted.  Anything richer (a record, a dict) fails
       closed rather than being compared as something it is not — an api-test compares FIELDS,
       and that is the shape the corpus uses. *)
    let rec comparand ty emitted = match ty with
      | TInt | TString | TBool | TFloat -> emitted
      | TNewtype info when not info.secret ->
        comparand info.base (Printf.sprintf "%s.Value" (selector_operand emitted))
      | TList (TInt | TString | TBool | TFloat) ->
        Printf.sprintf "teslrt.JsonListOf(%s)" emitted
      | _ -> unsupported loc
        "Go backend compares an api-test JSON value against a scalar, a newtype over one, or \
         a list of those"
    in
    let encoded =
      if typed_ty = TJson then emit_expr ~indent signatures env typed_side
      else comparand typed_ty
        (emit_expr ~expected:typed_ty ~indent signatures env typed_side)
    in
    Printf.sprintf "%steslrt.JsonEqual(%s, %s)"
      (if op = BNeq then "!" else "")
      (emit_expr ~indent signatures env json_side) encoded
  (* The money-rate algebra: a rate materialising into an amount, a rate rescaled, or an
     amount divided by a quantity.  Each is one runtime call rather than an operator, because
     each is a different operation on the exact rational inside the rate — and the one that
     ROUNDS (a rate becoming money) is named so it cannot happen by accident. *)
  | EBinop { op; left; right; loc; _ }
    when (match money_rate_binop ?expected op
                  (try type_of_expr signatures env left with Unsupported _ -> TFailure)
                  (try type_of_expr signatures env right with Unsupported _ -> TFailure) with
          | Some _ -> true | None -> false) ->
    let left_ty = type_of_expr signatures env left in
    let right_ty = type_of_expr signatures env right in
    let rate, quantity = if is_money_rate left_ty then left, right else right, left in
    let rendered side ty = emit_expr ~expected:ty ~indent signatures env side in
    (match money_rate_binop ?expected op left_ty right_ty with
     | Some (`Consume | `ConsumeFlipped) ->
       Printf.sprintf "teslrt.MoneyRateMul(%s, %s)"
         (rendered rate (if is_money_rate left_ty then left_ty else right_ty))
         (rendered quantity TQuantity)
     | Some (`Scale | `ScaleFlipped) ->
       Printf.sprintf "teslrt.MoneyRateScale(%s, %s)"
         (rendered rate (if is_money_rate left_ty then left_ty else right_ty))
         (rendered quantity TFloat)
     | Some `Divide ->
       (* The DECLARED rate type names the denominator, and the catalog turns that into the
          label a rate displays and quantizes per — per hour rather than per second, so a
          realistic hourly rate does not quantize to zero at a boundary. *)
       let alias = match expected with
         | Some (TRecord info) when is_money_rate (TRecord info) -> info.rec_tesl_name
         | _ -> unsupported loc
           "Go backend needs the rate's declared type here (`MoneyPerDuration` and friends)"
       in
       let label, (num, den) =
         match Units_catalog.dim_of_money_rate_alias alias with
         | Some dim ->
           (match Units_catalog.default_rate_label_of_dim dim with
            | Some pair -> pair
            | None -> unsupported loc "Go backend has no boundary unit for `%s`" alias)
         | None -> unsupported loc "Go backend does not know the rate type `%s`" alias
       in
       Printf.sprintf "teslrt.MoneyRateDivLabel(%s, %s, %d, %d, %s)"
         (rendered left left_ty) (rendered right TQuantity) num den (go_quote label)
     | None -> assert false)
  | EBinop { op; left; right; _ } ->
    let expr_binop_operand_source =
      match left, right with
      | EList { elems = []; _ }, _ -> right
      | _ -> left
    in
    (* The operand type is the one the TYPE rule settled on, which may come from the other
       side when this one is a defaulted empty list — so both operands are emitted against
       it rather than against whatever each infers alone. *)
    let ty = type_of_expr signatures env expr_binop_operand_source in
    let emitted_left = emit_expr ~expected:ty ~indent signatures env left in
    let emitted_right = emit_expr ~expected:ty ~indent signatures env right in
    let emit_bool_literal_comparison equal =
      match bool_literal_value left, bool_literal_value right with
      | Some expected, None ->
        if expected = equal then emitted_right
        else emit_negated ~indent signatures env right
      | None, Some expected ->
        if expected = equal then emitted_left
        else emit_negated ~indent signatures env left
      | _ ->
        if equal then equal_expr ty emitted_left emitted_right
        else unequal_expr ty emitted_left emitted_right
    in
    (match op with
     | BEq when ty = TBool -> emit_bool_literal_comparison true
     | BNeq when ty = TBool -> emit_bool_literal_comparison false
     | BAdd when ty = TFloat || ty = TQuantity ->
       Printf.sprintf "(%s + %s)" emitted_left emitted_right
     | BSub when ty = TFloat || ty = TQuantity ->
       Printf.sprintf "(%s - %s)" emitted_left emitted_right
     | BMul when ty = TFloat || ty = TQuantity ->
       Printf.sprintf "(%s * %s)" emitted_left emitted_right
     (* No zero guard: IEEE division by zero yields ±Inf, which is what Racket's `/` on
        a flonum does too. *)
     | BDiv when ty = TFloat || ty = TQuantity ->
       Printf.sprintf "(%s / %s)" emitted_left emitted_right
     | BAdd -> Printf.sprintf "teslrt.Add(%s, %s)" emitted_left emitted_right
     | BSub -> Printf.sprintf "teslrt.Sub(%s, %s)" emitted_left emitted_right
     | BMul -> Printf.sprintf "teslrt.Mul(%s, %s)" emitted_left emitted_right
     | BDiv -> Printf.sprintf "teslrt.MustQuo(%s, %s)" emitted_left emitted_right
     | BMod -> Printf.sprintf "teslrt.MustRem(%s, %s)" emitted_left emitted_right
     | BConcat ->
       (* Either side may be an untyped JSON value; what concatenates is the string it holds,
          and a value that is not a string traps there rather than rendering as `<nil>`. *)
       let text side emitted =
         if (try type_of_expr signatures env side = TJson with Unsupported _ -> false) then
           Printf.sprintf "teslrt.JsonAsString(%s)" emitted
         else emitted
       in
       Printf.sprintf "(%s + %s)" (text left emitted_left) (text right emitted_right)
     | BAnd -> Printf.sprintf "(%s && %s)" emitted_left emitted_right
     | BOr -> Printf.sprintf "(%s || %s)" emitted_left emitted_right
     | BEq | BNeq | BLt | BLe | BGt | BGe ->
       let compare left right = match op with
         | BEq -> equal_expr ty left right
         | BNeq -> unequal_expr ty left right
         | _ ->
           let symbol = match op with
             | BLt -> "<" | BLe -> "<=" | BGt -> ">" | _ -> ">=" in
           ordered_expr ty symbol left right
       in
       (* Two operands that EMIT THE SAME TEXT are a staticcheck finding (SA4000,
          "identical expressions on both sides"), and a lint finding on emitted code is an
          emitter bug by contract.  It is reachable from ordinary Tesl: comparing two calls
          of one effectful function — `generateId () != generateId ()` — is textually
          identical and semantically nothing of the kind.  Each side is bound first, which
          also fixes the evaluation ORDER at exactly what the source says. *)
       if emitted_left = emitted_right && String.contains emitted_left '(' then
         Printf.sprintf
           "(func() bool {\n%s\tteslLeft := %s\n%s\tteslRight := %s\n%s\treturn %s\n%s}())"
           indent emitted_left indent emitted_right indent
           (compare "teslLeft" "teslRight") indent
       else compare emitted_left emitted_right)
  (* Negating a LITERAL folds into the literal rather than emitting `-float64(0)`, which
     in Go is POSITIVE zero — the negation is applied to the already-typed value, so it
     cannot produce a negative zero (staticcheck SA4026 says exactly this).  Racket's
     `-0.0` is a real negative zero, and Tesl's Float equality distinguishes the two, so
     this was a wrong answer and not only a lint finding. *)
  | EUnop { op = UNeg; arg = ELit { lit = LFloat value; _ }; _ } ->
    emit_float_literal (-.value)
  | EUnop { op = UNeg; arg; _ }
    when (match type_of_expr signatures env arg with TFloat | TQuantity -> true | _ -> false) ->
    Printf.sprintf "(-%s)" (emit arg)
  | EUnop { op = UNeg; arg; _ } -> Printf.sprintf "teslrt.Neg(%s)" (emit arg)
  | EUnop { op = UNot; arg; _ } -> emit_negated ~indent signatures env arg
  | EIf _ as if_expr -> emit_if_expr ?expected ~indent signatures env if_expr
  | ELet _ as let_expr -> emit_let_expr ?expected ~indent signatures env let_expr
  | EField _ when (match normalize_call_head expr with
                   | EVar { name; _ } ->
                     (set_leaf name <> None || dict_leaf name <> None)
                     && Hashtbl.mem signatures name
                   | _ -> false) ->
    (match normalize_call_head expr with
     | EVar { name; loc } ->
       (match set_leaf name, dict_leaf name with
        | Some leaf, _ ->
          emit_set_leaf ~indent signatures env loc leaf []
            (match expected with Some want -> want | None -> TFailure) expected
        | _, Some leaf ->
          emit_dict_leaf ~indent signatures env loc leaf []
            (match expected with Some want -> want | None -> TFailure) expected
        | None, None -> assert false)
     | _ -> assert false)
  | EField { obj = EConstructor { name = module_name; args = []; _ }; field; _ }
    when Option.bind !current_types (fun types ->
           Hashtbl.find_opt types.consts (module_name ^ "." ^ field)) <> None ->
    (match Option.bind !current_types (fun types ->
             Hashtbl.find_opt types.consts (module_name ^ "." ^ field)) with
     | Some (_, go_name) -> go_name
     | None -> assert false)
  | EField { obj; field; _ } ->
    (match type_of_expr signatures env obj with
     | TNewtype _ ->
       ignore (type_of_expr signatures env expr);
       Printf.sprintf "%s.Value" (selector_operand (emit obj))
     | TRecord _ ->
       ignore (type_of_expr signatures env expr);
       Printf.sprintf "%s.%s" (selector_operand (emit obj)) (record_field_go_name field)
     (* A dynamic read on an api-test JSON value: a missing key is null, which is what makes
        `expect isNull resp.body.missing` writable. *)
     | TJson ->
       ignore (type_of_expr signatures env expr);
       Printf.sprintf "teslrt.JsonFieldOf(%s, %s)" (emit obj) (go_quote field)
     | _ -> unsupported (Checker.expr_loc expr) "Go backend cannot emit this field read")
  | ERecord { type_hint = Some name; fields; loc } ->
    (match record_info_of_signature signatures name with
     | Some info ->
       ignore (type_of_expr signatures env expr);
       emit_record_literal ~indent signatures env info fields
     | None -> unsupported loc "Go backend cannot emit record type `%s`" name)
  | ECase { scrut; arms; _ } ->
    let inferred = type_of_expr signatures env expr in
    let result = match inferred, expected with
      | TFailure, Some expected -> expected
      | _ -> inferred
    in
    let buffer = Buffer.create 256 in
    emit_case_statements ~indent:(indent ^ "\t") signatures env buffer scrut
      (List.map (fun (arm : case_arm) ->
         arm.pattern, arm.guard,
         (fun arm_env body_indent ->
            Printf.bprintf buffer "%sreturn %s\n" body_indent
              (emit_expr ~expected:result ~indent:body_indent signatures arm_env arm.body)))
         arms);
    Printf.sprintf "(func() %s {\n%s%s}())" (go_type result) (Buffer.contents buffer) indent
  | EList { elems; _ } ->
    (* The EXPECTATION settles the element type whenever there is one — not only for an
       empty list: `[Nothing, Nothing]` has no element that types on its own either. *)
    let element = match expected, elems with
      | Some (TList element), _ -> element
      | _ ->
        (match type_of_expr signatures env expr with
         | TList element -> element
         | _ -> invalid_arg "list literal validated before emission")
    in
    Printf.sprintf "[]%s{%s}" (go_type element)
      (String.concat ", " (List.map (fun elem ->
         emit_expr ~expected:element ~indent signatures env elem) elems))
  | ELetProof _ as let_proof -> emit_let_expr ?expected ~indent signatures env let_proof
  | ERecord { loc; _ } ->
    unsupported loc "Go backend cannot emit this expression yet"
  | EOk { value; keyword = false; _ } -> emit_expr ?expected ~indent signatures env value
  | EOk { value; _ } when (match expected with Some (TCheck _) | None -> false | Some _ -> true) ->
    (* Proof attachment at a call site: the proof has no runtime content. *)
    emit_expr ?expected ~indent signatures env value
  | EOk { value; _ } -> Printf.sprintf "teslrt.Accept(%s)" (emit value)
  | EFail { status; message; loc } ->
    (match expected with
     | Some (TCheck result) ->
       Printf.sprintf "teslrt.Reject[%s](%d, %s)" (go_type result) status
          (emit message)
     (* A `fail` in a position whose type is an ordinary VALUE — a handler's `fail 403
        "second factor required"`, a `fn`'s `fail 404 "task not found"`, a worker's `fail 500
        "…"` — has nowhere to put a failure in the Go signature, so it travels as the same
        `RequestRejection` a rejected check uses.

        What catches it is what makes the two backends agree:
        - inside a REQUEST, the router turns it back into a response carrying this status,
          which is `dsl/web.rkt`'s rule.  A cookie written before the failure is NOT sent:
          `writeResponse` attaches cookies to 2xx only, so a session cannot escape on a
          non-2xx answer;
        - inside a WORKER, `runJob` records it as a failed ATTEMPT, so retry and dead-lettering
          run — the Racket worker loop reads the same check-fail and calls `fail-job!`;
        - anywhere else it terminates the program, which is what Racket does too: a check-fail
          escaping a non-handler `fn` raises (`current-let-check-fail-behavior`), and a test
          asserting the failure recovers it either way. *)
     | _ ->
       ignore loc;
       Printf.sprintf "func() %s { panic(teslrt.RequestRejection{Status: %d, Message: %s}) }()"
         (match expected with Some ty -> go_type ty | None -> "struct{}{}")
         status (emit message))
  | EWithDatabase { database_name; body; loc } ->
    (* With a Memory-backed database the block adds nothing at run time: the store it names IS
       the entity's table variable.  With a Postgres-backed one it is what CONNECTS, and every
       query in the body — including those inside functions the body calls — routes to the
       server for as long as it is bound. *)
    (match postgres_database loc database_name with
     | None -> emit_expr ?expected ~indent signatures env body
     | Some info ->
       (* The body's value has to survive the closure the connection is held open around, so it
          is assigned out of it rather than returned through it: a `with database` in tail
          position answers what its body answers, exactly as the Memory form does. *)
       let ty = match expected with
         | Some ty -> ty
         | None -> type_of_expr signatures env body in
       let inner = indent ^ "\t" in
       Printf.sprintf
         "func() %s {\n%svar teslBound %s\n%steslrt.WithDatabase(%s, func() {\n%steslBound = %s\n%s})\n%sreturn teslBound\n%s}()"
         (go_type ty) inner (go_type ty) inner (qualified info.db_owner info.db_go_var)
         (inner ^ "\t") (emit_expr ~expected:ty ~indent:(inner ^ "\t") signatures env body)
         inner inner indent)
  | EEnqueue { job_type; payload; loc } ->
    let info = queue_of_job_type loc job_type in
    (* The row is the type ENQUEUED, which on a queue carrying several is not the queue's
       first one — reading it off the queue put every job in at the same type. *)
    let row = match Option.bind !current_types
                      (fun types -> Hashtbl.find_opt types.records job_type) with
      | Some row -> TRecord row
      | None -> unsupported loc "Go backend cannot resolve job type `%s`" job_type
    in
    Printf.sprintf "teslrt.EnqueueJob(%s, %s)"
      (qualified info.qu_owner info.qu_go_var)
      (emit_expr ~expected:row ~indent signatures env payload)
  (* `telemetry "name" { user.id = userId, count = n }`.  The attribute VALUES are a mixed bag of
     types while the runtime takes one attribute type, so each value is rendered to text here,
     where its type is known — the same rendering an interpolation performs.  A `secret` renders
     as its REDACTION, never its payload: an attribute walk is exactly where a misplaced secret
     would otherwise be exported in plaintext, and the Racket runtime redacts at every node of
     the same walk for that reason. *)
  | ETelemetry { name; fields; loc } ->
    let attribute (key, value) =
      let rendered = match type_of_expr signatures env value with
        | TString -> emit_expr ~expected:TString ~indent signatures env value
        | TInt -> Printf.sprintf "(%s).String()" (emit value)
        | TFloat -> Printf.sprintf "teslrt.FormatFloat(%s)" (emit value)
        | TBool -> Printf.sprintf "strconv.FormatBool(%s)" (emit value)
        | TNewtype info when info.secret ->
          ignore (emit value);
          "teslrt.SecretRedaction"
        | TNewtype info ->
          (match info.base with
           | TString -> Printf.sprintf "%s.Value" (selector_operand (emit value))
           | TInt -> Printf.sprintf "%s.Value.String()" (selector_operand (emit value))
           | TFloat ->
             Printf.sprintf "teslrt.FormatFloat(%s.Value)" (selector_operand (emit value))
           | TBool ->
             Printf.sprintf "strconv.FormatBool(%s.Value)" (selector_operand (emit value))
           | _ -> unsupported loc
             "Go backend telemetry attribute `%s` has an unsupported type" key)
        | _ -> unsupported loc
          "Go backend telemetry attribute `%s` must be a String, Int, Float or Bool" key
      in
      Printf.sprintf "{Tuple2First: %s, Tuple2Second: %s}" (go_quote key) rendered
    in
    Printf.sprintf "teslrt.Telemetry(%s, []teslrt.Tuple2[string, string]{%s})"
      (go_quote name) (String.concat ", " (List.map attribute fields))
  (* A capability scope adds nothing at run time: the checker has already verified every call in
     it, so what is left is the body. *)
  | EWithCapabilities { body; _ } -> emit_expr ?expected ~indent signatures env body
  (* `startWorkers` activates a queue: N goroutines, each claiming and running one job at a time
     through the SAME dispatcher an api-test's `processNextJob` builds — so "run one job" and "run
     them forever" cannot disagree about how a job is dispatched. *)
  | EStartWorkers { workers_name; concurrency; is_dead; loc; _ } ->
    let queue_name =
      (* The lowering names them `<Queue>Workers` / `<Queue>DeadWorkers`. *)
      let suffix = if is_dead then "DeadWorkers" else "Workers" in
      if Filename.check_suffix workers_name suffix then
        Filename.chop_suffix workers_name suffix
      else workers_name
    in
    let info = queue_of_job_type loc queue_name in
    let queue = qualified info.qu_owner info.qu_go_var in
    (* One dispatcher over every job type the queue carries: the store holds a payload as
       `any` precisely so one queue can carry several, and the type switch is where the
       emitter's static knowledge of them is spent. *)
    let wirings = List.filter_map (fun (job_type, worker, dead_worker) ->
      match is_dead, dead_worker with
      | false, _ -> Some (job_type, worker)
      | true, Some dead_worker -> Some (job_type, dead_worker)
      | true, None -> None) info.qu_jobs in
    if wirings = [] then unsupported loc
      "Go backend: queue `%s` has no dead-letter worker" info.qu_tesl_name;
    let cases = List.map (fun (job_type, worker) ->
      let row_go = match Option.bind !current_types
                           (fun types -> Hashtbl.find_opt types.records job_type) with
        | Some row -> go_type (TRecord row)
        | None -> unsupported loc "Go backend cannot resolve job type `%s`" job_type
      in
      let worker_go = match Hashtbl.find_opt signatures worker with
        | Some signature -> qualified signature.sig_owner signature.go_name
        | None -> unsupported loc "Go backend cannot resolve worker `%s`" worker
      in
      Printf.sprintf "%s\tcase %s:\n%s\t\t_ = %s(teslJob)\n" indent row_go indent worker_go)
      wirings in
    (* The literal's BODY sits one level in from the call, and its closing brace lines up with
       the call — the same shape gofmt writes, which is what the emitter has to produce. *)
    Printf.sprintf
      "teslrt.StartWorkers(%s, func(teslPayload any) teslrt.JobOutcome {\n%s\tswitch teslJob := teslPayload.(type) {\n%s%s\tdefault:\n%s\t\tpanic(\"%s: unexpected job payload\")\n%s\t}\n%s\treturn teslrt.JobOutcome{OK: true}\n%s}, %d, %b)"
      queue indent (String.concat "" cases) indent indent info.qu_tesl_name indent indent indent
      (match concurrency with Some n when n > 0 -> n | _ -> 1) is_dead
  (* `serve` is the tail of the startup chain: it runs until the process is asked to stop. *)
  | EServe { server_name; port; static_dir; mount_path; _ } ->
    let options =
      String.concat ", "
        ([ Printf.sprintf "Port: teslrt.PortOf(%s)"
             (emit_expr ~expected:TInt ~indent signatures env port) ]
         @ (match static_dir with
            | Some dir -> [ Printf.sprintf "StaticDir: %s" (go_quote dir) ] | None -> [])
         @ (match mount_path with
            | Some mount -> [ Printf.sprintf "MountPath: %s" (go_quote mount) ] | None -> []))
    in
    Printf.sprintf "teslrt.Serve(%s, teslrt.ServeOptions{%s})"
      (go_ident ~exported:true server_name) options
  (* The cache operations: one runtime call each, on the store the declaration emitted.  The
     cache NAME is not a value — it resolves to that store. *)
  | ECacheGet { cache_name; key; loc } ->
    let info = cache_of_name loc cache_name in
    Printf.sprintf "teslrt.CacheGet(%s, %s)"
      (qualified info.ca_owner info.ca_go_var) (emit key)
  | ECacheSet { cache_name; key; value; ttl; loc } ->
    let info = cache_of_name loc cache_name in
    let store = qualified info.ca_owner info.ca_go_var in
    let value = emit_expr ~expected:info.ca_value ~indent signatures env value in
    (match ttl with
     | None -> Printf.sprintf "teslrt.CacheSet(%s, %s, %s)" store (emit key) value
     | Some ttl ->
       Printf.sprintf "teslrt.CacheSetTTL(%s, %s, %s, %s)" store (emit key) value (emit ttl))
  | ECacheDelete { cache_name; key; loc } ->
    let info = cache_of_name loc cache_name in
    Printf.sprintf "teslrt.CacheDelete(%s, %s)"
      (qualified info.ca_owner info.ca_go_var) (emit key)
  | ECacheInvalidate { cache_name; prefix; loc } ->
    let info = cache_of_name loc cache_name in
    Printf.sprintf "teslrt.CacheInvalidatePrefix(%s, %s)"
      (qualified info.ca_owner info.ca_go_var) (emit prefix)
  (* The email operations, on the outbox the declaration emitted.  The email NAME is not a
     value — it resolves to that store, exactly as a cache's does. *)
  | ESendEmail { email_name; to_; subject; body; loc } ->
    let info = email_of_name loc email_name in
    Printf.sprintf "teslrt.SendEmail(%s, %s, %s, %s)"
      (qualified info.em_owner info.em_go_var) (emit to_) (emit subject) (emit body)
  | EStartEmailWorker { email_name; loc } ->
    let info = email_of_name loc email_name in
    Printf.sprintf "teslrt.StartEmailWorker(%s)" (qualified info.em_owner info.em_go_var)
  | EWithTransaction { body; _ } ->
    if not (module_has_postgres_database ()) then
      emit_expr ?expected ~indent signatures env body
    else begin
      let ty = match expected with
        | Some ty -> ty
        | None -> type_of_expr signatures env body in
      let inner = indent ^ "\t" in
      Printf.sprintf
        "func() %s {\n%svar teslCommitted %s\n%steslrt.WithTransaction(func() {\n%steslCommitted = %s\n%s})\n%sreturn teslCommitted\n%s}()"
        (go_type ty) inner (go_type ty) inner
        (inner ^ "\t") (emit_expr ~expected:ty ~indent:(inner ^ "\t") signatures env body)
        inner inner indent
    end
  | EPublish { channel_name; key; event_ctor; payload; loc } ->
    let info = channel_of_name loc channel_name in
    ignore (type_of_expr signatures env expr);
    let key = match key with
      | Some key_expr -> emit_expr ~expected:TString ~indent signatures env key_expr
      (* A channel with no key parameter keys every listener on the same empty string, which
         is what the Racket publish does when the declaration has no key. *)
      | None -> "\"\""
    in
    let payload = match payload with
      | Some payload_expr ->
        emit_expr ~expected:info.ch_payload ~indent signatures env
          (publish_payload_expr signatures loc event_ctor payload_expr)
      | None -> unsupported loc "Go backend requires a payload for `publish %s`" channel_name
    in
    (* The event crosses the wire as JSON, encoded by the payload type's own codec — the same
       encoder a response body goes through, so a subscriber and a caller read the same shape. *)
    Printf.sprintf "teslrt.Publish(%s, %s, %s(%s))"
      (qualified info.ch_owner info.ch_go_var) key
      (!value_encoder_hook info.ch_payload) payload
  (* A LAMBDA is a Go function literal.  The body goes through the ordinary TAIL emitter, so
     a `let` chain or an `if` inside it keeps statement form instead of nesting closures. *)
  | ELambda { params; body; loc } ->
    let param_types = match type_of_expr signatures env expr with
      | TFunc (param_types, _) -> param_types
      | _ -> unsupported loc "Go backend cannot resolve this lambda's type"
    in
    let result = match type_of_expr signatures env expr with
      | TFunc (_, result) -> result
      | _ -> assert false
    in
    let lambda_env =
      List.map2 (fun (binding : binding) ty -> binding.name, ty) params param_types @ env in
    (* The body is emitted as an EXPRESSION, so a `let` chain inside it becomes the same
       immediately-called closure any other nested `let` does — one shape for both. *)
    let emitted_body =
      emit_expr ~expected:result ~indent:(indent ^ "\t") signatures lambda_env body in
    Printf.sprintf "func(%s) %s {\n%s\treturn %s\n%s}"
      (String.concat ", " (List.map2 (fun (binding : binding) ty ->
         Printf.sprintf "%s %s" (local_ident binding.name) (go_type ty)) params param_types))
      (go_type result) indent emitted_body indent

(* What one arm has to test and bind, resolved once so the type rule and the
   emitter cannot disagree about which payload field a binder refers to. *)
(* A literal SUB-pattern (`RGB { r = 255, … }`): the comparison the arm has to make.  It
   goes through the same `equal_expr` a value comparison does, so an Int compares as an
   arbitrary-precision Int rather than as a Go int. *)
(* A named function reference, as a Go value.  The reference is the function's own Go name,
   qualified when it came from another package — the same resolution a CALL to it goes
   through, which is what keeps the two from drifting. *)
and agent_function_go signatures loc what expr =
  let signature = agent_function_ref signatures loc what expr in
  qualified signature.sig_owner signature.go_name

(* A publisher is a lambda or a named function; a lambda goes through the ordinary lambda
   emitter, which already produces the `func(string) struct{}` the runtime takes. *)
and agent_publisher_go ~indent signatures env loc what publisher =
  match publisher with
  | ELambda _ -> emit_expr ~indent signatures env publisher
  | _ -> agent_function_go signatures loc what publisher

(* `asTool fn` — the tool a plain typed function becomes.
   The two closures are HOISTED into named package-level functions rather than written
   inline, for the reason the comparators are: go/printer decides whether a function literal
   fits on one line by a threshold the emitter cannot predict, so an inline pair reformats
   under gofmt at some sizes and not others — and a gofmt diff on emitted code is an emitter
   bug.  Named functions are stable at every size, and read better in a tree someone owns
   after ejecting. *)
and emit_astool ~indent signatures (declaration : func_decl) =
  ignore indent;
  let types = match !current_types with
    | Some types -> types
    | None -> unsupported declaration.loc "Go backend cannot resolve `asTool` here"
  in
  let signature = match Hashtbl.find_opt signatures declaration.name with
    | Some signature -> signature
    | None -> unsupported declaration.loc
      "Go backend cannot resolve function `%s`" declaration.name
  in
  if signature.sig_needs_scope then
    unsupported declaration.loc
      "Go backend cannot wrap `%s` as a tool: it takes the request scope" declaration.name;
  let readers = List.map (fun (binding : binding) ->
    Printf.sprintf "%s(teslFields, %s)"
      (agent_tool_arg_reader declaration.loc binding) (go_quote binding.name))
    declaration.params in
  let decode = remember_helper_stmts ~prefix:"teslToolArgs"
    ~signature:"(teslArgs string) []any"
    ~body:(Printf.sprintf "\tteslFields := teslrt.ToolArguments(teslArgs)\n\treturn []any{%s}\n"
             (String.concat ", " readers)) in
  (* The dispatch asserts each argument back to the type the function DECLARED, so the
     erased `any` never reaches user code. *)
  let arguments = List.mapi (fun index (binding : binding) ->
    Printf.sprintf "teslArgs[%d].(%s)" index
      (go_type (type_of_type_expr types binding.type_expr))) declaration.params in
  let parameter = if declaration.params = [] then "_ []any" else "teslArgs []any" in
  let call = remember_helper ~prefix:"teslToolCall"
    ~signature:(Printf.sprintf "(%s) string" parameter)
    ~body:(Printf.sprintf "%s(%s)"
             (qualified signature.sig_owner signature.go_name)
             (String.concat ", " arguments)) in
  let description = match declaration.doc with
    | Some text when String.trim text <> "" -> String.trim text
    | _ -> declaration.name
  in
  Printf.sprintf "teslrt.ToolOf(%s, %s, %s, %s, %s)"
    (go_quote declaration.name) (go_quote description)
    (go_quote (agent_tool_schema declaration.loc declaration.params)) decode call

(* One endpoint, as a tool.  The tool IS the endpoint: the same handler, called with the
   same authenticated user, so every check in the handler body runs unchanged.  What is
   generated here is the pair the runtime needs — the argument decode and the call — each a
   named function for the gofmt reason every other hoisted helper is one. *)
and emit_endpoint_tool signatures loc name description schema (endpoint : api_endpoint)
    user_type emitted_user =
  let types = match !current_types with
    | Some types -> types
    | None -> unsupported loc "Go backend cannot resolve `serverTools` here"
  in
  let signature = match Hashtbl.find_opt signatures name with
    | Some signature -> signature
    | None -> unsupported loc "Go backend cannot resolve handler `%s`" name
  in
  if signature.sig_needs_scope then
    unsupported loc
      "Go backend cannot offer `%s` as a tool: it writes a cookie, and a tool call has no \
       HTTP response to attach one to" name;
  let has_auth = endpoint.auth <> None in
  (* The handler's own parameter list is what the arguments must satisfy, so the types come
     from it rather than being re-derived from the endpoint. *)
  let argument_types = match signature.params, has_auth with
    | _ :: rest, true -> rest
    | params, false -> params
    | [], true -> unsupported loc
      "Go backend handler `%s` takes no authenticated user" name
  in
  let readers =
    List.map (fun (capture : api_capture) ->
      let parser, checker = match capture.via_fn with
        | "" -> (match capture.inline_codec with Some codec -> codec | None -> "stringCodec"),
                capture.inline_check
        | via ->
          (match List.find_opt (fun (form : capture_form) -> form.name = via) !current_capturers with
           | Some form -> form.parser, form.checker
           | None -> unsupported endpoint.loc
             "Go backend cannot resolve capturer `%s`" via)
      in
      if parser <> "stringCodec" then unsupported endpoint.loc
        "Go backend supports `stringCodec` path captures only for now (`%s`)" parser;
      let raw = Printf.sprintf "teslrt.ToolArgString(teslFields, %s)" (go_quote capture.binding.name) in
      match checker with
      | None -> raw
      | Some check_fn ->
        let check = match Hashtbl.find_opt signatures check_fn with
          | Some check -> check
          | None -> unsupported endpoint.loc
            "Go backend cannot resolve capture check `%s`" check_fn
        in
        let reference = qualified check.sig_owner check.go_name in
        (* A capturer's `via` is either a CHECK, which may reject the segment, or a plain
           function that normalises it — the same two shapes the HTTP path allows. *)
        (match check.result with
         | TCheck _ ->
           Printf.sprintf "teslrt.ToolChecked(%s, %s(%s))"
             (go_quote capture.binding.name) reference raw
         | _ -> Printf.sprintf "%s(%s)" reference raw))
      endpoint.captures
    @ (match ep_body endpoint with
       | None -> []
       | Some (binding : binding) ->
         let key = go_quote binding.name in
         (match type_of_type_expr types binding.type_expr with
          (* A SCALAR body is the whole value, as it is over HTTP. *)
          | TString -> [ Printf.sprintf "teslrt.ToolArgString(teslFields, %s)" key ]
          | TInt -> [ Printf.sprintf "teslrt.ToolArgInt(teslFields, %s)" key ]
          | TBool -> [ Printf.sprintf "teslrt.ToolArgBool(teslFields, %s)" key ]
          | TFloat -> [ Printf.sprintf "teslrt.ToolArgFloat(teslFields, %s)" key ]
          (* Anything else decodes through the type's own codec — the very decode the HTTP
             boundary runs, so a tool argument cannot be validated more weakly. *)
          | TRecord info ->
            [ Printf.sprintf "teslrt.ToolArgDecoded(teslFields, %s, %s)" key
                (codec_decode_ref info.rec_tesl_name) ]
          | TAdt (info, _) ->
            [ Printf.sprintf "teslrt.ToolArgDecoded(teslFields, %s, %s)" key
                (codec_decode_ref info.adt_tesl_name) ]
          | _ -> unsupported endpoint.loc
            "Go backend cannot decode `%s` as a tool argument; give the type a `codec`"
            binding.name))
  in
  if List.length readers <> List.length argument_types then
    unsupported loc
      "Go backend endpoint `%s` declares %d argument(s) but its handler takes %d"
      name (List.length readers) (List.length argument_types);
  let decode = remember_helper_stmts ~prefix:"teslEndpointArgs"
    ~signature:"(teslArgs string) []any"
    (* An endpoint that takes nothing still validates the payload — the model has to send an
       object — but it binds no fields, and a bound-and-unused `teslFields` does not
       compile. *)
    ~body:(if readers = [] then
             "\t_ = teslrt.ToolArguments(teslArgs)\n\treturn []any{}\n"
           else
             Printf.sprintf "\tteslFields := teslrt.ToolArguments(teslArgs)\n\treturn []any{%s}\n"
               (String.concat ", " readers)) in
  let arguments = List.mapi (fun index ty ->
    Printf.sprintf "teslArgs[%d].(%s)" index (go_type ty)) argument_types in
  let call_arguments = if has_auth then "teslUser" :: arguments else arguments in
  let encoder = match signature.result with
    | TDict _ | TSet _ | TParam _ | TCheck _ | TFailure ->
      unsupported loc "Go backend cannot encode endpoint `%s`\'s response as a tool result" name
    | result -> !value_encoder_hook result
  in
  (* A tool_result is TEXT, and the endpoint's response is JSON — the same bytes an HTTP
     caller would receive, through the same encoder. *)
  let dispatch = remember_helper_stmts ~prefix:"teslEndpointCall"
    ~signature:(Printf.sprintf "(%s %s, teslArgs []any) string"
                  (if has_auth then "teslUser" else "_") (go_type user_type))
    ~body:(Printf.sprintf
             "\tdefer teslrt.ToolRejection()\n\treturn teslrt.EncodeJSONValue(%s(%s(%s)))\n"
             encoder (qualified signature.sig_owner signature.go_name)
             (String.concat ", " call_arguments)) in
  Printf.sprintf "teslrt.ToolOf(%s, %s, %s, %s, teslrt.ToolDispatchWith(%s, %s))"
    (go_quote name) (go_quote description) (go_quote schema) decode dispatch emitted_user

and literal_pattern_test access field_ty value =
  let literal = match field_ty, value with
    | TInt, LInt n -> Printf.sprintf "teslrt.FromInt64(%d)" n
    | TInt, LBigInt text -> Printf.sprintf "teslrt.MustParseDecimal(%s)" (go_quote text)
    | TString, LString text -> go_quote text
    | TBool, LBool b -> if b then "true" else "false"
    | _ -> invalid_arg "literal sub-pattern validated before emission"
  in
  strip_outer_parens (equal_expr field_ty access literal)

and pattern_plan ~scrut info type_args pattern =
  (* Answers what the arm TESTS beyond its own tag, what it BINDS (each binder paired with
     the Go expression that reads it), and the whole-value binder if the pattern is one.
     A nested pattern (`Neg (Lit n)`) contributes both: a test on the inner tag, and a
     binder that reads two levels down. *)
  let field_access base (owner : adt_info) variant field_name field_ty =
    ignore field_ty;
    let read = Printf.sprintf "%s.%s" base (variant_field_go_name variant field_name) in
    (* A self-referential payload is behind a pointer, so reading it — to test it or to
       bind it — goes through `teslrt.Unboxed`, exactly as a top-level binding does. *)
    if adt_self_payload owner variant field_name then Printf.sprintf "teslrt.Unboxed(%s)" read
    else read
  in
  let rec sub_plan access field_ty sub =
    match sub with
    | PWild -> [], []
    | PVar name -> [name, access, field_ty], []
    | PNullary { ctor; _ } ->
      (match field_ty with
       | TAdt (sub_info, _) ->
         (match find_variant sub_info ctor with
          | Some sub_variant ->
            [], [Printf.sprintf "%s.%s == %s" access adt_tag_field
                   (qualified sub_info.adt_owner sub_variant.var_tag)]
          | None -> invalid_arg "case pattern validated before emission")
       | _ -> invalid_arg "case pattern validated before emission")
    | PCon { ctor; fields = sub_fields; _ } ->
      (match field_ty with
       | TAdt (sub_info, sub_args) ->
         (match find_variant sub_info ctor with
          | Some sub_variant ->
            let tag_test = Printf.sprintf "%s.%s == %s" access adt_tag_field
              (qualified sub_info.adt_owner sub_variant.var_tag) in
            let deeper = List.mapi (fun index (_, deeper) ->
              let deeper_name, deeper_ty =
                List.nth (variant_field_types sub_info sub_args sub_variant) index in
              sub_plan (field_access access sub_info sub_variant deeper_name deeper_ty)
                deeper_ty deeper) sub_fields in
            List.concat_map fst deeper, tag_test :: List.concat_map snd deeper
          | None -> invalid_arg "case pattern validated before emission")
       | _ -> invalid_arg "case pattern validated before emission")
    | PLit { value; _ } -> [], [literal_pattern_test access field_ty value]
  in
  match pattern with
  | PWild -> None, None, [], []
  | PVar name -> None, Some name, [], []
  | PNullary { ctor; _ } -> find_variant info ctor, None, [], []
  | PCon { ctor; fields; _ } ->
    let variant = match find_variant info ctor with
      | Some variant -> variant
      | None -> invalid_arg "case pattern validated before emission"
    in
    let planned = List.mapi (fun index (_key, sub) ->
      let field_name, field_ty =
        List.nth (variant_field_types info type_args variant) index in
      sub_plan (field_access scrut info variant field_name field_ty) field_ty sub) fields in
    Some variant, None, List.concat_map fst planned, List.concat_map snd planned
  | PLit _ -> invalid_arg "case pattern validated before emission"

(* `case` lowers to statements, not an expression: a tag switch when no arm has a
   guard (so the emitted switch stays checkable), an ordered if-chain when a guard
   can make an arm fall through to the next one. *)
(* Arms arrive as (pattern, guard, body) TRIPLES rather than as `case_arm`s: an expression
   `case` carries an expr body while a test-block `case` carries a statement list, and the
   discrimination logic is the same for both. *)
(* [terminating] says whether every arm's body ENDS the function — it does in expression
   position, where each arm is a `return`, and it does not in a test block, where the arms
   are plain statements.  It changes what "no arm matched" has to look like: a `panic` after
   arms that all return is unreachable AND is what makes the emitted function terminating to
   Go's own analysis, while after arms that fall through it has to be conditional or it runs
   every time. *)
and emit_case_statements ?(indent="") ?(terminating=true) signatures env buffer scrut arms =
  match type_of_expr signatures env scrut with
  | scalar_ty when scalar_case_type scalar_ty ->
    emit_scalar_case_statements ~indent signatures env buffer scrut arms scalar_ty
  | _ -> emit_adt_case_statements ~indent ~terminating signatures env buffer scrut arms

(* A `case` over a SCALAR: the arms are literal patterns and at most one catch-all, so the
   emitted shape is an `if`/`else if` chain over the scrutinee rather than a tag switch — a Go
   `switch` on the value would not work for `teslrt.Int`, which is deliberately not comparable
   with `==`.  The scrutinee is bound once, so a non-trivial one is evaluated once.
   Exhaustiveness is the checker's (Racket requires it too), and the final `panic` says so
   rather than answering a zero value if a future change ever let a non-exhaustive case
   through. *)
and emit_scalar_case_statements ?(indent="") signatures env buffer scrut arms scrut_ty =
  let scrut_name = Printf.sprintf "teslScrut%d" (String.length indent) in
  let inner = indent ^ "\t" in
  Printf.bprintf buffer "%s{\n" indent;
  Printf.bprintf buffer "%s%s := %s\n" inner scrut_name
    (emit_expr ~expected:scrut_ty ~indent:inner signatures env scrut);
  let arm_pattern (pattern, _, _) = pattern in
  let arm_guard (_, guard, _) = guard in
  let arm_body (_, _, body) = body in
  (* A pattern's own condition, and the environment its bindings add. *)
  let condition_of arm =
    match arm_pattern arm with
    | PWild -> None, env
    | PVar name -> None, (name, scrut_ty) :: env
    | PLit { value; loc } ->
      (* A literal pattern compares against the scrutinee's PAYLOAD when that is a newtype: the
         pattern is written as the base value (`case code of 404 -> …`), so wrapping it would be
         the wrong shape and reading `.Value` off a bare literal does not compile. *)
      let compared_ty, compared_scrut = match scrut_ty with
        | TNewtype info -> info.base, Printf.sprintf "%s.Value" scrut_name
        | ty -> ty, scrut_name
      in
      let literal =
        emit_expr ~expected:compared_ty ~indent:inner signatures env (ELit { lit = value; loc }) in
      Some (strip_outer_parens (equal_expr compared_ty compared_scrut literal)), env
    | PNullary { ctor = ("True" | "False") as ctor; _ } ->
      (* A Bool literal: the scrutinee itself, or its negation. *)
      Some (if ctor = "True" then scrut_name else "!" ^ scrut_name), env
    | PNullary { ctor; loc } | PCon { ctor; loc; _ } ->
      unsupported loc "Go backend `case` over a scalar cannot match constructor `%s`" ctor
  in
  (* An arm that BINDS the scrutinee declares its name as the first statement of its own
     body: with the `if init; cond` form below the declaration is in the `if` header, and Go
     rejects a declared-and-unused variable, so the discard has to be inside. *)
  let discard_variable body_indent arm arm_env =
    match arm_pattern arm with
    | PVar name ->
      Printf.bprintf buffer "%s_ = %s\n" body_indent (local_ident name);
      arm_env
    | _ -> arm_env
  in
  (* The arms are ONE if/else-if chain, not a run of independent `if`s.  In expression
     position every arm ends in a `return`, so a missing `else` was invisible; as STATEMENTS
     — a `case` in a test block — it meant the arms after a matching one ran as well, and a
     `case label of "hello" -> … _ -> …` executed BOTH.  A chain also says what the code
     means: at most one arm runs. *)
  let rec chain ~first = function
    | [] ->
      if first then
        Printf.bprintf buffer
          "%spanic(\"unreachable: checker guarantees case exhaustiveness\")\n" inner
      else
        Printf.bprintf buffer " else {\n%s\tpanic(\"unreachable: checker guarantees case \
                               exhaustiveness\")\n%s}\n" inner inner
    | arm :: rest ->
      let condition, arm_env = condition_of arm in
      let guard = arm_guard arm in
      (* A guard on a VARIABLE pattern reads the name the arm binds, so the binding is
         declared in the `if`'s own init statement — where it is in scope for the condition
         and for the body, and for nothing else. *)
      let initialiser = match arm_pattern arm, guard with
        | PVar name, Some _ ->
          Printf.sprintf "%s := %s; " (local_ident name) scrut_name
        | _ -> ""
      in
      let full_condition = match condition, guard with
        | None, None -> None
        | Some condition, None -> Some condition
        | None, Some guard ->
          Some (strip_outer_parens (emit_expr ~indent:inner signatures arm_env guard))
        | Some condition, Some guard ->
          Some (Printf.sprintf "%s && %s" condition
                  (strip_outer_parens (emit_expr ~indent:inner signatures arm_env guard)))
      in
      (match full_condition with
       | None ->
         (* An unconditional arm CLOSES the chain: everything after it is unreachable, which
            the checker's exhaustiveness rule already says. *)
         let body_indent = inner ^ "\t" in
         if first then Printf.bprintf buffer "%s{\n" inner
         else Printf.bprintf buffer " else {\n";
         (match arm_pattern arm with
          | PVar name ->
            Printf.bprintf buffer "%s%s := %s\n%s_ = %s\n" body_indent (local_ident name)
              scrut_name body_indent (local_ident name)
          | _ -> ());
         (arm_body arm) arm_env body_indent;
         Printf.bprintf buffer "%s}\n" inner
       | Some condition ->
         if first then Printf.bprintf buffer "%sif %s%s {\n" inner initialiser condition
         else Printf.bprintf buffer " else if %s%s {\n" initialiser condition;
         let body_indent = inner ^ "\t" in
         let arm_env = discard_variable body_indent arm arm_env in
         (arm_body arm) arm_env body_indent;
         Printf.bprintf buffer "%s}" inner;
         chain ~first:false rest)
  in
  chain ~first:true arms;
  Printf.bprintf buffer "%s}\n" indent

and emit_adt_case_statements ?(indent="") ?(terminating=true) signatures env buffer scrut arms =
  let info, type_args = match type_of_expr signatures env scrut with
    | TAdt (info, args) -> info, args
    | _ -> invalid_arg "case scrutinee validated before emission"
  in
  let scrut_ty = TAdt (info, type_args) in
  let scrut_name = Printf.sprintf "teslScrut%d" (String.length indent) in
  let inner = indent ^ "\t" in
  Printf.bprintf buffer "%s{\n" indent;
  Printf.bprintf buffer "%s%s := %s\n" inner scrut_name
    (emit_expr ~expected:scrut_ty ~indent:inner signatures env scrut);
  let plans =
    List.map (fun ((pattern, guard, body) as arm) ->
      ignore guard; ignore body;
      arm, pattern_plan ~scrut:scrut_name info type_args pattern) arms in
  (* A NESTED pattern tests more than its own tag, so the arm cannot be a `switch` case:
     the chain form is the one that can carry an extra condition, and it is the same shape
     a guard already takes. *)
  let nested = List.exists (fun (_, (_, _, _, conditions)) -> conditions <> []) plans in
  let guarded = nested || List.exists (fun (_, guard, _) -> guard <> None) arms in
  (* A single-variant ADT (a tuple) has nothing to discriminate: the first arm always
     matches, so binding its payload IS the match.  A switch would need a tag the type
     does not carry. *)
  let single = single_variant info <> None && not guarded in
  let bind_arm body_indent (whole, bindings) =
    let env = ref env in
    (match whole with
     | None -> ()
     | Some name ->
       Printf.bprintf buffer "%s%s := %s\n%s_ = %s\n" body_indent (local_ident name)
         scrut_name body_indent (local_ident name);
       env := (name, scrut_ty) :: !env);
    (* The plan already carries the expression each binder reads — a field of the
       scrutinee, or a path through a nested pattern, unboxed wherever the payload is a
       pointer. *)
    List.iter (fun (name, read, field_ty) ->
      Printf.bprintf buffer "%s%s := %s\n%s_ = %s\n" body_indent (local_ident name)
        read body_indent (local_ident name);
      env := (name, field_ty) :: !env) bindings;
    !env
  in
  let unreachable_default body_indent =
    Printf.bprintf buffer "%spanic(\"unreachable: checker guarantees case exhaustiveness\")\n"
      body_indent
  in
  if single then begin
    match plans with
    | (arm, (_, whole, bindings, _)) :: _ ->
      let arm_env = bind_arm inner (whole, bindings) in
      (arm_body arm) arm_env inner
    | [] -> invalid_arg "case validated before emission"
  end else if guarded then begin
    (* First match wins, so an unguarded catch-all ends the chain: anything after
       it is dead code, which `go vet` rejects.

       An arm's GUARD is tested inside its tag block, because it reads the bindings the
       pattern introduces and those can only be read once the tag says the payload is
       there — so the arms cannot be one `if`/`else if`.  A FLAG carries "an arm already
       ran" instead: without it every later arm ran as well, which in expression position
       was invisible (each arm returns) and in STATEMENT position meant a `case` in a test
       block executed more than one of its arms. *)
    let matched = Printf.sprintf "teslMatched%d" (String.length indent) in
    (* Only where the arms FALL THROUGH.  Where they return, an arm that ran has already
       left the function and the flag would be dead weight — and the conditional panic it
       would force is not a terminating statement, which Go reads as a missing return. *)
    let needs_flag = (not terminating) && List.length plans > 1 in
    if needs_flag then Printf.bprintf buffer "%s%s := false\n" inner matched;
    let rec chain first = function
      | [] ->
        if needs_flag then begin
          Printf.bprintf buffer "%sif !%s {\n" inner matched;
          unreachable_default (inner ^ "\t");
          Printf.bprintf buffer "%s}\n" inner
        end else unreachable_default inner
      | (arm, (variant, whole, bindings, conditions)) :: rest ->
        let body_indent = inner ^ "\t" in
        (* The arm's own tag and its nested tests are ONE condition: a nested test reads
           through the payload, so it may only be evaluated once the tag says the payload
           is there — `&&` short-circuits left to right, which is exactly that order. *)
        let tests =
          (if needs_flag && not first then [Printf.sprintf "!%s" matched] else [])
          @ (match variant with
             | Some variant ->
               [Printf.sprintf "%s.%s == %s" scrut_name adt_tag_field
                  (qualified info.adt_owner variant.var_tag)]
             | None -> []) @ conditions in
        (match tests with
         | [] -> Printf.bprintf buffer "%s{\n" inner
         | _ -> Printf.bprintf buffer "%sif %s {\n" inner (String.concat " && " tests));
        let arm_env = bind_arm body_indent (whole, bindings) in
        let ran indent = if needs_flag then Printf.bprintf buffer "%s%s = true\n" indent matched in
        (match arm_guard arm with
         | None ->
           ran body_indent;
           (arm_body arm) arm_env body_indent
         | Some guard ->
           Printf.bprintf buffer "%sif %s {\n" body_indent
             (strip_outer_parens (emit_expr ~indent:body_indent signatures arm_env guard));
           ran (body_indent ^ "\t");
           (arm_body arm) arm_env (body_indent ^ "\t");
           Printf.bprintf buffer "%s}\n" body_indent);
        Printf.bprintf buffer "%s}\n" inner;
        if tests = [] && arm_guard arm = None then () else chain false rest
    in
    chain true plans
  end else begin
    (* Every tag is named explicitly — a Tesl catch-all becomes the list of tags no
       earlier arm covered — so the `exhaustive` linter can still verify the switch
       (`default:` alone would blind it under default-signifies-exhaustive: false). *)
    let all_tags =
      List.map (fun variant -> qualified info.adt_owner variant.var_tag) info.adt_variants in
    Printf.bprintf buffer "%sswitch %s.%s {\n" inner scrut_name adt_tag_field;
    let containment_default () =
      Printf.bprintf buffer "%sdefault:\n" inner;
      unreachable_default (inner ^ "\t")
    in
    let rec cases seen = function
      | [] -> containment_default ()
      | (arm, (variant, whole, bindings, _)) :: rest ->
        (match variant with
         | Some variant ->
           let tag = qualified info.adt_owner variant.var_tag in
           if List.mem tag seen then cases seen rest
           else begin
             Printf.bprintf buffer "%scase %s:\n" inner tag;
             let arm_env = bind_arm (inner ^ "\t") (whole, bindings) in
             (arm_body arm) arm_env (inner ^ "\t");
             cases (tag :: seen) rest
           end
         | None ->
           let uncovered = List.filter (fun tag -> not (List.mem tag seen)) all_tags in
           if uncovered = [] then containment_default ()
           else begin
             Printf.bprintf buffer "%scase %s:\n" inner (String.concat ", " uncovered);
             let arm_env = bind_arm (inner ^ "\t") (whole, bindings) in
             (arm_body arm) arm_env (inner ^ "\t");
             containment_default ()
           end)
    in
    cases [] plans;
    Printf.bprintf buffer "%s}\n" inner
  end;
  Printf.bprintf buffer "%s}\n" indent

(* Negation is pushed into the expression instead of wrapping the emitted string:
   `!(a && b)` and `!(a == b)` are golangci-lint findings on generated code, and a
   lint finding on emitted code is an emitter bug by contract. *)
and emit_negated ?(indent="") signatures env expr =
  let neg = emit_negated ~indent signatures env in
  let emit = emit_expr ~indent signatures env in
  let group value = if paren_wraps_whole value 0 then value else "(" ^ value ^ ")" in
  if type_of_expr signatures env expr <> TBool then
    unsupported (Checker.expr_loc expr) "Go backend can negate Bool expressions only";
  match expr with
  | ELit { lit = LBool value; _ } -> if value then "false" else "true"
  | EConstructor { name = "True"; args = []; _ } -> "false"
  | EConstructor { name = "False"; args = []; _ } -> "true"
  | EUnop { op = UNot; arg; _ } -> group (emit arg)
  | EBinop { op = BAnd; left; right; _ } ->
    Printf.sprintf "(%s || %s)" (group (neg left)) (group (neg right))
  | EBinop { op = BOr; left; right; _ } ->
    Printf.sprintf "(%s && %s)" (group (neg left)) (group (neg right))
  | EBinop { op = (BEq | BNeq) as op; left; right; _ } ->
    (* The operand type comes from whichever side HAS one: a defaulted empty list yields to
       the other, exactly as it does in the positive emission.  Both sides are then emitted
       against it, or `xs != []` would compare a `List OrderItem` with the default's
       `[]teslrt.Int{}` and Go would reject the emitted code. *)
    (* The operand type comes from whichever side HAS one, whether the other is a defaulted
       empty list or an under-constrained constructor. *)
    let ty = match typed_with_default (type_of_expr signatures env) left with
      | Some left_ty, false -> left_ty
      | _ -> type_of_expr signatures env right
    in
    let emitted_left = emit_expr ~expected:ty ~indent signatures env left
    and emitted_right = emit_expr ~expected:ty ~indent signatures env right in
    let equal = (op = BEq) in
    (match bool_literal_value left, bool_literal_value right with
     | Some expected, None when ty = TBool ->
       if expected = equal then neg right else group emitted_right
     | None, Some expected when ty = TBool ->
       if expected = equal then neg left else group emitted_left
     | _ ->
       if equal then unequal_expr ty emitted_left emitted_right
       else equal_expr ty emitted_left emitted_right)
  | EBinop { op = (BLt | BLe | BGt | BGe) as op; left; right; _ } ->
    let ty = type_of_expr signatures env left in
    let flipped = match op with
      | BLt -> ">=" | BLe -> ">" | BGt -> "<=" | BGe -> "<" | _ -> assert false in
    ordered_expr ty flipped (emit left) (emit right)
  | _ -> negate_bool (emit expr)

(* A generic ADT's composite literal must name its type arguments: Go infers type
   parameters for calls, never for a composite literal. *)
(* Applies a function argument to already-bound Go variables.  A lambda's body is
   emitted with its parameters bound to those variable NAMES, so the loop variable is
   named after the lambda parameter and the body needs no rewriting — and if the name
   shadows an outer binding, the Go shadowing matches the Tesl scoping exactly. *)
and emit_applied ?(indent="") signatures env callable params bound =
  match callable with
  | ELambda { params = lambda_params; body; _ } ->
    let env =
      List.map2 (fun (binding : binding) ty -> binding.name, ty) lambda_params params @ env in
    emit_expr ~indent signatures env body
  | EVar { name; _ } ->
    (match Hashtbl.find_opt signatures name with
     | Some signature ->
       baked_call (qualified signature.sig_owner signature.go_name) bound
     (* A local holding a function is called through its own identifier. *)
     | None when List.mem_assoc name env ->
       Printf.sprintf "%s(%s)" (local_ident name) (String.concat ", " bound)
     | None -> invalid_arg "function argument validated before emission")
  | EApp _ ->
    let head, supplied = flatten_app [] callable in
    let go_name = match normalize_call_head head with
      | EVar { name; _ } ->
        (match Hashtbl.find_opt signatures name with
         | Some signature -> qualified signature.sig_owner signature.go_name
         | None -> invalid_arg "function argument validated before emission")
      | _ -> invalid_arg "function argument validated before emission"
    in
    let supplied = List.map (emit_expr ~indent signatures env) supplied in
    baked_call go_name (supplied @ bound)
  (* A combined check as the callback: the SAME sequencing helper `check (a && b) x` mints,
     called with the loop's element.  Sharing the helper is the point — one rule for what a
     conjunction means, whichever position it is written in. *)
  | EBinop { op = BAnd; _ } when (match check_conjunct_calls callable with
                                  | Some (_ :: _ :: _) -> true | _ -> false) ->
    let calls = Option.value (check_conjunct_calls callable) ~default:[] in
    let element = match params with
      | [element] -> element
      | _ -> invalid_arg "combined check callback validated before emission"
    in
    let captured = List.map (fun (name, supplied) ->
      let leading = match Hashtbl.find_opt signatures name with
        | Some signature ->
          List.filteri (fun index _ -> index < List.length supplied) signature.params
        | None -> List.map (fun _ -> element) supplied
      in
      name, leading, List.combine supplied leading) calls in
    let capture_arguments = List.concat_map (fun (_, _, pairs) ->
      List.map (fun (value, want) ->
        emit_expr ~expected:want ~indent signatures env value) pairs) captured in
    Printf.sprintf "%s(%s)"
      (combined_check_helper signatures element
         (List.map (fun (name, leading, _) -> name, leading) captured))
      (String.concat ", " (bound @ capture_arguments))
  | _ -> invalid_arg "function argument validated before emission"

and callable_binders callable fallback =
  match callable with
  | ELambda { params = lambda_params; _ } ->
    List.map (fun (binding : binding) -> local_ident binding.name) lambda_params
  | _ -> fallback

(* Each higher-order leaf is one emitted loop.  The output slice is allocated once at
   its exact length rather than grown, and nothing here allocates a closure. *)
and emit_hof ?(indent="") signatures env _loc _what hof args result =
  let depth = String.length indent in
  let inner = indent ^ "\t" in
  let body_indent = inner ^ "\t" in
  (* Same normalisation as the type rule: the callback may be spelled `String.length`. *)
  let callable = normalize_call_head (List.nth args 0) in
  (* Mirrors the type rule: an EMPTY list argument takes its element type from the
     callback's declared parameter, since the literal carries none of its own. *)
  let element_position = match hof with HofFoldl -> 1 | _ -> 0 in
  let element_from_callable () =
    match callable with
    | ELambda { params; _ } ->
      (match !current_types, List.nth_opt params element_position with
       | Some types, Some (binding : binding) ->
         (try Some (type_of_type_expr types binding.type_expr) with Unsupported _ -> None)
       | _ -> None)
    | EVar { name; _ } ->
      (match Hashtbl.find_opt signatures name with
       | Some signature -> List.nth_opt signature.params element_position
       | None -> None)
    | _ -> None
  in
  let element_of index =
    match List.nth args index with
    | EList { elems = []; _ } when element_from_callable () <> None ->
      (match element_from_callable () with Some element -> element | None -> assert false)
    | arg ->
      (match type_of_expr signatures env arg with
       | TList element -> element
       | _ -> invalid_arg "higher-order leaf validated before emission")
  in
  let emit_list ?(at=indent) index =
    match List.nth args index with
    | EList { elems = []; _ } ->
      emit_expr ~expected:(TList (element_of index)) ~indent:at signatures env
        (List.nth args index)
    | arg -> emit_expr ~indent:at signatures env arg
  in
  (* The source list is BOUND, never spliced twice: `make(…, len(xs))` and `range xs` both
     mention it, and a source that is itself a comprehension would otherwise be emitted — and
     evaluated — twice, squaring the work of `List.filter f (List.map g xs)`.  Binding it at
     `inner` also gives the nested emission its own depth, so its `teslOut`/`teslAt` names
     cannot shadow this level's. *)
  let source_binding index =
    let emitted = emit_list ~at:inner index in
    (* A plain name needs no binding: it is already a single evaluation, and the extra line
       would be noise in the emitted code a reader is meant to be able to eject to. *)
    let simple =
      emitted <> ""
      && String.for_all (fun c ->
           (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
           || c = '_' || c = '.') emitted
    in
    if simple then emitted, ""
    else
      let name = Printf.sprintf "teslSrc%d" depth in
      name, Printf.sprintf "%s%s := %s\n" inner name emitted
  in
  (* A fold's initial accumulator may be an empty list literal, which only emits against
     an expected type. *)
  let emit_init accumulator =
    emit_expr ~expected:accumulator ~indent signatures env (List.nth args 1) in
  match hof with
  | HofMap | HofFilter | HofAny | HofAll ->
    let element = element_of 1 in
    let value = match callable_binders callable [Printf.sprintf "Value%d" depth] with
      | [value] -> value
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let applied = emit_applied ~indent:body_indent signatures env callable [element] [value] in
    let source, bind_source = source_binding 1 in
    (match hof with
     | HofMap ->
       let out = Printf.sprintf "teslOut%d" depth and index = Printf.sprintf "teslAt%d" depth in
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, len(%s))\n%sfor %s, %s := range %s {\n%s%s[%s] = %s\n%s}\n%sreturn %s\n%s}())"
         (go_type result) bind_source inner out (go_type result) source
         inner index value source
         body_indent out index applied
         inner inner out indent
     | HofFilter ->
       let out = Printf.sprintf "teslOut%d" depth in
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%sif %s {\n%s\t%s = append(%s, %s)\n%s}\n%s}\n%sreturn %s\n%s}())"
         (go_type result) bind_source inner out (go_type result) source
         inner value source
         body_indent (strip_outer_parens applied)
         body_indent out out value
         body_indent inner inner out indent
     | _ ->
       let found = (hof = HofAny) in
       Printf.sprintf
         "(func() bool {\n%s%sfor _, %s := range %s {\n%sif %s {\n%s\treturn %b\n%s}\n%s}\n%sreturn %b\n%s}())"
         bind_source inner value source
         body_indent
         (if found then strip_outer_parens applied
          else strip_outer_parens (emit_negated_applied ~indent:body_indent signatures env callable element value))
         body_indent found body_indent inner inner (not found) indent)
  | HofZip ->
    (* Racket truncates to the shorter list; the emitted loop does the same. *)
    let out = Printf.sprintf "teslOut%d" depth in
    let index = Printf.sprintf "teslAt%d" depth in
    let left = Printf.sprintf "teslLeft%d" depth in
    let right = Printf.sprintf "teslRight%d" depth in
    let pair = match result with
      | TList (TAdt (info, args)) ->
        (match single_variant info with
         | Some variant ->
           let names = List.map (fun (name, _) -> variant_field_go_name variant name)
             (variant_field_types info args variant) in
           (match names with
            | [first; second] ->
              Printf.sprintf "%s{%s: %s[%s], %s: %s[%s]}"
                (go_type (TAdt (info, args))) first left index second right index
            | _ -> invalid_arg "zip validated before emission")
         | None -> invalid_arg "zip validated before emission")
      | _ -> invalid_arg "zip validated before emission"
    in
    Printf.sprintf
      "(func() %s {\n%s%s := %s\n%s%s := %s\n%s%s := len(%s)\n%sif len(%s) < %s {\n%s\t%s = len(%s)\n%s}\n%s%s := make(%s, %s)\n%sfor %s := range %s {\n%s%s[%s] = %s\n%s}\n%sreturn %s\n%s}())"
      (go_type result) inner left (emit_list ~at:inner 0)
      inner right (emit_list ~at:inner 1)
      inner (Printf.sprintf "teslLen%d" depth) left
      inner right (Printf.sprintf "teslLen%d" depth)
      inner (Printf.sprintf "teslLen%d" depth) right
      inner
      inner out (go_type result) (Printf.sprintf "teslLen%d" depth)
      inner index out
      body_indent out index pair
      inner inner out indent
  (* `List.emptyForAll check` is the empty list: the `ForAll` it carries is vacuously true and
     erases, so the check names the element type and nothing else. *)
  | HofEmptyForAll ->
    (match result with
     | TList element -> Printf.sprintf "[]%s{}" (go_type element)
     | _ -> invalid_arg "emptyForAll validated before emission")
  (* The Set counterpart of `filterCheck`: the accepted elements, rebuilt as a set.  Going
     through the set's own list keeps ONE traversal rule for both containers. *)
  | HofSetFilterCheck | HofSetAllCheck ->
    let element = match type_of_expr signatures env (List.nth args 1) with
      | TSet element -> element
      | _ -> invalid_arg "Set check leaf validated before emission"
    in
    let value = match callable_binders callable [Printf.sprintf "Value%d" depth] with
      | [value] -> value
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let checked = emit_applied ~indent:body_indent signatures env callable [element] [value] in
    let source = emit_expr ~indent:inner signatures env (List.nth args 1) in
    let out = Printf.sprintf "teslOut%d" depth in
    let kept = Printf.sprintf "teslKept%d" depth in
    let ok = Printf.sprintf "teslOK%d" depth in
    let all_ok = Printf.sprintf "teslAll%d" depth in
    (match hof with
     | HofSetFilterCheck ->
       Printf.sprintf
         "(func() %s {\n%s%s := teslrt.SetEmpty[%s]()\n%sfor _, %s := range teslrt.SetToList(%s) {\n%sif %s, %s := (%s).Value(); %s {\n%s\t%s = teslrt.SetInsert(%s, %s, %s)\n%s}\n%s}\n%sreturn %s\n%s}())"
         (go_type result) inner out (go_type element)
         inner value source
         body_indent kept ok checked ok
         body_indent out kept out (element_key_less_func element)
         body_indent inner inner out indent
     (* Like `List.allCheck`, the check runs on EVERY element before the verdict is taken:
        an early return would skip checks the Racket backend performs. *)
     | _ ->
       Printf.sprintf
         "(func() %s {\n%s%s := true\n%s%s := teslrt.SetEmpty[%s]()\n%sfor _, %s := range teslrt.SetToList(%s) {\n%sif %s, %s := (%s).Value(); %s {\n%s\t%s = teslrt.SetInsert(%s, %s, %s)\n%s} else {\n%s\t%s = false\n%s}\n%s}\n%sif %s {\n%s\treturn %s{%s: %s, %s: %s}\n%s}\n%sreturn %s{%s: %s}\n%s}())"
         (go_type result) inner all_ok
         inner out (go_type element)
         inner value source
         body_indent kept ok checked ok
         body_indent out kept out (element_key_less_func element)
         body_indent body_indent all_ok body_indent
         inner
         inner all_ok inner (go_type result) adt_tag_field "teslrt.MaybeSomething"
         "SomethingValue" out inner
         inner (go_type result) adt_tag_field "teslrt.MaybeNothing" indent)
  (* The dict counterpart: the check runs on each VALUE, and a passing entry is rebuilt with
     its key.  Iterating the dict's own pair list keeps one traversal rule for every
     container. *)
  | HofDictFilterCheckValues | HofDictFilterCheckKeys ->
    let key_type, value_type = match type_of_expr signatures env (List.nth args 1) with
      | TDict (key, value) -> key, value
      | _ -> invalid_arg "Dict check leaf validated before emission"
    in
    let keys = hof = HofDictFilterCheckKeys in
    let pair = Printf.sprintf "teslPair%d" depth in
    let subject = Printf.sprintf "%s.%s" pair
      (if keys then "Tuple2First" else "Tuple2Second") in
    let checked = emit_applied ~indent:body_indent signatures env callable
      [if keys then key_type else value_type] [subject] in
    let source = emit_expr ~indent:inner signatures env (List.nth args 1) in
    let out = Printf.sprintf "teslOut%d" depth in
    let kept = Printf.sprintf "teslKept%d" depth in
    let ok = Printf.sprintf "teslOK%d" depth in
    (* The CHECKED value is what goes back in — a check may answer a different value than it
       was given (a normalising check does), and Racket stores `check-ok-value` too. *)
    let entry_key = if keys then kept else Printf.sprintf "%s.Tuple2First" pair in
    let entry_value = if keys then Printf.sprintf "%s.Tuple2Second" pair else kept in
    Printf.sprintf
      "(func() %s {\n%s%s := teslrt.DictEmpty[%s, %s]()\n%sfor _, %s := range teslrt.DictToList(%s) {\n%sif %s, %s := (%s).Value(); %s {\n%s\t%s = teslrt.DictInsert(%s, %s, %s, %s)\n%s}\n%s}\n%sreturn %s\n%s}())"
      (go_type result) inner out (go_type key_type) (go_type value_type)
      inner pair source
      body_indent kept ok checked ok
      body_indent out out entry_key entry_value (element_key_less_func key_type)
      body_indent inner inner out indent
  (* `count` is `filter` that keeps the tally instead of the elements. *)
  | HofCount ->
    let element = element_of 1 in
    let value = match callable_binders callable [Printf.sprintf "Value%d" depth] with
      | [value] -> value
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let applied = emit_applied ~indent:body_indent signatures env callable [element] [value] in
    let source, bind_source = source_binding 1 in
    let out = Printf.sprintf "teslOut%d" depth in
    Printf.sprintf
      "(func() teslrt.Int {\n%s%s%s := 0\n%sfor _, %s := range %s {\n%sif %s {\n%s\t%s++\n%s}\n%s}\n%sreturn teslrt.FromInt64(int64(%s))\n%s}())"
      bind_source inner out
      inner value source
      body_indent (strip_outer_parens applied)
      body_indent out body_indent
      inner
      inner out indent
  | HofFilterCheck | HofAllCheck ->
    let element = element_of 1 in
    let value = match callable_binders callable [Printf.sprintf "Value%d" depth] with
      | [value] -> value
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let checked = emit_applied ~indent:body_indent signatures env callable [element] [value] in
    let source, bind_source = source_binding 1 in
    let out = Printf.sprintf "teslOut%d" depth in
    let kept = Printf.sprintf "teslKept%d" depth in
    let ok = Printf.sprintf "teslOK%d" depth in
    (* The per-element `ok` is scoped to its `if`, so the running flag MUST NOT share
       its name: `teslOK := false` would otherwise assign to the shadow and allCheck
       would never report a failure. *)
    let all_ok = Printf.sprintf "teslAll%d" depth in
    let elements = go_type (TList element) in
    (match hof with
     | HofFilterCheck ->
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%sif %s, %s := (%s).Value(); %s {\n%s\t%s = append(%s, %s)\n%s}\n%s}\n%sreturn %s\n%s}())"
         elements bind_source inner out elements source
         inner value source
         body_indent kept ok checked ok
         body_indent out out kept
         body_indent inner inner out indent
     | _ ->
       (* Racket's allCheck runs the check on EVERY element before deciding, so this
          does too: an early return would skip checks the Racket backend performs. *)
       Printf.sprintf
         "(func() %s {\n%s%s%s := true\n%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%sif %s, %s := (%s).Value(); %s {\n%s\t%s = append(%s, %s)\n%s} else {\n%s\t%s = false\n%s}\n%s}\n%sif %s {\n%s\treturn %s{%s: %s, %s: %s}\n%s}\n%sreturn %s{%s: %s}\n%s}())"
         (go_type result) bind_source inner all_ok
         inner out elements source
         inner value source
         body_indent kept ok checked ok
         body_indent out out kept
         body_indent body_indent all_ok body_indent
         inner
         inner all_ok inner (go_type result) adt_tag_field "teslrt.MaybeSomething"
         "SomethingValue" out inner
         inner (go_type result) adt_tag_field "teslrt.MaybeNothing" indent)
  (* `find` is an early-return loop; the other three fill a fresh output. *)
  | HofFind | HofFilterMap | HofConcatMap ->
    let element = element_of 1 in
    let value = match callable_binders callable [Printf.sprintf "Value%d" depth] with
      | [value] -> value
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let applied = emit_applied ~indent:body_indent signatures env callable [element] [value] in
    let source, bind_source = source_binding 1 in
    let out = Printf.sprintf "teslOut%d" depth in
    let found = Printf.sprintf "teslFound%d" depth in
    (match hof with
     | HofFind ->
       Printf.sprintf
         "(func() %s {\n%s%sfor _, %s := range %s {\n%sif %s {\n%s\treturn %s{%s: teslrt.MaybeSomething, SomethingValue: %s}\n%s}\n%s}\n%sreturn %s{%s: teslrt.MaybeNothing}\n%s}())"
         (go_type result) bind_source inner value source
         body_indent (strip_outer_parens applied)
         body_indent (go_type result) adt_tag_field value
         body_indent inner
         inner (go_type result) adt_tag_field indent
     | HofFilterMap ->
       (* Decided by the TAG: a `Something` whose payload is `false` is still kept. *)
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%sif %s := %s; %s.%s == teslrt.MaybeSomething {\n%s\t%s = append(%s, %s.SomethingValue)\n%s}\n%s}\n%sreturn %s\n%s}())"
         (go_type result) bind_source inner out (go_type result) source
         inner value source
         body_indent found applied found adt_tag_field
         body_indent out out found
         body_indent inner inner out indent
     | _ ->
       Printf.sprintf
         "(func() %s {\n%s%s%s := make(%s, 0, len(%s))\n%sfor _, %s := range %s {\n%s%s = append(%s, %s...)\n%s}\n%sreturn %s\n%s}())"
         (go_type result) bind_source inner out (go_type result) source
         inner value source
         body_indent out out applied
         inner inner out indent)
  (* `sortBy` builds a comparator from the key function.  The key is recomputed per
     comparison, matching `List.sortBy` in tesl/list.rkt, and the sort is stable. *)
  | HofSortBy ->
    let element = element_of 1 in
    (* Fixed names, NOT depth-derived: the comparator is a package-level function with its
       own scope, so nothing can collide — and a depth-derived name would differ between
       the looped and flat emission passes, minting a second helper the first pass's name
       no longer matches and leaving an unused function behind. *)
    let left = "teslLeft" and right = "teslRight" in
    let key_ty = type_of_callable signatures env (Checker.expr_loc callable) "List.sortBy"
      callable [element] in
    (* A comparator needs the key on BOTH sides, and a lambda body inlined twice would
       reference its own parameter name, which is bound to neither side.  So a lambda key
       is hoisted into a named function — emitted once, with the lambda's parameter as the
       Go parameter, which is exactly the shape `emit_applied` already produces — and each
       side becomes a direct, inlinable call.  A named key function needs none of this. *)
    let key_call =
      match callable with
      | ELambda { params = [param]; _ } ->
        let binder = local_ident param.name in
        let name = remember_helper ~prefix:"teslSortKey"
          ~signature:(Printf.sprintf "(%s %s) %s" binder (go_type element) (go_type key_ty))
          ~body:(emit_applied ~indent:"\t" signatures env callable [element] [binder])
        in
        (fun side -> Printf.sprintf "%s(%s)" name side)
      | _ ->
        (fun side -> emit_applied ~indent:body_indent signatures env callable [element] [side])
    in
    (* The comparator is hoisted for the same reason a nested element comparator is: a
       one-line func literal survives only while go/printer judges it small enough, and
       this one is not. *)
    let less = remember_helper ~prefix:"teslSortLess"
      ~signature:(Printf.sprintf "(%s, %s %s) bool" left right (go_type element))
      ~body:(ordered_expr key_ty "<" (key_call left) (key_call right))
    in
    Printf.sprintf "teslrt.ListSortBy(%s, %s)" (emit_list 1) less
  | HofFoldl ->
    let element = element_of 2 in
    let accumulator = result in
    let bound = match callable_binders callable
      [Printf.sprintf "teslAcc%d" depth; Printf.sprintf "Value%d" depth] with
      | [acc; value] -> [acc; value]
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let state = Printf.sprintf "teslState%d" depth in
    let applied =
      emit_applied ~indent:body_indent signatures env callable [accumulator; element] bound in
    (* Both binders are discarded explicitly.  A callback that ignores its element — `fn(acc,
       ignored) -> acc + 1`, which is how a fold counts — otherwise leaves the range variable
       declared and unused, and Go rejects that. *)
    Printf.sprintf
      "(func() %s {\n%s%s := %s\n%sfor _, %s := range %s {\n%s_ = %s\n%s%s := %s\n%s_ = %s\n%s%s = %s\n%s}\n%sreturn %s\n%s}())"
      (go_type accumulator) inner state (emit_init accumulator)
      inner (List.nth bound 1) (emit_list ~at:inner 2)
      body_indent (List.nth bound 1)
      body_indent (List.nth bound 0) state
      body_indent (List.nth bound 0)
      body_indent state applied
      inner inner state indent
  (* `foldr` walks the slice BACKWARDS in a plain loop rather than recursing: Go has no
     TCO and a Go stack overflow is fatal (no `recover`), so recursing once per element
     would put a list length limit on a function Racket runs fine.  The fold itself
     therefore adds only O(n) traversal.  What it CANNOT fix is a callback that performs
     an immutable write on a growing accumulator — `List.append [x] acc` copies Θ(k) at
     step k, so the canonical reconstruction fold is Θ(n²) in the CALLBACK, not in the
     fold.  Lowering recognised builder folds to a private allocate-once builder is a
     tracked gate, and it needs an escape/linearity condition first: an arbitrary callback
     may retain an earlier accumulator inside its result, so uniqueness cannot be assumed
     from the shape alone. *)
  | HofFoldr ->
    let element = element_of 2 in
    let accumulator = result in
    let bound = match callable_binders callable
      [Printf.sprintf "Value%d" depth; Printf.sprintf "teslAcc%d" depth] with
      | [value; acc] -> [value; acc]
      | _ -> invalid_arg "higher-order leaf validated before emission"
    in
    let state = Printf.sprintf "teslState%d" depth in
    let source = Printf.sprintf "teslSource%d" depth in
    let index = Printf.sprintf "teslAt%d" depth in
    let applied =
      emit_applied ~indent:body_indent signatures env callable [element; accumulator] bound in
    (* The list is bound once: it is an arbitrary expression, and backwards iteration
       needs both its length and an index into it. *)
    Printf.sprintf
      "(func() %s {\n%s%s := %s\n%s%s := %s\n%sfor %s := len(%s) - 1; %s >= 0; %s-- {\n%s%s := %s[%s]\n%s_ = %s\n%s%s := %s\n%s_ = %s\n%s%s = %s\n%s}\n%sreturn %s\n%s}())"
      (go_type accumulator) inner state (emit_init accumulator)
      inner source (emit_list ~at:inner 2)
      inner index source index index
      body_indent (List.nth bound 0) source index
      body_indent (List.nth bound 0)
      body_indent (List.nth bound 1) state
      body_indent (List.nth bound 1)
      body_indent state applied
      inner inner state indent

(* `all` is the negation of "any element fails", and negating structurally keeps the
   emitted condition free of the `!(a && b)` shapes the lint gate rejects. *)
and emit_negated_applied ?(indent="") signatures env callable element value =
  match callable with
  | ELambda { params = lambda_params; body; _ } ->
    let env =
      List.map2 (fun (binding : binding) ty -> binding.name, ty) lambda_params [element] @ env in
    emit_negated ~indent signatures env body
  | _ -> negate_bool (emit_applied ~indent signatures env callable [element] [value])

(* Dict leaves are ordinary runtime calls; the only emitted extra is the key ordering,
   appended last so the hand-written signatures read naturally. *)
and emit_dict_leaf ?(indent="") signatures env loc leaf args result expected =
  let args = normalize_call_args (List.init leaf.dict_arity (fun _ -> TUnit)) args in
  let key =
    match leaf.dict_name, result, expected with
    | "Dict.empty", _, Some (TDict (key, _)) -> Some key
    | "Dict.empty", _, _ -> None
    | _, TDict (key, _), _ -> Some key
    | _ ->
      (match typed_with_default (type_of_expr signatures env)
               (List.nth args (leaf.dict_arity - 1)) with
       | Some (TDict (key, _)), _ -> Some key
       (* See the matching note in the type rule: a leaf that observes neither the key nor
          the value gets one rather than a refusal. *)
       | _ when leaf.dict_name = "Dict.isEmpty" || leaf.dict_name = "Dict.size" -> Some TInt
       | _ -> None)
  in
  (* `Dict.empty` takes no argument, so its type parameters have to be written out. *)
  let instantiation =
    if leaf.dict_name <> "Dict.empty" then ""
    else match expected with
      | Some (TDict (key, value)) ->
        Printf.sprintf "[%s, %s]" (go_type key) (go_type value)
      | _ -> unsupported loc
        "Go backend cannot infer the key and value types of `Dict.empty`"
  in
  (* The dict argument is emitted with its type EXPECTED, so an empty dict written in place
     (`Dict.insert k v Dict.empty`) knows what to instantiate. *)
  let emitted = List.mapi (fun index argument ->
    (* `Dict.fromList` takes a LIST OF PAIRS, not a dict — the only leaf whose last
       argument is neither.  An empty list there carries no pair type of its own, so the
       result's key and value are what say what it holds. *)
    (* `isEmpty` and `size` observe neither the key nor the value, so a bare `Dict.empty`
       here is given a pair to instantiate rather than left without one — see the matching
       note in the type rule. *)
    if (leaf.dict_name = "Dict.isEmpty" || leaf.dict_name = "Dict.size")
       && index = leaf.dict_arity - 1 then
      (match key with
       | Some element -> emit_expr ~expected:(TDict (element, element)) ~indent signatures env argument
       | None -> emit_expr ~indent signatures env argument)
    else if leaf.dict_name = "Dict.fromList" then
      (match result, Option.bind !current_types (fun types -> Hashtbl.find_opt types.adts "Tuple2") with
       | TDict (key, value), Some tuple ->
         emit_expr ~expected:(TList (TAdt (tuple, [key; value]))) ~indent signatures env argument
       | _ -> emit_expr ~indent signatures env argument)
    else if index = leaf.dict_arity - 1 && leaf.dict_name <> "Dict.singleton"
       && leaf.dict_name <> "Dict.empty" && result <> TFailure then
      match result, key with
      | TDict (_, value), Some key ->
        emit_expr ~expected:(TDict (key, value)) ~indent signatures env argument
      | _ -> emit_expr ~indent signatures env argument
    else emit_expr ~indent signatures env argument) args in
  (* Tesl puts the dict LAST (`Dict.insert key value d`); the runtime signatures put it
     first, which is what a Go author expects.  The emitter rotates rather than
     distorting the hand-written runtime.  `Dict.singleton` is the exception: it BUILDS a
     dict from a key and a value, so its last argument is not one to move to the front —
     rotating it silently swapped the pair. *)
  let emitted =
    if leaf.dict_arity > 1 && leaf.dict_name <> "Dict.singleton"
       && leaf.dict_name <> "Dict.union" then
      match List.rev emitted with
      | dict :: rest -> dict :: List.rev rest
      | [] -> emitted
    else emitted
  in
  let emitted =
    if not leaf.dict_needs_order then emitted
    else match key with
      | Some key -> emitted @ [element_key_less_func key]
      | None -> unsupported loc "Go backend `%s` needs ordered keys" leaf.dict_name
  in
  Printf.sprintf "%s%s(%s)" leaf.dict_go instantiation (String.concat ", " emitted)

(* Set leaves are ordinary runtime calls; the ordering is appended last, and
   `Set.empty` writes its type parameter out since it has no argument to infer from. *)
and emit_set_leaf ?(indent="") signatures env loc leaf args result expected =
  let args = normalize_call_args (List.init leaf.set_arity (fun _ -> TUnit)) args in
  let element = match result, expected with
    | TSet element, _ -> element
    | _, Some (TSet element) -> element
    | _ ->
      if leaf.set_index >= 0 then
        (match typed_with_default (type_of_expr signatures env)
                 (List.nth args leaf.set_index) with
         | Some (TSet element), _ -> element
         (* `isEmpty` and `size` answer the same whatever the set holds, so a bare
            `Set.empty` there is given an element rather than refused: the choice cannot
            change the result.  Anything whose result MENTIONS the element still fails
            closed, because there the choice would be a guess. *)
         | _ when leaf.set_name = "Set.isEmpty" || leaf.set_name = "Set.size" -> TInt
         | _ -> unsupported loc "Go backend `%s` requires a Set argument" leaf.set_name)
      else unsupported loc "Go backend cannot infer the element type of `%s`" leaf.set_name
  in
  let instantiation =
    if leaf.set_name <> "Set.empty" then ""
    else Printf.sprintf "[%s]" (go_type element)
  in
  let emitted = List.mapi (fun index argument ->
    (* `Set.fromList` takes a LIST, not a set — the one leaf whose indexed argument is a
       different container — so an empty one there is expected at the ELEMENT type.  Handing
       it a set expectation left the elements defaulted while the comparator followed the
       real element type, and the two disagreed. *)
    if leaf.set_name = "Set.fromList" then
      emit_expr ~expected:(TList element) ~indent signatures env argument
    else if index = leaf.set_index then
      emit_expr ~expected:(TSet element) ~indent signatures env argument
    else emit_expr ~indent signatures env argument) args in
  let emitted =
    if not leaf.set_needs_order then emitted
    else emitted @ [element_key_less_func element]
  in
  Printf.sprintf "%s%s(%s)" leaf.set_go instantiation (String.concat ", " emitted)

and emit_variant_literal ?(indent="") signatures env result variant args =
  let info, type_args = match result with
    | TAdt (info, args) -> info, args
    | _ -> invalid_arg "constructor validated before emission"
  in
  let payload = variant_field_types info type_args variant in
  let parts = List.map2 (fun arg (name, field_ty) ->
    let value = emit_expr ~expected:field_ty ~indent signatures env arg in
    (* A self-referential payload is boxed: `teslrt.Boxed` takes its argument by value, so
       the operand needs no address of its own — a composite literal's field is not
       addressable, which is why this is a call rather than an `&`. *)
    let value =
      if adt_self_payload info variant name then Printf.sprintf "teslrt.Boxed(%s)" value
      else value
    in
    Printf.sprintf "%s: %s" (variant_field_go_name variant name) value) args payload in
  let fields =
    if single_variant info <> None then parts
    else (adt_tag_field ^ ": " ^ qualified info.adt_owner variant.var_tag) :: parts
  in
  Printf.sprintf "%s{%s}" (go_type result) (String.concat ", " fields)

and emit_record_literal ?(indent="") signatures env info fields =
  (* A field-by-field COPY between two records with the same fields in the same order is a
     staticcheck finding on the emitted code (S1016, "should convert instead of using a
     struct literal") — and a lint finding on emitted code is an emitter bug by contract.
     It is also what the Go conversion says more clearly, so `Target(source)` is emitted
     when every field is `source.<same field>` and the source type matches field for
     field. *)
  let conversion_source () =
    let field_of_source name =
      match List.assoc_opt name fields with
      | Some (EField { obj = EVar { name = binder; _ }; field; _ }) when field = name ->
        Some binder
      | _ -> None
    in
    match info.rec_fields with
    | [] -> None
    | (first, _) :: _ ->
      (match field_of_source first with
       | None -> None
       | Some binder ->
         let all_from_binder =
           List.for_all (fun (name, _) -> field_of_source name = Some binder)
             info.rec_fields
         in
         if not all_from_binder then None
         else
           (match List.assoc_opt binder env with
            | Some (TRecord source)
              when source.rec_go_name <> info.rec_go_name
                && List.length source.rec_fields = List.length info.rec_fields
                && List.for_all2 (fun (left, left_ty) (right, right_ty) ->
                     left = right && type_equal left_ty right_ty)
                     source.rec_fields info.rec_fields ->
              Some (local_ident binder)
            | _ -> None))
  in
  match conversion_source () with
  | Some source ->
    Printf.sprintf "%s(%s)" (qualified info.rec_owner info.rec_go_name) source
  | None ->
  let parts = List.map (fun (name, field_ty) ->
    let value = match List.assoc_opt name fields with
      | Some value -> value
      | None -> invalid_arg "record literal validated before emission"
    in
    Printf.sprintf "%s: %s" (record_field_go_name name)
      (emit_expr ~expected:field_ty ~indent signatures env value)) info.rec_fields in
  (* Qualified for the same reason `go_type` qualifies: a record declared by another
     package is constructed through that package's name. *)
  Printf.sprintf "%s{%s}" (qualified info.rec_owner info.rec_go_name)
    (String.concat ", " parts)

(* Tesl record update copies the base and overrides the listed fields.  A struct
   literal naming every field is the readable Go shape, but it repeats the base
   expression once per preserved field, so anything other than a local binding is
   bound first. *)
and emit_record_update ?(indent="") signatures env loc fields =
  let base, updates = record_update_parts loc fields in
  let info = match type_of_expr signatures env base with
    | TRecord info -> info
    | _ -> unsupported loc "Go backend record update requires a record value"
  in
  let literal value_indent base_text =
    let parts = List.map (fun (name, field_ty) ->
      let value = match List.assoc_opt name updates with
        | Some value -> emit_expr ~expected:field_ty ~indent:value_indent signatures env value
        | None -> Printf.sprintf "%s.%s" base_text (record_field_go_name name)
      in
      Printf.sprintf "%s: %s" (record_field_go_name name) value) info.rec_fields in
    Printf.sprintf "%s{%s}" (qualified info.rec_owner info.rec_go_name)
      (String.concat ", " parts)
  in
  let rec is_local = function
    | EVar { name; _ } -> List.mem_assoc name env
    | EField { obj; _ } -> is_local obj
    | _ -> false
  in
  (* The struct literal repeats the base once per preserved field, so the base has
     to be a binding rather than a computation.  Today's surface syntax only allows
     `{ identifier | ... }`, so this rejection is unreachable from `.tesl` source and
     stays as containment rather than an untested emit path. *)
  if not (is_local base) then
    unsupported loc "Go backend record update requires a bound record value";
  literal indent (selector_operand (emit_expr ~indent signatures env base))

(* ─── Queries ─────────────────────────────────────────────────────────────────
   The `backend: Memory` store has no query planner: a clause is the same comparison
   the Racket runtime performs row by row, so a query becomes a table call plus a Go
   PREDICATE over the row.  The binder is the one the query itself named, which is what
   lets a `set` value or a column-to-column comparison read as written. *)
and sql_table_ref (info : entity_info) = qualified info.ent_owner info.ent_table_var

and sql_row_type (info : entity_info) = go_type (TRecord info.ent_row)

and sql_column_value ~indent signatures row_env loc (info : entity_info) field expr =
  let want = entity_column loc info field in
  let got = type_of_arg signatures row_env want expr in
  (* No coercion here, deliberately.  A String written to a `Maybe String` column is
     refused, which is the LANGUAGE's own rule — the checker's SET-clause validation says
     "the assigned value must have the same type; convert or construct it explicitly".  That
     validation only sees entities declared in the SAME module (`record_fields_of_type` is
     module-local), so a cross-module entity slips past it; accepting the coercion here would
     make the Go backend agree with the hole rather than with the rule. *)
  if type_unequal got want then unsupported (Checker.expr_loc expr)
    "Go backend: the value written to `%s.%s` has a different type than the column"
    info.ent_tesl_name field;
  emit_expr ~expected:want ~indent signatures row_env expr

and emit_sql_predicate ?(joins=[]) ~indent signatures env loc (info : entity_info) binder clauses =
  let row_env = (binder, TRecord info.ent_row) :: env in
  let column_ref field =
    Printf.sprintf "%s.%s" (local_ident binder) (record_field_go_name field) in
  let compare_op field op expr =
    let ty = entity_column loc info field in
    let left = column_ref field in
    let right = sql_column_value ~indent signatures row_env loc info field expr in
    match op with
    | BEq -> equal_expr ty left right
    | BNeq -> unequal_expr ty left right
    | BLt | BLe | BGt | BGe ->
      if not (supports_column_ordering ty) then unsupported loc
        "Go backend cannot order column `%s.%s`" info.ent_tesl_name field;
      let symbol = match op with
        | BLt -> "<" | BLe -> "<=" | BGt -> ">" | _ -> ">=" in
      ordered_expr ty symbol left right
    | _ -> unsupported loc
      "Go backend does not support this operator in a `where` clause yet"
  in
  (* `like` / `ilike` are String-only, as they are on the Racket side (which rejects a
     Money column outright and answers false for any non-string value). *)
  let like field pattern fold_case =
    let ty = entity_column loc info field in
    let text = match ty with
      | TString -> column_ref field
      | TNewtype newtype when newtype.base = TString ->
        Printf.sprintf "%s.Value" (column_ref field)
      | _ -> unsupported loc
        "Go backend supports `like`/`ilike` on a String column only, and `%s.%s` is not one"
        info.ent_tesl_name field
    in
    let pattern_ty = type_of_expr signatures row_env pattern in
    if pattern_ty <> TString then unsupported (Checker.expr_loc pattern)
      "Go backend `like`/`ilike` needs a String pattern";
    Printf.sprintf "teslrt.SqlLike(%s, %s, %b)" text
      (emit_expr ~expected:TString ~indent signatures row_env pattern) fold_case
  in
  let rec clause (c : Sql_query.sql_clause) =
    match c with
    | SqlPred { field; op; value } -> compare_op field op value
    | SqlOr parts ->
      (* An empty disjunction matches nothing, which is what the SQL `false` it would
         render to does.  It is not reachable from source; the case exists so the
         renderer is total. *)
      (match List.map clause parts with
       | [] -> "false"
       | rendered -> "(" ^ String.concat " || " rendered ^ ")")
    | SqlIn { field; values } ->
      (match List.map (fun value -> compare_op field BEq value) values with
       | [] -> "false"
       | rendered -> "(" ^ String.concat " || " rendered ^ ")")
    | SqlNotIn { field; values } ->
      (match List.map (fun value -> compare_op field BNeq value) values with
       | [] -> "true"
       | rendered -> "(" ^ String.concat " && " rendered ^ ")")
    | SqlIsNull { field } -> unsupported loc
      "Go backend does not support `where isNull %s.%s` yet" binder field
    | SqlIsNotNull { field } -> unsupported loc
      "Go backend does not support `where isNotNull %s.%s` yet" binder field
    | SqlLike { field; pattern } -> like field pattern false
    | SqlILike { field; pattern } -> like field pattern true
  in
  (* The predicate is emitted ALREADY SPLIT across lines rather than as a one-liner.  A
     `func(r T) bool { return … }` survives gofmt only while go/printer judges the whole line
     short enough, and a two-clause `where` on a newtype column is already past that — so a
     one-liner is gofmt-stable for small predicates and reflowed for the rest, which the
     emitted-code gate reads as an emitter bug (correctly: the emitter must produce gofmt's
     own output).  gofmt never JOINS a split literal, so the split form is stable at every
     size. *)
  let split params returned =
    Printf.sprintf "func(%s) bool {\n%s\treturn %s\n%s}" params indent returned indent
  in
  let rendered = List.map clause clauses @ joins in
  match rendered with
  (* No clause means every row, and naming the row would leave an unused parameter. *)
  | [] -> split (Printf.sprintf "_ %s" (sql_row_type info)) "true"
  | _ ->
    split (Printf.sprintf "%s %s" (local_ident binder) (sql_row_type info))
      (String.concat " && " rendered)

(* `where_field` is the field the RECOVERY saw first; every supported form also produces
   a clause for it.  One left over means the predicate was written in a shape this
   backend does not render, and emitting the query without it would silently read or
   write the wrong rows. *)
and sql_check_where_field loc where_field clauses =
  let rec mentions field (c : Sql_query.sql_clause) =
    match c with
    | SqlPred { field = other; _ } | SqlIsNull { field = other }
    | SqlIsNotNull { field = other } | SqlIn { field = other; _ }
    | SqlNotIn { field = other; _ } | SqlLike { field = other; _ }
    | SqlILike { field = other; _ } -> other = field
    | SqlOr parts -> List.exists (mentions field) parts
  in
  match where_field with
  | Some field when not (List.exists (mentions field) clauses) ->
    unsupported loc
      "Go backend does not support this `where` clause shape (on `%s`) yet" field
  | _ -> ()

(* The duplicate-primary-key test an insert carries: the same comparison the Racket
   memory backend performs by keying its store on the primary key. *)
and sql_key_conflict loc (info : entity_info) =
  let key = info.ent_primary_key in
  let key_type = entity_column loc info key in
  let field name = Printf.sprintf "%s.%s" name (record_field_go_name key) in
  Printf.sprintf "func(teslRow, teslNew %s) bool { return %s }" (sql_row_type info)
    (equal_expr key_type (field "teslRow") (field "teslNew"))

(* ─── The SQL half of a query ─────────────────────────────────────────────────
   For an entity a Postgres-backed database manages, the same query is emitted TWICE: once as
   the Go predicate the in-memory table needs, once as the statement the server needs.  The
   dispatcher picks at run time, because which store an entity's rows live in is decided by
   whether something has CONNECTED — a `test` block runs the very same query against the memory
   table with no server anywhere, which is what `database-runtime-for-entity` decides on the
   Racket side.

   The statement's TEXT is built here, at compile time, and never carries a value: every operand
   becomes a `$n` placeholder with its Go expression in the argument list.  So nothing a request
   sends can change what a statement SAYS. *)
and sql_placeholder (builder : sql_arguments) argument =
  builder.sql_args <- builder.sql_args @ [argument];
  Printf.sprintf "$%d" (List.length builder.sql_args)

(* The Go expression that BINDS a value of a column's type.  An `Int` travels as a NUMERIC
   rather than through int64, which is exactly where a Tesl integer stops being unbounded. *)
and sql_bound_value loc ty value =
  match ty with
  | TInt -> Printf.sprintf "teslrt.PgInt(%s)" value
  | TFloat | TString | TBool -> value
  | TNewtype { tesl_name = "PosixMillis"; _ } ->
    Printf.sprintf "teslrt.PgBigint(%s.Value)" value
  | TNewtype { secret = true; tesl_name; _ } ->
    (* A secret's payload is a redacting carrier, not a string: binding it would put the
       plaintext on the wire under a name that promises it is not there. *)
    unsupported loc
      "Go backend does not support a `secret` column (`%s`) on a Postgres-backed database yet"
      tesl_name
  | TNewtype newtype -> sql_bound_value loc newtype.base (value ^ ".Value")
  | TAdt (info, _) when info.adt_tesl_name <> "Maybe" ->
    Printf.sprintf "teslrt.EncodeJSONValue(%s(%s))" (!value_encoder_hook ty) value
  | _ ->
    (match maybe_element ty with
     | Some inner ->
       Printf.sprintf "teslrt.PgNull(%s, func(teslValue %s) any { return %s })"
         value (go_type inner) (sql_bound_value loc inner "teslValue")
     | None -> unsupported loc
       "Go backend cannot store a `%s` value in a column yet" (go_type ty))

(* The driver-side carrier a column is SCANNED into, and the expression that turns it back into
   the Tesl value.  A pair, so the scanner declares one variable and assigns one field per
   column, in the entity's own order. *)
and sql_scan_carrier loc ty target =
  match ty with
  | TInt -> ("pgtype.Numeric", Printf.sprintf "teslrt.PgIntOf(%s)" target)
  | TFloat -> ("float64", target)
  | TString -> ("string", target)
  | TBool -> ("bool", target)
  | TNewtype { tesl_name = "PosixMillis"; go_name; owner; _ } ->
    ("int64", Printf.sprintf "%s{Value: teslrt.FromInt64(%s)}" (qualified owner go_name) target)
  | TNewtype { secret = true; tesl_name; _ } ->
    unsupported loc
      "Go backend does not support a `secret` column (`%s`) on a Postgres-backed database yet"
      tesl_name
  | TNewtype newtype ->
    let carrier, decode = sql_scan_carrier loc newtype.base target in
    (carrier, Printf.sprintf "%s{Value: %s}" (qualified newtype.owner newtype.go_name) decode)
  | TAdt (info, _) when info.adt_tesl_name <> "Maybe" ->
    ("[]byte", Printf.sprintf "%s(%s)" (sql_adt_column_decoder loc info) target)
  | _ ->
    (match maybe_element ty with
     | Some inner ->
       let carrier, decode = sql_scan_carrier loc inner ("*" ^ target) in
       ("*" ^ carrier,
        Printf.sprintf "teslrt.MaybeOfPointer(%s, func() %s { return %s })"
          target (go_type inner) decode)
     | None -> unsupported loc
       "Go backend cannot read a `%s` column back yet" (go_type ty))

(* The reader for an ADT COLUMN.  The stored shape is the value's own wire shape — `{"tag": …}`
   for a constructor with no fields — so reading it back is a tag lookup.  A constructor that
   CARRIES fields is refused rather than half-read: decoding those needs the generic decoder,
   which does not derive an ADT yet, and a column that silently lost its payload is worse than
   one that does not compile.

   An unknown tag TRAPS.  It means the column holds a value this build has no constructor for —
   data written by an incompatible schema — and `dsl/sql.rkt` takes the same line for a stored
   currency code it cannot resolve. *)
and sql_adt_column_decoder loc (info : adt_info) =
  let name = "teslColumn" ^ go_ident ~exported:true info.adt_tesl_name in
  if not (Hashtbl.mem pending_helpers name) then begin
    List.iter (fun variant ->
      if variant.var_fields <> [] then unsupported loc
        "Go backend does not support a `%s` column on a Postgres-backed database yet: its \
         constructor `%s` carries fields" info.adt_tesl_name variant.var_ctor)
      info.adt_variants;
    let go_ty = qualified info.adt_owner info.adt_go_name in
    let buffer = Buffer.create 256 in
    Printf.bprintf buffer "\nfunc %s(teslText []byte) %s {\n" name go_ty;
    Printf.bprintf buffer
      "\tteslParsed, teslParseErr := teslrt.ParseJSON(teslText)\n\tif teslParseErr != nil {\n\t\tpanic(\"database: a %s column holds text that is not JSON: \" + teslParseErr.Error())\n\t}\n"
      info.adt_tesl_name;
    Printf.bprintf buffer
      "\tteslTag, teslTagErr := teslrt.DecodeStringField(teslParsed, \"tag\")\n\tif teslTagErr != nil {\n\t\tpanic(\"database: a %s column holds \" + teslTagErr.Error())\n\t}\n"
      info.adt_tesl_name;
    Buffer.add_string buffer "\tswitch teslTag {\n";
    List.iter (fun variant ->
      Printf.bprintf buffer "\tcase %s:\n\t\treturn %s{%s: %s}\n"
        (go_quote variant.var_ctor) go_ty adt_tag_field
        (qualified info.adt_owner variant.var_tag)) info.adt_variants;
    Printf.bprintf buffer
      "\t}\n\tpanic(\"database: a %s column holds an unknown tag \" + teslTag)\n}\n"
      info.adt_tesl_name;
    Hashtbl.replace pending_helpers name (Buffer.contents buffer)
  end;
  name

(* The scanner for one entity, hoisted to package level and emitted once: every statement that
   answers rows uses the same one, so the column ORDER a select asks for and the order the
   scanner reads can only be the same order. *)
and sql_scanner loc (info : entity_info) =
  let name = "teslScan" ^ go_ident ~exported:true info.ent_tesl_name in
  if not (Hashtbl.mem pending_helpers name) then begin
    let columns = entity_columns info in
    let row = sql_row_type info in
    let buffer = Buffer.create 256 in
    Printf.bprintf buffer "\nfunc %s(teslRow pgx.CollectableRow) (%s, error) {\n" name row;
    Printf.bprintf buffer "\tteslValue := %s{}\n" row;
    List.iteri (fun index (column : column_info) ->
      let carrier, _ = sql_scan_carrier loc column.col_type "" in
      Printf.bprintf buffer "\tvar teslColumn%d %s\n" index carrier) columns;
    Printf.bprintf buffer
      "\tif teslErr := teslRow.Scan(%s); teslErr != nil {\n\t\treturn teslValue, teslErr\n\t}\n"
      (String.concat ", "
         (List.mapi (fun index _ -> Printf.sprintf "&teslColumn%d" index) columns));
    List.iteri (fun index (column : column_info) ->
      let _, decode =
        sql_scan_carrier loc column.col_type (Printf.sprintf "teslColumn%d" index) in
      Printf.bprintf buffer "\tteslValue.%s = %s\n"
        (record_field_go_name column.col_field) decode) columns;
    Buffer.add_string buffer "\treturn teslValue, nil\n}\n";
    Hashtbl.replace pending_helpers name (Buffer.contents buffer)
  end;
  name

(* The reader for an AGGREGATE: one row, one column.  A sum answers the column's own type with
   `coalesce` supplying the zero; a max or min answers a `Maybe`, since SQL's aggregate over no
   rows is NULL where Tesl says Nothing. *)
and sql_scalar_scan loc ty ~optional =
  let name = Printf.sprintf "teslScan%s%s" (if optional then "Extreme" else "Total")
    (helper_suffix ty) in
  if not (Hashtbl.mem pending_helpers name) then begin
    let buffer = Buffer.create 256 in
    if optional then begin
      let carrier, decode = sql_scan_carrier loc ty "*teslFound" in
      Printf.bprintf buffer
        "\nfunc %s(teslRow pgx.Row) (teslrt.Maybe[%s], error) {\n\tvar teslFound *%s\n"
        name (go_type ty) carrier;
      Printf.bprintf buffer
        "\tif teslErr := teslRow.Scan(&teslFound); teslErr != nil {\n\t\treturn teslrt.Nothing[%s](), teslErr\n\t}\n"
        (go_type ty);
      Printf.bprintf buffer
        "\treturn teslrt.MaybeOfPointer(teslFound, func() %s { return %s }), nil\n}\n"
        (go_type ty) decode
    end else begin
      let carrier, decode = sql_scan_carrier loc ty "teslTotal" in
      Printf.bprintf buffer
        "\nfunc %s(teslRow pgx.Row) (%s, error) {\n\tvar teslTotal %s\n\tvar teslZero %s\n"
        name (go_type ty) carrier (go_type ty);
      Buffer.add_string buffer
        "\tif teslErr := teslRow.Scan(&teslTotal); teslErr != nil {\n\t\treturn teslZero, teslErr\n\t}\n";
      Printf.bprintf buffer "\treturn %s, nil\n}\n" decode
    end;
    Hashtbl.replace pending_helpers name (Buffer.contents buffer)
  end;
  name

(* The `where` fragment, in the same clause shapes the memory predicate supports — so a query
   this backend emits at all is emitted for BOTH stores, and one can never silently read rows
   the other would not. *)
and sql_where_text ?(joins=[]) ~indent signatures env loc (info : entity_info) binder clauses
    builder =
  let row_env = (binder, TRecord info.ent_row) :: env in
  let bind field expr =
    let ty = entity_column loc info field in
    let value = sql_column_value ~indent signatures row_env loc info field expr in
    sql_placeholder builder (sql_bound_value loc ty value)
  in
  let column field = sql_ident (sql_column_of loc info field).col_name in
  let compare_op field op expr =
    let symbol = match op with
      | BEq -> "=" | BNeq -> "<>" | BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">="
      | _ -> unsupported loc "Go backend does not support this operator in a `where` clause yet"
    in
    Printf.sprintf "%s %s %s" (column field) symbol (bind field expr)
  in
  let rec clause (c : Sql_query.sql_clause) =
    match c with
    | SqlPred { field; op; value } -> compare_op field op value
    | SqlOr parts ->
      (match List.map clause parts with
       | [] -> "false"
       | rendered -> "(" ^ String.concat " or " rendered ^ ")")
    | SqlIn { field; values } ->
      (match List.map (fun value -> compare_op field BEq value) values with
       | [] -> "false"
       | rendered -> "(" ^ String.concat " or " rendered ^ ")")
    | SqlNotIn { field; values } ->
      (match List.map (fun value -> compare_op field BNeq value) values with
       | [] -> "true"
       | rendered -> "(" ^ String.concat " and " rendered ^ ")")
    | SqlIsNull { field } -> unsupported loc
      "Go backend does not support `where isNull %s.%s` yet" binder field
    | SqlIsNotNull { field } -> unsupported loc
      "Go backend does not support `where isNotNull %s.%s` yet" binder field
    (* `like`/`ilike` are the SQL operators themselves; the memory store matches the same
       pattern by hand (`SqlLike`), which is what keeps the two answering alike. *)
    | SqlLike { field; pattern } ->
      Printf.sprintf "%s like %s" (column field)
        (sql_placeholder builder
           (emit_expr ~expected:TString ~indent signatures row_env pattern))
    | SqlILike { field; pattern } ->
      Printf.sprintf "%s ilike %s" (column field)
        (sql_placeholder builder
           (emit_expr ~expected:TString ~indent signatures row_env pattern))
  in
  match List.map clause clauses @ joins with
  | [] -> ""
  | rendered -> " where " ^ String.concat " and " rendered

and sql_order_text loc (info : entity_info) order =
  match order with
  | None -> ""
  | Some (field, direction) ->
    Printf.sprintf " order by %s %s" (sql_ident (sql_column_of loc info field).col_name)
      (if direction = "desc" then "DESC" else "ASC")

and sql_range_text limit offset =
  (match limit with Some count -> Printf.sprintf " limit %d" count | None -> "")
  ^ (match offset with Some count -> Printf.sprintf " offset %d" count | None -> "")

(* The column list a select asks for: the entity's own fields in declaration order, which is
   the order the scanner reads them in. *)
and sql_column_list (info : entity_info) =
  String.concat ", "
    (List.map (fun (column : column_info) -> sql_ident column.col_name) (entity_columns info))

(* The binder an INSERT hands the dispatcher: the arguments read off the row VALUE rather than
   emitted a second time from the same field expressions.  A row whose `createdAt` is
   `Time.nowMillis()` would otherwise be stored with one instant and answered with another. *)
and sql_row_binder loc indent (info : entity_info) columns =
  Printf.sprintf "func(teslRow %s) []any {\n%s\treturn []any{%s}\n%s}"
    (sql_row_type info) indent
    (String.concat ", "
       (List.map (fun (column : column_info) ->
          sql_bound_value loc column.col_type
            (Printf.sprintf "teslRow.%s" (record_field_go_name column.col_field)))
          columns))
    indent

(* The declared UNIQUE indexes an insert or an update carries, as `teslrt.UniqueIndex` values.
   The in-memory store enforces them (an index is an invariant, not a hint) and the server has
   the real index, so the emitted check runs only on the path that has no server.

   Emitted SPLIT across lines: gofmt keeps a composite literal on one line only while it fits,
   and one of these carries three func literals. *)
and sql_unique_indexes ~indent loc (info : entity_info) =
  let row = sql_row_type info in
  let inner = indent ^ "\t" in
  List.filter_map (fun (index : entity_index) ->
    if not index.ix_unique then None
    else begin
      let columns = List.map (fun field -> (sql_column_of loc info field).col_name)
        index.ix_fields in
      let same =
        String.concat " && " (List.map (fun field ->
          let ty = entity_column loc info field in
          let side name = Printf.sprintf "%s.%s" name (record_field_go_name field) in
          equal_expr ty (side "teslLeft") (side "teslRight")) index.ix_fields) in
      (* A row with a NULL in an indexed column is UNCONSTRAINED: two NULLs are not equal, so
         they do not collide.  PostgreSQL's rule, and Racket's. *)
      let nullable = List.filter (fun field ->
        maybe_element (entity_column loc info field) <> None) index.ix_fields in
      let constrained = match nullable with
        | [] -> "nil"
        | fields ->
          Printf.sprintf "func(teslRow %s) bool {\n%s\treturn %s\n%s}" row inner
            (String.concat " && " (List.map (fun field ->
               Printf.sprintf "teslRow.%s.IsSomething()" (record_field_go_name field)) fields))
            inner
      in
      (* The refusal names the VALUES that collided, so each is rendered the way an
         interpolation renders it — a column type with no rendering is refused rather than
         printed as a Go struct. *)
      let rec rendered ty operand =
        match ty with
        | TString -> operand
        | TInt -> operand ^ ".String()"
        | TFloat -> Printf.sprintf "teslrt.FormatFloat(%s)" operand
        | TBool -> Printf.sprintf "strconv.FormatBool(%s)" operand
        | TNewtype { secret = true; _ } -> unsupported loc
          "Go backend cannot put a `secret` column in a unique index on entity `%s`"
          info.ent_tesl_name
        | TNewtype newtype -> rendered newtype.base (operand ^ ".Value")
        | _ ->
          (match maybe_element ty with
           | Some inner -> rendered inner (operand ^ ".SomethingValue")
           | None -> unsupported loc
             "Go backend cannot name a `%s` column in a unique-index refusal" (go_type ty))
      in
      let describe =
        String.concat " + \" \" + " (List.map (fun field ->
          rendered (entity_column loc info field)
            (Printf.sprintf "teslRow.%s" (record_field_go_name field)))
          index.ix_fields) in
      Some (Printf.sprintf
        "teslrt.UniqueIndexOf(\n%s%s,\n%s[]string{%s},\n%s%s,\n%sfunc(teslLeft, teslRight %s) bool {\n%s\treturn %s\n%s},\n%sfunc(teslRow %s) string {\n%s\treturn \"(\" + %s + \")\"\n%s},\n%s)"
        inner (go_quote info.ent_tesl_name) inner
        (String.concat ", " (List.map go_quote columns)) inner constrained
        inner row inner same inner inner row inner describe inner indent)
    end) info.ent_indexes

(* `innerJoin E on main.f E.g` filters the MAIN entity's rows to those with a counterpart —
   the result is still a list of the main entity, so it is an EXISTENCE test rather than a
   product.  That is what `dsl/sql.rkt`'s memory store does
   (`in-memory-inner-join-matches?`), and it is the only reading a `List Order` can hold: a
   real join DUPLICATES a main row for every counterpart.

   Racket's own two backends disagree here — its Postgres path builds an `INNER JOIN`, which
   duplicates — so the two Go paths agree with each other and with the declared result type,
   and the divergence is recorded rather than reproduced. *)
and sql_join_predicate ~indent signatures loc (info : entity_info) binder (join : Sql_query.sql_join) =
  let joined = entity_of_query loc join.join_entity in
  let main_ty = entity_column loc info join.main_field in
  let join_ty = entity_column loc joined join.join_field in
  if type_unequal main_ty join_ty then unsupported loc
    "Go backend: `innerJoin %s on %s.%s %s.%s` compares columns of different types"
    join.join_entity binder join.main_field join.join_entity join.join_field;
  ignore signatures;
  Printf.sprintf "teslrt.TableAny(%s, func(teslJoined %s) bool {\n%s\treturn %s\n%s})"
    (sql_table_ref joined) (sql_row_type joined) indent
    (equal_expr join_ty
       (Printf.sprintf "teslJoined.%s" (record_field_go_name join.join_field))
       (Printf.sprintf "%s.%s" (local_ident binder) (record_field_go_name join.main_field)))
    indent

(* The same clause as SQL: `exists (select 1 from … where …)`, with both sides of the
   comparison table-qualified because the subquery sees the outer row's columns too. *)
and sql_join_exists loc (database : database_info) (info : entity_info)
    (join : Sql_query.sql_join) =
  let joined = entity_of_query loc join.join_entity in
  let main_column = (sql_column_of loc info join.main_field).col_name in
  let join_column = (sql_column_of loc joined join.join_field).col_name in
  Printf.sprintf "exists (select 1 from %s where %s.%s = %s.%s)"
    (sql_qualified_table database joined)
    (sql_qualified_table database joined) (sql_ident join_column)
    (sql_qualified_table database info) (sql_ident main_column)

(* The extra arguments a write carries when the entity declares a unique index: none at all
   when it declares none, so a program without one emits exactly what it always did. *)
and sql_unique_arguments ~indent loc (info : entity_info) =
  match sql_unique_indexes ~indent loc info with
  | [] -> ""
  | values -> ", " ^ String.concat ", " values

(* The emitted `teslrt.PgSql(…)`: one statement and a THUNK for the arguments its placeholders
   stand for.  A thunk because both forms of the query sit at this one call site but only one of
   them runs: an eager slice would evaluate a `where` operand that reads the clock, draws a
   random value or fails a check even on the memory path, where the memory-only emission never
   evaluates it.

   The thunk is emitted ALREADY SPLIT across lines.  gofmt keeps a func literal on one line only
   while go/printer judges it short enough, and an argument list crosses that threshold at a
   size the emitter cannot predict — but gofmt never JOINS a split literal, so the split form is
   stable at every size. *)
and sql_plan ~indent statement (builder : sql_arguments) =
  match builder.sql_args with
  | [] -> Printf.sprintf "teslrt.PgSql(%s, nil)" (go_quote statement)
  | args ->
    Printf.sprintf "teslrt.PgSql(%s, func() []any {\n%s\treturn []any{%s}\n%s})"
      (go_quote statement) indent (String.concat ", " args) indent

and emit_sql_form ?(indent="") signatures env loc form =
  match form with
  | SqlSelect (seed, clauses) ->
    let info = entity_of_query loc seed.entity in
    let all_clauses = seed.static_clauses @ clauses in
    sql_check_where_field loc seed.where_field all_clauses;
    (* `groupBy` belongs to the GROUPED aggregates and to nothing else: on a plain `select`
       it would silently change what the query answers. *)
    (match seed.group_by, seed.kind with
     | [], _ | _, (SelectCountBy | SelectSumBy _) -> ()
     | _ :: _, _ -> unsupported loc
       "Go backend supports `groupBy` only on `selectCountBy`/`selectSumBy`");
    (* One level deeper: the semi-join literal sits inside the predicate's own body, whose
       return line the `split` below writes at `indent + 1`. *)
    let join_predicates =
      List.map (sql_join_predicate ~indent:(indent ^ "\t") signatures loc info seed.binder)
        seed.joins in
    let predicate =
      emit_sql_predicate ~joins:join_predicates ~indent signatures env loc info seed.binder
        all_clauses in
    (* `order p.field asc|desc` becomes the STRICTLY-BEFORE comparison on that column;
       `desc` is the same comparison with its operands swapped, which keeps the sort
       stable in the direction Racket's ordering does. *)
    let ordering () = match seed.order with
      | None -> None
      | Some (field, direction) ->
        let ty = entity_column loc info field in
        if not (supports_column_ordering ty) then unsupported loc
          "Go backend cannot order by column `%s.%s`" info.ent_tesl_name field;
        let column name = Printf.sprintf "%s.%s" name (record_field_go_name field) in
        let left, right = match direction with
          | "desc" -> column "teslRight", column "teslLeft"
          | _ -> column "teslLeft", column "teslRight"
        in
        (* SPLIT rather than one line, for the reason the predicate is: gofmt keeps a func
           literal on one line only while it fits, and a comparator over a Bool column (which
           ranks each side) is already past that — so the split form is the stable one at every
           size. *)
        Some (Printf.sprintf "func(teslLeft, teslRight %s) bool {\n%s\treturn %s\n%s}"
                (sql_row_type info) indent (ordered_expr ty "<" left right) indent)
    in
    let range () =
      (* A missing `limit` is "every row", spelled as a negative count. *)
      Printf.sprintf "%d, %d" (Option.value seed.offset ~default:0)
        (Option.value seed.limit ~default:(-1))
    in
    let table = sql_table_ref info in
    (* The database this entity belongs to, when it is a Postgres-backed one: the query is then
       emitted in BOTH forms and the store is chosen at run time. *)
    let pg = info.ent_database in
    let where builder =
      let exists = match pg with
        | Some database -> List.map (sql_join_exists loc database info) seed.joins
        | None -> [] in
      sql_where_text ~joins:exists ~indent signatures env loc info seed.binder all_clauses
        builder in
    let db_ref (database : database_info) = qualified database.db_owner database.db_go_var in
    (match seed.kind with
     | SelectMany ->
       (match pg with
        | Some database ->
          let builder = { sql_args = [] } in
          let statement =
            Printf.sprintf "select %s from %s%s%s%s" (sql_column_list info)
              (sql_qualified_table database info) (where builder)
              (sql_order_text loc info seed.order) (sql_range_text seed.limit seed.offset) in
          Printf.sprintf "teslrt.DbSelect(%s, %s, %s, %s, %s, %s, %s)"
            (db_ref database) table predicate
            (match ordering () with None -> "nil" | Some less -> less)
            (range ()) (sql_plan ~indent statement builder) (sql_scanner loc info)
        | None ->
          (match ordering (), seed.limit, seed.offset with
           | None, None, None -> Printf.sprintf "teslrt.TableSelect(%s, %s)" table predicate
           | None, _, _ ->
             Printf.sprintf "teslrt.TableSelectRange(%s, %s, %s)" table predicate (range ())
           | Some less, _, _ ->
             Printf.sprintf "teslrt.TableSelectSorted(%s, %s, %s, %s)"
               table predicate less (range ())))
     | SelectOne ->
       (* `limit`/`offset` on a `selectOne` would change WHICH row it is, so they are
          refused rather than dropped; `order` decides it and is supported. *)
       if seed.limit <> None || seed.offset <> None then unsupported loc
         "Go backend does not support `limit`/`offset` on `selectOne` yet";
       (match pg with
        | Some database ->
          let builder = { sql_args = [] } in
          let statement =
            Printf.sprintf "select %s from %s%s%s limit 1" (sql_column_list info)
              (sql_qualified_table database info) (where builder)
              (sql_order_text loc info seed.order) in
          Printf.sprintf "teslrt.DbSelectOne(%s, %s, %s, %s, %s, %s)"
            (db_ref database) table predicate
            (match ordering () with None -> "nil" | Some less -> less)
            (sql_plan ~indent statement builder) (sql_scanner loc info)
        | None ->
          (match ordering () with
           | None -> Printf.sprintf "teslrt.TableSelectOne(%s, %s)" table predicate
           | Some less ->
             Printf.sprintf "teslrt.TableSelectOneSorted(%s, %s, %s)" table predicate less))
     | SelectCount ->
       if seed.order <> None || seed.limit <> None || seed.offset <> None then
         unsupported loc "Go backend does not support `order`/`limit`/`offset` on \
                          `selectCount` yet";
       (match pg with
        | Some database ->
          let builder = { sql_args = [] } in
          let statement =
            Printf.sprintf "select count(*) from %s%s"
              (sql_qualified_table database info) (where builder) in
          Printf.sprintf "teslrt.DbCount(%s, %s, %s, %s)"
            (db_ref database) table predicate (sql_plan ~indent statement builder)
        | None -> Printf.sprintf "teslrt.TableCount(%s, %s)" table predicate)
     | SelectSum field ->
       if seed.order <> None || seed.limit <> None || seed.offset <> None then
         unsupported loc "Go backend does not support `order`/`limit`/`offset` on \
                          `selectSum` yet";
       let ty = entity_column loc info field in
       let column = Printf.sprintf "teslRow.%s" (record_field_go_name field) in
       let project = Printf.sprintf "func(teslRow %s) %s { return %s }"
         (sql_row_type info) (go_type ty) column in
       (* The SUM is over the column's OWN type, so a newtype column sums to that
          newtype and a Float column to a Float — no unwrapping at the boundary. *)
       let fold_parts () = match ty with
         | TInt -> ("teslrt.Add", "teslrt.FromInt64(0)")
         | TFloat ->
           ("func(teslLeft, teslRight float64) float64 { return teslLeft + teslRight }",
            "float64(0)")
         | TNewtype newtype when newtype.base = TInt ->
           (Printf.sprintf
              "func(teslLeft, teslRight %s) %s { return %s{Value: teslrt.Add(teslLeft.Value, teslRight.Value)} }"
              (go_type ty) (go_type ty) (go_type ty),
            Printf.sprintf "%s{Value: teslrt.FromInt64(0)}" (go_type ty))
         | TNewtype newtype when newtype.base = TFloat ->
           (Printf.sprintf
              "func(teslLeft, teslRight %s) %s { return %s{Value: teslLeft.Value + teslRight.Value} }"
              (go_type ty) (go_type ty) (go_type ty),
            Printf.sprintf "%s{Value: float64(0)}" (go_type ty))
         | _ -> unsupported loc
           "Go backend cannot sum column `%s.%s`" info.ent_tesl_name field
       in
       (* A MONEY column cannot FOLD: the currency rule needs the whole set — an empty one has
          no currency to carry its zero, and two currencies have no common total — so it is one
          pass that adopts the currency from the first matching row and checks every later row
          against it.  Those are Racket's two refusals, word for word.  On a Postgres-backed
          entity a Money column stores into TWO columns, which `entity_columns` refuses above. *)
       (match ty, pg with
        | TRecord money, _ when money.rec_tesl_name = "Money" ->
          Printf.sprintf "teslrt.TableSumMoney(%s, %s, %s, %s, %s)"
            table predicate project (go_quote info.ent_tesl_name) (go_quote field)
        | _, None ->
          let combine, zero = fold_parts () in
          Printf.sprintf "teslrt.TableFold(%s, %s, %s, %s, %s)"
            table predicate project combine zero
        | _, Some database ->
          (* The server sums in the database rather than shipping every row here to be added
             up; `coalesce(…, 0)` is what makes a sum over no rows zero on both paths. *)
          let combine, zero = fold_parts () in
          let builder = { sql_args = [] } in
          let statement =
            Printf.sprintf "select coalesce(sum(%s), 0) from %s%s"
              (sql_ident (sql_column_of loc info field).col_name)
              (sql_qualified_table database info) (where builder) in
          Printf.sprintf "teslrt.DbSum(%s, %s, %s, %s, %s, %s, %s, %s)"
            (db_ref database) table predicate project combine zero
            (sql_plan ~indent statement builder) (sql_scalar_scan loc ty ~optional:false))
     (* `selectMax`/`selectMin` answer a `Maybe`: no matching row is `Nothing`, not a trap
        and not a fabricated zero. *)
     | SelectMax field | SelectMin field ->
       if seed.order <> None || seed.limit <> None || seed.offset <> None then
         unsupported loc "Go backend does not support `order`/`limit`/`offset` on \
                          `selectMax`/`selectMin` yet";
       let biggest = match seed.kind with SelectMax _ -> true | _ -> false in
       let ty = entity_column loc info field in
       if not (supports_column_ordering ty) then unsupported loc
         "Go backend cannot compare column `%s.%s`" info.ent_tesl_name field;
       let project = Printf.sprintf "func(teslRow %s) %s { return teslRow.%s }"
         (sql_row_type info) (go_type ty) (record_field_go_name field) in
       (* Split, like the other comparators: a one-line func literal is gofmt-stable only
          while it fits, and this one sits at the end of a four-argument call. *)
       let better =
         Printf.sprintf "func(teslLeft, teslRight %s) bool {\n%s\treturn %s\n%s}" (go_type ty)
           indent (ordered_expr ty (if biggest then ">" else "<") "teslLeft" "teslRight")
           indent in
       (match pg with
        | Some database ->
          let builder = { sql_args = [] } in
          let statement =
            Printf.sprintf "select %s(%s) from %s%s" (if biggest then "max" else "min")
              (sql_ident (sql_column_of loc info field).col_name)
              (sql_qualified_table database info) (where builder) in
          Printf.sprintf "teslrt.DbExtreme(%s, %s, %s, %s, %s, %s, %s)"
            (db_ref database) table predicate project better
            (sql_plan ~indent statement builder) (sql_scalar_scan loc ty ~optional:true)
        | None ->
          Printf.sprintf "teslrt.TableExtreme(%s, %s, %s, %s)"
            table predicate project better)
     (* ── The GROUPED aggregates ────────────────────────────────────────────
        One (bucket, value) pair per group, ORDERED BY KEY ASCENDING — which is the contract
        rather than an accident of iteration: the Racket memory backend sorts its buckets and
        PostgreSQL's `GROUP BY … ORDER BY 1` does the same, and a series a chart draws is
        only a series if its points are in order.

        The bucket key is either a plain column or one of the five `Time.trunc*` calendar
        buckets, and the truncation goes through the SAME engine the surface functions call,
        so `Time.truncDay zone e.startedAt` as a group key and as an expression cannot
        disagree about where a day starts. *)
     | SelectCountBy | SelectSumBy _ ->
       if seed.order <> None || seed.limit <> None || seed.offset <> None then
         unsupported loc "Go backend does not support `order`/`limit`/`offset` on a \
                          grouped aggregate yet";
       let key_field = match seed.group_by with
         | [GField field] | [GTimeTrunc (_, _, field)] -> field
         | [] -> unsupported loc "Go backend requires `groupBy` on a grouped aggregate"
         | _ -> unsupported loc
           "Go backend does not support `groupBy` on more than one key yet"
       in
       let key_ty = entity_column loc info key_field in
       if not (supports_column_ordering key_ty) then unsupported loc
         "Go backend cannot group by column `%s.%s`" info.ent_tesl_name key_field;
       let column = Printf.sprintf "teslRow.%s" (record_field_go_name key_field) in
       let key_of_row = match seed.group_by with
         | [GTimeTrunc (unit, zone, _)] ->
           let unit = String.capitalize_ascii unit in
           Printf.sprintf "teslrt.TimeTrunc%s(%s, %s)" unit
             (emit_expr ~indent signatures env zone) column
         | _ -> column
       in
       (* Split across lines, like every other func literal the emitter writes into a long
          argument list: gofmt keeps a one-line literal only while go/printer judges it short
          enough, and it never JOINS a split one — so the split form is stable at every
          size, and this call takes seven arguments. *)
       let key = Printf.sprintf "func(teslRow %s) %s {\n%s\treturn %s\n%s}"
         (sql_row_type info) (go_type key_ty) indent key_of_row indent in
       let less =
         Printf.sprintf "func(teslLeft, teslRight %s) bool {\n%s\treturn %s\n%s}"
           (go_type key_ty) indent (ordered_expr key_ty "<" "teslLeft" "teslRight") indent in
       let equal =
         Printf.sprintf "func(teslLeft, teslRight %s) bool {\n%s\treturn %s\n%s}"
           (go_type key_ty) indent (equal_expr key_ty "teslLeft" "teslRight") indent in
       let value_ty, step, zero = match seed.kind with
         | SelectSumBy field ->
           let ty = entity_column loc info field in
           let cell = Printf.sprintf "teslRow.%s" (record_field_go_name field) in
           let row = sql_row_type info in
           (match ty with
            | TInt ->
              ty,
              Printf.sprintf
                "func(teslTotal teslrt.Int, teslRow %s) teslrt.Int {\n%s\treturn teslrt.Add(teslTotal, %s)\n%s}"
                row indent cell indent,
              "teslrt.FromInt64(0)"
            | TFloat ->
              ty,
              Printf.sprintf
                "func(teslTotal float64, teslRow %s) float64 {\n%s\treturn teslTotal + %s\n%s}"
                row indent cell indent,
              "float64(0)"
            | TNewtype newtype when newtype.base = TInt ->
              ty,
              Printf.sprintf
                "func(teslTotal %s, teslRow %s) %s {\n%s\treturn %s{Value: teslrt.Add(teslTotal.Value, %s.Value)}\n%s}"
                (go_type ty) row (go_type ty) indent (go_type ty) cell indent,
              Printf.sprintf "%s{Value: teslrt.FromInt64(0)}" (go_type ty)
            | TNewtype newtype when newtype.base = TFloat ->
              ty,
              Printf.sprintf
                "func(teslTotal %s, teslRow %s) %s {\n%s\treturn %s{Value: teslTotal.Value + %s.Value}\n%s}"
                (go_type ty) row (go_type ty) indent (go_type ty) cell indent,
              Printf.sprintf "%s{Value: float64(0)}" (go_type ty)
            (* A Money column has no fold: an empty group has no currency to carry its zero,
               and the whole-set rule the scalar `selectSum` applies has no per-group form
               here.  Refused rather than summed in some currency the rows did not agree on. *)
            | _ -> unsupported loc
              "Go backend cannot sum column `%s.%s` in a grouped aggregate"
              info.ent_tesl_name field)
         (* A COUNT does not read the row, so the parameter is `_` rather than a name and a
            discard — the same count, with nothing to explain. *)
         | _ ->
           TInt,
           Printf.sprintf
             "func(teslTotal teslrt.Int, _ %s) teslrt.Int {\n%s\treturn teslrt.Add(teslTotal, teslrt.FromInt64(1))\n%s}"
             (sql_row_type info) indent indent,
           "teslrt.FromInt64(0)"
       in
       ignore value_ty;
       (match pg with
        | Some _ -> unsupported loc
          "Go backend does not support a grouped aggregate on a PostgreSQL-backed database yet"
        | None ->
          Printf.sprintf "teslrt.TableGroupFold(%s, %s, %s, %s, %s, %s, %s)"
            table predicate key less equal step zero))
  | SqlInsert insert ->
    let info = entity_of_query loc insert.entity in
    check_record_literal signatures env loc info.ent_row insert.fields;
    let row = emit_record_literal ~indent signatures env info.ent_row insert.fields in
    (match info.ent_database with
     | None ->
       Printf.sprintf "teslrt.TableInsert(%s, %s, %s, %s%s)"
         (sql_table_ref info) (go_quote info.ent_tesl_name) row (sql_key_conflict loc info)
         (sql_unique_arguments ~indent loc info)
     | Some database ->
       (* Each column is bound from the literal's OWN field expression rather than by reading
          it back out of the emitted struct: the two are the same value, and reading it back
          would mean naming a temporary the memory path has no use for.  The DUPLICATE-key
          refusal is the server's here (the primary key carries the constraint) and the
          emitted comparison there, which is what keeps the two backends agreeing about which
          programs run rather than only about what they answer. *)
       let columns = entity_columns info in
       List.iter (fun (column : column_info) ->
         if not (List.mem_assoc column.col_field insert.fields) then unsupported loc
           "Go backend: `insert` into `%s` leaves column `%s` unset"
           info.ent_tesl_name column.col_field) columns;
       let statement =
         Printf.sprintf "insert into %s (%s) values (%s)"
           (sql_qualified_table database info) (sql_column_list info)
           (String.concat ", "
              (List.mapi (fun index _ -> Printf.sprintf "$%d" (index + 1)) columns)) in
       Printf.sprintf "teslrt.DbInsert(%s, %s, %s, %s, %s, %s, %s%s)"
         (qualified database.db_owner database.db_go_var) (sql_table_ref info)
         (go_quote info.ent_tesl_name) row (sql_key_conflict loc info)
         (go_quote statement) (sql_row_binder loc indent info columns)
         (sql_unique_arguments ~indent loc info))
  (* ── `upsert … onConflict [c] doUpdate [u]` ──────────────────────────────
     Insert the row, unless one already matches on the CONFLICT columns — in which case only
     the UPDATE columns of that row are overwritten.  The conflict target is a unique index
     rather than necessarily the primary key, which is why the match is its own comparison
     and not `sql_key_conflict`. *)
  | SqlUpsert upsert ->
    let info = entity_of_query loc upsert.entity in
    check_record_literal signatures env loc info.ent_row upsert.fields;
    let row_type = sql_row_type info in
    let row = emit_record_literal ~indent signatures env info.ent_row upsert.fields in
    let column_field name =
      (* The field must be a real column: an `onConflict` naming something the entity does
         not have would compare nothing and upsert every row. *)
      ignore (entity_column loc info name);
      record_field_go_name name
    in
    if upsert.conflict = [] then unsupported loc
      "Go backend requires `upsert` to name its `onConflict` columns";
    let matches =
      Printf.sprintf "func(teslExisting, teslRow %s) bool {\n%s\treturn %s\n%s}"
        row_type indent
        (String.concat " && " (List.map (fun field ->
           let ty = entity_column loc info field in
           let side name = Printf.sprintf "%s.%s" name (column_field field) in
           equal_expr ty (side "teslExisting") (side "teslRow")) upsert.conflict))
        indent in
    (* The merged row is the EXISTING one with the update columns taken from the new one:
       every other column keeps what was stored, which is what makes an upsert different
       from an insert that replaces. *)
    let merge =
      let assignments = List.map (fun field ->
        ignore (entity_column loc info field);
        Printf.sprintf "%s\tteslMerged.%s = teslRow.%s" indent
          (column_field field) (column_field field)) upsert.do_update in
      Printf.sprintf "func(teslExisting, teslRow %s) %s {\n%s\tteslMerged := teslExisting\n%s\n%s\treturn teslMerged\n%s}"
        row_type row_type indent
        (if assignments = [] then Printf.sprintf "%s\t_ = teslRow" indent
         else String.concat "\n" assignments)
        indent indent in
    (match info.ent_database with
     | None ->
       (* The stored row is discarded here for the reason the typing gives: the form answers
          Unit, and `teslrt.Discard` is how a value-returning runtime call reaches a
          Unit-typed position without a statement. *)
       Printf.sprintf "teslrt.Discard(teslrt.TableUpsert(%s, %s, %s, %s, %s, %s%s))"
         (sql_table_ref info) (go_quote info.ent_tesl_name) row matches merge
         (sql_key_conflict loc info) (sql_unique_arguments ~indent loc info)
     | Some _ -> unsupported loc
       "Go backend does not support `upsert` on a PostgreSQL-backed database yet")
  | SqlInsertMany (list_var, entity) ->
    let info = entity_of_query loc entity in
    let rows = match List.assoc_opt list_var env with
      | Some (TList (TRecord row)) when row == info.ent_row -> local_ident list_var
      | Some _ -> unsupported loc
        "Go backend: `insertMany %s in %s` needs a list of `%s` rows"
        list_var entity entity
      | None -> unsupported loc "Go backend cannot resolve value `%s`" list_var
    in
    (match info.ent_database with
     | None ->
       Printf.sprintf "teslrt.TableInsertMany(%s, %s, %s, %s%s)"
         (sql_table_ref info) (go_quote info.ent_tesl_name) rows (sql_key_conflict loc info)
         (sql_unique_arguments ~indent loc info)
     | Some database ->
       (* The rows are only known at run time, so the statement is fixed and its ARGUMENTS are
          read off each row — the one query whose plan cannot be a value.  One statement per
          row rather than a multi-row VALUES list, so a row conflicting with an EARLIER row of
          the same batch is refused exactly where it would be if the two had been inserted
          separately: Racket's `insert-many!` is a loop over `insert-one!`. *)
       let columns = entity_columns info in
       let statement =
         Printf.sprintf "insert into %s (%s) values (%s)"
           (sql_qualified_table database info) (sql_column_list info)
           (String.concat ", "
              (List.mapi (fun index _ -> Printf.sprintf "$%d" (index + 1)) columns)) in
       let bind = sql_row_binder loc indent info columns in
       Printf.sprintf "teslrt.DbInsertMany(%s, %s, %s, %s, %s, %s, %s%s)"
         (qualified database.db_owner database.db_go_var) (sql_table_ref info)
         (go_quote info.ent_tesl_name) rows (sql_key_conflict loc info)
         (go_quote statement) bind (sql_unique_arguments ~indent loc info))
  | SqlUpdate update ->
    let info = entity_of_query loc update.entity in
    sql_check_where_field loc None update.clauses;
    let row_env = (update.binder, TRecord info.ent_row) :: env in
    let predicate =
      emit_sql_predicate ~indent signatures env loc info update.binder update.clauses in
    let inner = indent ^ "\t" in
    let assignments = List.map (fun (field, value) ->
      Printf.sprintf "%steslNext.%s = %s\n" inner (record_field_go_name field)
        (sql_column_value ~indent:inner signatures row_env loc info field value))
      update.updates in
    (* Every `set` value reads the row as it was: SQL evaluates the whole SET list
       against the old row, so assigning into a COPY is the parity-preserving shape —
       assigning in place would let one `set` feed the next. *)
    let apply =
      Printf.sprintf "func(%s %s) %s {\n%steslNext := %s\n%s%sreturn teslNext\n%s}"
        (local_ident update.binder) (sql_row_type info) (sql_row_type info)
        inner (local_ident update.binder)
        (String.concat "" assignments) inner indent
    in
    (match info.ent_database with
     | None ->
       Printf.sprintf "teslrt.%s(%s, %s, %s%s)"
         (if update.returning_one then "TableUpdateReturnOne" else "TableUpdate")
         (sql_table_ref info) predicate apply (sql_unique_arguments ~indent loc info)
     | Some database ->
       (* A `set` value is a PARAMETER on the server: `set p.count = p.count + 1` would have to
          become SQL arithmetic over the stored column, and Racket's Postgres path cannot do
          that either (`postgres-update-many!` binds every SET value).  So a value that reads
          the row is refused rather than silently evaluated against a row this side never
          fetched. *)
       let builder = { sql_args = [] } in
       let assignment (field, value) =
         if mentions_variable update.binder value then unsupported loc
           "Go backend does not support a `set` value that reads the row (`%s.%s`) on a \
            Postgres-backed database yet" update.binder field;
         let column = sql_column_of loc info field in
         let bound =
           sql_column_value ~indent signatures env loc info field value in
         Printf.sprintf "%s = %s" (sql_ident column.col_name)
           (sql_placeholder builder (sql_bound_value loc column.col_type bound))
       in
       let sets = String.concat ", " (List.map assignment update.updates) in
       let where =
         sql_where_text ~indent signatures env loc info update.binder update.clauses builder in
       if update.returning_one then
         let statement =
           Printf.sprintf "update %s set %s%s returning %s"
             (sql_qualified_table database info) sets where (sql_column_list info) in
         Printf.sprintf "teslrt.DbUpdateReturnOne(%s, %s, %s, %s, %s, %s%s)"
           (qualified database.db_owner database.db_go_var) (sql_table_ref info) predicate
           apply (sql_plan ~indent statement builder) (sql_scanner loc info)
           (sql_unique_arguments ~indent loc info)
       else
         let statement =
           Printf.sprintf "update %s set %s%s" (sql_qualified_table database info) sets where in
         Printf.sprintf "teslrt.DbUpdate(%s, %s, %s, %s, %s%s)"
           (qualified database.db_owner database.db_go_var) (sql_table_ref info) predicate
           apply (sql_plan ~indent statement builder) (sql_unique_arguments ~indent loc info))
  | SqlDelete (seed, clauses) ->
    let info = entity_of_query loc seed.entity in
    sql_check_where_field loc seed.where_field clauses;
    let predicate = emit_sql_predicate ~indent signatures env loc info seed.binder clauses in
    (* `delete` is a statement; `deleteAndReturnResult` answers whether anything WENT, which is
       a different outcome from a count of zero and is read as a `case` rather than compared. *)
    let memory = if seed.with_result then "TableDeleteResult" else "TableDelete" in
    let server = if seed.with_result then "DbDeleteResult" else "DbDelete" in
    (match info.ent_database with
     | None -> Printf.sprintf "teslrt.%s(%s, %s)" memory (sql_table_ref info) predicate
     | Some database ->
       let builder = { sql_args = [] } in
       let statement =
         Printf.sprintf "delete from %s%s" (sql_qualified_table database info)
           (sql_where_text ~indent signatures env loc info seed.binder clauses builder) in
       Printf.sprintf "teslrt.%s(%s, %s, %s, %s)" server
         (qualified database.db_owner database.db_go_var) (sql_table_ref info) predicate
         (sql_plan ~indent statement builder))

(* An api-test request BODY is a JSON template: `body { "tag": "one" }`.  It is rendered to
   the JSON text the request carries.  A literal template becomes a constant string at
   compile time; a value spliced from the test's own bindings is encoded at run time through
   the runtime's JSON writer, so the two cannot disagree about escaping. *)
(* The password plaintext is the one argument whose RUNTIME type differs from its Tesl type:
   `hashPassword`/`checkPassword` take a `teslrt.SecretString`, while Tesl types the parameter as
   String and a program normally holds the value as a `secret Password = String`.  Racket's
   `raw-str` unwraps any newtype there, so both shapes are accepted — and the conversion lives
   HERE, in one function every emitting path calls, rather than being repeated at each call site
   (the emit_elm lesson: a wrap rule copied four times is a rule that drifts three ways).
   The plaintext never appears as a bare string in emitted code: a secret newtype hands over its
   own `SecretString`, and anything else is wrapped on the way in. *)
and emit_leaf_argument ?(indent="") signatures env name want arg =
  (* Matched on EITHER spelling — the Tesl name at a direct call, the Go name where the emitter
     only has the resolved signature (the delegation paths). *)
  let password_plaintext =
    List.mem name
      [ "Crypto.hashPassword"; "Crypto.checkPassword";
        "teslrt.HashPassword"; "teslrt.CheckPassword" ]
    && want = TString
  in
  (* An untyped api-test value handed to a String parameter reads as the string it holds;
     see the matching rule in `type_of_arg`. *)
  let json_as_string =
    want = TString
    && (match typed_with_default (type_of_expr signatures env) arg with
        | Some TJson, _ -> true
        | _ -> false)
  in
  if json_as_string then
    Printf.sprintf "teslrt.JsonAsString(%s)" (emit_expr ~indent signatures env arg)
  else if not password_plaintext then emit_expr ~expected:want ~indent signatures env arg
  else
    let emitted = emit_expr ~indent signatures env arg in
    match type_of_expr signatures env arg with
    | TNewtype info when info.secret -> Printf.sprintf "%s.Value" (selector_operand emitted)
    | TNewtype _ -> Printf.sprintf "teslrt.MakeSecret(%s.Value)" (selector_operand emitted)
    | _ -> Printf.sprintf "teslrt.MakeSecret(%s)" emitted

(* Does this template hold a string that INTERPOLATES?  Only asked inside an api-test, where a
   `{…}` slot in a string literal is a substitution rather than the two characters. *)
and api_test_interpolates value =
  !current_api_server <> None
  && (match value with
      | ELit { lit = LString text; _ } ->
        List.exists (function
          | Emit_racket.ApiTestTemplateExpr _ -> true
          | Emit_racket.ApiTestTemplateLiteral _ -> false)
          (Emit_racket.parse_api_test_template_content text)
      | ERecord { fields; _ } ->
        List.exists (fun (_, field_value) -> api_test_interpolates field_value) fields
      | EList { elems; _ } -> List.exists api_test_interpolates elems
      | _ -> false)

(* An api-test STRING is a template: `cookie "chatUserId={userId}"` and `post "/rooms/{roomId}"`
   substitute the block's bindings, which is what `emit_racket` does through
   `api-test-string-fragment`.  The SPLIT is shared with that emitter rather than reproduced —
   a rule for what counts as an interpolation, written twice, is a rule that drifts, and its
   corner cases (`"{}"`, `"{\"id\": 1}"`, an unbalanced quote) are exactly where it would.

   Outside an api-test block a string literal is itself; nothing here is reached from ordinary
   code. *)
and emit_api_test_string ?(indent="") signatures env value =
  match value with
  | ELit { lit = LString text; _ } when !current_api_server <> None ->
    let parts = Emit_racket.parse_api_test_template_content text in
    let interpolates = List.exists (function
      | Emit_racket.ApiTestTemplateExpr _ -> true
      | Emit_racket.ApiTestTemplateLiteral _ -> false) parts in
    if not interpolates then emit_expr ~expected:TString ~indent signatures env value
    else
      let rendered = List.map (function
        | Emit_racket.ApiTestTemplateLiteral literal -> go_quote literal
        | Emit_racket.ApiTestTemplateExpr slot ->
          let ty = type_of_expr signatures env slot in
          let encoded = match ty with
            (* An untyped JSON handle hands over the value it holds; anything else goes
               through its own encoder, which is the shape the Racket walk produces. *)
            | TJson -> Printf.sprintf "%s.JsonRaw()"
                         (selector_operand (emit_expr ~indent signatures env slot))
            | _ -> Printf.sprintf "%s(%s)" (!value_encoder_hook ty)
                     (emit_expr ~expected:ty ~indent signatures env slot)
          in
          Printf.sprintf "teslrt.ApiTestFragment(%s)" encoded) parts in
      (match rendered with
       | [single] -> single
       | many -> "(" ^ String.concat " + " many ^ ")")
  | _ -> emit_expr ~expected:TString ~indent signatures env value

(* A JSON template, as the Go expression producing its TEXT.  A template whose values are all
   literals is that text, computed here; one that SPLICES a binding
   (`{ "id": roomId, "name": roomName }`) is built at run time through the same encoder a
   response body goes through, so a test and the code under test cannot disagree about how a
   value is written. *)
and emit_json_template ?(indent="") signatures env value =
  (* The constant shortcut is skipped when a string inside the template INTERPOLATES: the
     template is then not a constant, whatever `literal_json` makes of its spelling. *)
  match (if api_test_interpolates value then None else literal_json value) with
  | Some json -> Some (go_quote json)
  | None ->
    (match value with
     | ERecord _ ->
       Some (Printf.sprintf "teslrt.EncodeJSON(%s)"
               (json_template_object ~indent signatures env value))
     | _ -> None)

(* One VALUE inside a template, in the shape the encoder takes.  A nested object or array
   recurses — `{ "fields": { "roomName": roomId } }` is one template, not an object holding a
   Tesl record — and anything else goes through its own type's encoder, which is the encoder a
   response body would use for it. *)
and json_template_value ?(indent="") signatures env value =
  match value with
  (* A string INSIDE a body template interpolates too: `body { "content": "hello {name}" }`. *)
  | ELit { lit = LString _; _ } when !current_api_server <> None ->
    emit_api_test_string ~indent signatures env value
  | ERecord _ -> json_template_object ~indent signatures env value
  | EList { elems; _ } ->
    Printf.sprintf "[]any{%s}"
      (String.concat ", "
         (List.map (json_template_value ~indent signatures env) elems))
  | _ ->
    let ty = type_of_expr signatures env value in
    Printf.sprintf "%s(%s)" (!value_encoder_hook ty)
      (emit_expr ~expected:ty ~indent signatures env value)

and json_template_object ?(indent="") signatures env value =
  match value with
  | ERecord { fields; _ } ->
    Printf.sprintf "map[string]any{%s}"
      (String.concat ", "
         (List.map (fun (key, field_value) ->
            Printf.sprintf "%s: %s" (go_quote key)
              (json_template_value ~indent signatures env field_value)) fields))
  | _ -> invalid_arg "json template object validated before emission"

and emit_api_test_body ?(indent="") signatures env value =
  match emit_json_template ~indent signatures env value with
  | Some rendered -> rendered
  | None ->
    (* Not a template at all: a String expression is sent as-is (it IS the body), and
       anything else fails closed rather than being guessed at. *)
    if type_of_expr signatures env value = TString then
      emit_expr ~expected:TString ~indent signatures env value
    else
      unsupported (Checker.expr_loc value)
        "Go backend api-test body must be a JSON template or a String"

and emit_interp ?(indent="") signatures env segments =
  let parts = List.map (function
    | ILiteral value -> go_quote value
    | IExpr expr ->
      let emitted = emit_expr ~indent signatures env expr in
      match type_of_expr signatures env expr with
      | TString -> emitted
      | TInt -> emitted ^ ".String()"
      | TFloat -> Printf.sprintf "teslrt.FormatFloat(%s)" emitted
      | TBool -> Printf.sprintf "strconv.FormatBool(%s)" emitted
      | _ -> unsupported (Checker.expr_loc expr)
        "Go backend interpolation supports String, Int, Float, and Bool only") segments in
  match parts with
  | [] -> go_quote ""
  | [part] -> part
  | _ -> "(" ^ String.concat " + " parts ^ ")"

and emit_if_expr ?expected ?(indent="") signatures env expr =
  match expr with
  | EIf { cond; then_; else_; _ } ->
    let inferred = type_of_expr signatures env expr in
    let result = match inferred, expected with
      | TFailure, Some expected -> expected
      | _ -> inferred
    in
    Printf.sprintf "teslrt.If(%s, func() %s {\n%s\treturn %s\n%s}, func() %s {\n%s\treturn %s\n%s})"
      (emit_expr ~indent signatures env cond)
      (go_type result)
      indent (emit_expr ~expected:result ~indent:(indent ^ "\t") signatures env then_) indent
      (go_type result)
      indent (emit_expr ~expected:result ~indent:(indent ^ "\t") signatures env else_) indent
  | _ -> invalid_arg "emit_if_expr requires EIf"

and emit_let_expr ?expected ?(indent="") signatures env expr =
  let inferred = type_of_expr signatures env expr in
  let result = match inferred, expected with
    | TFailure, Some expected -> expected
    | _ -> inferred
  in
  let buffer = Buffer.create 192 in
  Printf.bprintf buffer "(func() %s {\n" (go_type result);
  let rec emit_bindings env = function
    (* `let (v ::: pf) = y`: the value binding is `y` itself and the proof binder is the
       zero-size proof value.  Both are emitted, because later code names both. *)
    | ELetProof { value_name; proof_name; value; body; _ } ->
      let value_ty = type_of_expr signatures env value in
      let emitted =
        emit_expr ~expected:value_ty ~indent:(indent ^ "\t") signatures env value in
      Printf.bprintf buffer "%s\t%s := %s\n%s\t_ = %s\n" indent (local_ident value_name)
        emitted indent (local_ident value_name);
      Printf.bprintf buffer "%s\t%s := struct{}{}\n%s\t_ = %s\n" indent
        (local_ident proof_name) indent (local_ident proof_name);
      emit_bindings ((proof_name, TUnit) :: (value_name, value_ty) :: env) body
    | ELet { name; value; body; _ } ->
      let inferred_value_ty = type_of_expr signatures env value in
      let value_ty = if inferred_value_ty = TFailure then result else inferred_value_ty in
      let emitted =
        emit_expr ~expected:value_ty ~indent:(indent ^ "\t") signatures env value in
      (* `let _ = expr` is written for its EFFECT and discards the value; `_ := expr` is
         not legal Go, so it becomes a plain discard (as in the statement emitter). *)
      if name = "_" then Printf.bprintf buffer "%s\t_ = %s\n" indent emitted
      else begin
        let go_name = local_ident name in
        Printf.bprintf buffer "%s\t%s := %s\n%s\t_ = %s\n" indent go_name emitted indent go_name
      end;
      emit_bindings ((name, value_ty) :: env) body
    | body ->
      Printf.bprintf buffer "%s\treturn %s\n" indent
        (emit_expr ~expected:result ~indent:(indent ^ "\t") signatures env body)
  in
  emit_bindings env expr;
  Printf.bprintf buffer "%s}())" indent;
  Buffer.contents buffer

let loop_label = "teslLoop"

(* A Tesl self tail call is a loop, not a stack frame.  Racket has TCO, Go does not,
   and Go's stack overflow is a FATAL error that `recover` cannot catch — so a deep
   tail-recursive program that merely runs on Racket would kill the process here.
   Only a call in tail position to the enclosing function, with the whole parameter
   list supplied and the name not shadowed by a local, qualifies. *)
let self_tail_call_args signatures env ~name ~arity expr =
  let resolves_to_self called =
    called = name && not (List.mem_assoc called env)
  in
  match expr with
  | EVar { name = called; _ } when arity = 0 && resolves_to_self called -> Some []
  | EApp _ ->
    let head, args = flatten_app [] expr in
    (match head with
     | EVar { name = called; _ } when resolves_to_self called ->
       let signature = Hashtbl.find_opt signatures called in
       let args = match signature with
         | Some { params; _ } -> normalize_call_args params args
         | None -> args
       in
       if List.length args = arity then Some args else None
     | _ -> None)
  | _ -> None

(* A `check` whose declared return is a plain VALUE — `-> Maybe (v: T ::: P v)` — has a body
   that IS that value: the proof rides inside the `Something`, so there is no `ok` to write.
   The tail is then an ACCEPTANCE and has to say so; emitting the bare value where the Go
   signature says `Check[T]` produced a package that did not compile, which is how this was
   found.  Answers the value type when the tail is one, so the branches are also EMITTED
   against it — which is what lets a bare `Nothing` in one of them find its element.

   `ok` and `fail` say what they are, and a tail that delegates to another check hands back
   that check's own result, so neither is an acceptance. *)
(* A `let` whose value DELEGATES to a check, in either spelling: `check g x` and
   `check (a && b) x`.  Answers the Go expression producing that `Check` and the type it
   carries, so a check body can PROPAGATE the rejection rather than trap on it.

   The combined spelling used to be missing here, which mattered only once a check whose
   declared return is a plain value could emit at all: `let validated = check (a && b) n`
   inside a check then trapped on a rejection where the single-check form propagated. *)
let delegated_check_call ~indent signatures env value =
  match check_application signatures value with
  | Some (signature, args) ->
    let inner = match signature.result with TCheck inner -> inner | ty -> ty in
    (* Runs the ordinary check-call validation (arity, argument types) — the same one the
       non-propagating path gets — so this branch cannot accept a call the other rejects. *)
    ignore (type_of_expr signatures env value);
    Some (Printf.sprintf "%s(%s)"
            (qualified signature.sig_owner signature.go_name)
            (String.concat ", " (List.map2
               (fun want arg ->
                  emit_leaf_argument ~indent signatures env signature.go_name want arg)
               signature.params args)),
          inner)
  | None ->
    (match flatten_app [] value with
     | EVar { name = "check"; _ }, [conjunction; argument] ->
       (match check_conjunct_calls conjunction with
        | Some (_ :: _ :: _ as calls) ->
          let inner = type_of_expr signatures env value in
          let captured = List.map (fun (name, supplied) ->
            let leading = match Hashtbl.find_opt signatures name with
              | Some signature ->
                List.filteri (fun index _ -> index < List.length supplied) signature.params
              | None -> List.map (fun _ -> inner) supplied
            in
            name, leading, List.combine supplied leading) calls in
          let capture_arguments = List.concat_map (fun (_, _, pairs) ->
            List.map (fun (capture, want) ->
              emit_expr ~expected:want ~indent signatures env capture) pairs) captured in
          Some (Printf.sprintf "%s(%s)"
                  (combined_check_helper signatures inner
                     (List.map (fun (name, leading, _) -> name, leading) captured))
                  (String.concat ", "
                     (emit_expr ~expected:inner ~indent signatures env argument
                      :: capture_arguments)),
                inner)
        | _ -> None)
     | _ -> None)

(* What a LATER use says a `let` binding must hold.
   `let raw = Dict.fromList []` carries no key or value type of its own, and the next line —
   `getVerifiedScores raw` — is what says what it is.  One step and no more: the binding's
   own expression is always preferred, and this is consulted only when that expression could
   not type by itself.  Anything a single use cannot settle stays refused rather than
   guessed at. *)
let expected_from_use signatures name exprs =
  let found = ref None in
  List.iter (fun expr ->
    Ast_visitor.iter (fun node ->
      if !found = None then
        match flatten_app [] node with
        | EVar { name = callee; _ }, (_ :: _ as args) when callee <> name ->
          (match Hashtbl.find_opt signatures callee with
           | Some signature when List.length args = List.length signature.params ->
             List.iteri (fun index arg ->
               match arg with
               | EVar { name = used; _ } when used = name && !found = None ->
                 found := List.nth_opt signature.params index
               | _ -> ()) args
           | _ -> ())
        | _ -> ()) expr) exprs;
  !found

(* The type a `let` binds: its own expression when that settles one, otherwise what a later
   use requires. *)
let let_binding_type signatures env name value later =
  (* A CHECK bound in a test body binds its checked VALUE: `let result = UUID.validate v4`
     followed by `expect result == v4` is what the corpus writes, and a rejection there is a
     failed test rather than a value to compare.  That is the same `MustCheck` every other
     consumer of a check's value goes through. *)
  let value_of = function TCheck inner -> inner | ty -> ty in
  match typed_with_default (type_of_expr signatures env) value with
  (* The value settled a type of its own, but left an ADT argument ANONYMOUS: `let xs =
     [Left "a", Left "b"]` says nothing about what a Right would hold, and the LATER use is
     what settles it.  Without this the binding is emitted at `Either[string, struct{}]` and
     the call that receives it wants `Either[string, teslrt.Int]`, which Go rejects — the
     value is right and only its type was under-determined. *)
  | Some ty, false when has_anon ty ->
    (match expected_from_use signatures name later with
     | Some want when not (has_anon want) ->
       (match typed_with_default (type_of_arg signatures env want) value with
        | Some settled, _ -> value_of settled
        | None, _ -> value_of ty)
     | _ -> value_of ty)
  | Some ty, false -> value_of ty
  | settled, _ ->
    (match expected_from_use signatures name later with
     | Some want ->
       (match typed_with_default (type_of_arg signatures env want) value with
        | Some ty, _ -> ty
        | None, _ -> (match settled with
                      | Some ty -> ty
                      | None -> type_of_expr signatures env value))
     | None ->
       (match settled with
        | Some ty -> ty
        | None -> type_of_expr signatures env value))

let tail_accepts_value signatures env expected expr =
  (* A tail spelled `check g x` — single or combined — DELEGATES: it hands back that check's
     own result, rejection included.  Accepting it would turn a rejection into a trap, which
     is what happened to `check (checkPositive && checkSmall) n` before this test was here. *)
  let delegates = match flatten_app [] expr with
    | EVar { name = "check"; _ }, (_ :: _) -> true
    | _ ->
      check_application signatures expr <> None
      (* A BARE call to another check delegates too — `check wrap(n) -> … = inner n` has no
         `check` keyword and still hands back the inner check's own result.  Reading it as a
         value would `MustCheck` it, turning a rejection into a trap that escapes the
         caller's `expectFail`. *)
      || (match expected, typed_with_default (type_of_expr signatures env) expr with
          | TCheck inner, (Some (TCheck delegated), _) -> not (type_unequal delegated inner)
          | _ -> false)
  in
  match expected, expr with
  | TCheck _, (EOk _ | EFail _) -> None
  | TCheck inner, _ when not delegates ->
    (match typed_with_default (type_of_arg signatures env inner) expr with
     | Some got, _ when not (type_unequal got inner) -> Some inner
     | _ -> None)
  | _ -> None

let emit_tail ?self buffer signatures env expected indent expr =
  let self_name, self_params = match self with
    | Some (name, params) -> Some name, params
    | None -> None, []
  in
  let emit_self_tail_call env indent args =
    (* Every argument lands in its own temporary first: a direct tuple assignment
       makes a pass-through argument a self-assignment, which `go vet` rejects. *)
    let temporaries = List.mapi (fun index arg ->
      let temporary = Printf.sprintf "teslArg%d_%d" (String.length indent) index in
      Printf.bprintf buffer "%s%s := %s\n" indent temporary
        (emit_expr ~indent signatures env arg);
      temporary) args in
    if temporaries <> [] then
      Printf.bprintf buffer "%s%s = %s\n" indent (String.concat ", " self_params)
        (String.concat ", " temporaries);
    Printf.bprintf buffer "%scontinue %s\n" indent loop_label
  in
  let rec go env indent expr =
    match self_name with
    | Some name when
        self_tail_call_args signatures env ~name ~arity:(List.length self_params) expr <> None ->
      let args = match
        self_tail_call_args signatures env ~name ~arity:(List.length self_params) expr with
        | Some args -> args
        | None -> assert false
      in
      ignore (type_of_expr signatures env expr);
      Buffer.add_string buffer (line_directive (Checker.expr_loc expr));
      emit_self_tail_call env indent args
    | _ -> go_shape env indent expr
  and go_shape env indent expr =
    match expr with
    (* A MULTI-LINE query — `update p in E` / `delete p in E` / a `select` with its clauses
       on their own lines — is an underscore-`let` CHAIN in the surface tree, so it arrives
       here looking like an ordinary `let`.  Emitting it as one would take the row binder and
       the clause keywords for values and try to call a function named `update`.
       Recognised FIRST, which is what a test-block statement already does; the two positions
       must read the same tree the same way. *)
    | (ELet _ | EApp _ | EBinop _) when recognise_sql expr <> None ->
      ignore (type_of_arg signatures env expected expr);
      Buffer.add_string buffer (line_directive (Checker.expr_loc expr));
      Printf.bprintf buffer "%sreturn %s\n" indent
        (emit_expr ~expected ~indent signatures env expr)
    (* `with database D { … }` adds nothing at run time on the Memory backend, so its body
       is emitted in TAIL position — the block keeps statement form instead of collapsing
       into an immediately-called closure.  A capability scope is the same: the checker has
       verified every call in it already, so the scope itself has no runtime form. *)
    | EWithDatabase { database_name; body; loc } ->
      (match postgres_database loc database_name with
       | None -> go env indent body
       | Some _ ->
         Buffer.add_string buffer (line_directive loc);
         Printf.bprintf buffer "%sreturn %s\n" indent
           (emit_expr ~expected ~indent signatures env expr))
    (* A `transaction` block is its body with nothing connected, so it keeps STATEMENT form:
       the writes it groups are ordinary statements, and wrapping them in a closure would
       change nothing but the shape of the emitted code.  Where a Postgres database is
       declared the block IS a runtime form (BEGIN/COMMIT) and takes the expression shape. *)
    | EWithTransaction { body; loc } ->
      if not (module_has_postgres_database ()) then go env indent body
      else begin
        Buffer.add_string buffer (line_directive loc);
        Printf.bprintf buffer "%sreturn %s\n" indent
          (emit_expr ~expected ~indent signatures env expr)
      end
    | EWithCapabilities { body; _ } -> go env indent body
    (* `let (v ::: p) = check g x` inside a CHECK or an AUTH: the rejection PROPAGATES, exactly
       as it does for a plain `let v = check g x` below.  The proof-DECOMPOSING form was left
       on the trapping path, so an `auth` that delegated to a check answered 500 where Racket
       answers the check's own status — `adminAuth` in tests/critical-review-48-auth-api-tests
       returns 403 there and crashed here. *)
    | ELetProof { value_name; proof_name; value; body; loc; _ }
      when (match check_application signatures value, expected with
            | Some _, TCheck _ -> true
            | _ -> false) ->
      let signature, args = match check_application signatures value with
        | Some pair -> pair
        | None -> assert false
      in
      let inner = match signature.result with
        | TCheck inner -> inner
        | _ -> assert false
      in
      ignore (type_of_expr signatures env value);
      Printf.bprintf buffer "%s{\n" indent;
      Buffer.add_string buffer (line_directive loc);
      let temporary = Printf.sprintf "teslDelegated%d" (String.length indent) in
      Printf.bprintf buffer "%s\t%s := %s(%s)\n" indent temporary
        (qualified signature.sig_owner signature.go_name)
        (String.concat ", " (List.map2
           (fun want arg ->
              emit_leaf_argument ~indent:(indent ^ "\t") signatures env
                signature.go_name want arg)
           signature.params args));
      Printf.bprintf buffer
        "%s\tif !%s.OK() {\n%s\t\treturn teslrt.Reject[%s](%s.Status(), %s.Message())\n%s\t}\n"
        indent temporary indent (go_type (match expected with TCheck ty -> ty | ty -> ty))
        temporary temporary indent;
      (* Past the guard the check cannot be a rejection, so unwrapping is total. *)
      if value_name = "_" then
        Printf.bprintf buffer "%s\t_ = teslrt.MustCheck(%s)\n" indent temporary
      else
        Printf.bprintf buffer "%s\t%s := teslrt.MustCheck(%s)\n%s\t_ = %s\n" indent
          (local_ident value_name) temporary indent (local_ident value_name);
      if proof_name <> "_" then
        Printf.bprintf buffer "%s\t%s := struct{}{}\n%s\t_ = %s\n" indent
          (local_ident proof_name) indent (local_ident proof_name);
      go ((proof_name, TUnit) :: (value_name, inner) :: env) (indent ^ "\t") body;
      Printf.bprintf buffer "%s}\n" indent
    (* Proof decomposition in tail position keeps statement form, like an ordinary `let`.
       Either half may be `_`, since the decomposition is often written for one of them. *)
    | ELetProof { value_name; proof_name; value; body; loc; _ } ->
      let value_ty = type_of_expr signatures env value in
      Printf.bprintf buffer "%s{\n" indent;
      Buffer.add_string buffer (line_directive loc);
      let emitted =
        emit_expr ~expected:value_ty ~indent:(indent ^ "\t") signatures env value in
      if value_name = "_" then
        Printf.bprintf buffer "%s\t_ = %s\n" indent emitted
      else
        Printf.bprintf buffer "%s\t%s := %s\n%s\t_ = %s\n" indent (local_ident value_name)
          emitted indent (local_ident value_name);
      if proof_name <> "_" then
        Printf.bprintf buffer "%s\t%s := struct{}{}\n%s\t_ = %s\n" indent
          (local_ident proof_name) indent (local_ident proof_name);
      go ((proof_name, TUnit) :: (value_name, value_ty) :: env) (indent ^ "\t") body;
      Printf.bprintf buffer "%s}\n" indent
    (* `let v = check g x` inside another CHECK: a rejection PROPAGATES — it becomes this
       check's own result, carrying the inner status and message.  Racket's `let/check`
       does exactly this (`(if (check-fail? result) result …)`), and the emitter used to
       reach for `MustCheck` here, which PANICS: a handler that should have answered 422
       crashed the request instead.  In a plain `fn` the trap is correct and stays — Racket
       raises there too, since `define/pow` installs a raising handler rather than letting a
       failure leak out as a value. *)
    | ELet { name; value; body; loc; _ }
      when (match expected with
            | TCheck _ ->
              delegated_check_call ~indent:(indent ^ "\t") signatures env value <> None
            | _ -> false) ->
      let call, inner =
        match delegated_check_call ~indent:(indent ^ "\t") signatures env value with
        | Some pair -> pair
        | None -> assert false
      in
      Printf.bprintf buffer "%s{\n" indent;
      Buffer.add_string buffer (line_directive loc);
      let temporary = Printf.sprintf "teslDelegated%d" (String.length indent) in
      Printf.bprintf buffer "%s\t%s := %s\n" indent temporary call;
      Printf.bprintf buffer "%s\tif !%s.OK() {\n%s\t\treturn teslrt.Reject[%s](%s.Status(), %s.Message())\n%s\t}\n"
        indent temporary indent (go_type (match expected with TCheck ty -> ty | ty -> ty))
        temporary temporary indent;
      (* Past the propagation guard the check cannot be a rejection, so unwrapping is
         total; `MustCheck` states that rather than ignoring a second return value. *)
      if name = "_" then
        Printf.bprintf buffer "%s\t_ = teslrt.MustCheck(%s)\n" indent temporary
      else begin
        Printf.bprintf buffer "%s\t%s := teslrt.MustCheck(%s)\n" indent
          (local_ident name) temporary;
        Printf.bprintf buffer "%s\t_ = %s\n" indent (local_ident name)
      end;
      go (if name = "_" then env else (name, inner) :: env) (indent ^ "\t") body;
      Printf.bprintf buffer "%s}\n" indent
    | ELet { name; value; body; loc; _ } ->
      let inferred = type_of_expr signatures env value in
      let ty = if inferred = TFailure then expected else inferred in
      Printf.bprintf buffer "%s{\n" indent;
      Buffer.add_string buffer (line_directive loc);
      let emitted_value =
        emit_expr ~expected:ty ~indent:(indent ^ "\t") signatures env value in
      (* `let _ = expr` discards its value — it is written for the EFFECT.  `_ := expr`
         is not legal Go ("no new variables on left side of :="), so it becomes a plain
         discard. *)
      if name = "_" then
        Printf.bprintf buffer "%s\t_ = %s\n" indent emitted_value
      else begin
        Printf.bprintf buffer "%s\t%s := %s\n" indent (local_ident name) emitted_value;
        Printf.bprintf buffer "%s\t_ = %s\n" indent (local_ident name)
      end;
      go ((name, ty) :: env) (indent ^ "\t") body;
      Printf.bprintf buffer "%s}\n" indent
    | EIf { cond; then_; else_; loc } ->
      (* Only the condition is typed here: each branch is typed against the EXPECTED
         type as it is emitted, which is what lets an under-constrained constructor in
         a branch resolve. *)
      if type_of_expr signatures env cond <> TBool then
        unsupported loc "Go backend if condition must be Bool";
      Buffer.add_string buffer (line_directive loc);
      Printf.bprintf buffer "%sif %s {\n" indent
        (strip_outer_parens (emit_expr ~indent signatures env cond));
      go env (indent ^ "\t") then_;
      Printf.bprintf buffer "%s} else {\n" indent;
      go env (indent ^ "\t") else_;
      Printf.bprintf buffer "%s}\n" indent
    | ECase { scrut; arms; loc } ->
      (* Checked against the EXPECTED type, arm by arm, for the same reason the plain
         tail below is: an arm is exactly where an under-constrained constructor sits.
         `Err "no"` cannot infer the `ok` half of `Result Int String` from its own
         argument — only the return type says what it is — and typing the `case` without
         the expectation rejected that shape outright. *)
      ignore (type_of_arg signatures env expected expr);
      Buffer.add_string buffer (line_directive loc);
      emit_case_statements ~indent signatures env buffer scrut
        (List.map (fun (arm : case_arm) ->
           arm.pattern, arm.guard,
           (fun arm_env body_indent -> go arm_env body_indent arm.body)) arms)
    (* A `fail` in TAIL position: `panic` terminates the function, so this is a statement
       rather than a returned expression — which is also what keeps it gofmt-stable (a
       one-line `func() T { panic(…) }()` is reflowed once the message is long).  Who catches
       it is documented at the expression form. *)
    | EFail { status; message; loc } when (match expected with TCheck _ -> false | _ -> true) ->
      Buffer.add_string buffer (line_directive loc);
      Printf.bprintf buffer "%spanic(teslrt.RequestRejection{Status: %d, Message: %s})\n"
        indent status (emit_expr ~expected:TString ~indent signatures env message)
    (* A check whose TAIL is another check hands that check's result straight back: the
       delegate's status and message are this check's, and no unwrapping happens at all. *)
    | _ when (match check_application signatures expr, expected with
              | Some ({ result = TCheck inner; _ }, _), TCheck outer -> inner = outer
              | _ -> false) ->
      let signature, args = match check_application signatures expr with
        | Some pair -> pair
        | None -> assert false
      in
      Buffer.add_string buffer (line_directive (Checker.expr_loc expr));
      Printf.bprintf buffer "%sreturn %s(%s)\n" indent
        (qualified signature.sig_owner signature.go_name)
        (String.concat ", " (List.map2
           (fun want arg ->
              emit_leaf_argument ~indent signatures env signature.go_name want arg)
           signature.params args))
    | _ ->
      (* The tail is checked against the EXPECTED type so a bare nullary constructor
         of a generic ADT (`Nothing`) is instantiated by the return type. *)
      ignore (type_of_arg signatures env expected expr);
      Buffer.add_string buffer (line_directive (Checker.expr_loc expr));
      (match tail_accepts_value signatures env expected expr with
       | Some inner ->
         Printf.bprintf buffer "%sreturn teslrt.Accept(%s)\n" indent
           (emit_expr ~expected:inner ~indent signatures env expr)
       | None ->
         Printf.bprintf buffer "%sreturn %s\n" indent
           (emit_expr ~expected ~indent signatures env expr))
  in
  go env indent expr

let contains_go_code haystack needle =
  let length = String.length haystack and needle_length = String.length needle in
  let rec loop index in_string escaped in_comment =
    if index >= length then false
    else if in_comment then
      if haystack.[index] = '\n' then loop (index + 1) false false false
      else loop (index + 1) false false true
    else if in_string then
      if escaped then loop (index + 1) true false false
      else if haystack.[index] = '\\' then loop (index + 1) true true false
      else if haystack.[index] = '"' then loop (index + 1) false false false
      else loop (index + 1) true false false
    else if haystack.[index] = '"' then loop (index + 1) true false false
    else if haystack.[index] = '/' && index + 1 < length && haystack.[index + 1] = '/' then
      loop (index + 2) false false true
    else if index + needle_length <= length
         && String.sub haystack index needle_length = needle then true
    else loop (index + 1) false false false
  in
  needle_length = 0 || loop 0 false false false

(* gofmt sorts an import block, so it is emitted sorted — otherwise every multi-import
   file is reported unformatted. *)
let import_block paths =
  let paths = List.sort_uniq String.compare paths in
  match paths with
  | [] -> ""
  | [path] -> Printf.sprintf "\nimport %s\n" (go_quote path)
  | _ -> Printf.sprintf "\nimport (\n%s)\n"
      (String.concat "" (List.map (fun path -> "\t" ^ go_quote path ^ "\n") paths))

(* One ADT emits its tag enum, one flat payload struct, and the equality method
   every comparison site calls.  The struct is deliberately NOT Go-comparable
   whenever a payload is, so `==` cannot silently replace TeslEqual. *)
let adt_source info =
  let body = Buffer.create 512 in
  Buffer.add_char body '\n';
  Buffer.add_string body (line_directive info.adt_loc);
  let type_params =
    if info.adt_params = [] then ""
    else "[" ^ String.concat ", "
      (List.map (fun (_, go_param) -> go_param ^ " any") info.adt_params) ^ "]"
  in
  Printf.bprintf body "type %s int\n\nconst (\n" info.adt_tag_type;
  List.iteri (fun index variant ->
    if index = 0 then Printf.bprintf body "\t%s %s = iota\n" variant.var_tag info.adt_tag_type
    else Printf.bprintf body "\t%s\n" variant.var_tag) info.adt_variants;
  Buffer.add_string body ")\n\n";
  let fields = (adt_tag_field, info.adt_tag_type)
    :: List.concat_map (fun variant ->
         List.map (fun (name, field_ty) ->
           variant_field_go_name variant name,
           (* A self-referential payload is a POINTER: a struct holding itself by value has
              no finite size.  Every read goes through `teslrt.Unboxed`. *)
           (if adt_self_field info field_ty then "*" else "") ^ go_type field_ty)
           variant.var_fields)
         info.adt_variants in
  let width = List.fold_left (fun width (name, _) -> max width (String.length name)) 0 fields in
  Printf.bprintf body "type %s%s struct {\n" info.adt_go_name type_params;
  List.iter (fun (name, go_field_type) ->
    Printf.bprintf body "\t%s%s %s\n" name
      (String.make (width - String.length name) ' ') go_field_type) fields;
  Buffer.add_string body "}\n";
  let payload_variants = List.filter (fun variant -> variant.var_fields <> []) info.adt_variants in
  (* A generic ADT gets no `TeslEqual`: equality on it is rejected before emission,
     and an unused method would be a lint finding. *)
  if info.adt_params <> [] then Buffer.contents body
  else begin
  Buffer.add_char body '\n';
  Printf.bprintf body "func (teslLeft %s) TeslEqual(teslRight %s) bool {\n"
    info.adt_go_name info.adt_go_name;
  if payload_variants = [] then
    Printf.bprintf body "\treturn teslLeft.%s == teslRight.%s\n" adt_tag_field adt_tag_field
  else begin
    Printf.bprintf body "\tif teslLeft.%s != teslRight.%s {\n\t\treturn false\n\t}\n"
      adt_tag_field adt_tag_field;
    Printf.bprintf body "\tswitch teslLeft.%s {\n" adt_tag_field;
    List.iter (fun variant ->
      Printf.bprintf body "\tcase %s:\n" variant.var_tag;
      let parts = List.map (fun (name, field_ty) ->
        let field = variant_field_go_name variant name in
        let operand side =
          if adt_self_field info field_ty then
            Printf.sprintf "teslrt.Unboxed(tesl%s.%s)" side field
          else Printf.sprintf "tesl%s.%s" side field
        in
        equal_expr field_ty (operand "Left") (operand "Right")) variant.var_fields in
      Printf.bprintf body "\t\treturn %s\n" (String.concat " && " parts)) payload_variants;
    (* The payload-free tags are listed too: equal tags with no payload are equal, and
       naming them keeps the switch verifiable by the `exhaustive` linter. *)
    let nullary_variants =
      List.filter (fun variant -> variant.var_fields = []) info.adt_variants in
    if nullary_variants <> [] then
      Printf.bprintf body "\tcase %s:\n\t\treturn true\n"
        (String.concat ", " (List.map (fun variant -> variant.var_tag) nullary_variants));
    Buffer.add_string body "\tdefault:\n\t\treturn true\n\t}\n"
  end;
  Buffer.add_string body "}\n";
  Buffer.contents body
  end

(* A codec becomes two ordinary Go functions per direction, mirroring what the Racket
   backend generates (`tesl-codec-encode-T`, `tesl-codec-decode-T-N`) — there is no macro
   layer to reproduce.  Differences that matter, both verified against Racket:

   - ENCODING goes through a sorted-key map rather than a struct with json tags, because
     Racket's `jsexpr->string` sorts object keys and response bytes are observable.
   - An INTEGER is rendered from its decimal digits and decoded from `json.Number`, since
     Tesl's Int is arbitrary precision and Go's default number handling is float64.

   Decode returns a `teslrt.Check`, so a `via` failure carries the check's own status and
   message (the 400 the client sees), while a missing or mistyped field is a decode
   failure whose text Racket hides behind "Invalid request payload" by default. *)
let codec_alt_name type_name index =
  Printf.sprintf "teslDecode%sAlt%d" (go_ident ~exported:true type_name) index

(* The primitive codecs, by the name written in `with_codec`.  Anything else is a TYPE
   name and resolves to that type's own codec. *)
(* `with_codec AcctId` names a NEWTYPE rather than a codec.  A newtype has no codec of its
   own — Racket resolves the spelling to the BASE codec, which is why `with_codec AcctId` and
   `with_codec stringCodec` on the same field round-trip identically — so it resolves here the
   same way.  Emitting a reference to `EncodeAcctIdJSON` instead produced a package that did
   not compile. *)
let newtype_base_codec name =
  match Option.bind !current_types (fun types -> Hashtbl.find_opt types.newtypes name) with
  | Some info ->
    (match info.base with
     | TString -> Some `String | TInt -> Some `Int
     | TBool -> Some `Bool | TFloat -> Some `Float
     | _ -> None)
  | None -> None

let primitive_codec = function
  | "stringCodec" -> Some `String
  | "intCodec" -> Some `Int
  | "boolCodec" -> Some `Bool
  | "floatCodec" -> Some `Float
  (* A `PosixMillis` crosses the wire as its integer millis and nothing else — the
     agent-boundary enrichment (`{epochMillis, iso}`) is a different surface, and an HTTP body
     carries the bare number on both backends (`tesl-encode-prim-posix-millis`). *)
  | "posixMillisCodec" -> Some `PosixMillis
  | _ -> None

(* What a field's `with_codec` means: a primitive codec, or a newtype standing for its base. *)
let field_codec_kind name =
  match primitive_codec name with
  | Some kind -> Some kind
  | None -> newtype_base_codec name

(* The wire shape of a response value, mirroring `runtime-value->jsexpr` in dsl/types.rkt:
   a type with its own codec encodes through it; a record without one becomes an object of
   its fields; an ADT without one becomes a TAGGED object — `{"tag":"Nothing"}`, or
   `{"tag":"Something","fields":{…}}` when the variant carries payload.  That is why a
   handler returning `Maybe Task` works without a codec for `Maybe`: the tagged shape is
   the fallback, not an error.  A newtype unwraps, matching Racket.

   Each encoder is hoisted into a named function, so the call site stays a plain call and
   the same type is encoded one way everywhere. *)
(* gofmt ALIGNS the values in a map literal, so the padding is part of the emitted text
   rather than something a formatter run would add: every entry's value starts at the same
   column, one past the longest `"key":`.  The codec-driven encoder computes the same
   padding for the same reason. *)
let aligned_map_entries indent entries =
  let width = List.fold_left (fun width (key, _) ->
    max width (String.length key + 3)) 0 entries in
  String.concat "\n" (List.map (fun (key, value) ->
    let key = Printf.sprintf "%S:" key in
    Printf.sprintf "%s%s%s %s," indent key
      (String.make (width - String.length key) ' ') value) entries)

let rec value_encoder ty =
  let encoded_field operand field_ty =
    Printf.sprintf "%s(%s)" (value_encoder field_ty) operand in
  match ty with
  | TInt | TString | TBool | TFloat | TQuantity | TUnit ->
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:"teslValue"
  | TNewtype info ->
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:(encoded_field "teslValue.Value" info.base)
  | TRecord info when List.mem info.rec_tesl_name !current_codec_types
                      || codec_owner info.rec_tesl_name <> None ->
    codec_encode_ref info.rec_tesl_name
  | TAdt (info, _) when List.mem info.adt_tesl_name !current_codec_types
                        || codec_owner info.adt_tesl_name <> None ->
    codec_encode_ref info.adt_tesl_name
  | TRecord info ->
    let fields = aligned_map_entries "\t\t" (List.map (fun (name, field_ty) ->
      (name, encoded_field ("teslValue." ^ record_field_go_name name) field_ty))
      info.rec_fields) in
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:(Printf.sprintf "map[string]any{\n%s\n\t}" fields)
  | TAdt (info, args) ->
    let arms = List.map (fun variant ->
      let fields = variant_field_types info args variant in
      let payload = match fields with
        | [] -> Printf.sprintf "map[string]any{\"tag\": %S}" variant.var_ctor
        | _ ->
          let entries = aligned_map_entries "\t\t\t\t" (List.map (fun (name, field_ty) ->
            (name, encoded_field ("teslValue." ^ variant_field_go_name variant name) field_ty))
            fields) in
          Printf.sprintf
            "map[string]any{\"tag\": %S, \"fields\": map[string]any{\n%s\n\t\t\t}}"
            variant.var_ctor entries
      in
      Printf.sprintf "\t\tcase %s:\n\t\t\treturn %s"
        (qualified info.adt_owner variant.var_tag) payload) info.adt_variants in
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:(Printf.sprintf
        "func() any {\n\t\tswitch teslValue.%s {\n%s\n\t\t}\n\t\tpanic(\"unreachable: checker guarantees case exhaustiveness\")\n\t}()"
        adt_tag_field (String.concat "\n" arms))
  | TList element ->
    remember_helper ~prefix:"teslEncode"
      ~signature:(Printf.sprintf "(teslValue %s) any" (go_type ty))
      ~body:(Printf.sprintf
        "func() any {\n\t\tteslOut := make([]any, len(teslValue))\n\t\tfor teslAt, teslItem := range teslValue {\n\t\t\tteslOut[teslAt] = %s(teslItem)\n\t\t}\n\t\treturn teslOut\n\t}()"
        (value_encoder element))
  | TDict _ | TSet _ | TParam _ | TFunc _ | TJson | TStream | TCheck _ | TFailure
  | TAnon ->
    invalid_arg "Go response encoding for this type is rejected before emission"

(* ── HTTP: `api` routes and the `server` that binds them ──────────────────────
   An `api` declares endpoints; a `server` binds handler functions to them POSITIONALLY in
   declaration order (the endpoint's own `name` is a parser-assigned placeholder, and the
   syntax used to carry a name-keyed-looking prefix that was always matched by position).
   Both become ordinary Go values, so someone who sheds Tesl can read the routing table,
   call a handler directly, or mount the server on any net/http mux. *)

(* The expression emitter reaches the encoder through this cell; see its declaration. *)
let () = value_encoder_hook := value_encoder

let http_method_name = function
  | GET -> "GET" | POST -> "POST" | PUT -> "PUT"
  | DELETE -> "DELETE" | PATCH -> "PATCH" | SSE -> "SSE"

(* Does a `requires` clause reach `cookieCap`?  A capability may IMPLY others
   (`capability sessions implies cookieCap, jwt`), so the answer is the transitive closure over
   the module's own declarations — testing the name directly missed every program that bundles
   its capabilities, and the handler then referenced a request scope it had never been given. *)
let implies_cookie_cap (capabilities : capability_form list) declared =
  let seen = Hashtbl.create 8 in
  let rec reaches name =
    if name = "cookieCap" then true
    else if Hashtbl.mem seen name then false
    else begin
      Hashtbl.add seen name ();
      match List.find_opt (fun (c : capability_form) -> c.name = name) capabilities with
      | Some form -> List.exists reaches form.implies
      | None -> false
    end
  in
  List.exists reaches declared

(* The decoder for a JSON value of a given type, as a `func(any) (T, error)`.
   Shared by the DERIVED record decoder and by a codec field whose `with_codec` names a CONTAINER
   codec (`listCodec`/`setCodec`/`dictCodec`): those decode by the field's declared type — the
   element type is what says how to read each element — which is exactly this walk.  Racket
   routes the same case through its generic type-aware decoder for the same reason: the prim
   decoder only checks the JSON shape and passes elements through unconverted. *)
let rec json_value_decoder ~package ~loc ~what ty =
  match ty with
  | TString -> "teslrt.DecodeStringValue"
  | TInt -> "teslrt.DecodeIntValue"
  | TBool -> "teslrt.DecodeBoolValue"
  | TFloat -> "teslrt.DecodeFloatValue"
  | TNewtype info ->
    let inner = json_value_decoder ~package ~loc ~what info.base in
    let wrap = if info.secret then "teslrt.MakeSecret(teslBase)" else "teslBase" in
    Printf.sprintf
      "func(teslRaw any) (%s, error) {\n\t\tteslBase, teslErr := %s(teslRaw)\n\t\tif teslErr != nil {\n\t\t\treturn %s{}, teslErr\n\t\t}\n\t\treturn %s{Value: %s}, nil\n\t}"
      (go_type ty) inner (go_type ty) (go_type ty) wrap
  | TList element ->
    Printf.sprintf
      "func(teslRaw any) ([]%s, error) {\n\t\treturn teslrt.DecodeListValue(teslRaw, %s)\n\t}"
      (go_type element) (json_value_decoder ~package ~loc ~what element)
  | TRecord nested when nested.rec_owner = package
                        || List.mem nested.rec_tesl_name !current_codec_types
                        || codec_owner nested.rec_tesl_name <> None ->
    (* A nested record decodes through its own decoder — derived or hand-written — and its
       `Check` becomes an `error` here so one field shape covers both. *)
    Printf.sprintf
      "func(teslRaw any) (%s, error) {\n\t\tteslNested := %s(teslRaw)\n\t\tif !teslNested.OK() {\n\t\t\treturn %s{}, errors.New(teslNested.Message())\n\t\t}\n\t\tteslValue, _ := teslNested.Value()\n\t\treturn teslValue, nil\n\t}"
      (go_type ty) (codec_decode_ref nested.rec_tesl_name) (go_type ty)
  | _ -> unsupported loc
    "Go backend cannot decode `%s` from JSON; give the type a `codec`" what

let module_source ?(imported_packages=[]) ?(unreachable=[]) ?(codecs=[]) ?(apis=[])
    ?(servers=[]) ?(capturers=[]) ?(consts=[]) ?(agents=[]) ?(capabilities=[])
    module_path package signatures
    types (funcs : func_decl list) =
  Hashtbl.reset pending_helpers;
  Hashtbl.reset helper_names;
  Hashtbl.reset module_helpers;
  let body = Buffer.create 1024 in
  (* ONLY THE DECLARING PACKAGE EMITS A DECLARATION.  An imported type is present in
     these tables so it can be referenced and its fields read, but emitting it here too
     would produce a second, incompatible Go type with the same Tesl name. *)
  let declared_here owner = owner = package in
  Hashtbl.to_seq_values types.newtypes
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.tesl_name right.tesl_name)
  |> List.filter (fun info -> declared_here info.owner)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.loc);
    if info.secret then begin
      (* A SECRET newtype carries a redacting payload, and the type itself gets `String()` so
         that printing the newtype — not just its field — redacts.  Reaching the plaintext is
         `.Value.Reveal()`, spelled to be greppable. *)
      Printf.bprintf body "type %s struct {\n\tValue teslrt.SecretString\n}\n" info.go_name;
      Printf.bprintf body
        "\nfunc (teslSecret %s) String() string { return teslrt.SecretRedaction }\n"
        info.go_name
    end else
      Printf.bprintf body "type %s struct {\n\tValue %s\n}\n"
        info.go_name (go_type info.base));
  Hashtbl.to_seq_values types.records
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.rec_tesl_name right.rec_tesl_name)
  |> List.filter (fun info -> declared_here info.rec_owner)
  |> List.iter (fun info ->
    (* gofmt aligns a struct's field types in one column; emit that alignment
       directly so the corpus stays gofmt-clean. *)
    let width = List.fold_left (fun width (name, _) ->
      max width (String.length (record_field_go_name name))) 0 info.rec_fields in
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.rec_loc);
    Printf.bprintf body "type %s struct {\n" info.rec_go_name;
    List.iter (fun (name, field_ty) ->
      let field = record_field_go_name name in
      Printf.bprintf body "\t%s%s %s\n" field
        (String.make (width - String.length field) ' ') (go_type field_ty))
      info.rec_fields;
    Buffer.add_string body "}\n");
  Hashtbl.to_seq_values types.adts
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.adt_tesl_name right.adt_tesl_name)
  |> List.iter (fun info ->
    if not info.adt_builtin && declared_here info.adt_owner then
      Buffer.add_string body (adt_source info));
  (* The job store for a queue.  `maxAttempts` is baked in because the retry rule belongs to
     the queue rather than to any call site; the lowered form supplies it (default 1, matching
     "no retry" for a queue that declares none). *)
  Hashtbl.to_seq_values types.queues
  |> List.of_seq
  |> List.sort_uniq (fun left right -> String.compare left.qu_tesl_name right.qu_tesl_name)
  |> List.filter (fun info -> info.qu_owner = package)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.qu_loc);
    Printf.bprintf body "var %s = teslrt.NewQueue(%s, %d)\n"
      info.qu_go_var (go_quote info.qu_tesl_name) info.qu_max_attempts);
  (* The store for a `cache` declaration.  `defaultTtl:` is baked in for the reason
     `maxAttempts` is: the expiry rule belongs to the declaration, not to any call site, and a
     `Cache.set` with no TTL of its own is exactly the one that asks for it. *)
  Hashtbl.to_seq_values types.caches
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.ca_tesl_name right.ca_tesl_name)
  |> List.filter (fun info -> declared_here info.ca_owner)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.ca_loc);
    Printf.bprintf body "var %s = teslrt.NewCache[%s](%d)\n"
      info.ca_go_var (go_type info.ca_value) info.ca_default_ttl);
  (* The outbox for an `email` declaration.  Its SMTP settings are the declaration's, and an
     `env` among them is a call here rather than a baked-in string: the variable belongs to
     the deployment, not to the build. *)
  Hashtbl.to_seq_values types.emails
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.em_tesl_name right.em_tesl_name)
  |> List.filter (fun info -> declared_here info.em_owner)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.em_loc);
    Printf.bprintf body
      "var %s = teslrt.NewOutbox(teslrt.SmtpSettings{\n\tHost:     %s,\n\tPort:     %d,\n\tUsername: %s,\n\tPassword: %s,\n\tTLS:      %b,\n})\n"
      info.em_go_var info.em_host info.em_port info.em_username info.em_password info.em_tls);
  (* The channel a `sseChannel` declaration becomes: one registry per declaration, named so a
     reader can see which channel a `publish` reaches. *)
  Hashtbl.to_seq_values types.channels
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.ch_tesl_name right.ch_tesl_name)
  |> List.filter (fun info -> declared_here info.ch_owner)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.ch_loc);
    Printf.bprintf body "var %s = teslrt.NewSseChannel(%s)\n"
      info.ch_go_var (go_quote info.ch_tesl_name));
  (* The store for a `backend: Memory` entity.  One variable per entity, initialised at
     package level: an entity belongs to exactly one database, and the table itself is
     what carries the lock, so nothing has to be threaded through call sites. *)
  Hashtbl.to_seq_values types.entities
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.ent_tesl_name right.ent_tesl_name)
  |> List.filter (fun info -> declared_here info.ent_owner)
  |> List.iter (fun info ->
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive info.ent_loc);
    Printf.bprintf body "var %s = teslrt.NewTable[%s]()\n"
      info.ent_table_var info.ent_row.rec_go_name);
  (* A Postgres-backed `database` declaration becomes one value holding what a connection
     needs: the DSN parts, the schema, and the tables the bootstrap creates if they are absent.
     A Memory-backed declaration emits nothing at all — the store it names IS the entity's
     table variable, which is why the corpus's Memory programs are unchanged by any of this. *)
  Hashtbl.to_seq_values types.databases
  |> List.of_seq
  |> List.sort (fun left right -> String.compare left.db_tesl_name right.db_tesl_name)
  |> List.filter (fun info -> info.db_backend = "postgres" && declared_here info.db_owner)
  |> List.iter (fun (database : database_info) ->
    let setting key = List.assoc_opt key database.db_config in
    let text key = match setting key with
      | Some value -> Some (go_config_value database.db_loc value)
      | None -> None in
    let fields =
      List.filter_map (fun (name, rendered) ->
        Option.map (fun value -> Printf.sprintf "%s: %s" name value) rendered)
        [ "DBName", text "database";
          "User", text "user";
          "Password", text "password";
          "Host", text "host";
          "Port", Option.map (go_config_int database.db_loc) (setting "port");
          "SocketDir", text "socket";
          "Schema", (if database.db_schema = "" then None
                     else Some (go_quote database.db_schema)) ]
    in
    let tables =
      Hashtbl.to_seq_values types.entities
      |> List.of_seq
      |> List.sort (fun left right -> String.compare left.ent_tesl_name right.ent_tesl_name)
      |> List.filter (fun (entity : entity_info) ->
           List.mem entity.ent_tesl_name database.db_entities)
      |> List.map (fun (entity : entity_info) ->
           let columns =
             List.map (fun (column : column_info) ->
               Printf.sprintf "\t\t\tteslrt.PostgresColumnOf(%s, %s, %b, %b),\n"
                 (go_quote column.col_name) (go_quote column.col_sql_type)
                 column.col_primary_key column.col_nullable)
               (entity_columns entity) in
           (* A UNIQUE index is created by the bootstrap under the name `dsl/sql.rkt` derives,
              so a table shared with the Racket backend does not end up with two indexes doing
              the same job.  A plain index is a hint with no observable effect and is left to
              whoever tunes the database. *)
           let unique =
             List.filter_map (fun (index : entity_index) ->
               if not index.ix_unique then None
               else
                 let columns = List.map (fun field ->
                   (sql_column_of entity.ent_loc entity field).col_name) index.ix_fields in
                 let name = match index.ix_name with
                   | Some explicit -> explicit
                   | None -> truncate_sql_identifier
                     (entity.ent_table_name ^ "_" ^ String.concat "_" columns ^ "_idx") in
                 Some (Printf.sprintf "teslrt.PostgresIndexOf(%s, %s)" (go_quote name)
                         (String.concat ", " (List.map go_quote columns))))
               entity.ent_indexes in
           match unique with
           | [] ->
             Printf.sprintf "\t\tteslrt.PostgresTableOf(%s,\n%s\t\t),\n"
               (go_quote entity.ent_table_name) (String.concat "" columns)
           | _ ->
             Printf.sprintf
               "\t\tteslrt.PostgresTableWithIndexes(%s,\n\t\t\t[]teslrt.PostgresIndex{%s},\n%s\t\t),\n"
               (go_quote entity.ent_table_name) (String.concat ", " unique)
               (String.concat "" columns))
    in
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive database.db_loc);
    Printf.bprintf body
      "var %s = teslrt.NewDatabase(\n\t%s,\n\tteslrt.PostgresConfig{%s},\n\t%s,\n)\n"
      database.db_go_var (go_quote database.db_tesl_name) (String.concat ", " fields)
      (* An EMPTY table list is written on one line: gofmt collapses `{\n}` and a database
         whose entities are declared in another module has none of them here. *)
      (match tables with
       | [] -> "[]teslrt.PostgresTable{}"
       | _ -> Printf.sprintf "[]teslrt.PostgresTable{\n%s\t}" (String.concat "" tables)));
  (* Module-level constants, in declaration order: each one's type settles as it is emitted, so
     a constant may be written in terms of an earlier one. *)
  List.iter (fun (c : const_form) ->
    let go_name = match Hashtbl.find_opt types.consts c.name with
      | Some (_, go_name) -> go_name
      | None -> unsupported c.loc "Go backend cannot resolve constant `%s`" c.name
    in
    let ty = type_of_expr signatures [] c.value in
    Hashtbl.replace types.consts c.name (ty, go_name);
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive c.loc);
    Printf.bprintf body "var %s = %s\n" go_name
      (emit_expr ~expected:ty signatures [] c.value)) consts;
  (* Module-level AGENTS.  The four fields are written out here rather than through the
     record-literal emitter because one of them is treated differently: the PROVIDER is
     wrapped in `DeferredProvider`, so a declaration whose provider reads configuration
     (`anthropic (requireEnv "…") "model"` is the shape the corpus uses) does not read it
     when the program loads.  See DeferredProvider for why that is the right moment. *)
  List.iter (fun (a : agent_form) ->
    let go_name = match Hashtbl.find_opt types.consts a.name with
      | Some (_, go_name) -> go_name
      | None -> unsupported a.loc "Go backend cannot resolve agent `%s`" a.name
    in
    let fields = match a.config_expr with
      | Some (ERecord { fields; _ }) -> fields
      | Some (EApp { fn = EConstructor { name = "Agent"; args = []; _ };
                     arg = ERecord { fields; _ }; _ }) -> fields
      | _ -> unsupported a.loc
        "Go backend requires an `agent` block to be written `= Agent { … }`"
    in
    let info = match Hashtbl.find_opt types.records "Agent" with
      | Some info -> info
      | None -> unsupported a.loc
        "Go backend `agent %s` needs `Agent` imported from `Tesl.Agent`" a.name
    in
    check_record_literal signatures [] a.loc info fields;
    (* The declaration's TYPE, now that it is known: a reference to the agent elsewhere in
       the module resolves through this table, exactly as a reference to a constant does. *)
    Hashtbl.replace types.consts a.name (TRecord info, go_name);
    let field name =
      match List.assoc_opt name fields, List.assoc_opt name info.rec_fields with
      | Some value, Some want -> emit_expr ~expected:want signatures [] value
      | _ -> unsupported a.loc "Go backend `agent %s` is missing field `%s`" a.name name
    in
    (* The provider expression becomes a named builder rather than an inline literal, for
       the reason every other hoisted helper is named: gofmt reflows a function literal at
       a size the emitter cannot predict. *)
    let build = remember_helper ~prefix:"teslProvider"
      ~signature:"() teslrt.LlmProvider" ~body:(field "provider") in
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive a.loc);
    Printf.bprintf body
      "var %s = teslrt.Agent{Provider: teslrt.DeferredProvider(%s), SystemPrompt: %s, MaxTokens: %s, Tools: %s}\n"
      go_name build (field "systemPrompt") (field "maxTokens") (field "tools")) agents;
  List.iter (fun (fd : func_decl) ->
    (* `establish` returns a detached proof, which erases — so the function body computes
       nothing observable and the emitted function returns the zero-size proof value.  It
       is still emitted (rather than dropped) because callers name it. *)
    (* An `auth` function is a check over the request: it returns `ok value ::: Proof` or
       `fail 401 …`, so it emits exactly like a `check`. *)
    (* A `worker` / `deadWorker` is an ordinary function of the job: its `FromQueue` proof
       annotation erases like every other proof, and the queue runtime is what calls it. *)
    (* `main` is emitted like any other function: by the time it gets here its trailing
       `App { … }` record has been LOWERED into the startup chain it describes (start each
       queue's workers, then serve), so there is no App value at run time — the record is
       configuration the compiler reads, which is what makes it typed rather than a config file. *)
    if fd.kind <> FnKind && fd.kind <> CheckKind && fd.kind <> EstablishKind
       && fd.kind <> HandlerKind && fd.kind <> AuthKind
       && fd.kind <> WorkerKind && fd.kind <> DeadWorkerKind
       && fd.kind <> MainKind then
      unsupported fd.loc
        "Go backend supports `fn`, `check`, `auth`, `establish`, `handler`, `worker`, \
         `deadWorker` and `main` declarations only";
    (* A capability is a COMPILE-TIME grant: the checker verifies every call against the
       declared set and forces it to propagate to callers, so nothing about it survives to
       run time.  `cookieCap` is the exception in shape only — it says this function may
       write to the response, so it receives the request scope.  That marker is the
       `requires` clause itself; no call-graph analysis is needed. *)
    let needs_scope = implies_cookie_cap capabilities fd.capabilities in
    (* No capability is checked against a list any more.  A capability is a COMPILE-TIME
       grant with no runtime form, and a capability naming a subsystem this backend does
       not implement cannot be exercised anyway — its functions are what fail closed, at
       the import.  `cookieCap` is the one exception, handled above, and only because it
       says "this function may write to the response". *)
    ignore fd.capabilities;
    let signature = Hashtbl.find signatures fd.name in
    let params = List.map2 (fun (binding : binding) ty -> binding.name, ty)
      fd.params signature.params in
    let result = signature.result in
    let env = params in
    (* An `establish` body is a proof TERM, not a value expression — it is never typed or
       emitted, so it is not checked against the result type either.  When the result is a
       CONTAINER of proofs (`Maybe (Fact P)`) the body IS emitted, and then it is checked
       like any other. *)
    if fd.kind <> EstablishKind || result <> TUnit then begin
      let body_ty = type_of_arg signatures env result fd.body in
      if type_unequal body_ty result && body_ty <> TFailure then
        unsupported fd.loc "Go backend function result type mismatch"
    end;
    Buffer.add_char body '\n';
    Buffer.add_string body (line_directive fd.loc);
    (* A function that may write to the response takes the request scope as its FIRST
       parameter.  Nothing else gains one, so ordinary functions keep plain signatures. *)
    let scope_parameter =
      if needs_scope then [ "teslScope *teslrt.RequestScope" ] else [] in
    (* A GENERIC function declares its type parameters between the name and the arguments.
       `any` is the only constraint: Tesl has no bounded polymorphism, and a parameter this
       backend cannot do anything to is exactly what an unconstrained one is. *)
    let type_parameters = match Hashtbl.find_opt current_type_params fd.name with
      | None | Some [] -> ""
      | Some params ->
        Printf.sprintf "[%s]"
          (String.concat ", " (List.map (fun (_, go) -> go ^ " any") params))
    in
    Printf.bprintf body "func %s%s(%s) %s {\n"
      signature.go_name type_parameters
      (String.concat ", "
         (scope_parameter
          @ List.map (fun (name, ty) -> local_ident name ^ " " ^ go_type ty) params))
      (go_type result);
    (* Emit the body once assuming it may loop.  If no self tail call actually turned
       into a `continue`, re-emit it flat: an unused label is a Go compile error, and
       a function that never tail-calls itself should read as plain Go. *)
    (* An `establish` body constructs a proof TERM (`Named "http" port`), which has no
       runtime content — so the emitted function returns the zero-size proof value and the
       body is not emitted at all.  Its parameters stay, since callers pass them.
       EXCEPT when the result is not the bare proof: `-> Maybe (Fact (ValidPort port))`
       answers "can this be established?", and the caller CASES on that answer, so the
       control flow is observable and the body must be emitted (with the proof inside it
       erased as usual).  Skipping it there emitted `return struct{}{}` for a Maybe. *)
    if fd.kind = EstablishKind && result = TUnit then begin
      List.iter (fun (name, _) ->
        Printf.bprintf body "\t_ = %s\n" (local_ident name)) params;
      Printf.bprintf body "\treturn struct{}{}\n}\n"
    end else begin
    let self = fd.name, List.map (fun (name, _) -> local_ident name) params in
    current_handler_body := (fd.kind = HandlerKind);
    current_scope_in_hand := needs_scope;
    let looped = Buffer.create 256 in
    emit_tail ~self looped signatures env result "\t\t" fd.body;
    if contains_go_code (Buffer.contents looped) ("continue " ^ loop_label) then begin
      Printf.bprintf body "%s:\n\tfor {\n" loop_label;
      Buffer.add_buffer body looped;
      Buffer.add_string body "\t}\n"
    end else
      emit_tail body signatures env result "\t" fd.body;
    current_handler_body := false;
    current_scope_in_hand := false;
    Buffer.add_string body "}\n" end) funcs;
  (* ── Codecs ─────────────────────────────────────────────────────────────── *)
  (* Which types have their own codec, for the response encoder above. *)
  current_codec_types :=
    List.map (fun (codec : codec_form) -> codec.type_name) codecs;
  List.iter (fun (codec : codec_form) ->
    let type_name = codec.type_name in
    let go_ty =
      match Hashtbl.find_opt types.records type_name with
      | Some info -> TRecord info
      | None ->
        (match Hashtbl.find_opt types.adts type_name with
         | Some info -> TAdt (info, [])
         | None ->
           (match Hashtbl.find_opt types.newtypes type_name with
            | Some info -> TNewtype info
            | None ->
              unsupported codec.loc "Go backend codec `%s` needs a record or ADT type"
                type_name))
    in
    let record_info = match go_ty with TRecord info -> Some info | _ -> None in
    let field_go name = record_field_go_name name in
    let field_type name =
      match record_info with
      | Some info ->
        (match List.assoc_opt name info.rec_fields with
         | Some ty -> ty
         | None ->
           unsupported codec.loc "Go backend codec `%s` has no field `%s`" type_name name)
      | None -> unsupported codec.loc "Go backend codec `%s` needs a record type" type_name
    in
    (* Encode: a record becomes a sorted-key map; an `adtJson` type becomes the
       constructor name as a JSON string. *)
    (match codec.to_json with
     | ToJsonForbidden -> ()
     | ToJsonAdt ->
       (match go_ty with
        | TAdt (info, _) ->
          Printf.bprintf body "\nfunc %s(teslValue %s) any {\n\tswitch teslValue.%s {\n"
            (codec_encode_name type_name) (go_type go_ty) adt_tag_field;
          List.iter (fun variant ->
            if variant.var_fields <> [] then unsupported codec.loc
              "Go backend `adtJson` needs constructors without payloads (`%s`)" variant.var_ctor;
            (* The wire shape is `{"tag": "Ctor"}`, which is what Racket's generated `adtJson`
               encoder writes — a bare constructor STRING (which this emitted before) reads
               back as a different value on the other backend, and the two disagreed about
               every response carrying an enum. *)
            Printf.bprintf body "\tcase %s:\n\t\treturn map[string]any{\"tag\": %S}\n"
              (qualified info.adt_owner variant.var_tag) variant.var_ctor) info.adt_variants;
          Printf.bprintf body "\t}\n\tpanic(\"unreachable: checker guarantees case exhaustiveness\")\n}\n"
        | _ -> unsupported codec.loc "Go backend `adtJson` needs an ADT type")
     | ToJsonFields entries ->
       Printf.bprintf body "\nfunc %s(teslValue %s) any {\n\treturn map[string]any{\n"
         (codec_encode_name type_name) (go_type go_ty);
       Buffer.add_string body (aligned_map_entries "\t\t"
         (List.map (fun (entry : codec_encode_entry) ->
            let value = Printf.sprintf "teslValue.%s" (field_go entry.field_name) in
            (* A PRIMITIVE codec puts the base value on the wire, so a field whose type is a
               newtype hands over its payload rather than the wrapper — `{"id":"u-9"}`, not
               `{"id":{"Value":"u-9"}}`, which is what the wrapper marshals to.  The instant is
               the same rule, not a special case. *)
            let rec unwrapped ty rendered = match ty with
              | TNewtype info -> unwrapped info.base (rendered ^ ".Value")
              | _ -> rendered
            in
            (entry.json_key, match field_codec_kind entry.codec with
              | Some _ -> unwrapped (field_type entry.field_name) value
              | None -> Printf.sprintf "%s(%s)" (codec_encode_ref entry.codec) value))
            entries));
       Buffer.add_string body "\n\t}\n}\n");
    (* Decode: each alternative is COMPLETE and they are tried in order, first success
       winning — the same rule the Racket decoder list follows. *)
    (match codec.from_json with
     | FromJsonForbidden -> ()
     | FromJsonAdt ->
       (match go_ty with
        | TAdt (info, _) ->
          Printf.bprintf body
            (* BOTH shapes are accepted, as Racket's generated decoder accepts them: the
               tagged object its own encoder writes, and a bare string a hand-written or Elm
               client may send. *)
            "\nfunc %s(teslJSON any) teslrt.Check[%s] {\n\tteslName, teslErr := teslrt.DecodeAdtTag(teslJSON)\n\tif teslErr != nil {\n\t\treturn teslrt.Reject[%s](400, teslErr.Error())\n\t}\n\tswitch teslName {\n"
            (codec_decode_name type_name) (go_type go_ty) (go_type go_ty);
          List.iter (fun variant ->
            Printf.bprintf body "\tcase %S:\n\t\treturn teslrt.Accept(%s{%s: %s})\n"
              variant.var_ctor (go_type go_ty) adt_tag_field
              (qualified info.adt_owner variant.var_tag)) info.adt_variants;
          Printf.bprintf body
            "\t}\n\treturn teslrt.Reject[%s](400, \"expected one of the %s constructors, got \"+teslName)\n}\n"
            (go_type go_ty) type_name
        | _ -> unsupported codec.loc "Go backend `adtJson` needs an ADT type")
     | FromJsonAlts alternatives ->
       let go_type_name = go_type go_ty in
       List.iteri (fun index (alternative : codec_decode_alt) ->
         Printf.bprintf body "\nfunc %s(teslJSON any) teslrt.Check[%s] {\n"
           (codec_alt_name type_name index) go_type_name;
         let assignments = ref [] in
         List.iter (fun entry ->
           match entry with
           | DecodeField { field_name; json_key; codec = field_codec; via; _ } ->
             let suffix = go_ident ~exported:true field_name in
             let binder = "teslField" ^ suffix in
             (match field_codec_kind field_codec with
              | Some kind ->
                let decoder = match kind with
                  | `String -> "DecodeStringField" | `Int -> "DecodeIntField"
                  | `Bool -> "DecodeBoolField" | `Float -> "DecodeFloatField"
                  (* The millis come back as an Int and the field's own newtype wraps them,
                     which is what `base_value` below arranges.
                     Racket cannot do this today — `tesl-decode-prim-posix-millis` answers the
                     bare integer and a `PosixMillis` field rejects it, so the same body is a
                     400 there (finding 11).  Go answers correctly rather than reproducing that:
                     the same call the port has made for `selectCount`'s dropped joins and for
                     `innerJoin` against a real server.  The divergence is measured, not
                     inherited. *)
                  | `PosixMillis -> "DecodeIntField"
                in
                Printf.bprintf body
                  "\t%s, teslErr%s := teslrt.%s(teslJSON, %S)\n\tif teslErr%s != nil {\n\t\treturn teslrt.RejectShape[%s](teslErr%s.Error())\n\t}\n"
                  binder suffix decoder json_key suffix go_type_name suffix
              (* A CONTAINER codec (`listCodec`/`setCodec`/`dictCodec`) decodes by the FIELD'S
                 DECLARED TYPE rather than by the codec name: the element type is what says how
                 to read each element, and the codec name only says "this is a container".
                 Racket routes it through its generic type-aware decoder for the same reason —
                 its prim decoder checks the JSON shape and passes elements through unconverted,
                 which made a declared `List String` accept anything an array held. *)
              | None when List.mem field_codec ["listCodec"; "setCodec"; "dictCodec"] ->
                Printf.bprintf body
                  "\tteslRaw%s, teslErr%s := teslrt.JSONFieldValue(teslJSON, %S)\n\tif teslErr%s != nil {\n\t\treturn teslrt.RejectShape[%s](teslErr%s.Error())\n\t}\n\t%s, teslDecodeErr%s := %s(teslRaw%s)\n\tif teslDecodeErr%s != nil {\n\t\treturn teslrt.RejectShape[%s](teslDecodeErr%s.Error())\n\t}\n"
                  suffix suffix json_key suffix go_type_name suffix
                  binder suffix
                  (json_value_decoder ~package ~loc:codec.loc
                     ~what:(Printf.sprintf "%s.%s" type_name field_name) (field_type field_name))
                  suffix suffix go_type_name suffix
              | None ->
                (* A nested codec decodes the field's own JSON value. *)
                Printf.bprintf body
                  "\tteslRaw%s, teslErr%s := teslrt.JSONFieldValue(teslJSON, %S)\n\tif teslErr%s != nil {\n\t\treturn teslrt.RejectShape[%s](teslErr%s.Error())\n\t}\n\tteslNested%s := %s(teslRaw%s)\n\tif !teslNested%s.OK() {\n\t\treturn teslrt.Reject[%s](teslNested%s.Status(), teslNested%s.Message())\n\t}\n\t%s, _ := teslNested%s.Value()\n"
                  suffix suffix json_key suffix go_type_name suffix
                  suffix (codec_decode_ref field_codec) suffix
                  suffix go_type_name suffix suffix
                  binder suffix);
             (* `via` CHAINS: each checker runs on the value the previous one accepted.  The
                result binder is numbered by POSITION in the chain — a second `via` on the
                same field redeclared the first one's name, which does not compile. *)
             List.iteri (fun via_index checker ->
               let signature = match Hashtbl.find_opt signatures checker with
                 | Some signature -> signature
                 | None -> unsupported codec.loc
                   "Go backend codec `%s` cannot resolve check `%s`" type_name checker
               in
               let suffix =
                 if via_index = 0 then suffix
                 else Printf.sprintf "%s%d" suffix (via_index + 1) in
               Printf.bprintf body
                 "\tteslChecked%s := %s(%s)\n\tif !teslChecked%s.OK() {\n\t\treturn teslrt.Reject[%s](teslChecked%s.Status(), teslChecked%s.Message())\n\t}\n\t%s, _ = teslChecked%s.Value()\n"
                 suffix (qualified signature.sig_owner signature.go_name) binder
                 suffix go_type_name suffix suffix binder suffix) via;
             (* Whether the binder holds the field's own type or its BASE value: a primitive
                codec answers a `string`/`Int`, so a newtype field still needs its constructor;
                a nested codec already answers the field's type. *)
             let base_value = field_codec_kind field_codec <> None in
             assignments := (field_name, binder, base_value) :: !assignments
           | DecodeDefault { field_name; default_lit; _ } ->
             let binder = Printf.sprintf "teslField%s" (go_ident ~exported:true field_name) in
             let rendered = match default_lit, field_type field_name with
               | LInt n, _ -> Printf.sprintf "teslrt.FromInt64(%d)" n
               | LBool b, _ -> if b then "true" else "false"
               | LString text, _ -> Printf.sprintf "%S" text
               | LFloat f, _ -> emit_float_literal f
               | _ -> unsupported codec.loc
                 "Go backend codec `%s` default for `%s` is not a literal" type_name field_name
             in
             Printf.bprintf body "\t%s := %s\n" binder rendered;
             assignments := (field_name, binder, true) :: !assignments
           | DecodeCrossCheck _ -> ()) alternative;
         (* The record is built before any cross-check, which takes the whole value. *)
         let assignments = List.rev !assignments in
         (* A field whose TYPE is a newtype decoded its BASE value — a primitive codec answers
            a `string`/`Int`, never the wrapper — so the constructor is applied here, at
            construction, and NOT before.  That ordering is the fix a Racket-side soundness bug
            forced (`compiler/test/test_secret_surface.ml` ratchets it): wrapping first meant a
            `via` checker declared `(text: String)` was handed the wrapped secret, so an
            arbitrary checker could reach the plaintext under a signature promising it never saw
            more than a String — and echo it into a client-facing 400.  `via` therefore runs on
            the raw value above, and only a successful check's value is wrapped. *)
         let wrapped field binder =
           match field_type field with
           | TNewtype info when info.secret ->
             Printf.sprintf "%s{Value: teslrt.MakeSecret(%s)}" (go_type (TNewtype info)) binder
           | TNewtype info -> Printf.sprintf "%s{Value: %s}" (go_type (TNewtype info)) binder
           | _ -> binder
         in
         Printf.bprintf body "\tteslDecoded := %s{" go_type_name;
         Buffer.add_string body
           (String.concat ", " (List.map (fun (field, binder, base_value) ->
              Printf.sprintf "%s: %s" (field_go field)
                (if base_value then wrapped field binder else binder)) assignments));
         Buffer.add_string body "}\n";
         List.iter (fun entry ->
           match entry with
           | DecodeCrossCheck { checker; _ } ->
             let signature = match Hashtbl.find_opt signatures checker with
               | Some signature -> signature
               | None -> unsupported codec.loc
                 "Go backend codec `%s` cannot resolve check `%s`" type_name checker
             in
             (* The cross-check receives the decoded FIELDS in declaration order — not the
                record — matching the call `emit_racket` generates.  Its result is used
                only for pass/fail: the record is built from the fields either way. *)
             Printf.bprintf body
               "\tteslCross := %s(%s)\n\tif !teslCross.OK() {\n\t\treturn teslrt.Reject[%s](teslCross.Status(), teslCross.Message())\n\t}\n"
               (qualified signature.sig_owner signature.go_name)
               (String.concat ", " (List.map (fun (_, binder, _) -> binder) assignments))
               go_type_name
           | _ -> ()) alternative;
         Buffer.add_string body "\treturn teslrt.Accept(teslDecoded)\n}\n") alternatives;
       (* The entry point tries each alternative in order and reports the LAST failure
          when none matches, matching first-success semantics. *)
       Printf.bprintf body "\nfunc %s(teslJSON any) teslrt.Check[%s] {\n"
         (codec_decode_name type_name) go_type_name;
       (match alternatives with
        | [] ->
          Printf.bprintf body "\treturn teslrt.Reject[%s](400, \"no decode alternative\")\n"
            go_type_name
        | _ ->
          (* Alternative order follows Racket's registry loop exactly: a SHAPE mismatch
             moves on, a VALIDATION failure is remembered (the FIRST one wins) and the
             search continues, since a later alternative may still succeed.  Reporting
             the last failure instead would replace a real 400 from the first
             alternative's check with the last alternative's "missing field" complaint. *)
          Printf.bprintf body "\tvar teslFirstFailure teslrt.Check[%s]\n\tteslHaveFailure := false\n"
            go_type_name;
          List.iteri (fun index _ ->
            Printf.bprintf body
              "\tteslResult%d := %s(teslJSON)\n\tif teslResult%d.OK() {\n\t\treturn teslResult%d\n\t}\n\tif !teslResult%d.IsShapeMismatch() && !teslHaveFailure {\n\t\tteslFirstFailure = teslResult%d\n\t\tteslHaveFailure = true\n\t}\n"
              index (codec_alt_name type_name index) index index index index) alternatives;
          Printf.bprintf body
            "\tif teslHaveFailure {\n\t\treturn teslFirstFailure\n\t}\n\treturn teslrt.Reject[%s](400, \"no decode alternative matched\")\n"
            go_type_name);
       Buffer.add_string body "}\n")) codecs;
  (* ── Derived decoders ───────────────────────────────────────────────────────
     A request-body record needs no `codec` block: Racket decodes it generically from the
     record spec at run time (`dsl/types.rkt jsexpr->typed-value`), so the type alone is the
     contract. Go has no runtime type registry, so the equivalent decoder is EMITTED — and it
     has to be, because the dispatcher above already calls `Decode<T>JSON` for every body
     type. Without this the emitted package referenced a function nobody wrote: a fail-OPEN
     that produced uncompilable Go rather than a refusal.

     The rules are the generic decoder's, not a new dialect: the object's keys must be exactly
     the record's fields (an extra key is a 400, because silently ignoring unknown keys is how
     a typo'd field name becomes a silent default), a newtype decodes its base and is then
     wrapped, and a nested record recurses. A shape the generic decoder handles but this does
     not yet — an ADT's `{tag, fields}`, Dict, Set, Money — fails closed at emit. *)
  let derived_decoders = ref [] in
  let rec derive_decoder loc ty =
    match ty with
    | TRecord info when info.rec_owner = package
                        && not (List.mem info.rec_tesl_name !current_codec_types) ->
      if not (List.mem info.rec_tesl_name !derived_decoders) then begin
        derived_decoders := info.rec_tesl_name :: !derived_decoders;
        (* Fields first: a nested record's decoder is emitted before the one that calls it,
           which also keeps a cycle from recursing forever (the name is claimed above). *)
        List.iter (fun (_, field_ty) -> derive_decoder loc field_ty) info.rec_fields;
        let go_ty = go_type ty in
        Printf.bprintf body
          "\n// %s is the DERIVED decoder for a record with no `codec` block: the type is the\n\
           // whole contract, exactly as it is on the Racket runtime's generic decode.\n\
           func %s(teslJSON any) teslrt.Check[%s] {\n"
          (codec_decode_name info.rec_tesl_name) (codec_decode_name info.rec_tesl_name) go_ty;
        Printf.bprintf body "\tteslFields, teslShapeErr := teslrt.DecodeObjectShape(teslJSON, %s, []string{%s})\n\tif teslShapeErr != nil {\n\t\treturn teslrt.RejectShape[%s](teslShapeErr.Error())\n\t}\n"
          (go_quote info.rec_tesl_name)
          (String.concat ", " (List.map (fun (name, _) -> go_quote name) info.rec_fields))
          go_ty;
        List.iter (fun (name, field_ty) ->
          let suffix = go_ident ~exported:true name in
          (* Every field decoder is a `func(any) (T, error)`, so a list composes over the
             element's own decoder without the emitter writing the loop. *)
          let value_decoder ty =
            json_value_decoder ~package ~loc
              ~what:(Printf.sprintf "%s.%s" info.rec_tesl_name name) ty
          in
          Printf.bprintf body
            "\tteslField%s, teslErr%s := %s(teslFields[%s])\n\tif teslErr%s != nil {\n\t\treturn teslrt.RejectShape[%s](teslErr%s.Error())\n\t}\n"
            suffix suffix (value_decoder field_ty) (go_quote name) suffix go_ty suffix)
          info.rec_fields;
        Printf.bprintf body "\treturn teslrt.Accept(%s{%s})\n}\n" go_ty
          (String.concat ", " (List.map (fun (name, _) ->
             Printf.sprintf "%s: teslField%s" (record_field_go_name name)
               (go_ident ~exported:true name)) info.rec_fields))
      end
    | _ -> ()
  in
  List.iter (fun (api : api_form) ->
    List.iter (fun (endpoint : api_endpoint) ->
      match endpoint.kind with
      | Http { body = Some (binding : binding); _ } ->
        derive_decoder endpoint.loc (type_of_type_expr types binding.type_expr)
      | _ -> ()) api.endpoints) apis;
  (* ── HTTP servers ───────────────────────────────────────────────────────── *)
  List.iter (fun (server : server_form) ->
    let api = match List.find_opt (fun (a : api_form) -> a.name = server.api_name) apis with
      | Some api -> api
      | None -> unsupported server.loc "Go backend cannot resolve api `%s`" server.api_name
    in
    (* SSE endpoints are a different transport: they carry no handler (there is no
       request/response pair to bind), and they are emitted as STREAMS below. *)
    let endpoints = List.filter (fun (ep : api_endpoint) ->
      match ep.kind with Http _ -> true | Sse _ -> false) api.endpoints in
    let sse_endpoints = List.filter (fun (ep : api_endpoint) ->
      match ep.kind with Sse _ -> true | Http _ -> false) api.endpoints in
    if List.length endpoints <> List.length server.handlers then
      unsupported server.loc
        "Go backend needs one handler per endpoint in `%s` (%d endpoint(s), %d handler(s))"
        server.api_name (List.length endpoints) (List.length server.handlers);
    let bound = List.combine endpoints server.handlers in
    List.iter (fun ((ep : api_endpoint), _) ->
      ignore ep) bound;
    let server_name = go_ident ~exported:true server.name in
    Printf.bprintf body "\nvar %s = teslrt.Server{\n\tRoutes: []teslrt.Route{\n" server_name;
    List.iter (fun ((ep : api_endpoint), handler) ->
      Printf.bprintf body "\t\t{Method: %S, Path: %S, Endpoint: %S},\n"
        (http_method_name ep.method_) ep.path handler) bound;
    (* An SSE route is a GET whose endpoint name is the PATH: it has no handler to name it
       after, and a path is what a subscriber addresses. *)
    List.iter (fun (ep : api_endpoint) ->
      Printf.bprintf body "\t\t{Method: \"GET\", Path: %S, Endpoint: %S},\n"
        ep.path ("sse:" ^ ep.path)) sse_endpoints;
    Buffer.add_string body "\t},\n\tHandlers: map[string]teslrt.HandlerFunc{\n";
    List.iter (fun ((endpoint : api_endpoint), handler) ->
      let endpoint_loc = endpoint.loc in
      let endpoint_path = endpoint.path in
      let endpoint_captures = endpoint.captures in
      let endpoint_auth = endpoint.auth in
      let endpoint_body = ep_body endpoint in
      let signature = match Hashtbl.find_opt signatures handler with
        | Some signature -> signature
        | None -> unsupported server.loc "Go backend cannot resolve handler `%s`" handler
      in
      (* The response goes through the result type's own codec, so the body bytes are the
         ones the codec layer already agrees with Racket on. *)
      let encoder = match signature.result with
        | TDict _ | TSet _ | TParam _ | TCheck _ | TFailure ->
          unsupported server.loc
            "Go backend cannot encode handler `%s`'s response type" handler
        | result -> value_encoder result
      in
      current_scope_in_hand := true;
      Printf.bprintf body
        "\t\t%S: func(teslScope *teslrt.RequestScope, teslRequest *http.Request) teslrt.Response {\n\t\t\t_ = teslScope\n"
        handler;
      (* Arguments are assembled in the handler's own parameter order: captures first (in
         path order), then the decoded body, matching how the endpoint declares them. *)
      let arguments = ref [] in
      (* Auth runs FIRST, before captures and the body: a request that is not authenticated
         is rejected before anything else about it is examined.  Its result carries the
         proven value the handler's proof-annotated parameter requires; the proof itself
         erases, so what the handler receives is the value. *)
      (* The request body is read ONCE, before anything examines the request: an `auth` may
         verify a MAC over the RAW bytes (every webhook scheme does), and the decoder needs the
         same bytes — `teslRequest.Body` is a stream that can only be read once, so reading it
         twice gave the auth an empty body and made it verify a tag over "". Racket reads
         `request-post-data/raw` once for exactly this reason. *)
      let reads_body = endpoint_auth <> None || endpoint_body <> None in
      if reads_body then
        Buffer.add_string body
          (if endpoint_auth <> None then
             "\t\t\tteslBodyBytes, teslBodyErr := io.ReadAll(teslRequest.Body)\n\t\t\tif teslBodyErr != nil {\n\t\t\t\treturn teslrt.Fail(400, \"Missing JSON payload\")\n\t\t\t}\n\t\t\tteslBodyText := string(teslBodyBytes)\n"
           else
             "\t\t\tteslBodyBytes, teslBodyErr := io.ReadAll(teslRequest.Body)\n\t\t\tif teslBodyErr != nil {\n\t\t\t\treturn teslrt.Fail(400, \"Missing JSON payload\")\n\t\t\t}\n");
      (match endpoint_auth with
       | None -> ()
       | Some (auth : api_auth) ->
         let signature = match Hashtbl.find_opt signatures auth.via_fn with
           | Some signature -> signature
           | None -> unsupported endpoint_loc
             "Go backend cannot resolve auth function `%s`" auth.via_fn
         in
         let binder = local_ident auth.binding.name in
         (* An `auth` that may write a cookie (a sliding session renews one) takes the request
            scope like any other cookie-writing function. *)
         let scope_argument = if signature.sig_needs_scope then "teslScope, " else "" in
         Printf.bprintf body
           "\t\t\tteslAuth := %s(%steslrt.NewHttpRequest(teslRequest, teslBodyText))\n\t\t\tif !teslAuth.OK() {\n\t\t\t\treturn teslrt.Fail(teslAuth.Status(), teslAuth.Message())\n\t\t\t}\n\t\t\t%s, _ := teslAuth.Value()\n"
           (qualified signature.sig_owner signature.go_name) scope_argument binder;
         arguments := !arguments @ [binder]);
      List.iter (fun (capture : api_capture) ->
        let name = capture.binding.name in
        let suffix = go_ident ~exported:true name in
        (* The capturer names how the segment is parsed and, optionally, a CHECK that
           mints a proof on it — the same "prove before the body runs" rule auth follows,
           applied to a path segment. *)
        let parser, checker = match capture.via_fn with
          | "" -> (match capture.inline_codec with Some c -> c | None -> "stringCodec"),
                  capture.inline_check
          | via ->
            (match List.find_opt (fun (c : capture_form) -> c.name = via) capturers with
             | Some form -> form.parser, form.checker
             | None -> unsupported endpoint_loc
               "Go backend cannot resolve capturer `%s`" via)
        in
        (* The declared type and the codec have to agree: the segment arrives as text and
           the parser is what turns it into the capture's type. *)
        let captured_type = type_of_type_expr types capture.binding.type_expr in
        (match parser, captured_type with
         | "stringCodec", TString -> ()
         | "intCodec", TInt -> ()
         | "stringCodec", _ | "intCodec", _ -> unsupported endpoint_loc
           "Go backend path capture `%s` does not match its `%s`" name parser
         | _ -> unsupported endpoint_loc
           "Go backend supports `stringCodec` and `intCodec` path captures only for now \
            (`%s`)" parser);
        (* A String capture IS the segment, so it binds the name directly.  An `intCodec` one
           has to be parsed first, and the raw text gets its own binder so the capture's name
           still holds the capture's declared type. *)
        let raw_binder =
          if parser = "intCodec" then "teslRaw" ^ suffix else local_ident name in
        Printf.bprintf body
          "\t\t\t%s, teslFound%s := teslrt.PathParam(%S, teslRequest.URL.Path, %S)\n\t\t\tif !teslFound%s {\n\t\t\t\treturn teslrt.Fail(404, \"not found\")\n\t\t\t}\n"
          raw_binder suffix endpoint_path name suffix;
        (* A segment that is not an integer is the CLIENT's error, not a missing route: the
           path shape matched and the value in it did not. *)
        if parser = "intCodec" then
          Printf.bprintf body
            "\t\t\tteslSegment%s := teslrt.IntegerSegment(%s)\n\t\t\tif !teslSegment%s.OK() {\n\t\t\t\treturn teslrt.Fail(teslSegment%s.Status(), teslSegment%s.Message())\n\t\t\t}\n\t\t\t%s, _ := teslSegment%s.Value()\n"
            suffix raw_binder suffix suffix suffix (local_ident name) suffix;
        (match checker with
         | None -> ()
         | Some check_fn ->
           let signature = match Hashtbl.find_opt signatures check_fn with
             | Some signature -> signature
             | None -> unsupported endpoint_loc
               "Go backend cannot resolve capture check `%s`" check_fn
           in
           (* A capturer's `via` names either a CHECK — which may reject the segment, and then
              the request is answered with the status it chose — or a plain `fn` that NORMALISES
              it (`parseUserId`).  Racket tells them apart the same way: it calls the function
              and only treats a `check-fail` as a rejection. *)
           (match signature.result with
            | TCheck _ ->
              Printf.bprintf body
                "\t\t\tteslCaptured%s := %s(%s)\n\t\t\tif !teslCaptured%s.OK() {\n\t\t\t\treturn teslrt.Fail(teslCaptured%s.Status(), teslCaptured%s.Message())\n\t\t\t}\n\t\t\t%s, _ = teslCaptured%s.Value()\n"
                suffix (qualified signature.sig_owner signature.go_name) (local_ident name)
                suffix suffix suffix (local_ident name) suffix
            | _ ->
              Printf.bprintf body "\t\t\t%s = %s(%s)\n"
                (local_ident name) (qualified signature.sig_owner signature.go_name)
                (local_ident name)));
        arguments := !arguments @ [local_ident name]) endpoint_captures;
      (match endpoint_body with
       | None -> if not reads_body then Buffer.add_string body "\t\t\t_ = teslRequest\n"
       | Some (binding : binding) ->
         (* A SCALAR body is the whole JSON value — `body runId: String` receives the string
            that was sent, not a field of an object — so it decodes through the scalar reader
            rather than a codec.  Racket does the same: its generic decoder reads the body
            value at the declared type. *)
         let body_type = type_of_type_expr types binding.type_expr in
         let scalar_reader = match body_type with
           | TString -> Some "teslrt.DecodeStringValue"
           | TInt -> Some "teslrt.DecodeIntValue"
           | TBool -> Some "teslrt.DecodeBoolValue"
           | TFloat -> Some "teslrt.DecodeFloatValue"
           | _ -> None
         in
         (* A LIST body — `body ids: List String` — is the JSON array itself, decoded
            element by element through the element's own reader.  The `ForAll` proof its
            annotation may carry erases like every other, so what arrives is the list. *)
         let list_reader = match body_type with
           | TList TString -> Some "teslrt.DecodeStringValue"
           | TList TInt -> Some "teslrt.DecodeIntValue"
           | TList TBool -> Some "teslrt.DecodeBoolValue"
           | TList TFloat -> Some "teslrt.DecodeFloatValue"
           | TList (TRecord info) -> Some (codec_decode_ref info.rec_tesl_name)
           | _ -> None
         in
         let decoder = match body_type, scalar_reader, list_reader with
           | _, Some _, _ -> ""
           | _, None, Some _ -> ""
           | TRecord info, None, None -> codec_decode_ref info.rec_tesl_name
           | TAdt (info, _), None, None -> codec_decode_ref info.adt_tesl_name
           | _ -> unsupported endpoint_loc
             "Go backend request body needs a type with a codec"
         in
         (* The two failure strings are the ones the Racket server sends, so a client sees
            the same 400 either way. *)
         (match scalar_reader, list_reader with
          | None, Some element ->
            (* An element decoder that answers a `Check` (a record's codec) is adapted to the
               `(value, error)` shape `DecodeListValue` walks with, so one loop covers both
               kinds of element. *)
            let element_reader = match body_type with
              | TList (TRecord info) ->
                Printf.sprintf "teslrt.CheckedDecoder(%s)" (codec_decode_ref info.rec_tesl_name)
              | _ -> element
            in
            Printf.bprintf body
              "\t\t\tteslParsed, teslParseErr := teslrt.ParseJSON(teslBodyBytes)\n\t\t\tif teslParseErr != nil {\n\t\t\t\treturn teslrt.Fail(400, \"Malformed JSON payload\")\n\t\t\t}\n\t\t\tteslBody, teslBodyDecodeErr := teslrt.DecodeListValue(teslParsed, %s)\n\t\t\tif teslBodyDecodeErr != nil {\n\t\t\t\treturn teslrt.Fail(400, teslBodyDecodeErr.Error())\n\t\t\t}\n"
              element_reader
          | Some reader, _ ->
            Printf.bprintf body
              "\t\t\tteslParsed, teslParseErr := teslrt.ParseJSON(teslBodyBytes)\n\t\t\tif teslParseErr != nil {\n\t\t\t\treturn teslrt.Fail(400, \"Malformed JSON payload\")\n\t\t\t}\n\t\t\tteslBody, teslBodyDecodeErr := %s(teslParsed)\n\t\t\tif teslBodyDecodeErr != nil {\n\t\t\t\treturn teslrt.Fail(400, teslBodyDecodeErr.Error())\n\t\t\t}\n"
              reader
          | None, None ->
            Printf.bprintf body
              "\t\t\tteslParsed, teslParseErr := teslrt.ParseJSON(teslBodyBytes)\n\t\t\tif teslParseErr != nil {\n\t\t\t\treturn teslrt.Fail(400, \"Malformed JSON payload\")\n\t\t\t}\n\t\t\tteslDecoded := %s(teslParsed)\n\t\t\tif !teslDecoded.OK() {\n\t\t\t\treturn teslrt.Fail(teslDecoded.Status(), teslDecoded.Message())\n\t\t\t}\n\t\t\tteslBody, _ := teslDecoded.Value()\n"
              decoder);
         arguments := !arguments @ ["teslBody"]);
      (* A handler that may write cookies receives the scope the dispatcher created. *)
      let call_arguments =
        if signature.sig_needs_scope then "teslScope" :: !arguments else !arguments in
      Printf.bprintf body
        "\t\t\treturn teslrt.Response{Status: 200, Body: %s(%s(%s))}\n\t\t},\n"
        encoder (qualified signature.sig_owner signature.go_name)
        (String.concat ", " call_arguments)) bound;
    Buffer.add_string body "\t},\n";
    (* ── SSE streams ─────────────────────────────────────────────────────────
       A stream owns its response for the life of the connection, so it is not a
       `HandlerFunc`.  What runs BEFORE the stream opens is the same gate a request meets:
       the auth check, then every declared capture check — a subscriber must not be able to
       reach an entity's events by asking for a path a request would be refused. *)
    if sse_endpoints <> [] then begin
      Buffer.add_string body "\tStreams: map[string]teslrt.StreamFunc{\n";
      List.iter (fun (endpoint : api_endpoint) ->
        let endpoint_loc = endpoint.loc in
        let endpoint_path = endpoint.path in
        let channel_name = match ep_subscribes endpoint with
          | [name] -> name
          | [] -> unsupported endpoint_loc
            "Go backend needs an `sse` route to subscribe to a channel"
          | _ -> unsupported endpoint_loc
            "Go backend supports one channel per `sse` route"
        in
        let info = channel_of_name endpoint_loc channel_name in
        Printf.bprintf body
          "\t\t%S: func(teslWriter http.ResponseWriter, teslRequest *http.Request) {\n"
          ("sse:" ^ endpoint_path);
        (match endpoint.auth with
         | None -> ()
         | Some (auth : api_auth) ->
           let signature = match Hashtbl.find_opt signatures auth.via_fn with
             | Some signature -> signature
             | None -> unsupported endpoint_loc
               "Go backend cannot resolve auth function `%s`" auth.via_fn
           in
           (* A stream has no response to attach a cookie to, so a sliding-session `auth`
              writes into a scope nothing sends — the check still runs, which is the part
              that decides whether this subscriber may listen at all. *)
           let scope_argument =
             if signature.sig_needs_scope then "teslrt.NewRequestScope(), " else "" in
           Printf.bprintf body
             "\t\t\tteslAuth := %s(%steslrt.NewHttpRequest(teslRequest, \"\"))\n\t\t\tif !teslAuth.OK() {\n\t\t\t\thttp.Error(teslWriter, teslAuth.Message(), teslAuth.Status())\n\t\t\t\treturn\n\t\t\t}\n"
             (qualified signature.sig_owner signature.go_name) scope_argument);
        List.iter (fun (capture : api_capture) ->
          let name = capture.binding.name in
          let suffix = go_ident ~exported:true name in
          let parser, checker = match capture.via_fn with
            | "" -> (match capture.inline_codec with Some c -> c | None -> "stringCodec"),
                    capture.inline_check
            | via ->
              (match List.find_opt (fun (c : capture_form) -> c.name = via) capturers with
               | Some form -> form.parser, form.checker
               | None -> unsupported endpoint_loc
                 "Go backend cannot resolve capturer `%s`" via)
          in
          if parser <> "stringCodec" then unsupported endpoint_loc
            "Go backend supports `stringCodec` path captures only for now (`%s`)" parser;
          (match type_of_type_expr types capture.binding.type_expr with
           | TString -> ()
           | _ -> unsupported endpoint_loc
             "Go backend supports String path captures only for now");
          Printf.bprintf body
            "\t\t\tteslSegment%s, teslFound%s := teslrt.PathParam(%S, teslRequest.URL.Path, %S)\n\t\t\tif !teslFound%s {\n\t\t\t\thttp.Error(teslWriter, \"not found\", 404)\n\t\t\t\treturn\n\t\t\t}\n"
            suffix suffix endpoint_path name suffix;
          (match checker with
           | None -> Printf.bprintf body "\t\t\t_ = teslSegment%s\n" suffix
           | Some check_fn ->
             let signature = match Hashtbl.find_opt signatures check_fn with
               | Some signature -> signature
               | None -> unsupported endpoint_loc
                 "Go backend cannot resolve capture check `%s`" check_fn
             in
             (* Same two shapes as the request path: a CHECK may refuse the subscription, a
                plain `fn` only normalises the segment. *)
             (match signature.result with
              | TCheck _ ->
                Printf.bprintf body
                  "\t\t\tteslCaptured%s := %s(teslSegment%s)\n\t\t\tif !teslCaptured%s.OK() {\n\t\t\t\thttp.Error(teslWriter, teslCaptured%s.Message(), teslCaptured%s.Status())\n\t\t\t\treturn\n\t\t\t}\n"
                  suffix (qualified signature.sig_owner signature.go_name) suffix
                  suffix suffix suffix
              | _ ->
                Printf.bprintf body "\t\t\t_ = %s(teslSegment%s)\n"
                  (qualified signature.sig_owner signature.go_name) suffix)))
           endpoint.captures;
        let stream = match ep_subscribe_key endpoint with
          | Some (SubscribeKeyLiteral key) ->
            Printf.sprintf "teslrt.SseStream(%s, %s)"
              (qualified info.ch_owner info.ch_go_var) (go_quote key)
          | Some (SubscribeKeyParam param) ->
            Printf.sprintf "teslrt.SseStreamParam(%s, %S, %S)"
              (qualified info.ch_owner info.ch_go_var) endpoint_path param
          (* No key argument: every connection lands on the one key the declaration has,
             which is the empty string a keyless `publish` uses. *)
          | None ->
            Printf.sprintf "teslrt.SseStream(%s, \"\")"
              (qualified info.ch_owner info.ch_go_var)
        in
        Printf.bprintf body "\t\t\t%s(teslWriter, teslRequest)\n\t\t},\n" stream)
        sse_endpoints;
      Buffer.add_string body "\t},\n"
    end;
    (* ── The runtime-owned SSO routes ─────────────────────────────────────
       An `sso "<seg>" connection <fn> onIdentity <fn>` clause mints /auth/<seg>/login and
       /auth/<seg>/callback.  The connection and the session key are THUNKS: both read the
       environment, which a test sets per case, so reading them at boot would freeze the
       first value the process ever saw.  `onIdentity` is app code the RUNTIME owns the call
       to — it runs after the identity is verified and the domain rules applied. *)
    if server.sso_clauses <> [] then begin
      let session_key_env = match server.sso_session_key_env with
        | Some name -> name
        | None -> unsupported server.loc
          "Go backend needs `sessionKey \"ENV_VAR\"` on a server that declares `sso`"
      in
      let public_origin = match server.public_origin with
        | Some (POLiteral origin) -> go_quote origin
        (* `publicOrigin fromEnv "VAR"`: read where it is used, not baked in, so a
           deployment can move without a rebuild. *)
        | Some (POEnv name) -> Printf.sprintf "teslrt.EnvString(%s, \"\")" (go_quote name)
        | None -> unsupported server.loc
          "Go backend needs `publicOrigin` on a server that declares `sso`: it is the \
           redirect_uri's base"
      in
      let after_login = match server.after_login with
        | Some path -> path
        | None -> "/"
      in
      Buffer.add_string body "\tSsoRoutes: []teslrt.SsoRoute{\n";
      List.iter (fun (segment, connection_fn, on_identity_fn) ->
        let resolve name what = match Hashtbl.find_opt signatures name with
          | Some signature -> qualified signature.sig_owner signature.go_name
          | None -> unsupported server.loc
            "Go backend cannot resolve the `sso` %s function `%s`" what name
        in
        (* The keys are ALIGNED as gofmt aligns a run of them — `PublicOrigin:` is the
           longest, so every value starts in its column.  Emitting them unaligned is a file
           gofmt would rewrite, which the gate reads as an emitter bug. *)
        let field name value =
          Printf.bprintf body "\t\t\t%-13s %s,\n" (name ^ ":") value in
        Buffer.add_string body "\t\t{\n";
        field "Segment" (Printf.sprintf "%S" segment);
        field "Connection" (resolve connection_fn "connection");
        field "OnIdentity" (resolve on_identity_fn "onIdentity");
        field "SessionKey"
          (Printf.sprintf "func() teslrt.Secret { return teslrt.RequireSecret(%s) }"
             (go_quote session_key_env));
        field "PublicOrigin" public_origin;
        field "AfterLogin" (Printf.sprintf "%S" after_login);
        Buffer.add_string body "\t\t},\n")
        server.sso_clauses;
      Buffer.add_string body "\t},\n"
    end;
    Buffer.add_string body "}\n";
    (* ── The server-wide settings, applied at PACKAGE LOAD ──────────────────
       `publicOrigin` turns on the Host check and is the redirect_uri's base; `sessionPolicy`
       decides the session cookie's Max-Age.  Both are set in an `init` rather than in
       `main`, because that is where Racket sets them — a top-level side effect at module
       load — and an api-test never runs `main`.  A server that declares neither emits
       nothing here, so a file without them is byte-identical to before. *)
    let boot_settings =
      (match server.public_origin with
       | Some (POLiteral origin) ->
         [Printf.sprintf "\tteslrt.SetPublicOriginValue(%s)" (go_quote origin)]
       (* The env form is read ONCE, here, and never per request: a public origin derived
          from a request is the thing it exists to guard against. *)
       | Some (POEnv name) ->
         [Printf.sprintf "\tteslrt.SetPublicOriginValue(teslrt.RequireEnv(%s))" (go_quote name)]
       | None -> [])
      @ (match server.session_policy with
         | Some policy ->
           [Printf.sprintf "\tteslrt.SetSessionPolicy(teslrt.SessionPolicyTTL(%s))"
              (go_quote policy)]
         | None -> [])
    in
    if boot_settings <> [] then
      Printf.bprintf body "\nfunc init() {\n%s\n}\n" (String.concat "\n" boot_settings);
    current_scope_in_hand := false) servers;
  (* Comparator helpers the body referenced, in name order so the output is
     deterministic. *)
  Hashtbl.to_seq pending_helpers
  |> List.of_seq
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  |> List.iter (fun (name, source) ->
    Hashtbl.replace module_helpers name ();
    Buffer.add_string body source);
  (* A private Tesl function that nothing calls is legal Tesl, and the Racket backend
     emits it, so refusing to emit Go for the whole module over it was a divergence with
     no upside — a teaching file that declares a function to illustrate it could not be
     compiled at all.  It is emitted, and referenced once here because Go's `unused`
     linter (staticcheck U1000) rejects an uncalled unexported function, and a lint
     finding on emitted code is an emitter bug by contract. *)
  (match List.sort String.compare unreachable with
   | [] -> ()
   | names ->
     Buffer.add_string body
       "\n// Declared in Tesl but not called within this module.  Tesl permits an unused\n\
        // private declaration; Go's linters do not, so these references keep them.\n";
     (match names with
      | [single] -> Printf.bprintf body "var _ = %s\n" single
      | names ->
        Buffer.add_string body "var (\n";
        List.iter (fun name -> Printf.bprintf body "\t_ = %s\n" name) names;
        Buffer.add_string body ")\n"));
  let body = Buffer.contents body in
  let imports =
    (if contains_go_code body "strconv." then ["strconv"] else [])
    (* A Float literal that Go has no syntax for — negative zero, an infinity, a NaN —
       renders as a `math` call, so the literal itself pulls the import in. *)
    @ (if contains_go_code body "math." then ["math"] else [])
    (* A server's handler adapters take an `*http.Request`. *)
    @ (if contains_go_code body "http.Request" then ["net/http"] else [])
    @ (if contains_go_code body "io.ReadAll" then ["io"] else [])
    (* A derived decoder turns a nested record's rejection into an `error`. *)
    @ (if contains_go_code body "errors.New" then ["errors"] else [])
    (* A Postgres-backed entity's row SCANNER names the driver's own types: a row handle to
       scan from, and the NUMERIC carrier an unbounded `Int` column travels in. *)
    @ (if contains_go_code body "pgx.CollectableRow" || contains_go_code body "pgx.Row"
       then ["github.com/jackc/pgx/v5"] else [])
    @ (if contains_go_code body "pgtype." then ["github.com/jackc/pgx/v5/pgtype"] else [])
    @ (if contains_go_code body "teslrt." then [module_path ^ "/internal/teslrt"] else [])
    (* Only packages the emitted body actually references: an unused import is a Go
       compile error, and a Tesl module may import names it only uses in a type
       annotation, or import facts that erase entirely. *)
    @ List.filter_map (fun dependency ->
        if contains_go_code body (dependency ^ ".") then
          Some (module_path ^ "/internal/" ^ dependency)
        else None)
        (List.sort String.compare imported_packages) in
  let header = Printf.sprintf "package %s\n%s" package (import_block imports) in
  header ^ body

let test_source ?(imported_packages=[]) ?(api_tests=[]) ?(load_tests=[]) module_path package
    signatures (tests : test_form list) =
  (* `pending_helpers` is cleared so the test file emits only what IT introduces, but
     `helper_names` is NOT: the two files are one Go package, and restarting the numbering
     minted a name module.go had already used for a different helper.  `module_helpers` then
     suppressed the duplicate definition and the test file silently called the module's
     function — `hasField "body" job` reached an encoder written for another type, which Go
     caught only because the two types differ.  Keeping the numbering monotonic makes a
     repeated name mean the same helper and nothing else. *)
  Hashtbl.reset pending_helpers;
  let body = Buffer.create 1024 in
  (* Numbers the operand bindings a comparison introduces, unique across the file. *)
  let expect_operand = ref 0 in
  (* ── Per-test isolation ────────────────────────────────────────────────────
     Every test block starts from empty stores, which is what Racket's
     `call-with-fresh-memory-db` gives every `test`/`api-test` body.  Go runs a package's
     tests in one process and (absent t.Parallel, which emitted tests never use) one at a
     time, so without this the second block would see the first block's rows, jobs and HTTP
     stubs — the exact leak the Racket side was fixed for, where one api-test saw another's
     seed and answered 200 instead of 404.
     Tables and queues of IMPORTED packages are reset too: a `database` block in another
     module is where that leak actually bit, and here the owning package is known rather than
     having to be recovered from a runtime registry. *)
  let reset_calls =
    let owned owner = owner = package || List.mem owner imported_packages in
    match !current_types with
    | None -> []
    | Some types ->
      let tables =
        Hashtbl.to_seq_values types.entities
        |> List.of_seq
        (* Only an entity some `database` block NAMES: Racket clears the stores of REGISTERED
           databases, and an entity in no declaration is in none of them, so its rows survive
           from one test block to the next.  Truncating it here made the same program's tests
           pass on Go and fail on Racket — a file with no `database` declaration shares one
           store on purpose, and a corpus lesson relies on it. *)
        |> List.filter (fun info -> owned info.ent_owner && info.ent_in_database)
        |> List.map (fun info ->
             Printf.sprintf "teslrt.TableTruncate(%s)"
               (qualified info.ent_owner info.ent_table_var))
      and queues =
        Hashtbl.to_seq_values types.queues
        |> List.of_seq
        |> List.filter (fun info -> owned info.qu_owner)
        |> List.map (fun info ->
             Printf.sprintf "teslrt.ResetQueue(%s)" (qualified info.qu_owner info.qu_go_var))
      (* A CACHE and an email OUTBOX are reset for the same reason the tables are: one block's
         entries must not be another's.  Racket resets both too — `call-with-fresh-memory-db`
         clears them from the process-wide registry, which this slice fixed after the oracle
         caught the two backends disagreeing about what a second block sees. *)
      and caches =
        Hashtbl.to_seq_values types.caches
        |> List.of_seq
        |> List.filter (fun info -> owned info.ca_owner)
        |> List.map (fun info ->
             Printf.sprintf "teslrt.CacheReset(%s)" (qualified info.ca_owner info.ca_go_var))
      and outboxes =
        Hashtbl.to_seq_values types.emails
        |> List.of_seq
        |> List.filter (fun info -> owned info.em_owner)
        |> List.map (fun info ->
             Printf.sprintf "teslrt.ResetOutbox(%s)" (qualified info.em_owner info.em_go_var))
      (* A channel's LISTENERS are per-block state on both backends: Racket's api-test
         cleanups unregister the block's subscription when it ends, and the emitted block
         closes its stream at the same point (the `defer` at the subscribe).  Clearing the
         registry here covers a listener no `subscribe` opened. *)
      and channels =
        Hashtbl.to_seq_values types.channels
        |> List.of_seq
        |> List.filter (fun info -> owned info.ch_owner)
        |> List.map (fun info ->
             Printf.sprintf "teslrt.ResetChannel(%s)" (qualified info.ch_owner info.ch_go_var))
      in
      (* The stub table is only reset when the module can stub at all: `stubHttp` is in
         `signatures` exactly when `Tesl.ApiTest` exposed it. *)
      let stubs =
        if Hashtbl.mem signatures "stubHttp" || Hashtbl.mem signatures "httpCallCount"
           || Hashtbl.mem signatures "httpCalled" || Hashtbl.mem signatures "httpLastBody"
        then ["teslrt.ResetHttpStubs()"] else []
      in
      (* Recorded signals are per-process state too: one block's counter must not be another's. *)
      let telemetry =
        if Hashtbl.mem signatures "counter" || Hashtbl.mem signatures "histogram"
           || Hashtbl.mem signatures "gauge"
        then ["teslrt.ResetTelemetry()"] else []
      in
      List.sort_uniq String.compare (tables @ queues @ caches @ outboxes @ channels)
      @ stubs @ telemetry
  in
  let emit_reset () =
    if reset_calls <> [] then Buffer.add_string body "\tteslResetTestState()\n"
  in
  (* A `property` block's repetition count, from the test header's `with N runs` (200 when it
     says nothing, which is Racket's default).  A ref because the statement emitter is one
     closure shared by every block. *)
  let property_runs = ref 200 in
  (* The generator for one property parameter, by TYPE — the same values Racket's
     `random_expr_for_type` produces, so a property searches the same space on both backends.
     A type Racket has no generator for falls back to `0` there; here it is refused, because a
     property that ran 200 times over the same wrong-typed value would report success without
     having tested anything. *)
  let rec property_generator loc ty =
    match ty with
    | TInt -> "teslrt.PropInt()"
    | TBool -> "teslrt.PropBool()"
    | TString -> "teslrt.PropString()"
    | TList element ->
      Printf.sprintf "teslrt.PropList(func() %s { return %s })"
        (go_type element) (property_generator loc element)
    | TAdt (info, [element]) when info.adt_tesl_name = "Maybe" ->
      Printf.sprintf "teslrt.PropMaybe(func() %s { return %s })"
        (go_type element) (property_generator loc element)
    (* A RECORD generates fieldwise, which is what Racket does — and a record whose fields
       carry PROOF annotations is refused instead: Racket has proof-aware generators there
       (`IsPositive` draws a positive), and a fieldwise draw would hand the property a value
       its own annotation says is impossible. *)
    | TRecord info ->
      (* A field carrying a PROOF draws from the range the predicate admits — the same three
         Racket has proof-aware generators for, over the same ranges, so a property searches
         the same space on both backends.  Any other predicate falls back to the plain draw
         and the proof is not fabricated: what makes it true is the checker. *)
      let proofs = Option.value (Hashtbl.find_opt current_field_proofs info.rec_tesl_name)
        ~default:[] in
      let field_generator name field_ty =
        match List.assoc_opt name proofs, field_ty with
        | Some predicate, TInt ->
          (match String.lowercase_ascii predicate with
           | "ispositive" -> "teslrt.PropPositiveInt()"
           | "isnonnegative" | "nonnegative" | "non_negative" -> "teslrt.PropNonNegativeInt()"
           | "isnonzero" | "nonzero" | "non_zero" -> "teslrt.PropNonZeroInt()"
           | _ -> property_generator loc field_ty)
        | _ -> property_generator loc field_ty
      in
      let drawn =
        Printf.sprintf "%s{%s}" (go_type ty)
          (String.concat ", " (List.map (fun (name, field_ty) ->
             Printf.sprintf "%s: %s" (record_field_go_name name)
               (field_generator name field_ty)) info.rec_fields))
      in
      (match Hashtbl.find_opt current_record_invariants info.rec_tesl_name with
       | None -> drawn
       | Some (checker, fields) ->
         (* A record-level invariant is a relation BETWEEN fields, which no fieldwise draw
            can guarantee — so the generator REDRAWS until the invariant's own check accepts,
            up to the 100 attempts Racket allows before it skips the iteration.  Hoisted into
            a named function: it captures nothing, and a loop written inline is a shape gofmt
            reflows. *)
         let signature = match Hashtbl.find_opt signatures checker with
           | Some signature -> signature
           | None -> unsupported loc
             "Go backend cannot resolve the invariant check `%s` of `%s`"
             checker info.rec_tesl_name
         in
         let go_ty = go_type ty in
         Printf.sprintf "%s()"
           (remember_helper_stmts ~prefix:"teslPropDraw"
              ~signature:(Printf.sprintf "() %s" go_ty)
              ~body:(Printf.sprintf
                "\tfor teslAttempt := 0; teslAttempt < 100; teslAttempt++ {\n\t\tteslCandidate := %s\n\t\tif %s(%s).OK() {\n\t\t\treturn teslCandidate\n\t\t}\n\t}\n\treturn %s\n"
                drawn (qualified signature.sig_owner signature.go_name)
                (String.concat ", " (List.map (fun field ->
                   Printf.sprintf "teslCandidate.%s" (record_field_go_name field)) fields))
                drawn)))
    | _ -> unsupported loc
      "Go backend has no property generator for `%s`" (go_type ty)
  in
  let rec emit_stmts env indent = function
    | [] -> ()
    | TsLet { name; value; loc; _ } :: rest ->
      let ty = let_binding_type signatures env name value
        (List.concat_map Ast.test_stmt_exprs rest) in
      Printf.bprintf body "%s{\n" indent;
      Buffer.add_string body (line_directive loc);
      let emitted = emit_expr ~expected:ty ~indent:(indent ^ "\t") signatures env value in
      (* `let _ = …` runs the statement and DISCARDS the result — Go's `_` is not a
         variable, so it can neither be declared with `:=` nor read back. *)
      if name = "_" then Printf.bprintf body "%s\t_ = %s\n" indent emitted
      else begin
        Printf.bprintf body "%s\t%s := %s\n" indent (local_ident name) emitted;
        Printf.bprintf body "%s\t_ = %s\n" indent (local_ident name);
        (* A SUBSCRIPTION holds a live connection and the test server behind it, so the block
           that opened it closes it — otherwise one block's stream would still be reading while
           the next runs, which is the same reason every other store is reset per block. *)
        if ty = TStream then
          Printf.bprintf body "%s\tdefer teslrt.UnsubscribeStream(%s)\n" indent
            (local_ident name)
      end;
      emit_stmts (if name = "_" then env else (name, ty) :: env) (indent ^ "\t") rest;
      Printf.bprintf body "%s}\n" indent
    | TsExpect { left; right; loc } :: rest ->
      (* Each side may be the one that supplies the other's type: `expect xs == []`
         and `expect [] == xs` both have to work, and an empty list literal (like a
         nullary generic constructor) carries no type of its own. *)
      let needs_expectation = function
        | EList { elems = []; _ } -> true
        | EConstructor { args = []; _ } -> true
        | _ -> false
      in
      (* A CHECK used as a value in a test — `expect UUID.validate v4 == v4` — is its
         checked value, and a rejection traps where it stands.  That is what `MustCheck`
         already does everywhere a check's value is consumed; the expectation just has to
         say the comparison is against the value rather than against the check. *)
      let value_of = function TCheck inner -> inner | ty -> ty in
      let left_ty = value_of (match right with
        | Some right when needs_expectation left ->
          type_of_arg signatures env (type_of_expr signatures env right) left
        | _ -> type_of_expr signatures env left)
      in
      (* The emitted guard is the NEGATION of the expectation, built structurally so
         no `!(a && b)` / `!(a == b)` shape reaches the lint gate. *)
      let failure_condition = match right with
        | None ->
          if left_ty <> TBool then unsupported loc "Go backend bare expect requires Bool";
          strip_outer_parens (emit_negated ~indent signatures env left)
        (* One side UNTYPED and the other a CONTAINER JSON template:
           `expect resp.body == [ { "text": "a" } ]` compares against JSON text, not against a
           Tesl value — an array of objects has no Tesl type to infer, so this is decided BEFORE
           the other side is typed.  A SCALAR literal is not routed here even though it is a
           valid template: `expect r.body.count == 3` has a perfectly good Tesl value on one
           side, and sending it through a JSON parse-and-render round trip would compare the two
           by their spelling rather than by their value. *)
        | Some right when (left_ty = TJson && template_json right <> None)
                          || (template_json left <> None
                              && (try type_of_expr signatures env right = TJson
                                  with Unsupported _ -> false)) ->
          let json_side, json = if left_ty = TJson
            then left, (match template_json right with Some json -> json | None -> assert false)
            else right, (match template_json left with Some json -> json | None -> assert false)
          in
          Printf.sprintf "!teslrt.JsonEqual(%s, teslrt.JsonParseBody(%s).JsonRaw())"
            (emit_expr ~indent signatures env json_side) (go_quote json)
        | Some right ->
          let right_ty = type_of_arg signatures env left_ty right in
          (* An UNTYPED api-test value on either side compares structurally through the
             runtime — `expect r.body.count == 3` is the shape these tests are written in, and
             the two sides are different Go types by construction. *)
          if left_ty = TJson || right_ty = TJson then begin
            let json_side, typed_side, typed_ty =
              if left_ty = TJson then left, right, right_ty else right, left, left_ty in
            let rec comparand ty emitted = match ty with
              | TJson -> emitted
              | TInt | TString | TBool | TFloat -> emitted
              | TNewtype info when not info.secret ->
                comparand info.base (Printf.sprintf "%s.Value" (selector_operand emitted))
              | TList (TInt | TString | TBool | TFloat) ->
                Printf.sprintf "teslrt.JsonListOf(%s)" emitted
              | _ -> unsupported loc
                "Go backend compares an api-test JSON value against a scalar, a newtype over \
                 one, or a list of those"
            in
            let encoded = comparand typed_ty
              (if typed_ty = TJson then emit_expr ~indent signatures env typed_side
               else emit_expr ~expected:typed_ty ~indent signatures env typed_side) in
            Printf.sprintf "!teslrt.JsonEqual(%s, %s)"
              (emit_expr ~indent signatures env json_side) encoded
          end else begin
          if left_ty <> right_ty then unsupported loc "Go backend expect operands have different types";
          (match left_ty, bool_literal_value left, bool_literal_value right with
           | TBool, Some expected, None ->
             if expected then strip_outer_parens (emit_negated ~indent signatures env right)
             else strip_outer_parens (emit_expr ~indent signatures env right)
           | TBool, None, Some expected ->
             if expected then strip_outer_parens (emit_negated ~indent signatures env left)
             else strip_outer_parens (emit_expr ~indent signatures env left)
           | _ ->
             if not (supports_equality left_ty) then unsupported loc
               "Go backend does not support `expect` equality on this type yet";
             (* Comparing a multi-variant value expands to a tag test plus a payload test,
                each mentioning the operand — so a non-trivial operand would be emitted
                THREE times, evaluating the whole expression three times and producing a
                line gofmt then reflows.  Anything that is not already a simple name is
                bound first. *)
             let simple expr = match expr with
               | EVar _ | ELit _ -> true
               | _ -> false
             in
             let bind label expr =
               let emitted = emit_expr ~expected:left_ty ~indent signatures env expr in
               if simple expr then emitted
               else begin
                 (* Numbered per comparison, not per indent: two `expect`s in one block
                    sit at the same indent and would redeclare the name. *)
                 let name = Printf.sprintf "tesl%s%d" label !expect_operand in
                 Printf.bprintf body "%s%s := %s\n" indent name emitted;
                 name
               end
             in
             incr expect_operand;
             let emitted_left = bind "Left" left in
             let emitted_right = bind "Right" right in
             strip_outer_parens (unequal_expr left_ty emitted_left emitted_right))
          end
      in
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%sif %s {\n%s\tteslT.Fatal(\"Tesl expectation failed\")\n%s}\n"
        indent failure_condition indent indent;
      emit_stmts env indent rest
    | TsExpr { e; loc } :: rest ->
      ignore (type_of_expr signatures env e);
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%s_ = %s\n" indent (emit_expr ~indent signatures env e);
      emit_stmts env indent rest
    | TsExpectFail { fn = EVar { name = "check"; _ } as check_head; arg; loc } :: rest ->
      (* `expectFail check (a && b) x` splits at the `check`, leaving the CONJUNCTION applied
         to the value as the argument — a shape nothing types on its own, since a check is
         not a function value.  Rebuilding the `check (a && b) x` application puts it back on
         the path that already knows what a combined check means, rather than teaching a
         second place. *)
      let combined = match arg with
        | EApp { fn = conjunction; arg = value; loc = app_loc }
          when (match check_conjunct_calls conjunction with
                | Some (_ :: _ :: _) -> true
                | _ -> false) ->
          delegated_check_call ~indent signatures env
            (EApp { fn = EApp { fn = check_head; arg = conjunction; loc = app_loc };
                    arg = value; loc = app_loc })
        | _ -> None
      in
      let emitted = match combined with
        | Some (call, _) -> call
        | None ->
          (match type_of_expr signatures env arg with
           | TCheck _ -> ()
           | _ -> unsupported loc "Go backend expectFail target is not a check");
          emit_expr ~indent signatures env arg
      in
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%sif (%s).OK() {\n%s\tteslT.Fatal(\"expected Tesl check failure\")\n%s}\n"
        indent emitted indent indent;
      emit_stmts env indent rest
    (* `expectFail (f x)` parenthesises the whole call, so the "function" is already an
       application and there are no further arguments — `expect_fail_call` answers it
       unchanged.  Both spellings reach the same emission. *)
    | TsExpectFail { fn; arg; loc } :: rest ->
      let call = expect_fail_call fn arg loc in
      (* `expectFail (fn () -> f x)` names a THUNK, and what is expected to fail is running
         it — emitting the closure itself would define a function and assert nothing.  So a
         zero-parameter lambda is unwrapped to its body, which is the expression the test is
         about. *)
      let call = match call with
        | ELambda { params = []; body; _ } -> body
        | _ -> call
      in
      (* `expectFail f ()` passes NO argument — `()` is the empty argument list, not a value —
         so what is left after the fold is the function's NAME.  A name is not what is
         expected to fail; RUNNING it is, so a zero-parameter function is applied here.  The
         parenthesised spelling `expectFail (f ())` already arrives applied. *)
      let call = match normalize_call_head call with
        | EVar { name; _ }
          when (match Hashtbl.find_opt signatures name with
                | Some { params = []; _ } -> true
                | _ -> false) ->
          EApp { fn = call; arg = EConstructor { name = "Unit"; args = []; loc }; loc }
        | _ -> call
      in
      (* A proof operation ERASES here, so it cannot be what fails: `expectFail (fn () ->
         detachFact …)` asserts a Racket RUNTIME restriction (its `detachFact` raises when a
         value carries more than one proof), and a program built on that assertion would run
         to completion on Go and fail the test.  Refusing says so, instead of emitting a test
         that cannot pass. *)
      let rec proof_operation expr =
        match normalize_call_head expr with
        | EVar { name = ("detachFact" | "introAnd" | "andLeft" | "andRight") as name; _ } ->
          Some name
        (* …including one reached through a call: the operation is in the CALLEE's body,
           which is where `multiProofDetach` puts it. *)
        | EVar { name; _ } when Hashtbl.mem proof_op_functions name ->
          Hashtbl.find_opt proof_op_functions name
        | _ -> Ast_visitor.fold_children (fun found child ->
                 match found with Some _ -> found | None -> proof_operation child) None expr
      in
      (match proof_operation call with
       | Some name -> unsupported loc
         "Go backend erases proofs, so `%s` cannot fail — this expectation is specific to \
          the Racket runtime" name
       | None -> ());
      let result_ty = type_of_expr signatures env call in
      (* A non-check target is wrapped in `teslExpectFailure(teslT, func() { … })`, so its
         value is emitted one level deeper than the statement — a multi-line expression laid
         out at the statement's indent is what gofmt then reflows. *)
      let emitted = match result_ty with
        | TCheck _ -> emit_expr ~indent signatures env call
        | _ -> emit_expr ~indent:(indent ^ "\t") signatures env call
      in
      Buffer.add_string body (line_directive loc);
      (match result_ty with
       | TCheck _ ->
         Printf.bprintf body "%sif (%s).OK() {\n%s\tteslT.Fatal(\"expected Tesl check failure\")\n%s}\n"
           indent emitted indent indent
       | TInt | TFloat | TQuantity | TString | TBool | TUnit | TNewtype _ | TRecord _
       | TAdt _ | TList _ | TDict _ | TSet _ | TParam _ | TFunc _ | TJson | TStream
       | TAnon ->
         Printf.bprintf body "%steslExpectFailure(teslT, func() {\n%s\t_ = %s\n%s})\n"
           indent indent emitted indent
       | TFailure -> unsupported loc "Go backend expectFail target has no result type");
      emit_stmts env indent rest
    (* A `case` in a test block discriminates exactly like one in an expression — the same
       emitter runs it — but each arm carries STATEMENTS rather than a value. *)
    | TsCase { scrut; arms; loc } :: rest ->
      Buffer.add_string body (line_directive loc);
      emit_case_statements ~indent ~terminating:false signatures env body scrut
        (List.map (fun (arm : ts_case_arm) ->
           arm.ts_pattern, arm.ts_guard,
           (fun arm_env body_indent -> emit_stmts arm_env body_indent arm.ts_body)) arms);
      emit_stmts env indent rest
    (* `let (v ::: pf) = value` in a test: the value binds and the proof erases, as in a
       function body.  A test may name several proofs at once (`::: p1 && p2`). *)
    | TsLetProof { value_name; proof_names; value; loc } :: rest ->
      let value_ty = type_of_expr signatures env value in
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%s{\n" indent;
      let emitted = emit_expr ~expected:value_ty ~indent:(indent ^ "\t") signatures env value in
      if value_name = "_" then
        Printf.bprintf body "%s\t_ = %s\n" indent emitted
      else begin
        Printf.bprintf body "%s\t%s := %s\n" indent (local_ident value_name) emitted;
        Printf.bprintf body "%s\t_ = %s\n" indent (local_ident value_name)
      end;
      List.iter (fun proof_name ->
        if proof_name <> "_" then begin
          Printf.bprintf body "%s\t%s := struct{}{}\n" indent (local_ident proof_name);
          Printf.bprintf body "%s\t_ = %s\n" indent (local_ident proof_name)
        end) proof_names;
      let env =
        (value_name, value_ty)
        :: List.map (fun proof_name -> proof_name, TUnit) proof_names
        @ env in
      emit_stmts env (indent ^ "\t") rest;
      Printf.bprintf body "%s}\n" indent
    (* `property "name" (x: T, y: U where …) { body }` — the body must hold for every generated
       binding.  A `where` clause SKIPS the run rather than failing it, which is what Racket's
       `(when guard (check-true …))` does: the guard describes which values the property is
       about, so a value outside it is not a counterexample. *)
    | TsProperty { description; params; body = property_body; loc } :: rest ->
      let types = match !current_types with
        | Some types -> types
        | None -> unsupported loc "Go backend cannot resolve property parameter types here"
      in
      let bindings = List.map (fun (param : property_param) ->
        param.binding.name, type_of_type_expr types param.binding.type_expr) params in
      let property_env = bindings @ env in
      let run = Printf.sprintf "teslPropRun%d" (String.length indent) in
      Printf.bprintf body "%sfor %s := 0; %s < %d; %s++ {\n"
        indent run run !property_runs run;
      Buffer.add_string body (line_directive loc);
      List.iter2 (fun (param : property_param) (name, ty) ->
        let generated = match param.generator with
          | Some generator ->
            (* A custom generator is a function of the RUN INDEX, so it can walk a space
               rather than sample it — `(gen tesl-prop-i)` on the Racket side. *)
            let signature = match Hashtbl.find_opt signatures generator with
              | Some signature -> signature
              | None -> unsupported loc
                "Go backend cannot resolve property generator `%s`" generator
            in
            (match signature.params with
             | [TInt] -> ()
             | _ -> unsupported loc
               "Go backend property generator `%s` must take the run index (an Int)" generator);
            if type_unequal signature.result ty then unsupported loc
              "Go backend property generator `%s` does not produce `%s`" generator (go_type ty);
            Printf.sprintf "%s(teslrt.FromInt64(int64(%s)))"
              (qualified signature.sig_owner signature.go_name) run
          | None -> property_generator loc ty
        in
        Printf.bprintf body "%s\t%s := %s\n%s\t_ = %s\n" indent (local_ident name) generated
          indent (local_ident name)) params bindings;
      let guards = List.filter_map (fun (param : property_param) -> param.where_clause) params in
      let inner = if guards = [] then indent ^ "\t" else indent ^ "\t\t" in
      if guards <> [] then begin
        List.iter (fun guard ->
          if type_of_expr signatures property_env guard <> TBool then
            unsupported (Checker.expr_loc guard)
              "Go backend property `where` clause must be Bool") guards;
        (* A SINGLE guard needs no parentheses of its own — gofmt strips them, and emitted
           code that gofmt would reformat is an emitter bug. *)
        let rendered = List.map (fun guard ->
          emit_expr ~expected:TBool ~indent:(indent ^ "\t") signatures property_env guard)
          guards in
        Printf.bprintf body "%s\tif %s {\n" indent
          (match rendered with
           | [only] -> strip_outer_parens only
           | several -> String.concat " && " several)
      end;
      if type_of_expr signatures property_env property_body <> TBool then
        unsupported loc "Go backend property body must be Bool";
      (* The failing BINDING is reported, not just the property's name: a counterexample the
         author cannot see is a test that only says "somewhere in 200 runs". *)
      let reported = List.map (fun (name, _) ->
        Printf.sprintf "%s=%%v" name) bindings in
      Printf.bprintf body "%sif %s {\n%s\tteslT.Fatalf(%s, %s)\n%s}\n"
        inner
        (strip_outer_parens
           (emit_negated ~indent:inner signatures property_env property_body))
        inner
        (go_quote (Printf.sprintf "property %s failed (%s)"
                     (Printf.sprintf "%S" description) (String.concat ", " reported)))
        (String.concat ", " (List.map (fun (name, _) -> local_ident name) bindings))
        inner;
      if guards <> [] then Printf.bprintf body "%s\t}\n" indent;
      Printf.bprintf body "%s}\n" indent;
      emit_stmts env indent rest
    (* `expectHasProof f x P` asserts, on Racket, that the value `f x` answers carries the
       fact `P`.  A fact has NO runtime form here — the checker discharges the proof before
       anything is emitted — so the fact list is not there to inspect.  What a Go run can
       still assert is the half that is about the run: that the check ACCEPTED, without
       which there is no value for the proof to be about.  The predicate itself is
       guaranteed statically, which is stronger than an assertion about a list. *)
    | TsExpectHasProof { fn; arg; proof_name; loc } :: rest ->
      let call = EApp { fn; arg; loc } in
      let emitted = match delegated_check_call ~indent signatures env call with
        | Some (rendered, _) -> rendered
        | None ->
          (match type_of_expr signatures env call with
           | TCheck _ -> ()
           | _ -> unsupported loc
             "Go backend `expectHasProof` takes a check that mints the proof");
          emit_expr ~indent signatures env call
      in
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body
        "%sif !(%s).OK() {\n%s\tteslT.Fatal(\"expected the check to accept, minting %s\")\n%s}\n"
        indent emitted indent proof_name indent;
      emit_stmts env indent rest
    (* `if cond { … } else { … }` in a test body is the Go statement it describes.  Each
       branch is its own scope, which is what the emitted braces already give. *)
    | TsIf { cond; then_stmts; else_stmts; loc } :: rest ->
      if type_of_expr signatures env cond <> TBool then
        unsupported loc "Go backend test `if` condition must be Bool";
      Buffer.add_string body (line_directive loc);
      Printf.bprintf body "%sif %s {\n" indent
        (strip_outer_parens (emit_expr ~expected:TBool ~indent signatures env cond));
      emit_stmts env (indent ^ "\t") then_stmts;
      if else_stmts <> [] then begin
        Printf.bprintf body "%s} else {\n" indent;
        emit_stmts env (indent ^ "\t") else_stmts
      end;
      Printf.bprintf body "%s}\n" indent;
      emit_stmts env indent rest
  in
  (* `seed { insert … }` runs before a block's own statements: the store starts from the rows the
     test declares rather than from whatever an earlier block left, which is the point of pairing
     it with the per-test reset.  The statements are EXPRESSIONS (an `insert` answers the row),
     so each is emitted and discarded — the shape a `let _ = insert …` already takes. *)
  (* A seed statement is WRITTEN `let _ = insert …`, and the parser gives that `let` a body:
     a reference to the binding it just made.  Emitted as one expression, that body becomes
     the closure's return value — `return _`, which is not Go.  A chain of discarding `let`s
     is peeled into the statements it describes.  Anything that binds a name and goes on to
     use it is left as it stands: there the closure IS the right shape. *)
  let rec seed_statements expr =
    match expr with
    | ELet { name = "_"; value; body; _ } ->
      value :: (match body with
                | EVar { name = "_"; _ } -> []
                | rest -> seed_statements rest)
    | _ -> [expr]
  in
  let emit_seed loc (seed_stmts : expr list) =
    if seed_stmts <> [] then begin
      Buffer.add_string body (line_directive loc);
      List.iter (fun statement ->
        ignore (type_of_expr signatures [] statement);
        Buffer.add_string body (line_directive (Checker.expr_loc statement));
        Printf.bprintf body "\t_ = %s\n" (emit_expr ~indent:"\t" signatures [] statement))
        (List.concat_map seed_statements seed_stmts)
    end
  in
  List.iteri (fun index (test : test_form) ->
    (* `runs` is a PROPERTY test's repetition count: emit_racket reads it only where a
       `property` statement is emitted, so on a test with no property statement it changes
       nothing on either backend — and refusing it here made a test Racket runs fine
       uncompilable.  A test that DOES carry a property statement is still refused, by the
       statement itself, which is where the generators are missing.
       The capabilities and the `with database X` header, by contrast, are compile-time
       grants: with `backend: Memory` the store a test writes to is the entity's own
       table variable, exactly as in a function body. *)
    (* `with N runs` is a PROPERTY block's repetition count; a test with no property statement
       is unaffected, on either backend. *)
    property_runs := Option.value test.runs ~default:200;
    ignore test.capabilities;
    (* `test "…" with database D { … }` binds D for the whole block, exactly as the same
       header does on a function.  With a Memory-backed D there is nothing to bind — the store
       is the entity's own table variable — and with a Postgres-backed one this is what
       CONNECTS, so the block's queries reach the server instead of the in-memory table. *)
    let bound = match test.database with
      | Some name -> postgres_database test.loc name
      | None -> None in
    Buffer.add_char body '\n';
    Printf.bprintf body "func TestTesl%d(teslT *testing.T) {\n" index;
    emit_reset ();
    (match bound with
     | None -> emit_stmts [] "\t" test.stmts
     | Some database ->
       Printf.bprintf body "\tteslrt.WithDatabase(%s, func() {\n"
         (qualified database.db_owner database.db_go_var);
       emit_stmts [] "\t\t" test.stmts;
       Buffer.add_string body "\t})\n");
    Buffer.add_string body "}\n") tests;
  (* An `api-test` drives the emitted server IN PROCESS — no socket, so it is an ordinary
     `go test` case.  Racket dispatches the same way, so both backends exercise the same
     layer.  The statements are the same `test_stmt` forms an ordinary `test` block uses,
     so they go through the same emitter; only the request verbs are special. *)
  List.iteri (fun index (api_test : api_test_form) ->
    Buffer.add_char body '\n';
    (* The description comment goes BEFORE the line directive: gofmt treats a comment
       directly above a declaration as its doc comment and moves the directive below it. *)
    (* gofmt separates a doc comment from a following `//line` directive with a bare `//`
       line, so it is emitted that way rather than left for gofmt to add. *)
    Printf.bprintf body "// api-test %s\n//\n" (String.escaped api_test.description);
    Buffer.add_string body (line_directive api_test.loc);
    Printf.bprintf body "func TestTeslApi%d(teslT *testing.T) {\n" index;
    emit_reset ();
    emit_seed api_test.loc api_test.seed_stmts;
    current_api_server := Some (go_ident ~exported:true api_test.server_name);
    emit_stmts [] "\t" api_test.stmts;
    current_api_server := None;
    Buffer.add_string body "}\n") api_tests;
  (* A `load-test` block is a Go test too: it drives the same in-process dispatch an api-test
     uses, at a fixed arrival rate, and asserts on the sample.  Driving the SAME dispatch is what
     makes the number comparable with the Racket harness's — both measure the program, not a
     socket.  The request statements are ordinary api-test statements, so they go through the
     same emitter; what differs is that they run inside the harness's thunk. *)
  List.iteri (fun index (load_test : load_test_form) ->
    if load_test.baseline <> None then unsupported load_test.loc
      "Go backend does not support load-test baselines yet";
    Buffer.add_char body '\n';
    Printf.bprintf body "// load-test %s\n//\n" (String.escaped load_test.description);
    Buffer.add_string body (line_directive load_test.loc);
    Printf.bprintf body "func TestTeslLoad%d(teslT *testing.T) {\n" index;
    emit_reset ();
    (* Seeded ONCE, before the run: every request sees the same state, which is what makes the
       measurement about the request rather than about a store that keeps growing. *)
    emit_seed load_test.loc load_test.seed_stmts;
    (* `-short` skips it: a load test takes seconds by construction, and `go test` in a tight
       loop should not pay for it.  The same run WITHOUT `-short` measures. *)
    Buffer.add_string body
      "\tif testing.Short() {\n\t\tteslT.Skip(\"load-test: skipped in -short mode\")\n\t}\n";
    Printf.bprintf body
      "\tteslResult := teslrt.RunLoadTest(%d, %d, func() int {\n" load_test.rate
      load_test.duration;
    current_api_server := Some (go_ident ~exported:true load_test.server_name);
    (* The last request statement's status is what the harness counts, so the thunk answers it. *)
    let statuses = ref [] in
    List.iteri (fun statement_index (statement : test_stmt) ->
      match statement with
      | TsExpr { e; loc } ->
        let name = Printf.sprintf "teslResponse%d" statement_index in
        Buffer.add_string body (line_directive loc);
        Printf.bprintf body "\t\t%s := %s\n" name
          (emit_expr ~indent:"\t\t" signatures [] e);
        statuses := name :: !statuses
      | TsLet { loc; _ } | TsExpect { loc; _ } | TsExpectFail { loc; _ }
      | TsExpectHasProof { loc; _ } | TsProperty { loc; _ } | TsIf { loc; _ }
      | TsCase { loc; _ } | TsLetProof { loc; _ } ->
        unsupported loc
          "Go backend load-test bodies take request statements only") load_test.request_stmts;
    (match !statuses with
     | [] -> unsupported load_test.loc "Go backend load-test needs a request statement"
     | last :: rest ->
       List.iter (fun name -> Printf.bprintf body "\t\t_ = %s\n" name) (List.rev rest);
       Printf.bprintf body "\t\treturn teslrt.LoadTestStatus(%s)\n" last);
    current_api_server := None;
    Buffer.add_string body "\t})\n\tteslrt.ReportLoadTest(teslT, teslResult)\n";
    List.iter (fun assertion ->
      match assertion with
      | LtAssertMetric { metric; op; value; unit } ->
        let metric_name = match metric with
          | LtP50 -> "p50" | LtP95 -> "p95" | LtP99 -> "p99" | LtP999 -> "p99.9"
          | LtErrorRate -> "errorRate" | LtThroughput -> "throughput"
        in
        let operator = match op with
          | BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">="
          | _ -> unsupported load_test.loc
            "Go backend load-test assertions compare with <, <=, > or >="
        in
        ignore unit;
        Printf.bprintf body "\tteslrt.AssertLoadTest(teslT, teslResult, %s, %s, %s)\n"
          (go_quote metric_name) (go_quote operator) (emit_float_literal value)
      | LtAssertRegression _ ->
        unsupported load_test.loc
          "Go backend does not support load-test regression baselines yet") load_test.assertions;
    Buffer.add_string body "}\n") load_tests;
  if reset_calls <> [] then begin
    Buffer.add_string body
      "\n// teslResetTestState empties the stores every test block starts from, so no block\n\
       // inherits another's rows, jobs, or outbound-HTTP stubs.\n\
       func teslResetTestState() {\n";
    List.iter (fun call -> Printf.bprintf body "\t%s\n" call) reset_calls;
    Buffer.add_string body "}\n"
  end;
  let body = Buffer.contents body in
  let expect_failure_helper =
    if contains_go_code body "teslExpectFailure(" then
      "\nfunc teslExpectFailure(teslT *testing.T, teslThunk func()) {\n\tteslT.Helper()\n\tdefer func() {\n\t\tif recover() == nil {\n\t\t\tteslT.Fatal(\"expected Tesl failure\")\n\t\t}\n\t}()\n\tteslThunk()\n}\n"
    else ""
  in
  let body =
    (* Only the helpers module.go did NOT already declare: both files are one Go package,
       so a duplicate is a redeclaration, and a helper the module already has is in scope
       here anyway. *)
    (Hashtbl.to_seq pending_helpers
     |> List.of_seq
     |> List.filter (fun (name, _) -> not (Hashtbl.mem module_helpers name))
     |> List.sort (fun (left, _) (right, _) -> String.compare left right)
     |> List.map snd
     |> String.concat "")
    ^ body
  in
  let imports = ["fmt"; "os"]
    @ (if contains_go_code body "strconv." then ["strconv"] else [])
    @ (if contains_go_code body "math." then ["math"] else [])
    @ (if contains_go_code body "pgx.CollectableRow" || contains_go_code body "pgx.Row"
       then ["github.com/jackc/pgx/v5"] else [])
    @ (if contains_go_code body "pgtype." then ["github.com/jackc/pgx/v5/pgtype"] else [])
    @ (if contains_go_code body "teslrt." then [module_path ^ "/internal/teslrt"] else [])
    (* A test block may construct a dependency's type or call into it directly, so the
       test file needs the same imports — and only the ones it actually references. *)
    @ List.filter_map (fun dependency ->
        if contains_go_code body (dependency ^ ".") then
          Some (module_path ^ "/internal/" ^ dependency)
        else None) imported_packages
    @ ["testing"] in
  Printf.sprintf
    "package %s\n%s\nfunc TestMain(teslM *testing.M) {\n\t_, _ = fmt.Fprintln(os.Stderr, \"TESL_GO_TESTS_STARTED\")\n\tos.Exit(teslM.Run())\n}\n%s%s"
    package (import_block imports) expect_failure_helper body

(* Brings an imported local module's exposed names into scope by COPYING the entries
   from the tables that module emitted from.  Nothing is re-derived: a second derivation
   would produce info records that compare unequal to the originals (go_type equality is
   structural), so a value crossing the boundary would look like a different type.
   Facts are absent from these tables by design — a fact erases entirely, so an exposed
   name that resolves to nothing is not an error. *)
(* The TYPES a module imports, registered before this module's own field types are
   resolved.  A record field may name an imported ADT (`role: OrgRole`), and the full
   import registration below runs after that resolution — so without this pass the field
   type is unresolvable and a perfectly ordinary cross-module record is refused.

   Add-if-absent, never replace: a local declaration of the same name is this module's own,
   and an import must not silently take its place. *)
let register_imported_types ~exposed types (exports : module_exports) =
  let add table name info = if not (Hashtbl.mem table name) then Hashtbl.replace table name info in
  List.iter (fun name ->
    let base = match String.index_opt name '(' with
      | Some index -> String.sub name 0 index
      | None -> name
    in
    List.iter (fun name ->
      (match Hashtbl.find_opt exports.ex_types.newtypes name with
       | Some info -> add types.newtypes name info
       | None -> ());
      (match Hashtbl.find_opt exports.ex_types.records name with
       | Some info ->
         add types.records name info;
         (* An exposed ENTITY brings its table along with its row type: a query here reads
            the other package's store, so the two must name the same table. *)
         (match Hashtbl.find_opt exports.ex_types.entities name with
          | Some entity -> add types.entities name entity
          | None -> ())
       | None -> ());
      (match Hashtbl.find_opt exports.ex_types.adts name with
       | Some info -> add types.adts name info
       | None -> ());
      (* And where the type's codec is emitted, if it has one: a reference from here has to
         name that package. *)
      (match Hashtbl.find_opt exports.ex_types.codecs name with
       | Some owner -> add types.codecs name owner
       | None -> ())) (if base = name then [name] else [name; base]))
    exposed

let register_imported_module ~loc ~exposed types signatures (exports : module_exports) =
  (* A LIFTED module's members are DECLARED bare (`fn fromParts`) and WRITTEN qualified at
     every call site (`CivilTime.fromParts`), which is also how the import list spells them.
     So the lookup strips the qualifier while the key keeps it: `normalize_call_head` turns
     the call site into the dotted name, and that is what has to resolve. *)
  let unqualified name =
    let prefix = exports.ex_module ^ "." in
    let cut = String.length prefix in
    if String.length name > cut && String.sub name 0 cut = prefix
    then Some (String.sub name cut (String.length name - cut))
    else None
  in
  List.iter (fun name ->
    let copy_type () =
      match Hashtbl.find_opt exports.ex_types.newtypes name,
            Hashtbl.find_opt exports.ex_types.records name,
            Hashtbl.find_opt exports.ex_types.adts name with
      | Some info, _, _ -> Hashtbl.replace types.newtypes name info; true
      | None, Some info, _ ->
        Hashtbl.replace types.records name info;
        (* An exposed ENTITY brings its table along with its row type: a query in this
           module reads the other package's store, so the two must be the same table. *)
        (match Hashtbl.find_opt exports.ex_types.entities name with
         | Some entity -> Hashtbl.replace types.entities name entity
         | None -> ());
        true
      | None, None, Some info -> Hashtbl.replace types.adts name info; true
      | None, None, None -> false
    in
    let copy_codec name =
      match Hashtbl.find_opt exports.ex_types.codecs name with
      | Some owner -> Hashtbl.replace types.codecs name owner
      | None -> ()
    in
    (* An ADT exposed as `Colour(..)` brings its constructors; the bare name is also
       accepted, since the constructors live in the signature table either way. *)
    let base = match String.index_opt name '(' with
      | Some index -> String.sub name 0 index
      | None -> name
    in
    let found_type = copy_type () ||
      (match unqualified base with
       | Some bare ->
         (match Hashtbl.find_opt exports.ex_types.newtypes bare,
                Hashtbl.find_opt exports.ex_types.records bare,
                Hashtbl.find_opt exports.ex_types.adts bare with
          | Some info, _, _ -> Hashtbl.replace types.newtypes bare info; true
          | None, Some info, _ -> Hashtbl.replace types.records bare info; true
          | None, None, Some info -> Hashtbl.replace types.adts bare info; true
          | None, None, None -> false)
       | None -> false)
      || (base <> name &&
      (match Hashtbl.find_opt exports.ex_types.adts base with
       | Some info -> Hashtbl.replace types.adts base info; true
       | None -> false)) in
    copy_codec name;
    if base <> name then copy_codec base;
    let found_value = match Hashtbl.find_opt exports.ex_signatures name with
      | Some signature -> Hashtbl.replace signatures name signature; true
      | None ->
        (match Option.bind (unqualified name) (Hashtbl.find_opt exports.ex_signatures) with
         | Some signature -> Hashtbl.replace signatures name signature; true
         | None -> false)
    in
    (* A constructor of an exposed ADT is itself a signature entry. *)
    if found_type then
      Hashtbl.iter (fun ctor (signature : signature) ->
        match signature.result with
        | TAdt (info, _) when info.adt_tesl_name = base ->
          Hashtbl.replace signatures ctor signature
        | _ -> ()) exports.ex_signatures;
    (* A name that is neither a type nor a value is a FACT: the frontend has already
       validated the import, and a fact has no runtime form to bring across. *)
    ignore (found_type, found_value, loc))
    exposed

let compile_module ?(mode=Release) ?(dependencies=[]) ?project_path (m : module_form) =
  try
    (match mode with
     | Release -> ()
     | Debug -> unsupported (Location.dummy_loc m.source_file)
       "Go debugger instrumentation is not implemented yet");
    (* `Maybe` is provided by `internal/teslrt` rather than emitted per module: a
       Maybe crosses module boundaries, and two packages declaring their own would
       be incompatible Go types.  Only the type and its constructors are available;
       the `Tesl.Maybe` FUNCTIONS still fail closed. *)
    let maybe_imported = ref false in
    List.iter (fun (import : import_decl) ->
      let exposed = match import.names with
        | ImportAll -> []
        | ImportExposing names -> names
      in
      match import.module_name with
      | "Tesl.Prelude" ->
        if List.exists (fun name -> name = "Maybe" || name = "Maybe(..)") exposed then
          maybe_imported := true
      | "Tesl.Maybe" ->
        (* The type and its two constructors are the runtime type; every `Maybe.*`
           FUNCTION still fails closed until the stdlib lands. *)
        List.iter (fun name ->
          match name with
          | "Maybe" | "Maybe(..)" | "Nothing" | "Something" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Maybe` export `%s` yet" other) exposed;
        maybe_imported := true
      (* `Tesl.Json` exports codec COMBINATOR names, not values: `stringCodec` and
         friends only ever appear in a `with_codec` position, which the codec emitter
         resolves directly.  Nothing is bound at runtime, so the import needs no
         support beyond accepting the names it may expose. *)
      | "Tesl.Json" ->
        List.iter (fun name ->
          match name with
          | "stringCodec" | "intCodec" | "boolCodec" | "floatCodec"
          | "posixMillisCodec" -> ()
          (* A CONTAINER codec names the shape; the field's declared type says how to read each
             element, which is what the decoder walks. *)
          | "listCodec" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Json` export `%s` yet" other) exposed
      (* `Tesl.Http`: the request type is runtime-provided (registered above) and
         `cookieCap` is a capability name the checker enforces — neither needs anything at
         run time.  The cookie WRITERS arrive with the session slice. *)
      (* `Tesl.ApiTest`: the response type is runtime-provided; the status predicates are
         runtime leaves.  A request verb is only meaningful inside an `api-test` block. *)
      | "Tesl.ApiTest" ->
        List.iter (fun name ->
          match name with
          | "HttpResponse" | "statusOk" | "statusClientError" | "statusServerError"
          | "get" | "post" | "put" | "delete" | "patch" -> ()
          (* The queue verbs an api-test drives.  `JobResult` is runtime-provided (registered
             below with Maybe and Either), the rest are calls whose QUEUE argument the
             emitter resolves statically. *)
          | "JobResult" | "JobResult(..)" | "JobOk" | "JobFailed"
          | "processNextJob" | "processNextDeadJob" | "pendingJobCount" | "drainQueue"
          | "expectJobOk" | "expectJobFailed" -> ()
          (* The untyped JSON surface: `JsonValue`/`JsonNull` are the type names, the rest are
             the predicates and accessors the emitter renders directly. *)
          | "JsonValue" | "JsonNull"
          | "isNull" | "isNotNull" | "isEmpty" | "isNotEmpty" | "hasLength" | "hasField"
          | "jsonInt" | "jsonString" | "jsonBool" | "jsonArray" | "jsonObject" | "jsonLength"
          | "arrayAt" | "fieldAt" | "bodyField" | "jsonContains"
          | "includesWhere" | "excludesWhere" -> ()
          (* The outbound-HTTP double: statements a test writes before the code under test
             runs, and the assertions that read the call log afterwards. *)
          | "stubHttp" | "stubHttpFailure" | "stubHttpTimeout"
          | "httpCalled" | "httpCallCount" | "httpLastBody" -> ()
          (* The session cookie a response set, for a round-trip test. *)
          | "responseCookie" -> ()
          (* The SSE surface: `subscribe` opens a stream against the emitted server and
             `collect` waits on it.  Both are statement shapes the emitter renders directly. *)
          | "subscribe" | "collect" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.ApiTest` export `%s` yet" other) exposed
      | "Tesl.Http" ->
        List.iter (fun name ->
          match name with
          | "HttpRequest" | "cookieCap" | "Http.clearSessionCookie"
          | "Http.setSessionCookie" | "Http.sessionToken" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Http` export `%s` yet" other) exposed
      (* `Tesl.Crypto`: message authentication, digests and tokens are runtime leaves over Go's
         standard library — the same primitives the Racket runtime reaches for in libsodium, so
         a tag or a fingerprint produced by one backend verifies on the other.  PASSWORD STORAGE
         is Argon2id through `golang.org/x/crypto/argon2` (the one approved non-stdlib
         dependency): the alternative substitutes would mint hashes the Racket side cannot
         verify, turning a shared database into a silent lockout.  It ships only with a program
         that stores passwords. *)
      (* `Tesl.Proxy` is the authenticating-proxy edge binding: one check-shaped function
         and the fact only it can mint.  The fact erases like every other; what survives is
         that the value carrying it went through a real comparison against stored material,
         which is what distinguishes it from trusting a header. *)
      | "Tesl.Proxy" ->
        List.iter (fun name ->
          match name with
          | "ProxyBound" | "Proxy.verifyBinding" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Proxy` export `%s` yet" other) exposed
      (* `Tesl.Sso` is the identity-provider surface.  Every value in it is OPAQUE — a
         connection, a subject key, an identity — because what makes them trustworthy is the
         path they came down: `Sso.defaults` or `Sso.oidc` builds a connection, the RUNTIME
         drives the flow, and an app first sees an identity at `onIdentity`, after the
         signature, the claims and the domain rules have all been applied.  The leaves and
         types register below, where the `Secret` their credentials use is in hand. *)
      | "Tesl.Sso" ->
        List.iter (fun name ->
          match name with
          | "SsoConnection" | "SsoSubjectKey" | "SsoIdentity" | "SsoProvider"
          | "Github" | "Google"
          | "Sso.defaults" | "Sso.oidc" | "Sso.keyText" | "Sso.subject"
          | "Sso.email" | "Sso.tenant" | "Sso.claim"
          | "Sso.allowedEmailDomains" | "Sso.allowedHostedDomains" | "Sso.allowedTenants"
          | "Sso.logoutUrl" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Sso` export `%s` yet" other) exposed
      | "Tesl.Crypto" ->
        List.iter (fun name ->
          match name with
          | "Secret" | "Signature" | "PasswordHash"
          | "Crypto.hashPassword" | "Crypto.checkPassword" | "Crypto.needsRehash"
          | "Crypto.signWith" | "Crypto.hmacSha256" | "Crypto.checkSignature"
          | "Crypto.signatureHex" | "Crypto.signatureFromHex"
          | "Crypto.signatureBase64" | "Crypto.signatureFromBase64"
          | "Crypto.fingerprint" | "Crypto.keyFingerprint" | "Crypto.randomToken"
          | "Crypto.sha256" | "Crypto.sha512" -> ()
          (* The proof predicates erase, like every other fact. *)
          | "HashFor" | "PasswordVerified" | "Authentic" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Crypto` export `%s` yet" other) exposed
      (* `Tesl.App`: the DECLARATION vocabulary for `main`.  `App` names the record the compiler
         lowers into a startup chain, so there is nothing to bind at run time. *)
      | "Tesl.App" ->
        List.iter (fun name ->
          match name with
          | "App" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.App` export `%s` yet" other) exposed
      (* `Tesl.Telemetry`: the ambient signals.  Nothing is gated — an observability call that
         needed a capability would be threaded through every signature or left out of the code
         that most needs it — so what is left is one runtime call per signal. *)
      | "Tesl.Telemetry" ->
        List.iter (fun name ->
          match name with
          | "initTelemetry" | "telemetry" | "counter" | "histogram" | "gauge" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Telemetry` export `%s` yet" other) exposed
      (* `Tesl.JWT`: the one blessed session token.  HS256 over `header.payload`, which is
         `Tesl.Crypto`'s own primitive — so a token minted by either backend verifies on the
         other, and a test pins that against a real Racket-minted token. *)
      | "Tesl.JWT" ->
        List.iter (fun name ->
          match name with
          | "jwt" | "JwtToken" | "Authentic"
          | "JWT.sign" | "JWT.verify" | "JWT.renew" | "JWT.decode" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.JWT` export `%s` yet" other) exposed
      (* `Tesl.HttpClient`: the four verbs and the two secret-accepting header builders are
         runtime leaves (registered below); `HttpResponse` is the runtime-provided record
         they answer with, and `httpClient` is the capability the checker enforces. *)
      | "Tesl.HttpClient" ->
        List.iter (fun name ->
          match name with
          | "httpClient" | "HttpResponse" | "HttpResponse?"
          | "HttpClient.get" | "HttpClient.post" | "HttpClient.put" | "HttpClient.delete"
          | "HttpClient.bearer" | "HttpClient.secretHeader" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.HttpClient` export `%s` yet" other) exposed
      (* `Tesl.DB` exports the two database CAPABILITIES, which the checker enforces and
         which have no runtime form, plus the `delete … returning result` ADT — refused
         while `deleteAndReturnResult` is. *)
      | "Tesl.DB" ->
        List.iter (fun name ->
          match name with
          | "dbRead" | "dbWrite" -> ()
          (* `DeleteResult` is runtime-provided, like `Maybe`: it crosses module boundaries, so
             it cannot be emitted once per module that names it.  Registered below. *)
          | "DeleteResult" | "DeleteResult(..)" | "NoRowDeleted" | "RowsDeleted" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.DB` export `%s` yet" other) exposed
      (* `Tesl.Database` names the DECLARATION form (`= Database { entities: … backend:
         Memory }`); the declaration itself is where the backend is checked. *)
      | "Tesl.Database" ->
        List.iter (fun name ->
          match name with
          (* These names are only meaningful inside a `database` declaration, which is where
             the backend is read and where the connection is built. *)
          | "Database" | "Memory" | "DatabaseBackend" | "Postgres" | "PostgresConfig"
          | "PostgresConnection" | "TcpConnection" | "SocketConnection" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Database` export `%s` yet" other) exposed
      (* `Tesl.Email` exposes the DECLARATION vocabulary (`Email`, `SmtpConfig`), the
         `EmailBody` ADT its `body:` field takes, and `emailCap` — a capability the checker
         enforces, so it has no emitted form.  The two OPERATIONS (`Email.send`,
         `startEmailWorker`) are surface syntax over a declared email rather than imported
         names, which is why neither appears here. *)
      (* `Tesl.SSE` exposes the DECLARATION form (`= SseChannel { … }`).  Publishing and
         subscribing are surface syntax over a declared channel rather than imported names,
         which is why neither appears here; `pubsub` is a capability, and capabilities are
         compile-time. *)
      | "Tesl.SSE" ->
        List.iter (fun name ->
          match name with
          | "SseChannel" | "pubsub" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.SSE` export `%s` yet" other) exposed
      | "Tesl.Email" ->
        List.iter (fun name ->
          match name with
          | "Email" | "SmtpConfig" | "emailCap"
          | "EmailBody" | "EmailBody(..)" | "TextBody" | "HtmlBody" | "RichBody" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Email` export `%s` yet" other) exposed
      (* `Tesl.Money` and `Tesl.Units` are validated where their types and leaves are
         registered, against the compiler's own catalogs.  `Tesl.Agent` is validated the same
         way: its types and its leaves are registered together, so one list decides what the
         module offers rather than a second list here that could drift from it. *)
      (* `Tesl.Regex`, `Tesl.Url` and `Tesl.Net` are validated where their types and leaves
         are registered, like the catalogs. *)
      | "Tesl.Regex" | "Tesl.Url" | "Tesl.Net"
      | "Tesl.Agent"
      | "Tesl.Money" | "Tesl.Units"
      | "Tesl.String" | "Tesl.List" | "Tesl.Int" | "Tesl.Tuple" | "Tesl.Dict"
      | "Tesl.Set" | "Tesl.Float" | "Tesl.Either" | "Tesl.EitherPrim"
      | "Tesl.Time" | "Tesl.Env" | "Tesl.Random" | "Tesl.Id" | "Tesl.Result"
      | "Tesl.UUID" | "Tesl.Cache" | "Tesl.Int32" -> ()
      (* `Tesl.Queue` exports the DECLARATION vocabulary (`Queue`, the retry strategy and
         its backoff constructors), two capabilities, and the `FromQueue`/`FromDeadQueue`
         provenance proofs — which erase.  None of it needs a runtime binding: the store is
         the queue's own variable and the retry rule is baked into it. *)
      | "Tesl.Queue" ->
        List.iter (fun name ->
          match name with
          | "Queue" | "QueueRetryStrategy" | "Fixed" | "Exponential" | "Linear"
          | "queueRead" | "queueWrite" | "FromQueue" | "FromDeadQueue" | "Job"
          (* `pubsub` is the SSE capability: a compile-time grant, and the functions it
             gates fail closed on their own. *)
          | "pubsub"
          (* `deadJobs` is a FUNCTION over a queue (registered as a leaf below), and
             `DeadJob` the opaque type of its elements. *)
          (* `requeue` takes a `DeadJob` back to pending, so importing it brings `DeadJob`
             in as well — the value it takes has to have a type. *)
          | "deadJobs" | "DeadJob" | "requeue" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Queue` export `%s` yet" other) exposed
        (* validated against the leaf/type tables below *)
      | other when List.exists (fun dependency ->
                     dependency_named dependency other) dependencies ->
        (* A LOCAL module: registered below, once the type tables exist. *)
        ()
      | other ->
        unsupported import.loc "Go backend does not support import `%s` yet" other) m.imports;
    (* A `fact` is a proof PREDICATE.  Applying it (`ValidPort port`) builds a proof term,
       which erases — so it is registered like a zero-size constructor: the arguments are
       typed and then dropped, and the value is the empty struct.  Registered because a
       proof term can appear in an expression the emitter DOES walk: an `establish` whose
       result is `Maybe (Fact P)` answers with `Something (ValidPort port)`, and that Maybe
       is real control flow. *)
    let fact_names = List.filter_map (function DFact f -> Some f.name | _ -> None) m.decls in
    (* `main`'s trailing `App { … }` record is LOWERED here, through the same backend-neutral
       pass the Racket path uses (`Desugar.lower_main_app`), rather than being re-read in this
       emitter: a second reader of a config record is a second place for a field to be misread,
       which is exactly how `backend: Memory` once looked like Postgres. *)
    let funcs = List.filter_map (function DFunc fd -> Some fd | _ -> None) m.decls in
    let funcs = List.map (Desugar.lower_main_app m.decls) funcs in
    let codecs = List.filter_map (function DCodec c -> Some c | _ -> None) m.decls in
    let apis = List.filter_map (function DApi a -> Some a | _ -> None) m.decls in
    let servers = List.filter_map (function DServer s -> Some s | _ -> None) m.decls in
    let capturers = List.filter_map (function DCapture c -> Some c | _ -> None) m.decls in
    let api_tests = List.filter_map (function DApiTest t -> Some t | _ -> None) m.decls in
    let load_tests = List.filter_map (function DLoadTest t -> Some t | _ -> None) m.decls in
    let tests = List.filter_map (function DTest test -> Some test | _ -> None) m.decls in
    let package = package_name m.module_name in
    let types = {
      newtypes = Hashtbl.create 8;
      records = Hashtbl.create 8;
      adts = Hashtbl.create 8;
      entities = Hashtbl.create 8;
      queues = Hashtbl.create 8;
      caches = Hashtbl.create 4;
      emails = Hashtbl.create 4;
      channels = Hashtbl.create 4;
      codecs = Hashtbl.create 8;
      aliases = Hashtbl.create 8;
      consts = Hashtbl.create 8;
      databases = Hashtbl.create 4;
    } in
    (* A hand-written codec is emitted by THIS package, once; a use from another package is
       qualified with it (see `codec_decode_ref`). *)
    List.iter (fun (codec : codec_form) ->
      Hashtbl.replace types.codecs codec.type_name package) codecs;
    (* Which functions perform a proof operation, for the one assertion that depends on it
       (see the `expectFail` emission).  Computed here, where the bodies are in hand. *)
    Hashtbl.reset proof_op_functions;
    Hashtbl.reset current_functions;
    List.iter (function
      | DFunc f -> Hashtbl.replace current_functions f.name f
      | _ -> ()) m.decls;
    current_capturers := List.filter_map (function DCapture c -> Some c | _ -> None) m.decls;
    Hashtbl.reset current_field_proofs;
    List.iter (function
      | DRecord (r : record_form) ->
        let proofs = List.filter_map (fun (field : field_def) ->
          match field.proof_ann with
          | Some (PredApp { pred; _ }) -> Some (field.name, pred)
          (* A CONJUNCTION says two things about the same field; there is no single draw
             that satisfies both, so it falls back to the plain one. *)
          | _ -> None) r.fields in
        if proofs <> [] then Hashtbl.replace current_field_proofs r.name proofs;
        (match r.invariant with
         (* The proof's ARGUMENTS name the fields the check takes — `IsLargerThan some2Prop
            some2Prop2 via isLargerThan` is `isLargerThan(value.Some2Prop, value.Some2Prop2)`. *)
         | Some { checker_name = Some checker; proof_text = PredApp { args; _ }; _ } ->
           Hashtbl.replace current_record_invariants r.name (checker, args)
         | _ -> ())
      | _ -> ()) m.decls;
    (* ── `serverTools` / `humanActions` metadata ─────────────────────────────
       Two things are needed and neither is in the module tree alone: WHICH endpoints each
       call site gets (the checker's per-site proof decision) and what each endpoint looks
       like to a model (its name, description and derived schema).  The checker is re-run
       for the first, as the Racket backend does — and only for a module that actually uses
       one of the two forms, so nothing else pays for it. *)
    Hashtbl.reset server_tools_sites;
    Hashtbl.reset human_actions_sites;
    Hashtbl.reset server_tools_endpoints;
    let uses_endpoint_tools = List.exists (fun (import : import_decl) ->
      import.module_name = "Tesl.Agent"
      && (match import.names with
          | ImportAll -> true
          | ImportExposing names ->
            List.mem "serverTools" names || List.mem "humanActions" names)) m.imports in
    if uses_endpoint_tools then begin
      let _, _, _, _, tools_sites, actions_sites, _ = Checker.check_module_with_metadata m in
      List.iter (fun ((site : Location.loc), decision) ->
        Hashtbl.replace server_tools_sites
          (site.Location.start.line, site.Location.start.col) decision) tools_sites;
      List.iter (fun ((site : Location.loc), decision) ->
        Hashtbl.replace human_actions_sites
          (site.Location.start.line, site.Location.start.col) decision) actions_sites;
      let codecs = List.filter_map (function DCodec c -> Some c | _ -> None) m.decls in
      List.iter (function
        | DServer (server : server_form) ->
          (match List.find_map (function
                   | DApi (api : api_form) when api.name = server.api_name -> Some api
                   | _ -> None) m.decls with
           | None -> ()
           | Some api ->
             let http_endpoints = List.filter (fun (endpoint : api_endpoint) ->
               endpoint.method_ <> SSE) api.endpoints in
             (* The tool NAME is the bound handler's, paired positionally with the api's
                non-SSE endpoints — exactly how the server emission pairs them. *)
             let paired =
               if List.length server.handlers = List.length http_endpoints
               then List.combine server.handlers http_endpoints
               else List.map (fun (endpoint : api_endpoint) -> endpoint.name, endpoint)
                      http_endpoints
             in
             Hashtbl.replace server_tools_endpoints server.name
               (List.map (fun (handler, (endpoint : api_endpoint)) ->
                  (* The description is what the model reads to decide whether to call it,
                     so the handler's own doc comment is used when there is one. *)
                  let description =
                    match Hashtbl.find_opt current_functions handler with
                    | Some { doc = Some text; _ } when String.trim text <> "" -> String.trim text
                    | _ -> Printf.sprintf "%s %s"
                             (http_method_name endpoint.method_) endpoint.path
                  in
                  handler, description,
                  server_tool_endpoint_schema codecs endpoint, endpoint) paired))
        | _ -> ()) m.decls
    end;
    (* WHICH functions have a proof operation that could only fail on RACKET.  Its runtime
       raises when a value carries more than one proof — and the emitter can see when that
       is the case: a `check` applied to a value that is itself a check's result
       ACCUMULATES, and a proof decomposition of such a value carries the accumulation to
       both names it binds.

       A proof operation on a SINGLY-checked value raises nowhere, so an `expectFail` over
       that function is expecting one of its checks to reject — which happens on Go too, and
       refusing it cost a whole file (`wrapAndUnwrap 0` fails because `checkPositive 0`
       rejects, on both backends). *)
    let accumulated_proof_names body =
      let checked = ref [] and accumulated = ref [] in
      let mentions_accumulated expr =
        let found = ref false in
        Ast_visitor.iter (function
          | EVar { name; _ } when List.mem name !accumulated -> found := true
          | _ -> ()) expr;
        !found
      in
      let rec walk expr =
        (match expr with
         | ELet { name; value; _ } ->
           (match flatten_app [] value with
            | EVar { name = "check"; _ }, (_ :: arguments) ->
              if List.exists (function
                   | EVar { name = argument; _ } -> List.mem argument !checked
                   | _ -> false) arguments
              then accumulated := name :: !accumulated;
              checked := name :: !checked
            | _ -> if mentions_accumulated value then accumulated := name :: !accumulated)
         | ELetProof { value_name; proof_name; value; _ } ->
           if mentions_accumulated value then
             accumulated := value_name :: proof_name :: !accumulated
         | _ -> ());
        Ast_visitor.iter_children walk expr
      in
      walk body;
      !accumulated
    in
    let proof_op_on_accumulated body =
      let accumulated = accumulated_proof_names body in
      if accumulated = [] then None
      else
        let found = ref None in
        Ast_visitor.iter (fun node ->
          if !found = None then
            match flatten_app [] node with
            | EVar { name = ("detachFact" | "introAnd" | "andLeft" | "andRight") as name; _ },
              (_ :: _ as arguments) ->
              if List.exists (fun argument ->
                   let hit = ref false in
                   Ast_visitor.iter (function
                     | EVar { name = used; _ } when List.mem used accumulated -> hit := true
                     | _ -> ()) argument;
                   !hit) arguments
              then found := Some name
            | _ -> ()) body;
        !found
    in
    List.iter (function
      | DFunc f ->
        (match proof_op_on_accumulated f.body with
         | Some op -> Hashtbl.replace proof_op_functions f.name op
         | None -> ())
      | _ -> ()) m.decls;
    (* ONE Postgres-backed database per module, because only one can ever be CONNECTED.
       `main`'s `App { database: X }` names a single database and is the only thing that
       connects (Racket keeps one `current-database-runtime`; this backend keeps one binding
       per declaration and only the App's is ever bound).  A second Postgres database would
       therefore compile, route its entities' queries to a connection nothing opens, and read
       the IN-MEMORY table in production — silently, with the same rows a test would see.
       That is worse than not compiling, so it does not compile.

       This became reachable when the free-floating `with database D { … }` block was removed
       (2026-08-17): before that a program could wrap the second database's queries to bind it.
       The block is gone because every other use of it was a no-op and the one non-no-op
       position silently dropped the name — and multiple databases deserve a better answer
       than a scoping block, when someone needs them. *)
    (match List.filter_map (function
       | DDatabase d ->
         let d = Desugar.desugar_database_config d in
         (match String.lowercase_ascii d.backend with
          | "memory" -> None
          | _ -> Some (d.name, d.loc))
       | _ -> None) m.decls with
     | (first, _) :: ((second, loc) :: _) ->
       unsupported loc
         "Go backend supports one Postgres-backed database per module: `%s` is declared \
          beside `%s`, and only the one `main`'s `App { database: … }` names is ever \
          connected — the other's queries would read the in-memory store instead"
         second first
     | _ -> ());
    (* Every package-level Go name is minted here, in declaration order, so the
       emitted names are deterministic and provably distinct. *)
    let taken : (string, unit) Hashtbl.t = Hashtbl.create 32 in
    let package_ident name = unique_ident taken (go_ident ~exported:true name) in
    (* Databases are registered BEFORE anything is emitted, because `with database D` may be
       written above D's own declaration, and because an ENTITY has to know whether a
       Postgres-backed database manages it before any of its queries are emitted. *)
    List.iter (function
      | DDatabase d ->
        let d = Desugar.desugar_database_config d in
        let backend =
          match String.lowercase_ascii d.backend with
          | "" | "postgres" -> "postgres"
          | other -> other
        in
        Hashtbl.replace types.databases d.name {
          db_tesl_name = d.name;
          db_backend = backend;
          db_schema = d.schema;
          db_entities = d.entities;
          db_config = d.postgres;
          db_go_var =
            (if backend = "postgres" then package_ident (d.name ^ "Database") else "");
          db_owner = package;
          db_loc = d.loc;
        }
      | _ -> ()) m.decls;
    List.iter (function
      | DType (TypeNewtype { name; base_type; secret; loc; _ }) ->
        (* A newtype over a NEWTYPE — `type Rank = Score` where `type Score = Int`.  Racket
           nests them the same way, and ordering works transitively because each layer
           compares through its payload.  Declaration order is what makes this resolve: the
           base has to have been registered already, which is the same rule the source
           follows. *)
        let base = match base_type with
          | TName { name = base_name; _ } when Hashtbl.mem types.newtypes base_name ->
            TNewtype (Hashtbl.find types.newtypes base_name)
          | _ -> primitive_type_of_type_expr base_type
        in
        (* A secret's payload is held as a `teslrt.SecretString`, so only a String base has a
           representation today; a secret over Int would need its own redacting carrier and
           has no corpus use. *)
        if secret && base <> TString then unsupported loc
          "Go backend supports a `secret` newtype over String only (`%s`)" name;
        Hashtbl.replace types.newtypes name {
          tesl_name = name;
          owner = package;
          go_name = package_ident name;
          base;
          secret;
          loc;
        }
      (* A module-level constant's Go name is minted in the same pass as every other
         package-level name, so a constant cannot collide with a record, a queue store or a
         function.  Its TYPE is filled in when the value is emitted (typing it needs the
         signature table), which is also why the entry starts as Unit. *)
      | DConst c -> Hashtbl.replace types.consts c.name (TUnit, package_ident c.name)
      (* An `agent X = Agent { … }` block is a package-level VALUE, like a constant: the
         type settles when it is emitted. *)
      | DAgent a -> Hashtbl.replace types.consts a.name (TUnit, package_ident a.name)
      | _ -> ()) m.decls;
    let record_forms = List.filter_map (function DRecord r -> Some r | _ -> None) m.decls in
    List.iter (fun (r : record_form) ->
      (* A record-level `::: P` after the closing brace is a CROSS-FIELD invariant, and it is
         compile-time only — LANGUAGE-SPEC calls it a zero-cost annotation, and the Racket
         emitter reads it for nothing but property-test GENERATORS (`record_meta`), never for
         a check at construction.  Constructing such a record needs a witness, which the
         checker demands; here it erases with every other proof. *)
      ignore r.invariant;
      if r.fields = [] then unsupported r.loc
        "Go backend does not support the field-less record `%s`" r.name;
      List.iter (fun (field : field_def) ->
        (* A proof-carrying field (`name: String ::: Named name`) ERASES to its own type,
           the same rule every other proof follows: the checker has discharged it, and
           LANGUAGE-SPEC 16.9 gives a proof no runtime structure.  Racket attaches a
           wrapper and unwraps on every read, which is an implementation detail of that
           backend.  This used to fail closed as a not-yet; codecs are what forced the
           question, since a decoded field is exactly a proof-carrying field. *)
        ignore field.proof_ann;
        if field.checker <> None then unsupported field.loc
          "Go backend does not support `via` on record field `%s.%s` yet" r.name field.name)
        r.fields;
      if Hashtbl.mem types.newtypes r.name || Hashtbl.mem types.records r.name then
        unsupported r.loc "Go backend generated type name collision for `%s`" r.name;
      Hashtbl.replace types.records r.name {
        rec_tesl_name = r.name;
        rec_owner = package;
        rec_go_name = package_ident r.name;
        rec_fields = [];
        rec_proof_fields =
          List.exists (fun (field : field_def) -> field.proof_ann <> None) r.fields;
        rec_loc = r.loc;
      }) record_forms;
    (* A `queue` declaration: one store variable plus the job-type → worker wiring.  The
       typed form (`= Queue { … }`) keeps its fields in `config_expr`, and the Go pipeline
       does not run the desugar pass, so the same lowering the Racket backend gets is
       applied here — including `job_entries`, which pairs each job type with its worker and
       optional dead-letter worker. *)
    let queue_forms = List.filter_map (function DQueue q -> Some q | _ -> None) m.decls in
    List.iter (fun (q : queue_form) ->
      let entries = match q.config_expr with
        | None -> []
        | Some config ->
          (match List.assoc_opt "jobs" (Desugar.config_record_fields config) with
           | Some jobs -> Desugar.job_entries jobs
           | None -> [])
      in
      let lowered = Desugar.desugar_queue_config q in
      (match entries with
       | [] -> unsupported q.loc
         "Go backend requires `jobs: [Job <JobType> <worker> …]` on queue `%s`" q.name
       | ((job_type, worker, dead_worker) :: _) as jobs ->
         let go_var = package_ident (q.name ^ "Queue") in
         let info = {
           qu_tesl_name = q.name;
           qu_go_var = go_var;
           qu_owner = package;
           qu_jobs = jobs;
           qu_job_type = job_type;
           qu_worker = worker;
           qu_dead_worker = dead_worker;
           qu_max_attempts = Option.value lowered.max_attempts ~default:1;
           qu_loc = q.loc;
         } in
         Hashtbl.replace types.queues q.name info;
         (* A queue's NAME is also a TYPE: `fn listDead(q: EmailQueue) -> List DeadJob`
            takes the queue as a value.  Opaque — a program names one, hands it to a queue
            verb, and reads nothing off it — so it registers with no fields, like `DeadJob`
            itself.  The Go representation is the pointer `NewQueue` answers. *)
         Hashtbl.replace types.records q.name {
           rec_tesl_name = q.name;
           rec_owner = "";
           rec_go_name = "*teslrt.Queue";
           rec_proof_fields = false;
           rec_fields = [];
           rec_loc = q.loc;
         };
         (* Also by job type, since `enqueue` names the JOB and not the queue — every one of
            them, so a queue carrying two job types is reachable from either. *)
         List.iter (fun (each, _, _) -> Hashtbl.replace types.queues each info) jobs;
         ignore lowered)) queue_forms;
    (* An entity's ROW type is registered exactly like a record — a query result and an
       `insert` argument are ordinary struct values — and its store is one package-level
       table variable. *)
    let entity_forms = List.filter_map (function DEntity e -> Some e | _ -> None) m.decls in
    List.iter (fun (e : entity_form) ->
      if e.fields = [] then unsupported e.loc
        "Go backend does not support the field-less entity `%s`" e.name;
      List.iter (fun (field : field_def) ->
        ignore field.proof_ann;
        if field.checker <> None then unsupported field.loc
          "Go backend does not support `via` on entity field `%s.%s` yet" e.name field.name)
        e.fields;
      if not (List.exists (fun (field : field_def) -> field.name = e.primary_key) e.fields) then
        unsupported e.loc
          "Go backend cannot find the primary key `%s` among the fields of entity `%s`"
          e.primary_key e.name;
      (* A UNIQUE index is a constraint the Memory backend ENFORCES on Racket (an insert that
         violates it raises), so it is enforced here too — accepting one without enforcing it
         would make the two backends disagree about which programs RUN, not merely about what
         they answer.  A plain index is a performance hint with no observable effect on either
         store, so it is carried for the schema and nothing else. *)
      List.iter (fun (index : entity_index) ->
        if index.ix_fields = [] then unsupported index.ix_loc
          "Go backend: the index on entity `%s` lists no fields" e.name)
        e.indexes;
      if Hashtbl.mem types.newtypes e.name || Hashtbl.mem types.records e.name then
        unsupported e.loc "Go backend generated type name collision for `%s`" e.name;
      let row = {
        rec_tesl_name = e.name;
        rec_owner = package;
        rec_go_name = package_ident e.name;
        rec_fields = [];
        rec_proof_fields =
          List.exists (fun (field : field_def) -> field.proof_ann <> None) e.fields;
        rec_loc = e.loc;
      } in
      Hashtbl.replace types.records e.name row;
      (* The database that MANAGES this entity, found by asking each declaration which
         entities it lists — the direction `dsl/sql.rkt` reads it in, and the reason an entity
         needs no `database:` field of its own. *)
      let managing =
        Hashtbl.fold (fun _ (database : database_info) found ->
          match found with
          | Some _ -> found
          | None ->
            if database.db_backend = "postgres" && List.mem e.name database.db_entities
            then Some database else None)
          types.databases None
      in
      (* Named by SOME database, whatever its backend: that is what decides whether a test
         block starts from an empty table (see `ent_in_database`). *)
      let declared = Hashtbl.fold (fun _ (database : database_info) found ->
        found || List.mem e.name database.db_entities) types.databases false in
      Hashtbl.replace types.entities e.name {
        ent_tesl_name = e.name;
        ent_row = row;
        ent_table_var = package_ident (e.name ^ "Table");
        ent_owner = package;
        ent_primary_key = e.primary_key;
        ent_table_name = e.table;
        ent_indexes = e.indexes;
        ent_db_types =
          List.filter_map (fun (field : field_def) ->
            Option.map (fun ty -> (field.name, ty)) field.db_type) e.fields;
        ent_database = managing;
        ent_in_database = declared;
        ent_loc = e.loc;
      }) entity_forms;
    let tuple_imported = ref false in
    let set_imports = ref [] in
    (* The Set leaves that are HIGHER-ORDER: registered with the list hofs below, since the
       machinery is theirs. *)
    let set_hof_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Set" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if set_leaf name <> None then set_imports := name :: !set_imports
          (* `Set.filterCheck` is a HIGHER-ORDER leaf (it applies a check per element), so it
             registers with the hof family rather than in the set-leaf table. *)
          else if higher_order_leaf name <> None then begin
            set_hof_imports := name :: !set_hof_imports;
            (* `Set.allCheck` answers a Maybe — the whole set or nothing at all. *)
            if name = "Set.allCheck" then maybe_imported := true
          end
          else match name with
            | "Set" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Set` export `%s` yet" other) exposed
      end) m.imports;
    let dict_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Dict" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if dict_leaf name <> None then begin
            dict_imports := name :: !dict_imports;
            (* lookup returns a Maybe; toList/fromList speak in tuples. *)
            if name = "Dict.lookup" then maybe_imported := true;
            if name = "Dict.toList" || name = "Dict.fromList" then tuple_imported := true
          end
          (* `Dict.filterCheckValues` is HIGHER-ORDER (a check per value), so it registers with
             the hof family rather than in the dict-leaf table; it walks the dict's own pair
             list, which is what brings the runtime tuple in. *)
          else if higher_order_leaf name <> None then begin
            set_hof_imports := name :: !set_hof_imports;
            tuple_imported := true
          end else match name with
            | "Dict" -> ()
            (* `HasKey` is the proof `Dict.requireKey` mints, and it erases like every other
               fact: what it buys is that `Dict.get` does not compile without it. *)
            | "HasKey" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Dict` export `%s` yet" other) exposed
      end) m.imports;
    (* A list leaf is element-polymorphic, so its signature cannot be a fixed tuple of
       types like a String leaf's.  Each entry says how to type the call from the
       element type, and `emit_go` builds the argument list the same way. *)
    let list_leaf_names = [
      "List.length"; "List.isEmpty"; "List.head"; "List.tail"; "List.last";
      "List.append"; "List.take"; "List.drop"; "List.reverse"; "List.sum"; "List.product";
      "List.member"; "List.contains"; "List.unique"; "List.sort";
      "List.concat"; "List.flatten"; "List.maximum"; "List.minimum";
      "List.range"; "List.repeat";
    ] @ higher_order_leaf_names in
    let list_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.List" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name list_leaf_names then begin
            list_imports := name :: !list_imports;
            (* zip builds tuples, so importing it brings the runtime tuple types in
               even when the module never names Tuple2. *)
            if name = "List.zip" then tuple_imported := true;
            (* head/tail/last return a Maybe, so importing one brings the runtime
               Maybe in even when the module never names it. *)
            if List.mem name
                 ["List.head"; "List.tail"; "List.last"; "List.maximum"; "List.minimum";
                  "List.find"; "List.filterMap"]
            then maybe_imported := true
          end else match name with
            (* `Tesl.List`'s proof predicates are compile-time only, like
               `Tesl.String`'s: they erase with every other proof, so importing one
               needs no runtime support. *)
            | "IsSorted" | "ForAll" | "IsNonEmpty" | "IsNonNegative" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.List` export `%s` yet" other) exposed
      end) m.imports;
    let string_leaves = [
      (* name, params, result-shape, teslrt function *)
      "String.length",    [`Str], `Int,     "teslrt.StringLength";
      "String.isEmpty",   [`Str], `Bool,    "teslrt.StringIsEmpty";
      "String.startsWith",[`Str; `Str], `Bool, "teslrt.StringStartsWith";
      "String.endsWith",  [`Str; `Str], `Bool, "teslrt.StringEndsWith";
      "String.contains",  [`Str; `Str], `Bool, "teslrt.StringContains";
      "String.concat",    [`Str; `Str], `Str,  "teslrt.StringConcat";
      "String.replace",   [`Str; `Str; `Str], `Str, "teslrt.StringReplace";
      "String.slice",     [`Str; `Int; `Int], `Str, "teslrt.StringSlice";
      "String.toUpper",   [`Str], `Str,     "teslrt.StringToUpper";
      "String.toLower",   [`Str], `Str,     "teslrt.StringToLower";
      "String.trim",      [`Str], `Str,     "teslrt.StringTrim";
      "String.fromInt",   [`Int], `Str,     "teslrt.StringFromInt";
      "String.toInt",     [`Str], `MaybeInt,"teslrt.StringToInt";
      "String.indexOf",   [`Str; `Str], `MaybeInt, "teslrt.StringIndexOf";
      "String.dropPrefix",[`Str; `Str], `Str, "teslrt.StringDropPrefix";
      "String.dropSuffix",[`Str; `Str], `Str, "teslrt.StringDropSuffix";
      "String.padLeft",   [`Str; `Int; `Str], `Str, "teslrt.StringPadLeft";
      "String.padRight",  [`Str; `Int; `Str], `Str, "teslrt.StringPadRight";
      "String.repeat",    [`Str; `Int], `Str, "teslrt.StringRepeat";
      "String.reverse",   [`Str], `Str,     "teslrt.StringReverse";
      "String.requireNonEmpty", [`Str], `CheckStr, "teslrt.StringRequireNonEmpty";
      "String.split",     [`Str; `Str], `StrList, "teslrt.StringSplit";
      "String.join",      [`StrList; `Str], `Str, "teslrt.StringJoin";
      (* `Tesl.Int` checks: `List.take`/`List.drop` are proof-total, so a caller
         needs `check Int.nonNegative n` before it can pass a count at all. *)
      "Int.nonZero",      [`Int], `CheckInt, "teslrt.IntNonZero";
      "Int.nonNegative",  [`Int], `CheckInt, "teslrt.IntNonNegative";
      "Int.abs",          [`Int], `Int,      "teslrt.Abs";
      "Int.min",          [`Int; `Int], `Int, "teslrt.Min";
      (* Both are Racket's, so both are NON-NEGATIVE whatever the operands' signs are, and
         `lcm` with a zero operand is zero rather than a division by the gcd of two zeros. *)
      "Int.gcd",          [`Int; `Int], `Int, "teslrt.IntGcd";
      "Int.lcm",          [`Int; `Int], `Int, "teslrt.IntLcm";
      "Int.max",          [`Int; `Int], `Int, "teslrt.Max";
      (* Proof-total: the divisor carries `IsNonZero`, so the runtime guard is
         containment rather than the primary check. *)
      (* `Tesl.Float`.  The TRANSCENDENTALS are here and they diverge from Racket: sin, cos
         and tan differ on 22 %, 22 % and 34 % of inputs (up to 9,214 ulps near a zero of the
         function) and exp on 0.09 %.  That rate says the two differ, not which is right —
         ulp-of-result exaggerates a small absolute error near a zero — and deciding needs a
         correctly-rounded reference rather than a diff against Racket, so the maintainer's
         call (2026-08-12) is to use Go's and record the divergence rather than refuse to
         emit.  `Float.log` is the exception that does NOT forward: Go's `math.Log` answers
         the same wrong number for every subnormal, so the runtime scales around it. *)
      "Float.sin",        [`Float], `Float, "teslrt.FloatSin";
      "Float.cos",        [`Float], `Float, "teslrt.FloatCos";
      "Float.tan",        [`Float], `Float, "teslrt.FloatTan";
      "Float.exp",        [`Float], `Float, "teslrt.FloatExp";
      "Float.log",        [`Float], `Float, "teslrt.FloatLog";
      (* The named arithmetic surface; `Float.div`'s divisor carries a FloatNonZero proof,
         which erases like every other proof. *)
      "Float.add",        [`Float; `Float], `Float, "teslrt.FloatAdd";
      "Float.sub",        [`Float; `Float], `Float, "teslrt.FloatSub";
      "Float.mul",        [`Float; `Float], `Float, "teslrt.FloatMul";
      "Float.div",        [`Float; `Float], `Float, "teslrt.FloatDiv";
      "Float.abs",        [`Float], `Float, "teslrt.FloatAbs";
      "Float.min",        [`Float; `Float], `Float, "teslrt.FloatMin";
      "Float.max",        [`Float; `Float], `Float, "teslrt.FloatMax";
      "Float.clamp",      [`Float; `Float; `Float], `Float, "teslrt.FloatClamp";
      "Float.sqrt",       [`Float], `Float, "teslrt.FloatSqrt";
      "Float.pow",        [`Float; `Float], `Float, "teslrt.FloatPow";
      "Float.floor",      [`Float], `Int,   "teslrt.FloatFloor";
      "Float.ceil",       [`Float], `Int,   "teslrt.FloatCeil";
      "Float.round",      [`Float], `Int,   "teslrt.FloatRound";
      "Float.toString",   [`Float], `Str,   "teslrt.FormatFloat";
      "Float.toInt",      [`Float], `Int,   "teslrt.FloatToIntTruncating";
      "Float.parse",      [`Str], `MaybeFloat, "teslrt.ParseFloat";
      (* The predicates.  NaN is its own case in each: every comparison with NaN is false, so
         `isPositive`/`isNegative`/`isZero` all answer false for it and `isNaN` is the only way
         to ask. *)
      "Float.isNaN",      [`Float], `Bool, "teslrt.FloatIsNaN";
      "Float.isInfinite", [`Float], `Bool, "teslrt.FloatIsInfinite";
      "Float.isPositive", [`Float], `Bool, "teslrt.FloatIsPositive";
      "Float.isNegative", [`Float], `Bool, "teslrt.FloatIsNegative";
      "Float.isZero",     [`Float], `Bool, "teslrt.FloatIsZero";
      (* A FLOAT sign (1.0/-1.0/0.0), so it composes with float arithmetic. *)
      "Float.sign",       [`Float], `Float, "teslrt.FloatSign";
      "Float.requireNonZero", [`Float], `CheckFloat, "teslrt.FloatRequireNonZero";
      "Float.requireNonNegative", [`Float], `CheckFloat, "teslrt.FloatRequireNonNegative";
      "Int.divide",       [`Int; `Int], `Int, "teslrt.MustQuo";
      (* Tesl's `Int.modulo` is Racket `remainder` (truncated, sign of the
         dividend), NOT `modulo` (floored) — see tesl/int.rkt:183.  Mapping it to
         teslrt.MustMod would silently disagree on every negative dividend. *)
      "Int.modulo",       [`Int; `Int], `Int, "teslrt.MustRem";
      "Int.clamp",        [`Int; `Int; `Int], `Int, "teslrt.Clamp";
      "Int.sign",         [`Int], `Int,     "teslrt.IntSign";
      "Int.isEven",       [`Int], `Bool,    "teslrt.IntIsEven";
      "Int.isOdd",        [`Int], `Bool,    "teslrt.IntIsOdd";
      "Int.toString",     [`Int], `Str,     "teslrt.IntToString";
      (* Racket's `Int.pow` REJECTS a negative exponent rather than returning a
         fraction, so the Go leaf raises there too. *)
      "Int.pow",          [`Int; `Int], `Int, "teslrt.MustPow";
      (* `Int.parse` is `String.toInt` under another name.  Racket's differ in one corner:
         `Int.parse` accepts anything `integer?` accepts, so `Int.parse "3.0"` yields
         `Something 3.0` — a FLOAT where the type says Int — while `String.toInt` demands
         `exact-integer?`.  Both are strict decimal here; the Racket wart is recorded in
         roadmap/next/migrate_to_golang.md rather than reproduced. *)
      "Int.parse",        [`Str], `MaybeInt, "teslrt.StringToInt";
      (* `Tesl.Int32` — the same shapes, over a value that IS its integer at run time.  The
         split worth reading in the signatures: an operation that CANNOT leave
         [-2^31, 2^31) answers the value, one that CAN answers a `Maybe`. *)
      "Int32.fromInt",       [`Int], `MaybeInt, "teslrt.Int32FromInt";
      "Int32.toInt",         [`Int], `Int, "teslrt.Int32ToInt";
      "Int32.fromIntClamped", [`Int], `Int, "teslrt.Int32FromIntClamped";
      "Int32.parse",         [`Str], `MaybeInt, "teslrt.Int32Parse";
      "Int32.fromFloat",     [`Float], `MaybeInt, "teslrt.Int32FromFloat";
      "Int32.toFloat",       [`Int], `Float, "teslrt.Int32ToFloat";
      "Int32.toString",      [`Int], `Str, "teslrt.Int32ToString";
      "Int32.min",           [`Int; `Int], `Int, "teslrt.Int32Min";
      "Int32.max",           [`Int; `Int], `Int, "teslrt.Int32Max";
      "Int32.clamp",         [`Int; `Int; `Int], `Int, "teslrt.Int32Clamp";
      "Int32.modulo",        [`Int; `Int], `Int, "teslrt.Int32Modulo";
      "Int32.add",           [`Int; `Int], `MaybeInt, "teslrt.Int32Add";
      "Int32.subtract",      [`Int; `Int], `MaybeInt, "teslrt.Int32Subtract";
      "Int32.multiply",      [`Int; `Int], `MaybeInt, "teslrt.Int32Multiply";
      "Int32.negate",        [`Int], `MaybeInt, "teslrt.Int32Negate";
      "Int32.abs",           [`Int], `MaybeInt, "teslrt.Int32Abs";
      "Int32.pow",           [`Int; `Int], `MaybeInt, "teslrt.Int32Pow";
      "Int32.divide",        [`Int; `Int], `MaybeInt, "teslrt.Int32Divide";
      "Int32.isPositive",    [`Int], `Bool, "teslrt.Int32IsPositive";
      "Int32.isNegative",    [`Int], `Bool, "teslrt.Int32IsNegative";
      "Int32.isZero",        [`Int], `Bool, "teslrt.Int32IsZero";
      "Int32.isEven",        [`Int], `Bool, "teslrt.Int32IsEven";
      "Int32.isOdd",         [`Int], `Bool, "teslrt.Int32IsOdd";
      (* `sign` answers an `Int`, not an Int32, so it composes with Int arithmetic — the
         shape `Int.sign` has. *)
      "Int32.sign",          [`Int], `Int, "teslrt.Int32Sign";
      "Int32.digits",        [`Int], `Int, "teslrt.Int32Digits";
      "Int32.nonZero",       [`Int], `CheckInt, "teslrt.Int32NonZero";
      "Int32.nonNegative",   [`Int], `CheckInt, "teslrt.Int32NonNegative";
    ] in
    let leaf_names_for prefix =
      List.filter_map (fun (name, _, _, _) ->
        if String.length name > String.length prefix
           && String.sub name 0 (String.length prefix) = prefix then Some name else None)
        string_leaves
    in
    let string_leaf_names = leaf_names_for "String." in
    let int_leaf_names = leaf_names_for "Int." in
    let string_imports = ref [] in
    let float_leaf_names = leaf_names_for "Float." in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Float" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name float_leaf_names then begin
            string_imports := name :: !string_imports;
            if name = "Float.parse" then maybe_imported := true
          end else match name with
            | "Float" | "FloatNonZero" | "FloatNonNegative" -> ()
            (* The two Float values with no literal spelling.  They resolve through the
               constant table, the same path `Int32.minValue` takes. *)
            | "Float.infinity" ->
              Hashtbl.replace types.consts name (TFloat, "teslrt.FloatInfinity()")
            | "Float.nan" ->
              Hashtbl.replace types.consts name (TFloat, "teslrt.FloatNaN()")
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Float` export `%s` yet" other) exposed
      end) m.imports;
    (* `String.toInt` and `String.indexOf` return `Maybe Int`, so importing either
       one brings the runtime Maybe in even when the module never names Maybe. *)

    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Int" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name int_leaf_names then begin
            string_imports := name :: !string_imports;
            if name = "Int.parse" then maybe_imported := true
          end else match name with
            (* Proof predicates are compile-time only. *)
            | "IsNonZero" | "IsNonNegative" | "IsPositive" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Int` export `%s` yet" other) exposed
      end) m.imports;
    (* `Tesl.Int32` (NT-07): a 32-bit-bounded integer for wire and storage boundaries.  The
       type is NOMINAL for the checker and IS its integer at run time, so it registers as an
       ALIAS for `Int` rather than as a type of its own — `tesl/int32.rkt` says the same, and a
       wrapper here would put a struct where both backends store a number. *)
    let int32_leaf_names = leaf_names_for "Int32." in
    let int32_imported = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Int32" then begin
        int32_imported := true;
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name int32_leaf_names then begin
            string_imports := name :: !string_imports;
            (* Every narrowing answers a `Maybe`, so importing one brings the runtime Maybe
               in even where the module never names it. *)
            match name with
            | "Int32.fromInt" | "Int32.parse" | "Int32.fromFloat" | "Int32.add"
            | "Int32.subtract" | "Int32.multiply" | "Int32.negate" | "Int32.abs"
            | "Int32.pow" | "Int32.divide" -> maybe_imported := true
            | _ -> ()
          end else match name with
            (* The type name, and the two proof predicates, which erase. *)
            | "Int32" | "IsNonZero" | "IsNonNegative" -> ()
            (* The bounds are VALUES, not calls; registered as constants below. *)
            | "Int32.minValue" | "Int32.maxValue" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Int32` export `%s` yet" other) exposed
      end) m.imports;
    (* ── `Tesl.Env` / `Tesl.Random`: effects with no state of their own ──────
       Both are gated by a capability the checker enforces (`envRead`, `random`), so what
       is left at run time is one runtime call.  `requireSecret` answers the stdlib's own secret
       newtype (registered with `Tesl.Crypto`'s types); `envRead`/`random` themselves are
       capability NAMES. *)
    let env_leaf_names = ["env"; "envInt"; "envString"; "requireEnv"; "requireSecret"] in
    let random_leaf_names = ["randomInt"; "randomFloat"] in
    let effect_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      let exposed = match import.names with
        | ImportAll -> []
        | ImportExposing names -> names
      in
      match import.module_name with
      | "Tesl.Env" ->
        List.iter (fun name ->
          if List.mem name env_leaf_names then begin
            effect_imports := name :: !effect_imports;
            if name = "env" then maybe_imported := true
          end else match name with
            | "envRead" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Env` export `%s` yet" other) exposed
      | "Tesl.Random" ->
        List.iter (fun name ->
          if List.mem name random_leaf_names then
            effect_imports := name :: !effect_imports
          else match name with
            | "random" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Random` export `%s` yet" other) exposed
      | "Tesl.Id" ->
        List.iter (fun name ->
          match name with
          | "generateId" | "generatePrefixedId" ->
            effect_imports := name :: !effect_imports
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Id` export `%s` yet" other) exposed
      (* `Tesl.Cache` exposes the TYPE (the declaration's `= Cache { … }` head) and the four
         operations; `cacheCap` is a capability the checker enforces, so it has no emitted
         form. *)
      | "Tesl.Cache" ->
        List.iter (fun name ->
          match name with
          | "Cache.get" | "Cache.set" | "Cache.delete" | "Cache.invalidate" ->
            effect_imports := name :: !effect_imports;
            if name = "Cache.get" then maybe_imported := true
          | "Cache" | "cacheCap" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Cache` export `%s` yet" other) exposed
      (* `Tesl.UUID`.  Generation is gated by the `uuid` capability (the checker enforces
         it, so nothing survives here), and `UUID.validate` is a CHECK — an invalid string
         is the 400 the request answers with, not a trap.  `IsUuid` is the fact it mints,
         and a fact erases. *)
      | "Tesl.UUID" ->
        List.iter (fun name ->
          match name with
          | "UUID.v4" | "UUID.v7" | "UUID.validate" ->
            effect_imports := name :: !effect_imports
          | "uuid" | "IsUuid" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.UUID` export `%s` yet" other) exposed
      | _ -> ()) m.imports;
    (* ── `Tesl.Time`: the instant, and exact-integer millisecond arithmetic ──
       `PosixMillis` is runtime-provided for the reason `Maybe` is: an instant crosses
       module boundaries.  The CALENDAR surface (`formatTime`, the `Time.trunc*` buckets,
       `TimeZone`/`Time.offsetAt`) is refused — it needs the zone database and the shared
       bucket engine, which is its own slice — and so is the Duration bridge, which needs
       `Tesl.Units`. *)
    let time_leaf_names = [
      "nowMillis"; "durationMs"; "addMs"; "subtractMs"; "diffMs";
      "Time.posixToSeconds"; "Time.secondsToPosix";
      (* The units-typed instant surface: `Time.add ts (Duration.hours 2.0)`.  The
         millisecond forms above stay canonical — they are exact integer arithmetic — and
         these take a Duration, converting SI seconds to that exact count. *)
      "Time.add"; "Time.subtract"; "Time.diff";
      (* The calendar half: rendering, the bucket family, and the per-instant offset. *)
      "formatTime";
      "Time.truncHour"; "Time.truncDay"; "Time.truncWeek"; "Time.truncMonth";
      "Time.truncYear"; "Time.offsetAt";
    ] in
    let time_imports = ref [] in
    let zone_type_needed = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Time" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name time_leaf_names then time_imports := name :: !time_imports
          else match name with
            (* The type itself, and the `time` CAPABILITY (compile-time, like every
               other capability). *)
            | "PosixMillis" | "time" -> ()
            (* The `TimeZone` constructors.  A zone is one of a FIXED set — `Utc`, a fixed
               offset, or one of the 489 baked IANA zones — so a program cannot name a zone
               by a string it composed, and there is no zone-name typo to make at run time.
               They register below, where the type is in hand. *)
            | "TimeZone" | "Utc" | "FixedOffset" -> zone_type_needed := true
            | other when List.mem_assoc other Tz_zones.zones -> zone_type_needed := true
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Time` export `%s` yet" other) exposed;
        (* Registered whenever the module imports Tesl.Time at all: the type is named in
           signatures and entity columns even when no leaf is exposed. *)
        Hashtbl.replace types.newtypes "PosixMillis" {
          tesl_name = "PosixMillis";
          owner = "";
          go_name = "teslrt.PosixMillis";
          base = TInt;
          secret = false;
          loc = import.loc;
        };
        (* `TimeZone` is OPAQUE: a program passes one and never takes it apart, which is what
           lets the runtime carry a zone NAME and resolve the offset per instant.  `Utc` and
           each named zone are VALUES rather than calls, so they resolve through the constant
           table the way a bare currency name does; `FixedOffset` takes its minutes and is a
           signature. *)
        if !zone_type_needed then begin
          let zone = {
            rec_tesl_name = "TimeZone";
            rec_owner = "";
            rec_go_name = "teslrt.TimeZone";
            rec_proof_fields = false;
            rec_fields = [];
            rec_loc = import.loc;
          } in
          Hashtbl.replace types.records "TimeZone" zone;
          Hashtbl.replace types.consts "Utc" (TRecord zone, "teslrt.UtcZone()");
          List.iter (fun (ctor, iana) ->
            Hashtbl.replace types.consts ctor
              (TRecord zone, Printf.sprintf "teslrt.NamedZone(%s)" (go_quote iana)))
            Tz_zones.zones
        end
      end) m.imports;
    (* ── `Tesl.Crypto`, and the `Secret` its functions take ──────────────────
       `Secret` is registered whenever it can appear — `requireSecret` answers one, and every
       Crypto function that takes a key takes one — because it is a runtime-provided SECRET
       newtype: it redacts when printed, compares in constant time, and reaches an outbound
       header only through `HttpClient.bearer`.  `Signature` is a newtype over the hex tag,
       which is the representation the Racket runtime keeps, so a tag crossing between the two
       is the same string. *)
    let crypto_leaf_names = [
      "Crypto.hashPassword"; "Crypto.checkPassword"; "Crypto.needsRehash";
      "Crypto.signWith"; "Crypto.hmacSha256"; "Crypto.checkSignature";
      "Crypto.signatureHex"; "Crypto.signatureFromHex";
      "Crypto.signatureBase64"; "Crypto.signatureFromBase64";
      "Crypto.fingerprint"; "Crypto.keyFingerprint"; "Crypto.randomToken";
      "Crypto.sha256"; "Crypto.sha512";
    ] in
    let crypto_imports = ref [] in
    let sso_imported = ref false in
    let jwt_imports = ref [] in
    let jwt_type_needed = ref false in
    let secret_type_needed = ref false in
    List.iter (fun (import : import_decl) ->
      let exposed = match import.names with
        | ImportAll -> [] | ImportExposing names -> names in
      match import.module_name with
      | "Tesl.Telemetry" -> tuple_imported := true
      | "Tesl.Crypto" ->
        secret_type_needed := true;
        List.iter (fun name ->
          if List.mem name crypto_leaf_names then crypto_imports := name :: !crypto_imports)
          exposed
      (* An SSO connection holds the client SECRET, so importing the module brings that type
         into play even when the program never names it. *)
      | "Tesl.Sso" ->
        secret_type_needed := true;
        sso_imported := true
      (* The proxy binding is verified against a `Secret`, so it registers through the same
         block the crypto leaves do — that is where the type is in hand. *)
      | "Tesl.Proxy" ->
        secret_type_needed := true;
        List.iter (fun name ->
          if name = "Proxy.verifyBinding" then crypto_imports := name :: !crypto_imports)
          exposed
      | "Tesl.Env" ->
        if List.mem "requireSecret" exposed then secret_type_needed := true
      (* A JWT is signed with `Tesl.Crypto`'s `Secret`, so importing `Tesl.JWT` brings that type
         into play even when the module never names it. *)
      | "Tesl.JWT" ->
        secret_type_needed := true;
        jwt_type_needed := true;
        List.iter (fun name ->
          if List.mem name [ "JWT.sign"; "JWT.verify"; "JWT.renew"; "JWT.decode" ] then
            jwt_imports := name :: !jwt_imports) exposed
      | _ -> ()) m.imports;
    if !secret_type_needed then begin
      let loc = Location.dummy_loc m.source_file in
      Hashtbl.replace types.newtypes "Secret" {
        tesl_name = "Secret"; owner = ""; go_name = "teslrt.Secret";
        base = TString; secret = true; loc;
      };
      Hashtbl.replace types.newtypes "Signature" {
        tesl_name = "Signature"; owner = ""; go_name = "teslrt.Signature";
        base = TString; secret = false; loc;
      };
      (* A stored hash is opaque: a program stores it, verifies against it, or asks whether it
         needs re-minting.  It is NOT a secret newtype — a hash is safe to hold and to log,
         which is the entire reason for hashing — so it prints as itself. *)
      Hashtbl.replace types.newtypes "PasswordHash" {
        tesl_name = "PasswordHash"; owner = ""; go_name = "teslrt.PasswordHash";
        base = TString; secret = false; loc;
      }
    end;
    if !jwt_type_needed then
      (* The dot-separated `header.payload.signature` text.  Not a secret newtype: a session
         token is held, compared and put in a cookie by the program that owns it. *)
      Hashtbl.replace types.newtypes "JwtToken" {
        tesl_name = "JwtToken"; owner = ""; go_name = "teslrt.JwtToken";
        base = TString; secret = false; loc = Location.dummy_loc m.source_file;
      };
    (* ── `Tesl.HttpClient`: the outbound verbs ───────────────────────────────
       The `httpClient` capability erases with every other one; what the emitter needs is the
       four verbs, the two secret-accepting header builders, and the response record.
       `Tuple2` is registered as a side effect because the header list is a
       `List (Tuple2 String String)` whether or not the module names the type itself. *)
    let httpclient_leaf_names = [
      "HttpClient.get"; "HttpClient.post"; "HttpClient.put"; "HttpClient.delete";
      "HttpClient.bearer"; "HttpClient.secretHeader";
    ] in
    let httpclient_imports = ref [] in
    let httpclient_imported = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.HttpClient" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        List.iter (fun name ->
          if List.mem name httpclient_leaf_names then
            httpclient_imports := name :: !httpclient_imports) exposed;
        httpclient_imported := true;
        tuple_imported := true
      end) m.imports;
    (* The outbound-HTTP test double.  Its declarations and assertions are ordinary calls, so
       only the leaf table is needed — plus the per-test reset, emitted with the test bodies. *)
    let http_stub_leaf_names = [
      "stubHttp"; "stubHttpFailure"; "stubHttpTimeout";
      "httpCalled"; "httpCallCount"; "httpLastBody";
    ] in
    let http_stub_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.ApiTest" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        List.iter (fun name ->
          if List.mem name http_stub_leaf_names then
            http_stub_imports := name :: !http_stub_imports) exposed
      end) m.imports;
    (* ── `Tesl.Money` and `Tesl.Units` ──────────────────────────────────────
       Money is EXACT MINOR UNITS plus a currency, never a float; a dimensioned QUANTITY is
       the opposite — it erases to a plain Float, because its dimension lives in the compiler's
       type layer and is checked there.  Both are runtime-provided types: an amount and a
       quantity cross module boundaries, and two packages declaring their own would be
       different Go types.

       The NAMES come from the compiler's own catalogs (`Units_catalog`, `Currencies`) rather
       than a list retyped here, so a unit or a currency added there reaches this backend
       without a second edit — and the conversion FACTORS live only in `tesl/units.rkt`, from
       which `runtime/go/teslrt/units_data.go` is generated. *)
    let money_imported = ref false in
    let units_imported = ref false in
    let money_leaf_imports = ref [] in
    let dummy = Location.dummy_loc m.source_file in
    let runtime_record name go_name fields = {
      rec_tesl_name = name;
      rec_owner = "";
      rec_go_name = go_name;
      rec_proof_fields = false;
      rec_fields = fields;
      rec_loc = dummy;
    } in
    (* The currency a `Usd` / `Money.usd` constructor names, by its Tesl constructor name. *)
    let currency_of_ctor ctor =
      List.find_map (fun (c, iso, _, digits) ->
        if c = ctor then Some (iso, digits) else None) Currencies.currencies
    in
    let money_ctor_currency name =
      (* `Money.usd` — the lower-cased ISO code after the dot. *)
      match String.index_opt name '.' with
      | Some index ->
        let code = String.uppercase_ascii
          (String.sub name (index + 1) (String.length name - index - 1)) in
        List.find_map (fun (_, iso, _, digits) ->
          if iso = code then Some (iso, digits) else None) Currencies.currencies
      | None -> None
    in
    List.iter (fun (import : import_decl) ->
      let exposed = match import.names with
        | ImportAll -> [] | ImportExposing names -> names in
      match import.module_name with
      | "Tesl.Money" ->
        money_imported := true;
        List.iter (fun name ->
          if List.mem name Currencies.ctor_names
             || List.mem name Currencies.money_ctor_names
             || List.mem_assoc name Units_catalog.money_rate_aliases
          then ()
          else match name with
            | "Money" | "Currency" | "ExchangeRate" -> ()
            (* The proof predicates this module owns are compile-time, like every other. *)
            | "SameCurrency" | "NonNegativeMoney" | "RateFor" -> ()
            | leaf when String.length leaf > 6
                        && (String.sub leaf 0 6 = "Money." || String.sub leaf 0 9 = "Currency."
                            || String.sub leaf 0 13 = "ExchangeRate."
                            || String.sub leaf 0 10 = "MoneyRate.") ->
              money_leaf_imports := leaf :: !money_leaf_imports
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Money` export `%s` yet" other) exposed
      | "Tesl.Units" ->
        units_imported := true;
        List.iter (fun name ->
          if List.mem name Units_catalog.exported_names then begin
            (* An alias is a TYPE name; the rest are leaves the emitter binds below. *)
            if not (List.mem_assoc name Units_catalog.aliases) then
              money_leaf_imports := name :: !money_leaf_imports
          end else match name with
            | "FloatNonZero" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.Units` export `%s` yet" other) exposed
      | _ -> ()) m.imports;
    if !money_imported then begin
      let currency_record = runtime_record "Currency" "teslrt.Currency"
        [ "code", TString; "minorDigits", TInt ] in
      Hashtbl.replace types.records "Currency" currency_record;
      Hashtbl.replace types.records "Money"
        (runtime_record "Money" "teslrt.Money"
           [ "minorUnits", TInt; "currency", TRecord currency_record ]);
      (* An exchange rate holds an exact RATIONAL, which has no Tesl type — so it is opaque
         here: a program reads it through the accessors and never through a field. *)
      Hashtbl.replace types.records "ExchangeRate"
        (runtime_record "ExchangeRate" "teslrt.ExchangeRate" []);
      (* One rate ALIAS per denominator dimension.  They share the runtime type and differ in
         name, which is what lets a `/` know which unit its result displays and quantizes
         per — the dimension is not recoverable from a float. *)
      List.iter (fun (alias, _) ->
        Hashtbl.replace types.aliases alias
          (TRecord (runtime_record alias "teslrt.MoneyRate" [])))
        Units_catalog.money_rate_aliases
    end;
    (* `Int32` IS its integer at run time, so it is an alias rather than a type of its own.
       The nominal distinction is the checker's and does not survive here. *)
    if !int32_imported then begin
      Hashtbl.replace types.aliases "Int32" TInt;
      (* The bounds are VALUES rather than calls, so they resolve through the constant table —
         the same path a bare currency name (`Usd`) takes. *)
      Hashtbl.replace types.consts "Int32.minValue" (TInt, "teslrt.Int32MinValue");
      Hashtbl.replace types.consts "Int32.maxValue" (TInt, "teslrt.Int32MaxValue")
    end;
    if !units_imported then
      (* Every quantity alias is the QUANTITY type: a float64 in the emitted code, distinct in
         the emitter so a rate times a quantity and a rate times a scalar stay different
         operations. *)
      List.iter (fun (alias, _) -> Hashtbl.replace types.aliases alias TQuantity)
        Units_catalog.aliases;
    (* ── `Tesl.Url` and `Tesl.Net` ───────────────────────────────────────────
       `Url` is OPAQUE: `Url.parse` is the only way in, so a program cannot hand-build one
       whose host never went through the canonicaliser — which is what makes a check on a
       parsed URL a check on the URL a caller will then use.  `HostClass` is a real ADT: a
       program `case`s over a classification exhaustively, and the compiler is what makes
       "did you handle link-local?" a question with an answer. *)
    let url_imported = ref false in
    let net_imported = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Url" then url_imported := true;
      if import.module_name = "Tesl.Net" then net_imported := true) m.imports;
    if !url_imported then
      Hashtbl.replace types.records "Url"
        (runtime_record "Url" "teslrt.Url" []);
    if !net_imported then begin
      let loc = Location.dummy_loc m.source_file in
      Hashtbl.replace types.adts "HostClass" {
        adt_tesl_name = "HostClass";
        adt_owner = "";
        adt_go_name = "teslrt.HostClass";
        adt_tag_type = "teslrt.HostClassTag";
        adt_params = [];
        adt_variants = List.map (fun ctor ->
          { var_ctor = ctor; var_tag = Printf.sprintf "teslrt.HostClass%s"
              (match ctor with
               (* The three Go names that are not the constructor spelled straight: the
                  runtime calls them by their range, the surface by their address family. *)
               | "PrivateIp" -> "Private" | "PublicIp" -> "Public"
               | "InvalidHost" -> "Invalid" | other -> other);
            var_fields = []; var_go_fields = []; var_loc = loc })
          [ "Loopback"; "PrivateIp"; "LinkLocal"; "Cgnat"; "Multicast";
            "Unspecified"; "PublicIp"; "DomainName"; "InvalidHost" ];
        adt_loc = loc;
        adt_builtin = true;
      }
    end;
    (* ── `Tesl.Agent` ────────────────────────────────────────────────────────
       The agent SPEC is written as a record literal — `Agent { provider: …, systemPrompt: …,
       maxTokens: …, tools: … }` — so it registers with its fields and reaches the ordinary
       record-literal path; the Go struct carries the same four names.

       Everything else the module exposes is OPAQUE: a provider, a reply, a tool, a scripted
       mock step, a conversation and one turn of it are values a program holds, passes on and
       reads through FUNCTIONS, never through a field.  Each registers with no fields, the
       same treatment `DeadJob` and `ExchangeRate` get, so a program cannot reach inside one
       and the runtime stays free to change what is in it. *)
    let agent_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Agent" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        List.iter (fun name -> agent_imports := name :: !agent_imports) exposed
      end) m.imports;
    if !agent_imports <> [] then begin
      let provider = runtime_record "LlmProvider" "teslrt.LlmProvider" [] in
      let tool = runtime_record "Tool" "teslrt.Tool" [] in
      List.iter (fun (info : record_info) ->
        Hashtbl.replace types.records info.rec_tesl_name info)
        [ provider; tool;
          runtime_record "Agent" "teslrt.Agent"
            [ "provider", TRecord provider; "systemPrompt", TString;
              "maxTokens", TInt; "tools", TList (TRecord tool) ];
          runtime_record "AgentReply" "teslrt.AgentReply" [];
          (* A mock script entry IS a normalised provider response at run time, which is why
             the Go name is the response rather than a type of its own. *)
          runtime_record "ToolStep" "teslrt.LlmResponse" [];
          runtime_record "Conversation" "teslrt.Conversation" [];
          runtime_record "ConversationTurn" "teslrt.ConversationTurn" [] ]
    end;
    (* `deadJobs` answers the dead-letter contents of a queue.  Its element type is opaque
       (`DeadJob`), so what a test can do with the list is count it or requeue from it — which
       is what the Racket surface allows too. *)
    let dead_jobs_imported = ref false in
    let requeue_imported = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Queue" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        if List.mem "deadJobs" exposed || List.mem "requeue" exposed then
          dead_jobs_imported := true;
        (* `requeue` is an ordinary function over a `DeadJob`, unlike the queue VERBS, which
           name a queue and are resolved statically. *)
        if List.mem "requeue" exposed then requeue_imported := true
      end) m.imports;
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.String" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          if List.mem name string_leaf_names then begin
            string_imports := name :: !string_imports;
            if name = "String.toInt" || name = "String.indexOf" then maybe_imported := true
          end else match name with
            (* The proof predicates are compile-time only: they erase with every
               other proof, so importing one needs no runtime support. *)
            | "IsTrimmed" | "IsUpperCase" | "IsLowerCase" | "IsNonNegative"
            | "IsNonEmpty" -> ()
            | other -> unsupported import.loc
              "Go backend does not support `Tesl.String` export `%s` yet" other) exposed
      end) m.imports;
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Tuple" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          match name with
          | "Tuple2" | "Tuple3" | "Tuple2(..)" | "Tuple3(..)"
          | "Tuple2.first" | "Tuple2.second"
          | "Tuple3.first" | "Tuple3.second" | "Tuple3.third" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Tuple` export `%s` yet" other) exposed;
        tuple_imported := true
      end) m.imports;
    if !tuple_imported then begin
      let loc = Location.dummy_loc m.source_file in
      let component index = Printf.sprintf "%c" (Char.chr (Char.code 'A' + index)) in
      List.iter (fun (name, arity) ->
        let fields = List.init arity (fun index ->
          let field = List.nth ["first"; "second"; "third"] index in
          field, TParam (component index)) in
        let go_fields = List.map (fun (field, _) ->
          field, name ^ go_ident ~exported:true field) fields in
        Hashtbl.replace types.adts name {
          adt_tesl_name = name;
          adt_owner = "";
          adt_go_name = "teslrt." ^ name;
          adt_tag_type = "teslrt." ^ name ^ "Tag";
          adt_params = List.init arity (fun index ->
            String.lowercase_ascii (component index), component index);
          adt_variants = [
            { var_ctor = name; var_tag = "teslrt." ^ name ^ "Only";
              var_fields = fields; var_go_fields = go_fields; var_loc = loc };
          ];
          adt_loc = loc;
          adt_builtin = true;
        }) ["Tuple2", 2; "Tuple3", 3]
    end;
    (* The outbound `HttpResponse`: `{ status: Int, body: String, headers: List (Tuple2 String
       String) }`.  Its `body` is response TEXT, not a parsed value — an outbound call is
       ordinary program code, so a body it wants to read structurally goes through a codec
       like any other string, and `String.contains resp.body "…"` stays a String operation. *)
    if !httpclient_imported then begin
      let loc = Location.dummy_loc m.source_file in
      let header_pair = match Hashtbl.find_opt types.adts "Tuple2" with
        | Some info -> TAdt (info, [TString; TString])
        | None -> unsupported loc "Go backend needs `Tuple2` for HttpClient headers"
      in
      Hashtbl.replace types.records "HttpResponse" {
        rec_tesl_name = "HttpResponse";
        rec_owner = "";
        rec_go_name = "teslrt.HttpResponse";
        rec_proof_fields = false;
        rec_fields = [ "status", TInt; "body", TString; "headers", TList header_pair ];
        rec_loc = loc;
      }
    end;
    (* `DeadJob` is opaque: the runtime carries the job's identity and nothing a program can
       read, so the element type is a runtime struct with no Tesl-visible fields. *)
    if !dead_jobs_imported then
      Hashtbl.replace types.records "DeadJob" {
        rec_tesl_name = "DeadJob";
        rec_owner = "";
        rec_go_name = "teslrt.DeadJob";
        rec_proof_fields = false;
        rec_fields = [];
        rec_loc = Location.dummy_loc m.source_file;
      };
    (* `HttpRequest` is runtime-provided too: a plain record the dispatcher builds once per
       request.  Only the fields Tesl exposes are present, so an ejecting author is not
       handed the whole net/http surface. *)
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Http" || import.module_name = "Tesl.ApiTest" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        (* Registered whenever `Tesl.ApiTest` is imported at all, not only when the type
           is named in the exposing list: a module may import just `statusOk` and still
           write `let r = get "/path"`, whose result IS this type. *)
        if import.module_name = "Tesl.ApiTest" then begin
          let api_response = {
            rec_tesl_name = "HttpResponse";
            rec_owner = "";
            rec_go_name = "teslrt.ApiResponse";
            rec_proof_fields = false;
        rec_fields = [
              (* `body` is a PARSED JSON value, matching Racket: `api-test-field-access-ref`
                 normalises the response and hands back the parsed body, which is why
                 `resp.body.userId` reads like the JSON it checks. *)
              "status", TInt; "body", TJson; "headers", TDict (TString, TString);
            ];
            rec_loc = import.loc;
          } in
          (* The checker has ONE opaque `HttpResponse`, shared by `Tesl.ApiTest` and
             `Tesl.HttpClient`, because field access on it is untyped either way.  The two
             backends' RUNTIME shapes differ (a parsed body here, response text and a header
             list there), and a module may import both — lesson58 does — so the api-test
             shape is kept under a key no Tesl type name can spell, and the NAME resolves to
             the outbound response whenever `Tesl.HttpClient` is imported: that is the one an
             annotation like `-> HttpResponse` can mention. *)
          Hashtbl.replace types.records api_response_key api_response;
          if not !httpclient_imported then
            Hashtbl.replace types.records "HttpResponse" api_response
        end;
        if List.mem "HttpRequest" exposed then begin
          let string_dict = TDict (TString, TString) in
          (* No explicit Go field names are needed: `record_field_go_name` capitalises, and
             the runtime struct is written with exactly those names.  `rec_owner = ""`
             keeps the declaration from being emitted, the same way `Maybe` does it. *)
          Hashtbl.replace types.records "HttpRequest" {
            rec_tesl_name = "HttpRequest";
            rec_owner = "";
            rec_go_name = "teslrt.HttpRequest";
            rec_proof_fields = false;
        rec_fields = [
              "method", TString; "path", TString;
              "cookies", string_dict; "headers", string_dict;
              "queryParameters", string_dict; "body", TString;
            ];
            rec_loc = import.loc;
          }
        end
      end) m.imports;
    (* `Either` is the same runtime-provided shape as `Maybe`: two variants, one
       payload each, provided by teslrt so it can cross module boundaries. *)
    let either_imported = ref false in
    (* The `Either.*` FUNCTIONS a module imported.  Like the container leaves they are typed
       per call site, so the entry only marks the name as available. *)
    let either_fn_imports = ref [] in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Either" || import.module_name = "Tesl.EitherPrim" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          match name with
          | "Either" | "Either(..)" | "Left" | "Right" -> ()
          (* `partition` answers the two sides as a tuple, so importing it brings the runtime
             tuple in even when the module never names Tuple2; the four that answer a Maybe
             bring that in for the same reason. *)
          | "Either.partition" ->
            tuple_imported := true; either_fn_imports := name :: !either_fn_imports
          | "Either.fromLeft" | "Either.fromRight" | "Either.toMaybe" | "Either.fromMaybe" ->
            maybe_imported := true; either_fn_imports := name :: !either_fn_imports
          | "Either.isLeft" | "Either.isRight" | "Either.withDefault"
          | "Either.map" | "Either.mapLeft" | "Either.andThen" ->
            either_fn_imports := name :: !either_fn_imports
          | other -> unsupported import.loc
            "Go backend does not support `%s` export `%s` yet" import.module_name other) exposed;
        either_imported := true
      end) m.imports;
    (* `JobResult` is the queue counterpart: `JobOk job` and `JobFailed job error` — the
       failed case carries BOTH, as it does on the Racket side, so a test can assert on the
       payload of a job that failed. *)
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.ApiTest" then begin
        let loc = import.loc in
        Hashtbl.replace types.adts "JobResult" {
          adt_tesl_name = "JobResult";
          adt_owner = "";
          adt_go_name = "teslrt.JobResult";
          adt_tag_type = "teslrt.JobResultTag";
          adt_params = ["job", "Payload"];
          adt_variants = [
            { var_ctor = "JobOk"; var_tag = "teslrt.JobResultOk";
              var_fields = ["job", TParam "Payload"];
              var_go_fields = ["job", "OkJob"]; var_loc = loc };
            { var_ctor = "JobFailed"; var_tag = "teslrt.JobResultFailed";
              var_fields = ["job", TParam "Payload"; "error", TString];
              var_go_fields = ["job", "FailedJob"; "error", "FailedError"]; var_loc = loc };
          ];
          adt_loc = loc;
          adt_builtin = true;
        }
      end) m.imports;
    (* `DeleteResult` is what `deleteAndReturnResult` answers: `NoRowDeleted` or
       `RowsDeleted n`.  Runtime-provided for the reason `Maybe` is, and registered on the
       import that names it rather than unconditionally, so a module that never deletes with a
       result carries no reference to it. *)
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.DB" then begin
        let loc = import.loc in
        Hashtbl.replace types.adts "DeleteResult" {
          adt_tesl_name = "DeleteResult";
          adt_owner = "";
          adt_go_name = "teslrt.DeleteResult";
          adt_tag_type = "teslrt.DeleteResultTag";
          adt_params = [];
          adt_variants = [
            { var_ctor = "NoRowDeleted"; var_tag = "teslrt.DeleteResultNoRowDeleted";
              var_fields = []; var_go_fields = []; var_loc = loc };
            { var_ctor = "RowsDeleted"; var_tag = "teslrt.DeleteResultRowsDeleted";
              var_fields = ["count", TInt];
              var_go_fields = ["count", "RowsDeletedCount"]; var_loc = loc };
          ];
          adt_loc = loc;
          adt_builtin = true;
        }
      end) m.imports;
    (* `Result ok err` is the same runtime-provided shape as `Either`: two variants, one
       payload each, provided by teslrt so it can cross module boundaries.  Tesl.Result
       exports the type and its constructors only — there are no `Result.*` functions. *)
    let result_imported = ref false in
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Result" then begin
        let exposed = match import.names with
          | ImportAll -> []
          | ImportExposing names -> names
        in
        List.iter (fun name ->
          match name with
          | "Result" | "Result(..)" | "Ok" | "Err" -> ()
          | other -> unsupported import.loc
            "Go backend does not support `Tesl.Result` export `%s` yet" other) exposed;
        result_imported := true
      end) m.imports;
    if !result_imported then begin
      let loc = Location.dummy_loc m.source_file in
      Hashtbl.replace types.adts "Result" {
        adt_tesl_name = "Result";
        adt_owner = "";
        adt_go_name = "teslrt.Result";
        adt_tag_type = "teslrt.ResultTag";
        adt_params = ["ok", "Ok"; "err", "Err"];
        adt_variants = [
          { var_ctor = "Ok"; var_tag = "teslrt.ResultOk";
            var_fields = ["value", TParam "Ok"];
            var_go_fields = ["value", "OkValue"]; var_loc = loc };
          { var_ctor = "Err"; var_tag = "teslrt.ResultErr";
            var_fields = ["error", TParam "Err"];
            var_go_fields = ["error", "ErrValue"]; var_loc = loc };
        ];
        adt_loc = loc;
        adt_builtin = true;
      }
    end;
    (* `EmailBody` is runtime-provided for the reason `Maybe` is: a `fn … -> EmailBody`
       crosses module boundaries, and two packages declaring their own would be different Go
       types.  Three variants, and no fourth for "no body" — which is the point of the ADT:
       a body-less email is unconstructible. *)
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Email" then begin
        let loc = import.loc in
        Hashtbl.replace types.adts "EmailBody" {
          adt_tesl_name = "EmailBody";
          adt_owner = "";
          adt_go_name = "teslrt.EmailBody";
          adt_tag_type = "teslrt.EmailBodyTag";
          adt_params = [];
          adt_variants = [
            { var_ctor = "TextBody"; var_tag = "teslrt.EmailBodyText";
              var_fields = ["content", TString];
              var_go_fields = ["content", "Text"]; var_loc = loc };
            { var_ctor = "HtmlBody"; var_tag = "teslrt.EmailBodyHTML";
              var_fields = ["content", TString];
              var_go_fields = ["content", "HTML"]; var_loc = loc };
            { var_ctor = "RichBody"; var_tag = "teslrt.EmailBodyRich";
              var_fields = ["text", TString; "html", TString];
              var_go_fields = ["text", "Text"; "html", "HTML"]; var_loc = loc };
          ];
          adt_loc = loc;
          adt_builtin = true;
        }
      end) m.imports;
    if !either_imported then begin
      let loc = Location.dummy_loc m.source_file in
      Hashtbl.replace types.adts "Either" {
        adt_tesl_name = "Either";
        adt_owner = "";
        adt_go_name = "teslrt.Either";
        adt_tag_type = "teslrt.EitherTag";
        adt_params = ["a", "A"; "b", "B"];
        adt_variants = [
          { var_ctor = "Left"; var_tag = "teslrt.EitherLeft";
            var_fields = ["value", TParam "A"];
            var_go_fields = ["value", "LeftValue"]; var_loc = loc };
          { var_ctor = "Right"; var_tag = "teslrt.EitherRight";
            var_fields = ["value", TParam "B"];
            var_go_fields = ["value", "RightValue"]; var_loc = loc };
        ];
        adt_loc = loc;
        adt_builtin = true;
      }
    end;
    if !maybe_imported then begin
      let loc = Location.dummy_loc m.source_file in
      Hashtbl.replace types.adts "Maybe" {
        adt_tesl_name = "Maybe";
        adt_owner = "";
        adt_go_name = "teslrt.Maybe";
        adt_tag_type = "teslrt.MaybeTag";
        adt_params = ["a", "A"];
        adt_variants = [
          { var_ctor = "Nothing"; var_tag = "teslrt.MaybeNothing";
            var_fields = []; var_go_fields = []; var_loc = loc };
          { var_ctor = "Something"; var_tag = "teslrt.MaybeSomething";
            var_fields = ["value", TParam "A"]; var_go_fields = []; var_loc = loc };
        ];
        adt_loc = loc;
        adt_builtin = true;
      }
    end;
    let adt_forms = List.filter_map (function
      | DType (TypeAdt { name; params; variants; loc }) -> Some (name, params, variants, loc)
      | _ -> None) m.decls in
    List.iter (fun (name, params, variants, loc) ->
      if variants = [] then unsupported loc "Go backend requires `%s` to have variants" name;
      List.iter (fun (variant : adt_variant) ->
        List.iter (fun (field : field_def) ->
          (* A proof ANNOTATION on a constructor field is a type-level contract with no
             runtime structure — the frontend has discharged it before anything reaches
             here — so the field is its own type, exactly as a proof-annotated record field
             and a proof-carrying return are.  What the annotation buys is that a `Node`
             cannot be BUILT without a proven value, and that is the checker's to enforce on
             both backends. *)
          if field.checker <> None then unsupported field.loc
            "Go backend does not support `via` on constructor field `%s.%s` yet"
            variant.ctor field.name) variant.fields) variants;
      if Hashtbl.mem types.newtypes name || Hashtbl.mem types.records name
         || Hashtbl.mem types.adts name then
        unsupported loc "Go backend generated type name collision for `%s`" name;
      let go_name = package_ident name in
      (* Type parameters live in the type's own scope, so they are named
         independently of the package-level uniqueness table. *)
      let param_names = Hashtbl.create 4 in
      let go_params = List.map (fun param ->
        param, unique_ident param_names (go_ident ~exported:true param)) params in
      Hashtbl.replace types.adts name {
        adt_tesl_name = name;
        adt_owner = package;
        adt_go_name = go_name;
        adt_tag_type = unique_ident taken (go_name ^ "Tag");
        adt_params = go_params;
        adt_variants = List.map (fun (variant : adt_variant) -> {
          var_ctor = variant.ctor;
          var_tag = unique_ident taken (go_name ^ go_ident ~exported:true variant.ctor);
          var_fields = [];
          var_go_fields = [];
          var_loc = variant.loc;
        }) variants;
        adt_loc = loc;
        adt_builtin = false;
      }) adt_forms;
    (* An imported TYPE is registered here, before any field type is resolved: a record
       field may name one (`role: OrgRole`), and the full import registration — which also
       brings the values across — runs later, once the signature table exists. *)
    List.iter (fun (import : import_decl) ->
      match List.find_opt (fun dependency ->
              dependency_named dependency import.module_name) dependencies with
      | None -> ()
      | Some dependency ->
        let exposed = match import.names with
          | ImportAll ->
            List.of_seq (Hashtbl.to_seq_keys dependency.ex_types.records)
            @ List.of_seq (Hashtbl.to_seq_keys dependency.ex_types.newtypes)
            @ List.of_seq (Hashtbl.to_seq_keys dependency.ex_types.adts)
          | ImportExposing names -> names
        in
        register_imported_types ~exposed types dependency)
      m.imports;
    (* Field types resolve only after every named type is registered, so records and
       ADTs may reference each other; a cycle would be an infinitely sized Go value
       and is rejected below. *)
    List.iter (fun (r : record_form) ->
      let info = Hashtbl.find types.records r.name in
      info.rec_fields <- List.map (fun (field : field_def) ->
        field.name, type_of_type_expr types field.type_expr) r.fields) record_forms;
    List.iter (fun (e : entity_form) ->
      let info = Hashtbl.find types.records e.name in
      info.rec_fields <- List.map (fun (field : field_def) ->
        field.name, type_of_type_expr types field.type_expr) e.fields) entity_forms;
    (* Registered HERE rather than with the other declarations: a cache's `valueType:` may
       name an ENTITY (`valueType: User`), whose row type exists only once the entity fields
       above are resolved. *)
    (* A `cache` declaration is one package-level store, typed by `valueType:`. *)
    List.iter (fun (c : cache_form) ->
      let c = Desugar.desugar_cache_config c in
      let value =
        try type_of_type_expr types c.value_type
        with Unsupported _ ->
          unsupported c.loc "Go backend cannot resolve the value type of cache `%s`" c.name
      in
      Hashtbl.replace types.caches c.name {
        ca_tesl_name = c.name;
        ca_go_var = package_ident (c.name ^ "Store");
        ca_owner = package;
        ca_value = value;
        ca_default_ttl = Option.value c.default_ttl ~default:0;
        ca_loc = c.loc;
      })
      (List.filter_map (function DCache c -> Some c | _ -> None) m.decls);
    (* An `email` declaration is one package-level outbox, carrying the SMTP settings the
       declaration fixed. *)
    List.iter (fun (e : email_form) ->
      let e = Desugar.desugar_email_config e in
      Hashtbl.replace types.emails e.name {
        em_tesl_name = e.name;
        em_go_var = package_ident (e.name ^ "Outbox");
        em_owner = package;
        em_host = go_config_value e.loc e.smtp.host;
        em_port = e.smtp.port;
        em_username = go_config_value e.loc e.smtp.username;
        em_password = go_config_value e.loc e.smtp.password;
        em_tls = e.smtp.tls;
        em_loc = e.loc;
      })
      (List.filter_map (function DEmail e -> Some e | _ -> None) m.decls);
    (* An `sseChannel` declaration is one package-level channel, typed by `payload:`. *)
    List.iter (fun (c : channel_form) ->
      let c = Desugar.desugar_channel_config c in
      let payload =
        try type_of_type_expr types c.payload
        with Unsupported _ ->
          unsupported c.loc "Go backend cannot resolve the payload type of channel `%s`" c.name
      in
      if List.length c.key_params > 1 then unsupported c.loc
        "Go backend supports a channel with at most one key parameter (`%s`)" c.name;
      List.iter (fun (binding : binding) ->
        if type_of_type_expr types binding.type_expr <> TString then unsupported c.loc
          "Go backend channel key `%s.%s` must be a String" c.name binding.name)
        c.key_params;
      Hashtbl.replace types.channels c.name {
        ch_tesl_name = c.name;
        ch_go_var = package_ident (c.name ^ "Channel");
        ch_owner = package;
        ch_payload = payload;
        ch_key_params = List.length c.key_params;
        ch_loc = c.loc;
      })
      (List.filter_map (function DChannel c -> Some c | _ -> None) m.decls);
    List.iter (fun (name, _, variants, _) ->
      let info = Hashtbl.find types.adts name in
      (* The ADT's own type parameters are in scope only here, while resolving the
         field types of its variants. *)
      let params = info.adt_params in
      List.iter2 (fun (variant : adt_variant) target ->
        target.var_fields <- List.map (fun (field : field_def) ->
          field.name, type_of_type_expr ~params types field.type_expr) variant.fields)
        variants info.adt_variants) adt_forms;
    let contained = function
      | TRecord info -> `Record info
      | TAdt (info, _) -> `Adt info
      | _ -> `Scalar
    in
    let rec reaches target visited ty =
      match contained ty with
      | `Scalar -> false
      | `Record info ->
        info.rec_tesl_name = target
        || (not (List.mem info.rec_tesl_name visited)
            && List.exists (fun (_, field_ty) ->
                 reaches target (info.rec_tesl_name :: visited) field_ty) info.rec_fields)
      | `Adt info ->
        info.adt_tesl_name = target
        || (not (List.mem info.adt_tesl_name visited)
            && List.exists (fun variant ->
                 List.exists (fun (_, field_ty) ->
                   reaches target (info.adt_tesl_name :: visited) field_ty) variant.var_fields)
                 info.adt_variants)
    in
    List.iter (fun (r : record_form) ->
      let info = Hashtbl.find types.records r.name in
      if List.exists (fun (_, field_ty) -> reaches r.name [r.name] field_ty) info.rec_fields then
        unsupported r.loc "Go backend does not support the recursive record `%s`" r.name)
      record_forms;
    List.iter (fun (e : entity_form) ->
      let info = Hashtbl.find types.records e.name in
      if List.exists (fun (_, field_ty) -> reaches e.name [e.name] field_ty) info.rec_fields then
        unsupported e.loc "Go backend does not support the recursive entity `%s`" e.name)
      entity_forms;
    (* A DIRECT self-reference in a payload field (`Add left: Expr right: Expr`) is
       supported: the field is a pointer, boxed at construction and unboxed at every read.
       Everything else still fails closed — a self-reference reached THROUGH another value
       type (`inner: Maybe Expr`) would need the indirection inside that type's layout, and
       a generic ADT's self-reference is refused because the corpus spells it at a different
       instantiation (`type Tree a = … left: (Tree Int)`), which Go rejects as an
       instantiation cycle rather than compiling to anything. *)
    List.iter (fun (name, _, _, loc) ->
      let info = Hashtbl.find types.adts name in
      (* Containment BY VALUE is what makes a Go type infinite: `Maybe Chain` holds a Chain
         inside its own struct, and so does a record field, while a `List Chain` does not — a
         slice is a reference and has a fixed size whatever it points at.  So the refusal is
         about value containment, not about mentioning the type. *)
      let rec contains_self ty =
        match ty with
        | TAdt (other, args) ->
          other.adt_go_name = info.adt_go_name || List.exists contains_self args
        | TRecord record -> List.exists (fun (_, field_ty) -> contains_self field_ty)
                              record.rec_fields
        | TNewtype newtype -> contains_self newtype.base
        | TCheck inner -> contains_self inner
        | TList _ | TSet _ | TDict _ | TFunc _ -> false
        | TInt | TFloat | TQuantity | TString | TBool | TUnit | TJson | TStream | TParam _
        | TFailure | TAnon -> false
      in
      let indirectly_recursive =
        List.exists (fun variant ->
          List.exists (fun (_, field_ty) ->
            (not (adt_self_field info field_ty))
            && (contains_self field_ty || reaches name [name] field_ty))
            variant.var_fields) info.adt_variants
      in
      let directly_recursive =
        List.exists (fun variant ->
          List.exists (fun (_, field_ty) -> adt_self_field info field_ty) variant.var_fields)
          info.adt_variants
      in
      if indirectly_recursive then
        unsupported loc
          "Go backend supports a recursive type only where the payload field IS the type \
           itself (`%s`)" name
      (* A GENERIC type may refer to itself at its own instantiation (`MkNode left:
         (MyTree a)` inside `MyTree a`, emitted `*MyTree[A]`) or at another one (`left:
         (Tree Int)` inside `Tree a`, emitted `*Tree[teslrt.Int]`).  Both are pointers and
         both are legal Go: the instantiation cycle Go rejects is the one whose type ARGUMENT
         grows, and neither of these does. *)
      else ignore directly_recursive)
      adt_forms;
    List.iter (function
      | DFunc _ | DTest _ -> ()
      | DType (TypeNewtype _) -> ()
      | DRecord _ -> ()
      | DType (TypeAlias { loc; _ }) ->
        unsupported loc "Go backend does not support transparent type aliases yet"
      | DType (TypeAdt _) -> ()
      | DEntity _ -> ()
      | DFact _ -> ()
      | DCodec _ -> ()
      (* A `database` declaration names a BACKEND and the entities it owns, and on BOTH
         backends it is inert: a query reaches a declared database only inside `with
         database D`, and everything outside one runs against the entity's own store
         (Racket's `current-database-runtime` is #f until `call-with-database` binds it,
         and its emitted `define-database` connects to nothing before that).  So the
         declaration itself emits nothing here, whichever backend it selects, and the one
         place the choice becomes observable is `with database` — see the refusal there. *)
      | DDatabase d ->
        (* The typed form (`= Database { … }`) leaves its fields in `config_expr`; the Go
           pipeline does not run the desugar pass, so the same lowering the Racket
           backend gets is applied to this one declaration.  Reusing that function is the
           point — a second reading of the config block here would be a second place for
           `backend:` to be misread. *)
        let d = Desugar.desugar_database_config d in
        let backend = String.lowercase_ascii d.backend in
        if backend <> "memory" && backend <> "postgres" && backend <> "" then
          unsupported d.loc "Go backend does not know the database backend `%s`"
            (String.capitalize_ascii d.backend);
        List.iter (fun entity ->
          if not (Hashtbl.mem types.entities entity) then unsupported d.loc
            "Go backend cannot find entity `%s` listed in database `%s`" entity d.name)
          d.entities
      (* A `capability` DECLARATION grants nothing at run time: the checker verifies every
         call against the declared set and forces the grant to propagate to callers, so the
         declaration has no emitted form — the same reason a `requires` clause has none. *)
      | DCapability _ -> ()
      (* A module-level constant becomes a package-level `var`.  Its NAME is minted here, in
         declaration order with every other package-level name, so it cannot collide; its TYPE
         is settled where the value is emitted, since typing it needs the signature table. *)
      | DConst _ -> ()
      (* Validated and registered above; the store variable is emitted with the tables. *)
      | DQueue _ -> ()
      (* An `sseChannel` declaration emits its channel above, with the other package-level
         state; the capability it needs (`pubsub`) is compile-time, like every other. *)
      | DChannel _ -> ()
      (* A `workers` block wires job types to worker functions.  With the folded `jobs:`
         form the wiring is already on the queue, and the workers only RUN on App
         activation, which is its own slice — so the declaration itself adds nothing. *)
      | DWorkers _ -> ()
      (* A `cache` declaration emits its store above, with the other package-level state; the
         capability it mints (`cacheCap C`) is compile-time, like every other. *)
      | DCache _ -> ()
      (* Emitted with the module-level values below. *)
      | DAgent _ -> ()
      (* An `email` declaration emits its outbox above, with the other package-level state;
         `emailCap` is compile-time, like every other capability. *)
      | DEmail _ -> ()
      (* A `capturer` is metadata about how a path segment is parsed and checked; the
         check function it names is an ordinary `check` the emitter already handles. *)
      | DCapture _ -> ()
      | DApi _ -> ()
      | DServer _ -> ()
      | DApiTest _ -> ()
      (* Emitted with the tests below. *)
      | DLoadTest _ -> ()) m.decls;
    let is_exported name = List.exists (function
      | ExportName exported -> exported = name
      | ExportAdt _ -> false) m.exports in
    let function_names = List.map (fun (fd : func_decl) -> fd.name) funcs in
    let graph = List.map (fun (fd : func_decl) ->
      let calls = ref [] in
      Ast_visitor.iter (function
        | EVar { name; _ } when List.mem name function_names && not (List.mem name !calls) ->
          calls := name :: !calls
        | _ -> ()) fd.body;
       fd.name, !calls) funcs in
    let test_roots = ref [] in
    (* A top-level `agent … = Agent { … }` block names functions too — `asTool myFn` wires
       one in as a tool — and those are as reachable as anything a body calls.  Without this
       the declaration's tool functions counted as unreachable and were kept alive by a
       `var _ = f` reference, which says the opposite of what is true. *)
    List.iter (function
      | DAgent { config_expr = Some config; _ } ->
        Ast_visitor.iter (function
          | EVar { name; _ } when List.mem name function_names ->
            if not (List.mem name !test_roots) then test_roots := name :: !test_roots
          | _ -> ()) config
      | _ -> ()) m.decls;
    List.iter (fun (test : test_form) ->
      List.iter (fun stmt ->
        List.iter (Ast_visitor.iter (function
          | EVar { name; _ } when List.mem name function_names ->
            if not (List.mem name !test_roots) then test_roots := name :: !test_roots
          | _ -> ())) (Ast.test_stmt_exprs stmt)) test.stmts) tests;
    let rec reachable visited name =
      if List.mem name visited then visited
      else
        let visited = name :: visited in
        match List.assoc_opt name graph with
        | None -> visited
        | Some calls -> List.fold_left reachable visited calls
    in
    let roots = !test_roots @ List.filter is_exported function_names in
    let reachable_names = List.fold_left reachable [] roots in
    let unreachable_private = List.filter_map (fun (fd : func_decl) ->
      if List.mem fd.name reachable_names then None else Some fd.name) funcs in
    let signatures = Hashtbl.create
      (List.length funcs + Hashtbl.length types.newtypes + Hashtbl.length types.records) in
    (* A fact's own signature: no parameters to type against (a proof term's arguments are
       proof SUBJECTS, not values the emitter checks) and the zero-size proof as result. *)
    List.iter (fun name ->
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name {
          params = []; result = TUnit;
          go_name = "struct{}{}"; sig_owner = ""; sig_needs_scope = false;
        }) fact_names;
    Hashtbl.iter (fun name info ->
      Hashtbl.add signatures name {
        params = [info.base];
        result = TNewtype info;
        go_name = info.go_name; sig_owner = info.owner; sig_needs_scope = false;
      }) types.newtypes;
    Hashtbl.iter (fun name info ->
      Hashtbl.add signatures name {
        params = List.map snd info.rec_fields;
        result = TRecord info;
        go_name = info.rec_go_name; sig_owner = info.rec_owner; sig_needs_scope = false;
      }) types.records;
    (* Each constructor is its own signature entry: the surface syntax names the
       constructor, and the variant it belongs to is recovered from the result type. *)
    Hashtbl.iter (fun _ info ->
      List.iter (fun variant ->
        if Hashtbl.mem signatures variant.var_ctor then unsupported variant.var_loc
          "Go backend generated name collision for constructor `%s`" variant.var_ctor;
        (* The result carries no type arguments: it exists so a constructor
           application can find its ADT, which then infers the arguments. *)
        Hashtbl.add signatures variant.var_ctor {
          params = List.map snd variant.var_fields;
          result = TAdt (info, []);
          go_name = variant.var_tag; sig_owner = info.adt_owner; sig_needs_scope = false;
        }) info.adt_variants) types.adts;
    (* Imported stdlib leaves are ordinary signatures whose Go name is a runtime
       function, so the existing call machinery emits them with no special case. *)
    (* A list leaf is registered only so the call arms can tell an imported name from
       an unresolved one; its params/result are computed per call site. *)
    List.iter (fun name ->
      let leaf = match set_leaf name with Some leaf -> leaf | None -> assert false in
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name
          { params = []; result = TFailure; go_name = leaf.set_go; sig_owner = ""; sig_needs_scope = false }) !set_imports;
    List.iter (fun name ->
      let leaf = match dict_leaf name with Some leaf -> leaf | None -> assert false in
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name
          { params = []; result = TFailure; go_name = leaf.dict_go; sig_owner = ""; sig_needs_scope = false }) !dict_imports;
    List.iter (fun name ->
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name
          { params = []; result = TFailure; go_name = "teslrt.EitherCombinator";
            sig_owner = ""; sig_needs_scope = false }) !either_fn_imports;
    List.iter (fun name ->
      (* A higher-order leaf has no runtime function at all — it lowers to a loop — so
         its entry exists only to mark the name as imported. *)
      let go_name = match list_leaf name with
        | Some leaf -> leaf.leaf_go
        | None -> "teslrt.EmittedAsALoop"
      in
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name
          { params = []; result = TFailure; go_name; sig_owner = ""; sig_needs_scope = false })
      (!list_imports @ !set_hof_imports);
    List.iter (fun name ->
      let params, result, go_name =
        match List.find_opt (fun (leaf, _, _, _) -> leaf = name) string_leaves with
        | Some (_, params, result, go_name) -> params, result, go_name
        | None -> assert false
      in
      let maybe_int () =
        match Hashtbl.find_opt types.adts "Maybe" with
        | Some info -> TAdt (info, [TInt])
        | None -> assert false
      in
      let maybe_of inner =
        match Hashtbl.find_opt types.adts "Maybe" with
        | Some info -> TAdt (info, [inner])
        | None -> assert false
      in
      let shape = function
        | `Str -> TString
        | `Int -> TInt
        | `Float -> TFloat
        | `MaybeFloat -> maybe_of TFloat
        | `CheckFloat -> TCheck TFloat
        | `Bool -> TBool
        | `MaybeInt -> maybe_int ()
        | `StrList -> TList TString
        | `CheckStr -> TCheck TString
        | `CheckInt -> TCheck TInt
      in
      if not (Hashtbl.mem signatures name) then
        Hashtbl.add signatures name { params = List.map shape params; result = shape result; go_name; sig_owner = ""; sig_needs_scope = false }) !string_imports;
    (* ── `Tesl.Money` / `Tesl.Units` leaves ─────────────────────────────────
       Registered here rather than with the shape-tagged string leaves because their types
       name RUNTIME RECORDS (a Money, a Currency, a rate) the table above cannot spell. *)
    if !money_imported || !units_imported then begin
      let record name = match Hashtbl.find_opt types.records name with
        | Some info -> TRecord info
        | None -> unsupported (Location.dummy_loc m.source_file)
          "Go backend needs `%s` for this module; import `Tesl.Money`" name
      in
      let rate_type alias = match Hashtbl.find_opt types.aliases alias with
        | Some ty -> ty
        | None -> unsupported (Location.dummy_loc m.source_file)
          "Go backend needs the rate type `%s`; import `Tesl.Money`" alias
      in
      let maybe_of ty = match Hashtbl.find_opt types.adts "Maybe" with
        | Some info -> TAdt (info, [ty])
        | None -> unsupported (Location.dummy_loc m.source_file)
          "Go backend `Currency.fromCode` answers a Maybe; import `Tesl.Maybe`"
      in
      let result_of ok err = match Hashtbl.find_opt types.adts "Result" with
        | Some info -> TAdt (info, [ok; err])
        | None -> unsupported (Location.dummy_loc m.source_file)
          "Go backend `Money.convert` answers a Result; import `Tesl.Result`"
      in
      let posix () = match Hashtbl.find_opt types.newtypes "PosixMillis" with
        | Some info -> TNewtype info
        | None -> unsupported (Location.dummy_loc m.source_file)
          "Go backend `ExchangeRate` carries a PosixMillis; import `Tesl.Time`"
      in
      let bind name params result go_name =
        if not (Hashtbl.mem signatures name) then
          Hashtbl.add signatures name
            { params; result; go_name; sig_owner = ""; sig_needs_scope = false }
      in
      let money () = record "Money" in
      let currency () = record "Currency" in
      let exchange () = record "ExchangeRate" in
      (* A rate CONSTRUCTOR answers the alias for its own denominator dimension. *)
      let rate_of_dim dim =
        match Units_catalog.money_rate_alias_of_dim dim with
        | Some alias -> rate_type alias
        | None -> unsupported (Location.dummy_loc m.source_file)
          "Go backend has no rate type for this denominator"
      in
      List.iter (fun name ->
        match name with
        | "Money.fromMinorUnits" -> bind name [currency (); TInt] (money ()) "teslrt.MoneyFromMinorUnits"
        | "Money.minorUnits" -> bind name [money ()] TInt "teslrt.MoneyMinorUnits"
        | "Money.currency" -> bind name [money ()] (currency ()) "teslrt.MoneyCurrency"
        | "Money.scale" -> bind name [money (); TInt] (money ()) "teslrt.MoneyScale"
        | "Money.scaleBy" -> bind name [money (); TFloat] (money ()) "teslrt.MoneyScaleBy"
        | "Money.negate" -> bind name [money ()] (money ()) "teslrt.MoneyNegate"
        | "Money.abs" -> bind name [money ()] (money ()) "teslrt.MoneyAbs"
        | "Money.isZero" -> bind name [money ()] TBool "teslrt.MoneyIsZero"
        | "Money.isNegative" -> bind name [money ()] TBool "teslrt.MoneyIsNegative"
        | "Money.display" -> bind name [money ()] TString "teslrt.MoneyDisplay"
        | "Money.add" -> bind name [money (); money ()] (money ()) "teslrt.MoneyAdd"
        | "Money.subtract" -> bind name [money (); money ()] (money ()) "teslrt.MoneySubtract"
        | "Money.compare" -> bind name [money (); money ()] TInt "teslrt.MoneyCompare"
        | "Money.requireSameCurrency" ->
          bind name [money (); money ()] (TCheck (money ())) "teslrt.MoneyRequireSameCurrency"
        | "Money.requireNonNegative" ->
          bind name [money ()] (TCheck (money ())) "teslrt.MoneyRequireNonNegative"
        | "Money.requireRateFor" ->
          bind name [exchange (); money ()] (TCheck (money ())) "teslrt.MoneyRequireRateFor"
        | "Money.convert" ->
          bind name [exchange (); money ()] (result_of (money ()) TString) "teslrt.MoneyConvert"
        | "Money.convertChecked" ->
          bind name [exchange (); money ()] (money ()) "teslrt.MoneyConvertChecked"
        | "Currency.code" -> bind name [currency ()] TString "teslrt.CurrencyCode"
        | "Currency.minorDigits" -> bind name [currency ()] TInt "teslrt.CurrencyMinorDigits"
        | "Currency.fromCode" -> bind name [TString] (maybe_of (currency ())) "teslrt.CurrencyFromCode"
        | "ExchangeRate.make" ->
          bind name [currency (); currency (); TFloat; posix ()] (exchange ()) "teslrt.ExchangeRateMake"
        | "ExchangeRate.fromCurrency" ->
          bind name [exchange ()] (currency ()) "teslrt.ExchangeRateFromCurrency"
        | "ExchangeRate.toCurrency" ->
          bind name [exchange ()] (currency ()) "teslrt.ExchangeRateToCurrency"
        | "ExchangeRate.rate" -> bind name [exchange ()] TFloat "teslrt.ExchangeRateRate"
        | "ExchangeRate.asOf" -> bind name [exchange ()] (posix ()) "teslrt.ExchangeRateAsOf"
        (* A fixed-denominator rate constructor bakes its label: the amount IS the price per
           that unit, and the label is what the rate displays and quantizes per. *)
        | "MoneyRate.perHour" ->
          bind name [money ()] (rate_of_dim Units_catalog.d_duration)
            "teslrt.MoneyRateOfLabel#3600#1#h"
        | "MoneyRate.perDay" ->
          bind name [money ()] (rate_of_dim Units_catalog.d_duration)
            "teslrt.MoneyRateOfLabel#86400#1#day"
        | "MoneyRate.perKilogram" ->
          bind name [money ()] (rate_of_dim Units_catalog.d_mass)
            "teslrt.MoneyRateOfLabel#1#1#kg"
        | "MoneyRate.perLiter" ->
          bind name [money ()] (rate_of_dim Units_catalog.d_volume)
            "teslrt.MoneyRateOfLabel#1#1000#L"
        | "MoneyRate.perSquareMeter" ->
          bind name [money ()] (rate_of_dim Units_catalog.d_area)
            "teslrt.MoneyRateOfLabel#1#1#m^2"
        (* `MoneyRate.currency` / `.display` are dimension-polymorphic: every rate is the same
           runtime value, so one binding serves them all. *)
        | "MoneyRate.currency" ->
          bind name [rate_of_dim Units_catalog.d_duration] (currency ()) "teslrt.MoneyRateCurrency"
        | "MoneyRate.display" ->
          bind name [rate_of_dim Units_catalog.d_duration] TString "teslrt.MoneyRateDisplay"
        | "Units.mul" -> bind name [TQuantity; TQuantity] TQuantity "teslrt.UnitsMul"
        | "Units.div" -> bind name [TQuantity; TQuantity] TQuantity "teslrt.UnitsDiv"
        | "Units.min" -> bind name [TQuantity; TQuantity] TQuantity "teslrt.UnitsMin"
        | "Units.max" -> bind name [TQuantity; TQuantity] TQuantity "teslrt.UnitsMax"
        | "Units.square" -> bind name [TQuantity] TQuantity "teslrt.UnitsSquare"
        | "Units.sqrt" -> bind name [TQuantity] TQuantity "teslrt.UnitsSqrt"
        | "Units.abs" -> bind name [TQuantity] TQuantity "teslrt.UnitsAbs"
        | "Units.negate" -> bind name [TQuantity] TQuantity "teslrt.UnitsNegate"
        | "Units.sum" -> bind name [TList TQuantity] TQuantity "teslrt.UnitsSum"
        | "Units.requireNonZero" ->
          bind name [TQuantity] (TCheck TQuantity) "teslrt.UnitsRequireNonZero"
        | "Duration.toMillis" -> bind name [TQuantity] TInt "teslrt.DurationToMillis"
        | "Duration.fromMillis" -> bind name [TInt] TQuantity "teslrt.DurationFromMillis"
        | unit_leaf ->
          (* Everything else is a unit CONSTRUCTOR or ACCESSOR: a Float in, a Float out, and
             the Go name is the dimension and the unit joined — the same derivation
             `scripts/gen-go-units.py` uses to write them. *)
          (match String.index_opt unit_leaf '.' with
           | Some index ->
             let dimension = String.sub unit_leaf 0 index in
             let unit = String.sub unit_leaf (index + 1)
               (String.length unit_leaf - index - 1) in
             (* A CONSTRUCTOR takes a plain number and answers a quantity; an ACCESSOR (the
                `in…` half) takes the quantity and answers the number. *)
             let is_accessor =
               String.length unit >= 3 && String.sub unit 0 2 = "in"
               && unit.[2] >= 'A' && unit.[2] <= 'Z'
             in
             let params, result =
               if is_accessor then [TQuantity], TFloat else [TFloat], TQuantity in
             bind unit_leaf params result
               (Printf.sprintf "teslrt.%s%s" dimension (go_ident ~exported:true unit))
           | None -> unsupported (Location.dummy_loc m.source_file)
             "Go backend cannot resolve the unit leaf `%s`" unit_leaf))
        !money_leaf_imports;
      (* The per-currency constructors: `Money.usd 1000` and the bare `Usd`.  The ISO code and
         the digit count are baked from the compiler's own currency table, so the runtime needs
         no lookup for a currency the source names. *)
      List.iter (fun (import : import_decl) ->
        if import.module_name = "Tesl.Money" then begin
          let exposed = match import.names with
            | ImportAll -> [] | ImportExposing names -> names in
          List.iter (fun name ->
            match money_ctor_currency name, currency_of_ctor name with
            | Some (iso, digits), _ when List.mem name Currencies.money_ctor_names ->
              bind name [TInt] (money ())
                (Printf.sprintf "teslrt.MoneyOf#%s#%d" iso digits)
            | _, Some (iso, digits) when List.mem name Currencies.ctor_names ->
              (* A bare `Usd` is a VALUE, not a nullary call: it goes in the const table, which
                 is what the emitter consults for a name mentioned without arguments. *)
              Hashtbl.replace types.consts name
                (currency (), Printf.sprintf "teslrt.CurrencyOf(%S, %d)" iso digits)
            | _ -> ()) exposed
        end) m.imports
    end;
    List.iter (fun name ->
      let maybe_string () =
        match Hashtbl.find_opt types.adts "Maybe" with
        | Some info -> TAdt (info, [TString])
        | None -> unsupported (Location.dummy_loc m.source_file)
          "Go backend `env` yields a Maybe; import `Tesl.Maybe`"
      in
      let params, result, go_name = match name with
        | "env" -> [TString], maybe_string (), "teslrt.EnvMaybe"
        | "envInt" -> [TString; TInt], TInt, "teslrt.EnvInt"
        | "envString" -> [TString; TString], TString, "teslrt.EnvString"
        | "requireEnv" -> [TString], TString, "teslrt.RequireEnv"
        (* `requireSecret` answers the stdlib's own SECRET newtype rather than a String: that is
           the whole point of it over `Secret (requireEnv …)` — the value redacts, compares in
           constant time, and can only reach a header through `HttpClient.bearer`. *)
        | "requireSecret" ->
          (match Hashtbl.find_opt types.newtypes "Secret" with
           | Some info -> [TString], TNewtype info, "teslrt.RequireSecret"
           | None -> unsupported (Location.dummy_loc m.source_file)
             "Go backend `requireSecret` needs the `Secret` type")
        | "randomInt" -> [TInt; TInt], TInt, "teslrt.RandomInt"
        (* Like `nowMillis`, a VALUE in Tesl's type table, written `randomFloat()`. *)
        | "randomFloat" -> [], TFloat, "teslrt.RandomFloat"
        | "generateId" -> [], TString, "teslrt.GenerateId"
        (* Both generators are VALUES in Tesl's type table, written `UUID.v4()`. *)
        (* The cache operations are typed per CALL SITE, from the cache the call names, so
           the entry only marks the name as available — the same placeholder a container leaf
           gets. *)
        | "Cache.get" | "Cache.set" | "Cache.delete" | "Cache.invalidate" ->
          [], TFailure, "teslrt.CacheOperation"
        | "UUID.v4" -> [], TString, "teslrt.UUIDv4"
        | "UUID.v7" -> [], TString, "teslrt.UUIDv7"
        | "UUID.validate" -> [TString], TCheck TString, "teslrt.UUIDValidate"
        | "generatePrefixedId" -> [TString], TString, "teslrt.GeneratePrefixedId"
        | other -> unsupported (Location.dummy_loc m.source_file)
          "Go backend does not support the effect leaf `%s` yet" other
      in
      Hashtbl.replace signatures name
        { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
      !effect_imports;
    (* `requeue job` resets a dead job to pending.  It answers whether the job was there to
       reset — a dead letter that no longer holds it is `False` rather than a trap, which is
       the answer `tesl/queue.rkt` gives for the same case. *)
    if !requeue_imported then
      (match Hashtbl.find_opt types.records "DeadJob" with
       | Some row ->
         Hashtbl.replace signatures "requeue"
           { params = [TRecord row]; result = TBool; go_name = "teslrt.Requeue";
             sig_owner = ""; sig_needs_scope = false }
       | None -> unsupported (Location.dummy_loc m.source_file)
         "Go backend `requeue` needs `DeadJob` from `Tesl.Queue`");

    (* `FixedOffset minutes` is the one zone constructor that takes an argument, so it is a
       signature where the others are constants. *)
    if !zone_type_needed then
      (match Hashtbl.find_opt types.records "TimeZone" with
       | Some zone ->
         Hashtbl.replace signatures "FixedOffset"
           { params = [TInt]; result = TRecord zone; go_name = "teslrt.FixedOffsetZone";
             sig_owner = ""; sig_needs_scope = false }
       | None -> ());
    List.iter (fun name ->
      let posix = match Hashtbl.find_opt types.newtypes "PosixMillis" with
        | Some info -> TNewtype info
        | None -> assert false
      in
      let params, result, go_name = match name with
        (* `nowMillis` is a VALUE in Tesl's type table, written `nowMillis()`; the
           empty-argument call normalises to a no-parameter call here. *)
        | "nowMillis" -> [], posix, "teslrt.NowMillis"
        | "durationMs" -> [posix], TInt, "teslrt.DurationMs"
        | "addMs" -> [posix; TInt], posix, "teslrt.AddMs"
        | "subtractMs" -> [posix; TInt], posix, "teslrt.SubtractMs"
        | "diffMs" -> [posix; posix], TInt, "teslrt.DiffMs"
        | "Time.posixToSeconds" -> [posix], TInt, "teslrt.PosixToSeconds"
        | "Time.secondsToPosix" -> [TInt], posix, "teslrt.SecondsToPosix"
        | "Time.add" -> [posix; TQuantity], posix, "teslrt.TimeAdd"
        | "Time.subtract" -> [posix; TQuantity], posix, "teslrt.TimeSubtract"
        | "Time.diff" -> [posix; posix], TQuantity, "teslrt.TimeDiff"
        (* `formatTime ts zone fmt` — the zone is a STRING here (the TimeZone value is the
           truncation family's), and the format is Tesl's own strftime-like vocabulary
           rather than Go's reference layout, because the two backends have to render the
           same instant identically. *)
        | "formatTime" -> [posix; TString; TString], TString, "teslrt.FormatTime"
        (* The bucket family and the offset.  Every one takes the ZONE first, which is the
           order the surface reads in: `Time.truncDay Utc e.startedAt`. *)
        | "Time.truncHour" | "Time.truncDay" | "Time.truncWeek" | "Time.truncMonth"
        | "Time.truncYear" | "Time.offsetAt" ->
          let zone = match Hashtbl.find_opt types.records "TimeZone" with
            | Some info -> TRecord info
            | None -> unsupported (Location.dummy_loc m.source_file)
              "Go backend `%s` takes a TimeZone; add `TimeZone` to the import" name
          in
          (match name with
           | "Time.offsetAt" -> [zone; posix], TInt, "teslrt.TimeOffsetAt"
           | _ ->
             let unit = String.sub name 10 (String.length name - 10) in
             [zone; posix], posix, "teslrt.TimeTrunc" ^ unit)
        | other -> unsupported (Location.dummy_loc m.source_file)
          "Go backend does not support `Tesl.Time` export `%s` yet" other
      in
      Hashtbl.replace signatures name
        { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
      !time_imports;
    (* ── `Tesl.Sso` ────────────────────────────────────────────────────────
       Every value here is OPAQUE, and that is the design rather than an omission: what makes
       an identity trustworthy is the path it came down — a connection built by
       `Sso.defaults`/`Sso.oidc`, a flow the RUNTIME drives, and an app that first sees the
       result at `onIdentity`, after the signature, the claims and the domain rules.  A
       program that could assemble an `SsoIdentity` could assert one. *)
    if !sso_imported then begin
      let loc = Location.dummy_loc m.source_file in
      let opaque name go_name =
        let info = {
          rec_tesl_name = name;
          rec_owner = "";
          rec_go_name = go_name;
          rec_proof_fields = false;
          rec_fields = [];
          rec_loc = loc;
        } in
        Hashtbl.replace types.records name info;
        TRecord info
      in
      let connection = opaque "SsoConnection" "teslrt.SsoConnection" in
      let identity = opaque "SsoIdentity" "teslrt.SsoIdentity" in
      let subject_key = opaque "SsoSubjectKey" "teslrt.SsoSubjectKeyValue" in
      (* A provider is one of a FIXED set, so each constructor is a VALUE — the string the
         runtime's defaults table is keyed by, written at the call site as `Github`. *)
      Hashtbl.replace types.aliases "SsoProvider" TString;
      Hashtbl.replace types.consts "Github" (TString, go_quote "GitHub");
      Hashtbl.replace types.consts "Google" (TString, go_quote "Google");
      let secret = match Hashtbl.find_opt types.newtypes "Secret" with
        | Some info -> TNewtype info
        | None -> unsupported loc "Go backend `Tesl.Sso` needs its `Secret` type"
      in
      (* The three accessors that answer a `Maybe` register only when the module is in
         scope.  A program that never imported it cannot have called them — the checker
         refuses the name — so this is the difference between registering nothing and
         refusing a program that is fine. *)
      let maybe_string = match Hashtbl.find_opt types.adts "Maybe" with
        | Some info -> Some (TAdt (info, [TString]))
        | None -> None
      in
      let maybe_leaves = match maybe_string with
        | None -> []
        | Some answer ->
          [ "Sso.email", [identity], answer, "teslrt.SsoEmail";
            "Sso.tenant", [identity], answer, "teslrt.SsoTenant";
            "Sso.claim", [identity; TString], answer, "teslrt.SsoClaim" ]
      in
      List.iter (fun (name, params, result, go_name) ->
        Hashtbl.replace signatures name
          { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
        (maybe_leaves @
        [ "Sso.defaults", [TString; TString; secret], connection, "teslrt.SsoDefaults";
          "Sso.oidc", [TString; TString; secret], connection, "teslrt.SsoOidc";
          "Sso.allowedEmailDomains", [connection; TList TString], connection,
            "teslrt.SsoAllowedEmailDomains";
          "Sso.allowedHostedDomains", [connection; TList TString], connection,
            "teslrt.SsoAllowedHostedDomains";
          "Sso.allowedTenants", [connection; TList TString], connection,
            "teslrt.SsoAllowedTenants";
          "Sso.logoutUrl", [connection; TString], TString, "teslrt.SsoLogoutURL";
          "Sso.keyText", [subject_key], TString, "teslrt.SsoKeyText";
          "Sso.subject", [identity], TString, "teslrt.SsoSubject" ])
    end;
    if !crypto_imports <> [] then begin
      let loc = Location.dummy_loc m.source_file in
      let secret = match Hashtbl.find_opt types.newtypes "Secret" with
        | Some info -> TNewtype info
        | None -> unsupported loc "Go backend `Tesl.Crypto` needs its `Secret` type"
      in
      let signature = match Hashtbl.find_opt types.newtypes "Signature" with
        | Some info -> TNewtype info
        | None -> unsupported loc "Go backend `Tesl.Crypto` needs its `Signature` type"
      in
      let password_hash = match Hashtbl.find_opt types.newtypes "PasswordHash" with
        | Some info -> TNewtype info
        | None -> unsupported loc "Go backend `Tesl.Crypto` needs its `PasswordHash` type"
      in
      let maybe_hash () = match Hashtbl.find_opt types.adts "Maybe" with
        | Some info -> TAdt (info, [password_hash])
        | None -> unsupported loc
          "Go backend `Crypto.checkPassword` takes a Maybe; import `Tesl.Maybe`"
      in
      List.iter (fun name ->
        let params, result, go_name = match name with
          (* Password storage.  `hashPassword` answers a VALUE (its Tesl type says so), and an
             over-long password is refused at the request boundary from inside the runtime. *)
          | "Crypto.hashPassword" -> [TString], password_hash, "teslrt.HashPassword"
          (* `checkPassword` takes a `Maybe` deliberately: a missing account and a wrong
             password must cost and answer the same, so `Nothing` still hashes. *)
          | "Crypto.checkPassword" ->
            [maybe_hash (); TString], TCheck (maybe_hash ()), "teslrt.CheckPassword"
          | "Crypto.needsRehash" -> [password_hash], TBool, "teslrt.NeedsRehash"
          (* `hmacSha256` is the expert alias for the same function. *)
          | "Crypto.signWith" | "Crypto.hmacSha256" ->
            [secret; TString], signature, "teslrt.SignWith"
          (* A verification is a CHECK: it answers the verified payload or fails 401, and the
             constant-time compare lives inside it — which is why there is no
             `constantTimeEquals` on the surface to get wrong. *)
          | "Crypto.checkSignature" ->
            [secret; signature; TString], TCheck TString, "teslrt.CheckSignature"
          | "Crypto.signatureHex" -> [signature], TString, "teslrt.SignatureHex"
          | "Crypto.signatureFromHex" -> [TString], signature, "teslrt.SignatureFromHex"
          | "Crypto.signatureBase64" -> [signature], TString, "teslrt.SignatureBase64"
          | "Crypto.signatureFromBase64" -> [TString], signature, "teslrt.SignatureFromBase64"
          (* `Tesl.Proxy`.  A CHECK for the same reason `checkSignature` is one: it answers
             the verified binding or a 401, and the constant-time compare is inside it. *)
          | "Proxy.verifyBinding" ->
            [secret; TString], TCheck TString, "teslrt.ProxyVerifyBinding"
          | "Crypto.fingerprint" -> [TString], TString, "teslrt.Fingerprint"
          | "Crypto.keyFingerprint" -> [secret], TString, "teslrt.KeyFingerprint"
          (* A VALUE in Tesl's type table, written `randomToken()`. *)
          | "Crypto.randomToken" -> [], TString, "teslrt.RandomToken"
          | "Crypto.sha256" -> [TString], TString, "teslrt.Sha256Hex"
          | "Crypto.sha512" -> [TString], TString, "teslrt.Sha512Hex"
          | other -> unsupported loc
            "Go backend does not support `Tesl.Crypto` export `%s` yet" other
        in
        Hashtbl.replace signatures name
          { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
        !crypto_imports
    end;
    (* The metric instruments.  Attributes are a `List (Tuple2 String String)` on the Tesl side
       already, so these are ordinary leaves; `initTelemetry` is not, because its surface is
       keyword arguments (`service V endpoint V console V`) rather than a positional call. *)
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Telemetry" then begin
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        let attributes = match Hashtbl.find_opt types.adts "Tuple2" with
          | Some info -> TList (TAdt (info, [TString; TString]))
          | None -> unsupported import.loc
            "Go backend telemetry attributes need `Tuple2`"
        in
        List.iter (fun name ->
          let params, result, go_name = match name with
            | "counter" -> [TString; TInt; attributes], TUnit, "teslrt.Counter"
            | "histogram" -> [TString; TFloat; attributes], TUnit, "teslrt.Histogram"
            | "gauge" -> [TString; TFloat; attributes], TUnit, "teslrt.Gauge"
            | _ -> [], TUnit, ""
          in
          if go_name <> "" then
            Hashtbl.replace signatures name
              { params; result; go_name; sig_owner = ""; sig_needs_scope = false }) exposed
      end) m.imports;
    if !jwt_imports <> [] then begin
      let loc = Location.dummy_loc m.source_file in
      let secret = match Hashtbl.find_opt types.newtypes "Secret" with
        | Some info -> TNewtype info
        | None -> unsupported loc "Go backend `Tesl.JWT` needs `Tesl.Crypto`'s `Secret` type"
      in
      let token = match Hashtbl.find_opt types.newtypes "JwtToken" with
        | Some info -> TNewtype info
        | None -> unsupported loc "Go backend `Tesl.JWT` needs its `JwtToken` type"
      in
      let claims = TDict (TString, TString) in
      List.iter (fun name ->
        let params, result, go_name = match name with
          | "JWT.sign" -> [claims; secret], token, "teslrt.JwtSign"
          (* Verification and renewal are CHECKS: each answers its value or a 401, and every
             rejection on those paths — malformed, wrong signature, expired, past the absolute
             cap — is a 401 rather than a trap, because the token arrives in a cookie. *)
          | "JWT.verify" -> [token; secret], TCheck claims, "teslrt.JwtVerify"
          | "JWT.renew" -> [token; secret], TCheck token, "teslrt.JwtRenew"
          (* `decode` reads WITHOUT verifying — for choosing which key to check a token with —
             so it mints no fact and its result must not be trusted. *)
          | "JWT.decode" -> [token], claims, "teslrt.JwtDecode"
          | other -> unsupported loc
            "Go backend does not support `Tesl.JWT` export `%s` yet" other
        in
        Hashtbl.replace signatures name
          { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
        !jwt_imports
    end;
    (* The outbound verbs.  A header list is `List (Tuple2 String String)`; the response is
       the record registered above.  `bearer`/`secretHeader` take a `Secret String`, which is
       a secret newtype — its Go type comes from the argument, so the parameter is typed as
       the newtype the call site has rather than being fixed here. *)
    if !httpclient_imports <> [] then begin
      let loc = Location.dummy_loc m.source_file in
      let response = match Hashtbl.find_opt types.records "HttpResponse" with
        | Some info -> TRecord info
        | None -> unsupported loc "Go backend `Tesl.HttpClient` needs its response type"
      in
      let header_pair = match Hashtbl.find_opt types.adts "Tuple2" with
        | Some info -> TAdt (info, [TString; TString])
        | None -> unsupported loc "Go backend needs `Tuple2` for HttpClient headers"
      in
      let headers = TList header_pair in
      List.iter (fun name ->
        let params, result, go_name = match name with
          | "HttpClient.get" -> [TString; headers], response, "teslrt.HttpGet"
          | "HttpClient.post" -> [TString; headers; TString], response, "teslrt.HttpPost"
          | "HttpClient.put" -> [TString; headers; TString], response, "teslrt.HttpPut"
          | "HttpClient.delete" -> [TString; headers], response, "teslrt.HttpDelete"
          (* The secret parameter is typed `TParam` so a call passes its own secret newtype
             through unchanged: the runtime takes a `teslrt.SecretString`, which is what every
             secret newtype's Go representation is. *)
          | "HttpClient.bearer" -> [TParam "Secret"], header_pair, "teslrt.HttpBearer"
          | "HttpClient.secretHeader" ->
            [TString; TParam "Secret"], header_pair, "teslrt.HttpSecretHeader"
          | other -> unsupported loc
            "Go backend does not support `Tesl.HttpClient` export `%s` yet" other
        in
        Hashtbl.replace signatures name
          { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
        !httpclient_imports
    end;
    (* ── `Tesl.Regex` ────────────────────────────────────────────────────────
       Six functions over String, each with the pattern first.  Pure: no capability, because
       nothing here reaches outside the process. *)
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Regex" then begin
        let loc = import.loc in
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        let maybe_of inner = match Hashtbl.find_opt types.adts "Maybe" with
          | Some info -> TAdt (info, [inner])
          | None -> unsupported loc
            "Go backend `Tesl.Regex` answers a Maybe; import `Tesl.Maybe`"
        in
        List.iter (fun name ->
          let params, result, go_name = match name with
            | "Regex.matches" -> [TString; TString], TBool, "teslrt.RegexMatches"
            | "Regex.find" -> [TString; TString], maybe_of TString, "teslrt.RegexFind"
            | "Regex.findAll" -> [TString; TString], TList TString, "teslrt.RegexFindAll"
            | "Regex.captures" ->
              [TString; TString], maybe_of (TList TString), "teslrt.RegexCaptures"
            | "Regex.replace" ->
              [TString; TString; TString], TString, "teslrt.RegexReplace"
            | "Regex.split" -> [TString; TString], TList TString, "teslrt.RegexSplit"
            | other -> unsupported loc
              "Go backend does not support `Tesl.Regex` export `%s` yet" other
          in
          Hashtbl.replace signatures name
            { params; result; go_name; sig_owner = ""; sig_needs_scope = false }) exposed
      end) m.imports;
    (* ── `Tesl.Url` and `Tesl.Net`: the leaves ───────────────────────────────
       Pure, both of them: a classification is arithmetic over an address and a parse is
       arithmetic over text.  Neither RESOLVES a name — that is the HTTP client's job, and
       keeping it out of here is what makes these callable from a `check`. *)
    List.iter (fun (import : import_decl) ->
      if import.module_name = "Tesl.Url" || import.module_name = "Tesl.Net" then begin
        let loc = import.loc in
        let exposed = match import.names with
          | ImportAll -> [] | ImportExposing names -> names in
        let maybe_of inner = match Hashtbl.find_opt types.adts "Maybe" with
          | Some info -> TAdt (info, [inner])
          | None -> unsupported loc
            "Go backend `%s` answers a Maybe; import `Tesl.Maybe`" import.module_name
        in
        let url () = match Hashtbl.find_opt types.records "Url" with
          | Some info -> TRecord info
          | None -> unsupported loc "Go backend `Tesl.Url` needs its `Url` type"
        in
        let host_class () = match Hashtbl.find_opt types.adts "HostClass" with
          | Some info -> TAdt (info, [])
          | None -> unsupported loc "Go backend `Tesl.Net` needs its `HostClass` type"
        in
        List.iter (fun name ->
          let params, result, go_name = match name with
            (* These name the TYPES, which were registered above.  `HostClass(..)` is the
               spelling that brings the constructors along, and the constructors are what a
               `case` over a classification matches on. *)
            | "Url" | "HostClass" | "HostClass(..)" -> [], TUnit, ""
            | "Url.parse" -> [TString], maybe_of (url ()), "teslrt.UrlParse"
            | "Url.scheme" -> [url ()], TString, "teslrt.UrlScheme"
            | "Url.host" -> [url ()], TString, "teslrt.UrlHost"
            | "Url.port" -> [url ()], maybe_of TInt, "teslrt.UrlPort"
            | "Url.effectivePort" -> [url ()], maybe_of TInt, "teslrt.UrlEffectivePort"
            | "Url.path" -> [url ()], TString, "teslrt.UrlPath"
            | "Url.query" -> [url ()], maybe_of TString, "teslrt.UrlQuery"
            | "Url.fragment" -> [url ()], maybe_of TString, "teslrt.UrlFragment"
            | "Url.userInfo" -> [url ()], maybe_of TString, "teslrt.UrlUserInfo"
            | "Url.toString" -> [url ()], TString, "teslrt.UrlToString"
            | "Net.classifyHost" -> [TString], host_class (), "teslrt.ClassifyHost"
            | "Net.normalizeHost" ->
              [TString], maybe_of TString, "teslrt.NormalizeHostMaybe"
            | "Net.isLoopback" -> [TString], TBool, "teslrt.NetIsLoopback"
            | "Net.isPrivate" -> [TString], TBool, "teslrt.NetIsPrivate"
            | "Net.isLinkLocal" -> [TString], TBool, "teslrt.NetIsLinkLocal"
            | "Net.isCgnat" -> [TString], TBool, "teslrt.NetIsCgnat"
            | "Net.isMulticast" -> [TString], TBool, "teslrt.NetIsMulticast"
            | "Net.isIpLiteral" -> [TString], TBool, "teslrt.NetIsIPLiteral"
            | "Net.isIpv4Mapped" -> [TString], TBool, "teslrt.NetIsIPv4Mapped"
            | "Net.isForbiddenHost" -> [TString], TBool, "teslrt.NetIsForbiddenHost"
            | other -> unsupported loc
              "Go backend does not support `%s` export `%s` yet" import.module_name other
          in
          if go_name <> "" then
            Hashtbl.replace signatures name
              { params; result; go_name; sig_owner = ""; sig_needs_scope = false }) exposed
      end) m.imports;
    (* ── `Tesl.Agent`: the inference and conversation leaves ─────────────────
       This match is the module's export list for this backend: a name that reaches its
       fallthrough is one the Go runtime does not offer yet, and the message says so with the
       name.  The type names and the capability are handled first and register nothing — the
       types were registered above, and `aiProvider` erases with every other capability. *)
    if !agent_imports <> [] then begin
      let loc = Location.dummy_loc m.source_file in
      let opaque name = match Hashtbl.find_opt types.records name with
        | Some info -> TRecord info
        | None -> unsupported loc "Go backend `Tesl.Agent` needs its `%s` type" name
      in
      let agent = opaque "Agent" in
      let provider = opaque "LlmProvider" in
      let reply = opaque "AgentReply" in
      let step = opaque "ToolStep" in
      let conversation = opaque "Conversation" in
      let turn = opaque "ConversationTurn" in
      List.iter (fun name ->
        match name with
        | "aiProvider"
        | "Agent" | "LlmProvider" | "AgentReply" | "AgentReply?" | "Tool" | "ToolStep"
        | "Conversation" | "Conversation?" | "ConversationTurn" | "ConversationTurn?" -> ()
        | _ ->
          let params, result, go_name = match name with
            (* The two test doubles.  A mock is deterministic and reaches no network, which is
               what lets an agent test run in the ordinary suite. *)
            | "mockProvider" -> [TList TString], provider, "teslrt.MockProvider"
            | "mockToolProvider" -> [TList step], provider, "teslrt.MockToolProvider"
            | "toolUseStep" -> [TString; TString; TString], step, "teslrt.ToolUseStep"
            | "textStep" -> [TString], step, "teslrt.TextStep"
            (* The real providers.  Each is a translation layer over the same normalised
               request; the outbound call goes through the ordinary HTTP client, so the
               network is gated and stubbable exactly like any other. *)
            | "anthropic" -> [TString; TString], provider, "teslrt.AnthropicProvider"
            | "openai" -> [TString; TString], provider, "teslrt.OpenAIProvider"
            | "mistral" -> [TString; TString], provider, "teslrt.MistralProvider"
            (* `local endpoint model`: the endpoint comes first, because it is the thing a
               self-hosted server is identified by. *)
            | "local" -> [TString; TString], provider, "teslrt.LocalProvider"
            (* Inference.  `ask` is `askReply` with everything but the text dropped; both run
               the same tool-calling loop, so a tool-augmented agent works through either. *)
            | "ask" -> [agent; TString], TString, "teslrt.Ask"
            | "askReply" -> [agent; TString], reply, "teslrt.AskReply"
            | "askWith" -> [agent; TString; provider], reply, "teslrt.AskWith"
            | "replyText" -> [reply], TString, "teslrt.ReplyText"
            | "replyTokens" -> [reply], TInt, "teslrt.ReplyTokens"
            | "replyToolCalls" -> [reply], TInt, "teslrt.ReplyToolCalls"
            (* Multi-turn conversation.  The transcript is threaded by the PROGRAM: `converse`
               answers the conversation advanced by this turn, and persisting it is a string
               round-trip through the program's own entity. *)
            | "newConversation" -> [agent], conversation, "teslrt.NewConversation"
            | "conversationFrom" -> [agent; TString], conversation, "teslrt.ConversationFrom"
            | "converse" -> [conversation; TString], turn, "teslrt.Converse"
            | "turnReply" -> [turn], reply, "teslrt.TurnReply"
            | "turnConversation" -> [turn], conversation, "teslrt.TurnConversation"
            | "conversationJson" -> [conversation], TString, "teslrt.ConversationJSON"
            | "conversationLength" -> [conversation], TInt, "teslrt.ConversationLength"
            (* Streaming takes a `String -> Unit` publisher, which a `params` row cannot
               describe — see the special-form arms in the expression emitter, which these
               placeholder rows are what identifies. *)
            | "converseStreaming" -> [], TFailure, "teslrt.ConverseStreaming"
            | "agentRun" -> [], TFailure, "teslrt.AgentRun"
            (* A tool's validator and dispatch, and `askFor`'s decoder, are FUNCTIONS; and
               `decodeAs` picks its decoder from a literal type name.  All four are typed
               from what the call site was given. *)
            | "tool" -> [], TFailure, "teslrt.ToolOf"
            | "asTool" -> [], TFailure, "teslrt.ToolOf#asTool"
            | "decodeAs" -> [], TFailure, "teslrt.DecodeAs"
            (* Both endpoint forms are decided per CALL SITE by the checker, so neither has
               a fixed result beyond `List Tool` and neither can be described here. *)
            | "serverTools" -> [], TFailure, "teslrt.ServerTools"
            | "humanActions" -> [], TFailure, "teslrt.HumanActions"
            | "askFor" -> [], TFailure, "teslrt.AskFor"
            | other -> unsupported loc
              "Go backend does not support `Tesl.Agent` export `%s` yet" other
          in
          Hashtbl.replace signatures name
            { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
        !agent_imports
    end;
    (* The outbound-HTTP double.  A stub DECLARATION is a statement whose Tesl type is Unit,
       so the runtime entry points answer `struct{}` like `enqueue` does. *)
    List.iter (fun name ->
      let params, result, go_name = match name with
        | "stubHttp" -> [TString; TString; TInt; TString], TUnit, "teslrt.StubHttp"
        | "stubHttpFailure" -> [TString; TString; TString], TUnit, "teslrt.StubHttpFailure"
        | "stubHttpTimeout" -> [TString; TString], TUnit, "teslrt.StubHttpTimeout"
        | "httpCalled" -> [TString; TString], TBool, "teslrt.HttpCalled"
        | "httpCallCount" -> [TString; TString], TInt, "teslrt.HttpCallCount"
        | "httpLastBody" -> [TString; TString], TString, "teslrt.HttpLastBody"
        | other -> unsupported (Location.dummy_loc m.source_file)
          "Go backend does not support the HTTP-stub leaf `%s` yet" other
      in
      Hashtbl.replace signatures name
        { params; result; go_name; sig_owner = ""; sig_needs_scope = false })
      !http_stub_imports;
    (* An imported local module contributes its exported functions with the OWNING
       package attached, so every reference to them is qualified. *)
    let imported_packages = ref [] in
    List.iter (fun (import : import_decl) ->
      match List.find_opt (fun dependency ->
              dependency_named dependency import.module_name) dependencies with
      | None -> ()
      | Some dependency ->
        (* `import M` with no `exposing` list is the QUALIFIED-ONLY form: references are
           written `M.Name`.  Every entry the dependency emitted from is brought in, keyed
           by its bare name, and the qualified reference resolves through the prefix strip
           in `type_of_type_expr` / `normalize_call_head`.  Bringing in more than the
           source names cannot widen what compiles: the checker has already rejected any
           use of a name this module did not import. *)
        let exposed = match import.names with
          | ImportAll ->
            List.of_seq (Hashtbl.to_seq_keys dependency.ex_signatures)
            @ List.of_seq (Hashtbl.to_seq_keys dependency.ex_types.records)
            @ List.of_seq (Hashtbl.to_seq_keys dependency.ex_types.newtypes)
            @ List.of_seq (Hashtbl.to_seq_keys dependency.ex_types.adts)
          | ImportExposing names -> names
        in
        if not (List.mem dependency.ex_package !imported_packages) then
          imported_packages := dependency.ex_package :: !imported_packages;
        register_imported_module ~loc:import.loc ~exposed types signatures dependency)
      m.imports;
    (* A `database` block may name an entity DECLARED in another module, and that entity's
       record only arrives with the import — so the flag is set again here, now that both are
       in hand.  The record is shared by reference, so marking it marks it for its own
       package too, which is what Racket's process-wide registry does. *)
    Hashtbl.iter (fun _ (database : database_info) ->
      List.iter (fun name ->
        match Hashtbl.find_opt types.entities name with
        | Some entity -> entity.ent_in_database <- true
        | None -> ()) database.db_entities) types.databases;
    List.iter (fun (fd : func_decl) ->
      if Hashtbl.mem signatures fd.name then unsupported fd.loc
        "Go backend generated name collision for `%s`" fd.name;
      (* A GENERIC function: the type variables its declaration mentions become Go type
         parameters, in order of first appearance.  Only a `fn` may be generic — a handler,
         a worker or a check is called by the runtime through a monomorphic signature. *)
      let type_params =
        type_variables_of
          ~subjects:(List.map (fun (binding : binding) -> binding.name) fd.params)
          (List.map (fun (binding : binding) -> binding.type_expr) fd.params
           @ return_spec_type_exprs fd.return_spec) in
      if type_params <> [] && fd.kind <> FnKind then
        unsupported fd.loc
          "Go backend supports a type variable only on a `fn`, and `%s` is not one" fd.name;
      if type_params <> [] then Hashtbl.replace current_type_params fd.name type_params;
      let params = List.map (fun (binding : binding) ->
        type_of_type_expr ~params:type_params types binding.type_expr) fd.params in
      (* `main` is exported whatever the module's `exposing` list says: the generated
         `package main` has to call it, and it is the program's entry point rather than part of a
         library surface. *)
      let exported = fd.kind = MainKind || is_exported fd.name in
      let go_name = unique_ident taken (go_ident ~exported fd.name) in
      (* `-> n: T ::: P` means different things by KIND: a `check`/`auth` answers a
         `Check T` (it can reject), while a plain `fn`/`worker` answers T carrying a proof —
         and the proof erases, so the result is just T.  Typing every attached return as a
         Check rejected an ordinary proof-passing `fn` as a "result type mismatch". *)
      (* `main() -> App` is the one signature whose declared type is CONFIGURATION rather than a
         value: the App record is lowered into the startup chain it describes, so what the
         emitted function answers is Unit.  Typing `App` as a value type would need a runtime
         representation for something that has none. *)
      let result = if fd.kind = MainKind then TUnit else
        match type_of_return_spec ~params:type_params types fd.return_spec, fd.kind with
        (* A `check`/`auth` can REJECT, so whatever its return spec says about the value, the
           result is a `Check` of it: `-> String ? Authenticated` on an `auth` is
           `Check[string]`, not `string`. *)
        | (TCheck _ as result), (CheckKind | AuthKind) -> result
        | result, (CheckKind | AuthKind) -> TCheck result
        | TCheck inner, (FnKind | WorkerKind | DeadWorkerKind | HandlerKind | MainKind) ->
          inner
        | result, _ -> result
      in
      Hashtbl.add signatures fd.name {
        params;
        result;
        go_name;
        sig_owner = package;
        (* The `requires` clause is the marker: a function that may write to the response
           takes the request scope, and the checker guarantees its callers declare the same
           capability — so the scope reaches it without any call-graph analysis. *)
        sig_needs_scope =
          implies_cookie_cap
            (List.filter_map (function DCapability c -> Some c | _ -> None) m.decls)
            fd.capabilities;
      }) funcs;
    (* Every package in a multi-module program lives under ONE Go module path, so an
       importer and its dependency agree on the import path. *)
    let module_path = match project_path with
      | Some path -> path
      | None -> "tesl.generated/" ^ package
    in
    current_package := package;
    current_types := Some types;
    let source =
      module_source ~imported_packages:!imported_packages ~codecs ~apis ~servers ~capturers
        ~consts:(List.filter_map (function DConst c -> Some c | _ -> None) m.decls)
        ~agents:(List.filter_map (function DAgent a -> Some a | _ -> None) m.decls)
        ~capabilities:(List.filter_map (function DCapability c -> Some c | _ -> None) m.decls)
        ~unreachable:(List.filter_map (fun name ->
          match Hashtbl.find_opt signatures name with
          | Some signature -> Some signature.go_name
          | None -> None) unreachable_private)
        module_path package signatures types funcs in
    let tests_source =
      if tests = [] && api_tests = [] && load_tests = [] then None
      else Some (test_source ~imported_packages:!imported_packages ~api_tests ~load_tests
                   module_path package signatures tests) in
    let needs_runtime = contains_go_code source "teslrt." ||
      match tests_source with Some text -> contains_go_code text "teslrt." | None -> false in
    (* The lint configuration is part of the emitter contract, versioned with this
       file: `exhaustive` is the static half of the ADT exhaustiveness mitigation and
       only sees a tag switch when a `default` arm does NOT count as covering. *)
    let lint_config =
      "# Generated by the Tesl Go backend. Every check here is part of the emitter\n\
       # contract: a finding on emitted code is an emitter bug, never a suppression.\n\
       version: \"2\"\n\
       linters:\n\
       \  enable:\n\
       \    - exhaustive\n\
       \  settings:\n\
       \    exhaustive:\n\
       \      default-signifies-exhaustive: false\n"
    in
    (* PASSWORD STORAGE is the one part of the runtime that is not standard-library-only:
       Argon2id comes from `golang.org/x/crypto/argon2`, because Racket hashes with libsodium's
       Argon2id and a stdlib substitute would mint hashes the other backend cannot verify — a
       shared database would become a silent lockout.  The dependency therefore travels with
       `password.go` and ONLY with it: a program that stores no passwords still emits a go.mod
       with no requirements at all.  The versions are pinned here and checked against
       `runtime/go/go.mod`/`go.sum` by a seam test, so a bump cannot drift. *)
    let password_runtime =
      let mentions name =
        contains_go_code source name
        || (match tests_source with
            | Some text -> contains_go_code text name
            | None -> false)
      in
      List.exists mentions
        [ "teslrt.HashPassword"; "teslrt.CheckPassword"; "teslrt.NeedsRehash";
          "teslrt.PasswordHash" ]
    in
    (* The PostgreSQL driver, on the same terms as the password dependency: Go has no Postgres
       driver in its standard library, so a program that declares a Postgres-backed database
       takes `github.com/jackc/pgx/v5` and a program that does not takes nothing.  Pinned here
       and checked against `runtime/go/go.mod`/`go.sum` by a seam test, so a bump cannot
       drift. *)
    let postgres_runtime =
      let mentions name =
        contains_go_code source name
        || (match tests_source with
            | Some text -> contains_go_code text name
            | None -> false)
      in
      List.exists mentions [ "teslrt.NewDatabase"; "teslrt.WithDatabase"; "teslrt.PgPlan" ]
    in
    let dependency_requires =
      (if password_runtime then
         "\nrequire golang.org/x/crypto v0.55.0\n\nrequire golang.org/x/sys v0.47.0 // indirect\n"
       else "")
      ^ (if postgres_runtime then postgres_dependency_go_mod else "")
    in
    let artifacts = [
      (* The go directive tracks the toolchain the gates pin (maintainer: use the latest
         stable Go).  It also sets the language version the emitted code may use, so it has
         to be at least as new as anything the runtime relies on. *)
      { path = "go.mod";
        contents = Printf.sprintf "module %s\n\ngo 1.26\n%s" module_path dependency_requires };
      { path = ".golangci.yml"; contents = lint_config };
      { path = "internal/" ^ package ^ "/module.go"; contents = source };
    ]
    (* A module with a `main` is a PROGRAM: it gets the one `package main` Go needs to build a
       binary.  Emitted as a separate artifact rather than by making the module itself `package
       main`, so a module can be both a library another package imports and the entry point —
       which is how the corpus is written (a `main` beside the handlers it serves). *)
    @ (if List.exists (fun (fd : func_decl) -> fd.kind = MainKind) funcs then
         [ { path = "cmd/app/main.go";
             contents = Printf.sprintf
               "package main\n\nimport (\n\t%s\n)\n\n// The entry point Tesl's `main` describes: its `App { … }` record was lowered into the\n// startup chain (activate each queue's workers, then serve), so this is the whole program.\nfunc main() {\n\t_ = %s.Main()\n}\n"
               (go_quote (module_path ^ "/internal/" ^ package)) package } ]
       else [])
    @ (if password_runtime || postgres_runtime then
           [ { path = "go.sum";
               contents = (if password_runtime then password_dependency_go_sum else "")
                          ^ (if postgres_runtime then postgres_dependency_go_sum else "") } ]
         else []) in
    let artifacts = match tests_source with
      | None -> artifacts
      | Some contents -> artifacts @ [{ path = "internal/" ^ package ^ "/module_test.go"; contents }]
    in
    let artifacts =
      if not needs_runtime then artifacts
      else begin
        (* The HTTP half of the runtime ships ONLY to a module that serves HTTP.  Emitting
           it everywhere pulled `net/http` — and its whole dependency chain — into every
           program, including pure-computation ones: govulncheck then reported a real
           stdlib vulnerability (GO-2026-5972, reachable as
           `teslrt.init -> http.init -> asn1.Unmarshal`) against a module that never opens
           a socket.  A dependency a program does not use should not be in it, for
           vulnerability surface as much as for the eject story. *)
        (* Declaring a `server` is the common way to need the HTTP half, but not the only one:
           an `auth` function takes a `teslrt.HttpRequest`, and a module can declare one while
           the `server` that routes to it lives elsewhere.  So the test is what the emitted code
           REFERENCES, not what it declares — otherwise the package compiles against a runtime
           file that was not shipped (`undefined: teslrt.HttpRequest`), which is the fail-open
           version of the same size argument. *)
        let mentions name =
          contains_go_code source name
          || (match tests_source with
              | Some text -> contains_go_code text name
              | None -> false)
        in
        let serves_http = servers <> []
          || List.exists mentions
               [ "teslrt.HttpRequest"; "teslrt.ApiResponse"; "teslrt.ApiRequest";
                 "teslrt.JsonValue"; "teslrt.RequestScope"; "teslrt.Server" ] in
        (* `apitest_json.go` travels with `apitest.go`: the untyped JSON view exists to inspect
           a RESPONSE, so a module that serves no HTTP has no use for it. *)
        let http_only =
          [ "serve.go"; "server.go"; "request.go"; "apitest.go"; "apitest_json.go";
            (* The SSE ROUTE and the api-test subscription need the server and the JSON view;
               the channel itself (sse.go) does not, so a module that only publishes ships
               no HTTP runtime. *)
            "sse_http.go";
            (* The SSO routes are part of the SERVER: `sso_route.go` names `Server` and
               `handleSsoRequest` is called from its dispatch, so it cannot ship without the
               HTTP half — and there is nothing for it to do in a program with no server. *)
            "sso.go"; "sso_flow.go"; "sso_route.go"; "jws.go" ] in
        (* `loadtest.go` imports `testing`, so it ships ONLY with a module that has load tests:
           the testing package has no place in a production binary. *)
        let load_test_only = [ "loadtest.go" ] in
        (* The PostgreSQL half ships ONLY to a program that declares a Postgres-backed
           database, for the reason the HTTP half does: it pulls a third-party driver and its
           whole dependency chain into a binary that would otherwise require nothing. *)
        let postgres_only = [ "postgres.go"; "database.go"; "dbquery.go" ] in
        (* `agent.go` ships only to a program that talks to a model.  It is not a dependency
           argument — everything in it is standard library — but a runtime file a program has
           no use for is still surface a reader has to rule out, and the gate costs nothing. *)
        let agent_only = [ "agent.go"; "agent_endpoint.go"; "agent_provider.go" ] in
        (* `timezone.go` embeds the IANA database (~450 KB) so a container with no
           /usr/share/zoneinfo still renders `Europe/Stockholm` correctly rather than
           silently falling back to UTC.  A program that formats no timestamps should not
           carry it. *)
        let regex_only = [ "regex.go" ] in
        let uses_regex = mentions "teslrt.Regex" in
        (* `Tesl.Url` and `Tesl.Net` travel TOGETHER: a URL's host is canonicalised by the
           classifier, so shipping the parser without it does not build.  They are gated only
           because a program that parses no URLs has no use for either. *)
        let url_net_only = [ "hostname.go"; "url.go" ] in
        let uses_url_net = List.exists mentions
          [ "teslrt.Url"; "teslrt.ClassifyHost"; "teslrt.NormalizeHost"; "teslrt.NetIs" ] in
        (* `timezone.go` and `timetrunc.go` travel TOGETHER: the truncation engine resolves a
           named zone through the same embedded database formatting uses, and a bucket that
           silently fell back to UTC would be the exact bug the embedding prevents. *)
        let timezone_only = [ "timezone.go"; "timetrunc.go" ] in
        let uses_timezone = List.exists mentions
          [ "teslrt.FormatTime"; "teslrt.TimeTrunc"; "teslrt.TimeOffsetAt";
            "teslrt.TimeZone"; "teslrt.UtcZone"; "teslrt.NamedZone";
            "teslrt.FixedOffsetZone" ] in
        let uses_agent = List.exists mentions
          [ "teslrt.Agent"; "teslrt.LlmProvider"; "teslrt.LlmResponse"; "teslrt.Tool";
            "teslrt.Conversation"; "teslrt.Ask"; "teslrt.MockProvider" ] in
        let has_load_tests = match tests_source with
          | Some text -> contains_go_code text "teslrt.RunLoadTest"
          | None -> false
        in
        artifacts @ List.filter_map (fun (name, contents) ->
          if (not serves_http) && List.mem name http_only then None
          else if (not has_load_tests) && List.mem name load_test_only then None
          else if (not postgres_runtime) && List.mem name postgres_only then None
          else if (not uses_agent) && List.mem name agent_only then None
          else if (not uses_timezone) && List.mem name timezone_only then None
          else if (not uses_regex) && List.mem name regex_only then None
          else if (not uses_url_net) && List.mem name url_net_only then None
          else if name = "password.go" && not password_runtime then None
          else Some { path = "internal/teslrt/" ^ name; contents })
          Embedded_go_runtime.files
      end
    in
    Ok (artifacts, { ex_module = m.module_name; ex_package = package;
                     ex_types = types; ex_signatures = signatures })
  with Unsupported error -> Error [error]

(* Emits a whole program: one Go package per Tesl module, all under the entry module's
   Go module path.  `modules` must contain the entry and every local module it imports,
   transitively; the caller resolves that graph (compile.ml owns file resolution).
   Shared artifacts — go.mod, the lint config, the runtime — are emitted once.

   Modules are compiled DEPENDENCY-FIRST so an importer receives the very tables its
   dependency emitted from.  That is what makes a type crossing the boundary the same
   type on both sides: `go_type` equality is structural, so a re-derived record would
   compare unequal to the original even when it describes the same Tesl declaration. *)
let compile_project ?(mode=Release) ~(entry : module_form) (modules : module_form list) =
  let project_path = "tesl.generated/" ^ package_name entry.module_name in
  let local_names = List.map (fun (m : module_form) -> m.module_name) modules in
  (* The name a local module answers to, which is not always the name the import writes:
     a LIFTED stdlib module is imported as `Tesl.CivilTime` and declares itself `CivilTime`. *)
  let local_named import_name =
    List.find_opt (fun name ->
      name = import_name
      || (String.length import_name > 5 && String.sub import_name 0 5 = "Tesl."
          && name = String.sub import_name 5 (String.length import_name - 5)
          && not (String.contains name '.')))
      local_names
  in
  let dependencies_of (m : module_form) =
    List.filter_map (fun (import : import_decl) -> local_named import.module_name) m.imports
  in
  (* Topological order.  A cycle cannot appear here — compile.ml rejects one before this
     point — but the counter keeps a malformed graph from looping forever rather than
     failing. *)
  let rec order done_names remaining passes =
    if remaining = [] then Ok (List.rev done_names)
    else if passes = 0 then
      Error [{ loc = Location.dummy_loc entry.source_file;
               message = "Go backend could not order the module graph" }]
    else
      let ready, blocked = List.partition (fun (m : module_form) ->
        List.for_all (fun name -> List.mem name done_names) (dependencies_of m)) remaining in
      if ready = [] then
        Error [{ loc = Location.dummy_loc entry.source_file;
                 message = "Go backend could not order the module graph" }]
      else
        order (List.rev_append (List.map (fun (m : module_form) -> m.module_name) ready)
                 done_names) blocked (passes - 1)
  in
  match order [] modules (List.length modules + 1) with
  | Error errors -> Error errors
  | Ok ordered_names ->
    let ordered = List.filter_map (fun name ->
      List.find_opt (fun (m : module_form) -> m.module_name = name) modules) ordered_names in
    let rec emit acc exports = function
      | [] -> Ok (List.rev acc)
      | (m : module_form) :: rest ->
        (match compile_module ~mode ~dependencies:exports ~project_path m with
         | Error errors -> Error errors
         | Ok (artifacts, module_exports) ->
           emit (List.rev_append artifacts acc) (module_exports :: exports) rest)
    in
    (match emit [] [] ordered with
     | Error errors -> Error errors
     | Ok artifacts ->
       (* On a duplicate path the FIRST wins, and dependencies are emitted first, so the
          shared artifacts (the lint config, the runtime files) come from whichever module
          needed them earliest — those are byte-identical either way. *)
       let seen = Hashtbl.create 16 in
       let deduped = List.filter (fun (artifact : artifact) ->
         if Hashtbl.mem seen artifact.path then false
         else begin Hashtbl.add seen artifact.path (); true end) artifacts in
       (* `go.mod` and `go.sum` are NOT byte-identical across modules: each names the
          dependencies ITS module needs, and taking the first one shipped a manifest missing
          whatever a LATER module required — a project whose database is declared in one module
          and whose entry point is another got the pgx runtime files with a go.mod requiring
          nothing, which does not build.  They are rebuilt here from the union of what the
          emitted tree actually references. *)
       let references marker =
         List.exists (fun (artifact : artifact) ->
           let is_go = Filename.check_suffix artifact.path ".go" in
           is_go && contains_go_code artifact.contents marker) deduped
       in
       let needs_password =
         List.exists references
           [ "teslrt.HashPassword"; "teslrt.CheckPassword"; "teslrt.NeedsRehash";
             "teslrt.PasswordHash" ] in
       let needs_postgres =
         List.exists references [ "teslrt.NewDatabase"; "teslrt.WithDatabase"; "teslrt.PgSql" ] in
       let requires =
         (if needs_password then
            "\nrequire golang.org/x/crypto v0.55.0\n\nrequire golang.org/x/sys v0.47.0 // indirect\n"
          else "")
         ^ (if needs_postgres then postgres_dependency_go_mod else "") in
       let checksums =
         (if needs_password then password_dependency_go_sum else "")
         ^ (if needs_postgres then postgres_dependency_go_sum else "") in
       let rebuilt = List.filter_map (fun (artifact : artifact) ->
         if artifact.path = "go.mod" then
           Some { artifact with
                  contents = Printf.sprintf "module %s\n\ngo 1.26\n%s" project_path requires }
         else if artifact.path = "go.sum" then
           (if checksums = "" then None else Some { artifact with contents = checksums })
         else Some artifact) deduped in
       (* A go.sum is needed even when no module emitted one, which happens when the module
          that requires a dependency is not the one that emitted the manifest. *)
       let rebuilt =
         if checksums = "" || List.exists (fun (a : artifact) -> a.path = "go.sum") rebuilt
         then rebuilt
         else rebuilt @ [{ path = "go.sum"; contents = checksums }] in
       Ok rebuilt)
