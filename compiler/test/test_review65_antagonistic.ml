(** Antagonistic regression tests for Critical Review 65.

    This review covers two classes of bugs where the compiler silently accepted
    invalid code that later produced Racket runtime errors in nix-flake installs:

    A. Stdlib function used without the required import
       (List.head, Dict.lookup, String.length, etc.)

       Bug: make_stdlib_env() always includes all stdlib functions so the type
       checker accepted the code, but the emitter needs an explicit import to
       generate the Racket `(only-in tesl/tesl/list ...)` binding.  Without it
       the generated Racket references an unbound identifier.

    B. Local ADT constructor name conflicts with an imported stdlib ADT constructor
       (e.g. defining type Status = Ok ... while also importing Tesl.Result exposing
       [Result(..)])

       Bug: imported_plain_exposed_ctor_entries skipped all Tesl.* imports, so the
       existing check_imported_exposed_type_and_ctor_conflicts never saw the conflict.

    Test groups:
      SI — stdlib import required (basic cases)
      SM — stdlib import: module-level granularity
      SE — stdlib import: exposing list granularity
      SA — stdlib import: accepted cases
      SC — stdlib constructor conflict
      SN — stdlib constructor: accepted cases (no conflict)
      SX — extended / similar-looking scenarios *)

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
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r65" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then begin
          Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end else
          Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

(* ── R65_SI — Basic: stdlib function used without any import ─────────────── *)

let test_R65_SI01_list_head_without_import_rejected () =
  should_fail "requires.*import Tesl\\.List\\|import Tesl\\.List" {|
#lang tesl
module R65Si01 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.Maybe exposing [Maybe]
fn test(xs: List Int) -> Maybe Int =
  List.head xs
|}

let test_R65_SI02_dict_lookup_without_import_rejected () =
  should_fail "requires.*import Tesl\\.Dict\\|import Tesl\\.Dict" {|
#lang tesl
module R65Si02 exposing []
import Tesl.Prelude exposing [List, Int, String]
import Tesl.Maybe exposing [Maybe]
fn test(d: Dict String Int) -> Maybe Int =
  Dict.lookup "key" d
|}

let test_R65_SI03_string_length_without_import_rejected () =
  should_fail "requires.*import Tesl\\.String\\|import Tesl\\.String" {|
#lang tesl
module R65Si03 exposing []
import Tesl.Prelude exposing [String, Int]
fn test(s: String) -> Int =
  String.length s
|}

let test_R65_SI04_int_parse_without_import_rejected () =
  should_fail "requires.*import Tesl\\.Int\\|import Tesl\\.Int" {|
#lang tesl
module R65Si04 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Maybe exposing [Maybe]
fn test(s: String) -> Maybe Int =
  Int.parse s
|}

let test_R65_SI05_set_member_without_import_rejected () =
  should_fail "requires.*import Tesl\\.Set\\|import Tesl\\.Set" {|
#lang tesl
module R65Si05 exposing []
import Tesl.Prelude exposing [Int]
fn test(s: Set Int, x: Int) -> Bool =
  Set.member x s
|}

let test_R65_SI06_list_map_and_filter_without_import_rejected () =
  should_fail "requires.*import Tesl\\.List\\|import Tesl\\.List" {|
#lang tesl
module R65Si06 exposing []
import Tesl.Prelude exposing [List, Int]
fn double(n: Int) -> Int = n * 2
fn test(xs: List Int) -> List Int =
  List.map double xs
|}

let test_R65_SI07_stdlib_fn_in_lambda_without_import_rejected () =
  should_fail "requires.*import Tesl\\.List\\|import Tesl\\.List" {|
#lang tesl
module R65Si07 exposing []
import Tesl.Prelude exposing [List, Int]
fn reverseInner(ys: List Int) -> List Int = List.reverse ys
fn test(xss: List (List Int)) -> List (List Int) =
  List.map reverseInner xss
|}

let test_R65_SI08_stdlib_fn_in_case_without_import_rejected () =
  should_fail "requires.*import Tesl\\.String\\|import Tesl\\.String" {|
#lang tesl
module R65Si08 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Maybe exposing [Maybe, Something, Nothing]
fn test(ms: Maybe String) -> Int =
  case ms of
    Something s -> String.length s
    Nothing -> 0
|}

(* ── R65_SM — Stdlib module-level import grants all functions ─────────────── *)

