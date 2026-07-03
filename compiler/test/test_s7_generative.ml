(** S7 / C5 — generative negative corpus with ATTRIBUTED KILLS.

    The class property the stability program wants:

      "No soundness-breaking MUTATION of an ACCEPTED proof-bearing program is
       itself accepted — and each mutant is rejected BY THE GATE THAT OWNS THAT
       SOUNDNESS LAYER, not by an incidental parse/type error."

    Unlike the earlier down-payment (a handful of seeds mutated by brittle STRING
    edits with coarse regexes), this is systematic and AST-driven:

      1. Each seed source is PARSED to a [module_form] (a valid baseline — every
         seed must compile clean).
      2. For each seed × each applicable soundness-breaking transform, the AST is
         REWRITTEN in-process ({!Mutate.apply_soundness_transform_to_module} — a
         total structural rewrite of a [func_decl], never a string edit).
      3. The rewritten module is handed straight to {!Compile.check_module}.
      4. We assert the checker REJECTS the mutant (>= 1 error diagnostic) AND that
         at least one error MESSAGE matches the transform's SPECIFIC soundness
         ANCHOR (a stable substring of the exact diagnostic the owning gate
         emits).  A mutant that fails only for an unrelated reason is NOT a kill.

    Because the whole pipeline runs in-process on the AST, a transform that has no
    site in a seed (no return proof to drop, no capability to weaken, …) is
    reported as a corpus gap (the test FAILS loudly) rather than passing
    vacuously — the corpus stays honest as seeds evolve.

    Attributed kills WITHOUT an error-code coupling: the checker attributes
    soundness through the diagnostic MESSAGE, so each transform anchors on a
    stable message substring (rather than an error code), keeping the harness
    robust to error-code churn — exactly the constraint S7 sets.

    Set TESL_S7_DEBUG=1 to dump every mutant's diagnostics to /tmp/s7dbg.log
    (useful when a seed or an anchor drifts). *)

open Alcotest

let debug = Sys.getenv_opt "TESL_S7_DEBUG" <> None

(* ── In-process parse + check ────────────────────────────────────────────── *)

(* A `tesl-` filename stem makes [check_file_module_name_match] skip the
   module-name/file-name check, so `module T` is accepted for every fixture. *)
let seed_file = "tesl-s7.tesl"

let parse src : Ast.module_form =
  match Parser.parse_module seed_file src with
  | Ok m -> m
  | Err e ->
    failwith (Printf.sprintf "seed FAILED to parse: %s" e.Parser.msg)

let error_diags (ds : Compile.diagnostic list) =
  List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") ds

let messages (ds : Compile.diagnostic list) =
  String.concat "\n"
    (List.map (fun (d : Compile.diagnostic) ->
       Printf.sprintf "  [%s/%s] %s" d.source d.code d.message) ds)

(* Case-insensitive regex substring match over the joined diagnostic messages. *)
let matches pattern ds =
  let hay = messages ds in
  let re = Str.regexp_case_fold pattern in
  try ignore (Str.search_forward re hay 0); true with Not_found -> false

let dump seed_name fn transform ds =
  if debug then begin
    let oc = open_out_gen [Open_append; Open_creat] 0o644 "/tmp/s7dbg.log" in
    Printf.fprintf oc "\n[%s / %s / %s]\n%s\n"
      seed_name fn (Mutate.soundness_transform_name transform) (messages ds);
    close_out oc
  end

(* ── Assertions ──────────────────────────────────────────────────────────── *)

(** The seed itself must be ACCEPTED (no error diagnostics). *)
let seed_accepted seed_name src () =
  let m = parse src in
  let ds = error_diags (Compile.check_module src m) in
  if ds <> [] then
    Printf.eprintf "seed %S unexpectedly REJECTED:\n%s\n" seed_name (messages ds);
  check int (Printf.sprintf "seed %s accepted (baseline)" seed_name) 0
    (List.length ds)

