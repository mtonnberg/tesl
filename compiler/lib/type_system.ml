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
let t_string  = TCon "String"
let t_bool    = TCon "Bool"
let t_float   = TCon "Float"
let t_unit    = TCon "Unit"
let t_posix   = TCon "PosixMillis"
let t_fact    = TCon "Fact"
let t_delete_result = TCon "DeleteResult"
let t_jwt_token  = TCon "JwtToken"
let t_jwt_secret = TCon "JwtSecret"
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

type type_error = {
  loc     : loc;
  message : string;
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

  (* ── Int ─────────────────────────────────────────────────────────────── *)
  "Int.parse",    mono (t_fun [t_string] (t_maybe t_int));
  "Int.toString", mono (t_fun [t_int] t_string);
  "Int.abs",      mono (t_fun [t_int] t_int);
  "Int.min",      mono (t_fun [t_int; t_int] t_int);
  "Int.max",      mono (t_fun [t_int; t_int] t_int);
  "Int.nonNegative", mono (t_fun [t_int] t_int);  (* check-like but simpler *)

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

  (* ── Time ────────────────────────────────────────────────────────────── *)
  "nowMillis",     mono t_posix;
  "Time.posixToSeconds", mono (t_fun [t_posix] t_int);
  "Time.secondsToPosix", mono (t_fun [t_int] t_posix);
  "Time.millisToSeconds", mono (t_fun [t_posix] t_int);
  "formatTime",    mono (t_fun [t_posix; t_string; t_string] t_string);
  "durationMs",    mono (t_fun [t_posix] t_int);
  "addMs",         mono (t_fun [t_posix; t_int] t_posix);
  "diffMs",        mono (t_fun [t_posix; t_posix] t_int);
  "subtractMs",    mono (t_fun [t_posix; t_int] t_posix);

  (* ── Either ─────────────────────────────────────────────────────────── *)
  (* The two ADT CONSTRUCTORS stay here (they are leaves).  The 10 pure Either
     COMBINATORS (isLeft/isRight/fromLeft/fromRight/map/mapLeft/andThen/
     withDefault/toMaybe/fromMaybe) were LIFTED to tesl/either.tesl — their
     types are now inferred from that source via load_imported_func_sigs, and
     their bodies compile to tesl/either-derived.rkt. *)
  "Left",             { vars = _r2_ab; mono = t_fun [_a] (t_either _a _b) };
  "Right",            { vars = _r2_ab; mono = t_fun [_b] (t_either _a _b) };

  (* ── Cli ─────────────────────────────────────────────────────────────── *)
  "cli.args",          mono (t_list t_string);
  "lookupPortArgument", mono (t_fun [t_list t_string] (t_maybe t_string));

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

  (* ── Random ──────────────────────────────────────────────────────────── *)
  "randomInt",     mono (t_fun [t_int; t_int] t_int);
  "randomFloat",   mono t_float;

  (* ── UUID ────────────────────────────────────────────────────────────── *)
  "UUID.v4",       mono (t_fun [t_unit] t_string);
  "UUID.v7",       mono (t_fun [t_unit] t_string);
  "UUID.validate", mono (t_fun [t_string] t_string);
  "IsUuid",        mono t_string;
  "uuidV4Codec",   mono t_string;
  "uuidV7Codec",   mono t_string;

  (* ── ID generation ───────────────────────────────────────────────────── *)
  "generateId",          mono t_string;
  "generatePrefixedId",  mono (t_fun [t_string] t_string);
  "newId",               mono t_string;

  (* ── Env ─────────────────────────────────────────────────────────────── *)
  "env",       mono (t_fun [t_string] (t_maybe t_string));
  "envInt",    mono (t_fun [t_string; t_int] t_int);
  "envString", mono (t_fun [t_string; t_string] t_string);
  (* requireEnv: read an env var as a String, failing at startup if unset.  The
     String-returning counterpart to `env` (which returns Maybe), for places that
     need a value directly, e.g. `anthropic (requireEnv "ANTHROPIC_API_KEY") model`. *)
  "requireEnv", mono (t_fun [t_string] t_string);

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
  (* JwtToken and JwtSecret are nominal newtypes wrapping String. *)
  "JwtToken",  mono (t_fun [t_string] t_jwt_token);
  "JwtSecret", mono (t_fun [t_string] t_jwt_secret);
  (* JWT.sign: takes any claims value (polymorphic) and a JwtSecret, returns JwtToken. *)
  "JWT.sign",   { vars = _r1_a; mono = t_fun [_a; t_jwt_secret] t_jwt_token };
  (* JWT.verify: takes a JwtToken and JwtSecret, returns claims (polymorphic). *)
  "JWT.verify", { vars = _r1_a; mono = t_fun [t_jwt_token; t_jwt_secret] _a };
  (* JWT.decode: takes a JwtToken, returns claims without checking signature. *)
  "JWT.decode", { vars = _r1_a; mono = t_fun [t_jwt_token] _a };

  (* ── Queue / Tesl infrastructure ─────────────────────────────────────── *)
  (* requeue: accepts any dead-job value, returns the declared return type freely.
     Using _r2_ab so the return type _b is independent of the input type _a. *)
  "requeue",        { vars = _r2_ab; mono = t_fun [_a] _b };
  (* deadJobs: accepts any queue, returns List of dead jobs (different type than queue).
     Using _r2_ab so the element type _b is independent of the queue type _a. *)
  "deadJobs",       { vars = _r2_ab; mono = t_fun [_a] (t_list _b) };
  "pendingJobCount",{ vars = _r1_a; mono = t_fun [_a] t_int };
  "drainQueue",     { vars = _r1_a; mono = t_fun [_a] t_unit };
  "processNextJob", { vars = _r1_a; mono = t_fun [_a] _a };
  "processNextDeadJob", { vars = _r1_a; mono = t_fun [_a] _a };

  (* ── Telemetry ───────────────────────────────────────────────────────── *)
  "initTelemetry", mono t_unit;
  "telemetry",     mono (t_fun [t_string] t_unit);

  (* ── EmailBody ADT ───────────────────────────────────────────────────── *)
  "TextBody", mono (t_fun [t_string] (TCon "EmailBody"));
  "HtmlBody", mono (t_fun [t_string] (TCon "EmailBody"));
  "RichBody", mono (t_fun [t_string; t_string] (TCon "EmailBody"));

  (* ── Misc ────────────────────────────────────────────────────────────── *)
  "check",   { vars = _r1_a; mono = t_fun [t_fun [_a] _a; _a] _a };
  "identity",{ vars = _r1_a; mono = t_fun [_a] _a };
  "const",   { vars = _r2_ab; mono = t_fun [_a; _b] _a };
  "print",   { vars = _r1_a; mono = t_fun [_a] t_unit };
]

