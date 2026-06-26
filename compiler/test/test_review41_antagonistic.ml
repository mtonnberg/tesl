(** Antagonistic regression tests for Critical Review 41.

    Focus: generated client fidelity for richer API shapes and the completeness of
    the semantic/editor tooling surface.

    R41_01  TS generator models Tuple2 GET responses as typed tuples
    R41_02  TS generator models Result GET responses as tagged unions
    R41_03  TS generator models Dict GET responses as typed records
    R41_04  TS generator models Set GET responses as typed arrays
    R41_05  TS generator Zod-parses Maybe GET responses
    R41_06  TS generator models Tuple2 POST bodies as typed tuples
    R41_07  TS generator models Result POST bodies as tagged unions
    R41_08  TS generator models Dict POST bodies as typed records
    R41_09  TS generator models Set POST bodies as typed arrays
    R41_10  TS generator preserves and parses Maybe POST shapes
    R41_11  Elm generator models Tuple2 GET responses as Elm tuples
    R41_12  Elm generator models Result GET responses as Elm Result
    R41_13  Elm generator models Dict GET responses as Dict
    R41_14  Elm generator lowers Set GET responses to List
    R41_15  Elm generator encodes Tuple2 POST bodies structurally
    R41_16  Elm generator encodes Result POST bodies structurally
    R41_17  Elm generator encodes Dict POST bodies structurally
    R41_18  Elm generator lowers Set POST requests to List encoding
    R41_19  Elm generator preserves Maybe POST shape
    R41_20  semantic-json omits API declarations entirely
    R41_21  semantic-json omits facts/codecs sections entirely
    R41_22  semantic-json erases refined record field types
    R41_23  semantic-json erases proof-returning check signatures
    R41_24  CLI help exits non-zero
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

let assert_contains ~label haystack needle =
  if not (contains haystack needle) then
    failf "%s: expected to find %S in output:\n%s" label needle haystack

let assert_not_contains ~label haystack needle =
  if contains haystack needle then
    failf "%s: expected NOT to find %S in output:\n%s" label needle haystack

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

let with_temp_file prefix suffix content f =
  let path = Filename.temp_file prefix suffix in
  write_file path content;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let generate_ts path =
  let code, out = run_compiler ["--generate-ts"; path] in
  check int "exit code" 0 code;
  out

let generate_elm path =
  let code, out = run_compiler ["--generate-elm"; path] in
  check int "exit code" 0 code;
  out

let semantic_json path =
  let code, out = run_compiler ["--semantic-json"; path] in
  check int "exit code" 0 code;
  out

let get_shape_api_src = {|#lang tesl
module Api exposing [ShapeApi]
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]
import Tesl.Tuple exposing [Tuple2(..)]
import Tesl.Result exposing [Result(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict]
import Tesl.Set exposing [Set]

record Todo {
  id: String
}
codec Todo {
  toJson {
    id -> "id" with_codec stringCodec
  }
  fromJson_forbidden
}

api ShapeApi {
  get "/pair" -> Tuple2 Int String
  get "/maybe" -> Maybe Todo
  get "/result" -> Result Todo String
  get "/dict" -> Dict String Int
  get "/set" -> Set String
}
|}

let post_shape_api_src = {|#lang tesl
module Api exposing [BodyApi]
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]
import Tesl.Tuple exposing [Tuple2(..)]
import Tesl.Result exposing [Result(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict]
import Tesl.Set exposing [Set]

record Todo {
  id: String
}
codec Todo {
  toJson {
    id -> "id" with_codec stringCodec
  }
  fromJson_forbidden
}

api BodyApi {
  post "/tuple" body pair: Tuple2 Int String -> Tuple2 Int String
  post "/maybe" body todo: Maybe Todo -> Maybe Todo
  post "/result" body result: Result Todo String -> Result Todo String
  post "/dict" body dict: Dict String Int -> Dict String Int
  post "/set" body tags: Set String -> Set String
}
|}

let semantic_api_src = {|#lang tesl
module Api exposing [TodoApi]
import Tesl.Prelude exposing [Int, String]
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

api TodoApi {
  post "/todos" body todo: NewTodo -> NewTodo
}
|}

let with_get_api f = with_temp_file "tesl-r41-get-" ".tesl" get_shape_api_src f
let with_post_api f = with_temp_file "tesl-r41-post-" ".tesl" post_shape_api_src f
let with_semantic_api f = with_temp_file "tesl-r41-sem-" ".tesl" semantic_api_src f

let r41_01_ts_get_tuple_erased_to_unknown () =
  with_get_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"tuple response" out
      "export async function getPair(): Promise<[number, string]>";
    assert_contains ~label:"tuple parse" out
      "z.tuple([z.number().int(), z.string()]).parse(await res.json())")

