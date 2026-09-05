open Alcotest
open Workspace_index

let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun output -> output_string output source)
let with_project files action = with_temporary_directory (fun root ->
  write (Filename.concat root "tesl.toml") "[project]\nname = \"workspace-test\"\n";
  List.iter (fun (name, source) -> write (Filename.concat root name) source) files;
  Fun.protect ~finally:Checker.clear_import_parse_cache (fun () -> action root))
let lib = "module Lib exposing [double]\nimport Tesl.Prelude exposing [Int]\nfn double(n: Int) -> Int = n * 2\n"
let main = "module Main exposing [run]\nimport Tesl.Prelude exposing [Int]\nimport Lib exposing [double]\nfn run(n: Int) -> Int = Lib.double n + double n\n"
let fixtures = ["lib.tesl", lib; "main.tesl", main]
let main_path root = Filename.concat root "main.tesl"
let selected snapshot file line col = match at snapshot file line col with
  | Some value -> value | None -> failf "no semantic symbol at %s:%d:%d" file line col
let complete snapshot =
  if snapshot.problems <> [] then failf "incomplete: %s" (json_list problem_json snapshot.problems)
let expect_safe snapshot selected name = match validate_rename snapshot (Some selected) name snapshot.id with
  | Ok edits -> edits
  | Error reason -> failf "rename rejected: %s" reason
let expect_refused snapshot selected name = match validate_rename snapshot (Some selected) name snapshot.id with
  | Ok _ -> fail "unsafe rename accepted" | Error _ -> ()
let contains text needle = try ignore (Str.search_forward (Str.regexp_string needle) text 0); true with Not_found -> false

let exposed_and_qualified () = with_project fixtures (fun root ->
  let index = build (main_path root) in complete index;
  let qualified = selected index (main_path root) 3 28 in
  let plain = selected index (main_path root) 3 39 in
  check bool "same semantic declaration" true (same_binding qualified.symbol plain.symbol);
  check string "declaring module" (Filename.concat root "lib.tesl") qualified.symbol.symbol_loc.file;
  check int "definition, two clauses and two callers" 5 (List.length (references index qualified.symbol));
  let edits = expect_safe index qualified "twice" in
  check int "all references edited" 5 (List.length edits);
  let changed = apply_edits main (List.filter (fun edit -> edit.loc.file = main_path root) edits) in
  check bool "qualified prefix preserved" true (contains changed "Lib.twice n + twice n");
  check string "proposal did not mutate source" main (In_channel.with_open_bin (main_path root) In_channel.input_all))

let local_shadow () =
  let source = "module Main exposing [run]\nimport Tesl.Prelude exposing [Int]\nimport Lib exposing [double]\nfn run(double: Int) -> Int = Lib.double double\n" in
  with_project ["lib.tesl", lib; "main.tesl", source] (fun root ->
    let index = build (main_path root) in complete index;
    let local = selected index (main_path root) 3 7 in
    let imported = selected index (main_path root) 3 33 in
    check bool "parameter is a distinct symbol" false (same_binding local.symbol imported.symbol);
    check int "parameter declaration and argument" 2 (List.length (references index local.symbol));
    check int "import excludes shadowed arguments" 4 (List.length (references index imported.symbol));
    check bool "language rejects existing shadowing" true (validation_errors index <> []);
    expect_refused index imported "twice")

let collision () =
  let source = "module Main exposing [run]\nimport Tesl.Prelude exposing [Int]\nimport Lib exposing [double]\nfn run(twice: Int) -> Int = double twice\n" in
  with_project ["lib.tesl", lib; "main.tesl", source] (fun root ->
    let index = build (main_path root) in complete index;
    expect_refused index (selected index (main_path root) 3 28) "twice")

let same_name_other_module () =
  with_project (fixtures @ ["other.tesl", "module Other exposing [double]\nimport Tesl.Prelude exposing [Int]\nfn double(n: Int) -> Int = n + 1\n"]) (fun root ->
    let index = build (main_path root) in complete index;
    let imported = selected index (main_path root) 3 28 in
    let other = selected index (Filename.concat root "other.tesl") 2 3 in
    check bool "same spelling has distinct identity" false (same_binding imported.symbol other.symbol);
    check int "unrelated declaration omitted" 5 (List.length (references index imported.symbol));
    ignore (expect_safe index imported "twice"))

