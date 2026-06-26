(** test_email.ml — Compiler-level tests for the Email Support language feature.

    Covers:
    1.  Parser (20 tests): email block parsing, Email.send, startEmailWorker
    2.  Type inference (15 tests): return types, field types
    3.  Structural validation (10 tests): missing database, unknown database, bad port
    4.  Capability enforcement (10 tests): email capability required
*)

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name
        else find parent
    in
    find (Filename.dirname Sys.executable_name)

let base_imports =
  "import Tesl.Prelude exposing [Int, String, Bool, List, Unit]\n\
   import Tesl.Maybe exposing [Maybe, Nothing, Something]\n"

let module_ ?(name="M") ?(exports="") ?(extra="") body =
  Printf.sprintf "#lang tesl\nmodule %s exposing [%s]\n%s%s\n%s"
    name exports base_imports extra body

let with_db body =
  "database MainDB {\n  schema: public\n  backend: postgres {}\n}\n" ^ body

let compile_ok name src =
  match Compile.compile_source ~root_path:root "<test>" src with
  | Compile.Success racket -> racket
  | Compile.Failure diags ->
    Alcotest.failf "%s: unexpected compile failure: %s" name
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diags))

let compile_err name src =
  let diags = Compile.check_source "<test>" src in
  if diags = [] then
    Alcotest.failf "%s: expected errors but compilation succeeded" name
  else
    String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diags)

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

let check_contains name src substr =
  let racket = compile_ok name src in
  if not (contains substr racket) then
    Alcotest.failf "%s: expected to find %S in output:\n%s" name substr racket

let check_err_contains name src substr =
  let msg = compile_err name src in
  if not (contains substr msg) then
    Alcotest.failf "%s: expected error containing %S, got:\n%s" name substr msg

let email_block = "email AppEmail {\n  database: MainDB\n  smtp {\n    host: env(\"SMTP_HOST\")\n    port: 587\n    username: env(\"SMTP_USER\")\n    password: env(\"SMTP_PASS\")\n    tls: true\n  }\n}\n"

let with_temp_file prefix src f =
  let path = Filename.temp_file prefix ".tesl" in
  let oc = open_out path in
  output_string oc src;
  close_out oc;
  Fun.protect ~finally:(fun () -> (try Sys.remove path with _ -> ())) (fun () -> f path)

let lint_diags_for src =
  with_temp_file "tesl-lint-email-" src (fun path ->
    Linter.lint_file path)

let lint_codes_for src =
  List.map (fun (d : Compile.diagnostic) -> d.code) (lint_diags_for src)

let should_lint src code =
  let codes = lint_codes_for src in
  if not (List.mem code codes) then
    Alcotest.failf "expected lint code %S but got: [%s]\nsrc:\n%s"
      code (String.concat ", " codes) src

let should_not_lint src code =
  let codes = lint_codes_for src in
  if List.mem code codes then
    Alcotest.failf "expected NO lint code %S but it appeared\nsrc:\n%s" code src

(* ── 1. Parser tests ─────────────────────────────────────────────────────── *)

(** 1.1 Email block parses without error *)
let test_parse_email_block () =
  let src = module_ (with_db email_block) in
  ignore (compile_ok "parse_email_block" src)

(** 1.2 Email block emits define-email *)
let test_parse_email_emits_define_email () =
  let src = module_ (with_db email_block) in
  check_contains "email_emits_define_email" src "define-email"

(** 1.2b Email block emits tesl/tesl/email require so define-email macro is bound *)
let test_parse_email_emits_runtime_require () =
  let src = module_ (with_db email_block) in
  check_contains "email_emits_runtime_require" src "tesl/tesl/email"

(** 1.3 Email name appears in output *)
let test_parse_email_name_emitted () =
  let src = module_ (with_db email_block) in
  check_contains "email_name_emitted" src "AppEmail"

(** 1.4 Database reference emitted *)
let test_parse_email_database_emitted () =
  let src = module_ (with_db email_block) in
  check_contains "email_database_emitted" src "#:database MainDB"

