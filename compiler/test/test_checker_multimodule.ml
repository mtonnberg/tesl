(** 2026-07 multi-module matrix — checker/validator hole batch.

    All eight bugs shared one generator: checker/validator metadata tables
    built from LOCAL decls only (entity columns, codec target types,
    newtype→base, record proof-anns/invariants, fromJson codec table), so the
    identical program was accepted same-module but falsely rejected — or, for
    the proof-enforcement holes, falsely ACCEPTED — when the type came through
    an import.  Fixed by scope-accurate harvests (exposing-filtered,
    local-wins — mirroring emit_racket's #40 record harvest):

    1. aggregate+where type hole — classify_lowered_query (checker.ml)
       hardcoded Int on the where-lowered selectSum/Max/Min path; now refined
       by the queried field's declared type (Money column → Money).
    2. groupBy field validator (validation_advanced.ml check_group_by_rules)
       read local entity decls only → V001 "field does not exist" on an
       imported entity.
    3. codec cross-module: (a) ctx.codec_decode_types was local-only so
       `decodeAs` targeting an imported module's codec was rejected;
       (b) check_codec_target_types' known-type set was local-only so a codec
       in Lib for a record imported from Recs was V001-rejected.
    4. check_capture_codec_types' newtype→base map was local-only (imported
       newtype capture spuriously rejected) and its hint suggested the
       non-parsing `using <TypeName>` spelling.
    5. newtype capture runtime wrap — the validator-endorsed
       `capturer uid: UserId using stringCodec` bound the RAW base value;
       emit_capture now wraps the parsed segment in the newtype ctor when the
       binding type is a (local or imported) newtype over the codec's output.
    6. record ctor proof/invariant enforcement: imported records' field
       proof-anns + cross-field invariants were invisible (violating
       construction PASSED — soundness hole, fail-open, no runtime backstop),
       and same-module TEST blocks were never walked at all.
    7. exists/pack leak — consuming an exists-returning fn's result as its
       declared underlying type trapped at runtime (raw packed-exists struct
       into string-length); raw-value (dsl/private) now projects the packed
       body, same-module and cross-module alike.
    8. diagnostics: (a) P001 undeclared-capability now carries the
       declare-it-in-a-shared-module guidance; (b) V001 inside an imported
       module's ::: clause is anchored at the imported file (locked here —
       fixed by Compile.cross_module_diags). *)

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

let contains needle hay =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

(* Write an n-file project into a temp dir; hand `f` an accessor by filename. *)
let with_files (files : (string * string) list) (f : (string -> string) -> unit) =
  let dir = Filename.temp_dir "tesl-mm" "" in
  let paths = List.map (fun (name, src) ->
    let p = Filename.concat dir name in
    let oc = open_out p in output_string oc src; close_out oc;
    (name, p)
  ) files in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (_, p) -> try Sys.remove p with _ -> ()) paths;
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f (fun name -> List.assoc name paths))

let check_ok what path =
  let code, out = run_cc ["--check"; path] in
  if code <> 0 then failf "--check of %s must PASS but failed:\n%s" what out;
  out

let check_fails what path =
  let code, out = run_cc ["--check"; path] in
  if code = 0 then failf "--check of %s must REJECT but passed:\n%s" what out;
  out

let emit_ok what path =
  let code, out = run_cc [path] in
  if code <> 0 then failf "emit of %s failed:\n%s" what out;
  out

(* ── 1. aggregate + where: field-type refinement on the lowered path ─────── *)

let b1_src ret = Printf.sprintf {|module Main exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.DB exposing [dbRead]
import Tesl.Database exposing [Database, Memory]
import Tesl.Money exposing [Money, Money.usd, Money.minorUnits]

entity L table "b1_ls" primaryKey id {
  id: String
  cat: String
  price: Money
}

database D = Database {
  entities: [L]
  backend: Memory
}

fn sumIn(c: String) -> %s requires [dbRead] =
  with database D { selectSum l.price from L where l.cat == c }
|} ret

let bug1_money_annotation_accepted () =
  with_files [("main.tesl", b1_src "Money")] (fun p ->
    ignore (check_ok "Money-sum-with-where (-> Money)" (p "main.tesl")))

