(** Regression tests for the soundness holes closed after the 2026-07 formal
    review (see TESL-REVIEW-TECHNICAL.md).  Each NEGATIVE case is a minimal
    program that was wrongly ACCEPTED before the fix and must now be REJECTED
    (attributed to the specific new diagnostic); each POSITIVE case is the
    closest legitimate program that must keep compiling.

    Holes closed:
      2.1  Existential-pack fail-open: a non-identifier pack body (literal /
           record / plain-fn result) or a bare local carrying the WRONG fact was
           accepted as satisfying the declared `exists … => … ::: P` proof.
      2.2  FromDb DB-provenance forgeable via 2.1 (hand-built entity packed).
      2.3  requeue/deadJobs were `∀a b. a -> b` / `-> List b` — an unsafeCoerce.
      2.4  Unknown field on a newtype / opaque stdlib type returned a wildcard
           `fresh ()` (a T_ANY back door).
      2.6  ForAll forgeable: an unknown/stdlib call (e.g. List.reverse) at a
           `? ForAll P` return minted the per-element proof it never established. *)

open Alcotest

(* ── Helpers (same shape as test_p0_soundness_fixes.ml) ─────────────────── *)

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some v -> v
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let check_subcmd =
  if Filename.basename tesl = "main.exe" then "--check" else "check"

let run_flag flag src =
  let tmp = Filename.temp_file "tesl-r76" ".tesl" in
  let oc = open_out tmp in output_string oc src; close_out oc;
  let cmd = Printf.sprintf "%s %s %s 2>&1" tesl flag tmp in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let compile_string src =
  let tmp = Filename.temp_file "tesl-r76" ".tesl" in
  let oc = open_out tmp in output_string oc src; close_out oc;
  let cmd = Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let has_error out =
  try ignore (Str.search_forward (Str.regexp "error\\[") out 0); true
  with Not_found -> false

let should_pass name src =
  let out = compile_string src in
  if has_error out then Printf.eprintf "[%s] unexpected error:\n%s\n" name out;
  check bool name false (has_error out)

let should_fail name pattern src =
  let out = compile_string src in
  let matched =
    try ignore (Str.search_forward (Str.regexp_case_fold pattern) out 0); true
    with Not_found -> false
  in
  if not matched then Printf.eprintf "[%s] expected /%s/, got:\n%s\n" name pattern out;
  check bool name true (matched && has_error out)

(* ── 2.1 / 2.2 existential-pack ─────────────────────────────────────────── *)

let hdr m =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\n\
     import Tesl.Prelude exposing [Int, String, Fact, Bool(..)]\n" m

let e21_fncall_pack () =
  should_fail "2.1 fn-call pack" "must carry the proof"
    (hdr "R76a" ^ {|
fact IsAdmin (u: String)
fn helper(s: String) -> String = s
fn forge(attacker: String) -> exists u: String => String ::: IsAdmin u =
  exists attacker =>
    helper attacker
|})

let e21_wrong_fact () =
  should_fail "2.1 wrong-fact launder" "must carry the proof\\|carries proof"
    (hdr "R76b" ^ {|
fact IsShort (s: String)
fact IsAdmin (u: String)
check checkShort(s: String) -> s: String ::: IsShort s =
  if 1 <= 2 then
    ok s ::: IsShort s
  else
    fail 400 "no"
fn forge(raw: String) -> exists u: String => String ::: IsAdmin u =
  let verified = check checkShort raw
  exists verified =>
    verified
|})

let e21_legit_check_pack () =
  should_pass "2.1 legit check-validated pack"
    (hdr "R76c" ^ {|
fact IsTok (t: String)
check checkTok(t: String) -> t: String ::: IsTok t =
  if 1 <= 2 then
    ok t ::: IsTok t
  else
    fail 400 "no"
fn make(raw: String) -> exists t: String => String ::: IsTok t =
  let verified = check checkTok raw
  exists verified =>
    verified
|})

let e22_fromdb_record_forgery () =
  (* Hand-built entity record packed as FromDb, no DB access — the 2.2 forgery. *)
  should_fail "2.2 FromDb record forgery" "must carry the proof\\|FromDb"
    ("#lang tesl\nmodule R76d exposing []\n\
      import Tesl.Prelude exposing [String]\n\
      import Tesl.DB exposing [dbRead, dbWrite]\n" ^ {|
entity Note table "notes" primaryKey id { id: String body: String }
fn forge(fakeId: String) -> exists noteId: String => Note ? FromDb (Id == noteId)
  requires [dbRead, dbWrite] =
  exists fakeId =>
    Note { id: fakeId, body: "leaked-without-db" }
|})

