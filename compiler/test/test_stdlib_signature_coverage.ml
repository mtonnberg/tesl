(** Seam test: every stdlib VALUE export has a real type signature.

    A stdlib export that is absent from {!Type_system.stdlib_env} does not fail
    to compile — it type-checks as ANYTHING.  Before this test,
    `Float.abs "hello" : String` passed `tesl check`, and a nominal boundary type
    (Int32, Money, PosixMillis) could be laundered through any such name.  The
    docs catalog HID the hole rather than exposing it: a plain function
    documented with [KSyntax] prose renders a hand-written signature string
    instead of the live scheme, so it looked documented while being untyped.
    (That is how 50 Float / String / Int / Dict / Set functions were untyped;
    they now carry schemes and render as [KFunction].)

    THE INVARIANT PINNED HERE.  Every name exported by a Tesl.* module (plus the
    always-available and bare-home-module names) is classified by its
    {!Stdlib_docs} entry kind:

      KFunction / KValue  → MUST have a [stdlib_env] scheme (the signature the
                            checker uses IS the signature the docs render).
      KType / KFact /
      KCapability /
      KConfig / KFamily   → no value scheme exists (a type, a proof predicate,
                            a capability token, a config record, a generated
                            constructor family).
      KSyntax             → a form the compiler LOWERS specially, so no scheme
                            can exist; must be listed in [lowered_forms] below.

    The [lowered_forms] list is the only escape hatch, and it is a ratchet: a
    name that gains a scheme must be REMOVED from it (the test says so), and a
    new untyped export cannot be added without editing this file — at which
    point "is this really a lowered form, or a function that needs a
    signature?" is a review question rather than an invisible default.

    Names typed from a LIFTED `.tesl` source (Tesl.List / Tesl.ListPrim /
    Tesl.Either — see [Checker.lifted_stdlib_basename]) are deliberately absent
    from [stdlib_env]; their signatures live in `tesl/*.tesl` and are loaded by
    [Checker.load_imported_func_sigs], so they are excluded by module. *)

open Alcotest

module SS = Set.Make (String)

let strip_dotdot s =
  let n = String.length s in
  if n > 4 && String.sub s (n - 4) 4 = "(..)" then String.sub s 0 (n - 4) else s

(** Modules whose function TYPES are lifted into a bundled `.tesl` source and
    loaded from there, so [stdlib_env] intentionally has no row. *)
let lifted_modules = [ "Tesl.List"; "Tesl.ListPrim"; "Tesl.Either" ]

(** Compiler-lowered forms: documented with [KSyntax], no value scheme possible.
    RATCHET — see the header.  Grouped by why they are lowered. *)
