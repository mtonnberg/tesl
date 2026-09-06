(** Pure source reconciliation. This has no schema judgment, filesystem writes or
    execution authority. The caller supplies identities from its checked context. *)
type desired = { id : string; key : string option; body : string }
type result = { source : string; protected : string list }
(** [existing] must identify every direct collection member exactly once.
    Untouched generated members can be replaced/removed. All other existing
    members stay byte-identical and are returned in [protected]. Missing desired
    members are appended with ownership markers. Equal syntax retains its exact
    original spelling/layout. Record keys cannot change under the same identity.
    Duplicates, stale ASTs, invalid fragments and ambiguous identities refuse.
    Containers may include arbitrary user expressions, which remain protected. *)
val reconcile : Migration_source_syntax.t -> collection:Ast.expr ->
  previous:string -> current:string -> existing:(string * Ast.expr) list ->
  desired:desired list -> (result,Migration_source_syntax.error) Stdlib.result
