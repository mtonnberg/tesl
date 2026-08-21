(** `secret X = T` — the compile-time surface (roadmap/next/tesl_crypto.md,
    phases 3 and 4).

    THE FEATURE, IN ONE SENTENCE.  `secret X = T` is exactly `type X = T` MINUS
    `.value`, minus `Ord`, plus redaction at every rendering sink, plus a compile
    error if the type appears in a response / codec / generated-client position.
    `==` stays and lowers to a constant-time compare.

    WHY THESE PARTICULAR TESTS.  The guarantee is:

      > In Tesl code, a secret cannot become a `String`.  No interpolation, no
      > concatenation, no `.value`, no escape hatch.

    That is enforced almost entirely by SUBTRACTION, and subtraction is exactly
    what a future refactor re-adds by accident: a new field on the newtype
    accessor path, a new alias-chasing shortcut in `ty_is_ord`, a new "helpful"
    coercion in interpolation.  So each ratchet below is stated as a program that
    MUST NOT COMPILE, with a stable error code, plus — and this is the half that
    is usually missing — the positive program beside it that MUST compile, so the
    ratchet cannot be satisfied by rejecting everything.

    THE ASYMMETRY IS THE RULE.  A secret is one-way at the network boundary: it
    can come IN (Phase 4's inbound half — the plaintext password in a request
    body is the highest-value secret in the system and today has no protection at
    all) and it cannot go back OUT.  Both directions are pinned, including the
    TRANSITIVE case (a record containing a record containing a secret), because a
    name-level check that misses nesting is precisely the bug the EmailBody
    machinery this reuses was written to fix.

    THE CONTEXTUAL KEYWORD.  `secret` is NOT a lexer keyword: it is already an
    ordinary identifier in the corpus (`fn signClaims(claims: String, secret:
    Secret)`, `let secret = …` in tests/jwt-tests.tesl).  The last group here
    pins that both readings still work — in the same file, so a future move of
    the recognition into the lexer fails here rather than in the corpus sweep. *)

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
  let code =
    match Unix.close_process_in ic with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

(* The module NAME must match the file name (V001), so every probe is `Probe`. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-secret" "" in
  let path = Filename.concat dir "Probe.tesl" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f path)

let contains needle haystack =
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re haystack 0); true with Not_found -> false

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [ "--check"; path ] in
    if code <> 0 then failf "expected clean compile, got (exit %d):\n%s\n--- source ---\n%s" code out src)

(** Reject, with a STABLE error code and a message that names the reason.  The
    message substring is asserted too: a `secret` rejection that reports a
    generic "no such field" teaches the author nothing, and the whole learnable
    surface of this feature is one sentence, so the diagnostic has to carry it. *)
let should_fail ~code:code_expected ~saying src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [ "--check"; path ] in
    if code = 0 then
      failf "expected error[%s], but the program compiled clean:\n%s" code_expected src;
    if not (contains ("error[" ^ code_expected ^ "]") out) then
      failf "expected error[%s], got:\n%s" code_expected out;
    List.iter (fun phrase ->
      if not (contains phrase out) then
        failf "expected the diagnostic to say %S, got:\n%s" phrase out) saying)

let generate flag src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [ flag; path ] in
    (code, out))

(* ── Program shapes ───────────────────────────────────────────────────────── *)

let prelude =
  "module Probe exposing [Password, f]\n\
   import Tesl.Prelude exposing [Bool, Int, String, List]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   \n\
   secret Password = String\n\
   \n"

let prog body = prelude ^ body ^ "\n"

(* ── 1. Declaration: `secret` is a real declaration form ──────────────────── *)

let declares () =
  should_pass (prog "fn f(p: Password) -> Password =\n  p")

let declares_over_int () =
  should_pass
    ("module Probe exposing [Code, f]\n\
      import Tesl.Prelude exposing [Int]\n\
      \n\
      secret Code = Int\n\
      \n\
      fn f(c: Code) -> Code =\n  c\n")

(* ── 2. Withhold `.value` ─────────────────────────────────────────────────── *)

let no_value_accessor () =
  should_fail ~code:"T001"
    ~saying:[ "is a `secret` type"; "has no `.value`"; "`==`" ]
    (prog "fn f(p: Password) -> String =\n  p.value")

(** The CONTRAST that makes the ratchet meaningful: an ordinary newtype keeps
    `.value`.  Without this, "reject `.value` on every newtype" would pass. *)
