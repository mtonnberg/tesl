(** Emit tests — verify that the OCaml compiler produces Racket output
    that matches the expected output (comparing against Python compiler's
    actual output where available). *)

open Parser
open Emit_racket

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let compile src =
  match parse_module "<test>" src with
  | Ok m -> Result.ok (compile_to_string ~root_path:"TESL_ROOT" m)
  | Err e -> Result.error e.msg

let assert_contains ~name haystack needle =
  if not (String.length haystack >= String.length needle &&
          let n = String.length needle in
          let m = String.length haystack in
          let found = ref false in
          for i = 0 to m - n do
            if String.sub haystack i n = needle then found := true
          done;
          !found) then
    Alcotest.failf "%s: expected to find\n  %S\nin:\n%s" name needle haystack

let assert_not_contains ~name haystack needle =
  if String.length haystack >= String.length needle then begin
    let n = String.length needle in
    let m = String.length haystack in
    let found = ref false in
    for i = 0 to m - n do
      if String.sub haystack i n = needle then found := true
    done;
    if !found then
      Alcotest.failf "%s: expected NOT to find\n  %S\nin:\n%s" name needle haystack
  end

let compile_ok src name =
  match compile src with
  | Ok r -> r
  | Error msg -> Alcotest.failf "%s compile error: %s" name msg

(* ── Require block tests ─────────────────────────────────────────────────── *)

let test_require_block () =
  let src = {|#lang tesl
module Foo exposing []
|} in
  let racket = compile_ok src "require_block" in
  assert_contains ~name:"has #lang racket" racket "#lang racket";
  assert_contains ~name:"has dsl/types" racket "tesl/dsl/types";
  assert_contains ~name:"has dsl/web" racket "tesl/dsl/web";
  assert_contains ~name:"has tesl/queue" racket "tesl/tesl/queue"

let test_require_prelude_import () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, String, Bool]
|} in
  let racket = compile_ok src "require_prelude" in
  assert_contains ~name:"only-in prelude" racket "only-in";
  assert_contains ~name:"Int exported" racket "Int";
  assert_contains ~name:"String exported" racket "String"

let test_require_qualified_import () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Dict exposing [Dict.lookup]
|} in
  let racket = compile_ok src "require_qualified" in
  (* Dict.lookup should be renamed to tesl_import_Dict_lookup *)
  assert_contains ~name:"Dict.lookup renamed" racket "tesl_import_Dict_lookup"

(* ── Provide block tests ─────────────────────────────────────────────────── *)

let test_provide_functions () =
  let src = {|#lang tesl
module Foo exposing [add, greet]
import Tesl.Prelude exposing [Int, String]
fn add(x: Int) -> Int = x
fn greet(s: String) -> String = s
|} in
  let racket = compile_ok src "provide_functions" in
  assert_contains ~name:"add in provide" racket "(provide";
  assert_contains ~name:"add provided" racket " add ";
  assert_contains ~name:"greet provided" racket " greet ";
  (* Signatures also provided *)
  assert_contains ~name:"add-signature provided" racket "add-signature"

(* ── Function emission tests ─────────────────────────────────────────────── *)

let test_fn_define_pow () =
  let src = {|#lang tesl
module Foo exposing [add]
import Tesl.Prelude exposing [Int]
fn add(x: Int, y: Int) -> Int =
  x + y
|} in
  let racket = compile_ok src "fn_define_pow" in
  assert_contains ~name:"define/pow" racket "(define/pow";
  assert_contains ~name:"fn name" racket "(add";
  assert_contains ~name:"param x" racket "[x : Integer]";
  assert_contains ~name:"param y" racket "[y : Integer]";
  assert_contains ~name:"returns Integer" racket "#:returns Integer";
  assert_contains ~name:"+ operator" racket "(+ *x *y)"

let test_fn_string_interpolation () =
  let src = {|#lang tesl
module Foo exposing [greet]
import Tesl.Prelude exposing [String]
fn greet(name: String) -> String =
  "Hello, ${name}!"
|} in
  let racket = compile_ok src "fn_interp" in
  assert_contains ~name:"format call" racket "(format";
  assert_contains ~name:"~a placeholder" racket "~a";
  assert_contains ~name:"tesl-display-val" racket "tesl-display-val"

