(** Validation pass tests for parity-critical frontend checks.

    Covers:
    1. Server binding completeness
    2. SQL field name validation with local bindings/patterns
    3. Codec proof coverage
    4. Call-site proof satisfaction
    5. ForAll proof propagation
    6. Exists return/body validation
    7. Integration with top-level diagnostics *)

open Validation_common

let parse src = Parser.parse_module "<test>" src

let assert_no_errors src =
  match parse src with
  | Err e -> Alcotest.failf "parse error: %s" e.msg
  | Ok m ->
    let errs = Validation.check_module m in
    if errs <> [] then
      Alcotest.failf "expected no validation errors but got:\n%s"
        (String.concat "\n" (List.map Validation_common.fmt_validation_error errs))

let contains needle haystack =
  let n = String.length needle in
  let m = String.length haystack in
  let found = ref false in
  if n <= m then
    for i = 0 to m - n do
      if String.sub haystack i n = needle then found := true
    done;
  !found

let assert_validation_error src substr =
  match parse src with
  | Err e -> Alcotest.failf "parse error: %s" e.msg
  | Ok m ->
    let errs = Validation.check_module m in
    let found = List.exists (fun e -> contains substr e.message) errs in
    if not found then
      Alcotest.failf "expected error %S but got:\n%s"
        substr
        (if errs = [] then "(no errors)" else
         String.concat "\n" (List.map (fun e -> e.message) errs))

let assert_no_compile_diagnostics src =
  let diags = Compile.check_source "<test>" src in
  if diags <> [] then
    Alcotest.failf "expected no diagnostics but got:
%s"
      (String.concat "
" (List.map (fun (d : Compile.diagnostic) -> d.source ^ ": " ^ d.message) diags))

let write_text_file path contents =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let assert_compile_diagnostic_from_entry ~entry_path ~entry_src ~extra_files ~substr =
  List.iter (fun (path, contents) -> write_text_file path contents) ((entry_path, entry_src) :: extra_files);
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (path, _) -> if Sys.file_exists path then Sys.remove path) ((entry_path, entry_src) :: extra_files)
    )
    (fun () ->
      let diags = Compile.check_source entry_path entry_src in
      let msgs = String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diags) in
      let n = String.length substr in
      let found = ref false in
      for i = 0 to String.length msgs - n do
        if String.sub msgs i n = substr then found := true
      done;
      if not !found then
        Alcotest.failf "expected diagnostic containing %S but got:\n%s" substr
          (if diags = [] then "(no diagnostics)" else msgs))

let assert_no_compile_diagnostics_from_entry ~entry_path ~entry_src ~extra_files =
  List.iter (fun (path, contents) -> write_text_file path contents) ((entry_path, entry_src) :: extra_files);
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (path, _) -> if Sys.file_exists path then Sys.remove path) ((entry_path, entry_src) :: extra_files)
    )
    (fun () ->
      let diags = Compile.check_source entry_path entry_src in
      if diags <> [] then
        Alcotest.failf "expected no diagnostics but got:
%s"
          (String.concat "
" (List.map (fun (d : Compile.diagnostic) -> d.source ^ ": " ^ d.message) diags)))

(* ── 1. Server binding completeness ──────────────────────────────────────── *)

let test_server_bindings_ok () =
  assert_no_errors {|#lang tesl
module Foo exposing [S]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture idCapture: id: String using stringCodec
handler createTask(x: String) -> String requires [] = x
handler getTask(x: String) -> String requires [] = x
api TaskApi {
  post "/tasks"
    -> String
  get "/tasks/:id"
    capture id: String via idCapture
    -> String
}
server S for TaskApi {
  createTask = createTask
  getTask = getTask
}
|}

let test_server_missing_handler () =
  assert_validation_error {|#lang tesl
module Foo exposing [S]
import Tesl.Prelude exposing [String]
api TaskApi {
  post "/tasks"
    -> String
}
server S for TaskApi {
  createTask = nonExistentHandler
}
|} "is not declared"

let test_server_missing_endpoint_binding () =
  assert_validation_error {|#lang tesl
module Foo exposing [S]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture idCapture: id: String using stringCodec
handler createTask(x: String) -> String requires [] = x
api TaskApi {
  post "/tasks"
    -> String
  get "/tasks/:id"
    capture id: String via idCapture
    -> String
}
server S for TaskApi {
  createTask = createTask
}
|} "missing 1 binding"

let test_server_sse_endpoint_does_not_require_binding () =
  assert_no_errors {|#lang tesl
module Foo exposing [S]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
database EventDatabase {
  backend postgres
  schema  "events"
  entities []
  postgres {
    database "demo"
    user     "demo"
    password "demo"
    host     "localhost"
    port     5432
    socket   ""
  }
}
type NoticeEvent
  = NoticeSent message:String
fn parseUserId(id: String) -> String =
  id
capture userIdCapture: String using stringCodec via parseUserId
channel NoticeEvents(userId: String) {
  database EventDatabase
  payload NoticeEvent
}
handler sendNotice() -> String requires [] =
  "queued"
api TaskApi {
  post "/send"
    -> String

  sse "/events/:userId"
    capture userId: String via userIdCapture
    subscribe NoticeEvents(userId)
}
server S for TaskApi {
  sendNotice = sendNotice
}
|}

let test_sse_endpoint_does_not_swallow_following_http_endpoint () =
  assert_no_errors {|#lang tesl
module Foo exposing [S]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
database EventDatabase {
  backend postgres
  schema  "events"
  entities []
  postgres {
    database "demo"
    user     "demo"
    password "demo"
    host     "localhost"
    port     5432
    socket   ""
  }
}
type NoticeEvent
  = Notice text:String
channel Notices(userId: String) {
  database EventDatabase
  payload  NoticeEvent
}
handler getValue() -> String requires [] = "ok"
api DemoApi {
  sse "/events/:userId"
    capture userId: String via stringCodec
    subscribe Notices(userId)
  get "/value"
    -> String
}
server S for DemoApi {
  getValue = getValue
}
|}

let test_imported_adt_constructors_are_visible () =
  let suffix = string_of_int (abs (Hashtbl.hash "imported_adt_ctors")) in
  let module_name = "TempImport" ^ suffix in
  let tmp_dir = Filename.get_temp_dir_name () in
  let import_path = Filename.concat tmp_dir ("temp-import" ^ suffix ^ ".tesl") in
  let main_path = Filename.concat tmp_dir ("temp-main-" ^ suffix ^ ".tesl") in
  let import_src = Printf.sprintf {|#lang tesl
module %s exposing [Status(..)]
type Status
  = Backlog
  | Todo
|} module_name in
  let main_src = Printf.sprintf {|#lang tesl
module Main exposing [value]
import %s exposing [Status(..)]
fn value() -> Status =
  Backlog
|} module_name in
  assert_no_compile_diagnostics_from_entry
    ~entry_path:main_path
    ~entry_src:main_src
    ~extra_files:[(import_path, import_src)]

(** Fix-11 §3.5: exhaustiveness checker now covers imported user-defined ADTs *)
let test_imported_adt_non_exhaustive_is_rejected () =
  let suffix = string_of_int (abs (Hashtbl.hash "imported_adt_exhaust_fail")) in
  let module_name = "TempColors" ^ suffix in
  let tmp_dir = Filename.get_temp_dir_name () in
  let import_path = Filename.concat tmp_dir ("temp-colors" ^ suffix ^ ".tesl") in
  let main_path = Filename.concat tmp_dir ("temp-main-" ^ suffix ^ ".tesl") in
  let import_src = Printf.sprintf {|#lang tesl
module %s exposing [Color(..)]
type Color
  = Red
  | Green
  | Blue
|} module_name in
  let main_src = Printf.sprintf {|#lang tesl
module Main exposing [describeColor]
import Tesl.Prelude exposing [String]
import %s exposing [Color(..)]
fn describeColor(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
|} module_name in
  (* Missing Blue — should be an error *)
  assert_compile_diagnostic_from_entry
    ~entry_path:main_path
    ~entry_src:main_src
    ~extra_files:[(import_path, import_src)]
    ~substr:"Blue"

let test_imported_adt_exhaustive_is_accepted () =
  let suffix = string_of_int (abs (Hashtbl.hash "imported_adt_exhaust_ok")) in
  let module_name = "TempShapes" ^ suffix in
  let tmp_dir = Filename.get_temp_dir_name () in
  let import_path = Filename.concat tmp_dir ("temp-shapes" ^ suffix ^ ".tesl") in
  let main_path = Filename.concat tmp_dir ("temp-main-" ^ suffix ^ ".tesl") in
  let import_src = Printf.sprintf {|#lang tesl
module %s exposing [Shape(..)]
type Shape
  = Circle
  | Square
  | Triangle
|} module_name in
  let main_src = Printf.sprintf {|#lang tesl
module Main exposing [describe]
import Tesl.Prelude exposing [String]
import %s exposing [Shape(..)]
fn describe(s: Shape) -> String =
  case s of
    Circle -> "circle"
    Square -> "square"
    Triangle -> "triangle"
|} module_name in
  (* All three variants covered — must pass *)
  assert_no_compile_diagnostics_from_entry
    ~entry_path:main_path
    ~entry_src:main_src
    ~extra_files:[(import_path, import_src)]

let test_fail_allows_interpolated_strings () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, String]
fn bad(source: String, rawPort: String) -> Int =
  fail 400 "invalid ${source} port value ${rawPort}; expected an integer"
|}

let test_server_extra_endpoint_binding () =
  assert_validation_error {|#lang tesl
module Foo exposing [S]
import Tesl.Prelude exposing [String]
handler createTask(x: String) -> String requires [] = x
api TaskApi {
  post "/tasks"
    -> String
}
server S for TaskApi {
  createTask = createTask
  unknownEndpoint = createTask
}
|} "binds extra endpoint"

let test_duplicate_function_import_rejected () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.String exposing [startsWith]
import Tesl.String exposing [startsWith]
|} "duplicate import `startsWith` from module `Tesl.String`"

