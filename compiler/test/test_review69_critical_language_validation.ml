(** Critical language validation tests — Review 69.

    These tests verify Tesl's core advertised claims against the actual
    implementation.  They are written as an independent evaluator would
    write them: testing the language's behavior, not its internal structure.

    Claims under test (from TESL.md / README.md):
      A. "validate once at the boundary, then carry the result as evidence"
      B. "make auth requirements visible in signatures"
      C. "capabilities and side effects explicit"
      D. "forgetting to validate is a compile error, not a runtime bug"
      E. "refactoring preserves guarantees"
      F. "built-in mutation testing for check, establish, auth functions"
      G. Standard library and module system work as documented
      H. Error messages for common newcomer mistakes are clear

    Test groups:
      CT — core types and functions
      PR — proof system basics
      PF — proof flow through calls
      PC — proof composition
      CP — capabilities
      AU — auth
      AP — api + server wiring
      SL — standard library
      EM — error message quality
      MS — module system
      PT — pattern matching
      MT — mutation testing claims *)

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
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r69" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
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

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── CT — Core types and functions ──────────────────────────────────────── *)

let test_CT01_type_mismatch_is_compile_error () =
  (* Claim: type system catches wrong return types *)
  should_fail "type.*mismatch\\|expected.*String\\|Int.*String\\|String.*Int" {|
#lang tesl
module CT01 exposing []
import Tesl.Prelude exposing [Int, String]
fn bad(n: Int) -> String = n
|}

let test_CT02_function_with_correct_types_accepted () =
  should_pass {|
#lang tesl
module CT02 exposing []
import Tesl.Prelude exposing [Int, String]
fn double(n: Int) -> Int = n * 2
fn greet(name: String) -> String = "Hello, ${name}!"
|}

let test_CT03_wrong_argument_type_rejected () =
  should_fail "type.*mismatch\\|expected.*Int\\|String.*Int" {|
#lang tesl
module CT03 exposing []
import Tesl.Prelude exposing [Int, String]
fn double(n: Int) -> Int = n * 2
fn bad() -> Int = double "not a number"
|}

let test_CT04_adt_pattern_match_accepted () =
  should_pass {|
#lang tesl
module CT04 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn safeMul(a: Int, b: Int) -> Maybe Int =
  if a > 0 then
    Something (a * b)
  else
    Nothing
|}

let test_CT05_missing_case_arm_rejected () =
  (* Claim: exhaustiveness checking works *)
  should_fail "non-exhaustive\\|missing.*Nothing\\|missing.*constructor" {|
#lang tesl
module CT05 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn unsafe(m: Maybe Int) -> Int =
  case m of
    Something n -> n
|}

let test_CT06_all_case_arms_covered_accepted () =
  should_pass {|
#lang tesl
module CT06 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn safe(m: Maybe Int) -> Int =
  case m of
    Something n -> n
    Nothing -> 0
|}

(* ── PR — Proof system basics ─────────────────────────────────────────────── *)

let test_PR01_check_produces_proof_accepted () =
  (* Claim A: check functions produce proof-carrying values *)
  should_pass {|
#lang tesl
module PR01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "must be positive"
fn requiresPositive(n: Int ::: IsPositive n) -> Int = n + 1
fn test() -> Int =
  let x = check checkPos 5
  requiresPositive x
|}

let test_PR02_unvalidated_value_where_proof_required_rejected () =
  (* Claim D: "forgetting to validate is a compile error" *)
  should_fail "proof\\|not.*satisfy\\|IsPositive\\|does not.*statically" {|
#lang tesl
module PR02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn requiresPositive(n: Int ::: IsPositive n) -> Int = n + 1
fn badCaller(rawN: Int) -> Int = requiresPositive rawN
|}

let test_PR03_check_failure_path_compiles () =
  should_pass {|
#lang tesl
module PR03 exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
fact NonEmpty (s: String)
check checkNonEmpty(s: String) -> s: String ::: NonEmpty s =
  if String.length s > 0 then
    ok s ::: NonEmpty s
  else
    fail 400 "cannot be empty"
|}

