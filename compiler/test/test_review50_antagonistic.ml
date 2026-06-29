(** Antagonistic regression tests for Critical Review 50.

    Focus areas:
      - Proof soundness deeper edge cases (decompose + forget + reattach)
      - Pattern matching limitations (literals in nested positions, redundant arms)
      - Module system (file/module name mismatches, duplicate imports)
      - Codec mismatches (more cases beyond R49)
      - Tooling: formatter not idempotent on operators, lints
      - Capability propagation through indirect transactions
      - Exhaustiveness with parameterized ADTs
      - Negative literal parser footgun
      - Entity field proof predicate scope (not validated)
      - Record field proof predicate scope (not validated)
      - Misc small ergonomic / soundness concerns

    Test ID prefix conventions:
      R50_P  = Proof soundness
      R50_PM = Pattern matching / case-arm sanity
      R50_M  = Module / import / file naming
      R50_C  = Codec / serialization
      R50_T  = Type system
      R50_F  = Formatter / linter / tooling
      R50_E  = Effects / capabilities / transactions
      R50_X  = Parser / syntax
      R50_N  = New positive cases (regressions in good behavior)
      R50_O  = Other / misc

    A test is named with `_bug` suffix when it documents a current bug or
    soundness gap that the test deliberately accepts as PASSING — so that
    when the bug is fixed, the suite will start failing and forces
    explicit attention.
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

(* Place the source in a temp directory under the basename matching the
   module header (`test.tesl`), so the file-vs-module-name check passes.
   `prefix` and `suffix` are kept for API compatibility but the actual file
   is named after the module header it contains. *)
let with_temp_file _prefix _suffix content f =
  let dir = Filename.temp_dir "tesl-r50" "" in
  (* Pick a default name; callers whose module header is `module Test ...`
     get `test.tesl`. If we cannot infer the module header name we fall back
     to `test.tesl` — the test harness only ever uses `module Test` today. *)
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
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
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  write_file path content;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let with_temp_files files f =
  let dir = Filename.temp_dir "tesl-r50" "" in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (name, _) ->
        try Sys.remove (Filename.concat dir name) with _ -> ()) files;
      try Unix.rmdir dir with _ -> ())
    (fun () ->
      List.iter (fun (name, content) ->
        write_file (Filename.concat dir name) content) files;
      f dir)

let should_pass_src src =
  with_temp_file "tesl-r50" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r50" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, Bool(..), forgetFact, attachFact, detachFact]
import Tesl.Maybe exposing [Maybe(..)]
|}

let isPositive_decl = {|
fact IsPositive (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|}

let isEven_decl = {|
fact IsEven (n: Int)

check isEven(n: Int) -> n: Int ::: IsEven n =
  if n > 0 then
    ok n ::: IsEven n
  else
    fail 400 "not even"
|}

(* ═══════════════════════════════════════════════════════════════════════════
   PROOF SOUNDNESS
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R50_P01 — Fixed: decompose + forgetFact + reattach via ::: no longer
   lets the static checker smuggle a forgotten proof back onto the value.
   The conjunct `pa` binds only the left fact (IsPositive x), so the
   reattached value cannot satisfy an IsEven parameter. *)
let r50_p01_decompose_forget_reattach_bug () =
  should_fail_src "does not statically satisfy" (base_header ^ isPositive_decl ^ isEven_decl ^ {|
fn needsEven(n: Int ::: IsEven n) -> Int = n

fn bug(x: Int) -> Int =
  let a = check isPositive x
  let b = check isEven a
  let (_ ::: pa && _) = b
  let clean = forgetFact b
  let just = clean ::: pa
  needsEven just
|})

(* R50_P02 — control: forgetFact alone strips proofs correctly. *)
let r50_p02_forget_alone_strips () =
  should_fail_src "does not statically satisfy" (base_header ^ isPositive_decl ^ {|
fn needsPos(n: Int ::: IsPositive n) -> Int = n

fn t(x: Int) -> Int =
  let a = check isPositive x
  let clean = forgetFact a
  needsPos clean
|})

(* R50_P03 — Fixed: symmetric to R50_P01.  The right-hand conjunct `evenP`
   now carries only IsEven x, so reattaching it to a forgotten value cannot
   satisfy an IsPositive parameter. *)
let r50_p03_reattach_discarded_bug () =
  should_fail_src "does not statically satisfy" (base_header ^ isPositive_decl ^ isEven_decl ^ {|
fn needsPos(n: Int ::: IsPositive n) -> Int = n

fn bug(x: Int) -> Int =
  let a = check isPositive x
  let b = check isEven a
  let (_ ::: _ && evenP) = b
  let clean = forgetFact b
  let just = clean ::: evenP
  needsPos just
|})

(* R50_P04 — detachFact on a multi-proof value now yields the full composite Fact. *)
let r50_p04_detachfact_compound_fact_fixed () =
  should_pass_src (base_header ^ isPositive_decl ^ isEven_decl ^ {|
fn needBoth(n: Int, proof: Fact (IsPositive n && IsEven n)) -> Int =
  n

fn t(x: Int) -> Int =
  let a = check isPositive x
  let b = check isEven a
  let proof = detachFact b
  needBoth b proof
|})

(* R50_P05 — A function returning ::: ForAll without explicit subject hint. *)
let r50_p05_forall_param_no_subject_rejected () =
  should_fail_src "ForAll\\|subject" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.List exposing [List]

fact P (n: Int)

fn f(xs: List Int ::: ForAll P) -> Int = 0
|})

