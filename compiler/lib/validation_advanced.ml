open Ast
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
      (* 2026-07-03 hole #4: a field's proof obligation may be written either as
         `field: T ::: P field` (proof_ann) OR as `field: Fact (P)` (the proof in
         the TYPE).  Collecting only proof_ann let a `Fact (B)`-typed field accept
         a value carrying a DIFFERENT fact (or none) at construction — punning any
         fact into any predicate, even predicates with no producing check/auth/
         establish anywhere.  Derive the obligation from BOTH forms. *)
      let eff_proof = match f.proof_ann with
        | Some proof -> Some proof
        | None -> proof_of_fact_type f.type_expr
      in
      match eff_proof with
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
  (* 2026-07-03 hole #4: also treat `field: Fact (P)` (proof in the TYPE) as an
     obligation, not just `field ::: P field` (proof_ann) — mirror of the record
     path above. *)
  let eff_proof (f : field_def) =
    match f.proof_ann with Some p -> Some p | None -> proof_of_fact_type f.type_expr in
  List.concat_map (function
    | DType (TypeAdt { variants; _ }) ->
      List.filter_map (fun (v : adt_variant) ->
        if not (List.exists (fun (f : field_def) -> eff_proof f <> None) v.fields)
        then None
        else Some (v.ctor,
          List.map (fun (f : field_def) ->
            { name = f.name; type_expr = f.type_expr; proof_ann = eff_proof f; loc = f.loc })
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
    | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe) as op; left; right; loc; _ } ->
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
    | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe) as op; left; right; loc; op_loc } ->
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
            let fake_pred = EBinop { op; left = last_atom; right; loc; op_loc } in
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
(* ── groupBy rules (GitHub #29, fail-closed sweep) ───────────────────────────
   Before #29, `groupBy` was accepted on every select form and then either
   silently DROPPED by the aggregate runtimes (one whole-set scalar came back)
   or, for a non-field key expression, emitted a module that failed to LOAD
   (`groupBy: unbound identifier`) — checker-accepts-what-codegen-cannot-lower.
   Now:
     - `groupBy` is ONLY legal on the grouped forms selectCountBy/selectSumBy,
       which require EXACTLY ONE groupBy clause;
     - the key must be `binder.field` (a declared column) or
       `Time.truncHour/Day/Week/Month/Year offsetExpr binder.field` on a
       declared PosixMillis column;
     - order/limit/offset/innerJoin are rejected on the grouped forms (the
       result is ordered by key ascending by definition).
   Decide-by-resolution: a user-declared fn with a select-form name stands the
   whole rule down for that head. *)
let check_group_by_rules (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  let emit err = errors := err :: !errors in
  let user_fn_names =
    List.filter_map (function DFunc (fd : func_decl) -> Some fd.name | _ -> None) decls in
  let entity_fields name =
    List.find_map (function
      | DEntity (e : entity_form) when e.name = name -> Some e.fields
      | _ -> None) decls
  in
  (* the query spine: select head + keyword/field atoms, including modifier
     atoms the parser merged onto an outer where-EBinop *)
  let rec spine_atoms e =
    match e with
    | EBinop { op = (BEq | BNeq | BLt | BLe | BGt | BGe | BAnd | BOr | BAdd); left; _ } ->
      spine_atoms left
    | EApp _ ->
      let rec go acc = function
        | EApp { fn; arg; _ } -> go (arg :: acc) fn
        | hd -> (hd, acc)
      in
      let (base, args) = go [] e in
      (match base with
       | EBinop _ -> spine_atoms base @ args
       | _ -> base :: args)
    | other -> [other]
  in
  let seen_heads : (Location.loc, unit) Hashtbl.t = Hashtbl.create 16 in
  let field_decl entity_opt field =
    match entity_opt with
    | Some en ->
      (match entity_fields en with
       | Some fs -> List.find_opt (fun (f : field_def) -> f.name = field) fs
       | None -> None)
    | None -> None
  in
  let validate_root head_name head_loc atoms =
    let entity_opt =
      let rec find_entity = function
        | EVar { name = "from"; _ } :: EConstructor { name; _ } :: _ -> Some name
        | EVar { name = "from"; _ } :: EVar { name; _ } :: _ -> Some name
        | _ :: rest -> find_entity rest
        | [] -> None
      in find_entity atoms
    in
    let group_keys =
      let rec collect acc = function
        | EVar { name = "groupBy"; _ } :: key :: rest -> collect (key :: acc) rest
        | _ :: rest -> collect acc rest
        | [] -> List.rev acc
      in collect [] atoms
    in
    let is_grouped = head_name = "selectCountBy" || head_name = "selectSumBy" in
    if not is_grouped then begin
      match group_keys with
      | [] -> ()
      | _ ->
        emit (make_error head_loc
          ~hint:(if head_name = "select" || head_name = "selectOne" then
                   "grouping only makes sense with an aggregate; use \
                    selectCountBy/selectSumBy for per-group rows, or drop the \
                    groupBy"
                 else
                   Printf.sprintf
                     "use `%sBy ... groupBy <key>` to get one (key, aggregate) \
                      row per group as a List (Tuple2 key value)"
                     head_name)
          (Printf.sprintf
             "`groupBy` is not supported on `%s` — the per-group breakdown \
              would be lost (the scalar form aggregates the whole matching set)"
             head_name))
    end else begin
      (match group_keys with
       | [key] ->
         let check_field_key ~want_posix field floc =
           match field_decl entity_opt field with
           | None ->
             emit (make_error floc
               ~hint:"the groupBy key must be a declared column of the queried entity"
               (Printf.sprintf
                  "`groupBy`: field `%s` does not exist on entity `%s`"
                  field (Option.value entity_opt ~default:"?")))
           | Some f ->
             if want_posix then
               (match f.type_expr with
                | TName { name = "PosixMillis"; _ } -> ()
                | _ ->
                  emit (make_error floc
                    ~hint:"Time.trunc* buckets a PosixMillis column; use the bare \
                           field as the key for other column types"
                    (Printf.sprintf
                       "`groupBy`: Time.trunc* requires a PosixMillis column, but \
                        `%s` is declared as a different type" field)))
         in
         (match key with
          | EField { obj = EVar _; field; loc = floc } ->
            check_field_key ~want_posix:false field floc
          | _ ->
            let rec flat acc = function
              | EApp { fn; arg; _ } -> flat (arg :: acc) fn
              | hd -> (hd, acc)
            in
            (match flat [] key with
             | EField { obj = (EConstructor { name = "Time"; args = []; _ }
                              | EVar { name = "Time"; _ });
                        field = ("truncHour" | "truncDay" | "truncWeek"
                                | "truncMonth" | "truncYear"); _ },
               [_off; EField { obj = EVar _; field; loc = floc }] ->
               check_field_key ~want_posix:true field floc
             | _ ->
               emit (make_error head_loc
                 ~hint:"supported keys: `e.field`, or \
                        `Time.truncHour/Day/Week/Month/Year offsetMinutes e.field` \
                        on a PosixMillis column"
                 (Printf.sprintf
                    "`%s`: unsupported `groupBy` key expression" head_name))))
       | [] ->
         emit (make_error head_loc
           ~hint:"add `groupBy e.field` or `groupBy (Time.truncDay offsetMinutes e.field)`"
           (Printf.sprintf
              "`%s` requires exactly one `groupBy` clause (it returns one row \
               per group)" head_name))
       | _ ->
         emit (make_error head_loc
           ~hint:"combine into a single key, or aggregate twice"
           (Printf.sprintf
              "`%s` supports exactly ONE `groupBy` clause" head_name)));
      let rec reject_modifiers = function
        | EVar { name = ("order" | "limit" | "offset" | "innerJoin") as m; loc = mloc } :: _ ->
          emit (make_error mloc
            ~hint:"grouped results are ordered by key ascending by definition"
            (Printf.sprintf
               "`%s` is not supported on `%s`" m head_name))
        | _ :: rest -> reject_modifiers rest
        | [] -> ()
      in
      reject_modifiers atoms
    end
  in
  let rec walk e =
    (match spine_atoms e with
     | EVar { name = ("select" | "selectOne" | "selectCount" | "selectSum"
                     | "selectMax" | "selectMin" | "selectCountBy"
                     | "selectSumBy" as head_name); loc = head_loc } :: atoms
       when not (List.mem head_name user_fn_names)
         && not (Hashtbl.mem seen_heads head_loc) ->
       Hashtbl.replace seen_heads head_loc ();
       validate_root head_name head_loc atoms
     | _ -> ());
    Ast_visitor.fold_children (fun () c -> walk c) () e
  in
  List.iter (function
    | DFunc (fd : func_decl) -> walk fd.body
    | DConst (c : const_form) -> walk c.value
    | DTest (tf : test_form) ->
      List.iter (fun st -> List.iter walk (test_stmt_exprs st)) tf.stmts
    | _ -> ()) decls;
  List.rev !errors

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
          | Some p -> (b.name, [Proof_kernel.assume_param p]) :: acc
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
      (* 2026-07 matrix (record ctor proof enforcement in TEST blocks): the
         construction-proof walk previously never entered test bodies, so a
         bare `Msg { title: "unvalidated" }` in a `test { … }` was silently
         accepted while the identical fn-body construction was rejected.  The
         statement block is lowered to one nested ELet/ELetProof expression
         (expr_of_test_stmts) so the SAME env-threading walk accepts witnessed
         constructions exactly as in fn bodies. *)
      | DTest tf ->
        (match expr_of_test_stmts tf.stmts with
         | Some e -> walk_expr [] [] [] e
         | None -> ())
      | DApiTest at ->
        List.iter (walk_expr [] [] []) at.seed_stmts;
        (match expr_of_test_stmts at.stmts with
         | Some e -> walk_expr [] [] [] e
         | None -> ())
      | DLoadTest lt ->
        List.iter (walk_expr [] [] []) lt.seed_stmts;
        (match expr_of_test_stmts lt.request_stmts with
         | Some e -> walk_expr [] [] [] e
         | None -> ())
      | _ -> ()
    ) decls;
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
          (* A Fact-typed param carries its proof in its TYPE; assume it like a
             `:::` param proof. *)
          | Some proof -> (b.name, [Proof_kernel.assume_param proof]) :: acc
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
      | Some proofs -> List.map Proof_kernel.fact_of proofs
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
          | Some (p :: _) -> (match proof_predicates (Proof_kernel.fact_of p) with pn :: _ -> Some pn | [] -> None)
          | _ ->
            let subj = match List.assoc_opt name subject_env with Some s -> s | None -> name in
            (match List.assoc_opt subj proof_env with
             | Some (p :: _) -> (match proof_predicates (Proof_kernel.fact_of p) with pn :: _ -> Some pn | [] -> None)
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
          | Some p -> (b.name, [Proof_kernel.assume_param p]) :: acc
          | None ->
            (match proof_of_fact_type b.type_expr with
             | Some p -> (b.name, [Proof_kernel.assume_param p]) :: acc
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
        (* #6 (2026-07-04): per-fn type context for the EField arm reached via
           walk_expr's carried_proofs_of_expr / proofs_of_expr calls. *)
        field_proof_type_ctx :=
          Some (fn_type_env funcs fields_by_type ctors fd, fields_by_type, ctors);
        walk_expr type_env subject_env proof_env fd.body
      (* 2026-07 matrix: ghost-witness enforcement in TEST blocks — same
         lowering as check_record_field_proof_construction's DTest arm (see
         expr_of_test_stmts), so a witnessless `OrderLine { … }` in a test is
         rejected exactly like in a fn body while `let (p ::: pw) = check …`
         chains still resolve the witness. *)
      | DTest tf ->
        field_proof_type_ctx := None;
        (match expr_of_test_stmts tf.stmts with
         | Some e -> walk_expr [] [] [] e
         | None -> ())
      | DApiTest at ->
        field_proof_type_ctx := None;
        List.iter (walk_expr [] [] []) at.seed_stmts;
        (match expr_of_test_stmts at.stmts with
         | Some e -> walk_expr [] [] [] e
         | None -> ())
      | DLoadTest lt ->
        field_proof_type_ctx := None;
        List.iter (walk_expr [] [] []) lt.seed_stmts;
        (match expr_of_test_stmts lt.request_stmts with
         | Some e -> walk_expr [] [] [] e
         | None -> ())
      | _ -> ()
    ) decls;
    field_proof_registry := [];
    field_proof_type_ctx := None;
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

