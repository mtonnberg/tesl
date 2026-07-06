(** test_email_integration.ml — Runtime integration tests for the Email module.

    These tests verify the runtime behaviour of the Email module under the modern
    Tesl language, which has no script-style `main() -> Unit` and no
    `with capabilities [...]` blocks.  Capabilities flow only from a declaration's
    `requires` plus the `main() -> App` entry point's auto-grant: the App desugar
    wraps server startup in the capability + database scope derived from
    `main.requires`.

    What is verified:

    - The email module loads at runtime without unbound-identifier errors, by
      starting a real Tesl App that declares an `email` block and serving it.
    - Email.send runs inside the App's auto-granted `[emailCap]` scope (no
      `with capabilities`) — exercised by hitting an App endpoint whose handler
      calls Email.send (TextBody / HtmlBody / RichBody variants).
    - The email capability gate is enforced at compile time (a fn calling
      Email.send without `requires [emailCap]` is rejected by --check).
    - Direct SMTP delivery to a live MailHog SMTP server works, and MailHog
      records the correct subject and recipient.

    MailHog binary is discovered via the MAILHOG env var, PATH, then nix store.
    Tests skip gracefully when racket or MailHog are not available.

    NOTE on Email.send → MailHog under the App model: Email.send is non-blocking
    (it queues to the outbox / in-memory store); a background worker delivers via
    SMTP.  The App tests assert that Email.send *runs* (the endpoint returns its
    marker); end-to-end SMTP→MailHog delivery is verified separately via the
    direct-SMTP MailHog tests below, which drive net/smtp exactly as the runtime
    delivery path does.
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
  let tmp_out = Filename.temp_file "tesl_email_int_out" ".txt" in
  let tmp_err = Filename.temp_file "tesl_email_int_err" ".txt" in
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

let find_compiler () =
  let exe_dir = Filename.dirname Sys.executable_name in
  let candidate = Filename.concat (Filename.dirname exe_dir) "bin/main.exe" in
  if Sys.file_exists candidate then candidate
  else "/home/mikael/repos_wsl/tesl-github/tesl/compiler/_build/default/bin/main.exe"

(** Find MailHog binary: MAILHOG env var, then PATH, then known nix store paths. *)
let mailhog_binary =
  match Sys.getenv_opt "MAILHOG" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    let (out, _, code) = run_cmd ~timeout_secs:3 "which" [|"MailHog"|] in
    if code = 0 then String.trim out
    else
      (* Fallback: scan common nix store prefixes *)
      let candidates = [
        "/run/current-system/sw/bin/MailHog";
        "/home/mikael/.nix-profile/bin/MailHog";
      ] in
      match List.find_opt Sys.file_exists candidates with
      | Some p -> p
      | None ->
        (* Last resort: glob the nix store *)
        let (out2, _, _) = run_cmd ~timeout_secs:3 "sh"
          [|"-c"; "ls /nix/store/*/bin/MailHog 2>/dev/null | head -1"|] in
        String.trim out2

(** Find curl binary via PATH. *)
let curl_binary =
  let (out, _, code) = run_cmd ~timeout_secs:3 "which" [|"curl"|] in
  if code = 0 then String.trim out else "curl"

(** Generate a unique PascalCase module name. *)
let fresh_module_name prefix =
  Printf.sprintf "%s%d" prefix (Random.int 9_000_000 + 1_000_000)

(** Compile a Tesl source string to a .rkt file.
    [module_name] must match the module header in [src]. *)
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

let run_racket rkt_file =
  run_cmd ~timeout_secs:25 "racket" [|rkt_file|]

let curl_get ?(timeout_secs=10) url =
  let (out, _, _) = run_cmd ~timeout_secs curl_binary [|"-s"; "-m"; string_of_int timeout_secs; url|] in
  out

(* ── Tooling availability ───────────────────────────────────────────────────── *)

let racket_available =
  let (_, _, code) = run_cmd ~timeout_secs:5 "racket" [|"--version"|] in
  code = 0

let mailhog_available =
  Sys.file_exists mailhog_binary

let tools_available = racket_available

