(** Antagonistic regression tests for Critical Review 44.

    Focus: ADT import and pattern soundness.

    R44_01  Local exhaustive ADT case still compiles
    R44_02  Imported exhaustive ADT case still compiles
    R44_03  Local bogus extra nullary constructor arm is rejected
    R44_04  Local bogus-only nullary constructor arm is rejected
    R44_05  Imported bogus extra nullary constructor arm is rejected
    R44_06  Imported bogus-only nullary constructor arm is rejected
    R44_07  `Nothing` on non-Maybe local ADT is rejected
    R44_08  `Something` on non-Maybe local ADT is rejected
    R44_09  `Nothing` on non-Maybe imported ADT is rejected
    R44_10  `Something` on non-Maybe imported ADT is rejected
    R44_11  Local bogus extra fielded constructor arm is rejected
    R44_12  Imported bogus extra fielded constructor arm is rejected
    R44_13  Duplicate imported plain type names are rejected
    R44_14  Duplicate imported Type(..) names are rejected
    R44_15  Duplicate imported constructor names are rejected
    R44_16  Local type shadows imported plain type is rejected
    R44_17  Local type shadows imported Type(..) is rejected
    R44_18  Local constructor shadows imported constructor is rejected
    R44_19  Qualified-only import does not poison local type namespace
    R44_20  Qualified-only import does not poison local constructor namespace
    R44_21  Distinct imported type names still compile
    R44_22  Distinct imported constructors still compile
    R44_23  Imported type plus unrelated local type still compiles
    R44_24  Imported constructor plus unrelated local constructor still compiles
*)

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
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_file prefix suffix content f =
  let path = Filename.temp_file prefix suffix in
  write_file path content;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let ensure_parent path =
  let parent = Filename.dirname path in
  if parent <> path && not (Sys.file_exists parent) then Unix.mkdir parent 0o755

let with_temp_project files f =
  let dir = Filename.temp_file "tesl-r44-proj" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  List.iter (fun (rel, content) ->
    let path = Filename.concat dir rel in
    ensure_parent path;
    write_file path content
  ) files;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () -> f dir)

let should_pass_src src =
  with_temp_file "tesl-r44" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:
%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r44" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:
%s" pattern out)

let should_pass_project files =
  with_temp_project files (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "Main.tesl"] in
    if code <> 0 then failf "expected compilation success, got:
%s" out)

let should_fail_project pattern files =
  with_temp_project files (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "Main.tesl"] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:
%s" pattern out)

let imported_foo_src = {|#lang tesl
module A exposing [Foo(..)]
type Foo =
  | MkFoo
  | MkBar
|}

let imported_fielded_src = {|#lang tesl
module A exposing [Box(..)]
import Tesl.Prelude exposing [Int]
type Box =
  | Wrap inner: Int
  | Empty
|}

let plain_type_a_src = {|#lang tesl
module A exposing [Foo]
type Foo =
  | MkFoo
|}

let plain_type_b_src = {|#lang tesl
module B exposing [Foo]
type Foo =
  | MkBar
|}

let adt_type_a_src = {|#lang tesl
module A exposing [Foo(..)]
type Foo =
  | MkFoo
|}

let adt_type_b_src = {|#lang tesl
module B exposing [Foo(..)]
type Foo =
  | MkBar
|}

let ctor_a_src = {|#lang tesl
module A exposing [Foo(..)]
type Foo =
  | Shared
|}

let ctor_b_src = {|#lang tesl
module B exposing [Bar(..)]
type Bar =
  | Shared
|}

let distinct_type_b_src = {|#lang tesl
module B exposing [Bar]
type Bar =
  | MkBar
|}

let distinct_ctor_b_src = {|#lang tesl
module B exposing [Bar(..)]
type Bar =
  | MkBar
|}

let r44_01_local_exhaustive_case_passes () =
  should_pass_src {|#lang tesl
module Main exposing [Foo(..), value]
type Foo =
  | MkFoo
  | MkBar
fn value(x: Foo) -> Foo =
  case x of
    MkFoo -> MkBar
    MkBar -> MkFoo
|}

let r44_02_imported_exhaustive_case_passes () =
  should_pass_project [
    ("A.tesl", imported_foo_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Foo(..)]
fn value(x: Foo) -> Foo =
  case x of
    MkFoo -> MkBar
    MkBar -> MkFoo
|});
  ]

let r44_03_local_bogus_extra_nullary_arm_rejected () =
  should_fail_src "unknown constructor" {|#lang tesl
module Main exposing [Foo(..), value]
type Foo =
  | MkFoo
  | MkBar
fn value(x: Foo) -> Foo =
  case x of
    MkFoo -> MkBar
    MkBar -> MkFoo
    DefinitelyNotFoo -> MkFoo
|}

let r44_04_local_bogus_only_nullary_arm_rejected () =
  should_fail_src "unknown constructor" {|#lang tesl
module Main exposing [Foo(..), value]
type Foo =
  | MkFoo
  | MkBar
fn value(x: Foo) -> Foo =
  case x of
    DefinitelyNotFoo -> MkFoo
|}

