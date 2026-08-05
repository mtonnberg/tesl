(** Bare stdlib CONSTRUCTORS are import-gated
    (roadmap/completed/import_gated_stdlib_constructors.md, found while landing #78).

    Before this, a stdlib ADT constructor resolved in a module that never
    imported its module, `tesl check` said nothing, and the emitted Racket could
    not load:

      case Monday of Monday -> True; _ -> False     # no import Tesl.CivilTime
      $ tesl check noimport.tesl        → 0 errors
      $ raco expand noimport.rkt        → Monday: unbound identifier

    The cause was not a missing gate but a hole in one gate's INPUT:
    `collect_stdlib_fn_uses` dropped every name absent from the home-module
    registry, and that registry (built from the DOTTED export rows) had no
    constructor rows at all.  Constructors got their types from `stdlib_env`, a
    flat global namespace with no import in it, so the name type-checked and
    nothing ever asked where it came from.

    What this file pins
    ------------------------------------------------------------------------
    1. THE REPRO, in the shape the issue reported it, and the FUNCTION case's
       diagnostic as the model to match (it names the import to add).
    2. THE EXPOSING RULE.  `Weekday(..)` brings the constructors; `Weekday`
       alone does not; naming the constructor directly also works; a plain
       `import Tesl.CivilTime` works.  All four spellings were checked against
       `raco expand` when the gate was written — the ACCEPTING ones must really
       emit the require, which tests/stdlib-bare-name-gate.sh re-verifies.
    3. NO FALSE POSITIVES on the three shapes that look like the bug:
       - a module that DECLARES its own ADT with the same constructor names
         (learn lesson37 declares `Either`/`Left`/`Right`; declaring is not
         importing, and only declare+import is shadowing);
       - a module qualifier, which parses as a nullary constructor
         (`Dict.lookup` must not demand an import for a value named `Dict`);
       - a constructor used ONLY in a pattern still needs its import (one rule
         everywhere — see below), but a module that satisfies it with the type
         family form must stay clean.
    4. THE SINGLE SOURCE.  Four consumers used to hand-list stdlib ADT
       constructor groups; three are now derived from
       `Type_system.stdlib_adt_ctor_groups`, and the fourth
       (`Validation_common.builtin_ctor_info`, which needs field types) is
       asserted to COVER it — so a new stdlib ADT cannot be gated without also
       being exhaustiveness-checked, or vice versa. *)

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

let failf fmt = Printf.ksprintf failwith fmt

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code =
    match st with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

(* The file name fixes the module header (`module Gated`). *)
let with_source src f =
  let dir = Filename.temp_dir "tesl-gated-ctors" "" in
  let path = Filename.concat dir "gated.tesl" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let check src = with_source src (fun p -> run_cc ["--check"; p])

let should_pass label src =
  let code, out = check src in
  if code <> 0 then
    failf "%s: expected a clean check, got exit %d:\n%s" label code out

let should_fail label ~expect src =
  let code, out = check src in
  if code = 0 then failf "%s: expected REJECTION, but the check passed" label;
  if not (contains out expect) then
    failf "%s: rejected, but not for the expected reason (wanted %S):\n%s"
      label expect out

(* ── 1. The repro ─────────────────────────────────────────────────────────── *)

let noimport_src = {|module Gated exposing [f]

import Tesl.Prelude exposing [Bool(..), Int]

fn f(n: Int) -> Bool =
  case Monday of
    Monday -> True
    _ -> False
|}

let t_repro_rejected () =
  should_fail "repro" ~expect:"constructor `Monday` requires `import Tesl.CivilTime`"
    noimport_src

let t_repro_names_the_exposing_form () =
  (* The FUNCTION case is the model: it names both spellings that would fix it.
     For a constructor the exposing spelling is the OWNING TYPE with `(..)`, not
     the constructor, because that is the form a reader writes. *)
  let _, out = check noimport_src in
  if not (contains out "import Tesl.CivilTime exposing [Weekday(..)]") then
    failf "the diagnostic must name the exposing form that fixes it:\n%s" out

let t_function_case_still_the_model () =
  should_fail "function case"
    ~expect:"function `Money.usd` requires `import Tesl.Money`"
    {|module Gated exposing [f]

import Tesl.Prelude exposing [String]

fn f() -> String =
  Money.currencyCode (Money.usd 100)
|}

(* ── 2. The exposing rule ─────────────────────────────────────────────────── *)

let with_import imp = Printf.sprintf {|module Gated exposing [f]

import Tesl.Prelude exposing [Bool(..), Int]
%s

fn f(n: Int) -> Bool =
  case Monday of
    Monday -> True
    _ -> False
|} imp

let t_type_dotdot_exposes_ctors () =
  should_pass "Weekday(..)" (with_import "import Tesl.CivilTime exposing [Weekday(..)]")

let t_ctor_named_directly () =
  should_pass "exposing [Monday]" (with_import "import Tesl.CivilTime exposing [Monday]")

let t_import_all () =
  should_pass "import all" (with_import "import Tesl.CivilTime")

let t_bare_type_does_not_expose_ctors () =
  should_fail "Weekday alone"
    ~expect:"is not in the exposing list"
    (with_import "import Tesl.CivilTime exposing [Weekday]")

let t_multi_home_ctor () =
  (* `Left`/`Right` are exported by BOTH Tesl.Either and Tesl.EitherPrim (the
     lifted-module split that breaks the require cycle).  Importing EITHER one
     satisfies the reference — tesl/either.tesl itself imports only the prim. *)
  should_pass "EitherPrim" {|module Gated exposing [f]

import Tesl.Prelude exposing [Int, String]
import Tesl.EitherPrim exposing [Either(..)]

fn f(n: Int) -> Either String Int =
  Right n
|}

let t_multi_home_error_lists_both () =
  let _, out = check {|module Gated exposing [f]

import Tesl.Prelude exposing [Int, String]

fn f(n: Int) -> Either String Int =
  Right n
|} in
  if not (contains out "also exported by") then
    failf "a constructor with two home modules must name both:\n%s" out

(* ── 3. No false positives ────────────────────────────────────────────────── *)

let t_local_adt_shadow_is_not_gated () =
  (* learn lesson37: a module declaring its own Either/Left/Right imports no
     calendar or either module and must stay clean. *)
  should_pass "local ADT" {|module Gated exposing [f]

import Tesl.Prelude exposing [Bool(..), Int, String]

type Either a b
  = Left value: a
  | Right value: b

fn f(n: Int) -> Either String Int =
  Right n
|}

let t_local_weekday_is_not_gated () =
  should_pass "local Weekday" {|module Gated exposing [f]

import Tesl.Prelude exposing [Bool(..), Int]

type Weekday =
  | Monday
  | Tuesday

fn f(n: Int) -> Bool =
  case Monday of
    Monday -> True
    _ -> False
|}

let t_module_qualifier_is_not_gated () =
  (* `Dict` in `Dict.lookup` parses as a nullary constructor; the gate must see a
     QUALIFIER, not a value.  (The qualified name itself is gated by the function
     rule, which the import below satisfies.) *)
  should_pass "qualifier" {|module Gated exposing [f]

import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict, Dict.lookup]
import Tesl.Maybe exposing [Maybe]

fn f(d: Dict String Int) -> Maybe Int =
  Dict.lookup "k" d
|}