let test_duplicate_adt_dotdot_import_rejected () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Bool, Bool(..)]
|} "cannot import both `Bool` and `Bool(..)` from module `Tesl.Prelude`"

(* ── 2. Field validation ─────────────────────────────────────────────────── *)

let test_valid_field_access () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
record Task {
  id: String
  title: String
}
fn getTitle(t: Task) -> String = t.title
|}

let test_invalid_field_access () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
record Task {
  id: String
  title: String
}
fn bad(t: Task) -> String = t.nonExistentField
|} "unknown field `nonExistentField`"

let test_case_pattern_field_access_validation () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
record Task {
  id: String
  title: String
}
fn bad(m: Maybe Task) -> String =
  case m of
    Nothing -> "none"
    Something task -> task.missing
|} "unknown field `missing`"

(* ── 3. Codec proof coverage ─────────────────────────────────────────────── *)

let test_codec_no_proof_fields_ok () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Task {
  id: String
  title: String
}
codec Task {
  toJson_forbidden
  fromJson [
    {
      id <- "id" with_codec stringCodec
      title <- "title" with_codec stringCodec
    }
  ]
}
|}

let test_codec_proof_with_via_ok () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
record SafeNote {
  title: String ::: SafeTitle title
}
check checkSafeTitle(s: String) -> s: String ::: SafeTitle s =
  if String.length s >= 1 then
    ok s ::: SafeTitle s
  else
    fail 400 "too short"
codec SafeNote {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via checkSafeTitle
    }
  ]
}
|}

let test_codec_proof_missing_via () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record SafeNote {
  title: String ::: SafeTitle title
}
codec SafeNote {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
    }
  ]
}
|} "has no `via` validation"

let test_codec_conjunctive_proof_requires_full_coverage () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record SafeNote {
  title: String ::: SafeTitle title && NonEmpty title
}
check checkSafeTitle(s: String) -> s: String ::: SafeTitle s =
  ok s ::: SafeTitle s
codec SafeNote {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via checkSafeTitle
    }
  ]
}
|} "not established by any `via` function"

let test_codec_conjunctive_proof_via_chain_ok () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record SafeNote {
  title: String ::: SafeTitle title && NonEmpty title
}
check checkSafeTitle(s: String) -> s: String ::: SafeTitle s =
  ok s ::: SafeTitle s
check checkNonEmpty(s: String) -> s: String ::: NonEmpty s =
  ok s ::: NonEmpty s
codec SafeNote {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via (checkSafeTitle && checkNonEmpty)
    }
  ]
}
|}

(* ── 4. Call-site proof satisfaction ────────────────────────────────────── *)

