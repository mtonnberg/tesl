open Ast
open Location
open Validation_common

let build_func_capability_map (decls : top_decl list) : (string * string list) list =
  List.filter_map (function
    | DFunc fd -> Some (fd.name, fd.capabilities)
    | _ -> None
  ) decls

(** Capability ENFORCEMENT table for the runtime/effect expression forms.

    Wave-2 reduce_language_size step: the per-effect-form capability requirement
    used to be spelled out inline in {!collect_needed_capabilities}'s match arms
    (one arm per form prepending a literal token list).  That enforcement is now
    RELOCATED here as data — one row per effect form, giving the fixed capability
    token(s) the form's own primitive requires.  The match arm in
    {!collect_needed_capabilities} consults this table and then recurses into the
    form's sub-expressions, so the WHAT (which capability each effect demands) is
    declarative and the HOW (tree walk + transitive closure + handler/worker
    denial in {!check_handler_capabilities}) is unchanged.

    Enforcement is NOT dropped: every token a form produced before still flows
    through the identical {!check_handler_capabilities} denial path, so a
    capability-denied effect still fails to compile.  Cache forms stay inline
    because their required token is data-dependent (the cache_name is
    interpolated into the token), not a fixed string. *)
let effect_form_fixed_caps : (string * string list) list = [
  "EEnqueue",          ["queueWrite"];
  "EPublish",          ["pubsub"];
  "ETelemetry",        [];          (* needs only what its field exprs need *)
  "ESendEmail",        ["email"];
  "EStartEmailWorker", ["email"];
]

let effect_caps key =
  match List.assoc_opt key effect_form_fixed_caps with Some c -> c | None -> []

(** Check whether an expression body uses any DB or queue/pubsub operations,
    or calls any functions that require capabilities.
    Returns a list of capability names needed.

    Wave-2 visitor migration: this is a pure fold over an expression's children
    whose result is ONLY ever consumed through [List.sort_uniq String.compare]
    (every caller dedups + sorts immediately), so accumulation ORDER is
    irrelevant downstream.  The mechanical descent — every variant that
    contributes nothing of its own beyond what its child exprs need — is now
    delegated to the single shared {!Ast_visitor.fold_children} traversal,
    mirroring {!Linter.collect_expr_names}.  Only the THREE semantically
    load-bearing classes of arm remain explicit:

      1. [EVar] / [EField] capability LOOKUP (SQL keywords, time/random/jwt/
         httpClient primitives, user-function caps) — the leaf that introduces a
         requirement out of a bare name.
      2. The fixed-token EFFECT forms ([EEnqueue]/[EPublish]/[ETelemetry]/
         [ESendEmail]/[EStartEmailWorker]) which prepend their {!effect_caps}
         token and THEN recurse into children.
      3. The CACHE forms, whose required token is data-dependent (the token is
         the cache name interpolated after a 'cache ' prefix) and so cannot live
         in the static data table.

    Sharing one descent means a new {!Ast.expr} variant cannot silently escape
    capability analysis.  An internal accumulator threads the list; the list-
    concatenation-vs-prepend difference is invisible to callers because they
    sort_uniq the result. *)
let collect_needed_capabilities
    ?(func_caps : (string * string list) list = [])
    (e : expr)
    : string list =
  let sql_read_names = ["select"; "selectOne"; "selectCount"; "selectSum"; "selectMax"; "selectMin"] in
  let sql_write_names = ["insert"; "update"; "delete"; "upsert"] in
  (* var_caps: the capability(ies) a bare referenced name introduces. *)
  let var_caps name =
    (* BUG-1 fix: Check user-defined functions FIRST.
       A user function named `insert`, `select`, `update`, or `delete` must NOT be
       treated as a SQL operation. `List.mem_assoc` returns true even for functions
       with empty capabilities (requires []), correctly shadowing the SQL keywords. *)
    if List.mem_assoc name func_caps then
      (match List.assoc_opt name func_caps with
       | Some caps -> caps
       | None -> [])
    else if List.mem name sql_read_names then ["dbRead"]
    else if List.mem name sql_write_names then ["dbWrite"]
    else if name = "deadJobs" then ["queueRead"]
    else if name = "requeue" then ["queueWrite"]
    else if List.mem name ["now"; "nowMillis"; "Time.now"; "Time.nowMillis";
                           "Time.secondsToPosix"; "Time.posixToMillis";
                           "Time.durationMs"; "Time.diffMs"; "Time.addMs";
                           "Time.subtractMs"; "Time.formatTime"] then ["time"]
    (* BUG-4 fix: generatePrefixedId and randomInt require the `random` capability. *)
    else if List.mem name ["generatePrefixedId"; "randomInt";
                           "Tesl.Id.generatePrefixedId"; "Tesl.Random.randomInt"] then ["random"]
    else if List.mem name ["JWT.sign"; "JWT.verify"; "JWT.decode"] then ["jwt"]
    else if List.mem name ["HttpClient.get"; "HttpClient.post";
                           "HttpClient.put"; "HttpClient.delete"] then ["httpClient"]
    (* Tesl.Agent: `ask` performs inference and requires the aiProvider capability. *)
    else if name = "ask" then ["aiProvider"]
    else []
  in
  (* acc is threaded left-to-right; result order is irrelevant (caller sort_uniqs). *)
  let rec go (acc : string list) (e : expr) : string list =
    match e with
    | EVar { name; _ } -> var_caps name @ acc
    | EField { obj = EConstructor { name = "JWT"; _ }; field; _ }
      when List.mem field ["sign"; "verify"; "decode"] -> "jwt" :: acc
    | EField { obj = EVar { name = "JWT"; _ }; field; _ }
      when List.mem field ["sign"; "verify"; "decode"] -> "jwt" :: acc
    | EField { obj = EConstructor { name = "HttpClient"; _ }; field; _ } ->
      (* HttpClient.get / .post / .put / .delete accessed as EField on EConstructor.
         Note: the EConstructor obj is intentionally NOT recursed into here (it
         carries no further capability), matching the original arm exactly. *)
      if List.mem ("HttpClient." ^ field)
           ["HttpClient.get"; "HttpClient.post"; "HttpClient.put"; "HttpClient.delete"]
      then "httpClient" :: acc
      else acc
    (* Effect forms: prepend the fixed data-table token, then descend into
       children via the shared traversal. *)
    | EEnqueue _ | EPublish _ | ETelemetry _ | ESendEmail _ ->
      let key = match e with
        | EEnqueue _ -> "EEnqueue" | EPublish _ -> "EPublish"
        | ETelemetry _ -> "ETelemetry" | _ -> "ESendEmail" in
      Ast_visitor.fold_children go (effect_caps key @ acc) e
    | EStartEmailWorker _ -> effect_caps "EStartEmailWorker" @ acc
    (* EConstructor is kept EXPLICIT as a no-capability LEAF: the original arm
       was `EConstructor _ -> []`, which did NOT walk constructor arguments.
       fold_children WOULD descend into the args, so we keep the original
       non-descent to remain byte-identical. *)
    | EConstructor _ -> acc
    (* ECase is kept EXPLICIT (not delegated to fold_children) to preserve the
       original traversal set EXACTLY: the hand-rolled arm descended into the
       scrutinee and each arm BODY but NOT the arm guards.  fold_children would
       additionally descend into guards — a strictly-safe over-approximation, but
       we keep behaviour byte-identical rather than widen the analysed set here. *)
    | ECase { scrut; arms; _ } ->
      let acc = go acc scrut in
      List.fold_left (fun acc (arm : case_arm) -> go acc arm.body) acc arms
    (* Cache forms: data-dependent token, then descend into key/value/ttl/prefix. *)
    | ECacheGet { cache_name; _ } | ECacheSet { cache_name; _ }
    | ECacheDelete { cache_name; _ } | ECacheInvalidate { cache_name; _ } ->
      Ast_visitor.fold_children go (("cache " ^ cache_name) :: acc) e
    (* Purely-mechanical variants: descend into child exprs only.  This includes
       EField (non-special obj), EApp, EBinop, EUnop, EIf, ELet, ELetProof,
       ERecord, EList, EOk, EWithDatabase/EWithCapabilities/EWithTransaction,
       EServe, ELambda, and the no-capability leaves (ELit, EFail, EStartWorkers,
       EConstructor, plain EVar handled above).

       NOTE on EServe: fold_children visits exactly the [port] child (the only
       expr field), matching the original `EServe { port; _ }` arm.  EWith*
       forms each carry a single [body] child, also matched exactly. *)
    | _ -> Ast_visitor.fold_children go acc e
  in
  go [] e