let lowered_forms : string list = [
  (* Declaration/config forms whose docs row is a plain KSyntax sketch rather
     than a KConfig/KType row: the name is a BLOCK head the desugarer rewrites,
     not a value you can pass. *)
  "cache"; "Email.send"; "startEmailWorker"; "humanActions"; "serverTools";
  (* Tesl.Json codecs are lowered INLINE (emit_requires skips the module
     wholesale — see test_stdlib_runtime_binding.ml's inline_modules). *)
  "stringCodec"; "intCodec"; "int32Codec"; "boolCodec"; "floatCodec";
  "posixMillisCodec"; "moneyCodec"; "listCodec"; "dictCodec"; "setCodec";
  (* api-test matchers / stream forms: desugared inside an api-test body, where
     the JSON values they inspect are dynamically typed. *)
  "subscribe"; "collect"; "isNull"; "isNotNull"; "isEmpty"; "isNotEmpty";
  "includesWhere"; "excludesWhere"; "hasLength"; "hasField"; "arrayAt";
  "fieldAt"; "bodyField"; "jsonContains"; "jsonInt"; "jsonString"; "jsonBool";
  "jsonArray"; "jsonObject"; "jsonLength"; "expectJobOk"; "expectJobFailed";
  "JsonNull";
  (* Cache reads/writes name a declared `cache` BLOCK, not a value:
     `Cache.get <CacheName> (key)` lowers with the cache name inlined. *)
  "Cache.get"; "Cache.set"; "Cache.delete"; "Cache.invalidate";
  (* Money rates: the value carries its currency and the TYPE carries the
     denominator dimension, so these resolve through the units checker path. *)
  "MoneyRate.currency"; "MoneyRate.display";
]

let lowered = SS.of_list lowered_forms

(* ── The sweep ───────────────────────────────────────────────────────────── *)

let all_exports () : (string * string) list =
  List.concat_map (fun (m, names) ->
    if List.mem m lifted_modules then []
    else List.map (fun n -> (strip_dotdot n, m)) names)
    Type_system.tesl_module_exports
  @ List.map (fun n -> (n, "<always-available>"))
      Type_system.always_available_stdlib_names
  @ Type_system.stdlib_bare_home_module

let env = lazy (Type_system.make_stdlib_env ())
let has_scheme name = List.mem_assoc name (Lazy.force env)

(** The documented kind for a name, if the catalog has one. *)
let kinds_of name =
  List.map (fun (e : Stdlib_docs.entry) -> e.kind) (Stdlib_docs.lookup name)

(** True when SOME documented kind for this name is one that cannot have a
    value scheme.  (A name can be documented by more than one module — e.g.
    IsNonZero from Tesl.Int and Tesl.Int32.) *)
let kind_needs_no_scheme name =
  let no_scheme_kind = function
    | Stdlib_docs.KType _ | Stdlib_docs.KFact _ | Stdlib_docs.KCapability
    | Stdlib_docs.KConfig | Stdlib_docs.KFamily _ -> true
    | Stdlib_docs.KFunction _ | Stdlib_docs.KValue -> false
    | Stdlib_docs.KSyntax _ -> false  (* handled by the ratchet, not here *)
  in
  List.exists no_scheme_kind (kinds_of name)

let is_documented_syntax name =
  List.exists (function Stdlib_docs.KSyntax _ -> true | _ -> false) (kinds_of name)

(* An export is untyped-and-unexplained when it has no scheme, its documented
   kind does not excuse it, and it is not on the lowered-forms ratchet. *)
let t_every_value_export_is_typed () =
  let offenders =
    all_exports ()
    |> List.filter (fun (n, _) ->
         not (has_scheme n)
         && not (kind_needs_no_scheme n)
         && not (Stdlib_docs.family_member n)
         && not (SS.mem n lowered))
    |> List.sort_uniq compare
  in
  if offenders <> [] then
    Alcotest.failf
      "%d stdlib export(s) have NO stdlib_env signature, so they type-check as \
       anything (`Float.abs \"hello\" : String` compiles).  Give each a scheme \
       in type_system.ml stdlib_env and document it with `f`/`v` (KFunction / \
       KValue) so the docs render the live type — or, if the compiler really \
       lowers it specially, add it to [lowered_forms] in this test with a \
       reason:\n%s"
      (List.length offenders)
      (String.concat "\n"
         (List.map (fun (n, m) -> Printf.sprintf "  %-32s (%s)" n m) offenders))

(* The ratchet direction: a lowered form that GAINED a scheme is now a normal
   typed function and must leave the list, so the escape hatch cannot quietly
   accumulate names that no longer need it. *)
let t_lowered_forms_list_only_shrinks () =
  let stale = List.filter has_scheme lowered_forms |> List.sort_uniq compare in
  if stale <> [] then
    Alcotest.failf
      "%d name(s) in [lowered_forms] now HAVE a stdlib_env scheme — remove them \
       from the list (and document them with `f`/`v` so the docs render the live \
       type):\n%s"
      (List.length stale) (String.concat "\n" (List.map (fun n -> "  " ^ n) stale))

(* Every ratchet entry must be a real export, so the list cannot rot into
   names that no longer exist. *)
let t_lowered_forms_are_real_exports () =
  let known =
    SS.of_list (List.map fst (all_exports ()))
  in
  let phantom = List.filter (fun n -> not (SS.mem n known)) lowered_forms in
  if phantom <> [] then
    Alcotest.failf
      "%d name(s) in [lowered_forms] are not stdlib exports (stale entries):\n%s"
      (List.length phantom) (String.concat "\n" (List.map (fun n -> "  " ^ n) phantom))

(* Every ratchet entry must actually be DOCUMENTED as a syntax form — that is
   the claim the list makes about it. *)
(* The list must say something the docs kind does not already say: a name whose
   documented kind is a type / fact / capability / config / family is excused by
   kind, so listing it here is redundant noise. *)
let t_lowered_forms_are_not_redundant () =
  let redundant = List.filter kind_needs_no_scheme lowered_forms in
  if redundant <> [] then
    Alcotest.failf
      "%d name(s) in [lowered_forms] are already excused by their documented        kind (type/fact/capability/config/family) — remove them:\n%s"
      (List.length redundant)
      (String.concat "\n" (List.map (fun n -> "  " ^ n) redundant))

let t_lowered_forms_are_documented_as_syntax () =
  let mislabeled =
    List.filter (fun n -> not (is_documented_syntax n) && not (kind_needs_no_scheme n))
      lowered_forms
  in
  if mislabeled <> [] then
    Alcotest.failf
      "%d name(s) in [lowered_forms] are not documented as a KSyntax (or \
       type/fact/capability/config/family) entry — either document the lowered \
       form or give the function a real signature:\n%s"
      (List.length mislabeled)
      (String.concat "\n" (List.map (fun n -> "  " ^ n) mislabeled))

(* A directly observable consequence of the fix, so the test names the symptom
   and not only the table: the numeric surfaces are typed end to end. *)
let t_numeric_surfaces_are_fully_typed () =
  let must_be_typed =
    [ (* every Tesl.Float export that is a function/value *)
      "Float.abs"; "Float.min"; "Float.max"; "Float.clamp"; "Float.sqrt";
      "Float.pow"; "Float.log"; "Float.exp"; "Float.sin"; "Float.cos";
      "Float.tan"; "Float.isNaN"; "Float.isInfinite"; "Float.isPositive";
      "Float.isNegative"; "Float.isZero"; "Float.sign"; "Float.infinity";
      "Float.nan"; "Float.parse"; "Float.toString"; "Float.toInt";
      (* Int helpers *)
      "Int.toFloat"; "Int.fromFloat"; "Int.clamp"; "Int.gcd"; "Int.lcm";
      "Int.pow"; "Int.digits"; "Int.sign"; "Int.isEven"; "Int.isOdd";
      (* the Int32 companion surface (NT-07) *)
      "Int32.toFloat"; "Int32.toString"; "Int32.parse"; "Int32.fromFloat";
      "Int32.add"; "Int32.subtract"; "Int32.multiply"; "Int32.clamp";
      "Int32.min"; "Int32.max"; "Int32.sign"; "Int32.digits";
      "Int32.minValue"; "Int32.maxValue"; "Int32.fromIntClamped" ]
  in
  let missing = List.filter (fun n -> not (has_scheme n)) must_be_typed in
  if missing <> [] then
    Alcotest.failf "%d numeric stdlib name(s) still have no signature:\n%s"
      (List.length missing) (String.concat "\n" (List.map (fun n -> "  " ^ n) missing))

let () =
  run "Stdlib-Signature-Coverage" [
    "typed", [
      test_case "every stdlib value export has a stdlib_env scheme" `Quick
        t_every_value_export_is_typed;
      test_case "the numeric surfaces are fully typed" `Quick
        t_numeric_surfaces_are_fully_typed;
    ];
    "ratchet", [
      test_case "lowered_forms only shrinks" `Quick t_lowered_forms_list_only_shrinks;
      test_case "lowered_forms names are real exports" `Quick
        t_lowered_forms_are_real_exports;
      test_case "lowered_forms names are documented as syntax forms" `Quick
        t_lowered_forms_are_documented_as_syntax;
      test_case "lowered_forms has no kind-excused entries" `Quick
        t_lowered_forms_are_not_redundant;
    ];
  ]