let test_call_with_checked_arg_ok () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, String]
check isPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "neg"
fn usePos(x: Int ::: Positive x) -> String = "ok"
fn main_fn(n: Int) -> String =
  let validated = isPos n
  usePos validated
|}

let test_call_literal_without_proof () =
  (* Integer literals now parse as valid proof subjects (subject = "42").
     Passing `42` to a proof-requiring fn still fails because `42` carries
     no proofs — error is now "does not statically satisfy declared proof `Positive 42`". *)
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, String]
fn usePos(x: Int ::: Positive x) -> String = "ok"
fn bad() -> String =
  usePos 42
|} "does not statically satisfy"

let test_cross_parameter_proof_mismatch () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, String]
check checkRange(lo: Int, hi: Int) -> lo: Int ::: ValidRange lo hi =
  ok lo ::: ValidRange lo hi
fn useRange(lo: Int ::: ValidRange lo hi, hi: Int) -> String = "ok"
fn bad(lo: Int, hi: Int, otherHi: Int) -> String =
  let checked = checkRange lo hi
  useRange checked otherHi
|} "does not statically satisfy"

let test_named_pack_call_site_propagation () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
record Task {
  id: String
}
fn fetchTask(id: String, task: Task) -> Task ? FromDb (Id == id) =
  task
fn processTask(t: Task::: FromDb (Id == id) t, id: String) -> String =
  "ok"
fn useTask(id: String, task: Task) -> String =
  let fetched = fetchTask id task
  processTask fetched id
|}

let test_local_declared_proof_mismatch_rejected () =
  assert_validation_error {|#lang tesl
module Foo exposing [useAdmin]
import Tesl.Prelude exposing [Int, String]
check checkIsPositive(n: Int) -> n: Int::: IsPositive n =
  if n > 0 then
    ok n::: IsPositive n
  else
    fail 400 "must be positive"
fn useAdmin(user: String::: IsAdmin user) -> String =
  user
fn demo() -> String =
  let admin: Int::: IsAdmin admin = checkIsPositive 5
  "nope"
|} "let binding `admin` declares proof `IsAdmin admin`"

let test_imported_capability_alias_covers_builtin_requirement () =
  let temp_dir = Filename.concat (Filename.get_temp_dir_name ()) "tesl-cap-alias-test" in
  if not (Sys.file_exists temp_dir) then Unix.mkdir temp_dir 0o755;
  let caps_path = Filename.concat temp_dir "caps.tesl" in
  let entry_path = Filename.concat temp_dir "main.tesl" in
  let caps_src = {|#lang tesl
module Caps exposing [localRead]
import Tesl.DB exposing [dbRead]
capability localRead implies dbRead
|} in
  let entry_src = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Caps exposing [localRead]
entity Thing table "things" primaryKey id {
  id: String
}
fn readThing(id: String) -> Maybe Thing
  requires [localRead] =
  selectOne t from Thing where t.id == id
|} in
  assert_no_compile_diagnostics_from_entry
    ~entry_path
    ~entry_src
    ~extra_files:[(caps_path, caps_src)]

(* ── 5. ForAll proof propagation ─────────────────────────────────────────── *)

let test_forall_with_correct_check () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
check isPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "neg"
fn filterPos(xs: List Int) -> List Int ::: ForAll Positive =
  List.filterCheck isPos xs
|}

let test_forall_mismatch () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
check isPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "neg"
check isSmall(n: Int) -> n: Int ::: Small n =
  if n < 100 then
    ok n ::: Small n
  else
    fail 400 "big"
fn filterPositive(xs: List Int) -> List Int ::: ForAll Positive =
  List.filterCheck isSmall xs
|} "missing `[Positive]`"

let test_forall_call_site_propagation () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
check isPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "neg"
fn filterPos(xs: List Int) -> List Int ::: ForAll Positive =
  List.filterCheck isPos xs
fn consume(xs: List Int ::: ForAll Positive xs) -> Int = 0
fn ok_use(xs: List Int) -> Int =
  let positives = filterPos xs
  consume positives
|}

let test_forall_filtercheck_preserves_existing_proofs () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
check isPositive(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
fn filterPositive(xs: List Int) -> List Int ::: ForAll Positive =
  List.filterCheck isPositive xs
|}

let test_forall_check_fn_missing_predicate () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
check isSmall(n: Int) -> n: Int ::: Small n =
  if n < 100 then
    ok n ::: Small n
  else
    fail 400 "big"
fn filterPositiveAndSmall(xs: List Int) -> List Int ::: ForAll (Positive && Small) =
  List.filterCheck isSmall xs
|} "missing `[Positive]`"

(* ── ForAll soundness: Hole 1 – direct pass-through ─────────────────────── *)

let test_forall_direct_passthrough_wrong_pred () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
check isPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "neg"
fn passThrough(xs: List Int ::: ForAll IsPositive xs) -> List Int ? ForAll (IsPositive && IsLarge) =
  xs
|} "return value `xs` carries ForAll"

let test_forall_direct_passthrough_same_pred_ok () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
fn identity(xs: List Int ::: ForAll IsPositive xs) -> List Int ? ForAll IsPositive =
  xs
|}

let test_forall_direct_passthrough_subset_ok () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
fn subset(xs: List Int ::: ForAll (IsPositive && IsLarge) xs) -> List Int ? ForAll IsPositive =
  xs
|}

(* ── ForAll soundness: Hole 2 – let-bound filterCheck result ─────────────── *)

let test_forall_let_bound_filtercheck_wrong_pred () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
check isSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "big"
fn f(xs: List Int) -> List Int ? ForAll IsPositive =
  let result = List.filterCheck isSmall xs
  result
|} "return value `result` carries ForAll"

let test_forall_let_bound_filtercheck_correct_pred_ok () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
check isPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "neg"
fn f(xs: List Int) -> List Int ? ForAll IsPositive =
  let result = List.filterCheck isPos xs
  result
|}

(* ── Capability enforcement ──────────────────────────────────────────────── *)

let test_handler_undeclared_capability () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
entity Thing table "things" primaryKey id {
  id: String
}
handler createThing(id: String) -> String requires [] =
  insert Thing { id: id }
|} "does not declare the required capabilities"

let test_handler_wrong_capability_declared () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbRead, dbWrite]
entity Thing table "things" primaryKey id {
  id: String
}
handler createThing(id: String) -> String requires [dbRead] =
  insert Thing { id: id }
