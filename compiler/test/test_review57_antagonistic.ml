(** Antagonistic regression tests for Critical Review 57.

    This review audits:
    1. ForAll inline tracking - filterCheck in fn bodies
    2. ForAll && combination with check combinator
    3. ForAll proof expansion through sequential filterChecks
    4. establish soundness documentation
    5. Capability checking consistency (fn vs handler vs worker)
    6. Cross-subject proof bypass attempts with decompose/recompose
    7. Deep proof chains (5+ proofs)
    8. Newtype proof patterns
    9. Complex detach-attach flows
    10. Existential witness escape
    11. Error message quality for proof violations
    12. Multi-parameter proof soundness
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

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r57" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then begin
          Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end else
          Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact, introAnd, andLeft, andRight]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.filterCheck, List.length, List.allCheck, List.map]
import Tesl.String exposing [String.length]
|}

(* ══════════════════════════════════════════════════════════════════════════
   R57_FA — ForAll inline tracking limitations
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_FA01: filterCheck in fn body DOES auto-track ForAll for single predicate — positive *)
let r57_fa01_forall_single_pred_inline_works () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn needsForAll(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs

fn inlineFilter(nums: List Int) -> Int =
  let filtered = List.filterCheck checkPos nums
  needsForAll filtered
|})

(* R57_FA02: BUG-2 FIXED — check && combination in fn body now correctly
   produces ForAll (P1 && P2) proof for the let binding *)
let r57_fa02_forall_check_and_tracked () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"

fn needsBoth(xs: List Int ::: ForAll (IsPositive && IsSmall) xs) -> Int =
  List.length xs

fn combinedInline(nums: List Int) -> Int =
  let filtered = List.filterCheck (checkPos && checkSmall) nums
  needsBoth filtered
|})

(* R57_FA03: ForAll WORKS with ? return type wrapper — positive regression *)
let r57_fa03_forall_wrapper_works () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"

fn needsBoth(xs: List Int ::: ForAll (IsPositive && IsSmall) xs) -> Int =
  List.length xs

fn filterWrapper(nums: List Int) -> List Int ? ForAll (IsPositive && IsSmall) requires [] =
  List.filterCheck (checkPos && checkSmall) nums

fn callWrapper(nums: List Int) -> Int =
  let result = filterWrapper nums
  needsBoth result
|})

(* R57_FA04 UPDATED: Sequential filterCheck now DOES accumulate ForAll (fixed in R58).
   filterCheck(checkSmall, filterCheck(checkPos, xs)) now produces ForAll(IsPositive && IsSmall). *)
let r57_fa04_sequential_forall_not_accumulated () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"

fn needsBoth(xs: List Int ::: ForAll (IsPositive && IsSmall) xs) -> Int =
  List.length xs

fn sequentialFilter(nums: List Int) -> Int =
  let pos = List.filterCheck checkPos nums
  let small = List.filterCheck checkSmall pos
  needsBoth small
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_CS — Cross-subject proof soundness
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_CS01: attach proof from x to y should be rejected *)
let r57_cs01_cross_subject_rejected () =
  should_fail "does not statically satisfy\\|different subject" (
    base_header ^ {|
fact IsPositive (n: Int)

establish makePos(n: Int) -> Fact (IsPositive n) =
  IsPositive n

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn attack(x: Int, y: Int) -> Int =
  let pf = makePos x
  requiresPositive <| y ::: pf
|})

(* R57_CS02: decompose-reattach with wrong predicate — NOW STATICALLY REJECTED.
   Closed by GAP-CONJPROJ: conjunction decomposition now projects each binder to its
   specific conjunct, so reattaching `tp` (ValidTag) where ValidScore is required no
   longer type-checks.  (Was a documented static-checker gap caught only at runtime;
   the proofsuite found it independently as GAP-CONJPROJ.) *)
