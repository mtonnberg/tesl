(** Tesl built-in mutation testing engine.

    Targets [check], [auth], and [establish] function bodies — the GDP
    boundary predicates whose correctness is most critical to the security
    model.  For each such function, every binary operator that has a
    "semantically close but subtly different" alternative is systematically
    replaced, one at a time.  Each mutant is emitted as a complete Racket
    module (test blocks intact) and evaluated with [raco test].  Surviving
    mutants (where the tests still pass) indicate test coverage gaps.

    Usage: [tesl --mutate file.tesl]
*)

open Ast

(* ── Operator mutation alternatives ────────────────────────────────────── *)

let binop_display = function
  | BAdd    -> "+"  | BSub -> "-"  | BMul -> "*"
  | BDiv    -> "/"  | BMod -> "%"  | BConcat -> "++"
  | BAnd    -> "&&" | BOr  -> "||"
  | BEq     -> "==" | BNeq -> "!="
  | BLt     -> "<"  | BLe  -> "<=" | BGt -> ">" | BGe -> ">="

(** For each operator, return the alternatives to try.  Only comparison and
    boolean operators are mutated: these are the ones most likely to silently
    break security invariants.  Off-by-one boundary flips (> vs >=) and logic
    inversions (&& vs ||) are historically the most dangerous survivors. *)
let mutation_alternatives = function
  | BGt  -> [BGe; BLt; BLe]   (* > → >=, <, <= — boundary/direction *)
  | BLt  -> [BLe; BGt; BGe]   (* < → <=, >, >= *)
  | BGe  -> [BGt; BLe; BLt]   (* >= → >, <=, < *)
  | BLe  -> [BLt; BGe; BGt]   (* <= → <, >=, > *)
  | BEq  -> [BNeq]             (* == → != *)
  | BNeq -> [BEq]              (* != → == *)
  | BAnd -> [BOr]              (* && → || — logic inversion *)
  | BOr  -> [BAnd]             (* || → && *)
  | BAdd -> [BSub]             (* + → - — arithmetic flip *)
  | BSub -> [BAdd]             (* - → + *)
  | _    -> []                 (* *, /, %, ++ — not mutated *)

(* ── Mutation site collection ───────────────────────────────────────────── *)

type mutation_site = {
  fn_name    : string;
  fn_kind    : func_kind;
  site_index : int;       (** stable 0-based index from pre-order walk *)
  original_op : binop;
  loc         : Location.loc;
}

(** Walk [body], accumulating every [EBinop] that has at least one
    mutation alternative.  [counter] tracks the pre-order index of
    every binop node (including non-mutable ones) to ensure indices
    remain stable when a specific node is later substituted.

    The structural recursion is delegated to {!Ast_visitor.iter}, the single
    shared pre-order, left-to-right traversal.  We only special-case [EBinop]
    to assign/advance the index and (conditionally) record a site; the visitor
    still descends into the binop's children afterwards, so the pre-order index
    sequence is byte-identical to the previous hand-rolled walk.  Sharing the
    traversal guarantees a new {!Ast.expr} variant cannot silently escape
    mutation-site collection. *)
let collect_sites fn_name fn_kind body =
  let counter = ref 0 in
  let acc     = ref [] in
  let visit e =
    (match e with
     | EBinop { op; loc; _ } ->
       let idx = !counter in
       incr counter;
       (match mutation_alternatives op with
        | [] -> ()
        | _  -> acc := { fn_name; fn_kind; site_index = idx;
                         original_op = op; loc } :: !acc)
     | _ -> ())
  in
  Ast_visitor.iter visit body;
  List.rev !acc

(* ── AST binop replacement ──────────────────────────────────────────────── *)

