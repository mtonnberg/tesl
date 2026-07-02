(** A3 — proof/subject identity soundness (external re-review §4).

    Closes three confirmed, silent forgeries — all reproduced exit-0 before the
    fix, all now rejected at `--check`:

    §4.1 BSUBJ-1 — field-qualified subject identity.  `subject_of_expr` collapsed
      every field of an object to the object's own subject, so a `Fact F` proven
      about `o.fieldA` satisfied a requirement for `F` about a sibling `o.fieldB`
      (the trusted-beside-untrusted request-DTO shape).  Fixed by qualifying the
      subject with the field name on BOTH the proof side (carried_proofs_of_expr's
      EField) and the requirement side (subject_of_expr's EField).

    §4.2 BMOD-FORGE-01 — cross-module fact forgery by a same-spelled local `fact`.
      A consumer declared a local `fact F` colliding with a predicate owned by an
      imported module; predicate identity was the bare name (+ an eq?-shared
      emitted symbol), so the local `F` satisfied the foreign module's `::: F`
      obligation.  Fixed fail-closed: a local `fact` may not collide with a fact
      owned by any imported module (nor an explicitly-imported stdlib predicate).

    §4.3 BMOD-SHADOW-ASYM-02 — the no-shadowing detector omitted `fact`.  The same
      fix rejects a local `fact` shadowing an imported predicate, closing the hole
      in thesis invariant #1 for the corner that matters to proof identity.

    Hardening: a static rejection must never leak a runtime token.  Positive
    companions ensure the fixes do not over-reject legitimate same-field proofs,
    record-field proofs, or self-contained facts that merely share a spelling with
    a non-imported stdlib predicate. *)

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

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let modname_of src =
  let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
  ignore (Str.search_forward re src 0);
  Str.matched_group 1 src

let file_of_module mname =
  (* kebab-case the module name so the file-name/module-name check is satisfied. *)
  let buf = Buffer.create (String.length mname + 4) in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
    else Buffer.add_char buf c) mname;
  Buffer.contents buf ^ ".tesl"

let with_files srcs f =
  let dir = Filename.temp_dir "tesl-a3" "" in
  let paths = List.map (fun src ->
    let p = Filename.concat dir (file_of_module (modname_of src)) in
    let oc = open_out p in output_string oc src; close_out oc; p) srcs in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) paths;
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f (List.nth paths (List.length paths - 1)))

let runtime_leak_re =
  Str.regexp_case_fold "raise-user-error\\|check-fail\\|\\.rkt:[0-9]\\|raco "

let assert_no_leak ~label out =
  try ignore (Str.search_forward runtime_leak_re out 0);
    failf "%s: rejection LEAKED to runtime:\n%s" label out
  with Not_found -> ()

(* [srcs]: the LAST module is the one compiled; earlier ones are dependencies. *)
let should_fail ?(pat = "") label srcs =
  with_files srcs (fun path ->
    let code, out = run_compiler ["--check"; path] in
    assert_no_leak ~label out;
    if code = 0 then failf "%s: expected static rejection, but COMPILED (exit 0)" label;
    if pat <> "" then
      let re = Str.regexp_case_fold pat in
      (try ignore (Str.search_forward re out 0)
       with Not_found -> failf "%s: rejected but message did not match %S:\n%s" label pat out))

let should_pass label srcs =
  with_files srcs (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "%s: expected COMPILE (exit 0) but failed:\n%s" label out)

(* ── §4.1 subject field-drop ──────────────────────────────────────────────── *)

let subj_hdr = {|#lang tesl
module SubjA exposing []
import Tesl.Prelude exposing [String, attachFact, detachFact, forgetFact]
import Tesl.String exposing [String.length]
fact Safe (s: String)
check checkSafe(s: String) -> s: String ::: Safe s =
  if String.length s >= 0 then
    ok s ::: Safe s
  else
    fail 400 "no"
fn sink(s: String ::: Safe s) -> String = s
record Cmd { safe: String, danger: String }
record Doc { title: String ::: Safe title }
|}

let subj src = [subj_hdr ^ src]

(* NEG: prove Safe on c.safe, retarget the proof to the sibling c.danger. *)
let neg_attachfact_sibling = subj {|
fn attack(c: Cmd) -> String =
  let vsafe = check checkSafe c.safe
  let (raw ::: p) = vsafe
  sink (attachFact c.danger p)
|}