let test_R65_SM01_import_all_grants_all_list_fns_accepted () =
  should_pass {|
#lang tesl
module R65Sm01 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.Maybe exposing [Maybe]
import Tesl.List
fn test(xs: List Int) -> Maybe Int =
  List.head xs
|}

let test_R65_SM02_import_all_dict_grants_lookup_accepted () =
  should_pass {|
#lang tesl
module R65Sm02 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Maybe exposing [Maybe]
import Tesl.Dict
fn test(d: Dict String Int) -> Maybe Int =
  Dict.lookup "key" d
|}

(* ── R65_SE — Exposing list granularity ──────────────────────────────────── *)

let test_R65_SE01_list_foldl_not_in_exposing_list_rejected () =
  (* User has import Tesl.List but only exposes List.head; using List.foldl is rejected *)
  should_fail "requires.*import Tesl\\.List\\|import Tesl\\.List\\|not in the exposing" {|
#lang tesl
module R65Se01 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.List exposing [List.head]
fn sum(acc: Int, x: Int) -> Int = acc + x
fn test(xs: List Int) -> Int =
  List.foldl sum 0 xs
|}

let test_R65_SE02_list_tail_not_in_exposing_rejected () =
  should_fail "requires.*import Tesl\\.List\\|List\\.tail.*not in\\|not in.*List\\.tail" {|
#lang tesl
module R65Se02 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.Maybe exposing [Maybe]
import Tesl.List exposing [List.head]
fn test(xs: List Int) -> Maybe (List Int) =
  List.tail xs
|}

let test_R65_SE03_two_functions_one_missing_from_exposing_rejected () =
  should_fail "requires.*import Tesl\\.List\\|not in the exposing" {|
#lang tesl
module R65Se03 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.Maybe exposing [Maybe]
import Tesl.List exposing [List.head]
fn test(xs: List Int) -> Int =
  let _h = List.head xs
  List.length xs
|}

(* ── R65_SA — Accepted cases (with proper imports) ──────────────────────── *)

let test_R65_SA01_list_head_with_exposing_accepted () =
  should_pass {|
#lang tesl
module R65Sa01 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.Maybe exposing [Maybe]
import Tesl.List exposing [List.head]
fn test(xs: List Int) -> Maybe Int =
  List.head xs
|}

let test_R65_SA02_multiple_list_fns_with_exposing_accepted () =
  should_pass {|
#lang tesl
module R65Sa02 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.Maybe exposing [Maybe]
import Tesl.List exposing [List.head, List.tail, List.length, List.map]
fn double(n: Int) -> Int = n * 2
fn test(xs: List Int) -> Int =
  List.length (List.map double xs)
|}

let test_R65_SA03_dict_with_explicit_import_accepted () =
  should_pass {|
#lang tesl
module R65Sa03 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Maybe exposing [Maybe]
import Tesl.Dict exposing [Dict.lookup, Dict.insert, Dict.empty]
fn test() -> Maybe Int =
  let d = Dict.insert "x" 42 Dict.empty
  Dict.lookup "x" d
|}

let test_R65_SA04_string_length_with_import_accepted () =
  should_pass {|
#lang tesl
module R65Sa04 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.String exposing [String.length]
fn test(s: String) -> Int =
  String.length s
|}

let test_R65_SA05_no_stdlib_fn_calls_no_import_needed_accepted () =
  (* A module that imports types but calls no stdlib functions *)
  should_pass {|
#lang tesl
module R65Sa05 exposing []
import Tesl.Prelude exposing [Int]
fn add(a: Int, b: Int) -> Int = a + b
fn mul(a: Int, b: Int) -> Int = a * b
|}

let test_R65_SA06_different_modules_all_imported_accepted () =
  should_pass {|
#lang tesl
module R65Sa06 exposing []
import Tesl.Prelude exposing [List, Int, String]
import Tesl.Maybe exposing [Maybe]
import Tesl.List exposing [List.length, List.head]
import Tesl.String exposing [String.length]
fn testList(xs: List Int) -> Int = List.length xs
fn testString(s: String) -> Int = String.length s
|}

(* ── R65_SC — Stdlib ADT constructor conflicts ────────────────────────────── *)

let test_R65_SC01_local_ok_conflicts_with_imported_result_rejected () =
  should_fail "constructor.*Ok.*shadows\\|Ok.*Result\\|shadows.*Ok" {|
#lang tesl
module R65Sc01 exposing [Status(..)]
import Tesl.Result exposing [Result(..)]
type Status
  = Ok
  | Pending
|}

