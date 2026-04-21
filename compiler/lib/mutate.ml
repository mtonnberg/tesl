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
    remain stable when a specific node is later substituted. *)
let collect_sites fn_name fn_kind body =
  let counter = ref 0 in
  let acc     = ref [] in
  let rec walk = function
    | EBinop { op; left; right; loc } ->
      let idx = !counter in
      incr counter;
      (match mutation_alternatives op with
       | [] -> ()
       | _  -> acc := { fn_name; fn_kind; site_index = idx;
                        original_op = op; loc } :: !acc);
      walk left; walk right
    | EApp    { fn; arg; _ }              -> walk fn; walk arg
    | EUnop   { arg; _ }                  -> walk arg
    | EIf     { cond; then_; else_; _ }  -> walk cond; walk then_; walk else_
    | ECase   { scrut; arms; _ }          ->
      walk scrut;
      List.iter (fun arm ->
        Option.iter walk arm.guard;
        walk arm.body
      ) arms
    | ELet      { value; body; _ }        -> walk value; walk body
    | ELetProof { value; body; _ }        -> walk value; walk body
    | ERecord   { fields; _ }             -> List.iter (fun (_, e) -> walk e) fields
    | EList     { elems; _ }              -> List.iter walk elems
    | EOk       { value; _ }              -> walk value
    | EFail     { message; _ }            -> walk message
    | ETelemetry { fields; _ }            -> List.iter (fun (_, e) -> walk e) fields
    | EEnqueue  { payload; _ }            -> walk payload
    | EPublish  { key; payload; _ }       ->
      Option.iter walk key;
      Option.iter walk payload
    | EWithDatabase    { body; _ }        -> walk body
    | EWithCapabilities { body; _ }       -> walk body
    | EWithTransaction  { body; _ }       -> walk body
    | EField    { obj; _ }                -> walk obj
    | EConstructor { args; _ }            -> List.iter walk args
    | ELambda   { body; _ }               -> walk body
    | EServe    { port; _ }               -> walk port
    | ELit _ | EVar _
    | EStartWorkers _ -> ()
  in
  walk body;
  List.rev !acc

(* ── AST binop replacement ──────────────────────────────────────────────── *)

(** Perform a single-site replacement: walk [expr], replacing the binop
    whose pre-order index equals [target_index] with [new_op].
    [counter] must start at 0 and is shared for the whole walk. *)
let replace_binop_at ~target_index ~new_op expr =
  let counter = ref 0 in
  let rec walk = function
    | EBinop { op; left; right; loc } ->
      let idx = !counter in
      incr counter;
      if idx = target_index
      then EBinop { op = new_op; left; right; loc }
      else
        (* Use let bindings to guarantee left-before-right evaluation order,
           matching the sequential [walk left; walk right] in collect_sites.
           OCaml record field initializers are evaluated right-to-left, which
           would cause index mismatches if we used them directly. *)
        let left' = walk left in
        let right' = walk right in
        EBinop { op; left = left'; right = right'; loc }
    | EApp    { fn; arg; loc } ->
      let fn' = walk fn in
      let arg' = walk arg in
      EApp { fn = fn'; arg = arg'; loc }
    | EUnop   { op; arg; loc }             -> EUnop { op; arg = walk arg; loc }
    | EIf     { cond; then_; else_; loc } ->
      let cond'  = walk cond  in
      let then_' = walk then_ in
      let else_' = walk else_ in
      EIf { cond = cond'; then_ = then_'; else_ = else_'; loc }
    | ECase   { scrut; arms; loc }         ->
      let scrut' = walk scrut in
      let arms'  = List.map (fun arm ->
        let guard' = Option.map walk arm.guard in
        let body'  = walk arm.body in
        { arm with guard = guard'; body = body' }
      ) arms in
      ECase { scrut = scrut'; arms = arms'; loc }
    | ELet { name; declared_type; declared_proof; value; body; loc } ->
      let value' = walk value in
      let body'  = walk body  in
      ELet { name; declared_type; declared_proof; value = value'; body = body'; loc }
    | ELetProof { value_name; proof_name; proof_index; value; body; loc } ->
      let value' = walk value in
      let body'  = walk body  in
      ELetProof { value_name; proof_name; proof_index; value = value'; body = body'; loc }
    | ERecord { fields; type_hint; loc } ->
      ERecord { fields = List.map (fun (k, v) -> (k, walk v)) fields; type_hint; loc }
    | EList { elems; loc } ->
      EList { elems = List.map walk elems; loc }
    | EOk   { value; proof; loc }           -> EOk { value = walk value; proof; loc }
    | EFail { status; message; loc }        -> EFail { status; message = walk message; loc }
    | ETelemetry { name; fields; loc } ->
      ETelemetry { name; fields = List.map (fun (k, v) -> (k, walk v)) fields; loc }
    | EEnqueue { job_type; payload; loc }   -> EEnqueue { job_type; payload = walk payload; loc }
    | EPublish { channel_name; key; event_ctor; payload; loc } ->
      let key'     = Option.map walk key     in
      let payload' = Option.map walk payload in
      EPublish { channel_name; key = key'; event_ctor; payload = payload'; loc }
    | EWithDatabase    { database_name; body; loc } ->
      EWithDatabase { database_name; body = walk body; loc }
    | EWithCapabilities { capabilities; body; loc } ->
      EWithCapabilities { capabilities; body = walk body; loc }
    | EWithTransaction  { body; loc } ->
      EWithTransaction { body = walk body; loc }
    | EField { obj; field; loc }            -> EField { obj = walk obj; field; loc }
    | EConstructor { name; args; loc }      -> EConstructor { name; args = List.map walk args; loc }
    | ELambda { params; body; loc }         -> ELambda { params; body = walk body; loc }
    | EServe  { server_name; port; capabilities; static_dir; loc } ->
      EServe { server_name; port = walk port; capabilities; static_dir; loc }
    | (ELit _ | EVar _ | EStartWorkers _) as e -> e
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
