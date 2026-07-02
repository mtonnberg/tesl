(** A9 / HM-1 — Int is arbitrary-precision.

    Out-of-native-range integer literals are no longer a compile-time range error.
    The lexer emits a [BIGINT] token carrying the canonical (leading-zero-stripped)
    decimal magnitude; the parser folds unary minus into a signed [LBigInt] string;
    the checker types it as [Int]; the emitter writes the exact digit string into
    the Racket bignum.  This suite pins:

      - a huge positive literal in a function body compiles and round-trips verbatim
        into the emitted Racket (no wrap / no truncation);
      - a huge literal under unary minus compiles and emits `-<digits>`;
      - the former out-of-range boundary 2^62 (= 4611686018427387904) now compiles
        (both the bare positive and the -2^62 form);
      - leading-zero canonicalization: `000…N` and `N` emit the SAME digit string
        (no leading zeros leak into Racket), so their content identity collapses;
      - a huge literal can serve as a proof subject / argument (multi-param fact),
        satisfying a proof exactly like an in-range Int literal;
      - GUARD (soundness): arbitrary precision does NOT make a huge literal a valid
        PORT — the VPort config validator still rejects it (and by extension VInt
        for `numberOfWorkers` / concurrency), so this fix over-accepts nothing in
        the config layer.

    Emission / canonicalization assertions run in-process (parse + emit) so they
    read the exact Racket text; the behavioural pass/reject assertions drive the
    real `--check` pipeline (which runs full validation, incl. VPort). *)

open Alcotest
open Parser
open Emit_racket

(* ── In-process compile (parse + emit), no filesystem, no validation pass ──── *)

let emit_ok src name =
  match parse_module "<a9-test>" src with
  | Ok m -> compile_to_string ~root_path:"TESL_ROOT" m
  | Err e -> failf "%s: expected parse/emit success, got: %s" name e.msg

let count_substring haystack needle =
  let n = String.length needle and m = String.length haystack in
  if n = 0 || m < n then 0
  else begin
    let c = ref 0 and i = ref 0 in
    while !i <= m - n do
      if String.sub haystack !i n = needle then (incr c; i := !i + n) else incr i
    done;
    !c
  end

let assert_contains ~name haystack needle =
  if count_substring haystack needle = 0 then
    failf "%s: expected to find\n  %S\nin:\n%s" name needle haystack

let assert_not_contains ~name haystack needle =
  if count_substring haystack needle > 0 then
    failf "%s: expected NOT to find\n  %S\nin:\n%s" name needle haystack

(* ── Subprocess --check harness (full validation pipeline) ─────────────────── *)

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

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let cmd = String.concat " " quoted ^ " 2>&1" in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let write_file_safe path content =
  let oc = open_out path in output_string oc content; close_out oc

let with_temp_file content f =
  let path = Filename.temp_file "tesl-a9" ".tesl" in
  write_file_safe path content;
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () -> f path)

let check_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    check bool (Printf.sprintf "expected --check success, got:\n%s" out) true (code = 0))

let check_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    check bool "expected --check failure (nonzero exit)" true (code <> 0);
    let re = Str.regexp pattern in
    check bool (Printf.sprintf "expected failure matching %S, got:\n%s" pattern out)
      true (try ignore (Str.search_forward re out 0); true with Not_found -> false))

let prelude = "#lang tesl\nmodule Test exposing []\nimport Tesl.Prelude exposing [Int]\n"

(* ── Positive: huge literal in a body type-checks and round-trips verbatim ─── *)

let huge = "99999999999999999999999999"   (* 26 digits, far beyond native int *)

let test_huge_body_compiles () =
  check_pass (prelude ^ Printf.sprintf "fn big() -> Int = %s\n" huge)

let test_huge_body_roundtrips () =
  let racket = emit_ok (prelude ^ Printf.sprintf "fn big() -> Int = %s\n" huge)
                 "huge_body_roundtrip" in
  assert_contains ~name:"emitted Racket carries the exact digit string" racket huge

let test_huge_under_unary_minus () =
  let src = prelude ^ Printf.sprintf "fn negBig() -> Int = -%s\n" huge in
  check_pass src;
  let racket = emit_ok src "huge_negated" in
  assert_contains ~name:"emitted Racket carries -<digits>" racket ("-" ^ huge)

