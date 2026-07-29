(** Hand-authored data rows for {!Stdlib_docs} — no logic here.

    Each row supplies what cannot be derived mechanically: PARAMETER NAMES for
    functions (their types render live from {!Type_system.stdlib_env}), full
    Tesl declarations for types/ADTs/facts, and signature sketches for
    compiler-lowered syntax forms.  One-line docs everywhere.

    test_stdlib_docs.ml enforces coverage (every stdlib export documented) and
    arity (param-name count = scheme arity), so this file cannot silently rot. *)

type kind =
  | KFunction of string list
  | KValue
  | KType of string
  | KFact of string
  | KSyntax of string
  | KCapability
  | KConfig
  | KFamily of string

type entry = {
  name : string;
  module_ : string;
  kind : kind;
  doc : string;
  aliases : string list;
}

let e ?(aliases = []) ~m ~kind ~doc name =
  { name; module_ = m; kind; doc; aliases }

(* fn with parameter names — the common row *)
let f ?(aliases = []) ~m ~doc name params =
  e ~aliases ~m ~kind:(KFunction params) ~doc name

let v ?(aliases = []) ~m ~doc name = e ~aliases ~m ~kind:KValue ~doc name

(* ── Always available (no import) ──────────────────────────────────────────── *)

let ambient : entry list = [
  f "+" [ "a"; "b" ] ~m:"" ~doc:"Integer addition (Float.add / Money.add / unit-aware + exist for other numeric types).";
  f "-" [ "a"; "b" ] ~m:"" ~doc:"Integer subtraction.";
  f "*" [ "a"; "b" ] ~m:"" ~doc:"Integer multiplication.";
  f "/" [ "a"; "b" ] ~m:"" ~doc:"Integer division (truncating); see Int.divide for a checked version.";
  f "%" [ "a"; "b" ] ~m:"" ~doc:"Integer remainder.";
  f "quotient" [ "a"; "b" ] ~m:"" ~doc:"Integer quotient (same as /).";
  f "modulo" [ "a"; "b" ] ~m:"" ~doc:"Mathematical modulo (result has the divisor's sign).";
  f "==" [ "a"; "b" ] ~m:"" ~doc:"Structural equality.";
  f "!=" [ "a"; "b" ] ~m:"" ~doc:"Structural inequality.";
  f "<" [ "a"; "b" ] ~m:"" ~doc:"Ordered comparison.";
  f "<=" [ "a"; "b" ] ~m:"" ~doc:"Ordered comparison.";
  f ">" [ "a"; "b" ] ~m:"" ~doc:"Ordered comparison.";
  f ">=" [ "a"; "b" ] ~m:"" ~doc:"Ordered comparison.";
  f "&&" [ "a"; "b" ] ~m:"" ~doc:"Logical and (short-circuiting).";
  f "||" [ "a"; "b" ] ~m:"" ~doc:"Logical or (short-circuiting).";
  f "!" [ "b" ] ~m:"" ~doc:"Logical negation.";
  f "not" [ "b" ] ~m:"" ~doc:"Logical negation (function form of !).";
  v "True" ~m:"" ~doc:"Boolean truth (constructor of Bool).";
  v "False" ~m:"" ~doc:"Boolean falsity (constructor of Bool).";
  v "Unit" ~m:"" ~doc:"The unit value/type — a function that returns nothing meaningful returns Unit.";
  e "check" ~m:"" ~kind:(KSyntax "let validated = check checkFn value   # runs a `check` function; fails the request on reject")
    ~doc:"Applies a check function to a value, yielding the proof-carrying result.";
  f "identity" [ "x" ] ~m:"" ~doc:"Returns its argument unchanged.";
  f "const" [ "x"; "ignored" ] ~m:"" ~doc:"Returns its first argument, ignoring the second.";
  f "print" [ "value" ] ~m:"" ~doc:"Prints a value to stdout (debugging aid).";
  f "forgetFact" [ "proven" ] ~m:"" ~doc:"Drops the proof from a proven value, keeping the raw value.";
  f "detachFact" [ "proven" ] ~m:"" ~doc:"Extracts the Fact from a proven value (value stays usable).";
  f "attachFact" [ "value"; "fact" ] ~m:"" ~doc:"Re-attaches a detached Fact to a value of the right type.";
  f "andLeft" [ "conj" ] ~m:"" ~doc:"Projects the left conjunct of a conjunction Fact.";
  f "andRight" [ "conj" ] ~m:"" ~doc:"Projects the right conjunct of a conjunction Fact.";
  f "introAnd" [ "left"; "right" ] ~m:"" ~doc:"Combines two Facts about the same subject into a conjunction.";
]

(* ── Tesl.Prelude ──────────────────────────────────────────────────────────── *)

let prelude : entry list = [
  e "Bool" ~m:"Tesl.Prelude" ~kind:(KType "type Bool = True | False") ~doc:"Booleans.";
  e "Int" ~m:"Tesl.Prelude" ~kind:(KType "type Int   # arbitrary-precision integer") ~doc:"Integers (arbitrary precision).";
  e "String" ~m:"Tesl.Prelude" ~kind:(KType "type String   # immutable UTF-8 text") ~doc:"Immutable text.";
  e "List" ~m:"Tesl.Prelude" ~kind:(KType "type List a   # e.g. List Int; literals: [1, 2, 3]") ~doc:"Homogeneous immutable lists.";
  e "Unit" ~m:"Tesl.Prelude" ~kind:(KType "type Unit   # the single no-information value") ~doc:"The unit type." ~aliases:[];
  e "Fact" ~m:"Tesl.Prelude" ~kind:(KType "type Fact p   # a detached compile-time proof, e.g. Fact (Positive n)") ~doc:"A first-class (erased) proof value; see detachFact/attachFact.";
  e "Any" ~m:"Tesl.Prelude" ~kind:(KType "type Any   # top type; escape hatch for interop, avoid in app code") ~doc:"Top type (interop escape hatch).";
  e "Bytes" ~m:"Tesl.Prelude" ~kind:(KType "type Bytes") ~doc:"Raw byte strings.";
  e "Char" ~m:"Tesl.Prelude" ~kind:(KType "type Char") ~doc:"A single character.";
  e "Hash" ~m:"Tesl.Prelude" ~kind:(KType "type Hash k v   # low-level hash (prefer Dict)") ~doc:"Low-level hash table (prefer Dict).";
  e "Keyword" ~m:"Tesl.Prelude" ~kind:(KType "type Keyword") ~doc:"Racket keyword (interop).";
  e "Integer" ~m:"Tesl.Prelude" ~kind:(KType "type Integer   # alias of Int") ~doc:"Alias of Int.";
  e "Null" ~m:"Tesl.Prelude" ~kind:(KType "type Null") ~doc:"The null type (interop; prefer Maybe).";
  e "Number" ~m:"Tesl.Prelude" ~kind:(KType "type Number   # Int or Float") ~doc:"Numeric supertype (interop).";
  e "Real" ~m:"Tesl.Prelude" ~kind:(KType "type Real   # alias of Float") ~doc:"Alias of Float.";
  e "Symbol" ~m:"Tesl.Prelude" ~kind:(KType "type Symbol") ~doc:"Racket symbol (interop).";
  e "Vector" ~m:"Tesl.Prelude" ~kind:(KType "type Vector a") ~doc:"Fixed-size vector (interop; prefer List).";
  e "int" ~m:"Tesl.Prelude" ~kind:(KType "type int   # lowercase alias of Int (interop)") ~doc:"Alias of Int.";
  e "integer" ~m:"Tesl.Prelude" ~kind:(KType "type integer   # lowercase alias of Int (interop)") ~doc:"Alias of Int.";
  e "string" ~m:"Tesl.Prelude" ~kind:(KType "type string   # lowercase alias of String (interop)") ~doc:"Alias of String.";
  (* True/False/Unit + fact combinators documented in [ambient]; the exposing
     list re-exports them, aliased here so `tesl doc Tesl.Prelude` shows them. *)
]

(* ── Tesl.Email ────────────────────────────────────────────────────────────── *)

let email : entry list = [
  e "EmailBody" ~m:"Tesl.Email"
    ~kind:(KType "type EmailBody = TextBody String | HtmlBody String | RichBody String String")
    ~doc:"An email body — plain text, HTML, or both (RichBody plainText html; recommended)."
    ~aliases:[ "TextBody"; "HtmlBody"; "RichBody" ];
  e "Email.send" ~m:"Tesl.Email"
    ~kind:(KSyntax "Email.send <EmailName> { to: String, subject: String, body: EmailBody } : Unit   # requires [emailCap]")
    ~doc:"Queues an email in the outbox table inside the current transaction (non-blocking; delivered by a background worker).";
  e "startEmailWorker" ~m:"Tesl.Email"
    ~kind:(KSyntax "startEmailWorker <EmailName> : Unit   # requires [emailCap]; usually implicit via App.email")
    ~doc:"Starts the SMTP delivery worker for an email block (listing the block in App.email does this automatically).";
]

(* ── Tesl.Maybe / Tesl.Result ──────────────────────────────────────────────── *)

let maybe_result : entry list = [
  e "Maybe" ~m:"Tesl.Maybe"
    ~kind:(KType "type Maybe a = Something a | Nothing")
    ~doc:"An optional value." ~aliases:[ "Something"; "Nothing" ];
  e "Result" ~m:"Tesl.Result"
    ~kind:(KType "type Result e a = Ok a | Err e")
    ~doc:"Success (Ok) or failure (Err)." ~aliases:[ "Ok"; "Err" ];
]

(* ── Tesl.Time ─────────────────────────────────────────────────────────────── *)

