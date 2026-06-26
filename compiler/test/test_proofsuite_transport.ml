(** ProofSuite Family G — proof transport (detach/attach/forget) + decomposition.

    Negative (must-NOT-compile) proofs that the *static* checker enforces the
    transport / decomposition discipline WITHOUT the runtime net, plus
    [should_pass] positive companions.

    Families covered:
      NOP   — decomposing a value that carries NO attached proof
              ("requires at least one attached proof").
      PROJ  — conjunction decomposition: use the wrong half (pa where Q
              required) / reattach the wrong projected proof.
      FORG  — forgetFact then use the result at a proof site.
      SELF  — self-referential `Fact` annotation ("used as both the binding
              name and a proof argument").
      POS   — positive companions (forget→re-validate; detach P&&Q then reattach
              to the SAME subject; decompose+reattach).

    NB: this family deliberately covers the DECOMPOSITION-BINDING variants of
    conjunction projection (the `let (a ::: pa && qa) = v` forms).  The
    andLeft/andRight no-op projection helpers are NEG-ATTACK's GAP-ANDPROJ and
    are NOT re-filed here. *)

open Alcotest

(* ── Compiler-path resolution ────────────────────────────────────────────── *)

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
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psG" "" in
  let name =
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
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let runtime_leak_re =
  Str.regexp_case_fold
    "raise-user-error\\|raise-argument-error\\|application: not a procedure\\|\
     racket/[A-Za-z_./-]*\\.rkt:[0-9]\\|^ *context\\.\\.\\.:\\|contract violation"

let assert_no_runtime_leak ctx out =
  try
    ignore (Str.search_forward runtime_leak_re out 0);
    failf "%s: rejection leaked to RUNTIME, expected STATIC compile error.\n%s" ctx out
  with Not_found -> ()

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled\n%s" pat out;
    assert_no_runtime_leak "should_fail" out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let[@warning "-32"] known_gap ~what src =
  with_temp_file src (fun path ->
    let code, _ = run_compiler ["--check"; path] in
    if code <> 0 then
      failf "KNOWN GAP CLOSED — `%s` is now rejected; promote to should_fail." what)

(* ── Shared TESL fragments ───────────────────────────────────────────────── *)

let hdr modname = Printf.sprintf
  "#lang tesl\nmodule %s exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, detachFact, attachFact, forgetFact]\n"
  modname

(* Single-subject Int / String checks. *)
let checks = {|
fact ValidScore (n: Int)
fact ValidTag (s: String)
check checkScore(n: Int) -> n: Int ::: ValidScore n =
  if n >= 0 && n <= 100 then
    ok n ::: ValidScore n
  else
    fail 400 "score 0-100"
check checkTag(s: String) -> s: String ::: ValidTag s =
  if s == "" then
    fail 400 "tag empty"
  else
    ok s ::: ValidTag s
fn requiresScore(score: Int ::: ValidScore score) -> String = "${score}"
fn requiresTag(tag: String ::: ValidTag tag) -> String = "${tag}"
|}

(* Two single-subject Int facts for conjunction tests. *)
let dual_int_checks = {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "p"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "s"
fn needsPositive(n: Int ::: IsPositive n) -> String = "pos"
fn needsSmall(n: Int ::: IsSmall n) -> String = "small"
fn makeBoth(n: Int) -> Int ? (IsPositive && IsSmall) requires [] =
  check (checkPos && checkSmall) n
|}

let satisfy_re =
  "requires at least one attached proof\\|does not.*statically.*satisfy\\|\
   different subject\\|binding name and a proof argument\\|carries no\\|V001"

(* ══════════════════════════════════════════════════════════════════════════
   NOP — decompose a value with NO attached proof.
   ══════════════════════════════════════════════════════════════════════════ *)

let nop_re = "requires at least one attached proof\\|carries none\\|carries no"

(* Matrix over the bare-value source and the binder shape. *)
let nop_case idx ~src_decl ~bound ~pattern =
  let m = Printf.sprintf "Nop%02d" idx in
  let test () =
    should_fail nop_re
      (hdr m ^ checks ^ Printf.sprintf {|
fn bad(%s) -> String =
%s  let %s = %s
  "x"
|} (fst src_decl) (snd src_decl) pattern bound)
  in
  (Printf.sprintf "NOP-%02d decompose %s" idx (fst src_decl |> fun _ -> pattern), test)

let nop_cases =
  [ (* plain Int parameter, full decompose *)
    (let m = "Nop01" in
     ("NOP-01 plain param, (raw ::: p)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn bad(x: Int) -> String =
  let (raw ::: p) = x
  "${raw}"
|})));
    (* plain Int parameter, proof-only decompose *)
    (let m = "Nop02" in
     ("NOP-02 plain param, (_ ::: p)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn bad(x: Int) -> String =
  let (_ ::: p) = x
  "x"
|})));
    (* plain let-bound literal, full decompose *)
    (let m = "Nop03" in
     ("NOP-03 plain literal, (raw ::: p)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn bad() -> String =
  let plain = 42
  let (raw ::: p) = plain
  "${raw}"
|})));
    (* arithmetic result (proof dropped) decomposed *)
    (let m = "Nop04" in
     ("NOP-04 arithmetic result, (raw ::: p)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn bad(x: Int ::: ValidScore x) -> String =
  let bumped = forgetFact x
  let bumped2 = bumped + 1
  let (raw ::: p) = bumped2
  "${raw}"
|})));
    (* String plain param decomposed *)
    (let m = "Nop05" in
     ("NOP-05 plain string param, (raw ::: p)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn bad(s: String) -> String =
  let (raw ::: p) = s
  raw
|})));
    (* conjunction decompose on a plain value (no proof at all) *)
    (let m = "Nop06" in
     ("NOP-06 plain param, (raw ::: p && q)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn bad(x: Int) -> String =
  let (raw ::: p && q) = x
  "${raw}"
|})));
    (* plain Bool-typed value decomposed *)
    (let m = "Nop08" in
     ("NOP-08 plain bool param, (raw ::: p)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn bad(b: Bool) -> String =
  let (raw ::: p) = b
  "x"
|})));
    (* function-call result with no proof decomposed *)
    (let m = "Nop09" in
     ("NOP-09 plain fn-call result, (raw ::: p)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn plainId(n: Int) -> Int = n
fn bad(x: Int) -> String =
  let r = plainId x
  let (raw ::: p) = r
  "${raw}"
|})));
    (* literal directly used in let then decomposed (string) *)
    (let m = "Nop10" in
     ("NOP-10 string literal, (raw ::: p)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn bad() -> String =
  let s = "hello"
  let (raw ::: p) = s
  raw
|})));
    (* conjunction decompose on a string with no proof *)
    (let m = "Nop11" in
     ("NOP-11 plain string, (raw ::: p && q)",
      fun () ->
        should_fail nop_re (hdr m ^ checks ^ {|
fn bad(s: String) -> String =
  let (raw ::: p && q) = s
  raw
|}))); ]
(* NB: `forgetFact v` does NOT make a subsequent decompose fail — forgetFact
   preserves the hidden subject, and the static checker still associates that
   subject with the proof it was validated under.  So a forgetFact-then-decompose
   is intentionally NOT a NOP case (the bare value below in POS-* uses it for
   arithmetic, which is the documented safe use). *)