let test_former_boundary_2pow62_compiles () =
  (* 2^62 = 4611686018427387904 was formerly the out-of-range boundary. *)
  check_pass (prelude ^ "fn b() -> Int = 4611686018427387904\n");
  check_pass (prelude ^ "fn b() -> Int = -4611686018427387904\n")

(* ── Canonicalization: leading zeros are stripped before emission ──────────── *)

let test_leading_zero_canonicalization () =
  let padded = "000099999999999999999999999" in       (* 4 leading zeros *)
  let bare   =     "99999999999999999999999" in
  let racket = emit_ok
    (prelude ^ Printf.sprintf "fn a() -> Int = %s\nfn b() -> Int = %s\n" padded bare)
    "leading_zero_canon" in
  (* both emit the same canonical (zero-stripped) digit string, twice *)
  check int "both fns emit the canonical bare form (2 occurrences)" 2
    (count_substring racket bare);
  (* no leading-zero form leaks into the Racket output *)
  assert_not_contains ~name:"no leading-zero literal leaks into Racket" racket ("0" ^ bare)

(* ── Cross-seam: a huge literal as a proof subject / argument ──────────────── *)
(* HasMin lo n holds when n >= lo. `atLeast` establishes it for a value known to
   meet a huge floor; passing a proof-bearing value to `needsFloor` (which requires
   HasMin <huge> x) must succeed — the huge literal is the fact's content parameter,
   identified by its canonical string, exactly as an in-range Int literal would be. *)

let test_huge_proof_subject_and_arg () =
  let src = Printf.sprintf {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Fact]
import Tesl.Maybe exposing [Maybe(..)]

fact HasFloor (floor: Int) (n: Int)

establish atFloor(n: Int) -> Maybe (Fact (HasFloor %s n)) =
  Something (HasFloor %s n)

fn needsFloor(x: Int ::: HasFloor %s x) -> Int = x

fn use(x: Int) -> Int =
  case atFloor x of
    Something p -> needsFloor (x ::: p)
    Nothing -> 0
|} huge huge huge in
  check_pass src

(* ── GUARD (soundness): a huge literal is still NOT a valid port ───────────── *)
(* Arbitrary-precision Int must not silently become a valid TCP port. The VPort
   validator matches native LInt in 1..65535; a huge LBigInt hits the reject arm. *)

let test_huge_port_still_rejected () =
  let src = Printf.sprintf {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.DB exposing [dbRead]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Database exposing [Database, DatabaseBackend, Postgres, PostgresConfig, TcpConnection]

entity Item table "items" primaryKey id {
  id: String
  name: String
}

database ItemDb = Database {
  schema: "test"
  entities: [Item]
  backend: Postgres (PostgresConfig {
    dbName: "test"
    user: "test"
    password: "test"
    connection: TcpConnection { host: "localhost"  port: %s }
  })
}

fn getFn(itemId: String) -> Maybe Item requires [dbRead] =
  selectOne i from Item where i.id == itemId
|} huge in
  check_fail "not a valid port\\|port.*range\\|65535" src

(* A huge `numberOfWorkers` (VInt config) is likewise still rejected. *)
let test_huge_worker_count_still_rejected () =
  let src = Printf.sprintf {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Unit]
import Tesl.Queue exposing [Queue, QueueConfig]

queue Jobs = Queue {
  payload: String
  numberOfWorkers: %s
}
|} huge in
  check_fail "out of range\\|must be an Int\\|numberOfWorkers\\|Int" src

let () =
  run "test_a9_bigint" [
    "arbitrary-precision-Int", [
      test_case "huge literal in body compiles"            `Quick test_huge_body_compiles;
      test_case "huge literal round-trips verbatim to Racket" `Quick test_huge_body_roundtrips;
      test_case "huge literal under unary minus"           `Quick test_huge_under_unary_minus;
      test_case "former 2^62 boundary now compiles (+/-)"  `Quick test_former_boundary_2pow62_compiles;
      test_case "leading-zero canonicalization"            `Quick test_leading_zero_canonicalization;
      test_case "huge literal as proof subject/argument"   `Quick test_huge_proof_subject_and_arg;
    ];
    "guards-still-reject", [
      test_case "huge literal is NOT a valid port (VPort)" `Quick test_huge_port_still_rejected;
      test_case "huge numberOfWorkers rejected (VInt)"     `Quick test_huge_worker_count_still_rejected;
    ];
  ]