(* R50_P06 — ForAll on a non-list type is rejected. *)
let r50_p06_forall_on_int_rejected () =
  should_fail_src "ForAll\\|List\\|Set\\|Dict" (base_header ^ {|
fact P (n: Int)
fn f(n: Int ::: ForAll P n) -> Int = 0
|})

(* ═══════════════════════════════════════════════════════════════════════════
   PATTERN MATCHING
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R50_PM01 — Fixed: literal patterns inside a nested constructor pattern
   are now supported by the parser. *)
let r50_pm01_literal_in_nested_pattern_ok () =
  should_pass_src (base_header ^ {|
fn f(m: Maybe Int) -> String =
  case m of
    Nothing -> "n"
    Something 0 -> "z"
    Something _ -> "o"

fn g(m: Maybe String) -> Int =
  case m of
    Nothing -> 0
    Something "hi" -> 1
    Something _ -> 2
|})

(* R50_PM02 — Fixed: redundant duplicate constructor case arm now rejected. *)
let r50_pm02_duplicate_arm_rejected () =
  should_fail_src "duplicate case arm\\|already covered" (base_header ^ {|
type Color
  = Red
  | Green
  | Blue

fn name(c: Color) -> String =
  case c of
    Red -> "r"
    Green -> "g"
    Blue -> "b"
    Red -> "duplicate"
|})

(* R50_PM03 — Fixed: catch-all followed by literal arm is now rejected
   as unreachable code. *)
let r50_pm03_catchall_then_literal_rejected () =
  should_fail_src "unreachable\\|catch-all" (base_header ^ {|
fn name(n: Int) -> String =
  case n of
    _ -> "any"
    100 -> "one hundred"
|})

(* R50_PM04 — Fixed: duplicate literal arms now rejected. *)
let r50_pm04_duplicate_literal_rejected () =
  should_fail_src "duplicate case arm\\|already" (base_header ^ {|
fn name(n: Int) -> String =
  case n of
    100 -> "first"
    100 -> "second"
    _   -> "other"
|})

(* R50_PM05 — Different case branches may legitimately re-use a binder. *)
let r50_pm05_branch_binder_reuse_ok () =
  should_pass_src (base_header ^ {|
fn f(m: Maybe Int, n: Maybe String) -> Int =
  case m of
    Nothing ->
      case n of
        Nothing -> 0
        Something x -> 1
    Something x -> x
|})

(* R50_PM06 — Wildcard arm before final body arm does not lose
   exhaustiveness for ADTs (positive control). *)
let r50_pm06_adt_with_catchall_ok () =
  should_pass_src (base_header ^ {|
type Color
  = Red
  | Green
  | Blue

fn name(c: Color) -> String =
  case c of
    Red -> "r"
    _   -> "other"
|})

(* ═══════════════════════════════════════════════════════════════════════════
   MODULE / IMPORT SYSTEM
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R50_M01 — Fixed: a file declaring `module Bar` in `foo.tesl` is now
   rejected at the producer site. *)
