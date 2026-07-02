(** AI-Suite — Tesl.Agent CAPABILITY bounding (negative + positive controls).

    Proves the STATIC checker enforces that every Tesl.Agent entry point which
    contacts a provider — [ask], [askReply], [askWith], [askFor], [converse],
    [agentRun] — requires the [aiProvider] capability, and that an enclosing
    consumer (fn / handler / worker) which calls one of them MUST declare a
    capability that covers [aiProvider] (either [aiProvider] itself, or a
    capability whose transitive `implies` closure reaches it).  A consumer that
    grants nothing, an unrelated capability, or a capability that does NOT imply
    [aiProvider] is rejected at compile time with error[V001]:

      handler 'H' uses [aiProvider] but does not declare the required capabilities
      worker  'W' uses [aiProvider] but does not declare the required capabilities
      fn      'F' uses privileged operations and callees requiring [aiProvider] but does not declare them

    Plus: a TOOL whose validate/dispatch fn requires a privileged capability
    (e.g. dbWrite) flows that requirement transitively through
    tool/Agent{tools}/askReply into the enclosing consumer — granting [aiProvider]
    alone is not enough; the consumer must also declare [dbWrite].

    Positive controls: granting [aiProvider] directly, or a capability that
    implies it (1-hop, 2-hop, or alongside other caps) compiles cleanly.

    Hardening: [should_fail] additionally fails if the compiler output contains
    any runtime-leak marker — the rejection must be STATIC and must never reach
    emitted Racket where a dynamic guard would catch it.

    Modeled byte-for-byte on the proofsuite harness in
    compiler/test/test_proofsuite_capability.ml. *)

open Alcotest

(* ── Compiler resolution (mirrors the proofsuite harness) ─────────────────── *)

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

(* Derive a kebab-case file name from the module/library header so the compiler's
   "module header does not match file name" check stays quiet (it resolves
   imports by file name).  Identical to the proofsuite harness. *)
let file_name_of_src content =
  let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
  try
    ignore (Str.search_forward re content 0);
    let mname = Str.matched_group 2 content in
    let buf = Buffer.create (String.length mname + 4) in
    String.iteri (fun i c ->
      if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
      else if c >= 'A' && c <= 'Z' then
        (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
      else Buffer.add_char buf c) mname;
    Buffer.contents buf ^ ".tesl"
  with Not_found -> "test.tesl"

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-aisuite" "" in
  let path = Filename.concat dir (file_name_of_src content) in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

(* Runtime-leak markers: presence means the program reached emitted Racket and
   relied on a dynamic guard, i.e. the static checker FAILED to reject it. *)
let leak_markers = [
  "raise-user-error"; "check-fail"; "context...:"; "context ...:";
  ".rkt:"; "racket/"; "/collects/"; "errortrace"; "uncaught exception";
]

let assert_no_runtime_leak pat out =
  List.iter (fun m ->
    let re = Str.regexp_string m in
    if (try ignore (Str.search_forward re out 0); true with Not_found -> false)
    then failf "STATIC-REJECTION VIOLATED for %S: output contains runtime-leak \
                marker %S — rejection leaked to runtime:\n%s" pat m out)
    leak_markers

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled \
                            cleanly:\n%s" pat out;
    assert_no_runtime_leak pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let has_err =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false in
    if code <> 0 || has_err then
      failf "expected clean compile, got (exit %d):\n%s" code out)

(* ── AI entry points: each performs inference, hence requires [aiProvider]. ──
   For each we capture the imports it needs, the consumer return type, and a
   body fragment that CALLS it from a context where [agent]/[prompt] are bound.
   The fragment is glued into a fn/handler body that prebinds:
     let agent = Agent { provider: mockProvider ["r1","r2"], systemPrompt: "x", maxTokens: 100, tools: [] }
   and (for converse) a conversation.  All return types are concrete so the
   capability check (which runs regardless of inference) is reached. *)

type ai_fn = {
  ai_tag    : string;    (* short id for the test name *)
  ai_extra_import : string;  (* additional Tesl.Agent names to import *)
  ai_ret    : string;    (* concrete return type of the consumer *)
  ai_body   : string;    (* statements; [agent] and [prompt] are in scope *)
}