|} "does not declare the required capabilities"

let test_handler_correct_capability_declared () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
entity Thing table "things" primaryKey id {
  id: String
}
handler createThing(id: String) -> String requires [dbWrite] =
  insert Thing { id: id }
|}

(* ── Cross-module parse error propagation ───────────────────────────────── *)

let test_import_parse_error_propagated () =
  let temp_dir = Filename.concat (Filename.get_temp_dir_name ()) "tesl-import-parse-err" in
  if not (Sys.file_exists temp_dir) then Unix.mkdir temp_dir 0o755;
  let bad_path = Filename.concat temp_dir "BadModule.tesl" in
  let entry_path = Filename.concat temp_dir "main.tesl" in
  let bad_src = {|#lang tesl
module BadModule exposing []
this is not valid tesl syntax !@#$
|} in
  let entry_src = {|#lang tesl
module Main exposing []
import BadModule exposing []
|} in
  assert_compile_diagnostic_from_entry
    ~entry_path
    ~entry_src
    ~extra_files:[(bad_path, bad_src)]
    ~substr:"BadModule"

(* ── 6. Exists validation ────────────────────────────────────────────────── *)

let test_set_forall_call_site_propagation () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Set exposing [Set, Set.fromList, Set.filterCheck, Set.size]
fact IsPositive (n: Int)
check isPositive(n: Int) -> n: Int::: IsPositive n =
  if n > 0 then
    ok n::: IsPositive n
  else
    fail 400 "neg"
fn countPositive(s: Set Int::: ForAll (IsPositive) s) -> Int =
  Set.size s
fn run() -> Int =
  let filtered = Set.filterCheck isPositive (Set.fromList [1, 2, 3, -1, -2])
  countPositive filtered
|}

let test_exists_function_has_exists_body () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn genToken() -> exists tokenId: String => tokenId: String ::: IsToken tokenId =
  exists tokenId =>
    tokenId
|}

let test_exists_missing_body () =
  assert_validation_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn bad() -> exists name: String => name: String ::: IsToken name =
  "token-123"
|} "no exists expression"

let test_exists_different_witness_name_is_ok () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn bad() -> exists tokenId: String => tokenId: String ::: IsToken tokenId =
  exists otherId =>
    otherId
|}

(* ── 7. Integration with Compile.check_source ───────────────────────────── *)

let test_validation_is_wired_into_top_level_diagnostics () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
record Task {
  title: String
}
fn bad(t: Task) -> String = t.missing
|} in
  let diags = Compile.check_source "<test>" src in
  let found = List.exists (fun (d : Compile.diagnostic) -> d.source = "validation") diags in
  Alcotest.(check bool) "validation diagnostic emitted" true found

let test_init_telemetry_keywords_typecheck () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Bool(..)]
import Tesl.Telemetry exposing [initTelemetry]
main {
  initTelemetry service "my-service" endpoint "in-memory" console True
}
|}

let test_with_transaction_returns_body_type () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn wrap(n: Int) -> Int =
  with transaction {
    n
  }
|}

let test_keyword_type_argument_from_keyword_token_typechecks () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Time exposing [PosixMillis]
record Reminder {
  id: String
  dueAt: Maybe PosixMillis
}
|}

let test_let_underscore_binding_typechecks () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn keep(n: Int) -> Int =
  let _ = n
  n
|}

let test_with_transaction_multiline_update_sequence_typechecks () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
entity Thing table "things" primaryKey id {
  id: String
  parentId: String
}
fn relink(id: String, parentId: String) -> String requires [dbWrite] =
  with transaction {
    update t in Thing
      where t.id == id
      set t.parentId = parentId
    id
  }
|}

let test_call_before_with_block_typechecks () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
record Session {
  userId: String
}
fn authorize(userId: String, orgId: String) -> String =
  userId
handler demo(
    session: Session,
    orgId: String)
  -> String
  requires [] =
  let adminUserId = authorize session.userId orgId
  with transaction {
    orgId
  }
|}

let test_stacked_case_labels_typecheck () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
type Status =
  | Backlog
  | Todo
  | InProgress
  | Done
fn classify(status: Status) -> Int =
  case status of
    Backlog ->
    Todo ->
    InProgress ->
      1
    Done ->
      2
|}

let test_serve_static_clause_typechecks () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing [S]
import Tesl.Prelude exposing [Int]
handler getValue() -> Int requires [] = 1
api TaskApi {
  get "/value"
    -> Int
}
server S for TaskApi {
  getValue = getValue
}
main {
  serve S on 8080 with capabilities [] static "public"
}
|}

let test_sql_reference_queries_typecheck () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List, String, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
entity Product table "products" primaryKey id {
  id: String
  category: String
  price: Int
}
fn findCheapInCategory(cat: String, maxPrice: Int) -> List Product requires [dbRead] =
  select p from Product where p.category == cat && p.price <= maxPrice
fn findFeatured(cat1: String, cat2: String) -> List Product requires [dbRead] =
  select p from Product where p.category == cat1 || p.category == cat2
fn removeProduct(id: String) -> Unit requires [dbWrite] =
  delete p from Product where p.id == id
fn expensiveProducts(minPrice: Int) -> List Product requires [dbRead] =
  select p from Product where p.price > minPrice
fn discounted(maxPrice: Int) -> List Product requires [dbRead] =
  select p from Product where p.price < maxPrice
fn notInCategory(cat: String) -> List Product requires [dbRead] =
  select p from Product where p.category != cat
fn countInCategory(cat: String) -> Int requires [dbRead] =
  selectCount p from Product where p.category == cat
fn sumInCategory(cat: String) -> Int requires [dbRead] =
  selectSum p.price from Product where p.category == cat
|}

let test_compound_named_pack_patterns_typecheck () =
  assert_no_compile_diagnostics {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, String, Fact, detachFact]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
fact IsAdmin (user: String)
check checkIsPositive(n: Int) -> n: Int::: IsPositive n =
  if n > 0 then
    ok n::: IsPositive n
  else
    fail 400 "must be positive"
check checkIsSmall(n: Int) -> n: Int::: IsSmall n =
  if n < 100 then
    ok n::: IsSmall n
  else
    fail 400 "must be less than 100"
establish provePositive (n: Int) -> Fact (IsPositive n) =
  IsPositive n
