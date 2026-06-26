(** Byte-exact diagnostic-snapshot corpus (Wave 0 safety net).

    Purpose: pin the *rendered diagnostic text + spans + code + severity +
    source* of one broken program per error class/form so that a compiler
    refactor cannot silently change the user-visible diagnostics (the gold-tier
    error messages) without a test going red.

    These are deliberately byte-EXACT. They are NOT `assert_contains` smoke
    checks — every byte of the message, every line/col of the span, the stable
    code, the severity and the diagnostic source are asserted verbatim. If the
    refactor changes the wording, re-spans a diagnostic, renames a source, or
    drops/changes a code, the matching snapshot fails and prints the expected vs
    actual blocks.

    Two production paths are exercised:

      - [Compile.check_source] — the library entry used by `--check`/`--check-json`
        and every editor integration. Produces the parser/type/proof/validation/
        capability/codec diagnostics. We call it with a fixed in-memory filename so
        the snapshots are path-independent (the rendered form below omits the file).

      - [Linter.lint_file] — the opinionated linter (W0xx/E0xx). It reads from
        disk, so each linter snapshot writes a temp file first.

    Capability-DENIAL negatives (programs that MUST FAIL to compile) are also
    asserted here through the real CLI binary: a denial program must exit
    non-zero AND surface its expected stable code. This guards the negative
    paths the refactor most endangers.

    To (re)generate an expected block after an *intentional* message change:
    run `dune exec test/test_diag_snapshots.exe` — a failing case prints the
    actual rendered block, which can be pasted back verbatim. *)

(* ── Rendering ──────────────────────────────────────────────────────────────
   Canonical, path-independent rendering of a diagnostic. Every field that the
   tooling contract exposes is included so the snapshot has teeth on all of
   them: code, severity, source, the full 4-tuple span, and the message
   (verbatim, including any embedded "Hint:" newline). *)
let render_diag (d : Compile.diagnostic) : string =
  Printf.sprintf "[%s] %s @ %s %d:%d-%d:%d\n  %s"
    d.code d.severity d.source
    d.start_line d.start_col d.end_line d.end_col
    d.message

let render_all (diags : Compile.diagnostic list) : string =
  String.concat "\n" (List.map render_diag diags)

(* ── Temp-file helper for the disk-reading linter ───────────────────────────── *)
let with_temp_file contents f =
  let path = Filename.temp_file "tesl-diagsnap-" ".tesl" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
       Out_channel.with_open_text path (fun oc -> output_string oc contents);
       f path)

(* ── Locate the compiled CLI for the denial negatives ───────────────────────── *)
let compiler_binary () =
  let candidates = [
    "compiler/_build/default/bin/main.exe";
    "_build/default/bin/main.exe";
    (let exe_dir = Filename.dirname Sys.executable_name in
     Filename.concat (Filename.dirname exe_dir) "bin/main.exe");
  ] in
  match List.find_opt Sys.file_exists candidates with
  | Some p -> p
  | None ->
    Alcotest.failf "compiler binary not found in: %s"
      (String.concat ", " candidates)

(* Run `tesl --check <file>` on [source]; return (exit_code, combined_output). *)
let run_check source =
  with_temp_file source (fun path ->
    let bin = compiler_binary () in
    (* Merge stderr into stdout: diagnostics print to stderr. *)
    let cmd =
      Printf.sprintf "%s --check %s 2>&1"
        (Filename.quote bin) (Filename.quote path)
    in
    let ic = Unix.open_process_in cmd in
    let out = In_channel.input_all ic in
    let code = match Unix.close_process_in ic with
      | Unix.WEXITED c -> c
      | Unix.WSIGNALED n -> 128 + n
      | Unix.WSTOPPED n -> 128 + n
    in
    (code, out))

(* ── Snapshot assertion ─────────────────────────────────────────────────────── *)
let assert_snapshot ~name ~expected ~actual =
  if expected <> actual then
    Alcotest.failf
      "%s: rendered diagnostics changed.\n\
       --- EXPECTED ---\n%s\n--- ACTUAL ---\n%s\n--- END ---\n\
       (If this change is intentional, update the expected block in \
       test_diag_snapshots.ml to the ACTUAL block above.)"
      name expected actual

let snapshot_source ~name ~source ~expected () =
  let actual = render_all (Compile.check_source "snapshot.tesl" source) in
  assert_snapshot ~name ~expected ~actual

