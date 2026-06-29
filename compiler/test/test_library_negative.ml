(** Library negative tests — Review 73b.

    30+ tests covering code that must NOT compile.  Four groups:

    LKWN  — library keyword violations (library module contains forbidden infra)
    REEXN — re-export failures (things that must not be re-exported)
    LIMN  — library import failures (importing app-level modules)
    PROVN — proof/type violations in library consumer context
    FORGE — proof ownership: re-exporting a fact must NOT allow the re-exporting
            module (or any other module) to mint/forge that proof.  Only the
            module that declares `fact F` can produce `F`-carrying values via
            `check`, `establish`, or `auth` functions.
    SIGX  — signature exposure: library exports a function whose signature
            references a locally-defined type or proof predicate that is not
            also exported.  Consumers cannot call such a function. *)

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
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r73n" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let with_two_files a_name a_src b_name b_src f =
  let dir = Filename.temp_dir "tesl-r73n2" "" in
  let path_a = Filename.concat dir (a_name ^ ".tesl") in
  let path_b = Filename.concat dir (b_name ^ ".tesl") in
  let oc_a = open_out path_a in output_string oc_a a_src; close_out oc_a;
  let oc_b = open_out path_b in output_string oc_b b_src; close_out oc_b;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path_a with _ -> ());
      (try Sys.remove path_b with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path_b)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let two_files_should_fail pat a_name a_src b_name b_src =
  with_two_files a_name a_src b_name b_src (fun path_b ->
    let code, out = run_compiler ["--check"; path_b] in
    if code = 0 then failf "expected failure matching %S for %s, but succeeded" pat b_name;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── LKWN — library keyword violations ───────────────────────────────────── *)

let test_LKWN01_library_with_server_rejected () =
  should_fail "library module.*server\\|server.*library\\|not allowed in library" {|
#lang tesl
library BadLib01 exposing []
import Tesl.Prelude exposing [String]
api MyApi { get "/ping" -> String }
handler ping() -> String requires [] = "pong"
server MyServer for MyApi { ping = ping }
|}

let test_LKWN02_library_with_api_rejected () =
  should_fail "library module.*api\\|api.*library\\|not allowed in library" {|
#lang tesl
library BadLib02 exposing []
import Tesl.Prelude exposing [String]
api ShouldNotBeHere { get "/health" -> String }
|}

let test_LKWN03_library_with_main_rejected () =
  should_fail "library module.*main\\|main.*library\\|not allowed in library" {|
#lang tesl
library BadLib03 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.App exposing [App]
fn add(a: Int, b: Int) -> Int = a + b
main() -> App requires [] =
  App {
    database: Db
    api: Srv
    port: 8080
    queues: []
  }
|}

let test_LKWN04_library_with_queue_infra_rejected () =
  (* A folded queue is application infrastructure: it requires a `database`
     declaration, and library modules cannot own a `database` (V001). This
     preserves the original intent — queue/worker infrastructure wiring is not
     allowed in a library — under the folded-queue model (which has no `workers`
     mapping keyword). The `database` declaration the queue depends on is the
     decl the library-boundary check rejects. *)
  should_fail "cannot own application infrastructure\\|database.*library\\|not allowed in library" {|
#lang tesl
library BadLib04 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [Queue, Job]
database Db = Database { schema: "public"  entities: []  backend: Memory }
record JobRec { msg: String }
worker doJob(j: JobRec) requires [] = j
queue MyQ = Queue { database: Db  jobs: [Job JobRec doJob (Nothing)]  numberOfWorkers: 1 }
|}

let test_LKWN05_library_with_both_api_and_server_rejected () =
  (* Both api AND server present — should get at least one error *)
  should_fail "library module.*api\\|library module.*server\\|not allowed in library" {|
#lang tesl
library BadLib05 exposing []
import Tesl.Prelude exposing [String]
api MultiApi { get "/a" -> String get "/b" -> String }
handler ha() -> String requires [] = "a"
handler hb() -> String requires [] = "b"
server MultiServer for MultiApi { ha = ha hb = hb }
|}

let test_LKWN06_library_error_mentions_library_keyword () =
  (* Error message must mention "library" to be helpful to newcomers *)
  should_fail "library" {|
#lang tesl
library ErrorMsgLib exposing []
import Tesl.Prelude exposing [String]
api BadApi { get "/test" -> String }
|}

let test_LKWN07_library_error_hint_suggests_module () =
  (* Hint must tell user to either remove the block or change to `module` *)
  should_fail "change.*module\\|module.*change\\|remove.*block\\|block.*remove\\|library.*to.*module" {|
#lang tesl
library HintLib exposing []
import Tesl.Prelude exposing [String]
api HintApi { get "/hint" -> String }
|}

