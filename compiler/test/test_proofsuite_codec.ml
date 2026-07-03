(** ProofSuite family K — Codec-attached proofs / codec bypass.

    NEGATIVE proof tests: code that must NOT compile.  TESL codecs
    (`codec T { toJson {...} fromJson [...] }`) connect JSON wire data to typed
    values; a decoder field whose type carries a proof predicate
    (`name: String ::: ValidName name`) must establish that proof through a
    `via <check>` clause, and a `with_codec C` on a field must match the field's
    type.  The captured/decoded value may only reach a proof position if the
    codec/capture actually established the proof.

    K-VIA   — a proof-carrying decoder field with no `via`, or a `via` that
              establishes the wrong proof → `error[V001] … requires proof
              predicates … (but has no `via` validation / not established by any
              `via` function)`.
    K-TYPE  — `with_codec` whose builtin codec does not match the field type, in
              both encode and decode direction → `error[V001] … has type `T` but
              `cCodec` encodes/decodes-to `U``.
    K-FIELD — a codec entry naming a field that does not exist on the type.
    K-ADT   — `adtJson` misuse and ADT/record codec-kind mismatch are rejected.
    K-BYPASS — a `capture` that establishes no proof wired to a proof-carrying
              handler param is rejected at the HTTP boundary.

    Hardening: a static rejection must never leak a runtime token
    (`raise-user-error`, `check-fail`, `.rkt` trace).  `should_fail` asserts
    this. *)

open Alcotest

(* ── Compiler discovery ──────────────────────────────────────────────────── *)

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

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psK" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
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

(* Hardening *)
let runtime_leak_re =
  Str.regexp_case_fold "raise-user-error\\|check-fail\\|\\.rkt:[0-9]\\|context\\.\\.\\.:\\|raco "

let assert_no_runtime_leak ~ctx out =
  try
    ignore (Str.search_forward runtime_leak_re out 0);
    failf "%s: rejection LEAKED to runtime, output:\n%s" ctx out
  with Not_found -> ()

let should_fail ?(label = "") pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let ctx = if label = "" then "should_fail" else label in
    assert_no_runtime_leak ~ctx out;
    if code = 0 then failf "%s: expected static failure matching %S, but COMPILED.\nsrc:\n%s" ctx pat src;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "%s: expected failure matching %S, got:\n%s" ctx pat out)

let should_pass ?(label = "") src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let ctx = if label = "" then "should_pass" else label in
    if code <> 0 then failf "%s: expected COMPILE, but failed:\n%s" ctx out)

(* ════════════════════════════════════════════════════════════════════════
   K-TYPE — `with_codec` codec ≠ field type, encode + decode directions.
   builtin codec ↔ base type: stringCodec/String, intCodec/Int, boolCodec/Bool.
   Each pair (codec, mismatched field type) must be rejected with V001.
   ════════════════════════════════════════════════════════════════════════ *)

let type_pat = "has type.*but.*\\(encodes\\|decodes\\)\\|V001\\|matching codec"

(* (codec name, codec's encoded type, an import for that field type, a field
   type that does NOT match the codec) *)
type codec_pair = { codec : string; field_ty : string; field_import : string }

(* Mismatched pairs: codec X on a field of a different builtin type. *)
let type_mismatches = [
  (* stringCodec on Int / Bool *)
  { codec = "stringCodec"; field_ty = "Int";    field_import = "Int" };
  { codec = "stringCodec"; field_ty = "Bool";   field_import = "Bool(..)" };
  (* intCodec on String / Bool *)
  { codec = "intCodec";    field_ty = "String"; field_import = "String" };
  { codec = "intCodec";    field_ty = "Bool";   field_import = "Bool(..)" };
  (* boolCodec on String / Int *)
  { codec = "boolCodec";   field_ty = "String"; field_import = "String" };
  { codec = "boolCodec";   field_ty = "Int";    field_import = "Int" };
]

