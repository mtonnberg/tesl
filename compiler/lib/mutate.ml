(** Tesl built-in mutation testing engine.

    Targets [check], [auth], and [establish] function bodies — the GDP
    boundary predicates whose correctness is most critical to the security
    model.  For each such function, every mutable node whose value has a
    "semantically close but subtly different" alternative is systematically
    replaced, one at a time.  Each mutant is emitted as a complete Racket
    module (test blocks intact) and evaluated with [raco test].  Surviving
    mutants (where the tests still pass) indicate test coverage gaps.

    {2 Mutation operators}

    Four families of AST-rewrite mutators are applied, each total and
    deterministic:

    - {b binary-operator swaps} ([EBinop]): comparison direction/boundary
      ([> ↔ >= ↔ < ↔ <=]), equality inversion ([== ↔ !=]), boolean-logic
      inversion ([&& ↔ ||]) and arithmetic flips ([+ ↔ -]).  Comparison-operator
      swaps in particular exercise off-by-one boundary bugs.
    - {b boolean-literal flip} ([True] ↔ [False]): inverts a hard-coded boolean,
      catching predicates that ignore a branch.  Tesl represents [True]/[False]
      as the nullary constructors [EConstructor {name="True"|"False"; args=[]}]
      (the idiomatic form) and, for the legacy lowercase [true]/[false], as
      [ELit (LBool _)] — both node shapes are flipped.
    - {b integer-literal perturbation} ([ELit (LInt n)] → [LInt (n+1)]): the
      classic off-by-one on a numeric threshold constant.

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

(* ── Mutation operators (node-kind agnostic) ─────────────────────────────── *)

(** A single, concrete AST rewrite applied to one node.  Each constructor names
    both WHICH kind of node is targeted and WHAT the value becomes, so a mutant
    is fully described by [(kind, node-index-within-kind, mutation_op)].  Every
    operator is total (defined for the node it targets) and deterministic (the
    replacement is a pure function of the original value). *)
type mutation_op =
  | MOBinop of binop     (** replace an [EBinop]'s operator with this one *)
  | MOBool  of bool      (** flip a boolean literal (the [True]/[False] constructor,
                             or a legacy [ELit (LBool _)]) to this value *)
  | MOInt   of int       (** replace an [ELit (LInt _)] with this value (n → n+1) *)

(** Which node kind a mutation targets.  Each kind carries its OWN independent
    pre-order index space (see {!collect_sites}), so adding a kind never shifts
    another kind's indices — every mutator stays stable in isolation. *)
type node_kind = KBinop | KBool | KInt

(** [Some b] when [e] is a boolean literal node carrying value [b] — either the
    idiomatic [True]/[False] nullary constructor or the legacy [ELit (LBool _)].
    [None] otherwise.  This is the single definition of "a boolean-literal node",
    used identically by both {!collect_sites} and {!replace_at} so their per-kind
    [KBool] index spaces stay in lockstep. *)
let bool_literal_value = function
  | ELit { lit = LBool b; _ }               -> Some b
  | EConstructor { name = "True";  args = []; _ } -> Some true
  | EConstructor { name = "False"; args = []; _ } -> Some false
  | _ -> None

(** Rebuild boolean-literal node [e] (which must satisfy {!bool_literal_value})
    with value [b], preserving its surface SHAPE (constructor stays a
    constructor, literal stays a literal) and its [loc].  [e] is returned
    unchanged if it is not a boolean-literal node. *)
let set_bool_literal e b =
  match e with
  | ELit { loc; _ }                     -> ELit { lit = LBool b; loc }
  | EConstructor { args = []; loc; _ }  ->
    EConstructor { name = (if b then "True" else "False"); args = []; loc }
  | _ -> e

(** A human-readable "before → after" for the mutation, e.g. ["> → >="],
    ["True → False"], ["3 → 4"]. *)
let mutation_display original op =
  match op, original with
  | MOBinop new_op, MOBinop old_op -> binop_display old_op ^ " → " ^ binop_display new_op
  | MOBool b, MOBool old_b ->
    (if old_b then "True" else "False") ^ " → " ^ (if b then "True" else "False")
  | MOInt n, MOInt old_n -> string_of_int old_n ^ " → " ^ string_of_int n
  | _ -> "?"

(* ── Mutation site collection ───────────────────────────────────────────── *)

type mutation_site = {
  fn_name    : string;
  fn_kind    : func_kind;
  kind       : node_kind;  (** which per-kind index space [site_index] lives in *)
  site_index : int;        (** stable 0-based index within [kind]'s pre-order walk *)
  original   : mutation_op;  (** the node's original value, for reporting *)
  loc        : Location.loc;
}

(** Walk [body], accumulating every mutable node together with the alternatives
    to try at it.  Each node KIND ([EBinop], boolean literal, integer literal)
    is counted in its OWN independent pre-order index space — a binop advances
    only the binop counter, a bool literal only the bool counter, etc. — so
    introducing a new mutator can never renumber another mutator's sites.

    The structural recursion is delegated to {!Ast_visitor.iter}, the single
    shared pre-order, left-to-right traversal, so a new {!Ast.expr} variant
    cannot silently escape mutation-site collection.  For each recorded site we
    also return the list of [mutation_op] alternatives to try there. *)
let collect_sites fn_name fn_kind body : (mutation_site * mutation_op list) list =
  let binop_ctr = ref 0 in
  let bool_ctr  = ref 0 in
  let int_ctr   = ref 0 in
  let acc = ref [] in
  let record kind ctr original alts loc =
    let idx = !ctr in
    incr ctr;
    match alts with
    | [] -> ()
    | _  -> acc := ({ fn_name; fn_kind; kind; site_index = idx; original; loc }, alts) :: !acc
  in
  (* Only ever called on a boolean-literal node (ELit / EConstructor), both of
     which carry a [loc]; the fallback is unreachable but keeps the match total. *)
  let loc_of e =
    match e with
    | ELit { loc; _ } | EConstructor { loc; _ } | EBinop { loc; _ } -> loc
    | _ -> Location.dummy_loc "?"
  in
  let visit e =
    match e with
    | EBinop { op; loc; _ } ->
      let alts = List.map (fun o -> MOBinop o) (mutation_alternatives op) in
      record KBinop binop_ctr (MOBinop op) alts loc
    | ELit { lit = LInt n; loc } ->
      (* Integer-literal perturbation: n → n+1 (classic off-by-one). *)
      record KInt int_ctr (MOInt n) [MOInt (n + 1)] loc
    | _ ->
      (match bool_literal_value e with
       | Some b ->
         (* Boolean-literal flip: True ↔ False (always exactly one alternative). *)
         record KBool bool_ctr (MOBool b) [MOBool (not b)] (loc_of e)
       | None -> ())
  in
  Ast_visitor.iter visit body;
  List.rev !acc

(* ── AST node replacement ────────────────────────────────────────────────── *)

(** Perform a single-site replacement: walk [expr], replacing the node of kind
    [kind] whose pre-order index (within that kind's own index space) equals
    [target_index] with the value carried by [op].

    Each kind keeps its OWN counter, matching {!collect_sites} exactly, so the
    per-kind index a site was assigned during collection still names the same
    node here.  The boilerplate "rebuild every other node from its rewritten
    children" is delegated to {!Ast_visitor.map_children}, which preserves [loc]
    and visits children left-to-right — the SAME order {!collect_sites} uses.

    [EBinop] keeps its bespoke handling: on a match swap the operator WITHOUT
    descending into the operands, exactly as the original walk did, so nested
    binops are unaffected by a replacement at an ancestor binop. *)
let replace_at ~kind ~target_index ~op expr =
  let binop_ctr = ref 0 in
  let bool_ctr  = ref 0 in
  let int_ctr   = ref 0 in
  let hit ctr = let idx = !ctr in incr ctr; idx = target_index in
  let rec walk e =
    match e with
    | EBinop { op = old_op; left; right; loc } ->
      let matched = kind = KBinop && hit binop_ctr in
      if matched then
        (match op with
         | MOBinop new_op -> EBinop { op = new_op; left; right; loc }
         | _ -> EBinop { op = old_op; left; right; loc })
      else
        (* Force children left-to-right (map_children does this internally too,
           but we are inside the binop arm where the counter advances). *)
        let left'  = walk left in
        let right' = walk right in
        EBinop { op = old_op; left = left'; right = right'; loc }
    | ELit { lit = LInt _; loc } when kind = KInt ->
      if hit int_ctr then
        (match op with MOInt n -> ELit { lit = LInt n; loc } | _ -> e)
      else e
    | _ when kind = KBool && bool_literal_value e <> None ->
      (* Boolean-literal node (True/False constructor or legacy LBool). *)
      if hit bool_ctr then
        (match op with MOBool b -> set_bool_literal e b | _ -> e)
      else e
    | _ -> Ast_visitor.map_children walk e
  in
  walk expr

(** Produce a copy of [m] with the [DFunc] for [fn_name] having its body
    mutated at [(kind, site_index)] with [op].  All other declarations are
    unchanged, so test blocks remain intact. *)
let apply_mutation_to_module (m : module_form) fn_name ~kind ~site_index ~op : module_form =
  let decls' = List.map (function
    | DFunc fd when fd.name = fn_name ->
      let body' = replace_at ~kind ~target_index:site_index ~op fd.body in
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
    start, cache op, or email send.  [transaction] is treated as external
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
  | c when c = "cacheCap" || (String.length c >= 9 && String.sub c 0 9 = "cacheCap ") ->
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
  replacement : mutation_op;   (** the value substituted at [site] *)
  description : string;
  module_     : module_form;
}

(** Generate every mutant for [m].  Only [CheckKind], [AuthKind], and
    [EstablishKind] function bodies are targeted.  Every mutator family
    (binop swaps, boolean-literal flips, integer-literal perturbation) is
    driven from the single [(site, alternatives)] list produced by
    {!collect_sites}. *)
let generate_mutants (m : module_form) : mutant list =
  List.concat_map (function
    (* B2: the trusted proof-introducing kinds — single source of truth in Ast. *)
    | DFunc fd when is_proof_introducing_kind fd.kind ->
      let sites = collect_sites fd.name fd.kind fd.body in
      List.concat_map (fun (site, alts) ->
        List.map (fun op ->
          let module_ =
            apply_mutation_to_module m fd.name
              ~kind:site.kind ~site_index:site.site_index ~op
          in
          let description =
            Printf.sprintf "%s:%d:%d  %s  (in %s)"
              site.loc.file
              (site.loc.start.line + 1)
              (site.loc.start.col + 1)
              (mutation_display site.original op)
              site.fn_name
          in
          { site; replacement = op; description; module_ }
        ) alts
      ) sites
    | _ -> []
  ) m.decls

(* ── Result types ───────────────────────────────────────────────────────── *)

type mutant_result =
  | Killed    (** tests ran and FAILED — the mutant's behaviour change was
                  detected.  This is the only outcome that credits a kill. *)
  | Survived  (** tests ran and PASSED — the mutant went undetected (a real
                  test-coverage gap). *)
  | NoTests   (** no test block present for this function. *)
  | Invalid of string
              (** the mutant failed to COMPILE / expand (module load or
                  macro-expansion error) — the tests never ran, so it proves
                  nothing about the suite.  It is NOT a kill and is EXCLUDED
                  from the kill-rate denominator entirely: a mutant that does
                  not even compile cannot demonstrate that the tests
                  distinguish behaviour. *)
  | Error of string
              (** the mutant could not be evaluated for an infrastructural
                  reason (emit failure, or a [raco test] timeout — e.g. an
                  unavailable DB).  Like [Invalid], it is NOT credited as a
                  kill and is excluded from the kill-rate denominator. *)

type mutation_report = {
  total    : int;
  killed   : int;
  survived : int;
  invalid  : int;   (** count of [Invalid] mutants (compile/expand failures) *)
  errors   : int;   (** count of [Error] mutants (infra failures / timeouts) *)
  results  : (mutant * mutant_result) list;
}

(* ══════════════════════════════════════════════════════════════════════════
   S7 / C5 — SOUNDNESS-BREAKING AST-REWRITE TRANSFORMS
   ══════════════════════════════════════════════════════════════════════════

   The binop / bool / int mutators above target VALUES inside a boundary
   predicate's BODY (a [check]/[auth]/[establish] arithmetic or comparison
   node) and probe TEST coverage.  The transforms below are a DIFFERENT family:
   they target the STRUCTURE of a declaration — its proof carriers, fact
   subjects, capability rows and auth grants — and probe the CHECKER's own
   soundness gates.  Each is a total, deterministic AST rewrite over a
   [func_decl] (never a string edit), so a rewritten module can be handed
   straight to [Compile.check_module] and the SPECIFIC soundness diagnostic it
   trips can be asserted (an "attributed kill"), rather than an incidental parse
   error that would masquerade as a kill.

   One transform GRAMMAR per soundness layer:

   - [SDropParamProof]  — remove a `:::` proof carrier from a PARAMETER the return
                        relies on.  A proof-passthrough `fn p(t ::: P) -> t ::: P`
                        then declares a return proof its (now bare) input never
                        carried — the dual of forging: dropping the premise the
                        promised proof rested on.  Rejected by the forgery gate.
   - [SForgeProof]    — ADD a `:::` proof carrier to a plain `fn` RETURN whose
                        body cannot have received that proof on an input, forging
                        provenance the boundary never granted.
   - [SRetargetReturnSubject] — rebind the SUBJECT of a return-proof [PredApp]
                        to a fresh name not in scope, so the return proof no
                        longer refers to the returned value / a parameter.
   - [SRetargetParamSubject]  — rebind the SUBJECT of a PARAMETER-proof
                        [PredApp] to a fresh name not bound anywhere.
   - [SWidenCaps]     — ADD a capability to the declared `requires [...]` row
                        that the body does not need (over-declaration).
   - [SWeakenCaps]    — REMOVE a capability the body DOES need (under-declaration:
                        a privileged operation left uncovered).
   - [SWeakenAuthVia] — DROP the capability row from an [auth] function (weaken
                        the grant a `via`-style boundary rests on).

   Each transform is applied to every APPLICABLE site in a declaration; a site
   that does not exist (no return proof to drop, no param proof to retarget, …)
   simply yields no mutant, so the corpus is derived mechanically from what each
   seed actually contains. *)

(** A structural soundness-breaking transform (see the block comment above). *)
type soundness_transform =
  | SDropParamProof
  | SForgeProof
  | SRetargetReturnSubject
  | SRetargetParamSubject
  | SWidenCaps
  | SWeakenCaps
  | SWeakenAuthVia

let soundness_transform_name = function
  | SDropParamProof        -> "drop-param-proof"
  | SForgeProof            -> "forge-return-proof"
  | SRetargetReturnSubject -> "retarget-return-subject"
  | SRetargetParamSubject  -> "retarget-param-subject"
  | SWidenCaps             -> "widen-capabilities"
  | SWeakenCaps            -> "weaken-capabilities"
  | SWeakenAuthVia         -> "weaken-auth-via"

(* ── Proof-carrier accessors on a return spec ────────────────────────────── *)

(** The proof annotation borne by a return spec's leading binding, if any.
    Only the [RetAttached] / [RetMaybeAttached] shapes carry a droppable `:::`
    on a named binding; the [Ret*ForAll*]/[RetNamedPack] shapes carry their
    proof in a dedicated field and are left to the forge/retarget grammar. *)
let return_binding_proof (rs : return_spec) : proof_expr option =
  match rs with
  | RetAttached { binding; _ }        -> binding.proof_ann
  | RetMaybeAttached { binding; _ }   -> binding.proof_ann
  | _ -> None

(** [true] when [rs] declares a proof-bearing return (any shape). *)
let return_has_proof (rs : return_spec) : bool =
  match rs with
  | RetPlain _ -> false
  | RetAttached { binding; _ } | RetMaybeAttached { binding; _ } ->
    binding.proof_ann <> None
  | RetNamedPack { entity_proof; other_proof; _ } ->
    entity_proof <> None || other_proof <> None
  | RetForAll _ | RetMaybeForAll _ | RetSetForAll _ | RetMaybeSetForAll _
  | RetForAllDictValues _ | RetForAllDictKeys _ -> true
  | RetExists _ -> true

(** The type a plain return should carry when forging a proof onto it. *)
let return_plain_type (rs : return_spec) : type_expr option =
  match rs with
  | RetPlain { ty; _ } -> Some ty
  | _ -> None

(* ── Proof-subject retargeting ───────────────────────────────────────────── *)

(** A subject name that is guaranteed NOT to be in scope in any well-formed
    program, so retargeting a proof subject to it must be rejected by the
    subject-scope gate (never accidentally resolve to a real binding).  It is a
    LOWERCASE identifier (the proof-subject gate only inspects lowercase names)
    with a distinctive spelling that no realistic seed binds. *)
let ghost_subject = "zqmutateghostsubject"

(** Rewrite the SUBJECT position of a proof [PredApp].  A predicate's arguments
    are subject names; we replace the LAST (the conventional subject slot) with
    [ghost_subject].  Conjunctions retarget their leftmost leaf so exactly one
    subject is corrupted (a minimal, deterministic edit). *)
let rec retarget_proof_subject (p : proof_expr) : proof_expr =
  match p with
  | PredApp { pred; args; loc } ->
    let args' = match List.rev args with
      | _last :: rest_rev -> List.rev (ghost_subject :: rest_rev)
      | []                -> [ghost_subject]
    in
    PredApp { pred; args = args'; loc }
  | PredAnd { left; right; loc } ->
    PredAnd { left = retarget_proof_subject left; right; loc }

(* ── Per-declaration transform application ───────────────────────────────── *)

(** A synthetic provenance proof to forge onto a plain return.  [FromDb] is
    chosen because it is a framework-produced provenance predicate a plain body
    can only legitimately obtain from a real DB site — so declaring it on a
    return whose body has NO DB site is precisely the forgery the §7.12 gate
    rejects.  [subject] is the name the forged proof is asserted about. *)
let forged_proof ~subject : proof_expr =
  PredApp { pred = "FromDb"; args = [subject]; loc = Location.dummy_loc "mutate" }

(** Apply [t] to [fd], returning the rewritten declaration when the transform
    has a site to act on, else [None] (the seed does not exercise that layer).
    Every branch is a pure structural rewrite of the [func_decl]. *)
let apply_soundness_transform (t : soundness_transform) (fd : func_decl)
  : func_decl option =
  match t with
  | SDropParamProof ->
    (* Strip the `:::` off the FIRST parameter that carries one, so a return that
       relied on that input proof now forges it. *)
    let done_ = ref false in
    let params' = List.map (fun (b : binding) ->
      match b.proof_ann with
      | Some _ when not !done_ -> done_ := true; { b with proof_ann = None }
      | _ -> b
    ) fd.params in
    if !done_ then Some { fd with params = params' } else None

  | SForgeProof ->
    (* Only forgeable on a PLAIN return of a forgery-restricted kind (fn /
       handler / worker); the added proof is one the body never received. *)
    (match fd.kind, return_plain_type fd.return_spec with
     | (FnKind | HandlerKind | WorkerKind), Some ty ->
       let subject = "forged" in
       let binding = {
         name = subject; type_expr = ty;
         proof_ann = Some (forged_proof ~subject);
         loc = Location.dummy_loc "mutate";
       } in
       Some { fd with return_spec =
                        RetAttached { binding; loc = Location.dummy_loc "mutate" } }
     | _ -> None)

  | SRetargetReturnSubject ->
    (match return_binding_proof fd.return_spec with
     | Some p ->
       let p' = retarget_proof_subject p in
       let rs' = match fd.return_spec with
         | RetAttached { binding; loc } ->
           RetAttached { binding = { binding with proof_ann = Some p' }; loc }
         | RetMaybeAttached { outer_ty; binding; loc } ->
           RetMaybeAttached { outer_ty;
                              binding = { binding with proof_ann = Some p' }; loc }
         | other -> other
       in
       Some { fd with return_spec = rs' }
     | None -> None)

  | SRetargetParamSubject ->
    let done_ = ref false in
    let params' = List.map (fun (b : binding) ->
      match b.proof_ann with
      | Some p when not !done_ ->
        done_ := true;
        { b with proof_ann = Some (retarget_proof_subject p) }
      | _ -> b
    ) fd.params in
    if !done_ then Some { fd with params = params' } else None

  | SWidenCaps ->
    (* Add a privileged capability the body does not exercise (over-declaration).
       NOTE: Tesl's capability discipline is needs⊆declares — it rejects UNDER-
       declaration (a privileged op with no covering capability) but deliberately
       TOLERATES over-declaration (declaring more than you use is safe: you can
       only ever grant callees LESS authority than you hold).  So this transform
       is a genuine grammar member but is NOT an attributed kill on its own — it
       is the SAFE direction, kept here to document the asymmetry and to pair
       with [SWeakenCaps]/[SWeakenAuthVia], which ARE the load-bearing kills. *)
    Some { fd with capabilities =
                     fd.capabilities @ ["dbWrite"]
                     |> List.sort_uniq String.compare }

  | SWeakenCaps ->
    (* Drop ALL declared capabilities: any privileged body operation is now
       uncovered (the under-declaration that the needs⊆declares gate rejects). *)
    if fd.capabilities <> [] then Some { fd with capabilities = [] } else None

  | SWeakenAuthVia ->
    (* Weaken the grant an auth boundary rests on: strip its capability row. *)
    (match fd.kind with
     | AuthKind when fd.capabilities <> [] ->
       Some { fd with capabilities = [] }
     | _ -> None)

(** Apply [t] to the FIRST declaration named [fn_name] in [m], returning the
    rewritten module when the transform had a site, else [None]. *)
let apply_soundness_transform_to_module (m : module_form) ~fn_name
    (t : soundness_transform) : module_form option =
  let hit = ref None in
  let decls' = List.map (function
    | DFunc fd when fd.name = fn_name && !hit = None ->
      (match apply_soundness_transform t fd with
       | Some fd' -> hit := Some (); DFunc fd'
       | None -> DFunc fd)
    | d -> d
  ) m.decls in
  match !hit with
  | Some () -> Some { m with decls = decls' }
  | None -> None
