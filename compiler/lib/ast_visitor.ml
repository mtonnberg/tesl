(** Shared structural AST traversal framework for {!Ast.expr}.

    This module provides the single, canonical "recurse into every immediate
    sub-expression" operation for {!Ast.expr}, so that the many mechanical
    hand-rolled walks scattered across the compiler (mutation-site collection,
    the linter's name collector, the legacy-bool diagnostic walk, the proof-name
    collector) share ONE definition of "the children of an expression". A single
    point of truth means a new {!Ast.expr} variant cannot silently be
    under-traversed by a forgotten match arm in five different files.

    {2 The three primitives}

    - [map_children f e] applies [f] to each {e immediate} sub-expression of [e]
      and rebuilds [e] with the results. It is NON-recursive by itself: [f] is
      called once per direct child and decides whether to recurse. The [loc] of
      [e] (and of every nested record that carries one) is PRESERVED verbatim.

    - [fold_children f acc e] threads [acc] left-to-right through each immediate
      sub-expression of [e].

    - [iter_children f e] applies [f] to each immediate sub-expression of [e],
      left-to-right, for effect.

    On top of those, [map] / [fold] / [iter] are the recursive (fix-pointed)
    closures: [map f e = f (map_children (map f) e)] etc., i.e. they apply the
    user function at every node of the whole tree.

    {2 Child-visit ORDER — load-bearing}

    Children are ALWAYS visited left-to-right in source/textual order. This is a
    hard guarantee, not an accident: {!Mutate} assigns a stable pre-order index
    to every [EBinop] via a shared mutable counter, and the deterministic site
    indices it produces (and later replays in [replace_binop_at]) only line up
    if both walks visit children in exactly the same order.

    OCaml evaluates the field initializers of a record literal RIGHT-TO-LEFT, so
    [map_children] never builds children inline inside a record literal. Every
    child is forced into a [let] binding first, in left-to-right order, and only
    then is the record assembled from the already-evaluated bindings. Reordering
    those [let] bindings would be a silent correctness bug.

    {2 Coverage decision (documented on purpose)}

    "Children" means every value of type {!Ast.expr} reachable WITHOUT crossing
    into a different top-level declaration. Concretely the following nested
    expression carriers are traversed:

    - [case_arm]:        both [guard] (an [expr option]) and [body] are children
                         of [ECase]. Visit order: scrutinee, then for each arm in
                         order its guard (if present) then its body.
    - [pattern]:         a {!Ast.pattern} (incl. [PCon] labelled sub-patterns and
                         [PLit] literals) contains NO {!Ast.expr} — only binders,
                         constructor names and {!Ast.lit}s. There is therefore no
                         child expression to visit inside a pattern, so patterns
                         are intentionally left untouched by [map_children] (they
                         are carried through verbatim). This is total coverage,
                         not under-coverage: the silent-bug class only exists for
                         sub-[expr]s, and patterns have none.
    - [return_spec]:     part of a [func_decl], NOT reachable from an [expr]. It
                         carries types/proofs, never an [expr]. Out of scope for
                         the expr visitor by construction.
    - [interp_segment]:  [IExpr e] inside an [ELit{lit=LInterp segs}] IS a child
                         expression and IS traversed (in segment order); the
                         [ILiteral] segments carry no expr and are preserved.
    - [ELambda.params] / function-like bindings: a {!Ast.binding} carries a
                         [type_expr] and a [proof_expr] option, never an [expr],
                         so it has no child expression and is preserved verbatim.

    The leaf variants that genuinely have no sub-[expr] ([ELit] except the
    [LInterp] case, [EVar], [EStartWorkers], [EStartEmailWorker]) are returned
    unchanged.

    {2 What this is NOT for}

    Semantic passes that must stay explicit and exhaustive — the type checker's
    [infer_expr] and the emitter's [emit_expr] — must NOT be built on this. They
    need per-variant behaviour and the compiler's exhaustiveness check is the
    point. This framework is only for the mechanical "recurse into children"
    walks where every non-leaf arm is identical boilerplate. *)

open Ast

(* ── interp_segment helpers (the LInterp child exprs) ───────────────────────
   A literal's interpolation segments may embed expressions ([IExpr]); those
   are children. We thread/transform them in left-to-right segment order. *)

let map_interp_segment (f : expr -> expr) (seg : interp_segment) : interp_segment =
  match seg with
  | ILiteral _ -> seg
  | IExpr e -> IExpr (f e)

