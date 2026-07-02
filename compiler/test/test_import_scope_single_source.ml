(** A7 — single-source stdlib import scope.

    Closes the "typechecks-but-unbound-at-runtime" CLASS: a stdlib name that sits
    in {!Type_system.stdlib_env} and would emit a `(require tesl/X.rkt)` when its
    module is imported, but was ABSENT from the checker's hand-maintained scope
    tables, passed `--check` yet was `unbound identifier` at runtime.

    After A7:
      - ONE authoritative registry {!Type_system.stdlib_home_module} drives the
        "needs import M" decision (dotted rows DERIVED from tesl_module_exports,
        bare rows from stdlib_bare_home_module).
      - the scope check runs over ONE generic AST fold that covers ALL
        declaration contexts, including test / api-test / load-test bodies that
        previously escaped the DFunc/DConst-only walk.

    This suite pins:
      (neg-fn)     a bare Tesl.Telemetry fn without its import is a `--check` error
                   (the reconfirmed hole; was exit=0);
      (neg-test)   the SAME name inside a `test { … }` body is flagged (proves the
                   fold now reaches test contexts);
      (neg-agent)  the whole Tesl.Agent bare API (mockProvider/ask/decodeAs/askFor)
                   without `import Tesl.Agent` is flagged;
      (pos)        the same programs WITH the correct import check clean, and
                   always-available names (check/identity/operators) never need an
                   import;
      (no-over)    config-block `env "…"` without `import Tesl.Env` is NOT flagged
                   (compile-time desugared);
      (exhaustive) every function-valued stdlib_env name is classified: either
                   always-available, a constructor, a compile-time-lowered form,
                   or has a home-module entry — so a future name cannot silently
                   re-open the hole;
      (emit-cover) every home module resolves to a Racket file path in the
                   emitter's module_path_table — the require path and the scope
                   decision cannot drift (belt-and-suspenders for the derivation). *)

open Alcotest

(* ── Subprocess harness (mirrors test_a6 / the antagonistic suites) ────────── *)

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

(* The compiler resolves a module by its file name, so the temp file must be
   named after the `module X` header (kebab-cased) or a spurious V001
   name-mismatch error masks the property under test. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-a7" "" in
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

(* [pat] is a (case-insensitive) regexp; keep it free of regexp specials so it
   reads as the literal guarantee. *)
let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* [pat] must NOT appear in the output (used to prove a specific over-rejection
   diagnostic is absent even if the program has OTHER, unrelated errors). *)
let should_not_report pat src =
  with_temp_file src (fun path ->
    let _code, out = run_compiler ["--check"; path] in
    let re = Str.regexp_case_fold pat in
    (try
       ignore (Str.search_forward re out 0);
       failf "did NOT expect %S in output, but got:\n%s" pat out
     with Not_found -> ()))

(* ── (neg-fn) bare Tesl.Telemetry fn without import — the reconfirmed hole ─── *)

let test_bare_telemetry_fn_rejected () =
  should_fail "initTelemetry.*requires .import Tesl.Telemetry" {|
#lang tesl
module A7Telemetry exposing [main]
import Tesl.Prelude exposing [Unit]
fn main() -> Unit = initTelemetry
|}

(* ── (neg-test) SAME name inside a test body — proves the fold reaches DTest ─ *)

let test_bare_telemetry_in_test_rejected () =
  should_fail "initTelemetry.*requires .import Tesl.Telemetry" {|
#lang tesl
module A7TelemetryTest exposing [main]
import Tesl.Prelude exposing [Unit]
fn main() -> Unit = Unit
test "uses initTelemetry" {
  let x = initTelemetry
  expect x == x
}
|}

(* ── (neg-agent) whole Tesl.Agent bare API without import ──────────────────── *)

