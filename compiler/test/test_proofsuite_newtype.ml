(** ProofSuite family I — Newtype nominal distinctness (§7.11).

    NEGATIVE proof tests: code that must NOT compile because the *static*
    checker rejects it.  `type Name = BaseType` creates a nominal wrapper:
    two newtypes over the same base type (`UserId` and `ProjectId`, both over
    `String`) are distinct, and a raw base value is not a newtype value.

    This file proves rejection happens at COMPILE time (no runtime safety net):
    `should_fail` additionally fails if the compiler output contains a Racket
    runtime token (`raise-user-error`, `check-fail`, a `.rkt` trace) — a static
    rejection must never leak to runtime.

    Breadth: a matrix over base types {String, Int} × positions
    {param, return, record field, fn arg, list element} × the two mistakes
    (wrong-newtype, raw-base), plus hand-written companions and ~13 positives.

    Companion to NEG-ATTACK (gap-hunters); here we provide systematic breadth
    and the positive companions. *)

open Alcotest

(* ── Compiler discovery (mirrors test_library_negative.ml) ───────────────── *)

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
  let dir = Filename.temp_dir "tesl-psI" "" in
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

(* Hardening: a static rejection must not leak a runtime token. *)
let runtime_leak_re =
  Str.regexp_case_fold "raise-user-error\\|check-fail\\|\\.rkt:[0-9]\\|context\\.\\.\\.:\\|raco "

let assert_no_runtime_leak ~ctx out =
  try
    ignore (Str.search_forward runtime_leak_re out 0);
    failf "%s: rejection LEAKED to runtime (matched runtime token), output:\n%s" ctx out
  with Not_found -> ()

(* should_fail: must reject statically (nonzero exit), output must match [pat],
   and output must contain no runtime token. *)
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

(* ── Matrix building blocks ──────────────────────────────────────────────── *)

(* Each base type carries: the prelude import list, a literal of the base,
   and how to take a `.value` projection where needed. *)
type base = { bname : string; import : string; lit : string }

let bases = [
  { bname = "String"; import = "String"; lit = {|"x"|} };
  { bname = "Int";    import = "Int";    lit = "5" };
]

(* The two distinct newtypes and the raw base, as the "actual" type supplied
   where the "expected" newtype is required. *)
let header b modname =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\nimport Tesl.Prelude exposing [%s, List]\n\
     type Alpha = %s\ntype Beta = %s\n"
    modname b.import b.bname b.bname

(* A `.value`-or-passthrough access helper for use in returns/bodies. *)

(* Positions: produce a (module-body) snippet where a value of type [actual]
   is supplied where [Alpha] is required.  Returns the snippet to append after
   the header. *)
let pos_param ~actual =
  (* a fn whose param is [actual], passed to a fn requiring Alpha *)
  Printf.sprintf
    "fn needsAlpha(a: Alpha) -> Alpha = a\nfn bad(x: %s) -> Alpha = needsAlpha x\n" actual

let pos_return ~actual =
  (* fn declares return Alpha but body is an [actual] param *)
  Printf.sprintf "fn bad(x: %s) -> Alpha = x\n" actual

let pos_record_field ~actual =
  Printf.sprintf
    "record Holder { a: Alpha }\nfn bad(x: %s) -> Holder = Holder { a: x }\n" actual

let pos_fn_arg ~actual b =
  (* distinct from pos_param: the consumer takes Alpha at a non-first arg *)
  Printf.sprintf
    "fn needsAlpha2(tag: %s, a: Alpha) -> Alpha = a\nfn bad(x: %s) -> Alpha = needsAlpha2 %s x\n"
    b.import actual b.lit

let pos_list_elem ~actual =
  Printf.sprintf
    "fn needsAlphas(xs: List Alpha) -> List Alpha = xs\nfn bad(xs: List %s) -> List Alpha = needsAlphas xs\n"
    actual

let positions = [
  ("param",        pos_param);
  ("return",       pos_return);
  ("record-field", pos_record_field);
  ("list-elem",    pos_list_elem);
]

(* fn_arg needs the base to form the tag literal, handled separately. *)

