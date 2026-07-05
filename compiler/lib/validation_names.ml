open Ast
open Location
open Validation_common
open Validation_proof

let check_case_exhaustiveness ?(extra_ctors=[]) (decls : top_decl list) : validation_error list =
  let funcs = build_func_info decls in
  let fields_by_type = build_fields_map decls in
  let ctors = build_ctor_info decls @ extra_ctors in
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      let env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
      errors := check_case_exhaustiveness_expr env funcs fields_by_type ctors fd.body @ !errors
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── B2. Name shadowing detection ───────────────────────────────────────── *)

(** Collect variable names bound by a pattern (excluding "_"). *)
let rec pattern_bound_names (pat : pattern) : string list =
  match pat with
  | PWild | PLit _ -> []
  | PVar s -> if s = "_" then [] else [s]
  | PNullary _ -> []
  | PCon { fields; _ } ->
    List.concat_map (fun (_, sub_pat) -> pattern_bound_names sub_pat) fields

let duplicate_parameter_errors (bindings : binding list) : validation_error list =
  let seen = ref [] in
  List.concat_map (fun (b : binding) ->
    if b.name = "_" then []
    else if List.mem b.name !seen then
      [ make_error b.loc
          ~hint:(Printf.sprintf "rename one of the parameters named `%s`" b.name)
          (Printf.sprintf "duplicate parameter name `%s`" b.name) ]
    else (
      seen := b.name :: !seen;
      []
    )
  ) bindings

(** Walk every `exists witness => body` in an expression, tracking only the
    witness names seen in outer `exists` frames.  Fires when an inner `exists`
    reuses the same witness name as an outer one — e.g. `exists p => exists p
    => p` — which would make the two existential packages indistinguishable. *)
let rec check_exists_witness_shadowing (exist_seen : string list) (e : expr)
    : validation_error list =
  match e with
  | EApp { fn = EVar { name = "make-witness"; _ };
           arg = EApp { fn = EVar { name = witness; loc = wit_loc; _ }; arg = body; _ }; _ } ->
    let shadow_errors =
      if witness <> "_" && List.mem witness exist_seen then
        [ make_error wit_loc
            (Printf.sprintf
               "exists witness `%s` shadows the outer exists witness of the same name"
               witness) ]
      else []
    in
    let exist_seen' = if witness = "_" then exist_seen else witness :: exist_seen in
    shadow_errors @ check_exists_witness_shadowing exist_seen' body
  (* These variants were deliberately NON-descending in the original walk: an
     `exists`/`make-witness` frame cannot appear inside a `fail` message, a
     `serve` port, the worker-start capability list, or telemetry/queue/pubsub
     payloads in well-formed programs, so the hand-walk returned `[]` for them
     WITHOUT recursing. `Ast_visitor.fold_children` would descend into their
     child exprs (e.g. EServe.port, ETelemetry/EEnqueue/EPublish payloads),
     changing behaviour, so keep them explicit no-ops. *)
  | ELit _ | EVar _ | EFail _ | EServe _ | EStartWorkers _
  | ETelemetry _ | EEnqueue _ | EPublish _ | EStartEmailWorker _ -> []
  (* Every remaining variant carries `exist_seen` UNCHANGED into all its child
     exprs (only the `make-witness` arm above extends the witness frame), and
     accumulates errors left-to-right.  That is exactly a left-to-right fold
     over the immediate children via the shared {!Ast_visitor}, so the
     mechanical arms collapse into one fall-through.  `fold_children` visits
     children in the same source order the hand-walk did, and `acc @ f child`
     preserves the prior `@`-concatenation order verbatim. (EField only visits
     `obj`, matching the original `EField { obj = arg; _ }` arm.) *)
  | _ ->
    Ast_visitor.fold_children
      (fun acc child -> acc @ check_exists_witness_shadowing exist_seen child)
      [] e

