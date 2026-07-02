(** Validation passes (Phase 5 parity).

    Implements and wires the validation layer that sits after parsing/type/proof checking:
    1. Server binding completeness
    2. SQL/record field name validation
    3. Codec proof coverage validation
    4. Call-site proof satisfaction
    5. ForAll proof propagation at call sites
    6. Exists return/body validation *)

open Ast
open Location

(* ── Validation error ────────────────────────────────────────────────────── *)

type validation_error = {
  loc     : loc;
  message : string;
  hint    : string;
  (* B5: the manual deep-link topic for this error, decided by WHICH validation
     pass produced it (the orchestrator stamps it via [with_topic]).  Defaults to
     [TGeneric] so the ~172 [make_error] callsites need no churn; the orchestrator
     overrides per pass.  Resolved to an anchor by [Error_codes.anchor_of_topic]
     at render time — message text never routes the anchor. *)
  topic   : Error_codes.manual_topic;
}

let make_error ?(hint="") ?(topic=Error_codes.TGeneric) loc message =
  { loc; message; hint; topic }

(** Re-tag a whole pass's output with its manual topic in one place.  Used by the
    orchestrator ([validation.ml]) so a pass's errors route by the resolved pass,
    exactly once, never by message text. *)
let with_topic (t : Error_codes.manual_topic) (es : validation_error list)
  : validation_error list =
  List.map (fun e -> { e with topic = t }) es

let fmt_validation_error (e : validation_error) =
  Printf.sprintf "%s:%d:%d: validation: %s%s"
    e.loc.file (e.loc.start.line + 1) (e.loc.start.col + 1) e.message
    (if e.hint = "" then "" else Printf.sprintf "\n  hint: %s" e.hint)

(* ── SQL builtin registry — single source of truth (formal-review G2/S3) ─────
   The set of SQL operations the emitter lowers to a database call was restated
   by hand at ~8 sites with DIVERGENT membership; the capability write-set
   (`validation_capabilities.ml`) omitted [insertMany]/[updateAndReturnOne]/
   [deleteAndReturnResult] even though the emitter lowers all three to real DB
   writes — so a handler whose only write was one of them was statically
   inferred to need no [dbWrite] (formal-review CAP-A1).

   Classification now lives ONCE, in a closed variant with a TOTAL classifier
   (no `_` arm): adding an operation without classifying its effect is a
   non-exhaustive-match COMPILE ERROR, not a silent blind spot.  The name-keyed
   predicates below are derived from that classifier, so every string-matching
   site that consults them cannot drift from it. *)
type sql_effect = SqlRead | SqlWrite

type sql_op =
  | SqlSelect | SqlSelectOne | SqlSelectCount | SqlSelectSum | SqlSelectMax
  | SqlSelectMin | SqlSelectMany
  | SqlInsert | SqlInsertMany | SqlUpsert
  | SqlUpdate | SqlUpdateAndReturnOne
  | SqlDelete | SqlDeleteAndReturnResult

let sql_op_of_name : string -> sql_op option = function
  | "select"               -> Some SqlSelect
  | "selectOne"            -> Some SqlSelectOne
  | "selectCount"          -> Some SqlSelectCount
  | "selectSum"            -> Some SqlSelectSum
  | "selectMax"            -> Some SqlSelectMax
  | "selectMin"            -> Some SqlSelectMin
  | "selectMany"           -> Some SqlSelectMany
  | "insert"               -> Some SqlInsert
  | "insertMany"           -> Some SqlInsertMany
  | "upsert"               -> Some SqlUpsert
  | "update"               -> Some SqlUpdate
  | "updateAndReturnOne"   -> Some SqlUpdateAndReturnOne
  | "delete"               -> Some SqlDelete
  | "deleteAndReturnResult" -> Some SqlDeleteAndReturnResult
  | _                      -> None

(* TOTAL classifier — the [@@warning "-..."]-free exhaustive match is the
   enforcement: a new [sql_op] constructor without an effect here will not
   compile. *)
let sql_op_effect : sql_op -> sql_effect = function
  | SqlSelect | SqlSelectOne | SqlSelectCount | SqlSelectSum | SqlSelectMax
  | SqlSelectMin | SqlSelectMany -> SqlRead
  | SqlInsert | SqlInsertMany | SqlUpsert
  | SqlUpdate | SqlUpdateAndReturnOne
  | SqlDelete | SqlDeleteAndReturnResult -> SqlWrite

let all_sql_ops : sql_op list =
  [ SqlSelect; SqlSelectOne; SqlSelectCount; SqlSelectSum; SqlSelectMax;
    SqlSelectMin; SqlSelectMany; SqlInsert; SqlInsertMany; SqlUpsert;
    SqlUpdate; SqlUpdateAndReturnOne; SqlDelete; SqlDeleteAndReturnResult ]

let sql_op_name : sql_op -> string = function
  | SqlSelect -> "select" | SqlSelectOne -> "selectOne"
  | SqlSelectCount -> "selectCount" | SqlSelectSum -> "selectSum"
  | SqlSelectMax -> "selectMax" | SqlSelectMin -> "selectMin"
  | SqlSelectMany -> "selectMany"
  | SqlInsert -> "insert" | SqlInsertMany -> "insertMany" | SqlUpsert -> "upsert"
  | SqlUpdate -> "update" | SqlUpdateAndReturnOne -> "updateAndReturnOne"
  | SqlDelete -> "delete" | SqlDeleteAndReturnResult -> "deleteAndReturnResult"

(* Name-keyed predicates, derived from the registry — single point every
   string-matching site consults so membership cannot diverge. *)
let is_sql_builtin (n : string) : bool = sql_op_of_name n <> None
let is_sql_read_builtin (n : string) : bool =
  match sql_op_of_name n with Some o -> sql_op_effect o = SqlRead | None -> false
let is_sql_write_builtin (n : string) : bool =
  match sql_op_of_name n with Some o -> sql_op_effect o = SqlWrite | None -> false
let sql_read_op_names : string list =
  List.filter_map (fun o -> if sql_op_effect o = SqlRead then Some (sql_op_name o) else None) all_sql_ops
let sql_write_op_names : string list =
  List.filter_map (fun o -> if sql_op_effect o = SqlWrite then Some (sql_op_name o) else None) all_sql_ops

(* ── Agent tool-param primitive registry (single source, B4) ───────────────
   The set of parameter types an agent tool `fn` may take: the model supplies
   these as untrusted JSON, decoded through the codec path. ONE registry, three
   TOTAL classifiers; a new variant here fails to compile at every consumer
   (checker whitelist, decode-tag emitter, JSON-schema emitter) until handled.
   (mirrors the sql_op registry pattern above.) *)
type agent_prim = APString | APInt | APFloat | APBool | APPosixMillis

(* the ONLY membership test — the surface type name the user writes *)
let agent_prim_of_type_name : string -> agent_prim option = function
  | "String"      -> Some APString
  | "Int"         -> Some APInt
  | "Float"       -> Some APFloat
  | "Bool"        -> Some APBool
  | "PosixMillis" -> Some APPosixMillis
  | _             -> None

let agent_prim_type_name : agent_prim -> string = function
  | APString -> "String" | APInt -> "Int" | APFloat -> "Float"
  | APBool -> "Bool" | APPosixMillis -> "PosixMillis"

let all_agent_prims : agent_prim list =
  [ APString; APInt; APFloat; APBool; APPosixMillis ]

(* TOTAL: the tag `tesl-agent-decode-args` understands (Racket symbol name) *)
let agent_prim_decode_tag : agent_prim -> string = function
  | APString -> "string" | APInt -> "int" | APPosixMillis -> "int"
  | APFloat -> "float" | APBool -> "bool"

(* TOTAL: the JSON Schema property fragment for this primitive *)
let agent_prim_schema_prop : agent_prim -> string = function
  | APInt | APPosixMillis -> {|{"type":"integer"}|}
  | APFloat -> {|{"type":"number"}|}
  | APBool  -> {|{"type":"boolean"}|}
  | APString -> {|{"type":"string"}|}