let _ = nop_case  (* keep helper available; explicit cases used above *)

(* ══════════════════════════════════════════════════════════════════════════
   PROJ — conjunction decomposition projection mistakes.
   ══════════════════════════════════════════════════════════════════════════ *)

(* GAP-CONJPROJ — KNOWN STATIC-CHECKER GAP.
   After `let (bare ::: pPos && pSmall) = both` (a SINGLE value carrying a
   conjunction), reattaching the WRONG projected half to a consumer
   (`needsPositive (bare ::: pSmall)`) is accepted today.  Because both
   projected proofs share `bare`'s subject, the checker cannot tell `pPos` from
   `pSmall` at reattach time, so the wrong-conjunct reattachment slips through.
   This is the DECOMPOSITION-BINDING variant of conjunction projection (distinct
   from NEG-ATTACK's GAP-ANDPROJ andLeft/andRight helper no-op).  CLOSED: the
   projection is now subject-precise, so reattaching the wrong projected half is
   rejected ("does not statically satisfy").
   (The cross-VALUE swap — different subjects — was already rejected; see PROJ-03/04.) *)
let proj_wrong_half_gap idx ~wrong_proof ~consumer =
  let m = Printf.sprintf "Proj%02d" idx in
  let test () =
    should_fail satisfy_re
      (hdr m ^ dual_int_checks ^ Printf.sprintf {|
fn bad(raw: Int) -> String =
  let both = makeBoth raw
  let (bare ::: pPos && pSmall) = both
  %s (bare ::: %s)
|} consumer wrong_proof)
  in
  (Printf.sprintf "PROJ-%02d reattach %s at %s (KNOWN GAP)" idx wrong_proof consumer, test)

(* Three-way conjunction projection: decompose P && Q && R, reattach a wrong
   leaf at each consumer.  Same GAP-CONJPROJ root cause. *)
let proj_three_way_gap idx ~wrong_proof ~consumer =
  let m = Printf.sprintf "Proj3%02d" idx in
  let test () =
    should_fail satisfy_re
      (hdr m ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"
check checkB(n: Int) -> n: Int ::: B n =
  if n > 0 then
    ok n ::: B n
  else
    fail 400 "b"
check checkC(n: Int) -> n: Int ::: C n =
  if n > 0 then
    ok n ::: C n
  else
    fail 400 "c"
fn needsA(n: Int ::: A n) -> String = "a"
fn needsB(n: Int ::: B n) -> String = "b"
fn needsC(n: Int ::: C n) -> String = "c"
fn makeABC(n: Int) -> Int ? (A && B && C) requires [] =
  check (checkA && checkB && checkC) n
|} ^ Printf.sprintf {|
fn bad(raw: Int) -> String =
  let abc = makeABC raw
  let (bare ::: pa && pb && pc) = abc
  %s (bare ::: %s)
|} consumer wrong_proof)
  in
  (Printf.sprintf "PROJ3-%02d reattach %s at %s (KNOWN GAP)" idx wrong_proof consumer, test)