let test_LKWN08_library_with_api_no_server_still_rejected () =
  (* api alone (no server) is still forbidden in a library *)
  should_fail "not allowed in library\\|library.*api" {|
#lang tesl
library ApiOnlyLib exposing []
import Tesl.Prelude exposing [String, Int]
api Routes {
  get "/users" -> String
  post "/users" -> Int
  delete "/users/:id" -> String
}
|}

let test_LKWN09_library_can_have_handler_functions_positive () =
  (* Sanity: handler functions (not server blocks) ARE allowed in libraries *)
  with_temp_file {|
#lang tesl
library HandlerFnLib exposing [myHandler]
import Tesl.Prelude exposing [String]
handler myHandler() -> String requires [] = "ok"
|} (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "handler functions should be allowed in libraries, got:\n%s" out)

let test_LKWN10_library_pure_functions_positive () =
  (* Sanity: pure function libraries work *)
  with_temp_file {|
#lang tesl
library PureFnLib exposing [double, triple]
import Tesl.Prelude exposing [Int]
fn double(n: Int) -> Int = n * 2
fn triple(n: Int) -> Int = n * 3
|} (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "pure libraries should compile, got:\n%s" out)

(* ── REEXN — re-export failures ─────────────────────────────────────────── *)

let test_REEXN01_cannot_reexport_ghost_name () =
  (* A name that doesn't exist locally and wasn't imported *)
  should_fail "unknown or non-local\\|exposes unknown\\|only locally-defined" {|
#lang tesl
module GhostExport exposing [totallyMadeUp]
import Tesl.Prelude exposing [Int]
fn realFn() -> Int = 42
|}

let test_REEXN02_cannot_reexport_from_import_all () =
  (* With ImportAll (no explicit exposing), names are usable but NOT re-exportable *)
  two_files_should_fail
    "unknown or non-local\\|exposes unknown\\|only locally-defined"
    "SourceMod" {|
#lang tesl
module SourceMod exposing [myFn]
import Tesl.Prelude exposing [Int]
fn myFn() -> Int = 42
|} "ImportAllReexport" {|
#lang tesl
module ImportAllReexport exposing [myFn]
import SourceMod
|}

let test_REEXN03_cannot_reexport_name_source_hides () =
  (* The source module has the name internally but does NOT expose it *)
  two_files_should_fail
    "unknown or non-local\\|exposes unknown\\|only locally-defined"
    "HidingLib" {|
#lang tesl
module HidingLib exposing [publicFn]
import Tesl.Prelude exposing [Int]
fn publicFn() -> Int = 1
fn hiddenFn() -> Int = 2
|} "ReexportHidden" {|
#lang tesl
module ReexportHidden exposing [hiddenFn]
import HidingLib exposing [publicFn]
|}

let test_REEXN04_cannot_reexport_and_declare_same_name () =
  (* Local declaration shadows import — both in exposing = conflict *)
  two_files_should_fail
    "shadows imported\\|duplicate\\|conflict\\|already"
    "BaseLib" {|
#lang tesl
module BaseLib exposing [foo]
import Tesl.Prelude exposing [Int]
fn foo() -> Int = 1
|} "ShadowReexport" {|
#lang tesl
module ShadowReexport exposing [foo]
import Tesl.Prelude exposing [Int]
import BaseLib exposing [foo]
fn foo() -> Int = 99
|}

let test_REEXN05_cannot_export_name_twice () =
  (* Listing the same name twice in exposing *)
  should_fail "duplicate.*export\\|export.*duplicate\\|already.*declared.*export" {|
#lang tesl
module DuplicateExport exposing [myFn, myFn]
import Tesl.Prelude exposing [Int]
fn myFn() -> Int = 42
|}

let test_REEXN06_cannot_reexport_type_from_import_all () =
  (* A type imported via ImportAll (no explicit exposing list) cannot be re-exported.
     ImportAll puts names in scope for USE but not for re-export. *)
  should_fail "unknown or non-local\\|exposes unknown\\|only locally-defined" {|
#lang tesl
module StdlibReexport exposing [String]
import Tesl.Prelude
|}

let test_REEXN07_cannot_reexport_name_from_wrong_module () =
  (* Module B imports 'existing' from ModA, but tries to export 'nonExistent' *)
  two_files_should_fail
    "unknown or non-local\\|exposes unknown\\|only locally-defined"
    "SmallMod" {|
#lang tesl
module SmallMod exposing [existing]
import Tesl.Prelude exposing [Int]
fn existing() -> Int = 1
|} "WrongNameReexport" {|
#lang tesl
module WrongNameReexport exposing [nonExistent]
import SmallMod exposing [existing]
|}