let test_PR04_fact_declaration_required_before_use () =
  (* You must declare a fact before using it as a proof predicate *)
  should_fail "not in scope\\|unknown.*proof\\|IsValidated\\|type.*not" {|
#lang tesl
module PR04 exposing []
import Tesl.Prelude exposing [Int]
check checkVal(n: Int) -> n: Int ::: IsValidated n =
  if n > 0 then
    ok n ::: IsValidated n
  else
    fail 400 "invalid"
|}

let test_PR05_ok_without_proof_annotation_rejected () =
  (* check must return value with proof — missing ::: is a syntax or type error *)
  should_fail "proof\\|return.*proof\\|ok.*proof\\|annotation\\|expected.*:::" {|
#lang tesl
module PR05 exposing []
import Tesl.Prelude exposing [Int]
fact Validated (n: Int)
check badCheck(n: Int) -> n: Int ::: Validated n =
  if n > 0 then
    ok n
  else
    fail 400 "bad"
|}

let test_PR06_establish_produces_unconditional_proof () =
  (* establish is for unconditional proof minting at a trust boundary *)
  should_pass {|
#lang tesl
module PR06 exposing []
import Tesl.Prelude exposing [Int]
fact InRange (lo: Int) (hi: Int) (n: Int)
establish proveInRange(n: Int) -> Fact (InRange 1 100 n) =
  InRange 1 100 n
fn needsRange(n: Int ::: InRange 1 100 n) -> Int = n
fn test(raw: Int) -> Int =
  let pf = proveInRange raw
  needsRange <| raw ::: pf
|}

let test_PR07_auth_function_structure_accepted () =
  (* auth is a special proof producer for HTTP requests *)
  should_pass {|
#lang tesl
module PR07 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
auth simpleAuth(req: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "token" req.cookies of
    Nothing -> fail 401 "not authenticated"
    Something t -> ok t ::: Authenticated user
|}

let test_PR08_check_return_type_must_match_binding () =
  (* The binding name in the return type must match the parameter *)
  should_fail "type.*mismatch\\|return.*type\\|proof\\|mismatch" {|
#lang tesl
module PR08 exposing []
import Tesl.Prelude exposing [Int, String]
fact IsValid (s: String)
check badCheck(n: Int) -> n: Int ::: IsValid n =
  if n > 0 then
    ok n ::: IsValid n
  else
    fail 400 "bad"
|}

(* ── PF — Proof flow through function calls ──────────────────────────────── *)

let test_PF01_proof_flows_from_check_to_requiring_fn () =
  (* Core claim A: proof carries from check to consumer *)
  should_pass {|
#lang tesl
module PF01 exposing []
import Tesl.Prelude exposing [Int, String]
fact ValidPort (port: Int)
check isValidPort(port: Int) -> port: Int ::: ValidPort port =
  if 1 <= port && port <= 65535 then
    ok port ::: ValidPort port
  else
    fail 400 "bad port"
fn listen(port: Int ::: ValidPort port) -> String = "listening on ${port}"
fn start(rawPort: Int) -> String =
  let port = check isValidPort rawPort
  listen port
|}

let test_PF02_proof_required_but_not_present_is_error () =
  (* The compiler must reject calls missing the required proof *)
  should_fail "proof\\|does not.*statically\\|ValidPort\\|IsPositive" {|
#lang tesl
module PF02 exposing []
import Tesl.Prelude exposing [Int, String]
fact ValidPort (port: Int)
fn listen(port: Int ::: ValidPort port) -> String = "listening"
fn badStart(rawPort: Int) -> String = listen rawPort
|}

let test_PF03_proof_passes_through_intermediate_fn () =
  should_pass {|
#lang tesl
module PF03 exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check checkPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "bad"
fn double(n: Int ::: Positive n) -> Int = n * 2
fn quadruple(n: Int ::: Positive n) -> Int = double n + double n
fn test(raw: Int) -> Int =
  let n = check checkPos raw
  quadruple n
|}

let test_PF04_proof_not_transferable_to_different_value () =
  (* Proof on x cannot be used for y — subjects must match *)
  should_fail "proof\\|subject\\|does not.*statically\\|Positive" {|
#lang tesl
module PF04 exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check checkPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "bad"
fn requiresPos(n: Int ::: Positive n) -> Int = n
fn badForge(a: Int, b: Int) -> Int =
  let validA = check checkPos a
  requiresPos b
|}

let test_PF05_proof_in_record_field_accepted () =
  should_pass {|
#lang tesl
module PF05 exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains]
fact ValidEmail (s: String)
check checkEmail(s: String) -> s: String ::: ValidEmail s =
  if String.contains s "@" then
    ok s ::: ValidEmail s
  else
    fail 400 "invalid email"
record UserInput { email: String ::: ValidEmail email }
fn getEmail(u: UserInput) -> String = u.email
|}

