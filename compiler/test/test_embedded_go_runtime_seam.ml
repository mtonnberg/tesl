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
      list forgot would otherwise be a runtime the source tree has and users do not);
    - every embedded file is an explicit rule dependency, so changing only that file
      invalidates the snapshot without waiting for an unrelated generator change. *)

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
           rule in compiler/lib/go_runtime/embedded/dune: %s"
      (String.concat ", " missing)

let test_embedded_list_has_no_test_files () =
  let tests = List.filter (fun (name, _) -> Filename.check_suffix name "_test.go")
      Embedded_go_runtime.files in
  if tests <> [] then
    failf "test files must not be embedded into user modules: %s"
      (String.concat ", " (List.map fst tests))

(* Read only explicit dependency atoms: a path in a comment or generator action
   cannot make Dune observe changes to that input. This small lexer also permits
   quoted atoms and nested dependency forms without treating their punctuation as
   part of a filename. *)
type dune_token = Open | Close | Atom of string

let dependency_atoms source =
  let length = String.length source in
  let separator = function ' ' | '\t' | '\r' | '\n' | '(' | ')' | ';' | '"' -> true | _ -> false in
  let rec tokens i acc =
    if i = length then List.rev acc else match source.[i] with
    | ' ' | '\t' | '\r' | '\n' -> tokens (i + 1) acc
    | ';' ->
      let next = match String.index_from_opt source i '\n' with Some n -> n | None -> length in
      tokens next acc
    | '(' -> tokens (i + 1) (Open :: acc)
    | ')' -> tokens (i + 1) (Close :: acc)
    | '"' ->
      let value = Buffer.create 32 in
      let rec quoted j =
        if j = length then failf "unterminated quoted Dune dependency atom"
        else match source.[j] with
        | '"' -> tokens (j + 1) (Atom (Buffer.contents value) :: acc)
        | '\\' when j + 1 < length -> Buffer.add_char value source.[j + 1]; quoted (j + 2)
        | c -> Buffer.add_char value c; quoted (j + 1) in
      quoted (i + 1)
    | _ ->
      let j = ref (i + 1) in
      while !j < length && not (separator source.[!j]) do incr j done;
      tokens !j (Atom (String.sub source i (!j - i)) :: acc) in
  let rec collect stack acc = function
    | [] -> if stack = [] then List.rev acc else failf "unclosed Dune dependency form"
    | Open :: Atom "deps" :: rest -> collect (true :: stack) acc rest
    | Open :: rest -> collect (false :: stack) acc rest
    | Close :: rest ->
      (match stack with _ :: parent -> collect parent acc rest | [] -> failf "unmatched Dune closing parenthesis")
    | Atom atom :: rest -> collect stack (if List.mem true stack then atom :: acc else acc) rest in
  collect [] [] (tokens 0 [])

let missing_runtime_dependencies names source =
  let declared = dependency_atoms source in
  (* Dune source paths use '/', including when this test runs on Windows. *)
  List.filter (fun name -> not (List.mem ("../../../../runtime/go/teslrt/" ^ name) declared)) names

let test_every_embedded_file_is_rule_dependency () =
  let rule = repo_root () // "compiler" // "lib" // "go_runtime" // "embedded" // "dune" in
  let missing = missing_runtime_dependencies (List.map fst Embedded_go_runtime.files) (read_file rule) in
  if missing <> [] then
    failf "embedded runtime files missing explicit Dune rule dependencies (edits would not regenerate the snapshot): %s"
      (String.concat ", " missing)

let test_dependency_check_ignores_non_dependencies () =
  let source = {|
; (deps ../../../../runtime/go/teslrt/missing.go)
(rule
 (deps "../../../../runtime/go/teslrt/present.go")
 (action (cat ../../../../runtime/go/teslrt/missing.go)))
|} in
  Alcotest.(check (list string)) "comments and action inputs do not repair an omitted dependency"
    ["missing.go"] (missing_runtime_dependencies ["present.go"; "missing.go"] source)

let test_generator_emits_binary_snapshot () =
  let executable = Unix.realpath Sys.executable_name in
  let generator = Filename.dirname executable // ".." // "gen" // "gen_go_runtime.exe" in
  let channel = Unix.open_process_args_in generator [|generator|] in
  (* Text-mode input would hide the Windows output conversion this test checks. *)
  set_binary_mode_in channel true;
  let output = In_channel.input_all channel in
  let status = Unix.close_process_in channel in
  Alcotest.(check bool) "generator exits successfully" true (status = Unix.WEXITED 0);
  Alcotest.(check bool) "generated source has no literal CR bytes" false
    (String.contains output '\r');
  let snapshot = repo_root () // "compiler" // "lib" // "go_runtime" // "embedded"
                 // "embedded_go_runtime.ml" in
  Alcotest.(check bool) "raw generator output matches the promoted snapshot" true
    (output = read_file snapshot)

let () =
  Alcotest.run "embedded-go-runtime-seam" [
    ("embedded runtime", [
        Alcotest.test_case "every embedded file is byte-identical to the tree" `Quick
          test_embedded_matches_disk;
        Alcotest.test_case "every runtime file is embedded" `Quick
          test_every_runtime_file_is_embedded;
        Alcotest.test_case "no test file is embedded" `Quick
          test_embedded_list_has_no_test_files;
        Alcotest.test_case "every embedded input invalidates the snapshot" `Quick
          test_every_embedded_file_is_rule_dependency;
        Alcotest.test_case "comments and actions cannot impersonate dependencies" `Quick
          test_dependency_check_ignores_non_dependencies;
        Alcotest.test_case "generator output is byte-stable on native hosts" `Quick
          test_generator_emits_binary_snapshot;
      ]);
  ]
