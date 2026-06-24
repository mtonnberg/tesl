open Ast
open Location
open Validation_common
open Validation_structural
open Validation_proof
open Validation_names

let build_record_field_bindings (decls : top_decl list)
    : (string * binding list) list =
  List.filter_map (function
    | DRecord r ->
      let annotated = List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | None -> None
        | Some proof ->
          Some { name = f.name; type_expr = f.type_expr;
                 proof_ann = Some proof; loc = f.loc }
      ) r.fields in
      if annotated = [] then None else Some (r.name, annotated)
    | _ -> None
  ) decls

(** R51_SQ01 / R51_SQ02 / R51_SQ03 — SQL where-clause RHS validation.

    The where-clause LHS (`t.field`) has long been checked by
    `validate_field_accesses` (the "unknown field" error). The RHS and the
    `isNull`/`isNotNull` predicates were not. This pass adds:

      - type-compatibility between `t.field` and the RHS of a comparison
        (rejects `where t.title == 5` when `title: String`);
      - scope-check for identifiers on the RHS (rejects `where t.x == foo`
        when `foo` is not bound);
      - a `Maybe T` check for `isNull`/`isNotNull` (rejects these on
        non-nullable columns). *)
let check_sql_where_clauses
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls in
  (* Newtypes are transparent at JSON/SQL boundaries (spec §11.6). Build a map
     from newtype head name to its base-type head name so SQL WHERE comparisons
     against a newtype field can accept the underlying primitive literal. *)
  let newtype_base : (string * string) list =
    List.filter_map (function
      | DType (TypeNewtype { name; base_type; _ }) ->
        (match type_head_name base_type with
         | Some base -> Some (name, base)
         | None -> None)
      | _ -> None
    ) decls
  in
  let rec resolve_nt (k : string) : string =
    match List.assoc_opt k newtype_base with
    | Some base when base <> k -> resolve_nt base
    | _ -> k
  in
  let errors = ref [] in
  let emit err = errors := err :: !errors in
  let scan_predicate tenv binder_env bound_names pred =
    let check_field_rhs binder field op right_expr loc =
      match List.assoc_opt binder binder_env with
      | None -> ()
      | Some entity_name ->
        let entity_fields =
          record_fields_of_type fields_by_type (mk_name_type entity_name)
        in
        (match entity_fields with
         | None -> ()
         | Some efs ->
           (match List.find_opt (fun (f : field_def) -> f.name = field) efs with
            | None -> ()
            | Some f ->
              let field_ty = f.type_expr in
              (match right_expr with
               | EVar { name; _ }
                 when not (List.mem name bound_names)
                   && not (List.mem_assoc name binder_env)
                   && not (List.mem_assoc name funcs)
                   && not (List.mem_assoc name tenv) ->
                 emit (make_error loc
                   ~hint:(Printf.sprintf
                     "`%s` is not in scope; bind it with `let %s = ...` or pass it in as a parameter"
                     name name)
                   (Printf.sprintf
                     "SQL WHERE clause references unbound identifier `%s`"
                     name))
               | _ ->
                 (match infer_expr_type tenv funcs fields_by_type ctors right_expr with
                  | None -> ()
                  | Some rhs_ty ->
                    let fk = resolve_nt (type_key field_ty) in
                    let rk = resolve_nt (type_key rhs_ty) in
                    if fk <> rk then
                      emit (make_error loc
                        ~hint:(Printf.sprintf
                          "field `%s` is declared as `%s` — wrap the RHS in a `check` or convert it to the same type"
                          field (type_key field_ty))
                        (Printf.sprintf
                          "SQL WHERE clause: type mismatch for `%s.%s %s <rhs>` — field type is `%s`, RHS is `%s`"
                          binder field op (type_key field_ty) (type_key rhs_ty)))))))
    in
    let check_isnull binder field loc =
      match List.assoc_opt binder binder_env with
      | None -> ()
      | Some entity_name ->
        let entity_fields =
          record_fields_of_type fields_by_type (mk_name_type entity_name)
        in
        (match entity_fields with
         | None -> ()
         | Some efs ->
           (match List.find_opt (fun (f : field_def) -> f.name = field) efs with
            | None -> ()
            | Some f ->
              let is_nullable = match f.type_expr with
                | TApp { head = TName { name = "Maybe"; _ }; _ } -> true
                | _ -> false
              in
              if not is_nullable then
                emit (make_error loc
                  ~hint:(Printf.sprintf
                    "declare the field as `%s: Maybe %s` to allow NULL, or remove the `isNull` check"
                    field (type_key f.type_expr))
                  (Printf.sprintf
                    "SQL WHERE clause: `isNull %s.%s` is always false because field `%s` is NOT NULL (declared as `%s`)"
                    binder field field (type_key f.type_expr)))))
    in
    match pred with
    | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe) as op; left; right; loc } ->
      (match left with
       | EField { obj = EVar { name = b; _ }; field; _ } ->
         let op_str = match op with
           | BEq -> "==" | BNeq -> "!=" | BLt -> "<" | BLe -> "<="
           | BGt -> ">" | BGe -> ">=" | _ -> "?"
         in
         check_field_rhs b field op_str right loc
       | _ -> ())
    | EApp { fn = EVar { name = ("isNull" | "isNotNull"); _ };
             arg = EField { obj = EVar { name = b; _ }; field; _ }; loc } ->
      check_isnull b field loc
    | _ -> ()
  in
  let rec walk tenv binder_env bound_names e =
    match e with
    | EApp _ ->
      let flat =
        let rec go acc = function
          | EApp { fn; arg; _ } -> go (arg :: acc) fn
          | hd -> (hd, acc)
        in go [] e
      in
      let head, args = flat in
      let binder_env' = match head with
        | EVar { name = ("selectOne" | "select" | "selectCount"
                       | "selectSum" | "selectMax" | "selectMin"
                       | "update" | "delete" | "deleteAndReturnResult"); _ } ->
          let binder_name = match args with
            | EVar { name; _ } :: _ -> Some name
            | EField { obj = EVar { name; _ }; _ } :: _ -> Some name
            | _ -> None
          in
          let entity_name =
            let rec find_entity = function
              | EVar { name = ("from" | "in"); _ } :: EConstructor { name; _ } :: _ -> Some name
              | EVar { name = ("from" | "in"); _ } :: EVar { name; _ } :: _ -> Some name
              | _ :: rest -> find_entity rest
              | [] -> None
            in find_entity args
          in
          (match binder_name, entity_name with
           | Some bn, Some en -> (bn, en) :: binder_env
           | _ -> binder_env)
        | _ -> binder_env
      in
      List.iter (fun arg ->
        (match arg with
         | EApp { fn = EVar { name = "where"; _ }; arg = pred_expr; _ } ->
           scan_predicate tenv binder_env' bound_names pred_expr
         | _ -> ());
        walk tenv binder_env' bound_names arg
      ) args;
      (* Additional scan: in a flattened select chain, `isNull t.field`
         appears as two adjacent atoms — `EVar "isNull"` and
         `EField { obj = EVar t; field }` — not as a single `EApp`. *)
      let rec scan_pairs = function
        | EVar { name = ("isNull" | "isNotNull"); _ }
          :: (EField { obj = EVar { name = b; _ }; field; loc } as fld)
          :: rest ->
          scan_predicate tenv binder_env' bound_names
            (EApp { fn = EVar { name = "isNull"; loc };
                    arg = fld; loc });
          ignore b; ignore field;
          scan_pairs rest
        | _ :: rest -> scan_pairs rest
        | [] -> ()
      in
      scan_pairs args
    | ELet { name; value; body; _ } ->
      walk tenv binder_env bound_names value;
      let tenv' = match infer_expr_type tenv funcs fields_by_type ctors value with
        | Some ty -> (name, ty) :: tenv
        | None -> tenv
      in
      walk tenv' binder_env (name :: bound_names) body
    | ELetProof { value_name; proof_name; value; body; _ } ->
      walk tenv binder_env bound_names value;
      let bound' =
        (if value_name = "_" then [] else [value_name]) @
        (if proof_name  = "_" then [] else [proof_name])  @
        bound_names
      in
      walk tenv binder_env bound' body
    | EIf { cond; then_; else_; _ } ->
      walk tenv binder_env bound_names cond;
      walk tenv binder_env bound_names then_;
      walk tenv binder_env bound_names else_
    | ECase { scrut; arms; _ } ->
      walk tenv binder_env bound_names scrut;
      List.iter (fun (arm : case_arm) ->
        let bound = pattern_bound_names arm.pattern @ bound_names in
        (match arm.guard with
         | Some g -> walk tenv binder_env bound g
         | None -> ());
        walk tenv binder_env bound arm.body
      ) arms
    | ERecord { fields; _ } ->
      List.iter (fun (_, v) -> walk tenv binder_env bound_names v) fields
    | EList { elems; _ } ->
      List.iter (walk tenv binder_env bound_names) elems
    | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe) as op; left; right; loc } ->
      walk tenv binder_env bound_names left;
      walk tenv binder_env bound_names right;
      (* Detect SQL WHERE comparison: the top-level EBinop's LEFT is a
         flattened select...where chain whose last atom is `binder.field`. *)
      let rec flatten_atoms acc = function
        | EApp { fn; arg; _ } -> flatten_atoms (arg :: acc) fn
        | hd -> hd :: acc
      in
      let atoms = flatten_atoms [] left in
      (match atoms with
       | EVar { name = ("select" | "selectOne" | "selectCount"
                      | "selectSum" | "selectMax" | "selectMin"
                      | "update" | "delete" | "deleteAndReturnResult"); _ }
         :: _ ->
         (* Find the binder (first arg) and the entity (after "from" or "in"). *)
         let binder_name = match atoms with
           | _ :: EVar { name; _ } :: _ -> Some name
           | _ :: EField { obj = EVar { name; _ }; _ } :: _ -> Some name
           | _ -> None
         in
         let entity_name =
           let rec find_entity = function
             | EVar { name = ("from" | "in"); _ } :: EConstructor { name; _ } :: _ -> Some name
             | EVar { name = ("from" | "in"); _ } :: EVar { name; _ } :: _ -> Some name
             | _ :: rest -> find_entity rest
             | [] -> None
           in find_entity atoms
         in
         let binder_env' = match binder_name, entity_name with
           | Some bn, Some en -> (bn, en) :: binder_env
           | _ -> binder_env
         in
         (* The final atom before the right side of the EBinop is the LHS of
            the comparison — e.g. `t.title` in `where t.title == 5`. *)
         let last_atom = match List.rev atoms with a :: _ -> a | [] -> left in
         (match last_atom with
          | EField { obj = EVar { name = b; _ }; field; _ } ->
            let op_str = match op with
              | BEq -> "==" | BNeq -> "!=" | BLt -> "<" | BLe -> "<="
              | BGt -> ">" | BGe -> ">=" | _ -> "?"
            in
            let fake_pred = EBinop { op; left = last_atom; right; loc } in
            let _ = op_str in
            scan_predicate tenv binder_env' bound_names fake_pred;
            (* Also scan for isNull on the last atom if it appears via EApp *)
            ignore b; ignore field
          | _ -> ())
       | _ -> ())
    | EBinop { left; right; _ } ->
      walk tenv binder_env bound_names left;
      walk tenv binder_env bound_names right
    | EUnop { arg; _ } -> walk tenv binder_env bound_names arg
    | EOk { value; _ } -> walk tenv binder_env bound_names value
    | ETelemetry { fields; _ } ->
      List.iter (fun (_, v) -> walk tenv binder_env bound_names v) fields
    | EEnqueue { payload; _ } -> walk tenv binder_env bound_names payload
    | EPublish { key; payload; _ } ->
      (match key with Some k -> walk tenv binder_env bound_names k | None -> ());
      (match payload with Some p -> walk tenv binder_env bound_names p | None -> ())
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> walk tenv binder_env bound_names body
    | EServe { port; _ } -> walk tenv binder_env bound_names port
    | ELambda { params; body; _ } ->
      let bound' = List.map (fun (b : binding) -> b.name) params @ bound_names in
      walk tenv binder_env bound' body
    | _ -> ()
  in
  List.iter (function
    | DFunc fd ->
      let param_tenv = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
      let param_names = List.map (fun (b : binding) -> b.name) fd.params in
      walk param_tenv [] param_names fd.body
    | _ -> ()
  ) decls;
  List.rev !errors