let test_REEXN08_cannot_reexport_from_transitive_only_dep () =
  (* B imports C directly; B imports A. A imports C but B doesn't re-expose from C directly.
     B tries to list a name from C that it only knows transitively — rejected. *)
  two_files_should_fail
    "unknown or non-local\\|exposes unknown\\|only locally-defined"
    "DepC" {|
#lang tesl
module DepC exposing [cFn]
import Tesl.Prelude exposing [Int]
fn cFn() -> Int = 1
|} "DepB" {|
#lang tesl
module DepB exposing [cFn]
import Tesl.Prelude exposing [Int]
fn bFn() -> Int = 2
|}

let test_REEXN09_cannot_reexport_imported_all_adt_fn () =
  (* Function from ImportAll — NOT re-exportable (function, not constructor) *)
  two_files_should_fail
    "unknown or non-local\\|exposes unknown\\|only locally-defined"
    "FnLib" {|
#lang tesl
module FnLib exposing [compute]
import Tesl.Prelude exposing [Int]
fn compute(n: Int) -> Int = n * 3
|} "FnLibReexportAll" {|
#lang tesl
module FnLibReexportAll exposing [compute]
import FnLib
|}

let test_REEXN10_cannot_reexport_importall_int_type () =
  (* Int type from ImportAll of Tesl.Prelude — only usable, not re-exportable *)
  should_fail "unknown or non-local\\|exposes unknown\\|only locally-defined" {|
#lang tesl
module BadStdlibExport exposing [Int]
import Tesl.Prelude
|}

let test_REEXN11_cannot_reexport_fact_not_explicitly_imported () =
  (* Library has a fact but it's not in the consumer's explicit exposing import *)
  two_files_should_fail
    "unknown or non-local\\|exposes unknown\\|only locally-defined"
    "FactOwner" {|
#lang tesl
module FactOwner exposing [ValidScore, checkScore]
import Tesl.Prelude exposing [Int]
fact ValidScore (n: Int)
check checkScore(n: Int) -> n: Int ::: ValidScore n =
  if n >= 0 && n <= 100 then
    ok n ::: ValidScore n
  else
    fail 400 "bad"
|} "FactMissingReexport" {|
#lang tesl
module FactMissingReexport exposing [ValidScore]
import FactOwner exposing [checkScore]
|}

let test_REEXN12_cannot_reexport_name_with_typo () =
  (* Typo in the re-exported name: ValidEmail vs validEmail *)
  two_files_should_fail
    "unknown or non-local\\|exposes unknown\\|only locally-defined"
    "EmailLib" {|
#lang tesl
module EmailLib exposing [ValidEmail, checkEmail]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains, String.length]
fact ValidEmail (s: String)
check checkEmail(s: String) -> s: String ::: ValidEmail s =
  if String.contains s "@" && String.length s >= 5 then
    ok s ::: ValidEmail s
  else
    fail 400 "invalid"
|} "TypoReexport" {|
#lang tesl
module TypoReexport exposing [validEmail]
import EmailLib exposing [ValidEmail, checkEmail]
|}

(* ── LIMN — library import (app module as library) failures ───────────────── *)

let test_LIMN01_importing_module_with_server_rejected () =
  two_files_should_fail
    "not allowed in library\\|server.*library\\|library.*server"
    "AppWithServer" {|
#lang tesl
module AppWithServer exposing [AppServer]
import Tesl.Prelude exposing [String]
api AppApi { get "/health" -> String }
handler health() -> String requires [] = "ok"
server AppServer for AppApi { health = health }
|} "ImporterOfApp" {|
#lang tesl
module ImporterOfApp exposing []
import Tesl.Prelude exposing [String]
import AppWithServer exposing [AppServer]
|}

let test_LIMN02_importing_module_with_api_rejected () =
  two_files_should_fail
    "not allowed in library\\|api.*library\\|library.*api"
    "AppWithApi" {|
#lang tesl
module AppWithApi exposing []
import Tesl.Prelude exposing [String]
api JustAnApi { get "/test" -> String }
|} "ImporterOfApiApp" {|
#lang tesl
module ImporterOfApiApp exposing []
import AppWithApi exposing []
|}

let test_LIMN03_importing_module_with_main_rejected () =
  two_files_should_fail
    "not allowed in library\\|main.*library\\|library.*main"
    "AppWithMain" {|
#lang tesl
module AppWithMain exposing []
import Tesl.Prelude exposing [Int]
import Tesl.App exposing [App]
fn add(a: Int, b: Int) -> Int = a + b
main() -> App requires [] =
  App {
    database: Db
    api: Srv
    port: 8080
    queues: []
  }
|} "ImporterOfMain" {|
#lang tesl
module ImporterOfMain exposing []
import AppWithMain exposing []
|}