let check_handler_capabilities ?(cap_map=[]) (decls : top_decl list) : validation_error list =
  let func_caps = build_func_capability_map decls in
  (* Full transitive closure: expand a set of declared capabilities to everything they
     imply, recursively. Uses the same algorithm as expand_caps in proof_checker.ml. *)
  let expand_declared declared =
    let result = Hashtbl.create 16 in
    let rec expand name =
      if not (Hashtbl.mem result name) then begin
        Hashtbl.replace result name ();
        match List.assoc_opt name cap_map with
        | Some implied -> List.iter expand implied
        | None -> ()
      end
    in
    List.iter expand declared;
    Hashtbl.fold (fun k () acc -> k :: acc) result []
  in
  let cap_covered declared needed =
    List.mem needed (expand_declared declared)
  in
  let errors = ref [] in
  List.iter (function
    | DFunc fd when fd.kind = HandlerKind ->
      let needed = collect_needed_capabilities ~func_caps fd.body |> List.sort_uniq String.compare in
      let declared = fd.capabilities in
      let missing = List.filter (fun cap -> not (cap_covered declared cap)) needed in
      if missing <> [] then
        errors := make_error fd.loc
          ~hint:(Printf.sprintf "add `requires [%s]` to the handler declaration"
                   (String.concat ", " missing))
          (Printf.sprintf "handler '%s' uses [%s] but does not declare the required capabilities"
             fd.name (String.concat ", " missing))
          :: !errors
    | DFunc fd when fd.kind = WorkerKind ->
      let needed = collect_needed_capabilities ~func_caps fd.body |> List.sort_uniq String.compare in
      let declared = fd.capabilities in
      let missing = List.filter (fun cap -> not (cap_covered declared cap)) needed in
      if missing <> [] then
        errors := make_error fd.loc
          ~hint:(Printf.sprintf "add `requires [%s]` to the worker declaration"
                   (String.concat ", " missing))
          (Printf.sprintf "worker '%s' uses [%s] but does not declare the required capabilities"
             fd.name (String.concat ", " missing))
          :: !errors
    | DFunc fd when fd.kind = FnKind ->
      let needed = collect_needed_capabilities ~func_caps fd.body |> List.sort_uniq String.compare in
      let declared = fd.capabilities in
      let missing = List.filter (fun cap -> not (cap_covered declared cap)) needed in
      if missing <> [] then
        errors := make_error fd.loc
          ~hint:(Printf.sprintf "add `requires [%s]` to the fn declaration"
                   (String.concat ", " missing))
          (Printf.sprintf "fn '%s' uses privileged operations and callees requiring [%s] but does not declare them"
             fd.name (String.concat ", " missing))
          :: !errors
    | DFunc fd when fd.kind = DeadWorkerKind ->
      let needed = collect_needed_capabilities ~func_caps fd.body |> List.sort_uniq String.compare in
      let declared = fd.capabilities in
      let missing = List.filter (fun cap -> not (cap_covered declared cap)) needed in
      if missing <> [] then
        errors := make_error fd.loc
          ~hint:(Printf.sprintf "add `requires [%s]` to the deadWorker declaration"
                   (String.concat ", " missing))
          (Printf.sprintf "deadWorker '%s' uses [%s] but does not declare the required capabilities"
             fd.name (String.concat ", " missing))
          :: !errors
    | _ -> ()
  ) decls;
  List.rev !errors

(** Extract variable name from a `(Id == varName)` proof argument string.
    E.g., "(Id == id)" → Some "id". *)
let extract_id_eq_var (arg : string) : string option =
  (* Strip surrounding parens if present *)
  let s = String.trim arg in
  let s = if String.length s > 1 && s.[0] = '(' && s.[String.length s - 1] = ')'
          then String.sub s 1 (String.length s - 2) |> String.trim
          else s in
  (* Find "==" and take everything after it, trimmed *)
  match String.split_on_char ' ' s with
  | parts ->
    (* Find "==" token and take the next non-empty token *)
    let rec find_after_eq = function
      | [] -> None
      | "==" :: next :: _ ->
        let v = String.trim next in
        if String.length v > 0 then Some v else None
      | _ :: rest -> find_after_eq rest
    in
    find_after_eq (List.filter (fun p -> p <> "") parts)

