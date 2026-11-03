(** Why this source cannot be rewritten by formatting, or None for a mutable
    file. Reads the active source overlay, so unsaved completed roots and frozen
    sibling snapshots protect private migration helper buffers too. *)
val reason : file:string -> source:string -> string option