let plain_newtype_keeps_value () =
  should_pass
    ("module Probe exposing [UserId, f]\n\
      import Tesl.Prelude exposing [String]\n\
      \n\
      type UserId = String\n\
      \n\
      fn f(u: UserId) -> String =\n  u.value\n")

let no_other_field () =
  should_fail ~code:"T001" ~saying:[ "no field" ]
    (prog "fn f(p: Password) -> String =\n  p.plaintext")

(* ── 3. Ord denied, Eq kept ───────────────────────────────────────────────── *)

let ord_denied () =
  should_fail ~code:"T001" ~saying:[ "ordering operator"; "Password" ]
    (prog "fn f(a: Password, b: Password) -> Bool =\n  a < b")

(** The one that a naive implementation gets wrong: `ty_is_ord` chases
    `ctx.type_aliases`, so a secret over `Int` would INHERIT Int's ordering
    unless the secret test runs BEFORE the chase.  An ordered comparison against
    a secret is a binary-search oracle for its value, so this is not cosmetic. *)
let ord_denied_over_int () =
  should_fail ~code:"T001" ~saying:[ "ordering operator" ]
    ("module Probe exposing [Code, f]\n\
      import Tesl.Prelude exposing [Bool, Int]\n\
      \n\
      secret Code = Int\n\
      \n\
      fn f(a: Code, b: Code) -> Bool =\n  a <= b\n")

let eq_allowed () =
  (* `==` STAYS — it is the sanctioned way to check a secret, and it lowers to a
     constant-time compare (tests/secret-runtime-tests.rkt pins the timing
     shape).  Contrast with PasswordHash/Signature, which lose Eq entirely
     because their only legitimate comparison IS a verification. *)
  should_pass (prog "fn f(a: Password, b: Password) -> Bool =\n  a == b")

let neq_allowed () =
  should_pass (prog "fn f(a: Password, b: Password) -> Bool =\n  a != b")

(* ── 4. Cannot become a String ────────────────────────────────────────────── *)

let interpolation_rejected () =
  should_fail ~code:"T001"
    ~saying:[ "cannot interpolate"; "it is a `secret`"; "no escape hatch" ]
    (prog "fn f(p: Password) -> String =\n  \"pw=${p}\"")

let concat_rejected () =
  (* `String.concat` is stdlib and must never accept a secret.  Unification is
     strictly nominal, so this is already a type error — the test exists to keep
     it one, because a future "newtypes coerce to their base at a call site"
     convenience would silently open every stdlib String function. *)
  should_fail ~code:"T001" ~saying:[ "Password" ]
    ("module Probe exposing [Password, f]\n\
      import Tesl.Prelude exposing [String, List]\n\
      import Tesl.String exposing [String.concat]\n\
      \n\
      secret Password = String\n\
      \n\
      fn f(p: Password) -> String =\n  String.concat p p\n")

let plaintext_into_secret_field_rejected () =
  (* The registration shape: a plaintext String may not be stored where a secret
     is declared.  Nominal identity is what does this; the ratchet keeps it. *)
  should_fail ~code:"T001" ~saying:[ "Password" ]
    ("module Probe exposing [Password, Account, f]\n\
      import Tesl.Prelude exposing [String]\n\
      \n\
      secret Password = String\n\
      \n\
      entity Account table \"accounts\" primaryKey id {\n\
      \  id: String @db(text)\n\
      \  password: Password @db(text)\n\
      }\n\
      \n\
      fn f(raw: String) -> Account =\n\
      \  let a = Account { id: \"a1\", password: raw }\n\
      \  a\n")

(* ── 5. Telemetry — the one sink reachable without `.value` ────────────────── *)

let telemetry_rejected () =
  (* A telemetry attribute value is an arbitrary expression with NO type
     constraint, which makes it the single place a secret reaches a rendering
     sink without going through `.value` or an interpolation hole.  The runtime
     redacts it, but a redacted attribute is a silently useless attribute — so
     it is rejected where the author can see it. *)
  should_fail ~code:"T001"
    ~saying:[ "telemetry attribute"; "is a `secret`"; "keyFingerprint" ]
    (prog "fn f(p: Password) -> String =\n\
          \  telemetry \"login\" { pw = p }\n\
          \  \"ok\"")

let telemetry_non_secret_allowed () =
  should_pass
    (prog "fn f(p: Password) -> String =\n\
          \  telemetry \"login\" { who = \"someone\" }\n\
          \  \"ok\"")

