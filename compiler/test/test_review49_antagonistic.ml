(** Antagonistic regression tests for Critical Review 49.

    Proof soundness & GDP invariants:
    R49_P01  Cross-subject proof reattachment rejected
    R49_P02  Proof fabrication in fn body rejected
    R49_P03  Proof fabrication via ::: in handler body rejected
    R49_P04  establish body cannot use fail
    R49_P05  check body cannot use direct proof constructor
    R49_P06  ok literal (not binding name) in check rejected
    R49_P07  Proof from check cannot be used on different subject
    R49_P08  Correct proof usage compiles (positive control)

    Shadowing & scoping:
    R49_S01  let shadows function parameter rejected
    R49_S02  case binder shadows outer let rejected
    R49_S03  Nested let shadowing rejected

    Type system edge cases:
    R49_T01  Newtype not interchangeable with base type
    R49_T02  Two newtypes over same base type not interchangeable
    R49_T03  PosixMillis not usable as Int in arithmetic
    R49_T04  String not usable where Int expected
    R49_T05  List of mixed types rejected
    R49_T06  Record field type mismatch rejected

    Parser & syntax:
    R49_X01  Single-line if/then/else rejected
    R49_X02  Single-line ADT uses result as unresolvable alias
    R49_X03  Import after definition rejected

    Exhaustiveness:
    R49_E01  Non-exhaustive case on custom ADT rejected
    R49_E02  case on Int without catch-all rejected
    R49_E03  case on String without catch-all rejected

    Capabilities:
    R49_C01  Calling fn requiring cap from context without it rejected

    Codec & records:
    R49_D01  stringCodec on ADT field should be rejected (BUG: currently passes)
    R49_D02  Record construction with proof field missing proof rejected

    Additional:
    R49_A01  empty module valid
    R49_A02  duplicate top-level rejected
    R49_A03  constructor same as type rejected
    R49_A04  valid multi-param fact compiles
    R49_A05  valid ADT pattern matching compiles
    R49_A06  integer overflow rejected
    R49_A07  first-class functions work
    R49_A08  nested Maybe pattern
    R49_A09  partial application works
    R49_A10  pipe operator works
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

let with_temp_file prefix suffix content f =
  let path = Filename.temp_file prefix suffix in
  write_file path content;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let should_pass_src src =
  with_temp_file "tesl-r49" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r49" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
|}

(* ═══════════════════════════════════════════════════════════════════════════
   PROOF SOUNDNESS
   ═══════════════════════════════════════════════════════════════════════════ *)

let r49_p01 () =
  should_fail_src "proof\\|subject\\|mismatch\\|reattach\\|retarget\\|not.*satisfy" (base_header ^ {|
fact IsPositive (n: Int)

check positive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

fn listen(port: Int ::: IsPositive port) -> Int = port

fn bad(x: Int, y: Int) -> Int =
  let checkedX = check positive(x)
  listen <| y ::: detachFact(checkedX)
|})

let r49_p02 () =
  should_fail_src "proof.*fabricat\\|only.*check\\|not.*allowed\\|cannot.*proof" (base_header ^ {|
fact IsPositive (n: Int)

fn sneaky(n: Int) -> Int ::: IsPositive n =
  n ::: IsPositive n
|})

let r49_p03 () =
  should_fail_src "proof.*fabricat\\|only.*check\\|not.*allowed\\|cannot.*proof\\|handler" (base_header ^ {|
fact IsPositive (n: Int)

record User { id: String }

handler sneakyHandler(n: Int)
  -> Int ::: IsPositive n
  requires [] =
  n ::: IsPositive n
|})

let r49_p04 () =
  should_fail_src "fail\\|establish" (base_header ^ {|
fact IsPositive (n: Int)

establish badEstablish(n: Int) -> Fact (IsPositive n) =
  if n > 0 then
    IsPositive n
  else
    fail 400 "not positive"
|})

let r49_p05 () =
  should_fail_src "unknown.*constructor\\|check\\|proof.*constructor\\|direct\\|form" (base_header ^ {|
fact IsPositive (n: Int)

check badCheck(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    IsPositive n
  else
    fail 400 "nope"
|})

let r49_p06 () =
  should_fail_src "binding\\|literal\\|must.*return\\|not.*binding\\|expected\\|constructor" (base_header ^ {|
fact IsPositive (n: Int)

check badLiteral(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok 42 ::: IsPositive n
  else
    fail 400 "nope"
|})

let r49_p07 () =
  should_fail_src "proof\\|subject\\|does not\\|mismatch\\|not.*satisfy" (base_header ^ {|
fact IsPositive (n: Int)

check positive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn misuse(a: Int, b: Int) -> Int =
  let validA = check positive(a)
  requiresPositive b
|})

let r49_p08 () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

check positive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn correct(a: Int) -> Int =
  let validA = check positive(a)
  requiresPositive validA
|})