let pattern_only_src imp = Printf.sprintf {|module Gated exposing [f]

import Tesl.Prelude exposing [Bool(..), String]
%s

fn f(d: CivilDate) -> Bool =
  case CivilTime.weekday d of
    Monday -> True
    _ -> False
|} imp

let t_pattern_position_is_gated () =
  (* A pattern needs no runtime binding — it emits `(eq? (adt-value-variant …)
     'Monday)`, a quoted symbol — so this half of the rule is not about
     unboundness.  It is about the rule being ONE rule: a module that names a
     stdlib constructor says where it came from, so the import list stays a
     complete inventory of the stdlib surface the module uses. *)
  should_fail "pattern only, no ctor import"
    ~expect:"constructor `Monday` requires `import Tesl.CivilTime`"
    (pattern_only_src
       "import Tesl.CivilTime exposing [CivilDate, Weekday, CivilTime.weekday]")

let t_pattern_position_satisfied_by_family_form () =
  should_pass "pattern only, Weekday(..)"
    (pattern_only_src
       "import Tesl.CivilTime exposing [CivilDate, Weekday(..), CivilTime.weekday]")

let t_prelude_literals_need_no_import () =
  should_pass "True/False/Unit" {|module Gated exposing [f]

import Tesl.Prelude exposing [Bool(..), Int]

fn f(n: Int) -> Bool =
  True
|}

