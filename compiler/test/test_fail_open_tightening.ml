(** Three fail-open holes in [Checker], closed together because they are one
    class: a permissive branch typed something as ANYTHING instead of rejecting
    it, so the program compiled and then failed — or, worse, quietly misbehaved —
    at runtime.

    1. FIELD ACCESS ON A STDLIB NOMINAL TYPE.  The old `is_known_opaque` decided
       whether an unresolved stdlib TCon got a fixed field set or the permissive
       `fresh ()` fallback, and the fallback typed EVERY field as anything:
       `x.value` compiled on an `Int32`, a `Money`, a `PosixMillis` — and so did
       `x.nonsense`.  None of them exists at runtime (a Money is a struct, an
       Int32 is a bare integer), so the compile-time acceptance was pure
       fail-open.  These types now have a field set of EXACTLY NOTHING, with a
       diagnostic that names the real accessor.

       1b. The same list held the JWT signing-key type WITH `"value"` permitted.
       A key is a secret newtype at runtime — redacted in telemetry, in structured
       logs and on all three debugger surfaces — so `.value` defeated every one of
       those in a single call and the type was not actually secret.  `JwtToken`
       KEEPS `.value`: handing a token to a client is the point of having one.
       That asymmetry is the design, so both halves are pinned here.  (The key
       type was a JWT-only newtype until 2026-07-30; it was deleted and the JWT
       surface now takes Tesl.Crypto's `Secret`, so the pins below are stated over
       `Secret`.)

    2. `Money n` TYPECHECKED AS `String`.  `known_qualifier_modules` doubled as
       the escape hatch for a BARE application of a qualifier name, and it holds
       names (`Money`, `Currency`, `ExchangeRate`, `MoneyRate`) that are not
       constructors of anything.  The bare application resolved to a fresh type
       variable, i.e. to anything at all.

    3. A CHECK-SHAPED CALL IN A NESTED ARGUMENT POSITION.  A check-shaped
       function returns `check-ok`/`check-fail`, and only `check` (which lowers
       to `let/check`) unwraps it and propagates the failure.  Nested straight
       into another call, the FAILURE value — a `check-fail` struct — becomes
       that call's argument: `Dict.lookup "sub" (JWT.verify t s)` looks a key up
       in a struct.  It typechecked and then misbehaved at runtime on the ERROR
       PATH ONLY, which is why the shape sat latent in `lesson57-jwt.tesl` while
       every test passed a valid token.

    WHY EACH ITEM HAS A POSITIVE TEST TOO.  All three fixes are SUBTRACTION, and
    subtraction is satisfied by rejecting everything.  Each negative below is
    paired with the legitimate program beside it — `token.value`, `Money.usd`,
    `let x = check f a` — so the rule cannot be loosened back by widening a list,
    nor "fixed" by deleting itself the next time it flags something. *)

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

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

(* The module NAME must match the file name (V001), so every probe is `Probe`. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-failopen" "" in
  let path = Filename.concat dir "Probe.tesl" in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains needle haystack =
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re haystack 0); true with Not_found -> false

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then
      failf "expected clean compile, got (exit %d):\n%s\n--- source ---\n%s" code out src)

(* Reject, with a STABLE error code and a message that names the reason.  The
   substring assertion is the half that usually goes missing: for every one of
   these the useful content of the diagnostic IS the accessor (or the binding
   form) it points at, and a rejection that only says "no such field" leaves the
   author with a type that looks broken rather than opaque. *)
let should_fail ~code:code_expected ~saying src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then
      failf "expected error[%s], but the program compiled clean:\n%s" code_expected src;
    if not (contains ("error[" ^ code_expected ^ "]") out) then
      failf "expected error[%s], got:\n%s" code_expected out;
    List.iter (fun phrase ->
      if not (contains phrase out) then
        failf "expected the diagnostic to say %S, got:\n%s" phrase out) saying)

(* ── Program shapes ───────────────────────────────────────────────────────── *)

let prog ~exposing ~imports body =
  Printf.sprintf
    "module Probe exposing [%s]\n\
     import Tesl.Prelude exposing [Bool, Int, String]\n\
     %s\n\
     \n\
     %s\n"
    exposing imports body