let r50_m01_file_module_mismatch_rejected () =
  let src = {|#lang tesl
module Bar exposing []
import Tesl.Prelude exposing [Int]

fn x() -> Int = 1
|} in
  with_temp_files [("foo.tesl", src)] (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "foo.tesl"] in
    if code = 0 then failf "expected file-vs-module mismatch error, got success";
    let re = Str.regexp_case_fold "does not match file name\\|module header" in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected file/module mismatch error, got:\n%s" out)

(* R50_M02 — Importing the misnamed module fails with a file-not-found error
   even though the module exists. *)
let r50_m02_import_misnamed_module_fails () =
  let bar = {|#lang tesl
module Bar exposing [x]
import Tesl.Prelude exposing [Int]

fn x() -> Int = 1
|} in
  let main = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [Int]
import Bar exposing [x]

fn main() -> Int = x()
|} in
  with_temp_files [("foo.tesl", bar); ("main.tesl", main)] (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "main.tesl"] in
    if code = 0 then failf "expected import to fail, but it succeeded";
    let re = Str.regexp_case_fold "module.*not found\\|Bar.*not found" in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected file-not-found error, got:\n%s" out)

(* R50_M03 — Cyclic module imports are accepted (positive — works correctly). *)
let r50_m03_cyclic_imports_accepted () =
  let a = {|#lang tesl
module A exposing [a]
import Tesl.Prelude exposing [Int]
import B exposing [b]

fn a() -> Int = 1 + b()
|} in
  let b = {|#lang tesl
module B exposing [b]
import Tesl.Prelude exposing [Int]
import A exposing [a]

fn b() -> Int = 1 + a()
|} in
  with_temp_files [("a.tesl", a); ("b.tesl", b)] (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "a.tesl"] in
    if code <> 0 then failf "expected cyclic imports to compile, got:\n%s" out)

(* R50_M04 — Importing the same name twice from two modules. *)
let r50_m04_duplicate_imported_name_rejected () =
  let p = {|#lang tesl
module P exposing [foo]
import Tesl.Prelude exposing [Int]
fn foo() -> Int = 1
|} in
  let q = {|#lang tesl
module Q exposing [foo]
import Tesl.Prelude exposing [Int]
fn foo() -> Int = 2
|} in
  let main = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [Int]
import P exposing [foo]
import Q exposing [foo]

fn x() -> Int = foo()
|} in
  with_temp_files [("p.tesl", p); ("q.tesl", q); ("main.tesl", main)] (fun dir ->
    let code, out = run_compiler ["--check"; Filename.concat dir "main.tesl"] in
    if code = 0 then failf "expected duplicate import to fail, but it succeeded";
    let re = Str.regexp_case_fold "duplicate\\|conflict\\|already\\|exposed by multiple\\|multiple modules" in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected duplicate-import error, got:\n%s" out)

(* ═══════════════════════════════════════════════════════════════════════════
   CODECS
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R50_C01 — Cross-ADT codec mismatch is rejected. *)
let r50_c01_cross_adt_codec_rejected () =
  should_fail_src "different type\\|with_codec\\|references" (base_header ^ {|
type Priority
  = Low
  | Medium
  | High

type Status
  = Pending
  | Done

codec Priority { adtJson }
codec Status   { adtJson }

record Task { title: String, priority: Priority }

codec Task {
  toJson_forbidden
  fromJson [
    {
      title    <- "title"    with_codec stringCodec
      priority <- "priority" with_codec Status
    }
  ]
}
|})

(* R50_C02 — Bool field decoded as intCodec is rejected. *)
let r50_c02_intcodec_on_bool_rejected () =
  should_fail_src "intCodec.*decodes\\|boolCodec" (base_header ^ {|
record Task { title: String, flag: Bool }

codec Task {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
      flag  <- "flag"  with_codec intCodec
    }
  ]
}
|})

(* R50_C03 — Int field decoded as stringCodec is rejected. *)
let r50_c03_stringcodec_on_int_rejected () =
  should_fail_src "stringCodec.*decodes\\|intCodec" (base_header ^ {|
record Task { title: String, count: Int }

codec Task {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
      count <- "count" with_codec stringCodec
    }
  ]
}
|})

(* R50_C04 — `with_codec Status` requires a visible `codec Status { ... }`. *)
let r50_c04_codec_for_undeclared_type_rejected () =
  should_fail_src "NotARealCodec\\|codec\\|visible\\|references\\|unknown" (base_header ^ {|
type Priority
  = Low
  | High

codec Priority { adtJson }

record Task { title: String, priority: Priority }

codec Task {
  toJson_forbidden
  fromJson [
    {
      title    <- "title"    with_codec stringCodec
      priority <- "priority" with_codec NotARealCodec
    }
  ]
}
|})