let time : entry list = [
  e "PosixMillis" ~m:"Tesl.Time"
    ~kind:(KType "type PosixMillis   # newtype over Int: milliseconds since the Unix epoch (UTC)")
    ~doc:"A point in time as epoch milliseconds; the canonical Tesl timestamp.";
  v "nowMillis" ~m:"Tesl.Time" ~doc:"The current time (epoch milliseconds).";
  f "formatTime" [ "t"; "zone"; "format" ] ~m:"Tesl.Time" ~doc:"Formats a PosixMillis with a strftime-style pattern in a named zone.";
  f "durationMs" [ "start" ] ~m:"Tesl.Time" ~doc:"Milliseconds elapsed since the given timestamp (reads the clock).";
  f "addMs" [ "t"; "ms" ] ~m:"Tesl.Time" ~doc:"Adds milliseconds to a timestamp.";
  f "subtractMs" [ "t"; "ms" ] ~m:"Tesl.Time" ~doc:"Subtracts milliseconds from a timestamp.";
  f "diffMs" [ "a"; "b" ] ~m:"Tesl.Time" ~doc:"Signed difference a - b in milliseconds.";
  f "Time.posixToSeconds" [ "t" ] ~m:"Tesl.Time" ~doc:"Epoch milliseconds to whole epoch seconds.";
  f "Time.secondsToPosix" [ "seconds" ] ~m:"Tesl.Time" ~doc:"Whole epoch seconds to PosixMillis.";
  f "Time.truncHour" [ "zone"; "t" ] ~m:"Tesl.Time" ~doc:"Truncates to the start of the hour in the given TimeZone.";
  f "Time.truncDay" [ "zone"; "t" ] ~m:"Tesl.Time" ~doc:"Truncates to local midnight in the given TimeZone (DST-correct).";
  f "Time.truncWeek" [ "zone"; "t" ] ~m:"Tesl.Time" ~doc:"Truncates to the start of the ISO week (Monday) in the given TimeZone.";
  f "Time.truncMonth" [ "zone"; "t" ] ~m:"Tesl.Time" ~doc:"Truncates to the first of the month in the given TimeZone.";
  f "Time.truncYear" [ "zone"; "t" ] ~m:"Tesl.Time" ~doc:"Truncates to January 1st in the given TimeZone.";
  f "Time.offsetAt" [ "zone"; "t" ] ~m:"Tesl.Time" ~doc:"UTC offset in minutes that the zone applies at instant t (DST-aware).";
  f "Time.add" [ "t"; "d" ] ~m:"Tesl.Time" ~doc:"Adds a typed Duration to a timestamp.";
  f "Time.subtract" [ "t"; "d" ] ~m:"Tesl.Time" ~doc:"Subtracts a typed Duration from a timestamp.";
  f "Time.diff" [ "a"; "b" ] ~m:"Tesl.Time" ~doc:"Difference of two timestamps as a typed Duration.";
  (* TimeZone family entry lives in Stdlib_docs.family_entries; the `time`
     capability entry is generated from the provider table. *)
  e "Utc" ~m:"Tesl.Time" ~kind:(KType "Utc : TimeZone") ~doc:"The UTC time zone constructor.";
  e "FixedOffset" ~m:"Tesl.Time" ~kind:(KType "FixedOffset <minutes> : TimeZone") ~doc:"A fixed UTC-offset zone (no DST), offset in minutes.";
]

(* ── Tesl.Int32 ────────────────────────────────────────────────────────────── *)

let int32 : entry list = [
  e "Int32" ~m:"Tesl.Int32"
    ~kind:(KType "type Int32   # nominal 32-bit-range integer for wire/storage boundaries; does NOT unify with Int")
    ~doc:"A JS-safe bounded integer boundary type; convert with Int32.fromInt / Int32.toInt.";
  f "Int32.fromInt" [ "n" ] ~m:"Tesl.Int32" ~doc:"Checked narrowing: Something for values in 32-bit range, Nothing otherwise.";
  f "Int32.toInt" [ "n32" ] ~m:"Tesl.Int32" ~doc:"Total widening of an Int32 back to Int.";
]

(* ── Tesl.DB (DeleteResult; dbRead/dbWrite are generated capability rows) ──── *)

let db : entry list = [
  e "DeleteResult" ~m:"Tesl.DB"
    ~kind:(KType "type DeleteResult = NoRowDeleted | RowsDeleted Int")
    ~doc:"Result of `deleteAndReturnResult` — whether (and how many) rows were deleted.";
  v "NoRowDeleted" ~m:"Tesl.DB" ~doc:"DeleteResult constructor: no rows matched the delete.";
  f "RowsDeleted" [ "count" ] ~m:"Tesl.DB" ~doc:"DeleteResult constructor: count rows were deleted.";
]

(* ── Tesl.EitherPrim / Tesl.Either ─────────────────────────────────────────── *)

let either : entry list = [
  e "Either" ~m:"Tesl.EitherPrim"
    ~kind:(KType "type Either a b = Left a | Right b")
    ~doc:"A two-alternative sum type; Tesl.EitherPrim is the constructor-only leaf module — import Tesl.Either for the combinators.";
  f "Left" [ "value" ] ~m:"Tesl.Either" ~doc:"Either constructor: the left (conventionally error) side.";
  f "Right" [ "value" ] ~m:"Tesl.Either" ~doc:"Either constructor: the right (conventionally success) side.";
  (* Combinators are lifted to tesl/either.tesl (types load from that source,
     not stdlib_env), so their signatures are sketched from it verbatim. *)
  e "Either.isLeft" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.isLeft(x: Either a b) -> Bool") ~doc:"True when x is a Left.";
  e "Either.isRight" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.isRight(x: Either a b) -> Bool") ~doc:"True when x is a Right.";
  e "Either.fromLeft" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.fromLeft(x: Either a b) -> Maybe a") ~doc:"The Left value, if any.";
  e "Either.fromRight" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.fromRight(x: Either a b) -> Maybe b") ~doc:"The Right value, if any.";
  e "Either.map" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.map(f: b -> c, x: Either a b) -> Either a c") ~doc:"Maps the Right value; passes a Left through unchanged.";
  e "Either.mapLeft" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.mapLeft(f: a -> c, x: Either a b) -> Either c b") ~doc:"Maps the Left value; passes a Right through unchanged.";
  e "Either.andThen" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.andThen(f: b -> Either a c, x: Either a b) -> Either a c") ~doc:"Chains a Right into f; passes a Left through (monadic bind).";
  e "Either.withDefault" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.withDefault(default: b, x: Either a b) -> b") ~doc:"The Right value, or default when x is a Left.";
  e "Either.toMaybe" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.toMaybe(x: Either a b) -> Maybe b") ~doc:"Something for a Right, Nothing for a Left.";
  e "Either.fromMaybe" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.fromMaybe(leftVal: a, m: Maybe b) -> Either a b") ~doc:"Right for Something, Left leftVal for Nothing.";
  e "Either.partition" ~m:"Tesl.Either" ~kind:(KSyntax "fn Either.partition(eithers: List (Either a b)) -> List (List Any)   # [lefts, rights]") ~doc:"Splits a list of Eithers into its Left values and Right values.";
]

(* ── Tesl.String ───────────────────────────────────────────────────────────── *)

let string_ : entry list = [
  e "IsTrimmed" ~m:"Tesl.String" ~kind:(KFact "fact IsTrimmed (s: String)")
    ~doc:"The string has no leading/trailing whitespace; minted by String.trim / trimLeft / trimRight.";
  e "IsUpperCase" ~m:"Tesl.String" ~kind:(KFact "fact IsUpperCase (s: String)")
    ~doc:"The string is entirely uppercase; minted by String.toUpper.";
  e "IsLowerCase" ~m:"Tesl.String" ~kind:(KFact "fact IsLowerCase (s: String)")
    ~doc:"The string is entirely lowercase; minted by String.toLower.";
  e "IsNonEmpty" ~m:"Tesl.String" ~kind:(KFact "fact IsNonEmpty (s: String)")
    ~doc:"The string is non-empty; minted by String.requireNonEmpty.";
  (* Rows with a live stdlib_env scheme *)
  f "String.length" [ "s" ] ~m:"Tesl.String" ~doc:"Number of characters.";
  f "String.concat" [ "a"; "b" ] ~m:"Tesl.String" ~doc:"Concatenates two strings.";
  f "String.join" [ "strs"; "sep" ] ~m:"Tesl.String" ~doc:"Joins a list of strings with a separator.";
  f "String.split" [ "s"; "sep" ] ~m:"Tesl.String" ~doc:"Splits on a separator string.";
  f "String.trim" [ "s" ] ~m:"Tesl.String" ~doc:"Removes leading and trailing whitespace (mints IsTrimmed).";
  f "String.toLower" [ "s" ] ~m:"Tesl.String" ~doc:"Lowercases the string (mints IsLowerCase).";
  f "String.toUpper" [ "s" ] ~m:"Tesl.String" ~doc:"Uppercases the string (mints IsUpperCase).";
  f "String.startsWith" [ "s"; "prefix" ] ~m:"Tesl.String" ~doc:"True when s starts with prefix.";
  f "String.endsWith" [ "s"; "suffix" ] ~m:"Tesl.String" ~doc:"True when s ends with suffix.";
  f "String.contains" [ "s"; "sub" ] ~m:"Tesl.String" ~doc:"True when s contains sub.";
  f "String.replace" [ "s"; "from"; "to" ] ~m:"Tesl.String" ~doc:"Replaces every occurrence of from with to.";
  f "String.toInt" [ "s" ] ~m:"Tesl.String" ~doc:"Parses an integer; Nothing on malformed input.";
  f "String.fromInt" [ "n" ] ~m:"Tesl.String" ~doc:"Renders an Int as a String.";
  (* Rows typed outside stdlib_env (runtime: tesl/string.rkt) *)
  e "String.isEmpty" ~m:"Tesl.String" ~kind:(KSyntax "fn String.isEmpty(s: String) -> Bool") ~doc:"True when the string has length 0.";
  e "String.trimLeft" ~m:"Tesl.String" ~kind:(KSyntax "fn String.trimLeft(s: String) -> String ? IsTrimmed") ~doc:"Removes leading whitespace.";
  e "String.trimRight" ~m:"Tesl.String" ~kind:(KSyntax "fn String.trimRight(s: String) -> String ? IsTrimmed") ~doc:"Removes trailing whitespace.";
  e "String.slice" ~m:"Tesl.String" ~kind:(KSyntax "fn String.slice(s: String, start: Int, end: Int) -> String") ~doc:"Substring from start (inclusive) to end (exclusive).";
  e "String.repeat" ~m:"Tesl.String" ~kind:(KSyntax "fn String.repeat(s: String, n: Int) -> String") ~doc:"Repeats the string n times.";
  e "String.reverse" ~m:"Tesl.String" ~kind:(KSyntax "fn String.reverse(s: String) -> String") ~doc:"Reverses the characters.";
  e "String.toFloat" ~m:"Tesl.String" ~kind:(KSyntax "fn String.toFloat(s: String) -> Maybe Float") ~doc:"Parses a float; Nothing on malformed input.";
  e "String.fromFloat" ~m:"Tesl.String" ~kind:(KSyntax "fn String.fromFloat(f: Float) -> String") ~doc:"Renders a Float as a String.";
  e "String.lines" ~m:"Tesl.String" ~kind:(KSyntax "fn String.lines(s: String) -> List String") ~doc:"Splits on newlines.";
  e "String.words" ~m:"Tesl.String" ~kind:(KSyntax "fn String.words(s: String) -> List String") ~doc:"Splits on runs of whitespace.";
  e "String.padLeft" ~m:"Tesl.String" ~kind:(KSyntax "fn String.padLeft(s: String, width: Int, char: String) -> String") ~doc:"Left-pads to width with the given character.";
  e "String.padRight" ~m:"Tesl.String" ~kind:(KSyntax "fn String.padRight(s: String, width: Int, char: String) -> String") ~doc:"Right-pads to width with the given character.";
  e "String.dropPrefix" ~m:"Tesl.String" ~kind:(KSyntax "fn String.dropPrefix(s: String, prefix: String) -> String") ~doc:"Removes prefix when present, otherwise returns s unchanged.";
  e "String.dropSuffix" ~m:"Tesl.String" ~kind:(KSyntax "fn String.dropSuffix(s: String, suffix: String) -> String") ~doc:"Removes suffix when present, otherwise returns s unchanged.";
  e "String.indexOf" ~m:"Tesl.String" ~kind:(KSyntax "fn String.indexOf(s: String, sub: String) -> Maybe Int") ~doc:"Index of the first occurrence of sub, or Nothing.";
  e "String.requireNonEmpty" ~m:"Tesl.String"
    ~kind:(KSyntax "check String.requireNonEmpty(s: String) -> s: String ::: IsNonEmpty s")
    ~doc:"Check function: passes non-empty strings, minting IsNonEmpty.";
]

