(** Antagonistic regression tests for Critical Review 40.

    Focus: user-facing toolchain coherence rather than only core typing.

    R40_01  API IR preserves simple GET route shape
    R40_02  API IR mis-shapes POST body type as a function type
    R40_03  API IR collapses POST response type to Unit
    R40_04  Definition lookup stops at file boundaries for imported symbols
    R40_05  Occurrences lookup stops at file boundaries for imported symbols
    R40_06  Type-at still works on imported function call sites
    R40_07  Completions include imported unqualified helpers
    R40_08  Completions include qualified imported helpers
    R40_09  --deps lists transitive local imports
    R40_10  --deps de-duplicates shared imports
    R40_11  --deps terminates cleanly on import cycles
    R40_12  semantic-json contains functions, local bindings, and expr types
    R40_13  local-bindings-json includes test-block lets
    R40_14  fmt-check rejects non-canonical formatting
    R40_15  fmt rewrites source and fmt-check then passes
    R40_16  lint reports stable warning/fix payloads for spacing drift
    R40_17  TS generator emits branded fact schema for checks
    R40_18  TS generator preserves GET response type
    R40_19  TS generator mis-types POST body parameter as unknown
    R40_20  TS generator mis-types POST response as Unit
    R40_21  Elm generator preserves GET response type
    R40_22  Elm generator erases refinement/fact surface entirely
    R40_23  Elm generator emits null POST body instead of encoder use
    R40_24  Elm generator mis-types POST response as Unit
*)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let candidate2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists candidate then candidate
       else if Sys.file_exists candidate2 then candidate2
       else "tesl")

let contains text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > text_len then false
    else if String.sub text i needle_len = needle then true
    else loop (i + 1)
  in
  needle_len = 0 || loop 0

let count_occurrences text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop i acc =
    if needle_len = 0 then acc
    else if i + needle_len > text_len then acc
    else if String.sub text i needle_len = needle then loop (i + needle_len) (acc + 1)
    else loop (i + 1) acc
  in
  loop 0 0

let assert_contains ~label haystack needle =
  if not (contains haystack needle) then
    failf "%s: expected to find %S in output:\n%s" label needle haystack

let assert_not_contains ~label haystack needle =
  if contains haystack needle then
    failf "%s: expected NOT to find %S in output:\n%s" label needle haystack

let assert_count ~label haystack needle expected =
  let actual = count_occurrences haystack needle in
  check int label expected actual

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_file prefix suffix content f =
  let path = Filename.temp_file prefix suffix in
  write_file path content;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let ensure_parent path =
  let parent = Filename.dirname path in
  if parent <> path && not (Sys.file_exists parent) then Unix.mkdir parent 0o755

let with_temp_project files f =
  let dir = Filename.temp_file "tesl-r40-proj" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  List.iter (fun (rel, content) ->
    let path = Filename.concat dir rel in
    ensure_parent path;
    write_file path content
  ) files;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () -> f dir)

let api_src = {|#lang tesl
module Api exposing [TodoApi]
import Tesl.Prelude exposing [Int, String, List]
import Tesl.String exposing [String.length]
import Tesl.Json exposing [stringCodec]

fact ValidTitle (s: String)
check validTitle(s: String) -> s: String ::: ValidTitle s =
  if 3 <= String.length(s) then
    ok s ::: ValidTitle s
  else
    fail 400 "too short"

record NewTodo {
  title: String ::: ValidTitle title
}
codec NewTodo {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via validTitle
    }
  ]
}

record Todo {
  id: String
  title: String
}
codec Todo {
  toJson {
    id -> "id" with_codec stringCodec
    title -> "title" with_codec stringCodec
  }
  fromJson_forbidden
}

api TodoApi {
  get "/todos" -> List Todo
  post "/todos" body todo: NewTodo -> Todo
}
|}

let cross_file_main_src = {|#lang tesl
module Main exposing [main]
import Local exposing [helper]
import Tesl.Prelude exposing [Int]
fn main() -> Int =
  helper()
|}

let cross_file_local_src = {|#lang tesl
module Local exposing [helper]
import Tesl.Prelude exposing [Int]
fn helper() -> Int =
  1
|}