let guarded_test name f () =
  if not tools_available then begin
    Printf.printf "  [SKIP] %s: racket not available\n%!" name
  end else
    f ()

let guarded_mailhog_test name f () =
  if not tools_available then
    Printf.printf "  [SKIP] %s: racket not available\n%!" name
  else if not mailhog_available then
    Printf.printf "  [SKIP] %s: MailHog binary not found\n%!" name
  else
    f ()

(* ── Tesl email App templates ────────────────────────────────────────────────── *)

(** Common module header + database + email block, shared by the App tests.

    An in-memory database backs the email outbox so the tests need no Postgres.
    The email block points at [smtp_port] (used only by the background delivery
    worker; the App tests assert that Email.send *runs*, not delivery).  *)
let app_prelude ~module_name smtp_port = Printf.sprintf {|#lang tesl
module %s exposing [EmailTestServer]

import Tesl.Prelude exposing [String, Unit, Bool(..)]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.Email exposing [Email, SmtpConfig]
import Tesl.App exposing [App]

# In-memory database backs the email outbox — no Postgres required.
database EmailTestDb = Database {
  schema: "email_test"
  entities: []
  backend: Memory
}

email EmailTestMail = Email {
  database: EmailTestDb
  smtp: SmtpConfig {
    host: "127.0.0.1"
    port: %d
    username: ""
    password: ""
    tls: false
  }
}|} module_name smtp_port

(** Trailing api/server/main for the App tests.  [endpoints] is a list of
    (endpoint-name, path) and the api lists one `get` route per endpoint. *)
let app_tail ~endpoints app_port =
  let api_routes =
    String.concat "\n"
      (List.map (fun (_, path) -> Printf.sprintf "  get \"%s\" -> String" path) endpoints) in
  let server_bindings =
    String.concat "\n"
      (List.mapi (fun i (name, _) -> Printf.sprintf "  endpoint_%d = %s" i name) endpoints) in
  Printf.sprintf {|
api EmailTestApi {
%s
}

server EmailTestServer for EmailTestApi {
%s
}

main() -> App requires [emailCap] =
  App {
    database: EmailTestDb
    email: [EmailTestMail]
    api: EmailTestServer
    port: %d
  }
|} api_routes server_bindings app_port

(** App that simply loads the email module and serves a health endpoint — proves
    the email block loads at runtime with no unbound-identifier errors. *)
let tesl_email_load_app ~module_name smtp_port app_port =
  Printf.sprintf {|%s

handler emailLoaded() -> String requires [] =
  "EMAIL-MODULE-LOADED"
%s|}
    (app_prelude ~module_name smtp_port)
    (app_tail ~endpoints:[("emailLoaded", "/loaded")] app_port)

(** App whose endpoint sends a TextBody email via Email.send (auto-granted
    [emailCap] capability) and returns a marker. *)
let tesl_email_send_app ~module_name smtp_port app_port recipient =
  Printf.sprintf {|%s

handler queueEmail() -> String requires [emailCap] =
  let _ = Email.send EmailTestMail {
    to: "%s"
    subject: "Integration Test Subject"
    body: TextBody "Hello from Tesl integration test"
  }
  "EMAIL-QUEUED"
%s|}
    (app_prelude ~module_name smtp_port)
    recipient
    (app_tail ~endpoints:[("queueEmail", "/send")] app_port)

(** App whose endpoint sends an HtmlBody email. *)
let tesl_email_html_app ~module_name smtp_port app_port =
  Printf.sprintf {|%s

handler sendHtml() -> String requires [emailCap] =
  let _ = Email.send EmailTestMail {
    to: "html@example.com"
    subject: "HTML Email Test"
    body: HtmlBody "<h1>Hello</h1><p>HTML email test</p>"
  }
  "HTML-EMAIL-QUEUED"
%s|}
    (app_prelude ~module_name smtp_port)
    (app_tail ~endpoints:[("sendHtml", "/html")] app_port)

