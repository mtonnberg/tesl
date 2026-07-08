(** First-Class Units tests — Tesl.Units dimensional algebra + Tesl.Money.

    Two layers, mirroring where each guarantee lives:

    - CHECKER (in-process, fast): the dimension algebra on `*`/`/`/`+`/`-`,
      alias resolution + import gating, the Money operator bans with their
      targeted hints, and the name-collision guard.  Uses
      Parser.parse_module + Checker.check_module directly (test_types.ml
      style).

    - VALIDATION (binary `--check`, test_proof_negatives.ml style): the
      proof-layer obligations — Money.add/subtract/compare demand
      `SameCurrency a b`, Money.convertChecked demands `RateFor r m`,
      quantity division by a variable demands `FloatNonZero` — these are
      V001-layer and do NOT fire in Checker.check_module, so they are pinned
      through the real compiler pipeline.

    Positive tests guard against over-rejection; negative tests pin the
    exact diagnostic substrings so a weakened check or a reworded hint
    surfaces here. *)

open Type_system

(* ── In-process helpers (test_types.ml style) ────────────────────────────── *)

let parse_and_check src =
  match Parser.parse_module "<test>" src with
  | Ok m -> Checker.check_module m
  | Err e -> [{ loc = e.loc; message = e.msg; fix = None }]

let contains_substr haystack needle =
  let n = String.length haystack and m = String.length needle in
  let rec go i = i <= n - m && (String.sub haystack i m = needle || go (i + 1)) in
  go 0

let assert_no_errors src =
  let errs = parse_and_check src in
  if errs <> [] then
    Alcotest.failf "expected no errors but got:\n%s"
      (String.concat "\n" (List.map fmt_error errs))

let assert_has_error src substr =
  let errs = parse_and_check src in
  if not (List.exists (fun e -> contains_substr e.message substr) errs) then
    Alcotest.failf "expected error containing %S but got:\n%s"
      substr
      (if errs = [] then "(no errors)" else
       String.concat "\n" (List.map (fun e -> e.message) errs));
  (* pp invariant: the raw canonical quantity name must never leak into any
     diagnostic — always the alias ("Speed") or unit form ("m/s^2"). *)
  List.iter (fun e ->
    if contains_substr e.message "\xc2\xa7Q[" then
      Alcotest.failf "raw quantity name leaked into diagnostic: %s" e.message)
    errs

(* ── Binary helpers (test_proof_negatives.ml style) ──────────────────────── *)

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

(* The compiler resolves a module by its file name, so the temp file must be
   named after the `module X` header (kebab-cased). *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-units" "" in
  let name =
    let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
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

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    (try ignore (Str.search_forward re out 0)
     with Not_found -> failf "expected failure matching %S, got:\n%s" pat out);
    (* pp invariant on the full compiler output too *)
    if contains_substr out "\xc2\xa7Q[" then
      failf "raw quantity name leaked into compiler output:\n%s" out)

(* ══ 1. Units — positive typing (in-process) ═══════════════════════════════ *)

(* The roadmap example: m/s^2 × 4 s = m/s.  The `-> Speed` annotation is what
   pins the RESULT dimension — a wrong product dimension is a unify error. *)
let test_pos_accel_times_duration_is_speed () =
  assert_no_errors {|#lang tesl
module Foo exposing [launchSpeed]
import Tesl.Units exposing [Acceleration, Duration, Speed, Acceleration.metersPerSecondSquared, Duration.seconds]
fn launchSpeed() -> Speed =
  Acceleration.metersPerSecondSquared 2.5 * Duration.seconds 4.0
|}

(* `/` subtracts exponent vectors: Length / Duration = Speed.  Also the
   alias-annotation equality property: the fn is declared with the ALIAS name
   and the body computes the dimension structurally — same type. *)
let test_pos_length_div_duration_is_speed () =
  assert_no_errors {|#lang tesl
module Foo exposing [pace]
import Tesl.Units exposing [Length, Duration, Speed]
fn pace(d: Length, t: Duration) -> Speed =
  d / t
|}

let test_pos_length_times_length_is_area () =
  assert_no_errors {|#lang tesl
module Foo exposing [rect]
import Tesl.Units exposing [Length, Area, Length.meters]
fn rect() -> Area =
  Length.meters 3.0 * Length.meters 4.0
|}