(* ═══════════════════════════════════════════════════════════════════════════
   SHADOWING
   ═══════════════════════════════════════════════════════════════════════════ *)

let r49_s01 () =
  should_fail_src "shadow" (base_header ^ {|
fn bad(x: Int) -> Int =
  let x = 1
  x
|})

let r49_s02 () =
  should_fail_src "shadow" (base_header ^ {|
type Color
  = Red
  | Blue

fn bad(c: Color) -> Int =
  let n = 5
  case c of
    Red ->
      let n = 10
      n
    Blue -> n
|})

let r49_s03 () =
  should_fail_src "shadow" (base_header ^ {|
fn bad() -> Int =
  let x = 1
  let x = 2
  x
|})

(* ═══════════════════════════════════════════════════════════════════════════
   TYPE SYSTEM
   ═══════════════════════════════════════════════════════════════════════════ *)

let r49_t01 () =
  should_fail_src "type\\|mismatch\\|expected\\|newtype\\|UserId\\|String" (base_header ^ {|
type UserId = String

fn takeUserId(id: UserId) -> String = id.value

fn bad() -> String =
  takeUserId "raw-string"
|})

let r49_t02 () =
  should_fail_src "type\\|mismatch\\|ProjectId\\|UserId" (base_header ^ {|
type UserId = String
type ProjectId = String

fn takeUserId(id: UserId) -> String = id.value

fn bad(pid: ProjectId) -> String =
  takeUserId pid
|})

let r49_t03 () =
  should_fail_src "type\\|mismatch\\|PosixMillis\\|Int\\|expected" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Time exposing [PosixMillis]

fn bad(ts: PosixMillis) -> Int =
  ts + 1
|})

let r49_t04 () =
  should_fail_src "type\\|mismatch\\|expected.*Int\\|got.*String" (base_header ^ {|
fn add(a: Int, b: Int) -> Int = a + b

fn bad() -> Int =
  add "hello" 5
|})

let r49_t05 () =
  should_fail_src "type\\|mismatch\\|homogeneous\\|mixed\\|unif" (base_header ^ {|
fn bad() -> List Int =
  [1, "two", 3]
|})

let r49_t06 () =
  should_fail_src "type\\|mismatch\\|expected\\|field" (base_header ^ {|
record Point { x: Int, y: Int }

fn bad() -> Point =
  Point { x: "hello", y: 5 }
|})

(* ═══════════════════════════════════════════════════════════════════════════
   PARSER & SYNTAX
   ═══════════════════════════════════════════════════════════════════════════ *)

let r49_x01 () =
  should_fail_src "single.line\\|parse\\|indent\\|unexpected\\|then.*must" (base_header ^ {|
fn bad(n: Int) -> String = if n > 0 then "pos" else "neg"
|})

let r49_x02 () =
  (* Single-line type Color = Red | Blue is a type alias, not an ADT.
     Using Red as a constructor should be some kind of error. *)
  should_fail_src "ADT.*separate\\|single.line\\|alias\\|variant" (base_header ^ {|
type Color = Red | Blue

fn bad() -> Color =
  Red
|})

let r49_x03 () =
  should_fail_src "import.*must.*before\\|import.*after\\|unexpected.*import" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]

fn f() -> Int = 1

import Tesl.Maybe exposing [Maybe(..)]
|})

(* ═══════════════════════════════════════════════════════════════════════════
   EXHAUSTIVENESS
   ═══════════════════════════════════════════════════════════════════════════ *)

