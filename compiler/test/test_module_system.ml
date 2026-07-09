(** Module-system bugs from the 2026-07-08 multi-module audit.

    THE PROPERTY: check-pass must imply runtime-works; rejections must be
    check-time with clear .tesl-anchored diagnostics, never raw Racket errors.

    BUG 1 — re-export rejected only at EMIT: `module A exposing [X]` where X
            is imported passed `--check <entrypoint>` and died at A's own emit
            with T001.  Now: export locality is enforced at CHECK time both
            for the module itself and for any entrypoint that (transitively)
            imports it, with a guided message naming the true declaring
            module ([Checker.export_locality_errors] +
            [Compile.cross_module_diags]).

    BUG 2 — import cycles crashed at `raco make` with a raw
            "standard-module-name-resolver: cycle in loading".  Two fixes:
            (a) the SCC machinery keyed graph nodes by unnormalized path
                STRINGS, so a bare CLI spelling (`main.tesl`) never matched a
                dep's back-edge spelling (`./main.tesl`) and the inliner
                silently missed the cycle — paths are now canonicalized
                (Validation_common.canonical_import_path);
            (b) cycles containing declarations the SCC inliner cannot lower
                (server/database/queue/api/codec/…/`main()`) are rejected at
                CHECK time with the cycle path.  Pure fn/type/record cycles
                remain supported (example/sandbox*.tesl class).  A module
                importing itself is always rejected.

    BUG 3 — CamelCase module filename: `--check` resolved `LibB.tesl` but the
            emitted require was unconditionally kebab (`lib-b.rkt`), which no
            emit step ever produces.  The require now uses the RESOLVED source
            file's basename; kebab-case is only the resolver's probe order.

    BUG 4 — opaque ADT export: importer-side [expand_local_import_names]
            expanded an imported ADT type name to name::all-ctors even when
            the declaring module exported it BARE (`exposing [Opaque]`), so
            the emitted `(only-in … Hidden)` failed at raco make.  Ctors are
            now pulled in only by an explicit `Name(..)` import.

    BUG 5 — the systemic hole behind 1: `--check <entrypoint>` never checked
            imported modules' BODIES.  A dep with a hard type error in a fn
            body (`cannot unify String with Int`), an out-of-scope type, a
            proof error or a failing validation passed `--check main.tesl`
            silently; --generate-elm/-ts generated clients with exit 0; the
            error only surfaced when the dep itself was compiled ("Failed to
            compile dependency", one phase too late).  Now
            [Compile.cross_module_diags] runs the FULL per-module check
            pipeline on every transitively imported local module, diagnostics
            anchored at the dep's own file:line; emit and the client
            generators gate on the same whole-program result; a dep that is
            itself a CLI argument of the same invocation is reported exactly
            once (dedupe by canonical path). *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let c2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl")

(** Repo root (for TESL_REPO_ROOT when invoking raco): env override, else walk
    up from cwd looking for a directory containing `compiler/`. *)
let repo_root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name else find parent
    in
    find (Sys.getcwd ())

let run_shell cmd =
  let ic = Unix.open_process_in (cmd ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128+n in
  (code, out)

let run_cc args =
  run_shell (String.concat " " (Filename.quote compiler :: List.map Filename.quote args))

(** Run the compiler with [dir] as cwd so RELATIVE .tesl spellings are
    exercised — the path-normalization regression (BUG 2a) only reproduces
    with a bare `main.tesl` argv, never with absolute paths. *)
let run_cc_in dir args =
  run_shell (Printf.sprintf "cd %s && %s"
               (Filename.quote dir)
               (String.concat " " (Filename.quote compiler :: List.map Filename.quote args)))

let raco_available =
  lazy (fst (run_shell "command -v raco") = 0)

let raco_make dir rkt =
  run_shell (Printf.sprintf "cd %s && TESL_REPO_ROOT=%s raco make %s"
               (Filename.quote dir) (Filename.quote repo_root) (Filename.quote rkt))

let failf fmt = Printf.ksprintf failwith fmt

let contains needle hay =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let with_temp_project (files : (string * string) list) (f : string -> unit) =
  let dir = Filename.temp_dir "tesl-modsys" "" in
  let paths = List.map (fun (name, src) ->
    let p = Filename.concat dir name in
    let oc = open_out p in output_string oc src; close_out oc; p
  ) files in
  Fun.protect
    ~finally:(fun () ->
      (* Remove everything the test (or raco) left behind. *)
      (try
         Array.iter (fun n ->
           let p = Filename.concat dir n in
           if Sys.is_directory p then begin
             Array.iter (fun n2 -> try Sys.remove (Filename.concat p n2) with _ -> ())
               (Sys.readdir p);
             (try Unix.rmdir p with _ -> ())
           end else (try Sys.remove p with _ -> ())
         ) (Sys.readdir dir)
       with _ -> ());
      ignore paths;
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f dir)

(* Emit [src_name] inside [dir] to [out_name]; fail the test on nonzero. *)
let emit_to dir src_name out_name =
  let code, out =
    run_shell (Printf.sprintf "cd %s && %s %s > %s"
                 (Filename.quote dir) (Filename.quote compiler)
                 (Filename.quote src_name) (Filename.quote out_name)) in
  if code <> 0 then failf "emit of %s failed:\n%s" src_name out;
  In_channel.with_open_text (Filename.concat dir out_name) In_channel.input_all

(* ── BUG 1: re-export must be rejected at CHECK time, guided ─────────────── *)

(* base declares every exportable decl kind; mid illegally re-exposes them. *)
let reexport_base = {|#lang tesl
module Base exposing [baseGreet, Payload, Gadget, GadgetDb, DeepJob, DeepQueue, Notices]

import Tesl.Prelude exposing [Int, String]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.Queue exposing [queueRead, Queue, Job, QueueRetryStrategy, Fixed]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.SSE exposing [SseChannel]

fn baseGreet(n: String) -> String =
  "hi ${n}"

record Payload {
  label: String
}

entity Gadget table "gadgets" primaryKey id {
  id: String
  kind: String
}

database GadgetDb = Database {
  schema: "reexp"
  entities: [Gadget]
  backend: Memory
}

record DeepJob {
  tag: String
}

queue DeepQueue requires [queueRead] = Queue {
  database: GadgetDb
  jobs: [Job DeepJob handleDeep Nothing]
  retry: QueueRetryStrategy {
    maxAttempts: 2
    backoff: Fixed
    initialDelay: 1
  }
}

worker handleDeep(job: DeepJob) requires [queueRead] =
  job

sseChannel Notices(userId: String) = SseChannel {
  database: GadgetDb
  payload: DeepJob
}
|}

let reexport_mid = {|#lang tesl
module Mid exposing [midGreet, baseGreet, Payload, Gadget, DeepJob, DeepQueue, Notices]

import Tesl.Prelude exposing [String]
import Base exposing [baseGreet, Payload, Gadget, DeepJob, DeepQueue, Notices]

fn midGreet(n: String) -> String =
  baseGreet n
|}

let reexport_main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [String]
import Mid exposing [midGreet]

fn go(n: String) -> String =
  midGreet n
|}

let reexport_files =
  [ ("base.tesl", reexport_base); ("mid.tesl", reexport_mid);
    ("main.tesl", reexport_main) ]

(* Whole-program `--check <entrypoint>` must surface the DEPENDENCY module's
   illegal re-exports (previously exit 0; T001 only appeared at mid's emit). *)
let reexport_whole_program_check_rejects () =
  with_temp_project reexport_files (fun dir ->
    let code, out = run_cc ["--check"; Filename.concat dir "main.tesl"] in
    if code = 0 then
      failf "--check of the entrypoint must reject the dependency's re-exports:\n%s" out;
    (* Every re-exported decl kind is reported: fn, record, entity, queue
       (record job type + queue) and sseChannel. *)
    List.iter (fun n ->
      if not (contains (Printf.sprintf "module exposes `%s`" n) out) then
        failf "expected a re-export rejection for `%s` from --check main.tesl:\n%s" n out)
      ["baseGreet"; "Payload"; "Gadget"; "DeepJob"; "DeepQueue"; "Notices"];
    (* Guided: names the true declaring module and the consumer-side fix. *)
    if not (contains "is imported from `Base`" out) then
      failf "re-export rejection must name the declaring module `Base`:\n%s" out;
    if not (contains "import Base exposing [baseGreet]" out) then
      failf "re-export rejection must give the consumer import line:\n%s" out)

(* Own-module `--check mid.tesl` gets the same guided rejection. *)
let reexport_own_module_check_rejects () =
  with_temp_project reexport_files (fun dir ->
    let code, out = run_cc ["--check"; Filename.concat dir "mid.tesl"] in
    if code = 0 then failf "--check of the re-exporting module must reject:\n%s" out;
    if not (contains "only locally-defined names can be exported" out) then
      failf "own-module rejection must carry the canonical phrase:\n%s" out;
    if not (contains "is imported from `Base`" out) then
      failf "own-module rejection must name the declaring module:\n%s" out)

(* An imported CONSTRUCTOR (pulled in via Type(..)) is a re-export too — it
   previously slipped the locality check via the imported-ctor table. *)
let reexport_imported_ctor_rejected () =
  let base = {|#lang tesl
module Base exposing [Status(..)]

import Tesl.Prelude exposing [String]

type Status
  = Active
  | Idle
|} in
  let mid = {|#lang tesl
module Mid exposing [Active]

import Tesl.Prelude exposing [String]
import Base exposing [Status(..)]
|} in
  with_temp_project [("base.tesl", base); ("mid.tesl", mid)] (fun dir ->
    let code, out = run_cc ["--check"; Filename.concat dir "mid.tesl"] in
    if code = 0 then failf "re-exporting an imported ctor must be rejected:\n%s" out;
    if not (contains "module exposes `Active`" out
            && contains "is imported from `Base`" out) then
      failf "imported-ctor re-export must get the guided message:\n%s" out)

(* ── BUG 2: import cycles ────────────────────────────────────────────────── *)

let cyc_main_server = {|#lang tesl
module Main exposing [MainServer]

import Tesl.Prelude exposing [String]
import Lib exposing [greetName]

handler hello() -> String =
  greetName "world"

api MainApi {
  get "/hello" -> String
}

server MainServer for MainApi {
  hello = hello
}
|}

let cyc_lib_apitest = {|#lang tesl
module Lib exposing [greetName]

import Tesl.Prelude exposing [String]
import Tesl.ApiTest exposing [statusOk]
import Main exposing [MainServer]

fn greetName(n: String) -> String =
  "hi ${n}"

api-test "lib api-test for main server" for MainServer {
  let r = get "/hello"
  expect statusOk r.status
}
|}

(* A cycle whose members declare config decls (api/server here) cannot be
   lowered by the SCC inliner — must be rejected at CHECK time with the cycle
   path, from BOTH members (previously exit 0, then raw "cycle in loading" at
   raco make). *)
let cycle_with_config_decls_rejected () =
  with_temp_project
    [("main.tesl", cyc_main_server); ("lib.tesl", cyc_lib_apitest)]
    (fun dir ->
       List.iter (fun entry ->
         let code, out = run_cc ["--check"; Filename.concat dir entry] in
         if code = 0 then
           failf "--check %s must reject the Main<->Lib config cycle:\n%s" entry out;
         if not (contains "import cycle detected" out) then
           failf "cycle rejection must say 'import cycle detected' (%s):\n%s" entry out;
         (* Item 22 (review 2026-07-09): the message states the FULL cycle-safe
            decl set — cycle_unsafe_decl_reason treats capturers and api-test/
            load-test blocks as legal, so the message must say so too. *)
         if not (contains
                   "fn (non-main)/type/record/entity/const/fact/test/api-test/load-test/capture declarations"
                   out) then
           failf "cycle rejection must state the full legal decl set (%s):\n%s"
             entry out;
         (* The full cycle path A -> B -> A is shown. *)
         if not (contains "Main -> Lib -> Main" out || contains "Lib -> Main -> Lib" out) then
           failf "cycle rejection must show the cycle path (%s):\n%s" entry out)
         ["main.tesl"; "lib.tesl"])

(* A module importing itself is always rejected. *)
let self_import_rejected () =
  let selfy = {|#lang tesl
module Selfy exposing [f]

import Tesl.Prelude exposing [Int]
import Selfy exposing [f]

fn f(n: Int) -> Int = n
|} in
  with_temp_project [("selfy.tesl", selfy)] (fun dir ->
    let code, out = run_cc ["--check"; Filename.concat dir "selfy.tesl"] in
    if code = 0 then failf "self-import must be rejected:\n%s" out;
    if not (contains "imports itself" out) then
      failf "self-import rejection must say so:\n%s" out)

let pure_cyc_a = {|#lang tesl
module CycA exposing [pingA]

import Tesl.Prelude exposing [Bool(..), Int]
import CycB exposing [pingB]

fn pingA(n: Int) -> Int =
  if n <= 0 then
    0
  else
    pingB (n - 1)
|}

let pure_cyc_b = {|#lang tesl
module CycB exposing [pingB]

import Tesl.Prelude exposing [Bool(..), Int]
import CycA exposing [pingA]

fn pingB(n: Int) -> Int =
  if n <= 0 then
    0
  else
    pingA (n - 1)
|}

(* Pure fn cycles stay LEGAL (mutually recursive modules are supported via SCC
   inlining — the example/sandbox*.tesl class), and the inliner must fire even
   when the compiler is invoked with a bare relative filename: the audit's
   "cycle in loading" was the SCC path-spelling mismatch (`CycA.tesl` vs
   `./CycA.tesl`), which canonicalization now closes. *)
let pure_cycle_allowed_and_inlined () =
  with_temp_project [("CycA.tesl", pure_cyc_a); ("CycB.tesl", pure_cyc_b)]
    (fun dir ->
       let code, out = run_cc_in dir ["--check"; "CycA.tesl"] in
       if code <> 0 then failf "pure fn cycle must still pass --check:\n%s" out;
       let a_out = emit_to dir "CycA.tesl" "CycA.rkt" in
       if not (contains "Inlined from cyclic module CycB" a_out) then
         failf "SCC inliner must fire for a bare relative CLI spelling:\n%s" a_out;
       if contains "CycB.rkt" a_out then
         failf "cyclic sibling must be inlined, not required (raw racket \
                'cycle in loading' otherwise):\n%s" a_out;
       (* The other member emits standalone too. *)
       let b_out = emit_to dir "CycB.tesl" "CycB.rkt" in
       if not (contains "Inlined from cyclic module CycA" b_out) then
         failf "SCC inliner must fire for CycB as entry too:\n%s" b_out;
       if Lazy.force raco_available then begin
         let code, out = raco_make dir "CycA.rkt" in
         if code <> 0 then failf "raco make CycA.rkt (pure cycle) failed:\n%s" out
       end)

(* ── BUG 3: CamelCase module filename — require matches the emitted dep ──── *)

let camel_lib = {|#lang tesl
module LibB exposing [twice]

import Tesl.Prelude exposing [Int]

fn twice(n: Int) -> Int =
  n + n
|}

let camel_main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [Int]
import LibB exposing [twice]

test "camelCase dep filename" {
  expect twice 2 == 4
}
|}

let camelcase_filename_require_matches () =
  with_temp_project [("LibB.tesl", camel_lib); ("main.tesl", camel_main)]
    (fun dir ->
       let code, out = run_cc ["--check"; Filename.concat dir "main.tesl"] in
       if code <> 0 then failf "--check must accept the CamelCase filename:\n%s" out;
       (* Emit each module to `${src%.tesl}.rkt` — exactly what the build
          pipeline does — and the require must point at that file. *)
       let _ = emit_to dir "LibB.tesl" "LibB.rkt" in
       let main_out = emit_to dir "main.tesl" "main.rkt" in
       if not (contains {|(file "LibB.rkt")|} main_out) then
         failf "require must use the RESOLVED source basename LibB.rkt:\n%s" main_out;
       if contains {|(file "lib-b.rkt")|} main_out then
         failf "require must not kebab-case a CamelCase filename (no emit step \
                ever produces lib-b.rkt):\n%s" main_out;
       if Lazy.force raco_available then begin
         let code, out = raco_make dir "LibB.rkt" in
         if code <> 0 then failf "raco make LibB.rkt failed:\n%s" out;
         let code, out = raco_make dir "main.rkt" in
         if code <> 0 then failf "raco make main.rkt (CamelCase dep) failed:\n%s" out
       end)

(* Control: the kebab-case spelling keeps working unchanged. *)
let kebab_filename_still_works () =
  with_temp_project [("lib-b.tesl", camel_lib); ("main.tesl", camel_main)]
    (fun dir ->
       let _ = emit_to dir "lib-b.tesl" "lib-b.rkt" in
       let main_out = emit_to dir "main.tesl" "main.rkt" in
       if not (contains {|(file "lib-b.rkt")|} main_out) then
         failf "kebab-case filename must resolve to lib-b.rkt:\n%s" main_out;
       if Lazy.force raco_available then begin
         let code, out = raco_make dir "main.rkt" in
         if code <> 0 then failf "raco make main.rkt (kebab dep) failed:\n%s" out
       end)

(* ── BUG 4: opaque (bare) ADT export vs Name(..) ─────────────────────────── *)

let opaque_lib = {|#lang tesl
module Lib exposing [Opaque, mkOpaque, opaqueName]

import Tesl.Prelude exposing [String]

type Opaque
  = Hidden tag: String

fn mkOpaque(t: String) -> Opaque =
  Hidden t

fn opaqueName(o: Opaque) -> String =
  case o of
    Hidden tag -> tag
|}

let opaque_main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [String]
import Lib exposing [Opaque, mkOpaque, opaqueName]

fn roundTrip(t: String) -> String =
  opaqueName (mkOpaque t)

test "opaque ADT via lib helpers" {
  expect roundTrip "t" == "t"
}
|}

(* Bare `exposing [Opaque]` + `import … [Opaque]` (needed for annotations)
   must NOT expand to constructors in the emitted only-in: lib.rkt's provide
   correctly omits them, so raco make used to die with "identifier `Hidden'
   not included in nested require spec". *)
let opaque_bare_export_type_name_import () =
  with_temp_project [("lib.tesl", opaque_lib); ("main.tesl", opaque_main)]
    (fun dir ->
       let code, out = run_cc ["--check"; Filename.concat dir "main.tesl"] in
       if code <> 0 then failf "--check must accept the opaque import:\n%s" out;
       let _ = emit_to dir "lib.tesl" "lib.rkt" in
       let main_out = emit_to dir "main.tesl" "main.rkt" in
       if contains "Hidden" main_out then
         failf "bare type-name import must not pull the hidden ctor into the \
                emitted require:\n%s" main_out;
       if not (contains "Opaque" main_out) then
         failf "the opaque type name itself must be require-bound:\n%s" main_out;
       if Lazy.force raco_available then begin
         let code, out = raco_make dir "main.rkt" in
         if code <> 0 then
           failf "raco make main.rkt (opaque bare export) failed:\n%s" out
       end)

let dotdot_lib = {|#lang tesl
module Lib exposing [Color(..)]

import Tesl.Prelude exposing [String]

type Color
  = Red
  | Green
|}

let dotdot_main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [String]
import Lib exposing [Color(..)]

fn show(c: Color) -> String =
  case c of
    Red -> "r"
    Green -> "g"

test "ctor import with (..)" {
  expect show Red == "r"
}
|}

(* Control: `Color(..)` export + `Color(..)` import keeps expanding ctors. *)
let dotdot_export_still_expands_ctors () =
  with_temp_project [("lib.tesl", dotdot_lib); ("main.tesl", dotdot_main)]
    (fun dir ->
       let _ = emit_to dir "lib.tesl" "lib.rkt" in
       let main_out = emit_to dir "main.tesl" "main.rkt" in
       if not (contains "Red" main_out && contains "Green" main_out) then
         failf "Color(..) import must still require-bind the ctors:\n%s" main_out;
       if Lazy.force raco_available then begin
         let code, out = raco_make dir "main.rkt" in
         if code <> 0 then failf "raco make main.rkt (Color(..)) failed:\n%s" out
       end)

(* Importing `Opaque(..)` when the declaring module exports it BARE stays a
   check-time rejection (pre-existing guard the emit fix relies on). *)
let dotdot_import_of_bare_export_rejected () =
  let main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [String]
import Lib exposing [Opaque(..)]
|} in
  with_temp_project [("lib.tesl", opaque_lib); ("main.tesl", main)]
    (fun dir ->
       let code, out = run_cc ["--check"; Filename.concat dir "main.tesl"] in
       if code = 0 then
         failf "Opaque(..) import of a bare export must be rejected:\n%s" out;
       if not (contains "does not expose constructors" out) then
         failf "expected the opaque-type guard message:\n%s" out)

(* ── BUG 5: whole-program --check covers imported-module BODIES ──────────── *)

let count_occurrences needle hay =
  let re = Str.regexp_string needle in
  let rec go pos acc =
    match (try Some (Str.search_forward re hay pos) with Not_found -> None) with
    | Some i -> go (i + String.length needle) (acc + 1)
    | None -> acc
  in
  go 0 0

(* Direct dep with a hard type error in a fn BODY (interface is fine). *)
let body_err_lib = {|#lang tesl
module Lib exposing [f]

import Tesl.Prelude exposing [Int, String]

fn f(x: Int) -> Int =
  "not an int"
|}

let body_err_main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [Int]
import Lib exposing [f]

fn use(n: Int) -> Int =
  f n
|}

