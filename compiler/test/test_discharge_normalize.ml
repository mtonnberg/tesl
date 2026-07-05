(** DISCHARGE-NORMALIZE — unit test for the obligation model (Proof_discharge).

    Pins the single, exhaustive `return_spec -> obligation list` front door of the
    discharge-unification refactor: the Carry/Mint judgment axis (function-kind
    driven), the per-form target, the `? P` entity-group flag, the Maybe
    success-only leaf scope, and the Framework (FromDb) mode.  These are the
    invariants every later phase's verifiers rely on. *)

open Alcotest
open Ast
open Proof_discharge

let parse src =
  match Parser.parse_module "dn.tesl" src with
  | Ok m -> m
  | Err e -> failf "parse error: %s" e.Parser.msg

let fn_named m name =
  match List.find_opt (function DFunc fd -> fd.name = name | _ -> false) m.decls with
  | Some (DFunc fd) -> fd
  | _ -> failf "function %s not found" name

let obls m name =
  let fd = fn_named m name in
  normalize fd.kind fd.return_spec

let src = {|#lang tesl
module Dn exposing []
import Tesl.Prelude exposing [Int, String, List, Fact, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact IsPositive (n: Int)
fn fCarry(x: Int ::: IsPositive x) -> r: Int ::: IsPositive r =
  x
check fMint(n: Int) -> n: Int ::: IsPositive n =
  ok n ::: IsPositive n
fn fPack(x: Int ::: IsPositive x) -> Int ? IsPositive =
  x
fn fPlain(n: Int) -> Int =
  n
fn fMaybe(x: Int ::: IsPositive x) -> Maybe (v: Int ::: IsPositive v) =
  Something x
fn fForAll(xs: List Int) -> List Int ? ForAll IsPositive =
  xs
|}

let judgment_str = function Carry -> "Carry" | Mint -> "Mint"
let target_str = function
  | ReturnedValue -> "ReturnedValue" | MaybeSuccess -> "MaybeSuccess"
  | ExistsPacked -> "ExistsPacked" | Elements -> "Elements"
  | DictValues -> "DictValues" | DictKeys -> "DictKeys"
let mode_str = function Carried -> "Carried" | Framework -> "Framework"

let one label os = match os with
  | [o] -> o
  | _ -> failf "%s: expected exactly one obligation, got %d" label (List.length os)

let () =
  let m = parse src in
  run "Discharge-Normalize" [
    "obligation model", [
      test_case "fn RetAttached -> Carry/ReturnedValue, binder set" `Quick (fun () ->
        let o = one "fCarry" (obls m "fCarry") in
        check string "judgment" "Carry" (judgment_str o.judgment);
        check string "target" "ReturnedValue" (target_str o.target);
        check string "mode" "Carried" (mode_str o.mode);
        check bool "binder is set" true (o.binder <> None);
        check bool "not entity_group" false o.entity_group);
      test_case "check RetAttached -> Mint" `Quick (fun () ->
        let o = one "fMint" (obls m "fMint") in
        check string "judgment" "Mint" (judgment_str o.judgment);
        check string "target" "ReturnedValue" (target_str o.target));
      test_case "fn `? P` -> entity_group flag set" `Quick (fun () ->
        let o = one "fPack" (obls m "fPack") in
        check string "judgment" "Carry" (judgment_str o.judgment);
        check bool "entity_group" true o.entity_group);
      test_case "plain `-> T` -> no obligation" `Quick (fun () ->
        check int "no obligations" 0 (List.length (obls m "fPlain")));
      test_case "RetMaybeAttached -> MaybeSuccess, success-only leaf scope" `Quick (fun () ->
        let o = one "fMaybe" (obls m "fMaybe") in
        check string "target" "MaybeSuccess" (target_str o.target);
        check bool "success-ctor-only" true (o.leaves = SuccessCtorPayloadOnly));
      test_case "ForAll -> Elements" `Quick (fun () ->
        let o = one "fForAll" (obls m "fForAll") in
        check string "target" "Elements" (target_str o.target));
      test_case "FromDb predicate -> Framework mode" `Quick (fun () ->
        let loc = Location.dummy_loc "test" in
        let fromdb = PredApp { pred = "FromDb"; args = ["Id == x"]; loc } in
        let ordinary = PredApp { pred = "IsPositive"; args = ["x"]; loc } in
        check string "FromDb is Framework" "Framework" (mode_str (mode_of_proof fromdb));
        check string "ordinary is Carried" "Carried" (mode_str (mode_of_proof ordinary)));
    ];
  ]
