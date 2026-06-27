(** Typed AST for the Tesl surface language.

    Each node carries a [Location.loc] so the type checker and emitter can
    report errors with exact source positions.  No "kind" strings, no untyped
    dicts — every variant is explicit and exhaustive pattern matching is
    enforced by the OCaml compiler. *)

open Location

(* ─── Basic building blocks ─────────────────────────────────────────────── *)

(** A simple identifier (lowercase). *)
type ident = { name : string; loc : loc }

(** An uppercase identifier — constructor or type name. *)
type uident = { name : string; loc : loc }

(** A qualified name like [Tesl.Dict.lookup] or just [lookup]. *)
type qname =
  | QSimple of ident          (** unqualified *)
  | QDot    of uident * ident (** Module.name *)

(* ─── Type expressions ───────────────────────────────────────────────────── *)

type type_expr =
  | TName   of uident                        (** Int, String, Bool, UserId … *)
  | TVar    of ident                         (** type variable: a, b … *)
  | TApp    of { head : type_expr; arg : type_expr; loc : loc } (** List Int, Maybe T *)
  | TFun    of { dom : type_expr; cod : type_expr; loc : loc }  (** a -> b *)
  | TTuple  of { elems : type_expr list; loc : loc }

(* ─── Proof expressions ──────────────────────────────────────────────────── *)

(** A proof predicate or conjunction: [ValidPort port], [P x && Q x]. *)
type proof_expr =
  | PredApp  of { pred : string; args : string list; loc : loc }
                (** ProofPredicate applied to names, e.g. ValidPort port *)
  | PredAnd  of { left : proof_expr; right : proof_expr; loc : loc }
                (** P x && Q x *)

(* ─── Binding & return specs ─────────────────────────────────────────────── *)

(** A parameter binding: [name : Type] or [name : Type ::: Proof]. *)
type binding = {
  name       : string;
  type_expr  : type_expr;
  proof_ann  : proof_expr option;   (** ::: Proof *)
  loc        : loc;
}

(** A record/entity field with optional @db override. *)
type field_def = {
  name      : string;
  type_expr : type_expr;
  proof_ann : proof_expr option;
  checker   : string option;   (** via checker name (for codec fields) *)
  db_type   : string option;   (** @db(type) override *)
  loc       : loc;
}

(** The return specification of a function — several distinct shapes. *)
type return_spec =
  | RetPlain      of { ty : type_expr; loc : loc }
                     (** -> T *)
  | RetAttached   of { binding : binding; loc : loc }
                     (** -> name: T ::: Proof name *)
  | RetNamedPack  of { ty : type_expr; entity_proof : proof_expr option; other_proof : proof_expr option; loc : loc }
                     (** -> T ? ProofName *)
  | RetForAll     of { elem_ty : type_expr; proof : proof_expr; loc : loc }
                     (** -> List T ::: ForAll Proof *)
  | RetMaybeForAll of { elem_ty : type_expr; proof : proof_expr; loc : loc }
                     (** -> Maybe (List T ::: ForAll Proof) *)
  | RetMaybeAttached of { outer_ty : type_expr option; binding : binding; loc : loc }
                     (** -> Maybe (name: T ::: Proof name) or Wrapper (T ? P) *)
  | RetSetForAll  of { elem_ty : type_expr; proof : proof_expr; loc : loc }
  | RetMaybeSetForAll of { elem_ty : type_expr; proof : proof_expr; loc : loc }
  | RetForAllDictValues of { key_ty : type_expr; val_ty : type_expr; proof : proof_expr; loc : loc }
                         (** -> Dict K V ::: ForAllValues Proof *)
  | RetForAllDictKeys   of { key_ty : type_expr; val_ty : type_expr; proof : proof_expr; loc : loc }
                         (** -> Dict K V ::: ForAllKeys Proof *)
  | RetExists     of { binding : binding; body : return_spec; loc : loc }
                     (** -> exists name: T => Body *)

(* ─── Expressions ────────────────────────────────────────────────────────── *)

type lit =
  | LInt    of int
  | LFloat  of float
  | LBool   of bool
  | LString of string                       (** plain string, no interpolation *)
  | LInterp of interp_segment list          (** "hello ${*x}!" *)

and interp_segment =
  | ILiteral of string
  | IExpr    of expr

