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

(* ── Tesl.CivilTime (GitHub #78) ───────────────────────────────────────────── *)
(* The calendar half of time, separate from Tesl.Time because a DATE is not an
   INSTANT.  Every function is exact integer arithmetic on a day number, so a DST
   transition cannot move it; the module is LIFTED (tesl/civil-time.tesl), so the
   signatures below are carried verbatim like Tesl.List's rather than rendered
   from stdlib_env.  Pure: no capability, no clock read. *)

let civil_time : entry list = [
  e "CivilDate" ~m:"Tesl.CivilTime"
    ~kind:(KType "type CivilDate   # opaque: a day number since 1970-01-01 AND the zone it was read in; built only by CivilTime.fromParts / fromChecked / fromDayNumber / fromInstant / fromIso")
    ~doc:"A calendar date together with the calendar it was read in. Opaque, so February 30 has no value at all rather than being rejected at every use. The zone is part of the value because 2026-08-05 in Tokyo and in Los Angeles label different instants — which is why CivilTime.startOfDay / endOfDay take no zone argument and cannot disagree with the one the date was built in.";
  e "IsoWeek" ~m:"Tesl.CivilTime"
    ~kind:(KType "type IsoWeek   # opaque: the week-numbering YEAR and the week within it, as ONE value; built only by CivilTime.isoWeekOf / isoWeek")
    ~doc:"An ISO-8601 week. A week number is meaningless without its week-year — week 1 of a year can fall in December of the previous one — so the pair travels together and cannot be mispaired, which is why CivilTime.isoWeekOf returns one IsoWeek instead of two Ints.";
  e "Month" ~m:"Tesl.CivilTime"
    ~kind:(KType "type Month = January | February | March | April | May | June | July | August | September | October | November | December")
    ~doc:"A calendar month. An ADT rather than an Int, so `case` over a month is exhaustive and the 0-based/1-based month bug cannot be written; CivilTime.monthNumber gives the 1..12 Int when a wire format needs one.";
  v "January"   ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 1.";
  v "February"  ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 2 — 28 days, or 29 when CivilTime.isLeapYear says so.";
  v "March"     ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 3.";
  v "April"     ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 4.";
  v "May"       ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 5.";
  v "June"      ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 6.";
  v "July"      ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 7.";
  v "August"    ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 8.";
  v "September" ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 9.";
  v "October"   ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 10.";
  v "November"  ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 11.";
  v "December"  ~m:"Tesl.CivilTime" ~doc:"Month: monthNumber 12.";
  e "Weekday" ~m:"Tesl.CivilTime"
    ~kind:(KType "type Weekday = Monday | Tuesday | Wednesday | Thursday | Friday | Saturday | Sunday")
    ~doc:"A day of the week, ISO-ordered from Monday; CivilTime.weekdayNumber gives the ISO number (Monday = 1 … Sunday = 7), which is not the C/JavaScript Sunday = 0.";
  v "Monday"    ~m:"Tesl.CivilTime" ~doc:"Weekday: ISO number 1, and the day CivilTime.startOfWeek returns.";
  v "Tuesday"   ~m:"Tesl.CivilTime" ~doc:"Weekday: ISO number 2.";
  v "Wednesday" ~m:"Tesl.CivilTime" ~doc:"Weekday: ISO number 3.";
  v "Thursday"  ~m:"Tesl.CivilTime" ~doc:"Weekday: ISO number 4 — the day that decides an ISO week's week-year.";
  v "Friday"    ~m:"Tesl.CivilTime" ~doc:"Weekday: ISO number 5.";
  v "Saturday"  ~m:"Tesl.CivilTime" ~doc:"Weekday: ISO number 6.";
  v "Sunday"    ~m:"Tesl.CivilTime" ~doc:"Weekday: ISO number 7, NOT 0.";
  (* The six range facts: an accessor hands back the value already carrying its
     bound, so a caller can REQUIRE the bound without re-deriving it.  Each is
     minted by one module-private check that verifies the bound rather than
     asserting it, so none can be forged. *)
  e "IsDayOfMonth" ~m:"Tesl.CivilTime" ~kind:(KFact "fact IsDayOfMonth (n: Int)")
    ~doc:"The Int is a day of the month, 1..31; carried out of CivilTime.day so downstream code need not re-derive the bound.";
  e "IsMonthNumber" ~m:"Tesl.CivilTime" ~kind:(KFact "fact IsMonthNumber (n: Int)")
    ~doc:"The Int is a month number, 1..12; carried out of CivilTime.monthNumber.";
  e "IsDayOfYear" ~m:"Tesl.CivilTime" ~kind:(KFact "fact IsDayOfYear (n: Int)")
    ~doc:"The Int is a day of the year, 1..366; carried out of CivilTime.dayOfYear.";
  e "IsWeekNumber" ~m:"Tesl.CivilTime" ~kind:(KFact "fact IsWeekNumber (n: Int)")
    ~doc:"The Int is an ISO week number, 1..53; carried out of CivilTime.weekNumber.";
  e "IsWeekdayNumber" ~m:"Tesl.CivilTime" ~kind:(KFact "fact IsWeekdayNumber (n: Int)")
    ~doc:"The Int is an ISO weekday number, 1..7 with Monday = 1; carried out of CivilTime.weekdayNumber.";
  e "IsMonthLength" ~m:"Tesl.CivilTime" ~kind:(KFact "fact IsMonthLength (n: Int)")
    ~doc:"The Int is a month's length, 28..31; carried out of CivilTime.daysInMonth.";
  e "DayOfMonth" ~m:"Tesl.CivilTime" ~kind:(KFact "fact DayOfMonth (y: Int) (m: Month) (d: Int)")
    ~doc:"That day exists in that month of that year — the precondition of the TOTAL constructor CivilTime.fromChecked. Minted by `check CivilTime.checkDayOfMonth`, so a caller who validated the parts at a boundary does not also unwrap a Maybe.";
  e "SameCalendar" ~m:"Tesl.CivilTime" ~kind:(KFact "fact SameCalendar (a: CivilDate) (b: CivilDate)")
    ~doc:"Both dates were read in the same zone, so comparing them is meaningful. Required by every two-date operation (CivilTime.diffDays / datesBetween / isBefore) and minted only by `check CivilTime.sameCalendar`: \"days between today-in-Tokyo and today-in-LA\" has no right answer, so it must not silently have one.";
  e "CivilTime.checkDayOfMonth" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "check CivilTime.checkDayOfMonth(y: Int, m: Month, d: Int) -> d: Int ::: DayOfMonth y m d")
    ~doc:"Validates a (year, month, day) triple at a boundary, minting DayOfMonth for CivilTime.fromChecked; fails 400 when that month has no such day. Use CivilTime.fromParts instead when the caller would rather branch than discharge.";
  e "CivilTime.sameCalendar" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "check CivilTime.sameCalendar(a: CivilDate, b: CivilDate) -> b: CivilDate ::: SameCalendar a b")
    ~doc:"Discharges the obligation that two dates share a calendar, once, for CivilTime.diffDays / datesBetween / isBefore; fails 400 when they were read in different zones, because dates from different zones are not comparable.";
  e "CivilTime.fromParts" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.fromParts(z: TimeZone, y: Int, m: Month, d: Int) -> Maybe CivilDate")
    ~doc:"Builds a date from calendar parts in the zone z, Nothing when the parts are not a real date (2026-02-30). The one validation point for untrusted input.";
  e "CivilTime.fromChecked" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.fromChecked(z: TimeZone, y: Int, m: Month, d: Int ::: DayOfMonth y m d) -> CivilDate")
    ~doc:"Total counterpart of CivilTime.fromParts: the day is already known to exist in that month, so there is no failure case left to represent and no Maybe to unwrap.";
  e "CivilTime.fromDayNumber" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.fromDayNumber(z: TimeZone, n: Int) -> CivilDate")
    ~doc:"Total: the date n days after 1970-01-01 (negative before it), read in z. Every integer names a real civil date, which is exactly why the day number is the representation.";
  e "CivilTime.fromInstant" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.fromInstant(z: TimeZone, ts: PosixMillis) -> CivilDate")
    ~doc:"The civil date an instant falls on IN z. This is where a zone is genuinely needed: the same instant is two different dates on either side of the date line.";
  e "CivilTime.fromIso" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.fromIso(z: TimeZone, s: String) -> Maybe CivilDate")
    ~doc:"Strict YYYY-MM-DD read as a date in z; anything else — a bad length, a missing separator, a date that does not exist — is Nothing rather than a guess.";
  e "CivilTime.startOfDay" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.startOfDay(d: CivilDate) -> PosixMillis")
    ~doc:"The first instant of that day, DST-correct: the zone offset is resolved AT the local midnight, not at the epoch. No zone argument — the date carries the one it was read in — and this is the INCLUSIVE lower bound of a day filter.";
  e "CivilTime.endOfDay" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.endOfDay(d: CivilDate) -> PosixMillis")
    ~doc:"The first instant of the NEXT day — the EXCLUSIVE upper bound, so a calendar-day filter is the half-open range [startOfDay, endOfDay) and needs no 23:59:59.999 fudge. It has its own name because \"+ one day\" in milliseconds is the DST bug this module exists to remove.";
  e "CivilTime.dayNumber" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.dayNumber(d: CivilDate) -> Int")
    ~doc:"Days since 1970-01-01, exact and negative before it — the Int to store when a column has to be a plain integer.";
  e "CivilTime.zone" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.zone(d: CivilDate) -> TimeZone")
    ~doc:"The calendar the date was read in. Part of the value, so the producer's intent stays recoverable.";
  e "CivilTime.year" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.year(d: CivilDate) -> Int")
    ~doc:"The proleptic-Gregorian year of the date — see CivilTime.weekYear for the ISO week-numbering year, which differs around New Year.";
  e "CivilTime.month" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.month(d: CivilDate) -> Month")
    ~doc:"The Month of the date, as a constructor; CivilTime.monthNumber turns it into 1..12.";
  e "CivilTime.day" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.day(d: CivilDate) -> Int ? IsDayOfMonth")
    ~doc:"Day of the month, returned already carrying IsDayOfMonth (1..31) so a caller that needs the bound downstream gets it from here instead of re-deriving it.";
  e "CivilTime.weekday" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.weekday(d: CivilDate) -> Weekday")
    ~doc:"The Weekday the date falls on.";
  e "CivilTime.dayOfYear" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.dayOfYear(d: CivilDate) -> Int ? IsDayOfYear")
    ~doc:"1..366 counting January 1st as 1, returned already carrying IsDayOfYear.";
  e "CivilTime.isoWeekOf" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.isoWeekOf(d: CivilDate) -> IsoWeek")
    ~doc:"The ISO week the date belongs to, as ONE value: a bare week number could be stored or compared without its week-year, which is exactly how week 1 gets filed under the wrong year.";
  e "CivilTime.isoWeek" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.isoWeek(y: Int, w: Int) -> Maybe IsoWeek")
    ~doc:"Builds an IsoWeek from a week-year and week number, Nothing when that year has no such week (a year has 52 or 53; week 54 never).";
  e "CivilTime.weekYear" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.weekYear(w: IsoWeek) -> Int")
    ~doc:"The ISO week-numbering year — NOT the calendar year of the week's dates: a week belongs to the year that owns its Thursday, so 2027-01-01 is in week 53 of 2026.";
  e "CivilTime.weekNumber" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.weekNumber(w: IsoWeek) -> Int ? IsWeekNumber")
    ~doc:"The ISO week number, returned already carrying IsWeekNumber (1..53); only ever meaningful together with CivilTime.weekYear, which is why both come out of one IsoWeek.";
  e "CivilTime.monthNumber" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.monthNumber(m: Month) -> Int ? IsMonthNumber")
    ~doc:"1..12 with January = 1, returned already carrying IsMonthNumber.";
  e "CivilTime.monthFromNumber" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.monthFromNumber(n: Int) -> Maybe Month")
    ~doc:"1..12 to a Month; Nothing for 0, 13 or anything else, so an untrusted number cannot become a wrong month.";
  e "CivilTime.weekdayNumber" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.weekdayNumber(w: Weekday) -> Int ? IsWeekdayNumber")
    ~doc:"The ISO weekday number, Monday = 1 … Sunday = 7, returned already carrying IsWeekdayNumber.";
  e "CivilTime.addDays" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.addDays(d: CivilDate, n: Int) -> CivilDate")
    ~doc:"Moves a date by whole calendar days. This is how you say \"+1 day\": twice a year in a DST zone a civil day is 23 or 25 hours, so `addMs ts 86400000` lands on the wrong wall-clock day.";
  e "CivilTime.diffDays" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.diffDays(a: CivilDate, b: CivilDate ::: SameCalendar a b) -> Int")
    ~doc:"Whole calendar days a - b, exact — where `diffMs a b / 86400000` miscounts across a DST transition, the day between two midnights being 23 or 25 hours long. Requires SameCalendar from `check CivilTime.sameCalendar`: dates read in different zones are not comparable.";
  e "CivilTime.addMonths" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.addMonths(d: CivilDate, n: Int) -> CivilDate")
    ~doc:"Moves a date by whole months, CLAMPING the day of the month: 31 January plus one month is 28 February, or the 29th in a leap year — never 3 March. Clamping is the only total choice; CivilTime.endOfMonth and daysInMonth are there for a caller who wants a different policy.";
  e "CivilTime.startOfMonth" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.startOfMonth(d: CivilDate) -> CivilDate")
    ~doc:"The 1st of that date's month.";
  e "CivilTime.endOfMonth" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.endOfMonth(d: CivilDate) -> CivilDate")
    ~doc:"The LAST day of that date's month (the 28th..31st itself, not the 1st of the next one).";
  e "CivilTime.startOfWeek" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.startOfWeek(d: CivilDate) -> CivilDate")
    ~doc:"The ISO Monday of that date's week.";
  e "CivilTime.startOfYear" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.startOfYear(d: CivilDate) -> CivilDate")
    ~doc:"January 1st of that date's year.";
  e "CivilTime.daysInMonth" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.daysInMonth(y: Int, m: Month) -> Int ? IsMonthLength")
    ~doc:"28..31, returned already carrying IsMonthLength; the year is required because February's length depends on it.";
  e "CivilTime.isLeapYear" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.isLeapYear(y: Int) -> Bool")
    ~doc:"True for proleptic-Gregorian leap years, century rule included (1900 is not, 2000 is).";
  e "CivilTime.datesBetween" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.datesBetween(a: CivilDate, b: CivilDate ::: SameCalendar a b) -> List CivilDate")
    ~doc:"Every date in the HALF-OPEN range [a, b), ascending, and empty when b is not after a — so consecutive periods do not double-count the boundary day. Requires SameCalendar from `check CivilTime.sameCalendar`.";
  e "CivilTime.isBefore" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.isBefore(a: CivilDate, b: CivilDate ::: SameCalendar a b) -> Bool")
    ~doc:"True when a is an earlier day than b. Requires SameCalendar from `check CivilTime.sameCalendar`, because ordering dates read in different zones compares two different calendars.";
  e "CivilTime.toIso" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.toIso(d: CivilDate) -> String")
    ~doc:"\"2026-08-05\", zero-padded. Zone-free: a date is a LABEL, and formatting one through an instant would need a zone it has no business needing — that round trip is this module's off-by-one-day bug in miniature.";
  e "CivilTime.isoWeekLabel" ~m:"Tesl.CivilTime"
    ~kind:(KSyntax "fn CivilTime.isoWeekLabel(w: IsoWeek) -> String")
    ~doc:"\"2026-W32\", zero-padded. The week-year is part of the label because the week number alone does not identify a week.";
]

