(** CLI seams for built-in mutation testing (`tesl --mutate`). Operator,
    classification, and backend details live in the pure and direct-API suites. *)

open Alcotest

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some b -> b
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else
      (* Dune sandbox: try relative path from test CWD *)
      let rel = "../bin/main.exe" in
      if Sys.file_exists rel then rel else "tesl"

let has_str out sub =
  try ignore (Str.search_forward (Str.regexp_string sub) out 0); true
  with Not_found -> false

let go_available () =
  Sys.command "go version >/dev/null 2>&1" = 0

let has_mutate_support () =
  Filename.basename tesl = "main.exe"

(** Run Go mutation testing on the given source and return (exit_code, output). *)
let run_mutate src =
  (* Write the fixture to a file whose name matches its `module X` header so the
     structural file-name/module-name check (V001) does not fire — otherwise
     `--mutate` errors out before mutating and the test sees empty output.
     (Mirrors the kebab-deriving helper used by the other antagonistic suites.) *)
  let dir = Filename.temp_dir "tesl-mutate-test" "" in
  let fname =
    let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re src 0);
      let mname = Str.matched_group 1 src in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then
          (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let tmp = Filename.concat dir fname in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let out_tmp = Filename.concat dir "out.txt" in
  let status = Sys.command
     (Printf.sprintf "%s --mutate --backend go %s > %s 2>&1" tesl
       (Filename.quote tmp) (Filename.quote out_tmp)) in
  let ic = open_in out_tmp in
  let out = In_channel.input_all ic in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  (try Sys.remove out_tmp with _ -> ());
  (try Sys.rmdir dir with _ -> ());
  (status, out)

(* ── Test cases ───────────────────────────────────────────────────────────── *)

let test_no_go_skip () =
  if not (go_available ()) then
    skip ()
  else
    ()

(** CLI smoke: successful mutation run prints killed mutants and a full score. *)
let test_all_killed () =
  if not (has_mutate_support ()) then skip ();
  if not (go_available ()) then skip ();
  let src = {|module T exposing [checkPos]
import Tesl.Prelude exposing [Int, Bool(..)]

fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

test "gt zero" {
  expect (check checkPos 1) == 1
  expectFail check checkPos 0
  expectFail check checkPos (-1)
}
|} in
  let (code, out) = run_mutate src in
  check int "exit 0 means 100% score" 0 code;
  check bool "mentions KILLED" true (String.length out > 0 && has_str out "KILLED");
  check bool "no SURVIVED" false (has_str out "SURVIVED");
  check bool "100% score" true (has_str out "100%")

let test_zero_mutants_is_not_success () =
  if not (has_mutate_support ()) then skip ();
  if not (go_available ()) then skip ();
  let src = {|module T exposing [identity]
import Tesl.Prelude exposing [Int]

fn identity(n: Int) -> Int = n

test "identity" {
  expect identity 1 == 1
}
|} in
  let code, out = run_mutate src in
  check int "zero mutants exits nonzero" 1 code;
  check bool "no mutable sites reported" true (has_str out "no mutable sites")

(** File with no test block: all mutants should show NO TESTS. *)
let test_no_test_block () =
  if not (has_mutate_support ()) then skip ();
  if not (go_available ()) then skip ();
  let src = {|module T exposing [checkPos]
import Tesl.Prelude exposing [Int, Bool(..)]

fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|} in
  let (code, out) = run_mutate src in
  check bool "no crash" true (code = 0 || code = 1);
  check bool "mentions NO TESTS" true (has_str out "NO TESTS")

(** Parse error should report cleanly. *)
let test_parse_error () =
  if not (has_mutate_support ()) then skip ();
  let src = {|this is not valid tesl
|} in
  let (code, out) = run_mutate src in
  check int "exit 1 on error" 1 code;
  check bool "error message" true (has_str out "error")

(* ── Suite ────────────────────────────────────────────────────────────────── *)

let () =
  run "Mutation-Testing" [
    "infrastructure", [
      test_case "Go availability check" `Quick test_no_go_skip;
      test_case "parse error reported cleanly" `Quick test_parse_error;
    ];
    "mutation-results", [
      test_case "all mutants killed with strong tests" `Slow test_all_killed;
      test_case "no-test block shows NO TESTS" `Slow test_no_test_block;
      test_case "zero mutants is not success" `Slow test_zero_mutants_is_not_success;
    ];
  ]
