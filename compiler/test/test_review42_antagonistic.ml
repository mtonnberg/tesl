(** Antagonistic regression tests for shared IR-backed client generation.

    Focus: richer IR/TS/Elm shape fidelity across the shared typed codegen path.

    R42_01-R42_08   IR preserves richer GET response shapes
    R42_09-R42_16   IR preserves richer POST body shapes
    R42_17-R42_24   TS generator preserves richer GET signatures/parsers
    R42_25-R42_32   TS generator preserves richer POST signatures/parsers
    R42_33-R42_40   Elm generator preserves richer GET signatures/decoders
    R42_41-R42_48   Elm generator preserves richer POST signatures/encoders
*)

open Alcotest

type shape_case = {
  route : string;
  body_name : string;
  ir_type : string;
  ts_get_sig : string;
  ts_get_parse : string;
  ts_post_sig : string;
  ts_post_parse : string;
  elm_get_sig : string;
  elm_get_decoder : string;
  elm_post_sig : string;
  elm_post_body : string;
  elm_post_decoder : string;
}

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
    failf "%s: expected not to find %S in output:\n%s" label needle haystack

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

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let ir_json path =
  let code, out = run_compiler ["--ir"; path] in
  check int "exit code" 0 code;
  out

let generate_ts path =
  let code, out = run_compiler ["--generate-ts"; path] in
  check int "exit code" 0 code;
  out

let generate_elm path =
  let code, out = run_compiler ["--generate-elm"; path] in
  check int "exit code" 0 code;
  out

let deep_shape_api_src = {|#lang tesl
module Api exposing [DeepShapeApi]
import Tesl.Prelude exposing [Int, String, Bool]
import Tesl.Json exposing [stringCodec]
import Tesl.Tuple exposing [Tuple2(..), Tuple3(..)]
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

api DeepShapeApi {
  get "/pair" -> Tuple2 Int String
  get "/triple" -> Tuple3 Int String Bool
  get "/maybe-pair" -> Maybe (Tuple2 Int String)
  get "/result" -> Result Todo String
  get "/result-pair" -> Result (Tuple2 Int String) String
  get "/dict" -> Dict String Int
  get "/dict-int" -> Dict Int String
  get "/set" -> Set String

  post "/pair" body pair: Tuple2 Int String -> Tuple2 Int String
  post "/triple" body triple: Tuple3 Int String Bool -> Tuple3 Int String Bool
  post "/maybe-pair" body pair: Maybe (Tuple2 Int String) -> Maybe (Tuple2 Int String)
  post "/result" body result: Result Todo String -> Result Todo String
  post "/result-pair" body result: Result (Tuple2 Int String) String -> Result (Tuple2 Int String) String
  post "/dict" body dict: Dict String Int -> Dict String Int
  post "/dict-int" body pairs: Dict Int String -> Dict Int String
  post "/set" body tags: Set String -> Set String
}
|}

let with_deep_shape_api f =
  with_temp_file "tesl-r42-shapes-" ".tesl" deep_shape_api_src f

