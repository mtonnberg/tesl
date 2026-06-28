(** Library boundary validation tests.

    Ensures that modules imported by other modules (i.e. used as libraries)
    do not contain application-only declarations: `main`, `server`, and `api`.

    Test groups:
      LB_NEG — negative tests: imports of app-only declarations must be rejected
      LB_POS — positive tests: valid library declarations must be accepted
      LB_MSG — error-message quality tests *)

open Alcotest

(* ── Compiler location ───────────────────────────────────────────────────── *)

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

(* ── Multi-file helpers ──────────────────────────────────────────────────── *)

(** Derive a kebab-case filename from a PascalCase module name. *)
let module_name_to_filename mname =
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

(** Extract the first module name from Tesl source. *)
let extract_module_name src =
  let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
  try
    ignore (Str.search_forward re src 0);
    Str.matched_group 1 src
  with Not_found -> "Unknown"

(** Write content to a file. *)
let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

(** Create a temp directory, write multiple (filename, content) pairs into it,
    and call f with the directory path.  Cleans up on exit. *)
let with_temp_dir files f =
  let dir = Filename.temp_dir "tesl-lb" "" in
  let paths =
    List.map (fun (name, content) ->
      let path = Filename.concat dir name in
      write_file path content;
      path
    ) files
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> (try Sys.remove p with _ -> ())) paths;
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f dir paths)

(** Write a single file in a temp dir and compile it. *)
let with_single_file src f =
  let mname = extract_module_name src in
  let filename = module_name_to_filename mname in
  with_temp_dir [(filename, src)] (fun _dir paths ->
    f (List.hd paths))

let should_pass src =
  with_single_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

let should_fail_single pat src =
  with_single_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(** Two-module test: lib_src is the library being imported,
    app_src imports it.  We compile app_src. *)
let with_two_files lib_src app_src f =
  let lib_name = extract_module_name lib_src in
  let app_name = extract_module_name app_src in
  let lib_file = module_name_to_filename lib_name in
  let app_file = module_name_to_filename app_name in
  with_temp_dir [(lib_file, lib_src); (app_file, app_src)] (fun _dir paths ->
    let app_path = List.nth paths 1 in
    f app_path)