and expr =
  | ELit    of { lit : lit; loc : loc }
  | EVar    of { name : string; loc : loc } (** plain identifier *)
  | EField  of { obj : expr; field : string; loc : loc }  (** expr.field *)
  | EApp    of { fn : expr; arg : expr; loc : loc }
               (** left-assoc function application *)
  | EBinop  of { op : binop; left : expr; right : expr; loc : loc }
  | EUnop   of { op : unop; arg : expr; loc : loc }
  | EIf     of { cond : expr; then_ : expr; else_ : expr; loc : loc }
  | ECase   of { scrut : expr; arms : case_arm list; loc : loc }
  | ELet    of { name : string; declared_type : type_expr option; declared_proof : proof_expr option; value : expr; body : expr; loc : loc }
  | ELetProof of { value_name : string; proof_name : string; proof_index : (int * int) option; value : expr; body : expr; loc : loc }
               (** let (value_name ::: proof_name) = value — proof decompose *)
  | ERecord of { fields : (string * expr) list; type_hint : string option; loc : loc }
               (** record literal { k: v, ... } — type_hint from let x: Type = { } *)
  | EList   of { elems : expr list; loc : loc }
  | EOk     of { value : expr; proof : proof_expr; loc : loc }
               (** ok expr ::: Proof *)
  | EFail   of { status : int; message : expr; loc : loc }
               (** fail 400 "..." or fail 400 "... ${expr} ..." *)
  | ETelemetry of { name : string; fields : (string * expr) list; loc : loc }
  | EEnqueue of { job_type : string; payload : expr; loc : loc }
  | EPublish of { channel_name : string; key : expr option; event_ctor : string; payload : expr option; loc : loc }
  | EStartWorkers of { workers_name : string; capabilities : string list; concurrency : int option; is_dead : bool; loc : loc }
  | ECacheGet    of { cache_name : string; key : expr; loc : loc }
  | ECacheSet    of { cache_name : string; key : expr; value : expr; ttl : expr option; loc : loc }
  | ECacheDelete of { cache_name : string; key : expr; loc : loc }
  | ECacheInvalidate of { cache_name : string; prefix : expr; loc : loc }
  | ESendEmail   of { email_name : string; to_ : expr; subject : expr; body : expr; loc : loc }
  | EStartEmailWorker of { email_name : string; loc : loc }
  | EWithDatabase of { database_name : string; body : expr; loc : loc }
  | EWithCapabilities of { capabilities : string list; body : expr; loc : loc }
  | EWithTransaction of { body : expr; loc : loc }
  | EServe of { server_name : string; port : expr; capabilities : string list; static_dir : string option; loc : loc }
  | EConstructor of { name : string; args : expr list; loc : loc }
               (** Constructor applied to zero or more args *)
  | ELambda of { params : binding list; body : expr; loc : loc }
               (** Anonymous function: fn(x: T, y: T) -> body *)
  | ERuntimeCall of { segments : rcall_seg list; loc : loc }
               (** Desugar-only lowering target (reduce_language_size, Wave 2).
                   A pre-rendered Racket runtime call: an alternation of verbatim
                   token strings ([RLit]) and argument sub-expressions ([RArg],
                   emitted through the context-aware {!Emit_racket.emit_expr_simple}
                   path).  Produced ONLY by {!Desugar} from fixed-shape effect
                   forms (EEnqueue / EStartWorkers / EServe) whose templates are
                   fully determined at desugar time; the emitter walks [segments]
                   verbatim.  This is never produced by the parser, so all
                   surface-form enforcement/diagnostics (which run BEFORE desugar)
                   still see the original variant. *)

and rcall_seg =
  | RLit of string   (** verbatim Racket tokens emitted as-is *)
  | RArg of expr     (** argument sub-expression, emitted via emit_expr_simple *)

and binop =
  | BAdd | BSub | BMul | BDiv | BMod
  | BConcat (* ++ — string concatenation *)
  | BAnd (* && *)
  | BOr  (* || — logical disjunction (booleans only, not proofs) *)
  | BEq | BNeq | BLt | BLe | BGt | BGe

and unop =
  | UNeg  (* unary minus *)
  | UNot  (* ! *)

and case_arm = {
  pattern : pattern;
  guard   : expr option;   (** optional `where expr` guard condition *)
  body    : expr;
  loc     : loc;
}

and pattern =
  | PVar       of string                          (** variable binding *)
  | PWild                                         (** _ *)
  | PCon       of { ctor : string; fields : (string * pattern) list; loc : loc }
                  (** Constructor field1 field2 — positional or labeled sub-patterns *)
  | PNullary   of { ctor : string; loc : loc }    (** Constructor with no fields *)
  | PLit       of { value : lit; loc : loc }      (** string / int literal pattern *)