let test_pos_area_times_length_is_volume () =
  assert_no_errors {|#lang tesl
module Foo exposing [box]
import Tesl.Units exposing [Length, Area, Volume, Length.meters, Area.squareMeters]
fn box(base: Area, h: Length) -> Volume =
  base * h
|}

(* Dimensionless result collapses to plain Float — Length/Length : Float. *)
let test_pos_length_div_length_is_float () =
  assert_no_errors {|#lang tesl
module Foo exposing [ratio]
import Tesl.Units exposing [Length]
import Tesl.Float exposing [Float]
fn ratio(a: Length, b: Length) -> Float =
  a / b
|}

(* Scalar × quantity with a FLOAT scalar keeps the dimension. *)
let test_pos_float_scalar_times_quantity () =
  assert_no_errors {|#lang tesl
module Foo exposing [double]
import Tesl.Units exposing [Length, Length.meters]
fn double(d: Length) -> Length =
  2.0 * d
|}

(* quantity / float-literal keeps the dimension (and the nonzero-literal
   divisor is exempt from the FloatNonZero obligation — see the binary group). *)
let test_pos_quantity_div_float_scalar () =
  assert_no_errors {|#lang tesl
module Foo exposing [halve]
import Tesl.Units exposing [Length]
fn halve(d: Length) -> Length =
  d / 2.0
|}

(* scalar / quantity INVERTS the dimension: 1/Duration = Frequency. *)
let test_pos_scalar_div_quantity_inverts () =
  assert_no_errors {|#lang tesl
module Foo exposing [freq]
import Tesl.Units exposing [Duration, Frequency]
fn freq(period: Duration) -> Frequency =
  1.0 / period
|}

let test_pos_same_dim_add_sub_compare () =
  assert_no_errors {|#lang tesl
module Foo exposing [longerThan, total]
import Tesl.Units exposing [Length, Length.meters]
import Tesl.Prelude exposing [Bool]
fn total(a: Length, b: Length) -> Length =
  a + b - Length.meters 1.0
fn longerThan(a: Length, b: Length) -> Bool =
  a > b && a >= b && a < b + b && a <= b && a == b && a != b
|}

(* Unary minus preserves the dimension of a quantity. *)
let test_pos_quantity_unary_minus () =
  assert_no_errors {|#lang tesl
module Foo exposing [flip]
import Tesl.Units exposing [Speed]
fn flip(v: Speed) -> Speed =
  -v
|}

(* Units.mul / Units.div / Units.square compose with checker-computed dims. *)
let test_pos_units_ops_compose () =
  assert_no_errors {|#lang tesl
module Foo exposing [sq, pace2, prod]
import Tesl.Units exposing [Length, Duration, Speed, Area, Length.meters, Units.mul, Units.div, Units.square]
fn sq() -> Area =
  Units.square (Length.meters 3.0)
fn pace2(d: Length, t: Duration) -> Speed =
  Units.div d t
fn prod(a: Length, b: Length) -> Area =
  Units.mul a b
|}

let test_pos_units_sqrt_area_is_length () =
  assert_no_errors {|#lang tesl
module Foo exposing [side]
import Tesl.Units exposing [Length, Area, Units.sqrt]
fn side(a: Area) -> Length =
  Units.sqrt a
|}

let test_pos_units_sum_list () =
  assert_no_errors {|#lang tesl
module Foo exposing [totalDistance]
import Tesl.Units exposing [Length, Length.meters, Units.sum]
import Tesl.Prelude exposing [List]
fn totalDistance(legs: List Length) -> Length =
  Units.sum legs
|}

let test_pos_units_min_max_abs_negate () =
  assert_no_errors {|#lang tesl
module Foo exposing [clampish]
import Tesl.Units exposing [Length, Units.min, Units.max, Units.abs, Units.negate]
fn clampish(a: Length, b: Length) -> Length =
  Units.max (Units.abs (Units.negate a)) (Units.min a b)
|}

(* Constructor : Float -> Quantity; accessor : Quantity -> Float. *)
let test_pos_constructor_accessor_typing () =
  assert_no_errors {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Temperature, Length.feet, Length.inFeet, Temperature.celsius, Temperature.inFahrenheit]
import Tesl.Float exposing [Float]
fn f() -> Float =
  Length.inFeet (Length.feet 10.0) + Temperature.inFahrenheit (Temperature.celsius 100.0)
|}

(* Import gating: a module that does NOT import Tesl.Units keeps full freedom
   to declare `type Speed = Slow | Fast`, with the ctors usable in case arms. *)