let proof_api_src = {|#lang tesl
module Api exposing [TodoApi]
import Tesl.Prelude exposing [String]
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

let with_proof_api f =
  with_temp_file "tesl-r42-proof-" ".tesl" proof_api_src f

let shape_cases = [
  {
    route = "/pair";
    body_name = "pair";
    ir_type = "Tuple2 Int String";
    ts_get_sig = {|export async function getPair(): Promise<[number, string]>|};
    ts_get_parse = {|z.tuple([z.number().int(), z.string()]).parse(await res.json()) as [number, string]|};
    ts_post_sig = {|export async function postPair(pair: [number, string]): Promise<[number, string]>|};
    ts_post_parse = {|z.tuple([z.number().int(), z.string()]).parse(await res.json()) as [number, string]|};
    elm_get_sig = {|getPair : (Result Http.Error ((Int, String)) -> msg) -> Cmd msg|};
    elm_get_decoder = {|Http.expectJson toMsg (D.map2 (\x y -> ( x, y )) (D.index 0 D.int) (D.index 1 D.string))|};
    elm_post_sig = {|postPair : (Int, String) -> (Result Http.Error ((Int, String)) -> msg) -> Cmd msg|};
    elm_post_body = {|Http.jsonBody (((\( first, second ) -> E.list identity [ E.int first, E.string second ]) pair))|};
    elm_post_decoder = {|Http.expectJson toMsg (D.map2 (\x y -> ( x, y )) (D.index 0 D.int) (D.index 1 D.string))|};
  };
  {
    route = "/triple";
    body_name = "triple";
    ir_type = "Tuple3 Int String Bool";
    ts_get_sig = {|export async function getTriple(): Promise<[number, string, boolean]>|};
    ts_get_parse = {|z.tuple([z.number().int(), z.string(), z.boolean()]).parse(await res.json()) as [number, string, boolean]|};
    ts_post_sig = {|export async function postTriple(triple: [number, string, boolean]): Promise<[number, string, boolean]>|};
    ts_post_parse = {|z.tuple([z.number().int(), z.string(), z.boolean()]).parse(await res.json()) as [number, string, boolean]|};
    elm_get_sig = {|getTriple : (Result Http.Error ((Int, String, Bool)) -> msg) -> Cmd msg|};
    elm_get_decoder = {|Http.expectJson toMsg (D.map3 (\x y z -> ( x, y, z )) (D.index 0 D.int) (D.index 1 D.string) (D.index 2 D.bool))|};
    elm_post_sig = {|postTriple : (Int, String, Bool) -> (Result Http.Error ((Int, String, Bool)) -> msg) -> Cmd msg|};
    elm_post_body = {|Http.jsonBody (((\( first, second, third ) -> E.list identity [ E.int first, E.string second, E.bool third ]) triple))|};
    elm_post_decoder = {|Http.expectJson toMsg (D.map3 (\x y z -> ( x, y, z )) (D.index 0 D.int) (D.index 1 D.string) (D.index 2 D.bool))|};
  };
  {
    route = "/maybe-pair";
    body_name = "pair";
    ir_type = "Maybe Tuple2 Int String";
    ts_get_sig = {|export async function getMaybePair(): Promise<[number, string] | null>|};
    ts_get_parse = {|z.tuple([z.number().int(), z.string()]).nullable().parse(await res.json()) as [number, string] | null|};
    ts_post_sig = {|export async function postMaybePair(pair: [number, string] | null): Promise<[number, string] | null>|};
    ts_post_parse = {|z.tuple([z.number().int(), z.string()]).nullable().parse(await res.json()) as [number, string] | null|};
    elm_get_sig = {|getMaybePair : (Result Http.Error (Maybe (((Int, String)))) -> msg) -> Cmd msg|};
    elm_get_decoder = {|Http.expectJson toMsg (D.maybe ((D.map2 (\x y -> ( x, y )) (D.index 0 D.int) (D.index 1 D.string))))|};
    elm_post_sig = {|postMaybePair : Maybe (((Int, String))) -> (Result Http.Error (Maybe (((Int, String)))) -> msg) -> Cmd msg|};
    elm_post_body = {|Http.jsonBody ((Maybe.withDefault E.null (Maybe.map (\value -> ((\( first, second ) -> E.list identity [ E.int first, E.string second ]) value)))) pair)|};
    elm_post_decoder = {|Http.expectJson toMsg (D.maybe ((D.map2 (\x y -> ( x, y )) (D.index 0 D.int) (D.index 1 D.string))))|};
  };
  {
    route = "/result";
    body_name = "result";
    ir_type = "Result Todo String";
    ts_get_sig = {|export async function getResult(): Promise<{ tag: "Ok"; value: Todo } | { tag: "Err"; error: string }>|};
    ts_get_parse = {|z.discriminatedUnion("tag", [z.object({ tag: z.literal("Ok"), value: TodoSchema }), z.object({ tag: z.literal("Err"), error: z.string() })]).parse(await res.json()) as { tag: "Ok"; value: Todo } | { tag: "Err"; error: string }|};
    ts_post_sig = {|export async function postResult(result: { tag: "Ok"; value: Todo } | { tag: "Err"; error: string }): Promise<{ tag: "Ok"; value: Todo } | { tag: "Err"; error: string }>|};
    ts_post_parse = {|z.discriminatedUnion("tag", [z.object({ tag: z.literal("Ok"), value: TodoSchema }), z.object({ tag: z.literal("Err"), error: z.string() })]).parse(await res.json()) as { tag: "Ok"; value: Todo } | { tag: "Err"; error: string }|};
    elm_get_sig = {|getResult : (Result Http.Error (Result String Todo) -> msg) -> Cmd msg|};
    elm_get_decoder = {|Http.expectJson toMsg (D.field "tag" D.string |> D.andThen (\tag -> case tag of "Ok" -> D.map Ok (D.field "value" todoDecoder) ; "Err" -> D.map Err (D.field "error" D.string) ; _ -> D.fail ("Unexpected Result tag: " ++ tag)))|};
    elm_post_sig = {|postResult : Result String Todo -> (Result Http.Error (Result String Todo) -> msg) -> Cmd msg|};
    elm_post_body = {|Http.jsonBody (((\result_ -> case result_ of Ok ok_ -> E.object [ ("tag", E.string "Ok"), ("value", todoEncoder ok_) ] ; Err err_ -> E.object [ ("tag", E.string "Err"), ("error", E.string err_) ]) result))|};
    elm_post_decoder = {|Http.expectJson toMsg (D.field "tag" D.string |> D.andThen (\tag -> case tag of "Ok" -> D.map Ok (D.field "value" todoDecoder) ; "Err" -> D.map Err (D.field "error" D.string) ; _ -> D.fail ("Unexpected Result tag: " ++ tag)))|};
  };
  {
    route = "/result-pair";
    body_name = "result";
    ir_type = "Result Tuple2 Int String String";
    ts_get_sig = {|export async function getResultPair(): Promise<{ tag: "Ok"; value: [number, string] } | { tag: "Err"; error: string }>|};
    ts_get_parse = {|z.discriminatedUnion("tag", [z.object({ tag: z.literal("Ok"), value: z.tuple([z.number().int(), z.string()]) }), z.object({ tag: z.literal("Err"), error: z.string() })]).parse(await res.json()) as { tag: "Ok"; value: [number, string] } | { tag: "Err"; error: string }|};
    ts_post_sig = {|export async function postResultPair(result: { tag: "Ok"; value: [number, string] } | { tag: "Err"; error: string }): Promise<{ tag: "Ok"; value: [number, string] } | { tag: "Err"; error: string }>|};
    ts_post_parse = {|z.discriminatedUnion("tag", [z.object({ tag: z.literal("Ok"), value: z.tuple([z.number().int(), z.string()]) }), z.object({ tag: z.literal("Err"), error: z.string() })]).parse(await res.json()) as { tag: "Ok"; value: [number, string] } | { tag: "Err"; error: string }|};
    elm_get_sig = {|getResultPair : (Result Http.Error (Result String ((Int, String))) -> msg) -> Cmd msg|};
    elm_get_decoder = {|Http.expectJson toMsg (D.field "tag" D.string |> D.andThen (\tag -> case tag of "Ok" -> D.map Ok (D.field "value" ((D.map2 (\x y -> ( x, y )) (D.index 0 D.int) (D.index 1 D.string)))) ; "Err" -> D.map Err (D.field "error" D.string) ; _ -> D.fail ("Unexpected Result tag: " ++ tag)))|};
    elm_post_sig = {|postResultPair : Result String ((Int, String)) -> (Result Http.Error (Result String ((Int, String))) -> msg) -> Cmd msg|};
    elm_post_body = {|Http.jsonBody (((\result_ -> case result_ of Ok ok_ -> E.object [ ("tag", E.string "Ok"), ("value", (\value -> ((\( first, second ) -> E.list identity [ E.int first, E.string second ]) value)) ok_) ] ; Err err_ -> E.object [ ("tag", E.string "Err"), ("error", E.string err_) ]) result))|};
    elm_post_decoder = {|Http.expectJson toMsg (D.field "tag" D.string |> D.andThen (\tag -> case tag of "Ok" -> D.map Ok (D.field "value" ((D.map2 (\x y -> ( x, y )) (D.index 0 D.int) (D.index 1 D.string)))) ; "Err" -> D.map Err (D.field "error" D.string) ; _ -> D.fail ("Unexpected Result tag: " ++ tag)))|};
  };
  {
    route = "/dict";
    body_name = "dict";
    ir_type = "Dict String Int";
    ts_get_sig = {|export async function getDict(): Promise<Record<string, number>>|};
    ts_get_parse = {|z.record(z.string(), z.number().int()).parse(await res.json()) as Record<string, number>|};
    ts_post_sig = {|export async function postDict(dict: Record<string, number>): Promise<Record<string, number>>|};
    ts_post_parse = {|z.record(z.string(), z.number().int()).parse(await res.json()) as Record<string, number>|};
    elm_get_sig = {|getDict : (Result Http.Error (Dict String Int) -> msg) -> Cmd msg|};
    elm_get_decoder = {|Http.expectJson toMsg (D.dict D.int)|};
    elm_post_sig = {|postDict : Dict String Int -> (Result Http.Error (Dict String Int) -> msg) -> Cmd msg|};
    elm_post_body = {|Http.jsonBody ((E.object (List.map (\( k, v ) -> ( k, E.int v )) (Dict.toList dict))))|};
    elm_post_decoder = {|Http.expectJson toMsg (D.dict D.int)|};
  };
  {
    route = "/dict-int";
    body_name = "pairs";
    ir_type = "Dict Int String";
    ts_get_sig = {|export async function getDictInt(): Promise<Array<[number, string]>>|};
    ts_get_parse = {|z.array(z.tuple([z.number().int(), z.string()])).parse(await res.json()) as Array<[number, string]>|};
    ts_post_sig = {|export async function postDictInt(pairs: Array<[number, string]>): Promise<Array<[number, string]>>|};
    ts_post_parse = {|z.array(z.tuple([z.number().int(), z.string()])).parse(await res.json()) as Array<[number, string]>|};
    elm_get_sig = {|getDictInt : (Result Http.Error (List (( Int, String ))) -> msg) -> Cmd msg|};
    elm_get_decoder = {|Http.expectJson toMsg (D.list (D.map2 (\x y -> ( x, y )) (D.index 0 D.int) (D.index 1 D.string)))|};
    elm_post_sig = {|postDictInt : List (( Int, String )) -> (Result Http.Error (List (( Int, String ))) -> msg) -> Cmd msg|};
    elm_post_body = {|Http.jsonBody ((E.list (\( k, v ) -> E.list identity [ E.int k, E.string v ]) pairs))|};
    elm_post_decoder = {|Http.expectJson toMsg (D.list (D.map2 (\x y -> ( x, y )) (D.index 0 D.int) (D.index 1 D.string)))|};
  };
  {
    route = "/set";
    body_name = "tags";
    ir_type = "Set String";
    ts_get_sig = {|export async function getSet(): Promise<Array<string>>|};
    ts_get_parse = {|z.array(z.string()).parse(await res.json()) as Array<string>|};
    ts_post_sig = {|export async function postSet(tags: Array<string>): Promise<Array<string>>|};
    ts_post_parse = {|z.array(z.string()).parse(await res.json()) as Array<string>|};
    elm_get_sig = {|getSet : (Result Http.Error (List String) -> msg) -> Cmd msg|};
    elm_get_decoder = {|Http.expectJson toMsg (D.list D.string)|};
    elm_post_sig = {|postSet : List String -> (Result Http.Error (List String) -> msg) -> Cmd msg|};
    elm_post_body = {|Http.jsonBody ((E.list E.string) tags)|};
    elm_post_decoder = {|Http.expectJson toMsg (D.list D.string)|};
  };
]

let () =
  List.iter (fun c ->
    assert (not (String.contains c.route ' '))
  ) shape_cases

let ir_response_test c =
  test_case (Printf.sprintf "IR GET %s response" c.route) `Quick (fun () ->
    with_deep_shape_api (fun path ->
      let out = ir_json path in
      assert_contains ~label:(c.route ^ " GET path") out ("\"method\":\"GET\",\"path\":\"" ^ c.route ^ "\"");
      assert_contains ~label:(c.route ^ " GET response type") out ("\"response\":{\"type\":\"" ^ c.ir_type ^ "\"");
      assert_contains ~label:(c.route ^ " GET semantic type") out ("\"semantic_return\":{\"kind\":\"plain\",\"type_text\":\"" ^ c.ir_type ^ "\"}")
    ))

let ir_body_test c =
  test_case (Printf.sprintf "IR POST %s body" c.route) `Quick (fun () ->
    with_deep_shape_api (fun path ->
      let out = ir_json path in
      assert_contains ~label:(c.route ^ " POST path") out ("\"method\":\"POST\",\"path\":\"" ^ c.route ^ "\"");
      assert_contains ~label:(c.route ^ " POST body type") out ("\"body\":{\"name\":\"" ^ c.body_name ^ "\",\"type\":\"" ^ c.ir_type ^ "\"");
      assert_contains ~label:(c.route ^ " POST body codec") out ("\"codec\":\"" ^ c.ir_type ^ "\"")
    ))

let ts_get_test c =
  test_case (Printf.sprintf "TS GET %s" c.route) `Quick (fun () ->
    with_deep_shape_api (fun path ->
      let out = generate_ts path in
      assert_contains ~label:(c.route ^ " TS GET signature") out c.ts_get_sig;
      assert_contains ~label:(c.route ^ " TS GET parser") out c.ts_get_parse
    ))

let ts_post_test c =
  test_case (Printf.sprintf "TS POST %s" c.route) `Quick (fun () ->
    with_deep_shape_api (fun path ->
      let out = generate_ts path in
      assert_contains ~label:(c.route ^ " TS POST signature") out c.ts_post_sig;
      assert_contains ~label:(c.route ^ " TS POST parser") out c.ts_post_parse
    ))

let elm_get_test c =
  test_case (Printf.sprintf "Elm GET %s" c.route) `Quick (fun () ->
    with_deep_shape_api (fun path ->
      let out = generate_elm path in
      assert_contains ~label:(c.route ^ " Elm GET signature") out c.elm_get_sig;
      assert_contains ~label:(c.route ^ " Elm GET decoder") out c.elm_get_decoder
    ))

let elm_post_test c =
  test_case (Printf.sprintf "Elm POST %s" c.route) `Quick (fun () ->
    with_deep_shape_api (fun path ->
      let out = generate_elm path in
      assert_contains ~label:(c.route ^ " Elm POST signature") out c.elm_post_sig;
      assert_contains ~label:(c.route ^ " Elm POST body") out c.elm_post_body;
      assert_contains ~label:(c.route ^ " Elm POST decoder") out c.elm_post_decoder
    ))

let elm_proof_field_decoder_closes_andthen () =
  with_proof_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"proof decoder closes" out
      {|D.fail "Failed proof: ValidTitle"
            )|})

