(** GitHub #29 — grouped aggregates + calendar bucket keys (static rules).

    `selectCountBy` / `selectSumBy … groupBy <key>` return one (key, aggregate)
    row per group as `List (Tuple2 K V)`; the key is `binder.field` or
    `Time.truncHour/Day/Week/Month/Year offsetMinutes binder.field` on a
    PosixMillis column.  These tests pin the fail-closed sweep that came with
    the feature:

    - `groupBy` on the scalar aggregates and on plain select/selectOne is a
      compile error (it used to be SILENTLY DROPPED at runtime);
    - the grouped forms require exactly ONE groupBy, a resolvable key, and
      reject order/limit/offset/innerJoin;
    - Time.trunc* keys demand a PosixMillis column;
    - the emitted Racket carries the sql-group-key lowering (the expression
      form used to emit a module that failed to LOAD).

    Harness modeled on compiler/test/test_server_tools.ml. *)

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

let file_name_of_src content =
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

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-groupby" "" in
  let path = Filename.concat dir (file_name_of_src content) in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled \
                            cleanly:\n%s" pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let has_err =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false in
    if code <> 0 || has_err then
      failf "expected clean compile, got (exit %d):\n%s" code out)

let emit_output src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [path] in
    if code <> 0 then failf "expected clean emit, got (exit %d):\n%s" code out;
    out)

let fixture tail = Printf.sprintf {|#lang tesl
module GbFix exposing []

import Tesl.Prelude exposing [Int, String, List]
import Tesl.Time exposing [PosixMillis, Time.truncDay, Time.truncMonth, TimeZone, Utc, FixedOffset, EuropeStockholm]
import Tesl.Tuple exposing [Tuple2]
import Tesl.DB exposing [dbRead]

entity Entry table "entries" primaryKey id {
  id: String
  orgId: String
  minutes: Int
  startedAt: PosixMillis
}

%s
|} tail

(* ── Positive controls ───────────────────────────────────────────────────── *)

let test_valid_grouped_forms () =
  should_pass (fixture {|
fn minutesPerDay(orgId: String, tz: TimeZone) -> List (Tuple2 PosixMillis Int)
  requires [dbRead] =
  selectSumBy e.minutes from Entry
    where e.orgId == orgId
    groupBy (Time.truncDay tz e.startedAt)

fn perMonth() -> List (Tuple2 PosixMillis Int)
  requires [dbRead] =
  selectCountBy e from Entry
    groupBy (Time.truncMonth EuropeStockholm e.startedAt)

fn perOrg() -> List (Tuple2 String Int)
  requires [dbRead] =
  selectCountBy e from Entry
    groupBy e.orgId
|})

let test_emitted_lowering () =
  let out = emit_output (fixture {|
fn minutesPerDay(tz: TimeZone) -> List (Tuple2 PosixMillis Int)
  requires [dbRead] =
  selectSumBy e.minutes from Entry
    groupBy (Time.truncDay tz e.startedAt)
|}) in
  let contains needle =
    try ignore (Str.search_forward (Str.regexp_string needle) out 0); true
    with Not_found -> false in
  if not (contains "select-sum-by (sql-group-key 'day") then
    failf "expected select-sum-by with a 'day sql-group-key in the emitted \
           Racket, got:\n%s" out

let test_wrong_key_type_is_type_error () =
  (* declared return says Tuple2 String Int, but a truncDay key is PosixMillis *)
  should_fail "cannot unify\\|type"
    (fixture {|
fn bad() -> List (Tuple2 String Int)
  requires [dbRead] =
  selectCountBy e from Entry
    groupBy (Time.truncDay Utc e.startedAt)
|})

(* ── Negative space ──────────────────────────────────────────────────────── *)

let test_group_by_on_scalar_aggregate () =
  should_fail "`groupBy` is not supported on `selectSum`"
    (fixture {|
fn bad(orgId: String) -> Int
  requires [dbRead] =
  selectSum e.minutes from Entry
    where e.orgId == orgId
    groupBy e.orgId
|})

let test_group_by_on_plain_select () =
  should_fail "`groupBy` is not supported on `select`"
    (fixture {|
fn bad() -> List Entry
  requires [dbRead] =
  select e from Entry
    groupBy e.orgId
|})

let test_grouped_form_requires_group_by () =
  should_fail "requires exactly one `groupBy`"
    (fixture {|
fn bad() -> List (Tuple2 String Int)
  requires [dbRead] =
  selectCountBy e from Entry
|})

let test_unknown_key_field () =
  should_fail "does not exist on entity"
    (fixture {|
fn bad() -> List (Tuple2 PosixMillis Int)
  requires [dbRead] =
  selectCountBy e from Entry
    groupBy (Time.truncDay Utc e.noSuchField)
|})

let test_trunc_on_non_posix_column () =
  should_fail "requires a PosixMillis column"
    (fixture {|
fn bad() -> List (Tuple2 PosixMillis Int)
  requires [dbRead] =
  selectCountBy e from Entry
    groupBy (Time.truncDay Utc e.orgId)
|})

let test_limit_on_grouped_form () =
  should_fail "`limit` is not supported on `selectCountBy`"
    (fixture {|
fn bad() -> List (Tuple2 String Int)
  requires [dbRead] =
  selectCountBy e from Entry
    groupBy e.orgId
    limit 5
|})

let test_int_offset_rejected () =
  (* the pre-ADT surface: a raw Int offset is a type error now *)
  should_fail "cannot unify\\|TimeZone"
    (fixture {|
fn bad() -> List (Tuple2 PosixMillis Int)
  requires [dbRead] =
  selectCountBy e from Entry
    groupBy (Time.truncDay 60 e.startedAt)
|})

let test_zone_typo_rejected () =
  should_fail "unknown constructor"
    (fixture {|
fn bad() -> List (Tuple2 PosixMillis Int)
  requires [dbRead] =
  selectCountBy e from Entry
    groupBy (Time.truncDay EuropeStokholm e.startedAt)
|})

let test_arbitrary_key_expression_rejected () =
  should_fail "unsupported `groupBy` key expression\\|unknown name"
    (fixture {|
fn bad() -> List (Tuple2 Int Int)
  requires [dbRead] =
  selectCountBy e from Entry
    groupBy (someFn e.startedAt)
|})

let () =
  run "group-by"
    [
      ( "positive",
        [
          test_case "grouped forms compile (trunc + plain keys)" `Quick
            test_valid_grouped_forms;
          test_case "lowering carries sql-group-key" `Quick test_emitted_lowering;
        ] );
      ( "negative",
        [
          test_case "wrong key type is a type error" `Quick
            test_wrong_key_type_is_type_error;
          test_case "groupBy on scalar aggregate rejected" `Quick
            test_group_by_on_scalar_aggregate;
          test_case "groupBy on plain select rejected" `Quick
            test_group_by_on_plain_select;
          test_case "grouped form requires groupBy" `Quick
            test_grouped_form_requires_group_by;
          test_case "unknown key field rejected" `Quick test_unknown_key_field;
          test_case "trunc on non-PosixMillis column rejected" `Quick
            test_trunc_on_non_posix_column;
          test_case "limit on grouped form rejected" `Quick
            test_limit_on_grouped_form;
          test_case "arbitrary key expression rejected" `Quick
            test_arbitrary_key_expression_rejected;
          test_case "raw Int offset rejected (TimeZone required)" `Quick
            test_int_offset_rejected;
          test_case "zone-name typo is an unknown constructor" `Quick
            test_zone_typo_rejected;
        ] );
    ]