(* ── Tesl.List / Tesl.ListPrim ─────────────────────────────────────────────── *)
(* The pure combinators are lifted to tesl/list.tesl (the checker loads their
   types from that source, not stdlib_env), so those rows carry the signature
   verbatim.  Only sort/sortBy and the check/ForAll machinery stay in
   stdlib_env and render live. *)

let list_ : entry list = [
  e "IsSorted" ~m:"Tesl.List" ~kind:(KFact "fact IsSorted (xs: List a)")
    ~doc:"The list is sorted ascending; minted by List.sort / List.sortBy.";
  f "List.sort" [ "xs" ] ~m:"Tesl.List" ~doc:"Sorts ascending (mints IsSorted).";
  f "List.sortBy" [ "key"; "xs" ] ~m:"Tesl.List" ~doc:"Sorts ascending by a key function (mints IsSorted).";
  f "List.filterCheck" [ "checkFn"; "xs" ] ~m:"Tesl.List" ~doc:"Keeps the elements that pass a check function, with their proof attached.";
  f "List.allCheck" [ "checkFn"; "xs" ] ~m:"Tesl.List" ~doc:"Applies a check to every element: Something (list ::: ForAll P) if all pass, Nothing otherwise.";
  f "List.emptyForAll" [ "checkFn" ] ~m:"Tesl.List" ~doc:"The empty list carrying a vacuous ForAll proof for the given check.";
  e "List.map" ~m:"Tesl.List" ~kind:(KSyntax "fn List.map(f: (a -> b requires c), xs: List a) -> List b requires c") ~doc:"Applies f to every element.";
  e "List.filter" ~m:"Tesl.List" ~kind:(KSyntax "fn List.filter(pred: (a -> Bool requires c), xs: List a) -> List a requires c") ~doc:"Keeps the elements satisfying pred.";
  e "List.filterMap" ~m:"Tesl.List" ~kind:(KSyntax "fn List.filterMap(f: (a -> Maybe b requires c), xs: List a) -> List b requires c") ~doc:"Maps and drops the Nothing results in one pass.";
  e "List.foldl" ~m:"Tesl.List" ~kind:(KSyntax "fn List.foldl(f: (b -> a -> b requires c), acc: b, xs: List a) -> b requires c") ~doc:"Left fold: threads acc through xs front to back.";
  e "List.foldr" ~m:"Tesl.List" ~kind:(KSyntax "fn List.foldr(f: (a -> b -> b requires c), acc: b, xs: List a) -> b requires c") ~doc:"Right fold: threads acc through xs back to front.";
  e "List.length" ~m:"Tesl.List" ~kind:(KSyntax "fn List.length(xs: List a) -> Int") ~doc:"Number of elements.";
  e "List.isEmpty" ~m:"Tesl.List" ~kind:(KSyntax "fn List.isEmpty(xs: List a) -> Bool") ~doc:"True when the list has no elements.";
  e "List.head" ~m:"Tesl.List" ~kind:(KSyntax "fn List.head(xs: List a) -> Maybe a") ~doc:"The first element, if any.";
  e "List.tail" ~m:"Tesl.List" ~kind:(KSyntax "fn List.tail(xs: List a) -> Maybe (List a)") ~doc:"Everything after the first element, if any.";
  e "List.last" ~m:"Tesl.List" ~kind:(KSyntax "fn List.last(xs: List a) -> Maybe a") ~doc:"The last element, if any.";
  e "List.nth" ~m:"Tesl.List" ~kind:(KSyntax "fn List.nth(xs: List a, i: Int) -> Maybe a") ~doc:"The element at index i (0-based), if in range.";
  e "List.append" ~m:"Tesl.List" ~kind:(KSyntax "fn List.append(xs: List a, ys: List a) -> List a") ~doc:"Concatenates two lists.";
  e "List.concat" ~m:"Tesl.List" ~kind:(KSyntax "fn List.concat(xss: List (List a)) -> List a") ~doc:"Flattens one level of nesting.";
  e "List.concatMap" ~m:"Tesl.List" ~kind:(KSyntax "fn List.concatMap(f: (a -> List b requires c), xs: List a) -> List b requires c") ~doc:"Maps each element to a list, then flattens one level (flatMap).";
  e "List.reverse" ~m:"Tesl.List" ~kind:(KSyntax "fn List.reverse(xs: List a) -> List a") ~doc:"Reverses the list.";
  e "List.contains" ~m:"Tesl.List" ~kind:(KSyntax "fn List.contains(x: a, xs: List a) -> Bool") ~doc:"True when x is an element of xs (structural equality).";
  e "List.member" ~m:"Tesl.List" ~kind:(KSyntax "fn List.member(x: a, xs: List a) -> Bool") ~doc:"True when x is an element of xs (structural equality; same as contains).";
  e "List.find" ~m:"Tesl.List" ~kind:(KSyntax "fn List.find(pred: (a -> Bool requires c), xs: List a) -> Maybe a requires c") ~doc:"The first element satisfying pred, if any.";
  e "List.findIndex" ~m:"Tesl.List" ~kind:(KSyntax "fn List.findIndex(pred: (a -> Bool requires c), xs: List a) -> Maybe Int requires c") ~doc:"Index of the first element satisfying pred, if any.";
  e "List.take" ~m:"Tesl.List" ~kind:(KSyntax "fn List.take(n: Int, xs: List a) -> List a") ~doc:"The first n elements (n must be non-negative).";
  e "List.drop" ~m:"Tesl.List" ~kind:(KSyntax "fn List.drop(n: Int, xs: List a) -> List a") ~doc:"Everything after the first n elements (n must be non-negative).";
  e "List.zip" ~m:"Tesl.List" ~kind:(KSyntax "fn List.zip(xs: List a, ys: List b) -> List (Tuple2 a b)") ~doc:"Pairs elements positionally; stops at the shorter list.";
  e "List.zipWith" ~m:"Tesl.List" ~kind:(KSyntax "fn List.zipWith(f: ((a, b) -> d requires c), xs: List a, ys: List b) -> List d requires c") ~doc:"Combines elements positionally with f; stops at the shorter list.";
  e "List.unzip" ~m:"Tesl.List" ~kind:(KSyntax "fn List.unzip(pairs: List (List Any)) -> List (List Any)   # [firsts, seconds]") ~doc:"Splits a list of pairs into the list of firsts and the list of seconds.";
  e "List.flatten" ~m:"Tesl.List" ~kind:(KSyntax "fn List.flatten(xss: List (List a)) -> List a") ~doc:"Flattens one level of nesting (same as concat).";
  e "List.dedupe" ~m:"Tesl.List" ~kind:(KSyntax "fn List.dedupe(xs: List a) -> List a") ~doc:"Removes consecutive duplicate elements.";
  e "List.unique" ~m:"Tesl.List" ~kind:(KSyntax "fn List.unique(xs: List a) -> List a") ~doc:"Removes duplicate elements, keeping first occurrences.";
  e "List.range" ~m:"Tesl.List" ~kind:(KSyntax "fn List.range(start: Int, end: Int) -> List Int") ~doc:"Integers from start (inclusive) to end (exclusive).";
  e "List.repeat" ~m:"Tesl.List" ~kind:(KSyntax "fn List.repeat(x: a, n: Int) -> List a") ~doc:"A list of n copies of x (n must be non-negative).";
  e "List.sum" ~m:"Tesl.List" ~kind:(KSyntax "fn List.sum(xs: List Int) -> Int") ~doc:"Sum of the elements (0 for the empty list).";
  e "List.product" ~m:"Tesl.List" ~kind:(KSyntax "fn List.product(xs: List Int) -> Int") ~doc:"Product of the elements (1 for the empty list).";
  e "List.maximum" ~m:"Tesl.List" ~kind:(KSyntax "fn List.maximum(xs: List a) -> Maybe a") ~doc:"Largest element, or Nothing for the empty list.";
  e "List.minimum" ~m:"Tesl.List" ~kind:(KSyntax "fn List.minimum(xs: List a) -> Maybe a") ~doc:"Smallest element, or Nothing for the empty list.";
  e "List.any" ~m:"Tesl.List" ~kind:(KSyntax "fn List.any(pred: (a -> Bool requires c), xs: List a) -> Bool requires c") ~doc:"True when some element satisfies pred.";
  e "List.all" ~m:"Tesl.List" ~kind:(KSyntax "fn List.all(pred: (a -> Bool requires c), xs: List a) -> Bool requires c") ~doc:"True when every element satisfies pred.";
  e "List.count" ~m:"Tesl.List" ~kind:(KSyntax "fn List.count(pred: (a -> Bool requires c), xs: List a) -> Int requires c") ~doc:"Number of elements satisfying pred.";
  e "List.partition" ~m:"Tesl.List" ~kind:(KSyntax "fn List.partition(pred: (a -> Bool requires c), xs: List a) -> List (List a) requires c   # [passing, failing]") ~doc:"Splits into the elements that satisfy pred and those that do not.";
  e "List.intersperse" ~m:"Tesl.List" ~kind:(KSyntax "fn List.intersperse(sep: a, xs: List a) -> List a") ~doc:"Inserts sep between consecutive elements.";
  e "List.intercalate" ~m:"Tesl.List" ~kind:(KSyntax "fn List.intercalate(sep: List a, xss: List (List a)) -> List a") ~doc:"Joins the inner lists with sep between them, then flattens.";
  e "List.groupBy" ~m:"Tesl.List" ~kind:(KSyntax "fn List.groupBy(f: (a -> b requires c), xs: List a) -> List (List a) requires c") ~doc:"Groups consecutive elements with equal keys under f.";
]

