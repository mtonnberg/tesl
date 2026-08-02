(** GitHub issue #72 — `tesl generate elm` emitted an UNPARENTHESIZED compound
    base type in `Proven`'s type-argument slot.

    A `fact` over a multi-word type (`fact MayReadProjects (perms: List
    Permission)`) produced

      mayReadProjectsFieldDecoder : D.Decoder (Proven List Permission MayReadProjects)

    Elm reads type application as juxtaposition, so `Proven` got THREE arguments
    (`List`, `Permission`, `MayReadProjects`) instead of two, and `elm make`
    rejected the generated module with

      The `List` type needs 1 argument, but I see 0 instead

    The BODY was already correct — only the standalone type signature was wrong.

    Root cause and the shape of the fix
    ------------------------------------------------------------------------
    [Emit_elm] renders a type to text and then splices that text into larger
    types.  Three of its four "parenthesize before splicing" helpers decided
    from the rendered TEXT (any space ⇒ wrap), which is total; the fact section
    used the raw [elm_type_of_type_expr] with no wrapping at all, and
    [elm_type_arg] decided from the AST NODE KIND (`TApp | TFun | TTuple`),
    which is not total — a bare `Set` renders as `List value` from a [TName].

    All four now route through the single text-driven [elm_paren_if_applied], so
    the rule holds for every present and future rendering rule rather than for
    the node kinds someone remembered to list.

    What is pinned below
    ------------------------------------------------------------------------
    - the four `fact` emit kinds that carry a base type into `Proven`
      (server-only, auth, ApiHelpers-delegated, and the record-field position
      that was already correct — it must stay correct);
    - a STRUCTURAL family guard, [assert_proven_arity], that parses every
      `Proven` occurrence in the generated module and fails unless it is
      followed by exactly two top-level atoms.  That catches the whole class,
      not just the `List` instance from the report. *)

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

let failf fmt = Printf.ksprintf failwith fmt

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

(* The compiler resolves imports by file name, so the temp file must be named
   after its module header (V001). *)
let kebab_of_module m =
  let buf = Buffer.create 16 in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then begin
      Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c)
    end else Buffer.add_char buf c) m;
  Buffer.contents buf

let generate_elm ~module_name src =
  let dir = Filename.temp_dir "tesl-issue72" "" in
  let path = Filename.concat dir (kebab_of_module module_name ^ ".tesl") in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () ->
      let code, out = run_cc ["--generate-elm"; path] in
      if code <> 0 then failf "generation failed (exit %d):\n%s" code out;
      out)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let assert_contains ~label out needle =
  if not (contains out needle) then
    failf "%s: expected %S in generated Elm:\n%s" label needle out

let assert_not_contains ~label out needle =
  if contains out needle then
    failf "%s: did not expect %S in generated Elm:\n%s" label needle out

