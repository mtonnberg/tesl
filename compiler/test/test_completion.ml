open Completion

let marked source =
  let marker = "<cursor>" in
  let at = Str.search_forward (Str.regexp_string marker) source 0 in
  let before = String.sub source 0 at in
  let source = before ^ String.sub source (at + String.length marker)
      (String.length source - at - String.length marker) in
  let lines = String.split_on_char '\n' before in
  source, List.length lines - 1, String.length (List.hd (List.rev lines))

let query source =
  let source, line, col = marked source in
  Compile.completions_source "completion.tesl" source line col

let find name source =
  match List.find_opt (fun item -> item.ci_label = name) (query source) with
  | Some item -> item
  | None -> Alcotest.failf "Missing %s in completions for:\n%s\nGot: %s" name source
      (String.concat ", " (List.map (fun item -> item.ci_label) (query source)))

let absent name source =
  Alcotest.(check bool) (name ^ " absent") false
    (List.exists (fun item -> item.ci_label = name) (query source))

let header = "module Demo exposing []\n"
let expression body = header ^ "fn demo() -> Int = " ^ body ^ "\n"
let contains needle text =
  try ignore (Str.search_forward (Str.regexp_string needle) text 0); true
  with Not_found -> false

let check_contains needle text = Alcotest.(check bool) needle true (contains needle text)

let offset source line col =
  let lines = Array.of_list (String.split_on_char '\n' source) in
  let start = ref col in
  for i = 0 to line - 1 do start := !start + String.length lines.(i) + 1 done;
  !start

let edits source = function
  | Type_system.Replace_range { start_line; start_col; end_line; end_col; replacement } ->
    offset source start_line start_col, offset source end_line end_col, replacement
  | Insert_line { line; text } ->
    let at = offset source line 0 in at, at, text ^ "\n"
  | Replace_span { start_line; end_line; replacement } ->
    let lines = String.split_on_char '\n' source in
    offset source start_line 0, offset source end_line (String.length (List.nth lines end_line)), replacement
  | _ -> Alcotest.fail "Unexpected completion edit"

let apply source item =
  let changes = List.filter_map Fun.id [item.ci_edit; item.ci_import_fix]
      |> List.map (edits source) |> List.sort (fun (a, _, _) (b, _, _) -> compare b a) in
  List.fold_left (fun source (start, stop, replacement) ->
    String.sub source 0 start ^ replacement ^ String.sub source stop (String.length source - stop)) source changes

let t_modules () =
  let item = find "Tesl.String" (header ^ "import Tesl.Str<cursor>\n") in
  Alcotest.(check string) "module kind" "module" item.ci_kind;
  Alcotest.(check bool) "no additional import" false item.ci_requires_import

let t_import_export () =
  let source = header ^ "import Tesl.String exposing [String.<cursor>]\n" in
  let item = find "String.length" source in
  absent "List.map" source;
  Alcotest.(check bool) "already in import" false item.ci_requires_import;
  Alcotest.(check bool) "no import edit" true (item.ci_import_fix = None)

let t_trailing_dot () =
  let item = find "String.length" (expression "String.<cursor>") in
  Alcotest.(check string) "function kind" "function" item.ci_kind;
  Alcotest.(check (option string)) "origin" (Some "Tesl.String") item.ci_module;
  Alcotest.(check bool) "requires import" true item.ci_requires_import;
  Alcotest.(check bool) "has documentation" true (Option.fold ~none:false ~some:((<>) "") item.ci_documentation)

let t_name_search () = ignore (find "String.length" (expression "len<cursor>"))
let t_case_search () = ignore (find "String.length" (expression "STRING.LE<cursor>"))

let t_replacement () =
  let input = expression "String.le<cursor>ngth" in
  let source, _, _ = marked input in
  let item = find "String.length" input in
  let after = apply source item in
  check_contains "= String.length\n" after;
  Alcotest.(check bool) "no duplicated suffix" false (contains "lengthngth" after)

let t_annotation () =
  let source = header ^ "fn f(x: May<cursor>) -> Int = 0\n" in
  let item = find "Maybe" source in
  Alcotest.(check string) "type kind" "type" item.ci_kind;
  check_contains "Maybe a" item.ci_detail;
  absent "Maybe.map" source;
  absent "Something" source

let t_only_types () =
  let source = header ^ "fn f() -> <cursor> = 0\n" in
  ignore (find "String" source);
  ignore (find "Maybe" source);
  Alcotest.(check bool) "type context excludes values" true
    (List.for_all (fun item -> item.ci_kind = "type") (query source));
  absent "SmtpConfig" source;
  absent "Database" source

