open Ast
open Location
open Validation_common

(* build_field_proof_map now lives in Validation_common (shared via module_facts). *)

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
    (* GAP-CONJPROJ: when the explicit annotation is a bare proof-VARIABLE
       reattach (`value ::: pf`, where `pf` resolves through proof_env to a
       concrete proof set), the user is explicitly stating exactly what is
       being claimed.  We must NOT silently OR in `value`'s own inherited
       proofs — otherwise a value carrying `P && Q`, reattached with only the
       wrong projected half (`bare ::: pSmall`), would still appear to carry
       both conjuncts and could masquerade as the other one.  In that case the
       annotation is authoritative and `base` is dropped.  (Composite `p && q`
       annotations and non-proof-var annotations keep the additive behaviour,
       so legitimate sidecar uses are unaffected.) *)
    let annotation_is_authoritative =
      match proof with
      | PredApp { pred; args = []; _ }
        when String.length pred > 0 && pred.[0] >= 'a' && pred.[0] <= 'z' ->
        (match List.assoc_opt pred proof_env with
         | Some (_ :: _) -> true
         | _ ->
           let subj = match List.assoc_opt pred subject_env with Some s -> s | None -> pred in
           (match List.assoc_opt subj proof_env with Some (_ :: _) -> true | _ -> false))
      | _ -> false
    in
    if annotation_is_authoritative then Some extra
    else
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
     | Some (("andLeft" | "andRight") as proj), [pf] ->
       (* andLeft/andRight narrow a conjunction proof to one conjunct:
          andLeft P&&Q ⇒ P, andRight P&&Q ⇒ Q.  We project the input's
          flattened proof list (left = first element, right = last). *)
       (match carried_proofs_of_expr ~funcs subject_env proof_env pf with
        | Some preds when List.length preds >= 2 ->
          let flat =
            List.concat_map
              (let rec f = function
                 | PredAnd { left; right; _ } -> f left @ f right
                 | p -> [p]
               in f) preds
          in
          if List.length flat >= 2 then
            Some [ if proj = "andLeft" then List.hd flat
                   else List.nth flat (List.length flat - 1) ]
          else Some preds
        | other -> other)
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

