(** Hindley-Milner type checker for Tesl.

    Implements Robinson unification + Algorithm W with let-polymorphism.
    No T_ANY / wildcard type exists — every expression has a fully resolved
    type or the checker emits a located error.

    Design:
    - Fresh unification variables: positive integer IDs
    - Rigid/named variables: negative integer IDs (in type schemes)
    - Substitution: int -> ty association list (small maps, chained)
    - Errors: accumulated, not raised (except internal TypeMismatch) *)

open Location

(* ── Type representation ──────────────────────────────────────────────────── *)

type var_id = int

(** The type language. *)
type ty =
  | TVar of var_id         (** Unification variable (>0) or rigid named var (<0) *)
  | TCon of string          (** Type constructor: Int, String, Bool, Float, List … *)
  | TApp of ty * ty         (** Left-associative type application: List Int, Dict k v *)
  | TFun of ty * ty         (** Function type: dom -> cod (binary, curried) *)

(** A type scheme ∀α₁…αₙ.τ  — rigid var IDs are the quantified variables. *)
type scheme = {
  vars : int list;   (** Rigid variable IDs (-1, -2, …) that are universally quantified *)
  mono : ty;         (** The underlying monotype *)
}

let mono ty = { vars = []; mono = ty }

(* ── Built-in type constants ─────────────────────────────────────────────── *)

let t_int     = TCon "Int"
let t_int32   = TCon "Int32"   (* NT-07: nominal, does not unify with Int *)
let t_string  = TCon "String"
let t_bool    = TCon "Bool"
let t_float   = TCon "Float"
let t_unit    = TCon "Unit"
let t_posix   = TCon "PosixMillis"
let t_timezone = TCon "TimeZone"
let t_fact    = TCon "Fact"
let t_delete_result = TCon "DeleteResult"
let t_jwt_token  = TCon "JwtToken"
(* Tesl.Http's request.  Opaque: it has no record type, and field reads on it go
   through the checker's [opaque_special_field_types] escape hatch, so this alias
   exists only to give `Http.sessionToken` an argument type that a `String` or an
   entity cannot be passed for. *)
let t_http_request = TCon "HttpRequest"
(* Tesl.Crypto.  All three are nominal wrappers over String.
   PasswordHash and Secret are additionally SECRET (redacted at every rendering
   sink); Signature is not, because a MAC tag is public data.
   PasswordHash and Signature have NO constructor row in [stdlib_env] on
   purpose — that is exactly what makes them opaque, so `PasswordHash "hunter2"`
   is an unknown-constructor error rather than a blessed lie. *)
let t_password_hash = TCon "PasswordHash"
let t_signature     = TCon "Signature"
let t_secret        = TCon "Secret"
(* Tesl.Sso (roadmap/next/ensure_sso_works.md, Phase 3).  Both OPAQUE nominal
   types, like Secret/PasswordHash: no constructor row in stdlib_env, so
   `SsoConnection x` / `SsoSubjectKey x` are unknown-constructor errors.  An
   SsoConnection is built by `Sso.defaults`; an SsoSubjectKey (the storable,
   email-free identity key) is read out with `Sso.keyText`. *)
let t_sso_connection  = TCon "SsoConnection"
let t_sso_subject_key = TCon "SsoSubjectKey"
let t_sso_identity    = TCon "SsoIdentity"
let t_sso_provider    = TCon "SsoProvider"
(* First-Class Units: Money is nominal like PosixMillis; its currency is a
   runtime qualifier (a `Currency` value, like TimeZone), NOT an SI dimension. *)
let t_money         = TCon "Money"
let t_currency      = TCon "Currency"
let t_exchange_rate = TCon "ExchangeRate"
(* A dimensioned quantity: canonical nominal TCon from the exponent vector
   (units_catalog.ml).  Erases to Float at runtime. *)
let t_quantity (d : Units_catalog.dim) = TCon (Units_catalog.dim_name d)
(* Money PER quantity (hourly rate, price per kg): currency inside the value,
   denominator dimension in the type — `Money / Duration : MoneyPerDuration`,
   `rate * Duration : Money`. *)
let t_money_rate (d : Units_catalog.dim) = TCon (Units_catalog.money_rate_name d)
let t_http_response = TCon "HttpResponse"
let t_agent       = TCon "Agent"
let t_llm_provider = TCon "LlmProvider"
let t_agent_reply = TCon "AgentReply"
let t_tool        = TCon "Tool"
let t_tool_step   = TCon "ToolStep"
let t_conversation = TCon "Conversation"
let t_conversation_turn = TCon "ConversationTurn"

let t_list a        = TApp (TCon "List", a)
let t_maybe a       = TApp (TCon "Maybe", a)
let t_set a         = TApp (TCon "Set", a)
let t_dict k v      = TApp (TApp (TCon "Dict", k), v)
let t_either a b    = TApp (TApp (TCon "Either", a), b)
let t_result ok e   = TApp (TApp (TCon "Result", ok), e)
let t_tuple2 a b    = TApp (TApp (TCon "Tuple2", a), b)
let t_tuple3 a b c  = TApp (TApp (TApp (TCon "Tuple3", a), b), c)

(** Build a curried function type: t_fun [A; B; C] = A -> B -> C *)
let rec t_fun params result =
  match params with
  | []     -> result
  | [a]    -> TFun (a, result)
  | a :: rest -> TFun (a, t_fun rest result)

(* ── Fresh variable counter ──────────────────────────────────────────────── *)

let _counter = ref 0

let fresh () =
  incr _counter;
  TVar !_counter

let fresh_id () =
  incr _counter;
  !_counter

let reset_counter () =
  _counter := 0

(* ── Substitution ─────────────────────────────────────────────────────────── *)

(** A substitution maps unification variable IDs to types. *)
type subst = (var_id * ty) list

let empty_subst : subst = []

(** Look up a variable in the substitution (does NOT chase chains). *)
let subst_lookup id (s : subst) = List.assoc_opt id s

(** Apply substitution to a type, chasing TVar chains. *)
let rec apply (s : subst) (ty : ty) : ty =
  match ty with
  | TVar id ->
    (match List.assoc_opt id s with
     | None    -> TVar id
     | Some ty' -> apply s ty')   (* chase chains *)
  | TCon _           -> ty
  | TApp (head, arg) -> TApp (apply s head, apply s arg)
  | TFun (a, b)      -> TFun (apply s a, apply s b)

(** Compose substitutions: apply s1 to the values of s2, then union. *)
let compose (s1 : subst) (s2 : subst) : subst =
  let s2' = List.map (fun (id, ty) -> (id, apply s1 ty)) s2 in
  (* s1 takes priority for variables it defines *)
  s1 @ List.filter (fun (id, _) -> not (List.mem_assoc id s1)) s2'

(** Collect all free (unification) variable IDs in a type. *)
let rec free_vars (ty : ty) : int list =
  match ty with
  | TVar id when id > 0 -> [id]    (* only positive IDs are unification vars *)
  | TVar _              -> []
  | TCon _              -> []
  | TApp (h, a)         -> free_vars h @ free_vars a
  | TFun (a, b)         -> free_vars a @ free_vars b

let free_vars_scheme (sch : scheme) : int list =
  let all = free_vars sch.mono in
  List.filter (fun id -> not (List.mem id sch.vars)) all

(** Collect free vars in an environment. *)
let free_vars_env (env : (string * scheme) list) : int list =
  List.concat_map (fun (_, sch) -> free_vars_scheme sch) env

(* ── Unification ──────────────────────────────────────────────────────────── *)

exception TypeMismatch of ty * ty * string

(** Occurs check: does TVar id appear free in ty? Prevents infinite types. *)
let rec occurs (id : var_id) (ty : ty) : bool =
  match ty with
  | TVar id' when id' = id -> true
  | TVar _                 -> false
  | TCon _                 -> false
  | TApp (h, a)            -> occurs id h || occurs id a
  | TFun (a, b)            -> occurs id a || occurs id b

let rec head_constructor_name (ty : ty) : string option =
  match ty with
  | TCon name -> Some name
  | TApp (head, _) -> head_constructor_name head
  | TVar _ | TFun _ -> None

(** Robinson unification. Returns the extended substitution or raises TypeMismatch. *)
let rec unify (s : subst) (t1 : ty) (t2 : ty) : subst =
  let t1 = apply s t1 in
  let t2 = apply s t2 in
  if t1 = t2 then s
  else match t1, t2 with
  | TVar id, t | t, TVar id ->
    if id <= 0 then
      (* Rigid/named variable — can only unify with itself (already handled above) *)
      raise (TypeMismatch (t1, t2, "rigid type variable cannot be unified"))
    else if occurs id t then
      raise (TypeMismatch (t1, t2, "occurs check failed (infinite type)"))
    else
      compose [(id, t)] s

  (* Application: unify head then argument *)
  | TApp (h1, a1), TApp (h2, a2) ->
    let s' = unify s h1 h2 in
    unify s' a1 a2

  (* Function type *)
  | TFun (a1, b1), TFun (a2, b2) ->
    let s' = unify s a1 a2 in
    unify s' b1 b2

  (* Type constructor mismatch *)
  | TCon c1, TCon c2 when c1 <> c2 ->
    raise (TypeMismatch (t1, t2, "type mismatch"))

  | _ ->
    raise (TypeMismatch (t1, t2, "type mismatch"))

(* ── Instantiation & Generalization ─────────────────────────────────────── *)

(** Replace rigid variables in a type with fresh unification variables. *)
let instantiate (sch : scheme) : ty =
  if sch.vars = [] then sch.mono
  else begin
    (* Map each rigid var to a fresh unification var *)
    let mapping = List.map (fun rid -> (rid, fresh_id ())) sch.vars in
    let rec subst_rigid ty =
      match ty with
      | TVar id ->
        (match List.assoc_opt id mapping with
         | Some new_id -> TVar new_id
         | None        -> ty)
      | TCon _           -> ty
      | TApp (h, a)      -> TApp (subst_rigid h, subst_rigid a)
      | TFun (a, b)      -> TFun (subst_rigid a, subst_rigid b)
    in
    subst_rigid sch.mono
  end

(** Like [instantiate], but also returns the rigid→fresh id mapping used, so a
    caller can freshen SIDE data expressed in the same rigid vars (e.g. Eq/Ord
    constraints on a scheme) consistently with the instantiated [mono].  Used by
    the Eq/Ord constraint discharge (checker.ml). *)
let instantiate_with_map (sch : scheme) : ty * (int * int) list =
  let mapping = List.map (fun rid -> (rid, fresh_id ())) sch.vars in
  let rec subst_rigid ty =
    match ty with
    | TVar id ->
      (match List.assoc_opt id mapping with Some n -> TVar n | None -> ty)
    | TCon _           -> ty
    | TApp (h, a)      -> TApp (subst_rigid h, subst_rigid a)
    | TFun (a, b)      -> TFun (subst_rigid a, subst_rigid b)
  in
  (subst_rigid sch.mono, mapping)

(** Rewrite every [TVar id] whose id appears in [imap] to [TVar (imap id)].
    (Total, exhaustive — no wildcard fallthrough that could silently drop a
    constructor.) *)
let rec apply_int_map (imap : (int * int) list) (ty : ty) : ty =
  match ty with
  | TVar id -> (match List.assoc_opt id imap with Some n -> TVar n | None -> ty)
  | TCon _ -> ty
  | TApp (h, a) -> TApp (apply_int_map imap h, apply_int_map imap a)
  | TFun (a, b) -> TFun (apply_int_map imap a, apply_int_map imap b)

(** Generalize a type over variables not free in the environment.
    Quantified variables get negative IDs (rigid). *)
let generalize (env_free : int list) (subst : subst) (ty : ty) : scheme =
  let ty = apply subst ty in
  let fv = free_vars ty in
  (* Quantify over free vars not appearing in the environment *)
  let quantified = List.filter (fun id -> not (List.mem id env_free)) fv in
  let quantified = List.sort_uniq compare quantified in
  if quantified = [] then mono ty
  else begin
    (* Re-map to negative IDs *)
    let mapping = List.mapi (fun i id -> (id, -(i + 1))) quantified in
    let rigid_vars = List.map snd mapping in
    let rec to_rigid ty =
      match ty with
      | TVar id ->
        (match List.assoc_opt id mapping with
         | Some rid -> TVar rid
         | None     -> ty)
      | TCon _      -> ty
      | TApp (h, a) -> TApp (to_rigid h, to_rigid a)
      | TFun (a, b) -> TFun (to_rigid a, to_rigid b)
    in
    { vars = rigid_vars; mono = to_rigid ty }
  end

(* ── Type pretty-printer ──────────────────────────────────────────────────── *)

let rec pp_ty ?(parens = false) (ty : ty) : string =
  let s = match ty with
    | TVar id when id < 0  ->
      let letter = Char.chr (Char.code 'a' + ((-id - 1) mod 26)) in
      String.make 1 letter
    | TVar id ->
      let letter = Char.chr (Char.code 'a' + ((id - 1) mod 26)) in
      String.make 1 letter
    | TCon "Int"    -> "Int"
    | TCon "String" -> "String"
    | TCon "Bool"   -> "Bool"
    | TCon "Float"  -> "Float"
    | TCon "Unit"   -> "Unit"
    (* Dimensioned quantity: render the alias ("Speed") or unit form ("m/s^2")
       — the raw §Q[...] canonical name must never leak into a diagnostic. *)
    | TCon c when Units_catalog.is_quantity_name c ->
      (match Units_catalog.display_of_name c with Some s -> s | None -> c)
    (* Money rate: "MoneyPerDuration" / "Money/kg" — §MR[...] never leaks *)
    | TCon c when Units_catalog.is_money_rate_name c ->
      (match Units_catalog.money_rate_display_of_name c with Some s -> s | None -> c)
    | TCon c        -> c
    | TApp (TCon "List", a) -> Printf.sprintf "List %s" (pp_ty ~parens:true a)
    | TApp (TCon "Maybe", a) -> Printf.sprintf "Maybe %s" (pp_ty ~parens:true a)
    | TApp (TCon "Set", a) -> Printf.sprintf "Set %s" (pp_ty ~parens:true a)
    | TApp (TApp (TCon "Dict", k), v) ->
      Printf.sprintf "Dict %s %s" (pp_ty ~parens:true k) (pp_ty ~parens:true v)
    | TApp (TApp (TCon "Either", a), b) ->
      Printf.sprintf "Either %s %s" (pp_ty ~parens:true a) (pp_ty ~parens:true b)
    | TApp (h, a) -> Printf.sprintf "%s %s" (pp_ty h) (pp_ty ~parens:true a)
    | TFun (a, b) ->
      Printf.sprintf "%s -> %s" (pp_ty ~parens:true a) (pp_ty b)
  in
  (* Wrap in parens if requested and the type contains spaces *)
  if parens && (match ty with TFun _ | TApp _ -> true | _ -> false)
  then Printf.sprintf "(%s)" s
  else s