let list_prim : entry list = [
  e "ListPrim.head" ~m:"Tesl.ListPrim" ~kind:(KSyntax "fn ListPrim.head(xs: List a) -> Maybe a")
    ~doc:"Irreducible list leaf primitive (first element); the lifted Tesl.List combinators are built on these.";
  e "ListPrim.tail" ~m:"Tesl.ListPrim" ~kind:(KSyntax "fn ListPrim.tail(xs: List a) -> Maybe (List a)")
    ~doc:"Irreducible list leaf primitive (rest of the list).";
  e "ListPrim.append" ~m:"Tesl.ListPrim" ~kind:(KSyntax "fn ListPrim.append(xs: List a, ys: List a) -> List a")
    ~doc:"Irreducible list leaf primitive (concatenation).";
]

(* ── Tesl.Int ──────────────────────────────────────────────────────────────── *)

let int_ : entry list = [
  e "IsNonNegative" ~m:"Tesl.Int" ~kind:(KFact "fact IsNonNegative (n: Int)")
    ~doc:"The integer is >= 0; minted by Int.nonNegative.";
  e "IsNonZero" ~m:"Tesl.Int" ~kind:(KFact "fact IsNonZero (n: Int)")
    ~doc:"The integer is != 0; minted by Int.nonZero, required by Int.divide / Int.modulo.";
  f "Int.parse" [ "s" ] ~m:"Tesl.Int" ~doc:"Parses an integer; Nothing on malformed input.";
  f "Int.toString" [ "n" ] ~m:"Tesl.Int" ~doc:"Renders an Int as a String.";
  f "Int.abs" [ "n" ] ~m:"Tesl.Int" ~doc:"Absolute value.";
  f "Int.min" [ "a"; "b" ] ~m:"Tesl.Int" ~doc:"The smaller of two integers.";
  f "Int.max" [ "a"; "b" ] ~m:"Tesl.Int" ~doc:"The larger of two integers.";
  f "Int.nonNegative" [ "n" ] ~m:"Tesl.Int" ~doc:"Check function: passes n >= 0, minting IsNonNegative.";
  e "Int.fromFloat" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.fromFloat(f: Float) -> Int") ~doc:"Converts a Float to Int, truncating toward zero.";
  e "Int.toFloat" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.toFloat(n: Int) -> Float") ~doc:"Converts an Int to Float.";
  e "Int.clamp" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.clamp(n: Int, lo: Int, hi: Int) -> Int") ~doc:"Clamps n into [lo, hi].";
  e "Int.isPositive" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.isPositive(n: Int) -> Bool") ~doc:"True when n > 0.";
  e "Int.isNegative" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.isNegative(n: Int) -> Bool") ~doc:"True when n < 0.";
  e "Int.isZero" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.isZero(n: Int) -> Bool") ~doc:"True when n == 0.";
  e "Int.isEven" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.isEven(n: Int) -> Bool") ~doc:"True when n is even.";
  e "Int.isOdd" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.isOdd(n: Int) -> Bool") ~doc:"True when n is odd.";
  e "Int.gcd" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.gcd(a: Int, b: Int) -> Int") ~doc:"Greatest common divisor.";
  e "Int.lcm" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.lcm(a: Int, b: Int) -> Int") ~doc:"Least common multiple.";
  e "Int.pow" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.pow(base: Int, exp: Int) -> Int") ~doc:"Integer exponentiation.";
  e "Int.digits" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.digits(n: Int) -> Int") ~doc:"Number of decimal digits in abs(n).";
  e "Int.sign" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.sign(n: Int) -> Int") ~doc:"-1, 0, or 1 by the sign of n.";
  e "Int.nonZero" ~m:"Tesl.Int" ~kind:(KSyntax "check Int.nonZero(n: Int) -> n: Int ::: IsNonZero n") ~doc:"Check function: passes n != 0, minting IsNonZero.";
  e "Int.divide" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.divide(a: Int, b: Int ::: IsNonZero b) -> Int") ~doc:"Integer division; the divisor must carry an IsNonZero proof (from Int.nonZero).";
  e "Int.modulo" ~m:"Tesl.Int" ~kind:(KSyntax "fn Int.modulo(a: Int, b: Int ::: IsNonZero b) -> Int") ~doc:"Integer remainder; the divisor must carry an IsNonZero proof (from Int.nonZero).";
]

(* ── Tesl.Float ────────────────────────────────────────────────────────────── *)

let float_ : entry list = [
  e "Float" ~m:"Tesl.Float" ~kind:(KType "type Float   # 64-bit IEEE-754 double")
    ~doc:"Double-precision floating point (never use for money — see Tesl.Money).";
  e "FloatNonZero" ~m:"Tesl.Float" ~kind:(KFact "fact FloatNonZero (f: Float)")
    ~doc:"The float is != 0.0; minted by Float.requireNonZero, required as the denominator proof of Float.div.";
  f "Float.add" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"Float addition.";
  f "Float.sub" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"Float subtraction.";
  f "Float.mul" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"Float multiplication.";
  f "Float.div" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"Float division; the denominator must carry a FloatNonZero proof (from Float.requireNonZero).";
  f "Float.requireNonZero" [ "f" ] ~m:"Tesl.Float" ~doc:"Check function: passes f != 0.0, minting FloatNonZero.";
  f "Float.round" [ "f" ] ~m:"Tesl.Float" ~doc:"Rounds to the nearest integer.";
  f "Float.floor" [ "f" ] ~m:"Tesl.Float" ~doc:"Largest integer <= f.";
  f "Float.ceil" [ "f" ] ~m:"Tesl.Float" ~doc:"Smallest integer >= f.";
  e "Float.parse" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.parse(s: String) -> Maybe Float") ~doc:"Parses a float; Nothing on malformed input.";
  e "Float.toString" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.toString(f: Float) -> String") ~doc:"Renders a Float as a String.";
  e "Float.toInt" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.toInt(f: Float) -> Int") ~doc:"Converts to Int, truncating toward zero.";
  e "Float.abs" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.abs(f: Float) -> Float") ~doc:"Absolute value.";
  e "Float.min" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.min(a: Float, b: Float) -> Float") ~doc:"The smaller of two floats.";
  e "Float.max" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.max(a: Float, b: Float) -> Float") ~doc:"The larger of two floats.";
  e "Float.clamp" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.clamp(f: Float, lo: Float, hi: Float) -> Float") ~doc:"Clamps f into [lo, hi].";
  e "Float.sqrt" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.sqrt(f: Float) -> Float") ~doc:"Square root.";
  e "Float.pow" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.pow(base: Float, exp: Float) -> Float") ~doc:"Exponentiation.";
  e "Float.log" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.log(f: Float) -> Float") ~doc:"Natural logarithm.";
  e "Float.exp" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.exp(f: Float) -> Float") ~doc:"e raised to f.";
  e "Float.sin" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.sin(f: Float) -> Float") ~doc:"Sine (radians).";
  e "Float.cos" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.cos(f: Float) -> Float") ~doc:"Cosine (radians).";
  e "Float.tan" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.tan(f: Float) -> Float") ~doc:"Tangent (radians).";
  e "Float.isNaN" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.isNaN(f: Float) -> Bool") ~doc:"True when f is NaN.";
  e "Float.isInfinite" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.isInfinite(f: Float) -> Bool") ~doc:"True when f is +inf or -inf.";
  e "Float.isPositive" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.isPositive(f: Float) -> Bool") ~doc:"True when f > 0.0.";
  e "Float.isNegative" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.isNegative(f: Float) -> Bool") ~doc:"True when f < 0.0.";
  e "Float.isZero" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.isZero(f: Float) -> Bool") ~doc:"True when f == 0.0.";
  e "Float.sign" ~m:"Tesl.Float" ~kind:(KSyntax "fn Float.sign(f: Float) -> Float") ~doc:"1.0, -1.0, or 0.0 by the sign of f.";
  e "Float.infinity" ~m:"Tesl.Float" ~kind:(KSyntax "Float.infinity : Float") ~doc:"Positive infinity.";
  e "Float.nan" ~m:"Tesl.Float" ~kind:(KSyntax "Float.nan : Float") ~doc:"Not-a-number.";
]