let test_fn_case_expression () =
  let src = {|#lang tesl
module Foo exposing [colorName]
import Tesl.Prelude exposing [String]
type Color =
  | Red
  | Green
  | Blue
fn colorName(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|} in
  let racket = compile_ok src "fn_case" in
  assert_contains ~name:"let tesl_case" racket "tesl_case_";
  assert_contains ~name:"cond" racket "(cond";
  assert_contains ~name:"adt-value?" racket "adt-value?";
  assert_contains ~name:"adt-value-variant" racket "adt-value-variant"

let test_fn_if_expression () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Bool, Int]
fn f(b: Bool, x: Int) -> Int =
  if b then
    x
  else
    0
|} in
  let racket = compile_ok src "fn_if" in
  assert_contains ~name:"if expression" racket "(if"

(* ── Check / auth emission tests ─────────────────────────────────────────── *)

let test_check_define_checker () =
  let src = {|#lang tesl
module Foo exposing [isValidPort]
import Tesl.Prelude exposing [Int]
check isValidPort(port: Int) -> port: Int::: ValidPort port =
  if 1 <= port && port <= 65535 then
    ok port::: ValidPort port
  else
    fail 400 "port must be between 1 and 65535"
|} in
  let racket = compile_ok src "check_emit" in
  assert_contains ~name:"define-checker" racket "(define-checker";
  assert_contains ~name:"isValidPort" racket "isValidPort";
  assert_contains ~name:"accept" racket "(accept";
  assert_contains ~name:"reject" racket "(reject";
  (* Proof symbol definition *)
  assert_contains ~name:"define ValidPort" racket "(define ValidPort 'ValidPort)"

let test_auth_define_auther () =
  let src = {|#lang tesl
module Foo exposing [cookieAuth]
import Tesl.Http exposing [HttpRequest]
import Tesl.Prelude exposing [String]
auth cookieAuth(request: HttpRequest) -> user: String::: Authenticated user =
  fail 401 "not authenticated"
|} in
  let racket = compile_ok src "auth_emit" in
  assert_contains ~name:"define-auther" racket "(define-auther";
  assert_contains ~name:"Authenticated symbol" racket "(define Authenticated 'Authenticated)"

let test_auth_record_return_emission () =
  let src = {|#lang tesl
module Foo exposing [cookieAuth]
import Tesl.Http exposing [HttpRequest]
import Tesl.Prelude exposing [String]
record SessionUser {
  id: String
  username: String
}
auth cookieAuth(request: HttpRequest) -> session: SessionUser::: Authenticated session =
  ok { id: "u1", username: "alice" } ::: Authenticated session
|} in
  let racket = compile_ok src "auth_record_return_emit" in
  assert_contains ~name:"typed SessionUser constructor" racket "(SessionUser #:id \"u1\" #:username \"alice\")";
  assert_not_contains ~name:"raw hash auth return" racket "(hash 'id \"u1\" 'username \"alice\")"

let test_handler_emit () =
  let src = {|#lang tesl
module Foo exposing [createTask]
import Tesl.Prelude exposing [String]
handler createTask(user: String) -> String
  requires [taskDbWrite] =
  "ok"
|} in
  let racket = compile_ok src "handler_emit" in
  assert_contains ~name:"define-handler" racket "(define-handler";
  assert_contains ~name:"capabilities" racket "#:capabilities [taskDbWrite]"

let test_named_pack_entity_proof_emission () =
  let src = {|#lang tesl
module Foo exposing [tag]
import Tesl.Prelude exposing [Int]
fn tag(n: Int) -> Int ? Positive && Small ::: SameArg n =
  n
|} in
  let racket = compile_ok src "named_pack_emit" in
  assert_contains ~name:"named pack keeps _entity binder" racket "#:returns (? Integer _entity :::";
  assert_contains ~name:"Positive gets entity subject" racket "(Positive _entity)";
  assert_contains ~name:"Small gets entity subject" racket "(Small _entity)";
  assert_contains ~name:"other proof preserved" racket "(SameArg n)"

(* ── Type emission tests ─────────────────────────────────────────────────── *)

let test_adt_emission () =
  let src = {|#lang tesl
module Foo exposing [Color(..)]
type Color =
  | Red
  | Green
  | Blue
|} in
  let racket = compile_ok src "adt_emit" in
  assert_contains ~name:"define-adt" racket "(define-adt Color";
  assert_contains ~name:"Red variant" racket "[Red]";
  assert_contains ~name:"Green variant" racket "[Green]";
  assert_contains ~name:"Blue variant" racket "[Blue]"

