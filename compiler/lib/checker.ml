(** Module-level type checker for Tesl (Phase 2).

    Runs Algorithm W over the parsed AST, collecting type errors.
    Does not modify the emitter — errors are reported separately via
    --check and --check-json.

    T_ANY does not exist in this implementation.  Every expression
    gets a fully resolved type, or a located error is emitted. *)

open Ast
open Type_system

(* ── Inference context ────────────────────────────────────────────────────── *)

(** Record types defined in the current module: name → field list. *)
type record_def = {
  rd_name   : string;
  rd_fields : (string * ty) list;
}

(** ADT types defined in the current module: name → variant list. *)
type adt_def = {
  ad_name     : string;
  ad_params   : string list;  (** type parameters *)
  ad_variants : (string * (string * ty) list) list;  (** (constructor, [(field_name, field_type)]) *)
}

(** The typing context carries the env, ADT/record defs, and error accumulator. *)
type binding_meta =
  | PlainBinding
  | AttachedProofBinding of proof_expr
  | FactProofBinding of proof_expr

type function_proof_return =
  | ReturnsAttachedProof of { binder_name : string; proof : proof_expr }

type local_binding_info = {
  name : string;
  loc : Location.loc;
  ty : ty;
  display_ty : string;
  hover_note : string option;
}

type expr_type_info = {
  loc : Location.loc;
  ty : ty;
  display_ty : string;
}

type field_access_info = {
  fa_loc         : Location.loc;
  fa_field       : string;
  fa_record_type : string;  (** record type name, e.g. "User" *)
  fa_field_type  : string;  (** display type of the field, e.g. "String" *)
}