(* ── PC — Proof composition ───────────────────────────────────────────────── *)

let test_PC01_conjunction_proof_accepted () =
  should_pass {|
#lang tesl
module PC01 exposing []
import Tesl.Prelude exposing [Int]
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
fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n
fn test(raw: Int) -> Int =
  let pos = check checkPos raw
  let small = check checkSmall pos
  needsBoth small
|}

let test_PC02_missing_half_of_conjunction_rejected () =
  should_fail "proof\\|does not.*statically\\|IsSmall\\|IsPositive.*&&" {|
#lang tesl
module PC02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n
fn test(raw: Int) -> Int =
  let pos = check checkPos raw
  needsBoth pos
|}

let test_PC03_forall_on_list_accepted () =
  should_pass {|
#lang tesl
module PC03 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn countPositive(xs: List Int) -> Int =
  let positives = List.filterCheck checkPos xs
  List.length positives
|}

let test_PC04_detach_and_reattach_accepted () =
  should_pass {|
#lang tesl
module PC04 exposing []
import Tesl.Prelude exposing [Int, Fact, detachFact, attachFact, forgetFact]
fact Validated (n: Int)
check checkVal(n: Int) -> n: Int ::: Validated n =
  if n > 0 then
    ok n ::: Validated n
  else
    fail 400 "bad"
fn roundtrip(n: Int) -> Int =
  let validated = check checkVal n
  let pf = detachFact validated
  let stripped = forgetFact validated
  attachFact stripped pf
|}

let test_PC05_combine_compound_check_function () =
  should_pass {|
#lang tesl
module PC05 exposing []
import Tesl.Prelude exposing [Int]
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
fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n
fn test(raw: Int) -> Int =
  let x = check (checkPos && checkSmall) raw
  needsBoth x
|}

(* ── CP — Capabilities ────────────────────────────────────────────────────── *)

let test_CP01_function_with_undeclared_capability_rejected () =
  (* Claim C: capabilities are explicit and compiler-enforced *)
  should_fail "undeclared capability\\|unknown.*capability\\|not.*declared" {|
#lang tesl
module CP01 exposing []
import Tesl.Prelude exposing [Int]
fn bad() -> Int requires [ghostCapability] = 42
|}

let test_CP02_declared_capability_accepted () =
  should_pass {|
#lang tesl
module CP02 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
fn query() -> Int requires [dbRead] = 42
|}

let test_CP03_calling_fn_without_required_capability_rejected () =
  should_fail "capability\\|requires.*dbWrite\\|missing.*capability" {|
#lang tesl
module CP03 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbWrite]
fn write() -> Int requires [dbWrite] = 42
fn noCapabilityFn() -> Int requires [] = write
|}

let test_CP04_capability_implication_chain_accepted () =
  should_pass {|
#lang tesl
module CP04 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead, dbWrite]
capability readCap implies dbRead
capability writeCap implies dbWrite
fn readsData() -> Int requires [readCap] = 1
fn writesData() -> Int requires [writeCap] = 2
|}

let test_CP05_capability_cycle_rejected () =
  should_fail "cycle\\|circular\\|implies.*cycle" {|
#lang tesl
module CP05 exposing []
capability capA implies capB
capability capB implies capA
|}

(* ── AU — Auth ────────────────────────────────────────────────────────────── *)