let test_R65_SC02_local_err_conflicts_with_imported_result_rejected () =
  should_fail "constructor.*Err.*shadows\\|Err.*Result\\|shadows.*Err" {|
#lang tesl
module R65Sc02 exposing [Outcome(..)]
import Tesl.Result exposing [Result(..)]
type Outcome
  = Success
  | Err
|}

let test_R65_SC03_local_left_conflicts_with_imported_either_rejected () =
  should_fail "constructor.*Left.*shadows\\|Left.*Either\\|shadows.*Left" {|
#lang tesl
module R65Sc03 exposing [Side(..)]
import Tesl.Either exposing [Either(..)]
type Side
  = Left
  | Center
  | Right
|}

let test_R65_SC04_local_constructor_conflicts_with_db_result_rejected () =
  should_fail "constructor.*NoRowDeleted.*shadows\\|NoRowDeleted.*DB\\|shadows.*NoRowDeleted" {|
#lang tesl
module R65Sc04 exposing [MyDelete(..)]
import Tesl.DB exposing [DeleteResult(..)]
type MyDelete
  = NoRowDeleted
  | Deleted
|}

let test_R65_SC05_both_ok_and_err_conflict_detected_rejected () =
  (* When both Ok and Err are locally defined alongside import of Result(..) *)
  should_fail "constructor.*Ok.*shadows\\|constructor.*Err.*shadows\\|shadows.*Ok\\|shadows.*Err" {|
#lang tesl
module R65Sc05 exposing [HttpResult(..)]
import Tesl.Result exposing [Result(..)]
type HttpResult
  = Ok
  | Err
  | Redirect
|}

(* ── R65_SN — No conflict: accepted cases ───────────────────────────────── *)

let test_R65_SN01_import_all_without_exposing_no_ctor_conflict_accepted () =
  (* import Tesl.Result without (..) exposing does NOT import the constructors *)
  should_pass {|
#lang tesl
module R65Sn01 exposing [Status(..)]
import Tesl.Result
type Status
  = Ok
  | Pending
|}

let test_R65_SN02_import_result_type_without_dotdot_no_ctor_conflict_accepted () =
  (* import Tesl.Result exposing [Result] (no (..)) does NOT import Ok/Err *)
  should_pass {|
#lang tesl
module R65Sn02 exposing [Status(..)]
import Tesl.Result exposing [Result]
type Status
  = Ok
  | Pending
|}

let test_R65_SN03_no_result_import_ok_constructor_no_conflict_detected () =
  (* Without any Tesl.Result import, Ok local constructor has no imported counterpart
     to conflict with in the exposing-based check. *)
  should_pass {|
#lang tesl
module R65Sn03 exposing [Status(..)]
type Status
  = Ok
  | Pending
|}

let test_R65_SN04_unique_constructors_no_conflict_accepted () =
  should_pass {|
#lang tesl
module R65Sn04 exposing [Status(..)]
import Tesl.Result exposing [Result(..)]
type Status
  = Active
  | Inactive
  | Suspended
|}

let test_R65_SN05_maybe_import_no_ctor_conflict_accepted () =
  (* Nothing and Something are keywords, so they can never be local constructors *)
  should_pass {|
#lang tesl
module R65Sn05 exposing [Status(..)]
import Tesl.Maybe exposing [Maybe(..)]
type Status
  = Active
  | Inactive
|}

(* ── R65_SX — Extended / similar scenarios ──────────────────────────────── *)

let test_R65_SX01_int_abs_without_import_rejected () =
  should_fail "requires.*import Tesl\\.Int\\|import Tesl\\.Int" {|
#lang tesl
module R65Sx01 exposing []
import Tesl.Prelude exposing [Int]
fn test(n: Int) -> Int =
  Int.abs n
|}

let test_R65_SX02_float_add_without_import_rejected () =
  should_fail "requires.*import Tesl\\.Float\\|import Tesl\\.Float" {|
#lang tesl
module R65Sx02 exposing []
fn test(a: Float, b: Float) -> Float =
  Float.add a b
|}

let test_R65_SX03_list_sort_in_let_body_without_import_rejected () =
  (* stdlib fn used inside a let body *)
  should_fail "requires.*import Tesl\\.List\\|import Tesl\\.List" {|
#lang tesl
module R65Sx03 exposing []
import Tesl.Prelude exposing [List, Int]
fn test(xs: List Int) -> List Int =
  let sorted = List.sort xs
  sorted
|}