let bug1_int_annotation_rejected () =
  with_files [("main.tesl", b1_src "Int")] (fun p ->
    let out = check_fails "Money-sum-with-where (-> Int)" (p "main.tesl") in
    if not (contains "Money" out) then
      failf "the -> Int rejection must mention the real Money result:\n%s" out)

(* ── 2. groupBy on an imported entity ────────────────────────────────────── *)

let b2_lib = {|module Lib exposing [Item, Store]
import Tesl.Prelude exposing [Int, String, List]
import Tesl.Database exposing [Database, Memory]

entity Item table "b2_items" primaryKey id {
  id: String
  category: String
  qty: Int
}

database Store = Database {
  entities: [Item]
  backend: Memory
}
|}

let b2_main = {|module Main exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.Tuple exposing [Tuple2]
import Tesl.DB exposing [dbRead]
import Lib exposing [Item, Store]

fn countsPerCategory() -> List (Tuple2 String Int) requires [dbRead] =
  with database Store { selectCountBy i from Item groupBy i.category }
|}

let bug2_groupby_imported_entity () =
  with_files [("lib.tesl", b2_lib); ("main.tesl", b2_main)] (fun p ->
    ignore (check_ok "groupBy on imported entity" (p "main.tesl")));
  (* the validator must still reject a genuinely unknown field *)
  let bad = Str.global_replace (Str.regexp_string "i.category") "i.nosuch" b2_main in
  with_files [("lib.tesl", b2_lib); ("main.tesl", bad)] (fun p ->
    let out = check_fails "groupBy unknown field on imported entity" (p "main.tesl") in
    if not (contains "does not exist on entity" out) then
      failf "unknown groupBy field must keep its V001:\n%s" out)

(* ── 3a. decodeAs targeting a codec declared in an imported module ───────── *)

let b3a_lib = {|module Lib exposing [Simple]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]

record Simple {
  label: String
}

codec Simple {
  toJson {
    label -> "label" with_codec stringCodec
  }
  fromJson [
    {
      label <- "label" with_codec stringCodec
    }
  ]
}
|}

let b3a_main = {|module Main exposing [parseSimple]
import Tesl.Prelude exposing [String]
import Tesl.Agent exposing [decodeAs]
import Lib exposing [Simple]

fn parseSimple(j: String) -> Simple =
  decodeAs "Simple" j
|}

let bug3a_decodeas_imported_codec () =
  with_files [("lib.tesl", b3a_lib); ("main.tesl", b3a_main)] (fun p ->
    ignore (check_ok "decodeAs on imported codec" (p "main.tesl")))

(* ── 3b. codec declared in Lib for a record imported from Recs ───────────── *)

let b3b_recs = {|module Recs exposing [Payload]
import Tesl.Prelude exposing [Int, String]

record Payload {
  label: String
  amount: Int
}
|}

let b3b_lib = {|module Lib exposing [payloadTag]
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
import Recs exposing [Payload]

codec Payload {
  toJson {
    label -> "label" with_codec stringCodec
    amount -> "amount" with_codec intCodec
  }
  fromJson [
    {
      label <- "label" with_codec stringCodec
      amount <- "amount" with_codec intCodec
    }
  ]
}

fn payloadTag(p: Payload) -> String =
  p.label
|}

let bug3b_codec_for_imported_record () =
  with_files [("recs.tesl", b3b_recs); ("lib.tesl", b3b_lib)] (fun p ->
    ignore (check_ok "codec for imported record (lib)" (p "lib.tesl"));
    ignore (emit_ok "codec for imported record (lib emit)" (p "lib.tesl")));
  (* a codec whose target exists NOWHERE must still be rejected *)
  let bad = Str.global_replace (Str.regexp_string "import Recs exposing [Payload]") "" b3b_lib in
  let bad = Str.global_replace (Str.regexp_string "fn payloadTag(p: Payload) -> String =\n  p.label") "" bad in
  with_files [("recs.tesl", b3b_recs); ("lib.tesl", bad)] (fun p ->
    let out = check_fails "codec for truly-unknown type" (p "lib.tesl") in
    if not (contains "refers to unknown type" out) then
      failf "codec for a truly-unknown type must keep its V001:\n%s" out)

