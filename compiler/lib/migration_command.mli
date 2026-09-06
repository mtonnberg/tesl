(** Compiler-owned command transport. Generation remains a non-mutating source
    preview; its diagnostics describe the complete proposed application. *)
type response = { stdout : string; stderr : string; exit_code : int }
val run : string list -> response