let r57_cs02_wrong_pred_via_conj_decompose_static_gap () =
  should_fail "does not statically satisfy" (
    base_header ^ {|
fact ValidScore (n: Int)
fact ValidTag (s: String)

check checkScore(n: Int) -> n: Int ::: ValidScore n =
  if n >= 0 && n <= 100 then
    ok n ::: ValidScore n
  else
    fail 400 "bad"

check checkTag(s: String) -> s: String ::: ValidTag s =
  if String.length s > 0 then
    ok s ::: ValidTag s
  else
    fail 400 "bad"

fn requiresScore(n: Int ::: ValidScore n) -> Int = n

fn wrongPredicateViaDecompose(score: Int ::: ValidScore score, tag: String ::: ValidTag tag) -> Int =
  let (rawScore ::: scoreProof) = score
  let (rawTag ::: tagProof) = tag
  let (_ ::: sp && tp) = rawScore ::: scoreProof && tagProof
  let x = rawScore ::: tp
  requiresScore x
|})

(* R57_CS03: same-predicate different-subject reattach rejected *)
let r57_cs03_same_pred_diff_subject_rejected () =
  should_fail "does not statically satisfy\\|different subject" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn differentSubjectBypass(x: Int, y: Int) -> Int =
  let vx = check checkPos x
  let pf = detachFact vx
  requiresPositive <| y ::: pf
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_DP — Deep proof chains (5+ proofs)
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_DP01: 5-proof chain compiles and validates *)
let r57_dp01_five_proof_chain () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)
fact E (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "bad"

check checkB(n: Int ::: A n) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "bad"

check checkC(n: Int ::: A n && B n) -> n: Int ::: C n =
  if n != 42 then
    ok n ::: C n
  else
    fail 400 "bad"

check checkD(n: Int ::: A n && B n && C n) -> n: Int ::: D n =
  if n != 99 then
    ok n ::: D n
  else
    fail 400 "bad"

check checkE(n: Int ::: A n && B n && C n && D n) -> n: Int ::: E n =
  ok n ::: E n

fn needsAll(n: Int ::: A n && B n && C n && D n && E n) -> Int = n

fn buildChain(raw: Int) -> Int =
  let a = check checkA raw
  let b = check checkB a
  let c = check checkC b
  let d = check checkD c
  let e = check checkE d
  needsAll e
|})

(* R57_DP02: missing step in 5-proof chain detected *)
let r57_dp02_five_proof_chain_missing_step () =
  should_fail "does not statically satisfy" (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)
fact E (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "bad"

check checkE(n: Int ::: A n) -> n: Int ::: E n =
  ok n ::: E n

fn needsAll(n: Int ::: A n && B n && C n && D n && E n) -> Int = n

fn missingSteps(raw: Int) -> Int =
  let a = check checkA raw
  let e = check checkE a
  needsAll e
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_EX — Existential witness handling
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_EX01: existential witness cannot be passed directly to fn requiring proof *)
let r57_ex01_existential_not_directly_usable () =
  should_fail "does not statically satisfy" (
    base_header ^ {|
import Tesl.Random exposing [random]
import Tesl.Id exposing [generatePrefixedId]

fact HasId (s: String)

capability myRandom implies random

fn generateAndReturn() -> exists id: String => String ::: HasId id
  requires [myRandom] =
  let id = generatePrefixedId "item"
  exists id => id

fn needsId(s: String ::: HasId s) -> String = s

fn tryEscape() -> String requires [myRandom] =
  let thing = generateAndReturn()
  needsId thing
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_ES — Establish unsoundness documentation
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_ES01: establish is trusted and will compile even for "wrong" values *)
let r57_es01_establish_unconditional () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)

establish assertPositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn unsoundUsage(n: Int) -> Int =
  let pf = assertPositive n
  requiresPositive <| n ::: pf
|})

(* R57_ES02: establish in fn body cannot use ok or fail *)
let r57_es02_establish_no_ok () =
  should_fail "establish functions must return proof constructors\\|not allowed in.*establish" (
    base_header ^ {|
fact IsPositive (n: Int)

establish badEstablish(n: Int) -> Fact (IsPositive n) =
  ok n ::: IsPositive n
|})

