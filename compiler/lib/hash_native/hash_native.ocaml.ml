(* Toolchains without a C compiler (the native Windows distribution build)
   keep Migration_hash's OCaml rounds; the digests are identical. *)
let available = false
let sha256_hex source (_ : bool) = Migration_hash.compute_native source
let portable source = sha256_hex source true
let install () = ()