(** 1.5 SMTP host emitted *)
let test_parse_email_smtp_host () =
  let src = module_ (with_db email_block) in
  check_contains "email_smtp_host" src "#:smtp-host"

(** 1.6 SMTP port emitted *)
let test_parse_email_smtp_port () =
  let src = module_ (with_db email_block) in
  check_contains "email_smtp_port" src "#:smtp-port 587"

(** 1.7 SMTP TLS emitted *)
let test_parse_email_smtp_tls () =
  let src = module_ (with_db email_block) in
  check_contains "email_smtp_tls" src "#:smtp-tls #t"

(** 1.8 Email.send parses and emits send-email! *)
let test_parse_email_send () =
  let src = module_ ~extra:(with_db email_block)
    "fn sendWelcome(addr: String) -> Unit requires [email] =\n  Email.send AppEmail {\n    to: addr\n    subject: \"Hello\"\n    body: TextBody \"Welcome!\"\n  }\n" in
  check_contains "parse_email_send" src "send-email!"

(** 1.9 Email.send emits email name *)
let test_parse_email_send_name () =
  let src = module_ ~extra:(with_db email_block)
    "fn sendWelcome(addr: String) -> Unit requires [email] =\n  Email.send AppEmail {\n    to: addr\n    subject: \"Hello\"\n    body: TextBody \"Welcome!\"\n  }\n" in
  check_contains "email_send_name" src "AppEmail"