(** Perform a single-site replacement: walk [expr], replacing the binop
    whose pre-order index equals [target_index] with [new_op].
    [counter] must start at 0 and is shared for the whole walk.

    The boilerplate "rebuild every other node from its rewritten children" is
    delegated to {!Ast_visitor.map_children}, which preserves [loc] and visits
    children left-to-right — the SAME order {!collect_sites} (and the
    [Ast_visitor.iter] underneath it) uses, so the pre-order index a site was
    assigned during collection still names the same node here.

    [EBinop] keeps its bespoke handling: advance the shared counter, and on a
    match swap the operator WITHOUT descending into the operands — exactly as
    the original walk did, so the indices of nested binops are unaffected by a
    replacement at an ancestor binop. *)
let replace_binop_at ~target_index ~new_op expr =
  let counter = ref 0 in
  let rec walk e =
    match e with
    | EBinop { op; left; right; loc } ->
      let idx = !counter in
      incr counter;
      if idx = target_index
      then EBinop { op = new_op; left; right; loc }
      else
        (* Force children left-to-right (map_children does this internally too,
           but we are inside the binop arm where the counter advances). *)
        let left' = walk left in
        let right' = walk right in
        EBinop { op; left = left'; right = right'; loc }
    | _ -> Ast_visitor.map_children walk e
  in
  walk expr

(** Produce a copy of [m] with the [DFunc] for [fn_name] having its body
    mutated at [site_index] with [new_op].  All other declarations are
    unchanged, so test blocks remain intact. *)
