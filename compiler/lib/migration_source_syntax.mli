(** Exact source ranges for contextual migration data. Diagnostic AST locations
    may include the next token, so they are not replacement ranges. A view binds
    parsed AST identities, tokens and immutable source bytes together. *)
type t
type range = { start_byte : int; end_byte : int }
type error = { message : string }
val read : file:string -> source:string -> (t,error) result
val module_ : t -> Ast.module_form
val source : t -> string
(** Only expressions physically belonging to this view may be addressed. Initial
    support covers literal migration data (references, applications, records,
    lists, primitive literals and unary operators). Other expressions refuse. *)
val range : t -> Ast.expr -> (range,error) result
(** Literal collection boundaries do not require supported fingerprints for their
    children. This permits editing generated siblings beside arbitrary user code.
    Duplicate record keys and stale or reconstructed AST nodes refuse. *)
val members : t -> Ast.expr -> ((string option * Ast.expr) list,error) result
val collection_range : t -> Ast.expr -> (range,error) result
(** Exact direct-member range, including a record's original key spelling and
    colon, excluding separators and trailing comments. The value must support
    [range]; a nested descendant is not a direct member. *)
val member_range : t -> collection:Ast.expr -> Ast.expr -> (range,error) result
val text : t -> range -> string
(** Location-independent syntax identity. Role roots are normalized for freezing
    VCurrent to V<n>; this does not establish semantic equality or proof evidence.
    Unsupported expressions return None and must remain user-owned. *)
val fingerprint : previous:string -> current:string -> Ast.expr -> string option
(** Apply sorted, non-overlapping byte edits to this view's immutable source.
    The result must parse; full type/proof/migration checks belong to the caller.
    No files are written. *)
val replace : t -> (range * string) list -> (string,error) result
