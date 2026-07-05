(** Unified proof-obligation discharge — the obligation model (foundation).

    This module is the front half of the discharge-unification refactor
    (~/.claude/plans/synthetic-watching-thunder.md).  Return-side proof checking is
    currently spread across ~9 divergent return-leaf walkers (in validation_advanced
    / validation_proof / validation_capabilities) plus a second pipeline
    (proof_checker.ml).  Several of those copies historically FAILED OPEN, which is
    where the 2026-07-05 forgery class lived.

    [normalize] is the SINGLE, exhaustive translation from a function's declared
    [return_spec] to the list of proof OBLIGATIONS its body must discharge.  Every
    return-side check will route through obligations produced here, so there is one
    place that knows all return forms and one fail-closed default.  Because the match
    over [return_spec] is total (the whole compiler builds with `-warn-error +8`),
    adding a new return form without deciding its obligation is a BUILD error, not a
    silent discharge-to-nothing — fail-closed by construction.

    The verifiers that CONSUME these obligations (the single Carry/Mint/Framework
    leaf judgment, and the dispatched ForAll/Existential sub-judgments) land in
    subsequent phases; this phase fixes the vocabulary and the exhaustive front door. *)

open Ast
open Location
(* The discharge verifier (below) is the downstream consumer of the whole
   validation layer, so it may use every validation_* helper directly. *)
open Validation_common
open Validation_structural
open Validation_proof

(** Which direction an obligation is checked in.  The same return form yields a
    different judgment depending on the function KIND — this axis is orthogonal to
    the return shape, which is why it is a field of its own. *)
type judgment =
  | Carry
      (** a forgery-restricted kind (fn / handler / worker / deadWorker / main): the
          returned value must CONTENT-CARRY the declared proof; it may not mint one. *)
  | Mint
      (** a boundary kind (check / auth / establish): the body MINTS the proof; the
          obligation is that the minted [ok v ::: P] matches the declared spec. *)

(** What value the obligation is about. *)
type target =
  | ReturnedValue      (** the single returned value (RetAttached / RetNamedPack / RetPlain-Fact) *)
  | MaybeSuccess       (** the success payload of a Maybe/Either wrapper (RetMaybeAttached) *)
  | ExistsPacked       (** the value packed under an existential witness (RetExists) *)
  | Elements           (** every element of a returned collection (RetForAll / RetSetForAll) *)
  | DictValues         (** every value of a returned Dict (RetForAllDictValues) *)
  | DictKeys           (** every key of a returned Dict (RetForAllDictKeys) *)

(** How the obligation is discharged.  [Framework] provenance
    (FromDb/FromQueue/FromDeadQueue) is established by a real DB/queue producing
    site, not by an ordinary carried proof. *)
type mode = Carried | Framework

(** Which returning leaves the obligation applies to.  RetMaybeAttached obliges only
    the success-constructor payload (not the [Nothing]/[Left] side); everything else
    obliges every returning leaf. *)
type leaf_scope = AllReturning | SuccessCtorPayloadOnly

type obligation = {
  judgment      : judgment;
  target        : target;
  required      : proof_expr;    (** the proof that must hold; binder / [_entity] unresolved *)
  binder        : string option; (** the return binder naming the subject, when present *)
  entity_group  : bool;          (** a `? P` entity group ([_entity]-appended): enables the
                                     sound arg-order reorder in the verifier *)
  leaves        : leaf_scope;
  mode          : mode;
  loc           : loc;
}

let judgment_of_kind : func_kind -> judgment = function
  | CheckKind | AuthKind | EstablishKind -> Mint
  | FnKind | HandlerKind | WorkerKind | DeadWorkerKind | MainKind -> Carry

let is_framework_pred = function
  | "FromDb" | "FromQueue" | "FromDeadQueue" -> true
  | _ -> false

let rec leaf_preds (p : proof_expr) : string list =
  match p with
  | PredApp { pred; _ } -> [pred]
  | PredAnd { left; right; _ } -> leaf_preds left @ leaf_preds right

let mode_of_proof (p : proof_expr) : mode =
  if List.exists is_framework_pred (leaf_preds p) then Framework else Carried

(** The single, exhaustive [return_spec -> obligation list] front door.  A form with
    no proof content (a bare `-> T`, or a `check`/`auth` without an annotation) yields
    the empty list; every proof-bearing form yields one obligation per declared proof.
    Total over [return_spec] — a new constructor forces a decision here. *)