let lint_warning_src =
  "#lang tesl\nmodule Main exposing [value]\nimport Tesl.Prelude exposing [Int]   \nfn value() -> Int = 1\n"

let semantic_src = {|#lang tesl
module Main exposing [double]
import Tesl.Prelude exposing [Int]
fn double(n: Int) -> Int =
  let twice = n * 2
  twice
|}

let test_block_bindings_src = {|#lang tesl
module Main exposing [main]
import Tesl.Prelude exposing [Int]
fn main() -> Int = 1

test "bindings" {
  let x = 1
  let y = x + 1
  expect y == 2
}
|}

let transitive_main_src = {|#lang tesl
module Main exposing [main]
import A exposing [fromA]
import Tesl.Prelude exposing [Int]
fn main() -> Int =
  fromA()
|}

let transitive_a_src = {|#lang tesl
module A exposing [fromA]
import Shared exposing [value]
import Tesl.Prelude exposing [Int]
fn fromA() -> Int =
  value()
|}

let transitive_b_src = {|#lang tesl
module B exposing [fromB]
import Shared exposing [value]
import Tesl.Prelude exposing [Int]
fn fromB() -> Int =
  value()
|}

let transitive_shared_src = {|#lang tesl
module Shared exposing [value]
import Tesl.Prelude exposing [Int]
fn value() -> Int =
  1
|}

let cycle_main_src = {|#lang tesl
module Main exposing [main]
import A exposing [fromA]
import Tesl.Prelude exposing [Int]
fn main() -> Int =
  fromA()
|}

let cycle_a_src = {|#lang tesl
module A exposing [fromA]
import B exposing [fromB]
import Tesl.Prelude exposing [Int]
fn fromA() -> Int =
  fromB()
|}

let cycle_b_src = {|#lang tesl
module B exposing [fromB]
import A exposing [fromA]
import Tesl.Prelude exposing [Int]
fn fromB() -> Int =
  1
|}

let r40_01_ir_get_route_shape_preserved () =
  with_temp_file "tesl-r40-ir-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--ir"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"get method" out "\"method\":\"GET\"";
    assert_contains ~label:"get response type" out "\"response\":{\"type\":\"List Todo\"";
    assert_contains ~label:"get elem type" out "\"elem_type\":\"Todo\"")

let r40_02_ir_post_body_preserves_plain_body_type () =
  with_temp_file "tesl-r40-ir-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--ir"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"post method" out "\"method\":\"POST\"";
    assert_contains ~label:"post body parsed as NewTodo" out "\"body\":{\"name\":\"todo\",\"type\":\"NewTodo\"";
    assert_contains ~label:"post body codec inferred as NewTodo" out "\"codec\":\"NewTodo\"";
    assert_not_contains ~label:"post body should not include route arrow" out "\"body\":{\"name\":\"todo\",\"type\":\"NewTodo -> Todo\"")

let r40_03_ir_post_response_preserves_todo_type () =
  with_temp_file "tesl-r40-ir-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--ir"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"post response Todo" out "\"response\":{\"type\":\"Todo\"";
    assert_contains ~label:"semantic return Todo" out "\"semantic_return\":{\"kind\":\"plain\",\"type_text\":\"Todo\"}";
    assert_not_contains ~label:"post response should not collapse to Unit" out "\"response\":{\"type\":\"Unit\"")

let r40_04_definition_stops_at_file_boundary () =
  with_temp_project [
    ("Main.tesl", cross_file_main_src);
    ("Local.tesl", cross_file_local_src);
  ] (fun dir ->
    let main = Filename.concat dir "Main.tesl" in
    let code, out = run_compiler ["--definition-json"; main; "5"; "2"] in
    check int "exit code" 0 code;
    assert_contains ~label:"definition null" out "\"definition\":null")

let r40_05_occurrences_stop_at_file_boundary () =
  with_temp_project [
    ("Main.tesl", cross_file_main_src);
    ("Local.tesl", cross_file_local_src);
  ] (fun dir ->
    let main = Filename.concat dir "Main.tesl" in
    let code, out = run_compiler ["--occurrences-json"; main; "5"; "2"] in
    check int "exit code" 0 code;
    assert_contains ~label:"occurrences empty" out "\"occurrences\":[]")