let test_pos_user_speed_adt_without_units_import () =
  assert_no_errors {|#lang tesl
module Foo exposing [Speed(..), describe]
import Tesl.Prelude exposing [String]
type Speed =
  | Slow
  | Fast
fn describe(s: Speed) -> String =
  case s of
    Slow -> "slow"
    Fast -> "fast"
|}

(* Same freedom for currency-constructor names without a Tesl.Money import. *)
let test_pos_currency_ctor_names_without_money_import () =
  assert_no_errors {|#lang tesl
module Foo exposing [Attempt(..), describe]
import Tesl.Prelude exposing [String]
type Attempt =
  | Try
  | Sek
  | Usd
fn describe(a: Attempt) -> String =
  case a of
    Try -> "try"
    Sek -> "sek"
    Usd -> "usd"
|}

(* ══ 2. Units — negative typing (in-process) ═══════════════════════════════ *)

let test_neg_add_length_mass () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Mass, Length.meters, Mass.kilograms]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = Length.meters 1.0 + Mass.kilograms 2.0
  1.0
|} "cannot add quantities of different dimension: `Length` and `Mass`"

let test_neg_subtract_cross_dim () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Duration, Length.meters, Duration.seconds]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = Length.meters 1.0 - Duration.seconds 2.0
  1.0
|} "cannot subtract quantities of different dimension: `Length` and `Duration`"

let test_neg_add_length_float () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Length.meters]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = Length.meters 1.0 + 2.0
  1.0
|} "cannot add a dimensioned quantity (`Length`) and a dimensionless number"

let test_neg_add_float_length () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Length.meters]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = 2.0 + Length.meters 1.0
  1.0
|} "cannot add a dimensionless number and a dimensioned quantity (`Length`)"

let test_neg_modulo_on_quantity () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Length.meters]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = Length.meters 5.0 % Length.meters 2.0
  1.0
|} "operator `%` is not defined for dimensioned quantities"

(* Int scalar gets the targeted Float-literal hint, not a bare unify error. *)
let test_neg_int_scalar_hint () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Length.meters]
fn f() -> Length =
  2 * Length.meters 3.0
|} "write a Float literal (`2.0`, not `2`)"

(* Cross-dimension ordering is a plain unify mismatch (nominal TCons). *)
let test_neg_cross_dim_compare () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Mass, Length.meters, Mass.kilograms]
import Tesl.Prelude exposing [Bool]
fn f() -> Bool =
  Length.meters 1.0 < Mass.kilograms 2.0
|} "cannot unify Length with Mass"

let test_neg_sqrt_odd_exponent () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Length.meters, Units.sqrt]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = Units.sqrt (Length.meters 4.0)
  1.0
|} "`Units.sqrt` is only defined when every dimension exponent is even"

(* A no-alias dimension renders in unit form ("m\xc2\xb7s"), never the raw
   canonical name (assert_has_error also asserts no diagnostic contains it). *)
let test_neg_sqrt_no_alias_dim_renders_unit_form () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Duration, Length.meters, Duration.seconds, Units.mul, Units.sqrt]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = Units.sqrt (Units.mul (Length.meters 4.0) (Duration.seconds 9.0))
  1.0
|} "`m\xc2\xb7s` has an odd exponent"

let test_neg_units_min_cross_dim () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Mass, Length.meters, Mass.kilograms, Units.min]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = Units.min (Length.meters 1.0) (Mass.kilograms 2.0)
  1.0
|} "`Units.min` needs both arguments in the SAME dimension: `Length` vs `Mass`"

let test_neg_units_mul_arity () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Length.meters, Units.mul]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = Units.mul (Length.meters 1.0)
  1.0
|} "`Units.mul` expects 2 arguments"

let test_neg_unknown_units_op () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Units exposing [Length, Length.meters]
import Tesl.Float exposing [Float]
fn f() -> Float =
  let bad = Units.cube (Length.meters 1.0)
  1.0
|} "unknown Units operation `Units.cube`"

(* Alias NOT imported: `Speed` is not a type in scope at all — no silent
   quantity semantics; the error carries the guided-import hint. *)
let test_neg_alias_not_imported () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Float exposing [Float]
fn f(x: Speed) -> Float =
  1.0
|} "type `Speed` is not in scope"

(* ══ 3. Money — positive typing (in-process) ═══════════════════════════════ *)

