(** Standalone entry point for the authoritative, bounded documentation generator.
    Usage: ocaml scripts/gen_embedded_docs.ml [repo-root] *)
#load "unix.cma";;
let () =
  let repo = if Array.length Sys.argv > 1 then Sys.argv.(1)
    else Filename.dirname (Filename.dirname Sys.argv.(0)) in
  let generator = Filename.concat
      (Filename.dirname (Filename.dirname Sys.argv.(0))) "compiler/gen/gen_docs.ml" in
  Unix.execv Sys.executable_name
    [|Sys.executable_name; "unix.cma"; generator; repo|]
