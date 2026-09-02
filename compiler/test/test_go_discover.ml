(** Go test-set discovery sanity.

    The Go backend is the only runtime backend. Keep the source corpus and the
    Go gate visible to the compiler test registration surface.
*)

let () =
  let root =
    match Sys.getenv_opt "TESL_REPO_ROOT" with
    | Some root -> root
    | None -> Filename.concat (Filename.dirname Sys.argv.(0)) "../.."
  in
  let tests_dir = Filename.concat root "tests" in
  let entries = Sys.readdir tests_dir |> Array.to_list in
  let tesl_files = List.filter (Filename.check_suffix ".tesl") entries in
  ignore tesl_files;
  if not (Sys.file_exists (Filename.concat root "tests/go-cli-smoke.sh")) then
    failwith "Go CLI smoke gate is missing";
  print_endline "Go test-set discovery: PASS"