(* ══════════════════════════════════════════════════════════════════════════ *)
(*  1. Field access on a stdlib nominal type: the field set is NOTHING         *)
(* ══════════════════════════════════════════════════════════════════════════ *)

let int32_imports = "import Tesl.Int32"
let money_imports = "import Tesl.Money\nimport Tesl.Float exposing [Float]"
let time_imports  = "import Tesl.Time"

let t_int32_value_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`Int32` has no field `value`"; "Int32.toInt" ]
    (prog ~exposing:"f" ~imports:int32_imports
       "fn f(x: Int32) -> Int =\n  x.value")

(** The other half of the SAME hole, and the one that proves the fallback was
    typing anything at all: a field nobody ever claimed exists. *)
let t_int32_arbitrary_field_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`Int32` has no field `nonsense`" ]
    (prog ~exposing:"f" ~imports:int32_imports
       "fn f(x: Int32) -> Int =\n  x.nonsense")

let t_money_value_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`Money` has no field `value`"; "Money.minorUnits" ]
    (prog ~exposing:"f" ~imports:money_imports
       "fn f(m: Money) -> Int =\n  m.value")

let t_currency_value_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`Currency` has no field `value`"; "Currency.code" ]
    (prog ~exposing:"f" ~imports:money_imports
       "fn f(c: Currency) -> String =\n  c.value")

let t_exchange_rate_value_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`ExchangeRate` has no field `value`"; "ExchangeRate.rate" ]
    (prog ~exposing:"f" ~imports:money_imports
       "fn f(r: ExchangeRate) -> Float =\n  r.value")

let t_posix_millis_value_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`PosixMillis` has no field `value`"; "Time.posixToSeconds" ]
    (prog ~exposing:"f" ~imports:time_imports
       "fn f(t: PosixMillis) -> Int =\n  t.value")

let t_timezone_value_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`TimeZone` has no field `value`"; "Time.offsetAt" ]
    (prog ~exposing:"f" ~imports:time_imports
       "fn f(z: TimeZone) -> String =\n  z.value")

(** First-Class Units: the canonical TCon of a rate is `§MR[...]`, so this
    cannot be matched by spelling and the raw name must never reach the
    diagnostic — the message has to say `MoneyPerDuration`. *)
let t_money_rate_value_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`MoneyPerDuration` has no field `value`"; "MoneyRate.display" ]
    (prog ~exposing:"f" ~imports:money_imports
       "fn f(r: MoneyPerDuration) -> Int =\n  r.value")

(** Same for a quantity (`§Q[...]`), whose diagnostic must name a real accessor
    for ITS dimension rather than a generic one. *)
let t_quantity_value_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`Length` has no field `value`"; "Length.inMeters" ]
    (prog ~exposing:"f" ~imports:"import Tesl.Units exposing [Length]"
       "fn f(l: Length) -> Int =\n  l.value")

(* ── the positives: the real accessors, and .value where it belongs ───────── *)

let t_int32_accessor_still_works () =
  should_pass
    (prog ~exposing:"f"
       ~imports:"import Tesl.Int32 exposing [Int32, Int32.toInt, Int32.toString]"
       "fn f(x: Int32) -> Int =\n  Int32.toInt x")

let t_money_accessors_still_work () =
  should_pass
    (prog ~exposing:"amount, code"
       ~imports:"import Tesl.Money exposing [Money, Currency, Money.minorUnits, \
                 Money.currency, Currency.code]"
       "fn amount(m: Money) -> Int =\n\
       \  Money.minorUnits m\n\
        \n\
        fn code(m: Money) -> String =\n\
       \  Currency.code (Money.currency m)")

let t_posix_millis_accessor_still_works () =
  should_pass
    (prog ~exposing:"f"
       ~imports:"import Tesl.Time exposing [PosixMillis, Time.posixToSeconds]"
       "fn f(t: PosixMillis) -> Int =\n  Time.posixToSeconds t")

let t_quantity_accessor_still_works () =
  should_pass
    (prog ~exposing:"f"
       ~imports:"import Tesl.Float exposing [Float]\n\
                 import Tesl.Units exposing [Length, Length.inMeters]"
       "fn f(l: Length) -> Float =\n  Length.inMeters l")