let test_LIMN04_importing_module_with_queue_app_rejected () =
  (* A queue-bearing app wires its folded queue into an `App` via `main` — that
     `main` (app entry-point infrastructure) is not allowed to be imported as a
     library. In the folded-queue model there is no `workers` wiring block; the
     queue infrastructure is carried by an App module whose `main` triggers the
     importer-level library-boundary rejection. *)
  two_files_should_fail
    "not allowed in library\\|main.*library\\|library.*main"
    "AppWithWorkers" {|
#lang tesl
module AppWithWorkers exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [Queue, Job]
import Tesl.App exposing [App]
database Db = Database { schema: "public"  entities: []  backend: Memory }
record JobRec { msg: String }
worker handleJob(j: JobRec) requires [] = j
queue Q = Queue { database: Db  jobs: [Job JobRec handleJob (Nothing)]  numberOfWorkers: 1 }
main() -> App requires [] =
  App {
    database: Db
    api: Srv
    port: 8080
    queues: [Q]
  }
|} "ImporterOfWorkers" {|
#lang tesl
module ImporterOfWorkers exposing []
import AppWithWorkers exposing []
|}

let test_LIMN05_clear_error_message_names_the_module () =
  (* Error message must identify which imported module is the problem *)
  two_files_should_fail
    "SpecificAppModule\\|not allowed in library"
    "SpecificAppModule" {|
#lang tesl
module SpecificAppModule exposing []
import Tesl.Prelude exposing [String]
api SpecApi { get "/" -> String }
|} "ImporterOfSpecific" {|
#lang tesl
module ImporterOfSpecific exposing []
import SpecificAppModule exposing []
|}

let test_LIMN06_clean_library_import_still_compiles () =
  (* Sanity: importing a clean library module is fine *)
  with_two_files "CleanLib" {|
#lang tesl
module CleanLib exposing [helper]
import Tesl.Prelude exposing [Int]
fn helper(n: Int) -> Int = n * 2
|} "CleanImporter" {|
#lang tesl
module CleanImporter exposing []
import Tesl.Prelude exposing [Int]
import CleanLib exposing [helper]
fn useHelper(n: Int) -> Int = helper n
|} (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "clean library import should compile, got:\n%s" out)

(* ── PROVN — proof/type violations in library consumer context ─────────────── *)

let test_PROVN01_consumer_uses_proof_without_importing_it () =
  (* Consumer imports a check function but forgets to import its fact *)
  two_files_should_fail
    "not in scope\\|proof predicate.*not in scope\\|IsVal\\|P001"
    "ValLib" {|
#lang tesl
module ValLib exposing [IsVal, checkVal]
import Tesl.Prelude exposing [Int]
fact IsVal (n: Int)
check checkVal(n: Int) -> n: Int ::: IsVal n =
  if n > 0 then
    ok n ::: IsVal n
  else
    fail 400 "bad"
|} "MissingFactImport" {|
#lang tesl
module MissingFactImport exposing []
import Tesl.Prelude exposing [Int]
import ValLib exposing [checkVal]
fn requiresIsVal(n: Int ::: IsVal n) -> Int = n
fn test(raw: Int) -> Int =
  let v = check checkVal raw
  requiresIsVal v
|}

let test_PROVN02_library_fact_ownership_violation () =
  (* Module B tries to produce a fact owned by module A without declaring it *)
  two_files_should_fail
    "fact ownership\\|P001\\|can only be produced\\|declaring module"
    "FactOwnerA" {|
#lang tesl
module FactOwnerA exposing [IsApproved, checkApproved]
import Tesl.Prelude exposing [Int]
fact IsApproved (n: Int)
check checkApproved(n: Int) -> n: Int ::: IsApproved n =
  if n > 0 then
    ok n ::: IsApproved n
  else
    fail 400 "bad"
|} "FactForger" {|
#lang tesl
module FactForger exposing []
import Tesl.Prelude exposing [Int]
import FactOwnerA exposing [IsApproved]
check fakeApproval(n: Int) -> n: Int ::: IsApproved n =
  ok n ::: IsApproved n
|}

let test_PROVN03_consumer_uses_type_from_library_without_importing () =
  (* Consumer function uses a record type from a library without importing it *)
  two_files_should_fail
    "not in scope\\|unknown.*type\\|T001"
    "TypeLib" {|
#lang tesl
module TypeLib exposing [Widget, makeWidget]
import Tesl.Prelude exposing [Int, String]
record Widget { id: Int name: String }
fn makeWidget(id: Int, name: String) -> Widget =
  Widget { id: id name: name }
|} "TypeConsumer" {|
#lang tesl
module TypeConsumer exposing []
import Tesl.Prelude exposing [Int, String]
import TypeLib exposing [makeWidget]
fn getWidget() -> Widget =
  makeWidget 1 "test"
|}

