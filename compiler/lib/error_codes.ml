(** Central, stable error-code registry (roadmap A3 / WS4).

    This module is the *single source of truth* for the compiler's diagnostic
    codes.  Every code the CLI can render — parser/type/proof/validation errors
    plus every linter rule — is documented here exactly once, together with:

      - a human-readable {b title} (what the code means),
      - a short {b explanation} (why it fires / how to think about it), and
      - an optional {b manual anchor} (`<section>#<anchor>`) that deep-links into
        the shipped manual via `tesl help manual <section>#<anchor>`.

    Goals:
      - {b Stability.} Codes never drift, because they are defined in one place
        and covered by tests.  Existing rendered codes (E000, T001, P001, V001,
        VBOOL001/2, W0xx, E0xx) are preserved verbatim — they are a contract that
        `compiler/test/test_diagnostics.ml` and the antagonistic suites assert on.
      - {b Deep-links.} Each code maps to the manual section that teaches the
        concept, so a rendered error can say "read more: tesl help manual …".
      - {b Discoverability.} `tesl help <code>` / `tesl explain <code>` print the
        entry; `tesl help codes` lists the whole registry.

    The {!manual_for} function additionally refines the broad validation code
    [V001] (which tags every validation-pass error) to the most relevant manual
    anchor using the STRUCTURED {!manual_topic} the producing validation pass
    stamped on the error — so a capability error and a codec error link to
    different sections even though they share a rendered code.  Routing is by the
    resolved topic (decide-by-resolution), never by sniffing keywords out of the
    rendered message text.  This keeps the rendered code stable while still
    giving precise "read more" pointers that cannot be hijacked by incidental
    words in user-controlled identifiers.

    Anchors here MUST match a heading slug documented in [manual/anchors.md]; the
    test [test_error_codes.ml] fails the build if any anchor stops resolving. *)

type category =
  | Syntax        (** parse / lexical structure *)
  | Type          (** type checking *)
  | Proof         (** proof / GDP fact reasoning *)
  | Capability    (** capability declaration / usage *)
  | Structure     (** servers, bindings, channels, databases, tests *)
  | Codec         (** JSON codec / SQL field coverage *)
  | Naming        (** scope / naming / imports *)
  | Lint          (** opinionated linter warnings *)
  | Security      (** structural security mistakes (SEC0xx) *)

let category_name = function
  | Syntax -> "syntax"
  | Type -> "type"
  | Proof -> "proof"
  | Capability -> "capability"
  | Structure -> "structure"
  | Codec -> "codec"
  | Naming -> "naming"
  | Lint -> "lint"
  | Security -> "security"

type entry = {
  code     : string;
  category : category;
  title    : string;          (** one-line "what this code means" *)
  explanation : string;       (** the "why / how to think about it" prose *)
  manual   : string option;   (** "<section>#<anchor>" or "<section>" or None *)
}

