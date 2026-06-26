(** IR tests — verify the evolving OCaml API IR slice and the `--ir` CLI. *)

open Parser

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
    Alcotest.failf "%s: expected to find
  %S
in:
%s" name needle haystack

let parse_module_ok ?(filename="<test>") src =
  match parse_module filename src with
  | Ok m -> m
  | Err e -> Alcotest.failf "parse error: %s" e.msg

let emit_ir src =
  Ir.module_to_json ~source_name:"test.tesl" (parse_module_ok src)

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
  let exe_dir = Filename.dirname Sys.executable_name in
  let build_dir = Filename.dirname exe_dir in
  let path = Filename.concat build_dir "bin/main.exe" in
  if Sys.file_exists path then path
  else Alcotest.failf "expected compiler binary at %s" path

let run_ir path =
  let binary = compiler_binary () in
  let ic = Unix.open_process_args_in binary [| binary; "--ir"; path |] in
  let stdout = In_channel.input_all ic in
  let exit_code =
    match Unix.close_process_in ic with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> Alcotest.failf "compiler terminated by signal %d" signal
    | Unix.WSTOPPED signal -> Alcotest.failf "compiler stopped by signal %d" signal
  in
  (exit_code, stdout)

let list_endpoint_src = {|#lang tesl
module ItemApiModule exposing [ItemApi]
record Item {
  name: String
}
api ItemApi {
  get "/items"
    -> List Item
}
|}

let body_endpoint_src = {|#lang tesl
module ItemApiModule exposing [ItemApi]
record Item {
  name: String
}
api ItemApi {
  post "/items"
    body item: Item
    -> Item
}
|}

let capture_endpoint_src = {|#lang tesl
module TodoApiModule exposing [TodoApi]
record Todo {
  id: String
}
api TodoApi {
  get "/todos/:todoId"
    capture todoId: String ::: TodoId todoId via todoIdCapture
    -> Todo
}
|}

let auth_endpoint_src = {|#lang tesl
module TodoApiModule exposing [TodoApi]
record User {
  id: String
}
record Todo {
  id: String
}
api TodoApi {
  get "/todos"
    auth u: User ::: Authenticated u via myAuth
    -> List Todo
}
|}

let exists_endpoint_src = {|#lang tesl
module TodoApiModule exposing [TodoApi]
record Todo {
  id: String
}
api TodoApi {
  post "/todos"
    -> exists newId: String => Todo ? FromDb (Id == newId)
}
|}

let simple_length_fact_src = {|#lang tesl
module M exposing [isSafe]
check isSafe(title: String) -> title: String ::: SafeText title =
  if 2 <= String.length(title) && String.length(title) <= 50 then
    ok title ::: SafeText title
  else
    fail 400 "bad"
|}

let int_range_fact_src = {|#lang tesl
module M exposing [isValidPort]
check isValidPort(port: Int) -> port: Int ::: ValidPort port =
  if 1 <= port && port <= 65535 then
    ok port ::: ValidPort port
  else
    fail 400 "bad"
|}

let complex_fact_src = {|#lang tesl
module M exposing [isComplex]
check isComplex(title: String) -> title: String ::: ComplexFact title =
  if customCheck title then
    ok title ::: ComplexFact title
  else
    fail 400 "bad"
|}

let auth_fact_src = {|#lang tesl
module M exposing [User]
record User {
  id: String
}
auth myAuth(req: HttpRequest) -> requestUser: User ::: Authenticated requestUser
  requires [todoReadHttpCookie] =
  ok { id: "u1" } ::: Authenticated requestUser
|}

let establish_fact_src = {|#lang tesl
module M exposing [validPort]
establish validPort (port: Int) -> Fact (ValidPort port) =
  if 1 <= port && port <= 65535 then
    ValidPort port
  else
    fail 400 "bad"
|}

let record_invariant_src = {|#lang tesl
module M exposing [Pair, checkGt]
check checkGt(a: Int, b: Int) -> a: Int ::: Gt a b =
  if a > b then
    ok a ::: Gt a b
  else
    fail 400 "bad"
record Pair {
  a: Int
  b: Int
} ::: Gt a b via checkGt
|}

let contains_ml_style_fact_src = {|#lang tesl
module M exposing [containsAnA]
check containsAnA(title: String) -> title: String ::: ContainsAnA title =
  if String.contains "a" title then
    ok title ::: ContainsAnA title
  else
    fail 400 "bad"
|}

let entity_auto_fact_src = {|#lang tesl
module M exposing [Item]
entity Item table "items" primaryKey id {
  id: String
  price: Int
}
|}

let record_fact_codec_src = {|#lang tesl
module M exposing [Msg, isSafeText]
check isSafeText(text: String) -> text: String ::: SafeText text =
  if 1 <= String.length text then
    ok text ::: SafeText text
  else
    fail 400 "bad"
record Msg {
  text: String ::: SafeText text
}
codec Msg {
  toJson {
    text -> "text" with_codec stringCodec
  }
  fromJson [
    {
      text <- "text" with_codec stringCodec
    }
  ]
}
|}

let codec_via_src = {|#lang tesl
module M exposing [Input, isSafe, isShort]
check isSafe(t: String) -> t: String ::: Safe t =
  if 1 <= String.length t then
    ok t ::: Safe t
  else
    fail 400 "bad"
check isShort(t: String) -> t: String ::: Short t =
  if String.length t <= 30 then
    ok t ::: Short t
  else
    fail 400 "bad"
record Input {
  title: String ::: Safe title && Short title
}
codec Input {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via (isSafe && isShort)
    }
  ]
}
|}

let codec_forbidden_src = {|#lang tesl
module M exposing [Out]
record Out {
  val: String
}
codec Out {
  toJson {
    val -> "val" with_codec stringCodec
  }
  fromJson_forbidden
}
|}

