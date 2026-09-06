(** A complete captured source graph admitted by the ordinary compiler.
    Construction checks every module with the public frontend, then obtains
    inferred expression types from those same original AST objects. No caller
    can manufacture a graph from unchecked typed nodes or a parsed signature. *)
type t

(** Capture pairs must contain every non-stdlib import at its resolved canonical
    path. Source bytes are pinned for all checking passes; the active project and
    explicitly installed migration proof context are preserved. Callers remain
    responsible for rechecking mutable source inputs before publication. *)
val check : (Ast.module_form * string) list -> (t, Migration_ir.error) result
val modules : t -> Ast.module_form list
(** Canonical path and captured source bytes, not source digests. *)
val source_texts : t -> (string * string) list
val resolve : t -> owner:string -> Migration_ir.resolver

(** Lower the original checked AST afresh under explicit schema roles. Never
    relabel an already-lowered Snapshot body as From/To. Every declaration is
    lowered; unsupported declarations, including constants, fail explicitly. *)
val lower : scopes:Migration_canonical.scope list -> t ->
  (Migration_ir.definition list, Migration_ir.error) result