(* ═══════════════════════════════════════════════════════════════════════════
   TYPE SYSTEM
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R50_T01 — Polymorphic identity function compiles. *)
let r50_t01_polymorphic_id_ok () =
  should_pass_src (base_header ^ {|
fn id(x: a) -> a = x

fn use_id() -> Int =
  let n = id 5
  let s = id "hi"
  n + 1
|})

(* R50_T02 — Recursive parameterized ADT compiles. *)
let r50_t02_recursive_polymorphic_adt () =
  should_pass_src (base_header ^ {|
type Tree a
  = Leaf
  | Node left:(Tree a) value:a right:(Tree a)

fn size(t: Tree Int) -> Int =
  case t of
    Leaf -> 0
    Node l _ r -> 1 + size(l) + size(r)
|})

(* R50_T03 — Constructor name colliding with type name is rejected. *)
let r50_t03_constructor_eq_type_rejected () =
  should_fail_src "same name" (base_header ^ {|
type Box a
  = Box value: a
|})

(* R50_T04 — `Bool` vs `Boolean` (Boolean is not a Tesl type alias). *)
let r50_t04_boolean_alias_rejected () =
  should_fail_src "Boolean\\|unknown" (base_header ^ {|
fn f(x: Boolean) -> Int = 0
|})

(* R50_T05 — Empty list literal does NOT vacuously satisfy ForAll proofs.
   This is an intentional design choice but documented here as a behavioral
   assertion (a future change to allow vacuous truth would break this test). *)
let r50_t05_empty_list_not_vacuously_forall () =
  should_fail_src "ForAll\\|does not statically" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.List exposing [List]

fact P (n: Int)

fn f(xs: List Int ::: ForAll P xs) -> Int = 0

fn use() -> Int =
  let xs = []
  f xs
|})

(* R50_T06 — Plain `Int` does not satisfy `PosixMillis`. *)
let r50_t06_int_vs_posix_millis_rejected () =
  should_fail_src "PosixMillis\\|cannot unify\\|expected" (base_header ^ {|
import Tesl.Time exposing [PosixMillis]

fn f(t: PosixMillis) -> Int = 0

fn g() -> Int =
  let n = 100
  f n
|})

(* ═══════════════════════════════════════════════════════════════════════════
   FORMATTER / LINTER
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R50_F01 — formatter normalises standalone `+` spacing. *)
let r50_f01_formatter_normalises_plus_fixed () =
  let src = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn add(x: Int, y: Int) -> Int = x+y
|} in
  with_temp_file "tesl-r50-fmt" ".tesl" src (fun path ->
    let _, _ = run_compiler ["--fmt"; path] in
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    let compact = Str.regexp_string "x+y" in
    let spaced = Str.regexp_string "x + y" in
    (try ignore (Str.search_forward compact content 0);
         failf "formatter left compact `x+y`. Content:
%s" content
     with Not_found -> ());
    try ignore (Str.search_forward spaced content 0)
    with Not_found ->
      failf "formatter did not normalise `x + y`. Content:
%s" content)

(* R50_F02 — formatter normalises standalone `<` and `>` spacing. *)
let r50_f02_formatter_normalises_lt_gt_fixed () =
  let src = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Bool(..)]