(* ── 3b. Every reference position ─────────────────────────────────────────── *)

(* "Referenced in any way" means every position, not just the one the issue
   happened to report.  These are the shapes a fix that only walked `case`
   scrutinees would miss: a `let` value, an `if` branch, a list element, a record
   field, a lambda body, a `case` GUARD, a nested sub-pattern, a test-block
   statement, and a top-level binding.  Each one is asserted independently, so a
   future narrowing of the fold fails here rather than reopening the hole in one
   corner of the grammar. *)

let positions =
  [ ( "let value",
      {|fn f(n: Int) -> Bool =
  let x = Nothing
  True|} );
    ( "if branch",
      {|fn f(n: Int) -> Bool =
  if n > 0 then
    case Something n of
      _ -> True
  else
    True|} );
    ( "list element",
      {|fn f(n: Int) -> Bool =
  case [Nothing] of
    _ -> True|} );
    ( "record field",
      {|record R { v: Maybe Int }

fn f(n: Int) -> Bool =
  case R { v: Nothing } of
    _ -> True|} );
    ( "lambda body",
      {|fn f(n: Int) -> Bool =
  case List.map (fn (x: Int) -> Nothing) [1] of
    _ -> True|} );
    ( "case guard arm",
      {|fn f(n: Int) -> Bool =
  case n of
    x where x > 0 ->
      case Nothing of
        _ -> True
    _ -> True|} );
    ( "nested sub-pattern",
      {|fn g(n: Int) -> Maybe (Maybe Int) = g n

fn f(n: Int) -> Bool =
  case g n of
    Something (Something x) -> True
    _ -> False|} );
    ( "test-block statement",
      {|fn f(n: Int) -> Bool = True

test "t" {
  let x = Nothing
  expect f 1 == True
}|} );
    ( "top-level binding",
      {|k = Nothing

fn f(n: Int) -> Bool = True|} ) ]

(* The type `Maybe` IS imported in every case below — only the CONSTRUCTORS are
   missing, which is the exposing distinction the gate has to get right. *)
let position_src body = Printf.sprintf {|module Gated exposing [f]

import Tesl.Prelude exposing [Bool(..), Int, String, List]
import Tesl.Maybe exposing [Maybe]
import Tesl.List exposing [List.map]

%s
|} body

let t_all_positions_gated () =
  List.iter (fun (label, body) ->
    should_fail ("position: " ^ label)
      ~expect:"requires `import Tesl.Maybe`"
      (position_src body))
    positions

let t_all_positions_clean_with_the_import () =
  List.iter (fun (label, body) ->
    let src =
      Str.global_replace
        (Str.regexp_string "import Tesl.Maybe exposing [Maybe]")
        "import Tesl.Maybe exposing [Maybe(..)]"
        (position_src body)
    in
    should_pass ("position (imported): " ^ label) src)
    positions

(* ── 4. The single source ─────────────────────────────────────────────────── *)

let t_derived_tables_agree () =
  (* Validation_names.stdlib_adt_ctors and Emit_racket.adt_constructors are
     DERIVED from the groups table; assert the derivation actually covers every
     group, so a future edit that re-hand-lists either one is caught. *)
  List.iter (fun (m, ty, ctors) ->
    let want = ty :: ctors in
    (match List.find_opt (fun (m', (ty', _)) -> m' = m && ty' = ty)
             Validation_names.stdlib_adt_ctors with
     | None -> failf "Validation_names.stdlib_adt_ctors lost %s / %s" m ty
     | Some (_, (_, got)) ->
       if got <> want then
         failf "Validation_names.stdlib_adt_ctors disagrees for %s / %s" m ty);
    match Hashtbl.find_opt Emit_racket.adt_constructors ty with
    | None -> failf "Emit_racket.adt_constructors lost %s (%s)" ty m
    | Some got ->
      if got <> want then
        failf "Emit_racket.adt_constructors disagrees for %s (%s)" ty m)
    Type_system.stdlib_adt_ctor_groups