(** The CONTRAST that makes the whole tier meaningful: a user-declared newtype
    still has `.value`.  Without this, "reject `.value` everywhere" would pass. *)
let t_user_newtype_keeps_value () =
  should_pass
    (prog ~exposing:"Score, f" ~imports:""
       "type Score = Int\n\
        \n\
        fn f(s: Score) -> Int =\n\
       \  s.value")

(** The OTHER opaque tier — a fixed special-field set — must be untouched in
    both directions, or the generalisation collapsed two tiers into one. *)
let t_http_request_special_fields_still_work () =
  should_pass
    (prog ~exposing:"f"
       ~imports:"import Tesl.Http exposing [HttpRequest]\n\
                 import Tesl.Dict exposing [Dict.lookup]\n\
                 import Tesl.Maybe exposing [Maybe(..)]"
       "fn f(req: HttpRequest) -> String =\n\
       \  case Dict.lookup \"host\" req.headers of\n\
       \    Nothing -> \"\"\n\
       \    Something h -> h")

let t_http_request_unknown_field_still_rejected () =
  should_fail ~code:"T001" ~saying:[ "has no field `bogusField`" ]
    (prog ~exposing:"f" ~imports:"import Tesl.Http exposing [HttpRequest]"
       "fn f(req: HttpRequest) -> String =\n  req.bogusField")

(* ══════════════════════════════════════════════════════════════════════════ *)
(*  1b. Secret loses `.value`; JwtToken keeps it                               *)
(*                                                                             *)
(*  There used to be a SECOND, JWT-only key type carrying the same rule.  It    *)
(*  was deleted (not aliased) on 2026-07-30 and `JWT.sign`/`JWT.verify` now     *)
(*  take Tesl.Crypto's `Secret`, so the asymmetry is stated once, here, over    *)
(*  the one key type there is.                                                  *)
(* ══════════════════════════════════════════════════════════════════════════ *)

let jwt_imports =
  "import Tesl.JWT exposing [jwt, JwtToken, JWT.sign, JWT.verify]\n\
   import Tesl.Crypto exposing [Secret]\n\
   import Tesl.Dict exposing [Dict.singleton, Dict.lookup]\n\
   import Tesl.Maybe exposing [Maybe(..)]"

let t_jwt_secret_value_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "`Secret` has no field `value`"; "redacted"; "JWT.sign" ]
    (prog ~exposing:"f" ~imports:jwt_imports
       "fn f(s: Secret) -> String =\n  s.value")

(** The asymmetry IS the feature: a token is handed to clients on purpose
    (`AuthResponse { token: token.value }` in example/user-service-api.tesl), so
    withholding `.value` from the secret must not withhold it from the token. *)
let t_jwt_token_value_still_works () =
  should_pass
    (prog ~exposing:"f" ~imports:jwt_imports
       "fn f(t: JwtToken) -> String =\n  t.value")

(** And the secret is still USABLE without an eliminator — the point of the
    subtraction is that a Secret goes to JWT.sign, not to a String. *)