let apply_mutation_to_module (m : module_form) fn_name site_index new_op : module_form =
  let decls' = List.map (function
    | DFunc fd when fd.name = fn_name ->
      let body' = replace_binop_at ~target_index:site_index ~new_op fd.body in
      DFunc { fd with body = body' }
    | d -> d
  ) m.decls in
  { m with decls = decls' }

(* ── DB / infrastructure test stubbing ──────────────────────────────────────
   Mutant runs shell out to [raco test] with no live infrastructure.  A test
   block that opens a *real* external connection — a Postgres-backed database,
   an HTTP server ([serve] / [apitest] / [loadtest]), a job queue / worker, or
   an SMTP email sender — will block until it times out (the [timeout] wrapper
   then reports the whole mutant as [Error], masking the pure tests that would
   otherwise have killed it and inflating wall-clock cost).

   [strip_infra_tests] removes exactly those infrastructure-touching test
   declarations from a module before it is emitted for a mutant run, so the
   remaining pure tests (the boundary-predicate [expect]s that actually
   exercise the mutated [check]/[auth]/[establish] logic) run fast and cannot
   hang.  In-memory databases ([backend memory], no [postgres { … }] block)
   are NOT external and are left intact — they run fine under [raco test].

   Score invariance: the set of mutants is derived from function bodies, never
   from tests, so stubbing never changes which mutants exist.  Files with no
   infrastructure tests (e.g. lesson42, lesson44) are returned unchanged, so
   their mutation score is identical to the serial, un-stubbed run. *)

(** Names of databases whose connection params include a non-empty [postgres]
    block — i.e. they connect to a real Postgres server (hang risk with no DB).
    [backend memory] databases have an empty [postgres] list and are excluded. *)
let postgres_database_names (m : module_form) : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 8 in
  List.iter (function
    | DDatabase d when d.postgres <> [] -> Hashtbl.replace tbl d.name ()
    | _ -> ()
  ) m.decls;
  tbl

(** [true] when [e] performs an effect that needs live external infrastructure
    not available in a bare [raco test] mutant run: a Postgres-backed
    [with database], any [serve], queue [enqueue], pub/sub [publish], worker
    start, cache op, or email send.  [with transaction] is treated as external
    because it only ever wraps a real (here, Postgres) database connection. *)
let rec expr_touches_infra ~pg e =
  match e with
  | EWithDatabase { database_name; body; _ } ->
    Hashtbl.mem pg database_name || expr_touches_infra ~pg body
  | EWithTransaction _ | EServe _ | EEnqueue _ | EPublish _
  | EStartWorkers _ | ECacheGet _ | ECacheSet _ | ECacheDelete _
  | ECacheInvalidate _ | ESendEmail _ | EStartEmailWorker _ -> true
  (* structural recursion through everything else *)
  | EApp { fn; arg; _ }            -> expr_touches_infra ~pg fn || expr_touches_infra ~pg arg
  | EUnop { arg; _ }               -> expr_touches_infra ~pg arg
  | EBinop { left; right; _ }      -> expr_touches_infra ~pg left || expr_touches_infra ~pg right
  | EIf { cond; then_; else_; _ } -> expr_touches_infra ~pg cond || expr_touches_infra ~pg then_ || expr_touches_infra ~pg else_
  | ECase { scrut; arms; _ }       ->
    expr_touches_infra ~pg scrut
    || List.exists (fun arm ->
         (match arm.guard with Some g -> expr_touches_infra ~pg g | None -> false)
         || expr_touches_infra ~pg arm.body) arms
  | EWithCapabilities { body; _ }  -> expr_touches_infra ~pg body
  | ELet { value; body; _ }        -> expr_touches_infra ~pg value || expr_touches_infra ~pg body
  | ELetProof { value; body; _ }   -> expr_touches_infra ~pg value || expr_touches_infra ~pg body
  | ERecord { fields; _ }          -> List.exists (fun (_, v) -> expr_touches_infra ~pg v) fields
  | EList { elems; _ }             -> List.exists (expr_touches_infra ~pg) elems
  | EOk { value; _ }               -> expr_touches_infra ~pg value
  | EFail { message; _ }           -> expr_touches_infra ~pg message
  | ETelemetry { fields; _ }       -> List.exists (fun (_, v) -> expr_touches_infra ~pg v) fields
  | EField { obj; _ }              -> expr_touches_infra ~pg obj
  | EConstructor { args; _ }       -> List.exists (expr_touches_infra ~pg) args
  | ELambda { body; _ }            -> expr_touches_infra ~pg body
  | ERuntimeCall _                 -> true  (* desugar-only infra call (EEnqueue/EStartWorkers/EServe) *)
  | ELit _ | EVar _                -> false

(** [true] when a [test_stmt] (recursively) touches external infrastructure. *)
let rec stmt_touches_infra ~pg = function
  | TsLet { value; _ }             -> expr_touches_infra ~pg value
  | TsLetProof { value; _ }        -> expr_touches_infra ~pg value
  | TsExpect { left; right; _ }   ->
    expr_touches_infra ~pg left
    || (match right with Some r -> expr_touches_infra ~pg r | None -> false)
  | TsExpectFail { fn; arg; _ }    -> expr_touches_infra ~pg fn || expr_touches_infra ~pg arg
  | TsExpectHasProof { fn; arg; _ } -> expr_touches_infra ~pg fn || expr_touches_infra ~pg arg
  | TsProperty { body; _ }         -> expr_touches_infra ~pg body
  | TsIf { cond; then_stmts; else_stmts; _ } ->
    expr_touches_infra ~pg cond
    || List.exists (stmt_touches_infra ~pg) then_stmts
    || List.exists (stmt_touches_infra ~pg) else_stmts
  | TsCase { scrut; arms; _ }      ->
    expr_touches_infra ~pg scrut
    || List.exists (fun arm ->
         (match arm.ts_guard with Some g -> expr_touches_infra ~pg g | None -> false)
         || List.exists (stmt_touches_infra ~pg) arm.ts_body) arms
  | TsExpr { e; _ }                -> expr_touches_infra ~pg e

(** Classify a test block's declared capabilities (its [requires [...]] list).
    A test block's capability list is the most reliable infra signal because,
    inside a test, the parser FLATTENS [with database Db { … }] — it discards
    the [EWithDatabase] wrapper and inlines the SQL ops as bare calls — so the
    capability list, not the expression tree, is what survives to mark the
    block as infrastructure-touching.  [time] and [env] are deterministic /
    local (no external service) and so are never infra. *)
let capability_class = function
  (* Database access.  A bare [raco test] only hangs on these when the database
     is Postgres-backed; an in-memory database runs fine, so DB capabilities are
     gated separately on whether the module declares a Postgres database. *)
  | "dbRead" | "dbWrite" -> `Db
  (* External services with no in-process test fallback — always need infra. *)
  | "queueRead" | "queueWrite" | "enqueue" | "publish" | "subscribe"
  | "email" -> `ExternalService
  | c when c = "cache" || (String.length c >= 6 && String.sub c 0 6 = "cache ") ->
    `ExternalService
  | _ -> `Local

(** [true] when a test block's capabilities mean it cannot run in a bare,
    DB-less [raco test].  Queue/cache/email/pub-sub always qualify; a database
    capability qualifies only when [has_pg] (the module has a Postgres-backed
    database, the real hang case) — in-memory database tests run fine and are
    score-relevant, so they are kept. *)
let caps_need_infra ~has_pg caps =
  List.exists (fun c -> match capability_class c with
    | `ExternalService -> true
    | `Db              -> has_pg
    | `Local           -> false) caps

(** Drop every test declaration that needs live external infrastructure so it
    cannot hang or poison a DB-less mutant run.  [DApiTest]/[DLoadTest] are
    server-driven and always require a running server, so they are dropped
    unconditionally.  A plain [DTest] is dropped when EITHER its declared
    capabilities need infrastructure (the primary, parse-stable signal — a
    Postgres [dbRead]/[dbWrite], or any queue/cache/email capability) OR one of
    its statements still structurally touches infrastructure (a Postgres
    [with database], [serve], queue/cache/email op — the secondary signal for
    constructs the parser does not flatten).  In-memory database tests are kept.

    All non-test declarations are preserved verbatim, and a module with no such
    tests is returned unchanged, so its mutation score is identical to the
    serial, un-stubbed run. *)
let strip_infra_tests (m : module_form) : module_form =
  let pg = postgres_database_names m in
  let has_pg = Hashtbl.length pg > 0 in
  let decls' = List.filter (function
    | DApiTest _ | DLoadTest _ -> false
    | DTest t ->
      not (caps_need_infra ~has_pg t.capabilities
           || List.exists (stmt_touches_infra ~pg) t.stmts)
    | _ -> true
  ) m.decls in
  { m with decls = decls' }

(* ── Mutant generation ──────────────────────────────────────────────────── *)

type mutant = {
  site        : mutation_site;
  replacement : binop;
  description : string;
  module_     : module_form;
}

(** Generate every mutant for [m].  Only [CheckKind], [AuthKind], and
    [EstablishKind] function bodies are targeted. *)
let generate_mutants (m : module_form) : mutant list =
  let target_kinds = [CheckKind; AuthKind; EstablishKind] in
  List.concat_map (function
    | DFunc fd when List.mem fd.kind target_kinds ->
      let sites = collect_sites fd.name fd.kind fd.body in
      List.concat_map (fun site ->
        List.map (fun new_op ->
          let module_ = apply_mutation_to_module m fd.name site.site_index new_op in
          let description =
            Printf.sprintf "%s:%d:%d  %s → %s  (in %s)"
              site.loc.file
              (site.loc.start.line + 1)
              (site.loc.start.col + 1)
              (binop_display site.original_op)
              (binop_display new_op)
              site.fn_name
          in
          { site; replacement = new_op; description; module_ }
        ) (mutation_alternatives site.original_op)
      ) sites
    | _ -> []
  ) m.decls

(* ── Result types ───────────────────────────────────────────────────────── *)

type mutant_result =
  | Killed    (** tests failed — mutant detected *)
  | Survived  (** tests passed — mutant went undetected *)
  | NoTests   (** no test block present for this function *)
  | Error of string  (** compilation error in the mutant (counts as killed) *)

type mutation_report = {
  total    : int;
  killed   : int;
  survived : int;
  errors   : int;
  results  : (mutant * mutant_result) list;
}