let test_AU01_auth_proof_required_in_handler () =
  (* Claim B: auth requirements visible in signatures — mismatch is detected *)
  should_fail "auth.*proof\\|endpoint.*requires.*auth\\|handler.*auth\\|no auth-proof" {|
#lang tesl
module AU01 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
auth myAuth(req: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "token" req.cookies of
    Nothing -> fail 401 "not authenticated"
    Something t -> ok t ::: Authenticated user
api AU01Api {
  get "/whoami"
    auth user : String ::: Authenticated user via myAuth
    -> String
}
handler whoami() -> String requires [] = "who?"
server AU01Server for AU01Api { whoami = whoami }
|}

let test_AU02_auth_proof_in_handler_accepted () =
  should_pass {|
#lang tesl
module AU02 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
auth myAuth(req: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "token" req.cookies of
    Nothing -> fail 401 "not authenticated"
    Something t -> ok t ::: Authenticated user
api AU02Api {
  get "/whoami"
    auth user : String ::: Authenticated user via myAuth
    -> String
}
handler whoami(user: String ::: Authenticated user) -> String requires [] =
  "hello ${user}"
server AU02Server for AU02Api { whoami = whoami }
|}

let test_AU03_auth_without_proof_annotation_in_endpoint_rejected () =
  (* Claim D: auth without proof annotation is a compile error *)
  should_fail "proof annotation\\|auth.*proof\\|::: ProofPred" {|
#lang tesl
module AU03 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
fact Authenticated (user: String)
auth myAuth(req: HttpRequest) -> user: String ::: Authenticated user =
  ok "user" ::: Authenticated user
api AU03Api {
  get "/whoami"
    auth user : String via myAuth
    -> String
}
|}

let test_AU04_public_endpoint_no_auth_accepted () =
  should_pass {|
#lang tesl
module AU04 exposing []
import Tesl.Prelude exposing [String]
api AU04Api { get "/health" -> String }
handler health() -> String requires [] = "ok"
server AU04Server for AU04Api { health = health }
|}

(* ── AP — API + server wiring ─────────────────────────────────────────────── *)

let test_AP01_full_api_server_stack_accepted () =
  should_pass {|
#lang tesl
module AP01 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec]
capture idCapture: id: String using stringCodec
api AP01Api {
  get "/health" -> String
  get "/items/:id"
    capture id : String via idCapture
    -> Int
}
handler health() -> String requires [] = "ok"
handler getItem(id: String) -> Int requires [] = 42
server AP01Server for AP01Api { health = health getItem = getItem }
|}

let test_AP02_server_missing_endpoint_binding_rejected () =
  should_fail "missing.*binding\\|endpoint.*not.*bound\\|missing.*1" {|
#lang tesl
module AP02 exposing []
import Tesl.Prelude exposing [String]
api AP02Api {
  get "/a" -> String
  get "/b" -> String
}
handler aHandler() -> String requires [] = "a"
server AP02Server for AP02Api { aHandler = aHandler }
|}

let test_AP03_endpoint_missing_return_type_rejected () =
  should_fail "missing return type\\|explicit.*TypeName\\|->.*TypeName" {|
#lang tesl
module AP03 exposing []
import Tesl.Prelude exposing [String]
api AP03Api { get "/health" }
|}

let test_AP04_server_binds_non_handler_function_rejected () =
  (* server blocks must point at `handler` declarations, not plain fn *)
  should_fail "not a handler\\|fn.*not.*handler\\|declared.*not.*handler" {|
#lang tesl
module AP04 exposing []
import Tesl.Prelude exposing [String]
api AP04Api { get "/ping" -> String }
fn notAHandler() -> String requires [] = "pong"
server AP04Server for AP04Api { notAHandler = notAHandler }
|}

(* ── SL — Standard library ────────────────────────────────────────────────── *)

let test_SL01_list_operations_accepted () =
  should_pass {|
#lang tesl
module SL01 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.List exposing [List.length, List.head, List.filter]
import Tesl.Maybe exposing [Maybe]
fn countPositive(xs: List Int) -> Int =
  List.length (List.filter (fn(n: Int) -> n > 0) xs)
fn safeHead(xs: List Int) -> Maybe Int = List.head xs
|}

let test_SL02_string_operations_accepted () =
  should_pass {|
#lang tesl
module SL02 exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.String exposing [String.length, String.toUpper, String.contains]
fn validate(s: String) -> Bool =
  String.length s > 3 && String.contains s "@"
fn transform(s: String) -> String = String.toUpper s
|}

let test_SL03_dict_operations_accepted () =
  should_pass {|
#lang tesl
module SL03 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Dict exposing [Dict, Dict.empty, Dict.insert, Dict.lookup]
import Tesl.Maybe exposing [Maybe]
fn buildCache() -> Dict String Int =
  Dict.insert "a" 1 (Dict.insert "b" 2 Dict.empty)
fn safeLookup(key: String, d: Dict String Int) -> Maybe Int =
  Dict.lookup key d
|}

let test_SL04_stdlib_without_import_rejected () =
  (* Claim D: using stdlib without import is a compile error *)
  should_fail "requires.*import Tesl\\.List\\|import Tesl\\.List" {|
#lang tesl
module SL04 exposing []
import Tesl.Prelude exposing [List, Int]
import Tesl.Maybe exposing [Maybe]
fn bad(xs: List Int) -> Maybe Int = List.head xs
|}

(* ── EM — Error message quality ──────────────────────────────────────────── *)

let test_EM01_wrong_type_gives_useful_error () =
  (* A newcomer passing a String where Int expected should get a clear message *)
  should_fail "type.*mismatch\\|expected.*Int\\|got.*String\\|String.*Int" {|
#lang tesl
module EM01 exposing []
import Tesl.Prelude exposing [Int, String]
fn add(a: Int, b: Int) -> Int = a + b
fn bad() -> Int = add "hello" "world"
|}

let test_EM02_unknown_name_gives_useful_error () =
  should_fail "unknown name\\|not.*scope\\|unbound" {|
#lang tesl
module EM02 exposing []
import Tesl.Prelude exposing [Int]
fn bad() -> Int = completelyUndefinedFunction 42
|}

let test_EM03_missing_import_gives_helpful_hint () =
  should_fail "not in scope\\|add it to an import\\|Try: import" {|
#lang tesl
module EM03 exposing []
fn bad(xs: List Int) -> Int = 0
|}

let test_EM04_duplicate_function_definition_clear_error () =
  should_fail "duplicate.*function\\|already.*defined\\|duplicate" {|
#lang tesl
module EM04 exposing []
import Tesl.Prelude exposing [Int]
fn foo() -> Int = 1
fn foo() -> Int = 2
|}

(* ── MS — Module system ──────────────────────────────────────────────────── *)

let test_MS01_exporting_undefined_name_rejected () =
  should_fail "unknown.*non-local\\|module exposes unknown\\|non-local" {|
#lang tesl
module MS01 exposing [doesNotExist]
import Tesl.Prelude exposing [Int]
fn realFn() -> Int = 42
|}

let test_MS02_importing_nonexistent_name_from_stdlib_rejected () =
  should_fail "does not export\\|unknown.*export\\|module.*export" {|
#lang tesl
module MS02 exposing []
import Tesl.List exposing [List.nonExistentFunction]
|}

let test_MS03_using_imported_function_accepted () =
  should_pass {|
#lang tesl
module MS03 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.abs, Int.toString]
import Tesl.String exposing [String.length]
fn describe(n: Int) -> Int =
  String.length (Int.toString (Int.abs n))
|}