let check_api_endpoint_structure ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  (* Validation-consolidation Phase 1: iterate the API forms precomputed ONCE in
     [module_facts] instead of re-filtering [decls].  [mf_api_forms] preserves
     source order, and the previous [_ -> []] arm contributed nothing, so the
     emitted error stream is byte-identical.  The ?facts/facts_or_compute opt-in
     keeps standalone/test callers (no facts threaded) byte-identical too. *)
  let api_forms = (facts_or_compute ?facts ~extra_funcs decls).mf_api_forms in
  (* Names of every top-level `capture` form (DCapture).  An API-block
     `capture name: T via <fn>` clause must reference one of these by name —
     `via` binds the path segment to a declared capture codec.  Referencing a
     JSON codec (e.g. `stringCodec`) or any other identifier here type-checks
     today but fails at `tesl run` because the emitted `(Capture <fn> ...)`
     route names a binding that is not a `define-capture`. *)
  let capture_form_names =
    List.filter_map (function
      | DCapture (cf : capture_form) -> Some cf.name
      | _ -> None) decls
  in
  let method_str = function
    | GET -> "get" | POST -> "post" | PUT -> "put"
    | DELETE -> "delete" | PATCH -> "patch" | SSE -> "sse"
  in
  List.concat_map (fun (af : api_form) ->
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

        (* The remaining two checks apply only to HTTP endpoints: SSE routes
           are emitted by [emit_sse_route], which strips `:param` segments and
           never emits a `(Capture …)` form, so a missing/codec capture on an
           SSE route is harmless at runtime. *)
        if ep.method_ <> SSE then begin

        (* Every `:param` path segment must have a matching `capture` clause.
           Without one the emitter invents an undefined capture name
           (`<param>Capture`), so the endpoint type-checks but crashes at
           `tesl run`.  This also catches the unsupported `using <codec>`
           spelling, which the parser silently drops (leaving the path param
           with no capture). *)
        List.iter (fun param ->
          if not (List.exists (fun (c : api_capture) -> c.binding.name = param)
                    ep.captures)
          then
            add_hint
              (Printf.sprintf
                "add a capture clause before `->`: either the inline form \
                 `capture %s: String with stringCodec` (no separate declaration), \
                 or `capture %s: String via %sCapture` with a top-level \
                 `capturer %sCapture: String using stringCodec`"
                param param param param)
              (Printf.sprintf
                "endpoint %s: path parameter `:%s` has no `capture` clause; \
                 every `:param` segment must be bound by a \
                 `capture %s: <Type> via <captureForm>` clause"
                ep_id param param)
        ) path_params;

        (* A capture's `via <fn>` must reference a declared top-level `capture`
           form.  Referencing a JSON codec (e.g. `stringCodec`) or any other
           identifier type-checks but fails at `tesl run` because the emitted
           route names a binding that is not a `define-capture`. *)
        List.iter (fun (c : api_capture) ->
          (* The inline form (`capture x: T with <codec> [via <check>]`) carries
             its own codec, so it needs no top-level `capturer` reference. Only
             the reference form (`via <capturer>`) must name a declared capturer. *)
          if c.inline_codec = None
             && List.mem c.binding.name path_params
             && not (List.mem c.via_fn capture_form_names)
          then
            add_hint
              (Printf.sprintf
                "`via %s` must name a top-level `capturer`, or use the inline \
                 form `capture %s: %s with stringCodec`; to use a capturer declare \
                 `capturer %s: %s: String using stringCodec` and write \
                 `capture %s: String via %s`%s"
                c.via_fn c.binding.name c.binding.name
                c.via_fn c.binding.name c.binding.name c.via_fn
                (if capture_form_names = [] then ""
                 else Printf.sprintf
                   " (declared capturers: %s)"
                   (String.concat ", " capture_form_names)))
              (Printf.sprintf
                "endpoint %s: capture `%s` uses `via %s`, but `%s` is not a \
                 declared `capturer` (it may be a codec or undefined); use the \
                 inline form `capture %s: %s with <codec>` or reference a `capturer`"
                ep_id c.binding.name c.via_fn c.via_fn c.binding.name c.binding.name)
        ) ep.captures

        end;

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
  ) api_forms

(* ── Queue / channel / workers / database / api-test structure checks ─────── *)

let check_entity_structure ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  (* Validation-consolidation Phase 1: iterate the entity forms precomputed once
     in [module_facts] (source-order preserved) instead of re-filtering [decls].
     Byte-identical because the dropped [_ -> []] arm produced nothing. *)
  let entities = (facts_or_compute ?facts ~extra_funcs decls).mf_entities in
  List.concat_map (fun (e : entity_form) ->
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
  ) entities

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

let check_cache_structure (decls : top_decl list) : validation_error list =
  let known_dbs =
    List.filter_map (function DDatabase db -> Some db.name | _ -> None) decls
  in
  List.concat_map (function
    | DCache (c : Ast.cache_form) ->
      let errs = ref [] in
      let add hint msg = errs := make_error c.loc ~hint msg :: !errs in
      if c.database = "" then
        add "add `database: MainDB` inside the cache block"
          (Printf.sprintf "cache `%s` is missing a `database` clause" c.name)
      else if not (List.mem c.database known_dbs) then
        add (Printf.sprintf "declare `database %s { ... }` in this module" c.database)
          (Printf.sprintf
            "cache `%s` references unknown database `%s`" c.name c.database);
      (match c.default_ttl with
       | Some n when n <= 0 ->
         add "use a positive integer (seconds), e.g. `defaultTtl: 3600`"
           (Printf.sprintf "cache `%s` has invalid `defaultTtl` %d; must be > 0" c.name n)
       | _ -> ());
      List.rev !errs
    | _ -> []
  ) decls