let comments_unicode_crlf () =
  let source = "module Main exposing [run]\r\nimport Tesl.Prelude exposing [Int, String]\r\nimport Lib exposing [double]\r\n# 😀 double in a comment\r\nfn run(n: Int) -> Int =\r\n  let text = \"😀 double\"\r\n  double n\r\n" in
  with_project ["lib.tesl", lib; "main.tesl", source] (fun root ->
    let index = build (main_path root) in complete index;
    let imported = selected index (main_path root) 6 2 in
    let edits = expect_safe index imported "twice" in
    let changed = apply_edits source (List.filter (fun edit -> edit.loc.file = main_path root) edits) in
    check bool "comment preserved" true (contains changed "# 😀 double in a comment\r\n");
    check bool "string preserved" true (contains changed "\"😀 double\"\r\n");
    check bool "only semantic call changed" true (contains changed "  twice n\r\n"))

let interpolation () =
  let source = "module Main exposing [show]\nimport Tesl.Prelude exposing [Int, String]\nimport Lib exposing [double]\nfn show(n: Int) -> String = \"😀 ${double n}\"\n" in
  with_project ["lib.tesl", lib; "main.tesl", source] (fun root ->
    let index = build (main_path root) in complete index;
    let imported = selected index (Filename.concat root "lib.tesl") 2 3 in
    check int "interpolation body is semantic" 4 (List.length (references index imported.symbol));
    let edits = expect_safe index imported "twice" in
    check bool "interpolation span uses byte offsets" true
      (contains (apply_edits source (List.filter (fun edit -> edit.loc.file = main_path root) edits)) "${twice n}"))

let dirty_files_and_stale_precondition () = with_project fixtures (fun root ->
  let first = build (main_path root) in
  let change source = Str.global_replace (Str.regexp_string "double") "triple" source in
  write (Filename.concat root "lib.tesl") (change lib);
  write (main_path root) (change main);
  let second = build (main_path root) in complete second;
  check bool "both dirty mirror files change snapshot" false (first.id = second.id);
  let imported = selected second (main_path root) 3 28 in
  check string "new source wins" "triple" imported.symbol.symbol_name;
  check bool "old snapshot refused" true (match validate_rename second (Some imported) "twice" first.id with Error _ -> true | _ -> false);
  ignore (expect_safe second imported "twice"))

let nested_projects_and_generated () = with_project fixtures (fun root ->
  write (Filename.concat root "nested/tesl.toml") "[project]\nname=\"other\"\n";
  write (Filename.concat root "nested/broken.tesl") "broken syntax";
  write (Filename.concat root "_build/generated.tesl") "broken syntax";
  let index = build (main_path root) in complete index;
  check int "only active project sources" 2 (List.length index.units))

let parse_failure_recovery () = with_project fixtures (fun root ->
  write (Filename.concat root "broken.tesl") "module Broken exposing [";
  let index = build (main_path root) in
  check bool "partial explicit" true (List.exists (fun problem -> problem.code = "parse-error") index.problems);
  expect_refused index (selected index (main_path root) 3 28) "twice";
  write (Filename.concat root "broken.tesl") "module Broken exposing []\n";
  let fixed = build (main_path root) in complete fixed;
  check bool "repair invalidates snapshot" false (index.id = fixed.id))

let missing_import () = with_project ["main.tesl", main] (fun root ->
  let index = build (main_path root) in
  check bool "missing import explicit" true (index.problems <> []);
  write (Filename.concat root "lib.tesl") lib;
  let fixed = build (main_path root) in complete fixed;
  check bool "creation invalidates snapshot" false (index.id = fixed.id))

let cycle () =
  let source own other fname otherfn = Printf.sprintf
    "module %s exposing [%s]\nimport Tesl.Prelude exposing [Int]\nimport %s exposing [%s]\nfn %s(n: Int) -> Int =\n  if n == 0 then\n    0\n  else\n    %s (n - 1)\n"
    own fname other otherfn fname otherfn in
  with_project ["a.tesl", source "A" "B" "alpha" "beta"; "b.tesl", source "B" "A" "beta" "alpha"] (fun root ->
    let path = Filename.concat root "a.tesl" in
    let index = build path in complete index;
    check int "cycle loads each module once" 2 (List.length index.units);
    let target = selected index path 3 3 in
    check int "cross-cycle reference set" 4 (List.length (references index target.symbol));
    ignore (expect_safe index target "first"))