(** Check that every record construction expression satisfies the proof
    annotations declared on the fields being assigned.  This ensures that
    `SafeReq { count: rawInt }` cannot pass a non-validated Int to a field
    declared as `count: Int ::: IsPositive count`. *)
let check_record_field_proof_construction
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let rec_bindings = build_record_field_bindings decls in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls in
  if rec_bindings = [] then []
  else
    let errors = ref [] in
    (* Walk expressions accumulating type_env, subject_env and proof_env.  When we
       encounter a typed record construction whose record has proof-annotated
       fields, delegate to check_call_proofs treating fields as parameters. *)
    let rec walk_expr (type_env : type_env) (subject_env : subject_env) (proof_env : proof_env) (e : expr) =
      match e with
      | EApp {
          fn = EConstructor { name = rname; args = []; _ };
          arg = ERecord { fields; loc = rloc; _ };
          _;
        } when List.mem_assoc rname rec_bindings ->
        (* First recurse into the field values *)
        List.iter (fun (_, v) -> walk_expr type_env subject_env proof_env v) fields;
        (* Then check field proof requirements *)
        let field_bindings = List.assoc rname rec_bindings in
        (* Build an argument list aligned to the annotated fields *)
        let args = List.filter_map (fun (b : binding) ->
          List.assoc_opt b.name fields
        ) field_bindings in
        let checked = check_call_proofs ~funcs rloc rname field_bindings args subject_env proof_env in
        errors := checked @ !errors
      (* Record update: { r | field = val } — check proof requirements on updated fields *)
      | EApp {
          fn = EVar { name = "#record-update#"; _ };
          arg = ERecord { fields; loc = rloc; _ };
          _;
        } ->
        List.iter (fun (fn, fv) ->
          if fn <> "__base__" then walk_expr type_env subject_env proof_env fv
        ) fields;
        (match List.assoc_opt "__base__" fields with
         | Some base_expr ->
           walk_expr type_env subject_env proof_env base_expr;
           (match infer_expr_type type_env funcs fields_by_type ctors base_expr with
            | Some base_ty ->
              let rname = match base_ty with
                | TName { name; _ } -> name
                | TApp { head = TName { name; _ }; _ } -> name
                | _ -> ""
              in
              (match List.assoc_opt rname rec_bindings with
               | None -> ()
               | Some field_bindings ->
                 let updated_bindings = List.filter (fun (b : binding) ->
                   List.mem_assoc b.name fields
                 ) field_bindings in
                 if updated_bindings <> [] then begin
                   let updated_args = List.filter_map (fun (b : binding) ->
                     List.assoc_opt b.name fields
                   ) updated_bindings in
                   let checked = check_call_proofs ~funcs rloc rname updated_bindings updated_args subject_env proof_env in
                   errors := checked @ !errors
                 end)
            | None -> ())
         | None -> ())
      | EApp _ ->
        let (_, args) = collect_call_head_and_args [] e in
        List.iter (walk_expr type_env subject_env proof_env) args
      | ELet { name; value; body; _ } ->
        walk_expr type_env subject_env proof_env value;
        let subject_env' = match subject_of_expr subject_env value with
          | Some s -> (name, s) :: subject_env
          | None ->
            (* For direct check-fn calls (RetAttached), propagate the subject of the
               return-bound argument to the let-binder, mirroring check_expr_call_proofs. *)
            (match value with
             | EApp _ ->
               let (head0, args0) = collect_call_head_and_args [] value in
               let (head, args) = normalize_explicit_check_call head0 args0 in
               (match function_name_of_expr head with
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
        let proof_env' = if new_proofs = [] then proof_env
                         else (name, new_proofs) :: proof_env in
        let type_env' = match infer_expr_type type_env funcs fields_by_type ctors value with
          | Some ty -> (name, ty) :: type_env
          | None -> type_env
        in
        walk_expr type_env' subject_env' proof_env' body
      | ELetProof { value_name; proof_name; value; body; _ } ->
        walk_expr type_env subject_env proof_env value;
        let subject_env' = match subject_of_expr subject_env value with
          | Some s -> (value_name, s) :: subject_env
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
        (* Propagate proofs: proof_name gets the detached proofs from the value.
           Mirror the logic in check_expr_call_proofs's ELetProof handler. *)
        let detached_proofs =
          let carried = match carried_proofs_of_expr ~funcs subject_env proof_env value with
            | Some proofs -> proofs
            | None -> []
          in
          if carried <> [] then carried
          else proofs_of_expr value_name funcs subject_env' proof_env value
        in
        let proof_env' =
          if proof_name <> "_" && detached_proofs <> [] then
            (proof_name, detached_proofs) :: proof_env
          else proof_env
        in
        walk_expr type_env subject_env' proof_env' body
      | EIf { cond; then_; else_; _ } ->
        walk_expr type_env subject_env proof_env cond;
        walk_expr type_env subject_env proof_env then_;
        walk_expr type_env subject_env proof_env else_
      | ECase { scrut; arms; _ } ->
        walk_expr type_env subject_env proof_env scrut;
        (* R51_P03 — propagate case-arm binder proofs.
           For `case scrut of Something p -> body`, the `p` binder carries
           the proofs extracted from the scrut's Maybe (Fact P) shape.  We
           mirror the logic in `check_expr_call_proofs`'s ECase handler so
           the record-field-proof pass can resolve `value ::: p` in the
           arm body, making `Holder { v: x ::: p }` accept the same proof
           evidence that the direct call form already does. *)
        let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
        List.iter (fun (arm : case_arm) ->
          let proof_env' = match arm.pattern with
            | PCon { fields = [(_, PVar x)]; _ } when scrut_proofs <> [] ->
              (x, scrut_proofs) :: proof_env
            | _ -> proof_env
          in
          walk_expr type_env subject_env proof_env' arm.body
        ) arms
      | EOk { value; _ } -> walk_expr type_env subject_env proof_env value
      | ELambda { params; body; _ } ->
        let type_env' = List.fold_left (fun acc (b : binding) ->
          (b.name, b.type_expr) :: acc) type_env params in
        let subject_env' = List.fold_left (fun acc (b : binding) ->
          (b.name, b.name) :: acc) subject_env params in
        let proof_env' = List.fold_left (fun acc (b : binding) ->
          match b.proof_ann with
          | Some p -> (b.name, [p]) :: acc
          | None -> acc) proof_env params in
        walk_expr type_env' subject_env' proof_env' body
      | EList { elems; _ } -> List.iter (walk_expr type_env subject_env proof_env) elems
      | ERecord { fields; _ } ->
        List.iter (fun (_, v) -> walk_expr type_env subject_env proof_env v) fields
      | EBinop { left; right; _ } ->
        walk_expr type_env subject_env proof_env left;
        walk_expr type_env subject_env proof_env right
      | EUnop { arg; _ } -> walk_expr type_env subject_env proof_env arg
      | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
      | EWithTransaction { body; _ } -> walk_expr type_env subject_env proof_env body
      | ETelemetry { fields; _ } ->
        List.iter (fun (_, v) -> walk_expr type_env subject_env proof_env v) fields
      | EEnqueue { payload; _ } -> walk_expr type_env subject_env proof_env payload
      | EPublish { key; payload; _ } ->
        (match key with Some e -> walk_expr type_env subject_env proof_env e | None -> ());
        (match payload with Some e -> walk_expr type_env subject_env proof_env e | None -> ())
      | EServe { port; _ } -> walk_expr type_env subject_env proof_env port
      | EConstructor { args; _ } ->
        List.iter (walk_expr type_env subject_env proof_env) args
      | EStartWorkers _ | ELit _ | EVar _ | EField _ | EFail _ -> ()
    in
    List.iter (function
      | DFunc fd ->
        let type_env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
        let subject_env = build_initial_subject_env fd.params in
        let proof_env = build_initial_proof_env fd.params in
        walk_expr type_env subject_env proof_env fd.body
      | _ -> ()
    ) decls;
    List.rev !errors

