(** `tesl generate elm` emitted a client that could not be completed: an
    ApiHelpers module the user is unable to write.

    A `check` whose predicate calls a helper `fn` is not inlinable into Elm, so
    the generated client delegates it to a hand-written
    `ApiHelpers.<check> : <base> -> Bool` and emits `import ApiHelpers`.

    When `<base>` is a type TESL OWNS — an ADT, a record, an entity, a newtype,
    `Money` — that type is declared IN the generated module.  Writing the
    ApiHelpers signature then requires importing the generated module, which
    already imports ApiHelpers:

        ┌─────┐
        │    ApiHelpers
        │     ↓
        │    Api
        └─────┘

    Elm rejects import cycles outright, so NEITHER module compiles and there is
    no way for the user to satisfy the generated client.  Discovered while
    fixing issue #72, where an `ApiHelpers` stub for a `List Permission` fact
    could only be made to compile by giving it a signature (`List a -> Bool`)
    different from the one the generator asked for.

    The fix has two halves, both pinned below.  Neither one DROPS the
    client-side smart constructor: the capability survives for every base type.

    1.  An `import ApiHelpers` delegation is only emitted when the base type is
        nameable from OUTSIDE the generated module
        ([Emit_elm.elm_type_nameable_outside_module]), and the module then
        prints the exact definitions to write, spelled in `elm/core` types.  A
        `newtype` becomes a transparent `type alias` in the generated Elm, so
        its UNDERLYING type is printed: `type Slug = String` in Tesl yields
        `checkSlug : String -> Bool`, not `checkSlug : Slug -> Bool`.  Copying
        the printed block verbatim produces a module that compiles.

    2.  For a Tesl-owned base type the dependency is INVERTED rather than
        dropped.  The generated module imports nothing hand-written and the
        smart constructor takes the predicate as a parameter, so the user's
        module is free to import the generated one and pass a predicate with
        full access to the domain type:

            App.mayReadProjects ApiHelpers.mayReadProjects perms

        Same trust level as the ApiHelpers route — a client-side predicate the
        server re-validates — and Elm still forces the caller to supply one, so
        it cannot be silently skipped.  Uniform injection was NOT chosen: for a
        core-nameable base the field decoder itself calls the smart constructor,
        so a predicate parameter would have to thread through every record
        decoder that references it.

    [assert_helper_signatures_are_core] is the family guard: whenever
    `import ApiHelpers` is emitted, EVERY printed parameter type must be built
    from `elm/core` names only.  A future rendering rule that lets a
    module-local name into that signature fails here rather than in a user's
    `elm make`. *)

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

let kebab_of_module m =
  let buf = Buffer.create 16 in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then begin
      Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c)
    end else Buffer.add_char buf c) m;
  Buffer.contents buf

let generate_elm ~module_name src =
  let dir = Filename.temp_dir "tesl-helpers-cycle" "" in
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

(* ── Family guard ─────────────────────────────────────────────────────────
   Pull the `<fn> : <type> -> Bool` lines out of the printed ApiHelpers block
   and check that every type name in them is an `elm/core` name.  A nominal
   type Tesl owns would have to be imported from the generated module, and that
   import is the cycle. *)
let core_type_names =
  ["String"; "Int"; "Float"; "Bool"; "Char"; "List"; "Maybe"; "Dict"; "Set";
   "Order"; "Never"; "Result"]

let helper_signature_lines out =
  List.filter_map (fun line ->
    let trimmed = String.trim line in
    (* Skip `--` comments: the blocked-delegation note names the signature it
       could NOT ask for, and that one is allowed to mention a local type. *)
    if String.length trimmed >= 2 && String.sub trimmed 0 2 = "--" then None
    else if contains trimmed " : " && contains trimmed " -> Bool"
            && not (contains trimmed "Decoder") && not (contains trimmed "Proven")
    then Some trimmed else None)
    (String.split_on_char '\n' out)

let assert_helper_signatures_are_core ~label out =
  if contains out "import ApiHelpers" then begin
    let sigs = helper_signature_lines out in
    if sigs = [] then
      failf "%s: `import ApiHelpers` emitted with no printed signature block to \
             tell the user what to write:\n%s" label out;
    List.iter (fun line ->
      (* "<fn> : <type> -> Bool" → the type between " : " and " -> Bool". *)
      let start = Str.search_forward (Str.regexp_string " : ") line 0 + 3 in
      let stop = Str.search_forward (Str.regexp_string " -> Bool") line start in
      let ty = String.sub line start (stop - start) in
      let words =
        List.filter (fun w -> w <> "")
          (String.split_on_char ' '
             (String.map (fun c -> match c with '(' | ')' -> ' ' | c -> c) ty))
      in
      List.iter (fun w ->
        if w <> "" && w.[0] >= 'A' && w.[0] <= 'Z' && not (List.mem w core_type_names) then
          failf "%s: ApiHelpers signature %S names `%s`, which is declared in the \
                 GENERATED module — writing that signature needs an import back \
                 into the generated module, and Elm rejects the import cycle:\n%s"
            label line w out) words) sigs
  end

