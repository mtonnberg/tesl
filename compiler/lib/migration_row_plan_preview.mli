(** A source-only storage and transformation description. This neither observes
    persisted PostgreSQL state nor grants execution or decoder-pruning authority. *)
val describe : quote:(string -> string) -> contracts:Migration_contract.t list ->
  Migration_row_history.t -> (string, Migration_sparse.error list) result