let pp_scheme (sch : scheme) : string =
  if sch.vars = [] then pp_ty sch.mono
  else
    let vars = String.concat " " (List.map (fun rid ->
      let letter = Char.chr (Char.code 'a' + ((-rid - 1) mod 26)) in
      String.make 1 letter) sch.vars) in
    Printf.sprintf "∀%s. %s" vars (pp_ty sch.mono)

(* ── Type errors ─────────────────────────────────────────────────────────── *)

(** A machine-applicable edit a diagnostic can carry (E1 import ergonomics,
    D9 structured fixes).  The type itself lives in the dependency-leaf
    {!Diag_fix} (so the parser can carry one too); re-exported here via a type
    equation so [type_error] producers keep writing [Replace_line { ... }].
    All line numbers are 0-based, matching diagnostic positions on the JSON
    wire; [Replace_range] columns are half-open ([end_col] exclusive). *)
type diagnostic_fix = Diag_fix.t =
  | Replace_line of { line : int; replacement : string }
  | Insert_line  of { line : int; text : string }
      (** insert [text] as a new line BEFORE [line] *)
  | Replace_span of { start_line : int; end_line : int; replacement : string }
      (** replace the inclusive line range; [replacement = ""] deletes it *)
  | Replace_range of { start_line : int; start_col : int;
                       end_line : int; end_col : int; replacement : string }
      (** column-precise replacement of [start_line:start_col ..
          end_line:end_col) *)
  | Multi of diagnostic_fix list
      (** several non-overlapping edits applied together *)

type type_error = {
  loc     : loc;
  message : string;
  fix     : diagnostic_fix option;
}

let fmt_error (e : type_error) : string =
  Printf.sprintf "%s:%d:%d: type error: %s"
    e.loc.file (e.loc.start.line + 1) (e.loc.start.col + 1) e.message

(* ── Stdlib type environment ──────────────────────────────────────────────── *)

(** Rigid type variables used in polymorphic stdlib signatures. *)
let _a = TVar (-1)
let _b = TVar (-2)
let _c = TVar (-3)
let _k = TVar (-4)
let _v = TVar (-5)
let _e = TVar (-6)

let _r1_a   = [-1]
let _r2_ab  = [-1; -2]
let _r2_kv  = [-4; -5]
let _r3_abc = [-1; -2; -3]