let t_record_type () = ignore (find "Maybe" (header ^ "record R {\n  field: May<cursor>\n}\n"))
let t_empty () = ignore (find "Maybe" (header ^ "<cursor>"))

let t_comment () = Alcotest.(check int) "comment" 0 (List.length (query (header ^ "# String.<cursor>")))
let t_literal () = Alcotest.(check int) "string" 0 (List.length (query (expression "\"String.<cursor>\"")))
let t_unfinished_literal () = Alcotest.(check int) "unfinished string" 0 (List.length (query (expression "\"String.<cursor>")))
let t_escaped_literal () = Alcotest.(check int) "escaped quote" 0 (List.length (query (expression "\"\\\" String.<cursor>\"")))
let t_after_comment () = ignore (find "String.length" (header ^ "# comment\nfn f() -> Int = String.<cursor>"))

let t_bad_positions () =
  List.iter (fun (line, col) ->
    Alcotest.(check int) "invalid cursor" 0
      (List.length (Compile.completions_source "bad.tesl" header line col)))
    [-1, 0; 0, -1; 99, 0; 0, 100000]

let t_broken_neighbor () =
  let source = header ^ "fn broken() -> Int =\nfn next() -> Int = String.<cursor>\n" in
  let item = find "String.length" source in
  Alcotest.(check bool) "conservative import edit" true (item.ci_import_fix = None)

let t_imported_all () =
  let item = find "String.length" (header ^ "import Tesl.String\nfn f() -> Int = String.<cursor>\n") in
  Alcotest.(check bool) "in scope" false item.ci_requires_import;
  Alcotest.(check bool) "no duplicate import" true (item.ci_import_fix = None)

let t_imported_explicit () =
  let item = find "String.length" (header ^ "import Tesl.String exposing [String.length]\nfn f() -> Int = String.<cursor>\n") in
  Alcotest.(check bool) "explicitly in scope" false item.ci_requires_import

let t_extend_import () =
  let input = header ^ "import Tesl.String exposing [String.trim]\nfn f() -> Int = String.le<cursor>\n" in
  let item = find "String.length" input in
  let source, _, _ = marked input in
  let after = apply source item in
  check_contains "exposing [String.trim, String.length]" after;
  Alcotest.(check int) "one module import" 2
    (List.length (Str.split_delim (Str.regexp_string "import Tesl.String") after))

let t_constructor () =
  let item = find "Something" (expression "Some<cursor>") in
  Alcotest.(check string) "constructor" "constructor" item.ci_kind;
  check_contains "Maybe" item.ci_detail

let t_ctor_wildcard () =
  let item = find "Something" (header ^ "import Tesl.Maybe exposing [Maybe(..)]\nfn f() -> Int = Some<cursor>\n") in
  Alcotest.(check bool) "wildcard brings ctor in scope" false item.ci_requires_import

let t_unavailable () = absent "String.words" (expression "String.<cursor>")
let t_opaque () = absent "MkCivilDate" (expression "<cursor>")

let record_source tail = header ^ "record User {\n  name: String\n  age: Int\n}\nfn f(u: User) -> String = " ^ tail ^ "\n"
let t_field () =
  let item = find "name" (record_source "u.<cursor>") in
  Alcotest.(check string) "field" "field" item.ci_kind;
  absent "String.length" (record_source "u.<cursor>")
let t_partial_field () =
  let input = record_source "u.na<cursor>me" in
  let source, _, _ = marked input in
  let item = find "name" input in
  check_contains "= u.name\n" (apply source item)

let t_crlf () =
  let input = Str.global_replace (Str.regexp "\n") "\r\n" (expression "String.<cursor>") in
  ignore (find "String.length" input)

let t_unicode () =
  let input = expression "if \"😀\" == \"å\" then String.le<cursor> else 0" in
  let source, _, _ = marked input in
  check_contains "then String.length else" (apply source (find "String.length" input))

let t_deterministic () =
  let source = expression "<cursor>" in
  let identity item = item.ci_label ^ ":" ^ Option.value ~default:"" item.ci_module in
  let labels = List.map identity (query source) in
  Alcotest.(check (list string)) "stable ordering" labels (List.map identity (query source));
  Alcotest.(check int) "unique symbols per origin" (List.length labels) (List.length (List.sort_uniq compare labels))