(* serverTools (server endpoints as agent tools): one non-SSE endpoint of the
   server's api, as seen by the `serverTools S user` inclusion decision. *)
type server_tools_endpoint = {
  ste_binding : string;
  (** the server-binding name for this endpoint — the tool's model-facing name *)
  ste_preds : (string * string list) list;
  (** the endpoint's `auth` predicates, normalized: (predicate name, args with
      the auth binder replaced by "§").  [] = endpoint without an auth line
      (public), included for every caller. *)
}

(* Eq/Ord Stage-3 (compile-time constraint threading).  A closed, built-in
   predicate set — no user classes/instances, no surface syntax.  POrd/PEq mark a
   type variable that a function's body compares with </== ; captured per-fn from
   the body (harvest) and discharged at each call site against the concrete
   instantiation (see [ord_eq_constraints], [check_ord_eq_calls]). *)
type ord_eq_pred = POrd | PEq

type ctx = {
  env      : (string * scheme) list;
  records  : (string * record_def) list;
  adts     : (string * adt_def) list;      (* type name → ADT def *)
  type_aliases : (string * ty) list;        (* newtype/alias name → base type (for Eq/Ord resolution) *)
  ctors    : (string * (string * scheme)) list;(* ctor name → (type_name, ctor_scheme) *)
  errors   : type_error list ref;
  local_bindings : local_binding_info list ref;
  expr_types : expr_type_info list ref;
  field_accesses    : field_access_info list ref;
  bare_record_hints : (Location.loc * string) list ref;
  entity_binder_at : (Location.loc * string) list ref;
  binding_meta_env : (string * binding_meta) list;
  subject_chain_env : (string * string list) list;
  proof_returns : (string * function_proof_return) list;
  function_kinds : (string * func_kind) list;
  subst    : subst ref;
  filename : string;
  in_establish : bool;  (** true when type-checking an establish function body *)
  codec_decode_types : string list;
  (** locally-declared type names that have a non-forbidden fromJson codec.
      Consulted (decide-by-resolution) to validate `decodeAs` targets. *)
  ord_eq_acc : (ord_eq_pred * ty) list ref;
  (** Per-fn accumulator: (pred, operand-type) for every </== whose operand was
      NON-ground while checking the current function body.  Reset per fn in
      [check_func_decl]; finalized into [ord_eq_constraints]. *)
  ord_eq_constraints : (string, (ord_eq_pred * ty) list) Hashtbl.t;
  (** Module-wide: fn name → its captured Eq/Ord obligations, expressed in the
      fn scheme's RIGID vars (so they freshen consistently at a call). *)
  ord_eq_calls : (string * ty list * Location.loc) list ref;
  (** Module-wide: (callee-name, resolved arg types, call loc) recorded at each
      direct call, discharged after the module is checked. *)
  server_tools_env : (string * (string option * server_tools_endpoint list)) list;
  (** `serverTools` static surface: server name → (the user TYPE name bound by
      the api's `auth` lines (None when no non-SSE endpoint declares auth), the
      non-SSE endpoints with their tool names + normalized auth predicates).
      Server names are declarative configuration, not expression values (the
      same reason `App { api: S }` skips body type-checking), so the
      `serverTools S user` application is typed structurally against this env.
      Endpoint-shape rules live in [check_module]'s serverTools walk; capability
      charging in {!Validation_capabilities}; lowering in {!Emit_racket}. *)
  server_tools_sites : (Location.loc * (string * string list)) list ref;
  (** Every `serverTools S user` call site → (server name, the endpoint tool
      names INCLUDED for that site).  An endpoint is included iff the user
      variable's declared proof annotation covers the endpoint's auth
      predicates — so `u ::: Authenticated u` exposes the plain endpoints and
      `u ::: Authenticated u && Admin u` additionally exposes the admin-gated
      ones.  Sound because a declared annotation is itself checker-verified
      (params by call-site discharge, let/check bindings by their own rules).
      Threaded into the emitter (like [field_accesses]) so codegen builds
      exactly the included tools. *)
  server_tools_shadowed : bool;
  (** true when this module declares its own `serverTools` fn/value — the builtin
      arms stand down (decide-by-resolution, not by spelling). *)
  human_actions_sites : (Location.loc * (string * string list)) list ref;
  (** Every `humanActions S user` call site → (server name, the endpoint tool
      names EXCLUDED at that site).  An endpoint is excluded iff the user
      variable's declared proof annotation does NOT cover its auth predicates —
      the exact complement of the `serverTools` inclusion decision, so the two
      builtins partition the server's endpoints (disjoint, complete).  Threaded
      into the emitter to build exactly the inert human-action tools. *)
  human_actions_shadowed : bool;
  (** true when this module declares its own `humanActions` fn/value — the
      builtin arms stand down (decide-by-resolution, not by spelling). *)
  import_suggest : string -> Import_suggest.suggestion option;
  (** E1: unbound name → "which import would bind it" hint + quickfix.  Seeded
      per-module in {!check_module_with_metadata}; the default suggests nothing. *)
  source_lines : string array;
  (** D9: the source text being checked, split on '\n' — lets a diagnostic ship
      a source-VERIFIED machine-applicable fix ({!Diag_fix}).  [||] (callers
      without source, e.g. completion contexts) fail closed: the error is still
      emitted, just without a fix. *)
}

let make_ctx ?(source_lines = [||]) ~filename ~env () = {
  env;
  records  = [];
  adts     = [];
  type_aliases = [];
  ctors    = [];
  errors   = ref [];
  local_bindings = ref [];
  expr_types = ref [];
  field_accesses    = ref [];
  bare_record_hints = ref [];
  entity_binder_at = ref [];
  binding_meta_env = [];
  subject_chain_env = [];
  proof_returns = [];
  function_kinds = [];
  subst    = ref empty_subst;
  filename;
  in_establish = false;
  codec_decode_types = [];
  ord_eq_acc = ref [];
  ord_eq_constraints = Hashtbl.create 64;
  ord_eq_calls = ref [];
  server_tools_env = [];
  server_tools_sites = ref [];
  server_tools_shadowed = false;
  human_actions_sites = ref [];
  human_actions_shadowed = false;
  import_suggest = (fun _ -> None);
  source_lines;
}

let add_error ctx loc msg =
  ctx.errors := { loc; message = msg; fix = None } :: !(ctx.errors)

(* E1: an error that carries a machine-applicable import fix (LSP quickfix). *)
let add_error_fix ctx loc msg fix =
  ctx.errors := { loc; message = msg; fix } :: !(ctx.errors)

(* E1: "unknown name/constructor: x", with the import that would bind it (stdlib
   or a sibling module in the folder tree) appended as a hint + quickfix. *)
let add_unknown_name_error ctx loc ~what name =
  match ctx.import_suggest name with
  | Some (s : Import_suggest.suggestion) ->
    add_error_fix ctx loc
      (Printf.sprintf "unknown %s: %s%s" what name s.sug_hint) s.sug_fix
  | None -> add_error ctx loc (Printf.sprintf "unknown %s: %s" what name)

let current_subst ctx = !(ctx.subst)

let rec pp_proof_expr = function
  | PredApp { pred; args; _ } ->
    if args = [] then pred else pred ^ " " ^ String.concat " " args
  | PredAnd { left; right; _ } ->
    Printf.sprintf "%s && %s" (pp_proof_expr left) (pp_proof_expr right)

let display_ty_of_binding ty = function
  | PlainBinding -> pp_ty ty
  | AttachedProofBinding proof ->
    Printf.sprintf "%s ::: %s" (pp_ty ty) (pp_proof_expr proof)
  | FactProofBinding proof ->
    Printf.sprintf "Fact (%s)" (pp_proof_expr proof)

let record_local_binding ?hover_note ctx name loc ty meta =
  let ty = apply !(ctx.subst) ty in
  let display_ty = display_ty_of_binding ty meta in
  ctx.local_bindings := { name; loc; ty; display_ty; hover_note } :: !(ctx.local_bindings)

let record_expr_type ctx loc ty =
  let ty = apply !(ctx.subst) ty in
  let display_ty = pp_ty ty in
  ctx.expr_types := { loc; ty; display_ty } :: !(ctx.expr_types)

(* Like record_expr_type but includes proof annotation in the display type. *)
let record_expr_type_with_meta ctx loc ty meta =
  let ty = apply !(ctx.subst) ty in
  let display_ty = display_ty_of_binding ty meta in
  ctx.expr_types := { loc; ty; display_ty } :: !(ctx.expr_types)

type expectation_role =
  | ReturnBody of string
  | CallArgument of string option * int
  | ConstructorArgument of string * int
  | RecordField of string * string
  | IfCondition
  | ListElement
  | TupleElement of int
  | LetBinding of string
  | FailMessage

type expectation_frame = {
  ty : ty;
  reason : string;
  role : expectation_role;
  origin : Location.loc option;
}

type expectation = expectation_frame list

let mk_expectation ?origin ~role ~reason ty =
  [{ ty; reason; role; origin }]

let push_expectation ?origin ~role ~reason ty expectation =
  { ty; reason; role; origin } :: expectation

let current_expectation = function
  | frame :: _ -> frame
  | [] -> failwith "empty expectation stack"

let expected_ty_of expectation =
  (current_expectation expectation).ty

let expectation_role_label = function
  | ReturnBody fn_name -> Printf.sprintf "return body of `%s`" fn_name
  | CallArgument (Some name, index) -> Printf.sprintf "argument %d to `%s`" index name
  | CallArgument (None, index) -> Printf.sprintf "argument %d" index
  | ConstructorArgument (name, index) -> Printf.sprintf "argument %d of constructor `%s`" index name
  | RecordField (type_name, field_name) -> Printf.sprintf "field `%s` of `%s`" field_name type_name
  | IfCondition -> "if condition"
  | ListElement -> "list element"
  | TupleElement index -> Printf.sprintf "tuple element %d" index
  | LetBinding name -> Printf.sprintf "let binding `%s`" name
  | FailMessage -> "`fail` message"

let expectation_frame_message (frame : expectation_frame) =
  let origin_hint =
    match frame.origin with
    | Some loc -> Printf.sprintf " (introduced at line %d)" (loc.start.line + 1)
    | None -> ""
  in
  Printf.sprintf "- %s expects %s because %s%s"
    (expectation_role_label frame.role)
    (pp_ty frame.ty)
    frame.reason
    origin_hint

let is_fact_ty = function
  | TApp (TCon "Fact", _) | TCon "Fact" -> true
  | _ -> false

let is_posix_ty = function TCon "PosixMillis" -> true | _ -> false

let type_mismatch_message actual expected note expectation =
  let fact_hint =
    if (is_fact_ty actual && not (is_fact_ty expected))
       || (is_fact_ty expected && not (is_fact_ty actual))
    then " (hint: use `detachFact value` to extract a Fact from a value-with-proof)"
    else ""
  in
  let posix_hint =
    if is_posix_ty actual || is_posix_ty expected
    then " (hint: PosixMillis values cannot be used in arithmetic; \
use `diffMs t1 t2` to get a duration in ms, `addMs t offset` to advance a timestamp, \
or `subtractMs t offset` to go back in time)"
    else ""
  in
  let reason_hint =
    match expectation with
    | Some frames ->
      let reason = (current_expectation frames).reason in
      if reason <> "" then Printf.sprintf " (because %s)" reason else ""
    | None -> ""
  in
  let chain_hint =
    match expectation with
    | Some (_ :: outer) when outer <> [] ->
      "
Expectation chain:
" ^ String.concat "
" (List.map expectation_frame_message outer)
    | _ -> ""
  in
  Printf.sprintf "cannot unify %s with %s%s%s%s%s%s"
    (pp_ty actual) (pp_ty expected)
    (if note = "" then "" else Printf.sprintf " (%s)" note)
    fact_hint
    posix_hint
    reason_hint
    chain_hint

let add_type_mismatch ctx loc actual expected note expectation =
  let actual' = apply !(ctx.subst) actual in
  let expected' = apply !(ctx.subst) expected in
  add_error ctx loc (type_mismatch_message actual' expected' note expectation)

let unify_at ctx loc t1 t2 =
  try
    ctx.subst := unify (current_subst ctx) t1 t2
  with TypeMismatch (a, b, note) ->
    add_type_mismatch ctx loc a b note None

let unify_expected_at ctx loc actual expected =
  let expected_ty = expected_ty_of expected in
  try
    ctx.subst := unify (current_subst ctx) actual expected_ty
  with TypeMismatch (a, b, note) ->
    add_type_mismatch ctx loc a b note (Some expected)

(* ── Lookup in context ────────────────────────────────────────────────────── *)

let lookup_name ctx name =
  match env_lookup name ctx.env with
  | Some sch -> Some (instantiate sch)
  | None     -> None

let lookup_field ctx record_ty field_name =
  let record_ty = apply !(ctx.subst) record_ty in
  match record_ty with
  | TCon type_name | TApp (TCon type_name, _) ->
    (match List.assoc_opt type_name ctx.records with
     | Some rd ->
       (match List.assoc_opt field_name rd.rd_fields with
        | Some fty -> Some fty
        | None     -> None)
     | None -> None)
  | _ -> None

(* ── Build typing environment from AST declarations ─────────────────────── *)

(* First-Class Units: a quantity ALIAS type name (Length/Speed/Area/…)
   normalizes to its dimension-canonical TCon, so `Speed` in an annotation and
   the result of `Length.meters 1.0 / Duration.seconds 1.0` are the SAME type
   (structural over the dimension, NOT nominal per alias).  ACTIVE-gated:
   aliases resolve only when the module imports them from Tesl.Units (the
   names are common words — `type Speed = Slow | Fast` in a module that does
   not import Tesl.Units must keep meaning the user's ADT); the checker
   activates them per module in [activate_units_aliases_for]. *)
let resolve_quantity_alias (name : string) : ty option =
  match Units_catalog.active_dim_of_alias name with
  | Some d -> Some (t_quantity d)
  | None -> None

(* Fail-closed name-collision guard: a module that IMPORTS the units/money
   surface cannot also declare types/constructors that collide with it —
   silent hijack in either direction is the bug class this feature exists to
   kill.  A module that does NOT import them keeps full freedom (`type Speed
   = Slow | Fast` stays the user's ADT). *)
let check_units_name_collisions (m : module_form) : type_error list =
  let imports_units =
    List.exists (fun (i : import_decl) -> i.module_name = "Tesl.Units") m.imports in
  let imports_money =
    List.exists (fun (i : import_decl) -> i.module_name = "Tesl.Money") m.imports in
  if not (imports_units || imports_money) then []
  else
    List.concat_map (fun decl ->
        match decl with
        | DType tf ->
          let (name, loc) = match tf with
            | TypeNewtype { name; loc; _ } | TypeAlias { name; loc; _ }
            | TypeAdt { name; loc; _ } -> (name, loc) in
          let alias_clash =
            imports_units && List.mem_assoc name Units_catalog.aliases in
          let money_clash =
            imports_money
            && List.mem name ["Money"; "Currency"; "ExchangeRate"] in
          let ctor_clashes =
            match tf with
            | TypeAdt { variants; _ } when imports_money ->
              List.filter_map (fun (v : adt_variant) ->
                  if Currencies.iso_of_ctor v.ctor <> None then
                    Some { loc = v.loc;
                           message = Printf.sprintf
                             "constructor `%s` collides with the `%s` Currency \
                              constructor exported by Tesl.Money (imported by \
                              this module); rename the constructor"
                             v.ctor v.ctor;
                           fix = None }
                  else None)
                variants
            | _ -> []
          in
          (if alias_clash then
             [{ loc;
                message = Printf.sprintf
                  "type `%s` collides with the `%s` quantity type exported by \
                   Tesl.Units (imported by this module); rename the type"
                  name name;
                fix = None }]
           else if money_clash then
             [{ loc;
                message = Printf.sprintf
                  "type `%s` collides with the `%s` type exported by \
                   Tesl.Money (imported by this module); rename the type"
                  name name;
                fix = None }]
           else [])
          @ ctor_clashes
        | _ -> [])
      m.decls

(* Compute + set the module's active quantity aliases: the alias TYPE names
   this module imports from Tesl.Units (exposing list, or all of them for a
   bare/ImportAll import).  Returns the previous active set so nested module
   checks can restore it. *)
let activate_units_aliases_for (m : module_form) : string list =
  let prev = Units_catalog.snapshot_active_aliases () in
  let active =
    List.concat_map (fun (imp : import_decl) ->
        if imp.module_name <> "Tesl.Units" then []
        else match imp.names with
          | ImportAll -> List.map fst Units_catalog.aliases
          | ImportExposing names ->
            List.filter (fun n -> List.mem_assoc n Units_catalog.aliases) names)
      m.imports
  in
  Units_catalog.set_active_aliases active;
  prev

(** Tesl type expression → OCaml ty *)
let rec ty_of_type_expr (te : type_expr) : ty =
  match te with
  | TName { name; _ } ->
    (match name with
     | "Int" | "Integer" -> t_int
     | "String"          -> t_string
     | "Bool"            -> t_bool
     | "Float" | "Real"  -> t_float
     | "Unit"            -> t_unit
     | "PosixMillis"     -> t_posix
     | other ->
       (match resolve_quantity_alias other with
        | Some q -> q
        | None -> TCon other))
  | TVar { name; _ }     -> TCon name   (* treat named tyvars as abstract *)
  | TApp { head = TName { name = "Fact"; _ }; _ } -> t_fact
  | TApp { head; arg; _ }-> TApp (ty_of_type_expr head, ty_of_type_expr arg)
  | TFun { dom; cod; _ } -> TFun (ty_of_type_expr dom, ty_of_type_expr cod)
  | TTuple { elems; loc = _ } ->
    (match List.map ty_of_type_expr elems with
     | [a; b] -> t_tuple2 a b
     | [a; b; c] -> t_tuple3 a b c
     | elems ->
       let n = List.length elems in
       let msg = if n = 0 then "empty tuple type is not supported"
                 else if n = 1 then "1-element tuple type is not supported; use the type directly"
                 else Printf.sprintf "%d-element tuple type is not supported; only Tuple2 and Tuple3 are available" n
       in
       failwith msg)

(** Like ty_of_type_expr but substitutes named type variables using params_map.
    params_map: (param_name, rigid_var_id) list *)
let ty_of_type_expr_with_params (params_map : (string * int) list) (te : type_expr) : ty =
  let rec go te = match te with
    | TName { name; _ } ->
      (match name with
       | "Int" | "Integer" -> t_int
       | "String"          -> t_string
       | "Bool"            -> t_bool
       | "Float" | "Real"  -> t_float
       | "Unit"            -> t_unit
       | "PosixMillis"     -> t_posix
       | other ->
         (match resolve_quantity_alias other with
          | Some q -> q
          | None -> TCon other))
    | TVar { name; _ } ->
      (match List.assoc_opt name params_map with
       | Some id -> TVar id
       | None    -> TCon name)
    | TApp { head = TName { name = "Fact"; _ }; _ } -> t_fact
    | TApp { head; arg; _ } -> TApp (go head, go arg)
    | TFun { dom; cod; _ } -> TFun (go dom, go cod)
    | TTuple { elems; _ }  ->
      (match List.map go elems with
       | [a; b] -> t_tuple2 a b
       | [a; b; c] -> t_tuple3 a b c
       | _ -> TCon "Unit")
  in
  go te

(** Build a record definition from a RecordForm. *)
let build_record_def (r : record_form) : record_def = {
  rd_name   = r.name;
  rd_fields = List.map (fun (f : field_def) -> (f.name, ty_of_type_expr f.type_expr)) r.fields;
}

(** Build ADT constructor types from an ADT declaration. *)
let build_adt_def (name : string) (params : string list) (variants : adt_variant list) : adt_def =
  let rigid_ids = List.init (List.length params) (fun i -> -(i + 1)) in
  let params_map = List.combine params rigid_ids in
  {
    ad_name     = name;
    ad_params   = params;
    ad_variants = List.map (fun (v : adt_variant) ->
      (v.ctor, List.map (fun (f : field_def) -> (f.name, ty_of_type_expr_with_params params_map f.type_expr)) v.fields)
    ) variants;
  }

(** Add all type definitions from a module to the context. *)
let collect_type_defs ctx (decls : top_decl list) : ctx =
  (* Built-in `Agent` record: an agent is constructed with the normal typed-record
     constructor `Agent { provider, systemPrompt, maxTokens, tools }`, used both as a
     top-level `agent X = Agent { … }` block and as a plain expression (e.g. building
     a per-request BYOK agent in a function). Registering its fields here lets the
     standard record-construction type-checking validate it. *)
  let agent_record = {
    rd_name = "Agent";
    rd_fields = [
      ("provider", TCon "LlmProvider");
      ("systemPrompt", TCon "String");
      ("maxTokens", TCon "Int");
      ("tools", TApp (TCon "List", TCon "Tool"));
    ];
  } in
  let ctx = { ctx with records = ("Agent", agent_record) :: ctx.records } in
  List.fold_left (fun ctx decl ->
    match decl with
    | DRecord r ->
      let rd = build_record_def r in
      { ctx with records = (r.name, rd) :: ctx.records }
    | DEntity e ->
      let rd = {
        rd_name = e.name;
        rd_fields = List.map (fun (f : field_def) ->
          (f.name, ty_of_type_expr f.type_expr)) e.fields;
      } in
      { ctx with records = (e.name, rd) :: ctx.records }
    | DType (TypeAdt { name; params; variants; _ }) ->
      let ad = build_adt_def name params variants in
      (* Build rigid var IDs for type parameters *)
      let rigid_ids = List.init (List.length params) (fun i -> -(i + 1)) in
      let params_map = List.combine params rigid_ids in
      (* Result type: Either a b → TApp (TApp (TCon "Either") (TVar -1)) (TVar -2) *)
      let result_ty = List.fold_left (fun acc (_, id) -> TApp (acc, TVar id))
        (TCon name) params_map in
      let new_ctors = List.map (fun (v : adt_variant) ->
        let field_tys = List.map (fun (f : field_def) ->
          ty_of_type_expr_with_params params_map f.type_expr) v.fields in
        let ctor_mono = List.fold_right (fun ft acc -> TFun (ft, acc)) field_tys result_ty in
        let ctor_sch = { vars = rigid_ids; mono = ctor_mono } in
        (v.ctor, (name, ctor_sch))
      ) variants in
      { ctx with
        adts = (name, ad) :: ctx.adts;
        ctors = new_ctors @ ctx.ctors }
    | DType (TypeNewtype { name; base_type; _ }) ->
      (* Newtype: wrap type + accessor scheme *)
      let base = ty_of_type_expr base_type in
      let ctor_ty  = TFun (base, TCon name) in
      let ctor_sch = mono ctor_ty in
      { ctx with
        ctors = (name, (name, ctor_sch)) :: ctx.ctors;
        type_aliases = (name, base) :: ctx.type_aliases }
    | DType (TypeAlias { name; base_type; _ }) ->
      (* Transparent alias — record its base so Eq/Ord resolution can chase it. *)
      { ctx with type_aliases = (name, ty_of_type_expr base_type) :: ctx.type_aliases }
    | DCodec cf ->
      (* Register the target type as decodable iff it has a non-forbidden
         fromJson codec; this drives the decide-by-resolution check for
         `decodeAs` (we consult the resolved type's codec, never the string). *)
      (match cf.from_json with
       | FromJsonForbidden -> ctx
       | FromJsonAlts _ | FromJsonAdt ->
         { ctx with codec_decode_types = cf.type_name :: ctx.codec_decode_types })
    | _ -> ctx
  ) ctx decls

let rec ret_spec_type = function
  | RetPlain { ty; _ } -> ty_of_type_expr ty
  | RetAttached { binding = b; _ } -> ty_of_type_expr b.type_expr
  | RetNamedPack { ty; _ } -> ty_of_type_expr ty
  | RetForAll { elem_ty; _ } -> t_list (ty_of_type_expr elem_ty)
  | RetMaybeForAll { elem_ty; _ } -> t_maybe (t_list (ty_of_type_expr elem_ty))
  | RetSetForAll { elem_ty; _ } -> t_set (ty_of_type_expr elem_ty)
  | RetMaybeSetForAll { elem_ty; _ } -> t_maybe (t_set (ty_of_type_expr elem_ty))
  | RetForAllDictValues { key_ty; val_ty; _ } -> t_dict (ty_of_type_expr key_ty) (ty_of_type_expr val_ty)
  | RetForAllDictKeys   { key_ty; val_ty; _ } -> t_dict (ty_of_type_expr key_ty) (ty_of_type_expr val_ty)
  | RetMaybeAttached { outer_ty = Some ty; _ } -> ty_of_type_expr ty
  | RetMaybeAttached { binding = b; _ } -> t_maybe (ty_of_type_expr b.type_expr)
  | RetExists { body; _ } -> ret_spec_type body

(** Collect all type-variable names (TVar) appearing in a type expression. *)
let rec collect_tvar_names (te : type_expr) : string list =
  match te with
  | TVar { name; _ } -> [name]
  | TName _ -> []
  | TApp { head; arg; _ } -> collect_tvar_names head @ collect_tvar_names arg
  | TFun { dom; cod; _ } -> collect_tvar_names dom @ collect_tvar_names cod
  | TTuple { elems; _ } -> List.concat_map collect_tvar_names elems

(** Collect type-variable names from a return spec. *)
let rec collect_ret_spec_tvar_names = function
  | RetPlain { ty; _ } -> collect_tvar_names ty
  | RetAttached { binding = b; _ } -> collect_tvar_names b.type_expr
  | RetNamedPack { ty; _ } -> collect_tvar_names ty
  | RetForAll { elem_ty; _ } | RetMaybeForAll { elem_ty; _ }
  | RetSetForAll { elem_ty; _ } | RetMaybeSetForAll { elem_ty; _ } -> collect_tvar_names elem_ty
  | RetForAllDictValues { key_ty; val_ty; _ }
  | RetForAllDictKeys   { key_ty; val_ty; _ } -> collect_tvar_names key_ty @ collect_tvar_names val_ty
  | RetMaybeAttached { outer_ty = Some ty; _ } -> collect_tvar_names ty
  | RetMaybeAttached { binding = b; _ } -> collect_tvar_names b.type_expr
  | RetExists { body; _ } -> collect_ret_spec_tvar_names body

(** Like ret_spec_type but substitutes named type variables using params_map. *)
let rec ret_spec_type_with_params params_map = function
  | RetPlain { ty; _ } -> ty_of_type_expr_with_params params_map ty
  | RetAttached { binding = b; _ } -> ty_of_type_expr_with_params params_map b.type_expr
  | RetNamedPack { ty; _ } -> ty_of_type_expr_with_params params_map ty
  | RetForAll { elem_ty; _ } -> t_list (ty_of_type_expr_with_params params_map elem_ty)
  | RetMaybeForAll { elem_ty; _ } -> t_maybe (t_list (ty_of_type_expr_with_params params_map elem_ty))
  | RetSetForAll { elem_ty; _ } -> t_set (ty_of_type_expr_with_params params_map elem_ty)
  | RetMaybeSetForAll { elem_ty; _ } -> t_maybe (t_set (ty_of_type_expr_with_params params_map elem_ty))
  | RetForAllDictValues { key_ty; val_ty; _ } ->
    t_dict (ty_of_type_expr_with_params params_map key_ty) (ty_of_type_expr_with_params params_map val_ty)
  | RetForAllDictKeys   { key_ty; val_ty; _ } ->
    t_dict (ty_of_type_expr_with_params params_map key_ty) (ty_of_type_expr_with_params params_map val_ty)
  | RetMaybeAttached { outer_ty = Some ty; _ } -> ty_of_type_expr_with_params params_map ty
  | RetMaybeAttached { binding = b; _ } -> t_maybe (ty_of_type_expr_with_params params_map b.type_expr)
  | RetExists { body; _ } -> ret_spec_type_with_params params_map body

(** Get the type of a function declaration's signature (for the environment).
    If the signature contains type variables (lowercase names like a, b),
    builds a polymorphic scheme with quantified rigid variables. *)
let decl_scheme (fd : func_decl) : scheme =
  (* Collect all type variable names from params and return type *)
  let param_tvars = List.concat_map (fun (b : binding) -> collect_tvar_names b.type_expr) fd.params in
  let ret_tvars = collect_ret_spec_tvar_names fd.return_spec in
  let all_tvars = List.sort_uniq String.compare (param_tvars @ ret_tvars) in
  if all_tvars = [] then begin
    (* No type variables — monomorphic as before *)
    let param_types = List.map (fun (b : binding) -> ty_of_type_expr b.type_expr) fd.params in
    let ret_type = match fd.return_spec with
      | RetPlain { ty; _ }         -> ty_of_type_expr ty
      | RetAttached { binding = b; _ } -> ty_of_type_expr b.type_expr
      | RetNamedPack { ty; _ }     -> ty_of_type_expr ty
      | RetForAll { elem_ty; _ }   -> t_list (ty_of_type_expr elem_ty)
      | RetMaybeForAll { elem_ty; _ } -> t_maybe (t_list (ty_of_type_expr elem_ty))
      | RetSetForAll { elem_ty; _ } -> t_set (ty_of_type_expr elem_ty)
      | RetMaybeSetForAll { elem_ty; _ } -> t_maybe (t_set (ty_of_type_expr elem_ty))
      | RetForAllDictValues { key_ty; val_ty; _ } -> t_dict (ty_of_type_expr key_ty) (ty_of_type_expr val_ty)
      | RetForAllDictKeys   { key_ty; val_ty; _ } -> t_dict (ty_of_type_expr key_ty) (ty_of_type_expr val_ty)
      | RetMaybeAttached { outer_ty = Some ty; _ } -> ty_of_type_expr ty
      | RetMaybeAttached { binding = b; _ } -> t_maybe (ty_of_type_expr b.type_expr)
      | RetExists { body; _ } -> ret_spec_type body
    in
    mono (t_fun param_types ret_type)
  end else begin
    (* Polymorphic: assign rigid var IDs to each type variable *)
    let rigid_ids = List.init (List.length all_tvars) (fun i -> -(i + 1)) in
    let params_map = List.combine all_tvars rigid_ids in
    let param_types = List.map (fun (b : binding) -> ty_of_type_expr_with_params params_map b.type_expr) fd.params in
    let ret_type = ret_spec_type_with_params params_map fd.return_spec in
    { vars = rigid_ids; mono = t_fun param_types ret_type }
  end

(* Apply the entity-append rule: wrap bare [PredApp p []] with [PredApp p ["_entity"]]
   so the caller's let binder can rename [_entity] to their chosen name. *)
let rec expand_entity_proof_group (p : proof_expr) : proof_expr =
  match p with
  | PredApp { pred; args = []; loc } -> PredApp { pred; args = ["_entity"]; loc }
  | PredApp _ -> p
  | PredAnd { left; right; loc } ->
    PredAnd {
      left  = expand_entity_proof_group left;
      right = expand_entity_proof_group right;
      loc;
    }

let function_proof_return_of_decl (fd : func_decl) : function_proof_return option =
  match fd.return_spec with
  | RetAttached { binding = { name = binder_name; proof_ann = Some proof; _ }; _ } ->
    Some (ReturnsAttachedProof { binder_name; proof })
  | RetMaybeAttached { binding = { name = binder_name; proof_ann = Some proof; _ }; _ } ->
    Some (ReturnsAttachedProof { binder_name; proof })
  | RetNamedPack { entity_proof = Some ep; other_proof; _ } ->
    (* `Type ? P && Q` — the entity-append rule makes P, Q be about `_entity`,
       which gets renamed to the caller's binder by rename_binding_meta.
       If there's a sidecar (`::: Positive m`), append it too; the `m` is a
       function parameter name, left as-is (not call-site substituted here —
       hover information is approximate for sidecars). *)
    let entity = expand_entity_proof_group ep in
    let combined = match other_proof with
      | Some op ->
        let loc = (match entity with PredApp x -> x.loc | PredAnd x -> x.loc) in
        PredAnd { left = entity; right = op; loc }
      | None -> entity
    in
    Some (ReturnsAttachedProof { binder_name = "_entity"; proof = combined })
  | _ -> None

let collect_proof_returns (decls : top_decl list) : (string * function_proof_return) list =
  List.filter_map (function
    | DFunc fd ->
      Option.map (fun proof_return -> (fd.name, proof_return))
        (function_proof_return_of_decl fd)
    | _ -> None
  ) decls

let collect_func_kinds (decls : top_decl list) : (string * func_kind) list =
  List.filter_map (function
    | DFunc fd -> Some (fd.name, fd.kind)
    | _ -> None
  ) decls

(* Review item 3: one canonical resolver in Validation_common (was a copy). *)
let module_name_to_kebab = Validation_common.module_name_to_kebab

(* ── Lifted-stdlib source resolution (type source of truth) ───────────────────
   A small subset of the [Tesl.*] standard library has its TYPES lifted out of
   the hardcoded [stdlib_env] (type_system.ml) and into bundled `.tesl` sources
   under the repo's `tesl/` directory.  [load_imported_func_sigs] reads those
   signatures from source instead of short-circuiting to [stdlib_env].

   RUNTIME emission is unaffected: the emitter still maps each lifted module to
   its existing `tesl/<mod>.rkt` runtime via its own collection-path table.  This
   resolver only locates the `.tesl` *type* source, never a runtime require, and
   it is NOT [resolve_local_import_path] (which resolves relative to the user's
   importing file — it would never find the bundled stdlib). *)

(** Repo root: honor [TESL_REPO_ROOT], else walk up from the running executable
    looking for a directory that contains a `compiler/` sibling.  Mirrors
    [Compile.default_root_path] (which the checker, a lower layer, cannot call). *)
let stdlib_repo_root () =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name
        else find parent
    in
    find (Filename.dirname Sys.executable_name)

(** Map a lifted [Tesl.X] module name to its bundled `.tesl` TYPE source's
    kebab basename, e.g. [Tesl.List] -> [Some "list.tesl"].  Only modules whose
    types have actually been lifted return [Some]; every other [Tesl.*] returns
    [None] so callers fall back to [stdlib_env]. *)
let lifted_stdlib_basename (module_name : string) : string option =
  match module_name with
  | "Tesl.List" -> Some "list.tesl"
  | "Tesl.ListPrim" -> Some "list-prim.tesl"
  | "Tesl.Either" -> Some "either.tesl"
  | _ -> None

(** Resolve a lifted [Tesl.X] module to its bundled `.tesl` TYPE source path.
    Returns [None] when the module is not lifted OR the source cannot be located
    (graceful: the import then contributes no rows).  Looked up under the repo's
    `tesl/` dir, with the installed-distribution collections layout
    (`share/tesl-collections/tesl/tesl/`) as a fallback so an installed binary —
    whose `tesl/` sources ship via the same path as the `.rkt` runtime — also
    finds them.  This NEVER points at a runtime require; emission is unaffected. *)
let lifted_stdlib_source_path (module_name : string) : string option =
  match lifted_stdlib_basename module_name with
  | None -> None
  | Some base ->
    let root = stdlib_repo_root () in
    let candidates = [
      Filename.concat root (Filename.concat "tesl" base);
      (* Installed distribution: cp -r tesl share/tesl-collections/tesl/tesl *)
      Filename.concat root
        (Filename.concat "share"
           (Filename.concat "tesl-collections"
              (Filename.concat "tesl" (Filename.concat "tesl" base))));
    ] in
    List.find_opt Sys.file_exists candidates

let resolve_local_import_path = Validation_common.resolve_local_import_path

(* ── Imported-module parse cache (WS4: batch / per-file amortization) ──────
   A single [check_module_*] run reads + re-parses each locally-imported
   `.tesl` file once per consumer site — [load_imported_func_kinds],
   [load_imported_func_sigs], [load_imported_ctors], [check_local_import_names]
   and [check_type_names_in_scope] each independently open and parse the same
   path.  That is ~5 redundant parses of every imported file *within one file
   check*, and in a whole-project / batch run the same shared module is
   re-parsed by every file that imports it.

   This cache memoizes the read+parse by resolved path.  The compiler is a
   one-shot process and never mutates source files mid-run, so caching by path
   is sound: a given path always parses to the same result.  The cache is
   purely a performance optimization — every call site behaves exactly as
   before (same [Parser.result], same handling of a missing file), so emitted
   output and diagnostics are byte-identical.

   [clear_import_parse_cache] is exposed for tests / long-lived hosts that may
   want a fresh slate; the normal CLI never needs to call it. *)
let import_parse_cache : (string, module_form Parser.result option) Hashtbl.t =
  Hashtbl.create 32

let clear_import_parse_cache () = Hashtbl.reset import_parse_cache

(** Read + parse a locally-imported module at [path], memoized by path.
    Returns [None] if the file does not exist (so callers can keep their
    existing "skip missing import" behavior), otherwise [Some result] where
    [result] is the parse outcome ([Ok]/[Err]) exactly as
    [Parser.parse_module] would return it for a fresh read. *)
let parse_local_import_module (path : string) : module_form Parser.result option =
  match Hashtbl.find_opt import_parse_cache path with
  | Some cached -> cached
  | None ->
    let result =
      if not (Sys.file_exists path) then None
      else
        let source = In_channel.with_open_text path In_channel.input_all in
        Some (Parser.parse_module path source)
    in
    Hashtbl.replace import_parse_cache path result;
    result

let load_imported_func_kinds (m : module_form) : (string * func_kind) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then []
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      match parse_local_import_module path with
      | None | Some (Err _) -> []
      | Some (Ok imported) ->
          let requested = match imp.names with
            | ImportAll -> None
            | ImportExposing names -> Some names
          in
          List.concat_map (function
            | DFunc fd ->
              let qualified_name = imp.module_name ^ "." ^ fd.name in
              let include_plain = match requested with
                | Some names -> List.mem fd.name names
                | None -> false
              in
              let include_qualified = match requested with
                | Some names -> List.mem fd.name names
                | None -> true
              in
              (if include_plain then [ (fd.name, fd.kind) ] else [])
              @ (if include_qualified then [ (qualified_name, fd.kind) ] else [])
            | _ -> []
          ) imported.decls
  ) m.imports

let load_imported_func_sigs (m : module_form) : (string * scheme) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  (** Qualify local type names that are NOT explicitly imported with the module name.
      E.g. `Widget` from B becomes `B.Widget` only when Widget is NOT directly imported.
      This enables `fn f(w: B.Widget)` to match `makeB`'s return type. *)
  let qualify_ty mod_name local_type_names explicitly_imported =
    let should_qualify n =
      List.mem n local_type_names && not (List.mem n explicitly_imported)
    in
    let rec go = function
      | TCon n when should_qualify n -> TCon (mod_name ^ "." ^ n)
      | TApp (f, a) -> TApp (go f, go a)
      | TFun (a, b) -> TFun (go a, go b)
      | other -> other
    in
    go
  in
  (* Load the lifted-stdlib TYPE signatures for a module whose types now come
     from a bundled `.tesl` source instead of [stdlib_env] (the "type source of
     truth" path).  The bundled module declares functions under their bare name
     (e.g. `fn map`), but the type environment keys them by the stdlib's dotted
     convention (`List.map`), which is also exactly how the user exposes them
     (`import Tesl.List exposing [List.map]`).  So the env key and the requested
     name are both `<ShortMod>.<fn>` (e.g. `List.map`), where `<ShortMod>` is the
     trailing segment of the [Tesl.X] module name.  Returns [] when the source is
     absent / unparsable (only reachable in an unsupported config — no repo root
     and no installed `tesl/` collection; the harness always sets the env var and
     the distribution ships `tesl/list.tesl`); the lifted rows are gone from
     [stdlib_env], so a genuinely missing source would surface as unbound names
     rather than silently mistyping. *)
  let load_lifted_sigs (imp : import_decl) (path : string) : (string * scheme) list =
    match parse_local_import_module path with
    | None | Some (Err _) -> []
    | Some (Ok imported) ->
        (* `Tesl.List` -> `List`; the env/exposing key prefix. *)
        let short_mod =
          match String.rindex_opt imp.module_name '.' with
          | Some i -> String.sub imp.module_name (i + 1)
                        (String.length imp.module_name - i - 1)
          | None -> imp.module_name
        in
        let strip_dotdot s =
          let n = String.length s in
          if n > 4 && String.sub s (n-4) 4 = "(..)" then String.sub s 0 (n-4) else s
        in
        let requested = match imp.names with
          | ImportAll -> None
          | ImportExposing names -> Some (List.map strip_dotdot names)
        in
        List.concat_map (function
          | DFunc fd ->
            let dotted = short_mod ^ "." ^ fd.name in   (* e.g. "List.map" *)
            let sch = decl_scheme fd in
            let include_it = match requested with
              | Some names -> List.mem dotted names
              | None -> true
            in
            if include_it then [ (dotted, sch) ] else []
          | _ -> []
        ) imported.decls
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then
      (match lifted_stdlib_source_path imp.module_name with
       | Some path -> load_lifted_sigs imp path
       | None -> [])
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      match parse_local_import_module path with
      | None | Some (Err _) -> []
      | Some (Ok imported) ->
          (* Collect locally-defined type names from the imported module *)
          let local_types = List.concat_map (function
            | DType (TypeAdt { name; _ }) | DType (TypeNewtype { name; _ })
            | DType (TypeAlias { name; _ }) | DRecord { name; _ } -> [name]
            | _ -> []
          ) imported.decls in
          let strip_dotdot s =
            let n = String.length s in
            if n > 4 && String.sub s (n-4) 4 = "(..)" then String.sub s 0 (n-4) else s
          in
          let requested = match imp.names with
            | ImportAll -> None
            | ImportExposing names -> Some (List.map strip_dotdot names)
          in
          let explicitly_imported = match requested with
            | None -> []
            | Some names -> names
          in
          let qualify = qualify_ty imp.module_name local_types explicitly_imported in
          List.concat_map (function
            | DFunc fd ->
              let qualified_name = imp.module_name ^ "." ^ fd.name in
              let sch = decl_scheme fd in
              (* Qualify the scheme's type so local types appear as Module.Type *)
              let q_sch = { sch with mono = qualify sch.mono } in
              let include_plain = match requested with
                | Some names -> List.mem fd.name names
                | None -> false
              in
              let include_qualified = match requested with
                | Some names -> List.mem fd.name names
                | None -> true
              in
              (if include_plain then [ (fd.name, q_sch) ] else [])
              @ (if include_qualified then [ (qualified_name, q_sch) ] else [])
            | DConst c ->
              (* #34: bind exported constants across the module boundary.  The
                 emitted Racket already `provide`s them; only the checker's
                 import env was missing the binding, so `import Lib exposing
                 [kMax]` type-checked the export but left every use unbound. *)
              (match shallow_const_ty c.value with
               | None -> []
               | Some ty ->
                 let sch = mono ty in
                 let qualified_name = imp.module_name ^ "." ^ c.name in
                 let include_plain = match requested with
                   | Some names -> List.mem c.name names
                   | None -> false
                 in
                 let include_qualified = match requested with
                   | Some names -> List.mem c.name names
                   | None -> true
                 in
                 (if include_plain then [ (c.name, sch) ] else [])
                 @ (if include_qualified then [ (qualified_name, sch) ] else []))
            | _ -> []
          ) imported.decls
  ) m.imports

let exported_ctor_entries (m : module_form) : (string * string * scheme) list =
  (* ExportAdt exposes constructors; ExportName is opaque for ADTs.
     For newtypes, the constructor is always exported (it's the only one). *)
  let exported_adt_names =
    List.fold_left (fun acc -> function
      | ExportAdt name -> name :: acc
      | ExportName _ -> acc
    ) [] m.exports
  in
  let exported_all_names =
    List.fold_left (fun acc -> function
      | ExportAdt name | ExportName name -> name :: acc
    ) [] m.exports
  in
  let is_exported_adt name = List.mem name exported_adt_names in
  let is_exported name = List.mem name exported_all_names in
  List.concat_map (function
    | DType (TypeAdt { name; params; variants; _ }) when is_exported_adt name ->
      let rigid_ids = List.init (List.length params) (fun i -> -(i + 1)) in
      let params_map = List.combine params rigid_ids in
      let result_ty = List.fold_left (fun acc (_, id) -> TApp (acc, TVar id))
        (TCon name) params_map in
      List.map (fun (v : adt_variant) ->
        let field_tys = List.map (fun (f : field_def) ->
          ty_of_type_expr_with_params params_map f.type_expr) v.fields in
        let ctor_mono = List.fold_right (fun ft acc -> TFun (ft, acc)) field_tys result_ty in
        let ctor_sch = { vars = rigid_ids; mono = ctor_mono } in
        (name, v.ctor, ctor_sch)
      ) variants
    | DType (TypeNewtype { name; base_type; _ }) when is_exported name ->
      (* Newtypes always export their constructor, regardless of ExportAdt vs ExportName *)
      let base = ty_of_type_expr base_type in
      [ (name, name, mono (TFun (base, TCon name))) ]
    | _ -> []
  ) m.decls

let load_imported_ctors (m : module_form) : (string * (string * scheme)) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then []
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      match parse_local_import_module path with
      | None | Some (Err _) -> []
      | Some (Ok imported) ->
          let requested = match imp.names with
            | ImportAll -> None
            | ImportExposing names -> Some names
          in
          List.concat_map (fun (adt_name, ctor_name, ctor_sch) ->
            let qualified_name = imp.module_name ^ "." ^ ctor_name in
            let requested_name = match requested with
              | Some names ->
                (* A constructor enters scope ONLY when named explicitly
                   (`exposing [Red]`) or via its ADT's wildcard form
                   (`exposing [Color(..)]`).  Importing the bare type name
                   (`exposing [Color]`) brings the TYPE, not its constructors —
                   otherwise unimported constructors leak into scope (soundness). *)
                List.mem ctor_name names || List.mem (adt_name ^ "(..)") names
              | None -> false
            in
            let include_plain = requested_name in
            let include_qualified = match requested with
              | Some _ -> requested_name
              | None -> true
            in
            (if include_plain then [ (ctor_name, (adt_name, ctor_sch)) ] else [])
            @ (if include_qualified then [ (qualified_name, (adt_name, ctor_sch)) ] else [])
          ) (exported_ctor_entries imported)
  ) m.imports

(* 2026-07-03 hole #15: load imported record/entity FIELD TYPES so dotted field
   access on an imported type (`u.email`, `w.name`) resolves to the real field
   type.  Previously imported records/entities were never entered into
   ctx.records, so lookup_field returned None and EField fell back to a fresh
   unification var — an implicit T_ANY that unified with ANYTHING, silently
   disabling structural type-checking for every `imported.field` (e.g.
   `w.name == 42` on a String field compiled clean).  Mirrors load_imported_ctors;
   only types actually brought into scope (named in `exposing`, or via a wildcard
   import) are loaded. *)
let load_imported_records (m : module_form) : (string * record_def) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then []
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      match parse_local_import_module path with
      | None | Some (Err _) -> []
      | Some (Ok imported) ->
        let wants name = match imp.names with
          | ImportAll -> true
          | ImportExposing names -> List.mem name names
        in
        (* C6 (2026-07-05 fresh review): register each imported record/entity under
           BOTH its bare name AND its module-qualified name (`Module.Type`).  A
           module-qualified type reference (`x: Sandbox3.ARecord2`, valid after any
           `import Sandbox3`) parses to `TCon "Sandbox3.ARecord2"`, but only bare
           keys existed — so qualified field access fell through to the `fresh ()`
           T_ANY wildcard, silently disabling type-checking (`w.name + 1` on a
           String field compiled clean).  The qualified key is per-module, so two
           modules that both define `ARecord2` (Sandbox2 with `foo2`, Sandbox3 with
           `foo3`) resolve to their OWN fields instead of colliding under the bare
           name.  The bare key is kept (gated on `wants`) for the exposing-import
           access style. *)
        let qualify name = imp.module_name ^ "." ^ name in
        List.concat_map (function
          | DRecord r ->
            let rd = build_record_def r in
            (qualify r.name, rd) :: (if wants r.name then [(r.name, rd)] else [])
          | DEntity e ->
            let rd =
              { rd_name = e.name;
                rd_fields =
                  List.map (fun (f : field_def) -> (f.name, ty_of_type_expr f.type_expr))
                    e.fields } in
            (qualify e.name, rd) :: (if wants e.name then [(e.name, rd)] else [])
          | _ -> []
        ) imported.decls
  ) m.imports

(* Builtin ADTs that back the typed configuration blocks.  They are seeded into
   the checker (like Maybe/Either) when the owning stdlib module is imported, so
   `connection: TcpConnection { host: ..., port: ... }` and `backoff: Exponential`
   type-check via the normal record/constructor machinery.  The surrounding
   config records (Database/Queue/…) are validated by the dedicated config
   checker rather than as generic record literals, because their entities/jobs/
   payload fields reference declared types, not ordinary values. *)
let config_stdlib_seed (m : module_form) :
    (string * adt_def) list * (string * (string * scheme)) list =
  let imported name = List.exists (fun (i : import_decl) -> i.module_name = name) m.imports in
  let adt name params variants = (name, { ad_name = name; ad_params = params; ad_variants = variants }) in
  let nullary_ctor adt_name name = (name, (adt_name, mono (TCon adt_name))) in
  let fn_ctor adt_name name arg_tys =
    (name, (adt_name, mono (List.fold_right (fun a acc -> TFun (a, acc)) arg_tys (TCon adt_name))))
  in
  let adts = ref [] and ctors = ref [] in
  if imported "Tesl.Database" then begin
    adts := adt "PostgresConnection" []
      [ ("TcpConnection", [ ("host", TCon "String"); ("port", TCon "Int") ]);
        ("SocketConnection", [ ("path", TCon "String") ]) ]
      :: adt "DatabaseBackend" []
      [ ("Postgres", [ ("config", TCon "PostgresConfig") ]); ("Memory", []) ] :: !adts;
    ctors :=
      fn_ctor "PostgresConnection" "TcpConnection" [ TCon "String"; TCon "Int" ]
      :: fn_ctor "PostgresConnection" "SocketConnection" [ TCon "String" ]
      :: fn_ctor "DatabaseBackend" "Postgres" [ TCon "PostgresConfig" ]
      :: nullary_ctor "DatabaseBackend" "Memory"
      :: !ctors
  end;
  if imported "Tesl.Queue" then begin
    adts := adt "QueueRetryBackoff" [] [ ("Exponential", []); ("Fixed", []); ("Linear", []) ] :: !adts;
    ctors :=
      nullary_ctor "QueueRetryBackoff" "Exponential"
      :: nullary_ctor "QueueRetryBackoff" "Fixed"
      :: nullary_ctor "QueueRetryBackoff" "Linear" :: !ctors
  end;
  (!adts, !ctors)

(** Add all function signatures from a module to the typing environment. *)
let collect_func_sigs ctx (decls : top_decl list) : ctx =
  List.fold_left (fun ctx decl ->
    match decl with
    | DFunc fd ->
      let sch = decl_scheme fd in
      { ctx with env = env_extend fd.name sch ctx.env }
    | DCapture c ->
      (* Capture produces the binding type *)
      let ty = ty_of_type_expr c.binding.type_expr in
      { ctx with env = env_extend c.name (mono ty) ctx.env }
    | DConst c ->
      (* We'll type-check the const body separately; for now add fresh var *)
      let ty = fresh () in
      { ctx with env = env_extend c.name (mono ty) ctx.env }
    | _ -> ctx
  ) ctx decls

(* ── Expression type inference (Algorithm W) ─────────────────────────────── *)

let expr_loc (e : expr) =
  match e with
  | ELit { loc; _ } | EVar { loc; _ } | EField { loc; _ }
  | EApp { loc; _ } | EBinop { loc; _ } | EUnop { loc; _ } | EIf { loc; _ }
  | ECase { loc; _ } | ELet { loc; _ } | ELetProof { loc; _ }
  | ERecord { loc; _ } | EList { loc; _ } | EOk { loc; _ } | EFail { loc; _ }
  | ETelemetry { loc; _ } | EEnqueue { loc; _ } | EPublish { loc; _ }
  | EStartWorkers { loc; _ } | EWithDatabase { loc; _ } | EWithCapabilities { loc; _ }
  | EWithTransaction { loc; _ } | EServe { loc; _ } | EConstructor { loc; _ } | ELambda { loc; _ }
  | ECacheGet { loc; _ } | ECacheSet { loc; _ } | ECacheDelete { loc; _ } | ECacheInvalidate { loc; _ }
  | ESendEmail { loc; _ } | EStartEmailWorker { loc; _ }
  | ERuntimeCall { loc; _ } -> loc

let rec flatten_app_expr acc = function
  | EApp { fn; arg; _ } -> flatten_app_expr (arg :: acc) fn
  | other -> (other, acc)

let is_subject_name (name : string) : bool =
  String.length name > 0 &&
  let c = name.[0] in
  ((c >= 'a' && c <= 'z') || c = '_') && not (String.contains name '.')

let rec proof_subject_names = function
  | PredApp { args; _ } -> List.filter is_subject_name args
  | PredAnd { left; right; _ } -> proof_subject_names left @ proof_subject_names right

let subject_chain_of_name chain_env name =
  match List.assoc_opt name chain_env with
  | Some chain -> chain
  | None -> [name]

let render_subject_chain chain = String.concat " ← " chain

let rec base_subject_chain_of_expr ctx (value : expr) : string list option =
  match value with
  | EVar { name; _ } -> Some (subject_chain_of_name ctx.subject_chain_env name)
  | EOk { value; _ } -> base_subject_chain_of_expr ctx value
  | EApp _ as app ->
    let base_fn, args = flatten_app_expr [] app in
    (match base_fn, args with
     | EVar { name = "check"; _ }, _check_fn :: EVar { name = subj_name; _ } :: _ ->
       Some (subject_chain_of_name ctx.subject_chain_env subj_name)
     | EVar { name = ("attachFact" | "forgetFact" | "detachFact"); _ }, value :: _ ->
       base_subject_chain_of_expr ctx value
     | _ -> None)
  | _ -> None

let binding_subject_chain ctx bound_name value =
  match base_subject_chain_of_expr ctx value with
  | Some chain when chain <> [] -> bound_name :: chain
  | _ -> [bound_name]

let hover_note_for_meta chain_env bound_name = function
  | PlainBinding ->
    let chain = subject_chain_of_name chain_env bound_name in
    if List.length chain > 1 then Some ("subject chain: " ^ render_subject_chain chain) else None
  | AttachedProofBinding proof ->
    let subjects = List.sort_uniq String.compare (proof_subject_names proof) in
    let chains = List.map (subject_chain_of_name chain_env) subjects in
    let interesting =
      List.exists (fun chain -> List.length chain > 1) chains || List.length chains > 1
    in
    if interesting then
      Some ("subjects: " ^ String.concat "; " (List.map render_subject_chain chains))
    else
      None
  | FactProofBinding proof ->
    let subjects = List.sort_uniq String.compare (proof_subject_names proof) in
    let chains = List.map (subject_chain_of_name chain_env) subjects in
    let interesting =
      List.exists (fun chain -> List.length chain > 1) chains || List.length chains > 1
    in
    if interesting then
      Some ("fact subjects: " ^ String.concat "; " (List.map render_subject_chain chains))
    else
      None

let rec flatten_check_chain_expr acc = function
  | EBinop { op = BAnd; left; right; _ } ->
    flatten_check_chain_expr (flatten_check_chain_expr acc right) left
  | other -> other :: acc

let stdlib_check_function_names = [
  "Float.requireNonZero";
  "Int.nonZero";
  "Int.nonNegative";
  "String.requireNonEmpty";
  "Dict.requireKey";
]

let is_check_function_name ctx name =
  List.mem name stdlib_check_function_names
  || match List.assoc_opt name ctx.function_kinds with
     | Some CheckKind -> true
     | _ -> false

let is_composed_check_function_expr ctx e =
  let check_fns = flatten_check_chain_expr [] e in
  List.length check_fns >= 2
  && List.for_all (function
    | EVar { name; _ } -> is_check_function_name ctx name
    | _ -> false
  ) check_fns

let rec rename_proof_name old_name new_name = function
  | PredApp { pred; args; loc } ->
    let args = List.map (fun arg -> if arg = old_name then new_name else arg) args in
    PredApp { pred; args; loc }
  | PredAnd { left; right; loc } ->
    PredAnd {
      left = rename_proof_name old_name new_name left;
      right = rename_proof_name old_name new_name right;
      loc;
    }

let rename_binding_meta old_name new_name = function
  | PlainBinding -> PlainBinding
  | AttachedProofBinding proof ->
    AttachedProofBinding (rename_proof_name old_name new_name proof)
  | FactProofBinding proof ->
    FactProofBinding (rename_proof_name old_name new_name proof)

let rec binding_meta_of_expr ctx (e : expr) : binding_meta option =
  match e with
  | EVar { name; _ } -> List.assoc_opt name ctx.binding_meta_env
  | EOk { proof; _ } -> Some (AttachedProofBinding proof)
  | EApp _ as app ->
    let base_fn, args = flatten_app_expr [] app in
    (match base_fn, args with
     | EVar { name = "detachFact"; _ }, [arg] ->
       (match binding_meta_of_expr ctx arg with
        | Some (AttachedProofBinding proof)
        | Some (FactProofBinding proof) -> Some (FactProofBinding proof)
        | Some PlainBinding | None -> None)
     | EVar { name = "attachFact"; _ }, [_value; fact] ->
       (match binding_meta_of_expr ctx fact with
        | Some (FactProofBinding proof)
        | Some (AttachedProofBinding proof) -> Some (AttachedProofBinding proof)
        | Some PlainBinding | None -> None)
     | EVar { name = "check"; _ }, fn_expr :: rest_args ->
       (* `check checkFn arg ...` — un-renamed proof from checkFn, plus subject accumulation. *)
       let proof_opt = match fn_expr with
         | EVar { name = fn_name; _ } ->
           (match List.assoc_opt fn_name ctx.proof_returns with
            | Some (ReturnsAttachedProof { proof; _ }) -> Some proof
            | None -> None)
         | _ -> None
       in
       let subj_meta = match rest_args with
         | EVar { name = subj_name; _ } :: _ -> List.assoc_opt subj_name ctx.binding_meta_env
         | _ -> None
       in
       (match proof_opt, subj_meta with
        | Some p, Some (AttachedProofBinding acc) ->
          let loc = (match p with PredApp x -> x.loc | PredAnd x -> x.loc) in
          Some (AttachedProofBinding (PredAnd { left = acc; right = p; loc }))
        | Some p, _ -> Some (AttachedProofBinding p)
        | None, Some m -> Some m
        | None, None -> None)
     | EVar { name; _ }, _ ->
       (match List.assoc_opt name ctx.proof_returns with
        | Some (ReturnsAttachedProof { proof; _ }) -> Some (AttachedProofBinding proof)
        | None -> None)
     | _ -> None)
  | _ -> None

let binding_meta_for_binding ctx bound_name (value : expr) : binding_meta =
  (* Strip the binder variable from a proof expression so that e.g. Active x
     (where x is the element binder in a check fn) becomes Active (args=[]),
     suitable for use as a ForAll predicate. *)
  let strip_binder_from_proof binder proof =
    let rec strip = function
      | PredApp { pred; args; loc } ->
        PredApp { pred; args = List.filter (fun a -> a <> binder) args; loc }
      | PredAnd { left; right; loc } ->
        PredAnd { left = strip left; right = strip right; loc }
    in
    strip proof
  in
  match value with
  | EVar { name = source_name; _ } ->
    (match binding_meta_of_expr ctx value with
     | Some meta -> rename_binding_meta source_name bound_name meta
     | None -> PlainBinding)
  | EOk { value = EVar { name = source_name; _ }; proof; _ } ->
    rename_binding_meta source_name bound_name (AttachedProofBinding proof)
  | EApp _ as app ->
    let base_fn, args = flatten_app_expr [] app in
    (match base_fn with
     | EVar { name = ("List.filterCheck" | "Set.filterCheck" | "List.allCheck"); _ }
     | EField { obj = EConstructor { name = ("List" | "Set"); _ };
                field = ("filterCheck" | "allCheck"); _ }
       when (match args with _ :: _ :: [] -> true | _ -> false) ->
       (* filterCheck checkFn inputList → tracks ForAll(checkFn_proof) on result.
          If inputList already has ForAll(Q), expand to ForAll(Q && P). *)
       let check_fn_expr = List.nth args 0 in
       let input_expr    = List.nth args 1 in
       let check_proof_opt = match check_fn_expr with
         | EVar { name = fn_name; loc = fn_loc } ->
           (match List.assoc_opt fn_name ctx.proof_returns with
            | Some (ReturnsAttachedProof { binder_name; proof }) ->
              (* Only check-kind functions may be passed to filterCheck *)
              (match List.assoc_opt fn_name ctx.function_kinds with
               | Some (FnKind | EstablishKind) ->
                 add_error ctx fn_loc
                   (Printf.sprintf "`%s` is a plain `fn` and cannot be used as the predicate \
                                    argument to `filterCheck`; only `check`-kind functions \
                                    produce verified proof at a validation boundary"
                      fn_name);
                 None
               | _ -> Some (strip_binder_from_proof binder_name proof))
            | _ -> None)
         | ELambda { loc; _ } ->
           (* Anonymous lambda cannot produce check-kind proofs — reject *)
           add_error ctx loc
             "anonymous lambda cannot be used as the predicate argument to `filterCheck`; \
              only named `check`-kind functions produce verified proof at a validation boundary. \
              Define a named `check` function and pass it by name instead.";
           None
         | EBinop { loc; _ } ->
           (* `checkA && checkB` compound check — already handled elsewhere, but if
              it reaches here it's a non-check expression; skip silently (no proof). *)
           ignore loc; None
         | _ -> None
       in
       (match check_proof_opt with
        | None -> PlainBinding
        | Some forall_pred ->
          (* Expand: if input already has ForAll(Q), result is ForAll(Q && P) *)
          let expanded = match binding_meta_of_expr ctx input_expr with
            | Some (AttachedProofBinding existing) ->
            let loc = (match forall_pred with PredApp p -> p.loc | PredAnd p -> p.loc) in
              PredAnd { left = existing; right = forall_pred; loc }
            | _ -> forall_pred
          in
          AttachedProofBinding expanded)
     | EVar { name = "List.emptyForAll"; _ }
     | EField { obj = EConstructor { name = "List"; _ }; field = "emptyForAll"; _ }
       when (match args with _ :: [] -> true | _ -> false) ->
       (* emptyForAll checkFn → empty list with ForAll(checkFn_proof).
          No input list: the result is always an empty list vacuously satisfying the proof. *)
       let check_fn_expr = List.nth args 0 in
       let check_proof_opt = match check_fn_expr with
         | EVar { name = fn_name; _ } ->
           (match List.assoc_opt fn_name ctx.proof_returns with
            | Some (ReturnsAttachedProof { binder_name; proof }) ->
              (match List.assoc_opt fn_name ctx.function_kinds with
               | Some (FnKind | EstablishKind) -> None
               | _ -> Some (strip_binder_from_proof binder_name proof))
            | _ -> None)
         | _ -> None
       in
       (match check_proof_opt with
        | None -> PlainBinding
        | Some forall_pred -> AttachedProofBinding forall_pred)
     | EVar { name = "check"; _ } ->
       (* `check checkFn arg ...` — extract proof from checkFn, renamed to bound_name,
          and fold in accumulated proofs from the subject argument. *)
       let fn_and_rest = match args with fn_expr :: rest -> Some (fn_expr, rest) | [] -> None in
       let new_proof_opt = match fn_and_rest with
         | Some (EVar { name = fn_name; _ }, _) ->
           (match List.assoc_opt fn_name ctx.proof_returns with
            | Some (ReturnsAttachedProof { binder_name; proof }) ->
              Some (rename_proof_name binder_name bound_name proof)
            | None -> None)
         | _ -> None
       in
       let subj_acc_opt = match fn_and_rest with
         | Some (_, EVar { name = subj_name; _ } :: _) ->
           (match List.assoc_opt subj_name ctx.binding_meta_env with
            | Some (AttachedProofBinding acc_proof) ->
              Some (rename_proof_name subj_name bound_name acc_proof)
            | _ -> None)
         | _ -> None
       in
       (match new_proof_opt, subj_acc_opt with
        | Some new_p, Some acc_p ->
          let loc = (match new_p with PredApp x -> x.loc | PredAnd x -> x.loc) in
          AttachedProofBinding (PredAnd { left = acc_p; right = new_p; loc })
        | Some new_p, None -> AttachedProofBinding new_p
        | None, Some acc_p -> AttachedProofBinding acc_p
        | None, None -> PlainBinding)
     | EVar { name; _ } ->
       (match List.assoc_opt name ctx.proof_returns with
        | Some (ReturnsAttachedProof { binder_name; proof }) ->
          AttachedProofBinding (rename_proof_name binder_name bound_name proof)
        | None ->
          (match binding_meta_of_expr ctx value with
           | Some meta -> meta
           | None -> PlainBinding))
     | _ ->
       (match binding_meta_of_expr ctx value with
        | Some meta -> meta
        | None -> PlainBinding))
  | _ ->
    (match binding_meta_of_expr ctx value with
     | Some meta -> meta
     | None -> PlainBinding)

(* R51 follow-up — when an ELetProof projects one conjunct out of a
   compound proof (`let (v ::: p1 && p2) = rhs` or
   `let (v ::: _ && q) = rhs`), the individual proof binder must carry
   only the conjunct at its position, not the whole conjunction. *)
let rec flatten_proof_conj (p : proof_expr) : proof_expr list =
  match p with
  | PredAnd { left; right; _ } ->
    flatten_proof_conj left @ flatten_proof_conj right
  | _ -> [p]

(* Resolve a proof variable reference (a [PredApp { pred = name; args = [] }]
   whose [pred] is actually an in-scope proof binder) to the underlying
   proof predicate. This turns bare-name projections like
   [PredApp "scoreProof"] into the concrete [PredApp "ValidScore" ["rawScore"]]
   they were originally established as. *)
let rec resolve_proof_ref ctx (p : proof_expr) : proof_expr =
  match p with
  | PredApp { pred; args = []; _ } ->
    (match List.assoc_opt pred ctx.binding_meta_env with
     | Some (AttachedProofBinding inner)
     | Some (FactProofBinding inner) -> resolve_proof_ref ctx inner
     | _ -> p)
  | PredApp _ -> p
  | PredAnd { left; right; loc } ->
    PredAnd {
      left = resolve_proof_ref ctx left;
      right = resolve_proof_ref ctx right;
      loc;
    }

let project_proof_at ctx ~pos ~arity (proof : proof_expr) : proof_expr =
  let parts = flatten_proof_conj proof in
  let projected =
    if arity <= 1 || List.length parts <> arity then proof
    else try List.nth parts pos with _ -> proof
  in
  resolve_proof_ref ctx projected

let proof_meta_for_let_proof
    ?(proof_index : (int * int) option = None)
    ctx value_name value =
  let value_loc = match value with
    | EVar { loc; _ } | ELit { loc; _ } | EField { loc; _ }
    | EApp { loc; _ } | EBinop { loc; _ } | EUnop { loc; _ }
    | EIf { loc; _ } | ECase { loc; _ } | ELet { loc; _ }
    | ELetProof { loc; _ } | ERecord { loc; _ } | EList { loc; _ }
    | EOk { loc; _ } | EFail { loc; _ } | EConstructor { loc; _ }
    | ELambda { loc; _ } -> Some loc
    | _ -> None
  in
  (* If this is the outer ELetProof (value_name not "_"), record the binder
     name at the value's location so sibling inner ELetProofs that share the
     same RHS (e.g. from `let (x ::: p1 && p2) = rhs`) can find the outer
     binder and rename `_entity` to it too.  If this is an inner one
     (value_name = "_"), try to look up the outer's binder. *)
  let effective_binder =
    if value_name <> "_" then begin
      (match value_loc with
       | Some loc -> ctx.entity_binder_at := (loc, value_name) :: !(ctx.entity_binder_at)
       | None -> ());
      value_name
    end else begin
      match value_loc with
      | Some loc ->
        (match List.assoc_opt loc !(ctx.entity_binder_at) with
         | Some outer -> outer
         | None -> value_name)
      | None -> value_name
    end
  in
  let meta =
    if value_name = "_" && effective_binder = "_" then
      binding_meta_of_expr ctx value
    else
      Some (binding_meta_for_binding ctx effective_binder value)
  in
  let project = match proof_index with
    | Some (pos, arity) -> fun p -> project_proof_at ctx ~pos ~arity p
    | None -> fun p -> resolve_proof_ref ctx p
  in
  match meta with
  | Some (AttachedProofBinding proof)
  | Some (FactProofBinding proof) -> FactProofBinding (project proof)
  | Some PlainBinding
  | None -> PlainBinding

let select_entity_type args =
  List.find_map (function
    | EConstructor { name; _ } -> Some (TCon name)
    | _ -> None
  ) args

(** Infer the return type of a scalar aggregate (selectSum / selectMax / selectMin)
    by looking up the field type in the entity definition.
    Falls back to [t_int] if the entity or field cannot be resolved. *)

let select_aggregate_field_type ctx args =
  let field_opt = List.find_map (function
    | EField { field; _ } -> Some field
    | _ -> None
  ) args in
  let entity_opt = List.find_map (function
    | EConstructor { name; _ } -> Some name
    | _ -> None
  ) args in
  match field_opt, entity_opt with
  | Some field, Some entity_name ->
    (match List.assoc_opt entity_name ctx.records with
     | Some rd ->
       (match List.assoc_opt field rd.rd_fields with
        | Some ty -> ty
        | None -> t_int)
     | None -> t_int)
  | _ -> t_int

let local_let_reason name expected_ty =
  Printf.sprintf "let binding `%s` must have declared type %s" name (pp_ty expected_ty)

let known_qualifier_modules =
  [ "List"; "ListPrim"; "Dict"; "String"; "Int"; "Float"; "Set"; "Maybe";
    "Either"; "Result"; "Time"; "Random"; "Uuid"; "UUID"; "Env";
    "Http"; "HttpClient"; "Json"; "DB"; "Telemetry"; "Tesl"; "JWT"; "Email";
    (* First-Class Units *)
    "Money"; "Currency"; "ExchangeRate" ]
  @ Units_catalog.quantity_modules

type constructor_resolution =
  | KnownConstructor of ty
  | ProofPredicateConstructor

let resolve_constructor_type ctx name loc =
  match List.assoc_opt name ctx.ctors with
  | Some (_, sch) -> KnownConstructor (instantiate sch)
  | None ->
    (match lookup_name ctx name with
     | Some ty -> KnownConstructor ty
     | None ->
       (match env_lookup name (make_stdlib_env ()) with
        | Some sch -> KnownConstructor (instantiate sch)
        | None ->
          if not (List.mem name known_qualifier_modules) && not ctx.in_establish then
            add_unknown_name_error ctx loc ~what:"constructor" name;
          if ctx.in_establish then ProofPredicateConstructor
          else KnownConstructor (fresh ())))

(* GitHub #29: the flattened "spine" atoms of a query expression — the select
   head, binder/field/entity/keyword atoms, and any modifier atoms the parser
   merged onto an outer where-EBinop (order/limit/groupBy/...).  Comparison
   VALUE operands (the right side of a where) are not spine atoms. *)
let rec query_spine_atoms e =
  match e with
  | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe | BAnd | BOr | BAdd); left; _ } ->
    query_spine_atoms left
  | EApp _ ->
    let (base, args) = flatten_app_expr [] e in
    (match base with
     | EBinop _ -> query_spine_atoms base @ args
     | _ -> base :: args)
  | other -> [other]

let rec classify_lowered_query e =
  match e with
  | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe); left; _ } ->
    classify_lowered_query left
  | EBinop { op = (BAnd | BOr | BAdd); left; right; _ } ->
    (match classify_lowered_query left with
     | Some ty -> Some ty
     | None -> classify_lowered_query right)
  | _ ->
    let (base_fn, args) = flatten_app_expr [] e in
    match base_fn with
    | EVar { name = "selectOne"; _ } -> Some (t_maybe (Option.value (select_entity_type args) ~default:(fresh ())))
    | EVar { name = "select"; _ } -> Some (t_list (Option.value (select_entity_type args) ~default:(fresh ())))
    | EVar { name = "selectCount"; _ } -> Some t_int
    | EVar { name = "selectSum"; _ }
    | EVar { name = "selectMax"; _ }
    | EVar { name = "selectMin"; _ } -> Some t_int  (* field type refined in infer_expr *)
    | EVar { name = ("selectCountBy" | "selectSumBy"); _ } ->
      (* grouped aggregates (GitHub #29): List (Tuple2 K V); K/V are refined by
         [grouped_query_type] at the infer sites (needs ctx + the FULL expr) *)
      Some (t_list (t_tuple2 (fresh ()) (fresh ())))
    | EVar { name = "update"; _ } when args <> [] && (match List.hd args with EConstructor _ | EVar _ -> true | _ -> false) -> Some t_unit
    | EVar { name = "updateAndReturnOne"; _ } -> Some (fresh ())
    | EVar { name = "delete"; _ } when args <> [] && (match List.hd args with EConstructor _ | EVar _ -> true | _ -> false) -> Some t_unit
    | EVar { name = "deleteAndReturnResult"; _ } -> Some t_delete_result
    | EVar { name = "where"; _ } | EVar { name = "set"; _ } -> Some t_unit
    | _ ->
      (* Handle multi-line SQL: SQL modifier clauses (order, limit, etc.) merged as EApp
         args onto a where-EBinop; recurse into the EBinop base to find the select type.
         Only recurse when we actually peeled at least one EApp layer (args <> []);
         otherwise base_fn == e and we'd loop infinitely. *)
      if args = [] then None
      else classify_lowered_query base_fn

(* Decide-by-resolution for `decodeAs`: the runtime type read is driven by the
   resolved RESULT type, so the literal type-name string must agree with it and
   the result must be a concrete codec-registered type. Called from both EApp
   arms with the already-inferred+substituted result type. *)
let check_decodeAs_call ?(strict = true) ctx ~loc ~args ~result_ty =
  match args with
  | (ELit { lit = LString type_name_str; loc = str_loc }) :: _json :: _ ->
    let head = match apply !(ctx.subst) result_ty with
      | TCon n -> Some n
      | TApp (TCon n, _) -> Some n
      | _ -> None in
    (match head with
     | None ->
       (* Only the check-path (strict) reports ambiguity: it runs with the
          resolved expected type. The infer-path runs BEFORE surrounding
          unification pins the result (e.g. `let x = decodeAs "T" j` whose type
          is fixed only by a later use / the enclosing fn return), so a `None`
          head there is "not yet resolved", NOT "ambiguous" — reporting it
          over-rejects legitimate let-bound decodes. When the type IS resolved
          (Some, below) the name/codec match is enforced on both paths. *)
       if strict then
         add_error ctx loc
           "`decodeAs` result type is ambiguous; annotate the target type \
            (e.g. `fn f(j: String) -> T = decodeAs \"T\" j`)"
     | Some resolved_name ->
       if type_name_str <> resolved_name then
         add_error ctx str_loc
           (Printf.sprintf
              "`decodeAs \"%s\"` decodes as type `%s` but the result is used as `%s`; \
               the type-name string must match the target type"
              type_name_str type_name_str resolved_name)
       else if (List.mem_assoc resolved_name ctx.records
                || List.mem_assoc resolved_name ctx.adts)
               && not (List.mem resolved_name ctx.codec_decode_types) then
         add_error ctx str_loc
           (Printf.sprintf
              "`decodeAs` target type `%s` has no `fromJson` codec; declare one \
               (`codec %s { ... fromJson [ ... ] }`)" resolved_name resolved_name))
  | (first :: _) ->
    (* first arg is not a string literal: the type name must be a compile-time
       literal so it can be checked against the type. *)
    add_error ctx (expr_loc first)
      "`decodeAs` requires a literal type-name string as its first argument"
  | [] -> ()

(* ── Eq/Ord instance predicates (scoped type-class layer, Stage 1) ──────────
   The comparison operators demand `Eq`/`Ord` on their operand type.  Rather than
   a divergent shadow re-inferencer, the check is driven from the HM-resolved
   operand type at the comparison site (see [infer_binop]).  It fires ONLY on a
   FULLY-GROUND type (no type variable anywhere) — a type still mentioning a
   variable is generic and stays PERMISSIVE (the S14b decision: no open Eq/Ord
   polymorphism; a bad concrete instantiation is caught wherever it becomes
   ground).  Instance set: Ord = {Int, Float, PosixMillis} + newtypes over them;
   Eq = everything except a function (or a composite transitively containing one),
   with records/ADTs recursed through their field types. *)
(* A lowercase-initial TCon name is a TYPE VARIABLE (type parameter), not a real
   type — real Tesl types are always capitalized.  ty_of_type_expr encodes a
   type-param `a` as `TCon "a"`, so it must be treated as generic (permissive /
   non-ground), exactly like a TVar. *)
let is_ty_var_name (s : string) : bool =
  String.length s > 0 && s.[0] >= 'a' && s.[0] <= 'z'

let rec ty_is_ground (t : ty) : bool =
  match t with
  | TVar _ -> false
  | TCon name -> not (is_ty_var_name name)
  | TApp (h, a) | TFun (h, a) -> ty_is_ground h && ty_is_ground a

(* [ctx.type_aliases] holds both newtype and transparent-alias bases (populated in
   collect_type_defs); resolving through it makes `type Celsius = Float` orderable
   and `type Callback = (Int) -> Int` non-equatable.  Nominal identity is unaffected
   (unification still distinguishes the TCons); this only decides comparability. *)
let ty_is_ord ctx (t : ty) : bool =
  let rec go seen t =
    match apply !(ctx.subst) t with
    | TCon ("Int" | "Float" | "PosixMillis") -> true
    (* Dimensioned quantities are ordered (same-dimension only — unification
       already rejects a cross-dimension compare before this predicate runs).
       Money is deliberately NOT ord: ordering across currencies is undefined;
       use Money.compare (which requires the SameCurrency proof). *)
    | TCon q when Units_catalog.is_quantity_name q -> true
    | TVar _ -> true  (* generic — permissive (the ground-check gates real use) *)
    | TCon name when is_ty_var_name name -> true   (* generic type param — permissive *)
    | TCon name when not (List.mem name seen) ->
      (match List.assoc_opt name ctx.type_aliases with
       | Some b -> go (name :: seen) b | None -> false)
    | _ -> false      (* records, ADTs, Maybe/List/…, functions, tuples: not ordered *)
  in go [] t

let ty_is_eq ctx (t : ty) : bool =
  let rec go seen t =
    match apply !(ctx.subst) t with
    | TFun _ -> false                      (* functions have no decidable equality *)
    | TVar _ -> true                       (* generic / type-param — permissive *)
    | TCon name when is_ty_var_name name -> true   (* generic type param — permissive *)
    | TApp (h, a) -> go seen h && go seen a (* container + args must be equatable *)
    | TCon name when List.mem name seen -> true  (* recursive type: eq at the cycle *)
    | TCon name ->
      (match List.assoc_opt name ctx.type_aliases with
       | Some b -> go (name :: seen) b
       | None ->
         (match List.assoc_opt name ctx.records with
          | Some rd -> List.for_all (fun (_, ft) -> go (name :: seen) ft) rd.rd_fields
          | None ->
            (match List.assoc_opt name ctx.adts with
             | Some ad ->
               List.for_all (fun (_, fields) ->
                 List.for_all (fun (_, ft) -> go (name :: seen) ft) fields) ad.ad_variants
             | None -> true)))  (* primitive / opaque nominal → equatable *)
  in go [] t

let cmp_op_name = function
  | BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">="
  | BEq -> "==" | BNeq -> "!=" | _ -> "?"

(* Resolve the callable's name for Eq/Ord constraint discharge: a bare fn
   (`genLt`) or a qualified stdlib member (`List.member`).  None for anything
   without a stable name (lambdas, computed callees) — those simply aren't
   discharged here (residual is caught by the runtime backstop). *)
let ord_eq_callee_name (fn_expr : expr) : string option =
  match fn_expr with
  | EVar { name; _ } -> Some name
  | EField { obj = EConstructor { name = modname; _ }; field; _ } -> Some (modname ^ "." ^ field)
  | EField { obj = EVar { name = modname; _ }; field; _ } -> Some (modname ^ "." ^ field)
  | _ -> None

(** Infer the type of an expression. Returns the inferred type;
    errors are accumulated in ctx. *)
(* serverTools: flatten a proof annotation into normalized predicates —
   (predicate name, args with [subject] replaced by "§") — the shape both sides
   of the endpoint-inclusion comparison are put into.  Comparing the FULL
   normalized predicate (not just the name) keeps `HasRole u "admin"` from
   matching `HasRole u "viewer"`. *)
let normalized_preds_of_proof (subject : string) (p : proof_expr)
  : (string * string list) list =
  let rec go acc = function
    | PredApp { pred; args; _ } ->
      (pred, List.map (fun a -> if a = subject then "\xc2\xa7" else a) args) :: acc
    | PredAnd { left; right; _ } -> go (go acc left) right
  in
  List.sort_uniq compare (go [] p)

let rec infer_expr ctx (e : expr) : ty =
  (* GitHub #29: type a grouped aggregate (selectCountBy / selectSumBy) from
     the FULL query expression: List (Tuple2 K V) where K is the groupBy key
     type (a declared column's type, or PosixMillis for a Time.trunc* bucket —
     whose offset expression is inferred against Int here) and V is Int for
     count / the summed column's declared type for sum.  Shape/field
     completeness rules live in Validation_advanced; this is only typing.
     Decide-by-resolution: stands down when the head is user-defined. *)
  let grouped_query_type full =
    match query_spine_atoms full with
    | EVar { name = ("selectCountBy" | "selectSumBy" as head); _ } :: atoms
      when lookup_name ctx head = None ->
      let entity_opt = List.find_map (function
        | EConstructor { name; _ } -> Some name
        | _ -> None) atoms in
      let field_ty_of field =
        match entity_opt with
        | Some en ->
          (match List.assoc_opt en ctx.records with
           | Some rd ->
             (match List.assoc_opt field rd.rd_fields with
              | Some ty -> ty
              | None -> fresh ())
           | None -> fresh ())
        | None -> fresh ()
      in
      let rec find_key = function
        | EVar { name = "groupBy"; _ } :: key :: _ -> Some key
        | _ :: rest -> find_key rest
        | [] -> None
      in
      let key_ty =
        match find_key atoms with
        | Some (EField { field; _ }) -> field_ty_of field
        | Some key ->
          (match flatten_app_expr [] key with
           | EField { obj = (EConstructor { name = "Time"; args = []; _ }
                            | EVar { name = "Time"; _ });
                      field = ("truncHour" | "truncDay" | "truncWeek"
                              | "truncMonth" | "truncYear"); _ },
             [off; _field] ->
             let off_ty = infer_expr ctx off in
             unify_at ctx (expr_loc off) off_ty t_timezone;
             t_posix
           | _ -> fresh ())
        | None -> fresh ()
      in
      let value_ty =
        if head = "selectCountBy" then t_int
        else
          (match atoms with
           | EField { field; _ } :: _ -> field_ty_of field
           | _ -> t_int)
      in
      Some (t_list (t_tuple2 key_ty value_ty))
    | _ -> None
  in
  let inferred = match e with

  | ELit { lit = LInterp segs; loc = _ } ->
    List.iter (function
      | ILiteral _ -> ()
      | IExpr e ->
        let ty = infer_expr ctx e in
        let ty' = apply !(ctx.subst) ty in
        (match ty' with
         | TCon ("String" | "Int" | "Bool" | "Float") | TVar _ -> ()
         | _ ->
           add_error ctx (expr_loc e)
             (Printf.sprintf
               "cannot interpolate a value of type `%s`; \
                only String, Int, Bool, and Float values are supported in \
                string interpolation — convert to String first with a \
                dedicated function"
               (pp_ty ty')))
    ) segs;
    t_string

  | ELit { lit; loc = _ } -> infer_lit lit

  (* ── serverTools: server endpoints as agent tools ──────────────────────────
     `serverTools MyServer user : List Tool` derives one agent tool per non-SSE
     endpoint of the server's api, partially applied with the proof-carrying
     authenticated user value so the agent acts strictly on the user's behalf.
     Typed structurally here because a server name is declarative configuration,
     not an expression value.  INCLUSION is per call site: an endpoint becomes a
     tool iff the user variable's declared proof annotation covers the endpoint's
     auth predicates — so an `Authenticated`-only user gets the plain endpoints
     while an `Authenticated && Admin` user additionally gets the admin-gated
     ones.  Sound because declared annotations are themselves checker-verified
     (params by call-site discharge, let/check bindings by their own rules) —
     the tool never fabricates a proof the value does not carry.  All arms stand
     down when the module declares its own `serverTools` (decide-by-resolution,
     not by spelling). *)
  | EApp { fn = EApp { fn = EVar { name = "serverTools"; _ }; arg = server_ref; _ };
           arg = user_arg; loc }
    when not ctx.server_tools_shadowed ->
    (match server_ref with
     | EConstructor { name = sname; args = []; _ } | EVar { name = sname; _ } ->
       (match List.assoc_opt sname ctx.server_tools_env with
        | Some (auth_ty_opt, endpoints) ->
          let user_ty = infer_expr ctx user_arg in
          (match auth_ty_opt with
           | Some auth_ty_name ->
             unify_at ctx (expr_loc user_arg) user_ty
               (ty_of_type_expr (TName { name = auth_ty_name; loc }))
           | None -> ());
          (match user_arg with
           | EVar { name = uname; _ } ->
             let user_preds =
               match List.assoc_opt uname ctx.binding_meta_env with
               | Some (AttachedProofBinding p) -> normalized_preds_of_proof uname p
               | _ -> []
             in
             let included = List.filter (fun (ep : server_tools_endpoint) ->
               List.for_all (fun pr -> List.mem pr user_preds) ep.ste_preds
             ) endpoints in
             let has_authed = List.exists (fun ep -> ep.ste_preds <> []) endpoints in
             let included_authed = List.exists (fun ep -> ep.ste_preds <> []) included in
             if has_authed && not included_authed then
               add_error ctx (expr_loc user_arg) (Printf.sprintf
                 "`serverTools %s %s`: `%s` carries no declared proof matching any \
                  endpoint's `auth` line, so no authenticated endpoint would become a \
                  tool. Pass a value whose declared annotation covers the api's auth \
                  predicates (e.g. a handler parameter `%s: T ::: %s %s`)"
                 sname uname uname uname
                 (match List.find_opt (fun ep -> ep.ste_preds <> []) endpoints with
                  | Some ep -> fst (List.hd ep.ste_preds)
                  | None -> "Authenticated")
                 uname)
             else
               ctx.server_tools_sites :=
                 (loc, (sname, List.map (fun ep -> ep.ste_binding) included))
                 :: !(ctx.server_tools_sites)
           | _ ->
             add_error ctx (expr_loc user_arg)
               "`serverTools` takes the authenticated user as a bare variable whose \
                declared proof annotation decides which endpoints become tools — \
                bind the value first (e.g. a proof-annotated handler parameter, or \
                `let admin = requireAdmin user`) and pass that name")
        | None ->
          ignore (infer_expr ctx user_arg);
          add_error ctx loc (Printf.sprintf
            "`serverTools` argument `%s` is not a server declared in this module — \
             it takes a bare reference to a `server` block (`serverTools MyServer user`)"
            sname))
     | _ ->
       ignore (infer_expr ctx user_arg);
       add_error ctx loc
         "`serverTools` supports only a bare reference to a server declared in this \
          module (`serverTools MyServer user`) — an arbitrary expression cannot be \
          lowered to the server's endpoint tools");
    t_list t_tool

  | EApp { fn = EVar { name = "serverTools"; _ }; loc; _ }
    when not ctx.server_tools_shadowed ->
    add_error ctx loc
      "`serverTools` must be fully applied: `serverTools MyServer user` (a server \
       and the proof-carrying authenticated user the tools act on behalf of); a \
       partial application cannot be lowered";
    t_list t_tool

  | EVar { name = "serverTools"; loc } when not ctx.server_tools_shadowed ->
    add_error ctx loc
      "`serverTools` cannot be passed around as a value — apply it directly to a \
       server and an authenticated user: `serverTools MyServer user`";
    t_list t_tool

  (* `humanActions MyServer user : List Tool` is the COMPLEMENT of `serverTools`
     at the same call site: one INERT tool per endpoint the agent may NOT call
     on `user`'s behalf — whose auth predicates the user variable's declared
     proof annotation does NOT cover.  serverTools (included) and humanActions
     (excluded) partition the server's endpoints, disjoint and complete.  The
     tool never executes the endpoint; it surfaces a request the HUMAN performs
     in the browser under their own session (which re-checks auth server-side),
     so scoping the agent's `user` narrower than the human's real authority is
     what makes the held-back actions meaningful.  Typed structurally for the
     same reason as `serverTools` — a server name is declarative configuration,
     not an expression value.  All arms stand down when the module declares its
     own `humanActions` (decide-by-resolution, not by spelling). *)
  | EApp { fn = EApp { fn = EVar { name = "humanActions"; _ }; arg = server_ref; _ };
           arg = user_arg; loc }
    when not ctx.human_actions_shadowed ->
    (match server_ref with
     | EConstructor { name = sname; args = []; _ } | EVar { name = sname; _ } ->
       (match List.assoc_opt sname ctx.server_tools_env with
        | Some (auth_ty_opt, endpoints) ->
          let user_ty = infer_expr ctx user_arg in
          (match auth_ty_opt with
           | Some auth_ty_name ->
             unify_at ctx (expr_loc user_arg) user_ty
               (ty_of_type_expr (TName { name = auth_ty_name; loc }))
           | None -> ());
          (match user_arg with
           | EVar { name = uname; _ } ->
             let user_preds =
               match List.assoc_opt uname ctx.binding_meta_env with
               | Some (AttachedProofBinding p) -> normalized_preds_of_proof uname p
               | _ -> []
             in
             (* EXCLUDED = the complement of serverTools' INCLUDED filter: an
                endpoint whose auth predicates the user's declared proof does NOT
                fully cover.  Empty (user can do everything) is legitimate — no
                error, unlike serverTools' "no authed endpoint reachable" guard. *)
             let excluded = List.filter (fun (ep : server_tools_endpoint) ->
               not (List.for_all (fun pr -> List.mem pr user_preds) ep.ste_preds)
             ) endpoints in
             ctx.human_actions_sites :=
               (loc, (sname, List.map (fun (ep : server_tools_endpoint) -> ep.ste_binding) excluded))
               :: !(ctx.human_actions_sites)
           | _ ->
             add_error ctx (expr_loc user_arg)
               "`humanActions` takes the authenticated user as a bare variable whose \
                declared proof annotation decides which endpoints are the agent's \
                human actions — bind the value first (e.g. a proof-annotated handler \
                parameter, or `let scoped = requireAuthed user`) and pass that name")
        | None ->
          ignore (infer_expr ctx user_arg);
          add_error ctx loc (Printf.sprintf
            "`humanActions` argument `%s` is not a server declared in this module — \
             it takes a bare reference to a `server` block (`humanActions MyServer user`)"
            sname))
     | _ ->
       ignore (infer_expr ctx user_arg);
       add_error ctx loc
         "`humanActions` supports only a bare reference to a server declared in this \
          module (`humanActions MyServer user`) — an arbitrary expression cannot be \
          lowered to the server's held-back endpoint tools");
    t_list t_tool

  | EApp { fn = EVar { name = "humanActions"; _ }; loc; _ }
    when not ctx.human_actions_shadowed ->
    add_error ctx loc
      "`humanActions` must be fully applied: `humanActions MyServer user` (a server \
       and the proof-carrying authenticated user the held-back tools are computed \
       against); a partial application cannot be lowered";
    t_list t_tool

  | EVar { name = "humanActions"; loc } when not ctx.human_actions_shadowed ->
    add_error ctx loc
      "`humanActions` cannot be passed around as a value — apply it directly to a \
       server and an authenticated user: `humanActions MyServer user`";
    t_list t_tool

  | EVar { name; loc } ->
    (match lookup_name ctx name with
     | Some ty -> ty
     | None ->
       (* Check constructors *)
       (match List.assoc_opt name ctx.ctors with
        | Some (_, ctor_sch) -> instantiate ctor_sch
        | None ->
          (* D8 idiom-transfer hint: `return x` is a common transfer mistake —
             Tesl has no `return`; a function body IS its value.  D9: the loc
             isolates the `return` token (start of `return` .. start of the
             following token), so deleting it IS the fix — shipped only when
             the source snapshot confirms `return` sits there. *)
          (if name = "return" then
             add_error_fix ctx loc
               "unknown name: `return` — Tesl has no `return` statement; a function \
                body IS its return value, so write the value as the last expression \
                (e.g. `x` instead of `return x`)"
               (Diag_fix.verified_delete ~source_lines:ctx.source_lines loc
                  ~expect:"return")
           else add_unknown_name_error ctx loc ~what:"name" name);
          fresh ()))

  | EField { obj; field; loc } ->
    (* First try module-qualified name: Module.function (e.g., Dict.lookup).
       For constructors (uppercase), always try qualified. For EVar (lowercase), try
       qualified first and fall back to record field access if not found. *)
    let try_qualified () =
      let qname_opt = match obj with
        | EConstructor { name = modname; args = []; _ }
        | EVar { name = modname; _ } -> Some (modname ^ "." ^ field)
        | _ -> None
      in
      match qname_opt with
      | None -> None
      | Some qname ->
        (match lookup_name ctx qname with
         | Some ty -> Some ty
         | None ->
           (match env_lookup qname (make_stdlib_env ()) with
            | Some sch -> Some (instantiate sch)
            | None -> None))
    in
    (match try_qualified () with
     | Some ty -> ty
     | None ->
       (* Record field access *)
       let obj_ty = infer_expr ctx obj in
       let obj_ty_resolved = apply !(ctx.subst) obj_ty in
       (match lookup_field ctx obj_ty_resolved field with
        | Some fty ->
          let fa_record_type = match obj_ty_resolved with
            | TCon n | TApp (TCon n, _) -> n
            | _ -> ""
          in
          if fa_record_type <> "" then begin
            let fa_field_type = pp_ty (apply !(ctx.subst) fty) in
            ctx.field_accesses := {
              fa_loc = loc; fa_field = field;
              fa_record_type; fa_field_type;
            } :: !(ctx.field_accesses)
          end;
          fty
        | None ->
           (* Field not found.  If the object type is concretely known (not a
              free type variable) and is not a record type, this is an error.
              For type variables we stay silent to allow polymorphic inference. *)
           (match obj_ty_resolved with
            | TVar _ ->
              fresh ()  (* type still unresolved — defer *)
            | TCon type_name | TApp (TCon type_name, _) ->
              (match List.assoc_opt type_name ctx.records with
               | Some _ ->
                 (* It IS a record, but the field doesn't exist *)
                 add_error ctx loc (Printf.sprintf
                   "type `%s` has no field `%s`" type_name field);
                 fresh ()
                              | None ->
                  (* Not a user-defined record.  Sub-cases:
                     1. Newtype — only `.value` is valid (unwraps to base type);
                        any other field is an error (review 2.4).
                     2. Primitive / user ADT — no fields, error.
                     3. Opaque stdlib type (HttpRequest/HttpResponse) — the emitter
                        handles a FIXED special-field set; any OTHER field is an
                        error.  Previously ANY field returned a wildcard `fresh ()`
                        that unified with any type — a T_ANY back door (review 2.4). *)
                  let is_primitive = match type_name with
                    | "Int" | "Integer" | "String" | "Bool" | "Float"
                    | "Real" | "Unit" -> true
                    | _ -> false
                  in
                  let is_user_adt = List.mem_assoc type_name ctx.adts in
                  let newtype_base =
                    match List.assoc_opt type_name ctx.ctors with
                    | Some (ctor_type_name, ctor_sch) when ctor_type_name = type_name ->
                      (match instantiate ctor_sch with
                       | TFun (base_ty, _) -> Some base_ty
                       | _ -> Some (fresh ()))
                    | _ -> None
                  in
                  let no_such_field () =
                    add_error ctx loc (Printf.sprintf
                      "type `%s` has no field `%s`" type_name field);
                    fresh ()
                  in
                  (match newtype_base with
                   | Some base ->
                     (* Newtype: `.value` unwraps; no other field exists. *)
                     if field = "value" then base else no_such_field ()
                   | None ->
                     if is_primitive || is_user_adt then begin
                       add_error ctx loc (Printf.sprintf
                         "cannot access field `%s` on a value of type `%s` \
                          (not a record type)"
                         field (pp_ty obj_ty_resolved));
                       fresh ()
                     end else begin
                       (* Only the KNOWN opaque stdlib types have a fixed,
                          checker-side field set (the emitter's special fields).
                          For those, error on any other field (review 2.4 — this
                          closes the `HttpResponse.bogusField` T_ANY hole).  For
                          ANY OTHER unresolved type — an imported entity/record
                          (`KanelUser`, `OrgMembership`) or a qualified cross-module
                          record (`Sandbox3.ARecord2`) whose fields we cannot
                          resolve here — keep the permissive fallback rather than
                          risk a false "no field" on a real record field. *)
                       let is_known_opaque = match type_name with
                         | "HttpRequest" | "HttpResponse"
                         | "JwtToken" | "JwtSecret"
                         | "Agent" | "AgentReply" | "LlmProvider"
                         | "Conversation" | "ConversationTurn"
                         | "Tool" | "ToolStep" -> true
                         | _ -> false
                       in
                       if not is_known_opaque then fresh ()
                       else
                         (match field with
                          | "value" | "cookies" | "headers" | "queryParameters"
                          | "body" | "path" | "method_" | "method" | "status" ->
                            fresh ()
                          | _ -> no_such_field ())
                     end))
            | _ ->
              add_error ctx loc (Printf.sprintf
                "cannot access field `%s` on a value of type `%s` \
                 (not a record type)"
                field (pp_ty obj_ty_resolved));
              fresh ())))

  | EApp {
      fn = EVar { name = "#record-update#"; _ };
      arg = ERecord { fields; type_hint = _; loc = _ };
      loc = _;
    } ->
    (match List.assoc_opt "__base__" fields with
     | Some base_expr ->
       let base_ty = infer_expr ctx base_expr in
       let resolved_base = apply !(ctx.subst) base_ty in
       (* R51_T01 — reject record update with unknown field. The previous
          implementation silently accepted `{ p | z = 100 }` when `z` did
          not exist on the record's declared type. *)
       let base_type_name =
         let rec head_name = function
           | TCon n -> Some n
           | TApp (h, _) -> head_name h
           | _ -> None
         in
         match head_name resolved_base with Some n -> n | None -> "?"
       in
       List.iter (fun (field_name, value_expr) ->
         if field_name <> "__base__" then begin
           let value_ty = infer_expr ctx value_expr in
           match lookup_field ctx resolved_base field_name with
           | Some field_ty -> unify_at ctx (expr_loc value_expr) value_ty field_ty
           | None ->
             add_error ctx (expr_loc value_expr)
               (Printf.sprintf "record update: type `%s` has no field `%s`"
                  base_type_name field_name)
         end
       ) fields;
       apply !(ctx.subst) base_ty
     | None -> fresh ())

  (* TypeName { field: val } — record construction with explicit type name *)
  | EApp {
      fn = EConstructor { name = rname; args = []; _ };
      arg = ERecord { fields; loc = rloc; _ };
      loc = _;
    } when List.mem_assoc rname ctx.records ->
    let rd = List.assoc rname ctx.records in
    (* Check for missing fields *)
    let provided_field_names = List.map fst fields in
    List.iter (fun (def_name, _def_ty) ->
      if not (List.mem def_name provided_field_names) then
        add_error ctx rloc
          (Printf.sprintf "record `%s` is missing required field `%s`" rname def_name)
    ) rd.rd_fields;
    (* Type-check provided fields *)
    List.iter (fun (field_name, value_expr) ->
      match List.assoc_opt field_name rd.rd_fields with
      | Some field_ty ->
        let actual = infer_expr ctx value_expr in
        unify_at ctx (expr_loc value_expr) actual field_ty
      | None ->
        add_error ctx rloc
          (Printf.sprintf "record type `%s` has no field `%s`" rname field_name);
        ignore (infer_expr ctx value_expr)
    ) fields;
    TCon rname

  (* ADT variant constructor with inline record syntax: Right { value: x }
     The ERecord is NOT a Tesl record type here — it's syntactic sugar for
     passing multiple named arguments to the ADT constructor. *)
  | EApp {
      fn = EConstructor { name = ctor_name; args = []; _ };
      arg = ERecord { fields; loc = _; _ };
      loc;
    } when List.mem_assoc ctor_name ctx.ctors
        && not (List.mem_assoc ctor_name ctx.records) ->
    let (adt_name, ctor_sch) = List.assoc ctor_name ctx.ctors in
    let ctor_ty = instantiate ctor_sch in
    (* Get the declared field names in order from the ADT definition *)
    let named_field_tys =
      match List.assoc_opt adt_name ctx.adts with
      | Some ad -> (match List.assoc_opt ctor_name ad.ad_variants with
          | Some nft -> nft
          | None -> [])
      | None -> []
    in
    let ret_ty =
      if named_field_tys = [] then
        (* No ADT metadata: fall back to applying values in source order. *)
        List.fold_left (fun cur_ty value_expr ->
          let arg_ty = infer_expr ctx value_expr in
          let next_ty = fresh () in
          unify_at ctx loc cur_ty (TFun (arg_ty, next_ty));
          apply !(ctx.subst) next_ty
        ) ctor_ty (List.map snd fields)
      else begin
        (* Validate the named fields like a record literal: every declared field
           must be present, no unknown fields. Then consume every declared arrow
           (matching values by name) so the result is the ADT type even when a
           field is missing — avoiding a confusing cascade arity error. *)
        List.iter (fun (fname, _) ->
          if not (List.mem_assoc fname fields) then
            add_error ctx loc
              (Printf.sprintf "constructor `%s` is missing required field `%s`"
                 ctor_name fname)
        ) named_field_tys;
        List.iter (fun (fname, value_expr) ->
          if not (List.mem_assoc fname named_field_tys) then begin
            add_error ctx (expr_loc value_expr)
              (Printf.sprintf "constructor `%s` has no field `%s`" ctor_name fname);
            ignore (infer_expr ctx value_expr)
          end
        ) fields;
        List.fold_left (fun cur_ty (fname, _decl_ty) ->
          let next_ty = fresh () in
          (match List.assoc_opt fname fields with
           | Some value_expr ->
             let arg_ty = infer_expr ctx value_expr in
             unify_at ctx loc cur_ty (TFun (arg_ty, next_ty))
           | None ->
             unify_at ctx loc cur_ty (TFun (fresh (), next_ty)));
          apply !(ctx.subst) next_ty
        ) ctor_ty named_field_tys
      end
    in
    apply !(ctx.subst) ret_ty

  | EApp { fn; arg = (EList { elems = []; _ } as empty_list); loc } ->
    (* Parser reuses the same AST node for () and []. Treat this as a real
       application when the callee is callable; otherwise preserve the zero-arg
       sentinel behavior for declarations like f(). *)
    let fn_ty = apply !(ctx.subst) (infer_expr ctx fn) in
    (match fn_ty with
     | TFun _ | TVar _ ->
        let arg_ty = infer_expr ctx empty_list in
        let ret_ty = fresh () in
        unify_at ctx loc fn_ty (TFun (arg_ty, ret_ty));
        apply !(ctx.subst) ret_ty
     | _ -> fn_ty)

  | EApp _ as app ->
    let (base_fn, args) = flatten_app_expr [] app in
    let infer_direct_call fn_expr call_args =
      let fn_ty = infer_expr ctx fn_expr in
      let arg_tys_rev = ref [] in
      let final_ret_ty = List.fold_left (fun current_ret_ty arg_expr ->
        let arg_ty = infer_expr ctx arg_expr in
        arg_tys_rev := arg_ty :: !arg_tys_rev;
        let next_ret_ty = fresh () in
        unify_at ctx (expr_loc arg_expr) current_ret_ty (TFun (arg_ty, next_ret_ty));
        apply !(ctx.subst) next_ret_ty
      ) fn_ty call_args in
      (* Record the call for Eq/Ord discharge after the whole module is checked
         (when every fn's obligations are known).  Resolve arg types NOW, in this
         fn's substitution.  Additive: does not affect inference. *)
      (match ord_eq_callee_name fn_expr with
       | Some name when call_args <> [] ->
         let resolved = List.rev_map (fun a -> apply !(ctx.subst) a) !arg_tys_rev in
         ctx.ord_eq_calls := (name, resolved, expr_loc fn_expr) :: !(ctx.ord_eq_calls)
       | _ -> ());
      apply !(ctx.subst) final_ret_ty
    in
    (match base_fn with
     | EVar { name; loc } when is_check_function_name ctx name ->
        add_error ctx loc
          (Printf.sprintf
             "check function `%s` must be called with the `check` keyword; write `check %s ...`"
             name name);
        infer_direct_call base_fn args
     | EBinop { op = BAnd; loc; _ } when is_composed_check_function_expr ctx base_fn ->
        add_error ctx loc
          "combined check application must use the `check` keyword; write `check (checkA && checkB) value`";
        let check_fns = flatten_check_chain_expr [] base_fn in
        let result_ty = fresh () in
        List.iter (fun fn_expr ->
          let fn_ret_ty = infer_direct_call fn_expr args in
          unify_at ctx (expr_loc fn_expr) result_ty fn_ret_ty
        ) check_fns;
        apply !(ctx.subst) result_ty
     | EVar { name = "check"; _ } ->
        (match args with
         | check_fn :: check_args -> infer_direct_call check_fn check_args
         | [] -> fresh ())
     | EVar { name = "initTelemetry"; _ } ->
        let rec infer_kw_args = function
          | [] -> ()
          | EVar { name = "service"; _ } :: value :: rest
          | EVar { name = "endpoint"; _ } :: value :: rest ->
            let value_ty = infer_expr ctx value in
            unify_at ctx (expr_loc value) value_ty t_string;
            infer_kw_args rest
          | EVar { name = "console"; _ } :: value :: rest ->
            let value_ty = infer_expr ctx value in
            unify_at ctx (expr_loc value) value_ty t_bool;
            infer_kw_args rest
          | EVar { name = kw; loc } :: _ ->
            add_error ctx loc (Printf.sprintf "unknown initTelemetry keyword: %s" kw)
          | value :: _ ->
            add_error ctx (expr_loc value) "initTelemetry expects keyword/value pairs"
        in
        infer_kw_args args;
        t_unit
     | EBinop { op = BAnd; _ } ->
        (* First check if this is a SQL compound-where expression (where A && B)
           that may have order/limit/etc. modifier args appended after merge.
           If so, use the SQL type classifier to infer the return type.
           Otherwise fall through to the check-chain logic. *)
        (match grouped_query_type app with
         | Some ty -> record_sql_operand_field_accesses ctx base_fn; ty
         | None ->
        match classify_lowered_query base_fn with
         | Some ty -> record_sql_operand_field_accesses ctx base_fn; ty
         | None ->
           let check_fns = flatten_check_chain_expr [] base_fn in
           if List.length check_fns >= 2 then begin
             let result_ty = fresh () in
             List.iter (fun fn_expr ->
               let fn_ret_ty = infer_direct_call fn_expr args in
               unify_at ctx (expr_loc fn_expr) result_ty fn_ret_ty
             ) check_fns;
             apply !(ctx.subst) result_ty
           end else
             infer_direct_call base_fn args)
     | EVar { name = "make-witness"; _ } ->
        (match args with
         | [EApp { fn = EVar { name = _; _ }; arg = body; _ }] -> infer_expr ctx body
         | _ -> fresh ())
     (* BUG-1 fix: user-defined functions named `select`, `selectOne`, `insert`, `update`,
        `delete`, `upsert` must be type-checked as normal function calls when they appear
        in ctx.env (user-defined). Only treat them as SQL operations when NOT user-defined. *)
     | EVar { name = ("select" | "selectOne" | "selectCount" | "selectSum" | "selectMax"
                     | "selectMin" | "selectCountBy" | "selectSumBy"
                     | "insert" | "update" | "delete" | "upsert" as name); _ }
       when lookup_name ctx name <> None ->
        infer_direct_call base_fn args
     | EVar { name = "selectOne"; _ } ->
        t_maybe (Option.value (select_entity_type args) ~default:(fresh ()))
     | EVar { name = "select"; _ } ->
        t_list (Option.value (select_entity_type args) ~default:(fresh ()))
     | EVar { name = "selectCount"; _ } ->
        t_int
     | EVar { name = "selectSum"; _ }
     | EVar { name = "selectMax"; _ }
     | EVar { name = "selectMin"; _ } ->
        select_aggregate_field_type ctx args
     | EVar { name = ("selectCountBy" | "selectSumBy"); _ } ->
        (match grouped_query_type app with
         | Some ty -> ty
         | None -> t_list (t_tuple2 (fresh ()) (fresh ())))
     | EVar { name = "insert"; _ }
     | EVar { name = "insertMany"; _ } ->
        (* NT-07 width-match: an inserted entity record must match its declared
           field types — e.g. an `Int` written to an `Int32` column is a compile
           error, not a silent narrowing caught only by Postgres at write time.
           `insert Ent { .. }` flattens to `EConstructor Ent :: ERecord { .. } ::
           _` (the outer `insert` application splits the constructor from its
           record), and the record-construction arm above only fires on the
           *tight* `EApp { EConstructor; ERecord }` unit — so rebuild that unit and
           infer it, running the same field-by-field unification that guards bare
           construction.  This arm previously short-circuited to `TCon name`,
           leaving the record entirely unchecked. *)
        (match args with
         | EConstructor { name = rname; args = []; loc = cloc }
           :: (ERecord { fields; loc = rloc; _ }) :: _
           when List.mem_assoc rname ctx.records ->
           ignore (infer_expr ctx
             (EApp { fn = EConstructor { name = rname; args = []; loc = cloc };
                     arg = ERecord { fields; type_hint = Some rname; loc = rloc };
                     loc = rloc }))
         | _ -> ());
        (match args with
         | EConstructor { name; _ } :: _ -> TCon name
         | _ -> fresh ())
     | EVar { name = "upsert"; _ } -> t_unit
     | EVar { name = "update"; _ }
     | EVar { name = "updateAndReturnOne"; _ }
     | EVar { name = "returning"; _ } ->
        fresh ()
     | EVar { name = "delete"; _ } -> t_unit
     | EVar { name = "deleteAndReturnResult"; _ } -> t_delete_result
     | EVar { name = "where"; _ }
     | EVar { name = "set"; _ }
     | EVar { name = "onConflict"; _ }
     | EVar { name = "doUpdate"; _ }
     | EVar { name = "serve"; _ } ->
        t_unit
     | EBinop _ ->
        (* Multi-line SQL: SQL modifier clauses (order, limit, offset, groupBy, etc.)
           are merged by the parser as EApp args onto a where-EBinop.
           Classify the underlying select expression to infer the return type. *)
        (match grouped_query_type app with
         | Some ty -> record_sql_operand_field_accesses ctx base_fn; ty
         | None ->
         match classify_lowered_query base_fn with
         | Some ty -> record_sql_operand_field_accesses ctx base_fn; ty
         | None -> infer_direct_call base_fn args)
     | EConstructor { name; _ }
       when ctx.in_establish &&
            (match List.assoc_opt name ctx.ctors with None -> true | _ -> false) &&
            (match env_lookup name (make_stdlib_env ()) with None -> true | _ -> false) ->
        (* In establish context, unknown uppercase constructors are proof predicates.
           Infer arg types for any side effects but return t_fact. *)
        List.iter (fun arg -> ignore (infer_expr ctx arg)) args;
        t_fact
     | EVar { name = "decodeAs"; loc } ->
        (* Infer normally so the (json:String) arg is checked and the result var
           can be pinned by surrounding unification, then decide-by-resolution.
           When the context later constrains the result (e.g. an annotated fn
           return), the check-path arm re-runs with the resolved type; this arm
           catches the truly-ambiguous standalone case. *)
        let result_ty = infer_direct_call base_fn args in
        (* A5 / review §6.3: DRIVE the result type from the literal type-name so
           HM unification enforces name==type at EVERY use.  Previously the result
           was a free var cross-checked non-strictly HERE (before surrounding
           unification pinned it), so `let x = decodeAs "Priority" j` pinned to a
           different type by a LATER use evaded the check entirely.  Unifying the
           result with the named concrete type turns a wrong-type use into an
           ordinary unification error at the use site.  Only fires for a literal
           type-name that resolves to a registered concrete type. *)
        (match args with
         | (ELit { lit = LString tn; _ }) :: _
           when List.mem_assoc tn ctx.records
                || List.mem_assoc tn ctx.adts
                || List.mem tn ctx.codec_decode_types ->
           unify_at ctx loc result_ty (TCon tn)
         | _ -> ());
        (* Infer-path: non-strict — see check_decodeAs_call. With the result now
           driven above, this still enforces the codec/name check. *)
        check_decodeAs_call ~strict:false ctx ~loc ~args
          ~result_ty:(apply !(ctx.subst) result_ty);
        apply !(ctx.subst) result_ty
     | EField { obj = (EConstructor { name = "Units"; args = []; _ }
                      | EVar { name = "Units"; _ }); field; _ }
       when lookup_name ctx ("Units." ^ field) = None ->
        (* First-Class Units, phase 3: the polymorphic dimension operations
           (Units.mul/div/square/sqrt/abs/negate/min/max/sum).  A dimension
           variable does not fit HM (abelian-group unification is non-unitary),
           so these are dimension-COMPUTED at each application site instead —
           argument dimensions are ground here, so the result dimension is
           plain exponent arithmetic.  Decide-by-resolution: stands down when
           the name resolves to a user binding.  Runtime bindings are ordinary
           Float functions in tesl/units.rkt (quantities erase). *)
        infer_units_op ctx (expr_loc app) field args
     | _ ->
        infer_direct_call base_fn args)
  | EBinop _ as binop ->
    (match grouped_query_type binop with
     | Some ty -> record_sql_operand_field_accesses ctx binop; ty
     | None ->
    match classify_lowered_query binop with
     | Some ty -> record_sql_operand_field_accesses ctx binop; ty
     | None ->
       let rec infer_check_chain_value = function
         | EBinop { op = BAnd; left; right; loc; _ } ->
            (match infer_check_chain_value left, infer_check_chain_value right with
             | Some left_ty, Some right_ty ->
                let arg_ty = fresh () in
                let ret_ty = fresh () in
                unify_at ctx loc left_ty (TFun (arg_ty, ret_ty));
                (* For check/establish combinations, only require same input type.
                   check returns T ::: P while establish returns Fact (Q) — both valid. *)
                let arg_ty_r = fresh () in
                let ret_ty_r = fresh () in
                unify_at ctx loc right_ty (TFun (arg_ty_r, ret_ty_r));
                unify_at ctx loc (apply !(ctx.subst) arg_ty) (apply !(ctx.subst) arg_ty_r);
                ignore ret_ty_r;
                Some (apply !(ctx.subst) (TFun (arg_ty, ret_ty)))
             | _ -> None)
         | other ->
            let ty = apply !(ctx.subst) (infer_expr ctx other) in
            match ty with
            | TFun _ -> Some ty
            | _ -> None
       in
       (match binop with
        | EBinop { op = BAnd; left; right; loc; op_loc } ->
           (match infer_check_chain_value binop with
            | Some ty -> ty
            | None -> infer_binop ctx loc ~op_loc BAnd left right)
        | EBinop { op; left; right; loc; op_loc } -> infer_binop ctx loc ~op_loc op left right
        | _ -> fresh ()))

  | EUnop { op; arg; loc } ->
    let arg_ty = infer_expr ctx arg in
    (match op with
     | UNeg ->
       (* Unary minus works on Int, Float, and dimensioned quantities (a
          negative length is a direction; the dimension is preserved).
          Money is rejected with a hint — use Money.negate. *)
       let resolved = apply !(ctx.subst) arg_ty in
       (match resolved with
        | TCon "Float" -> t_float
        | TCon q when Units_catalog.is_quantity_name q -> resolved
        | TCon "Money" ->
          add_error ctx loc
            "unary `-` is not defined for `Money`; use `Money.negate m`";
          resolved
        | _ ->
          unify_at ctx loc arg_ty t_int;
          t_int)
     | UNot ->
       unify_at ctx loc arg_ty t_bool;
       t_bool)

  | EIf { cond; then_; else_; loc } ->
    let cond_ty = infer_expr ctx cond in
    unify_at ctx loc cond_ty t_bool;
    let then_ty = infer_expr ctx then_ in
    let else_ty = infer_expr ctx else_ in
    unify_at ctx loc then_ty else_ty;
    apply !(ctx.subst) then_ty

  | ECase { scrut; arms; loc } ->
    (* ── Exhaustiveness helper (defined inline to close over ctx/loc) ──────── *)
    let stdlib_ctors_for_type = function
      | "Bool"         -> Some ["True"; "False"]
      | "Maybe"        -> Some ["Nothing"; "Something"]
      | "Either"       -> Some ["Left"; "Right"]
      | "Result"       -> Some ["Ok"; "Err"]
      | "DeleteResult" -> Some ["NoRowDeleted"; "RowsDeleted"]
      | _              -> None
    in
    let all_ctors_for_type type_name =
      match stdlib_ctors_for_type type_name with
      | Some ctors -> ctors
      | None ->
        (match List.assoc_opt type_name ctx.adts with
         | Some ad -> List.map fst ad.ad_variants
         | None ->
           (* Imported local ADT: collect constructor names by type name.
              Both plain and qualified names may be present (e.g. "RoleAdmin"
              and "KanelModels.RoleAdmin"); keep only unqualified names to
              avoid false "missing" reports when arms use plain patterns. *)
           List.filter_map (fun (ctor_name, (tn, _)) ->
             if tn = type_name && not (String.contains ctor_name '.') then
               Some ctor_name
             else None
           ) ctx.ctors)
    in
    let check_exhaustiveness scrut_ty =
      let resolved = apply !(ctx.subst) scrut_ty in
      let type_name_opt = match resolved with
        | TCon n -> Some n
        | TApp (TCon n, _) | TApp (TApp (TCon n, _), _) -> Some n
        | _ -> None
      in
      match type_name_opt with
      | None -> ()  (* can't determine type, skip *)
      | Some type_name ->
        let all_ctors = all_ctors_for_type type_name in
        if all_ctors = [] then ()  (* no known constructors (e.g. Int, String) *)
        else begin
          (* A wildcard (PVar or PWild) without a guard covers everything remaining *)
          let has_catchall = List.exists (fun (arm : case_arm) ->
            arm.guard = None &&
            (match arm.pattern with PVar _ | PWild -> true | _ -> false)
          ) arms in
          if not has_catchall then begin
            (* Collect constructors covered by arms without guards.
               Both PCon (with fields) and PNullary (no fields) count. *)
            let covered = List.filter_map (fun (arm : case_arm) ->
              if arm.guard = None then
                match arm.pattern with
                | PCon { ctor; _ } | PNullary { ctor; _ } -> Some ctor
                | _ -> None
              else None
            ) arms in
            let missing = List.filter (fun c -> not (List.mem c covered)) all_ctors in
            if missing <> [] then
              add_error ctx loc
                (Printf.sprintf "non-exhaustive case expression: missing %s for type `%s`\n\
                                 Hint: add %s or a wildcard branch `_ -> ...`"
                   (String.concat ", " (List.map (fun c -> Printf.sprintf "`%s`" c) missing))
                   type_name
                   (if List.length missing = 1 then "a branch for " ^ List.hd missing
                    else "branches for " ^ String.concat ", " missing))
          end
        end
    in
    let scrut_ty = infer_expr ctx scrut in
    (* When the scrutinee is a named variable carrying a proof (e.g. from a
       RetMaybeAttached or RetAttached return), propagate that proof into the
       `Something val` arm binding.  This is the mechanism that makes
       `case maybePos n of Something v -> needPos v` work without attachFact. *)
    let scrut_name_opt = match scrut with EVar { name; _ } -> Some name | _ -> None in
    let scrut_proof_opt = match scrut_name_opt with
      | Some sn -> List.assoc_opt sn ctx.binding_meta_env
      | None    -> None
    in
    let result_ty = fresh () in
    List.iter (fun (arm : case_arm) ->
      let arm_env = bind_pattern_vars ctx scrut_ty arm.pattern in
      (* If scrut carries a proof and this arm binds the inner value with a
         single-field constructor (Something, Right, CustomRight, etc.),
         propagate the proof renamed from the scrut name to the arm variable. *)
      let extra_meta = match scrut_proof_opt, scrut_name_opt, arm.pattern with
        | Some (AttachedProofBinding proof), Some scrut_name,
          PCon { fields = [(_, PVar arm_var)]; _ } ->
          (* Propagate proof to any single-field constructor arm (Something, Right, CustomRight, etc.) *)
          [(arm_var, AttachedProofBinding (rename_proof_name scrut_name arm_var proof))]
        | _ -> []
      in
      (* When propagating proof into a `Something v` arm, the arm variable `v`
         should be treated as its own proof subject (not aliased to the outer
         scrutinee subject). This ensures `needPos v` resolves as `IsPositive v`
         rather than `IsPositive m` (where `m` is the outer let binder). *)
      let extra_subjects = match extra_meta with
        | [(arm_var, _)] -> [(arm_var, [arm_var])]
        | _ -> []
      in
      let ctx' = { ctx with
        env = arm_env @ ctx.env;
        binding_meta_env = extra_meta @ ctx.binding_meta_env;
        subject_chain_env = extra_subjects @ ctx.subject_chain_env;
      } in
      (match arm.guard with
       | Some guard ->
         let guard_ty = infer_expr ctx' guard in
         unify_at ctx (expr_loc guard) guard_ty t_bool
       | None -> ());
      let body_ty = infer_expr ctx' arm.body in
      record_pattern_bindings ~extra_meta ctx arm.loc arm_env;
      unify_at ctx loc result_ty body_ty
    ) arms;
    (* Check exhaustiveness after all arm types are resolved *)
    check_exhaustiveness scrut_ty;
    apply !(ctx.subst) result_ty

  | ELet { name = "_"; value = first_expr; _ } as seq
    when (let rec is_update_and_return = function
            | EApp { fn; _ } -> is_update_and_return fn
            | EVar { name; _ } -> name = "updateAndReturnOne"
            | _ -> false
          in is_update_and_return first_expr) ->
    (* updateAndReturnOne chain: the whole sequence has a fresh return type
       (the actual entity type), since set/where return Unit but the emitted
       Racket wraps with (car (update-many! ...)) *)
    let rec walk_seq = function
      | ELet { name = "_"; value; body; _ } ->
        ignore (infer_expr ctx value);
        walk_seq body
      | other -> ignore (infer_expr ctx other)
    in
    walk_seq seq;
    fresh ()

  | ELet { name; declared_type; value; body; loc; declared_proof = _ } ->
    let value_ty =
      match declared_type with
      | Some declared_type ->
        let expected_ty = ty_of_type_expr declared_type in
        let inferred_ty = infer_expr ctx value in
        unify_expected_at ctx (expr_loc value) inferred_ty
          (mk_expectation ~origin:loc ~role:(LetBinding name)
            ~reason:(local_let_reason name expected_ty) expected_ty);
        apply !(ctx.subst) expected_ty
      | None -> infer_expr ctx value
    in
    (* Generalize: let-polymorphism *)
    let env_fv = free_vars_env ctx.env in
    let sch = generalize env_fv !(ctx.subst) value_ty in
    let ctx' = { ctx with env = env_extend name sch ctx.env } in
    infer_expr ctx' body

  | ELetProof { value_name; proof_name; value; body; loc = _; _ } ->
    (* Proof decompose: let (x ::: p) = y — type of body, with x and p bound *)
    let value_ty = infer_expr ctx value in
    let sch = generalize (free_vars_env ctx.env) !(ctx.subst) value_ty in
    let env' = env_extend proof_name (mono t_fact) (env_extend value_name sch ctx.env) in
    let ctx' = { ctx with env = env' } in
    infer_expr ctx' body

  | ERecord { fields; type_hint; loc } ->
    (match type_hint with
     | Some type_name ->
       (* Typed record literal: { field: val } with known type_name — type-check each field *)
       (match List.assoc_opt type_name ctx.records with
        | Some rd ->
          (* Check for missing fields *)
          let provided_field_names = List.map fst fields in
          List.iter (fun (def_name, _def_ty) ->
            if not (List.mem def_name provided_field_names) then
              add_error ctx loc
                (Printf.sprintf "record `%s` is missing required field `%s`" type_name def_name)
          ) rd.rd_fields;
          (* Type-check provided fields and catch unknown fields *)
          List.iter (fun (field_name, value_expr) ->
            match List.assoc_opt field_name rd.rd_fields with
            | Some field_ty -> ignore (infer_expr ctx value_expr |> fun actual ->
                unify_at ctx (expr_loc value_expr) actual field_ty; actual)
            | None ->
              add_error ctx (expr_loc value_expr)
                (Printf.sprintf "record type `%s` has no field `%s`" type_name field_name);
              ignore (infer_expr ctx value_expr)
          ) fields;
          TCon type_name
        | None ->
          (* type_hint set but not a known record — infer fields and return opaque *)
          List.iter (fun (_, e) -> ignore (infer_expr ctx e)) fields;
          TCon type_name)
     | None ->
       (* Bare record literal without type name: error unless in record-update context *)
       (* Note: record updates are EApp { fn = EVar "#record-update#"; arg = ERecord{__base__} }
          which are caught separately before this branch *)
       add_error ctx loc
         "bare record literal: every record must be prefixed with its type name.\n\
          \  Use: TypeName { field: value, ... }\n\
          \  Example: Point { x: 0, y: 0 }";
       List.iter (fun (_, e) -> ignore (infer_expr ctx e)) fields;
       fresh ())

  | EList { elems; loc } ->
    (match elems with
     | [] -> t_list (fresh ())
     | _ ->
        let elem_ty = fresh () in
        List.iter (fun e ->
          let t = infer_expr ctx e in
          unify_at ctx loc elem_ty t
        ) elems;
        t_list (apply !(ctx.subst) elem_ty))

  | EOk { value; proof; loc } ->
    let ty = infer_expr ctx value in
    (* Verify conjunction proofs against the value's tracked binding meta.
       When the programmer writes ok xs ::: P && Q (or ok xs ::: ForAll (P && Q)),
       check that xs was actually established with both P and Q — not just one of them.
       This catches forged conjunctions like filterCheck checkP xs ::: P && Q. *)
    let strip_outer_parens s =
      let s = String.trim s in
      let n = String.length s in
      if n >= 2 && s.[0] = '(' && s.[n-1] = ')' then String.trim (String.sub s 1 (n-2))
      else s
    in
    let actual_proof_str =
      match binding_meta_of_expr ctx value with
      | Some (AttachedProofBinding p) -> Some (pp_proof_expr p)
      | _ -> None
    in
    (match proof, actual_proof_str with
     | PredAnd _, Some actual ->
       (* Direct conjunction: ok x ::: P && Q — value must carry P && Q *)
       if actual <> pp_proof_expr proof then
         add_error ctx loc (Printf.sprintf
           "ok proof `%s` claims a conjunction, but value has established proof `%s`; \
            use checkBoth or a combined check to establish all conjuncts"
           (pp_proof_expr proof) actual)
     | PredApp { pred = "ForAll"; args = [inner_str]; _ }, Some actual ->
       (* ForAll conjunction: ok xs ::: ForAll (P && Q) — value must carry ForAll (P && Q) *)
       let inner = strip_outer_parens inner_str in
       if actual <> inner && ("ForAll " ^ inner_str) <> actual && ("ForAll (" ^ inner ^ ")") <> actual then
         add_error ctx loc (Printf.sprintf
           "ok proof `ForAll (%s)` claims all elements satisfy `%s`, but value has established proof `%s`; \
            use List.filterCheck with a check function that establishes all conjuncts"
           inner inner actual)
     | _ -> ());
    ty

  | EFail { message; _ } ->
    let msg_ty = infer_expr ctx message in
    unify_at ctx (expr_loc message) msg_ty t_string;
    fresh ()  (* fail : any type (unreachable after this point) *)

  | ETelemetry { fields; _ } ->
    (* Telemetry itself is Unit, but the attribute VALUE expressions are real
       expressions: infer them so their types and field accesses are recorded
       for hover / type-at (otherwise hovering on `record.field` inside a
       telemetry block reports the enclosing Unit). *)
    List.iter (fun (_, v) -> ignore (infer_expr ctx v)) fields;
    t_unit
  | EEnqueue { payload; _ } ->
    ignore (infer_expr ctx payload);
    t_unit
  | EPublish { key; payload; _ } ->
    Option.iter (fun e -> ignore (infer_expr ctx e)) key;
    Option.iter (fun e -> ignore (infer_expr ctx e)) payload;
    t_unit
  | EStartWorkers _ -> t_unit
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    infer_expr ctx body
  | EServe _ -> t_unit
  | ECacheGet { cache_name; key; loc } ->
    let key_ty = infer_expr ctx key in
    unify_at ctx loc key_ty t_string;
    (* Look up the declared value type for this cache *)
    let val_ty = match List.assoc_opt ("__cache_" ^ cache_name) ctx.env with
      | Some s -> s.mono
      | None -> fresh ()
    in
    t_maybe val_ty
  | ECacheSet { cache_name; key; value; ttl; loc } ->
    let key_ty = infer_expr ctx key in
    unify_at ctx loc key_ty t_string;
    let val_ty = infer_expr ctx value in
    (* Check against declared type if available *)
    (match List.assoc_opt ("__cache_" ^ cache_name) ctx.env with
     | Some s -> unify_at ctx loc val_ty s.mono
     | None -> ());
    Option.iter (fun ttl_expr ->
      let ttl_ty = infer_expr ctx ttl_expr in
      unify_at ctx loc ttl_ty t_int
    ) ttl;
    t_unit
  | ECacheDelete { key; loc; _ } ->
    let key_ty = infer_expr ctx key in
    unify_at ctx loc key_ty t_string;
    t_unit
  | ECacheInvalidate { prefix; loc; _ } ->
    let pfx_ty = infer_expr ctx prefix in
    unify_at ctx loc pfx_ty t_string;
    t_unit

  | ESendEmail { to_; subject; body; loc; _ } ->
    let to_ty      = infer_expr ctx to_ in
    unify_at ctx loc to_ty t_string;
    let subj_ty    = infer_expr ctx subject in
    unify_at ctx loc subj_ty t_string;
    let body_ty    = infer_expr ctx body in
    unify_at ctx loc body_ty (TCon "EmailBody");
    t_unit

  | EStartEmailWorker { loc = _; _ } ->
    t_unit

  | EConstructor { name; args; loc } ->
    (match resolve_constructor_type ctx name loc with
     | ProofPredicateConstructor ->
       List.iter (fun arg -> ignore (infer_expr ctx arg)) args;
       t_fact
     | KnownConstructor ctor_ty ->
       List.fold_left (fun fn_ty arg ->
         let arg_ty = infer_expr ctx arg in
         let ret_ty = fresh () in
         unify_at ctx loc fn_ty (TFun (arg_ty, ret_ty));
         apply !(ctx.subst) ret_ty
       ) ctor_ty args)

  | ELambda { params; body; loc = _ } ->
    let param_tys = List.map (fun (b : binding) -> (b.name, ty_of_type_expr b.type_expr)) params in
    let param_schemes = List.map (fun (n, t) -> (n, mono t)) param_tys in
    let ctx' = { ctx with env = param_schemes @ ctx.env } in
    let body_ty = infer_expr ctx' body in
    List.fold_right (fun (_, t) acc -> TFun (t, acc)) param_tys body_ty
  | ERuntimeCall { segments; _ } ->
    (* Desugar-only node: never present during type-checking (desugar runs
       AFTER the checker).  Infer children defensively, result is Unit. *)
    List.iter (function RLit _ | RRawVar _ -> () | RArg e -> ignore (infer_expr ctx e)) segments;
    t_unit
  in
  let expr_meta = match binding_meta_of_expr ctx e with Some m -> m | None -> PlainBinding in
  record_expr_type_with_meta ctx (expr_loc e) inferred expr_meta;
  inferred

(* Ambiguous-dot where-clause hint (issue #26/#27 follow-up): a lowered SQL
   query with a `where` comparison is EBinop-headed and typed structurally by
   [classify_lowered_query], which never infers the comparison operands — so a
   field read in a VALUE operand (`where o.name == pr.name` → `pr.name`) gets
   no [field_accesses] entry, the emitter's field_access_type_tbl misses, and
   [emit_field_dot] emits the bare 2-arg `(tesl-dot/runtime pr 'name)`, which
   traps at runtime when the field name is shared across entities/records.
   This pass re-walks the lowered query, binds the select binder to its entity
   type, and infers every field read on the VALUE side of each comparison —
   for the [field_accesses] side effect only (errors rolled back, so it can
   never reject a program).  The COLUMN side (comparison left) is emitted as
   `entity-field-ref` and needs no hint, so it is skipped. *)
and record_sql_operand_field_accesses ctx query =
  (* Binder + entity of the lowered query, mirroring the emitter's
     parse_select_seed / parse_update_start / parse_delete_seed shapes. *)
  let entity_name_of = function
    | EConstructor { name; args = []; _ } | EVar { name; _ } -> Some name
    | _ -> None
  in
  let rec binder_entity e =
    match e with
    | EBinop { left; right; _ } ->
      (match binder_entity left with
       | Some r -> Some r
       | None -> binder_entity right)
    | _ ->
      (match flatten_app_expr [] e with
       | (EBinop _ as base), _ :: _ -> binder_entity base
       | EVar { name = ("select" | "selectOne" | "selectCount"); _ },
         EVar { name = binder; _ } :: EVar { name = "from"; _ } :: entity_expr :: _
       | EVar { name = ("delete" | "deleteAndReturnResult"); _ },
         EVar { name = binder; _ } :: EVar { name = "from"; _ } :: entity_expr :: _
       | EVar { name = ("update" | "updateAndReturnOne"); _ },
         EVar { name = binder; _ } :: EVar { name = "in"; _ } :: entity_expr :: _
       | EVar { name = ("selectSum" | "selectMax" | "selectMin"); _ },
         EField { obj = EVar { name = binder; _ }; _ }
         :: EVar { name = "from"; _ } :: entity_expr :: _ ->
         Option.map (fun entity -> (binder, entity)) (entity_name_of entity_expr)
       | _ -> None)
  in
  match binder_entity query with
  | Some (binder, entity) when List.mem_assoc entity ctx.records ->
    let ctx' = { ctx with env = env_extend binder (mono (TCon entity)) ctx.env } in
    (* Infer only the EField nodes of a value operand — inferring the whole
       `col == value` would re-enter classify_lowered_query and skip the value
       side again.  Outermost EField per subtree suffices: inferring it infers
       (and records) any nested field reads. *)
    let record_fields_in value =
      let rec walk e =
        match e with
        | EField _ ->
          let saved_errors = !(ctx'.errors) in
          ignore (infer_expr ctx' e);
          ctx'.errors := saved_errors
        | _ -> Ast_visitor.iter_children walk e
      in
      walk value
    in
    let rec scan e =
      match e with
      | EBinop { op = (BAnd | BOr | BAdd); left; right; _ } ->
        scan left; scan right
      | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe); left; right; _ } ->
        scan left;              (* left is the column or the select app-chain *)
        record_fields_in right  (* right is the VALUE operand *)
      | EApp _ ->
        (* Multi-line SQL: modifier clauses merged as EApp args onto the
           where-EBinop — recurse into the EBinop base. *)
        (match flatten_app_expr [] e with
         | (EBinop _ as base), _ :: _ -> scan base
         | _ -> ())
      | _ -> ()
    in
    scan query
  | _ -> ()

and infer_lit = function
  | LInt _    -> t_int
  | LBigInt _ -> t_int   (* A9/HM-1: arbitrary-precision Int literal *)
  | LFloat _  -> t_float
  | LBool _   -> t_bool
  | LString _ -> t_string
  | LInterp _ -> t_string  (* interpolated strings are always String *)

and infer_binop ctx loc ~op_loc op left right =
  let lt = infer_expr ctx left in
  let rt = infer_expr ctx right in
  match op with
  | BAdd | BSub | BMul | BDiv | BMod ->
    let lt' = apply !(ctx.subst) lt in
    let rt' = apply !(ctx.subst) rt in
    (* D8 idiom-transfer hint: `+` on a String is the classic TS/Python/Java
       transfer mistake.  Emit ONE clear "use `++`" error and short-circuit to
       [String] so the caller does not then see three cascading "unify String
       with Int" errors.  D9: the binop loc covers the whole `a + b` expression
       and the `+` token has no loc of its own, so the fix relocates it in the
       source — the first `+` strictly between the operands — and ships only
       when that verification succeeds. *)
    if op = BAdd && (lt' = TCon "String" || rt' = TCon "String") then begin
      add_error_fix ctx loc
        "operator `+` is not defined for `String`; use `++` for string \
         concatenation (Tesl reserves `+` for numeric addition)"
        (Diag_fix.verified_token_replace ~source_lines:ctx.source_lines
           ~at:op_loc.start ~token:"+" ~replacement:"++");
      t_string
    end else if lt' = TCon "Money" || rt' = TCon "Money" then begin
      (* Money never meets a raw arithmetic operator: same-currency safety is
         proof-gated in the named ops.  One clear error, short-circuit to Money
         so the caller sees no cascading unify noise. *)
      (match op with
       | BAdd ->
         add_error ctx loc
           "operator `+` is not defined for `Money`; use `Money.add a b` \
            (requires a `SameCurrency a b` proof — mint it with \
            `Money.requireSameCurrency a b`)"
       | BSub ->
         add_error ctx loc
           "operator `-` is not defined for `Money`; use `Money.subtract a b` \
            (requires a `SameCurrency a b` proof — mint it with \
            `Money.requireSameCurrency a b`)"
       | BMul | BDiv | BMod ->
         add_error ctx loc
           (Printf.sprintf
              "operator `%s` is not defined for `Money` (money times money is \
               meaningless); scale by an integer with `Money.scale m k`"
              (match op with BMul -> "*" | BDiv -> "/" | _ -> "%"))
       | _ -> ());
      TCon "Money"
    end else begin
      (* First-Class Units: the dimensioned-quantity algebra.  This branch
         MUST run before the unify-to-num_ty default below — that unify would
         collapse a quantity operand to Float and silently lose the dimension.
         `*` adds exponent vectors, `/` subtracts them, `+`/`-` require equal
         dimensions; a dimensionless result collapses back to plain Float. *)
      let dim_of t = match t with
        | TCon n -> Units_catalog.dim_of_name n
        | _ -> None
      in
      let disp d = Units_catalog.display_name d in
      let quantity_or_float d =
        if Units_catalog.dim_is_zero d then t_float else t_quantity d
      in
      (* The scalar side of a mixed scalar×quantity op must be Float; an Int
         literal is the common slip, so it gets a targeted hint instead of a
         bare unify error. *)
      let require_float_scalar side_ty side_expr =
        match apply !(ctx.subst) side_ty with
        | TCon "Int" ->
          add_error ctx (expr_loc side_expr)
            "a quantity is scaled by a `Float`, not an `Int` — write a Float \
             literal (`2.0`, not `2`)"
        | _ -> unify_at ctx loc side_ty t_float
      in
      match dim_of lt', dim_of rt' with
      | Some dl, Some dr ->
        (match op with
         | BMul -> quantity_or_float (Units_catalog.dim_add dl dr)
         | BDiv -> quantity_or_float (Units_catalog.dim_sub dl dr)
         | BAdd | BSub ->
           if dl = dr then t_quantity dl
           else begin
             add_error ctx loc (Printf.sprintf
               "cannot %s quantities of different dimension: `%s` and `%s` \
                (dimensions must match exactly; convert first)"
               (if op = BAdd then "add" else "subtract")
               (disp dl) (disp dr));
             t_quantity dl   (* fail-closed: keep the LHS dimension *)
           end
         | BMod ->
           add_error ctx loc (Printf.sprintf
             "operator `%%` is not defined for dimensioned quantities (`%s`)"
             (disp dl));
           t_quantity dl
         | BConcat | BAnd | BOr | BEq | BNeq | BLt | BLe | BGt | BGe ->
           (* unreachable: the outer match restricts op to arithmetic *)
           t_quantity dl)
      | Some d, None ->
        (match op with
         | BMul | BDiv ->
           (* quantity × scalar / quantity ÷ scalar keeps the dimension *)
           require_float_scalar rt right;
           t_quantity d
         | BAdd | BSub ->
           add_error ctx loc (Printf.sprintf
             "cannot %s a dimensioned quantity (`%s`) and a dimensionless \
              number; wrap the number in a unit constructor first"
             (if op = BAdd then "add" else "subtract") (disp d));
           t_quantity d
         | BMod ->
           add_error ctx loc "operator `%` is not defined for dimensioned quantities";
           t_quantity d
         | BConcat | BAnd | BOr | BEq | BNeq | BLt | BLe | BGt | BGe ->
           t_quantity d)
      | None, Some d ->
        (match op with
         | BMul ->
           require_float_scalar lt left;
           t_quantity d
         | BDiv ->
           (* scalar / quantity INVERTS the dimension (1/s, 1/m, …) *)
           require_float_scalar lt left;
           quantity_or_float (Units_catalog.dim_neg d)
         | BAdd | BSub ->
           add_error ctx loc (Printf.sprintf
             "cannot %s a dimensionless number and a dimensioned quantity \
              (`%s`); wrap the number in a unit constructor first"
             (if op = BAdd then "add" else "subtract") (disp d));
           t_quantity d
         | BMod ->
           add_error ctx loc "operator `%` is not defined for dimensioned quantities";
           t_quantity d
         | BConcat | BAnd | BOr | BEq | BNeq | BLt | BLe | BGt | BGe ->
           t_quantity d)
      | None, None ->
        let num_ty = match lt', rt' with
          | TCon "Float", _ | _, TCon "Float" -> t_float
          | _ -> t_int
        in
        unify_at ctx loc lt num_ty;
        unify_at ctx loc rt num_ty;
        num_ty
    end
  | BConcat ->
    unify_at ctx loc lt t_string;
    unify_at ctx loc rt t_string;
    t_string
  | BAnd ->
    let lt' = apply !(ctx.subst) lt in
    let rt' = apply !(ctx.subst) rt in
    (match lt', rt' with
     | TCon "Fact", TCon "Fact" -> t_fact
     | _ ->
       unify_at ctx loc lt t_bool;
       unify_at ctx loc rt t_bool;
       t_bool)
  | BOr ->
    unify_at ctx loc lt t_bool;
    unify_at ctx loc rt t_bool;
    t_bool
  | BEq | BNeq ->
    unify_at ctx loc lt rt;
    let t = apply !(ctx.subst) lt in
    if ty_is_ground t then begin
      if not (ty_is_eq ctx t) then
        add_error ctx loc (Printf.sprintf
          "equality operator `%s` is not defined for type `%s` \
           (only types without a function component can be compared for equality)"
          (cmp_op_name op) (pp_ty t))
    end else
      (* Generic operand: capture an Eq obligation on this type, discharged at
         each call site once the type is concrete (Eq/Ord Stage 3). *)
      ctx.ord_eq_acc := (PEq, t) :: !(ctx.ord_eq_acc);
    t_bool
  | BLt | BLe | BGt | BGe ->
    unify_at ctx loc lt rt;
    let t = apply !(ctx.subst) lt in
    if ty_is_ground t then begin
      if not (ty_is_ord ctx t) then
        if t = TCon "Money" then
          add_error ctx loc (Printf.sprintf
            "ordering operator `%s` is not defined for `Money` (ordering \
             across currencies is undefined); use `Money.compare a b` — it \
             requires a `SameCurrency a b` proof"
            (cmp_op_name op))
        else
          add_error ctx loc (Printf.sprintf
            "ordering operator `%s` is not defined for type `%s` \
             (only Int, Float, PosixMillis, dimensioned quantities, and \
             newtypes over them are ordered; compare a numeric representation \
             instead)"
            (cmp_op_name op) (pp_ty t))
    end else
      ctx.ord_eq_acc := (POrd, t) :: !(ctx.ord_eq_acc);
    t_bool

(* First-Class Units, phase 3 — application-site typing of the polymorphic
   dimension operations.  Argument dimensions are ground at every call, so the
   result dimension is computed with plain exponent arithmetic; a Float operand
   is the dimensionless case.  A dimensionless RESULT collapses to Float.
   Fail-closed: any operand that is neither a quantity nor a Float is an error
   (never routed to the Int/Float default). *)
and infer_units_op ctx loc field args =
  let disp = Units_catalog.display_name in
  let quantity_or_float d =
    if Units_catalog.dim_is_zero d then t_float else t_quantity d in
  (* classify one argument: quantity dim | dimensionless Float | bad *)
  let arg_dim e =
    let t = apply !(ctx.subst) (infer_expr ctx e) in
    match t with
    | TCon n when Units_catalog.is_quantity_name n ->
      (match Units_catalog.dim_of_name n with
       | Some d -> `Dim d
       | None -> `Other t)
    | TCon "Float" -> `Dimless
    | TCon "Int" ->
      add_error ctx (expr_loc e)
        (Printf.sprintf
           "`Units.%s` scales with `Float`, not `Int` — write a Float literal \
            (`2.0`, not `2`)" field);
      `Dimless
    | TVar _ ->
      (* monomorphic phase: an un-ground operand pins to Float *)
      unify_at ctx (expr_loc e) t t_float; `Dimless
    | other ->
      add_error ctx (expr_loc e)
        (Printf.sprintf
           "`Units.%s` expects a dimensioned quantity (or a Float scalar), \
            got `%s`" field (pp_ty other));
      `Other other
  in
  let dim_or_zero = function
    | `Dim d -> d
    | `Dimless | `Other _ -> Units_catalog.dimensionless in
  let arity_error n =
    add_error ctx loc (Printf.sprintf
      "`Units.%s` expects %d argument%s" field n (if n = 1 then "" else "s"));
    List.iter (fun a -> ignore (infer_expr ctx a)) args;
    fresh () in
  match field, args with
  | "mul", [a; b] ->
    quantity_or_float
      (Units_catalog.dim_add (dim_or_zero (arg_dim a)) (dim_or_zero (arg_dim b)))
  | "div", [a; b] ->
    quantity_or_float
      (Units_catalog.dim_sub (dim_or_zero (arg_dim a)) (dim_or_zero (arg_dim b)))
  | "square", [a] ->
    quantity_or_float (Units_catalog.dim_scale 2 (dim_or_zero (arg_dim a)))
  | "sqrt", [a] ->
    let d = dim_or_zero (arg_dim a) in
    if Units_catalog.dim_all_even d then
      quantity_or_float (Units_catalog.dim_halve d)
    else begin
      add_error ctx loc (Printf.sprintf
        "`Units.sqrt` is only defined when every dimension exponent is even; \
         `%s` has an odd exponent (the square root of `%s` is not a physical \
         quantity)" (disp d) (disp d));
      fresh ()
    end
  | ("abs" | "negate" | "requireNonZero"), [a] ->
    (* requireNonZero: check fn minting FloatNonZero (quantities erase to
       Float, so the SAME predicate that guards Float division applies) —
       typing is same-quantity in/out; the proof side lives in
       stdlib_func_infos. *)
    (match arg_dim a with
     | `Dim d -> t_quantity d
     | `Dimless -> t_float
     | `Other _ -> fresh ())
  | ("min" | "max"), [a; b] ->
    (match arg_dim a, arg_dim b with
     | `Dim da, `Dim db when da = db -> t_quantity da
     | `Dimless, `Dimless -> t_float
     | `Dim da, `Dim db ->
       add_error ctx loc (Printf.sprintf
         "`Units.%s` needs both arguments in the SAME dimension: `%s` vs `%s`"
         field (disp da) (disp db));
       t_quantity da
     | `Dim d, `Dimless | `Dimless, `Dim d ->
       add_error ctx loc (Printf.sprintf
         "`Units.%s` needs both arguments in the SAME dimension: `%s` vs a \
          dimensionless Float" field (disp d));
       t_quantity d
     | _ -> fresh ())
  | "sum", [xs] ->
    let t = apply !(ctx.subst) (infer_expr ctx xs) in
    (match t with
     | TApp (TCon "List", TCon n) when Units_catalog.is_quantity_name n ->
       TCon n
     | TApp (TCon "List", TCon "Float") -> t_float
     | other ->
       add_error ctx (expr_loc xs) (Printf.sprintf
         "`Units.sum` expects a `List` of dimensioned quantities (one known \
          dimension), got `%s`" (pp_ty other));
       fresh ())
  | ("mul" | "div" | "min" | "max"), _ -> arity_error 2
  | ("square" | "sqrt" | "abs" | "negate" | "sum" | "requireNonZero"), _ ->
    arity_error 1
  | other, _ ->
    add_error ctx loc (Printf.sprintf
      "unknown Units operation `Units.%s` (available: mul, div, square, sqrt, \
       abs, negate, min, max, sum, requireNonZero)" other);
    List.iter (fun a -> ignore (infer_expr ctx a)) args;
    fresh ()

and unwind_fun_type ty =
  match ty with
  | TFun (arg_ty, rest_ty) ->
    let arg_tys, result_ty = unwind_fun_type rest_ty in
    (arg_ty :: arg_tys, result_ty)
  | other -> ([], other)

and bind_pattern_vars ctx scrut_ty (pat : pattern) : (string * scheme) list =
  let scrut_ty = apply !(ctx.subst) scrut_ty in
  let fresh_sub_bindings sub_pat field_ty =
    let field_ty' = apply !(ctx.subst) field_ty in
    bind_pattern_vars ctx field_ty' sub_pat
  in
  let fresh_field_bindings fields =
    List.concat_map (fun (_, sub_pat) ->
      match sub_pat with
      | PVar var_name -> [(var_name, mono (fresh ()))]
      | PWild | PLit _ | PNullary _ -> []
      | PCon _ -> bind_pattern_vars ctx (fresh ()) sub_pat
    ) fields
  in
  let bind_constructor_pattern ctor fields loc =
    match resolve_constructor_type ctx ctor loc with
    | ProofPredicateConstructor -> fresh_field_bindings fields
    | KnownConstructor ctor_ty ->
      let (field_tys, result_ty) = unwind_fun_type ctor_ty in
      (match unify !(ctx.subst) scrut_ty result_ty with
       | subst' ->
         ctx.subst := subst';
         let n_fields = List.length fields in
         let n_tys = List.length field_tys in
         if n_fields = n_tys then
           List.concat_map (fun ((_, sub_pat), field_ty) ->
             fresh_sub_bindings sub_pat (apply !(ctx.subst) field_ty)
           ) (List.combine fields field_tys)
         else
           fresh_field_bindings fields
       | exception TypeMismatch _ ->
         add_unknown_name_error ctx loc ~what:"constructor" ctor;
         fresh_field_bindings fields)
  in
  match pat with
  | PVar n -> [(n, mono scrut_ty)]
  | PWild | PLit _ -> []
  | PNullary { ctor; loc } ->
    ignore (bind_constructor_pattern ctor [] loc);
    []
  | PCon { ctor; fields; loc } -> bind_constructor_pattern ctor fields loc

and record_pattern_bindings ?(extra_meta = []) ctx loc (bindings : (string * scheme) list) : unit =
  List.iter (fun (name, sch) ->
    let meta = match List.assoc_opt name extra_meta with
      | Some m -> m
      | None -> PlainBinding
    in
    record_local_binding ctx name loc sch.mono meta
  ) bindings

(* ── Statement sequence inference ────────────────────────────────────────── *)

(** Infer a statement sequence (for function bodies with multiple statements). *)
let rec infer_stmt ctx (e : expr) : ty * ctx =
  match e with
  | ELet {
      name = "_";
      declared_type = _;
      declared_proof = _;
      value = EVar { name = "set"; _ };
      body = ELet { name = "_"; declared_type = _; declared_proof = _; value = EField _; body; loc = _ };
      loc = _;
    } ->
    infer_stmt ctx body
  | ELet { name = "_"; value = first_expr; _ } as seq
    when (let rec is_update_and_return = function
            | EApp { fn; _ } -> is_update_and_return fn
            | EVar { name; _ } -> name = "updateAndReturnOne"
            | _ -> false
          in is_update_and_return first_expr) ->
    (* updateAndReturnOne chain returns a fresh entity type, not Unit *)
    let ty = infer_expr ctx seq in
    (ty, ctx)
  | ELet { name = "_"; value; body; loc; _ }
    when (match fst (flatten_app_expr [] value) with
          | EVar { name = "check"; _ } -> true
          | _ -> false) ->
    (* Bare `check f(n)` without a let binding: the validation result is silently
       discarded and there is no stable subject name to attach the proof to. *)
    add_error ctx loc
      "bare `check` call: the result must be bound with `let x = check f(n)` \
       — without a binding there is no subject to attach the proof to, and the \
       validation result is silently discarded";
    infer_stmt ctx body
  | ELet { name; declared_type; value; body; loc; declared_proof = _ } ->
    let value_ty =
      match declared_type with
      | Some declared_type ->
        let expected_ty = ty_of_type_expr declared_type in
        let inferred_ty = infer_expr ctx value in
        unify_expected_at ctx (expr_loc value) inferred_ty
          (mk_expectation ~origin:loc ~role:(LetBinding name)
            ~reason:(local_let_reason name expected_ty) expected_ty);
        apply !(ctx.subst) expected_ty
      | None -> infer_expr ctx value
    in
    let meta = binding_meta_for_binding ctx name value in
    let subject_chain = binding_subject_chain ctx name value in
    let hover_note = hover_note_for_meta ((name, subject_chain) :: ctx.subject_chain_env) name meta in
    record_local_binding ?hover_note ctx name loc value_ty meta;
    let env_fv = free_vars_env ctx.env in
    let sch = generalize env_fv !(ctx.subst) value_ty in
    let ctx' = {
      ctx with
      env = env_extend name sch ctx.env;
      binding_meta_env = (name, meta) :: ctx.binding_meta_env;
      subject_chain_env = (name, subject_chain) :: ctx.subject_chain_env;
    } in
    infer_stmt ctx' body
  | ELetProof { value_name; proof_name; proof_index; value; body; loc; _ } ->
    let value_ty = infer_expr ctx value in
    let sch = generalize (free_vars_env ctx.env) !(ctx.subst) value_ty in
    let value_meta = PlainBinding in
    let subject_chain = binding_subject_chain ctx value_name value in
    let value_hover_note = hover_note_for_meta ((value_name, subject_chain) :: ctx.subject_chain_env) value_name value_meta in
    record_local_binding ?hover_note:value_hover_note ctx value_name loc value_ty value_meta;
    let proof_meta = proof_meta_for_let_proof ~proof_index ctx value_name value in
    let proof_hover_note = hover_note_for_meta ((value_name, subject_chain) :: ctx.subject_chain_env) proof_name proof_meta in
    record_local_binding ?hover_note:proof_hover_note ctx proof_name loc t_fact proof_meta;
    let env' = env_extend proof_name (mono t_fact) (env_extend value_name sch ctx.env) in
    let ctx' = {
      ctx with
      env = env';
      binding_meta_env = (proof_name, proof_meta) :: (value_name, value_meta) :: ctx.binding_meta_env;
      subject_chain_env = (value_name, subject_chain) :: ctx.subject_chain_env;
    } in
    infer_stmt ctx' body
  | _ ->
    (infer_expr ctx e, ctx)

let call_target_name = function
  | EVar { name; _ } -> Some name
  | EField { field; _ } -> Some field
  | _ -> None

let argument_reason fn_expr index =
  match call_target_name fn_expr with
  | Some name -> Printf.sprintf "argument %d to `%s` must match the callee parameter type" index name
  | None -> Printf.sprintf "argument %d must match the callee parameter type" index

let constructor_argument_reason ctor_name index =
  Printf.sprintf "argument %d of constructor `%s` must match the constructor field type"
    index ctor_name

let return_reason fn_name expected_ty =
  Printf.sprintf "body of `%s` must have type %s" fn_name (pp_ty expected_ty)

let record_field_reason type_name field_name =
  Printf.sprintf "field `%s` of `%s` must match its declared type" field_name type_name

let list_element_reason expected_ty =
  Printf.sprintf "list elements must have type %s" (pp_ty expected_ty)

let tuple_element_reason index expected_ty =
  Printf.sprintf "tuple element %d must have type %s" index (pp_ty expected_ty)

let rec check_stmt ctx (e : expr) (expected : expectation) : unit =
  match e with
  | ELet {
      name = "_";
      declared_type = _;
      declared_proof = _;
      value = EVar { name = "set"; _ };
      body = ELet { name = "_"; declared_type = _; declared_proof = _; value = EField _; body; loc = _ };
      loc = _;
    } ->
    check_stmt ctx body expected
  | ELet { name = "_"; value = first_expr; _ } as seq
    when (let rec is_update_and_return = function
            | EApp { fn; _ } -> is_update_and_return fn
            | EVar { name; _ } -> name = "updateAndReturnOne"
            | _ -> false
          in is_update_and_return first_expr) ->
    (* updateAndReturnOne chain: infer as a fresh entity type, then unify with expected *)
    let actual_ty = infer_expr ctx seq in
    let resolved_expected = apply !(ctx.subst) (expected_ty_of expected) in
    unify_expected_at ctx (expr_loc seq) actual_ty expected;
    ignore (apply !(ctx.subst) resolved_expected)
  | ELet { name = "_"; value; body; loc; _ }
    when (match fst (flatten_app_expr [] value) with
          | EVar { name = "check"; _ } -> true
          | _ -> false) ->
    (* Bare `check f(n)` without a let binding: the validation result is silently
       discarded and there is no stable subject name to attach the proof to. *)
    add_error ctx loc
      "bare `check` call: the result must be bound with `let x = check f(n)` \
       — without a binding there is no subject to attach the proof to, and the \
       validation result is silently discarded";
    check_stmt ctx body expected
  | ELet { name; declared_type; value; body; loc; declared_proof = _ } ->
    let value_ty =
      match declared_type with
      | Some declared_type ->
        let expected_ty = ty_of_type_expr declared_type in
        ignore (check_expr ctx value
          (push_expectation ~origin:loc ~role:(LetBinding name)
            ~reason:(local_let_reason name expected_ty) expected_ty expected));
        apply !(ctx.subst) expected_ty
      | None -> infer_expr ctx value
    in
    let meta = binding_meta_for_binding ctx name value in
    let subject_chain = binding_subject_chain ctx name value in
    let hover_note = hover_note_for_meta ((name, subject_chain) :: ctx.subject_chain_env) name meta in
    record_local_binding ?hover_note ctx name loc value_ty meta;
    let env_fv = free_vars_env ctx.env in
    let sch = generalize env_fv !(ctx.subst) value_ty in
    let ctx' = {
      ctx with
      env = env_extend name sch ctx.env;
      binding_meta_env = (name, meta) :: ctx.binding_meta_env;
      subject_chain_env = (name, subject_chain) :: ctx.subject_chain_env;
    } in
    check_stmt ctx' body expected
  | ELetProof { value_name; proof_name; proof_index; value; body; loc; _ } ->
    let value_ty = infer_expr ctx value in
    let sch = generalize (free_vars_env ctx.env) !(ctx.subst) value_ty in
    let value_meta = PlainBinding in
    let subject_chain = binding_subject_chain ctx value_name value in
    let value_hover_note = hover_note_for_meta ((value_name, subject_chain) :: ctx.subject_chain_env) value_name value_meta in
    record_local_binding ?hover_note:value_hover_note ctx value_name loc value_ty value_meta;
    let proof_meta = proof_meta_for_let_proof ~proof_index ctx value_name value in
    let proof_hover_note = hover_note_for_meta ((value_name, subject_chain) :: ctx.subject_chain_env) proof_name proof_meta in
    record_local_binding ?hover_note:proof_hover_note ctx proof_name loc t_fact proof_meta;
    let env' = env_extend proof_name (mono t_fact) (env_extend value_name sch ctx.env) in
    let ctx' = {
      ctx with
      env = env';
      binding_meta_env = (proof_name, proof_meta) :: (value_name, value_meta) :: ctx.binding_meta_env;
      subject_chain_env = (value_name, subject_chain) :: ctx.subject_chain_env;
    } in
    check_stmt ctx' body expected
  | _ ->
    ignore (check_expr ctx e expected)

and check_expr ctx (e : expr) (expected : expectation) : ty =
  let expected_ty = expected_ty_of expected in
  let fallback () =
    let actual_ty = infer_expr ctx e in
    let resolved_expected = apply !(ctx.subst) expected_ty in
    unify_expected_at ctx (expr_loc e) actual_ty expected;
    apply !(ctx.subst) resolved_expected
  in
  let checked = match e with
  | EIf { cond; then_; else_; loc } ->
    ignore (check_expr ctx cond
      (push_expectation ~origin:loc ~role:IfCondition
        ~reason:"if conditions must have type Bool" t_bool expected));
    ignore (check_expr ctx then_ expected);
    ignore (check_expr ctx else_ expected);
    apply !(ctx.subst) expected_ty
  | ECase { scrut; arms; _ } ->
    let scrut_ty = infer_expr ctx scrut in
    let scrut_name_opt = match scrut with EVar { name; _ } -> Some name | _ -> None in
    let scrut_proof_opt = match scrut_name_opt with
      | Some sn -> List.assoc_opt sn ctx.binding_meta_env
      | None    -> None
    in
    List.iter (fun (arm : case_arm) ->
      let arm_env = bind_pattern_vars ctx scrut_ty arm.pattern in
      let extra_meta = match scrut_proof_opt, scrut_name_opt, arm.pattern with
        | Some (AttachedProofBinding proof), Some scrut_name,
          PCon { fields = [(_, PVar arm_var)]; _ } ->
          (* Propagate proof to any single-field constructor arm (Something, Right, CustomRight, etc.) *)
          [(arm_var, AttachedProofBinding (rename_proof_name scrut_name arm_var proof))]
        | _ -> []
      in
      let extra_subjects = match extra_meta with
        | [(arm_var, _)] -> [(arm_var, [arm_var])]
        | _ -> []
      in
      let ctx' = { ctx with
        env = arm_env @ ctx.env;
        binding_meta_env = extra_meta @ ctx.binding_meta_env;
        subject_chain_env = extra_subjects @ ctx.subject_chain_env;
      } in
      (match arm.guard with
       | Some guard ->
         let guard_ty = infer_expr ctx' guard in
         unify_at ctx (expr_loc guard) guard_ty t_bool
       | None -> ());
      ignore (check_expr ctx' arm.body expected);
      record_pattern_bindings ~extra_meta ctx arm.loc arm_env
    ) arms;
    apply !(ctx.subst) expected_ty
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    check_stmt ctx body expected;
    apply !(ctx.subst) expected_ty
  | EOk { value; _ } ->
    ignore (check_expr ctx value expected);
    apply !(ctx.subst) expected_ty
  | EFail { message; loc; _ } ->
    ignore (check_expr ctx message
      (push_expectation ~origin:loc ~role:FailMessage
        ~reason:"`fail` messages must have type String" t_string expected));
    apply !(ctx.subst) expected_ty
  | ERecord { fields; loc; _ } ->
    let resolved_expected = apply !(ctx.subst) expected_ty in
    (* Bare record literal — always error; user must write TypeName { field: val } *)
    add_error ctx loc
      "bare record literal: every record must be prefixed with its type name.\n\
       \  Use: TypeName { field: value, ... }\n\
       \  Example: Point { x: 0, y: 0 }";
    (match resolved_expected with
     | TCon type_name | TApp (TCon type_name, _) ->
       (match List.assoc_opt type_name ctx.records with
        | Some rd ->
          ctx.bare_record_hints := (loc, type_name) :: !(ctx.bare_record_hints);
          List.iter (fun (field_name, value_expr) ->
            match List.assoc_opt field_name rd.rd_fields with
            | Some field_ty ->
              ignore (check_expr ctx value_expr
                (push_expectation ~origin:loc
                  ~role:(RecordField (type_name, field_name))
                  ~reason:(record_field_reason type_name field_name)
                  field_ty expected))
            | None -> ignore (infer_expr ctx value_expr)
          ) fields;
          resolved_expected
        | None -> fallback ())
     | _ -> fallback ())
  (* ADT variant constructor with inline record syntax in check mode: Right { value: x } *)
  | EApp {
      fn = EConstructor { name = ctor_name; args = []; _ };
      arg = ERecord { fields; loc = _; _ };
      loc;
    } when List.mem_assoc ctor_name ctx.ctors
        && not (List.mem_assoc ctor_name ctx.records) ->
    let (adt_name, ctor_sch) = List.assoc ctor_name ctx.ctors in
    let ctor_ty = instantiate ctor_sch in
    let named_field_tys =
      match List.assoc_opt adt_name ctx.adts with
      | Some ad -> (match List.assoc_opt ctor_name ad.ad_variants with
          | Some nft -> nft | None -> [])
      | None -> []
    in
    let ret_ty =
      if named_field_tys = [] then
        List.fold_left (fun cur_ty value_expr ->
          let arg_ty = infer_expr ctx value_expr in
          let next_ty = fresh () in
          unify_at ctx loc cur_ty (TFun (arg_ty, next_ty));
          apply !(ctx.subst) next_ty
        ) ctor_ty (List.map snd fields)
      else begin
        List.iter (fun (fname, _) ->
          if not (List.mem_assoc fname fields) then
            add_error ctx loc
              (Printf.sprintf "constructor `%s` is missing required field `%s`"
                 ctor_name fname)
        ) named_field_tys;
        List.iter (fun (fname, value_expr) ->
          if not (List.mem_assoc fname named_field_tys) then begin
            add_error ctx (expr_loc value_expr)
              (Printf.sprintf "constructor `%s` has no field `%s`" ctor_name fname);
            ignore (infer_expr ctx value_expr)
          end
        ) fields;
        List.fold_left (fun cur_ty (fname, _decl_ty) ->
          let next_ty = fresh () in
          (match List.assoc_opt fname fields with
           | Some value_expr ->
             let arg_ty = infer_expr ctx value_expr in
             unify_at ctx loc cur_ty (TFun (arg_ty, next_ty))
           | None ->
             unify_at ctx loc cur_ty (TFun (fresh (), next_ty)));
          apply !(ctx.subst) next_ty
        ) ctor_ty named_field_tys
      end
    in
    let resolved = apply !(ctx.subst) ret_ty in
    unify_expected_at ctx loc resolved expected;
    apply !(ctx.subst) expected_ty
  (* TypeName { field: val } in check mode *)
  | EApp {
      fn = EConstructor { name = rname; args = []; _ };
      arg = ERecord { fields; loc = rloc; _ };
      loc = _;
    } when List.mem_assoc rname ctx.records ->
    let rd = List.assoc rname ctx.records in
    (* Check for missing fields *)
    let provided_field_names = List.map fst fields in
    List.iter (fun (def_name, _def_ty) ->
      if not (List.mem def_name provided_field_names) then
        add_error ctx rloc
          (Printf.sprintf "record `%s` is missing required field `%s`" rname def_name)
    ) rd.rd_fields;
    List.iter (fun (field_name, value_expr) ->
      match List.assoc_opt field_name rd.rd_fields with
      | Some field_ty ->
        ignore (check_expr ctx value_expr
          (push_expectation ~origin:rloc
            ~role:(RecordField (rname, field_name))
            ~reason:(record_field_reason rname field_name)
            field_ty expected))
      | None ->
        add_error ctx rloc
          (Printf.sprintf "record type `%s` has no field `%s`" rname field_name);
        ignore (infer_expr ctx value_expr)
    ) fields;
    unify_expected_at ctx rloc (TCon rname) expected;
    apply !(ctx.subst) expected_ty
  | EList { elems; loc } ->
    let resolved_expected = apply !(ctx.subst) expected_ty in
    (match resolved_expected, elems with
     | TApp (TCon "List", elem_ty), _ ->
       List.iter (fun elem ->
         ignore (check_expr ctx elem
           (push_expectation ~origin:loc ~role:ListElement
             ~reason:(list_element_reason elem_ty) elem_ty expected))
       ) elems;
       resolved_expected
     | _, [_; _] ->
       add_error ctx loc
         "list literal `[a, b]` cannot be used to construct a Tuple2; \
use the `Tuple2 a b` constructor instead";
       resolved_expected
     | _, [_; _; _] ->
       add_error ctx loc
         "list literal `[a, b, c]` cannot be used to construct a Tuple3; \
use the `Tuple3 a b c` constructor instead";
       resolved_expected
     | _ -> fallback ())
  | EConstructor { name; args; loc } ->
    (match resolve_constructor_type ctx name loc with
     | ProofPredicateConstructor ->
       fallback ()
     | KnownConstructor ctor_ty ->
       let result_ty = fresh () in
       let param_tys = List.init (List.length args) (fun _ -> fresh ()) in
       let expected_ctor_ty =
         List.fold_right (fun param_ty acc -> TFun (param_ty, acc)) param_tys result_ty
       in
       unify_at ctx loc ctor_ty expected_ctor_ty;
       unify_expected_at ctx loc (apply !(ctx.subst) result_ty) expected;
       List.iteri (fun idx arg_expr ->
         let param_ty = List.nth param_tys idx in
         ignore (check_expr ctx arg_expr
           (push_expectation ~origin:loc
             ~role:(ConstructorArgument (name, idx + 1))
             ~reason:(constructor_argument_reason name (idx + 1))
             param_ty expected))
       ) args;
       apply !(ctx.subst) expected_ty)
  | EApp _ when ctx.in_establish ->
    fallback ()
  | EApp { arg = EList { elems = []; _ }; _ } ->
    fallback ()
  | EApp _ as app ->
    let base_fn, args = flatten_app_expr [] app in
    (match base_fn with
     | EVar { name = "initTelemetry" | "check" | "make-witness" | "selectOne" | "select" | "selectCount" | "selectSum" | "selectMax" | "selectMin" | "selectCountBy" | "selectSumBy" | "insert" | "insertMany" | "upsert" | "update" | "updateAndReturnOne" | "returning" | "where" | "set" | "onConflict" | "doUpdate" | "delete" | "deleteAndReturnResult" | "one" | "#record-update#"; _ } ->
       fallback ()
     | EVar { name = "serverTools"; _ } when not ctx.server_tools_shadowed ->
       (* serverTools is typed structurally by its infer_expr arms (a server
          name is not an expression value); the generic head-inference below
          would misreport it. *)
       fallback ()
     | EVar { name = "humanActions"; _ } when not ctx.human_actions_shadowed ->
       (* humanActions is typed structurally by its infer_expr arms, same as
          serverTools — a server name is not an expression value. *)
       fallback ()
     | EBinop _ ->
       (* Multi-line SQL: order/limit/offset merged as EApp args onto a where-EBinop.
          Delegate to infer_expr which correctly classifies the merged SQL expression. *)
       fallback ()
     | EField { obj = (EConstructor { name = "Units"; args = []; _ }
                      | EVar { name = "Units"; _ }); field; _ }
       when lookup_name ctx ("Units." ^ field) = None ->
       (* First-Class Units: the polymorphic dimension ops have no env arrow
          type (their result dimension is computed per application site), so
          the generic head-inference below would thread a FRESH fn var and
          swallow every dimension/arity error in tail position — a fail-open.
          Route through the same site-typing as the infer path, then unify
          with the annotation. *)
       let ty = infer_units_op ctx (expr_loc app) field args in
       unify_expected_at ctx (expr_loc app) ty expected;
       apply !(ctx.subst) ty
     | _ ->
       (* Generic call-checking path: infer the function type, check each arg
          against expected, unify the result with the annotation.  We do NOT
          route `decodeAs` through `fallback ()`/`infer_expr` here (that would
          re-enter the infer-path decodeAs arm with a not-yet-pinned free var and
          spuriously flag it as ambiguous); instead we check args + unify the
          result with `expected` inline, so `expected_ty` is the RESOLVED result
          type when we run the decide-by-resolution cross-check below. *)
       let initial_fn_ty = infer_expr ctx base_fn in
       let current_ty = ref initial_fn_ty in
       List.iteri (fun idx arg_expr ->
         let resolved_fn = apply !(ctx.subst) !current_ty in
         match resolved_fn with
         | TFun (param_ty, ret_ty) ->
           ignore (check_expr ctx arg_expr
             (push_expectation ~origin:(expr_loc app)
               ~role:(CallArgument (call_target_name base_fn, idx + 1))
               ~reason:(argument_reason base_fn (idx + 1))
               param_ty expected));
           current_ty := apply !(ctx.subst) ret_ty
         | _ ->
           let is_concrete = match resolved_fn with
             | TVar _ -> false
             | _ -> true
           in
           let fn_name = call_target_name base_fn in
           let total_args = List.length args in
           let accepted = idx in
           (match fn_name with
           | Some name when is_concrete && accepted > 0 ->
             add_error ctx (expr_loc arg_expr)
               (Printf.sprintf
                  "`%s` accepts %d argument%s but was given %d"
                  name accepted (if accepted = 1 then "" else "s") total_args)
           | _ ->
             let arg_ty = infer_expr ctx arg_expr in
             let next_ret_ty = fresh () in
             unify_at ctx (expr_loc arg_expr) resolved_fn (TFun (arg_ty, next_ret_ty));
             current_ty := apply !(ctx.subst) next_ret_ty)
       ) args;
       (* Eq/Ord Stage 3: record this call for post-check discharge.  The callee's
          instantiated param slots are now bound to the argument types, so read
          them straight off the resolved fn type (no re-inference). *)
       (match ord_eq_callee_name base_fn with
        | Some name when args <> [] ->
          let resolved_fn = apply !(ctx.subst) initial_fn_ty in
          let rec take n ty =
            if n = 0 then []
            else match ty with
              | TFun (a, b) -> apply !(ctx.subst) a :: take (n - 1) b
              | _ -> []
          in
          let arg_tys = take (List.length args) resolved_fn in
          if List.length arg_tys = List.length args then
            ctx.ord_eq_calls := (name, arg_tys, expr_loc app) :: !(ctx.ord_eq_calls)
        | _ -> ());
       let resolved_result = apply !(ctx.subst) !current_ty in
       unify_expected_at ctx (expr_loc app) resolved_result expected;
       (match base_fn with
        | EVar { name = "decodeAs"; _ } ->
          (* decide-by-resolution: the literal type-name string must equal the
             now-resolved result type name, and that type must have a codec. *)
          check_decodeAs_call ctx ~loc:(expr_loc app) ~args
            ~result_ty:(apply !(ctx.subst) expected_ty)
        | _ -> ());
       apply !(ctx.subst) expected_ty)
  | _ ->
    fallback ()
  in
  let expr_meta = match binding_meta_of_expr ctx e with Some m -> m | None -> PlainBinding in
  record_expr_type_with_meta ctx (expr_loc e) checked expr_meta;
  checked

(* ── Function declaration type checking ─────────────────────────────────── *)

(* Rewrite a harvested operand type (body form: type params are lowercase
   [TCon "a"]) into the fn scheme's RIGID vars, using [params_map] (the SAME
   name→rigid-id assignment [decl_scheme] uses).  Returns None if the type is not
   fully attributable to the fn's own type params — a stray unification [TVar] or
   an unknown lowercase name — so such a constraint is dropped rather than stored
   wrongly (the runtime backstop still covers it).  Total match, no wildcard. *)
let rec constraint_to_rigid (params_map : (string * int) list) (ty : ty) : ty option =
  match ty with
  | TCon name when is_ty_var_name name ->
    (match List.assoc_opt name params_map with Some rid -> Some (TVar rid) | None -> None)
  | TCon _ -> Some ty
  | TVar id when id < 0 -> Some (TVar id)
  | TVar _ -> None
  | TApp (h, a) ->
    (match constraint_to_rigid params_map h, constraint_to_rigid params_map a with
     | Some h', Some a' -> Some (TApp (h', a')) | _ -> None)
  | TFun (a, b) ->
    (match constraint_to_rigid params_map a, constraint_to_rigid params_map b with
     | Some a', Some b' -> Some (TFun (a', b')) | _ -> None)

(* Capture the current fn's harvested Eq/Ord obligations, keyed by [name], into
   the module-wide table (constraints expressed in the scheme's rigid vars). *)
let finalize_ord_eq_constraints ctx (name : string) (fd_params : binding list) return_spec =
  let param_tvars = List.concat_map (fun (b : binding) -> collect_tvar_names b.type_expr) fd_params in
  let ret_tvars = collect_ret_spec_tvar_names return_spec in
  let all_tvars = List.sort_uniq String.compare (param_tvars @ ret_tvars) in
  let params_map = List.mapi (fun i n -> (n, -(i + 1))) all_tvars in
  let converted =
    List.filter_map (fun (pred, t) ->
      match constraint_to_rigid params_map t with
      | Some t' -> Some (pred, t')
      | None -> None)
      !(ctx.ord_eq_acc)
  in
  let dedup = List.sort_uniq compare converted in
  if dedup <> [] then Hashtbl.replace ctx.ord_eq_constraints name dedup

let check_func_decl ?(user_fn_names : string list = []) ctx (fd : func_decl) =
  (* [user_fn_names] are the top-level fn names (which may shadow a SQL builtin).
     They were threaded in so the checker's §7.12 FromDb-forgery gate could be
     shadow-aware (S4b).  A6 removed that in-checker forgery gate — the §7.12
     forgery decision (incl. shadow-aware FromDb provenance) now lives SOLELY in
     Validation_advanced.check_fn_return_proof_annotations (V001) — so the label
     is retained for call-site stability but is intentionally unused here. *)
  ignore user_fn_names;
  (* Each function gets its own fresh substitution to avoid interference. *)
  let ctx = { ctx with subst = ref empty_subst; ord_eq_acc = ref [] } in
  (* Build param environment *)
  let param_env = List.map (fun (b : binding) ->
    (b.name, mono (ty_of_type_expr b.type_expr))
  ) fd.params in
  let param_meta = List.map (fun (b : binding) ->
    let meta = match b.proof_ann with
      | Some proof -> AttachedProofBinding proof
      | None -> PlainBinding
    in
    (b.name, meta)
  ) fd.params in
  let param_subject_chains = List.map (fun (b : binding) -> (b.name, [b.name])) fd.params in
  let ctx' = { ctx with
    env = param_env @ ctx.env;
    binding_meta_env = param_meta @ ctx.binding_meta_env;
    subject_chain_env = param_subject_chains @ ctx.subject_chain_env;
    in_establish = (fd.kind = EstablishKind);
  } in
  List.iter (fun (b : binding) ->
    let meta = match b.proof_ann with
      | Some proof -> AttachedProofBinding proof
      | None -> PlainBinding
    in
    let hover_note = hover_note_for_meta ctx'.subject_chain_env b.name meta in
    record_local_binding ?hover_note ctx' b.name b.loc (ty_of_type_expr b.type_expr) meta
  ) fd.params;
  (* A6: the forgery decision for a fn/handler/worker RetAttached proof-carrying
     return (§7.12) is made SOLELY by Validation_advanced.check_fn_return_proof_annotations
     (V001), which threads let/case/if/attachFact proof ENVIRONMENTS
     (extend_let_envs / proofs_of_expr / carried_proofs_of_expr) and decides by
     proof CONTENT — not by identifier spelling.  The former T001 block here
     admitted a return whenever the body syntactically returned a variable/field
     whose NAME matched the return binder (`body_returns_named`), a decide-by-
     spelling carve-out that let `let n = raw; n` or `attachFact x <unrelated>; y`
     forge an arbitrary return proof; it was sound only because V001 was unioned
     in.  That carve-out is removed so V001 is the single source of truth.

     The one rule T001 uniquely enforced — and which V001 deliberately does NOT
     (its content walk ACCEPTS a body that legitimately carries the proof) — is
     that a proof-carrying return must NAME its binding.  We preserve exactly that,
     keyed off the synthetic `_entity` binder the parser mints for the unnamed
     `-> Type ::: Pred` RetAttached form (parser.ml ~951/1040/1046).  `_entity`
     is a gensym the user cannot spell, so this decides over the resolved binder
     IDENTITY, not over body text. *)
  let is_forgery_restricted_kind = Validation_common.is_forgery_restricted_kind in
  (match fd.return_spec with
   | RetAttached { binding = ret_b; loc; _ }
     when is_forgery_restricted_kind fd.kind
          && ret_b.proof_ann <> None
          && ret_b.name = "_entity" ->
     let proof_str = match ret_b.proof_ann with
       | Some p -> Validation_common.pp_proof p | None -> "" in
     let ty_str = Validation_common.pp_type_expr ret_b.type_expr in
     add_error ctx loc
       (Printf.sprintf
          "a proof-carrying return type must name its binding, e.g. \
           `-> result: %s ::: %s`; an unnamed `-> %s ::: ...` cannot carry a proof"
          ty_str proof_str ty_str)
   | _ -> ());
  (* Check that return binding doesn't reuse a parameter name with a different type *)
  (match fd.return_spec with
   | RetAttached { binding = b; loc; _ } ->
     (match List.assoc_opt b.name param_env with
      | Some sch ->
        let param_ty = sch.mono in
        let ret_ty = ty_of_type_expr b.type_expr in
        if param_ty <> ret_ty then
          add_error ctx loc
            (Printf.sprintf "return binding `%s` reuses input binder `%s` with a different type \
                             (parameter: %s, return: %s)"
              b.name b.name (pp_ty param_ty) (pp_ty ret_ty))
      | _ -> ())
   | _ -> ());
  let expected = match fd.return_spec with
    | RetPlain { ty; _ }          -> ty_of_type_expr ty
    | RetAttached { binding = b; _ } -> ty_of_type_expr b.type_expr
    | RetNamedPack { ty; _ }      -> ty_of_type_expr ty
    | RetForAll { elem_ty; _ }    -> t_list (ty_of_type_expr elem_ty)
    | RetMaybeForAll { elem_ty; _ } -> t_maybe (t_list (ty_of_type_expr elem_ty))
    | RetSetForAll { elem_ty; _ } -> t_set (ty_of_type_expr elem_ty)
    | RetMaybeSetForAll { elem_ty; _ } -> t_maybe (t_set (ty_of_type_expr elem_ty))
    | RetForAllDictValues { key_ty; val_ty; _ } -> t_dict (ty_of_type_expr key_ty) (ty_of_type_expr val_ty)
    | RetForAllDictKeys   { key_ty; val_ty; _ } -> t_dict (ty_of_type_expr key_ty) (ty_of_type_expr val_ty)
    | RetMaybeAttached { outer_ty = Some ty; _ } -> ty_of_type_expr ty
    | RetMaybeAttached { binding = b; _ } -> t_maybe (ty_of_type_expr b.type_expr)
    | RetExists { body; _ } -> ret_spec_type body
  in
  (* App-pass entry point: `main() -> App = … App { … }` is declarative
     configuration whose fields reference declarations (databases/queues/servers)
     by name, not as values. It is validated structurally and lowered by the
     desugar pass, so its body is not type-checked here. *)
  let is_app_main =
    fd.kind = MainKind &&
    (let rec tail = function
       | ELet { body; _ } | ELetProof { body; _ } -> tail body
       | ERecord { type_hint = Some "App"; _ } -> true
       | EApp { fn = EConstructor { name = "App"; _ }; arg = ERecord _; _ } -> true
       | _ -> false
     in tail fd.body)
  in
  (if is_app_main then () else
   check_stmt ctx' fd.body
     (mk_expectation ~origin:fd.loc ~role:(ReturnBody fd.name)
       ~reason:(return_reason fd.name expected) expected));
  (* Eq/Ord Stage 3: record this fn's harvested obligations for call-site discharge. *)
  finalize_ord_eq_constraints ctx fd.name fd.params fd.return_spec

(* ── Module-level type checker ───────────────────────────────────────────── *)

(** Validate that all names in `import Tesl.X exposing [...]` actually exist
    in that module.  Names not in the registered export list are flagged. *)
let check_stdlib_import_names (m : module_form) : type_error list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if not (is_tesl_module imp.module_name) then []
    else
      match imp.names with
      | ImportAll ->
        (* `import Tesl.X` with no exposing — still validate the module exists *)
        if not (Type_system.is_known_tesl_module imp.module_name) then
          [{ loc = imp.loc;
             message = Printf.sprintf
               "unknown stdlib module `%s`; \
                check the module name or remove this import"
               imp.module_name;
             fix = None }]
        else
          []
      | ImportExposing names ->
        (match Type_system.tesl_module_export_set imp.module_name with
         | None ->
           (* Module has no registered export list.  If the module itself is
              unknown (not a real Tesl.* module), reject it with a clear error. *)
           if not (Type_system.is_known_tesl_module imp.module_name) then
             [{ loc = imp.loc;
                message = Printf.sprintf
                  "unknown stdlib module `%s`; \
                   check the module name or remove this import"
                  imp.module_name;
                fix = None }]
           else
             []  (* known internal module — accept all names loosely *)
         | Some exports ->
           List.filter_map (fun raw_name ->
             (* Strip the (..) wildcard suffix: "Maybe(..)" -> "Maybe" *)
             let name =
               let n = String.length raw_name in
               if n > 4 && String.sub raw_name (n - 4) 4 = "(..)"
               then String.sub raw_name 0 (n - 4)
               else raw_name
             in
             if List.mem name exports then None
             else Some { loc = imp.loc;
                         message = Printf.sprintf
                           "module `%s` does not export `%s`"
                           imp.module_name name;
                         fix = None }
           ) names)
  ) m.imports

let check_local_import_names (m : module_form) : type_error list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then []
    else
      match imp.names with
      | ImportAll -> []
      | ImportExposing names ->
        let path = resolve_local_import_path m.source_file imp.module_name in
        (match parse_local_import_module path with
           | None | Some (Err _) -> []
           | Some (Ok imported) ->
             let exported_adt_names =
               List.fold_left (fun acc -> function
                 | ExportAdt n -> n :: acc
                 | ExportName _ -> acc
               ) [] imported.exports
             in
             let exported_names =
               List.fold_left (fun acc -> function
                 | ExportAdt n | ExportName n -> n :: acc
               ) [] imported.exports
             in
             (* Include ADT constructors for ExportAdt types and newtype names for all exported types *)
             let exported_ctors = List.concat_map (function
               | DType (TypeAdt { name; variants; _ }) when List.mem name exported_adt_names ->
                 List.map (fun (v : adt_variant) -> v.ctor) variants
               | DType (TypeNewtype { name; _ }) when List.mem name exported_names ->
                 [name]  (* newtype constructor has same name as type *)
               | _ -> []
             ) imported.decls in
             List.filter_map (fun raw_name ->
               let with_ctors =
                 let n = String.length raw_name in
                 n > 4 && String.sub raw_name (n - 4) 4 = "(..)"
               in
               let name =
                 if with_ctors then
                   String.sub raw_name 0 (String.length raw_name - 4)
                 else raw_name
               in
               let base_name = match String.rindex_opt name '.' with
                 | Some i -> String.sub name (i+1) (String.length name - i - 1)
                 | None -> name
               in
               if with_ctors then begin
                 (* Importing with (..) requires ExportAdt, not just ExportName *)
                 if List.mem name exported_adt_names || List.mem base_name exported_adt_names
                 then None
                 else if List.mem name exported_names || List.mem base_name exported_names
                 then Some { loc = imp.loc;
                             message = Printf.sprintf
                               "module `%s` does not expose constructors of `%s`; \
                                it is exported as an opaque type"
                               imp.module_name name;
                             fix = None }
                 else Some { loc = imp.loc;
                             message = Printf.sprintf
                               "module `%s` does not expose `%s`"
                               imp.module_name name;
                             fix = None }
               end else begin
                 let all_exported = exported_names @ exported_ctors in
                 if List.mem name all_exported || List.mem base_name all_exported then None
                 else Some { loc = imp.loc;
                             message = Printf.sprintf
                               "module `%s` does not expose `%s`"
                               imp.module_name name;
                             fix = None }
               end
             ) names)
  ) m.imports

(** Collect all type names that are explicitly in scope for this module:
    locally-defined types + types brought in via import …exposing. *)
let collect_in_scope_type_names (m : module_form) : string list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  let strip_dotdot s =
    let n = String.length s in
    if n > 4 && String.sub s (n-4) 4 = "(..)" then String.sub s 0 (n-4) else s
  in
  (* Fact is a built-in language construct (establish return type), always available *)
  let always_in_scope = ["Fact"] in
  let local_types = List.filter_map (function
    | DType (TypeAdt { name; _ }) | DType (TypeNewtype { name; _ })
    | DType (TypeAlias { name; _ }) | DRecord { name; _ }
    | DEntity { name; _ } | DFact { name; _ }
    | DQueue { name; _ } | DChannel { name; _ } | DCache { name; _ }
    | DAgent { name; _ } -> Some name
    | _ -> None
  ) m.decls in
  let imported = List.concat_map (fun (imp : import_decl) ->
    match imp.names with
    | ImportAll ->
      if is_tesl_module imp.module_name then
        (match Type_system.tesl_module_export_set imp.module_name with
         | None -> []
         | Some exports -> exports)
      else
        let path = resolve_local_import_path m.source_file imp.module_name in
        (match parse_local_import_module path with
           | None | Some (Err _) -> []
           | Some (Ok imp_m) ->
             List.filter_map (function
               | DType (TypeAdt { name; _ }) | DType (TypeNewtype { name; _ })
               | DType (TypeAlias { name; _ }) | DRecord { name; _ }
               | DFact { name; _ } -> Some name
               | _ -> None
             ) imp_m.decls)
    | ImportExposing names -> List.map strip_dotdot names
  ) m.imports in
  always_in_scope @ local_types @ imported

(** Extract all (name, loc) pairs from TName nodes in a type_expr. *)
let rec type_names_of_type_expr (te : type_expr) : (string * Location.loc) list =
  match te with
  | TName { name; loc } -> [(name, loc)]
  | TVar _ -> []
  | TApp { head; arg; _ } ->
    type_names_of_type_expr head @ type_names_of_type_expr arg
  | TFun { dom; cod; _ } ->
    type_names_of_type_expr dom @ type_names_of_type_expr cod
  | TTuple { elems; _ } ->
    List.concat_map type_names_of_type_expr elems

let type_names_of_return_spec (rs : return_spec) : (string * Location.loc) list =
  let rec go = function
    | RetPlain { ty; _ }            -> type_names_of_type_expr ty
    | RetAttached { binding; _ }    -> type_names_of_type_expr binding.type_expr
    | RetNamedPack { ty; _ }        -> type_names_of_type_expr ty
    | RetForAll { elem_ty; _ }
    | RetMaybeForAll { elem_ty; _ }
    | RetSetForAll { elem_ty; _ }
    | RetMaybeSetForAll { elem_ty; _ } -> type_names_of_type_expr elem_ty
    | RetForAllDictValues { key_ty; val_ty; _ }
    | RetForAllDictKeys   { key_ty; val_ty; _ } ->
      type_names_of_type_expr key_ty @ type_names_of_type_expr val_ty
    | RetMaybeAttached { outer_ty = Some ty; _ } -> type_names_of_type_expr ty
    | RetMaybeAttached { binding; _ } -> type_names_of_type_expr binding.type_expr
    | RetExists { binding; body; _ } ->
      type_names_of_type_expr binding.type_expr @ go body
  in
  go rs

(** Hint about where to import a type from. *)
(** Validate that every type name used in declarations is explicitly in scope.
    [suggest] (E1) resolves an out-of-scope name to the import that would bind
    it — every stdlib export plus sibling modules in the folder tree — and
    carries the LSP quickfix.  (Generalizes the old hardcoded 17-name
    `import_hint` list to the whole {!Type_system.tesl_module_exports} table.) *)
let check_type_names_in_scope ~(suggest : string -> Import_suggest.suggestion option)
    (m : module_form) : type_error list =
  let in_scope = collect_in_scope_type_names m in
  (* A name is ok if: in scope, or qualified (contains '.'), or type-variable (lowercase) *)
  let is_ok name =
    List.mem name in_scope
    || String.contains name '.'
    || (String.length name > 0 && Char.lowercase_ascii name.[0] = name.[0])
  in
  let make_err (name, loc) =
    if is_ok name then None
    else
      let hint, fix = match suggest name with
        | Some (s : Import_suggest.suggestion) -> s.sug_hint, s.sug_fix
        | None -> "", None
      in
      Some { loc; message = Printf.sprintf
        "type `%s` is not in scope; add it to an import.%s" name hint; fix }
  in
  (* Collect errors for unsupported tuple arities. *)
  let rec check_tuple_arities (te : type_expr) : type_error list =
    match te with
    | TTuple { elems; loc } ->
      let n = List.length elems in
      let arity_err =
        if n = 2 || n = 3 then []
        else
          let msg = if n = 0 then "empty tuple type is not supported"
                    else if n = 1 then "1-element tuple type is not supported; use the type directly"
                    else Printf.sprintf "%d-element tuple type is not supported; only Tuple2 and Tuple3 are available" n
          in
          [{ loc; message = msg; fix = None }]
      in
      arity_err @ List.concat_map check_tuple_arities elems
    | TApp { head; arg; _ } -> check_tuple_arities head @ check_tuple_arities arg
    | TFun { dom; cod; _ } -> check_tuple_arities dom @ check_tuple_arities cod
    | TName _ | TVar _ -> []
  in
  let check_te te = List.filter_map make_err (type_names_of_type_expr te) @ check_tuple_arities te in
  let check_rs rs = List.filter_map make_err (type_names_of_return_spec rs) in
  List.concat_map (function
    | DFunc fd ->
      List.concat_map (fun (b : binding) -> check_te b.type_expr) fd.params
      (* MainKind always has a parser-injected implicit Unit return — skip return-spec validation *)
      @ (if fd.kind = MainKind then [] else check_rs fd.return_spec)
    | DRecord rd ->
      List.concat_map (fun (f : field_def) -> check_te f.type_expr) rd.fields
    | DEntity e ->
      List.concat_map (fun (f : field_def) -> check_te f.type_expr) e.fields
    | DType (TypeAdt { variants; _ }) ->
      List.concat_map (fun (v : adt_variant) ->
        List.concat_map (fun (f : field_def) -> check_te f.type_expr) v.fields
      ) variants
    | DType (TypeNewtype { base_type; _ }) ->
      check_te base_type
    | DType (TypeAlias { base_type; _ }) ->
      check_te base_type
    | DTest t ->
      List.concat_map (function
        | TsLetProof _ -> []
        | TsLet { declared_type = Some te; _ } -> check_te te
        | _ -> []
      ) t.stmts
    | DApi af ->
      List.concat_map (fun (ep : api_endpoint) ->
        (* Skip return-spec check when no explicit `->` was written (default Unit),
           and for SSE (no return spec at all). *)
        (match ep_return_spec_opt ep with
         | Some rs when ep_has_explicit_return ep -> check_rs rs | _ -> [])
        @ (match ep.auth with Some a -> check_te a.binding.type_expr | None -> [])
        @ List.concat_map (fun (c : api_capture) -> check_te c.binding.type_expr) ep.captures
        @ (match ep_body ep with Some b -> check_te b.type_expr | None -> [])
      ) af.endpoints
    | DFact ff ->
      List.concat_map (fun (b : binding) -> check_te b.type_expr) ff.params
    | DCapture cf ->
      check_te cf.binding.type_expr
    | _ -> []
  ) m.decls

(** Proof predicates that belong to stdlib modules and must be explicitly imported
    (via `import Tesl.X exposing [Pred]`) to be usable in proof annotations.
    A plain `import Tesl.X` (ImportAll) does NOT make these predicates available. *)
let tesl_module_predicate_exports : (string * string list) list = [
  ("Tesl.String",  ["IsTrimmed"; "IsUpperCase"; "IsLowerCase"; "IsNonNegative"; "IsNonEmpty"]);
  ("Tesl.List",    ["IsSorted"]);
  ("Tesl.Int",     ["IsNonNegative"; "IsNonZero"]);
  ("Tesl.Float",   ["FloatNonZero"]);
  ("Tesl.Dict",    ["HasKey"]);
]

(** Collect the set of stdlib predicate names that are EXPLICITLY available:
    only those that appear in an `import Tesl.X exposing [...]` list. *)
let collect_explicitly_imported_stdlib_predicates (m : module_form) : string list =
  let all_stdlib_preds = List.concat_map snd tesl_module_predicate_exports in
  List.concat_map (fun (imp : import_decl) ->
    match imp.names with
    | ImportAll -> []  (* ImportAll does NOT grant stdlib predicates *)
    | ImportExposing names ->
      List.filter (fun name -> List.mem name all_stdlib_preds) names
  ) m.imports

(** Collect all proof predicate names (uppercase) referenced in proof annotations
    across all function declarations in the module. Returns (pred_name, loc) pairs. *)
let collect_proof_predicate_uses (m : module_form) : (string * Location.loc) list =
  let rec preds_of_proof acc = function
    | PredApp { pred; loc; _ }
      when String.length pred > 0 && pred.[0] >= 'A' && pred.[0] <= 'Z'
           && not (String.contains pred '.') ->
      (pred, loc) :: acc
    | PredApp _ -> acc
    | PredAnd { left; right; _ } -> preds_of_proof (preds_of_proof acc left) right
  in
  let preds_of_proof_opt acc = function
    | None -> acc
    | Some p -> preds_of_proof acc p
  in
  let preds_of_rs acc = function
    | RetPlain _ | RetExists _ -> acc
    | RetAttached { binding = b; _ } -> preds_of_proof_opt acc b.proof_ann
    | RetNamedPack { entity_proof; other_proof; _ } ->
      preds_of_proof_opt (preds_of_proof_opt acc entity_proof) other_proof
    | RetForAll { proof; _ } | RetMaybeForAll { proof; _ }
    | RetSetForAll { proof; _ } | RetMaybeSetForAll { proof; _ } ->
      preds_of_proof acc proof
    | RetForAllDictValues { proof; _ } | RetForAllDictKeys { proof; _ } ->
      preds_of_proof acc proof
    | RetMaybeAttached { binding = b; _ } -> preds_of_proof_opt acc b.proof_ann
  in
  List.concat_map (function
    | DFunc fd ->
      let param_preds = List.fold_left (fun acc (b : binding) ->
        preds_of_proof_opt acc b.proof_ann) [] fd.params in
      preds_of_rs param_preds fd.return_spec
    | DRecord rd ->
      List.fold_left (fun acc (f : field_def) ->
        preds_of_proof_opt acc f.proof_ann) [] rd.fields
    | DEntity e ->
      List.fold_left (fun acc (f : field_def) ->
        preds_of_proof_opt acc f.proof_ann) [] e.fields
    | _ -> []
  ) m.decls

(* A7: the two hand-maintained "name → module" tables that lived here
   (`stdlib_module_of_prefix` and `bare_stdlib_fn_module`) have been DELETED.
   Both the "needs import M" scope decision (below) and the emitter's require
   path now derive from the SINGLE authoritative registry
   {!Type_system.stdlib_home_module} / {!Type_system.stdlib_home_module_of}. *)

(** Every name BOUND by the module — top-level fn/const names plus all binders in
    fn/const bodies (params, lets, let-proofs, lambda params, case patterns).  A
    bare-name use that matches one of these is a user binding (a shadow), NOT the
    stdlib function, so it must never be flagged as needing an import.  Conservative
    over-approximation (a name bound anywhere shadows everywhere) — safe: it can
    only SUPPRESS a flag, never raise a false one. *)
let collect_bound_names (m : module_form) : (string, unit) Hashtbl.t =
  let t : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let add n = Hashtbl.replace t n () in
  let rec pat = function
    | PVar n -> add n
    | PCon { fields; _ } -> List.iter (fun (_, p) -> pat p) fields
    | _ -> ()
  in
  let rec walk = function
    | ELet { name; value; body; _ } -> add name; walk value; walk body
    | ELetProof { value_name; proof_name; value; body; _ } ->
      add value_name; add proof_name; walk value; walk body
    | ELambda { params; body; _ } ->
      List.iter (fun (b : binding) -> add b.name) params; walk body
    | ECase { scrut; arms; _ } ->
      walk scrut; List.iter (fun (a : case_arm) -> pat a.pattern; walk a.body) arms
    | EField { obj; _ } -> walk obj
    | EApp { fn; arg; _ } -> walk fn; walk arg
    | EBinop { left; right; _ } -> walk left; walk right
    | EUnop { arg; _ } -> walk arg
    | EIf { cond; then_; else_; _ } -> walk cond; walk then_; walk else_
    | EList { elems; _ } -> List.iter walk elems
    | ERecord { fields; _ } -> List.iter (fun (_, v) -> walk v) fields
    | EOk { value; _ } -> walk value
    | EConstructor { args; _ } -> List.iter walk args
    | EFail { message; _ } -> walk message
    | ETelemetry { fields; _ } -> List.iter (fun (_, v) -> walk v) fields
    | EEnqueue { payload; _ } -> walk payload
    | EPublish { key; payload; _ } -> Option.iter walk key; Option.iter walk payload
    | EServe { port; _ } -> walk port
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> walk body
    | ECacheGet { key; _ } -> walk key
    | ECacheSet { key; value; ttl; _ } -> walk key; walk value; Option.iter walk ttl
    | ECacheDelete { key; _ } -> walk key
    | ECacheInvalidate { prefix; _ } -> walk prefix
    | ESendEmail { to_; subject; body; _ } -> walk to_; walk subject; walk body
    | ERuntimeCall { segments; _ } ->
      List.iter (function RLit _ | RRawVar _ -> () | RArg e -> walk e) segments
    | ELit _ | EVar _ | EStartWorkers _ | EStartEmailWorker _ -> ()
  in
  List.iter (function
    | DFunc fd ->
      add fd.name;
      List.iter (fun (b : binding) -> add b.name) fd.params;
      walk fd.body
    | DConst c -> add c.name; walk c.value
    | _ -> ()
  ) m.decls;
  t

(** Enumerate the child expressions carried by one [test_stmt] and apply [f] to
    each (recursing into nested [test_stmt]s for [TsIf]/[TsCase]).  Used to make
    the stdlib-import scope fold reach test / api-test / load-test bodies. *)
let rec iter_test_stmt (f : expr -> unit) (s : test_stmt) : unit =
  match s with
  | TsLet { value; _ } -> f value
  | TsLetProof { value; _ } -> f value
  | TsExpect { left; right; _ } -> f left; Option.iter f right
  | TsExpectFail { fn; arg; _ } | TsExpectHasProof { fn; arg; _ } -> f fn; f arg
  | TsProperty { params; body; _ } ->
    List.iter (fun (p : property_param) -> Option.iter f p.where_clause) params;
    f body
  | TsIf { cond; then_stmts; else_stmts; _ } ->
    f cond;
    List.iter (iter_test_stmt f) then_stmts;
    List.iter (iter_test_stmt f) else_stmts
  | TsCase { scrut; arms; _ } ->
    f scrut;
    List.iter (fun (a : ts_case_arm) ->
      Option.iter f a.ts_guard;
      List.iter (iter_test_stmt f) a.ts_body) arms
  | TsExpr { e; _ } -> f e

(** Collect stdlib value/function uses (bare AND qualified) that resolve to a
    home module via {!Type_system.stdlib_home_module_of}, across ALL declaration
    contexts, deduped by name → first location.

    A7: one generic AST fold ({!Ast_visitor.iter}) drives the per-expression
    recording, and ONE decl→expr enumeration covers every declaration form that
    carries user expressions — fn/const bodies AND test / api-test / load-test
    bodies (previously unscanned, so bare stdlib uses inside `test { … }` escaped
    the check).  A non-exhaustive [match] on the decl below is a compile error, so
    a new declaration form cannot silently escape the scope check.

    Config-record RHSs of the infrastructure declarations
    (database/queue/channel/cache/email/agent) are DELIBERATELY not swept: those
    records are desugared at compile time and their compile-time forms
    (`env "…"`, `anthropic …`, provider names) emit no runtime bare-name require,
    so demanding an import for them would over-reject.  Record/entity invariants
    carry proof PREDICATES (a [string list], no value exprs) and are handled by
    {!check_proof_predicate_scope}. *)
let collect_stdlib_fn_uses (m : module_form) : (string * Location.loc) list =
  let bound = collect_bound_names m in
  let seen : (string, Location.loc) Hashtbl.t = Hashtbl.create 32 in
  let record name loc =
    if not (Hashtbl.mem seen name)
       && not (Hashtbl.mem bound name)               (* user shadow suppresses *)
       && Type_system.stdlib_home_module_of name <> None
    then Hashtbl.replace seen name loc
  in
  (* Per-NODE recorder: a module-qualifier field access (Dict.lookup) or a bare
     gated value (initTelemetry / mockProvider).  Bare constructors are never
     recorded because they are absent from the home-module registry. *)
  let visit (e : expr) : unit =
    Ast_visitor.iter (fun node ->
      match node with
      | EField { obj = (EConstructor { name = modname; args = []; _ }
                       | EVar { name = modname; _ }); field; loc } ->
        record (modname ^ "." ^ field) loc
      | EVar { name; loc } -> record name loc
      | _ -> ()
    ) e
  in
  List.iter (function
    | DFunc fd -> visit fd.body
    | DConst c -> visit c.value
    | DTest t -> List.iter (iter_test_stmt visit) t.stmts
    | DApiTest t ->
      List.iter visit t.seed_stmts;
      List.iter (iter_test_stmt visit) t.stmts
    | DLoadTest lt ->
      List.iter visit lt.seed_stmts;
      List.iter (iter_test_stmt visit) lt.request_stmts
    (* A7-c-agent-config-leak (review §6.2): unlike database/queue/channel/cache/
       email — whose config RHSs desugar to erased scalars — an `agent X = Agent {…}`
       config_expr is KEPT by desugar and re-emitted verbatim by emit_agent, so a
       gated stdlib name in a config slot (e.g. `envString` in `apiKey`/
       `systemPrompt`) passes --check yet dies at `raco expand` (unbound). Sweep it
       like a function body so the missing import is a compile error. *)
    | DAgent a -> Option.iter visit a.config_expr
    (* Config-block RHSs are compile-time desugared — not swept (see doc above).
       Remaining forms carry no user value expressions that reference gated
       stdlib names.  Kept as an explicit, exhaustive enumeration so a new decl
       form forces a decision here. *)
    | DDatabase _ | DQueue _ | DChannel _ | DCache _ | DEmail _
    | DType _ | DRecord _ | DEntity _ | DFact _ | DCodec _ | DCapability _
    | DWorkers _ | DCapture _ | DApi _ | DServer _ -> ()
  ) m.decls;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) seen []

(** Check that qualified stdlib functions used in code have a corresponding import.
    Without the import the emitter cannot generate the Racket `require` binding,
    causing a runtime error instead of a compile-time error.

    Rules:
    - `import Tesl.X` (ImportAll)            → every X.* function is available.
    - `import Tesl.X exposing [X.func, ...]` → only the listed functions are available.
    - No import for Tesl.X                   → no X.* function is available. *)
let check_stdlib_fn_import_scope (m : module_form) : type_error list =
  let strip_dotdot s =
    let n = String.length s in
    if n > 4 && String.sub s (n - 4) 4 = "(..)" then String.sub s 0 (n - 4) else s
  in
  let is_fn_available tesl_module qname =
    List.exists (fun (imp : import_decl) ->
      imp.module_name = tesl_module &&
      (match imp.names with
       | ImportAll -> true
       | ImportExposing names ->
         List.exists (fun n -> strip_dotdot n = qname) names)
    ) m.imports
  in
  List.filter_map (fun (qname, loc) ->
    (* A7: qualified (Dict.lookup) and bare (envInt / initTelemetry / mockProvider)
       names alike resolve through the SINGLE authoritative home-module registry. *)
    let tesl_module_opt = Type_system.stdlib_home_module_of qname in
    match tesl_module_opt with
    | None -> None
    | Some tesl_module ->
      if is_fn_available tesl_module qname then None
      else
        let has_any_import = List.exists
          (fun (imp : import_decl) -> imp.module_name = tesl_module) m.imports
        in
        let hint =
          if has_any_import then
            Printf.sprintf
              " (you have `import %s` but `%s` is not in the exposing list)"
              tesl_module qname
          else ""
        in
        Some { loc; message = Printf.sprintf
          "function `%s` requires `import %s` (or `import %s exposing [%s]`)%s"
          qname tesl_module tesl_module qname hint;
          fix = Import_suggest.build_fix m ~target_module:tesl_module
                  ~expose_name:qname }
  ) (collect_stdlib_fn_uses m)

(** Check that stdlib proof predicates used in annotations are explicitly imported.
    A plain `import Tesl.X` (no exposing) does NOT make predicates like IsTrimmed available. *)
let check_proof_predicate_scope (m : module_form) : type_error list =
  let all_stdlib_preds = List.concat_map snd tesl_module_predicate_exports in
  (* Predicates explicitly available: locally declared facts + explicitly imported stdlib preds *)
  let local_facts = List.filter_map (function
    | DFact { name; _ } -> Some name
    | _ -> None) m.decls in
  let explicit_stdlib = collect_explicitly_imported_stdlib_predicates m in
  let explicitly_available = local_facts @ explicit_stdlib in
  (* Collect all proof predicate uses *)
  let uses = collect_proof_predicate_uses m in
  (* Deduplicate by pred name to avoid redundant errors *)
  let seen = Hashtbl.create 8 in
  List.filter_map (fun (pred, loc) ->
    if not (List.mem pred all_stdlib_preds) then None  (* not a stdlib pred, skip *)
    else if List.mem pred explicitly_available then None  (* explicitly available, ok *)
    else if Hashtbl.mem seen pred then None  (* already reported *)
    else begin
      Hashtbl.add seen pred ();
      (* Find which module exports this predicate *)
      let owner = List.find_opt (fun (_, preds) -> List.mem pred preds)
          tesl_module_predicate_exports in
      let module_hint = match owner with
        | Some (mod_name, _) ->
          Printf.sprintf " To use it, add it to an explicit import: `import %s exposing [%s]`" mod_name pred
        | None -> ""
      in
      Some { loc; message = Printf.sprintf
        "proof predicate `%s` is not in scope; \
         a plain module import does not expose proof predicates.%s" pred module_hint;
        fix = (match owner with
          | Some (mod_name, _) ->
            Import_suggest.build_fix m ~target_module:mod_name ~expose_name:pred
          | None -> None) }
    end
  ) uses

(** BMOD-FORGE-01 (review §4.2 + §4.3): a proof-predicate (`fact`) name must have a
    SINGLE owning module across the import graph — exactly as a type name does.

    Before this, predicate identity was the bare surface name and the emitter
    interned a shared `eq?` symbol, so a consumer could declare a local `fact F`
    with the same spelling as a predicate owned by an imported module and thereby
    (a) become a co-"owner" able to MINT it, and (b) satisfy that module's `::: F`
    obligation with a forged value — the exact cross-module forgery the thesis's
    invariant #2 forbids.  It also left thesis invariant #1 (no-shadowing) with a
    hole for `fact` specifically (the fn/type shadow detector omits it).

    Rather than re-architect predicate identity, we close the class fail-closed:
    a proof-predicate name must resolve to a SINGLE owning module across everything
    in scope.  This rejects (a) a local `fact` whose name is already owned by an
    imported module, (b) two DISTINCT imported modules that each own a fact of the
    same name reachable in this module — the cross-module "diamond" where a value
    carrying `ModA.F` would satisfy a `ModB.F` obligation because identity is the
    bare name (confirmed forgeable via `ModA.mint` + `ModB.sink` bridged in a
    consumer), and (c) a local `fact` colliding with an explicitly-imported stdlib
    predicate.  A re-export of the SAME originally-declared fact keeps one owner, so
    legitimate re-export + use is unaffected. *)
let check_fact_name_distinctness (m : module_form) : type_error list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl." in
  (* Facts a module PROVIDES as (name, ORIGINAL-owner): those it declares (owner =
     itself), plus those it re-exports resolved transitively to their declaring
     module — so a re-export chain of one fact keeps a single owner, while two
     independent declarations of the same name have two distinct owners.  [visited]
     bounds recursion over cycles. *)
  let rec provided_owned visited (mm : module_form) : (string * string) list =
    if List.mem mm.module_name visited then []
    else begin
      let visited = mm.module_name :: visited in
      let declared =
        List.filter_map (function
          | DFact { name; _ } -> Some (name, mm.module_name) | _ -> None) mm.decls in
      let exported_names =
        List.filter_map (function ExportName n | ExportAdt n -> Some n) mm.exports in
      let reexported =
        List.concat_map (fun (imp : import_decl) ->
          if is_tesl_module imp.module_name then []
          else
            match parse_local_import_module
                    (resolve_local_import_path mm.source_file imp.module_name) with
            | Some (Ok im) ->
              List.filter (fun (n, _) -> List.mem n exported_names) (provided_owned visited im)
            | _ -> []
        ) mm.imports
      in
      declared @ reexported
    end
  in
  (* fact-name -> distinct owning modules reachable in THIS module, and, for a
     diamond with no local declaration, an import loc to report at. *)
  let owners : (string, string list) Hashtbl.t = Hashtbl.create 16 in
  let import_loc_of : (string, Location.loc) Hashtbl.t = Hashtbl.create 16 in
  let add_owner ?loc name owner =
    let cur = try Hashtbl.find owners name with Not_found -> [] in
    if not (List.mem owner cur) then Hashtbl.replace owners name (owner :: cur);
    (match loc with
     | Some l when not (Hashtbl.mem import_loc_of name) -> Hashtbl.replace import_loc_of name l
     | _ -> ())
  in
  let local_facts =
    List.filter_map (function DFact { name; loc; _ } -> Some (name, loc) | _ -> None) m.decls in
  List.iter (fun (name, loc) -> add_owner ~loc name m.module_name) local_facts;
  List.iter (fun (imp : import_decl) ->
    if not (is_tesl_module imp.module_name) then
      match parse_local_import_module
              (resolve_local_import_path m.source_file imp.module_name) with
      | Some (Ok imported) ->
        List.iter (fun (name, owner) -> add_owner ~loc:imp.loc name owner)
          (provided_owned [] imported)
      | _ -> ()
  ) m.imports;
  (* Report each name owned by >= 2 distinct modules exactly once, preferring a
     local-declaration loc for the message when this module declares the fact. *)
  let local_name_loc = local_facts in
  let ambiguity_errors =
    Hashtbl.fold (fun name owner_list acc ->
      match owner_list with
      | _ :: _ :: _ ->
        let owners_str = String.concat ", " (List.sort compare owner_list) in
        let loc, msg =
          match List.assoc_opt name local_name_loc with
          | Some loc ->
            loc, Printf.sprintf
              "fact `%s` is already owned by another module in scope (owners: %s); \
               a proof predicate has a single owning module (like a type), so a local \
               `fact %s` here would forge that module's proof. Rename this fact, or \
               import and reuse the existing one." name owners_str name
          | None ->
            let loc = try Hashtbl.find import_loc_of name with Not_found -> Location.dummy_loc m.source_file in
            loc, Printf.sprintf
              "proof predicate `%s` is declared by MORE THAN ONE module in scope \
               (owners: %s); its identity is ambiguous here, so a value carrying one \
               module's `%s` could satisfy another's obligation. Import `%s` from a \
               single owning module." name owners_str name name
        in
        { loc; message = msg; fix = None } :: acc
      | _ -> acc
    ) owners []
  in
  (* A local `fact` colliding with an EXPLICITLY-imported stdlib predicate (stdlib
     preds have no user-module owner, so they don't enter [owners]). *)
  let imported_stdlib_preds = collect_explicitly_imported_stdlib_predicates m in
  let stdlib_errors =
    List.filter_map (fun (name, loc) ->
      if List.mem name imported_stdlib_preds then
        Some { loc; message = Printf.sprintf
          "fact `%s` shadows the imported stdlib proof predicate `%s`; a proof \
           predicate has a single owning module. Drop the local `fact %s` and use \
           the imported one, or rename this fact." name name name; fix = None }
      else None
    ) local_facts
  in
  ambiguity_errors @ stdlib_errors

(** Collect variable bindings introduced by a pattern (recursive for nested patterns). *)
let rec pattern_var_names = function
  | PVar n -> [n]
  | PWild | PNullary _ | PLit _ -> []
  | PCon { fields; _ } -> List.concat_map (fun (_, sub_pat) -> pattern_var_names sub_pat) fields

let pattern_bound_names_helper pat = pattern_var_names pat

(* ── Api-test / load-test scope checker ─────────────────────────────────── *)

(** Check that every free variable referenced in api-test or load-test
    expressions is either a DSL keyword, in the module's scope, or a name
    explicitly imported from a Tesl stdlib module.
    This catches "unbound identifier" errors at compile time rather than
    letting them surface as Racket runtime errors. *)
let check_api_test_scope ctx (m : module_form) seed_stmts stmts =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  let strip_dotdot s =
    let n = String.length s in
    if n > 4 && String.sub s (n - 4) 4 = "(..)" then String.sub s 0 (n - 4)
    else s
  in
  (* DSL keywords: always valid in api-test blocks, not real Racket bindings.
     These are structural keywords of the Tesl language handled specially
     by the type checker and emitter. *)
  let api_test_keywords = [
    (* HTTP request methods *)
    "get"; "post"; "put"; "delete"; "patch";
    (* HTTP request keyword arguments *)
    "cookie"; "headers"; "body";
    (* collect keyword arguments and condition modifier *)
    "count"; "timeout"; "until";
    (* unit suffixes used for readability (e.g. 1500ms — emitter strips them) *)
    "ms"; "s"; "rps";
    (* DB/SQL DSL keywords *)
    "select"; "selectOne"; "selectCount"; "selectSum"; "selectMax"; "selectMin";
    "selectCountBy"; "selectSumBy";
    "insert"; "insertMany"; "upsert"; "onConflict"; "doUpdate";
    "update"; "updateAndReturnOne";
    "delete"; "deleteAndReturnResult";
    "where"; "set"; "returning"; "one"; "from";
    (* Other built-in DSL keywords.
       A7: `initTelemetry` is no longer whitelisted here — its import is now
       enforced uniformly by check_stdlib_fn_import_scope, whose fold covers
       api-test seed/stmts too, so the third duplicated copy of the fact is gone. *)
    "check"; "serve"; "make-witness";
  ] in
  (* Names from the module environment (stdlib + local imports + module defs) *)
  let env_names = List.map fst ctx.env in
  (* Constructor names (ADTs) and record/entity/queue/channel/fact type names *)
  let ctor_names = List.map fst ctx.ctors in
  let record_names = List.map fst ctx.records in
  let decl_type_names = List.filter_map (function
    | DQueue { name; _ } | DChannel { name; _ } | DFact { name; _ }
    | DCapability { name; _ } | DServer { name; _ } | DCache { name; _ }
    | DEmail { name; _ } | DAgent { name; _ } -> Some name
    | _ -> None
  ) m.decls in
  (* Names explicitly imported from Tesl.* stdlib modules via `exposing [...]`.
     These are NOT added to ctx.env by the import machinery (which only
     processes local modules), so we collect them here. *)
  let tesl_stdlib_imported =
    List.concat_map (fun (imp : import_decl) ->
      if not (is_tesl_module imp.module_name) then []
      else
        match imp.names with
        | ImportAll ->
          (match tesl_module_export_set imp.module_name with
           | Some exports -> exports
           | None -> [])
        | ImportExposing names ->
          List.map strip_dotdot names
    ) m.imports
  in
  (* Names explicitly imported from local modules via `exposing [...]`.
     load_imported_func_sigs adds functions but not record/entity type names; and
     load_imported_ctors only adds ADT constructors. So entity types like KanelUser
     imported from a sibling module won't appear in ctx.env or ctx.ctors.
     We simply trust the exposing list — check_local_import_names already validates
     that each name actually exists in the imported module. *)
  let local_imported_names =
    List.concat_map (fun (imp : import_decl) ->
      if is_tesl_module imp.module_name then []
      else
        match imp.names with
        | ImportAll -> []
        | ImportExposing names -> List.map strip_dotdot names
    ) m.imports
  in
  let known_names =
    api_test_keywords @ env_names @ ctor_names @ record_names
    @ decl_type_names @ tesl_stdlib_imported @ local_imported_names
  in
  (* Collect variable bindings introduced by a pattern *)
  let pattern_bound_names pat = pattern_var_names pat in
  (* Walk an expression, reporting any EVar/EConstructor whose name is neither
     in [known_names] nor in the [locals] accumulated by enclosing let stmts. *)
  let rec check_expr locals e =
    match e with
    | EVar { name; loc } ->
      if not (List.mem name locals || List.mem name known_names) then
        add_unknown_name_error ctx loc ~what:"name" name
    | EConstructor { name; args; loc } ->
      if not (List.mem name locals || List.mem name known_names) then
        add_unknown_name_error ctx loc ~what:"constructor" name;
      List.iter (check_expr locals) args
    | EField { obj; _ } ->
      check_expr locals obj
    | EApp { fn; arg; _ } ->
      check_expr locals fn;
      check_expr locals arg
    | EBinop { left; right; _ } ->
      check_expr locals left;
      check_expr locals right
    | EUnop { arg; _ } ->
      check_expr locals arg
    | EIf { cond; then_; else_; _ } ->
      check_expr locals cond;
      check_expr locals then_;
      check_expr locals else_
    | ELet { name; value; body; _ } ->
      check_expr locals value;
      check_expr (name :: locals) body
    | ELetProof { value_name; proof_name; value; body; _ } ->
      check_expr locals value;
      check_expr (value_name :: proof_name :: locals) body
    | ERecord { fields; _ } ->
      List.iter (fun (_, v) -> check_expr locals v) fields
    | EList { elems; _ } ->
      List.iter (check_expr locals) elems
    | ECase { scrut; arms; _ } ->
      check_expr locals scrut;
      List.iter (fun (arm : case_arm) ->
        let arm_locals = pattern_bound_names arm.pattern @ locals in
        (match arm.guard with
         | Some g -> check_expr arm_locals g
         | None -> ());
        check_expr arm_locals arm.body
      ) arms
    | ELambda { params; body; _ } ->
      let param_names = List.map (fun (b : binding) -> b.name) params in
      check_expr (param_names @ locals) body
    | ESendEmail { to_; subject; body; _ } ->
      check_expr locals to_;
      check_expr locals subject;
      check_expr locals body
    | EStartEmailWorker _ -> ()
    | ELit _ -> ()
    | _ -> ()
  in
  let rec check_stmts locals = function
    | [] -> ()
    | stmt :: rest ->
      let locals' = match stmt with
        | TsLetProof { value_name; proof_names; value; _ } ->
          check_expr locals value;
          let locals' = if value_name <> "_" then value_name :: locals else locals in
          List.fold_left (fun acc pn -> pn :: acc) locals' proof_names
        | TsLet { name; value; _ } ->
          check_expr locals value;
          name :: locals
        | TsExpect { left; right; _ } ->
          check_expr locals left;
          (match right with Some r -> check_expr locals r | None -> ());
          locals
        | TsExpectFail { fn; arg; _ } | TsExpectHasProof { fn; arg; _ } ->
          check_expr locals fn;
          check_expr locals arg;
          locals
        | TsProperty { params; body; _ } ->
          let param_names = List.map (fun (p : property_param) -> p.binding.name) params in
          let prop_locals = param_names @ locals in
          List.iter (fun (p : property_param) ->
            match p.where_clause with
            | Some g -> check_expr prop_locals g
            | None -> ()
          ) params;
          check_expr prop_locals body;
          locals
        | TsIf { cond; then_stmts; else_stmts; _ } ->
          check_expr locals cond;
          check_stmts locals then_stmts;
          check_stmts locals else_stmts;
          locals
        | TsCase { scrut; arms; _ } ->
          check_expr locals scrut;
          List.iter (fun (arm : ts_case_arm) ->
            let arm_locals = pattern_bound_names arm.ts_pattern @ locals in
            (match arm.ts_guard with Some g -> check_expr arm_locals g | None -> ());
            check_stmts arm_locals arm.ts_body
          ) arms;
          locals
        | TsExpr { e; _ } ->
          check_expr locals e;
          locals
      in
      check_stmts locals' rest
  in
  List.iter (check_expr []) seed_stmts;
  check_stmts [] stmts

(** Check that type names referenced in api endpoint body/capture/auth bindings
    are in scope.  Catches "unbound identifier" Racket errors at compile time. *)
let check_api_decl_types ctx (m : module_form) =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  let strip_dotdot s =
    let n = String.length s in
    if n > 4 && String.sub s (n - 4) 4 = "(..)" then String.sub s 0 (n - 4)
    else s
  in
  (* Collect all known type names *)
  let record_names  = List.map fst ctx.records in
  let ctor_names    = List.map fst ctx.ctors in
  let env_names     = List.map fst ctx.env in
  let tesl_stdlib_imported =
    List.concat_map (fun (imp : import_decl) ->
      if not (is_tesl_module imp.module_name) then []
      else
        match imp.names with
        | ImportAll ->
          (match tesl_module_export_set imp.module_name with
           | Some exports -> exports
           | None -> [])
        | ImportExposing names -> List.map strip_dotdot names
    ) m.imports
  in
  let local_imported_names =
    List.concat_map (fun (imp : import_decl) ->
      if is_tesl_module imp.module_name then []
      else
        match imp.names with
        | ImportAll -> []
        | ImportExposing names -> List.map strip_dotdot names
    ) m.imports
  in
  let known_types =
    record_names @ ctor_names @ env_names
    @ tesl_stdlib_imported @ local_imported_names
  in
  let check_type_name_in_scope loc name =
    let known = [ "Unit"; "Bool"; "Int"; "Float"; "String"; "List"; "Maybe";
                  "Dict"; "Set"; "PosixMillis"; "HttpRequest"; "HttpResponse";
                  "JwtToken"; "JwtSecret";
                  "Agent"; "LlmProvider"; "AgentReply"; "Tool"; "ToolStep";
                  "Conversation"; "ConversationTurn" ] in
    if not (List.mem name known || List.mem name known_types) then
      add_error ctx loc (Printf.sprintf "unknown type: %s" name)
  in
  let rec check_type_expr (te : type_expr) =
    match te with
    | TName { name; loc } -> check_type_name_in_scope loc name
    | TApp { head; arg; _ } -> check_type_expr head; check_type_expr arg
    | TFun { dom; cod; _ } -> check_type_expr dom; check_type_expr cod
    | TTuple { elems; _ } -> List.iter check_type_expr elems
    | TVar _ -> ()
  in
  let check_binding (b : binding) = check_type_expr b.type_expr in
  List.iter (function
    | DApi af ->
      List.iter (fun (ep : api_endpoint) ->
        (match ep.auth with Some a -> check_binding a.binding | None -> ());
        List.iter (fun (c : api_capture) -> check_binding c.binding) ep.captures;
        (match (ep_body ep) with Some b -> check_binding b | None -> ())
      ) af.endpoints
    | _ -> ()
  ) m.decls

(* Eq/Ord Layer 1b (2026-07-04, eq_ord_generic_soundness) — harvest closed
   Ord/Eq obligations from IMPORTED generic comparators, so a misuse like
   `List.member fn xs` is rejected at COMPILE time rather than only fail-closed at
   runtime (Layer 1 covered same-module callees only; the cross-module case was
   left to the Layer-2 runtime backstop because the importer rebuilds the callee's
   scheme from its annotation without re-checking the body).

   We re-parse each import (exactly as [load_imported_func_sigs] does) and, for
   every imported `fn`, record an Eq/Ord obligation for each `<`/`==` operand that
   is a bare PARAMETER of a generic (type-variable) type — expressed in the callee
   scheme's rigid vars via the same [constraint_to_rigid] map [finalize_ord_eq_
   constraints] uses, and keyed by the qualified name (`List.member`) plus the
   plain name when exposed.  [check_ord_eq_calls] then discharges these against a
   recorded call's argument types identically to the same-module case.

   Scope: this closes comparators that compare a bare PARAMETER (e.g. `member`:
   `x == first`).  A comparator whose operands are case/let binders rather than
   parameters (e.g. `List.maximum`/`minimum`, which compare list ELEMENTS) is not
   harvested here — statically that needs full body re-inference of the import —
   and remains fail-closed at RUNTIME via the loud `<` crash / `tesl-equal?`
   backstop (Layer 2).  Purely additive: it only ADDS obligations for imported
   callees; it never relaxes an existing check. *)
let harvest_fd_ord_eq (fd : func_decl) : (ord_eq_pred * ty) list =
  let param_ty =
    List.map (fun (b : binding) -> (b.name, ty_of_type_expr b.type_expr)) fd.params in
  let acc = ref [] in
  let add pred = function
    | EVar { name; _ } ->
      (match List.assoc_opt name param_ty with
       | Some t -> acc := (pred, t) :: !acc
       | None -> ())
    | _ -> ()
  in
  let rec walk (e : expr) =
    (match e with
     | EBinop { op = (BEq | BNeq); left; right; _ } -> add PEq left; add PEq right
     | EBinop { op = (BLt | BLe | BGt | BGe); left; right; _ } -> add POrd left; add POrd right
     | _ -> ());
    Ast_visitor.iter_children walk e
  in
  walk fd.body;
  let param_tvars =
    List.concat_map (fun (b : binding) -> collect_tvar_names b.type_expr) fd.params in
  let ret_tvars = collect_ret_spec_tvar_names fd.return_spec in
  let all_tvars = List.sort_uniq String.compare (param_tvars @ ret_tvars) in
  let params_map = List.mapi (fun i n -> (n, -(i + 1))) all_tvars in
  List.sort_uniq compare
    (List.filter_map (fun (pred, t) ->
       match constraint_to_rigid params_map t with
       | Some t' -> Some (pred, t')
       | None -> None)
       !acc)

let load_imported_ord_eq_constraints (m : module_form)
    : (string * (ord_eq_pred * ty) list) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl." in
  List.concat_map (fun (imp : import_decl) ->
    let parsed =
      if is_tesl_module imp.module_name then
        (match lifted_stdlib_source_path imp.module_name with
         | Some path -> parse_local_import_module path
         | None -> None)
      else
        parse_local_import_module (resolve_local_import_path m.source_file imp.module_name)
    in
    match parsed with
    | None | Some (Err _) -> []
    | Some (Ok imported) ->
      let short_mod =
        match String.rindex_opt imp.module_name '.' with
        | Some i -> String.sub imp.module_name (i + 1) (String.length imp.module_name - i - 1)
        | None -> imp.module_name in
      let strip_dotdot s =
        let n = String.length s in
        if n > 4 && String.sub s (n - 4) 4 = "(..)" then String.sub s 0 (n - 4) else s in
      let requested = match imp.names with
        | ImportAll -> None
        | ImportExposing names -> Some (List.map strip_dotdot names) in
      List.concat_map (function
        | DFunc fd ->
          (match harvest_fd_ord_eq fd with
           | [] -> []
           | obligations ->
             let dotted = short_mod ^ "." ^ fd.name in
             let include_plain = match requested with
               | Some names -> List.mem fd.name names || List.mem dotted names
               | None -> false in
             (if include_plain then [ (fd.name, obligations) ] else [])
             @ [ (dotted, obligations) ])
        | _ -> []
      ) imported.decls
  ) m.imports

(* Eq/Ord Stage 3 — discharge.  Run AFTER every fn body is checked (so
   [ord_eq_constraints] is complete).  For each recorded direct call to a fn that
   carries an Eq/Ord obligation, re-instantiate the callee's scheme, bind its
   fresh vars against the recorded (already-resolved) argument types, and check
   the obligation type once it is concrete.  Fail-CLOSED: a concrete non-instance
   type is rejected here; a still-generic obligation is left for the enclosing
   fn's own call sites (and, as a final backstop, the runtime tesl-equal? / the
   loud `<` crash).  Purely additive — reads recorded data, only emits errors. *)
let check_ord_eq_calls ctx =
  List.iter (fun (callee, arg_tys, loc) ->
    match Hashtbl.find_opt ctx.ord_eq_constraints callee with
    | None -> ()
    | Some constraints ->
      (match env_lookup callee ctx.env with
       | None -> ()
       | Some sch ->
         let (fn_ty, imap) = instantiate_with_map sch in
         let result = fresh () in
         let applied = List.fold_right (fun a acc -> TFun (a, acc)) arg_tys result in
         let local_subst = (try unify empty_subst fn_ty applied with _ -> empty_subst) in
         List.iter (fun (pred, c_rigid) ->
           let concrete = apply local_subst (apply_int_map imap c_rigid) in
           if ty_is_ground concrete then begin
             let ok = match pred with
               | POrd -> ty_is_ord ctx concrete
               | PEq  -> ty_is_eq ctx concrete
             in
             if not ok then
               add_error ctx loc
                 (match pred with
                  | POrd -> Printf.sprintf
                      "ordering is not defined for type `%s` — it reaches a generic \
                       `<`/`>` comparison via `%s` (only Int, Float, PosixMillis, and \
                       newtypes over them are ordered)"
                      (pp_ty concrete) callee
                  | PEq -> Printf.sprintf
                      "equality is not defined for type `%s` — it reaches a generic \
                       `==`/`!=` comparison via `%s` (types with a function component \
                       have no decidable equality)"
                      (pp_ty concrete) callee)
           end
         ) constraints)
  ) !(ctx.ord_eq_calls)

let check_module_with_metadata ?(source_lines = [||]) (m : module_form) : local_binding_info list * expr_type_info list * field_access_info list * (Location.loc * string) list * (Location.loc * (string * string list)) list * (Location.loc * (string * string list)) list * type_error list =
  reset_counter ();
  (* First-Class Units: activate the quantity alias TYPE names this module
     imports from Tesl.Units.  Deliberately NOT restored on exit — the emit
     pass runs after the checker in the same compile and consults the state;
     re-activated below after import loading (a nested check of an imported
     module sets its own aliases). *)
  ignore (activate_units_aliases_for m);
  (* E1: one lazy folder-tree index per checked module — the scan only runs if
     an unbound-name error is actually emitted. *)
  let local_index = Import_suggest.build_local_index m in
  let suggest = Import_suggest.suggest m ~local_index in
  let import_errors = check_stdlib_import_names m in
  let import_errors = import_errors @ check_local_import_names m in
  let import_errors = import_errors @ check_type_names_in_scope ~suggest m in
  let import_errors = import_errors @ check_proof_predicate_scope m in
  let import_errors = import_errors @ check_fact_name_distinctness m in
  let import_errors = import_errors @ check_stdlib_fn_import_scope m in
  let import_errors = import_errors @ check_units_name_collisions m in
  let initial_env = make_stdlib_env () in
  let ctx = make_ctx ~source_lines ~filename:m.source_file ~env:initial_env () in
  let ctx = { ctx with import_suggest = suggest } in

  (* 1. Collect type definitions (records, ADTs, newtypes) *)
  let ctx = collect_type_defs ctx m.decls in
  (* hole #15: bring imported record/entity field types into scope so
     `imported.field` type-checks (local defs keep precedence — they are at the
     front of ctx.records, imported are appended). *)
  let ctx = { ctx with records = ctx.records @ load_imported_records m } in
  let imported_ctors = load_imported_ctors m in
  let (config_adts, config_ctors) = config_stdlib_seed m in
  let ctx = { ctx with
    ctors = config_ctors @ imported_ctors @ ctx.ctors;
    adts  = config_adts @ ctx.adts } in

  (* 2. Add ADT constructors and record types to env *)
  let ctx = {
    ctx with env =
      (* Add constructor types to env *)
      List.map (fun (name, (_, sch)) -> (name, sch)) ctx.ctors
      @ ctx.env
  } in

  (* 3. Add imported function signatures and this module's function signatures. *)
  let ctx = {
    ctx with
    env = load_imported_func_sigs m @ ctx.env;
    function_kinds = load_imported_func_kinds m @ ctx.function_kinds;
  } in
  (* re-activate THIS module's quantity aliases: loading an imported module
     above may have checked it and set its own (see activate note at entry) *)
  ignore (activate_units_aliases_for m);
  let ctx = collect_func_sigs ctx m.decls in
  let ctx = {
    ctx with
    proof_returns = collect_proof_returns m.decls;
    function_kinds = collect_func_kinds m.decls @ ctx.function_kinds;
  } in

  (* 3b. Add cache value types as synthetic env bindings "__cache_<Name>" → type *)
  let ctx =
    (* For the new typed `cache X = Cache { valueType: T … }` form the flat
       [value_type] field is filled by the desugar pass (which runs AFTER the
       checker), so resolve it from [config_expr] here. *)
    let cache_value_type (c : Ast.cache_form) : Ast.type_expr =
      match c.config_expr with
      | None -> c.value_type
      | Some e ->
        let fields = (match e with
          | Ast.ERecord { fields; _ } -> fields
          | Ast.EApp { fn = Ast.EConstructor _; arg = Ast.ERecord { fields; _ }; _ } -> fields
          | _ -> []) in
        (match List.assoc_opt "valueType" fields with
         | Some (Ast.EConstructor { name; _ })
         | Some (Ast.EApp { fn = Ast.EConstructor { name; _ }; _ }) ->
           Ast.TName { name; loc = c.loc }
         | _ -> c.value_type)
    in
    let cache_bindings = List.filter_map (function
      | DCache (c : Ast.cache_form) ->
        let ty = ty_of_type_expr (cache_value_type c) in
        Some ("__cache_" ^ c.name, mono ty)
      | _ -> None
    ) m.decls in
    (* A declarative `agent X = Agent { … }` binds the bare name [X] to type
       [Agent], so it resolves as a value where `ask`/`askReply`/`askWith` expect
       one (mirroring how a server name is a value). *)
    let agent_bindings = List.filter_map (function
      | DAgent (a : Ast.agent_form) ->
        Some (a.name, mono (ty_of_type_expr (Ast.TName { name = "Agent"; loc = a.loc })))
      | _ -> None
    ) m.decls in
    { ctx with env = agent_bindings @ cache_bindings @ ctx.env }
  in

  (* serverTools static env (see the [server_tools_env] doc on [ctx]): for each
     server, the auth user type its api binds and the non-SSE endpoints as
     (tool name, normalized auth predicates).  Tool names are the server-binding
     LHS names, paired positionally with the api's non-SSE endpoints exactly as
     the emitter pairs them (endpoint names in the AST are synthetic). *)
  let ctx =
    let api_of name = List.find_map (function
      | DApi (a : Ast.api_form) when a.name = name -> Some a
      | _ -> None) m.decls in
    let server_tools_env = List.filter_map (function
      | DServer (srv : Ast.server_form) ->
        (match api_of srv.api_name with
         | None -> Some (srv.name, (None, []))
         | Some api ->
           let non_sse =
             List.filter (fun (ep : Ast.api_endpoint) -> ep.method_ <> SSE)
               api.endpoints in
           let binding_names = List.map fst srv.bindings in
           let paired =
             if List.length binding_names = List.length non_sse then
               List.combine binding_names non_sse
             else
               (* Mismatched server ↔ api (its own validation error elsewhere);
                  fall back to the synthetic endpoint names so checking can
                  continue without pretending to know the tool names. *)
               List.map (fun (ep : Ast.api_endpoint) -> (ep.name, ep)) non_sse
           in
           let endpoints = List.map (fun (bname, (ep : Ast.api_endpoint)) ->
             { ste_binding = bname;
               ste_preds =
                 (match ep.auth with
                  | Some (a : Ast.api_auth) ->
                    (match a.binding.proof_ann with
                     | Some p -> normalized_preds_of_proof a.binding.name p
                     | None -> [])
                  | None -> []) }
           ) paired in
           let auth_ty = List.find_map (fun (ep : Ast.api_endpoint) ->
             match ep.auth with
             | Some (a : Ast.api_auth) ->
               (match a.binding.type_expr with
                | TName { name; _ } -> Some name
                | _ -> None)
             | None -> None) non_sse in
           Some (srv.name, (auth_ty, endpoints)))
      | _ -> None) m.decls in
    let server_tools_shadowed = List.exists (function
      | DFunc (fd : Ast.func_decl) -> fd.name = "serverTools"
      | DConst (c : Ast.const_form) -> c.name = "serverTools"
      | _ -> false) m.decls in
    let human_actions_shadowed = List.exists (function
      | DFunc (fd : Ast.func_decl) -> fd.name = "humanActions"
      | DConst (c : Ast.const_form) -> c.name = "humanActions"
      | _ -> false) m.decls in
    { ctx with server_tools_env; server_tools_shadowed; human_actions_shadowed }
  in

  (* 3c. Validate agent tool parameters: every tool must resolve to a local `fn`
     whose parameters are JSON-decodable primitives (the model's tool-call
     arguments are decoded from JSON through the codec path) and carry NO proof
     annotation (AGENT-1 — a proof on a model-supplied value would be fabricated).
     This runs for BOTH a declarative `agent X = Agent { … }` block AND an
     expression-position `Agent { … }` (BYOK), which previously skipped the check
     entirely (AGENT-2). *)
  let agent_tool_refs_of_fields fields =
    match List.assoc_opt "tools" fields with
    | Some (Ast.EList { elems; _ }) ->
      (* Each tool is `asTool <fn>`; recover the wrapped function name. *)
      List.filter_map (function
        | Ast.EApp { fn = Ast.EVar { name = "asTool"; _ }; arg = Ast.EVar { name; loc }; _ } -> Some (name, loc)
        | _ -> None) elems
    | _ -> []
  in
  (* Issue #24 (2026-07-05): `asTool` expands ONLY for a bare function reference
     (`asTool myFn`).  Applied to anything else — most importantly a partial
     application `asTool (myFn arg)` — the tools-list extractor above silently
     DROPPED the element (`| _ -> None`), so it type-checked, yet codegen has no
     `asTool` runtime binding and emitted the expression verbatim → the module
     failed to LOAD (`tesl test` ran zero tests).  A checker that accepts a form
     codegen cannot lower is the same fail-open class this compiler is being
     hardened against.  Fail closed: reject a malformed `asTool` at check time
     with an actionable message. *)
  let check_malformed_tool_forms agent_label fields =
    match List.assoc_opt "tools" fields with
    | Some (Ast.EList { elems; _ }) ->
      List.iter (function
        | Ast.EApp { fn = Ast.EVar { name = "asTool"; _ }; arg; loc } ->
          (match arg with
           | Ast.EVar _ -> ()   (* the one supported form: a bare reference *)
           | _ ->
             add_error ctx loc (Printf.sprintf
               "%s: `asTool` supports only a bare function reference (`asTool myFn`); \
                a partial application like `asTool (myFn arg)` is not supported — codegen \
                cannot derive the tool's JSON schema from it, so the emitted module would \
                fail to load. Define a wrapper `fn myTool(...) = myFn boundValue ...` that \
                closes over the bound value in its body, and pass `asTool myTool`."
               agent_label))
        | _ -> ()   (* manual `tool { … }` and other tool forms are validated elsewhere *)
      ) elems
    | _ -> ()
  in
  let check_agent_tool_refs agent_label tool_refs =
    List.iter (fun (tn, tloc) ->
      match List.find_opt (function DFunc fd -> fd.name = tn | _ -> false) m.decls with
      | Some (DFunc fd) ->
        List.iter (fun (b : Ast.binding) ->
          (match b.proof_ann with
           | Some _ ->
             add_error ctx b.loc (Printf.sprintf
               "%s: tool '%s' parameter '%s' must not carry a proof annotation (`:::`) — \
                the model supplies this argument as untrusted JSON, so a proof on it would be \
                fabricated, not validated; take the raw value and validate it inside the tool with a `check`"
               agent_label tn b.name)
           | None -> ());
          (* Whitelist is the single Validation_common.agent_prim registry (B4);
             the message type-list is DERIVED from it so it cannot drift. *)
          if Validation_common.agent_prim_of_type_expr b.type_expr = None then
            add_error ctx b.loc (Printf.sprintf
              "%s: tool '%s' parameter '%s' must be %s — agent tool arguments are decoded from the model's JSON"
              agent_label tn b.name Validation_common.agent_prim_whitelist_english)
        ) fd.params
      | _ ->
        add_error ctx tloc (Printf.sprintf
          "%s: tool '%s' is not a function declared in this module" agent_label tn)
    ) tool_refs
  in
  (* The record fields of an `Agent { … }` construction (either surface shape). *)
  let agent_fields_of_expr = function
    | Ast.ERecord { type_hint = Some "Agent"; fields; _ } -> Some fields
    | Ast.EApp { fn = Ast.EConstructor { name = "Agent"; _ }; arg = Ast.ERecord { fields; _ }; _ } -> Some fields
    | _ -> None
  in
  (* Declarative `agent X = Agent { … }` blocks. *)
  List.iter (function
    | DAgent (a : Ast.agent_form) ->
      (match a.config_expr with Some e -> ignore (infer_expr ctx e) | None -> ());
      let tool_refs =
        match a.config_expr with
        | Some e ->
          let fields = (match e with
            | Ast.ERecord { fields; _ } -> fields
            | Ast.EApp { fn = Ast.EConstructor _; arg = Ast.ERecord { fields; _ }; _ } -> fields
            | _ -> []) in
          check_malformed_tool_forms (Printf.sprintf "agent '%s'" a.name) fields;
          agent_tool_refs_of_fields fields
        | None -> List.map (fun n -> (n, a.loc)) a.tools
      in
      check_agent_tool_refs (Printf.sprintf "agent '%s'" a.name) tool_refs
    | _ -> ()) m.decls;
  (* AGENT-2: expression-position `Agent { … }` (BYOK) anywhere in a function body. *)
  let rec walk_agents_in_expr label (e : Ast.expr) : unit =
    (match agent_fields_of_expr e with
     | Some fields ->
       check_malformed_tool_forms label fields;
       check_agent_tool_refs label (agent_tool_refs_of_fields fields)
     | None -> ());
    ignore (Ast_visitor.fold_children (fun () c -> walk_agents_in_expr label c) () e)
  in
  List.iter (function
    | DFunc fd ->
      walk_agents_in_expr (Printf.sprintf "agent expression in `%s`" fd.name) fd.body
    (* Issue #24 (2026-07-05): a top-level value binding `name = Agent { … }`
       (a DConst, the idiomatic function-first agent form) was walked by NEITHER
       the DAgent path above NOR this expression walk (which only covered DFunc
       bodies), so its tool forms escaped both the AGENT-1/2 param checks and the
       malformed-`asTool` check.  Walk DConst values too. *)
    | DConst c ->
      walk_agents_in_expr (Printf.sprintf "agent expression in `%s`" c.name) c.value
    | _ -> ()) m.decls;

  (* 3d. serverTools endpoint-shape rules, validated once per server a
     `serverTools` expression actually references:
       - every capture parameter must be an agent-prim (the model supplies it as
         JSON; same single-source whitelist as `asTool` params);
       - every authed endpoint must bind the SAME user type (one value is
         partially applied to all included handlers).
     Per-endpoint predicate INCLUSION (who gets the admin-gated endpoints) is
     decided at each call site by the infer_expr arm; these are the rules that
     do not depend on the caller. *)
  (if not ctx.server_tools_shadowed then begin
    let method_str = function
      | Ast.GET -> "get" | Ast.POST -> "post" | Ast.PUT -> "put"
      | Ast.DELETE -> "delete" | Ast.PATCH -> "patch" | Ast.SSE -> "sse" in
    let used_servers : (string * Location.loc) list ref = ref [] in
    let rec walk_st (e : Ast.expr) : unit =
      (match e with
       | EApp { fn = EApp { fn = EVar { name = "serverTools"; _ }; arg = server_ref; _ }; loc; _ } ->
         (match server_ref with
          | EConstructor { name; args = []; _ } | EVar { name; _ } ->
            if not (List.mem_assoc name !used_servers) then
              used_servers := (name, loc) :: !used_servers
          | _ -> ())
       | _ -> ());
      Ast_visitor.fold_children (fun () c -> walk_st c) () e
    in
    List.iter (function
      | DFunc (fd : Ast.func_decl) -> walk_st fd.body
      | DConst (c : Ast.const_form) -> walk_st c.value
      | DTest (tf : Ast.test_form) ->
        List.iter (fun s -> List.iter walk_st (Ast.test_stmt_exprs s)) tf.stmts
      | _ -> ()) m.decls;
    List.iter (fun (sname, uloc) ->
      let srv_opt = List.find_map (function
        | DServer (s : Ast.server_form) when s.name = sname -> Some s
        | _ -> None) m.decls in
      let api_opt = match srv_opt with
        | Some srv -> List.find_map (function
            | DApi (a : Ast.api_form) when a.name = srv.api_name -> Some a
            | _ -> None) m.decls
        | None -> None in
      match api_opt with
      | None -> ()  (* unknown server / dangling api: reported elsewhere *)
      | Some api ->
        let eps = List.filter (fun (ep : Ast.api_endpoint) -> ep.method_ <> SSE)
            api.endpoints in
        (* one user type across all authed endpoints *)
        let auth_tys = List.filter_map (fun (ep : Ast.api_endpoint) ->
          match ep.auth with
          | Some (a : Ast.api_auth) ->
            Some (ep, (match a.binding.type_expr with
                       | TName { name; _ } -> name
                       | _ -> "?"))
          | None -> None) eps in
        (match auth_tys with
         | (_, first_ty) :: rest ->
           List.iter (fun ((ep : Ast.api_endpoint), ty) ->
             if ty <> first_ty then
               add_error ctx uloc (Printf.sprintf
                 "serverTools %s: endpoint `%s %s` authenticates a `%s` but other \
                  endpoints authenticate a `%s` — serverTools partially applies ONE \
                  user value, so every authed endpoint of the api must bind the same \
                  user type"
                 sname (method_str ep.method_) ep.path ty first_ty)) rest
         | [] -> ());
        (* capture params arrive as model JSON — agent-prim whitelist (B4) *)
        List.iter (fun (ep : Ast.api_endpoint) ->
          List.iter (fun (c : Ast.api_capture) ->
            if Validation_common.agent_prim_of_type_expr c.binding.type_expr = None then
              add_error ctx uloc (Printf.sprintf
                "serverTools %s: endpoint `%s %s` capture `%s` must be %s — an agent \
                 tool argument is decoded from the model's JSON"
                sname (method_str ep.method_) ep.path c.binding.name
                Validation_common.agent_prim_whitelist_english)) ep.captures) eps
    ) !used_servers
  end);

  (* 4. Type-check each declaration *)
  (* Top-level fn names that may shadow a SQL builtin — threaded into the §7.12
     FromDb-forgery gate so it decides DB sites by resolution, not spelling (S4b). *)
  let user_fn_names =
    List.filter_map (function DFunc d -> Some d.name | _ -> None) m.decls in
  List.iter (fun decl ->
    match decl with
    | DFunc fd ->
      check_func_decl ~user_fn_names ctx fd
    | DConst c ->
      let ty = infer_expr ctx c.value in
      (* Update the env with the inferred type *)
      (match env_lookup c.name ctx.env with
       | Some sch -> unify_at ctx c.loc ty (instantiate sch)
       | None -> ())
    | DTest t ->
      let test_env = make_stdlib_env () @ ctx.env in
      let test_ctx0 = { ctx with env = test_env; subst = ref empty_subst } in
      let rec check_test_stmts test_ctx stmts =
        List.fold_left (fun test_ctx stmt ->
          match stmt with
          | TsLetProof { value_name = name; proof_names; value; loc; _ } ->
            let ty = infer_expr test_ctx value in
            let value_meta = PlainBinding in
            let subject_chain = binding_subject_chain test_ctx name value in
            let value_hover_note = hover_note_for_meta ((name, subject_chain) :: test_ctx.subject_chain_env) name value_meta in
            record_local_binding ?hover_note:value_hover_note test_ctx name loc ty value_meta;
            let sch = generalize (free_vars_env test_ctx.env) !(test_ctx.subst) ty in
            let proof_meta = proof_meta_for_let_proof test_ctx name value in
            let test_ctx = {
              test_ctx with
              env = env_extend name sch test_ctx.env;
              binding_meta_env = (name, value_meta) :: test_ctx.binding_meta_env;
              subject_chain_env = (name, subject_chain) :: test_ctx.subject_chain_env;
            } in
            (* Register proof names as local bindings too (they hold proof values) *)
            List.fold_left (fun ctx pn ->
              let proof_hover_note = hover_note_for_meta ctx.subject_chain_env pn proof_meta in
              record_local_binding ?hover_note:proof_hover_note ctx pn loc t_fact proof_meta;
              { ctx with
                env = env_extend pn (mono t_fact) ctx.env;
                binding_meta_env = (pn, proof_meta) :: ctx.binding_meta_env;
              }
            ) test_ctx proof_names
          | TsLet { name; declared_type; value; loc; _ } ->
            let ty =
              match declared_type with
              | Some declared_type ->
                let expected_ty = ty_of_type_expr declared_type in
                ignore (check_expr test_ctx value
                  (mk_expectation ~origin:loc ~role:(LetBinding name)
                    ~reason:(local_let_reason name expected_ty) expected_ty));
                apply !(test_ctx.subst) expected_ty
              | None -> infer_expr test_ctx value
            in
            let meta = binding_meta_for_binding test_ctx name value in
            let subject_chain = binding_subject_chain test_ctx name value in
            let hover_note = hover_note_for_meta ((name, subject_chain) :: test_ctx.subject_chain_env) name meta in
            record_local_binding ?hover_note test_ctx name loc ty meta;
            let sch = generalize (free_vars_env test_ctx.env) !(test_ctx.subst) ty in
            {
              test_ctx with
              env = env_extend name sch test_ctx.env;
              binding_meta_env = (name, meta) :: test_ctx.binding_meta_env;
              subject_chain_env = (name, subject_chain) :: test_ctx.subject_chain_env;
            }
          | TsExpect { left; right; loc } ->
            let lt = infer_expr test_ctx left in
            (match right with
             | Some r ->
               let rt = infer_expr test_ctx r in
               unify_at test_ctx loc lt rt
             | None ->
               unify_at test_ctx loc lt t_bool);
            test_ctx
          | TsExpectFail { fn; arg; loc } ->
            let rec flatten_args acc a =
              match a with
              | EApp { fn = base; arg = last; _ } -> flatten_args (last :: acc) base
              | _ -> a :: acc
            in
            let full_call = match flatten_args [] arg with
              | [] -> EApp { fn; arg = EList { elems = []; loc }; loc }
              | first :: rest ->
                List.fold_left (fun call arg ->
                  EApp { fn = call; arg; loc }
                ) (EApp { fn; arg = first; loc }) rest
            in
            ignore (infer_expr test_ctx full_call);
            test_ctx
          | TsExpectHasProof { fn; arg; _ } ->
            ignore (infer_expr test_ctx fn, infer_expr test_ctx arg);
            test_ctx
          | TsProperty { params; body; loc; _ } ->
            let prop_ctx = List.fold_left (fun acc (p : property_param) ->
              { acc with env = env_extend p.binding.name (mono (ty_of_type_expr p.binding.type_expr)) acc.env }
            ) test_ctx params in
            List.iter (fun (p : property_param) ->
              match p.where_clause with
              | Some guard ->
                let gt = infer_expr prop_ctx guard in
                unify_at prop_ctx loc gt t_bool
              | None -> ()
            ) params;
            let bt = infer_expr prop_ctx body in
            unify_at prop_ctx loc bt t_bool;
            test_ctx
          | TsIf { cond; then_stmts; else_stmts; loc } ->
            let ct = infer_expr test_ctx cond in
            unify_at test_ctx loc ct t_bool;
            ignore (check_test_stmts test_ctx then_stmts);
            ignore (check_test_stmts test_ctx else_stmts);
            test_ctx
          | TsCase { scrut; arms; _ } ->
            ignore (infer_expr test_ctx scrut);
            List.iter (fun (arm : ts_case_arm) ->
              let arm_ctx = List.fold_left (fun acc name ->
                { acc with env = env_extend name (mono (fresh ())) acc.env }
              ) test_ctx (pattern_bound_names_helper arm.ts_pattern) in
              (match arm.ts_guard with
               | Some g -> ignore (infer_expr arm_ctx g)
               | None -> ());
              ignore (check_test_stmts arm_ctx arm.ts_body)
            ) arms;
            test_ctx
          | TsExpr { e; _ } ->
            ignore (infer_expr test_ctx e);
            test_ctx
        ) test_ctx stmts
      in
      ignore (check_test_stmts test_ctx0 t.stmts)
    | DApiTest t ->
      check_api_test_scope ctx m t.seed_stmts t.stmts
    | DLoadTest lt ->
      check_api_test_scope ctx m lt.seed_stmts lt.request_stmts
    | _ -> ()  (* codecs, databases, etc. — skip for Phase 2 *)
  ) m.decls;
  check_api_decl_types ctx m;
  (* Eq/Ord Layer 1b: fold in IMPORTED generic comparators' obligations (keyed by
     qualified/plain name) before discharge, so a cross-module `List.member fn xs`
     is rejected at compile time.  Local obligations (already in the table) take
     precedence — never overwrite a same-module entry. *)
  List.iter (fun (name, obligations) ->
    if not (Hashtbl.mem ctx.ord_eq_constraints name) then
      Hashtbl.replace ctx.ord_eq_constraints name obligations)
    (load_imported_ord_eq_constraints m);
  (* Eq/Ord Stage 3: discharge every recorded generic-comparison call now that
     all fns' obligations are known. *)
  check_ord_eq_calls ctx;

  (* 5. Check that all exported names actually exist in the module *)
  let decl_names = List.concat_map (function
    | DFunc fd -> [fd.name]
    | DConst c -> [c.name]
    | DType (TypeAdt { name; variants; _ }) ->
      name :: List.map (fun (v : Ast.adt_variant) -> v.ctor) variants
    | DType (TypeNewtype { name; _ }) | DType (TypeAlias { name; _ }) -> [name]
    | DRecord r -> [r.name]
    | DEntity e -> [e.name]
    | DDatabase db -> [db.name]
    | DApi api -> [api.name]
    | DServer srv -> [srv.name]
    | DAgent a -> [a.name]
    | DQueue q -> [q.name]
    | DChannel ch -> [ch.name]
    | DCapability cap -> [cap.name]
    | DFact f -> [f.name]
    | DWorkers w -> [w.name]
    | _ -> []
  ) m.decls in
  (* Proof predicates declared by check/auth/establish functions *)
  let predicate_names = List.concat_map (function
    | DFunc fd when is_proof_introducing_kind fd.kind ->
      let collect_pred = function
        | RetPlain { ty = TApp { head = TName { name = "Fact"; _ }; arg; _ }; _ } ->
          (match arg with
           | TApp { head = TName { name; _ }; _ } -> [name]
           | TName { name; _ } -> [name]
           | _ -> [])
        | RetPlain { ty = TApp { head = TName { name = "Maybe"; _ };
                                  arg = TApp { head = TName { name = "Fact"; _ }; arg = inner; _ }; _ }; _ } ->
          (match inner with
           | TApp { head = TName { name; _ }; _ } -> [name]
           | TName { name; _ } -> [name]
           | _ -> [])
        | RetAttached { binding = b; _ } ->
          (match b.proof_ann with
           | Some (PredApp { pred; _ }) -> [pred]
           | Some (PredAnd _) -> []  (* conjunction — collect individually if needed *)
           | _ -> [])
        | RetNamedPack { entity_proof; other_proof; _ } ->
          let pred_of_opt = function
            | None -> []
            | Some (PredApp { pred; _ }) -> [pred]
            | Some (PredAnd _) -> []
          in
          pred_of_opt entity_proof @ pred_of_opt other_proof
        | RetForAll { proof = PredApp { pred; _ }; _ }
        | RetMaybeForAll { proof = PredApp { pred; _ }; _ }
        | RetSetForAll { proof = PredApp { pred; _ }; _ }
        | RetMaybeSetForAll { proof = PredApp { pred; _ }; _ }
        | RetForAllDictValues { proof = PredApp { pred; _ }; _ }
        | RetForAllDictKeys   { proof = PredApp { pred; _ }; _ } -> [pred]
        | RetMaybeAttached { binding = b; _ } ->
          (match b.proof_ann with
           | Some (PredApp { pred; _ }) -> [pred]
           | Some (PredAnd _) -> []
           | _ -> [])
        | _ -> []
      in
      collect_pred fd.return_spec
    | _ -> []
  ) m.decls in

  (* Ownership check: a check/establish/auth function can only produce a predicate
     that is declared with `fact` in THIS module.  Importing a fact only grants
     the right to USE the predicate as a type, never to produce it. *)
  let locally_declared_facts =
    List.filter_map (function DFact { name; _ } -> Some name | _ -> None) m.decls
  in
  let rec collect_preds_from_proof = function
    | PredApp { pred; _ } -> [pred]
    | PredAnd { left; right; _ } ->
      collect_preds_from_proof left @ collect_preds_from_proof right
  in
  let extract_produced_preds_with_loc (fd : func_decl) : (string * Location.loc) list =
    let rec from_rs = function
      | RetPlain { ty = TApp { head = TName { name = "Fact"; _ }; arg; loc; _ }; _ } ->
        (match arg with
         | TApp { head = TName { name; _ }; _ } -> [(name, loc)]
         | TName { name; loc; _ } -> [(name, loc)]
         | _ -> [])
      | RetPlain { ty = TApp { head = TName { name = "Maybe"; _ };
                               arg = TApp { head = TName { name = "Fact"; _ }; arg = inner; loc; _ }; _ }; _ } ->
        (match inner with
         | TApp { head = TName { name; _ }; _ } -> [(name, loc)]
         | TName { name; loc; _ } -> [(name, loc)]
         | _ -> [])
      | RetAttached { binding = b; loc; _ } ->
        (match b.proof_ann with
         | Some p -> List.map (fun pred -> (pred, loc)) (collect_preds_from_proof p)
         | None -> [])
      | RetNamedPack { entity_proof; other_proof; loc; _ } ->
        let of_opt = function
          | None -> []
          | Some p -> List.map (fun pred -> (pred, loc)) (collect_preds_from_proof p)
        in
        of_opt entity_proof @ of_opt other_proof
      (* Route the WHOLE proof through collect_preds_from_proof (which recurses
         into PredAnd) so a CONJUNCTION `ForAll (P && Q)` produces BOTH P and Q
         for the ownership gate.  Matching only `PredApp` here (as before) let a
         function mint an unowned conjunct predicate: the compound fell through
         to `| _ -> []` and produced nothing, so the ownership check passed. *)
      | RetForAll { proof; loc; _ }
      | RetMaybeForAll { proof; loc; _ }
      | RetSetForAll { proof; loc; _ }
      | RetMaybeSetForAll { proof; loc; _ }
      | RetForAllDictValues { proof; loc; _ }
      | RetForAllDictKeys   { proof; loc; _ } ->
        List.map (fun pred -> (pred, loc)) (collect_preds_from_proof proof)
      | RetMaybeAttached { binding = b; loc; _ } ->
        (match b.proof_ann with
         | Some p -> List.map (fun pred -> (pred, loc)) (collect_preds_from_proof p)
         | None -> [])
      (* An existential return may itself carry a proof-producing inner spec. *)
      | RetExists { body; _ } -> from_rs body
      | RetPlain _ -> []
    in
    from_rs fd.return_spec
  in
  let fact_ownership_errors = List.concat_map (function
    | DFunc fd when is_proof_introducing_kind fd.kind ->
      List.filter_map (fun (pred, loc) ->
        (* Skip if it's a qualified name (already module-prefixed) or a type variable *)
        if String.contains pred '.' then None
        else if String.length pred > 0 && Char.lowercase_ascii pred.[0] = pred.[0] then None
        else if List.mem pred locally_declared_facts then None
        else
          let hint =
            if List.mem pred (collect_in_scope_type_names m) then
              Printf.sprintf " `%s` is declared in another module; only the declaring module may produce it." pred
            else
              Printf.sprintf " Declare it in this module with: `fact %s (...)`" pred
          in
          Some { loc; message = Printf.sprintf
            "fact ownership violation: `%s` can only be produced \
             (via check/establish/auth) in the module that declares it.%s" pred hint;
            fix = None }
      ) (extract_produced_preds_with_loc fd)
    | _ -> []
  ) m.decls in

  (* Re-export was removed 2026-07 (along with the `library` feature): a module may
     export ONLY names it declares locally, never a name it merely imported.  So
     imported-exposed names are NOT added here — exporting one now fails with the
     "only locally-defined names can be exported" error below. *)
  let all_known_names = decl_names @ predicate_names @ List.map fst ctx.ctors in
  let seen_exports : (string, Location.loc) Hashtbl.t = Hashtbl.create 16 in
  let export_errors = List.concat_map (fun export ->
    let n = match export with ExportName n | ExportAdt n -> n in
    let duplicate_error =
      match Hashtbl.find_opt seen_exports n with
      | Some first_loc ->
        [ { loc = Location.dummy_loc m.source_file;
            message = Printf.sprintf
              "module exposes duplicate name `%s` (first declared for export at line %d)"
              n (first_loc.start.line + 1); fix = None } ]
      | None ->
        Hashtbl.replace seen_exports n (Location.dummy_loc m.source_file);
        []
    in
    let unknown_error =
      if List.mem n all_known_names then []
      else [ {
        loc = Location.dummy_loc m.source_file;
        message = Printf.sprintf "module exposes unknown or non-local name `%s` \
                                  (only locally-defined names can be exported)" n;
        fix = None
      } ]
    in
    duplicate_error @ unknown_error
  ) m.exports in

  (* 6. Return collected errors and retained metadata — include stdlib import validation errors *)
  (List.rev !(ctx.local_bindings),
   List.rev !(ctx.expr_types),
   List.rev !(ctx.field_accesses),
   List.rev !(ctx.bare_record_hints),
   List.rev !(ctx.server_tools_sites),
   List.rev !(ctx.human_actions_sites),
   import_errors @ export_errors @ fact_ownership_errors @ List.rev !(ctx.errors))

let check_module_with_local_bindings (m : module_form) : local_binding_info list * type_error list =
  let local_bindings, _, _, _, _, _, errors = check_module_with_metadata m in
  (local_bindings, errors)

let check_module_with_expr_types (m : module_form) : expr_type_info list * type_error list =
  let _, expr_types, _, _, _, _, errors = check_module_with_metadata m in
  (expr_types, errors)

let check_module (m : module_form) : type_error list =
  let _, _, _, _, _, _, errors = check_module_with_metadata m in
  errors

let check_module_with_field_accesses (m : module_form) : field_access_info list * type_error list =
  let _, _, field_accesses, _, _, _, errors = check_module_with_metadata m in
  (field_accesses, errors)
