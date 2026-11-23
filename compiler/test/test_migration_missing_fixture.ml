(* A transformation without a representative fixture reports exactly that, once.
   The row function is still checked under the migration's Same and proof
   context, so a Same-covered proof is not reported as unsatisfied (V001), and
   the entry does not repeat the same migration error once per checking pass. *)
open Alcotest

let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
  (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let read p = In_channel.with_open_bin p In_channel.input_all
let write p s = Out_channel.with_open_bin p (fun out -> output_string out s)

let with_example run =
  let root = Filename.temp_dir "tesl-missing-fixture-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let project = Filename.concat root "example" in
    let source = Filename.concat (Validation_common.stdlib_repo_root ()) "example/db-migration-example" in
    if Sys.command (Filename.quote_command "cp" ["-R"; source; project]) <> 0 then fail "copy example";
    run project)

let errors file =
  Compile.check_source file (read file)
  |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
  |> List.map (fun (d : Compile.diagnostic) -> d.code)

let only_the_missing_fixture () = with_example (fun project ->
  let migration = Filename.concat project "migrations/todo/v13.tesl" in
  let before = read migration in
  let edited = Str.global_replace (Str.regexp_string "fixtures: [previousImported, previousCreated]") "fixtures: []" before in
  check bool "fixture list removed" true (edited <> before);
  write migration edited;
  check (list string) "the migration reports only the missing fixture" ["MIG003"] (errors migration);
  check (list string) "the entry reports it once" ["MIG003"] (errors (Filename.concat project "todo-app.tesl")))

let () = run "missing migration fixture" ["diagnostics", [
  test_case "only the missing fixture, once" `Quick only_the_missing_fixture]]