let r44_05_imported_bogus_extra_nullary_arm_rejected () =
  should_fail_project "unknown constructor" [
    ("A.tesl", imported_foo_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Foo(..)]
fn value(x: Foo) -> Foo =
  case x of
    MkFoo -> MkBar
    MkBar -> MkFoo
    DefinitelyNotFoo -> MkFoo
|});
  ]

let r44_06_imported_bogus_only_nullary_arm_rejected () =
  should_fail_project "unknown constructor" [
    ("A.tesl", imported_foo_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Foo(..)]
fn value(x: Foo) -> Foo =
  case x of
    DefinitelyNotFoo -> MkFoo
|});
  ]

let r44_07_nothing_on_non_maybe_local_rejected () =
  should_fail_src "unknown constructor" {|#lang tesl
module Main exposing [Foo(..), value]
type Foo =
  | MkFoo
fn value(x: Foo) -> Foo =
  case x of
    MkFoo -> MkFoo
    Nothing -> MkFoo
|}

let r44_08_something_on_non_maybe_local_rejected () =
  should_fail_src "unknown constructor" {|#lang tesl
module Main exposing [Box(..), value]
import Tesl.Prelude exposing [Int]
type Box =
  | Wrap inner: Int
  | Empty
fn value(x: Box) -> Box =
  case x of
    Wrap n -> Wrap n
    Empty -> Empty
    Something y -> Wrap y
|}

let r44_09_nothing_on_non_maybe_imported_rejected () =
  should_fail_project "unknown constructor" [
    ("A.tesl", imported_foo_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Foo(..)]
fn value(x: Foo) -> Foo =
  case x of
    MkFoo -> MkFoo
    MkBar -> MkBar
    Nothing -> MkFoo
|});
  ]

let r44_10_something_on_non_maybe_imported_rejected () =
  should_fail_project "unknown constructor" [
    ("A.tesl", imported_fielded_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Box(..)]
fn value(x: Box) -> Box =
  case x of
    Wrap n -> Wrap n
    Empty -> Empty
    Something y -> Wrap y
|});
  ]

let r44_11_local_bogus_extra_fielded_arm_rejected () =
  should_fail_src "unknown constructor" {|#lang tesl
module Main exposing [Box(..), value]
import Tesl.Prelude exposing [Int]
type Box =
  | Wrap inner: Int
  | Empty
fn value(x: Box) -> Box =
  case x of
    Wrap n -> Wrap n
    Empty -> Empty
    Ghost y -> Wrap y
|}

let r44_12_imported_bogus_extra_fielded_arm_rejected () =
  should_fail_project "unknown constructor" [
    ("A.tesl", imported_fielded_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Box(..)]
fn value(x: Box) -> Box =
  case x of
    Wrap n -> Wrap n
    Empty -> Empty
    Ghost y -> Wrap y
|});
  ]

let r44_13_duplicate_imported_plain_type_names_rejected () =
  should_fail_project "imported type" [
    ("A.tesl", plain_type_a_src);
    ("B.tesl", plain_type_b_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Foo]
import B exposing [Foo]
fn value(x: Foo) -> Foo = x
|});
  ]

let r44_14_duplicate_imported_type_dotdot_names_rejected () =
  should_fail_project "imported type" [
    ("A.tesl", adt_type_a_src);
    ("B.tesl", adt_type_b_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Foo(..)]
import B exposing [Foo(..)]
fn value() -> Foo = MkBar
|});
  ]

let r44_15_duplicate_imported_constructor_names_rejected () =
  should_fail_project "imported constructor" [
    ("A.tesl", ctor_a_src);
    ("B.tesl", ctor_b_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Foo(..)]
import B exposing [Bar(..)]
fn value(x: Bar) -> Bar =
  case x of
    Shared -> Shared
|});
  ]

let r44_16_local_type_shadows_imported_plain_type_rejected () =
  should_fail_project "top-level type" [
    ("A.tesl", plain_type_a_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [Foo(..), value]
import A exposing [Foo]
type Foo =
  | LocalFoo
fn value(x: Foo) -> Foo = x
|});
  ]

let r44_17_local_type_shadows_imported_dotdot_type_rejected () =
  should_fail_project "top-level type" [
    ("A.tesl", adt_type_a_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [Foo(..), value]
import A exposing [Foo(..)]
type Foo =
  | LocalFoo
fn value(x: Foo) -> Foo = x
|});
  ]

let r44_18_local_constructor_shadows_imported_constructor_rejected () =
  should_fail_project "shadows imported constructor" [
    ("A.tesl", {|#lang tesl
module A exposing [Imported(..)]
type Imported =
  | Shared
|});
    ("Main.tesl", {|#lang tesl
module Main exposing [Local(..), value]
import A exposing [Imported(..)]
type Local =
  | Shared
fn value() -> Local = Shared
|});
  ]

let r44_19_qualified_only_import_does_not_poison_type_namespace () =
  should_pass_project [
    ("A.tesl", plain_type_a_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [Foo(..), value]
import A
type Foo =
  | LocalFoo
fn value(x: Foo) -> Foo = x
|});
  ]