let body_err_files =
  [ ("lib.tesl", body_err_lib); ("main.tesl", body_err_main) ]

(* (a) `--check main.tesl` must fail on the DEP's body type error, with the
   diagnostic anchored at lib.tesl and the correct line (the body expr,
   line 7).  Previously exit 0; the error only appeared at lib's own emit. *)
let dep_body_type_error_fails_entry_check () =
  with_temp_project body_err_files (fun dir ->
    let code, out = run_cc ["--check"; Filename.concat dir "main.tesl"] in
    if code = 0 then
      failf "--check main.tesl must fail on the imported module's body:\n%s" out;
    if not (contains "cannot unify String with Int" out) then
      failf "expected the dep's unification error:\n%s" out;
    if not (contains "T001" out) then
      failf "dep body error must keep its own code T001:\n%s" out;
    if not (contains "lib.tesl:7:" out) then
      failf "diagnostic must be anchored at lib.tesl line 7 (the bad body), \
             not at the entrypoint:\n%s" out;
    (* The entrypoint itself is clean — no diagnostic may claim main.tesl. *)
    if contains "main.tesl:" out then
      failf "no diagnostic should be anchored at the (healthy) entrypoint:\n%s" out)

(* (b) TRANSITIVE dep: main -> A -> B, error in B's body. *)
let transitive_dep_body_error_fails_entry_check () =
  let main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [Int]
import A exposing [g]

fn use(n: Int) -> Int =
  g n
|} in
  let a = {|#lang tesl
module A exposing [g]

import Tesl.Prelude exposing [Int]
import B exposing [h]

fn g(n: Int) -> Int =
  h n
|} in
  let b = {|#lang tesl
module B exposing [h]

import Tesl.Prelude exposing [Int, String]

fn h(n: Int) -> Int =
  "boom"
|} in
  with_temp_project [("main.tesl", main); ("a.tesl", a); ("b.tesl", b)]
    (fun dir ->
       let code, out = run_cc ["--check"; Filename.concat dir "main.tesl"] in
       if code = 0 then
         failf "--check main.tesl must fail on the TRANSITIVE dep's body:\n%s" out;
       if not (contains "cannot unify String with Int" out) then
         failf "expected B's unification error:\n%s" out;
       if not (contains "b.tesl:7:" out) then
         failf "diagnostic must be anchored at b.tesl line 7:\n%s" out)

(* (c) client generators gate on the SAME whole-program result: broken dep
   => non-zero exit and no output file. *)
let client_generators_gate_on_dep_errors () =
  with_temp_project body_err_files (fun dir ->
    List.iter (fun (flag, out_name) ->
      let out_path = Filename.concat dir out_name in
      let code, out =
        run_cc [flag; Filename.concat dir "main.tesl"; "--out"; out_path] in
      if code = 0 then
        failf "%s must exit non-zero when a dep is broken:\n%s" flag out;
      if not (contains "cannot unify String with Int" out) then
        failf "%s must print the dep's diagnostic:\n%s" flag out;
      if Sys.file_exists out_path then
        failf "%s must not write a client for a broken program" flag)
      [("--generate-ts", "client.ts"); ("--generate-elm", "Api.elm")];
    (* Plain emit of the entrypoint is gated too. *)
    let code, out = run_cc_in dir ["main.tesl"] in
    if code = 0 then
      failf "plain emit of main.tesl must fail on the broken dep:\n%s" out)

(* (d) control: a healthy 3-module chain still checks + generates clean. *)
let healthy_multi_module_still_passes () =
  let main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [Int]
import A exposing [g]

fn use(n: Int) -> Int =
  g n
|} in
  let a = {|#lang tesl
module A exposing [g]

import Tesl.Prelude exposing [Int]
import B exposing [h]

fn g(n: Int) -> Int =
  h n
|} in
  let b = {|#lang tesl
module B exposing [h]

import Tesl.Prelude exposing [Int]

fn h(n: Int) -> Int =
  n + 1
|} in
  with_temp_project [("main.tesl", main); ("a.tesl", a); ("b.tesl", b)]
    (fun dir ->
       let code, out = run_cc ["--check"; Filename.concat dir "main.tesl"] in
       if code <> 0 then failf "healthy chain must pass --check:\n%s" out;
       let code, out = run_cc ["--generate-ts"; Filename.concat dir "main.tesl"] in
       if code <> 0 then failf "healthy chain must pass --generate-ts:\n%s" out;
       let code, out = run_cc ["--generate-elm"; Filename.concat dir "main.tesl"] in
       if code <> 0 then failf "healthy chain must pass --generate-elm:\n%s" out)