fn makePositiveAndSmall(n: Int::: IsPositive n && IsSmall n) -> Int ? IsPositive && IsSmall =
  n
fn makeWithAdminCargo(n: Int::: IsPositive n, user: String::: IsAdmin user)
  -> Int ? IsPositive::: IsAdmin user =
  n::: detachFact user
fn makeWithProofOnReturnLine(n: Int, user: String::: IsAdmin user)
  -> Int ? IsPositive::: IsAdmin user =
  let p = provePositive n
  n::: p && detachFact user
fn useCombinedChecks() -> Int =
  let ps: Int::: IsPositive ps && IsSmall ps = check (checkIsPositive && checkIsSmall) 5
  makePositiveAndSmall ps
|}

let test_compound_fact_param_requires_all_conjuncts () =
  assert_validation_error {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Fact]

fact IsPositive (n: Int)
fact IsEven (n: Int)

establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n

fn needsBoth(n: Int, proof: Fact (IsPositive n && IsEven n)) -> Int =
  n

fn bad(x: Int) -> Int =
  needsBoth x (provePositive x)
|} "Fact (IsPositive x && IsEven x)"

let test_adt_constructor_same_name_as_type_rejected () =
  assert_validation_error {|#lang tesl
module Test exposing []
type Box a
  = Box value:a
|} "same name as its type"

let test_adt_constructor_different_name_ok () =
  assert_no_compile_diagnostics {|#lang tesl
module Test exposing []
type Box a
  = MkBox value:a
|}

let test_all_lesson_files_no_crash () =
  let root = (match Sys.getenv_opt "TESL_REPO_ROOT" with
    | Some p when p <> "" -> p
    | _ ->
        let rec find dir =
          let candidate = Filename.concat dir "compiler" in
          if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
          then dir
          else let parent = Filename.dirname dir in
               if parent = dir then Filename.current_dir_name else find parent
        in
        find (Filename.dirname Sys.executable_name))
  in
  let learn_root = Filename.concat root "example/learn" in
  let files = try Sys.readdir learn_root |> Array.to_list
              |> List.filter (fun f -> let n = String.length f in n >= 5 && String.sub f (n - 5) 5 = ".tesl")
              with Sys_error _ -> [] in
  List.iter (fun fname ->
    let path = Filename.concat learn_root fname in
    let src = try In_channel.with_open_text path In_channel.input_all with Sys_error _ -> "" in
    if src <> "" then
      match Parser.parse_module path src with
      | Err _ -> ()
      | Ok m -> ignore (Validation.check_module m)
  ) files

(* ── Proof enforcement in test blocks (critical-review-17 §2.1) ──────── *)

let test_proof_bypass_in_test_block_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String]

fact IsAdult (age: Int)

check validateAge(age: Int) -> age: Int::: IsAdult age =
  if age >= 18 then
    ok age::: IsAdult age
  else
    fail 400 "not adult"

fn needsAdult(age: Int::: IsAdult age) -> String =
  "allowed"

test "bypass" {
  let raw = 25
  expect needsAdult raw == "allowed"
}
|} "does not statically satisfy declared proof"

let test_proof_proper_check_in_test_block_ok () =
  assert_no_errors {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String]

fact IsAdult (age: Int)

check validateAge(age: Int) -> age: Int::: IsAdult age =
  if age >= 18 then
    ok age::: IsAdult age
  else
    fail 400 "not adult"

fn needsAdult(age: Int::: IsAdult age) -> String =
  "allowed"

test "proper" {
  let age = 25
  let checked = check validateAge age
  expect needsAdult checked == "allowed"
}
|}

let test_proof_literal_arg_to_proof_fn_rejected () =
  (* Integer literal `42` now has a trackable subject "42" but still carries
     no proofs. The error is "does not statically satisfy declared proof `IsPositive 42`". *)
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String]

fact IsPositive (n: Int)

fn needsPositive(n: Int::: IsPositive n) -> Int = n

test "literal" {
  expect needsPositive 42 == 42
}
|} "does not statically satisfy"

let test_named_pack_declared_proof_mismatch_in_test_block_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact IsPositive (n: Int)
fact IsAdmin (user: String)

check checkIsAdmin(user: String) -> user: String ::: IsAdmin user =
  if user == "admin" then
    ok user ::: IsAdmin user
  else
    fail 401 "admin only"

establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n

fn makeWithProofOnReturnLine(n: Int, user: String ::: IsAdmin user)
  -> Int ? IsPositive ::: IsAdmin user =
  let p = provePositive n
  n ::: p && detachFact user

test "declared proof mismatch" {
  let userId = "admin"
  let userId2 = "admin2"
  let userId_with_Proof: String ::: IsAdmin userId_with_Proof = check checkIsAdmin userId
  let result: Int ::: IsPositive result && IsAdmin userId2 = makeWithProofOnReturnLine 42 userId_with_Proof
  expect result == 42
}
|} "let binding `result` declares proof"

let test_named_pack_declared_proof_in_test_block_ok () =
  assert_no_errors {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact IsPositive (n: Int)
fact IsAdmin (user: String)

check checkIsAdmin(user: String) -> user: String ::: IsAdmin user =
  if user == "admin" then
    ok user ::: IsAdmin user
  else
    fail 401 "admin only"

establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n

fn makeWithProofOnReturnLine(n: Int, user: String ::: IsAdmin user)
  -> Int ? IsPositive ::: IsAdmin user =
  let p = provePositive n
  n ::: p && detachFact user

test "declared proof ok" {
  let userId = "admin"
  let userId_with_Proof: String ::: IsAdmin userId_with_Proof = check checkIsAdmin userId
  let result: Int ::: IsPositive result && IsAdmin userId_with_Proof = makeWithProofOnReturnLine 42 userId_with_Proof
  expect result == 42
}
|}

let test_named_pack_db_key_alias_in_test_block_ok () =
  assert_no_compile_diagnostics {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [String]
record Task {
  id: String
}
fn fetchTask(id: String, task: Task) -> Task ? FromDb (Id == id) =
  task

test "named db key alias ok" {
  let queryId = "task-1"
  let task = Task { id: queryId }
  let fetched: Task ::: FromDb (Id == queryId) fetched = fetchTask queryId task
  expect fetched.id == "task-1"
}
|}

(* ── Inline-literal proof-subject regression tests ───────────────────────
   The compiler must reject inline literals (and complex expressions) at
   proof-subject positions of check function calls inside test blocks.
   Without this check the code would silently fail at runtime because bare
   Racket values do not carry stable gensym identities across function calls.
   ──────────────────────────────────────────────────────────────────────── *)