let test_bare_mockprovider_fn_rejected () =
  should_fail "mockProvider.*requires .import Tesl.Agent" {|
#lang tesl
module A7Agent exposing [main]
import Tesl.Prelude exposing [Unit, String, List]
fn main() -> Unit =
  let _ = mockProvider ["hi"]
  Unit
|}

let test_bare_ask_in_test_rejected () =
  (* `ask` used ONLY inside a test body, with NO Tesl.Agent import — proves the
     fold covers DTest for the whole Agent API, not just fn bodies. *)
  should_fail "ask.*requires .import Tesl.Agent" {|
#lang tesl
module A7AgentAskTest exposing [main]
import Tesl.Prelude exposing [Unit, String]
fn main() -> Unit = Unit
test "uses ask" {
  let r = ask "not-an-agent" "hi"
  expect r == r
}
|}

let test_bare_decodeas_rejected () =
  should_fail "decodeAs.*requires .import Tesl.Agent" {|
#lang tesl
module A7Decode exposing [main]
import Tesl.Prelude exposing [String]
fn main() -> String = decodeAs "Foo" "{}"
|}

let test_bare_uuidcodec_rejected () =
  should_fail "uuidV4Codec.*requires .import Tesl.UUID" {|
#lang tesl
module A7Uuid exposing [main]
import Tesl.Prelude exposing [String]
fn main() -> String = uuidV4Codec
|}

(* ── (pos) same programs WITH the import check clean ───────────────────────── *)

let test_telemetry_with_import_ok () =
  should_pass {|
#lang tesl
module A7TelemetryOk exposing [main]
import Tesl.Prelude exposing [Unit]
import Tesl.Telemetry exposing [initTelemetry]
fn main() -> Unit = initTelemetry
|}

let test_agent_in_test_with_import_ok () =
  should_pass {|
#lang tesl
module A7AgentOk exposing [main]
import Tesl.Prelude exposing [Unit, String, List]
import Tesl.Agent exposing [Agent, LlmProvider, mockProvider, ask, aiProvider]
capability bot implies aiProvider
fn main() -> Unit = Unit
test "ask via mock" requires [bot] {
  let a = Agent { provider: mockProvider ["hi"], systemPrompt: "x", maxTokens: 10, tools: [] }
  let r = ask a "hi"
  expect r == r
}
|}

let test_always_available_no_import_ok () =
  should_pass {|
#lang tesl
module A7Always exposing [main]
import Tesl.Prelude exposing [Int]
fn main() -> Int = check identity 5
|}

(* ── (no-over) config-block env WITHOUT Tesl.Env must NOT be flagged ───────── *)

(* The `Database { dbName: env "…" }` config record is desugared at compile time;
   its `env` uses emit no runtime env call, so the scope check must NOT demand
   `import Tesl.Env`.  The program below imports the correct Database schema so it
   compiles clean AND proves the env-scope diagnostic never fires. *)
let test_config_block_env_not_flagged () =
  should_not_report "requires .import Tesl.Env" {|
#lang tesl
module A7ConfigEnv exposing [main]
import Tesl.Prelude exposing [Unit]
import Tesl.Database exposing [
  Database, DatabaseBackend, Postgres, Memory, PostgresConfig, PostgresConnection, TcpConnection
]
entity Widget {
  id: String
} table "widgets" primary key id
database Db = Database {
  schema: "public",
  entities: [Widget],
  backend: Postgres {
    config: PostgresConfig {
      dbName: env "A7_DB",
      user: env "A7_USER",
      password: env "A7_PASS",
      connection: TcpConnection { host: env "A7_HOST", port: 5432 }
    }
  }
}
fn main() -> Unit = Unit
|}

(* ── (exhaustive) every stdlib_env fn is classified ────────────────────────── *)

(* A constructor is an ADT/newtype value: uppercase-initial name, OR one of the
   known lowercase-free forms.  Constructors are handled by the constructor-scope
   machinery and are DELIBERATELY excluded from the home-module registry, so they
   must not be required to have an entry. *)
