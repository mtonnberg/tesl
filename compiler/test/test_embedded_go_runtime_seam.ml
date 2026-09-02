(** Durable seam test: the Go runtime the compiler EMBEDS is the Go runtime in the tree.

    Every emitted module carries its own copy of `runtime/go/teslrt`, taken not from the
    file system at emission time but from {!Embedded_go_runtime.files} — an OCaml literal
    that `compiler/gen/gen_go_runtime.ml` generates and a `(mode promote)` dune rule writes
    back into the source tree.  That is what lets a generated project build with no
    `TESL_REPO_ROOT`.

    It also means there are TWO copies of the runtime, and CI phase 2a tests only one of
    them: the source tree.  The 2026-09-02 review found that four runtime files
    (`workers.go`, `debug_sql.go`, `debug_state.go`, `debug_value.go`) were read by the
    generator but were not listed as dependencies of the dune rule, so an edit to only
    those files did not regenerate the literal — a fix to the queue worker loop would have
    passed every runtime test and not shipped.  The dune deps are fixed; this test is what
    makes the class impossible to reintroduce, because it does not care WHY the two copies
    differ, only THAT they do:

    - every embedded file is byte-identical to `runtime/go/teslrt/<name>` on disk;
    - every non-test `.go` file under `runtime/go/teslrt` is embedded (a file the generator's
      list forgot would otherwise be a runtime the source tree has and users do not). *)

let ( // ) = Filename.concat

let failf fmt = Alcotest.failf fmt

let runtime_dir = "runtime" // "go" // "teslrt"

(* The repo root: TESL_REPO_ROOT when the harness sets it (ci.sh does), else walk up from
   the executable the way gen_go_runtime.ml does. *)
let repo_root () =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some root when Sys.file_exists (root // runtime_dir // "int.go") -> root
  | _ ->
    let rec up dir remaining =
      if Sys.file_exists (dir // runtime_dir // "int.go") then Some dir
      else if remaining = 0 then None
      else
        let parent = Filename.dirname dir in
        if parent = dir then None else up parent (remaining - 1)
    in
    let start = try Unix.realpath Sys.argv.(0) with _ -> Sys.argv.(0) in
    (match up (Filename.dirname start) 12 with
     | Some root -> root
     | None -> failf "cannot locate the repository root (set TESL_REPO_ROOT)")

let read_file path = In_channel.with_open_bin path In_channel.input_all

let on_disk root =
  Sys.readdir (root // runtime_dir)
  |> Array.to_list
  |> List.filter (fun name ->
       Filename.check_suffix name ".go"
       && not (Filename.check_suffix name "_test.go"))
  |> List.sort compare

let test_embedded_matches_disk () =
  let root = repo_root () in
  let stale = List.filter_map (fun (name, embedded) ->
    let path = root // runtime_dir // name in
    if not (Sys.file_exists path) then Some (name ^ " (embedded but not on disk)")
    else if read_file path <> embedded then Some (name ^ " (content differs)")
    else None) Embedded_go_runtime.files in
  if stale <> [] then
    failf "embedded_go_runtime.ml is out of date with runtime/go/teslrt — run `dune build` \
           (the promote rule regenerates it) and commit the result. Stale: %s"
      (String.concat ", " stale)

let test_every_runtime_file_is_embedded () =
  let root = repo_root () in
  let embedded = List.map fst Embedded_go_runtime.files in
  let missing = List.filter (fun name -> not (List.mem name embedded)) (on_disk root) in
  if missing <> [] then
    failf "runtime/go/teslrt has files the compiler does not embed — add them to the list in \
           compiler/gen/gen_go_runtime.ml AND to the (deps …) of the embedded_go_runtime.ml \
           rule in compiler/lib/dune: %s"
      (String.concat ", " missing)

let test_embedded_list_has_no_test_files () =
  let tests = List.filter (fun (name, _) -> Filename.check_suffix name "_test.go")
      Embedded_go_runtime.files in
  if tests <> [] then
    failf "test files must not be embedded into user modules: %s"
      (String.concat ", " (List.map fst tests))

let () =
  Alcotest.run "embedded-go-runtime-seam" [
    ("embedded runtime", [
        Alcotest.test_case "every embedded file is byte-identical to the tree" `Quick
          test_embedded_matches_disk;
        Alcotest.test_case "every runtime file is embedded" `Quick
          test_every_runtime_file_is_embedded;
        Alcotest.test_case "no test file is embedded" `Quick
          test_embedded_list_has_no_test_files;
      ]);
  ]
