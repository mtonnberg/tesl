(** Local refresh ownership, not authenticated history or permission to run a
    database transition. A matching marker permits mechanical source refresh;
    a changed body or an added internal comment remains user-owned. *)
type ownership = Generated | User_owned | Unmarked
val ownership : Migration_source_syntax.t -> previous:string -> current:string ->
  id:string -> Ast.expr -> ownership
(** A generated direct collection member, through its trailing marker, including
    the original record key and optional comma. Comments between key and value
    also protect the member. Preceding/following comments and indentation remain
    outside this span. *)
val editable_member : Migration_source_syntax.t -> collection:Ast.expr ->
  previous:string -> current:string -> id:string -> Ast.expr ->
  Migration_source_syntax.range option
(** Annotate freshly generated expressions on otherwise empty line tails (an
    optional comma is retained). Existing matching annotations are idempotent;
    comments, code, malformed annotations and edited bodies are never overwritten.
    Unsupported expressions refuse. Returns source bytes; no files are written. *)
val annotate : Migration_source_syntax.t -> previous:string -> current:string ->
  (string * Ast.expr) list -> (string,Migration_source_syntax.error) result