fn lt(a: Int, b: Int) -> Bool = a<b
fn gt(a: Int, b: Int) -> Bool = a>b
|} in
  with_temp_file "tesl-r50-fmt2" ".tesl" src (fun path ->
    let _, _ = run_compiler ["--fmt"; path] in
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    let compact_lt = Str.regexp_string "a<b" in
    let compact_gt = Str.regexp_string "a>b" in
    let spaced_lt = Str.regexp_string "a < b" in
    let spaced_gt = Str.regexp_string "a > b" in
    (try ignore (Str.search_forward compact_lt content 0);
         failf "formatter left compact `a<b`. Content:
%s" content
     with Not_found -> ());
    (try ignore (Str.search_forward compact_gt content 0);
         failf "formatter left compact `a>b`. Content:
%s" content
     with Not_found -> ());
    (try ignore (Str.search_forward spaced_lt content 0)
     with Not_found ->
       failf "formatter did not normalise `a < b`. Content:
%s" content);
    try ignore (Str.search_forward spaced_gt content 0)
    with Not_found ->
      failf "formatter did not normalise `a > b`. Content:
%s" content)

(* R50_F03 — formatter preserves `<-` decode arrows. *)
let r50_f03_formatter_preserves_decode_arrow () =
  let src = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

record ValueBody { value: Int }
codec ValueBody {
  toJson_forbidden
  fromJson [ { value<-"value" with_codec intCodec } ]
}
|} in
  with_temp_file "tesl-r50-fmt3" ".tesl" src (fun path ->
    let _, _ = run_compiler ["--fmt"; path] in
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    let broken = Str.regexp_string "value < - \"value\"" in
    let fixed = Str.regexp_string "value <- \"value\"" in
    (try ignore (Str.search_forward broken content 0);
         failf "formatter split `<-` into `< -`. Content:
%s" content
     with Not_found -> ());
    try ignore (Str.search_forward fixed content 0)
    with Not_found ->
      failf "formatter did not preserve `value <- \"value\"`. Content:
%s" content)

(* R50_F04 — formatter preserves `++` string concatenation. *)
let r50_f04_formatter_preserves_string_concat () =
  let src = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]

fn join(a: String, b: String) -> String = a++b
|} in
  with_temp_file "tesl-r50-fmt4" ".tesl" src (fun path ->
    let _, _ = run_compiler ["--fmt"; path] in
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    let broken = Str.regexp_string "a + + b" in
    let fixed = Str.regexp_string "a ++ b" in
    (try ignore (Str.search_forward broken content 0);
         failf "formatter split `++` into `+ +`. Content:
%s" content
     with Not_found -> ());
    try ignore (Str.search_forward fixed content 0)
    with Not_found ->
      failf "formatter did not preserve `a ++ b`. Content:
%s" content)

(* R50_F05 — Linter detects unused imports. *)
let r50_f05_linter_unused_import () =
  let src = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]

fn f(x: Int) -> Int = x + 1
|} in
  with_temp_file "tesl-r50-lint" ".tesl" src (fun path ->
    let _, out = run_compiler ["--lint"; path] in
    let re = Str.regexp_case_fold "unused\\|never referenced\\|W050" in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected unused-import lint, got:
%s" out)

(* ═══════════════════════════════════════════════════════════════════════════
   EFFECTS / CAPABILITIES / TRANSACTIONS
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R50_E01 — Indirect nested transaction is now rejected statically. *)
let r50_e01_indirect_nested_txn_rejected () =
  should_fail_src "transaction" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

entity User table "users" primaryKey id {
  id:   String
  name: String
}

database TestDB = Database {
  schema: "test"
  entities: [User]
  backend: Postgres (PostgresConfig {
    dbName: env "DB_NAME"
    user: env "DB_USER"
    password: env "DB_PASS"
    connection: TcpConnection { host: env "DB_HOST"  port: envInt "DB_PORT" 5432 }
  })
}

fn doInner(uid: String, n: String) -> Int
  requires [dbWrite] =
  transaction {
    let _ = insert User { id: uid, name: n }
    1
  }

fn doOuter(uid: String, n: String) -> Int
  requires [dbWrite] =
  transaction {
    let _ = insert User { id: uid, name: n }
    doInner uid n
  }
|})

(* R50_E02 — Direct nested `transaction` IS rejected. *)
let r50_e02_direct_nested_txn_rejected () =
  should_fail_src "transaction" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

entity User table "users" primaryKey id {
  id:   String
  name: String
}

database TestDB = Database {
  schema: "test"
  entities: [User]
  backend: Postgres (PostgresConfig {
    dbName: env "DB_NAME"
    user: env "DB_USER"
    password: env "DB_PASS"
    connection: TcpConnection { host: env "DB_HOST"  port: envInt "DB_PORT" 5432 }
  })
}

fn doNested(uid: String, n: String) -> Int requires [dbWrite] =
  transaction {
    transaction {
      let _ = insert User { id: uid, name: n }
      1
    }
  }
|})

(* R50_E03 — Calling a function that requires a capability without declaring
   it transitively is rejected. *)
let r50_e03_transitive_capability_required () =
  should_fail_src "requires\\|cap\\|dbWrite" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead, dbWrite]

fn writer() -> Int requires [dbWrite] = 1