let test_adt_with_fields_emission () =
  let src = {|#lang tesl
module Foo exposing [Shape(..)]
type Shape
  = Circle radius:Int
  | Rectangle width:Int height:Int
  | Point
|} in
  let racket = compile_ok src "adt_fields_emit" in
  assert_contains ~name:"define-adt Shape" racket "(define-adt Shape";
  assert_contains ~name:"Circle with radius" racket "[Circle [radius : Integer]]";
  assert_contains ~name:"Rectangle with fields" racket "[Rectangle [width : Integer] [height : Integer]]";
  assert_contains ~name:"Point nullary" racket "[Point]"

let test_newtype_emission () =
  let src = {|#lang tesl
module Foo exposing [UserId]
type UserId = String
|} in
  let racket = compile_ok src "newtype_emit" in
  assert_contains ~name:"define-newtype" racket "(define-newtype UserId"

let test_parameterized_adt_emission () =
  let src = {|#lang tesl
module Foo exposing [Either(..)]
type Either a b =
  | Left value:a
  | Right value:b
|} in
  let racket = compile_ok src "param_adt_emit" in
  assert_contains ~name:"define-adt with params" racket "(define-adt (Either a b)";
  assert_contains ~name:"Left variant" racket "[Left";
  assert_contains ~name:"Right variant" racket "[Right"

let test_single_param_adt_emission () =
  let src = {|#lang tesl
module Foo exposing [Box(..)]
type Box a = Box value:a
|} in
  let racket = compile_ok src "single_param_adt_emit" in
  assert_contains ~name:"define-adt with single param" racket "(define-adt (Box a)"

(* ── Record emission tests ───────────────────────────────────────────────── *)

let test_record_emission () =
  let src = {|#lang tesl
module Foo exposing [Task]
record Task {
  id: String
  title: String
  priority: Int
  done: Bool
}
|} in
  let racket = compile_ok src "record_emit" in
  assert_contains ~name:"define-record" racket "(define-record Task";
  assert_contains ~name:"id field" racket "[id : String]";
  assert_contains ~name:"priority as Integer" racket "[priority : Integer]";
  assert_contains ~name:"done as Boolean" racket "[done : Boolean]"

(* ── Codec emission tests ────────────────────────────────────────────────── *)

let test_codec_forbidden_emission () =
  let src = {|#lang tesl
module Foo exposing []
codec NewTask {
  toJson_forbidden
  fromJson_forbidden
}
|} in
  let racket = compile_ok src "codec_forbidden" in
  assert_contains ~name:"toJson error" racket "toJson is forbidden"

let test_codec_full_emission () =
  let src = {|#lang tesl
module Foo exposing []
codec Task {
  toJson {
    id -> "id" with_codec stringCodec
    title -> "title" with_codec stringCodec
  }
  fromJson_forbidden
}
|} in
  let racket = compile_ok src "codec_full" in
  assert_contains ~name:"tesl-codec-encode-Task" racket "tesl-codec-encode-Task";
  (* compile_time_specialization: primitive-codec fields encode via a DIRECT
     tesl-encode-prim-* helper call rather than routing each field through the
     generic tesl-codec-encode-field interpreter (behaviour-identical: the
     primitive codec pairs in dsl/types.rkt are built from these same helpers). *)
  assert_contains ~name:"tesl-encode-prim-string" racket "tesl-encode-prim-string";
  assert_contains ~name:"register-type-codec!" racket "register-type-codec!"

(* ── Capability emission tests ───────────────────────────────────────────── *)

let test_capability_emission () =
  let src = {|#lang tesl
module Foo exposing []
capability taskDbRead implies dbRead
|} in
  let racket = compile_ok src "capability_emit" in
  assert_contains ~name:"define-capability" racket "(define-capability taskDbRead"

(* ── Test block emission tests ───────────────────────────────────────────── *)

let test_test_block_emission () =
  let src = {|#lang tesl
module Foo exposing []
test "greet" {
  expect greet "World" == "Hello, World!"
  expect greet "Tesl" == "Hello, Tesl!"
}
|} in
  let racket = compile_ok src "test_block_emit" in
  assert_contains ~name:"module+ test" racket "(module+ test";
  assert_contains ~name:"require rackunit" racket "(require rackunit)";
  assert_contains ~name:"test-case" racket "(test-case \"greet\"";
  assert_contains ~name:"check-equal?" racket "check-equal?"