let test_R65_SX04_list_fn_in_if_branch_without_import_rejected () =
  (* stdlib fn used inside a conditional *)
  should_fail "requires.*import Tesl\\.List\\|import Tesl\\.List" {|
#lang tesl
module R65Sx04 exposing []
import Tesl.Prelude exposing [List, Int]
fn test(xs: List Int, flag: Bool) -> List Int =
  if flag then
    List.reverse xs
  else
    xs
|}

let test_R65_SX05_two_stdlib_modules_only_one_imported_catches_missing () =
  (* String.length used without import even though Tesl.List IS imported *)
  should_fail "requires.*import Tesl\\.String\\|import Tesl\\.String" {|
#lang tesl
module R65Sx05 exposing []
import Tesl.Prelude exposing [List, Int, String]
import Tesl.Maybe exposing [Maybe]
import Tesl.List exposing [List.head]
fn test(xs: List Int) -> Maybe Int = List.head xs
fn test2(s: String) -> Int = String.length s
|}

let test_R65_SX06_list_head_and_string_length_both_missing_catches_both () =
  (* Two missing imports; error should mention one of them at minimum *)
  should_fail "requires.*import Tesl\\." {|
#lang tesl
module R65Sx06 exposing []
import Tesl.Prelude exposing [List, Int, String]
import Tesl.Maybe exposing [Maybe]
fn test1(xs: List Int) -> Maybe Int = List.head xs
fn test2(s: String) -> Int = String.length s
|}

let test_R65_SX07_using_dict_empty_as_value_without_import_rejected () =
  (* Dict.empty is a zero-arg stdlib function/value *)
  should_fail "requires.*import Tesl\\.Dict\\|import Tesl\\.Dict" {|
#lang tesl
module R65Sx07 exposing []
import Tesl.Prelude exposing [String, Int]
fn test() -> Dict String Int =
  Dict.empty
|}

let test_R65_SX08_local_adt_with_same_name_as_result_ctor_accepted_if_not_imported () =
  (* Defining Err locally is OK if Tesl.Result is not imported with (..) *)
  should_pass {|
#lang tesl
module R65Sx08 exposing [Outcome(..)]
import Tesl.Prelude exposing [String]
type Outcome
  = Success
  | Err
|}