let test_MS04_importing_same_module_twice_same_names_rejected () =
  should_fail "duplicate import\\|already imported" {|
#lang tesl
module MS04 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Prelude exposing [Int, String]
fn foo() -> Int = 42
|}

(* ── PT — Pattern matching ────────────────────────────────────────────────── *)

let test_PT01_adt_constructors_in_patterns_accepted () =
  should_pass {|
#lang tesl
module PT01 exposing []
import Tesl.Prelude exposing [Int]
type Shape
  = Circle radius: Int
  | Rectangle width: Int height: Int
fn area(s: Shape) -> Int =
  case s of
    Circle r -> r * r
    Rectangle w h -> w * h
|}

let test_PT02_missing_adt_case_rejected () =
  should_fail "non-exhaustive\\|missing.*Rectangle\\|missing.*constructor" {|
#lang tesl
module PT02 exposing []
import Tesl.Prelude exposing [Int]
type Shape
  = Circle radius: Int
  | Rectangle width: Int height: Int
fn bad(s: Shape) -> Int =
  case s of
    Circle r -> r * r
|}

let test_PT03_unknown_constructor_in_pattern_rejected () =
  should_fail "unknown constructor\\|UnknownShape" {|
#lang tesl
module PT03 exposing []
import Tesl.Prelude exposing [Int]
type Shape = Circle radius: Int
fn bad(s: Shape) -> Int =
  case s of
    Circle r -> r
    UnknownShape -> 0
|}