let r49_e01 () =
  should_fail_src "exhaustive\\|missing\\|Blue\\|incomplete" (base_header ^ {|
type Color
  = Red
  | Green
  | Blue

fn describe(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
|})

let r49_e02 () =
  should_fail_src "exhaustive\\|catch.all\\|wildcard\\|incomplete\\|default" (base_header ^ {|
fn bad(n: Int) -> String =
  case n of
    0 -> "zero"
    1 -> "one"
|})

let r49_e03 () =
  should_fail_src "exhaustive\\|catch.all\\|wildcard\\|incomplete\\|default" (base_header ^ {|
fn bad(s: String) -> Int =
  case s of
    "hello" -> 1
    "world" -> 2
|})

(* ═══════════════════════════════════════════════════════════════════════════
   CAPABILITIES
   ═══════════════════════════════════════════════════════════════════════════ *)

let r49_c01 () =
  should_fail_src "capability\\|requires\\|missing\\|not.*declared\\|dbWrite" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Unit]
import Tesl.DB exposing [dbRead, dbWrite]

entity Item table "items" primaryKey id {
  id: String
  name: String
}

fn writeItem(id: String, name: String) -> Unit
  requires [dbWrite] =
  insert Item { id: id, name: name }

fn caller() -> Unit
  requires [dbRead] =
  writeItem "1" "test"
|})

(* ═══════════════════════════════════════════════════════════════════════════
   CODEC & RECORDS — including known bugs
   ═══════════════════════════════════════════════════════════════════════════ *)

(* FIXED: stringCodec on an ADT field is now a type mismatch *)
let r49_d01_bug () =
  should_fail_src "field.*priority.*type.*Priority.*stringCodec.*decodes.*String\\|stringCodec.*decodes.*String" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]

type Priority
  = Low
  | Medium
  | High

codec Priority { adtJson }

record Task { title: String, priority: Priority }

codec Task {
  toJson_forbidden
  fromJson [
    {
      title    <- "title"    with_codec stringCodec
      priority <- "priority" with_codec stringCodec
    }
  ]
}
|})

(* Record construction without proof should be rejected *)
let r49_d02 () =
  should_fail_src "proof\\|requires\\|ValidTitle\\|missing\\|error" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length]

fact ValidTitle (title: String)

check isValidTitle(title: String) -> title: String ::: ValidTitle title =
  if String.length title > 3 then
    ok title ::: ValidTitle title
  else
    fail 400 "too short"

record SafeRecord { title: String ::: ValidTitle title }

fn bad() -> SafeRecord =
  SafeRecord { title: "hello" }
|})

(* ═══════════════════════════════════════════════════════════════════════════
   ADDITIONAL EDGE CASES
   ═══════════════════════════════════════════════════════════════════════════ *)

let r49_a01 () =
  should_pass_src {|#lang tesl
module Empty exposing []
import Tesl.Prelude exposing [Int]
|}

let r49_a02 () =
  should_fail_src "duplicate\\|already.*defined\\|redefin" (base_header ^ {|
fn f() -> Int = 1
fn f() -> Int = 2
|})

let r49_a03 () =
  should_fail_src "constructor.*same.*type\\|ambiguous\\|cannot.*share\\|constructor.*Status" (base_header ^ {|
type Status
  = Status
  | Other
|})

let r49_a04 () =
  should_pass_src (base_header ^ {|
fact InRange (lo: Int) (hi: Int) (n: Int)

check isInRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"

fn processInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> String = "ok"
|})

let r49_a05 () =
  should_pass_src (base_header ^ {|
type Shape
  = Circle radius: Int
  | Rect width: Int height: Int

fn area(s: Shape) -> Int =
  case s of
    Circle r -> r * r * 3
    Rect w h -> w * h
|})

let r49_a06 () =
  (* A9/HM-1: Int is arbitrary-precision — a huge literal compiles (carried as an
     LBigInt canonical string into the Racket bignum), no longer rejected. *)
  should_pass_src (base_header ^ {|
fn bad() -> Int = 9999999999999999999999
|})

let r49_a07 () =
  should_pass_src (base_header ^ {|
fn add(x: Int, y: Int) -> Int = x + y

fn applyAdd(f: Int -> Int -> Int, a: Int, b: Int) -> Int =
  f a b

fn test() -> Int =
  applyAdd add 3 4
|})

let r49_a08 () =
  should_pass_src ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]

fn fromMaybe(m: Maybe Int, def: Int) -> Int =
  case m of
    Something n -> n
    Nothing -> def
|})

(* Partial application positive test *)
let r49_a09 () =
  should_pass_src (base_header ^ {|
fn add(x: Int, y: Int) -> Int = x + y

fn test() -> Int =
  let add3 = add 3
  add3 4
|})