(* ── Structural family guard ──────────────────────────────────────────────
   `Proven` is a two-parameter Elm type.  Read the top-level atoms that follow
   each occurrence — a bare word or a balanced parenthesized group counts as
   one atom — stopping at the end of the enclosing group, at an arrow, or at
   end of line.  Exactly two atoms means the base type was parenthesized when
   it needed to be; three or more means the base leaked its own arguments into
   `Proven`'s slot, which is the whole bug class of issue #72. *)
let proven_atoms text start =
  let n = String.length text in
  let atoms = ref [] in
  let buf = Buffer.create 16 in
  let depth = ref 0 in
  let i = ref start in
  let stop = ref false in
  let flush () =
    if Buffer.length buf > 0 then begin
      atoms := Buffer.contents buf :: !atoms;
      Buffer.clear buf
    end
  in
  while (not !stop) && !i < n do
    (match text.[!i] with
     | '\n' -> stop := true
     | '(' | '{' as c -> incr depth; Buffer.add_char buf c
     | (')' | '}') as c -> if !depth = 0 then stop := true else (decr depth; Buffer.add_char buf c)
     | (' ' | ',') as c when !depth = 0 -> flush (); if c = ',' then stop := true
     | c -> Buffer.add_char buf c);
    incr i
  done;
  flush ();
  (* An arrow ends the type-argument list just as reliably as a closing paren. *)
  let rec until_arrow = function
    | [] -> []
    | ("->" | "|>" | "=") :: _ -> []
    | x :: rest -> x :: until_arrow rest
  in
  until_arrow (List.rev !atoms)

let assert_proven_arity ~label original =
  (* `import RefinementProofs.Theory exposing (Proven, axiom, …)` mentions the
     name in a value list, not a type position — drop that one line. *)
  let text =
    String.concat "\n"
      (List.filter
         (fun line -> not (contains line "import RefinementProofs.Theory"))
         (String.split_on_char '\n' original))
  in
  let re = Str.regexp_string "Proven " in
  let rec scan from =
    match Str.search_forward re text from with
    | exception Not_found -> ()
    | pos ->
      let after = pos + String.length "Proven " in
      let atoms = proven_atoms text after in
      if List.length atoms <> 2 then
        failf "%s: `Proven` applied to %d arguments (%s) — a compound base type \
               lost its parentheses (issue #72):\n%s"
          label (List.length atoms) (String.concat " | " atoms) text;
      scan after
  in
  scan 0

(* ── Fixtures ─────────────────────────────────────────────────────────────── *)

(* The report's own shape: an ADT vocabulary carried as `List Permission`
   through an api `auth` binding.  Classifies as FkAuth. *)
let auth_src = {|module Issue72Auth exposing [DummyApi]
import Tesl.Prelude exposing [String, List]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]

type Permission
  = ReadProjects
  | WriteCostRates

fact MayReadProjects (perms: List Permission)

auth resolveCaller(request: HttpRequest) -> perms: List Permission ::: MayReadProjects perms =
  case Dict.lookup "perm" request.cookies of
    Nothing -> fail 401 "no caller"
    Something _claim ->
      let perms = [ReadProjects]
      ok perms ::: MayReadProjects perms

handler dummy(perms: List Permission ::: MayReadProjects perms) -> String =
  "ok"

api DummyApi {
  get "/dummy"
    auth perms: List Permission ::: MayReadProjects perms via resolveCaller
    -> String
}

server DummyServer for DummyApi {
  dummy = dummy
}
|}

(* A stdlib-only predicate over a `List String` body binding.  The predicate is
   not client-translatable, so this classifies as FkServerOnly — the emit arm
   that only writes a decoder signature. *)
let server_only_src = {|module Issue72ServerOnly exposing [TagApi]
import Tesl.Prelude exposing [Bool(..), Int, String, List]
import Tesl.List exposing [List.length]

fact NonEmptyTags (tags: List String)

check checkTags(tags: List String) -> tags: List String ::: NonEmptyTags tags =
  if List.length tags >= 1 then
    ok tags ::: NonEmptyTags tags
  else
    fail 400 "empty"

api TagApi {
  post "/tags" body tags: List String ::: NonEmptyTags tags -> String
}
|}

(* The predicate is factored into a user `fn`, so the Elm side delegates to
   `ApiHelpers.<check>` — FkElmHelper, the arm that writes BOTH a smart
   constructor signature and a decoder signature.  The record field pins the
   position that was already correct before the fix.

   The base is `List String` rather than `List Permission` on purpose: a
   Tesl-owned base type keeps the ApiHelpers delegation from being emitted at
   all (an outside module cannot name it without closing an import cycle — see
   test_elm_api_helpers_cycle.ml), and this test needs the delegating arm. *)
let helper_src = {|module Issue72Helper exposing [DummyApi]
import Tesl.Prelude exposing [Bool(..), String, List]
import Tesl.List exposing [List.member]

fn hasRead(tags: List String) -> Bool =
  List.member "read" tags

fact MayReadProjects (tags: List String)

check mayReadProjects(tags: List String) -> tags: List String ::: MayReadProjects tags =
  if hasRead tags then
    ok tags ::: MayReadProjects tags
  else
    fail 403 "missing permission"

record Grant {
  granted: List String ::: MayReadProjects granted
}

codec Grant {
  toJson {
    granted -> "granted"
  }
  fromJson_forbidden
}

handler dummy() -> Grant =
  let raw = ["read"]
  let allowed = check mayReadProjects raw
  Grant { granted: allowed }

api DummyApi {
  get "/dummy" -> Grant
}

server DummyServer for DummyApi {
  dummy = dummy
}
|}

