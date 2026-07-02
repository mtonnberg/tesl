open Ast
open Location
open Validation_common

let build_func_capability_map (decls : top_decl list) : (string * string list) list =
  List.filter_map (function
    | DFunc fd ->
      (* Drop this function's capability-ROW variables: when the function is
         CALLED, its row variables are instantiated by the actual callback
         arguments (which the caller's body walks separately, collecting their
         caps).  Only its CONCRETE capabilities propagate to callers. *)
      let bound = Ast.func_bound_cap_vars fd in
      Some (fd.name, List.filter (fun c -> not (List.mem c bound)) fd.capabilities)
    | _ -> None
  ) decls

(** Capability rows introduced by a function's function-typed parameters:
    `f: (A -> B requires c)` ⇒ `("f", ["c"])`.  Calling such a parameter in the
    body requires its row variable(s), which the enclosing function must declare. *)
let build_param_capability_map (fd : func_decl) : (string * string list) list =
  List.filter_map (fun (b : binding) ->
    match func_bound_cap_vars_of_params [b] with
    | [] -> None
    | caps -> Some (b.name, caps)
  ) fd.params

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
    ?(param_caps : (string * string list) list = [])
    ?(bound : string list = [])
    (e : expr)
    : string list =
  (* CAP-A1 fix: read/write classification comes from the single SQL registry
     (Validation_common) so it cannot drift from the set the emitter lowers to
     DB calls.  The old inline write-set omitted insertMany/updateAndReturnOne/
     deleteAndReturnResult, statically inferring no dbWrite for handlers that
     used them — a real capability-soundness hole. *)
  (* var_caps: the capability(ies) a bare referenced name introduces, given the
     names [bound] in lexical scope at the use site (a bound name shadows the
     builtin and introduces nothing). *)
  let var_caps bound name =
    (* A function-typed PARAMETER (`f: (A -> B requires c)`) shadows everything:
       calling it requires its capability-row variable(s), which the enclosing
       function declares in its own `requires`. *)
    if List.mem_assoc name param_caps then
      (match List.assoc_opt name param_caps with Some caps -> caps | None -> [])
    else
    (* BUG-1 fix: Check user-defined functions FIRST.
       A user function named `insert`, `select`, `update`, or `delete` must NOT be
       treated as a SQL operation. `List.mem_assoc` returns true even for functions
       with empty capabilities (requires []), correctly shadowing the SQL keywords. *)
    if List.mem_assoc name func_caps then
      (match List.assoc_opt name func_caps with
       | Some caps -> caps
       | None -> [])
    (* A plain local binding (value param, let, lambda/case binder) named like a
       stdlib effect function (env/nowMillis/randomInt/…) SHADOWS it and introduces
       NO capability — checked after param_caps/func_caps so function-typed params
       and user functions keep their own rows. *)
    else if List.mem name bound then []
    else if is_sql_read_builtin name then ["dbRead"]
    else if is_sql_write_builtin name then ["dbWrite"]
    (* A2-3: every other effect→capability decision is DERIVED from the single
       source of truth in type_system (queue/time/random/env/jwt/httpClient/uuid/
       aiProvider). SQL stays structural above because a user fn may legitimately
       shadow those keyword spellings. Pure stdlib fns (PosixMillis arithmetic,
       constructors, accessors) are absent from the registry → []. *)
    else Type_system.stdlib_capabilities_of name
  in
  (* Names bound by a pattern (PVar / nested PCon fields) — the per-arm binder
     set, mirroring what the old fn_bound_names collected for the whole function. *)
  let rec pat_names acc = function
    | PVar n -> n :: acc
    | PCon { fields; _ } -> List.fold_left (fun acc (_, p) -> pat_names acc p) acc fields
    | _ -> acc
  in
  (* acc is threaded left-to-right; result order is irrelevant (caller sort_uniqs).
     [bound] is the set of names in LEXICAL scope at this expression — the
     function parameters plus the let / let-proof / lambda / case binders of
     ENCLOSING scopes.  A name in [bound] shadows the stdlib effect/SQL builtin
     of the same name ONLY within the scope it is bound in.  This is the fix for
     the `requires []` capability-suppression hole: previously every binder
     anywhere in the function (e.g. a `delete` bound in one case arm) suppressed
     the capability function-wide, so a binder in a disjoint scope could hide a
     real effect.  Threading [bound] lexically makes the capability checker agree
     with the typechecker's own scoping (checker.ml routes a name to the SQL/
     builtin path only when it is NOT locally bound). *)
  let rec go (bound : string list) (acc : string list) (e : expr) : string list =
    match e with
    | EVar { name; _ } -> var_caps bound name @ acc
    (* A qualified stdlib call `M.f` (JWT.sign, HttpClient.get, UUID.v4/v7, …) parses
       as an EField on the module-name constructor/var. Charge its capability from
       the SINGLE-SOURCE registry (A2-3) — this is what makes `UUID.v7()` require the
       `uuid` capability (CAP-UUID) without a second hand-list. The module-name obj
       carries no further capability, so it is not recursed into. Non-capability
       field accesses (record fields, etc.) map to [] and fall through below. *)
    | EField { obj = (EConstructor { name = m; _ } | EVar { name = m; _ }); field; _ }
      when Type_system.stdlib_capabilities_of (m ^ "." ^ field) <> [] ->
      Type_system.stdlib_capabilities_of (m ^ "." ^ field) @ acc
    (* Effect forms: prepend the fixed data-table token, then descend into
       children via the shared traversal. *)
    | EEnqueue _ | EPublish _ | ETelemetry _ | ESendEmail _ ->
      let key = match e with
        | EEnqueue _ -> "EEnqueue" | EPublish _ -> "EPublish"
        | ETelemetry _ -> "ETelemetry" | _ -> "ESendEmail" in
      Ast_visitor.fold_children_env go bound (effect_caps key @ acc) e
    | EStartEmailWorker _ ->
      (* CAP-4 fix: descend into child exprs after prepending the fixed token,
         exactly like the EEnqueue/EPublish/ETelemetry/ESendEmail arm above — a
         child expression can itself carry effects and must be walked. *)
      Ast_visitor.fold_children_env go bound (effect_caps "EStartEmailWorker" @ acc) e
    (* CAP-1 fix: EConstructor is NO LONGER a no-capability leaf.  The previous
       explicit `EConstructor _ -> acc` arm dropped constructor ARGUMENTS, so an
       effect wrapped in a built-in args-carrying constructor (e.g.
       `Something (insert ...)`, `Something (env key)`) escaped capability
       analysis entirely.  By removing the arm, EConstructor now falls through to
       the shared `_ -> Ast_visitor.fold_children_env ...` catch-all below, which
       walks its args identically to every other node.  (The JWT/HttpClient
       `EField { obj = EConstructor ... }` arms above still match first and are
       unaffected — they match EField, not a bare EConstructor.) *)
    (* Binder forms: extend [bound] with the names each binder introduces, but
       ONLY for the sub-scope that binder governs (value exprs are evaluated in
       the enclosing scope; bodies/arms see the new name). *)
    | ELet { name; value; body; _ } ->
      let acc = go bound acc value in
      go (name :: bound) acc body
    | ELetProof { value_name; proof_name; value; body; _ } ->
      let acc = go bound acc value in
      go (value_name :: proof_name :: bound) acc body
    | ELambda { params; body; _ } ->
      go (List.map (fun (b : binding) -> b.name) params @ bound) acc body
    (* ECase descends into the scrutinee, each arm GUARD, and each arm BODY.
       B-GUARD-CAP-ESCAPE (review §5.2): the arm guard was previously skipped on
       the unenforced assumption "guards are pure boolean tests", so a privileged
       effect hidden in a `where` guard (e.g. a `deleteAndReturnResult`, an `env`
       read) escaped the capability charge entirely — a read-only handler could
       write undeclared.  The guard is an ordinary expression that runs at request
       time, so it must be folded exactly like the body.  Both see the arm's
       pattern binders. *)
    | ECase { scrut; arms; _ } ->
      let acc = go bound acc scrut in
      List.fold_left (fun acc (arm : case_arm) ->
        let arm_bound = pat_names bound arm.pattern in
        let acc = match arm.guard with Some g -> go arm_bound acc g | None -> acc in
        go arm_bound acc arm.body) acc arms
    (* Cache forms: data-dependent token, then descend into key/value/ttl/prefix. *)
    | ECacheGet { cache_name; _ } | ECacheSet { cache_name; _ }
    | ECacheDelete { cache_name; _ } | ECacheInvalidate { cache_name; _ } ->
      Ast_visitor.fold_children_env go bound (("cacheCap " ^ cache_name) :: acc) e
    (* Purely-mechanical variants: descend into child exprs in the same scope.
       Includes EField (non-special obj), EApp, EBinop, EUnop, EIf, ERecord,
       EList, EOk, EWithDatabase/EWithCapabilities/EWithTransaction, EServe, and
       the no-capability leaves (ELit, EFail, EStartWorkers). *)
    | _ -> Ast_visitor.fold_children_env go bound acc e
  in
  go bound [] e