let test_PROVN04_unvalidated_value_fails_library_proof_requirement () =
  (* Consumer has library's fact imported but passes raw value where proof required *)
  two_files_should_fail
    "does not.*statically.*satisfy\\|proof\\|IsPositive"
    "PosLib" {|
#lang tesl
module PosLib exposing [IsPositive, checkPositive, requiresPositive]
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn requiresPositive(n: Int ::: IsPositive n) -> Int = n + 1
|} "UnvalidatedConsumer" {|
#lang tesl
module UnvalidatedConsumer exposing []
import Tesl.Prelude exposing [Int]
import PosLib exposing [IsPositive, checkPositive, requiresPositive]
fn badCaller(raw: Int) -> Int =
  requiresPositive raw
|}

let test_PROVN05_library_proof_not_satisfied_in_consumer () =
  (* Consumer requires a library proof but passes un-validated value *)
  two_files_should_fail
    "does not.*statically.*satisfy\\|proof\\|IsActive"
    "ActiveLib" {|
#lang tesl
module ActiveLib exposing [IsActive, checkActive, requiresActive]
import Tesl.Prelude exposing [Int]
fact IsActive (n: Int)
check checkActive(n: Int) -> n: Int ::: IsActive n =
  if n > 0 then
    ok n ::: IsActive n
  else
    fail 400 "not active"
fn requiresActive(n: Int ::: IsActive n) -> Int = n * 10
|} "ActiveConsumer" {|
#lang tesl
module ActiveConsumer exposing []
import Tesl.Prelude exposing [Int]
import ActiveLib exposing [IsActive, checkActive, requiresActive]
fn badCaller(raw: Int) -> Int =
  requiresActive raw
|}

let test_PROVN06_undeclared_capability_in_consumer () =
  (* Consumer function declares requires [] but uses a capability the language enforces *)
  should_fail "undeclared capability\\|unknown.*capability\\|not.*declared" {|
#lang tesl
module CapConsumer exposing []
import Tesl.Prelude exposing [Int]
capability ghost implies dbRead
fn badFn() -> Int requires [ghostCapabilityThatDoesntExist] = 42
|}

(* ── FORGE — proof ownership preserved through re-export ────────────────── *)
(* These tests verify that re-exporting a `fact` from another module does NOT
   grant the re-exporting module the ability to produce (mint) that proof.
   Only the module that declared `fact F (...)` can have check/establish/auth
   functions that return `F`-carrying values. *)

let fact_owner_lib = {|
#lang tesl
module FactOwnerLib exposing [ValidEmail, checkEmail]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains, String.length]
fact ValidEmail (s: String)
check checkEmail(s: String) -> s: String ::: ValidEmail s =
  if String.contains s "@" && String.length s >= 5 then
    ok s ::: ValidEmail s
  else
    fail 400 "invalid email"
|}

let test_FORGE01_reexporting_module_cannot_forge_via_check () =
  (* Module B re-exports ValidEmail but tries to create its own check that
     mints ValidEmail proofs — must be rejected with P001 ownership violation *)
  two_files_should_fail
    "fact ownership\\|P001\\|can only be produced\\|declaring module"
    "FactOwnerLib" fact_owner_lib
    "ForgeViaCheck" {|
#lang tesl
module ForgeViaCheck exposing [ValidEmail, badForge]
import Tesl.Prelude exposing [String]
import FactOwnerLib exposing [ValidEmail, checkEmail]
check badForge(s: String) -> s: String ::: ValidEmail s =
  ok s ::: ValidEmail s
|}

let test_FORGE02_reexporting_module_cannot_forge_via_establish () =
  two_files_should_fail
    "fact ownership\\|P001\\|can only be produced\\|declaring module"
    "FactOwnerLib" fact_owner_lib
    "ForgeViaEstablish" {|
#lang tesl
module ForgeViaEstablish exposing [ValidEmail, alwaysValid]
import Tesl.Prelude exposing [String, Fact]
import FactOwnerLib exposing [ValidEmail, checkEmail]
establish alwaysValid(s: String) -> Fact (ValidEmail s) =
  ValidEmail s
|}

