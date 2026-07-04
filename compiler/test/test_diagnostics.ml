(** Diagnostics protocol tests — verify the OCaml compiler emits the
    versioned IR-2 JSON contract used by editor/tooling integrations. *)

open Compile

let contains needle haystack =
  String.length haystack >= String.length needle &&
  let n = String.length needle in
  let m = String.length haystack in
  let found = ref false in
  for i = 0 to m - n do
    if String.sub haystack i n = needle then found := true
  done;
  !found

let assert_contains ~name haystack needle =
  if not (contains needle haystack) then
    Alcotest.failf "%s: expected to find\n  %S\nin:\n%s" name needle haystack


let assert_not_contains ~name haystack needle =
  if contains needle haystack then
    Alcotest.failf "%s: expected NOT to find\n  %S\nin:\n%s" name needle haystack
let require_diag ~name ~source diags =
  match List.find_opt (fun (d : diagnostic) -> d.source = source) diags with
  | Some d -> d
  | None ->
    let sources = String.concat ", " (List.map (fun (d : diagnostic) -> d.source) diags) in
    Alcotest.failf "%s: expected a %s diagnostic, got [%s]" name source sources

let assert_structured_range ~name (d : diagnostic) =
  if d.end_line < d.start_line || (d.end_line = d.start_line && d.end_col < d.start_col) then
    Alcotest.failf
      "%s: invalid range start=(%d,%d) end=(%d,%d)"
      name d.start_line d.start_col d.end_line d.end_col

let write_text_file path contents =
  Out_channel.with_open_text path (fun oc -> output_string oc contents)

let with_temp_file prefix contents f =
  let path = Filename.temp_file prefix ".tesl" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      write_text_file path contents;
      f path)

let compiler_binary () =
  let candidates = [
    "compiler/_build/default/bin/main.exe";
    "_build/default/bin/main.exe";
    let exe_dir = Filename.dirname Sys.executable_name in
    let build_dir = Filename.dirname exe_dir in
    Filename.concat build_dir "bin/main.exe";
  ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "expected compiler binary at one of: %s" (String.concat ", " candidates)

let run_check_json path =
  let binary = compiler_binary () in
  let ic = Unix.open_process_args_in binary [| binary; "--check-json"; path |] in
  let stdout = In_channel.input_all ic in
  let exit_code =
    match Unix.close_process_in ic with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> Alcotest.failf "compiler terminated by signal %d" signal
    | Unix.WSTOPPED signal -> Alcotest.failf "compiler stopped by signal %d" signal
  in
  (exit_code, stdout)

let run_local_bindings_json path =
  let binary = compiler_binary () in
  let ic = Unix.open_process_args_in binary [| binary; "--local-bindings-json"; path |] in
  let stdout = In_channel.input_all ic in
  let exit_code =
    match Unix.close_process_in ic with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> Alcotest.failf "compiler terminated by signal %d" signal
    | Unix.WSTOPPED signal -> Alcotest.failf "compiler stopped by signal %d" signal
  in
  (exit_code, stdout)

let run_definition_json path line col =
  let binary = compiler_binary () in
  let ic = Unix.open_process_args_in binary [| binary; "--definition-json"; path; string_of_int line; string_of_int col |] in
  let stdout = In_channel.input_all ic in
  let exit_code =
    match Unix.close_process_in ic with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> Alcotest.failf "compiler terminated by signal %d" signal
    | Unix.WSTOPPED signal -> Alcotest.failf "compiler stopped by signal %d" signal
  in
  (exit_code, stdout)

let run_occurrences_json path line col =
  let binary = compiler_binary () in
  let ic = Unix.open_process_args_in binary [| binary; "--occurrences-json"; path; string_of_int line; string_of_int col |] in
  let stdout = In_channel.input_all ic in
  let exit_code =
    match Unix.close_process_in ic with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> Alcotest.failf "compiler terminated by signal %d" signal
    | Unix.WSTOPPED signal -> Alcotest.failf "compiler stopped by signal %d" signal
  in
  (exit_code, stdout)

let run_type_at_json path line col =
  let binary = compiler_binary () in
  let ic = Unix.open_process_args_in binary [| binary; "--type-at-json"; path; string_of_int line; string_of_int col |] in
  let stdout = In_channel.input_all ic in
  let exit_code =
    match Unix.close_process_in ic with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> Alcotest.failf "compiler terminated by signal %d" signal
    | Unix.WSTOPPED signal -> Alcotest.failf "compiler stopped by signal %d" signal
  in
  (exit_code, stdout)

let parser_error_src = {|#lang tesl
module Main exposing [value]
value: Int
value = 1
|}

let type_error_src = {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [String]
fn value() -> String = 1
|}

let validation_error_src = {|#lang tesl
module Foo exposing [S]
import Tesl.Prelude exposing [String]
api TaskApi {
  post "/tasks"
    -> String
}
server S for TaskApi {
  createTask = nonExistentHandler
}
|}

let valid_src = {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
fn value() -> Int = 1
|}

let lint_warning_src = "#lang tesl\nmodule Main exposing [value]\nimport Tesl.Prelude exposing [Int]   \nfn value() -> Int = 1\n"

let local_bindings_src = {|#lang tesl
module Main exposing [localLets, value]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn localLets() -> Int =
  let explicit: Int = 1
  let inferred = 2 + 3
  inferred

fn value(input: Maybe Int) -> Int =
  case input of
    Nothing -> 0
    Something matched -> matched
|}

let definition_src = {|#lang tesl
module Main exposing [helper, value]
import Tesl.Prelude exposing [Int]
fn helper(x: Int) -> Int =
  x

fn value() -> Int =
  let local = 1
  helper local
|}

let local_definition_src = {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int]
fn value() -> Int =
  let local = 1
  local
|}

