(** Antagonistic regression tests for Critical Review 68: newcomer feedback.

    These tests cover structural validation gaps where a newcomer (human or AI)
    would write plausibly-correct-looking code that silently compiled but failed
    at runtime.  The principle: every common mistake should produce a clear,
    located error message at compile time — not a cryptic Racket crash.

    New checks added in this review:
      - entity: empty table name, primary-key field not declared in entity body
      - queue/channel: database name references an undeclared database
      - fact: parameter type not in scope
      - capture: binding type not in scope

    Test groups:
      EN — entity structure
      QD — queue/channel database references
      FT — fact type parameters
      CP — capture binding types
      OK — valid forms (regression guard) *)

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

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r68" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── R68_EN — Entity structure ───────────────────────────────────────────── *)

let test_R68_EN01_entity_empty_table_name_rejected () =
  should_fail "empty table name\\|entity.*empty.*table" {|
#lang tesl
module R68En01 exposing []
import Tesl.Prelude exposing [Int]
entity R68En01 table "" primaryKey id { id: Int }
|}

let test_R68_EN02_entity_pk_field_not_declared_rejected () =
  should_fail "primary key\\|no field named\\|declares.*as its primary" {|
#lang tesl
module R68En02 exposing []
import Tesl.Prelude exposing [Int, String]
entity R68En02 table "items" primaryKey ghost { id: Int name: String }
|}

let test_R68_EN03_entity_pk_not_in_empty_fields_rejected () =
  should_fail "primary key\\|no field named\\|declares.*as its primary" {|
#lang tesl
module R68En03 exposing []
import Tesl.Prelude exposing [Int]
entity R68En03 table "t" primaryKey id { }
|}

let test_R68_EN04_entity_valid_accepted () =
  should_pass {|
#lang tesl
module R68En04 exposing []
import Tesl.Prelude exposing [Int, String]
entity R68En04 table "items" primaryKey id {
  id: Int
  name: String
  price: Int
}
|}

let test_R68_EN05_entity_pk_is_first_field_accepted () =
  should_pass {|
#lang tesl
module R68En05 exposing []
import Tesl.Prelude exposing [Int, String]
entity R68En05 table "users" primaryKey userId {
  userId: Int
  email: String
}
|}

let test_R68_EN06_entity_with_string_pk_accepted () =
  (* Primary key can be a String field too *)
  should_pass {|
#lang tesl
module R68En06 exposing []
import Tesl.Prelude exposing [String]
entity R68En06 table "sessions" primaryKey token {
  token: String
  userId: String
}
|}

(* ── R68_QD — Queue / channel undefined database ─────────────────────────── *)

let test_R68_QD01_queue_named_db_not_declared_rejected () =
  should_fail "unknown database\\|references unknown database" {|
#lang tesl
module R68Qd01 exposing []
queue R68Qd01 { database GhostDatabase jobs [MyJob] }
|}

let test_R68_QD02_channel_named_db_not_declared_rejected () =
  should_fail "unknown database\\|references unknown database" {|
#lang tesl
module R68Qd02 exposing []
import Tesl.Prelude exposing [String]
type Ev = EvA msg: String
channel R68Qd02 { database GhostDatabase payload Ev }
|}

let test_R68_QD03_queue_with_declared_database_accepted () =
  should_pass {|
#lang tesl
module R68Qd03 exposing []
import Tesl.Prelude exposing [String]
database R68Qd03Db {
  backend postgres schema "s" entities []
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" }
}
queue R68Qd03 { database R68Qd03Db jobs [NotifyJob] }
|}

let test_R68_QD04_channel_with_declared_database_accepted () =
  should_pass {|
#lang tesl
module R68Qd04 exposing []
import Tesl.Prelude exposing [String]
database R68Qd04Db {
  backend postgres schema "s" entities []
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" }
}
type Event = Happened msg: String
channel R68Qd04 { database R68Qd04Db payload Event }
|}

let test_R68_QD05_multiple_queues_one_bad_database_rejected () =
  (* Only the second queue has an undefined database *)
  should_fail "unknown database\\|references unknown database" {|
#lang tesl
module R68Qd05 exposing []
database R68Qd05Db {
  backend postgres schema "s" entities []
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" }
}
queue GoodQueue { database R68Qd05Db jobs [JobA] }
queue BadQueue  { database UndeclaredDb jobs [JobB] }
|}