(* ── 6. Response / codec / client rejection, and the inbound acceptance ───── *)

let api_shape ~body_type ~return_type ~extra =
  Printf.sprintf
    "module Probe exposing [Password, Inner, Outer, LoginBody, LoginOut, h, ProbeApi]\n\
     import Tesl.Prelude exposing [Bool, String]\n\
     \n\
     secret Password = String\n\
     \n\
     record Inner { pw: Password }\n\
     record Outer { inner: Inner }\n\
     record LoginBody { email: String, password: Password }\n\
     record LoginOut { fine: Bool }\n\
     %s\
     handler h(body: %s) -> %s =\n\
     \  let out = %s\n\
     \  out\n\
     \n\
     api ProbeApi {\n\
     \  post \"/x\"\n\
     \    body body: %s\n\
     \    -> %s\n\
     }\n"
    extra body_type return_type
    (if return_type = "LoginOut" then "LoginOut { fine: True }"
     else "Outer { inner: Inner { pw: Password \"x\" } }")
    body_type return_type

(** THE INBOUND HALF (Phase 4).  `record LoginBody { email: String, password:
    Password }` in a REQUEST position is the whole point of the feature and must
    be accepted — the plaintext password in a request body is the highest-value
    secret in the system.  Verified end to end (a real JSON post that decodes and
    compares) by tests/secret-runtime-tests.rkt's sibling api-test; here we pin
    the CHECKER's acceptance, which is what a "reject secrets at the boundary"
    over-correction would break. *)
let secret_accepted_in_request_position () =
  should_pass (api_shape ~body_type:"LoginBody" ~return_type:"LoginOut" ~extra:"")

let secret_rejected_in_response_position () =
  should_fail ~code:"T001"
    ~saying:[ "cannot be serialized to a client"; "one-way at the network boundary" ]
    (api_shape ~body_type:"LoginBody" ~return_type:"Outer" ~extra:"")

(** TRANSITIVITY, named in the message.  A record containing a record containing
    a secret is equally rejected, and the diagnostic prints the
    `Outer.inner → Inner.pw` path — a rejection the author cannot locate is a
    rejection they will work around by not declaring the type `secret`. *)
let response_rejection_is_transitive_and_names_the_path () =
  should_fail ~code:"T001" ~saying:[ "`Outer.inner`"; "`Inner.pw`" ]
    (api_shape ~body_type:"LoginBody" ~return_type:"Outer" ~extra:"")

let sse_payload_rejected () =
  (* An SSE payload is an OUTBOUND position — it is serialized to a connected
     client — so it takes the response rule, not the request one. *)
  should_fail ~code:"T001" ~saying:[ "cannot be serialized to a client" ]
    ("module Probe exposing [Password, Inner, ProbeEvents]\n\
      import Tesl.Prelude exposing [String]\n\
      import Tesl.SSE exposing [SseChannel]\n\
      \n\
      secret Password = String\n\
      \n\
      record Inner { pw: Password }\n\
      \n\
      sseChannel ProbeEvents(key: String) = SseChannel {\n\
      \  payload: Inner\n\
      }\n")

let codec_rejected () =
  should_fail ~code:"V001"
    ~saying:[ "is a `secret`, which has no serialization"; "randomToken" ]
    ("module Probe exposing [Password]\n\
      import Tesl.Prelude exposing [String]\n\
      import Tesl.Json exposing [stringCodec]\n\
      \n\
      secret Password = String\n\
      \n\
      codec Password {\n\
      \  toJson {\n\
      \    value -> \"value\" with_codec stringCodec\n\
      \  }\n\
      \  fromJson [\n\
      \    {\n\
      \      value <- \"value\" with_codec stringCodec\n\
      \    }\n\
      \  ]\n\
      }\n")

let plain_newtype_codec_still_allowed () =
  (* The contrast: a codec on an ordinary newtype is untouched. *)
  should_pass
    ("module Probe exposing [UserId]\n\
      import Tesl.Prelude exposing [String]\n\
      import Tesl.Json exposing [stringCodec]\n\
      \n\
      type UserId = String\n\
      \n\
      codec UserId {\n\
      \  toJson {\n\
      \    value -> \"value\" with_codec stringCodec\n\
      \  }\n\
      \  fromJson [\n\
      \    {\n\
      \      value <- \"value\" with_codec stringCodec\n\
      \    }\n\
      \  ]\n\
      }\n")