(* (Removed fn_bound_names: the function-wide bound-name set it produced was the
   root of the `requires []` capability-suppression hole — a binder in any
   disjoint scope suppressed a capability everywhere.  collect_needed_capabilities
   now threads `bound` lexically, seeded with the function parameters at the call
   site below.) *)

(* ── Fix C: env read reached through a database config block ──────────────── *)

(** Does an expression read the environment (env / envInt / envString /
    requireEnv)?  Used both for a function body and for the `= … { }` config of
    a declarative block, so the env-read discipline ([envRead]) is uniform
    regardless of how the env read is reached. *)
let expr_reads_env (e : expr) : bool =
  let found = ref false in
  let rec go e =
    (match e with
     | EVar { name; _ }
       when List.mem name ["env"; "envInt"; "envString"; "requireEnv"] -> found := true
     | _ -> ());
    ignore (Ast_visitor.fold_children (fun () e -> go e; ()) () e)
  in
  go e; !found

(** Does ANY declarative config block — database / queue / email / cache /
    agent — read the environment in its `= … { }` config?  Every such block
    initializes at app STARTUP, i.e. when [main] runs, so a module's [main]
    performs that env read transitively and must declare [envRead].  This is
    uniform across block kinds: the database block was only the motivating
    example.  (Per-module, like every other capability check: a library that
    declares env-reading config but has no [main] relies on the importing app's
    [main] to carry the requirement.) *)
let module_config_reads_env (decls : top_decl list) : bool =
  List.exists (function
    | DDatabase { config_expr = Some e; _ }
    | DQueue    { config_expr = Some e; _ }
    | DEmail    { config_expr = Some e; _ }
    | DCache    { config_expr = Some e; _ }
    | DAgent    { config_expr = Some e; _ } -> expr_reads_env e
    | _ -> false
  ) decls

(** Per-kind capability-error reporting metadata.  Every [func_kind] is now
    capability-checked: check/auth/establish each get their OWN runtime
    capability boundary (emit_racket emits `#:capabilities` for their declared
    `requires`), so a privileged operation in their body must be covered by
    their own declared row — identical treatment to [fn].  This closes the
    compile-time effect-laundering hole (a `check`/`auth`/`establish` body could
    previously perform e.g. a dbWrite that the ambient whole-app union satisfied
    at runtime, with no static declaration).  The message text for the four
    effecting kinds is preserved verbatim (snapshot tests pin it); [MainKind]
    gets its own env-honesty wording.

    This match is intentionally EXHAUSTIVE (no `_ ->` wildcard): a future new
    [func_kind] becomes a non-exhaustive-match COMPILE error here rather than a
    silent capability-check skip (enforced-by-construction). *)
let cap_check_kind_info (k : func_kind) : (string * (string -> string -> string)) option =
  match k with
  | HandlerKind    -> Some ("handler",
      fun n caps -> Printf.sprintf
        "handler '%s' uses [%s] but does not declare the required capabilities" n caps)
  | WorkerKind     -> Some ("worker",
      fun n caps -> Printf.sprintf
        "worker '%s' uses [%s] but does not declare the required capabilities" n caps)
  | FnKind         -> Some ("fn",
      fun n caps -> Printf.sprintf
        "fn '%s' uses privileged operations and callees requiring [%s] but does not declare them" n caps)
  | CheckKind      -> Some ("check",
      fun n caps -> Printf.sprintf
        "check '%s' uses privileged operations and callees requiring [%s] but does not declare them" n caps)
  | AuthKind       -> Some ("auth",
      fun n caps -> Printf.sprintf
        "auth '%s' uses privileged operations and callees requiring [%s] but does not declare them" n caps)
  | EstablishKind  -> Some ("establish",
      fun n caps -> Printf.sprintf
        "establish '%s' uses privileged operations and callees requiring [%s] but does not declare them" n caps)
  | DeadWorkerKind -> Some ("deadWorker",
      fun n caps -> Printf.sprintf
        "deadWorker '%s' uses [%s] but does not declare the required capabilities" n caps)
  | MainKind       -> Some ("main",
      fun n caps -> Printf.sprintf
        "main '%s' reads the environment (directly or through a declarative config block) \
         but does not declare the required capability [%s]" n caps)

