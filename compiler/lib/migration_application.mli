(** Check a database's declared migration history as an implicit dependency of
    the complete application. No migration names or runtime imports are added.
    The returned callback is scoped to a single frontend judgment; it shares
    dependency de-duplication and honors the frontend's batch skip predicate.
    This checks current source, not database state or execution ABI authority. *)
val make : ?skip_dep_body:(string -> bool) -> Ast.module_form ->
  string -> Ast.module_form -> Frontend_check.diagnostic list