(* English whitelist for diagnostics — derived, not hand-typed, so the error
   message cannot drift from the registry. e.g. "String, Int, Float, Bool, or
   PosixMillis". *)
let agent_prim_whitelist_english : string =
  match List.rev (List.map agent_prim_type_name all_agent_prims) with
  | [] -> ""
  | [x] -> x
  | last :: rest -> String.concat ", " (List.rev rest) ^ ", or " ^ last

(* helper: classify a type_expr (only nominal TName types can be primitives) *)
let agent_prim_of_type_expr (t : type_expr) : agent_prim option =
  match t with TName { name; _ } -> agent_prim_of_type_name name | _ -> None

(* ── §7.12 forgery-restriction helpers (single decision site, S4b) ─────────

   These two helpers used to be duplicated: [is_forgery_restricted_kind] was
   defined identically in both [checker.ml] and [validation_advanced.ml], and
   [body_has_db_site] existed twice — a shadow-aware copy in
   [validation_advanced.ml] and a NON-shadow-aware copy in [checker.ml].  The
   duplicated logic is exactly the kind of drift that let the
   insertMany/updateAndReturnOne/deleteAndReturnResult write-op omission slip in
   (fixed in S3/S4).  They now live here so every forgery gate consults ONE
   definition; the SQL op set comes from the registry above so it cannot diverge. *)

(* fn / handler / worker may use an attached (`:::`) proof return only if the
   proof was already carried on an input parameter (or is a genuine
   framework-produced provenance proof).  check / auth / establish are the only
   kinds that may introduce a fresh proof at a boundary.  deadWorker is excluded
   — its FromDeadQueue proof is infrastructure-produced and handled elsewhere. *)
let is_forgery_restricted_kind : func_kind -> bool = function
  | FnKind | HandlerKind | WorkerKind -> true
  | _ -> false

(* A FromDb provenance proof on a fn/handler/worker return is only
   framework-produced when the body actually runs a select/insert/upsert/…
   builtin.  A builtin SQL name only counts as a DB site when it RESOLVES to the
   builtin — i.e. it is NOT shadowed by a user-defined function of the same name
   (passed in [shadowed]) nor by a local let / let-proof / lambda / case binder.
   The language deliberately permits `fn select(...)` (test R57_B1); without this
   gate, naming a local function `select`/`insert` made `select a` look like a DB
   query and forged a `FromDb` provenance proof on a value that never touched the
   database.  Identifier privilege is decided by resolution, not spelling. *)
let body_has_db_site ?(shadowed : string list = []) (e : expr) : bool =
  let rec pat_names acc = function
    | PVar n -> n :: acc
    | PCon { fields; _ } -> List.fold_left (fun acc (_, p) -> pat_names acc p) acc fields
    | _ -> acc
  in
  let rec go (bound : string list) (e : expr) : bool =
    match e with
    | EVar { name; _ } -> is_sql_builtin name && not (List.mem name bound)
    | ELet { name; value; body; _ } -> go bound value || go (name :: bound) body
    | ELetProof { value_name; proof_name; value; body; _ } ->
      go bound value || go (value_name :: proof_name :: bound) body
    | ELambda { params; body; _ } ->
      go (List.map (fun (b : binding) -> b.name) params @ bound) body
    | ECase { scrut; arms; _ } ->
      go bound scrut
      || List.exists (fun (a : case_arm) -> go (pat_names bound a.pattern) a.body) arms
    | _ -> Ast_visitor.fold_children (fun found c -> found || go bound c) false e
  in
  go shadowed e

(* ── Proof helpers ───────────────────────────────────────────────────────── *)

let rec flatten_proof (p : proof_expr) : proof_expr list =
  match p with
  | PredAnd { left; right; _ } -> flatten_proof left @ flatten_proof right
  | other -> [other]

let rec pp_proof (p : proof_expr) : string =
  match p with
  | PredApp { pred; args = []; _ } -> pred
  | PredApp { pred; args; _ } -> pred ^ " " ^ String.concat " " args
  | PredAnd { left; right; _ } -> pp_proof left ^ " && " ^ pp_proof right

let rec pp_type_expr (te : type_expr) : string =
  match te with
  | TName { name; _ } -> name
  | TVar { name; _ } -> name
  | TApp { head; arg; _ } -> Printf.sprintf "%s %s" (pp_type_expr head) (pp_type_expr arg)
  | TFun { dom; cod; caps; _ } ->
    let arrow = Printf.sprintf "%s -> %s" (pp_type_expr dom) (pp_type_expr cod) in
    if caps = [] then arrow
    else Printf.sprintf "(%s requires %s)" arrow (String.concat ", " caps)
  | TTuple { elems; _ } -> Printf.sprintf "(%s)" (String.concat ", " (List.map pp_type_expr elems))

let strip_outer_parens (s : string) : string =
  let len = String.length s in
  if len >= 2 && s.[0] = '(' && s.[len - 1] = ')' then
    String.sub s 1 (len - 2)
  else
    s

(* B6: structural, injective proof key.  The old key rendered a proof to a
   single space-joined string, so `PredApp("P",["a b";"c"])` and
   `PredApp("P",["a";"b c"])` — both reachable via the parser's opaque
   parenthesised-arg capture and via [normalize_carried_forall]'s pp_proof'd
   inner rendering — collapsed to the SAME string "P a b c" and matched/deduped
   as equal.  Keeping pred and each arg as SEPARATE fields makes the pred/arg-0
   and inter-arg boundaries unambiguous.  Conjunctions are sorted so `P && Q`
   and `Q && P` dedup/match identically.  Comparison is polymorphic structural
   (=) over this variant, i.e. over the RESOLVED predicate identity (pred name)
   and the RESOLVED subject identities (the canonical arg strings produced by
   subst_proof_args_with_subjects / A4 literal identity keys). *)
type proof_key_t =
  | KApp of string * string list       (* (resolved pred, resolved args) *)
  | KAnd of proof_key_t list           (* sorted conjuncts, order-insensitive *)

let rec proof_key (p : proof_expr) : proof_key_t =
  match p with
  | PredApp { pred = "ForAll"; args = [proof_name; subject]; _ } ->
    (* Keep the required (parenthesised) and carried (bare) inner renderings
       comparable, matching the pre-B6 special case.  The inner is still one
       rendered field, but the pred/subject BOUNDARY is now unambiguous. *)
    KApp ("ForAll", [strip_outer_parens proof_name; subject])
  | PredApp { pred; args; _ } -> KApp (pred, args)
  | PredAnd { left; right; _ } ->
    let flat = function KAnd xs -> xs | k -> [k] in
    KAnd (List.sort compare (flat (proof_key left) @ flat (proof_key right)))
(* Note: pp_proof (above) remains the string renderer for DIAGNOSTICS only; it
   must never be used for equality (that would reintroduce the collision). *)

let rec proof_subjects (p : proof_expr) : string list =
  match p with
  | PredApp { args; _ } ->
    (* A4: literal VALUE occurrences are keyed `lit#<basename-no-ext>:line:col`
       (see [literal_occurrence_key] below).  Such a key starts with lowercase
       'l' and — because [literal_occurrence_key] strips the file extension —
       contains no '.' and no '(', so it PASSES this filter and is correctly
       treated as a trackable subject (like a variable).  This is WHY the
       extension MUST be stripped: a dotted key (e.g. `lit#foo.tesl:3:5`) would
       be silently dropped by the no-dot filter and re-open the provenance
       leak. *)
    List.filter (fun s ->
      String.length s > 0
      && s.[0] >= 'a' && s.[0] <= 'z'
      && not (String.contains s '.')
      && not (String.contains s '(')
    ) args
  | PredAnd { left; right; _ } -> proof_subjects left @ proof_subjects right

let rec proof_predicates (p : proof_expr) : string list =
  match p with
  | PredApp { pred; _ } -> [pred]
  | PredAnd { left; right; _ } -> proof_predicates left @ proof_predicates right

let subst_proof_arg (mapping : (string * string) list) (arg : string) : string =
  match List.assoc_opt arg mapping with
  | Some repl -> repl
  | None ->
    let len = String.length arg in
    let is_ident_char = function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' -> true
      | _ -> false
    in
    let buf = Buffer.create len in
    let flush_ident start_idx end_idx =
      if end_idx > start_idx then
        let token = String.sub arg start_idx (end_idx - start_idx) in
        Buffer.add_string buf (match List.assoc_opt token mapping with Some repl -> repl | None -> token)
    in
    let rec loop i ident_start =
      if i = len then begin
        (match ident_start with
         | Some start_idx -> flush_ident start_idx i
         | None -> ());
        Buffer.contents buf
      end else
        let ch = arg.[i] in
        if is_ident_char ch then
          match ident_start with
          | Some _ -> loop (i + 1) ident_start
          | None -> loop (i + 1) (Some i)
        else begin
          (match ident_start with
           | Some start_idx -> flush_ident start_idx i
           | None -> ());
          Buffer.add_char buf ch;
          loop (i + 1) None
        end
    in
    loop 0 None

let rec subst_proof (mapping : (string * string) list) (p : proof_expr) : proof_expr =
  match p with
  | PredApp ({ args; _ } as app) ->
    let args' = List.map (subst_proof_arg mapping) args in
    PredApp { app with args = args' }
  | PredAnd ({ left; right; _ } as conj) ->
    PredAnd { conj with left = subst_proof mapping left; right = subst_proof mapping right }

let rec expand_entity_proof_group (p : proof_expr) : proof_expr =
  match p with
  | PredApp ({ args; _ } as app) -> PredApp { app with args = args @ ["_entity"] }
  | PredAnd ({ left; right; _ } as conj) ->
    PredAnd {
      conj with
      left = expand_entity_proof_group left;
      right = expand_entity_proof_group right;
    }

(* A4: recover a literal occurrence key's CONTENT.  Occurrence keys are globally
   unique (file:line:col), so a global registry is sound: it maps each minted
   `lit#…` subject key to the literal's content-key.  Populated lazily whenever
   [subject_of_expr] mints an occurrence key (below).  Consulted by
   [canonicalize_content_args] to re-content content-parameter positions while
   subject positions stay occurrence-keyed. *)
let literal_occ_content : (string, string) Hashtbl.t = Hashtbl.create 64

let literal_content_of_key (key : string) : string option =
  Hashtbl.find_opt literal_occ_content key

(* A4: canonicalize the CONTENT-parameter positions of a proof predicate so that
   a literal used as a content parameter (e.g. `let lo = 1` feeding `Clamped 1
   100 n`) still matches by CONTENT, while the SUBJECT position keeps its
   per-occurrence literal identity.

   Convention (codebase-wide): the FINAL argument of a fact predicate is the
   subject; all LEADING arguments are content parameters.  We therefore rewrite
   every arg except the last, mapping any `lit#…` occurrence key back to its
   recorded content-key (identity otherwise).  The subject (last arg) is left
   untouched, so two distinct literal SUBJECTS never collapse.

   This is the arity-free "all-args-except-final" form (see spec A4): it needs no
   fact registry because a literal only ever reaches a LEADING position through a
   `let`-bound content parameter, and the subject is always last.  For 0/1-arg
   predicates there are no leading content positions, so nothing is rewritten. *)
let canonicalize_content_args (p : proof_expr) : proof_expr =
  let recover s = match literal_content_of_key s with Some c -> c | None -> s in
  let rec go = function
    | PredApp ({ args; _ } as app) ->
      let n = List.length args in
      let args' =
        List.mapi (fun i a -> if i < n - 1 then recover a else a) args
      in
      PredApp { app with args = args' }
    | PredAnd ({ left; right; _ } as conj) ->
      PredAnd { conj with left = go left; right = go right }
  in
  go p

let rec proof_matches (required : proof_expr) (carried : proof_expr list) : bool =
  let carried =
    List.concat_map flatten_proof carried |> List.map canonicalize_content_args
  in
  match required with
  | PredAnd { left; right; _ } ->
    proof_matches left carried && proof_matches right carried
  | _ ->
    (* B6: structural key equality (proof_key now returns proof_key_t) instead of
       rendered-string equality — cannot be fooled by arg-space rendering.
       A4: canonicalize content-parameter positions of both sides before the
       structural comparison, so content facts match by content and subjects by
       per-occurrence identity. *)
    let key = proof_key (canonicalize_content_args required) in
    List.exists (fun p -> proof_key p = key) carried

let pred_names_of_return_spec (spec : return_spec) : string list =
  let dedup xs = List.sort_uniq String.compare xs in
  match spec with
  | RetAttached { binding = b; _ } ->
    (match b.proof_ann with Some p -> dedup (proof_predicates p) | None -> [])
  | RetNamedPack { entity_proof; other_proof; _ } ->
    dedup (
      (match entity_proof with Some p -> proof_predicates p | None -> [])
      @ (match other_proof with Some p -> proof_predicates p | None -> [])
    )
  | _ -> []

(** Extract the element-level predicate names from a ForAll/MaybeForAll/SetForAll return spec. *)
let forall_preds_of_return_spec (spec : return_spec) : string list =
  match spec with
  | RetForAll { proof; _ }
  | RetMaybeForAll { proof; _ }
  | RetSetForAll { proof; _ }
  | RetMaybeSetForAll { proof; _ } -> proof_predicates proof
  | RetForAllDictValues { proof; _ } | RetForAllDictKeys { proof; _ } -> proof_predicates proof
  | _ -> []

(* ── Signature reference helpers ─────────────────────────────────────────── *)

(** All TName nodes in a type expression, with their source locations. *)
let rec type_names_with_locs (te : type_expr) : (string * loc) list =
  match te with
  | TName { name; loc } -> [(name, loc)]
  | TVar _ -> []
  | TApp { head; arg; _ } -> type_names_with_locs head @ type_names_with_locs arg
  | TFun { dom; cod; _ } -> type_names_with_locs dom @ type_names_with_locs cod
  | TTuple { elems; _ } -> List.concat_map type_names_with_locs elems

(** All PredApp nodes in a proof expression, with their source locations.
    Also captures UpperCamelCase args (e.g. the `IsPositive` in `ForAll IsPositive xs`)
    since those are predicate or type names, not variable names. *)
let rec pred_names_with_locs (pe : proof_expr) : (string * loc) list =
  match pe with
  | PredApp { pred; args; loc } ->
    let upper_args = List.filter_map (fun arg ->
      if String.length arg > 0 && Char.uppercase_ascii arg.[0] = arg.[0]
      then Some (arg, loc)
      else None
    ) args in
    (pred, loc) :: upper_args
  | PredAnd { left; right; _ } ->
    pred_names_with_locs left @ pred_names_with_locs right

let binding_sig_refs (b : binding) : (string * loc) list =
  type_names_with_locs b.type_expr
  @ (match b.proof_ann with None -> [] | Some pe -> pred_names_with_locs pe)

(** All type and predicate names referenced in a return spec. *)
let rec return_spec_sig_refs (rs : return_spec) : (string * loc) list =
  match rs with
  | RetPlain { ty; _ } -> type_names_with_locs ty
  | RetAttached { binding; _ } -> binding_sig_refs binding
  | RetNamedPack { ty; entity_proof; other_proof; _ } ->
    type_names_with_locs ty
    @ (match entity_proof with None -> [] | Some pe -> pred_names_with_locs pe)
    @ (match other_proof with None -> [] | Some pe -> pred_names_with_locs pe)
  | RetForAll { elem_ty; proof; _ }
  | RetMaybeForAll { elem_ty; proof; _ }
  | RetSetForAll { elem_ty; proof; _ }
  | RetMaybeSetForAll { elem_ty; proof; _ } ->
    type_names_with_locs elem_ty @ pred_names_with_locs proof
  | RetForAllDictValues { key_ty; val_ty; proof; _ }
  | RetForAllDictKeys   { key_ty; val_ty; proof; _ } ->
    type_names_with_locs key_ty @ type_names_with_locs val_ty @ pred_names_with_locs proof
  | RetMaybeAttached { outer_ty = Some ty; binding; _ } ->
    type_names_with_locs ty @ binding_sig_refs binding
  | RetMaybeAttached { binding; _ } -> binding_sig_refs binding
  | RetExists { binding; body; _ } ->
    binding_sig_refs binding @ return_spec_sig_refs body

(** All type and predicate names referenced in a function's parameter and return
    signature. These are the names consumers must have access to in order to
    call or use the function. *)
let func_sig_refs (fd : func_decl) : (string * loc) list =
  List.concat_map binding_sig_refs fd.params
  @ return_spec_sig_refs fd.return_spec

(* ── Type helpers ────────────────────────────────────────────────────────── *)

let gen_loc = dummy_loc "<validation>"

let mk_name_type name = TName { name; loc = gen_loc }
let mk_var_type name = TVar { name; loc = gen_loc }
let mk_app_type head arg = TApp { head; arg; loc = gen_loc }

let rec type_key (ty : type_expr) : string =
  match ty with
  | TName { name; _ } -> name
  | TVar { name; _ } -> name
  | TApp { head; arg; _ } -> type_key head ^ " " ^ type_key arg
  | TFun { dom; cod; _ } -> type_key dom ^ " -> " ^ type_key cod
  | TTuple { elems; _ } -> "(" ^ String.concat ", " (List.map type_key elems) ^ ")"

type func_info = {
  fi_name : string;
  fi_kind : func_kind;
  fi_params : binding list;
  fi_return : return_spec;
  fi_loc : loc;
}

type field_map = (string * field_def list) list
type type_env = (string * type_expr) list
type proof_env = (string * proof_expr list) list
type subject_env = (string * string) list
type ctor_info = (string * (type_expr list * type_expr)) list

(** Maps codec function names to the primitive type they encode/decode.
    Shared by codec field validation and capture codec validation. *)
let builtin_codec_type : (string * string) list = [
  "stringCodec",      "String";
  "intCodec",         "Int";
  "boolCodec",        "Bool";
  "floatCodec",       "Float";
  "posixMillisCodec", "PosixMillis";
  "listCodec",        "List";
  "dictCodec",        "Dict";
  "setCodec",         "Set";
]

(** Extract the head type constructor name from a type expression.
    Used by codec field and capture codec validation. *)
let type_head_name (te : type_expr) : string option =
  match te with
  | TName { name; _ } -> Some name
  | TApp { head = TName { name; _ }; _ } -> Some name
  | _ -> None

let rec return_value_type (spec : return_spec) : type_expr option =
  match spec with
  | RetPlain { ty; _ } -> Some ty
  | RetAttached { binding = b; _ } -> Some b.type_expr
  | RetNamedPack { ty; _ } -> Some ty
  | RetForAll { elem_ty; _ } -> Some (mk_app_type (mk_name_type "List") elem_ty)
  | RetMaybeForAll { elem_ty; _ } -> Some (mk_app_type (mk_name_type "Maybe") (mk_app_type (mk_name_type "List") elem_ty))
  | RetSetForAll { elem_ty; _ } -> Some (mk_app_type (mk_name_type "Set") elem_ty)
  | RetMaybeSetForAll { elem_ty; _ } -> Some (mk_app_type (mk_name_type "Maybe") (mk_app_type (mk_name_type "Set") elem_ty))
  | RetForAllDictValues { key_ty; val_ty; _ } ->
    Some (mk_app_type (mk_app_type (mk_name_type "Dict") key_ty) val_ty)
  | RetForAllDictKeys   { key_ty; val_ty; _ } ->
    Some (mk_app_type (mk_app_type (mk_name_type "Dict") key_ty) val_ty)
  | RetMaybeAttached { outer_ty = Some ty; _ } -> Some ty
  | RetMaybeAttached { binding = b; _ } ->
    Some (mk_app_type (mk_name_type "Maybe") b.type_expr)
  | RetExists { body; _ } -> return_value_type body

let record_fields_of_type (fields_by_type : field_map) (ty : type_expr) : field_def list option =
  match ty with
  | TName { name; _ } -> List.assoc_opt name fields_by_type
  | TApp { head = TName { name; _ }; _ } -> List.assoc_opt name fields_by_type
  | _ -> None

let zip_prefix xs ys =
  let rec go acc xs ys =
    match xs, ys with
    | x :: xs', y :: ys' -> go ((x, y) :: acc) xs' ys'
    | _ -> List.rev acc
  in
  go [] xs ys

let rec unify_type_vars subst pattern actual =
  match pattern, actual with
  | TVar { name; _ }, ty ->
    (match List.assoc_opt name subst with
     | None -> Some ((name, ty) :: subst)
     | Some existing when type_key existing = type_key ty -> Some subst
     | Some _ -> None)
  | TName { name = lhs; _ }, TName { name = rhs; _ } when lhs = rhs -> Some subst
  | TApp { head = h1; arg = a1; _ }, TApp { head = h2; arg = a2; _ } ->
    (match unify_type_vars subst h1 h2 with
     | Some subst' -> unify_type_vars subst' a1 a2
     | None -> None)
  | TFun { dom = d1; cod = c1; _ }, TFun { dom = d2; cod = c2; _ } ->
    (match unify_type_vars subst d1 d2 with
     | Some subst' -> unify_type_vars subst' c1 c2
     | None -> None)
  | TTuple { elems = xs; _ }, TTuple { elems = ys; _ } when List.length xs = List.length ys ->
    List.fold_left2 (fun acc x y ->
      match acc with
      | Some subst' -> unify_type_vars subst' x y
      | None -> None
    ) (Some subst) xs ys
  | _ when type_key pattern = type_key actual -> Some subst
  | _ -> None

let rec instantiate_type subst ty =
  match ty with
  | TVar { name; _ } -> (match List.assoc_opt name subst with Some ty' -> ty' | None -> ty)
  | TApp ({ head; arg; _ } as app) -> TApp { app with head = instantiate_type subst head; arg = instantiate_type subst arg }
  | TFun ({ dom; cod; _ } as fn) -> TFun { fn with dom = instantiate_type subst dom; cod = instantiate_type subst cod }
  | TTuple ({ elems; _ } as tup) -> TTuple { tup with elems = List.map (instantiate_type subst) elems }
  | TName _ -> ty

let instantiate_ctor_field_types result_ty scrut_ty field_tys =
  match unify_type_vars [] result_ty scrut_ty with
  | Some subst -> List.map (instantiate_type subst) field_tys
  | None -> field_tys

let field_type (fields_by_type : field_map) (ty : type_expr) (field_name : string) : type_expr option =
  match record_fields_of_type fields_by_type ty with
  | None -> None
  | Some fields ->
    match List.find_opt (fun (f : field_def) -> f.name = field_name) fields with
    | Some f -> Some f.type_expr
    | None -> None

let builtin_ctor_info : ctor_info = [
  ("Nothing", ([], mk_app_type (mk_name_type "Maybe") (mk_var_type "a")));
  ("Something", ([mk_var_type "a"], mk_app_type (mk_name_type "Maybe") (mk_var_type "a")));
  ("Ok", ([mk_var_type "a"], mk_app_type (mk_app_type (mk_name_type "Result") (mk_var_type "a")) (mk_var_type "e")));
  ("Err", ([mk_var_type "e"], mk_app_type (mk_app_type (mk_name_type "Result") (mk_var_type "a")) (mk_var_type "e")));
  ("Left", ([mk_var_type "a"], mk_app_type (mk_app_type (mk_name_type "Either") (mk_var_type "a")) (mk_var_type "b")));
  ("Right", ([mk_var_type "b"], mk_app_type (mk_app_type (mk_name_type "Either") (mk_var_type "a")) (mk_var_type "b")));
  ("Tuple2", ([mk_var_type "a"; mk_var_type "b"], mk_app_type (mk_app_type (mk_name_type "Tuple2") (mk_var_type "a")) (mk_var_type "b")));
  ("Tuple3", ([mk_var_type "a"; mk_var_type "b"; mk_var_type "c"], mk_app_type (mk_app_type (mk_app_type (mk_name_type "Tuple3") (mk_var_type "a")) (mk_var_type "b")) (mk_var_type "c")));
]

let build_ctor_info (decls : top_decl list) : ctor_info =
  let adt_ctors = List.concat_map (function
    | DType (TypeAdt { name; variants; _ }) ->
      let result_ty = mk_name_type name in
      List.map (fun (v : adt_variant) ->
        (v.ctor, (List.map (fun (f : field_def) -> f.type_expr) v.fields, result_ty))
      ) variants
    | DType (TypeNewtype { name; base_type; _ })
    | DType (TypeAlias { name; base_type; _ }) ->
      [ (name, ([base_type], mk_name_type name)) ]
    | _ -> []
  ) decls in
  adt_ctors @ builtin_ctor_info

let build_func_info (decls : top_decl list) : (string * func_info) list =
  List.filter_map (function
    | DFunc fd -> Some (fd.name, { fi_name = fd.name; fi_kind = fd.kind; fi_params = fd.params; fi_return = fd.return_spec; fi_loc = fd.loc })
    | _ -> None
  ) decls

let module_name_to_kebab name =
  let buf = Buffer.create (String.length name + 4) in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then begin
      Buffer.add_char buf '-';
      Buffer.add_char buf (Char.lowercase_ascii c)
    end else
      Buffer.add_char buf c
  ) name;
  Buffer.contents buf

let resolve_local_import_path source_file module_name =
  let dir = Filename.dirname source_file in
  let kebab_path = Filename.concat dir (module_name_to_kebab module_name ^ ".tesl") in
  if Sys.file_exists kebab_path then kebab_path
  else Filename.concat dir (module_name ^ ".tesl")

let normalize_exposed_type_name (name : string) : string option =
  let n = String.length name in
  let base =
    if n >= 4 && String.sub name (n - 4) 4 = "(..)" then
      String.sub name 0 (n - 4)
    else
      name
  in
  let parts = String.split_on_char '.' base in
  let local_name = match List.rev parts with
    | hd :: _ -> hd
    | [] -> base
  in
  if String.length local_name > 0 && local_name.[0] >= 'A' && local_name.[0] <= 'Z' then
    Some local_name
  else
    None

let load_imported_ctor_info (m : module_form) : ctor_info =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then []
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      if not (Sys.file_exists path) then []
      else
        let source = In_channel.with_open_text path In_channel.input_all in
        (match Parser.parse_module path source with
         | Err _ -> []
         | Ok imported ->
           let requested_types = match imp.names with
             | ImportAll -> None
              | ImportExposing names -> Some (List.filter_map normalize_exposed_type_name names)
           in
           List.concat_map (function
             | DType (TypeAdt { name; variants; _ }) ->
               let include_it = match requested_types with
                 | None -> true
                 | Some names -> List.mem name names
               in
               if not include_it then []
               else
                 let result_ty = mk_name_type name in
                 List.map (fun (v : adt_variant) ->
                   (v.ctor, (List.map (fun (f : field_def) -> f.type_expr) v.fields, result_ty))
                 ) variants
             | _ -> []
           ) imported.decls)
  ) m.imports

(* ── Stdlib proof metadata ───────────────────────────────────────────────── *)
(* func_info records for stdlib functions that have proof-annotated parameters.
   Used by load_imported_func_info so calls like `Int.divide n d` are checked
   for the required `d ::: IsNonZero d` proof at the call site. *)

let stdlib_func_infos : (string * func_info) list =
  let g = gen_loc in
  let tname n = TName { name = n; loc = g } in
  let param name ty proof = { name; type_expr = tname ty; proof_ann = proof; loc = g } in
  let plain name ty = param name ty None in
  let with_proof name ty pred = param name ty (Some (PredApp { pred; args = [name]; loc = g })) in
  let ret ty = RetPlain { ty = tname ty; loc = g } in
  let ret_attached name ty pred =
    RetAttached {
      binding = { name; type_expr = tname ty;
                  proof_ann = Some (PredApp { pred; args = [name]; loc = g }); loc = g };
      loc = g }
  in
  [
    (* Int.divide: second arg b must carry IsNonZero b *)
    ("Int.divide",
     { fi_name = "Int.divide"; fi_kind = FnKind;
       fi_params = [ plain "a" "Int"; with_proof "b" "Int" "IsNonZero" ];
       fi_return = ret "Int"; fi_loc = g });
    (* Int.modulo: second arg b must carry IsNonZero b *)
    ("Int.modulo",
     { fi_name = "Int.modulo"; fi_kind = FnKind;
       fi_params = [ plain "a" "Int"; with_proof "b" "Int" "IsNonZero" ];
       fi_return = ret "Int"; fi_loc = g });
    (* Float.div: second arg b must carry FloatNonZero b *)
    ("Float.div",
     { fi_name = "Float.div"; fi_kind = FnKind;
       fi_params = [ plain "a" "Float"; with_proof "b" "Float" "FloatNonZero" ];
       fi_return = ret "Float"; fi_loc = g });
    (* Float.requireNonZero: check function returning f ::: FloatNonZero f *)
    ("Float.requireNonZero",
     { fi_name = "Float.requireNonZero"; fi_kind = CheckKind;
       fi_params = [ plain "f" "Float" ];
       fi_return = ret_attached "f" "Float" "FloatNonZero"; fi_loc = g });
    (* Int.nonZero: check function returning n ::: IsNonZero n *)
    ("Int.nonZero",
     { fi_name = "Int.nonZero"; fi_kind = CheckKind;
       fi_params = [ plain "n" "Int" ];
       fi_return = ret_attached "n" "Int" "IsNonZero"; fi_loc = g });
    (* Int.nonNegative: check function returning n ::: IsNonNegative n *)
    ("Int.nonNegative",
     { fi_name = "Int.nonNegative"; fi_kind = CheckKind;
       fi_params = [ plain "n" "Int" ];
       fi_return = ret_attached "n" "Int" "IsNonNegative"; fi_loc = g });
    (* List.take: second arg n must carry IsNonNegative n *)
    ("List.take",
     { fi_name = "List.take"; fi_kind = FnKind;
       fi_params = [ with_proof "n" "Int" "IsNonNegative"; plain "xs" "List" ];
       fi_return = ret "List"; fi_loc = g });
    (* List.drop: second arg n must carry IsNonNegative n *)
    ("List.drop",
     { fi_name = "List.drop"; fi_kind = FnKind;
       fi_params = [ with_proof "n" "Int" "IsNonNegative"; plain "xs" "List" ];
       fi_return = ret "List"; fi_loc = g });
    (* List.repeat: element x first, count n second (matches Racket List.repeat x n) *)
    ("List.repeat",
     { fi_name = "List.repeat"; fi_kind = FnKind;
       fi_params = [ plain "x" "a"; with_proof "n" "Int" "IsNonNegative" ];
       fi_return = ret "List"; fi_loc = g });
    (* String.requireNonEmpty: check function returning s ::: IsNonEmpty s *)
    ("String.requireNonEmpty",
     { fi_name = "String.requireNonEmpty"; fi_kind = CheckKind;
       fi_params = [ plain "s" "String" ];
       fi_return = ret_attached "s" "String" "IsNonEmpty"; fi_loc = g });
    (* Dict.get: dict must carry HasKey key dict proof (dict has been proven to contain key) *)
    ("Dict.get",
     { fi_name = "Dict.get"; fi_kind = FnKind;
       fi_params = [ plain "key" "a";
                     param "dict" "Dict"
                       (Some (PredApp { pred = "HasKey"; args = ["key"; "dict"]; loc = g })) ];
       fi_return = ret "b"; fi_loc = g });
    (* Dict.requireKey: check function returning dict ::: HasKey key dict (2-arg proof) *)
    ("Dict.requireKey",
     { fi_name = "Dict.requireKey"; fi_kind = CheckKind;
       fi_params = [ plain "key" "a"; plain "dict" "Dict" ];
       fi_return = RetAttached {
         binding = { name = "dict"; type_expr = tname "Dict";
                     proof_ann = Some (PredApp { pred = "HasKey";
                                                 args = ["key"; "dict"]; loc = g });
                     loc = g };
         loc = g }; fi_loc = g });
    (* String.trim / trimLeft / trimRight: fn returning String ? IsTrimmed *)
    ("String.trim",
     { fi_name = "String.trim"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsTrimmed"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    ("String.trimLeft",
     { fi_name = "String.trimLeft"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsTrimmed"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    ("String.trimRight",
     { fi_name = "String.trimRight"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsTrimmed"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    (* String.toUpper / toLower *)
    ("String.toUpper",
     { fi_name = "String.toUpper"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsUpperCase"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    ("String.toLower",
     { fi_name = "String.toLower"; fi_kind = FnKind;
       fi_params = [ plain "s" "String" ];
       fi_return = RetNamedPack {
         ty = tname "String";
         entity_proof = Some (PredApp { pred = "IsLowerCase"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    (* List.sort / sortBy: fn returning List T ? IsSorted *)
    ("List.sort",
     { fi_name = "List.sort"; fi_kind = FnKind;
       fi_params = [ plain "xs" "List" ];
       fi_return = RetNamedPack {
         ty = tname "List";
         entity_proof = Some (PredApp { pred = "IsSorted"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
    ("List.sortBy",
     { fi_name = "List.sortBy"; fi_kind = FnKind;
       fi_params = [ plain "f" "a"; plain "xs" "List" ];
       fi_return = RetNamedPack {
         ty = tname "List";
         entity_proof = Some (PredApp { pred = "IsSorted"; args = []; loc = g });
         other_proof = None; loc = g };
       fi_loc = g });
  ]

let split_module_name (full : string) : string * string =
  match String.rindex_opt full '.' with
  | Some i ->
    (String.sub full 0 i,
     String.sub full (i + 1) (String.length full - i - 1))
  | None -> ("", full)

let load_imported_func_info (m : module_form) : (string * func_info) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then
      (* Return stdlib func_info entries for functions imported from this module *)
      let requested = match imp.names with
        | ImportAll -> None
        | ImportExposing names -> Some names
      in
      List.filter_map (fun (full_name, info) ->
        let include_it = match requested with
          | None -> true
          | Some names ->
            (* "Int.divide" is included if "Int.divide" or "divide" is in names *)
            let (_, local_name) = split_module_name full_name in
            List.mem full_name names || List.mem local_name names
        in
        if include_it then Some (full_name, info) else None
      ) stdlib_func_infos
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      if not (Sys.file_exists path) then []
      else
        let source = In_channel.with_open_text path In_channel.input_all in
        match Parser.parse_module path source with
        | Err _ -> []
        | Ok imported ->
          let requested = match imp.names with
            | ImportAll -> None
            | ImportExposing names -> Some names
          in
          List.concat_map (function
            | DFunc fd ->
              let info = { fi_name = fd.name; fi_kind = fd.kind; fi_params = fd.params; fi_return = fd.return_spec; fi_loc = fd.loc } in
              let qualified_name = imp.module_name ^ "." ^ fd.name in
              let include_plain = match requested with
                | Some names -> List.mem fd.name names
                | None -> false
              in
              let include_qualified = match requested with
                | Some names -> List.mem fd.name names
                | None -> true
              in
              (if include_plain then [ (fd.name, info) ] else [])
              @ (if include_qualified then [ (qualified_name, info) ] else [])
            | _ -> []
          ) imported.decls
  ) m.imports

(** Capability requirements (`requires [...]`) declared by IMPORTED functions,
    keyed by both their plain and module-qualified names.  This is what closes
    the cross-module capability hole: the capability validator merges this map
    into its callee→caps table so that calling an imported `requires [dbWrite]`
    function from a `requires []` function is rejected exactly as the single-file
    case is.  Tesl stdlib effect primitives are matched by name inside
    {!Validation_capabilities.collect_needed_capabilities} and so contribute
    nothing here.  Capability-ROW variables are dropped (mirroring
    {!Validation_capabilities.build_func_capability_map}) — only a function's
    concrete declared capabilities propagate to callers. *)
let load_imported_func_caps (m : module_form) : (string * string list) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then []
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      if not (Sys.file_exists path) then []
      else
        let source = In_channel.with_open_text path In_channel.input_all in
        match Parser.parse_module path source with
        | Err _ -> []
        | Ok imported ->
          let requested = match imp.names with
            | ImportAll -> None
            | ImportExposing names -> Some names
          in
          List.concat_map (function
            | DFunc fd ->
              let bound = Ast.func_bound_cap_vars fd in
              let caps = List.filter (fun c -> not (List.mem c bound)) fd.capabilities in
              let qualified_name = imp.module_name ^ "." ^ fd.name in
              let include_plain = match requested with
                | Some names -> List.mem fd.name names
                | None -> false
              in
              (if include_plain then [ (fd.name, caps) ] else [])
              @ [ (qualified_name, caps) ]
            | _ -> []
          ) imported.decls
  ) m.imports

(** Capabilities provided by each Tesl stdlib module, with their implication
    chains.  THIS IS THE SINGLE SOURCE OF TRUTH for stdlib capability providers:
    it is consumed both by the capability validator (below, via
    [load_imported_cap_map]) and by the proof checker
    ([Proof_checker.stdlib_capabilities], which references this binding rather
    than duplicating the literal so the two cannot drift). *)
let tesl_stdlib_cap_map : (string * (string * string list) list) list = [
  "Tesl.DB",         [("dbRead", []); ("dbWrite", ["dbRead"])];
  "Tesl.Time",       [("time", [])];
  "Tesl.Random",     [("random", [])];
  "Tesl.Env",        [("envRead", [])];
  "Tesl.Queue",      [("queueRead", []); ("queueWrite", ["queueRead"]); ("pubsub", [])];
  "Tesl.UUID",       [("uuid", [])];
  "Tesl.JWT",        [("jwt", [])];
  "Tesl.HttpClient", [("httpClient", [])];
  "Tesl.Agent",      [("aiProvider", ["httpClient"])];
]

let load_imported_cap_map (m : module_form) : (string * string list) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then
      (* For Tesl stdlib modules, use the static capability table *)
      (match List.assoc_opt imp.module_name tesl_stdlib_cap_map with
       | None -> []
       | Some caps ->
         let requested = match imp.names with
           | ImportAll -> None
           | ImportExposing names -> Some names
         in
         List.filter (fun (name, _) ->
           match requested with
           | Some names -> List.mem name names
           | None -> false
         ) caps)
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      if not (Sys.file_exists path) then []
      else
        let source = In_channel.with_open_text path In_channel.input_all in
        match Parser.parse_module path source with
        | Err _ -> []
        | Ok imported ->
          let requested = match imp.names with
            | ImportAll -> None
            | ImportExposing names -> Some names
          in
          List.concat_map (function
            | DCapability c ->
              let qualified_name = imp.module_name ^ "." ^ c.name in
              let include_plain = match requested with
                | Some names -> List.mem c.name names
                | None -> false
              in
              let include_qualified = match requested with
                | Some names -> List.mem c.name names
                | None -> true
              in
              (if include_plain then [ (c.name, c.implies) ] else [])
              @ (if include_qualified then [ (qualified_name, c.implies) ] else [])
            | _ -> []
          ) imported.decls
  ) m.imports

let check_adt_variant_names (decls : top_decl list) : validation_error list =
  List.concat_map (function
    | DType (TypeAdt { name; variants; loc; _ }) ->
      List.filter_map (fun (v : adt_variant) ->
        if v.ctor = name then
          Some (make_error loc
            (Printf.sprintf
               "constructor '%s' has the same name as its type — rename the constructor (e.g. 'Mk%s')"
               v.ctor name))
        else None
      ) variants
    | _ -> []
  ) decls

(* R51_T03 — self-referential type alias / newtype. `type Foo = Foo` is not
   a meaningful nominal declaration; the base type is the alias itself. We
   forbid it at declaration time so the error lives where the bug lives,
   not at every use site. *)
let check_self_referential_aliases (decls : top_decl list) : validation_error list =
  let rec mentions_name name (te : type_expr) =
    match te with
    | TName { name = n; _ } -> n = name
    | TVar _ -> false
    | TApp { head; arg; _ } -> mentions_name name head || mentions_name name arg
    | TFun { dom; cod; _ } -> mentions_name name dom || mentions_name name cod
    | TTuple { elems; _ } -> List.exists (mentions_name name) elems
  in
  List.concat_map (function
    | DType (TypeAlias { name; base_type; loc })
    | DType (TypeNewtype { name; base_type; loc }) ->
      if mentions_name name base_type then
        [ make_error loc
            (Printf.sprintf
               "type `%s` is self-referential: the base type mentions `%s`, which creates an infinite alias. Rename the alias or use a recursive ADT declaration (`type %s = Mk%s %s` or multi-variant form)."
               name name name name name) ]
      else []
    | _ -> []
  ) decls

let collect_import_parse_errors (m : module_form) : validation_error list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.filter_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then None
    else
      let path = resolve_local_import_path m.source_file imp.module_name in
      if not (Sys.file_exists path) then None
      else
        let source = In_channel.with_open_text path In_channel.input_all in
        match Parser.parse_module path source with
        | Ok _ -> None
        | Err e -> Some (make_error e.loc
            (Printf.sprintf "imported module '%s' has a parse error: %s" imp.module_name e.msg))
  ) m.imports

let build_fields_map (decls : top_decl list) : field_map =
  List.filter_map (function
    | DRecord r -> Some (r.name, r.fields)
    | DEntity e -> Some (e.name, e.fields)
    | _ -> None
  ) decls

let rec collect_call_head_and_args acc = function
  | EApp { fn; arg; _ } -> collect_call_head_and_args (arg :: acc) fn
  | fn -> (fn, acc)

let normalize_explicit_check_call head args =
  match head, args with
  | EVar { name = "check"; _ }, check_fn :: check_args -> (check_fn, check_args)
  | _ -> (head, args)

let function_name_of_expr = function
  | EVar { name; _ } -> Some name
  | EField { obj = EConstructor { name = mod_name; args = []; _ }; field; _ }
  | EField { obj = EVar { name = mod_name; _ }; field; _ } -> Some (mod_name ^ "." ^ field)
  | _ -> None

let rec flatten_check_chain_expr acc = function
  | EBinop { op = BAnd; left; right; _ } ->
    flatten_check_chain_expr (flatten_check_chain_expr acc right) left
  | other -> other :: acc

(** Detect SQL DSL expressions buried under WHERE-clause operator chains.

    The Tesl SQL DSL parses e.g.:
      selectCount m from T where m.x == v && m.y == w
    as:
      BAnd(BEq(App(App(App(App(selectCount, m), from), T), where_m.x), v),
           BEq(m.y, w))

    Similarly, WHERE filters with comparison operators:
      select p from Product where p.price > minPrice
    is parsed as:
      BGt(App(App(App(App(select, p), from), Product), where_p.price), minPrice)

    The left spine through BAnd / BEq / BNeq / BGt / BGe / BLt / BLe → EApp leads
    to the actual SQL function.  We follow it recursively to detect SQL expressions
    so that the ordering-operator validation pass can skip SQL predicate syntax. *)
let rec infer_sql_aggregate_type (e : expr) : type_expr option =
  match e with
  | EApp _ ->
    let (head, _) = collect_call_head_and_args [] e in
    (match function_name_of_expr head with
     | Some ("selectCount" | "selectSum" | "selectMin" | "selectMax") ->
       Some (mk_name_type "Int")
     | Some ("select" | "selectMany") ->
       Some (mk_app_type (mk_name_type "List") (mk_var_type "a"))
     | Some "selectOne" ->
       Some (mk_app_type (mk_name_type "Maybe") (mk_var_type "a"))
     | _ -> None)
  | EBinop { op = BAnd | BEq | BNeq | BGt | BGe | BLt | BLe; left; _ } ->
    infer_sql_aggregate_type left
  | _ -> None

let rec infer_expr_type
    (env : type_env)
    (funcs : (string * func_info) list)
    (fields_by_type : field_map)
    (ctors : ctor_info)
    (e : expr)
    : type_expr option =
  (* Check for SQL aggregate expressions buried under WHERE-clause chains first,
     before the regular BAnd/BEq → Bool inference runs. *)
  match infer_sql_aggregate_type e with
  | Some ty -> Some ty
  | None ->
  match e with
  | ELit { lit = LInt _; _ } -> Some (mk_name_type "Int")
  | ELit { lit = LBigInt _; _ } -> Some (mk_name_type "Int")
  | ELit { lit = LFloat _; _ } -> Some (mk_name_type "Float")
  | ELit { lit = LBool _; _ } -> Some (mk_name_type "Bool")
  | ELit { lit = LString _; _ } | ELit { lit = LInterp _; _ } -> Some (mk_name_type "String")
  | EVar { name; _ } ->
    (match List.assoc_opt name env with
     | Some ty -> Some ty              (* local binding / param wins (shadowing) *)
     | None ->
       (* Bare reference to a top-level fn of arity >= 1 is itself a function
          value; resolve it to its curried arrow so function-value comparison is
          rejected by is_equatable/is_orderable (A5, option A).  A NULLARY
          top-level fn (fi_params = []) stays None here — its bare use is its
          RESULT value, matching the existing `pi == pi` positive test — so
          privilege/shape is decided by RESOLUTION over funcs, never by spelling. *)
       (match List.assoc_opt name funcs with
        | Some info when info.fi_params <> [] ->
          (match return_value_type info.fi_return with
           | Some cod ->
             Some (List.fold_right
                     (fun (b : binding) acc ->
                        TFun { dom = b.type_expr; cod = acc; caps = []; loc = gen_loc })
                     info.fi_params cod)
           | None -> None)
        | _ -> None))
  | EField { obj; field; _ } ->
    (match infer_expr_type env funcs fields_by_type ctors obj with
     | Some obj_ty -> field_type fields_by_type obj_ty field
     | None -> None)
  | ERecord { type_hint = Some type_name; _ } -> Some (mk_name_type type_name)
  | ERecord _ -> None
  | EList { elems = []; _ } -> Some (mk_app_type (mk_name_type "List") (mk_name_type "a"))
  | EList { elems = hd :: _; _ } ->
    (match infer_expr_type env funcs fields_by_type ctors hd with
     | Some elem_ty -> Some (mk_app_type (mk_name_type "List") elem_ty)
     | None -> None)
  | EIf { then_; else_; _ } ->
    (match infer_expr_type env funcs fields_by_type ctors then_,
           infer_expr_type env funcs fields_by_type ctors else_ with
     | Some t1, Some t2 when type_key t1 = type_key t2 -> Some t1
     | Some t, None | None, Some t -> Some t
     | _ -> None)
  | ECase { arms; _ } ->
    let arm_types = List.filter_map (fun (arm : case_arm) ->
      infer_expr_type env funcs fields_by_type ctors arm.body
    ) arms in
    (match arm_types with
     | first :: rest when List.for_all (fun t -> type_key t = type_key first) rest -> Some first
     | first :: _ -> Some first
     | [] -> None)
  | ELet { name; value; body; _ } ->
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (name, ty) :: env
      | None -> env
    in
    infer_expr_type env' funcs fields_by_type ctors body
  | ELetProof { value_name; value; body; _ } ->
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (value_name, ty) :: env
      | None -> env
    in
    infer_expr_type env' funcs fields_by_type ctors body
  | EOk { value; _ } -> infer_expr_type env funcs fields_by_type ctors value
  | EFail _ -> None
  | ETelemetry _ | EEnqueue _ | EPublish _ | EStartWorkers _ -> Some (mk_name_type "Unit")
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    infer_expr_type env funcs fields_by_type ctors body
  | EServe _ -> Some (mk_name_type "Unit")
  | ELambda { params; body; _ } ->
    (* A lambda literal is a function value; infer its curried arrow from the
       params' declared types over the body's inferred codomain (A5, option A).
       If the body does not infer, stay None (matches prior behavior) — this only
       ever tightens the comparison check, never loosens it. *)
    let env' =
      List.map (fun (b : binding) -> (b.name, b.type_expr)) params @ env in
    (match infer_expr_type env' funcs fields_by_type ctors body with
     | Some cod ->
       Some (List.fold_right
               (fun (b : binding) acc ->
                  TFun { dom = b.type_expr; cod = acc; caps = []; loc = gen_loc })
               params cod)
     | None -> None)
  | EBinop { op; _ } ->
    (match op with
     | BAnd | BOr | BEq | BNeq | BLt | BLe | BGt | BGe -> Some (mk_name_type "Bool")
     | BConcat -> Some (mk_name_type "String")
     | _ -> Some (mk_name_type "Int"))
  | EUnop { op; _ } -> (match op with UNot -> Some (mk_name_type "Bool") | UNeg -> Some (mk_name_type "Int"))
  | EConstructor { name; _ } ->
    (match List.assoc_opt name ctors with
     | Some (_, result_ty) -> Some result_ty
     | None -> None)
  | EApp _ ->
    let (head, args) = collect_call_head_and_args [] e in
    (match function_name_of_expr head with
    | Some fn_name ->
      (* Check user-defined functions first, then known SQL built-in return types. *)
      (match List.assoc_opt fn_name funcs with
       | Some info ->
         let arity = List.length info.fi_params in
         let n = List.length args in
         if n < arity then
           (* Under-applied: the value IS a function.  Build the curried arrow
              from the UNconsumed params to the (fully-applied) return type.
              Decide-by-resolution: the resolved semantic object is an arrow, so
              comparison's is_equatable/is_orderable reject it directly instead of
              relying on a syntactic AST-shape allowlist (S14b / A5). *)
           (match return_value_type info.fi_return with
            | Some cod ->
              let rem =
                List.filteri (fun i _ -> i >= n) info.fi_params
                |> List.map (fun (b : binding) -> b.type_expr) in
              (* rem is non-empty when n < arity, so this yields at least one TFun. *)
              Some (List.fold_right
                      (fun dom acc -> TFun { dom; cod = acc; caps = []; loc = gen_loc })
                      rem cod)
            | None -> None)   (* return type unknown -> stay conservative *)
         else
           return_value_type info.fi_return   (* fully/over-applied: unchanged *)
       | None ->
         (* A5 / review §6.4: the head is not a top-level fn but may be a
            function-typed BINDING in scope — a higher-order PARAMETER
            (`f: Int -> Int -> Int`) or a let bound to one.  Unwind its arrow by
            the number of applied args, so an under-applied HOF-param value
            resolves to a TFun and function-value comparison is rejected by
            is_equatable/is_orderable (decide-by-resolution, not by whether the
            head happens to be in the top-level funcs table). *)
         (match List.assoc_opt fn_name env with
          | Some head_ty when (match head_ty with TFun _ -> true | _ -> false) ->
            let rec unwind ty n =
              if n <= 0 then ty
              else (match ty with TFun { cod; _ } -> unwind cod (n - 1) | _ -> ty)
            in
            Some (unwind head_ty (List.length args))
          | _ ->
         (match fn_name with
          | "selectCount" | "selectSum" | "selectMin" | "selectMax" ->
            Some (mk_name_type "Int")
          | "select" | "selectMany" ->
            Some (mk_app_type (mk_name_type "List") (mk_var_type "a"))
          | "selectOne" ->
            Some (mk_app_type (mk_name_type "Maybe") (mk_var_type "a"))
          | "upsert" -> Some (mk_name_type "Unit")
          | _ -> None)))
    | None -> None)
  | ECacheGet _ -> Some (mk_app_type (mk_name_type "Maybe") (mk_name_type "a"))
  | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _ -> Some (mk_name_type "Unit")
  | ESendEmail _ | EStartEmailWorker _ -> Some (mk_name_type "Unit")
  | ERuntimeCall _ -> Some (mk_name_type "Unit")  (* desugar-only infra call → Unit *)

let rec pattern_bindings (scrut_ty : type_expr option) (ctors : ctor_info) (pat : pattern) : type_env =
  match pat with
  | PWild | PNullary _ | PLit _ -> []
  | PVar name ->
    (match scrut_ty with Some ty -> [ (name, ty) ] | None -> [])
  | PCon { ctor; fields; _ } ->
    let field_types = match List.assoc_opt ctor ctors, scrut_ty with
      | Some (tys, result_ty), Some scrut_ty -> instantiate_ctor_field_types result_ty scrut_ty tys
      | Some (tys, _), None -> tys
      | None, _ -> []
    in
    List.concat_map (fun ((_, sub_pat), ty) ->
      pattern_bindings (Some ty) ctors sub_pat
    ) (zip_prefix fields field_types)
    |> fun ok -> if ok = [] && fields <> [] then
         (* fallback: collect PVar names at any depth with Unknown type *)
         let rec collect_vars = function
           | PVar n -> [(n, mk_name_type "Unknown")]
           | PCon { fields; _ } -> List.concat_map (fun (_, p) -> collect_vars p) fields
           | _ -> []
         in
         List.concat_map (fun (_, sub_pat) -> collect_vars sub_pat) fields
       else ok

let normalize_carried_forall (result_name : string) (proof : proof_expr) : proof_expr =
  (* Use pp_proof to include literal args (e.g. "HasMin 10" from `HasMin 10 n`).
     The proof here has already had the element-subject stripped (it came from the
     `?` return-type annotation, where the element subject is implicit). *)
  PredApp { pred = "ForAll"; args = [pp_proof proof; result_name]; loc = gen_loc }

let normalize_carried_forall_dict_values (result_name : string) (proof : proof_expr) : proof_expr =
  PredApp { pred = "ForAllValues"; args = [pp_proof proof; result_name]; loc = gen_loc }

let normalize_carried_forall_dict_keys (result_name : string) (proof : proof_expr) : proof_expr =
  PredApp { pred = "ForAllKeys"; args = [pp_proof proof; result_name]; loc = gen_loc }

let name_of_proof_type_arg (ty : type_expr) : string option =
  match ty with
  | TName { name; _ } -> Some name
  | TVar { name; _ } -> Some name
  | _ -> None

let proof_of_fact_type (ty : type_expr) : proof_expr option =
  let extract_from_fact_type arg =
    type_expr_to_proof_expr arg
  in
  match ty with
  | TApp { head = TName { name = "Fact"; _ }; arg; _ } ->
    extract_from_fact_type arg
  (* Maybe (Fact P) — the inner proof, for establish functions returning optional proofs *)
  | TApp { head = TName { name = "Maybe"; _ };
           arg  = TApp { head = TName { name = "Fact"; _ }; arg = inner; _ }; _ } ->
    extract_from_fact_type inner
  | _ -> None
let proofs_of_return_spec
    (result_name : string)
    ?(param_mapping = [])
    (spec : return_spec)
    : proof_expr list =
  let attach_binding_proof (binding : binding) =
    (* Use the param_mapping's subject for this binding name ONLY when the mapping is
       non-trivial (maps to a different name). Self-mappings like rawLabel → rawLabel mean
       the result should be indexed by result_name.

       E.g. checkPositive(n: Int) -> n: Int ::: Positive n, called on `raw`:
         param_mapping = [("n","raw")] → "n" ≠ "raw" → use "raw" → proof = Positive raw
       E.g. sanitize(rawLabel: String) -> rawLabel: String ::: Sanitized rawLabel, called on `rawLabel`:
         param_mapping = [("rawLabel","rawLabel")] → self-map → use result_name → proof = Sanitized validLabel *)
    let subject_for_binding = match List.assoc_opt binding.name param_mapping with
      | Some s -> s      (* use the argument's subject (consistent with subject_env propagation) *)
      | None -> result_name  (* param not in mapping → use result_name *)
    in
    let mapping = (binding.name, subject_for_binding)
                  :: List.filter (fun (name, _) -> name <> binding.name) param_mapping in
    match binding.proof_ann with
    | Some proof -> [ subst_proof mapping proof ]
    | None -> []
  in
  match spec with
  | RetAttached { binding; _ } -> attach_binding_proof binding
  | RetNamedPack { entity_proof; other_proof; _ } ->
    let entity_mapping = ("_entity", result_name) :: param_mapping in


    (match entity_proof with
     | Some proof -> [ subst_proof entity_mapping (expand_entity_proof_group proof) ]
     | None -> [])
    @ (match other_proof with Some proof -> [ subst_proof param_mapping proof ] | None -> [])
  | RetForAll { proof; _ } -> [ normalize_carried_forall result_name (subst_proof param_mapping proof) ]
  | RetMaybeForAll { proof; _ } -> [ normalize_carried_forall result_name (subst_proof param_mapping proof) ]
  | RetSetForAll { proof; _ } -> [ normalize_carried_forall result_name (subst_proof param_mapping proof) ]
  | RetMaybeSetForAll { proof; _ } -> [ normalize_carried_forall result_name (subst_proof param_mapping proof) ]
  | RetForAllDictValues { proof; _ } ->
    [ normalize_carried_forall_dict_values result_name (subst_proof param_mapping proof) ]
  | RetForAllDictKeys { proof; _ } ->
    [ normalize_carried_forall_dict_keys result_name (subst_proof param_mapping proof) ]
  | RetMaybeAttached { binding; _ } -> attach_binding_proof binding
  | RetExists _ -> []
  | RetPlain { ty; _ } -> (match proof_of_fact_type ty with Some proof -> [ subst_proof param_mapping proof ] | None -> [])

let rec flatten_proof_conj (proof : proof_expr) : proof_expr list =
  match proof with
  | PredAnd { left; right; _ } -> flatten_proof_conj left @ flatten_proof_conj right
  | _ -> [proof]

let combine_proof_list (loc : loc) (proofs : proof_expr list) : proof_expr option =
  match proofs with
  | [] -> None
  | first :: rest ->
    Some (List.fold_left (fun acc proof -> PredAnd { left = acc; right = proof; loc }) first rest)

(** Substitute proof argument names using subject_env, so that a user-written
    annotation like [Fact (NonEmpty ne)] (where [ne] has subject [raw]) is
    normalised to [NonEmpty raw] before comparison against the tracked proofs. *)
let rec subst_proof_args_with_subjects (subject_env : subject_env) (proof : proof_expr) : proof_expr =
  match proof with
  | PredApp { pred; args; loc } ->
    let args' = List.map (subst_proof_arg subject_env) args in
    PredApp { pred; args = args'; loc }
  | PredAnd { left; right; loc } ->
    PredAnd {
      left  = subst_proof_args_with_subjects subject_env left;
      right = subst_proof_args_with_subjects subject_env right;
      loc;
    }

let rec normalize_proof_aliases (proof_env : proof_env) (proof : proof_expr) : proof_expr =
  match proof with
  | PredApp ({ pred; args = []; loc } as app) ->
    (match List.assoc_opt pred proof_env with
     | Some proofs ->
       (match combine_proof_list loc proofs with
        | Some combined -> combined
        | None -> PredApp app)
     | None -> PredApp app)
  | PredApp { pred = "introAnd"; args; loc } ->
    (* introAnd pf1 pf2 → conjunction of all proofs from each argument *)
    let component_proofs = List.filter_map (fun arg ->
      match List.assoc_opt arg proof_env with
      | Some proofs -> combine_proof_list loc proofs
      | None -> None
    ) args in
    (match combine_proof_list loc component_proofs with
     | Some combined -> combined
     | None -> proof)
  | PredApp { pred = (("andLeft" | "andRight") as proj); args = [pf_name]; loc } ->
    (* andLeft/andRight narrow a conjunction proof to one conjunct:
       andLeft P&&Q ⇒ P, andRight P&&Q ⇒ Q. *)
    (match List.assoc_opt pf_name proof_env with
     | Some proofs ->
       let flat =
         List.concat_map
           (let rec f = function
              | PredAnd { left; right; _ } -> f left @ f right
              | p -> [p]
            in f) proofs
       in
       (match flat with
        | _ :: _ :: _ ->
          if proj = "andLeft" then List.hd flat
          else List.nth flat (List.length flat - 1)
        | _ -> (match combine_proof_list loc proofs with
                | Some combined -> combined
                | None -> proof))
     | None -> proof)
  | PredApp _ -> proof
  | PredAnd { left; right; loc } ->
    PredAnd {
      left = normalize_proof_aliases proof_env left;
      right = normalize_proof_aliases proof_env right;
      loc;
    }

(* A4: the CONTENT-key of a literal — its stable string identity, as the parser
   also captures a literal proof ARGUMENT (parser.ml:398-410).  Used to recover
   a literal's content when it sits in a content-PARAMETER position of a fact. *)
let literal_content_key (lit : lit) : string option =
  match lit with
  | LInt n -> Some (string_of_int n)
  (* A9/HM-1: a huge Int literal's canonical signed decimal string IS its stable
     content identity.  It flows through the SAME per-occurrence subject machinery
     as LInt (subject_of_expr's ELit arm mints a location-keyed occurrence key and
     records this content in literal_occ_content), so a huge literal cannot alias a
     textually-equal one at another position — mirroring A4's LInt treatment. *)
  | LBigInt s -> Some s
  | LFloat f -> Some (Float_fmt.identity_key f)
  | LString s -> Some ("\"" ^ s ^ "\"")
  | LBool b -> Some (if b then "true" else "false")
  | _ -> None

(* A4: a fresh, user-unspellable SUBJECT key for each literal VALUE occurrence,
   keyed by source location.  Contains '#' and ':' so it is not a legal
   identifier a user can spell, and can never equal a parser-captured content
   arg.  The file extension is stripped so the key contains no '.', and thus
   PASSES proof_subjects' no-dot filter (treated as a real, trackable subject —
   see the comment on proof_subjects).  Two textually-equal literals at
   DIFFERENT source positions get DISTINCT keys, so a proof earned about one
   literal cannot be reused for a second, independently-authored identical
   literal (the provenance/taint forgery this closes). *)
let literal_occurrence_key (loc : loc) : string =
  Printf.sprintf "lit#%s:%d:%d"
    (Filename.remove_extension (Filename.basename loc.file))
    loc.start.line loc.start.col

let rec subject_of_expr (subject_env : subject_env) (expr : expr) : string option =
  match expr with
  | EVar { name; _ } ->
    Some (match List.assoc_opt name subject_env with Some subject -> subject | None -> name)
  | EOk { value; _ } -> subject_of_expr subject_env value
  (* BSUBJ-1 (review §4.1): a field selector is PART of the subject identity.
     Collapsing `o.fieldA` to `o`'s subject let a proof about one field satisfy a
     requirement about a sibling field of the same type (the trusted-beside-
     untrusted request-DTO shape).  Qualify the subject with the field name so
     `o.fieldA` and `o.fieldB` are DISTINCT subjects.  Both the proof side and the
     requirement side route through here, so legitimate same-field proofs still
     match.  If the object has no stable subject we stay fail-closed (None →
     bind-and-recheck), never widening. *)
  | EField { obj; field; _ } ->
    (match subject_of_expr subject_env obj with
     | Some obj_subject -> Some (obj_subject ^ "." ^ field)
     | None -> None)
  | EApp _ ->
    let (head, args) = collect_call_head_and_args [] expr in
    (match function_name_of_expr head, args with
     | Some "attachFact", value :: _ -> subject_of_expr subject_env value
     | Some "forgetFact", [value]
     | Some "detachFact", [value] -> subject_of_expr subject_env value
     (* Note: we do NOT propagate subjects for arbitrary function calls here,
        as that would incorrectly equate the result subject with arg subjects for
        non-identity functions (e.g. database selectors, transformers). *)
     | _ -> None)
  (* A4: a literal VALUE occurrence is its OWN, per-occurrence subject (keyed by
     source location), NOT its rendered text.  This is the soundness change: two
     textually-equal literals are DIFFERENT subjects, so a proof about one cannot
     be reused for the other.  Its CONTENT is recorded in [literal_occ_content]
     so content-PARAMETER positions (e.g. the `10` in `HasMin 10 n`, the `1 100`
     in `Clamped 1 100 n`) still match by content via [canonicalize_content_args].
     S15's collision-free float key is preserved as the recorded content. *)
  | ELit { lit; loc } when literal_content_key lit <> None ->
    let occ = literal_occurrence_key loc in
    (match literal_content_key lit with
     | Some content -> Hashtbl.replace literal_occ_content occ content
     | None -> ());
    Some occ
  | EUnop { op = UNeg; arg = ELit { lit = (LInt _ as l); loc }; _ } ->
    let occ = literal_occurrence_key loc in
    (match l with LInt n -> Hashtbl.replace literal_occ_content occ ("-" ^ string_of_int n) | _ -> ());
    Some occ
  | EUnop { op = UNeg; arg = ELit { lit = (LFloat _ as l); loc }; _ } ->
    let occ = literal_occurrence_key loc in
    (match l with LFloat f -> Hashtbl.replace literal_occ_content occ (Float_fmt.identity_key (-. f)) | _ -> ());
    Some occ
  | _ -> None

(** Extract proofs from an evidence expression (second arg to attachFact).
    When [funcs] is provided, inline establish/check function calls are resolved. *)
let rec proofs_of_evidence_expr
    ?(funcs : (string * func_info) list = [])
    (subject_env : subject_env)
    (proof_env : proof_env)
    (expr : expr)
    : proof_expr list option =
  match expr with
  | EVar { name; _ } -> List.assoc_opt name proof_env
  | EBinop { op = BAnd; left; right; _ } ->
    (match proofs_of_evidence_expr ~funcs subject_env proof_env left,
           proofs_of_evidence_expr ~funcs subject_env proof_env right with
     | Some left_proofs, Some right_proofs -> Some (left_proofs @ right_proofs)
     | _ -> None)
  | EOk { value; proof; _ } ->
    (* `value ::: proof_expr` as evidence: both the value's proofs and the proof annotation.
       The value may be an establish call (e.g. `positive n` returns IsPositive n),
       and the proof may be an establish function call (e.g. `nonzero n` returns NonZero n).
       Combine both. *)
    let value_proofs = proofs_of_evidence_expr ~funcs subject_env proof_env value in
    (* Resolve the proof annotation: if it's an establish function call, get its predicates *)
    let resolve_proof_predicate p = match p with
      | PredApp { pred; args; _ } when funcs <> [] ->
        (match List.assoc_opt pred funcs with
         | Some info when info.fi_kind = EstablishKind ->
           (* Map establish function params to their argument names *)
           let param_mapping = List.filter_map (fun ((param : binding), arg) ->
             match arg with
             | arg_name ->
               let subject = match List.assoc_opt arg_name subject_env with
                 | Some s -> s | None -> arg_name
               in
               Some (param.name, subject)
           ) (zip_prefix info.fi_params args) in
           proofs_of_return_spec "_" ~param_mapping info.fi_return
         | _ -> flatten_proof_conj (normalize_proof_aliases proof_env p))
      | _ -> flatten_proof_conj (normalize_proof_aliases proof_env p)
    in
    let proof_proofs = resolve_proof_predicate proof in
    (match value_proofs with
     | Some vp -> Some (vp @ proof_proofs)
     | None -> Some proof_proofs)
  | EApp _ ->
    let (head, args) = collect_call_head_and_args [] expr in
    (match function_name_of_expr head, args with
     | Some ("detachFact" | "detachAllFact"), [value] ->
       proofs_of_evidence_expr ~funcs subject_env proof_env value
     | Some fn_name, _ when funcs <> [] ->
       (* When funcs is available, resolve inline establish/check calls.
          E.g. `attachFact forgotten (validPort y)` — evidence is `validPort y`. *)
       (match List.assoc_opt fn_name funcs with
        | Some info ->
          let param_mapping = List.filter_map (fun ((param : binding), arg) ->
            match subject_of_expr subject_env arg with
            | Some subject -> Some (param.name, subject)
            | None -> None
          ) (zip_prefix info.fi_params args) in
          let preds = proofs_of_return_spec "_" ~param_mapping info.fi_return in
          if preds = [] then None else Some preds
        | None -> None)
     | _ -> None)
  | _ -> None

(** Module-level registry of field-name → (param_name, proof_expr) for all
    proof-annotated record/entity fields.  Set by [check_call_site_proofs] before
    the traversal so that [carried_proofs_of_expr] can look up field proofs without
    threading an extra parameter through every call site. *)
let field_proof_registry : (string * (string * proof_expr)) list ref = ref []

(** Build a flat map from field name to (field_param_name, proof_expr) for all
    proof-annotated record/entity fields in [decls]. *)
let build_field_proof_map (decls : top_decl list) : (string * (string * proof_expr)) list =
  List.concat_map (function
    | DRecord r ->
      List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | Some p -> Some (f.name, (f.name, p))
        | None -> None
      ) r.fields
    | DEntity e ->
      List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | Some p -> Some (f.name, (f.name, p))
        | None -> None
      ) e.fields
    | _ -> []
  ) decls

(** ADT-constructor field proofs, POSITIONAL (review 2026-07 PFC-2 part a).
    `ctor -> [(field_name, proof_ann option)]` in declaration order, for variants
    with at least one proof-annotated field.  Used to PROPAGATE a field proof to a
    pattern binder on destructuring: `case t of Node l cur r -> …` gives `cur` the
    `value` field's `::: P` proof (renamed subject field_name -> binder).  Sound
    because field proofs are now enforced at CONSTRUCTION (PFC-2b / a0). *)
let ctor_field_proof_registry : (string * (string * proof_expr option) list) list ref = ref []

let build_ctor_field_proof_map (decls : top_decl list)
    : (string * (string * proof_expr option) list) list =
  List.concat_map (function
    | DType (TypeAdt { variants; _ }) ->
      List.filter_map (fun (v : adt_variant) ->
        if not (List.exists (fun (f : field_def) -> f.proof_ann <> None) v.fields)
        then None
        else Some (v.ctor, List.map (fun (f : field_def) -> (f.name, f.proof_ann)) v.fields)
      ) variants
    | _ -> []
  ) decls

(** Precomputed module-level facts, derived once from a module's [decls] (and the
    imported function infos) and threaded through the validation passes that would
    otherwise rebuild them on every call.

    Invariants preserved verbatim from the per-pass recomputation:
      - [mf_funcs] is exactly [build_func_info decls @ extra_funcs] — the LOCAL
        decls first, then the IMPORTED/extra funcs appended (order is significant
        for List.assoc shadowing semantics).
      - [mf_field_proof_map] is [build_field_proof_map decls]; passes that use the
        mutable [field_proof_registry] still assign/reset it themselves, but assign
        FROM this precomputed value rather than recomputing. *)
type module_facts = {
  mf_funcs : (string * func_info) list;       (* build_func_info decls @ extra_funcs *)
  mf_fields_map : field_map;                  (* build_fields_map decls *)
  mf_ctors : ctor_info;                       (* build_ctor_info decls *)
  mf_field_proof_map : (string * (string * proof_expr)) list; (* build_field_proof_map decls *)
  mf_ctor_field_proof_map : (string * (string * proof_expr option) list) list; (* build_ctor_field_proof_map decls *)
  (* Validation-consolidation Phase 1: per-decl projections extracted ONCE here
     instead of being re-filtered out of [decls] by every structural/codec pass.
     Each list preserves the SOURCE ORDER of [decls] (List.filter_map is
     order-preserving), so any pass that iterates one of these in place of a
     [List.concat_map (function DApi.. | _ -> [])] over [decls] produces a
     byte-identical error stream — the dropped [_ -> []] branch contributed
     nothing. *)
  mf_api_forms : api_form list;               (* every DApi form, in source order *)
  mf_entities  : entity_form list;            (* every DEntity form, in source order *)
  mf_codecs    : codec_form list;             (* every DCodec form, in source order *)
}

(** Compute all module-level facts ONCE. [extra_funcs] are the imported/extra
    function infos that must be appended (NOT prepended) to the local ones, exactly
    as each pass did with [build_func_info decls @ extra_funcs]. *)
let build_module_facts ?(extra_funcs : (string * func_info) list = []) (decls : top_decl list) : module_facts =
  {
    mf_funcs = build_func_info decls @ extra_funcs;
    mf_fields_map = build_fields_map decls;
    mf_ctors = build_ctor_info decls;
    mf_field_proof_map = build_field_proof_map decls;
    mf_ctor_field_proof_map = build_ctor_field_proof_map decls;
    mf_api_forms = List.filter_map (function DApi af -> Some af | _ -> None) decls;
    mf_entities  = List.filter_map (function DEntity e -> Some e | _ -> None) decls;
    mf_codecs    = List.filter_map (function DCodec cf -> Some cf | _ -> None) decls;
  }

(** Resolve module facts for a pass: use the precomputed [facts] when threaded
    through (the orchestrator path), else fall back to recomputing them from
    [decls]/[extra_funcs] (the standalone/test path). The recomputation is
    byte-identical to what each pass previously did inline. *)
let facts_or_compute
    ?(facts : module_facts option)
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list) : module_facts =
  match facts with
  | Some f -> f
  | None -> build_module_facts ~extra_funcs decls