let check_handler_capabilities ?(cap_map=[]) ?(imported_func_caps=[]) (decls : top_decl list) : validation_error list =
  (* Local callee→caps first (a local name shadows an imported one); then
     imported functions' declared `requires`, so a transitive call into an
     imported effecting function is enforced across the module boundary. *)
  let func_caps = build_func_capability_map decls @ imported_func_caps in
  let config_reads_env = module_config_reads_env decls in
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
    | DFunc fd ->
      (match cap_check_kind_info fd.kind with
       | None -> ()  (* total-match safety net: no func_kind returns None today
                        (every kind is capability-checked); kept so the outer
                        match stays total if a future kind ever opts out. *)
       | Some (label, msg) ->
         let needed =
           match fd.kind with
           | MainKind ->
             (* main is the capability BOUNDARY: its body is lowered to run inside
                `with capabilities main_caps { with database … }`, so the full
                transitive check is the scope's job, not main's `requires`.  The
                one effect the scope does not grant is reading the environment, so
                main must still declare [envRead] when it reads env — directly in
                its body, or transitively because a declarative config block it
                starts up reads env (Fix C, uniform across all block kinds). *)
             if expr_reads_env fd.body || config_reads_env
             then ["envRead"] else []
           | _ ->
             let param_caps = build_param_capability_map fd in
             (* Seed [bound] with the function parameters (in scope for the whole
                body); collect_needed_capabilities extends it lexically per inner
                binder so a disjoint binder can no longer suppress a capability. *)
             collect_needed_capabilities ~func_caps ~param_caps
               ~bound:(List.map (fun (b : binding) -> b.name) fd.params) fd.body
             |> List.sort_uniq String.compare
         in
         let declared = fd.capabilities in
         let missing = List.filter (fun cap -> not (cap_covered declared cap)) needed in
         if missing <> [] then
           errors := make_error fd.loc
             ~hint:(Printf.sprintf "add `requires [%s]` to the %s declaration"
                      (String.concat ", " missing) label)
             (msg fd.name (String.concat ", " missing))
             :: !errors)
    | _ -> ()
  ) decls;
  (* ── CAP-COMPOSE (review 2026-07) ──────────────────────────────────────────
     The App root (`main`) grants expand(main.requires) app-wide; every wired
     handler/worker runs inside `with capabilities main_caps`.  A handler/worker
     requiring a capability `main` does NOT grant compiles clean but 500s at
     runtime ("Missing capabilities").  Verify at compile time that main's grant
     covers every handler/worker/queue reachable from the App main returns.
     Reachability is taken from the App record's `api:` server (endpoint→handler
     bindings) and its `queues:` list (workers + folded requires), so an unused
     declaration is never flagged — matching the runtime, which only runs wired
     units.  The check compares expand(unit) ⊆ expand(main), exactly the runtime
     condition, so there are no false positives against the capability lattice. *)
  (match List.find_opt (function DFunc fd -> fd.kind = MainKind | _ -> false) decls with
   | Some (DFunc main_fd) ->
     let main_grant = expand_declared main_fd.capabilities in
     let is_granted c = List.mem c main_grant in
     let fn_info = List.filter_map (function
       | DFunc fd -> Some (fd.name, (fd.capabilities, fd.loc)) | _ -> None) decls in
     let servers = List.filter_map (function
       | DServer s -> Some (s.name, List.map snd s.bindings) | _ -> None) decls in
     let workers_by_queue = List.filter_map (function
       | DWorkers w -> Some (w.queue_name, List.map snd w.bindings) | _ -> None) decls in
     let queue_caps = List.filter_map (function
       | DQueue q -> Some (q.name, (q.capabilities, q.loc)) | _ -> None) decls in
     let rec collect_apps (e : expr) : expr list =
       let here = match e with
         | ERecord { fields; _ } when List.mem_assoc "api" fields -> [e] | _ -> [] in
       here @ Ast_visitor.fold_children (fun acc c -> acc @ collect_apps c) [] e in
     let apps = collect_apps main_fd.body in
     (* A server/queue/db reference is a NAME: capitalized identifiers parse as a
        nullary EConstructor, lowercase ones as EVar — accept both. *)
     let name_of = function
       | EVar { name; _ } -> Some name
       | EConstructor { name; args = []; _ } -> Some name
       | _ -> None in
     let referenced field = List.concat_map (fun app -> match app with
       | ERecord { fields; _ } ->
         (match List.assoc_opt field fields with
          | Some (EList { elems; _ }) -> List.filter_map name_of elems
          | Some e -> (match name_of e with Some n -> [n] | None -> [])
          | None -> [])
       | _ -> []) apps in
     let api_servers = referenced "api" in
     let app_queues = referenced "queues" in
     let handler_fns =
       List.concat_map (fun sn -> match List.assoc_opt sn servers with
         | Some hs -> hs | None -> []) api_servers |> List.sort_uniq String.compare in
     let worker_fns =
       List.concat_map (fun qn -> match List.assoc_opt qn workers_by_queue with
         | Some ws -> ws | None -> []) app_queues |> List.sort_uniq String.compare in
     let report kind name requires loc =
       let missing =
         List.filter (fun c -> not (is_granted c)) (expand_declared requires)
         |> List.sort_uniq String.compare in
       if missing <> [] then
         errors := make_error loc
           ~hint:(Printf.sprintf
             "add [%s] to `main`'s `requires` (or to a capability `main` grants), or remove it from %s `%s`"
             (String.concat ", " missing) kind name)
           (Printf.sprintf
             "%s `%s` requires [%s], but the App root (`main`) does not grant %s; \
              every wired %s runs under main's granted capabilities, so this fails at \
              runtime with \"Missing capabilities\""
             kind name (String.concat ", " missing)
             (if List.length missing = 1 then "it" else "them") kind)
           :: !errors
     in
     List.iter (fun h -> match List.assoc_opt h fn_info with
       | Some (reqs, loc) -> report "handler" h reqs loc | None -> ()) handler_fns;
     List.iter (fun w -> match List.assoc_opt w fn_info with
       | Some (reqs, loc) -> report "worker" w reqs loc | None -> ()) worker_fns;
     List.iter (fun qn -> match List.assoc_opt qn queue_caps with
       | Some (caps, loc) -> report "queue" qn caps loc | None -> ()) app_queues
   | _ -> ());
  List.rev !errors

(** Extract BOTH sides of a `(Col == rhs)` proof argument string.
    E.g. "(Id == todoId)" → Some ("Id", "todoId");
         "(OwnerId == requestUser . id)" → Some ("OwnerId", "requestUser.id").

    The parser captures a parenthesized proof arg token-by-token with a space
    after each token (parser.ml:336-356), so a dotted field-access RHS arrives
    as three tokens `requestUser`, `.`, `id`.  We rejoin the post-`==` tokens
    with no separator so `requestUser . id` collapses back to `requestUser.id`,
    matching the dotted paths the parser already emits for field-access WHERE
    subjects. *)
let extract_col_eq_var (arg : string) : (string * string) option =
  let s = String.trim arg in
  let s = if String.length s > 1 && s.[0] = '(' && s.[String.length s - 1] = ')'
          then String.sub s 1 (String.length s - 2) |> String.trim
          else s in
  let parts = List.filter (fun p -> p <> "") (String.split_on_char ' ' s) in
  match parts with
  | col :: "==" :: rest when rest <> [] ->
    (* Rejoin so `requestUser . id` → `requestUser.id` and `todoId` → `todoId`. *)
    Some (col, String.concat "" rest)
  | _ -> None

(** Extract variable name from a `(Id == varName)` proof argument string.
    Retained as the RHS-only projection of {!extract_col_eq_var} so existing
    callers (e.g. {!check_insert_pk_match}) are unchanged. *)