(* ─── Top-level forms ────────────────────────────────────────────────────── *)

(** A function kind: plain, check, auth, establish, handler, worker, etc. *)
type func_kind =
  | FnKind
  | CheckKind
  | AuthKind
  | EstablishKind
  | HandlerKind
  | WorkerKind
  | DeadWorkerKind
  | MainKind

(** Desugaring provenance: where a synthesised AST node was lowered FROM.

    Platinum groundwork for the upcoming desugar pass (Wave 2). When a later
    pass replaces a piece of surface syntax with a more primitive form, it must
    record the ORIGINAL source location here so that go-to-definition, hover and
    diagnostics keep pointing at what the user actually wrote, never at the
    machine-generated lowering. It is [None] for every node parsed directly from
    source (the only producer today is the parser, which always sets [None]), so
    adding it changes no current behaviour. *)
type provenance = {
  desugared_from : loc;   (** the surface loc this node was lowered from *)
}

type func_decl = {
  kind        : func_kind;
  name        : string;
  params      : binding list;
  return_spec : return_spec;
  capabilities : string list;
  body        : expr;
  loc         : loc;
  desugared_from : provenance option;
                (** [None] when parsed from source; [Some p] when synthesised by
                    a desugaring pass, recording the original surface location. *)
}

type adt_variant = {
  ctor    : string;
  fields  : field_def list;
  loc     : loc;
}

type type_form =
  | TypeNewtype of { name : string; base_type : type_expr; loc : loc }
                   (** type UserId = String *)
  | TypeAlias   of { name : string; base_type : type_expr; loc : loc }
                   (** transparent alias — currently same as newtype at surface *)
  | TypeAdt     of { name : string; params : string list; variants : adt_variant list; loc : loc }
                   (** type Status = Open | Closed | Pending reason:String *)

type record_invariant = {
  proof_text   : proof_expr;
  checker_name : string option;
  loc          : loc;
}

type record_form = {
  name      : string;
  fields    : field_def list;
  invariant : record_invariant option;
  loc       : loc;
}

type entity_form = {
  name        : string;
  table       : string;
  primary_key : string;
  fields      : field_def list;
  loc         : loc;
}

type capability_form = {
  name    : string;
  implies : string list;
  loc     : loc;
}

(** Explicit proof-predicate declaration: [fact ValidPort (port: Int)].
    Introduces the predicate name into the module's type namespace so it can
    be imported by other modules and used in [Fact (ValidPort x)] type positions. *)
type fact_form = {
  name   : string;
  params : binding list;
  loc    : loc;
}

type const_form = {
  name  : string;
  value : expr;
  loc   : loc;
}

(* ─── Codec forms ────────────────────────────────────────────────────────── *)

type codec_to_json =
  | ToJsonForbidden
  | ToJsonFields of codec_encode_entry list
  | ToJsonAdt  (** adtJson: encode constructor name as a JSON string *)

and codec_encode_entry = {
  field_name : string;
  json_key   : string;
  codec      : string;
  loc        : loc;
}

type codec_from_json =
  | FromJsonForbidden
  | FromJsonAlts of codec_decode_alt list  (** multiple decode alternatives *)
  | FromJsonAdt  (** adtJson: decode a JSON string back to a constructor *)

and codec_decode_alt = codec_decode_entry list

and codec_decode_entry =
  | DecodeField  of { field_name : string; json_key : string; codec : string; via : string list; loc : loc }
  | DecodeDefault of { field_name : string; default_expr : string; loc : loc }
  | DecodeCrossCheck of { checker : string; loc : loc }

type codec_form = {
  name       : string;
  type_name  : string;   (** the type being given a codec *)
  to_json    : codec_to_json;
  from_json  : codec_from_json;
  loc        : loc;
}

(* ─── Config-block field metadata ───────────────────────────────────────── *)

(** One [key[: value]] line as actually written in a configuration block
    (database / queue / channel / cache / email and their nested sub-blocks),
    captured generically by the parser in source order — INCLUDING keys that are
    not recognised fields.  This is the raw surface record the config-schema
    validation pass ({!Validation_config}) and the LSP [--config-context-json]
    query read; the typed fields on each [*_form] record carry the decoded
    values for the emitter.  [cf_block] is the nested block's own fields (e.g.
    the [postgres {...}] / [retry {...}] / [smtp {...}] sub-block), empty for a
    scalar field. *)