(* ── Tesl.Dict ─────────────────────────────────────────────────────────────── *)

let dict : entry list = [
  e "Dict" ~m:"Tesl.Dict" ~kind:(KType "type Dict k v   # immutable key-value map") ~doc:"An immutable dictionary from keys to values.";
  e "HasKey" ~m:"Tesl.Dict" ~kind:(KFact "fact HasKey (key: k, d: Dict k v)")
    ~doc:"The dict contains the key; minted by Dict.requireKey, required by Dict.get.";
  v "Dict.empty" ~m:"Tesl.Dict" ~doc:"The empty dictionary.";
  f "Dict.singleton" [ "key"; "value" ] ~m:"Tesl.Dict" ~doc:"A one-entry dictionary.";
  f "Dict.insert" [ "key"; "value"; "d" ] ~m:"Tesl.Dict" ~doc:"Inserts or replaces the entry for key.";
  f "Dict.remove" [ "key"; "d" ] ~m:"Tesl.Dict" ~doc:"Removes the entry for key, if present.";
  f "Dict.delete" [ "key"; "d" ] ~m:"Tesl.Dict" ~doc:"Removes the entry for key (same as remove).";
  f "Dict.lookup" [ "key"; "d" ] ~m:"Tesl.Dict" ~doc:"The value for key, if present.";
  f "Dict.requireKey" [ "key"; "d" ] ~m:"Tesl.Dict" ~doc:"Check function: passes when key is present, minting HasKey.";
  f "Dict.get" [ "key"; "d" ] ~m:"Tesl.Dict" ~doc:"The value for key; the dict must carry a HasKey proof (from Dict.requireKey).";
  f "Dict.member" [ "key"; "d" ] ~m:"Tesl.Dict" ~doc:"True when key is present.";
  f "Dict.size" [ "d" ] ~m:"Tesl.Dict" ~doc:"Number of entries.";
  f "Dict.isEmpty" [ "d" ] ~m:"Tesl.Dict" ~doc:"True when the dict has no entries.";
  f "Dict.keys" [ "d" ] ~m:"Tesl.Dict" ~doc:"The keys as a list.";
  f "Dict.values" [ "d" ] ~m:"Tesl.Dict" ~doc:"The values as a list.";
  f "Dict.fromList" [ "pairs" ] ~m:"Tesl.Dict" ~doc:"Builds a dict from (key, value) pairs; later duplicates win.";
  f "Dict.toList" [ "d" ] ~m:"Tesl.Dict" ~doc:"The entries as (key, value) pairs.";
  f "Dict.map" [ "f"; "d" ] ~m:"Tesl.Dict" ~doc:"Maps f over the values.";
  f "Dict.filter" [ "pred"; "d" ] ~m:"Tesl.Dict" ~doc:"Keeps the entries whose value satisfies pred.";
  f "Dict.filterCheckValues" [ "checkFn"; "d" ] ~m:"Tesl.Dict" ~doc:"Keeps the entries whose value passes a check, with a ForAllValues proof attached.";
  f "Dict.filterCheckKeys" [ "checkFn"; "d" ] ~m:"Tesl.Dict" ~doc:"Keeps the entries whose key passes a check, with a ForAllKeys proof attached.";
  f "Dict.union" [ "d1"; "d2" ] ~m:"Tesl.Dict" ~doc:"Union of two dicts; d1 wins on conflicting keys.";
  f "Dict.intersection" [ "d1"; "d2" ] ~m:"Tesl.Dict" ~doc:"Entries of d1 whose key is also in d2.";
  f "Dict.difference" [ "d1"; "d2" ] ~m:"Tesl.Dict" ~doc:"Entries of d1 whose key is not in d2.";
  e "Dict.insertWith" ~m:"Tesl.Dict" ~kind:(KSyntax "fn Dict.insertWith(f: (v, v) -> v, key: k, value: v, d: Dict k v) -> Dict k v") ~doc:"Inserts, combining with f (new, old) when the key already exists.";
  e "Dict.mapWithKey" ~m:"Tesl.Dict" ~kind:(KSyntax "fn Dict.mapWithKey(f: (k, v) -> w, d: Dict k v) -> Dict k w") ~doc:"Maps over the values with access to each key.";
  e "Dict.filterWithKey" ~m:"Tesl.Dict" ~kind:(KSyntax "fn Dict.filterWithKey(pred: (k, v) -> Bool, d: Dict k v) -> Dict k v") ~doc:"Keeps the entries satisfying a key-and-value predicate.";
  e "Dict.foldl" ~m:"Tesl.Dict" ~kind:(KSyntax "fn Dict.foldl(f: (b, v) -> b, init: b, d: Dict k v) -> b") ~doc:"Left fold over the values.";
  e "Dict.foldr" ~m:"Tesl.Dict" ~kind:(KSyntax "fn Dict.foldr(f: (v, b) -> b, init: b, d: Dict k v) -> b") ~doc:"Right fold over the values.";
  e "Dict.unionWith" ~m:"Tesl.Dict" ~kind:(KSyntax "fn Dict.unionWith(f: (v, v) -> v, d1: Dict k v, d2: Dict k v) -> Dict k v") ~doc:"Union, combining conflicting values with f.";
  e "Dict.update" ~m:"Tesl.Dict" ~kind:(KSyntax "fn Dict.update(key: k, f: Maybe v -> Maybe v, d: Dict k v) -> Dict k v") ~doc:"Inserts, modifies, or removes the entry for key through f.";
]

(* ── Tesl.Set ──────────────────────────────────────────────────────────────── *)

let set_ : entry list = [
  e "Set" ~m:"Tesl.Set" ~kind:(KType "type Set a   # immutable set of distinct values") ~doc:"An immutable set of distinct values.";
  v "Set.empty" ~m:"Tesl.Set" ~doc:"The empty set.";
  f "Set.singleton" [ "x" ] ~m:"Tesl.Set" ~doc:"A one-element set.";
  f "Set.insert" [ "x"; "s" ] ~m:"Tesl.Set" ~doc:"Adds an element.";
  f "Set.remove" [ "x"; "s" ] ~m:"Tesl.Set" ~doc:"Removes an element, if present.";
  f "Set.delete" [ "x"; "s" ] ~m:"Tesl.Set" ~doc:"Removes an element (same as remove).";
  f "Set.member" [ "x"; "s" ] ~m:"Tesl.Set" ~doc:"True when x is in the set.";
  f "Set.size" [ "s" ] ~m:"Tesl.Set" ~doc:"Number of elements.";
  f "Set.isEmpty" [ "s" ] ~m:"Tesl.Set" ~doc:"True when the set has no elements.";
  f "Set.toList" [ "s" ] ~m:"Tesl.Set" ~doc:"The elements as a list.";
  f "Set.fromList" [ "xs" ] ~m:"Tesl.Set" ~doc:"Builds a set from a list (duplicates collapse).";
  f "Set.union" [ "s1"; "s2" ] ~m:"Tesl.Set" ~doc:"Union of two sets.";
  f "Set.intersection" [ "s1"; "s2" ] ~m:"Tesl.Set" ~doc:"Intersection of two sets.";
  f "Set.difference" [ "s1"; "s2" ] ~m:"Tesl.Set" ~doc:"Elements of s1 not in s2.";
  f "Set.isSubset" [ "s1"; "s2" ] ~m:"Tesl.Set" ~doc:"True when every element of s1 is in s2.";
  f "Set.filter" [ "pred"; "s" ] ~m:"Tesl.Set" ~doc:"Keeps the elements satisfying pred.";
  f "Set.filterCheck" [ "checkFn"; "s" ] ~m:"Tesl.Set" ~doc:"Keeps the elements that pass a check function, with their proof attached.";
  f "Set.any" [ "pred"; "s" ] ~m:"Tesl.Set" ~doc:"True when some element satisfies pred.";
  f "Set.all" [ "pred"; "s" ] ~m:"Tesl.Set" ~doc:"True when every element satisfies pred.";
  f "Set.allCheck" [ "checkFn"; "s" ] ~m:"Tesl.Set" ~doc:"Applies a check to every element: Something (set ::: ForAll P) if all pass, Nothing otherwise.";
  e "Set.map" ~m:"Tesl.Set" ~kind:(KSyntax "fn Set.map(f: (a -> b requires c), s: Set a) -> Set b requires c") ~doc:"Maps f over the elements (results collapse duplicates).";
  e "Set.foldl" ~m:"Tesl.Set" ~kind:(KSyntax "fn Set.foldl(f: (b, a) -> b, init: b, s: Set a) -> b") ~doc:"Left fold over the elements.";
  e "Set.partition" ~m:"Tesl.Set" ~kind:(KSyntax "fn Set.partition(pred: (a -> Bool), s: Set a) -> List (Set a)   # [passing, failing]") ~doc:"Splits into the elements that satisfy pred and those that do not.";
]

(* ── Tesl.Tuple ────────────────────────────────────────────────────────────── *)