let test_expect_true_emission () =
  let src = {|#lang tesl
module Foo exposing []
test "weekend" {
  expect isWeekend Sat
}
|} in
  let racket = compile_ok src "expect_true" in
  assert_contains ~name:"check-true" racket "check-true"

let test_expect_fail_emission () =
  let src = {|#lang tesl
module Foo exposing []
test "invalid" {
  expectFail isValidPort 0
}
|} in
  let racket = compile_ok src "expect_fail_emit" in
  assert_contains ~name:"with-handlers" racket "with-handlers";
  assert_contains ~name:"exn:fail?" racket "exn:fail?"

let test_direct_check_expression_lowering () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check isPositive(n: Int) -> n: Int::: Positive n =
  if n > 0 then
    ok n::: Positive n
  else
    fail 400 "not positive"
test "lower direct check" {
  expect check isPositive 5 == 5
}
|} in
  let racket = compile_ok src "direct_check_lowering" in
  assert_contains ~name:"lowered checker call" racket "(isPositive 5)";
  assert_not_contains ~name:"no literal check form in emitted test" racket "(check isPositive 5)"

let test_expect_fail_check_lowering () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check isPositive(n: Int) -> n: Int::: Positive n =
  if n > 0 then
    ok n::: Positive n
  else
    fail 400 "not positive"
test "lower expectFail check" {
  expectFail check isPositive 0
}
|} in
  let racket = compile_ok src "expect_fail_check_lowering" in
  assert_contains ~name:"lowered checker call in expectFail" racket "(isPositive 0)";
  assert_not_contains ~name:"expectFail keeps check result intact" racket "(raw-value (check isPositive 0))"

let test_named_pack_local_tail_no_raw_unwrap () =
  let src = {|#lang tesl
module Foo exposing [validateAndReturn]
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check isPositive(n: Int) -> n: Int::: Positive n =
  if n > 0 then
    ok n::: Positive n
  else
    fail 400 "not positive"
fn validateAndReturn(n: Int) -> Int ? Positive =
  let validated = check isPositive n
  validated
|} in
  let racket = compile_ok src "named_pack_local_tail" in
  assert_contains ~name:"let/check preserved in named-pack function" racket "(let/check";
  assert_not_contains ~name:"named-pack local tail keeps proof value" racket "(raw-value validated)"

let test_if_branch_let_emission () =
  let src = {|#lang tesl
module Foo exposing []
test "branch locals" {
  if true then
    let x = 1
    expect x == 1
  else
    expect true
}
|} in
  let racket = compile_ok src "if_branch_let_emit" in
  assert_contains ~name:"then branch uses let body" racket "(let ()";
  assert_not_contains ~name:"then branch not bare begin" racket "(if #t
      (begin"

let test_test_raw_arithmetic_emission () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
check keepInt(n: Int) -> n: Int::: Kept n =
  ok n ::: Kept n

test "raw arithmetic" {
  let n = keepInt 30
  let total = n + 2
  expect total == 32
}
|} in
  let racket = compile_ok src "test_raw_arithmetic_emit" in
  (* B5: the let value is wrapped in a (thsl-src! … (lambda () …)) checkpoint
     that erases in release; the inner arithmetic is unchanged. *)
  assert_contains ~name:"raw arithmetic unwraps let-bound value" racket "(lambda () (+ (raw-value n) 2))";
  assert_contains ~name:"raw arithmetic define total" racket "(define total (thsl-src!";
  assert_not_contains ~name:"raw arithmetic does not use bare named value" racket "(+ n 2)"

let test_api_test_template_emission () =
  let src = {|#lang tesl
module Foo exposing []
api-test "request templates" for ChatServer {
  let room = post "/rooms/{roomId}"
              cookie "chatUserId={userId}"
              body { "content": "hello {roomName}" }
}
|} in
  let racket = compile_ok src "api_test_templates" in
  assert_contains ~name:"path fragment helper" racket "api-test-path-fragment";
  assert_contains ~name:"string fragment helper" racket "api-test-string-fragment";
  assert_contains ~name:"string append helper" racket "string-append"

(* ── Server emission tests ───────────────────────────────────────────────── *)

let test_server_emission () =
  let src = {|#lang tesl
module Foo exposing [TaskServer]
server TaskServer for TaskApi {
  createTask = createTask
  getTask = getTask
}
|} in
  let racket = compile_ok src "server_emit" in
  assert_contains ~name:"define-server" racket "(define-server TaskServer";
  assert_contains ~name:"api binding" racket "#:api TaskApi";
  assert_contains ~name:"createTask binding" racket "[createTask createTask]"