(* ── 6b. A `via`-checked field whose OWN type is a secret newtype ─────────────
   roadmap/completed/secret_wrapped_credentials.md: `secret Password = String
   ::: P` is not a valid DECLARATION (the newtype grammar's base is a plain
   type_expr), but a record FIELD typed as the secret newtype with the proof
   on the FIELD (`password: Password ::: P`, decoded `with_codec stringCodec
   via isLongEnough`) is — record fields already carry proof annotations, and
   the inbound path already mints a secret straight from a bare JSON string,
   so this is those two shipped mechanisms composing, not new syntax.

   The compiler used to apply the newtype wrap BEFORE the `via` check ran, so
   `isLongEnough` — declared to take a plain `String` — was actually invoked
   with the wrapped secret struct.  It happened to still work, structurally,
   because the stdlib's `raw-str` unwraps ANY `newtype-value?` (secret or
   not) with no regard to secrecy — so the plaintext was fully available to
   an arbitrary `via` function under a signature that claimed it never saw
   more than a `String`.  Concretely: a `via` function that put its argument
   in its own `fail` message would echo the plaintext straight into the 400
   response (verified against the pre-fix compiler by hand — not asserted
   here, since that is a property of what a check function's AUTHOR writes,
   not of the compiler; what the compiler owes is that the check function
   really receives the type it declared).  Fixed by decoding the raw base
   value, running `via` on THAT, and applying the newtype constructor only to
   a value the check has already accepted. *)

let secret_field_with_via_proof_src =
  "module Probe exposing [Password, Body, f, isLongEnough]\n\
   import Tesl.Prelude exposing [Bool, String]\n\
   import Tesl.String exposing [String.length]\n\
   import Tesl.Json exposing [stringCodec]\n\
   \n\
   secret Password = String\n\
   \n\
   fact LongEnough (text: String)\n\
   \n\
   check isLongEnough(text: String) -> text: String ::: LongEnough text =\n\
   \  if String.length text >= 8 then\n\
   \    ok text ::: LongEnough text\n\
   \  else\n\
   \    fail 400 \"too short\"\n\
   \n\
   record Body { password: Password ::: LongEnough password }\n\
   \n\
   codec Body {\n\
   \  toJson_forbidden\n\
   \  fromJson [\n\
   \    { password <- \"password\" with_codec stringCodec via isLongEnough }\n\
   \  ]\n\
   }\n\
   \n\
   fn f(b: Body) -> Password =\n  b.password\n"

let secret_field_with_via_proof_compiles () =
  should_pass secret_field_with_via_proof_src

let compile_to_go src =
  with_temp_file src (fun path ->
    match Compile.compile_go_file path with
    | Compile.GoFailure diagnostics ->
      failf "expected clean Go compile:\n%s\n--- source ---\n%s"
        (String.concat "\n"
           (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)) src
    | Compile.GoSuccess artifacts ->
      match List.find_opt (fun (a : Emit_go.artifact) ->
        Filename.basename a.path = "module.go") artifacts with
      | Some artifact -> artifact.contents
      | None -> failf "Go emit did not produce module.go")

let secret_field_with_via_proof_wraps_after_the_check () =
  let out = compile_to_go secret_field_with_via_proof_src in
  let position needle =
    try Str.search_forward (Str.regexp_string needle) out 0
    with Not_found -> failf "expected %S in emitted Go:\n%s" needle out
  in
  let checked = position "teslCheckedPassword := IsLongEnough(teslFieldPassword)" in
  let extracted = position "teslFieldPassword, _ = teslCheckedPassword.Value()" in
  let wrapped = position "Password{Value: teslrt.MakeSecret(teslFieldPassword)}" in
  if not (checked < extracted && extracted < wrapped) then
    failf "expected decode, via-check extraction, then secret wrapping; got:\n%s" out

(* ── 7. Generated clients, direction-dependent ────────────────────────────── *)

let client_request_src =
  "module Probe exposing [Password, LoginBody, LoginOut, h, ProbeApi]\n\
   import Tesl.Prelude exposing [Bool, String]\n\
   \n\
   secret Password = String\n\
   \n\
   record LoginBody { email: String, password: Password }\n\
   record LoginOut { fine: Bool }\n\
   \n\
   handler h(body: LoginBody) -> LoginOut =\n\
   \  let out = LoginOut { fine: True }\n\
   \  out\n\
   \n\
   api ProbeApi {\n\
   \  post \"/x\"\n\
   \    body body: LoginBody\n\
   \    -> LoginOut\n\
   }\n"