let proj_cases =
  [ proj_wrong_half_gap 1 ~wrong_proof:"pSmall" ~consumer:"needsPositive";
    proj_wrong_half_gap 2 ~wrong_proof:"pPos" ~consumer:"needsSmall";
    proj_three_way_gap 1 ~wrong_proof:"pb" ~consumer:"needsA";
    proj_three_way_gap 2 ~wrong_proof:"pc" ~consumer:"needsA";
    proj_three_way_gap 3 ~wrong_proof:"pa" ~consumer:"needsB";
    proj_three_way_gap 4 ~wrong_proof:"pc" ~consumer:"needsB";
    proj_three_way_gap 5 ~wrong_proof:"pa" ~consumer:"needsC";
    proj_three_way_gap 6 ~wrong_proof:"pb" ~consumer:"needsC"; ]

(* The exact lesson38-documented bug: decompose two SEPARATE proven values,
   re-combine, then reattach the cross-proof (tagProof) where ValidScore is
   required. *)
let proj_cross_value_swap () =
  should_fail satisfy_re
    (hdr "Proj03" ^ checks ^ {|
fn bad(score: Int ::: ValidScore score, tag: String ::: ValidTag tag) -> String =
  let (rawScore ::: scoreProof) = score
  let (rawTag ::: tagProof) = tag
  requiresScore (rawScore ::: tagProof)
|})

