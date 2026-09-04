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
  | TFun    of { dom : type_expr; cod : type_expr;
                 caps : string list;  (** capability row on the arrow: `(a -> b requires c)`;
                                          names are row variables (bound by this occurrence)
                                          or concrete capabilities. Empty for a plain `a -> b`. *)
                 loc : loc }  (** a -> b [requires c] *)
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

(* SQL payload records below intentionally share field labels. *)
[@@@ocaml.warning "-30"]
type lit =
  | LInt    of int
  | LBigInt of string                       (** canonical signed decimal for |value| outside native int; e.g. "9999999999999999999999" or "-4611686018427387905" *)
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
  | EBinop  of { op : binop; left : expr; right : expr; loc : loc;
                 op_loc : loc }
               (** [op_loc]: the operator token itself — [loc] spans the whole
                   [left op right] expression, so a diagnostic that wants to
                   edit just the operator (D9 `+`→`++`) needs the token's own
                   span.  Synthesized nodes reuse the expression [loc]. *)
  | EUnop   of { op : unop; arg : expr; loc : loc }
  | EIf     of { cond : expr; then_ : expr; else_ : expr; loc : loc }
  | ECase   of { scrut : expr; arms : case_arm list; loc : loc }
  | ELet    of { name : string; declared_type : type_expr option; declared_proof : proof_expr option; value : expr; body : expr; loc : loc }
  | ELetProof of { value_name : string; proof_name : string; proof_index : (int * int) option; value : expr; body : expr; loc : loc }
               (** let (value_name ::: proof_name) = value — proof decompose *)
  | ERecord of { fields : (string * expr) list; type_hint : string option; loc : loc }
               (** record literal { k: v, ... } — type_hint from let x: Type = { } *)
  | EList   of { elems : expr list; loc : loc }
  | EOk     of { value : expr; proof : proof_expr; keyword : bool; loc : loc }
               (** [ok expr ::: Proof] ([keyword = true]) and the bare attachment
                   [expr ::: proof] ([keyword = false]).  ONE node for both, because they
                   mean the same thing to the checker — a value carrying a proof — and the
                   spelling is what tells a CONSUMER whether the result is a check's answer
                   (a [Check]) or an ordinary value with an erased proof.  The Go backend
                   needs that distinction: [let outcome = if … then ok n ::: P else fail …]
                   is a check result, while [let reat = v ::: proof] is just [v]. *)
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
  | EServe of { server_name : string; port : expr; capabilities : string list; static_dir : string option; mount_path : string option; loc : loc }
  | EConstructor of { name : string; args : expr list; loc : loc }
               (** Constructor applied to zero or more args *)
   | ELambda of { params : binding list; body : expr; loc : loc }
                (** Anonymous function: fn(x: T, y: T) -> body *)
   | ESqlQuery of { query : sql_query; loc : loc }
                (** A parsed SQL operation. SQL payloads are mutually recursive
                    with expressions because predicates and assignments contain them. *)
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

(* ─── SQL query expressions ──────────────────────────────────────────────── *)

and sql_clause =
  | SqlPred of { field : string; op : binop; value : expr }
  | SqlOr of sql_clause list
  | SqlIsNull of { field : string }
  | SqlIsNotNull of { field : string }
  | SqlIn of { field : string; values : expr list }
  | SqlNotIn of { field : string; values : expr list }
  | SqlLike of { field : string; pattern : expr }
  | SqlILike of { field : string; pattern : expr }

and sql_join = {
  join_entity : string;
  main_field : string;
  join_field : string;
}

and sql_select_kind =
  | SelectMany
  | SelectOne
  | SelectCount
  | SelectSum of string
  | SelectMax of string
  | SelectMin of string
  | SelectCountBy
  | SelectSumBy of string

and sql_group_key =
  | GField of string
  | GTimeTrunc of string * expr * string

and sql_select_seed = {
  kind : sql_select_kind;
  binder : string;
  entity : string;
  where_field : string option;
  order : (string * string) option;
  limit : int option;
  offset : int option;
  static_clauses : sql_clause list;
  group_by : sql_group_key list;
  joins : sql_join list;
}

