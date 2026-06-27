(** Surface-syntax lowering pass (Wave 2: reduce_language_size).

    {2 Where this runs}

    The pipeline is: parse → type-check + proof-check + validation → DESUGAR →
    emit.  Crucially the pass runs AFTER all enforcement/diagnostics (so every
    error message still points at the surface form the user wrote) and BEFORE
    {!Emit_racket} (so the emitter sees the lowered, more primitive forms).

    {2 Identity-first contract}

    This module starts life as a STRICT IDENTITY transform.  {!desugar_module}
    walks every expression in every top-level declaration through
    {!Ast_visitor.map} and applies {!lower_expr} at each node; today
    {!lower_expr} returns its argument unchanged, so the output module is
    structurally identical to the input and the emitted Racket is byte-for-byte
    unchanged.  The value of landing the identity transform now is the plumbing:
    the pass is wired into the pipeline, the provenance helpers exist, and a
    future lowering only has to fill in one [lower_expr] arm.

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

    Deliberately NOT lowered (documented BLOCKED, see roadmap):
    - [ETelemetry] / [EPublish]: their operands branch on emit-time-only
      [ctx.func_kind] / [ctx.raw_locals] to choose [*name] (the raw-param
      blocker) — a desugar pass cannot reproduce that per-leaf decision.
    - [EWithDatabase] / [EWithCapabilities] / [EWithTransaction]: position
      dependent — they emit DIFFERENT runtime calls in tail-raw position
      ([with-database] / [call-with-declared-capabilities]) than in statement
      position ([call-with-database] / [with-capabilities]); a single core form
      cannot capture both.
    - cache / email families: feasible in shape but not exercised by any
      byte-gated lesson reference, so byte-identity cannot be verified.
    - [EUnop] / [LInterp]: the raw-param blocker (see module docstring above). *)

(** The job-type → queue-name resolution table the emitter builds from [DQueue]
    declarations.  Mirrors [Emit_racket.job_type_to_queue]: when a job type has
    no declared queue the emitter falls back to ["_queue_for_" ^ job_type]. *)
let queue_ref_of (queues : (string, string) Hashtbl.t) (job_type : string) : string =
  match Hashtbl.find_opt queues job_type with
  | Some q -> q
  | None -> "_queue_for_" ^ job_type

(** Per-node lowering.  [queues] is the module's job-type → queue map (for
    [EEnqueue]).  {!Ast_visitor.map} has already lowered the node's children by
    the time this is called, so each arm only rewrites the node's own shape and
    reuses the surface node's own [loc] verbatim (span-preserving). *)
let lower_expr (queues : (string, string) Hashtbl.t) (e : expr) : expr =
  match e with
  | EEnqueue { job_type; payload; loc } ->
    (* (enqueue! QUEUE_REF <payload via emit_expr_simple>) *)
    let queue_ref = queue_ref_of queues job_type in
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
    (match concurrency with
     | Some n when n <> 1 -> Buffer.add_string buf (Printf.sprintf " #:concurrency %d" n)
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
  | _ -> e

(** Lower a single expression: bottom-up rewrite via the shared traversal
    framework, so a new {!Ast.expr} variant cannot silently escape the pass. *)
let desugar_expr (queues : (string, string) Hashtbl.t) (e : expr) : expr =
  Ast_visitor.map (lower_expr queues) e

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
    let postgres =
      match List.assoc_opt "postgres" top with
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
        scalar "dbName" "database" @ scalar "user" "user"
        @ scalar "password" "password" @ conn
      | None -> []
    in
    { d with backend = "postgres"; schema; entities; postgres; config_expr = None }

let int_value = function ELit { lit = LInt n; _ } -> Some n | _ -> None
let string_value = function ELit { lit = LString s; _ } -> Some s | _ -> None
let bool_value = function ELit { lit = LBool b; _ } -> Some b | _ -> None

let desugar_queue_config (q : queue_form) : queue_form =
  match q.config_expr with
  | None -> q
  | Some e ->
    let top = config_record_fields e in
    let database = match List.assoc_opt "database" top with
      | Some v -> Option.value ~default:"" (config_ctor_name v) | None -> "" in
    let jobs = match List.assoc_opt "jobs" top with
      | Some (EList { elems; _ }) -> List.filter_map config_ctor_name elems | _ -> [] in
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
            | _ -> ())
        | None -> ())
     | None -> ());
    { q with database; jobs; max_attempts = !max_attempts; backoff = !backoff;
             initial_delay = !initial_delay; config_expr = None }

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

let desugar_decl (queues : (string, string) Hashtbl.t) (d : top_decl) : top_decl =
  match d with
  | DFunc fd -> DFunc { fd with body = desugar_expr queues fd.body }
  | DConst cf -> DConst { cf with value = desugar_expr queues cf.value }
  | DDatabase db -> DDatabase (desugar_database_config db)
  | DQueue q -> DQueue (desugar_queue_config q)
  | DEmail em -> DEmail (desugar_email_config em)
  | DChannel c -> DChannel (desugar_channel_config c)
  | DType _ | DRecord _ | DEntity _ | DFact _ | DCodec _
  | DCapability _ | DWorkers _ | DCache _
  | DCapture _ | DApi _ | DServer _ | DTest _ | DApiTest _
  | DLoadTest _ -> d

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

let desugar_module (m : module_form) : module_form =
  (* Rebuild the emitter's job-type → queue map from this module's DQueue
     declarations (same construction as Emit_racket's pre-pass). *)
  let queues : (string, string) Hashtbl.t = Hashtbl.create 16 in
  List.iter (function
    | DQueue (q : queue_form) -> List.iter (fun job -> Hashtbl.replace queues job q.name) q.jobs
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
  { m with decls = List.map (desugar_decl queues) decls2 }