let local_rhs_occurrences_src = {|#lang tesl
module Main exposing [helper, value]
import Tesl.Prelude exposing [Int]
fn helper(x: Int) -> Int =
  x
fn value() -> Int =
  let alias = helper 1
  alias
|}

(* T1 (2026-07-04): a `#>` doctest snippet is parsed with snippet-LOCAL locs
   (line 0).  If its occurrences are collected, an LSP rename of the doctested
   symbol writes a corrupting edit at line 0.  This fixture references `triple`
   from a `#> triple 5` doctest; occurrence collection must yield only the real
   def + call-site positions, never a line-0 edit. *)
let doctest_occurrences_src = {|#lang tesl
module Main exposing [triple, caller]
import Tesl.Prelude exposing [Int]
#> triple 5
#= 15
fn triple(n: Int) -> Int =
  n + n + n
fn caller() -> Int =
  triple 4
|}

let codec_via_occurrences_src = {|#lang tesl
module Main exposing [Msg, nonEmpty]
import Tesl.Prelude exposing [Int, String, Bool, List, Fact, detachFact]
import Tesl.Json exposing [stringCodec, intCodec, boolCodec, floatCodec, posixMillisCodec]
check nonEmpty(s: String) -> s: String ::: NonEmpty s =
  if s == "" then
    fail 400 "empty string"
  else
    ok s ::: NonEmpty s
record Msg {
  content: String ::: NonEmpty content
}
codec Msg {
  toJson {
    content -> "content" with_codec stringCodec
  }
  fromJson [
    {
      content <- "content" with_codec stringCodec via nonEmpty
    }
  ]
}
|}

let codec_unknown_type_src = {|#lang tesl
module Main exposing [Missing]
codec Missing {
  toJson_forbidden
  fromJson_forbidden
}
|}

let refined_case_bindings_src = {|#lang tesl
module Main exposing [cookieAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]

auth cookieAuth(request: HttpRequest) -> user: String::: Authenticated user
  requires [] =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "not logged in"
    Something userId -> ok userId::: Authenticated user
|}

let guarded_case_bindings_src = {|#lang tesl
module Main exposing [ownerOnly]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]

record Note {
  id: String
  authorId: String
}

fn ownerOnly(user: String, existing: Maybe Note) -> String =
  case existing of
    Nothing -> "missing"
    Something note where note.authorId != user -> "forbidden"
    Something _ -> "ok"
