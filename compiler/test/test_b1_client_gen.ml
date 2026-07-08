(** B1 / A10 — client-generation soundness (external re-review §8.2).

    (a) checker bypass — `--generate-ts` / `--generate-elm` called Parser.parse
        then emitted, SKIPPING Compile, so a type-invalid program that fails
        `--check` still emitted a plausible client (exit 0).  Both generators are
        now gated behind the full checker.

    (b) constraint under-approximation — the Elm smart constructor manufactured a
        proof (`Just (axiom Fact input)`) from constraints extracted only from the
        `if` CONDITION, ignoring a nested guard on the ok-path.  A value satisfying
        the outer condition but failing the inner guard got a client proof the
        server rejects.  `extract_simple_constraints` is now TOTAL: it captures a
        check only when the body is provably `if <cond> then <ok> else <fail>`;
        a nested-guard / partial check falls back to a server-only decoder (which
        trusts a validated server RESPONSE via `D.map (axiom …)`) and emits NO
        client-side smart constructor. *)

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

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128+n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let with_src src f =
  let dir = Filename.temp_dir "tesl-b1" "" in
  let re = Str.regexp "module[ \t]+\\([A-Z][A-Za-z0-9_]*\\)" in
  ignore (Str.search_forward re src 0);
  let m = Str.matched_group 1 src in
  let buf = Buffer.create 16 in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
    else Buffer.add_char buf c) m;
  let path = Filename.concat dir (Buffer.contents buf ^ ".tesl") in
  let oc = open_out path in output_string oc src; close_out oc;
  Fun.protect ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains needle hay =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

(* ── fixtures ─────────────────────────────────────────────────────────────── *)
let type_invalid = {|#lang tesl
module Invalid exposing []
import Tesl.Prelude exposing [String, Int]
fn f(x: Int) -> Int = totallyUndefinedName x
|}

let nested_guard = {|#lang tesl
module NestedGuard exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.String exposing [String.length, String.startsWith]
fact ValidCode (s: String)
check checkCode(input: String) -> input: String ::: ValidCode input =
  if String.length input >= 3 then
    if String.startsWith input "AB" then
      ok input ::: ValidCode input
    else
      fail 400 "no AB"
  else
    fail 400 "too short"
fn useCode(c: String ::: ValidCode c) -> String = c
api CodeApi {
  post "/code" body payload: String -> String
}
|}

let full_capture = {|#lang tesl
module FullCapture exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.String exposing [String.length]
fact LongEnough (s: String)
check checkLong(input: String) -> input: String ::: LongEnough input =
  if String.length input >= 3 then
    ok input ::: LongEnough input
  else
    fail 400 "too short"
fn useLong(c: String ::: LongEnough c) -> String = c
api LongApi {
  post "/x" body payload: String -> String
}
|}

(* GitHub #25: Elm's D.mapN stops at map8; a record/entity with 9+ fields used
   to emit `D.map8` over the first 8 fields and reference the rest as unbound
   names (module did not compile).  9+ fields must use the applicative
   pipeline `D.succeed Ctor |> D.map2 (|>) …`; 8 fields keep D.map8. *)
let nine_fields = {|#lang tesl
module NineWide exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
record Nine {
  f1: String
  f2: String
  f3: String
  f4: String
  f5: String
  f6: String
  f7: String
  f8: String
  f9: String
}
api NineApi {
  post "/nine" body payload: String -> String
}
|}

let eight_fields = {|#lang tesl
module EightWide exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
record Eight {
  f1: String
  f2: String
  f3: String
  f4: String
  f5: String
  f6: String
  f7: String
  f8: String
}
api EightApi {
  post "/eight" body payload: String -> String
}
|}

(* A PosixMillis field crosses the wire as a bare epoch-millis int over HTTP,
   but the agent boundary renders it as {"epochMillis": <int>, "iso": "…"}
   (types.rkt enrichment).  The Elm decoder must accept BOTH shapes. *)
let posix_field = {|#lang tesl
module PosixWide exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Time exposing [PosixMillis]
record Meeting {
  title: String
  startsAt: PosixMillis
}
api MeetingApi {
  post "/meeting" body payload: String -> String
}
|}

(* GitHub #38 residual class: MoneyRate references through the TYPE_EXPR
   emission paths (records, newtypes) — the entity/IR path was fixed first and
   the record/newtype path kept emitting alias-specific undefined names
   (`moneyPerDurationDecoder`).  All positions must reference the ONE shared
   MoneyRate alias/codec, which must be DEFINED. *)
