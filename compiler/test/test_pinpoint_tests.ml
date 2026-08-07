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
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r65" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then begin
          Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end else
          Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

(* let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out) *)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)


let agent_block_uses_env_cap_without_declaring_it () =
  should_fail ".*but does not declare the required capabilities.*" {|
  module Lesson63AiStructuredOutput exposing [
    Assistant
  ]

  import Tesl.Prelude exposing [Int, String]
  import Tesl.Json exposing [stringCodec, intCodec]
  import Tesl.Agent exposing [
    aiProvider,
    LlmProvider,
    mockProvider,
    Agent,
    anthropic,
    askWith,
    askFor,
    textStep,
    decodeAs,
    toolUseStep,
    replyText,
    mockToolProvider,
    replyToolCalls,
  ]
  import Tesl.Env exposing [requireEnv]

  # no capability specified to read from environment vars
  agent Assistant = Agent {
    provider: anthropic "asdf" "claude-opus-4-8"
    systemPrompt: "You are a helpful assistant. Be concise."
    tools: []
    maxTokens: 256
  }

  test "a multi-parameter tool decodes each argument by type" requires [] {
    #let call = toolUseStep "bookTable" "c1" "{\"restaurant\":\"Chez Tesl\",\"guests\":4}"
    let final = textStep "All set!"
    let mock = mockToolProvider [] [final]
    let reply = askWith Assistant "Book Chez Tesl for 4" mock
    expect (replyText reply) == "All set!"
    #expect (replyToolCalls reply) == 1
  }
|}
  
let agent_block_uses_env_cap_without_declaring_all () =
  should_fail "agent.*provider.*requiring.*envRead.*" {|
  module Lesson63AiStructuredOutput exposing [
    Assistant
  ]

  import Tesl.Prelude exposing [Int, String]
  import Tesl.Json exposing [stringCodec, intCodec]
  import Tesl.Agent exposing [
    aiProvider,
    LlmProvider,
    mockProvider,
    Agent,
    anthropic,
    askWith,
    askFor,
    decodeAs,
    replyText,
  ]
  import Tesl.Env exposing [requireEnv]

  # no capability specified to read from environment vars
  agent Assistant requires [aiProvider] = Agent {
    provider: anthropic (requireEnv "ANTHROPIC_API_KEY") "claude-opus-4-8"
    systemPrompt: "You are a helpful assistant. Be concise."
    tools: []
    maxTokens: 256
  }
|}
  
let agent_block_uses_env_cap_without_declaring_systemPrompt () =
  should_fail "agent.*systemPrompt.*requiring.*envRead.*" {|
  module Lesson63AiStructuredOutput exposing [
    Assistant
  ]

  import Tesl.Prelude exposing [Int, String]
  import Tesl.Json exposing [stringCodec, intCodec]
  import Tesl.Agent exposing [
    aiProvider,
    LlmProvider,
    mockProvider,
    Agent,
    anthropic,
    askWith,
    askFor,
    decodeAs,
    replyText,
  ]
  import Tesl.Env exposing [requireEnv]

  # no capability specified to read from environment vars
  agent Assistant requires [aiProvider] = Agent {
    provider: anthropic "ds" "claude-opus-4-8"
    systemPrompt: (requireEnv "PROMPT")
    tools: []
    maxTokens: 256
  }
|}

  
let agent_block_uses_env_cap_without_declaring_maxTokens () =
  should_fail "agent.*maxTokens.*requiring.*envRead.*" {|
  module Lesson63AiStructuredOutput exposing [
    Assistant
  ]

  import Tesl.Prelude exposing [Int, String]
  import Tesl.Json exposing [stringCodec, intCodec]
  import Tesl.Agent exposing [
    aiProvider,
    LlmProvider,
    mockProvider,
    Agent,
    anthropic,
    askWith,
    askFor,
    decodeAs,
    replyText,
  ]
  import Tesl.Env exposing [requireEnv]

  # no capability specified to read from environment vars
  agent Assistant requires [aiProvider] = Agent {
    provider: anthropic "ds" "claude-opus-4-8"
    systemPrompt: "asdf"
    tools: []
    maxTokens: (requireEnv "maxTokens")
  }
|}

