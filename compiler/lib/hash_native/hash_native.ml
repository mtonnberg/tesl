(* Installs the native SHA-256 (sha256_stubs.c) into Migration_hash. Linked
   only into native executables; the browser build keeps the OCaml rounds. *)
external sha256_hex : string -> bool -> string = "tesl_sha256_hex"
let portable source = sha256_hex source true
let install () = Migration_hash.install_native (fun source -> sha256_hex source false)