(* NEG: `:::` reattach across sibling fields. *)
let neg_annotate_sibling = subj {|
fn attack(c: Cmd) -> String =
  let vsafe = check checkSafe c.safe
  let (raw ::: p) = vsafe
  sink (c.danger ::: p)
|}

(* NEG: forget on danger, attach the safe proof. *)
let neg_forget_attach_sibling = subj {|
fn attack(c: Cmd) -> String =
  let vsafe = check checkSafe c.safe
  let (raw ::: p) = vsafe
  let stripped = forgetFact c.danger
  sink (attachFact stripped p)
|}

(* NEG: cross-object, same field name — c1.safe proof used for c2.safe. *)
let neg_cross_object_same_field = subj {|
fn attack(c1: Cmd, c2: Cmd) -> String =
  let v1 = check checkSafe c1.safe
  let (raw ::: p) = v1
  sink (attachFact c2.safe p)
|}

(* POS: same field — prove and use c.safe (bound first, as the language requires). *)
let pos_same_field = subj {|
fn ok1(c: Cmd) -> String =
  let v = check checkSafe c.safe
  sink v
|}

(* POS: record-field proof round trip — Doc.title carries Safe title. *)
let pos_record_field_roundtrip = subj {|
fn makeDoc(t0: String) -> Doc =
  let t = check checkSafe t0
  Doc { title: t }
fn readTitle(d: Doc) -> String =
  sink d.title
|}

(* POS: detach + reattach to the SAME field is fine. *)
let pos_detach_reattach_same = subj {|
fn ok2(c: Cmd) -> String =
  let vsafe = check checkSafe c.safe
  let (raw ::: p) = vsafe
  sink (attachFact c.safe p)
|}

(* ── §4.2 / §4.3 cross-module fact identity ───────────────────────────────── *)

let owner = {|#lang tesl
module FactOwner exposing [ValidEmail, checkEmail, trustedSink]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains, String.length]
fact ValidEmail (s: String)
check checkEmail(s: String) -> s: String ::: ValidEmail s =
  if String.contains s "@" && String.length s >= 5 then
    ok s ::: ValidEmail s
  else
    fail 400 "invalid"
fn trustedSink(s: String ::: ValidEmail s) -> String = s
|}