let elm_proof_record_decoder_uses_fact_field_decoder () =
  with_proof_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"field decoder reuse" out
      {|(D.field "title" validTitleFieldDecoder)|})

let elm_out_path_infers_api_module_name () =
  with_deep_shape_api (fun path ->
    let root = Filename.temp_file "tesl-r42-elm-out-" "" in
    Sys.remove root;
    Unix.mkdir root 0o755;
    let src_dir = Filename.concat root "src" in
    let api_dir = Filename.concat src_dir "Api" in
    Unix.mkdir src_dir 0o755;
    Unix.mkdir api_dir 0o755;
    let out_path = Filename.concat api_dir "TodoApi.elm" in
    Fun.protect
      ~finally:(fun () -> rm_rf root)
      (fun () ->
        let code, out = run_compiler ["--generate-elm"; path; "--out"; out_path] in
        check int "exit code" 0 code;
        check string "stdout" "" out;
        let generated = In_channel.with_open_text out_path In_channel.input_all in
        assert_contains ~label:"module header" generated "module Api.TodoApi exposing")
  )

let elm_binding_forall_supports_compound_element_proofs () =
  let src = {|#lang tesl
module Api exposing [TodoApi]
import Tesl.Prelude exposing [String]

fact TodoId (s: String)
fact ContainsAnA (s: String)
fact NonEmpty (xs: List String)

api TodoApi {
  post "/list-test" body newTodos: List String ::: ForAll (TodoId && ContainsAnA) newTodos && NonEmpty newTodos -> String
}
|} in
  with_temp_file "tesl-r42-elm-forall-compound-" ".tesl" src (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"compound forall body signature" out
      {|postListTest : Proven (List ((Proven String (And TodoId ContainsAnA)))) NonEmpty -> (Result Http.Error String -> msg) -> Cmd msg|};
    assert_contains ~label:"compound forall body encoder" out
      {|body = Http.jsonBody ((E.list (\value -> E.string (exorcise value))) (exorcise newTodos))|}
  )