let test_R68_QD06_queue_and_channel_same_db_accepted () =
  (* Both a queue and a channel can share the same database *)
  should_pass {|
#lang tesl
module R68Qd06 exposing []
import Tesl.Prelude exposing [String]
database SharedDb {
  backend postgres schema "s" entities []
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" }
}
type Notification = NotifyMsg text: String
queue EmailQueue { database SharedDb jobs [EmailJob] }
channel Updates { database SharedDb payload Notification }
|}

(* ── R68_FT — Fact type parameters ──────────────────────────────────────── *)

let test_R68_FT01_fact_unknown_type_in_param_rejected () =
  should_fail "not in scope\\|unknown.*type\\|type.*not in scope" {|
#lang tesl
module R68Ft01 exposing []
fact ValidEntry (x: UndeclaredRecordType)
|}

let test_R68_FT02_fact_unknown_type_stdlib_not_imported_rejected () =
  (* Dict type used in fact param without importing Tesl.Dict *)
  should_fail "not in scope\\|unknown.*type" {|
#lang tesl
module R68Ft02 exposing []
import Tesl.Prelude exposing [String]
fact HasKey (d: Dict String Int)
|}

let test_R68_FT03_fact_with_valid_local_record_type_accepted () =
  should_pass {|
#lang tesl
module R68Ft03 exposing []
import Tesl.Prelude exposing [Int]
record Item { id: Int }
fact IsValid (item: Item)
|}

let test_R68_FT04_fact_with_stdlib_type_imported_accepted () =
  should_pass {|
#lang tesl
module R68Ft04 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Maybe exposing [Maybe]
fact HasValue (m: Maybe Int)
|}