let snapshot_lint ~name ~source ~expected () =
  with_temp_file source (fun path ->
    let actual = render_all (Linter.lint_file path) in
    assert_snapshot ~name ~expected ~actual)

(* ════════════════════════════════════════════════════════════════════════════
   THE CORPUS — one broken program per error class/form.
   ════════════════════════════════════════════════════════════════════════════ *)

(* ── Parse error (E000, source=parser) ──────────────────────────────────────── *)
let parse_src = {|#lang tesl
module Snapshot exposing [value]
value: Int
value = 1
|}
let parse_expected =
  "[E000] error @ parser 2:0-2:1\n\
  \  unexpected token at top level: value (pos 10)"

(* ── Type error (T001, source=type-checker) ─────────────────────────────────── *)
let type_src = {|#lang tesl
module Snapshot exposing [value]
import Tesl.Prelude exposing [String, Int]
fn value() -> String = 1
|}
let type_expected =
  "[T001] error @ type-checker 3:23-3:24\n\
  \  cannot unify Int with String (type mismatch) (because body of `value` must have type String)"

(* ── Proof error (P001, source=proof-checker) ───────────────────────────────── *)
(* Undeclared capability name in `requires` is a pure proof-checker (P001)
   rejection. *)
let proof_src = {|#lang tesl
module Snapshot exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int) -> Int requires [totallyBogusCap] = n
|}
let proof_expected =
  "[P001] error @ proof-checker 3:3-5:1\n\
  \  function 'f' requires undeclared capability 'totallyBogusCap'"

(* ── Validation error (V001, source=validation) ─────────────────────────────── *)
(* A server binding referencing a handler that does not exist. *)
let validation_src = {|#lang tesl
module Snapshot exposing [S]
import Tesl.Prelude exposing [String]
api TaskApi {
  post "/tasks"
    -> String
}
server S for TaskApi {
  createTask = nonExistentHandler
}
|}
let validation_expected =
  "[V001] error @ validation 7:7-9:2\n\
  \  server 'S': handler 'nonExistentHandler' for endpoint 'createTask' is not declared\n\
   Hint: declare `handler nonExistentHandler(...)` in this module or import it explicitly"

(* ── Capability denial: effect used without declared capability (V001) ──────── *)
(* A handler that calls the `time` effect (nowMillis) but declares `requires []`.
   This is the everyday "you used an effect without its capability" denial. *)
let cap_deny_src = {|#lang tesl
module Snapshot exposing []
import Tesl.Prelude exposing []
import Tesl.Time exposing [nowMillis, PosixMillis]
handler h() -> PosixMillis requires [] =
  nowMillis()
|}
let cap_deny_expected =
  "[V001] error @ validation 4:8-7:1\n\
  \  handler 'h' uses [time] but does not declare the required capabilities\n\
   Hint: add `requires [time]` to the handler declaration"

(* ── Capability/structure: handler called directly from code (V001) ─────────── *)
let handler_iso_src = {|#lang tesl
module Snapshot exposing []
import Tesl.Prelude exposing [Int]
handler protectedHandler(n: Int) -> Int requires [] = n
fn caller(n: Int) -> Int =
  protectedHandler n
|}
let handler_iso_expected =
  "[V001] error @ validation 5:2-5:20\n\
  \  `caller` calls handler `protectedHandler` directly; handlers cannot be called from code — only the server router may reference handlers\n\
   Hint: handlers are HTTP entry points that can only be wired via server declarations; extract shared logic into a helper `fn` function instead"

(* ── Codec / field-coverage error (V001) ─────────────────────────────────────── *)
(* A toJson clause naming a field that does not exist on the record. *)
let codec_field_src = {|#lang tesl
module Snapshot exposing [Msg]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Msg {
  content: String
}
codec Msg {
  toJson {
    bogus -> "bogus" with_codec stringCodec
  }
  fromJson [
    {
      content <- "content" with_codec stringCodec
    }
  ]
}
|}
let codec_field_expected =
  "[V001] error @ validation 9:4-9:44\n\
  \  codec 'Msg': field 'bogus' does not exist on type 'Msg'; remove this toJson entry or rename the field\n\
   Hint: valid fields on 'Msg': content"

(* ── Codec / proof-coverage error (V001) ─────────────────────────────────────── *)
(* A decoder field whose declared type carries a proof predicate but the codec
   provides no `via` validation. *)