(* `List` is not the only compound base a fact can take. *)
let maybe_src = {|module Issue72Maybe exposing [NoteApi]
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.Maybe exposing [Maybe(..)]

fact NoteGiven (note: Maybe String)

check checkNote(note: Maybe String) -> note: Maybe String ::: NoteGiven note =
  case note of
    Nothing -> fail 400 "no note"
    Something _text -> ok note ::: NoteGiven note

api NoteApi {
  post "/notes" body note: Maybe String ::: NoteGiven note -> String
}
|}

(* ── Tests ────────────────────────────────────────────────────────────────── *)

let auth_fact_decoder_parenthesizes_compound_base () =
  let out = generate_elm ~module_name:"Issue72Auth" auth_src in
  assert_contains ~label:"auth decoder signature" out
    "mayReadProjectsFieldDecoder : D.Decoder (Proven (List Permission) MayReadProjects)";
  assert_not_contains ~label:"auth decoder signature (unparenthesized)" out
    "Proven List Permission";
  assert_proven_arity ~label:"auth module" out

let server_only_fact_decoder_parenthesizes_compound_base () =
  let out = generate_elm ~module_name:"Issue72ServerOnly" server_only_src in
  assert_contains ~label:"server-only decoder signature" out
    "nonEmptyTagsFieldDecoder : D.Decoder (Proven (List String) NonEmptyTags)";
  assert_not_contains ~label:"server-only decoder signature (unparenthesized)" out
    "Proven List String";
  assert_proven_arity ~label:"server-only module" out

let helper_smart_constructor_parenthesizes_compound_base () =
  let out = generate_elm ~module_name:"Issue72Helper" helper_src in
  (* The ARGUMENT side of the arrow is not a type-argument slot and must stay
     unparenthesized; only `Proven`'s first slot needs the parens. *)
  assert_contains ~label:"helper smart constructor" out
    "mayReadProjects : List String -> Maybe (Proven (List String) MayReadProjects)";
  assert_contains ~label:"helper decoder signature" out
    "mayReadProjectsFieldDecoder : D.Decoder (Proven (List String) MayReadProjects)";
  assert_contains ~label:"record field keeps its parens" out
    "{ granted : Proven (List String) MayReadProjects";
  assert_not_contains ~label:"helper module (unparenthesized)" out
    "Proven List String";
  assert_proven_arity ~label:"helper module" out

let maybe_base_parenthesizes_compound_base () =
  let out = generate_elm ~module_name:"Issue72Maybe" maybe_src in
  assert_contains ~label:"Maybe-based fact decoder" out
    "noteGivenFieldDecoder : D.Decoder (Proven (Maybe String) NoteGiven)";
  assert_not_contains ~label:"Maybe-based fact decoder (unparenthesized)" out
    "Proven Maybe String";
  assert_proven_arity ~label:"maybe module" out

(* The guard has to be able to FAIL, or it pins nothing. *)
let proven_arity_guard_rejects_the_reported_output () =
  let broken =
    "mayReadProjectsFieldDecoder : D.Decoder (Proven List Permission MayReadProjects)\n"
  in
  match assert_proven_arity ~label:"synthetic" broken with
  | () -> failwith "assert_proven_arity accepted the malformed signature from issue #72"
  | exception Failure _ -> ()

let () =
  run "issue-72-elm-compound-proof-base" [
    "elm", [
      test_case "auth fact decoder parenthesizes List Permission" `Quick
        auth_fact_decoder_parenthesizes_compound_base;
      test_case "server-only fact decoder parenthesizes List String" `Quick
        server_only_fact_decoder_parenthesizes_compound_base;
      test_case "ApiHelpers smart constructor + decoder parenthesize List Permission" `Quick
        helper_smart_constructor_parenthesizes_compound_base;
      test_case "Maybe base is parenthesized too" `Quick
        maybe_base_parenthesizes_compound_base;
      test_case "arity guard rejects the reported malformed signature" `Quick
        proven_arity_guard_rejects_the_reported_output;
    ];
  ]