fn reader() -> Int requires [dbRead] =
  writer()
|})

(* ═══════════════════════════════════════════════════════════════════════════
   PARSER / SYNTAX
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R50_X01 — Negative-literal-as-argument footgun.
   `f -3 -4` parses as `f - 3 - 4` and fails with a cryptic type error. *)
let r50_x01_negative_arg_footgun_bug () =
  should_fail_src "cannot unify\\|type\\|mismatch" (base_header ^ {|
fn f(a: Int, b: Int) -> Int = a + b

fn g() -> Int =
  f -3 -4
|})

(* R50_X02 — Single-line `if/then/else` is rejected by design. *)
let r50_x02_single_line_if_rejected () =
  should_fail_src "single-line\\|then body" (base_header ^ {|
fn f(n: Int) -> Int =
  if n > 0 then 1 else 2
|})

(* R50_X03 — Receiver-style `value.method` syntax is rejected. *)
let r50_x03_receiver_style_rejected () =
  should_fail_src "receiver\\|receiver-style\\|unknown\\|field" (base_header ^ {|
import Tesl.String exposing [String.length]

fn f(s: String) -> Int = s.length
|})

(* R50_X04 — Unary minus on a variable IS accepted (positive control). *)
let r50_x04_unary_minus_on_var_ok () =
  should_pass_src (base_header ^ {|
fn neg(x: Int) -> Int =
  let y = -x
  y
|})

(* ═══════════════════════════════════════════════════════════════════════════
   ENTITY / RECORD PROOF SCOPE
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R50_O01 — Fixed in review 50 follow-up: a record field referencing an
   undeclared proof predicate is now rejected at the declaration site. *)
let r50_o01_record_field_undecl_proof_fixed () =
  should_fail_src "not in scope\\|proof predicate" (base_header ^ {|
record Item {
  title: String ::: NotDeclaredAnywhere title
}
|})

(* R50_O02 — Fixed in review 50 follow-up: the same check fires for
   entity fields. *)
let r50_o02_entity_field_undecl_proof_fixed () =
  should_fail_src "not in scope\\|proof predicate" (base_header ^ {|
entity Item table "items" primaryKey id {
  id:    String
  title: String ::: NotDeclaredAnywhere title
}
|})

(* R50_O03 — Function parameter with undeclared proof IS rejected (positive
   control showing the asymmetry with R50_O01 and R50_O02). *)
let r50_o03_param_undecl_proof_rejected () =
  should_fail_src "not in scope\\|proof predicate" (base_header ^ {|
fn f(n: Int ::: NotDeclaredAnywhere n) -> Int = n
|})

(* R50_O04 — Constructor application with proof-bearing field via literal
   IS rejected at the construction site. *)
let r50_o04_record_construction_rejects_unproven () =
  should_fail_src "requires proof\\|proof" (base_header ^ {|
fact TitleSafe (s: String)

record Item {
  title: String ::: TitleSafe title
}

fn make() -> Item =
  Item { title: "hello" }
|})