(* Conjunction re-combine then misuse the recombined wrong half (lesson38's
   `bUG_this_should_not_compile` block, exact shape). *)
let proj_recombine_swap () =
  should_fail satisfy_re
    (hdr "Proj04" ^ checks ^ {|
fn bad(score: Int ::: ValidScore score, tag: String ::: ValidTag tag) -> String =
  let (rawScore ::: scoreProof) = score
  let (rawTag ::: tagProof) = tag
  let (_ ::: scoreProof2 && tagProof2) = rawScore ::: scoreProof && tagProof
  requiresScore (rawScore ::: tagProof2)
|})

(* Cross-VALUE proof swap matrix: decompose two separately-proven values, then
   reattach value X's proof onto value Y's bare binding.  Different subjects →
   statically rejected.  Distinct from the same-value conjunction gap above. *)
let proj_cross_swap idx ~bare ~proof ~consumer =
  let m = Printf.sprintf "ProjX%02d" idx in
  let test () =
    should_fail satisfy_re
      (hdr m ^ checks ^ Printf.sprintf {|
fn bad(score: Int ::: ValidScore score, n: Int ::: ValidScore n) -> String =
  let (rawScore ::: scoreProof) = score
  let (rawN ::: nProof) = n
  %s (%s ::: %s)
|} consumer bare proof)
  in
  (Printf.sprintf "PROJX-%02d reattach %s to %s" idx proof bare, test)

let proj_cross_swap_cases =
  [ proj_cross_swap 1 ~bare:"rawScore" ~proof:"nProof" ~consumer:"requiresScore";
    proj_cross_swap 2 ~bare:"rawN" ~proof:"scoreProof" ~consumer:"requiresScore";
    proj_cross_swap 3 ~bare:"rawScore" ~proof:"nProof" ~consumer:"requiresScore";
    proj_cross_swap 4 ~bare:"rawN" ~proof:"scoreProof" ~consumer:"requiresScore"; ]

(* A bare value decomposed from a value whose proof was forgotten — the bare
   binding carries no detachable proof, so a (raw ::: p) decompose has nothing
   to detach.  (forgetFact preserves the subject, but an explicit re-decompose
   of a freshly-constructed plain value has no proof.) *)
let nop_plain_constructed idx ~expr =
  let m = Printf.sprintf "NopC%02d" idx in
  let test () =
    should_fail nop_re
      (hdr m ^ checks ^ Printf.sprintf {|
fn bad() -> String =
  let plain = %s
  let (raw ::: p) = plain
  "x"
|} expr)
  in
  (Printf.sprintf "NOP-C-%02d decompose plain `%s`" idx expr, test)

let nop_constructed_cases =
  [ nop_plain_constructed 1 ~expr:"1 + 2";
    nop_plain_constructed 2 ~expr:"100";
    nop_plain_constructed 3 ~expr:"0 - 1"; ]

let proj_extra_cases =
  [ ("PROJ-03 cross-value proof swap (lesson38 bug)", proj_cross_value_swap);
    ("PROJ-04 recombine then wrong-half reattach", proj_recombine_swap); ]
  @ proj_cross_swap_cases

(* ══════════════════════════════════════════════════════════════════════════
   FORG — forgetFact then use at a proof site.
   ══════════════════════════════════════════════════════════════════════════ *)

let forg_use_after idx ~consumer =
  let m = Printf.sprintf "Forg%02d" idx in
  let test () =
    should_fail "does not.*statically.*satisfy\\|carries no\\|V001"
      (hdr m ^ checks ^ Printf.sprintf {|
fn bad(raw: Int) -> String =
  let v = check checkScore raw
  let f = forgetFact v
  %s f
|} consumer)
  in
  (Printf.sprintf "FORG-%02d forgetFact then %s" idx consumer, test)