let r40_06_type_at_works_on_imported_call_site () =
  with_temp_project [
    ("Main.tesl", cross_file_main_src);
    ("Local.tesl", cross_file_local_src);
  ] (fun dir ->
    let main = Filename.concat dir "Main.tesl" in
    let code, out = run_compiler ["--type-at-json"; main; "5"; "2"] in
    check int "exit code" 0 code;
    assert_contains ~label:"type_at object" out "\"type_at\":{";
    assert_contains ~label:"type_at Int" out "\"type\":\"Int\"")

let r40_07_completions_include_imported_helper () =
  with_temp_project [
    ("Main.tesl", cross_file_main_src);
    ("Local.tesl", cross_file_local_src);
  ] (fun dir ->
    let main = Filename.concat dir "Main.tesl" in
    let code, out = run_compiler ["--completions-json"; main; "5"; "2"] in
    check int "exit code" 0 code;
    assert_contains ~label:"helper completion" out "\"label\":\"helper\"")

let r40_08_completions_include_qualified_imported_helper () =
  with_temp_project [
    ("Main.tesl", cross_file_main_src);
    ("Local.tesl", cross_file_local_src);
  ] (fun dir ->
    let main = Filename.concat dir "Main.tesl" in
    let code, out = run_compiler ["--completions-json"; main; "5"; "2"] in
    check int "exit code" 0 code;
    assert_contains ~label:"qualified helper completion" out "\"label\":\"Local.helper\"")

let r40_09_deps_lists_transitive_imports () =
  with_temp_project [
    ("Main.tesl", transitive_main_src);
    ("A.tesl", transitive_a_src);
    ("Shared.tesl", transitive_shared_src);
  ] (fun dir ->
    let main = Filename.concat dir "Main.tesl" in
    let code, out = run_compiler ["--deps"; main] in
    check int "exit code" 0 code;
    assert_contains ~label:"A listed" out "A.tesl";
    assert_contains ~label:"Shared listed" out "Shared.tesl")

let r40_10_deps_dedupes_shared_imports () =
  with_temp_project [
    ("Main.tesl", {|#lang tesl
module Main exposing [main]
import A exposing [fromA]
import B exposing [fromB]
import Tesl.Prelude exposing [Int]
fn main() -> Int =
  fromA() + fromB()
|});
    ("A.tesl", transitive_a_src);
    ("B.tesl", transitive_b_src);
    ("Shared.tesl", transitive_shared_src);
  ] (fun dir ->
    let main = Filename.concat dir "Main.tesl" in
    let code, out = run_compiler ["--deps"; main] in
    check int "exit code" 0 code;
    assert_count ~label:"Shared only once" out "Shared.tesl" 1)

let r40_11_deps_terminates_on_import_cycles () =
  with_temp_project [
    ("Main.tesl", cycle_main_src);
    ("A.tesl", cycle_a_src);
    ("B.tesl", cycle_b_src);
  ] (fun dir ->
    let main = Filename.concat dir "Main.tesl" in
    let code, out = run_compiler ["--deps"; main] in
    check int "exit code" 0 code;
    assert_count ~label:"A only once" out "A.tesl" 1;
    assert_count ~label:"B only once" out "B.tesl" 1)