(* ── Fixtures ─────────────────────────────────────────────────────────────── *)

(* Tesl-owned ADT base: delegation is impossible, so it must not be requested. *)
let adt_base_src = {|module CycleAdt exposing [DummyApi]
import Tesl.Prelude exposing [Bool(..), String, List]
import Tesl.List exposing [List.member]

type Permission
  = ReadProjects
  | WriteCostRates

fn hasRead(perms: List Permission) -> Bool =
  List.member ReadProjects perms

fact MayReadProjects (perms: List Permission)

check mayReadProjects(perms: List Permission) -> perms: List Permission ::: MayReadProjects perms =
  if hasRead perms then
    ok perms ::: MayReadProjects perms
  else
    fail 403 "missing permission"

record Grant {
  granted: List Permission ::: MayReadProjects granted
}

codec Grant {
  toJson {
    granted -> "granted"
  }
  fromJson_forbidden
}

handler dummy() -> Grant =
  let raw = [ReadProjects]
  let allowed = check mayReadProjects raw
  Grant { granted: allowed }

api DummyApi {
  get "/dummy" -> Grant
}

server DummyServer for DummyApi {
  dummy = dummy
}
|}

(* A RECORD base — the other big Tesl-owned family, and the case that was most
   useless before: `ApiHelpers.checkBig` could only have compiled with a
   signature so generic (`a -> Bool`) that it could not read a single field. *)
let record_base_src = {|module CycleRecord exposing [OrderApi]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Json exposing [stringCodec, intCodec]

record Order {
  code: String
  qty: Int
}

codec Order {
  toJson {
    code -> "code" with_codec stringCodec
    qty -> "qty" with_codec intCodec
  }
  fromJson [
    {
      code <- "code" with_codec stringCodec
      qty <- "qty" with_codec intCodec
    }
  ]
}

fn isBig(o: Order) -> Bool =
  o.qty >= 10

fact BigOrder (o: Order)

check checkBig(o: Order) -> o: Order ::: BigOrder o =
  if isBig o then
    ok o ::: BigOrder o
  else
    fail 400 "too small"

api OrderApi {
  post "/orders" body o: Order ::: BigOrder o -> String
}
|}

(* Primitive base — the issue #13 scenario the delegation was built for. It
   still works, and now prints the definitions to copy. *)
let primitive_base_src = {|module CyclePrimitive exposing [CodeApi]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.String exposing [String.length]

fn looksLikeCode(s: String) -> Bool =
  String.length s >= 3

fact ValidCode (s: String)

check checkCode(s: String) -> s: String ::: ValidCode s =
  if looksLikeCode s then
    ok s ::: ValidCode s
  else
    fail 400 "bad code"

api CodeApi {
  post "/code" body payload: String ::: ValidCode payload -> String
}
|}

(* A Tesl `newtype` is NOMINAL in Tesl but emits a TRANSPARENT `type alias` in
   Elm, so an outside module can spell the underlying type and Elm unifies the
   two. The delegation survives — with the UNDERLYING type printed. *)
let newtype_base_src = {|module CycleNewtype exposing [SlugApi]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.String exposing [String.length]

type Slug = String

fn looksLikeSlug(s: Slug) -> Bool =
  String.length s.value >= 2

fact ValidSlug (s: Slug)

check checkSlug(s: Slug) -> s: Slug ::: ValidSlug s =
  if looksLikeSlug s then
    ok s ::: ValidSlug s
  else
    fail 400 "bad slug"

api SlugApi {
  post "/slug" body slug: Slug ::: ValidSlug slug -> String
}
|}

(* Compound but still core-nameable: `List String` is fine. *)
let compound_core_base_src = {|module CycleCompound exposing [TagApi]
import Tesl.Prelude exposing [Bool(..), String, List]
import Tesl.List exposing [List.member]

fn hasRead(tags: List String) -> Bool =
  List.member "read" tags

fact MayRead (tags: List String)

check mayRead(tags: List String) -> tags: List String ::: MayRead tags =
  if hasRead tags then
    ok tags ::: MayRead tags
  else
    fail 403 "denied"

api TagApi {
  post "/tags" body tags: List String ::: MayRead tags -> String
}
|}

(* ── Tests ────────────────────────────────────────────────────────────────── *)