let test_unauth_multi_segment_api_path_emission () =
  let src = {|#lang tesl
module Foo exposing [MyApi]
import Tesl.Prelude exposing [String]
api MyApi {
  post "/auth/register"
    body req: String
    -> String
}
|} in
  let racket = compile_ok src "unauth_multi_segment_api_path_emit" in
  assert_contains ~name:"first segment emitted" racket "\"auth\"";
  assert_contains ~name:"later segment chained with :>" racket ":> \"register\"";
  assert_contains ~name:"request body still emitted" racket ":> (ReqBody JSON [req : String])"

let test_publish_channel_key_uses_raw_value () =
  let src = {|#lang tesl
module Foo exposing [postMessage]
import Tesl.Prelude exposing [String]
capability chatPubSub implies pubsub

type RoomEvent = NewMessage roomId: String

channel RoomMessages(roomId: String) {
  database MainDatabase
  payload RoomEvent
}

handler postMessage(roomId: String) -> String
  requires [chatPubSub] =
  publish RoomMessages(roomId) NewMessage { roomId: roomId }
  "ok"
|} in
  let racket = compile_ok src "publish_channel_key_uses_raw_value" in
  assert_contains ~name:"publish key unwraps named value" racket "(publish-event! RoomMessages (format \"~a\" *roomId)";
  assert_not_contains ~name:"publish key does not use wrapped binding" racket "(publish-event! RoomMessages (format \"~a\" roomId)"

let test_publish_channel_key_field_access_uses_runtime_field_value () =
  let src = {|#lang tesl
module Foo exposing [handleDeadNotify]
import Tesl.Prelude exposing [String]
capability chatPubSub implies pubsub

record NotifyJob {
  roomName: String
}

type RoomEvent = NotifyFailed roomName: String

channel RoomMessages(roomId: String) {
  database MainDatabase
  payload RoomEvent
}

deadWorker handleDeadNotify(job: NotifyJob) -> NotifyJob
  requires [chatPubSub] =
  publish RoomMessages(job.roomName) NotifyFailed { roomName: job.roomName }
  job
|} in
  let racket = compile_ok src "publish_channel_key_field_access_uses_runtime_field_value" in
  assert_contains ~name:"publish key keeps handler field access semantics" racket "(publish-event! RoomMessages (format \"~a\" (raw-value job.roomName))";
  assert_not_contains ~name:"publish key does not use raw field-access-ref on named value" racket "(publish-event! RoomMessages (format \"~a\" (field-access-ref job 'roomName))"

(* ── Full module round-trip tests ────────────────────────────────────────── *)

let test_full_hello_world () =
  let src = {|#lang tesl
module HelloWorld exposing [greet, add]
import Tesl.Prelude exposing [Int, String]

fn greet(name: String) -> String =
  "Hello, ${name}!"

fn add(x: Int, y: Int) -> Int =
  x + y

test "greet" {
  expect greet "World" == "Hello, World!"
}

test "add" {
  expect add 1 2 == 3
}
|} in
  let racket = compile_ok src "hello_world" in
  (* Verify key structural elements *)
  assert_contains ~name:"has define/pow for greet" racket "(define/pow";
  assert_contains ~name:"has format for interpolation" racket "format";
  assert_contains ~name:"has module+ test" racket "module+ test";
  assert_contains ~name:"no field-access-ref for simple vars" racket "raw-value";
  (* greet should use format "Hello, ~a!" *)
  assert_contains ~name:"Hello ~a format" racket "Hello, ~a!"

let test_full_proof_module () =
  let src = {|#lang tesl
module Proofs exposing [ValidPort, isValidPort]
import Tesl.Prelude exposing [Int, String]

check isValidPort(port: Int) -> port: Int::: ValidPort port =
  if 1 <= port && port <= 65535 then
    ok port::: ValidPort port
  else
    fail 400 "port must be between 1 and 65535"
|} in
  let racket = compile_ok src "proofs" in
  assert_contains ~name:"ValidPort symbol" racket "(define ValidPort 'ValidPort)";
  assert_contains ~name:"define-checker" racket "(define-checker";
  assert_contains ~name:"accept call" racket "(accept";
  assert_contains ~name:"reject call" racket "(reject";
  assert_not_contains ~name:"no T_ANY" racket "__Any__"