let r40_12_semantic_json_contains_functions_bindings_expr_types () =
  with_temp_file "tesl-r40-semantic-" ".tesl" semantic_src (fun path ->
    let code, out = run_compiler ["--semantic-json"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"module name" out "\"module_name\":\"Main\"";
    assert_contains ~label:"function name" out "\"functions\":[{\"name\":\"double\"";
    assert_contains ~label:"local binding" out "\"local_bindings\":[{";
    assert_contains ~label:"expr types" out "\"expr_types\":[{")

let r40_13_local_bindings_include_test_block_lets () =
  with_temp_file "tesl-r40-bindings-" ".tesl" test_block_bindings_src (fun path ->
    let code, out = run_compiler ["--local-bindings-json"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"x binding" out "\"name\":\"x\"";
    assert_contains ~label:"y binding" out "\"name\":\"y\"";
    assert_contains ~label:"binding type" out "\"type\":\"Int\"")

let r40_14_fmt_check_rejects_noncanonical_spacing () =
  with_temp_file "tesl-r40-fmt-" ".tesl" lint_warning_src (fun path ->
    let code, out = run_compiler ["--fmt-check"; path] in
    check int "exit code" 1 code;
    assert_contains ~label:"fmt check message" out "not formatted")

let r40_15_fmt_rewrites_and_fmt_check_then_passes () =
  with_temp_file "tesl-r40-fmt-" ".tesl" lint_warning_src (fun path ->
    let fmt_code, fmt_out = run_compiler ["--fmt"; path] in
    check int "fmt exit code" 0 fmt_code;
    check string "fmt stdout" "" fmt_out;
    let formatted = In_channel.with_open_text path In_channel.input_all in
    check string "formatted content"
      "#lang tesl\nmodule Main exposing [value]\nimport Tesl.Prelude exposing [Int]\nfn value() -> Int = 1\n"
      formatted;
    let check_code, check_out = run_compiler ["--fmt-check"; path] in
    check int "fmt-check exit code" 0 check_code;
    check string "fmt-check stdout" "" check_out)

let r40_16_lint_reports_warning_and_fix_payload () =
  with_temp_file "tesl-r40-lint-" ".tesl" lint_warning_src (fun path ->
    let code, out = run_compiler ["--lint"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"warning code" out "warning[W010]";
    assert_contains ~label:"warning message" out "trailing whitespace";
    assert_contains ~label:"warning file" out path)

let r40_17_ts_generator_emits_branded_fact_schema () =
  with_temp_file "tesl-r40-ts-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--generate-ts"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"valid title schema" out
      "export const ValidTitleSchema = z.string().min(3).brand<\"ValidTitle\">();")

let r40_18_ts_generator_preserves_get_response_type () =
  with_temp_file "tesl-r40-ts-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--generate-ts"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"getTodos return type" out "export async function getTodos(): Promise<Array<Todo>>";
    assert_contains ~label:"getTodos parser" out "return z.array(TodoSchema).parse(await res.json()) as Array<Todo>;" )

let r40_19_ts_generator_types_post_body_as_newtodo () =
  with_temp_file "tesl-r40-ts-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--generate-ts"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"postTodos typed body" out "export async function postTodos(todo: NewTodo): Promise<Todo>";
    assert_not_contains ~label:"postTodos should not regress to unknown body" out "export async function postTodos(todo: unknown): Promise<Unit>")

let r40_20_ts_generator_types_post_response_as_todo () =
  with_temp_file "tesl-r40-ts-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--generate-ts"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"postTodos Todo response" out "Promise<Todo>";
    assert_contains ~label:"postTodos Todo parser" out "return TodoSchema.parse(await res.json()) as Todo;";
    assert_not_contains ~label:"postTodos should not parse Unit" out "return UnitSchema.parse(await res.json()) as Unit;" )

let r40_21_elm_generator_preserves_get_response_type () =
  with_temp_file "tesl-r40-elm-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--generate-elm"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"getTodos signature" out "getTodos : (Result Http.Error (List Todo) -> msg) -> Cmd msg";
    assert_contains ~label:"getTodos decoder" out ", expect = Http.expectJson toMsg (D.list todoDecoder)" )

let r40_22_elm_generator_preserves_refinement_surface () =
  with_temp_file "tesl-r40-elm-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--generate-elm"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"refinement-proofs import" out "import RefinementProofs.Theory exposing (Proven, axiom, exorcise, And, and)";
    assert_contains ~label:"NewTodo title proven string" out "type alias NewTodo =\n    { title : Proven String ValidTitle";
    assert_contains ~label:"ValidTitle type emitted" out "type ValidTitle";
    assert_contains ~label:"smart constructor emitted" out "validTitle : String -> Maybe (Proven String ValidTitle)")