let is_constructor name =
  String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z'

(* Compile-time-lowered Agent provider/tool forms: they lower via the `__tart_`
   desugar path (emit_racket) and have no plain runtime require, so they are
   intentionally OUT of the home-module registry (demanding an import for them
   would contradict the emitter). *)
let compile_time_lowered = [ "anthropic"; "openai"; "mistral"; "local"; "asTool" ]

(* [cli.args] is a dotted-but-lowercase-prefix bare value (not a Module.fn form
   and not in tesl_module_exports); it is intentionally un-gated (matches the
   pre-A7 behaviour where the "cli" prefix resolved to nothing).  Exclude it from
   the exhaustiveness requirement so it is not a false offender. *)
let intentionally_ungated = [ "cli.args" ]

let test_every_fn_env_name_is_classified () =
  (* Every stdlib_env name (function-valued or a runtime value that lives in an
     import-gated module) must be classified: always-available, a constructor, a
     compile-time-lowered form, intentionally un-gated, or have a home-module
     entry.  An unclassified name is exactly the re-opened-hole regression. *)
  let offenders =
    Type_system.stdlib_env
    |> List.filter_map (fun (name, _sch) ->
         if is_constructor name then None
         else if List.mem name compile_time_lowered then None
         else if List.mem name intentionally_ungated then None
         else if List.mem name Type_system.always_available_stdlib_names then None
         else if Type_system.stdlib_home_module_of name <> None then None
         else Some name)
    |> List.sort_uniq String.compare
  in
  if offenders <> [] then
    failf
      "A7 single-source gap: the following stdlib_env names are neither \
       always-available, a constructor, a compile-time-lowered form, nor have a \
       Type_system.stdlib_home_module entry.  Classify each (add to \
       always_available_stdlib_names or stdlib_bare_home_module):\n  %s"
      (String.concat "\n  " offenders)

(* ── (emit-cover) every home module has a Racket file path ─────────────────── *)

let test_every_home_module_has_emit_path () =
  let missing =
    Type_system.stdlib_home_module
    |> List.map snd
    |> List.sort_uniq String.compare
    |> List.filter (fun m -> not (Hashtbl.mem Emit_racket.module_path_table m))
  in
  if missing <> [] then
    failf
      "A7 drift guard: home modules resolved by Type_system.stdlib_home_module \
       have no entry in Emit_racket.module_path_table, so a name could resolve \
       to a module the emitter cannot require:\n  %s"
      (String.concat "\n  " missing)

let () =
  run "A7 single-source stdlib import scope" [
    "negatives-fn-and-test-contexts", [
      test_case "bare initTelemetry (fn body) rejected" `Quick
        test_bare_telemetry_fn_rejected;
      test_case "bare initTelemetry (test body) rejected" `Quick
        test_bare_telemetry_in_test_rejected;
      test_case "bare mockProvider (fn body) rejected" `Quick
        test_bare_mockprovider_fn_rejected;
      test_case "bare ask (test body) rejected" `Quick
        test_bare_ask_in_test_rejected;
      test_case "bare decodeAs rejected" `Quick
        test_bare_decodeas_rejected;
      test_case "bare uuidV4Codec rejected" `Quick
        test_bare_uuidcodec_rejected;
    ];
    "positives-no-over-rejection", [
      test_case "initTelemetry with import compiles" `Quick
        test_telemetry_with_import_ok;
      test_case "mockProvider/ask in test with import compiles" `Quick
        test_agent_in_test_with_import_ok;
      test_case "always-available names need no import" `Quick
        test_always_available_no_import_ok;
      test_case "config-block env is not flagged" `Quick
        test_config_block_env_not_flagged;
    ];
    "single-source-invariants", [
      test_case "every stdlib_env name is classified" `Quick
        test_every_fn_env_name_is_classified;
      test_case "every home module has an emit path" `Quick
        test_every_home_module_has_emit_path;
    ];
  ]