let tuple : entry list = [
  f "Tuple2" [ "first"; "second" ] ~m:"Tesl.Tuple" ~doc:"Pair constructor; Tuple2 a b is also the pair type (e.g. List (Tuple2 String String)).";
  f "Tuple2.first" [ "pair" ] ~m:"Tesl.Tuple" ~doc:"First component of a pair.";
  f "Tuple2.second" [ "pair" ] ~m:"Tesl.Tuple" ~doc:"Second component of a pair.";
  f "Tuple3" [ "first"; "second"; "third" ] ~m:"Tesl.Tuple" ~doc:"Triple constructor; Tuple3 a b c is also the triple type.";
  f "Tuple3.first" [ "triple" ] ~m:"Tesl.Tuple" ~doc:"First component of a triple.";
  f "Tuple3.second" [ "triple" ] ~m:"Tesl.Tuple" ~doc:"Second component of a triple.";
  f "Tuple3.third" [ "triple" ] ~m:"Tesl.Tuple" ~doc:"Third component of a triple.";
]

(* ── Tesl.Money ────────────────────────────────────────────────────────────── *)
(* The Currency ADT and per-currency Money constructors are family entries in
   Stdlib_docs (Currency / MoneyCtors). *)

let money : entry list = [
  e "Money" ~m:"Tesl.Money"
    ~kind:(KType "type Money   # exact integer minor units (cents/öre/yen) + an intrinsic Currency; never Float")
    ~doc:"Exact money; same-currency arithmetic is proof-gated (SameCurrency) and conversion needs an explicit ExchangeRate.";
  e "ExchangeRate" ~m:"Tesl.Money"
    ~kind:(KType "type ExchangeRate   # runtime rate with provenance: fromCurrency, toCurrency, rate: Float, asOf: PosixMillis")
    ~doc:"A cross-currency conversion rate — always runtime data with provenance, never ambient; built with ExchangeRate.make.";
  e "SameCurrency" ~m:"Tesl.Money" ~kind:(KFact "fact SameCurrency (a: Money, b: Money)")
    ~doc:"Both amounts share one currency; minted by Money.requireSameCurrency, required by Money.add / subtract / compare.";
  e "NonNegativeMoney" ~m:"Tesl.Money" ~kind:(KFact "fact NonNegativeMoney (m: Money)")
    ~doc:"The amount is >= 0; minted by Money.requireNonNegative.";
  e "RateFor" ~m:"Tesl.Money" ~kind:(KFact "fact RateFor (rate: ExchangeRate, m: Money)")
    ~doc:"The rate's from-currency matches the amount's currency; minted by Money.requireRateFor, required by Money.convertChecked.";
  f "Money.fromMinorUnits" [ "currency"; "minorUnits" ] ~m:"Tesl.Money" ~doc:"Builds Money from whole minor units (e.g. cents); see also the per-currency constructors (Money.sek 100).";
  f "Money.minorUnits" [ "m" ] ~m:"Tesl.Money" ~doc:"The amount in whole minor units.";
  f "Money.currency" [ "m" ] ~m:"Tesl.Money" ~doc:"The amount's currency.";
  f "Money.scale" [ "m"; "factor" ] ~m:"Tesl.Money" ~doc:"Multiplies by an integer factor (exact).";
  f "Money.scaleBy" [ "m"; "factor" ] ~m:"Tesl.Money" ~doc:"Multiplies by a decimal factor (VAT/discount), rounding half-even back to minor units.";
  f "Money.negate" [ "m" ] ~m:"Tesl.Money" ~doc:"Negates the amount.";
  f "Money.abs" [ "m" ] ~m:"Tesl.Money" ~doc:"Absolute value of the amount.";
  f "Money.isZero" [ "m" ] ~m:"Tesl.Money" ~doc:"True when the amount is zero.";
  f "Money.isNegative" [ "m" ] ~m:"Tesl.Money" ~doc:"True when the amount is negative.";
  f "Money.display" [ "m" ] ~m:"Tesl.Money" ~doc:"Formats with the currency's minor digits (e.g. \"950.00 SEK\").";
  f "Money.add" [ "a"; "b" ] ~m:"Tesl.Money" ~doc:"Adds two amounts; requires a SameCurrency a b proof (mint with Money.requireSameCurrency).";
  f "Money.subtract" [ "a"; "b" ] ~m:"Tesl.Money" ~doc:"Subtracts b from a; requires a SameCurrency a b proof.";
  f "Money.compare" [ "a"; "b" ] ~m:"Tesl.Money" ~doc:"-1/0/1 ordering of two amounts; requires a SameCurrency a b proof.";
  f "Money.requireSameCurrency" [ "a"; "b" ] ~m:"Tesl.Money" ~doc:"Check function: passes when both amounts share a currency, minting SameCurrency.";
  f "Money.requireNonNegative" [ "m" ] ~m:"Tesl.Money" ~doc:"Check function: passes non-negative amounts, minting NonNegativeMoney.";
  f "Money.requireRateFor" [ "rate"; "m" ] ~m:"Tesl.Money" ~doc:"Check function: passes when the rate converts the amount's currency, minting RateFor.";
  f "Money.convert" [ "rate"; "m" ] ~m:"Tesl.Money" ~doc:"Converts through an explicit rate; Err when the rate's from-currency does not match.";
  f "Money.convertChecked" [ "rate"; "m" ] ~m:"Tesl.Money" ~doc:"Converts through a rate already proven to match (RateFor); returns Money directly.";
  f "Currency.code" [ "c" ] ~m:"Tesl.Money" ~doc:"The ISO-4217 code (e.g. \"SEK\").";
  f "Currency.minorDigits" [ "c" ] ~m:"Tesl.Money" ~doc:"Number of minor-unit digits (2 for SEK/USD, 0 for JPY).";
  f "Currency.fromCode" [ "code" ] ~m:"Tesl.Money" ~doc:"Currency for an ISO-4217 code string, if known.";
  f "ExchangeRate.make" [ "from"; "to"; "rate"; "asOf" ] ~m:"Tesl.Money" ~doc:"Builds a rate with provenance (asOf timestamp).";
  f "ExchangeRate.fromCurrency" [ "r" ] ~m:"Tesl.Money" ~doc:"The rate's source currency.";
  f "ExchangeRate.toCurrency" [ "r" ] ~m:"Tesl.Money" ~doc:"The rate's target currency.";
  f "ExchangeRate.rate" [ "r" ] ~m:"Tesl.Money" ~doc:"The numeric conversion factor.";
  f "ExchangeRate.asOf" [ "r" ] ~m:"Tesl.Money" ~doc:"When the rate was observed.";
  f "MoneyRate.perHour" [ "amount" ] ~m:"Tesl.Money" ~doc:"Money per hour (e.g. an hourly price); `rate * duration : Money`.";
  f "MoneyRate.perDay" [ "amount" ] ~m:"Tesl.Money" ~doc:"Money per day; `rate * duration : Money`.";
  f "MoneyRate.perKilogram" [ "amount" ] ~m:"Tesl.Money" ~doc:"Money per kilogram; `rate * mass : Money`.";
  f "MoneyRate.perLiter" [ "amount" ] ~m:"Tesl.Money" ~doc:"Money per liter; `rate * volume : Money`.";
  f "MoneyRate.perSquareMeter" [ "amount" ] ~m:"Tesl.Money" ~doc:"Money per square meter; `rate * area : Money`.";
  e "MoneyRate.currency" ~m:"Tesl.Money" ~kind:(KSyntax "MoneyRate.currency rate : Currency   # dimension-polymorphic, typed at the application site")
    ~doc:"The currency riding on a money rate.";
  e "MoneyRate.display" ~m:"Tesl.Money" ~kind:(KSyntax "MoneyRate.display rate : String   # e.g. \"950.00 SEK/h\"; dimension-polymorphic")
    ~doc:"Formats a money rate with its currency and denominator unit.";
]

(* ── Tesl.Random / Tesl.UUID / Tesl.Id / Tesl.Env ──────────────────────────── *)

let random_uuid_id_env : entry list = [
  f "randomInt" [ "lo"; "hi" ] ~m:"Tesl.Random" ~doc:"Uniformly random integer in [lo, hi).";
  v "randomFloat" ~m:"Tesl.Random" ~doc:"A random Float in [0, 1) — fresh per call, invoked as randomFloat().";
  e "IsUuid" ~m:"Tesl.UUID" ~kind:(KFact "fact IsUuid (s: String)")
    ~doc:"The string is a well-formed UUID; minted by UUID.validate.";
  v "UUID.v4" ~m:"Tesl.UUID" ~doc:"A fresh random (v4) UUID string per call — invoked as UUID.v4().";
  v "UUID.v7" ~m:"Tesl.UUID" ~doc:"A fresh time-ordered (v7) UUID string per call — invoked as UUID.v7().";
  f "UUID.validate" [ "s" ] ~m:"Tesl.UUID" ~doc:"Check function: passes well-formed UUID strings, minting IsUuid.";
  v "uuidV4Codec" ~m:"Tesl.UUID" ~doc:"JSON codec for UUID-v4 strings (use with `with_codec` or a capturer `using` clause).";
  v "uuidV7Codec" ~m:"Tesl.UUID" ~doc:"JSON codec for UUID-v7 strings (use with `with_codec` or a capturer `using` clause).";
  v "generateId" ~m:"Tesl.Id" ~doc:"A fresh unique id string per call.";
  f "generatePrefixedId" [ "prefix" ] ~m:"Tesl.Id" ~doc:"A fresh unique id with the given prefix (e.g. \"usr_...\").";
  f "env" [ "name" ] ~m:"Tesl.Env" ~doc:"Reads an environment variable, if set.";
  f "envInt" [ "name"; "default" ] ~m:"Tesl.Env" ~doc:"Reads an environment variable as Int, falling back to default when unset or unparseable.";
  f "envString" [ "name"; "default" ] ~m:"Tesl.Env" ~doc:"Reads an environment variable as String, falling back to default when unset.";
  f "requireEnv" [ "name" ] ~m:"Tesl.Env" ~doc:"Reads an environment variable as String, failing at startup if unset.";
]

(* ── Tesl.Json (builtin codecs — validated by name and lowered inline) ─────── *)