(* ── 2.3 requeue/deadJobs unsafeCoerce ──────────────────────────────────── *)

let e23_requeue_coerce () =
  should_fail "2.3 requeue coerce" "cannot unify"
    ("#lang tesl\nmodule R76e exposing []\n\
      import Tesl.Prelude exposing [Int, String]\n\
      import Tesl.Queue exposing [requeue]\n" ^ {|
fn coerce(s: String) -> Int requires [queueWrite] = requeue s
|})

(* ── 2.4 unknown-field wildcard ─────────────────────────────────────────── *)

let e24_newtype_bogus_field () =
  should_fail "2.4 newtype bogus field" "has no field"
    ("#lang tesl\nmodule R76f exposing []\n\
      import Tesl.Prelude exposing [Int, Bool, String]\n" ^ {|
type UserId = String
fn probe(u: UserId) -> Int = u.bogus
fn probe2(u: UserId) -> Bool = u.bogus
|})

let e24_newtype_value_ok () =
  should_pass "2.4 newtype .value still works"
    ("#lang tesl\nmodule R76g exposing []\n\
      import Tesl.Prelude exposing [String]\n" ^ {|
type UserId = String
fn unwrap(u: UserId) -> String = u.value
|})

(* ── 2.6 ForAll forgeable via unknown call ──────────────────────────────── *)

let e26_forall_reverse () =
  should_fail "2.6 ForAll via List.reverse" "does not establish\\|ForAll"
    ("#lang tesl\nmodule R76h exposing []\n\
      import Tesl.Prelude exposing [Int, List]\n\
      import Tesl.List exposing [List.reverse]\n" ^ {|
fact IsPositive (n: Int)
fn demo(xs: List Int) -> List Int ? ForAll (IsPositive) requires [] =
  List.reverse xs
|})

(* ── item 5: stdlib type-table well-formedness (escaping result var) ─────── *)

let lint_stdlib_wellformed () =
  let offenders = Type_system.stdlib_escaping_result_vars () in
  if offenders <> [] then
    Printf.eprintf "escaping result-var stdlib schemes: %s\n"
      (String.concat ", " (List.map fst offenders));
  check int "stdlib has no escaping-result-var schemes (item 5)" 0 (List.length offenders)

(* ── LSP crash class: --check-json must not crash on lexer-fatal input ───── *)

let json_no_crash name src =
  let out = run_flag "--check-json" src in
  let crashed =
    try ignore (Str.search_forward (Str.regexp "Fatal error") out 0); true
    with Not_found -> false
  in
  let is_json = String.length out > 0 && out.[0] = '{' in
  if crashed || not is_json then Printf.eprintf "[%s] got:\n%s\n" name out;
  check bool name true ((not crashed) && is_json)

let lsp_unterminated_string () =
  json_no_crash "LSP --check-json unterminated string"
    "#lang tesl\nmodule R76i exposing []\nimport Tesl.Prelude exposing [String]\nfn f() -> String =\n  \"unterminated"

let () =
  run "Review76-SoundnessFixes" [
    "2.1-existential-pack", [
      test_case "fn-call pack rejected" `Quick e21_fncall_pack;
      test_case "wrong-fact launder rejected" `Quick e21_wrong_fact;
      test_case "legit check pack accepted" `Quick e21_legit_check_pack;
    ];
    "2.2-fromdb-forgery", [
      test_case "hand-built record packed as FromDb rejected" `Quick e22_fromdb_record_forgery;
    ];
    "2.3-requeue-coerce", [
      test_case "requeue String->Int rejected" `Quick e23_requeue_coerce;
      test_case "stdlib type table well-formed (item 5)" `Quick lint_stdlib_wellformed;
    ];
    "2.4-unknown-field", [
      test_case "newtype bogus field rejected" `Quick e24_newtype_bogus_field;
      test_case "newtype .value accepted" `Quick e24_newtype_value_ok;
    ];
    "2.6-forall-forgery", [
      test_case "ForAll via List.reverse rejected" `Quick e26_forall_reverse;
    ];
    "LSP-crash-class", [
      test_case "check-json on unterminated string does not crash" `Quick lsp_unterminated_string;
    ];
  ]
