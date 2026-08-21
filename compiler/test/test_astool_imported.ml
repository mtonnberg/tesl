(** `asTool` on an exposing-imported fn (DESIGN: asTool cross-module class).

    Before the checker fix, imported names were rejected inconsistently or hit
    the issue-#24 defense failwith in statement/tail position.  The checker now
    accepts exposed imported functions and validates their signatures; the Go
    backend rejects them explicitly until cross-package tool dispatch exists.
    Meanwhile `check_agent_tool_refs` resolved tool names in m.decls only, so
    an imported fn in an Agent tools list inside a fn/const body was a FALSE
    check error, and Agent blocks inside `test` bodies escaped ALL tool
    validation.

    The contract has two coordinated parts:
      A. Go backend boundary: imported tool refs fail closed with a targeted
         diagnostic until cross-package dispatch is supported; local fns emit
         executable teslrt.ToolOf dispatch;
      B. checker: tool names resolve local-first then via exposing-imported
         fn decls (same AGENT-1 param rules), the agent walk covers DTest
         bodies, and a whole-module walk validates EVERY `asTool`-headed
         application (bare in-scope fn reference or a targeted error —
         including a guided message for qualified `asTool M.f`). *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let c2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl")

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128+n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let contains needle hay =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let with_project ~lib ~main f =
  let dir = Filename.temp_dir "tesl-astool" "" in
  let write name src =
    let p = Filename.concat dir name in
    let oc = open_out p in output_string oc src; close_out oc; p
  in
  let lib_p = write "lib.tesl" lib in
  let main_p = write "main.tesl" main in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) [lib_p; main_p];
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f ~lib_p ~main_p)

let check_ok what path =
  let code, out = run_cc ["--check"; path] in
  if code <> 0 then failf "check of %s must pass:\n%s" what out

let check_fails what path =
  let code, out = run_cc ["--check"; path] in
  if code = 0 then failf "check of %s must FAIL" what;
  out

let emit_ok what path =
  match Compile.compile_go_file path with
  | Compile.GoFailure diagnostics ->
    failf "Go emit of %s failed:\n%s" what
      (String.concat "\n"
         (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    (match List.find_opt (fun (a : Emit_go.artifact) ->
       Filename.basename a.path = "module.go"
       && Filename.basename (Filename.dirname a.path) = "teslmodmain") artifacts with
     | Some artifact -> artifact.contents
     | None -> failf "Go emit of %s did not produce the Main module artifact" what)

let emit_fails what path =
  match Compile.compile_go_file path with
  | Compile.GoSuccess _ -> failf "Go emit of %s must fail closed" what
  | Compile.GoFailure diagnostics ->
    String.concat "\n"
      (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)

(* The shared tool library: a caps-free tool fn, a caps-carrying one, and one
   whose param violates the AGENT-1 prim whitelist. *)
let tool_lib = {|module Lib exposing [getWeather, stamp, badTool, libStamp]
import Tesl.Prelude exposing [String, Int, List]
import Tesl.String exposing [String.concat]

capability libStamp

# Look up the current weather for a city.
fn getWeather(city: String) -> String =
  String.concat "It is sunny in " city

# Stamp a message with an audit prefix.
fn stamp(msg: String) -> String requires [libStamp] =
  String.concat "stamped: " msg

# Params must be agent-prims; List String is not.
fn badTool(items: List String) -> String =
  "no"
|}

let agent_imports = {|import Tesl.Agent exposing [
  aiProvider, Agent, Tool, asTool, mockToolProvider
]
|}

(* ── accepted: imported fn in an Agent tools list (agent block + fn body) ── *)

let tools_list_main = {|module Main exposing []
import Tesl.Prelude exposing [String]
|} ^ agent_imports ^ {|import Lib exposing [getWeather, stamp, libStamp]

capability bot implies aiProvider, libStamp

agent WeatherAgent requires [bot] = Agent {
  provider: mockToolProvider []
  systemPrompt: "s"
  tools: [asTool getWeather, asTool stamp]
  maxTokens: 128
}

fn makeAgent() -> Agent requires [bot] =
  Agent {
    provider: mockToolProvider []
    systemPrompt: "s"
    maxTokens: 128
    tools: [asTool getWeather]
  }
|}

let imported_tools_list_checks_and_fails_closed () =
  with_project ~lib:tool_lib ~main:tools_list_main (fun ~lib_p:_ ~main_p ->
    (* This used to be a false checker error for the fn-body list. *)
    check_ok "main (imported tools list)" main_p;
    let out = emit_fails "main (imported tools list)" main_p in
    if not (contains "supports a function declared in this module" out) then
      failf "imported asTool must fail closed at the Go backend boundary:\n%s" out)

let imported_caps_fn_fails_closed () =
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String]
|} ^ agent_imports ^ {|import Lib exposing [stamp, libStamp]

capability bot implies aiProvider, libStamp

fn makeTool() -> Tool requires [bot] =
  asTool stamp
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    check_ok "main (imported caps tool)" main_p;
    let out = emit_fails "main (imported caps tool)" main_p in
    if not (contains "`stamp` is not one" out) then
      failf "caps-carrying imported asTool must name its unsupported target:\n%s" out)