(* ── 4+5. newtype capture: imported newtype accepted, hint fixed, emit wrap ─ *)

let b45_lib = {|module Lib exposing [UserId]
import Tesl.Prelude exposing [String]

type UserId = String
|}

let b45_main codec = Printf.sprintf {|module Main exposing [MainServer]
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
import Lib exposing [UserId]

handler getUser(uid: UserId) -> String =
  "user-${uid.value}"

capturer uidCapture: uid: UserId using %s

api MainApi {
  get "/users/:uid"
    capture uid: UserId via uidCapture
    -> String
  get "/plain/:tag"
    capture tag: String using stringCodec
    -> String
}

server MainServer for MainApi {
  getUser = getUser
  plainTag = plainTag
}

handler plainTag(tag: String) -> String =
  tag
|} codec

let bug4_imported_newtype_capture_accepted () =
  with_files [("lib.tesl", b45_lib); ("main.tesl", b45_main "stringCodec")] (fun p ->
    ignore (check_ok "imported newtype capture via stringCodec" (p "main.tesl")))

let bug4_hint_names_a_codec_spelling () =
  with_files [("lib.tesl", b45_lib); ("main.tesl", b45_main "intCodec")] (fun p ->
    let out = check_fails "newtype capture with wrong codec" (p "main.tesl") in
    if not (contains "using stringCodec" out) then
      failf "the hint must suggest the codec matching the newtype's base:\n%s" out;
    if contains "using UserId" out then
      failf "the hint must not suggest the non-parsing `using UserId` spelling:\n%s" out)

let bug5_capture_newtype_wrap_emit_shape () =
  with_files [("lib.tesl", b45_lib); ("main.tesl", b45_main "stringCodec")] (fun p ->
    let out = emit_ok "newtype capture emit" (p "main.tesl") in
    (* newtype-typed capture: parsed segment wrapped in the newtype ctor,
       check-fail passthrough preserved *)
    if not (contains "(UserId tesl-cap-parsed)" out) then
      failf "newtype capture must wrap the parsed segment in the newtype ctor:\n%s" out;
    if not (contains "(check-fail? tesl-cap-parsed)" out) then
      failf "the wrap must pass check-fail results through untouched:\n%s" out;
    (* plain String capture keeps the bare parser *)
    if not (contains "#:parser string-segment" out) then
      failf "a plain String capture must keep the unwrapped parser:\n%s" out)

(* ── 6. record ctor proof/invariant enforcement: imports + test blocks ───── *)

let b6_lib = {|module Lib exposing [
  SafeTitle, checkSafeTitle,
  Positive, isPositive,
  PriceExceedsQuantity, checkPEQ,
  Msg, OrderLine,
]
import Tesl.Prelude exposing [Int, String, Fact]
import Tesl.String exposing [String.length]

fact SafeTitle (t: String)

check checkSafeTitle(s: String) -> s: String ::: SafeTitle s =
  if String.length s > 0 && String.length s <= 120 then
    ok s ::: SafeTitle s
  else
    fail 400 "bad title"

fact Positive (n: Int)

check isPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "must be positive"

fact PriceExceedsQuantity (price: Int, quantity: Int)

check checkPEQ(price: Int, quantity: Int) -> price: Int ::: PriceExceedsQuantity price quantity =
  if price > quantity then
    ok price ::: PriceExceedsQuantity price quantity
  else
    fail 422 "price must exceed quantity"

record Msg {
  title: String ::: SafeTitle title
}

record OrderLine {
  price: Int ::: Positive price
  quantity: Int ::: Positive quantity
} ::: PriceExceedsQuantity price quantity
|}

let b6_import_header = {|module Main exposing []
import Tesl.Prelude exposing [Int, String, Fact, detachFact]
import Lib exposing [
  SafeTitle, checkSafeTitle,
  Positive, isPositive,
  PriceExceedsQuantity, checkPEQ,
  Msg, OrderLine,
]
|}

