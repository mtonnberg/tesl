(** GDP Proof Checker (Phase 3).

    Validates:
    1. Parameter proof subjects — every name in `x ::: P x` must be a param
    2. Return proof validation — `ok x ::: P x` must match declared return spec
    3. Proof ownership — only check/auth/establish can construct proofs with ok :::
    4. Capability checker — requires [A] must be declared; implies closure checked *)

open Ast
open Location

(* ── Proof error type ─────────────────────────────────────────────────────── *)

type proof_error = {
  loc     : loc;
  message : string;
}

let fmt_proof_error (e : proof_error) : string =
  Printf.sprintf "%s:%d:%d: proof error: %s"
    e.loc.file (e.loc.start.line + 1) (e.loc.start.col + 1) e.message

(* ── Proof expression utilities ──────────────────────────────────────────── *)

(** Collect all subject names (lowercase identifiers) used in a proof expression. *)
let rec proof_subjects (p : proof_expr) : string list =
  match p with
  | PredApp { args; _ } ->
    (* Filter: lowercase identifiers are subjects; uppercase are predicates *)
    List.filter (fun s ->
      String.length s > 0 && s.[0] >= 'a' && s.[0] <= 'z' && not (String.contains s '.')
    ) args
  | PredAnd { left; right; _ } ->
    proof_subjects left @ proof_subjects right

(** Flatten a proof conjunction into a list of atomic predicates. *)
let rec flatten_proof (p : proof_expr) : proof_expr list =
  match p with
  | PredAnd { left; right; _ } -> flatten_proof left @ flatten_proof right
  | other -> [other]

(** Pretty-print a proof expression for error messages. *)
let rec pp_proof (p : proof_expr) : string =
  match p with
  | PredApp { pred; args = []; _ } -> pred
  | PredApp { pred; args; _ } ->
    Printf.sprintf "%s %s" pred (String.concat " " args)
  | PredAnd { left; right; _ } ->
    Printf.sprintf "%s && %s" (pp_proof left) (pp_proof right)

(** Normalise a proof conjunction to a canonical form for structural comparison.
    Flattens the conjunction, sorts atoms lexicographically by their string key,
    then rebuilds a left-associative tree. This makes `A && B` and `B && A`
    compare equal, fixing BUG-03 where conjunction order in `ok` was strictly
    positional. *)
let normalize_conj (p : proof_expr) : string =
  let atoms = flatten_proof p in
  let sorted = List.sort_uniq (fun a b -> String.compare (pp_proof a) (pp_proof b)) atoms in
  String.concat " && " (List.map pp_proof sorted)

(* ── Capability implication expansion ───────────────────────────────────── *)

(** Build a transitive capability implication map from capability declarations. *)
let build_cap_map (decls : top_decl list) : (string * string list) list =
  List.filter_map (function
    | DCapability c -> Some (c.name, c.implies)
    (* Cache declarations implicitly define a "cache <Name>" capability *)
    | DCache (c : Ast.cache_form) -> Some ("cache " ^ c.name, [])
    (* Email declarations implicitly define an "email" capability *)
    | DEmail _ -> Some ("email", [])
    | _ -> None
  ) decls

let module_name_to_kebab name =
  let buf = Buffer.create (String.length name + 8) in
  String.iteri (fun i ch ->
    if ch = '.' then Buffer.add_char buf '-'
    else if ch >= 'A' && ch <= 'Z' then begin
      if i > 0 then Buffer.add_char buf '-';
      Buffer.add_char buf (Char.lowercase_ascii ch)
    end else
      Buffer.add_char buf ch
  ) name;
  Buffer.contents buf

let resolve_local_import_path source_file module_name =
  let dir = Filename.dirname source_file in
  let kebab_path = Filename.concat dir (module_name_to_kebab module_name ^ ".tesl") in
  if Sys.file_exists kebab_path then kebab_path
  else Filename.concat dir (module_name ^ ".tesl")

(** Capabilities exported by each Tesl stdlib module, with their implication chains. *)
let stdlib_capabilities : (string * (string * string list) list) list = [
  "Tesl.DB",         [("dbRead", []); ("dbWrite", ["dbRead"])];
  "Tesl.Time",       [("time", [])];
  "Tesl.Random",     [("random", [])];
  "Tesl.Queue",      [("queueRead", []); ("queueWrite", ["queueRead"]); ("pubsub", [])];
  "Tesl.UUID",       [("uuid", [])];
  "Tesl.JWT",        [("jwt", [])];
  "Tesl.HttpClient", [("httpClient", [])];
]

let load_imported_cap_map (m : module_form) : (string * string list) list =
  List.concat_map (fun (imp : import_decl) ->
    let requested = match imp.names with
      | ImportAll -> None
      | ImportExposing names -> Some names
    in
    match List.assoc_opt imp.module_name stdlib_capabilities with
    | Some caps ->
      List.filter (fun (name, _) ->
        match requested with
        | Some names -> List.mem name names
        | None -> false
      ) caps
    | None ->
      let is_tesl_module name =
        String.length name >= 5 && String.sub name 0 5 = "Tesl."
      in
      if is_tesl_module imp.module_name then []
      else
        let path = resolve_local_import_path m.source_file imp.module_name in
        if not (Sys.file_exists path) then []
        else
          let source = In_channel.with_open_text path In_channel.input_all in
          match Parser.parse_module path source with
          | Err _ -> []
          | Ok imported ->
            List.filter_map (function
              | DCapability c ->
                let include_plain = match requested with
                  | Some names -> List.mem c.name names
                  | None -> false
                in
                if include_plain then Some (c.name, c.implies) else None
              | _ -> None
            ) imported.decls
  ) m.imports

(** Expand a set of capabilities via their transitive implications. *)
let expand_caps (initial : string list) (cap_map : (string * string list) list) : string list =
  let result = Hashtbl.create 16 in
  let rec expand name =
    if not (Hashtbl.mem result name) then begin
      Hashtbl.replace result name ();
      match List.assoc_opt name cap_map with
      | Some implied -> List.iter expand implied
      | None -> ()
    end
  in
  List.iter expand initial;
  Hashtbl.fold (fun k () acc -> k :: acc) result []

(* ── Parameter proof subject validation ─────────────────────────────────── *)

(** Validate that all proof subjects in parameter annotations refer to valid names.
    Valid names = parameter names + the return binding name (if present). *)
