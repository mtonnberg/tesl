(* The native SHA-256 in sha256_stubs.c. Built only where a C compiler is part
   of the OCaml toolchain; Hash_native selects it when this library exists. *)
external sha256_hex : string -> bool -> string = "tesl_sha256_hex"