let bug6a_imported_field_proof_rejected () =
  let main = b6_import_header ^ {|
fn mkMsg(raw: String) -> Msg =
  Msg { title: raw }
|} in
  with_files [("lib.tesl", b6_lib); ("main.tesl", main)] (fun p ->
    let out = check_fails "violating literal into imported proof field" (p "main.tesl") in
    if not (contains "does not statically satisfy declared proof" out) then
      failf "imported record field proof must be enforced at construction:\n%s" out)

let bug6b_imported_invariant_rejected () =
  let main = b6_import_header ^ {|
fn mkOrder(rawP: Int, rawQ: Int) -> OrderLine =
  let p = check isPositive rawP
  let q = check isPositive rawQ
  OrderLine { price: p, quantity: q }
|} in
  with_files [("lib.tesl", b6_lib); ("main.tesl", main)] (fun p ->
    let out = check_fails "imported invariant record without ghost witness" (p "main.tesl") in
    if not (contains "requires a ghost witness" out) then
      failf "imported record invariant must demand a ghost witness:\n%s" out)

let bug6_imported_witnessed_construction_accepted () =
  let main = b6_import_header ^ {|
fn mkOrder(rawP: Int, rawQ: Int) -> OrderLine =
  let p = check isPositive rawP
  let q = check isPositive rawQ
  let pq = check checkPEQ p q
  OrderLine { price: p, quantity: q } ::: (detachFact pq)
|} in
  with_files [("lib.tesl", b6_lib); ("main.tesl", main)] (fun p ->
    ignore (check_ok "witnessed imported construction" (p "main.tesl")))

let bug6c_testblock_field_proof_rejected () =
  let src = {|module Main exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length]

fact SafeTitle (t: String)

check checkSafeTitle(s: String) -> s: String ::: SafeTitle s =
  if String.length s > 0 then
    ok s ::: SafeTitle s
  else
    fail 400 "bad title"

record Msg {
  title: String ::: SafeTitle title
}

test "bare literal into proof field" {
  let m = Msg { title: "unvalidated" }
  expect m.title == "unvalidated"
}
|} in
  with_files [("main.tesl", src)] (fun p ->
    let out = check_fails "test-block field-proof violation" (p "main.tesl") in
    if not (contains "does not statically satisfy declared proof" out) then
      failf "field proofs must be enforced in test blocks:\n%s" out)

let b6c_inv_src construction = Printf.sprintf {|module Main exposing []
import Tesl.Prelude exposing [Int, String, Fact, detachFact]

fact Positive (n: Int)

check isPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "must be positive"

fact PriceExceedsQuantity (price: Int, quantity: Int)

check checkPEQ(price: Int, quantity: Int) -> price: Int ::: PriceExceedsQuantity price quantity =
  if price > quantity then
    ok price ::: PriceExceedsQuantity price quantity
  else
    fail 422 "price must exceed quantity"

record OrderLine {
  price: Int ::: Positive price
  quantity: Int ::: Positive quantity
} ::: PriceExceedsQuantity price quantity

test "invariant record in test block" {
  let rawP = 10
  let p = check isPositive rawP
  let rawQ = 3
  let q = check isPositive rawQ
  let pq = check checkPEQ p q
  let o = %s
  expect o.price == 10
}
|} construction

let bug6c_testblock_invariant_rejected () =
  with_files
    [("main.tesl", b6c_inv_src "OrderLine { price: p, quantity: q }")] (fun p ->
    let out = check_fails "test-block witnessless invariant construction" (p "main.tesl") in
    if not (contains "requires a ghost witness" out) then
      failf "record invariants must be enforced in test blocks:\n%s" out)

let bug6c_testblock_witnessed_accepted () =
  with_files
    [("main.tesl",
      b6c_inv_src "OrderLine { price: p, quantity: q } ::: (detachFact pq)")] (fun p ->
    ignore (check_ok "test-block witnessed construction" (p "main.tesl")))

(* ── 7. exists/pack: consuming the result as its underlying type ─────────── *)

let b7_lib = {|module Lib exposing [IsTokenId, checkTokenId, idGen, generateToken]
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length]
import Tesl.Random exposing [random]
import Tesl.Id exposing [generatePrefixedId]

fact IsTokenId (s: String)

check checkTokenId(s: String) -> s: String ::: IsTokenId s =
  if String.length s > 3 then
    ok s ::: IsTokenId s
  else
    fail 400 "bad token"