(* ═══════════════════════════════════════════════════════════════════════════
   TEST REGISTRATION
   ═══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "Review50-Antagonistic" [
    "proof-soundness", [
      test_case "R50_P01 decompose+forget+reattach rejected (FIXED)"           `Quick r50_p01_decompose_forget_reattach_bug;
      test_case "R50_P02 forgetFact alone strips proofs"                       `Quick r50_p02_forget_alone_strips;
      test_case "R50_P03 reattach discarded conjunct (BUG)"                    `Quick r50_p03_reattach_discarded_bug;
      test_case "R50_P04 detachFact preserves compound Fact (FIXED)"          `Quick r50_p04_detachfact_compound_fact_fixed;
      test_case "R50_P05 ForAll on param without subject rejected"             `Quick r50_p05_forall_param_no_subject_rejected;
      test_case "R50_P06 ForAll on Int rejected"                               `Quick r50_p06_forall_on_int_rejected;
    ];
    "pattern-matching", [
      test_case "R50_PM01 literal in nested pattern OK (FIXED)"               `Quick r50_pm01_literal_in_nested_pattern_ok;
      test_case "R50_PM02 duplicate constructor arm rejected (FIXED)"         `Quick r50_pm02_duplicate_arm_rejected;
      test_case "R50_PM03 catch-all-then-literal rejected (FIXED)"            `Quick r50_pm03_catchall_then_literal_rejected;
      test_case "R50_PM04 duplicate literal arms rejected (FIXED)"            `Quick r50_pm04_duplicate_literal_rejected;
      test_case "R50_PM05 branch binder reuse OK"                              `Quick r50_pm05_branch_binder_reuse_ok;
      test_case "R50_PM06 ADT case with catch-all OK"                          `Quick r50_pm06_adt_with_catchall_ok;
    ];
    "module-system", [
      test_case "R50_M01 file/module name mismatch rejected (FIXED)"          `Quick r50_m01_file_module_mismatch_rejected;
      test_case "R50_M02 import misnamed module fails"                         `Quick r50_m02_import_misnamed_module_fails;
      test_case "R50_M03 cyclic imports accepted"                              `Quick r50_m03_cyclic_imports_accepted;
      test_case "R50_M04 duplicate imported name rejected"                     `Quick r50_m04_duplicate_imported_name_rejected;
    ];
    "codecs", [
      test_case "R50_C01 cross-ADT codec rejected"                             `Quick r50_c01_cross_adt_codec_rejected;
      test_case "R50_C02 intCodec on Bool rejected"                            `Quick r50_c02_intcodec_on_bool_rejected;
      test_case "R50_C03 stringCodec on Int rejected"                          `Quick r50_c03_stringcodec_on_int_rejected;
      test_case "R50_C04 codec for undeclared type rejected"                   `Quick r50_c04_codec_for_undeclared_type_rejected;
    ];
    "type-system", [
      test_case "R50_T01 polymorphic id OK"                                    `Quick r50_t01_polymorphic_id_ok;
      test_case "R50_T02 recursive polymorphic ADT OK"                         `Quick r50_t02_recursive_polymorphic_adt;
      test_case "R50_T03 constructor=type rejected"                            `Quick r50_t03_constructor_eq_type_rejected;
      test_case "R50_T04 Boolean alias rejected"                               `Quick r50_t04_boolean_alias_rejected;
      test_case "R50_T05 empty list NOT vacuously ForAll"                      `Quick r50_t05_empty_list_not_vacuously_forall;
      test_case "R50_T06 Int not PosixMillis"                                  `Quick r50_t06_int_vs_posix_millis_rejected;
    ];
    "formatter-linter", [
      test_case "R50_F01 formatter normalises + (FIXED)"                    `Quick r50_f01_formatter_normalises_plus_fixed;
      test_case "R50_F02 formatter normalises < and > (FIXED)"              `Quick r50_f02_formatter_normalises_lt_gt_fixed;
      test_case "R50_F03 formatter preserves <-"                            `Quick r50_f03_formatter_preserves_decode_arrow;
      test_case "R50_F04 formatter preserves ++"                            `Quick r50_f04_formatter_preserves_string_concat;
      test_case "R50_F05 linter detects unused import"                      `Quick r50_f05_linter_unused_import;
    ];
    "effects-capabilities", [
      test_case "R50_E01 indirect nested txn rejected (FIXED)"               `Quick r50_e01_indirect_nested_txn_rejected;
      test_case "R50_E02 direct nested txn rejected"                           `Quick r50_e02_direct_nested_txn_rejected;
      test_case "R50_E03 transitive capability required"                       `Quick r50_e03_transitive_capability_required;
    ];
    "parser-syntax", [
      test_case "R50_X01 negative arg footgun (BUG)"                           `Quick r50_x01_negative_arg_footgun_bug;
      test_case "R50_X02 single-line if rejected"                              `Quick r50_x02_single_line_if_rejected;
      test_case "R50_X03 receiver-style rejected"                              `Quick r50_x03_receiver_style_rejected;
      test_case "R50_X04 unary minus on var OK"                                `Quick r50_x04_unary_minus_on_var_ok;
    ];
    "proof-scope-asymmetry", [
      test_case "R50_O01 record field undecl proof rejected (FIXED)"          `Quick r50_o01_record_field_undecl_proof_fixed;
      test_case "R50_O02 entity field undecl proof rejected (FIXED)"          `Quick r50_o02_entity_field_undecl_proof_fixed;
      test_case "R50_O03 param undecl proof rejected (positive control)"       `Quick r50_o03_param_undecl_proof_rejected;
      test_case "R50_O04 record construction rejects unproven literal"         `Quick r50_o04_record_construction_rejects_unproven;
    ];
  ]