(** Return-binding position — single-param check — inline Int literal. *)
let test_inline_lit_return_binding_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact ValidScore (n: Int)

check checkScore(n: Int) -> n: Int ::: ValidScore n =
  if n >= 0 && n <= 100 then
    ok n ::: ValidScore n
  else
    fail 400 "bad score"

fn requiresScore(n: Int ::: ValidScore n) -> String = "ok"

test "inline literal rejected" {
  let s = checkScore 42
  expect requiresScore s == "ok"
}
|} "inline literals cannot be tracked as proof subjects in test blocks"

(** Return-binding position — inline String literal. *)
let test_inline_string_lit_return_binding_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact NonEmpty (s: String)

check checkNonEmpty(s: String) -> s: String ::: NonEmpty s =
  if s == "" then
    fail 400 "empty"
  else
    ok s ::: NonEmpty s

fn requiresNonEmpty(s: String ::: NonEmpty s) -> String = s

test "inline string literal rejected" {
  let r = checkNonEmpty "hello"
  expect requiresNonEmpty r == "hello"
}
|} "inline literals cannot be tracked as proof subjects in test blocks"

(** Cross-parameter position — inline Int literal. *)
let test_inline_lit_cross_param_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact InBounds (lo: Int) (hi: Int) (n: Int)

check checkInBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if n >= lo && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "out of bounds"

fn requiresInBounds(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> String =
  "ok"

test "inline cross-param rejected" {
  let lo = 1
  let hi = 10
  let r = checkInBounds lo hi 5
  expect requiresInBounds lo hi r == "ok"
}
|} "inline literals cannot be tracked as proof subjects in test blocks"

(** Cross-parameter position — inline literal for lo and hi. *)
let test_inline_lit_cross_param_lo_hi_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact InBounds (lo: Int) (hi: Int) (n: Int)

check checkInBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if n >= lo && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "out of bounds"

fn requiresInBounds(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> String =
  "ok"

test "inline cross-param lo hi rejected" {
  let n = 5
  let r = checkInBounds 1 10 n
  expect requiresInBounds 1 10 r == "ok"
}
|} "inline literals cannot be tracked as proof subjects in test blocks"

(** All three positions inline — multiple errors emitted. *)
let test_inline_lit_all_positions_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact InBounds (lo: Int) (hi: Int) (n: Int)

check checkInBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if n >= lo && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "out of bounds"

fn requiresInBounds(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> String =
  "ok"

test "all inline rejected" {
  let r = checkInBounds 1 10 5
  expect requiresInBounds 1 10 r == "ok"
}
|} "inline literals cannot be tracked as proof subjects in test blocks"

(** Happy path — all proof-subject arguments are let-bound variables. *)
let test_let_bound_proof_args_ok () =
  assert_no_errors {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact InBounds (lo: Int) (hi: Int) (n: Int)

check checkInBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if n >= lo && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "out of bounds"

fn requiresInBounds(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> String =
  "ok"

test "let-bound args ok" {
  let lo = 1
  let hi = 10
  let n = 5
  let r = checkInBounds lo hi n
  expect requiresInBounds lo hi r == "ok"
}
|}

(** Inline literal in test block for a DIFFERENT (non-subject) argument
    must NOT produce a false positive. *)
let test_non_subject_inline_arg_ok () =
  assert_no_errors {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact ValidScore (n: Int)

check checkScore(n: Int) -> n: Int ::: ValidScore n =
  if n >= 0 && n <= 100 then
    ok n ::: ValidScore n
  else
    fail 400 "bad score"

fn show(n: Int ::: ValidScore n, label: String) -> String = label

test "non-subject inline arg ok" {
  let n = 42
  let s = checkScore n
  expect show s "x" == "x"
}
|}

(** Happy path — single-param check, the argument is let-bound. *)
let test_single_param_let_bound_ok () =
  assert_no_errors {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact]

fact ValidScore (n: Int)

check checkScore(n: Int) -> n: Int ::: ValidScore n =
  if n >= 0 && n <= 100 then
    ok n ::: ValidScore n
  else
    fail 400 "bad score"

fn requiresScore(n: Int ::: ValidScore n) -> String = "ok"

test "let-bound single-param ok" {
  let n = 42
  let s = checkScore n
  expect requiresScore s == "ok"
}
|}

(* ── Capability enforcement regression tests (critical-review-17 §2.2) ── *)

let test_capability_transitive_fn_call_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int]

capability time

fn getTime() -> Int requires [time] =
  42

fn noTimeFn() -> Int =
  getTime()
|} "uses privileged operations and callees requiring [time]"

let test_capability_transitive_fn_call_declared_ok () =
  assert_no_errors {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int]

capability time

fn getTime() -> Int requires [time] =
  42

fn hasTimeFn() -> Int requires [time] =
  getTime()
|}

let test_capability_chain_three_deep_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int]

capability time

fn a() -> Int requires [time] = 42
fn b() -> Int requires [time] = a()
fn c() -> Int = b()
|} "uses privileged operations and callees requiring [time]"

let test_capability_multiple_missing_rejected () =
  assert_validation_error {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String]

capability time
capability audit

fn needsBoth() -> Int requires [time, audit] = 42
fn hasSome() -> Int requires [time] = needsBoth()
|} "requiring [audit]"

let test_capability_no_false_positive_on_plain_fn () =
  assert_no_errors {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int]

fn add(a: Int, b: Int) -> Int = a + b
fn double(x: Int) -> Int = add x x
|}

(* ── Multi-line pipeline regression tests (critical-review-17 §2.3) ──── *)

let test_multiline_pipeline_typechecks () =
  assert_no_compile_diagnostics {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, Bool(..), List]
import Tesl.List exposing [List.map, List.filter]

fn double(x: Int) -> Int = x * 2
fn isEven(x: Int) -> Bool = x % 2 == 0

fn process(xs: List Int) -> List Int =
  xs
    |> List.filter isEven
    |> List.map double
|}

(* ── Polymorphic functions regression tests (critical-review-17 §2.4) ── *)

let test_polymorphic_identity_typechecks () =
  assert_no_compile_diagnostics {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]

fn identity(x: a) -> a = x

fn use() -> Bool =
  let i = identity 42
  let s = identity "hello"
  i == 42
