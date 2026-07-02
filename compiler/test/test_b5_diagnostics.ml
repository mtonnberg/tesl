(** B5 — D8 idiom-transfer diagnostics + D6 dead reserved-keyword removal.

    D8: the three most common "coming from TS/Python/Java" transfer mistakes now
        get a targeted hint instead of a bare/cascading error —
        `return x` (Tesl has no `return`), `+` on `String` (use `++`, and it no
        longer cascades three "unify String with Int" errors), and single-line
        `if … then … else …` (shown the indented multi-line form).
    D6: `deadWorkers` and `inject` were reserved in the lexer but never matched by
        the grammar (pure dead reservations) — removed, so they are usable
        identifiers now; the reservation set no longer carries dead entries. *)

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
  let dir = Filename.temp_dir "tesl-b5" "" in
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

let fails_with pat label src =
  with_src src (fun p ->
    let code, out = run_cc ["--check"; p] in
    if code = 0 then failf "%s: expected rejection but COMPILED" label;
    (try ignore (Str.search_forward (Str.regexp_case_fold pat) out 0)
     with Not_found -> failf "%s: message !~ %S:\n%s" label pat out))

let count_matches pat out =
  let re = Str.regexp_case_fold pat in
  let rec go i n = match (try Some (Str.search_forward re out i) with Not_found -> None) with
    | Some j -> go (j + 1) (n + 1) | None -> n in
  go 0 0

let compiles label src =
  with_src src (fun p ->
    let code, out = run_cc ["--check"; p] in
    if code <> 0 then failf "%s: expected COMPILE but failed:\n%s" label out)

let d8_return = {|#lang tesl
module RetX exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int = return x
|}
let d8_plus_string = {|#lang tesl
module AddX exposing []
import Tesl.Prelude exposing [String]
fn g(a: String, b: String) -> String = a + b
|}
let d8_single_if = {|#lang tesl
module IfX exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fn h(n: Int) -> Int = if n > 0 then 1 else 2
|}
(* D6: the removed reservations are usable identifiers now. *)
let d6_ident = {|#lang tesl
module IdentX exposing []
import Tesl.Prelude exposing [Int]
fn inject(deadWorkers: Int) -> Int = deadWorkers
|}

let () =
  run "B5-Diagnostics" [
    "D8 idiom-transfer hints", [
      test_case "return x → 'Tesl has no return' hint" `Quick
        (fun () -> fails_with "no `return`\\|has no return" "d8-return" d8_return);
      test_case "+ on String → 'use ++' (single, not cascading)" `Quick
        (fun () ->
          fails_with "use `\\+\\+`\\|string concatenation" "d8-plus" d8_plus_string;
          (* the short-circuit means NOT three cascading unify errors *)
          with_src d8_plus_string (fun p ->
            let _, out = run_cc ["--check"; p] in
            let n = count_matches "unify String with Int" out in
            if n >= 3 then failf "expected no cascading unify errors, got %d" n));
      test_case "single-line if → indented-form hint" `Quick
        (fun () -> fails_with "indented\\|single-line" "d8-if" d8_single_if);
    ];
    "D6 dead reserved keywords removed", [
      test_case "inject / deadWorkers are usable identifiers" `Quick
        (fun () -> compiles "d6-ident" d6_ident);
    ];
  ]