let test_R68_FT05_fact_with_no_params_accepted () =
  (* Fact with no parameters is valid — it's a module-level predicate *)
  should_pass {|
#lang tesl
module R68Ft05 exposing []
fact GlobalPred
|}

let test_R68_FT06_fact_with_primitive_types_accepted () =
  should_pass {|
#lang tesl
module R68Ft06 exposing []
import Tesl.Prelude exposing [String, Int]
fact Authenticated (userId: String)
fact InRange (lo: Int) (hi: Int) (n: Int)
|}

(* ── R68_CP — Capture binding types ─────────────────────────────────────── *)

let test_R68_CP01_capture_binding_unknown_type_rejected () =
  should_fail "not in scope\\|unknown.*type" {|
#lang tesl
module R68Cp01 exposing []
import Tesl.Json exposing [stringCodec]
capture myCapture: UndefinedType using stringCodec
|}

let test_R68_CP02_capture_binding_stdlib_type_not_imported_rejected () =
  (* Using Int without importing it *)
  should_fail "not in scope\\|unknown.*type\\|Int.*not in scope" {|
#lang tesl
module R68Cp02 exposing []
import Tesl.Json exposing [intCodec]
capture myIntCapture: Int using intCodec
|}

let test_R68_CP03_capture_with_valid_stdlib_type_accepted () =
  should_pass {|
#lang tesl
module R68Cp03 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture userId: String using stringCodec
|}

let test_R68_CP04_capture_with_valid_imported_type_accepted () =
  should_pass {|
#lang tesl
module R68Cp04 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Json exposing [intCodec]
capture itemId: Int using intCodec
|}

let test_R68_CP05_capture_with_local_newtype_accepted () =
  should_pass {|
#lang tesl
module R68Cp05 exposing []
import Tesl.Json exposing [stringCodec]
import Tesl.Prelude exposing [String]
type UserId = String
capture userId: UserId using stringCodec
|}

(* ── R68_OK — Pre-existing validation still works ───────────────────────── *)

let test_R68_OK01_unknown_export_still_rejected () =
  should_fail "unknown or non-local\\|module exposes unknown" {|
#lang tesl
module R68Ok01 exposing [doesNotExist]
import Tesl.Prelude exposing [Int]
fn add(a: Int, b: Int) -> Int = a + b
|}

let test_R68_OK02_undefined_capability_in_handler_still_rejected () =
  should_fail "undeclared capability\\|unknown.*capability" {|
#lang tesl
module R68Ok02 exposing []
import Tesl.Prelude exposing [Int]
handler h() -> Int requires [ghostCap] = 42
|}

let test_R68_OK03_case_unknown_ctor_still_rejected () =
  should_fail "unknown constructor\\|UnknownCtor" {|
#lang tesl
module R68Ok03 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn test(x: Maybe Int) -> Int =
  case x of
    Something n -> n
    UnknownCtor -> 0
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review68-Newcomer-Feedback" [
    "entity-structure", [
      test_case "R68_EN01 entity empty table name rejected" `Quick test_R68_EN01_entity_empty_table_name_rejected;
      test_case "R68_EN02 entity pk field not declared rejected" `Quick test_R68_EN02_entity_pk_field_not_declared_rejected;
      test_case "R68_EN03 entity pk not in empty fields rejected" `Quick test_R68_EN03_entity_pk_not_in_empty_fields_rejected;
      test_case "R68_EN04 entity valid accepted" `Quick test_R68_EN04_entity_valid_accepted;
      test_case "R68_EN05 entity pk is first field accepted" `Quick test_R68_EN05_entity_pk_is_first_field_accepted;
      test_case "R68_EN06 entity with string pk accepted" `Quick test_R68_EN06_entity_with_string_pk_accepted;
    ];
    "queue-channel-database", [
      test_case "R68_QD01 queue undefined database rejected" `Quick test_R68_QD01_queue_named_db_not_declared_rejected;
      test_case "R68_QD02 channel undefined database rejected" `Quick test_R68_QD02_channel_named_db_not_declared_rejected;
      test_case "R68_QD03 queue with declared database accepted" `Quick test_R68_QD03_queue_with_declared_database_accepted;
      test_case "R68_QD04 channel with declared database accepted" `Quick test_R68_QD04_channel_with_declared_database_accepted;
      test_case "R68_QD05 one bad queue database rejected" `Quick test_R68_QD05_multiple_queues_one_bad_database_rejected;
      test_case "R68_QD06 queue and channel sharing same db accepted" `Quick test_R68_QD06_queue_and_channel_same_db_accepted;
    ];
    "fact-type-parameters", [
      test_case "R68_FT01 fact unknown type in param rejected" `Quick test_R68_FT01_fact_unknown_type_in_param_rejected;
      test_case "R68_FT02 fact stdlib type not imported rejected" `Quick test_R68_FT02_fact_unknown_type_stdlib_not_imported_rejected;
      test_case "R68_FT03 fact with valid local type accepted" `Quick test_R68_FT03_fact_with_valid_local_record_type_accepted;
      test_case "R68_FT04 fact with imported stdlib type accepted" `Quick test_R68_FT04_fact_with_stdlib_type_imported_accepted;
      test_case "R68_FT05 fact with no params accepted" `Quick test_R68_FT05_fact_with_no_params_accepted;
      test_case "R68_FT06 fact with primitive types accepted" `Quick test_R68_FT06_fact_with_primitive_types_accepted;
    ];
    "capture-binding-types", [
      test_case "R68_CP01 capture unknown binding type rejected" `Quick test_R68_CP01_capture_binding_unknown_type_rejected;
      test_case "R68_CP02 capture stdlib type not imported rejected" `Quick test_R68_CP02_capture_binding_stdlib_type_not_imported_rejected;
      test_case "R68_CP03 capture valid stdlib type accepted" `Quick test_R68_CP03_capture_with_valid_stdlib_type_accepted;
      test_case "R68_CP04 capture valid int type accepted" `Quick test_R68_CP04_capture_with_valid_imported_type_accepted;
      test_case "R68_CP05 capture local newtype accepted" `Quick test_R68_CP05_capture_with_local_newtype_accepted;
    ];
    "pre-existing-still-works", [
      test_case "R68_OK01 unknown export rejected" `Quick test_R68_OK01_unknown_export_still_rejected;
      test_case "R68_OK02 undefined capability in handler rejected" `Quick test_R68_OK02_undefined_capability_in_handler_still_rejected;
      test_case "R68_OK03 case unknown constructor rejected" `Quick test_R68_OK03_case_unknown_ctor_still_rejected;
    ];
  ]
