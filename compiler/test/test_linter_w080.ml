(** W080 lint warning tests — exported function references unexported type or
    proof predicate.

    For library modules this is a compile error (tested in test_library_negative).
    For regular modules it is a lint warning (W080) only — compilation succeeds.

    Groups:
      W080P — W080 positive: linter emits W080
      W080N — W080 negative: no W080 for correct code *)

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
  (* Strip a single leading newline — heredocs add one that confuses the linter's
     E002 / W001 checks which expect #lang tesl on the very first line. *)
  let content =
    if String.length content > 0 && content.[0] = '\n'
    then String.sub content 1 (String.length content - 1)
    else content
  in
  let dir = Filename.temp_dir "tesl-sigexp" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
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

let should_lint_warn pat src =
  with_temp_file src (fun path ->
    let exit_code, out = run_compiler ["--lint"; path] in
    let re = Str.regexp_case_fold pat in
    (try ignore (Str.search_forward re out 0)
     with Not_found -> failf "expected lint output matching %S, got (exit %d):\n%s" pat exit_code out))

let should_compile_clean src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got:\n%s" out)

let should_lint_no_w080 src =
  with_temp_file src (fun path ->
    let _exit_code, out = run_compiler ["--lint"; path] in
    (* Search only in the diagnostic message portion, not the file path prefix *)
    let found = ref false in
    let re = Str.regexp {|warning\[W080\]|} in
    (try ignore (Str.search_forward re out 0); found := true
     with Not_found -> ());
    if !found then failf "expected no W080, but got:\n%s" out)

(* ── W080P — W080 positive cases ─────────────────────────────────────────── *)

let test_W080P01_unexported_record_param () =
  (* Regular module exports fn whose param uses an unexported record type *)
  should_lint_warn "W080\\|not.*exported\\|consumers.*import" {|
#lang tesl
module W080P01 exposing [processUser]
import Tesl.Prelude exposing [String]
record User { name: String }
fn processUser(u: User) -> String = u.name
|}

let test_W080P02_unexported_record_return () =
  should_lint_warn "W080\\|not.*exported" {|
#lang tesl
module W080P02 exposing [makeToken]
import Tesl.Prelude exposing [String]
record Token { value: String }
fn makeToken(s: String) -> Token =
  Token { value: s }
|}

let test_W080P03_unexported_proof_predicate () =
  should_lint_warn "W080\\|not.*exported" {|
#lang tesl
module W080P03 exposing [requiresValid]
import Tesl.Prelude exposing [Int]
fact IsValid (n: Int)
fn requiresValid(n: Int ::: IsValid n) -> Int = n
|}

let test_W080P04_unexported_adt_type () =
  should_lint_warn "W080\\|not.*exported" {|
#lang tesl
module W080P04 exposing [describeColor]
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn describeColor(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|}

let test_W080P05_still_compiles_despite_warning () =
  (* Compilation must succeed even when W080 would fire *)
  should_compile_clean {|
#lang tesl
module W080P05 exposing [processUser]
import Tesl.Prelude exposing [String]
record User { name: String }
fn processUser(u: User) -> String = u.name
|}

let test_W080P06_warning_names_the_function_and_type () =
  (* The warning message must include both the function name and the type name *)
  should_lint_warn "processUser\\|User" {|
#lang tesl
module W080P06 exposing [processUser]
import Tesl.Prelude exposing [String]
record User { name: String }
fn processUser(u: User) -> String = u.name
|}

(* ── W080N — W080 negative cases (no warning) ────────────────────────────── *)

let test_W080N01_all_types_exported_no_warning () =
  should_lint_no_w080 {|
#lang tesl
module W080N01 exposing [processUser, User]
import Tesl.Prelude exposing [String]
record User { name: String }
fn processUser(u: User) -> String = u.name
|}

let test_W080N02_stdlib_types_never_warn () =
  should_lint_no_w080 {|
#lang tesl
module W080N02 exposing [double, greet]
import Tesl.Prelude exposing [Int, String]
fn double(n: Int) -> Int = n * 2
fn greet(name: String) -> String = name
|}

let test_W080N03_unexported_fn_does_not_warn () =
  (* If the function itself is not exported, no W080 *)
  should_lint_no_w080 {|
#lang tesl
module W080N03 exposing []
import Tesl.Prelude exposing [String]
record User { name: String }
fn processUser(u: User) -> String = u.name
|}

let test_W080N04_unexported_type_in_exported_fact_proof_fn () =
  (* Proof fn exported along with its fact — no warning *)
  should_lint_no_w080 {|
#lang tesl
module W080N04 exposing [IsValid, requiresValid]
import Tesl.Prelude exposing [Int]
fact IsValid (n: Int)
fn requiresValid(n: Int ::: IsValid n) -> Int = n
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "W080-Unexported-Signature-Types" [
    "w080-positive", [
      test_case "W080P01 unexported record param warns" `Quick test_W080P01_unexported_record_param;
      test_case "W080P02 unexported record return warns" `Quick test_W080P02_unexported_record_return;
      test_case "W080P03 unexported proof predicate warns" `Quick test_W080P03_unexported_proof_predicate;
      test_case "W080P04 unexported ADT type warns" `Quick test_W080P04_unexported_adt_type;
      test_case "W080P05 still compiles despite warning" `Quick test_W080P05_still_compiles_despite_warning;
      test_case "W080P06 warning names function and type" `Quick test_W080P06_warning_names_the_function_and_type;
    ];
    "w080-negative", [
      test_case "W080N01 all types exported — no warning" `Quick test_W080N01_all_types_exported_no_warning;
      test_case "W080N02 stdlib types never warn" `Quick test_W080N02_stdlib_types_never_warn;
      test_case "W080N03 unexported function does not warn" `Quick test_W080N03_unexported_fn_does_not_warn;
      test_case "W080N04 exported fact+proof fn no warning" `Quick test_W080N04_unexported_type_in_exported_fact_proof_fn;
    ];
  ]