(** Build an initial type environment from the stdlib list. *)
let make_stdlib_env () : (string * scheme) list =
  stdlib_env

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
  ( "Tesl.List",
    [ "IsSorted";
      "List.isEmpty"; "List.length"; "List.head"; "List.tail"; "List.last"; "List.nth";
      "List.map"; "List.filter"; "List.filterCheck"; "List.allCheck"; "List.mapCheck";
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
      "Set.filterCheck"; "Set.allCheck"; "Set.mapCheck"; "Set.delete" ] );
  ( "Tesl.Tuple",
    [ "Tuple2"; "Tuple3";
      "Tuple2.first"; "Tuple2.second";
      "Tuple3.first"; "Tuple3.second"; "Tuple3.third" ] );
  ( "Tesl.Time",
    [ "PosixMillis"; "nowMillis"; "time"; "formatTime"; "durationMs";
      "addMs"; "subtractMs"; "diffMs";
      "Time.posixToSeconds"; "Time.secondsToPosix"; "Time.millisToSeconds" ] );
  ( "Tesl.Random",
    [ "randomInt"; "randomFloat"; "random" ] );
  ( "Tesl.UUID",
    [ "IsUuid"; "uuid"; "UUID.v4"; "UUID.v7"; "UUID.validate";
      "uuidV4Codec"; "uuidV7Codec" ] );
  ( "Tesl.Env",
    [ "env"; "envInt"; "envString"; "requireEnv" ] );
  ( "Tesl.Json",
    [ "stringCodec"; "intCodec"; "boolCodec"; "floatCodec"; "posixMillisCodec";
      "listCodec"; "dictCodec"; "setCodec" ] );
  ( "Tesl.ApiTest",
    [ "HttpResponse"; "JsonValue"; "JsonNull"; "SseStream";
      "statusOk"; "statusClientError"; "statusServerError";
      "jsonInt"; "jsonString"; "jsonBool"; "jsonArray"; "jsonObject"; "jsonLength";
      "isNull"; "isNotNull"; "includesWhere"; "excludesWhere";
      "hasLength"; "isEmpty"; "isNotEmpty"; "arrayAt"; "hasField"; "fieldAt"; "bodyField";
      "jsonContains"; "subscribe"; "collect";
      "JobResult"; "JobOk"; "JobFailed";
      "processNextJob"; "processNextDeadJob"; "drainQueue"; "pendingJobCount";
      "expectJobOk"; "expectJobFailed" ] );
  ( "Tesl.JWT",
    [ "jwt"; "JwtToken"; "JwtSecret"; "JWT.sign"; "JWT.verify"; "JWT.decode" ] );
  ( "Tesl.Cache",
    [ "cache"; "Cache.get"; "Cache.set"; "Cache.delete"; "Cache.invalidate";
      (* config-block type (typed config block) *)
      "Cache" ] );
  ( "Tesl.Email",
    [ "email"; "EmailBody"; "TextBody"; "HtmlBody"; "RichBody";
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
      "HttpClient.get"; "HttpClient.post"; "HttpClient.put"; "HttpClient.delete" ] );
  ( "Tesl.Agent",
    [ "aiProvider"; "Agent"; "LlmProvider"; "AgentReply"; "AgentReply?"; "Tool"; "ToolStep";
      "mockProvider"; "ask";
      "mockToolProvider"; "toolUseStep"; "textStep";
      "anthropic"; "openai"; "mistral"; "local";
      "tool"; "asTool";
      "askReply"; "askWith"; "replyText"; "replyTokens"; "replyToolCalls";
      "decodeAs"; "askFor";
      "Conversation"; "Conversation?"; "ConversationTurn"; "ConversationTurn?";
      "newConversation"; "conversationFrom"; "converse"; "converseStreaming"; "turnReply";
      "turnConversation"; "conversationJson"; "conversationLength"; "agentRun" ] );
  (* Tesl.Http, Tesl.DB, Tesl.Bool, Tesl.Uuid, Tesl.Crypto, Tesl.Map, Tesl.Logging,
     Tesl.Queue, Tesl.Channel, Tesl.Sse —
     internal modules; imports validated loosely (unknown names accepted)
     Note: Tesl.UUID (uppercase) now has a full export list above. *)
]