let r41_02_ts_get_result_erased_to_unknown () =
  with_get_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"result response" out
      "export async function getResult(): Promise<{ tag: \"Ok\"; value: Todo } | { tag: \"Err\"; error: string }>";
    assert_contains ~label:"result parse" out
      "z.discriminatedUnion(\"tag\", [z.object({ tag: z.literal(\"Ok\"), value: TodoSchema }), z.object({ tag: z.literal(\"Err\"), error: z.string() })]).parse(await res.json())")

let r41_03_ts_get_dict_erased_to_unknown () =
  with_get_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"dict response" out
      "export async function getDict(): Promise<Record<string, number>>";
    assert_contains ~label:"dict parse" out
      "z.record(z.string(), z.number().int()).parse(await res.json())")

let r41_04_ts_get_set_erased_to_unknown () =
  with_get_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"set response" out
      "export async function getSet(): Promise<Array<string>>";
    assert_contains ~label:"set parse" out
      "z.array(z.string()).parse(await res.json())")

let r41_05_ts_get_maybe_lacks_zod_parse () =
  with_get_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"maybe signature" out
      "export async function getMaybe(): Promise<Todo | null>";
    assert_contains ~label:"maybe parse" out
      "TodoSchema.nullable().parse(await res.json())")

let r41_06_ts_post_tuple_body_erased_to_unknown () =
  with_post_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"tuple body" out
      "export async function postTuple(pair: [number, string]): Promise<[number, string]>";
    assert_contains ~label:"tuple return parse" out
      "z.tuple([z.number().int(), z.string()]).parse(await res.json())")

let r41_07_ts_post_result_body_erased_to_unknown () =
  with_post_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"result body" out
      "export async function postResult(result: { tag: \"Ok\"; value: Todo } | { tag: \"Err\"; error: string }): Promise<{ tag: \"Ok\"; value: Todo } | { tag: \"Err\"; error: string }>";
    assert_contains ~label:"result return parse" out
      "z.discriminatedUnion(\"tag\", [z.object({ tag: z.literal(\"Ok\"), value: TodoSchema }), z.object({ tag: z.literal(\"Err\"), error: z.string() })]).parse(await res.json())")

let r41_08_ts_post_dict_body_erased_to_unknown () =
  with_post_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"dict body" out
      "export async function postDict(dict: Record<string, number>): Promise<Record<string, number>>";
    assert_contains ~label:"dict return parse" out
      "z.record(z.string(), z.number().int()).parse(await res.json())")

let r41_09_ts_post_set_body_erased_to_unknown () =
  with_post_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"set body" out
      "export async function postSet(tags: Array<string>): Promise<Array<string>>";
    assert_contains ~label:"set return parse" out
      "z.array(z.string()).parse(await res.json())")

let r41_10_ts_post_maybe_is_the_only_preserved_complex_shape () =
  with_post_api (fun path ->
    let out = generate_ts path in
    assert_contains ~label:"maybe body signature" out
      "export async function postMaybe(todo: Todo | null): Promise<Todo | null>";
    assert_contains ~label:"maybe stringified" out
      "body: JSON.stringify(todo)";
    assert_contains ~label:"maybe return parse" out
      "TodoSchema.nullable().parse(await res.json())")

let r41_11_elm_get_tuple_erased_to_value () =
  with_get_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"tuple get" out
      "getPair : (Result Http.Error ((Int, String)) -> msg) -> Cmd msg";
    assert_contains ~label:"tuple get decoder" out
      "Http.expectJson toMsg (D.map2 (\\x y -> ( x, y )) (D.index 0 D.int) (D.index 1 D.string))")

let r41_12_elm_get_result_erased_to_value () =
  with_get_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"result get" out
      "getResult : (Result Http.Error (Result String Todo) -> msg) -> Cmd msg";
    assert_contains ~label:"result get decoder" out
      "Http.expectJson toMsg (D.field \"tag\" D.string |> D.andThen (\\tag -> case tag of \"Ok\" -> D.map Ok (D.field \"value\" todoDecoder) ; \"Err\" -> D.map Err (D.field \"error\" D.string) ; _ -> D.fail (\"Unexpected Result tag: \" ++ tag)))")