let fold_interp_segment (f : 'a -> expr -> 'a) (acc : 'a) (seg : interp_segment) : 'a =
  match seg with
  | ILiteral _ -> acc
  | IExpr e -> f acc e

(* ── map_children ───────────────────────────────────────────────────────────
   Apply [f] to each IMMEDIATE child expr and rebuild, preserving every [loc].
   Every child is forced left-to-right into a [let] BEFORE the record literal is
   assembled, because OCaml evaluates record fields right-to-left. *)

let map_children (f : expr -> expr) (e : expr) : expr =
  match e with
  (* Leaves with no child expr — returned verbatim. *)
  | EVar _ | EStartWorkers _ | EStartEmailWorker _ -> e
  | ELit { lit = LInterp segs; loc } ->
    let segs' = List.map (map_interp_segment f) segs in
    ELit { lit = LInterp segs'; loc }
  | ELit _ -> e
  | EField { obj; field; loc } ->
    let obj' = f obj in
    EField { obj = obj'; field; loc }
  | EApp { fn; arg; loc } ->
    let fn' = f fn in
    let arg' = f arg in
    EApp { fn = fn'; arg = arg'; loc }
  | EBinop { op; left; right; loc } ->
    let left' = f left in
    let right' = f right in
    EBinop { op; left = left'; right = right'; loc }
  | EUnop { op; arg; loc } ->
    let arg' = f arg in
    EUnop { op; arg = arg'; loc }
  | EIf { cond; then_; else_; loc } ->
    let cond' = f cond in
    let then_' = f then_ in
    let else_' = f else_ in
    EIf { cond = cond'; then_ = then_'; else_ = else_'; loc }
  | ECase { scrut; arms; loc } ->
    let scrut' = f scrut in
    let arms' =
      List.map (fun (arm : case_arm) ->
        let guard' = Option.map f arm.guard in
        let body' = f arm.body in
        { arm with guard = guard'; body = body' }
      ) arms
    in
    ECase { scrut = scrut'; arms = arms'; loc }
  | ELet { name; declared_type; declared_proof; value; body; loc } ->
    let value' = f value in
    let body' = f body in
    ELet { name; declared_type; declared_proof; value = value'; body = body'; loc }
  | ELetProof { value_name; proof_name; proof_index; value; body; loc } ->
    let value' = f value in
    let body' = f body in
    ELetProof { value_name; proof_name; proof_index; value = value'; body = body'; loc }
  | ERecord { fields; type_hint; loc } ->
    let fields' = List.map (fun (k, v) -> let v' = f v in (k, v')) fields in
    ERecord { fields = fields'; type_hint; loc }
  | EList { elems; loc } ->
    let elems' = List.map f elems in
    EList { elems = elems'; loc }
  | EOk { value; proof; loc } ->
    let value' = f value in
    EOk { value = value'; proof; loc }
  | EFail { status; message; loc } ->
    let message' = f message in
    EFail { status; message = message'; loc }
  | ETelemetry { name; fields; loc } ->
    let fields' = List.map (fun (k, v) -> let v' = f v in (k, v')) fields in
    ETelemetry { name; fields = fields'; loc }
  | EEnqueue { job_type; payload; loc } ->
    let payload' = f payload in
    EEnqueue { job_type; payload = payload'; loc }
  | EPublish { channel_name; key; event_ctor; payload; loc } ->
    let key' = Option.map f key in
    let payload' = Option.map f payload in
    EPublish { channel_name; key = key'; event_ctor; payload = payload'; loc }
  | ECacheGet { cache_name; key; loc } ->
    let key' = f key in
    ECacheGet { cache_name; key = key'; loc }
  | ECacheSet { cache_name; key; value; ttl; loc } ->
    let key' = f key in
    let value' = f value in
    let ttl' = Option.map f ttl in
    ECacheSet { cache_name; key = key'; value = value'; ttl = ttl'; loc }
  | ECacheDelete { cache_name; key; loc } ->
    let key' = f key in
    ECacheDelete { cache_name; key = key'; loc }
  | ECacheInvalidate { cache_name; prefix; loc } ->
    let prefix' = f prefix in
    ECacheInvalidate { cache_name; prefix = prefix'; loc }
  | ESendEmail { email_name; to_; subject; body; loc } ->
    let to_' = f to_ in
    let subject' = f subject in
    let body' = f body in
    ESendEmail { email_name; to_ = to_'; subject = subject'; body = body'; loc }
  | EWithDatabase { database_name; body; loc } ->
    let body' = f body in
    EWithDatabase { database_name; body = body'; loc }
  | EWithCapabilities { capabilities; body; loc } ->
    let body' = f body in
    EWithCapabilities { capabilities; body = body'; loc }
  | EWithTransaction { body; loc } ->
    let body' = f body in
    EWithTransaction { body = body'; loc }
  | EServe { server_name; port; capabilities; static_dir; loc } ->
    let port' = f port in
    EServe { server_name; port = port'; capabilities; static_dir; loc }
  | EConstructor { name; args; loc } ->
    let args' = List.map f args in
    EConstructor { name; args = args'; loc }
  | ELambda { params; body; loc } ->
    let body' = f body in
    ELambda { params; body = body'; loc }
  | ERuntimeCall { segments; loc } ->
    let segments' = List.map (function
      | RLit _ as s -> s
      | RArg e -> RArg (f e)) segments in
    ERuntimeCall { segments = segments'; loc }

(* ── fold_children ──────────────────────────────────────────────────────────
   Thread [acc] left-to-right through each immediate child expr.  Defined in the
   SAME child order as [map_children]. *)

let fold_children (f : 'a -> expr -> 'a) (acc : 'a) (e : expr) : 'a =
  match e with
  | EVar _ | EStartWorkers _ | EStartEmailWorker _ -> acc
  | ELit { lit = LInterp segs; _ } ->
    List.fold_left (fold_interp_segment f) acc segs
  | ELit _ -> acc
  | EField { obj; _ } -> f acc obj
  | EApp { fn; arg; _ } -> f (f acc fn) arg
  | EBinop { left; right; _ } -> f (f acc left) right
  | EUnop { arg; _ } -> f acc arg
  | EIf { cond; then_; else_; _ } -> f (f (f acc cond) then_) else_
  | ECase { scrut; arms; _ } ->
    let acc = f acc scrut in
    List.fold_left (fun acc (arm : case_arm) ->
      let acc = match arm.guard with Some g -> f acc g | None -> acc in
      f acc arm.body
    ) acc arms
  | ELet { value; body; _ } -> f (f acc value) body
  | ELetProof { value; body; _ } -> f (f acc value) body
  | ERecord { fields; _ } -> List.fold_left (fun acc (_, v) -> f acc v) acc fields
  | EList { elems; _ } -> List.fold_left f acc elems
  | EOk { value; _ } -> f acc value
  | EFail { message; _ } -> f acc message
  | ETelemetry { fields; _ } -> List.fold_left (fun acc (_, v) -> f acc v) acc fields
  | EEnqueue { payload; _ } -> f acc payload
  | EPublish { key; payload; _ } ->
    let acc = match key with Some k -> f acc k | None -> acc in
    (match payload with Some p -> f acc p | None -> acc)
  | ECacheGet { key; _ } -> f acc key
  | ECacheSet { key; value; ttl; _ } ->
    let acc = f (f acc key) value in
    (match ttl with Some t -> f acc t | None -> acc)
  | ECacheDelete { key; _ } -> f acc key
  | ECacheInvalidate { prefix; _ } -> f acc prefix
  | ESendEmail { to_; subject; body; _ } -> f (f (f acc to_) subject) body
  | EWithDatabase { body; _ } -> f acc body
  | EWithCapabilities { body; _ } -> f acc body
  | EWithTransaction { body; _ } -> f acc body
  | EServe { port; _ } -> f acc port
  | EConstructor { args; _ } -> List.fold_left f acc args
  | ELambda { body; _ } -> f acc body
  | ERuntimeCall { segments; _ } ->
    List.fold_left (fun acc -> function
      | RLit _ -> acc
      | RArg e -> f acc e) acc segments

(* ── fold_children_env ───────────────────────────────────────────────────────
   Like [fold_children], but ALSO threads an explicit read-only [env] DOWN to
   each immediate child.  [f] receives [env], the running [acc], and the child;
   it returns the updated [acc].  The SAME [env] is handed to every immediate
   child of [e] (env is contextual scope flowing top-down — e.g. a proof/subject
   environment — and [f] decides whether/how to extend it before recursing into
   grandchildren).

   The result accumulator [acc] is threaded LEFT-TO-RIGHT through the children in
   exactly the same child order as [fold_children]/[map_children]; in fact this
   is literally [fold_children] with [env] partially applied into [f], so the two
   can never disagree about child identity or order.  That left-to-right order is
   the same load-bearing guarantee documented at the top of this module (the
   {!Mutate} pre-order index depends on it). *)

let fold_children_env
    (f : 'env -> 'acc -> expr -> 'acc)
    (env : 'env) (acc : 'acc) (e : expr) : 'acc =
  fold_children (fun acc child -> f env acc child) acc e

(* ── iter_children ──────────────────────────────────────────────────────────
   Visit each immediate child expr left-to-right for effect.  Expressed via
   [fold_children] so the child order can never drift between the two. *)

let iter_children (f : expr -> unit) (e : expr) : unit =
  fold_children (fun () child -> f child) () e

(* ── Recursive (fix-pointed) closures ───────────────────────────────────────
   [map]/[fold]/[iter] apply the user function at EVERY node of the whole tree.
   They are pre-order for [fold]/[iter] (node visited, then its children) and
   bottom-up for [map] (children rebuilt first, then the node passed to [f]).

   NOTE on [map] order: children are rebuilt before [f] sees the node, but the
   per-child rebuild itself still happens left-to-right (guaranteed by
   [map_children]).  A bottom-up [map] keeps it a true structural fixpoint while
   leaving the pre-order *visit* order to [fold]/[iter], which is what the
   index-sensitive [Mutate] walks use. *)

let rec map (f : expr -> expr) (e : expr) : expr =
  f (map_children (map f) e)

let rec fold (f : 'a -> expr -> 'a) (acc : 'a) (e : expr) : 'a =
  let acc = f acc e in
  fold_children (fold f) acc e

let rec iter (f : expr -> unit) (e : expr) : unit =
  f e;
  iter_children (iter f) e
