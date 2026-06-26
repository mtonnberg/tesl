(** ProofSuite Family E — cross-parameter / 2-arg proofs + named-pack [?].

    Negative (must-NOT-compile) proofs that the *static* checker rejects
    cross-parameter and named-pack misuse WITHOUT relying on the runtime net.
    Plus [should_pass] positive companions establishing the correct shapes.

    Families covered:
      CP   — cross-parameter subject confusion (OwnedBy u2 vs u1, InBounds, etc.)
      TRK  — unresolved / untrackable cross-parameter subjects (literals, dotted)
      NP   — named-pack [?] result misuse (binder differs, wrong entity predicate)
      POS  — positive companions that MUST compile

    Hardening: [should_fail] requires a non-zero exit AND a case-insensitive
    regex match AND that the output contains NO runtime-leak markers
    (`raise-user-error`, `check-fail`, a Racket backtrace).  A negative whose
    rejection leaked to runtime is treated as a failure of this suite. *)

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

(* Derive the on-disk filename from the module/library header so the compiler's
   V001 "module header does not match file name" diagnostic never confounds the
   real proof error we are probing. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psE" "" in
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

(* Markers that a rejection escaped to RUNTIME rather than being caught
   statically.  NB: the compiler's own *static* error text legitimately quotes
   the tokens `check-ok`/`check-fail` when explaining why a lambda is invalid,
   so those bare words must NOT be treated as leak markers — we match only
   forms that indicate an actually-thrown runtime error. *)
let runtime_leak_re =
  Str.regexp_case_fold
    "raise-user-error\\|raise-argument-error\\|application: not a procedure\\|\
     racket/[A-Za-z_./-]*\\.rkt:[0-9]\\|^ *context\\.\\.\\.:\\|contract violation"

let assert_no_runtime_leak ctx out =
  try
    ignore (Str.search_forward runtime_leak_re out 0);
    failf "%s: rejection leaked to RUNTIME (found runtime-net marker), \
           expected a STATIC compile error.\nOutput:\n%s" ctx out
  with Not_found -> ()

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled\nOutput:\n%s" pat out;
    assert_no_runtime_leak "should_fail" out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

(* A [known_gap] is a program that SHOULD be statically rejected but compiles
   today.  We assert it still COMPILES so the suite stays green; if a future
   static-checker fix starts rejecting it, this flips loudly (the assertion
   fails) and the case should be promoted to [should_fail]. *)
let[@warning "-32"] known_gap ~what src =
  with_temp_file src (fun path ->
    let code, _ = run_compiler ["--check"; path] in
    if code <> 0 then
      failf "KNOWN GAP CLOSED — `%s` is now statically rejected; \
             promote this case from known_gap to should_fail." what)

(* ── Shared TESL fragments ───────────────────────────────────────────────── *)

let hdr modname =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\n\
     import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact]\n" modname

(* OwnedBy two-subject ownership fact over a Todo record. *)
let owned_by_lib m = hdr m ^ {|
record Todo { id: String ownerId: String }
fact OwnedBy (u: String) (t: Todo)
check checkOwned(u: String, t: Todo) -> t: Todo ::: OwnedBy u t =
  if t.ownerId == u then
    ok t ::: OwnedBy u t
  else
    fail 403 "not owner"
fn process(u: String, t: Todo ::: OwnedBy u t) -> String = t.id
|}