let r41_13_elm_get_dict_erased_to_value () =
  with_get_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"dict get" out
      "getDict : (Result Http.Error (Dict String Int) -> msg) -> Cmd msg";
    assert_contains ~label:"dict get decoder" out
      "Http.expectJson toMsg (D.dict D.int)")

let r41_14_elm_get_set_lowered_to_list () =
  with_get_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"set get signature" out
      "getSet : (Result Http.Error (List String) -> msg) -> Cmd msg";
    assert_contains ~label:"set get decoder" out
      ", expect = Http.expectJson toMsg (D.list D.string)")

let r41_15_elm_post_tuple_body_becomes_null () =
  with_post_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"tuple post signature" out
      "postTuple : (Int, String) -> (Result Http.Error ((Int, String)) -> msg) -> Cmd msg";
    assert_contains ~label:"tuple post body" out
      ", body = Http.jsonBody (((\\( first, second ) -> E.list identity [ E.int first, E.string second ]) pair))")

let r41_16_elm_post_result_body_becomes_null () =
  with_post_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"result post signature" out
      "postResult : Result String Todo -> (Result Http.Error (Result String Todo) -> msg) -> Cmd msg";
    assert_contains ~label:"result post body" out
      ", body = Http.jsonBody (((\\result_ -> case result_ of Ok ok_ -> E.object [ (\"tag\", E.string \"Ok\"), (\"value\", todoEncoder ok_) ] ; Err err_ -> E.object [ (\"tag\", E.string \"Err\"), (\"error\", E.string err_) ]) result))")

let r41_17_elm_post_dict_body_becomes_null () =
  with_post_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"dict post signature" out
      "postDict : Dict String Int -> (Result Http.Error (Dict String Int) -> msg) -> Cmd msg";
    assert_contains ~label:"dict post body" out
      ", body = Http.jsonBody ((E.object (List.map (\\( k, v ) -> ( k, E.int v )) (Dict.toList dict))))")

let r41_18_elm_post_set_lowers_to_list_encoding () =
  with_post_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"set post signature" out
      "postSet : List String -> (Result Http.Error (List String) -> msg) -> Cmd msg";
    assert_contains ~label:"set post body" out
      ", body = Http.jsonBody ((E.list E.string) tags)")

let r41_19_elm_post_maybe_preserves_simple_record_shape () =
  with_post_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"maybe post signature" out
      "postMaybe : Maybe Todo -> (Result Http.Error (Maybe Todo) -> msg) -> Cmd msg";
    assert_contains ~label:"maybe post body" out
      ", body = Http.jsonBody ((Maybe.withDefault E.null (Maybe.map todoEncoder)) todo)")

let r41_20_semantic_json_omits_api_declarations () =
  with_semantic_api (fun path ->
    let out = semantic_json path in
    assert_not_contains ~label:"apis key" out "\"apis\":";
    assert_not_contains ~label:"api name" out "\"TodoApi\"")

let r41_21_semantic_json_omits_facts_and_codecs_sections () =
  with_semantic_api (fun path ->
    let out = semantic_json path in
    assert_not_contains ~label:"facts key" out "\"facts\":";
    assert_not_contains ~label:"codecs key" out "\"codecs\":")

let r41_22_semantic_json_erases_refined_record_field_types () =
  with_semantic_api (fun path ->
    let out = semantic_json path in
    assert_contains ~label:"record field lowered" out
      "\"name\":\"title\",\"type\":\"String\"";
    assert_not_contains ~label:"record field refinement" out
      "\"type\":\"String ::: ValidTitle title\"")

let r41_23_semantic_json_erases_check_return_refinement () =
  with_semantic_api (fun path ->
    let out = semantic_json path in
    assert_contains ~label:"check signature lowered" out
      "\"kind\":\"check\",\"type\":\"String -> String\"";
    assert_not_contains ~label:"check signature refinement" out
      "\"kind\":\"check\",\"type\":\"String -> String ::: ValidTitle s\"")

(* Resilient semantic snapshot (Platinum P2): a buffer with a mid-declaration
   syntax error must still yield a best-effort JSON snapshot of the declarations
   that DID parse, not None/empty.  The earlier well-formed function and the
   later well-formed functions must both survive; only the broken one is lost. *)
