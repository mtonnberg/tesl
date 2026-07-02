(** A5 — decoder & comparison soundness (external re-review §6.3 + §6.4).

    §6.4 — a function value from applying a HIGHER-ORDER PARAMETER
      (`f: Int -> Int -> Int`; `f 1`) type-checked under `==`/`<` and emitted a
      broken `(equal? proc proc)` / `(< proc proc)`.  The decidability check
      consulted a parallel inferencer that returned None for a param head (it only
      resolved top-level fns).  Now `infer_expr_type` unwinds a function-typed
      binding's arrow, so an under-applied HOF-param value resolves to a `TFun`
      and is rejected by is_equatable / is_orderable.

    §6.3 — `let x = decodeAs "T" j` whose result type was pinned only by a LATER
      use evaded the type/codec cross-check (which ran non-strict before that
      unification).  The result type is now DRIVEN by the literal type-name
      (unified with the named concrete type), so a wrong-type use is an ordinary
      unification error at the use site. *)

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

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128+n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let with_src src f =
  let dir = Filename.temp_dir "tesl-a5" "" in
  let re = Str.regexp "module[ \t]+\\([A-Z][A-Za-z0-9_]*\\)" in
  ignore (Str.search_forward re src 0);
  let m = Str.matched_group 1 src in
  let buf = Buffer.create 16 in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
    else Buffer.add_char buf c) m;
  let path = Filename.concat dir (Buffer.contents buf ^ ".tesl") in
  let oc = open_out path in output_string oc src; close_out oc;
  Fun.protect ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_fail ?(pat="") label src =
  with_src src (fun p ->
    let code, out = run_cc ["--check"; p] in
    if code = 0 then failf "%s: expected rejection but COMPILED:\n%s" label src;
    if pat <> "" then
      (try ignore (Str.search_forward (Str.regexp_case_fold pat) out 0)
       with Not_found -> failf "%s: rejected but message !~ %S:\n%s" label pat out))

let should_pass label src =
  with_src src (fun p ->
    let code, out = run_cc ["--check"; p] in
    if code <> 0 then failf "%s: expected COMPILE but failed:\n%s" label out)

(* ── §6.4 HOF-parameter function-value comparison ─────────────────────────── *)
let cmp_hdr = {|#lang tesl
module M exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
|}

let neg_hof_eq_let = cmp_hdr ^ {|
fn useMaker(maker: Int -> Int -> Int) -> Bool =
  let f = maker 1
  let g = maker 2
  f == g
|}
let neg_hof_eq_direct = cmp_hdr ^ {|
fn useMaker(maker: Int -> Int -> Int) -> Bool = (maker 1) == (maker 2)
|}
let neg_hof_lt_let = cmp_hdr ^ {|
fn useMaker(maker: Int -> Int -> Int) -> Bool =
  let f = maker 1
  let g = maker 2
  f < g
|}
let neg_hof_neq = cmp_hdr ^ {|
fn useMaker(maker: Int -> Int -> Int) -> Bool = (maker 1) != (maker 2)
|}
(* positive: comparing the fully-applied results (Ints) is fine *)
let pos_hof_applied = cmp_hdr ^ {|
fn useMaker(maker: Int -> Int -> Int) -> Bool = (maker 1 2) == (maker 3 4)
|}
let pos_int_eq = cmp_hdr ^ {|
fn cmp(a: Int, b: Int) -> Bool = a == b
|}

let notdef_pat = "not defined for type\\|no decidable equality\\|has no total order\\|not comparable"

(* ── §6.3 decodeAs type-name drives the result ────────────────────────────── *)
let dec_hdr = {|#lang tesl
module D exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Json exposing [intCodec, stringCodec]
import Tesl.Agent exposing [decodeAs]
record Priority {
  level: Int
}
codec Priority {
  toJson_forbidden
  fromJson [
    {
      level <- "level" with_codec intCodec
    }
  ]
}
|}

(* pinned to a WRONG type by a later use *)
let neg_dec_wrongtype = dec_hdr ^ {|
fn evade(j: String) -> Bool =
  let x = decodeAs "Priority" j
  x == "not-a-priority"
|}
(* the type-name string must match the target type *)
let pos_dec_correct = dec_hdr ^ {|
fn ok(j: String) -> Int =
  let x = decodeAs "Priority" j
  x.level
|}
(* annotated form still compiles *)
let pos_dec_annotated = dec_hdr ^ {|
fn ok(j: String) -> Priority = decodeAs "Priority" j
|}

let dec_pat = "cannot unify\\|type-name string must match\\|decodes as type"

let () =
  run "A5-Decoder-Comparison" [
    "§6.4 HOF-param comparison (negatives)", [
      test_case "== on let-bound HOF-param values" `Quick
        (fun () -> should_fail ~pat:notdef_pat "hof-eq-let" neg_hof_eq_let);
      test_case "== on directly-applied HOF-param values" `Quick
        (fun () -> should_fail ~pat:notdef_pat "hof-eq-direct" neg_hof_eq_direct);
      test_case "< on let-bound HOF-param values" `Quick
        (fun () -> should_fail ~pat:notdef_pat "hof-lt-let" neg_hof_lt_let);
      test_case "!= on HOF-param values" `Quick
        (fun () -> should_fail ~pat:notdef_pat "hof-neq" neg_hof_neq);
    ];
    "§6.4 comparison (positives)", [
      test_case "fully-applied results (Int) compare fine" `Quick
        (fun () -> should_pass "hof-applied" pos_hof_applied);
      test_case "Int == Int compiles" `Quick
        (fun () -> should_pass "int-eq" pos_int_eq);
    ];
    "§6.3 decodeAs type-name drives result", [
      test_case "decodeAs result used at wrong type is rejected" `Quick
        (fun () -> should_fail ~pat:dec_pat "dec-wrongtype" neg_dec_wrongtype);
    ];
    "§6.3 decodeAs (positives)", [
      test_case "decodeAs result used at its named type compiles" `Quick
        (fun () -> should_pass "dec-correct" pos_dec_correct);
      test_case "annotated decodeAs compiles" `Quick
        (fun () -> should_pass "dec-annotated" pos_dec_annotated);
    ];
  ]
