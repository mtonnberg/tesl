(** test_httpclient_integration.ml — Runtime integration tests for HttpClient.

    These tests compile real Tesl programs that use HttpClient.get/post/put/delete
    and run the generated Racket code as a *real Tesl App server*, then exercise
    the outbound HTTP calls by hitting the server's endpoints over HTTP.

    The modern Tesl language has no script-style `main() -> Unit` and no
    `with capabilities [...]` blocks.  Capabilities flow only from a declaration's
    `requires` plus the `main() -> App` entry point's auto-grant: the App desugar
    wraps server startup in the capability + database scope derived from
    `main.requires`.  So a program that needs `httpClient` must:

      - declare a `handler` with `requires [httpClient]` that performs the call,
      - expose it through an `api` + `server`,
      - return an `App` from `main() -> App requires [httpClient]`.

    Each test therefore:
      1. starts a Python mock HTTP server (the *upstream* the handler calls),
      2. compiles a Tesl App whose handlers call HttpClient.{get,post,put,delete}
         against that mock and return the status code / body,
      3. starts the compiled Tesl App server on a free port (racket <file>.rkt
         runs the App's `(module+ main … serve …)`),
      4. GETs the App endpoint, which triggers the outbound HttpClient call,
      5. asserts on the HTTP response (the echoed status / body).

    The capability-gate test stays a `--check` compile-failure test (it has no
    runnable behaviour — the point is that the compiler rejects it).

    Tests skip gracefully if racket or python3 are unavailable.
*)

(* ── Utilities ──────────────────────────────────────────────────────────────── *)

let contains needle haystack =
  let n = String.length needle in
  let m = String.length haystack in
  if n > m then false
  else begin
    let found = ref false in
    for i = 0 to m - n do
      if String.sub haystack i n = needle then found := true
    done;
    !found
  end

(** Pick an ephemeral free port by binding to port: 0 and reading the assigned port. *)
let pick_free_port () =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt sock Unix.SO_REUSEADDR true;
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port = match Unix.getsockname sock with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> 0
  in
  Unix.close sock;
  port

(** Run a command, capturing stdout and stderr.  Returns (stdout, stderr, exit_code). *)
let run_cmd ?(timeout_secs=30) cmd args =
  let tmp_out = Filename.temp_file "tesl_int_out" ".txt" in
  let tmp_err = Filename.temp_file "tesl_int_err" ".txt" in
  let fd_out = Unix.openfile tmp_out [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let fd_err = Unix.openfile tmp_err [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let pid = Unix.create_process cmd (Array.append [|cmd|] args) Unix.stdin fd_out fd_err in
  Unix.close fd_out;
  Unix.close fd_err;
  let deadline = Unix.gettimeofday () +. float_of_int timeout_secs in
  let rec wait () =
    if Unix.gettimeofday () > deadline then begin
      (try Unix.kill pid Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] pid) with _ -> ());
      ("", "", -1)
    end else
      match (try Unix.waitpid [Unix.WNOHANG] pid with _ -> (0, Unix.WEXITED 0)) with
      | (0, _) -> Unix.sleepf 0.05; wait ()
      | (_, Unix.WEXITED c) ->
        let out = In_channel.(with_open_text tmp_out input_all) in
        let err = In_channel.(with_open_text tmp_err input_all) in
        (try Sys.remove tmp_out with _ -> ());
        (try Sys.remove tmp_err with _ -> ());
        (out, err, c)
      | (_, _) ->
        (try Sys.remove tmp_out with _ -> ());
        (try Sys.remove tmp_err with _ -> ());
        ("", "", -1)
  in
  wait ()

(** Wait until TCP port is accepting connections, or timeout. *)
let wait_for_port host port ~timeout_secs =
  let deadline = Unix.gettimeofday () +. float_of_int timeout_secs in
  let rec try_connect () =
    if Unix.gettimeofday () > deadline then false
    else
      let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      let addr = Unix.ADDR_INET (Unix.inet_addr_of_string host, port) in
      (try
        Unix.connect sock addr;
        Unix.close sock;
        true
      with _ ->
        Unix.close sock;
        Unix.sleepf 0.1;
        try_connect ())
  in
  try_connect ()

(** Find the tesl main.exe compiler relative to this test executable. *)
let find_compiler () =
  let exe_dir = Filename.dirname Sys.executable_name in
  (* _build/default/test → _build/default/bin *)
  let candidate = Filename.concat (Filename.dirname exe_dir) "bin/main.exe" in
  if Sys.file_exists candidate then candidate
  else
    (* Try the build directory pattern *)
    let alt = Filename.concat exe_dir "../bin/main.exe" in
    if Sys.file_exists alt then alt
    else "/home/mikael/repos_wsl/tesl-github/tesl/compiler/_build/default/bin/main.exe"


(** Generate a unique PascalCase module name for a temporary Tesl file.
    The Tesl compiler requires the module header to match the filename. *)
let fresh_module_name prefix =
  Printf.sprintf "%s%d" prefix (Random.int 9_000_000 + 1_000_000)

(** Compile a Tesl source string and return path to .rkt file.
    [module_name] must match the module header in [src].
    The caller is responsible for deleting the returned file. *)
let compile_tesl_src ~module_name src =
  let compiler = find_compiler () in
  let tesl_tmp = Filename.concat (Filename.get_temp_dir_name ()) (module_name ^ ".tesl") in
  let rkt_tmp  = Filename.concat (Filename.get_temp_dir_name ()) (module_name ^ ".rkt")  in
  Out_channel.(with_open_text tesl_tmp (fun oc -> output_string oc src));
  (* First check syntax *)
  let (_, check_err, check_code) = run_cmd ~timeout_secs:20 compiler [|"--check"; tesl_tmp|] in
  if check_code <> 0 then begin
    (try Sys.remove tesl_tmp with _ -> ());
    failwith ("Tesl --check failed: " ^ check_err)
  end;
  (* Compile to Racket *)
  let (out, err, code) = run_cmd ~timeout_secs:20 compiler [|tesl_tmp|] in
  (try Sys.remove tesl_tmp with _ -> ());
  if code <> 0 then
    failwith ("Tesl compile failed: " ^ err)
  else begin
    Out_channel.(with_open_text rkt_tmp (fun oc -> output_string oc out));
    rkt_tmp
  end

(** Check that --check exits non-zero for given source.
    [module_name] must match the module header in [src]. *)
let compile_tesl_check_fails ~module_name src =
  let compiler = find_compiler () in
  let tesl_tmp = Filename.concat (Filename.get_temp_dir_name ()) (module_name ^ ".tesl") in
  Out_channel.(with_open_text tesl_tmp (fun oc -> output_string oc src));
  let (_, _, code) = run_cmd ~timeout_secs:20 compiler [|"--check"; tesl_tmp|] in
  (try Sys.remove tesl_tmp with _ -> ());
  code <> 0

(** Find curl via PATH. *)
let curl_binary =
  let (out, _, code) = run_cmd ~timeout_secs:3 "which" [|"curl"|] in
  if code = 0 then String.trim out else "curl"

(** HTTP GET using curl.  Returns body string. *)
let curl_get ?(timeout_secs=10) url =
  let (out, _, _) = run_cmd ~timeout_secs curl_binary [|"-s"; "-m"; string_of_int timeout_secs; url|] in
  out

(* ── Python mock HTTP server script (the upstream the Tesl handlers call) ───── *)

let mock_server_script = {|
import sys, json
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/ping':
            self.send_json(200, {"status": "ok", "message": "pong"})
        elif self.path == '/users/42':
            self.send_json(200, {"id": 42, "name": "Alice"})
        elif self.path == '/error':
            self.send_json(500, {"error": "internal error"})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == '/echo':
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode()
            self.send_json(201, {"received": body})
        else:
            self.send_json(404, {"error": "not found"})

    def do_PUT(self):
        if self.path.startswith('/update/'):
            self.send_json(200, {"updated": True})
        else:
            self.send_json(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path.startswith('/items/'):
            self.send_json(200, {"deleted": True})
        else:
            self.send_json(404, {"error": "not found"})

server = HTTPServer(('127.0.0.1', PORT), Handler)
server.serve_forever()
|}

(** Write the mock server script to a temp file and return its path. *)
let write_mock_script () =
  let path = Filename.temp_file "tesl_mock_http" ".py" in
  Out_channel.(with_open_text path (fun oc -> output_string oc mock_server_script));
  path

(** Start the mock HTTP server subprocess.  Returns (pid, port, script_path). *)
let start_mock_server () =
  let port = pick_free_port () in
  let script = write_mock_script () in
  let devnull = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  let pid = Unix.create_process "python3"
    [|"python3"; script; string_of_int port|]
    Unix.stdin devnull devnull
  in
  Unix.close devnull;
  if not (wait_for_port "127.0.0.1" port ~timeout_secs:5) then begin
    (try Unix.kill pid Sys.sigkill with _ -> ());
    (try ignore (Unix.waitpid [] pid) with _ -> ());
    (try Sys.remove script with _ -> ());
    failwith (Printf.sprintf "Mock HTTP server failed to start on port %d" port)
  end;
  (pid, port, script)

(** Kill mock server and clean up. *)
let stop_mock_server pid script =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  (try ignore (Unix.waitpid [Unix.WNOHANG] pid) with _ -> ());
  (try Sys.remove script with _ -> ())

(* ── Tesl App server (the program under test) ───────────────────────────────── *)

(** A single Tesl App exposing one GET endpoint per HTTP method we want to
    exercise.  Each handler performs an *outbound* HttpClient call to [mock_port]
    (the Python mock) and returns either the upstream status code (as a string)
    or the upstream response body.

    Capabilities flow only via `requires [httpClient]` on each handler + the
    `main() -> App requires [httpClient]` auto-grant — no `with capabilities`,
    no script-style main. *)
let tesl_app_src ~module_name ~mock_port ~app_port =
  let url p = Printf.sprintf "http://127.0.0.1:%d%s" mock_port p in
  Printf.sprintf {|#lang tesl
module %s exposing [HttpClientTestServer]

import Tesl.Prelude exposing [Int, String, Bool(..), Unit]
import Tesl.HttpClient exposing [httpClient, HttpResponse, HttpClient.get, HttpClient.post, HttpClient.put, HttpClient.delete]
import Tesl.Int exposing [Int.toString]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.App exposing [App]

# In-memory database backs the App; the HttpClient tests do not touch it,
# but `main() -> App` requires a database in the App record.
database HttpClientTestDb = Database {
  schema: "httpclient_test"
  entities: []
  backend: Memory
}

# Each handler performs one outbound HttpClient call and returns the upstream
# status code (or body).  `requires [httpClient]` declares the capability; the
# App entry point auto-grants it at startup.

handler getStatus() -> String requires [httpClient] =
  let resp = HttpClient.get "%s" []
  Int.toString resp.status

handler getBody() -> String requires [httpClient] =
  let resp = HttpClient.get "%s" []
  resp.body

handler getUsersBody() -> String requires [httpClient] =
  let resp = HttpClient.get "%s" []
  resp.body

handler getErrorStatus() -> String requires [httpClient] =
  let resp = HttpClient.get "%s" []
  Int.toString resp.status

handler postEchoStatus() -> String requires [httpClient] =
  let resp = HttpClient.post "%s" [] "integration-test-payload"
  Int.toString resp.status

handler postEchoBody() -> String requires [httpClient] =
  let resp = HttpClient.post "%s" [] "integration-test-payload"
  resp.body

handler putStatus() -> String requires [httpClient] =
  let resp = HttpClient.put "%s" [] "payload"
  Int.toString resp.status

handler deleteStatus() -> String requires [httpClient] =
  let resp = HttpClient.delete "%s" []
  Int.toString resp.status

api HttpClientTestApi {
  get "/getStatus"     -> String
  get "/getBody"       -> String
  get "/getUsersBody"  -> String
  get "/getErrorStatus" -> String
  get "/postEchoStatus" -> String
  get "/postEchoBody"  -> String
  get "/putStatus"     -> String
  get "/deleteStatus"  -> String
}

server HttpClientTestServer for HttpClientTestApi {
  endpoint_0 = getStatus
  endpoint_1 = getBody
  endpoint_2 = getUsersBody
  endpoint_3 = getErrorStatus
  endpoint_4 = postEchoStatus
  endpoint_5 = postEchoBody
  endpoint_6 = putStatus
  endpoint_7 = deleteStatus
}

main() -> App requires [httpClient] =
  App {
    database: HttpClientTestDb
    api: HttpClientTestServer
    port: %d
  }
|}
    module_name
    (url "/ping")        (* getStatus *)
    (url "/ping")        (* getBody *)
    (url "/users/42")    (* getUsersBody *)
    (url "/error")       (* getErrorStatus *)
    (url "/echo")        (* postEchoStatus *)
    (url "/echo")        (* postEchoBody *)
    (url "/update/1")    (* putStatus *)
    (url "/items/5")     (* deleteStatus *)
    app_port

(** Start the compiled Tesl App as a racket subprocess.  Returns (pid). *)
let start_tesl_app rkt_file =
  let devnull_out = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  let err_file = Filename.temp_file "tesl_app_err" ".txt" in
  let fd_err = Unix.openfile err_file [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let pid = Unix.create_process "racket"
    [|"racket"; rkt_file|]
    Unix.stdin devnull_out fd_err
  in
  Unix.close devnull_out;
  Unix.close fd_err;
  (pid, err_file)

let stop_tesl_app pid err_file =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  (try ignore (Unix.waitpid [Unix.WNOHANG] pid) with _ -> ());
  (* Give it a moment, then SIGKILL if still alive. *)
  Unix.sleepf 0.1;
  (try Unix.kill pid Sys.sigkill with _ -> ());
  (try ignore (Unix.waitpid [] pid) with _ -> ());
  (try Sys.remove err_file with _ -> ())

(** Build the App, start the Python mock + the Tesl App server, run [f endpoint_url]
    where [endpoint_url base] yields a full URL for a given endpoint path, then
    tear everything down.  [f] receives a function that maps an endpoint name to a
    full URL on the running Tesl App. *)
let with_app_server f =
  let (mock_pid, mock_port, script) = start_mock_server () in
  Fun.protect ~finally:(fun () -> stop_mock_server mock_pid script) (fun () ->
    let app_port = pick_free_port () in
    let mn = fresh_module_name "HttpClientApp" in
    let src = tesl_app_src ~module_name:mn ~mock_port ~app_port in
    let rkt = compile_tesl_src ~module_name:mn src in
    Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
      let (app_pid, err_file) = start_tesl_app rkt in
      Fun.protect ~finally:(fun () -> stop_tesl_app app_pid err_file) (fun () ->
        if not (wait_for_port "127.0.0.1" app_port ~timeout_secs:20) then begin
          let err = try In_channel.(with_open_text err_file input_all) with _ -> "" in
          Alcotest.failf "Tesl App server failed to start on port %d; stderr: %s" app_port err
        end;
        let endpoint name = Printf.sprintf "http://127.0.0.1:%d/%s" app_port name in
        f endpoint
      )
    )
  )

(** Build source + module name for a Tesl program without requires [httpClient].
    Used to verify the capability gate.  No main is needed — the point is that
    the compiler rejects an HttpClient.get call in a fn lacking the capability. *)
let tesl_no_capability_src module_name =
  (module_name, Printf.sprintf {|#lang tesl
module %s exposing []

import Tesl.Prelude exposing [Int, String, Bool(..), Unit]
import Tesl.HttpClient exposing [httpClient, HttpResponse, HttpClient.get]
import Tesl.Int exposing [Int.toString]

fn badFetch(url: String) -> String =
  let resp = HttpClient.get url []
  Int.toString resp.status
|} module_name)

(* ── Test setup: skip if tools missing ─────────────────────────────────────── *)

let racket_available =
  let (_, _, code) = run_cmd ~timeout_secs:5 "racket" [|"--version"|] in
  code = 0

let python3_available =
  let (_, _, code) = run_cmd ~timeout_secs:5 "python3" [|"--version"|] in
  code = 0

let tools_available = racket_available && python3_available

(** Run a test only if tools are available; otherwise print a skip message. *)
let guarded_test name f () =
  if not tools_available then begin
    Printf.printf "  [SKIP] %s: racket or python3 not available\n%!" name
  end else
    f ()

(* ── Individual tests ───────────────────────────────────────────────────────── *)

(** Test 1: GET /ping (via the App's getStatus endpoint) returns status 200 *)
let test_get_status_200 () =
  with_app_server (fun endpoint ->
    let out = curl_get (endpoint "getStatus") in
    if not (contains "200" out) then
      Alcotest.failf "GET /ping: expected status 200 in response, got: %S" out
  )

(** Test 2: GET /ping body contains "pong" *)
let test_get_body_contains_pong () =
  with_app_server (fun endpoint ->
    let out = curl_get (endpoint "getBody") in
    if not (contains "pong" out) then
      Alcotest.failf "GET /ping body: expected 'pong' in response, got: %S" out
  )

(** Test 3: POST /echo returns status 201 *)
let test_post_status_201 () =
  with_app_server (fun endpoint ->
    let out = curl_get (endpoint "postEchoStatus") in
    if not (contains "201" out) then
      Alcotest.failf "POST /echo: expected status 201 in response, got: %S" out
  )

(** Test 4: PUT /update/1 returns status 200 *)
let test_put_status_200 () =
  with_app_server (fun endpoint ->
    let out = curl_get (endpoint "putStatus") in
    if not (contains "200" out) then
      Alcotest.failf "PUT /update/1: expected status 200 in response, got: %S" out
  )

(** Test 5: DELETE /items/5 returns status 200 *)
let test_delete_status_200 () =
  with_app_server (fun endpoint ->
    let out = curl_get (endpoint "deleteStatus") in
    if not (contains "200" out) then
      Alcotest.failf "DELETE /items/5: expected status 200 in response, got: %S" out
  )

(** Test 6: GET /error returns status 500 *)
let test_server_error_returns_500 () =
  with_app_server (fun endpoint ->
    let out = curl_get (endpoint "getErrorStatus") in
    if not (contains "500" out) then
      Alcotest.failf "GET /error: expected status 500 in response, got: %S" out
  )

(** Test 7: GET /users/42 body contains "Alice" *)
let test_get_users_body_contains_alice () =
  with_app_server (fun endpoint ->
    let out = curl_get (endpoint "getUsersBody") in
    if not (contains "Alice" out) then
      Alcotest.failf "GET /users/42 body: expected 'Alice' in response, got: %S" out
  )

(** Test 8: Capability gate — missing requires [httpClient] causes compile error *)
let test_capability_gate_compile_error () =
  let mn = fresh_module_name "TeslHttpNoCap" in
  let (module_name, src) = tesl_no_capability_src mn in
  if not (compile_tesl_check_fails ~module_name src) then
    Alcotest.failf "Expected --check to fail for HttpClient.get without requires [httpClient]"

(** Test 9: the App server endpoint responds successfully (a non-empty status). *)
let test_get_endpoint_responds () =
  with_app_server (fun endpoint ->
    let out = curl_get (endpoint "getStatus") in
    if String.length (String.trim out) = 0 then
      Alcotest.failf "GET endpoint: expected a non-empty response from the Tesl App"
  )

(** Test 10: POST body is sent: mock echoes it back in the response body. *)
let test_post_body_echoed () =
  with_app_server (fun endpoint ->
    let out = curl_get (endpoint "postEchoBody") in
    if not (contains "integration-test-payload" out) then
      Alcotest.failf "POST echo body: expected the payload echoed back, got: %S" out
  )

(* ── Main ───────────────────────────────────────────────────────────────────── *)

let () =
  Random.self_init ();
  Alcotest.run "HttpClient-Integration" [
    "get", [
      Alcotest.test_case "GET /ping returns status 200"     `Slow
        (guarded_test "get-status-200"     test_get_status_200);
      Alcotest.test_case "GET /ping body contains pong"     `Slow
        (guarded_test "get-body-pong"      test_get_body_contains_pong);
      Alcotest.test_case "GET /users/42 body contains Alice" `Slow
        (guarded_test "get-users-alice"    test_get_users_body_contains_alice);
      Alcotest.test_case "GET /error returns status 500"    `Slow
        (guarded_test "get-error-500"      test_server_error_returns_500);
      Alcotest.test_case "GET endpoint responds over HTTP"  `Slow
        (guarded_test "get-responds"       test_get_endpoint_responds);
    ];
    "post-put-delete", [
      Alcotest.test_case "POST /echo returns status 201"    `Slow
        (guarded_test "post-201"           test_post_status_201);
      Alcotest.test_case "POST body echoed back by server"  `Slow
        (guarded_test "post-echo"          test_post_body_echoed);
      Alcotest.test_case "PUT /update/1 returns status 200" `Slow
        (guarded_test "put-200"            test_put_status_200);
      Alcotest.test_case "DELETE /items/5 returns status 200" `Slow
        (guarded_test "delete-200"         test_delete_status_200);
    ];
    "capability", [
      Alcotest.test_case "Missing requires [httpClient] causes compile error" `Quick
        (guarded_test "no-cap-error"       test_capability_gate_compile_error);
    ];
  ]