let test_pos_money_construct_accessors () =
  assert_no_errors {|#lang tesl
module Foo exposing [amount, units, cur, shown, ops]
import Tesl.Money exposing [Money, Currency, Money.usd, Money.minorUnits, Money.currency, Money.display, Money.scale, Money.negate, Money.abs, Money.isZero, Money.isNegative, Currency.code]
import Tesl.Prelude exposing [Int, String, Bool]
fn amount() -> Money =
  Money.usd 1050
fn units(m: Money) -> Int =
  Money.minorUnits m
fn cur(m: Money) -> String =
  Currency.code (Money.currency m)
fn shown(m: Money) -> String =
  Money.display m
fn ops(m: Money) -> Bool =
  Money.isZero (Money.scale m 0) && Money.isNegative (Money.negate (Money.abs m))
|}

(* Money.fromMinorUnits takes a Currency CONSTRUCTOR (baked ISO 4217 ADT). *)
let test_pos_money_from_minor_units () =
  assert_no_errors {|#lang tesl
module Foo exposing [price]
import Tesl.Money exposing [Money, Currency, Money.fromMinorUnits, Eur]
fn price() -> Money =
  Money.fromMinorUnits Eur 916
|}

(* The proof-gated flow TYPES cleanly (the proof itself is validated in the
   binary group below). *)
let test_pos_require_same_currency_add_types () =
  assert_no_errors {|#lang tesl
module Foo exposing [total]
import Tesl.Money exposing [Money, Money.add, Money.requireSameCurrency]
fn total(a: Money, b: Money) -> Money =
  let sb = check Money.requireSameCurrency a b
  Money.add a sb
|}

let test_pos_require_non_negative_types () =
  assert_no_errors {|#lang tesl
module Foo exposing [deposit]
import Tesl.Money exposing [Money, Money.requireNonNegative]
fn deposit(m: Money) -> Money =
  let nn = check Money.requireNonNegative m
  nn
|}

(* ExchangeRate.make : Currency -> Currency -> Float -> PosixMillis;
   Money.convert : ExchangeRate -> Money -> Result Money String. *)
let test_pos_exchange_rate_convert_result () =
  assert_no_errors {|#lang tesl
module Foo exposing [converted]
import Tesl.Money exposing [Money, ExchangeRate, Money.usd, Money.convert, ExchangeRate.make, Usd, Eur]
import Tesl.Result exposing [Result(..)]
import Tesl.Prelude exposing [String]
import Tesl.Time exposing [PosixMillis, Time.secondsToPosix]
fn converted() -> Result Money String =
  let rate = ExchangeRate.make Usd Eur 0.9155 (Time.secondsToPosix 0)
  Money.convert rate (Money.usd 1000)
|}

let test_pos_require_rate_for_convert_checked_types () =
  assert_no_errors {|#lang tesl
module Foo exposing [convertStrict]
import Tesl.Money exposing [Money, ExchangeRate, Money.convertChecked, Money.requireRateFor]
fn convertStrict(r: ExchangeRate, m: Money) -> Money =
  let mc = check Money.requireRateFor r m
  Money.convertChecked r mc
|}

(* ══ 4. Money — negative typing (in-process) ═══════════════════════════════ *)

let test_neg_money_plus () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Money exposing [Money, Money.usd]
fn f() -> Money =
  Money.usd 100 + Money.usd 200
|} "operator `+` is not defined for `Money`; use `Money.add a b`"

(* The `+` hint names the proof AND its mint. *)
let test_neg_money_plus_hint_mentions_proof () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Money exposing [Money, Money.usd]
fn f() -> Money =
  Money.usd 100 + Money.usd 200
|} "mint it with `Money.requireSameCurrency a b`"

let test_neg_money_minus () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Money exposing [Money, Money.usd]
fn f() -> Money =
  Money.usd 100 - Money.usd 200
|} "operator `-` is not defined for `Money`; use `Money.subtract a b`"

let test_neg_money_times () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Money exposing [Money, Money.usd]
fn f() -> Money =
  Money.usd 100 * Money.usd 200
|} "operator `*` is not defined for `Money`"

let test_neg_money_ordering () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Money exposing [Money, Money.usd]
import Tesl.Prelude exposing [Bool]
fn f() -> Bool =
  Money.usd 100 < Money.usd 200
|} "use `Money.compare a b`"

