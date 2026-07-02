(** A4 — capability completeness (external re-review §5.2 + §6.2).

    §5.2 B-GUARD-CAP-ESCAPE — `collect_needed_capabilities` skipped a `case`-arm
      `where` guard, so a privileged effect hidden in a guard (an `env` read, a
      `select`/write) escaped the capability charge: a handler `requires []` could
      run it undeclared, with no runtime backstop.  Now the guard is folded exactly
      like the arm body.  Verified: the same effect in the arm BODY / an `if`
      condition was already caught, so this closes the guard-specific gap.  The
      escape was transitive (a caller of the under-declared fn) and fired in
      workers — both covered because the shared collector now sees the guard.

    §6.2 A7-c-agent-config-leak — an `agent = Agent { … }` config_expr is kept and
      re-emitted, so a gated stdlib name in a config slot (`envString`/`requireEnv`
      in `apiKey`) passed --check yet died at `raco expand`.  The config is now
      swept for stdlib-name imports like a function body. *)

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

let with_src src f =
  let dir = Filename.temp_dir "tesl-a4" "" in
  let re = Str.regexp "module[ \t]+\\([A-Z][A-Za-z0-9_]*\\)" in
  ignore (Str.search_forward re src 0);
  let m = Str.matched_group 1 src in
  let buf = Buffer.create 16 in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
    else Buffer.add_char buf c) m;
  let path = Filename.concat dir (Buffer.contents buf ^ ".tesl") in
  let oc = open_out path in output_string oc src; close_out oc;
  Fun.protect ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_fail ?(pat="") label src =
  with_src src (fun p ->
    let code, out = run_cc ["--check"; p] in
    if code = 0 then failf "%s: expected rejection but COMPILED:\n%s" label src;
    if pat <> "" then
      (try ignore (Str.search_forward (Str.regexp_case_fold pat) out 0)
       with Not_found -> failf "%s: rejected but message !~ %S:\n%s" label pat out))

let should_pass label src =
  with_src src (fun p ->
    let code, out = run_cc ["--check"; p] in
    if code <> 0 then failf "%s: expected COMPILE but failed:\n%s" label out)

(* ── §5.2 guard-escape ────────────────────────────────────────────────────── *)
let cap_pat = "does not declare\\|privileged operations\\|requiring \\[\\|capabilit"

(* env read hidden in a handler case-arm guard, requires [] *)
let neg_env_guard = {|#lang tesl
module EnvGuard exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Env exposing [env, envRead]
handler h(m: Maybe String) -> String requires [] =
  case m of
    Something s where env "SECRET" == Nothing ->
      "match"
    _ ->
      "no"
|}

(* dbRead select hidden in a guard, requires [] *)
let neg_select_guard = {|#lang tesl
module SelGuard exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead]
entity Todo table "todos" primaryKey id { id: String }
handler h(m: Maybe String) -> String requires [] =
  case m of
    Something s where (selectOne t from Todo where t.id == s) == Nothing ->
      "found"
    _ ->
      "no"
|}

(* transitive: a plain fn with the guard effect but requires []; a caller also
   under-declares.  The under-declared fn itself must be rejected. *)
let neg_transitive_guard = {|#lang tesl
module TransGuard exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Env exposing [env, envRead]
fn leaf(m: Maybe String) -> String requires [] =
  case m of
    Something s where env "SECRET" == Nothing -> "a"
    _ -> "b"
|}

(* worker body guard escape *)
let neg_worker_guard = {|#lang tesl
module WorkerGuard exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Env exposing [env, envRead]
import Tesl.Queue exposing [queueRead]
record Job { arg: String }
worker doJob(j: Job) requires [queueRead] =
  case Something j.arg of
    Something s where env "SECRET" == Nothing -> j
    _ -> j
|}

(* positive: the guard effect IS declared → compiles *)
let pos_guard_declared = {|#lang tesl
module GuardOk exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Env exposing [env, envRead]
handler h(m: Maybe String) -> String requires [envRead] =
  case m of
    Something s where env "SECRET" == Nothing ->
      "match"
    _ ->
      "no"
|}

(* positive: a pure guard needs no capability *)
let pos_pure_guard = {|#lang tesl
module PureGuard exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
handler h(m: Maybe String) -> String requires [] =
  case m of
    Something s where s == "x" ->
      "match"
    _ ->
      "no"
|}

(* ── §6.2 agent-config leak ───────────────────────────────────────────────── *)
(* The gated name `requireEnv` sits in the provider `apiKey` slot; without the
   Tesl.Env import it passes the (old) checker but is unbound at runtime. *)
let neg_agent_config_leak = {|#lang tesl
module AgentLeak exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Agent exposing [aiProvider]
agent Assistant requires [aiProvider] = Agent {
  provider: anthropic (requireEnv "ANTHROPIC_KEY") "claude-3"
  systemPrompt: "hi"
  tools: []
  maxTokens: 256
}
|}

let pos_agent_config_imported = {|#lang tesl
module AgentOk exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Env exposing [requireEnv, envRead]
import Tesl.Agent exposing [aiProvider]
agent Assistant requires [aiProvider] = Agent {
  provider: anthropic (requireEnv "ANTHROPIC_KEY") "claude-3"
  systemPrompt: "hi"
  tools: []
  maxTokens: 256
}
|}

let import_pat = "requires.*import\\|not in scope\\|unbound\\|import Tesl"

let () =
  run "A4-Capability-Completeness" [
    "§5.2 case-arm guard escape (negatives)", [
      test_case "env read in handler guard" `Quick
        (fun () -> should_fail ~pat:cap_pat "env-guard" neg_env_guard);
      test_case "select (dbRead) in handler guard" `Quick
        (fun () -> should_fail ~pat:cap_pat "select-guard" neg_select_guard);
      test_case "guard effect in a plain fn (transitive root)" `Quick
        (fun () -> should_fail ~pat:cap_pat "transitive-guard" neg_transitive_guard);
      test_case "guard effect in a worker body" `Quick
        (fun () -> should_fail ~pat:cap_pat "worker-guard" neg_worker_guard);
    ];
    "§5.2 guard (positives)", [
      test_case "guard effect with declared capability compiles" `Quick
        (fun () -> should_pass "guard-declared" pos_guard_declared);
      test_case "pure guard needs no capability" `Quick
        (fun () -> should_pass "pure-guard" pos_pure_guard);
    ];
    "§6.2 agent-config stdlib leak", [
      test_case "gated name in agent config without import is rejected" `Quick
        (fun () -> should_fail ~pat:import_pat "agent-leak" neg_agent_config_leak);
      test_case "agent config with proper import compiles" `Quick
        (fun () -> should_pass "agent-ok" pos_agent_config_imported);
    ];
  ]
