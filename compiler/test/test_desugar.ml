(** Backend-neutral desugaring contract.

    Effect forms remain in the AST until the selected backend handles them. The
    shared pass must therefore preserve expression identity and locations.
*)

open Ast

let loc = Validation_common.gen_loc

let test_empty_tables_are_backend_neutral () =
  let expr = ELit { lit = LInt 1; loc } in
  if Desugar.desugar_expr (Desugar.empty_tables ()) expr <> expr then
    failwith "desugar changed a backend-neutral expression"

let () =
  test_empty_tables_are_backend_neutral ();
  print_endline "desugar: PASS"