let rate_positions = {|#lang tesl
module RateWide exposing []
import Tesl.Prelude exposing [String, Int, Bool(..), List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Money exposing [Money, MoneyPerDuration, MoneyPerMass, Money.sek,
                            MoneyRate.perHour]
record Quote {
  base: MoneyPerDuration
  discount: Maybe MoneyPerDuration
  tiers: List MoneyPerMass
}
type ContractRate = MoneyPerDuration
handler quote() -> Quote =
  Quote { base: MoneyRate.perHour (Money.sek 95000),
          discount: Nothing,
          tiers: [] }
api QuoteApi {
  get "/quote" -> Quote
}
server QuoteServer for QuoteApi { quote = quote }
|}

(* ── tests ────────────────────────────────────────────────────────────────── *)
let gen_rejects_invalid flag () =
  with_src type_invalid (fun p ->
    let code, _ = run_cc [flag; p] in
    if code = 0 then failf "%s emitted a client for a type-invalid program (exit 0)" flag)

let gen_accepts_valid flag () =
  with_src full_capture (fun p ->
    let code, out = run_cc [flag; p] in
    if code <> 0 then failf "%s rejected a valid program:\n%s" flag out)

(* Elm: a nested-guard check must NOT manufacture a client proof from the partial
   outer condition — no `Just (axiom ValidCode …)` (that shape appears only in a
   client-side smart constructor).  A server-only decoder maps a decoded RESPONSE
   through `axiom` instead, which is sound. *)
let elm_nested_guard_no_manufacture () =
  with_src nested_guard (fun p ->
    let code, out = run_cc ["--generate-elm"; p] in
    if code <> 0 then failf "generate-elm failed on a valid nested-guard program:\n%s" out;
    if contains "Just (axiom ValidCode" out then
      failf "Elm manufactured a client proof from a PARTIAL nested-guard predicate:\n%s" out;
    (* it should still emit a server-only decoder that trusts a validated response *)
    if not (contains "axiom ValidCode" out) then
      failf "expected a server-only ValidCode decoder in the Elm output:\n%s" out)

(* Elm: a fully-captured check SHOULD still emit a sound client smart constructor
   guarded by the FULL predicate. *)
let elm_full_capture_smart () =
  with_src full_capture (fun p ->
    let code, out = run_cc ["--generate-elm"; p] in
    if code <> 0 then failf "generate-elm failed:\n%s" out;
    if not (contains "Just (axiom LongEnough" out) then
      failf "expected a client smart constructor for the fully-captured check:\n%s" out;
    if not (contains "String.length input >= 3" out) then
      failf "expected the full predicate in the smart constructor:\n%s" out)

(* GitHub #25 regression: 9-field record decoder must be the arity-unlimited
   pipeline (no D.map8, no unbound field names); every field decoded. *)
let elm_nine_fields_pipeline () =
  with_src nine_fields (fun p ->
    let code, out = run_cc ["--generate-elm"; p] in
    if code <> 0 then failf "generate-elm failed on a 9-field record:\n%s" out;
    if contains "D.map8" out then
      failf "9-field decoder still uses D.map8 (GitHub #25 regression):\n%s" out;
    if not (contains "D.succeed Nine" out) then
      failf "expected the applicative pipeline decoder for Nine:\n%s" out;
    List.iter (fun f ->
      let step = Printf.sprintf "|> D.map2 (|>) (D.field \"%s\"" f in
      if not (contains step out) then
        failf "field %s missing from the pipeline decoder:\n%s" f out)
      ["f1";"f2";"f3";"f4";"f5";"f6";"f7";"f8";"f9"])

(* Control: exactly 8 fields keeps the direct D.map8 form (snapshot-stable). *)
let elm_eight_fields_map8 () =
  with_src eight_fields (fun p ->
    let code, out = run_cc ["--generate-elm"; p] in
    if code <> 0 then failf "generate-elm failed on an 8-field record:\n%s" out;
    if not (contains "D.map8 Eight" out) then
      failf "expected D.map8 for exactly 8 fields:\n%s" out)

let elm_money_rate_all_positions () =
  with_src rate_positions (fun p ->
    let code, out = run_cc ["--generate-elm"; p] in
    if code <> 0 then failf "generate-elm failed on money-rate positions:\n%s" out;
    if not (contains "type alias MoneyRate" out) then
      failf "expected the shared MoneyRate alias to be DEFINED:\n%s" out;
    if not (contains "moneyRateDecoder :" out) then
      failf "expected moneyRateDecoder to be DEFINED:\n%s" out;
    (* the #38 signature: alias-specific names that nothing defines *)
    if contains "moneyPerDuration" out || contains "moneyPerMass" out then
      failf "record/newtype path emitted an alias-specific (undefined) codec name:\n%s" out;
    if contains ": MoneyPerDuration" out || contains ": MoneyPerMass" out then
      failf "record/newtype path emitted an alias-specific (undefined) TYPE name:\n%s" out)

let ts_money_rate_all_positions () =
  with_src rate_positions (fun p ->
    let code, out = run_cc ["--generate-ts"; p] in
    if code <> 0 then failf "generate-ts failed on money-rate positions:\n%s" out;
    if not (contains "per: z.string()" out) then
      failf "expected the tolerant MoneyRate zod schema:\n%s" out;
    if contains "moneyPerDuration" out then
      failf "TS emitted an alias-specific (undefined) name:\n%s" out)

(* PosixMillis decoder tolerance: bare int (HTTP) OR the agent-enriched
   {"epochMillis": …} object; encoding stays a bare int. *)
let elm_posix_field_tolerant_decoder () =
  with_src posix_field (fun p ->
    let code, out = run_cc ["--generate-elm"; p] in
    if code <> 0 then failf "generate-elm failed on a PosixMillis field:\n%s" out;
    if not (contains {|(D.oneOf [ D.int, D.field "epochMillis" D.int ])|} out) then
      failf "expected the tolerant PosixMillis decoder (bare int OR {epochMillis}):\n%s" out)

(* ── GitHub #36: imported-module types must be emitted, not just referenced ──
   The entrypoint's API references a record + fact declared in an imported
   module; the generated client previously mentioned `NewThing` / `NameSafe`
   in endpoint signatures without ever DEFINING them (uncompilable client). *)
let issue36_lib = {|#lang tesl
module Lib exposing [NameSafe, isName, NewThing]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
import Tesl.Json exposing [stringCodec]

fact NameSafe (name: String)

check isName(name: String) -> name: String ::: NameSafe name =
  if String.length name > 0 then
    ok name ::: NameSafe name
  else
    fail 400 "empty"

record NewThing {
  name: String ::: NameSafe name
}

codec NewThing {
  toJson_forbidden
  fromJson [
    { name <- "name" with_codec stringCodec via isName }
  ]
}
|}

let issue36_main = {|#lang tesl
module Main exposing [MainApi, MainServer]
import Tesl.Prelude exposing [String]
import Lib exposing [NameSafe, isName, NewThing]

api MainApi {
  post "/thing"
    body newThing: NewThing
    -> String
}

handler createThing(newThing: NewThing) -> String =
  newThing.name

server MainServer for MainApi {
  createThing = createThing
}
|}

let with_issue36_project f =
  let dir = Filename.temp_dir "tesl-i36" "" in
  let write name src =
    let p = Filename.concat dir name in
    let oc = open_out p in output_string oc src; close_out oc; p
  in
  let lib = write "lib.tesl" issue36_lib in
  let main = write "main.tesl" issue36_main in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) [lib; main];
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f main)