(* forgetFact then use directly at a proof site (matrix over how many times we
   alias the forgotten value before using it — all lose the proof). *)
let forg_alias_chain idx ~aliases =
  let m = Printf.sprintf "ForgA%02d" idx in
  let alias_lines =
    String.concat "" (List.init aliases (fun i ->
      Printf.sprintf "  let a%d = a%d\n" (i + 1) i))
  in
  let last = Printf.sprintf "a%d" aliases in
  let test () =
    should_fail "does not.*statically.*satisfy\\|carries no\\|V001"
      (hdr m ^ checks ^ Printf.sprintf {|
fn bad(raw: Int) -> String =
  let v = check checkScore raw
  let a0 = forgetFact v
%s  requiresScore %s
|} alias_lines last)
  in
  (Printf.sprintf "FORG-A-%02d forget then %d aliases then use" idx aliases, test)

let forg_cases =
  [ forg_use_after 1 ~consumer:"requiresScore";
    forg_alias_chain 1 ~aliases:1;
    forg_alias_chain 2 ~aliases:2;
    forg_alias_chain 3 ~aliases:3; ]

(* forgetFact, then forget AGAIN, then use (double-forget). *)
let forg_double () =
  should_fail "does not.*statically.*satisfy\\|carries no\\|V001"
    (hdr "Forg03" ^ checks ^ {|
fn bad(raw: Int) -> String =
  let v = check checkScore raw
  let f1 = forgetFact v
  let f2 = forgetFact f1
  requiresScore f2
|})

(* forgetFact a value, do arithmetic on it (new subject, no proof), then use. *)
let forg_then_arith () =
  should_fail "does not.*statically.*satisfy\\|carries no\\|V001"
    (hdr "Forg04" ^ checks ^ {|
fn bad(raw: Int) -> String =
  let v = check checkScore raw
  let bare = forgetFact v
  let bumped = bare + 1
  requiresScore bumped
|})

let forg_extra2_cases =
  [ ("FORG-03 double forgetFact then use", forg_double);
    ("FORG-04 forget then arithmetic then use", forg_then_arith); ]

(* forgetFact on a string value, then use at the string proof site. *)
let forg_string () =
  should_fail "does not.*statically.*satisfy\\|carries no\\|V001"
    (hdr "Forg02" ^ checks ^ {|
fn bad(raw: String) -> String =
  let v = check checkTag raw
  let f = forgetFact v
  requiresTag f
|})

let forg_extra_cases = [ ("FORG-02 forgetFact string then use", forg_string) ]

(* ══════════════════════════════════════════════════════════════════════════
   SELF — self-referential `Fact` annotation.
   ══════════════════════════════════════════════════════════════════════════ *)

let self_re = "binding name and a proof argument"

(* `let p: Fact (NonEmpty p) = detachFact v` — `p` names the Fact holder, not
   the value being proven. *)
let self_via_detach () =
  should_fail self_re
    (hdr "Self01" ^ checks ^ {|
fn bad(raw: Int) -> String =
  let v = check checkScore raw
  let p: Fact (ValidScore p) = detachFact v
  "x"
|})

(* Same, with a String fact. *)
let self_via_detach_str () =
  should_fail self_re
    (hdr "Self02" ^ checks ^ {|
fn bad(raw: String) -> String =
  let v = check checkTag raw
  let proof: Fact (ValidTag proof) = detachFact v
  "x"
|})

(* Self-referential Fact binding-name matrix over the binding identifier. *)
let self_named idx name =
  let m = Printf.sprintf "Self%02d" (idx + 2) in
  let test () =
    should_fail self_re
      (hdr m ^ checks ^ Printf.sprintf {|
fn bad(raw: Int) -> String =
  let v = check checkScore raw
  let %s: Fact (ValidScore %s) = detachFact v
  "x"
|} name name)
  in
  (Printf.sprintf "SELF-%02d self-ref Fact binding `%s`" (idx + 2) name, test)

