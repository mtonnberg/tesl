(** Invocation-local evidence supplied only after a declared literal validator
    has been checked and evaluated. No process-global evidence escapes a scope. *)
type site = { value : Ast.expr; binder : string; proof : Ast.proof_expr }
val with_sites : site list -> (unit -> 'a) -> 'a
val proofs : string -> Ast.expr -> Proof_kernel.proven_fact list