(** Look up the known exports for a Tesl stdlib module.
    Returns `None` when the module has no registered export list (unknown module
    or internal module), in which case all import names are accepted. *)
let tesl_module_export_set (module_name : string) : string list option =
  List.assoc_opt module_name tesl_module_exports

(** Complete set of valid Tesl.* stdlib module names (including internal modules
    that have runtime files but no registered export list).
    Used to reject `import Tesl.Unknown` with a compile-time error. *)
let tesl_known_module_names : string list = [
  "Tesl.Prelude"; "Tesl.String"; "Tesl.Int"; "Tesl.Float"; "Tesl.Bool";
  "Tesl.List"; "Tesl.ListPrim"; "Tesl.Dict"; "Tesl.Maybe"; "Tesl.Either"; "Tesl.EitherPrim"; "Tesl.Result";
  "Tesl.Http"; "Tesl.HttpClient"; "Tesl.Json"; "Tesl.DB"; "Tesl.Time"; "Tesl.Random";
  "Tesl.Uuid"; "Tesl.UUID"; "Tesl.Crypto"; "Tesl.Set"; "Tesl.Map"; "Tesl.Env";
  "Tesl.Telemetry"; "Tesl.Cli"; "Tesl.ApiTest"; "Tesl.Tuple"; "Tesl.Id";
  "Tesl.Queue"; "Tesl.Channel"; "Tesl.Sql"; "Tesl.Sse"; "Tesl.Logging";
  "Tesl.JWT"; "Tesl.Cache"; "Tesl.Email"; "Tesl.Database"; "Tesl.SSE"; "Tesl.App"; "Tesl.Agent";
]

(** Returns [true] when [name] is a known Tesl.* stdlib module. *)
let is_known_tesl_module (name : string) : bool =
  List.mem name tesl_known_module_names