(* (e) --check-json carries the dep diagnostic WITH its own file path (the
   editor/agent surface: dep errors must be attributable to lib.tesl). *)
let check_json_includes_dep_diags () =
  with_temp_project body_err_files (fun dir ->
    let code, out = run_cc ["--check-json"; Filename.concat dir "main.tesl"] in
    if code = 0 then
      failf "--check-json must exit non-zero on a dep error:\n%s" out;
    if not (contains "cannot unify String with Int" out) then
      failf "--check-json must include the dep's diagnostic:\n%s" out;
    if not (contains {|"file"|} out) then
      failf "--check-json diagnostics must carry a file field:\n%s" out;
    if not (contains {|lib.tesl"|} out) then
      failf "the dep diagnostic's file field must point at lib.tesl:\n%s" out)

(* Dedupe: when the broken dep is ALSO a CLI argument, its error is reported
   exactly once (under its own entry), for both --check and --check-batch. *)
let dep_also_cli_arg_reported_once () =
  with_temp_project body_err_files (fun dir ->
    let code, out = run_cc ["--check"; Filename.concat dir "main.tesl";
                            Filename.concat dir "lib.tesl"] in
    if code = 0 then failf "--check main lib must fail:\n%s" out;
    let n = count_occurrences "cannot unify String with Int" out in
    if n <> 1 then
      failf "dep error must be reported exactly once (got %d):\n%s" n out;
    let code, out = run_cc ["--check-batch"; Filename.concat dir "main.tesl";
                            Filename.concat dir "lib.tesl"] in
    if code = 0 then failf "--check-batch main lib must fail:\n%s" out;
    let n = count_occurrences "cannot unify String with Int" out in
    if n <> 1 then
      failf "batch: dep error must be reported exactly once (got %d):\n%s" n out)

(* A dep that fails to PARSE is a whole-program check failure too, anchored
   at the dep's file. *)
let dep_parse_error_fails_entry_check () =
  let broken_lib = {|#lang tesl
module Lib exposing [f]

fn f(x: Int -> Int =
|} in
  with_temp_project [("lib.tesl", broken_lib); ("main.tesl", body_err_main)]
    (fun dir ->
       let code, out = run_cc ["--check"; Filename.concat dir "main.tesl"] in
       if code = 0 then
         failf "--check must fail when a dep does not parse:\n%s" out;
       if not (contains "lib.tesl" out) then
         failf "dep parse error must be anchored at lib.tesl:\n%s" out)

(* ── suite ────────────────────────────────────────────────────────────────── *)

let () =
  run "Module-System" [
    "bug1-reexport", [
      test_case "whole-program check rejects dep re-exports (all kinds)" `Quick
        reexport_whole_program_check_rejects;
      test_case "own-module check rejects, guided" `Quick
        reexport_own_module_check_rejects;
      test_case "imported ctor re-export rejected" `Quick
        reexport_imported_ctor_rejected;
    ];
    "bug2-cycles", [
      test_case "config-decl cycle rejected at check with cycle path" `Quick
        cycle_with_config_decls_rejected;
      test_case "self-import rejected" `Quick self_import_rejected;
      test_case "pure fn cycle allowed + inlined from bare CLI spelling" `Quick
        pure_cycle_allowed_and_inlined;
    ];
    "bug3-camelcase-filename", [
      test_case "require uses resolved basename (CamelCase)" `Quick
        camelcase_filename_require_matches;
      test_case "kebab-case filename control" `Quick kebab_filename_still_works;
    ];
    "bug4-opaque-adt-export", [
      test_case "bare export + type-name import compiles" `Quick
        opaque_bare_export_type_name_import;
      test_case "(..) export still expands ctors" `Quick
        dotdot_export_still_expands_ctors;
      test_case "(..) import of bare export rejected at check" `Quick
        dotdot_import_of_bare_export_rejected;
    ];
    "bug5-dep-bodies", [
      test_case "dep fn-body type error fails entrypoint --check, dep-anchored"
        `Quick dep_body_type_error_fails_entry_check;
      test_case "transitive dep body error fails entrypoint --check" `Quick
        transitive_dep_body_error_fails_entry_check;
      test_case "--generate-elm/-ts/emit gate on dep errors" `Quick
        client_generators_gate_on_dep_errors;
      test_case "healthy multi-module chain still passes" `Quick
        healthy_multi_module_still_passes;
      test_case "--check-json includes dep diagnostic with its file" `Quick
        check_json_includes_dep_diags;
      test_case "dep that is also a CLI arg reported once" `Quick
        dep_also_cli_arg_reported_once;
      test_case "dep parse error fails entrypoint --check" `Quick
        dep_parse_error_fails_entry_check;
    ];
  ]
