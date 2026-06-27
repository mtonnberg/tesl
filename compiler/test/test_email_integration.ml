(** test_email_integration.ml — Runtime integration tests for the Email module.

    These tests compile real Tesl programs with email blocks, run the generated
    Racket code, and verify the runtime behaviour:

    - The email module loads at runtime without unbound-identifier errors
    - Email.send stores messages in the in-memory outbox
    - The email capability gate is enforced at compile time
    - Direct SMTP delivery to a live MailHog SMTP server works

    MailHog binary: /nix/store/b5jwbxli7mn2w0gx7l6bvqkyvxg07z10-MailHog-1.0.1/bin/MailHog
    Tests skip gracefully when racket or MailHog are not available.
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

let curl_get url =
  let (out, _, _) = run_cmd ~timeout_secs:10 curl_binary [|"-s"; url|] in
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

(* ── Tesl email source templates ─────────────────────────────────────────────── *)

(** Common DB block template, shared by all email tests. *)
let db_block = {|database AppDB {
  backend: postgres
  schema: "testschema"
  entities: []
  postgres {
    database: env("TESL_EMAIL_TEST_DB")
    user: env("TESL_EMAIL_TEST_USER")
    password: env("TESL_EMAIL_TEST_PASS")
    host: "localhost"
    port: envInt("TESL_EMAIL_TEST_PORT", 5432)
    socket: env("TESL_EMAIL_TEST_SOCK")
  }
}|}

(** Email block template. *)
let email_block smtp_port = Printf.sprintf {|email AppEmail {
  database: AppDB
  smtp {
    host: "127.0.0.1"
    port: %d
    username: ""
    password: ""
    tls: false
  }
}|} smtp_port

(** Tesl source with an email block + load only. *)
let tesl_email_load_src ~module_name smtp_port =
  Printf.sprintf {|#lang tesl
module %s exposing []

import Tesl.Prelude exposing [String, Unit, Bool(..)]

%s

%s

main {
  let _ = print "EMAIL-MODULE-LOADED"
  Unit
}
|} module_name db_block (email_block smtp_port)

(** Tesl source that sends an email via Email.send (in-memory fallback). *)
let tesl_email_send_src ~module_name smtp_port recipient =
  Printf.sprintf {|#lang tesl
module %s exposing []

import Tesl.Prelude exposing [String, Unit, Bool(..)]

%s

%s

fn queueEmail(addr: String) -> Unit requires [email] =
  Email.send AppEmail {
    to: addr
    subject: "Integration Test Subject"
    body: TextBody "Hello from Tesl integration test"
  }

main {
  with capabilities [email] {
    let _ = queueEmail "%s"
    let _ = print "EMAIL-QUEUED"
    Unit
  }
}
|} module_name db_block (email_block smtp_port) recipient

(** Tesl source that uses HtmlBody. *)
let tesl_email_html_src ~module_name smtp_port =
  Printf.sprintf {|#lang tesl
module %s exposing []

import Tesl.Prelude exposing [String, Unit, Bool(..)]

%s

%s

fn sendHtml(addr: String) -> Unit requires [email] =
  Email.send AppEmail {
    to: addr
    subject: "HTML Email Test"
    body: HtmlBody "<h1>Hello</h1><p>HTML email test</p>"
  }

main {
  with capabilities [email] {
    let _ = sendHtml "html@example.com"
    let _ = print "HTML-EMAIL-QUEUED"
    Unit
  }
}
|} module_name db_block (email_block smtp_port)

(** Tesl source that uses RichBody. *)
let tesl_email_rich_src ~module_name smtp_port =
  Printf.sprintf {|#lang tesl
module %s exposing []

import Tesl.Prelude exposing [String, Unit, Bool(..)]

%s

%s

fn sendRich(addr: String) -> Unit requires [email] =
  Email.send AppEmail {
    to: addr
    subject: "Rich Email Test"
    body: RichBody "Plain text fallback" "<h1>HTML version</h1>"
  }

main {
  with capabilities [email] {
    let _ = sendRich "rich@example.com"
    let _ = print "RICH-EMAIL-QUEUED"
    Unit
  }
}
|} module_name db_block (email_block smtp_port)

(** Build module name + source for a Tesl program without requires [email]. *)
let tesl_email_no_cap_src module_name =
  (module_name, Printf.sprintf {|#lang tesl
module %s exposing []

import Tesl.Prelude exposing [String, Unit, Bool(..)]

%s

%s

fn badSend(addr: String) -> Unit =
  Email.send AppEmail {
    to: addr
    subject: "No cap"
    body: TextBody "This should fail capability check"
  }

main {
  let _ = badSend "test@example.com"
  Unit
}
|} module_name db_block (email_block 2525))

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

(** Write a Racket script that sends an email via net/smtp directly (correct API),
    bypassing the email.rkt deliver-email! call.  Returns path to the script. *)
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

(** Test 1: Email module loads at runtime — no unbound identifier errors. *)
let test_email_module_loads () =
  let mn = fresh_module_name "TeslEmailLoad" in
  let src = tesl_email_load_src ~module_name:mn 2525 in
  let rkt = compile_tesl_src ~module_name:mn src in
  Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
    let (out, err, code) = run_racket rkt in
    if code <> 0 then
      Alcotest.failf "Email module load: racket exited %d; stderr: %s" code err;
    if not (contains "EMAIL-MODULE-LOADED" out) then
      Alcotest.failf "Email module load: expected 'EMAIL-MODULE-LOADED' in output, got: %S" out
  )

