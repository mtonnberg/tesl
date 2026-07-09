(** `asTool` on an exposing-imported fn (DESIGN: asTool cross-module class).

    Before the fix, `asTool importedFn` TYPE-CHECKED and then either:
      - tools-list / argument position: fell through to the generic app path
        and emitted the literal unbound `(asTool importedFn)` — a module that
        fails to LOAD (`asTool` has no runtime binding); or
      - statement/tail position: hit the issue-#24 defense failwith — a
        COMPILER crash ("please report this bug").
    Meanwhile `check_agent_tool_refs` resolved tool names in m.decls only, so
    an imported fn in an Agent tools list inside a fn/const body was a FALSE
    check error, and Agent blocks inside `test` bodies escaped ALL tool
    validation.

    The fix has three coordinated parts:
      A. emitter harvest: fn_tool_decls/fn_return_specs are filled from
         directly imported local modules (ImportExposing plain names, MainKind
         excluded, locals win) with origin recorded in imported_tool_fns;
      B. dispatch shape: an imported tool fn with concrete caps delegates them
         through the issue-#30 procedure registry
         (`call-with-delegated-capabilities`) — its capability IDENTIFIERS are
         not require-bound cross-module; local fns keep byte-identical output;
      C. checker: tool names resolve local-first then via exposing-imported
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
  let code, out = run_cc [path] in
  if code <> 0 then failf "emit of %s failed:\n%s" what out;
  out

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

let imported_tools_list_checks_and_emits () =
  with_project ~lib:tool_lib ~main:tools_list_main (fun ~lib_p:_ ~main_p ->
    (* Before the fix this was a FALSE check error ("tool 'getWeather' is not
       a function declared in this module") for the fn-body list, and the
       agent-block list emitted the literal `(asTool getWeather)`. *)
    check_ok "main (imported tools list)" main_p;
    let out = emit_ok "main (imported tools list)" main_p in
    if contains "(asTool " out then
      failf "imported tool fn must never emit the unbound literal (asTool ...):\n%s" out;
    if not (contains {|(__tart_tool "getWeather"|} out) then
      failf "imported tool fn must lower to __tart_tool:\n%s" out;
    if not (contains {|\"city\":{\"type\":\"string\"}|} out) then
      failf "tool schema must be derived from the imported fn's params:\n%s" out;
    if not (contains {|(cons "city" 'string)|} out) then
      failf "arg decode tags must be derived from the imported fn's params:\n%s" out;
    if not (contains "(apply getWeather _decoded)" out) then
      failf "caps-free imported fn keeps the bare apply dispatch:\n%s" out)

let imported_caps_fn_delegates () =
  with_project ~lib:tool_lib ~main:tools_list_main (fun ~lib_p:_ ~main_p ->
    let out = emit_ok "main (caps delegation)" main_p in
    (* stamp's capability IDENTIFIER (libStamp) is define-capability-bound in
       lib.rkt only; the dispatch must delegate through the issue-#30 registry
       instead of emitting `(with-capabilities (libStamp) ...)`. *)
    if not (contains
              "(lambda (_decoded) (call-with-delegated-capabilities stamp (lambda () (apply stamp _decoded))))"
              out) then
      failf "imported caps-carrying tool fn must delegate via the procedure registry:\n%s" out;
    if contains "(with-capabilities (libStamp) (apply stamp" out then
      failf "imported tool fn must NOT use the local with-capabilities shape (unbound cap identifier):\n%s" out)

(* ── accepted: statement/tail position (the old issue-#24 crash path) ────── *)

let statement_position_imported_fn_emits () =
  let main = {|module Main exposing []
import Tesl.Prelude exposing [String]
|} ^ agent_imports ^ {|import Lib exposing [getWeather]

fn makeTool() -> Tool =
  asTool getWeather
|} in
  with_project ~lib:tool_lib ~main (fun ~lib_p:_ ~main_p ->
    check_ok "main (statement-position asTool)" main_p;
    let out = emit_ok "main (statement-position asTool)" main_p in
    if not (contains {|(__tart_tool "getWeather"|} out) then
      failf "statement-position asTool on an imported fn must lower to __tart_tool (was a compiler crash):\n%s" out)

(* ── local dispatch stays byte-identical (the harvest must not repaint it) ── *)

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
    if not (contains "(with-capabilities (localCap) (apply echo _decoded))" out) then
      failf "LOCAL caps-carrying tool fn must keep the with-capabilities shape byte-identical:\n%s" out;
    if contains "call-with-delegated-capabilities echo" out then
      failf "local tool fn must not switch to registry delegation:\n%s" out)

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
    if not (contains "(with-capabilities (localCap) (apply stamp _decoded))" out) then
      failf "a local fn whose name the import does not expose must keep the LOCAL dispatch shape:\n%s" out;
    if contains "call-with-delegated-capabilities stamp" out then
      failf "unexposed imported same-name fn must not be harvested over the local decl:\n%s" out)

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
      test_case "tools list checks and emits __tart_tool" `Quick
        imported_tools_list_checks_and_emits;
      test_case "caps-carrying imported fn delegates via registry" `Quick
        imported_caps_fn_delegates;
      test_case "statement position emits (was compiler crash)" `Quick
        statement_position_imported_fn_emits;
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
