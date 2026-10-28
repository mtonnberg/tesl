(** Checked public QueueRepair source; no installed repair authority. *)
val check : source:string -> Ast.module_form -> (Migration_queue_transform.t option, Migration_sparse.error list) result
val diagnostics : string -> Ast.module_form -> Frontend_check.diagnostic list