let t_jwt_secret_still_signs () =
  (* `JWT.sign` charges `time` on top of `jwt` (it stamps `exp` from the wall
     clock), so the probe's capability implies both — the point being asserted is
     the SECRET's usability, not the capability set. *)
  should_pass
    (prog ~exposing:"signCap, f"
       ~imports:(jwt_imports ^ "\nimport Tesl.Time exposing [time]")
       "capability signCap implies jwt, time\n\
        \n\
        fn f(userId: String, secret: Secret) -> JwtToken requires [signCap] =\n\
       \  JWT.sign (Dict.singleton \"sub\" userId) secret")

(* ══════════════════════════════════════════════════════════════════════════ *)
(*  2. A bare application of a qualifier-only name is T001, not `anything`     *)
(* ══════════════════════════════════════════════════════════════════════════ *)

let t_bare_money_rejected () =
  should_fail ~code:"T001" ~saying:[ "unknown constructor"; "Money" ]
    (prog ~exposing:"bad" ~imports:money_imports
       "fn bad(n: Int) -> String =\n  Money n")

let t_bare_currency_rejected () =
  should_fail ~code:"T001" ~saying:[ "unknown constructor"; "Currency" ]
    (prog ~exposing:"bad" ~imports:money_imports
       "fn bad(n: Int) -> String =\n  Currency n")

let t_bare_exchange_rate_rejected () =
  should_fail ~code:"T001" ~saying:[ "unknown constructor"; "ExchangeRate" ]
    (prog ~exposing:"bad" ~imports:money_imports
       "fn bad(n: Int) -> String =\n  ExchangeRate n")

let t_bare_money_rate_rejected () =
  should_fail ~code:"T001" ~saying:[ "unknown constructor"; "MoneyRate" ]
    (prog ~exposing:"bad" ~imports:money_imports
       "fn bad(n: Int) -> String =\n  MoneyRate n")

(** The dotted names resolve by a DIFFERENT path (stdlib_env), and the currency
    values are ordinary ADT constructors.  If the tightening had been done by
    removing the entries from `known_qualifier_modules` outright, this is the
    test that would have caught it. *)
let t_dotted_money_constructors_still_work () =
  should_pass
    (prog ~exposing:"a, b, c, d, e"
       ~imports:"import Tesl.Float exposing [Float]\n\
                 import Tesl.Time exposing [PosixMillis]\n\
                 import Tesl.Money exposing [Money, Currency, ExchangeRate, \
                 MoneyPerDuration, Usd, Eur, Jpy, Money.usd, \
                 Money.fromMinorUnits, ExchangeRate.make, ExchangeRate.rate, \
                 MoneyRate.perHour]"
       "fn a() -> Money =\n\
       \  Money.usd 1050\n\
        \n\
        fn b(cur: Currency, n: Int) -> Money =\n\
       \  Money.fromMinorUnits cur n\n\
        \n\
        fn c() -> Money =\n\
       \  Money.fromMinorUnits Usd 1050\n\
        \n\
        fn d(from: Currency, to: Currency, r: Float, at: PosixMillis) -> Float =\n\
       \  ExchangeRate.rate (ExchangeRate.make from to r at)\n\
        \n\
        fn e(m: Money) -> MoneyPerDuration =\n\
       \  MoneyRate.perHour m")

let t_currency_adt_constructors_still_work () =
  should_pass
    (prog ~exposing:"a, b, c"
       ~imports:"import Tesl.Money exposing [Currency, Usd, Eur, Jpy]"
       "fn a() -> Currency =\n  Usd\n\
        \n\
        fn b() -> Currency =\n  Eur\n\
        \n\
        fn c() -> Currency =\n  Jpy")

(* ══════════════════════════════════════════════════════════════════════════ *)
(*  4. A check-shaped call must be BOUND, not nested                          *)
(* ══════════════════════════════════════════════════════════════════════════ *)

let str_check_imports =
  "import Tesl.String exposing [String.requireNonEmpty, String.length]"

(** The TAIL of a fn body takes a different checker path from every other
    expression position ([check_expr] rather than [infer_expr]), so the rule has
    to be installed in both.  This probe is the one that catches a
    single-site fix. *)
let t_nested_check_in_tail_position_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "cannot be called in an argument position";
              "let result = check String.requireNonEmpty" ]
    (prog ~exposing:"f" ~imports:str_check_imports
       "fn f(s: String) -> Int =\n  String.length (String.requireNonEmpty s)")

(** …and the same shape inside a `let` value, which takes the other path. *)
let t_nested_check_in_let_value_rejected () =
  should_fail ~code:"T001" ~saying:[ "cannot be called in an argument position" ]
    (prog ~exposing:"f" ~imports:str_check_imports
       "fn f(s: String) -> Int =\n\
       \  let n = String.length (String.requireNonEmpty s)\n\
       \  n")

(** The live instance: `JWT.verify` returns the claims on success and a
    `check-fail … 401` on rejection, so nesting it hands Dict.lookup the
    check-fail struct and the 401 never happens. *)
