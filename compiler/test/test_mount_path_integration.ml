(** test_mount_path_integration.ml — Runtime integration tests for issue #75's
    `App { … mountPath: "/prefix" }`.

    `mountPath` scopes exactly the DECLARED api surface (the `api` block's routes
    and its SSE routes).  Everything the runtime owns keeps answering on the RAW
    path: static files and the SPA fallback, the health probe, and the SSO
    endpoints.  The first cut of this feature applied the prefix at one choke
    point in front of *everything*, which 404'd the SPA, the health probe and the
    SSO callback — a fully green 20-phase CI missed all three because mountPath
    was only ever tested against a bare app.  So every combination below is a
    regression test for a break that actually shipped in a working tree.

    Skips gracefully if racket is unavailable. *)

(* ── Harness ────────────────────────────────────────────────────────────────── *)

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

let run_cmd ?(timeout_secs=30) cmd args =
  let tmp_out = Filename.temp_file "tesl_mp_out" ".txt" in
  let tmp_err = Filename.temp_file "tesl_mp_err" ".txt" in
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

let wait_for_port host port ~timeout_secs =
  let deadline = Unix.gettimeofday () +. float_of_int timeout_secs in
  let rec try_connect () =
    if Unix.gettimeofday () > deadline then false
    else
      let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      let addr = Unix.ADDR_INET (Unix.inet_addr_of_string host, port) in
      (try Unix.connect sock addr; Unix.close sock; true
       with _ -> Unix.close sock; Unix.sleepf 0.1; try_connect ())
  in
  try_connect ()

let find_compiler () =
  let exe_dir = Filename.dirname Sys.executable_name in
  let candidate = Filename.concat (Filename.dirname exe_dir) "bin/main.exe" in
  if Sys.file_exists candidate then candidate
  else
    let alt = Filename.concat exe_dir "../bin/main.exe" in
    if Sys.file_exists alt then alt
    else "/home/mikael/repos_wsl/tesl-github/tesl/compiler/_build/default/bin/main.exe"

let fresh_module_name prefix =
  Printf.sprintf "%s%d" prefix (Random.int 9_000_000 + 1_000_000)

let compile_tesl_src ~module_name src =
  let compiler = find_compiler () in
  let tesl_tmp = Filename.concat (Filename.get_temp_dir_name ()) (module_name ^ ".tesl") in
  let rkt_tmp  = Filename.concat (Filename.get_temp_dir_name ()) (module_name ^ ".rkt")  in
  Out_channel.(with_open_text tesl_tmp (fun oc -> output_string oc src));
  let (_, check_err, check_code) = run_cmd ~timeout_secs:20 compiler [|"--check"; tesl_tmp|] in
  if check_code <> 0 then begin
    (try Sys.remove tesl_tmp with _ -> ());
    failwith ("Tesl --check failed: " ^ check_err)
  end;
  let (out, err, code) = run_cmd ~timeout_secs:20 compiler [|tesl_tmp|] in
  (try Sys.remove tesl_tmp with _ -> ());
  if code <> 0 then failwith ("Tesl compile failed: " ^ err)
  else begin
    Out_channel.(with_open_text rkt_tmp (fun oc -> output_string oc out));
    rkt_tmp
  end

let start_tesl_app rkt_file =
  let devnull_out = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  let err_file = Filename.temp_file "tesl_mp_app_err" ".txt" in
  let fd_err = Unix.openfile err_file [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let pid = Unix.create_process "racket" [|"racket"; rkt_file|] Unix.stdin devnull_out fd_err in
  Unix.close devnull_out;
  Unix.close fd_err;
  (pid, err_file)

let stop_tesl_app pid err_file =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  (try ignore (Unix.waitpid [Unix.WNOHANG] pid) with _ -> ());
  Unix.sleepf 0.1;
  (try Unix.kill pid Sys.sigkill with _ -> ());
  (try ignore (Unix.waitpid [] pid) with _ -> ());
  (try Sys.remove err_file with _ -> ())

let curl_binary =
  let (out, _, code) = run_cmd ~timeout_secs:3 "which" [|"curl"|] in
  if code = 0 then String.trim out else "curl"

(** GET a URL, returning (http_status, body).  [host] overrides the Host header. *)
let curl_status ?(timeout_secs=10) ?host url =
  let base = [|"-s"; "-m"; string_of_int timeout_secs; "-w"; "\n%{http_code}"|] in
  let hdr = match host with Some h -> [|"-H"; "Host: " ^ h|] | None -> [||] in
  let (out, _, _) = run_cmd ~timeout_secs curl_binary
      (Array.concat [base; hdr; [|url|]]) in
  match String.rindex_opt out '\n' with
  | Some i ->
    let body = String.sub out 0 i in
    let status_str = String.sub out (i + 1) (String.length out - i - 1) in
    let status = try int_of_string (String.trim status_str) with _ -> 0 in
    (status, body)
  | None -> (0, out)

let contains hay needle =
  let n = String.length hay and m = String.length needle in
  let found = ref false in
  for i = 0 to n - m do if String.sub hay i m = needle then found := true done;
  !found

let racket_available =
  let (_, _, code) = run_cmd ~timeout_secs:3 "which" [|"racket"|] in
  code = 0

let guarded_test name f () =
  if not racket_available then Printf.printf "skipping %s: racket not on PATH\n%!" name
  else f ()

(** Compile [src_of port], run it, and hand [f url] a URL builder. *)
let with_app ~prefix ~src_of f =
  let port = pick_free_port () in
  let mn = fresh_module_name prefix in
  let rkt = compile_tesl_src ~module_name:mn (src_of ~module_name:mn ~port) in
  Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
    let (app_pid, err_file) = start_tesl_app rkt in
    Fun.protect ~finally:(fun () -> stop_tesl_app app_pid err_file) (fun () ->
      if not (wait_for_port "127.0.0.1" port ~timeout_secs:20) then begin
        let err = try In_channel.(with_open_text err_file input_all) with _ -> "" in
        Alcotest.failf "app failed to start on port %d; stderr: %s" port err
      end;
      f (fun path -> Printf.sprintf "http://127.0.0.1:%d%s" port path) port))

