(** test_check_binding_gap.ml — the let-RHS half of the "an unwrapped check
    result must not escape" rule (roadmap/next/check_binding_gap.md).

    A check-shaped callee (`JWT.verify`, `Float.requireNonZero`,
    `Units.requireNonZero`, a user `check` function, …) returns a check RESULT:
    the payload on success, a `check-fail` struct on failure.  Only `check`
    unwraps it and propagates the failure as a status.  Two positions already
    refused to let the raw wrapper escape — a bare call statement, and a nested
    argument position — and the third, the plain `let` binding, did not:

        let claims = JWT.verify token key      (* compiled; wrong on the 401 path *)

    which misbehaves ONLY on the error path, exactly the shape a test suite
    that feeds valid input never sees.  These tests pin the rule that closes it,
    and — just as importantly — the legitimate shapes it must NOT reject: a
    partial application (which hands over a check FUNCTION, not a result), a
    bare reference as `check`'s own head, and the `check`ed binding itself.

    The `Units.requireNonZero` cases are here for a second reason: closing the
    gap required `check` to work on the dimension ops at all.  Before this,
    `check Units.requireNonZero t` collapsed the quantity to a bare Float, so
    lesson72 taught the un-`check`ed direct call as the only spelling — i.e. the
    language documented the very shape this rule refuses.  The rule and the
    dimension-preserving `check` land together, so the tests do too. *)

let root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name else find parent
    in
    find (Filename.dirname Sys.executable_name)

let contains needle haystack =
  let n = String.length needle and m = String.length haystack in
  if n > m then false
  else begin
    let found = ref false in
    for i = 0 to m - n do
      if String.sub haystack i n = needle then found := true
    done;
    !found
  end

let errors_of src =
  List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
    (Compile.check_source "<test>" src)

let compile_ok name src =
  match Compile.compile_source ~root_path:root "<test>" src with
  | Compile.Success racket -> racket
  | Compile.Failure diags ->
    Alcotest.failf "%s: unexpected compile failure:\n%s" name
      (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diags))