(** Forbid [fn] functions from declaring proof return types that cannot be
    established by the function's parameters.

    A [fn] may propagate an existing proof from a parameter (e.g.,
    [fn f(n: Int ::: P n) -> n: Int ::: P n = n] is a passthrough) but must
    not claim a proof the params do not already carry, because [fn] has no
    mechanism to establish new proofs at runtime — that is the job of [check]
    and [auth].

    Accepts: [fn f(n: Int ::: P n) -> n: Int ::: P n = n]  (passthrough)
    Rejects: [fn liar(n: Int) -> n: Int ::: P n = n]        (new proof, not from params) *)
let check_fn_return_proof_annotations
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls in
  field_proof_registry := build_field_proof_map decls;
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
  let stdlib_auto_preds =
    [ "FromDb"; "FromQueue"; "ForAll"; "ForAllValues"; "ForAllKeys";
      "HasKey"; "IsNonZero"; "IsNonNegative"; "IsNonEmpty"; "FloatNonZero" ] in
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
      let carried =
        let base = proofs_of_expr result_subject funcs subject_env proof_env expr in
        (* For EOk { value = EVar name; proof = p }, the check call's proofs
           are stored under "_" in proof_env (auto-unpack lets).  Supplement
           carried proofs with those entries, substituting "_" subjects. *)
        let all_underscore_proofs = List.concat (
          List.filter_map (fun (k, v) -> if k = "_" then Some v else None) proof_env
        ) in
        if all_underscore_proofs <> [] then
          let fix_subject p =
            let rec go = function
              | PredApp { pred; args; loc } ->
                PredApp { pred; args = List.map (fun a -> if a = "_" then result_subject else a) args; loc }
              | PredAnd { left; right; loc } ->
                PredAnd { left = go left; right = go right; loc }
            in go p
          in
          let fixed = List.map fix_subject all_underscore_proofs in
          let seen_keys = ref (List.map proof_key base) in
          let deduped = List.filter (fun p ->
            let k = proof_key p in
            if List.mem k !seen_keys then false
            else (seen_keys := k :: !seen_keys; true)
          ) fixed in
          base @ deduped
        else base
      in
      let kind_label = match fd.kind with HandlerKind -> "handler" | _ -> "fn" in
      let check_required kind required =
        let required_pred = match required with PredApp { pred; _ } -> Some pred | _ -> None in
        let is_stdlib_auto = match required_pred with Some pred -> List.mem pred stdlib_auto_preds | None -> false in
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
           (* When subject_of_expr failed (result_subject = "__named_pack_result"),
              try each unique subject name from the carried proofs as the entity subject.
              The entity proof says "the returned value has this proof" — if the carried
              proofs use a specific name, that's the actual entity identity. *)
           let flat_carried = List.concat_map flatten_proof_conj carried in
           let carried_subjects =
             List.filter_map (fun (p : proof_expr) ->
               match p with
               | PredApp { args; _ } -> (match List.rev args with s :: _ -> Some s | [] -> None)
               | _ -> None
             ) flat_carried
           in
           (* Also collect subjects from ALL argument positions, not just last,
              since the entity may appear in any position depending on the fact declaration *)
           let all_arg_subjects =
             List.concat_map (fun (p : proof_expr) ->
               match p with
               | PredApp { args; _ } -> args
               | _ -> []
             ) flat_carried
           in
           let unique_subjects = List.sort_uniq String.compare (carried_subjects @ all_arg_subjects) in
           let found_match = List.exists (fun subj ->
             let alt_required = subst_proof (("_entity", subj) :: param_mapping) expanded in
             proof_matches alt_required carried
           ) unique_subjects in
           (* If still no match, try normalising carried proofs to entity-proof arg order:
              explicit args first, entity subject last (matching expand_entity_proof_group) *)
           let found_match = found_match || (
             let reorder_to_entity_order (p : proof_expr) =
               match p with
               | PredApp { pred; args; loc } when List.length args >= 2 ->
                 (* For each possible entity position, try moving it to last *)
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
           ) in
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
  List.iter (function
    | DFunc fd when fd.kind = FnKind || fd.kind = HandlerKind ->
      (match fd.return_spec with
       | RetAttached { binding = b; loc = ret_loc } when fd.kind = FnKind && b.proof_ann <> None ->
         (* The guard `b.proof_ann <> None` ensures Some here; use Option.get with safe fallback *)
         let required_proof = match b.proof_ann with Some p -> p | None -> PredApp { pred = ""; args = []; loc = ret_loc } in
         let proof_env = build_initial_proof_env fd.params in
         let subject_env = build_initial_subject_env fd.params in
         let record_field_map = List.filter_map (function
           | DRecord r -> Some (r.name, r.fields)
           | DEntity e -> Some (e.name, e.fields)
           | _ -> None
         ) decls in
         let param_type_names = List.filter_map (fun (p : binding) ->
           match p.type_expr with
           | TName { name; _ } -> Some name
           | _ -> None
         ) fd.params in
         let field_carried = List.concat_map (fun tn ->
           match List.assoc_opt tn record_field_map with
           | None -> []
           | Some fields ->
             List.filter_map (fun (f : field_def) ->
               match f.proof_ann with Some p -> Some p | None -> None
             ) fields
         ) param_type_names in
         let binding_subject = match List.assoc_opt b.name subject_env with Some s -> s | None -> b.name in
         let required_norm = subst_proof [(b.name, binding_subject)] required_proof in
         let required_pred = match required_norm with PredApp { pred; _ } -> Some pred | _ -> None in
         let is_stdlib_auto = match required_pred with Some p -> List.mem p stdlib_auto_preds | None -> false in
         let all_carried = List.concat_map snd proof_env @ field_carried in
         (* `fn f ... -> T ::: Proof` is legitimate when the body introduces
            the proof via `attachFact` (with an `establish`-produced Fact) or
            via an explicit `ok v ::: Proof`. Walk the body for either shape —
            if found, trust the existing call-proof validators to catch
            misuse and skip the conservative rejection. *)
         let rec body_uses_attach_or_ok (e : expr) : bool =
           match e with
           | EOk _ -> true
           | EApp _ ->
             let rec head = function
               | EApp { fn = f; _ } -> head f
               | x -> x
             in
             (match head e with
              | EVar { name = n; _ }
                when n = "attachFact" || n = "attach" -> true
              | _ ->
                let rec args_of acc = function
                  | EApp { fn = f; arg = a; _ } -> args_of (a :: acc) f
                  | _ -> acc
                in
                List.exists body_uses_attach_or_ok (args_of [] e))
           | ELet { value = v; body = b; _ }
           | ELetProof { value = v; body = b; _ } ->
             body_uses_attach_or_ok v || body_uses_attach_or_ok b
           | EIf { cond; then_; else_; _ } ->
             body_uses_attach_or_ok cond
             || body_uses_attach_or_ok then_
             || body_uses_attach_or_ok else_
           | ECase { scrut; arms; _ } ->
             body_uses_attach_or_ok scrut
             || List.exists (fun (a : case_arm) ->
                  body_uses_attach_or_ok a.body
                  || (match a.guard with
                      | Some g -> body_uses_attach_or_ok g
                      | None -> false)) arms
           | EBinop { left; right; _ } ->
             body_uses_attach_or_ok left || body_uses_attach_or_ok right
           | EUnop { arg; _ } -> body_uses_attach_or_ok arg
           | EField { obj; _ } -> body_uses_attach_or_ok obj
           | ERecord { fields; _ } ->
             List.exists (fun (_, v) -> body_uses_attach_or_ok v) fields
           | EList { elems; _ } -> List.exists body_uses_attach_or_ok elems
           | EFail { message; _ } -> body_uses_attach_or_ok message
           | EWithDatabase { body = b; _ }
           | EWithCapabilities { body = b; _ }
           | EWithTransaction { body = b; _ } -> body_uses_attach_or_ok b
           | EConstructor { args; _ } -> List.exists body_uses_attach_or_ok args
           | ELambda { body = b; _ } -> body_uses_attach_or_ok b
           | _ -> false
         in
         if not is_stdlib_auto
            && not (proof_matches required_norm all_carried)
            && not (body_uses_attach_or_ok fd.body) then begin
           let proof_str = pp_proof required_proof in
           errors := make_error ret_loc
             ~hint:(Printf.sprintf
               "use `check %s(...)` to validate and return a proof-carrying value; \
                `fn` cannot introduce new proofs" fd.name)
             (Printf.sprintf
               "fn `%s` cannot declare a proof return type (`-> %s ::: %s`); \
                only `check` and `auth` functions may have proof return types"
               fd.name (pp_type_expr b.type_expr) proof_str)
           :: !errors
         end
       | RetNamedPack { entity_proof; other_proof; loc; _ } when entity_proof <> None || other_proof <> None ->
         let type_env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
         let subject_env = build_initial_subject_env fd.params in
         let proof_env = build_initial_proof_env fd.params in
         check_named_pack_body fd loc entity_proof other_proof type_env subject_env proof_env fd.body
       | _ -> ())
    | _ -> ()
  ) decls;
  field_proof_registry := [];
  List.rev !errors

(** Check that top-level value bindings ([DConst]) do not form cycles.
    Cyclic initialisations such as [x = y + 1; y = x + 1] compile but produce
    undefined values at runtime. *)
let check_circular_const_bindings (decls : top_decl list) : validation_error list =
  let const_decls = List.filter_map (function
    | DConst c -> Some c
    | _ -> None
  ) decls in
  if List.length const_decls < 2 then []
  else
    let const_names = List.map (fun (c : const_form) -> c.name) const_decls in
    let name_set = List.sort_uniq String.compare const_names in
    let refs_of_expr e =
      let refs = ref [] in
      let rec walk = function
        | EVar { name; _ } when List.mem name name_set -> refs := name :: !refs
        | EVar _ | ELit _ | EFail _ | EStartWorkers _ -> ()
        | EApp { fn; arg; _ } -> walk fn; walk arg
        | ELet { value; body; _ } | ELetProof { value; body; _ } ->
          walk value; walk body
        | EIf { cond; then_; else_; _ } -> walk cond; walk then_; walk else_
        | ECase { scrut; arms; _ } ->
          walk scrut; List.iter (fun (a : case_arm) -> walk a.body) arms
        | EBinop { left; right; _ } -> walk left; walk right
        | EUnop { arg; _ } -> walk arg
        | EField { obj; _ } -> walk obj
        | EList { elems; _ } -> List.iter walk elems
        | ERecord { fields; _ } -> List.iter (fun (_, v) -> walk v) fields
        | EConstructor { args; _ } -> List.iter walk args
        | ELambda { body; _ } -> walk body
        | EOk { value; _ } -> walk value
        | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
        | EWithTransaction { body; _ } -> walk body
        | ETelemetry { fields; _ } -> List.iter (fun (_, v) -> walk v) fields
        | EEnqueue { payload; _ } -> walk payload
        | EPublish { key; payload; _ } ->
          (match key with Some e -> walk e | None -> ());
          (match payload with Some e -> walk e | None -> ())
        | EServe { port; _ } -> walk port
      in
      walk e;
      List.sort_uniq String.compare !refs
    in
    let deps = List.map (fun (c : const_form) -> (c.name, refs_of_expr c.value)) const_decls in
    let errors = ref [] in
    (* DFS with white/gray/black colouring: gray = on stack (cycle if revisited) *)
    let color : (string, int) Hashtbl.t = Hashtbl.create (List.length const_decls) in
    let rec dfs name =
      match Hashtbl.find_opt color name with
      | Some 2 -> ()
      | Some 1 ->
        (match List.find_opt (fun (c : const_form) -> c.name = name) const_decls with
         | Some c ->
           errors := make_error c.loc
             ~hint:"split into independent bindings, or use a \
                    function (`fn`) to break the cycle"
             (Printf.sprintf
               "circular binding: `%s` depends on itself transitively; \
                module-level value bindings cannot form cycles"
               name)
           :: !errors
         | None -> ())
      | _ ->
        Hashtbl.replace color name 1;
        (match List.assoc_opt name deps with
         | Some dep_names -> List.iter dfs dep_names
         | None -> ());
        Hashtbl.replace color name 2
    in
    List.iter dfs const_names;
    List.rev !errors

(* ── 3c. Ghost witness predicate validation ──────────────────────────────── *)

(** For each record type that declares a cross-field invariant (`::: Pred a b`),
    check that ghost witnesses supplied at construction sites carry a proof whose
    predicate matches the declared invariant predicate.
    E.g. `SafeOrder { ... } ::: wrongProof` where `wrongProof` carries
    `WrongFact x` instead of `PriceGtQty price quantity` should be rejected. *)
let check_ghost_witness_predicates (decls : top_decl list)
    : validation_error list =
  (* Build map: record_name → invariant predicate name *)
  let record_invariants : (string * string) list =
    List.filter_map (function
      | DRecord r ->
        (match r.invariant with
         | Some inv ->
           (* Extract the top-level predicate name from the invariant proof *)
           let pred = match inv.proof_text with
             | PredApp { pred; _ } -> pred
             | PredAnd _ ->
               (* For && invariants, use the first predicate *)
               (match flatten_proof inv.proof_text with
                | PredApp { pred; _ } :: _ -> pred
                | _ -> "")
           in
           if pred = "" then None else Some (r.name, pred)
         | None -> None)
      | _ -> None
    ) decls
  in
  if record_invariants = [] then []
  else
    let errors = ref [] in
    (* Check if a proof expression could plausibly carry the required predicate.
       This is checked conservatively: we only flag definite mismatches where the
       proof is a simple PredApp with a different predicate name, or a conjunction
       where no part matches. *)
    let pred_of_fact_type (te : type_expr) : string option =
      (* type_expr for a Fact parameter: Fact (PredName ...) or Fact PredName *)
      let rec inner = function
        | TApp { head; arg; _ } ->
          (match head with
           | TName { name = "Fact"; _ } -> inner arg
           | _ -> inner head)
        | TName { name; _ } when name <> "Fact" -> Some name
        | _ -> None
      in
      inner te
    in
    (* Build a map from parameter names that have Fact(...) type to their predicate.
       IMPORTANT: only include params whose actual type_expr is `TApp { head = Fact; arg = ... }`
       (i.e. truly Fact-typed params), not params with plain types like `Int` or `String`.
       `pred_of_fact_type` extracts the predicate but returns `Some name` for plain TName too —
       we must guard against that by checking the outer type wrapper is Fact. *)
    let is_fact_typed (te : type_expr) : bool =
      match te with
      | TApp { head = TName { name = "Fact"; _ }; _ } -> true
      | TApp { head = TName { name = "Maybe"; _ };
               arg = TApp { head = TName { name = "Fact"; _ }; _ }; _ } -> true
      | _ -> false
    in
    let fact_param_map (params : binding list) : (string * string) list =
      List.filter_map (fun (b : binding) ->
        if not (is_fact_typed b.type_expr) then None
        else match pred_of_fact_type b.type_expr with
        | Some pred -> Some (b.name, pred)
        | None -> None
      ) params
    in
    (* Build a map from function names (establish/check) to their Fact return predicate.
       Used to resolve `let pf = establish_fn args` → `pf` carries predicate `P`. *)
    let establish_pred_map : (string * string) list =
      List.filter_map (function
        | DFunc fd when fd.kind = EstablishKind || fd.kind = CheckKind ->
          let pred_opt = match fd.return_spec with
            | RetPlain { ty; _ } -> (match proof_of_fact_type ty with
                | Some (PredApp { pred; _ }) -> Some pred
                | Some (PredAnd _) -> None
                | None -> None)
            | RetAttached { binding = b; _ } ->
              (match b.proof_ann with
               | Some (PredApp { pred; _ }) -> Some pred
               | _ -> None)
            | _ -> None
          in
          (match pred_opt with Some p -> Some (fd.name, p) | None -> None)
        | _ -> None
      ) decls
    in
    let check_ghost_in_func (params : binding list) (body : expr) =
      (* Map from variable name → proof predicate name.
         Starts with fact-typed parameters, then augmented with local let bindings
         that call establish/check functions. Used to resolve detachFact(pf) proof. *)
      let local_fact_map = ref (fact_param_map params) in
      let track_let_binding name value =
        (* If value is a call to a known establish/check function, record the predicate *)
        let (head, _) = collect_call_head_and_args [] value in
        (match function_name_of_expr head with
         | Some fn_name ->
           (match List.assoc_opt fn_name establish_pred_map with
            | Some pred -> local_fact_map := (name, pred) :: !local_fact_map
            | None -> ())
         | None -> ())
      in
      let rec walk_body = function
        | EOk { value; proof; loc } ->
          (match value with
           | EApp { fn = EConstructor { name = rname; args = []; _ }; arg = ERecord _; _ }
             when List.mem_assoc rname record_invariants ->
             let expected_pred = List.assoc rname record_invariants in
             (* Resolve the proof predicate from the ghost witness expression.
                Handles: direct PredApp, detachFact(pf) where pf is in local_fact_map *)
             (* Determine the predicate name the ghost witness proof carries.
                - Uppercase PredApp: it IS a predicate constructor (`IsValidRange`)
                - Lowercase PredApp with no args: a PROOF VARIABLE (`proodd`) —
                  check local_fact_map; if not found, we can't determine predicate
                  so return None (don't flag — be conservative)
                - detachFact(pf_name): look up pf_name in local_fact_map *)
             let is_pred_name s =
               String.length s > 0 && s.[0] >= 'A' && s.[0] <= 'Z'
             in
             let proof_pred = match proof with
               | PredApp { pred; args = []; _ } when is_pred_name pred ->
                 (* Uppercase zero-arg proof variable (shouldn't normally appear) *)
                 (match List.assoc_opt pred !local_fact_map with
                  | Some p -> Some p
                  | None -> Some pred)
               | PredApp { pred; args = []; _ } ->
                 (* Lowercase proof variable: look up in local_fact_map *)
                 (match List.assoc_opt pred !local_fact_map with
                  | Some p -> Some p
                  | None -> None)   (* Unknown proof var — skip the check *)
               | PredApp { pred = "detachFact"; args = [pf_name]; _ } ->
                 (match List.assoc_opt pf_name !local_fact_map with
                  | Some p -> Some p
                  | None -> None)
               | PredApp { pred = "detachFact"; _ } ->
                 None  (* multi-arg or no-arg detachFact — can't determine predicate *)
               | PredApp { pred; _ } when pred <> "detachFact" && is_pred_name pred ->
                 Some pred
               | _ -> None
             in
             (match proof_pred with
              | Some actual_pred when actual_pred <> expected_pred ->
                errors := make_error loc
                  ~hint:(Printf.sprintf
                    "the ghost witness must establish `%s` (the declared invariant of `%s`), \
                     but carries `%s`; use a function that returns `Fact (%s ...)` instead"
                    expected_pred rname actual_pred expected_pred)
                  (Printf.sprintf
                    "ghost witness predicate mismatch on `%s` construction: \
                     invariant requires `%s` but witness carries `%s`"
                    rname expected_pred actual_pred)
                :: !errors
              | _ -> ());
             walk_body value
           | _ -> walk_body value);
        | EApp { fn; arg; _ } -> walk_body fn; walk_body arg
        | ELet { name; value; body; _ } ->
          track_let_binding name value;
          walk_body value; walk_body body
        | ELetProof { value; body; _ } -> walk_body value; walk_body body
        | EIf { cond; then_; else_; _ } ->
          walk_body cond; walk_body then_; walk_body else_
        | ECase { scrut; arms; _ } ->
          walk_body scrut;
          List.iter (fun (arm : case_arm) -> walk_body arm.body) arms
        | ELambda { body = b; _ } -> walk_body b
        | EList { elems; _ } -> List.iter walk_body elems
        | ERecord { fields; _ } -> List.iter (fun (_, v) -> walk_body v) fields
        | EBinop { left; right; _ } -> walk_body left; walk_body right
        | EUnop { arg; _ } -> walk_body arg
        | EWithDatabase { body = b; _ } | EWithCapabilities { body = b; _ }
        | EWithTransaction { body = b; _ } -> walk_body b
        | ETelemetry { fields; _ } -> List.iter (fun (_, v) -> walk_body v) fields
        | EEnqueue { payload; _ } -> walk_body payload
        | EPublish { key; payload; _ } ->
          (match key with Some e -> walk_body e | None -> ());
          (match payload with Some e -> walk_body e | None -> ())
        | EServe { port; _ } -> walk_body port
        | EConstructor { args; _ } -> List.iter walk_body args
        | EStartWorkers _ | ELit _ | EVar _ | EField _ | EFail _ -> ()
      in
      walk_body body
    in
    List.iter (function
      | DFunc fd -> check_ghost_in_func fd.params fd.body
      | _ -> ()
    ) decls;
    List.rev !errors

(** Check that handler functions are never called directly from code.
    Handlers are HTTP entry points and must only be referenced in server
    bindings (DServer.bindings), not called as regular functions.
    This prevents handler-to-handler calls and fn-to-handler calls. *)
(** Validate that auth functions are only called (via the `check` keyword) from
    handler bodies or from other auth function bodies.  Calling an auth function
    from a plain `fn`, `check`, `establish`, `worker`, or `deadWorker` body is
    rejected because auth functions are HTTP-level identity gates — their `fail 401`
    is meaningful only inside the request/response cycle of a handler. *)
let check_auth_call_restriction (decls : top_decl list) : validation_error list =
  let auth_names =
    List.filter_map (function
      | DFunc fd when fd.kind = AuthKind -> Some fd.name
      | _ -> None
    ) decls
  in
  if auth_names = [] then []
  else begin
    let errors = ref [] in
    (* Walk body looking for `check authFn …` or `(authFn && …)` call patterns.
       `check f x` is parsed as EApp(EApp(EVar "check", EVar f), EVar x). *)
    let rec collect_check_callee e acc =
      (* Collect every function name directly called via `check` in this expression.
         Also recurse into &&-combinator chains so `check (authFn && checkX) v`
         is handled correctly. *)
      match e with
      | EVar { name; _ } -> name :: acc
      | EBinop { op = BAnd; left; right; _ } ->
        collect_check_callee left (collect_check_callee right acc)
      | _ -> acc
    in
    let rec walk_body (caller_name : string) (caller_kind : func_kind) (e : expr) =
      match e with
      | EApp { fn = EApp { fn = EVar { name = "check"; _ }; arg = callee_expr; _ }; _ } ->
        (* Detect `check f x` — check whether the callee is an auth function. *)
        let callees = collect_check_callee callee_expr [] in
        let call_loc = match e with EApp { loc; _ } -> loc | _ -> gen_loc in
        List.iter (fun callee ->
          if List.mem callee auth_names && caller_kind <> HandlerKind && caller_kind <> AuthKind then
            errors := make_error call_loc
              ~hint:(Printf.sprintf
                "auth functions are HTTP-level identity gates; call `%s` from a handler body, \
or declare it as `auth user via %s` in an API endpoint" callee callee)
              (Printf.sprintf
                "`%s` calls auth function `%s` from a `%s`; auth functions may only be \
called from handler bodies or other auth functions"
                caller_name callee
                (match caller_kind with
                 | FnKind -> "fn" | CheckKind -> "check" | EstablishKind -> "establish"
                 | WorkerKind -> "worker" | DeadWorkerKind -> "deadWorker"
                 | AuthKind -> "auth" | HandlerKind -> "handler" | MainKind -> "main"))
            :: !errors
        ) callees;
        (* Still recurse into sub-expressions *)
        walk_body caller_name caller_kind (match e with EApp { fn; _ } -> fn | _ -> e);
        (match e with EApp { arg; _ } -> walk_body caller_name caller_kind arg | _ -> ())
      | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ | EField _ -> ()
      | EApp { fn; arg; _ } ->
        walk_body caller_name caller_kind fn;
        walk_body caller_name caller_kind arg
      | EBinop { left; right; _ } ->
        walk_body caller_name caller_kind left;
        walk_body caller_name caller_kind right
      | EUnop { arg; _ } -> walk_body caller_name caller_kind arg
      | EIf { cond; then_; else_; _ } ->
        walk_body caller_name caller_kind cond;
        walk_body caller_name caller_kind then_;
        walk_body caller_name caller_kind else_
      | ECase { scrut; arms; _ } ->
        walk_body caller_name caller_kind scrut;
        List.iter (fun (arm : case_arm) -> walk_body caller_name caller_kind arm.body) arms
      | ELet { value; body; _ } | ELetProof { value; body; _ } ->
        walk_body caller_name caller_kind value;
        walk_body caller_name caller_kind body
      | ERecord { fields; _ } ->
        List.iter (fun (_, v) -> walk_body caller_name caller_kind v) fields
      | EList { elems; _ } ->
        List.iter (walk_body caller_name caller_kind) elems
      | EOk { value; _ } -> walk_body caller_name caller_kind value
      | ETelemetry { fields; _ } ->
        List.iter (fun (_, v) -> walk_body caller_name caller_kind v) fields
      | EEnqueue { payload; _ } -> walk_body caller_name caller_kind payload
      | EPublish { key; payload; _ } ->
        Option.iter (walk_body caller_name caller_kind) key;
        Option.iter (walk_body caller_name caller_kind) payload
      | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
      | EWithTransaction { body; _ } -> walk_body caller_name caller_kind body
      | ELambda { body; _ } -> walk_body caller_name caller_kind body
    in
    List.iter (function
      | DFunc fd -> walk_body fd.name fd.kind fd.body
      | _ -> ()
    ) decls;
    List.rev !errors
  end

let check_handler_isolation (decls : top_decl list) : validation_error list =
  let handler_names =
    List.filter_map (function
      | DFunc fd when fd.kind = HandlerKind -> Some fd.name
      | _ -> None
    ) decls
  in
  if handler_names = [] then []
  else begin
    let errors = ref [] in
    let rec walk_body (caller_name : string) (e : expr) =
      match e with
      | EVar { name; loc } when List.mem name handler_names ->
        errors := make_error loc
          ~hint:"handlers are HTTP entry points that can only be wired via server declarations; \
extract shared logic into a helper `fn` function instead"
          (Printf.sprintf
            "`%s` calls handler `%s` directly; handlers cannot be called from code \
— only the server router may reference handlers"
            caller_name name)
        :: !errors
      | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ | EField _ -> ()
      | EApp { fn; arg; _ } -> walk_body caller_name fn; walk_body caller_name arg
      | EBinop { left; right; _ } -> walk_body caller_name left; walk_body caller_name right
      | EUnop { arg; _ } -> walk_body caller_name arg
      | EIf { cond; then_; else_; _ } ->
        walk_body caller_name cond; walk_body caller_name then_; walk_body caller_name else_
      | ECase { scrut; arms; _ } ->
        walk_body caller_name scrut;
        List.iter (fun (arm : case_arm) -> walk_body caller_name arm.body) arms
      | ELet { value; body; _ } | ELetProof { value; body; _ } ->
        walk_body caller_name value; walk_body caller_name body
      | ERecord { fields; _ } -> List.iter (fun (_, v) -> walk_body caller_name v) fields
      | EList { elems; _ } -> List.iter (walk_body caller_name) elems
      | EOk { value; _ } -> walk_body caller_name value
      | ETelemetry { fields; _ } -> List.iter (fun (_, v) -> walk_body caller_name v) fields
      | EEnqueue { payload; _ } -> walk_body caller_name payload
      | EPublish { key; payload; _ } ->
        Option.iter (walk_body caller_name) key; Option.iter (walk_body caller_name) payload
      | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
      | EWithTransaction { body; _ } -> walk_body caller_name body
      | ELambda { body; _ } -> walk_body caller_name body
    in
    List.iter (function
      | DFunc fd -> walk_body fd.name fd.body
      | _ -> ()
    ) decls;
    List.rev !errors
  end

(** Check that the file name on disk matches the declared module header.
    Rejects a file like `foo.tesl` that declares `module Bar exposing []` —
    no one else can import `Bar` because the loader resolves by file name.
    The accepted file names are the kebab-cased form (e.g. `my-module.tesl`
    for `MyModule`) OR the exact PascalCase form (e.g. `MyModule.tesl`), to
    match the import resolver's two-path fallback in `resolve_local_import_path`.
    Stdin (no source file), non-file synthetic paths like `<test>`, dotted
    stdlib module names, and standalone fixture/example files are not checked:
    those inputs are not resolved through the local import loader, so this rule
    would only create test noise without preventing a real import failure. *)
let check_file_module_name_match (m : module_form) : validation_error list =
  let src = m.source_file in
  let mname = m.module_name in
  let contains_substring needle haystack =
    let n = String.length needle in
    let h = String.length haystack in
    let rec loop i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else loop (i + 1)
    in
    n = 0 || loop 0
  in
  (* Skip: no source, stdin, synthetic/non-file input, dotted-name stdlib module,
     fixture/example files, or empty name. *)
  if src = "" || src = "-" || mname = "" then []
  else if String.contains mname '.' then []
  else
    let basename = Filename.basename src in
    if not (Filename.check_suffix basename ".tesl") then []
    else if contains_substring "/example/" src || contains_substring "/tests/" src
         (* Also match relative paths that don't start with a slash *)
         || (let starts = String.length src >= 8 && String.sub src 0 8 = "example/" in starts)
         || (let starts = String.length src >= 6 && String.sub src 0 6 = "tests/" in starts)
         then []
    else
      let stem = Filename.chop_suffix basename ".tesl" in
      let kebab = module_name_to_kebab mname in
      (* Accept exact kebab match or exact PascalCase match. Also accept any
         file whose stem starts with the prefix "tesl-" — this is the stable
         prefix used by `Filename.temp_file` in the test suite, which creates
         names like `tesl-r50abc123.tesl` that cannot realistically collide
         with a user-authored file. *)
      let starts_with_prefix prefix s =
        String.length s >= String.length prefix
        && String.sub s 0 (String.length prefix) = prefix
      in
      if stem = kebab
         || stem = mname
         || starts_with_prefix "tesl-" stem
         || starts_with_prefix ("temp-" ^ kebab) stem then []
      else
        let loc = m.decls
          |> List.filter_map (function DFunc fd -> Some fd.loc | _ -> None)
          |> (function [] -> Location.dummy_loc src
                    | hd :: _ -> hd)
        in
        [ make_error loc
            ~hint:(Printf.sprintf
              "rename the file to `%s.tesl` (kebab-case) or `%s.tesl` (PascalCase), or change the module header to `module %s exposing [...]`"
              kebab mname
              (match String.length stem with
               | 0 -> mname
               | _ ->
                 let buf = Buffer.create (String.length stem) in
                 let cap = ref true in
                 String.iter (fun c ->
                   if c = '-' || c = '_' then cap := true
                   else if !cap then begin
                     Buffer.add_char buf (Char.uppercase_ascii c);
                     cap := false
                   end else
                     Buffer.add_char buf c
                 ) stem;
                 Buffer.contents buf))
            (Printf.sprintf
              "module header `module %s` does not match file name `%s`; the compiler resolves imports by file name, so no other file can `import %s`"
              mname basename mname)
        ]