|}

let proof_local_bindings_src = {|#lang tesl
module Main exposing [shouldWork]
import Tesl.Prelude exposing [Int, detachFact]

check checkPositiveInt(value: Int) -> value: Int::: IsPositive value =
  ok value::: IsPositive value

check checkPriceExceedsQuantity(price: Int, quantity: Int) -> price: Int::: PriceExceedsQuantity price quantity =
  ok price::: PriceExceedsQuantity price quantity

fn shouldWork(quantity: Int) -> Int =
  let p = checkPositiveInt 10
  let pq = checkPriceExceedsQuantity p quantity
  let proodd = detachFact pq
  let (_ ::: xProof2) = pq
  p
|}

let test_parser_diagnostic_json_contract () =
  let filename = "/tmp/parser-contract.tesl" in
  let diags = check_source filename parser_error_src in
  let d = require_diag ~name:"parser contract" ~source:"parser" diags in
  Alcotest.(check string) "parser code" "E000" d.code;
  Alcotest.(check string) "parser severity" "error" d.severity;
  assert_structured_range ~name:"parser contract" d;
  let json = diagnostics_to_json diags in
  assert_contains ~name:"parser json version" json "\"version\":1";
  assert_contains ~name:"parser json file" json filename;
  assert_contains ~name:"parser json source" json "\"source\":\"parser\"";
  assert_contains ~name:"parser json code" json "\"code\":\"E000\"";
  assert_contains ~name:"parser json fix" json "\"fix\":null"

let test_type_diagnostic_json_contract () =
  let diags = check_source "/tmp/type-contract.tesl" type_error_src in
  let d = require_diag ~name:"type contract" ~source:"type-checker" diags in
  Alcotest.(check string) "type code" "T001" d.code;
  Alcotest.(check string) "type severity" "error" d.severity;
  assert_structured_range ~name:"type contract" d;
  let json = diagnostics_to_json diags in
  assert_contains ~name:"type json source" json "\"source\":\"type-checker\"";
  assert_contains ~name:"type json code" json "\"code\":\"T001\""

let test_validation_diagnostic_json_contract () =
  let diags = check_source "/tmp/validation-contract.tesl" validation_error_src in
  let d = require_diag ~name:"validation contract" ~source:"validation" diags in
  Alcotest.(check string) "validation code" "V001" d.code;
  Alcotest.(check string) "validation severity" "error" d.severity;
  assert_structured_range ~name:"validation contract" d;
  let json = diagnostics_to_json diags in
  assert_contains ~name:"validation json source" json "\"source\":\"validation\"";
  assert_contains ~name:"validation json code" json "\"code\":\"V001\""

let argument_locality_src = {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int, String]
fn takesInt(x: Int) -> Int =
  x
fn value() -> Int =
  takesInt "oops"
|}

let test_type_diagnostic_argument_locality () =
  let diags = check_source "/tmp/type-arg-locality.tesl" argument_locality_src in
  let d = require_diag ~name:"type arg locality" ~source:"type-checker" diags in
  Alcotest.(check int) "argument line" 6 d.start_line;
  assert_contains ~name:"argument reason" d.message "argument 1 to `takesInt`"

let local_let_locality_src = {|#lang tesl
module Main exposing [value, formatPublishedAt]
import Tesl.Prelude exposing [Int, String]
fn formatPublishedAt(ts: Int) -> String =
  "formatted"
fn value() -> Int =
  let formatted: Int = formatPublishedAt 0
  1
|}

let test_type_diagnostic_local_let_locality () =
  let diags = check_source "/tmp/type-let-locality.tesl" local_let_locality_src in
  let d = require_diag ~name:"type let locality" ~source:"type-checker" diags in
  Alcotest.(check int) "local let line" 6 d.start_line;
  assert_contains ~name:"local let reason" d.message "let binding `formatted` must have declared type Int"

let constructor_argument_locality_src = {|#lang tesl
module Main exposing [value]
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn value() -> Maybe Int =
  Something "oops"
|}