(* ── Tesl.Int32 ────────────────────────────────────────────────────────────── *)

let int32 : entry list = [
  e "Int32" ~m:"Tesl.Int32"
    ~kind:(KType "type Int32   # nominal 32-bit-range integer for wire/storage boundaries; does NOT unify with Int")
    ~doc:"A JS-safe bounded integer boundary type. Range rule: an operation that cannot leave [-2^31, 2^31) returns Int32, one that can returns Maybe Int32 (never a silent wrap).";
  e "IsNonNegative" ~m:"Tesl.Int32" ~kind:(KFact "fact IsNonNegative (n: Int32)")
    ~doc:"The Int32 is >= 0; minted by Int32.nonNegative.";
  e "IsNonZero" ~m:"Tesl.Int32" ~kind:(KFact "fact IsNonZero (n: Int32)")
    ~doc:"The Int32 is != 0; minted by Int32.nonZero, required by Int32.divide / Int32.modulo.";
  f "Int32.fromInt" [ "n" ] ~m:"Tesl.Int32" ~doc:"Checked narrowing: Something for values in 32-bit range, Nothing otherwise.";
  f "Int32.toInt" [ "n32" ] ~m:"Tesl.Int32" ~doc:"Total widening of an Int32 back to Int.";
  f "Int32.fromIntClamped" [ "n" ] ~m:"Tesl.Int32" ~doc:"Saturating narrowing: values below/above the range become minValue/maxValue.";
  f "Int32.parse" [ "s" ] ~m:"Tesl.Int32" ~doc:"Parses an Int32; Nothing on malformed input or out-of-range value.";
  f "Int32.fromFloat" [ "f" ] ~m:"Tesl.Int32" ~doc:"Truncates toward zero; Nothing when out of range (NaN and infinities included).";
  f "Int32.toFloat" [ "n32" ] ~m:"Tesl.Int32" ~doc:"Widens an Int32 to Float (always exact — 32-bit ints fit in a double).";
  f "Int32.toString" [ "n32" ] ~m:"Tesl.Int32" ~doc:"Renders an Int32 as a String.";
  v "Int32.minValue" ~m:"Tesl.Int32" ~doc:"The smallest Int32, -2147483648.";
  v "Int32.maxValue" ~m:"Tesl.Int32" ~doc:"The largest Int32, 2147483647.";
  f "Int32.min" [ "a"; "b" ] ~m:"Tesl.Int32" ~doc:"The smaller of two Int32s.";
  f "Int32.max" [ "a"; "b" ] ~m:"Tesl.Int32" ~doc:"The larger of two Int32s.";
  f "Int32.clamp" [ "n"; "lo"; "hi" ] ~m:"Tesl.Int32" ~doc:"Clamps n into [lo, hi].";
  f "Int32.add" [ "a"; "b" ] ~m:"Tesl.Int32" ~doc:"Checked addition: Nothing when the sum leaves the 32-bit range.";
  f "Int32.subtract" [ "a"; "b" ] ~m:"Tesl.Int32" ~doc:"Checked subtraction: Nothing when the difference leaves the 32-bit range.";
  f "Int32.multiply" [ "a"; "b" ] ~m:"Tesl.Int32" ~doc:"Checked multiplication: Nothing when the product leaves the 32-bit range.";
  f "Int32.negate" [ "n" ] ~m:"Tesl.Int32" ~doc:"Checked negation: Nothing for minValue, whose positive has no Int32.";
  f "Int32.pow" [ "base"; "exp" ] ~m:"Tesl.Int32" ~doc:"Checked exponentiation: Nothing for a negative exponent or an out-of-range result.";
  f "Int32.isPositive" [ "n" ] ~m:"Tesl.Int32" ~doc:"True when n > 0.";
  f "Int32.isNegative" [ "n" ] ~m:"Tesl.Int32" ~doc:"True when n < 0.";
  f "Int32.isZero" [ "n" ] ~m:"Tesl.Int32" ~doc:"True when n == 0.";
  f "Int32.isEven" [ "n" ] ~m:"Tesl.Int32" ~doc:"True when n is even.";
  f "Int32.isOdd" [ "n" ] ~m:"Tesl.Int32" ~doc:"True when n is odd.";
  f "Int32.sign" [ "n" ] ~m:"Tesl.Int32" ~doc:"-1, 0, or 1 by the sign of n (an Int, so it composes with Int arithmetic).";
  f "Int32.digits" [ "n" ] ~m:"Tesl.Int32" ~doc:"Number of decimal digits in abs(n).";
  e "Int32.abs" ~m:"Tesl.Int32"
    ~kind:(KFunction [ "n" ])
    ~doc:"Checked absolute value: Nothing for minValue, whose absolute value has no Int32.";
  e "Int32.nonZero" ~m:"Tesl.Int32"
    ~kind:(KSyntax "check Int32.nonZero(n: Int32) -> n: Int32 ::: IsNonZero n")
    ~doc:"Check function: passes n != 0, minting IsNonZero.";
  e "Int32.nonNegative" ~m:"Tesl.Int32"
    ~kind:(KSyntax "check Int32.nonNegative(n: Int32) -> n: Int32 ::: IsNonNegative n")
    ~doc:"Check function: passes n >= 0, minting IsNonNegative.";
  e "Int32.divide" ~m:"Tesl.Int32"
    ~kind:(KSyntax "fn Int32.divide(a: Int32, b: Int32 ::: IsNonZero b) -> Maybe Int32")
    ~doc:"Integer division; the divisor needs an IsNonZero proof, and -minValue/-1 is Nothing.";
  e "Int32.modulo" ~m:"Tesl.Int32"
    ~kind:(KSyntax "fn Int32.modulo(a: Int32, b: Int32 ::: IsNonZero b) -> Int32")
    ~doc:"Integer remainder; the divisor needs an IsNonZero proof (from Int32.nonZero).";
]