(* Pipe operator test *)
let r49_a10 () =
  should_pass_src (base_header ^ {|
fn double(n: Int) -> Int = n * 2
fn inc(n: Int) -> Int = n + 1

fn test() -> Int =
  5 |> double |> inc
|})


(* ═══════════════════════════════════════════════════════════════════════════
   PROOF DECOMPOSITION + REATTACHMENT (regression for ELetProof bug)
   ═══════════════════════════════════════════════════════════════════════════ *)

let proof_decomp_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, Bool(..)]
import Tesl.String exposing [IsNonEmpty, String.requireNonEmpty]

record User {
  id: String ::: IsNonEmpty id
  name: String ::: IsNonEmpty name
}

fact Valid (s: String)

check isValid(s: String) -> s: String ::: Valid s =
  if True then
    ok s ::: Valid s
  else
    fail 400 "bad"

fn needValid(s: String ::: Valid s) -> String = s
|}

(* R49_LP01: let (x ::: p) = check ..., then use x ::: p in record — should compile *)
let r49_lp01 () =
  should_pass_src (proof_decomp_header ^ {|
fn build(raw: String) -> User =
  let (checked ::: p) = check String.requireNonEmpty(raw)
  let checkedName = check String.requireNonEmpty("test")
  User { id: checked ::: p, name: checkedName }
|})

(* R49_LP02: let (_ ::: p) = check ..., then use original ::: p in record — should compile *)
let r49_lp02 () =
  should_pass_src (proof_decomp_header ^ {|
fn build(raw: String) -> User =
  let (_ ::: p) = check String.requireNonEmpty(raw)
  let checkedName = check String.requireNonEmpty("test")
  User { id: raw ::: p, name: checkedName }
|})

(* R49_LP03: let x = check ..., then use plain x in record — should compile *)
let r49_lp03 () =
  should_pass_src (proof_decomp_header ^ {|
fn build(raw: String) -> User =
  let checkedId = check String.requireNonEmpty(raw)
  let checkedName = check String.requireNonEmpty("test")
  User { id: checkedId, name: checkedName }
|})

(* R49_LP04: fn + decompose + reattach via <| — should compile *)
let r49_lp04 () =
  should_pass_src (proof_decomp_header ^ {|
fn test(raw: String) -> String =
  let (val ::: pf) = check isValid(raw)
  needValid <| val ::: pf
|})

(* R49_LP05: fn + decompose, discard value, reattach to original — should compile *)
let r49_lp05 () =
  should_pass_src (proof_decomp_header ^ {|
fn test(raw: String) -> String =
  let (_ ::: pf) = check isValid(raw)
  needValid <| raw ::: pf
|})

(* R49_LP06: anonymous record literal in auth ok is rejected *)
let r49_lp06 () =
  should_fail_src "anonymous.*record\\|bare.*record\\|named.*constructor" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]

record Session { id: String }
fact Authenticated (s: Session)
capability readCookie

auth cookieAuth(request: HttpRequest) -> session: Session ::: Authenticated session
  requires [readCookie] =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something uid ->
      ok { id: uid } ::: Authenticated session
|})

(* R49_LP07: named constructor in auth ok is accepted *)
let r49_lp07 () =
  should_pass_src ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]

record Session { id: String }
fact Authenticated (s: Session)
capability readCookie

auth cookieAuth(request: HttpRequest) -> session: Session ::: Authenticated session
  requires [readCookie] =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something uid ->
      ok Session { id: uid } ::: Authenticated session
|})


(* ═══════════════════════════════════════════════════════════════════════════
   DEEP EDGE CASES (confidence-building for review #50)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R49_EC01: toJson stringCodec on ADT field rejected *)
let r49_ec01 () =
  should_fail_src "stringCodec.*encodes" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]

type Priority
  = Low
  | Medium
  | High

codec Priority { adtJson }
record Task { title: String, priority: Priority }
codec Task {
  toJson {
    title    -> "title"    with_codec stringCodec
    priority -> "priority" with_codec stringCodec
  }
  fromJson_forbidden
}
|})

(* R49_EC02: Maybe Priority + stringCodec in fromJson rejected *)
let r49_ec02 () =
  should_fail_src "stringCodec.*decodes" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Json exposing [stringCodec]

type Priority
  = Low
  | Medium
  | High

codec Priority { adtJson }
record Task { title: String, prio: Maybe Priority }
codec Task {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
      prio  <- "prio"  with_codec stringCodec
    }
  ]
}
|})

