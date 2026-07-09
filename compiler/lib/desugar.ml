(** Surface-syntax lowering pass (Wave 2: reduce_language_size).

    {2 Where this runs}

    The pipeline is: parse → type-check + proof-check + validation → DESUGAR →
    emit.  Crucially the pass runs AFTER all enforcement/diagnostics (so every
    error message still points at the surface form the user wrote) and BEFORE
    {!Emit_racket} (so the emitter sees the lowered, more primitive forms).

    {2 Contract: identity except the lowered families; hit = historical bytes}

    {!desugar_module} walks every expression in every top-level declaration
    through {!Ast_visitor.map} and applies {!lower_expr} at each node.
    [lower_expr] is the identity for every expression EXCEPT the lowered
    families ([EEnqueue] / [EStartWorkers] / [EServe] / the cache family /
    the email family / [ETelemetry]), which it rewrites to the core
    {!Ast.ERuntimeCall} node.  For those families the byte contract is
    two-sided (see {!lower_tables}):

    - a same-module resolution-table HIT emits the declaration's own Racket
      binding — byte-identical to the historical (pre-desugar) emit output,
      gated by the committed lesson snapshots;
    - a table MISS (the declaring block lives in another module, issue #41)
      emits a per-call registry lookup ([queue-for-job-ref] /
      [cache-for-name] / [email-for-name]) — deliberately NOT the historical
      bytes; the historical output was an unbound identifier.

    Every un-lowered expression variant is carried through structurally
    unchanged with every [loc] preserved (asserted by test/test_desugar.ml).

    {2 Provenance — go-to-definition / error spans}

    When a real lowering eventually replaces a surface node with a synthesised
    primitive form, it MUST thread the original surface {!Location.loc} so that
    hover / go-to-definition / diagnostics keep resolving to what the user typed,
    never to the machine-generated lowering.  For synthesised {!Ast.func_decl}s
    that is the [desugared_from] field ({!provenance_from}); for expressions the
    convention is to REUSE the surface node's own [loc] verbatim on the lowered
    node (every expression variant carries its own [loc], so a structurally
    equal-or-smaller lowering preserves spans for free).

    {2 Why the two pilot sugar forms (EUnop / LInterp) are NOT lowered here}

    The reduce_language_size pilot considered lowering [EUnop] and the [LInterp]
    interpolation literal to a core application form.  Both were investigated and
    deliberately LEFT UN-LOWERED, because neither is context-free at emit and a
    pre-emit lowering cannot reproduce the emitter's byte output:

    - [EUnop] (emit_racket.ml ~1719): the [UNeg]/[UNot] arms consult emit-time
      context unavailable to a desugar pass — [ctx.func_kind], [ctx.param_names]
      and [ctx.raw_locals] — to decide whether a bare-[EVar] operand is emitted
      raw ([*name]) or normally, and special-case a negative integer LITERAL to
      the bare token [-n].  Even the seemingly context-free literal fold
      ([EUnop(UNeg, ELit(LInt n))] -> [ELit(LInt (-n))]) is NOT safe: a folded
      [ELit(LInt _)] is matched by [int_literal_value] in the SQL clause
      extractor (emit_racket.ml ~586), so a negative LIMIT/OFFSET literal would
      take a different emit path than the un-folded [EUnop].

    - [LInterp] ([emit_interp], emit_racket.ml ~2483): interpolation emits a
      Racket [(format "...~a..." (tesl-display-val ...))] call (NOT a [BConcat]
      / string-append chain), and the per-segment operand again branches on
      [ctx.func_kind] to choose [*name] / [(raw-value name.field)] / the generic
      [(tesl-display-val e)] wrapping.

    Lowering either form at this stage would be a behaviour-changing rewrite, so
    per the wave's hard byte-identity invariant they remain explicit in
    {!Emit_racket}.  When the emitter's context-dependent unwrapping is itself
    moved into a core primitive (a later wave), these become safe to lower and
    the arms below are where that lowering lands. *)

open Ast

(** Build a {!provenance} tag recording the surface location a synthesised node
    was lowered FROM.  Use this when a lowering creates a fresh {!func_decl}: set
    its [desugared_from] to [provenance_from surface_loc] so navigation/spans
    keep pointing at the user's original construct. *)
let provenance_from (surface : Location.loc) : provenance = { desugared_from = surface }

(** {2 Fixed-shape effect-form lowering (reduce_language_size Wave 2, P3)}

    [EEnqueue], [EStartWorkers] and [EServe] are lowered to the core
    {!Ast.ERuntimeCall} node — a pre-rendered Racket runtime call composed of
    verbatim token strings ([RLit]) interleaved with argument sub-expressions
    ([RArg]).  These three families are exactly the ones whose emit template is
    {e position-independent} and {e context-free}:

    - their literal tokens (runtime fn name, the resolved queue/worker/server
      name, [#:capabilities]/[#:concurrency]/[#:static-dir]/[#:sse-routes]
      keyword args) are fully determined at desugar time, and
    - their argument sub-expressions ([payload] / [port]) were emitted by the
      former emit arms through {!Emit_racket.emit_expr_simple}; carrying them as
      [RArg] re-emits them through that SAME context-aware path, so the byte
      output is identical.

    Also lowered (same fixed-shape, position-independent template): the cache
    family ([ECacheGet]/[ECacheSet]/[ECacheDelete]/[ECacheInvalidate]) and the
    email family ([ESendEmail]/[EStartEmailWorker]).  Their former emit arms were
    shape-only (constant prefix + keyword tokens, sub-expressions through
    [emit_expr_simple]); byte-identity is gated by the committed
    [lesson59-cache.rkt] / [lesson60-email.rkt] snapshots.

    [ETelemetry] is ALSO lowered to {!Ast.ERuntimeCall}: although its bare-[EVar]
    field value emits the raw [*name], that rule is in fact context-FREE (it does
    NOT consult [ctx.func_kind] / [ctx.raw_locals] and uses the literal surface
    name, not [resolve_name]).  The new {!Ast.RRawVar} segment reproduces that
    [*name] byte output verbatim, so the lowering is byte-identical without any
    emit-time context — see the [ETelemetry] arm of {!lower_expr}.

    Deliberately NOT lowered (documented BLOCKED, see roadmap):
    - [EPublish]: its key operand branches on emit-time-only [ctx.func_kind] to
      choose [*name] vs [(raw-value name)] (the raw-param blocker) — a desugar
      pass cannot reproduce that per-leaf decision.
    - [EWithDatabase] / [EWithCapabilities] / [EWithTransaction]: position
      dependent — they emit DIFFERENT runtime calls in tail-raw position
      ([with-database] / [call-with-declared-capabilities]) than in statement
      position ([call-with-database] / [with-capabilities]); a single core form
      cannot capture both.
    - [EUnop] / [LInterp]: the raw-param blocker (see module docstring above). *)

(** The same-module resolution tables the lowering consults, all built from the
    module's OWN declarations (the emitter's historical pre-pass):
    - [queues]: job-type → queue-name from [DQueue] (for [EEnqueue]);
    - [caches]: locally declared cache names from [DCache] (for the
      [ECacheGet]/[ECacheSet]/[ECacheDelete]/[ECacheInvalidate] family);
    - [emails]: locally declared email names from [DEmail] (for
      [ESendEmail]/[EStartEmailWorker]).

    A table HIT resolves to the declaration's own Racket binding at compile
    time — byte-identical to the historical output.  A MISS means the
    declaring block lives in another module (the issue-#41 name-wired class):
    fall back to a lazy runtime lookup in the process-wide domain registry
    ([queue-for-job-ref] / [cache-for-name] / [email-for-name], tesl/queue.rkt /
    tesl/cache.rkt / tesl/email.rkt): every define-queue/cache/email registers
    its live spec at module instantiation, and each lookup is fail-closed
    (errors on zero or multiple declaring modules).  Every lookup must stay
    PER-CALL: a top-level binding would evaluate at module instantiation,
    before the entrypoint's own define-* has registered. *)
type lower_tables = {
  queues : (string, string) Hashtbl.t;  (** job type → declaring queue name *)
  caches : (string, unit) Hashtbl.t;    (** locally declared cache names *)
  emails : (string, unit) Hashtbl.t;    (** locally declared email names *)
}

let empty_tables () : lower_tables =
  { queues = Hashtbl.create 1; caches = Hashtbl.create 1; emails = Hashtbl.create 1 }

let queue_ref_of (tables : lower_tables) (job_type : string) : string =
  match Hashtbl.find_opt tables.queues job_type with
  | Some q -> q
  (* NOMINAL miss form (DESIGN-4 Topic B): the macro normalizes the job-type
     IDENTIFIER at the enqueue site — require-bound there, since the payload
     construction next to it uses it — so the registry lookup matches by
     (owner, name) type-ref, not by spelling.  A same-name job record declared
     by a different module now fails closed at enqueue with both owners
     instead of silently misrouting into the foreign queue. *)
  | None -> Printf.sprintf "(queue-for-job-ref %s)" job_type

let cache_ref_of (tables : lower_tables) (cache_name : string) : string =
  if Hashtbl.mem tables.caches cache_name then cache_name
  else Printf.sprintf "(cache-for-name '%s)" cache_name

let email_ref_of (tables : lower_tables) (email_name : string) : string =
  if Hashtbl.mem tables.emails email_name then email_name
  else Printf.sprintf "(email-for-name '%s)" email_name

(** Per-node lowering.  [tables] holds the module's same-module resolution
    tables (job-type → queue for [EEnqueue]; local cache/email name sets for
    the cache/email families).  {!Ast_visitor.map} has already lowered the
    node's children by the time this is called, so each arm only rewrites the
    node's own shape and reuses the surface node's own [loc] verbatim
    (span-preserving). *)
let lower_expr (tables : lower_tables) (e : expr) : expr =
  match e with
  | ETelemetry { name; fields; loc } ->
    (* (telemetry-event! "NAME" #:attributes ([%S v]...))
       The former emit arm rendered each field value with a context-FREE rule:
       a bare [EVar] became the raw value [*name] (the literal surface name, NOT
       [resolve_name]); every other value went through emit_expr_simple.  So the
       value operand needs no func-context knowledge — [RRawVar] reproduces the
       [*name] byte output and [RArg] the emit_expr_simple path, byte-identically. *)
    let segs = ref [ RLit (Printf.sprintf "(telemetry-event! %S #:attributes (" name) ] in
    let push s = segs := s :: !segs in
    List.iteri (fun i (k, v) ->
      if i > 0 then push (RLit " ");
      push (RLit (Printf.sprintf "[%S " k));
      (match v with
       | EVar { name = vname; _ } -> push (RRawVar vname)
       | _ -> push (RArg v));
      push (RLit "]")
    ) fields;
    push (RLit "))");
    ERuntimeCall { segments = List.rev !segs; loc }
  | EEnqueue { job_type; payload; loc } ->
    (* (enqueue! QUEUE_REF <payload via emit_expr_simple>) *)
    let queue_ref = queue_ref_of tables job_type in
    ERuntimeCall { segments =
      [ RLit (Printf.sprintf "(enqueue! %s " queue_ref)
      ; RArg payload
      ; RLit ")" ]; loc }
  | EStartWorkers { workers_name; capabilities; concurrency; is_dead; loc } ->
    (* (start-workers!|start-dead-workers! NAME (list CAP...)[ #:concurrency N]) *)
    let runtime_fn = if is_dead then "start-dead-workers!" else "start-workers!" in
    let buf = Buffer.create 64 in
    Buffer.add_string buf (Printf.sprintf "(%s %s (list" runtime_fn workers_name);
    List.iter (fun cap -> Buffer.add_string buf (Printf.sprintf " %s" cap)) capabilities;
    Buffer.add_string buf ")";
    (* `numberOfWorkers` (concurrency) applies ONLY to the normal worker starter.
       Dead-letter workers are always single-threaded and `start-dead-workers!`
       takes no `#:concurrency` keyword — passing it there crashed at App boot on
       any queue that had BOTH a dead worker and `numberOfWorkers` (issue #15). *)
    (match concurrency with
     | Some n when n <> 1 && not is_dead ->
       Buffer.add_string buf (Printf.sprintf " #:concurrency %d" n)
     | _ -> ());
    Buffer.add_string buf ")";
    ERuntimeCall { segments = [ RLit (Buffer.contents buf) ]; loc }
  | EServe { server_name; port; capabilities; static_dir; loc } ->
    (* (serve NAME #:port <port via emit_expr_simple> #:capabilities (list CAP...)
        [ #:static-dir "DIR"] #:sse-routes NAME-sse-routes) *)
    let prefix = Printf.sprintf "(serve %s #:port " server_name in
    let mid_buf = Buffer.create 64 in
    Buffer.add_string mid_buf " #:capabilities (list";
    List.iter (fun cap -> Buffer.add_string mid_buf (Printf.sprintf " %s" cap)) capabilities;
    Buffer.add_string mid_buf ")";
    (match static_dir with
     | Some dir -> Buffer.add_string mid_buf (Printf.sprintf " #:static-dir %S" dir)
     | None -> ());
    Buffer.add_string mid_buf (Printf.sprintf " #:sse-routes %s-sse-routes)" server_name);
    ERuntimeCall { segments =
      [ RLit prefix
      ; RArg port
      ; RLit (Buffer.contents mid_buf) ]; loc }
  (* Cache / email families — also fixed-shape, position-independent runtime
     calls.  Each former emit arm rendered a constant prefix + keyword tokens and
     emitted its sub-expressions through [emit_expr_simple]; carrying them as
     [RArg] re-emits through that SAME path, so the byte output is identical.
     Byte-gated by the committed lesson59-cache / lesson60-email [.rkt].
     The NAME operand goes through [cache_ref_of]/[email_ref_of]: a local
     declaration keeps the bare binding (exact historical bytes), a miss
     splices the per-call registry lookup — the same #41 rule as [EEnqueue]. *)
  | ECacheGet { cache_name; key; loc } ->
    (* (cache-get! CACHE_REF <key>) *)
    ERuntimeCall { segments =
      [ RLit (Printf.sprintf "(cache-get! %s " (cache_ref_of tables cache_name))
      ; RArg key
      ; RLit ")" ]; loc }
  | ECacheSet { cache_name; key; value; ttl; loc } ->
    (* (cache-set! CACHE_REF <key> <value>[ <ttl>]) *)
    let ttl_segs = match ttl with
      | Some ttl_expr -> [ RLit " "; RArg ttl_expr ]
      | None -> [] in
    ERuntimeCall { segments =
      [ RLit (Printf.sprintf "(cache-set! %s " (cache_ref_of tables cache_name))
      ; RArg key
      ; RLit " "
      ; RArg value ]
      @ ttl_segs
      @ [ RLit ")" ]; loc }
  | ECacheDelete { cache_name; key; loc } ->
    (* (cache-delete! CACHE_REF <key>) *)
    ERuntimeCall { segments =
      [ RLit (Printf.sprintf "(cache-delete! %s " (cache_ref_of tables cache_name))
      ; RArg key
      ; RLit ")" ]; loc }
  | ECacheInvalidate { cache_name; prefix; loc } ->
    (* (cache-invalidate-prefix! CACHE_REF <prefix>) *)
    ERuntimeCall { segments =
      [ RLit (Printf.sprintf "(cache-invalidate-prefix! %s " (cache_ref_of tables cache_name))
      ; RArg prefix
      ; RLit ")" ]; loc }
  | ESendEmail { email_name; to_; subject; body; loc } ->
    (* (send-email! EMAIL_REF #:to <to> #:subject <subject> #:body <body>) *)
    ERuntimeCall { segments =
      [ RLit (Printf.sprintf "(send-email! %s #:to " (email_ref_of tables email_name))
      ; RArg to_
      ; RLit " #:subject "
      ; RArg subject
      ; RLit " #:body "
      ; RArg body
      ; RLit ")" ]; loc }
  | EStartEmailWorker { email_name; loc } ->
    (* (start-email-worker! EMAIL_REF) *)
    ERuntimeCall { segments =
      [ RLit (Printf.sprintf "(start-email-worker! %s)" (email_ref_of tables email_name)) ]; loc }
  | _ -> e

(** Lower a single expression: bottom-up rewrite via the shared traversal
    framework, so a new {!Ast.expr} variant cannot silently escape the pass. *)
let desugar_expr (tables : lower_tables) (e : expr) : expr =
  Ast_visitor.map (lower_expr tables) e

(** Lower every expression carried by a top-level declaration.  Only [DFunc] and
    [DConst] carry an {!Ast.expr} body reachable from the surface program; the
    rest are pure declarations (types, records, codecs, schema/queue/cache/email
    metadata) with no expression children, so they pass through verbatim.  This
    mirrors the "children = sub-[expr]s reachable without crossing a top-level
    declaration boundary" coverage decision documented in {!Ast_visitor}. *)
(* ── Typed-config-block lowering (`database X = Database { … }`) ────────────
   The parser leaves the new typed-record syntax as a record-construction [expr]
   in [config_expr]; here we extract the structured fields the emitter reads, so
   {!Emit_racket} is untouched.  Scalar values (`env "X"`, `envInt "X" n`,
   `envString "X" "d"`, literals) are rendered to the same intermediate strings
   the emitter already understands. *)

let config_record_fields (e : expr) : (string * expr) list =
  match e with
  | ERecord { fields; _ } -> fields
  | EApp { fn = EConstructor _; arg = ERecord { fields; _ }; _ } -> fields
  | _ -> []

let config_ctor_name (e : expr) : string option =
  match e with
  | EConstructor { name; _ } -> Some name
  | EApp { fn = EConstructor { name; _ }; _ } -> Some name
  | _ -> None

(* Render a scalar config value to the emitter's intermediate string form. *)
let render_config_value (e : expr) : string =
  match e with
  | ELit { lit = LString s; _ } -> s
  | ELit { lit = LInt n; _ } -> string_of_int n
  | ELit { lit = LBool b; _ } -> if b then "true" else "false"
  | EApp { fn = EVar { name = "env"; _ }; arg = ELit { lit = LString v; _ }; _ } ->
    Printf.sprintf "env(%S)" v
  | EApp { fn = EApp { fn = EVar { name = "envInt"; _ };
                       arg = ELit { lit = LString v; _ }; _ };
           arg = ELit { lit = LInt n; _ }; _ } ->
    Printf.sprintf "envInt(%S,%d)" v n
  | EApp { fn = EApp { fn = EVar { name = "envString"; _ };
                       arg = ELit { lit = LString v; _ }; _ };
           arg = ELit { lit = LString d; _ }; _ } ->
    Printf.sprintf "envString(%S,%S)" v d
  | _ -> ""

let desugar_database_config (d : database_form) : database_form =
  match d.config_expr with
  | None -> d
  | Some e ->
    let top = config_record_fields e in
    let schema =
      match List.assoc_opt "schema" top with
      | Some (ELit { lit = LString s; _ }) -> s | _ -> ""
    in
    let entities =
      match List.assoc_opt "entities" top with
      | Some (EList { elems; _ }) -> List.filter_map config_ctor_name elems
      | _ -> []
    in
    (* backend: Postgres (PostgresConfig { … }) | Memory *)
    let backend_expr = List.assoc_opt "backend" top in
    let backend = match Option.map config_ctor_name backend_expr with
      | Some (Some "Memory") -> "memory"
      | _ -> "postgres"
    in
    let postgres_expr =
      match backend_expr with
      | Some b -> (match config_ctor_name b with
          | Some "Postgres" ->
            (match b with EApp { arg; _ } -> Some arg | _ -> None)
          | _ -> None)
      | None -> None
    in
    let postgres =
      match postgres_expr with
      | Some pg ->
        let pf = config_record_fields pg in
        let scalar key out =
          match List.assoc_opt key pf with
          | Some v -> [ (out, render_config_value v) ] | None -> []
        in
        let conn =
          match List.assoc_opt "connection" pf with
          | Some c ->
            let cf = config_record_fields c in
            let get k out = match List.assoc_opt k cf with
              | Some v -> [ (out, render_config_value v) ] | None -> [] in
            (match config_ctor_name c with
             | Some "TcpConnection" -> get "host" "host" @ get "port" "port"
             | Some "SocketConnection" -> get "path" "socket"
             | _ -> [])
          | None -> []
        in
        (* Issue #31: `poolSize` keeps its surface spelling here; the emitter
           maps it to the runtime's `#:max-connections` keyword (same pattern
           as `host` → `#:server`). *)
        scalar "dbName" "database" @ scalar "user" "user"
        @ scalar "password" "password" @ scalar "poolSize" "poolSize" @ conn
      | None -> []
    in
    { d with backend; schema; entities; postgres; config_expr = None }

let int_value = function ELit { lit = LInt n; _ } -> Some n | _ -> None
let string_value = function ELit { lit = LString s; _ } -> Some s | _ -> None
let bool_value = function ELit { lit = LBool b; _ } -> Some b | _ -> None

(* App pass: a folded queue's `jobs: [Job J fn (Something dead)]` pairs each job
   type with its handler and an optional dead-letter handler. Returns
   (jobType, handler, dead_handler option) per entry; [] for the plain
   `jobs: [JobType]` form. *)
let job_entries (jobs_v : expr) : (string * string * string option) list =
  match jobs_v with
  | EList { elems; _ } ->
    List.filter_map (fun e ->
      match e with
      | EApp { fn = EApp { fn = EApp { fn = EConstructor { name = "Job"; _ }; arg = jt; _ };
                           arg = h; _ }; arg = dead; _ } ->
        let jobtype = Option.value ~default:"" (config_ctor_name jt) in
        let handler = (match h with
          | EVar { name; _ } -> name
          | _ -> Option.value ~default:"" (config_ctor_name h)) in
        let dead_h = (match dead with
          | EApp { fn = EConstructor { name = "Something"; _ }; arg = EVar { name; _ }; _ } -> Some name
          | EConstructor { name = "Something"; args = [ EVar { name; _ } ]; _ } -> Some name
          | _ -> None) in
        if jobtype = "" then None else Some (jobtype, handler, dead_h)
      | _ -> None) elems
  | _ -> []

(* Synthesize the worker declarations folded into a queue's job list. Names are
   deterministic (`<Queue>Workers` / `<Queue>DeadWorkers`) so the App-startup
   desugar can reference them. *)
let folded_queue_workers (q : queue_form) : workers_form list =
  match q.config_expr with
  | None -> []
  | Some e ->
    let entries = match List.assoc_opt "jobs" (config_record_fields e) with
      | Some v -> job_entries v | None -> [] in
    if entries = [] then []
    else
      let regular = { Ast.name = q.name ^ "Workers"; queue_name = q.name;
                      bindings = List.map (fun (jt, h, _) -> (jt, h)) entries;
                      is_dead = false; loc = q.loc } in
      let dead = List.filter_map (fun (jt, _, d) ->
        Option.map (fun dh -> (jt, dh)) d) entries in
      regular :: (if dead = [] then []
                  else [ { Ast.name = q.name ^ "DeadWorkers"; queue_name = q.name;
                           bindings = dead; is_dead = true; loc = q.loc } ])

let desugar_queue_config (q : queue_form) : queue_form =
  match q.config_expr with
  | None -> q
  | Some e ->
    let top = config_record_fields e in
    let database = match List.assoc_opt "database" top with
      | Some v -> Option.value ~default:"" (config_ctor_name v) | None -> "" in
    let jobs_v = List.assoc_opt "jobs" top in
    let entries = match jobs_v with Some v -> job_entries v | None -> [] in
    let jobs =
      if entries <> [] then List.map (fun (jt, _, _) -> jt) entries
      else (match jobs_v with
            | Some (EList { elems; _ }) -> List.filter_map config_ctor_name elems | _ -> []) in
    let number_of_workers = match List.assoc_opt "numberOfWorkers" top with
      | Some v -> int_value v | None -> q.number_of_workers in
    let max_attempts = ref None and backoff = ref None and initial_delay = ref None in
    (match List.assoc_opt "retry" top with
     | Some r ->
       let rf = config_record_fields r in
       (match List.assoc_opt "maxAttempts" rf with Some v -> max_attempts := int_value v | None -> ());
       (match List.assoc_opt "initialDelay" rf with Some v -> initial_delay := int_value v | None -> ());
       (match List.assoc_opt "backoff" rf with
        | Some v -> (match config_ctor_name v with
            | Some "Exponential" -> backoff := Some "exponential"
            | Some "Fixed" -> backoff := Some "fixed"
            | Some "Linear" -> backoff := Some "linear"
            | _ -> ())
        | None -> ())
     | None -> ());
    { q with database; jobs; max_attempts = !max_attempts; backoff = !backoff;
             initial_delay = !initial_delay; number_of_workers; config_expr = None }

(** Effective job-type names for a queue, for the job→queue resolution table.
    For the old syntax this is [q.jobs]; for the typed form ([queue Q = Queue {
    jobs: [...] }]) [q.jobs] is still empty until {!desugar_queue_config} runs, so
    we read the [jobs] field out of [config_expr] directly — the same extraction
    {!desugar_queue_config} performs.  Without this the enqueue lowering falls
    back to the per-call [(queue-for-job-ref <JobType>)] registry lookup instead of
    the queue's direct compile-time binding. *)
let queue_job_types (q : queue_form) : string list =
  if q.jobs <> [] then q.jobs
  else match q.config_expr with
    | None -> []
    | Some e ->
      (match List.assoc_opt "jobs" (config_record_fields e) with
       | None -> []
       | Some v ->
         let entries = job_entries v in
         if entries <> [] then List.map (fun (jt, _, _) -> jt) entries
         else (match v with
               | EList { elems; _ } -> List.filter_map config_ctor_name elems
               | _ -> []))

let desugar_email_config (em : email_form) : email_form =
  match em.config_expr with
  | None -> em
  | Some e ->
    let top = config_record_fields e in
    let database = match List.assoc_opt "database" top with
      | Some v -> Option.value ~default:"" (config_ctor_name v) | None -> "" in
    let smtp =
      match List.assoc_opt "smtp" top with
      | Some sm ->
        let sf = config_record_fields sm in
        let str k d = match List.assoc_opt k sf with Some v -> render_config_value v |> (fun r -> if r = "" then d else r) | None -> d in
        let host = (match List.assoc_opt "host" sf with Some v -> render_config_value v | None -> "") in
        let port = (match List.assoc_opt "port" sf with Some v -> Option.value ~default:587 (int_value v) | None -> 587) in
        let tls = (match List.assoc_opt "tls" sf with Some v -> Option.value ~default:true (bool_value v) | None -> true) in
        { Ast.host; port; username = str "username" ""; password = str "password" ""; tls }
      | None -> em.smtp
    in
    { em with database; smtp; config_expr = None }

let desugar_channel_config (c : channel_form) : channel_form =
  match c.config_expr with
  | None -> c
  | Some e ->
    let top = config_record_fields e in
    let database = match List.assoc_opt "database" top with
      | Some v -> Option.value ~default:"" (config_ctor_name v) | None -> "" in
    let payload = match List.assoc_opt "payload" top with
      | Some v -> (match config_ctor_name v with
          | Some n -> TName { name = n; loc = c.loc } | None -> c.payload)
      | None -> c.payload in
    { c with database; payload; config_expr = None }

(** Effective payload type of a channel, for CHECK-time consumers (the wire
    walk): [c.payload] for the old syntax; for the typed form (`sseChannel
    C(k) = SseChannel { … }`) [c.payload] is still the parser placeholder
    until {!desugar_channel_config} runs, so read the [payload] field out of
    [config_expr] directly — the same extraction the desugar performs. *)
let channel_payload_type (c : channel_form) : type_expr =
  match c.config_expr with
  | None -> c.payload
  | Some e ->
    (match List.assoc_opt "payload" (config_record_fields e) with
     | Some v ->
       (match config_ctor_name v with
        | Some n -> TName { name = n; loc = c.loc }
        | None -> c.payload)
     | None -> c.payload)

let desugar_cache_config (c : cache_form) : cache_form =
  match c.config_expr with
  | None -> c
  | Some e ->
    let top = config_record_fields e in
    let database = match List.assoc_opt "database" top with
      | Some v -> Option.value ~default:"" (config_ctor_name v) | None -> "" in
    let default_ttl = match List.assoc_opt "defaultTtl" top with
      | Some v -> int_value v | None -> None in
    let value_type = match List.assoc_opt "valueType" top with
      | Some v -> (match config_ctor_name v with
          | Some n -> TName { name = n; loc = c.loc } | None -> c.value_type)
      | None -> c.value_type in
    { c with database; default_ttl; value_type; config_expr = None }

(* Lift the `= Agent { … }` record into the structured fields the emitter reads.
   `provider:` is a bare identifier (anthropic|openai|local); `tools:` is a list of
   bare function names (like a server's handler bindings); `apiKey`/`model`/
   `endpoint`/`systemPrompt` render to the emitter's intermediate strings (literal
   or env("X")). *)
let desugar_agent_config (a : agent_form) : agent_form =
  match a.config_expr with
  | None -> a
  | Some e ->
    let top = config_record_fields e in
    let provider = match List.assoc_opt "provider" top with
      | Some (EVar { name; _ }) -> String.lowercase_ascii name
      | Some v -> (match config_ctor_name v with
          | Some n -> String.lowercase_ascii n
          | None -> Option.value ~default:"anthropic" (string_value v))
      | None -> "anthropic" in
    let render key = match List.assoc_opt key top with
      | Some v -> render_config_value v | None -> "" in
    let model = render "model" in
    let api_key = render "apiKey" in
    let endpoint = render "endpoint" in
    let system_prompt = render "systemPrompt" in
    let max_tokens = match List.assoc_opt "maxTokens" top with
      | Some v -> Option.value ~default:1024 (int_value v) | None -> 1024 in
    let tools = match List.assoc_opt "tools" top with
      | Some (EList { elems; _ }) ->
        List.filter_map (function
          | EVar { name; _ } -> Some name
          | el -> config_ctor_name el) elems
      | _ -> [] in
    (* Keep [config_expr] so {!Emit_racket.emit_agent} can lower the unified
       `Agent { … }` constructor through the shared expression arm (the block is
       just a top-level binding of that expression). The lifted fields below are
       still populated for any consumer that reads the structured view. *)
    { a with provider; model; api_key; endpoint; system_prompt;
             max_tokens; tools; config_expr = Some e }

(** Lower every [expr] carried by a test block.  [DTest]/[DApiTest]/[DLoadTest]
    were previously passed through verbatim — sound only while the lowered
    fixed-shape forms never appeared in a test body.  The cache/email lowering
    DOES occur in test bodies (e.g. [tests/cache-tests], [tests/email-tests]),
    so the pass must reach those expressions too; otherwise a lowered form
    reaches the emitter un-desugared and trips its guard.  [lower_expr] is the
    identity on every non-effect node, so traversing a test body that uses no
    effect form is a structural no-op (byte-identical emitted Racket). *)
let rec desugar_test_stmt (tables : lower_tables) (ts : test_stmt) : test_stmt =
  let de = desugar_expr tables in
  match ts with
  | TsLet r -> TsLet { r with value = de r.value }
  | TsLetProof r -> TsLetProof { r with value = de r.value }
  | TsExpect r -> TsExpect { r with left = de r.left; right = Option.map de r.right }
  | TsExpectFail r -> TsExpectFail { r with fn = de r.fn; arg = de r.arg }
  | TsExpectHasProof r -> TsExpectHasProof { r with fn = de r.fn; arg = de r.arg }
  | TsProperty r ->
    TsProperty { r with
      params = List.map (fun (p : property_param) ->
        { p with where_clause = Option.map de p.where_clause }) r.params;
      body = de r.body }
  | TsIf r ->
    TsIf { r with cond = de r.cond;
                  then_stmts = List.map (desugar_test_stmt tables) r.then_stmts;
                  else_stmts = List.map (desugar_test_stmt tables) r.else_stmts }
  | TsCase r ->
    TsCase { r with scrut = de r.scrut;
                    arms = List.map (fun (a : ts_case_arm) ->
                      { a with ts_guard = Option.map de a.ts_guard;
                               ts_body = List.map (desugar_test_stmt tables) a.ts_body })
                      r.arms }
  | TsExpr r -> TsExpr { r with e = de r.e }

let desugar_decl (tables : lower_tables) (d : top_decl) : top_decl =
  match d with
  | DFunc fd -> DFunc { fd with body = desugar_expr tables fd.body }
  | DConst cf -> DConst { cf with value = desugar_expr tables cf.value }
  | DDatabase db -> DDatabase (desugar_database_config db)
  | DQueue q -> DQueue (desugar_queue_config q)
  | DEmail em -> DEmail (desugar_email_config em)
  | DChannel c -> DChannel (desugar_channel_config c)
  | DCache c -> DCache (desugar_cache_config c)
  | DAgent a -> DAgent (desugar_agent_config a)
  | DTest tf ->
    DTest { tf with stmts = List.map (desugar_test_stmt tables) tf.stmts }
  | DApiTest af ->
    DApiTest { af with
      seed_stmts = List.map (desugar_expr tables) af.seed_stmts;
      stmts = List.map (desugar_test_stmt tables) af.stmts }
  | DLoadTest lf ->
    DLoadTest { lf with
      seed_stmts = List.map (desugar_expr tables) lf.seed_stmts;
      request_stmts = List.map (desugar_test_stmt tables) lf.request_stmts }
  | DType _ | DRecord _ | DEntity _ | DFact _ | DCodec _
  | DCapability _ | DWorkers _
  | DCapture _ | DApi _ | DServer _ -> d

(** Lower a whole module.  Lowers the fixed-shape effect forms (EEnqueue /
    EStartWorkers / EServe) to {!Ast.ERuntimeCall}; all other nodes pass through
    structurally identical (every [loc] preserved), so {!Emit_racket} produces
    byte-identical Racket. *)
(* Lower an inline endpoint capture (`capture x: T with <codec> [via <check>]`)
   into a synthesized top-level `capturer` plus a plain `via` reference to it.
   This keeps the emitter/runtime on a single capture path: every endpoint capture
   becomes a `via <capturerName>` after desugaring. Synthesized capturers are
   returned to be prepended to the module (so the define-capture precedes the
   define-api that references it). *)
let desugar_api_inline_captures (synthetic : capture_form list ref) (counter : int ref)
    (api : api_form) : api_form =
  let lower_endpoint (ep : api_endpoint) : api_endpoint =
    let captures' =
      List.map (fun (c : api_capture) ->
        match c.inline_codec with
        | None -> c
        | Some codec ->
          incr counter;
          let cap_name = Printf.sprintf "__inline_capturer_%s_%d" c.binding.name !counter in
          synthetic := {
            name    = cap_name;
            binding = c.binding;
            parser  = codec;
            checker = c.inline_check;
            loc     = c.binding.loc;
          } :: !synthetic;
          { c with via_fn = cap_name; inline_codec = None; inline_check = None }
      ) ep.captures
    in
    { ep with captures = captures' }
  in
  { api with endpoints = List.map lower_endpoint api.endpoints }

(* App pass: lower `main() -> App requires [R] = … App { database, queues, email,
   sseChannels, api, port }` into the imperative startup the runtime already
   understands: `with capabilities [R] { with database D { startWorkers… ;
   startEmailWorker… ; serve api #:port port } }`. Worker capabilities/concurrency
   come from each queue's `requires`/`numberOfWorkers`. *)
let queue_startup_info (q : queue_form) : string * string list * int option * bool =
  let nw, has_dead = match q.config_expr with
    | Some e ->
      let fields = config_record_fields e in
      let nw = match List.assoc_opt "numberOfWorkers" fields with Some v -> int_value v | None -> None in
      let hd = match List.assoc_opt "jobs" fields with
        | Some v -> List.exists (fun (_, _, d) -> d <> None) (job_entries v) | None -> false in
      (nw, hd)
    | None -> (q.number_of_workers, false)
  in
  (q.name, q.capabilities, nw, has_dead)

let lower_main_app (decls : top_decl list) (fd : func_decl) : func_decl =
  if fd.kind <> MainKind then fd else
  let qinfo = List.filter_map (function DQueue q -> Some (queue_startup_info q) | _ -> None) decls in
  let find_q n = List.find_opt (fun (qn, _, _, _) -> qn = n) qinfo in
  let main_caps = fd.capabilities and loc = fd.loc in
  let names_of = function
    | EList { elems; _ } -> List.filter_map config_ctor_name elems | _ -> [] in
  let is_app = function
    | ERecord { type_hint = Some "App"; fields; _ } -> Some fields
    | EApp { fn = EConstructor { name = "App"; _ }; arg = ERecord { fields; _ }; _ } -> Some fields
    | _ -> None in
  let db_of fields =
    match List.assoc_opt "database" fields with Some v -> Option.value ~default:"" (config_ctor_name v) | None -> "" in
  (* The startup chain (start-workers per activated queue, start-email-workers,
     then serve) that REPLACES the `App { … }` record at the tail of main's body. *)
  let startup_chain fields =
    let qs  = match List.assoc_opt "queues" fields with Some v -> names_of v | None -> [] in
    let es  = match List.assoc_opt "email" fields with Some v -> names_of v | None -> [] in
    let api = match List.assoc_opt "api" fields with Some v -> Option.value ~default:"" (config_ctor_name v) | None -> "" in
    let port = match List.assoc_opt "port" fields with Some v -> v | None -> ELit { lit = LInt 8080; loc } in
    let static_dir = match List.assoc_opt "static" fields with
      | Some (ELit { lit = LString s; _ }) -> Some s
      | _ -> None in
    let worker_stmts = List.concat_map (fun qn ->
      let (caps, nw, has_dead) = match find_q qn with Some (_, c, n, d) -> (c, n, d) | None -> ([], None, false) in
      EStartWorkers { workers_name = qn ^ "Workers"; capabilities = caps; concurrency = nw; is_dead = false; loc }
      :: (if has_dead then [ EStartWorkers { workers_name = qn ^ "DeadWorkers"; capabilities = caps; concurrency = nw; is_dead = true; loc } ] else [])
    ) qs in
    let email_stmts = List.map (fun en -> EStartEmailWorker { email_name = en; loc }) es in
    let serve = EServe { server_name = api; port; capabilities = main_caps; static_dir; loc } in
    let rec chain = function
      | [] -> serve
      | [ last ] -> last
      | s :: rest -> ELet { name = "_"; declared_type = None; declared_proof = None; value = s; body = chain rest; loc }
    in
    chain (worker_stmts @ email_stmts @ [ serve ])
  in
  (* Walk the let-chain of main's body to the trailing `App { … }` record. *)
  let rec find_app e = match e with
    | ELet r      -> find_app r.body
    | ELetProof r -> find_app r.body
    | _           -> is_app e
  in
  (* Replace ONLY the trailing App record with the startup chain, preserving the
     user's `let … = …` startup statements (seed, telemetry, port) in place. *)
  let rec rewrite e = match e with
    | ELet r      -> ELet { r with body = rewrite r.body }
    | ELetProof r -> ELetProof { r with body = rewrite r.body }
    | _ -> (match is_app e with Some fields -> startup_chain fields | None -> e)
  in
  match find_app fd.body with
  | None -> fd  (* no App record returned — leave untouched *)
  | Some fields ->
    (* Per the App-model design: the WHOLE main body (the user's seed/telemetry/
       let statements AND the synthesized startup) runs inside main's capability +
       database scope, so DB-context startup steps like `seedExampleData()` have
       database access.  The static-checker is scope-unaware (per-function
       `requires`), so this affects only the runtime scope, not capability checking. *)
    let body' =
      EWithCapabilities { capabilities = main_caps;
        body = EWithDatabase { database_name = db_of fields; body = rewrite fd.body; loc }; loc }
    in
    { fd with body = body' }

let desugar_module (m : module_form) : module_form =
  (* Build the same-module resolution tables from this module's declarations:
     job-type → queue map from DQueue (same construction as Emit_racket's
     pre-pass), plus the local cache / email name sets (the #41 hit/miss rule
     for the cache and email families — see [lower_tables]). *)
  let tables = { queues = Hashtbl.create 16;
                 caches = Hashtbl.create 4;
                 emails = Hashtbl.create 4 } in
  List.iter (function
    | DQueue (q : queue_form) -> List.iter (fun job -> Hashtbl.replace tables.queues job q.name) (queue_job_types q)
    | DCache (c : cache_form) -> Hashtbl.replace tables.caches c.name ()
    | DEmail (em : email_form) -> Hashtbl.replace tables.emails em.name ()
    | _ -> ()) m.decls;
  (* First lower inline endpoint captures into synthesized top-level capturers. *)
  let synthetic = ref [] in
  let counter = ref 0 in
  let decls1 =
    List.map (function
      | DApi api -> DApi (desugar_api_inline_captures synthetic counter api)
      | d -> d) m.decls
  in
  (* Prepend the synthesized capturers (define-capture must precede the
     define-api/server that references them), then run the normal desugaring. *)
  let decls2 = List.rev_map (fun cf -> DCapture cf) !synthetic @ decls1 in
  (* App pass: synthesize the worker declarations folded into each queue's job
     list (`jobs: [Job J fn (Something dead)]`). *)
  let folded_workers =
    List.concat_map (function
      | DQueue q -> List.map (fun w -> DWorkers w) (folded_queue_workers q)
      | _ -> []) decls2
  in
  (* App pass: lower `main() -> App = App { … }` into the imperative startup
     (before desugar_decl lowers the EStartWorkers/EServe it generates). *)
  let decls3 =
    List.map (function
      | DFunc fd when fd.kind = MainKind -> DFunc (lower_main_app decls2 fd)
      | d -> d) (decls2 @ folded_workers)
  in
  { m with decls = List.map (desugar_decl tables) decls3 }

(** {2 Name-wired use detection (issue #41 class)}

    The cache / email families resolve their NAME operand against the module's
    own declarations (see {!lower_tables}); when the declaring block lives in
    another module the lowering splices a per-call registry lookup, which needs
    the [tesl/tesl/cache] / [tesl/tesl/email] runtime require in the USING
    module too.  These predicates are the single owner of "does this module use
    the cache/email surface" for {!Emit_racket.emit_requires} (declares-OR-uses
    gate).  They recognise BOTH the surface forms (pre-desugar) and the lowered
    {!Ast.ERuntimeCall} prefixes (post-desugar — [emit_requires] runs on the
    desugared module), so the answer is stable on either side of the pass. *)

(** Fold [f] over every expression (recursively) reachable from the module's
    declarations: function bodies, consts, and all test-block statements. *)
let module_fold_exprs (f : 'a -> expr -> 'a) (init : 'a) (m : module_form) : 'a =
  let rec walk acc e =
    let acc = f acc e in
    Ast_visitor.fold_children walk acc e
  in
  let walk_stmts acc stmts =
    List.fold_left (fun acc s -> List.fold_left walk acc (Ast.test_stmt_exprs s)) acc stmts
  in
  List.fold_left (fun acc d ->
    match d with
    | DFunc (fd : func_decl) -> walk acc fd.body
    | DConst (c : const_form) -> walk acc c.value
    | DTest (tf : test_form) -> walk_stmts acc tf.stmts
    | DApiTest (af : api_test_form) ->
      walk_stmts (List.fold_left walk acc af.seed_stmts) af.stmts
    | DLoadTest (lf : load_test_form) ->
      walk_stmts (List.fold_left walk acc lf.seed_stmts) lf.request_stmts
    | _ -> acc
  ) init m.decls

let runtime_call_has_prefix (prefixes : string list) (e : expr) : bool =
  match e with
  | ERuntimeCall { segments = RLit s :: _; _ } ->
    List.exists (fun p ->
      String.length s >= String.length p && String.sub s 0 (String.length p) = p
    ) prefixes
  | _ -> false

(** Does the module use any cache operation (Cache.get/set/delete/invalidate)?
    Also true when a `requires [cacheCap <Name>]` names a NON-local cache: the
    emitter resolves that capability VALUE through [cache-for-name] too, so the
    runtime require is needed even without a direct cache op. *)
let module_uses_cache (m : module_form) : bool =
  let local_caches =
    List.filter_map (function DCache (c : cache_form) -> Some c.name | _ -> None) m.decls in
  let cap_names_non_local caps =
    List.exists (fun cap ->
      String.length cap >= 9 && String.sub cap 0 9 = "cacheCap "
      && not (List.mem (String.sub cap 9 (String.length cap - 9)) local_caches)
    ) caps
  in
  let requires_non_local_cap =
    List.exists (function
      | DFunc (fd : func_decl) -> cap_names_non_local fd.capabilities
      | DQueue (q : queue_form) -> cap_names_non_local q.capabilities
      | DAgent (a : agent_form) -> cap_names_non_local a.capabilities
      | DTest (tf : test_form) -> cap_names_non_local tf.capabilities
      | DApiTest (af : api_test_form) -> cap_names_non_local af.capabilities
      | DLoadTest (lf : load_test_form) -> cap_names_non_local lf.capabilities
      (* `capability admin implies cacheCap <Name>` with a non-local Name:
         the emitter synthesizes `(define cacheCap_<Name> (… (cache-for-name
         '<Name>)))` for it, and cache-for-name is bound by tesl/tesl/cache. *)
      | DCapability (c : capability_form) -> cap_names_non_local c.implies
      | _ -> false
    ) m.decls
  in
  requires_non_local_cap
  || module_fold_exprs (fun found e ->
       found
       || (match e with
           | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _ -> true
           | _ ->
             runtime_call_has_prefix
               [ "(cache-get! "; "(cache-set! "; "(cache-delete! ";
                 "(cache-invalidate-prefix! " ] e)
     ) false m

(** Does the module use any email operation (Email.send / startEmailWorker)?
    Also true when any requires-list names [emailCap] — mirroring the
    [cacheCap <Name>] handling in {!module_uses_cache}: `emailCap` is bound
    ONLY by tesl/email.rkt, so a `fn notify(...) requires [emailCap]` that
    merely wraps an imported email-sending fn (no direct email op in THIS
    module) still needs the runtime require, or the emitted
    `#:capabilities [emailCap]` fails to load (`emailCap: unbound
    identifier`). *)
let module_uses_email (m : module_form) : bool =
  (* A module may declare its OWN `capability emailCap …` (lesson31 does):
     then every `requires [emailCap]` names the LOCAL define-capability, not
     the builtin from tesl/email.rkt — the same local-shadow rule as the
     local-cache exclusion in module_uses_cache. *)
  let local_email_cap =
    List.exists (function
      | DCapability (c : capability_form) -> c.name = "emailCap"
      | _ -> false
    ) m.decls
  in
  let caps_name_email_cap caps =
    (not local_email_cap) && List.mem "emailCap" caps in
  let requires_email_cap =
    List.exists (function
      | DFunc (fd : func_decl) -> caps_name_email_cap fd.capabilities
      | DQueue (q : queue_form) -> caps_name_email_cap q.capabilities
      | DAgent (a : agent_form) -> caps_name_email_cap a.capabilities
      | DTest (tf : test_form) -> caps_name_email_cap tf.capabilities
      | DApiTest (af : api_test_form) -> caps_name_email_cap af.capabilities
      | DLoadTest (lf : load_test_form) -> caps_name_email_cap lf.capabilities
      (* `capability x implies emailCap` — define-capability references the
         emailCap identifier at instantiation. *)
      | DCapability (c : capability_form) -> caps_name_email_cap c.implies
      | _ -> false
    ) m.decls
  in
  requires_email_cap
  || module_fold_exprs (fun found e ->
       found
       || (match e with
           | ESendEmail _ | EStartEmailWorker _ -> true
           | _ -> runtime_call_has_prefix [ "(send-email! "; "(start-email-worker!" ] e)
     ) false m

(** {2 Name-wired uses for the whole-program closure diagnostic}

    Collect every (kind, name, loc) triple where the module references a
    name-wired runtime object: cache ops, email ops, `publish` channels and
    `enqueue` job types.  Consumed by {!Compile.cross_module_diags}: when the
    ENTRY module is a program root, a name declared NOWHERE in the transitive
    import closure can never resolve at runtime (the domain registry only
    holds specs from modules that are actually required), so the check rejects
    it early instead of leaving the failure to the runtime lookup.  Surface
    forms only — the collector runs on parsed (pre-desugar) modules. *)
type wired_use_kind = UseCache | UseEmail | UseChannel | UseJobType

let collect_name_wired_uses (m : module_form)
  : (wired_use_kind * string * Location.loc) list =
  let expr_uses =
    List.rev
      (module_fold_exprs (fun acc e ->
         match e with
         | ECacheGet { cache_name; loc; _ } | ECacheSet { cache_name; loc; _ }
         | ECacheDelete { cache_name; loc; _ } | ECacheInvalidate { cache_name; loc; _ } ->
           (UseCache, cache_name, loc) :: acc
         | ESendEmail { email_name; loc; _ } | EStartEmailWorker { email_name; loc; _ } ->
           (UseEmail, email_name, loc) :: acc
         | EPublish { channel_name; loc; _ } ->
           (UseChannel, channel_name, loc) :: acc
         | EEnqueue { job_type; loc; _ } ->
           (UseJobType, job_type, loc) :: acc
         | _ -> acc
       ) [] m)
  in
  (* SSE endpoints subscribe to a channel by name too (`sse "/p" … subscribe
     Ch(k)`), the second name-wired channel position (the sse-routes list). *)
  let subscribe_uses =
    List.concat_map (function
      | DApi (api : api_form) ->
        List.concat_map (fun (ep : api_endpoint) ->
          List.map (fun ch -> (UseChannel, ch, ep.loc)) (Ast.ep_subscribes ep)
        ) api.endpoints
      | _ -> []
    ) m.decls
  in
  expr_uses @ subscribe_uses

(** Name-wired objects DECLARED by a module, for the same closure diagnostic:
    cache / email / channel names plus every job type its queues handle. *)
let collect_name_wired_decls (m : module_form)
  : (wired_use_kind * string) list =
  List.concat_map (function
    | DCache (c : cache_form) -> [ (UseCache, c.name) ]
    | DEmail (em : email_form) -> [ (UseEmail, em.name) ]
    | DChannel (ch : channel_form) -> [ (UseChannel, ch.name) ]
    | DQueue (q : queue_form) ->
      List.map (fun jt -> (UseJobType, jt)) (queue_job_types q)
    | _ -> []
  ) m.decls