(* The rule's own diagnostic, isolated from any other error in the module. *)
let binding_errors src =
  List.filter (fun (d : Compile.diagnostic) ->
      contains "must be bound with `check`" d.message)
    (errors_of src)

let expect_binding_error name src ~callee =
  match binding_errors src with
  | [] ->
    Alcotest.failf "%s: expected the check-binding error naming `%s`, got:\n%s"
      name callee
      (String.concat "\n"
         (List.map (fun (d : Compile.diagnostic) -> d.message) (errors_of src)))
  | [ d ] ->
    if not (contains callee d.message) then
      Alcotest.failf "%s: the error must name `%s`, got:\n%s" name callee d.message;
    d
  | many ->
    (* One binding, one diagnostic: the rule runs from several checker arms and
       a duplicate would mean the same `let` is judged twice. *)
    Alcotest.failf "%s: expected exactly 1 check-binding error, got %d:\n%s" name
      (List.length many)
      (String.concat "\n"
         (List.map (fun (d : Compile.diagnostic) -> d.message) many))

let expect_no_binding_error name src =
  match binding_errors src with
  | [] -> ()
  | ds ->
    Alcotest.failf "%s: the check-binding rule must not fire here, got:\n%s" name
      (String.concat "\n"
         (List.map (fun (d : Compile.diagnostic) -> d.message) ds))

(* ── Module skeletons ────────────────────────────────────────────────────── *)

let jwt_module body =
  Printf.sprintf
    "module M exposing [f]\n\
     import Tesl.Prelude exposing [String, Bool]\n\
     import Tesl.Dict exposing [Dict]\n\
     import Tesl.Crypto exposing [Secret]\n\
     import Tesl.JWT exposing [jwt, JwtToken, JWT.verify, Authentic]\n\
     \n\
     fn key() -> Secret =\n\
     \  Secret \"compiler-test-key\"\n\
     %s"
    body

let units_module body =
  Printf.sprintf
    "module M exposing [pace]\n\
     import Tesl.Units exposing [Length, Duration, Speed, Length.meters, \
     Duration.seconds, Speed.inMetersPerSecond, Units.requireNonZero]\n\
     %s"
    body

let float_module body =
  Printf.sprintf
    "module M exposing [recip]\n\
     import Tesl.Float exposing [Float, Float.div, Float.requireNonZero]\n\
     %s"
    body

(* ── 1. The gap itself ───────────────────────────────────────────────────── *)

let test_plain_let_jwt_verify_is_refused () =
  let src =
    jwt_module
      {|
fn f(token: JwtToken) -> Bool requires [jwt] =
  let claims = JWT.verify token (key())
  True
|}
  in
  let d = expect_binding_error "plain_let_jwt_verify" src ~callee:"JWT.verify" in
  (* The message has to say what to write instead — the whole point is that the
     reader cannot see the failure path in the type. *)
  if not (contains "check JWT.verify" d.message) then
    Alcotest.failf "the error must show the `check` spelling, got:\n%s" d.message

let test_plain_let_float_require_non_zero_is_refused () =
  let src =
    float_module
      {|
fn recip(x: Float) -> Float =
  let nz = Float.requireNonZero x
  Float.div 1.0 nz
|}
  in
  ignore (expect_binding_error "plain_let_float_require_non_zero" src
            ~callee:"Float.requireNonZero")

let test_plain_let_units_require_non_zero_is_refused () =
  let src =
    units_module
      {|
fn pace(d: Length, t: Duration) -> Speed =
  let safe = Units.requireNonZero t
  d / safe
|}
  in
  ignore (expect_binding_error "plain_let_units_require_non_zero" src
            ~callee:"Units.requireNonZero")

(* A user-declared `check` function is check-shaped by KIND, not by spelling,
   so the rule covers it without a registry entry. *)
let check_fn_module body =
  Printf.sprintf
    "module M exposing [f]\n\
     import Tesl.Prelude exposing [Int, Bool(..), List]\n\
     import Tesl.List exposing [List.length, List.filterCheck]\n\
     \n\
     fact IsPositive (n: Int)\n\
     fact InBounds (lo: Int) (hi: Int) (n: Int)\n\
     \n\
     check checkPositive(n: Int) -> n: Int ::: IsPositive n =\n\
    \  if n > 0 then\n\
    \    ok n ::: IsPositive n\n\
    \  else\n\
    \    fail 400 \"not positive\"\n\
     \n\
     check checkInBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =\n\
    \  if lo <= n && n <= hi then\n\
    \    ok n ::: InBounds lo hi n\n\
    \  else\n\
    \    fail 400 \"out of bounds\"\n\
     %s"
    body

let test_plain_let_user_check_fn_is_refused () =
  let src =
    check_fn_module
      {|
fn f(n: Int) -> Int =
  let p = checkPositive n
  p
|}
  in
  ignore (expect_binding_error "plain_let_user_check_fn" src ~callee:"checkPositive")

(* `let _ = <check call>` discards the result outright — the same escape with no
   name attached, and the same refusal. *)
let test_discarded_check_result_is_refused () =
  let src =
    jwt_module
      {|
fn f(token: JwtToken) -> Bool requires [jwt] =
  let _ = JWT.verify token (key())
  True
|}
  in
  ignore (expect_binding_error "discarded_check_result" src ~callee:"JWT.verify")

(* The proof-decompose binding is the same escape with a proof pulled off the
   side — and without `check` that proof describes a value that is a check-fail
   on the failure path, which is worse than the plain `let`, not better. *)
let test_proof_decompose_binding_is_refused () =
  let src =
    jwt_module
      {|
fn f(token: JwtToken) -> Bool requires [jwt] =
  let (claims ::: p) = JWT.verify token (key())
  True
|}
  in
  let d = expect_binding_error "proof_decompose_binding" src ~callee:"JWT.verify" in
  (* the suggested spelling has to be the proof-decompose one, not `let x = …` *)
  if not (contains "let (claims ::: p) = check JWT.verify" d.message) then
    Alcotest.failf "the error must suggest the proof-decompose spelling, got:\n%s"
      d.message

(* ── 2. What must keep compiling ─────────────────────────────────────────── *)

let test_checked_binding_compiles () =
  let src =
    jwt_module
      {|
fn f(token: JwtToken) -> Bool requires [jwt] =
  let claims = check JWT.verify token (key())
  True
|}
  in
  expect_no_binding_error "checked_binding" src;
  ignore (compile_ok "checked_binding" src)

(* A partial application hands over a check FUNCTION, which is the entire point
   of filterCheck/allCheck.  The rule fires on SATURATING calls only, so this
   must be untouched. *)
(* The line the rule has to draw: `Dict.requireKey` is check-shaped and takes
   two arguments, so ONE argument is a partial application — a check FUNCTION,
   which no `check` can or should unwrap — while two is a call whose result must
   be `check`ed.  Both halves in one module, so the boundary is pinned by a
   compile rather than by reading [check_shaped_arity]. *)
let test_partial_application_is_not_a_call () =
  let src =
    "module M exposing [f, g]\n\
     import Tesl.Prelude exposing [String, Int]\n\
     import Tesl.Dict exposing [Dict, Dict.requireKey, Dict.size]\n\
     \n\
     fn f(d: Dict String String) -> Int =\n\
    \  let needSub = Dict.requireKey \"sub\"\n\
    \  Dict.size (needSub d)\n\
     \n\
     fn g(d: Dict String String) -> Int =\n\
    \  let checked = check Dict.requireKey \"sub\" d\n\
    \  Dict.size checked\n"
  in
  expect_no_binding_error "partial_application" src;
  ignore (compile_ok "partial_application" src)

let test_saturating_call_of_the_same_callee_is_refused () =
  let src =
    "module M exposing [g]\n\
     import Tesl.Prelude exposing [String, Int]\n\
     import Tesl.Dict exposing [Dict, Dict.requireKey, Dict.size]\n\
     \n\
     fn g(d: Dict String String) -> Int =\n\
    \  let checked = Dict.requireKey \"sub\" d\n\
    \  Dict.size checked\n"
  in
  ignore (expect_binding_error "saturating_call" src ~callee:"Dict.requireKey")

(* A partial application of a USER check function is refused too — but by the
   older "must be called with the `check` keyword" rule, not this one.  What
   matters here is that the let-RHS rule stays out of it: it must not add a
   second, differently-worded error to a shape another rule already owns. *)
let test_user_check_fn_partial_is_not_this_rules_business () =
  let src =
    check_fn_module
      {|
fn f(xs: List Int) -> Int =
  let pxs = List.filterCheck (checkInBounds 0 100) xs
  List.length pxs
|}
  in
  expect_no_binding_error "user_check_fn_partial" src

(* A bare reference is a check FUNCTION too — `check f a b` hands `f` over as a
   head, and filterCheck takes it the same way. *)
let test_bare_reference_is_not_a_call () =
  let src =
    check_fn_module
      {|
fn f(xs: List Int) -> Int =
  let pxs = List.filterCheck checkPositive xs
  List.length pxs
|}
  in
  expect_no_binding_error "bare_reference" src;
  ignore (compile_ok "bare_reference" src)

(* The `check` form on a user check function — the accepted spelling. *)
let test_checked_user_check_fn_compiles () =
  let src =
    check_fn_module
      {|
fn f(n: Int) -> Int =
  let p = check checkPositive n
  p
|}
  in
  expect_no_binding_error "checked_user_check_fn" src;
  ignore (compile_ok "checked_user_check_fn" src)

(* ── 3. `check` preserves the dimension of a quantity ────────────────────── *)

(* The enabling half: `check Units.requireNonZero t` must yield a Duration, not
   a bare Float, or the refusal above would have no legal spelling to point at. *)
let test_checked_units_require_non_zero_keeps_the_dimension () =
  let src =
    units_module
      {|
fn pace(d: Length, t: Duration) -> Speed =
  let safe = check Units.requireNonZero t
  d / safe
|}
  in
  expect_no_binding_error "checked_units_require_non_zero" src;
  let racket = compile_ok "checked_units_require_non_zero" src in
  if not (contains "Units.requireNonZero" racket) then
    Alcotest.failf "the checked call must reach the emitted Racket:\n%s" racket

(* And the dimension is really CHECKED, not merely passed through: dividing a
   Length by a checked Duration is a Speed, so annotating it Length still fails. *)
let test_checked_units_dimension_is_still_verified () =
  let src =
    units_module
      {|
fn pace(d: Length, t: Duration) -> Length =
  let safe = check Units.requireNonZero t
  d / safe
|}
  in
  let msgs =
    String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) (errors_of src))
  in
  if not (contains "Speed" msgs && contains "Length" msgs) then
    Alcotest.failf
      "expected a dimension mismatch naming Speed and Length, got:\n%s" msgs