capability idGen implies random

fn generateToken() -> exists tokenId: String => tokenId: String ::: IsTokenId tokenId
  requires [idGen] =
  let tokenId = generatePrefixedId "tok"
  let validated = check checkTokenId tokenId
  exists tokenId =>
    validated
|}

let b7_main = {|module Main exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]
import Tesl.String exposing [String.length]
import Lib exposing [IsTokenId, idGen, generateToken]

test "consume exists result as its underlying type" requires [idGen] {
  let tok = generateToken()
  expect String.length tok > 3
}
|}

(* The checker deliberately types the exists result as the UNDERLYING type
   (the pack hides witness NAMES, not the value); the runtime projection that
   makes this spelling actually WORK (raw-value unwrapping packed-exists) is
   exercised end-to-end by tests/exists-consume-tests.tesl. This locks the
   cross-module CHECK acceptance so the two sides cannot drift apart again. *)
let bug7_exists_consume_checks_cross_module () =
  with_files [("lib.tesl", b7_lib); ("main.tesl", b7_main)] (fun p ->
    ignore (check_ok "cross-module exists consumption" (p "main.tesl"));
    ignore (emit_ok "cross-module exists consumption (emit)" (p "main.tesl")))

(* ── 8. diagnostics polish ───────────────────────────────────────────────── *)

let b8a_lib = {|module Lib exposing [needsMainCap]
import Tesl.Prelude exposing [Int]

fn needsMainCap(n: Int) -> Int requires [mainCap] =
  n * 2
|}

let b8a_main = {|module Main exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
import Lib exposing [needsMainCap]

capability mainCap

test "cap declared in main, required by lib fn" requires [mainCap] {
  expect needsMainCap 21 == 42
}
|}

let bug8a_p001_carries_shared_module_guidance () =
  with_files [("lib.tesl", b8a_lib); ("main.tesl", b8a_main)] (fun p ->
    let out = check_fails "capability declared only in main" (p "main.tesl") in
    if not (contains "requires undeclared capability 'mainCap'" out) then
      failf "must reject the lib fn's undeclared capability:\n%s" out;
    if not (contains "shared module both can import" out) then
      failf "P001 must carry the move-to-a-shared-module guidance:\n%s" out;
    if not (contains "lib.tesl" out) then
      failf "the P001 must be anchored at the imported lib file:\n%s" out)

let b8b_lib = {|module Lib exposing [PairGap, checkPairGap]
import Tesl.Prelude exposing [Int, String]

fact PairGap (name: String, hi: Int, lo: Int)

check checkPairGap(hi: Int, lo: Int) -> hi: Int ::: PairGap hi lo 0 =
  if hi > lo then
    ok hi ::: PairGap hi lo 0
  else
    fail 422 "hi must exceed lo"
|}

let b8b_main = {|module Main exposing [useIt]
import Tesl.Prelude exposing [Int, String]
import Lib exposing [PairGap, checkPairGap]

fn useIt(a: Int, b: Int) -> Int =
  let v = check checkPairGap a b
  v
|}

let bug8b_v001_anchored_at_imported_file () =
  with_files [("lib.tesl", b8b_lib); ("main.tesl", b8b_main)] (fun p ->
    let out = check_fails "fact-subject mismatch inside imported lib" (p "main.tesl") in
    if not (contains "declares type `String`" out) then
      failf "must surface the imported module's V001 from the entrypoint check:\n%s" out;
    if not (contains "lib.tesl:" out) then
      failf "the V001 must carry the imported file's path/loc:\n%s" out)

(* ── REVIEW2 item 16 (2026-07-09): cross-module `requires [emailCap]` ───────
   A lib declares the `email` block; the importing module merely WRAPS the
   lib's sending fn in its own `fn … requires [emailCap]` with no direct
   email op.  Validation_common.collect_imported_cache_email_caps makes that
   check-legal, but Desugar.module_uses_email only counted direct ops, so the
   emitted module carried `#:capabilities [emailCap]` with NO tesl/tesl/email
   require — `emailCap: unbound identifier` at load.  module_uses_email now
   also counts requires-list mentions of emailCap (mirroring the
   `cacheCap <Name>` handling in module_uses_cache). *)