let elm_fromdb_filtering_preserves_remaining_conjunctions () =
  let src = {|#lang tesl
module Api exposing [TodoApi]
import Tesl.Prelude exposing [String]

record Todo {
  id: String
}
codec Todo {
  toJson_forbidden
  fromJson_forbidden
}

fact IsOpen (todo: Todo)
fact Archived (todo: Todo)

api TodoApi {
  get "/todos/open" -> List Todo ? ForAll (FromDb (OwnerId == userId) && IsOpen && Archived)
}
|} in
  with_temp_file "tesl-r42-elm-fromdb-conj-" ".tesl" src (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"fromdb-stripped conjunction preserved" out
      {|getTodosOpen : (Result Http.Error (List (Proven Todo (And IsOpen Archived))) -> msg) -> Cmd msg|};
    assert_not_contains ~label:"fromdb removed from conjunction" out "FromDb"
  )

let elm_capture_collision_renames_only_when_needed () =
  let src = {|#lang tesl
module Api exposing [TodoApi]
import Tesl.Prelude exposing [String]

fact TodoId (s: String)

api TodoApi {
  get "/todos/:todoId" capture todoId: String ::: TodoId todoId via todoIdCapture -> String
}
|} in
  with_temp_file "tesl-r42-elm-capture-collision-" ".tesl" src (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"collision capture type" out
      {|getTodos : Proven String TodoId -> (Result Http.Error String -> msg) -> Cmd msg|};
    assert_contains ~label:"capture implementation arg stays unchanged when unreserved" out
      {|getTodos todoId toMsg =|};
    assert_contains ~label:"capture url uses unchanged arg" out
      {|url = "/" ++ "todos" ++ "/" ++ exorcise todoId|}
  )