let agent_block_missing_import () =
  should_fail ".*anthropic.*requires.*import Tesl.Agent.*" {|
  module AiLiveCheck exposing [AiServer, askClaude, AskRequest]

import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Json exposing [stringCodec]
import Tesl.Env exposing [envInt, envRead, requireEnv]
import Tesl.Telemetry exposing [initTelemetry]
import Tesl.App exposing [App]
import Tesl.Agent exposing [aiProvider, askReply, replyText]

capability liveAi implies aiProvider

# The agent's provider/model/apiKey are the live production binding. `apiKey` is
# read from the environment when inference runs.
agent Assistant requires [liveAi, envRead] = Agent {
  provider: anthropic (requireEnv "ANTHROPIC_API_KEY") "claude-opus-4-8"
  systemPrompt: "You are a helpful assistant. Answer in one short sentence."
  tools: []
  maxTokens: 256
}

record AskRequest {
  prompt: String
}

codec AskRequest {
  toJson_forbidden
  fromJson [
    {
      prompt <- "prompt" with_codec stringCodec
    }
  ]
}

# Calls the REAL model (askReply requires the aiProvider capability) and returns
# the assistant's text. There is intentionally no mock here — this is the live path.
handler post askClaude(req: AskRequest) -> String
  requires [liveAi] =
  replyText (askReply Assistant req.prompt)

api AiApi {
  post "/ask"
    body req: AskRequest
    -> String
}

server AiServer for AiApi {
  askClaude
}

# An in-memory database keeps this runnable with only the API key set — no
# PostgreSQL required for the smoke check.
database LiveDb = Database {
  schema: "ai_live"
  entities: []
  backend: Memory
}

main() -> App requires [liveAi, envRead] =
  let _ = initTelemetry service "ai-live-check" endpoint "in-memory" console True
  let port = envInt "PORT" 8088
  App {
    database: LiveDb
    api: AiServer
    port: port
  }

|}


let agent_block_missing_local_import () =
  should_fail ".*tool.*missing_func.*" {|
  module AiLiveCheck exposing [AiServer, askClaude, AskRequest]

import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Json exposing [stringCodec]
import Tesl.Env exposing [envInt, envRead, requireEnv]
import Tesl.Telemetry exposing [initTelemetry]
import Tesl.App exposing [App]
import Tesl.Agent exposing [aiProvider, askReply, asTool, anthropic, replyText]

capability liveAi implies aiProvider

# The agent's provider/model/apiKey are the live production binding. `apiKey` is
# read from the environment when inference runs.
agent Assistant requires [liveAi, envRead] = Agent {
  provider: anthropic (requireEnv "ANTHROPIC_API_KEY") "claude-opus-4-8"
  systemPrompt: "You are a helpful assistant. Answer in one short sentence."
  tools: [asTool missing_func]
  maxTokens: 256
}

record AskRequest {
  prompt: String
}

codec AskRequest {
  toJson_forbidden
  fromJson [
    {
      prompt <- "prompt" with_codec stringCodec
    }
  ]
}

# Calls the REAL model (askReply requires the aiProvider capability) and returns
# the assistant's text. There is intentionally no mock here — this is the live path.
handler post askClaude(req: AskRequest) -> String
  requires [liveAi] =
  replyText (askReply Assistant req.prompt)

api AiApi {
  post "/ask"
    body req: AskRequest
    -> String
}

server AiServer for AiApi {
  askClaude
}

# An in-memory database keeps this runnable with only the API key set — no
# PostgreSQL required for the smoke check.
database LiveDb = Database {
  schema: "ai_live"
  entities: []
  backend: Memory
}

main() -> App requires [liveAi, envRead] =
  let _ = initTelemetry service "ai-live-check" endpoint "in-memory" console True
  let port = envInt "PORT" 8088
  App {
    database: LiveDb
    api: AiServer
    port: port
  }

|}


(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "PinPoints01" [
    "capabilities", [
      test_case "PIN01C01" `Quick agent_block_uses_env_cap_without_declaring_it;
      test_case "PIN01C02" `Quick agent_block_uses_env_cap_without_declaring_all;
      test_case "PIN01C03" `Quick agent_block_uses_env_cap_without_declaring_systemPrompt;
      test_case "PIN01C04" `Quick agent_block_uses_env_cap_without_declaring_maxTokens;
    ];
    "imports", [
      test_case "PIN01I01" `Quick agent_block_missing_import;
      test_case "PIN01I02" `Quick agent_block_missing_local_import;
    ];
  ]