let t_nested_jwt_verify_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "check function `JWT.verify` cannot be called in an argument position" ]
    (prog ~exposing:"authCap, f" ~imports:jwt_imports
       "capability authCap implies jwt\n\
        \n\
        fn f(token: JwtToken, secret: Secret) -> String requires [authCap] =\n\
       \  case Dict.lookup \"sub\" (JWT.verify token secret) of\n\
       \    Nothing -> \"\"\n\
       \    Something userId -> userId")

(** A USER check function is check-shaped for exactly the same reason, and
    `ctx.function_kinds` is the registry that says so. *)
let t_nested_user_check_rejected () =
  should_fail ~code:"T001" ~saying:[ "cannot be called in an argument position" ]
    (prog ~exposing:"InRange, checkRange, f" ~imports:str_check_imports
       "fact InRange (n: Int)\n\
        \n\
        check checkRange(n: Int) -> n: Int ::: InRange n =\n\
       \  if n >= 0 then\n\
       \    ok n ::: InRange n\n\
       \  else\n\
       \    fail 422 \"out of range\"\n\
        \n\
        fn wrap(n: Int) -> Int =\n\
       \  n\n\
        \n\
        fn f(n: Int) -> Int =\n\
       \  wrap (checkRange n)")

(* ── the positives: every legitimate shape the corpus uses ────────────────── *)

let t_let_check_binding_still_works () =
  should_pass
    (prog ~exposing:"f" ~imports:str_check_imports
       "fn f(s: String) -> Int =\n\
       \  let ok1 = check String.requireNonEmpty s\n\
       \  String.length ok1")

let t_check_bound_jwt_verify_still_works () =
  should_pass
    (prog ~exposing:"authCap, f" ~imports:jwt_imports
       "capability authCap implies jwt\n\
        \n\
        fn f(token: JwtToken, secret: Secret) -> String requires [authCap] =\n\
       \  let claims = check JWT.verify token secret\n\
       \  case Dict.lookup \"sub\" claims of\n\
       \    Nothing -> \"\"\n\
       \    Something userId -> userId")

(** A check function's own body ends in its verdict — a tail check call, not a
    nested one.  The rule must not touch it. *)
let t_check_function_tail_verdict_still_works () =
  should_pass
    (prog ~exposing:"InRange, checkRange, use" ~imports:""
       "fact InRange (n: Int)\n\
        \n\
        check checkRange(n: Int) -> n: Int ::: InRange n =\n\
       \  if n >= 0 then\n\
       \    ok n ::: InRange n\n\
       \  else\n\
       \    fail 422 \"out of range\"\n\
        \n\
        fn use(n: Int) -> Int =\n\
       \  let v = check checkRange n\n\
       \  v")

(** The proof-consuming shape the whole `check` form exists for: a check binding
    feeding a stdlib function that DEMANDS the proof. *)
let t_check_binding_feeds_a_proof_consumer () =
  should_pass
    (prog ~exposing:"f"
       ~imports:"import Tesl.Int exposing [Int.nonZero, Int.divide]"
       "fn f(a: Int, b: Int) -> Int =\n\
       \  let nz = check Int.nonZero b\n\
       \  Int.divide a nz")

(** A composed check — `check (checkA && checkB) value` — arrives with the checks
    as the head of the `check` application, not as arguments of an ordinary call.
    tests/critical-review-48-tests.tesl relies on this. *)
let t_composed_check_still_works () =
  should_pass
    (prog ~exposing:"Pos, Small, checkPositive, checkSmall, f" ~imports:""
       "fact Pos (n: Int)\n\
        fact Small (n: Int)\n\
        \n\
        check checkPositive(n: Int) -> n: Int ::: Pos n =\n\
       \  if n > 0 then\n\
       \    ok n ::: Pos n\n\
       \  else\n\
       \    fail 422 \"not positive\"\n\
        \n\
        check checkSmall(n: Int) -> n: Int ::: Small n =\n\
       \  if n < 100 then\n\
       \    ok n ::: Small n\n\
       \  else\n\
       \    fail 422 \"too big\"\n\
        \n\
        fn f(n: Int) -> Int =\n\
       \  let v = check (checkPositive && checkSmall) n\n\
       \  v")

