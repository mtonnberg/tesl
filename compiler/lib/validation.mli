(** Validation orchestrator — public interface.

    The only public entry point is [check_module]; the implementation details
    of each validation pass live in the validation_* sub-modules. *)

(** The type of a validation diagnostic.  Re-exported from Validation_common
    so that Compile can reference it as [Validation.validation_error]. *)
type validation_error = Validation_common.validation_error

(** Run all validation passes on a parsed module.  Returns an empty list when
    the module is structurally and semantically valid. *)
val check_module : Ast.module_form -> validation_error list