(* ── accepted: statement/tail position (the old issue-#24 crash path) ────── *)

let statement_position_imported_fn_fails_closed () =
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String]
|} ^ agent_imports ^ {|import Lib exposing [getWeather]

fn makeTool() -> Tool =
  asTool getWeather
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    check_ok "main (statement-position asTool)" main_p;
    let out = emit_fails "main (statement-position asTool)" main_p in
    if contains "please report this bug" out
       || not (contains "supports a function declared in this module" out) then
      failf "statement-position imported asTool must be a targeted Go rejection, not a compiler crash:\n%s" out)

(* ── local dispatch remains executable Go ───────────────────────────────── *)

let local_fn_dispatch_byte_stable () =
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.concat]
|} ^ agent_imports ^ {|import Lib exposing [getWeather]

capability localCap

# Echo a message.
fn echo(msg: String) -> String requires [localCap] =
  String.concat "echo " msg

fn makeTool() -> Tool requires [localCap] =
  asTool echo
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    let out = emit_ok "main (local dispatch)" main_p in
    if not (contains {|teslrt.ToolOf("echo"|} out)
       || not (contains "return echo(teslArgs[0].(string))" out) then
      failf "local caps-carrying tool fn must emit executable Go dispatch:\n%s" out)

(* Same-name policy (harvest risk 4): a local fn COLLIDING with an
   exposing-imported name is rejected up front by the existing shadow
   diagnostic — the emitter's locals-first mem-guard is defense-in-depth
   behind it.  A same-name fn the import does NOT expose is simply never
   harvested: the local decl keeps the byte-identical local dispatch shape. *)
let local_shadow_policy () =
  let main_conflict = {|module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.concat]
|} ^ agent_imports ^ {|import Lib exposing [stamp, libStamp]

capability localCap

# Local stamp collides with the exposing-imported one.
fn stamp(msg: String) -> String requires [localCap] =
  String.concat "local " msg

fn makeTool() -> Tool requires [localCap] =
  asTool stamp
|} in
  with_project ~lib:tool_lib ~main:main_conflict (fun ~lib_p:_ ~main_p ->
    let out = check_fails "main (exposed-name collision)" main_p in
    if not (contains "shadows imported name" out) then
      failf "a local fn colliding with an exposing-imported name must hit the shadow diagnostic:\n%s" out);
  let main_local = {|module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.concat]
|} ^ agent_imports ^ {|import Lib exposing [getWeather]

capability localCap

# Same name as Lib's (unexposed here) stamp — purely local.
fn stamp(msg: String) -> String requires [localCap] =
  String.concat "local " msg

fn makeTool() -> Tool requires [localCap] =
  asTool stamp
|} in
  with_project ~lib:tool_lib ~main:main_local (fun ~lib_p:_ ~main_p ->
    let out = emit_ok "main (unexposed same-name)" main_p in
    if not (contains {|teslrt.ToolOf("stamp"|} out)
       || not (contains "return stamp(teslArgs[0].(string))" out) then
      failf "unexposed same-name fn must emit local Go dispatch:\n%s" out)

(* ── rejected: fail-closed checker walk (no crash, no unbound emit) ──────── *)

let unknown_fn_check_error_not_crash () =
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String]
|} ^ agent_imports ^ {|
fn makeTool() -> Tool =
  asTool ghostFn
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    let out = check_fails "main (unknown asTool target)" main_p in
    if not (contains "is not a function declared in this module or exposed" out) then
      failf "unknown asTool target must get the fn-existence error:\n%s" out;
    (* The plain-emit path must ALSO surface a check error, never the emitter's
       issue-#24 "please report this bug" crash. *)
    let code, out = run_cc [main_p] in
    if code = 0 then failf "emit of an unknown asTool target must fail:\n%s" out;
    if contains "please report this bug" out then
      failf "unknown asTool target must be a check error, not a compiler crash:\n%s" out)

let import_all_not_in_scope () =
  (* ImportAll brings no plain names into scope, so `asTool fn` under a bare
     `import Lib` must be the checker error (never a crash / literal emit). *)
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String]
|} ^ agent_imports ^ {|import Lib

fn makeTool() -> Tool =
  asTool getWeather
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    let out = check_fails "main (ImportAll asTool)" main_p in
    if not (contains "is not a function declared in this module or exposed" out) then
      failf "asTool under ImportAll must fail with the fn-existence error:\n%s" out)

