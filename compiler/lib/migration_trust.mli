(** Trust seals for completed migration history: a completed step whose
    recorded schema seals and frozen-source closure still hash to the saved
    bytes, and whose seals were recorded by this exact compiler ABI, is not
    re-checked. See the implementation header for the complete rule. *)

(** True when TESL_FULL_HISTORY is set (1/true/yes/on) or [request_full_history]
    ran: every frozen step then receives the complete check. *)
val full_history : unit -> bool
val request_full_history : unit -> unit
(** [f] with trust disabled in this process only; restored afterwards. *)
val with_full_history : (unit -> 'a) -> 'a

(** Evidence that one completed step's trust seal verified. *)
type evidence
val root : evidence -> string

(** Build evidence from a header and closure the caller already verified
    against the saved bytes and the module's adjacent roots. [compiler_abi] is
    the caller's actual compiler ABI; a comparison label never matches a seal. *)
val of_verified : compiler_abi:string -> stored_value_compatibility:string option -> root:string ->
  header:Migration_header.checked option -> closure:Migration_closure.located option -> evidence option

(** The running compiler's ABI identity and stored-value contract. *)
val current_compiler : unit -> (string * string) option

(** Verify one saved completed migration file reached as history and decide
    trust. Any integrity failure yields [None]; callers then run the full check,
    which reports the precise diagnostic. *)
val edge : project_root:string -> compiler:(string * string) option -> file:string -> source:string -> evidence option

(** [edge] for a captured module: a completed migration root, or the Contract
    companion of one. *)
val module_edge : compiler:(string * string) option -> Ast.module_form -> string -> evidence option

(** Roots trusted in this process, in decision order (tests). *)
val trusted_roots : unit -> string list
val reset_trusted_roots : unit -> unit