(* R57_ES03: establish cannot call check functions *)
let r57_es03_establish_no_check_calls () =
  should_fail "establish.*check\\|check.*establish" (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

establish badEstablish(n: Int) -> Fact (IsPositive n) =
  let v = check checkPos n
  IsPositive v
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_NT — Newtype proof isolation
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_NT01: UserId and ProjectId cannot be interchanged *)
let r57_nt01_newtype_isolation () =
  should_fail "cannot unify.*UserId.*ProjectId\\|cannot unify.*ProjectId.*UserId" (
    base_header ^ {|
type UserId = String
type ProjectId = String

fact ValidUserId (id: UserId)
fact ValidProjectId (id: ProjectId)

check checkUserId(s: String) -> id: UserId ::: ValidUserId id =
  let id = UserId s
  if String.length s > 3 then
    ok id ::: ValidUserId id
  else
    fail 400 "bad"

fn requiresValidUser(id: UserId ::: ValidUserId id) -> String = id.value
fn requiresValidProject(id: ProjectId ::: ValidProjectId id) -> String = id.value

fn testConfusion(userId: UserId ::: ValidUserId userId) -> String =
  requiresValidProject userId
|})

(* R57_NT02: newtype proof pattern works correctly *)
let r57_nt02_newtype_proof_roundtrip () =
  should_pass (
    base_header ^ {|
type UserId = String

fact ValidUserId (id: UserId)

check checkUserId(s: String) -> id: UserId ::: ValidUserId id =
  let id = UserId s
  if String.length s > 3 then
    ok id ::: ValidUserId id
  else
    fail 400 "bad"

fn requiresValidUser(id: UserId ::: ValidUserId id) -> String = id.value

fn processUser(rawId: String) -> String =
  let userId = check checkUserId rawId
  requiresValidUser userId
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_MP — Multi-parameter proof soundness
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_MP01: multi-param proof requires all subjects as function params *)
let r57_mp01_multi_param_all_subjects_required () =
  should_fail "proof subject.*is not a parameter name\\|not a parameter" (
    base_header ^ {|
fact OwnedBy (userId: String, taskId: Int)

check checkOwned(userId: String, taskId: Int) -> taskId: Int ::: OwnedBy userId taskId =
  if taskId > 0 then
    ok taskId ::: OwnedBy userId taskId
  else
    fail 403 "not owned"

fn badRequires(task: Int ::: OwnedBy user task) -> Int = task
|})

(* R57_MP02: multi-param proof works when all subjects are parameters *)
let r57_mp02_multi_param_full_params () =
  should_pass (
    base_header ^ {|
fact OwnedBy (userId: String, taskId: Int)

check checkOwned(userId: String, taskId: Int) -> taskId: Int ::: OwnedBy userId taskId =
  if taskId > 0 then
    ok taskId ::: OwnedBy userId taskId
  else
    fail 403 "not owned"

fn requiresOwned(userId: String, task: Int ::: OwnedBy userId task) -> Int = task

fn process(userId: String, taskId: Int) -> Int =
  let ownedTask = check checkOwned userId taskId
  requiresOwned userId ownedTask
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_CA — Capability checking consistency
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_CA01: BUG-4 FIXED — fn without random capability using generatePrefixedId
   is now correctly rejected (random capability is required) *)
let r57_ca01_fn_random_cap_enforced () =
  should_fail "uses.*random\\|does not declare.*capabilities" (
    base_header ^ {|
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]

fn missingCapFn() -> String requires [] =
  generatePrefixedId "item"
|})

(* R57_CA02: handler without dbRead is caught *)
let r57_ca02_handler_db_cap_checked () =
  should_fail "uses.*dbRead\\|does not declare.*capabilities" (
    {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

entity Item table "items" primaryKey id {
  id: String @db(text)
  value: Int @db(integer)
}

database TestDB = Database {
  schema: "test"
  entities: [Item]
  backend: Postgres (PostgresConfig {
    dbName: "testdb"
    user: "testuser"
    password: "testpass"
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}

handler getItems() -> List Item requires [] =
  select item from Item
|})

(* R57_CA03: fn without dbRead using select is caught *)
let r57_ca03_fn_db_cap_checked () =
  should_fail "uses.*dbRead\\|does not declare.*capabilities" (
    {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

entity Item table "items" primaryKey id {
  id: String @db(text)
  value: Int @db(integer)
}

database TestDB = Database {
  schema: "test"
  entities: [Item]
  backend: Postgres (PostgresConfig {
    dbName: "testdb"
    user: "testuser"
    password: "testpass"
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}

fn getItemsFn() -> List Item requires [] =
  select item from Item
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_REC — Recursive type proofs
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_REC01: recursive type with proof field compiles and validates *)
let r57_rec01_recursive_type_proof () =
  should_pass (
    base_header ^ {|
import Tesl.Either exposing [Either(..)]

fact IsPositive (n: Int)

type Tree
  = Leaf
  | Node (left: Tree) (value: Int ::: IsPositive value) (right: Tree)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn needsPositive(n: Int ::: IsPositive n) -> Int = n

fn findMin(t: Tree) -> Either String (Int ? IsPositive) =
  case t of
    Leaf -> Left "empty"
    Node Leaf cur _ -> Right cur
    Node l _ _ -> findMin l

fn getMin(t: Tree) -> Int =
  let m = findMin t
  case m of
    Left _ -> 0
    Right v -> needsPositive v

fn insertTree(t: Tree, v: Int ::: IsPositive v) -> Tree =
  case t of
    Leaf -> Node { left: Leaf, value: v, right: Leaf }
    Node l cur r ->
      if v < cur then
        Node { left: insertTree l v, value: cur, right: r }
      else
        Node { left: l, value: cur, right: insertTree r v }
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_ERR — Error message quality
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_ERR01: proof not satisfied gives actionable hint *)
let r57_err01_proof_error_hint () =
  let code, out =
    with_temp_file (base_header ^ {|
fact IsPositive (n: Int)

fn requiresPositive(n: Int ::: IsPositive n) -> Int = n

fn badCall(n: Int) -> Int =
  requiresPositive n
|}) (fun path -> run_compiler ["--check"; path])
  in
  if code = 0 then failf "expected failure, got success";
  let has_hint = try
    ignore (Str.search_forward (Str.regexp_case_fold "validate.*check function\\|hint") out 0);
    true
  with Not_found -> false
  in
  if not has_hint then failf "expected actionable hint, got:\n%s" out

(* R57_ERR02: wrong capability name gives clear message *)
let r57_err02_wrong_capability_message () =
  should_fail "undeclared capability" (
    {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbRead]

capability myDb implies dbRead

handler test() -> String requires [nonExistentCap] = "ok"
|})

(* R57_ERR03: shadow detection gives clear message *)
let r57_err03_shadow_rejection () =
  should_fail "shadow\\|already bound" (
    base_header ^ {|
fn shadowTest(x: Int) -> Int =
  let x = 42
  x
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_PC — Proof combining operations
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_PC01: introAnd produces conjunction proof *)
let r57_pc01_intro_and () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)

establish makeA(n: Int) -> Fact (A n) = A n
establish makeB(n: Int) -> Fact (B n) = B n

fn needsAB(n: Int ::: A n && B n) -> Int = n

fn combineProofs(n: Int) -> Int =
  let pA = makeA n
  let pB = makeB n
  let pAB = introAnd pA pB
  needsAB <| n ::: pAB
|})

(* R57_PC02: andLeft/andRight decompose conjunction *)
let r57_pc02_and_left_right () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)

establish makeA(n: Int) -> Fact (A n) = A n
establish makeB(n: Int) -> Fact (B n) = B n

fn needsA(n: Int ::: A n) -> Int = n
fn needsB(n: Int ::: B n) -> Int = n

fn decomposeProofs(n: Int) -> Int =
  let pA = makeA n
  let pB = makeB n
  let pAB = introAnd pA pB
  let pA2 = andLeft pAB
  let pB2 = andRight pAB
  needsA <| n ::: pA2
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_NP — Named pack / ? return type
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_NP01: named pack return type works correctly *)
let r57_np01_named_pack_basic () =
  should_pass (
    base_header ^ {|
import Tesl.Either exposing [Either(..)]

fact IsPositive (n: Int)

type PosTree
  = PLeaf
  | PNode (left: PosTree) (value: Int ::: IsPositive value) (right: PosTree)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn needsPositive(n: Int ::: IsPositive n) -> Int = n

fn findPosMin(t: PosTree) -> Maybe (Int ? IsPositive) =
  case t of
    PLeaf -> Nothing
    PNode PLeaf cur _ -> Something cur
    PNode l _ _ -> findPosMin l

fn useMin(t: PosTree) -> Int =
  let m = findPosMin t
  case m of
    Nothing -> 0
    Something v -> needsPositive v
|})

(* R57_NP02: ? return type with wrong predicate fails *)
let r57_np02_named_pack_wrong_pred () =
  should_fail "does not statically satisfy\\|proof" (
    base_header ^ {|
import Tesl.Either exposing [Either(..)]

fact IsPositive (n: Int)
fact IsNegative (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn needsNegative(n: Int ::: IsNegative n) -> Int = n

type PosTree
  = PLeaf
  | PNode (left: PosTree) (value: Int ::: IsPositive value) (right: PosTree)

fn findAndMisuse(t: PosTree) -> Int =
  case t of
    PLeaf -> 0
    PNode PLeaf cur _ ->
      needsNegative cur
    PNode l _ _ -> 0
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_STR — String interpolation edge cases
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_STR01: string interpolation with proof-carrying Int works *)
let r57_str01_interpolation_proof_value () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn interpolate(n: Int ::: IsPositive n) -> String =
  "value is ${n}"
|})

(* R57_STR02: Float not importable from Tesl.Prelude but from Tesl.Float *)
let r57_str02_float_import () =
  should_fail "does not export.*Float\\|Float.*not in scope\\|is not in scope" (
    {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Float]

fn testFloat(x: Float) -> Float = x
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_B1 — BUG-1: SQL keyword naming conflict fixes
   ══════════════════════════════════════════════════════════════════════════ *)

let db_entity_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

entity Item table "items" primaryKey id {
  id: String @db(text)
  value: Int @db(integer)
}

database TestDB = Database {
  schema: "test"
  entities: [Item]
  backend: Postgres (PostgresConfig {
    dbName: "testdb"
    user: "testuser"
    password: "testpass"
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
|}

(* R57_B1_01: fn named insert should NOT trigger dbWrite requirement *)
let r57_b1_01_insert_user_fn () =
  should_pass (
    base_header ^ {|
fn insert(a: Int, b: Int) -> Int = a + b
fn use_insert(n: Int) -> Int = insert n 3
|})

(* R57_B1_02: fn named select should NOT trigger dbRead requirement *)
let r57_b1_02_select_user_fn () =
  should_pass (
    base_header ^ {|
fn select(a: Int) -> Int = a * 2
fn use_select(n: Int) -> Int = select n
|})

(* R57_B1_03: fn named update should NOT trigger dbWrite requirement *)
let r57_b1_03_update_user_fn () =
  should_pass (
    base_header ^ {|
fn update(a: Int, b: Int) -> Int = a + b
fn use_update(n: Int) -> Int = update n 1
|})

(* R57_B1_04: fn named delete should NOT trigger dbWrite requirement *)
let r57_b1_04_delete_user_fn () =
  should_pass (
    base_header ^ {|
fn delete(a: Int) -> Int = a - 1
fn use_delete(n: Int) -> Int = delete n
|})

(* R57_B1_05: actual SQL insert without DB cap IS caught *)
let r57_b1_05_sql_insert_needs_cap () =
  should_fail "uses.*dbWrite\\|does not declare.*capabilities" (
    db_entity_header ^ {|
handler badHandler() -> String requires [] =
  let _ = insert Item { id: "x", value: 1 }
  "done"
|})

(* R57_B1_06: user fn named insert has the correct return type (Int, not entity type) *)
let r57_b1_06_user_insert_type () =
  should_pass (
    base_header ^ {|
fn insert(a: Int, b: Int) -> Int = a + b

fn test() -> Int =
  let result = insert 5 3
  result + 1
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_B2 — BUG-2: ForAll && check combination fixes
   ══════════════════════════════════════════════════════════════════════════ *)

(* R57_B2_01: double && combination inline in fn body *)
let r57_b2_01_double_and_inline () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "bad"

fn needsBoth(xs: List Int ::: ForAll (IsPositive && IsSmall) xs) -> Int =
  List.length xs

fn doubleCombined(nums: List Int) -> Int =
  let filtered = List.filterCheck (checkPos && checkSmall) nums
  needsBoth filtered
|})

(* R57_B2_02: triple && combination inline in fn body *)
let r57_b2_02_triple_and_inline () =
  should_pass (
    base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "bad"

check checkB(n: Int) -> n: Int ::: B n =
  if n < 100 then
    ok n ::: B n
  else
    fail 400 "bad"

check checkC(n: Int) -> n: Int ::: C n =
  if n != 42 then
    ok n ::: C n
  else
    fail 400 "bad"

fn needsAll(xs: List Int ::: ForAll (A && B && C) xs) -> Int =
  List.length xs

fn tripleFilter(nums: List Int) -> Int =
  let filtered = List.filterCheck (checkA && checkB && checkC) nums
  needsAll filtered
|})

(* R57_B2_03: allCheck with && combination *)
let r57_b2_03_allcheck_and () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "bad"

fn validAll(xs: List Int) -> Maybe (r: List Int ::: ForAll (IsPositive && IsSmall) r) =
  List.allCheck (checkPos && checkSmall) xs
|})