and sql_insert = {
  entity : string;
  fields : (string * expr) list;
}

and sql_delete_seed = {
  binder : string;
  entity : string;
  where_field : string option;
  with_result : bool;
}

and sql_update = {
  binder : string;
  entity : string;
  clauses : sql_clause list;
  updates : (string * expr) list;
  returning_one : bool;
  returns_row : bool;
}

and sql_upsert = {
  entity : string;
  fields : (string * expr) list;
  conflict : string list;
  do_update : string list;
}

and sql_query =
  | QuerySelect of sql_select_seed * sql_clause list
  | QueryInsert of sql_insert
  | QueryInsertMany of string * string
  | QueryUpsert of sql_upsert
  | QueryUpdate of sql_update
  | QueryDelete of sql_delete_seed * sql_clause list
[@@@ocaml.warning "+30"]

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

(** The trusted proof-introducing function kinds (LANGUAGE-SPEC §7.12): only
    [check], [auth], and [establish] may MINT a proof or own a fact predicate.
    This is the single source of truth for that set (B2 / generator G1): every
    "may this kind introduce a proof?" decision must derive from here rather than
    restate the constructor list.  The match is exhaustive on purpose — a future
    [func_kind] forces an explicit decision here instead of silently defaulting.

    NOTE: this is NOT the same set as "runs in a dot-notation function context"
    (that also includes handlers/workers) nor "may use ok/fail" (check/auth only)
    — do not fold those into this predicate. *)
let is_proof_introducing_kind = function
  | CheckKind | AuthKind | EstablishKind -> true
  | FnKind | HandlerKind | WorkerKind | DeadWorkerKind | MainKind -> false

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