(* ── Fixture 1: bare mounted app (no static, no sso, no health probe) ───────── *)

let bare_src ~module_name ~port =
  Printf.sprintf {|module %s exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

database MpDb = Database {
  entities: []
  backend: Memory
}

handler get ping() -> String requires [] =
  "pong"

api MpApi {
  get "/ping" -> String
}

server MpServer for MpApi {
  ping
}

main() -> App requires [] =
  App {
    database: MpDb
    api: MpServer
    port: %d
    mountPath: "/api"
  }
|} module_name port

let with_bare f = with_app ~prefix:"MountBare" ~src_of:bare_src f

let test_mounted_path_reaches_the_route () =
  with_bare (fun url _ ->
    let (status, body) = curl_status (url "/api/ping") in
    Alcotest.(check int) "mounted path answers 200" 200 status;
    if not (contains body "pong") then
      Alcotest.failf "expected the handler's body, got: %s" body)

let test_unmounted_path_is_404 () =
  with_bare (fun url _ ->
    let (status, _) = curl_status (url "/ping") in
    Alcotest.(check int) "the route's unmounted path must not answer" 404 status)

let test_mount_root_alone_is_404 () =
  with_bare (fun url _ ->
    let (status, _) = curl_status (url "/api") in
    Alcotest.(check int) "the mount root with no route segment 404s" 404 status)

(* ── Fixture 2: mountPath + static (the single-binary SPA + API deployment) ───
   The first cut 404'd every one of these: the mount guard ran in front of
   static-file serving, making `mountPath` and `static` mutually exclusive —
   which defeats issue #75's own motivating scenario (an API sharing one origin
   with a SPA).  `example/kanel` and `example/chat` are both this shape. *)

let static_dir = ref ""

let static_src ~module_name ~port =
  Printf.sprintf {|module %s exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

database MpDb = Database {
  entities: []
  backend: Memory
}

handler get ping() -> String requires [] =
  "pong"

api MpApi {
  get "/ping" -> String
}

server MpServer for MpApi {
  ping
}

main() -> App requires [] =
  App {
    database: MpDb
    api: MpServer
    port: %d
    static: "%s"
    mountPath: "/api"
  }
|} module_name port !static_dir

let with_static f =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "tesl-mp-static-%d" (Random.int 9_000_000)) in
  (try Unix.mkdir dir 0o755 with _ -> ());
  let index = Filename.concat dir "index.html" in
  Out_channel.(with_open_text index (fun oc -> output_string oc "<html>SPA-INDEX</html>"));
  static_dir := dir;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove index with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> with_app ~prefix:"MountStatic" ~src_of:static_src f)

let test_static_spa_index_served_at_root () =
  with_static (fun url _ ->
    let (status, body) = curl_status (url "/") in
    Alcotest.(check int) "SPA index at / is served" 200 status;
    if not (contains body "SPA-INDEX") then
      Alcotest.failf "expected the SPA index, got: %s" body)

let test_static_file_served_unmounted () =
  with_static (fun url _ ->
    let (status, _) = curl_status (url "/index.html") in
    Alcotest.(check int) "a static file is served on its raw path" 200 status)

let test_spa_fallback_still_works () =
  with_static (fun url _ ->
    let (status, body) = curl_status (url "/some/client/route") in
    Alcotest.(check int) "an unrouted path falls back to the SPA shell" 200 status;
    if not (contains body "SPA-INDEX") then
      Alcotest.failf "expected the SPA shell, got: %s" body)