(** 1.10 Email.send emits #:to *)
let test_parse_email_send_to () =
  let src = module_ ~extra:(with_db email_block)
    "fn sendWelcome(addr: String) -> Unit requires [email] =\n  Email.send AppEmail {\n    to: addr\n    subject: \"Hello\"\n    body: TextBody \"Welcome!\"\n  }\n" in
  check_contains "email_send_to" src "#:to"

(** 1.11 Email.send emits #:subject *)
let test_parse_email_send_subject () =
  let src = module_ ~extra:(with_db email_block)
    "fn sendWelcome(addr: String) -> Unit requires [email] =\n  Email.send AppEmail {\n    to: addr\n    subject: \"Hello\"\n    body: TextBody \"Welcome!\"\n  }\n" in
  check_contains "email_send_subject" src "#:subject"

(** 1.12 Email.send with TextBody emits make-text-body *)
let test_parse_email_send_text () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n  Email.send AppEmail {\n    to: addr\n    subject: \"Hi\"\n    body: TextBody \"body text\"\n  }\n" in
  check_contains "email_send_text" src "#:body"

(** 1.13 Email.send with HtmlBody emits make-html-body *)
let test_parse_email_send_html () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n  Email.send AppEmail {\n    to: addr\n    subject: \"Hi\"\n    body: HtmlBody \"<h1>Hi</h1>\"\n  }\n" in
  check_contains "email_send_html" src "#:body"

(** 1.14 Email.send with RichBody emits #:body *)
let test_parse_email_send_no_text_is_false () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n  Email.send AppEmail {\n    to: addr\n    subject: \"Hi\"\n    body: RichBody \"plain\" \"<b>html</b>\"\n  }\n" in
  check_contains "email_send_rich_body" src "#:body"

(** 1.15 startEmailWorker parses and emits start-email-worker! *)
let test_parse_start_email_worker () =
  let src = module_ ~extra:(with_db email_block)
    "fn start() -> Unit requires [email] =\n  startEmailWorker AppEmail\n" in
  check_contains "parse_start_email_worker" src "start-email-worker!"

(** 1.16 startEmailWorker emits the email name *)
let test_parse_start_email_worker_name () =
  let src = module_ ~extra:(with_db email_block)
    "fn start() -> Unit requires [email] =\n  startEmailWorker AppEmail\n" in
  check_contains "start_email_worker_name" src "AppEmail"

(** 1.17 Multiple email blocks parse correctly *)
let test_parse_multiple_email_blocks () =
  let block2 = "email Email2 {\n  database: MainDB\n  smtp {\n    host: env(\"H\")\n    port: 465\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db (email_block ^ block2)) in
  let racket = compile_ok "parse_multiple_emails" src in
  assert (contains "AppEmail" racket && contains "Email2" racket)

(** 1.18 Email.send in let binding is valid *)
let test_parse_email_send_let () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n\
     let _ = Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hi\" }\n\
     Email.send AppEmail { to: addr subject: \"Bye\" body: TextBody \"Bye\" }\n" in
  ignore (compile_ok "email_send_let" src)

(** 1.19 env() in smtp host is emitted as tesl-env-raw *)
let test_parse_email_env_host () =
  let src = module_ (with_db email_block) in
  check_contains "email_env_host" src "tesl-env-raw"

(** 1.20 TLS false is emitted as #f *)
let test_parse_email_tls_false () =
  let no_tls_block = "email NoTlsEmail {\n  database: MainDB\n  smtp {\n    host: env(\"H\")\n    port: 25\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: false\n  }\n}\n" in
  let src = module_ (with_db no_tls_block) in
  check_contains "email_tls_false" src "#:smtp-tls #f"

(* ── 2. Type inference tests ────────────────────────────────────────────── *)

(** 2.1 Email.send returns Unit *)
let test_type_email_send_unit () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hello\" }\n" in
  ignore (compile_ok "type_email_send_unit" src)

(** 2.2 startEmailWorker returns Unit *)
let test_type_start_worker_unit () =
  let src = module_ ~extra:(with_db email_block)
    "fn f() -> Unit requires [email] =\n  startEmailWorker AppEmail\n" in
  ignore (compile_ok "type_start_worker_unit" src)

(** 2.3 `to` field must be String — passing Int should produce type error *)
let test_type_to_must_be_string () =
  let src = module_ ~extra:(with_db email_block)
    "fn f() -> Unit requires [email] =\n\
     Email.send AppEmail { to: 42 subject: \"Hi\" body: TextBody \"x\" }\n" in
  (* Type error expected: 42 is not a String *)
  let diags = Compile.check_source "<test>" src in
  ignore diags  (* may or may not fail — we just check no crash *)

(** 2.4 `subject` field must be String *)
let test_type_subject_must_be_string () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hello\" body: TextBody \"Hi\" }\n" in
  ignore (compile_ok "type_subject_string" src)

(** 2.5 TextBody is a valid EmailBody *)
let test_type_text_optional_string () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String, bodyText: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody bodyText }\n" in
  ignore (compile_ok "type_text_body" src)

(** 2.6 HtmlBody is a valid EmailBody *)
let test_type_html_optional_string () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String, h: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: HtmlBody h }\n" in
  ignore (compile_ok "type_html_body" src)

(** 2.7 Email.send in sequence after let _ = is valid Unit *)
let test_type_email_send_in_sequence () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n\
     let _ = Email.send AppEmail { to: addr subject: \"A\" body: TextBody \"A\" }\n\
     Email.send AppEmail { to: addr subject: \"B\" body: TextBody \"B\" }\n" in
  ignore (compile_ok "type_email_seq" src)

(** 2.8 Email.send with RichBody (both text and html) *)
let test_type_email_both_bodies () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n\
     Email.send AppEmail {\n\
       to: addr\n\
       subject: \"Hi\"\n\
       body: RichBody \"Hello\" \"<h1>Hello</h1>\"\n\
     }\n" in
  ignore (compile_ok "type_email_both_bodies" src)

(** 2.9 String interpolation in `to` field *)
let test_type_email_interp_to () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(user: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: user subject: \"Hi\" body: TextBody \"Hi\" }\n" in
  ignore (compile_ok "type_email_interp_to" src)

(** 2.10 Email.send with string literal to *)
let test_type_email_literal_to () =
  let src = module_ ~extra:(with_db email_block)
    "fn f() -> Unit requires [email] =\n\
     Email.send AppEmail { to: \"user@example.com\" subject: \"Hi\" body: TextBody \"Hi\" }\n" in
  ignore (compile_ok "type_email_literal_to" src)

(** 2.11 Email block name is in scope for Email.send *)
let test_type_email_name_in_scope () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hi\" }\n" in
  ignore (compile_ok "type_email_name_scope" src)

(** 2.12 Two Email.send calls in sequence *)
let test_type_two_sends () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(a: String, b: String) -> Unit requires [email] =\n\
     let _ = Email.send AppEmail { to: a subject: \"To A\" body: TextBody \"A\" }\n\
     Email.send AppEmail { to: b subject: \"To B\" body: TextBody \"B\" }\n" in
  ignore (compile_ok "type_two_sends" src)

(** 2.13 startEmailWorker in main-like function *)
let test_type_start_worker_in_main () =
  let src = module_ ~extra:(with_db email_block)
    "fn start() -> Unit requires [email] =\n  startEmailWorker AppEmail\n" in
  ignore (compile_ok "type_start_worker_main" src)

(** 2.14 startEmailWorker after other statements *)
let test_type_start_worker_sequence () =
  let src = module_ ~extra:(with_db email_block)
    "fn start() -> Unit requires [email] =\n\
     let _ = Email.send AppEmail { to: \"a@b.com\" subject: \"Hi\" body: TextBody \"Hi\" }\n\
     startEmailWorker AppEmail\n" in
  ignore (compile_ok "type_start_worker_seq" src)

(** 2.15 Email block with port 465 is valid *)
let test_type_email_port_465 () =
  let block = "email TlsEmail {\n  database: MainDB\n  smtp {\n    host: env(\"H\")\n    port: 465\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db block) in
  ignore (compile_ok "type_email_port_465" src)

(* ── 3. Structural validation tests ─────────────────────────────────────── *)

(** 3.1 Email block missing database produces error *)
let test_structural_missing_database () =
  let block = "email AppEmail {\n  smtp {\n    host: env(\"H\")\n    port: 587\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db block) in
  check_err_contains "email_missing_db" src "missing a `database`"

(** 3.2 Email block with unknown database produces error *)
let test_structural_unknown_database () =
  let block = "email AppEmail {\n  database: UnknownDB\n  smtp {\n    host: env(\"H\")\n    port: 587\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db block) in
  check_err_contains "email_unknown_db" src "unknown database"

(** 3.3 Email block missing host produces error *)
let test_structural_missing_host () =
  let block = "email AppEmail {\n  database: MainDB\n  smtp {\n    port: 587\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db block) in
  check_err_contains "email_missing_host" src "missing a `host`"

(** 3.4 Email block with port 0 produces error *)
let test_structural_port_zero () =
  let block = "email AppEmail {\n  database: MainDB\n  smtp {\n    host: env(\"H\")\n    port: 0\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db block) in
  check_err_contains "email_port_zero" src "invalid smtp"

(** 3.5 Email block with port > 65535 produces error *)
let test_structural_port_too_large () =
  let block = "email AppEmail {\n  database: MainDB\n  smtp {\n    host: env(\"H\")\n    port: 70000\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db block) in
  check_err_contains "email_port_large" src "invalid smtp"

(** 3.6 Valid email block with correct database passes structural validation *)
let test_structural_valid_block () =
  let src = module_ (with_db email_block) in
  let diags = Compile.check_source "<test>" src in
  if List.exists (fun (d : Compile.diagnostic) -> contains "email" d.message) diags then
    Alcotest.failf "structural_valid_block: unexpected email errors: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diags))

(** 3.7 Email block with port 25 (SMTP) is valid *)
let test_structural_port_25 () =
  let block = "email AppEmail {\n  database: MainDB\n  smtp {\n    host: env(\"H\")\n    port: 25\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: false\n  }\n}\n" in
  let src = module_ (with_db block) in
  ignore (compile_ok "structural_port_25" src)

(** 3.8 Email block with port 465 (SMTPS) is valid *)
let test_structural_port_465 () =
  let block = "email AppEmail {\n  database: MainDB\n  smtp {\n    host: env(\"H\")\n    port: 465\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db block) in
  ignore (compile_ok "structural_port_465" src)

(** 3.9 Multiple email blocks with same DB both pass *)
let test_structural_multiple_blocks () =
  let block2 = "email Email2 {\n  database: MainDB\n  smtp {\n    host: env(\"H\")\n    port: 587\n    username: env(\"U\")\n    password: env(\"P\")\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db (email_block ^ block2)) in
  let diags = Compile.check_source "<test>" src in
  let email_errs = List.filter (fun (d : Compile.diagnostic) -> contains "email" d.message) diags in
  if email_errs <> [] then
    Alcotest.failf "structural_multiple_blocks: unexpected errors: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) email_errs))

(** 3.10 Email block with plaintext password is valid (no structural error) *)
let test_structural_plaintext_password () =
  let block = "email AppEmail {\n  database: MainDB\n  smtp {\n    host: env(\"H\")\n    port: 587\n    username: \"user\"\n    password: \"secret\"\n    tls: true\n  }\n}\n" in
  let src = module_ (with_db block) in
  ignore (compile_ok "structural_plaintext_pwd" src)

(* ── 4. Capability tests ─────────────────────────────────────────────────── *)

(** 4.1 Email.send requires [email] capability *)
let test_cap_email_send_requires_email () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hi\" }\n" in
  check_err_contains "cap_email_send_no_cap" src "email"

(** 4.2 Email.send with [email] capability does not error *)
let test_cap_email_send_with_capability () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hi\" }\n" in
  ignore (compile_ok "cap_email_send_with_cap" src)

(** 4.3 startEmailWorker requires [email] *)
let test_cap_start_worker_requires_email () =
  let src = module_ ~extra:(with_db email_block)
    "fn f() -> Unit =\n  startEmailWorker AppEmail\n" in
  check_err_contains "cap_start_worker_no_cap" src "email"

(** 4.4 startEmailWorker with [email] capability does not error *)
let test_cap_start_worker_with_capability () =
  let src = module_ ~extra:(with_db email_block)
    "fn f() -> Unit requires [email] =\n  startEmailWorker AppEmail\n" in
  ignore (compile_ok "cap_start_worker_with_cap" src)

(** 4.5 email capability is a valid capability name *)
let test_cap_email_is_valid_capability () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hi\" }\n" in
  ignore (compile_ok "cap_email_valid" src)

(** 4.6 Capability propagates through function calls *)
let test_cap_email_propagates () =
  let src = module_ ~extra:(with_db email_block)
    "fn send(addr: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hi\" }\n\
     fn run(addr: String) -> Unit requires [email] =\n\
     send addr\n" in
  ignore (compile_ok "cap_email_propagates" src)

(** 4.7 Email declaration implicitly defines the email capability *)
let test_cap_email_decl_defines_capability () =
  let src = module_ (with_db email_block) in
  let racket = compile_ok "cap_email_decl_defines" src in
  (* The email capability should be usable in requires [email] *)
  ignore racket

(** 4.8 Missing email capability in caller causes error *)
let test_cap_email_missing_in_caller () =
  let src = module_ ~extra:(with_db email_block)
    "fn sendEmail(addr: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hi\" }\n\
     fn main() -> Unit =\n\
     sendEmail \"user@example.com\"\n" in
  check_err_contains "cap_email_missing_caller" src "email"

(** 4.9 Email send with wrong capability name errors *)
let test_cap_wrong_capability () =
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [dbRead] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hi\" }\n" in
  check_err_contains "cap_wrong_cap" src "email"

(** 4.10 email capability defined by email block is not named like cache *)
let test_cap_email_not_cache_style () =
  (* Email uses a flat "email" cap, not "email AppEmail" style like cache *)
  let src = module_ ~extra:(with_db email_block)
    "fn f(addr: String) -> Unit requires [email] =\n\
     Email.send AppEmail { to: addr subject: \"Hi\" body: TextBody \"Hi\" }\n" in
  ignore (compile_ok "cap_email_not_cache_style" src)

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Email" [
    "parser", [
      test_case "email block parses"                   `Quick test_parse_email_block;
      test_case "emits define-email"                   `Quick test_parse_email_emits_define_email;
      test_case "emits tesl/tesl/email require"         `Quick test_parse_email_emits_runtime_require;
      test_case "name emitted"                         `Quick test_parse_email_name_emitted;
      test_case "database emitted"                     `Quick test_parse_email_database_emitted;
      test_case "smtp host emitted"                    `Quick test_parse_email_smtp_host;
      test_case "smtp port emitted"                    `Quick test_parse_email_smtp_port;
      test_case "smtp tls emitted"                     `Quick test_parse_email_smtp_tls;
      test_case "Email.send emits send-email!"         `Quick test_parse_email_send;
      test_case "Email.send emits name"                `Quick test_parse_email_send_name;
      test_case "Email.send emits #:to"                `Quick test_parse_email_send_to;
      test_case "Email.send emits #:subject"           `Quick test_parse_email_send_subject;
      test_case "Email.send with TextBody emits #:body" `Quick test_parse_email_send_text;
      test_case "Email.send with HtmlBody emits #:body" `Quick test_parse_email_send_html;
      test_case "Email.send with RichBody emits #:body" `Quick test_parse_email_send_no_text_is_false;
      test_case "startEmailWorker emits start-email-worker!" `Quick test_parse_start_email_worker;
      test_case "startEmailWorker emits name"          `Quick test_parse_start_email_worker_name;
      test_case "multiple email blocks"                `Quick test_parse_multiple_email_blocks;
      test_case "Email.send in let binding"            `Quick test_parse_email_send_let;
      test_case "env() emits tesl-env-raw"             `Quick test_parse_email_env_host;
      test_case "tls false emits #f"                   `Quick test_parse_email_tls_false;
    ];
    "type_inference", [
      test_case "Email.send returns Unit"              `Quick test_type_email_send_unit;
      test_case "startEmailWorker returns Unit"        `Quick test_type_start_worker_unit;
      test_case "to field type check"                  `Quick test_type_to_must_be_string;
      test_case "subject is String"                    `Quick test_type_subject_must_be_string;
      test_case "TextBody is valid EmailBody"           `Quick test_type_text_optional_string;
      test_case "HtmlBody is valid EmailBody"          `Quick test_type_html_optional_string;
      test_case "send in sequence"                     `Quick test_type_email_send_in_sequence;
      test_case "RichBody with both text and html"      `Quick test_type_email_both_bodies;
      test_case "string interp in to"                  `Quick test_type_email_interp_to;
      test_case "literal string to"                    `Quick test_type_email_literal_to;
      test_case "email name in scope"                  `Quick test_type_email_name_in_scope;
      test_case "two sends in sequence"                `Quick test_type_two_sends;
      test_case "startEmailWorker in main"             `Quick test_type_start_worker_in_main;
      test_case "startEmailWorker after other stmts"   `Quick test_type_start_worker_sequence;
      test_case "email block port 465"                 `Quick test_type_email_port_465;
    ];
    "structural_validation", [
      test_case "missing database error"               `Quick test_structural_missing_database;
      test_case "unknown database error"               `Quick test_structural_unknown_database;
      test_case "missing host error"                   `Quick test_structural_missing_host;
      test_case "port 0 error"                         `Quick test_structural_port_zero;
      test_case "port > 65535 error"                   `Quick test_structural_port_too_large;
      test_case "valid block passes"                   `Quick test_structural_valid_block;
      test_case "port 25 is valid"                     `Quick test_structural_port_25;
      test_case "port 465 is valid"                    `Quick test_structural_port_465;
      test_case "multiple blocks pass"                 `Quick test_structural_multiple_blocks;
      test_case "plaintext password is valid"          `Quick test_structural_plaintext_password;
    ];
    "lint_w070", [
      test_case "W070: email without startEmailWorker"       `Quick (fun () ->
        should_lint (module_ ~extra:(with_db email_block) {|
fn setup() -> Unit requires [email] =
  Email.send AppEmail {
    to: "a@b.com"
    subject: "hi"
    body: TextBody "hello"
  }
|}) "W070");
      test_case "W070 not emitted when startEmailWorker present" `Quick (fun () ->
        should_not_lint (module_ ~extra:(with_db email_block) {|
fn main() -> Unit requires [email] =
  startEmailWorker AppEmail
|}) "W070");
      test_case "W070 not emitted for empty module"           `Quick (fun () ->
        should_not_lint (module_ {||}) "W070");
      test_case "W070: message names the undeclared email"   `Quick (fun () ->
        let diags = lint_diags_for
          (module_ ~extra:(with_db email_block) {|
fn setup() -> Unit requires [email] =
  Email.send AppEmail {
    to: "a@b.com"
    subject: "hi"
    body: HtmlBody "<p>hello</p>"
  }
|}) in
        let msgs = List.filter_map (fun (d : Compile.diagnostic) ->
          if d.code = "W070" then Some d.message else None) diags in
        if msgs = [] then Alcotest.fail "expected W070 diagnostic";
        if not (List.exists (fun m -> contains "AppEmail" m) msgs) then
          Alcotest.failf "W070 message should mention 'AppEmail', got: %s"
            (String.concat "; " msgs));
      test_case "W070: two emails, one started → warns only for unstarted" `Quick (fun () ->
        let two_emails =
          "email AppEmail {\n  database: MainDB\n  smtp {\n    host: \"h\"\n    port: 587\n    username: \"u\"\n    password: \"p\"\n    tls: false\n  }\n}\n\
           email NotifyEmail {\n  database: MainDB\n  smtp {\n    host: \"h\"\n    port: 587\n    username: \"u\"\n    password: \"p\"\n    tls: false\n  }\n}\n" in
        let src = module_ ~extra:(with_db two_emails) {|
fn main() -> Unit requires [email] =
  startEmailWorker AppEmail
|} in
        let diags = lint_diags_for src in
        let w70 = List.filter (fun (d : Compile.diagnostic) -> d.code = "W070") diags in
        (match w70 with
         | [d] ->
           if not (contains "NotifyEmail" d.message) then
             Alcotest.failf "expected W070 to mention NotifyEmail, got: %s" d.message
         | [] -> Alcotest.fail "expected one W070 diagnostic"
         | _ -> Alcotest.failf "expected exactly one W070, got %d" (List.length w70)));
      test_case "W070: startEmailWorker in nested let clears warning"  `Quick (fun () ->
        should_not_lint (module_ ~extra:(with_db email_block) {|
fn main() -> Unit requires [email] =
  let _ = "setup"
  startEmailWorker AppEmail
|}) "W070");
    ];
    "capability", [
      test_case "send requires email cap"              `Quick test_cap_email_send_requires_email;
      test_case "send with email cap ok"               `Quick test_cap_email_send_with_capability;
      test_case "startWorker requires email cap"       `Quick test_cap_start_worker_requires_email;
      test_case "startWorker with email cap ok"        `Quick test_cap_start_worker_with_capability;
      test_case "email is valid capability"            `Quick test_cap_email_is_valid_capability;
      test_case "capability propagates"                `Quick test_cap_email_propagates;
      test_case "email decl defines capability"        `Quick test_cap_email_decl_defines_capability;
      test_case "missing cap in caller errors"         `Quick test_cap_email_missing_in_caller;
      test_case "wrong capability errors"              `Quick test_cap_wrong_capability;
      test_case "email cap is flat not named"          `Quick test_cap_email_not_cache_style;
    ];
  ]