let rec check_name_shadowing_expr
    (seen : string list)
    (e : expr)
    : validation_error list =
  match e with
  | ELet { name; value; body; loc; _ } ->
    let value_errors = check_name_shadowing_expr seen value in
    let shadow_errors =
      if name <> "_" && List.mem name seen then
        [ make_error loc
            (Printf.sprintf "let binding shadows existing name(s): `%s`" name) ]
      else []
    in
    let seen' = if name <> "_" then name :: seen else seen in
    value_errors @ shadow_errors @ check_name_shadowing_expr seen' body
  | ECase { scrut; arms; _ } ->
    let scrut_errors = check_name_shadowing_expr seen scrut in
    let arm_errors = List.concat_map (fun (arm : case_arm) ->
      let bound = pattern_bound_names arm.pattern in
      (* Check for duplicate binders within this arm's own pattern *)
      let dup_errors =
        let rec find_dups seen_in_pat = function
          | [] -> []
          | name :: rest ->
            if List.mem name seen_in_pat then
              [ make_error arm.loc
                  ~hint:(Printf.sprintf "rename one of the `%s` binders" name)
                  (Printf.sprintf "duplicate variable binding `%s` in case arm pattern" name) ]
            else find_dups (name :: seen_in_pat) rest
        in
        find_dups [] bound
      in
      let shadow_errors = List.filter_map (fun var_name ->
        if List.mem var_name seen then
          Some (make_error arm.loc
            (Printf.sprintf "case pattern binder `%s` shadows an existing name" var_name))
        else None
      ) bound in
      let seen' = bound @ seen in
      let guard_errors =
        match arm.guard with
        | Some guard -> check_name_shadowing_expr seen' guard
        | None -> []
      in
      dup_errors @ shadow_errors @ guard_errors @ check_name_shadowing_expr seen' arm.body
    ) arms in
    scrut_errors @ arm_errors
  | ELetProof { value_name; proof_name; value; body; loc; _ } ->
    let value_errors = check_name_shadowing_expr seen value in
    let bound_names =
      List.filter (fun name -> name <> "_") [value_name; proof_name]
    in
    let duplicate_errors =
      match bound_names with
      | [a; b] when a = b ->
        [ make_error loc
            ~hint:(Printf.sprintf "rename one of the `%s` binders" a)
            (Printf.sprintf "duplicate variable binding `%s` in let-proof pattern" a) ]
      | _ -> []
    in
    let shadow_errors = List.filter_map (fun name ->
      if List.mem name seen then
        Some (make_error loc
          (Printf.sprintf "let binding shadows existing name(s): `%s`" name))
      else None
    ) bound_names in
    value_errors
    @ duplicate_errors
    @ shadow_errors
    @ check_name_shadowing_expr (bound_names @ seen) body
  | ELambda { params; body; _ } ->
    let duplicate_errors = duplicate_parameter_errors params in
    let shadow_errors = List.filter_map (fun (b : binding) ->
      if b.name <> "_" && List.mem b.name seen then
        Some (make_error b.loc
          (Printf.sprintf "let binding shadows existing name(s): `%s`" b.name))
      else None
    ) params in
    let seen' =
      List.fold_right (fun (b : binding) acc ->
        if b.name = "_" then acc else b.name :: acc
      ) params seen
    in
    duplicate_errors @ shadow_errors @ check_name_shadowing_expr seen' body
  (* EConstructor args and the `fail` message MUST be descended into: review
     2026-07 (SHADOW-1/2/3) showed a proof-carrying binder shadowed inside a bare
     constructor argument (`Something (case raw of Something n -> needsProof n)`)
     or a `fail` message escaped V001 entirely, letting the shadow forge the
     outer proof onto a raw value.  Shadowing is illegal EVERYWHERE (a hard
     language rule, not position-dependent), so these fall through to the
     `fold_children` catch-all like every other non-binder form. *)
  (* All remaining variants pass `seen` UNCHANGED into every child expr — only
     the binder-introducing arms above (ELet, ECase, ELetProof, ELambda) extend
     it.  Their hand-rolled recursion is exactly a left-to-right fold over the
     immediate children, so it collapses into one {!Ast_visitor} fall-through.
     `fold_children` threads children in the same source order, and `acc @ f
     child` preserves the prior `@`-concatenation order verbatim. (EField only
     visits `obj`, the cache/email/serve/with forms only their child exprs, and
     the leaves contribute nothing — all matched by `fold_children`.) *)
  | _ ->
    Ast_visitor.fold_children
      (fun acc child -> acc @ check_name_shadowing_expr seen child)
      [] e


and check_name_shadowing_test_stmts
    (seen : string list)
    (stmts : test_stmt list)
    : validation_error list =
  match stmts with
  | [] -> []
  | stmt :: rest ->
    let stmt_errors, seen' =
      match stmt with
      | TsLetProof { value_name = name; proof_names; value; loc; _ } ->
        let value_errors = check_name_shadowing_expr seen value in
        let shadow_errors =
          if name <> "_" && List.mem name seen then
            [ make_error loc
                (Printf.sprintf "let binding shadows existing name(s): `%s`" name) ]
          else []
        in
        let seen' = if name <> "_" then name :: seen else seen in
        let seen' = List.fold_left (fun acc pn -> if pn <> "_" then pn :: acc else acc) seen' proof_names in
        (value_errors @ shadow_errors, seen')
      | TsLet { name; value; loc; _ } ->
        let value_errors = check_name_shadowing_expr seen value in
        let shadow_errors =
          if name <> "_" && List.mem name seen then
            [ make_error loc
                (Printf.sprintf "let binding shadows existing name(s): `%s`" name) ]
          else []
        in
        let seen' = if name <> "_" then name :: seen else seen in
        (value_errors @ shadow_errors, seen')
      | TsExpect { left; right; _ } ->
        let expr_errors =
          check_name_shadowing_expr seen left
          @ (match right with Some r -> check_name_shadowing_expr seen r | None -> [])
        in
        (expr_errors, seen)
      | TsExpectFail { fn; arg; _ }
      | TsExpectHasProof { fn; arg; _ } ->
        (check_name_shadowing_expr seen fn @ check_name_shadowing_expr seen arg, seen)
      | TsProperty { params; body; _ } ->
        let bindings = List.map (fun (p : property_param) -> p.binding) params in
        let duplicate_errors = duplicate_parameter_errors bindings in
        let shadow_errors = List.filter_map (fun (p : property_param) ->
          let b = p.binding in
          if b.name <> "_" && List.mem b.name seen then
            Some (make_error b.loc
              (Printf.sprintf "let binding shadows existing name(s): `%s`" b.name))
          else None
        ) params in
        let prop_seen =
          List.fold_right (fun (b : binding) acc ->
            if b.name = "_" then acc else b.name :: acc
          ) bindings seen
        in
        let where_errors = List.concat_map (fun (p : property_param) ->
          match p.where_clause with
          | Some guard -> check_name_shadowing_expr prop_seen guard
          | None -> []
        ) params in
        let body_errors = check_name_shadowing_expr prop_seen body in
        (duplicate_errors @ shadow_errors @ where_errors @ body_errors, seen)
      | TsIf { cond; then_stmts; else_stmts; _ } ->
        let branch_errors =
          check_name_shadowing_expr seen cond
          @ check_name_shadowing_test_stmts seen then_stmts
          @ check_name_shadowing_test_stmts seen else_stmts
        in
        (branch_errors, seen)
      | TsCase { scrut; arms; _ } ->
        let scrut_errors = check_name_shadowing_expr seen scrut in
        let arm_errors = List.concat_map (fun (arm : ts_case_arm) ->
          let bound = pattern_bound_names arm.ts_pattern in
          let dup_errors =
            let rec find_dups seen_in_pat = function
              | [] -> []
              | name :: rest ->
                if List.mem name seen_in_pat then
                  [ make_error arm.ts_loc
                      ~hint:(Printf.sprintf "rename one of the `%s` binders" name)
                      (Printf.sprintf "duplicate variable binding `%s` in case arm pattern" name) ]
                else find_dups (name :: seen_in_pat) rest
            in
            find_dups [] bound
          in
          let shadow_errors = List.filter_map (fun var_name ->
            if List.mem var_name seen then
              Some (make_error arm.ts_loc
                (Printf.sprintf "let binding shadows existing name(s): `%s`" var_name))
            else None
          ) bound in
          let arm_seen = bound @ seen in
          let guard_errors =
            match arm.ts_guard with
            | Some guard -> check_name_shadowing_expr arm_seen guard
            | None -> []
          in
          dup_errors
          @ shadow_errors
          @ guard_errors
          @ check_name_shadowing_test_stmts arm_seen arm.ts_body
        ) arms in
        (scrut_errors @ arm_errors, seen)
      | TsExpr { e; _ } ->
        (check_name_shadowing_expr seen e, seen)
    in
    stmt_errors @ check_name_shadowing_test_stmts seen' rest

(* ── ForAll parameter subject enforcement ───────────────────────────────── *)

(** True when a proof expression contains a ForAll predicate without an explicit
    subject variable — i.e. `ForAll P` with only one argument. *)
let rec has_subjectless_forall (proof : proof_expr) : bool =
  match proof with
  | PredApp { pred = "ForAll" | "ForAllValues" | "ForAllKeys"; args = [_]; _ } -> true
  | PredAnd { left; right; _ } -> has_subjectless_forall left || has_subjectless_forall right
  | _ -> false

(** True if a type expression is List, Maybe List, Set, or Maybe Set (i.e. valid ForAll subject). *)
let rec is_collection_type (te : Ast.type_expr) : bool =
  match te with
  | TName { name = "List"; _ }
  | TName { name = "Set"; _ } -> true
  | TApp { head = TName { name = "List"; _ }; _ }
  | TApp { head = TName { name = "Set"; _ }; _ } -> true
  | TApp { head = TName { name = "Maybe"; _ }; arg; _ } -> is_collection_type arg
  | TApp { head; _ } -> is_collection_type head
  | _ -> false

(** True if a type expression is Dict K V (valid ForAllValues/ForAllKeys subject). *)
let is_dict_type (te : Ast.type_expr) : bool =
  match te with
  | TApp { head = TApp { head = TName { name = "Dict"; _ }; _ }; _ } -> true
  | _ -> false

(** Extract the ForAll subject variable from a proof, if present. *)
let rec forall_subjects (proof : proof_expr) : string list =
  match proof with
  | PredApp { pred = "ForAll"; args = [_; subj]; _ } -> [subj]
  | PredApp { pred = "ForAll"; args = [_]; _ } -> []
  | PredAnd { left; right; _ } -> forall_subjects left @ forall_subjects right
  | _ -> []

(** Extract the ForAllValues/ForAllKeys subject variable from a proof, if present. *)
let rec foralldict_subjects (proof : proof_expr) : string list =
  match proof with
  | PredApp { pred = "ForAllValues" | "ForAllKeys"; args = [_; subj]; _ } -> [subj]
  | PredApp { pred = "ForAllValues" | "ForAllKeys"; args = [_]; _ } -> []
  | PredAnd { left; right; _ } -> foralldict_subjects left @ foralldict_subjects right
  | _ -> []

(** Check that every parameter (and handler body-binding) ForAll proof annotation
    carries an explicit subject variable that matches the parameter name.
    e.g. `xs: List T ::: ForAll P xs` is valid; `xs: List T ::: ForAll P` is not.
    Also checks that ForAll subjects have a collection type (List or Set). *)
let check_forall_param_subjects (decls : top_decl list) : validation_error list =
  let check_binding (b : binding) =
    match b.proof_ann with
    | None -> []
    | Some proof ->
      let subjectless_errors =
        if has_subjectless_forall proof then
          [ make_error b.loc
              ~hint:(Printf.sprintf
                "add the parameter name as explicit subject: `%s ::: ForAll P %s`"
                b.name b.name)
              (Printf.sprintf
                "parameter `%s` has a `ForAll` annotation without an explicit subject variable; \
                 write `ForAll Predicate %s` to ensure the proof is tied to this parameter"
                b.name b.name) ]
        else []
      in
      (* Check that the parameter's declared type is a collection when ForAll is used *)
      let non_collection_errors =
        let subjects = forall_subjects proof in
        let dict_subjects = foralldict_subjects proof in
        let forall_errors =
          if subjects = [] then []
          else
            if not (is_collection_type b.type_expr) then
              [ make_error b.loc
                  ~hint:(Printf.sprintf
                    "`ForAll` quantifies over elements of a collection; \
                     parameter `%s` should have type `List T` or `Set T`"
                    b.name)
                  (Printf.sprintf
                    "parameter `%s` has a `ForAll` proof annotation but its type is not a collection \
                     (`List` or `Set`); `ForAll` is only meaningful on list or set-typed parameters"
                    b.name) ]
            else []
        in
        let dict_forall_errors =
          if dict_subjects = [] then []
          else
            if not (is_dict_type b.type_expr) then
              [ make_error b.loc
                  ~hint:(Printf.sprintf
                    "`ForAllValues`/`ForAllKeys` quantifies over a dict; \
                     parameter `%s` should have type `Dict K V`"
                    b.name)
                  (Printf.sprintf
                    "parameter `%s` has a `ForAllValues`/`ForAllKeys` proof annotation but its type is not \
                     a `Dict K V`; these quantifiers are only meaningful on dict-typed parameters"
                    b.name) ]
            else []
        in
        forall_errors @ dict_forall_errors
      in
      subjectless_errors @ non_collection_errors
  in
  List.concat_map (function
    | DFunc fd ->
      List.concat_map check_binding fd.params
    | _ -> []
  ) decls

let strip_exposed_import_name (name : string) : string =
  let len = String.length name in
  if len > 4 && String.sub name (len - 4) 4 = "(..)" then
    String.sub name 0 (len - 4)
  else
    name

let push_unique_name acc name =
  if name = "_" || List.mem name acc then acc else name :: acc

let local_function_names (decls : top_decl list) : string list =
  (* Collect both top-level `fn` names and top-level immutable bindings
     (spec §11.2) so the no-shadowing rule (§7.4, §13.2) applies to both
     uniformly. R51_S01 closed the gap where top-level value bindings
     were silently shadowable by function parameters. *)
  List.fold_left (fun acc -> function
    | DFunc fd -> push_unique_name acc fd.name
    | DConst c -> push_unique_name acc c.name
    | _ -> acc
  ) [] decls
  |> List.rev

let imported_plain_exposed_name_entries (m : module_form) : (string * string * loc) list =
  List.concat_map (fun (imp : import_decl) ->
    match imp.names with
    | ImportAll -> []
    | ImportExposing names ->
      List.filter_map (fun name ->
        let base = strip_exposed_import_name name in
        if String.contains base '.' then None
        else Some (base, imp.module_name, imp.loc)
      ) names
  ) m.imports

let imported_plain_exposed_names (m : module_form) : string list =
  List.fold_left (fun acc (name, _, _) -> push_unique_name acc name) [] (imported_plain_exposed_name_entries m)
  |> List.rev

let imported_plain_exposed_type_entries (m : module_form) : (string * string * loc) list =
  List.concat_map (fun (imp : import_decl) ->
    match imp.names with
    | ImportAll -> []
    | ImportExposing names ->
      List.filter_map (fun name ->
        match normalize_exposed_type_name name with
        | Some type_name -> Some (type_name, imp.module_name, imp.loc)
        | None -> None
      ) names
  ) m.imports

let imported_ctor_request_type_names (imp : import_decl) : string list =
  match imp.names with
  | ImportAll -> []
  | ImportExposing names ->
    List.filter_map (fun name ->
      let n = String.length name in
      if n >= 4 && String.sub name (n - 4) 4 = "(..)" then
        normalize_exposed_type_name name
      else
        None
    ) names

(** Constructors exported by stdlib ADT types, keyed by the type name.
    Used to detect conflicts when a local ADT reuses a stdlib constructor name. *)
let stdlib_adt_ctors : (string * (string * string list)) list = [
  (* (tesl_module, (type_name, [constructors...])) *)
  ("Tesl.Maybe",   ("Maybe",        ["Maybe"; "Something"; "Nothing"]));
  ("Tesl.Result",  ("Result",       ["Result"; "Ok"; "Err"]));
  ("Tesl.Either",  ("Either",       ["Either"; "Left"; "Right"]));
  ("Tesl.DB",      ("DeleteResult", ["DeleteResult"; "NoRowDeleted"; "RowsDeleted"]));
  ("Tesl.ApiTest", ("JobResult",    ["JobResult"; "JobOk"; "JobFailed"]));
]

let imported_plain_exposed_ctor_entries (m : module_form) : (string * string * string * loc) list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  let stdlib_entries =
    List.concat_map (fun (imp : import_decl) ->
      if not (is_tesl_module imp.module_name) then []
      else
        match imp.names with
        | ImportAll -> []
        | ImportExposing names ->
          let has_dotdot s =
            let n = String.length s in
            n > 4 && String.sub s (n - 4) 4 = "(..)"
          in
          let strip_dotdot s =
            let n = String.length s in
            if n > 4 && String.sub s (n - 4) 4 = "(..)" then String.sub s 0 (n - 4) else s
          in
          (* Only expand constructors for names explicitly listed with (..) *)
          let dotdot_types = names |> List.filter has_dotdot |> List.map strip_dotdot in
          (match List.assoc_opt imp.module_name stdlib_adt_ctors with
           | None -> []
           | Some (type_name, ctors) ->
             if List.mem type_name dotdot_types then
               List.map (fun ctor -> (ctor, type_name, imp.module_name, imp.loc)) ctors
             else [])
    ) m.imports
  in
  stdlib_entries @
  List.concat_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then []
    else
      let requested_types = imported_ctor_request_type_names imp in
      if requested_types = [] then []
      else
        let path = resolve_local_import_path m.source_file imp.module_name in
        if not (Sys.file_exists path) then []
        else
          let source = In_channel.with_open_text path In_channel.input_all in
          match Parser.parse_module path source with
          | Err _ -> []
          | Ok imported ->
            List.concat_map (function
              | DType (TypeAdt { name; variants; _ }) when List.mem name requested_types ->
                List.map (fun (v : adt_variant) ->
                  (v.ctor, name, imp.module_name, imp.loc)
                ) variants
              | _ -> []
            ) imported.decls
  ) m.imports

let local_type_entries (decls : top_decl list) : (string * loc) list =
  List.concat_map (function
    | DType (TypeNewtype { name; loc; _ }) -> [ (name, loc) ]
    | DType (TypeAlias { name; loc; _ }) -> [ (name, loc) ]
    | DType (TypeAdt { name; loc; _ }) -> [ (name, loc) ]
    | DRecord rf -> [ (rf.name, rf.loc) ]
    | DEntity ef -> [ (ef.name, ef.loc) ]
    | _ -> []
  ) decls

let local_ctor_entries (decls : top_decl list) : (string * string * loc) list =
  List.concat_map (function
    | DType (TypeAdt { name; variants; _ }) ->
      List.map (fun (v : adt_variant) -> (v.ctor, name, v.loc)) variants
    | _ -> []
  ) decls

let parameter_shadow_errors (seen : string list) (bindings : binding list) : validation_error list =
  List.filter_map (fun (b : binding) ->
    if b.name <> "_" && List.mem b.name seen then
      Some (make_error b.loc
        (Printf.sprintf "function parameter `%s` shadows an existing name" b.name))
    else None
  ) bindings

let check_name_shadowing (m : module_form) : validation_error list =
  let decls = m.decls in
  let seed_names =
    List.fold_left push_unique_name []
      ("gdp" :: (local_function_names decls @ imported_plain_exposed_names m))
    |> List.rev
  in
  let errors = ref [] in
  List.iter (function
    | DFunc fd ->
      let param_names =
        List.fold_right (fun (b : binding) acc ->
          if b.name = "_" then acc else b.name :: acc
        ) fd.params []
      in
      let seen = param_names @ seed_names in
      errors := duplicate_parameter_errors fd.params @ !errors;
      errors := parameter_shadow_errors seed_names fd.params @ !errors;
      errors := check_name_shadowing_expr seen fd.body @ !errors;
      errors := check_exists_witness_shadowing [] fd.body @ !errors
    | DConst c ->
      (* C7 (2026-07-05 fresh review): §7.4 no-shadowing is PROGRAM-WIDE, but the
         RHS of a top-level value binding (`name = expr`) was never traversed —
         it fell into the `_ -> ()` arm below — so a `let`/`case`/lambda binder in
         a top-level const could shadow top-level names, sibling binders, and even
         `check`/`auth`/`establish` function names (e.g. `bar = (fn(foo: Int) -> …)`
         with a top-level `foo`).  Traverse the const RHS with the same seed as a
         function body so the invariant holds for every binder in the program. *)
      errors := check_name_shadowing_expr seed_names c.value @ !errors;
      errors := check_exists_witness_shadowing [] c.value @ !errors
    | DTest tf ->
      errors := check_name_shadowing_test_stmts seed_names tf.stmts @ !errors
    | DApiTest atf ->
      errors := List.concat_map (check_name_shadowing_expr seed_names) atf.seed_stmts @ !errors;
      errors := check_name_shadowing_test_stmts seed_names atf.stmts @ !errors
    | DLoadTest ltf ->
      errors := List.concat_map (check_name_shadowing_expr seed_names) ltf.seed_stmts @ !errors;
      errors := check_name_shadowing_test_stmts seed_names ltf.request_stmts @ !errors
    | _ -> ()
  ) decls;
  List.rev !errors

(** A `check` or `auth` function MUST declare a proof in its return type.

    Writing `check f(n: Int) -> n: Int` (no `:::`) is a silent footgun: the
    compiler accepts `ok n ::: IsPositive n` in the body, but the proof is
    invisible to callers because it was never promised in the return spec.
    Callers cannot use what was never contracted. *)
let check_check_fn_has_proof_return (decls : top_decl list) : validation_error list =
  List.filter_map (function
    | DFunc fd when fd.kind = CheckKind || fd.kind = AuthKind ->
      let has_proof = match fd.return_spec with
        | RetAttached    { binding; _ } -> binding.proof_ann <> None
        | RetMaybeAttached { binding; _ } -> binding.proof_ann <> None
        | RetForAll _
        | RetMaybeForAll _
        | RetSetForAll _
        | RetMaybeSetForAll _
        | RetForAllDictValues _
        | RetForAllDictKeys _ -> true
        | RetExists _ -> true
        | RetNamedPack _ -> true
        | RetPlain _ -> false
      in
      if has_proof then None
      else
        let kind = match fd.kind with CheckKind -> "check" | _ -> "auth" in
        let example_binding =
          match fd.return_spec with
          | RetAttached { binding; _ } ->
            Printf.sprintf "-> %s: <Type> ::: <Predicate> %s" binding.name binding.name
          | _ ->
            "-> result: <Type> ::: <Predicate> result"
        in
        Some (make_error fd.loc
          ~hint:(Printf.sprintf "add a proof to the return type: `%s`" example_binding)
          (Printf.sprintf
            "`%s` function `%s` has no proof in its return type — \
             callers cannot use any proof produced in the body; \
             a `%s` function without `:::` in its return type is always a bug"
            kind fd.name kind))
    | _ -> None
  ) decls


(* ── Duplicate top-level names ──────────────────────────────────────────── *)

let check_duplicate_top_level_names (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  (* Separate namespaces: functions and types/records/entities can share names with codecs *)
  let seen_funcs : (string * loc) list ref = ref [] in
  let seen_types : (string * loc) list ref = ref [] in
  let seen_facts : (string * loc) list ref = ref [] in
  (* A codec is keyed by the type it serialises; two codecs for the same type
     emit colliding `tesl-codec-encode-<T>` defines (a `raco` error, not a Tesl
     diagnostic). Reject the second codec at the frontend. *)
  let seen_codecs : (string * loc) list ref = ref [] in
  let check seen name loc kind =
    match List.assoc_opt name !seen with
    | Some first_loc ->
      errors := make_error loc
        ~hint:(Printf.sprintf "first definition of `%s` is at line %d" name (first_loc.start.line + 1))
        (Printf.sprintf "duplicate %s `%s`" kind name)
        :: !errors
    | None -> seen := (name, loc) :: !seen
  in
  List.iter (function
    | DFunc fd -> check seen_funcs fd.name fd.loc "function"
    | DType (TypeNewtype { name; loc; _ }) -> check seen_types name loc "type"
    | DType (TypeAlias { name; loc; _ }) -> check seen_types name loc "type"
    | DType (TypeAdt { name; loc; _ }) -> check seen_types name loc "type"
    | DRecord rf -> check seen_types rf.name rf.loc "record"
    | DEntity ef -> check seen_types ef.name ef.loc "entity"
    | DFact ff -> check seen_facts ff.name ff.loc "fact"
    | DCodec cf -> check seen_codecs cf.type_name cf.loc "codec for type"
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── Reserved framework-predicate names (2026-07-03 hole #8) ─────────────────
   The provenance / quantifier predicates (FromDb, FromQueue, FromDeadQueue,
   ForAll, MaybeForAll, ForAllValues, ForAllKeys, Exists, Id) are minted ONLY by
   the framework — the SQL layer (FromDb/Id), the queue layer (FromQueue/
   FromDeadQueue), and the `?`/`ForAll` return-spec machinery.  Their soundness
   depends on that exclusivity: a value carrying `FromDb (Id == x)` is trusted to
   have actually come from the DB by that key.  A user `fact FromDb (…)`
   re-declared the name and let a check/auth/establish MINT it from thin air onto
   a fabricated value, forging DB provenance.  The reservation was previously
   enforced only in the emitter (runtime-name registration), never at
   declaration, so the checker accepted the re-declaration.  Reserve the names
   here, at the single point every fact declaration passes through. *)
let check_reserved_predicate_names (decls : top_decl list) : validation_error list =
  List.filter_map (function
    | DFact ff when Type_system.is_framework_predicate ff.name ->
      Some (make_error ff.loc
        ~hint:(Printf.sprintf
          "`%s` is a built-in framework predicate; pick a different name for your own \
           fact (e.g. `%sChecked`)" ff.name ff.name)
        (Printf.sprintf
          "`fact %s` re-declares the reserved framework predicate `%s`; provenance and \
           quantifier predicates (FromDb, FromQueue, FromDeadQueue, ForAll, Exists, Id, …) \
           are minted only by the framework and may not be user-defined — allowing it would \
           let their provenance guarantee be forged"
          ff.name ff.name))
    | _ -> None
  ) decls

(* ── Duplicate ADT constructors within a single ADT ────────────────────── *)

let check_duplicate_adt_constructors (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  let seen_global : (string, string * loc) Hashtbl.t = Hashtbl.create 16 in
  List.iter (function
    | DType (TypeAdt { name; variants; _ }) ->
      let seen_local = Hashtbl.create 8 in
      List.iter (fun (v : adt_variant) ->
        if Hashtbl.mem seen_local v.ctor then
          errors := make_error v.loc
            ~hint:(Printf.sprintf "each constructor in type `%s` must be unique" name)
            (Printf.sprintf "duplicate constructor `%s` in type `%s`" v.ctor name)
            :: !errors
        else begin
          Hashtbl.replace seen_local v.ctor v.loc;
          match Hashtbl.find_opt seen_global v.ctor with
          | Some (first_type, first_loc) when first_type <> name ->
            errors := make_error v.loc
              ~hint:(Printf.sprintf "constructor `%s` was already declared in type `%s` at line %d; constructors must be globally unique" v.ctor first_type (first_loc.start.line + 1))
              (Printf.sprintf "duplicate constructor `%s` across types `%s` and `%s`" v.ctor first_type name)
              :: !errors
          | _ ->
            Hashtbl.replace seen_global v.ctor (name, v.loc)
        end
      ) variants
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── Duplicate record/entity field names within a single declaration ─────── *)

let check_duplicate_decl_fields (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  let check_fields decl_kind decl_name (fields : field_def list) =
    let seen : (string, loc) Hashtbl.t = Hashtbl.create 8 in
    List.iter (fun (f : field_def) ->
      match Hashtbl.find_opt seen f.name with
      | Some first_loc ->
        errors := make_error f.loc
          ~hint:(Printf.sprintf "first field `%s` is at line %d; each field in %s `%s` must be unique" f.name (first_loc.start.line + 1) decl_kind decl_name)
          (Printf.sprintf "duplicate field `%s` in %s `%s`" f.name decl_kind decl_name)
          :: !errors
      | None ->
        Hashtbl.replace seen f.name f.loc
    ) fields
  in
  List.iter (function
    | DRecord r -> check_fields "record" r.name r.fields
    | DEntity e -> check_fields "entity" e.name e.fields
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── Self-import detection ──────────────────────────────────────────────── *)

let check_self_imports (module_name : string) (imports : import_decl list) : validation_error list =
  let errors = ref [] in
  List.iter (fun (imp : import_decl) ->
    if imp.module_name = module_name then
      errors := make_error imp.loc
        ~hint:"remove the self-import"
        (Printf.sprintf "module `%s` imports itself" module_name)
        :: !errors
  ) imports;
  List.rev !errors

let has_dotdot_suffix (name : string) =
  let len = String.length name in
  len > 4 && String.sub name (len - 4) 4 = "(..)"

let strip_dotdot_suffix (name : string) =
  if has_dotdot_suffix name then
    String.sub name 0 (String.length name - 4)
  else
    name

let check_imported_exposed_name_conflicts (m : module_form) : validation_error list =
  let errors = ref [] in
  let seen_imports : (string, string * loc) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (name, module_name, loc) ->
    match Hashtbl.find_opt seen_imports name with
    | Some (first_module, _) when first_module <> module_name ->
      errors := make_error loc
        ~hint:(Printf.sprintf "remove one of the exposing imports for `%s`, or import one module qualified-only" name)
        (Printf.sprintf "imported name `%s` is exposed by multiple modules (`%s` and `%s`)" name first_module module_name)
        :: !errors
    | Some _ -> ()
    | None -> Hashtbl.add seen_imports name (module_name, loc)
  ) (imported_plain_exposed_name_entries m);
  List.iter (function
    | DFunc fd ->
      (match Hashtbl.find_opt seen_imports fd.name with
       | Some (module_name, _) ->
         errors := make_error fd.loc
           ~hint:(Printf.sprintf "rename `%s`, remove it from the exposing list, or switch to `import %s` for qualified access" fd.name module_name)
           (Printf.sprintf "top-level function `%s` shadows imported name from module `%s`" fd.name module_name)
           :: !errors
       | None -> ())
    | _ -> ()
  ) m.decls;
  List.rev !errors

let check_imported_exposed_type_and_ctor_conflicts (m : module_form) : validation_error list =
  let errors = ref [] in
  let seen_types : (string, string * loc) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (name, module_name, loc) ->
    match Hashtbl.find_opt seen_types name with
    | Some (first_module, _) when first_module <> module_name ->
      errors := make_error loc
        ~hint:(Printf.sprintf "remove one of the exposing imports for `%s`, or import one module qualified-only" name)
        (Printf.sprintf "imported type `%s` is exposed by multiple modules (`%s` and `%s`)" name first_module module_name)
        :: !errors
    | Some _ -> ()
    | None -> Hashtbl.add seen_types name (module_name, loc)
  ) (imported_plain_exposed_type_entries m);
  let seen_ctors : (string, string * string * loc) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (ctor_name, type_name, module_name, loc) ->
    match Hashtbl.find_opt seen_ctors ctor_name with
    | Some (first_type, first_module, _) when first_module <> module_name || first_type <> type_name ->
      errors := make_error loc
        ~hint:(Printf.sprintf "remove one of the `(..)` imports for `%s`, or import one module qualified-only" ctor_name)
        (Printf.sprintf "imported constructor `%s` is exposed by multiple modules (`%s` and `%s`)" ctor_name first_module module_name)
        :: !errors
    | Some _ -> ()
    | None -> Hashtbl.add seen_ctors ctor_name (type_name, module_name, loc)
  ) (imported_plain_exposed_ctor_entries m);
  List.iter (fun (name, loc) ->
    match Hashtbl.find_opt seen_types name with
    | Some (module_name, _) ->
      errors := make_error loc
        ~hint:(Printf.sprintf "rename `%s`, remove it from the exposing list, or switch to `import %s` for qualified access" name module_name)
        (Printf.sprintf "top-level type `%s` shadows imported type from module `%s`" name module_name)
        :: !errors
    | None -> ()
  ) (local_type_entries m.decls);
  List.iter (fun (ctor_name, owner_type, loc) ->
    match Hashtbl.find_opt seen_ctors ctor_name with
    | Some (_, module_name, _) ->
      errors := make_error loc
        ~hint:(Printf.sprintf "rename constructor `%s`, or remove the conflicting `(..)` import from `%s`" ctor_name module_name)
        (Printf.sprintf "constructor `%s` in type `%s` shadows imported constructor from module `%s`" ctor_name owner_type module_name)
        :: !errors
    | None -> ()
  ) (local_ctor_entries m.decls);
  List.rev !errors


let check_duplicate_imports (imports : import_decl list) : validation_error list =
  let errors = ref [] in
  let seen_by_module = Hashtbl.create 16 in
  let seen_tables module_name =
    match Hashtbl.find_opt seen_by_module module_name with
    | Some tables -> tables
    | None ->
      let exact = Hashtbl.create 16 in
      let plain = Hashtbl.create 16 in
      let dotdot = Hashtbl.create 16 in
      let tables = (exact, plain, dotdot) in
      Hashtbl.add seen_by_module module_name tables;
      tables
  in
  List.iter (fun (imp : import_decl) ->
    match imp.names with
    | ImportAll -> ()
    | ImportExposing names ->
      let seen_exact, seen_plain, seen_dotdot = seen_tables imp.module_name in
      List.iter (fun name ->
        if Hashtbl.mem seen_exact name then
          errors := make_error imp.loc
            ~hint:(Printf.sprintf "remove the repeated import of `%s` from `%s`" name imp.module_name)
            (Printf.sprintf "duplicate import `%s` from module `%s`" name imp.module_name)
            :: !errors
        else begin
          Hashtbl.replace seen_exact name ();
          let base = strip_dotdot_suffix name in
          if has_dotdot_suffix name then begin
            if Hashtbl.mem seen_plain base then
              errors := make_error imp.loc
                ~hint:(Printf.sprintf "keep either `%s` or `%s(..)` when importing from `%s`" base base imp.module_name)
                (Printf.sprintf "cannot import both `%s` and `%s(..)` from module `%s`" base base imp.module_name)
                :: !errors;
            Hashtbl.replace seen_dotdot base ()
          end else begin
            if Hashtbl.mem seen_dotdot base then
              errors := make_error imp.loc
                ~hint:(Printf.sprintf "keep either `%s` or `%s(..)` when importing from `%s`" base base imp.module_name)
                (Printf.sprintf "cannot import both `%s` and `%s(..)` from module `%s`" base base imp.module_name)
                :: !errors;
            Hashtbl.replace seen_plain base ()
          end
        end
      ) names
  ) imports;
  List.rev !errors

(** Check that every non-stdlib import resolves to an existing file.
    When the file doesn't exist, the compiler silently ignores the import and
    later emits confusing "unknown name: fn" type errors.  This check surfaces
    the root cause early with a clear message. *)
let check_local_imports_exist (m : module_form) : validation_error list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  List.filter_map (fun (imp : import_decl) ->
    if is_tesl_module imp.module_name then None
    else
      let kebab_path = resolve_local_import_path m.source_file imp.module_name in
      (* resolve_local_import_path prefers the kebab-case path; fall back to PascalCase *)
      let dir    = Filename.dirname m.source_file in
      let kebab  = Filename.concat dir (module_name_to_kebab imp.module_name ^ ".tesl") in
      let pascal = Filename.concat dir (imp.module_name ^ ".tesl") in
      if Sys.file_exists kebab_path then None
      else
        let hint =
          if kebab <> pascal then
            Printf.sprintf "create `%s` or `%s` in the same directory" kebab pascal
          else
            Printf.sprintf "create `%s` in the same directory" kebab
        in
        Some (make_error imp.loc ~hint
          (Printf.sprintf "module `%s` not found: looked for `%s`"
             imp.module_name kebab_path))
  ) m.imports


(** Build a map from function name → declared capabilities for all DFunc decls *)
(** Build a map of ALL user-defined function names to their declared capabilities.
    Functions with `requires []` map to an empty list.
    This is used to distinguish user-defined `fn insert` from the SQL `insert` keyword. *)