let adt_codec_src = {|#lang tesl
module M exposing [Dir(..)]
type Dir
  = North
  | South
codec Dir {
  toJson {
    North -> "N" with_codec stringCodec
  }
  fromJson_forbidden
}
|}

let newtype_src = {|#lang tesl
module M exposing [UserId]
type UserId = String
|}

let todo_api_path =
  let tesl_root = match Sys.getenv_opt "TESL_REPO_ROOT" with
    | Some p when p <> "" -> p
    | _ ->
      let rec find dir =
        let candidate = Filename.concat dir "compiler" in
        if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
        then dir
        else let parent = Filename.dirname dir in
             if parent = dir then Filename.current_dir_name else find parent
      in
      find (Filename.dirname Sys.executable_name)
  in
  Filename.concat tesl_root "example/todo-api.tesl"

let test_ir_get_list_endpoint () =
  let json = emit_ir list_endpoint_src in
  assert_contains ~name:"module name" json {|"module":"ItemApiModule"|};
  assert_contains ~name:"endpoint path" json {|"path":"/items"|};
  assert_contains ~name:"response list type" json {|"type":"List Item"|};
  assert_contains ~name:"response is_list" json {|"is_list":true|};
  assert_contains ~name:"response elem_type" json {|"elem_type":"Item"|}