(** App whose endpoint sends a RichBody email. *)
let tesl_email_rich_app ~module_name smtp_port app_port =
  Printf.sprintf {|%s

handler sendRich() -> String requires [emailCap] =
  let _ = Email.send EmailTestMail {
    to: "rich@example.com"
    subject: "Rich Email Test"
    body: RichBody "Plain text fallback" "<h1>HTML version</h1>"
  }
  "RICH-EMAIL-QUEUED"
%s|}
    (app_prelude ~module_name smtp_port)
    (app_tail ~endpoints:[("sendRich", "/rich")] app_port)

(** Build module name + source for a Tesl program where a fn calls Email.send
    WITHOUT `requires [emailCap]`.  No main is needed — the point is that the
    compiler rejects the missing-capability call. *)
let tesl_email_no_cap_src module_name =
  (module_name, Printf.sprintf {|#lang tesl
module %s exposing []

import Tesl.Prelude exposing [String, Unit, Bool(..)]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.Email exposing [Email, SmtpConfig]

database EmailTestDb = Database {
  schema: "email_test"
  entities: []
  backend: Memory
}

email EmailTestMail = Email {
  database: EmailTestDb
  smtp: SmtpConfig {
    host: "127.0.0.1"
    port: 2525
    username: ""
    password: ""
    tls: false
  }
}

fn badSend(addr: String) -> Unit =
  Email.send EmailTestMail {
    to: addr
    subject: "No cap"
    body: TextBody "This should fail capability check"
  }
|} module_name)

(* ── Tesl App server runner ─────────────────────────────────────────────────── *)

(** Start the compiled Tesl App as a racket subprocess.  Returns (pid, err_file). *)
let start_tesl_app rkt_file =
  let devnull_out = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  let err_file = Filename.temp_file "tesl_email_app_err" ".txt" in
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
  Unix.sleepf 0.1;
  (try Unix.kill pid Sys.sigkill with _ -> ());
  (try ignore (Unix.waitpid [] pid) with _ -> ());
  (try Sys.remove err_file with _ -> ())

(** Compile [src] (an App returning [app_port]), start the server, run
    [f endpoint_url], then tear down.  [endpoint_url] maps an endpoint path
    (e.g. "/send") to a full URL on the running App. *)
let with_email_app ~module_name ~app_port src f =
  let rkt = compile_tesl_src ~module_name src in
  Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
    let (app_pid, err_file) = start_tesl_app rkt in
    Fun.protect ~finally:(fun () -> stop_tesl_app app_pid err_file) (fun () ->
      if not (wait_for_port "127.0.0.1" app_port ~timeout_secs:20) then begin
        let err = try In_channel.(with_open_text err_file input_all) with _ -> "" in
        Alcotest.failf "Tesl email App failed to start on port %d; stderr: %s" app_port err
      end;
      let endpoint_url path = Printf.sprintf "http://127.0.0.1:%d%s" app_port path in
      f endpoint_url
    )
  )

(* ── MailHog helpers ─────────────────────────────────────────────────────────── *)

(** Start MailHog.  Returns (pid, smtp_port, api_port, ui_port). *)
let start_mailhog () =
  let smtp_port = pick_free_port () in
  let api_port  = pick_free_port () in
  let ui_port   = pick_free_port () in
  let devnull = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  let pid = Unix.create_process mailhog_binary
    [| mailhog_binary
     ; "-smtp-bind-addr"; Printf.sprintf "127.0.0.1:%d" smtp_port
     ; "-api-bind-addr";  Printf.sprintf "127.0.0.1:%d" api_port
     ; "-ui-bind-addr";   Printf.sprintf "127.0.0.1:%d" ui_port
    |]
    Unix.stdin devnull devnull
  in
  Unix.close devnull;
  (* Wait for API port to come up *)
  if not (wait_for_port "127.0.0.1" api_port ~timeout_secs:5) then begin
    (try Unix.kill pid Sys.sigkill with _ -> ());
    (try ignore (Unix.waitpid [] pid) with _ -> ());
    failwith (Printf.sprintf "MailHog failed to start (smtp=%d api=%d)" smtp_port api_port)
  end;
  (pid, smtp_port, api_port, ui_port)

let stop_mailhog pid =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  (try ignore (Unix.waitpid [Unix.WNOHANG] pid) with _ -> ())