let t_applied_program () =
  let input = header ^ "import Tesl.Prelude exposing [String, Int]\nfn size(s: String) -> Int = String.le<cursor> s\n" in
  let source, _, _ = marked input in
  let after = apply source (find "String.length" input) in
  let errors = Compile.check_source "demo.tesl" after
    |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
  if errors <> [] then Alcotest.failf "Applied completion did not check:\n%s\n%s"
      after (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) errors))

let t_empty_import_location () =
  let source = header ^ "May<cursor>" in
  let item = find "Maybe" source in
  (* An invalid top-level expression has no safe auto-import, but remains discoverable. *)
  Alcotest.(check bool) "missing import visible" true item.ci_requires_import

let check_program source =
  let errors = Compile.check_source "demo.tesl" source
    |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
  if errors <> [] then Alcotest.failf "%s\n%s" source
    (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) errors))

let t_type_auto_import () =
  let input = "module Demo exposing [Box]\nimport Tesl.Prelude exposing [Int]\nrecord Box {\n  value: May<cursor> Int\n}\n" in
  let item = find "Maybe" input in
  let source, _, _ = marked input in
  let after = apply source item in
  check_contains "import Tesl.Maybe exposing [Maybe]" after;
  check_contains "value: Maybe Int" after;
  check_program after

let t_type_extends_import () =
  let input = header ^ "import Tesl.Prelude exposing [Int]\nimport Tesl.Maybe exposing [Nothing]\nfn missing() -> May<cursor> Int = Nothing\n" in
  let item = find "Maybe" input in
  let source, _, _ = marked input in
  let after = apply source item in
  check_contains "exposing [Nothing, Maybe]" after;
  check_program after

let t_preserves_import_comments () =
  List.iter (fun exposing ->
    let input = header ^ "import Tesl.Prelude exposing [Int]\nimport Tesl.Maybe exposing "
      ^ exposing ^ " # import note\nrecord Box {\n  value: May<cursor> Int\n}\n" in
    let source, _, _ = marked input in
    let after = apply source (find "Maybe" input) in
    check_contains "# import note" after;
    if contains "# constructor" input then check_contains "# constructor" after;
    check_program after)
    ["[]"; "[Nothing,]"; "[\n  Nothing # constructor\n]";
     "[\n  Nothing, # constructor\n]"; "[\n  # constructor\n]"]

let t_type_already_imported () =
  List.iter (fun import ->
    let input = header ^ import ^ "\nfn missing() -> May<cursor> Int = Nothing\n" in
    let item = find "Maybe" input in
    Alcotest.(check bool) "type in scope" false item.ci_requires_import;
    Alcotest.(check bool) "no duplicate type import" true (item.ci_import_fix = None))
    ["import Tesl.Maybe"; "import Tesl.Maybe exposing [Maybe]"; "import Tesl.Maybe exposing [Maybe(..)]"]

let t_local_type_wins () =
  let input = header ^ "record Maybe { value: Int }\nfn use(x: May<cursor>) -> Int = x.value\n" in
  let item = find "Maybe" input in
  Alcotest.(check (option string)) "local type origin" None item.ci_module;
  Alcotest.(check bool) "do not import a conflicting type" false item.ci_requires_import;
  Alcotest.(check bool) "no conflicting edit" true (item.ci_import_fix = None)

let t_local_function_wins () =
  let input = header ^ "fn identity(x: Int) -> Int = x\nfn use() -> Int = ident<cursor>\n" in
  let item = find "identity" input in
  Alcotest.(check (option string)) "local function origin" None item.ci_module;
  check_contains "Int -> Int" item.ci_detail

let t_effect_visible () =
  let item = find "nowMillis" (expression "nowMil<cursor>") in
  check_contains "requires [time]" item.ci_detail

let t_json_metadata () =
  let item = find "String.length" (expression "String.<cursor>") in
  let json = Compile.completions_response_to_json [item] in
  List.iter (fun s -> check_contains s json)
    ["\"version\":1"; "\"module\":\"Tesl.String\""; "\"documentation\":";
     "\"requires_import\":true"; "\"text_edit\":"; "\"import_edit\":"; "\"sort_text\":"]

let with_project files action =
  let directory = Filename.temp_file "tesl-completion-project-" "" in
  Sys.remove directory; Unix.mkdir directory 0o700;
  Fun.protect ~finally:(fun () ->
    Array.iter (fun name -> Sys.remove (Filename.concat directory name)) (Sys.readdir directory);
    Unix.rmdir directory) (fun () ->
    List.iter (fun (name, source) -> Out_channel.with_open_bin (Filename.concat directory name)
      (fun channel -> output_string channel source)) files;
    action directory)