let json_codecs : entry list =
  let codec name ty extra =
    e name ~m:"Tesl.Json"
      ~kind:(KSyntax (Printf.sprintf "%s   # builtin JSON codec: %s" name ty))
      ~doc:(Printf.sprintf
              "JSON codec for %s fields%s — use in `with_codec %s`, `toJson`/`fromJson` mappings, and capturer `using` clauses."
              ty extra name)
  in
  [ codec "stringCodec" "String" "";
    codec "intCodec" "Int" "";
    codec "int32Codec" "Int32" "";
    codec "boolCodec" "Bool" "";
    codec "floatCodec" "Float" "";
    codec "posixMillisCodec" "PosixMillis" " (epoch milliseconds)";
    codec "moneyCodec" "Money" "";
    codec "listCodec" "List" "";
    codec "dictCodec" "Dict" "";
    codec "setCodec" "Set" "";
  ]

(* ── Tesl.ApiTest ──────────────────────────────────────────────────────────── *)

let api_test : entry list = [
  e "JsonValue" ~m:"Tesl.ApiTest" ~kind:(KType "type JsonValue   # a raw JSON value (api-test response bodies, SSE events)")
    ~doc:"Raw JSON as returned by api-test requests; inspect with jsonInt / fieldAt / includesWhere / ...";
  e "JsonNull" ~m:"Tesl.ApiTest" ~kind:(KSyntax "JsonNull : JsonValue   # the JSON null literal") ~doc:"The JSON null value.";
  e "SseStream" ~m:"Tesl.ApiTest" ~kind:(KType "type SseStream   # an open SSE subscription handle (from subscribe)")
    ~doc:"A live server-sent-events subscription inside an api-test; read with collect.";
  e "JobResult" ~m:"Tesl.ApiTest"
    ~kind:(KType "type JobResult a e = JobOk a | JobFailed a e")
    ~doc:"Result of processNextJob / processNextDeadJob — the worker's job on success, job plus error on failure."
    ~aliases:[ "JobOk"; "JobFailed" ];
  v "statusOk" ~m:"Tesl.ApiTest" ~doc:"Status matcher for api-test expectations — `expect statusOk resp.status` passes on any 2xx.";
  v "statusClientError" ~m:"Tesl.ApiTest" ~doc:"Status matcher — passes on any 4xx status.";
  v "statusServerError" ~m:"Tesl.ApiTest" ~doc:"Status matcher — passes on any 5xx status.";
  e "jsonInt" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn jsonInt(value: JsonValue) -> Int") ~doc:"Reads a JSON number as Int (fails the test on a non-integer).";
  e "jsonString" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn jsonString(value: JsonValue) -> String") ~doc:"Reads a JSON string (fails the test on a non-string).";
  e "jsonBool" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn jsonBool(value: JsonValue) -> Bool") ~doc:"Reads a JSON boolean (fails the test on a non-boolean).";
  e "jsonArray" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn jsonArray(value: JsonValue) -> JsonValue") ~doc:"Asserts the value is a JSON array and returns it.";
  e "jsonObject" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn jsonObject(value: JsonValue) -> JsonValue") ~doc:"Asserts the value is a JSON object and returns it.";
  e "jsonLength" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn jsonLength(value: JsonValue) -> Int") ~doc:"Length of a JSON array or object.";
  e "isNull" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn isNull(value: JsonValue) -> Bool") ~doc:"True when the value is JSON null.";
  e "isNotNull" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn isNotNull(value: JsonValue) -> Bool") ~doc:"True when the value is not JSON null.";
  e "hasLength" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn hasLength(expected: Int, value: JsonValue) -> Bool") ~doc:"True when a JSON array/object has exactly the expected length.";
  e "isEmpty" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn isEmpty(value: JsonValue) -> Bool") ~doc:"True when a JSON array/object is empty.";
  e "isNotEmpty" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn isNotEmpty(value: JsonValue) -> Bool") ~doc:"True when a JSON array/object is non-empty.";
  e "arrayAt" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn arrayAt(index: Int, value: JsonValue) -> JsonValue") ~doc:"The array element at index (fails the test when out of range).";
  e "hasField" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn hasField(field: String, value: JsonValue) -> Bool") ~doc:"True when a JSON object has the field.";
  e "fieldAt" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn fieldAt(field: String, value: JsonValue) -> JsonValue") ~doc:"The object field's value (fails the test when missing).";
  e "bodyField" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn bodyField(field: String, response: HttpResponse) -> JsonValue") ~doc:"Shorthand for fieldAt on a response body.";
  e "jsonContains" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn jsonContains(needle: JsonValue, value: JsonValue) -> Bool") ~doc:"True when a JSON array contains an equal element.";
  e "includesWhere" ~m:"Tesl.ApiTest" ~kind:(KSyntax "expect events |> includesWhere { \"field\": expected, ... }") ~doc:"Passes when some array element matches every field of the pattern object.";
  e "excludesWhere" ~m:"Tesl.ApiTest" ~kind:(KSyntax "expect events |> excludesWhere { \"field\": expected, ... }") ~doc:"Passes when no array element matches every field of the pattern object.";
  e "subscribe" ~m:"Tesl.ApiTest" ~kind:(KSyntax "let stream = subscribe \"/events/route\" [cookie \"session=...\"] : SseStream")
    ~doc:"Opens an SSE subscription inside an api-test (optionally authenticated via cookie).";
  e "collect" ~m:"Tesl.ApiTest" ~kind:(KSyntax "let events = collect stream count N timeout Tms : JsonValue")
    ~doc:"Waits for N events on an SSE stream (up to the timeout) and returns them as a JSON array.";
  f "processNextJob" [ "queue" ] ~m:"Tesl.ApiTest" ~doc:"Runs one pending job through its worker inside the test; returns a JobResult.";
  f "processNextDeadJob" [ "queue" ] ~m:"Tesl.ApiTest" ~doc:"Runs one dead-letter job through its dead-worker inside the test; returns a JobResult.";
  f "drainQueue" [ "queue" ] ~m:"Tesl.ApiTest" ~doc:"Runs pending jobs until the queue is empty (safety-limited).";
  f "pendingJobCount" [ "queue" ] ~m:"Tesl.ApiTest" ~doc:"Number of jobs currently waiting on the queue.";
  e "expectJobOk" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn expectJobOk(result: JobResult a e) -> a") ~doc:"Asserts the job succeeded and returns the processed job.";
  e "expectJobFailed" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn expectJobFailed(result: JobResult a e) -> e") ~doc:"Asserts the job failed and returns the worker's error.";
]

(* ── Tesl.JWT ──────────────────────────────────────────────────────────────── *)

let jwt : entry list = [
  f "JwtToken" [ "raw" ] ~m:"Tesl.JWT" ~doc:"Newtype constructor wrapping a raw JWT string.";
  f "JwtSecret" [ "raw" ] ~m:"Tesl.JWT" ~doc:"Newtype constructor wrapping a signing secret.";
  f "JWT.sign" [ "claims"; "secret" ] ~m:"Tesl.JWT" ~doc:"Signs a string-keyed claims dict into a JwtToken.";
  f "JWT.verify" [ "token"; "secret" ] ~m:"Tesl.JWT" ~doc:"Verifies the signature and returns the claims (fails on tampered/expired tokens).";
  f "JWT.decode" [ "token" ] ~m:"Tesl.JWT" ~doc:"Decodes the claims WITHOUT verifying the signature — never use for auth decisions.";
]

(* ── Tesl.Cache (compiler-lowered forms; the Cache config block is generated) ─ *)

let cache : entry list = [
  e "cache" ~m:"Tesl.Cache" ~kind:(KSyntax "cache Name = Cache { database: ..., valueType: ..., defaultTtl: ... }")
    ~doc:"Declares a cache; the declaration grants the capability `cacheCap Name`.";
  e "Cache.get" ~m:"Tesl.Cache" ~kind:(KSyntax "Cache.get <CacheName> (key) : Maybe v   # requires [cacheCap <CacheName>]")
    ~doc:"Looks up a cached value by key.";
  e "Cache.set" ~m:"Tesl.Cache" ~kind:(KSyntax "Cache.set <CacheName> (key) value [ttlSeconds] : Unit   # requires [cacheCap <CacheName>]")
    ~doc:"Stores a value under key, with an optional per-entry TTL override.";
  e "Cache.delete" ~m:"Tesl.Cache" ~kind:(KSyntax "Cache.delete <CacheName> (key) : Unit   # requires [cacheCap <CacheName>]")
    ~doc:"Removes the entry for key.";
  e "Cache.invalidate" ~m:"Tesl.Cache" ~kind:(KSyntax "Cache.invalidate <CacheName> (prefix) : Unit   # requires [cacheCap <CacheName>]")
    ~doc:"Removes every entry whose key starts with the prefix.";
]

(* ── Tesl.Database (config ADTs; the Database/PostgresConfig/... blocks are
      generated config entries) ──────────────────────────────────────────────── *)

let database : entry list = [
  e "DatabaseBackend" ~m:"Tesl.Database"
    ~kind:(KType "type DatabaseBackend = Postgres PostgresConfig | Memory")
    ~doc:"The `backend:` field of a Database block — PostgreSQL or the in-memory backend."
    ~aliases:[ "Postgres"; "Memory" ];
  e "PostgresConnection" ~m:"Tesl.Database"
    ~kind:(KType "type PostgresConnection = TcpConnection { host, port } | SocketConnection { path }")
    ~doc:"The `connection:` field of a PostgresConfig — TCP or Unix socket.";
]

(* ── Tesl.HttpClient ───────────────────────────────────────────────────────── *)