(** Query MailHog message count via its API. *)
let mailhog_message_count api_port =
  let url = Printf.sprintf "http://127.0.0.1:%d/api/v2/messages" api_port in
  let json = curl_get url in
  (* Extract "total" field: {"total":N,...} *)
  try
    let start = String.index json ':' + 1 in
    let stop = String.index_from json start ',' in
    int_of_string (String.trim (String.sub json start (stop - start)))
  with _ -> -1

(** Write a Racket script that sends an email via net/smtp directly, exactly as
    the Tesl runtime email-delivery worker does (header string + (list body)).
    Returns path to the script. *)
let write_direct_smtp_rkt smtp_port recipient subject body_text =
  let path = Filename.temp_file "tesl_email_smtp" ".rkt" in
  let src = Printf.sprintf {|#lang racket
(require net/smtp)

(define SMTP-PORT %d)

(with-handlers ([exn:fail?
                 (lambda (e)
                   (displayln (format "SMTP-ERROR: ~~a" (exn-message e))))])
  (smtp-send-message
   "127.0.0.1"
   "noreply@tesl-test.local"
   '(%S)
   (string-append
    "From: noreply@tesl-test.local\r\n"
    "To: " %S "\r\n"
    "Subject: " %S "\r\n"
    "Content-Type: text/plain; charset=utf-8\r\n")
   (list %S)
   #:port-no SMTP-PORT
   #:auth-user "noreply@tesl-test.local"
   #:auth-passwd ""
   #:tls-encode #f)
  (displayln "SMTP-SENT"))
|} smtp_port recipient recipient subject body_text
  in
  Out_channel.(with_open_text path (fun oc -> output_string oc src));
  path

(* ── Tests ───────────────────────────────────────────────────────────────────── *)

(** Test 1: Email module loads at runtime — a Tesl App declaring an email block
    starts and serves without unbound-identifier errors. *)
let test_email_module_loads () =
  let mn = fresh_module_name "TeslEmailLoad" in
  let app_port = pick_free_port () in
  let smtp_port = pick_free_port () in
  let src = tesl_email_load_app ~module_name:mn smtp_port app_port in
  with_email_app ~module_name:mn ~app_port src (fun endpoint_url ->
    let out = curl_get (endpoint_url "/loaded") in
    if not (contains "EMAIL-MODULE-LOADED" out) then
      Alcotest.failf "Email module load: expected 'EMAIL-MODULE-LOADED' in response, got: %S" out
  )

(** Test 2: Email.send runs inside the App's auto-granted [emailCap] scope. *)
let test_email_send_queues () =
  let mn = fresh_module_name "TeslEmailSend" in
  let app_port = pick_free_port () in
  let smtp_port = pick_free_port () in
  let src = tesl_email_send_app ~module_name:mn smtp_port app_port "recipient@example.com" in
  with_email_app ~module_name:mn ~app_port src (fun endpoint_url ->
    let out = curl_get (endpoint_url "/send") in
    if not (contains "EMAIL-QUEUED" out) then
      Alcotest.failf "Email.send queue: expected 'EMAIL-QUEUED' in response, got: %S" out
  )

(** Test 3: HtmlBody variant compiles and runs (Email.send via App endpoint). *)
let test_email_html_body () =
  let mn = fresh_module_name "TeslEmailHtml" in
  let app_port = pick_free_port () in
  let smtp_port = pick_free_port () in
  let src = tesl_email_html_app ~module_name:mn smtp_port app_port in
  with_email_app ~module_name:mn ~app_port src (fun endpoint_url ->
    let out = curl_get (endpoint_url "/html") in
    if not (contains "HTML-EMAIL-QUEUED" out) then
      Alcotest.failf "HtmlBody: expected 'HTML-EMAIL-QUEUED' in response, got: %S" out
  )

(** Test 4: RichBody variant compiles and runs (Email.send via App endpoint). *)
let test_email_rich_body () =
  let mn = fresh_module_name "TeslEmailRich" in
  let app_port = pick_free_port () in
  let smtp_port = pick_free_port () in
  let src = tesl_email_rich_app ~module_name:mn smtp_port app_port in
  with_email_app ~module_name:mn ~app_port src (fun endpoint_url ->
    let out = curl_get (endpoint_url "/rich") in
    if not (contains "RICH-EMAIL-QUEUED" out) then
      Alcotest.failf "RichBody: expected 'RICH-EMAIL-QUEUED' in response, got: %S" out
  )

(** Test 5: Capability gate — Email.send without requires [emailCap] fails compile. *)
let test_email_capability_gate () =
  let mn = fresh_module_name "TeslEmailNoCap" in
  let (module_name, src) = tesl_email_no_cap_src mn in
  if not (compile_tesl_check_fails ~module_name src) then
    Alcotest.failf "Expected --check to fail for Email.send without requires [emailCap]"

(** Test 6: Multiple Email.send calls run without error — the App endpoint can be
    hit repeatedly and Email.send keeps succeeding (the outbox handles >1). *)
let test_multiple_emails_queued () =
  let mn = fresh_module_name "TeslEmailMulti" in
  let app_port = pick_free_port () in
  let smtp_port = pick_free_port () in
  let src = tesl_email_send_app ~module_name:mn smtp_port app_port "user1@example.com" in
  with_email_app ~module_name:mn ~app_port src (fun endpoint_url ->
    let out1 = curl_get (endpoint_url "/send") in
    let out2 = curl_get (endpoint_url "/send") in
    let out3 = curl_get (endpoint_url "/send") in
    if not (contains "EMAIL-QUEUED" out1
            && contains "EMAIL-QUEUED" out2
            && contains "EMAIL-QUEUED" out3) then
      Alcotest.failf "Multiple emails: expected 'EMAIL-QUEUED' from all three sends (got %S / %S / %S)"
        out1 out2 out3
  )

(** Test 7: Racket email module loads (define-email macro is bound at runtime). *)
let test_define_email_bound () =
  (* Write a minimal Racket script that uses define-email directly *)
  let rkt_path = Filename.temp_file "tesl_email_defn" ".rkt" in
  let rkt_src = {|#lang racket
(require tesl/tesl/email)

(define-email TestEmail
  #:smtp-host "127.0.0.1"
  #:smtp-port 2525
  #:smtp-username ""
  #:smtp-password ""
  #:smtp-tls #f)

(displayln "DEFINE-EMAIL-OK")
(displayln (email-spec? TestEmail))
|}
  in
  Out_channel.(with_open_text rkt_path (fun oc -> output_string oc rkt_src));
  Fun.protect ~finally:(fun () -> try Sys.remove rkt_path with _ -> ()) (fun () ->
    let (out, err, code) = run_racket rkt_path in
    if code <> 0 then
      Alcotest.failf "define-email bound: racket exited %d; stderr: %s" code err;
    if not (contains "DEFINE-EMAIL-OK" out) then
      Alcotest.failf "define-email bound: expected 'DEFINE-EMAIL-OK' in output, got: %S" out;
    if not (contains "#t" out) then
      Alcotest.failf "define-email bound: expected '#t' (email-spec? result), got: %S" out
  )

(** Test 8: Direct SMTP delivery via Racket net/smtp to MailHog.
    Drives net/smtp exactly as the runtime email-delivery worker does.
    Starts MailHog, sends an email via a Racket script, checks MailHog API. *)
let test_smtp_delivery_to_mailhog () =
  let (mh_pid, smtp_port, api_port, _ui_port) = start_mailhog () in
  Fun.protect ~finally:(fun () -> stop_mailhog mh_pid) (fun () ->
    let rkt = write_direct_smtp_rkt smtp_port
                "recipient@example.com"
                "Tesl Integration Test"
                "Hello from Tesl email integration test"
    in
    Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
      let (out, err, code) = run_racket rkt in
      if code <> 0 then
        Alcotest.failf "SMTP delivery: racket exited %d; stderr: %s" code err;
      if not (contains "SMTP-SENT" out) then
        Alcotest.failf "SMTP delivery: expected 'SMTP-SENT' in output, got: %S" out;
      (* Verify MailHog received the message *)
      Unix.sleepf 0.5; (* give MailHog a moment to process *)
      let count = mailhog_message_count api_port in
      if count < 1 then
        Alcotest.failf "SMTP delivery: MailHog shows %d messages, expected >= 1" count
    )
  )

(** Test 9: MailHog API returns correct subject for delivered email. *)
let test_smtp_subject_in_mailhog () =
  let (mh_pid, smtp_port, api_port, _ui_port) = start_mailhog () in
  Fun.protect ~finally:(fun () -> stop_mailhog mh_pid) (fun () ->
    let subject = "TeSlSubjectCheck12345" in
    let rkt = write_direct_smtp_rkt smtp_port
                "check@example.com"
                subject
                "Body for subject check test"
    in
    Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
      let (out, _err, code) = run_racket rkt in
      if code <> 0 then
        Alcotest.failf "Subject check: racket exited %d" code;
      if not (contains "SMTP-SENT" out) then
        Alcotest.failf "Subject check: SMTP not sent, got: %S" out;
      Unix.sleepf 0.5;
      let api_response = curl_get
        (Printf.sprintf "http://127.0.0.1:%d/api/v2/messages" api_port)
      in
      if not (contains subject api_response) then
        Alcotest.failf "Subject check: expected %S in MailHog API response, got: %S"
          subject api_response
    )
  )

(** Test 10: MailHog API shows correct recipient in delivered email. *)
let test_smtp_recipient_in_mailhog () =
  let (mh_pid, smtp_port, api_port, _ui_port) = start_mailhog () in
  Fun.protect ~finally:(fun () -> stop_mailhog mh_pid) (fun () ->
    let recipient = "unique-recipient-test999@example.com" in
    let rkt = write_direct_smtp_rkt smtp_port
                recipient
                "Recipient Check Test"
                "Body for recipient check"
    in
    Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
      let (out, _err, code) = run_racket rkt in
      if code <> 0 then
        Alcotest.failf "Recipient check: racket exited %d" code;
      if not (contains "SMTP-SENT" out) then
        Alcotest.failf "Recipient check: SMTP not sent";
      Unix.sleepf 0.5;
      let api_response = curl_get
        (Printf.sprintf "http://127.0.0.1:%d/api/v2/messages" api_port)
      in
      if not (contains "unique-recipient-test999" api_response) then
        Alcotest.failf "Recipient check: expected recipient in MailHog API response, got: %S"
          api_response
    )
  )