let t_project_type_auto_import () =
  let input = "module Main exposing [Box]\nrecord Box { value: Per<cursor> }\n" in
  let source, line, col = marked input in
  with_project ["main.tesl", source;
    "models.tesl", "module Models exposing [Person]\nimport Tesl.Prelude exposing [Int]\nrecord Person { age: Int }\n"]
    (fun directory ->
      let filename = Filename.concat directory "main.tesl" in
      let items = Compile.completions_source filename source line col in
      let item = List.find (fun item -> item.ci_label = "Person") items in
      Alcotest.(check (option string)) "project module origin" (Some "Models") item.ci_module;
      let after = apply source item in
      check_contains "import Models exposing [Person]" after;
      let errors = Compile.check_source filename after |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
      if errors <> [] then Alcotest.failf "%s\n%s" after
        (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) errors)))

let t_imported_project_type_wins () =
  let input = "module Main exposing [Box]\nimport Models exposing [Maybe]\nrecord Box { value: May<cursor> }\n" in
  let source, line, col = marked input in
  with_project ["main.tesl", source;
    "models.tesl", "module Models exposing [Maybe]\nimport Tesl.Prelude exposing [Int]\nrecord Maybe { value: Int }\n"]
    (fun directory ->
      let items = Compile.completions_source (Filename.concat directory "main.tesl") source line col
        |> List.filter (fun item -> item.ci_label = "Maybe") in
      Alcotest.(check int) "one in-scope type" 1 (List.length items);
      let item = List.hd items in
      Alcotest.(check (option string)) "keep project identity" (Some "Models") item.ci_module;
      Alcotest.(check bool) "no conflicting stdlib import" true (item.ci_import_fix = None))

let t_project_type_ambiguity_and_exports () =
  let source, line, col = marked "module Main exposing [Box]\nrecord Box { value: Sha<cursor> }\n" in
  with_project ["main.tesl", source;
    "left.tesl", "module Left exposing [Shared]\nrecord Shared {}\n";
    "right.tesl", "module Right exposing [Shared]\nrecord Shared {}\n";
    "private.tesl", "module Private exposing []\nrecord Shared {}\n";
    "wrong.tesl", "module Unresolvable exposing [Shared]\nrecord Shared {}\n"]
    (fun directory ->
      let items = Compile.completions_source (Filename.concat directory "main.tesl") source line col
        |> List.filter (fun item -> item.ci_label = "Shared") in
      Alcotest.(check (list string)) "explicit choices without private/unresolvable modules"
        ["Left"; "Right"] (List.map (fun item -> Option.get item.ci_module) items))

let () = Alcotest.run "Completion" ["discovery", List.map (fun (name, test) ->
  Alcotest.test_case name `Quick test) [
  "module names", t_modules; "exposing list", t_import_export;
  "trailing dot", t_trailing_dot; "discover by member name", t_name_search;
  "case insensitive", t_case_search; "replace whole token", t_replacement;
  "type parameters", t_annotation; "only types in annotation", t_only_types;
  "record field annotation", t_record_type; "fresh project", t_empty;
  "comments", t_comment; "strings", t_literal; "unfinished strings", t_unfinished_literal;
  "escaped strings", t_escaped_literal; "after comment", t_after_comment;
  "invalid cursors", t_bad_positions; "broken neighboring declaration", t_broken_neighbor;
  "wholesale import", t_imported_all; "explicit import", t_imported_explicit;
  "extend import", t_extend_import; "constructors", t_constructor;
  "constructor wildcard", t_ctor_wildcard; "unavailable backend symbols", t_unavailable;
  "opaque constructors", t_opaque; "record fields", t_field; "partial record field", t_partial_field;
  "CRLF", t_crlf; "Unicode ranges", t_unicode; "deterministic and unique", t_deterministic;
  "accepted insertion type checks", t_applied_program; "incomplete top level", t_empty_import_location;
  "type selection automatically imports", t_type_auto_import;
  "type selection extends existing import", t_type_extends_import;
  "auto-import preserves comments and layout", t_preserves_import_comments;
  "type selection prevents duplicate imports", t_type_already_imported;
  "local type prevents conflicting auto-import", t_local_type_wins;
  "local function keeps its signature", t_local_function_wins;
  "effect requirement visible", t_effect_visible;
  "project type auto-import checks", t_project_type_auto_import;
  "project type wins over stdlib", t_imported_project_type_wins;
  "ambiguous project types retain module choices", t_project_type_ambiguity_and_exports;
  "agent JSON metadata", t_json_metadata]]