|}

let test_polymorphic_pair_typechecks () =
  assert_no_compile_diagnostics {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Tuple exposing [Tuple2]

fn pair(a: x, b: y) -> Tuple2 x y =
  Tuple2 a b

fn use() -> Tuple2 Int String =
  pair 42 "hello"
|}

(* ── Division proof enforcement ────────────────────────────────────────── *)

let test_div_by_zero_literal_rejected () =
  assert_validation_error {|#lang tesl
module T exposing [f]
import Tesl.Prelude exposing [Int]

fn f(x: Int) -> Int =
  x / 0
|} "division by zero"

let test_mod_by_zero_literal_rejected () =
  assert_validation_error {|#lang tesl
module T exposing [f]
import Tesl.Prelude exposing [Int]

fn f(x: Int) -> Int =
  x % 0
|} "division by zero"

let test_div_by_nonzero_literal_ok () =
  assert_no_compile_diagnostics {|#lang tesl
module T exposing [f]
import Tesl.Prelude exposing [Int]

fn f(x: Int) -> Int =
  x / 42
|}

let test_div_by_variable_without_proof_rejected () =
  assert_validation_error {|#lang tesl
module T exposing [f]
import Tesl.Prelude exposing [Int]

fn f(x: Int, y: Int) -> Int =
  x / y
|} "IsNonZero"

let test_div_by_variable_with_proof_ok () =
  assert_no_compile_diagnostics {|#lang tesl
module T exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.nonZero, Int.divide]

fn f(x: Int, y: Int) -> Int =
  let safe = check Int.nonZero y
  Int.divide x safe
|}

let test_float_div_by_nonzero_literal_ok () =
  assert_no_compile_diagnostics {|#lang tesl
module T exposing [f]
import Tesl.Prelude exposing [Int]

fn f(x: Int) -> Int =
  x / 180
|}

let test_float_div_by_zero_float_literal_rejected () =
  assert_validation_error {|#lang tesl
module T exposing [f]
import Tesl.Prelude exposing [Int]

fn f(x: Int) -> Int =
  x / 0
|} "division by zero"

let test_div_inside_constructor_rejected () =
  assert_validation_error {|#lang tesl
module T exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]

fn f(x: Int, y: Int) -> Maybe Int =
  Something (x / y)
|} "IsNonZero"