(* ── Manual deep-link topic (B5) ────────────────────────────────────────────
   The broad validation code [V001] tags a whole family of rules, but each rule
   should deep-link to the manual section that teaches ITS concept.  That routing
   used to be decided by SUBSTRING-SNIFFING the rendered message text — so the
   SAME structural rule routed to DIFFERENT anchors purely by incidental words in
   user-controlled identifiers (e.g. an api-test whose description happened to
   contain "database" was hijacked from #testing to #database-access).

   The topic is now a CLOSED variant decided UPSTREAM by which validation pass
   produced the error (see validation.ml), carried structurally on the
   [validation_error] (see validation_common.ml), and resolved to an anchor by
   the single TOTAL [anchor_of_topic] map below.  Message text no longer decides
   anything: a rule's anchor is a property of the rule, listed exactly once. *)
type manual_topic =
  | TStructural   (* servers/handlers/bindings/queues/channels/workers/cache/email/config/app-wiring *)
  | TDatabase     (* entities, database blocks, SQL field names, SQL WHERE, PK matching *)
  | TTesting      (* test blocks, api-test structure/descriptions *)
  | TProof        (* call-site proofs, forall/exists, ghost witness, record-field/return proof annotations *)
  | TCodec        (* codec coverage/types, capture codec types *)
  | TCapability   (* handler capabilities, capability cycles, auth/ord restrictions *)
  | TNaming       (* exhaustiveness, shadowing, imports, duplicates, arities, reserved names *)
  | TGeneric      (* fallback == the topic-less V001 default *)

(** SINGLE source of truth: one arm per constructor.  A new [manual_topic]
    constructor without an anchor here is a non-exhaustive-match COMPILE ERROR,
    not a silent dangling deep-link.  Every anchor below is slug-checked by
    [test_error_codes.ml] so a heading rename cannot silently break a link. *)
let anchor_of_topic : manual_topic -> string = function
  | TStructural  -> "best-practices#api-design"
  | TDatabase    -> "best-practices#database-access"
  | TTesting     -> "best-practices#testing"
  | TProof       -> "best-practices#proof-management"
  | TCodec       -> "best-practices#validation-patterns"
  | TCapability  -> "best-practices#api-design"
  | TNaming      -> "best-practices#validation-patterns"
  | TGeneric     -> "best-practices#validation-patterns"

(** Every [manual_topic] constructor, so tests can iterate the closed set and
    assert totality of [anchor_of_topic].  Keep in sync with the variant (the
    exhaustive match in [anchor_of_topic] enforces the anchor side; this list is
    the enumeration side — the test guards it against a forgotten constructor by
    comparing lengths in a warning-covered position is not possible, so keep this
    list complete by hand when adding a topic). *)
let all_topics : manual_topic list =
  [ TStructural; TDatabase; TTesting; TProof; TCodec; TCapability; TNaming; TGeneric ]

(* ── The registry ─────────────────────────────────────────────────────────
   One row per *rendered* code.  Keep this list in sync with:
     - compile.ml      (diag_of_* : E000/T001/P001/V001, VBOOL001/2,
                        VREGEX001-4 via regex_lint.ml)
     - linter.ml       (E001/E002/E010/E03x and W0xx — see its header comment)
   Adding a NEW rendered code is a deliberate act: add it here AND add a case
   to test_error_codes.ml. *)
let registry : entry list = [
  (* ── Parser / syntax ──────────────────────────────────────────────────── *)
  { code = "E000"; category = Syntax;
    title = "syntax error";
    explanation =
      "The parser could not make sense of the source at this position. This is \
       a structural problem (a missing keyword, an unexpected token, a \
       single-line function body, bad indentation, …) rather than a type or \
       proof problem. Read the message for the specific cause. Some parse \
       errors with a mechanical rewrite (e.g. a single-line \
       `if cond then a else b`) carry a structured machine-applicable fix, \
       surfaced in editors as a quickfix.";
    manual = Some "language-spec" };

  (* ── Type checker ─────────────────────────────────────────────────────── *)
  { code = "T001"; category = Type;
    title = "type error";
    explanation =
      "The type checker rejected the program: two types could not be unified, \
       a value was used at the wrong type, a name/type is not in scope, or a \
       function body does not match its declared return type. The message names \
       the conflicting types and (where possible) the expectation chain that \
       led there. Errors with a mechanical rewrite (a missing import, \
       `return x`, `+` on strings) carry a structured machine-applicable fix, \
       surfaced in editors as a quickfix.";
    manual = Some "overview#core-principles" };

  (* ── Proof checker / GDP reasoning ────────────────────────────────────── *)
  { code = "P001"; category = Proof;
    title = "proof error";
    explanation =
      "A proof (Ghosts-of-Departed-Proofs fact) is missing, malformed, or used \
       illegally — e.g. `ok ::: P` constructed outside a `check`, a ghost \
       witness whose predicate does not match a record invariant, or a proof \
       predicate that is not in scope. Proofs can only be produced by a `check` \
       and travel attached to the value they describe.";
    manual = Some "best-practices#proof-management" };

  (* ── Validation passes (broad code; refined by message in manual_for) ──── *)
  { code = "V001"; category = Structure;
    title = "validation error";
    explanation =
      "A semantic validation pass rejected the program. This covers a family of \
       checks that run after parsing/typing: call-site proof satisfaction, \
       capability declarations, codec/SQL field coverage, server binding \
       completeness, and structural rules (channels, databases, tests). The \
       message describes the specific rule; `tesl help manual` links below point \
       at the most relevant section for the kind of error.";
    manual = Some "best-practices#validation-patterns" };

  (* ── Legacy Bool spelling (validation source, dedicated codes) ─────────── *)
  { code = "VBOOL001"; category = Type;
    title = "use `Bool`, not `Boolean`/`bool`";
    explanation =
      "Tesl's boolean type is spelled `Bool` (constructors `True`/`False`), from \
       `Tesl.Prelude`. `Boolean` and lowercase `bool` are not valid type names. \
       The compiler offers a quick-fix that rewrites the spelling in place.";
    manual = Some "language-spec" };

  { code = "VBOOL002"; category = Naming;
    title = "missing `Bool` import";
    explanation =
      "`Bool` (and its `True`/`False` constructors) come from `Tesl.Prelude` and \
       must be imported before use: add \
       `import Tesl.Prelude exposing [Bool(..)]`.";
    manual = Some "language-spec" };

  (* ── Regex pattern literals (Tesl.Regex — see LANGUAGE-SPEC.md §21.6) ──── *)
  { code = "VREGEX001"; category = Syntax;
    title = "malformed regex pattern";
    explanation =
      "A `Tesl.Regex` pattern literal did not parse, or used a construct \
       outside Tesl's regex subset. Tesl checks pattern literals when it checks \
       the program, so a typo in a pattern is a compile error with an offset \
       rather than a runtime raise on the unlucky request. The subset is \
       literals, `.`, character classes, `\\d \\D \\w \\W \\s \\S \\b \\B`, \
       anchors, `( … )` / `(?: … )`, `|`, and `? * + {n} {n,} {n,m}`. Not in \
       the subset: backreferences, lookaround, inline flags, lazy/possessive \
       quantifiers, POSIX bracket classes, and the `\\n \\t \\r \\\\` escapes \
       (Tesl string literals already process those).";
    manual = Some "best-practices#validation-patterns" };

  { code = "VREGEX002"; category = Structure;
    title = "regex pattern is not a string literal";
    explanation =
      "Every `Tesl.Regex` function takes its pattern as the FIRST argument, and \
       that argument must be a string literal written at the call site. This is \
       deliberate and there is no dynamic-pattern escape hatch: compile-time \
       validation (VREGEX001/003/004) is only possible when the pattern is part \
       of the program, and a pattern that can come from request data is a \
       resource-exhaustion hole (a hostile pattern against friendly input is \
       just as bad as the reverse). Name the predicate rather than the pattern: \
       wrap the call in a `fn` or a `check`.";
    manual = Some "best-practices#validation-patterns" };

  { code = "VREGEX003"; category = Structure;
    title = "regex pattern can backtrack catastrophically";
    explanation =
      "The pattern parses, but its repetition is ambiguous: the same input can \
       be split across iterations in exponentially many ways, so a matcher that \
       backtracks (Racket's does) can be made to run effectively forever by a \
       short hostile input — the `(a+)+` shape. Tesl rejects these at compile \
       time. Fixes: drop one of the two quantifiers, replace an alternation \
       under a quantifier with a character class (`[ab]*` for `(?:a|b)*`), or \
       start the repeated group with a fixed separator character that cannot \
       appear in the rest of the group (`(?:-[a-z0-9]+)*` is accepted for \
       exactly that reason).";
    manual = Some "best-practices#validation-patterns" };

  { code = "VREGEX004"; category = Structure;
    title = "capture group may not participate in a match";
    explanation =
      "`Regex.captures` returns `Maybe (List String)` — one String per capture \
       group, with no inner `Maybe`. That is only honest if every capture group \
       of an accepted pattern captures text whenever the match succeeds, so \
       Tesl rejects the two shapes where it would not: a capture group under a \
       quantifier (it captures only its last repetition, or nothing at all when \
       the count is zero) and a capture group inside an alternation branch (the \
       other branch may win). Make the group non-capturing with `(?: … )`, or \
       restructure so the group is unconditional.";
    manual = Some "best-practices#validation-patterns" };

  (* ── Linter: structural file checks (E0xx) ────────────────────────────── *)
  { code = "E001"; category = Lint;
    title = "empty file";
    explanation = "The file has no content. A Tesl module needs at least a \
       `module` header.";
    manual = Some "getting-started" };
  { code = "E002"; category = Lint;
    title = "`#lang tesl` is no longer part of Tesl";
    explanation = "The historical `#lang tesl` pragma is not accepted anymore: \
       a Tesl file starts directly with its `module` header (comments may \
       precede it). Delete the `#lang` line — the diagnostic carries the edit \
       as an applicable fix.";
    manual = Some "getting-started" };
  { code = "E010"; category = Lint;
    title = "tab character";
    explanation = "Tesl source uses spaces, not tabs, for indentation. Replace \
       the tab(s) with spaces (two per level).";
    manual = Some "best-practices" };
  { code = "E030"; category = Lint;
    title = "receiver-style `.length`";
    explanation = "`.length` receiver syntax is not supported; call the \
       function form, e.g. `String.length s`.";
    manual = Some "language-spec" };
  { code = "E031"; category = Lint;
    title = "receiver-style `.startsWith`";
    explanation = "`.startsWith` receiver syntax is not supported; use the \
       function form, e.g. `String.startsWith prefix s`.";
    manual = Some "language-spec" };
  { code = "E032"; category = Lint;
    title = "receiver-style `.isEmpty`";
    explanation = "`.isEmpty` receiver syntax is not supported; use the function \
       form, e.g. `String.isEmpty s`.";
    manual = Some "language-spec" };

  (* ── Linter: style / hygiene warnings (W0xx) ──────────────────────────── *)
  { code = "W001"; category = Lint;
    title = "module header not first";
    explanation = "The `module … exposing [ … ]` header should be the first \
       non-blank, non-comment line (comments may precede it).";
    manual = Some "best-practices" };
  { code = "W002"; category = Lint;
    title = "trailing blank lines";
    explanation = "The file ends with blank lines. The formatter removes them; \
       run `tesl fmt`.";
    manual = Some "best-practices" };
  { code = "W003"; category = Lint;
    title = "multiple consecutive blank lines";
    explanation = "More than one blank line in a row. The formatter collapses \
       these; run `tesl fmt`.";
    manual = Some "best-practices" };
  { code = "W010"; category = Lint;
    title = "trailing whitespace";
    explanation = "A line has trailing spaces. The formatter strips them; run \
       `tesl fmt` (a quick-fix is offered).";
    manual = Some "best-practices" };
  { code = "W011"; category = Lint;
    title = "indentation not a multiple of 2";
    explanation = "Tesl indents in steps of two spaces. Re-indent the line or \
       run `tesl fmt`.";
    manual = Some "best-practices" };
  { code = "W020"; category = Lint;
    title = "module name not UpperCamelCase";
    explanation = "Module names use UpperCamelCase, e.g. `module TodoApi`.";
    manual = Some "best-practices" };
  { code = "W021"; category = Lint;
    title = "type name not UpperCamelCase";
    explanation = "Type, record, entity and fact names use UpperCamelCase.";
    manual = Some "best-practices" };
  { code = "W022"; category = Lint;
    title = "function name not lowerCamelCase";
    explanation = "Function, handler, check and auth names use lowerCamelCase.";
    manual = Some "best-practices" };
  { code = "W040"; category = Lint;
    title = "single-line ADT-looking type alias";
    explanation = "A one-line `type X = A | B` reads like an ADT but defines an \
       alias. Use the multi-line ADT syntax to avoid the footgun.";
    manual = Some "language-spec" };
  { code = "W041"; category = Lint;
    title = "unparenthesized lambda in argument position";
    explanation = "A bare lambda passed as an argument is ambiguous; wrap it in \
       parentheses.";
    manual = Some "language-spec" };
  { code = "W050"; category = Lint;
    title = "unused import";
    explanation = "An imported name is never used. Remove it from the `exposing` \
       list to keep imports honest. The diagnostic carries a structured fix \
       (the import rewritten without its unused names), so editors offer it \
       as a quickfix and via `source.organizeImports`.";
    manual = Some "best-practices" };
  { code = "W060"; category = Lint;
    title = "unused `let` binding";
    explanation = "A `let` binding is never read (the proof half of a \
       proof-decompose is exempted). Remove it or use it.";
    manual = Some "best-practices" };
  { code = "W061"; category = Lint;
    title = "unused function parameter";
    explanation = "A declared parameter is never used in the body. Rename it to \
       `_` if intentional.";
    manual = Some "best-practices" };
  { code = "W062"; category = Lint;
    title = "unreachable code after `fail`";
    explanation = "Statements after a `fail` can never run. Remove the dead \
       code or restructure the branch.";
    manual = Some "best-practices#error-handling" };
  { code = "W063"; category = Lint;
    title = "redundant re-check of an already-validated value (proof footgun)";
    explanation = "You are re-running a `check` on a value that already carries \
       the proof. Validate once at the boundary and pass the proof-carrying \
       value onward.";
    manual = Some "best-practices#proof-management" };
  { code = "W064"; category = Lint;
    title = "discarded `check`/`auth` validation result (proof footgun)";
    explanation = "The result of a `check`/`auth` (which carries the proof) is \
       thrown away, so the proof is lost. Bind it and use the proof-carrying \
       value.";
    manual = Some "best-practices#proof-management" };
  { code = "W070"; category = Lint;
    title = "email declared but startEmailWorker never called";
    explanation = "An email definition exists but no `startEmailWorker` call \
       wires it up, so it will never send.";
    manual = Some "best-practices" };
  { code = "W080"; category = Lint;
    title = "exported function references unexported type or proof predicate";
    explanation = "An exported function's signature mentions a type or proof \
       predicate that is not itself exported, so callers cannot name it. Export \
       the referenced name too.";
    manual = Some "best-practices#api-design" };
  { code = "W091"; category = Lint;
    title = "`Int` at a wire/serialized boundary may lose precision on JS clients";
    explanation = "JavaScript numbers are exact only up to 2^53, so a large `Int` \
       at an API request body, capture, or return type can silently lose precision \
       crossing to a JS/TS/Elm client. Use `Int32` (JS-safe, < 2^31) for bounded \
       values, or a string/BigNumber codec for genuinely large `Int`. Advisory: \
       internal/compute `Int` use is unaffected.";
    manual = Some "best-practices" };

  (* ── Linter: security (SEC0xx) ─────────────────────────────────────────────
     Their own category, deliberately, so `tesl help codes` groups them apart
     from style lints and a reader can tell "this is a security finding" from
     the code alone.  The governing rule for the category (roadmap
     tesl_crypto.md § Security lints): a check ships only if it is ACTIONABLE
     (one obvious fix), PRECISE (a clean codebase is completely silent) and
     ABOUT SOMETHING TESL CAN ENFORCE.  A noisy security lint is worse than
     none — it trains people to ignore the whole category — and there is no
     suppression mechanism yet, so a false positive cannot be silenced at all.
     Anything failing those tests belongs in the manual, not here. *)
  { code = "SEC001"; category = Security;
    title = "authorization decided by comparing request data with a string literal";
    explanation =
      "Inside an `auth` body, a value that came from the request \
       (`request.cookies`, `request.headers`, `request.queryParameters`) is \
       compared with `==`/`!=` against a string literal, and the result decides \
       whether to mint the authentication fact. The client chooses that value, \
       so the comparison proves nothing: anyone can send \
       `Cookie: user=admin`. A plaintext, guessable session cookie is not \
       authentication.\n\n\
       Authenticate with something the client cannot forge, then decide \
       authorization from the verified value:\n\
       \  - a signed session or token — `check Crypto.checkSignature key sig \
       payload` yields `Authentic payload`, and `JWT.verify` checks an \
       HMAC-signed token (see `example/learn/lesson57-jwt.tesl`);\n\
       \  - a password — `Crypto.checkPassword stored candidate` yields \
       `PasswordVerified`;\n\
       \  - an opaque random session id (`Crypto.randomToken`) looked up in \
       your session table.\n\n\
       Comparing an already-verified value against a literal is fine and does \
       NOT fire: the lint stops tracking a value once it has passed through \
       `Crypto.checkSignature`, `Crypto.checkPassword`, `JWT.verify` or a \
       `check`/`auth` call.";
    manual = Some "best-practices#security" };

  { code = "SEC003"; category = Security;
    title = "hardcoded secret — a string literal used as key material";
    explanation =
      "A string literal is being used as key material: either `Secret \"…\"` \
       directly, or a literal in the key position of `Crypto.signWith` / \
       `Crypto.checkSignature` / `Crypto.keyFingerprint` / \
       `Crypto.hmacSha256`. A key committed to the repository is readable by \
       everyone who can read the source, survives in git history after it is \
       changed, and is identical across every deployment.\n\n\
       Read it from the environment instead — `Secret (requireEnv \
       \"SESSION_SIGNING_KEY\")` — and rotate it there. This is a STRUCTURAL \
       check (a literal in a key position), not entropy guessing: Tesl \
       deliberately does not scan string literals for high-entropy-looking \
       content, because that lint cannot be made quiet.";
    manual = Some "best-practices#security" };

  { code = "SEC004"; category = Security;
    title = "timing-unsafe MAC comparison via `Crypto.signatureHex`";
    explanation =
      "A `Crypto.signatureHex` result is being compared with `==`/`!=`. That \
       is a hand-rolled message-authentication check, and `==` on `String` \
       short-circuits at the first differing byte, so how long the comparison \
       takes leaks how much of the correct tag the caller guessed — enough to \
       recover a valid tag byte by byte without ever knowing the key.\n\n\
       `Crypto.signatureHex` exists only to TRANSPORT a tag (put it in a \
       header, read one out of a header). Verify with \
       `check Crypto.checkSignature key sig payload`, which compares in \
       constant time and yields an `Authentic payload` fact that downstream \
       code can demand — a `Bool` can be ignored or inverted, a fact cannot. \
       For an inbound hex tag, parse it first with \
       `Crypto.signatureFromHex`.\n\n\
       This is why `Signature` has no `==` of its own: the only legitimate \
       comparison of two tags IS a verification.";
    manual = Some "best-practices#security" };

  { code = "SEC005"; category = Security;
    title = "state-changing capability in a GET route";
    explanation =
      "A handler bound to a GET endpoint (transitively) reaches a \
       state-changing capability — `dbWrite`, `queueWrite`, `pubsub` or \
       `emailCap`. A GET must be SAFE and idempotent: HTTP caches, \
       prefetchers, link crawlers and `<img>`/`<link>` tags all issue GETs \
       without user intent, so a write behind one runs on traffic the user \
       never authorised. This is HTTP's own rule, not a Tesl invention (GET is \
       \"safe\" per RFC 9110 section 9.2.1).\n\n\
       It is also the one method a `SameSite=Lax` session cookie is still sent \
       on: the browser DOES attach a Lax cookie to a cross-site TOP-LEVEL GET \
       navigation. So a mutating GET is a CSRF hole an attacker triggers just \
       by navigating the victim's browser to the URL. Every other CSRF vector \
       is already closed by construction — the 415 on non-`application/json` \
       request bodies, no CORS headers on JSON routes, parameterised SQL — \
       which is exactly why this one is enforced.\n\n\
       `emailCap` is included because a GET that sends mail is a cross-site \
       SPAM vector reached the same way. Reads are fine (`dbRead`, \
       `queueRead`): a GET reads. Telemetry is ambient and out of scope. Cache \
       is out of scope too — `cacheCap` has no read/write split, and filling a \
       cache during a GET is response caching, the canonical benign read-path \
       mutation.\n\n\
       Move the mutation to a POST/PUT/PATCH/DELETE endpoint, or take the \
       write out of the GET handler. If you need a read-audit trail, record it \
       through telemetry, or accept the write on a POST.";
    manual = Some "best-practices#security" };
]

(* ── Lookup helpers ───────────────────────────────────────────────────────── *)

let lookup (code : string) : entry option =
  List.find_opt (fun e -> e.code = code) registry

let all_codes () : string list = List.map (fun e -> e.code) registry

(* Case-insensitive substring test (no Str dependency). *)
let contains_ci ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  if n = 0 then true
  else if n > h then false
  else begin
    let lc s = String.lowercase_ascii s in
    let needle = lc needle and haystack = lc haystack in
    let rec at i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else at (i + 1)
    in
    at 0
  end

(** Pick the most relevant manual anchor for a rendered diagnostic.

    For most codes this is simply the registry's [manual] field.  The broad
    validation code [V001] tags a whole family of rules; each rule's anchor is
    decided by the STRUCTURED [topic] the producing validation pass stamped on
    the error (see {!manual_topic}), resolved by the single total
    {!anchor_of_topic} map.  Message text is NOT consulted — decide-by-resolution,
    not decide-by-spelling — so the same rule always links to the same section
    regardless of what user identifiers happen to be spelled in the message.

    When no topic is supplied (e.g. `tesl help V001` with no live diagnostic),
    V001 falls back to the registry's topic-less default, which is the same
    anchor as {!TGeneric}. *)
let manual_for ?(topic : manual_topic option) ~(code : string) ~(message : string) () : string option =
  ignore message;  (* message text no longer routes the anchor (B5) *)
  match code, topic with
  | "V001", Some t -> Some (anchor_of_topic t)
  | _ -> (match lookup code with Some e -> e.manual | None -> None)

(** A multi-line explanation block for `tesl help <code>` / `tesl explain <code>`.
    Returns [None] for an unknown code. The [manual] argument, when given, lets
    the caller render the message-refined anchor instead of the registry default
    (used by the CLI so `tesl help <code>` and a live diagnostic agree). *)
let explain ?manual (code : string) : string option =
  match lookup code with
  | None -> None
  | Some e ->
    let buf = Buffer.create 256 in
    Buffer.add_string buf (Printf.sprintf "%s  [%s]\n" e.code (category_name e.category));
    Buffer.add_string buf (Printf.sprintf "  %s\n\n" e.title);
    Buffer.add_string buf (e.explanation);
    Buffer.add_char buf '\n';
    let anchor = match manual with Some _ as m -> m | None -> e.manual in
    (match anchor with
     | Some a ->
       Buffer.add_string buf
         (Printf.sprintf "\nread more: tesl help manual %s\n" a)
     | None -> ());
    Some (Buffer.contents buf)

(** One-line summary used by `tesl help codes` (the index). *)
let summary_line (e : entry) : string =
  Printf.sprintf "  %-9s %-11s %s" e.code ("(" ^ category_name e.category ^ ")") e.title

(** The full `tesl help codes` index, grouped by category in registry order. *)
let index () : string =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf "Tesl diagnostic codes\n";
  Buffer.add_string buf "=====================\n\n";
  Buffer.add_string buf
    "Every code the compiler and linter can emit. Run `tesl help <code>` (or\n\
     `tesl explain <code>`) for a full explanation and a manual deep-link.\n\n";
  (* NOTE: this list is the ONE silent coupling in this module — [category_name]
     is exhaustive so the compiler forces a new constructor to be named there,
     but a category omitted HERE simply never appears in `tesl help codes` while
     `tesl explain <code>` keeps working. Keep it in sync with the variant. *)
  let cats = [ Syntax; Type; Proof; Capability; Structure; Codec; Naming;
               Security; Lint ] in
  List.iter (fun cat ->
    let rows = List.filter (fun e -> e.category = cat) registry in
    if rows <> [] then begin
      Buffer.add_string buf (Printf.sprintf "%s:\n" (String.uppercase_ascii (category_name cat)));
      List.iter (fun e -> Buffer.add_string buf (summary_line e ^ "\n")) rows;
      Buffer.add_char buf '\n'
    end
  ) cats;
  Buffer.contents buf

(** Turn a Markdown heading's text into its anchor slug (D16 — the SINGLE source
    of the slug rule for lib-linked consumers).  Lower-case; keep [a-z0-9]; map
    ' '/'-' to a space; drop everything else (punctuation, emoji, UTF-8 bytes);
    collapse runs of spaces to a single '-'; trim.  Mirrors manual/anchors.md.
    [compiler/bin/main.ml] and [compiler/test/test_error_codes.ml] both call this
    so the rule cannot drift between the diagnostic deep-links and the anchor test.
    (manual/tests/test_embedded_docs.ml deliberately links only str/unix — no
    compiler lib — so it keeps its own byte-identical mirror; that mirror names
    THIS function as its source of truth.) *)
let slug_of_heading (heading : string) : string =
  let b = Buffer.create (String.length heading) in
  String.iter
    (fun c ->
       let c = Char.lowercase_ascii c in
       if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then Buffer.add_char b c
       else if c = ' ' || c = '-' then Buffer.add_char b ' ')
    heading;
  String.split_on_char ' ' (Buffer.contents b)
  |> List.filter (fun s -> s <> "")
  |> String.concat "-"
