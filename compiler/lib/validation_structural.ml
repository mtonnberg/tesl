open Ast
open Location
open Validation_common

let build_field_proof_map (decls : top_decl list) : (string * (string * proof_expr)) list =
  List.concat_map (function
    | DRecord r ->
      List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | Some p -> Some (f.name, (f.name, p))
        | None -> None
      ) r.fields
    | DEntity e ->
      List.filter_map (fun (f : field_def) ->
        match f.proof_ann with
        | Some p -> Some (f.name, (f.name, p))
        | None -> None
      ) e.fields
    | _ -> []
  ) decls

let rec carried_proofs_of_expr
    ?(funcs : (string * func_info) list = [])
    (subject_env : subject_env)
    (proof_env : proof_env)
    (expr : expr)
    : proof_expr list option =
  match expr with
  | EVar { name; _ } ->
    (* Resolve through subject_env to find the canonical subject name.
       This handles proof aliases created by ELetProof: `let (raw ::: lp && rp) = b`
       adds `subject_env["raw"] = "b"` but does NOT add `proof_env["raw"]`.
       We must follow the alias to find `proof_env["b"]`.
       IMPORTANT: always check proof_env[name] first. The subject_env alias is only a
       fallback for ELetProof where the new name has no own proofs. If a check function
       was called (e.g. `let notDoneId = checkNotDone issueId`), proof_env["notDoneId"]
       holds the established proofs and must take priority over proof_env["issueId"]. *)
    Some (match List.assoc_opt name proof_env with
          | Some proofs when proofs <> [] -> proofs
          | _ ->
            let subject = match List.assoc_opt name subject_env with Some s -> s | None -> name in
            match List.assoc_opt subject proof_env with
            | Some proofs -> proofs
            | None -> [])
  | EOk { value; proof; _ } ->
    let base = carried_proofs_of_expr ~funcs subject_env proof_env value in
    (* For the proof annotation: try to resolve establish function calls and
       detachFact references to concrete predicates. Recurse into PredAnd. *)
    let extra =
      let normalized = normalize_proof_aliases proof_env proof in
      let rec resolve_proof_ref p =
        match p with
        | PredApp { pred = "detachFact"; args = [name]; _ } ->
          let subject = match List.assoc_opt name subject_env with Some s -> s | None -> name in
          (match List.assoc_opt name proof_env with
           | Some proofs when proofs <> [] -> proofs
           | _ ->
             (match List.assoc_opt subject proof_env with
              | Some proofs -> proofs
              | None -> [p]))
        | PredApp { pred; args; _ } when funcs <> [] ->
          (match List.assoc_opt pred funcs with
           | Some info when info.fi_kind = EstablishKind ->
             let param_mapping = List.filter_map (fun ((param : binding), arg) ->
               let subject = match List.assoc_opt arg subject_env with
                 | Some s -> s | None -> arg
               in
               Some (param.name, subject)
             ) (zip_prefix info.fi_params args) in
             let preds = proofs_of_return_spec "_" ~param_mapping info.fi_return in
             if preds = [] then [p] else preds
           | _ -> [p])
        | PredApp { pred; args = []; _ } when
            String.length pred > 0 && pred.[0] >= 'a' && pred.[0] <= 'z' ->
          (* Proof variable reference (e.g. from let (_ ::: p) = ...):
             resolve through proof_env to find what it actually proves. *)
          (match List.assoc_opt pred proof_env with
           | Some proofs when proofs <> [] -> proofs
           | _ ->
             (* Also try subject_env alias *)
             let subject = match List.assoc_opt pred subject_env with Some s -> s | None -> pred in
             (match List.assoc_opt subject proof_env with
              | Some proofs when proofs <> [] -> proofs
              | _ -> [p]))
        | PredApp _ -> [p]
        | PredAnd { left; right; _ } ->
          resolve_proof_ref left @ resolve_proof_ref right
      in
      resolve_proof_ref normalized
    in
    (match base with
     | Some proofs -> Some (proofs @ extra)
     | None -> Some extra)
  | EApp _ ->
    let (head, args) = collect_call_head_and_args [] expr in
    (match function_name_of_expr head, args with
     | Some "attachFact", [value; evidence] ->
       let base = carried_proofs_of_expr ~funcs subject_env proof_env value in
       let extra = proofs_of_evidence_expr ~funcs subject_env proof_env evidence in
       (match base, extra with
        | Some left, Some right -> Some (left @ right)
        | Some left, None -> Some left
        | None, Some right -> Some right
        | None, None -> None)
     | Some "forgetFact", [_] -> Some []
     | Some "detachFact", [value] -> carried_proofs_of_expr ~funcs subject_env proof_env value
     (* Proof conjunction operations: return the combined proofs of their inputs *)
     | Some "introAnd", pf_args ->
       (* introAnd pf1 pf2 ... → carries all proofs from all arguments.
          Try carried_proofs first (for named Fact variables), then fall back
          to proofs_of_evidence_expr to handle inline establish calls like
          `introAnd (proveA x) (proveB x)` where the arguments are EApp nodes. *)
       let all = List.filter_map (fun arg ->
         match carried_proofs_of_expr ~funcs subject_env proof_env arg with
         | Some proofs when proofs <> [] -> Some proofs
         | _ -> proofs_of_evidence_expr ~funcs subject_env proof_env arg
       ) pf_args in
       Some (List.concat all)
     | Some ("andLeft" | "andRight"), [pf] ->
       (* andLeft/andRight: conservative — carries same proofs as input
          (static analysis doesn't know the structural split) *)
       carried_proofs_of_expr ~funcs subject_env proof_env pf
     | _ -> None)
  | EField { obj; field; _ } ->
    (* When a proof-annotated record field is accessed, propagate the field's
       declared proof with its subject substituted to the actual object subject. *)
    (match List.assoc_opt field !field_proof_registry with
     | None -> None
     | Some (param_name, proof) ->
       let obj_subj = match subject_of_expr subject_env obj with
         | Some s -> s
         | None -> field
       in
       Some [subst_proof [(param_name, obj_subj)] proof])
  | _ -> None

let proofs_of_expr
    (result_name : string)
    (funcs : (string * func_info) list)
    (subject_env : subject_env)
    (proof_env : proof_env)
    (expr : expr)
    : proof_expr list =
  let direct =
    match expr with
    | EVar _ | EField _ -> carried_proofs_of_expr ~funcs subject_env proof_env expr
    | EOk _ ->
      (* Handled after proofs_of_call_head is defined below, so we can merge
         sidecar proofs (from carried_proofs_of_expr) with check-call proofs. *)
      None
    | EApp _ ->
      let (head, _) = collect_call_head_and_args [] expr in
      (match function_name_of_expr head with
       | Some ("attachFact" | "forgetFact" | "detachFact"
              | "introAnd" | "andLeft" | "andRight") ->
         carried_proofs_of_expr ~funcs subject_env proof_env expr
       | _ -> None)
    | _ -> None
  in
  match direct with
  | Some proofs -> proofs
  | None ->
    let (head, args) = collect_call_head_and_args [] expr in
    let rec proofs_of_call_head head args =
      match function_name_of_expr head with
      | Some "check" ->
        (* `check f arg` is syntactic sugar for a proof-carrying call to f.
           Treat the first argument as the actual function and recurse. *)
        (match args with
         | fn_expr :: rest -> proofs_of_call_head fn_expr rest
         | [] -> [])
      | Some fn_name ->
        (match List.assoc_opt fn_name funcs with
         | Some info ->
           let param_mapping = List.filter_map (fun ((param : binding), arg) ->
             match subject_of_expr subject_env arg with
             | Some subject -> Some (param.name, subject)
             | None -> None
           ) (zip_prefix info.fi_params args) in
           let return_proofs = proofs_of_return_spec result_name ~param_mapping info.fi_return in
           (* For CheckKind functions: also carry forward existing proofs from the subject arg.
              E.g. `let y = check isB x` where x already has [IsA]: y should have [IsA, IsB]. *)
           let carried_subject_proofs =
             if info.fi_kind = CheckKind then
               let subj_param_name = match info.fi_return with
                 | RetAttached { binding; _ } -> Some binding.name
                 | _ -> None
               in
               (match subj_param_name with
                | Some spn ->
                  let idx = ref (-1) in
                  List.iteri (fun i (p : binding) -> if p.name = spn && !idx < 0 then idx := i) info.fi_params;
                  let subj_arg = match !idx with
                    | i when i >= 0 -> List.nth_opt args i
                    | _ -> List.nth_opt args 0
                  in
                  (match subj_arg with
                   | None -> []
                   | Some arg ->
                     match carried_proofs_of_expr ~funcs subject_env proof_env arg with
                     | Some proofs -> proofs
                     | None ->
                       let name = match arg with EVar { name; _ } -> name | _ -> "" in
                       let subj = match List.assoc_opt name subject_env with Some s -> s | None -> name in
                       (match List.assoc_opt subj proof_env with
                        | Some ps -> ps
                        | None -> (match List.assoc_opt name proof_env with Some ps -> ps | None -> [])))
                | None -> [])
             else []
           in
           (* Merge carried (old proofs) + return_proofs (new proofs), deduplicating by proof_key *)
           let seen_keys = ref [] in
           List.filter (fun p ->
             let k = proof_key p in
             if List.mem k !seen_keys then false
             else (seen_keys := k :: !seen_keys; true)
           ) (carried_subject_proofs @ return_proofs)
         | None ->
           (* BUG-2 fix: handle `List.filterCheck (checkA && checkB) xs`.
              Build a SINGLE combined ForAll proof for the chain so that
              `ForAll (PA && PB) result` matches the declared return type. *)
           let is_filtercheck_head h = match h with
             | EField { obj = EConstructor { name = "List"; _ }; field = "filterCheck"; _ }
             | EVar { name = "List.filterCheck"; _ }
             | EField { obj = EConstructor { name = "Set"; _ }; field = "filterCheck"; _ }
             | EVar { name = "Set.filterCheck"; _ }
             | EField { obj = EConstructor { name = "List"; _ }; field = "allCheck"; _ }
             | EVar { name = "List.allCheck"; _ }
             | EField { obj = EConstructor { name = "Set"; _ }; field = "allCheck"; _ }
             | EVar { name = "Set.allCheck"; _ }
             | EField { obj = EConstructor { name = "List"; _ }; field = "emptyForAll"; _ }
             | EVar { name = "List.emptyForAll"; _ } -> true
             | _ -> false
           in
           (* Returns the predicate string for ForAll, including literal args but
              stripping the binder/element arg (always the last positional arg).
              E.g. "IsPositive n" → "IsPositive", "HasMin 10 n" → "HasMin 10",
              "IsPositive && IsSmall" → "IsPositive && IsSmall". *)
           let pred_str_drop_last_arg pred args =
             match List.rev args with
             | _ :: rest -> (* last arg is the element subject; keep the literals *)
               let kept = List.rev rest in
               if kept = [] then pred
               else pred ^ " " ^ String.concat " " kept
             | [] -> pred
           in
           let rec pred_str_from_check_chain e = match e with
             | EVar { name = check_fn; _ } ->
               (match List.assoc_opt check_fn funcs with
                | Some info ->
                  (match info.fi_return with
                   | RetAttached { binding = { proof_ann = Some (PredApp { pred; args; _ }); _ }; _ } ->
                     Some (pred_str_drop_last_arg pred args)
                   | RetAttached { binding = { proof_ann = Some p; _ }; _ } ->
                     Some (pp_proof p)
                   | _ -> None)
                | None -> None)
             | EBinop { op = BAnd; left; right; _ } ->
               (match pred_str_from_check_chain left, pred_str_from_check_chain right with
                | Some lp, Some rp -> Some (lp ^ " && " ^ rp)
                | Some p, None | None, Some p -> Some p
                | None, None -> None)
             | _ -> None
           in
           (match head, args with
           | h, (check_fn_expr :: input_expr :: _) when is_filtercheck_head h ->
             (match pred_str_from_check_chain check_fn_expr with
              | Some new_pred_str ->
                (* Merge any prior ForAll predicates from the input list so that
                   sequential filterChecks accumulate: filterCheck checkSmall (filterCheck checkPos xs)
                   produces ForAll (IsPositive && IsSmall) rather than just ForAll (IsSmall). *)
                let prior_preds =
                  match carried_proofs_of_expr ~funcs subject_env proof_env input_expr with
                  | Some proofs ->
                    List.filter_map (fun p ->
                      match p with
                      | PredApp { pred = "ForAll"; args = (inner :: _); _ } -> Some inner
                      | _ -> None
                    ) proofs
                  | None -> []
                in
                let combined_pred_str =
                  List.fold_left (fun acc prior -> prior ^ " && " ^ acc) new_pred_str prior_preds
                in
                [PredApp { pred = "ForAll"; args = [combined_pred_str; result_name]; loc = gen_loc }]
              | None -> [])
           | h, (check_fn_expr :: _) when is_filtercheck_head h ->
             (match pred_str_from_check_chain check_fn_expr with
              | Some pred_str ->
                [PredApp { pred = "ForAll"; args = [pred_str; result_name]; loc = gen_loc }]
              | None -> [])
           | _ -> []))
      | None ->
        match head with
        | EBinop { op = BAnd; _ } ->
          flatten_check_chain_expr [] head
          |> List.concat_map (fun check_head -> proofs_of_call_head check_head args)
        | _ -> []
    in
    let call_proofs = proofs_of_call_head head args in
    (* For `EOk { value = expr; proof = proof_var }` (i.e. `expr ::: proof_var`):
       combine the check-call proofs from `value` with the sidecar proof.
       Without this, `check f n ::: p` in return position only carries `p`,
       losing the check function's own proofs (e.g. IsPositive, IsSmall). *)
    match expr with
    | EOk { value; _ } ->
      let sidecar = match carried_proofs_of_expr ~funcs subject_env proof_env expr with
        | Some ps -> ps
        | None -> []
      in
      let from_value =
        let (vhead, vargs) = collect_call_head_and_args [] value in
        proofs_of_call_head vhead vargs
      in
      let all = sidecar @ from_value in
      (* Deduplicate *)
      let seen = ref [] in
      List.filter (fun p ->
        let k = proof_key p in
        if List.mem k !seen then false
        else (seen := k :: !seen; true)
      ) all
    | _ -> call_proofs

(* ── 1. Server binding completeness ──────────────────────────────────────── *)

let is_synthetic_endpoint_name (name : string) : bool =
  let prefix = "endpoint_" in
  let prefix_len = String.length prefix in
  String.length name > prefix_len
  && String.sub name 0 prefix_len = prefix
  && let suffix = String.sub name prefix_len (String.length name - prefix_len) in
     String.length suffix > 0
     && String.for_all (fun ch -> ch >= '0' && ch <= '9') suffix

let take n xs =
  let rec go acc remaining count =
    if count <= 0 then List.rev acc else
    match remaining with
    | [] -> List.rev acc
    | x :: rest -> go (x :: acc) rest (count - 1)
  in
  go [] xs n

let drop n xs =
  let rec go remaining count =
    if count <= 0 then remaining else
    match remaining with
    | [] -> []
    | _ :: rest -> go rest (count - 1)
  in
  go xs n

type handler_decl_ref =
  | LocalHandler of func_decl
  | ImportedHandler of func_info

(** Extract the proof-predicate name from an auth function's return spec.
    Auth functions return `-> name: T ::: PredName name`, so the predicate
    is in the RetAttached binding's proof_ann. *)
let auth_proof_pred_of_return_spec spec =
  match spec with
  | RetAttached { binding; _ } ->
    (match binding.proof_ann with
     | Some (PredApp { pred; _ }) -> Some pred
     | _ -> None)
  | _ -> None

(** Build the set of proof-predicate names produced by all auth functions
    reachable from [decls] and [extra_funcs]. *)
let collect_auth_predicates decls extra_funcs =
  let from_decls =
    List.filter_map (function
      | DFunc fd when fd.kind = AuthKind ->
        auth_proof_pred_of_return_spec fd.return_spec
      | _ -> None
    ) decls
  in
  let from_imports =
    List.filter_map (fun (_, info : string * func_info) ->
      if info.fi_kind = AuthKind then
        auth_proof_pred_of_return_spec info.fi_return
      else None
    ) extra_funcs
  in
  from_decls @ from_imports

(** Return true if any param in [params] carries a proof annotation whose
    predicate name is in [auth_preds].  Handles conjunction proofs (PredAnd)
    by recursively checking all leaf predicates. *)
let has_auth_proof_param auth_preds params =
  let rec proof_mentions_auth = function
    | PredApp { pred; _ } -> List.mem pred auth_preds
    | PredAnd { left; right; _ } -> proof_mentions_auth left || proof_mentions_auth right
  in
  List.exists (fun (b : binding) ->
    match b.proof_ann with
    | Some p -> proof_mentions_auth p
    | None -> false
  ) params

(** Extract `:param` names from an endpoint path string. *)
let path_param_names (path : string) : string list =
  String.split_on_char '/' path
  |> List.filter_map (fun segment ->
       if String.length segment > 1 && segment.[0] = ':' then
         Some (String.sub segment 1 (String.length segment - 1))
       else None)

let check_api_endpoint_structure (decls : top_decl list) : validation_error list =
  let method_str = function
    | GET -> "get" | POST -> "post" | PUT -> "put"
    | DELETE -> "delete" | PATCH -> "patch" | SSE -> "sse"
  in
  List.concat_map (function
    | DApi af ->
      let seen_method_paths : (string * loc) list ref = ref [] in
      List.concat_map (fun (ep : api_endpoint) ->
        let errors = ref [] in
        let add_hint hint msg = errors := make_error ep.loc ~hint msg :: !errors in
        let ep_id = Printf.sprintf "`%s \"%s\"`" (method_str ep.method_) ep.path in

        (* Clause(s) appeared after `->` — they were silently ignored by the parser *)
        if ep.has_clause_after_return then
          add_hint
            "move all `auth`, `body`, `capture`, `response`, and `subscribe` \
             clauses to before the `->` return type"
            (Printf.sprintf
              "endpoint %s: endpoint clauses (auth/body/capture/response) \
               must come before the `->` return type, not after"
              ep_id);

        (* Missing `->` return type (SSE endpoints are exempt: they stream events, no response type) *)
        if not ep.has_explicit_return && ep.method_ <> SSE then
          add_hint
            "add `-> ReturnType` at the end of the endpoint, \
             e.g. `-> String` or `-> MyResponseRecord`"
            (Printf.sprintf
              "endpoint %s: missing return type — every endpoint must have \
               an explicit `-> TypeName`"
              ep_id);

        (* Empty path *)
        if ep.path = "" then
          add_hint "use a non-empty path string, e.g. `\"/health\"`"
            (Printf.sprintf
              "api `%s`: endpoint has an empty path; paths must not be empty"
              af.name);

        (* Path without leading slash *)
        if ep.path <> "" && ep.path.[0] <> '/' then
          add_hint
            (Printf.sprintf "change `\"%s\"` to `\"/%s\"`" ep.path ep.path)
            (Printf.sprintf
              "endpoint %s: path must start with `/`" ep_id);

        (* Auth binding must have a proof annotation *)
        (match ep.auth with
         | Some a when a.binding.proof_ann = None ->
           let ty_name = match a.binding.type_expr with
             | TName { name; _ } -> name | _ -> "T" in
           add_hint
             (Printf.sprintf
               "add a proof annotation, e.g. `auth %s : %s ::: ProofPred %s via %s`"
               a.binding.name ty_name a.binding.name a.via_fn)
             (Printf.sprintf
               "endpoint %s: auth binding `%s` must have a proof annotation \
                (`::: ProofPred %s`); without it the handler cannot receive \
                a verified identity"
               ep_id a.binding.name a.binding.name)
         | _ -> ());

        (* Capture names must match path parameters *)
        let path_params = path_param_names ep.path in
        List.iter (fun (c : api_capture) ->
          if not (List.mem c.binding.name path_params) then
            add_hint
              (Printf.sprintf
                "path is `\"%s\"`; available path parameters: %s"
                ep.path
                (if path_params = [] then "(none)"
                 else String.concat ", " (List.map (fun p -> ":"^p) path_params)))
              (Printf.sprintf
                "endpoint %s: capture clause for `%s` does not match any \
                 path parameter (`:param`) in the path"
                ep_id c.binding.name)
        ) ep.captures;

        (* Duplicate capture clauses for the same parameter *)
        let seen_captures : (string * loc) list ref = ref [] in
        List.iter (fun (c : api_capture) ->
          match List.assoc_opt c.binding.name !seen_captures with
          | Some first_loc ->
            errors := make_error c.binding.loc
              ~hint:(Printf.sprintf
                "first `capture %s` is at line %d; remove the duplicate"
                c.binding.name (first_loc.start.line + 1))
              (Printf.sprintf
                "endpoint %s: duplicate capture clause for `%s`"
                ep_id c.binding.name)
              :: !errors
          | None -> seen_captures := (c.binding.name, c.binding.loc) :: !seen_captures
        ) ep.captures;

        (* Duplicate endpoints: same HTTP method + path within this api block *)
        let mstr = String.uppercase_ascii (method_str ep.method_) in
        let key = mstr ^ " " ^ ep.path in
        (match List.assoc_opt key !seen_method_paths with
         | Some first_loc ->
           errors := make_error ep.loc
             ~hint:(Printf.sprintf "first declaration is at line %d" (first_loc.start.line + 1))
             (Printf.sprintf
               "api `%s`: duplicate endpoint %s"
               af.name ep_id)
             :: !errors
         | None ->
           seen_method_paths := (key, ep.loc) :: !seen_method_paths);

        List.rev !errors
      ) af.endpoints
    | _ -> []
  ) decls

(* ── Queue / channel / workers / database / api-test structure checks ─────── *)

let check_entity_structure (decls : top_decl list) : validation_error list =
  List.concat_map (function
    | DEntity e ->
      let errs = ref [] in
      let add hint msg = errs := make_error e.loc ~hint msg :: !errs in
      if e.table = "" then
        add "add a table name: `entity Foo table \"my_table\" ...`"
          (Printf.sprintf "entity `%s` has an empty table name" e.name);
      let field_names = List.map (fun (f : field_def) -> f.name) e.fields in
      if e.primary_key <> "" && not (List.mem e.primary_key field_names) then
        add (Printf.sprintf
          "declare `%s` as a field of entity `%s`, e.g. `%s: Int`"
          e.primary_key e.name e.primary_key)
          (Printf.sprintf
            "entity `%s` declares `%s` as its primary key but has no field named `%s`"
            e.name e.primary_key e.primary_key);
      List.rev !errs
    | _ -> []
  ) decls

let check_queue_structure (decls : top_decl list) : validation_error list =
  let known_dbs =
    List.filter_map (function DDatabase db -> Some db.name | _ -> None) decls
  in
  List.concat_map (function
    | DQueue q ->
      let errs = ref [] in
      let add hint msg = errs := make_error q.loc ~hint msg :: !errs in
      if q.database = "" then
        add "add `database MyDB` inside the queue block"
          (Printf.sprintf "queue `%s` is missing a `database` clause" q.name)
      else if not (List.mem q.database known_dbs) then
        add (Printf.sprintf "declare `database %s { ... }` in this module" q.database)
          (Printf.sprintf
            "queue `%s` references unknown database `%s`" q.name q.database);
      if q.jobs = [] then
        add "add `jobs [JobType]` listing the record types that can be enqueued"
          (Printf.sprintf "queue `%s` has no job types; at least one `jobs [JobType]` entry is required" q.name);
      List.rev !errs
    | _ -> []
  ) decls

let check_channel_structure (decls : top_decl list) : validation_error list =
  let known_dbs =
    List.filter_map (function DDatabase db -> Some db.name | _ -> None) decls
  in
  List.concat_map (function
    | DChannel ch ->
      let errs = ref [] in
      if ch.database = "" then
        errs := make_error ch.loc
          ~hint:"add `database MyDB` inside the channel block"
          (Printf.sprintf "channel `%s` is missing a `database` clause" ch.name)
          :: !errs
      else if not (List.mem ch.database known_dbs) then
        errs := make_error ch.loc
          ~hint:(Printf.sprintf "declare `database %s { ... }` in this module" ch.database)
          (Printf.sprintf
            "channel `%s` references unknown database `%s`" ch.name ch.database)
          :: !errs;
      List.rev !errs
    | _ -> []
  ) decls

let check_workers_structure ?(extra_funcs = []) (decls : top_decl list) : validation_error list =
  let queues =
    List.filter_map (function DQueue q -> Some q.name | _ -> None) decls
  in
  let worker_fns =
    let local =
      List.filter_map (function
        | DFunc fd when fd.kind = WorkerKind || fd.kind = DeadWorkerKind -> Some fd.name
        | _ -> None
      ) decls
    in
    let imported =
      List.filter_map (fun (name, info) ->
        if info.fi_kind = WorkerKind || info.fi_kind = DeadWorkerKind then Some name else None
      ) extra_funcs
    in
    local @ imported
  in
  List.concat_map (function
    | DWorkers w ->
      let errs = ref [] in
      let add hint msg = errs := make_error w.loc ~hint msg :: !errs in
      (* Undefined queue reference *)
      if not (List.mem w.queue_name queues) then
        add (Printf.sprintf "declare `queue %s { database MyDB jobs [JobType] }`" w.queue_name)
          (Printf.sprintf "workers `%s` references unknown queue `%s`" w.name w.queue_name);
      (* Empty bindings *)
      if w.bindings = [] then
        add "add `JobType = workerFnName` bindings"
          (Printf.sprintf "workers `%s` has no job bindings; at least one `JobType = workerFn` entry is required" w.name);
      (* Undefined or wrong-kind worker functions *)
      List.iter (fun (job_type, fn_name) ->
        if not (List.mem fn_name worker_fns) then
          add (Printf.sprintf "declare `worker %s(...) -> ...`" fn_name)
            (Printf.sprintf "workers `%s`: `%s` for job type `%s` is not declared as a `worker` function"
               w.name fn_name job_type)
      ) w.bindings;
      List.rev !errs
    | _ -> []
  ) decls

let load_imported_entity_names (m : module_form) : string list =
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
          let exported = List.filter_map (function
            | ExportName n | ExportAdt n -> Some n
          ) imported.exports in
          let requested = match imp.names with
            | ImportAll -> None
            | ImportExposing names ->
              let strip s =
                let n = String.length s in
                if n > 4 && String.sub s (n-4) 4 = "(..)" then String.sub s 0 (n-4) else s
              in
              Some (List.map strip names)
          in
          List.filter_map (function
            | DEntity e when List.mem e.name exported ->
              (match requested with
               | None -> Some e.name
               | Some req -> if List.mem e.name req then Some e.name else None)
            | _ -> None
          ) imported.decls
  ) m.imports

let check_database_entities (m : module_form) : validation_error list =
  let decls = m.decls in
  let local_entities =
    List.filter_map (function DEntity e -> Some e.name | _ -> None) decls
  in
  let imported_entities = load_imported_entity_names m in
  let known_entities = local_entities @ imported_entities in
  List.concat_map (function
    | DDatabase db ->
      List.filter_map (fun ent_name ->
        if not (List.mem ent_name known_entities) then
          Some (make_error db.loc
            ~hint:(Printf.sprintf
              "declare or import `entity %s table \"...\" primaryKey id { ... }`" ent_name)
            (Printf.sprintf "database `%s` references unknown entity `%s`" db.name ent_name))
        else None
      ) db.entities
    | _ -> []
  ) decls

let load_imported_server_names (m : module_form) : string list =
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
          let exported = List.filter_map (function
            | ExportName n | ExportAdt n -> Some n
          ) imported.exports in
          let requested = match imp.names with
            | ImportAll -> None
            | ImportExposing names -> Some (List.map (fun s ->
                let n = String.length s in
                if n > 4 && String.sub s (n-4) 4 = "(..)" then String.sub s 0 (n-4) else s
              ) names)
          in
          List.filter_map (function
            | DServer sv when List.mem sv.name exported ->
              (match requested with
               | None -> Some sv.name
               | Some req -> if List.mem sv.name req then Some sv.name else None)
            | _ -> None
          ) imported.decls
  ) m.imports

let check_api_test_structure (m : module_form) : validation_error list =
  let decls = m.decls in
  let local_servers =
    List.filter_map (function DServer sv -> Some sv.name | _ -> None) decls
  in
  let imported_servers = load_imported_server_names m in
  let known_servers = local_servers @ imported_servers in
  List.concat_map (function
    | DApiTest at ->
      let errs = ref [] in
      if at.description = "" then
        errs := make_error at.loc
          ~hint:"add a descriptive string, e.g. `api-test \"user can log in\" for MyServer { ... }`"
          (Printf.sprintf
            "api-test for server `%s` has an empty description string" at.server_name)
          :: !errs;
      if not (List.mem at.server_name known_servers) then
        errs := make_error at.loc
          ~hint:(Printf.sprintf
            "declare `server %s for ApiName { ... }` or import it" at.server_name)
          (Printf.sprintf "api-test `%s` references unknown server `%s`" at.description at.server_name)
          :: !errs;
      List.rev !errs
    | _ -> []
  ) decls

let check_test_descriptions (decls : top_decl list) : validation_error list =
  List.filter_map (function
    | DTest t when t.description = "" ->
      Some (make_error t.loc
        ~hint:"add a descriptive name: `test \"what this verifies\" { ... }`"
        "test block has an empty description string")
    | _ -> None
  ) decls

let check_capture_codec_types (decls : top_decl list) : validation_error list =
  (* Build newtype-to-base-type map: UserId -> String, etc. *)
  let newtype_base : (string * string) list =
    List.filter_map (function
      | DType (TypeNewtype { name; base_type; _ }) ->
        (match type_head_name base_type with
         | Some base -> Some (name, base)
         | None -> None)
      | _ -> None
    ) decls
  in
  List.filter_map (function
    | DCapture cf ->
      (* Check that the codec is compatible with the capture's binding type.
         Newtypes are transparent: UserId (newtype of String) can use stringCodec. *)
      (match type_head_name cf.binding.type_expr with
       | None -> None  (* complex type — skip *)
       | Some binding_type ->
         (match List.assoc_opt cf.parser builtin_codec_type with
          | None -> None  (* user-defined codec — can't validate statically *)
          | Some expected_type when expected_type = binding_type -> None  (* direct match *)
          | Some expected_type ->
            (* Allow if binding_type is a newtype wrapping expected_type *)
            let is_newtype_match =
              match List.assoc_opt binding_type newtype_base with
              | Some base -> base = expected_type
              | None -> false
            in
            if is_newtype_match then None
            else
              Some (make_error cf.loc
                ~hint:(Printf.sprintf
                  "use `using %s` for `%s` captures, or change the binding type to `%s`"
                  (match List.assoc_opt binding_type
                      (List.map (fun (a,b) -> (b,a)) builtin_codec_type) with
                   | Some c -> c | None -> binding_type)
                  binding_type expected_type)
                (Printf.sprintf
                  "capture `%s`: binding type is `%s` but `%s` decodes to `%s`"
                  cf.name binding_type cf.parser expected_type))))
    | _ -> None
  ) decls

let check_server_handler_binding
    (handlers : (string * handler_decl_ref) list)
    (auth_preds : string list)
    (sv : server_form)
    (endpoint_opt : api_endpoint option)
    (endpoint_name, handler_name)
    (errors : validation_error list ref)
  =
  match List.assoc_opt handler_name handlers with
  | None ->
    errors := make_error sv.loc
      ~hint:(Printf.sprintf "declare `handler %s(...)` in this module or import it explicitly" handler_name)
      (Printf.sprintf "server '%s': handler '%s' for endpoint '%s' is not declared" sv.name handler_name endpoint_name)
      :: !errors
  | Some (LocalHandler fd) when fd.kind <> HandlerKind ->
    errors := make_error fd.loc
      ~hint:"server bindings must point at `handler` declarations"
      (Printf.sprintf "server '%s': '%s' is declared, but it is not a handler" sv.name handler_name)
      :: !errors
  | Some (ImportedHandler info) when info.fi_kind <> HandlerKind ->
    errors := make_error info.fi_loc
      ~hint:"server bindings must point at `handler` declarations"
      (Printf.sprintf "server '%s': '%s' is declared, but it is not a handler" sv.name handler_name)
      :: !errors
  | Some hdl ->
    (* Return type compatibility check: handler return type must match endpoint declaration *)
    (match endpoint_opt with
     | None -> ()
     | Some ep when ep.has_explicit_return ->
       let handler_return = match hdl with
         | LocalHandler fd -> return_value_type fd.return_spec
         | ImportedHandler info -> return_value_type info.fi_return
       in
       let endpoint_return = return_value_type ep.return_spec in
       let handler_loc = match hdl with
         | LocalHandler fd -> fd.loc
         | ImportedHandler info -> info.fi_loc
       in
       (match handler_return, endpoint_return with
        | Some h_ty, Some e_ty ->
          let h_name = type_head_name h_ty in
          let e_name = type_head_name e_ty in
          (match h_name, e_name with
           | Some h, Some e when h <> e ->
             errors := make_error handler_loc
               ~hint:(Printf.sprintf
                 "change handler `%s` return type from `%s` to `%s`, \
                  or update the endpoint declaration to `-> %s`"
                 handler_name h e h)
               (Printf.sprintf
                 "server '%s': handler '%s' returns `%s` but endpoint '%s' declares `-> %s`"
                 sv.name handler_name h endpoint_name e)
               :: !errors
           | _ -> ())
        | _ -> ())
     | _ -> ());
    (* Auth-wiring alignment check — only meaningful when auth predicates are known *)
    if auth_preds <> [] then begin
      let handler_params = match hdl with
        | LocalHandler fd -> fd.params
        | ImportedHandler info -> info.fi_params
      in
      let handler_loc = match hdl with
        | LocalHandler fd -> fd.loc
        | ImportedHandler info -> info.fi_loc
      in
      match endpoint_opt with
      | None -> ()
      | Some ep ->
        let ep_needs_auth = ep.auth <> None in
        let handler_has_auth = has_auth_proof_param auth_preds handler_params in
        if ep_needs_auth && not handler_has_auth then
          errors := make_error handler_loc
            ~hint:(Printf.sprintf
              "add an auth-proof parameter to handler '%s' \
               (e.g. `user: T ::: AuthPred user`), or remove the `auth via …` clause from endpoint '%s'"
              handler_name endpoint_name)
            (Printf.sprintf
              "server '%s': endpoint '%s' requires auth but handler '%s' has no auth-proof parameter"
              sv.name endpoint_name handler_name)
            :: !errors
        else if not ep_needs_auth && handler_has_auth then
          errors := make_error handler_loc
            ~hint:(Printf.sprintf
              "add `auth via <authFn>` to endpoint '%s', \
               or remove the auth-proof parameter from handler '%s'"
              endpoint_name handler_name)
            (Printf.sprintf
              "server '%s': handler '%s' expects an auth-proof parameter \
               but endpoint '%s' declares no `auth` clause"
              sv.name handler_name endpoint_name)
            :: !errors
    end

let check_server_completeness ?(extra_funcs = []) (decls : top_decl list) : validation_error list =
  let apis = List.filter_map (function
    | DApi api -> Some (api.name, api)
    | _ -> None
  ) decls in
  let handlers =
    List.filter_map (function
      | DFunc fd -> Some (fd.name, LocalHandler fd)
      | _ -> None
    ) decls
    @ List.map (fun (name, info) -> (name, ImportedHandler info)) extra_funcs
  in
  let auth_preds = collect_auth_predicates decls extra_funcs in
  let errors = ref [] in
  List.iter (function
    | DServer sv ->
      (match List.assoc_opt sv.api_name apis with
       | None ->
         errors := make_error sv.loc
           ~hint:(Printf.sprintf "declare `api %s { ... }` before the server or import it once cross-module servers are supported" sv.api_name)
           (Printf.sprintf "server '%s' refers to unknown api '%s'" sv.name sv.api_name)
           :: !errors
       | Some api ->
         let non_sse_eps = api.endpoints |> List.filter (fun ep -> ep.method_ <> SSE) in
         let expected = List.map (fun (ep : api_endpoint) -> ep.name) non_sse_eps in
         let bound_names = List.map fst sv.bindings in
         if List.for_all is_synthetic_endpoint_name expected then begin
           let expected_count = List.length expected in
           let bound_count = List.length sv.bindings in
           if bound_count < expected_count then
             errors := make_error sv.loc
               ~hint:(Printf.sprintf "add %d more `<endpointName> = <handlerName>` binding(s) to server '%s'" (expected_count - bound_count) sv.name)
               (Printf.sprintf "server '%s' is missing %d binding(s) for api '%s'" sv.name (expected_count - bound_count) sv.api_name)
               :: !errors;
           List.iter (fun (endpoint_name, _handler_name) ->
             errors := make_error sv.loc
               ~hint:(Printf.sprintf "api '%s' declares %d endpoint(s)" sv.api_name expected_count)
               (Printf.sprintf "server '%s' binds extra endpoint '%s'" sv.name endpoint_name)
               :: !errors
           ) (drop expected_count sv.bindings);
           List.iteri (fun i binding ->
             let ep_opt = List.nth_opt non_sse_eps i in
             check_server_handler_binding handlers auth_preds sv ep_opt binding errors
           ) (take expected_count sv.bindings)
         end else begin
           List.iter (fun endpoint_name ->
             if not (List.mem endpoint_name bound_names) then
               errors := make_error sv.loc
                 ~hint:(Printf.sprintf "add `%s = <handlerName>` to server '%s'" endpoint_name sv.name)
                 (Printf.sprintf "server '%s' is missing a binding for endpoint '%s'" sv.name endpoint_name)
                 :: !errors
           ) expected;
           List.iter (fun (endpoint_name, handler_name) ->
             if not (List.mem endpoint_name expected) then
               errors := make_error sv.loc
                 ~hint:(Printf.sprintf "valid endpoints: %s" (String.concat ", " expected))
                 (Printf.sprintf "server '%s' binds unknown endpoint '%s'" sv.name endpoint_name)
                 :: !errors;
             let ep_opt = List.find_opt (fun (ep : api_endpoint) -> ep.name = endpoint_name) non_sse_eps in
             check_server_handler_binding handlers auth_preds sv ep_opt (endpoint_name, handler_name) errors
           ) sv.bindings
         end)
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── 2. SQL/record field name validation ─────────────────────────────────── *)