let test_type_diagnostic_constructor_argument_locality () =
  let diags = check_source "/tmp/type-constructor-arg-locality.tesl" constructor_argument_locality_src in
  let d = require_diag ~name:"constructor arg locality" ~source:"type-checker" diags in
  Alcotest.(check int) "constructor argument line" 5 d.start_line;
  assert_contains ~name:"constructor argument reason" d.message "argument 1 of constructor `Something`";
  assert_contains ~name:"constructor outer reason" d.message "body of `value` must have type Maybe Int";
  assert_contains ~name:"constructor expectation chain" d.message "Expectation chain:"

let test_cli_check_json_success_contract () =
  with_temp_file "tesl-check-json-ok-" valid_src (fun path ->
    let exit_code, stdout = run_check_json path in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"cli success version" stdout "\"version\":1";
    assert_contains ~name:"cli success diagnostics" stdout "\"diagnostics\":[]")

let test_cli_check_json_parser_contract () =
  with_temp_file "tesl-check-json-parser-" parser_error_src (fun path ->
    let exit_code, stdout = run_check_json path in
    Alcotest.(check int) "exit code" 1 exit_code;
    assert_contains ~name:"cli parser version" stdout "\"version\":1";
    assert_contains ~name:"cli parser file" stdout path;
    assert_contains ~name:"cli parser source" stdout "\"source\":\"parser\"";
    assert_contains ~name:"cli parser code" stdout "\"code\":\"E000\"";
    assert_contains ~name:"cli parser fix" stdout "\"fix\":null";
    assert_not_contains ~name:"cli parser omits lint noise" stdout "\"source\":\"lint\"")