let r44_20_qualified_only_import_does_not_poison_constructor_namespace () =
  should_pass_project [
    ("A.tesl", {|#lang tesl
module A exposing [Imported(..)]
type Imported =
  | Shared
|});
    ("Main.tesl", {|#lang tesl
module Main exposing [Local(..), value]
import A
type Local =
  | Shared
fn value() -> Local = Shared
|});
  ]

let r44_21_distinct_imported_type_names_compile () =
  should_pass_project [
    ("A.tesl", plain_type_a_src);
    ("B.tesl", distinct_type_b_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Foo]
import B exposing [Bar]
fn value(x: Foo) -> Foo = x
|});
  ]

let r44_22_distinct_imported_constructors_compile () =
  should_pass_project [
    ("A.tesl", adt_type_a_src);
    ("B.tesl", distinct_ctor_b_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [value]
import A exposing [Foo(..)]
import B exposing [Bar(..)]
fn value() -> Bar = MkBar
|});
  ]

let r44_23_imported_type_plus_unrelated_local_type_compile () =
  should_pass_project [
    ("A.tesl", plain_type_a_src);
    ("Main.tesl", {|#lang tesl
module Main exposing [Local(..), value]
import A exposing [Foo]
type Local =
  | LocalFoo
fn value(x: Foo) -> Foo = x
|});
  ]

let r44_24_imported_constructor_plus_unrelated_local_constructor_compile () =
  should_pass_project [
    ("A.tesl", {|#lang tesl
module A exposing [Imported(..)]
type Imported =
  | Shared
|});
    ("Main.tesl", {|#lang tesl
module Main exposing [Local(..), value]
import A exposing [Imported(..)]
type Local =
  | LocalShared
fn value() -> Local = LocalShared
|});
  ]

let () =
  run "Review44-Antagonistic" [
    ("adt import and pattern soundness", [
      test_case "R44_01 local exhaustive ADT case passes" `Quick r44_01_local_exhaustive_case_passes;
      test_case "R44_02 imported exhaustive ADT case passes" `Quick r44_02_imported_exhaustive_case_passes;
      test_case "R44_03 local bogus extra nullary arm rejected" `Quick r44_03_local_bogus_extra_nullary_arm_rejected;
      test_case "R44_04 local bogus-only nullary arm rejected" `Quick r44_04_local_bogus_only_nullary_arm_rejected;
      test_case "R44_05 imported bogus extra nullary arm rejected" `Quick r44_05_imported_bogus_extra_nullary_arm_rejected;
      test_case "R44_06 imported bogus-only nullary arm rejected" `Quick r44_06_imported_bogus_only_nullary_arm_rejected;
      test_case "R44_07 Nothing on non-Maybe local ADT rejected" `Quick r44_07_nothing_on_non_maybe_local_rejected;
      test_case "R44_08 Something on non-Maybe local ADT rejected" `Quick r44_08_something_on_non_maybe_local_rejected;
      test_case "R44_09 Nothing on non-Maybe imported ADT rejected" `Quick r44_09_nothing_on_non_maybe_imported_rejected;
      test_case "R44_10 Something on non-Maybe imported ADT rejected" `Quick r44_10_something_on_non_maybe_imported_rejected;
      test_case "R44_11 local bogus extra fielded arm rejected" `Quick r44_11_local_bogus_extra_fielded_arm_rejected;
      test_case "R44_12 imported bogus extra fielded arm rejected" `Quick r44_12_imported_bogus_extra_fielded_arm_rejected;
      test_case "R44_13 duplicate imported plain type names rejected" `Quick r44_13_duplicate_imported_plain_type_names_rejected;
      test_case "R44_14 duplicate imported Type(..) names rejected" `Quick r44_14_duplicate_imported_type_dotdot_names_rejected;
      test_case "R44_15 duplicate imported constructor names rejected" `Quick r44_15_duplicate_imported_constructor_names_rejected;
      test_case "R44_16 local type shadows imported plain type rejected" `Quick r44_16_local_type_shadows_imported_plain_type_rejected;
      test_case "R44_17 local type shadows imported Type(..) rejected" `Quick r44_17_local_type_shadows_imported_dotdot_type_rejected;
      test_case "R44_18 local constructor shadows imported constructor rejected" `Quick r44_18_local_constructor_shadows_imported_constructor_rejected;
      test_case "R44_19 qualified-only import does not poison type namespace" `Quick r44_19_qualified_only_import_does_not_poison_type_namespace;
      test_case "R44_20 qualified-only import does not poison constructor namespace" `Quick r44_20_qualified_only_import_does_not_poison_constructor_namespace;
      test_case "R44_21 distinct imported type names compile" `Quick r44_21_distinct_imported_type_names_compile;
      test_case "R44_22 distinct imported constructors compile" `Quick r44_22_distinct_imported_constructors_compile;
      test_case "R44_23 imported type plus unrelated local type compile" `Quick r44_23_imported_type_plus_unrelated_local_type_compile;
      test_case "R44_24 imported constructor plus unrelated local constructor compile" `Quick r44_24_imported_constructor_plus_unrelated_local_constructor_compile;
    ])
  ]