let self_named_cases =
  List.mapi (fun i n -> self_named (i + 1) n)
    [ "pf"; "evidence"; "witness"; "fact1" ]

let self_cases =
  [ ("SELF-01 self-ref Fact via detachFact", self_via_detach);
    ("SELF-02 self-ref Fact (string) via detachFact", self_via_detach_str); ]
  @ self_named_cases

(* GAP-SELFPARAM — CLOSED.
   The self-referential check fired on `let`-bound `Fact (P binding)` (SELF-01/02
   above) but not on a function *parameter* annotated `p: Fact (P p)`.  The
   parameter form is now also rejected (P001, same root cause). *)
let self_param_gap () =
  should_fail self_re
    (hdr "SelfGap01" ^ checks ^ {|
fn bad(p: Fact (ValidScore p)) -> String = "x"
|})

let self_gap_cases =
  [ ("SELF-GAP-01 self-ref Fact on parameter (KNOWN GAP)", self_param_gap) ]

(* ══════════════════════════════════════════════════════════════════════════
   POS — positive companions (MUST compile).
   ══════════════════════════════════════════════════════════════════════════ *)

(* Decompose a proven value and reattach to the SAME subject. *)
let pos_decompose_reattach () =
  should_pass (hdr "PosG01" ^ checks ^ {|
fn good(raw: Int) -> String =
  let v = check checkScore raw
  let (bare ::: p) = v
  requiresScore (bare ::: p)
|})

(* forgetFact then re-validate, then use. *)
let pos_forget_revalidate () =
  should_pass (hdr "PosG02" ^ checks ^ {|
fn good(raw: Int) -> String =
  let v = check checkScore raw
  let bare = forgetFact v
  let revalidated = check checkScore bare
  requiresScore revalidated
|})

(* Detach P && Q then reattach to the SAME subject; use both halves correctly. *)
let pos_conj_decompose_correct () =
  should_pass (hdr "PosG03" ^ dual_int_checks ^ {|
fn good(raw: Int) -> String =
  let both = makeBoth raw
  let (bare ::: pPos && pSmall) = both
  let r1 = needsPositive (bare ::: pPos)
  let r2 = needsSmall (bare ::: pSmall)
  "${r1}/${r2}"
|})

(* detachFact a proof into a Fact value, then reattach with attachFact. *)
let pos_detach_attach () =
  should_pass (hdr "PosG04" ^ checks ^ {|
fn good(raw: Int) -> String =
  let v = check checkScore raw
  let p = detachFact v
  let bare = forgetFact v
  requiresScore (bare ::: p)
|})

(* Decompose with `_` discarding the proof; use only the bare value. *)
let pos_decompose_discard_proof () =
  should_pass (hdr "PosG05" ^ checks ^ {|
fn good(score: Int ::: ValidScore score) -> Int =
  let (raw ::: _) = score
  raw
|})

(* Decompose with `_` discarding the value; keep the proof. *)
let pos_decompose_discard_value () =
  should_pass (hdr "PosG06" ^ checks ^ {|
fn good(score: Int ::: ValidScore score) -> String =
  let (_ ::: _p) = score
  "proof extracted"
|})

(* Two distinct proven values decomposed; each half reattached to its OWN
   subject and used correctly. *)
let pos_two_values_correct () =
  should_pass (hdr "PosG07" ^ checks ^ {|
fn good(score: Int ::: ValidScore score, tag: String ::: ValidTag tag) -> String =
  let (rawScore ::: scoreProof) = score
  let (rawTag ::: tagProof) = tag
  let s = requiresScore (rawScore ::: scoreProof)
  let t = requiresTag (rawTag ::: tagProof)
  "${t}=${s}"
|})

(* forgetFact used purely for its raw value in arithmetic (the documented safe
   pattern) — returns a plain Int, no proof site. *)