(* Declared above [func_decl] because a `handler` states the HTTP method(s) it
   serves (issue #65 follow-up); the `api` block's endpoints use the same type. *)
type http_method = GET | POST | PUT | DELETE | PATCH | SSE

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
  doc         : string option;
                (** The contiguous leading `#` comment block above the declaration,
                    harvested post-parse. Used as the description for a function
                    exposed as an agent/MCP tool. [None] when undocumented. *)
  http_methods : http_method list;
                (** The HTTP method(s) this handler serves, from the contextual
                    keyword(s) after `handler` (`handler get greet(…)`, or
                    `handler get post search(…)` for one function serving two
                    slots).  Only ever non-empty for [HandlerKind].

                    Load-bearing, not decoration: the method already determines
                    what a handler may legally do — SEC005 forbids `dbWrite`,
                    `queueWrite`, `pubsub` and `emailCap` anywhere in a GET
                    handler's capability closure.  Declaring it here means that
                    security rule reads the handler's own text instead of
                    inferring the method through the server block's POSITIONAL
                    pairing, and gives that pairing an extra discriminator so a
                    misordered server block is caught structurally rather than
                    only warned about (W095). *)
}

type adt_variant = {
  ctor    : string;
  fields  : field_def list;
  loc     : loc;
}

type type_form =
  | TypeNewtype of { name : string; base_type : type_expr; secret : bool; loc : loc }
                   (** [type UserId = String], or [secret Password = String] when
                       [secret] is true.

                       A SECRET is a newtype in every structural respect — same
                       nominal identity, same runtime [newtype-value] wrapper,
                       same SQL round-trip — MINUS [.value], minus [Ord], plus
                       redaction at every rendering sink, plus rejection in a
                       response/codec/generated-client position.  It is a FLAG
                       on this constructor rather than a constructor of its own
                       precisely because everything else about it is identical:
                       [TypeNewtype] is matched at ~55 sites, and every
                       [{ name; base_type; _ }] pattern keeps working. *)
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

(** A secondary index declared in an entity body:
    [index [orgId, createdAt]] / [unique index [orgId, slug] as "my_idx"].

    [ix_fields] names entity FIELDS (not columns) in index order — the
    field→column mapping is owned by the runtime, which is where column naming
    already lives.  [ix_name] is the explicit `as` override; when [None] the
    runtime derives the name from the table and column names. *)
type entity_index = {
  ix_unique : bool;
  ix_fields : string list;
  ix_name   : string option;
  ix_loc    : loc;
}

type entity_form = {
  name        : string;
  table       : string;
  primary_key : string;
  fields      : field_def list;
  indexes     : entity_index list;
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
  | DecodeDefault of { field_name : string; default_lit : lit; loc : loc }
      (** `field <- default <literal>`.  Carries the LITERAL, not a rendered string: it
          used to hold pre-rendered Racket source (`#t`, Racket string escaping, Racket
          float syntax), which no other backend could consume without parsing Racket. *)
  | DecodeCrossCheck of { checker : string; loc : loc }

type codec_form = {
  name       : string;
  type_name  : string;   (** the type being given a codec *)
  to_json    : codec_to_json;
  from_json  : codec_from_json;
  loc        : loc;
}

(* ─── Database form ──────────────────────────────────────────────────────── *)

type database_form = {
  name       : string;
  backend    : string;                   (** e.g. "postgres" | "memory" ("" = default postgres) *)
  schema     : string;
  entities   : string list;
  postgres   : (string * string) list;  (** key-value connection params *)
  config_expr : expr option;             (** typed-record syntax: `= Database { … }` (desugar fills the fields above) *)
  loc        : loc;
}

(* ─── Queue / sseChannel / workers ─────────────────────────────────────────── *)

type queue_form = {
  name             : string;
  database         : string;
  jobs             : string list;
  max_attempts     : int option;
  backoff          : string option;
  initial_delay    : int option;
  capabilities     : string list;     (** `requires [...]` for the folded workers (App pass) *)
  number_of_workers : int option;     (** `numberOfWorkers: N` (App pass); workers started on App activation *)
  config_expr      : expr option;
  loc              : loc;
}

type channel_form = {
  name       : string;
  key_params : binding list;
  database   : string;
  payload    : type_expr;
  config_expr : expr option;
  loc        : loc;
}

type cache_form = {
  name        : string;
  database    : string;
  value_type  : type_expr;
  default_ttl : int option;
  config_expr : expr option;        (** typed-record syntax: = Cache { … } *)
  loc         : loc;
}

(** A declarative AI agent:
      agent SupportAgent requires [supportAi] = Agent {
        provider:     anthropic            -- anthropic | openai | local
        model:        "claude-opus-4-8"
        apiKey:       env "ANTHROPIC_API_KEY"
        systemPrompt: "You are a concise support agent."
        tools:        [lookupOrder, refundOrder]
        maxTokens:    1500
      }
    The parser leaves everything in [config_expr]; {!Desugar.desugar_agent_config}
    extracts the structured fields the emitter reads (same pattern as queue/cache). *)
type agent_form = {
  name          : string;
  capabilities  : string list;      (** from `requires [...]` — bounds the tools' authority *)
  provider      : string;           (** "anthropic" | "openai" | "local" (desugar fills) *)
  model         : string;           (** rendered config value: literal or env("X") *)
  api_key       : string;           (** rendered config value: literal or env("X") *)
  endpoint      : string;           (** rendered; used when provider = local *)
  system_prompt : string;           (** rendered config value *)
  max_tokens    : int;              (** desugar fills; default 1024 *)
  tools         : string list;      (** tool function names (referenced like server handlers) *)
  config_expr   : expr option;      (** `= Agent { … }` RHS; desugar lifts the fields above *)
  loc           : loc;
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
  config_expr : expr option;
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

(* S6a/C11: an endpoint is either an HTTP request/response endpoint OR an SSE
   stream. The HTTP-only fields (body, response, return spec) live in [http_clause]
   and the SSE-only channel list in [sse_clause], so an SSE endpoint STRUCTURALLY
   cannot hold a body/response/return — the unsound combination the validator used
   to reject is now unrepresentable. Common fields stay on [api_endpoint]. *)
type http_clause = {
  body           : binding option;
  body_wire_type : string option;
  body_decoder   : string option;
  body_via       : string option;
  response_wire_type : string option;
  response_encoder   : string option;
  return_spec    : return_spec;
  has_explicit_return    : bool;  (** true iff `->` was written in source *)
  has_clause_after_return : bool; (** true iff an endpoint clause appears after `->` *)
}

(** The channel-key argument of a `subscribe Ch(arg)` clause: either a bare
    identifier naming a `:param` of the path (the common, per-request-scoped
    case, e.g. `conversationId` in `subscribe ChatStream(conversationId)`), or
    a fixed string literal for a broadcast-style channel with no per-request
    key (e.g. `subscribe RunEvents("all")`). *)
type subscribe_key_arg =
  | SubscribeKeyParam of string
  | SubscribeKeyLiteral of string

type sse_clause = {
  subscribes : string list;       (** the channel(s) an SSE endpoint streams *)
  (** [None] when the subscribe has no argument (a channel with no key
      parameter).  The emitter uses a param argument to pick WHICH `:param`
      segment carries the channel key; before it was recorded the key was
      assumed to be the segment right after the literal prefix, so a key that
      was not the last segment (e.g. `/rooms/:roomId/events`) keyed on the
      wrong segment.  A literal argument keys every connection on that fixed
      string regardless of path. *)
  subscribe_key : subscribe_key_arg option;
  (** S6a: an SSE endpoint may NOT declare body/response/return clauses. The parser
      records which such clauses were WRITTEN (breadcrumbs only — never the body/
      response VALUES, so emit still cannot use them) so validation rejects them
      with a clear message rather than silently dropping. *)
  illegal_clauses : string list;
}

type endpoint_kind =
  | Http of http_clause
  | Sse  of sse_clause

type api_endpoint = {
  name           : string;   (** derived from the handler name *)
  method_        : http_method;   (** never [SSE] when [kind] is [Http] *)
  path           : string;
  auth           : api_auth option;
  captures       : api_capture list;
  loc            : loc;
  kind           : endpoint_kind;
}

(* S6a accessors — read a per-clause field with an SSE-safe default, so consumers
   that treated the old flat record uniformly stay concise. An SSE endpoint has no
   body/response/return (structurally); those default to None/[]/false here. *)
let ep_body ep = match ep.kind with Http h -> h.body | Sse _ -> None
let ep_body_wire_type ep = match ep.kind with Http h -> h.body_wire_type | Sse _ -> None
let ep_body_decoder ep = match ep.kind with Http h -> h.body_decoder | Sse _ -> None
let ep_body_via ep = match ep.kind with Http h -> h.body_via | Sse _ -> None
let ep_response_wire_type ep = match ep.kind with Http h -> h.response_wire_type | Sse _ -> None
let ep_response_encoder ep = match ep.kind with Http h -> h.response_encoder | Sse _ -> None
let ep_has_explicit_return ep = match ep.kind with Http h -> h.has_explicit_return | Sse _ -> false
let ep_has_clause_after_return ep = match ep.kind with Http h -> h.has_clause_after_return | Sse _ -> false
let ep_subscribes ep = match ep.kind with Sse s -> s.subscribes | Http _ -> []
(** The channel-key argument of an SSE endpoint's `subscribe Ch(arg)`; [None] for HTTP. *)
let ep_subscribe_key ep = match ep.kind with Sse s -> s.subscribe_key | Http _ -> None
(** Illegal clauses an SSE endpoint declared (body/response/return); [] for HTTP. *)
let ep_sse_illegal_clauses ep = match ep.kind with Sse s -> s.illegal_clauses | Http _ -> []
(** The return spec of an HTTP endpoint; [None] for SSE (which has no response). *)
let ep_return_spec_opt ep = match ep.kind with Http h -> Some h.return_spec | Sse _ -> None
(** Return spec with an SSE default of [RetPlain Unit] (SSE had that default before
    S6a, so consumers stay byte-exact). *)
let ep_return_spec ep = match ep.kind with
  | Http h -> h.return_spec
  | Sse _ -> RetPlain { ty = TName { name = "Unit"; loc = ep.loc }; loc = ep.loc }

type api_form = {
  name      : string;
  endpoints : api_endpoint list;
  loc       : loc;
}

(* ─── Server form ────────────────────────────────────────────────────────── *)

(* Phase 3 (OQ11): the source of the server's public origin.  Either an inline
   string literal or an env-var read (12-factor deploys).  Both resolve to the
   SAME validated origin at boot (absolute https — or http only for a loopback
   host — with no path beyond `/`, no query, no fragment); the env form is read
   ONCE at boot, NEVER from a request. *)
type public_origin_src =
  | POLiteral of string  (** [publicOrigin "https://app.example.com"] *)
  | POEnv of string      (** [publicOrigin fromEnv "PUBLIC_ORIGIN"] — the env var name *)

type server_form = {
  name     : string;
  api_name : string;
  handlers : string list;
  (** Handler functions, positionally paired with the api's non-SSE endpoints
      in declaration order (issue #65: the block used to carry a spurious
      `endpoint_name =` prefix that looked name-keyed but was always matched
      by position — removed so the syntax stops lying about that). *)
  (* Phase 3 (roadmap/next/ensure_sso_works.md): the `sessionPolicy` server
     clause — a closed keyword set ("StandardSession" | "ShortSession"), not a
     free value, so it cannot be turned the unsafe way.  Sets the runtime's
     `current-session-policy` at boot; server-wide, not SSO-specific. *)
  session_policy : string option;
  (* Phase 3: the `publicOrigin` clause — the app's verified public origin (the
     redirect_uri base, and the HSTS origin).  An inline literal OR a `fromEnv`
     env-var read (OQ11); NEVER derived from a request header. *)
  public_origin : public_origin_src option;
  (* Phase 3: repeatable `sso "<seg>" connection <fn> onIdentity <fn>` clauses.
     Each mints /auth/<seg>/login and /auth/<seg>/callback (runtime-owned).
     Tuple: (route_segment, connection_fn, on_identity_fn). *)
  sso_clauses : (string * string * string) list;
  (* Phase 3: `sessionKey "ENV_VAR"` (the session-signing Secret's env var)
     and `afterLogin "/path"` (the post-login landing).  String literals. *)
  sso_session_key_env : string option;
  (* Phase 3: `sessionPreviousKey "ENV_VAR"` — the OPTIONAL previous session-signing
     key (rotation overlap).  Sets `current-previous-session-key` at boot so
     JWT.verify accepts tokens signed by either key; emptying it is the global
     kill switch.  A string literal naming the env var (a Secret). *)
  sso_previous_key_env : string option;
  after_login : string option;
  (* Phase 3: `sessionRevoked <fn>` — the app's revocation predicate, consulted
     ONLY at session renewal (fail-closed).  Stores the function name; the
     emitted adapter converts the runtime's epoch-seconds iat to the Tesl fn's
     `(String, PosixMillis) -> Bool` contract. *)
  session_revoked : string option;
  (* Phase 3: `listenAddress Loopback | AllInterfaces` — a CLOSED keyword set for
     the interface the server binds to.  `Loopback` binds 127.0.0.1 only (behind
     a reverse proxy); `AllInterfaces` is the default.  Sets serve's #:listen-ip
     at boot via the runtime registry. *)
  listen_address : string option;
  (* Phase 3: `loginMethods [Sso] | [Sso, Password via <fn>] | [Sso, Proxy]` — the
     fail-closed allowlist of session-establishment methods.  A CLOSED keyword set
     (Sso | Password | Proxy).  Under a `loginMethods` declaration WITHOUT
     `Password`, no app code may mint a session (`Http.setSessionCookie`) or run a
     password call (`Crypto.checkPassword`/`hashPassword`) — the only minting site
     is the runtime-owned SSO callback.  The `Password via <fn>` policy-fn name is
     carried separately. *)
  login_methods : string list option;
  password_policy_fn : string option;
  (* #51: the `trustedProxies [ "10.0.0.1", ... ]` edge declaration — the
     trusted proxy addresses in front of the app.  Empty = no declaration
     (⇒ `request.clientAddress` is the unspoofable socket peer). *)
  trusted_proxies : string list;
  (* Risk 50/60: `healthProbePath "/healthz"` — the ONE path exempt from Host
     validation (a load balancer probes host-blind). *)
  health_probe_path : string option;
  (* OQ17/#50.1: `contentSecurityPolicy "<policy>"` — the server default CSP for
     HTML responses (a handler may still override per response). *)
  content_security_policy : string option;
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

(** All expressions contained in a test statement, recursing into nested
    statement blocks — for module walks that scan test bodies for a syntactic
    form (e.g. the `serverTools` lowering/require detection). *)
let rec test_stmt_exprs (s : test_stmt) : expr list =
  match s with
  | TsLet { value; _ } -> [value]
  | TsLetProof { value; _ } -> [value]
  | TsExpect { left; right; _ } ->
    left :: (match right with Some r -> [r] | None -> [])
  | TsExpectFail { fn; arg; _ } -> [fn; arg]
  | TsExpectHasProof { fn; arg; _ } -> [fn; arg]
  | TsProperty { body; _ } -> [body]
  | TsIf { cond; then_stmts; else_stmts; _ } ->
    cond :: (List.concat_map test_stmt_exprs then_stmts
             @ List.concat_map test_stmt_exprs else_stmts)
  | TsCase { scrut; arms; _ } ->
    scrut :: List.concat_map (fun (a : ts_case_arm) ->
      (match a.ts_guard with Some g -> [g] | None -> [])
      @ List.concat_map test_stmt_exprs a.ts_body) arms
  | TsExpr { e; _ } -> [e]

type test_form = {
  description  : string;
  stmts        : test_stmt list;
  runs         : int option;
  capabilities : string list;
  (* Optional `with database X` header clause: binds the named database for the test
     body (so queries run against X's configured backend).  [None] ⇒ the default
     in-memory store, which is what the vast majority of tests use. *)
  database     : string option;
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
  | DAgent      of agent_form
  | DEmail      of email_form
  | DCapture    of capture_form
  | DApi        of api_form
  | DServer     of server_form
  | DTest       of test_form
  | DApiTest    of api_test_form
  | DLoadTest   of load_test_form

(* The source span of a top-level declaration. *)
let top_decl_loc (decl : top_decl) : loc =
  match decl with
  | DFunc fd -> fd.loc
  | DType (TypeNewtype { loc; _ })
  | DType (TypeAdt { loc; _ }) -> loc
  | DRecord r -> r.loc
  | DEntity e -> e.loc
  | DFact f -> f.loc
  | DCodec c -> c.loc
  | DDatabase d -> d.loc
  | DCapability c -> c.loc
  | DConst c -> c.loc
  | DQueue q -> q.loc
  | DChannel c -> c.loc
  | DWorkers w -> w.loc
  | DCache c -> c.loc
  | DEmail e -> e.loc
  | DAgent a -> a.loc
  | DCapture c -> c.loc
  | DApi a -> a.loc
  | DServer s -> s.loc
  | DTest t -> t.loc
  | DApiTest t -> t.loc
  | DLoadTest t -> t.loc

(* ─── Module ─────────────────────────────────────────────────────────────── *)

type module_form = {
  module_name : string;
  exports     : export_item list;
  imports     : import_decl list;
  decls       : top_decl list;
  source_file : string;
}

(** The trailing `App { … }` record expression of a `main` function's body.

    `main`'s body is normally a chain of startup `let`s (telemetry init, port
    resolution, seeding) ending in the App record, so the chain is walked to its
    tail first.  Both spellings are accepted: a record carrying the `App` type
    hint, and `App` applied to a record. *)
let app_record_of_main (fd : func_decl) : expr option =
  if fd.kind <> MainKind then None
  else
    let rec tail = function
      | ELet { body; _ } | ELetProof { body; _ } -> tail body
      | e -> e in
    match tail fd.body with
    | (ERecord { type_hint = Some "App"; _ }
      | EApp { fn = EConstructor { name = "App"; _ }; arg = ERecord _; _ }) as e -> Some e
    | _ -> None

(** The literal string value of one field in `main`'s returned `App { … }`
    record (see [app_record_of_main]; [Linter.app_activated_names] is its twin
    for reference-list fields like `queues`). [None] when `main` is absent, the
    field is absent, or the field is not a plain string literal (an
    `envRead`/computed value is deliberately not resolved here — every caller is
    a compile-time-only concern: desugar's runtime-call emission and the client
    generators' request-URL base both need the literal at compile time or not at
    all). *)
let main_app_string_field (m : module_form) (key : string) : string option =
  let fields_of = function
    | ERecord { fields; _ } -> fields
    | EApp { arg = ERecord { fields; _ }; _ } -> fields
    | _ -> [] in
  List.find_map (function
    | DFunc fd ->
      (match app_record_of_main fd with
       | None -> None
       | Some app ->
         (match List.assoc_opt key (fields_of app) with
          | Some (ELit { lit = LString s; _ }) -> Some s
          | _ -> None))
    | _ -> None) m.decls

(* ─── Capability-row helpers ──────────────────────────────────────────────── *)

(** Capability-row variables bound by a function's parameters: the union of the
    capability rows annotated on any arrow (`TFun`) type inside a parameter's
    type, e.g. the [c] in [f: (Int -> Int requires c)].  Within the function's
    own [requires] clause, names in this set are row *variables* (instantiated at
    each call site); all other names are concrete capabilities.  Shared by the
    capability checker (P001 + the needs⊆declares check) and the emitter (which
    drops row variables from the emitted `#:capabilities`). *)
(* Concrete built-in capabilities.  A capability-ROW variable is a FRESH,
   polymorphic name (instantiated per call site); a concrete built-in capability
   is not.  GDP-CAP-SPELLING (2026-07 fresh review): [func_bound_cap_vars_of_params]
   collected row names purely by spelling, so writing a concrete capability (e.g.
   `time`) as a parameter arrow's cap-row (`f: (Int -> Int requires time)`) made
   the function's own genuine `requires [time]` get stripped from propagation AND
   from the emitted runtime `#:capabilities` — laundering the capability.  A
   concrete capability can therefore NEVER be a row variable.  (Single source of
   truth for the built-in set is [Validation_common.tesl_stdlib_cap_map]; this
   lowest-layer list mirrors it — a mismatch is caught by the seam tests.) *)
let builtin_capability_names : string list =
  [ "dbRead"; "dbWrite"; "time"; "random"; "envRead";
    "queueRead"; "queueWrite"; "pubsub"; "uuid"; "jwt";
    "httpClient"; "aiProvider"; "emailCap"; "cookieCap" ]

let resource_capability_verbs : string list =
  [ "dbRead"; "dbWrite"; "queueRead"; "queueWrite"; "pubsub" ]

let resource_capability_parts (name : string) : (string * string) option =
  match String.split_on_char ' ' name with
  | [verb; resource]
    when resource <> "" && List.mem verb resource_capability_verbs ->
    Some (verb, resource)
  | _ -> None

let is_concrete_builtin_capability (name : string) : bool =
  List.mem name builtin_capability_names || Option.is_some (resource_capability_parts name)

let func_bound_cap_vars_of_params (params : binding list) : string list =
  let rec from_type acc (t : type_expr) =
    match t with
    | TFun { dom; cod; caps; _ } -> from_type (from_type (caps @ acc) dom) cod
    | TApp { head; arg; _ } -> from_type (from_type acc head) arg
    | TTuple { elems; _ } -> List.fold_left from_type acc elems
    | TName _ | TVar _ -> acc
  in
  List.fold_left (fun acc (b : binding) -> from_type acc b.type_expr) [] params
  (* A concrete built-in capability is never a row variable, even when it is
     spelled as a parameter arrow's cap-row — otherwise it launders. *)
  |> List.filter (fun n -> not (is_concrete_builtin_capability n))
  |> List.sort_uniq String.compare

let func_bound_cap_vars (fd : func_decl) : string list =
  func_bound_cap_vars_of_params fd.params

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