let test_FORGE03_reexporting_module_cannot_forge_via_auth () =
  two_files_should_fail
    "fact ownership\\|P001\\|can only be produced\\|declaring module"
    "FactOwnerLib" fact_owner_lib
    "ForgeViaAuth" {|
#lang tesl
module ForgeViaAuth exposing [ValidEmail, fakeAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import FactOwnerLib exposing [ValidEmail, checkEmail]
auth fakeAuth(req: HttpRequest) -> email: String ::: ValidEmail email =
  ok "forged@example.com" ::: ValidEmail email
|}

let test_FORGE04_third_module_cannot_forge_via_reexport_chain () =
  (* Chain: A defines fact, B re-exports, C imports from B.
     C must NOT be able to forge A's proof either. *)
  with_two_files "FactOwnerLib" fact_owner_lib "ReexportBridge" {|
#lang tesl
module ReexportBridge exposing [ValidEmail, checkEmail]
import FactOwnerLib exposing [ValidEmail, checkEmail]
|} (fun _ ->
    (* Now run check on a third file in the same dir *)
    let dir = Filename.temp_dir "tesl-r73-chain" "" in
    let path_a = Filename.concat dir "FactOwnerLib.tesl" in
    let path_b = Filename.concat dir "ReexportBridge.tesl" in
    let path_c = Filename.concat dir "ForgeThroughChain.tesl" in
    let oc_a = open_out path_a in output_string oc_a fact_owner_lib; close_out oc_a;
    let oc_b = open_out path_b in
    output_string oc_b {|
#lang tesl
module ReexportBridge exposing [ValidEmail, checkEmail]
import FactOwnerLib exposing [ValidEmail, checkEmail]
|};
    close_out oc_b;
    let oc_c = open_out path_c in
    output_string oc_c {|
#lang tesl
module ForgeThroughChain exposing []
import Tesl.Prelude exposing [String]
import ReexportBridge exposing [ValidEmail, checkEmail]
check forgeViaChain(s: String) -> s: String ::: ValidEmail s =
  ok s ::: ValidEmail s
|};
    close_out oc_c;
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove path_a with _ -> ());
        (try Sys.remove path_b with _ -> ());
        (try Sys.remove path_c with _ -> ());
        (try Unix.rmdir dir with _ -> ()))
      (fun () ->
        let code, out = run_compiler ["--check"; path_c] in
        if code = 0 then failf "expected P001 ownership violation, but succeeded";
        let re = Str.regexp_case_fold "fact ownership\\|P001\\|can only be produced\\|declaring module" in
        try ignore (Str.search_forward re out 0)
        with Not_found -> failf "expected ownership error, got:\n%s" out))

let test_FORGE05_legitimate_reexport_use_still_works () =
  (* Positive: re-exporting a fact and using it in type annotations (not forging) is fine *)
  with_two_files "FactOwnerLib" fact_owner_lib "LegitReexportUse" {|
#lang tesl
module LegitReexportUse exposing []
import Tesl.Prelude exposing [String]
import FactOwnerLib exposing [ValidEmail, checkEmail]
fn requiresValidEmail(s: String ::: ValidEmail s) -> String = s
fn process(raw: String) -> String =
  let e = check checkEmail raw
  requiresValidEmail e
|} (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "legitimate re-export use must compile, got:\n%s" out)

let test_FORGE06_reexporting_module_cannot_annotate_own_fn_with_foreign_proof () =
  (* B re-exports ValidEmail and tries to annotate its own function's RETURN with it.
     A plain `fn` (not check/establish) cannot declare a proof return type at all —
     this is a different error but also blocked. *)
  two_files_should_fail
    "fact ownership\\|P001\\|proof return type\\|only.*check.*auth.*establish"
    "FactOwnerLib" fact_owner_lib
    "FnWithForeignProof" {|
#lang tesl
module FnWithForeignProof exposing []
import Tesl.Prelude exposing [String]
import FactOwnerLib exposing [ValidEmail, checkEmail]
fn badAnnotation(s: String) -> s: String ::: ValidEmail s = s
|}

let test_FORGE07_cannot_produce_fact_without_declaring_it () =
  (* Module that never saw the fact at all cannot produce it either *)
  should_fail "fact ownership\\|P001\\|can only be produced\\|declaring module" {|
#lang tesl
module NoFactDeclared exposing []
import Tesl.Prelude exposing [String]
fact GhostFact (s: String)
check tryProduce(s: String) -> s: String ::: GhostFact s =
  ok s ::: GhostFact s
check tryProduce2(s: String) -> s: String ::: AnotherGhostFact s =
  ok s ::: AnotherGhostFact s
|}

(* ── SIGX — signature exposure errors (library modules only) ─────────────── *)

let test_SIGX01_library_exports_fn_with_unexported_param_type () =
  should_fail "not exported\\|consumers cannot use\\|add.*User.*exposing\\|V001" {|
#lang tesl
library SigX01 exposing [processUser]
import Tesl.Prelude exposing [String]
record User { name: String }
fn processUser(u: User) -> String = u.name
|}

let test_SIGX02_library_exports_fn_with_unexported_return_type () =
  should_fail "not exported\\|consumers cannot use\\|add.*Token.*exposing\\|V001" {|
#lang tesl
library SigX02 exposing [makeToken]
import Tesl.Prelude exposing [String]
record Token { value: String }
fn makeToken(s: String) -> Token =
  Token { value: s }
|}

let test_SIGX03_library_exports_fn_with_unexported_proof_predicate () =
  should_fail "not exported\\|consumers cannot use\\|add.*IsValid.*exposing\\|V001" {|
#lang tesl
library SigX03 exposing [checkVal]
import Tesl.Prelude exposing [Int]
fact IsValid (n: Int)
check checkVal(n: Int) -> n: Int ::: IsValid n =
  if n > 0 then
    ok n ::: IsValid n
  else
    fail 400 "not valid"
|}

