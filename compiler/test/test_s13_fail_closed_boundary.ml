(** S13 — fail-closed Go boundary types.

    Go has no dynamic type registry. Concrete boundary types become Go types, so
    known mismatches are rejected by Tesl's type checker and unknown/unsupported
    concrete types are refused before artifacts escape. Records, ADTs, newtypes,
    Unit, runtime-provided DeleteResult, and type variables must still compile to
    typed Go and execute successfully. This suite proves both halves: compiler
    rejection for bad boundaries and a real generated-Go test for valid ones. *)

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
  let dir = Filename.temp_dir "tesl-s13" "" in
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

let contains ~needle haystack =
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re haystack 0); true with Not_found -> false

(* --check exits 0. *)
let should_check src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected --check success, got:\n%s" out)

let should_reject pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static rejection matching %S" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected rejection matching %S, got:\n%s" pat out)

let should_emit_go needles src =
  match Compile.compile_go_source "<s13-go-boundaries>" src with
  | Compile.GoFailure diagnostics ->
    failf "expected Go emission, got: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    let emitted = String.concat "\n" (List.map (fun (a : Emit_go.artifact) -> a.contents) artifacts) in
    List.iter (fun needle ->
      if not (contains ~needle emitted) then
        failf "expected emitted Go to contain %S" needle) needles

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end else Sys.remove path

let rec mkdir_p path =
  if path = "" || path = Filename.current_dir_name || Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_artifacts root artifacts =
  List.iter (fun (artifact : Emit_go.artifact) ->
    let path = Filename.concat root artifact.path in
    mkdir_p (Filename.dirname path);
    Out_channel.with_open_bin path (fun channel -> output_string channel artifact.contents)) artifacts

let should_fail_go_emit needle src =
  match Compile.compile_go_source "<s13-unsupported-boundary>" src with
  | Compile.GoSuccess _ -> failf "unsupported boundary emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    if not (List.exists (fun (d : Compile.diagnostic) ->
      d.source = "go-emitter" && contains ~needle d.message) diagnostics) then
      failf "expected Go emitter rejection containing %S, got: %s" needle
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))

let runtime_proof = {|module DesignS13Go exposing [Widget, Color, Score, firstOr, countDeleted]
import Tesl.Prelude exposing [Int, String, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [DeleteResult(..)]

record Widget { id: Int name: String }
type Color =
  | Red
  | Green
  | Blue
type Score = Int

fn firstOr(value: Maybe a, dflt: a) -> a =
  case value of
    Something found -> found
    Nothing -> dflt

fn countDeleted(result: DeleteResult) -> Int =
  case result of
    RowsDeleted count -> count
    NoRowDeleted -> 0

fn colorCode(color: Color) -> Int =
  case color of
    Red -> 1
    Green -> 2
    Blue -> 3

fn scoreValue(score: Score) -> Int = score.value
fn unitValue() -> Unit = Unit

test "typed Go boundaries" {
  let widget = Widget { id: 1, name: "ok" }
  let id = widget.id
  let color = colorCode (firstOr (Something Green) Red)
  let number = firstOr (Something 7) 0
  let score = scoreValue (Score 7)
  let rows = countDeleted (RowsDeleted 3)
  let none = countDeleted NoRowDeleted
  let _unit = unitValue()
  expect id == 1
  expect color == 2
  expect number == 7
  expect score == 7
  expect rows == 3
  expect none == 0
}
|}

let test_S13_fail_closed_runtime_proof () =
  if Sys.command "go version >/dev/null 2>&1" <> 0 then
    failf "Go is required for the S13 runtime boundary proof";
  match Compile.compile_go_source "<s13-go-runtime-proof>" runtime_proof with
  | Compile.GoFailure diagnostics ->
    failf "runtime proof did not compile: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    let root = Filename.temp_dir "tesl-s13-go" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root artifacts;
      let cmd = Printf.sprintf "cd %s && go test -count=1 ./... 2>&1" (Filename.quote root) in
      let code, out = run_command cmd in
      if code <> 0 then failf "generated Go boundary proof failed (exit %d):\n%s" code out)