(** A soundness mutant must (a) exist for this seed, (b) be REJECTED, and (c) be
    rejected FOR its transform's specific anchor. *)
let mutant_killed ~seed_name ~fn ~transform ~anchor src () =
  let m = parse src in
  match Mutate.apply_soundness_transform_to_module m ~fn_name:fn transform with
  | None ->
    (* No site — the seed does not exercise this layer.  A silently-skipped
       transform is a corpus gap, so fail loudly rather than pass vacuously. *)
    failf "transform %s has no site on fn %S in seed %S"
      (Mutate.soundness_transform_name transform) fn seed_name
  | Some m' ->
    let ds = Compile.check_module src m' in
    let errs = error_diags ds in
    dump seed_name fn transform ds;
    (* (b) rejected at all *)
    check bool
      (Printf.sprintf "%s: %s rejected" seed_name
         (Mutate.soundness_transform_name transform))
      true (errs <> []);
    (* (c) rejected for THIS layer's anchor (attributed kill) *)
    let attributed = matches anchor errs in
    if not attributed then
      Printf.eprintf
        "mutant %s/%s expected anchor %S but got:\n%s\n"
        seed_name (Mutate.soundness_transform_name transform) anchor (messages errs);
    check bool
      (Printf.sprintf "%s: %s attributed to anchor" seed_name
         (Mutate.soundness_transform_name transform))
      true attributed

(* ── Diagnostic anchors (one per soundness layer) ────────────────────────────
   Each is a stable substring of the EXACT message the owning gate emits.  A
   mutant only counts as a kill when the checker rejects it AND one error message
   matches this anchor, so an unrelated parse/type error cannot masquerade as a
   kill.  Anchors are message substrings (NOT error codes), per S7's constraint. *)

(* drop-a-premise / forge a `:::` proof carrier (Validation_advanced §7.12
   forgery gate) — a fn/handler/worker declaring a return proof its inputs never
   carried.  For an auth/check the analogous rejection is "does not match
   declared return spec" (the boundary produced the wrong proof). *)
let forge_anchor =
  "cannot declare a proof.*return\\|may introduce new proofs\
   \\|does not match declared return spec"

(* retarget a fact SUBJECT to a name not in scope (Proof_checker subject gate). *)
let subject_anchor =
  "is not a parameter name\\|not a valid GDP subject\\|return proof subject"

(* capability weaken / auth-via weaken (Validation_capabilities needs⊆declares). *)
let cap_anchor =
  "does not declare\\|privileged operations\\|required capabilit"

(* ── Shared seed headers ─────────────────────────────────────────────────── *)

let task_hdr = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [String, Int, Bool(..), List]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Maybe exposing [Maybe(..)]
entity Task table "tasks" primaryKey id {
  id: String
  title: String
}
|}

let prim_hdr = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Bool(..), Int, List]
import Tesl.List exposing [List.filterCheck]
fact IsPositive (n: Int)
|}

let auth_hdr = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
entity Account table "accounts" primaryKey id {
  id: String
  token: String
}
fact Authenticated (u: String)
|}

(* ── Seeds (proof-bearing, spanning every soundness layer) ────────────────── *)

(* SEED A — FromDb provenance produced by a real select; capability declared. *)
let seed_a = task_hdr ^ {|
fn getT(id: String) -> t: Task ::: FromDb (Id == id) t requires [dbRead] =
  let r = selectOne t from Task where t.id == id
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
|}

(* SEED B — a real DB write with the correct capability declared. *)
let seed_b = task_hdr ^ {|
fn del() -> String requires [dbWrite] =
  delete o from Task where o.id == "x"
  "ok"
|}

(* SEED C — a legitimate proof passthrough (the proof arrives on the input). *)
let seed_c = task_hdr ^ {|
fn passthru(t: Task ::: FromDb (Id == id) t) -> t: Task ::: FromDb (Id == id) t = t
|}

(* SEED D — a plain constructor returned by a plain fn (nothing to launder). *)
let seed_d = task_hdr ^ {|
fn mk(id: String) -> Task = Task { id: id, title: "x" }
|}

(* SEED E — a plain fn over a plain param (a clean forge-return target). *)
let seed_e = task_hdr ^ {|
fn ident(t: Task) -> Task = t
|}

(* SEED F — a real DB read returning a list. *)
let seed_f = task_hdr ^ {|
fn allT() -> List Task requires [dbRead] =
  select t from Task
|}

(* SEED G — a genuine `check` boundary that mints IsPositive. *)
let seed_g = prim_hdr ^ {|
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|}

(* SEED H — a genuine `auth` boundary reading the DB, capability declared. *)
let seed_h = auth_hdr ^ {|
auth tokenAuth(tok: String) -> user: String ::: Authenticated user requires [dbRead] =
  let r = selectOne a from Account where a.token == tok
  case r of
    Nothing -> fail 401 "bad token"
    Something a ->
      let uid = a.id
      ok uid ::: Authenticated uid
|}

(* SEED I — a proof-passthrough over a NON-DB predicate, so no stdlib-auto path
   masks a retarget/drop (unlike the FromDb passthrough). *)
let seed_i = prim_hdr ^ {|
fn keepPos(n: Int ::: IsPositive n) -> n: Int ::: IsPositive n = n
|}

