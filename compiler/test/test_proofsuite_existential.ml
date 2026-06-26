(** ProofSuite Family H — existential return specs (`exists w => …`).

    Negative (must-NOT-compile) proofs that the *static* checker enforces the
    existential discipline WITHOUT the runtime net, plus [should_pass] positive
    companions.

    Families covered:
      NOEX  — body has no `exists` expression though the return type declares one
              ("body has no exists expression").
      RAW   — `exists w => p` packs a raw PARAMETER whose declared proof is not
              demonstrably attached ("proof is not demonstrably attached").
      CONS  — feeding an existential result to a proof-requiring consumer is
              rejected today (witness is hidden) — a positive-rejection negative.
      POS   — positive companions (insert/check-produced packs; structural
              (Id == w) packs; non-trivial proof with attached evidence).

    NB: `.tesl` has NO `pack`/`unpack` keyword (Racket-DSL only), so no raw
    Skolem-escape surface program is attempted here. *)

open Alcotest

(* ── Compiler-path resolution ────────────────────────────────────────────── *)

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
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psH" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then
          (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let runtime_leak_re =
  Str.regexp_case_fold
    "raise-user-error\\|raise-argument-error\\|application: not a procedure\\|\
     racket/[A-Za-z_./-]*\\.rkt:[0-9]\\|^ *context\\.\\.\\.:\\|contract violation"

let assert_no_runtime_leak ctx out =
  try
    ignore (Str.search_forward runtime_leak_re out 0);
    failf "%s: rejection leaked to RUNTIME, expected STATIC compile error.\n%s" ctx out
  with Not_found -> ()

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled\n%s" pat out;
    assert_no_runtime_leak "should_fail" out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let[@warning "-32"] known_gap ~what src =
  with_temp_file src (fun path ->
    let code, _ = run_compiler ["--check"; path] in
    if code <> 0 then
      failf "KNOWN GAP CLOSED — `%s` is now rejected; promote to should_fail." what)

(* ── Shared TESL fragments ───────────────────────────────────────────────── *)

let hdr modname = Printf.sprintf
  "#lang tesl\nmodule %s exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact]\n"
  modname

(* A single-subject token check, plus rng/id imports the producers need. *)
let tok_lib m = hdr m ^ {|
import Tesl.String exposing [String.length]
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
fact IsTok (s: String)
check checkTok(s: String) -> s: String ::: IsTok s =
  if String.length s > 8 then
    ok s ::: IsTok s
  else
    fail 400 "invalid token"
|}

(* An entity + db imports for the insert/select existential producers. *)
let todo_lib m = hdr m ^ {|
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
entity Todo table "todos" primaryKey id { id: String title: String }
|}

(* ══════════════════════════════════════════════════════════════════════════
   NOEX — existential return type but the body has no `exists` expression.
   ══════════════════════════════════════════════════════════════════════════ *)

let noex_re = "no exists expression\\|body has no exists"

(* Matrix over the inner return shape and the body that omits `exists`. *)
let noex_case idx ~ret ~body =
  let m = Printf.sprintf "Noex%02d" idx in
  let test () =
    should_fail noex_re
      (tok_lib m ^ Printf.sprintf {|
fn bad(s: String) -> exists t: String => %s
  requires [] =
  %s
|} ret body)
  in
  (Printf.sprintf "NOEX-%02d ret=%s" idx ret, test)

let noex_cases =
  [ noex_case 1 ~ret:"String ::: IsTok t" ~body:"s";
    noex_case 2 ~ret:"t: String ::: IsTok t" ~body:"s";
    noex_case 7 ~ret:"String ::: IsTok t" ~body:"\"x\"";
    (* body validates but never packs *)
    (let m = "Noex03" in
     ("NOEX-03 validated but unpacked body",
      fun () ->
        should_fail noex_re (tok_lib m ^ {|
fn bad(s: String) -> exists t: String => String ::: IsTok t
  requires [] =
  let v = check checkTok s
  v
|})));
    (* body is a let-chain with no exists at the tail *)
    (let m = "Noex04" in
     ("NOEX-04 let-chain, no exists tail",
      fun () ->
        should_fail noex_re (tok_lib m ^ {|
fn bad(s: String) -> exists t: String => String ::: IsTok t
  requires [random] =
  let a = generatePrefixedId "tok"
  let b = a
  b
|})));
    (* string-literal body, no exists *)
    (let m = "Noex05" in
     ("NOEX-05 literal body, no exists",
      fun () ->
        should_fail noex_re (tok_lib m ^ {|
fn bad(s: String) -> exists t: String => String ::: IsTok t
  requires [] =
  "literal"
|})));
    (* if/else body, neither branch packs *)
    (let m = "Noex06" in
     ("NOEX-06 if/else body, no exists in either branch",
      fun () ->
        should_fail noex_re (tok_lib m ^ {|
fn bad(s: String) -> exists t: String => String ::: IsTok t
  requires [] =
  if s == "" then
    "a"
  else
    "b"
|}))); ]

(* ══════════════════════════════════════════════════════════════════════════
   RAW — pack a raw PARAMETER whose declared proof is not demonstrably attached.
   ══════════════════════════════════════════════════════════════════════════ *)

let raw_re =
  "not demonstrably attached\\|must carry the proof\\|does not.*satisfy"

(* exists w => <param> where <param> has no proof history. *)
let raw_case idx ~witness ~packed =
  let m = Printf.sprintf "Raw%02d" idx in
  let test () =
    should_fail raw_re
      (tok_lib m ^ Printf.sprintf {|
fn bad(%s: String) -> exists t: String => String ::: IsTok t
  requires [] =
  exists %s =>
    %s
|} packed witness packed)
  in
  (Printf.sprintf "RAW-%02d pack raw param `%s`" idx packed, test)

let raw_cases =
  [ raw_case 1 ~witness:"input" ~packed:"input";
    raw_case 2 ~witness:"raw" ~packed:"raw";
    raw_case 3 ~witness:"s" ~packed:"s";
    raw_case 4 ~witness:"value" ~packed:"value";
    raw_case 5 ~witness:"tok" ~packed:"tok";
    raw_case 6 ~witness:"x" ~packed:"x";
    raw_case 7 ~witness:"arg" ~packed:"arg";
    raw_case 8 ~witness:"param" ~packed:"param";
    raw_case 9 ~witness:"data" ~packed:"data"; ]

(* Pack a raw param while a DIFFERENT param carries the witness name — still the
   packed value has no proof. *)
let raw_two_params () =
  should_fail raw_re
    (tok_lib "Raw04" ^ {|
fn bad(a: String, b: String) -> exists t: String => String ::: IsTok t
  requires [] =
  exists a =>
    a
|})

(* Pack a raw param even though a validated local is in scope (the param still
   has no proof — the validated local is simply ignored). *)
let raw_with_validated_local idx ~packed =
  let m = Printf.sprintf "RawVL%02d" idx in
  let test () =
    should_fail raw_re
      (tok_lib m ^ Printf.sprintf {|
fn bad(%s: String) -> exists t: String => String ::: IsTok t
  requires [random] =
  let other = generatePrefixedId "tok"
  let validated = check checkTok other
  exists %s =>
    %s
|} packed packed packed)
  in
  (Printf.sprintf "RAW-VL-%02d pack raw param `%s` ignoring validated local" idx packed, test)

let raw_extra_cases =
  [ ("RAW-04 pack raw param among two", raw_two_params);
    raw_with_validated_local 1 ~packed:"input";
    raw_with_validated_local 2 ~packed:"raw";
    raw_with_validated_local 3 ~packed:"s"; ]

(* GAP-PACKLOCAL — CLOSED.
   The "not demonstrably attached" check was widened: it now flags a raw
   LET-BOUND local with no proof (the result of a non-proof-producing call), not
   only a literal function parameter.  Packing such a local where the return spec
   declares a non-trivial proof is correctly rejected. *)
let pack_local_gap () =
  should_fail "not demonstrably attached"
    (tok_lib "RawGap01" ^ {|
fn bad() -> exists t: String => String ::: IsTok t
  requires [random] =
  let x = generatePrefixedId "tok"
  exists x =>
    x
|})

let pack_local_gap_cases =
  [ ("RAW-GAP-01 pack raw let-bound local (KNOWN GAP)", pack_local_gap) ]

(* ══════════════════════════════════════════════════════════════════════════
   CONS — feeding an existential result to a proof-requiring consumer.
   The witness is hidden, so the result cannot satisfy a universally-quantified
   proof site.  Rejected today; included as a positive-rejection negative.
   ══════════════════════════════════════════════════════════════════════════ *)

let cons_re = "does not.*statically.*satisfy\\|witness\\|escape\\|hidden\\|V001"

let cons_feed idx ~consumer =
  let m = Printf.sprintf "Cons%02d" idx in
  let test () =
    should_fail cons_re
      (tok_lib m ^ Printf.sprintf {|
fn gen() -> exists t: String => String ::: IsTok t requires [random] =
  let raw = generatePrefixedId "tok"
  let validated = check checkTok raw
  exists raw =>
    validated
fn %s(s: String ::: IsTok s) -> String = s
fn bad() -> String requires [random] =
  let tok = gen()
  %s tok
|} consumer consumer)
  in
  (Printf.sprintf "CONS-%02d feed existential to %s" idx consumer, test)

let cons_cases =
  List.mapi (fun i c -> cons_feed (i + 1) ~consumer:c)
    [ "consume"; "useTok"; "requireTok"; "checkTokSite"; "needTok"; "withTok" ]

(* Feed the existential result to a cross-parameter proof site (witness can't be
   used to instantiate the other subject). *)
let cons_crossparam () =
  should_fail cons_re
    (tok_lib "Cons02" ^ {|
fact Linked (a: String) (b: String)
fn gen() -> exists t: String => String ::: IsTok t requires [random] =
  let raw = generatePrefixedId "tok"
  let validated = check checkTok raw
  exists raw =>
    validated
fn needsLinked(a: String ::: Linked a b, b: String) -> String = a
fn bad(other: String) -> String requires [random] =
  let tok = gen()
  needsLinked tok other
|})

let cons_extra_cases = [ ("CONS-02 feed existential to cross-param site", cons_crossparam) ]

(* ══════════════════════════════════════════════════════════════════════════
   POS — positive companions (MUST compile).
   ══════════════════════════════════════════════════════════════════════════ *)

(* exists with a check-validated pack (proof demonstrably attached). *)
let pos_check_pack () =
  should_pass (tok_lib "PosH01" ^ {|
fn gen() -> exists t: String => String ::: IsTok t requires [random] =
  let raw = generatePrefixedId "tok"
  let validated = check checkTok raw
  exists raw =>
    validated
|})

(* exists with an insert-produced FromDb pack (the canonical create handler). *)
let pos_insert_pack () =
  should_pass (todo_lib "PosH02" ^ {|
fn create(t: String) -> exists todoId: String => Todo ? FromDb (Id == todoId)
  requires [dbRead, dbWrite, random] =
  let todoId = generatePrefixedId "todo"
  exists todoId =>
    insert Todo { id: todoId, title: t }
|})

(* exists returning a structural (Id == w) proof produced via check. *)
let pos_structural_pack () =
  should_pass (hdr "PosH03" ^ {|
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
record Session { id: String userId: String }
fact IsCreatedSession (sessionId: String, user: String)
check checkSession(session: Session, sessionId: String, user: String)
  -> session: Session ::: IsCreatedSession (Id == sessionId) user =
  if session.id == sessionId then
    ok session ::: IsCreatedSession (Id == sessionId) user
  else
    fail 500 "id mismatch"
fn createSession(user: String) -> exists sessionId: String => session: Session ::: IsCreatedSession (Id == sessionId) user
  requires [random] =
  let sessionId = generatePrefixedId "s"
  let session = Session { id: sessionId, userId: user }
  let verified = check checkSession session sessionId user
  exists sessionId =>
    verified
|})

(* exists whose return spec carries a trivial body type (no proof) — packing any
   string is allowed because nothing is claimed. *)
let pos_trivial_proof () =
  should_pass (hdr "PosH04" ^ {|
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
fact IsTok (s: String)
fn anyTok() -> exists t: String => String ::: IsTok t requires [random] =
  let raw = generatePrefixedId "tok"
  exists raw =>
    "anyrandomstring"
|})

(* exists inside a select-existential (fetch by generated id). *)
let pos_select_existential () =
  should_pass (Printf.sprintf
    "#lang tesl\nmodule PosH05 exposing []\n\
     import Tesl.Prelude exposing [String]\n\
     import Tesl.DB exposing [dbRead, dbWrite]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n\
     import Tesl.Id exposing [generatePrefixedId]\n\
     import Tesl.Random exposing [random]\n%s"
    {|
entity Todo table "todos" primaryKey id { id: String title: String }
fn fetchAuto(prefix: String) -> exists todoId: String => Todo ? FromDb (Id == todoId)
  requires [dbRead, dbWrite, random] =
  let todoId = generatePrefixedId prefix
  insert Todo { id: todoId, title: "auto" }
  let r = selectOne t from Todo where t.id == todoId
  case r of
    Nothing -> fail 500 "missing"
    Something t ->
      exists todoId =>
        t
|})

(* exists in an API handler position. *)
let pos_handler_existential () =
  should_pass (todo_lib "PosH06" ^ {|
fn createTodo(title: String) -> exists todoId: String => Todo ? FromDb (Id == todoId)
  requires [dbRead, dbWrite, random] =
  let todoId = generatePrefixedId "todo"
  exists todoId =>
    insert Todo { id: todoId, title: title }
|})

(* exists packing an attachFact-reattached proof (explicit attach). *)
let pos_attachfact_pack () =
  should_pass (Printf.sprintf
    "#lang tesl\nmodule PosH07 exposing []\n\
     import Tesl.Prelude exposing [String, Fact, detachFact, attachFact, forgetFact]\n\
     import Tesl.String exposing [String.length]\n\
     import Tesl.Id exposing [generatePrefixedId]\n\
     import Tesl.Random exposing [random]\n%s"
    {|
fact IsTok (s: String)
check checkTok(s: String) -> s: String ::: IsTok s =
  if String.length s > 8 then
    ok s ::: IsTok s
  else
    fail 400 "bad"
fn gen() -> exists t: String => String ::: IsTok t requires [random] =
  let raw = generatePrefixedId "tok"
  let validated = check checkTok raw
  let (bare ::: p) = validated
  exists raw =>
    bare ::: p
|})

(* exists in both branches of an if/else, each packing a validated value. *)
let pos_conditional_pack () =
  should_pass (tok_lib "PosH08" ^ {|
fn gen(flag: Bool) -> exists t: String => String ::: IsTok t requires [random] =
  if flag then
    let a = generatePrefixedId "tok"
    let va = check checkTok a
    exists a =>
      va
  else
    let b = generatePrefixedId "tk"
    let vb = check checkTok b
    exists b =>
      vb
|})

(* exists packing a value validated by a combined check (&&). *)
let pos_combined_check_pack () =
  should_pass (hdr "PosH09" ^ {|
import Tesl.String exposing [String.length]
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
fact IsTok (s: String)
fact IsLong (s: String)
check checkTok(s: String) -> s: String ::: IsTok s =
  if String.length s > 4 then
    ok s ::: IsTok s
  else
    fail 400 "short"
check checkLong(s: String) -> s: String ::: IsLong s =
  if String.length s > 8 then
    ok s ::: IsLong s
  else
    fail 400 "tooShort"
fn gen() -> exists t: String => String ::: IsTok t && IsLong t requires [random] =
  let raw = generatePrefixedId "token"
  let validated = check (checkTok && checkLong) raw
  exists raw =>
    validated
|})

(* exists returning an Int subject with a numeric proof. *)
let pos_int_existential () =
  should_pass (hdr "PosH10" ^ {|
fact IsValidId (n: Int)
check checkId(n: Int) -> n: Int ::: IsValidId n =
  if n > 0 then
    ok n ::: IsValidId n
  else
    fail 400 "bad id"
fn gen(seed: Int) -> exists w: Int => Int ::: IsValidId w requires [] =
  let candidate = seed + 1
  let validated = check checkId candidate
  exists candidate =>
    validated
|})

(* exists returning a record subject validated by a check. *)
let pos_record_existential () =
  should_pass (hdr "PosH11" ^ {|
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
record Account { id: String balance: Int }
fact IsOpened (a: Account)
check checkOpened(a: Account) -> a: Account ::: IsOpened a =
  if a.balance >= 0 then
    ok a ::: IsOpened a
  else
    fail 400 "negative balance"
fn openAcc() -> exists accId: String => Account ::: IsOpened acc requires [random] =
  let accId = generatePrefixedId "acc"
  let acc = Account { id: accId, balance: 0 }
  let validated = check checkOpened acc
  exists accId =>
    validated
|})

(* exists where the inner proof references the witness in (Id == w) structurally
   and the body is an insert. *)
let pos_structural_insert_existential () =
  should_pass (todo_lib "PosH12" ^ {|
fn createReturning(title: String)
  -> exists tid: String => Todo ? FromDb (Id == tid)
  requires [dbRead, dbWrite, random] =
  let tid = generatePrefixedId "t"
  exists tid =>
    insert Todo { id: tid, title: title }
|})

(* ── Registration ────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (name, fn) -> test_case name `Quick fn) lst

let () =
  run "ProofSuite-H" [
    "NOEX-no-exists-body", to_cases noex_cases;
    "RAW-unattached-pack", to_cases (raw_cases @ raw_extra_cases @ pack_local_gap_cases);
    "CONS-existential-to-consumer", to_cases (cons_cases @ cons_extra_cases);
    "POS-companions", [
      test_case "POS check-validated pack" `Quick pos_check_pack;
      test_case "POS insert FromDb pack" `Quick pos_insert_pack;
      test_case "POS structural (Id == w) pack" `Quick pos_structural_pack;
      test_case "POS trivial-proof pack any string" `Quick pos_trivial_proof;
      test_case "POS select-existential pack" `Quick pos_select_existential;
      test_case "POS handler existential" `Quick pos_handler_existential;
      test_case "POS attachFact-reattached pack" `Quick pos_attachfact_pack;
      test_case "POS conditional pack both branches" `Quick pos_conditional_pack;
      test_case "POS combined-check pack" `Quick pos_combined_check_pack;
      test_case "POS Int existential" `Quick pos_int_existential;
      test_case "POS record-witness existential" `Quick pos_record_existential;
      test_case "POS structural insert existential" `Quick pos_structural_insert_existential;
    ];
  ]