let test_neg_money_unary_minus () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Money exposing [Money]
fn f(m: Money) -> Money =
  -m
|} "unary `-` is not defined for `Money`; use `Money.negate m`"

(* ══ 5. Name-collision guard (in-process) ══════════════════════════════════ *)

let test_neg_speed_collision_with_units_import () =
  assert_has_error {|#lang tesl
module Foo exposing [Speed(..)]
import Tesl.Units exposing [Length, Length.meters]
type Speed =
  | Slow
  | Fast
|} "type `Speed` collides with the `Speed` quantity type exported by Tesl.Units"

let test_neg_money_type_collision_with_money_import () =
  assert_has_error {|#lang tesl
module Foo exposing [Money(..)]
import Tesl.Money exposing [Currency]
type Money =
  | Cash
  | Card
|} "type `Money` collides with the `Money` type exported by Tesl.Money"

(* `Try` is the TRY (Turkish lira) currency constructor. *)
let test_neg_ctor_collision_with_currency_ctor () =
  assert_has_error {|#lang tesl
module Foo exposing [Foo(..)]
import Tesl.Money exposing [Money]
type Foo =
  | Try
  | Fast
|} "constructor `Try` collides with the `Try` Currency constructor exported by Tesl.Money"

(* ══ 6. Proof obligations (binary --check; V001 validation layer) ══════════ *)

let test_v_money_add_without_proof () =
  should_fail "call to `Money.add` argument `b` does not statically satisfy declared proof `SameCurrency a b`" {|
module UnitsMoneyAddNoProof exposing [f]
import Tesl.Money exposing [Money, Money.add]
fn f(a: Money, b: Money) -> Money =
  Money.add a b
|}

let test_v_money_subtract_without_proof () =
  should_fail "call to `Money.subtract` argument `b` does not statically satisfy declared proof `SameCurrency a b`" {|
module UnitsMoneySubNoProof exposing [f]
import Tesl.Money exposing [Money, Money.subtract]
fn f(a: Money, b: Money) -> Money =
  Money.subtract a b
|}

let test_v_money_compare_without_proof () =
  should_fail "call to `Money.compare` argument `b` does not statically satisfy declared proof `SameCurrency a b`" {|
module UnitsMoneyCmpNoProof exposing [f]
import Tesl.Money exposing [Money, Money.compare]
import Tesl.Prelude exposing [Int]
fn f(a: Money, b: Money) -> Int =
  Money.compare a b
|}

let test_v_convert_checked_without_rate_for () =
  should_fail "call to `Money.convertChecked` argument `m` does not statically satisfy declared proof `RateFor r m`" {|
module UnitsMoneyConvNoProof exposing [f]
import Tesl.Money exposing [Money, ExchangeRate, Money.convertChecked]
fn f(r: ExchangeRate, m: Money) -> Money =
  Money.convertChecked r m
|}

(* Quantity division by a VARIABLE divisor demands FloatNonZero (the shared
   nonzero-divisor family); the hint routes to Units.requireNonZero. *)
let test_v_quantity_division_var_needs_nonzero () =
  should_fail "the right operand of `/` (`t`) has no `IsNonZero` proof" {|
module UnitsDivNoProof exposing [f]
import Tesl.Units exposing [Length, Duration, Speed]
fn f(d: Length, t: Duration) -> Speed =
  d / t
|}

let test_v_quantity_division_hint_mentions_units_require_non_zero () =
  should_fail "Units.requireNonZero" {|
module UnitsDivNoProofHint exposing [f]
import Tesl.Units exposing [Length, Duration, Speed]
fn f(d: Length, t: Duration) -> Speed =
  d / t
|}

(* A call-expression divisor has no trackable subject — also rejected. *)
let test_v_quantity_division_expr_divisor_untrackable () =
  should_fail "the right operand of `/` is an expression with no trackable `IsNonZero` proof" {|
module UnitsDivExprDivisor exposing [f]
import Tesl.Units exposing [Length, Duration, Speed, Length.meters, Duration.seconds]
fn f() -> Speed =
  Length.meters 6.0 / Duration.seconds 2.0
|}

(* ── positive controls: the sanctioned mints unlock the same operations ──── *)

let test_v_require_same_currency_unlocks_add () =
  should_pass {|
module UnitsMoneyAddProof exposing [total]
import Tesl.Money exposing [Money, Money.add, Money.requireSameCurrency]
fn total(a: Money, b: Money) -> Money =
  let sb = check Money.requireSameCurrency a b
  Money.add a sb
|}