let test_cli_check_json_includes_lint_warning () =
  with_temp_file "tesl-check-json-lint-" lint_warning_src (fun path ->
    let exit_code, stdout = run_check_json path in
    (* 2026-07-03: --check-json exits non-zero IFF an ERROR-severity diagnostic is
       present (the documented AGENTS.md contract, matching `agent-context`), so a
       WARNING-only file exits 0.  The warning is still emitted in the JSON
       (asserted below); only the exit code changed from the old "any diagnostic
       → 1" behaviour, which reddened warning-only files in CI/editors. *)
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"cli lint version" stdout "\"version\":1";
    assert_contains ~name:"cli lint file" stdout path;
    assert_contains ~name:"cli lint source" stdout "\"source\":\"lint\"";
    assert_contains ~name:"cli lint code" stdout "\"code\":\"W010\"";
    assert_contains ~name:"cli lint severity" stdout "\"severity\":\"warning\"";
    assert_contains ~name:"cli lint fix kind" stdout "\"fix\":{\"kind\":\"replace_line\"";
    assert_contains ~name:"cli lint fix line" stdout "\"line\":2";
    assert_contains ~name:"cli lint fix replacement" stdout "\"replacement\":\"import Tesl.Prelude exposing [Int]\"")

let test_cli_check_json_codec_unknown_type_contract () =
  with_temp_file "tesl-check-json-codec-unknown-type-" codec_unknown_type_src (fun path ->
    let exit_code, stdout = run_check_json path in
    Alcotest.(check int) "exit code" 1 exit_code;
    assert_contains ~name:"codec unknown type version" stdout "\"version\":1";
    assert_contains ~name:"codec unknown type file" stdout path;
    assert_contains ~name:"codec unknown type message" stdout "codec 'Missing' refers to unknown type 'Missing'")

let test_cli_local_bindings_json_contract () =
  with_temp_file "tesl-local-bindings-ok-" local_bindings_src (fun path ->
    let exit_code, stdout = run_local_bindings_json path in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"local bindings version" stdout "\"version\":1";
    assert_contains ~name:"local bindings field" stdout "\"bindings\":[";
    assert_contains ~name:"parameter binding name" stdout "\"name\":\"input\"";
    assert_contains ~name:"parameter binding type" stdout "\"type\":\"Maybe Int\"";
    assert_contains ~name:"case binding name" stdout "\"name\":\"matched\"";
    assert_contains ~name:"case binding type" stdout "\"type\":\"Int\"";
    assert_contains ~name:"explicit binding name" stdout "\"name\":\"explicit\"";
    assert_contains ~name:"explicit binding type" stdout "\"type\":\"Int\"";
    assert_contains ~name:"inferred binding name" stdout "\"name\":\"inferred\"")

let test_cli_local_bindings_json_refined_case_contract () =
  with_temp_file "tesl-local-bindings-refined-case-" refined_case_bindings_src (fun path ->
    let exit_code, stdout = run_local_bindings_json path in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"refined case binding name" stdout "\"name\":\"userId\"";
    assert_contains ~name:"refined case binding type" stdout "\"type\":\"String\"")

let test_cli_local_bindings_json_guarded_case_contract () =
  with_temp_file "tesl-local-bindings-guarded-case-" guarded_case_bindings_src (fun path ->
    let exit_code, stdout = run_local_bindings_json path in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"guarded case binding name" stdout "\"name\":\"note\"";
    assert_contains ~name:"guarded case binding type" stdout "\"type\":\"Note\"")

let test_cli_local_bindings_json_proof_contract () =
  with_temp_file "tesl-local-bindings-proof-" proof_local_bindings_src (fun path ->
    let exit_code, stdout = run_local_bindings_json path in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"proof local p" stdout "\"name\":\"p\"";
    assert_contains ~name:"proof local p type" stdout "\"type\":\"Int ::: IsPositive p\"";
    assert_contains ~name:"proof local pq" stdout "\"name\":\"pq\"";
    assert_contains ~name:"proof local pq type" stdout "\"type\":\"Int ::: PriceExceedsQuantity pq quantity\"";
    assert_contains ~name:"proof local pq note" stdout "\"note\":\"subjects: pq; quantity\"";
    assert_contains ~name:"proof local proodd" stdout "\"name\":\"proodd\"";
    assert_contains ~name:"proof local proodd type" stdout "\"type\":\"Fact (PriceExceedsQuantity pq quantity)\"";
    assert_contains ~name:"proof local proodd note" stdout "\"note\":\"fact subjects: pq; quantity\"";
    assert_contains ~name:"proof local xProof2" stdout "\"name\":\"xProof2\"";
    assert_contains ~name:"proof local xProof2 type" stdout "\"type\":\"Fact (PriceExceedsQuantity pq quantity)\"";
    assert_contains ~name:"proof local xProof2 note" stdout "\"note\":\"fact subjects: pq; quantity\"")

let test_cli_local_bindings_json_parser_contract () =
  with_temp_file "tesl-local-bindings-parser-" parser_error_src (fun path ->
    let exit_code, stdout = run_local_bindings_json path in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"local bindings parser version" stdout "\"version\":1";
    assert_contains ~name:"local bindings parser empty" stdout "\"bindings\":[]")


let test_cli_definition_json_top_level_contract () =
  with_temp_file "tesl-definition-top-level-" definition_src (fun path ->
    let exit_code, stdout = run_definition_json path 8 2 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"definition version" stdout "\"version\":1";
    assert_contains ~name:"definition file" stdout path;
    assert_contains ~name:"definition line" stdout "\"line\":3";
    assert_contains ~name:"definition col" stdout "\"col\":3")

let test_cli_definition_json_local_contract () =
  with_temp_file "tesl-definition-local-" local_definition_src (fun path ->
    let exit_code, stdout = run_definition_json path 5 2 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"local definition version" stdout "\"version\":1";
    assert_contains ~name:"local definition file" stdout path;
    assert_contains ~name:"local definition line" stdout "\"line\":4")

let test_cli_definition_json_parser_contract () =
  with_temp_file "tesl-definition-parser-" parser_error_src (fun path ->
    let exit_code, stdout = run_definition_json path 2 0 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"definition parser version" stdout "\"version\":1";
    assert_contains ~name:"definition parser null" stdout "\"definition\":null")

let test_cli_occurrences_json_top_level_contract () =
  with_temp_file "tesl-occurrences-top-level-" definition_src (fun path ->
    let exit_code, stdout = run_occurrences_json path 8 2 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"occurrences version" stdout "\"version\":1";
    assert_contains ~name:"occurrences field" stdout "\"occurrences\":[";
    assert_contains ~name:"occurrences file" stdout path;
    assert_contains ~name:"occurrences helper def line" stdout "\"line\":3";
    assert_contains ~name:"occurrences helper use line" stdout "\"line\":8")

let test_cli_occurrences_json_doctest_no_line0 () =
  with_temp_file "tesl-occurrences-doctest-" doctest_occurrences_src (fun path ->
    (* query `triple` at its definition (0-based line 5, col 3) *)
    let exit_code, stdout = run_occurrences_json path 5 3 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"doctest occ: def" stdout "\"line\":5,\"col\":3";
    assert_contains ~name:"doctest occ: call site" stdout "\"line\":8,\"col\":2";
    (* T1 regression: the `#> triple 5` doctest must NOT contribute a line-0
       occurrence (LSP rename would corrupt line 0). *)
    let has_line0 =
      try ignore (Str.search_forward (Str.regexp_string "\"line\":0") stdout 0); true
      with Not_found -> false
    in
    if has_line0 then
      Alcotest.failf "doctest produced a corrupting line-0 occurrence:\n%s" stdout)

let test_cli_occurrences_json_local_contract () =
  with_temp_file "tesl-occurrences-local-" local_definition_src (fun path ->
    let exit_code, stdout = run_occurrences_json path 5 2 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"local occurrences version" stdout "\"version\":1";
    assert_contains ~name:"local occurrences def line" stdout "\"line\":4";
    assert_contains ~name:"local occurrences def precise col" stdout "\"line\":4,\"col\":6,\"end_line\":4,\"end_col\":11";
    assert_contains ~name:"local occurrences use line" stdout "\"line\":5")

let test_cli_occurrences_json_precise_top_level_range_contract () =
  with_temp_file "tesl-occurrences-precise-top-level-" definition_src (fun path ->
    let exit_code, stdout = run_occurrences_json path 8 2 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"top-level precise def range" stdout "\"line\":3,\"col\":3,\"end_line\":3,\"end_col\":9";
    assert_contains ~name:"top-level precise use range" stdout "\"line\":8,\"col\":2,\"end_line\":8,\"end_col\":8")

let test_cli_occurrences_json_rhs_picks_called_symbol_contract () =
  with_temp_file "tesl-occurrences-rhs-" local_rhs_occurrences_src (fun path ->
    let exit_code, stdout = run_occurrences_json path 6 14 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"rhs occurrences helper def range" stdout "\"line\":3,\"col\":3,\"end_line\":3,\"end_col\":9";
    assert_contains ~name:"rhs occurrences helper use range" stdout "\"line\":6,\"col\":14,\"end_line\":6,\"end_col\":20";
    assert_not_contains ~name:"rhs occurrences should not hit let binding" stdout "\"line\":6,\"col\":6,\"end_line\":6,\"end_col\":11")

let test_cli_occurrences_json_codec_via_precise_range_contract () =
  with_temp_file "tesl-occurrences-codec-via-" codec_via_occurrences_src (fun path ->
    let exit_code, stdout = run_occurrences_json path 18 55 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"codec via declaration range" stdout "\"line\":4,\"col\":6,\"end_line\":4,\"end_col\":14";
    assert_contains ~name:"codec via use range" stdout "\"line\":18,\"col\":54,\"end_line\":18,\"end_col\":62";
    assert_not_contains ~name:"codec via should not return whole codec block" stdout "\"line\":12,\"col\":10,\"end_line\":21,\"end_col\":2")

let test_cli_occurrences_json_parser_contract () =
  with_temp_file "tesl-occurrences-parser-" parser_error_src (fun path ->
    let exit_code, stdout = run_occurrences_json path 2 0 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"occurrences parser version" stdout "\"version\":1";
    assert_contains ~name:"occurrences parser empty" stdout "\"occurrences\":[]")

let test_cli_type_at_json_top_level_contract () =
  with_temp_file "tesl-type-at-top-level-" definition_src (fun path ->
    let exit_code, stdout = run_type_at_json path 8 2 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"type_at version" stdout "\"version\":1";
    assert_contains ~name:"type_at field" stdout "\"type_at\":{";
    assert_contains ~name:"type_at file" stdout path;
    assert_contains ~name:"type_at helper use line" stdout "\"line\":8";
    assert_contains ~name:"type_at helper type" stdout "\"type\":\"Int -> Int\"")

let test_cli_type_at_json_local_contract () =
  with_temp_file "tesl-type-at-local-" local_definition_src (fun path ->
    let exit_code, stdout = run_type_at_json path 5 2 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"local type_at version" stdout "\"version\":1";
    assert_contains ~name:"local type_at line" stdout "\"line\":5";
    assert_contains ~name:"local type_at type" stdout "\"type\":\"Int\"")

let test_cli_type_at_json_parser_contract () =
  with_temp_file "tesl-type-at-parser-" parser_error_src (fun path ->
    let exit_code, stdout = run_type_at_json path 2 0 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"type_at parser version" stdout "\"version\":1";
    assert_contains ~name:"type_at parser null" stdout "\"type_at\":null")

let field_at_src = {|#lang tesl
module M exposing [getName]
import Tesl.Prelude exposing [String, Int]

record User {
  name: String
  age: Int
}

fn getName(u: User) -> String = u.name
|}

let run_field_at_json path line col =
  let binary = compiler_binary () in
  let ic = Unix.open_process_args_in binary [| binary; "--field-at-json"; path; string_of_int line; string_of_int col |] in
  let stdout = In_channel.input_all ic in
  let exit_code =
    match Unix.close_process_in ic with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> Alcotest.failf "compiler terminated by signal %d" signal
    | Unix.WSTOPPED signal -> Alcotest.failf "compiler stopped by signal %d" signal
  in
  (exit_code, stdout)

let run_completions_json path line col =
  let binary = compiler_binary () in
  let ic = Unix.open_process_args_in binary [| binary; "--completions-json"; path; string_of_int line; string_of_int col |] in
  let stdout = In_channel.input_all ic in
  let exit_code =
    match Unix.close_process_in ic with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> Alcotest.failf "compiler terminated by signal %d" signal
    | Unix.WSTOPPED signal -> Alcotest.failf "compiler stopped by signal %d" signal
  in
  (exit_code, stdout)

(* field_at_src: u.name is on line 9 (0-based).
   fn getName(u: User) -> String = u.name
   Col: u=32, .=33, name starts at 34, stop at 38.
   EField loc spans [33, 38), so cursor at col 34 hits it. *)

let test_cli_field_at_json_contract () =
  with_temp_file "tesl-field-at-" field_at_src (fun path ->
    let exit_code, stdout = run_field_at_json path 9 34 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"field_at version" stdout "\"version\":1";
    assert_contains ~name:"field_at object present" stdout "\"field_at\":{";
    assert_contains ~name:"field_at field name" stdout "\"field\":\"name\"";
    assert_contains ~name:"field_at record type" stdout "\"record_type\":\"User\"";
    assert_contains ~name:"field_at field type" stdout "\"field_type\":\"String\"")

let test_cli_field_at_json_null_contract () =
  with_temp_file "tesl-field-at-null-" field_at_src (fun path ->
    (* cursor on `u` before the dot (col 32) — outside EField loc [33,38) *)
    let exit_code, stdout = run_field_at_json path 9 32 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"field_at null version" stdout "\"version\":1";
    assert_contains ~name:"field_at null result" stdout "\"field_at\":null")

let test_cli_completions_json_field_contract () =
  with_temp_file "tesl-completions-field-" field_at_src (fun path ->
    (* cursor at col 34, char at col 33 is '.', triggers dot completion *)
    let exit_code, stdout = run_completions_json path 9 34 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"completions version" stdout "\"version\":1";
    assert_contains ~name:"completions array" stdout "\"completions\":[";
    assert_contains ~name:"completions name field" stdout "\"label\":\"name\"";
    assert_contains ~name:"completions age field" stdout "\"label\":\"age\"";
    assert_contains ~name:"completions field kind" stdout "\"kind\":\"field\"")

let test_cli_completions_json_general_contract () =
  with_temp_file "tesl-completions-general-" field_at_src (fun path ->
    (* cursor at col 3 on line 9, not after a dot *)
    let exit_code, stdout = run_completions_json path 9 3 in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"general completions version" stdout "\"version\":1";
    assert_contains ~name:"general completions array" stdout "\"completions\":[";
    assert_contains ~name:"general completions getName" stdout "\"label\":\"getName\"")

let () =
  Alcotest.run "Diagnostics" [
    "contract", [
      Alcotest.test_case "parser diagnostic json" `Quick test_parser_diagnostic_json_contract;
      Alcotest.test_case "type diagnostic json" `Quick test_type_diagnostic_json_contract;
      Alcotest.test_case "type diagnostic argument locality" `Quick test_type_diagnostic_argument_locality;
      Alcotest.test_case "type diagnostic local let locality" `Quick test_type_diagnostic_local_let_locality;
      Alcotest.test_case "type diagnostic constructor argument locality" `Quick test_type_diagnostic_constructor_argument_locality;
      Alcotest.test_case "validation diagnostic json" `Quick test_validation_diagnostic_json_contract;
      Alcotest.test_case "cli check-json success" `Quick test_cli_check_json_success_contract;
      Alcotest.test_case "cli check-json parser failure" `Quick test_cli_check_json_parser_contract;
      Alcotest.test_case "cli check-json includes lint warning" `Quick test_cli_check_json_includes_lint_warning;
      Alcotest.test_case "cli check-json codec unknown type" `Quick test_cli_check_json_codec_unknown_type_contract;
      Alcotest.test_case "cli local-bindings success" `Quick test_cli_local_bindings_json_contract;
      Alcotest.test_case "cli local-bindings refined case" `Quick test_cli_local_bindings_json_refined_case_contract;
      Alcotest.test_case "cli local-bindings guarded case" `Quick test_cli_local_bindings_json_guarded_case_contract;
      Alcotest.test_case "cli local-bindings proof locals" `Quick test_cli_local_bindings_json_proof_contract;
      Alcotest.test_case "cli local-bindings parser failure" `Quick test_cli_local_bindings_json_parser_contract;
      Alcotest.test_case "cli definition top-level" `Quick test_cli_definition_json_top_level_contract;
      Alcotest.test_case "cli definition local" `Quick test_cli_definition_json_local_contract;
      Alcotest.test_case "cli definition parser failure" `Quick test_cli_definition_json_parser_contract;
      Alcotest.test_case "cli occurrences top-level" `Quick test_cli_occurrences_json_top_level_contract;
      Alcotest.test_case "cli occurrences local" `Quick test_cli_occurrences_json_local_contract;
      Alcotest.test_case "cli occurrences doctest no line-0 (T1)" `Quick test_cli_occurrences_json_doctest_no_line0;
      Alcotest.test_case "cli occurrences precise top-level range" `Quick test_cli_occurrences_json_precise_top_level_range_contract;
      Alcotest.test_case "cli occurrences rhs picks called symbol" `Quick test_cli_occurrences_json_rhs_picks_called_symbol_contract;
      Alcotest.test_case "cli occurrences codec via precise range" `Quick test_cli_occurrences_json_codec_via_precise_range_contract;
      Alcotest.test_case "cli occurrences parser failure" `Quick test_cli_occurrences_json_parser_contract;
      Alcotest.test_case "cli type_at top-level" `Quick test_cli_type_at_json_top_level_contract;
      Alcotest.test_case "cli type_at local" `Quick test_cli_type_at_json_local_contract;
      Alcotest.test_case "cli type_at parser failure" `Quick test_cli_type_at_json_parser_contract;
      Alcotest.test_case "cli field_at hit" `Quick test_cli_field_at_json_contract;
      Alcotest.test_case "cli field_at miss" `Quick test_cli_field_at_json_null_contract;
      Alcotest.test_case "cli completions field" `Quick test_cli_completions_json_field_contract;
      Alcotest.test_case "cli completions general" `Quick test_cli_completions_json_general_contract;
    ];
  ]