let test_full_adt_module () =
  let src = {|#lang tesl
module Adts exposing [Color(..), colorName]
import Tesl.Prelude exposing [String]

type Color =
  | Red
  | Green
  | Blue

fn colorName(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|} in
  let racket = compile_ok src "adt_full" in
  assert_contains ~name:"define-adt Color" racket "(define-adt Color";
  assert_contains ~name:"case compiled to cond" racket "cond";
  assert_contains ~name:"Red in provide" racket "Red";
  (* The provide should include Color, Red, Green, Blue *)
  assert_contains ~name:"Blue in provide" racket "Blue"

(* ── Adversarial emit tests ──────────────────────────────────────────────── *)

let test_no_t_any () =
  (* The new compiler must never emit __Any__ *)
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int = x
|} in
  let racket = compile_ok src "no_t_any" in
  assert_not_contains ~name:"no __Any__" racket "__Any__"

let test_type_mapping () =
  (* Tesl types should map correctly to Racket types *)
  let src = {|#lang tesl
module Foo exposing []
record R {
  a: Int
  b: String
  c: Bool
  d: Float
}
|} in
  let racket = compile_ok src "type_mapping" in
  assert_contains ~name:"Int -> Integer" racket "Integer";
  assert_contains ~name:"Bool -> Boolean" racket "Boolean"

(* ── Fix-11 §1.1: let x = check fn arg in fn body ─────────────────────── *)

(** Bug 1.1 regression: emit_with_raw_tail was not detecting the let/check
    pattern, generating `(let ([p (check isPositive n)]))` where `check` is
    unbound at runtime.  It must emit `(let/check ...)` instead. *)
let test_let_check_in_fn_body_emits_let_check () =
  let src = {|#lang tesl
module Foo exposing [addPositive, IsPositive]
import Tesl.Prelude exposing [Int]
check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn usePositive(n: Int ::: IsPositive n) -> Int = n

fn addPositive(a: Int, b: Int) -> Int =
  let pa = check isPositive a
  let pb = check isPositive b
  usePositive pa
|} in
  let racket = compile_ok src "let_check_in_fn_body" in
  (* Must emit let/check, NOT (let ([pa (check isPositive a)])) *)
  assert_contains ~name:"let/check for pa"     racket "let/check";
  assert_not_contains ~name:"no raw check call" racket "(check isPositive"

(** Adversarial: a plain let (not check) should NOT produce let/check. *)
let test_plain_let_in_fn_body_does_not_emit_let_check () =
  let src = {|#lang tesl
module Foo exposing [addTwo]
import Tesl.Prelude exposing [Int]
fn addTwo(n: Int) -> Int =
  let x = n + 1
  x + 1
|} in
  let racket = compile_ok src "plain_let_no_let_check" in
  assert_not_contains ~name:"no let/check for plain let" racket "let/check"

(* ── Fix-11 §3.3: ++ string concatenation operator ─────────────────────── *)

let test_string_concat_emits_string_append () =
  let src = {|#lang tesl
module Foo exposing [greet]
import Tesl.Prelude exposing [String]
fn greet(first: String, last: String) -> String =
  first ++ " " ++ last
|} in
  let racket = compile_ok src "string_concat_emit" in
  assert_contains ~name:"string-append in output" racket "string-append";
  assert_not_contains ~name:"no raw ++" racket "++"

(* ── SQL DSL emission tests ─────────────────────────────────────────────── *)

let test_sql_select_offset_emitted () =
  let src = {|#lang tesl
module Foo exposing []
fn test() -> Int =
  select u from User limit 10 offset 5
|} in
  let racket = compile_ok src "sql_offset" in
  assert_contains ~name:"limit emitted" racket "(limit 10)";
  assert_contains ~name:"offset emitted" racket "(offset 5)"

let test_sql_select_is_null_emitted () =
  let src = {|#lang tesl
module Foo exposing []
fn getNullEmail() -> Int =
  select u from User where isNull u.email
|} in
  let racket = compile_ok src "sql_isnull" in
  assert_contains ~name:"null?. predicate emitted" racket "null?.";
  assert_contains ~name:"entity-field-ref for email" racket "'email"

let test_sql_select_is_not_null_emitted () =
  let src = {|#lang tesl
module Foo exposing []
fn getNotNullEmail() -> Int =
  select u from User where isNotNull u.email
|} in
  let racket = compile_ok src "sql_isnotnull" in
  assert_contains ~name:"not-null?. predicate emitted" racket "not-null?.";
  assert_contains ~name:"entity-field-ref for email" racket "'email"