let r40_23_elm_generator_uses_encoded_post_body () =
  with_temp_file "tesl-r40-elm-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--generate-elm"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"post body encoder" out ", body = Http.jsonBody (newTodoEncoder todo)";
    assert_not_contains ~label:"post body should not regress to null" out ", body = Http.jsonBody (E.null)")

let r40_24_elm_generator_types_post_response_as_todo () =
  with_temp_file "tesl-r40-elm-" ".tesl" api_src (fun path ->
    let code, out = run_compiler ["--generate-elm"; path] in
    check int "exit code" 0 code;
    assert_contains ~label:"postTodos Todo signature" out "postTodos : NewTodo -> (Result Http.Error Todo -> msg) -> Cmd msg";
    assert_contains ~label:"postTodos Todo decoder" out ", expect = Http.expectJson toMsg todoDecoder";
    assert_not_contains ~label:"postTodos should not regress to Unit signature" out "postTodos : value -> (Result Http.Error Unit -> msg) -> Cmd msg")

let () =
  run "review-40-antagonistic" [
    "ir-and-navigation", [
      test_case "IR preserves GET route shape (R40_01)" `Quick r40_01_ir_get_route_shape_preserved;
      test_case "IR preserves POST body type (R40_02)" `Quick r40_02_ir_post_body_preserves_plain_body_type;
      test_case "IR preserves POST response type (R40_03)" `Quick r40_03_ir_post_response_preserves_todo_type;
      test_case "definition stops at file boundary (R40_04)" `Quick r40_04_definition_stops_at_file_boundary;
      test_case "occurrences stop at file boundary (R40_05)" `Quick r40_05_occurrences_stop_at_file_boundary;
      test_case "type-at works on imported call site (R40_06)" `Quick r40_06_type_at_works_on_imported_call_site;
      test_case "completions include imported helper (R40_07)" `Quick r40_07_completions_include_imported_helper;
      test_case "completions include qualified helper (R40_08)" `Quick r40_08_completions_include_qualified_imported_helper;
    ];
    "deps-and-metadata", [
      test_case "deps list transitive imports (R40_09)" `Quick r40_09_deps_lists_transitive_imports;
      test_case "deps de-dupes shared imports (R40_10)" `Quick r40_10_deps_dedupes_shared_imports;
      test_case "deps terminates on cycles (R40_11)" `Quick r40_11_deps_terminates_on_import_cycles;
      test_case "semantic json carries functions/bindings/types (R40_12)" `Quick r40_12_semantic_json_contains_functions_bindings_expr_types;
      test_case "local-bindings includes test lets (R40_13)" `Quick r40_13_local_bindings_include_test_block_lets;
    ];
    "format-and-lint", [
      test_case "fmt-check rejects non-canonical spacing (R40_14)" `Quick r40_14_fmt_check_rejects_noncanonical_spacing;
      test_case "fmt rewrites and fmt-check passes (R40_15)" `Quick r40_15_fmt_rewrites_and_fmt_check_then_passes;
      test_case "lint reports warning and fix payload (R40_16)" `Quick r40_16_lint_reports_warning_and_fix_payload;
    ];
    "frontend-codegen", [
      test_case "TS emits branded fact schema (R40_17)" `Quick r40_17_ts_generator_emits_branded_fact_schema;
      test_case "TS preserves GET response type (R40_18)" `Quick r40_18_ts_generator_preserves_get_response_type;
      test_case "TS types POST body as NewTodo (R40_19)" `Quick r40_19_ts_generator_types_post_body_as_newtodo;
      test_case "TS types POST response as Todo (R40_20)" `Quick r40_20_ts_generator_types_post_response_as_todo;
      test_case "Elm preserves GET response type (R40_21)" `Quick r40_21_elm_generator_preserves_get_response_type;
      test_case "Elm preserves refinement surface (R40_22)" `Quick r40_22_elm_generator_preserves_refinement_surface;
      test_case "Elm encodes POST body (R40_23)" `Quick r40_23_elm_generator_uses_encoded_post_body;
      test_case "Elm types POST response as Todo (R40_24)" `Quick r40_24_elm_generator_types_post_response_as_todo;
    ];
  ]