let elm_exports_proof_types_without_exporting_proof_constructors () =
  with_proof_api (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"proof type exported" out "    , ValidTitle";
    assert_not_contains ~label:"proof constructor not exported" out "ValidTitle(..)";
    assert_not_contains ~label:"forall constructor not exported" out "ForAll(..)"
  )

let elm_body_forall_proof_surfaces_as_proven_elements_with_outer_list_proofs () =
  let src = {|#lang tesl
module Api exposing [TodoApi]
import Tesl.Prelude exposing [String]

fact TodoId (s: String)
fact NonEmpty (xs: List String)
fact SomeOtherProof (xs: List String)

api TodoApi {
  post "/list-test" body newTodos: List String ::: ForAll TodoId newTodos && NonEmpty newTodos && SomeOtherProof newTodos -> String
}
|} in
  with_temp_file "tesl-r42-elm-forall-surface-" ".tesl" src (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"forall type constructor" out {|type ForAll p|};
    assert_contains ~label:"forall body signature" out
      {|postListTest : Proven (List ((Proven String TodoId))) (And NonEmpty SomeOtherProof) -> (Result Http.Error String -> msg) -> Cmd msg|};
    assert_contains ~label:"forall body encoder" out
      {|body = Http.jsonBody ((E.list (\value -> E.string (exorcise value))) (exorcise newTodos))|}
  )