(* The two "actuals" that must be rejected where Alpha is required:
   - "Beta": the sibling newtype over the same base (nominal mismatch)
   - b.bname: the raw base type (unwrapped) *)
let actuals b = [ ("sibling-newtype", "Beta"); ("raw-base", b.bname) ]

(* Expected error: a newtype mismatch is a T001 "cannot unify" failure. *)
let mismatch_pat = "cannot unify\\|type mismatch\\|T001"

(* ── I-MX: the full matrix (2 bases × 4 positions × 2 actuals = 16) ──────── *)

let matrix_main_positions () =
  List.concat_map (fun b ->
    List.concat_map (fun (pos_name, pos_fn) ->
      List.map (fun (act_name, actual) ->
        let modname = Printf.sprintf "MxI_%s_%s_%s" b.bname pos_name act_name in
        let modname = String.map (fun c -> if c = '-' then '_' else c) modname in
        let src = header b modname ^ pos_fn ~actual in
        let label = Printf.sprintf "I-MX %s/%s/%s" b.bname pos_name act_name in
        test_case label `Quick (fun () -> should_fail ~label mismatch_pat src)
      ) (actuals b)
    ) positions
  ) bases

(* fn_arg position handled separately because it needs the base literal. *)
let matrix_fn_arg () =
  List.concat_map (fun b ->
    List.map (fun (act_name, actual) ->
      let modname = Printf.sprintf "MxIArg_%s_%s" b.bname act_name in
      let modname = String.map (fun c -> if c = '-' then '_' else c) modname in
      let src = header b modname ^ pos_fn_arg ~actual b in
      let label = Printf.sprintf "I-MX %s/fn-arg/%s" b.bname act_name in
      test_case label `Quick (fun () -> should_fail ~label mismatch_pat src)
    ) (actuals b)
  ) bases

(* ── I-SWAP: swap the two newtypes in *both* directions per position ────────
   (Alpha where Beta required) to prove distinctness is symmetric. *)

let swap_param b =
  Printf.sprintf
    "%sfn needsBeta(x: Beta) -> Beta = x\nfn bad(a: Alpha) -> Beta = needsBeta a\n"
    (header b (Printf.sprintf "SwapI_%s" b.bname))

let swap_return b =
  Printf.sprintf
    "%sfn bad(a: Alpha) -> Beta = a\n"
    (header b (Printf.sprintf "SwapRetI_%s" b.bname))

let matrix_swap () =
  List.concat_map (fun b ->
    [ test_case (Printf.sprintf "I-SWAP %s/param Alpha->Beta" b.bname) `Quick
        (fun () -> should_fail ~label:"I-SWAP param" mismatch_pat (swap_param b));
      test_case (Printf.sprintf "I-SWAP %s/return Alpha->Beta" b.bname) `Quick
        (fun () -> should_fail ~label:"I-SWAP return" mismatch_pat (swap_return b)) ]
  ) bases

(* ── I-DECL: `type UserId = String` then a raw String where UserId required,
   exercised via a named-domain shape (UserId/ProjectId over String, like the
   spec's running example) and over Int (Cents/Quantity). ─────────────────── *)

let test_decl_raw_string_where_userid () =
  should_fail ~label:"I-DECL raw String→UserId" mismatch_pat {|
#lang tesl
module DeclI_UserId exposing []
import Tesl.Prelude exposing [String]
type UserId = String
type ProjectId = String
fn loadUser(u: UserId) -> String = u.value
fn bad(raw: String) -> String = loadUser raw
|}

let test_decl_projectid_where_userid () =
  should_fail ~label:"I-DECL ProjectId→UserId" mismatch_pat {|
#lang tesl
module DeclI_PidUid exposing []
import Tesl.Prelude exposing [String]
type UserId = String
type ProjectId = String
fn loadUser(u: UserId) -> String = u.value
fn bad(p: ProjectId) -> String = loadUser p
|}

let test_decl_raw_int_where_cents () =
  should_fail ~label:"I-DECL raw Int→Cents" mismatch_pat {|
#lang tesl
module DeclI_Cents exposing []
import Tesl.Prelude exposing [Int]
type Cents = Int
type Quantity = Int
fn charge(c: Cents) -> Int = c.value
fn bad(n: Int) -> Int = charge n
|}

let test_decl_quantity_where_cents () =
  should_fail ~label:"I-DECL Quantity→Cents" mismatch_pat {|
#lang tesl
module DeclI_QtyCents exposing []
import Tesl.Prelude exposing [Int]
type Cents = Int
type Quantity = Int
fn charge(c: Cents) -> Int = c.value
fn bad(q: Quantity) -> Int = charge q
|}

(* Newtype value projected to base, then re-supplied where the newtype is
   required — `.value` drops to raw, so it must be rejected. *)
let test_unwrapped_value_where_newtype () =
  should_fail ~label:"I-DECL .value→newtype" mismatch_pat {|
#lang tesl
module DeclI_Unwrap exposing []
import Tesl.Prelude exposing [String]
type UserId = String
fn loadUser(u: UserId) -> String = u.value
fn bad(u: UserId) -> String = loadUser u.value
|}

(* ── I-LIT: a raw LITERAL supplied where the newtype is required ──────────── *)

let test_lit_string_where_userid () =
  should_fail ~label:"I-LIT String literal→UserId" mismatch_pat {|
#lang tesl
module LitI_Str exposing []
import Tesl.Prelude exposing [String]
type UserId = String
fn loadUser(u: UserId) -> String = u.value
fn bad() -> String = loadUser "raw-string"
|}

let test_lit_int_where_cents () =
  should_fail ~label:"I-LIT Int literal→Cents" mismatch_pat {|
#lang tesl
module LitI_Int exposing []
import Tesl.Prelude exposing [Int]
type Cents = Int
fn charge(c: Cents) -> Int = c.value
fn bad() -> Int = charge 100
|}

let test_lit_string_in_record_field () =
  should_fail ~label:"I-LIT String literal in record field" mismatch_pat {|
#lang tesl
module LitI_Rec exposing []
import Tesl.Prelude exposing [String]
type UserId = String
record Owner { uid: UserId }
fn bad() -> Owner = Owner { uid: "raw" }
|}

(* ── I-NEST: newtype distinctness through nested positions ────────────────── *)

let test_nested_record_field_newtype () =
  should_fail ~label:"I-NEST nested record field" mismatch_pat {|
#lang tesl
module NestI_Rec exposing []
import Tesl.Prelude exposing [String]
type UserId = String
type ProjectId = String
record Inner { uid: UserId }
record Outer { inner: Inner }
fn bad(p: ProjectId) -> Outer = Outer { inner: Inner { uid: p } }
|}

let test_list_of_records_newtype () =
  should_fail ~label:"I-NEST list of records" mismatch_pat {|
#lang tesl
module NestI_ListRec exposing []
import Tesl.Prelude exposing [String, List]
type UserId = String
type ProjectId = String
record Owner { uid: UserId }
fn mk(p: ProjectId) -> Owner = Owner { uid: p }
fn bad(ps: List ProjectId) -> List Owner = [mk (head ps)]
|}

(* Two-newtype confusion through a Maybe wrapper. *)
let test_maybe_newtype_confusion () =
  should_fail ~label:"I-NEST Maybe newtype" mismatch_pat {|
#lang tesl
module NestI_Maybe exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Maybe exposing [Maybe(..)]
type UserId = String
type ProjectId = String
fn needsMaybeUser(m: Maybe UserId) -> Int = 0
fn bad(p: ProjectId) -> Int = needsMaybeUser (Something p)
|}

(* ── I-PROOF: newtype + proof interaction — a proof established for a UserId
   subject must not satisfy a requirement phrased over ProjectId.  This pairs
   newtype distinctness with proof identity. ───────────────────────────────── *)

let test_newtype_proof_wrong_carrier () =
  should_fail ~label:"I-PROOF wrong carrier type" mismatch_pat {|
#lang tesl
module ProofI_Carrier exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
type UserId = String
type ProjectId = String
fact ValidId (u: UserId)
check checkId(u: UserId) -> u: UserId ::: ValidId u =
  if String.length u.value > 0 then
    ok u ::: ValidId u
  else
    fail 400 "empty"
fn needsValidUser(u: UserId ::: ValidId u) -> String = u.value
fn bad(p: ProjectId) -> String =
  let v = check checkId p
  needsValidUser v
|}

(* ── I-POS: positive companions (must compile) ────────────────────────────── *)

let pos_userid_accepted () =
  should_pass ~label:"I-POS UserId→UserId" {|
#lang tesl
module PosI_UidUid exposing []
import Tesl.Prelude exposing [String]
type UserId = String
fn loadUser(u: UserId) -> String = u.value
fn good(u: UserId) -> String = loadUser u
|}

let pos_wrap_raw () =
  should_pass ~label:"I-POS wrap raw" {|
#lang tesl
module PosI_Wrap exposing []
import Tesl.Prelude exposing [String]
type UserId = String
fn loadUser(u: UserId) -> String = u.value
fn good(raw: String) -> String = loadUser (UserId raw)
|}

let pos_int_newtype_accepted () =
  should_pass ~label:"I-POS Cents→Cents" {|
#lang tesl
module PosI_Cents exposing []
import Tesl.Prelude exposing [Int]
type Cents = Int
fn charge(c: Cents) -> Int = c.value
fn good(c: Cents) -> Int = charge c
|}

let pos_record_field_newtype () =
  should_pass ~label:"I-POS record field" {|
#lang tesl
module PosI_Rec exposing []
import Tesl.Prelude exposing [String]
type UserId = String
record Owner { uid: UserId }
fn good(u: UserId) -> Owner = Owner { uid: u }
|}

let pos_list_newtype () =
  should_pass ~label:"I-POS list elem" {|
#lang tesl
module PosI_List exposing []
import Tesl.Prelude exposing [String, List]
type UserId = String
fn needsUsers(us: List UserId) -> List UserId = us
fn good(us: List UserId) -> List UserId = needsUsers us
|}

let pos_unwrap_value_for_base_fn () =
  (* Unwrapping the newtype with `.value` to feed a base-typed function is the
     intended round-trip and must compile. *)
  should_pass ~label:"I-POS unwrap for base fn" {|
#lang tesl
module PosI_Unwrap exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.String exposing [String.length]
type UserId = String
fn lenOf(s: String) -> Int = String.length s
fn good(u: UserId) -> Int = lenOf u.value
|}

let pos_db_roundtrip_unwrap () =
  (* Newtype field stored to / read from a DB entity: the entity's field is the
     newtype; unwrapping for serialization compiles (spec §11.6 transparency). *)
  should_pass ~label:"I-POS db roundtrip codec" {|
#lang tesl
module PosI_Db exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
type UserId = String
record Account { uid: UserId, label: String }
codec Account {
  toJson {
    uid -> "uid" with_codec stringCodec
    label -> "label" with_codec stringCodec
  }
  fromJson [
    {
      uid <- "uid" with_codec stringCodec
      label <- "label" with_codec stringCodec
    }
  ]
}
|}

let pos_json_roundtrip_newtype () =
  (* JSON codec over a newtype field: stringCodec is accepted on a String-backed
     newtype (transparent at the JSON boundary). *)
  should_pass ~label:"I-POS json newtype transparency" {|
#lang tesl
module PosI_Json exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
type Email = String
record Contact { email: Email, name: String }
codec Contact {
  toJson {
    email -> "email" with_codec stringCodec
    name -> "name" with_codec stringCodec
  }
  fromJson [
    {
      email <- "email" with_codec stringCodec
      name <- "name" with_codec stringCodec
    }
  ]
}
|}

let pos_two_newtypes_each_own_fn () =
  should_pass ~label:"I-POS two newtypes own fns" {|
#lang tesl
module PosI_TwoOwn exposing []
import Tesl.Prelude exposing [String]
type UserId = String
type ProjectId = String
fn loadUser(u: UserId) -> String = u.value
fn loadProject(p: ProjectId) -> String = p.value
fn good(u: UserId, p: ProjectId) -> String = loadUser u
|}

let pos_newtype_in_maybe () =
  should_pass ~label:"I-POS newtype in Maybe" {|
#lang tesl
module PosI_Maybe exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Maybe exposing [Maybe(..)]
type UserId = String
fn needsMaybeUser(m: Maybe UserId) -> Int = 0
fn good(u: UserId) -> Int = needsMaybeUser (Something u)
|}

let pos_newtype_proof_roundtrip () =
  should_pass ~label:"I-POS newtype proof roundtrip" {|
#lang tesl
module PosI_Proof exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
type UserId = String
fact ValidId (u: UserId)
check checkId(u: UserId) -> u: UserId ::: ValidId u =
  if String.length u.value > 0 then
    ok u ::: ValidId u
  else
    fail 400 "empty"
fn needsValid(u: UserId ::: ValidId u) -> String = u.value
fn good(u: UserId) -> String =
  let v = check checkId u
  needsValid v
|}

let pos_nested_record_newtype () =
  should_pass ~label:"I-POS nested record newtype" {|
#lang tesl
module PosI_Nested exposing []
import Tesl.Prelude exposing [String]
type UserId = String
record Inner { uid: UserId }
record Outer { inner: Inner }
fn good(u: UserId) -> Outer = Outer { inner: Inner { uid: u } }
|}

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  run "ProofSuite-I-Newtype" [
    "I-MX matrix base×position×actual", matrix_main_positions ();
    "I-MX matrix fn-arg position",      matrix_fn_arg ();
    "I-SWAP symmetric distinctness",    matrix_swap ();
    "I-DECL declared-domain newtypes", [
      test_case "raw String where UserId required" `Quick test_decl_raw_string_where_userid;
      test_case "ProjectId where UserId required" `Quick test_decl_projectid_where_userid;
      test_case "raw Int where Cents required" `Quick test_decl_raw_int_where_cents;
      test_case "Quantity where Cents required" `Quick test_decl_quantity_where_cents;
      test_case "unwrapped .value where newtype required" `Quick test_unwrapped_value_where_newtype;
    ];
    "I-LIT raw literal where newtype required", [
      test_case "String literal where UserId required" `Quick test_lit_string_where_userid;
      test_case "Int literal where Cents required" `Quick test_lit_int_where_cents;
      test_case "String literal in newtype record field" `Quick test_lit_string_in_record_field;
    ];
    "I-NEST nested positions", [
      test_case "nested record field newtype mismatch" `Quick test_nested_record_field_newtype;
      test_case "list of records newtype mismatch" `Quick test_list_of_records_newtype;
      test_case "Maybe newtype confusion" `Quick test_maybe_newtype_confusion;
    ];
    "I-PROOF newtype × proof", [
      test_case "proof carrier type mismatch" `Quick test_newtype_proof_wrong_carrier;
    ];
    "I-POS positive companions", [
      test_case "UserId accepted where UserId required" `Quick pos_userid_accepted;
      test_case "wrapping a raw String compiles" `Quick pos_wrap_raw;
      test_case "Int newtype accepted where required" `Quick pos_int_newtype_accepted;
      test_case "newtype record field compiles" `Quick pos_record_field_newtype;
      test_case "List of newtype compiles" `Quick pos_list_newtype;
      test_case "unwrap .value for base fn compiles" `Quick pos_unwrap_value_for_base_fn;
      test_case "DB-style codec roundtrip compiles" `Quick pos_db_roundtrip_unwrap;
      test_case "JSON newtype transparency compiles" `Quick pos_json_roundtrip_newtype;
      test_case "two newtypes with own fns compile" `Quick pos_two_newtypes_each_own_fn;
      test_case "newtype inside Maybe compiles" `Quick pos_newtype_in_maybe;
      test_case "newtype proof roundtrip compiles" `Quick pos_newtype_proof_roundtrip;
      test_case "nested record newtype compiles" `Quick pos_nested_record_newtype;
    ];
  ]