(* The shared import line lists every Agent name any fragment might use, so a
   single import block serves all fragments (unused imports are harmless). *)
let agent_imports extra =
  Printf.sprintf
    "import Tesl.Agent exposing [aiProvider, Agent, LlmProvider, AgentReply, \
     mockProvider, ask, askReply, askWith, askFor, replyText, \
     newConversation, converse, turnReply, agentRun, decodeAs%s]"
    (if extra = "" then "" else ", " ^ extra)

(* A structured-output decoder shared by the askFor fragment. *)
let summary_decl = {|
record Summary { title: String }
codec Summary {
  toJson_forbidden
  fromJson [ { title <- "title" with_codec stringCodec } ]
}
fn decodeSummary(j: String) -> Summary = decodeAs "Summary" j
|}

let ai_fns = [
  { ai_tag = "ask"; ai_extra_import = ""; ai_ret = "String";
    ai_body = "ask agent prompt" };
  { ai_tag = "askReply"; ai_extra_import = ""; ai_ret = "AgentReply";
    ai_body = "askReply agent prompt" };
  { ai_tag = "askWith"; ai_extra_import = ""; ai_ret = "AgentReply";
    ai_body = "let byok = mockProvider [\"o\"]\n  askWith agent prompt byok" };
  { ai_tag = "askFor"; ai_extra_import = ""; ai_ret = "Summary";
    ai_body = "askFor agent prompt decodeSummary 2" };
  { ai_tag = "converse"; ai_extra_import = ""; ai_ret = "String";
    ai_body = "let conv = newConversation agent\n  let t = converse conv prompt\n  replyText (turnReply t)" };
]

(* agentRun is special: it returns Unit-ish and takes a publisher fn; it is
   only legal in a worker. We thread it through a dedicated worker matrix. *)

(* ── Insufficient grants: capabilities that do NOT cover aiProvider. ──────────
   Each entry: (tag, requires-list-text, prelude-decls-needed). The prelude
   carries any `import`/`capability` lines the requires-list references. *)
type grant = {
  g_tag  : string;
  g_req  : string;    (* text placed inside requires [...] *)
  g_pre  : string;    (* extra top-level decls (imports / capability lines) *)
}

let insufficient_grants = [
  { g_tag = "none";       g_req = "";          g_pre = "" };
  { g_tag = "dbRead";     g_req = "dbRead";    g_pre = "import Tesl.DB exposing [dbRead]" };
  { g_tag = "dbWrite";    g_req = "dbWrite";   g_pre = "import Tesl.DB exposing [dbWrite]" };
  { g_tag = "time";       g_req = "time";      g_pre = "import Tesl.Time exposing [time]" };
  { g_tag = "random";     g_req = "random";    g_pre = "import Tesl.Random exposing [random]" };
  { g_tag = "jwt";        g_req = "jwt";       g_pre = "import Tesl.Auth exposing [jwt]" };
  { g_tag = "queueRead";  g_req = "queueRead"; g_pre = "import Tesl.Queue exposing [queueRead]" };
  { g_tag = "queueWrite"; g_req = "queueWrite"; g_pre = "import Tesl.Queue exposing [queueWrite]" };
  { g_tag = "pubsub";     g_req = "pubsub";    g_pre = "import Tesl.Queue exposing [pubsub]" };
  (* httpClient is what aiProvider IMPLIES, not the reverse — granting the
     implied capability must NOT satisfy the requirement for aiProvider. *)
  { g_tag = "httpClient"; g_req = "httpClient"; g_pre = "import Tesl.HttpClient exposing [httpClient]" };
  (* custom capabilities whose implication closure never reaches aiProvider *)
  { g_tag = "customLog";  g_req = "logCap";    g_pre = "import Tesl.DB exposing [dbRead]\ncapability logCap implies dbRead" };
  { g_tag = "customDeep"; g_req = "deepCap";   g_pre = "import Tesl.DB exposing [dbWrite]\ncapability midCap implies dbWrite\ncapability deepCap implies midCap" };
  (* a custom cap that implies httpClient (the thing aiProvider implies) — still
     does NOT imply aiProvider, so must be rejected. *)
  { g_tag = "customHttp"; g_req = "netCap";    g_pre = "import Tesl.HttpClient exposing [httpClient]\ncapability netCap implies httpClient" };
]

