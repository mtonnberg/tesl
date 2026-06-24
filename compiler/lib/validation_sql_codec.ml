open Ast
open Location
open Validation_common

let is_allowed_special_field = function
  | "value" | "cookies" | "headers" | "body" | "path" | "method_" | "status" -> true
  | _ -> false

let rec validate_field_accesses
    (env : type_env)
    (funcs : (string * func_info) list)
    (fields_by_type : field_map)
    (ctors : ctor_info)
    (e : expr)
    : validation_error list =
  match e with
  | EField { obj; field; loc } ->
    let inner = validate_field_accesses env funcs fields_by_type ctors obj in
    (match infer_expr_type env funcs fields_by_type ctors obj with
     | Some obj_ty ->
       (match record_fields_of_type fields_by_type obj_ty with
        | Some fields when not (List.exists (fun (f : field_def) -> f.name = field) fields)
                           && not (is_allowed_special_field field) ->
          make_error loc
            ~hint:(Printf.sprintf "valid fields: %s" (String.concat ", " (List.map (fun (f : field_def) -> f.name) fields)))
            (Printf.sprintf "unknown field `%s` on type `%s`" field (type_key obj_ty))
          :: inner
        | _ -> inner)
     | None -> inner)
  | ELit _ | EVar _ | EConstructor _ | EFail _ -> []
  | EApp _ ->
    (* Check if this is a SQL select expression: selectOne/select binder from Entity where/order/limit ...
       If so, add the binder (typed as Entity) to the env for validating sub-expressions. *)
    let flat = let rec go acc = function
      | EApp { fn; arg; _ } -> go (arg :: acc) fn
      | hd -> (hd, acc)
      in go [] e
    in
    let (head, args) = flat in
    let sql_binder_env = match head with
      | EVar { name = ("selectOne" | "select" | "selectCount" | "selectSum"); _ } ->
        (* args[0] = binder (or field for sum), args[1] = "from", args[2] = Entity name *)
        let binder_name = match args with
          | EVar { name; _ } :: _ -> Some name
          | EField { obj = EVar { name; _ }; _ } :: _ -> Some name  (* sum: binder.field from ... *)
          | _ -> None
        in
        let entity_name = match args with
          | _ :: EVar { name = "from"; _ } :: EConstructor { name; _ } :: _ -> Some name
          | _ :: EVar { name = "from"; _ } :: EVar { name; _ } :: _ -> Some name
          | _ -> None
        in
        (match binder_name, entity_name with
         | Some bn, Some en -> (bn, mk_name_type en) :: env
         | _ -> env)
      | EVar { name = "update"; _ } ->
        (* update binder in Entity ... *)
        let binder_name = match args with EVar { name; _ } :: _ -> Some name | _ -> None in
        let entity_name = match args with
          | _ :: EVar { name = "in"; _ } :: EConstructor { name; _ } :: _ -> Some name
          | _ :: EVar { name = "in"; _ } :: EVar { name; _ } :: _ -> Some name
          | _ -> None
        in
        (match binder_name, entity_name with
         | Some bn, Some en -> (bn, mk_name_type en) :: env
         | _ -> env)
      | EVar { name = ("delete" | "deleteAndReturnResult"); _ } ->
        (* delete binder from Entity [where binder.field] *)
        let binder_name = match args with EVar { name; _ } :: _ -> Some name | _ -> None in
        let entity_name = match args with
          | _ :: EVar { name = "from"; _ } :: EConstructor { name; _ } :: _ -> Some name
          | _ :: EVar { name = "from"; _ } :: EVar { name; _ } :: _ -> Some name
          | _ -> None
        in
        (match binder_name, entity_name with
         | Some bn, Some en -> (bn, mk_name_type en) :: env
         | _ -> env)
      | _ -> env
    in
    (* Also check insert/upsert/update field names directly *)
    let insert_errors = match head with
      | EVar { name = ("insert" | "upsert"); _ } ->
        (* args: [EntityExpr, ERecord { fields }, ...] *)
        (match args with
         | entity_expr :: ERecord { fields; _ } :: _ ->
           let entity_name = match entity_expr with
             | EConstructor { name; _ } | EVar { name; _ } -> Some name
             | _ -> None
           in
           (match entity_name with
            | None -> []
            | Some en ->
              let entity_fields = record_fields_of_type fields_by_type (mk_name_type en) in
              List.filter_map (fun (fname, _) ->
                match entity_fields with
                | None -> None
                | Some efs when not (List.exists (fun (f : field_def) -> f.name = fname) efs) ->
                  Some (make_error (match e with EApp { loc; _ } -> loc | _ -> dummy_loc "")
                    ~hint:(Printf.sprintf "valid fields: %s" (String.concat ", " (List.map (fun (f : field_def) -> f.name) efs)))
                    (Printf.sprintf "unknown field `%s` on type `%s`" fname en))
                | _ -> None
              ) fields)
         | _ -> [])
      | _ -> []
    in
    (* e is guaranteed to be EApp here (we're inside the EApp match arm), but OCaml
       can't prove that, so provide a safe fallback instead of assert false *)
    let (fn_e, arg_e) = match e with EApp { fn; arg; _ } -> (fn, arg) | _ -> (e, e) in
    insert_errors
    @ validate_field_accesses sql_binder_env funcs fields_by_type ctors fn_e
    @ validate_field_accesses sql_binder_env funcs fields_by_type ctors arg_e
  | EBinop { left; right; _ } ->
    validate_field_accesses env funcs fields_by_type ctors left
    @ validate_field_accesses env funcs fields_by_type ctors right
  | EUnop { arg; _ } -> validate_field_accesses env funcs fields_by_type ctors arg
  | EIf { cond; then_; else_; _ } ->
    validate_field_accesses env funcs fields_by_type ctors cond
    @ validate_field_accesses env funcs fields_by_type ctors then_
    @ validate_field_accesses env funcs fields_by_type ctors else_
  | ECase { scrut; arms; _ } ->
    let scrut_errors = validate_field_accesses env funcs fields_by_type ctors scrut in
    let scrut_ty = infer_expr_type env funcs fields_by_type ctors scrut in
    scrut_errors @ List.concat_map (fun (arm : case_arm) ->
      let arm_env = pattern_bindings scrut_ty ctors arm.pattern @ env in
      validate_field_accesses arm_env funcs fields_by_type ctors arm.body
    ) arms
  | ELet { name; value; body; _ } ->
    let value_errors = validate_field_accesses env funcs fields_by_type ctors value in
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (name, ty) :: env
      | None -> env
    in
    (* Detect `update binder in Entity` statements and add binder to env for body *)
    let env' =
      let flat = let rec go acc = function
        | EApp { fn; arg; _ } -> go (arg :: acc) fn
        | hd -> (hd, acc)
        in go [] value
      in
      match flat with
      | (EVar { name = "update"; _ }, EVar { name = binder; _ } :: EVar { name = "in"; _ } :: entity_expr :: _) ->
        let entity_name = match entity_expr with
          | EConstructor { name; _ } | EVar { name; _ } -> Some name
          | _ -> None
        in
        (match entity_name with
         | Some en -> (binder, mk_name_type en) :: env'
         | None -> env')
      | _ -> env'
    in
    value_errors @ validate_field_accesses env' funcs fields_by_type ctors body
  | ELetProof { value_name; value; body; _ } ->
    let value_errors = validate_field_accesses env funcs fields_by_type ctors value in
    let env' = match infer_expr_type env funcs fields_by_type ctors value with
      | Some ty -> (value_name, ty) :: env
      | None -> env
    in
    value_errors @ validate_field_accesses env' funcs fields_by_type ctors body
  | ERecord { fields; _ } ->
    List.concat_map (fun (_, v) -> validate_field_accesses env funcs fields_by_type ctors v) fields
  | EList { elems; _ } ->
    List.concat_map (validate_field_accesses env funcs fields_by_type ctors) elems
  | EOk { value; _ } -> validate_field_accesses env funcs fields_by_type ctors value
  | ETelemetry { fields; _ } ->
    List.concat_map (fun (_, v) -> validate_field_accesses env funcs fields_by_type ctors v) fields
  | EEnqueue { payload; _ } ->
    validate_field_accesses env funcs fields_by_type ctors payload
  | EPublish { key; payload; _ } ->
    (match key with Some e -> validate_field_accesses env funcs fields_by_type ctors e | None -> [])
    @ (match payload with Some e -> validate_field_accesses env funcs fields_by_type ctors e | None -> [])
  | EStartWorkers _ -> []
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ } | EWithTransaction { body; _ } ->
    validate_field_accesses env funcs fields_by_type ctors body
  | EServe { port; _ } -> validate_field_accesses env funcs fields_by_type ctors port
  | ELambda { params; body; _ } ->
    let env' = List.map (fun (b : binding) -> (b.name, b.type_expr)) params @ env in
    validate_field_accesses env' funcs fields_by_type ctors body

let check_sql_field_names ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls in
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      let env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
      errors := validate_field_accesses env funcs fields_by_type ctors fd.body @ !errors
    | _ -> ()
  ) decls;
  List.rev !errors

let local_declared_type_names (decls : top_decl list) : string list =
  List.concat_map (function
    | DType (TypeAdt { name; _ }) -> [name]
    | DType (TypeNewtype { name; _ })
    | DType (TypeAlias { name; _ }) -> [name]
    | DRecord r -> [r.name]
    | DEntity e -> [e.name]
    | _ -> []
  ) decls

let check_codec_target_types (decls : top_decl list) : validation_error list =
  let known_types = local_declared_type_names decls in
  let errors = ref [] in
  List.iter (function
    | DCodec cf when not (List.mem cf.type_name known_types) ->
      errors := make_error cf.loc
        ~hint:(Printf.sprintf "declare `record %s { ... }`, `entity %s { ... }`, or `type %s ...` before this codec" cf.type_name cf.type_name cf.type_name)
        (Printf.sprintf "codec '%s' refers to unknown type '%s'" cf.name cf.type_name)
        :: !errors
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── 3. Codec proof coverage ──────────────────────────────────────────────── *)

let check_codec_proof_coverage ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls @ extra_funcs in
  let record_proofs = List.filter_map (function
    | DRecord r ->
      let field_proofs = List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | Some proof -> Some (f.name, List.sort_uniq String.compare (proof_predicates proof))
        | None -> None
      ) r.fields in
      if field_proofs = [] then None else Some (r.name, field_proofs)
    | _ -> None
  ) decls in
  let errors = ref [] in
  List.iter (function
    | DCodec cf ->
      (match List.assoc_opt cf.name record_proofs with
       | None -> ()
       | Some field_requirements ->
         (match cf.from_json with
          | FromJsonForbidden | FromJsonAdt -> ()
          | FromJsonAlts alts ->
            List.iter (fun alt ->
              List.iter (function
                | DecodeField { field_name; via; loc; _ } ->
                  (match List.assoc_opt field_name field_requirements with
                   | None -> ()
                   | Some required_preds ->
                     if via = [] then
                       errors := make_error loc
                         ~hint:(Printf.sprintf "add `via <checkFn>` so field '%s' is validated before decoding succeeds" field_name)
                         (Printf.sprintf "codec '%s': decoder field '%s' requires proof predicates %s but has no `via` validation"
                            cf.name field_name (String.concat ", " required_preds))
                         :: !errors
                     else begin
                       let covered = ref [] in
                       List.iter (fun via_fn ->
                         match List.assoc_opt via_fn funcs with
                         | None ->
                           errors := make_error loc
                             ~hint:"codec `via` entries must reference declared `check` or `auth` functions"
                             (Printf.sprintf "codec '%s': `via %s` is not a declared function" cf.name via_fn)
                             :: !errors
                         | Some info when info.fi_kind <> CheckKind && info.fi_kind <> AuthKind ->
                           errors := make_error loc
                             ~hint:"only `check` and `auth` functions may appear after `via`"
                             (Printf.sprintf "codec '%s': `via %s` is a %s, not a check/auth function"
                                cf.name via_fn
                                (match info.fi_kind with
                                 | FnKind -> "fn"
                                 | HandlerKind -> "handler"
                                 | WorkerKind -> "worker"
                                 | DeadWorkerKind -> "dead-worker"
                                 | EstablishKind -> "establish"
                                 | MainKind -> "main"
                                 | CheckKind -> "check"
                                 | AuthKind -> "auth"))
                             :: !errors
                         | Some info ->
                           covered := pred_names_of_return_spec info.fi_return @ !covered
                       ) via;
                       let covered = List.sort_uniq String.compare !covered in
                       let uncovered = List.filter (fun pred -> not (List.mem pred covered)) required_preds in
                       if uncovered <> [] then
                         errors := make_error loc
                           ~hint:(Printf.sprintf "via functions provided: %s" (String.concat ", " via))
                           (Printf.sprintf "codec '%s': decoder field '%s' requires proof predicates %s that are not established by any `via` function"
                              cf.name field_name (String.concat ", " uncovered))
                           :: !errors
                     end)
                | DecodeDefault _ | DecodeCrossCheck _ -> ()
              ) alt
            ) alts))
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── 3b. Codec field type vs codec type ───────────────────────────────────
   Builtin codecs (stringCodec, intCodec, boolCodec, floatCodec) must match
   the declared field type.  User-defined codec names (e.g. `Priority`) must
   match the field's head type name.  §11.7 of the language spec. *)

let check_codec_field_types (decls : top_decl list) : validation_error list =
  (* Build a map: record/entity name -> (field_name -> type_expr) *)
  let field_types_by_type : (string * (string * type_expr) list) list =
    List.filter_map (function
      | DRecord r -> Some (r.name, List.map (fun (f : field_def) -> (f.name, f.type_expr)) r.fields)
      | DEntity e -> Some (e.name, List.map (fun (f : field_def) -> (f.name, f.type_expr)) e.fields)
      | _ -> None
    ) decls
  in
  (* Build newtype-to-base-type map: NoteId -> String, UserId -> String, etc. *)
  let newtype_base_type : (string * string) list =
    List.filter_map (function
      | DType (TypeNewtype { name; base_type; _ }) ->
        (match type_head_name base_type with
         | Some base -> Some (name, base)
         | None -> None)
      | _ -> None
    ) decls
  in
  let errors = ref [] in
  (* Shared helper: check one field_name + codec pair against declared field types *)
  let check_field_codec ~direction cf_name field_types field_name codec loc =
    match List.assoc_opt field_name field_types with
    | None ->
      (* Field does not exist on the record — this is a real error, not caught elsewhere *)
      if field_types <> [] then
        errors := make_error loc
          ~hint:(Printf.sprintf "valid fields on '%s': %s"
            cf_name (String.concat ", " (List.map fst field_types)))
          (Printf.sprintf "codec '%s': field '%s' does not exist on type '%s'; remove this %s entry or rename the field"
            cf_name field_name cf_name
            (if direction = `Encode then "toJson" else "fromJson"))
          :: !errors
    | Some field_type ->
      let field_type_name = type_head_name field_type in
      let verb = if direction = `Encode then "encodes" else "decodes to" in
      (match List.assoc_opt codec builtin_codec_type with
       | Some expected_type ->
         (match field_type_name with
          (* Accept builtin codec if the field is a newtype wrapping the codec's
             base type — newtypes are transparent at JSON boundaries (spec §11.6). *)
          | Some actual when actual <> expected_type
                          && not (match List.assoc_opt actual newtype_base_type with
                                  | Some base -> base = expected_type
                                  | None -> false) ->
            errors := make_error loc
              ~hint:(Printf.sprintf "use `with_codec %s` or a matching codec for %s fields"
                       (match actual with
                        | s when List.mem_assoc s (List.map (fun (a,b) -> (b,a)) builtin_codec_type) ->
                          List.assoc s (List.map (fun (a,b) -> (b,a)) builtin_codec_type)
                        | s -> s)
                       actual)
              (Printf.sprintf "codec '%s': field '%s' has type `%s` but `%s` %s `%s`"
                 cf_name field_name (pp_type_expr field_type) codec verb expected_type)
              :: !errors
          | _ -> ())
       | None ->
         (match field_type_name with
          | Some actual when actual <> codec ->
            errors := make_error loc
              ~hint:(Printf.sprintf "use `with_codec %s` to match the field's declared type" actual)
              (Printf.sprintf "codec '%s': field '%s' has type `%s` but `with_codec %s` references a different type"
                 cf_name field_name (pp_type_expr field_type) codec)
              :: !errors
          | _ -> ()))
  in
  List.iter (function
    | DCodec cf ->
      let field_types = match List.assoc_opt cf.type_name field_types_by_type with
        | Some ft -> ft
        | None -> []
      in
      (* Check fromJson *)
      (match cf.from_json with
       | FromJsonForbidden | FromJsonAdt -> ()
       | FromJsonAlts alts ->
         List.iter (fun alt ->
           List.iter (function
             | DecodeField { field_name; codec; loc; _ } ->
               check_field_codec ~direction:`Decode cf.name field_types field_name codec loc
             | DecodeDefault _ | DecodeCrossCheck _ -> ()
           ) alt
         ) alts);
      (* Check toJson *)
      (match cf.to_json with
       | ToJsonForbidden | ToJsonAdt -> ()
       | ToJsonFields entries ->
         List.iter (fun (entry : codec_encode_entry) ->
           check_field_codec ~direction:`Encode cf.name field_types entry.field_name entry.codec entry.loc
         ) entries)
    | _ -> ()
  ) decls;
  List.rev !errors


(* ── 4. Call-site proof flow + 5. ForAll propagation ────────────────────── *)

