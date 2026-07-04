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
    let obj_record_ty =
      match infer_expr_type env funcs fields_by_type ctors obj with
      | Some ty -> Some ty
      | None ->
        (* SQL-1: an entity-qualified field in a join condition (`Post.usrId`) has
           [obj] = the entity NAME as a constructor/var, which infer_expr_type does
           not resolve to the entity's record type — so the join field previously
           escaped validation (a false documented guarantee).  Resolve it directly
           when the name is a declared entity/record.  (Module-qualified stdlib
           calls like `String.length` have a non-entity head, so record_fields_of_type
           is None and this does not fire.) *)
        (match obj with
         | EConstructor { name; _ } | EVar { name; _ }
           when record_fields_of_type fields_by_type (mk_name_type name) <> None ->
           Some (mk_name_type name)
         | _ -> None)
    in
    (match obj_record_ty with
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
      | EVar { name = ("selectOne" | "select" | "selectCount" | "selectSum"
                      | "selectMax" | "selectMin"); _ } ->
        (* args[0] = binder (or field for sum/max/min), args[1] = "from", args[2] = Entity name *)
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
    (* SQL-1: validate the JOINED entity name in `innerJoin <Entity> on …`.  The
       flattened args carry `EVar "innerJoin" :: <Entity> :: …`; the join FIELDS
       (`<Entity>.field`) are validated by the EField arm above (via the
       entity-name resolution), but the joined entity name itself was unchecked,
       so a misspelled join target compiled and failed at runtime. *)
    let join_entity_errors = match head with
      | EVar { name = ("selectOne" | "select" | "selectCount" | "selectSum"
                      | "selectMax" | "selectMin"); _ } ->
        let rec scan = function
          | EVar { name = "innerJoin"; _ } :: ent :: rest ->
            let here = match ent with
              | (EConstructor { name; loc; _ } | EVar { name; loc; _ })
                when record_fields_of_type fields_by_type (mk_name_type name) = None ->
                [ make_error loc
                    (Printf.sprintf "unknown entity `%s` in innerJoin" name) ]
              | _ -> []
            in here @ scan rest
          | _ :: rest -> scan rest
          | [] -> []
        in scan args
      | _ -> []
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
    let recursive_errs =
      validate_field_accesses sql_binder_env funcs fields_by_type ctors fn_e
      @ validate_field_accesses sql_binder_env funcs fields_by_type ctors arg_e in
    (* The flattened select chain is re-scanned at every peel, so the same
       innerJoin clause yields the same join-entity error at multiple levels.
       Emit it only where it is not already reported by a deeper level. *)
    let join_errs = List.filter (fun je -> not (List.mem je recursive_errs)) join_entity_errors in
    insert_errors @ join_errs @ recursive_errs
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
  | ELambda { params; body; _ } ->
    let env' = List.map (fun (b : binding) -> (b.name, b.type_expr)) params @ env in
    validate_field_accesses env' funcs fields_by_type ctors body
  (* EConstructor and EFail were NON-descending no-ops in the original walk
     (the leaf `ELit _ | EVar _ | EConstructor _ | EFail _ -> []` arm above
     already matched EConstructor/EFail), and EStartWorkers/EStartEmailWorker
     are genuine leaves. `Ast_visitor.fold_children` DOES descend into
     EConstructor.args / EFail.message, so keep these explicit no-ops to
     preserve behaviour exactly. (EConstructor/EFail are matched at the top.) *)
  | EStartWorkers _ | EStartEmailWorker _ -> []
  (* Every remaining variant recurses into all child exprs with `env`
     UNCHANGED (only EField/EApp/ECase/ELet/ELetProof/ELambda above touch the
     type env), so the mechanical recursion is exactly a left-to-right fold
     over the immediate children. `fold_children` visits the same children in
     the same source order, and `acc @ f child` preserves the prior
     `@`-concatenation order verbatim. *)
  | _ ->
    Ast_visitor.fold_children
      (fun acc child -> acc @ validate_field_accesses env funcs fields_by_type ctors child)
      [] e

let check_sql_field_names ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let mf = facts_or_compute ?facts ~extra_funcs decls in
  let funcs = mf.mf_funcs in
  let fields_by_type = mf.mf_fields_map in
  let ctors = mf.mf_ctors in
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

(* Classify a declared type's KIND so codec forms can be checked against it.
   `Adt` has constructors; `Record` (record/entity) has named fields.
   Newtypes/aliases are kind-ambiguous without resolution, so they are left
   `Other` and not subjected to the kind check (conservative — avoids
   over-rejecting an alias that resolves to a record or ADT). *)
type codec_target_kind = Adt | Record | Other

let codec_target_kinds (decls : top_decl list) : (string * codec_target_kind) list =
  List.concat_map (function
    | DType (TypeAdt { name; _ }) -> [(name, Adt)]
    | DRecord r -> [(r.name, Record)]
    | DEntity e -> [(e.name, Record)]
    | DType (TypeNewtype { name; _ })
    | DType (TypeAlias { name; _ }) -> [(name, Other)]
    | _ -> []
  ) decls

let check_codec_target_types ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  (* Validation-consolidation Phase 1: the per-codec iteration runs over the
     precomputed [mf_codecs] (source-order preserved) instead of re-filtering
     [decls].  [known_types]/[kinds] still scan all decls (they read record/
     entity/type decls, not just codecs).  Byte-identical: the previous
     [_ -> ()] arm produced no errors. *)
  let codecs = (facts_or_compute ?facts ~extra_funcs decls).mf_codecs in
  let known_types = local_declared_type_names decls in
  let kinds = codec_target_kinds decls in
  let errors = ref [] in
  List.iter (fun (cf : codec_form) ->
    if not (List.mem cf.type_name known_types) then
      errors := make_error cf.loc
        ~hint:(Printf.sprintf "declare `record %s { ... }`, `entity %s { ... }`, or `type %s ...` before this codec" cf.type_name cf.type_name cf.type_name)
        (Printf.sprintf "codec '%s' refers to unknown type '%s'" cf.name cf.type_name)
        :: !errors
    else begin
      (* Target is a known type — verify the codec FORM matches its KIND.
         `adtJson` requires an ADT (has constructors); a record-style
         `toJson { ... }` / `fromJson [ ... ]` requires a record/entity. *)
      let uses_adt_json =
        cf.to_json = ToJsonAdt || cf.from_json = FromJsonAdt in
      let uses_record_json =
        (match cf.to_json with ToJsonFields _ -> true | _ -> false)
        || (match cf.from_json with FromJsonAlts _ -> true | _ -> false) in
      (match List.assoc_opt cf.type_name kinds with
       | Some Record when uses_adt_json ->
         errors := make_error cf.loc
           ~hint:(Printf.sprintf "use a record-style codec (`toJson { ... }` / `fromJson [ ... ]`) for record/entity `%s`, or apply `adtJson` to an ADT (a `type` with constructors)" cf.type_name)
           (Printf.sprintf "codec '%s': `adtJson` requires an ADT target, but '%s' is a record/entity (it has no constructors)" cf.name cf.type_name)
           :: !errors
       | Some Adt when uses_record_json ->
         errors := make_error cf.loc
           ~hint:(Printf.sprintf "use `adtJson` for ADT `%s` (a `type` with constructors), or apply a record-style codec to a record/entity" cf.type_name)
           (Printf.sprintf "codec '%s': record-style `toJson`/`fromJson` requires a record/entity target, but '%s' is an ADT" cf.name cf.type_name)
           :: !errors
       | _ -> ())
    end
  ) codecs;
  List.rev !errors

(* ── 3. Codec proof coverage ──────────────────────────────────────────────── *)

let check_codec_proof_coverage ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let mf = facts_or_compute ?facts ~extra_funcs decls in
  let funcs = mf.mf_funcs in
  (* Validation-consolidation Phase 1: iterate precomputed [mf_codecs] for the
     per-codec coverage scan (source-order preserved, byte-identical). *)
  let codecs = mf.mf_codecs in
  (* 2026-07-03 hole #9: this scan previously covered `DRecord` only, so a
     proof-annotated field on an *entity* used as a request body / queue payload
     decoded through a codec that omitted the `via` validation was accepted with
     a checkerless decoder (fail-open at the HTTP boundary — the record form is a
     compile error, making the entity trap invisible).  Entities carry field
     proofs exactly like records, so they get the identical coverage check. *)
  let named_fields_of = function
    | DRecord r -> Some (r.name, r.fields)
    | DEntity e -> Some (e.name, e.fields)
    | _ -> None
  in
  let record_proofs = List.filter_map (fun d ->
    match named_fields_of d with
    | None -> None
    | Some (name, fields) ->
      let field_proofs = List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | Some proof -> Some (f.name, List.sort_uniq String.compare (proof_predicates proof))
        | None -> None
      ) fields in
      if field_proofs = [] then None else Some (name, field_proofs)
  ) decls in
  let errors = ref [] in
  List.iter (fun (cf : codec_form) ->
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
                | DecodeDefault { field_name; loc; _ } ->
                  (* A proof-annotated field must be validated at the boundary
                     (`via <checkFn>`); populating it from a codec DEFAULT value
                     establishes no proof, so the decoded record would carry an
                     unproven field.  Fail closed for such fields; non-proof
                     fields (no requirement) keep defaulting freely. *)
                  (match List.assoc_opt field_name field_requirements with
                   | Some (_ :: _ as required_preds) ->
                     errors := make_error loc
                       ~hint:(Printf.sprintf
                         "field '%s' carries a proof; decode it with `via <checkFn>` that establishes it, not from a default value"
                         field_name)
                       (Printf.sprintf
                         "codec '%s': decoder field '%s' requires proof predicates %s but is populated from a default value with no `via` validation"
                         cf.name field_name (String.concat ", " required_preds))
                       :: !errors
                   | Some [] | None -> ())
                | DecodeCrossCheck _ -> ()
              ) alt
            ) alts))
  ) codecs;
  List.rev !errors