(* ── Sufficient grants: capabilities that DO cover aiProvider. ──────────────── *)
let sufficient_grants = [
  { g_tag = "aiProvider"; g_req = "aiProvider"; g_pre = "" };
  { g_tag = "impliesDirect"; g_req = "bot";
    g_pre = "capability bot implies aiProvider" };
  { g_tag = "impliesOneHop"; g_req = "svc";
    g_pre = "capability mid implies aiProvider\ncapability svc implies mid" };
  { g_tag = "impliesTwoHop"; g_req = "top";
    g_pre = "capability mid implies aiProvider\ncapability svc implies mid\ncapability top implies svc" };
  { g_tag = "impliesAlongside"; g_req = "svc";
    g_pre = "import Tesl.DB exposing [dbRead]\ncapability svc implies dbRead, aiProvider" };
]

(* ── Consumer kinds: fn / handler / worker — each with its own V001 wording. *)
type consumer = {
  c_id   : string;
  c_pat  : string;       (* regex for the expected V001 message *)
  (* given (return-type, requires-text, body) -> the consumer declaration *)
  c_decl : ret:string -> req:string -> body:string -> string;
  c_extra_decls : string;  (* e.g. the JobRec a worker needs *)
}

let consumers = [
  { c_id = "fn";
    c_pat = "fn '.*' uses privileged operations and callees requiring \\[aiProvider\\] but does not declare them";
    c_extra_decls = "";
    c_decl = (fun ~ret ~req ~body ->
      Printf.sprintf
        "fn consume(prompt: String) -> %s requires [%s] =\n  let agent = Agent { provider: mockProvider [\"r1\", \"r2\"], systemPrompt: \"x\", maxTokens: 100, tools: [] }\n  %s"
        ret req body) };
  { c_id = "handler";
    c_pat = "handler '.*' uses \\[aiProvider\\] but does not declare the required capabilities";
    c_extra_decls = "";
    c_decl = (fun ~ret ~req ~body ->
      Printf.sprintf
        "handler consume(prompt: String) -> %s requires [%s] =\n  let agent = Agent { provider: mockProvider [\"r1\", \"r2\"], systemPrompt: \"x\", maxTokens: 100, tools: [] }\n  %s"
        ret req body) };
  { c_id = "worker";
    c_pat = "worker '.*' uses \\[aiProvider\\] but does not declare the required capabilities";
    c_extra_decls = "record JobRec { prompt: String }";
    c_decl = (fun ~ret:_ ~req ~body ->
      (* worker returns its job; we bind the body's value to _r and ignore it *)
      Printf.sprintf
        "worker consume(j: JobRec) requires [%s] =\n  let prompt = j.prompt\n  let agent = Agent { provider: mockProvider [\"r1\", \"r2\"], systemPrompt: \"x\", maxTokens: 100, tools: [] }\n  let _r = %s\n  j"
        req body) };
]

(* Build a full module from (consumer, ai_fn, grant, expectation). [mod_id] must
   be unique so the derived file name is unique per case. *)
let build_module ~mod_id ~consumer ~ai ~grant ~body_override =
  let body = match body_override with Some b -> b | None -> ai.ai_body in
  (* For the worker, the ai_body's final expression becomes the _r binding; for
     fn/handler it is the tail expression. The worker c_decl already wraps it.
     But askWith/converse fragments contain `let`-prefixed lines; for the worker
     we must keep them as a block before the final value. We handle this by
     placing the whole fragment as the body and letting c_decl wrap. The worker
     wrapper does `let _r = <body>` which breaks for multi-line fragments, so we
     restrict the worker matrix to single-expression fragments below. *)
  Printf.sprintf
{|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [Int, String, Bool, List, Unit]
import Tesl.Json exposing [stringCodec, intCodec]
%s
%s
%s
%s
%s
|}
    mod_id
    (agent_imports ai.ai_extra_import)
    grant.g_pre
    (if consumer.c_extra_decls = "" then "" else consumer.c_extra_decls)
    (if ai.ai_tag = "askFor" then summary_decl else "")
    (consumer.c_decl ~ret:ai.ai_ret ~req:grant.g_req ~body)

(* ── N1 — negative matrix: AI fn × consumer × insufficient grant. ──────────── *)
(* For the WORKER consumer, multi-line `let`-prefixed fragments (askWith,
   converse) don't fit the `let _r = <expr>` wrapper, so the worker matrix uses
   only single-expression AI fns (ask, askReply, askFor). fn/handler use all. *)

let single_expr_ai = List.filter (fun a ->
  List.mem a.ai_tag ["ask"; "askReply"; "askFor"]) ai_fns

let ai_fns_for consumer =
  if consumer.c_id = "worker" then single_expr_ai else ai_fns

let neg_matrix =
  List.concat_map (fun consumer ->
    List.concat_map (fun ai ->
      List.map (fun grant ->
        let mod_id =
          Printf.sprintf "AiNeg%s%s%s"
            (String.capitalize_ascii consumer.c_id)
            (String.capitalize_ascii ai.ai_tag)
            (String.capitalize_ascii grant.g_tag) in
        Printf.sprintf "N1 %s/%s grant=%s -> V001" consumer.c_id ai.ai_tag grant.g_tag,
        (fun () ->
           should_fail consumer.c_pat
             (build_module ~mod_id ~consumer ~ai ~grant ~body_override:None)))
        insufficient_grants)
      (ai_fns_for consumer))
    consumers

(* ── P1 — positive matrix: AI fn × consumer × sufficient grant. ────────────── *)

let pos_matrix =
  List.concat_map (fun consumer ->
    List.concat_map (fun ai ->
      List.map (fun grant ->
        let mod_id =
          Printf.sprintf "AiPos%s%s%s"
            (String.capitalize_ascii consumer.c_id)
            (String.capitalize_ascii ai.ai_tag)
            (String.capitalize_ascii grant.g_tag) in
        Printf.sprintf "P1 %s/%s grant=%s -> ok" consumer.c_id ai.ai_tag grant.g_tag,
        (fun () ->
           should_pass
             (build_module ~mod_id ~consumer ~ai ~grant ~body_override:None)))
        sufficient_grants)
      (ai_fns_for consumer))
    consumers

(* ── N2 — agentRun on a worker: a dedicated matrix (publisher fn + Unit). ───── *)
(* agentRun is worker-only in practice; the publisher fn returns Unit (the unit
   value literal is `Unit`). We sweep insufficient + sufficient grants. *)

let build_agentrun ~mod_id ~req ~pre =
  Printf.sprintf
{|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [String, Unit]
import Tesl.Agent exposing [aiProvider, Agent, mockProvider, agentRun]
%s
record JobRec { prompt: String }
fn publishStep(event: String) -> Unit = Unit
worker doJob(j: JobRec) requires [%s] =
  let agent = Agent { provider: mockProvider ["r1"], systemPrompt: "x", maxTokens: 100, tools: [] }
  let _r = agentRun agent j.prompt publishStep
  j
|}
    mod_id pre req

let agentrun_neg =
  List.map (fun grant ->
    let mod_id = Printf.sprintf "AiRunNeg%s" (String.capitalize_ascii grant.g_tag) in
    Printf.sprintf "N2 agentRun/worker grant=%s -> V001" grant.g_tag,
    (fun () ->
       should_fail "worker 'doJob' uses \\[aiProvider\\] but does not declare the required capabilities"
         (build_agentrun ~mod_id ~req:grant.g_req ~pre:grant.g_pre)))
    insufficient_grants

let agentrun_pos =
  List.map (fun grant ->
    let mod_id = Printf.sprintf "AiRunPos%s" (String.capitalize_ascii grant.g_tag) in
    Printf.sprintf "P2 agentRun/worker grant=%s -> ok" grant.g_tag,
    (fun () ->
       should_pass (build_agentrun ~mod_id ~req:grant.g_req ~pre:grant.g_pre)))
    sufficient_grants

(* ── N3 — tool-fn privileged-cap flow: a tool whose dispatch/validate fn needs
   dbWrite flows that requirement through tool/Agent{tools}/askReply into the
   enclosing consumer. Granting aiProvider alone is NOT enough — the consumer
   must ALSO declare dbWrite. Sweep consumer × which-tool-fn-carries-the-cap. *)

let tool_cap_imports = "import Tesl.Agent exposing [aiProvider, Agent, AgentReply, mockToolProvider, toolUseStep, textStep, tool, askReply, replyText, decodeAs]"

let echo_decls = {|
record EchoArgs { text: String }
codec EchoArgs {
  toJson_forbidden
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
|}

(* which tool fn carries dbWrite: the validator or the dispatcher *)
let tool_cap_sites = [
  "dispatch",
  "fn validateEcho(argsJson: String) -> EchoArgs = decodeAs \"EchoArgs\" argsJson\nfn dispatchEcho(args: EchoArgs) -> String requires [dbWrite] = args.text";
  "validate",
  "fn validateEcho(argsJson: String) -> EchoArgs requires [dbWrite] =\n  let _x = decodeAs \"EchoArgs\" argsJson\n  _x\nfn dispatchEcho(args: EchoArgs) -> String = args.text";
]

let tool_consumer_decl c_id req =
  let prelude = {|  let echoTool = tool "echo" "Echo" "{}" validateEcho dispatchEcho
  let agent = Agent { provider: mockToolProvider [toolUseStep "echo" "c1" "{\"text\":\"hi\"}", textStep "done"], systemPrompt: "x", maxTokens: 256, tools: [echoTool] }
  let reply = askReply agent prompt
  replyText reply|} in
  match c_id with
  | "fn" ->
    Printf.sprintf "fn consume(prompt: String) -> String requires [%s] =\n%s" req prelude
  | "handler" ->
    Printf.sprintf "handler consume(prompt: String) -> String requires [%s] =\n%s" req prelude
  | _ ->
    Printf.sprintf
      "record JobRec { prompt: String }\nworker consume(j: JobRec) requires [%s] =\n  let prompt = j.prompt\n%s\n  j"
      req prelude

(* the V001 pattern names dbWrite (the still-missing cap), for any consumer kind *)
let tool_cap_pattern c_id =
  match c_id with
  | "fn" -> "fn 'consume' uses privileged operations and callees requiring .*dbWrite.* but does not declare them"
  | "handler" -> "handler 'consume' uses .*dbWrite.* but does not declare the required capabilities"
  | _ -> "worker 'consume' uses .*dbWrite.* but does not declare the required capabilities"

let build_tool_module ~mod_id ~c_id ~site_decls ~req =
  Printf.sprintf
{|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.DB exposing [dbWrite]
import Tesl.Json exposing [stringCodec]
%s
%s
%s
%s
|}
    mod_id tool_cap_imports echo_decls site_decls (tool_consumer_decl c_id req)

(* Negative: consumer grants ONLY aiProvider (covers the agent call) but NOT the
   tool fn's dbWrite -> rejected for dbWrite. *)
let tool_cap_neg =
  List.concat_map (fun (site_tag, site_decls) ->
    List.map (fun c_id ->
      let mod_id = Printf.sprintf "AiToolNeg%s%s"
          (String.capitalize_ascii c_id) (String.capitalize_ascii site_tag) in
      Printf.sprintf "N3 tool-%s-cap/%s grants aiProvider only -> V001(dbWrite)" site_tag c_id,
      (fun () ->
         should_fail (tool_cap_pattern c_id)
           (build_tool_module ~mod_id ~c_id ~site_decls ~req:"aiProvider")))
      ["fn"; "handler"; "worker"])
    tool_cap_sites

(* Positive: consumer grants BOTH aiProvider and dbWrite -> compiles. *)
let tool_cap_pos =
  List.concat_map (fun (site_tag, site_decls) ->
    List.map (fun c_id ->
      let mod_id = Printf.sprintf "AiToolPos%s%s"
          (String.capitalize_ascii c_id) (String.capitalize_ascii site_tag) in
      Printf.sprintf "P3 tool-%s-cap/%s grants aiProvider+dbWrite -> ok" site_tag c_id,
      (fun () ->
         should_pass
           (build_tool_module ~mod_id ~c_id ~site_decls ~req:"aiProvider, dbWrite")))
      ["fn"; "handler"; "worker"])
    tool_cap_sites

(* ── N4 — explicit single-shot controls (named, for readability of failures). *)

let test_N4_handler_no_cap () =
  should_fail "handler 'h' uses \\[aiProvider\\] but does not declare the required capabilities"
    {|
#lang tesl
module AiCtrlH exposing []
import Tesl.Prelude exposing [String]
import Tesl.Agent exposing [aiProvider, Agent, mockProvider, ask]
handler h(prompt: String) -> String requires [] =
  let agent = Agent { provider: mockProvider ["hi"], systemPrompt: "x", maxTokens: 100, tools: [] }
  ask agent prompt
|}

let test_N4_fn_unrelated_cap () =
  should_fail "fn 'f' uses privileged operations and callees requiring \\[aiProvider\\] but does not declare them"
    {|
#lang tesl
module AiCtrlF exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbRead]
import Tesl.Agent exposing [aiProvider, Agent, mockProvider, ask]
fn f(prompt: String) -> String requires [dbRead] =
  let agent = Agent { provider: mockProvider ["hi"], systemPrompt: "x", maxTokens: 100, tools: [] }
  ask agent prompt
|}

let test_N4_custom_nonimplying_cap () =
  should_fail "handler 'h' uses \\[aiProvider\\] but does not declare the required capabilities"
    {|
#lang tesl
module AiCtrlN exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbRead]
import Tesl.Agent exposing [aiProvider, Agent, mockProvider, ask]
capability logger implies dbRead
handler h(prompt: String) -> String requires [logger] =
  let agent = Agent { provider: mockProvider ["hi"], systemPrompt: "x", maxTokens: 100, tools: [] }
  ask agent prompt
|}

let test_P4_direct_aiProvider () =
  should_pass
    {|
#lang tesl
module AiCtrlPos exposing []
import Tesl.Prelude exposing [String]
import Tesl.Agent exposing [aiProvider, Agent, mockProvider, ask]
handler h(prompt: String) -> String requires [aiProvider] =
  let agent = Agent { provider: mockProvider ["hi"], systemPrompt: "x", maxTokens: 100, tools: [] }
  ask agent prompt
|}

let test_P4_pure_constructors_need_no_cap () =
  (* Agent {...} / mockProvider / replyText etc. are PURE — building an agent
     and inspecting a reply value requires NO capability; only the inference
     entry points do. A consumer that builds an agent but never calls a
     provider compiles with no requires. *)
  should_pass
    {|
#lang tesl
module AiPureCtor exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Agent exposing [aiProvider, Agent, LlmProvider, mockProvider]
fn buildAgent(sys: String) -> Agent =
  Agent { provider: mockProvider ["hi"], systemPrompt: sys, maxTokens: 100, tools: [] }
|}

(* ── Runner ────────────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (n, f) -> test_case n `Quick f) lst

let () =
  run "AiSuite-Capability" [
    "N1-negative-matrix (ai-fn × consumer × insufficient-grant)",
      to_cases neg_matrix;
    "P1-positive-matrix (ai-fn × consumer × sufficient-grant)",
      to_cases pos_matrix;
    "N2-agentRun-worker-negative", to_cases agentrun_neg;
    "P2-agentRun-worker-positive", to_cases agentrun_pos;
    "N3-tool-fn-privileged-cap-flow-negative", to_cases tool_cap_neg;
    "P3-tool-fn-privileged-cap-flow-positive", to_cases tool_cap_pos;
    "N4/P4-named-controls", to_cases [
      "N4 handler no cap", test_N4_handler_no_cap;
      "N4 fn unrelated cap (dbRead)", test_N4_fn_unrelated_cap;
      "N4 custom non-implying cap", test_N4_custom_nonimplying_cap;
      "P4 direct aiProvider (positive)", test_P4_direct_aiProvider;
      "P4 pure constructors need no cap (positive)", test_P4_pure_constructors_need_no_cap;
    ];
  ]