let elm_client_surface_strips_fromdb_proofs () =
  let src = {|#lang tesl
module Api exposing [TodoApi]
import Tesl.Prelude exposing [String]

record Todo {
  id: String
}
codec Todo {
  toJson_forbidden
  fromJson_forbidden
}

fact IsOpen (todo: Todo)

api TodoApi {
  get "/todos" -> Todo ? FromDb (Id == todoId)
  get "/todos/open" -> List Todo ? ForAll (FromDb (OwnerId == userId) && IsOpen)
}
|} in
  with_temp_file "tesl-r42-elm-fromdb-strip-" ".tesl" src (fun path ->
    let out = generate_elm path in
    assert_contains ~label:"plain todo return" out
      {|getTodos : (Result Http.Error Todo -> msg) -> Cmd msg|};
    assert_contains ~label:"filtered proof return" out
      {|getTodosOpen : (Result Http.Error (List (Proven Todo IsOpen)) -> msg) -> Cmd msg|};
    assert_not_contains ~label:"fromdb stripped from client surface" out "FromDb"
  )

let () =
  run "review-42-ir-codegen-antagonistic"
    [ ("ir-response", List.map ir_response_test shape_cases);
      ("ir-body", List.map ir_body_test shape_cases);
      ("ts-get", List.map ts_get_test shape_cases);
      ("ts-post", List.map ts_post_test shape_cases);
      ("elm-get", List.map elm_get_test shape_cases);
      ("elm-post", List.map elm_post_test shape_cases);
      ("elm-proof-surface", [
         test_case "Elm closes proof field decoder" `Quick elm_proof_field_decoder_closes_andthen;
         test_case "Elm reuses fact field decoder" `Quick elm_proof_record_decoder_uses_fact_field_decoder;
         test_case "Elm infers module name from --out path" `Quick elm_out_path_infers_api_module_name;
         test_case "Elm binding ForAll supports compound element proofs" `Quick elm_binding_forall_supports_compound_element_proofs;
         test_case "Elm exports proof types without exporting proof constructors" `Quick elm_exports_proof_types_without_exporting_proof_constructors;
         test_case "Elm body ForAll surfaces as proven elements plus outer list proofs" `Quick elm_body_forall_proof_surfaces_as_proven_elements_with_outer_list_proofs;
         test_case "Elm strips FromDb from client proof surfaces" `Quick elm_client_surface_strips_fromdb_proofs;
         test_case "Elm FromDb filtering preserves remaining conjunctions" `Quick elm_fromdb_filtering_preserves_remaining_conjunctions;
         test_case "Elm capture collisions rename only when needed" `Quick elm_capture_collision_renames_only_when_needed;
       ]);
    ]