(* ── 2c. fromJson alternative completeness ─────────────────────────────────
   Each `{ ... }` block in `fromJson [ ... ]` is a complete decode ALTERNATIVE,
   tried first-success at runtime — NOT a group of fields that get merged. An
   alternative that maps only SOME of the target record's fields decodes to an
   incomplete record, which then fails its own body type at the HTTP/api-test
   boundary with a confusing runtime 400 (issue #3: a user who put each field in
   its own `{ }` block got two one-field alternatives instead of one two-field
   record). Reject the incomplete alternative at compile time and point at the
   one-block form. A field populated by a codec DEFAULT counts as covered. *)
let check_codec_alt_completeness ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let mf = facts_or_compute ?facts ~extra_funcs decls in
  let codecs = mf.mf_codecs in
  let named_fields_of = function
    | DRecord r -> Some (r.name, List.map (fun (f : field_def) -> f.name) r.fields)
    | DEntity e -> Some (e.name, List.map (fun (f : field_def) -> f.name) e.fields)
    | _ -> None
  in
  let record_fields = List.filter_map named_fields_of decls in
  let errors = ref [] in
  List.iter (fun (cf : codec_form) ->
    match List.assoc_opt cf.type_name record_fields with
    | None -> ()
    | Some all_fields ->
      (match cf.from_json with
       | FromJsonForbidden | FromJsonAdt -> ()
       | FromJsonAlts alts ->
         List.iteri (fun i alt ->
           let covered = List.filter_map (function
             | DecodeField { field_name; _ } -> Some field_name
             | DecodeDefault { field_name; _ } -> Some field_name
             | DecodeCrossCheck _ -> None) alt in
           let missing = List.filter (fun f -> not (List.mem f covered)) all_fields in
           if missing <> [] then begin
             let alt_loc = match alt with
               | DecodeField { loc; _ } :: _
               | DecodeDefault { loc; _ } :: _
               | DecodeCrossCheck { loc; _ } :: _ -> loc
               | [] -> cf.loc in
             errors := make_error alt_loc
               ~hint:(Printf.sprintf
                 "each `{ … }` in `fromJson [ … ]` is a COMPLETE decode alternative (tried first-success), not merged — put all fields of `%s` in ONE `{ }` block"
                 cf.type_name)
               (Printf.sprintf
                 "codec '%s': fromJson alternative %d does not decode field(s) %s of `%s`; every alternative must produce a complete `%s`"
                 cf.name (i + 1) (String.concat ", " missing) cf.type_name cf.type_name)
               :: !errors
           end
         ) alts)
  ) codecs;
  List.rev !errors

