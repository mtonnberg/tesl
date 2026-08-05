(** SEC005 — "GET handlers do not mutate", enforced at compile time.
    roadmap/next/get_handlers_do_not_mutate.md.

    WHY THIS IS A HARD ERROR AND NOT A LINT.  The session cookie ships
    `SameSite=Lax`, and a browser DOES attach a Lax cookie to a cross-site
    TOP-LEVEL GET navigation.  So a mutating GET is a CSRF hole an attacker
    triggers by navigating the victim's browser to the URL.  Every other CSRF
    vector is already closed by construction (415 on non-JSON request bodies, no
    CORS headers on JSON routes, parameterised SQL), which left the mutating GET
    as the only residual — previously guarded by nothing but a convention the
    docs teach.  It was briefly a linter WARNING, but the linter does not run
    during `--check`/build, so a plain build never saw it.

    Forbidden closure: `dbWrite`, `queueWrite`, `pubsub`, `emailCap`.  Reads are
    fine.  Telemetry is ambient and out of scope.  `cacheCap` is out of scope
    because it has no read/write split, so banning it would ban cache READS in a
    GET too. *)

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

let check_subcmd =
  if Filename.basename compiler = "main.exe" then "--check" else "check"

let failf fmt = Printf.ksprintf failwith fmt

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n
  in (code, out)

(* Each program is written under its module's kebab file name (the compiler
   resolves imports by file name), in a fresh directory so multi-file cases can
   put a library beside the entry module. *)
let kebab_of_module content =
  let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
  ignore (Str.search_forward re content 0);
  let mname = Str.matched_group 2 content in
  let buf = Buffer.create (String.length mname + 4) in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
    else Buffer.add_char buf c) mname;
  Buffer.contents buf ^ ".tesl"

let write_file path content =
  let oc = open_out path in output_string oc content; close_out oc

let with_project ?(aux = []) main_src f =
  let dir = Filename.temp_dir "tesl-sec005" "" in
  let written = ref [] in
  let put src =
    let p = Filename.concat dir (kebab_of_module src) in
    write_file p src; written := p :: !written; p
  in
  List.iter (fun s -> ignore (put s)) aux;
  let main_path = put main_src in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) !written;
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f main_path)

let expect_sec005 ?(who = "expect_sec005") ?aux ?(mentions = []) src =
  with_project ?aux src (fun path ->
    let code, out = run_compiler [check_subcmd; path] in
    if code = 0 then
      failf "%s: expected SEC005, but the program compiled cleanly.\nOutput:\n%s" who out;
    (try ignore (Str.search_forward (Str.regexp_string "SEC005") out 0)
     with Not_found ->
       failf "%s: expected a SEC005 diagnostic, got:\n%s" who out);
    List.iter (fun needle ->
      try ignore (Str.search_forward (Str.regexp_string needle) out 0)
      with Not_found ->
        failf "%s: SEC005 fired but the message never mentions %S.\nOutput:\n%s"
          who needle out) mentions)

let expect_clean ?(who = "expect_clean") ?aux src =
  with_project ?aux src (fun path ->
    let code, out = run_compiler [check_subcmd; path] in
    if code <> 0 then
      failf "%s: expected a clean compile, got (exit %d):\n%s" who code out)

(* Assert the program compiles cleanly OR fails for some reason that is NOT
   SEC005.  Used where the point is only "this rule does not fire". *)
let expect_no_sec005 ?(who = "expect_no_sec005") ?aux src =
  with_project ?aux src (fun path ->
    let _code, out = run_compiler [check_subcmd; path] in
    try
      ignore (Str.search_forward (Str.regexp_string "SEC005") out 0);
      failf "%s: SEC005 fired but should not have.\nOutput:\n%s" who out
    with Not_found -> ())

(* ── Program templates ────────────────────────────────────────────────────── *)