let ts_request_field_is_string () =
  let code, out = generate "--generate-ts" client_request_src in
  if code <> 0 then failf "expected the TS client to generate, got (exit %d):\n%s" code out;
  (* A plain `z.string()` — NOT branded.  A brand would force the caller to mint
     a Tesl-side value it has no way to obtain; the client holds the plaintext
     and must be able to send it. *)
  if not (contains "export const PasswordSchema = z.string();" out) then
    failf "expected an unbranded z.string() for the secret request field, got:\n%s" out;
  if contains "PasswordSchema = z.string().brand" out then
    failf "the secret emitted a brand, which a client cannot construct:\n%s" out;
  (* And it says so, so a reader of the generated file learns the direction. *)
  if not (contains "request-only" out) then
    failf "expected the generated TS to state the one-way direction:\n%s" out

let elm_request_field_is_string () =
  let code, out = generate "--generate-elm" client_request_src in
  if code <> 0 then failf "expected the Elm client to generate, got (exit %d):\n%s" code out;
  if not (contains "type alias Password =\n    String" out) then
    failf "expected `type alias Password = String`, got:\n%s" out;
  (* The encoder AND decoder are both emitted: a request record gets its own
     decoder in Elm and it references this one, so dropping either produces a
     generated module that does not compile.  The client is outside the guarantee
     boundary; the enforcement that matters happened in the checker. *)
  if not (contains "passwordEncoder : Password -> E.Value" out) then
    failf "expected a passwordEncoder for the request direction:\n%s" out;
  if not (contains "passwordDecoder : D.Decoder Password" out) then
    failf "expected passwordDecoder (loginBodyDecoder references it):\n%s" out;
  if not (contains "request-only" out) then
    failf "expected the generated Elm to state the one-way direction:\n%s" out

let client_response_fails_the_build () =
  (* Both generators are gated behind the FULL checker, so the response
     rejection IS the client rejection — the generator can simply never be
     handed a secret in an outbound type.  Asserted through the generator entry
     point rather than `--check`, because the gate is what makes that true. *)
  let src = api_shape ~body_type:"LoginBody" ~return_type:"Outer" ~extra:"" in
  List.iter (fun flag ->
    let code, out = generate flag src in
    if code = 0 then
      failf "%s generated a client for a response-position secret:\n%s" flag out;
    if not (contains "cannot be serialized to a client" out) then
      failf "%s failed for the wrong reason:\n%s" flag out)
    [ "--generate-ts"; "--generate-elm" ]

(* ── 8. Secret-accepting sinks: the design must be USABLE ─────────────────── *)

let env_require_secret_accepted () =
  should_pass
    ("module Probe exposing [loadKey]\n\
      import Tesl.Prelude exposing [String]\n\
      import Tesl.Env exposing [requireSecret, envRead]\n\
      import Tesl.Crypto exposing [Secret, Crypto.keyFingerprint]\n\
      \n\
      fn loadKey() -> String\n\
      \  requires [envRead] =\n\
      \  let k = requireSecret \"API_KEY\"\n\
      \  Crypto.keyFingerprint k\n")

let http_secret_header_accepted () =
  (* No intermediate String anywhere: the secret goes from the environment into
     a header and onto the wire, and the only unwrap is inside the client. *)
  should_pass
    ("module Probe exposing [callOut]\n\
      import Tesl.Prelude exposing [String, List]\n\
      import Tesl.Env exposing [requireSecret, envRead]\n\
      import Tesl.Crypto exposing [Secret]\n\
      import Tesl.HttpClient exposing [httpClient, HttpResponse, HttpClient.get, HttpClient.bearer, HttpClient.secretHeader]\n\
      \n\
      fn callOut() -> HttpResponse\n\
      \  requires [envRead, httpClient] =\n\
      \  let k = requireSecret \"API_KEY\"\n\
      \  HttpClient.get \"https://example.com\" [HttpClient.bearer k, HttpClient.secretHeader \"X-Api-Key\" k]\n")

let stdlib_secret_has_no_value_either () =
  (* The stdlib `Secret` is subject to the same subtraction, via its own
     no-eliminator list — asserted here so the user-secret rule and the stdlib
     rule cannot drift into disagreeing. *)
  should_fail ~code:"T001" ~saying:[ "Secret" ]
    ("module Probe exposing [f]\n\
      import Tesl.Prelude exposing [String]\n\
      import Tesl.Crypto exposing [Secret]\n\
      \n\
      fn f(s: Secret) -> String =\n  s.value\n")