(* ── 3b. Codec field type vs codec type ───────────────────────────────────
   Builtin codecs (stringCodec, intCodec, boolCodec, floatCodec) must match
   the declared field type.  User-defined codec names (e.g. `Priority`) must
   match the field's head type name.  §11.7 of the language spec. *)

let check_codec_field_types ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let mf = facts_or_compute ?facts ~extra_funcs decls in
  (* Validation-consolidation Phase 1: the record/entity field-type map is now
     derived from the precomputed [mf_fields_map] (build_fields_map decls) rather
     than re-filtering DRecord/DEntity out of [decls].  [mf_fields_map] is itself
     [build_fields_map decls] in source order (DRecord/DEntity), so the derived
     name->(field,type) projection is byte-identical to the previous inline
     filter_map.  The per-codec scan iterates the precomputed [mf_codecs]. *)
  let field_types_by_type : (string * (string * type_expr) list) list =
    List.map (fun (tname, fields) ->
      (tname, List.map (fun (f : field_def) -> (f.name, f.type_expr)) fields))
      mf.mf_fields_map
  in
  let codecs = mf.mf_codecs in
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
  List.iter (fun (cf : codec_form) ->
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
  ) codecs;
  List.rev !errors


(* ── 4. Call-site proof flow + 5. ForAll propagation ────────────────────── *)