(* One GET/POST route whose handler optionally performs a DB write. *)
let db_prog ?(module_name = "Sec005Db") ~method_kw ~writes () =
  Printf.sprintf
    {|module %s exposing []
import Tesl.Prelude exposing [String]
%s
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

record Doc {
  id: String
}

handler %s act() -> String requires [%s] =
%s

api ActApi {
  %s "/act" -> String
}

server ActServer for ActApi {
  act
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

main() -> App requires [%s] =
  App {
    database: ProbeDb
    api: ActServer
    port: 8086
  }
|}
    module_name
    (if writes then "import Tesl.DB exposing [dbWrite]" else "")
    method_kw
    (if writes then "dbWrite" else "")
    (if writes then "  let saved = insert Doc { id: \"x\" }\n  \"ok\"" else "  \"ok\"")
    method_kw
    (if writes then "dbWrite" else "")

(* ── dbWrite: the canonical case, plus the POST control ───────────────────── *)

let test_get_dbwrite_rejected () =
  expect_sec005 ~who:"GET+dbWrite"
    ~mentions:[ "dbWrite"; "act"; "/act" ]
    (db_prog ~method_kw:"get" ~writes:true ())

let test_post_dbwrite_accepted () =
  expect_clean ~who:"POST+dbWrite"
    (db_prog ~module_name:"Sec005Post" ~method_kw:"post" ~writes:true ())

let test_get_readonly_accepted () =
  expect_clean ~who:"GET read-only"
    (db_prog ~module_name:"Sec005Read" ~method_kw:"get" ~writes:false ())

(* A GET that only READS the database is the common case and must stay silent. *)
let test_get_dbread_accepted () =
  expect_clean ~who:"GET+dbRead" {|module Sec005DbRead exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.DB exposing [dbRead]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

record Doc {
  id: String
}

handler get act() -> List Doc requires [dbRead] =
  select Doc

api ActApi {
  get "/act" -> List Doc
}

server ActServer for ActApi {
  act
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

main() -> App requires [dbRead] =
  App {
    database: ProbeDb
    api: ActServer
    port: 8086
  }
|}

(* ── emailCap: added to the forbidden set 2026-08-03 ──────────────────────── *)

let email_prog ~method_kw =
  Printf.sprintf
    {|module Sec005Email exposing []
import Tesl.Prelude exposing [String, Unit]
import Tesl.Database exposing [Database, Memory]
import Tesl.Email exposing [Email, SmtpConfig, emailCap, EmailBody(..)]
import Tesl.App exposing [App]

database ProbeDb = Database {
  schema: "sec005"
  entities: []
  backend: Memory
}

email ProbeMail = Email {
  database: ProbeDb
  smtp: SmtpConfig {
    host: "127.0.0.1"
    port: 1025
    username: ""
    password: ""
    tls: false
  }
}

handler %s act() -> String requires [emailCap] =
  let _ = Email.send ProbeMail {
    to: "to@example.com"
    subject: "hi"
    body: TextBody "body"
  }
  "ok"

api ActApi {
  %s "/act" -> String
}

server ActServer for ActApi {
  act
}

main() -> App requires [emailCap] =
  App {
    database: ProbeDb
    email: [ProbeMail]
    api: ActServer
    port: 8086
  }
|}
    method_kw
    method_kw

let test_get_email_rejected () =
  expect_sec005 ~who:"GET+emailCap" ~mentions:[ "emailCap" ] (email_prog ~method_kw:"get")

let test_post_email_accepted () =
  expect_clean ~who:"POST+emailCap" (email_prog ~method_kw:"post")

(* ── A user capability whose `implies` chain reaches a forbidden one ───────── *)

(* The closure is what matters, not the spelling: `capability audit implies
   dbWrite` in a GET handler must fire exactly as a bare `dbWrite` does. *)
let test_get_implied_write_rejected () =
  expect_sec005 ~who:"GET+implies dbWrite" ~mentions:[ "dbWrite" ]
    {|module Sec005Implies exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

capability audit implies dbWrite

record Doc {
  id: String
}

handler get act() -> String requires [audit] =
  let saved = insert Doc { id: "x" }
  "ok"

api ActApi {
  get "/act" -> String
}

server ActServer for ActApi {
  act
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

main() -> App requires [audit] =
  App {
    database: ProbeDb
    api: ActServer
    port: 8086
  }
|}

(* ── Endpoint pairing is POSITIONAL, and that is the runtime truth ────────── *)

(* There is no surface syntax for naming an api endpoint: the parser mints
   `endpoint_N` for every one, and the emitter re-attaches the BINDING KEY as the
   name of the endpoint at that INDEX.  So binding order — not the key — decides
   which handler serves which method.  Here `mutate` is bound FIRST while the api
   declares the POST first, so `mutate` genuinely serves POST /create and this
   program is safe, even though its binding key reads `endpoint_1`.

   This is the false-POSITIVE guard for the pairing rule: pairing by key instead
   of by position would reject this safe program.  Verified against the emitted
   Racket, which wires [endpoint_1 mutate] onto the POST route. *)
let test_binding_order_is_authoritative () =
  expect_clean ~who:"out-of-order binding keys, mutation on the POST"
    {|module Sec005Order exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

record Doc {
  id: String
}

handler get readOnly() -> String requires [] =
  "ok"

handler post mutate() -> String requires [dbWrite] =
  let saved = insert Doc { id: "x" }
  "ok"

api ActApi {
  post "/create" -> String
  get "/read" -> String
}

server ActServer for ActApi {
  mutate
  readOnly
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

main() -> App requires [dbWrite] =
  App {
    database: ProbeDb
    api: ActServer
    port: 8086
  }
|}

(* The mirror: swap the binding ORDER so the mutating handler lands on the GET.
   Same keys, same handlers, same api — only the order changed, and now it must
   be rejected.  Together with the test above this pins the pairing to position
   in both directions. *)
let test_binding_order_moves_mutation_to_get () =
  expect_sec005 ~who:"binding order puts the mutation on the GET"
    ~mentions:[ "dbWrite"; "mutate"; "/read" ]
    {|module Sec005OrderBad exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

record Doc {
  id: String
}

handler post readOnly() -> String requires [] =
  "ok"

handler get mutate() -> String requires [dbWrite] =
  let saved = insert Doc { id: "x" }
  "ok"

api ActApi {
  post "/create" -> String
  get "/read" -> String
}

server ActServer for ActApi {
  readOnly
  mutate
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

main() -> App requires [dbWrite] =
  App {
    database: ProbeDb
    api: ActServer
    port: 8086
  }
|}

(* An SSE endpoint must not shift the positional pairing: the api below has an
   SSE route BEFORE the GET, so a pairing that forgot to filter SSE first would
   line the GET up against the wrong binding. *)
let test_sse_does_not_shift_pairing () =
  expect_sec005 ~who:"SSE route does not shift the GET pairing"
    ~mentions:[ "dbWrite"; "mutate" ]
    {|module Sec005Sse exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
import Tesl.Queue exposing [pubsub]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

record Doc {
  id: String
}

handler post readOnly() -> String requires [] =
  "ok"

handler get mutate() -> String requires [dbWrite] =
  let saved = insert Doc { id: "x" }
  "ok"

api ActApi {
  sse "/events"
    subscribes ["news"]
  post "/create" -> String
  get "/read" -> String
}

server ActServer for ActApi {
  readOnly
  mutate
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

main() -> App requires [dbWrite, pubsub] =
  App {
    database: ProbeDb
    api: ActServer
    port: 8086
  }
|}

(* ── Transitive: the write is one call away, not in the handler body ──────── *)

let test_get_transitive_write_rejected () =
  expect_sec005 ~who:"GET+transitive write" ~mentions:[ "dbWrite" ]
    {|module Sec005Trans exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

record Doc {
  id: String
}

fn doWrite() -> String requires [dbWrite] =
  let saved = insert Doc { id: "x" }
  "ok"

handler get act() -> String requires [dbWrite] =
  doWrite()

api ActApi {
  get "/act" -> String
}

server ActServer for ActApi {
  act
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

main() -> App requires [dbWrite] =
  App {
    database: ProbeDb
    api: ActServer
    port: 8086
  }
|}

(* ── Cross-module: an IMPORTED handler must not launder the rule ──────────── *)

(* No handler body is available for an imported function, so the rule falls back
   to the imported capability row ([load_imported_func_caps] — the union of the
   declared row and body-derived caps).  Skipping instead would be the fail-open
   direction this rule exists to remove. *)
let test_imported_handler_rejected () =
  let lib =
    {|module Sec005Lib exposing [libMutate]
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]

record Doc {
  id: String
}

handler get libMutate() -> String requires [dbWrite] =
  let saved = insert Doc { id: "x" }
  "ok"
|}
  in
  expect_sec005 ~who:"GET+imported mutating handler" ~aux:[ lib ] ~mentions:[ "dbWrite" ]
    {|module Sec005Import exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]
import Sec005Lib exposing [libMutate]

record Doc {
  id: String
}

api ActApi {
  get "/act" -> String
}

server ActServer for ActApi {
  libMutate
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

main() -> App requires [dbWrite] =
  App {
    database: ProbeDb
    api: ActServer
    port: 8086
  }
|}

(* ── Out of scope by design ──────────────────────────────────────────────── *)

(* Telemetry is ambient and ungated, and is not a state change a CSRF attacker
   cares about — a GET that logs must stay clean. *)
let test_get_telemetry_accepted () =
  expect_no_sec005 ~who:"GET+telemetry" {|module Sec005Telemetry exposing []
import Tesl.Prelude exposing [String]
import Tesl.Telemetry exposing [telemetry]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

record Doc {
  id: String
}

handler get act() -> String requires [] =
  telemetry "act.viewed" { n = 1 }
  "ok"

api ActApi {
  get "/act" -> String
}

server ActServer for ActApi {
  act
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

main() -> App requires [] =
  App {
    database: ProbeDb
    api: ActServer
    port: 8086
  }
|}

(* ── The code itself stays documented ────────────────────────────────────── *)

let test_sec005_documented () =
  match Error_codes.lookup "SEC005" with
  | None -> failf "SEC005 vanished from the error-code registry"
  | Some e ->
    check bool "SEC005 deep-links into the manual" true (e.manual <> None);
    let mentions needle =
      let n = String.length needle and h = String.length e.explanation in
      let rec at i = i + n <= h && (String.sub e.explanation i n = needle || at (i + 1)) in
      at 0
    in
    (* The prose must name the whole forbidden closure, or `tesl explain SEC005`
       under-describes the rule the compiler actually enforces. *)
    List.iter (fun cap ->
      check bool (Printf.sprintf "explanation names %s" cap) true (mentions cap))
      [ "dbWrite"; "queueWrite"; "pubsub"; "emailCap" ];
    (* And it must say why cache is NOT in it, so the omission reads as a
       decision rather than an oversight. *)
    check bool "explanation explains the cache exclusion" true (mentions "cacheCap")

(* The forbidden set is the contract; pin it so widening or narrowing it is a
   deliberate edit that updates this list too. *)
let test_forbidden_set_pinned () =
  check (list string) "forbidden capability closure"
    [ "dbWrite"; "emailCap"; "pubsub"; "queueWrite" ]
    (List.sort compare Validation_capabilities.get_forbidden_caps)

(* ── Declaration-driven enforcement ────────────────────────────────────────
   SEC005 used to obtain a handler's method by pairing server bindings to api
   endpoints POSITIONALLY.  Now that a `handler` declares its own method, the
   rule reads the handler's text.  Two holes that closed with it, both pinned
   below because both were silently unchecked before:

   - a mutating GET handler bound to NO server was invisible: there was no
     pairing to infer a method from, so the rule never ran on it;
   - [server_endpoint_bindings] returns [] when the handler count and endpoint
     count disagree, so a malformed server block switched the rule OFF entirely.
     A count mismatch is its own error, but it must not also disable a security
     check — that is the fail-open direction this rule exists to remove. *)

let unbound_prog ~method_kw = Printf.sprintf {|module Sec005Unbound exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
import Tesl.Database exposing [Database, Memory]

record Doc {
  id: String
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

handler %s leaky() -> String requires [dbWrite] =
  let saved = insert Doc { id: "x" }
  "ok"
|} method_kw

let test_unbound_get_handler_rejected () =
  expect_sec005 ~who:"unbound mutating GET handler"
    ~mentions:[ "dbWrite"; "leaky" ]
    (unbound_prog ~method_kw:"get")

let test_unbound_post_handler_accepted () =
  (* Control: the method is what decides, not the mere presence of a write. *)
  expect_no_sec005 ~who:"unbound mutating POST handler"
    (unbound_prog ~method_kw:"post")

let test_count_mismatch_still_checked () =
  (* One handler listed for two endpoints.  That is itself an error, and the
     program must ALSO still be told its GET mutates. *)
  expect_sec005 ~who:"malformed server block"
    ~mentions:[ "dbWrite"; "leaky" ]
    {|module Sec005Mismatch exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbWrite]
import Tesl.Database exposing [Database, Memory]

record Doc {
  id: String
}

database ProbeDb = Database {
  entities: [Doc]
  backend: Memory
}

handler get leaky() -> String requires [dbWrite] =
  let saved = insert Doc { id: "x" }
  "ok"

handler get other() -> String requires [] =
  "ok"

api ActApi {
  get "/leaky" -> String
  get "/other" -> String
}

server ActServer for ActApi {
  leaky
}
|}

let () =
  run "SEC005-GetHandlersDoNotMutate" [
    "db-write", [
      test_case "GET reaching dbWrite is rejected" `Quick test_get_dbwrite_rejected;
      test_case "the same handler under POST compiles" `Quick test_post_dbwrite_accepted;
      test_case "read-only GET compiles" `Quick test_get_readonly_accepted;
      test_case "GET performing dbRead compiles" `Quick test_get_dbread_accepted;
    ];
    "email", [
      test_case "GET reaching emailCap is rejected" `Quick test_get_email_rejected;
      test_case "the same send under POST compiles" `Quick test_post_email_accepted;
    ];
    "closure", [
      test_case "user capability implying dbWrite is rejected" `Quick test_get_implied_write_rejected;
      test_case "a write one call away is rejected" `Quick test_get_transitive_write_rejected;
      test_case "imported mutating handler is rejected" `Quick test_imported_handler_rejected;
    ];
    "endpoint-pairing", [
      test_case "binding order is authoritative (safe program accepted)" `Quick test_binding_order_is_authoritative;
      test_case "binding order can put the mutation on the GET (rejected)" `Quick test_binding_order_moves_mutation_to_get;
      test_case "an SSE route does not shift the pairing" `Quick test_sse_does_not_shift_pairing;
    ];
    "declaration-driven (not pairing-inferred)", [
      test_case "a mutating GET handler bound to no server is still rejected" `Quick
        test_unbound_get_handler_rejected;
      test_case "a POST handler bound to no server stays clean" `Quick
        test_unbound_post_handler_accepted;
      test_case "a malformed server block does not switch the rule off" `Quick
        test_count_mismatch_still_checked;
    ];
    "out-of-scope", [
      test_case "telemetry in a GET is not a mutation" `Quick test_get_telemetry_accepted;
    ];
    "contract", [
      test_case "SEC005 stays documented and names its closure" `Quick test_sec005_documented;
      test_case "forbidden capability set is pinned" `Quick test_forbidden_set_pinned;
    ];
  ]