(* R57_B2_04 UPDATED: sequential filterChecks now DO accumulate ForAll (fixed in R58).
   The proof from the first filterCheck is merged into the second filterCheck's ForAll. *)
let r57_b2_04_sequential_filters () =
  should_pass (
    base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "bad"

fn needsBoth(xs: List Int ::: ForAll (IsPositive && IsSmall) xs) -> Int =
  List.length xs

fn seqFilter(nums: List Int) -> Int =
  let pos = List.filterCheck checkPos nums
  let small = List.filterCheck checkSmall pos
  needsBoth small
|})

(* ══════════════════════════════════════════════════════════════════════════
   R57_B4 — BUG-4: random capability enforcement
   ══════════════════════════════════════════════════════════════════════════ *)

let random_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
|}

(* R57_B4_01: fn WITH random capability can use generatePrefixedId *)
let r57_b4_01_fn_with_random () =
  should_pass (
    random_header ^ {|
fn genId() -> String requires [random] =
  generatePrefixedId "item"
|})

(* R57_B4_02: fn WITHOUT random capability cannot use generatePrefixedId *)
let r57_b4_02_fn_without_random () =
  should_fail "uses.*random\\|does not declare.*capabilities" (
    random_header ^ {|
fn genIdBad() -> String requires [] =
  generatePrefixedId "item"
|})