let test_R65_SX09_ctor_conflict_checked_for_maybe_type_ok_rejected () =
  (* Maybe has constructors Nothing (keyword) and Something (keyword);
     those can't be defined locally anyway since they're reserved keywords.
     But the 'Maybe' constructor itself coming from exposing [Maybe(..)] DOES
     get registered, so a local Maybe ctor would conflict. *)
  should_pass {|
#lang tesl
module R65Sx09 exposing [Flag(..)]
import Tesl.Maybe exposing [Maybe(..)]
type Flag
  = Enabled
  | Disabled
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review65-Antagonistic" [
    "stdlib-import-required", [
      test_case "R65_SI01 List.head without import rejected" `Quick test_R65_SI01_list_head_without_import_rejected;
      test_case "R65_SI02 Dict.lookup without import rejected" `Quick test_R65_SI02_dict_lookup_without_import_rejected;
      test_case "R65_SI03 String.length without import rejected" `Quick test_R65_SI03_string_length_without_import_rejected;
      test_case "R65_SI04 Int.parse without import rejected" `Quick test_R65_SI04_int_parse_without_import_rejected;
      test_case "R65_SI05 Set.member without import rejected" `Quick test_R65_SI05_set_member_without_import_rejected;
      test_case "R65_SI06 List.map without import rejected" `Quick test_R65_SI06_list_map_and_filter_without_import_rejected;
      test_case "R65_SI07 stdlib fn in lambda without import rejected" `Quick test_R65_SI07_stdlib_fn_in_lambda_without_import_rejected;
      test_case "R65_SI08 stdlib fn in case arm without import rejected" `Quick test_R65_SI08_stdlib_fn_in_case_without_import_rejected;
    ];
    "stdlib-import-module-level", [
      test_case "R65_SM01 import Tesl.List (all) grants List.head" `Quick test_R65_SM01_import_all_grants_all_list_fns_accepted;
      test_case "R65_SM02 import Tesl.Dict (all) grants Dict.lookup" `Quick test_R65_SM02_import_all_dict_grants_lookup_accepted;
    ];
    "stdlib-import-exposing-granularity", [
      test_case "R65_SE01 List.foldl not in exposing list rejected" `Quick test_R65_SE01_list_foldl_not_in_exposing_list_rejected;
      test_case "R65_SE02 List.tail not in exposing list rejected" `Quick test_R65_SE02_list_tail_not_in_exposing_rejected;
      test_case "R65_SE03 two fns: one missing from exposing rejected" `Quick test_R65_SE03_two_functions_one_missing_from_exposing_rejected;
    ];
    "stdlib-import-accepted", [
      test_case "R65_SA01 List.head with exposing accepted" `Quick test_R65_SA01_list_head_with_exposing_accepted;
      test_case "R65_SA02 multiple List fns with exposing accepted" `Quick test_R65_SA02_multiple_list_fns_with_exposing_accepted;
      test_case "R65_SA03 Dict with explicit import accepted" `Quick test_R65_SA03_dict_with_explicit_import_accepted;
      test_case "R65_SA04 String.length with import accepted" `Quick test_R65_SA04_string_length_with_import_accepted;
      test_case "R65_SA05 no stdlib fn calls: no import needed" `Quick test_R65_SA05_no_stdlib_fn_calls_no_import_needed_accepted;
      test_case "R65_SA06 different modules all imported accepted" `Quick test_R65_SA06_different_modules_all_imported_accepted;
    ];
    "stdlib-ctor-conflict", [
      test_case "R65_SC01 local Ok conflicts with Result(..) rejected" `Quick test_R65_SC01_local_ok_conflicts_with_imported_result_rejected;
      test_case "R65_SC02 local Err conflicts with Result(..) rejected" `Quick test_R65_SC02_local_err_conflicts_with_imported_result_rejected;
      test_case "R65_SC03 local Left/Right conflict with Either(..) rejected" `Quick test_R65_SC03_local_left_conflicts_with_imported_either_rejected;
      test_case "R65_SC04 NoRowDeleted conflicts with DB(..) rejected" `Quick test_R65_SC04_local_constructor_conflicts_with_db_result_rejected;
      test_case "R65_SC05 both Ok and Err conflict detected" `Quick test_R65_SC05_both_ok_and_err_conflict_detected_rejected;
    ];
    "stdlib-ctor-accepted", [
      test_case "R65_SN01 import all without (..) no ctor conflict" `Quick test_R65_SN01_import_all_without_exposing_no_ctor_conflict_accepted;
      test_case "R65_SN02 import Result type without (..) no ctor conflict" `Quick test_R65_SN02_import_result_type_without_dotdot_no_ctor_conflict_accepted;
      test_case "R65_SN03 no Result import: no conflict detected" `Quick test_R65_SN03_no_result_import_ok_constructor_no_conflict_detected;
      test_case "R65_SN04 unique constructors no conflict" `Quick test_R65_SN04_unique_constructors_no_conflict_accepted;
      test_case "R65_SN05 Maybe import no ctor conflict" `Quick test_R65_SN05_maybe_import_no_ctor_conflict_accepted;
    ];
    "extended-scenarios", [
      test_case "R65_SX01 Int.abs without import rejected" `Quick test_R65_SX01_int_abs_without_import_rejected;
      test_case "R65_SX02 Float.add without import rejected" `Quick test_R65_SX02_float_add_without_import_rejected;
      test_case "R65_SX03 List.sort in let body without import rejected" `Quick test_R65_SX03_list_sort_in_let_body_without_import_rejected;
      test_case "R65_SX04 List.reverse in if branch without import rejected" `Quick test_R65_SX04_list_fn_in_if_branch_without_import_rejected;
      test_case "R65_SX05 two modules: only one imported catches missing" `Quick test_R65_SX05_two_stdlib_modules_only_one_imported_catches_missing;
      test_case "R65_SX06 both List and String missing imports caught" `Quick test_R65_SX06_list_head_and_string_length_both_missing_catches_both;
      test_case "R65_SX07 Dict.empty without import rejected" `Quick test_R65_SX07_using_dict_empty_as_value_without_import_rejected;
      test_case "R65_SX08 local Err without Result import accepted" `Quick test_R65_SX08_local_adt_with_same_name_as_result_ctor_accepted_if_not_imported;
      test_case "R65_SX09 Maybe import unique local ctors accepted" `Quick test_R65_SX09_ctor_conflict_checked_for_maybe_type_ok_rejected;
    ];
  ]