(* Attacker declares a same-named local fact WITHOUT importing the predicate,
   mints it via [mint_kind], and feeds it to the owner's trusted sink. *)
let attacker_check = {|#lang tesl
module AttackerC exposing []
import Tesl.Prelude exposing [String]
import FactOwner exposing [trustedSink]
fact ValidEmail (s: String)
check forge(s: String) -> s: String ::: ValidEmail s = ok s ::: ValidEmail s
fn attack(evil: String) -> String =
  let v = check forge evil
  trustedSink v
|}

let attacker_establish = {|#lang tesl
module AttackerE exposing []
import Tesl.Prelude exposing [String, Fact, attachFact]
import FactOwner exposing [trustedSink]
fact ValidEmail (s: String)
establish forge(s: String) -> Fact (ValidEmail s) = ValidEmail s
fn attack(evil: String) -> String =
  let p = forge evil
  trustedSink (attachFact evil p)
|}

(* Attacker imports the fact by name AND re-declares it locally (the §4.3 shadow). *)
let shadower = {|#lang tesl
module ShadowerM exposing []
import Tesl.Prelude exposing [String]
import FactOwner exposing [ValidEmail, checkEmail, trustedSink]
fact ValidEmail (s: String)
|}

(* POS: consumer imports and USES the fact as a type, never re-declaring it. *)
let legit_consumer = {|#lang tesl
module LegitC exposing []
import Tesl.Prelude exposing [String]
import FactOwner exposing [ValidEmail, checkEmail, trustedSink]
fn process(raw: String) -> String =
  let e = check checkEmail raw
  trustedSink e
|}

(* POS: a self-contained module owns its OWN fact (no importing module owns it). *)
let self_owner = {|#lang tesl
module SelfOwner exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
fact LocalNonEmpty (s: String)
check checkNE(s: String) -> s: String ::: LocalNonEmpty s =
  if String.length s >= 1 then
    ok s ::: LocalNonEmpty s
  else
    fail 400 "empty"
fn needNE(s: String ::: LocalNonEmpty s) -> String = s
fn use(raw: String) -> String =
  let v = check checkNE raw
  needNE v
|}

(* POS: a local fact sharing a spelling with a NON-imported stdlib predicate. *)
let stdlib_name_not_imported = {|#lang tesl
module StdName exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
fact IsNonEmpty (s: String)
check checkNonEmpty(s: String) -> s: String ::: IsNonEmpty s =
  if String.length s >= 1 then
    ok s ::: IsNonEmpty s
  else
    fail 400 "empty"
fn need(s: String ::: IsNonEmpty s) -> String = s
|}

let own_pat = "already owned by imported module\\|single owning module\\|shadows the imported"

let mismatch_pat = "subject mismatch\\|does not statically satisfy\\|different subject\\|does not match"

(* ── §4.1 parameterised matrix: every ordered field pair × launder mechanism ─
   A 4-field record gives 12 ordered (proven, target) pairs; each retarget via a
   distinct launder must be rejected.  This is the breadth that catches a subject
   key that is right for one field pair but collapses another. *)
let quad_hdr = {|#lang tesl
module SubjQ exposing []
import Tesl.Prelude exposing [String, attachFact, detachFact, forgetFact]
import Tesl.String exposing [String.length]
fact Safe (s: String)
check checkSafe(s: String) -> s: String ::: Safe s =
  if String.length s >= 0 then
    ok s ::: Safe s
  else
    fail 400 "no"
fn sink(s: String ::: Safe s) -> String = s
record Quad { fa: String, fb: String, fc: String, fd: String }
|}

let field_pairs =
  [ ("fa","fb"); ("fb","fa"); ("fa","fc"); ("fc","fd"); ("fd","fb"); ("fb","fc") ]

(* mechanism : (proven_field, target_field) -> body of `attack(q: Quad)` *)
let launders = [
  ("attachFact",
   fun p t -> Printf.sprintf
     "  let v = check checkSafe q.%s\n  let (raw ::: pr) = v\n  sink (attachFact q.%s pr)\n" p t);
  ("annotate",
   fun p t -> Printf.sprintf
     "  let v = check checkSafe q.%s\n  let (raw ::: pr) = v\n  sink (q.%s ::: pr)\n" p t);
  ("forget-attach",
   fun p t -> Printf.sprintf
     "  let v = check checkSafe q.%s\n  let (raw ::: pr) = v\n  let s = forgetFact q.%s\n  sink (attachFact s pr)\n" p t);
]

let quad_neg mech_body p t =
  [ quad_hdr ^ Printf.sprintf "fn attack(q: Quad) -> String =\n%s" (mech_body p t) ]

let matrix_cases =
  List.concat_map (fun (mech_name, mech_body) ->
    List.map (fun (p, t) ->
      let label = Printf.sprintf "§4.1 retarget %s: %s->%s" mech_name p t in
      test_case label `Quick
        (fun () -> should_fail ~pat:mismatch_pat label (quad_neg mech_body p t))
    ) field_pairs
  ) launders

(* POS matrix: proving-and-using the SAME field (all four) must compile. *)
let quad_pos_cases =
  List.map (fun fld ->
    let label = Printf.sprintf "§4.1 same-field ok: %s" fld in
    let src = [ quad_hdr ^ Printf.sprintf
      "fn ok(q: Quad) -> String =\n  let v = check checkSafe q.%s\n  sink v\n" fld ] in
    test_case label `Quick (fun () -> should_pass label src)
  ) ["fa"; "fb"; "fc"; "fd"]

(* ── §4.2 forgery matrix: mint-kind × import-style ────────────────────────── *)
let owner_bridge = {|#lang tesl
module OwnerBridge exposing [ValidEmail, checkEmail, trustedSink]
import FactOwner exposing [ValidEmail, checkEmail, trustedSink]
|}

(* attacker importing via the re-export bridge, minting a same-named local fact. *)
let attacker_via_bridge = {|#lang tesl
module AttackerB exposing []
import Tesl.Prelude exposing [String]
import OwnerBridge exposing [trustedSink]
fact ValidEmail (s: String)
check forge(s: String) -> s: String ::: ValidEmail s = ok s ::: ValidEmail s
fn attack(evil: String) -> String =
  let v = check forge evil
  trustedSink v
|}

(* auth-mint variant — the collision is caught at the `fact` DECLARATION, before
   any mint, so simply declaring the same-named local fact while importing the
   owner is already the forgery vector regardless of mint kind. *)
let attacker_auth = {|#lang tesl
module AttackerA exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import FactOwner exposing [trustedSink]
fact ValidEmail (s: String)
auth forge(req: HttpRequest) -> s: String ::: ValidEmail s =
  ok "evil" ::: ValidEmail s
|}

(* POS: two modules each declaring DISTINCT facts, one importing the other. *)
let distinct_a = {|#lang tesl
module DistinctA exposing [FactAlpha, mkAlpha]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
fact FactAlpha (s: String)
check mkAlpha(s: String) -> s: String ::: FactAlpha s =
  if String.length s >= 0 then
    ok s ::: FactAlpha s
  else
    fail 400 "x"
|}
let distinct_b = {|#lang tesl
module DistinctB exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
import DistinctA exposing [FactAlpha, mkAlpha]
fact FactBeta (s: String)
check mkBeta(s: String) -> s: String ::: FactBeta s =
  if String.length s >= 0 then
    ok s ::: FactBeta s
  else
    fail 400 "y"
fn needBeta(s: String ::: FactBeta s) -> String = s
|}

(* ── §4.2 cross-module DIAMOND: same-named facts from different owners ──────
   User-reported scenario: two modules each declare a `fact` of the same name
   (same OR different arity); a consumer that reaches BOTH (via imported minters /
   sinks, directly or through a re-export hop) must NOT let a value carrying one
   owner's fact satisfy the other owner's obligation — even if the other is never
   proved.  Identity is bare-name, so this is fail-closed by rejecting any fact
   name owned by >1 module in scope. *)
let own_int_mint = {|#lang tesl
module OwnIntMint exposing [Widget, mkWidget]
import Tesl.Prelude exposing [Int, Bool(..)]
fact Widget (n: Int)
check mkWidget(n: Int) -> n: Int ::: Widget n =
  if n > 0 then
    ok n ::: Widget n
  else
    fail 400 "x"
|}
let own_int_sink = {|#lang tesl
module OwnIntSink exposing [Widget, useWidget]
import Tesl.Prelude exposing [Int]
fact Widget (n: Int)
fn useWidget(x: Int ::: Widget x) -> Int = x
|}
let own_str_sink = {|#lang tesl
module OwnStrSink exposing [Widget, useWidget]
import Tesl.Prelude exposing [String]
fact Widget (s: String)
fn useWidget(x: String ::: Widget x) -> String = x
|}
(* NEG: consumer bridges OwnIntMint's Widget value into OwnIntSink's sink. *)
let neg_diamond_bridge = {|#lang tesl
module DiamondBridge exposing []
import Tesl.Prelude exposing [Int]
import OwnIntMint exposing [mkWidget]
import OwnIntSink exposing [useWidget]
fn attack(raw: Int) -> Int =
  let w = check mkWidget raw
  useWidget w
|}
(* NEG: same name, DIFFERENT arity/type owners — ambiguous even if never bridged. *)
let neg_diamond_arity = {|#lang tesl
module DiamondArity exposing []
import Tesl.Prelude exposing [Int]
import OwnIntMint exposing [mkWidget]
import OwnStrSink exposing [useWidget]
fn attack(raw: Int) -> Int =
  let w = check mkWidget raw
  w
|}
(* NEG (user's 4-module form): C re-exports A's Widget; D reaches A (via C) and B. *)
let bridge_reexport = {|#lang tesl
module BridgeReexport exposing [Widget]
import OwnIntMint exposing [Widget]
|}
let neg_diamond_4mod = {|#lang tesl
module Diamond4 exposing []
import Tesl.Prelude exposing [Int]
import OwnIntMint exposing [mkWidget]
import OwnIntSink exposing [useWidget]
import BridgeReexport exposing []
fn attack(raw: Int) -> Int =
  let w = check mkWidget raw
  useWidget w
|}
(* POS: a consumer using a fact from a SINGLE owning module compiles. *)
let own_full = {|#lang tesl
module OwnFull exposing [Widget, mkWidget, useWidget]
import Tesl.Prelude exposing [Int, Bool(..)]
fact Widget (n: Int)
check mkWidget(n: Int) -> n: Int ::: Widget n =
  if n > 0 then
    ok n ::: Widget n
  else
    fail 400 "x"
fn useWidget(x: Int ::: Widget x) -> Int = x
|}
let pos_single_owner = {|#lang tesl
module SingleOwner exposing []
import Tesl.Prelude exposing [Int]
import OwnFull exposing [Widget, mkWidget, useWidget]
fn ok(raw: Int) -> Int =
  let w = check mkWidget raw
  useWidget w
|}

let diamond_pat = "more than one module\\|ambiguous\\|already owned by another module\\|single owning module"

(* ── Runner ───────────────────────────────────────────────────────────────── *)

let () =
  run "A3-Proof-Identity" [
    "§4.1 subject field-drop (negatives)", [
      test_case "attachFact to sibling field" `Quick
        (fun () -> should_fail ~pat:mismatch_pat "attachFact sibling" neg_attachfact_sibling);
      test_case "::: reattach to sibling field" `Quick
        (fun () -> should_fail ~pat:mismatch_pat "annotate sibling" neg_annotate_sibling);
      test_case "forget+attach to sibling field" `Quick
        (fun () -> should_fail ~pat:mismatch_pat "forget-attach sibling" neg_forget_attach_sibling);
      test_case "cross-object same field name" `Quick
        (fun () -> should_fail ~pat:mismatch_pat "cross-object same field" neg_cross_object_same_field);
    ];
    "§4.1 subject field-drop (positives)", [
      test_case "same field proven and used" `Quick
        (fun () -> should_pass "same field" pos_same_field);
      test_case "record-field proof round trip" `Quick
        (fun () -> should_pass "record field roundtrip" pos_record_field_roundtrip);
      test_case "detach+reattach same field" `Quick
        (fun () -> should_pass "detach reattach same" pos_detach_reattach_same);
    ];
    "§4.1 field-pair × launder matrix (negatives)", matrix_cases;
    "§4.1 same-field matrix (positives)", quad_pos_cases;
    "§4.2/§4.3 cross-module fact identity (negatives)", [
      test_case "forge via same-named local fact (check mint)" `Quick
        (fun () -> should_fail ~pat:own_pat "forge check" [owner; attacker_check]);
      test_case "forge via same-named local fact (establish mint)" `Quick
        (fun () -> should_fail ~pat:own_pat "forge establish" [owner; attacker_establish]);
      test_case "forge via same-named local fact (auth mint)" `Quick
        (fun () -> should_fail ~pat:own_pat "forge auth" [owner; attacker_auth]);
      test_case "forge through a re-export bridge" `Quick
        (fun () -> should_fail ~pat:own_pat "forge via bridge" [owner; owner_bridge; attacker_via_bridge]);
      test_case "local fact shadows explicitly imported predicate" `Quick
        (fun () -> should_fail ~pat:own_pat "shadow import" [owner; shadower]);
    ];
    "§4.2/§4.3 cross-module fact identity (positives)", [
      test_case "consumer imports and uses fact (no re-declare)" `Quick
        (fun () -> should_pass "legit consumer" [owner; legit_consumer]);
      test_case "self-contained owner of its own fact" `Quick
        (fun () -> should_pass "self owner" [self_owner]);
      test_case "local fact sharing spelling with non-imported stdlib pred" `Quick
        (fun () -> should_pass "stdlib name not imported" [stdlib_name_not_imported]);
      test_case "two modules with DISTINCT facts, one imports the other" `Quick
        (fun () -> should_pass "distinct facts cross-module" [distinct_a; distinct_b]);
    ];
    "§4.2 cross-module diamond (same-named facts, different owners)", [
      test_case "bridge mint(A.Widget) → sink(B.Widget) is rejected" `Quick
        (fun () -> should_fail ~pat:diamond_pat "diamond-bridge"
                     [own_int_mint; own_int_sink; neg_diamond_bridge]);
      test_case "same name, different arity owners is rejected" `Quick
        (fun () -> should_fail ~pat:diamond_pat "diamond-arity"
                     [own_int_mint; own_str_sink; neg_diamond_arity]);
      test_case "4-module form (C re-exports A; D reaches A and B) is rejected" `Quick
        (fun () -> should_fail ~pat:diamond_pat "diamond-4mod"
                     [own_int_mint; own_int_sink; bridge_reexport; neg_diamond_4mod]);
      test_case "single-owner consumer still compiles" `Quick
        (fun () -> should_pass "single-owner" [own_full; pos_single_owner]);
    ];
  ]