let validate_param_proof_subjects (fd : func_decl) : proof_error list =
  let errors = ref [] in
  (* Collect valid subject names: all parameter names *)
  let param_names = List.map (fun (b : binding) -> b.name) fd.params in
  (* Also include the return binding name if there is one *)
  let return_binding = match fd.return_spec with
    | RetAttached { binding = b; _ } -> [b.name]
    | _ -> []
  in
  let valid_names = param_names @ return_binding in

  (* Check each parameter's proof annotation *)
  List.iter (fun (b : binding) ->
    match b.proof_ann with
    | None -> ()
    | Some proof ->
      let subjects = proof_subjects proof in
      List.iter (fun subj ->
        if not (List.mem subj valid_names) then
          errors := {
            loc = b.loc;
            message = Printf.sprintf
              "proof subject '%s' in '%s ::: %s' is not a parameter name (valid: %s)"
              subj b.name (pp_proof proof)
              (String.concat ", " valid_names)
          } :: !errors
      ) subjects
  ) fd.params;

  (* Check return spec proof subjects *)
  (match fd.return_spec with
   | RetAttached { binding = b; _ } ->
     (match b.proof_ann with
      | None -> ()
      | Some proof ->
        let subjects = proof_subjects proof in
        List.iter (fun subj ->
          if not (List.mem subj valid_names) then
            errors := {
              loc = b.loc;
              message = Printf.sprintf
                "return proof subject '%s' is not a parameter name (valid: %s)"
                subj (String.concat ", " valid_names)
            } :: !errors
        ) subjects)
   | _ -> ());

  List.rev !errors

(* ── Proof ownership validation ─────────────────────────────────────────── *)

(** Collect proof predicates that this module "owns" (declared via check/establish/auth). *)
let preds_of_proof_opt (p_opt : proof_expr option) : string list =
  match p_opt with
  | None -> []
  | Some p -> List.filter_map (function
      | PredApp { pred; _ } when pred <> "" -> Some pred
      | _ -> None
    ) (flatten_proof p)

(* Inline predicate name extraction without forward reference *)
let rec preds_of_proof_expr (p : proof_expr) : string list =
  match p with
  | PredApp { pred; _ } -> if pred = "" then [] else [pred]
  | PredAnd { left; right; _ } -> preds_of_proof_expr left @ preds_of_proof_expr right

let rec preds_of_return_spec (spec : return_spec) : string list =
  match spec with
  | RetAttached { binding = b; _ } -> preds_of_proof_opt b.proof_ann
  | RetNamedPack { entity_proof; other_proof; _ } ->
    preds_of_proof_opt entity_proof @ preds_of_proof_opt other_proof
  | RetForAll { proof; _ } | RetMaybeForAll { proof; _ }
  | RetSetForAll { proof; _ } | RetMaybeSetForAll { proof; _ } -> preds_of_proof_expr proof
  | RetForAllDictValues { proof; _ } | RetForAllDictKeys { proof; _ } -> preds_of_proof_expr proof
  | RetMaybeAttached { binding = b; _ } -> preds_of_proof_opt b.proof_ann
  | RetExists { binding = b; body; _ } ->
    preds_of_proof_opt b.proof_ann @ preds_of_return_spec body
  | RetPlain { ty; _ } ->
    (* For establish/check functions returning Fact (P args) or Maybe (Fact (P args)),
       extract the predicate name so it's registered as owned. *)
    (match ty with
     | TApp { head = TName { name = "Fact"; _ }; arg; _ } ->
       (match arg with TApp { head = TName { name = pred; _ }; _ } | TName { name = pred; _ } ->
         if String.length pred > 0 && pred.[0] >= 'A' && pred.[0] <= 'Z' then [pred] else []
       | _ -> [])
     | TApp { head = TName { name = "Maybe"; _ };
              arg = TApp { head = TName { name = "Fact"; _ }; arg = inner; _ }; _ } ->
       (match inner with TApp { head = TName { name = pred; _ }; _ } | TName { name = pred; _ } ->
         if String.length pred > 0 && pred.[0] >= 'A' && pred.[0] <= 'Z' then [pred] else []
       | _ -> [])
     | _ -> [])

(** Collect predicate names declared by check/auth/establish functions in this module. *)
let collect_owned_predicates (decls : top_decl list) : string list =
  List.filter_map (function
    | DFact ff -> Some ff.name
    | _ -> None
  ) decls

(** Collect uppercase predicate-style names explicitly imported from any module.
    E.g., `import Tesl.String exposing [IsTrimmed, String.length]` contributes `IsTrimmed`. *)
let collect_imported_predicate_names (m : module_form) : string list =
  List.concat_map (fun (imp : import_decl) ->
    match imp.names with
    | ImportAll -> []
    | ImportExposing names ->
      List.filter (fun name ->
        String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z' &&
        not (String.contains name '.')  (* exclude Module.Fn qualified names *)
      ) names
  ) m.imports

let is_lowercase_subject_name (name : string) : bool =
  String.length name > 0 &&
  let c = name.[0] in
  (c >= 'a' && c <= 'z') || c = '_'

let rec proof_uses_existing_witness (p : proof_expr) : bool =
  match p with
  | PredApp { pred; args = []; _ } ->
    is_lowercase_subject_name pred
  | PredApp { pred = ("detachFact" | "detachAllFact"); args; _ } ->
    args <> [] && List.for_all is_lowercase_subject_name args
  | PredApp { pred = ("introAnd" | "andLeft" | "andRight"); args; _ } ->
    (* Proof-combining stdlib functions — allowed in fn context because they
       only manipulate existing proofs, not create proofs from scratch *)
    args <> [] && List.for_all is_lowercase_subject_name args
  | PredApp { pred; args; _ }
    when is_lowercase_subject_name pred && args <> [] &&
         List.for_all is_lowercase_subject_name args ->
    (* An establish function call used as inline proof: `x ::: positive n` or `x ::: nonzero n` —
       allowed in fn context since it calls a proof-producing establish function. *)
    true
  | PredAnd { left; right; _ } ->
    proof_uses_existing_witness left && proof_uses_existing_witness right
  | _ -> false

(** Check that `ok expr ::: proof` is only used in check/establish/auth functions,
    unless the proof expression is merely reattaching an existing lowercase fact witness. *)
let string_of_func_kind = function
  | FnKind -> "fn"
  | CheckKind -> "check"
  | AuthKind -> "auth"
  | EstablishKind -> "establish"
  | HandlerKind -> "handler"
  | WorkerKind -> "worker"
  | DeadWorkerKind -> "deadworker"
  | MainKind -> "main"

let validate_no_ok_in_fn (body : expr) (kind : func_kind) (fd_loc : loc)
    : proof_error list =
  match kind with
  | CheckKind | AuthKind -> []  (* ok/fail allowed in check/auth *)
  | EstablishKind ->
    (* In establish, ok, fail, and check/auth calls are forbidden.
       establish must be total: it may not call functions that can fail at runtime.
       check and auth functions can fail (they use HTTP `fail`), so calling them
       inside establish would silently make establish non-total. *)
    let rec is_check_call = function
      | EApp { fn; _ } -> is_check_call fn
      | EVar { name = "check"; _ } -> true
      | _ -> false
    in
    let rec walk (e : Ast.expr) =
      match e with
      | EOk { loc; _ } ->
        [{ loc; message = "establish functions must return proof constructors directly (e.g. `ValidPort port`), not use 'ok' syntax" }]
      | EFail { loc; _ } ->
        [{ loc; message = "establish functions cannot use 'fail' — return 'Nothing' for conditional proofs, or use a 'check' function for HTTP-failing validation" }]
      | EApp { loc; _ } when is_check_call e ->
        [{ loc; message = "establish functions cannot call 'check' (or 'auth') functions — \
establish must be total and check/auth can fail with HTTP errors at runtime. \
Use an 'if' expression and return 'Nothing' for the failure case instead." }]
      (* Explicit leaves / DELIBERATE non-descents — these arms are semantically
         load-bearing and must NOT be routed through the shared visitor, because
         the canonical "all children" traversal would search MORE subtrees for a
         forbidden `ok`/`fail`/`check` than this establish-totality check
         intends.  Each deliberate omission below is preserved exactly:
           - EConstructor: does NOT descend into its args (the original arm
             returned []).  A proof constructor's arguments are not a control
             path the establish-totality rule inspects.
           - ECase: walks the scrutinee and each arm BODY but NOT the arm guards
             (guards are pure boolean tests, not establish return paths).
           - The cache forms and the email forms return [] without descending.
           - EStartWorkers returns []. *)
      | ELit _ | EVar _ | EConstructor _ -> []
      | ECase { scrut; arms; _ } ->
        walk scrut @ List.concat_map (fun (a : Ast.case_arm) -> walk a.body) arms
      | EStartWorkers _ -> []
      | ECacheGet _ | ECacheDelete _ | ECacheInvalidate _ -> []
      | ESendEmail _ | EStartEmailWorker _ -> []
      (* ECacheSet is kept EXPLICIT: the original arm descended ONLY into the
         [value] child, not [key]/[ttl].  fold_children would descend into all
         three, so we preserve the original single-child descent to keep the
         analysed set (and thus the verdict) byte-identical. *)
      | ECacheSet { value; _ } -> walk value
      (* Purely-MECHANICAL full descent into every immediate child — migrated
         onto the shared {!Ast_visitor.fold_children} (Wave-2 visitor
         consolidation).  Covers EField (into obj), EApp, EBinop, EUnop, EIf,
         ELet, ELetProof, ERecord, EList, ETelemetry, EEnqueue, EPublish,
         EWithDatabase/EWithCapabilities/EWithTransaction, EServe, ELambda.
         For every one of these the original arm already descended into EXACTLY
         the set of children fold_children visits, in the SAME left-to-right
         order, so the concatenated error order is preserved.  A new
         full-descent {!Ast.expr} variant is now traversed automatically here. *)
      | _ -> Ast_visitor.fold_children (fun acc c -> acc @ walk c) [] e
    in
    ignore fd_loc;
    walk body
  | _ ->
    (* Walk the body looking for EOk *)
    let rec walk (e : Ast.expr) =
      match e with
      | EOk { proof; _ } when proof_uses_existing_witness proof ->
        []
      | EOk { loc; _ } ->
        [{ loc; message = Printf.sprintf
             "ok ::: proof construction is not allowed in `%s`; use a check, auth, or establish function"
             (string_of_func_kind kind) }]
      (* Explicit leaves / DELIBERATE non-descents — preserved exactly as the
         EOk-search rule intends (EConstructor does NOT walk its args; ECase
         walks bodies but NOT guards; cache/email forms and EStartWorkers do not
         descend).  Routing these through the shared visitor would search more
         subtrees and could change the verdict, so they stay explicit. *)
      | ELit _ | EVar _ | EConstructor _ | EFail _ -> []
      | ECase { scrut; arms; _ } ->
        walk scrut @ List.concat_map (fun (a : Ast.case_arm) -> walk a.body) arms
      | EStartWorkers _ -> []
      | ECacheGet _ | ECacheDelete _ | ECacheInvalidate _ -> []
      | ESendEmail _ | EStartEmailWorker _ -> []
      (* ECacheSet stays EXPLICIT: original descended ONLY into [value]. *)
      | ECacheSet { value; _ } -> walk value
      (* Purely-MECHANICAL full descent — migrated onto {!Ast_visitor.fold_children}.
         Covers EField (into obj), EApp, EBinop, EUnop, EIf, ELet, ELetProof,
         ERecord, EList, ETelemetry, EEnqueue, EPublish, EWithDatabase/
         EWithCapabilities/EWithTransaction, EServe, ELambda — each of which
         already descended into EXACTLY fold_children's children, in the same
         left-to-right order, so error order is preserved. *)
      | _ -> Ast_visitor.fold_children (fun acc c -> acc @ walk c) [] e
    in
    ignore fd_loc;
    walk body

(* ── Check function return validation ────────────────────────────────────── *)

(** Extract the name from a value expression, if it's a simple variable. *)
let value_name_of_expr = function
  | EVar { name; _ } -> Some name
  | _ -> None

(** Check that a proof has no dotted-path arguments (e.g. "request.cookies.user").
    Returns errors for any such argument. *)
let check_proof_no_dotted_path (proof : proof_expr) (loc : loc) : proof_error list =
  let rec check = function
    | PredApp { args; _ } ->
      List.filter_map (fun arg ->
        if String.contains arg '.' then
          Some { loc; message = Printf.sprintf
            "proof subject '%s' is not a valid GDP subject — dotted paths like 'request.cookies.user' \
             are not trackable; use a local variable instead" arg }
        else None
      ) args
    | PredAnd { left; right; _ } -> check left @ check right
  in
  check proof

(* ── ForAll proof tracking for ok-annotation validation ──────────────────── *)

(** Strip a single layer of outer parentheses and trim whitespace.
    E.g. "(Active && Valid)" → "Active && Valid". *)
let strip_outer_parens (s : string) : string =
  let s = String.trim s in
  if String.length s >= 2 && s.[0] = '(' && s.[String.length s - 1] = ')' then
    String.trim (String.sub s 1 (String.length s - 2))
  else s

(** Remove all args equal to binder_name from a proof expression.
    E.g. [Active x] with binder "x" → [Active] (args=[]). *)
let rec strip_binder_from_proof (binder : string) (p : proof_expr) : proof_expr =
  match p with
  | PredApp { pred; args; loc } ->
    PredApp { pred; args = List.filter (fun a -> a <> binder) args; loc }
  | PredAnd { left; right; loc } ->
    PredAnd {
      left  = strip_binder_from_proof binder left;
      right = strip_binder_from_proof binder right;
      loc;
    }

(** Look up the inner proof (binder-stripped) for a named check function.
    E.g. checkActive(x: Item) -> x: Item ::: Active x → Some (Active). *)
let inner_proof_of_named_fn (all_funcs : func_decl list) (fn_name : string) : proof_expr option =
  match List.find_opt (fun (fd : func_decl) -> fd.name = fn_name) all_funcs with
  | Some { return_spec = RetAttached { binding = { proof_ann = Some proof; name = binder; _ }; _ }; _ } ->
    Some (strip_binder_from_proof binder proof)
  | _ -> None

(** Flatten a left-associative EApp into (base_fn, args list). *)
let rec flatten_app_pf acc = function
  | EApp { fn; arg; _ } -> flatten_app_pf (arg :: acc) fn
  | other -> (other, acc)

(** Get the combined inner proof for a check-chain expression (EVar or EBinop &&). *)
let rec check_chain_proof (all_funcs : func_decl list) (e : expr) : proof_expr option =
  match e with
  | EVar { name; _ } -> inner_proof_of_named_fn all_funcs name
  | EBinop { op = BAnd; left; right; loc } ->
    (match check_chain_proof all_funcs left, check_chain_proof all_funcs right with
     | Some lp, Some rp -> Some (PredAnd { left = lp; right = rp; loc })
     | Some p, None | None, Some p -> Some p
     | None, None -> None)
  | _ -> None

(** Build a (binding_name → pp'd inner proof) environment for the function body.
    Tracks proofs established by filterCheck / allCheck calls on let bindings. *)
let build_forall_binding_env (all_funcs : func_decl list) (fd : func_decl) : (string * string) list =
  let init_env = List.filter_map (fun (b : binding) ->
    match b.proof_ann with
    | Some (PredApp { pred = "ForAll"; args = inner_str :: _; _ }) ->
      Some (b.name, strip_outer_parens inner_str)
    | _ -> None
  ) fd.params in
  let env = ref init_env in
  (* Check if an expression's base function is a filterCheck-family call.
     Handles both qualified EVar ("List.filterCheck") and field-access
     (EField { obj = EConstructor "List"; field = "filterCheck" }) forms. *)
  let is_filter_check_call base_fn = match base_fn with
    | EVar { name = ("List.filterCheck" | "Set.filterCheck"
                    | "List.allCheck"   | "Set.allCheck"
                    | "List.emptyForAll"); _ } -> true
    | EField { obj = EConstructor { name = ("List" | "Set"); _ };
               field = ("filterCheck" | "allCheck" | "emptyForAll"); _ } -> true
    | _ -> false
  in
  let rec walk = function
    | ELet { name; value; body; _ } ->
      let base_fn, args = flatten_app_pf [] value in
      (match args with
       | [check_fn_expr; input_expr] when is_filter_check_call base_fn ->
         let check_proof_opt = check_chain_proof all_funcs check_fn_expr in
         let input_proof_opt = match input_expr with
           | EVar { name = input_name; _ } -> List.assoc_opt input_name !env
           | _ -> None
         in
         (match check_proof_opt with
          | Some p ->
            let proof_str = match input_proof_opt with
              | Some existing -> existing ^ " && " ^ pp_proof p
              | None -> pp_proof p
            in
            env := (name, proof_str) :: !env
          | None -> ())
       | _ -> ());
      walk body
    | ELetProof { body; _ } -> walk body
    | EIf { then_; else_; _ } -> walk then_; walk else_
    | ECase { arms; _ } ->
      List.iter (fun (a : Ast.case_arm) -> walk a.body) arms
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> walk body
    | _ -> ()
  in
  walk fd.body;
  !env

(** Validate a check/auth function's `ok x ::: P x` body against declared return spec.
    Also validates fn functions with binding return type.
    [all_funcs] is used to look up check function proofs for ForAll binding tracking. *)
let validate_check_return (all_funcs : func_decl list) (fd : func_decl) : proof_error list =
  match fd.kind with
  | CheckKind | AuthKind ->
    let errors = ref [] in
    let param_names = List.map (fun (b : binding) -> b.name) fd.params in
    (* Pre-compute ForAll binding proof env for this function body (Bug 2). *)
    let binding_env = build_forall_binding_env all_funcs fd in
    (* Walk body looking for EOk expressions *)
    let proof_var_env : (string * proof_expr) list ref = ref [] in
    let rec expand_proof_vars (proof : proof_expr) : proof_expr =
      match proof with
      | PredApp { pred; args = []; loc = _ } when
          String.length pred > 0 && pred.[0] >= 'a' && pred.[0] <= 'z' ->
        (match List.assoc_opt pred !proof_var_env with
         | Some expanded -> expanded
         | None -> proof)
      | PredAnd { left; right; loc } ->
        PredAnd { left = expand_proof_vars left;
                  right = expand_proof_vars right; loc }
      | _ -> proof
    in
    let subst_in_proof (from_name : string) (to_name : string) (proof : proof_expr) : proof_expr =
      let rec go = function
        | PredApp { pred; args; loc } ->
          PredApp { pred; args = List.map (fun a -> if a = from_name then to_name else a) args; loc }
        | PredAnd { left; right; loc } ->
          PredAnd { left = go left; right = go right; loc }
      in go proof
    in
    ignore param_names; ignore binding_env;
    let rec validate_ok_expr (e : Ast.expr) =
      match e with
      | EOk { value; proof; loc } ->
        (* Check for dotted paths in proof subjects *)
        errors := check_proof_no_dotted_path proof loc @ !errors;
        (match fd.return_spec with
         | RetAttached { binding = b; _ } ->
           (match fd.kind with
            | CheckKind ->
              (* Check functions: ok value must be either:
                 (a) a simple identifier matching the declared return binding name, OR
                 (b) a constructor application `Ctor arg` (wraps a type; GDP subject
                     is the return binding name, handled by a let-binding in the emitter).
                 Arbitrary expressions (arithmetic, literals, function calls) are rejected. *)
              let rec ok_value_is_ctor_app = function
                | EConstructor _ -> true
                | EApp { fn = EConstructor _; _ } -> true
                | EApp { fn = (EApp _ as inner); _ } -> ok_value_is_ctor_app inner
                | _ -> false
              in
              let ok_name = value_name_of_expr value in
              (match ok_name with
               | Some n when n <> b.name ->
                 errors := { loc; message = Printf.sprintf
                   "ok expression returns `%s` but the declared return binding name is `%s`; \
either use `let %s = ... in ok %s ::: ...` to bind the result to `%s`, \
or change the return spec to `-> %s: <Type> ::: ...`" n b.name b.name b.name b.name n } :: !errors
               | None when not (ok_value_is_ctor_app value) ->
                 errors := { loc; message = "ok expression returns a non-identifier and is not \
a constructor application; the ok expression must return the declared binding name or wrap it \
in a constructor: `ok BindingName ::: ...` or `ok (Ctor arg) ::: Proof bindingName`" } :: !errors
               | _ -> ());
              (* Proof must match declared (conjunction-normalised: order-insensitive). *)
              (match b.proof_ann with
               | None -> ()
               | Some expected ->
                 let expanded = expand_proof_vars proof in
                 let ok_name = match value with EVar { name; _ } -> Some name | _ -> None in
                 let normalized = match ok_name with
                   | Some n when n <> b.name -> subst_in_proof n b.name expanded
                   | _ -> expanded
                 in
                 if normalize_conj normalized <> normalize_conj expected then
                   errors := { loc; message = Printf.sprintf
                     "ok proof does not match declared return spec: got `%s`, expected `%s`"
                     (pp_proof normalized) (pp_proof expected) } :: !errors)
            | AuthKind ->
              (* Auth functions PRODUCE the proof subject (the authenticated identity);
                 they do not validate an input.  So, unlike `check` (LANGUAGE-SPEC §"ok
                 binding name requirement in check functions", which is scoped to check),
                 the ok value may be any expression auth vouches for — an identifier, a
                 constructor application, or a literal (e.g. a fixed dev identity
                 `ok "admin"`).  Only a bare anonymous record literal is rejected, since
                 it bypasses record-field-proof checking; use a named constructor. *)
              let ok_name = value_name_of_expr value in
              (match ok_name with
               | None ->
                 (match value with
                  | ERecord _ ->
                    errors := { loc; message = Printf.sprintf
                      "ok expression in auth function returns an anonymous record literal; \
use the named constructor instead: `ok %s { ... } ::: ...`" b.name } :: !errors
                  | _ -> ())
               | _ -> ());
              (match b.proof_ann with
               | None -> ()
               | Some expected ->
                 let expanded = expand_proof_vars proof in
                 let ok_name = match value with EVar { name; _ } -> Some name | _ -> None in
                 let normalized = match ok_name with
                   | Some n when n <> b.name -> subst_in_proof n b.name expanded
                   | _ -> expanded
                 in
                 if normalize_conj normalized <> normalize_conj expected then
                   errors := { loc; message = Printf.sprintf
                     "ok proof does not match declared return spec: got `%s`, expected `%s`"
                     (pp_proof normalized) (pp_proof expected) } :: !errors)
            | _ -> ())
         | RetNamedPack _ ->
           (* Auth named-pack: ok value must be a simple identifier *)
           (match value with
            | EVar _ -> ()
            | _ ->
              errors := { loc; message =
                "auth named-pack ok must return a simple identifier (a variable name), \
                 not a literal or expression" } :: !errors);
           (* Auth named-pack: proof subjects must reference the returned value *)
           let returned_name = value_name_of_expr value in
           (match returned_name with
            | Some rn ->
              let proof_args = match proof with
                | PredApp { args; _ } -> args
                | _ -> []
              in
              let bad_args = List.filter (fun arg ->
                String.contains arg '.' ||
                (not (List.mem arg param_names) && arg <> rn &&
                 not (List.exists (fun p -> p = arg) param_names))
              ) proof_args in
              let references_returned = List.exists (fun arg -> arg = rn) proof_args in
              if not references_returned && proof_args <> [] then
                errors := { loc; message =
                  "entity proof subjects must reference the returned value; \
                   all proof subjects should use the identifier being returned" } :: !errors;
              List.iter (fun arg ->
                if String.contains arg '.' then
                  errors := { loc; message = Printf.sprintf
                    "proof subject '%s' is not a valid GDP subject — use a local variable" arg }
                  :: !errors
              ) bad_args
            | None -> ())
         (* ── ForAll / MaybeForAll / SetForAll return spec validation ─────
            Verify ok xs ::: ForAll (inner) matches the declared inner proof.
            The ok proof is parsed as PredApp { pred="ForAll"; args=["(inner)"] }. *)
         | RetForAll { proof = expected_inner; _ }
         | RetMaybeForAll { proof = expected_inner; _ }
         | RetSetForAll { proof = expected_inner; _ }
         | RetMaybeSetForAll { proof = expected_inner; _ } ->
           let expected_str = pp_proof expected_inner in
           (match proof with
            | PredApp { pred = "ForAll"; args = [inner_arg]; _ } ->
              let actual = strip_outer_parens inner_arg in
              if actual <> expected_str then
                errors := { loc; message = Printf.sprintf
                  "ok proof `ForAll (%s)` does not match declared return `ForAll (%s)`"
                  actual expected_str } :: !errors
              else begin
                (* Bug 2: verify the value binding actually has the claimed proof. *)
                match value_name_of_expr value with
                | None -> ()
                | Some val_name ->
                  (match List.assoc_opt val_name binding_env with
                   | Some tracked when tracked <> actual ->
                     errors := { loc; message = Printf.sprintf
                       "value `%s` has established proof `ForAll (%s)` but `ok` claims \
                         `ForAll (%s)`; ensure all conjuncts are established by the \
                         check function chain"
                       val_name tracked actual } :: !errors
                   | _ -> ())
              end
            | _ ->
              errors := { loc; message = Printf.sprintf
                "ok proof `%s` does not match declared ForAll return; expected `ForAll (%s)`"
                (pp_proof proof) expected_str } :: !errors)
         | RetForAllDictValues { proof = expected_inner; _ } ->
           let expected_str = pp_proof expected_inner in
           (match proof with
            | PredApp { pred = "ForAllValues"; args = [inner_arg]; _ } ->
              let actual = strip_outer_parens inner_arg in
              if actual <> expected_str then
                errors := { loc; message = Printf.sprintf
                  "ok proof `ForAllValues (%s)` does not match declared return `ForAllValues (%s)`"
                  actual expected_str } :: !errors
            | _ ->
              errors := { loc; message = Printf.sprintf
                "ok proof `%s` does not match declared ForAllValues return; expected `ForAllValues (%s)`"
                (pp_proof proof) expected_str } :: !errors)
         | RetForAllDictKeys { proof = expected_inner; _ } ->
           let expected_str = pp_proof expected_inner in
           (match proof with
            | PredApp { pred = "ForAllKeys"; args = [inner_arg]; _ } ->
              let actual = strip_outer_parens inner_arg in
              if actual <> expected_str then
                errors := { loc; message = Printf.sprintf
                  "ok proof `ForAllKeys (%s)` does not match declared return `ForAllKeys (%s)`"
                  actual expected_str } :: !errors
            | _ ->
              errors := { loc; message = Printf.sprintf
                "ok proof `%s` does not match declared ForAllKeys return; expected `ForAllKeys (%s)`"
                (pp_proof proof) expected_str } :: !errors)
         | RetMaybeAttached { binding = b; _ } ->
           (* Maybe (name: T ::: P): ok proof validation works like RetAttached *)
           (match b.proof_ann with
            | None -> ()
            | Some expected ->
              let expanded = expand_proof_vars proof in
              let ok_name = match value with EVar { name; _ } -> Some name | _ -> None in
              let normalized = match ok_name with
                | Some n when n <> b.name -> subst_in_proof n b.name expanded
                | _ -> expanded
              in
              if pp_proof normalized <> pp_proof expected then
                errors := { loc; message = Printf.sprintf
                  "ok proof does not match declared Maybe return spec: got `%s`, expected `%s`"
                  (pp_proof normalized) (pp_proof expected) } :: !errors)
         | _ -> ());
      | EIf { then_; else_; _ } ->
        validate_ok_expr then_; validate_ok_expr else_
      | ECase { arms; _ } ->
        List.iter (fun (a : Ast.case_arm) -> validate_ok_expr a.body) arms
      | ELet { body; _ } -> validate_ok_expr body
      | ELetProof { value_name; proof_name; value; body; _ } ->
        (* Track the proof carried by the proof variable. *)
        (let check_proof_opt =
          let rec find_check_fn = function
            | EApp { fn = EVar { name = "check"; _ }; arg; _ } -> Some arg
            | EApp { fn; _ } -> find_check_fn fn
            | _ -> None
          in
          match find_check_fn value with
          | Some check_fn_expr ->
            let fn_name, check_args = match flatten_app_pf [] check_fn_expr with
              | EVar { name; _ }, args -> name, args
              | _ -> "", []
            in
            (match List.find_opt (fun (fd2 : func_decl) -> fd2.name = fn_name) all_funcs with
             | Some { return_spec = RetAttached { binding = { proof_ann = Some p; name = binder; _ }; _ }; _ }
             | Some { return_spec = RetMaybeAttached { binding = { proof_ann = Some p; name = binder; _ }; _ }; _ } ->
               let actual_arg = match check_args with
                 | [EVar { name; _ }] -> name
                 | _ -> binder
               in
               let rec subst_proof (pe : proof_expr) : proof_expr = match pe with
                 | PredApp { pred; args; loc } ->
                   PredApp { pred; args = List.map (fun a -> if a = binder || a = actual_arg then value_name else a) args; loc }
                 | PredAnd { left; right; loc } ->
                   PredAnd { left = subst_proof left; right = subst_proof right; loc }
               in
               Some (subst_proof p)
             | _ -> None)
          | None -> None
        in
        (match check_proof_opt with
         | Some p -> proof_var_env := (proof_name, p) :: !proof_var_env
         | None -> ()));
        validate_ok_expr body
      | _ -> ()
    in
    validate_ok_expr fd.body;
    List.rev !errors
  | FnKind ->
    (* For fn functions with RetAttached, the body must return the binding name *)
    (match fd.return_spec with
     | RetAttached { binding = b; _ } ->
       let errors = ref [] in
       (* Find the tail expression and check it returns the binding name *)
       let rec get_tail = function
         | ELet { body; _ } | ELetProof { body; _ } -> get_tail body
         | e -> e
       in
       let tail = get_tail fd.body in
       (match tail with
        | EVar { name; loc } when name <> b.name ->
          errors := { loc; message = Printf.sprintf
            "fn with binding return: body returns `%s` but must return `%s` \
             (the declared binding name)" name b.name } :: !errors
        | _ -> ());
       !errors
     | RetNamedPack { other_proof = Some other_proof_spec; _ } ->
       (* For fn with named-pack return including cargo proof (other_proof),
          check that the body's cargo proof matches the declared other_proof. *)
       let errors = ref [] in
       let param_names = List.map (fun (b : binding) -> b.name) fd.params in
       (* Track proof variables from let (_ ::: p) = check ... bindings *)
       let proof_var_env : (string * proof_expr) list ref = ref [] in
       let rec expand_proof_vars (proof : proof_expr) : proof_expr =
         match proof with
         | PredApp { pred; args = []; loc = _ } when
             String.length pred > 0 && pred.[0] >= 'a' && pred.[0] <= 'z' ->
           (match List.assoc_opt pred !proof_var_env with
            | Some expanded -> expanded
            | None -> proof)
         | PredAnd { left; right; loc } ->
           PredAnd { left = expand_proof_vars left;
                     right = expand_proof_vars right; loc }
         | _ -> proof
       in
       let rec check_body e =
         match e with
         | EOk { proof; loc; _ } ->
           (* Extract the "cargo" proof — the second part of `p && detachFact x` *)
           let cargo_proof = match proof with
             | PredAnd { right; _ } -> Some right
             | PredApp { pred = "detachFact"; _ } -> Some proof  (* only cargo *)
             | _ -> None
           in
           (* Resolve the cargo proof: if it's a proof variable like `p`,
              expand it through proof_var_env to find what it actually proves.
              Then verify it matches the declared other_proof_spec. *)
           let resolved_cargo = match cargo_proof with
             | Some p -> Some (expand_proof_vars p)
             | None -> None
           in
           (match resolved_cargo with
            | None -> ()
            | Some (PredApp { pred = "detachFact"; args = [x_name]; _ }) ->
              (* detachFact case: check subject match *)
              let expected_subjects = match other_proof_spec with
                | PredApp { args; _ } -> args | _ -> []
              in
              let x_subject = if List.mem x_name param_names then Some x_name else None in
              (match x_subject with
               | Some xs ->
                 if expected_subjects <> [xs] && expected_subjects <> [] then
                   errors := { loc; message = Printf.sprintf
                     "cargo proof subject mismatch: `detachFact %s` provides proof with \
                      subject `%s`, but return spec requires `%s`"
                     x_name xs (pp_proof other_proof_spec) }
                   :: !errors
               | None -> ())
            | Some resolved ->
              (* Resolved proof variable or direct proof: compare against other_proof_spec.
                 Flatten both to compare predicate names and subjects. *)
              let rec proof_key p = match p with
                | PredApp { pred; args; _ } -> [(pred, args)]
                | PredAnd { left; right; _ } -> proof_key left @ proof_key right
              in
              let expected_keys = proof_key other_proof_spec in
              let actual_keys = proof_key resolved in
              let matches_expected = List.for_all (fun ek ->
                List.exists (fun ak -> ak = ek) actual_keys
              ) expected_keys in
              if not matches_expected then
                errors := { loc; message = Printf.sprintf
                  "sidecar proof mismatch: body provides `%s`, but return type declares `%s`"
                  (pp_proof resolved) (pp_proof other_proof_spec) }
                :: !errors
            )

         | EIf { then_; else_; _ } -> check_body then_; check_body else_
         | ECase { arms; _ } -> List.iter (fun (a : case_arm) -> check_body a.body) arms
         | ELet { body; _ } -> check_body body
         | ELetProof { value_name; proof_name; value; body; _ } ->
           (* Track what proof the proof variable carries *)
           let check_proof_opt =
             let rec find_check_fn = function
               | EApp { fn = EVar { name = "check"; _ }; arg; _ } -> Some arg
               | EApp { fn; _ } -> find_check_fn fn
               | _ -> None
             in
             match find_check_fn value with
             | Some check_fn_expr ->
               let fn_name = match check_fn_expr with
                 | EVar { name; _ } -> name
                 | EApp { fn = EVar { name; _ }; _ } -> name
                 | _ -> ""
               in
               let check_args = let rec go acc = function
                 | EApp { fn; arg; _ } -> go (arg :: acc) fn
                 | _ -> acc
               in go [] check_fn_expr in
               (match List.find_opt (fun (fd2 : func_decl) -> fd2.name = fn_name) all_funcs with
                | Some { return_spec = RetAttached { binding = { proof_ann = Some p; name = binder; _ }; _ }; _ } ->
                  let actual_arg = match check_args with
                    | [EVar { name; _ }] -> name
                    | _ -> binder
                  in
                  let rec subst_proof (pe : proof_expr) : proof_expr = match pe with
                    | PredApp { pred; args; loc } ->
                      PredApp { pred; args = List.map (fun a -> if a = binder then actual_arg else a) args; loc }
                    | PredAnd { left; right; loc } ->
                      PredAnd { left = subst_proof left; right = subst_proof right; loc }
                  in
                  Some (subst_proof p)
                | _ -> None)
             | None -> None
           in
           (match check_proof_opt with
            | Some p -> proof_var_env := (proof_name, p) :: !proof_var_env
            | None -> ());
           ignore value_name;
           check_body body
         | _ -> ()
       in
       check_body fd.body;
       !errors
     | _ -> [])
  | _ -> []

(* ── Capability checking ─────────────────────────────────────────────────── *)

(** Validate capability declarations and function requires clauses. *)
let check_capabilities ?(extra_caps = []) (decls : top_decl list) : proof_error list =
  let errors = ref [] in
  let cap_map = build_cap_map decls @ extra_caps in
  let declared_caps = List.map fst cap_map in

  (* Check each capability declaration: all implied caps must be known *)
  List.iter (fun decl ->
    match decl with
    | DCapability c ->
      List.iter (fun implied ->
        if not (List.mem implied declared_caps) then
          errors := { loc = c.loc;
            message = Printf.sprintf
              "capability '%s' implies unknown capability '%s'" c.name implied
          } :: !errors
      ) c.implies
    | DFunc fd ->
      (* Check requires: all listed caps must be declared *)
      List.iter (fun cap ->
        if not (List.mem cap declared_caps) then
          errors := { loc = fd.loc;
            message = Printf.sprintf
              "function '%s' requires undeclared capability '%s'" fd.name cap
          } :: !errors
      ) fd.capabilities
    | _ -> ()
  ) decls;

  List.rev !errors

(* ── B8. Undefined proof predicates ─────────────────────────────────────── *)

(** Predicate names from the standard library that are always valid. *)
let stdlib_predicates : string list =
  [ "IsNonZero"; "IsNonNegative"; "IsNonEmpty"; "IsUpperCase"; "IsLowerCase"
  ; "IsTrimmed"; "IsSorted"; "HasKey"; "ForAll"; "FromDb"; "FromQueue"
  ; "Authenticated"; "Fact"; "FloatNonZero" ]

(** Collect predicate names produced by check/auth/establish functions in imported modules. *)
let load_imported_predicates (m : module_form) : string list =
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
          List.filter_map (function
            | DFact ff ->
              let include_it = match requested with
                | Some names -> List.mem ff.name names
                | None -> true
              in
              if include_it then Some ff.name else None
            | _ -> None
          ) imported.decls
  ) m.imports

let collect_import_parse_errors (m : module_form) : proof_error list =
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
        | Err e -> Some { loc = e.loc;
            message = Printf.sprintf "imported module '%s' has a parse error: %s" imp.module_name e.msg }
  ) m.imports

(** Collect all predicate names referenced in a proof annotation. *)
let rec pred_names_in_proof (p : proof_expr) : string list =
  match p with
  | PredApp { pred; _ } -> if pred = "" then [] else [pred]
  | PredAnd { left; right; _ } -> pred_names_in_proof left @ pred_names_in_proof right

(** Collect all subject argument names referenced in a proof annotation.
    Used to validate that the subject of a record/entity field proof annotation
    actually names a declared field of that record/entity. *)
let rec pred_arg_names_in_proof (p : proof_expr) : string list =
  match p with
  | PredApp { args; _ } -> args
  | PredAnd { left; right; _ } -> pred_arg_names_in_proof left @ pred_arg_names_in_proof right

(** Check that all predicates used in parameter/return annotations are in scope.
    A predicate is in scope if it is:
    - Declared by a check/auth/establish function in the current file
    - Imported via `exposing [...]` (uppercase names from any import)
    - A Tesl stdlib predicate (IsNonZero, IsTrimmed, FloatNonZero, etc.) *)
let check_undefined_predicates (m : module_form) (known_preds : string list) : proof_error list =
  let errors = ref [] in
  let all_known = known_preds @ stdlib_predicates in
  let check_proof loc p =
    List.iter (fun pred_name ->
      if not (List.mem pred_name all_known) then
        errors := { loc;
          message = Printf.sprintf
            "proof predicate '%s' is not in scope — declare it with a `fact` declaration, \
             or import it from the module that declares it"
            pred_name
        } :: !errors
    ) (pred_names_in_proof p)
  in
  let _check_proof_opt loc p_opt =
    match p_opt with None -> () | Some p -> check_proof loc p
  in
  List.iter (fun decl ->
    match decl with
    | DFunc fd ->
      (* Check parameter proof annotations for ALL functions.
         Parameters reference predicates that callers must have proven, so all
         predicate names used here must be declared via `fact` in this module. *)
      List.iter (fun (b : binding) ->
        match b.proof_ann with
        | None -> ()
        | Some p ->
          List.iter (fun pred_name ->
            if not (List.mem pred_name all_known) then
              errors := { loc = b.loc;
                message = Printf.sprintf
                  "proof predicate '%s' in parameter annotation is not in scope — \
declare it with a `fact` declaration, \
or import it from the module that declares it"
                  pred_name
              } :: !errors
          ) (pred_names_in_proof p)
      ) fd.params;

      (* Collect predicates that appear in parameter annotations.
         A predicate in a return spec is allowed if it also appears in a parameter
         annotation (thread-through pattern: proof flows from input to output).
         Only NEW predicates in return specs — not found in any param — are checked.
         check/auth/establish return specs are now also validated: predicates must
         be declared via `fact` before being referenced. *)
      let param_preds =
        List.concat_map (fun (b : binding) ->
          match b.proof_ann with
          | None -> []
          | Some p -> pred_names_in_proof p
        ) fd.params
      in
      let check_proof_new_only loc p =
        List.iter (fun pred_name ->
          if not (List.mem pred_name param_preds) &&
             not (List.mem pred_name all_known) then
            errors := { loc;
              message = Printf.sprintf
                "proof predicate '%s' is not in scope — declare it with a `fact` declaration \
before this function, or import it from the module that declares it"
                pred_name
            } :: !errors
        ) (pred_names_in_proof p)
      in
      let check_proof_opt_new_only loc p_opt =
        match p_opt with None -> () | Some p -> check_proof_new_only loc p
      in
      let rec check_ret spec =
        match spec with
        | RetAttached { binding = b; loc } -> check_proof_opt_new_only loc b.proof_ann
        | RetNamedPack { entity_proof; other_proof; loc; _ } ->
          check_proof_opt_new_only loc entity_proof;
          check_proof_opt_new_only loc other_proof
        | RetForAll { proof; loc; _ } | RetMaybeForAll { proof; loc; _ }
        | RetSetForAll { proof; loc; _ } | RetMaybeSetForAll { proof; loc; _ } ->
          check_proof_new_only loc proof
        | RetForAllDictValues { proof; loc; _ } | RetForAllDictKeys { proof; loc; _ } ->
          check_proof_new_only loc proof
        | RetMaybeAttached { binding = b; loc; _ } ->
          check_proof_opt_new_only loc b.proof_ann
        | RetExists { binding = b; body; _ } ->
          check_proof_opt_new_only b.loc b.proof_ann; check_ret body
        | RetPlain _ -> ()
      in
      check_ret fd.return_spec
    (* Record and entity field proof annotations (e.g. `title: String ::: TitleSafe title`)
       must reference a proof predicate that is in scope in the declaring module —
       either declared locally with a `fact` declaration, imported via `exposing [...]`,
       or a well-known stdlib predicate. The proof's subject argument(s) must be a
       declared field of the same record/entity.
       Reporting at the declaration site (rather than deferring to the construction
       site) keeps the error close to the typo. *)
    | DRecord rf ->
      let field_names = List.map (fun (f : field_def) -> f.name) rf.fields in
      List.iter (fun (f : field_def) ->
        match f.proof_ann with
        | None -> ()
        | Some p ->
          List.iter (fun pred_name ->
            if not (List.mem pred_name all_known) then
              errors := { loc = f.loc;
                message = Printf.sprintf
                  "proof predicate '%s' in record field `%s` is not in scope — declare it with a `fact` declaration, or import it from the module that declares it"
                  pred_name f.name
              } :: !errors
          ) (pred_names_in_proof p);
          List.iter (fun arg_name ->
            (* Reject proof-arg names that are neither a declared field of the
               same record nor the keyword `_` used as a placeholder. Dotted
               paths and literals are allowed through unchanged. *)
            if arg_name <> "_"
               && not (String.contains arg_name '.')
               && not (String.contains arg_name '(')
               && not (List.mem arg_name field_names)
               && (String.length arg_name > 0
                   && arg_name.[0] >= 'a' && arg_name.[0] <= 'z') then
              errors := { loc = f.loc;
                message = Printf.sprintf
                  "proof argument `%s` in record field `%s` is not a field of `%s` — the proof subject must be one of: %s"
                  arg_name f.name rf.name
                  (if field_names = [] then "<no fields>"
                   else String.concat ", " field_names)
              } :: !errors
          ) (pred_arg_names_in_proof p)
      ) rf.fields
    | DEntity ef ->
      let field_names = List.map (fun (f : field_def) -> f.name) ef.fields in
      List.iter (fun (f : field_def) ->
        match f.proof_ann with
        | None -> ()
        | Some p ->
          List.iter (fun pred_name ->
            if not (List.mem pred_name all_known) then
              errors := { loc = f.loc;
                message = Printf.sprintf
                  "proof predicate '%s' in entity field `%s` is not in scope — declare it with a `fact` declaration, or import it from the module that declares it"
                  pred_name f.name
              } :: !errors
          ) (pred_names_in_proof p);
          List.iter (fun arg_name ->
            if arg_name <> "_"
               && not (String.contains arg_name '.')
               && not (String.contains arg_name '(')
               && not (List.mem arg_name field_names)
               && (String.length arg_name > 0
                   && arg_name.[0] >= 'a' && arg_name.[0] <= 'z') then
              errors := { loc = f.loc;
                message = Printf.sprintf
                  "proof argument `%s` in entity field `%s` is not a field of `%s` — the proof subject must be one of: %s"
                  arg_name f.name ef.name
                  (if field_names = [] then "<no fields>"
                   else String.concat ", " field_names)
              } :: !errors
          ) (pred_arg_names_in_proof p)
      ) ef.fields
    | _ -> ()
  ) m.decls;
  List.rev !errors

(* ── Module-level proof checking ─────────────────────────────────────────── *)

let check_module (m : module_form) : proof_error list =
  let errors = ref [] in
  (* Collect all top-level func_decls for cross-function proof lookup *)
  let all_funcs : func_decl list = List.filter_map (function DFunc fd -> Some fd | _ -> None) m.decls in
  let rec collect_call_head_and_args acc = function
    | EApp { fn; arg; _ } -> collect_call_head_and_args (arg :: acc) fn
    | fn -> (fn, acc)
  in
  let normalize_explicit_check_call (head, args) =
    match head, args with
    | EVar { name = "check"; _ }, check_fn :: check_args -> (check_fn, check_args)
    | _ -> (head, args)
  in
  let function_name_of_expr = function
    | EVar { name; _ } -> Some name
    | EField { obj = EConstructor { name = mod_name; args = []; _ }; field; _ }
    | EField { obj = EVar { name = mod_name; _ }; field; _ } -> Some (mod_name ^ "." ^ field)
    | _ -> None
  in
  let rec expr_contains_transaction (e : expr) : bool =
    match e with
    | EWithTransaction _ -> true
    | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ -> false
    | EField { obj; _ } -> expr_contains_transaction obj
    | EApp _ ->
      let (head, args) = normalize_explicit_check_call (collect_call_head_and_args [] e) in
      expr_contains_transaction head || List.exists expr_contains_transaction args
    | EBinop { left; right; _ } -> expr_contains_transaction left || expr_contains_transaction right
    | EUnop { arg; _ } -> expr_contains_transaction arg
    | EIf { cond; then_; else_; _ } ->
      expr_contains_transaction cond || expr_contains_transaction then_ || expr_contains_transaction else_
    | ECase { scrut; arms; _ } ->
      expr_contains_transaction scrut ||
      List.exists (fun (arm : case_arm) -> expr_contains_transaction arm.body) arms
    | ELet { value; body; _ } | ELetProof { value; body; _ } ->
      expr_contains_transaction value || expr_contains_transaction body
    | ERecord { fields; _ } | ETelemetry { fields; _ } ->
      List.exists (fun (_, v) -> expr_contains_transaction v) fields
    | EList { elems; _ } -> List.exists expr_contains_transaction elems
    | EOk { value; _ } -> expr_contains_transaction value
    | EEnqueue { payload; _ } -> expr_contains_transaction payload
    | EPublish { key; payload; _ } ->
      (match key with Some e -> expr_contains_transaction e | None -> false)
      || (match payload with Some e -> expr_contains_transaction e | None -> false)
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ } ->
      expr_contains_transaction body
    | ELambda { body; _ } -> expr_contains_transaction body
    | ECacheGet _ | ECacheDelete _ | ECacheInvalidate _ -> false
    | ECacheSet { value; _ } -> expr_contains_transaction value
    | ESendEmail _ | EStartEmailWorker _ -> false
    | ERuntimeCall { segments; _ } ->
      List.exists (function RLit _ -> false | RArg e -> expr_contains_transaction e) segments
  in
  let rec expr_called_functions (e : expr) : string list =
    let dedup = List.sort_uniq String.compare in
    match e with
    | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ -> []
    | EField { obj; _ } -> expr_called_functions obj
    | EApp _ ->
      let (head, args) = normalize_explicit_check_call (collect_call_head_and_args [] e) in
      dedup (
        (match function_name_of_expr head with Some fn_name -> [fn_name] | None -> [])
        @ expr_called_functions head
        @ List.concat_map expr_called_functions args
      )
    | EBinop { left; right; _ } -> dedup (expr_called_functions left @ expr_called_functions right)
    | EUnop { arg; _ } -> expr_called_functions arg
    | EIf { cond; then_; else_; _ } ->
      dedup (expr_called_functions cond @ expr_called_functions then_ @ expr_called_functions else_)
    | ECase { scrut; arms; _ } ->
      dedup (expr_called_functions scrut @ List.concat_map (fun (arm : case_arm) -> expr_called_functions arm.body) arms)
    | ELet { value; body; _ } | ELetProof { value; body; _ } ->
      dedup (expr_called_functions value @ expr_called_functions body)
    | ERecord { fields; _ } | ETelemetry { fields; _ } ->
      dedup (List.concat_map (fun (_, v) -> expr_called_functions v) fields)
    | EList { elems; _ } -> dedup (List.concat_map expr_called_functions elems)
    | EOk { value; _ } -> expr_called_functions value
    | EEnqueue { payload; _ } -> expr_called_functions payload
    | EPublish { key; payload; _ } ->
      dedup (
        (match key with Some e -> expr_called_functions e | None -> [])
        @ (match payload with Some e -> expr_called_functions e | None -> [])
      )
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ }
      | ELambda { body; _ } ->
      expr_called_functions body
    | ECacheGet _ | ECacheDelete _ | ECacheInvalidate _ -> []
    | ECacheSet { value; _ } -> expr_called_functions value
    | ESendEmail _ | EStartEmailWorker _ -> []
    | ERuntimeCall { segments; _ } ->
      dedup (List.concat_map (function RLit _ -> [] | RArg e -> expr_called_functions e) segments)
  in
  let rec close_transaction_functions txn_funcs =
    let grown =
      List.fold_left (fun acc (fd : func_decl) ->
        if List.mem fd.name acc then acc
        else if List.exists (fun callee -> List.mem callee acc) (expr_called_functions fd.body) then
          fd.name :: acc
        else
          acc
      ) txn_funcs all_funcs
      |> List.sort_uniq String.compare
    in
    if List.length grown = List.length txn_funcs then grown
    else close_transaction_functions grown
  in
  let transaction_functions =
    all_funcs
    |> List.filter_map (fun (fd : func_decl) -> if expr_contains_transaction fd.body then Some fd.name else None)
    |> List.sort_uniq String.compare
    |> close_transaction_functions
  in

  List.iter (fun decl ->
    match decl with
    | DFunc fd ->
      (* 1. Validate parameter proof subjects *)
      errors := validate_param_proof_subjects fd @ !errors;

      (* 1b. Reject self-referential Fact-typed parameters:
         `fn bad(p: Fact (ValidScore p))` is nonsensical because `p` names the
         Fact *holder*, not the value being proven — `Fact (P x)` describes a
         fact about `x`, not about the Fact holder itself.  This mirrors the
         self-referential check already enforced on `let`/test-let bindings
         (`let p: Fact (ValidScore p) = …`), extended to function parameters. *)
      List.iter (fun (b : binding) ->
        let inner_proof_opt = match b.type_expr with
          | TApp { head = TName { name = "Fact"; _ }; arg; _ } -> type_expr_to_proof_expr arg
          | TApp { head = TName { name = "Maybe"; _ };
                   arg = TApp { head = TName { name = "Fact"; _ }; arg = inner; _ }; _ } ->
            type_expr_to_proof_expr inner
          | _ -> None
        in
        match inner_proof_opt with
        | Some proof when List.mem b.name (pred_arg_names_in_proof proof) ->
          errors := { loc = b.loc; message = Printf.sprintf
            "`%s` is used as both the binding name and a proof argument; \
`Fact (P x)` describes a fact about `x`, not about the `Fact` holder itself — \
name the proof-carrying value (a different parameter or local), not the Fact parameter itself"
            b.name } :: !errors
        | _ -> ()
      ) fd.params;

      (* 2. Check ok ::: only in check/auth/establish *)
      errors := validate_no_ok_in_fn fd.body fd.kind fd.loc @ !errors;

      (* 3. Validate check/auth return proofs *)
      errors := validate_check_return all_funcs fd @ !errors;

      (* 4. Validate establish return type: must be Fact (...) or Maybe (Fact (...)) *)
      if fd.kind = EstablishKind then begin
        (* Peel a (possibly nested) type-application left-spine into
           (head_name, arg_name_list).  The parser encodes a multi-arg fact
           `Clamped 1 100 n` as nested TApps whose leftmost head is `Clamped`
           and whose args are TName nodes carrying the literal/subject text
           ("1", "100", "n").  This lets us recover both the predicate NAME
           and the declared literal/subject ARGS for multi-arg facts. *)
        let flatten_type_app ty =
          let rec go acc = function
            (* Subject identifiers parse as TVar (lowercase) and literals/uppercase
               names as TName; capture both as their surface text. *)
            | TApp { head; arg = TName { name = a; _ }; _ }
            | TApp { head; arg = TVar { name = a; _ }; _ } -> go (a :: acc) head
            | TApp { head; arg = _; _ } -> go ("?" :: acc) head
            | TName { name; _ } | TVar { name; _ } -> Some (name, acc)
            | _ -> None
          in go [] ty
        in
        (* From the return spec, extract the inner Fact argument type (the
           `Clamped 1 100 n` part), unwrapping any Maybe (Fact (...)). *)
        let fact_arg_type_of_return spec =
          match spec with
          | RetPlain { ty = TApp { head = TName { name = "Fact"; _ }; arg; _ }; _ } -> Some arg
          | RetPlain { ty = TApp { head = TName { name = "Maybe"; _ };
                                    arg = TApp { head = TName { name = "Fact"; _ };
                                                 arg; _ }; _ }; _ } -> Some arg
          | RetPlain { ty = TApp {
              head = TApp { head = TName { name = "Maybe"; _ };
                            arg  = TName { name = "Fact"; _ }; _ };
              arg; _ }; _ } -> Some arg
          | _ -> None
        in
        (* Declared predicate name (works for 1-arg AND multi-arg facts). *)
        let declared_pred_of_return spec =
          match fact_arg_type_of_return spec with
          | Some arg -> (match flatten_type_app arg with Some (pred, _) -> Some pred | None -> None)
          | None -> None
        in
        (* Declared (name, args) of the return Fact, e.g. ("Clamped",["1";"100";"n"]). *)
        let declared_fact_of_return spec =
          match fact_arg_type_of_return spec with
          | Some arg -> flatten_type_app arg
          | None -> None
        in
        let valid_establish_return = match fd.return_spec with
          | RetPlain { ty = TApp { head = TName { name = "Fact"; _ }; _ }; _ } -> true
          | RetPlain { ty = TApp {
              head = TApp { head = TName { name = "Maybe"; _ };
                            arg  = TName { name = "Fact"; _ }; _ };
              _ }; _ } -> true
          | RetPlain { ty = TApp {
              head = TName { name = "Maybe"; _ };
              arg  = TApp { head = TName { name = "Fact"; _ }; _ }; _ }; _ } -> true
          | _ -> false
        in
        if not valid_establish_return then
          errors := { loc = fd.loc;
            message = "establish functions must return 'Fact (Pred args)' or 'Maybe (Fact (Pred args))'" }
            :: !errors
        else begin
          (* Verify that every fact constructor used in the body matches the declared
             predicate. This prevents `establish f -> Fact (A n) = B n` which would lie
             about what it proves. Collect all EConstructor/EVar names that look like
             fact constructors (uppercase) and compare against the declared predicate. *)
          let known_facts = collect_owned_predicates m.decls in
          (match declared_pred_of_return fd.return_spec with
           | None -> ()
           | Some declared_pred ->
             let rec collect_fact_ctors (e : Ast.expr) : string list =
               match e with
               | EConstructor { name; _ } when
                   List.mem name known_facts && name <> declared_pred -> [name]
               | EVar { name; _ } when
                   List.mem name known_facts && name <> declared_pred -> [name]
               | EConstructor { args; _ } -> List.concat_map collect_fact_ctors args
               | EApp { fn; arg; _ } -> collect_fact_ctors fn @ collect_fact_ctors arg
               | EIf { cond; then_; else_; _ } ->
                 collect_fact_ctors cond @ collect_fact_ctors then_ @ collect_fact_ctors else_
               | ECase { scrut; arms; _ } ->
                 collect_fact_ctors scrut @
                 List.concat_map (fun (a : Ast.case_arm) -> collect_fact_ctors a.body) arms
               | ELet { value; body; _ } | ELetProof { value; body; _ } ->
                 collect_fact_ctors value @ collect_fact_ctors body
               | ELambda { body; _ } -> collect_fact_ctors body
               | _ -> []
             in
             let wrong_ctors = List.sort_uniq String.compare (collect_fact_ctors fd.body) in
             List.iter (fun wrong ->
               errors := { loc = fd.loc; message = Printf.sprintf
                 "establish '%s' declares return type `Fact (%s ...)` but its body uses \
fact constructor `%s`; the body must return the declared fact constructor"
                 fd.name declared_pred wrong }
               :: !errors
             ) wrong_ctors;
             (* For multi-arg / literal-param facts, ALSO verify that a body use of
                the *correct* constructor supplies the declared literal arguments.
                `establish e -> Fact (Clamped 1 100 n) = Clamped 2 200 n` uses the
                right constructor but the wrong literals (2/200 vs 1/100) — that
                lies about which fact it proves, just like using a wrong ctor.
                We only constrain positions whose DECLARED argument is a literal
                (numeric / string / boolean), leaving subject positions (lowercase
                identifiers like `n`) free to be bound to any value. *)
             (match declared_fact_of_return fd.return_spec with
              | None -> ()
              | Some (_, declared_args) ->
                (* Is this declared-arg position a literal constant rather than a
                   GDP subject?  Subjects are lowercase-initial identifiers; `_`
                   is a placeholder; everything else (digits, minus sign, string
                   quote, uppercase) we treat as a literal we must match exactly. *)
                let is_literal_arg a =
                  String.length a > 0 &&
                  not (a = "_") &&
                  not (a = "?") &&
                  not ((a.[0] >= 'a' && a.[0] <= 'z'))
                in
                (* Render a body argument expression into the same surface string
                   the type-arg encoding uses: integers as digits (ELit (LInt 2)
                   -> "2") and string literals WITH their surrounding quotes
                   (ELit (LString "http") -> "\"http\"", matching the TName the
                   parser builds for `Named "http" …`).  Float / bool literals
                   return None so they are never compared (their textual encoding
                   is not reliably round-trippable — staying conservative avoids
                   false positives). *)
                let expr_arg_to_string (e : Ast.expr) : string option =
                  match e with
                  | ELit { lit = LInt n; _ } -> Some (string_of_int n)
                  | ELit { lit = LString s; _ } -> Some ("\"" ^ s ^ "\"")
                  | EVar { name; _ } -> Some name
                  | EUnop { op = UNeg; arg = ELit { lit = LInt n; _ }; _ } -> Some (string_of_int (- n))
                  | _ -> None
                in
                (* Flatten an expression into (ctor_name_opt, arg_exprs) covering
                   both `EConstructor { name; args }` and the curried-EApp spine
                   `EApp(EApp(EConstructor name, a), b)` the parser may produce. *)
                let flatten_ctor_app (e : Ast.expr) : (string * Ast.expr list) option =
                  let rec go acc = function
                    | EConstructor { name; args; _ } -> Some (name, args @ acc)
                    | EApp { fn; arg; _ } -> go (arg :: acc) fn
                    | EVar { name; _ } -> Some (name, acc)
                    | _ -> None
                  in go [] e
                in
                (* Walk the body; for every application of the DECLARED constructor,
                   compare its literal-position args against the declared literals. *)
                let arg_mismatches : string list ref = ref [] in
                let check_ctor_args name body_args =
                  if name = declared_pred
                     && List.length body_args = List.length declared_args then
                    List.iteri (fun i declared_a ->
                      if is_literal_arg declared_a then
                        match expr_arg_to_string (List.nth body_args i) with
                        | Some actual when actual <> declared_a ->
                          arg_mismatches :=
                            Printf.sprintf "argument %d is `%s` but the return spec declares `%s`"
                              (i + 1) actual declared_a :: !arg_mismatches
                        | _ -> ()
                    ) declared_args
                in
                let rec walk_args (e : Ast.expr) =
                  (match flatten_ctor_app e with
                   | Some (name, body_args) when name = declared_pred -> check_ctor_args name body_args
                   | _ -> ());
                  match e with
                  | EConstructor { args; _ } -> List.iter walk_args args
                  | EApp { fn; arg; _ } -> walk_args fn; walk_args arg
                  | EIf { cond; then_; else_; _ } -> walk_args cond; walk_args then_; walk_args else_
                  | ECase { scrut; arms; _ } ->
                    walk_args scrut; List.iter (fun (a : Ast.case_arm) -> walk_args a.body) arms
                  | ELet { value; body; _ } | ELetProof { value; body; _ } ->
                    walk_args value; walk_args body
                  | ELambda { body; _ } -> walk_args body
                  | _ -> ()
                in
                walk_args fd.body;
                List.iter (fun detail ->
                  errors := { loc = fd.loc; message = Printf.sprintf
                    "establish '%s' declares return type `Fact (%s)` but its body's `%s` constructor \
supplies the wrong literal arguments (%s); the body must return the declared fact"
                    fd.name (String.concat " " (declared_pred :: declared_args)) declared_pred detail }
                  :: !errors
                ) (List.sort_uniq String.compare !arg_mismatches)))
        end
      end;

      (* 5. Check for nested with-transaction blocks *)
      let rec check_nested_txn in_txn (e : Ast.expr) =
        match e with
        | EWithTransaction { body; loc } when in_txn ->
          errors := { loc; message = "nested `with transaction` is not allowed; transactions cannot be nested" }
            :: !errors;
          check_nested_txn true body
        | EWithTransaction { body; _ } ->
          check_nested_txn true body
        | ELit _ | EVar _ | EConstructor _ | EFail _ -> ()
        | EField { obj; _ } -> check_nested_txn in_txn obj
        | EApp ({ loc; _ } as app) ->
          let (head, args) = normalize_explicit_check_call (collect_call_head_and_args [] (EApp app)) in
          (match function_name_of_expr head with
           | Some fn_name when in_txn && List.mem fn_name transaction_functions ->
             errors := {
               loc;
               message = Printf.sprintf
                 "call to `%s` is not allowed inside `with transaction` because it can open its own transaction"
                 fn_name;
             } :: !errors
           | _ -> ());
          check_nested_txn in_txn head;
          List.iter (check_nested_txn in_txn) args
        | EBinop { left; right; _ } -> check_nested_txn in_txn left; check_nested_txn in_txn right
        | EUnop { arg; _ } -> check_nested_txn in_txn arg
        | EIf { cond; then_; else_; _ } ->
          check_nested_txn in_txn cond; check_nested_txn in_txn then_; check_nested_txn in_txn else_
        | ECase { scrut; arms; _ } ->
          check_nested_txn in_txn scrut;
          List.iter (fun (arm : case_arm) -> check_nested_txn in_txn arm.body) arms
        | ELet { value; body; _ } | ELetProof { value; body; _ } ->
          check_nested_txn in_txn value; check_nested_txn in_txn body
        | ERecord { fields; _ } ->
          List.iter (fun (_, v) -> check_nested_txn in_txn v) fields
        | EList { elems; _ } -> List.iter (check_nested_txn in_txn) elems
        | EOk { value; _ } -> check_nested_txn in_txn value
        | ETelemetry { fields; _ } ->
          List.iter (fun (_, v) -> check_nested_txn in_txn v) fields
        | EEnqueue { payload; _ } -> check_nested_txn in_txn payload
        | EPublish { key; payload; _ } ->
          Option.iter (check_nested_txn in_txn) key;
          Option.iter (check_nested_txn in_txn) payload
        | EWithDatabase { body; _ } | EWithCapabilities { body; _ } ->
          check_nested_txn in_txn body
        | EStartWorkers _ | EServe _ -> ()
        | ELambda { body; _ } -> check_nested_txn in_txn body
        | ECacheGet _ | ECacheDelete _ | ECacheInvalidate _ -> ()
        | ECacheSet { value; _ } -> check_nested_txn in_txn value
        | ESendEmail _ | EStartEmailWorker _ -> ()
        | ERuntimeCall { segments; _ } ->
          List.iter (function RLit _ -> () | RArg e -> check_nested_txn in_txn e) segments
      in
      check_nested_txn false fd.body;

    | _ -> ()
  ) m.decls;

  (* 4. Capability consistency *)
  let imported_caps = load_imported_cap_map m in
  errors := check_capabilities ~extra_caps:imported_caps m.decls @ !errors;

  (* Propagate parse errors from imported modules *)
  errors := collect_import_parse_errors m @ !errors;

  (* B8: Undefined proof predicates — now enforced.
     A predicate used in a proof annotation must be:
       (a) declared in this file by a check/auth/establish function, OR
       (b) imported via an explicit `import ... exposing [PredicateName]`, OR
       (c) a Tesl stdlib predicate (IsNonZero, IsTrimmed, FloatNonZero, etc.).
     This catches typos and enforces explicit import of cross-module predicates. *)
  let local_preds    = collect_owned_predicates m.decls in
  let imported_preds = load_imported_predicates m in
  let explicit_preds = collect_imported_predicate_names m in
  let all_known      = local_preds @ imported_preds @ explicit_preds in
  errors := check_undefined_predicates m all_known @ !errors;

  (* Ghost witness validation: { record } ::: (detachFact x) must match record invariant *)
  let record_inv_map = List.filter_map (function
    | DRecord r ->
      (match r.invariant with
       | Some inv -> Some (r.name, (r.fields, inv))
       | None -> None)
    | _ -> None
  ) m.decls in
  let is_detach_fact_call = function
    | EApp { fn = EVar { name = "detachFact"; _ }; _ } -> true
    | EApp { fn = EApp { fn = EVar { name = "detachFact"; _ }; _ }; _ } -> true
    | _ -> false
  in
  if record_inv_map <> [] then begin
    List.iter (function
      | DFunc fd ->
        let param_proof_map = List.filter_map (fun (b : binding) ->
          match b.proof_ann with Some p -> Some (b.name, p) | None -> None
        ) fd.params in
        (* Build map of params whose TYPE is Fact(...) — these are valid direct ghost witnesses.
           Also extract the inner proof from Fact(P args) so we can validate subjects. *)
        let fact_type_params = List.filter_map (fun (b : binding) ->
          match b.type_expr with
          | TApp { head = TName { name = "Fact"; _ }; _ } -> Some b.name
          | _ -> None
        ) fd.params in
        (* Map from Fact-typed param name → extracted inner proof_expr (for subject checking) *)
        let fact_type_proof_map = List.filter_map (fun (b : binding) ->
          match b.type_expr with
          | TApp { head = TName { name = "Fact"; _ }; arg; _ } ->
            (match type_expr_to_proof_expr arg with
             | Some p -> Some (b.name, p)
             | None -> None)
          | _ -> None
        ) fd.params in
        (* Also check test blocks *)
        let check_test_param_map (test_params : (string * proof_expr) list) e =
          (* fact_names: set of names bound to Fact values (Fact-typed params + detachFact let-bindings) *)
          let init_fact_names = fact_type_params in
          let rec check_gw param_map fact_names e =
            match e with
            | EOk { value = ERecord { fields; type_hint = Some type_name; _ }; proof; loc }
            | EOk { value = EApp { fn = EConstructor { name = type_name; args = []; _ };
                                   arg = ERecord { fields; _ }; _ };
                    proof; loc } ->
              (match List.assoc_opt type_name record_inv_map with
               | None -> ()
               | Some (_, inv) ->
                 let invariant_proof = inv.proof_text in
                 let inv_pred = match invariant_proof with
                   | PredApp { pred; _ } -> Some pred | _ -> None
                 in
                 (* Helper: validate an actual_proof against the record invariant and fields *)
                 let check_actual_proof actual_proof =
                   let ap_pred = match actual_proof with
                     | PredApp { pred; _ } -> Some pred | _ -> None
                   in
                   if inv_pred <> ap_pred then
                     errors := { loc; message = Printf.sprintf
                       "ghost witness: proof predicate `%s` does not match \
                        record `%s` invariant `%s`; wrong proof"
                       (pp_proof actual_proof) type_name (pp_proof invariant_proof) }
                     :: !errors
                   else begin
                     (* Check subjects by applying field mapping *)
                     let field_map = List.filter_map (fun (fname, fexpr) ->
                       match fexpr with
                       | EVar { name; _ } -> Some (fname, name)
                       | _ -> None
                     ) fields in
                     let subst_arg arg =
                       match List.assoc_opt arg field_map with
                       | Some var -> var | None -> arg
                     in
                     let expected_args = match invariant_proof with
                       | PredApp { args; _ } -> List.map subst_arg args | _ -> []
                     in
                     let actual_args = match actual_proof with
                       | PredApp { args; _ } -> args | _ -> []
                     in
                     if expected_args <> actual_args then
                       errors := { loc; message = Printf.sprintf
                         "ghost witness subjects do not match record fields: \
                          record `%s` invariant needs `%s`, \
                          but proof carries `%s`"
                         type_name (pp_proof invariant_proof) (pp_proof actual_proof) }
                       :: !errors
                   end
                 in
                 (match proof with
                  | PredApp { pred = "detachFact"; args = [x_name]; _ } ->
                    (* First try proof-annotated params (:::), then Fact-typed params *)
                    (match List.assoc_opt x_name param_map with
                     | Some actual_proof -> check_actual_proof actual_proof
                     | None ->
                       match List.assoc_opt x_name fact_type_proof_map with
                       | Some actual_proof -> check_actual_proof actual_proof
                       | None -> (* unknown witness — not enough info to validate *) ())
                  | PredApp { pred; args = []; _ } when List.mem pred fact_names ->
                    (* Fact-typed parameter or let-bound Fact used directly as ghost witness — OK *)
                    ()
                  | _ ->
                    (* Non-detachFact ghost witness — error if record has invariant *)
                    errors := { loc; message = Printf.sprintf
                      "ghost witness for record `%s` must use `(detachFact proof)` \
                       to provide a Fact value for the invariant `%s`"
                      type_name (pp_proof invariant_proof) }
                    :: !errors))
            | EIf { then_; else_; _ } ->
              check_gw param_map fact_names then_; check_gw param_map fact_names else_
            | ECase { arms; _ } ->
              List.iter (fun (a : case_arm) ->
                let arm_map = match a.pattern with
                  | PCon { fields; _ } ->
                    List.filter_map (fun (_, sub_pat) ->
                      match sub_pat with
                      | PVar vname ->
                        (match List.assoc_opt vname param_map with
                         | Some p -> Some (vname, p) | None -> None)
                      | _ -> None
                    ) fields @ param_map
                  | _ -> param_map
                in
                check_gw arm_map fact_names a.body) arms
            | ELet { name; value; body; _ } ->
              check_gw param_map fact_names value;
              (* If this let binds a detachFact result, add to fact_names *)
              let fact_names' =
                if is_detach_fact_call value then name :: fact_names
                else fact_names
              in
              check_gw param_map fact_names' body
            | ELetProof { value; body; _ } ->
              check_gw param_map fact_names value;
              check_gw param_map fact_names body
            | EWithTransaction { body; _ } | EWithDatabase { body; _ }
            | EWithCapabilities { body; _ } -> check_gw param_map fact_names body
            | _ -> ()
          in
          check_gw test_params init_fact_names e
        in
        check_test_param_map param_proof_map fd.body
      | DTest t ->
        (* Build map of ALL fn return predicates: fn_name → predicate names *)
        let fn_return_preds_map = List.filter_map (function
          | DFunc fd ->
            let preds = match fd.return_spec with
              | RetNamedPack { entity_proof; other_proof; _ } ->
                (match entity_proof with Some p -> pred_names_in_proof p | None -> [])
                @ (match other_proof with Some p -> pred_names_in_proof p | None -> [])
              | RetAttached { binding = b; _ } ->
                (match b.proof_ann with Some p -> pred_names_in_proof p | None -> [])
              | RetForAll { proof; _ } | RetMaybeForAll { proof; _ }
              | RetSetForAll { proof; _ } | RetMaybeSetForAll { proof; _ } ->
                pred_names_in_proof proof
              | RetForAllDictValues { proof; _ } | RetForAllDictKeys { proof; _ } ->
                pred_names_in_proof proof
              | _ -> []
            in
            if preds = [] then None else Some (fd.name, preds)
          | _ -> None
        ) m.decls in
        (* Build check fn return proof map: fn_name → (param_names, return_proof) *)
        let check_return_proof_map = List.filter_map (function
          | DFunc fd when fd.kind = CheckKind ->
            (match fd.return_spec with
             | RetAttached { binding = b; _ } ->
               (match b.proof_ann with
                | Some proof ->
                  let param_names = List.map (fun (pb : binding) -> pb.name) fd.params in
                  Some (fd.name, (param_names, b.name, proof))
                | None -> None)
             | _ -> None)
          | _ -> None
        ) m.decls in
        (* Build named-pack fn return proof map: fn_name → (param_names, expanded_entity_proof)
           Covers `fn foo(n: Int) -> Int ? Positive && Small` style returns. *)
        let named_pack_return_proof_map = List.filter_map (function
          | DFunc fd ->
            (match fd.return_spec with
             | RetNamedPack { entity_proof = Some proof; _ } ->
               let param_names = List.map (fun (pb : binding) -> pb.name) fd.params in
               (* expand_entity_proof_group: append "_entity" to each PredApp's args *)
               let rec expand_entity p = match p with
                 | PredApp ({ args; _ } as app) -> PredApp { app with args = args @ ["_entity"] }
                 | PredAnd ({ left; right; _ } as conj) ->
                   PredAnd { conj with left = expand_entity left; right = expand_entity right }
               in
               Some (fd.name, (param_names, expand_entity proof))
             | _ -> None)
          | _ -> None
        ) m.decls in
        (* Derive proof for a let-binding from a check fn call:
           let x = checkFn arg1 arg2 → proof with args substituted.
           The check fn's return binding name is replaced by the let-binding name. *)
        let derive_proof_for_let let_name value =
          let flat = let rec go acc = function
            | EApp { fn; arg; _ } -> go (arg :: acc) fn
            | hd -> (hd, acc)
            in go [] value
          in
          let normalize_check_call (head, args) =
            match head, args with
            | EVar { name = "check"; _ }, check_fn :: check_args -> (check_fn, check_args)
            | _ -> (head, args)
          in
          let (head, args) = normalize_check_call flat in
          match head with
          | EVar { name = fn_name; _ } ->
            (match List.assoc_opt fn_name check_return_proof_map with
             | Some (param_names, ret_binding_name, return_proof) ->
               (* Build substitution: param_name → subject_of(arg), ret_binding → let_name *)
               let param_subst = List.filter_map (fun (pname, arg) ->
                 match arg with
                 | EVar { name = aname; _ } -> Some (pname, aname)
                 | _ -> None
               ) (List.combine
                    (if List.length param_names <= List.length args
                     then param_names
                     else List.filteri (fun i _ -> i < List.length args) param_names)
                    args) in
               (* Also substitute the return binding name with the let-binding name,
                  but only if not already covered by a param substitution *)
               let subst = param_subst @ [(ret_binding_name, let_name)] in
               let rec subst_proof p = match p with
                 | PredApp { pred; args = pargs; loc } ->
                   PredApp { pred; args = List.map (fun a ->
                     match List.assoc_opt a subst with Some s -> s | None -> a
                   ) pargs; loc }
                 | PredAnd { left; right; loc } ->
                   PredAnd { left = subst_proof left; right = subst_proof right; loc }
               in
               Some (subst_proof return_proof)
             | None ->
               (* Fall through to named-pack map for `fn foo() -> T ? Proof` style *)
               (match List.assoc_opt fn_name named_pack_return_proof_map with
                | Some (np_param_names, np_entity_proof) ->
                  let np_param_subst = List.filter_map (fun (pname, arg) ->
                    match arg with
                    | EVar { name = aname; _ } -> Some (pname, aname)
                    | _ -> None
                  ) (List.combine
                       (if List.length np_param_names <= List.length args
                        then np_param_names
                        else List.filteri (fun i _ -> i < List.length args) np_param_names)
                       args) in
                  let np_subst = np_param_subst @ [("_entity", let_name)] in
                  let rec np_subst_proof p = match p with
                    | PredApp { pred; args = pargs; loc } ->
                      PredApp { pred; args = List.map (fun a ->
                        match List.assoc_opt a np_subst with Some s -> s | None -> a
                      ) pargs; loc }
                    | PredAnd { left; right; loc } ->
                      PredAnd { left = np_subst_proof left; right = np_subst_proof right; loc }
                  in
                  Some (np_subst_proof np_entity_proof)
                | None -> None))
          | _ -> None
        in
        (* Check test stmts, tracking proof map *)
        let rec check_test_stmts proof_map fact_names stmts =
          match stmts with
          | [] -> ()
          | TsLetProof { value_name; proof_names; value; _ } :: rest ->
            let proof_map' = match derive_proof_for_let value_name value with
              | Some proof ->
                let pm = (value_name, proof) :: proof_map in
                List.fold_left (fun acc pname -> (pname, proof) :: acc) pm proof_names
              | None -> proof_map
            in
            check_test_stmts proof_map' fact_names rest
          | TsLet { name; value; declared_proof; _ } :: rest ->
            (* Validate declared proof annotation against function's return type *)
            (match declared_proof with
             | Some dp ->
               let declared_preds = pred_names_in_proof dp in
               (* Find the called function and check its return predicates *)
               let fn_name = match value with
                 | EApp _ ->
                   let flat = let rec go acc = function
                     | EApp { fn; arg; _ } -> go (arg :: acc) fn
                     | hd -> (hd, acc)
                     in go [] value
                   in
                   let (head, args) = flat in
                   let normalized_head = match head, args with
                     | EVar { name = "check"; _ }, check_fn :: _ -> check_fn
                     | _ -> head
                   in
                   (match normalized_head with EVar { name = n; _ } -> Some n | _ -> None)
                 | _ -> None
               in
               (match fn_name with
                | Some fn ->
                  let actual_preds =
                    (* First try check function map (has specific proof) *)
                    match List.assoc_opt fn check_return_proof_map with
                    | Some (_, _, rp) -> pred_names_in_proof rp
                    | None ->
                      (* Then try general fn return preds map *)
                      match List.assoc_opt fn fn_return_preds_map with
                      | Some preds -> preds
                      | None -> []
                  in
                  if actual_preds <> [] then begin
                    let missing = List.filter (fun p -> not (List.mem p actual_preds)) declared_preds in
                    if missing <> [] then
                      errors := { loc = (match value with EApp { loc; _ } -> loc | _ -> dummy_loc "");
                        message = Printf.sprintf
                          "let binding `%s` declares proof predicate `%s` but function `%s` does not return it \
                           (the function returns: %s); declared binding type does not match function return type"
                          name (String.concat ", " missing) fn (String.concat ", " actual_preds) }
                      :: !errors
                  end
                | None -> ())
             | None -> ());
            (* Check ghost witness in value *)
            let infer_record_type_from_fields fields =
              let fnames = List.map fst fields |> List.sort_uniq String.compare in
              List.find_opt (fun (_, (rfields, _)) ->
                let rfnames = List.map (fun (f : Ast.field_def) -> f.name) rfields
                              |> List.sort_uniq String.compare in
                rfnames = fnames
              ) record_inv_map
              |> Option.map fst
            in
            (match value with
             | EOk { value = ERecord { fields; type_hint; _ }; proof; loc }
             | EOk { value = EApp { fn = EConstructor { name = _; args = []; _ };
                                    arg = ERecord { fields; type_hint; _ }; _ };
                     proof; loc } ->
               (* Normalize: for EApp case, synthesize type_hint from constructor name *)
               let type_hint_for_app = match value with
                 | EOk { value = EApp { fn = EConstructor { name; _ }; _ }; _ } -> Some name
                 | _ -> type_hint
               in
               let type_name_opt = match type_hint_for_app with
                 | Some t -> Some t
                 | None -> infer_record_type_from_fields fields
               in
               (match type_name_opt with
                | None -> ()
                | Some type_name ->
               (match List.assoc_opt type_name record_inv_map with
                | None -> ()
                | Some (_, inv) ->
                  let invariant_proof = inv.proof_text in
                  let inv_pred = match invariant_proof with
                    | PredApp { pred; _ } -> Some pred | _ -> None
                  in
                  (match proof with
                   | PredApp { pred = "detachFact"; args = [x_name]; _ } ->
                     (* Look up x_name in proof_map *)
                     (match List.assoc_opt x_name proof_map with
                      | None -> ()
                      | Some actual_proof ->
                        let ap_pred = match actual_proof with
                          | PredApp { pred; _ } -> Some pred | _ -> None
                        in
                        if inv_pred <> ap_pred then
                          errors := { loc; message = Printf.sprintf
                            "ghost witness: proof predicate `%s` does not match \
                             record `%s` invariant `%s`; wrong proof"
                            (pp_proof actual_proof) type_name (pp_proof invariant_proof) }
                          :: !errors
                        else begin
                          let field_map = List.filter_map (fun (fname, fexpr) ->
                            match fexpr with
                            | EVar { name; _ } -> Some (fname, name) | _ -> None
                          ) fields in
                          let subst_arg arg =
                            match List.assoc_opt arg field_map with
                            | Some var -> var | None -> arg
                          in
                          let expected_args = match invariant_proof with
                            | PredApp { args; _ } -> List.map subst_arg args | _ -> []
                          in
                          let actual_args = match actual_proof with
                            | PredApp { args; _ } -> args | _ -> []
                          in
                          if expected_args <> actual_args then
                            errors := { loc; message = Printf.sprintf
                              "ghost witness subjects do not match record fields: \
                               record `%s` invariant needs `%s`, \
                               but proof carries `%s`"
                              type_name (pp_proof invariant_proof) (pp_proof actual_proof) }
                            :: !errors
                        end)
                   | PredApp { pred; args = []; _ } when List.mem pred fact_names -> ()
                   | _ ->
                     errors := { loc; message = Printf.sprintf
                       "ghost witness for record `%s` must use `(detachFact proof)` \
                        to provide a Fact value for the invariant `%s`"
                       type_name (pp_proof invariant_proof) }
                     :: !errors)))
             | _ -> ());
            (* Update proof_map with this let binding *)
            let proof_map' = match derive_proof_for_let name value with
              | Some proof -> (name, proof) :: proof_map
              | None -> proof_map
            in
            let fact_names' = if is_detach_fact_call value then name :: fact_names
                             else fact_names in
            check_test_stmts proof_map' fact_names' rest
          | _ :: rest -> check_test_stmts proof_map fact_names rest
        in
        check_test_stmts [] [] t.stmts
      | _ -> ()
    ) m.decls
  end;

  (* Declared proof annotation validation for test block let bindings.
     Check that `let x: T ::: P = expr` doesn't declare proofs that expr doesn't provide. *)
  let fn_return_preds_all = List.filter_map (function
    | DFunc fd ->
      let preds = match fd.return_spec with
        | RetNamedPack { entity_proof; other_proof; _ } ->
          (match entity_proof with Some p -> pred_names_in_proof p | None -> [])
          @ (match other_proof with Some p -> pred_names_in_proof p | None -> [])
        | RetAttached { binding = b; _ } ->
          (match b.proof_ann with Some p -> pred_names_in_proof p | None -> [])
        | _ -> []
      in
      if preds = [] then None else Some (fd.name, preds)
    | _ -> None
  ) m.decls in
  let check_return_preds_all = List.filter_map (function
    | DFunc fd when fd.kind = CheckKind ->
      (match fd.return_spec with
       | RetAttached { binding = b; _ } ->
         (match b.proof_ann with
          | Some proof -> Some (fd.name, pred_names_in_proof proof)
          | None -> None)
       | _ -> None)
    | _ -> None
  ) m.decls in
  List.iter (function
    | DTest t ->
      let rec validate_stmts stmts =
        match stmts with
        | [] -> ()
        | TsLetProof _ :: rest -> validate_stmts rest
        | TsLet { name; value; declared_proof = Some dp; _ } :: rest ->
          let declared_preds = pred_names_in_proof dp in
          let fn_name = match value with
            | EApp _ ->
              let flat = let rec go acc = function
                | EApp { fn; arg; _ } -> go (arg :: acc) fn
                | hd -> (hd, acc)
                in go [] value
              in
              (match fst flat with EVar { name = n; _ } -> Some n | _ -> None)
            | _ -> None
          in
          (match fn_name with
           | Some fn ->
             let actual_preds =
               match List.assoc_opt fn check_return_preds_all with
               | Some preds -> preds
               | None ->
                 match List.assoc_opt fn fn_return_preds_all with
                 | Some preds -> preds
                 | None -> []
             in
             if actual_preds <> [] then begin
               let missing = List.filter (fun p -> not (List.mem p actual_preds)) declared_preds in
               if missing <> [] then
                 errors := { loc = (match value with EApp { loc; _ } -> loc | _ -> dummy_loc "");
                   message = Printf.sprintf
                     "let binding `%s` declares proof predicate `%s` but function `%s` \
                      does not return it (function returns: %s); \
                      declared binding type does not match the function's return type"
                     name (String.concat ", " missing) fn (String.concat ", " actual_preds) }
                 :: !errors
             end
           | None -> ());
          validate_stmts rest
        | _ :: rest -> validate_stmts rest
      in
      validate_stmts t.stmts
    | _ -> ()
  ) m.decls;

  List.rev !errors
