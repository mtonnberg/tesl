(** Capability-row polymorphism tests.

    A higher-order function opts into propagating its callback's capabilities by
    naming a capability-row variable on the parameter's arrow type and listing it
    in its own `requires`:

        fn applyTwice(x: Int, f: (Int -> Int requires c)) -> Int requires c =
          f (f x)

    `c` is a row variable (bound by the param's `(… requires c)`), not a concrete
    capability.  At each call site it is instantiated to the actual callback's
    capabilities (handled conservatively by the checker walking the callback
    argument).  See roadmap/next/capability_polymorphism.md.

    Test groups:
      CP — positive: HOFs with capability-bearing / pure callbacks compile
      CN — negative: forgetting / mis-declaring row variables is rejected, and the
           `requires []` guarantee is preserved for direct capability use. *)

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
  let dir = Filename.temp_dir "tesl-cap" "" in
  let name =
    let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
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

(* ── CP — positive ───────────────────────────────────────────────────────── *)

let test_CP01_hof_with_capability_callback () =
  should_pass {|
module CapPolyCp01 exposing [useIt]
import Tesl.Prelude exposing [Int]
capability dbThing
fn helper(x: Int) -> Int requires [dbThing] =
  x
fn applyTwice(x: Int, f: (Int -> Int requires c)) -> Int requires c =
  f (f x)
fn useIt(x: Int) -> Int requires [dbThing] =
  applyTwice x helper
|}

let test_CP02_hof_with_concrete_and_row_caps () =
  (* `requires ([dbThing] ++ c)` — concrete capability concatenated with a row var *)
  should_pass {|
module CapPolyCp02 exposing [useIt]
import Tesl.Prelude exposing [Int]
capability dbThing
capability logCap
fn helper(x: Int) -> Int requires [logCap] =
  x
fn runWith(x: Int, f: (Int -> Int requires c)) -> Int requires ([dbThing] ++ c) =
  f x
fn useIt(x: Int) -> Int requires [dbThing, logCap] =
  runWith x helper
|}

let test_CP03_pure_callback_needs_no_caps () =
  (* A callback with no capabilities instantiates c = {}, so a caller using only
     pure callbacks needs no capabilities. *)
  should_pass {|
module CapPolyCp03 exposing [usePure]
import Tesl.Prelude exposing [Int]
fn applyf(x: Int, f: (Int -> Int requires c)) -> Int requires c =
  f x
fn double(x: Int) -> Int =
  x
fn usePure(x: Int) -> Int =
  applyf x double
|}

(* ── CN — negative ───────────────────────────────────────────────────────── *)

let test_CN01_hof_omits_row_var () =
  (* applyTwice calls f (which requires c) but declares no capabilities. *)
  should_fail "does not declare\\|requires \\[c\\]" {|
module CapPolyCn01 exposing [applyTwice]
import Tesl.Prelude exposing [Int]
fn applyTwice(x: Int, f: (Int -> Int requires c)) -> Int requires [] =
  f (f x)
|}

let test_CN02_unbound_row_variable () =
  (* `requires [c]` with no parameter binding `c` is an undeclared capability. *)
  should_fail "undeclared capability 'c'\\|undeclared capability" {|
module CapPolyCn02 exposing [foo]
import Tesl.Prelude exposing [Int]
fn foo(x: Int) -> Int requires [c] =
  x
|}

let test_CN03_requires_empty_guarantee_preserved () =
  (* A `requires []` function that calls a capability-bearing function is still
     rejected — the core guarantee is intact. *)
  should_fail "does not declare\\|dbThing" {|
module CapPolyCn03 exposing [bad]
import Tesl.Prelude exposing [Int]
capability dbThing
fn helper(x: Int) -> Int requires [dbThing] =
  x
fn bad(x: Int) -> Int requires [] =
  helper x
|}

let () =
  run "capability-polymorphism" [
    "positive", [
      test_case "CP01 HOF with capability-bearing callback" `Quick test_CP01_hof_with_capability_callback;
      test_case "CP02 concrete ++ row capability clause"     `Quick test_CP02_hof_with_concrete_and_row_caps;
      test_case "CP03 pure callback needs no caps"           `Quick test_CP03_pure_callback_needs_no_caps;
    ];
    "negative", [
      test_case "CN01 HOF omits row variable"                `Quick test_CN01_hof_omits_row_var;
      test_case "CN02 unbound row variable"                  `Quick test_CN02_unbound_row_variable;
      test_case "CN03 requires [] guarantee preserved"       `Quick test_CN03_requires_empty_guarantee_preserved;
    ];
  ]