let test_sql_select_in_list_emitted () =
  let src = {|#lang tesl
module Foo exposing []
fn getAdmins() -> Int =
  select u from User where inList u.role ["admin", "moderator"]
|} in
  let racket = compile_ok src "sql_inlist" in
  assert_contains ~name:"in?. predicate emitted" racket "in?.";
  assert_contains ~name:"list emitted" racket "(list"

let test_sql_select_not_in_list_emitted () =
  let src = {|#lang tesl
module Foo exposing []
fn getActive() -> Int =
  select u from User where notInList u.status ["banned", "suspended"]
|} in
  let racket = compile_ok src "sql_notinlist" in
  assert_contains ~name:"not-in?. predicate emitted" racket "not-in?.";
  assert_contains ~name:"list emitted" racket "(list"

let test_sql_select_like_emitted () =
  let src = {|#lang tesl
module Foo exposing []
fn getSmith() -> Int =
  select u from User where like u.name "%Smith%"
|} in
  let racket = compile_ok src "sql_like" in
  assert_contains ~name:"like?. predicate emitted" racket "like?.";
  assert_contains ~name:"pattern emitted" racket "\"%Smith%\""

let test_sql_select_ilike_emitted () =
  let src = {|#lang tesl
module Foo exposing []
fn getExample() -> Int =
  select u from User where ilike u.email "%@example.com"
|} in
  let racket = compile_ok src "sql_ilike" in
  assert_contains ~name:"ilike?. predicate emitted" racket "ilike?.";
  assert_contains ~name:"pattern emitted" racket "\"%@example.com\""

let test_sql_select_group_by_emitted () =
  let src = {|#lang tesl
module Foo exposing []
fn getUsersByRole() -> Int =
  select u from User groupBy u.role
|} in
  let racket = compile_ok src "sql_groupby" in
  assert_contains ~name:"group-by emitted" racket "group-by";
  assert_contains ~name:"role field ref emitted" racket "'role"

let test_sql_inner_join_emitted () =
  let src = {|#lang tesl
module Foo exposing []
fn test() -> Int =
  select u from User innerJoin Profile on u.profileId Profile.id
|} in
  let racket = compile_ok src "sql_inner_join" in
  assert_contains ~name:"inner-join emitted" racket "inner-join";
  assert_contains ~name:"Profile entity emitted" racket "Profile";
  assert_contains ~name:"profileId field ref emitted" racket "'profileId";
  assert_contains ~name:"id field ref emitted" racket "'id"

(* ── Property test proof generation ─────────────────────────────────────── *)

let test_property_known_proof_uses_proof_field () =
  (* Known predicates (IsPositive) should still use tesl-test-proof-field
     because the generator guarantees the value satisfies the proof. *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
record PosInt {
  value: Int ::: IsPositive value
}
test "pos" {
  property "pos works" (n: PosInt) { True }
}
|} in
  let racket = compile_ok src "prop_known_proof" in
  assert_contains ~name:"tesl-test-proof-field for IsPositive" racket "tesl-test-proof-field";
  assert_contains ~name:"positive generator used" racket "(+ 1 (random"