(* ── Corpus: (seed_name, fn, src, [transform × anchor]) ──────────────────────
   Each row lists exactly the soundness layers its seed exercises. *)

type row = {
  name       : string;
  fn         : string;
  src        : string;
  transforms : (Mutate.soundness_transform * string) list;
}

let corpus : row list = [
  (* fn, FromDb via a real select — capability + provenance layers. *)
  { name = "A-fromdb-select"; fn = "getT"; src = seed_a; transforms = [
      Mutate.SWeakenCaps, cap_anchor;
    ] };

  (* fn, DB write — capability layer.  (A DB-write body makes FromDb
     stdlib-auto, so forging FromDb onto its return is NOT a forgery here; the
     forge layer is covered by the DB-siteless seeds D/E below.) *)
  { name = "B-declared-write"; fn = "del"; src = seed_b; transforms = [
      Mutate.SWeakenCaps, cap_anchor;
    ] };

  (* fn, proof passthrough — every proof-carrier layer. *)
  { name = "C-proof-passthrough"; fn = "passthru"; src = seed_c; transforms = [
      Mutate.SDropParamProof,        forge_anchor;
      Mutate.SRetargetReturnSubject, subject_anchor;
      Mutate.SRetargetParamSubject,  subject_anchor;
    ] };

  (* fn, plain constructor — forge a return proof onto a plain return. *)
  { name = "D-plain-constructor"; fn = "mk"; src = seed_d; transforms = [
      Mutate.SForgeProof, forge_anchor;
    ] };

  (* fn, plain identity — forge a return proof. *)
  { name = "E-plain-ident"; fn = "ident"; src = seed_e; transforms = [
      Mutate.SForgeProof, forge_anchor;
    ] };

  (* fn, list read — capability layer. *)
  { name = "F-list-read"; fn = "allT"; src = seed_f; transforms = [
      Mutate.SWeakenCaps, cap_anchor;
    ] };

  (* check boundary — retarget its minted proof's subject. *)
  { name = "G-check-boundary"; fn = "checkPos"; src = seed_g; transforms = [
      Mutate.SRetargetReturnSubject, subject_anchor;
    ] };

  (* auth boundary — capability + auth-via weaken + subject retarget. *)
  { name = "H-auth-boundary"; fn = "tokenAuth"; src = seed_h; transforms = [
      Mutate.SWeakenCaps,            cap_anchor;
      Mutate.SWeakenAuthVia,         cap_anchor;
      Mutate.SRetargetReturnSubject, subject_anchor;
    ] };

  (* fn, non-DB proof passthrough — carrier layers with no stdlib-auto mask. *)
  { name = "I-pos-passthrough"; fn = "keepPos"; src = seed_i; transforms = [
      Mutate.SDropParamProof,        forge_anchor;
      Mutate.SRetargetReturnSubject, subject_anchor;
      Mutate.SRetargetParamSubject,  subject_anchor;
    ] };
]

(* ── Real-corpus sweep ───────────────────────────────────────────────────────
   Beyond the curated seeds, additionally sweep every proof-bearing `.tesl` file
   under example/ + tests/ that checks CLEAN in-process, applying each soundness
   transform to each of its functions.  This generalises the property from a
   handful of seeds toward the whole proof-bearing corpus (S7's actual goal).

   Determinism / robustness: a corpus file that does not check clean in-process
   (unresolved local import, infra, or a construct the in-process path cannot
   resolve) is SKIPPED, not failed — the sweep only reasons about mutants of a
   genuinely-accepted baseline.  For each accepted baseline, a mutant is counted
   as an ATTRIBUTED KILL only when it is rejected AND at least one error message
   matches the applied transform's anchor.  Mutants that a transform produces but
   that trip only an unrelated diagnostic are NOT asserted (they would not be an
   attributed kill), so the sweep never manufactures spurious failures; it only
   adds high-confidence attributed kills to the corpus. *)

let repo_root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some r -> Some r
  | None ->
    (* Fall back to walking up from the test binary to a dir containing example/. *)
    let rec up dir n =
      if n > 8 then None
      else if Sys.file_exists (Filename.concat dir "example") then Some dir
      else up (Filename.dirname dir) (n + 1)
    in
    up (Sys.getcwd ()) 0

let rec tesl_files dir : string list =
  match Sys.readdir dir with
  | exception _ -> []
  | entries ->
    Array.to_list entries
    |> List.concat_map (fun e ->
         let p = Filename.concat dir e in
         if (try Sys.is_directory p with _ -> false) then tesl_files p
         else if Filename.check_suffix p ".tesl" then [p]
         else [])

(* The transforms to sweep, with each transform's owning-gate anchor. *)
let sweep_transforms = [
  Mutate.SForgeProof,            forge_anchor;
  Mutate.SDropParamProof,        forge_anchor;
  Mutate.SRetargetReturnSubject, subject_anchor;
  Mutate.SRetargetParamSubject,  subject_anchor;
  Mutate.SWeakenCaps,            cap_anchor;
  Mutate.SWeakenAuthVia,         cap_anchor;
]

(* An attributed kill: the mutant is rejected AND one error matches [anchor]. *)
let is_attributed_kill src (m : Ast.module_form) anchor =
  let errs = error_diags (Compile.check_module src m) in
  errs <> [] && matches anchor errs

(* ── Option E: surface ACCEPTED soundness-breaking mutants as candidate holes ──
   The sweep used to `else None`-drop any mutant it didn't confirm as a kill —
   so a mutant the checker ACCEPTS (a live hole) was invisible and the gate could
   only guard already-closed holes.  We now surface accepts.

   BUT the transforms fire on syntactic presence, not load-bearingness: dropping
   an OVER-declared capability (SWeakenCaps) or a param proof the return never
   used (SDropParamProof) is legitimately accepted, so a blanket "accept ⇒ fail"
   would flood false positives.  Only [reliably_load_bearing] transforms are a
   genuine hole on accept — SForgeProof adds a proof about a FRESH `forged`
   subject the body can never carry, so a forgery-restricted kind MUST reject it.
   Non-reliable accepts are tallied into a census (reported, not failed). *)
let reliably_load_bearing = function
  | Mutate.SForgeProof -> true
  | Mutate.SDropParamProof | Mutate.SRetargetReturnSubject
  | Mutate.SRetargetParamSubject | Mutate.SWidenCaps
  | Mutate.SWeakenCaps | Mutate.SWeakenAuthVia -> false

(* (rel-file, fn, transform-name) triples whose ACCEPT is known-benign. Empty
   today; a genuine future accept is triaged into either a fix or this list. *)
let s7_accept_allowlist : (string * string * string) list = []

(* Census of non-reliable accepts, reported in the summary (not a failure). *)
let accept_census : (string, int) Hashtbl.t = Hashtbl.create 8
let bump_census name =
  Hashtbl.replace accept_census name (1 + (Option.value ~default:0 (Hashtbl.find_opt accept_census name)))

(* ci.sh sets this to scan the WHOLE corpus for accepts (unbudgeted); the fast
   dune-test layer leaves it unset and stays budget-bounded. *)
let exhaustive = Sys.getenv_opt "TESL_S7_EXHAUSTIVE" <> None

(* Keep the sweep FAST and its count STABLE across machines: take a deterministic
   budget of confirmed attributed kills (files are visited in sorted order).  The
   curated seeds are the backbone; the sweep proves the property generalises. *)
let sweep_budget = 120

(* Build one alcotest [test_case] per (file, fn, transform) that is a confirmed
   attributed kill on a clean-checking baseline.  Group names are the file path
   relative to the repo root so basename collisions cannot produce a duplicate
   alcotest path.  Returns the (group_name, test-cases) pairs plus the kill count
   for the summary assertion. *)
let sweep_cases () : ((string * unit test_case list) list * int) =
  match repo_root with
  | None -> ([], 0)
  | Some root ->
    let roots = [ Filename.concat root "example"; Filename.concat root "tests" ] in
    let files =
      List.concat_map tesl_files roots
      |> List.sort_uniq String.compare
    in
    let rel f =
      let n = String.length root in
      if String.length f > n && String.sub f 0 n = root
      then String.sub f (n + 1) (String.length f - n - 1)
      else f
    in
    let count = ref 0 in
    let groups =
      List.filter_map (fun file ->
        (* In exhaustive mode (ci.sh) keep visiting every file so accepts are
           scanned corpus-wide; the fast dune-test layer stays budget-bounded. *)
        if (not exhaustive) && !count >= sweep_budget then None else
        match Compile.parse_module_file file with
        | None -> None
        | Some m ->
          let src =
            try In_channel.with_open_text file In_channel.input_all
            with _ -> "" in
          (* Only sweep files that check CLEAN in-process. *)
          if error_diags (Compile.check_module src m) <> [] then None
          else begin
            let fn_names =
              List.filter_map (function
                | Ast.DFunc fd -> Some fd.Ast.name
                | _ -> None) m.decls
              |> List.sort_uniq String.compare
            in
            let seen = Hashtbl.create 16 in
            let cases =
              List.concat_map (fun fn ->
                List.filter_map (fun (transform, anchor) ->
                  let tname = Mutate.soundness_transform_name transform in
                  match
                    Mutate.apply_soundness_transform_to_module m ~fn_name:fn transform
                  with
                  | None -> None                     (* transform had no site here *)
                  | Some m' ->
                    let errs = error_diags (Compile.check_module src m') in
                    if errs = [] then begin
                      (* ACCEPTED a soundness-breaking transform (Option E). *)
                      if reliably_load_bearing transform
                         && not (List.mem (rel file, fn, tname) s7_accept_allowlist)
                      then
                        (* Genuine minting-gate hole — fail loudly for triage. *)
                        Some (test_case
                                (Printf.sprintf "CANDIDATE HOLE %s :: %s" fn tname)
                                `Quick (fun () ->
                          Alcotest.failf
                            "checker ACCEPTED a %s mutant of `%s` in %s — candidate \
                             soundness hole: a forgery-restricted kind now declares a \
                             return proof about a fresh subject its body never received, \
                             yet the checker did not reject it. Triage: fix the gate, or \
                             (if genuinely benign) add to s7_accept_allowlist with a reason."
                            tname fn (rel file)))
                      else begin bump_census tname; None end
                    end
                    else if matches anchor errs then begin
                      (* Attributed kill — record a budgeted regression case. *)
                      if (not exhaustive) && !count >= sweep_budget then None
                      else begin
                        incr count;
                        let base = Printf.sprintf "%s :: %s" fn tname in
                        (* Ensure per-group test-name uniqueness. *)
                        let name =
                          let rec uniq i =
                            let cand = if i = 0 then base
                                       else Printf.sprintf "%s #%d" base i in
                            if Hashtbl.mem seen cand then uniq (i + 1)
                            else (Hashtbl.add seen cand (); cand)
                          in uniq 0
                        in
                        (* Re-assert inside the test body so the corpus is a real
                           regression gate, not just a build-time count. *)
                        Some (test_case name `Quick (fun () ->
                          let m2 = match Compile.parse_module_file file with
                            | Some x -> x | None -> Alcotest.fail "reparse failed" in
                          let m3 =
                            match Mutate.apply_soundness_transform_to_module m2
                                    ~fn_name:fn transform with
                            | Some x -> x
                            | None -> Alcotest.fail "transform site vanished" in
                          Alcotest.check bool "attributed kill" true
                            (is_attributed_kill src m3 anchor)))
                      end
                    end
                    else None   (* killed, but not attributed to this anchor — soft drop *)
                ) sweep_transforms
              ) fn_names
            in
            match cases with
            | [] -> None
            | _  -> Some ("sweep: " ^ rel file, cases)
          end
      ) files
    in
    (groups, !count)

(* ── Test tree ───────────────────────────────────────────────────────────── *)

let () =
  let seed_groups =
    List.map (fun (r : row) ->
      (r.name,
       test_case "seed accepted (baseline)" `Quick
         (seed_accepted r.name r.src)
       :: List.map (fun (transform, anchor) ->
            test_case
              (Printf.sprintf "kill: %s"
                 (Mutate.soundness_transform_name transform))
              `Quick
              (mutant_killed ~seed_name:r.name ~fn:r.fn ~transform ~anchor r.src))
            r.transforms))
      corpus
  in
  (* Count curated mutant assertions (excludes the per-seed baseline case). *)
  let curated_kills =
    List.fold_left (fun acc (r : row) -> acc + List.length r.transforms) 0 corpus
  in
  let sweep_groups, sweep_kills = sweep_cases () in
  let total_kills = curated_kills + sweep_kills in
  Printf.printf
    "S7 corpus: %d curated + %d swept = %d attributed-kill assertions (target >= 50)\n%!"
    curated_kills sweep_kills total_kills;
  (* Option E: report the non-load-bearing accept census (informational — these
     are legitimately-accepted mutations of transforms whose accept does not imply
     a hole; reliably-load-bearing accepts are surfaced as failing tests above). *)
  if Hashtbl.length accept_census > 0 then
    Hashtbl.iter (fun name n ->
      Printf.printf "S7 accept-census: %d accept(s) of %s (non-load-bearing; informational)\n%!" n name)
      accept_census;
  let summary_group =
    ("corpus-size",
     [ test_case "at least 50 attributed-kill mutants" `Quick (fun () ->
         Alcotest.check bool
           (Printf.sprintf "kills=%d >= 50" total_kills)
           true (total_kills >= 50)) ])
  in
  run "S7-Generative-Negative-Corpus"
    (seed_groups @ sweep_groups @ [summary_group])