let rec normalize (kind : func_kind) (rs : return_spec) : obligation list =
  let j = judgment_of_kind kind in
  let mk ?(entity_group = false) ?(leaves = AllReturning) ~target ~required ~binder ~loc () =
    { judgment = j; target; required; binder; entity_group; leaves;
      mode = mode_of_proof required; loc }
  in
  match rs with
  | RetPlain { ty; loc } ->
    (* `-> T` carries a proof only when T is a `Fact (…)` type; otherwise no proof. *)
    (match Validation_common.proof_of_fact_type ty with
     | Some p -> [ mk ~target:ReturnedValue ~required:p ~binder:None ~loc () ]
     | None -> [])
  | RetAttached { binding = b; loc } ->
    (match b.proof_ann with
     | Some p -> [ mk ~target:ReturnedValue ~required:p ~binder:(Some b.name) ~loc () ]
     | None -> [])
  | RetNamedPack { entity_proof; other_proof; loc; _ } ->
    (match entity_proof with
     | Some p -> [ mk ~target:ReturnedValue ~required:p ~binder:None ~entity_group:true ~loc () ]
     | None -> [])
    @ (match other_proof with
       | Some p -> [ mk ~target:ReturnedValue ~required:p ~binder:None ~loc () ]
       | None -> [])
  | RetMaybeAttached { binding = b; loc; _ } ->
    (match b.proof_ann with
     | Some p -> [ mk ~target:MaybeSuccess ~required:p ~binder:(Some b.name)
                     ~leaves:SuccessCtorPayloadOnly ~loc () ]
     | None -> [])
  | RetForAll { proof; loc; _ } | RetSetForAll { proof; loc; _ } ->
    [ mk ~target:Elements ~required:proof ~binder:None ~loc () ]
  | RetMaybeForAll { proof; loc; _ } | RetMaybeSetForAll { proof; loc; _ } ->
    [ mk ~target:Elements ~required:proof ~binder:None ~loc () ]
  | RetForAllDictValues { proof; loc; _ } ->
    [ mk ~target:DictValues ~required:proof ~binder:None ~loc () ]
  | RetForAllDictKeys { proof; loc; _ } ->
    [ mk ~target:DictKeys ~required:proof ~binder:None ~loc () ]
  | RetExists { body; loc; _ } ->
    (* The packed value must discharge the inner return spec's proofs, retargeted to
       the existentially-packed value. *)
    List.map (fun o -> { o with target = ExistsPacked; loc }) (normalize kind body)

(** ── The return-proof discharge verifier (moved verbatim from
    validation_advanced.check_fn_return_proof_annotations, 2026-07-06) ──

    §7.12 fail-closed forgery gate for the forgery-restricted kinds
    (fn/handler/worker): a returned value must CONTENT-CARRY the proof its
    return type declares.  Relocated here to co-locate with the obligation
    model above; the per-form dispatch below is being incrementally rewired
    to consume [normalize].  Behaviour is unchanged by the move. *)