(* R57_B4_03: handler WITH random capability can use generatePrefixedId *)
let r57_b4_03_handler_with_random () =
  should_pass (
    random_header ^ {|
handler genHandler() -> String requires [random] =
  generatePrefixedId "item"
|})

(* R57_B4_04: handler WITHOUT random capability cannot use generatePrefixedId *)
let r57_b4_04_handler_without_random () =
  should_fail "uses.*random\\|does not declare.*capabilities" (
    random_header ^ {|
handler genHandlerBad() -> String requires [] =
  generatePrefixedId "item"
|})

(* ══════════════════════════════════════════════════════════════════════════
   Test runner
   ══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "Review57-Antagonistic" [
    "forall-inline-limitation", [
      test_case "R57_FA01 single filterCheck in fn body works" `Quick r57_fa01_forall_single_pred_inline_works;
      test_case "R57_FA02 check&& combination now tracked (BUG-2 fixed)" `Quick r57_fa02_forall_check_and_tracked;
      test_case "R57_FA03 ForAll wrapper ? return works" `Quick r57_fa03_forall_wrapper_works;
      test_case "R57_FA04 sequential filterCheck not accumulated" `Quick r57_fa04_sequential_forall_not_accumulated;
    ];
    "cross-subject-soundness", [
      test_case "R57_CS01 cross-subject attach rejected" `Quick r57_cs01_cross_subject_rejected;
      test_case "R57_CS02 wrong-pred via conj-decompose static gap" `Quick r57_cs02_wrong_pred_via_conj_decompose_static_gap;
      test_case "R57_CS03 same-pred diff-subject rejected" `Quick r57_cs03_same_pred_diff_subject_rejected;
    ];
    "deep-proof-chains", [
      test_case "R57_DP01 5-proof chain compiles" `Quick r57_dp01_five_proof_chain;
      test_case "R57_DP02 missing step in chain detected" `Quick r57_dp02_five_proof_chain_missing_step;
    ];
    "existential-witnesses", [
      test_case "R57_EX01 existential not directly usable" `Quick r57_ex01_existential_not_directly_usable;
    ];
    "establish-soundness", [
      test_case "R57_ES01 establish unconditional (trusted boundary)" `Quick r57_es01_establish_unconditional;
      test_case "R57_ES02 establish no ok allowed" `Quick r57_es02_establish_no_ok;
      test_case "R57_ES03 establish no check calls" `Quick r57_es03_establish_no_check_calls;
    ];
    "newtype-proofs", [
      test_case "R57_NT01 newtype confusion rejected" `Quick r57_nt01_newtype_isolation;
      test_case "R57_NT02 newtype proof roundtrip works" `Quick r57_nt02_newtype_proof_roundtrip;
    ];
    "multi-parameter-proofs", [
      test_case "R57_MP01 missing param subjects rejected" `Quick r57_mp01_multi_param_all_subjects_required;
      test_case "R57_MP02 full param list works" `Quick r57_mp02_multi_param_full_params;
    ];
    "capability-checking", [
      test_case "R57_CA01 fn random cap enforced (BUG-4 fixed)" `Quick r57_ca01_fn_random_cap_enforced;
      test_case "R57_CA02 handler db cap checked" `Quick r57_ca02_handler_db_cap_checked;
      test_case "R57_CA03 fn db cap checked" `Quick r57_ca03_fn_db_cap_checked;
    ];
    "recursive-type-proofs", [
      test_case "R57_REC01 recursive type proof works" `Quick r57_rec01_recursive_type_proof;
    ];
    "error-messages", [
      test_case "R57_ERR01 actionable hint in proof error" `Quick r57_err01_proof_error_hint;
      test_case "R57_ERR02 wrong capability message" `Quick r57_err02_wrong_capability_message;
      test_case "R57_ERR03 shadow rejection message" `Quick r57_err03_shadow_rejection;
    ];
    "proof-combining", [
      test_case "R57_PC01 introAnd produces conjunction" `Quick r57_pc01_intro_and;
      test_case "R57_PC02 andLeft/andRight decompose" `Quick r57_pc02_and_left_right;
    ];
    "named-pack-return", [
      test_case "R57_NP01 named pack basic" `Quick r57_np01_named_pack_basic;
      test_case "R57_NP02 named pack wrong pred fails" `Quick r57_np02_named_pack_wrong_pred;
    ];
    "string-interpolation", [
      test_case "R57_STR01 interpolation with proof value" `Quick r57_str01_interpolation_proof_value;
      test_case "R57_STR02 Float not in Prelude" `Quick r57_str02_float_import;
    ];
    "bug1-sql-keyword-naming", [
      test_case "R57_B1_01 fn named insert compiles without dbWrite" `Quick r57_b1_01_insert_user_fn;
      test_case "R57_B1_02 fn named select compiles without dbRead" `Quick r57_b1_02_select_user_fn;
      test_case "R57_B1_03 fn named update compiles without dbWrite" `Quick r57_b1_03_update_user_fn;
      test_case "R57_B1_04 fn named delete compiles without dbWrite" `Quick r57_b1_04_delete_user_fn;
      test_case "R57_B1_05 SQL insert still needs dbWrite" `Quick r57_b1_05_sql_insert_needs_cap;
      test_case "R57_B1_06 user insert return type is fn type" `Quick r57_b1_06_user_insert_type;
    ];
    "bug2-forall-and-combination", [
      test_case "R57_B2_01 double && inline" `Quick r57_b2_01_double_and_inline;
      test_case "R57_B2_02 triple && inline" `Quick r57_b2_02_triple_and_inline;
      test_case "R57_B2_03 allCheck && works" `Quick r57_b2_03_allcheck_and;
      test_case "R57_B2_04 sequential filterChecks" `Quick r57_b2_04_sequential_filters;
    ];
    "bug4-random-capability", [
      test_case "R57_B4_01 fn with random cap passes" `Quick r57_b4_01_fn_with_random;
      test_case "R57_B4_02 fn without random fails" `Quick r57_b4_02_fn_without_random;
      test_case "R57_B4_03 handler with random passes" `Quick r57_b4_03_handler_with_random;
      test_case "R57_B4_04 handler without random fails" `Quick r57_b4_04_handler_without_random;
    ];
  ]