let test_api_still_mounted_alongside_static () =
  with_static (fun url _ ->
    let (status, body) = curl_status (url "/api/ping") in
    Alcotest.(check int) "the API is still reachable under the mount" 200 status;
    if not (contains body "pong") then
      Alcotest.failf "expected the handler's body, got: %s" body)

let test_unmounted_api_path_serves_spa_not_the_handler () =
  (* The subtle one: with a SPA present the unmounted API path returns 200,
     but it must be the SPA shell — NOT the handler answering outside its
     mount.  A route answering at both its mounted and unmounted path would
     defeat the point of declaring a mount, and a bare status assertion here
     would pass while that bug was live. *)
  with_static (fun url _ ->
    let (status, body) = curl_status (url "/ping") in
    Alcotest.(check int) "unmounted API path is absorbed by the SPA fallback" 200 status;
    if contains body "pong" then
      Alcotest.failf "the handler answered OUTSIDE its mount — got: %s" body;
    if not (contains body "SPA-INDEX") then
      Alcotest.failf "expected the SPA shell, got: %s" body)

(* ── Fixture 3: mountPath + publicOrigin + healthProbePath ───────────────────
   `healthProbePath` names one of the api block's own routes, so it is
   api-relative and moves under the mount with everything else — a load
   balancer probes the MOUNTED path.  What must survive is the Host-validation
   exemption (LBs probe host-blind), which is security-relevant: the first cut
   404'd the probe outright. *)

let health_src ~module_name ~port =
  Printf.sprintf {|module %s exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

database MpDb = Database {
  entities: []
  backend: Memory
}

handler get ping() -> String requires [] =
  "pong"

handler get healthz() -> String requires [] =
  "ok"

api MpApi {
  get "/ping" -> String
  get "/healthz" -> String
}

server MpServer for MpApi {
  ping
  healthz
  publicOrigin "http://127.0.0.1:%d"
  healthProbePath "/healthz"
}

main() -> App requires [] =
  App {
    database: MpDb
    api: MpServer
    port: %d
    mountPath: "/api"
  }
|} module_name port port

let with_health f = with_app ~prefix:"MountHealth" ~src_of:health_src f

let test_health_probe_reachable_under_mount () =
  with_health (fun url port ->
    let host = Printf.sprintf "127.0.0.1:%d" port in
    let (status, _) = curl_status ~host (url "/api/healthz") in
    Alcotest.(check int) "the health probe answers on its mounted path" 200 status)

let test_health_probe_exempt_from_host_validation () =
  with_health (fun url _ ->
    let (status, _) = curl_status ~host:"evil.example.com" (url "/api/healthz") in
    Alcotest.(check int)
      "a host-blind LB probe is still exempt from Host validation" 200 status)

let test_host_validation_still_enforced_on_api_routes () =
  (* The exemption must stay a single hole, not a blanket bypass. *)
  with_health (fun url _ ->
    let (status, _) = curl_status ~host:"evil.example.com" (url "/api/ping") in
    Alcotest.(check int) "an ordinary route still refuses a mismatched Host" 421 status)

(* ── Fixture 4: mountPath + SSO ──────────────────────────────────────────────
   SSO endpoints are runtime-owned and deliberately NOT mounted, so
   `redirect_uri` (publicOrigin ++ "/auth/<seg>/callback") stays exactly what is
   registered at the identity provider.  Coupling an externally-registered OAuth
   callback to a deployment knob would mean changing `mountPath` silently
   invalidates the IdP registration.  `publicOrigin` cannot carry a path
   (`valid_public_origin`), so a prefixed callback is not even expressible.

   These assert the ROUTING decision without needing a live IdP: the SSO
   endpoints must be reachable on the raw path (any status but 404 means the SSO
   handler ran — discovery against a bogus issuer then fails, which is fine),
   and must NOT exist under the mount. *)

let sso_src ~module_name ~port =
  Printf.sprintf {|module %s exposing []
import Tesl.Prelude exposing [String]
import Tesl.Sso exposing [SsoConnection, SsoIdentity, Sso.oidc, Sso.subject]
import Tesl.Env exposing [envRead, requireEnv, requireSecret]
import Tesl.HttpClient exposing [httpClient]
import Tesl.Time exposing [time]
import Tesl.JWT exposing [jwt]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

database MpDb = Database {
  entities: []
  backend: Memory
}

fn idpConn() -> SsoConnection requires [envRead, httpClient] =
  Sso.oidc (requireEnv "MP_ISSUER") (requireEnv "MP_CLIENT_ID") (requireSecret "MP_CLIENT_SECRET")

fn linkUser(identity: SsoIdentity) -> String =
  Sso.subject identity

handler get ping() -> String requires [] =
  "pong"

api MpApi {
  get "/ping" -> String
}

server MpServer for MpApi {
  ping
  sso "idp" connection idpConn onIdentity linkUser
  publicOrigin "http://127.0.0.1:%d"
  sessionKey "MP_SESSION_KEY"
}

main() -> App requires [envRead, httpClient, jwt, time] =
  App {
    database: MpDb
    api: MpServer
    port: %d
    mountPath: "/api"
  }
|} module_name port port

let with_sso f = with_app ~prefix:"MountSso" ~src_of:sso_src f

let test_sso_login_reachable_on_raw_path () =
  with_sso (fun url port ->
    let host = Printf.sprintf "127.0.0.1:%d" port in
    let (status, _) = curl_status ~host (url "/auth/idp/login") in
    if status = 404 then
      Alcotest.failf
        "SSO login must stay reachable at its unmounted /auth/<seg>/login \
         (got 404 — the mount swallowed it, which would break the IdP-registered \
         redirect_uri)";
    Alcotest.(check bool) "SSO login route was matched and handled" true (status <> 404))

let test_sso_callback_reachable_on_raw_path () =
  (* The callback is the half that must match `redirect_uri` exactly. *)
  with_sso (fun url port ->
    let host = Printf.sprintf "127.0.0.1:%d" port in
    let (status, _) = curl_status ~host (url "/auth/idp/callback") in
    if status = 404 then
      Alcotest.failf
        "SSO callback must stay reachable at its unmounted /auth/<seg>/callback \
         — this is the URL handed to the IdP as redirect_uri (got 404)";
    Alcotest.(check bool) "SSO callback route was matched and handled" true (status <> 404))

let test_sso_is_not_mounted () =
  with_sso (fun url port ->
    let host = Printf.sprintf "127.0.0.1:%d" port in
    let (status, _) = curl_status ~host (url "/api/auth/idp/login") in
    Alcotest.(check int) "SSO endpoints do not also appear under the mount" 404 status)

let test_api_still_mounted_alongside_sso () =
  with_sso (fun url port ->
    let host = Printf.sprintf "127.0.0.1:%d" port in
    let (status, body) = curl_status ~host (url "/api/ping") in
    Alcotest.(check int) "the API is still mounted with an sso clause present" 200 status;
    if not (contains body "pong") then
      Alcotest.failf "expected the handler's body, got: %s" body)

let () =
  Alcotest.run "mount-path integration (#75)" [
    "bare mounted app", [
      Alcotest.test_case "mounted path reaches the route" `Quick
        (guarded_test "mounted" test_mounted_path_reaches_the_route);
      Alcotest.test_case "unmounted path is 404" `Quick
        (guarded_test "unmounted" test_unmounted_path_is_404);
      Alcotest.test_case "mount root alone is 404" `Quick
        (guarded_test "mount root" test_mount_root_alone_is_404);
    ];
    "mountPath + static (SPA at the same origin)", [
      Alcotest.test_case "SPA index served at /" `Quick
        (guarded_test "spa index" test_static_spa_index_served_at_root);
      Alcotest.test_case "static file served on its raw path" `Quick
        (guarded_test "static file" test_static_file_served_unmounted);
      Alcotest.test_case "SPA fallback still works" `Quick
        (guarded_test "spa fallback" test_spa_fallback_still_works);
      Alcotest.test_case "API still mounted alongside static" `Quick
        (guarded_test "api+static" test_api_still_mounted_alongside_static);
      Alcotest.test_case "unmounted API path serves the SPA, not the handler" `Quick
        (guarded_test "no double answer" test_unmounted_api_path_serves_spa_not_the_handler);
    ];
    "mountPath + healthProbePath (Host validation)", [
      Alcotest.test_case "health probe reachable under the mount" `Quick
        (guarded_test "health reachable" test_health_probe_reachable_under_mount);
      Alcotest.test_case "health probe exempt from Host validation" `Quick
        (guarded_test "health exempt" test_health_probe_exempt_from_host_validation);
      Alcotest.test_case "ordinary routes still enforce Host" `Quick
        (guarded_test "host enforced" test_host_validation_still_enforced_on_api_routes);
    ];
    "mountPath + SSO (redirect_uri integrity)", [
      Alcotest.test_case "SSO login reachable on the raw path" `Quick
        (guarded_test "sso login" test_sso_login_reachable_on_raw_path);
      Alcotest.test_case "SSO callback reachable on the raw path" `Quick
        (guarded_test "sso callback" test_sso_callback_reachable_on_raw_path);
      Alcotest.test_case "SSO endpoints are not mounted" `Quick
        (guarded_test "sso unmounted" test_sso_is_not_mounted);
      Alcotest.test_case "API still mounted alongside SSO" `Quick
        (guarded_test "api+sso" test_api_still_mounted_alongside_sso);
    ];
  ]