type config_field = {
  cf_key     : string;
  cf_key_loc : loc;
  cf_colon   : bool;              (** whether a [:] immediately followed the key *)
  cf_block   : config_field list; (** nested sub-block fields, [] when scalar *)
}

(* ─── Database form ──────────────────────────────────────────────────────── *)

type database_form = {
  name       : string;
  backend    : string;                   (** e.g. "postgres" | "memory" ("" = default postgres) *)
  schema     : string;
  entities   : string list;
  postgres   : (string * string) list;  (** key-value connection params *)
  raw_fields : config_field list;        (** surface fields for schema validation *)
  config_expr : expr option;             (** new typed-record syntax: `= Database { … }` (desugar fills the fields above) *)
  loc        : loc;
}

(* ─── Queue / channel / workers ─────────────────────────────────────────── *)

type queue_form = {
  name          : string;
  database      : string;
  jobs          : string list;
  max_attempts  : int option;
  backoff       : string option;
  initial_delay : int option;
  raw_fields    : config_field list;
  loc           : loc;
}

type channel_form = {
  name       : string;
  key_params : binding list;
  database   : string;
  payload    : type_expr;
  raw_fields : config_field list;
  loc        : loc;
}

type cache_form = {
  name        : string;
  database    : string;
  value_type  : type_expr;
  default_ttl : int option;
  raw_fields  : config_field list;
  loc         : loc;
}

type smtp_config = {
  host     : string;
  port     : int;
  username : string;
  password : string;
  tls      : bool;
}

type email_form = {
  name       : string;
  database   : string;
  smtp       : smtp_config;
  raw_fields : config_field list;
  loc        : loc;
}

type workers_form = {
  name       : string;
  queue_name : string;
  bindings   : (string * string) list;  (** (job_type, worker_fn) *)
  is_dead    : bool;
  loc        : loc;
}

(* ─── Capture form ───────────────────────────────────────────────────────── *)

type capture_form = {
  name    : string;
  binding : binding;
  parser  : string;   (** e.g. stringCodec, intCodec *)
  checker : string option;
  loc     : loc;
}

(* ─── API form ───────────────────────────────────────────────────────────── *)

type http_method = GET | POST | PUT | DELETE | PATCH | SSE

type api_auth = {
  binding : binding;
  via_fn  : string;
}

type api_capture = {
  binding      : binding;
  via_fn       : string;          (** references a top-level `capturer` (empty for inline) *)
  inline_codec : string option;   (** inline form: `capture x: T with <codec> [via <check>]` *)
  inline_check : string option;   (** optional `via <check>` of the inline form (mints a proof) *)
}

type api_endpoint = {
  name           : string;   (** derived from the handler name *)
  method_        : http_method;
  path           : string;
  auth           : api_auth option;
  body           : binding option;
  body_wire_type : string option;
  body_decoder   : string option;
  body_via       : string option;
  response_wire_type : string option;
  response_encoder   : string option;
  captures       : api_capture list;
  return_spec    : return_spec;
  subscribes     : string list;
  loc            : loc;
  has_explicit_return    : bool;  (** true iff `->` was written in source *)
  has_clause_after_return : bool; (** true iff an endpoint clause appears after `->` *)
}

type api_form = {
  name      : string;
  endpoints : api_endpoint list;
  loc       : loc;
}

(* ─── Server form ────────────────────────────────────────────────────────── *)

type server_form = {
  name     : string;
  api_name : string;
  bindings : (string * string) list;  (** (endpoint_name, handler_fn) *)
  loc      : loc;
}

(* ─── Test forms ─────────────────────────────────────────────────────────── *)

(** A statement within a test body. *)
type property_param = {
  binding    : binding;
  where_clause : expr option;
  generator  : string option;
  loc        : loc;
}

type test_stmt =
  | TsLet       of { name : string; declared_type : type_expr option; value : expr; declared_proof : proof_expr option; loc : loc }
  | TsLetProof  of { value_name : string; proof_names : string list; value : expr; loc : loc }
  | TsExpect    of { left : expr; right : expr option; loc : loc }
                   (** expect expr [== expr] — right=None means expect truthy *)
  | TsExpectFail of { fn : expr; arg : expr; loc : loc }
  | TsExpectHasProof of { fn : expr; arg : expr; proof_name : string; loc : loc }
  | TsProperty  of { description : string; params : property_param list; body : expr; loc : loc }
  | TsIf        of { cond : expr; then_stmts : test_stmt list; else_stmts : test_stmt list; loc : loc }
  | TsCase      of { scrut : expr; arms : ts_case_arm list; loc : loc }
                   (** case expr of Pattern -> [test_stmts...]; allows expect inside arms *)
  | TsExpr      of { e : expr; loc : loc }