let http_client : entry list = [
  e "HttpResponse" ~m:"Tesl.HttpClient"
    ~kind:(KType "type HttpResponse   # record: { status: Int, body: String, headers: List (Tuple2 String String) }")
    ~doc:"An HTTP response — from HttpClient calls (body: String) and api-test requests (body readable as JsonValue)."
    ~aliases:[ "HttpResponse?" ];
  f "HttpClient.get" [ "url"; "headers" ] ~m:"Tesl.HttpClient" ~doc:"Outbound GET; headers are (name, value) pairs.";
  f "HttpClient.post" [ "url"; "headers"; "body" ] ~m:"Tesl.HttpClient" ~doc:"Outbound POST with a string body.";
  f "HttpClient.put" [ "url"; "headers"; "body" ] ~m:"Tesl.HttpClient" ~doc:"Outbound PUT with a string body.";
  f "HttpClient.delete" [ "url"; "headers" ] ~m:"Tesl.HttpClient" ~doc:"Outbound DELETE.";
]

(* ── Tesl.Agent ────────────────────────────────────────────────────────────── *)

let agent : entry list = [
  e "Agent" ~m:"Tesl.Agent"
    ~kind:(KType "Agent { provider: LlmProvider, systemPrompt: String, maxTokens: Int, tools: List Tool } : Agent")
    ~doc:"A capability-bounded AI agent — declared as a top-level `agent X requires [...] = Agent { ... }` block or built inline (e.g. per-request BYOK).";
  e "LlmProvider" ~m:"Tesl.Agent" ~kind:(KType "type LlmProvider   # which model answers and whose key pays")
    ~doc:"A provider binding; built with anthropic / openai / mistral / local / mockProvider, overridable per call via askWith.";
  e "AgentReply" ~m:"Tesl.Agent" ~kind:(KType "type AgentReply   # final text + token usage + tool-call count")
    ~doc:"The result of an agent run; read with replyText / replyTokens / replyToolCalls."
    ~aliases:[ "AgentReply?" ];
  e "Tool" ~m:"Tesl.Agent" ~kind:(KType "type Tool   # a tool the model may call")
    ~doc:"An LLM tool — wrap a typed Tesl function with asTool, or build one manually with tool.";
  e "ToolStep" ~m:"Tesl.Agent" ~kind:(KType "type ToolStep   # a scripted step for mockToolProvider")
    ~doc:"One scripted model step for tests: a tool call (toolUseStep) or final text (textStep).";
  e "Conversation" ~m:"Tesl.Agent" ~kind:(KType "type Conversation   # multi-turn agent conversation state")
    ~doc:"Conversation state; advance with converse, persist with conversationJson / conversationFrom."
    ~aliases:[ "Conversation?" ];
  e "ConversationTurn" ~m:"Tesl.Agent" ~kind:(KType "type ConversationTurn   # one turn: reply + advanced conversation")
    ~doc:"One conversation turn; read with turnReply / turnConversation."
    ~aliases:[ "ConversationTurn?" ];
  f "mockProvider" [ "replies" ] ~m:"Tesl.Agent" ~doc:"Deterministic text provider for tests: returns the scripted replies in order (no network, no keys).";
  f "mockToolProvider" [ "steps" ] ~m:"Tesl.Agent" ~doc:"Deterministic tool-calling provider for tests: scripts the model with toolUseStep / textStep.";
  f "toolUseStep" [ "name"; "id"; "argsJson" ] ~m:"Tesl.Agent" ~doc:"Scripts one model tool call (with its raw arguments JSON) for a mockToolProvider.";
  f "textStep" [ "text" ] ~m:"Tesl.Agent" ~doc:"Scripts the model's final assistant text for a mockToolProvider; ends the loop.";
  f "anthropic" [ "apiKey"; "model" ] ~m:"Tesl.Agent" ~doc:"An Anthropic provider binding.";
  f "openai" [ "apiKey"; "model" ] ~m:"Tesl.Agent" ~doc:"An OpenAI provider binding.";
  f "mistral" [ "apiKey"; "model" ] ~m:"Tesl.Agent" ~doc:"A Mistral provider binding (OpenAI-compatible chat completions).";
  f "local" [ "endpoint"; "model" ] ~m:"Tesl.Agent" ~doc:"A local / OpenAI-compatible provider binding (e.g. Ollama, vLLM) at the given endpoint.";
  f "tool" [ "name"; "description"; "schema"; "validate"; "dispatch" ] ~m:"Tesl.Agent"
    ~doc:"Builds a tool from a JSON-schema string, an argument validator, and a dispatch function; prefer asTool for typed Tesl functions.";
  f "asTool" [ "fn" ] ~m:"Tesl.Agent"
    ~doc:"Wraps a typed Tesl function as a Tool: the JSON schema, argument decoding, and dispatch are derived from its signature; the description is its doc-comment.";
  e "serverTools" ~m:"Tesl.Agent"
    ~kind:(KSyntax "serverTools <ServerName> user : List Tool   # endpoints the user's declared proof covers, as preauthenticated tools")
    ~doc:"Exposes the server's endpoints the given user's proof authorizes as agent tools (charges the endpoints' capabilities).";
  e "humanActions" ~m:"Tesl.Agent"
    ~kind:(KSyntax "humanActions <ServerName> user : List Tool   # endpoints the agent may NOT run — surfaced to the human as inert typed actions")
    ~doc:"The complement of serverTools: hands write-style endpoints to the human as inert action requests; charges no capability.";
  f "ask" [ "agent"; "prompt" ] ~m:"Tesl.Agent" ~doc:"Runs the agent's tool-calling loop on the prompt and returns the final assistant text.";
  f "askReply" [ "agent"; "prompt" ] ~m:"Tesl.Agent" ~doc:"Like ask, but returns the full AgentReply (text + tokens + tool-call count).";
  f "askWith" [ "agent"; "prompt"; "provider" ] ~m:"Tesl.Agent" ~doc:"Like askReply, but overrides the agent's provider for this call (the BYOK path).";
  f "replyText" [ "reply" ] ~m:"Tesl.Agent" ~doc:"The model's final assistant text.";
  f "replyTokens" [ "reply" ] ~m:"Tesl.Agent" ~doc:"The token usage the provider reported.";
  f "replyToolCalls" [ "reply" ] ~m:"Tesl.Agent" ~doc:"How many tool round-trips the loop made.";
  f "decodeAs" [ "typeName"; "json" ] ~m:"Tesl.Agent" ~doc:"Decodes a JSON string into the named type through its codec (the proof-carrying HTTP-body path); raises on malformed input.";
  f "askFor" [ "agent"; "prompt"; "decode"; "maxRetries" ] ~m:"Tesl.Agent" ~doc:"Structured output: runs inference, decodes the reply into a typed value, retrying up to maxRetries on decode failure.";
  f "newConversation" [ "agent" ] ~m:"Tesl.Agent" ~doc:"Starts a fresh multi-turn conversation.";
  f "conversationFrom" [ "agent"; "json" ] ~m:"Tesl.Agent" ~doc:"Restores a conversation from persisted JSON (see conversationJson).";
  f "converse" [ "conversation"; "prompt" ] ~m:"Tesl.Agent" ~doc:"Takes one turn: sends the prompt, returns the ConversationTurn carrying the reply and the advanced conversation.";
  f "converseStreaming" [ "conversation"; "prompt"; "publish" ] ~m:"Tesl.Agent" ~doc:"Like converse, but calls publish once per loop step (tool events and the final text) — stream over SSE while threading history.";
  f "turnReply" [ "turn" ] ~m:"Tesl.Agent" ~doc:"The AgentReply produced by a turn.";
  f "turnConversation" [ "turn" ] ~m:"Tesl.Agent" ~doc:"The conversation advanced past this turn (thread it into the next converse).";
  f "conversationJson" [ "conversation" ] ~m:"Tesl.Agent" ~doc:"Serializes a conversation to JSON for persistence.";
  f "conversationLength" [ "conversation" ] ~m:"Tesl.Agent" ~doc:"Number of turns recorded in the conversation.";
  f "agentRun" [ "agent"; "prompt"; "publish" ] ~m:"Tesl.Agent" ~doc:"Runs the loop to completion (typically on a worker), publishing each step via the callback.";
]

(* ── Tesl.Queue (infrastructure helpers; queue caps + config are generated) ── *)

let queue : entry list = [
  f "requeue" [ "job" ] ~m:"Tesl.Queue" ~doc:"Re-enqueues a dead-letter job for another attempt; True when requeued.";
  f "deadJobs" [ "queue" ] ~m:"Tesl.Queue" ~doc:"The queue's dead-letter entries.";
]

(* ── Tesl.Telemetry ────────────────────────────────────────────────────────── *)

let telemetry : entry list = [
  e "initTelemetry" ~m:"Tesl.Telemetry"
    ~kind:(KSyntax "initTelemetry service \"my-service\" endpoint \"http://collector:4318\" console True : Unit")
    ~doc:"Configures the OpenTelemetry exporter (keyword-value form lowered by the compiler); call once at startup.";
  f "telemetry" [ "name" ] ~m:"Tesl.Telemetry"
    ~doc:"Emits a span; the special form `telemetry \"span.name\" { key = value }` attaches the fields as span attributes.";
  f "counter" [ "name"; "delta"; "attrs" ] ~m:"Tesl.Telemetry"
    ~doc:"Adds delta to a cumulative counter metric; attrs are [Tuple2 \"key\" value] pairs.";
  f "histogram" [ "name"; "value"; "attrs" ] ~m:"Tesl.Telemetry"
    ~doc:"Records a value in a histogram metric; attrs are [Tuple2 \"key\" value] pairs.";
  f "gauge" [ "name"; "value"; "attrs" ] ~m:"Tesl.Telemetry"
    ~doc:"Sets a gauge metric to the given value; attrs are [Tuple2 \"key\" value] pairs.";
]

let entries : entry list =
  ambient @ prelude @ email @ maybe_result @ time
  @ int32 @ db @ either @ string_ @ list_ @ list_prim @ int_ @ float_
  @ dict @ set_ @ tuple @ money @ random_uuid_id_env @ json_codecs
  @ api_test @ jwt @ cache @ database @ http_client @ agent @ queue
  @ telemetry