let test_v_require_same_currency_unlocks_compare () =
  should_pass {|
module UnitsMoneyCmpProof exposing [cmp]
import Tesl.Money exposing [Money, Money.compare, Money.requireSameCurrency]
import Tesl.Prelude exposing [Int]
fn cmp(a: Money, b: Money) -> Int =
  let sb = check Money.requireSameCurrency a b
  Money.compare a sb
|}

let test_v_require_rate_for_unlocks_convert_checked () =
  should_pass {|
module UnitsMoneyConvProof exposing [convertStrict]
import Tesl.Money exposing [Money, ExchangeRate, Money.convertChecked, Money.requireRateFor]
fn convertStrict(r: ExchangeRate, m: Money) -> Money =
  let mc = check Money.requireRateFor r m
  Money.convertChecked r mc
|}

let test_v_require_non_negative_flow () =
  should_pass {|
module UnitsMoneyNonNeg exposing [deposit]
import Tesl.Money exposing [Money, Money.requireNonNegative]
fn deposit(m: Money) -> Money =
  let nn = check Money.requireNonNegative m
  nn
|}

(* NOTE: the mint is the BARE call form (`let tc = Units.requireNonZero t`),
   not `check Units.requireNonZero t` — the `check` combinator's `(a -> a) -> a`
   typing collapses the checker-computed dimension result, so the checked
   binding loses its quantity type (would then fail `-> Speed`). *)
let test_v_units_require_non_zero_unlocks_division () =
  should_pass {|
module UnitsDivProof exposing [pace]
import Tesl.Units exposing [Length, Duration, Speed, Units.requireNonZero]
fn pace(d: Length, t: Duration) -> Speed =
  let tc = Units.requireNonZero t
  d / tc
|}