(* ── Main ───────────────────────────────────────────────────────────────────── *)

let () =
  Random.self_init ();
  Alcotest.run "Email-Integration" [
    "tesl-app", [
      Alcotest.test_case "email module loads in a running App"   `Slow
        (guarded_test "email-module-loads"   test_email_module_loads);
      Alcotest.test_case "Email.send runs in App [emailCap] scope"  `Slow
        (guarded_test "email-send-queues"    test_email_send_queues);
      Alcotest.test_case "HtmlBody compiles and runs"            `Slow
        (guarded_test "html-body"            test_email_html_body);
      Alcotest.test_case "RichBody compiles and runs"            `Slow
        (guarded_test "rich-body"            test_email_rich_body);
      Alcotest.test_case "multiple Email.send calls succeed"     `Slow
        (guarded_test "multi-queue"          test_multiple_emails_queued);
    ];
    "capability", [
      Alcotest.test_case "missing requires [emailCap] causes compile error" `Quick
        (guarded_test "no-cap-error"         test_email_capability_gate);
    ];
    "racket-runtime", [
      Alcotest.test_case "define-email macro is bound at runtime" `Slow
        (guarded_test "define-email-bound"   test_define_email_bound);
    ];
    "smtp-mailhog", [
      Alcotest.test_case "direct SMTP delivery to MailHog"       `Slow
        (guarded_mailhog_test "smtp-delivery"  test_smtp_delivery_to_mailhog);
      Alcotest.test_case "MailHog shows correct subject"          `Slow
        (guarded_mailhog_test "smtp-subject"   test_smtp_subject_in_mailhog);
      Alcotest.test_case "MailHog shows correct recipient"        `Slow
        (guarded_mailhog_test "smtp-recipient" test_smtp_recipient_in_mailhog);
    ];
  ]