let test_property_unknown_proof_no_fabrication () =
  (* Unknown predicates should NOT use tesl-test-proof-field — no fabrication. *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
record Task {
  priority: Int ::: LowPriority priority
}
test "task" {
  property "task gen" (t: Task) { True }
}
|} in
  let racket = compile_ok src "prop_unknown_proof" in
  assert_not_contains ~name:"no tesl-test-proof-field for unknown pred" racket "tesl-test-proof-field"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Emit" [
    "require", [
      Alcotest.test_case "require block" `Quick test_require_block;
      Alcotest.test_case "prelude import" `Quick test_require_prelude_import;
      Alcotest.test_case "qualified import rename" `Quick test_require_qualified_import;
    ];
    "provide", [
      Alcotest.test_case "function provides" `Quick test_provide_functions;
    ];
    "functions", [
      Alcotest.test_case "define/pow emission" `Quick test_fn_define_pow;
      Alcotest.test_case "string interpolation" `Quick test_fn_string_interpolation;
      Alcotest.test_case "case expression" `Quick test_fn_case_expression;
      Alcotest.test_case "if expression" `Quick test_fn_if_expression;
    ];
    "check-auth", [
      Alcotest.test_case "check define-checker" `Quick test_check_define_checker;
      Alcotest.test_case "auth define-auther" `Quick test_auth_define_auther;
      Alcotest.test_case "auth record return" `Quick test_auth_record_return_emission;
      Alcotest.test_case "handler define-handler" `Quick test_handler_emit;
      Alcotest.test_case "named-pack entity proofs" `Quick test_named_pack_entity_proof_emission;
    ];
    "types", [
      Alcotest.test_case "ADT emission" `Quick test_adt_emission;
      Alcotest.test_case "ADT with fields" `Quick test_adt_with_fields_emission;
      Alcotest.test_case "newtype emission" `Quick test_newtype_emission;
      Alcotest.test_case "parameterized ADT emission" `Quick test_parameterized_adt_emission;
      Alcotest.test_case "single-param ADT emission" `Quick test_single_param_adt_emission;
    ];
    "records", [
      Alcotest.test_case "record emission" `Quick test_record_emission;
    ];
    "codecs", [
      Alcotest.test_case "codec forbidden" `Quick test_codec_forbidden_emission;
      Alcotest.test_case "codec full" `Quick test_codec_full_emission;
    ];
    "capabilities", [
      Alcotest.test_case "capability emission" `Quick test_capability_emission;
    ];
    "tests", [
      Alcotest.test_case "test block emission" `Quick test_test_block_emission;
      Alcotest.test_case "expect true" `Quick test_expect_true_emission;
      Alcotest.test_case "expectFail" `Quick test_expect_fail_emission;
      Alcotest.test_case "direct check expression lowering" `Quick test_direct_check_expression_lowering;
      Alcotest.test_case "expectFail check lowering" `Quick test_expect_fail_check_lowering;
      Alcotest.test_case "named-pack local tail keeps proof" `Quick test_named_pack_local_tail_no_raw_unwrap;
      Alcotest.test_case "if branch lets" `Quick test_if_branch_let_emission;
      Alcotest.test_case "test raw arithmetic" `Quick test_test_raw_arithmetic_emission;
      Alcotest.test_case "api-test templates" `Quick test_api_test_template_emission;
    ];
    "server", [
      Alcotest.test_case "server emission" `Quick test_server_emission;
      Alcotest.test_case "unauth multi-segment api path" `Quick test_unauth_multi_segment_api_path_emission;
      Alcotest.test_case "publish channel key uses raw value" `Quick test_publish_channel_key_uses_raw_value;
      Alcotest.test_case "publish channel key field access uses runtime field value" `Quick test_publish_channel_key_field_access_uses_runtime_field_value;
    ];
    "full-modules", [
      Alcotest.test_case "hello world" `Quick test_full_hello_world;
      Alcotest.test_case "proof module" `Quick test_full_proof_module;
      Alcotest.test_case "ADT module" `Quick test_full_adt_module;
    ];
    "adversarial", [
      Alcotest.test_case "no T_ANY" `Quick test_no_t_any;
      Alcotest.test_case "type mapping" `Quick test_type_mapping;
    ];
    "fix-11-regressions", [
      Alcotest.test_case "let/check in fn body emits let/check" `Quick test_let_check_in_fn_body_emits_let_check;
      Alcotest.test_case "plain let does not emit let/check" `Quick test_plain_let_in_fn_body_does_not_emit_let_check;
      Alcotest.test_case "++ emits string-append" `Quick test_string_concat_emits_string_append;
    ];
    "sql", [
      Alcotest.test_case "select with offset" `Quick test_sql_select_offset_emitted;
      Alcotest.test_case "select with isNull" `Quick test_sql_select_is_null_emitted;
      Alcotest.test_case "select with isNotNull" `Quick test_sql_select_is_not_null_emitted;
      Alcotest.test_case "select with inList" `Quick test_sql_select_in_list_emitted;
      Alcotest.test_case "select with notInList" `Quick test_sql_select_not_in_list_emitted;
      Alcotest.test_case "select with like" `Quick test_sql_select_like_emitted;
      Alcotest.test_case "select with ilike" `Quick test_sql_select_ilike_emitted;
      Alcotest.test_case "select with groupBy" `Quick test_sql_select_group_by_emitted;
      Alcotest.test_case "select with innerJoin" `Quick test_sql_inner_join_emitted;
    ];
    "property-tests", [
      Alcotest.test_case "known proof uses tesl-test-proof-field" `Quick test_property_known_proof_uses_proof_field;
      Alcotest.test_case "unknown proof no fabrication" `Quick test_property_unknown_proof_no_fabrication;
    ];
  ]