let () =
  Alcotest.run "Validation" [
    "server-bindings", [
      Alcotest.test_case "valid bindings" `Quick test_server_bindings_ok;
      Alcotest.test_case "missing handler" `Quick test_server_missing_handler;
      Alcotest.test_case "missing endpoint binding" `Quick test_server_missing_endpoint_binding;
      Alcotest.test_case "sse endpoint ignored for bindings" `Quick test_server_sse_endpoint_does_not_require_binding;
      Alcotest.test_case "sse does not swallow following http endpoint" `Quick test_sse_endpoint_does_not_swallow_following_http_endpoint;
      Alcotest.test_case "imported adt constructors are visible" `Quick test_imported_adt_constructors_are_visible;
      Alcotest.test_case "imported adt non-exhaustive is rejected" `Quick test_imported_adt_non_exhaustive_is_rejected;
      Alcotest.test_case "imported adt exhaustive is accepted" `Quick test_imported_adt_exhaustive_is_accepted;
      Alcotest.test_case "fail allows interpolated strings" `Quick test_fail_allows_interpolated_strings;
      Alcotest.test_case "extra endpoint binding" `Quick test_server_extra_endpoint_binding;
    ];
    "import-validation", [
      Alcotest.test_case "duplicate function import" `Quick test_duplicate_function_import_rejected;
      Alcotest.test_case "adt and dotdot import overlap" `Quick test_duplicate_adt_dotdot_import_rejected;
    ];
    "field-validation", [
      Alcotest.test_case "valid field access" `Quick test_valid_field_access;
      Alcotest.test_case "invalid field" `Quick test_invalid_field_access;
      Alcotest.test_case "case pattern field access" `Quick test_case_pattern_field_access_validation;
    ];
    "codec-proofs", [
      Alcotest.test_case "no proof fields ok" `Quick test_codec_no_proof_fields_ok;
      Alcotest.test_case "proof with via ok" `Quick test_codec_proof_with_via_ok;
      Alcotest.test_case "proof missing via" `Quick test_codec_proof_missing_via;
      Alcotest.test_case "conjunctive proof coverage" `Quick test_codec_conjunctive_proof_requires_full_coverage;
      Alcotest.test_case "conjunctive via chain ok" `Quick test_codec_conjunctive_proof_via_chain_ok;
    ];
    "call-site-proofs", [
      Alcotest.test_case "checked arg ok" `Quick test_call_with_checked_arg_ok;
      Alcotest.test_case "literal without proof" `Quick test_call_literal_without_proof;
      Alcotest.test_case "cross-parameter mismatch" `Quick test_cross_parameter_proof_mismatch;
      Alcotest.test_case "named-pack propagation" `Quick test_named_pack_call_site_propagation;
      Alcotest.test_case "local declared proof mismatch" `Quick test_local_declared_proof_mismatch_rejected;
      Alcotest.test_case "imported capability alias covers builtin requirement" `Quick test_imported_capability_alias_covers_builtin_requirement;
    ];
    "forall", [
      Alcotest.test_case "filterCheck correct" `Quick test_forall_with_correct_check;
      Alcotest.test_case "filterCheck mismatch" `Quick test_forall_mismatch;
      Alcotest.test_case "call-site propagation" `Quick test_forall_call_site_propagation;
      Alcotest.test_case "filterCheck preserves existing proofs" `Quick test_forall_filtercheck_preserves_existing_proofs;
      Alcotest.test_case "set call-site propagation" `Quick test_set_forall_call_site_propagation;
      Alcotest.test_case "check fn missing predicate is error" `Quick test_forall_check_fn_missing_predicate;
      Alcotest.test_case "direct passthrough wrong pred is error" `Quick test_forall_direct_passthrough_wrong_pred;
      Alcotest.test_case "direct passthrough same pred ok" `Quick test_forall_direct_passthrough_same_pred_ok;
      Alcotest.test_case "direct passthrough subset ok" `Quick test_forall_direct_passthrough_subset_ok;
      Alcotest.test_case "let-bound filterCheck wrong pred is error" `Quick test_forall_let_bound_filtercheck_wrong_pred;
      Alcotest.test_case "let-bound filterCheck correct pred ok" `Quick test_forall_let_bound_filtercheck_correct_pred_ok;
    ];
    "capabilities", [
      Alcotest.test_case "handler undeclared capability" `Quick test_handler_undeclared_capability;
      Alcotest.test_case "handler wrong capability declared" `Quick test_handler_wrong_capability_declared;
      Alcotest.test_case "handler correct capability declared" `Quick test_handler_correct_capability_declared;
    ];
    "cross-module-errors", [
      Alcotest.test_case "import parse error propagated" `Quick test_import_parse_error_propagated;
    ];
    "exists", [
      Alcotest.test_case "exists body present" `Quick test_exists_function_has_exists_body;
      Alcotest.test_case "exists body missing" `Quick test_exists_missing_body;
      Alcotest.test_case "exists different witness name ok" `Quick test_exists_different_witness_name_is_ok;
    ];
    "adt-names", [
      Alcotest.test_case "constructor same name as type rejected" `Quick test_adt_constructor_same_name_as_type_rejected;
      Alcotest.test_case "constructor different name ok" `Quick test_adt_constructor_different_name_ok;
    ];
    "proof-enforcement-test-blocks", [
      Alcotest.test_case "bypass proof in test block rejected" `Quick test_proof_bypass_in_test_block_rejected;
      Alcotest.test_case "proper check in test block ok" `Quick test_proof_proper_check_in_test_block_ok;
      Alcotest.test_case "literal arg to proof fn rejected" `Quick test_proof_literal_arg_to_proof_fn_rejected;
      Alcotest.test_case "named-pack declared proof mismatch rejected" `Quick test_named_pack_declared_proof_mismatch_in_test_block_rejected;
      Alcotest.test_case "named-pack declared proof ok" `Quick test_named_pack_declared_proof_in_test_block_ok;
      Alcotest.test_case "named-pack db key alias ok" `Quick test_named_pack_db_key_alias_in_test_block_ok;
      Alcotest.test_case "inline Int literal at return-binding pos rejected" `Quick test_inline_lit_return_binding_rejected;
      Alcotest.test_case "inline String literal at return-binding pos rejected" `Quick test_inline_string_lit_return_binding_rejected;
      Alcotest.test_case "inline literal at cross-param (n) rejected" `Quick test_inline_lit_cross_param_rejected;
      Alcotest.test_case "inline literal at cross-param (lo/hi) rejected" `Quick test_inline_lit_cross_param_lo_hi_rejected;
      Alcotest.test_case "inline literals at all subject positions rejected" `Quick test_inline_lit_all_positions_rejected;
      Alcotest.test_case "let-bound proof-subject args ok" `Quick test_let_bound_proof_args_ok;
      Alcotest.test_case "non-subject inline arg is not a false positive" `Quick test_non_subject_inline_arg_ok;
      Alcotest.test_case "single-param let-bound ok" `Quick test_single_param_let_bound_ok;
    ];
    "capability-transitive", [
      Alcotest.test_case "transitive fn call rejected" `Quick test_capability_transitive_fn_call_rejected;
      Alcotest.test_case "transitive fn call declared ok" `Quick test_capability_transitive_fn_call_declared_ok;
      Alcotest.test_case "chain three deep rejected" `Quick test_capability_chain_three_deep_rejected;
      Alcotest.test_case "multiple missing rejected" `Quick test_capability_multiple_missing_rejected;
      Alcotest.test_case "no false positive on plain fn" `Quick test_capability_no_false_positive_on_plain_fn;
    ];
    "multiline-pipeline", [
      Alcotest.test_case "multi-line pipeline typechecks" `Quick test_multiline_pipeline_typechecks;
    ];
    "polymorphic-functions", [
      Alcotest.test_case "polymorphic identity typechecks" `Quick test_polymorphic_identity_typechecks;
      Alcotest.test_case "polymorphic pair typechecks" `Quick test_polymorphic_pair_typechecks;
    ];
    "division-proof", [
      Alcotest.test_case "div by zero literal rejected" `Quick test_div_by_zero_literal_rejected;
      Alcotest.test_case "mod by zero literal rejected" `Quick test_mod_by_zero_literal_rejected;
      Alcotest.test_case "div by nonzero literal ok" `Quick test_div_by_nonzero_literal_ok;
      Alcotest.test_case "div by variable without proof rejected" `Quick test_div_by_variable_without_proof_rejected;
      Alcotest.test_case "div by variable with proof ok" `Quick test_div_by_variable_with_proof_ok;
      Alcotest.test_case "float div by nonzero literal ok" `Quick test_float_div_by_nonzero_literal_ok;
      Alcotest.test_case "float div by zero literal rejected" `Quick test_float_div_by_zero_float_literal_rejected;
      Alcotest.test_case "div inside constructor rejected" `Quick test_div_inside_constructor_rejected;
    ];
    "integration", [
      Alcotest.test_case "validation wired into compile diagnostics" `Quick test_validation_is_wired_into_top_level_diagnostics;
      Alcotest.test_case "initTelemetry keywords typecheck" `Quick test_init_telemetry_keywords_typecheck;
      Alcotest.test_case "with transaction returns body type" `Quick test_with_transaction_returns_body_type;
      Alcotest.test_case "keyword type arg from keyword token typechecks" `Quick test_keyword_type_argument_from_keyword_token_typechecks;
      Alcotest.test_case "let underscore binding typechecks" `Quick test_let_underscore_binding_typechecks;
      Alcotest.test_case "with transaction multiline update sequence typechecks" `Quick test_with_transaction_multiline_update_sequence_typechecks;
      Alcotest.test_case "call before with block typechecks" `Quick test_call_before_with_block_typechecks;
      Alcotest.test_case "stacked case labels typecheck" `Quick test_stacked_case_labels_typecheck;
      Alcotest.test_case "serve static clause typechecks" `Quick test_serve_static_clause_typechecks;
      Alcotest.test_case "sql reference queries typecheck" `Quick test_sql_reference_queries_typecheck;
      Alcotest.test_case "compound named-pack patterns typecheck" `Quick test_compound_named_pack_patterns_typecheck;
      Alcotest.test_case "compound Fact param requires all conjuncts" `Quick test_compound_fact_param_requires_all_conjuncts;
      Alcotest.test_case "all lessons don't crash" `Quick test_all_lesson_files_no_crash;
    ];
  ]