let t_every_group_ctor_is_gated () =
  (* The whole point: every stdlib ADT constructor resolves to at least one home
     module.  A group whose constructors are absent from the registry is the
     re-opened hole. *)
  let offenders =
    List.concat_map (fun (m, _ty, ctors) ->
      List.filter_map (fun c ->
        let homes = Type_system.stdlib_ctor_home_modules_of c in
        if List.mem m homes then None else Some (c, m)) ctors)
      Type_system.stdlib_adt_ctor_groups
  in
  if offenders <> [] then
    failf "constructors not gated to their home module: %s"
      (String.concat ", "
         (List.map (fun (c, m) -> Printf.sprintf "%s (%s)" c m) offenders))

let t_exhaustiveness_covers_the_groups () =
  (* Validation_common.builtin_ctor_info carries field types, so it stays
     hand-written — but a gated ADT with no rows there is a `case` that is
     silently unchecked for exhaustiveness.  Known-and-recorded gaps are listed
     explicitly rather than skipped, so closing one is a visible edit. *)
  let recorded_gaps = [ "DeleteResult"; "JobResult" ] in
  let missing =
    List.concat_map (fun (_m, ty, ctors) ->
      if List.mem ty recorded_gaps then []
      else
        List.filter (fun c ->
          not (List.mem_assoc c Validation_common.builtin_ctor_info)) ctors)
      Type_system.stdlib_adt_ctor_groups
    |> List.sort_uniq compare
  in
  if missing <> [] then
    failf
      "stdlib constructors with no Validation_common.builtin_ctor_info row (a \
       `case` over them is not exhaustiveness-checked): %s"
      (String.concat ", " missing)

let t_config_only_names_are_not_gated () =
  (* The 489 IANA zone / ISO 4217 currency / config-marker names emit NO require
     under ANY import, so gating them would demand imports that cannot help.
     (Using one outside a config block is unbound with or without the import —
     recorded as still-open in the roadmap file.) *)
  let leaked =
    List.filter (fun n -> Type_system.stdlib_ctor_home_modules_of n <> [])
      [ "Utc"; "FixedOffset"; "EuropeStockholm"; "Usd"; "Memory"; "Postgres";
        "Exponential"; "Github" ]
  in
  if leaked <> [] then
    failf "config-only names must not be import-gated: %s"
      (String.concat ", " leaked)

let () =
  run "Import-gated stdlib constructors"
    [ ( "repro",
        [ test_case "bare Monday with no import is rejected" `Quick t_repro_rejected;
          test_case "diagnostic names the exposing form" `Quick
            t_repro_names_the_exposing_form;
          test_case "the function case is still the model" `Quick
            t_function_case_still_the_model ] );
      ( "exposing rule",
        [ test_case "Weekday(..) exposes the constructors" `Quick
            t_type_dotdot_exposes_ctors;
          test_case "the constructor may be named directly" `Quick
            t_ctor_named_directly;
          test_case "plain import exposes everything" `Quick t_import_all;
          test_case "Weekday alone does NOT expose them" `Quick
            t_bare_type_does_not_expose_ctors;
          test_case "either home module satisfies a shared ctor" `Quick
            t_multi_home_ctor;
          test_case "the error names every home module" `Quick
            t_multi_home_error_lists_both ] );
      ( "no false positives",
        [ test_case "a locally declared ADT is not gated" `Quick
            t_local_adt_shadow_is_not_gated;
          test_case "a local Weekday is not gated" `Quick t_local_weekday_is_not_gated;
          test_case "a module qualifier is not a value" `Quick
            t_module_qualifier_is_not_gated;
          test_case "pattern position IS gated (one rule everywhere)" `Quick
            t_pattern_position_is_gated;
          test_case "a pattern is satisfied by the family form" `Quick
            t_pattern_position_satisfied_by_family_form;
          test_case "Prelude literals need no import" `Quick
            t_prelude_literals_need_no_import ] );
      ( "every reference position",
        [ test_case "every position demands the import" `Quick t_all_positions_gated;
          test_case "every position is clean with Maybe(..)" `Quick
            t_all_positions_clean_with_the_import ] );
      ( "single source",
        [ test_case "derived tables agree with the groups" `Quick t_derived_tables_agree;
          test_case "every group constructor is gated" `Quick t_every_group_ctor_is_gated;
          test_case "exhaustiveness rows cover the groups" `Quick
            t_exhaustiveness_covers_the_groups;
          test_case "config-only names are not gated" `Quick
            t_config_only_names_are_not_gated ] ) ]