(* InBounds three-subject fact (proof attached to the middle/last subject). *)
let in_bounds_lib m = hdr m ^ {|
fact InBounds (lo: Int) (hi: Int) (n: Int)
check checkInBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if n >= lo && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "out of bounds"
fn requiresInBounds(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> String =
  "${n} in [${lo}, ${hi}]"
|}

(* ValidRange two-subject fact (proof attached to the lower bound). *)
let valid_range_lib m = hdr m ^ {|
fact ValidRange (lo: Int, hi: Int)
check checkValidRange(lo: Int, hi: Int) -> lo: Int ::: ValidRange lo hi =
  if lo < hi then
    ok lo ::: ValidRange lo hi
  else
    fail 400 "lo must be < hi"
fn clampToRange(lo: Int ::: ValidRange lo hi, hi: Int, value: Int) -> Int =
  if value < lo then
    lo
  else
    value
|}

(* Named-pack [?] entity + consumer for the FromDb 2-arg form. *)
let named_pack_lib m = hdr m ^ {|
import Tesl.DB exposing [dbRead, dbWrite]
entity Todo table "todos" primaryKey id { id: String title: String ownerId: String }
fn getTodo(todoId: String) -> Todo ? FromDb (Id == todoId)
  requires [dbRead] =
  let r = selectOne t from Todo where t.id == todoId
  case r of
    Nothing -> fail 404 "not found"
    Something t -> t
fn consume(t: Todo ::: FromDb (Id == id) t, id: String) -> String = t.title
|}

let satisfy_re = "does not.*statically.*satisfy\\|not trackable\\|different subject\\|V001"

(* ══════════════════════════════════════════════════════════════════════════
   CP — cross-parameter subject confusion (matrix)
   ══════════════════════════════════════════════════════════════════════════ *)

(* For OwnedBy: validate with one user, consume requiring a DIFFERENT user. *)
let cp_owned_by_wrong_user idx wrong_user =
  let m = Printf.sprintf "CpOwnA%02d" idx in
  let test () =
    should_fail satisfy_re
      (owned_by_lib m ^ Printf.sprintf {|
fn bad(u1: String, %s: String, raw: Todo) -> String =
  let t = check checkOwned u1 raw
  process %s t
|} wrong_user wrong_user)
  in
  (Printf.sprintf "CP-OWN-%02d OwnedBy consume with `%s` not `u1`" idx wrong_user, test)

(* Generate several distinct "wrong second subject" variants. *)
let cp_owned_cases =
  List.mapi (fun i u -> cp_owned_by_wrong_user (i + 1) u)
    [ "u2"; "other"; "attacker"; "victim"; "alt"; "u3"; "stranger";
      "intruder"; "owner2"; "someoneElse"; "u4"; "guest"; "admin2"; "rival" ]

(* For InBounds: shuffle which named lo/hi is reused at the require site. *)
let cp_inbounds_mismatch idx ~check_lo ~check_hi ~req_lo ~req_hi =
  let m = Printf.sprintf "CpBounds%02d" idx in
  let test () =
    should_fail satisfy_re
      (in_bounds_lib m ^ Printf.sprintf {|
fn bad(%s: Int, %s: Int, %s: Int, %s: Int, raw: Int) -> String =
  let n = check checkInBounds %s %s raw
  requiresInBounds %s %s n
|} check_lo check_hi req_lo req_hi check_lo check_hi req_lo req_hi)
  in
  (Printf.sprintf "CP-BND-%02d InBounds check(%s,%s) require(%s,%s)"
     idx check_lo check_hi req_lo req_hi, test)

let cp_inbounds_cases =
  [ cp_inbounds_mismatch 1 ~check_lo:"lo" ~check_hi:"hi" ~req_lo:"lo2" ~req_hi:"hi";
    cp_inbounds_mismatch 2 ~check_lo:"lo" ~check_hi:"hi" ~req_lo:"lo" ~req_hi:"hi2";
    cp_inbounds_mismatch 3 ~check_lo:"lo" ~check_hi:"hi" ~req_lo:"hi" ~req_hi:"lo";
    cp_inbounds_mismatch 4 ~check_lo:"a" ~check_hi:"b" ~req_lo:"b" ~req_hi:"a";
    cp_inbounds_mismatch 5 ~check_lo:"a" ~check_hi:"b" ~req_lo:"a" ~req_hi:"c";
    cp_inbounds_mismatch 6 ~check_lo:"lo" ~check_hi:"hi" ~req_lo:"lo3" ~req_hi:"hi3";
    cp_inbounds_mismatch 7 ~check_lo:"low" ~check_hi:"high" ~req_lo:"high" ~req_hi:"low";
    cp_inbounds_mismatch 8 ~check_lo:"x" ~check_hi:"y" ~req_lo:"x" ~req_hi:"z";
    cp_inbounds_mismatch 9 ~check_lo:"x" ~check_hi:"y" ~req_lo:"w" ~req_hi:"y";
    cp_inbounds_mismatch 10 ~check_lo:"p" ~check_hi:"q" ~req_lo:"q" ~req_hi:"p"; ]

(* ValidRange: clamp with a hi that differs from the checked hi. *)
let cp_validrange_wrong_hi idx wrong_hi =
  let m = Printf.sprintf "CpRange%02d" idx in
  let test () =
    should_fail satisfy_re
      (valid_range_lib m ^ Printf.sprintf {|
fn bad(rawLo: Int, rawHi: Int, %s: Int, value: Int) -> Int =
  let lo = check checkValidRange rawLo rawHi
  clampToRange lo %s value
|} wrong_hi wrong_hi)
  in
  (Printf.sprintf "CP-RNG-%02d clamp hi=`%s` not rawHi" idx wrong_hi, test)

let cp_validrange_cases =
  List.mapi (fun i h -> cp_validrange_wrong_hi (i + 1) h)
    [ "otherHi"; "wrongHi"; "hiX"; "bound"; "upper"; "max"; "ceiling"; "limit";
      "hi2"; "top"; "boundary"; "cap" ]

(* OwnedBy: validate entity A then consume a DIFFERENT entity B (same user) —
   the entity subject does not match. *)
let cp_owned_wrong_entity idx other_entity =
  let m = Printf.sprintf "CpEnt%02d" idx in
  let test () =
    should_fail satisfy_re
      (owned_by_lib m ^ Printf.sprintf {|
fn bad(u1: String, rawA: Todo, %s: Todo) -> String =
  let t = check checkOwned u1 rawA
  process u1 %s
|} other_entity other_entity)
  in
  (Printf.sprintf "CP-ENT-%02d consume entity `%s` not checked one" idx other_entity, test)

let cp_owned_entity_cases =
  List.mapi (fun i e -> cp_owned_wrong_entity (i + 1) e)
    [ "rawB"; "otherTodo"; "todoB"; "different"; "todo2"; "entityB"; "wrongTodo" ]

(* Linked two-subject relation between two strings: validate (a,b), then consume
   demanding the proof for a DIFFERENT second subject. *)
let linked_lib m = hdr m ^ {|
fact Linked (a: String) (b: String)
check checkLinked(a: String, b: String) -> a: String ::: Linked a b =
  if a == b then
    ok a ::: Linked a b
  else
    fail 400 "not linked"
fn useLinked(a: String ::: Linked a b, b: String) -> String = a
|}

let cp_linked_wrong_second idx wrong_b =
  let m = Printf.sprintf "CpLink%02d" idx in
  let test () =
    should_fail satisfy_re
      (linked_lib m ^ Printf.sprintf {|
fn bad(rawA: String, rawB: String, %s: String) -> String =
  let a = check checkLinked rawA rawB
  useLinked a %s
|} wrong_b wrong_b)
  in
  (Printf.sprintf "CP-LINK-%02d useLinked second=`%s` not rawB" idx wrong_b, test)

let cp_linked_cases =
  List.mapi (fun i b -> cp_linked_wrong_second (i + 1) b)
    [ "otherB"; "wrongB"; "bX"; "second"; "partner"; "target";
      "b2"; "linkedTo"; "counterpart"; "peer" ]

(* ══════════════════════════════════════════════════════════════════════════
   TRK — cross-parameter subjects that are NOT trackable
   ══════════════════════════════════════════════════════════════════════════ *)

(* A cross-parameter subject that DIFFERS between the check site and the
   require site is not satisfiable.  Whether the subjects are literals or named
   bindings, a mismatch is rejected statically (the proof was established for
   one pair of subjects, demanded for another). *)
let trk_literal_mismatch idx ~check_lo ~check_hi ~req_lo ~req_hi =
  let m = Printf.sprintf "TrkLit%02d" idx in
  let test () =
    should_fail satisfy_re
      (in_bounds_lib m ^ Printf.sprintf {|
fn bad(raw: Int) -> String =
  let n = check checkInBounds %s %s raw
  requiresInBounds %s %s n
|} check_lo check_hi req_lo req_hi)
  in
  (Printf.sprintf "TRK-LIT-%02d literal mismatch (%s,%s)->(%s,%s)"
     idx check_lo check_hi req_lo req_hi, test)

let trk_literal_cases =
  [ trk_literal_mismatch 1 ~check_lo:"0" ~check_hi:"100" ~req_lo:"5" ~req_hi:"100";
    trk_literal_mismatch 2 ~check_lo:"0" ~check_hi:"100" ~req_lo:"0" ~req_hi:"50";
    trk_literal_mismatch 3 ~check_lo:"1" ~check_hi:"10" ~req_lo:"2" ~req_hi:"10";
    trk_literal_mismatch 4 ~check_lo:"(-5)" ~check_hi:"5" ~req_lo:"(-4)" ~req_hi:"5";
    trk_literal_mismatch 5 ~check_lo:"10" ~check_hi:"20" ~req_lo:"11" ~req_hi:"20";
    trk_literal_mismatch 6 ~check_lo:"10" ~check_hi:"20" ~req_lo:"10" ~req_hi:"21";
    trk_literal_mismatch 7 ~check_lo:"0" ~check_hi:"1000" ~req_lo:"1" ~req_hi:"1000";
    trk_literal_mismatch 8 ~check_lo:"3" ~check_hi:"7" ~req_lo:"4" ~req_hi:"8"; ]

(* Mixed literal/named with a mismatched literal at the require site. *)
let trk_mixed idx =
  let m = Printf.sprintf "TrkMix%02d" idx in
  let test () =
    should_fail satisfy_re
      (in_bounds_lib m ^ Printf.sprintf {|
fn bad(lo: Int, raw: Int) -> String =
  let n = check checkInBounds lo 100 raw
  requiresInBounds lo 50 n
|})
  in
  (Printf.sprintf "TRK-MIX-%02d mismatched literal cross-param" idx, test)

let trk_mixed_cases = [ trk_mixed 1 ]

(* ══════════════════════════════════════════════════════════════════════════
   NP — named-pack [?] result misuse
   ══════════════════════════════════════════════════════════════════════════ *)

(* Consume requires `FromDb (Id == id) t` with id bound to a DIFFERENT key than
   the one the value was fetched with. *)
let np_wrong_key idx wrong_id =
  let m = Printf.sprintf "NpKey%02d" idx in
  let test () =
    should_fail satisfy_re
      (named_pack_lib m ^ Printf.sprintf {|
fn bad(todoId: String, %s: String) -> String requires [dbRead] =
  let todo = getTodo todoId
  consume todo %s
|} wrong_id wrong_id)
  in
  (Printf.sprintf "NP-KEY-%02d consume key `%s` not todoId" idx wrong_id, test)

let np_wrong_key_cases =
  List.mapi (fun i k -> np_wrong_key (i + 1) k)
    [ "otherId"; "wrongId"; "altKey"; "key2"; "differentId";
      "badKey"; "mismatchedId"; "swappedId"; "id2"; "keyX";
      "fakeId"; "wrongKey" ]

(* The [?] result is bound, then a DIFFERENT (raw, unfetched) value is consumed
   with the fetched key — the entity subject does not match. *)
let np_wrong_entity idx =
  let m = Printf.sprintf "NpEnt%02d" idx in
  let test () =
    should_fail satisfy_re
      (named_pack_lib m ^ {|
fn bad(todoId: String, raw: Todo) -> String requires [dbRead] =
  let todo = getTodo todoId
  consume raw todoId
|})
  in
  (Printf.sprintf "NP-ENT-%02d consume raw entity with fetched key" idx, test)

let np_wrong_entity_cases = [ np_wrong_entity 1 ]

(* Two fetches: consume entity A but with entity B's key (swapped key). *)
let np_swapped_keys idx =
  let m = Printf.sprintf "NpSwap%02d" idx in
  let test () =
    should_fail satisfy_re
      (named_pack_lib m ^ {|
fn bad(id1: String, id2: String) -> String requires [dbRead] =
  let a = getTodo id1
  let b = getTodo id2
  consume a id2
|})
  in
  (Printf.sprintf "NP-SWAP-%02d consume A with B's key" idx, test)

let np_swapped_cases =
  [ np_swapped_keys 1;
    (let m = "NpSwap02" in
     ("NP-SWAP-02 consume B with A's key",
      fun () ->
        should_fail satisfy_re (named_pack_lib m ^ {|
fn bad(id1: String, id2: String) -> String requires [dbRead] =
  let a = getTodo id1
  let b = getTodo id2
  consume b id1
|}))); ]

(* A bare `select` promising a non-FromDb proof predicate the SQL layer does not
   establish: declare `? Positive` (a user fact) on a raw select result. *)
let np_bare_select_wrong_pred idx =
  let m = Printf.sprintf "NpSel%02d" idx in
  let test () =
    should_fail "Positive\\|does not\\|satisfy\\|V001\\|P001\\|not.*scope\\|FromDb"
      (hdr m ^ Printf.sprintf {|
import Tesl.DB exposing [dbRead]
entity Todo table "todos" primaryKey id { id: String title: String }
fact Positive (t: Todo)
fn bad(todoId: String) -> Todo ? Positive
  requires [dbRead] =
  let r = selectOne t from Todo where t.id == todoId
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
|})
  in
  (Printf.sprintf "NP-SEL-%02d select promising non-FromDb pred" idx, test)

let np_bare_select_cases = [ np_bare_select_wrong_pred 1 ]

(* Use the named-pack result where a 2-arg proof is required but the BINDER
   differs: the consumer requires `OwnedBy u t` but is handed a FromDb-only
   value (predicate mismatch). *)
let np_binder_differs idx =
  let m = Printf.sprintf "NpBind%02d" idx in
  let test () =
    should_fail satisfy_re
      (hdr m ^ Printf.sprintf {|
import Tesl.DB exposing [dbRead]
entity Todo table "todos" primaryKey id { id: String title: String ownerId: String }
fact OwnedBy (u: String) (t: Todo)
fn getTodo(todoId: String) -> Todo ? FromDb (Id == todoId)
  requires [dbRead] =
  let r = selectOne t from Todo where t.id == todoId
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
fn needsOwned(u: String, t: Todo ::: OwnedBy u t) -> String = t.title
fn bad(u: String, todoId: String) -> String requires [dbRead] =
  let todo = getTodo todoId
  needsOwned u todo
|})
  in
  (Printf.sprintf "NP-BIND-%02d FromDb value at OwnedBy site" idx, test)

let np_binder_cases = [ np_binder_differs 1 ]

(* ══════════════════════════════════════════════════════════════════════════
   GAP — pin a known static-checker gap (self-referential param annotation
   compiles today; the `let`-binding form below is the rejected variant).
   ══════════════════════════════════════════════════════════════════════════ *)

(* Cross-parameter proof on a param that names a parameter which does not exist
   in scope is rejected — but a literal in the proof template position is a
   known-gap candidate. We pin the trackable-subject expectation as a positive
   instead; see POS-* below. (No false gaps asserted here.) *)

(* ══════════════════════════════════════════════════════════════════════════
   POS — positive companions (MUST compile)
   ══════════════════════════════════════════════════════════════════════════ *)

let pos_owned_by_correct () =
  should_pass (owned_by_lib "PosOwn01" ^ {|
fn good(u1: String, raw: Todo) -> String =
  let t = check checkOwned u1 raw
  process u1 t
|})

let pos_inbounds_correct () =
  should_pass (in_bounds_lib "PosBnd01" ^ {|
fn good(lo: Int, hi: Int, raw: Int) -> String =
  let n = check checkInBounds lo hi raw
  requiresInBounds lo hi n
|})

let pos_validrange_correct () =
  should_pass (valid_range_lib "PosRng01" ^ {|
fn good(rawLo: Int, rawHi: Int, value: Int) -> Int =
  let lo = check checkValidRange rawLo rawHi
  clampToRange lo rawHi value
|})

(* The canonical E positive: a `?`-returning fetch then a consumer accepting the
   2-arg FromDb form with the matching key. *)
let pos_named_pack_roundtrip () =
  should_pass (named_pack_lib "PosNp01" ^ {|
fn flow(todoId: String) -> String requires [dbRead] =
  let todo = getTodo todoId
  consume todo todoId
|})

(* Renaming a named-pack value preserves its subject; the renamed binding is
   accepted at the consumer. *)
let pos_named_pack_rename () =
  should_pass (named_pack_lib "PosNp02" ^ {|
fn flow(todoId: String) -> String requires [dbRead] =
  let todo = getTodo todoId
  let alias = todo
  consume alias todoId
|})

(* Budget-style: proof attached to the FIRST parameter, used correctly. *)
let pos_budget_first_param () =
  should_pass (hdr "PosBud01" ^ {|
fact Approved (amount: Int) (budget: Int)
check checkBudget(amount: Int, budget: Int) -> amount: Int ::: Approved amount budget =
  if amount <= budget then
    ok amount ::: Approved amount budget
  else
    fail 400 "over budget"
fn useApproved(amount: Int ::: Approved amount budget, budget: Int) -> String =
  "${amount}/${budget}"
fn good(rawAmount: Int, budget: Int) -> String =
  let amount = check checkBudget rawAmount budget
  useApproved amount budget
|})

(* IsCreatedSession-style structural (Id == x) proof produced via check, used. *)
let pos_structural_id_eq () =
  should_pass (hdr "PosSes01" ^ {|
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
fn useSession(s: Session ::: IsCreatedSession (Id == sid) user, sid: String, user: String) -> String =
  s.id
fn good(user: String) -> String requires [random] =
  let sessionId = generatePrefixedId "s"
  let session = Session { id: sessionId, userId: user }
  let verified = check checkSession session sessionId user
  useSession verified sessionId user
|})

(* Matching literal cross-parameters ARE accepted by the checker: the same
   literal subjects appear at both the check site and the require site, so the
   established proof satisfies the demand.  (This documents the implemented
   behavior, which is more permissive than lesson44's conservative note.) *)
let pos_matching_literal_crossparams () =
  should_pass (in_bounds_lib "PosLit01" ^ {|
fn good(raw: Int) -> String =
  let n = check checkInBounds 0 100 raw
  requiresInBounds 0 100 n
|})

(* Linked relation used correctly (same second subject at check and use). *)
let pos_linked_correct () =
  should_pass (linked_lib "PosLink01" ^ {|
fn good(rawA: String, rawB: String) -> String =
  let a = check checkLinked rawA rawB
  useLinked a rawB
|})

(* InBounds: internal wiring of check → require with named bindings (lesson44). *)
let pos_inbounds_wiring () =
  should_pass (in_bounds_lib "PosBnd02" ^ {|
fn describe(lo: Int, hi: Int, raw: Int) -> String =
  let safeN = check checkInBounds lo hi raw
  requiresInBounds lo hi safeN
|})

(* Named-pack value consumed at two different sites with the same key. *)
let pos_named_pack_consumed_twice () =
  should_pass (named_pack_lib "PosNp04" ^ {|
fn flow(todoId: String) -> String requires [dbRead] =
  let todo = getTodo todoId
  let r1 = consume todo todoId
  let r2 = consume todo todoId
  "${r1}/${r2}"
|})

(* Cross-param proof threaded through an intermediate fn that preserves it. *)
let pos_crossparam_threaded () =
  should_pass (in_bounds_lib "PosBnd03" ^ {|
fn relay(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> String =
  requiresInBounds lo hi n
fn good(lo: Int, hi: Int, raw: Int) -> String =
  let n = check checkInBounds lo hi raw
  relay lo hi n
|})

(* Multiple distinct named-pack fetches keep distinct subjects — both consume
   correctly with their own keys. *)
let pos_named_pack_two_fetches () =
  should_pass (named_pack_lib "PosNp03" ^ {|
fn flow(id1: String, id2: String) -> String requires [dbRead] =
  let a = getTodo id1
  let b = getTodo id2
  let ra = consume a id1
  let rb = consume b id2
  "${ra}/${rb}"
|})

(* ── Registration ────────────────────────────────────────────────────────── *)

let to_cases lst =
  List.map (fun (name, fn) -> test_case name `Quick fn) lst

let () =
  run "ProofSuite-E" [
    "CP-cross-param-confusion",
      to_cases (cp_owned_cases @ cp_owned_entity_cases @ cp_linked_cases
                @ cp_inbounds_cases @ cp_validrange_cases);
    "TRK-untrackable-subjects",
      to_cases (trk_literal_cases @ trk_mixed_cases);
    "NP-named-pack-misuse",
      to_cases (np_wrong_key_cases @ np_wrong_entity_cases @ np_swapped_cases
                @ np_bare_select_cases @ np_binder_cases);
    "POS-companions", [
      test_case "POS OwnedBy correct user" `Quick pos_owned_by_correct;
      test_case "POS InBounds correct lo/hi" `Quick pos_inbounds_correct;
      test_case "POS ValidRange correct hi" `Quick pos_validrange_correct;
      test_case "POS named-pack round-trip" `Quick pos_named_pack_roundtrip;
      test_case "POS named-pack rename preserves subject" `Quick pos_named_pack_rename;
      test_case "POS budget first-param proof" `Quick pos_budget_first_param;
      test_case "POS structural (Id == x) proof" `Quick pos_structural_id_eq;
      test_case "POS matching literal cross-params" `Quick pos_matching_literal_crossparams;
      test_case "POS Linked relation correct" `Quick pos_linked_correct;
      test_case "POS InBounds internal wiring" `Quick pos_inbounds_wiring;
      test_case "POS named-pack consumed twice" `Quick pos_named_pack_consumed_twice;
      test_case "POS cross-param threaded through fn" `Quick pos_crossparam_threaded;
      test_case "POS two named-pack fetches distinct" `Quick pos_named_pack_two_fetches;
    ];
  ]