let check_email_structure (decls : top_decl list) : validation_error list =
  let known_dbs =
    List.filter_map (function DDatabase db -> Some db.name | _ -> None) decls
  in
  List.concat_map (function
    | DEmail (e : Ast.email_form) ->
      let errs = ref [] in
      let add hint msg = errs := make_error e.loc ~hint msg :: !errs in
      if e.database = "" then
        add "add `database: MainDB` inside the email block"
          (Printf.sprintf "email `%s` is missing a `database` clause" e.name)
      else if not (List.mem e.database known_dbs) then
        add (Printf.sprintf "declare `database %s { ... }` in this module" e.database)
          (Printf.sprintf
            "email `%s` references unknown database `%s`" e.name e.database);
      if e.smtp.host = "" then
        add "add `host: env(\"SMTP_HOST\")` inside the smtp block"
          (Printf.sprintf "email `%s` smtp block is missing a `host`" e.name);
      if e.smtp.port < 1 || e.smtp.port > 65535 then
        add "use a valid port number (e.g. 587 or 465)"
          (Printf.sprintf "email `%s` has invalid smtp `port` %d; must be 1-65535"
            e.name e.smtp.port);
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

(** A top-level `capture` that DECLARES a proof must establish it through a `via`
    check/auth function, exactly as a codec decoder field must (§11.7,
    validation_sql_codec.ml). Otherwise a `capture x: T ::: P x using c via f`
    where `f` does not produce `P` (or there is no `via` at all) would hand an
    unverified value to the handler param that requires `P x` — the obligation is
    lost at the HTTP entry point.

    Conservative: only captures whose binding carries a `proof_ann` are checked,
    and a missing/wrong `via` is rejected. Captures with no proof annotation are
    untouched. *)
let check_capture_proof_via
    ?facts
    ?(extra_funcs : (string * func_info) list = [])
    (decls : top_decl list)
    : validation_error list =
  let funcs = (facts_or_compute ?facts ~extra_funcs decls).mf_funcs in
  List.filter_map (function
    | DCapture cf ->
      (match cf.binding.proof_ann with
       | None -> None
       | Some proof ->
         let required_preds =
           List.sort_uniq String.compare (proof_predicates proof) in
         (match cf.checker with
          | None ->
            Some (make_error cf.binding.loc
              ~hint:(Printf.sprintf
                "add `via <checkFn>` so capture `%s` is validated before it reaches the handler"
                cf.name)
              (Printf.sprintf
                "capture `%s` declares proof %s but has no `via` validation; \
                 the HTTP value reaches the handler unverified"
                cf.name (String.concat ", " required_preds)))
          | Some via_fn ->
            (match List.assoc_opt via_fn funcs with
             | None ->
               Some (make_error cf.binding.loc
                 ~hint:"capture `via` must reference a declared `check` or `auth` function"
                 (Printf.sprintf "capture `%s`: `via %s` is not a declared function" cf.name via_fn))
             | Some info when info.fi_kind <> CheckKind && info.fi_kind <> AuthKind ->
               Some (make_error cf.binding.loc
                 ~hint:"only `check` and `auth` functions may appear after `via`"
                 (Printf.sprintf "capture `%s`: `via %s` is a %s, not a check/auth function"
                    cf.name via_fn
                    (match info.fi_kind with
                     | FnKind -> "fn" | HandlerKind -> "handler"
                     | WorkerKind -> "worker" | DeadWorkerKind -> "dead-worker"
                     | EstablishKind -> "establish" | MainKind -> "main"
                     | CheckKind -> "check" | AuthKind -> "auth")))
             | Some info ->
               let covered = pred_names_of_return_spec info.fi_return in
               let uncovered =
                 List.filter (fun p -> not (List.mem p covered)) required_preds in
               if uncovered = [] then None
               else
                 Some (make_error cf.binding.loc
                   ~hint:(Printf.sprintf
                     "`via %s` establishes %s; use a check function that produces %s"
                     via_fn
                     (if covered = [] then "no proof" else String.concat ", " covered)
                     (String.concat ", " uncovered))
                   (Printf.sprintf
                     "capture `%s` declares proof %s that is not established by `via %s`"
                     cf.name (String.concat ", " uncovered) via_fn)))))
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
    end;
    (* Capture/body proof reconciliation (mirror the auth reconciliation above):
       a handler parameter that REQUIRES a proof `P x` must have that proof supplied
       at the HTTP boundary. The router can only supply param proofs via `auth`,
       `capture`, or `body`. Auth predicates are reconciled above, so here we require
       that any remaining (non-auth) proof-carrying handler param is matched, BY NAME,
       to a capture or body binding whose declared proof covers `P`. Without this a
       `handler getTodo(todoId ::: TodoId todoId)` wired to a `capture todoId: String`
       (which establishes nothing) silently drops the obligation at the entry point. *)
    (match endpoint_opt with
     | None -> ()
     | Some ep ->
       let handler_params = match hdl with
         | LocalHandler fd -> fd.params
         | ImportedHandler info -> info.fi_params
       in
       (* Auth-supplied predicates are reconciled by the auth block above, NOT by
          name here. We exclude them endpoint-wide: any predicate the endpoint's own
          `auth` clause carries (read off `ep.auth.binding.proof_ann`) plus the global
          auth_preds set. Reading the endpoint's auth clause directly matters because
          auth functions written in the named-pack form `-> T ? Authenticated` are not
          picked up by auth_proof_pred_of_return_spec, so relying on auth_preds alone
          would wrongly demand a capture/body for an auth-supplied param (and the auth
          param name need not match the handler param name). *)
       let endpoint_auth_preds =
         auth_preds @ (match ep.auth with
           | Some a -> (match a.binding.proof_ann with
               | Some p -> proof_predicates p | None -> [])
           | None -> [])
       in
       (* Non-auth proofs the endpoint supplies for a given param name, via a
          same-named capture or body binding. *)
       let supplied_for (param_name : string) : string list =
         let from_captures =
           List.concat_map (fun (c : api_capture) ->
             if c.binding.name = param_name then
               (match c.binding.proof_ann with
                | Some p -> proof_predicates p | None -> [])
             else []
           ) ep.captures
         in
         let from_body =
           match ep.body with
           | Some b when b.name = param_name ->
             (match b.proof_ann with Some p -> proof_predicates p | None -> [])
           | _ -> []
         in
         from_captures @ from_body
       in
       (* A capture or body binding with the same name exists at all? *)
       let has_named_source (param_name : string) : bool =
         List.exists (fun (c : api_capture) -> c.binding.name = param_name) ep.captures
         || (match ep.body with Some b -> b.name = param_name | None -> false)
       in
       List.iter (fun (p : binding) ->
         match p.proof_ann with
         | None -> ()
         | Some proof ->
           (* Predicates the handler requires on this param, excluding auth
              predicates (reconciled in the auth block above). *)
           let required =
             List.filter (fun pred -> not (List.mem pred endpoint_auth_preds))
               (proof_predicates proof)
           in
           if required <> [] then begin
             let supplied = supplied_for p.name in
             let uncovered =
               List.filter (fun pred -> not (List.mem pred supplied)) required
             in
             if uncovered <> [] then
               let handler_loc = match hdl with
                 | LocalHandler fd -> fd.loc
                 | ImportedHandler info -> info.fi_loc
               in
               if has_named_source p.name then
                 errors := make_error handler_loc
                   ~hint:(Printf.sprintf
                     "annotate the capture/body for `%s` with `::: %s %s` (and a `via` \
                      that establishes it) in endpoint '%s', so the proof reaches the handler"
                     p.name (String.concat " && " uncovered) p.name endpoint_name)
                   (Printf.sprintf
                     "server '%s': handler '%s' requires proof %s on `%s`, but the \
                      capture/body for `%s` in endpoint '%s' establishes %s — the \
                      obligation is lost at the HTTP boundary"
                     sv.name handler_name (String.concat ", " uncovered) p.name
                     p.name endpoint_name
                     (if supplied = [] then "nothing" else String.concat ", " supplied))
                   :: !errors
               else
                 errors := make_error handler_loc
                   ~hint:(Printf.sprintf
                     "add `capture %s: %s ::: %s %s via <checkFn>` (or a proof-carrying \
                      `body`) to endpoint '%s' so the proof reaches the handler"
                     p.name (pp_type_expr p.type_expr) (String.concat " && " uncovered)
                     p.name endpoint_name)
                   (Printf.sprintf
                     "server '%s': handler '%s' requires proof %s on `%s`, but endpoint \
                      '%s' supplies no capture or body for `%s` — the obligation cannot \
                      be established at the HTTP boundary"
                     sv.name handler_name (String.concat ", " uncovered) p.name
                     endpoint_name p.name)
                   :: !errors
           end
       ) handler_params)

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

(* ── Library boundary validation ─────────────────────────────────────────── *)

(** Check that locally-imported modules do not contain application-only
    declarations (`api`, `server`).  These declarations define an app's
    external interface and cannot be meaningfully shared as a library.

    The check runs at the *importer* level: when compiling module B that
    imports module A, we load A's AST and look for forbidden declarations.
    Errors are pinned to the `import` statement in B, not to A. *)
(** Validate that a module declared with the `library` keyword does not contain
    application-only declarations.  When `is_library = true` the compiler enforces
    the boundary immediately without waiting for an import to trigger the check. *)
let check_library_self_boundary (m : module_form) : validation_error list =
  if not m.is_library then []
  else
    let decl_kind_loc = function
      | DApi api      -> Some ("api",      api.loc)
      | DServer sv    -> Some ("server",   sv.loc)
      | DFunc fd when fd.kind = MainKind -> Some ("main", fd.loc)
      | DWorkers w    -> Some ("workers",  w.loc)
      | DDatabase db  -> Some ("database", db.loc)
      | DEntity e     -> Some ("entity",   e.loc)
      | _ -> None
    in
    List.filter_map (fun decl ->
      match decl_kind_loc decl with
      | None -> None
      | Some (kind, loc) ->
        Some (make_error loc
          ~hint:(Printf.sprintf
            "remove the `%s` block from this library module, or change `library` to `module`"
            kind)
          (Printf.sprintf
            "library module `%s` contains a `%s` declaration; \
             library modules cannot own application infrastructure"
            m.module_name kind))
    ) m.decls

let check_imported_module_is_library (m : module_form) : validation_error list =
  let is_tesl_module name =
    String.length name >= 5 && String.sub name 0 5 = "Tesl."
  in
  let decl_kind_name = function
    | DApi _     -> Some "api"
    | DServer _  -> Some "server"
    | DWorkers _ -> Some "workers"
    | DFunc fd when fd.kind = MainKind -> Some "main"
    | _ -> None
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
          (* Collect all forbidden declaration kinds present in the imported module *)
          let forbidden =
            List.filter_map decl_kind_name imported.decls
            |> List.sort_uniq String.compare
          in
          List.map (fun kind ->
            make_error imp.loc
              ~hint:(Printf.sprintf
                "move the `%s` block to your application's root module, \
                 or create a separate app entry-point that imports from `%s`"
                kind imp.module_name)
              (Printf.sprintf
                "imported module `%s` contains a `%s` declaration, \
                 which is not allowed in library modules"
                imp.module_name kind)
          ) forbidden
  ) m.imports

(* ── 2. SQL/record field name validation ─────────────────────────────────── *)

