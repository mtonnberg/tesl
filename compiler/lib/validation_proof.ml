open Ast
open Location
open Validation_common
open Validation_structural

(* Review item 1/2 (fail-open hardening): non-exhaustive matches are a COMPILE
   ERROR in this soundness-gating module, so an explicitly-enumerated proof walker
   fails the build when a NEW `Ast.expr` variant is added — forcing a deliberate
   fail-closed decision here rather than a silent fall-open. *)
[@@@ocaml.warning "@8"]

let build_initial_proof_env (params : binding list) : proof_env =
  List.filter_map (fun (b : binding) ->
    match b.proof_ann with
    (* A proof-carrying parameter's declared proof is ASSUMED inside the body;
       sound because every call site discharges it (proof_matches). *)
    | Some proof -> Some (b.name, [Proof_kernel.assume_param proof])
    | None -> None
  ) params

let build_initial_subject_env (params : binding list) : subject_env =
  List.map (fun (b : binding) -> (b.name, b.name)) params

(** Build a note about GDP subject synonyms for `arg_name` in `subject_env`.
    When `arg_name` has a canonical subject key that differs from its surface
    spelling (i.e. it's an alias), or when multiple names share the same
    subject, the note helps the user understand why the error message refers
    to a name that isn't the argument they wrote.
    Returns "" when there's nothing interesting to say. *)
let subject_chain_note (arg_name : string) (subject_env : subject_env) : string =
  let canonical = match List.assoc_opt arg_name subject_env with
    | Some s -> s
    | None -> arg_name
  in
  (* Find all names in subject_env whose canonical subject equals ours. *)
  let synonyms =
    List.filter_map (fun (name, subj) ->
      if subj = canonical && name <> arg_name then Some name else None
    ) subject_env
    |> List.sort_uniq String.compare
  in
  if canonical <> arg_name then
    (* arg_name is an alias for canonical — the error message mentions canonical,
       so tell the user why (arg_name derives from canonical). *)
    let other_aliases = List.filter (fun n -> n <> canonical) synonyms in
    if other_aliases = [] then
      Printf.sprintf " (`%s` is derived from `%s` — same GDP subject)" arg_name canonical
    else
      Printf.sprintf " (`%s` is derived from `%s` — same GDP subject; also aliased as: %s)"
        arg_name canonical
        (String.concat ", " (List.map (Printf.sprintf "`%s`") other_aliases))
  else if synonyms <> [] then
    (* arg_name IS the canonical subject but has aliases in scope *)
    Printf.sprintf " (also known as: %s in this scope)"
      (String.concat ", " (List.map (Printf.sprintf "`%s`") synonyms))
  else
    "" (* no interesting information to add *)

let unresolved_subjects
    (formal_names : string list)
    (mapping : (string * string) list)
    (proof : proof_expr)
    : string list =
  proof_subjects proof
  |> List.filter (fun subj -> List.mem subj formal_names && not (List.mem_assoc subj mapping))
  |> List.sort_uniq String.compare

let check_call_proofs
    ?(funcs : (string * func_info) list = [])
    (loc : loc)
    (func_name : string)
    (params : binding list)
    (args : expr list)
    (subject_env : subject_env)
    (proof_env : proof_env)
    : validation_error list =
  let formal_names = List.map (fun (b : binding) -> b.name) params in
  let mapping = List.filter_map (fun ((param : binding), arg) ->
    match subject_of_expr subject_env arg with
    | Some subject -> Some (param.name, subject)
    | None -> None
  ) (zip_prefix params args) in
  let errors = ref [] in
  List.iter2 (fun (param : binding) arg ->
    (* Check Fact-typed params against the full proof expression carried by the evidence. *)
    (match proof_of_fact_type param.type_expr with
     | Some expected_proof ->
       let expected_proof = subst_proof mapping expected_proof in
       let carried_fact_proofs = match proofs_of_evidence_expr ~funcs subject_env proof_env arg with
         | Some proofs -> List.map Proof_kernel.fact_of proofs
         | None -> []
       in
       (match carried_fact_proofs with
        | _ :: _ ->
          if not (proof_matches expected_proof carried_fact_proofs) then
            let carried_desc =
              carried_fact_proofs
              |> List.concat_map flatten_proof
              |> List.map pp_proof
              |> String.concat ", "
            in
            let expected_desc = pp_proof expected_proof in
            errors := make_error loc
              ~hint:(Printf.sprintf "the proof carried by the argument does not match the                    required `Fact (%s)` evidence" expected_desc)
              (Printf.sprintf "proof mismatch: argument to `%s` parameter `%s` carries proof(s)                   `%s`, but `Fact (%s)` is required"
                 func_name param.name carried_desc expected_desc)
            :: !errors
        | [] ->
          (* #5-Fact-param (2026-07-04): the value-side evidence is opaque (the arg
             is not in proof_env — e.g. an opaque Fact-typed variable), so the old
             `carried <> []` guard skipped the check and let a Fact(A) launder where
             Fact(B) is required (the type checker unifies Fact heads).  Fall back to
             the arg's declared/inferred Fact TYPE and compare its predicate to the
             required one.  Fires ONLY on a resolvable Fact-typed arg, so it does not
             over-reject lesson12's `detachFact pq` (which resolves via proof_env into
             the branch above) or exotic non-Fact-typed shapes. *)
          let arg_fact =
            match !field_proof_type_ctx with
            | Some (tenv, fmap, ctors) ->
              (match infer_expr_type tenv funcs fmap ctors arg with
               | Some ty -> proof_of_fact_type ty
               | None -> None)
            | None -> None
          in
          (match arg_fact with
           | Some ap ->
             let ap' = subst_proof mapping ap in
             if not (proof_matches expected_proof [ap']) then
               errors := make_error loc
                 ~hint:(Printf.sprintf
                   "the argument's fact `%s` does not match the required fact `%s`"
                   (pp_proof ap') (pp_proof expected_proof))
                 (Printf.sprintf
                   "proof mismatch: argument to `%s` parameter `%s` has type `Fact (%s)`, \
                    but `Fact (%s)` is required"
                   func_name param.name (pp_proof ap') (pp_proof expected_proof))
               :: !errors
           | None -> ()))
     | None -> ());
    match param.proof_ann with
    | None -> ()
    | Some required ->
      let unresolved = unresolved_subjects formal_names mapping required in
      let carried = match carried_proofs_of_expr ~funcs subject_env proof_env arg with
        | Some proofs -> List.map Proof_kernel.fact_of proofs
        | None -> []
      in
      (match subject_of_expr subject_env arg with
       | None ->
         (match arg with
           | ELit { loc = lit_loc; _ } ->
             errors := make_error lit_loc
               ~hint:(Printf.sprintf "bind the value to a named variable before passing it to `%s`" func_name)
               (Printf.sprintf "argument to `%s` parameter `%s` requires proof `%s`, but the argument is a literal"
                  func_name param.name (pp_proof required))
               :: !errors
           | _ ->
             errors := make_error loc
               ~hint:(Printf.sprintf "bind the expression to a named variable first, then pass that variable to `%s`" func_name)
               (Printf.sprintf "call to `%s` argument `%s` requires proof `%s`, but the argument is an expression with no trackable subject"
                  func_name param.name (pp_proof required))
               :: !errors)
       | Some _ ->
         if unresolved <> [] then
           errors := make_error loc
             ~hint:(Printf.sprintf "all proof subjects must be trackable variable names at the call site (%s unresolved)" (String.concat ", " unresolved))
             (Printf.sprintf "call to `%s` argument `%s` requires proof `%s`, but some cross-parameter subjects are not trackable"
                func_name param.name (pp_proof required))
             :: !errors
         else begin
           let required' = subst_proof_args_with_subjects subject_env (subst_proof mapping required) in
           (* Normalise carried proofs through subject_env so that, e.g.,
              Positive v1 resolves to Positive n1 when subject_env maps v1→n1.
              This is needed for RetNamedPack functions where the entity proof
              uses result_name but the required proof uses the argument's subject.
              We also normalise required' so that call-site subject aliases
              (e.g. `checked → result` from a case arm) are followed in both
              directions, preventing false negatives for lambda proof checks. *)
           let carried_norm = List.map (subst_proof_args_with_subjects subject_env) carried in
           (* R51 follow-up — narrow check for the user's bug pattern
              `requiresX (value ::: wrongProof)`, where `wrongProof` is a
              proof variable whose described subject is different from the
              required proof's subject. Fire this check BEFORE the generic
              carried-vs-required match so the error message is precise.
              We intentionally skip this when the attached proof is a
              combination (`p1 && p2`) or when the proof is not a bare
              variable reference — those forms are legitimate sidecar or
              composition uses. *)
           let attach_subject_mismatch =
             match arg with
             | EOk { proof = PredApp { pred = proof_var_name; args = []; _ }; _ } ->
               let proof_subjects =
                 match List.assoc_opt proof_var_name proof_env with
                 | Some proofs ->
                   List.filter_map (fun pf -> match Proof_kernel.fact_of pf with
                     | PredApp { args = (_ :: _ as pargs); _ } ->
                       Some (List.nth pargs (List.length pargs - 1))
                     | _ -> None) proofs
                 | None -> []
               in
               let required_subjects =
                 let rec go = function
                   | PredApp { args = (_ :: _ as pargs); _ } ->
                     [List.nth pargs (List.length pargs - 1)]
                   | PredAnd { left; right; _ } -> go left @ go right
                   | _ -> []
                 in go required'
               in
               let resolve_chain n =
                 let rec follow seen n0 =
                   if List.mem n0 seen then n0
                   else match List.assoc_opt n0 subject_env with
                     | Some s when s <> n0 -> follow (n0 :: seen) s
                     | _ -> n0
                 in follow [] n
               in
               let proof_subjects_r = List.map resolve_chain proof_subjects in
               let required_subjects_r = List.map resolve_chain required_subjects in
               proof_subjects_r <> [] && required_subjects_r <> []
               && not (List.exists (fun s -> List.mem s required_subjects_r) proof_subjects_r)
             | _ -> false
           in
           if attach_subject_mismatch then begin
             let proof_var_name = match arg with
               | EOk { proof = PredApp { pred; _ }; _ } -> pred
               | _ -> "?"
             in
             errors := make_error loc
               ~hint:(Printf.sprintf
                 "the proof `%s` describes a different subject than the call site requires; \
                  rebind the value with a `check` that establishes `%s` here"
                 proof_var_name (pp_proof required'))
               (Printf.sprintf
                 "call to `%s` argument `%s`: the explicit `::: %s` attaches a proof about a different subject than the required `%s`"
                 func_name param.name proof_var_name (pp_proof required'))
               :: !errors
           end else
           if not (proof_matches required' carried_norm) &&
              not (proof_matches required' carried) then
             (* Use the surface variable name in the hint, not the internal subject — avoids
                confusing "validate validated" when the user passed `bare = forgetFact validated`. *)
             let subject_hint = match arg with
               | EVar { name; _ } -> name
               | _ -> (match subject_of_expr subject_env arg with Some s -> s | None -> param.name)
             in
             let chain_note = subject_chain_note subject_hint subject_env in
             errors := make_error loc
               ~hint:(Printf.sprintf "validate `%s` with a check function that establishes `%s`%s"
                  subject_hint (pp_proof required') chain_note)
               (Printf.sprintf "call to `%s` argument `%s` does not statically satisfy declared proof `%s`"
                  func_name param.name (pp_proof required'))
               :: !errors
         end)
  ) (List.filteri (fun i _ -> i < List.length args) params) (List.filteri (fun i _ -> i < List.length params) args);
  List.rev !errors

(* R51 follow-up — when `let (v ::: p1 && p2 && ...)` synthesises multiple
   ELetProof nodes, only the OUTER has the true binder (v); the inner ones
   use value_name = "_". For RetNamedPack RHSs, `_entity` must be renamed
   to the outer binder — otherwise `Small _` ends up in proof_env. We keep
   an expression-location → outer-binder map here so inner ELetProofs can
   recover the outer name. *)
let entity_binder_at_in_val : (loc * string) list ref = ref []

let effective_value_name value_name value =
  if value_name <> "_" then value_name
  else
    let loc_opt = match value with
      | EVar { loc; _ } | ELit { loc; _ } | EField { loc; _ }
      | EApp { loc; _ } | EBinop { loc; _ } | EUnop { loc; _ }
      | EIf { loc; _ } | ECase { loc; _ } | ELet { loc; _ }
      | ELetProof { loc; _ } | ERecord { loc; _ } | EList { loc; _ }
      | EOk { loc; _ } | EFail { loc; _ } | EConstructor { loc; _ }
      | ELambda { loc; _ } -> Some loc
      | _ -> None
    in
    match loc_opt with
    | Some loc ->
      (match List.assoc_opt loc !entity_binder_at_in_val with
       | Some outer -> outer
       | None -> value_name)
    | None -> value_name

let record_entity_binder value_name value =
  if value_name = "_" then ()
  else
    let loc_opt = match value with
      | EVar { loc; _ } | ELit { loc; _ } | EField { loc; _ }
      | EApp { loc; _ } | EBinop { loc; _ } | EUnop { loc; _ }
      | EIf { loc; _ } | ECase { loc; _ } | ELet { loc; _ }
      | ELetProof { loc; _ } | ERecord { loc; _ } | EList { loc; _ }
      | EOk { loc; _ } | EFail { loc; _ } | EConstructor { loc; _ }
      | ELambda { loc; _ } -> Some loc
      | _ -> None
    in
    match loc_opt with
    | Some loc -> entity_binder_at_in_val := (loc, value_name) :: !entity_binder_at_in_val
    | None -> ()

(* Stdlib higher-order combinators that distribute a per-element proof from a
   `ForAll`-carrying collection onto the elements they hand to their callback.
   Only these have the contract that justifies a proof-annotated lambda
   parameter; any other HOF (user-defined or non-distributing stdlib) cannot
   establish the per-element proof, so a proof-annotated lambda passed to it
   would forge the proof. *)
let proof_distributing_combinators =
  [ "List.map"; "Set.map"
  ; "List.foldr"; "List.foldl"; "List.foldRight"; "List.foldLeft"
  ; "List.forEach"; "Set.forEach" ]

(* Extract UpperCamelCase identifier tokens (predicate names) from a string such
   as the pretty-printed inner proof of a `ForAll` predicate
   ("IsPositive", "IsPositive && IsEven", "InRange 1 10" → ["InRange"]). *)
let upper_camel_tokens (s : string) : string list =
  let buf = Buffer.create 16 in
  let out = ref [] in
  let flush () =
    if Buffer.length buf > 0 then begin
      let t = Buffer.contents buf in
      (if t.[0] >= 'A' && t.[0] <= 'Z' then out := t :: !out);
      Buffer.clear buf
    end
  in
  String.iter (fun c ->
    match c with
    | 'A'..'Z' | 'a'..'z' | '0'..'9' | '_' -> Buffer.add_char buf c
    | _ -> flush ()) s;
  flush ();
  List.rev !out

(* Element-level predicate names carried by a `ForAll`/`ForAllValues`/`ForAllKeys`
   proof on a collection. *)
let forall_inner_pred_names (proofs : proof_expr list) : string list =
  List.concat_map (fun p ->
    match p with
    | PredApp { pred = ("ForAll" | "ForAllValues" | "ForAllKeys"); args = proof_name :: _; _ } ->
      upper_camel_tokens proof_name
    | _ -> []
  ) proofs
  |> List.sort_uniq String.compare

let rec check_expr_call_proofs
    (subject_env : subject_env)
    (proof_env : proof_env)
    (funcs : (string * func_info) list)
    (e : expr)
    : validation_error list =
  match e with
  | EApp _ ->
    let (head0, args0) = collect_call_head_and_args [] e in
    let (head, args) = normalize_explicit_check_call head0 args0 in
    (* Proof-annotated lambda ARGUMENTS are checked specially below (their body
       is checked with the param proof assumed ONLY when a `ForAll` source
       justifies it), so exclude them from the generic recursion here. *)
    let is_proof_annotated_lambda = function
      | ELambda { params; _ } -> List.exists (fun (p : binding) -> p.proof_ann <> None) params
      | _ -> false
    in
    let inner = List.concat_map (fun a ->
      if is_proof_annotated_lambda a then []
      else check_expr_call_proofs subject_env proof_env funcs a) args in
    (* attachFact subject-mismatch check: the fact must describe the same underlying
       value as the one being attached to.
       E.g. `attachFact name2 proof` where proof was derived from `ne = check … name`
       is wrong because the proof says `NonEmpty name`, not `NonEmpty name2`.

       We determine what a fact *describes* by reading proof_env for the fact variable
       and taking the last argument of each carried proof predicate (conventionally the
       "subject" position, e.g. `NonEmpty name` → `name`, `InRange lo hi n` → `n`).
       This is more reliable than following subject_env, which only tracks which value
       the proof was *extracted from* (not what it says). *)
    let attach_errors = match function_name_of_expr head with
      | Some "attachFact" ->
        (match args with
         | [value_expr; fact_expr] ->
           let v_subj_opt = subject_of_expr subject_env value_expr in
           (* Collect the described subjects from the carried proofs *)
           let proof_subjects =
             let proofs = match fact_expr with
               | EVar { name = fact_name; _ } ->
                 (match List.assoc_opt fact_name proof_env with
                  | Some ps -> List.map Proof_kernel.fact_of ps
                  | None -> [])
               | _ -> []
             in
             List.filter_map (function
               | PredApp { args = (_ :: _ as pargs); _ } ->
                 Some (List.nth pargs (List.length pargs - 1))
               | _ -> None) proofs
           in
           (match v_subj_opt with
            | Some v_subj
              when proof_subjects <> []
                && not (List.mem v_subj proof_subjects) ->
              let call_loc = match head with
                | EVar { loc; _ } -> loc
                | _ -> gen_loc
              in
              let described = String.concat ", " proof_subjects in
              let v_chain = subject_chain_note v_subj subject_env in
              [ make_error call_loc
                  ~hint:(Printf.sprintf
                    "the fact describes `%s`; use `attachFact` with a value derived from `%s`, \
                     or re-prove the value with a `check …` call%s"
                    described described v_chain)
                  (Printf.sprintf
                    "proof subject mismatch: the fact describes `%s` but is being attached \
                     to a value derived from `%s`"
                    described v_subj) ]
            | _ -> [])
         | _ -> [])
      | _ -> []
    in
    let call_errors = match function_name_of_expr head with
      | Some fn_name ->
        (match List.assoc_opt fn_name funcs with
         | Some info when List.exists (fun (p : binding) ->
             p.proof_ann <> None || Option.is_some (proof_of_fact_type p.type_expr)
           ) info.fi_params ->
           check_call_proofs ~funcs (match head with
             | EVar { loc; _ } -> loc
             | EField { loc; _ } -> loc
             | _ -> gen_loc) fn_name info.fi_params args subject_env proof_env
         | _ -> [])
      | None -> []
    in
    (* Detect proof-requiring fn/handler passed as a plain callback.
       Calling such a function via a higher-order combinator (e.g. List.map)
       silently drops proof requirements because the HOF has no knowledge of
       the proof obligations. Reject at validation time. *)
    let callback_errors = List.filter_map (fun arg ->
      match function_name_of_expr arg with
      | Some fn_name ->
        (match List.assoc_opt fn_name funcs with
         | Some info
           when (info.fi_kind = FnKind || info.fi_kind = HandlerKind)
             && List.exists (fun (p : binding) -> p.proof_ann <> None) info.fi_params ->
           let loc = match arg with
             | EVar { loc; _ } -> loc
             | EField { loc; _ } -> loc
             | _ -> gen_loc
           in
           Some (make_error loc
             ~hint:"wrap it in an explicit function literal that performs the proof check: e.g. `fn(x: T) -> myFn (check MyPred x)`"
             (Printf.sprintf
                "function `%s` requires proof annotations on its parameters and cannot be passed as a plain callback; \
                 callers via higher-order functions cannot satisfy the required proofs"
                fn_name))
         | _ -> None)
      | None -> None
    ) args in
    (* R52-L inline lambda call: `(fn(n: T ::: P n) -> ...) arg`
       When the call head is a lambda literal whose params carry proof annotations,
       check the actual arguments against those annotations. *)
    let inline_lambda_errors = match head with
      | ELambda { params; _ }
        when List.exists (fun (p : binding) -> p.proof_ann <> None) params ->
        let call_loc = match e with
          | EApp { fn = _; arg = _; loc = l } -> l
          | _ -> gen_loc
        in
        check_call_proofs ~funcs call_loc "<lambda>" params args subject_env proof_env
      | _ -> []
    in
    (* §6.1 — proof-annotated lambda LITERAL passed as an argument.
       `someHof (fn(n: T ::: P n) -> body) ...` introduces a parameter that
       CLAIMS to carry `P` with nothing to back it up — a proof conjured from
       nowhere. The ONLY position where such a lambda is legitimate is as the
       callback of a recognised element-distributing stdlib combinator
       (List.map/Set.map/List.foldr/…) over a collection that already carries a
       matching `ForAll P`: there the per-element proof genuinely COMES FROM the
       collection (the lesson30 pattern). Every other case is rejected RIGHT AT
       THE LAMBDA — including a body that happens not to consume the proof yet —
       because allowing it is a latent footgun (a later edit silently turns it
       unsound) and the eventual error would land far from its cause. Proofs are
       never conjured; they are established (check/auth/establish) or distributed
       (ForAll). When justified we check `body` WITH the param proof assumed.
       (The lambda-as-call-HEAD immediate-application form, where the argument is
       checked against the param proof, is handled by `inline_lambda_errors`
       above; this only fires for non-head argument positions.) *)
    let lambda_arg_errors = List.concat_map (fun arg ->
      match arg with
      | ELambda { params = lam_params; body = lam_body; loc = lam_loc }
        when is_proof_annotated_lambda arg ->
        let required_preds =
          List.concat_map (fun (p : binding) ->
            match p.proof_ann with Some pr -> proof_predicates pr | None -> []) lam_params
          |> List.sort_uniq String.compare
        in
        let is_distributor = match function_name_of_expr head with
          | Some n -> List.mem n proof_distributing_combinators
          | None -> false
        in
        (* ForAll element-predicates available from any OTHER argument that is a
           variable carrying a ForAll proof in the current proof environment. *)
        let available_preds =
          List.concat_map (fun a ->
            match a with
            | ELambda _ -> []
            | EVar { name; _ } ->
              (match List.assoc_opt name proof_env with
               | Some proofs -> forall_inner_pred_names (List.map Proof_kernel.fact_of proofs)
               | None -> [])
            | _ -> []) args
          |> List.sort_uniq String.compare
        in
        let justified =
          is_distributor
          && required_preds <> []
          && List.for_all (fun p -> List.mem p available_preds) required_preds
        in
        if justified then begin
          (* Legitimate ForAll distribution — the per-element proof is real, so
             assume it while checking the body (mirrors the generic ELambda
             arm). *)
          let body_proof_env =
            List.fold_left (fun acc (b : binding) ->
              match b.proof_ann with
              | None -> acc
              | Some proof ->
                (b.name,
                 List.map Proof_kernel.assume_param (flatten_proof_conj proof)) :: acc
            ) proof_env lam_params
          in
          check_expr_call_proofs subject_env body_proof_env funcs lam_body
        end else begin
          (* Unjustified — the lambda's proof annotation has no source. Reject at
             the lambda itself (one error, at the cause) and do NOT proof-check
             the body under the bogus premise (that would either hide the forge
             or emit a confusing secondary error far from here). *)
          let required_s = String.concat ", " required_preds in
          let hint =
            if is_distributor then
              Printf.sprintf
                "the collection passed to `%s` must already carry `ForAll (%s)` so each element is proven \
                 — establish it with `List.filterCheck`/`List.allCheck`/a `select` first, \
                 then map; or drop the proof annotation and validate inside the lambda with a `check`"
                (match function_name_of_expr head with Some n -> n | None -> "the combinator") required_s
            else
              "a proof-annotated lambda parameter is only valid as the callback of a `ForAll`-distributing \
               stdlib combinator (List.map/Set.map/List.foldr/List.foldl) over a `ForAll`-proven collection; \
               drop the annotation and validate inside the lambda with a `check`, or establish the proof first"
          in
          let what =
            match function_name_of_expr head with
            | Some n when is_distributor ->
              Printf.sprintf "`%s` over a collection that does not carry `ForAll (%s)`" n required_s
            | Some n -> Printf.sprintf "`%s`, which does not distribute element proofs" n
            | None -> "a higher-order function that cannot establish it"
          in
          [ make_error lam_loc
              ~hint
              (Printf.sprintf
                 "lambda parameter declares proof `%s`, but nothing establishes it here: the lambda is passed to %s. \
                  A proof must be established (check/auth/establish) or distributed from a `ForAll` collection — never conjured by annotating a parameter"
                 required_s what) ]
        end
      | _ -> []
    ) args in
    inner @ attach_errors @ call_errors @ callback_errors @ inline_lambda_errors @ lambda_arg_errors
  | ELet { name = _binder; declared_proof; declared_type; value; body; loc } ->
    let name = _binder in
    (* R51_P01 / R51_P02 — proof laundering via `let`.
       A `let f = g` where `g` is a named function with one or more
       proof-annotated parameters, or `let f = g arg1 ... argK` where the
       remaining (unapplied) parameters include proof-annotated ones,
       silently drops the proof obligation — the subsequent `f arg` call
       has no trackable function identity, so `check_call_proofs` sees no
       obligation to enforce. Reject this at the `let` so the bug is
       caught where it occurs, not silently later. *)
    let laundering_errors =
      let rec head_and_applied_args = function
        | EVar { name = n; _ } -> Some (n, [])
        | EApp { fn; arg; _ } ->
          (match head_and_applied_args fn with
           | Some (n, args) -> Some (n, args @ [arg])
           | None -> None)
        | _ -> None
      in
      match head_and_applied_args value with
      | Some (fn_name, applied_args) ->
        (match List.assoc_opt fn_name funcs with
         | Some info ->
           let total = List.length info.fi_params in
           let applied_count = List.length applied_args in
           if applied_count < total then begin
             let remaining = List.filteri (fun i _ -> i >= applied_count) info.fi_params in
             let has_proof = List.exists
               (fun (p : binding) -> p.proof_ann <> None) remaining in
             if has_proof then begin
               (* Walk `body` looking for uses of `name` (the alias).
                  - If the alias appears as a call head `name x1 ... xM`,
                    reconstruct the full call `fn_name applied_args... x1..xM`
                    and run `check_expr_call_proofs` on it so proof obligations
                    on the remaining proof-bearing params are enforced at the
                    actual use site — this legitimises partial applications
                    that only strip non-proof-bearing leading args (e.g.
                    `let addToN = addProved 10` where the proof is on arg 2).
                  - If the alias appears anywhere else (passed as argument,
                    returned, stored in a record, etc.), the proof obligation
                    cannot be checked — report a single laundering error at
                    that location. *)
               let reconstructed_errors = ref [] in
               let non_call_loc : loc option ref = ref None in
               let rec visit e =
                 match e with
                 | EVar { name = n; loc = l; _ } when n = name ->
                   if !non_call_loc = None then non_call_loc := Some l
                 | EApp _ ->
                   let (h, args) = collect_call_head_and_args [] e in
                   (match function_name_of_expr h with
                    | Some n when n = name ->
                      List.iter visit args;
                      let reconstructed_args = applied_args @ args in
                      let rec build_app h_expr a_list =
                        match a_list with
                        | [] -> h_expr
                        | a :: rest ->
                          build_app (EApp { fn = h_expr; arg = a; loc = gen_loc }) rest
                      in
                      let fn_head = EVar { name = fn_name; loc = gen_loc } in
                      let reconstructed = build_app fn_head reconstructed_args in
                      reconstructed_errors := !reconstructed_errors
                        @ check_expr_call_proofs subject_env proof_env funcs reconstructed
                    | _ ->
                      visit h;
                      List.iter visit args)
                 | EField { obj; _ } -> visit obj
                 | EBinop { left; right; _ } -> visit left; visit right
                 | EUnop { arg; _ } -> visit arg
                 | EIf { cond; then_; else_; _ } ->
                   visit cond; visit then_; visit else_
                 | ECase { scrut; arms; _ } ->
                   visit scrut;
                   List.iter (fun (a : case_arm) ->
                     (match a.guard with Some g -> visit g | None -> ());
                     visit a.body) arms
                 | ELet { name = n; value = v; body = b; _ } ->
                   visit v;
                   (* Don't descend into body if alias is shadowed.
                      (Shadowing is illegal per spec, but be defensive.) *)
                   if n <> name then visit b
                 | ELetProof { value_name; proof_name; value = v; body = b; _ } ->
                   visit v;
                   if value_name <> name && proof_name <> name then visit b
                 | ERecord { fields; _ } ->
                   List.iter (fun (_, v) -> visit v) fields
                 | EList { elems; _ } -> List.iter visit elems
                 | EOk { value = v; _ } -> visit v
                 | EFail { message; _ } -> visit message
                 | ETelemetry { fields; _ } ->
                   List.iter (fun (_, v) -> visit v) fields
                 | EEnqueue { payload; _ } -> visit payload
                 | EPublish { key; payload; _ } ->
                   (match key with Some k -> visit k | None -> ());
                   (match payload with Some p -> visit p | None -> ())
                 | EWithDatabase { body = b; _ }
                 | EWithCapabilities { body = b; _ }
                 | EWithTransaction { body = b; _ } -> visit b
                 | EServe { port; _ } -> visit port
                 | EConstructor { args; _ } -> List.iter visit args
                 | ELambda { params; body = b; _ } ->
                   if not (List.exists (fun (p : binding) -> p.name = name) params)
                   then visit b
                 | ELit _ | EVar _ | EStartWorkers _ -> ()
                 | ECacheGet _ | ECacheDelete _ | ECacheInvalidate _ -> ()
                 | ECacheSet { value; _ } -> visit value
                 | ESendEmail _ | EStartEmailWorker _ -> ()
                 | ERuntimeCall { segments; _ } ->
                   List.iter (function RLit _ | RRawVar _ -> () | RArg e -> visit e) segments
               in
               visit body;
               let non_call_errors =
                 match !non_call_loc with
                 | Some l ->
                   [ make_error l
                       ~hint:(Printf.sprintf
                         "call `%s` directly at its use site (supplying all remaining arguments), or wrap `%s` in a fresh `fn(...) -> ...` lambda that re-validates the proof with `check`"
                         fn_name name)
                       (Printf.sprintf
                         "alias `%s` of proof-requiring function `%s` cannot be passed around — doing so would bypass the proof check on the remaining parameters"
                         name fn_name) ]
                 | None -> []
               in
               !reconstructed_errors @ non_call_errors
             end else []
           end else []
         | None -> [])
      | None -> []
    in
    (* R52-L let-bound lambda: `let f = fn(n: T ::: P n) -> ...; f arg`
       When the bound value is a lambda with proof-annotated parameters, walk the
       body looking for calls to `name` and check proof obligations at each call
       site, just like the R51 partial-application alias logic above. *)
    let let_lambda_errors =
      match value with
      | ELambda { params; _ }
        when List.exists (fun (p : binding) -> p.proof_ann <> None) params ->
        let call_errors_ref = ref [] in
        let non_call_loc : loc option ref = ref None in
        let rec visit e =
          match e with
          | EVar { name = n; loc = l; _ } when n = name ->
            if !non_call_loc = None then non_call_loc := Some l
          | EApp _ ->
            let (h, call_args) = collect_call_head_and_args [] e in
            (match function_name_of_expr h with
             | Some n when n = name ->
               List.iter visit call_args;
               let call_loc = match h with
                 | EVar { loc = l; _ } -> l
                 | _ -> gen_loc
               in
               call_errors_ref := !call_errors_ref
                 @ check_call_proofs ~funcs call_loc name params call_args subject_env proof_env
             | _ ->
               visit h;
               List.iter visit call_args)
          | EField { obj; _ } -> visit obj
          | EBinop { left; right; _ } -> visit left; visit right
          | EUnop { arg; _ } -> visit arg
          | EIf { cond; then_; else_; _ } ->
            visit cond; visit then_; visit else_
          | ECase { scrut; arms; _ } ->
            visit scrut;
            List.iter (fun (a : case_arm) ->
              (match a.guard with Some g -> visit g | None -> ());
              visit a.body) arms
          | ELet { name = n; value = v; body = b; _ } ->
            visit v;
            if n <> name then visit b
          | ELetProof { value_name; proof_name; value = v; body = b; _ } ->
            visit v;
            if value_name <> name && proof_name <> name then visit b
          | ERecord { fields; _ } ->
            List.iter (fun (_, v) -> visit v) fields
          | EList { elems; _ } -> List.iter visit elems
          | EOk { value = v; _ } -> visit v
          | EFail { message; _ } -> visit message
          | ETelemetry { fields; _ } ->
            List.iter (fun (_, v) -> visit v) fields
          | EEnqueue { payload; _ } -> visit payload
          | EPublish { key; payload; _ } ->
            (match key with Some k -> visit k | None -> ());
            (match payload with Some p -> visit p | None -> ())
          | EWithDatabase { body = b; _ }
          | EWithCapabilities { body = b; _ }
          | EWithTransaction { body = b; _ } -> visit b
          | EServe { port; _ } -> visit port
          | EConstructor { args; _ } -> List.iter visit args
          | ELambda { params = ps; body = b; _ } ->
            if not (List.exists (fun (p : binding) -> p.name = name) ps)
            then visit b
          | ELit _ | EVar _ | EStartWorkers _ -> ()
          | ECacheGet _ | ECacheDelete _ | ECacheInvalidate _ -> ()
          | ECacheSet { value; _ } -> visit value
          | ESendEmail _ | EStartEmailWorker _ -> ()
          | ERuntimeCall { segments; _ } ->
            List.iter (function RLit _ | RRawVar _ -> () | RArg e -> visit e) segments
        in
        visit body;
        let non_call_errors =
          match !non_call_loc with
          | Some l ->
            [ make_error l
                ~hint:(Printf.sprintf
                  "wrap the lambda in a fresh `fn(...) -> ...` that re-validates the proof with `check`, or call the original lambda directly at its use site"
                  )
                (Printf.sprintf
                  "lambda alias `%s` has proof-annotated parameters and cannot be passed around — doing so would bypass the proof check"
                  name) ]
          | None -> []
        in
        !call_errors_ref @ non_call_errors
      | _ -> []
    in
    let value_errors = laundering_errors @ let_lambda_errors @ check_expr_call_proofs subject_env proof_env funcs value in
    let subject_env' = match subject_of_expr subject_env value with
      | Some subject -> (name, subject) :: subject_env
      | None ->
        (* For check/establish function calls (RetAttached returns), the result IS the
           first argument (same value with proof). Propagate its subject so cross-parameter
           proof validation works correctly (e.g. requiresPositiveX raw checked). *)
        (match value with
         | EApp _ ->
           let (head, args) = collect_call_head_and_args [] value in
           (match function_name_of_expr head with
            | Some "check" ->
              (* `check fn arg` — fn is first arg, real arg is second *)
              (match args with
               | fn_expr :: rest_args ->
                 (match function_name_of_expr fn_expr with
                  | Some fn_name ->
                    (match List.assoc_opt fn_name funcs with
                     | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                       (* Use the arg corresponding to the return binding's param name *)
                       let binding_arg = match info.fi_return with
                         | RetAttached { binding = b; _ } ->
                           (* Find which param index has binding's name, use that arg *)
                           let rec find_idx i = function
                             | [] -> None
                             | (p : binding) :: _ when p.name = b.name ->
                               if i < List.length rest_args then Some (List.nth rest_args i) else None
                             | _ :: rest -> find_idx (i+1) rest
                           in
                           (match find_idx 0 info.fi_params with
                            | Some arg -> Some arg
                            | None -> match rest_args with x :: _ -> Some x | [] -> None)
                         | _ -> match rest_args with x :: _ -> Some x | [] -> None
                       in
                       (match binding_arg with
                        | Some arg ->
                          (match subject_of_expr subject_env arg with
                           | Some s -> (name, s) :: subject_env
                           | None -> subject_env)
                        | None -> subject_env)
                     | _ -> subject_env)
                  | None ->
                     (* Combined check: (checkA && checkB) real_arg.
                        fn_expr is an EBinop BAnd, not a simple function name.
                        The real argument is the first element of rest_args.
                        Propagate its subject to the let-binder so that
                        later calls like `needsBoth v` can resolve proofs. *)
                     (match rest_args with
                      | real_arg :: _ ->
                        (match subject_of_expr subject_env real_arg with
                         | Some s -> (name, s) :: subject_env
                         | None -> subject_env)
                      | [] -> subject_env))
               | [] -> subject_env)
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                 (* Use the arg that corresponds to the return binding's param name, NOT
                    always the first arg.  For single-param checks both are the same, but
                    for multi-param checks like isInRange(lo,hi,n)->n:T:::P, the relevant
                    arg is the one bound to `n` (3rd), not `lo` (1st). *)
                 let binding_arg = match info.fi_return with
                   | RetAttached { binding = b; _ } ->
                     let rec find_idx i = function
                       | [] -> None
                       | (p : binding) :: _ when p.name = b.name ->
                         if i < List.length args then Some (List.nth args i) else None
                       | _ :: rest -> find_idx (i+1) rest
                     in
                     (match find_idx 0 info.fi_params with
                      | Some arg -> Some arg
                      | None -> (match args with x :: _ -> Some x | [] -> None))
                   | _ -> (match args with x :: _ -> Some x | [] -> None)
                 in
                 (match binding_arg with
                  | Some arg ->
                    (match subject_of_expr subject_env arg with
                     | Some s -> (name, s) :: subject_env
                     | None -> subject_env)
                  | None -> subject_env)
               | _ -> subject_env)
            | None ->
              (* Combined check: (checkA && checkB) arg — no "check" wrapper.
                 Propagate the argument subject to the let-binder. *)
              (match head with
               | EBinop { op = BAnd; _ } ->
                 (match args with
                  | subj_arg :: _ ->
                    (match subject_of_expr subject_env subj_arg with
                     | Some s -> (name, s) :: subject_env
                     | None -> subject_env)
                  | [] -> subject_env)
               | _ -> subject_env))
         | _ -> subject_env)
    in
    let new_proofs = proofs_of_expr name funcs subject_env proof_env value in
    (* Collect all atom names used as arguments in a proof expression. *)
    let rec proof_arg_names = function
      | PredApp { args; _ } -> args
      | PredAnd { left; right; _ } -> proof_arg_names left @ proof_arg_names right
    in
    let check_proof_annotation required =
      (* Most aliases inside a declared proof should resolve to their tracked
         subjects (e.g. `admin` → `adminStr`), but the binding being introduced
         may legitimately remain as the fresh result name (e.g. named-pack
         entity proofs such as `IsPositive result`). Accept either form. *)
      let normalize_required subject_env =
        normalize_proof_aliases proof_env
          (subst_proof_args_with_subjects subject_env required)
      in
      let subject_env_without_name =
        List.filter (fun (candidate, _) -> candidate <> name) subject_env' in
      let required_candidates = [
        normalize_required subject_env';
        normalize_required subject_env_without_name;
      ] in
      let new_proofs = List.map Proof_kernel.fact_of new_proofs in
      if List.exists (fun required' -> proof_matches required' new_proofs) required_candidates then []
      else
        let carried =
          match new_proofs with
          | [] -> "no tracked proofs"
          | proofs -> String.concat ", " (List.map pp_proof proofs)
        in
        [ make_error loc
            ~hint:(Printf.sprintf
              "bind a value that carries `%s`, or remove the incorrect annotation"
              (pp_proof required))
            (Printf.sprintf
              "let binding `%s` declares proof `%s`, but the bound expression carries %s"
              name (pp_proof required) carried) ]
    in
    let check_fact_annotation_proof proof fact_loc =
      (* Reject self-referential annotations: `let proof: Fact (NonEmpty proof)` is
         nonsensical because `proof` names the Fact holder, not the value being proven. *)
      if List.mem name (proof_arg_names proof) then
        [ make_error fact_loc
            ~hint:"the proof argument should name the proof-carrying value (e.g. the result of a `check …`), not the binding being defined"
            (Printf.sprintf
              "`%s` is used as both the binding name and a proof argument; \
               `Fact (P x)` describes a fact about `x`, not about the `Fact` holder itself"
              name) ]
      else
        check_proof_annotation proof
    in
    let declared_proof_errors =
      match declared_proof with
      | Some required -> check_proof_annotation required
      | None ->
        (* Also validate Fact(P) type annotations: `let x: Fact (P) = ...` *)
        (match declared_type with
         | Some (TApp { head = TName { name = "Fact"; _ }; arg; loc = fact_loc }) ->
           (match type_expr_to_proof_expr arg with
            | Some proof -> check_fact_annotation_proof proof fact_loc
            | None -> [])
         | Some (TName { name = "Fact"; loc = fact_loc }) ->
           (* Bare `Fact` without a proof argument is always invalid. *)
           [ make_error fact_loc
               ~hint:"write `Fact (P)` e.g. `Fact (NonEmpty x)` to name the proof"
               (Printf.sprintf
                 "bare `Fact` is not a valid type annotation for `%s`; \
                  a proof argument is required" name) ]
         | _ -> [])
    in
    let proof_env' = if new_proofs = [] then proof_env else (name, new_proofs) :: proof_env in
    value_errors @ declared_proof_errors @ check_expr_call_proofs subject_env' proof_env' funcs body
  | ELetProof { value_name; proof_name; proof_index; value; body; loc } ->
    let value_errors = check_expr_call_proofs subject_env proof_env funcs value in
    let subject_env' = match subject_of_expr subject_env value with
      | Some subject -> (value_name, subject) :: subject_env
      | None ->
        (* For check-fn calls (RetAttached), propagate the subject of the
           return-bound argument — same logic as the ELet handler. *)
        (match value with
         | EApp _ ->
           let (head0, args0) = collect_call_head_and_args [] value in
           let (_head, args) = normalize_explicit_check_call head0 args0 in
           (match function_name_of_expr _head with
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                 let binding_arg = match info.fi_return with
                   | RetAttached { binding = b; _ } ->
                     let rec find_idx i = function
                       | [] -> None
                       | (p : binding) :: _ when p.name = b.name ->
                         if i < List.length args then Some (List.nth args i) else None
                       | _ :: rest -> find_idx (i+1) rest
                     in
                     (match find_idx 0 info.fi_params with
                      | Some arg -> Some arg
                      | None -> (match args with x :: _ -> Some x | [] -> None))
                   | _ -> (match args with x :: _ -> Some x | [] -> None)
                 in
                 (match binding_arg with
                  | Some arg ->
                    (match subject_of_expr subject_env arg with
                     | Some s -> (value_name, s) :: subject_env
                     | None -> subject_env)
                  | None -> subject_env)
               | _ -> subject_env)
            | None -> subject_env)
         | _ -> subject_env)
    in
    (* Use proofs_of_expr (not carried_proofs_of_expr) so that function-call
       return proofs are included — carried_proofs_of_expr can't derive proofs
       from arbitrary EApp calls like checkPosAndSmall n1. *)
    let detached_proofs =
      let carried = match carried_proofs_of_expr ~funcs subject_env proof_env value with
        | Some proofs -> proofs
        | None -> []
      in
      let () = record_entity_binder value_name value in
      let effective = effective_value_name value_name value in
      let full =
        if carried <> [] then carried
        else proofs_of_expr effective funcs subject_env' proof_env value
      in
      (* Flatten any top-level `P && Q && R` proofs so that each conjunct
         is its own element in the list.  Without this, a single
         `PredAnd { left; right }` element would be treated as one atom
         and EVERY positional binder in an `&&` decomposition would get
         back the full compound proof — a soundness hole that lets
         `let (_ ::: p && q) = (a ::: A && B)` bind both `p` and `q` to
         `A && B` instead of to `A` and `B` separately. *)
      (* Split each carried conjunction fact into its leaf conjuncts through the
         kernel (conjunction-elimination), so `let (x ::: p && q) = (a ::: A && B)`
         binds p and q to A and B separately rather than both to `A && B`. *)
      let full = List.concat_map Proof_kernel.conj_split full in
      (* Deduplicate: `let (x ::: p && q) = val` where val is `raw ::: lp && rp`
         would otherwise accumulate both the carried proofs of `raw` and the
         extra proofs on the annotation, producing duplicates that defeat
         the positional projection below. *)
      let rec dedup_by_key seen = function
        | [] -> []
        | p :: rest ->
          let k = proof_key (Proof_kernel.fact_of p) in
          if List.mem k seen then dedup_by_key seen rest
          else p :: dedup_by_key (k :: seen) rest
      in
      let full = dedup_by_key [] full in
      (* If this binder is one slot of an `&&` decomposition, pick the
         positional conjunct instead of handing the full proof set to every
         name.  `let (x ::: p && q) = val` — per LANGUAGE-SPEC / lesson09 —
         binds p to the left conjunct and q to the right conjunct. *)
      match proof_index with
      | Some (i, arity) when arity > 1 ->
        if List.length full = arity && i < arity then [List.nth full i]
        else if full = [] then []
        else
          (* Arity mismatch after dedup — unusual; fall back to full to avoid
             losing proof info, but this now only happens when the RHS truly
             provides an unexpected number of distinct proofs. *)
          full
      | _ -> full
    in
    (* Validate that the value actually carries at least one proof — if we can
       determine statically that it carries none, report an error. *)
    let no_proof_errors =
      match carried_proofs_of_expr ~funcs subject_env proof_env value with
      | Some [] ->
        [ make_error loc
            ~hint:(Printf.sprintf
              "use `attachFact` or a check function to attach a proof before destructuring with `%s ::: %s`"
              value_name proof_name)
            (Printf.sprintf
              "proof destructuring `let (%s ::: %s) = ...` requires at least one attached proof, \
               but the value carries none" value_name proof_name) ]
      | _ -> []
    in
    let proof_env' = if detached_proofs = [] then proof_env else (proof_name, detached_proofs) :: proof_env in
    value_errors @ no_proof_errors @ check_expr_call_proofs subject_env' proof_env' funcs body
  | ECase { scrut; arms; _ } ->
    let scrut_errors = check_expr_call_proofs subject_env proof_env funcs scrut in
    (* For `case (establish_fn arg) of Something proof ->`, the `proof` binding
       carries the inner proof from the establish function's Maybe (Fact P) return.
       Also handles user ADT round-trips: `let m = Something p; case m of Something x ->`
       where x should inherit p's proofs via subject aliasing. *)
    (* Use a sentinel result name for non-variable scrutinees so that named-return
       proofs like `Maybe (r: T ::: ForAll P r)` get a trackable subject.
       For EVar scrutinees the result_name is irrelevant (carried_proofs_of_expr
       uses the variable's own proof_env entry directly).  For call expressions the
       sentinel will be substituted with the pattern-bound name below. *)
    let scrut_result_name = match scrut with
      | EVar { name; _ } -> name
      | _ -> "_case_scrut"
    in
    let scrut_proofs = proofs_of_expr scrut_result_name funcs subject_env proof_env scrut in
    let arm_errors = List.concat_map (fun (arm : case_arm) ->
      let proof_env', subject_env' = match arm.pattern with
        | PCon { fields = [(_, PVar x)]; _ } ->
          (* Any single-field constructor: propagate scrutinee's proofs and subject chain
             to the bound variable x. This enables proof tracking through constructor
             round-trips: `let m = Something p; case m of Something x -> requiresP x`.
             For direct call scrutinees the sentinel result name is substituted with x
             so that `ForAll P _case_scrut` becomes `ForAll P x`.
             We fully resolve the subject chain (m→p→n) so that call-site substitution
             maps the proof subject correctly (Positive n, not Positive p). *)
          let scrut_proofs_for_x =
            if scrut_result_name = "_case_scrut" then
              List.map (Proof_kernel.pass_through (subst_proof [("_case_scrut", x)])) scrut_proofs
            else scrut_proofs
          in
          let penv = if scrut_proofs_for_x <> [] then (x, scrut_proofs_for_x) :: proof_env else proof_env in
          let senv =
            (* Fully follow the subject_env chain to the final canonical subject.
               e.g. m→p→n resolves to "n", which is what x's call-site subject must be.
               When the chain doesn't extend (e.g. m has no subject alias), fall back to
               the subject described by the carried proofs themselves — e.g. if scrut_proofs
               contain `IsPositive raw`, use "raw" as x's subject so that `needPos x`
               resolves to `IsPositive raw` (matching the carried proof). *)
            let rec resolve_chain seen name =
              if List.mem name seen then name  (* cycle guard *)
              else match List.assoc_opt name subject_env with
                | Some s when s <> name -> resolve_chain (name :: seen) s
                | _ -> name
            in
            let chain_subj = match scrut with
              | EVar { name; _ } -> resolve_chain [] name
              | _ -> (match subject_of_expr subject_env scrut with Some s -> s | None -> x)
            in
            (* If the chain didn't extend beyond the scrutinee name, try to find
               the ultimate subject from the proof's own argument list. *)
            let final_subj =
              if chain_subj = (match scrut with EVar { name; _ } -> name | _ -> "") then
                (* Chain stopped at the scrutinee itself — try proof's last argument *)
                let proof_subject = List.find_map (fun p ->
                  match Proof_kernel.fact_of p with
                  | PredApp { args = (_ :: _ as pargs); _ } ->
                    let last = List.nth pargs (List.length pargs - 1) in
                    (* Only use if it's a simple lowercase identifier (a subject name) *)
                    if String.length last > 0 && last.[0] >= 'a' && last.[0] <= 'z'
                       && not (String.contains last '.')
                    then Some last
                    else None
                  | _ -> None
                ) scrut_proofs_for_x in
                (match proof_subject with
                 | Some s -> resolve_chain [] s  (* follow the chain from the proof's subject *)
                 | None -> chain_subj)
              else chain_subj
            in
            if final_subj <> x then (x, final_subj) :: subject_env
            else subject_env
          in
          (penv, senv)
        | _ -> (proof_env, subject_env)
      in
      (* PFC-2 (a): propagate CONSTRUCTOR FIELD proofs to pattern binders,
         positionally.  `case t of Node l cur r -> …` gives `cur` the `value`
         field's `::: P` proof (subject renamed field_name -> binder).  Sound
         because field proofs are now enforced at construction (PFC-2b / a0). *)
      let proof_env', subject_env' = match arm.pattern with
        | PCon { ctor; fields; _ } ->
          (match List.assoc_opt ctor !ctor_field_proof_registry with
           | Some fps when List.length fps = List.length fields ->
             List.fold_left2 (fun (penv, senv) (fname, proof_opt) (_lbl, pat) ->
               match proof_opt, pat with
               | Some proof, PVar var ->
                 ((var, [Proof_kernel.elaborated Proof_kernel.FieldProof
                           (subst_proof [(fname, var)] proof)]) :: penv,
                  (var, var) :: senv)
               | _ -> (penv, senv)
             ) (proof_env', subject_env') fps fields
           | _ -> (proof_env', subject_env'))
        | _ -> (proof_env', subject_env')
      in
      check_expr_call_proofs subject_env' proof_env' funcs arm.body
    ) arms in
    scrut_errors @ arm_errors
  | EBinop { op = (BDiv | BMod) as op; left; right; loc; _ } ->
    let child_errors =
      check_expr_call_proofs subject_env proof_env funcs left
      @ check_expr_call_proofs subject_env proof_env funcs right
    in
    (* The / and % operators require the divisor to carry an IsNonZero proof *)
    let op_name = match op with BDiv -> "/" | BMod -> "%" | _ -> "?" in
    let div_errors = match right with
      | ELit { lit = LInt 0; loc = lit_loc }
      | ELit { lit = LFloat 0.0; loc = lit_loc } ->
        [ make_error lit_loc
            ~hint:"use a non-zero literal, or use `check Int.nonZero` to validate the divisor"
            (Printf.sprintf "division by zero: the right operand of `%s` is literally 0" op_name) ]
      | ELit { lit = (LInt _ | LFloat _); _ } ->
        (* Non-zero literal — statically safe *)
        []
      | EVar { name; _ } ->
        let subject = match List.assoc_opt name subject_env with Some s -> s | None -> name in
        let carried = match List.assoc_opt subject proof_env with Some proofs -> proofs | None ->
          match List.assoc_opt name proof_env with Some proofs -> proofs | None -> [] in
        (* B6: decide over the RESOLVED predicate identity, not a rendered-string
           prefix.  The old `String.sub key 0 9 = "IsNonZero"` also matched any
           predicate whose NAME merely starts with "IsNonZero" (e.g. a
           user-declared `IsNonZeroish`), and only inspected the top node of a
           PredAnd.  flatten_proof + exact pred match over the full nonzero
           family is the structural form. `Int.nonZero` mints `IsNonZero`;
           `Float.requireNonZero` mints `FloatNonZero` — both mean "safe divisor". *)
        let has_nonzero = List.exists (fun p ->
          List.exists (function
            | PredApp { pred = ("IsNonZero" | "FloatNonZero"); _ } -> true
            | _ -> false)
            (flatten_proof (Proof_kernel.fact_of p))
        ) carried in
        if has_nonzero then []
        else
          [ make_error loc
              ~hint:(Printf.sprintf "use `let checked = check Int.nonZero %s` then `%s` the checked value" name op_name)
              (Printf.sprintf "the right operand of `%s` (`%s`) has no `IsNonZero` proof; division may crash at runtime"
                 op_name name) ]
      | _ ->
        [ make_error loc
            ~hint:(Printf.sprintf "bind the divisor to a named variable, then use `check Int.nonZero` before `%s`" op_name)
            (Printf.sprintf "the right operand of `%s` is an expression with no trackable `IsNonZero` proof" op_name) ]
    in
    child_errors @ div_errors
  | ELambda { params; body; _ } ->
    (* Inject lambda parameter proofs into proof_env so callee's proof
       requirements can be satisfied by explicitly-annotated lambda params.
       e.g. `fn(x: Int ::: Positive x) -> double x` needs proof_env["x"] = [Positive x] *)
    let proof_env' = List.fold_left (fun acc (b : binding) ->
      match b.proof_ann with
      | None -> acc
      | Some proof ->
        (b.name, List.map Proof_kernel.assume_param (flatten_proof_conj proof)) :: acc
    ) proof_env params in
    check_expr_call_proofs subject_env proof_env' funcs body
  (* Explicit no-obligation LEAVES.  EField is deliberately a leaf here (it does
     NOT descend into its [obj]): the original arm returned [] and that omission
     is load-bearing — qualified-name field accesses like `Module.fn` are not
     call sites and carry no proof obligation, so we must NOT start walking into
     [obj].  EVar/ELit/EFail/EStartWorkers/EStartEmailWorker have no proof-bearing
     children either. *)
  | ELit _ | EVar _ | EField _ | EFail _ | EStartWorkers _ | EStartEmailWorker _ -> []
  (* Purely-MECHANICAL structural descent: thread the SAME (subject_env, proof_env,
     funcs) context UNCHANGED into every immediate child and concatenate the
     resulting error lists left-to-right.  Migrated onto the shared
     {!Ast_visitor.fold_children_env} (Wave-2 visitor consolidation) so a new
     {!Ast.expr} variant cannot silently escape proof-call checking.

     This fall-through covers exactly the variants whose old hand-rolled arms did
     nothing but recurse with the unchanged env: EApp's argument/sub-walks are
     handled in the dedicated EApp arm above; the remaining mechanical forms are
     EIf, EBinop (non Div/Mod — Div/Mod has the div-by-zero arm above), EUnop,
     EList, ERecord, EOk, ETelemetry, EEnqueue, EPublish, EWithDatabase/
     EWithCapabilities/EWithTransaction, EServe, EConstructor, the four cache
     forms, and ESendEmail.  fold_children_env visits children in the identical
     left-to-right order the explicit arms used, so the concatenated error order
     (and thus diagnostic byte-identity) is preserved. *)
  | _ ->
    Ast_visitor.fold_children_env
      (fun (s, p, f) acc child -> acc @ check_expr_call_proofs s p f child)
      (subject_env, proof_env, funcs) [] e

(** In test blocks, `let x = e` compiles to a bare Racket `(define x e)`, so
    the value is NOT wrapped in a named-value.  Every time a bare integer/string
    is passed into a check function the runtime creates a *fresh* gensym for it,
    so the gensym at the check-call site and at the require-call site will differ
    and the proof match will always fail at runtime.
    To prevent the confusing runtime failure, reject inline literals (and other
    non-variable expressions) at any proof-subject position of a check function
    call inside a test block.  The user must `let`-bind the value first. *)
let check_inline_proof_args (loc : loc) (fn_name : string) (info : func_info)
    (args : expr list) : validation_error list =
  match info.fi_return with
  | RetAttached { binding = b; _ } ->
    let subj_names = match b.proof_ann with
      | Some p -> proof_subjects p
      | None   -> []
    in
    List.concat (List.mapi (fun i (param : binding) ->
      if not (List.mem param.name subj_names) then []
      else
        match List.nth_opt args i with
        | None | Some (EVar _) -> []
        | Some (ELit { loc = arg_loc; _ }) ->
          [ make_error arg_loc
              ~hint:(Printf.sprintf
                "write `let %s = <value>` on a separate line before the call, \
                 then pass `%s` instead of the inline literal"
                param.name param.name)
              (Printf.sprintf
                "argument `%s` to `%s` is at a proof-subject position; \
                 inline literals cannot be tracked as proof subjects in test blocks \
                 — use a `let` binding"
                param.name fn_name) ]
        | Some _ ->
          [ make_error loc
              ~hint:(Printf.sprintf
                "bind the expression to `let %s = ...` before passing it to `%s`"
                param.name fn_name)
              (Printf.sprintf
                "argument `%s` to `%s` is at a proof-subject position; \
                 complex expressions cannot be tracked as proof subjects in test blocks \
                 — use a `let` binding"
                param.name fn_name) ]
    ) info.fi_params)
  | _ -> []

(** Apply check_inline_proof_args to a call expression (value) in a TsLet. *)
let inline_proof_arg_errors_for_call (loc : loc)
    (funcs : (string * func_info) list) (value : expr)
    : validation_error list =
  match value with
  | EApp _ ->
    let (head, args) = collect_call_head_and_args [] value in
    (match function_name_of_expr head with
     | Some "check" ->
       (match args with
        | fn_expr :: rest_args ->
          (match function_name_of_expr fn_expr with
           | Some fn_name ->
             (match List.assoc_opt fn_name funcs with
              | Some info -> check_inline_proof_args loc fn_name info rest_args
              | None -> [])
           | None -> [])
        | [] -> [])
     | Some fn_name ->
       (match List.assoc_opt fn_name funcs with
        | Some info -> check_inline_proof_args loc fn_name info args
        | None -> [])
     | None -> [])
  | _ -> []

(** Walk test statements and check proof obligations at call sites. *)
let rec check_test_stmt_call_proofs
    (subject_env : subject_env)
    (proof_env : proof_env)
    (funcs : (string * func_info) list)
    (stmt : test_stmt)
    : validation_error list * subject_env * proof_env =
  match stmt with
  | TsLetProof { value_name; proof_names; value; _ } ->
    let value_errors = check_expr_call_proofs subject_env proof_env funcs value in
    (* For proof variable tracking, we need a meaningful result name even when
       value_name is "_".  Use the first argument's subject so that entity proofs
       in RetNamedPack get the correct subject (e.g. Positive n99 not Positive _). *)
    let first_arg_subject =
      let (_, args) = collect_call_head_and_args [] value in
      match args with
      | arg :: _ -> subject_of_expr subject_env arg
      | [] -> None
    in
    let effective_name = if value_name = "_" then
      match first_arg_subject with Some s -> s | None -> value_name
    else value_name in
    let subject_env' = match subject_of_expr subject_env value with
      | Some subject -> (effective_name, subject) :: subject_env
      | None ->
        (match first_arg_subject with
         | Some s -> (effective_name, s) :: subject_env
         | None -> subject_env)
    in
    let new_proofs = proofs_of_expr effective_name funcs subject_env' proof_env value in
    let proof_env' = List.fold_left (fun env pname ->
      if new_proofs = [] then env else (pname, new_proofs) :: env
    ) proof_env proof_names in
    let proof_env' = if new_proofs = [] then proof_env'
      else (effective_name, new_proofs) :: proof_env' in
    (value_errors, subject_env', proof_env')
  | TsLet { name; value; declared_type; declared_proof; loc; _ } ->
    let value_errors =
      check_expr_call_proofs subject_env proof_env funcs value
      @ inline_proof_arg_errors_for_call loc funcs value
    in
    let subject_env' = match subject_of_expr subject_env value with
      | Some subject -> (name, subject) :: subject_env
      | None ->
        (* For check/establish/named-pack function calls, propagate subjects.
           Mirrors the ELet case in check_expr_call_proofs. *)
        (match value with
         | EApp _ ->
           let (head, args) = collect_call_head_and_args [] value in
           (match function_name_of_expr head with
            | Some "check" ->
              (* `check fn arg` — fn is first arg, real arg is second *)
              (match args with
               | fn_expr :: rest_args ->
                 (match function_name_of_expr fn_expr with
                  | Some fn_name ->
                    (match List.assoc_opt fn_name funcs with
                     | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                       let binding_arg = match info.fi_return with
                         | RetAttached { binding = b; _ } ->
                           let rec find_idx i = function
                             | [] -> None
                             | (p : binding) :: _ when p.name = b.name ->
                               if i < List.length rest_args then Some (List.nth rest_args i) else None
                             | _ :: rest -> find_idx (i+1) rest
                           in
                           (match find_idx 0 info.fi_params with
                            | Some arg -> Some arg
                            | None -> match rest_args with x :: _ -> Some x | [] -> None)
                         | _ -> match rest_args with x :: _ -> Some x | [] -> None
                       in
                       (match binding_arg with
                        | Some arg ->
                          (match subject_of_expr subject_env arg with
                           | Some s -> (name, s) :: subject_env
                           | None -> subject_env)
                        | None -> subject_env)
                     | _ -> subject_env)
                  | None ->
                    (* Compound check: fn_expr is EBinop (&&); use first real arg as subject *)
                    (match rest_args with
                     | arg :: _ ->
                       (match subject_of_expr subject_env arg with
                        | Some s -> (name, s) :: subject_env
                        | None -> subject_env)
                     | [] -> subject_env))
               | [] -> subject_env)
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info when (match info.fi_return with RetAttached _ | RetNamedPack _ -> true | _ -> false) ->
                 (* For multi-parameter checks like checkInBounds(lo,hi,n)->n:T:::P,
                    the subject of the result is the subject of the argument that
                    corresponds to the return binding's param name (here `n`, index 2),
                    NOT always the first argument.  Mirror the find_idx logic used in
                    the ELet case of check_expr_call_proofs. *)
                 let binding_arg = match info.fi_return with
                   | RetAttached { binding = b; _ } ->
                     let rec find_idx i = function
                       | [] -> None
                       | (p : binding) :: _ when p.name = b.name ->
                         if i < List.length args then Some (List.nth args i) else None
                       | _ :: rest -> find_idx (i+1) rest
                     in
                     (match find_idx 0 info.fi_params with
                      | Some arg -> Some arg
                      | None -> (match args with x :: _ -> Some x | [] -> None))
                   | _ -> (match args with x :: _ -> Some x | [] -> None)
                 in
                 (match binding_arg with
                  | Some arg ->
                    (match subject_of_expr subject_env arg with
                     | Some s -> (name, s) :: subject_env
                     | None -> subject_env)
                  | None -> subject_env)
               | _ -> subject_env)
            | None -> subject_env)
         | _ -> subject_env)
    in
    let new_proofs = proofs_of_expr name funcs subject_env proof_env value in
    let rec proof_arg_names = function
      | PredApp { args; _ } -> args
      | PredAnd { left; right; _ } -> proof_arg_names left @ proof_arg_names right
    in
    let check_proof_annotation required =
      (* Most aliases inside a declared proof should resolve to their tracked
         subjects (e.g. `admin` → `adminStr`), but the binding being introduced
         may legitimately remain as the fresh result name (e.g. named-pack
         entity proofs such as `IsPositive result`). Accept either form. *)
      let normalize_required subject_env =
        normalize_proof_aliases proof_env
          (subst_proof_args_with_subjects subject_env required)
      in
      let subject_env_without_name =
        List.filter (fun (candidate, _) -> candidate <> name) subject_env' in
      let required_candidates = [
        normalize_required subject_env';
        normalize_required subject_env_without_name;
      ] in
      let new_proofs = List.map Proof_kernel.fact_of new_proofs in
      if List.exists (fun required' -> proof_matches required' new_proofs) required_candidates then []
      else
        let carried =
          match new_proofs with
          | [] -> "no tracked proofs"
          | proofs -> String.concat ", " (List.map pp_proof proofs)
        in
        [ make_error loc
            ~hint:(Printf.sprintf
              "bind a value that carries `%s`, or remove the incorrect annotation"
              (pp_proof required))
            (Printf.sprintf
              "let binding `%s` declares proof `%s`, but the bound expression carries %s"
              name (pp_proof required) carried) ]
    in
    let check_fact_annotation_proof proof fact_loc =
      if List.mem name (proof_arg_names proof) then
        [ make_error fact_loc
            ~hint:"the proof argument should name the proof-carrying value (e.g. the result of a `check …`), not the binding being defined"
            (Printf.sprintf
              "`%s` is used as both the binding name and a proof argument;                `Fact (P x)` describes a fact about `x`, not about the `Fact` holder itself"
              name) ]
      else
        check_proof_annotation proof
    in
    let declared_proof_errors =
      match declared_proof with
      | Some required -> check_proof_annotation required
      | None ->
        (match declared_type with
         | Some (TApp { head = TName { name = "Fact"; _ }; arg; loc = fact_loc }) ->
           (match type_expr_to_proof_expr arg with
            | Some proof -> check_fact_annotation_proof proof fact_loc
            | None -> [])
         | Some (TName { name = "Fact"; loc = fact_loc }) ->
           [ make_error fact_loc
               ~hint:"write `Fact (P)` e.g. `Fact (NonEmpty x)` to name the proof"
               (Printf.sprintf
                 "bare `Fact` is not a valid type annotation for `%s`;                   a proof argument is required" name) ]
         | _ -> [])
    in
    let proof_env' = if new_proofs = [] then proof_env else (name, new_proofs) :: proof_env in
    (value_errors @ declared_proof_errors, subject_env', proof_env')
  | TsExpect { left; right; _ } ->
    let left_errors = check_expr_call_proofs subject_env proof_env funcs left in
    let right_errors = match right with
      | Some r -> check_expr_call_proofs subject_env proof_env funcs r
      | None -> []
    in
    (left_errors @ right_errors, subject_env, proof_env)
  | TsExpectFail { fn; arg; _ } ->
    let fn_errors = check_expr_call_proofs subject_env proof_env funcs fn in
    let arg_errors = check_expr_call_proofs subject_env proof_env funcs arg in
    (fn_errors @ arg_errors, subject_env, proof_env)
  | TsExpectHasProof { fn; arg; _ } ->
    let fn_errors = check_expr_call_proofs subject_env proof_env funcs fn in
    let arg_errors = check_expr_call_proofs subject_env proof_env funcs arg in
    (fn_errors @ arg_errors, subject_env, proof_env)
  | TsProperty { body; _ } ->
    let errors = check_expr_call_proofs subject_env proof_env funcs body in
    (errors, subject_env, proof_env)
  | TsIf { cond; then_stmts; else_stmts; _ } ->
    let cond_errors = check_expr_call_proofs subject_env proof_env funcs cond in
    let then_errors = check_test_stmts_call_proofs subject_env proof_env funcs then_stmts in
    let else_errors = check_test_stmts_call_proofs subject_env proof_env funcs else_stmts in
    (cond_errors @ then_errors @ else_errors, subject_env, proof_env)
  | TsCase { scrut; arms; _ } ->
    let scrut_errors = check_expr_call_proofs subject_env proof_env funcs scrut in
    let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
    let arm_errors = List.concat_map (fun (arm : Ast.ts_case_arm) ->
      (* Propagate scrutinee proofs into the arm binding, same as ECase in
         check_expr_call_proofs: `case m of Something v ->` gives v the proof of m. *)
      let proof_env', subject_env' =
        let penv, senv = match arm.ts_pattern with
          | PCon { fields = [(_, PVar x)]; _ } ->
            let penv = if scrut_proofs <> [] then (x, scrut_proofs) :: proof_env else proof_env in
            let senv =
              let rec resolve_chain seen name =
                if List.mem name seen then name
                else match List.assoc_opt name subject_env with
                  | Some s when s <> name -> resolve_chain (name :: seen) s
                  | _ -> name
              in
              let final_subj = match scrut with
                | EVar { name; _ } -> resolve_chain [] name
                | _ -> (match subject_of_expr subject_env scrut with Some s -> s | None -> x)
              in
              if final_subj <> x then (x, final_subj) :: subject_env else subject_env
            in
            (penv, senv)
          | _ -> (proof_env, subject_env)
        in
        (penv, senv)
      in
      let guard_errors = match arm.ts_guard with
        | Some g -> check_expr_call_proofs subject_env' proof_env' funcs g
        | None -> []
      in
      let body_errors =
        check_test_stmts_call_proofs subject_env' proof_env' funcs arm.ts_body
      in
      guard_errors @ body_errors
    ) arms in
    (scrut_errors @ arm_errors, subject_env, proof_env)
  | TsExpr { e; _ } ->
    let errors = check_expr_call_proofs subject_env proof_env funcs e in
    (errors, subject_env, proof_env)

(** Walk a list of test statements, threading subject_env and proof_env. *)
and check_test_stmts_call_proofs
    (subject_env : subject_env)
    (proof_env : proof_env)
    (funcs : (string * func_info) list)
    (stmts : test_stmt list)
    : validation_error list =
  let (errors, _, _) =
    List.fold_left (fun (acc_errors, se, pe) stmt ->
      let (errs, se', pe') = check_test_stmt_call_proofs se pe funcs stmt in
      (acc_errors @ errs, se', pe')
    ) ([], subject_env, proof_env) stmts
  in
  errors

let check_call_site_proofs ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let mf = facts_or_compute ?facts ~extra_funcs decls in
  let funcs = mf.mf_funcs in
  field_proof_registry := mf.mf_field_proof_map;
  ctor_field_proof_registry := mf.mf_ctor_field_proof_map;
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      let subject_env = build_initial_subject_env fd.params in
      let proof_env = build_initial_proof_env fd.params in
      (* #6/#5 (2026-07-04): set the per-fn type context (params + let-chain +
         module field/ctor maps) so the EField arm can resolve a receiver's type
         and the Fact-param check can resolve an argument's Fact type. *)
      field_proof_type_ctx :=
        Some (fn_type_env funcs mf.mf_fields_map mf.mf_ctors fd,
              mf.mf_fields_map, mf.mf_ctors);
      errors := check_expr_call_proofs subject_env proof_env funcs fd.body @ !errors
    | DTest tf ->
      errors := check_test_stmts_call_proofs [] [] funcs tf.stmts @ !errors
    | DApiTest atf ->
      let seed_errors = List.concat_map (check_expr_call_proofs [] [] funcs) atf.seed_stmts in
      let stmt_errors = check_test_stmts_call_proofs [] [] funcs atf.stmts in
      errors := seed_errors @ stmt_errors @ !errors
    | DLoadTest ltf ->
      let seed_errors = List.concat_map (check_expr_call_proofs [] [] funcs) ltf.seed_stmts in
      let req_errors = check_test_stmts_call_proofs [] [] funcs ltf.request_stmts in
      errors := seed_errors @ req_errors @ !errors
    | _ -> ()
  ) decls;
  field_proof_registry := [];
  ctor_field_proof_registry := [];
  field_proof_type_ctx := None;
  List.rev !errors

(** Validate that every argument passed to filterCheck/allCheck/filterCheckValues/
    filterCheckKeys is a declared `check` or `auth` function (or an `&&` combination
    thereof), not a plain lambda or `fn` function.

    The runtime implementations of these functions call the argument as a check
    function and validate that the result is `check-ok` or `check-fail`.  A plain
    lambda or fn returns a raw value, which crashes at runtime with "expected
    check-ok or check-fail".  This is a compile-time soundness gap: the type system
    does not distinguish check functions from plain functions, so we enforce this
    constraint here. *)
let check_filter_check_args ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = (facts_or_compute ?facts ~extra_funcs decls).mf_funcs in
  let errors = ref [] in
  let filter_fns = [
    "List.filterCheck"; "Set.filterCheck";
    "List.allCheck"; "Set.allCheck";
    "Dict.filterCheckValues"; "Dict.filterCheckKeys";
  ] in
  (* Check that the first argument to filterCheck-family calls is a declared
     check/auth function or an && combination of them. *)
  let rec is_valid_check_arg e =
    match e with
    | EVar { name; _ } ->
      (match List.assoc_opt name funcs with
       | Some info -> info.fi_kind = CheckKind || info.fi_kind = AuthKind
       | None -> false)           (* unknown name — caught by other passes *)
    | EBinop { op = BAnd; left; right; _ } ->
      is_valid_check_arg left && is_valid_check_arg right
    | EApp { fn; _ } ->
      (* Allow partial application of check functions.
         E.g. `checkInRange 0 100` is EApp(EApp(EVar "checkInRange", 0), 100).
         Recurse into the function part to reach the base check function name. *)
      is_valid_check_arg fn
    | _ -> false
  in
  let check_fn_arg_of e =
    (* The check-function argument is the first positional arg after the fn name.
       For `List.filterCheck checkFn xs`, args = [checkFn; xs]. *)
    let (head, args) = collect_call_head_and_args [] e in
    match function_name_of_expr head with
    | Some name when List.mem name filter_fns ->
      (match args with first_arg :: _ -> Some first_arg | [] -> None)
    | _ -> None
  in
  let rec walk e =
    (match e with
     | EApp _ ->
       (match check_fn_arg_of e with
        | Some arg when not (is_valid_check_arg arg) ->
          let loc = match e with EApp { loc; _ } -> loc | _ -> gen_loc in
          let fname = match function_name_of_expr (fst (collect_call_head_and_args [] e)) with
            | Some n -> n | None -> "filterCheck"
          in
          let msg = match arg with
            | ELambda _ ->
              Printf.sprintf
                "the first argument to `%s` must be a declared `check` function, not an inline lambda; \
inline lambdas do not return the `check-ok`/`check-fail` value that `%s` requires at runtime"
                fname fname
            | EVar { name; _ } ->
              (match List.assoc_opt name funcs with
               | Some info ->
                 Printf.sprintf
                   "the first argument to `%s` is `%s` which is a `%s`, not a `check` function; \
only `check` (or `auth`) functions may be passed to `%s`"
                   fname name
                   (match info.fi_kind with
                    | FnKind -> "fn" | EstablishKind -> "establish"
                    | HandlerKind -> "handler" | WorkerKind -> "worker"
                    | DeadWorkerKind -> "deadWorker" | MainKind -> "main"
                    | CheckKind -> "check" | AuthKind -> "auth")
                   fname
               | None ->
                 Printf.sprintf
                   "the first argument to `%s` is not a declared `check` function; \
pass a `check` function or a `&&` combination of check functions"
                   fname)
            | _ ->
              Printf.sprintf
                "the first argument to `%s` must be a declared `check` function or `checkA && checkB` combination"
                fname
          in
          errors := make_error loc
            ~hint:(Printf.sprintf "replace the argument with a declared `check` function, e.g. `%s checkFn %s`"
                     fname
                     (match snd (collect_call_head_and_args [] e) with
                      | _ :: rest -> String.concat " " (List.map (fun _ -> "xs") rest)
                      | [] -> "xs"))
            msg
          :: !errors
        | _ -> ());
       let (head, args) = collect_call_head_and_args [] e in
       walk head;
       List.iter walk args
     | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ | EField _ -> ()
     | EBinop { left; right; _ } -> walk left; walk right
     | EUnop { arg; _ } -> walk arg
     | EIf { cond; then_; else_; _ } -> walk cond; walk then_; walk else_
     | ECase { scrut; arms; _ } ->
       walk scrut;
       List.iter (fun (arm : case_arm) -> walk arm.body) arms
     | ELet { value; body; _ } | ELetProof { value; body; _ } ->
       walk value; walk body
     | ERecord { fields; _ } | ETelemetry { fields; _ } ->
       List.iter (fun (_, v) -> walk v) fields
     | EList { elems; _ } -> List.iter walk elems
     | EOk { value; _ } -> walk value
     | EEnqueue { payload; _ } -> walk payload
     | EPublish { key; payload; _ } ->
       Option.iter walk key; Option.iter walk payload
     | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
     | EWithTransaction { body; _ } -> walk body
     | ELambda { body; _ } -> walk body
     | ECacheGet { key; _ } -> walk key
     | ECacheSet { key; value; ttl; _ } ->
       walk key; walk value; Option.iter walk ttl
     | ECacheDelete { key; _ } -> walk key
     | ECacheInvalidate { prefix; _ } -> walk prefix
     | ESendEmail { to_; subject; body; _ } ->
       walk to_; walk subject; walk body
     | EStartEmailWorker _ -> ()
     | ERuntimeCall { segments; _ } ->
       List.iter (function RLit _ | RRawVar _ -> () | RArg e -> walk e) segments);
  in
  List.iter (function
    | DFunc fd -> walk fd.body
    | _ -> ()
  ) decls;
  List.rev !errors

let check_forall_consistency ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = (facts_or_compute ?facts ~extra_funcs decls).mf_funcs in
  let errors = ref [] in
  (* Detect if an expression is a SQL select (which carries FromDb proofs). *)
  let rec is_sql_select e =
    match e with
    | EApp { fn; _ } -> (match fn with
      | EVar { name = ("select" | "selectOne" | "selectMany" | "selectCount" | "selectSum" | "selectMin" | "selectMax"); _ } -> true
      | _ -> is_sql_select fn)
    | EBinop { left; right; _ } -> is_sql_select left || is_sql_select right
    | _ -> false
  in
  (* Detect if an expression is a `check fn xs` / `filterCheck fn xs` call
     returning ForAll proofs.  Also threads `forall_env` so that predicates
     already carried by the input collection are included in the result. *)
  (* BUG-2 fix: extract ForAll predicates from a check function expression,
     including `&&` combinator chains like `(checkA && checkB)`.
     Returns the list of predicate names produced by the check chain. *)
  let rec preds_from_check_expr check_expr =
    match check_expr with
    | EVar { name = check_fn; _ } ->
      (match List.assoc_opt check_fn funcs with
       | Some info -> pred_names_of_return_spec info.fi_return
       | None -> [])
    | EBinop { op = BAnd; left; right; _ } ->
      List.sort_uniq String.compare (preds_from_check_expr left @ preds_from_check_expr right)
    | _ -> []
  in
  let check_call_produced_preds forall_env e =
    match e with
    | EApp _ ->
      let (head, args) = collect_call_head_and_args [] e in
      (match function_name_of_expr head with
       | Some ("List.check" | "Set.check"
              | "List.filterCheck" | "Set.filterCheck"
              | "List.allCheck" | "Set.allCheck"
              | "List.emptyForAll"
              | "Dict.filterCheckValues" | "Dict.filterCheckKeys") ->
         (match args with
          | check_fn_expr :: rest ->
            let input_preds = match rest with
              | EVar { name = coll_var; _ } :: _ ->
                (match List.assoc_opt coll_var forall_env with
                 | Some preds -> preds
                 | None -> [])
              | _ -> []
            in
            (* BUG-2: use preds_from_check_expr to handle `checkA && checkB` *)
            let check_preds = preds_from_check_expr check_fn_expr in
            List.sort_uniq String.compare (check_preds @ input_preds)
          | _ -> [])
       | Some fn_name ->
         (* For any other call, propagate ForAll predicates from known fn return specs *)
         let input_preds = match args with
           | EVar { name = coll_var; _ } :: _ ->
             (match List.assoc_opt coll_var forall_env with Some p -> p | None -> [])
           | _ -> []
         in
         let call_preds = match List.assoc_opt fn_name funcs with
           | Some info -> forall_preds_of_return_spec info.fi_return
           | None -> []
         in
         List.sort_uniq String.compare (call_preds @ input_preds)
       | None -> [])
    | _ -> []
  in
  (* Build a local ForAll-predicate environment from let bindings.
     Maps variable name → known element-level predicates it already carries.
     This lets us recognise that `filterCheck fn all` where `all` came from a
     DB select already carries `FromDb` — those don't need to come from `fn`. *)
  (* 2026-07-03 hole #16: a `check` callback's PARAMETER proof precondition was
     silently dropped by filterCheck/allCheck.  `check checkNarrow(n: Int ::: IsPositive n)
     -> n ::: IsSmall n` applied via `List.filterCheck checkNarrow xs` over a plain
     `List Int` produced a `ForAll IsSmall` collection whose elements were never
     shown to satisfy the callback's `IsPositive` precondition — and the callback
     body freely called proof-requiring fns on those unproven elements.  The old
     checks only validated what the callback PRODUCES against the return type,
     never what it REQUIRES on input, and the proof-param-callback guard was
     kind-scoped to fn/handler (omitting check).

     Fix: for every filterCheck-family call, verify the callback chain's input
     preconditions are satisfied, LEFT-TO-RIGHT, by the collection's carried
     ForAll preds PLUS the preds produced by EARLIER checks in the `&&` chain
     (this preserves the legitimate proof-combining pattern
     `filterCheck (checkA && checkB) xs`, where checkB's precondition A is
     produced by checkA). Fail-closed: an unknown collection carries nothing. *)
  let flatten_check_chain e =
    let rec go acc = function
      | EBinop { op = BAnd; left; right; _ } -> go (go acc right) left
      | EApp { fn; _ } -> go acc fn            (* partial application → base name *)
      | EVar { name; _ } -> name :: acc
      | _ -> acc
    in go [] e
  in
  let filtercheck_precond_errors forall_env check_expr rest loc =
    let input_preds = match rest with
      | EVar { name = coll; _ } :: _ ->
        (match List.assoc_opt coll forall_env with Some p -> p | None -> [])
      | _ -> []
    in
    let chain = flatten_check_chain check_expr in
    (* Only enforce when every chain entry is a known function; unknown/invalid
       callbacks are reported by check_filter_check_args, not duplicated here. *)
    if chain = [] || not (List.for_all (fun n -> List.mem_assoc n funcs) chain)
    then []
    else begin
      let available = ref (List.sort_uniq String.compare input_preds) in
      let errs = ref [] in
      List.iter (fun fn_name ->
        match List.assoc_opt fn_name funcs with
        | Some info ->
          let pre =
            List.concat_map (fun (p : binding) ->
              match p.proof_ann with Some pr -> proof_predicates pr | None -> [])
              info.fi_params
            |> List.sort_uniq String.compare
          in
          let missing = List.filter (fun p -> not (List.mem p !available)) pre in
          if missing <> [] then
            errs := make_error loc
              ~hint:(Printf.sprintf
                "each element must already carry `ForAll [%s]` before `%s` runs — \
                 establish it with an earlier `List.filterCheck`/`select`, put an \
                 earlier check producing it in the `&&` chain, or annotate the input \
                 as `List T ::: ForAll %s`"
                (String.concat ", " missing) fn_name (String.concat " " missing))
              (Printf.sprintf
                "`%s` requires each element to carry proof [%s] on input, but the \
                 collection is not known to carry `ForAll [%s]`; a check callback's \
                 input precondition is not automatically established by filterCheck/allCheck"
                fn_name (String.concat ", " pre) (String.concat ", " missing))
            :: !errs;
          available := List.sort_uniq String.compare
                         (!available @ pred_names_of_return_spec info.fi_return)
        | None -> ()
      ) chain;
      List.rev !errs
    end
  in
  let rec walk forall_env expected e =
    match e with
    | EApp _ ->
      let (head, args) = collect_call_head_and_args [] e in
      (* hole #16 precondition check — fires for EVERY filterCheck-family call,
         independent of the return type (`expected`). *)
      (match function_name_of_expr head with
       | Some ("List.filterCheck" | "Set.filterCheck"
              | "List.allCheck" | "Set.allCheck"
              | "Dict.filterCheckValues" | "Dict.filterCheckKeys") ->
         (match args with
          | check_expr :: rest ->
            let loc = match e with EApp { loc; _ } -> loc | _ -> gen_loc in
            errors := List.rev_append
                        (filtercheck_precond_errors forall_env check_expr rest loc)
                        !errors
          | _ -> ())
       | _ -> ());
      (match function_name_of_expr head, expected with
       | (Some "List.filterCheck" | Some "Set.filterCheck"
         | Some "Dict.filterCheckValues" | Some "Dict.filterCheckKeys"), Some wanted
       | (Some "List.allCheck" | Some "Set.allCheck"), Some wanted
       | (Some "List.emptyForAll"), Some wanted ->
         (* BUG-2: handle both `EVar check_fn` and `EBinop BAnd (checkA && checkB)` *)
         let check_fn_loc = match args with
           | EVar { loc; _ } :: _ -> loc
           | EBinop { loc; _ } :: _ -> loc
           | _ -> gen_loc
         in
         (match args with
          | check_fn_expr :: rest ->
            (* Predicates already carried by the input collection. *)
            let input_preds = match rest with
              | EVar { name = coll_var; _ } :: _ ->
                (match List.assoc_opt coll_var forall_env with
                 | Some preds -> preds
                 | None -> [])
              | _ -> []
            in
            let produced_preds = preds_from_check_expr check_fn_expr in
            if produced_preds <> [] then begin
              let required_preds = proof_predicates wanted in
              (* Available = what the check fn(s) produce + what the input already has. *)
              let available_preds = List.sort_uniq String.compare (produced_preds @ input_preds) in
              let missing = List.filter (fun pred -> not (List.mem pred available_preds)) required_preds in
              if missing <> [] then begin
                let produced = String.concat ", " produced_preds in
                let required = String.concat ", " required_preds in
                let missing_s = String.concat ", " missing in
                let check_fn_str = match check_fn_expr with
                  | EVar { name; _ } -> name
                  | EBinop _ -> "(check combination)"
                  | _ -> "?"
                in
                errors := make_error check_fn_loc
                  ~hint:(Printf.sprintf "use a check function that produces all of [%s], e.g. one returning `x ::: %s x`" missing_s required)
                  (Printf.sprintf "%s uses `%s` (produces `[%s]`) but the surrounding return type requires `[%s]` — missing `[%s]`"
                     (match function_name_of_expr head with Some n -> n | None -> "filterCheck")
                     check_fn_str produced required missing_s)
                  :: !errors
              end
            end else begin
              (* No known predicates — for single EVar, report unknown check fn *)
              match check_fn_expr with
              | EVar { name = check_fn; loc } when List.assoc_opt check_fn funcs = None ->
                errors := make_error loc
                  ~hint:"use a declared check function"
                  (Printf.sprintf "`%s` is not a known check function" check_fn)
                  :: !errors
              | _ -> ()
            end
          | _ -> ())
       | _ -> ());
      (* Additional check for non-filterCheck expressions at ForAll return position *)
      (match function_name_of_expr head, expected with
       | (Some "List.filterCheck" | Some "Set.filterCheck"
         | Some "List.allCheck" | Some "Set.allCheck"
         | Some "List.emptyForAll"
         | Some "Dict.filterCheckValues" | Some "Dict.filterCheckKeys"), _ -> ()
       | _, Some wanted ->
         let required_preds = proof_predicates wanted in
         if is_sql_select e then begin
           (* A bare SQL select only establishes FromDb — flag any other required preds *)
           let non_fromdb = List.filter (fun p -> p <> "FromDb") required_preds in
           if non_fromdb <> [] then
             let loc = (match e with EApp { loc; _ } -> loc | _ -> gen_loc) in
             errors := make_error loc
               ~hint:(Printf.sprintf
                 "add `List.filterCheck <checkFn>` after the select to verify each element satisfies [%s]"
                 (String.concat ", " non_fromdb))
               (Printf.sprintf
                 "SQL select only establishes `FromDb`; return type requires `ForAll [%s]` — add a `List.filterCheck` call"
                 (String.concat ", " required_preds))
             :: !errors
         end else begin
           (* For a known function call, verify its return is ForAll-compatible *)
           (match function_name_of_expr head with
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info ->
                 let call_preds = forall_preds_of_return_spec info.fi_return in
                 if call_preds <> [] then begin
                   let missing = List.filter (fun p -> not (List.mem p call_preds)) required_preds in
                   if missing <> [] then
                     let loc = (match e with EApp { loc; _ } -> loc | _ -> gen_loc) in
                     errors := make_error loc
                       ~hint:(Printf.sprintf
                         "`%s` produces ForAll [%s]; add a `List.filterCheck` step to also prove [%s]"
                         fn_name (String.concat ", " call_preds) (String.concat ", " missing))
                       (Printf.sprintf
                         "`%s` produces `ForAll [%s]` but return type requires `ForAll [%s]` — missing [%s]"
                         fn_name (String.concat ", " call_preds)
                         (String.concat ", " required_preds) (String.concat ", " missing))
                     :: !errors
                 end else if required_preds <> [] then begin
                   let loc = (match e with EApp { loc; _ } -> loc | _ -> gen_loc) in
                   errors := make_error loc
                     ~hint:(Printf.sprintf
                       "`%s` does not return a `ForAll`-annotated collection; pass the result through `List.filterCheck` or use a function that already returns the required proof"
                       fn_name)
                     (Printf.sprintf
                       "`%s` does not return a `ForAll`-annotated collection but return type requires `ForAll [%s]`"
                       fn_name (String.concat ", " required_preds))
                   :: !errors
                 end
               | None ->
                 (* Unknown/stdlib named function at a ForAll return position.  It
                    is NOT a recognised ForAll-producing combinator (those are
                    handled above), it is not a SQL select, and we have no
                    ForAll-carrying return spec for it — so it CANNOT discharge the
                    pending per-element obligation.  Fail CLOSED (review 2.6):
                    previously skipped, which let e.g. `List.reverse xs` forge
                    `ForAll P` that it never establishes. *)
                 if required_preds <> [] then
                   let loc = (match e with EApp { loc; _ } -> loc | _ -> gen_loc) in
                   errors := make_error loc
                     ~hint:(Printf.sprintf
                       "route the collection through `List.filterCheck <checkFn>` (or a \
                        function whose return type declares `ForAll [%s]`) so every element is proven"
                       (String.concat ", " required_preds))
                     (Printf.sprintf
                       "`%s` does not establish `ForAll [%s]`: it is not a recognised \
                        ForAll-producing combinator (filterCheck/allCheck/emptyForAll) and \
                        does not declare a `ForAll` return — a plain list transform \
                        (map/reverse/take/…) carries no per-element proof"
                       fn_name (String.concat ", " required_preds))
                     :: !errors)
            | None ->
              (* Head is not a simple function name (e.g. call through a field or
                 lambda) at a ForAll return position — likewise cannot discharge
                 the obligation.  Fail CLOSED (review 2.6). *)
              if required_preds <> [] then
                let loc = (match e with EApp { loc; _ } -> loc | _ -> gen_loc) in
                errors := make_error loc
                  ~hint:(Printf.sprintf
                    "route the collection through `List.filterCheck <checkFn>` so every element satisfies [%s]"
                    (String.concat ", " required_preds))
                  (Printf.sprintf
                    "this expression does not establish `ForAll [%s]` — only \
                     filterCheck/allCheck/emptyForAll, a SQL select, or a function \
                     declaring a `ForAll` return can"
                    (String.concat ", " required_preds))
                  :: !errors)
         end
       | _ -> ());
      List.iter (walk forall_env None) args
    | ELet { name; value; body; _ } ->
      walk forall_env None value;
      (* Track ForAll predicates for this binding so nested filterCheck calls can use them. *)
      let elem_preds =
        if is_sql_select value then ["FromDb"]
        else check_call_produced_preds forall_env value
      in
      let forall_env' = if elem_preds = [] then forall_env else (name, elem_preds) :: forall_env in
      walk forall_env' expected body
    | ELetProof { value_name; value; body; _ } ->
      walk forall_env None value;
      let elem_preds =
        if is_sql_select value then ["FromDb"]
        else check_call_produced_preds forall_env value
      in
      let forall_env' = if elem_preds = [] then forall_env else (value_name, elem_preds) :: forall_env in
      walk forall_env' expected body
    | EIf { then_; else_; _ } -> walk forall_env expected then_; walk forall_env expected else_
    | ECase { arms; _ } -> List.iter (fun (arm : case_arm) -> walk forall_env expected arm.body) arms
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
      walk forall_env expected body
    | EVar { name; loc } ->
      (* When a ForAll-annotated variable is returned directly, verify it carries
         all required predicates. *)
      (match expected with
       | Some wanted ->
         let var_preds = match List.assoc_opt name forall_env with
           | Some preds -> preds
           | None -> []
         in
         let required_preds = proof_predicates wanted in
         if var_preds <> [] then begin
           let missing = List.filter (fun pred -> not (List.mem pred var_preds)) required_preds in
           if missing <> [] then
             errors := make_error loc
               ~hint:(Printf.sprintf "add a `List.filterCheck` call to prove [%s] on each element before returning" (String.concat ", " missing))
               (Printf.sprintf "return value `%s` carries ForAll [%s] but return type requires [%s]"
                  name (String.concat ", " var_preds) (String.concat ", " required_preds))
             :: !errors
         end else if required_preds <> [] then
           (* Variable not in forall_env — no ForAll proof has been tracked for it *)
           errors := make_error loc
             ~hint:(Printf.sprintf
               "pass `%s` through `List.filterCheck <checkFn>` to establish the required proof, or annotate the parameter as `%s: List T ::: ForAll P %s`"
               name name name)
             (Printf.sprintf
               "variable `%s` has no tracked `ForAll` proof; cannot satisfy `ForAll [%s]` — is the collection filtered?"
               name (String.concat ", " required_preds))
           :: !errors
       | None -> ())
    | EList { elems; loc } ->
      (* §6.3 — a list LITERAL returned at a `ForAll P` position.
         A literal mints no per-element proof, so a non-empty literal cannot
         carry `ForAll P` (each element would need the proof). `[]` is allowed:
         `ForAll P []` is vacuously true. This closes the return-site smuggle
         where `[-5, -3]` satisfied `List Int ? ForAll (IsPos)`. *)
      (match expected with
       | Some wanted ->
         let required_preds = proof_predicates wanted in
         if elems <> [] && required_preds <> [] then
           errors := make_error loc
             ~hint:(Printf.sprintf
               "a list literal cannot establish `ForAll [%s]`; build the proven list with `List.filterCheck`/`List.allCheck`/a `select` (or return `[]`, which satisfies ForAll vacuously)"
               (String.concat ", " required_preds))
             (Printf.sprintf
               "list literal does not establish `ForAll [%s]` — a literal mints no per-element proof, so every element is unproven"
               (String.concat ", " required_preds))
           :: !errors
       | None -> ())
    (* S9-EField: a record field access carries no per-element ForAll proof —
       proof_expr has NO ForAll variant, so ForAll lives only on bindings/returns
       produced by filterCheck/allCheck/select, never on a record field.  Hence
       `w.items` at a `ForAll`-return position is always an unproven smuggle;
       reject it, mirroring the bare-var and list-literal cases above. *)
    | EField { field; loc; _ } ->
      (match expected with
       | Some wanted ->
         let required_preds = proof_predicates wanted in
         if required_preds <> [] then
           errors := make_error loc
             ~hint:(Printf.sprintf
               "a record field access cannot carry `ForAll [%s]` (fields hold plain \
                values); build the proven list with `List.filterCheck`/`List.allCheck`/a \
                `select` and return that"
               (String.concat ", " required_preds))
             (Printf.sprintf
               "field access `.%s` does not establish `ForAll [%s]` — a field access \
                carries no per-element proof, so every element is unproven"
               field (String.concat ", " required_preds))
           :: !errors
       | None -> ())
    (* S9: enumerate the remaining variants explicitly (no `_`) so adding a new
       Ast.expr variant becomes a COMPILE error here rather than silently
       escaping this ForAll-consistency walk.  None of these are ForAll-producing
       / ForAll-return-tail forms, so their behaviour is unchanged (no descent). *)
    | ELit _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _
    | EBinop _ | EUnop _ | ERecord _ | ETelemetry _ | EOk _ | EEnqueue _
    | EPublish _ | ELambda _ | ECacheGet _ | ECacheSet _ | ECacheDelete _
    | ECacheInvalidate _ | ESendEmail _ | EStartEmailWorker _ | ERuntimeCall _ -> ()
  in
  (* A `ForAll (P1 && P2) xs` proof annotation is stored as
     `PredApp { pred="ForAll"; args=["(P1 && P2)"; "xs"] }` — the inner
     conjunction lives in the first arg as a string.  Recover it as a proper
     `proof_expr` (a left-assoc PredAnd chain of bare PredApps) so that
     `proof_predicates`/`walk` see the element predicates [P1; P2].
     This is how `Maybe (xs: List T ::: ForAll (P) xs)` returns expose their
     ForAll obligation — they parse to RetMaybeAttached, not RetMaybeForAll. *)
  let forall_inner_proof_of_ann (p : proof_expr) : proof_expr option =
    match p with
    | PredApp { pred = ("ForAll" | "ForAllValues" | "ForAllKeys"); args = inner_pred :: _; loc } ->
      let names =
        String.split_on_char ' '
          (String.concat "" (List.map (fun c ->
             match c with '(' | ')' -> "" | c -> String.make 1 c)
             (List.of_seq (String.to_seq inner_pred))))
        |> List.filter (fun s -> s <> "" && s <> "&&")
      in
      (match names with
       | [] -> None
       | first :: rest ->
         Some (List.fold_left
                 (fun acc n -> PredAnd { left = acc; right = PredApp { pred = n; args = []; loc }; loc })
                 (PredApp { pred = first; args = []; loc }) rest))
    | _ -> None
  in
  List.iter (function
    | DFunc fd ->
      let expected = match fd.return_spec with
        | RetForAll { proof; _ }
        | RetMaybeForAll { proof; _ }
        | RetSetForAll { proof; _ }
        | RetMaybeSetForAll { proof; _ }
        | RetForAllDictValues { proof; _ }
        | RetForAllDictKeys { proof; _ } -> Some proof
        (* `Maybe (xs: List T ::: ForAll (P) xs)` / `name: T ::: ForAll (P) xs`
           parse to RetMaybeAttached / RetAttached with a ForAll proof_ann;
           extract the same element-predicate obligation so allCheck/filterCheck
           returns are validated here too (GAP-ALLCHECK-RET). *)
        | RetMaybeAttached { binding = { proof_ann = Some pa; _ }; _ }
        | RetAttached { binding = { proof_ann = Some pa; _ }; _ } ->
          forall_inner_proof_of_ann pa
        | _ -> None
      in
      (* Seed forall_env with predicates already on ForAll-annotated parameters. *)
      let init_env = List.filter_map (fun (b : binding) ->
        match b.proof_ann with
        | Some (PredApp { pred = "ForAll" | "ForAllValues" | "ForAllKeys"; args = [inner_pred; _]; _ }) ->
          (* Inner pred is a string like "IsActive" or "(P1 && P2)" — extract names *)
          let preds = List.filter (fun s -> s <> "") (String.split_on_char ' '
            (String.concat "" (List.map (fun c ->
              match c with '(' | ')' -> "" | c -> String.make 1 c)
              (List.of_seq (String.to_seq inner_pred))))) in
          let cleaned = List.filter (fun s -> s <> "&&" && s <> "") preds in
          if cleaned = [] then None else Some (b.name, cleaned)
        | _ -> None
      ) fd.params in
      walk init_env expected fd.body
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── 6. Exists binding proof tracking ────────────────────────────────────── *)

let rec exists_witnesses (e : expr) : string list =
  match e with
  | EApp { fn = EVar { name = "make-witness"; _ };
           arg = EApp { fn = EVar { name = witness; _ }; arg = body; _ }; _ } ->
    witness :: exists_witnesses body
  | EApp { fn; arg; _ } -> exists_witnesses fn @ exists_witnesses arg
  | ELet { value; body; _ } | ELetProof { value; body; _ } -> exists_witnesses value @ exists_witnesses body
  | EIf { cond; then_; else_; _ } -> exists_witnesses cond @ exists_witnesses then_ @ exists_witnesses else_
  | ECase { scrut; arms; _ } -> exists_witnesses scrut @ List.concat_map (fun (arm : case_arm) -> exists_witnesses arm.body) arms
  | EBinop { left; right; _ } -> exists_witnesses left @ exists_witnesses right
  | EUnop { arg; _ } -> exists_witnesses arg
  | ERecord { fields; _ } -> List.concat_map (fun (_, v) -> exists_witnesses v) fields
  | EList { elems; _ } -> List.concat_map exists_witnesses elems
  | EOk { value; _ } -> exists_witnesses value
  | ETelemetry { fields; _ } -> List.concat_map (fun (_, v) -> exists_witnesses v) fields
  | EEnqueue { payload; _ } -> exists_witnesses payload
  | EPublish { key; payload; _ } ->
    (match key with Some e -> exists_witnesses e | None -> [])
    @ (match payload with Some e -> exists_witnesses e | None -> [])
  | EStartWorkers _ -> []
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } -> exists_witnesses body
  | EServe { port; _ } -> exists_witnesses port
  | ELambda { body; _ } -> exists_witnesses body
  | ELit _ | EVar _ | EField _ | EConstructor _ | EFail _ -> []
  | ECacheGet { key; _ } -> exists_witnesses key
  | ECacheSet { key; value; ttl; _ } ->
    exists_witnesses key @ exists_witnesses value
    @ (match ttl with Some e -> exists_witnesses e | None -> [])
  | ECacheDelete { key; _ } -> exists_witnesses key
  | ECacheInvalidate { prefix; _ } -> exists_witnesses prefix
  | ESendEmail { to_; subject; body; _ } ->
    exists_witnesses to_ @ exists_witnesses subject @ exists_witnesses body
  | EStartEmailWorker _ -> []
  | ERuntimeCall { segments; _ } ->
    List.concat_map (function RLit _ | RRawVar _ -> [] | RArg e -> exists_witnesses e) segments

let check_exists_bindings (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      (match fd.return_spec with
       | RetExists { binding; _ } ->
         let witnesses = exists_witnesses fd.body |> List.sort_uniq String.compare in
         if witnesses = [] then
           errors := make_error fd.loc
             ~hint:(Printf.sprintf "use `exists %s => ...` in the function body" binding.name)
             (Printf.sprintf "function '%s' declares exists return type but body has no exists expression" fd.name)
             :: !errors
         (* Note: we do NOT enforce that the witness NAME in the body matches the declared name.
            The implementation may use a different internal name (e.g. `i`) while the public
            return spec uses a different name (e.g. `itemId`). The names are matched positionally. *)
       | _ -> ())
    | _ -> ()
  ) decls;
  List.rev !errors

(* R51_E01 — existential-return proof enforcement.
   A function `... -> exists x: T => T ::: P x` is supposed to guarantee
   that the packed value satisfies `P`. Prior to this check, the compiler
   accepted `exists n => n` with NO proof attachment, silently dropping
   the `P x` claim. Detect the obvious forging pattern: the packed body
   is a plain identifier (not the result of a check / establish / auth,
   not attached with `:::`, not the output of a proof-returning stdlib
   helper), but the return spec declares a non-trivial proof.

   This is intentionally conservative: it catches the common footgun
   without over-fitting. Programs that use genuinely complex packs
   (select results, upsert results, explicit attachFact, etc.) still
   go through the runtime evidence layer. *)
let rec inner_return_proof_spec = function
  | RetExists { body; _ } -> inner_return_proof_spec body
  | RetAttached { binding = b; _ } -> b.proof_ann
  | RetNamedPack { entity_proof = Some ep; _ } -> Some ep
  | RetNamedPack { other_proof = Some op; _ } -> Some op
  | _ -> None

(* Collect all the packed values from nested `exists` expressions in a body.
   The same function may contain multiple packs via conditionals, so we
   return a list to avoid losing any of them. *)
let rec packed_body_exprs (e : expr) : expr list =
  match e with
  (* Pattern emitted by parse_exists_expr:
       (make-witness (witness inner_body)) *)
  | EApp {
      fn = EVar { name = "make-witness"; _ };
      arg = EApp { arg = body; _ };
      _ } -> [body]
  | EIf { then_; else_; _ } ->
    packed_body_exprs then_ @ packed_body_exprs else_
  | ECase { arms; _ } ->
    List.concat_map (fun (a : case_arm) -> packed_body_exprs a.body) arms
  | ELet { body; _ } | ELetProof { body; _ } -> packed_body_exprs body
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
  | EWithTransaction { body; _ } -> packed_body_exprs body
  | _ -> []

(* Does this expression demonstrably carry a proof? The cheapest heuristic:
   it is an EOk (check `:::` form), an EConstructor with an uppercased fact
   name, a check / establish call, a stdlib proof-producing call, or a
   database / queue operation whose result is known to carry proofs. *)
let looks_proof_carrying (funcs : (string * func_info) list) (e : expr) : bool =
  match e with
  | EOk _ -> true
  | EConstructor _ -> true
  | EApp { fn; _ } ->
    let rec head = function
      | EVar { name; _ } -> Some name
      | EApp { fn; _ } -> head fn
      | _ -> None
    in
    (match head fn with
     | Some name ->
       (* `select` / `selectOne` / `insert` / `upsert` / `update` all attach
          FromDb / FromQueue style proofs; accept them. *)
       List.mem name [
         "select"; "selectOne"; "selectCount"; "selectSum";
         "selectMax"; "selectMin"; "insert"; "insertMany";
         "upsert"; "update"; "updateAndReturnOne";
         "check"; "make-witness"; "attachFact"; "#record-update#";
       ]
       || (match List.assoc_opt name funcs with
           | Some info ->
             is_proof_introducing_kind info.fi_kind  (* B2: single source in Ast *)
             || (match info.fi_return with
                 | RetAttached { binding = b; _ } -> b.proof_ann <> None
                 | RetNamedPack _ -> true
                 | _ -> false)
           | None -> false)
     | None -> false)
  | _ -> false

(* Like packed_body_exprs, but also threads, down to each pack site, the
   in-scope binder environments.  Returns per pack site: (packed_body, let_env,
   case_env) where:
     - let_env maps `let x = v` / `let (v ::: p) = value` binders to their value;
     - case_env maps `case … of Ctor v ->` PATTERN binders to the SCRUTINEE they
       were unwrapped from.
   GDP-EXISTS-CASE (2026-07 fresh review, CRITICAL): case-pattern binders used to
   be dropped entirely, so `case scrut of Ctor v -> exists w => v` reached the
   "binder we cannot see → accept conservatively" branch and minted an arbitrary
   proof (incl. FromDb provenance) on unvalidated data.  Threading them lets the
   enforcement decide by the scrutinee's actual provenance instead of failing
   open, and letproof binders are threaded too so their value is resolvable. *)
let packed_body_exprs_with_locals (e : expr)
    : (expr * (string * expr) list * (string * expr) list) list =
  let rec pat_binders acc = function
    | PVar n -> n :: acc
    | PCon { fields; _ } -> List.fold_left (fun acc (_, p) -> pat_binders acc p) acc fields
    | _ -> acc
  in
  let rec go let_env case_env (e : expr) =
    match e with
    | EApp {
        fn = EVar { name = "make-witness"; _ };
        arg = EApp { arg = body; _ };
        _ } ->
      (* The packed value is the TAIL of `body`, which may be wrapped in block
         constructs (`transaction`/`with database`/`with capabilities`) and/or a
         let-chain. Unwrap them to the tail expression — threading `let`/`letproof`
         bindings into let_env — so the proof carried by the tail (e.g. `insert …`
         inside a `transaction { … }`) is seen. Without this the pack body was the
         raw `EWithTransaction` node, which no proof-carrier check recognises, so
         "insert-two-rows-atomically-and-return-the-proof-carrying-one" was
         rejected (bug-report #2). The tail still gets the SAME proof scrutiny, so
         a fabricated tail is still rejected — no forgery is admitted. *)
      let rec unwrap le = function
        | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
        | EWithTransaction { body; _ } -> unwrap le body
        | ELet { name; value; body; _ } -> unwrap ((name, value) :: le) body
        | ELetProof { value_name; value; body; _ } -> unwrap ((value_name, value) :: le) body
        | e -> (e, le)
      in
      let (tail, le') = unwrap let_env body in
      [(tail, le', case_env)]
    | EIf { then_; else_; _ } -> go let_env case_env then_ @ go let_env case_env else_
    | ECase { scrut; arms; _ } ->
      (* Resolve a let-bound scrutinee to its value so provenance (e.g. `let x =
         selectOne …  ; case x of …`) is not lost when the binder is checked. *)
      let scrut' = match scrut with
        | EVar { name; _ } -> (match List.assoc_opt name let_env with Some v -> v | None -> scrut)
        | _ -> scrut in
      List.concat_map (fun (a : case_arm) ->
        let case_env' =
          List.map (fun n -> (n, scrut')) (pat_binders [] a.pattern) @ case_env in
        go let_env case_env' a.body) arms
    | ELet { name; value; body; _ } -> go ((name, value) :: let_env) case_env body
    | ELetProof { value_name; value; body; _ } ->
      go ((value_name, value) :: let_env) case_env body
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> go let_env case_env body
    | _ -> []
  in
  go [] [] e

let check_existential_proof_enforcement ?(extra_funcs = []) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  List.concat_map (function
    | DFunc fd ->
      (match fd.return_spec with
       | RetExists _ ->
         (match inner_return_proof_spec fd.return_spec with
          | Some declared_proof ->
            (* The inner body of `exists … => body` MUST carry the proof declared
               in the return spec.  This mirrors the original three-way structure
               (raw param / raw local / other), tightened so it no longer fails
               OPEN on non-identifier bodies (review 2.1/2.2):
                 - a literal, record literal or plain-function result carries no
                   proof → rejected;
                 - a bare local we can RESOLVE to a concrete predicate set that
                   OMITS the declared predicate is wrong-fact laundering
                   (e.g. `IsShort` packed as `IsAdmin`) → rejected;
                 - recognised proof-carriers (EOk / check / select / insert /
                   attachFact / …) and binders we cannot see here (case-arm
                   patterns carrying `FromDb`) are accepted, exactly as before.
               All proof resolution is best-effort and crash-safe. *)
            let param_names = List.map (fun (b : binding) -> b.name) fd.params in
            let declared_preds = List.sort_uniq compare (proof_predicates declared_proof) in
            let body_loc = function
              | EVar { loc; _ } | ELit { loc; _ } | EField { loc; _ }
              | EApp { loc; _ } | EBinop { loc; _ } | EUnop { loc; _ }
              | EIf { loc; _ } | ECase { loc; _ } | ELet { loc; _ }
              | ELetProof { loc; _ } | ERecord { loc; _ } | EList { loc; _ }
              | EOk { loc; _ } | EFail { loc; _ } | EConstructor { loc; _ }
              | ELambda { loc; _ } -> loc
              | _ -> Location.dummy_loc "existential-pack"
            in
            let hint =
              "validate the packed value with a `check`/`establish` function (or a \
               proof-carrying DB read) so it carries the declared proof, or attach an \
               existing proof with `value ::: proofVar`"
            in
            (* Best-effort, crash-safe predicate resolution for an expression. *)
            let resolved_preds e =
              try
                let se = build_initial_subject_env fd.params in
                let pe = build_initial_proof_env fd.params in
                List.concat_map proof_predicates
                  (List.map Proof_kernel.fact_of (proofs_of_expr "_pack" funcs se pe e))
              with _ -> []
            in
            (* True only when we resolved concrete proofs that OMIT a declared one. *)
            let is_wrong_fact carried =
              carried <> [] &&
              not (List.for_all (fun p -> List.mem p carried) declared_preds)
            in
            let param_preds name =
              match List.find_opt (fun (b : binding) -> b.name = name) fd.params with
              | Some { proof_ann = Some p; _ } -> proof_predicates p
              | _ -> []
            in
            let user_fn_names =
              List.filter_map (function DFunc d -> Some d.name | _ -> None) decls in
            let is_fromdb_family =
              List.exists (fun p -> List.mem p ["FromDb"; "FromQueue"; "FromDeadQueue"])
                declared_preds in
            (* A case-arm binder carries the declared proof iff the SCRUTINEE it was
               unwrapped from provably does: either the proof engine resolves the
               declared predicate(s) on the scrutinee, or — for framework provenance
               (FromDb/FromQueue) not modelled as a first-class proof — the
               scrutinee's returned value flows from a real DB site.  A fabricated
               constructor/record scrutinee satisfies neither and is rejected. *)
            let case_scrut_carries scrut =
              let se = build_initial_subject_env fd.params in
              let pe = build_initial_proof_env fd.params in
              let carried =
                try List.concat_map proof_predicates
                      (List.map Proof_kernel.fact_of (proofs_of_expr "_pack" funcs se pe scrut))
                with _ -> [] in
              (carried <> [] && List.for_all (fun p -> List.mem p carried) declared_preds)
              || (is_fromdb_family
                  && return_value_flows_from_db_site ~shadowed:user_fn_names scrut)
            in
            List.concat_map (fun (body, local_env, case_env) ->
              match body with
              | EVar { loc; name } when List.mem name param_names ->
                (* Raw parameter: OK only if it declares the required proof. *)
                let pp = param_preds name in
                if pp <> [] && List.for_all (fun p -> List.mem p pp) declared_preds then []
                else
                  [ make_error loc ~hint
                      (Printf.sprintf
                         "existential pack returns the raw parameter `%s`; the packed value must \
                          carry the proof `%s` declared in the return spec"
                         name (pp_proof declared_proof)) ]
              | EVar { loc; name } when List.mem_assoc name local_env ->
                let value = List.assoc name local_env in
                let carried = resolved_preds value in
                if is_wrong_fact carried then
                  [ make_error loc ~hint
                      (Printf.sprintf
                         "existential pack body carries proof(s) `%s` but must carry the proof \
                          `%s` declared in the return spec"
                         (String.concat ", " carried) (pp_proof declared_proof)) ]
                else if looks_proof_carrying funcs value then []
                else
                  [ make_error loc ~hint
                      (Printf.sprintf
                         "existential pack returns the raw local `%s`; the packed value must \
                          carry the proof `%s` declared in the return spec"
                         name (pp_proof declared_proof)) ]
              | EVar { loc; name } when List.mem_assoc name case_env ->
                (* GDP-EXISTS-CASE: a value unwrapped from a `case` arm.  Decide by
                   the scrutinee's provenance, NOT by conservative acceptance. *)
                if case_scrut_carries (List.assoc name case_env) then []
                else
                  [ make_error loc ~hint
                      (Printf.sprintf
                         "existential pack returns `%s`, unwrapped from a value that is not shown \
                          to carry the proof `%s` declared in the return spec; validate it at a \
                          boundary (`check`/`establish`) or read it from the database"
                         name (pp_proof declared_proof)) ]
              | EVar _ ->
                (* The existential WITNESS binder itself (`exists w => w`, the
                   identity introduction) or another binder we cannot resolve
                   here.  Accept conservatively, as the original did — the
                   case-arm laundering path that used to fall through HERE is now
                   handled by the [case_env] branch above, so this no longer fails
                   open on it.  (Witness-identity intro is covered by dedicated
                   tests and must keep compiling.) *)
                []
              | _ ->
                (* C5 (2026-07-05 fresh review): fail-CLOSED, decide by PROOF
                   CONTENT.  The former gate accepted any body that merely
                   `looks_proof_carrying` (EOk / check / select / insert /
                   attachFact / bare constructor) WITHOUT checking WHICH fact it
                   carried, so `exists w => check tagWithUnrelatedFact v` and even
                   `exists w => SomeConstructor` forged the declared proof (incl.
                   FromDb provenance) on unvalidated data.  We now accept only when
                   the body PROVABLY carries the declared predicate(s): either the
                   proof engine resolves them on the body, or — for framework
                   provenance not modelled as a first-class proof — the returned
                   value flows from a real DB/queue site.  Anything else (wrong
                   fact, unresolved, literal, record, plain result, or a
                   proof-shaped call carrying the wrong predicate) is rejected. *)
                let carried =
                  (* Resolve the body's predicates threading the enclosing `let`
                     bindings, so an attached proof VARIABLE (`let p = pp n in
                     v ::: p`, where `pp` is an establish) resolves to its
                     underlying predicate rather than the bare proof-var spelling.
                     [resolved_preds] alone uses a params-only env and would read
                     `n ::: p` as carrying `p`. *)
                  let se = build_initial_subject_env fd.params in
                  let pe =
                    List.fold_left (fun pe (nm, ve) ->
                      let ps = (try proofs_of_expr nm funcs se pe ve with _ -> []) in
                      if ps = [] then pe else (nm, ps) :: pe)
                      (build_initial_proof_env fd.params) (List.rev local_env)
                  in
                  (try List.concat_map proof_predicates
                         (List.map Proof_kernel.fact_of (proofs_of_expr "_pack" funcs se pe body))
                   with _ -> [])
                in
                let user_fn_names =
                  List.filter_map (function DFunc d -> Some d.name | _ -> None) decls in
                let is_fromdb_family =
                  List.exists (fun p -> List.mem p ["FromDb"; "FromQueue"; "FromDeadQueue"])
                    declared_preds in
                if carried <> [] && List.for_all (fun p -> List.mem p carried) declared_preds
                then []
                else if is_fromdb_family
                        && return_value_flows_from_db_site ~shadowed:user_fn_names body
                then []
                else if is_wrong_fact carried then
                  [ make_error (body_loc body) ~hint
                      (Printf.sprintf
                         "existential pack body carries proof(s) `%s` but must carry the proof \
                          `%s` declared in the return spec"
                         (String.concat ", " carried) (pp_proof declared_proof)) ]
                else
                  [ make_error (body_loc body) ~hint
                      (Printf.sprintf
                         "existential pack body must carry the proof `%s` declared in the return \
                          spec (a literal, record, plain function result, or a proof-carrying \
                          value that does not establish this fact carries no such proof)"
                         (pp_proof declared_proof)) ]
            ) (packed_body_exprs_with_locals fd.body)
          | None -> [])
       | _ -> [])
    | _ -> []
  ) decls

(* ── B1. Non-exhaustive case expressions ─────────────────────────────────── *)

(** Extract the outermost type constructor name from a type expression.
    For `TName "Maybe"` → `"Maybe"`.
    For `TApp (TApp (TName "Result") a) e` → `"Result"`. *)
let rec head_type_name : type_expr -> string option = function
  | TName { name; _ } -> Some name
  | TApp { head; _ } -> head_type_name head
  | _ -> None

(** Given a ctor_info (ctor -> (field_types, result_type)) and an ADT type name,
    return the list of all constructor names for that ADT.
    Handles both plain types (TName) and parameterized types (TApp). *)
let ctors_for_type (ctors : ctor_info) (adt_name : string) : string list =
  match adt_name with
  | "Bool" -> ["True"; "False"]
  | _ ->
    List.filter_map (fun (ctor_name, (_, result_ty)) ->
      match head_type_name result_ty with
      | Some name when name = adt_name -> Some ctor_name
      | _ -> None
    ) ctors

let ctor_signature (ctors : ctor_info) (ctor_name : string) : (type_expr list * type_expr) option =
  match ctor_name with
  | "True" | "False" -> Some ([], mk_name_type "Bool")
  | _ -> List.assoc_opt ctor_name ctors

let rec unify_type_vars
    (expected : type_expr)
    (actual : type_expr)
    (subst : (string * type_expr) list)
    : (string * type_expr) list option =
  match expected, actual with
  | TVar { name; _ }, ty ->
    (match List.assoc_opt name subst with
     | Some existing when existing = ty -> Some subst
     | Some _ -> None
     | None -> Some ((name, ty) :: subst))
  | TName { name = expected_name; _ }, TName { name = actual_name; _ } when expected_name = actual_name -> Some subst
  | TApp { head = expected_head; arg = expected_arg; _ },
    TApp { head = actual_head; arg = actual_arg; _ } ->
    (match unify_type_vars expected_head actual_head subst with
     | Some subst' -> unify_type_vars expected_arg actual_arg subst'
     | None -> None)
  | TTuple { elems = expected_elems; _ }, TTuple { elems = actual_elems; _ }
    when List.length expected_elems = List.length actual_elems ->
    List.fold_left2 (fun acc expected_elem actual_elem ->
      match acc with
      | Some subst' -> unify_type_vars expected_elem actual_elem subst'
      | None -> None
    ) (Some subst) expected_elems actual_elems
  | TFun { dom = expected_dom; cod = expected_cod; _ },
    TFun { dom = actual_dom; cod = actual_cod; _ } ->
    (match unify_type_vars expected_dom actual_dom subst with
     | Some subst' -> unify_type_vars expected_cod actual_cod subst'
     | None -> None)
  | _ -> None

let rec apply_type_subst (subst : (string * type_expr) list) (ty : type_expr) : type_expr =
  match ty with
  | TVar { name; _ } -> Option.value (List.assoc_opt name subst) ~default:ty
  | TApp { head; arg; loc } ->
    TApp { head = apply_type_subst subst head; arg = apply_type_subst subst arg; loc }
  | TFun { dom; cod; caps; loc } ->
    TFun { dom = apply_type_subst subst dom; cod = apply_type_subst subst cod; caps; loc }
  | TTuple { elems; loc } ->
    TTuple { elems = List.map (apply_type_subst subst) elems; loc }
  | TName _ -> ty

let ctor_field_types_for_scrutinee
    (ctors : ctor_info)
    (ctor_name : string)
    (scrut_ty : type_expr)
    : type_expr list option =
  match ctor_signature ctors ctor_name with
  | Some (field_types, result_ty) ->
    (match unify_type_vars result_ty scrut_ty [] with
     | Some subst -> Some (List.map (apply_type_subst subst) field_types)
     | None -> Some field_types)
  | None -> None

let wildcard_patterns (field_types : type_expr list) : pattern list =
  List.map (fun _ -> PWild) field_types

let specialize_rows_for_ctor
    (ctor_name : string)
    (field_types : type_expr list)
    (rows : pattern list list)
    : pattern list list =
  let wilds = wildcard_patterns field_types in
  List.filter_map (fun row ->
    match row with
    | [] -> None
    | pat :: tail ->
      match pat with
      | PWild | PVar _ -> Some (wilds @ tail)
      | PNullary { ctor; _ } when ctor = ctor_name && field_types = [] -> Some tail
      | PCon { ctor; fields; _ }
        when ctor = ctor_name && List.length fields = List.length field_types ->
        Some (List.map snd fields @ tail)
      | _ -> None
  ) rows

let default_rows (rows : pattern list list) : pattern list list =
  List.filter_map (fun row ->
    match row with
    | [] -> None
    | (PWild | PVar _) :: tail -> Some tail
    | _ -> None
  ) rows

let row_is_catch_all (row : pattern list) : bool =
  List.for_all (function PWild | PVar _ -> true | _ -> false) row

let rec patterns_are_exhaustive_for_types
    (ctors : ctor_info)
    (tys : type_expr list)
    (rows : pattern list list)
    : bool =
  match tys with
  | [] -> rows <> []
  | _ when List.exists row_is_catch_all rows -> true
  | ty :: rest ->
    let defaults = default_rows rows in
    match head_type_name ty with
    | Some adt_name ->
      let all_ctors = ctors_for_type ctors adt_name in
      if all_ctors = [] then
        patterns_are_exhaustive_for_types ctors rest defaults
      else
        List.for_all (fun ctor_name ->
          match ctor_field_types_for_scrutinee ctors ctor_name ty with
          | Some field_types ->
            let specialized = specialize_rows_for_ctor ctor_name field_types rows in
            patterns_are_exhaustive_for_types ctors (field_types @ rest) specialized
          | None -> false
        ) all_ctors
    | None ->
      patterns_are_exhaustive_for_types ctors rest defaults

let patterns_are_exhaustive_for_type
    (ctors : ctor_info)
    (ty : type_expr)
    (patterns : pattern list)
    : bool =
  patterns_are_exhaustive_for_types ctors [ty] (List.map (fun pat -> [pat]) patterns)

let rec check_case_exhaustiveness_expr
    (env : type_env)
    (funcs : (string * func_info) list)
    (fields_by_type : field_map)
    (ctors : ctor_info)
    (e : expr)
    : validation_error list =
  let recurse = check_case_exhaustiveness_expr env funcs fields_by_type ctors in
  match e with
  | ECase { scrut; arms; loc } ->
    (* Check sub-expressions first *)
    let scrut_errors = recurse scrut in
    let scrut_ty = infer_expr_type env funcs fields_by_type ctors scrut in
    (* A guarded arm does NOT count as full coverage: if the guard fails, the
       value is unhandled.  Only unguarded arms (or unguarded wildcards) establish
       exhaustiveness.  Reachability analysis below is still guard-aware and does
       not let guards create duplicate-arm false positives. *)
    let has_wildcard = List.exists (fun (arm : case_arm) ->
      arm.guard = None &&
      (match arm.pattern with PWild | PVar _ -> true | _ -> false)
    ) arms in
    let case_errors =
      if has_wildcard then []
      else
        (* Collect constructors covered by at least one UNGUARDED arm.
           A guarded arm for constructor C does not count as covering C. *)
        let covered = List.filter_map (fun (arm : case_arm) ->
          if arm.guard <> None then None
          else match arm.pattern with
          | PCon { ctor; _ } -> Some ctor
          | PNullary { ctor; _ } -> Some ctor
          | _ -> None
        ) arms in
        (* Look up all constructors for the scrutinee's ADT *)
        let all_ctors = match scrut_ty with
          | Some ty ->
            (match head_type_name ty with
             | Some adt_name -> ctors_for_type ctors adt_name
             | None -> [])
          | None -> []
        in
        if all_ctors = [] then []
        else
          let missing = List.filter (fun c -> not (List.mem c covered)) all_ctors in
          if missing = [] then []
          else
            (* Distinguish between constructors that are truly absent and constructors
               that appear in the case but only with `where` guards.  If ALL arms for
               a constructor are guarded, those arms provide no exhaustiveness guarantee
               (the guard could fail), but the error message "missing" is misleading
               when the constructors ARE present. *)
            let guarded_only = List.filter (fun c ->
              List.mem c missing &&
              List.exists (fun (arm : case_arm) ->
                arm.guard <> None &&
                (match arm.pattern with
                 | PCon { ctor; _ } | PNullary { ctor; _ } -> ctor = c
                 | _ -> false)
              ) arms
            ) missing in
            let genuinely_missing = List.filter (fun c ->
              not (List.mem c guarded_only)) missing in
            let errors = ref [] in
            if genuinely_missing <> [] then
              errors := make_error loc
                (Printf.sprintf "non-exhaustive case: missing constructor(s) [%s]"
                   (String.concat ", " genuinely_missing))
                :: !errors;
            if guarded_only <> [] then
              errors := make_error loc
                ~hint:"add an unguarded catch-all arm `_ -> ...` to handle cases where all guards fail"
                (Printf.sprintf
                   "non-exhaustive case: constructor(s) [%s] only appear in guarded arms — \
if every guard fails at runtime, the case has no match"
                   (String.concat ", " guarded_only))
                :: !errors;
            List.rev !errors
    in
    (* Check pattern arity — PNullary used on a constructor that has fields is an error *)
    let arity_errors = List.concat_map (fun (arm : case_arm) ->
      match arm.pattern with
      | PNullary { ctor; loc } ->
        (match List.assoc_opt ctor ctors with
         | Some (field_types, _) when field_types <> [] ->
           [ make_error loc
               (Printf.sprintf "pattern `%s` expects %d field%s but was used without any"
                  ctor (List.length field_types)
                  (if List.length field_types = 1 then "" else "s")) ]
         | _ -> [])
      | _ -> []
    ) arms in
    let arm_errors = List.concat_map (fun (arm : case_arm) ->
      let arm_env = pattern_bindings scrut_ty ctors arm.pattern @ env in
      check_case_exhaustiveness_expr arm_env funcs fields_by_type ctors arm.body
    ) arms in
    (* Literal exhaustiveness: require a catch-all when all patterns are literals *)
    let literal_errors =
      if has_wildcard then []
      else
        let arm_count = List.length arms in
        let literal_count = List.length (List.filter (fun (arm : case_arm) ->
          match arm.pattern with PLit _ -> true | _ -> false
        ) arms) in
        if arm_count > 0 && literal_count = arm_count then
          [ make_error loc
              ~hint:"add a catch-all arm `_ -> ...` to handle all other values"
              "non-exhaustive case: literal patterns (Int, Float, or String) always require a catch-all arm `_ -> ...`" ]
        else []
    in
    let recursive_errors =
      if has_wildcard then []
      else
        match scrut_ty with
        | Some ty ->
          (* Only unguarded arms count toward exhaustiveness for nested patterns too. *)
          let patterns = List.filter_map (fun (arm : case_arm) ->
            if arm.guard = None then Some arm.pattern else None
          ) arms in
          if patterns_are_exhaustive_for_type ctors ty patterns
          || case_errors <> [] || literal_errors <> []
          then []
          else
            [ make_error loc
                ~hint:"add a catch-all arm `_ -> ...` or cover the remaining nested values explicitly"
                "non-exhaustive case: nested constructor/literal patterns leave uncovered values" ]
        | None -> []
    in
    (* Redundancy analysis (review 50 §2.4).
       Catches three independent classes of dead case arms:
       1. A constructor arm after an earlier arm with the same constructor tag
          and no narrowing inner pattern (each subsequent arm is unreachable).
       2. A literal arm duplicating an earlier literal arm with the same value.
       3. Any arm after a wildcard / variable catch-all (the catch-all already
          matches everything, so all following arms are dead code).
       Reporting is always at the offending arm's pattern location, so the
       editor can highlight exactly what to delete. *)
    let redundancy_errors =
      let lit_key = function
        | LInt n -> Some (`Int n)
        (* A9/HM-1: reuse the `Str key (distinct variant from `Int, so a huge Int
           literal never collides with a native-int one) so identical huge arms are
           still flagged as redundant. *)
        | LBigInt s -> Some (`Str s)
        | LString s -> Some (`Str s)
        | LFloat _ -> None
        | LBool _ -> None
        | _ -> None
      in
      (* A constructor arm fully covers every value with that constructor only
         when its *immediate* fields are plain binders/wildcards.
         `Something 0`, `Something Nothing`, and `Something (Pair _ _)` all
         narrow the `Something` space, so later `Something ...` arms may still
         be reachable.  This deliberately stays conservative to avoid false
         positives on nested-pattern coverage. *)
      let pat_is_open = function
        | PWild | PVar _ -> true
        | PNullary _ -> true
        | PCon { fields; _ } ->
          List.for_all (function
            | (_, PWild) | (_, PVar _) -> true
            | _ -> false
          ) fields
        | PLit _ -> false
      in
      let catchall_seen = ref false in
      let catchall_loc = ref None in
      (* Open-coverage tracking: only an arm whose pattern is fully open
         establishes redundant coverage for the constructor tag. *)
      let seen_open_ctors : (string * Location.loc) list ref = ref [] in
      let seen_lits : ([ `Int of int | `Str of string ] * Location.loc) list ref = ref [] in
      let errs = ref [] in
      List.iter (fun (arm : case_arm) ->
        let guarded = arm.guard <> None in
        let pat_loc = match arm.pattern with
          | PWild -> loc
          | PVar _ -> loc
          | PCon { loc; _ } -> loc
          | PNullary { loc; _ } -> loc
          | PLit { loc; _ } -> loc
        in
        if !catchall_seen then begin
          let prior = match !catchall_loc with
            | Some l ->
              Printf.sprintf " (a catch-all arm at line %d already matches everything)"
                (l.Location.start.Location.line + 1)
            | None -> ""
          in
          errs := make_error pat_loc
            ~hint:"remove this arm, or move it before the catch-all arm"
            (Printf.sprintf "unreachable case arm%s" prior) :: !errs
        end else
          match arm.pattern with
          | PWild | PVar _ ->
            if not guarded then begin
              catchall_seen := true;
              catchall_loc := Some pat_loc
            end
          | PNullary { ctor; _ } | PCon { ctor; _ } ->
            (match List.assoc_opt ctor !seen_open_ctors with
             | Some prev_loc ->
               errs := make_error pat_loc
                 ~hint:(Printf.sprintf
                   "a case arm for `%s` already appears at line %d; remove this duplicate"
                   ctor (prev_loc.Location.start.Location.line + 1))
                 (Printf.sprintf "duplicate case arm: constructor `%s` is already covered" ctor)
                 :: !errs
             | None ->
               if (not guarded) && pat_is_open arm.pattern then
                 seen_open_ctors := (ctor, pat_loc) :: !seen_open_ctors)
          | PLit { value; _ } ->
            (match lit_key value with
             | Some key ->
               (match List.assoc_opt key !seen_lits with
                | Some prev_loc ->
                  errs := make_error pat_loc
                    ~hint:(Printf.sprintf
                      "this literal is already matched at line %d; remove this duplicate"
                      (prev_loc.Location.start.Location.line + 1))
                    "duplicate case arm: literal value is already covered"
                    :: !errs
                | None ->
                  seen_lits := (key, pat_loc) :: !seen_lits)
             | None -> ())
      ) arms;
      List.rev !errs
    in
    scrut_errors @ case_errors @ arity_errors @ literal_errors @ recursive_errors @ redundancy_errors @ arm_errors
  | ELit _ | EVar _ | EConstructor _ | EFail _ -> []
  | EField { obj; _ } -> recurse obj
  | EApp { fn; arg; _ } -> recurse fn @ recurse arg
  | EBinop { left; right; _ } -> recurse left @ recurse right
  | EUnop { arg; _ } -> recurse arg
  | EIf { cond; then_; else_; _ } -> recurse cond @ recurse then_ @ recurse else_
  | ELet { name; value; body; _ } ->
    let value_errors = recurse value in
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (name, ty) :: env
      | None -> env
    in
    value_errors @ check_case_exhaustiveness_expr env' funcs fields_by_type ctors body
  | ELetProof { value_name; value; body; _ } ->
    let value_errors = recurse value in
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (value_name, ty) :: env
      | None -> env
    in
    value_errors @ check_case_exhaustiveness_expr env' funcs fields_by_type ctors body
  | ERecord { fields; _ } ->
    List.concat_map (fun (_, v) -> recurse v) fields
  | EList { elems; _ } -> List.concat_map recurse elems
  | EOk { value; _ } -> recurse value
  | ETelemetry { fields; _ } ->
    List.concat_map (fun (_, v) -> recurse v) fields
  | EEnqueue { payload; _ } -> recurse payload
  | EPublish { key; payload; _ } ->
    (match key with Some e -> recurse e | None -> [])
    @ (match payload with Some e -> recurse e | None -> [])
  | EStartWorkers _ -> []
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    recurse body
  | EServe { port; _ } -> recurse port
  | ELambda { params; body; _ } ->
    let env' = List.map (fun (b : binding) -> (b.name, b.type_expr)) params @ env in
    check_case_exhaustiveness_expr env' funcs fields_by_type ctors body
  | ECacheGet { key; _ } -> recurse key
  | ECacheSet { key; value; ttl; _ } ->
    recurse key @ recurse value @ (match ttl with Some e -> recurse e | None -> [])
  | ECacheDelete { key; _ } -> recurse key
  | ECacheInvalidate { prefix; _ } -> recurse prefix
  | ESendEmail { to_; subject; body; _ } ->
    recurse to_ @ recurse subject @ recurse body
  | EStartEmailWorker _ -> []
  | ERuntimeCall { segments; _ } ->
    List.concat_map (function RLit _ | RRawVar _ -> [] | RArg e -> recurse e) segments