let extract_id_eq_var (arg : string) : string option =
  Option.map snd (extract_col_eq_var arg)

(** Extract the variable from a FromDb proof's (Id == X) argument. *)
let fromdb_pk_var (proof : proof_expr) : string option =
  match proof with
  | PredApp { pred = "FromDb"; args = [arg]; _ } -> extract_id_eq_var arg
  | _ -> None

(** Extract the (column, rhs) pair from a FromDb proof, descending PredAnd to
    find the FromDb conjunct.  Covers both a bare `FromDb (Col == x)` and a
    compound proof such as `FromDb (Col == x) && IsOpen` (the listOpenTodos
    pattern), which a plain top-level PredApp match would silently skip.
    The rhs is returned even when it is a field access (`requestUser.id`); the
    caller unifies the COLUMN unconditionally and the SUBJECT by full dotted
    string. *)
let rec fromdb_col_var (proof : proof_expr) : (string * string) option =
  match proof with
  | PredApp { pred = "FromDb"; args = [arg]; _ } -> extract_col_eq_var arg
  | PredAnd { left; right; _ } ->
    (match fromdb_col_var left with
     | Some _ as r -> r
     | None -> fromdb_col_var right)
  | _ -> None

(** Render an expression as a dotted subject path, for comparing a SQL WHERE
    RHS against a proof subject: `EVar x` → "x", `EField x.f` → "x.f",
    `EField x.f.g` → "x.f.g".  Returns None for anything else (e.g. a literal). *)
let rec expr_dotted_subject (e : expr) : string option =
  match e with
  | EVar { name; _ } -> Some name
  | EField { obj; field; _ } ->
    (match expr_dotted_subject obj with
     | Some base -> Some (base ^ "." ^ field)
     | None -> None)
  | _ -> None

(** Check that SELECT WHERE conditions establish the FromDb provenance declared
    by a named-pack / ForAll return spec — matching BOTH the COLUMN (via the
    single {!Ir.entity_field_fact_name} field→column mapping, honoring an
    explicit `first_field_fact`) and the SUBJECT.

    E.g. `-> Task ? FromDb (Id == id)` requires `selectOne t from Task where
    t.id == id`; `-> List Msg ? ForAll (FromDb (RoomId == roomId))` requires the
    SELECT to filter `m.roomId == roomId`.

    Soundness (A1): the declared FromDb (column, subject) is unified against the
    resolved WHERE equality — a select fetching by the WRONG column (e.g. by
    `ownerId` while claiming `Id == todoId`), or a select with NO matching WHERE
    at all, is rejected (previously only the RHS variable spelling was checked,
    so a wrong-column or where-less select forged provenance).  The must-have-a-
    matching-WHERE requirement is scoped to select-derived grants: insert- and
    update-returning-derived FromDb grants (which have no select WHERE for the
    pk) are exempt (insert is owned by {!check_insert_pk_match}). *)
let check_pk_match (decls : top_decl list) : validation_error list =
  let fields_by_type = build_fields_map decls in
  (* field → column for a given entity, honoring first_field_fact via the single
     shared ir.ml mapping (do not re-implement the capitalize heuristic). *)
  let field_to_column (entity_name : string) (fname : string) : string =
    match record_fields_of_type fields_by_type (mk_name_type entity_name) with
    | Some efs ->
      (match List.find_opt (fun (f : field_def) -> f.name = fname) efs with
       | Some f -> Ir.entity_field_fact_name f
       | None -> String.capitalize_ascii fname)
    | None -> String.capitalize_ascii fname
  in
  let errors = ref [] in
  List.iter (function
    | DFunc fd when (fd.kind = FnKind || fd.kind = HandlerKind) ->
      (* Determine the declared FromDb (column, subject) from the return spec, and
         a label describing it for error messages. *)
      let where_spec = match fd.return_spec with
        | RetNamedPack { entity_proof = Some ep; _ } ->
          (match fromdb_col_var ep with
           | Some (col, rhs) -> Some (col, rhs, Printf.sprintf "%s == %s" col rhs)
           | None -> None)
        | RetForAll { proof; _ } | RetMaybeForAll { proof; _ } ->
          (match fromdb_col_var proof with
           | Some (col, rhs) ->
             Some (col, rhs, Printf.sprintf "FromDb (%s == %s) in ForAll" col rhs)
           | None -> None)
        | _ -> None
      in
      (match where_spec with
       | None -> ()
       | Some (expected_col, expected_rhs, spec_label) ->
         let param_names = List.map (fun (b : binding) -> b.name) fd.params in
         (* The declared subject: a bare param, or a field access on a param
            (e.g. requestUser.id).  Verify the subject root resolves to a
            parameter.  Skip this scope check for a dotted subject only when its
            root is a parameter (field-access subjects are legitimate). *)
         let subj_root =
           match String.index_opt expected_rhs '.' with
           | Some i -> String.sub expected_rhs 0 i
           | None -> expected_rhs
         in
         if not (List.mem subj_root param_names) then
           errors := make_error fd.loc
             ~hint:(Printf.sprintf "`%s` used in `%s` is not a parameter name; \
                     use a function parameter" expected_rhs spec_label)
             (Printf.sprintf "return spec `%s`: `%s` is not a parameter name"
                spec_label expected_rhs)
           :: !errors
         else begin
           (* Result of unifying ONE select-with-WHERE against the declared
              (col, subject): whether it matched, plus a deferred error for the
              near-misses (right column / wrong subject, or wrong column). *)
           let matched = ref false in
           let subject_mismatch : validation_error option ref = ref None in
           let column_mismatch : validation_error option ref = ref None in
           (* A1-OR-BROADEN (review §3.1): a disjunction in a provenance WHERE
              broadens the result set, so the {AND,EQ} unifier cannot prove it
              entails the declared `col == subj` for EVERY returned row.  We model
              only conjunctions; a top-level OR whose spine reaches the select head
              is fail-closed (a narrowing OR nested inside an AND-conjunct — e.g.
              `col==subj && (a || b)` — has no select head in its spine and is
              unaffected). *)
           let disjunction_seen : validation_error option ref = ref None in
           let select_head_seen = ref false in
           (* A1-MASK-NODATAFLOW write variant (review §3.2): the FromDb value is
              produced by a row-returning WRITE (update/updateAndReturnOne …
              returning one, deleteAndReturnResult).  Set when such a write is on
              the return path, so a where-LESS returning-write is rejected the same
              way a where-less select is (its provenance is unestablished). *)
           let write_head_seen = ref false in
           (* Write-path result refs, kept SEPARATE from the select refs: a
              return-reachable write must establish the provenance for the row IT
              returns; a matching select on a DIFFERENT path must not suppress a
              wrong-column write's rejection (a mixed-path handler could otherwise
              forge write provenance). *)
           let write_matched = ref false in
           let write_subject_mismatch : validation_error option ref = ref None in
           let write_column_mismatch : validation_error option ref = ref None in

           (* Gather the (field, rhs_expr) equality conjuncts of a compound WHERE.
              The SQL DSL parses `... where a && b && c` as a left-leaning BAnd of
              BEq conjuncts; only the leftmost conjunct carries the select head in
              its left spine, so we must walk the whole BAnd tree to find the pk
              conjunct wherever it sits. *)
           let rec eq_conjuncts binder (e : expr) : (string * expr * loc) list =
             match e with
             | EBinop { op = BAnd; left; right; _ } ->
               eq_conjuncts binder left @ eq_conjuncts binder right
             | EBinop { op = BEq; left; right; loc } ->
               (* left is either the select-chain ending in `where binder.field`
                  (leftmost conjunct) or a bare `binder.field` (later conjunct). *)
               let last_field =
                 let rec last = function
                   | EField { obj = EVar { name; _ }; field; _ } when name = binder ->
                     Some field
                   | EApp { fn; arg; _ } ->
                     (match arg with
                      | EField { obj = EVar { name; _ }; field; _ } when name = binder ->
                        Some field
                      | _ -> (match last arg with Some f -> Some f | None -> last fn))
                   | _ -> None
                 in last left
               in
               (match last_field with
                | Some f -> [(f, right, loc)]
                | None -> [])
             | _ -> []
           in

           (* Unify a WHERE (rooted at a BEq/BAnd whose left spine reaches a SQL
              head — select/selectOne, or a standalone `where` clause emitted by
              update/updateAndReturnOne/delete) against the declared (col, subj).
              [entity] resolves the field→column mapping; when None (entity binder
              unresolved) we fall back to capitalize so a bare pk still unifies.

              [matched]/[subject_mismatch]/[column_mismatch] are passed in so the
              SELECT path and the returning-WRITE path each track their OWN result:
              a matching select must NOT suppress a sibling wrong-column write's
              rejection (that would forge write provenance on a mixed-path handler).
              [noun] tailors the message (SELECT vs returning write). *)
           let unify_where ~matched ~subject_mismatch ~column_mismatch ~noun
               entity binder (root : expr) =
             let col_of f = match entity with
               | Some en -> field_to_column en f
               | None -> String.capitalize_ascii f
             in
             let conjuncts = eq_conjuncts binder root in
             (* A conjunct whose column matches the declared column. *)
             let col_hit =
               List.find_opt (fun (f, _, _) -> col_of f = expected_col) conjuncts
             in
             (match col_hit with
              | Some (_f, rhs_expr, loc) ->
                (match expr_dotted_subject rhs_expr with
                 | Some subj when subj = expected_rhs -> matched := true
                 | Some where_v ->
                   if !subject_mismatch = None then
                     subject_mismatch := Some (make_error loc
                       ~hint:(Printf.sprintf "the WHERE clause should use `%s` \
                               (from `%s` in the return spec)"
                               expected_rhs spec_label)
                       (Printf.sprintf "WHERE clause uses `%s` but return spec \
                              declares `%s == %s`; these do not match"
                          where_v expected_col expected_rhs))
                 | None ->
                   (* literal (or non-subject expr) on the RHS *)
                   if !subject_mismatch = None then
                     subject_mismatch := Some (make_error loc
                       ~hint:(Printf.sprintf "the WHERE clause should compare \
                               to `%s` (from `%s` in the return spec)"
                               expected_rhs spec_label)
                       (Printf.sprintf "WHERE condition does not match \
                              `%s == %s` in return spec; \
                              use parameter `%s` not a literal"
                          expected_col expected_rhs expected_rhs)))
              | None ->
                (* No conjunct constrains the declared column: wrong-column WHERE. *)
                if conjuncts <> [] && !column_mismatch = None then begin
                  let cols = List.map (fun (f, _, _) -> col_of f) conjuncts in
                  let loc = match conjuncts with (_, _, l) :: _ -> l | [] -> fd.loc in
                  column_mismatch := Some (make_error loc
                    ~hint:(Printf.sprintf "the %s must filter on column `%s` \
                            equal to `%s` to establish `%s`"
                            noun expected_col expected_rhs spec_label)
                    (Printf.sprintf "%s constrains column(s) [%s] but return \
                           spec declares `%s == %s`; the declared FromDb \
                           provenance is not established by this WHERE"
                       noun (String.concat ", " cols) expected_col expected_rhs))
                end)
           in
           (* The SELECT path keeps its existing refs + wording verbatim. *)
           let unify_where_select entity binder root =
             unify_where ~matched ~subject_mismatch ~column_mismatch
               ~noun:"SELECT" entity binder root
           in

           (* Extract (binder, entity) from a SQL DSL call chain head
              (select/selectOne/update/updateAndReturnOne/delete ... from|in E),
              mirroring validation_advanced.ml's binder_env construction. *)
           let sql_binder_entity args =
             let binder = match args with
               | EVar { name; _ } :: _ -> Some name
               | EField { obj = EVar { name; _ }; _ } :: _ -> Some name
               | _ -> None
             in
             let entity =
               let rec find = function
                 | EVar { name = ("from" | "in"); _ } :: EConstructor { name; _ } :: _ -> Some name
                 | EVar { name = ("from" | "in"); _ } :: EVar { name; _ } :: _ -> Some name
                 | _ :: rest -> find rest
                 | [] -> None
               in find args
             in
             (binder, entity)
           in

           (* Collect binder → entity for EVERY SQL DSL head in the body, up front.
              A standalone `where` clause (from update/updateAndReturnOne ...
              returning one) is parsed as a SIBLING statement to the `update ... in
              E` chain that names the entity, so the entity is not reachable from
              the `where` expression itself — we resolve it through this map.
              Binder names are function-unique in practice, so a flat function-wide
              map is sufficient (and degrades to the capitalize fallback if a
              binder is unresolved). *)
           let binder_env =
             let acc = ref [] in
             let rec collect (e : expr) =
               (match e with
                | EApp _ ->
                  let (head, args) = collect_call_head_and_args [] e in
                  (match head with
                   | EVar { name = ("selectOne" | "select" | "update"
                                  | "updateAndReturnOne" | "delete"
                                  | "deleteAndReturnResult"); _ } ->
                     (match sql_binder_entity args with
                      | Some bn, Some en ->
                        if not (List.mem_assoc bn !acc) then acc := (bn, en) :: !acc
                      | _ -> ())
                   | _ -> ())
                | _ -> ());
               ignore (Ast_visitor.fold_children (fun () c -> collect c) () e)
             in
             collect fd.body; !acc
           in

           (* A1-MASK-NODATAFLOW (review §3.2): the declared provenance must be
              established by the WHERE of the select that PRODUCES the returned
              value — not by any matching WHERE anywhere in the body.  [matched]
              was function-wide, so an unused sibling `let good = select … where
              <matching>` laundered a returned value from a different, wrong-WHERE
              select.  We compute the set of variables whose value flows to the
              function result (following `let`-body, `if`-branches, and
              `case scrut of … Ctor b -> … b …` back to the scrutinee), and only
              credit a select whose `let`-binder is return-reachable (or a select
              not let-bound at all, i.e. already in the return path). *)
           let returned_vars =
             let pat_binders =
               let rec pb = function
                 | PVar n -> [n] | PWild | PNullary _ | PLit _ -> []
                 | PCon { fields; _ } -> List.concat_map (fun (_, p) -> pb p) fields
               in pb
             in
             (* all variable USES in an expression (over-approximate free vars). *)
             let free_vars e =
               let acc = ref [] in
               let rec go e =
                 (match e with EVar { name; _ } -> acc := name :: !acc | _ -> ());
                 ignore (Ast_visitor.fold_children (fun () c -> go c) () e)
               in go e; !acc
             in
             (* every `let`-binder → the free vars of its bound value. *)
             let let_defs =
               let acc = ref [] in
               let rec go e =
                 (match e with
                  | ELet { name; value; _ } -> acc := (name, free_vars value) :: !acc
                  | ELetProof { value_name; value; _ } -> acc := (value_name, free_vars value) :: !acc
                  | _ -> ());
                 ignore (Ast_visitor.fold_children (fun () c -> go c) () e)
               in go fd.body; !acc
             in
             (* Variables used in RESULT position (peeling `let` VALUES, tracing a
                returned pattern binder back to its scrutinee).  Intermediate `let`
                values are reached only via the closure below, so a dead sibling
                select's binder never enters the set. *)
             let rec result_uses e =
               match e with
               | ELet { body; _ } | ELetProof { body; _ }
               | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
               | EWithTransaction { body; _ } -> result_uses body
               | EIf { then_; else_; _ } -> result_uses then_ @ result_uses else_
               | ECase { scrut; arms; _ } ->
                 List.concat_map (fun (arm : case_arm) ->
                   let bvs = result_uses arm.body in
                   let pbs = pat_binders arm.pattern in
                   if List.exists (fun v -> List.mem v pbs) bvs
                   then free_vars scrut @ bvs else bvs
                 ) arms
               | EField { obj; _ } -> result_uses obj
               | EOk { value; _ } -> result_uses value
               | _ -> free_vars e
             in
             (* Backward closure: a returned variable pulls in the free vars of the
                value it was bound to, so `let b = f a in … b …` credits `a`'s
                select while a never-contributing sibling stays out. *)
             let rec close seen = function
               | [] -> seen
               | v :: rest ->
                 if List.mem v seen then close seen rest
                 else
                   let extra = match List.assoc_opt v let_defs with Some fvs -> fvs | None -> [] in
                   close (v :: seen) (extra @ rest)
             in
             close [] (result_uses fd.body)
           in
           let should_credit = function
             | None -> true                         (* result position → in the return path *)
             | Some x -> List.mem x returned_vars
           in

           (* ── Returning-WRITE provenance (review §3.2 write variant) ────────
              A row-producing write — `update … where … set … returning one`,
              `updateAndReturnOne … where … set …`, or `deleteAndReturnResult …
              where …` — hands back a value carrying the declared FromDb.  Its
              WHERE is NOT fused into a select-head spine (the multi-line form is
              lowered by the parser to a sibling `let _ = <where …>` chain, so the
              `should_credit`-gated select walk in `check_expr` never sees it), so
              it must be unified separately here.  We reuse the SAME `unify_where`
              (⇒ matched / column_mismatch / subject_mismatch) and disjunction
              fail-closed used for selects; the only new work is isolating the
              write's WHERE conjunct(s) from its `set`/`returning` modifiers.

              The heads that RETURN a row (and so can carry a FromDb grant): a
              multi-line `update`/`updateAndReturnOne` chain, a multi-line
              `delete`/`deleteAndReturnResult` chain, and their single-line
              `updateAndReturnOne`/`deleteAndReturnResult … where …` forms.  A
              plain non-returning `update`/`delete` produces Unit and cannot carry
              a FromDb, so it is only credited when a `returning one` tail is
              present. *)
           let is_update_head = function
             | "update" | "updateAndReturnOne" -> true | _ -> false in
           let is_delete_head = function
             | "delete" | "deleteAndReturnResult" -> true | _ -> false in
           let is_write_head n = is_update_head n || is_delete_head n in
           (* Head keyword of a statement, peeling any BEq/BAnd/BOr comparison
              wrapper to reach the SQL-call spine (a `where a == b` statement is an
              EBinop whose left spine is the `where`/select/update EApp chain). *)
           let rec stmt_head_kw (e : expr) : string option =
             match e with
             | EBinop { op = (BEq | BAnd | BOr); left; _ } -> stmt_head_kw left
             | EApp _ -> (match collect_call_head_and_args [] e with
                          | EVar { name; _ }, _ -> Some name
                          | _ -> None)
             | EVar { name; _ } -> Some name
             | _ -> None
           in
           (* True when a top-level `||` rides the WHERE spine (fail-closed). *)
           let where_has_disjunction (e : expr) : bool =
             let rec go = function
               | EBinop { op = BOr; _ } -> true
               | EBinop { op = (BEq | BAnd); left; right; _ } -> go left || go right
               | _ -> false
             in go e
           in
           (* Best-effort loc for a WHERE statement (its top comparison node),
              falling back to the function loc — [expr_loc] lives in checker.ml
              which this task must not touch. *)
           let where_loc (e : expr) : loc =
             match e with
             | EBinop { loc; _ } -> loc
             | _ -> fd.loc
           in
           (* Given a returning-write expression [e] (multi-line `let _` chain or a
              single-line call), unify each of its WHERE conjuncts against the
              declared (col, subj).  [set] statements are never passed to the
              unifier, so `set field = value` is not mistaken for a WHERE conjunct. *)
           let unify_write_where entity binder (where_stmts : expr list) =
             List.iter (fun w ->
               if where_has_disjunction w then begin
                 if !disjunction_seen = None then
                   disjunction_seen := Some (make_error (where_loc w)
                     ~hint:(Printf.sprintf "a WHERE with `||` broadens the rows the \
                             write touches; to establish `%s` every affected row must \
                             satisfy `%s == %s`, so remove the disjunction"
                             spec_label expected_col expected_rhs)
                     (Printf.sprintf "returning-write WHERE clause uses `||` \
                            (disjunction); the declared FromDb provenance `%s == %s` \
                            in `%s` is not established for every affected row"
                        expected_col expected_rhs spec_label))
               end else
                 unify_where ~matched:write_matched
                   ~subject_mismatch:write_subject_mismatch
                   ~column_mismatch:write_column_mismatch
                   ~noun:"returning write" entity binder w
             ) where_stmts
           in
           (* Recognise a returning-write and return its (entity, binder, WHERE
              statements).  Returns None for anything that is not a row-returning
              write. *)
           let returning_write (e : expr) : (string option * string * expr list) option =
             (* Multi-line form: `let _ = <update/delete head> in let _ = <where …>
                in let _ = <set …> in … returning one`. *)
             let rec flatten acc = function
               | ELet { name = "_"; value; body; _ } -> flatten (value :: acc) body
               | last -> List.rev (last :: acc)
             in
             let stmts = flatten [] e in
             match stmts with
             | head_stmt :: rest ->
               (match collect_call_head_and_args [] head_stmt with
                | EVar { name; _ }, args when is_write_head name ->
                  let binder, entity = sql_binder_entity args in
                  (* which statements are WHERE clauses (not set/returning)? *)
                  let where_stmts =
                    List.filter (fun s -> stmt_head_kw s = Some "where") rest in
                  (* a `returning one` tail (or an updateAndReturnOne / *AndReturn*
                     head) makes the write row-returning. *)
                  let returns_row =
                    name = "updateAndReturnOne" || name = "deleteAndReturnResult"
                    || List.exists (fun s ->
                         match collect_call_head_and_args [] s with
                         | EVar { name = "returning"; _ }, _ -> true
                         | _ -> false) rest
                  in
                  if returns_row then
                    (match binder with
                     | Some bn ->
                       let entity = match entity with Some _ -> entity
                                    | None -> List.assoc_opt bn binder_env in
                       Some (entity, bn, where_stmts)
                     | None -> None)
                  else None
                | _ ->
                  (* Single-line form: `updateAndReturnOne b … where …` or
                     `deleteAndReturnResult b … where …` — the whole expression is
                     one call whose WHERE is fused into the arg spine. *)
                  (match e with
                   | (EApp _ | EBinop { op = (BEq | BAnd | BOr); _ }) ->
                     let spine_head =
                       let rec sp = function
                         | EBinop { op = (BEq | BAnd | BOr); left; _ } -> sp left
                         | other -> other
                       in sp e
                     in
                     (match collect_call_head_and_args [] spine_head with
                      | EVar { name; _ }, args
                        when name = "updateAndReturnOne" || name = "deleteAndReturnResult" ->
                        (match sql_binder_entity args with
                         | Some bn, entity ->
                           let entity = match entity with Some _ -> entity
                                        | None -> List.assoc_opt bn binder_env in
                           Some (entity, bn, [e])
                         | None, _ -> None)
                      | _ -> None)
                   | _ -> None))
             | [] -> None
           in
           (* Walk RESULT positions only (mirroring `result_uses`), so a write is
              checked exactly when its value flows to the function result — a dead
              sibling `let bad = updateAndReturnOne … where <wrong>` that is never
              returned does not (write-variant sibling mask, review §3.2). *)
           let rec check_writes (e : expr) =
             match returning_write e with
             | Some (entity, binder, where_stmts) ->
               write_head_seen := true;
               unify_write_where entity binder where_stmts
             | None ->
               (match e with
                | ELet { body; _ } | ELetProof { body; _ }
                | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
                | EWithTransaction { body; _ } -> check_writes body
                | EIf { then_; else_; _ } -> check_writes then_; check_writes else_
                | ECase { arms; _ } ->
                  List.iter (fun (arm : case_arm) -> check_writes arm.body) arms
                | EField { obj; _ } -> check_writes obj
                | EOk { value; _ } -> check_writes value
                | _ -> ())
           in

           (* Walk the body: unify each WHERE — select-rooted OR standalone
              (update/delete-derived) — against the declared spec.  A select/
              selectOne head sets [select_head_seen] so the must-have-WHERE
              requirement fires ONLY for select-derived grants (insert/update-
              returning grants have no select head and stay exempt). *)
           (* Find the SQL head in a comparison chain's left spine: either a
              select/selectOne (select-derived grant) or a standalone `where`
              clause (update/delete-derived).  Lifted out so both the conjunction
              and disjunction arms of [check_expr] can consult it. *)
           let rec sql_root = function
             | EBinop { op = BAnd | BEq; left; _ } -> sql_root left
             | EApp _ as a ->
               let (head, args) = collect_call_head_and_args [] a in
               (match head with
                | EVar { name = ("selectOne" | "select"); _ } ->
                  (match sql_binder_entity args with
                   | Some bn, en -> Some (`Select, bn, en)
                   | None, _ -> None)
                | EVar { name = "where"; _ } ->
                  (match args with
                   | [ EField { obj = EVar { name = bn; _ }; _ } ] ->
                     Some (`Where, bn, List.assoc_opt bn binder_env)
                   | _ -> None)
                | _ -> None)
             | _ -> None
           in
           (* [binder] = the `let`-binder currently being bound to [e], or None
              when [e] is not directly on the right of a `let`.  Used to decide
              whether a select's provenance may be credited (return-reachability). *)
           let rec check_expr ?(binder=None) (e : expr) =
             match e with
             | ELet { name; value; body; _ } ->
               check_expr ~binder:(Some name) value;
               check_expr ~binder:None body
             | ELetProof { value; body; _ } ->
               check_expr ~binder:None value;
               check_expr ~binder:None body
             | EApp _ ->
               let (head, _args) = collect_call_head_and_args [] e in
               (match head with
                | EVar { name = ("selectOne" | "select"); _ } ->
                  (* A select head: credit only if its value flows to the return.
                     Either way do NOT descend — the select's own subtree carries no
                     other credited grant, and descending would re-credit it. *)
                  if should_credit binder then select_head_seen := true
                | _ ->
                  ignore (Ast_visitor.fold_children (fun () c -> check_expr c) () e))
             | EBinop { op = (BEq | BAnd); _ } ->
               (match sql_root e with
                | Some (kind, sbinder, entity) ->
                  (* This EBinop IS a select/where condition.  Credit only if the
                     produced value is return-reachable; do NOT descend (the inner
                     select EApp would otherwise re-set select_head_seen even when
                     the value is a discarded sibling). *)
                  if should_credit binder then begin
                    (match kind with `Select -> select_head_seen := true | `Where -> ());
                    unify_where_select entity sbinder e
                  end
                | None ->
                  ignore (Ast_visitor.fold_children (fun () c -> check_expr c) () e))
             | EBinop { op = BOr; loc; _ }
               when should_credit binder
                    && (let rec or_root = function
                       | EBinop { op = BOr; left; right; _ } ->
                         (match sql_root left with Some _ as r -> r
                          | None -> (match or_root left with Some _ as r -> r
                                     | None -> (match sql_root right with Some _ as r -> r
                                                | None -> or_root right)))
                       | _ -> None
                     in or_root e <> None) ->
               (* Fail-closed: a disjunction at the WHERE top level cannot be shown
                  to establish the declared provenance for every branch.  Mark the
                  select head seen, record the rejection, and do NOT descend into
                  the disjuncts (which would credit the single matching branch). *)
               select_head_seen := true;
               if !disjunction_seen = None then
                 disjunction_seen := Some (make_error loc
                   ~hint:(Printf.sprintf "a WHERE with `||` broadens the result set; \
                           to establish `%s` every row must satisfy `%s == %s`, so \
                           remove the disjunction (or move it into a narrowing \
                           conjunct: `%s == %s && (…)`)"
                           spec_label expected_col expected_rhs expected_col expected_rhs)
                   (Printf.sprintf "WHERE clause uses `||` (disjunction); the declared \
                          FromDb provenance `%s == %s` in `%s` is not established for \
                          every returned row (an `OR` broadens beyond the declared \
                          subject)" expected_col expected_rhs spec_label))
             | _ -> ignore (Ast_visitor.fold_children (fun () c -> check_expr c) () e)
           in
           check_expr fd.body;
           check_writes fd.body;

           (* Report.  A disjunction in ANY provenance WHERE (select or write) is a
              definite rejection even if a sibling matched — an OR broadens the rows
              beyond the declared subject.  The SELECT and WRITE paths are reported
              INDEPENDENTLY (each tracks its own matched / near-miss refs) so a
              matching select on one branch cannot suppress a wrong-column write's
              rejection on another (the mixed-path write-forgery gap). *)
           (match !disjunction_seen with
            | Some e -> errors := e :: !errors
            | None ->
              (* SELECT path — unchanged: prefer subject then column near-miss,
                 else a where-less select head is unestablished. *)
              if not !matched then begin
                match !subject_mismatch, !column_mismatch with
                | Some e, _ -> errors := e :: !errors
                | None, Some e -> errors := e :: !errors
                | None, None ->
                  if !select_head_seen then
                    errors := make_error fd.loc
                      ~hint:(Printf.sprintf "add a WHERE clause constraining column \
                              `%s` to `%s` so the SELECT establishes `%s`"
                              expected_col expected_rhs spec_label)
                      (Printf.sprintf "SELECT does not constrain `%s` to `%s`; the \
                             declared FromDb provenance in `%s` is not established \
                             by any WHERE clause"
                         expected_col expected_rhs spec_label)
                    :: !errors
              end;
              (* WRITE path — independent of the select result: a return-reachable
                 row-returning write must establish the provenance for its own row. *)
              if not !write_matched then begin
                match !write_subject_mismatch, !write_column_mismatch with
                | Some e, _ -> errors := e :: !errors
                | None, Some e -> errors := e :: !errors
                | None, None ->
                  if !write_head_seen then
                    (* A row-returning write reached the return path but no WHERE
                       conjunct constrained the declared column to the declared
                       subject (a where-less returning-write forges provenance). *)
                    errors := make_error fd.loc
                      ~hint:(Printf.sprintf "add a `where %s == %s` clause to the \
                              returning write so it establishes `%s`"
                              (String.uncapitalize_ascii expected_col) expected_rhs
                              spec_label)
                      (Printf.sprintf "returning write does not constrain `%s` to \
                             `%s`; the declared FromDb provenance in `%s` is not \
                             established by any WHERE clause"
                         expected_col expected_rhs spec_label)
                    :: !errors
              end)
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
              (* OK: the id field IS the existential witness / declared pk var. *)
              | EVar { name; _ } when name = pk_var || name = witness -> ()
              | EVar { name; _ } ->
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
              (* review 2026-07 (EE-1): a computed/wrapped id expression
                 (arithmetic, constructor, call) was previously let through by a
                 `| _ -> ()` leaf, forging the FromDb provenance.  The id must be
                 EXACTLY the witness, so anything the compiler cannot equate to it
                 fails closed. *)
              | _ ->
                errors := make_error loc
                  ~hint:(Printf.sprintf
                    "use `id: %s` (the existential witness) directly to satisfy `FromDb (Id == %s)` in the return spec"
                    witness witness)
                  (Printf.sprintf
                    "insert sets `id` to a computed expression, but the return spec \
                     declares `Id == %s`; the `id` must be exactly the existential witness `%s`, \
                     not a value the compiler cannot equate to it"
                    witness witness)
                :: !errors
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

(** Non-existential named-pack FromDb provenance (review 2026-07 F1/F2).
    A `-> T ? FromDb (Col == rhs)` return whose body's TAIL is an `insert T {…}`
    must set the `Col` field to `rhs`; otherwise the inserted row does not carry
    the declared provenance and the proof is forged.  Legitimate INSERT handlers
    use the existential form (`exists W => insert { id: W }`, owned by
    {!check_insert_pk_match}); non-existential named-pack + tail-`insert` with a
    mismatched provenance field is the forgery.  SELECT bodies are unaffected
    (the head is not `insert`), and a matching field (`id: rhs`) is accepted. *)
let check_nonexist_named_pack_insert (decls : top_decl list) : validation_error list =
  let errors = ref [] in
  let col_field col =
    if String.length col = 0 then col
    else String.make 1 (Char.lowercase_ascii col.[0])
         ^ String.sub col 1 (String.length col - 1)
  in
  let expr_key (e : expr) : string option = match e with
    | EVar { name; _ } -> Some name
    | EField { obj = EVar { name; _ }; field; _ } -> Some (name ^ "." ^ field)
    | _ -> None
  in
  let rec tail_exprs (e : expr) : expr list = match e with
    | ELet { body; _ } | ELetProof { body; _ } -> tail_exprs body
    | EIf { then_; else_; _ } -> tail_exprs then_ @ tail_exprs else_
    | ECase { arms; _ } ->
      List.concat_map (fun (a : case_arm) -> tail_exprs a.body) arms
    | EWithTransaction { body; _ } | EWithDatabase { body; _ }
    | EWithCapabilities { body; _ } -> tail_exprs body
    | e -> [e]
  in
  List.iter (function
    | DFunc fd when (fd.kind = FnKind || fd.kind = HandlerKind) ->
      (match fd.return_spec with
       | RetNamedPack { entity_proof = Some ep; _ } ->
         (match fromdb_col_var ep with
          | Some (col, rhs) ->
            let field = col_field col in
            List.iter (fun leaf ->
              let (head, args) = collect_call_head_and_args [] leaf in
              match function_name_of_expr head with
              | Some "insert" ->
                List.iter (fun arg -> match arg with
                  | ERecord { fields; loc; _ } ->
                    List.iter (fun (fname, fval) ->
                      if fname = field then
                        (match expr_key fval with
                         | Some k when k = rhs -> ()
                         | _ ->
                           errors := make_error loc
                             ~hint:(Printf.sprintf
                               "set `%s: %s` so the inserted row matches the declared \
                                provenance `FromDb (%s == %s)`, or generate the key with \
                                `exists %s => …`" field rhs col rhs rhs)
                             (Printf.sprintf
                               "insert sets `%s` to a value that is not `%s`, but the return \
                                spec declares `FromDb (%s == %s)`; the inserted row does not \
                                carry that provenance (forged FromDb)" field rhs col rhs)
                           :: !errors)
                    ) fields
                  | _ -> ()) args
              | _ -> ()
            ) (tail_exprs fd.body)
          | None -> ())
       | _ -> ())
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
    (* Cache declarations implicitly define a "cacheCap <Name>" capability *)
    | DCache (c : Ast.cache_form) -> Some ("cacheCap " ^ c.name, [])
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
        List.iter (function RLit _ | RRawVar _ -> () | RArg e -> walk_expr local_env e) segments
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