let test_ir_post_body_endpoint () =
  let json = emit_ir body_endpoint_src in
  assert_contains ~name:"post method" json {|"method":"POST"|};
  assert_contains ~name:"body binding name" json {|"body":{"name":"item"|};
  assert_contains ~name:"body binding type" json {|"type":"Item"|};
  assert_contains ~name:"body codec" json {|"codec":"Item"|};
  assert_contains ~name:"response type" json {|"response":{"type":"Item"|}

let test_ir_capture_endpoint () =
  let json = emit_ir capture_endpoint_src in
  assert_contains ~name:"capture array" json {|"captures":[{"name":"todoId"|};
  assert_contains ~name:"capture fact" json {|"fact":"TodoId"|};
  assert_contains ~name:"capture via" json {|"via":"todoIdCapture"|}

let test_ir_auth_endpoint () =
  let json = emit_ir auth_endpoint_src in
  assert_contains ~name:"auth object" json {|"auth":{"name":"u"|};
  assert_contains ~name:"auth fact" json {|"fact":"Authenticated"|};
  assert_contains ~name:"auth via" json {|"via":"myAuth"|}

let test_ir_exists_response () =
  let json = emit_ir exists_endpoint_src in
  assert_contains ~name:"exists response type" json {|"response":{"type":"Todo"|};
  assert_contains ~name:"exists response fact" json {|"facts":["FromDb"]|};
  assert_contains ~name:"exists semantic kind" json {|"semantic_return":{"kind":"exists"|};
  assert_contains ~name:"exists binding name" json {|"binding":{"name":"newId"|};
  assert_contains ~name:"exists body kind" json {|"body":{"kind":"named-pack"|}

let test_ir_simple_length_fact () =
  let json = emit_ir simple_length_fact_src in
  assert_contains ~name:"fact name" json {|"name":"SafeText"|};
  assert_contains ~name:"fact checker" json {|"checker":"isSafe"|};
  assert_contains ~name:"fact kind" json {|"func_kind":"check"|};
  assert_contains ~name:"fact base type" json {|"base_type":"String"|};
  assert_contains ~name:"simple logic kind" json {|"logic":{"kind":"simple"|};
  assert_contains ~name:"gte length constraint" json {|{"op":"gte","fn":"String.length","value":2}|};
  assert_contains ~name:"lte length constraint" json {|{"op":"lte","fn":"String.length","value":50}|}

let test_ir_int_range_fact () =
  let json = emit_ir int_range_fact_src in
  assert_contains ~name:"valid port fact" json {|"name":"ValidPort"|};
  assert_contains ~name:"value gte" json {|{"op":"gte","fn":"value","value":1}|};
  assert_contains ~name:"value lte" json {|{"op":"lte","fn":"value","value":65535}|}

let test_ir_complex_check_is_server_only () =
  let json = emit_ir complex_fact_src in
  assert_contains ~name:"complex fact" json {|"name":"ComplexFact"|};
  assert_contains ~name:"server only logic" json {|"logic":{"kind":"server_only"}|}

let test_ir_auth_fact_logic () =
  let json = emit_ir auth_fact_src in
  assert_contains ~name:"auth fact name" json {|"name":"Authenticated"|};
  assert_contains ~name:"auth func kind" json {|"func_kind":"auth"|};
  assert_contains ~name:"auth logic" json {|"logic":{"kind":"auth"}|}

let test_ir_establish_fact_logic () =
  let json = emit_ir establish_fact_src in
  assert_contains ~name:"establish fact name" json {|"name":"ValidPort"|};
  assert_contains ~name:"establish kind" json {|"func_kind":"establish"|};
  assert_contains ~name:"establish logic" json {|"logic":{"kind":"server_only"}|}

let test_ir_record_invariant () =
  let json = emit_ir record_invariant_src in
  assert_contains ~name:"record invariant proof" json {|"invariant":{"proof_text":"Gt a b","checker_name":"checkGt"}|};
  assert_contains ~name:"record field a" json {|"fields":[{"name":"a"|}

let test_ir_contains_ml_style_fact () =
  let json = emit_ir contains_ml_style_fact_src in
  assert_contains ~name:"ml-style contains fact" json {|"name":"ContainsAnA"|};
  assert_contains ~name:"ml-style contains simple" json {|"logic":{"kind":"simple"|};
  assert_contains ~name:"ml-style contains constraint" json {|{"op":"contains","fn":"String.contains","value":"a"}|}

let test_ir_entity_auto_fact_names () =
  let json = emit_ir entity_auto_fact_src in
  assert_contains ~name:"entity id auto fact" json {|"name":"id","type":"String","fact":"Id"|};
  assert_contains ~name:"entity price auto fact" json {|"name":"price","type":"Int","fact":"Price"|}

let test_ir_record_fields_and_codec_reference () =
  let json = emit_ir record_fact_codec_src in
  assert_contains ~name:"record fact array" json {|"name":"text","type":"String","facts":["SafeText"]|};
  assert_contains ~name:"record codec reference" json {|"codec":"Msg"|}

let test_ir_codec_to_from_json () =
  let json = emit_ir record_fact_codec_src in
  assert_contains ~name:"codec to_json" json {|"to_json":[{"name":"text","json_key":"text","codec":"stringCodec"}]|};
  assert_contains ~name:"codec from_json" json {|"from_json":[[{"name":"text","json_key":"text","codec":"stringCodec","via":[]}]]|}

let test_ir_codec_via_list () =
  let json = emit_ir codec_via_src in
  assert_contains ~name:"codec via list" json {|"via":["isSafe","isShort"]|};
  assert_contains ~name:"codec to_json forbidden" json {|"to_json":null|}

let test_ir_codec_forbidden_from_json () =
  let json = emit_ir codec_forbidden_src in
  assert_contains ~name:"codec from_json forbidden" json {|"from_json":null|};
  assert_contains ~name:"codec to_json present" json {|"to_json":[{"name":"val","json_key":"val","codec":"stringCodec"}]|}

let test_ir_adt_codec_and_tag () =
  let json = emit_ir adt_codec_src in
  assert_contains ~name:"adt variant tag" json {|"tag":"North"|};
  assert_contains ~name:"adt codec reference" json {|"codec":"Dir"|}

let test_ir_newtype_base () =
  let json = emit_ir newtype_src in
  assert_contains ~name:"newtype base" json {|"newtypes":[{"name":"UserId","base":"String"}]|}

let test_cli_ir_endpoint_output () =
  with_temp_file "tesl-ir-" body_endpoint_src (fun path ->
    let exit_code, stdout = run_ir path in
    Alcotest.(check int) "exit code" 0 exit_code;
    assert_contains ~name:"cli ir module" stdout {|"module":"ItemApiModule"|};
    assert_contains ~name:"cli ir endpoints" stdout {|"endpoints":[|};
    assert_contains ~name:"cli ir body codec" stdout {|"codec":"Item"|})

let test_cli_ir_real_todo_api_facts () =
  let exit_code, stdout = run_ir todo_api_path in
  Alcotest.(check int) "exit code" 0 exit_code;
  assert_contains ~name:"todo-api title safe" stdout {|"name":"TitleSafe"|};
  assert_contains ~name:"todo-api authenticated auth" stdout {|"name":"Authenticated"|};
  assert_contains ~name:"todo-api auth logic" stdout {|"logic":{"kind":"auth"}|};
  assert_contains ~name:"todo-api valid port" stdout {|"name":"ValidPort"|};
  assert_contains ~name:"todo-api server only" stdout {|"logic":{"kind":"server_only"}|};
  assert_contains ~name:"todo-api contains-a" stdout {|"name":"ContainsAnA"|};
  assert_contains ~name:"todo-api contains constraint" stdout {|{"op":"contains","fn":"String.contains","value":"a"}|};
  assert_contains ~name:"todo-api title field facts" stdout {|"name":"title","type":"String","facts":["TitleSafe","LengthLessThan30","ContainsAnA"]|}

(* ---------------------------------------------------------------------------
   Constraint pattern coverage — mirrors TestIRConstraintParser in Python
   --------------------------------------------------------------------------- *)

let starts_with_fact_src = {|#lang tesl
module M exposing [isTodoId]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.startsWith, String.length]
check isTodoId(s: String) -> s: String ::: TodoId s =
  if String.startsWith s "todo-" && String.length s > 4 then
    ok s ::: TodoId s
  else
    fail 400 "bad"
|}

let regex_fact_src = {|#lang tesl
module M exposing [isSlug]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.matches]
check isSlug(s: String) -> s: String ::: Slug s =
  if String.matches s "[a-z]+" then
    ok s ::: Slug s
  else
    fail 400 "bad"
|}

let gt_lt_fact_src = {|#lang tesl
module M exposing [isMiddle]
import Tesl.Prelude exposing [Int]
check isMiddle(n: Int) -> n: Int ::: Middle n =
  if n > 0 && n < 100 then
    ok n ::: Middle n
  else
    fail 400 "bad"
|}

let test_ir_starts_with_constraint () =
  let json = emit_ir starts_with_fact_src in
  assert_contains ~name:"starts_with op" json {|"op":"starts_with"|};
  assert_contains ~name:"starts_with fn" json {|"fn":"String.startsWith"|};
  assert_contains ~name:"starts_with value" json {|"value":"todo-"|};
  assert_contains ~name:"gt op" json {|"op":"gt"|};
  assert_contains ~name:"gt fn" json {|"fn":"String.length"|}

let test_ir_regex_constraint () =
  let json = emit_ir regex_fact_src in
  assert_contains ~name:"regex op" json {|"op":"regex"|};
  assert_contains ~name:"regex fn" json {|"fn":"String.matches"|};
  assert_contains ~name:"regex value" json {|"value":"[a-z]+"|}

let test_ir_gt_lt_int_constraints () =
  let json = emit_ir gt_lt_fact_src in
  assert_contains ~name:"gt op" json {|"op":"gt"|};
  assert_contains ~name:"gt value" json {|"value":0|};
  assert_contains ~name:"lt op" json {|"op":"lt"|};
  assert_contains ~name:"lt value" json {|"value":100|}

(* ---------------------------------------------------------------------------
   Record structure — mirrors TestIRRecords in Python
   --------------------------------------------------------------------------- *)

let plain_record_src = {|#lang tesl
module M exposing [User]
import Tesl.Prelude exposing [String]
record User {
  id: String
  name: String
}
|}

let multi_record_src = {|#lang tesl
module M exposing [A, B]
import Tesl.Prelude exposing [Int, String]
record A {
  x: Int
}
record B {
  y: String
}
|}

let record_fact_field_src = {|#lang tesl
module M exposing [isValidTitle, Item]
import Tesl.Prelude exposing [String]
check isValidTitle(t: String) -> t: String ::: ValidTitle t =
  if 1 <= String.length t && String.length t <= 100 then
    ok t ::: ValidTitle t
  else
    fail 400 "bad"
record Item {
  title: String ::: ValidTitle title
}
|}

let test_ir_plain_record_fields () =
  let json = emit_ir plain_record_src in
  assert_contains ~name:"record name" json {|"name":"User"|};
  assert_contains ~name:"field id" json {|"name":"id","type":"String","facts":[]|};
  assert_contains ~name:"field name" json {|"name":"name","type":"String","facts":[]|};
  assert_contains ~name:"no codec" json {|"codec":null|}

let test_ir_multiple_records () =
  let json = emit_ir multi_record_src in
  assert_contains ~name:"record A" json {|"name":"A"|};
  assert_contains ~name:"record B" json {|"name":"B"|}

let test_ir_record_with_fact_field_proof_tree () =
  let json = emit_ir record_fact_field_src in
  assert_contains ~name:"field facts list" json {|"facts":["ValidTitle"]|};
  assert_contains ~name:"proof_tree predicate" json {|"proof_tree":{"kind":"predicate","name":"ValidTitle"}|}

let and_proof_tree_src = {|#lang tesl
module M exposing [isSafe, isShort, Msg]
import Tesl.Prelude exposing [String]
check isSafe(t: String) -> t: String ::: Safe t =
  if 1 <= String.length t then
    ok t ::: Safe t
  else
    fail 400 "bad"
check isShort(t: String) -> t: String ::: Short t =
  if String.length t <= 30 then
    ok t ::: Short t
  else
    fail 400 "too long"
record Msg {
  content: String ::: Safe content && Short content
}
|}

let test_ir_and_proof_tree_field () =
  let json = emit_ir and_proof_tree_src in
  assert_contains ~name:"and proof_tree kind" json {|"proof_tree":{"kind":"and"|};
  assert_contains ~name:"and left predicate" json {|"left":{"kind":"predicate","name":"Safe"}|};
  assert_contains ~name:"and right predicate" json {|"right":{"kind":"predicate","name":"Short"}|}

let composite_endpoint_proof_src = {|#lang tesl
module M exposing [MsgApi]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]

fact Safe (t: String)
check isSafe(t: String) -> t: String ::: Safe t =
  if 1 <= String.length(t) then
    ok t ::: Safe t
  else
    fail 400 "bad"

fact Short (t: String)
check isShort(t: String) -> t: String ::: Short t =
  if String.length(t) <= 30 then
    ok t ::: Short t
  else
    fail 400 "too long"

api MsgApi {
  post "/msgs/:id"
    auth user: String ::: Safe user && Short user via requireUser
    capture id: String ::: Safe id && Short id via idCapture
    body msg: String ::: Safe msg && Short msg
    -> saved: String ::: Safe saved && Short saved
}
|}

let test_ir_endpoint_bindings_preserve_composite_proofs () =
  let json = emit_ir composite_endpoint_proof_src in
  assert_contains ~name:"auth facts" json {|"auth":{"name":"user","type":"String","fact":"Safe","facts":["Safe","Short"]|};
  assert_contains ~name:"capture facts" json {|"captures":[{"name":"id","type":"String","fact":"Safe","facts":["Safe","Short"]|};
  assert_contains ~name:"body facts" json {|"body":{"name":"msg","type":"String","fact":"Safe","facts":["Safe","Short"]|};
  assert_contains ~name:"response facts" json {|"response":{"type":"String","facts":["Safe","Short"]|};
  assert_contains ~name:"semantic return binding facts" json {|"semantic_return":{"kind":"binding","binding":{"name":"saved","type":"String","fact":"Safe","facts":["Safe","Short"]|};
  assert_contains ~name:"binding proof_tree and" json {|"proof_tree":{"kind":"and","left":{"kind":"predicate","name":"Safe"},"right":{"kind":"predicate","name":"Short"}}|}

(* ---------------------------------------------------------------------------
   ADT structure — mirrors TestIRAdts in Python
   --------------------------------------------------------------------------- *)

let unit_adt_src = {|#lang tesl
module M exposing [Color(..)]
type Color
  = Red
  | Green
  | Blue
|}

let adt_with_fields_src = {|#lang tesl
module M exposing [Shape(..)]
import Tesl.Prelude exposing [Int]
type Shape
  = Circle Int
  | Rectangle Int Int
|}

let test_ir_unit_adt_variants () =
  let json = emit_ir unit_adt_src in
  assert_contains ~name:"adt name" json {|"name":"Color"|};
  assert_contains ~name:"tag Red" json {|"tag":"Red"|};
  assert_contains ~name:"tag Green" json {|"tag":"Green"|};
  assert_contains ~name:"tag Blue" json {|"tag":"Blue"|};
  assert_contains ~name:"no adt codec" json {|"codec":null|}

let test_ir_adt_with_fields () =
  let json = emit_ir adt_with_fields_src in
  assert_contains ~name:"adt name Shape" json {|"name":"Shape"|};
  assert_contains ~name:"circle tag" json {|"tag":"Circle"|};
  assert_contains ~name:"rectangle tag" json {|"tag":"Rectangle"|}

(* ---------------------------------------------------------------------------
   Newtype — mirrors TestIRNewtypes in Python
   --------------------------------------------------------------------------- *)

let int_newtype_src = {|#lang tesl
module M exposing [Port]
import Tesl.Prelude exposing [Int]
type Port = Int
|}

let multi_newtype_src = {|#lang tesl
module M exposing [A, B, C]
import Tesl.Prelude exposing [Int, String, Bool]
type A = String
type B = Int
type C = Bool
|}

let test_ir_int_newtype () =
  let json = emit_ir int_newtype_src in
  assert_contains ~name:"newtype Port" json {|"name":"Port","base":"Int"|}

let test_ir_multiple_newtypes () =
  let json = emit_ir multi_newtype_src in
  assert_contains ~name:"newtype A" json {|"name":"A","base":"String"|};
  assert_contains ~name:"newtype B" json {|"name":"B","base":"Int"|}

(* ---------------------------------------------------------------------------
   Contains call-style constraint — mirrors TestIRFacts.test_check_contains_call_style
   --------------------------------------------------------------------------- *)

let contains_call_style_src = {|#lang tesl
module M exposing [containsHello]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains]
check containsHello(s: String) -> s: String ::: ContainsHello s =
  if String.contains "hello" s then
    ok s ::: ContainsHello s
  else
    fail 400 "bad"
|}

let test_ir_contains_call_style_is_simple () =
  let json = emit_ir contains_call_style_src in
  assert_contains ~name:"contains call fact" json {|"name":"ContainsHello"|};
  assert_contains ~name:"contains call logic" json {|"logic":{"kind":"simple"|};
  assert_contains ~name:"contains call constraint" json {|"op":"contains","fn":"String.contains","value":"hello"|}

(* ---------------------------------------------------------------------------
   Entity structure — mirrors TestIREntities in Python
   --------------------------------------------------------------------------- *)

let entity_src = {|#lang tesl
module M exposing []
import Tesl.Prelude exposing [String, Int, Bool]
import Tesl.DB exposing [dbRead]
entity Task table "tasks" primaryKey id {
  id: String
  title: String
  done: Bool
}
|}

let entity_types_src = {|#lang tesl
module M exposing []
import Tesl.Prelude exposing [String, Int, Bool]
import Tesl.DB exposing [dbRead]
entity Rec table "recs" primaryKey id {
  id: String
  count: Int
  active: Bool
}
|}

let test_ir_entity_table_and_pk () =
  let json = emit_ir entity_src in
  assert_contains ~name:"entity name" json {|"name":"Task"|};
  assert_contains ~name:"entity table" json {|"table":"tasks"|};
  assert_contains ~name:"entity pk" json {|"primary_key":"id"|}

let test_ir_entity_field_types () =
  let json = emit_ir entity_types_src in
  assert_contains ~name:"id field type" json {|"name":"id","type":"String"|};
  assert_contains ~name:"count field type" json {|"name":"count","type":"Int"|};
  assert_contains ~name:"active field type" json {|"name":"active","type":"Bool"|}

(* ---------------------------------------------------------------------------
   Module metadata — mirrors TestIRModuleMetadata in Python
   --------------------------------------------------------------------------- *)

let empty_module_src = {|#lang tesl
module EmptyMod exposing []
|}

let test_ir_module_name () =
  let json = emit_ir empty_module_src in
  assert_contains ~name:"module name" json {|"module":"EmptyMod"|}

let test_ir_empty_module_arrays () =
  let json = emit_ir empty_module_src in
  assert_contains ~name:"empty records" json {|"records":[]|};
  assert_contains ~name:"empty adts" json {|"adts":[]|};
  assert_contains ~name:"empty newtypes" json {|"newtypes":[]|};
  assert_contains ~name:"empty entities" json {|"entities":[]|};
  assert_contains ~name:"empty facts" json {|"facts":[]|};
  assert_contains ~name:"empty codecs" json {|"codecs":[]|};
  assert_contains ~name:"empty endpoints" json {|"endpoints":[]|}

(* ---------------------------------------------------------------------------
   Codec via — mirrors TestIRCodecs in Python
   --------------------------------------------------------------------------- *)

let codec_no_via_src = {|#lang tesl
module M exposing [Msg]
import Tesl.Prelude exposing [String]
record Msg {
  content: String
}
codec Msg {
  toJson_forbidden
  fromJson [
    {
      content <- "content" with_codec stringCodec
    }
  ]
}
|}

let codec_single_via_src = {|#lang tesl
module M exposing [isSafe, Input]
import Tesl.Prelude exposing [String]
check isSafe(t: String) -> t: String ::: Safe t =
  if 1 <= String.length t then
    ok t ::: Safe t
  else
    fail 400 "bad"
record Input {
  title: String ::: Safe title
}
codec Input {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via isSafe
    }
  ]
}
|}

let codec_two_via_src = {|#lang tesl
module M exposing [isSafe, isShort, Input]
import Tesl.Prelude exposing [String]
check isSafe(t: String) -> t: String ::: Safe t =
  if 1 <= String.length t then
    ok t ::: Safe t
  else
    fail 400 "bad"
check isShort(t: String) -> t: String ::: Short t =
  if String.length t <= 30 then
    ok t ::: Short t
  else
    fail 400 "too long"
record Input {
  title: String ::: Safe title && Short title
}
codec Input {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via (isSafe && isShort)
    }
  ]
}
|}

let test_ir_codec_no_via_empty_list () =
  let json = emit_ir codec_no_via_src in
  assert_contains ~name:"no via is empty list" json {|"via":[]|}

let test_ir_codec_single_via () =
  let json = emit_ir codec_single_via_src in
  assert_contains ~name:"single via" json {|"via":["isSafe"]|}

let test_ir_codec_two_via () =
  let json = emit_ir codec_two_via_src in
  assert_contains ~name:"two via" json {|"via":["isSafe","isShort"]|}

(* ---------------------------------------------------------------------------
   Real example structure — mirrors TestIRRealExample in Python
   --------------------------------------------------------------------------- *)

let test_ir_todo_api_structure () =
  let exit_code, stdout = run_ir todo_api_path in
  Alcotest.(check int) "exit code" 0 exit_code;
  (* module *)
  assert_contains ~name:"module TodoApi" stdout {|"module":"TodoApi"|};
  (* newtypes *)
  assert_contains ~name:"newtype UserId" stdout {|"name":"UserId"|};
  (* facts *)
  assert_contains ~name:"fact TitleSafe" stdout {|"name":"TitleSafe"|};
  assert_contains ~name:"fact ValidPort" stdout {|"name":"ValidPort"|};
  assert_contains ~name:"fact TodoId" stdout {|"name":"TodoId"|};
  assert_contains ~name:"fact Authenticated" stdout {|"name":"Authenticated"|};
  (* records *)
  assert_contains ~name:"record NewTodo" stdout {|"name":"NewTodo"|};
  (* adts *)
  assert_contains ~name:"adt Status" stdout {|"name":"Status"|};
  (* entities *)
  assert_contains ~name:"entity Todo" stdout {|"name":"Todo"|};
  (* codecs *)
  assert_contains ~name:"codec NewTodo" stdout {|"name":"NewTodo"|};
  (* endpoints *)
  assert_contains ~name:"path /todos" stdout {|"path":"/todos"|};
  assert_contains ~name:"path /todos/:todoId" stdout {|"path":"/todos/:todoId"|}

let test_ir_todo_api_endpoints_methods () =
  let exit_code, stdout = run_ir todo_api_path in
  Alcotest.(check int) "exit code" 0 exit_code;
  assert_contains ~name:"POST /todos" stdout {|"method":"POST","path":"/todos"|};
  assert_contains ~name:"GET /todos/mine" stdout {|"method":"GET","path":"/todos/mine"|};
  assert_contains ~name:"GET /todos/:todoId" stdout {|"method":"GET","path":"/todos/:todoId"|};
  assert_contains ~name:"PUT /todos/:todoId/complete" stdout {|"method":"PUT","path":"/todos/:todoId/complete"|}

let test_ir_todo_api_post_body () =
  let exit_code, stdout = run_ir todo_api_path in
  Alcotest.(check int) "exit code" 0 exit_code;
  assert_contains ~name:"POST body type NewTodo" stdout {|"type":"NewTodo"|};
  assert_contains ~name:"POST body codec NewTodo" stdout {|"codec":"NewTodo"|}

let test_ir_todo_api_title_safe_constraints () =
  let exit_code, stdout = run_ir todo_api_path in
  Alcotest.(check int) "exit code" 0 exit_code;
  assert_contains ~name:"TitleSafe simple logic" stdout {|"name":"TitleSafe"|};
  assert_contains ~name:"TitleSafe gte constraint" stdout {|"op":"gte","fn":"String.length","value":4|};
  assert_contains ~name:"TitleSafe lte constraint" stdout {|"op":"lte","fn":"String.length","value":120|}

let test_ir_todo_api_new_todo_title_facts () =
  let exit_code, stdout = run_ir todo_api_path in
  Alcotest.(check int) "exit code" 0 exit_code;
  assert_contains ~name:"NewTodo title facts" stdout
    {|"name":"title","type":"String","facts":["TitleSafe","LengthLessThan30","ContainsAnA"]|}

(* ---------------------------------------------------------------------------
   Fact params — multi-parameter facts must include full params array
   --------------------------------------------------------------------------- *)

let multi_param_fact_src = {|#lang tesl
module M exposing [checkRange]
import Tesl.Prelude exposing [Int]
fact ValidRange (lo: Int, hi: Int)
check checkRange(lo: Int, hi: Int) -> lo: Int ::: ValidRange lo hi =
  if lo < hi then
    ok lo ::: ValidRange lo hi
  else
    fail 400 "bad"
|}

let test_ir_multi_param_fact_has_params () =
  let json = emit_ir multi_param_fact_src in
  assert_contains ~name:"fact name" json {|"name":"ValidRange"|};
  assert_contains ~name:"first param" json {|{"name":"lo","type":"Int"}|};
  assert_contains ~name:"second param" json {|{"name":"hi","type":"Int"}|}

let test_ir_single_param_fact_has_params () =
  let json = emit_ir simple_length_fact_src in
  assert_contains ~name:"single param name" json {|"params":[{"name":"title","type":"String"}]|}

(* When a `fact` declaration exists but there is no check/auth/establish function
   for it the fact should still appear in the IR with checker = null. *)
let standalone_fact_src = {|#lang tesl
module M exposing []
import Tesl.Prelude exposing [String]
fact Branded (value: String)
|}

let test_ir_standalone_fact_appears () =
  let json = emit_ir standalone_fact_src in
  assert_contains ~name:"fact name" json {|"name":"Branded"|};
  assert_contains ~name:"fact param" json {|{"name":"value","type":"String"}|};
  assert_contains ~name:"null checker" json {|"checker":null|}

(* todo-api declares `fact ValidPort (port: Int)` — check params are emitted. *)
let test_ir_todo_api_fact_params () =
  let exit_code, stdout = run_ir todo_api_path in
  Alcotest.(check int) "exit code" 0 exit_code;
  assert_contains ~name:"ValidPort params" stdout
    {|"name":"ValidPort","params":[{"name":"port","type":"Int"}]|};
  assert_contains ~name:"Authenticated params" stdout
    {|"name":"Authenticated","params":[{"name":"req","type":"User"}]|}

(* ---------------------------------------------------------------------------
   Editor query flags — signature help, selection range, type definition,
   and the additive occurrence `kind` field.  These exercise the
   Compile.*_source producers + their *_to_json serializers (the exact path the
   CLI flags dispatch through).
   --------------------------------------------------------------------------- *)

(* 0-based line/col layout:
   0  #lang tesl
   1  module Query exposing [add, useAdd]
   2  (blank)
   3  import Tesl.Prelude exposing [Int]
   4  (blank)
   5  record Point {
   6    x: Int
   7  }
   8  (blank)
   9  fn add(a: Int, b: Int) -> Int =
   10   a + b
   11 (blank)
   12 fn useAdd(p: Point) -> Int =
   13   add (p.x) (add 2 3) *)
let query_src = {|#lang tesl
module Query exposing [add, useAdd]

import Tesl.Prelude exposing [Int]

record Point {
  x: Int
}

fn add(a: Int, b: Int) -> Int =
  a + b

fn useAdd(p: Point) -> Int =
  add (p.x) (add 2 3)
|}

let test_occurrences_kind_write_and_read () =
  (* Cursor on the `add` definition (line 9, col 3). *)
  let occs = Compile.occurrences_source "query.tesl" query_src 9 3 in
  let json = Compile.occurrences_response_to_json occs in
  assert_contains ~name:"occurrences version" json {|"version":1|};
  (* The definition site is a write. *)
  assert_contains ~name:"def site is write" json {|"line":9,"col":3,"end_line":9,"end_col":6,"kind":"write"|};
  (* The two call sites on line 13 are reads. *)
  assert_contains ~name:"call site is read" json {|"line":13,"col":2,"end_line":13,"end_col":5,"kind":"read"|}

let test_occurrences_param_binding_is_write () =
  (* Cursor on parameter `a` of `add` (line 9, col 7). *)
  let occs = Compile.occurrences_source "query.tesl" query_src 9 7 in
  let json = Compile.occurrences_response_to_json occs in
  assert_contains ~name:"param binding is write" json {|"line":9,"col":7,"end_line":9,"end_col":8,"kind":"write"|};
  assert_contains ~name:"param use is read" json {|"line":10,"col":2,"end_line":10,"end_col":3,"kind":"read"|}

let test_signature_help_first_param () =
  (* Cursor inside the outer `add (...)` call, before any complete arg. *)
  let sig_ = Compile.signature_help_source "query.tesl" query_src 13 6 in
  let json = Compile.signature_help_response_to_json sig_ in
  assert_contains ~name:"sig version" json {|"version":1|};
  assert_contains ~name:"sig label" json {|"label":"add a: Int b: Int"|};
  assert_contains ~name:"sig params" json {|"parameters":[{"label":"a","type":"Int"},{"label":"b","type":"Int"}]|};
  assert_contains ~name:"active param 0" json {|"active_parameter":0|}

let test_signature_help_second_param () =
  (* Cursor positioned after the first argument of the outer `add` call. *)
  let sig_ = Compile.signature_help_source "query.tesl" query_src 13 11 in
  let json = Compile.signature_help_response_to_json sig_ in
  assert_contains ~name:"active param 1" json {|"active_parameter":1|}

let test_signature_help_outside_call_is_null () =
  (* Cursor on the record field declaration — not inside any call. *)
  let sig_ = Compile.signature_help_source "query.tesl" query_src 6 2 in
  let json = Compile.signature_help_response_to_json sig_ in
  assert_contains ~name:"no signature" json {|"signature":null|}

let test_selection_range_nested () =
  (* Cursor on `a` inside the body `a + b` (line 10, col 2). *)
  let ranges = Compile.selection_range_source "query.tesl" query_src 10 2 in
  let json = Compile.selection_ranges_response_to_json ranges in
  assert_contains ~name:"selection version" json {|"version":1|};
  (* Innermost-first: the binop body span appears, and the enclosing function
     declaration span (line 9 .. line 12) appears later in the chain. *)
  assert_contains ~name:"binop body range" json {|"line":10,"col":2,"end_line":10,"end_col":8|};
  assert_contains ~name:"enclosing decl range" json {|"end_line":12|};
  (* Must be non-empty and the first range no wider than the last. *)
  (match ranges with
   | [] -> Alcotest.fail "expected at least one selection range"
   | first :: _ ->
     let last = List.nth ranges (List.length ranges - 1) in
     let span r = (r.Compile.sr_end_line - r.Compile.sr_line,
                   r.Compile.sr_end_col - r.Compile.sr_col) in
     if compare (span first) (span last) > 0 then
       Alcotest.fail "selection ranges must be innermost-first")

let test_type_definition_record () =
  (* Cursor on `p` whose type is `Point`; expect the record declaration loc. *)
  let loc = Compile.type_definition_source "query.tesl" query_src 13 7 in
  let json = Compile.type_definition_response_to_json loc in
  assert_contains ~name:"type-def version" json {|"version":1|};
  assert_contains ~name:"points at record decl" json {|"line":5,"col":7,"end_line":5,"end_col":12|}

let test_type_definition_null_when_no_type () =
  (* Cursor on a blank line — nothing resolves. *)
  let loc = Compile.type_definition_source "query.tesl" query_src 2 0 in
  let json = Compile.type_definition_response_to_json loc in
  assert_contains ~name:"null type definition" json {|"type_definition":null|}

let () =
  Alcotest.run "IR" [
    "emit", [
      Alcotest.test_case "list endpoint" `Quick test_ir_get_list_endpoint;
      Alcotest.test_case "post body endpoint" `Quick test_ir_post_body_endpoint;
      Alcotest.test_case "capture endpoint" `Quick test_ir_capture_endpoint;
      Alcotest.test_case "auth endpoint" `Quick test_ir_auth_endpoint;
      Alcotest.test_case "exists response" `Quick test_ir_exists_response;
      Alcotest.test_case "simple length fact" `Quick test_ir_simple_length_fact;
      Alcotest.test_case "int range fact" `Quick test_ir_int_range_fact;
      Alcotest.test_case "complex check is server_only" `Quick test_ir_complex_check_is_server_only;
      Alcotest.test_case "auth fact logic" `Quick test_ir_auth_fact_logic;
      Alcotest.test_case "establish fact logic" `Quick test_ir_establish_fact_logic;
      Alcotest.test_case "record invariant" `Quick test_ir_record_invariant;
      Alcotest.test_case "contains ml-style fact" `Quick test_ir_contains_ml_style_fact;
      Alcotest.test_case "entity auto fact names" `Quick test_ir_entity_auto_fact_names;
      Alcotest.test_case "record fields and codec reference" `Quick test_ir_record_fields_and_codec_reference;
      Alcotest.test_case "codec to/from json" `Quick test_ir_codec_to_from_json;
      Alcotest.test_case "codec via list" `Quick test_ir_codec_via_list;
      Alcotest.test_case "codec forbidden from_json" `Quick test_ir_codec_forbidden_from_json;
      Alcotest.test_case "adt codec and tag" `Quick test_ir_adt_codec_and_tag;
      Alcotest.test_case "newtype base" `Quick test_ir_newtype_base;
      Alcotest.test_case "cli --ir output" `Quick test_cli_ir_endpoint_output;
      Alcotest.test_case "cli --ir real todo-api facts" `Quick test_cli_ir_real_todo_api_facts;
    ];
    "constraints", [
      Alcotest.test_case "starts_with constraint" `Quick test_ir_starts_with_constraint;
      Alcotest.test_case "regex constraint" `Quick test_ir_regex_constraint;
      Alcotest.test_case "gt/lt int constraints" `Quick test_ir_gt_lt_int_constraints;
      Alcotest.test_case "contains call-style simple" `Quick test_ir_contains_call_style_is_simple;
    ];
    "records", [
      Alcotest.test_case "plain record fields" `Quick test_ir_plain_record_fields;
      Alcotest.test_case "multiple records" `Quick test_ir_multiple_records;
      Alcotest.test_case "fact field proof_tree predicate" `Quick test_ir_record_with_fact_field_proof_tree;
      Alcotest.test_case "and proof_tree field" `Quick test_ir_and_proof_tree_field;
      Alcotest.test_case "endpoint bindings keep composite proofs" `Quick test_ir_endpoint_bindings_preserve_composite_proofs;
    ];
    "adts", [
      Alcotest.test_case "unit adt variants" `Quick test_ir_unit_adt_variants;
      Alcotest.test_case "adt with fields" `Quick test_ir_adt_with_fields;
    ];
    "newtypes", [
      Alcotest.test_case "int newtype" `Quick test_ir_int_newtype;
      Alcotest.test_case "multiple newtypes" `Quick test_ir_multiple_newtypes;
    ];
    "entities", [
      Alcotest.test_case "entity table and pk" `Quick test_ir_entity_table_and_pk;
      Alcotest.test_case "entity field types" `Quick test_ir_entity_field_types;
    ];
    "codecs", [
      Alcotest.test_case "no via gives empty list" `Quick test_ir_codec_no_via_empty_list;
      Alcotest.test_case "single via" `Quick test_ir_codec_single_via;
      Alcotest.test_case "two via entries" `Quick test_ir_codec_two_via;
    ];
    "module-metadata", [
      Alcotest.test_case "module name" `Quick test_ir_module_name;
      Alcotest.test_case "empty module arrays" `Quick test_ir_empty_module_arrays;
    ];
    "real-example", [
      Alcotest.test_case "todo-api structure" `Quick test_ir_todo_api_structure;
      Alcotest.test_case "todo-api endpoint methods" `Quick test_ir_todo_api_endpoints_methods;
      Alcotest.test_case "todo-api post body" `Quick test_ir_todo_api_post_body;
      Alcotest.test_case "todo-api TitleSafe constraints" `Quick test_ir_todo_api_title_safe_constraints;
      Alcotest.test_case "todo-api NewTodo title facts" `Quick test_ir_todo_api_new_todo_title_facts;
    ];
    "fact-params", [
      Alcotest.test_case "multi-param fact has params array" `Quick test_ir_multi_param_fact_has_params;
      Alcotest.test_case "single-param fact has params array" `Quick test_ir_single_param_fact_has_params;
      Alcotest.test_case "standalone fact appears in IR" `Quick test_ir_standalone_fact_appears;
      Alcotest.test_case "todo-api fact params" `Quick test_ir_todo_api_fact_params;
    ];
    "query-flags", [
      Alcotest.test_case "occurrences kind write/read" `Quick test_occurrences_kind_write_and_read;
      Alcotest.test_case "occurrences param binding is write" `Quick test_occurrences_param_binding_is_write;
      Alcotest.test_case "signature help first param" `Quick test_signature_help_first_param;
      Alcotest.test_case "signature help second param" `Quick test_signature_help_second_param;
      Alcotest.test_case "signature help null outside call" `Quick test_signature_help_outside_call_is_null;
      Alcotest.test_case "selection range nested" `Quick test_selection_range_nested;
      Alcotest.test_case "type definition record" `Quick test_type_definition_record;
      Alcotest.test_case "type definition null" `Quick test_type_definition_null_when_no_type;
    ];
  ]