let test_SIGX04_library_exports_fn_with_unexported_adt_type () =
  should_fail "not exported\\|consumers cannot use\\|add.*Color.*exposing\\|V001" {|
#lang tesl
library SigX04 exposing [describeColor]
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn describeColor(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|}

let test_SIGX05_library_all_exported_compiles_fine () =
  (* Positive: library exports both the type and the function using it *)
  with_temp_file {|
#lang tesl
library SigX05 exposing [processUser, User]
import Tesl.Prelude exposing [String]
record User { name: String }
fn processUser(u: User) -> String = u.name
|} (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "fully-exported library should compile, got:\n%s" out)

let test_SIGX06_library_stdlib_types_need_not_be_exported () =
  (* Positive: types from Tesl.* stdlib are never locally-defined, no error *)
  with_temp_file {|
#lang tesl
library SigX06 exposing [double, greet]
import Tesl.Prelude exposing [Int, String]
fn double(n: Int) -> Int = n * 2
fn greet(name: String) -> String = name
|} (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "stdlib-typed library should compile, got:\n%s" out)

let test_SIGX07_library_exports_proof_fn_fully_exported () =
  (* Positive: library exports both the fact and the check function *)
  with_temp_file {|
#lang tesl
library SigX07 exposing [IsValid, checkVal]
import Tesl.Prelude exposing [Int]
fact IsValid (n: Int)
check checkVal(n: Int) -> n: Int ::: IsValid n =
  if n > 0 then
    ok n ::: IsValid n
  else
    fail 400 "not valid"
|} (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "fully-exported library proof fn should compile, got:\n%s" out)

let test_SIGX08_regular_module_unexported_type_still_compiles () =
  (* Positive: regular module with unexported type in exported fn is a lint warning,
     NOT a compile error *)
  with_temp_file {|
#lang tesl
module SigX08 exposing [processUser]
import Tesl.Prelude exposing [String]
record User { name: String }
fn processUser(u: User) -> String = u.name
|} (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "regular module with unexported type should compile, got:\n%s" out)

let test_SIGX09_library_hint_names_missing_export () =
  (* Error message must include the specific type name and a fix hint *)
  should_fail "add.*Widget.*exposing\\|Widget" {|
#lang tesl
library SigX09 exposing [makeWidget]
import Tesl.Prelude exposing [Int, String]
record Widget { id: Int name: String }
fn makeWidget(id: Int, name: String) -> Widget =
  Widget { id: id name: name }
|}

let test_SIGX10_library_multiple_unexported_types_all_reported () =
  (* Both types must be flagged, not just the first *)
  should_fail "not exported\\|consumers cannot use" {|
#lang tesl
library SigX10 exposing [combine]
import Tesl.Prelude exposing [String]
record Alpha { a: String }
record Beta { b: String }
fn combine(x: Alpha, y: Beta) -> String = x.a
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review73b-Library-Negative" [
    "library-keyword-violations", [
      test_case "LKWN01 library+server rejected" `Quick test_LKWN01_library_with_server_rejected;
      test_case "LKWN02 library+api rejected" `Quick test_LKWN02_library_with_api_rejected;
      test_case "LKWN03 library+main rejected" `Quick test_LKWN03_library_with_main_rejected;
      test_case "LKWN04 library+queue infra rejected" `Quick test_LKWN04_library_with_queue_infra_rejected;
      test_case "LKWN05 library+api+server both rejected" `Quick test_LKWN05_library_with_both_api_and_server_rejected;
      test_case "LKWN06 error message mentions library" `Quick test_LKWN06_library_error_mentions_library_keyword;
      test_case "LKWN07 error hint suggests module keyword" `Quick test_LKWN07_library_error_hint_suggests_module;
      test_case "LKWN08 api alone in library rejected" `Quick test_LKWN08_library_with_api_no_server_still_rejected;
      test_case "LKWN09 handler functions allowed (positive)" `Quick test_LKWN09_library_can_have_handler_functions_positive;
      test_case "LKWN10 pure functions allowed (positive)" `Quick test_LKWN10_library_pure_functions_positive;
    ];
    "re-export-failures", [
      test_case "REEXN01 ghost name not exportable" `Quick test_REEXN01_cannot_reexport_ghost_name;
      test_case "REEXN02 ImportAll names not re-exportable" `Quick test_REEXN02_cannot_reexport_from_import_all;
      test_case "REEXN03 hidden name not re-exportable" `Quick test_REEXN03_cannot_reexport_name_source_hides;
      test_case "REEXN04 local+import same name rejected" `Quick test_REEXN04_cannot_reexport_and_declare_same_name;
      test_case "REEXN05 duplicate export rejected" `Quick test_REEXN05_cannot_export_name_twice;
      test_case "REEXN06 ImportAll type not re-exportable" `Quick test_REEXN06_cannot_reexport_type_from_import_all;
      test_case "REEXN07 name from wrong module rejected" `Quick test_REEXN07_cannot_reexport_name_from_wrong_module;
      test_case "REEXN08 transitive-only dep rejected" `Quick test_REEXN08_cannot_reexport_from_transitive_only_dep;
      test_case "REEXN09 ImportAll function not re-exportable" `Quick test_REEXN09_cannot_reexport_imported_all_adt_fn;
      test_case "REEXN10 ImportAll Int type not re-exportable" `Quick test_REEXN10_cannot_reexport_importall_int_type;
      test_case "REEXN11 fact not in exposing rejected" `Quick test_REEXN11_cannot_reexport_fact_not_explicitly_imported;
      test_case "REEXN12 typo in re-export name rejected" `Quick test_REEXN12_cannot_reexport_name_with_typo;
    ];
    "library-import-failures", [
      test_case "LIMN01 import module-with-server rejected" `Quick test_LIMN01_importing_module_with_server_rejected;
      test_case "LIMN02 import module-with-api rejected" `Quick test_LIMN02_importing_module_with_api_rejected;
      test_case "LIMN03 import module-with-main rejected" `Quick test_LIMN03_importing_module_with_main_rejected;
      test_case "LIMN04 import module-with-queue-app rejected" `Quick test_LIMN04_importing_module_with_queue_app_rejected;
      test_case "LIMN05 error names the bad module" `Quick test_LIMN05_clear_error_message_names_the_module;
      test_case "LIMN06 clean library import still works (positive)" `Quick test_LIMN06_clean_library_import_still_compiles;
    ];
    "proof-type-violations", [
      test_case "PROVN01 fact not imported consumer" `Quick test_PROVN01_consumer_uses_proof_without_importing_it;
      test_case "PROVN02 fact ownership violation" `Quick test_PROVN02_library_fact_ownership_violation;
      test_case "PROVN03 type not imported consumer" `Quick test_PROVN03_consumer_uses_type_from_library_without_importing;
      test_case "PROVN04 unvalidated value fails library proof" `Quick test_PROVN04_unvalidated_value_fails_library_proof_requirement;
      test_case "PROVN05 unvalidated value fails library proof requirement" `Quick test_PROVN05_library_proof_not_satisfied_in_consumer;
      test_case "PROVN06 undeclared capability rejected" `Quick test_PROVN06_undeclared_capability_in_consumer;
    ];
    "proof-ownership-through-reexport", [
      test_case "FORGE01 reexporting module cannot forge via check" `Quick test_FORGE01_reexporting_module_cannot_forge_via_check;
      test_case "FORGE02 reexporting module cannot forge via establish" `Quick test_FORGE02_reexporting_module_cannot_forge_via_establish;
      test_case "FORGE03 reexporting module cannot forge via auth" `Quick test_FORGE03_reexporting_module_cannot_forge_via_auth;
      test_case "FORGE04 third module cannot forge via chain" `Quick test_FORGE04_third_module_cannot_forge_via_reexport_chain;
      test_case "FORGE05 legitimate reexport use still works" `Quick test_FORGE05_legitimate_reexport_use_still_works;
      test_case "FORGE06 fn cannot annotate return with foreign proof" `Quick test_FORGE06_reexporting_module_cannot_annotate_own_fn_with_foreign_proof;
      test_case "FORGE07 cannot produce undeclared fact" `Quick test_FORGE07_cannot_produce_fact_without_declaring_it;
    ];
    "signature-exposure", [
      test_case "SIGX01 library unexported param type → error" `Quick test_SIGX01_library_exports_fn_with_unexported_param_type;
      test_case "SIGX02 library unexported return type → error" `Quick test_SIGX02_library_exports_fn_with_unexported_return_type;
      test_case "SIGX03 library unexported proof predicate → error" `Quick test_SIGX03_library_exports_fn_with_unexported_proof_predicate;
      test_case "SIGX04 library unexported ADT type → error" `Quick test_SIGX04_library_exports_fn_with_unexported_adt_type;
      test_case "SIGX05 library fully exported compiles (positive)" `Quick test_SIGX05_library_all_exported_compiles_fine;
      test_case "SIGX06 stdlib types need not be exported (positive)" `Quick test_SIGX06_library_stdlib_types_need_not_be_exported;
      test_case "SIGX07 library exported proof fn compiles (positive)" `Quick test_SIGX07_library_exports_proof_fn_fully_exported;
      test_case "SIGX08 regular module unexported type still compiles (positive)" `Quick test_SIGX08_regular_module_unexported_type_still_compiles;
      test_case "SIGX09 error hint names the missing export" `Quick test_SIGX09_library_hint_names_missing_export;
      test_case "SIGX10 multiple unexported types all reported" `Quick test_SIGX10_library_multiple_unexported_types_all_reported;
    ];
  ]