(* ══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "fail-open-tightening" [
    "opaque-field-sets", [
      test_case "Int32.value is rejected, naming Int32.toInt" `Quick
        t_int32_value_rejected;
      test_case "an arbitrary field on Int32 is rejected" `Quick
        t_int32_arbitrary_field_rejected;
      test_case "Money.value is rejected, naming Money.minorUnits" `Quick
        t_money_value_rejected;
      test_case "Currency.value is rejected, naming Currency.code" `Quick
        t_currency_value_rejected;
      test_case "ExchangeRate.value is rejected, naming ExchangeRate.rate" `Quick
        t_exchange_rate_value_rejected;
      test_case "PosixMillis.value is rejected, naming Time.posixToSeconds" `Quick
        t_posix_millis_value_rejected;
      test_case "TimeZone.value is rejected, naming Time.offsetAt" `Quick
        t_timezone_value_rejected;
      test_case "a MoneyRate has no .value, and the alias name is what prints" `Quick
        t_money_rate_value_rejected;
      test_case "a quantity has no .value, and its own accessor is named" `Quick
        t_quantity_value_rejected;
    ];
    "opaque-field-sets-positive", [
      test_case "Int32.toInt still works" `Quick t_int32_accessor_still_works;
      test_case "Money.minorUnits / Money.currency still work" `Quick
        t_money_accessors_still_work;
      test_case "Time.posixToSeconds still works" `Quick
        t_posix_millis_accessor_still_works;
      test_case "Length.inMeters still works" `Quick t_quantity_accessor_still_works;
      test_case "a user-declared newtype KEEPS .value" `Quick
        t_user_newtype_keeps_value;
      test_case "HttpRequest's special fields are untouched" `Quick
        t_http_request_special_fields_still_work;
      test_case "an unknown HttpRequest field is still rejected" `Quick
        t_http_request_unknown_field_still_rejected;
    ];
    "secret-key-asymmetry", [
      test_case "Secret.value is rejected (the redaction is defeatable without this)"
        `Quick t_jwt_secret_value_rejected;
      test_case "JwtToken.value still works (a token is handed out on purpose)"
        `Quick t_jwt_token_value_still_works;
      test_case "a Secret is still usable — it signs" `Quick
        t_jwt_secret_still_signs;
    ];
    "bare-qualifier-application", [
      test_case "`Money n` is an unknown constructor, not `anything`" `Quick
        t_bare_money_rejected;
      test_case "`Currency n` is an unknown constructor" `Quick
        t_bare_currency_rejected;
      test_case "`ExchangeRate n` is an unknown constructor" `Quick
        t_bare_exchange_rate_rejected;
      test_case "`MoneyRate n` is an unknown constructor" `Quick
        t_bare_money_rate_rejected;
      test_case "the DOTTED Money/ExchangeRate/MoneyRate constructors still work"
        `Quick t_dotted_money_constructors_still_work;
      test_case "the Usd/Eur/Jpy ADT constructors still work" `Quick
        t_currency_adt_constructors_still_work;
    ];
    "nested-check-call", [
      test_case "a nested check call in TAIL position is rejected" `Quick
        t_nested_check_in_tail_position_rejected;
      test_case "a nested check call in a let value is rejected" `Quick
        t_nested_check_in_let_value_rejected;
      test_case "Dict.lookup \"sub\" (JWT.verify t s) is rejected" `Quick
        t_nested_jwt_verify_rejected;
      test_case "a nested USER check function is rejected" `Quick
        t_nested_user_check_rejected;
    ];
    "nested-check-call-positive", [
      test_case "`let x = check f a` still works" `Quick
        t_let_check_binding_still_works;
      test_case "`let claims = check JWT.verify t s` still works" `Quick
        t_check_bound_jwt_verify_still_works;
      test_case "a check function's tail verdict is untouched" `Quick
        t_check_function_tail_verdict_still_works;
      test_case "a check binding still feeds a proof-consuming stdlib call" `Quick
        t_check_binding_feeds_a_proof_consumer;
      test_case "`check (checkA && checkB) v` still works" `Quick
        t_composed_check_still_works;
    ];
  ]
