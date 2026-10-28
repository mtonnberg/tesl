(** Read-only observations of codec changes at stored field occurrences.
    These are not Same evidence, directional compatibility proofs, execution
    permissions, or permission to remove a decoder. *)
type decoder_order = Unchanged | Append_only | Removed | Reordered_or_replaced
type codec_change = {
  previous_codec : string option;
  current_codec : string option;
  encoder_syntax_changed : bool;
  decoder_alternatives_changed : bool;
  decoder_order_change : decoder_order;
  dependency_closure_changed : bool;
}
type report = { entity : string; field : string; codecs : codec_change list }
val inspect : before:Migration_inventory.t -> after:Migration_inventory.t ->
  (report list, Migration_ir.error) result
val json : quote:(string -> string) -> report list -> string