let adt_base_injects_the_predicate_instead_of_importing () =
  let out = generate_elm ~module_name:"CycleAdt" adt_base_src in
  assert_not_contains ~label:"ADT base must not import ApiHelpers" out
    "import ApiHelpers";
  (* The explanatory comment below NAMES the helper it cannot ask for, so match
     the call site rather than the mention. *)
  assert_not_contains ~label:"ADT base must not call ApiHelpers" out
    "if ApiHelpers.";
  (* The capability is INVERTED, not lost: the constructor is still exported… *)
  assert_contains ~label:"smart constructor still exported" out
    "    , mayReadProjects\n";
  (* …and takes the predicate, so the caller's module can import this one. *)
  assert_contains ~label:"predicate is a parameter" out
    "mayReadProjects : (List Permission -> Bool) -> List Permission -> \
     Maybe (Proven (List Permission) MayReadProjects)";
  assert_contains ~label:"predicate is applied, not assumed" out
    "    if predicate input then";
  assert_contains ~label:"cycle explained in the generated module" out
    "Elm rejects that pair as an import";
  assert_contains ~label:"inversion explained in the generated module" out
    "The predicate is a parameter instead";
  (* The decoder cannot ask a call site for a predicate, so it stays
     server-trusting — threading one through record decoders would be viral. *)
  assert_contains ~label:"server-trusting decoder still emitted" out
    "mayReadProjectsFieldDecoder : D.Decoder (Proven (List Permission) MayReadProjects)";
  assert_contains ~label:"decoder maps the axiom" out
    "|> D.map (axiom MayReadProjects)";
  assert_helper_signatures_are_core ~label:"ADT base" out

let record_base_injects_the_predicate () =
  let out = generate_elm ~module_name:"CycleRecord" record_base_src in
  assert_not_contains ~label:"record base must not import ApiHelpers" out
    "import ApiHelpers";
  (* The constructor is named after the FACT, not the check. *)
  assert_contains ~label:"record smart constructor exported" out
    "    , bigOrder\n";
  assert_contains ~label:"record predicate is a parameter" out
    "bigOrder : (Order -> Bool) -> Order -> Maybe (Proven Order BigOrder)";
  (* The comment still names the ApiHelpers signature that could NOT be asked
     for, so the reader can see exactly what the inversion replaced. *)
  assert_contains ~label:"blocked ApiHelpers signature named" out
    "`ApiHelpers.checkBig : Order -> Bool`";
  assert_helper_signatures_are_core ~label:"record base" out

let primitive_base_keeps_the_helper_and_prints_it () =
  let out = generate_elm ~module_name:"CyclePrimitive" primitive_base_src in
  assert_contains ~label:"primitive base still delegates" out "import ApiHelpers";
  assert_contains ~label:"delegation call" out "if ApiHelpers.checkCode input then";
  assert_contains ~label:"exposing line to copy" out
    "module ApiHelpers exposing (checkCode)";
  assert_contains ~label:"signature to copy" out "checkCode : String -> Bool";
  assert_contains ~label:"cycle warned about" out
    "Do NOT import this module from ApiHelpers";
  assert_helper_signatures_are_core ~label:"primitive base" out

let newtype_base_prints_the_underlying_type () =
  let out = generate_elm ~module_name:"CycleNewtype" newtype_base_src in
  assert_contains ~label:"newtype base still delegates" out "import ApiHelpers";
  (* `Slug` is a module-local alias; printing it would send the user straight
     into the cycle. The underlying `String` is what unifies. *)
  assert_contains ~label:"underlying type printed" out "checkSlug : String -> Bool";
  assert_not_contains ~label:"alias name must not be printed" out
    "checkSlug : Slug -> Bool";
  assert_helper_signatures_are_core ~label:"newtype base" out

let compound_core_base_keeps_the_helper () =
  let out = generate_elm ~module_name:"CycleCompound" compound_core_base_src in
  assert_contains ~label:"List String base still delegates" out "import ApiHelpers";
  assert_contains ~label:"compound signature printed" out "mayRead : List String -> Bool";
  assert_helper_signatures_are_core ~label:"compound core base" out

(* The guard has to be able to FAIL, or it pins nothing. *)
let guard_rejects_a_module_local_helper_signature () =
  let broken =
    "import ApiHelpers\n\n       mayReadProjects : List Permission -> Bool\n"
  in
  match assert_helper_signatures_are_core ~label:"synthetic" broken with
  | () -> failwith "guard accepted an ApiHelpers signature naming a generated type"
  | exception Failure _ -> ()

let () =
  run "elm-api-helpers-import-cycle" [
    "elm", [
      test_case "Tesl-owned base type injects the predicate instead of importing" `Quick
        adt_base_injects_the_predicate_instead_of_importing;
      test_case "record base injects the predicate" `Quick
        record_base_injects_the_predicate;
      test_case "primitive base keeps the delegation and prints it verbatim" `Quick
        primitive_base_keeps_the_helper_and_prints_it;
      test_case "newtype base prints the underlying core type" `Quick
        newtype_base_prints_the_underlying_type;
      test_case "List String base keeps the delegation" `Quick
        compound_core_base_keeps_the_helper;
      test_case "guard rejects a module-local ApiHelpers signature" `Quick
        guard_rejects_a_module_local_helper_signature;
    ];
  ]
