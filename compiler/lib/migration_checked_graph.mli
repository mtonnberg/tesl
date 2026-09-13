(** A complete captured source graph admitted by the ordinary compiler.
    Construction checks every module with the public frontend, then obtains
    inferred expression types from those same original AST objects. No caller
    can manufacture a graph from unchecked typed nodes or a parsed signature. *)
type t

(** Capture pairs must contain every non-stdlib import at its resolved canonical
    path. Source bytes are pinned for all checking passes. An explicit proof token
    must match this complete captured graph; omitting it suspends ambient grants.
    Its mutable source/import guards are revalidated before and after checking and
    lowering. Context-free callers remain responsible for publication guards. *)
val check : ?context:Migration_proof_context.t -> (Ast.module_form * string) list -> (t, Migration_ir.error) result
val modules : t -> Ast.module_form list
(** Canonical path and captured source bytes, not source digests. *)
val source_texts : t -> (string * string) list
val resolve : t -> owner:string -> Migration_ir.resolver

(** Lower the original checked AST afresh under explicit schema roles. Never
    relabel an already-lowered Snapshot body as From/To. Every declaration is
    lowered; unsupported declarations, including constants, fail explicitly. *)
val lower : scopes:Migration_canonical.scope list -> t ->
  (Migration_ir.definition list, Migration_ir.error) result

(** The transform linker may omit its exact checked contextual declaration and
    ordinary tests after the complete graph passed frontend validation. All other
    unsupported declarations still fail. Original owner/declaration identity is
    required; structurally identical replacement nodes do not qualify. *)
val lower_transform : scopes:Migration_canonical.scope list ->
  contextual:Ast.module_form * Ast.const_form -> t ->
  (Migration_ir.definition list, Migration_ir.error) result
