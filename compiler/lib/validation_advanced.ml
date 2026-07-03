open Ast
open Location
open Validation_common
open Validation_structural
open Validation_proof
open Validation_names

(* [body_has_db_site] and [is_forgery_restricted_kind] are now the single shared
   definitions in {!Validation_common} (S4b: they were duplicated here and in
   checker.ml, with checker.ml's copy NOT shadow-aware).  They are in scope via
   `open Validation_common` above; see that module for the shadow-awareness /
   §7.12 rationale. *)

let build_record_field_bindings (decls : top_decl list)
    : (string * binding list) list =
  (* Records AND entities both construct via `Name { field: value, ... }` and both
     may carry field-level proof annotations, so construction from a RAW value must
     be rejected for either. *)
  let annotated_fields (name : string) (fields : field_def list) =
    let annotated = List.filter_map (fun (f : field_def) ->
      match f.proof_ann with
      | None -> None
      | Some proof ->
        Some { name = f.name; type_expr = f.type_expr;
               proof_ann = Some proof; loc = f.loc }
    ) fields in
    if annotated = [] then None else Some (name, annotated)
  in
  List.filter_map (function
    | DRecord r -> annotated_fields r.name r.fields
    | DEntity e -> annotated_fields e.name e.fields
    | _ -> None
  ) decls

(** ADT-constructor field bindings (review 2026-07 PFC-2b): a constructor whose
    field is declared `field: T ::: P field` must, at CONSTRUCTION, receive an
    argument that carries `P` — otherwise the field proof is decorative and a
    `Node Leaf (0 - 5) Leaf` fabricates a "PositiveTree" with a negative value.
    Unlike records (looked up by field name), constructor args are POSITIONAL, so
    we keep the FULL field list per constructor (proof-annotated or not) and align
    args positionally in [check_call_proofs] (which skips non-proof fields).  Only
    constructors with at least one proof-annotated field are included. *)
let build_adt_ctor_field_bindings (decls : top_decl list)
    : (string * binding list) list =
  List.concat_map (function
    | DType (TypeAdt { variants; _ }) ->
      List.filter_map (fun (v : adt_variant) ->
        if not (List.exists (fun (f : field_def) -> f.proof_ann <> None) v.fields)
        then None
        else Some (v.ctor,
          List.map (fun (f : field_def) ->
            { name = f.name; type_expr = f.type_expr; proof_ann = f.proof_ann; loc = f.loc })
            v.fields)
      ) variants
    | _ -> []
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
    ?facts
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let mf = facts_or_compute ?facts ~extra_funcs decls in
  let funcs = mf.mf_funcs in
  let fields_by_type = mf.mf_fields_map in
  let ctors = mf.mf_ctors in
  (* Newtypes are NOT coerced at SQL boundaries: a comparison or assignment
     against a newtype column must supply that exact newtype (construct it, e.g.
     `UserId x`), never the bare underlying primitive.  Coercion is not accepted
     by design — see spec §11.6.  Field/RHS types are therefore compared by their
     nominal head (`type_key`) with no base-type resolution. *)
  let errors = ref [] in
  let emit err = errors := err :: !errors in
  (* Flatten a query expression to its atoms, descending through a WHERE-merged
     EBinop (the query chain is on its left) as well as the EApp spine.  Mirrors
     the walk-time flattening used for the WHERE scan. *)
  let rec flatten_query_atoms e =
    match e with
    | EBinop { left; _ } -> flatten_query_atoms left
    | EApp _ ->
      let rec go acc = function
        | EApp { fn; arg; _ } -> go (arg :: acc) fn
        | hd -> hd :: acc
      in go [] e
    | other -> [other]
  in
  (* If [e] is an `update b in Entity …` / delete chain, return [binder_env]
     extended with (b → Entity) so the following `set`/`where` statements in the
     same sequence resolve the row binder.  Otherwise [binder_env] unchanged. *)
  let update_binder_of e binder_env =
    let atoms = flatten_query_atoms e in
    match atoms with
    | EVar { name = ("update" | "updateAndReturnOne"
                   | "delete" | "deleteAndReturnResult"); _ } :: _ ->
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
      (match binder_name, entity_name with
       | Some bn, Some en -> (bn, en) :: binder_env
       | _ -> binder_env)
    | _ -> binder_env
  in
  (* NT-07 width-match at the `update … set field = value` write site.  A `set`
     assigns [right_expr] into the column [binder.field]; the value's type must
     match the column's declared type (e.g. an `Int` into an `Int32` column, or a
     raw primitive into a distinct-primitive column, is a compile error rather
     than a silent narrowing caught only by Postgres).  Uses the same field/RHS
     comparison as the WHERE scan (strict nominal `type_key`, no newtype
     coercion — §11.6), so writes and queries agree; Int vs Integer share a
     `type_key` and are not a false positive. *)
  let check_set_field tenv binder_env bound_names binder field right_expr loc =
    match List.assoc_opt binder binder_env with
    | None -> ()
    | Some entity_name ->
      (match record_fields_of_type fields_by_type (mk_name_type entity_name) with
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
               ()  (* unbound identifier — reported by other passes; skip here *)
             | _ ->
               (match infer_expr_type tenv funcs fields_by_type ctors right_expr with
                | None -> ()
                | Some rhs_ty ->
                  let fk = type_key field_ty in
                  let rk = type_key rhs_ty in
                  if fk <> rk then
                    emit (make_error loc
                      ~hint:(Printf.sprintf
                        "field `%s` is declared as `%s` — the assigned value must have the same type; convert or construct it explicitly"
                        field (type_key field_ty))
                      (Printf.sprintf
                        "SQL SET clause: type mismatch for `%s.%s = <rhs>` — field type is `%s`, RHS is `%s`"
                        binder field (type_key field_ty) (type_key rhs_ty)))))))
  in
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
                    let fk = type_key field_ty in
                    let rk = type_key rhs_ty in
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
      (* NT-07: a standalone `set b.field = rhs` statement (from `update … set …`)
         flattens to head `set`, args [ b.field ; rhs ].  The row binder `b` is
         threaded in via the ELet arm below (the update scopes over its sets). *)
      (match head, args with
       | EVar { name = "set"; _ },
         EField { obj = EVar { name = b; _ }; field; loc = floc } :: rhs :: _ ->
         check_set_field tenv binder_env bound_names b field rhs floc
       | _ -> ());
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
      (* An `update b in Entity …` value scopes its row binder over the following
         `set`/`where` statements in this sequence (they parse as ELet body). *)
      let binder_env' = update_binder_of value binder_env in
      walk tenv' binder_env' (name :: bound_names) body
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
    (* S9: enumerate the remaining variants explicitly (no `_`) so a new Ast.expr
       variant becomes a COMPILE error rather than silently escaping this SQL
       where-clause scan.  These forms cannot host a select…where chain, so their
       behaviour is unchanged (no descent). *)
    | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EField _
    | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _
    | ESendEmail _ | EStartEmailWorker _ | ERuntimeCall _ -> ()
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
    ?facts
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let mf = facts_or_compute ?facts ~extra_funcs decls in
  let funcs = mf.mf_funcs in
  let rec_bindings = build_record_field_bindings decls in
  let adt_ctor_bindings = build_adt_ctor_field_bindings decls in
  let fields_by_type = mf.mf_fields_map in
  let ctors = mf.mf_ctors in
  if rec_bindings = [] && adt_ctor_bindings = [] then []
  else
    let errors = ref [] in
    (* Enforce ADT constructor field proofs at construction (PFC-2b).  Positional
       alignment of args to the variant's fields; [check_call_proofs] skips fields
       without a proof annotation. *)
    let check_ctor_field_proofs subject_env proof_env loc name args =
      match List.assoc_opt name adt_ctor_bindings with
      | Some field_bindings when List.length field_bindings = List.length args ->
        errors := check_call_proofs ~funcs loc name field_bindings args subject_env proof_env
                  @ !errors
      | _ -> ()
    in
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
        let (head, args) = collect_call_head_and_args [] e in
        (match head with
         | EConstructor { name; loc; _ } ->
           check_ctor_field_proofs subject_env proof_env loc name args
         | _ -> ());
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
      | EConstructor { name; args; loc } ->
        check_ctor_field_proofs subject_env proof_env loc name args;
        List.iter (walk_expr type_env subject_env proof_env) args
      | EStartWorkers _ | ELit _ | EVar _ | EField _ | EFail _ -> ()
      | ECacheGet { key; _ } -> walk_expr type_env subject_env proof_env key
      | ECacheSet { key; value; ttl; _ } ->
        walk_expr type_env subject_env proof_env key;
        walk_expr type_env subject_env proof_env value;
        Option.iter (walk_expr type_env subject_env proof_env) ttl
      | ECacheDelete { key; _ } -> walk_expr type_env subject_env proof_env key
      | ECacheInvalidate { prefix; _ } -> walk_expr type_env subject_env proof_env prefix
      | ESendEmail { to_; subject; body; _ } ->
        walk_expr type_env subject_env proof_env to_;
        walk_expr type_env subject_env proof_env subject;
        walk_expr type_env subject_env proof_env body
      | EStartEmailWorker _ -> ()
      | ERuntimeCall { segments; _ } ->
        List.iter (function RLit _ | RRawVar _ -> () | RArg e -> walk_expr type_env subject_env proof_env e) segments
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
  (* §7.12 forgery restriction applies to fn, handler, and worker: none of these
     can fabricate a proof their inputs do not carry. (check/auth/establish are the
     only kinds that may introduce a fresh proof at a boundary.) deadWorker is
     intentionally excluded — its job carries an infrastructure FromDeadQueue proof
     handled elsewhere.  [is_forgery_restricted_kind] is the shared definition in
     Validation_common (in scope via `open`). *)
  List.iter (function
    | DFunc fd when is_forgery_restricted_kind fd.kind ->
      (match fd.return_spec with
       | RetAttached { binding = b; loc = ret_loc }
         when is_forgery_restricted_kind fd.kind && b.proof_ann <> None ->
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
         let all_carried = List.concat_map snd proof_env @ field_carried in
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
            escapes the forgery rejection. *)
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
             let carried = proofs_of_expr result_subject funcs subject_env proof_env e in
             proof_matches required_here carried
         in
         if not is_stdlib_auto
            && not (proof_matches required_norm all_carried)
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
                           | Some pr, PVar var -> ((var, [subst_proof [(fname, var)] pr]) :: p, (var, var) :: s)
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
                     let carried = proofs_of_expr result_subject funcs subject_env proof_env payload in
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
       (* All remaining return specs carry no forgery obligation in THIS gate:
            - RetPlain: no proof.
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
        (* These were deliberately NON-descending in the original collector:
           a const-binding reference cannot live inside a `fail` message in a
           cycle-relevant way, and the others are genuine leaves. Keep them as
           explicit no-ops — `Ast_visitor.iter_children` would descend into the
           `fail` message expr, changing behaviour. *)
        | EVar _ | ELit _ | EFail _ | EStartWorkers _ -> ()
        (* Every remaining variant recurses into ALL its child exprs (the
           const-name set is constant — no per-arm threading), so the
           mechanical recursion is exactly {!Ast_visitor.iter_children}, which
           visits the same children in the same left-to-right order. *)
        | e -> Ast_visitor.iter_children walk e
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
let check_ghost_witness_predicates
    ?facts
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  (* Build map: record_name → (invariant predicate NAME, full invariant proof,
     field NAMES).  The predicate name is kept for the conservative name-only
     fallback; the FULL invariant proof + field names drive the new
     subject-aware comparison (the invariant's declared subjects are the record's
     own field names, e.g. `PriceExceedsQuantity price quantity`). *)
  let record_invariants : (string * (string * proof_expr * string list)) list =
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
           let field_names = List.map (fun (f : field_def) -> f.name) r.fields in
           if pred = "" then None
           else Some (r.name, (pred, inv.proof_text, field_names))
         | None -> None)
      | _ -> None
    ) decls
  in
  if record_invariants = [] then []
  else
    let mf = facts_or_compute ?facts ~extra_funcs decls in
    let funcs = mf.mf_funcs in
    let fields_by_type = mf.mf_fields_map in
    let ctors = mf.mf_ctors in
    field_proof_registry := mf.mf_field_proof_map;
    let errors = ref [] in
    (* Seed the initial proof_env for a function's params.  A Fact-typed param
       (`w: Fact (P a b)`) carries its proof in its TYPE (not a `:::` proof_ann),
       so [build_initial_proof_env] (which reads only proof_ann) misses it — we
       additionally seed such params from [proof_of_fact_type]. *)
    let initial_proof_env (params : binding list) : proof_env =
      let base = build_initial_proof_env params in
      List.fold_left (fun acc (b : binding) ->
        if List.mem_assoc b.name acc then acc
        else match proof_of_fact_type b.type_expr with
          | Some proof -> (b.name, [proof]) :: acc
          | None -> acc
      ) base params
    in
    (* Resolve the FULL carried proof (predicate name AND subjects) of a ghost
       witness proof-expression, threading it through [carried_proofs_of_expr] via
       an [EOk] wrapper whose value carries NO proofs of its own (an [EFail] node),
       so the returned proofs come solely from resolving the witness annotation.
       Returns [] when the witness cannot be resolved (unknown proof var, opaque
       source) — the caller then falls back to the name-only check. *)
    let resolve_witness_proofs subject_env proof_env (witness : proof_expr) loc
        : proof_expr list =
      let wrapper =
        EOk { value = EFail { status = 0; message = ELit { lit = LString ""; loc }; loc };
              proof = witness; loc }
      in
      match carried_proofs_of_expr ~funcs subject_env proof_env wrapper with
      | Some proofs -> proofs
      | None -> []
    in
    (* Report a subject/predicate mismatch at a witnessed construction site.
       [name_only] selects the legacy predicate-name-only message (used when the
       full witness proof could not be resolved) vs. the full subject-aware
       message (both sides fully resolved). *)
    let report_mismatch loc rname ~expected_pred ~actual_pred =
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
    in
    let report_subject_mismatch loc rname ~required ~carried =
      errors := make_error loc
        ~hint:(Printf.sprintf
          "the ghost witness for `%s` must be about the record's own field values; \
           supply a proof of `%s`"
          rname (pp_proof required))
        (Printf.sprintf
          "ghost witness for `%s` proves `%s` but the invariant requires `%s`"
          rname (pp_proof carried) (pp_proof required))
      :: !errors
    in
    (* The witnessed-construction check.  [subject_env]/[proof_env] carry the
       resolved subjects and proofs of in-scope bindings (params, lets, case
       binders); they let us resolve the witness's FULL proof and the field
       values' subjects. *)
    let check_witness subject_env proof_env loc rname witnessed_fields proof =
      let (expected_pred, inv_proof, field_names) = List.assoc rname record_invariants in
      (* required = invariant with each FIELD NAME substituted by the SUBJECT of
         that field's value expression in the record literal.  A field value with
         no stable subject is conservatively skipped (left unsubstituted). *)
      let field_subst =
        List.filter_map (fun (fname, fe) ->
          if not (List.mem fname field_names) then None
          else match subject_of_expr subject_env fe with
            | Some s -> Some (fname, s)
            | None -> None
        ) witnessed_fields
      in
      let required = subst_proof field_subst inv_proof in
      (* Resolve the witness's FULL carried proof (predicate + subjects). *)
      let carried = resolve_witness_proofs subject_env proof_env proof loc in
      (* SUBJECT-AWARE PATH: when BOTH the required proof and the witness's carried
         proof fully resolve, compare predicate name AND subject args.  This is
         purely ADDITIVE — it can only add rejections that the name-only path below
         would have accepted; whenever [proof_matches] holds we accept, and whenever
         either side fails to resolve we FALL BACK to the name-only check. *)
      if carried <> [] && proof_matches required carried then
        ()  (* full match — accept *)
      else if carried <> [] then begin
        (* Both sides resolved but do not match.  Distinguish a predicate mismatch
           (report with the legacy message + code) from a pure subject mismatch. *)
        let required_preds = List.sort_uniq compare (proof_predicates required) in
        let carried_preds =
          List.sort_uniq compare (List.concat_map proof_predicates carried) in
        if required_preds <> carried_preds then
          (* Predicate name differs — legacy-style message. *)
          let actual_pred = match carried_preds with p :: _ -> p | [] -> "?" in
          report_mismatch loc rname ~expected_pred ~actual_pred
        else
          (* Same predicate(s), wrong subjects — the newly-closed GAP 1. *)
          let carried_proof = match combine_proof_list loc carried with
            | Some p -> p | None -> (match carried with p :: _ -> p | [] -> required) in
          report_subject_mismatch loc rname ~required ~carried:carried_proof
      end
      else
        (* FALLBACK: witness could not be fully resolved.  Keep the conservative
           predicate-name-only check (unchanged behaviour): flag only a definite
           name mismatch resolvable from the proof-env / detachFact chain. *)
        let is_pred_name s =
          String.length s > 0 && s.[0] >= 'A' && s.[0] <= 'Z'
        in
        let pred_of_proof_var name =
          (* Resolve a proof variable to its predicate name via proof_env. *)
          match List.assoc_opt name proof_env with
          | Some (p :: _) -> (match proof_predicates p with pn :: _ -> Some pn | [] -> None)
          | _ ->
            let subj = match List.assoc_opt name subject_env with Some s -> s | None -> name in
            (match List.assoc_opt subj proof_env with
             | Some (p :: _) -> (match proof_predicates p with pn :: _ -> Some pn | [] -> None)
             | _ -> None)
        in
        let proof_pred = match proof with
          | PredApp { pred; args = []; _ } when is_pred_name pred ->
            (match pred_of_proof_var pred with Some p -> Some p | None -> Some pred)
          | PredApp { pred; args = []; _ } -> pred_of_proof_var pred
          | PredApp { pred = "detachFact"; args = [pf_name]; _ } -> pred_of_proof_var pf_name
          | PredApp { pred = "detachFact"; _ } -> None
          | PredApp { pred; _ } when pred <> "detachFact" && is_pred_name pred -> Some pred
          | _ -> None
        in
        (match proof_pred with
         | Some actual_pred when actual_pred <> expected_pred ->
           report_mismatch loc rname ~expected_pred ~actual_pred
         | _ -> ())
    in
    (* Walk the body threading type_env/subject_env/proof_env so that the witness's
       carried proof and the field values' subjects can be resolved through the
       shared proof engine.  This mirrors [check_record_field_proof_construction]'s
       env-threading walk. *)
    let rec walk_expr (type_env : type_env) (subject_env : subject_env)
        (proof_env : proof_env) (e : expr) =
      match e with
      | EOk { value; proof; loc } ->
        (match value with
         | EApp { fn = EConstructor { name = rname; args = []; _ };
                  arg = ERecord { fields = witnessed_fields; _ }; _ }
           when List.mem_assoc rname record_invariants ->
           check_witness subject_env proof_env loc rname witnessed_fields proof;
           (* Recurse into the record's field expressions ONLY (not the whole
              construction node), so the bare-construction arm does NOT re-flag
              this witnessed site. *)
           List.iter (fun (_, fe) -> walk_expr type_env subject_env proof_env fe)
             witnessed_fields
         | _ -> walk_expr type_env subject_env proof_env value)
      | ELet { name; value; body; _ } ->
        walk_expr type_env subject_env proof_env value;
        let subject_env' = match subject_of_expr subject_env value with
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
          | None -> subject_env
        in
        let detached_proofs =
          match carried_proofs_of_expr ~funcs subject_env proof_env value with
          | Some (_ :: _ as proofs) -> proofs
          | _ -> proofs_of_expr value_name funcs subject_env' proof_env value
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
        (* Propagate case-arm binder proofs: `case scrut of Something p -> body`
           binds `p` to the proofs extracted from the scrut's Maybe (Fact P)
           shape, so a witness `::: p` in the arm body resolves correctly. *)
        let scrut_proofs = proofs_of_expr "_" funcs subject_env proof_env scrut in
        List.iter (fun (arm : case_arm) ->
          let proof_env', subject_env' = match arm.pattern with
            | PVar x when x <> "_" ->
              let pe = if scrut_proofs <> [] then (x, scrut_proofs) :: proof_env else proof_env in
              let se = match subject_of_expr subject_env scrut with
                | Some s when s <> x -> (x, s) :: subject_env | _ -> subject_env in
              (pe, se)
            | PCon { fields = [(_, PVar x)]; _ } ->
              let pe = if scrut_proofs <> [] then (x, scrut_proofs) :: proof_env else proof_env in
              let se = match subject_of_expr subject_env scrut with
                | Some s when s <> x -> (x, s) :: subject_env | _ -> subject_env in
              (pe, se)
            | _ -> (proof_env, subject_env)
          in
          walk_expr type_env subject_env' proof_env' arm.body
        ) arms
      | ELambda { params; body; _ } ->
        let type_env' = List.fold_left (fun acc (b : binding) ->
          (b.name, b.type_expr) :: acc) type_env params in
        let subject_env' = List.fold_left (fun acc (b : binding) ->
          (b.name, b.name) :: acc) subject_env params in
        let proof_env' = List.fold_left (fun acc (b : binding) ->
          match b.proof_ann with
          | Some p -> (b.name, [p]) :: acc
          | None ->
            (match proof_of_fact_type b.type_expr with
             | Some p -> (b.name, [p]) :: acc
             | None -> acc)) proof_env params in
        walk_expr type_env' subject_env' proof_env' body
      | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
      | EWithTransaction { body; _ } -> walk_expr type_env subject_env proof_env body
      (* Leaf / non-descending nodes: no witnessed construction can hide here. *)
      | EStartWorkers _ | ELit _ | EVar _ | EField _ | EFail _
      | EStartEmailWorker _ -> ()
      (* GDP-RECORD-WITNESS (2026-07 review §3.2): a record type that declares a
         cross-field invariant must be constructed WITH a ghost witness.  A BARE
         construction reaches HERE as a plain `EApp { EConstructor R; ERecord }`
         (not inside an EOk) and carries no witness — reject it. *)
      | EApp { fn = EConstructor { name = rname; args = []; _ };
               arg = ERecord { fields = bare_fields; _ }; loc; _ }
        when List.mem_assoc rname record_invariants ->
        let (inv, _, _) = List.assoc rname record_invariants in
        errors := make_error loc
          ~hint:(Printf.sprintf
            "supply the cross-field proof as a ghost witness at the construction site: \
             `%s { ... } ::: <proofVar>`, where `<proofVar>` carries `%s`" rname inv)
          (Printf.sprintf
            "constructing `%s` requires a ghost witness for its cross-field invariant `%s`; \
             a `%s { ... }` literal must be written `%s { ... } ::: <proofVar>`"
            rname inv rname rname)
        :: !errors;
        List.iter (fun (_, fe) -> walk_expr type_env subject_env proof_env fe) bare_fields
      (* Every remaining variant recurses into all child exprs with the shared
         {!Ast_visitor.iter_children} traversal (same children, same order),
         re-using the CURRENT envs — none of these nodes bind new subjects/proofs
         relevant to a witness. *)
      | e -> Ast_visitor.iter_children (walk_expr type_env subject_env proof_env) e
    in
    List.iter (function
      | DFunc fd ->
        let type_env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
        let subject_env = build_initial_subject_env fd.params in
        let proof_env = initial_proof_env fd.params in
        walk_expr type_env subject_env proof_env fd.body
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
        (* Still recurse into sub-expressions — identical to the children of an
           EApp, in fn-then-arg order. *)
        walk_body caller_name caller_kind (match e with EApp { fn; _ } -> fn | _ -> e);
        (match e with EApp { arg; _ } -> walk_body caller_name caller_kind arg | _ -> ())
      (* The original walk treated these as NON-descending no-ops; an auth call
         travels through `check` (handled above) or operator chains, never via
         a constructor's args, a `serve` port, a field object, or a `fail`
         message in a way this rule observes. `Ast_visitor.iter_children` would
         descend into those, so keep the explicit no-ops to preserve behaviour. *)
      | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ | EField _
      | EStartEmailWorker _ -> ()
      (* Every remaining variant (including the non-`check` EApp form) recurses
         into all child exprs with the same constant caller name/kind — exactly
         {!Ast_visitor.iter_children}, same children, same left-to-right order. *)
      | e -> Ast_visitor.iter_children (walk_body caller_name caller_kind) e
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
      (* The original walk treated these as NON-descending no-ops: a direct
         handler reference is an `EVar` (handled above), and a handler name can
         only appear in call position, never inside a constructor's args, a
         `serve` port, a field projection's object, or a `fail` message in a
         way this rule cares about. `Ast_visitor.iter_children` WOULD descend
         into EConstructor.args / EServe.port / EField.obj / EFail.message, so
         keep them explicit no-ops to preserve behaviour exactly. *)
      | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ | EField _
      | EStartEmailWorker _ -> ()
      (* Every remaining variant recurses into all child exprs with the same
         constant `caller_name`, i.e. the shared {!Ast_visitor.iter_children}
         traversal, same children, same left-to-right order. *)
      | e -> Ast_visitor.iter_children (walk_body caller_name) e
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