(* ── Tesl.DB (dbRead/dbWrite are generated capability rows) ──────────────── *)

let db : entry list = [
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
  f "String.isEmpty" [ "s" ] ~m:"Tesl.String" ~doc:"True when the string has length 0.";
  f "String.trimLeft" [ "s" ] ~m:"Tesl.String" ~doc:"Removes leading whitespace.";
  f "String.trimRight" [ "s" ] ~m:"Tesl.String" ~doc:"Removes trailing whitespace.";
  f "String.slice" [ "s"; "start"; "end" ] ~m:"Tesl.String" ~doc:"Substring from start (inclusive) to end (exclusive).";
  f "String.repeat" [ "s"; "n" ] ~m:"Tesl.String" ~doc:"Repeats the string n times.";
  f "String.reverse" [ "s" ] ~m:"Tesl.String" ~doc:"Reverses the characters.";
  f "String.toFloat" [ "s" ] ~m:"Tesl.String" ~doc:"Parses a float; Nothing on malformed input.";
  f "String.fromFloat" [ "f" ] ~m:"Tesl.String" ~doc:"Renders a Float as a String.";
  f "String.lines" [ "s" ] ~m:"Tesl.String" ~doc:"Splits on newlines.";
  f "String.words" [ "s" ] ~m:"Tesl.String" ~doc:"Splits on runs of whitespace.";
  f "String.padLeft" [ "s"; "width"; "char" ] ~m:"Tesl.String" ~doc:"Left-pads to width with the given character.";
  f "String.padRight" [ "s"; "width"; "char" ] ~m:"Tesl.String" ~doc:"Right-pads to width with the given character.";
  f "String.dropPrefix" [ "s"; "prefix" ] ~m:"Tesl.String" ~doc:"Removes prefix when present, otherwise returns s unchanged.";
  f "String.dropSuffix" [ "s"; "suffix" ] ~m:"Tesl.String" ~doc:"Removes suffix when present, otherwise returns s unchanged.";
  f "String.indexOf" [ "s"; "sub" ] ~m:"Tesl.String" ~doc:"Index of the first occurrence of sub, or Nothing.";
  e "String.requireNonEmpty" ~m:"Tesl.String"
    ~kind:(KSyntax "check String.requireNonEmpty(s: String) -> s: String ::: IsNonEmpty s")
    ~doc:"Check function: passes non-empty strings, minting IsNonEmpty.";
]

(* ── Tesl.Regex ────────────────────────────────────────────────────────────── *)
(* Pattern-literal-only regex (LANGUAGE-SPEC.md §21.6).  The pattern is
   argument 1 of every function and is validated when the program is compiled
   (VREGEX001-4), which is why `Regex.captures` can promise `List String`
   rather than `List (Maybe String)`. *)