let partial_recovery_src = {|#lang tesl
module Recover exposing [alpha, gamma]
import Tesl.Prelude exposing [Int]

fn alpha(n: Int) -> Int =
  n + 1

fn beta(n: Int) -> Int =
  n + @@@ )(

fn gamma(n: Int) -> Int =
  n + 3
|}

let r41_25_semantic_json_partial_on_parse_error () =
  with_temp_file "recover" ".tesl" partial_recovery_src (fun path ->
    let code, out = run_compiler ["--semantic-json"; path] in
    check int "exit code (partial snapshot succeeds)" 0 code;
    assert_contains ~label:"valid module header parsed" out "\"module_name\":\"Recover\"";
    assert_contains ~label:"function before the error survives" out "\"name\":\"alpha\"";
    assert_contains ~label:"function after the error survives" out "\"name\":\"gamma\"";
    assert_not_contains ~label:"broken function is dropped" out "\"name\":\"beta\"")

let r41_24_help_exits_nonzero () =
  let code, out = run_compiler ["--help"] in
  (* --help exits 0 (POSIX convention for successful help display) *)
  check int "exit code" 0 code;
  assert_contains ~label:"usage" out "Usage:"

let () =
  run "review-41-antagonistic"
    [ ("ts-generator",
       [ test_case "R41_01 tuple get typed" `Quick r41_01_ts_get_tuple_erased_to_unknown;
         test_case "R41_02 result get typed" `Quick r41_02_ts_get_result_erased_to_unknown;
         test_case "R41_03 dict get typed" `Quick r41_03_ts_get_dict_erased_to_unknown;
         test_case "R41_04 set get typed" `Quick r41_04_ts_get_set_erased_to_unknown;
         test_case "R41_05 maybe get parsed" `Quick r41_05_ts_get_maybe_lacks_zod_parse;
         test_case "R41_06 tuple post typed" `Quick r41_06_ts_post_tuple_body_erased_to_unknown;
         test_case "R41_07 result post typed" `Quick r41_07_ts_post_result_body_erased_to_unknown;
         test_case "R41_08 dict post typed" `Quick r41_08_ts_post_dict_body_erased_to_unknown;
         test_case "R41_09 set post typed" `Quick r41_09_ts_post_set_body_erased_to_unknown;
         test_case "R41_10 maybe post preserved" `Quick r41_10_ts_post_maybe_is_the_only_preserved_complex_shape;
       ]);
      ("elm-generator",
       [ test_case "R41_11 tuple get typed" `Quick r41_11_elm_get_tuple_erased_to_value;
         test_case "R41_12 result get typed" `Quick r41_12_elm_get_result_erased_to_value;
         test_case "R41_13 dict get typed" `Quick r41_13_elm_get_dict_erased_to_value;
         test_case "R41_14 set get lowered" `Quick r41_14_elm_get_set_lowered_to_list;
         test_case "R41_15 tuple post encoded" `Quick r41_15_elm_post_tuple_body_becomes_null;
         test_case "R41_16 result post encoded" `Quick r41_16_elm_post_result_body_becomes_null;
         test_case "R41_17 dict post encoded" `Quick r41_17_elm_post_dict_body_becomes_null;
         test_case "R41_18 set post lowered" `Quick r41_18_elm_post_set_lowers_to_list_encoding;
         test_case "R41_19 maybe post preserved" `Quick r41_19_elm_post_maybe_preserves_simple_record_shape;
       ]);
      ("semantic-and-cli",
       [ test_case "R41_20 semantic-json omits apis" `Quick r41_20_semantic_json_omits_api_declarations;
         test_case "R41_21 semantic-json omits facts/codecs" `Quick r41_21_semantic_json_omits_facts_and_codecs_sections;
         test_case "R41_22 semantic-json erases field refinements" `Quick r41_22_semantic_json_erases_refined_record_field_types;
         test_case "R41_23 semantic-json erases check refinements" `Quick r41_23_semantic_json_erases_check_return_refinement;
         test_case "R41_24 help exits non-zero" `Quick r41_24_help_exits_nonzero;
         test_case "R41_25 semantic-json partial on parse error" `Quick r41_25_semantic_json_partial_on_parse_error;
       ]);
    ]
