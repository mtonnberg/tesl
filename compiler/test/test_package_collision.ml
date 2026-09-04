(** Two Tesl module names that fold to one Go package are refused (whitebox campaign,
    2026-09-02). `package_name` keeps letters and digits and lower-cases, so `FooBar` and
    `Foobar` both became `teslmodfoobar`; two `module.go` artifacts then shared a path and the
    dedupe kept the first — the second module's functions were silently replaced by the
    first's, so a dependency mirroring a trusted module's exposed names hijacked them with no
    diagnostic. Also pins that a `_`-leading record field crosses a module boundary (it used
    to become an unexported Go field). *)

open Alcotest

let write dir name content =
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc; path

let with_project files f =
  let dir = Filename.temp_dir "tesl-pkg" "" in
  let paths = List.map (fun (name, content) -> write dir name content) files in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) paths;
      (try Sys.rmdir dir with _ -> ()))
    (fun () -> f dir)

let messages = function
  | Compile.GoFailure diagnostics ->
    String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)
  | Compile.GoSuccess _ -> ""

let test_folded_package_collision_refused () =
  with_project [
    ("foobar.tesl", {|module Foobar exposing [other, Rec]
import Tesl.Prelude exposing [Int, String]

record Rec {
  w: String
}

fn other() -> Int = 2
|});
    ("foo-bar.tesl", {|module FooBar exposing [answer, Rec]
import Tesl.Prelude exposing [Int, String]

record Rec {
  v: Int
}

fn answer() -> Int = 1
|});
    ("p10c.tesl", {|module P10c exposing [run]
import Tesl.Prelude exposing [Int, String, Bool(..)]
import FooBar exposing [answer]
import Foobar exposing [Rec]

fn run() -> Int = answer ()

fn mk() -> Rec = Rec { w: "x" }
|}) ] (fun dir ->
    match Compile.compile_go_file (Filename.concat dir "p10c.tesl") with
    | Compile.GoSuccess _ -> fail "two modules folding to one Go package were emitted"
    | failure ->
      let text = messages failure in
      if not (try ignore (Str.search_forward
                            (Str.regexp_string "all map to the Go package `teslmodfoobar`") text 0); true
              with Not_found -> false)
      then failf "unexpected diagnostic:\n%s" text)

let test_distinct_packages_still_compile () =
  with_project [
    ("alpha.tesl", {|module Alpha exposing [answer]
import Tesl.Prelude exposing [Int]

fn answer() -> Int = 1
|});
    ("consumer.tesl", {|module Consumer exposing [run]
import Tesl.Prelude exposing [Int]
import Alpha exposing [answer]

fn run() -> Int = answer ()
|}) ] (fun dir ->
    match Compile.compile_go_file (Filename.concat dir "consumer.tesl") with
    | Compile.GoSuccess _ -> ()
    | failure -> failf "distinct packages must compile:\n%s" (messages failure))

let test_underscore_field_is_exported () =
  with_project [
    ("vault.tesl", {|module Vault exposing [Box, mk]
import Tesl.Prelude exposing [Int, String]

record Box {
  _hidden: Int
  shown: String
}

fn mk() -> Box = Box { _hidden: 1, shown: "s" }
|});
    ("user.tesl", {|module User exposing [read]
import Tesl.Prelude exposing [Int, String]
import Vault exposing [Box, mk]

fn read() -> Int = (mk ())._hidden
|}) ] (fun dir ->
    match Compile.compile_go_file (Filename.concat dir "user.tesl") with
    | Compile.GoSuccess artifacts ->
      let vault = List.find_opt (fun (a : Emit_go.artifact) ->
          Filename.basename a.path = "module.go"
          && (try ignore (Str.search_forward (Str.regexp_string "type Box struct") a.contents 0); true
              with Not_found -> false)) artifacts in
      (match vault with
       | Some artifact ->
         if not (try ignore (Str.search_forward (Str.regexp_string "X_hidden") artifact.contents 0); true
                 with Not_found -> false)
         then failf "`_hidden` must become an exported Go field:\n%s" artifact.contents
       | None -> fail "no Box struct emitted")
    | failure -> failf "underscore field project must compile:\n%s" (messages failure))

let () =
  run "package-collision"
    [
      ( "packages",
        [ test_case "folded collision refused" `Quick test_folded_package_collision_refused;
          test_case "distinct packages compile" `Quick test_distinct_packages_still_compile;
          test_case "underscore field exported" `Quick test_underscore_field_is_exported ] );
    ]
