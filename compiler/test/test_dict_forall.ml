(** Tests for ForAllValues and ForAllKeys Dict proof quantifiers.

    Covers the new `Dict K V ::: ForAllValues P` and `Dict K V ::: ForAllKeys P`
    return specifications, the `Dict.filterCheckValues` and `Dict.filterCheckKeys`
    stdlib functions, and their compile-time proof validation. *)

open Alcotest

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some v -> v
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    if Sys.file_exists candidate then candidate else "tesl"

let check_subcmd =
  if Filename.basename tesl = "main.exe" then "--check" else "check"

let compile_string src =
  let tmp = Filename.temp_file "tesl-dict-forall-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let should_pass src =
  let out = compile_string src in
  let has_error =
    let re = Str.regexp "error\\[" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if has_error then
    Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false has_error

let should_fail pattern src =
  let out = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true found

(* ── Preludes ──────────────────────────────────────────────────────────────── *)

(* fn functions with ForAllValues use Dict.filterCheckValues directly —
   no `ok ... :::` annotation needed in fn bodies (ForAll is compile-time only). *)

let auth_prelude =
  "#lang tesl\nmodule T exposing []\n" ^
  "import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit]\n" ^
  "import Tesl.Dict exposing [Dict, Dict.filterCheckValues, Dict.filterCheckKeys]\n" ^
  "fact IsAuthenticated (u: String)\n" ^
  "check checkIsAuthenticated(u: String) -> u: String ::: IsAuthenticated u =\n" ^
  "  if String.length u > 0 then\n" ^
  "    ok u ::: IsAuthenticated u\n" ^
  "  else\n" ^
  "    fail 401 \"not authenticated\"\n"

let email_prelude =
  "#lang tesl\nmodule T exposing []\n" ^
  "import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit]\n" ^
  "import Tesl.Dict exposing [Dict, Dict.filterCheckValues, Dict.filterCheckKeys]\n" ^
  "fact IsValidEmail (e: String)\n" ^
  "check checkIsValidEmail(e: String) -> e: String ::: IsValidEmail e =\n" ^
  "  if String.length e > 3 then\n" ^
  "    ok e ::: IsValidEmail e\n" ^
  "  else\n" ^
  "    fail 400 \"invalid email\"\n"

(* ── Test 1: ForAllValues passing case (fn function) ────────────────────── *)

let test_forall_values_pass () =
  (* fn functions with ForAll return types call the filter function and return
     the result directly — no `ok ... :::` annotation is needed. *)
  let src = auth_prelude ^
    "fn getVerifiedCache(raw: Dict String String) -> Dict String String ::: ForAllValues IsAuthenticated requires [] =\n" ^
    "  let checked = Dict.filterCheckValues checkIsAuthenticated raw\n" ^
    "  checked\n"
  in
  should_pass src

(* ── Test 2: ForAllValues with direct return (no let binding) ────────────── *)

let test_forall_values_direct_return () =
  let src = auth_prelude ^
    "fn getVerifiedCache(raw: Dict String String) -> Dict String String ::: ForAllValues IsAuthenticated requires [] =\n" ^
    "  Dict.filterCheckValues checkIsAuthenticated raw\n"
  in
  should_pass src

(* ── Test 3: ForAllValues on a non-Dict type (parse error) ──────────────── *)

let test_forall_values_non_dict () =
  let src =
    "#lang tesl\nmodule T exposing []\n" ^
    "import Tesl.Prelude exposing [Int, String, List]\n" ^
    "fact IsPositive (n: Int)\n" ^
    "fn getPositives() -> List Int ::: ForAllValues IsPositive requires [] =\n" ^
    "  List.singleton 1\n"
  in
  should_fail "ForAllValues.*Dict\\|only valid.*Dict\\|Dict.*ForAllValues" src

(* ── Test 4: ForAllKeys on a non-Dict type (parse error) ─────────────────── *)

let test_forall_keys_non_dict () =
  let src =
    "#lang tesl\nmodule T exposing []\n" ^
    "import Tesl.Prelude exposing [Int, String, List]\n" ^
    "fact IsValidId (n: Int)\n" ^
    "fn getValidIds() -> List Int ::: ForAllKeys IsValidId requires [] =\n" ^
    "  List.singleton 1\n"
  in
  should_fail "ForAllKeys.*Dict\\|only valid.*Dict\\|Dict.*ForAllKeys" src

(* ── Test 5: Missing Dict.filterCheckValues (bare dict returned) ────────── *)

let test_forall_values_no_filter () =
  (* The ForAll consistency checker should detect that raw has no tracked ForAll proof *)
  let src = auth_prelude ^
    "fn getVerifiedCache(raw: Dict String String) -> Dict String String ::: ForAllValues IsAuthenticated requires [] =\n" ^
    "  raw\n"
  in
  should_fail "ForAll\\|no tracked\\|proof\\|IsAuthenticated" src

(* ── Test 6: ForAllKeys passing case (fn function) ──────────────────────── *)

let test_forall_keys_pass () =
  let src = email_prelude ^
    "fn getByValidKeys(raw: Dict String Int) -> Dict String Int ::: ForAllKeys IsValidEmail requires [] =\n" ^
    "  let checked = Dict.filterCheckKeys checkIsValidEmail raw\n" ^
    "  checked\n"
  in
  should_pass src

(* ── Test 7: ForAllKeys direct return (no let binding) ───────────────────── *)

let test_forall_keys_direct_return () =
  let src = email_prelude ^
    "fn getByValidKeys(raw: Dict String Int) -> Dict String Int ::: ForAllKeys IsValidEmail requires [] =\n" ^
    "  Dict.filterCheckKeys checkIsValidEmail raw\n"
  in
  should_pass src

(* ── Test 8: Wrong check function (produces different predicate) ─────────── *)

let test_forall_values_wrong_check_fn () =
  (* Using checkIsValidEmail (produces IsValidEmail) for a ForAllValues IsAuthenticated return *)
  let src = auth_prelude ^
    "fact IsValidEmail (e: String)\n" ^
    "check checkIsValidEmail(e: String) -> e: String ::: IsValidEmail e =\n" ^
    "  ok e ::: IsValidEmail e\n" ^
    "fn getVerifiedCache(raw: Dict String String) -> Dict String String ::: ForAllValues IsAuthenticated requires [] =\n" ^
    "  Dict.filterCheckValues checkIsValidEmail raw\n"
  in
  should_fail "IsAuthenticated\\|IsValidEmail\\|missing\\|produces" src

(* ── Test suite ──────────────────────────────────────────────────────────── *)

let () =
  run "Dict ForAll quantifiers" [
    "ForAllValues", [
      test_case "pass: fn with let binding + filterCheckValues" `Quick test_forall_values_pass;
      test_case "pass: fn with direct filterCheckValues return" `Quick test_forall_values_direct_return;
      test_case "fail: ForAllValues on List type (parse error)" `Quick test_forall_values_non_dict;
      test_case "fail: no filterCheckValues call (bare dict)" `Quick test_forall_values_no_filter;
      test_case "fail: wrong check function (mismatched predicate)" `Quick test_forall_values_wrong_check_fn;
    ];
    "ForAllKeys", [
      test_case "pass: fn with let binding + filterCheckKeys" `Quick test_forall_keys_pass;
      test_case "pass: fn with direct filterCheckKeys return" `Quick test_forall_keys_direct_return;
      test_case "fail: ForAllKeys on List type (parse error)" `Quick test_forall_keys_non_dict;
    ];
  ]