let codec_proof_src = {|#lang tesl
module Snapshot exposing [Msg, nonEmpty]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
fact NonEmpty (s: String)
check nonEmpty(s: String) -> s: String ::: NonEmpty s =
  if s == "" then
    fail 400 "empty"
  else
    ok s ::: NonEmpty s
record Msg {
  content: String ::: NonEmpty content
}
codec Msg {
  toJson {
    content -> "content" with_codec stringCodec
  }
  fromJson [
    {
      content <- "content" with_codec stringCodec
    }
  ]
}
|}
let codec_proof_expected =
  "[V001] error @ validation 19:6-19:50\n\
  \  codec 'Msg': decoder field 'content' requires proof predicates NonEmpty but has no `via` validation\n\
   Hint: add `via <checkFn>` so field 'content' is validated before decoding succeeds"

(* ── Linter: E002 (missing #lang tesl) ──────────────────────────────────────── *)
let lint_e002_src = "module Main exposing [value]\nfn value() = 1\n"
let lint_e002_expected =
  "[E002] error @ lint 0:0-0:0\n\
  \  file must start with `#lang tesl`\n\
   [W001] warning @ lint 1:0-1:0\n\
  \  first non-comment declaration should be a module header"

(* ── Linter: E010 (tab character) ───────────────────────────────────────────── *)
let lint_e010_src =
  "#lang tesl\nmodule Main exposing [value]\nimport Tesl.Prelude exposing [Int]\nfn value() -> Int =\n\t1\n"
let lint_e010_expected =
  "[E010] error @ lint 4:0-4:0\n\
  \  tabs are not allowed; use spaces"

(* ── Linter: W010 (trailing whitespace) ─────────────────────────────────────── *)
let lint_w010_src =
  "#lang tesl\nmodule Main exposing [value]\nimport Tesl.Prelude exposing [Int]   \nfn value() -> Int = 1\n"
let lint_w010_expected =
  "[W010] warning @ lint 2:34-2:34\n\
  \  trailing whitespace"

(* ── Linter: W020 (module name not UpperCamelCase) ──────────────────────────── *)
let lint_w020_src =
  "#lang tesl\nmodule myMod exposing [value]\nimport Tesl.Prelude exposing [Int]\nfn value() -> Int = 1\n"
let lint_w020_expected =
  "[W020] warning @ lint 1:0-1:0\n\
  \  module name `myMod` should be UpperCamelCase"

(* ── Linter: W022 (function name not lowerCamelCase) ────────────────────────── *)
let lint_w022_src =
  "#lang tesl\nmodule Main exposing [Value]\nimport Tesl.Prelude exposing [Int]\nfn Value() -> Int = 1\n"
let lint_w022_expected =
  "[W022] warning @ lint 3:0-3:0\n\
  \  function name `Value` should be lowerCamelCase"

(* ── Linter: W050 (unused import) ───────────────────────────────────────────── *)
let lint_w050_src =
  "#lang tesl\nmodule Main exposing [value]\nimport Tesl.Prelude exposing [Int, String]\nfn value() -> Int = 1\n"
let lint_w050_expected =
  "[W050] warning @ lint 2:42-2:42\n\
  \  unused import: `String` from `Tesl.Prelude` is never referenced"

(* ════════════════════════════════════════════════════════════════════════════
   CAPABILITY-DENIAL NEGATIVES — must FAIL to compile via the real CLI.
   Each asserts: exit non-zero AND the expected stable code appears.
   ════════════════════════════════════════════════════════════════════════════ *)

let assert_cli_denied ~name ~source ~code () =
  let exit_code, out = run_check source in
  if exit_code = 0 then
    Alcotest.failf
      "%s: expected the program to FAIL to compile (non-zero exit), but it \
       compiled cleanly. Output:\n%s" name out;
  let needle = "[" ^ code ^ "]" in
  let found =
    let n = String.length needle and h = String.length out in
    let rec at i = if i + n > h then false
      else if String.sub out i n = needle then true else at (i + 1) in
    at 0
  in
  if not found then
    Alcotest.failf
      "%s: program failed (exit %d) as required, but the expected code %s was \
       not in the output. Output:\n%s" name exit_code needle out

(* (1) Effect without capability: handler uses `time` but `requires []`. *)
let deny_effect_src = cap_deny_src

(* (2) Undeclared capability name in `requires`. *)
let deny_unknown_cap_src = {|#lang tesl
module Deny exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int) -> Int requires [totallyBogusCap] = n
|}

(* (3) Capability used in `requires` without importing its name. *)
let deny_unimported_cap_src = {|#lang tesl
module Deny exposing []
import Tesl.Prelude exposing [String]
import Tesl.Id exposing [generatePrefixedId]
handler h() -> String requires [random] =
  generatePrefixedId "x"
|}

(* (4) Proof obligation not satisfied at a call site (a value lacking its
       required proof is passed to a function that demands it). *)
let deny_proof_unsat_src = {|#lang tesl
module Deny exposing [use]
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check mkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "no"
fn needsProof(n: Int ::: IsPositive n) -> Int = n
fn use(n: Int) -> Int =
  needsProof n
|}

(* (5) Handler isolation: a plain fn calls a handler directly. *)
let deny_handler_iso_src = handler_iso_src

(* ════════════════════════════════════════════════════════════════════════════
   RUNNER
   ════════════════════════════════════════════════════════════════════════════ *)

let () =
  Alcotest.run "DiagSnapshots" [
    "snapshot/check_source", [
      Alcotest.test_case "parse error E000" `Quick
        (snapshot_source ~name:"parse E000" ~source:parse_src ~expected:parse_expected);
      Alcotest.test_case "type error T001" `Quick
        (snapshot_source ~name:"type T001" ~source:type_src ~expected:type_expected);
      Alcotest.test_case "proof error P001" `Quick
        (snapshot_source ~name:"proof P001" ~source:proof_src ~expected:proof_expected);
      Alcotest.test_case "validation error V001 (bad server route)" `Quick
        (snapshot_source ~name:"validation V001" ~source:validation_src ~expected:validation_expected);
      Alcotest.test_case "capability denial V001 (effect w/o capability)" `Quick
        (snapshot_source ~name:"cap deny V001" ~source:cap_deny_src ~expected:cap_deny_expected);
      Alcotest.test_case "handler isolation V001" `Quick
        (snapshot_source ~name:"handler iso V001" ~source:handler_iso_src ~expected:handler_iso_expected);
      Alcotest.test_case "codec field-coverage V001" `Quick
        (snapshot_source ~name:"codec field V001" ~source:codec_field_src ~expected:codec_field_expected);
      Alcotest.test_case "codec proof-coverage V001" `Quick
        (snapshot_source ~name:"codec proof V001" ~source:codec_proof_src ~expected:codec_proof_expected);
    ];
    "snapshot/linter", [
      Alcotest.test_case "E002 missing #lang tesl" `Quick
        (snapshot_lint ~name:"E002" ~source:lint_e002_src ~expected:lint_e002_expected);
      Alcotest.test_case "E010 tab character" `Quick
        (snapshot_lint ~name:"E010" ~source:lint_e010_src ~expected:lint_e010_expected);
      Alcotest.test_case "W010 trailing whitespace" `Quick
        (snapshot_lint ~name:"W010" ~source:lint_w010_src ~expected:lint_w010_expected);
      Alcotest.test_case "W020 module name casing" `Quick
        (snapshot_lint ~name:"W020" ~source:lint_w020_src ~expected:lint_w020_expected);
      Alcotest.test_case "W022 function name casing" `Quick
        (snapshot_lint ~name:"W022" ~source:lint_w022_src ~expected:lint_w022_expected);
      Alcotest.test_case "W050 unused import" `Quick
        (snapshot_lint ~name:"W050" ~source:lint_w050_src ~expected:lint_w050_expected);
    ];
    "denial/must-not-compile", [
      Alcotest.test_case "effect without capability fails" `Quick
        (assert_cli_denied ~name:"deny effect" ~source:deny_effect_src ~code:"V001");
      Alcotest.test_case "undeclared capability fails" `Quick
        (assert_cli_denied ~name:"deny unknown cap" ~source:deny_unknown_cap_src ~code:"P001");
      Alcotest.test_case "unimported capability fails" `Quick
        (assert_cli_denied ~name:"deny unimported cap" ~source:deny_unimported_cap_src ~code:"P001");
      Alcotest.test_case "unsatisfied proof obligation fails" `Quick
        (assert_cli_denied ~name:"deny proof unsat" ~source:deny_proof_unsat_src ~code:"V001");
      Alcotest.test_case "handler called from code fails" `Quick
        (assert_cli_denied ~name:"deny handler iso" ~source:deny_handler_iso_src ~code:"V001");
    ];
  ]