(* ── MT — Mutation testing claims ────────────────────────────────────────── *)

let test_MT01_check_function_is_mutation_testable () =
  (* Claim F: mutation testing built in — test blocks can test check functions *)
  should_pass {|
#lang tesl
module MT01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "must be positive"
test "positive check accepts 5" {
  let n = 5
  let r = check checkPositive n
  expect r == 5
}
test "positive check accepts 100" {
  let n = 100
  let r = check checkPositive n
  expect r == 100
}
test "positive check rejects zero" {
  let n = 0
  expectFail (check checkPositive n)
}
|}

let test_MT02_mutate_command_accepts_file_with_check () =
  (* Verify --mutate flag accepts a file with check functions (does not crash) *)
  with_temp_file {|
#lang tesl
module MT02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
test "rejects zero" { expectFail checkPos 0 }
test "accepts one" {
  let r = check checkPos 1
  expect r == 1
}
|} (fun path ->
    let code, _ = run_compiler ["--mutate"; path] in
    (* mutate exits 0 (all killed), 1 (survivors), but should not crash *)
    if code > 1 then failf "mutate crashed with exit code %d" code)

let test_MT03_test_block_with_expectFail_accepted () =
  should_pass {|
#lang tesl
module MT03 exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
fact NonEmpty (s: String)
check checkNonEmpty(s: String) -> s: String ::: NonEmpty s =
  if String.length s > 0 then
    ok s ::: NonEmpty s
  else
    fail 400 "empty"
test "rejects empty string" {
  let s = ""
  expectFail (check checkNonEmpty s)
}
test "accepts non-empty" {
  let s = "hello"
  let r = check checkNonEmpty s
  expect r == "hello"
}
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review69-Critical-Language-Validation" [
    "core-types", [
      test_case "CT01 type mismatch is compile error" `Quick test_CT01_type_mismatch_is_compile_error;
      test_case "CT02 correct types compile" `Quick test_CT02_function_with_correct_types_accepted;
      test_case "CT03 wrong argument type rejected" `Quick test_CT03_wrong_argument_type_rejected;
      test_case "CT04 ADT pattern match compiles" `Quick test_CT04_adt_pattern_match_accepted;
      test_case "CT05 missing case arm rejected" `Quick test_CT05_missing_case_arm_rejected;
      test_case "CT06 exhaustive case compiles" `Quick test_CT06_all_case_arms_covered_accepted;
    ];
    "proof-basics", [
      test_case "PR01 check produces proof" `Quick test_PR01_check_produces_proof_accepted;
      test_case "PR02 unvalidated where proof required rejected" `Quick test_PR02_unvalidated_value_where_proof_required_rejected;
      test_case "PR03 check failure path compiles" `Quick test_PR03_check_failure_path_compiles;
      test_case "PR04 undeclared fact predicate rejected" `Quick test_PR04_fact_declaration_required_before_use;
      test_case "PR05 ok without proof rejected" `Quick test_PR05_ok_without_proof_annotation_rejected;
      test_case "PR06 establish unconditional proof" `Quick test_PR06_establish_produces_unconditional_proof;
      test_case "PR07 auth function structure accepted" `Quick test_PR07_auth_function_structure_accepted;
      test_case "PR08 check return type must match" `Quick test_PR08_check_return_type_must_match_binding;
    ];
    "proof-flow", [
      test_case "PF01 proof flows check to consumer" `Quick test_PF01_proof_flows_from_check_to_requiring_fn;
      test_case "PF02 missing proof at call site rejected" `Quick test_PF02_proof_required_but_not_present_is_error;
      test_case "PF03 proof through intermediate function" `Quick test_PF03_proof_passes_through_intermediate_fn;
      test_case "PF04 proof not transferable to different value" `Quick test_PF04_proof_not_transferable_to_different_value;
      test_case "PF05 proof in record field" `Quick test_PF05_proof_in_record_field_accepted;
    ];
    "proof-composition", [
      test_case "PC01 conjunction proof accepted" `Quick test_PC01_conjunction_proof_accepted;
      test_case "PC02 half conjunction missing rejected" `Quick test_PC02_missing_half_of_conjunction_rejected;
      test_case "PC03 ForAll on list accepted" `Quick test_PC03_forall_on_list_accepted;
      test_case "PC04 detach reattach accepted" `Quick test_PC04_detach_and_reattach_accepted;
      test_case "PC05 compound check function" `Quick test_PC05_combine_compound_check_function;
    ];
    "capabilities", [
      test_case "CP01 undeclared capability rejected" `Quick test_CP01_function_with_undeclared_capability_rejected;
      test_case "CP02 declared capability accepted" `Quick test_CP02_declared_capability_accepted;
      test_case "CP03 calling fn without capability rejected" `Quick test_CP03_calling_fn_without_required_capability_rejected;
      test_case "CP04 capability implication chain accepted" `Quick test_CP04_capability_implication_chain_accepted;
      test_case "CP05 capability cycle rejected" `Quick test_CP05_capability_cycle_rejected;
    ];
    "auth", [
      test_case "AU01 auth proof required in handler" `Quick test_AU01_auth_proof_required_in_handler;
      test_case "AU02 auth proof in handler accepted" `Quick test_AU02_auth_proof_in_handler_accepted;
      test_case "AU03 auth without proof annotation rejected" `Quick test_AU03_auth_without_proof_annotation_in_endpoint_rejected;
      test_case "AU04 public endpoint no auth accepted" `Quick test_AU04_public_endpoint_no_auth_accepted;
    ];
    "api-server", [
      test_case "AP01 full api server stack accepted" `Quick test_AP01_full_api_server_stack_accepted;
      test_case "AP02 server missing endpoint rejected" `Quick test_AP02_server_missing_endpoint_binding_rejected;
      test_case "AP03 endpoint missing return type rejected" `Quick test_AP03_endpoint_missing_return_type_rejected;
      test_case "AP04 server fn not handler rejected" `Quick test_AP04_server_binds_non_handler_function_rejected;
    ];
    "standard-library", [
      test_case "SL01 list operations accepted" `Quick test_SL01_list_operations_accepted;
      test_case "SL02 string operations accepted" `Quick test_SL02_string_operations_accepted;
      test_case "SL03 dict operations accepted" `Quick test_SL03_dict_operations_accepted;
      test_case "SL04 stdlib without import rejected" `Quick test_SL04_stdlib_without_import_rejected;
    ];
    "error-messages", [
      test_case "EM01 wrong type useful error" `Quick test_EM01_wrong_type_gives_useful_error;
      test_case "EM02 unknown name useful error" `Quick test_EM02_unknown_name_gives_useful_error;
      test_case "EM03 missing import helpful hint" `Quick test_EM03_missing_import_gives_helpful_hint;
      test_case "EM04 duplicate function clear error" `Quick test_EM04_duplicate_function_definition_clear_error;
    ];
    "module-system", [
      test_case "MS01 exporting undefined name rejected" `Quick test_MS01_exporting_undefined_name_rejected;
      test_case "MS02 importing nonexistent stdlib name rejected" `Quick test_MS02_importing_nonexistent_name_from_stdlib_rejected;
      test_case "MS03 using imported function accepted" `Quick test_MS03_using_imported_function_accepted;
      test_case "MS04 duplicate module import rejected" `Quick test_MS04_importing_same_module_twice_same_names_rejected;
    ];
    "pattern-matching", [
      test_case "PT01 ADT constructors in patterns accepted" `Quick test_PT01_adt_constructors_in_patterns_accepted;
      test_case "PT02 missing ADT case rejected" `Quick test_PT02_missing_adt_case_rejected;
      test_case "PT03 unknown constructor rejected" `Quick test_PT03_unknown_constructor_in_pattern_rejected;
    ];
    "mutation-testing", [
      test_case "MT01 check function with test blocks accepted" `Quick test_MT01_check_function_is_mutation_testable;
      test_case "MT02 mutate command accepts check file" `Quick test_MT02_mutate_command_accepts_file_with_check;
      test_case "MT03 test block with expectFail accepted" `Quick test_MT03_test_block_with_expectFail_accepted;
    ];
  ]