let ec_lib = {|module Mailer exposing [sendWelcome]
import Tesl.Prelude exposing [Int, String, Unit, Bool(..)]
import Tesl.Database exposing [Database, Memory]
import Tesl.Email exposing [Email, SmtpConfig, TextBody]
import Tesl.Env exposing [env]

database MailDB = Database {
  schema: "public"
  entities: []
  backend: Memory
}

email Notifier = Email {
  database: MailDB
  smtp: SmtpConfig {
    host: env "SMTP_HOST"
    port: 587
    username: env "SMTP_USER"
    password: env "SMTP_PASS"
    tls: true
  }
}

fn sendWelcome(addr: String) -> Unit requires [emailCap] =
  Email.send Notifier {
    to: addr
    subject: "Welcome!"
    body: TextBody "hello"
  }
|}

let ec_main = {|module Main exposing [notify]
import Tesl.Prelude exposing [String, Unit]
import Mailer exposing [sendWelcome]

fn notify(addr: String) -> Unit requires [emailCap] =
  sendWelcome addr
|}

let emailcap_requires_only_emits_email_require () =
  with_files
    [ ("mailer.tesl", ec_lib); ("main.tesl", ec_main) ]
    (fun path ->
      ignore (check_ok "cross-module emailCap requires" (path "main.tesl"));
      let out = emit_ok "cross-module emailCap requires" (path "main.tesl") in
      if not (contains "#:capabilities [emailCap]" out) then
        failf "requires list must emit the emailCap grant:\n%s" out;
      (* pre-fix: no tesl/tesl/email require — emailCap unbound at load *)
      if not (contains "tesl/tesl/email" out) then
        failf "requires-list emailCap must pull the email runtime require:\n%s" out)

let () =
  run "checker-multimodule" [
    ("bug1 aggregate+where field type", [
      test_case "-> Money accepted with where" `Quick bug1_money_annotation_accepted;
      test_case "-> Int rejected (real result is Money)" `Quick bug1_int_annotation_rejected;
    ]);
    ("bug2 groupBy imported entity", [
      test_case "imported entity column accepted; unknown still rejected" `Quick bug2_groupby_imported_entity;
    ]);
    ("bug3 codec cross-module", [
      test_case "decodeAs targets imported codec" `Quick bug3a_decodeas_imported_codec;
      test_case "codec in Lib for record imported from Recs" `Quick bug3b_codec_for_imported_record;
    ]);
    ("bug4+5 newtype capture", [
      test_case "imported newtype capture accepted" `Quick bug4_imported_newtype_capture_accepted;
      test_case "hint suggests a codec, not `using TypeName`" `Quick bug4_hint_names_a_codec_spelling;
      test_case "emit wraps parsed segment in the newtype" `Quick bug5_capture_newtype_wrap_emit_shape;
    ]);
    ("bug6 record proof enforcement", [
      test_case "imported field proof enforced (reject)" `Quick bug6a_imported_field_proof_rejected;
      test_case "imported invariant enforced (reject)" `Quick bug6b_imported_invariant_rejected;
      test_case "imported witnessed construction accepted" `Quick bug6_imported_witnessed_construction_accepted;
      test_case "test-block field proof enforced (reject)" `Quick bug6c_testblock_field_proof_rejected;
      test_case "test-block invariant enforced (reject)" `Quick bug6c_testblock_invariant_rejected;
      test_case "test-block witnessed construction accepted" `Quick bug6c_testblock_witnessed_accepted;
    ]);
    ("bug7 exists consumption", [
      test_case "cross-module consume checks + emits" `Quick bug7_exists_consume_checks_cross_module;
    ]);
    ("bug8 diagnostics", [
      test_case "P001 shared-module guidance" `Quick bug8a_p001_carries_shared_module_guidance;
      test_case "V001 anchored at imported file" `Quick bug8b_v001_anchored_at_imported_file;
    ]);
    ("REVIEW2 item 16 — cross-module emailCap requires", [
      test_case "requires-list emailCap pulls the email runtime require" `Quick
        emailcap_requires_only_emits_email_require;
    ]);
  ]