(* R49_EC03: intCodec on PosixMillis rejected — must use posixMillisCodec *)
let r49_ec03 () =
  should_fail_src "intCodec.*decodes" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [intCodec, stringCodec]
import Tesl.Time exposing [PosixMillis]

record Event { name: String, ts: PosixMillis }
codec Event {
  toJson_forbidden
  fromJson [
    {
      name <- "name" with_codec stringCodec
      ts   <- "ts"   with_codec intCodec
    }
  ]
}
|})

(* R49_EC04: posixMillisCodec on PosixMillis accepted *)
let r49_ec04 () =
  should_pass_src ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, posixMillisCodec]
import Tesl.Time exposing [PosixMillis]

record Event { name: String, ts: PosixMillis }
codec Event {
  toJson_forbidden
  fromJson [
    {
      name <- "name" with_codec stringCodec
      ts   <- "ts"   with_codec posixMillisCodec
    }
  ]
}
|})

(* R49_EC05: List String + intCodec rejected *)
let r49_ec05 () =
  should_fail_src "intCodec.*decodes" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.Json exposing [stringCodec, intCodec]

record Msg { tags: List String }
codec Msg {
  toJson_forbidden
  fromJson [
    {
      tags <- "tags" with_codec intCodec
    }
  ]
}
|})

(* R49_EC06: ELetProof inside case arm works *)
let r49_ec06 () =
  should_pass_src ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [IsNonEmpty, String.requireNonEmpty]

record User { id: String ::: IsNonEmpty id }

fn build(m: Maybe String) -> User =
  case m of
    Nothing -> fail 400 "missing"
    Something raw ->
      let (checked ::: p) = check String.requireNonEmpty(raw)
      User { id: checked ::: p }
|})

(* R49_EC07: chained proof decomposition works *)
let r49_ec07 () =
  should_pass_src ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, Bool(..)]

fact IsPositive (n: Int)
fact IsBig (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

check checkBig(n: Int) -> n: Int ::: IsBig n =
  if n > 100 then
    ok n ::: IsBig n
  else
    fail 400 "not big"

fn needBoth(n: Int ::: IsPositive n && IsBig n) -> Int = n

fn test(raw: Int) -> Int =
  let (a ::: p) = check checkPos(raw)
  let (b ::: q) = check checkBig(a)
  needBoth <| b ::: p && q
|})

(* R49_EC08: correct toJson types accepted *)
let r49_ec08 () =
  should_pass_src ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]

record Simple { name: String, age: Int }
codec Simple {
  toJson {
    name -> "name" with_codec stringCodec
    age  -> "age"  with_codec intCodec
  }
  fromJson_forbidden
}
|})


(* R49_EC09: stringCodec on newtype wrapping String is accepted — newtypes transparent at JSON *)
let r49_ec09 () =
  should_pass_src ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]

type NoteId = String

record Note { id: NoteId, title: String }
codec Note {
  toJson {
    id    -> "id"    with_codec stringCodec
    title -> "title" with_codec stringCodec
  }
  fromJson_forbidden
}
|})

(* R49_EC10: intCodec on newtype wrapping Int is accepted *)
let r49_ec10 () =
  should_pass_src ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [intCodec, stringCodec]

type Score = Int

record Result { name: String, score: Score }
codec Result {
  toJson_forbidden
  fromJson [
    {
      name  <- "name"  with_codec stringCodec
      score <- "score" with_codec intCodec
    }
  ]
}
|})

(* R49_EC11: stringCodec on newtype wrapping Int is still rejected *)
let r49_ec11 () =
  should_fail_src "stringCodec.*decodes" ({|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]

type Score = Int

record Result { name: String, score: Score }
codec Result {
  toJson_forbidden
  fromJson [
    {
      name  <- "name"  with_codec stringCodec
      score <- "score" with_codec stringCodec
    }
  ]
}
|})