let test_S13_go_types_are_concrete () =
  should_emit_go
    [ "type Widget struct"; "type ColorTag int"; "type Score struct";
      "teslrt.DeleteResult"; "func FirstOr[A any]" ]
    runtime_proof

let test_S13_known_mismatches_rejected () =
  List.iter (fun (label, ty, value) ->
    should_reject ("cannot unify.*" ^ ty)
      (Printf.sprintf {|module DesignS13Bad%s exposing []
import Tesl.Prelude exposing [Int, String]
record Widget { id: Int }
type Color =
  | Red
  | Green
type Score = Int
fn bad() -> %s = %s
|} label ty value))
    [ "Record", "Widget", "42";
      "Adt", "Color", "\"red\"";
      "Newtype", "Score", "99" ]

let test_S13_unknown_concrete_rejected () =
  should_reject "Bogus.*not in scope\\|unknown type.*Bogus\\|type.*Bogus.*not in scope"
    {|module DesignS13Unknown exposing []
fn bad(value: Bogus) -> Bogus = value
|}

let test_S13_unsupported_runtime_type_rejected () =
  should_fail_go_emit "`Tesl.Telemetry` export `Span`"
    {|module DesignS13Unsupported exposing []
import Tesl.Prelude exposing [String]
import Tesl.Telemetry exposing [Span]
fn describe(_span: Span) -> String = "span"
|}

(* ── Unit return: emitted as Go's zero-sized value ─────────────────────────── *)

let test_S13_unit_return_compiles () =
  should_emit_go ["func LogIt(_msg string) struct{}"] {|
module DesignS13Unit exposing [logIt]
import Tesl.Prelude exposing [String, Unit]

fn logIt(_msg: String) -> Unit =
  Unit
|}

(* ── Polymorphic return: emitted as a Go type parameter ────────────────────── *)

let test_S13_polymorphic_return_compiles () =
  should_emit_go ["func FirstOr[A any]"] {|
module DesignS13Poly exposing [firstOr]
import Tesl.Prelude exposing [List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.head]

fn firstOr(xs: List a, dflt: a) -> a =
  case List.head xs of
    Something v -> v
    Nothing -> dflt
|}

let test_S13_polymorphic_param_emits_typevar () =
  should_emit_go ["dflt A"] {|
module DesignS13Poly2 exposing [firstOr]
import Tesl.Prelude exposing [List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.head]

fn firstOr(xs: List a, dflt: a) -> a =
  case List.head xs of
    Something v -> v
    Nothing -> dflt
|}

(* ── Concrete builtin return still compiles (no over-rejection) ────────────── *)

let test_S13_concrete_return_still_compiles () =
  should_check {|
module DesignS13Concrete exposing [ident]
import Tesl.Prelude exposing [Int]

fn ident(x: Int) -> Int =
  x
|}

let () =
  run "s13-fail-closed-boundary" [
    "positive", [
      test_case "-> Unit compiles to struct{}" `Quick test_S13_unit_return_compiles;
      test_case "polymorphic fn emits a Go type parameter" `Quick test_S13_polymorphic_return_compiles;
      test_case "polymorphic param uses the Go type parameter" `Quick test_S13_polymorphic_param_emits_typevar;
      test_case "concrete builtin return still compiles" `Quick test_S13_concrete_return_still_compiles;
    ];
    "fail_closed", [
      test_case "generated Go accepts typed record/ADT/newtype/Unit/DeleteResult/type-var"
        `Quick test_S13_fail_closed_runtime_proof;
      test_case "generated Go keeps concrete and generic boundary types" `Quick test_S13_go_types_are_concrete;
      test_case "known record/ADT/newtype mismatches are rejected" `Quick test_S13_known_mismatches_rejected;
      test_case "unknown concrete type is rejected" `Quick test_S13_unknown_concrete_rejected;
      test_case "unsupported runtime type is rejected before Go escapes" `Quick test_S13_unsupported_runtime_type_rejected;
    ];
  ]