let elm_imported_types_emitted () =
  with_issue36_project (fun main ->
    let code, out = run_cc ["--generate-elm"; main] in
    if code <> 0 then failf "generate-elm failed on the multi-module project:\n%s" out;
    if not (contains "type alias NewThing" out) then
      failf "imported record NewThing referenced but not defined (#36):\n%s" out;
    if not (contains "type NameSafe" out) then
      failf "imported fact NameSafe referenced but not defined (#36):\n%s" out)

let ts_imported_types_emitted () =
  with_issue36_project (fun main ->
    let code, out = run_cc ["--generate-ts"; main] in
    if code <> 0 then failf "generate-ts failed on the multi-module project:\n%s" out;
    if not (contains "NewThingSchema" out) then
      failf "imported record NewThing schema missing from TS client (#36):\n%s" out;
    if not (contains "NameSafeSchema" out) then
      failf "imported fact NameSafe schema missing from TS client (#36):\n%s" out)

let () =
  run "B1-Client-Generation" [
    "checker bypass (a)", [
      test_case "--generate-ts rejects a type-invalid program" `Quick
        (gen_rejects_invalid "--generate-ts");
      test_case "--generate-elm rejects a type-invalid program" `Quick
        (gen_rejects_invalid "--generate-elm");
      test_case "--generate-ts accepts a valid program" `Quick
        (gen_accepts_valid "--generate-ts");
      test_case "--generate-elm accepts a valid program" `Quick
        (gen_accepts_valid "--generate-elm");
    ];
    "constraint totality (b)", [
      test_case "nested-guard check does NOT manufacture a client axiom" `Quick
        elm_nested_guard_no_manufacture;
      test_case "fully-captured check keeps a sound smart constructor" `Quick
        elm_full_capture_smart;
    ];
    "decoder arity (GitHub #25)", [
      test_case "9-field record uses the applicative pipeline" `Quick
        elm_nine_fields_pipeline;
      test_case "8-field record keeps D.map8" `Quick
        elm_eight_fields_map8;
    ];
    "PosixMillis decoder tolerance", [
      test_case "PosixMillis field decodes bare int OR {epochMillis}" `Quick
        elm_posix_field_tolerant_decoder;
    ];
    "imported types emitted (GitHub #36)", [
      test_case "elm client defines imported record + fact" `Quick
        elm_imported_types_emitted;
      test_case "ts client defines imported record + fact" `Quick
        ts_imported_types_emitted;
    ];
    "money rates emitted at every position (GitHub #38)", [
      test_case "elm: record/newtype/Maybe/List rate fields use the ONE defined MoneyRate" `Quick
        elm_money_rate_all_positions;
      test_case "ts: rate fields use the tolerant shared schema" `Quick
        ts_money_rate_all_positions;
    ];
  ]