let pos_forget_arithmetic () =
  should_pass (hdr "PosG08" ^ checks ^ {|
fn birthday(age: Int ::: ValidScore age) -> Int =
  let bare = forgetFact age
  bare + 1
|})

(* Conjunction decompose then recombine to the SAME subject, both halves used. *)
let pos_conj_recombine_correct () =
  should_pass (hdr "PosG09" ^ dual_int_checks ^ {|
fn good(raw: Int) -> String =
  let both = makeBoth raw
  let (bare ::: pPos && pSmall) = both
  needsPositive (bare ::: pPos && pSmall)
|})

(* detachFact result has type Fact (P subject); reattach to forgotten value. *)
let pos_detach_into_fact_value () =
  should_pass (hdr "PosG10" ^ checks ^ {|
fn extractAndReuse(score: Int ::: ValidScore score) -> String =
  let p = detachFact score
  let bare = forgetFact score
  requiresScore (bare ::: p)
|})

(* Decompose, use bare value in a string, then reattach proof to use at a site. *)
let pos_decompose_use_both () =
  should_pass (hdr "PosG11" ^ checks ^ {|
fn good(score: Int ::: ValidScore score) -> String =
  let (raw ::: p) = score
  let label = "raw=${raw}"
  let used = requiresScore (raw ::: p)
  "${label} ${used}"
|})

(* forgetFact on a proven value, then the value is used purely as data (no proof
   site) — the documented safe pattern. *)
let pos_forget_data_only () =
  should_pass (hdr "PosG12" ^ checks ^ {|
fn describe(tag: String ::: ValidTag tag) -> String =
  let bare = forgetFact tag
  "tag is ${bare}"
|})

(* Two-level conjunction: decompose then re-decompose the recombined proof. *)
let pos_nested_conj () =
  should_pass (hdr "PosG13" ^ dual_int_checks ^ {|
fn good(raw: Int) -> String =
  let both = makeBoth raw
  let (bare ::: pPos && pSmall) = both
  let recombined = bare ::: pPos && pSmall
  let (bare2 ::: pPos2 && pSmall2) = recombined
  let r1 = needsPositive (bare2 ::: pPos2)
  let r2 = needsSmall (bare2 ::: pSmall2)
  "${r1}/${r2}"
|})

(* ── Registration ────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (name, fn) -> test_case name `Quick fn) lst

let () =
  run "ProofSuite-G" [
    "NOP-no-attached-proof", to_cases (nop_cases @ nop_constructed_cases);
    "PROJ-conjunction-projection", to_cases (proj_cases @ proj_extra_cases);
    "FORG-forget-then-use", to_cases (forg_cases @ forg_extra_cases @ forg_extra2_cases);
    "SELF-self-referential-fact", to_cases (self_cases @ self_gap_cases);
    "POS-companions", [
      test_case "POS decompose then reattach same subject" `Quick pos_decompose_reattach;
      test_case "POS forget then re-validate" `Quick pos_forget_revalidate;
      test_case "POS conj decompose, both halves correct" `Quick pos_conj_decompose_correct;
      test_case "POS detach then attach" `Quick pos_detach_attach;
      test_case "POS decompose discard proof" `Quick pos_decompose_discard_proof;
      test_case "POS decompose discard value" `Quick pos_decompose_discard_value;
      test_case "POS two values, each half correct" `Quick pos_two_values_correct;
      test_case "POS forget for arithmetic (plain Int)" `Quick pos_forget_arithmetic;
      test_case "POS conj recombine same subject" `Quick pos_conj_recombine_correct;
      test_case "POS detach into Fact value then reattach" `Quick pos_detach_into_fact_value;
      test_case "POS decompose use both halves" `Quick pos_decompose_use_both;
      test_case "POS forget then data-only use" `Quick pos_forget_data_only;
      test_case "POS nested conjunction decompose" `Quick pos_nested_conj;
    ];
  ]