let type_encode_src p modname =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\nimport Tesl.Prelude exposing [%s]\nimport Tesl.Json exposing [%s]\n\
     record R { f: %s }\ncodec R {\n  toJson {\n    f -> \"f\" with_codec %s\n  }\n  fromJson_forbidden\n}\n"
    modname p.field_import p.codec p.field_ty p.codec

let type_decode_src p modname =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\nimport Tesl.Prelude exposing [%s]\nimport Tesl.Json exposing [%s]\n\
     record R { f: %s }\ncodec R {\n  toJson_forbidden\n  fromJson [\n    { f <- \"f\" with_codec %s }\n  ]\n}\n"
    modname p.field_import p.codec p.field_ty p.codec

let k_type_matrix () =
  List.concat_map (fun p ->
    let mk dir build =
      let modname = Printf.sprintf "KType%s%s%s" p.codec p.field_ty dir in
      let modname = String.map (fun c -> if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' then c else 'X') modname in
      let label = Printf.sprintf "K-TYPE %s on %s/%s" p.codec p.field_ty dir in
      test_case label `Quick (fun () -> should_fail ~label type_pat (build p modname))
    in
    [ mk "encode" type_encode_src; mk "decode" type_decode_src ]
  ) type_mismatches

(* ════════════════════════════════════════════════════════════════════════
   K-VIA — proof-carrying decoder field coverage.
   ════════════════════════════════════════════════════════════════════════ *)

let via_pat = "requires proof predicates\\|has no .via. validation\\|not established by any .via.\\|V001"

let test_via_missing () =
  should_fail ~label:"K-VIA missing via" via_pat {|
#lang tesl
module KViaMissing exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
fact ValidName (s: String)
check checkName(s: String) -> s: String ::: ValidName s =
  if String.length s > 0 then
    ok s ::: ValidName s
  else
    fail 400 "empty"
record Person { name: String ::: ValidName name }
codec Person {
  toJson_forbidden
  fromJson [
    { name <- "name" with_codec stringCodec }
  ]
}
|}

let test_via_wrong_proof () =
  should_fail ~label:"K-VIA wrong proof" via_pat {|
#lang tesl
module KViaWrong exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
fact ValidName (s: String)
fact ValidAge (s: String)
check checkAge(s: String) -> s: String ::: ValidAge s =
  if String.length s > 0 then
    ok s ::: ValidAge s
  else
    fail 400 "bad"
record Person { name: String ::: ValidName name }
codec Person {
  toJson_forbidden
  fromJson [
    { name <- "name" with_codec stringCodec via checkAge }
  ]
}
|}

let test_via_missing_one_of_two_fields () =
  (* Two proof-carrying fields, only one given a via → the other must error.
     Field names deliberately NON-keyword (`nick`/`addr`); the keyword-named
     case (`email`) is covered separately below. *)
  should_fail ~label:"K-VIA one of two missing" via_pat {|
#lang tesl
module KViaPartial exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
fact ValidNick (s: String)
fact ValidAddr (s: String)
check checkNick(s: String) -> s: String ::: ValidNick s =
  if String.length s > 0 then
    ok s ::: ValidNick s
  else
    fail 400 "empty"
check checkAddr(s: String) -> s: String ::: ValidAddr s =
  if String.length s > 0 then
    ok s ::: ValidAddr s
  else
    fail 400 "empty"
record Person { nick: String ::: ValidNick nick, addr: String ::: ValidAddr addr }
codec Person {
  toJson_forbidden
  fromJson [
    {
      nick <- "nick" with_codec stringCodec via checkNick
      addr <- "addr" with_codec stringCodec
    }
  ]
}
|}

(* A `fromJson` decoder field whose NAME is a reserved keyword token (e.g.
   `email`) is parsed via `expect_ident` in parse_codec_form (the same
   keyword-tolerant path used for record fields), so a `DecodeField` node is
   produced and the proof-coverage check sees it.  A proof-carrying decoder
   field named `email` with NO `via` therefore has its missing `via` correctly
   flagged. *)
let test_via_keyword_field_name_missing_via () =
  should_fail ~label:"K-VIA keyword field name decoded, missing via" via_pat {|
#lang tesl
module KViaKeyword exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
fact ValidName (s: String)
fact ValidEmail (s: String)
check checkName(s: String) -> s: String ::: ValidName s =
  if String.length s > 0 then
    ok s ::: ValidName s
  else
    fail 400 "empty"
check checkEmail(s: String) -> s: String ::: ValidEmail s =
  if String.length s > 0 then
    ok s ::: ValidEmail s
  else
    fail 400 "empty"
record Person { name: String ::: ValidName name, email: String ::: ValidEmail email }
codec Person {
  toJson_forbidden
  fromJson [
    {
      name <- "name" with_codec stringCodec via checkName
      email <- "email" with_codec stringCodec
    }
  ]
}
|}

(* ════════════════════════════════════════════════════════════════════════
   K-FIELD — codec entry references a field that does not exist.
   ════════════════════════════════════════════════════════════════════════ *)

let field_pat = "does not exist on type\\|valid fields on\\|V001"

let test_field_nonexistent_encode () =
  should_fail ~label:"K-FIELD nonexistent encode" field_pat {|
#lang tesl
module KFieldEnc exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Person { name: String }
codec Person {
  toJson {
    nope -> "nope" with_codec stringCodec
  }
  fromJson_forbidden
}
|}

let test_field_nonexistent_decode () =
  should_fail ~label:"K-FIELD nonexistent decode" field_pat {|
#lang tesl
module KFieldDec exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Person { name: String }
codec Person {
  toJson_forbidden
  fromJson [
    { ghost <- "ghost" with_codec stringCodec }
  ]
}
|}

(* ════════════════════════════════════════════════════════════════════════
   K-UDEF — a user-defined codec name applied to a field of a different type.
   `with_codec Inner` on a `String` field references the wrong head type.
   ════════════════════════════════════════════════════════════════════════ *)

let udef_pat = "references a different type\\|has type.*but.*with_codec\\|V001"

let test_userdef_codec_wrong_type () =
  should_fail ~label:"K-UDEF user codec wrong type" udef_pat {|
#lang tesl
module KUdefWrong exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec, intCodec]
record Inner { x: Int }
record Outer { name: String, inner: Inner }
codec Inner {
  toJson {
    x -> "x" with_codec intCodec
  }
  fromJson_forbidden
}
codec Outer {
  toJson {
    name -> "name" with_codec Inner
    inner -> "inner" with_codec Inner
  }
  fromJson_forbidden
}
|}

(* ════════════════════════════════════════════════════════════════════════
   K-ADT — adtJson misuse / codec-kind mismatch is rejected.
   The codec validator verifies that `adtJson` is applied to an ADT (not a
   record/entity) and that a record-field-style codec is applied to a record
   (not an ADT); both mismatches below are rejected.
   ════════════════════════════════════════════════════════════════════════ *)

(* adtJson on a record is rejected (adtJson encodes a constructor name; a record
   has no constructors). *)
let test_adtjson_on_record_rejected () =
  should_fail ~label:"K-ADT adtJson on record" "requires an ADT target" {|
#lang tesl
module KAdtRecord exposing []
import Tesl.Prelude exposing [String]
record Person { name: String }
codec Person {
  adtJson
}
|}

(* A record-field-style codec applied to an ADT (which has no fields, only
   constructors) is rejected and requires `adtJson` instead. *)
let test_record_codec_on_adt_rejected () =
  should_fail ~label:"K-ADT record-codec on ADT" "requires a record/entity target" {|
#lang tesl
module KFieldCodecOnAdt exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
type Color
  = Red
  | Green
  | Blue
codec Color {
  toJson {
    name -> "name" with_codec stringCodec
  }
  fromJson_forbidden
}
|}

(* ════════════════════════════════════════════════════════════════════════
   K-BYPASS — capture/body proof-coverage at the HTTP boundary.
   `check_server_handler_binding` reconciles a handler's proof-carrying
   parameter against the proof established by the api endpoint clause
   (`capture`/`body`) the server binding connects — mirroring the codec
   proof-coverage check — so a `capture` that establishes no proof cannot be
   wired to a proof-carrying handler param.

   Below: a handler demands `::: TodoId todoId` but the wiring establishes no
   such proof; both cases are rejected.
   ════════════════════════════════════════════════════════════════════════ *)

(* The handler param `todoId: String ::: TodoId todoId` is wired to a `capture
   todoId: String` (no proof) backed by `capture todoIdCapture: String using
   stringCodec` (no `via`).  check_server_handler_binding reconciles capture/body
   proofs (mirroring the codec proof-coverage check), so the dropped proof
   obligation at the HTTP entry boundary is rejected. *)
let test_capture_no_proof_feeds_proof_param_rejected () =
  should_fail ~label:"K-BYPASS capture w/o proof → proof param"
    "obligation is lost at the HTTP boundary" {|
#lang tesl
module KCapBypass exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
fact TodoId (todoId: String)
check isTodoId(todoId: String) -> todoId: String ::: TodoId todoId =
  if String.length todoId > 0 then
    ok todoId ::: TodoId todoId
  else
    fail 400 "bad"
capture todoIdCapture: String using stringCodec
handler getTodo(todoId: String ::: TodoId todoId) -> String requires [] = todoId
api TodoApi {
  get "/todos/:todoId"
    capture todoId: String via todoIdCapture
    -> String
}
server S for TodoApi {
  getTodo = getTodo
}
|}

(* The capture declaration *declares* `::: TodoId todoId` but provides no `via`
   check to establish it (`using stringCodec` alone cannot establish a proof).
   It requires a `via` like codec decoder fields do, so this is rejected. *)
let test_capture_declares_proof_no_via_rejected () =
  should_fail ~label:"K-BYPASS capture declares proof, no via"
    "has no `via` validation" {|
#lang tesl
module KCapNoVia exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Json exposing [stringCodec]
fact TodoId (todoId: String)
capture todoIdCapture: String ::: TodoId todoId using stringCodec
handler getTodo(todoId: String ::: TodoId todoId) -> String requires [] = todoId
api TodoApi {
  get "/todos/:todoId"
    capture todoId: String ::: TodoId todoId via todoIdCapture
    -> String
}
server S for TodoApi {
  getTodo = getTodo
}
|}

(* ════════════════════════════════════════════════════════════════════════
   K-POS — positive companions (must compile)
   ════════════════════════════════════════════════════════════════════════ *)

let pos_via_establishes_proof () =
  should_pass ~label:"K-POS via establishes field proof" {|
#lang tesl
module PosK_Via exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
fact ValidName (s: String)
check checkName(s: String) -> s: String ::: ValidName s =
  if String.length s > 0 then
    ok s ::: ValidName s
  else
    fail 400 "empty"
record Person { name: String ::: ValidName name }
codec Person {
  toJson_forbidden
  fromJson [
    { name <- "name" with_codec stringCodec via checkName }
  ]
}
|}

let pos_decoded_proof_consumed_downstream () =
  (* The decoded, proof-carrying field is consumed by a fn requiring that proof. *)
  should_pass ~label:"K-POS decoded proof consumed downstream" {|
#lang tesl
module PosK_Downstream exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
fact ValidName (s: String)
check checkName(s: String) -> s: String ::: ValidName s =
  if String.length s > 0 then
    ok s ::: ValidName s
  else
    fail 400 "empty"
record Person { name: String ::: ValidName name }
codec Person {
  toJson_forbidden
  fromJson [
    { name <- "name" with_codec stringCodec via checkName }
  ]
}
fn useName(s: String ::: ValidName s) -> String = s
fn consume(p: Person) -> String = useName p.name
|}

let pos_builtin_codecs_match_types () =
  should_pass ~label:"K-POS builtin codecs match field types" {|
#lang tesl
module PosK_Match exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Json exposing [stringCodec, intCodec, boolCodec]
record Task { id: String, priority: Int, done: Bool }
codec Task {
  toJson {
    id -> "id" with_codec stringCodec
    priority -> "priority" with_codec intCodec
    done -> "done" with_codec boolCodec
  }
  fromJson [
    {
      id <- "id" with_codec stringCodec
      priority <- "priority" with_codec intCodec
      done <- "done" with_codec boolCodec
    }
  ]
}
|}

let pos_adtjson_correct () =
  should_pass ~label:"K-POS adtJson on ADT" {|
#lang tesl
module PosK_Adt exposing []
import Tesl.Prelude exposing [String]
type Status
  = Active
  | Closed
codec Status {
  adtJson
}
|}

let pos_newtype_field_transparent () =
  (* A String-backed newtype field accepts stringCodec (transparent JSON). *)
  should_pass ~label:"K-POS newtype field stringCodec" {|
#lang tesl
module PosK_Newtype exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
type Email = String
record Contact { email: Email, label: String }
codec Contact {
  toJson {
    email -> "email" with_codec stringCodec
    label -> "label" with_codec stringCodec
  }
  fromJson [
    {
      email <- "email" with_codec stringCodec
      label <- "label" with_codec stringCodec
    }
  ]
}
|}

let pos_capture_with_via_establishes_proof () =
  should_pass ~label:"K-POS capture with via establishes proof" {|
#lang tesl
module PosK_Capture exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
fact TodoId (todoId: String)
check isTodoId(todoId: String) -> todoId: String ::: TodoId todoId =
  if String.length todoId > 0 then
    ok todoId ::: TodoId todoId
  else
    fail 400 "bad"
capture todoIdCapture: String ::: TodoId todoId using stringCodec via isTodoId
handler getTodo(todoId: String ::: TodoId todoId) -> String requires [] = todoId
api TodoApi {
  get "/todos/:todoId"
    capture todoId: String ::: TodoId todoId via todoIdCapture
    -> String
}
server TodoServer for TodoApi {
  getTodo = getTodo
}
|}

let pos_userdef_nested_codec () =
  (* A user-defined codec name (`Inner`) correctly used for a nested-record
     field whose type IS `Inner`. *)
  should_pass ~label:"K-POS user-defined nested codec" {|
#lang tesl
module PosK_Udef exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec, intCodec]
record Inner { x: Int }
record Outer { name: String, inner: Inner }
codec Inner {
  toJson {
    x -> "x" with_codec intCodec
  }
  fromJson_forbidden
}
codec Outer {
  toJson {
    name -> "name" with_codec stringCodec
    inner -> "inner" with_codec Inner
  }
  fromJson_forbidden
}
|}

let pos_plain_record_codec () =
  should_pass ~label:"K-POS plain record codec" {|
#lang tesl
module PosK_Plain exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec, intCodec]
record NewTask { title: String, priority: Int }
codec NewTask {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
      priority <- "priority" with_codec intCodec
    }
  ]
}
|}

let pos_codec_cross_field_via () =
  (* A cross-field `} via check` on the closing brace, with each field validated.
     Mirrors example/learn/lesson12-records-with-proofs.tesl. *)
  should_pass ~label:"K-POS cross-field via" {|
#lang tesl
module PosK_Cross exposing []
import Tesl.Prelude exposing [Int, String, Fact, detachFact]
import Tesl.Json exposing [intCodec]
fact IsPositive (n: Int)
check checkPositiveInt(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "neg"
fact PriceExceedsQuantity (price: Int, quantity: Int)
check checkPriceExceedsQuantity(price: Int, quantity: Int) -> price: Int ::: PriceExceedsQuantity price quantity =
  if price > quantity then
    ok price ::: PriceExceedsQuantity price quantity
  else
    fail 400 "no"
record OrderLine {
  price: Int ::: IsPositive price
  quantity: Int ::: IsPositive quantity
} ::: PriceExceedsQuantity price quantity
codec OrderLine {
  toJson_forbidden
  fromJson [
    {
      price <- "price" with_codec intCodec via checkPositiveInt
      quantity <- "quantity" with_codec intCodec via checkPositiveInt
    } via checkPriceExceedsQuantity
  ]
}
|}

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  run "ProofSuite-K-Codec" [
    "K-TYPE with_codec type mismatch", k_type_matrix ();
    "K-VIA decoder proof coverage", [
      test_case "proof field missing via" `Quick test_via_missing;
      test_case "via establishes wrong proof" `Quick test_via_wrong_proof;
      test_case "one of two proof fields missing via" `Quick test_via_missing_one_of_two_fields;
      test_case "keyword field name decoded, missing via" `Quick test_via_keyword_field_name_missing_via;
    ];
    "K-FIELD nonexistent codec field", [
      test_case "nonexistent field (encode)" `Quick test_field_nonexistent_encode;
      test_case "nonexistent field (decode)" `Quick test_field_nonexistent_decode;
    ];
    "K-UDEF user-defined codec mismatch", [
      test_case "user-defined codec on wrong field type" `Quick test_userdef_codec_wrong_type;
    ];
    "K-ADT adtJson / codec-kind mismatch", [
      test_case "adtJson on a record rejected" `Quick test_adtjson_on_record_rejected;
      test_case "record-field codec on an ADT rejected" `Quick test_record_codec_on_adt_rejected;
    ];
    "K-BYPASS capture proof coverage", [
      test_case "capture w/o proof feeds proof param rejected" `Quick test_capture_no_proof_feeds_proof_param_rejected;
      test_case "capture declares proof but has no via rejected" `Quick test_capture_declares_proof_no_via_rejected;
    ];
    "K-POS positive companions", [
      test_case "via establishes a field proof" `Quick pos_via_establishes_proof;
      test_case "decoded proof consumed downstream" `Quick pos_decoded_proof_consumed_downstream;
      test_case "builtin codecs match field types" `Quick pos_builtin_codecs_match_types;
      test_case "adtJson correctly used on ADT" `Quick pos_adtjson_correct;
      test_case "newtype field transparent stringCodec" `Quick pos_newtype_field_transparent;
      test_case "user-defined nested codec compiles" `Quick pos_userdef_nested_codec;
      test_case "capture with via establishes proof" `Quick pos_capture_with_via_establishes_proof;
      test_case "plain record codec compiles" `Quick pos_plain_record_codec;
      test_case "cross-field via codec compiles" `Quick pos_codec_cross_field_via;
    ];
  ]