let type_and_constructor () =
  let base = "module Lib exposing [Count]\nimport Tesl.Prelude exposing [Int]\ntype Count = Int\n" in
  let user = "module Main exposing [make]\nimport Tesl.Prelude exposing [Int]\nimport Lib exposing [Count]\nfn make(n: Int) -> Count = Count n\n" in
  with_project ["lib.tesl", base; "main.tesl", user] (fun root ->
    let index = build (main_path root) in complete index;
    let target = selected index (Filename.concat root "lib.tesl") 2 5 in
    check string "type namespace" "type" (kind target.symbol.symbol_kind);
    check int "type and nominal constructor share identity" 5 (List.length (references index target.symbol));
    ignore (expect_safe index target "Total"))

let read_only_lifted_source () = with_temporary_directory (fun stdlib ->
  write (Filename.concat stdlib "list.tesl") "module List exposing [map]\nimport Tesl.Prelude exposing [Int]\nfn map(n: Int) -> Int = n\n";
  let old = Sys.getenv_opt "TESL_STDLIB_DIR" in
  Unix.putenv "TESL_STDLIB_DIR" stdlib;
  Fun.protect ~finally:(fun () -> Unix.putenv "TESL_STDLIB_DIR" (Option.value ~default:"" old)) (fun () ->
    with_project ["main.tesl", "module Main exposing [run]\nimport Tesl.Prelude exposing [Int]\nimport Tesl.List exposing [List.map]\nfn run(n: Int) -> Int = List.map n\n"] (fun root ->
      let index = build (main_path root) in complete index;
      let target = selected index (main_path root) 3 29 in
      check string "stdlib declaration source" (Filename.concat stdlib "list.tesl") target.symbol.symbol_loc.file;
      expect_refused index target "transform")))

let bounds_and_unknown_context () = with_project fixtures (fun root ->
  let before = build (main_path root) in
  write (Filename.concat root "oversized.tesl") (String.make (1024 * 1024 + 1) ' ');
  let index = build (main_path root) in
  check bool "new rejected input still changes snapshot" false (before.id = index.id);
  check bool "budget failure explicit" true (List.exists (fun problem -> problem.code = "workspace-limit") index.problems);
  expect_refused index (selected index (main_path root) 3 28) "twice")

let session_rename_frames () = with_project fixtures (fun root ->
  let path = main_path root in
  let index = build path in
  let input = Filename.concat root "request.bin" and output = Filename.concat root "response.bin" in
  Out_channel.with_open_bin input (fun stream -> List.iter (Workspace_session.write_frame stream)
    ["mirror-revision"; "--workspace-rename-json"; path; "3"; "28"; "twice"; index.id;
     "mirror-revision"; "--workspace-definition-json"; path; "3"; "28"]);
  In_channel.with_open_bin input (fun input -> Out_channel.with_open_bin output (fun output -> Workspace_session.run input output));
  In_channel.with_open_bin output (fun input ->
    let hello = Workspace_session.read_frame input 4096 in
    check bool "capability advertised" true (contains hello "workspace-rename-arguments-v1");
    let rename = Workspace_session.read_frame input Workspace_session.max_response in
    check bool "rename has safe proposal" true (contains rename "\"safe\":true");
    let next = Workspace_session.read_frame input Workspace_session.max_response in
    check bool "five-frame request remains aligned" true (contains next "\"complete\":true")))

let import_all () =
  let source = "module Main exposing [run]\nimport Tesl.Prelude exposing [Int]\nimport Lib\nfn run(n: Int) -> Int = Lib.double n\n" in
  with_project ["lib.tesl", lib; "main.tesl", source] (fun root ->
    let index = build (main_path root) in complete index;
    let target = selected index (main_path root) 3 28 in
    check int "qualified-only import has no exposure edit" 3 (List.length (references index target.symbol));
    ignore (expect_safe index target "twice"))