(* ── 8b. The secret-accepting-PARAMETER rule ──────────────────────────────────
   The rule that makes the feature usable rather than merely safe:

     a `secret T` may be passed where a parameter explicitly MARKED
     secret-accepting expects a `T`.  Nowhere else.

   Without it, an author declares `secret Password = String`, finds that
   `Crypto.hashPassword body.password` does not typecheck, and — per the
   roadmap's own named risk — stops declaring the type `secret` at all.  With it,
   the marking has to be exactly per-parameter, which is what the negative half
   below measures: `String.concat` is stdlib too and must never accept a secret,
   and `Crypto.checkPassword`'s FIRST argument is the stored hash while only its
   SECOND is the candidate. *)

let crypto_prelude =
  "module Probe exposing [Password, ApiKey, LoginBody, f]\n\
   import Tesl.Prelude exposing [Bool, Int, String, List]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   import Tesl.Random exposing [random]\n\
   import Tesl.String exposing [String.concat, String.length]\n\
   import Tesl.Crypto exposing [PasswordHash, Signature, Secret, \
   Crypto.hashPassword, Crypto.checkPassword, Crypto.signWith, \
   Crypto.checkSignature, Crypto.keyFingerprint, Crypto.fingerprint]\n\
   \n\
   secret Password = String\n\
   secret ApiKey = String\n\
   \n\
   record LoginBody { email: String, password: Password }\n\
   \n"

let crypto_prog body = crypto_prelude ^ body ^ "\n"

(** THE SHAPE THE FEATURE EXISTS FOR, end to end: a request-body record whose
    field is `secret Password = String`, hashed by `Crypto.hashPassword`, with no
    intermediate `String` anywhere.  The field access is an `EField`, not a plain
    variable, deliberately — that is the shape the repro used and the shape a
    variable-only relaxation would miss. *)
let hash_password_from_a_request_body () =
  should_pass
    (crypto_prog
       "fn f(body: LoginBody) -> PasswordHash\n\
       \  requires [random] =\n\
       \  Crypto.hashPassword body.password")

(** The SAME call, but its result is bound with `let` before being returned,
    instead of being the function's tail expression directly. `infer_expr`'s
    application arm used to unify the callee's OWN (concrete) function type
    against `TFun(widened_param, ...)` — so a secret-accepting call widened to
    `Password` failed with "cannot unify String with Password", because the
    callee's real signature says `String` and nothing should have tried to
    rewrite it. `check_expr`'s parallel implementation never had this bug
    (it only unifies the ARGUMENT against the widened type), which is why the
    tail-position case above always passed while this one did not — until the
    two were unified. Not a synthetic case: this is `let hash =
    Crypto.hashPassword password \n ...`, the ordinary shape of any handler
    that hashes then stores. *)
let hash_password_let_bound () =
  should_pass
    (crypto_prog
       "fn f(body: LoginBody) -> PasswordHash\n\
       \  requires [random] =\n\
       \  let hash = Crypto.hashPassword body.password\n\
       \  hash")

let sinks_accept_a_user_secret () =
  (* Every marked sink, each with a secret the author declared themselves — the
     stdlib `Secret` is not involved anywhere. *)
  List.iter (fun body -> should_pass (crypto_prog body))
    [ "fn f(k: ApiKey) -> String =\n  Crypto.keyFingerprint k";
      "fn f(k: ApiKey, m: String) -> Signature =\n  Crypto.signWith k m";
      "fn f(k: ApiKey, s: Signature, m: String) -> String =\n  Crypto.checkSignature k s m";
      "fn f(stored: Maybe PasswordHash, cand: Password) -> Maybe PasswordHash =\n\
      \  Crypto.checkPassword stored cand" ]

let http_sinks_accept_a_user_secret () =
  should_pass
    ("module Probe exposing [ApiKey, f]\n\
      import Tesl.Prelude exposing [String, List]\n\
      import Tesl.HttpClient exposing [httpClient, HttpResponse, HttpClient.get, HttpClient.bearer, HttpClient.secretHeader]\n\
      \n\
      secret ApiKey = String\n\
      \n\
      fn f(k: ApiKey) -> HttpResponse\n\
      \  requires [httpClient] =\n\
      \  HttpClient.get \"https://example.com\" [HttpClient.bearer k, HttpClient.secretHeader \"X-Api-Key\" k]\n")