(* Division by a NONZERO literal is statically safe — exempt from the proof. *)
let test_v_division_by_nonzero_literal_exempt () =
  should_pass {|
module UnitsDivLiteral exposing [halve]
import Tesl.Units exposing [Length]
fn halve(d: Length) -> Length =
  d / 2.0
|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "UnitsMoney" [
    "units-positive", [
      Alcotest.test_case "accel * duration : Speed" `Quick test_pos_accel_times_duration_is_speed;
      Alcotest.test_case "length / duration : Speed (alias annotation)" `Quick test_pos_length_div_duration_is_speed;
      Alcotest.test_case "length * length : Area" `Quick test_pos_length_times_length_is_area;
      Alcotest.test_case "area * length : Volume" `Quick test_pos_area_times_length_is_volume;
      Alcotest.test_case "length / length : Float" `Quick test_pos_length_div_length_is_float;
      Alcotest.test_case "Float scalar * quantity" `Quick test_pos_float_scalar_times_quantity;
      Alcotest.test_case "quantity / Float scalar" `Quick test_pos_quantity_div_float_scalar;
      Alcotest.test_case "scalar / quantity inverts dimension" `Quick test_pos_scalar_div_quantity_inverts;
      Alcotest.test_case "same-dim add/sub/compare" `Quick test_pos_same_dim_add_sub_compare;
      Alcotest.test_case "quantity unary minus" `Quick test_pos_quantity_unary_minus;
      Alcotest.test_case "Units.mul/div/square compose" `Quick test_pos_units_ops_compose;
      Alcotest.test_case "Units.sqrt Area : Length" `Quick test_pos_units_sqrt_area_is_length;
      Alcotest.test_case "Units.sum : List Length -> Length" `Quick test_pos_units_sum_list;
      Alcotest.test_case "Units.min/max/abs/negate" `Quick test_pos_units_min_max_abs_negate;
      Alcotest.test_case "constructor/accessor typing" `Quick test_pos_constructor_accessor_typing;
      Alcotest.test_case "user Speed ADT without Units import" `Quick test_pos_user_speed_adt_without_units_import;
      Alcotest.test_case "currency ctor names without Money import" `Quick test_pos_currency_ctor_names_without_money_import;
    ];
    "units-negative", [
      Alcotest.test_case "Length + Mass rejected" `Quick test_neg_add_length_mass;
      Alcotest.test_case "Length - Duration rejected" `Quick test_neg_subtract_cross_dim;
      Alcotest.test_case "Length + Float rejected" `Quick test_neg_add_length_float;
      Alcotest.test_case "Float + Length rejected" `Quick test_neg_add_float_length;
      Alcotest.test_case "% on quantity rejected" `Quick test_neg_modulo_on_quantity;
      Alcotest.test_case "Int scalar gets Float-literal hint" `Quick test_neg_int_scalar_hint;
      Alcotest.test_case "cross-dim compare rejected" `Quick test_neg_cross_dim_compare;
      Alcotest.test_case "Units.sqrt odd exponent rejected" `Quick test_neg_sqrt_odd_exponent;
      Alcotest.test_case "no-alias dim renders unit form" `Quick test_neg_sqrt_no_alias_dim_renders_unit_form;
      Alcotest.test_case "Units.min cross-dim rejected" `Quick test_neg_units_min_cross_dim;
      Alcotest.test_case "Units.mul arity rejected" `Quick test_neg_units_mul_arity;
      Alcotest.test_case "unknown Units op rejected" `Quick test_neg_unknown_units_op;
      Alcotest.test_case "alias not imported: Speed unknown" `Quick test_neg_alias_not_imported;
    ];
    "money-positive", [
      Alcotest.test_case "construct + accessors" `Quick test_pos_money_construct_accessors;
      Alcotest.test_case "fromMinorUnits with Currency ctor" `Quick test_pos_money_from_minor_units;
      Alcotest.test_case "requireSameCurrency -> add types" `Quick test_pos_require_same_currency_add_types;
      Alcotest.test_case "requireNonNegative types" `Quick test_pos_require_non_negative_types;
      Alcotest.test_case "ExchangeRate.make + convert : Result" `Quick test_pos_exchange_rate_convert_result;
      Alcotest.test_case "requireRateFor -> convertChecked types" `Quick test_pos_require_rate_for_convert_checked_types;
    ];
    "money-negative", [
      Alcotest.test_case "Money + rejected with add hint" `Quick test_neg_money_plus;
      Alcotest.test_case "Money + hint mentions proof mint" `Quick test_neg_money_plus_hint_mentions_proof;
      Alcotest.test_case "Money - rejected with subtract hint" `Quick test_neg_money_minus;
      Alcotest.test_case "Money * rejected" `Quick test_neg_money_times;
      Alcotest.test_case "Money < rejected with compare hint" `Quick test_neg_money_ordering;
      Alcotest.test_case "unary - on Money rejected" `Quick test_neg_money_unary_minus;
    ];
    "collisions", [
      Alcotest.test_case "type Speed collides with Units import" `Quick test_neg_speed_collision_with_units_import;
      Alcotest.test_case "type Money collides with Money import" `Quick test_neg_money_type_collision_with_money_import;
      Alcotest.test_case "ctor Try collides with Currency ctor" `Quick test_neg_ctor_collision_with_currency_ctor;
    ];
    "proof-negative", [
      Alcotest.test_case "Money.add needs SameCurrency" `Quick test_v_money_add_without_proof;
      Alcotest.test_case "Money.subtract needs SameCurrency" `Quick test_v_money_subtract_without_proof;
      Alcotest.test_case "Money.compare needs SameCurrency" `Quick test_v_money_compare_without_proof;
      Alcotest.test_case "convertChecked needs RateFor" `Quick test_v_convert_checked_without_rate_for;
      Alcotest.test_case "quantity / var needs FloatNonZero" `Quick test_v_quantity_division_var_needs_nonzero;
      Alcotest.test_case "division hint routes to Units.requireNonZero" `Quick test_v_quantity_division_hint_mentions_units_require_non_zero;
      Alcotest.test_case "expression divisor untrackable" `Quick test_v_quantity_division_expr_divisor_untrackable;
    ];
    "proof-positive", [
      Alcotest.test_case "requireSameCurrency unlocks add" `Quick test_v_require_same_currency_unlocks_add;
      Alcotest.test_case "requireSameCurrency unlocks compare" `Quick test_v_require_same_currency_unlocks_compare;
      Alcotest.test_case "requireRateFor unlocks convertChecked" `Quick test_v_require_rate_for_unlocks_convert_checked;
      Alcotest.test_case "requireNonNegative flow validates" `Quick test_v_require_non_negative_flow;
      Alcotest.test_case "Units.requireNonZero unlocks division" `Quick test_v_units_require_non_zero_unlocks_division;
      Alcotest.test_case "nonzero literal divisor exempt" `Quick test_v_division_by_nonzero_literal_exempt;
    ];
  ]