let check_fn_return_proof_annotations
    ?facts
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let mf = facts_or_compute ?facts ~extra_funcs decls in
  let funcs = mf.mf_funcs in
  let fields_by_type = mf.mf_fields_map in
  let ctors = mf.mf_ctors in
  field_proof_registry := mf.mf_field_proof_map;
  let errors = ref [] in
  let actual_proof_summary proofs =
    match combine_proof_list (dummy_loc "named-pack return") proofs with
    | Some proof -> pp_proof proof
    | None -> "no proofs"
  in
  let extend_let_envs type_env subject_env proof_env name value =
    (* Special case: forgetFact strips all proofs — do not propagate subject chain,
       and add an explicit empty proof entry to prevent alias resolution from
       finding the original's proofs. *)
    let is_forget_fact =
      match value with
      | EApp _ ->
        let (head, _) = collect_call_head_and_args [] value in
        (match function_name_of_expr head with
         | Some "forgetFact" -> true
         | _ -> false)
      | _ -> false
    in
    if is_forget_fact then
      let type_env' =
        match infer_expr_type type_env funcs fields_by_type ctors value with
        | Some ty -> (name, ty) :: type_env
        | None -> type_env
      in
      (* Empty proof entry blocks alias resolution; no subject link *)
      (type_env', subject_env, (name, []) :: proof_env)
    else
    let subject_env' =
      match subject_of_expr subject_env value with
      | Some s -> (name, s) :: subject_env
      | None ->
        (match value with
         | EApp _ ->
           let (head0, args0) = collect_call_head_and_args [] value in
           let (head, args) = normalize_explicit_check_call head0 args0 in
           (match function_name_of_expr head with
            | Some fn_name ->
              (match List.assoc_opt fn_name funcs with
               | Some info when (match info.fi_return with RetAttached _ -> true | _ -> false) ->
                 let binding_arg =
                   match info.fi_return with
                   | RetAttached { binding = b; _ } ->
                     let rec find_idx i = function
                       | [] -> None
                       | (p : binding) :: _ when p.name = b.name ->
                         if i < List.length args then Some (List.nth args i) else None
                       | _ :: rest -> find_idx (i + 1) rest
                     in
                     (match find_idx 0 info.fi_params with
                      | Some a -> Some a
                      | None -> List.nth_opt args 0)
                   | _ -> List.nth_opt args 0
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
    let new_proofs = proofs_of_expr name funcs subject_env' proof_env value in
    let proof_env' = if new_proofs = [] then proof_env else (name, new_proofs) :: proof_env in
    (* When name is "_" (auto-unpack from check calls), the proofs are lost
       because nobody looks up "_".  Also store under the check call's argument
       name so that EOk { value = EVar arg_name } can find them. *)
    let proof_env' =
      if name = "_" && new_proofs <> [] then
        (* Extract the last argument of the check call *)
        let (_, args) = collect_call_head_and_args [] value in
        let last_arg = match List.rev args with a :: _ -> Some a | [] -> None in
        let arg_name = match last_arg with
          | Some (EVar { name = n; _ }) -> Some n
          | Some (EOk { value = EVar { name = n; _ }; _ }) -> Some n
          | _ -> None
        in
        (match arg_name with
         | Some n when n <> "_" -> (n, new_proofs) :: proof_env'
         | _ -> proof_env')
      else proof_env'
    in
    let type_env' =
      match infer_expr_type type_env funcs fields_by_type ctors value with
      | Some ty -> (name, ty) :: type_env
      | None -> type_env
    in
    (type_env', subject_env', proof_env')
  in
  let extend_case_envs subject_env proof_env scrut scrut_proofs pat =
    match pat with
    | PVar x when x <> "_" ->
      let penv = if scrut_proofs <> [] then (x, scrut_proofs) :: proof_env else proof_env in
      let senv =
        match subject_of_expr subject_env scrut with
        | Some s when s <> x -> (x, s) :: subject_env
        | _ -> subject_env
      in
      (penv, senv)
    | PCon { fields = [(_, PVar x)]; _ } ->
      let penv = if scrut_proofs <> [] then (x, scrut_proofs) :: proof_env else proof_env in
      let senv =
        let rec resolve_chain seen name =
          if List.mem name seen then name
          else
            match List.assoc_opt name subject_env with
            | Some s when s <> name -> resolve_chain (name :: seen) s
            | _ -> name
        in
        let final_subj =
          match scrut with
          | EVar { name; _ } -> resolve_chain [] name
          | _ -> (match subject_of_expr subject_env scrut with Some s -> s | None -> x)
        in
        if final_subj <> x then (x, final_subj) :: subject_env else subject_env
      in
      (penv, senv)
    | _ -> (proof_env, subject_env)
  in
  (* Predicates that come from infrastructure (SQL, queue) and cannot be
     validated by tracing the function body — exclude them from proof-body
     checking so fn functions can correctly propagate these proofs.
     Note: IsTrimmed, IsSorted, IsUpperCase, IsLowerCase are now in
     stdlib_func_infos so they ARE validated; don't list them here. *)
  (* PROOF-1 fix: a predicate may be auto-granted on a `:::` return ONLY when it
     has a verified producing site or a dedicated flow validator.  FromDb is gated
     by body_has_db_site (an actual select/insert/upsert); FromQueue/FromDeadQueue
     are never minted in a body (handled in is_stdlib_auto below); ForAll/
     ForAllValues/ForAllKeys have a dedicated forall-flow validator that rejects
     forgery independently.  The remaining predicates that used to live here —
     HasKey, IsNonZero, IsNonNegative, IsNonEmpty, FloatNonZero — are produced
     ONLY by check/establish functions (Dict.requireKey, Int.nonZero,
     String.requireNonEmpty, Float.requireNonZero).  Trusting them by NAME let a
     plain `fn` forge them from thin air (`fn f(n) -> n ::: IsNonZero n = n`).
     They are removed: a fn that returns one must now receive it on a parameter
     (proof_matches below) or obtain it via `ok`/`attachFact` (body_uses_attach_or_ok). *)
  let stdlib_auto_preds =
    [ "FromDb"; "FromQueue"; "ForAll"; "ForAllValues"; "ForAllKeys" ] in
  let rec check_named_pack_body (fd : func_decl) ret_loc entity_proof other_proof type_env subject_env proof_env expr =
    match expr with
    | ELet { name; value; body; _ } ->
      let type_env', subject_env', proof_env' = extend_let_envs type_env subject_env proof_env name value in
      check_named_pack_body fd ret_loc entity_proof other_proof type_env' subject_env' proof_env' body
    | ELetProof { value_name; proof_name; value; body; _ } ->
      let type_env', subject_env', proof_env' = extend_let_envs type_env subject_env proof_env value_name value in
      (* Also register the proof variable in proof_env so it can be resolved
         when the body uses `::: p` annotations. *)
      let proof_env' =
        let proofs = proofs_of_expr value_name funcs subject_env' proof_env' value in
        if proofs = [] then proof_env'
        else (proof_name, proofs) :: proof_env'
      in
      check_named_pack_body fd ret_loc entity_proof other_proof type_env' subject_env' proof_env' body
    | EIf { then_; else_; _ } ->
      check_named_pack_body fd ret_loc entity_proof other_proof type_env subject_env proof_env then_;
      check_named_pack_body fd ret_loc entity_proof other_proof type_env subject_env proof_env else_
    | ECase { scrut; arms; _ } ->
      let scrut_ty = infer_expr_type type_env funcs fields_by_type ctors scrut in
      let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
      List.iter (fun (arm : case_arm) ->
        let type_env' = pattern_bindings scrut_ty ctors arm.pattern @ type_env in
        let proof_env', subject_env' = extend_case_envs subject_env proof_env scrut scrut_proofs arm.pattern in
        check_named_pack_body fd ret_loc entity_proof other_proof type_env' subject_env' proof_env' arm.body
      ) arms
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
      check_named_pack_body fd ret_loc entity_proof other_proof type_env subject_env proof_env body
    | EFail _ -> ()  (* fail never returns — no proof obligation *)
    | _ ->
      check_named_pack_body_leaf fd ret_loc entity_proof other_proof type_env subject_env proof_env expr
  and check_named_pack_body_leaf (fd : func_decl) ret_loc entity_proof other_proof _type_env subject_env proof_env expr =
      let result_subject =
        match subject_of_expr subject_env expr with
        | Some s -> s
        | None -> "__named_pack_result"
      in
      let param_mapping = List.map (fun (p : binding) ->
        let subject = match List.assoc_opt p.name subject_env with Some s -> s | None -> p.name in
        (p.name, subject)
      ) fd.params in
      (* ROOT A / C2 (2026-07-05 fresh review): named-pack discharge counts the
         proofs the RETURNED expression carries at its own subject.

         The former code ALSO harvested every proof stored under the `_` key
         (produced by anonymous `let (_ ::: p) = check f arg` destructurings) and
         re-subjected them onto the returned value via [fix_subject] — laundering a
         fact about a validated-but-DISCARDED value onto an unrelated returned
         value (`fn f(dummy,a,b) -> Int ? IsPositive = let (_ ::: p) = check c (a+b)
         in dummy`).  That harvest is deleted: a proof discharged onto a `_` binding
         was explicitly thrown away and must not resurface on the return. *)
      let carried =
        List.map Proof_kernel.fact_of
          (proofs_of_expr result_subject funcs subject_env proof_env expr)
      in
      (* Subject-precise guard for the `value ::: <foreign fact>` (EOk) return
         form (ROOT A / C2, pl-npdirect).  `dummy ::: detachFact proven` attaches
         `proven`'s fact onto the unrelated `dummy`; §7.7 says re-attachment does
         NOT retarget a proof, so the returned value does not actually carry it.
         When the body is an explicit attach whose value-subject is a plain
         parameter that carries no proof of its own, the entity/cargo proof must
         hold for THAT subject exactly — the all-subjects search below is
         suppressed so a fact about a sibling value cannot be laundered in. *)
      let attached_value_subject =
        match expr with
        | EOk { value; _ } -> subject_of_expr subject_env value
        | _ -> None
      in
      let param_subjects =
        List.filter_map (fun (p : binding) -> List.assoc_opt p.name subject_env) fd.params
      in
      let is_bare_param_attach =
        match attached_value_subject with
        | Some s -> List.mem s param_subjects
        | None -> false
      in
      let kind_label = match fd.kind with
        | HandlerKind -> "handler" | WorkerKind -> "worker" | _ -> "fn" in
      let check_required kind required =
        let required_pred = match required with PredApp { pred; _ } -> Some pred | _ -> None in
        (* GDP-FROMDB-NAMEDPACK (2026-07 review §3.3): the `?` named-pack path must
           apply the SAME producing-site gate the `:::` (RetAttached) and `Maybe`
           (RetMaybeAttached) paths use — NOT a flat name-membership.  FromDb is
           framework-produced only when the body runs a real select/insert/upsert
           (body_has_db_site); FromQueue/FromDeadQueue are never body-minted; ForAll*
           keep their dedicated flow validator (still auto here).  Without this gate a
           plain `fn f(pk) -> E ? FromDb (Id == pk) = E { ... }` (no DB access at all)
           minted a fabricated provenance proof consumed downstream as a real DB row. *)
        let is_stdlib_auto = match required_pred with
          | Some "FromDb" ->
            let user_fn_names =
              List.filter_map (function DFunc d -> Some d.name | _ -> None) decls in
            (* GDP-FROMDB-DATAFLOW: dataflow, not presence — the RETURNED value
               must flow from the DB site, else a discarded select forges FromDb. *)
            return_value_flows_from_db_site ~shadowed:user_fn_names fd.body
          | Some ("FromQueue" | "FromDeadQueue") -> false
          | Some p -> List.mem p stdlib_auto_preds
          | None -> false in
        if not is_stdlib_auto && not (proof_matches required carried) then
          errors := make_error ret_loc
            ~hint:(Printf.sprintf
              "establish `%s` before returning, or remove it from the named-pack return spec"
              (pp_proof required))
            (Printf.sprintf
              "%s `%s` returns a named pack claiming %s proof `%s`, but the returned expression only carries `%s`"
              kind_label fd.name kind (pp_proof required) (actual_proof_summary carried))
            :: !errors
      in
      (match entity_proof with
       | Some proof ->
         let expanded = expand_entity_proof_group proof in
         let required = subst_proof (("_entity", result_subject) :: param_mapping) expanded in
         if not (proof_matches required carried) then begin
           (* When subject_of_expr could not pin the returned value's subject
              (result_subject = "__named_pack_result"), OR the naive entity-append
              placed `_entity` in the wrong argument slot for a multi-arg fact
              (`BoundedBy (n, limit)` returned as `? BoundedBy lim`), recover by
              trying the returned expression's OWN carried-proof subjects as the
              entity subject and by permuting argument positions.

              ROOT A / C2 (2026-07-05): this subject-search is what a `? P` launder
              abused — `dummy ::: detachFact proven` returns the bare parameter
              `dummy` while carrying a fact about the sibling `proven`, and the
              search happily bound `_entity := proven`.  §7.7 (re-attachment does
              not retarget) means the returned value does NOT carry that fact, so
              when the body is exactly that shape ([is_bare_param_attach]: an
              explicit `param ::: <foreign fact>`) the search is SUPPRESSED and the
              proof must hold for the parameter's own subject — which it does not,
              so the launder is rejected.  Legit passthroughs (a bare variable, a
              check-call, or `local ::: establishedFact` where the local is derived
              from the input) keep the search. *)
           let flat_carried = List.concat_map flatten_proof_conj carried in
           let carried_subjects =
             List.filter_map (fun (p : proof_expr) ->
               match p with
               | PredApp { args; _ } -> (match List.rev args with s :: _ -> Some s | [] -> None)
               | _ -> None
             ) flat_carried
           in
           let all_arg_subjects =
             List.concat_map (fun (p : proof_expr) ->
               match p with
               | PredApp { args; _ } -> args
               | _ -> []
             ) flat_carried
           in
           let unique_subjects = List.sort_uniq String.compare (carried_subjects @ all_arg_subjects) in
           let found_match =
             (not is_bare_param_attach)
             && List.exists (fun subj ->
               let alt_required = subst_proof (("_entity", subj) :: param_mapping) expanded in
               proof_matches alt_required carried
             ) unique_subjects in
           let found_match = found_match || ((not is_bare_param_attach) && (
             let reorder_to_entity_order (p : proof_expr) =
               match p with
               | PredApp { pred; args; loc } when List.length args >= 2 ->
                 let n = List.length args in
                 let try_pos i =
                   let entity_val = List.nth args i in
                   let rest = List.filteri (fun j _ -> j <> i) args in
                   let reordered = rest @ [entity_val] in
                   PredApp { pred; args = reordered; loc }
                 in
                 List.init n try_pos
               | _ -> [p]
             in
             let reordered_variants = List.concat_map reorder_to_entity_order flat_carried in
             List.exists (fun subj ->
               let alt_required = subst_proof (("_entity", subj) :: param_mapping) expanded in
               proof_matches alt_required reordered_variants
             ) unique_subjects
           )) in
           if not found_match then
             check_required "entity" required
         end
       | None -> ());
      (match other_proof with
       | Some proof ->
         let required = subst_proof param_mapping proof in
         check_required "cargo" required
       | None -> ())
  in
  (* §7.12 forgery restriction applies to fn, handler, and worker: none of these
     can fabricate a proof their inputs do not carry. (check/auth/establish are the
     only kinds that may introduce a fresh proof at a boundary.) deadWorker is
     intentionally excluded — its job carries an infrastructure FromDeadQueue proof
     handled elsewhere.  [is_forgery_restricted_kind] is the shared definition in
     Validation_common (in scope via `open`). *)
  List.iter (function
    | DFunc fd when is_forgery_restricted_kind fd.kind ->
      (* #6 (2026-07-04): set the per-fn type context so the EField arm of
         carried_proofs_of_expr (reached via body_carries below) can resolve a
         field receiver's type — e.g. `extractValue(item: ValidItem) = item.value`. *)
      field_proof_type_ctx :=
        Some (fn_type_env funcs fields_by_type ctors fd, fields_by_type, ctors);
      (match fd.return_spec with
       | RetAttached { binding = b; loc = ret_loc }
         when is_forgery_restricted_kind fd.kind && b.proof_ann <> None ->
         (* The guard `b.proof_ann <> None` ensures Some here; use Option.get with safe fallback *)
         let required_proof = match b.proof_ann with Some p -> p | None -> PredApp { pred = ""; args = []; loc = ret_loc } in
         let proof_env = build_initial_proof_env fd.params in
         let subject_env = build_initial_subject_env fd.params in
         let binding_subject = match List.assoc_opt b.name subject_env with Some s -> s | None -> b.name in
         let required_norm = subst_proof [(b.name, binding_subject)] required_proof in
         let required_pred = match required_norm with PredApp { pred; _ } -> Some pred | _ -> None in
         let is_stdlib_auto = match required_pred with
           (* FromDb on a `:::` return is framework-produced ONLY when the body
              actually runs a select/insert/upsert; with no DB site it forges
              provenance. FromQueue/FromDeadQueue can never be minted in a body. *)
           | Some "FromDb" ->
             (* PROOF-2: exclude user-defined top-level functions so a `fn select`
                cannot masquerade as the SQL builtin and forge DB provenance. *)
             let user_fn_names =
               List.filter_map (function DFunc d -> Some d.name | _ -> None) decls in
             (* GDP-FROMDB-DATAFLOW: dataflow, not presence — the RETURNED value
               must flow from the DB site, else a discarded select forges FromDb. *)
            return_value_flows_from_db_site ~shadowed:user_fn_names fd.body
           | Some ("FromQueue" | "FromDeadQueue") -> false
           | Some p -> List.mem p stdlib_auto_preds
           | None -> false in
         (* GDP-FORGE-1 fix (formal-review CRITICAL).  A `fn`/`handler`/`worker`
            may legitimately introduce its declared return proof in the body via
            `attachFact` (with an `establish`-produced Fact) or an `ok v ::: P`.
            The PREVIOUS gate accepted the body whenever it *syntactically
            mentioned* `attachFact`/`attach`/`ok` ANYWHERE — a decide-by-spelling
            proxy that let a body attach an UNRELATED predicate and still declare
            an arbitrary return proof (e.g. `let y = attachFact x w; y` where `w`
            carries `Whatever` but the return claims `IsPositive`).  Because
            proofs are erased at runtime (§7.10, sole-root-of-trust), that forged
            value then satisfied every downstream proof obligation silently.

            We now decide by PROOF CONTENT, not spelling: walk the body's return
            paths through the same proof engine the named-pack path uses
            ([extend_let_envs] / [proofs_of_expr] / [carried_proofs_of_expr],
            which resolve `attachFact value evidence` to the evidence's actual
            predicate) and require every returning leaf to CARRY the declared
            predicate.  A body that only attaches an unrelated fact no longer
            escapes the forgery rejection.

            GDP-FORGE-2 fix (2026-07-05 fresh review, ROOT A).  The previous gate
            ALSO accepted the body whenever the required proof was merely PRESENT
            among the flat set of all in-scope carried proofs (parameter proofs +
            proofs declared on fields of parameter types), regardless of what the
            body actually RETURNS.  Naming the return binder to collide with an
            in-scope subject (e.g. `fn f(x: Int ::: IsPositive x) -> x: Int :::
            IsPositive x = 0 - 999`) forged the fact onto an arbitrary value.
            That flat `proof_matches required_norm all_carried` short-circuit is
            deleted: discharge now flows SOLELY through [body_carries_required],
            the subject-identity-precise dataflow walk below (or the FromDb
            producing-site gate [is_stdlib_auto]).  Fail-closed: an unrecognised
            return shape falls through to the leaf, which requires the returned
            expression itself to carry the declared proof. *)
         let type_env0 =
           List.map (fun (p : binding) -> (p.name, p.type_expr)) fd.params in
         let rec body_carries_required type_env subject_env proof_env (e : expr) : bool =
           match e with
           | ELet { name; value; body; _ } ->
             let te, se, pe = extend_let_envs type_env subject_env proof_env name value in
             body_carries_required te se pe body
           | ELetProof { value_name; proof_name; value; body; _ } ->
             let te, se, pe = extend_let_envs type_env subject_env proof_env value_name value in
             let pe =
               let proofs = proofs_of_expr value_name funcs se pe value in
               if proofs = [] then pe else (proof_name, proofs) :: pe
             in
             body_carries_required te se pe body
           | EIf { then_; else_; _ } ->
             (* Every return path must carry the proof. *)
             body_carries_required type_env subject_env proof_env then_
             && body_carries_required type_env subject_env proof_env else_
           | ECase { scrut; arms; _ } ->
             let scrut_ty = infer_expr_type type_env funcs fields_by_type ctors scrut in
             let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
             arms <> [] && List.for_all (fun (arm : case_arm) ->
               let te = pattern_bindings scrut_ty ctors arm.pattern @ type_env in
               let pe, se = extend_case_envs subject_env proof_env scrut scrut_proofs arm.pattern in
               body_carries_required te se pe arm.body
             ) arms
           | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
           | EWithTransaction { body; _ } ->
             body_carries_required type_env subject_env proof_env body
           | EFail _ -> true  (* never returns — no proof obligation on this path *)
           | _ ->
             let result_subject = match subject_of_expr subject_env e with
               | Some s -> s | None -> b.name in
             let required_here = subst_proof [(b.name, result_subject)] required_proof in
             let carried =
               List.map Proof_kernel.fact_of
                 (proofs_of_expr result_subject funcs subject_env proof_env e) in
             proof_matches required_here carried
         in
         if not is_stdlib_auto
            && not (body_carries_required type_env0 subject_env proof_env fd.body) then begin
           let proof_str = pp_proof required_proof in
           let kw = match fd.kind with
             | HandlerKind -> "handler" | WorkerKind -> "worker" | _ -> "fn" in
           errors := make_error ret_loc
             ~hint:(Printf.sprintf
               "receive `%s` with that proof on an input parameter, or use `check %s(...)` \
                to validate it at a boundary; a `%s` cannot introduce new proofs" b.name fd.name kw)
             (Printf.sprintf
               "%s `%s` cannot declare a proof return type (`-> %s ::: %s`) \
                unless `%s` was received with that proof on an input parameter; \
                only `check` and `auth` functions may introduce new proofs"
               kw fd.name (pp_type_expr b.type_expr) proof_str b.name)
           :: !errors
         end
       | RetNamedPack { entity_proof; other_proof; loc; _ } when entity_proof <> None || other_proof <> None ->
         let type_env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
         let subject_env = build_initial_subject_env fd.params in
         let proof_env = build_initial_proof_env fd.params in
         check_named_pack_body fd loc entity_proof other_proof type_env subject_env proof_env fd.body
       (* PFC-2 (b): container-wrapped proof minting.  `Maybe (v: T ::: P v)` /
          `Maybe (T ? P)` / `Either L (T ? P)` / custom eithers all parse to
          RetMaybeAttached.  A forgery-restricted kind must not mint the inner
          proof: every returning SUCCESS payload (a single-arg constructor whose
          payload has the proof's subject TYPE — `Something x`/`Right x`/`CustomRight
          x`, but NOT the error side `Left "e"`:String nor `Nothing`) must CARRY the
          proof.  Field proofs propagate through pattern matching (PFC-2 a), so
          `findMin`'s `Node Leaf cur _ -> Right cur` is accepted (cur carries the
          field proof) while `Something (0 - 999)` is rejected. *)
       | RetMaybeAttached { binding = b; loc = ret_loc; _ }
         when is_forgery_restricted_kind fd.kind && b.proof_ann <> None ->
         let required_proof = match b.proof_ann with Some p -> p | None -> PredApp { pred = ""; args = []; loc = fd.loc } in
         let pred_name = match required_proof with PredApp { pred; _ } -> Some pred | _ -> None in
         let facts = List.filter_map (function DFact f -> Some f | _ -> None) decls in
         let type_name_of = function
           | TName { name; _ } -> Some name
           | TApp { head = TName { name; _ }; _ } -> Some name
           | _ -> None in
         let inner_tyname = match pred_name with
           | Some pn ->
             (match List.find_opt (fun (f : fact_form) -> f.name = pn) facts with
              | Some { params = p :: _; _ } -> type_name_of p.type_expr
              | _ -> None)
           | None -> None in
         let is_stdlib_auto = match pred_name with
           | Some "FromDb" ->
             let user_fn_names = List.filter_map (function DFunc d -> Some d.name | _ -> None) decls in
             (* GDP-FROMDB-DATAFLOW: dataflow, not presence — the RETURNED value
               must flow from the DB site, else a discarded select forges FromDb. *)
            return_value_flows_from_db_site ~shadowed:user_fn_names fd.body
           | Some ("FromQueue" | "FromDeadQueue") -> false
           | Some p -> List.mem p stdlib_auto_preds
           | None -> false in
         (* Skip conservatively when we cannot resolve the inner type (compound /
            unknown predicate) or the proof is framework-auto — no false positives. *)
         (match inner_tyname with
          | Some inner_ty when not is_stdlib_auto ->
            let ctor_fps = build_ctor_field_proof_map decls in
            let ctor_app (e : expr) : (string * expr list) option =
              match collect_call_head_and_args [] e with
              | (EConstructor { name; args = ha; _ }, applied) -> Some (name, ha @ applied)
              | _ -> None in
            let type_env0 = List.map (fun (p : binding) -> (p.name, p.type_expr)) fd.params in
            let subject_env0 = build_initial_subject_env fd.params in
            let proof_env0 = build_initial_proof_env fd.params in
            let rec walk type_env subject_env proof_env (e : expr) =
              match e with
              | ELet { name; value; body; _ } ->
                let te, se, pe = extend_let_envs type_env subject_env proof_env name value in
                walk te se pe body
              | ELetProof { value_name; proof_name; value; body; _ } ->
                let te, se, pe = extend_let_envs type_env subject_env proof_env value_name value in
                let pe = let ps = proofs_of_expr value_name funcs se pe value in
                  if ps = [] then pe else (proof_name, ps) :: pe in
                walk te se pe body
              | EIf { then_; else_; _ } ->
                walk type_env subject_env proof_env then_;
                walk type_env subject_env proof_env else_
              | ECase { scrut; arms; _ } ->
                let scrut_ty = infer_expr_type type_env funcs fields_by_type ctors scrut in
                let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
                List.iter (fun (arm : case_arm) ->
                  let te = pattern_bindings scrut_ty ctors arm.pattern @ type_env in
                  let pe, se = extend_case_envs subject_env proof_env scrut scrut_proofs arm.pattern in
                  (* field-proof propagation (PFC-2 a) for this walk *)
                  let pe, se = match arm.pattern with
                    | PCon { ctor; fields; _ } ->
                      (match List.assoc_opt ctor ctor_fps with
                       | Some fps when List.length fps = List.length fields ->
                         List.fold_left2 (fun (p, s) (fname, proof_opt) (_l, pat) ->
                           match proof_opt, pat with
                           | Some pr, PVar var ->
                             ((var, [Proof_kernel.elaborated Proof_kernel.FieldProof
                                       (subst_proof [(fname, var)] pr)]) :: p,
                              (var, var) :: s)
                           | _ -> (p, s)) (pe, se) fps fields
                       | _ -> (pe, se))
                    | _ -> (pe, se) in
                  walk te se pe arm.body
                ) arms
              | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
              | EWithTransaction { body; _ } -> walk type_env subject_env proof_env body
              | EFail _ -> ()
              | _ ->
                (match ctor_app e with
                 | Some (ctor, [payload]) ->
                   let payload_tyname = match infer_expr_type type_env funcs fields_by_type ctors payload with
                     | Some te -> type_name_of te | None -> None in
                   (* Only demand the proof on the payload whose TYPE is the proof's
                      subject type (the success side); the error side (different type)
                      and nullary constructors carry no obligation. *)
                   if payload_tyname = Some inner_ty then begin
                     let result_subject = match subject_of_expr subject_env payload with
                       | Some s -> s | None -> b.name in
                     let required_here = subst_proof [(b.name, result_subject)] required_proof in
                     let carried =
                       List.map Proof_kernel.fact_of
                         (proofs_of_expr result_subject funcs subject_env proof_env payload) in
                     if not (proof_matches required_here carried) then begin
                       let kw = match fd.kind with
                         | HandlerKind -> "handler" | WorkerKind -> "worker" | _ -> "fn" in
                       errors := make_error ret_loc
                         ~hint:(Printf.sprintf
                           "return the error/empty side, or a value that carries `%s` (validate it with a `check`/`auth`); a `%s` cannot introduce a fresh proof"
                           (pp_proof required_proof) kw)
                         (Printf.sprintf
                           "%s `%s` returns a proof-carrying `%s`, but the value in `%s ...` does not carry `%s`; only `check`/`auth`/`establish` may introduce a fresh proof"
                           kw fd.name (pp_type_expr b.type_expr) ctor (pp_proof required_proof))
                       :: !errors
                     end
                   end
                 | _ -> ())
            in
            walk type_env0 subject_env0 proof_env0 fd.body
          | _ -> ())
       (* Review 2026-07-03 fix (hole #1, mint-outside-boundary): a `-> Fact (P x)`
          return parses to RetPlain{ty=Fact(P x)} and was previously in the
          NO-obligation bucket below ("RetPlain: no proof"), letting a plain fn /
          handler / worker / deadWorker MINT an arbitrary detached fact for a
          value that never crossed a validation boundary — the exact bypass §7.12
          claims is closed.  We now hold RetPlain-Fact to the SAME body-carries-
          the-proof rule as RetAttached.  Because RetPlain has no return binder,
          the fact's declared subject is fixed (a param name / literal), so no
          binder-rename is applied: a body that proves `IsPositive 7` cannot
          satisfy a declared `-> Fact (IsPositive _n)` — this also closes the
          subject-launder (hole #2). check/auth/establish are excluded by the
          outer is_forgery_restricted_kind guard, so they may still mint. *)
       | RetPlain { ty; loc = ret_loc }
         when (match proof_of_fact_type ty with Some _ -> true | None -> false) ->
         let required_proof = match proof_of_fact_type ty with
           | Some p -> p | None -> PredApp { pred = ""; args = []; loc = ret_loc } in
         let required_pred = match required_proof with
           | PredApp { pred; _ } -> Some pred | PredAnd _ -> None in
         let user_fn_names =
           List.filter_map (function DFunc d -> Some d.name | _ -> None) decls in
         let is_stdlib_auto = match required_pred with
           | Some "FromDb" -> return_value_flows_from_db_site ~shadowed:user_fn_names fd.body
           | Some ("FromQueue" | "FromDeadQueue") -> false
           | Some p -> List.mem p stdlib_auto_preds
           | None -> false in
         let subject_env = build_initial_subject_env fd.params in
         let proof_env = build_initial_proof_env fd.params in
         let type_env0 = List.map (fun (p : binding) -> (p.name, p.type_expr)) fd.params in
         let rec body_carries type_env subject_env proof_env (e : expr) : bool =
           match e with
           | ELet { name; value; body; _ } ->
             let te, se, pe = extend_let_envs type_env subject_env proof_env name value in
             body_carries te se pe body
           | ELetProof { value_name; proof_name; value; body; _ } ->
             let te, se, pe = extend_let_envs type_env subject_env proof_env value_name value in
             let pe = let ps = proofs_of_expr value_name funcs se pe value in
               if ps = [] then pe else (proof_name, ps) :: pe in
             body_carries te se pe body
           | EIf { then_; else_; _ } ->
             body_carries type_env subject_env proof_env then_
             && body_carries type_env subject_env proof_env else_
           | ECase { scrut; arms; _ } ->
             let scrut_ty = infer_expr_type type_env funcs fields_by_type ctors scrut in
             let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
             arms <> [] && List.for_all (fun (arm : case_arm) ->
               let te = pattern_bindings scrut_ty ctors arm.pattern @ type_env in
               let pe, se = extend_case_envs subject_env proof_env scrut scrut_proofs arm.pattern in
               body_carries te se pe arm.body) arms
           | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
           | EWithTransaction { body; _ } -> body_carries type_env subject_env proof_env body
           | EFail _ -> true
           | _ ->
             let result_subject = match subject_of_expr subject_env e with
               | Some s -> s | None -> "_" in
             let carried =
               List.map Proof_kernel.fact_of
                 (proofs_of_expr result_subject funcs subject_env proof_env e) in
             proof_matches required_proof carried
         in
         if not is_stdlib_auto
            && not (body_carries type_env0 subject_env proof_env fd.body) then begin
           let kw = match fd.kind with
             | HandlerKind -> "handler" | WorkerKind -> "worker"
             | DeadWorkerKind -> "deadworker" | MainKind -> "main" | _ -> "fn" in
           errors := make_error ret_loc
             ~hint:(Printf.sprintf
               "receive that `Fact (...)` on an input parameter, or validate the value \
                with a `check`/`auth`/`establish`; a `%s` cannot introduce a fresh proof" kw)
             (Printf.sprintf
               "%s `%s` cannot declare a `-> Fact (%s)` return unless that proof was \
                received on an input parameter; only `check`/`auth`/`establish` may \
                introduce a fresh proof"
               kw fd.name (pp_proof required_proof))
           :: !errors
         end
       (* All remaining return specs carry no forgery obligation in THIS gate:
            - RetPlain (non-Fact): no proof (the Fact case is handled just above).
            - RetForAll / RetMaybeForAll / RetSetForAll / RetMaybeSetForAll /
              RetForAllDictValues / RetForAllDictKeys: validated by
              Validation_proof.check_forall_consistency.
            - RetExists: validated by
              Validation_proof.check_existential_proof_enforcement.
            - the guard-FALSE cases of the three specs handled above (e.g. an
              attached / named-pack / maybe return with no proof annotation).
          Enumerated (NOT a wildcard) so -warn-error +8 forces a decision here
          when a new return_spec constructor is added — fail-closed on new AST
          shapes rather than silently skipping the forgery restriction. *)
       | RetPlain _ | RetForAll _ | RetMaybeForAll _ | RetSetForAll _
       | RetMaybeSetForAll _ | RetForAllDictValues _ | RetForAllDictKeys _
       | RetExists _ | RetAttached _ | RetNamedPack _ | RetMaybeAttached _ -> ())
    | _ -> ()
  ) decls;
  field_proof_registry := [];
  field_proof_type_ctx := None;
  List.rev !errors