and ts_case_arm = {
  ts_pattern : pattern;
  ts_guard   : expr option;
  ts_body    : test_stmt list;
  ts_loc     : loc;
}

type test_form = {
  description  : string;
  stmts        : test_stmt list;
  runs         : int option;
  capabilities : string list;
  loc          : loc;
}

type api_test_form = {
  description  : string;
  server_name  : string;
  seed_stmts   : expr list;
  stmts        : test_stmt list;
  capabilities : string list;
  loc          : loc;
}

(* ─── Load-test assertions ───────────────────────────────────────────────── *)

type load_test_metric =
  | LtP50 | LtP95 | LtP99 | LtP999
  | LtErrorRate | LtThroughput

type load_test_assertion =
  | LtAssertMetric of {
      metric : load_test_metric;
      op     : binop;       (** BLt, BLe, BGt, BGe *)
      value  : float;
      unit   : string;      (** "ms", "rps", "" (ratio) *)
    }
  | LtAssertRegression of {
      metric : load_test_metric;
      ratio  : float;
    }

type load_test_form = {
  description  : string;
  server_name  : string;
  rate         : int;           (** requests per second *)
  duration     : int;           (** seconds *)
  baseline     : string option;
  seed_stmts   : expr list;
  request_stmts : test_stmt list; (** HTTP request statements *)
  assertions   : load_test_assertion list;
  capabilities : string list;
  loc          : loc;
}

(* ─── Import / module ────────────────────────────────────────────────────── *)

type import_decl = {
  module_name : string;
  names       : import_names;
  loc         : loc;
}

and import_names =
  | ImportAll                   (** import Module — qualified access only *)
  | ImportExposing of string list (** import Module exposing [a, b, C(..)] *)

type export_item =
  | ExportName of string
  | ExportAdt  of string   (** Color(..) — type + all constructors *)

(* ─── Top-level declarations ─────────────────────────────────────────────── *)

type top_decl =
  | DFunc       of func_decl
  | DType       of type_form
  | DRecord     of record_form
  | DEntity     of entity_form
  | DFact       of fact_form
  | DCodec      of codec_form
  | DDatabase   of database_form
  | DCapability of capability_form
  | DConst      of const_form
  | DQueue      of queue_form
  | DChannel    of channel_form
  | DWorkers    of workers_form
  | DCache      of cache_form
  | DEmail      of email_form
  | DCapture    of capture_form
  | DApi        of api_form
  | DServer     of server_form
  | DTest       of test_form
  | DApiTest    of api_test_form
  | DLoadTest   of load_test_form

(* ─── Module ─────────────────────────────────────────────────────────────── *)

type module_form = {
  module_name : string;
  is_library  : bool;    (** true when declared with `library` keyword instead of `module` *)
  exports     : export_item list;
  imports     : import_decl list;
  decls       : top_decl list;
  source_file : string;
}

(* ─── Proof/type conversion helper ────────────────────────────────────────── *)

(** Inverse of [proof_expr_to_type_expr] in parser.ml.
    Reconstructs a [proof_expr] from the [type_expr] encoding used inside
    [Fact (...)] type annotations.  Returns [None] for type expressions that
    do not encode a proof (e.g. plain type applications with non-name args). *)
let rec type_expr_to_proof_expr (te : type_expr) : proof_expr option =
  match te with
  (* PredAnd: TApp(TApp(TName "&&", l), r) *)
  | TApp { head = TApp { head = TName { name = "&&"; loc }; arg = l; _ }; arg = r; _ } ->
    (match type_expr_to_proof_expr l, type_expr_to_proof_expr r with
     | Some pl, Some pr -> Some (PredAnd { left = pl; right = pr; loc })
     | _ -> None)
  (* PredApp: TApp*(TName pred, TName arg0, ...) — peel off args right-to-left *)
  | _ ->
    let rec collect args = function
      | TApp { head; arg; _ } ->
        let arg_name = match arg with
          | TName { name; _ } | TVar { name; _ } -> Some name
          | _ -> None
        in
        (match arg_name with
         | Some name -> collect (name :: args) head
         | None -> None)
      | TName { name; loc } -> Some (PredApp { pred = name; args; loc })
      | TVar { name; loc } -> Some (PredApp { pred = name; args; loc })
      | _ -> None
    in
    collect [] te