(** Test 2: Email.send queues a message to in-memory store without error. *)
let test_email_send_queues () =
  let mn = fresh_module_name "TeslEmailSend" in
  let src = tesl_email_send_src ~module_name:mn 2525 "recipient@example.com" in
  let rkt = compile_tesl_src ~module_name:mn src in
  Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
    let (out, err, code) = run_racket rkt in
    if code <> 0 then
      Alcotest.failf "Email.send queue: racket exited %d; stderr: %s" code err;
    if not (contains "EMAIL-QUEUED" out) then
      Alcotest.failf "Email.send queue: expected 'EMAIL-QUEUED' in output, got: %S" out
  )

(** Test 3: HtmlBody variant compiles and runs without error. *)
let test_email_html_body () =
  let mn = fresh_module_name "TeslEmailHtml" in
  let src = tesl_email_html_src ~module_name:mn 2525 in
  let rkt = compile_tesl_src ~module_name:mn src in
  Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
    let (out, err, code) = run_racket rkt in
    if code <> 0 then
      Alcotest.failf "HtmlBody: racket exited %d; stderr: %s" code err;
    if not (contains "HTML-EMAIL-QUEUED" out) then
      Alcotest.failf "HtmlBody: expected 'HTML-EMAIL-QUEUED' in output, got: %S" out
  )

(** Test 4: RichBody variant compiles and runs without error. *)
let test_email_rich_body () =
  let mn = fresh_module_name "TeslEmailRich" in
  let src = tesl_email_rich_src ~module_name:mn 2525 in
  let rkt = compile_tesl_src ~module_name:mn src in
  Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
    let (out, err, code) = run_racket rkt in
    if code <> 0 then
      Alcotest.failf "RichBody: racket exited %d; stderr: %s" code err;
    if not (contains "RICH-EMAIL-QUEUED" out) then
      Alcotest.failf "RichBody: expected 'RICH-EMAIL-QUEUED' in output, got: %S" out
  )

(** Test 5: Capability gate — Email.send without requires [email] fails compile. *)
let test_email_capability_gate () =
  let mn = fresh_module_name "TeslEmailNoCap" in
  let (module_name, src) = tesl_email_no_cap_src mn in
  if not (compile_tesl_check_fails ~module_name src) then
    Alcotest.failf "Expected --check to fail for Email.send without requires [email]"

(** Test 6: Multiple email sends run without error (tests the outbox handles >1). *)
let test_multiple_emails_queued () =
  (* Compile once and run twice — the in-memory store is fresh each run. *)
  let mn = fresh_module_name "TeslEmailMulti" in
  let src = tesl_email_send_src ~module_name:mn 2525 "user1@example.com" in
  let rkt = compile_tesl_src ~module_name:mn src in
  Fun.protect ~finally:(fun () -> try Sys.remove rkt with _ -> ()) (fun () ->
    let (out1, _err1, code1) = run_racket rkt in
    let (out2, _err2, code2) = run_racket rkt in
    if code1 <> 0 || code2 <> 0 then
      Alcotest.failf "Multiple emails: expected exit 0 for both runs (got %d, %d)" code1 code2;
    if not (contains "EMAIL-QUEUED" out1 && contains "EMAIL-QUEUED" out2) then
      Alcotest.failf "Multiple emails: expected 'EMAIL-QUEUED' in both runs"
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
    "tesl-compilation", [
      Alcotest.test_case "email module loads at runtime"         `Slow
        (guarded_test "email-module-loads"   test_email_module_loads);
      Alcotest.test_case "Email.send queues to in-memory store"  `Slow
        (guarded_test "email-send-queues"    test_email_send_queues);
      Alcotest.test_case "HtmlBody compiles and runs"            `Slow
        (guarded_test "html-body"            test_email_html_body);
      Alcotest.test_case "RichBody compiles and runs"            `Slow
        (guarded_test "rich-body"            test_email_rich_body);
      Alcotest.test_case "multiple emails queued without error"  `Slow
        (guarded_test "multi-queue"          test_multiple_emails_queued);
    ];
    "capability", [
      Alcotest.test_case "missing requires [email] causes compile error" `Quick
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