let regex : entry list = [
  f "Regex.matches" [ "pattern"; "input" ] ~m:"Tesl.Regex"
    ~doc:"True when the literal pattern matches anywhere in input; anchor with ^ and $ for a whole-string match.";
  f "Regex.find" [ "pattern"; "input" ] ~m:"Tesl.Regex"
    ~doc:"The text of the first match, or Nothing.";
  f "Regex.findAll" [ "pattern"; "input" ] ~m:"Tesl.Regex"
    ~doc:"The text of every non-overlapping match, left to right.";
  f "Regex.captures" [ "pattern"; "input" ] ~m:"Tesl.Regex"
    ~doc:"The capture groups of the first match (whole match excluded); every group participates, so there is no inner Maybe.";
  f "Regex.replace" [ "pattern"; "input"; "replacement" ] ~m:"Tesl.Regex"
    ~doc:"Replaces every match; the replacement is inserted literally (no $1 / backslash-1 group references).";
  f "Regex.split" [ "pattern"; "input" ] ~m:"Tesl.Regex"
    ~doc:"Splits input on every match of the pattern.";
]

(* ── Tesl.Url / Tesl.Net (GitHub #68) ──────────────────────────────────────── *)
(* Application-level URL / host checking.  Both modules are pure — no capability,
   no I/O, no name resolution.  They close the "the string check itself was
   wrong" class (port smuggling, case, trailing-dot FQDN, alternate IP-literal
   encodings); they do NOT replace the runtime's resolve-then-pin egress
   containment, which is always on in Tesl.HttpClient (issue #48). *)

let url : entry list = [
  e "Url" ~m:"Tesl.Url"
    ~kind:(KType "type Url   # opaque; built only by Url.parse")
    ~doc:"A parsed, normalized URL. Opaque: every component you read back is already canonical, which is the point of parsing instead of slicing the string.";
  f "Url.parse" [ "text" ] ~m:"Tesl.Url"
    ~doc:"Parses an authority-based URL (scheme://host[:port][/path][?query][#fragment]). Nothing for anything ambiguous or unsafe to guess at: a control character or space anywhere, a backslash, a URL with no // authority (mailto:), an unbracketed IPv6 literal, an empty or out-of-range port, or a host this runtime will not vouch for.";
  f "Url.scheme" [ "url" ] ~m:"Tesl.Url" ~doc:"The scheme, lowercased and without the colon.";
  f "Url.host" [ "url" ] ~m:"Tesl.Url"
    ~doc:"The host, CANONICAL: lowercased, trailing dot stripped, IPv6 brackets removed, and every IP-literal spelling (decimal/octal/hex IPv4, IPv4-mapped IPv6) folded to one form. Never carries the port.";
  f "Url.port" [ "url" ] ~m:"Tesl.Url" ~doc:"The port, only when it was written in the URL.";
  f "Url.effectivePort" [ "url" ] ~m:"Tesl.Url"
    ~doc:"The written port, or the scheme default (http 80, https 443, ws 80, wss 443, ftp 21); Nothing when the scheme has no default.";
  f "Url.path" [ "url" ] ~m:"Tesl.Url" ~doc:"The path; \"/\" when the URL had none.";
  f "Url.query" [ "url" ] ~m:"Tesl.Url" ~doc:"The text after ?, up to any #; Nothing when no ? was written (Something \"\" when it was written empty).";
  f "Url.fragment" [ "url" ] ~m:"Tesl.Url" ~doc:"The text after the first #; Nothing when no # was written.";
  f "Url.userInfo" [ "url" ] ~m:"Tesl.Url"
    ~doc:"Everything before the LAST @ of the authority. Exposed rather than dropped because https://trusted.example.com@127.0.0.1/ puts a trusted-looking name in the credentials slot; refusing URLs that carry userinfo is one line.";
  f "Url.toString" [ "url" ] ~m:"Tesl.Url"
    ~doc:"Re-serializes from the canonical parts, so the URL you checked and the URL you fetch are the same string.";
]

let net : entry list = [
  e "HostClass" ~m:"Tesl.Net"
    ~kind:(KType "type HostClass = Loopback | PrivateIp | LinkLocal | Cgnat | Multicast | Unspecified | PublicIp | DomainName | InvalidHost")
    ~doc:"How a host classifies. Case over it rather than chaining predicates: exhaustiveness is what stops a forgotten range.";
  v "Loopback" ~m:"Tesl.Net" ~doc:"HostClass: 127.0.0.0/8, ::1, or an RFC 6761 localhost name.";
  v "PrivateIp" ~m:"Tesl.Net" ~doc:"HostClass: 10/8, 172.16/12, 192.168/16, or IPv6 unique-local fc00::/7.";
  v "LinkLocal" ~m:"Tesl.Net" ~doc:"HostClass: 169.254.0.0/16 (the cloud instance-metadata endpoint) or fe80::/10.";
  v "Cgnat" ~m:"Tesl.Net" ~doc:"HostClass: carrier-grade NAT, 100.64.0.0/10.";
  v "Multicast" ~m:"Tesl.Net" ~doc:"HostClass: 224.0.0.0/4 and above, or IPv6 ff00::/8.";
  v "Unspecified" ~m:"Tesl.Net" ~doc:"HostClass: 0.0.0.0/8 or the IPv6 unspecified address ::.";
  v "PublicIp" ~m:"Tesl.Net" ~doc:"HostClass: an address literal in none of the reserved ranges.";
  v "DomainName" ~m:"Tesl.Net" ~doc:"HostClass: a valid DNS name. NOT a safety verdict — it can still resolve to a forbidden address, which only the HTTP client's resolve-then-pin can judge.";
  v "InvalidHost" ~m:"Tesl.Net" ~doc:"HostClass: not a host this runtime will vouch for (bad characters, a malformed address literal, an all-numeric final label). Refuse it.";
  f "Net.classifyHost" [ "host" ] ~m:"Tesl.Net"
    ~doc:"Classifies a host after canonicalizing it, so LOCALHOST, localhost., 2130706433 and [::ffff:127.0.0.1] all classify as Loopback. The primitive to reach for: a case over the result cannot forget a range.";
  f "Net.normalizeHost" [ "host" ] ~m:"Tesl.Net"
    ~doc:"The canonical spelling of a host (lowercased, trailing dot stripped, unbracketed, every IP-literal encoding folded), or Nothing when it is not a host worth vouching for. Compare and store this, never the raw text.";
  f "Net.isLoopback" [ "host" ] ~m:"Tesl.Net" ~doc:"True for 127.0.0.0/8, ::1 and the localhost names, in any spelling.";
  f "Net.isPrivate" [ "host" ] ~m:"Tesl.Net" ~doc:"True for RFC1918 and IPv6 unique-local addresses, in any spelling.";
  f "Net.isLinkLocal" [ "host" ] ~m:"Tesl.Net" ~doc:"True for 169.254.0.0/16 (cloud metadata) and fe80::/10.";
  f "Net.isCgnat" [ "host" ] ~m:"Tesl.Net" ~doc:"True for 100.64.0.0/10.";
  f "Net.isMulticast" [ "host" ] ~m:"Tesl.Net" ~doc:"True for 224.0.0.0/4 and above, and IPv6 ff00::/8.";
  f "Net.isIpLiteral" [ "host" ] ~m:"Tesl.Net" ~doc:"True when the host IS an address in some spelling rather than a DNS name. A localhost name is not a literal, but it is isLoopback.";
  f "Net.isIpv4Mapped" [ "host" ] ~m:"Tesl.Net" ~doc:"True when the host was written as an IPv4-mapped or IPv4-compatible IPv6 literal ([::ffff:127.0.0.1]) — the spelling hand-written checks miss most often.";
  f "Net.isForbiddenHost" [ "host" ] ~m:"Tesl.Net"
    ~doc:"The one-line outbound guard: True for every non-public address literal in any spelling, the localhost names, and anything unparseable (fail-closed). False means only that the string check found nothing wrong — a DomainName still has to resolve somewhere, and judging that is Tesl.HttpClient's resolve-then-pin.";
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
  f "Int.fromFloat" [ "f" ] ~m:"Tesl.Int" ~doc:"Converts a Float to Int, truncating toward zero.";
  f "Int.toFloat" [ "n" ] ~m:"Tesl.Int" ~doc:"Converts an Int to Float.";
  f "Int.clamp" [ "n"; "lo"; "hi" ] ~m:"Tesl.Int" ~doc:"Clamps n into [lo, hi].";
  f "Int.isPositive" [ "n" ] ~m:"Tesl.Int" ~doc:"True when n > 0.";
  f "Int.isNegative" [ "n" ] ~m:"Tesl.Int" ~doc:"True when n < 0.";
  f "Int.isZero" [ "n" ] ~m:"Tesl.Int" ~doc:"True when n == 0.";
  f "Int.isEven" [ "n" ] ~m:"Tesl.Int" ~doc:"True when n is even.";
  f "Int.isOdd" [ "n" ] ~m:"Tesl.Int" ~doc:"True when n is odd.";
  f "Int.gcd" [ "a"; "b" ] ~m:"Tesl.Int" ~doc:"Greatest common divisor.";
  f "Int.lcm" [ "a"; "b" ] ~m:"Tesl.Int" ~doc:"Least common multiple.";
  f "Int.pow" [ "base"; "exp" ] ~m:"Tesl.Int" ~doc:"Integer exponentiation.";
  f "Int.digits" [ "n" ] ~m:"Tesl.Int" ~doc:"Number of decimal digits in abs(n).";
  f "Int.sign" [ "n" ] ~m:"Tesl.Int" ~doc:"-1, 0, or 1 by the sign of n.";
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
  e "FloatNonNegative" ~m:"Tesl.Float" ~kind:(KFact "fact FloatNonNegative (f: Float)")
    ~doc:"The float is >= 0.0; minted by Float.requireNonNegative, required as the argument proof of Float.sqrt (a negative input has no real square root).";
  f "Float.add" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"Float addition.";
  f "Float.sub" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"Float subtraction.";
  f "Float.mul" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"Float multiplication.";
  f "Float.div" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"Float division; the denominator must carry a FloatNonZero proof (from Float.requireNonZero).";
  f "Float.requireNonZero" [ "f" ] ~m:"Tesl.Float" ~doc:"Check function: passes f != 0.0, minting FloatNonZero.";
  f "Float.requireNonNegative" [ "f" ] ~m:"Tesl.Float" ~doc:"Check function: passes f >= 0.0, minting FloatNonNegative. Zero is accepted, since sqrt 0.0 is 0.0.";
  f "Float.round" [ "f" ] ~m:"Tesl.Float" ~doc:"Rounds to the nearest integer.";
  f "Float.floor" [ "f" ] ~m:"Tesl.Float" ~doc:"Largest integer <= f.";
  f "Float.ceil" [ "f" ] ~m:"Tesl.Float" ~doc:"Smallest integer >= f.";
  f "Float.parse" [ "s" ] ~m:"Tesl.Float" ~doc:"Parses a float; Nothing on malformed input.";
  f "Float.toString" [ "f" ] ~m:"Tesl.Float" ~doc:"Renders a Float as a String.";
  f "Float.toInt" [ "f" ] ~m:"Tesl.Float" ~doc:"Converts to Int, truncating toward zero.";
  f "Float.abs" [ "f" ] ~m:"Tesl.Float" ~doc:"Absolute value.";
  f "Float.min" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"The smaller of two floats.";
  f "Float.max" [ "a"; "b" ] ~m:"Tesl.Float" ~doc:"The larger of two floats.";
  f "Float.clamp" [ "f"; "lo"; "hi" ] ~m:"Tesl.Float" ~doc:"Clamps f into [lo, hi].";
  f "Float.sqrt" [ "f" ] ~m:"Tesl.Float" ~doc:"Square root.";
  f "Float.pow" [ "base"; "exp" ] ~m:"Tesl.Float" ~doc:"Exponentiation.";
  f "Float.log" [ "f" ] ~m:"Tesl.Float" ~doc:"Natural logarithm.";
  f "Float.exp" [ "f" ] ~m:"Tesl.Float" ~doc:"e raised to f.";
  f "Float.sin" [ "f" ] ~m:"Tesl.Float" ~doc:"Sine (radians).";
  f "Float.cos" [ "f" ] ~m:"Tesl.Float" ~doc:"Cosine (radians).";
  f "Float.tan" [ "f" ] ~m:"Tesl.Float" ~doc:"Tangent (radians).";
  f "Float.isNaN" [ "f" ] ~m:"Tesl.Float" ~doc:"True when f is NaN.";
  f "Float.isInfinite" [ "f" ] ~m:"Tesl.Float" ~doc:"True when f is +inf or -inf.";
  f "Float.isPositive" [ "f" ] ~m:"Tesl.Float" ~doc:"True when f > 0.0.";
  f "Float.isNegative" [ "f" ] ~m:"Tesl.Float" ~doc:"True when f < 0.0.";
  f "Float.isZero" [ "f" ] ~m:"Tesl.Float" ~doc:"True when f == 0.0.";
  f "Float.sign" [ "f" ] ~m:"Tesl.Float" ~doc:"1.0, -1.0, or 0.0 by the sign of f.";
  v "Float.infinity" ~m:"Tesl.Float" ~doc:"Positive infinity.";
  v "Float.nan" ~m:"Tesl.Float" ~doc:"Not-a-number.";
]

(* ── Tesl.Dict ─────────────────────────────────────────────────────────────── *)

let dict : entry list = [
  e "Dict" ~m:"Tesl.Dict" ~kind:(KType "type Dict k v   # immutable key-value map") ~doc:"An immutable dictionary from keys to values. An UNORDERED datatype: lookup, membership, insertion, removal, equality, and size are independent of storage order, and no iteration order is promised. A backend may return a deterministic internal order, but that is an implementation detail and must not be relied on.";
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
  f "Dict.keys" [ "d" ] ~m:"Tesl.Dict" ~doc:"The keys as a list, each once, in UNSPECIFIED order. Sort explicitly when order matters (presentation, pagination, snapshots, signatures, hashing, canonical serialization). Dict.keys and Dict.values have no promised positional relationship — use Dict.toList to pair them.";
  f "Dict.values" [ "d" ] ~m:"Tesl.Dict" ~doc:"One value per binding (multiplicity preserved), in UNSPECIFIED order. See Dict.keys.";
  f "Dict.fromList" [ "pairs" ] ~m:"Tesl.Dict" ~doc:"Builds a dict from (key, value) pairs; later duplicates win.";
  f "Dict.toList" [ "d" ] ~m:"Tesl.Dict" ~doc:"The entries as (key, value) pairs, each binding once, in UNSPECIFIED order. Pairing is guaranteed; order is not.";
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
  e "Set" ~m:"Tesl.Set" ~kind:(KType "type Set a   # immutable set of distinct values") ~doc:"An immutable set of distinct values. An UNORDERED datatype: membership, size, equality, and set algebra are independent of storage order, and no iteration order is promised. A backend may return a deterministic internal order, but that is an implementation detail and must not be relied on.";
  v "Set.empty" ~m:"Tesl.Set" ~doc:"The empty set.";
  f "Set.singleton" [ "x" ] ~m:"Tesl.Set" ~doc:"A one-element set.";
  f "Set.insert" [ "x"; "s" ] ~m:"Tesl.Set" ~doc:"Adds an element.";
  f "Set.remove" [ "x"; "s" ] ~m:"Tesl.Set" ~doc:"Removes an element, if present.";
  f "Set.delete" [ "x"; "s" ] ~m:"Tesl.Set" ~doc:"Removes an element (same as remove).";
  f "Set.member" [ "x"; "s" ] ~m:"Tesl.Set" ~doc:"True when x is in the set.";
  f "Set.size" [ "s" ] ~m:"Tesl.Set" ~doc:"Number of elements.";
  f "Set.isEmpty" [ "s" ] ~m:"Tesl.Set" ~doc:"True when the set has no elements.";
  f "Set.toList" [ "s" ] ~m:"Tesl.Set" ~doc:"Every member exactly once, in UNSPECIFIED order. Sort explicitly when order matters.";
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
  f "requireSecret" [ "name" ] ~m:"Tesl.Env" ~doc:"Reads an environment variable straight into a Secret, failing at startup if unset — no String ever exists in Tesl code. A Secret has no `.value`: hand it to Crypto.signWith / Crypto.keyFingerprint / HttpClient.bearer, store it in a column, or compare it with == (constant-time).";
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
    ~kind:(KType "type JobResult a = JobOk a | JobFailed a String")
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
  (* `f` (KFunction), not `KSyntax` like its neighbours: this one HAS a real
     stdlib_env scheme, so the rendered signature comes from the live checker and
     cannot drift from it. *)
  f "responseCookie" [ "response" ] ~m:"Tesl.ApiTest" ~doc:"The session cookie a response set, as a Cookie-header-ready `name=value` pair you can hand straight to a request's `cookie` clause. Nothing when the response set none (including every error response — cookies attach to 2xx only). The attributes are stripped; assert those against response.headers's \"set-cookie\" entry.";
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
  e "expectJobOk" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn expectJobOk(result: JobResult a) -> a") ~doc:"Asserts the job succeeded and returns the processed job.";
  e "expectJobFailed" ~m:"Tesl.ApiTest" ~kind:(KSyntax "fn expectJobFailed(result: JobResult a) -> String") ~doc:"Asserts the job failed and returns the worker's error.";
  f "stubHttp" [ "method"; "url"; "status"; "body" ] ~m:"Tesl.ApiTest"
    ~doc:"Answers a matching outbound HttpClient call from the test instead of the network (\"*\" = any method/url, trailing * = url prefix).";
  f "stubHttpFailure" [ "method"; "url"; "message" ] ~m:"Tesl.ApiTest"
    ~doc:"Makes a matching outbound HttpClient call fail with a connection error, so the failure branch is reachable.";
  f "stubHttpTimeout" [ "method"; "url" ] ~m:"Tesl.ApiTest"
    ~doc:"Makes a matching outbound HttpClient call raise exactly the timeout error a hung upstream produces.";
  f "httpCalled" [ "method"; "url" ] ~m:"Tesl.ApiTest"
    ~doc:"True when the code under test made a matching outbound HTTP call.";
  f "httpCallCount" [ "method"; "url" ] ~m:"Tesl.ApiTest"
    ~doc:"How many matching outbound HTTP calls the code under test made.";
  f "httpLastBody" [ "method"; "url" ] ~m:"Tesl.ApiTest"
    ~doc:"The request body of the last matching outbound HTTP call (fails the test when there was none).";
]

(* ── Tesl.JWT ──────────────────────────────────────────────────────────────── *)

let jwt : entry list = [
  f "JwtToken" [ "raw" ] ~m:"Tesl.JWT" ~doc:"Newtype constructor wrapping a raw JWT string.";
  f "JWT.sign" [ "claims"; "secret" ] ~m:"Tesl.JWT" ~doc:"Signs a string-keyed claims dict into a session JwtToken, stamping `exp` ONE HOUR ahead in epoch seconds (RFC 7519 NumericDate). The signing key is Tesl.Crypto's `Secret` — there is one key type in the language, so `Env.requireSecret \"…\"` feeds this directly and no String ever holds key material. The JOSE header carries `kid` = Crypto.keyFingerprint of the key, so logs can say which key signed. The expiry is not a parameter and cannot be opted out of: a caller who can choose an expiry can choose ten years, and a JWT here is a session token — for a long-lived credential use Crypto.randomToken and store only its Crypto.fingerprint, which is revocable. An `exp` in the claims dict is an error, not an override. Requires `time` as well as `jwt` because it reads the clock. See LANGUAGE-SPEC §21.2.";
  f "JWT.verify" [ "token"; "secret" ] ~m:"Tesl.JWT" ~doc:"Verifies the signature and returns the claims carrying an `Authentic` fact; 401 on a tampered token, or an `exp` (epoch SECONDS, RFC 7519) in the past or unreadable. Check-shaped: bind it with `check`, then read claims with Dict.lookup. Demand `Authentic` on a downstream parameter and \"trusted the cookie without verifying it\" stops compiling.";
  f "JWT.renew" [ "token"; "secret" ] ~m:"Tesl.JWT" ~doc:"Slides the session window forward: verifies the token, then re-issues it with a fresh one-hour `exp` and the ORIGINAL `iat` preserved, carrying every other claim across untouched. Check-shaped, so bind it with `check`; pair it with Http.setSessionCookie and an active user is never logged out mid-task, while an idle one still expires an hour after their last request. 401s on a token that does not verify or has expired, on one with no usable `iat` — absent, not an exact non-negative integer, or dated in the future beyond a minute of clock skew, so its age cannot be bounded (fail closed) — and once the session passes its absolute maximum lifetime of 12 hours from the original login. That cap is not a knob: renewal is presented WITH the token, so it is what keeps a captured token useful for a bounded time in a design that has no revocation.";
  f "JWT.decode" [ "token" ] ~m:"Tesl.JWT" ~doc:"Decodes the claims WITHOUT verifying the signature — never use for auth decisions. Mints no Authentic fact, which is the point.";
]

(* ── Tesl.Crypto ─────────────────────────────────────────────────────────────
   Every doc string names the PRIMITIVE underneath.  Friendly names hide the
   CHOICE, never the FACT: nobody should have to audit Tesl to decide whether
   Tesl's password hashing is sound — the answer is "it is libsodium's
   crypto_pwhash, unmodified, with libsodium's recommended parameters", and it
   has to be checkable in a minute by someone who does not read Racket. *)

let crypto : entry list = [
  e "PasswordHash" ~m:"Tesl.Crypto"
    ~kind:(KType "secret type PasswordHash   # opaque: no constructor, no .value, no ==")
    ~doc:"A stored password hash (libsodium crypto_pwhash / Argon2id, PHC string format). Opaque on purpose: it has no constructor, so a plaintext cannot be blessed as a hash, and no ==, because its only legitimate comparison is Crypto.checkPassword. Secret: redacted in telemetry, logs and the debugger. Store it in a column directly.";
  e "Signature" ~m:"Tesl.Crypto"
    ~kind:(KType "type Signature   # opaque: no .value, no ==; use Crypto.signatureHex to transport")
    ~doc:"An HMAC-SHA256 message authentication tag. Public data (publishing it is the point), so it is NOT redacted — but it has no ==, because comparing tags by hand is not constant-time. Use Crypto.checkSignature to verify and Crypto.signatureHex/signatureBase64 (and the From* parsers) to transport.";
  e "Secret" ~m:"Tesl.Crypto"
    ~kind:(KType "secret type Secret = String   # constant-time ==, redacted everywhere, no .value")
    ~doc:"Key material. A Secret cannot become a String in Tesl code: no interpolation, no concatenation, no .value. Hand it to a function that knows what to do with it, store it in a column, or compare it with == (which lowers to libsodium's sodium_memcmp).";
  e "HashFor" ~m:"Tesl.Crypto" ~kind:(KFact "fact HashFor (plaintext: String)")
    ~doc:"This PasswordHash is the hash of THAT plaintext; minted only by Crypto.hashPassword. Demand it on a storing function's parameter and hashing the wrong one of several same-typed strings in scope stops compiling — the change-password and password-reset shapes.";
  e "PasswordVerified" ~m:"Tesl.Crypto" ~kind:(KFact "fact PasswordVerified (stored: Maybe PasswordHash)")
    ~doc:"A submitted password was checked against this stored hash; minted only by Crypto.checkPassword. Reaching Authenticated still needs an explicit establish — this fact makes that step small and reviewable, it does not remove it.";
  e "Authentic" ~m:"Tesl.Crypto" ~kind:(KFact "fact Authentic (payload: String)")
    ~doc:"This value's message authentication tag verified; minted by Crypto.checkSignature (about a payload String) and by JWT.verify (about the claims Dict) — one predicate, two subject types, so a parameter demanding one shape cannot be handed the other. Require it and \"forgot to check the signature before trusting the value\" stops compiling. Also exposed from Tesl.JWT.";

  e "ProxyBound" ~m:"Tesl.Proxy" ~kind:(KFact "fact ProxyBound (presented: String)")
    ~doc:"A request's proxy-binding header was verified against the configured shared secret; minted ONLY by `check Proxy.verifyBinding` (constant-time). Because it is obtainable only through that verification, an `auth` block that trusts a header reaches its decision by a real check against STORED MATERIAL — not a bare header assertion, which would instead need a network-topology claim (a loopback `listenAddress`).";
  f "Proxy.verifyBinding" [ "config"; "presented" ] ~m:"Tesl.Proxy"
    ~doc:"Verifies a request-supplied proxy-binding header value against a configured shared Secret, constant-time, and mints `ProxyBound` on a match. Use with `check`; the failure is a 401. This is the authenticating-proxy pattern's compile-time evidence: a value verified against stored material needs no topology claim (unlike a bare X-Auth-User header, which does).";

  f "Crypto.hashPassword" [ "plaintext" ] ~m:"Tesl.Crypto"
    ~doc:"Hashes a password for storage. libsodium crypto_pwhash_str — Argon2id, libsodium's INTERACTIVE parameters (currently m=64 MiB, t=2, p=1), read from the library at call time so a libsodium upgrade strengthens every new hash with no code change. Draws a random salt. Rejects input over 1024 bytes: an unbounded memory-hard hash on an unauthenticated endpoint is a denial-of-service amplifier.";
  f "Crypto.checkPassword" [ "stored"; "candidate" ] ~m:"Tesl.Crypto"
    ~doc:"Verifies a submitted password against a stored hash. libsodium crypto_pwhash_str_verify, constant-time. Takes Maybe deliberately: with Nothing it hashes against a dummy, so a missing user and a wrong password cost the same and the login endpoint does not leak which addresses are registered. Use with check: `let ok = check Crypto.checkPassword(user.passwordHash, body.password)`.";
  f "Crypto.needsRehash" [ "stored" ] ~m:"Tesl.Crypto"
    ~doc:"True when a stored hash was minted with weaker parameters than the current ones, or in a format this libsodium cannot parse. libsodium crypto_pwhash_str_needs_rehash. Re-mint on the next successful login — a hash is one-way, so that is the only moment the plaintext exists. Tesl deliberately does not write to the database for you.";

  f "Crypto.signWith" [ "key"; "payload" ] ~m:"Tesl.Crypto"
    ~aliases:["Crypto.hmacSha256"]
    ~doc:"Produces a tag a client cannot forge or tamper with. libsodium crypto_auth_hmacsha256 (HMAC-SHA256). Deliberately not called `sign`: this is SYMMETRIC authentication — anyone who can verify can also forge. The bare name is reserved for asymmetric signing.";
  f "Crypto.checkSignature" [ "key"; "sig"; "payload" ] ~m:"Tesl.Crypto"
    ~doc:"Confirms a payload carries a valid tag for this key. Recomputes the HMAC and compares with libsodium sodium_memcmp (constant-time). Use with check; the failure is a 401. This is why there is no constantTimeEquals on the surface: the compare lives where it cannot be got wrong.";
  f "Crypto.signatureHex" [ "sig" ] ~m:"Tesl.Crypto"
    ~doc:"The transport form of a signature you produced, for putting in a header or a body. A tag is public data, so this is not an unwrap of a secret — but comparing two of these is a timing-unsafe MAC comparison, which is what the SEC004 diagnostic is for.";
  f "Crypto.signatureFromHex" [ "hex" ] ~m:"Tesl.Crypto"
    ~doc:"Parses an inbound hex signature — a webhook's X-Signature header (Stripe, GitHub) — so Crypto.checkSignature can verify it. Malformed input fails the verification cleanly; it never raises.";
  f "Crypto.signatureBase64" [ "sig" ] ~m:"Tesl.Crypto"
    ~doc:"The base64 transport form of a signature you produced — the encoding Standard Webhooks uses (webhook-signature: v1,<base64>). Same status as signatureHex: a tag is public data, and comparing two of these by hand is the SEC004 timing-unsafe MAC comparison.";
  f "Crypto.signatureFromBase64" [ "b64" ] ~m:"Tesl.Crypto"
    ~doc:"Parses an inbound base64 signature — a Standard Webhooks webhook-signature header — so Crypto.checkSignature can verify it. Malformed input fails the verification cleanly; it never raises.";

  f "Crypto.fingerprint" [ "content" ] ~m:"Tesl.Crypto"
    ~aliases:["Crypto.sha256"]
    ~doc:"A stable content digest for ETags, cache keys, dedup and idempotency keys. libsodium crypto_hash_sha256, hex-encoded. NOT for passwords — a fast digest of a password is exactly the mistake Crypto.hashPassword exists to prevent.";
  f "Crypto.keyFingerprint" [ "key" ] ~m:"Tesl.Crypto"
    ~doc:"A short, non-reversible identifier for a key, safe to log: \"did I load the right key?\". Domain-separated SHA-256, truncated to 16 hex characters. It is not proof of key possession.";
  v "Crypto.randomToken" ~m:"Tesl.Crypto"
    ~doc:"An unguessable token: 256 bits from the OS CSPRNG, base64url (43 URL-safe characters). No length parameter, on purpose. Store only its fingerprint, never the token — then a database leak cannot be replayed.";
  f "Crypto.sha512" [ "content" ] ~m:"Tesl.Crypto"
    ~doc:"SHA-512 of the content, hex-encoded (libsodium crypto_hash_sha512). An expert alias; prefer Crypto.fingerprint unless a foreign protocol demands SHA-512 specifically.";
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
  f "HttpClient.bearer" [ "secret" ] ~m:"Tesl.HttpClient" ~doc:"An `Authorization: Bearer <secret>` header pair, built from a Secret with no intermediate String. Drop it straight into any verb's header list; the plaintext is unwrapped inside the client, on its way to the socket.";
  f "HttpClient.secretHeader" [ "name"; "secret" ] ~m:"Tesl.HttpClient" ~doc:"A (name, secret) header pair for any header that carries a credential (e.g. \"X-Api-Key\"). Same one-way guarantee as HttpClient.bearer: the value is never a String in Tesl code and renders as [redacted] everywhere.";
]

(* ── Tesl.Http ─────────────────────────────────────────────────────────────── *)

let http : entry list = [
  e "HttpRequest" ~m:"Tesl.Http"
    ~kind:(KType "type HttpRequest   # fields: method, path, headers, cookies, queryParameters, clientAddress, body")
    ~doc:"The incoming request, as bound by an `auth` block or a handler that declares it.";
  f "Http.setSessionCookie" [ "token" ] ~m:"Tesl.Http"
    ~doc:"Sets the session cookie on the response: `__Host-session`, HttpOnly, Secure, SameSite=Lax, Path=/, Max-Age = the JWT TTL. Every attribute and the name are fixed — there are no options. It takes a JwtToken, so a session cookie always carries a signed value, and it attaches to 2xx responses only: a handler that sets a cookie and then `fail`s mints no session.";
  v "Http.clearSessionCookie" ~m:"Tesl.Http"
    ~doc:"The logout half — the same cookie with Max-Age=0, invoked as Http.clearSessionCookie(). It removes the browser's copy; it does not invalidate the token, which stays verifiable until `exp` (bounded at one hour by the fixed TTL).";
  f "Http.sessionToken" [ "request" ] ~m:"Tesl.Http"
    ~doc:"Reads the session cookie back as a Maybe JwtToken. Pure and ungated — request data is not an effect. Use it instead of `Dict.lookup \"__Host-session\" request.cookies`, where a typo is a permanent 401; feed the result to JWT.verify.";
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
  e "TelemetryConfig" ~m:"Tesl.Telemetry"
    ~kind:(KType "TelemetryConfig { service: String, endpoint: String, console: Bool, metrics: Bool?, metricsInterval: Int? }")
    ~doc:"Application telemetry configuration. Put `TelemetryConfig { service, endpoint, console }` in the `telemetry` field of the App record; `metrics` and `metricsInterval` are optional. The record is consumed at startup and has no runtime value.";
  e "Span" ~m:"Tesl.Telemetry"
    ~kind:(KType "Span")
    ~doc:"Opaque span handle returned by telemetry integrations.";
  e "initTelemetry" ~m:"Tesl.Telemetry"
    ~kind:(KSyntax "initTelemetry service \"my-service\" endpoint \"http://collector:4318\" console True : Unit")
    ~doc:"Legacy startup form for configuring OpenTelemetry. Prefer `TelemetryConfig` in the App record.";
  f "telemetry" [ "name" ] ~m:"Tesl.Telemetry"
    ~doc:"Emits a span; the special form `telemetry \"span.name\" { key = value }` attaches the fields as span attributes.";
  f "counter" [ "name"; "delta"; "attrs" ] ~m:"Tesl.Telemetry"
    ~doc:"Adds delta to a cumulative counter metric; attrs are [Tuple2 \"key\" value] pairs.";
  f "histogram" [ "name"; "value"; "attrs" ] ~m:"Tesl.Telemetry"
    ~doc:"Records a value in a histogram metric; attrs are [Tuple2 \"key\" value] pairs.";
  f "gauge" [ "name"; "value"; "attrs" ] ~m:"Tesl.Telemetry"
    ~doc:"Sets a gauge metric to the given value; attrs are [Tuple2 \"key\" value] pairs.";
]

(* ── Tesl.Sso (Phase 3 tables-only foundation) ─────────────────────────────── *)
let sso : entry list = [
  e "SsoConnection" ~m:"Tesl.Sso"
    ~kind:(KType "type SsoConnection   # opaque; built by Sso.defaults")
    ~doc:"An opaque, blessed provider connection (endpoints, scopes, client id/secret). Built by Sso.defaults; consumed by the `sso` server clause. Opaque on the Tesl surface — there is no constructor, so it cannot be forged field-by-field.";
  e "SsoSubjectKey" ~m:"Tesl.Sso"
    ~kind:(KType "type SsoSubjectKey   # opaque, storable identity key")
    ~doc:"The opaque, email-free identity key for an SSO user, derived injectively from (issuer, subject) like PasswordHash is opaque. Store `Sso.keyText key` in a column; never key a user table on an email address.";
  e "SsoProvider" ~m:"Tesl.Sso"
    ~kind:(KType "type SsoProvider = Github | Google")
    ~doc:"The blessed set of SSO providers, a closed ADT. Each constructor lowers to the runtime provider id, so a typo is a compile error and completion lists every provider (the Utc/Currency baked-ADT pattern). Pass one as the first argument to Sso.defaults; for any other OpenID Connect issuer use Sso.oidc.";
  v "Github" ~m:"Tesl.Sso" ~doc:"The GitHub SSO provider (plain OAuth2 + server-side userinfo). A value of type SsoProvider for Sso.defaults.";
  v "Google" ~m:"Tesl.Sso" ~doc:"The Google SSO provider (OIDC). A value of type SsoProvider for Sso.defaults.";
  f "Sso.defaults" [ "provider"; "clientId"; "clientSecret" ] ~m:"Tesl.Sso"
    ~doc:"Builds a blessed provider SsoConnection with minimal scopes and the right endpoints/field mapping. `provider` is an SsoProvider (Github/Google). The client secret is a Tesl.Crypto Secret, so it is redacted at every rendering sink.";
  f "Sso.oidc" [ "issuer"; "clientId"; "clientSecret" ] ~m:"Tesl.Sso"
    ~doc:"Builds a generic OpenID Connect SsoConnection from an ISSUER URL (self-hosted Keycloak/dex, Okta, Auth0, single-tenant Entra). Endpoints are discovered from the issuer's /.well-known/openid-configuration; the same signature+claims trust argument as the blessed OIDC providers applies, and the issuer passes the SSRF preflight.";
  f "Sso.allowedEmailDomains" [ "connection"; "domains" ] ~m:"Tesl.Sso"
    ~doc:"Restricts a connection to identities whose email domain is in the list. Enforced by the runtime at the callback BEFORE onIdentity, and satisfiable ONLY by a VerifiedEmail — an unverified or absent address is refused (restricting by an address the provider never verified is the Risk 2 takeover in disguise). Case- and FQDN-root-insensitive.";
  f "Sso.allowedHostedDomains" [ "connection"; "domains" ] ~m:"Tesl.Sso"
    ~doc:"Restricts a connection to a Google Workspace / hosted-domain (`hd`) claim in the list. An absent `hd` claim is a refusal, not a pass. Checked at the callback before onIdentity.";
  f "Sso.allowedTenants" [ "connection"; "tenants" ] ~m:"Tesl.Sso"
    ~doc:"Restricts an OIDC connection to the listed tenant ids (Entra `tid`). Checked at the callback before onIdentity.";
  f "Sso.keyText" [ "key" ] ~m:"Tesl.Sso"
    ~doc:"Renders an opaque SsoSubjectKey as the String to store in a database column. The inverse (constructing a key) is the runtime's job at the SSO callback, never the app's.";
  e "SsoIdentity" ~m:"Tesl.Sso"
    ~kind:(KType "type SsoIdentity   # opaque; handed to an `sso` clause's onIdentity")
    ~doc:"The verified third-party identity the SSO runtime hands to a server clause's `onIdentity` function at the callback. Opaque; read the stable session subject with Sso.subject.";
  f "Sso.subject" [ "identity" ] ~m:"Tesl.Sso"
    ~doc:"The stable subject string of an SsoIdentity (issuer-scoped), for use as the session subject an onIdentity function returns.";
  f "Sso.email" [ "identity" ] ~m:"Tesl.Sso"
    ~doc:"The identity's VERIFIED email as a Maybe String — Something only when the provider verified the address, Nothing otherwise. There is deliberately no way to read an UNVERIFIED email, so an app cannot trust one for identity decisions (the Risk 2 takeover). Domain restriction on the connection is the enforced form; this is for display/linking.";
  f "Sso.tenant" [ "identity" ] ~m:"Tesl.Sso"
    ~doc:"The identity's tenant as a Maybe String — the OIDC `tid` / Google Workspace `hd` when present, Nothing otherwise. Use it to scope a multi-tenant app; pair with Sso.allowedTenants to restrict at the connection.";
  f "Sso.claim" [ "identity"; "name" ] ~m:"Tesl.Sso"
    ~doc:"Reads a single string claim from the verified token by name, as a Maybe String (Nothing if absent or not a string). For arbitrary claims beyond subject/email/tenant.";
  f "Sso.logoutUrl" [ "connection"; "postLogoutRedirectUri" ] ~m:"Tesl.Sso"
    ~doc:"Builds the RP-initiated logout URL (OIDC RP-Initiated Logout 1.0) that ends the IdP's own browser session, not just the app's. Re-discovers the connection's `end_session_endpoint` on every call, so a rotated endpoint is always honored; requires `httpClient` since discovery is a live fetch. Raises if the provider does not advertise `end_session_endpoint` (plain OAuth2 providers such as GitHub/Discord never do). A `handler` typically returns this String and the frontend navigates to it after clearing its own session cookie.";
]

let migration : entry list = [
  e "Migration" ~m:"Tesl.Migration"
    ~kind:(KType "Migration { from: schemaRef, to: schemaRef, same: List Same, entities: { EntityName: Entity }, fixtures: [] }")
    ~doc:"A contextual declaration in FamilySchema.Migrate.V<n>. References and entity keys are compiler-checked against adjacent schema revisions. It is not a runtime type or value. The initial checker covers additive declarations; physical planning and execution are separate.";
  e "Entity" ~m:"Tesl.Migration" ~aliases:["Additive";"New";"Drop"]
    ~kind:(KType "Entity = Additive (List Rule) | New | Drop   # contextual")
    ~doc:"One entry per changed entity. Additive derives a single row adapter; New and Drop name an added or removed table. An absent entity must be compiler-verified unchanged. These markers cannot be used as runtime values.";
  e "Rule" ~m:"Tesl.Migration" ~aliases:["Default"]
    ~kind:(KType "Rule = Default field literal   # contextual")
    ~doc:"Default supplies the exact primitive literal for a new, non-optional, proof-free field. Optional new fields receive Nothing in the adapter; current application literals still name every field.";
  e "Same" ~m:"Tesl.Migration"
    ~kind:(KType "Same From.Declaration To.Declaration   # contextual")
    ~doc:"The compiler verifies semantic equality for every eligible type, fact and codec with the named spelling. A record and its same-named codec are both checked. This claim cannot assert equality or cast persisted proofs.";
]

let entries : entry list =
  ambient @ prelude @ email @ maybe_result @ time @ civil_time
  @ int32 @ db @ either @ string_ @ regex @ url @ net @ list_ @ list_prim @ int_ @ float_
  @ dict @ set_ @ tuple @ money @ random_uuid_id_env @ json_codecs
  @ api_test @ jwt @ crypto @ cache @ database @ http @ http_client @ agent @ queue
   @ telemetry @ sso @ migration