(* ── 4. The fix ──────────────────────────────────────────────────────────── *)

(* The diagnostic ships the `check` insertion as a machine-applicable edit, and
   applying it produces exactly the accepted form.  (test_fix_apply.ml drives
   the full apply → recompile → converge loop; this pins the edit's shape.) *)
let test_fix_inserts_check_at_the_callee () =
  let source =
    jwt_module
      {|
fn f(token: JwtToken) -> Bool requires [jwt] =
  let claims = JWT.verify token (key())
  True
|}
  in
  let d = expect_binding_error "fix_inserts_check" source ~callee:"JWT.verify" in
  match d.fix with
  | None -> Alcotest.fail "the check-binding diagnostic must ship a fix"
  | Some fix ->
    let fixed = Diag_fix.apply source fix in
    if not (contains "let claims = check JWT.verify token (key())" fixed) then
      Alcotest.failf "the fix must insert `check` before the callee, got:\n%s" fixed;
    expect_no_binding_error "fix_inserts_check (applied)" fixed

(* Fail-closed: no source snapshot, no fix — never a fix aimed at text the
   compiler could not confirm. *)
let test_no_source_snapshot_no_fix () =
  let source =
    jwt_module
      {|
fn f(token: JwtToken) -> Bool requires [jwt] =
  let claims = JWT.verify token (key())
  True
|}
  in
  let m =
    match Parser.parse_module "<test>" source with
    | Ok m -> m
    | Err e -> Alcotest.failf "parse failed: %s" e.Parser.msg
  in
  (* check_module_with_metadata without ~source_lines = the LSP/hover path that
     has no snapshot. *)
  let (_, _, _, _, _, _, errs) = Checker.check_module_with_metadata m in
  let ours =
    List.filter (fun (e : Type_system.type_error) ->
        contains "must be bound with `check`" e.message) errs
  in
  (match ours with
   | [] -> Alcotest.fail "expected the check-binding error even without a snapshot"
   | e :: _ ->
     if e.fix <> None then
       Alcotest.fail "no source snapshot must mean no fix (fail-closed)")

let () =
  Alcotest.run "check-binding gap"
    [
      ( "refusals",
        [
          Alcotest.test_case "plain let JWT.verify" `Quick
            test_plain_let_jwt_verify_is_refused;
          Alcotest.test_case "plain let Float.requireNonZero" `Quick
            test_plain_let_float_require_non_zero_is_refused;
          Alcotest.test_case "plain let Units.requireNonZero" `Quick
            test_plain_let_units_require_non_zero_is_refused;
          Alcotest.test_case "plain let user check fn" `Quick
            test_plain_let_user_check_fn_is_refused;
          Alcotest.test_case "discarded check result" `Quick
            test_discarded_check_result_is_refused;
          Alcotest.test_case "proof-decompose binding" `Quick
            test_proof_decompose_binding_is_refused;
        ] );
      ( "no false positives",
        [
          Alcotest.test_case "checked binding compiles" `Quick
            test_checked_binding_compiles;
          Alcotest.test_case "partial application" `Quick
            test_partial_application_is_not_a_call;
          Alcotest.test_case "saturating call of the same callee" `Quick
            test_saturating_call_of_the_same_callee_is_refused;
          Alcotest.test_case "user check fn partial" `Quick
            test_user_check_fn_partial_is_not_this_rules_business;
          Alcotest.test_case "bare reference" `Quick
            test_bare_reference_is_not_a_call;
          Alcotest.test_case "checked user check fn" `Quick
            test_checked_user_check_fn_compiles;
        ] );
      ( "checked quantities",
        [
          Alcotest.test_case "check keeps the dimension" `Quick
            test_checked_units_require_non_zero_keeps_the_dimension;
          Alcotest.test_case "dimension still verified" `Quick
            test_checked_units_dimension_is_still_verified;
        ] );
      ( "fix",
        [
          Alcotest.test_case "inserts check at the callee" `Quick
            test_fix_inserts_check_at_the_callee;
          Alcotest.test_case "no snapshot, no fix" `Quick
            test_no_source_snapshot_no_fix;
        ] );
    ]