(** Extract the variable from a FromDb proof's (Id == X) argument. *)
let fromdb_pk_var (proof : proof_expr) : string option =
  match proof with
  | PredApp { pred = "FromDb"; args = [arg]; _ } -> extract_id_eq_var arg
  | _ -> None

(** Extract the plain variable from a ForAll FromDb proof's (Field == X) argument.
    Returns None if the variable is a field access (e.g. requestUser.id — tokenized
    as "requestUser . id" with spaces, so the next token after the variable is ".").
    E.g., ForAll (FromDb (RoomId == roomId)) → Some "roomId".
    E.g., ForAll (FromDb (OwnerId == requestUser.id)) → None (field access). *)
let forall_fromdb_field_var (proof : proof_expr) : string option =
  match proof with
  | PredApp { pred = "FromDb"; args = [arg]; _ } ->
    let s = String.trim arg in
    let s = if String.length s > 1 && s.[0] = '(' && s.[String.length s - 1] = ')'
            then String.sub s 1 (String.length s - 2) |> String.trim
            else s in
    let parts = List.filter (fun p -> p <> "") (String.split_on_char ' ' s) in
    (* Find the variable after == and check if it's followed by "." (field access) *)
    let rec find_var = function
      | [] -> None
      | "==" :: v :: "." :: _ -> ignore v; None  (* field access: skip *)
      | "==" :: v :: _ ->
        if String.length v > 0 && v.[0] >= 'a' && v.[0] <= 'z'
        then Some v
        else None
      | _ :: rest -> find_var rest
    in
    find_var parts
  | _ -> None

(** Check that SELECT WHERE conditions match the named-pack return spec's pk constraint.
    E.g., `-> Task ? FromDb (Id == id)` requires `selectOne t from Task where t.id == id`.
    Also validates ForAll return types: `-> List Msg ? ForAll (FromDb (RoomId == roomId))`
    requires the SELECT to use `roomId`, not another variable. *)
let check_pk_match (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  List.iter (function
    | DFunc fd when (fd.kind = FnKind || fd.kind = HandlerKind) ->
      (* Determine the expected WHERE variable from the return spec, and a label
         describing it for error messages. Returns (expected_var, spec_label). *)
      let where_spec = match fd.return_spec with
        | RetNamedPack { entity_proof = Some ep; _ } ->
          (match fromdb_pk_var ep with
           | Some v -> Some (v, Printf.sprintf "Id == %s" v)
           | None -> None)
        | RetForAll { proof; _ } | RetMaybeForAll { proof; _ } ->
          (match forall_fromdb_field_var proof with
           | Some v when not (String.contains v '.') ->
             (* Only check simple parameter names (no field access like `user.id`).
                Field-access subjects like `requestUser.id` are legitimate but cannot
                be validated by simple param-name matching. *)
             Some (v, Printf.sprintf "FromDb (...%s...) in ForAll" v)
           | _ -> None)
        | _ -> None
      in
      (match where_spec with
       | None -> ()
       | Some (expected_var, spec_label) ->
         let param_names = List.map (fun (b : binding) -> b.name) fd.params in
         (* Check that expected_var is a parameter *)
         if not (List.mem expected_var param_names) then
           errors := make_error fd.loc
             ~hint:(Printf.sprintf "`%s` used in `%s` is not a parameter name; \
                     use a function parameter" expected_var spec_label)
             (Printf.sprintf "return spec `%s`: `%s` is not a parameter name"
                spec_label expected_var)
           :: !errors
         else begin
              (* Walk body looking for SELECT WHERE conditions *)
              let rec check_expr (e : expr) =
                match e with
                | EApp _ ->
                  let flat = let rec go acc = function
                    | EApp { fn; arg; _ } -> go (arg :: acc) fn
                    | hd -> (hd, acc)
                    in go [] e
                  in
                  let (head, args) = flat in
                  (match head with
                   | EVar { name = ("selectOne" | "select"); _ } ->
                     (* Find the WHERE condition — args: [binder, "from", Entity, "where", EField{binder.field}] *)
                     (* The actual comparison value is in the outer EBinop if present *)
                     List.iter check_expr args
                   | _ ->
                     List.iter check_expr args;
                     check_expr head)
                | EBinop { op = BEq; left; right; loc } ->
                  (* SELECT ... WHERE binder.field == value — check value matches expected_var *)
                  let flat = let rec go acc = function
                    | EApp { fn; arg; _ } -> go (arg :: acc) fn
                    | hd -> (hd, acc)
                    in go [] left
                  in
                  let (head, args) = flat in
                  (* Detect select WHERE: head = selectOne/select, last arg is binder.field *)
                  let is_select = match head with
                    | EVar { name = ("selectOne" | "select"); _ } -> true
                    | _ -> false
                  in
                  (* Detect update/standalone WHERE: head = "where", single arg = binder.field *)
                  let is_where_clause = match head with
                    | EVar { name = "where"; _ } -> true
                    | _ -> false
                  in
                  let check_where_value binder last_arg =
                    let is_binder_field = match last_arg with
                      | EField { obj = EVar { name; _ }; _ } when name = binder -> true
                      | _ -> false
                    in
                    if is_binder_field then begin
                      let where_val = match right with
                        | EVar { name; _ } -> Some name
                        | ELit _ -> None
                        | _ -> None
                      in
                      (match where_val with
                       | None ->
                         errors := make_error loc
                           ~hint:(Printf.sprintf "the WHERE clause should compare \
                                   to `%s` (from `Id == %s` in the return spec)"
                                   expected_var expected_var)
                           (Printf.sprintf "WHERE condition does not match \
                                  `Id == %s` in return spec; \
                                  use parameter `%s` not a literal"
                              expected_var expected_var)
                         :: !errors
                       | Some where_v when where_v <> expected_var ->
                         errors := make_error loc
                           ~hint:(Printf.sprintf "the WHERE clause should use `%s` \
                                   (from `Id == %s` in the return spec)"
                                   expected_var expected_var)
                           (Printf.sprintf "WHERE clause uses `%s` but return spec \
                                  declares `Id == %s`; these do not match"
                              where_v expected_var)
                         :: !errors
                       | _ -> ())
                    end
                  in
                  if is_select then begin
                    let binder = match args with EVar { name; _ } :: _ -> name | _ -> "_" in
                    let last_arg = match List.rev args with x :: _ -> x | [] -> ELit { lit = LInt 0; loc } in
                    check_where_value binder last_arg
                  end else if is_where_clause then begin
                    (* update WHERE: EApp{fn=EVar"where"; arg=EField{binder.field}} == value *)
                    let last_arg = match args with [x] -> x | _ -> ELit { lit = LInt 0; loc } in
                    let binder = match last_arg with
                      | EField { obj = EVar { name; _ }; _ } -> name
                      | _ -> "_"
                    in
                    check_where_value binder last_arg
                  end;
                  check_expr left; check_expr right
                | ELet { value; body; _ } -> check_expr value; check_expr body
                | ELetProof { value; body; _ } -> check_expr value; check_expr body
                | EIf { cond; then_; else_; _ } ->
                  check_expr cond; check_expr then_; check_expr else_
                | ECase { scrut; arms; _ } ->
                  check_expr scrut;
                  List.iter (fun (arm : case_arm) -> check_expr arm.body) arms
                | EWithTransaction { body; _ } | EWithDatabase { body; _ }
                | EWithCapabilities { body; _ } -> check_expr body
                | _ -> ()
              in
              check_expr fd.body
            end)
    | _ -> ()
  ) decls;
  List.rev !errors

(** Check that insert statements inside `exists witness => ...` use the witness variable
    for the primary-key field, not a different variable or literal.
    E.g., `-> exists msgId: String => Msg ? FromDb (Id == msgId)` requires
    `insert Msg { id: msgId, ... }`, not `insert Msg { id: "sneaky", ... }`. *)
let check_insert_pk_match (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  (* Recursively find witness name from RetExists chain. Returns the innermost
     exists witness name and the FromDb pk var from its inner RetNamedPack. *)
  let rec exists_pk_spec spec = match spec with
    | RetExists { binding; body; _ } ->
      let witness = binding.name in
      (match exists_pk_spec body with
       | Some (_, pk) -> Some (witness, pk)
       | None ->
         (match body with
          | RetNamedPack { entity_proof = Some ep; _ } ->
            (match fromdb_pk_var ep with
             | Some pk -> Some (witness, pk)
             | None -> None)
          | _ -> None))
    | _ -> None
  in
  (* Check a single insert expression that is the packed body of `exists witness =>`.
     Only the PACKED body insert is validated — other inserts in the function body
     (e.g. for related entities) are allowed to use different id bindings. *)
  let check_packed_insert witness pk_var (e : expr) =
    let (head, args) = collect_call_head_and_args [] e in
    match function_name_of_expr head with
    | Some "insert" ->
      List.iter (fun arg ->
        match arg with
        | ERecord { fields; loc; _ } ->
          List.iter (fun (fname, fval) ->
            if fname = "id" then begin
              match fval with
              | EVar { name; _ } when name <> pk_var && name <> witness ->
                errors := make_error loc
                  ~hint:(Printf.sprintf
                    "the `id` field must be `%s` (the existential witness) to satisfy `FromDb (Id == %s)` in the return spec"
                    witness witness)
                  (Printf.sprintf
                    "insert uses `id: %s` but return spec declares `Id == %s`; \
                     these do not match — use the existential witness `%s` for the id field"
                    name witness witness)
                :: !errors
              | ELit _ ->
                errors := make_error loc
                  ~hint:(Printf.sprintf
                    "use `id: %s` (the existential witness) instead of a literal to satisfy `FromDb (Id == %s)` in the return spec"
                    witness witness)
                  (Printf.sprintf
                    "insert uses a literal for `id` but return spec declares `Id == %s`; \
                     the `id` must be the existential witness `%s`, not a string or integer literal"
                    witness witness)
                :: !errors
              | _ -> ()
            end
          ) fields
        | _ -> ()
      ) args
    | _ -> ()
  in
  (* Find (actual_witness_var, body) pairs from `exists X => body` packs.
     actual_witness_var is the variable written in `exists X =>` — it may differ
     from the return-spec witness name (e.g. `exists i => ...` with return spec
     `-> exists itemId => ...`). Both names must be accepted for the id field. *)
  let rec packed_witness_and_bodies (e : expr) : (string * expr) list =
    match e with
    | EApp {
        fn = EVar { name = "make-witness"; _ };
        arg = EApp { fn = EVar { name = actual_witness; _ }; arg = body; _ };
        _ } -> [(actual_witness, body)]
    | EApp { fn; arg; _ } ->
      packed_witness_and_bodies fn @ packed_witness_and_bodies arg
    | EIf { cond; then_; else_; _ } ->
      packed_witness_and_bodies cond
      @ packed_witness_and_bodies then_
      @ packed_witness_and_bodies else_
    | ECase { scrut; arms; _ } ->
      packed_witness_and_bodies scrut
      @ List.concat_map (fun (arm : case_arm) -> packed_witness_and_bodies arm.body) arms
    | ELet { value; body; _ } | ELetProof { value; body; _ } ->
      packed_witness_and_bodies value @ packed_witness_and_bodies body
    | EWithTransaction { body; _ } | EWithDatabase { body; _ }
    | EWithCapabilities { body; _ } -> packed_witness_and_bodies body
    | _ -> []
  in
  List.iter (function
    | DFunc fd when (fd.kind = FnKind || fd.kind = HandlerKind) ->
      (match exists_pk_spec fd.return_spec with
       | Some (witness, pk_var) ->
         List.iter (fun (actual_witness, body) ->
           (* Allow id to be: the return-spec pk var, the return-spec witness name,
              or the actual exists-X variable (which may differ from the spec name). *)
           let extended_witness =
             if actual_witness = witness then witness
             else actual_witness
           in
           check_packed_insert
             extended_witness
             (if pk_var = witness then extended_witness else pk_var)
             body)
           (packed_witness_and_bodies fd.body)
       | None -> ())
    | _ -> ()
  ) decls;
  List.rev !errors

(** Check for invalid HttpRequest field chain access (request.cookies.X).
    `cookies` is a Dict, so `.X` field access doesn't work — use Dict.lookup instead. *)
let check_cookies_field_access (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  let rec check_expr (e : expr) =
    match e with
    | EField { obj = EField { obj = EVar { name = req_name; _ }; field = "cookies"; _ };
               field = _; loc } ->
      errors := make_error loc
        ~hint:(Printf.sprintf
          "use `Dict.lookup \"<key>\" %s.cookies` to get a cookie value" req_name)
        (Printf.sprintf
          "3-level dot access `%s.cookies.<field>` is not valid — \
           `cookies` is a Dict, not a record; \
           use Dict.lookup to access cookie values" req_name)
      :: !errors
    | EApp { fn; arg; _ } -> check_expr fn; check_expr arg
    | EField { obj; _ } -> check_expr obj
    | EBinop { left; right; _ } -> check_expr left; check_expr right
    | EUnop { arg; _ } -> check_expr arg
    | EIf { cond; then_; else_; _ } ->
      check_expr cond; check_expr then_; check_expr else_
    | ECase { scrut; arms; _ } ->
      check_expr scrut;
      List.iter (fun (arm : case_arm) -> check_expr arm.body) arms
    | ELet { value; body; _ } -> check_expr value; check_expr body
    | ELetProof { value; body; _ } -> check_expr value; check_expr body
    | ERecord { fields; _ } ->
      List.iter (fun (_, v) -> check_expr v) fields
    | EOk { value; _ } -> check_expr value
    | EWithTransaction { body; _ } | EWithDatabase { body; _ }
    | EWithCapabilities { body; _ } -> check_expr body
    | _ -> ()
  in
  List.iter (function
    | DFunc fd -> check_expr fd.body
    | _ -> ()
  ) decls;
  List.rev !errors

(* ── Module-level validation ──────────────────────────────────────────────── *)

let build_local_cap_map (decls : top_decl list) : (string * string list) list =
  List.filter_map (function
    | DCapability c -> Some (c.name, c.implies)
    (* Cache declarations implicitly define a "cache <Name>" capability *)
    | DCache (c : Ast.cache_form) -> Some ("cache " ^ c.name, [])
    (* Email declarations implicitly define an "email" capability *)
    | DEmail _ -> Some ("email", [])
    | _ -> None
  ) decls

(** Detect cycles in the capability `implies` graph using DFS.
    A cycle means a capability (transitively) implies itself, which makes the
    implication relation circular and semantically meaningless. *)
let check_capability_cycles (decls : top_decl list) : validation_error list =
  let caps : capability_form list =
    List.filter_map (function DCapability c -> Some c | _ -> None) decls
  in
  if caps = [] then []
  else begin
    (* Build adjacency: name → (list of implied names, loc) *)
    let adj : (string * (string list * loc)) list =
      List.map (fun (c : capability_form) -> (c.name, (c.implies, c.loc))) caps
    in
    let errors = ref [] in
    (* DFS with colour marking: white=0 unvisited, grey=1 in stack, black=2 done *)
    let colour : (string, int) Hashtbl.t = Hashtbl.create 8 in
    let rec dfs path node =
      match Hashtbl.find_opt colour node with
      | Some 2 -> ()  (* already fully explored *)
      | Some 1 ->
        (* Back-edge: cycle detected — report on the capability that closes the loop *)
        let cycle_str = String.concat " → " (List.rev (node :: path)) in
        let loc = match List.assoc_opt node adj with
          | Some (_, l) -> l | None -> dummy_loc "capability cycle"
        in
        errors := make_error loc
          ~hint:"remove one of the `implies` declarations that creates the cycle"
          (Printf.sprintf "capability cycle detected: %s" cycle_str)
          :: !errors
      | _ ->
        Hashtbl.replace colour node 1;
        (match List.assoc_opt node adj with
         | Some (implied, _) ->
           List.iter (fun target -> dfs (node :: path) target) implied
         | None -> ());
        Hashtbl.replace colour node 2
    in
    List.iter (fun (c : capability_form) ->
      if not (Hashtbl.mem colour c.name) then dfs [] c.name
    ) caps;
    List.rev !errors
  end

(** Check that the argument types in proof annotations match the declared
    parameter types in `fact` declarations.
    E.g. `fact IsPositive (n: Int)` with `ok s ::: IsPositive s` where `s: String`
    is a type mismatch and should be a compile error.
    Only simple variable-name arguments are checked; complex expressions are skipped. *)
let check_fact_arg_types (decls : top_decl list) : validation_error list =
  (* Build map: fact_name → declared param bindings *)
  let fact_map : (string * binding list) list =
    List.filter_map (function
      | DFact ff -> Some (ff.name, ff.params)
      | _ -> None
    ) decls
  in
  if fact_map = [] then []
  else begin
    let errors = ref [] in
    (* Check one proof expression given a local var→type_key env *)
    (* ~entity:true = this proof is in entity-proof position (e.g. Int ? BoundedBy limit)
       where the entity variable is auto-appended as the last argument, so
       n_params-1 explicit args is valid. *)
    let is_simple_proof_subject (arg : string) : bool =
      let n = String.length arg in
      let rec loop i =
        if i >= n then true
        else
          match arg.[i] with
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> loop (i + 1)
          | _ -> false
      in
      n > 0 && loop 0
    in
    let rec take_prefix n xs =
      if n <= 0 then []
      else
        match xs with
        | [] -> []
        | x :: rest -> x :: take_prefix (n - 1) rest
    in
    let rec check_proof ?(entity = false) ?(forall_inner = false) local_env loc (p : proof_expr) =
      match p with
      | PredApp { pred; args; loc = ploc } ->
        (match List.assoc_opt pred fact_map with
         | Some param_bindings ->
           let n_params = List.length param_bindings in
           let n_args   = List.length args in
           (* entity && n_args = n_params-1: entity auto-appended as last arg — also valid *)
           let entity_implicit = entity && n_params > 0 && n_args = n_params - 1 in
           if n_params = n_args then
             List.iter2 (fun (param : binding) arg_name ->
               match param.type_expr with
               | TVar _ -> ()  (* Generic type parameter — accept any type *)
               | decl_ty ->
                 let decl_key = type_key decl_ty in
                 (* Only check simple identifiers; skip dotted paths / complex args *)
                 if String.contains arg_name '.' || String.contains arg_name '('
                    || String.contains arg_name '*' then ()
                 else
                   match List.assoc_opt arg_name local_env with
                   | None -> ()  (* Variable not in scope map — skip *)
                   | Some actual_key ->
                     if actual_key <> decl_key then
                       let use_loc = if ploc.start.col > 0 || ploc.start.line > 0 then ploc else loc in
                       errors := make_error use_loc
                         ~hint:(Printf.sprintf
                           "fact `%s` declares parameter `%s: %s`, but `%s` has type `%s`; \
check your fact declaration or the type of `%s`"
                           pred param.name decl_key arg_name actual_key arg_name)
                         (Printf.sprintf
                           "proof `%s %s`: argument `%s` has type `%s` but fact `%s` declares type `%s`"
                           pred (String.concat " " args) arg_name actual_key pred decl_key)
                       :: !errors
             ) param_bindings args
           else if entity_implicit then
             ()  (* entity auto-appended — valid, skip type check for implicit entity arg *)
           else if forall_inner && (n_args = 0 || n_args = n_params - 1) then
             ()  (* ForAll/Set inner predicate: zero-arg OR (n_params-1) literal args (element subject implicit) *)
           else
             (* Wrong arity: n_args ≠ n_params and no special context allows it *)
             errors := make_error ploc
               ~hint:(Printf.sprintf
                 "fact `%s` declares %d argument%s — in `:::` annotations write `%s %s`"
                 pred n_params (if n_params = 1 then "" else "s")
                 pred
                 (String.concat " " (List.map (fun (b : binding) -> b.name) param_bindings)))
               (Printf.sprintf
                 "proof `%s`: argument count mismatch — expected %d, got %d; use `%s <subject>` in `:::` annotations"
                 pred n_params n_args pred)
             :: !errors
         | None -> ())  (* Not a user-declared fact — skip *)
      | PredAnd { left; right; _ } ->
        check_proof ~entity ~forall_inner local_env loc left;
        check_proof ~entity ~forall_inner local_env loc right
    in
    let rec check_entity_proof local_env loc (p : proof_expr) =
      match p with
      | PredApp { pred; args; loc = ploc } ->
        (match List.assoc_opt pred fact_map with
         | Some param_bindings ->
           let explicit_params = take_prefix (max 0 (List.length param_bindings - 1)) param_bindings in
           let expected_args = List.length explicit_params in
           let n_args = List.length args in
           if n_args <> expected_args then
             let explicit_names = List.map (fun (b : binding) -> b.name) explicit_params in
             let hint =
               match explicit_names with
               | [] ->
                 Printf.sprintf
                   "entity-side `?` proof `%s` takes no explicit subjects here; write `%s` and let the returned entity be implicit"
                   pred pred
               | _ ->
                 Printf.sprintf
                   "entity-side `?` proof `%s` takes %d explicit subject%s here; write `%s %s` and let the returned entity be implicit"
                   pred expected_args (if expected_args = 1 then "" else "s") pred
                   (String.concat " " explicit_names)
             in
             errors := make_error ploc ~hint
               (Printf.sprintf
                  "entity-side `?` proof `%s`: argument count mismatch — expected %d explicit argument%s before the returned entity, got %d"
                  pred expected_args (if expected_args = 1 then "" else "s") n_args)
               :: !errors
           else
             List.iter2 (fun (param : binding) arg_name ->
               let use_loc = if ploc.start.col > 0 || ploc.start.line > 0 then ploc else loc in
               if String.contains arg_name '.' then
                 errors := make_error use_loc
                   ~hint:"bind the value to a local variable first, then use that variable in the entity-side `?` proof"
                   (Printf.sprintf
                      "entity-side `?` proof subject '%s' is not a valid GDP subject — dotted paths are not trackable"
                      arg_name)
                   :: !errors
               else if is_simple_proof_subject arg_name then
                 (match List.assoc_opt arg_name local_env with
                  | None ->
                    errors := make_error use_loc
                      ~hint:"use a function parameter or local variable name here; the returned entity itself is implicit in `?` proofs"
                      (Printf.sprintf
                         "entity-side `?` proof subject `%s` is not in scope"
                         arg_name)
                      :: !errors
                  | Some actual_key ->
                    (match param.type_expr with
                     | TVar _ -> ()
                     | decl_ty ->
                       let decl_key = type_key decl_ty in
                       if actual_key <> decl_key then
                         errors := make_error use_loc
                           ~hint:(Printf.sprintf
                             "entity-side `?` proof `%s` expects `%s: %s`, but `%s` has type `%s`"
                             pred param.name decl_key arg_name actual_key)
                           (Printf.sprintf
                             "entity-side `?` proof `%s %s`: argument `%s` has type `%s` but fact `%s` declares type `%s`"
                             pred (String.concat " " args) arg_name actual_key pred decl_key)
                           :: !errors))
               else ()) explicit_params args
         | None -> ())
      | PredAnd { left; right; _ } ->
        check_entity_proof local_env loc left;
        check_entity_proof local_env loc right
    in
    (* Check proof annotations in a return spec *)
    let rec check_ret_spec local_env (spec : return_spec) =
      match spec with
      | RetAttached { binding = b; loc } ->
        Option.iter (check_proof local_env loc) b.proof_ann
      | RetForAll { proof; loc; _ }
      | RetMaybeForAll { proof; loc; _ }
      | RetSetForAll { proof; loc; _ }
      | RetMaybeSetForAll { proof; loc; _ }
      | RetForAllDictValues { proof; loc; _ }
      | RetForAllDictKeys   { proof; loc; _ } ->
        (* ForAll inner predicate: zero-arg usage is valid (the element is implicit) *)
        check_proof ~forall_inner:true local_env loc proof
      | RetMaybeAttached { binding = b; loc; _ } ->
        Option.iter (check_proof local_env loc) b.proof_ann
      | RetNamedPack { entity_proof; other_proof; loc; _ } ->
        Option.iter (check_entity_proof local_env loc) entity_proof;
        Option.iter (check_proof local_env loc) other_proof
      | RetExists { binding = b; body; _ } ->
        Option.iter (check_proof local_env b.loc) b.proof_ann;
        check_ret_spec local_env body
      | RetPlain _ -> ()
    in
    (* Walk an expression looking for ok ::: proof sites and let bindings *)
    let rec walk_expr local_env (e : expr) =
      match e with
      | EOk { value; proof; loc } ->
        check_proof local_env loc proof;
        walk_expr local_env value
      | ELet { name; declared_type; value; body; _ } ->
        walk_expr local_env value;
        let env' = match declared_type with
          | Some ty -> (name, type_key ty) :: local_env
          | None -> local_env
        in
        walk_expr env' body
      | ELetProof { value; body; _ } ->
        walk_expr local_env value;
        walk_expr local_env body
      | EIf { cond; then_; else_; _ } ->
        walk_expr local_env cond; walk_expr local_env then_; walk_expr local_env else_
      | ECase { scrut; arms; _ } ->
        walk_expr local_env scrut;
        List.iter (fun (arm : case_arm) -> walk_expr local_env arm.body) arms
      | EApp { fn; arg; _ } -> walk_expr local_env fn; walk_expr local_env arg
      | EBinop { left; right; _ } -> walk_expr local_env left; walk_expr local_env right
      | EUnop { arg; _ } -> walk_expr local_env arg
      | EField { obj; _ } -> walk_expr local_env obj
      | ERecord { fields; _ } -> List.iter (fun (_, v) -> walk_expr local_env v) fields
      | EList { elems; _ } -> List.iter (walk_expr local_env) elems
      | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
      | EWithTransaction { body; _ } -> walk_expr local_env body
      | ELambda { body; _ } -> walk_expr local_env body
      | ETelemetry { fields; _ } -> List.iter (fun (_, v) -> walk_expr local_env v) fields
      | EEnqueue { payload; _ } -> walk_expr local_env payload
      | EPublish { key; payload; _ } ->
        Option.iter (walk_expr local_env) key;
        Option.iter (walk_expr local_env) payload
      | ELit _ | EVar _ | EConstructor _ | EFail _ | EStartWorkers _ | EServe _ -> ()
      | ECacheGet { key; _ } -> walk_expr local_env key
      | ECacheSet { key; value; ttl; _ } ->
        walk_expr local_env key; walk_expr local_env value;
        Option.iter (walk_expr local_env) ttl
      | ECacheDelete { key; _ } -> walk_expr local_env key
      | ECacheInvalidate { prefix; _ } -> walk_expr local_env prefix
      | ESendEmail { to_; subject; body; _ } ->
        walk_expr local_env to_; walk_expr local_env subject;
        walk_expr local_env body
      | EStartEmailWorker _ -> ()
      | ERuntimeCall { segments; _ } ->
        List.iter (function RLit _ -> () | RArg e -> walk_expr local_env e) segments
    in
    List.iter (function
      | DFunc fd ->
        (* Build local env from all parameter bindings *)
        let local_env = List.filter_map (fun (b : binding) ->
          match b.type_expr with
          | TVar _ -> None
          | ty -> Some (b.name, type_key ty)
        ) fd.params in
        (* Extend env with return binding name if present (for RetAttached) *)
        let local_env = match fd.return_spec with
          | RetAttached { binding = b; _ } ->
            (match b.type_expr with TVar _ -> local_env | ty -> (b.name, type_key ty) :: local_env)
          | _ -> local_env
        in
        (* Check parameter proof annotations *)
        List.iter (fun (b : binding) ->
          Option.iter (check_proof local_env b.loc) b.proof_ann
        ) fd.params;
        (* Check return spec *)
        check_ret_spec local_env fd.return_spec;
        (* Walk body for ok ::: proof sites *)
        walk_expr local_env fd.body
      | _ -> ()
    ) decls;
    List.rev !errors
  end

(* ── Type arity / kind checking ──────────────────────────────────────────── *)

(** Arities for known parameterized type constructors. User-defined ADT params
    are added dynamically in [check_type_arities]. *)
let stdlib_type_arities : (string * int) list = [
  "List",   1;
  "Maybe",  1;
  "Set",    1;
  "Dict",   2;
  "Either", 2;
  "Tuple2", 2;
  "Tuple3", 3;
]

(** Walk a [type_expr] and emit errors for bare (unapplied) parameterized
    type constructors.  [go_arg] is called for nodes in argument/top-level
    position (must be fully applied); [go_head n] is called for nodes in head
    position of [n] already-applied TApp layers. *)
let check_type_arity_te (arity_tbl : (string * int) list) (te : Ast.type_expr) : validation_error list =
  let errors = ref [] in
  let err loc msg = errors := make_error loc msg :: !errors in
  let rec go_arg te =
    match te with
    | Ast.TName { name; loc } ->
      let n = try List.assoc name arity_tbl with Not_found -> 0 in
      if n > 0 then
        err loc (Printf.sprintf
          "type `%s` requires %d type argument(s); \
           write e.g. `%s %s` or use a type variable like `%s a`"
          name n name
          (String.concat " " (List.init n (fun i ->
             String.make 1 (Char.chr (Char.code 'a' + i)))))
          name)
    | Ast.TVar _ -> ()
    | Ast.TApp { head; arg; _ } -> go_head head 1; go_arg arg
    | Ast.TFun { dom; cod; _ } -> go_arg dom; go_arg cod
    | Ast.TTuple { elems; _ } -> List.iter go_arg elems
  and go_head te n_applied =
    match te with
    | Ast.TName { name; loc } ->
      let expected = try List.assoc name arity_tbl with Not_found -> 0 in
      let remaining = expected - n_applied in
      if remaining > 0 then
        err loc (Printf.sprintf
          "type `%s` requires %d type argument(s) but only %d given"
          name expected n_applied)
    | Ast.TApp { head; arg; _ } -> go_head head (n_applied + 1); go_arg arg
    | _ -> ()
  in
  go_arg te;
  List.rev !errors

let check_type_arities (decls : top_decl list) : validation_error list =
  (* Build arity table: stdlib + user-defined parameterized ADTs *)
  let user_arities = List.filter_map (fun d ->
    match d with
    | DType (TypeAdt { name; params; _ }) when params <> [] ->
      Some (name, List.length params)
    | _ -> None
  ) decls in
  let arity_tbl = stdlib_type_arities @ user_arities in
  let check_te te = check_type_arity_te arity_tbl te in
  let check_ret rs =
    match rs with
    | RetPlain { ty; _ }            -> check_te ty
    | RetAttached { binding = b; _ }-> check_te b.type_expr
    | RetNamedPack { ty; _ }        -> check_te ty
    | RetForAll { elem_ty; _ }      -> check_te elem_ty
    | RetMaybeForAll { elem_ty; _ } -> check_te elem_ty
    | RetSetForAll { elem_ty; _ }   -> check_te elem_ty
    | RetMaybeSetForAll { elem_ty; _ } -> check_te elem_ty
    | RetForAllDictValues { key_ty; val_ty; _ }
    | RetForAllDictKeys   { key_ty; val_ty; _ } -> check_te key_ty @ check_te val_ty
    | _ -> []
  in
  List.concat_map (fun d ->
    match d with
    | DFunc fd ->
      let param_errs = List.concat_map (fun (b : binding) ->
        check_te b.type_expr) fd.params in
      let ret_errs = check_ret fd.return_spec in
      param_errs @ ret_errs
    | DType (TypeAdt { variants; _ }) ->
      List.concat_map (fun (v : adt_variant) ->
        List.concat_map (fun (f : field_def) ->
          check_te f.type_expr) v.fields) variants
    | DType (TypeNewtype { base_type; _ }) -> check_te base_type
    | _ -> []
  ) decls

(** Check that the ordering operators (<, <=, >, >=) are only applied to
    types that support a meaningful total order: Int, Float, PosixMillis, and
    any nominal type (type alias or newtype) whose declared base type resolves
    to one of those three through a chain of such declarations. *)
let check_ord_operator_types ?facts ?(extra_funcs=[]) (decls : top_decl list) : validation_error list =
  let mf = facts_or_compute ?facts ~extra_funcs decls in
  let funcs = mf.mf_funcs in
  let fields_by_type = mf.mf_fields_map in
  let ctors = mf.mf_ctors in
  (* Map: nominal type name -> declared base type_expr *)
  let alias_map : (string * type_expr) list =
    List.filter_map (function
      | DType (TypeNewtype { name; base_type; _ })
      | DType (TypeAlias   { name; base_type; _ }) -> Some (name, base_type)
      | _ -> None
    ) decls
  in
  let orderable_bases = ["Int"; "Float"; "PosixMillis"] in
  (* Resolve through alias/newtype chains to check orderability *)
  let rec is_orderable (seen : string list) (ty : type_expr) : bool =
    match ty with
    | TVar _ -> true  (* Generic type variable — can't determine at checking time; trust HM *)
    | TName { name; _ } ->
      List.mem name orderable_bases ||
      (not (List.mem name seen) &&
       match List.assoc_opt name alias_map with
       | Some base -> is_orderable (name :: seen) base
       | None -> false)
    | _ -> false
  in
  let ord_op_name = function
    | BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">=" | _ -> "?"
  in
  let rec walk_expr (env : type_env) (e : expr) : validation_error list =
    match e with
    | EBinop { op = (BLt | BLe | BGt | BGe) as op; left; right; loc } ->
      let child_errs = walk_expr env left @ walk_expr env right in
      let ord_errs =
        (* SQL DSL: `select p from T where p.field > val` is parsed as
           EBinop(BGt, select_chain, val).  The comparison operator is SQL predicate
           syntax here, not a Tesl ordering comparison.  Skip the check. *)
        if infer_sql_aggregate_type e <> None then []
        else
          match infer_expr_type env funcs fields_by_type ctors left with
          | Some ty when is_orderable [] ty -> []
          | Some ty ->
            [ make_error loc
                ~hint:(Printf.sprintf
                  "only Int, Float, PosixMillis, and nominal types derived from them \
                   support `%s`; consider comparing a numeric representation instead"
                  (ord_op_name op))
                (Printf.sprintf
                  "ordering operator `%s` is not defined for type `%s`"
                  (ord_op_name op) (type_key ty)) ]
          | None -> []  (* cannot infer type — do not block *)
      in
      child_errs @ ord_errs
    | ELet { name; value; body; _ } ->
      let child_errs = walk_expr env value in
      let env' = match infer_expr_type env funcs fields_by_type ctors value with
        | Some ty -> (name, ty) :: env
        | None -> env
      in
      child_errs @ walk_expr env' body
    | ELetProof { value_name; value; body; _ } ->
      let child_errs = walk_expr env value in
      let env' = match infer_expr_type env funcs fields_by_type ctors value with
        | Some ty -> (value_name, ty) :: env
        | None -> env
      in
      child_errs @ walk_expr env' body
    | EIf { cond; then_; else_; _ } ->
      walk_expr env cond @ walk_expr env then_ @ walk_expr env else_
    | ECase { scrut; arms; _ } ->
      let scrut_ty = infer_expr_type env funcs fields_by_type ctors scrut in
      walk_expr env scrut
      @ List.concat_map (fun (arm : case_arm) ->
          let env' = pattern_bindings scrut_ty ctors arm.pattern @ env in
          walk_expr env' arm.body
        ) arms
    | EApp _ ->
      let (_, args) = collect_call_head_and_args [] e in
      List.concat_map (walk_expr env) args
    | EOk { value; _ } -> walk_expr env value
    | ELambda { params; body; _ } ->
      let env' = List.map (fun (b : binding) -> (b.name, b.type_expr)) params @ env in
      walk_expr env' body
    | EBinop { left; right; _ } -> walk_expr env left @ walk_expr env right
    | EUnop { arg; _ } -> walk_expr env arg
    | EList { elems; _ } -> List.concat_map (walk_expr env) elems
    | ERecord { fields; _ } -> List.concat_map (fun (_, v) -> walk_expr env v) fields
    | ETelemetry { fields; _ } -> List.concat_map (fun (_, v) -> walk_expr env v) fields
    | EEnqueue { payload; _ } -> walk_expr env payload
    | EPublish { key; payload; _ } ->
      (match key with Some e -> walk_expr env e | None -> [])
      @ (match payload with Some e -> walk_expr env e | None -> [])
    | EWithDatabase { body; _ }
    | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> walk_expr env body
    | EServe { port; _ } -> walk_expr env port
    | EStartWorkers _ | ELit _ | EVar _ | EField _
    | EFail _ | EConstructor _ -> []
    | ECacheGet { key; _ } -> walk_expr env key
    | ECacheSet { key; value; ttl; _ } ->
      walk_expr env key @ walk_expr env value
      @ (match ttl with Some e -> walk_expr env e | None -> [])
    | ECacheDelete { key; _ } -> walk_expr env key
    | ECacheInvalidate { prefix; _ } -> walk_expr env prefix
    | ESendEmail { to_; subject; body; _ } ->
      walk_expr env to_ @ walk_expr env subject @ walk_expr env body
    | EStartEmailWorker _ -> []
    | ERuntimeCall { segments; _ } ->
      List.concat_map (function RLit _ -> [] | RArg e -> walk_expr env e) segments
  in
  let rec walk_test_stmts (env : type_env) (stmts : test_stmt list)
      : validation_error list =
    let (errs, _) = List.fold_left (fun (acc, env) stmt ->
      match stmt with
      | TsLetProof { value_name = name; value; _ } ->
        let e = walk_expr env value in
        let env' = (name, TName { name = "Any"; loc = dummy_loc "" }) :: env in
        (acc @ e, env')
      | TsLet { name; value; _ } ->
        let e = walk_expr env value in
        let env' = match infer_expr_type env funcs fields_by_type ctors value with
          | Some ty -> (name, ty) :: env
          | None -> env
        in
        (acc @ e, env')
      | TsExpect { left; right; _ } ->
        let e = walk_expr env left
                @ (match right with Some r -> walk_expr env r | None -> []) in
        (acc @ e, env)
      | TsExpectFail { fn; arg; _ }
      | TsExpectHasProof { fn; arg; _ } ->
        (acc @ walk_expr env fn @ walk_expr env arg, env)
      | TsProperty { body; _ } ->
        (acc @ walk_expr env body, env)
      | TsIf { cond; then_stmts; else_stmts; _ } ->
        let e = walk_expr env cond
                @ walk_test_stmts env then_stmts
                @ walk_test_stmts env else_stmts in
        (acc @ e, env)
      | TsCase { scrut; arms; _ } ->
        let e = walk_expr env scrut
                @ List.concat_map (fun (arm : Ast.ts_case_arm) ->
                    (match arm.ts_guard with Some g -> walk_expr env g | None -> [])
                    @ walk_test_stmts env arm.ts_body
                  ) arms in
        (acc @ e, env)
      | TsExpr { e; _ } ->
        (acc @ walk_expr env e, env)
    ) ([], env) stmts
    in errs
  in
  List.concat_map (function
    | DFunc fd ->
      let env = List.map (fun (b : binding) -> (b.name, b.type_expr)) fd.params in
      walk_expr env fd.body
    | DTest tf ->
      walk_test_stmts [] tf.stmts
    | DApiTest atf ->
      List.concat_map (walk_expr []) atf.seed_stmts
      @ walk_test_stmts [] atf.stmts
    | DLoadTest ltf ->
      List.concat_map (walk_expr []) ltf.seed_stmts
      @ walk_test_stmts [] ltf.request_stmts
    | _ -> []
  ) decls

(* ── 3b. Record field proof enforcement at construction sites ─────────────── *)

(** Build a map from record name → list of (field_name, binding) for fields
    that have proof annotations.  The binding uses the field name as the
    parameter name so [check_call_proofs] can substitute it with the actual
    argument's subject at construction time. *)