(* ═══════════════════════════════════════════════════════════════════════════
   TEST REGISTRATION
   ═══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "Review49-Antagonistic" [
    "proof-soundness", [
      test_case "R49_P01 cross-subject reattachment rejected" `Quick r49_p01;
      test_case "R49_P02 proof fabrication in fn rejected" `Quick r49_p02;
      test_case "R49_P03 proof fabrication in handler rejected" `Quick r49_p03;
      test_case "R49_P04 establish cannot use fail" `Quick r49_p04;
      test_case "R49_P05 check cannot use direct proof" `Quick r49_p05;
      test_case "R49_P06 ok literal not binding rejected" `Quick r49_p06;
      test_case "R49_P07 proof wrong subject rejected" `Quick r49_p07;
      test_case "R49_P08 correct proof usage compiles" `Quick r49_p08;
    ];
    "shadowing", [
      test_case "R49_S01 let shadows param rejected" `Quick r49_s01;
      test_case "R49_S02 case binder shadows let rejected" `Quick r49_s02;
      test_case "R49_S03 nested let shadowing rejected" `Quick r49_s03;
    ];
    "type-system", [
      test_case "R49_T01 newtype not interchangeable" `Quick r49_t01;
      test_case "R49_T02 two newtypes not interchangeable" `Quick r49_t02;
      test_case "R49_T03 PosixMillis not Int" `Quick r49_t03;
      test_case "R49_T04 String not Int" `Quick r49_t04;
      test_case "R49_T05 mixed-type list rejected" `Quick r49_t05;
      test_case "R49_T06 record field type mismatch" `Quick r49_t06;
    ];
    "parser-syntax", [
      test_case "R49_X01 single-line if rejected" `Quick r49_x01;
      test_case "R49_X02 single-line ADT is alias not ADT" `Quick r49_x02;
      test_case "R49_X03 import after def rejected" `Quick r49_x03;
    ];
    "exhaustiveness", [
      test_case "R49_E01 non-exhaustive ADT case" `Quick r49_e01;
      test_case "R49_E02 Int case no catch-all" `Quick r49_e02;
      test_case "R49_E03 String case no catch-all" `Quick r49_e03;
    ];
    "capabilities", [
      test_case "R49_C01 calling fn without its cap" `Quick r49_c01;
    ];
    "codec-records", [
      test_case "R49_D01 stringCodec on ADT field rejected" `Quick r49_d01_bug;
      test_case "R49_D02 record proof field needs proof" `Quick r49_d02;
    ];
    "proof-decomposition", [
      test_case "R49_LP01 decompose+reattach in record" `Quick r49_lp01;
      test_case "R49_LP02 discard+reattach original in record" `Quick r49_lp02;
      test_case "R49_LP03 plain check in record" `Quick r49_lp03;
      test_case "R49_LP04 decompose+reattach via <|" `Quick r49_lp04;
      test_case "R49_LP05 discard+reattach original via <|" `Quick r49_lp05;
      test_case "R49_LP06 anonymous record in auth rejected" `Quick r49_lp06;
      test_case "R49_LP07 named constructor in auth accepted" `Quick r49_lp07;
    ];
    "edge-cases", [
      test_case "R49_EC01 toJson stringCodec on ADT rejected" `Quick r49_ec01;
      test_case "R49_EC02 Maybe Priority + stringCodec rejected" `Quick r49_ec02;
      test_case "R49_EC03 intCodec on PosixMillis rejected" `Quick r49_ec03;
      test_case "R49_EC04 posixMillisCodec on PosixMillis ok" `Quick r49_ec04;
      test_case "R49_EC05 List String + intCodec rejected" `Quick r49_ec05;
      test_case "R49_EC06 ELetProof inside case arm" `Quick r49_ec06;
      test_case "R49_EC07 chained proof decomposition" `Quick r49_ec07;
      test_case "R49_EC08 correct toJson types accepted" `Quick r49_ec08;
      test_case "R49_EC09 stringCodec on String-newtype ok" `Quick r49_ec09;
      test_case "R49_EC10 intCodec on Int-newtype ok" `Quick r49_ec10;
      test_case "R49_EC11 stringCodec on Int-newtype rejected" `Quick r49_ec11;
    ];
    "additional", [
      test_case "R49_A01 empty module valid" `Quick r49_a01;
      test_case "R49_A02 duplicate top-level rejected" `Quick r49_a02;
      test_case "R49_A03 constructor same as type rejected" `Quick r49_a03;
      test_case "R49_A04 multi-param fact compiles" `Quick r49_a04;
      test_case "R49_A05 ADT pattern matching compiles" `Quick r49_a05;
      test_case "R49_A06 integer overflow rejected" `Quick r49_a06;
      test_case "R49_A07 first-class functions" `Quick r49_a07;
      test_case "R49_A08 nested Maybe pattern" `Quick r49_a08;
      test_case "R49_A09 partial application" `Quick r49_a09;
      test_case "R49_A10 pipe operator" `Quick r49_a10;
    ];
  ]