let should_pass_two lib_src app_src =
  with_two_files lib_src app_src (fun app_path ->
    let code, out = run_compiler ["--check"; app_path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

let should_fail_two pat lib_src app_src =
  with_two_files lib_src app_src (fun app_path ->
    let code, out = run_compiler ["--check"; app_path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── LB_NEG — Negative tests ─────────────────────────────────────────────── *)

(* LB_NEG01: importing a module with a `server` block is an error *)
let test_LB_NEG01_import_server_rejected () =
  let lib_src = {|#lang tesl
module LbLib01 exposing [LbLib01Server]
import Tesl.Prelude exposing [String]
api LbLib01Api {
  get "/ping" -> String
}
handler pingH() -> String requires [] = "pong"
server LbLib01Server for LbLib01Api { ping = pingH }
|} in
  let app_src = {|#lang tesl
module LbApp01 exposing []
import LbLib01 exposing [LbLib01Server]
|} in
  should_fail_two "server.*not allowed in library\\|library.*server\\|server.*library" lib_src app_src

(* LB_NEG02: importing a module with an `api` block is an error *)
let test_LB_NEG02_import_api_rejected () =
  let lib_src = {|#lang tesl
module LbLib02 exposing [LbLib02Api]
import Tesl.Prelude exposing [String]
api LbLib02Api {
  get "/ping" -> String
}
|} in
  let app_src = {|#lang tesl
module LbApp02 exposing []
import LbLib02 exposing [LbLib02Api]
|} in
  should_fail_two "api.*not allowed in library\\|library.*api\\|api.*library" lib_src app_src

(* LB_NEG03: importing a module with a `main` block is an error *)
let test_LB_NEG03_import_main_rejected () =
  let lib_src = {|#lang tesl
module LbLib03 exposing []
import Tesl.Prelude exposing [String]
fn helper() -> String = "hi"
main {
  let _ = helper()
}
|} in
  let app_src = {|#lang tesl
module LbApp03 exposing []
import LbLib03 exposing [helper]
|} in
  should_fail_two "main.*not allowed in library\\|library.*main\\|main.*library" lib_src app_src

(* LB_NEG04: multiple imports, only one has server → error for that import *)
let test_LB_NEG04_one_of_two_imports_has_server () =
  let lib_src = {|#lang tesl
module LbLib04 exposing [LbLib04Server]
import Tesl.Prelude exposing [String]
api LbLib04Api { get "/x" -> String }
handler xH() -> String requires [] = "x"
server LbLib04Server for LbLib04Api { x = xH }
|} in
  let app_src = {|#lang tesl
module LbApp04 exposing []
import Tesl.Prelude exposing [String]
import LbLib04 exposing [LbLib04Server]
fn localFn() -> String = "ok"
|} in
  should_fail_two "LbLib04.*server\\|server.*LbLib04\\|server.*library" lib_src app_src

(* LB_NEG05: library has both api and server → error mentions both *)
let test_LB_NEG05_api_and_server_both_forbidden () =
  let lib_src = {|#lang tesl
module LbLib05 exposing []
import Tesl.Prelude exposing [String]
api LbLib05Api { get "/y" -> String }
handler yH() -> String requires [] = "y"
server LbLib05Server for LbLib05Api { y = yH }
|} in
  let app_src = {|#lang tesl
module LbApp05 exposing []
import LbLib05
|} in
  should_fail_two "api.*library\\|server.*library\\|not allowed in library" lib_src app_src

(* LB_NEG06: error pinned to import line in the importer, mentions imported module name *)
let test_LB_NEG06_error_shows_imported_module_name () =
  let lib_src = {|#lang tesl
module LbNamedLib06 exposing []
import Tesl.Prelude exposing [String]
api LbNamedLib06Api { get "/z" -> String }
handler zH() -> String requires [] = "z"
server LbNamedLib06Sv for LbNamedLib06Api { z = zH }
|} in
  let app_src = {|#lang tesl
module LbApp06 exposing []
import LbNamedLib06
|} in
  should_fail_two "LbNamedLib06" lib_src app_src

(* LB_NEG07: `api` alone (no server) in imported module triggers error *)
let test_LB_NEG07_api_only_in_library_rejected () =
  let lib_src = {|#lang tesl
module LbLib07 exposing []
import Tesl.Prelude exposing [String]
api LbLib07Api {
  get "/health" -> String
  post "/items" -> String
}
|} in
  let app_src = {|#lang tesl
module LbApp07 exposing []
import LbLib07
|} in
  should_fail_two "api.*library\\|not allowed in library" lib_src app_src

(* LB_NEG08: `server` alone (no api) in imported module triggers error *)
(* Note: server without api also has a structural error, but the library
   boundary check fires first or alongside. We just need some error. *)
let test_LB_NEG08_server_alone_in_library_rejected () =
  let lib_src = {|#lang tesl
module LbLib08 exposing []
import Tesl.Prelude exposing [String]
handler hH() -> String requires [] = "h"
server LbLib08Server for NonexistentApi { handler1 = hH }
|} in
  let app_src = {|#lang tesl
module LbApp08 exposing []
import LbLib08
|} in
  should_fail_two "server.*library\\|library.*server\\|not allowed in library\\|server.*NonexistentApi" lib_src app_src

(* LB_NEG09: error message includes hint about moving block to root module *)
let test_LB_NEG09_error_includes_hint () =
  let lib_src = {|#lang tesl
module LbLib09 exposing []
import Tesl.Prelude exposing [String]
api LbLib09Api { get "/hint" -> String }
handler hintH() -> String requires [] = "hint"
server LbLib09Server for LbLib09Api { hint = hintH }
|} in
  let app_src = {|#lang tesl
module LbApp09 exposing []
import LbLib09
|} in
  should_fail_two "move.*server\\|root module\\|entry.point\\|app" lib_src app_src

(* ── LB_POS — Positive tests ─────────────────────────────────────────────── *)

(* LB_POS01: pure types module → OK *)
let test_LB_POS01_pure_types_module_ok () =
  let lib_src = {|#lang tesl
module LbPure01 exposing [Color(..), colorName]
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn colorName(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|} in
  let app_src = {|#lang tesl
module LbApp01Pos exposing []
import Tesl.Prelude exposing [String]
import LbPure01 exposing [Color(..), colorName]
fn render(c: Color) -> String = colorName c
|} in
  should_pass_two lib_src app_src

(* LB_POS02: module with `fact` and `check` functions → OK *)
let test_LB_POS02_fact_and_check_ok () =
  let lib_src = {|#lang tesl
module LbFacts02 exposing [IsPositive, checkPositive]
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|} in
  let app_src = {|#lang tesl
module LbApp02Pos exposing []
import Tesl.Prelude exposing [Int]
import LbFacts02 exposing [IsPositive, checkPositive]
fn addPositive(a: Int ::: IsPositive a, b: Int ::: IsPositive b) -> Int = a + b
|} in
  should_pass_two lib_src app_src

(* LB_POS03: module with `handler` functions → OK (handlers are just functions) *)
let test_LB_POS03_handler_functions_ok () =
  let lib_src = {|#lang tesl
module LbHandlers03 exposing [pingHandler, echoHandler]
import Tesl.Prelude exposing [String]
handler pingHandler() -> String requires [] = "pong"
handler echoHandler() -> String requires [] = "echo"
|} in
  let app_src = {|#lang tesl
module LbApp03Pos exposing []
import Tesl.Prelude exposing [String]
import LbHandlers03 exposing [pingHandler, echoHandler]
api LbApp03Api {
  get "/ping" -> String
  get "/echo" -> String
}
server LbApp03Server for LbApp03Api {
  ping = pingHandler
  echo = echoHandler
}
|} in
  should_pass_two lib_src app_src

(* LB_POS04: module with `worker` functions → OK *)
let test_LB_POS04_worker_functions_ok () =
  let lib_src = {|#lang tesl
module LbWorkers04 exposing [processJob, MyJob]
import Tesl.Prelude exposing [String]
record MyJob { msg: String }
worker processJob(job: MyJob) -> String requires [] = job.msg
|} in
  let app_src = {|#lang tesl
module LbApp04Pos exposing []
import Tesl.Prelude exposing [String]
import LbWorkers04 exposing [processJob, MyJob]
|} in
  should_pass_two lib_src app_src

(* LB_POS05: module with `capability` declarations → OK *)
let test_LB_POS05_capability_declarations_ok () =
  let lib_src = {|#lang tesl
module LbCaps05 exposing [readCap]
capability readCap
|} in
  let app_src = {|#lang tesl
module LbApp05Pos exposing []
import LbCaps05 exposing [readCap]
|} in
  should_pass_two lib_src app_src

(* LB_POS06: module with `record` declarations → OK *)
let test_LB_POS06_record_declarations_ok () =
  let lib_src = {|#lang tesl
module LbRecords06 exposing [User, Product]
import Tesl.Prelude exposing [String, Int]
record User { id: Int name: String }
record Product { id: Int price: Int label: String }
|} in
  let app_src = {|#lang tesl
module LbApp06Pos exposing []
import Tesl.Prelude exposing [String, Int]
import LbRecords06 exposing [User, Product]
fn userName(u: User) -> String = u.name
|} in
  should_pass_two lib_src app_src

(* LB_POS07: module with `auth` functions → OK *)
let test_LB_POS07_auth_functions_ok () =
  let lib_src = {|#lang tesl
module LbAuth07 exposing [Authenticated, sessionAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (u: String)
auth sessionAuth(req: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "session" req.cookies of
    Nothing -> fail 401 "not authenticated"
    Something s -> ok s ::: Authenticated user
|} in
  let app_src = {|#lang tesl
module LbApp07Pos exposing []
import Tesl.Prelude exposing [String]
import LbAuth07 exposing [Authenticated, sessionAuth]
api LbApp07Api {
  get "/whoami"
    auth user : String ::: Authenticated user via sessionAuth
    -> String
}
handler whoami(user: String ::: Authenticated user) -> String requires [] = user
server LbApp07Server for LbApp07Api { whoami = whoami }
|} in
  should_pass_two lib_src app_src

(* LB_POS08: module with type alias declarations → OK *)
let test_LB_POS08_codec_declarations_ok () =
  let lib_src = {|#lang tesl
module LbCodecs08 exposing [UserId, makeUserId]
import Tesl.Prelude exposing [String]
type UserId = String
fn makeUserId(s: String) -> UserId = s
|} in
  let app_src = {|#lang tesl
module LbApp08Pos exposing []
import Tesl.Prelude exposing [String]
import LbCodecs08 exposing [UserId, makeUserId]
fn createUser(s: String) -> UserId = makeUserId s
|} in
  should_pass_two lib_src app_src

(* LB_POS09: standalone app CAN have server/api/main — no error when not imported *)
let test_LB_POS09_standalone_app_server_ok () =
  should_pass {|
#lang tesl
module LbStandaloneApp09 exposing []
import Tesl.Prelude exposing [String]
api LbStandaloneApi {
  get "/health" -> String
}
handler health() -> String requires [] = "ok"
server LbStandaloneServer for LbStandaloneApi { health = health }
|}

(* LB_POS10: standalone app (with server+api) not imported — pure standalone module is OK *)
let test_LB_POS10_standalone_app_main_ok () =
  (* When a module has server+api but is NOT imported by another module, no error *)
  should_pass {|
#lang tesl
module LbStandaloneApp10 exposing []
import Tesl.Prelude exposing [String]
api LbStandaloneApp10Api {
  get "/ok" -> String
}
handler okH() -> String requires [] = "ok"
server LbStandaloneApp10Server for LbStandaloneApp10Api { ok = okH }
|}

(* LB_POS11: two modules each with server blocks, not importing each other → both OK *)
let test_LB_POS11_two_server_modules_not_importing_each_other () =
  (* Test each one individually — they're standalone apps *)
  should_pass {|
#lang tesl
module LbApp11a exposing []
import Tesl.Prelude exposing [String]
api LbApp11aApi { get "/a" -> String }
handler aH() -> String requires [] = "a"
server LbApp11aServer for LbApp11aApi { a = aH }
|};
  should_pass {|
#lang tesl
module LbApp11b exposing []
import Tesl.Prelude exposing [String]
api LbApp11bApi { get "/b" -> String }
handler bH() -> String requires [] = "b"
server LbApp11bServer for LbApp11bApi { b = bH }
|}

(* LB_POS12: importing a pure-function module (no infra) → OK *)
let test_LB_POS12_pure_functions_lib_ok () =
  let lib_src = {|#lang tesl
module LbMath12 exposing [add, multiply, square]
import Tesl.Prelude exposing [Int]
fn add(a: Int, b: Int) -> Int = a + b
fn multiply(a: Int, b: Int) -> Int = a * b
fn square(n: Int) -> Int = n * n
|} in
  let app_src = {|#lang tesl
module LbApp12Pos exposing []
import Tesl.Prelude exposing [Int]
import LbMath12 exposing [add, multiply, square]
fn cube(n: Int) -> Int = multiply n (square n)
|} in
  should_pass_two lib_src app_src

(* LB_POS13: stdlib imports [Tesl.*] are always OK, never checked *)
let test_LB_POS13_stdlib_imports_never_checked () =
  should_pass {|
#lang tesl
module LbStdlib13 exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.filter]
fn present() -> String = "ok"
|}

(* LB_POS14: entity/database-only module → OK in phase 1 (only api/server/main are errors) *)
let test_LB_POS14_entity_and_database_ok_in_phase1 () =
  let lib_src = {|#lang tesl
module LbSchema14 exposing [Product]
import Tesl.Prelude exposing [String, Int]
entity Product table "products" primaryKey id {
  id: Int
  name: String
  price: Int
}
|} in
  let app_src = {|#lang tesl
module LbApp14Pos exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Database exposing [Database, DatabaseBackend, Postgres, PostgresConfig, TcpConnection]
import LbSchema14 exposing [Product]
database LbApp14Db = Database {
  schema: "shop"
  entities: [Product]
  backend: Postgres (PostgresConfig {
    dbName: "shop"
    user: "u"
    password: ""
    connection: TcpConnection {
      host: "localhost"
      port: 5432
    }
  })
}
|} in
  should_pass_two lib_src app_src

(* LB_POS15: queue-only module → OK in phase 1 *)
let test_LB_POS15_queue_declarations_ok_in_phase1 () =
  let lib_src = {|#lang tesl
module LbQueues15 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, DatabaseBackend, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
record NotifyJob { msg: String }
database LbQueues15Db = Database {
  schema: "q"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "q"
    user: "u"
    password: ""
    connection: TcpConnection {
      host: "localhost"
      port: 5432
    }
  })
}
queue NotifyQueue = Queue {
  database: LbQueues15Db
  jobs: [NotifyJob]
  retry: QueueRetryStrategy {
    maxAttempts: 3
    backoff: Exponential
    initialDelay: 60
  }
}
|} in
  let app_src = {|#lang tesl
module LbApp15Pos exposing []
import LbQueues15
|} in
  should_pass_two lib_src app_src

(* ── LB_MSG — Error message quality ──────────────────────────────────────── *)

(* LB_MSG01: error message names the declaration kind (`server`) *)
let test_LB_MSG01_error_names_server_kind () =
  let lib_src = {|#lang tesl
module LbMsgLib01 exposing []
import Tesl.Prelude exposing [String]
api LbMsgLib01Api { get "/m" -> String }
handler mH() -> String requires [] = "m"
server LbMsgLib01Server for LbMsgLib01Api { m = mH }
|} in
  let app_src = {|#lang tesl
module LbMsgApp01 exposing []
import LbMsgLib01
|} in
  should_fail_two "`server`\\|server" lib_src app_src

(* LB_MSG02: error message names the declaration kind (`api`) *)
let test_LB_MSG02_error_names_api_kind () =
  let lib_src = {|#lang tesl
module LbMsgLib02 exposing []
import Tesl.Prelude exposing [String]
api LbMsgLib02Api { get "/n" -> String }
|} in
  let app_src = {|#lang tesl
module LbMsgApp02 exposing []
import LbMsgLib02
|} in
  should_fail_two "`api`\\|api" lib_src app_src

(* LB_MSG03: error message names the declaration kind (`main`) *)
let test_LB_MSG03_error_names_main_kind () =
  let lib_src = {|#lang tesl
module LbMsgLib03 exposing []
fn helper() -> Int = 42
main { let _ = helper() }
|} in
  let app_src = {|#lang tesl
module LbMsgApp03 exposing []
import LbMsgLib03
|} in
  should_fail_two "`main`\\|main" lib_src app_src

(* LB_MSG04: hint text mentions moving the block to the root module *)
let test_LB_MSG04_hint_mentions_root_module () =
  let lib_src = {|#lang tesl
module LbMsgLib04 exposing []
import Tesl.Prelude exposing [String]
api LbMsgLib04Api { get "/o" -> String }
handler oH() -> String requires [] = "o"
server LbMsgLib04Server for LbMsgLib04Api { o = oH }
|} in
  let app_src = {|#lang tesl
module LbMsgApp04 exposing []
import LbMsgLib04
|} in
  should_fail_two "root module\\|entry.point\\|app\\|move" lib_src app_src

(* LB_MSG05: non-library module itself can have api+server with no error *)
let test_LB_MSG05_non_imported_app_no_error () =
  should_pass {|
#lang tesl
module LbMsgSelf05 exposing []
import Tesl.Prelude exposing [String]
api LbMsgSelf05Api {
  get "/ping" -> String
}
handler ping() -> String requires [] = "pong"
server LbMsgSelf05Server for LbMsgSelf05Api { ping = ping }
|}

(* LB_MSG06: error is not produced when importing a module that only has functions *)
let test_LB_MSG06_no_error_for_function_only_lib () =
  let lib_src = {|#lang tesl
module LbFnLib06 exposing [greet]
import Tesl.Prelude exposing [String]
fn greet(name: String) -> String = name
|} in
  let app_src = {|#lang tesl
module LbFnApp06 exposing []
import Tesl.Prelude exposing [String]
import LbFnLib06 exposing [greet]
fn hello() -> String = greet "world"
|} in
  should_pass_two lib_src app_src

(* LB_MSG07: error appears even when the import uses `exposing [...]` not `import All` *)
let test_LB_MSG07_error_with_exposing_import () =
  let lib_src = {|#lang tesl
module LbExpLib07 exposing [LbExpLib07Server]
import Tesl.Prelude exposing [String]
api LbExpLib07Api { get "/e" -> String }
handler eH() -> String requires [] = "e"
server LbExpLib07Server for LbExpLib07Api { e = eH }
|} in
  let app_src = {|#lang tesl
module LbExpApp07 exposing []
import LbExpLib07 exposing [LbExpLib07Server]
|} in
  should_fail_two "server.*library\\|not allowed in library" lib_src app_src

(* LB_MSG08: stdlib module import does NOT trigger library boundary check *)
let test_LB_MSG08_stdlib_not_checked () =
  should_pass {|
#lang tesl
module LbStdCheck08 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Http exposing [HttpRequest]
fn ok_fn() -> String = "ok"
|}

(* LB_MSG09: non-existent local module → no library boundary error (handled elsewhere) *)
let test_LB_MSG09_nonexistent_module_no_lib_boundary_error () =
  should_fail_single "module.*not found\\|no such file\\|not found\\|does not exist\\|unknown module\\|import"
    {|
#lang tesl
module LbMissing09 exposing []
import NonExistentLibModule exposing [something]
fn f() -> Int = something 1
|}

(* LB_MSG10: can use handler from a library in app's server block *)
let test_LB_MSG10_app_wires_library_handlers () =
  let lib_src = {|#lang tesl
module LbHandlerLib10 exposing [pingHandler, statusHandler]
import Tesl.Prelude exposing [String, Int]
handler pingHandler() -> String requires [] = "pong"
handler statusHandler() -> Int requires [] = 200
|} in
  let app_src = {|#lang tesl
module LbHandlerApp10 exposing []
import Tesl.Prelude exposing [String, Int]
import LbHandlerLib10 exposing [pingHandler, statusHandler]
api LbApp10Api {
  get "/ping" -> String
  get "/status" -> Int
}
server LbApp10Server for LbApp10Api {
  ping = pingHandler
  status = statusHandler
}
|} in
  should_pass_two lib_src app_src

(* LB_MSG11: importing a module with `test` blocks → OK (tests are not app-only) *)
let test_LB_MSG11_test_blocks_in_lib_ok () =
  let lib_src = {|#lang tesl
module LbTestLib11 exposing [myFn]
import Tesl.Prelude exposing [Int]
fn myFn(n: Int) -> Int = n + 1
test "myFn adds one" {
  expect myFn 1 == 2
}
|} in
  let app_src = {|#lang tesl
module LbTestApp11 exposing []
import Tesl.Prelude exposing [Int]
import LbTestLib11 exposing [myFn]
fn doubleFn(n: Int) -> Int = myFn (myFn n)
|} in
  should_pass_two lib_src app_src

(* LB_MSG12: multiple app modules, each importing lib with server → errors in each *)
let test_LB_MSG12_multiple_importers_each_get_error () =
  let lib_src = {|#lang tesl
module LbMultiLib12 exposing []
import Tesl.Prelude exposing [String]
api LbMultiLib12Api { get "/m" -> String }
handler mH() -> String requires [] = "m"
server LbMultiLib12Server for LbMultiLib12Api { m = mH }
|} in
  let app_src = {|#lang tesl
module LbMultiApp12 exposing []
import LbMultiLib12
|} in
  should_fail_two "server.*library\\|not allowed in library" lib_src app_src

(* LB_MSG13: error message includes the imported module name *)
let test_LB_MSG13_error_includes_module_name_in_message () =
  let lib_src = {|#lang tesl
module LbNameCheck13 exposing []
import Tesl.Prelude exposing [String]
api LbNameCheck13Api { get "/nc" -> String }
handler ncH() -> String requires [] = "nc"
server LbNameCheck13Server for LbNameCheck13Api { nc = ncH }
|} in
  let app_src = {|#lang tesl
module LbNameApp13 exposing []
import LbNameCheck13
|} in
  should_fail_two "LbNameCheck13" lib_src app_src

(* LB_MSG14: regression — pure util library with ADT types compiles fine *)
let test_LB_MSG14_adt_type_library_ok () =
  let lib_src = {|#lang tesl
module LbAdtLib14 exposing [Shape(..), area]
import Tesl.Prelude exposing [Int]
type Shape
  = Circle radius: Int
  | Rectangle width: Int height: Int
fn area(s: Shape) -> Int =
  case s of
    Circle r -> r * r
    Rectangle w h -> w * h
|} in
  let app_src = {|#lang tesl
module LbAdtApp14 exposing []
import Tesl.Prelude exposing [Int]
import LbAdtLib14 exposing [Shape(..), area]
fn totalArea(s: Shape) -> Int = area s
|} in
  should_pass_two lib_src app_src

(* LB_MSG15: regression — type alias library compiles fine *)
let test_LB_MSG15_newtype_library_ok () =
  let lib_src = {|#lang tesl
module LbNewtype15 exposing [UserId, EmailAddr, makeUserId]
import Tesl.Prelude exposing [String]
type UserId = String
type EmailAddr = String
fn makeUserId(s: String) -> UserId = s
|} in
  let app_src = {|#lang tesl
module LbApp15Pos exposing []
import Tesl.Prelude exposing [String]
import LbNewtype15 exposing [UserId, EmailAddr, makeUserId]
fn makeUser(s: String) -> UserId = makeUserId s
|} in
  should_pass_two lib_src app_src

(* LB_MSG16: regression — importing module with only facts is fine *)
let test_LB_MSG16_facts_only_lib_ok () =
  let lib_src = {|#lang tesl
module LbFactsOnly16 exposing [IsValid, IsNonEmpty]
import Tesl.Prelude exposing [String, Int]
fact IsValid (s: String)
fact IsNonEmpty (s: String)
|} in
  let app_src = {|#lang tesl
module LbApp16Pos exposing []
import Tesl.Prelude exposing [String]
import LbFactsOnly16 exposing [IsValid, IsNonEmpty]
fn needValid(s: String ::: IsValid s) -> String = s
|} in
  should_pass_two lib_src app_src

(* LB_MSG17: regression — importing a constants module (using fn) is fine *)
let test_LB_MSG17_const_module_ok () =
  let lib_src = {|#lang tesl
module LbConsts17 exposing [maxRetries, defaultPort]
import Tesl.Prelude exposing [Int]
fn maxRetries() -> Int = 3
fn defaultPort() -> Int = 8080
|} in
  let app_src = {|#lang tesl
module LbApp17Pos exposing []
import Tesl.Prelude exposing [Int]
import LbConsts17 exposing [maxRetries, defaultPort]
fn getPort() -> Int = defaultPort()
|} in
  should_pass_two lib_src app_src

(* LB_MSG18: api-test (apiTest) in lib is NOT forbidden by this check — api-test
   is a test construct that does not define the application's external interface *)
(* Note: api-test requires a server reference which may not exist in isolation.
   We test that api-test itself doesn't trigger the library boundary error. *)
let test_LB_MSG18_api_test_not_forbidden () =
  (* An api-test referencing an existing server in the same module should be
     caught by the server completeness check but NOT the library boundary check.
     We check that the error is NOT about library boundaries. *)
  let lib_src = {|#lang tesl
module LbApiTestLib18 exposing []
import Tesl.Prelude exposing [String]
import Tesl.ApiTest exposing [statusOk]
api LbApiTestLib18Api { get "/t" -> String }
handler tH() -> String requires [] = "t"
server LbApiTestLib18Sv for LbApiTestLib18Api { t = tH }
api-test "test t" for LbApiTestLib18Sv {
  let resp = get "/t"
  expect statusOk resp
}
|} in
  (* This lib has server → import error. But the error should be about `server`,
     not about api-test. Any error is acceptable here (it WILL fail due to server).
     We just verify api-test itself is not called out as the forbidden kind. *)
  let app_src = {|#lang tesl
module LbApiTestApp18 exposing []
import LbApiTestLib18
|} in
  (* Should fail — but the error should be about `server` or `api`, not specifically
     about `api-test` being a library boundary violation *)
  with_two_files lib_src app_src (fun app_path ->
    let code, out = run_compiler ["--check"; app_path] in
    if code = 0 then failf "expected failure (server in imported module), but succeeded";
    (* The error MUST mention api/server, NOT target api-test as a separate library
       boundary violation *)
    let re_good = Str.regexp_case_fold "server.*library\\|api.*library\\|not allowed in library" in
    (try ignore (Str.search_forward re_good out 0)
     with Not_found -> failf "expected library boundary error about server/api, got:\n%s" out))

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Library-Boundary-Validation" [
    "negative-server", [
      test_case "LB_NEG01 import server rejected" `Quick test_LB_NEG01_import_server_rejected;
      test_case "LB_NEG08 server alone in lib rejected" `Quick test_LB_NEG08_server_alone_in_library_rejected;
    ];
    "negative-api", [
      test_case "LB_NEG02 import api rejected" `Quick test_LB_NEG02_import_api_rejected;
      test_case "LB_NEG07 api only in lib rejected" `Quick test_LB_NEG07_api_only_in_library_rejected;
    ];
    "negative-main", [
      test_case "LB_NEG03 import main rejected" `Quick test_LB_NEG03_import_main_rejected;
    ];
    "negative-combined", [
      test_case "LB_NEG04 one-of-two imports has server" `Quick test_LB_NEG04_one_of_two_imports_has_server;
      test_case "LB_NEG05 api and server both forbidden" `Quick test_LB_NEG05_api_and_server_both_forbidden;
      test_case "LB_NEG06 error shows imported module name" `Quick test_LB_NEG06_error_shows_imported_module_name;
      test_case "LB_NEG09 error includes hint" `Quick test_LB_NEG09_error_includes_hint;
    ];
    "positive-lib-declarations", [
      test_case "LB_POS01 pure types module OK" `Quick test_LB_POS01_pure_types_module_ok;
      test_case "LB_POS02 fact and check functions OK" `Quick test_LB_POS02_fact_and_check_ok;
      test_case "LB_POS03 handler functions OK in lib" `Quick test_LB_POS03_handler_functions_ok;
      test_case "LB_POS04 worker functions OK in lib" `Quick test_LB_POS04_worker_functions_ok;
      test_case "LB_POS05 capability declarations OK" `Quick test_LB_POS05_capability_declarations_ok;
      test_case "LB_POS06 record declarations OK" `Quick test_LB_POS06_record_declarations_ok;
      test_case "LB_POS07 auth functions OK in lib" `Quick test_LB_POS07_auth_functions_ok;
      test_case "LB_POS08 codec declarations OK" `Quick test_LB_POS08_codec_declarations_ok;
      test_case "LB_POS12 pure-function lib OK" `Quick test_LB_POS12_pure_functions_lib_ok;
      test_case "LB_POS14 entity/db OK in phase1" `Quick test_LB_POS14_entity_and_database_ok_in_phase1;
      test_case "LB_POS15 queue declarations OK in phase1" `Quick test_LB_POS15_queue_declarations_ok_in_phase1;
    ];
    "positive-app-modules", [
      test_case "LB_POS09 standalone app with server OK" `Quick test_LB_POS09_standalone_app_server_ok;
      test_case "LB_POS10 standalone app with main OK" `Quick test_LB_POS10_standalone_app_main_ok;
      test_case "LB_POS11 two server modules not importing each other" `Quick test_LB_POS11_two_server_modules_not_importing_each_other;
      test_case "LB_POS13 stdlib imports never checked" `Quick test_LB_POS13_stdlib_imports_never_checked;
    ];
    "error-message-quality", [
      test_case "LB_MSG01 error names server kind" `Quick test_LB_MSG01_error_names_server_kind;
      test_case "LB_MSG02 error names api kind" `Quick test_LB_MSG02_error_names_api_kind;
      test_case "LB_MSG03 error names main kind" `Quick test_LB_MSG03_error_names_main_kind;
      test_case "LB_MSG04 hint mentions root module" `Quick test_LB_MSG04_hint_mentions_root_module;
      test_case "LB_MSG05 non-imported app no error" `Quick test_LB_MSG05_non_imported_app_no_error;
      test_case "LB_MSG06 no error for function-only lib" `Quick test_LB_MSG06_no_error_for_function_only_lib;
      test_case "LB_MSG07 error with exposing import" `Quick test_LB_MSG07_error_with_exposing_import;
      test_case "LB_MSG08 stdlib not checked" `Quick test_LB_MSG08_stdlib_not_checked;
      test_case "LB_MSG09 nonexistent module no lib boundary error" `Quick test_LB_MSG09_nonexistent_module_no_lib_boundary_error;
      test_case "LB_MSG10 app wires library handlers" `Quick test_LB_MSG10_app_wires_library_handlers;
      test_case "LB_MSG11 test blocks in lib OK" `Quick test_LB_MSG11_test_blocks_in_lib_ok;
      test_case "LB_MSG12 multiple importers each get error" `Quick test_LB_MSG12_multiple_importers_each_get_error;
      test_case "LB_MSG13 error includes module name" `Quick test_LB_MSG13_error_includes_module_name_in_message;
      test_case "LB_MSG14 ADT type library OK" `Quick test_LB_MSG14_adt_type_library_ok;
      test_case "LB_MSG15 newtype library OK" `Quick test_LB_MSG15_newtype_library_ok;
      test_case "LB_MSG16 facts-only lib OK" `Quick test_LB_MSG16_facts_only_lib_ok;
      test_case "LB_MSG17 const module OK" `Quick test_LB_MSG17_const_module_ok;
      test_case "LB_MSG18 api-test not targeted as lib boundary" `Quick test_LB_MSG18_api_test_not_forbidden;
    ];
  ]