let stdlib_env : (string * scheme) list = [
  (* ── Arithmetic ─────────────────────────────────────────────────────── *)
  "+",  mono (t_fun [t_int; t_int] t_int);
  "-",  mono (t_fun [t_int; t_int] t_int);
  "*",  mono (t_fun [t_int; t_int] t_int);
  "/",  mono (t_fun [t_int; t_int] t_int);
  "%",  mono (t_fun [t_int; t_int] t_int);
  "quotient", mono (t_fun [t_int; t_int] t_int);
  "modulo",   mono (t_fun [t_int; t_int] t_int);

  (* ── Comparison (polymorphic) ────────────────────────────────────────── *)
  "==", { vars = _r1_a; mono = t_fun [_a; _a] t_bool };
  "!=", { vars = _r1_a; mono = t_fun [_a; _a] t_bool };
  "<",  { vars = _r1_a; mono = t_fun [_a; _a] t_bool };
  "<=", { vars = _r1_a; mono = t_fun [_a; _a] t_bool };
  ">",  { vars = _r1_a; mono = t_fun [_a; _a] t_bool };
  ">=", { vars = _r1_a; mono = t_fun [_a; _a] t_bool };

  (* ── Boolean ────────────────────────────────────────────────────────── *)
  "&&", mono (t_fun [t_bool; t_bool] t_bool);
  "||", mono (t_fun [t_bool; t_bool] t_bool);
  "!",  mono (t_fun [t_bool] t_bool);
  "not", mono (t_fun [t_bool] t_bool);
  "True",  mono t_bool;
  "False", mono t_bool;
  "Unit",  mono t_unit;

  (* ── Maybe ───────────────────────────────────────────────────────────── *)
  "Nothing",  { vars = _r1_a; mono = t_maybe _a };
  "Something", { vars = _r1_a; mono = t_fun [_a] (t_maybe _a) };

  (* ── Result ──────────────────────────────────────────────────────────── *)
  "Ok",  { vars = _r2_ab; mono = t_fun [_a] (t_result _a _b) };
  "Err", { vars = _r2_ab; mono = t_fun [_b] (t_result _a _b) };

  (* ── DeleteResult ─────────────────────────────────────────────────────── *)
  "NoRowDeleted", { vars = []; mono = t_delete_result };
  "RowsDeleted", { vars = []; mono = t_fun [t_int] t_delete_result };

  (* ── List ────────────────────────────────────────────────────────────── *)
  (* TYPE SOURCE OF TRUTH: the 26 PURE, PROOF-FREE List combinators below were
     LIFTED — their type signatures now live in `tesl/list.tesl` and are loaded
     from source by [Checker.load_imported_func_sigs].  They are intentionally
     ABSENT here.  (Runtime is unchanged: emission still maps `Tesl.List` to
     `tesl/list.rkt`.)  Lifted, no longer in stdlib_env:
       map filter foldl foldr length isEmpty head tail concat append reverse
       unique take drop zip range repeat any all find sum maximum minimum
       concatMap member contains
     DEFERRED (still hardcoded here — they carry the IsSorted proof or use the
     check/ForAll machinery, which is soundness-sensitive to lift): *)
  "List.filterCheck", { vars = _r1_a; mono = t_fun [t_fun [_a] _a; t_list _a] (t_list _a) };
  "List.allCheck",    { vars = _r1_a; mono = t_fun [t_fun [_a] _a; t_list _a] (t_maybe (t_list _a)) };
  "List.emptyForAll", { vars = _r1_a; mono = t_fun [t_fun [_a] _a] (t_list _a) };
  "List.sort",    { vars = _r1_a; mono = t_fun [t_list _a] (t_list _a) };
  "List.sortBy",  { vars = _r2_ab; mono = t_fun [t_fun [_a] _b; t_list _a] (t_list _a) };

  (* ── String ──────────────────────────────────────────────────────────── *)
  "String.length",     mono (t_fun [t_string] t_int);
  "String.concat",     mono (t_fun [t_string; t_string] t_string);
  "String.join",       mono (t_fun [t_list t_string; t_string] t_string);
  "String.split",      mono (t_fun [t_string; t_string] (t_list t_string));
  "String.trim",       mono (t_fun [t_string] t_string);
  "String.toLower",    mono (t_fun [t_string] t_string);
  "String.toUpper",    mono (t_fun [t_string] t_string);
  "String.startsWith", mono (t_fun [t_string; t_string] t_bool);
  "String.endsWith",   mono (t_fun [t_string; t_string] t_bool);
  "String.contains",   mono (t_fun [t_string; t_string] t_bool);
  "String.replace",    mono (t_fun [t_string; t_string; t_string] t_string);
  "String.toInt",      mono (t_fun [t_string] (t_maybe t_int));
  "String.fromInt",    mono (t_fun [t_int] t_string);
  (* The rest of Tesl.String (exported but previously unTYPED — see the note on
     the Float block below). *)
  "String.isEmpty",    mono (t_fun [t_string] t_bool);
  "String.trimLeft",   mono (t_fun [t_string] t_string);
  "String.trimRight",  mono (t_fun [t_string] t_string);
  "String.slice",      mono (t_fun [t_string; t_int; t_int] t_string);
  "String.repeat",     mono (t_fun [t_string; t_int] t_string);
  "String.reverse",    mono (t_fun [t_string] t_string);
  "String.toFloat",    mono (t_fun [t_string] (t_maybe t_float));
  "String.fromFloat",  mono (t_fun [t_float] t_string);
  "String.lines",      mono (t_fun [t_string] (t_list t_string));
  "String.words",      mono (t_fun [t_string] (t_list t_string));
  "String.padLeft",    mono (t_fun [t_string; t_int; t_string] t_string);
  "String.padRight",   mono (t_fun [t_string; t_int; t_string] t_string);
  "String.dropPrefix", mono (t_fun [t_string; t_string] t_string);
  "String.dropSuffix", mono (t_fun [t_string; t_string] t_string);
  "String.indexOf",    mono (t_fun [t_string; t_string] (t_maybe t_int));
  (* check function: passes a non-empty string through, minting IsNonEmpty *)
  "String.requireNonEmpty", mono (t_fun [t_string] t_string);

  (* ── Regex (LANGUAGE-SPEC.md §21.6) ──────────────────────────────────────
     The PATTERN is argument 1 of every function and must be a string LITERAL:
     the compiler parses it, rejects malformed ones and ones that can backtrack
     catastrophically, and guarantees each capture group participates in every
     successful match (Regex_lint, codes VREGEX001-4).  `Regex.captures` is
     `Maybe (List String)` rather than `Maybe (List (Maybe String))` precisely
     because that last rule makes the inner Maybe unreachable. *)
  "Regex.matches",  mono (t_fun [t_string; t_string] t_bool);
  "Regex.find",     mono (t_fun [t_string; t_string] (t_maybe t_string));
  "Regex.findAll",  mono (t_fun [t_string; t_string] (t_list t_string));
  "Regex.captures", mono (t_fun [t_string; t_string] (t_maybe (t_list t_string)));
  "Regex.replace",  mono (t_fun [t_string; t_string; t_string] t_string);
  "Regex.split",    mono (t_fun [t_string; t_string] (t_list t_string));

  (* ── Int32 (NT-07) ───────────────────────────────────────────────────── *)
  (* A JS-safe nominal boundary integer.  ONE RANGE RULE across the module:
     a result that cannot leave [-2^31, 2^31) is an `Int32`; a result that can
     is a `Maybe Int32` (`Nothing` = out of range, never a silent wrap); a
     result that is not an Int32 at all has its own type.  `Int32.toInt` is
     total widening, `Int32.fromIntClamped` is total saturating narrowing. *)
  "Int32.fromInt",        mono (t_fun [t_int] (t_maybe t_int32));
  "Int32.toInt",          mono (t_fun [t_int32] t_int);
  "Int32.fromIntClamped", mono (t_fun [t_int] t_int32);
  "Int32.parse",          mono (t_fun [t_string] (t_maybe t_int32));
  "Int32.fromFloat",      mono (t_fun [t_float] (t_maybe t_int32));
  "Int32.toFloat",        mono (t_fun [t_int32] t_float);
  "Int32.toString",       mono (t_fun [t_int32] t_string);
  "Int32.minValue",       mono t_int32;
  "Int32.maxValue",       mono t_int32;
  "Int32.min",            mono (t_fun [t_int32; t_int32] t_int32);
  "Int32.max",            mono (t_fun [t_int32; t_int32] t_int32);
  "Int32.clamp",          mono (t_fun [t_int32; t_int32; t_int32] t_int32);
  "Int32.modulo",         mono (t_fun [t_int32; t_int32] t_int32);
  "Int32.add",            mono (t_fun [t_int32; t_int32] (t_maybe t_int32));
  "Int32.subtract",       mono (t_fun [t_int32; t_int32] (t_maybe t_int32));
  "Int32.multiply",       mono (t_fun [t_int32; t_int32] (t_maybe t_int32));
  "Int32.divide",         mono (t_fun [t_int32; t_int32] (t_maybe t_int32));
  "Int32.negate",         mono (t_fun [t_int32] (t_maybe t_int32));
  "Int32.abs",            mono (t_fun [t_int32] (t_maybe t_int32));
  "Int32.pow",            mono (t_fun [t_int32; t_int32] (t_maybe t_int32));
  "Int32.isPositive",     mono (t_fun [t_int32] t_bool);
  "Int32.isNegative",     mono (t_fun [t_int32] t_bool);
  "Int32.isZero",         mono (t_fun [t_int32] t_bool);
  "Int32.isEven",         mono (t_fun [t_int32] t_bool);
  "Int32.isOdd",          mono (t_fun [t_int32] t_bool);
  "Int32.sign",           mono (t_fun [t_int32] t_int);
  "Int32.digits",         mono (t_fun [t_int32] t_int);
  "Int32.nonZero",        mono (t_fun [t_int32] t_int32);
  "Int32.nonNegative",    mono (t_fun [t_int32] t_int32);

  (* ── Int ─────────────────────────────────────────────────────────────── *)
  "Int.parse",    mono (t_fun [t_string] (t_maybe t_int));
  "Int.toString", mono (t_fun [t_int] t_string);
  "Int.abs",      mono (t_fun [t_int] t_int);
  "Int.min",      mono (t_fun [t_int; t_int] t_int);
  "Int.max",      mono (t_fun [t_int; t_int] t_int);
  "Int.nonNegative", mono (t_fun [t_int] t_int);  (* check-like but simpler *)
  "Int.nonZero",  mono (t_fun [t_int] t_int);     (* check: mints IsNonZero *)
  "Int.fromFloat", mono (t_fun [t_float] t_int);
  "Int.toFloat",  mono (t_fun [t_int] t_float);
  "Int.clamp",    mono (t_fun [t_int; t_int; t_int] t_int);
  "Int.isPositive", mono (t_fun [t_int] t_bool);
  "Int.isNegative", mono (t_fun [t_int] t_bool);
  "Int.isZero",   mono (t_fun [t_int] t_bool);
  "Int.isEven",   mono (t_fun [t_int] t_bool);
  "Int.isOdd",    mono (t_fun [t_int] t_bool);
  "Int.gcd",      mono (t_fun [t_int; t_int] t_int);
  "Int.lcm",      mono (t_fun [t_int; t_int] t_int);
  "Int.pow",      mono (t_fun [t_int; t_int] t_int);
  "Int.digits",   mono (t_fun [t_int] t_int);
  "Int.sign",     mono (t_fun [t_int] t_int);
  "Int.divide",   mono (t_fun [t_int; t_int] t_int);
  "Int.modulo",   mono (t_fun [t_int; t_int] t_int);

  (* ── Dict ────────────────────────────────────────────────────────────── *)
  "Dict.empty",        { vars = _r2_kv; mono = t_dict _k _v };
  "Dict.singleton",    { vars = _r2_kv; mono = t_fun [_k; _v] (t_dict _k _v) };
  "Dict.insert",       { vars = _r2_kv; mono = t_fun [_k; _v; t_dict _k _v] (t_dict _k _v) };
  "Dict.remove",       { vars = _r2_kv; mono = t_fun [_k; t_dict _k _v] (t_dict _k _v) };
  "Dict.delete",       { vars = _r2_kv; mono = t_fun [_k; t_dict _k _v] (t_dict _k _v) };
  "Dict.lookup",       { vars = _r2_kv; mono = t_fun [_k; t_dict _k _v] (t_maybe _v) };
  "Dict.requireKey",   { vars = _r2_kv; mono = t_fun [_k; t_dict _k _v] (t_dict _k _v) };
  "Dict.get",          { vars = _r2_kv; mono = t_fun [_k; t_dict _k _v] _v };
  "Dict.member",       { vars = _r2_kv; mono = t_fun [_k; t_dict _k _v] t_bool };
  "Dict.size",         { vars = _r2_kv; mono = t_fun [t_dict _k _v] t_int };
  "Dict.isEmpty",      { vars = _r2_kv; mono = t_fun [t_dict _k _v] t_bool };
  "Dict.keys",         { vars = _r2_kv; mono = t_fun [t_dict _k _v] (t_list _k) };
  "Dict.values",       { vars = _r2_kv; mono = t_fun [t_dict _k _v] (t_list _v) };
  "Tuple2",            { vars = _r2_ab; mono = t_fun [_a; _b] (t_tuple2 _a _b) };
  "Tuple2.first",      { vars = _r2_ab; mono = t_fun [t_tuple2 _a _b] _a };
  "Tuple2.second",     { vars = _r2_ab; mono = t_fun [t_tuple2 _a _b] _b };
  "Tuple3",            { vars = _r3_abc; mono = t_fun [_a; _b; _c] (t_tuple3 _a _b _c) };
  "Tuple3.first",      { vars = _r3_abc; mono = t_fun [t_tuple3 _a _b _c] _a };
  "Tuple3.second",     { vars = _r3_abc; mono = t_fun [t_tuple3 _a _b _c] _b };
  "Tuple3.third",      { vars = _r3_abc; mono = t_fun [t_tuple3 _a _b _c] _c };
  "Dict.fromList",     { vars = _r2_kv; mono = t_fun [t_list (t_tuple2 _k _v)] (t_dict _k _v) };
  "Dict.toList",       { vars = _r2_kv; mono = t_fun [t_dict _k _v] (t_list (t_tuple2 _k _v)) };
  "Dict.map",          { vars = _r3_abc; mono = t_fun [t_fun [_a] _b; t_dict _k _a] (t_dict _k _b) };
  "Dict.filter",       { vars = _r2_kv; mono = t_fun [t_fun [_v] t_bool; t_dict _k _v] (t_dict _k _v) };
  "Dict.filterCheckValues", { vars = _r2_kv; mono = t_fun [t_fun [_v] _v; t_dict _k _v] (t_dict _k _v) };
  "Dict.filterCheckKeys",   { vars = _r2_kv; mono = t_fun [t_fun [_k] _k; t_dict _k _v] (t_dict _k _v) };
  "Dict.union",        { vars = _r2_kv; mono = t_fun [t_dict _k _v; t_dict _k _v] (t_dict _k _v) };
  "Dict.intersection", { vars = _r2_kv; mono = t_fun [t_dict _k _v; t_dict _k _v] (t_dict _k _v) };
  "Dict.difference",   { vars = _r2_kv; mono = t_fun [t_dict _k _v; t_dict _k _v] (t_dict _k _v) };
  (* Exported but previously unTYPED (see the Float block note). *)
  "Dict.insertWith",   { vars = _r2_kv; mono = t_fun [t_fun [_v; _v] _v; _k; _v; t_dict _k _v] (t_dict _k _v) };
  "Dict.mapWithKey",   { vars = _r3_abc; mono = t_fun [t_fun [_k; _a] _b; t_dict _k _a] (t_dict _k _b) };
  "Dict.filterWithKey",{ vars = _r2_kv; mono = t_fun [t_fun [_k; _v] t_bool; t_dict _k _v] (t_dict _k _v) };
  "Dict.foldl",        { vars = _r3_abc; mono = t_fun [t_fun [_b; _v] _b; _b; t_dict _k _v] _b };
  "Dict.foldr",        { vars = _r3_abc; mono = t_fun [t_fun [_v; _b] _b; _b; t_dict _k _v] _b };
  "Dict.unionWith",    { vars = _r2_kv; mono = t_fun [t_fun [_v; _v] _v; t_dict _k _v; t_dict _k _v] (t_dict _k _v) };
  "Dict.update",       { vars = _r2_kv; mono = t_fun [_k; t_fun [t_maybe _v] (t_maybe _v); t_dict _k _v] (t_dict _k _v) };

  (* ── Set ─────────────────────────────────────────────────────────────── *)
  "Set.empty",         { vars = _r1_a; mono = t_set _a };
  "Set.singleton",     { vars = _r1_a; mono = t_fun [_a] (t_set _a) };
  "Set.member",        { vars = _r1_a; mono = t_fun [_a; t_set _a] t_bool };
  "Set.insert",        { vars = _r1_a; mono = t_fun [_a; t_set _a] (t_set _a) };
  "Set.remove",        { vars = _r1_a; mono = t_fun [_a; t_set _a] (t_set _a) };
  "Set.delete",        { vars = _r1_a; mono = t_fun [_a; t_set _a] (t_set _a) };
  "Set.size",          { vars = _r1_a; mono = t_fun [t_set _a] t_int };
  "Set.isEmpty",       { vars = _r1_a; mono = t_fun [t_set _a] t_bool };
  "Set.toList",        { vars = _r1_a; mono = t_fun [t_set _a] (t_list _a) };
  "Set.fromList",      { vars = _r1_a; mono = t_fun [t_list _a] (t_set _a) };
  "Set.union",         { vars = _r1_a; mono = t_fun [t_set _a; t_set _a] (t_set _a) };
  "Set.intersection",  { vars = _r1_a; mono = t_fun [t_set _a; t_set _a] (t_set _a) };
  "Set.difference",    { vars = _r1_a; mono = t_fun [t_set _a; t_set _a] (t_set _a) };
  "Set.isSubset",      { vars = _r1_a; mono = t_fun [t_set _a; t_set _a] t_bool };
  "Set.filter",        { vars = _r1_a; mono = t_fun [t_fun [_a] t_bool; t_set _a] (t_set _a) };
  "Set.filterCheck",   { vars = _r1_a; mono = t_fun [t_fun [_a] _a; t_set _a] (t_set _a) };
  "Set.any",           { vars = _r1_a; mono = t_fun [t_fun [_a] t_bool; t_set _a] t_bool };
  "Set.all",           { vars = _r1_a; mono = t_fun [t_fun [_a] t_bool; t_set _a] t_bool };
  "Set.allCheck",      { vars = _r1_a; mono = t_fun [t_fun [_a] _a; t_set _a] (t_maybe (t_set _a)) };
  (* Exported but previously unTYPED (see the Float block note). *)
  "Set.map",           { vars = _r2_ab; mono = t_fun [t_fun [_a] _b; t_set _a] (t_set _b) };
  "Set.foldl",         { vars = _r2_ab; mono = t_fun [t_fun [_b; _a] _b; _b; t_set _a] _b };
  "Set.partition",     { vars = _r1_a; mono = t_fun [t_fun [_a] t_bool; t_set _a] (t_list (t_set _a)) };

  (* ── Time ────────────────────────────────────────────────────────────── *)
  "nowMillis",     mono t_posix;
  "Time.posixToSeconds", mono (t_fun [t_posix] t_int);
  "Time.secondsToPosix", mono (t_fun [t_int] t_posix);
  (* Time.millisToSeconds removed 2026-07-06: it was importable + typed but had
     no runtime binding (unbound at load); redundant with posixToSeconds.
     See roadmap/completed/stdlib_surface_binding_drift.md. *)
  "formatTime",    mono (t_fun [t_posix; t_string; t_string] t_string);
  "durationMs",    mono (t_fun [t_posix] t_int);
  "addMs",         mono (t_fun [t_posix; t_int] t_posix);
  "diffMs",        mono (t_fun [t_posix; t_posix] t_int);
  "subtractMs",    mono (t_fun [t_posix; t_int] t_posix);
  (* Calendar truncation (GitHub #29): bucket-start instant for the wall clock
     in a TimeZone (a FIXED ADT — `Utc`, `FixedOffset minutes`, or one of the
     baked IANA zone constructors like `EuropeStockholm`, which are DST-correct
     per instant).  Pure functions — and the only PosixMillis operations the
     query DSL accepts as a `groupBy` bucket key. *)
  "Time.truncHour",  mono (t_fun [t_timezone; t_posix] t_posix);
  "Time.truncDay",   mono (t_fun [t_timezone; t_posix] t_posix);
  "Time.truncWeek",  mono (t_fun [t_timezone; t_posix] t_posix);
  "Time.truncMonth", mono (t_fun [t_timezone; t_posix] t_posix);
  "Time.truncYear",  mono (t_fun [t_timezone; t_posix] t_posix);
  (* the zone's UTC offset in minutes AT an instant (DST-correct) *)
  "Time.offsetAt",   mono (t_fun [t_timezone; t_posix] t_int);
  (* Duration bridge (First-Class Units): typed spans alongside the exact-Int
     ms forms.  addMs/diffMs stay canonical (exact integer arithmetic — the
     same exactness stance as Money's minor units); these give the units-typed
     surface: `Time.add ts (Duration.hours 2.0)`.  Conversion rounds
     half-even at the ms boundary. *)
  "Time.add",      mono (t_fun [t_posix; t_quantity Units_catalog.d_duration] t_posix);
  "Time.subtract", mono (t_fun [t_posix; t_quantity Units_catalog.d_duration] t_posix);
  "Time.diff",     mono (t_fun [t_posix; t_posix] (t_quantity Units_catalog.d_duration));
  "Duration.toMillis",   mono (t_fun [t_quantity Units_catalog.d_duration] t_int);
  "Duration.fromMillis", mono (t_fun [t_int] (t_quantity Units_catalog.d_duration));
  (* TimeZone constructors: Utc, FixedOffset, + one per baked IANA zone
     (appended below from the generated Tz_zones table — a typo'd zone is a
     compile error and completion lists every zone). *)
  "Utc",             mono t_timezone;
  "FixedOffset",     mono (t_fun [t_int] t_timezone);

  (* ── Either ─────────────────────────────────────────────────────────── *)
  (* The two ADT CONSTRUCTORS stay here (they are leaves).  The 10 pure Either
     COMBINATORS (isLeft/isRight/fromLeft/fromRight/map/mapLeft/andThen/
     withDefault/toMaybe/fromMaybe) were LIFTED to tesl/either.tesl — their
     types are now inferred from that source via load_imported_func_sigs, and
     their bodies compile to tesl/either-derived.rkt. *)
  "Left",             { vars = _r2_ab; mono = t_fun [_a] (t_either _a _b) };
  "Right",            { vars = _r2_ab; mono = t_fun [_b] (t_either _a _b) };


  (* ── Float arithmetic functions ─────────────────────────────────────── *)
  "Float.add",  mono (t_fun [t_float; t_float] t_float);
  "Float.sub",  mono (t_fun [t_float; t_float] t_float);
  "Float.mul",  mono (t_fun [t_float; t_float] t_float);
  (* Float.div denominator must carry FloatNonZero proof (from Float.requireNonZero).
     At the type level it is Float → Float → Float; proof enforcement is at the
     validation / proof-checker level via the parameter proof annotation. *)
  "Float.div",  mono (t_fun [t_float; t_float] t_float);
  "Float.requireNonZero", mono (t_fun [t_float] t_float);
  "Float.round", mono (t_fun [t_float] t_int);
  "Float.floor", mono (t_fun [t_float] t_int);
  "Float.ceil",  mono (t_fun [t_float] t_int);
  (* The rest of Tesl.Float.  These were EXPORTED but absent here, which does not
     fail — an export with no scheme type-checks as ANYTHING, so
     `Float.abs "hello" : String` passed `tesl check` and the nominal boundary
     types could be laundered through any such name.  Pinned by
     test_stdlib_signature_coverage.ml. *)
  "Float.parse",    mono (t_fun [t_string] (t_maybe t_float));
  "Float.toString", mono (t_fun [t_float] t_string);
  "Float.toInt",    mono (t_fun [t_float] t_int);
  "Float.abs",      mono (t_fun [t_float] t_float);
  "Float.min",      mono (t_fun [t_float; t_float] t_float);
  "Float.max",      mono (t_fun [t_float; t_float] t_float);
  "Float.clamp",    mono (t_fun [t_float; t_float; t_float] t_float);
  "Float.sqrt",     mono (t_fun [t_float] t_float);
  "Float.pow",      mono (t_fun [t_float; t_float] t_float);
  "Float.log",      mono (t_fun [t_float] t_float);
  "Float.exp",      mono (t_fun [t_float] t_float);
  "Float.sin",      mono (t_fun [t_float] t_float);
  "Float.cos",      mono (t_fun [t_float] t_float);
  "Float.tan",      mono (t_fun [t_float] t_float);
  "Float.isNaN",      mono (t_fun [t_float] t_bool);
  "Float.isInfinite", mono (t_fun [t_float] t_bool);
  "Float.isPositive", mono (t_fun [t_float] t_bool);
  "Float.isNegative", mono (t_fun [t_float] t_bool);
  "Float.isZero",     mono (t_fun [t_float] t_bool);
  "Float.sign",       mono (t_fun [t_float] t_float);
  "Float.infinity",   mono t_float;
  "Float.nan",        mono t_float;

  (* ── Random ──────────────────────────────────────────────────────────── *)
  "randomInt",     mono (t_fun [t_int; t_int] t_int);
  "randomFloat",   mono t_float;

  (* ── UUID ────────────────────────────────────────────────────────────── *)
  (* Nullary EFFECTS (a fresh UUID each call), typed as their result like the
     other nullary effects `nowMillis`/`randomFloat` — NOT `Unit -> String`, which
     made `UUID.v7()` fail to unify (CAP-UUID). Invoked as `UUID.v7()`; the emitter
     lowers the `()` to a nullary Racket call. *)
  "UUID.v4",       mono t_string;
  "UUID.v7",       mono t_string;
  "UUID.validate", mono (t_fun [t_string] t_string);
  "IsUuid",        mono t_string;
  "uuidV4Codec",   mono t_string;
  "uuidV7Codec",   mono t_string;

  (* ── ID generation ───────────────────────────────────────────────────── *)
  "generateId",          mono t_string;
  "generatePrefixedId",  mono (t_fun [t_string] t_string);
  (* newId removed 2026-07-06: importable + typed but no runtime binding, and
     redundant with the Tesl.UUID module (UUID.v4/v7).
     See roadmap/completed/stdlib_surface_binding_drift.md. *)

  (* ── Env ─────────────────────────────────────────────────────────────── *)
  "env",       mono (t_fun [t_string] (t_maybe t_string));
  "envInt",    mono (t_fun [t_string; t_int] t_int);
  "envString", mono (t_fun [t_string; t_string] t_string);
  (* requireEnv: read an env var as a String, failing at startup if unset.  The
     String-returning counterpart to `env` (which returns Maybe), for places that
     need a value directly, e.g. `anthropic (requireEnv "ANTHROPIC_API_KEY") model`. *)
  "requireEnv", mono (t_fun [t_string] t_string);
  (* requireSecret: read an env var straight into a `Secret`, with no String
     ever existing in Tesl code.  This is the "read from the environment" row of
     the secret-accepting-sinks table: `Secret (requireEnv "…")` would work but
     puts the plaintext in a String first, which is exactly what the feature
     exists to prevent.
     v1 is MONOMORPHIC — it returns the stdlib `Secret`, not the user's own
     `secret Password = String`.  Result-polymorphism would need a fresh result
     var + an [escaping_result_var_whitelist] entry + a bespoke
     decide-by-resolution validator (the `decodeAs` pattern), which is a lot of
     fail-closed machinery for an env read; a user secret is minted from a
     request body (Phase 4's decoder path), which is where user secrets actually
     come from. *)
  "requireSecret", mono (t_fun [t_string] t_secret);

  (* ── HTTP ────────────────────────────────────────────────────────────── *)
  "statusOk",          mono t_int;
  "statusClientError", mono t_int;
  "statusServerError", mono t_int;

  (* ── HttpClient ─────────────────────────────────────────────────────── *)
  "HttpResponse",         mono t_http_response;
  "HttpClient.get",       mono (t_fun [t_string; t_list (t_tuple2 t_string t_string)] t_http_response);
  "HttpClient.post",      mono (t_fun [t_string; t_list (t_tuple2 t_string t_string); t_string] t_http_response);
  "HttpClient.put",       mono (t_fun [t_string; t_list (t_tuple2 t_string t_string); t_string] t_http_response);
  "HttpClient.delete",    mono (t_fun [t_string; t_list (t_tuple2 t_string t_string)] t_http_response);
  (* Outbound header sinks — the "an outbound HTTP header" row of the
     secret-accepting-sinks table.  Both return a `Tuple2 String String`, which
     is what the four verbs' header parameter already accepts, so a secret can
     be put on the wire without a `String` ever existing in Tesl code and
     without changing four signatures the whole corpus depends on.
     At RUNTIME the value half is NOT a string: it is an opaque
     `secret-header-value` (dsl/types.rkt) that prints as `[redacted]` and is
     rejected by every String primitive, so projecting it back out
     (`Tuple2.second h`) cannot leak.  It becomes plaintext at exactly one
     place — `http-header-pair` in tesl/http-client.rkt, inside trusted code, on
     its way onto the socket. *)
  "HttpClient.bearer",    mono (t_fun [t_secret] (t_tuple2 t_string t_string));
  "HttpClient.secretHeader", mono (t_fun [t_string; t_secret] (t_tuple2 t_string t_string));

  (* ── Agent (AI Tier-0) ──────────────────────────────────────────────── *)
  (* mockProvider: list of scripted reply strings → an opaque LlmProvider. *)
  "mockProvider", mono (t_fun [t_list t_string] t_llm_provider);
  (* ask: one-shot inference — Agent → prompt String → assistant text String.
     Requires the aiProvider capability (enforced in validation_capabilities). *)
  "ask",          mono (t_fun [t_agent; t_string] t_string);

  (* ── Agent (AI Tier-0 Wave 2a — agentic core) ───────────────────────────
     Provider constructors (all build an opaque LlmProvider). Positional args
     only (Tesl forbids bare record literals). *)
  "mockToolProvider", mono (t_fun [t_list t_tool_step] t_llm_provider);
  "toolUseStep",  mono (t_fun [t_string; t_string; t_string] t_tool_step);
  "textStep",     mono (t_fun [t_string] t_tool_step);
  "anthropic",    mono (t_fun [t_string; t_string] t_llm_provider);
  "openai",       mono (t_fun [t_string; t_string] t_llm_provider);
  "mistral",      mono (t_fun [t_string; t_string] t_llm_provider);
  "local",        mono (t_fun [t_string; t_string] t_llm_provider);

  (* tool: name, description, JSON-schema string, validator (args-JSON String → a),
     dispatch (a → result String) → an opaque Tool. The validated-argument type
     `a` is hidden inside the Tool value; tool is polymorphic in it. A malformed
     arg makes the validator raise / return a check-fail and the loop returns it
     to the model as a tool_result is_error (not an exception). *)
  "tool",         { vars = _r1_a;
                    mono = t_fun [t_string; t_string; t_string;
                                  t_fun [t_string] _a; t_fun [_a] t_string] t_tool };
  (* asTool: wrap a typed Tesl function as a Tool, deriving the JSON schema from its
     parameter types and decoding/dispatching the model's args under the hood.  Used
     in the Agent { tools: [...] } field (block and expression alike).  The argument
     is a function reference; its concrete type is irrelevant to the result, so it is
     polymorphic in the argument. *)
  "asTool",       { vars = _r1_a; mono = t_fun [_a] t_tool };

  (* askReply / askWith: full tool-calling loop returning an AgentReply.
     askWith takes a BYOK LlmProvider override as its last argument. *)
  "askReply",     mono (t_fun [t_agent; t_string] t_agent_reply);
  "askWith",      mono (t_fun [t_agent; t_string; t_llm_provider] t_agent_reply);
  (* AgentReply accessors. *)
  "replyText",      mono (t_fun [t_agent_reply] t_string);
  "replyTokens",    mono (t_fun [t_agent_reply] t_int);
  "replyToolCalls", mono (t_fun [t_agent_reply] t_int);

  (* decodeAs: typeName, JSON String → proof-carrying value of the named type
     (same codec registry path as an HTTP body decode). Polymorphic result. *)
  "decodeAs",     { vars = _r1_a; mono = t_fun [t_string; t_string] _a };
  (* askFor: ask the model for a typed value. decoder is the developer's
     String → a function; maxRetries bounds the decode-failure retry loop. *)
  "askFor",       { vars = _r1_a;
                    mono = t_fun [t_agent; t_string; t_fun [t_string] _a; t_int] _a };

  (* ── Agent (AI Tier-0 Wave 2b — conversation + worker-backed run) ──────────
     Multi-turn conversation (function-first; the developer owns persistence via
     conversationJson / conversationFrom into their OWN entity). *)
  "newConversation",  mono (t_fun [t_agent] t_conversation);
  "conversationFrom", mono (t_fun [t_agent; t_string] t_conversation);
  "converse",         mono (t_fun [t_conversation; t_string] t_conversation_turn);
  "converseStreaming", mono (t_fun [t_conversation; t_string; t_fun [t_string] t_unit] t_conversation_turn);
  "turnReply",        mono (t_fun [t_conversation_turn] t_agent_reply);
  "turnConversation", mono (t_fun [t_conversation_turn] t_conversation);
  "conversationJson",   mono (t_fun [t_conversation] t_string);
  "conversationLength", mono (t_fun [t_conversation] t_int);
  (* agentRun: run the loop to completion on a worker, publishing each step via
     the developer's (String → Unit) callback (which closes over `publish`). *)
  "agentRun",         mono (t_fun [t_agent; t_string; t_fun [t_string] t_unit] t_agent_reply);

  (* ── GDP / proof utilities ───────────────────────────────────────────── *)
  "forgetFact",   { vars = _r1_a; mono = t_fun [_a] _a };
  "detachFact",   { vars = _r1_a; mono = t_fun [_a] t_fact };
  "attachFact",   { vars = _r1_a; mono = t_fun [_a; t_fact] _a };
  (* Proof conjunction operations *)
  "andLeft",      mono (t_fun [t_fact] t_fact);
  "andRight",     mono (t_fun [t_fact] t_fact);
  "introAnd",     mono (t_fun [t_fact; t_fact] t_fact);

  (* ── JWT ─────────────────────────────────────────────────────────────────── *)
  (* JwtToken is a nominal newtype wrapping String — the non-secret WIRE value.
     There is no JWT key type: the signing key is Tesl.Crypto's `Secret` (the one
     key-material type in the language).  A JWT-ONLY key newtype existed until
     2026-07-30 and was DELETED, not aliased — with two types `Env.requireSecret`
     (which returns `Secret`) could not feed `JWT.sign`/`JWT.verify`, so every
     shipped example rewrapped the signing key through a plain `String`, defeating
     the redaction the secret types exist to guarantee. *)
  "JwtToken",  mono (t_fun [t_string] t_jwt_token);
  (* Claims are a string-keyed JSON object; the runtime (jwt.rkt
     jwt-claims->string-keyed) always returns a string-keyed hash, and every
     consumer reads it via Dict.lookup. Pin to a CONCRETE Dict String String so
     a free result var can no longer be silently typed as Int/String/etc.
     (security hole). Round-trips with sign. t_dict = Dict String String.

     There is deliberately NO expiry parameter: `JWT.sign` stamps `exp` itself,
     one hour ahead (epoch seconds, RFC 7519 — LANGUAGE-SPEC.md §21.2), and a
     caller-supplied `exp` in the claims is a runtime error.  Tesl.Crypto's
     design rule applies — no mechanism reaches the application author, because
     every knob is a place where a non-expert makes a wrong call and gets a
     plausible-looking result; a caller who can pass an expiry can pass ten
     years.  Because it reads the clock it charges `time` as well as `jwt`. *)
  "JWT.sign",   mono (t_fun [t_dict t_string t_string; t_secret] t_jwt_token);
  "JWT.verify", mono (t_fun [t_jwt_token; t_secret] (t_dict t_string t_string));
  (* JWT.renew — sliding sessions.  Check-shaped: it verifies, then re-issues the
     token with a fresh `exp` and the ORIGINAL `iat` preserved, so an active user
     is not logged out mid-task while an idle one still expires an hour after
     their last request.  It exists as a function because re-signing by hand is a
     trap: the verified claims carry `exp` and `iat`, `JWT.sign` rejects both, and
     an author who rebuilds the dict to strip them silently drops any claim they
     forget (a `role`, a tenant id).  It refuses once `now - iat` passes the fixed
     absolute maximum — renewal is presented WITH the token, so without that cap a
     captured token would be renewable forever, and there is no revocation to fall
     back on.  Charges `time` as well as `jwt`, like JWT.sign: it signs. *)
  "JWT.renew",  mono (t_fun [t_jwt_token; t_secret] t_jwt_token);
  "JWT.decode", mono (t_fun [t_jwt_token] (t_dict t_string t_string));

  (* ── Tesl.Sso (Phase 3 tables-only foundation) ───────────────────────────
     `Sso.defaults provider clientId clientSecret` builds a blessed provider
     connection.  The provider is the baked `SsoProvider` ADT (`Github`/`Google`)
     — a closed set of nullary constructors that lower inline to the runtime
     provider string, so a typo is a compile error and completion lists every
     provider (the `Utc`/`Currency` baked-ADT pattern).  `Sso.oidc issuer …` is
     the generic OpenID Connect connection by ISSUER URL (self-hosted
     Keycloak/dex, Okta, Auth0, single-tenant Entra).  `Sso.keyText` renders the
     opaque identity key for a DB column.  The runtime is tesl/sso.rkt, wrapping
     dsl/sso.rkt. *)
  "Sso.defaults", mono (t_fun [t_sso_provider; t_string; t_secret] t_sso_connection);
  "Sso.oidc",     mono (t_fun [t_string; t_string; t_secret] t_sso_connection);
  (* Domain-restriction builders (Risk 17/53): set the runtime-enforced allow-
     lists on a connection.  Checked at the callback BEFORE onIdentity, and
     satisfiable only by a VerifiedEmail — a returned record-update. *)
  "Sso.allowedEmailDomains",  mono (t_fun [t_sso_connection; t_list t_string] t_sso_connection);
  "Sso.allowedHostedDomains", mono (t_fun [t_sso_connection; t_list t_string] t_sso_connection);
  "Sso.allowedTenants",       mono (t_fun [t_sso_connection; t_list t_string] t_sso_connection);
  (* Item A (#50.2): a check-shaped verification of a proxy-binding header
     value against a configured Secret; mints `ProxyBound` (proof-layer). *)
  "Proxy.verifyBinding", mono (t_fun [t_secret; t_string] t_string);
  (* SsoProvider constructors (fixed set): nullary values of type SsoProvider,
     lowered inline in emit_racket to the runtime provider string. *)
  "Github", mono t_sso_provider;
  "Google", mono t_sso_provider;
  "Sso.keyText",  mono (t_fun [t_sso_subject_key] t_string);
  (* the SSO identity handed to `onIdentity`; opaque, read via Sso.subject *)
  "Sso.subject",  mono (t_fun [t_sso_identity] t_string);
  (* Typed-identity accessors (Risk 2/3/18/32, OQ12): the VERIFIED email only
     (as Maybe — an app cannot obtain an unverified address, so it cannot trust
     one), the tenant, and any single claim by name.  The full 3-way EmailClaim
     ADT + `claims: Dict String Json` are a deferred richer surface. *)
  "Sso.email",   mono (t_fun [t_sso_identity] (t_maybe t_string));
  "Sso.tenant",  mono (t_fun [t_sso_identity] (t_maybe t_string));
  "Sso.claim",   mono (t_fun [t_sso_identity; t_string] (t_maybe t_string));

  (* ── Http: the session cookie ──────────────────────────────────────────────
     The transport for the credential above.  Three ordinary imported functions,
     no new syntax and nothing ambient: the NAMES arrive via `import Tesl.Http
     exposing [...]` and the RIGHT to write arrives via `cookieCap` in a
     `requires` list.  The handler's return type is untouched, so every generated
     TS/Elm client and every api-test is unchanged by setting a cookie.

     `setSessionCookie` demands a `JwtToken`, not a `String`: the type system,
     not a lesson, is what guarantees a session cookie always carries a signed
     value.  There is no way to set an unsigned cookie and no second
     cookie-writing function — name, attributes and expiry are all fixed in
     tesl/http.rkt.  General cookie handling (UI state, preferences, tracking) is
     a permanent non-goal.

     `clearSessionCookie` is typed as its RESULT, not as `t_fun []` — the house
     shape for a nullary stdlib call (`nowMillis`, `UUID.v4`), written
     `Http.clearSessionCookie()` in Tesl and lowered via
     Emit_racket.stdlib_zero_arg_names.

     `sessionToken` is the reader, pure and ungated: request data is not an
     effect.  It exists so the fixed cookie name is written down once, in the
     runtime, instead of appearing at call sites as
     `Dict.lookup "__Host-session" request.cookies`, where a typo is a permanent
     401. *)
  "Http.setSessionCookie",   mono (t_fun [t_jwt_token] t_unit);
  "Http.clearSessionCookie", mono t_unit;
  "Http.sessionToken",       mono (t_fun [t_http_request] (t_maybe t_jwt_token));
  (* Tesl.ApiTest's reader for the same cookie, so a round-trip test never parses
     a `Set-Cookie` line by hand.  It lives beside the cookie functions rather
     than with the other api-test helpers because it is part of this surface; the
     `Maybe` is what makes "no cookie was set" a case the test must handle. *)
  "responseCookie",          mono (t_fun [t_http_response] (t_maybe t_string));

  (* ── Crypto ──────────────────────────────────────────────────────────────
     Eight jobs, three types, three facts.  Every primitive is libsodium.

     `Secret` HAS a constructor, deliberately, and the other two do not:
       * `Secret "…"` only asserts "this string is key material", which is more
         protective than leaving it a bare String, and something has to be able
         to mint one from a config read.  A hardcoded key is caught by the
         SEC003 lint (a string LITERAL reaching a secret-accepting parameter),
         which is the precise check — not by making the type unusable.
       * `PasswordHash "…"` would bless a plaintext as a hash. That is a
         catastrophic type lie, so there is no row for it.
       * `Signature "…"` would invite hand-rolled tag comparison. Use
         `Crypto.signatureFromHex`, which parses rather than asserts.

     No new capability: a capability marks an EFFECT, and sensitivity is carried
     by the types and the facts.  Only the two functions that draw randomness
     are gated, and they reuse the existing `random`. *)
  "Secret", mono (t_fun [t_string] t_secret);

  "Crypto.hashPassword",  mono (t_fun [t_string] t_password_hash);
  (* Takes `Maybe` so a missing user row and a wrong password cost the same:
     with Nothing it hashes against a dummy.  Check-shaped — the proof half
     lives in Validation_common.stdlib_func_infos. *)
  "Crypto.checkPassword", mono (t_fun [t_maybe t_password_hash; t_string]
                                  (t_maybe t_password_hash));
  "Crypto.needsRehash",   mono (t_fun [t_password_hash] t_bool);

  "Crypto.signWith",      mono (t_fun [t_secret; t_string] t_signature);
  "Crypto.checkSignature", mono (t_fun [t_secret; t_signature; t_string] t_string);
  (* Transport, in and out.  A MAC tag is public: you PUT it in a header and you
     READ one out of a header, so both directions are needed and neither is an
     unwrap of a secret. *)
  "Crypto.signatureHex",     mono (t_fun [t_signature] t_string);
  "Crypto.signatureFromHex", mono (t_fun [t_string] t_signature);
  "Crypto.signatureBase64",     mono (t_fun [t_signature] t_string);
  "Crypto.signatureFromBase64", mono (t_fun [t_string] t_signature);

  "Crypto.fingerprint",    mono (t_fun [t_string] t_string);
  "Crypto.keyFingerprint", mono (t_fun [t_secret] t_string);
  (* A VALUE type, not a function type, like nowMillis / UUID.v4 / randomFloat:
     `Crypto.randomToken()` is a fresh value per call, and Emit_racket's
     stdlib_zero_arg_names is what lowers the `()` to a nullary application. *)
  "Crypto.randomToken",    mono t_string;

  (* Expert aliases.  Never required to write correct code; they exist so that
     someone who already knows what they want can say it, and so a search for
     "hmac" or "sha256" lands somewhere useful. *)
  "Crypto.hmacSha256", mono (t_fun [t_secret; t_string] t_signature);
  "Crypto.sha256",     mono (t_fun [t_string] t_string);
  "Crypto.sha512",     mono (t_fun [t_string] t_string);

  (* ── Money (First-Class Units, phase 1) ──────────────────────────────────
     Money = exact-integer MINOR units (cents/öre/yen) + an intrinsic Currency
     qualifier — money NEVER touches Float.  Currency is a fixed baked ADT
     (one ctor per active ISO 4217 code, appended below from Currencies) —
     a typo'd currency is an unknown-constructor compile error.  Same-currency
     safety is proof-layer (SameCurrency, minted by Money.requireSameCurrency;
     Money.add/subtract/compare require it — currency is a runtime qualifier,
     deliberately NOT in the static type, like a PosixMillis's zone).
     Cross-currency conversion is EXPLICIT: a runtime-supplied ExchangeRate
     (never ambient, never a default rate) through Money.convert.  Pure module:
     no capability. *)
  (* NOT `Money.of` — `of` is the case-expression keyword and cannot follow a
     dot in Tesl source *)
  "Money.fromMinorUnits", mono (t_fun [t_currency; t_int] t_money);
  "Money.minorUnits",  mono (t_fun [t_money] t_int);
  "Money.currency",    mono (t_fun [t_money] t_currency);
  "Money.scale",       mono (t_fun [t_money; t_int] t_money);
  (* fractional scaling (interest/VAT/discount): decimal-faithful exact factor,
     half-even rounding back to minor units — named (not `*`) because it rounds *)
  "Money.scaleBy",     mono (t_fun [t_money; t_float] t_money);
  "Money.negate",      mono (t_fun [t_money] t_money);
  "Money.abs",         mono (t_fun [t_money] t_money);
  "Money.isZero",      mono (t_fun [t_money] t_bool);
  "Money.isNegative",  mono (t_fun [t_money] t_bool);
  "Money.display",     mono (t_fun [t_money] t_string);
  (* Same-currency ops: statically Money -> Money -> Money; the SameCurrency
     proof obligation on the second argument is enforced by the proof layer. *)
  "Money.add",         mono (t_fun [t_money; t_money] t_money);
  "Money.subtract",    mono (t_fun [t_money; t_money] t_money);
  "Money.compare",     mono (t_fun [t_money; t_money] t_int);
  (* check functions (mint SameCurrency / NonNegativeMoney / RateFor) *)
  "Money.requireSameCurrency", mono (t_fun [t_money; t_money] t_money);
  "Money.requireNonNegative",  mono (t_fun [t_money] t_money);
  "Money.requireRateFor",      mono (t_fun [t_exchange_rate; t_money] t_money);
  "Currency.code",        mono (t_fun [t_currency] t_string);
  "Currency.minorDigits", mono (t_fun [t_currency] t_int);
  "Currency.fromCode",    mono (t_fun [t_string] (t_maybe t_currency));
  (* Exchange: rate is runtime data with provenance (asOf), never baked. *)
  "ExchangeRate.make", mono (t_fun [t_currency; t_currency; t_float; t_posix] t_exchange_rate);
  "ExchangeRate.fromCurrency", mono (t_fun [t_exchange_rate] t_currency);
  "ExchangeRate.toCurrency",   mono (t_fun [t_exchange_rate] t_currency);
  "ExchangeRate.rate",         mono (t_fun [t_exchange_rate] t_float);
  "ExchangeRate.asOf",         mono (t_fun [t_exchange_rate] t_posix);
  "Money.convert", mono (t_fun [t_exchange_rate; t_money] (t_result t_money t_string));
  "Money.convertChecked", mono (t_fun [t_exchange_rate; t_money] t_money);
  (* Money rates (money PER quantity — consultant cost, price per kg).
     Construction: a fixed-denominator constructor below, or `money / quantity`
     directly.  Consumption: `rate * quantity : Money` (dimensions cancel,
     currency rides through, ONE half-even rounding).  MoneyRate.currency /
     MoneyRate.display are dimension-polymorphic and typed at the application
     site by the checker, like the Units ops. *)
  "MoneyRate.perHour",        mono (t_fun [t_money] (t_money_rate Units_catalog.d_duration));
  "MoneyRate.perDay",         mono (t_fun [t_money] (t_money_rate Units_catalog.d_duration));
  "MoneyRate.perKilogram",    mono (t_fun [t_money] (t_money_rate Units_catalog.d_mass));
  "MoneyRate.perLiter",       mono (t_fun [t_money] (t_money_rate Units_catalog.d_volume));
  "MoneyRate.perSquareMeter", mono (t_fun [t_money] (t_money_rate Units_catalog.d_area));
  (* moneyCodec is deliberately NOT env-typed — codec names are validated by
     builtin_codec_type and lowered inline, exactly like posixMillisCodec *)

  (* ── Queue / Tesl infrastructure ─────────────────────────────────────── *)
  (* requeue: takes a DeadJob (the concrete dead-letter entry) and returns Bool
     (#t/#f from the runtime).  The result type is CONCRETE — an earlier scheme
     `∀a b. a -> b` had a free result var `_b` that HM would instantiate to any
     type at the use site, i.e. an `unsafeCoerce` (review 2.3).  Fixed. *)
  "requeue",        mono (t_fun [TCon "DeadJob"] t_bool);
  (* deadJobs: takes a queue (nominal per-declaration, hence polymorphic in `_a`)
     and returns a concrete `List DeadJob`.  `_a` appears in an argument position,
     so there is no escaping result var (review 2.3). *)
  "deadJobs",       { vars = _r1_a; mono = t_fun [_a] (t_list (TCon "DeadJob")) };
  "pendingJobCount",{ vars = _r1_a; mono = t_fun [_a] t_int };
  "drainQueue",     { vars = _r1_a; mono = t_fun [_a] t_unit };
  "processNextJob", { vars = _r1_a; mono = t_fun [_a] _a };
  "processNextDeadJob", { vars = _r1_a; mono = t_fun [_a] _a };

  (* ── Outbound-HTTP test double (Tesl.ApiTest) ─────────────────────────────
     Declared as statements in a test body; the runtime scope is created per
     test block by call-with-fresh-memory-db (dsl/test-support.rkt), so nothing
     leaks between tests and none of it exists in a production build. *)
  "stubHttp",        mono (t_fun [t_string; t_string; t_int; t_string] t_unit);
  "stubHttpFailure", mono (t_fun [t_string; t_string; t_string] t_unit);
  "stubHttpTimeout", mono (t_fun [t_string; t_string] t_unit);
  "httpCalled",      mono (t_fun [t_string; t_string] t_bool);
  "httpCallCount",   mono (t_fun [t_string; t_string] t_int);
  "httpLastBody",    mono (t_fun [t_string; t_string] t_string);

  (* ── Telemetry ───────────────────────────────────────────────────────── *)
  "initTelemetry", mono t_unit;
  "telemetry",     mono (t_fun [t_string] t_unit);
  (* Metrics signal (roadmap opentelemetry_metrics): plain stdlib functions,
     ambient like `telemetry`.  Attrs are [Tuple2 "key" value] pairs, mirroring
     the Dict.fromList surface. *)
  "counter",   mono (t_fun [t_string; t_int;   t_list (t_tuple2 t_string t_string)] t_unit);
  "histogram", mono (t_fun [t_string; t_float; t_list (t_tuple2 t_string t_string)] t_unit);
  "gauge",     mono (t_fun [t_string; t_float; t_list (t_tuple2 t_string t_string)] t_unit);

  (* ── EmailBody ADT ───────────────────────────────────────────────────── *)
  "TextBody", mono (t_fun [t_string] (TCon "EmailBody"));
  "HtmlBody", mono (t_fun [t_string] (TCon "EmailBody"));
  "RichBody", mono (t_fun [t_string; t_string] (TCon "EmailBody"));

  (* ── Misc ────────────────────────────────────────────────────────────── *)
  "check",   { vars = _r1_a; mono = t_fun [t_fun [_a] _a; _a] _a };
  "identity",{ vars = _r1_a; mono = t_fun [_a] _a };
  "const",   { vars = _r2_ab; mono = t_fun [_a; _b] _a };
]
(* the 312 baked IANA zone constructors, each : TimeZone *)
@ List.map (fun c -> (c, mono t_timezone)) Tz_zones.ctor_names
(* the baked ISO 4217 Currency constructors (Usd, Eur, …), each : Currency *)
@ List.map (fun c -> (c, mono t_currency)) Currencies.ctor_names
(* per-currency Money constructors (Money.usd, …) : Int -> Money (minor units) *)
@ List.map (fun n -> (n, mono (t_fun [t_int] t_money))) Currencies.money_ctor_names
(* unit constructors (Length.meters, …) : Float -> <quantity>; factors live
   only in tesl/units.rkt — the type is factor-independent *)
@ List.map (fun (m, f, d) -> (m ^ "." ^ f, mono (t_fun [t_float] (t_quantity d))))
    Units_catalog.constructors
(* unit accessors (Length.inFeet, …) : <quantity> -> Float *)
@ List.map (fun (m, f, d) -> (m ^ "." ^ f, mono (t_fun [t_quantity d] t_float)))
    Units_catalog.accessors
(* polymorphic dimension ops (Units.mul/div/…) are NOT typed here: they are
   dimension-computed at each application site in the checker (decide-by-
   resolution, like the grouped-aggregate heads); their runtime bindings are
   ordinary Float functions in tesl/units.rkt *)

(** Build an initial type environment from the stdlib list. *)
(* ── Secret-accepting parameters ────────────────────────────────────────────
   THE RULE, from roadmap/completed/tesl_crypto.md, which subsumes the whole
   secret-accepting-sinks table:

     a `secret T` may be passed where a parameter explicitly marked
     secret-accepting expects a `T`.  Nowhere else.

   OPT-IN IS PER PARAMETER, NOT PER MODULE.  `String.concat` is stdlib too and
   must never accept a secret; `Crypto.checkPassword`'s FIRST argument is the
   stored `Maybe PasswordHash` and only its SECOND is the candidate.  A
   module-level or type-level rule cannot express either, so the unit of marking
   is the argument slot.

   Without this rule the feature is safe and useless: an author declares
   `secret Password = String`, discovers `Crypto.hashPassword body.password`
   does not typecheck (unify is strictly nominal), and — per the roadmap's own
   named risk — the realistic outcome is not a filed issue, it is that they stop
   declaring the type `secret` and lose the protection entirely.

   App authors never write these markings; they only read them in `tesl doc`, so
   the learnable surface stays the one sentence above.

   SINGLE SOURCE.  The SEC003 lint (a string LITERAL reaching a secret-accepting
   parameter — a hardcoded credential) needs exactly this table, so it lives here
   as one exported binding rather than being restated in linter.ml. *)
let secret_accepting_params : (string * int list) list = [
  (* Password storage.  Index 0 is the plaintext being hashed. *)
  "Crypto.hashPassword",   [0];
  (* Index 1 is the CANDIDATE password.  Index 0 is the stored
     `Maybe PasswordHash` and is deliberately NOT marked — a PasswordHash is not
     a secret you were handed, it is a value you already hold. *)
  "Crypto.checkPassword",  [1];
  (* Message authentication: index 0 is the key.  The MESSAGE (index 1) is not
     marked — it is ordinary data, and marking it would let a secret be signed
     as a payload. *)
  "Crypto.signWith",       [0];
  "Crypto.checkSignature", [0];
  (* "Which key did I load?" — a short non-reversible digest, the sanctioned
     answer to the question that would otherwise motivate an unwrap. *)
  "Crypto.keyFingerprint", [0];
  (* Outbound headers: the whole point of these two functions. *)
  "HttpClient.bearer",       [0];
  "HttpClient.secretHeader", [1];
  (* The JWT signing key, index 1 in both.  These were MISSING while `Tesl.JWT`
     had a key newtype of its own: the old type had no `secret_param_expected_base`
     row, so marking the slot would have rejected the stdlib key type itself.  With
     the key unified on `Secret` (2026-07-30) the row is a pure win — it extends
     SEC003 to the two slots where a hardcoded credential matters most, and it lets
     a user's own `secret MyKey = String` be passed to `JWT.sign`/`JWT.verify`,
     which it never could before.  The CLAIMS (index 0) are deliberately unmarked:
     they are ordinary data, and marking them would bless signing a secret as a
     payload — the same reason `Crypto.signWith`'s message index is unmarked. *)
  "JWT.sign",                [1];
  "JWT.verify",              [1];
  "JWT.renew",               [1];
]

let secret_accepting_indices (name : string) : int list =
  match List.assoc_opt name secret_accepting_params with
  | Some idxs -> idxs
  | None -> []

let is_secret_accepting_param (name : string) (index : int) : bool =
  List.mem index (secret_accepting_indices name)

(** The base type a secret-accepting parameter really wants, or [None] when the
    parameter is not one a secret could ever satisfy.

    Deliberately a SHORT total function rather than a chase through the alias
    table: the parameters in {!secret_accepting_params} are stdlib parameters, so
    their declared types are fixed and known here.  `Secret` needs its own row
    because it is a stdlib nominal wrapper over String declared in
    tesl/crypto.rkt — it has no entry in the checker's alias table, so a user's
    `secret ApiKey = String` would not satisfy a `Secret` parameter without it.
    That is the ONE special case, and it is what makes `Crypto.signWith myKey`
    work for a user-declared secret rather than only for the stdlib `Secret`. *)
let secret_param_expected_base (t : ty) : ty option =
  match t with
  | TCon "String" -> Some t_string
  | TCon "Secret" -> Some t_string
  | _ -> None

let make_stdlib_env () : (string * scheme) list =
  stdlib_env

(* ── Stdlib well-formedness: escaping result-var lint (review item 5) ─────────
   A stdlib FUNCTION scheme is an unchecked cast ("unsafeCoerce") when a
   quantified variable appears in the RESULT (after stripping outer
   List/Maybe/Set) as a BARE type variable but in NO argument position — HM then
   instantiates it to whatever the use site demands (review 2.3: requeue/deadJobs
   were `∀a b. a -> b` / `∀a b. a -> List b`).
   NOT flagged:
     • polymorphic data constructors (Left/Right/Ok/Something): their result is a
       TApp (e.g. Either a b), never a bare var;
     • nullary polymorphic values (Nothing, Dict.empty): not functions;
     • `decodeAs`: intentionally result-polymorphic (its type is chosen at runtime
       from a string via the codec registry) — whitelisted. *)
let escaping_result_var_whitelist = [ "decodeAs" ]

(* Collect ALL type-variable ids (incl. negative rigid/quantified ids — unlike
   [free_vars], which returns only positive unification ids). *)
let all_type_vars (ty : ty) : int list =
  let rec go acc = function
    | TVar id                   -> if List.mem id acc then acc else id :: acc
    | TCon _                    -> acc
    | TApp (x, y) | TFun (x, y) -> go (go acc x) y
  in
  go [] ty

let split_fun_type (ty : ty) : ty list * ty =
  let rec go args = function
    | TFun (dom, cod) -> go (dom :: args) cod
    | res -> (List.rev args, res)
  in
  go [] ty

let rec strip_result_containers = function
  | TApp (TCon ("List" | "Maybe" | "Set"), inner) -> strip_result_containers inner
  | t -> t

(** Stdlib schemes whose result carries an escaping quantified var (item 5).
    Returns (name, offending_var_ids); empty iff the table is well-formed. *)
let stdlib_escaping_result_vars () : (string * int list) list =
  List.filter_map (fun (name, sch) ->
    if List.mem name escaping_result_var_whitelist then None
    else match sch.mono with
      | TFun _ ->
        let (args, res) = split_fun_type sch.mono in
        let arg_vars = List.concat_map all_type_vars args in
        (match strip_result_containers res with
         | TVar id when List.mem id sch.vars && not (List.mem id arg_vars) ->
           Some (name, [id])
         | _ -> None)
      | _ -> None
  ) stdlib_env

(* ── Framework-reserved proof predicates (review item 6) ──────────────────────
   Single source of truth for the structural / provenance predicate names owned
   by the framework.  These MUST NOT be user-definable or user-mintable: they are
   produced only by the SQL/queue layer (FromDb/FromQueue/FromDeadQueue), the
   quantifier machinery (ForAll/MaybeForAll/ForAllValues/ForAllKeys), the
   existential packer (Exists) and the structural id helper (Id).
   NOTE: this is deliberately distinct from the *stdlib user-predicate* allowlists
   (IsNonZero/IsSorted/HasKey/…), which ARE user-facing and owned by the declaring
   Tesl.* module — do not fold those in here. *)
let framework_proof_predicates : string list =
  [ "ForAll"; "MaybeForAll"; "ForAllValues"; "ForAllKeys"; "Exists"
  ; "FromDb"; "FromQueue"; "FromDeadQueue"; "Id" ]

let is_framework_predicate (name : string) : bool =
  List.mem name framework_proof_predicates

(* ── Lookup helpers ───────────────────────────────────────────────────────── *)

let env_lookup name (env : (string * scheme) list) =
  List.assoc_opt name env

let env_extend name sch (env : (string * scheme) list) =
  (name, sch) :: env

(* ── Stdlib module export registry ───────────────────────────────────────── *)
(** Authoritative export lists for every Tesl.* stdlib module.
    Used to validate `import Tesl.X exposing [name]` at compile time —
    the compiler rejects any name that is not listed here. *)
let tesl_module_exports : (string * string list) list = [
  ( "Tesl.Prelude",
    [ "Any"; "Bool"; "True"; "False"; "Bytes"; "Char"; "Hash"; "Int"; "Integer";
      "Keyword"; "List"; "Null"; "Number"; "Fact"; "Real"; "String"; "Symbol";
      "Unit"; "Vector"; "int"; "integer"; "string";
      "andLeft"; "andRight"; "attachFact"; "detachFact"; "forgetFact"; "introAnd" ] );
  ( "Tesl.Int32",
    (* NT-07: a JS-safe (< 2^53) bounded integer for wire/storage boundaries.
       Nominal — does NOT unify with Int.  Range rule: `Int32` out when the
       result cannot leave [-2^31, 2^31), `Maybe Int32` when it can. *)
    [ "Int32"; "IsNonNegative"; "IsNonZero";
      "Int32.fromInt"; "Int32.toInt"; "Int32.fromIntClamped";
      "Int32.parse"; "Int32.fromFloat"; "Int32.toFloat"; "Int32.toString";
      "Int32.minValue"; "Int32.maxValue";
      "Int32.min"; "Int32.max"; "Int32.clamp"; "Int32.modulo";
      "Int32.add"; "Int32.subtract"; "Int32.multiply"; "Int32.divide";
      "Int32.negate"; "Int32.abs"; "Int32.pow";
      "Int32.isPositive"; "Int32.isNegative"; "Int32.isZero";
      "Int32.isEven"; "Int32.isOdd"; "Int32.sign"; "Int32.digits";
      "Int32.nonZero"; "Int32.nonNegative" ] );
  ( "Tesl.Maybe",
    [ "Maybe"; "Something"; "Nothing" ] );
  ( "Tesl.Result",
    [ "Result"; "Ok"; "Err" ] );
  ( "Tesl.DB",
    [ "dbRead"; "dbWrite"; "DeleteResult"; "NoRowDeleted"; "RowsDeleted" ] );
  ( "Tesl.EitherPrim",
    [ "Either"; "Left"; "Right" ] );
  ( "Tesl.Either",
    [ "Either"; "Left"; "Right";
      "Either.isLeft"; "Either.isRight"; "Either.fromLeft"; "Either.fromRight";
      "Either.map"; "Either.mapLeft"; "Either.andThen"; "Either.withDefault";
      "Either.toMaybe"; "Either.fromMaybe"; "Either.partition" ] );
  ( "Tesl.String",
    [ "IsTrimmed"; "IsUpperCase"; "IsLowerCase"; "IsNonNegative"; "IsNonEmpty";
      "String.length"; "String.isEmpty"; "String.startsWith"; "String.endsWith";
      "String.contains"; "String.toUpper"; "String.toLower"; "String.trim";
      "String.trimLeft"; "String.trimRight"; "String.split"; "String.join";
      "String.replace"; "String.slice"; "String.concat"; "String.repeat";
      "String.reverse"; "String.toInt"; "String.toFloat"; "String.fromInt";
      "String.fromFloat"; "String.lines"; "String.words";
      "String.padLeft"; "String.padRight"; "String.dropPrefix"; "String.dropSuffix";
      "String.indexOf"; "String.requireNonEmpty" ] );
  ( "Tesl.Regex",
    (* Pattern-literal-only regex over String — see LANGUAGE-SPEC.md §21.6.
       Pure: no capability.  The pattern is argument 1 everywhere. *)
    [ "Regex.matches"; "Regex.find"; "Regex.findAll"; "Regex.captures";
      "Regex.replace"; "Regex.split" ] );
  ( "Tesl.List",
    [ "IsSorted";
      "List.isEmpty"; "List.length"; "List.head"; "List.tail"; "List.last"; "List.nth";
      "List.map"; "List.filter"; "List.filterCheck"; "List.allCheck";
      "List.filterMap"; "List.foldl"; "List.foldr"; "List.append"; "List.concat";
      "List.reverse"; "List.sort"; "List.sortBy"; "List.contains"; "List.find";
      "List.findIndex"; "List.take"; "List.drop"; "List.zip"; "List.zipWith";
      "List.unzip"; "List.flatten"; "List.dedupe"; "List.range"; "List.repeat";
      "List.sum"; "List.product"; "List.maximum"; "List.minimum"; "List.any";
      "List.all"; "List.count"; "List.partition"; "List.intersperse";
      "List.intercalate"; "List.groupBy"; "List.unique";
      "List.concatMap"; "List.member"; "List.emptyForAll" ] );
  ( "Tesl.ListPrim",
    [ "ListPrim.head"; "ListPrim.tail"; "ListPrim.append" ] );
  ( "Tesl.Int",
    [ "IsNonNegative"; "IsNonZero";
      "Int.parse"; "Int.fromFloat"; "Int.toString"; "Int.abs"; "Int.min"; "Int.max";
      "Int.clamp"; "Int.isPositive"; "Int.isNegative"; "Int.isZero"; "Int.isEven";
      "Int.isOdd"; "Int.gcd"; "Int.lcm"; "Int.pow"; "Int.digits"; "Int.toFloat";
      "Int.sign"; "Int.nonZero"; "Int.nonNegative"; "Int.divide"; "Int.modulo" ] );
  ( "Tesl.Float",
    [ "Float"; "FloatNonZero";
      "Float.requireNonZero"; "Float.parse"; "Float.toString"; "Float.toInt";
      "Float.add"; "Float.sub"; "Float.mul"; "Float.div"; "Float.abs";
      "Float.min"; "Float.max"; "Float.clamp"; "Float.ceil"; "Float.floor";
      "Float.round"; "Float.sqrt"; "Float.pow"; "Float.log"; "Float.exp";
      "Float.sin"; "Float.cos"; "Float.tan"; "Float.isNaN"; "Float.isInfinite";
      "Float.isPositive"; "Float.isNegative"; "Float.isZero"; "Float.sign";
      "Float.infinity"; "Float.nan" ] );
  ( "Tesl.Dict",
    [ "Dict"; "HasKey";
      "Dict.empty"; "Dict.singleton"; "Dict.insert"; "Dict.insertWith"; "Dict.remove";
      "Dict.lookup"; "Dict.requireKey"; "Dict.get"; "Dict.member"; "Dict.size";
      "Dict.isEmpty"; "Dict.keys"; "Dict.values"; "Dict.toList"; "Dict.fromList";
      "Dict.map"; "Dict.mapWithKey"; "Dict.filter"; "Dict.filterWithKey";
      "Dict.filterCheckValues"; "Dict.filterCheckKeys";
      "Dict.foldl"; "Dict.foldr"; "Dict.union"; "Dict.unionWith";
      "Dict.intersection"; "Dict.difference"; "Dict.update"; "Dict.delete" ] );
  ( "Tesl.Set",
    [ "Set";
      "Set.empty"; "Set.singleton"; "Set.insert"; "Set.remove"; "Set.member";
      "Set.size"; "Set.isEmpty"; "Set.toList"; "Set.fromList"; "Set.union";
      "Set.intersection"; "Set.difference"; "Set.isSubset"; "Set.map";
      "Set.filter"; "Set.foldl"; "Set.any"; "Set.all"; "Set.partition";
      "Set.filterCheck"; "Set.allCheck"; "Set.delete" ] );
  ( "Tesl.Tuple",
    [ "Tuple2"; "Tuple3";
      "Tuple2.first"; "Tuple2.second";
      "Tuple3.first"; "Tuple3.second"; "Tuple3.third" ] );
  ( "Tesl.Time",
    [ "PosixMillis"; "nowMillis"; "time"; "formatTime"; "durationMs";
      "addMs"; "subtractMs"; "diffMs";
      "Time.posixToSeconds"; "Time.secondsToPosix";
      "Time.truncHour"; "Time.truncDay"; "Time.truncWeek";
      "Time.truncMonth"; "Time.truncYear"; "Time.offsetAt";
      (* Duration bridge — typed spans (First-Class Units) *)
      "Time.add"; "Time.subtract"; "Time.diff";
      "TimeZone"; "Utc"; "FixedOffset" ]
    @ Tz_zones.ctor_names );
  ( "Tesl.Money",
    [ "Money"; "Currency"; "ExchangeRate";
      (* proof predicates owned by this module *)
      "SameCurrency"; "NonNegativeMoney"; "RateFor";
      "Money.fromMinorUnits"; "Money.minorUnits"; "Money.currency";
      "Money.scale"; "Money.scaleBy";
      "Money.negate"; "Money.abs"; "Money.isZero"; "Money.isNegative";
      "Money.display"; "Money.add"; "Money.subtract"; "Money.compare";
      "Money.requireSameCurrency"; "Money.requireNonNegative";
      "Money.requireRateFor"; "Money.convert"; "Money.convertChecked";
      "Currency.code"; "Currency.minorDigits"; "Currency.fromCode";
      "ExchangeRate.make"; "ExchangeRate.fromCurrency";
      "ExchangeRate.toCurrency"; "ExchangeRate.rate"; "ExchangeRate.asOf";
      (* money rates: money PER quantity *)
      "MoneyRate.perHour"; "MoneyRate.perDay"; "MoneyRate.perKilogram";
      "MoneyRate.perLiter"; "MoneyRate.perSquareMeter";
      "MoneyRate.currency"; "MoneyRate.display" ]
      (* moneyCodec lives in Tesl.Json (inline-lowered), NOT here *)
    @ List.map fst Units_catalog.money_rate_aliases
    @ Currencies.ctor_names
    @ Currencies.money_ctor_names );
  ( "Tesl.Units", Units_catalog.exported_names );
  ( "Tesl.Random",
    [ "randomInt"; "randomFloat"; "random" ] );
  ( "Tesl.UUID",
    [ "IsUuid"; "uuid"; "UUID.v4"; "UUID.v7"; "UUID.validate";
      "uuidV4Codec"; "uuidV7Codec" ] );
  ( "Tesl.Env",
    [ "env"; "envInt"; "envString"; "requireEnv"; "requireSecret"; "envRead" ] );
  ( "Tesl.Json",
    [ "stringCodec"; "intCodec"; "int32Codec"; "boolCodec"; "floatCodec"; "posixMillisCodec";
      "moneyCodec";
      "listCodec"; "dictCodec"; "setCodec" ] );
  ( "Tesl.ApiTest",
    [ "HttpResponse"; "JsonValue"; "JsonNull"; "SseStream";
      "statusOk"; "statusClientError"; "statusServerError";
      "jsonInt"; "jsonString"; "jsonBool"; "jsonArray"; "jsonObject"; "jsonLength";
      "isNull"; "isNotNull"; "includesWhere"; "excludesWhere";
      "hasLength"; "isEmpty"; "isNotEmpty"; "arrayAt"; "hasField"; "fieldAt"; "bodyField";
      (* the session cookie a response set, as a Cookie-header-ready pair, so a
         round-trip test never parses `Set-Cookie` by hand *)
      "responseCookie";
      "jsonContains"; "subscribe"; "collect";
      "JobResult"; "JobOk"; "JobFailed";
      "processNextJob"; "processNextDeadJob"; "drainQueue"; "pendingJobCount";
      "expectJobOk"; "expectJobFailed";
      (* outbound-HTTP double *)
      "stubHttp"; "stubHttpFailure"; "stubHttpTimeout";
      "httpCalled"; "httpCallCount"; "httpLastBody" ] );
  ( "Tesl.JWT",
    (* `Authentic` is Tesl.Crypto's fact, re-exposed here because JWT.verify
       mints it (Crypto Phase 2): a program that verifies a session token and
       wants to DEMAND verification downstream should not have to import
       Tesl.Crypto to name the fact.  Same predicate, two minting sites, two
       subject types — see the note on the JWT.verify row in
       validation_common.ml's stdlib_func_infos. *)
    (* No key type here: `JWT.sign`/`JWT.verify` take Tesl.Crypto's `Secret`, so
       a program that signs imports `Secret` (or `requireSecret`) from where it
       lives.  Re-exposing it under Tesl.JWT would make one name reachable
       through two module rows, which is the drift the stdlib
       binding-existence seam test exists to prevent. *)
    [ "jwt"; "JwtToken"; "JWT.sign";
      "JWT.verify"; "JWT.renew"; "JWT.decode"; "Authentic" ] );
  ( "Tesl.Sso",
    (* SsoConnection / SsoSubjectKey are TYPES only (no ctor row → opaque, like
       PasswordHash).  Phase 3 tables-only foundation for the `sso` clause. *)
    [ "SsoConnection"; "SsoSubjectKey"; "SsoIdentity";
      "SsoProvider"; "Github"; "Google";
      "Sso.defaults"; "Sso.oidc"; "Sso.keyText"; "Sso.subject";
      "Sso.email"; "Sso.tenant"; "Sso.claim";
      "Sso.allowedEmailDomains"; "Sso.allowedHostedDomains"; "Sso.allowedTenants" ] );
  ( "Tesl.Proxy",
    (* Item A: authenticating-proxy edge binding.  `ProxyBound` is the fact
       minted only by the check-shaped `Proxy.verifyBinding`. *)
    [ "ProxyBound"; "Proxy.verifyBinding" ] );
  ( "Tesl.Crypto",
    (* Password storage, message authentication, digests and secrets.
       `PasswordHash` and `Signature` appear here as TYPES only — there is no
       constructor row for them in stdlib_env, which is what makes them opaque
       (`PasswordHash "hunter2"` is a T001 unknown constructor). *)
    [ "PasswordHash"; "Signature"; "Secret";
      "HashFor"; "PasswordVerified"; "Authentic";
      "Crypto.hashPassword"; "Crypto.checkPassword"; "Crypto.needsRehash";
      "Crypto.signWith"; "Crypto.checkSignature";
      "Crypto.signatureHex"; "Crypto.signatureFromHex";
      "Crypto.signatureBase64"; "Crypto.signatureFromBase64";
      "Crypto.fingerprint"; "Crypto.keyFingerprint"; "Crypto.randomToken";
      "Crypto.hmacSha256"; "Crypto.sha256"; "Crypto.sha512" ] );
  ( "Tesl.Cache",
    [ "cache"; "Cache.get"; "Cache.set"; "Cache.delete"; "Cache.invalidate";
      (* config-block type (typed config block) *)
      "Cache" ] );
  ( "Tesl.Email",
    [ "emailCap"; "EmailBody"; "TextBody"; "HtmlBody"; "RichBody";
      "Email.send"; "startEmailWorker";
      (* config-block types (typed config blocks) *)
      "Email"; "SmtpConfig" ] );
  ( "Tesl.Database",
    [ "Database"; "DatabaseBackend"; "Postgres"; "Memory";
      "PostgresConfig"; "PostgresConnection";
      "TcpConnection"; "SocketConnection" ] );
  (* App-simplification (roadmap/next/app_simplification.md): `main : () -> App`
     returning a typed App record; `Job` pairs a job type with its handler +
     optional dead-letter handler inside a folded `queue`. *)
  ( "Tesl.App",
    [ "App" ] );
  ( "Tesl.SSE",
    [ "SseChannel" ] );
  ( "Tesl.HttpClient",
    [ "httpClient"; "HttpResponse"; "HttpResponse?";
      "HttpClient.get"; "HttpClient.post"; "HttpClient.put"; "HttpClient.delete";
      "HttpClient.bearer"; "HttpClient.secretHeader" ] );
  ( "Tesl.Agent",
    [ "aiProvider"; "Agent"; "LlmProvider"; "AgentReply"; "AgentReply?"; "Tool"; "ToolStep";
      "mockProvider"; "ask";
      "mockToolProvider"; "toolUseStep"; "textStep";
      "anthropic"; "openai"; "mistral"; "local";
      "tool"; "asTool"; "serverTools"; "humanActions";
      "askReply"; "askWith"; "replyText"; "replyTokens"; "replyToolCalls";
      "decodeAs"; "askFor";
      "Conversation"; "Conversation?"; "ConversationTurn"; "ConversationTurn?";
      "newConversation"; "conversationFrom"; "converse"; "converseStreaming"; "turnReply";
      "turnConversation"; "conversationJson"; "conversationLength"; "agentRun" ] );
  (* Tesl.Http gained a real export list when the session cookie landed
     (2026-07-30).  Before that it was one of the loosely-validated internal
     modules below, which meant its names were also invisible to the stdlib
     binding-existence seam test — an importable name with no runtime `provide`
     would have typechecked and then failed at load.  `HttpRequest` was the only
     name anyone imported from it, so making the list strict breaks nothing. *)
  ( "Tesl.Http",
    [ "HttpRequest"; "cookieCap";
      "Http.setSessionCookie"; "Http.clearSessionCookie"; "Http.sessionToken" ] );
  (* Tesl.DB, Tesl.Uuid, Tesl.Logging, Tesl.Queue, Tesl.Sse —
     internal modules; imports validated loosely (unknown names accepted)
     Note: Tesl.UUID (uppercase) now has a full export list above. *)
]

(** Look up the known exports for a Tesl stdlib module.
    Returns `None` when the module has no registered export list (unknown module
    or internal module), in which case all import names are accepted. *)
let tesl_module_export_set (module_name : string) : string list option =
  List.assoc_opt module_name tesl_module_exports

(* ── Single-source stdlib "home module" registry (A7) ──────────────────────── *)

(** Names that are ALWAYS available with no import: operators, the Prelude
    values [check]/[identity]/[const]/[print]/[True]/[False]/[Unit], and the GDP
    proof utilities.  Their runtime is provided by the always-emitted
    dsl/runtime + Prelude requires, so using them compiles with no `import`.

    Constructors ([Ok]/[Err]/[Nothing]/[Something]/[Left]/[Right]/[Tuple2]/…/
    [TextBody]/…) are DELIBERATELY excluded from both this set and
    {!stdlib_home_module}: they are handled by the constructor-scope machinery
    (`Maybe(..)`/`Result(..)`/`EmailBody` import forms), and the stdlib-fn scope
    checker never records bare constructor uses. *)
let always_available_stdlib_names : string list = [
  (* arithmetic / comparison / boolean operators *)
  "+"; "-"; "*"; "/"; "%"; "quotient"; "modulo";
  "=="; "!="; "<"; "<="; ">"; ">=";
  "&&"; "||"; "!"; "not";
  (* Prelude values that need no import *)
  "True"; "False"; "Unit";
  (* `print` was REMOVED from the surface language 2026-07-29. It was ambient,
     needed no import, and was typed `t_fun [_a] t_unit` — a bare type variable
     that unifies with anything, INCLUDING a `secret`. So `print mySecret`
     typechecked and wrote the plaintext to stdout, defeating the whole `secret`
     guarantee through a name nothing in the corpus used (zero call sites) and
     that W090 already told authors not to use. `print x` is now an unknown-name
     error, which is a better diagnostic than a warning was. Observable output
     goes through `telemetry`. *)
  "check"; "identity"; "const";
  (* GDP / proof utilities (Tesl.Prelude exports, emitted with the always-on
     Prelude require) *)
  "forgetFact"; "detachFact"; "attachFact"; "andLeft"; "andRight"; "introAnd";
]

(** Bare (unqualified) stdlib value/function names whose runtime lives in an
    import-gated module that has NO export list in {!tesl_module_exports}
    (Tesl.Telemetry / Tesl.Agent) or whose bare token needs an explicit
    home-module mapping (Env / Id / Time / Random / ApiTest / Cli / Queue / UUID
    codecs).  The qualified (dotted) rows are DERIVED from {!tesl_module_exports}
    in {!stdlib_home_module} below, so this list carries only the bare rows. *)
let stdlib_bare_home_module : (string * string) list = [
  (* Int32 (NT-07): the bare TYPE name is import-gated like any stdlib name. *)
  "Int32", "Tesl.Int32";
  (* Env *)
  "env", "Tesl.Env"; "envInt", "Tesl.Env"; "envString", "Tesl.Env";
  "requireEnv", "Tesl.Env"; "requireSecret", "Tesl.Env";
  (* Id *)
  "generateId", "Tesl.Id"; "generatePrefixedId", "Tesl.Id";
  (* Random *)
  "randomInt", "Tesl.Random"; "randomFloat", "Tesl.Random";
  (* Time *)
  "nowMillis", "Tesl.Time"; "formatTime", "Tesl.Time"; "durationMs", "Tesl.Time";
  "addMs", "Tesl.Time"; "diffMs", "Tesl.Time"; "subtractMs", "Tesl.Time";
  (* HTTP status helpers + queue/job-drain test helpers (Tesl.ApiTest) *)
  "statusOk", "Tesl.ApiTest"; "statusClientError", "Tesl.ApiTest";
  "statusServerError", "Tesl.ApiTest";
  "pendingJobCount", "Tesl.ApiTest"; "drainQueue", "Tesl.ApiTest";
  (* the session-cookie reader — a bare name, import-gated like its siblings *)
  "responseCookie", "Tesl.ApiTest";
  "processNextJob", "Tesl.ApiTest"; "processNextDeadJob", "Tesl.ApiTest";
  (* outbound-HTTP double — bare names, import-gated like their siblings *)
  "stubHttp", "Tesl.ApiTest"; "stubHttpFailure", "Tesl.ApiTest";
  "stubHttpTimeout", "Tesl.ApiTest"; "httpCalled", "Tesl.ApiTest";
  "httpCallCount", "Tesl.ApiTest"; "httpLastBody", "Tesl.ApiTest";
  (* Queue infrastructure (Tesl.Queue — internal module, no export list) *)
  "requeue", "Tesl.Queue"; "deadJobs", "Tesl.Queue";
  (* UUID codecs (bare tokens; UUID.* dotted forms come from the derived rows) *)
  "uuidV4Codec", "Tesl.UUID"; "uuidV7Codec", "Tesl.UUID";
  (* Telemetry — was MISSING from every checker table (the soundness gap). *)
  "initTelemetry", "Tesl.Telemetry"; "telemetry", "Tesl.Telemetry";
  (* Metrics signal — same module, same ambient model. *)
  "counter", "Tesl.Telemetry"; "histogram", "Tesl.Telemetry";
  "gauge", "Tesl.Telemetry";
  (* Whole Tesl.Agent bare API — was MISSING from every checker table.
     NOTE: the compile-time-lowered provider/tool forms
     (anthropic/openai/mistral/local/asTool) are intentionally NOT here — they
     lower via the `__tart_` desugar path and have no plain runtime require, so
     demanding an import for them would contradict what the emitter honors. *)
  "mockProvider", "Tesl.Agent"; "ask", "Tesl.Agent";
  "mockToolProvider", "Tesl.Agent"; "toolUseStep", "Tesl.Agent";
  "textStep", "Tesl.Agent"; "tool", "Tesl.Agent";
  "askReply", "Tesl.Agent"; "askWith", "Tesl.Agent";
  "replyText", "Tesl.Agent"; "replyTokens", "Tesl.Agent";
  "replyToolCalls", "Tesl.Agent"; "decodeAs", "Tesl.Agent";
  "askFor", "Tesl.Agent"; "newConversation", "Tesl.Agent";
  "conversationFrom", "Tesl.Agent"; "converse", "Tesl.Agent";
  "converseStreaming", "Tesl.Agent"; "turnReply", "Tesl.Agent";
  "turnConversation", "Tesl.Agent"; "conversationJson", "Tesl.Agent";
  "conversationLength", "Tesl.Agent"; "agentRun", "Tesl.Agent";
]

(** THE authoritative name → home-module table (A7 single source).

    Consumed by BOTH the scope checker's "needs import M" decision
    ({!Checker.check_stdlib_fn_import_scope}) and — belt-and-suspenders — the
    exhaustiveness test that guards {!Emit_racket.module_path_table}.  A name that
    is a function value in {!stdlib_env}, is not a constructor, and is neither in
    {!always_available_stdlib_names} nor here, is a compile-time regression
    (caught by the exhaustiveness test).

    The dotted (qualified) rows are DERIVED from {!tesl_module_exports} — filter
    to names containing '.' — so the very same list that validates
    `import Tesl.X exposing [X.f]` also drives the scope decision (no drift). The
    bare rows come from {!stdlib_bare_home_module}. *)
let stdlib_home_module : (string * string) list =
  let dotted_rows =
    List.concat_map (fun (m, names) ->
      List.filter_map (fun n ->
        if String.contains n '.' then Some (n, m) else None) names)
      tesl_module_exports
  in
  stdlib_bare_home_module @ dotted_rows

(** Resolve the Tesl.* module that provides [name] at runtime, or [None] when
    [name] is always-available / a constructor / not a gated stdlib name. *)
let stdlib_home_module_of (name : string) : string option =
  List.assoc_opt name stdlib_home_module

(** A2-3 single source: the capability(ies) a referenced stdlib name introduces.

    THE authoritative effect→capability map for stdlib *value* names. The
    capability checker's [var_caps] (validation_capabilities.ml) is DERIVED from
    this rather than re-listing the same names, so the two cannot drift (generator
    class G1). Names NOT listed here introduce no capability (pure functions).

    NOT covered here (handled structurally elsewhere, by design):
    - the SQL keyword operations `insert`/`select`/`update`/`delete` — they are not
      stdlib value names; [is_sql_read_builtin]/[is_sql_write_builtin] classify
      them, since a user function may legitimately shadow those spellings.

    Pure stdlib functions deliberately absent (no capability): the PosixMillis
    arithmetic ops `diffMs`/`addMs`/`subtractMs`/`formatTime`/`secondsToPosix`/
    `posixToMillis` (clock *reads* — `nowMillis`/`now`/`durationMs`, the last of
    which computes "elapsed since a past timestamp" and so reads NOW — take
    `time`); constructors and accessors of every module.

    Drift note (2026-07-05 fresh review): `durationMs` was in the "deliberately
    absent" list above, but its runtime (`tesl/time.rkt:42-43`) calls
    `require-capabilities! (list time)`.  A handler declaring `requires []` could
    therefore read the wall clock — the compile-time table must mirror the runtime
    self-checks.  This table is a hand-maintained mirror of the per-module
    `require-capabilities!` calls; when adding a clock/IO stdlib op, update BOTH. *)
let stdlib_capabilities : (string * string list) list = [
  (* Time — reading the wall clock is an effect. *)
  "now", ["time"]; "nowMillis", ["time"]; "durationMs", ["time"];
  (* Random *)
  "randomInt", ["random"]; "randomFloat", ["random"];
  "generateId", ["random"]; "generatePrefixedId", ["random"];
  (* Env *)
  "env", ["envRead"]; "envInt", ["envRead"];
  "envString", ["envRead"]; "requireEnv", ["envRead"];
  "requireSecret", ["envRead"];
  (* Queue infrastructure *)
  "deadJobs", ["queueRead"]; "requeue", ["queueWrite"];
  (* JWT.  `JWT.sign` charges `time` on top of `jwt`: it stamps the `exp` claim
     from the wall clock, and a capability marks an EFFECT (same reason
     `nowMillis` charges it).  `JWT.verify` also reads the clock to compare
     `exp` — see the drift note below; it is recorded, not yet propagated. *)
  "JWT.sign", ["jwt"; "time"];
  "JWT.verify", ["jwt"]; "JWT.decode", ["jwt"];
  (* JWT.renew signs, so it charges `time` for the same reason JWT.sign does. *)
  "JWT.renew", ["jwt"; "time"];
  (* Http: writing a cookie is an effect ON THE RESPONSE, so both writers are
     gated by `cookieCap`.  `Http.sessionToken` is deliberately absent — reading
     request data is not an effect, exactly as `request.cookies` is ungated. *)
  "Http.setSessionCookie", ["cookieCap"];
  "Http.clearSessionCookie", ["cookieCap"];
  (* Crypto — ONLY the two that draw randomness.  A capability marks an effect;
     sensitivity is carried by the types and the facts, which track the VALUE
     rather than the function.  So signWith/checkSignature/checkPassword/
     needsRehash/fingerprint are ungated: they are as privileged as
     String.length.  (`jwt` above is inconsistent with that rule — the HMAC
     itself is pure and is gated — but removing a capability would break every
     `requires [jwt]` in the wild, so it stays as recorded debt rather than
     being propagated here.  `JWT.sign`'s `time` is NOT that kind of debt: it
     genuinely reads the clock.  RECORDED DRIFT, 2026-07-29: `JWT.verify` reads
     the clock too — it compares `exp` against now — and so should charge `time`
     by the same rule.  Adding it would put `time` in the capability closure of
     every JWT-authenticated endpoint in the corpus, which is a bigger change
     than the one authorised here, so it is written down rather than done.) *)
  "Crypto.hashPassword", ["random"]; "Crypto.randomToken", ["random"];
  (* HttpClient *)
  "HttpClient.get", ["httpClient"]; "HttpClient.post", ["httpClient"];
  "HttpClient.put", ["httpClient"]; "HttpClient.delete", ["httpClient"];
  (* HttpClient.bearer / .secretHeader build a header PAIR and perform no I/O:
     a capability marks an effect, and these have none.  The verb that actually
     sends still requires `httpClient`. *)
  (* UUID generation (A2-3 drift fix: these were MISSING from var_caps). *)
  "UUID.v4", ["uuid"]; "UUID.v7", ["uuid"];
  (* Tesl.Agent inference entry points — every call that contacts a provider. *)
  "ask", ["aiProvider"]; "askReply", ["aiProvider"]; "askWith", ["aiProvider"];
  "askFor", ["aiProvider"]; "converse", ["aiProvider"];
  "converseStreaming", ["aiProvider"]; "agentRun", ["aiProvider"];
]

(** The capability(ies) referenced stdlib [name] introduces ([] if pure/unknown). *)
let stdlib_capabilities_of (name : string) : string list =
  match List.assoc_opt name stdlib_capabilities with Some c -> c | None -> []

(** Complete set of valid Tesl.* stdlib module names (including internal modules
    that have runtime files but no registered export list).
    Used to reject `import Tesl.Unknown` with a compile-time error. *)
let tesl_known_module_names : string list = [
  "Tesl.Prelude"; "Tesl.String"; "Tesl.Regex"; "Tesl.Int"; "Tesl.Int32"; "Tesl.Float";
  "Tesl.List"; "Tesl.ListPrim"; "Tesl.Dict"; "Tesl.Maybe"; "Tesl.Either"; "Tesl.EitherPrim"; "Tesl.Result";
  "Tesl.Http"; "Tesl.HttpClient"; "Tesl.Json"; "Tesl.DB"; "Tesl.Time"; "Tesl.Random";
  "Tesl.Uuid"; "Tesl.UUID"; "Tesl.Set"; "Tesl.Env";
  "Tesl.Telemetry"; "Tesl.ApiTest"; "Tesl.Tuple"; "Tesl.Id";
  "Tesl.Queue"; "Tesl.Sse"; "Tesl.Logging";
  "Tesl.JWT"; "Tesl.Cache"; "Tesl.Email"; "Tesl.Database"; "Tesl.SSE"; "Tesl.App"; "Tesl.Agent";
  (* Tesl.Sso: SSO / third-party-auth surface (roadmap/next/ensure_sso_works.md,
     Phase 3), backed by tesl/sso.rkt. *)
  "Tesl.Sso";
  (* Tesl.Proxy: authenticating-proxy edge binding (Item A, #50.2). *)
  "Tesl.Proxy";
  "Tesl.Money"; "Tesl.Units";
  (* Tesl.Crypto: REINSTATED with a real tesl/crypto.rkt behind it (password
     storage, message authentication, digests, secrets).  It was removed
     2026-07-07 precisely because it had no runtime file; the seam test
     test_stdlib_runtime_binding.ml is what makes reinstating it safe. *)
  "Tesl.Crypto";
  (* Tesl.Bool / Tesl.Map / Tesl.Channel / Tesl.Sql are still removed
     2026-07-07: they had NO runtime .rkt file, so `import Tesl.Map`
     typechecked and then crashed at Racket load ("cannot open module file").
     Rejecting the import at compile time is the fail-closed behaviour;
     test_stdlib_runtime_binding.ml pins every remaining module to a real file. *)
]

(** Returns [true] when [name] is a known Tesl.* stdlib module. *)
let is_known_tesl_module (name : string) : bool =
  List.mem name tesl_known_module_names

(* ── Exported-constant shallow typing (#34) ──────────────────────────────── *)

(** The type of a bare top-level constant (`kMax = 5`), derived WITHOUT running
    inference on its module.  Cross-module signatures are annotation-driven and
    a bare const has no annotation, so only values whose type is syntactically
    evident can be bound by an importing module's checker; for anything else
    the importer's unbound-name error explains the wrap-in-a-fn workaround
    (see Import_suggest).  Single source of truth for both the checker's
    import-side binding and the error hint's classification. *)
let rec shallow_const_ty (e : Ast.expr) : ty option =
  match e with
  | Ast.ELit { lit; _ } ->
    (match lit with
     | Ast.LInt _ | Ast.LBigInt _ -> Some t_int
     | Ast.LFloat _               -> Some t_float
     | Ast.LBool _                -> Some t_bool
     | Ast.LString _              -> Some t_string
     | Ast.LInterp _              -> Some t_string)
  | Ast.EUnop { op = Ast.UNeg; arg; _ } -> shallow_const_ty arg
  | Ast.EList { elems = e0 :: rest; _ } ->
    (match shallow_const_ty e0 with
     | Some t when List.for_all (fun x -> shallow_const_ty x = Some t) rest ->
       Some (t_list t)
     | _ -> None)
  | _ -> None