let interpolation_escapes () =
  let source = "module Main exposing [show]\r\nimport Tesl.Prelude exposing [Int, String]\r\nimport Lib exposing [double]\r\nfn show(n: Int) -> String = \"double \\n😀 \\t ${double n} ${double n}\"\r\n" in
  with_project ["lib.tesl", lib; "main.tesl", source] (fun root ->
    let index = build (main_path root) in complete index;
    let target = selected index (Filename.concat root "lib.tesl") 2 3 in
    check int "both expression segments indexed" 5 (List.length (references index target.symbol));
    let edits = expect_safe index target "twice" in
    let changed = apply_edits source (List.filter (fun edit -> edit.loc.file = main_path root) edits) in
    check bool "decoded escapes preserve exact original offsets" true
      (contains changed "\"double \\n😀 \\t ${twice n} ${twice n}\"\r\n"))

let interpolation_local_scope () =
  let source = "module Main exposing [show]\nimport Tesl.Prelude exposing [Int, String]\nfn show(n: Int) -> String = \"😀 ${(fn(innerValue: Int) -> innerValue) n}\"\n" in
  with_project ["main.tesl", source] (fun root ->
    let index = build (main_path root) in complete index;
    let target = List.find (fun (use : use) -> use.symbol.symbol_name = "innerValue") index.uses in
    check int "interpolation-only local binder is indexed" 2 (List.length (references index target.symbol));
    ignore (expect_safe index target "renamedValue"))

let invalid_rename_names () = with_project fixtures (fun root ->
  let index = build (main_path root) in complete index;
  let target = selected index (main_path root) 3 28 in
  List.iter (expect_refused index target) [""; "fn"; "twice "; "twice #comment"; "two names"; "Lib.twice"; "Twice"; "double"; String.make 129 'x'])

let stable_mirror_identity () = with_project fixtures (fun root ->
  let before = build (main_path root) in
  with_project fixtures (fun other ->
    let after = build (main_path other) in
    check string "same relative content snapshot across mirrors" before.id after.id;
    let one = selected before (main_path root) 3 28 and two = selected after (main_path other) 3 28 in
    check string "declaration identity survives mirror move" (symbol_id before.root one.symbol) (symbol_id after.root two.symbol)))

let manifest_change () = with_project fixtures (fun root ->
  let before = build (main_path root) in
  write (Filename.concat root "tesl.toml") "[project]\nname=\"changed\"\n";
  let after = build (main_path root) in
  check bool "manifest invalidates semantic snapshot" false (before.id = after.id))

let invalid_context_is_partial () =
  let source = "module Main exposing [run]\nimport Tesl.Prelude exposing [Int]\nimport Lib exposing [double]\nrecord Row { double: Int }\nfn run(row: Row) -> Int = row.double\n" in
  with_project ["lib.tesl", lib; "main.tesl", source] (fun root ->
    let index = build (main_path root) in
    check bool "unsupported fields do not claim complete references" true
      (List.exists (fun problem -> problem.code = "unsupported-reference-context") index.problems);
    let target = selected index (Filename.concat root "lib.tesl") 2 3 in
    check int "field text is never a function reference" 3 (List.length (references index target.symbol));
    expect_refused index target "twice")

let () = Alcotest.run "Workspace semantic index" ["identity and edits", List.map (fun (name, test) -> test_case name `Quick test)
  ["interpolation local scope", interpolation_local_scope; "qualified import all", import_all; "interpolation escaped prefix", interpolation_escapes;
   "invalid rename identifiers", invalid_rename_names; "stable mirror identity", stable_mirror_identity;
   "manifest invalidation", manifest_change; "unsupported contexts explicit", invalid_context_is_partial;
   "exposing and qualified calls", exposed_and_qualified; "local shadowing", local_shadow;
   "capture conflict", collision; "unrelated same spelling", same_name_other_module;
   "comments Unicode and CRLF", comments_unicode_crlf; "string interpolation", interpolation;
   "two dirty files and stale precondition", dirty_files_and_stale_precondition;
   "nested and generated projects", nested_projects_and_generated;
   "parse failure and repair", parse_failure_recovery; "missing imported file", missing_import;
   "import cycle", cycle; "nominal type and constructor", type_and_constructor;
   "read-only stdlib source", read_only_lifted_source; "bounded refusal", bounds_and_unknown_context;
   "session rename framing", session_rename_frames]]
