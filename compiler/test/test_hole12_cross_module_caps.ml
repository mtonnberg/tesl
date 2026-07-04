(** Hole #12 — an imported function's declared `requires` is RE-VERIFIED against
    its body, so a lying `requires []` (a body that reads env / writes the DB /
    calls httpClient while declaring no capability) cannot launder an ungoverned
    effect through an `import`.

    Before the fix, [load_imported_func_caps] propagated only the imported
    function's DECLARED capability row; an importer that only compiled itself saw
    the honest-looking `requires []` and could call the effecting function from a
    `requires []` (or `[dbRead]`) context, performing an undeclared effect the
    whole-app capability union never governs.  After the fix, the loader computes
    each imported function's ACTUAL body capabilities ([collect_needed_capabilities],
    now colocated in validation_common) — to a fixpoint over the imported module's
    own call graph, and recursively through its transitive imports — and unions
    them with the declared row, so the caller is charged the real effect.

    Cross-module ⇒ the imported module must exist on disk ([load_imported_func_caps]
    resolves local imports via the filesystem, relative to the importer's path).
    We write both files into a fresh temp dir and compile the importer IN-PROCESS
    (via [Compile.compile_source], like test_a2_capability_launder) so `dune test`'s
    per-test sandbox exercises the freshly linked validation layer. *)

open Alcotest

(* Repo root discovery for stdlib imports — identical to test_a2_capability_launder:
   TESL_REPO_ROOT wins, else walk up to the dir containing `compiler/`. *)
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
        if parent = dir then Filename.current_dir_name else find parent
    in
    find (Filename.dirname Sys.executable_name)

let failf fmt = Printf.ksprintf failwith fmt

let diags_text diags =
  String.concat "\n"
    (List.map (fun (d : Compile.diagnostic) ->
       Printf.sprintf "error[%s]: %s" d.code d.message) diags)

(* Write every (filename, source) into a fresh temp dir, then compile the file
   named [importer] in-process against that dir (so its local imports resolve to
   the sibling files).  The dir + files are removed afterwards. *)
let compile_importer (files : (string * string) list) (importer : string) =
  let dir = Filename.temp_dir "tesl-h12" "" in
  let write (name, src) =
    let oc = open_out (Filename.concat dir name) in
    output_string oc src; close_out oc
  in
  List.iter write files;
  let path = Filename.concat dir importer in
  let src = List.assoc importer files in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (name, _) ->
        try Sys.remove (Filename.concat dir name) with _ -> ()) files;
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> Compile.compile_source ~root_path:root ~type_check:true path src)

let expect_launder_rejected label files importer =
  match compile_importer files importer with
  | Compile.Success _ ->
    failf "%s: expected the cross-module capability launder to be REJECTED, but it compiled" label
  | Compile.Failure diags ->
    let text = diags_text diags in
    let re = Str.regexp_case_fold "callees requiring" in
    (try ignore (Str.search_forward re text 0)
     with Not_found ->
       failf "%s: rejected, but not with the transitive-capability message:\n%s" label text)

let expect_ok label files importer =
  match compile_importer files importer with
  | Compile.Success _ -> ()
  | Compile.Failure diags ->
    failf "%s: honest cross-module import should compile, got:\n%s" label (diags_text diags)

(* ── Fixtures ──────────────────────────────────────────────────────────────── *)

(* A lying leaf: declares no capability but reads the environment. *)
let evil = {|#lang tesl
module Evil exposing [sneakyRead]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [env]
fn sneakyRead(key: String) -> String requires [] =
  env key
|}

(* Importer that trusts the lie — declares [], must be rejected. *)
let app2 = {|#lang tesl
module App2 exposing [readOnly]
import Tesl.Prelude exposing [String]
import Evil exposing [sneakyRead]
fn readOnly(key: String) -> String requires [] =
  sneakyRead key
|}

(* Two-hop lie inside the imported module: hop1 (requires []) calls hop2
   (requires []) which reads env.  Closed by the loader's intra-module fixpoint. *)
let evil_chain = {|#lang tesl
module EvilChain exposing [hop1]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [env]
fn hop2(key: String) -> String requires [] =
  env key
fn hop1(key: String) -> String requires [] =
  hop2 key
|}

let app3 = {|#lang tesl
module App3 exposing [readOnly]
import Tesl.Prelude exposing [String]
import EvilChain exposing [hop1]
fn readOnly(key: String) -> String requires [] =
  hop1 key
|}

(* Honest leaf + honest importer: declared == actual, must still compile. *)
let honest = {|#lang tesl
module Honest exposing [honestRead]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [env, envRead]
fn honestRead(key: String) -> String requires [envRead] =
  env key
|}

let app_ok = {|#lang tesl
module AppOk exposing [reader]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [envRead]
import Honest exposing [honestRead]
fn reader(key: String) -> String requires [envRead] =
  honestRead key
|}

(* The importer, having declared the real capability, must compile (the diagnostic
   leads to fixable code — no V001/P001 dead-end). *)
let app2_fixed = {|#lang tesl
module App2Fixed exposing [readOnly]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [envRead]
import Evil exposing [sneakyRead]
fn readOnly(key: String) -> String requires [envRead] =
  sneakyRead key
|}

let () =
  run "Hole12-Cross-Module-Caps" [
    "launder-rejected", [
      test_case "direct import of a lying requires-[] effect is rejected" `Quick
        (fun () -> expect_launder_rejected "App2/Evil"
            [ "Evil.tesl", evil; "App2.tesl", app2 ] "App2.tesl");
      test_case "two-hop lie inside the imported module is rejected" `Quick
        (fun () -> expect_launder_rejected "App3/EvilChain"
            [ "EvilChain.tesl", evil_chain; "App3.tesl", app3 ] "App3.tesl");
    ];
    "honest-compiles", [
      test_case "honest cross-module passthrough compiles" `Quick
        (fun () -> expect_ok "AppOk/Honest"
            [ "Honest.tesl", honest; "AppOk.tesl", app_ok ] "AppOk.tesl");
      test_case "declaring the real capability compiles (fixable, no dead-end)" `Quick
        (fun () -> expect_ok "App2Fixed/Evil"
            [ "Evil.tesl", evil; "App2Fixed.tesl", app2_fixed ] "App2Fixed.tesl");
    ];
  ]