let non_fn_rejected () =
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String, Int]
|} ^ agent_imports ^ {|
maxRetries = 3

fn makeTool() -> Tool =
  asTool maxRetries
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    let out = check_fails "main (asTool on non-fn)" main_p in
    if not (contains "is not a function declared in this module or exposed" out) then
      failf "asTool on a non-fn (const) must be a check error:\n%s" out)

let qualified_ref_guided_error () =
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String]
|} ^ agent_imports ^ {|import Lib

fn makeTool() -> Tool =
  asTool Lib.getWeather
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    let out = check_fails "main (qualified asTool)" main_p in
    if not (contains "import Lib exposing [getWeather]" out) then
      failf "qualified `asTool Lib.getWeather` must get the guided exposing-import error:\n%s" out)

let agent_in_test_body_validated () =
  (* Agent blocks inside `test` bodies escaped ALL tool checks (the walk
     covered only DFunc/DConst). *)
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String, Int]
|} ^ agent_imports ^ {|
capability bot implies aiProvider

test "agent in test body" requires [bot] {
  let agent = Agent { provider: mockToolProvider [], systemPrompt: "s", maxTokens: 64, tools: [asTool ghostTool] }
  expect 1 == 1
}
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    let out = check_fails "main (Agent in test body)" main_p in
    if not (contains "is not a function declared in this module or exposed" out) then
      failf "Agent tools list inside a test body must be validated:\n%s" out)

let imported_fn_agent1_param_rules_apply () =
  (* AGENT-1 runs on the IMPORTED fd's params too: badTool takes List String. *)
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String]
|} ^ agent_imports ^ {|import Lib exposing [badTool]

capability bot implies aiProvider

agent BadAgent requires [bot] = Agent {
  provider: mockToolProvider []
  systemPrompt: "s"
  tools: [asTool badTool]
  maxTokens: 64
}
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    let out = check_fails "main (imported AGENT-1)" main_p in
    if not (contains "tool 'badTool' parameter 'items' must be" out) then
      failf "AGENT-1 prim whitelist must run on imported tool fn params:\n%s" out)

let () =
  run "asTool-imported" [
    "accepted — imported fn as tool", [
      test_case "tools list checks; Go backend fails closed" `Quick
        imported_tools_list_checks_and_fails_closed;
      test_case "caps-carrying imported fn fails closed" `Quick
        imported_caps_fn_fails_closed;
      test_case "statement position rejects without compiler crash" `Quick
        statement_position_imported_fn_fails_closed;
    ];
    "local paths unchanged", [
      test_case "local caps dispatch byte-stable" `Quick
        local_fn_dispatch_byte_stable;
      test_case "same-name policy: collision rejected, unexposed stays local" `Quick
        local_shadow_policy;
    ];
    "rejected — fail-closed asTool validation", [
      test_case "unknown target is a check error, not a crash" `Quick
        unknown_fn_check_error_not_crash;
      test_case "ImportAll target is not in scope" `Quick
        import_all_not_in_scope;
      test_case "non-fn target rejected" `Quick
        non_fn_rejected;
      test_case "qualified M.f gets guided exposing error" `Quick
        qualified_ref_guided_error;
      test_case "Agent in test body is validated" `Quick
        agent_in_test_body_validated;
      test_case "AGENT-1 param rules run on imported fns" `Quick
        imported_fn_agent1_param_rules_apply;
    ];
  ]