(** THE NEGATIVE HALF — the tests that prove the marking is a MARKING and not a
    hole.  Each of these would pass if the relaxation were "any stdlib String
    parameter accepts a secret", which is the shape a shortcut would take. *)
let unmarked_parameters_still_reject () =
  List.iter (fun (label, body) ->
      try should_fail ~code:"T001" ~saying:[ "Password" ] (crypto_prog body)
      with Failure m -> failf "%s: %s" label m)
    [ ("String.concat", "fn f(p: Password) -> String =\n  String.concat p p");
      ("String.length", "fn f(p: Password) -> Int =\n  String.length p");
      (* Crypto.fingerprint digests PUBLIC data and is deliberately unmarked;
         `Crypto.keyFingerprint` is the secret-accepting sibling.  Two adjacent
         functions in the same module, one marked and one not, is the sharpest
         available statement that the unit of opt-in is the parameter. *)
      ("Crypto.fingerprint", "fn f(p: Password) -> String =\n  Crypto.fingerprint p") ]

let checkPassword_stored_hash_slot_is_not_marked () =
  (* Index 0 is the STORED hash — a value you already hold, not a secret you were
     handed.  Only index 1, the candidate, is marked.  A per-FUNCTION marking
     could not express this. *)
  should_fail ~code:"T001" ~saying:[ "PasswordHash" ]
    (crypto_prog
       "fn f(p: Maybe Password, cand: Password) -> Maybe PasswordHash =\n\
       \  Crypto.checkPassword p cand")

let a_secret_over_the_wrong_base_is_rejected () =
  (* The marking widens the slot for secrets over the base the slot WANTS; it
     does not turn the slot into a wildcard.  `secret Code = Int` is still
     rejected by `Crypto.signWith`'s key parameter. *)
  should_fail ~code:"T001" ~saying:[ "Code" ]
    ("module Probe exposing [Code, f]\n\
      import Tesl.Prelude exposing [Int, String]\n\
      import Tesl.Crypto exposing [Signature, Secret, Crypto.signWith]\n\
      \n\
      secret Code = Int\n\
      \n\
      fn f(k: Code, m: String) -> Signature =\n  Crypto.signWith k m\n")

let the_stdlib_Secret_still_works_in_a_marked_slot () =
  (* Regression: relaxing the slot must not break the type the slot declares. *)
  should_pass
    ("module Probe exposing [f]\n\
      import Tesl.Prelude exposing [String]\n\
      import Tesl.Crypto exposing [Secret, Crypto.keyFingerprint]\n\
      \n\
      fn f(k: Secret) -> String =\n  Crypto.keyFingerprint k\n")

let a_plain_string_still_works_in_a_marked_slot () =
  (* The other regression direction: a marked slot must keep accepting the base
     type it declares, or every existing `Crypto.hashPassword rawPassword` call
     breaks. *)
  should_pass
    (crypto_prog
       "fn f(raw: String) -> PasswordHash\n\
       \  requires [random] =\n\
       \  Crypto.hashPassword raw")

(* ── 9. `secret` is a CONTEXTUAL keyword ──────────────────────────────────── *)

let secret_still_usable_as_an_identifier () =
  (* Both readings, in ONE file: `secret` as a parameter name, as a `let` binder,
     AND as the declaration keyword.  If recognition ever moves into the lexer's
     keyword table, this file stops parsing — which is what happens to
     tests/jwt-tests.tesl (`fn signClaims(claims: String, secret: Secret)`)
     and is the reason the keyword is contextual. *)
  should_pass
    ("module Probe exposing [Password, useIt]\n\
      import Tesl.Prelude exposing [String]\n\
      \n\
      secret Password = String\n\
      \n\
      fn useIt(secret: String) -> String =\n\
      \  let secret2 = secret\n\
      \  secret2\n")

let secret_as_a_bare_const_still_parses () =
  (* The arm sits beside the bare-const arm (`IDENT _ when peek2 s = EQ`), and
     the two-token lookahead is what separates them: `secret = "x"` is a const,
     `secret Password = String` is a declaration. *)
  should_pass
    ("module Probe exposing [f]\n\
      import Tesl.Prelude exposing [String]\n\
      \n\
      secret = \"a-plain-const-named-secret\"\n\
      \n\
      fn f() -> String =\n  secret\n")

(* ── Suite ────────────────────────────────────────────────────────────────── *)

let () =
  run "secret surface" [
    ("declare", [
      test_case "secret X = String declares a usable nominal type" `Quick declares;
      test_case "secret X = Int is equally a declaration" `Quick declares_over_int;
    ]);
    ("withhold .value", [
      test_case "a secret has no .value" `Quick no_value_accessor;
      test_case "an ordinary newtype still has .value" `Quick plain_newtype_keeps_value;
      test_case "no other field either" `Quick no_other_field;
      test_case "the stdlib Secret withholds .value too" `Quick stdlib_secret_has_no_value_either;
    ]);
    ("Ord denied, Eq kept", [
      test_case "< is rejected" `Quick ord_denied;
      test_case "<= is rejected over Int (before the alias chase)" `Quick ord_denied_over_int;
      test_case "== is allowed" `Quick eq_allowed;
      test_case "!= is allowed" `Quick neq_allowed;
    ]);
    ("cannot become a String", [
      test_case "interpolation is rejected, with the reason" `Quick interpolation_rejected;
      test_case "String.concat rejects a secret" `Quick concat_rejected;
      test_case "a plaintext String cannot fill a secret field" `Quick
        plaintext_into_secret_field_rejected;
    ]);
    ("telemetry", [
      test_case "a secret attribute value is rejected" `Quick telemetry_rejected;
      test_case "a non-secret attribute is unaffected" `Quick telemetry_non_secret_allowed;
    ]);
    ("the network asymmetry", [
      test_case "ACCEPTED in a request position (the inbound half)" `Quick
        secret_accepted_in_request_position;
      test_case "REJECTED in a response position" `Quick
        secret_rejected_in_response_position;
      test_case "the response rejection is transitive and names the path" `Quick
        response_rejection_is_transitive_and_names_the_path;
      test_case "an SSE payload is a response position" `Quick sse_payload_rejected;
      test_case "a codec on a secret is rejected" `Quick codec_rejected;
      test_case "a codec on an ordinary newtype still works" `Quick
        plain_newtype_codec_still_allowed;
    ]);
    ("a via-checked field typed as the secret itself", [
      test_case "compiles: proof on the field, secret as the field's type" `Quick
        secret_field_with_via_proof_compiles;
      test_case "the newtype wrap applies AFTER the check, not before" `Quick
        secret_field_with_via_proof_wraps_after_the_check;
    ]);
    ("generated clients", [
      test_case "TS: a request field emits as an unbranded string" `Quick
        ts_request_field_is_string;
      test_case "Elm: a request field emits as String" `Quick elm_request_field_is_string;
      test_case "a response field fails the build in both generators" `Quick
        client_response_fails_the_build;
    ]);
    ("secret-accepting sinks", [
      test_case "Env.requireSecret mints one from the environment" `Quick
        env_require_secret_accepted;
      test_case "HttpClient.bearer / .secretHeader take one directly" `Quick
        http_secret_header_accepted;
    ]);
    ("secret-accepting parameters", [
      test_case "the LoginBody.password -> Crypto.hashPassword shape compiles" `Quick
        hash_password_from_a_request_body;
      test_case "the same shape still compiles when let-bound, not tail" `Quick
        hash_password_let_bound;
      test_case "every Crypto sink accepts a user-declared secret" `Quick
        sinks_accept_a_user_secret;
      test_case "HttpClient.bearer / .secretHeader accept a user-declared secret" `Quick
        http_sinks_accept_a_user_secret;
      test_case "an UNMARKED stdlib parameter still rejects a secret" `Quick
        unmarked_parameters_still_reject;
      test_case "checkPassword's stored-hash slot is not marked" `Quick
        checkPassword_stored_hash_slot_is_not_marked;
      test_case "a secret over the wrong base is still rejected" `Quick
        a_secret_over_the_wrong_base_is_rejected;
      test_case "the stdlib Secret still works in a marked slot" `Quick
        the_stdlib_Secret_still_works_in_a_marked_slot;
      test_case "a plain String still works in a marked slot" `Quick
        a_plain_string_still_works_in_a_marked_slot;
    ]);
    ("contextual keyword", [
      test_case "`secret` still works as a parameter and let binder" `Quick
        secret_still_usable_as_an_identifier;
      test_case "`secret = …` is still a bare const" `Quick
        secret_as_a_bare_const_still_parses;
    ]);
  ]
