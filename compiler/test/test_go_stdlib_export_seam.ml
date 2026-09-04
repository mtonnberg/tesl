(** Durable seam test: no stdlib export reaches the Go emitter's fallthrough by accident.

    Each stdlib module's export list is matched name by name in [Emit_go.compile_module], and
    every match ends in

      {[ | other -> unsupported loc "Go backend does not emit the `Tesl.M` export `%s`: …" other ]}

    which is the right shape — an unwired name must be REFUSED, not emitted as something the
    backend guessed at — but it is silent in the direction that matters to us: adding an
    export to {!Type_system.tesl_module_exports} routes it straight to that arm, so a NEW
    stdlib feature is refused at the user's compile time with no signal at ours. The
    fallthrough would quietly eat every future addition.

    This closes that direction. Every export in {!Type_system.tesl_module_exports} is
    compiled through the Go pipeline. Exports in
    {!Type_system.go_backend_unavailable_exports} must be rejected by the checker; every
    emitter fallthrough is therefore an unclassified backend gap and fails this suite.

    The probe is an IMPORT: the export match runs at the import, so importing one name is
    enough to reach it. Some wired leaves answer a `Maybe`/`Result` or take a `TimeZone`, and
    say so at the import rather than emitting; those companions are added to every probe so
    that "needs a companion import" cannot read as "unsupported". *)

open Alcotest

let contains haystack needle =
  let n = String.length needle and m = String.length haystack in
  let rec loop i = i + n <= m && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0

(* The companions a wired leaf may need in scope. Importing them is harmless for a name that
   needs none: an unused import is not an error in Tesl. *)
let companions = {|import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Result exposing [Result(..)]
import Tesl.Either exposing [Either(..)]
import Tesl.Tuple exposing [Tuple2]
import Tesl.Time exposing [PosixMillis, TimeZone]
|}

(* A name the PARSER cannot put in an `exposing` list (the `?`-suffixed optional-field
   spellings) is not a probe this test can run. *)
let probeable name = not (String.contains name '?')

type answer = Wired | Refused of string | Rejected of string

let probe module_name export =
  let source =
    Printf.sprintf
      "module GoExportProbe exposing [zero]\n\
       import Tesl.Prelude exposing [Int]\n\
       %s\
       import %s exposing [%s]\n\
       fn zero() -> Int = 0\n"
      (if module_name = "Tesl.Prelude" then "" else companions) module_name export
  in
  match Compile.compile_go_source "<go-export-probe>" source with
  | Compile.GoSuccess _ -> Wired
  | Compile.GoFailure diagnostics ->
    let message = String.concat "; "
      (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics) in
    if List.exists (fun (d : Compile.diagnostic) ->
         (* Matched on the SHAPE of the fallthrough's message, which every module arm shares:
            "does not emit the `Tesl.M` export `x`".  A refusal that says something else is a
            different rule (a type refusal, a capability refusal) and belongs in [Rejected]. *)
         d.source = "go-emitter" && contains d.message "does not emit the"
         && contains d.message "export") diagnostics
    then Refused message
    else Rejected message

(* The compiler's single source of truth for intentionally unavailable Go exports. *)
let unavailable_exports = Type_system.go_backend_unavailable_exports

let listed module_name export =
  match List.assoc_opt module_name unavailable_exports with
  | Some names -> List.mem export names
  | None -> false

let test_no_export_is_swallowed () =
  let swallowed = ref [] and unguarded = ref [] in
  List.iter (fun (module_name, exports) ->
    List.iter (fun export ->
      if probeable export then
        match probe module_name export with
        | Wired ->
          if listed module_name export then
            unguarded := Printf.sprintf "%s %s" module_name export :: !unguarded
        | Refused _ ->
          swallowed := Printf.sprintf "%s %s" module_name export :: !swallowed
        (* A probe the CHECKER refuses says nothing about the Go emitter: the name needs a
           companion this probe does not know, or a capability an import cannot grant. *)
         | Rejected _ ->
           if not (listed module_name export) then ())
      exports)
    Type_system.tesl_module_exports;
  if !swallowed <> [] then
    failf
      "these stdlib exports reach the Go emitter's fallthrough without a checker guard; \
       wire them, or add them to go_backend_unavailable_exports:\n  %s"
      (String.concat "\n  " (List.sort compare !swallowed));
  if !unguarded <> [] then
    failf
      "these unavailable stdlib exports reached code generation instead of being rejected \
       by the checker:\n  %s"
      (String.concat "\n  " (List.sort compare !unguarded))

(* The fallthrough's own wording, pinned: it must name the MODULE and the EXPORT, so the
   reader knows which table to add a row to. *)
let test_the_fallthrough_names_what_it_refuses () =
  match probe "Tesl.Telemetry" "Span" with
  | Refused message ->
    check bool "names the module" true (contains message "`Tesl.Telemetry`");
    check bool "names the export" true (contains message "`Span`")
  | Wired -> fail "the probe compiled; pick a name that is still unwired"
  | Rejected message ->
    check bool "checker refusal names the module" true (contains message "`Tesl.Telemetry`");
    check bool "checker refusal names the export" true (contains message "`Span`")

let test_unavailable_export_is_rejected_by_checker () =
  match probe "Tesl.List" "List.nth" with
  | Rejected message ->
    check bool "names backend" true (contains message "Go backend");
    check bool "names module" true (contains message "`Tesl.List`");
    check bool "names export" true (contains message "`List.nth`")
  | Refused message ->
    failf "unavailable export reached the emitter instead of the checker: %s" message
  | Wired -> fail "unavailable export unexpectedly compiled"

let test_import_all_rejects_unavailable_use () =
  let source = {|module GoImportAllProbe exposing [dedupe]
import Tesl.Prelude exposing [Int, List]
import Tesl.List
fn dedupe(xs: List Int) -> List Int = List.dedupe xs
|} in
  match Compile.compile_go_source "<go-import-all-probe>" source with
  | Compile.GoSuccess _ -> fail "qualified unavailable export unexpectedly compiled"
  | Compile.GoFailure diagnostics ->
    let message = String.concat "; "
      (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics) in
    check bool "names backend" true (contains message "Go backend");
    check bool "names unavailable use" true (contains message "`List.dedupe`")

(* ── The `App` field inventory ─────────────────────────────────────────────────
   `App { … }` is the startup surface: `Desugar.lower_main_app` reads its fields and turns them
   into the imperative chain (start workers, start email workers, serve).  It reads them BY NAME
   out of an assoc list, so a field added to the App schema that nothing reads is silently
   dropped — the same class as the six `server` clauses the direct Go path once ignored.

   `Ast.server_form` and `Ast.EServe` are OCaml records, so their seams are compile-time ones
   (`emit_go.ml` rebuilds each record from its own fields).  The App schema is DATA — a row in
   `Validation_structural.config_block_schema` — so its seam is this test: adding a field fails
   here until someone writes down what happens to it. *)
let app_field_dispositions = [
  (* READ by `Desugar.lower_main_app`, and what each becomes. *)
  "database", "the database scope main's body runs inside";
  "queues", "one teslrt.StartWorkers per activated queue (plus its dead-letter pool)";
  "email", "one teslrt.StartEmailWorker per declared outbox";
  "telemetry", "one teslrt.InitTelemetry call from TelemetryConfig";
  "api", "the server teslrt.Serve is called with";
  "port", "ServeOptions.Port";
  "static", "ServeOptions.StaticDir";
  "mountPath", "ServeOptions.MountPath";
  (* INERT: an `sseChannel` declaration registers its own channel, and listing it in App
     starts nothing. Listed so the field is accounted for rather than forgotten. *)
  "sseChannels", "inert: the channel declaration is what registers it";
]

let test_app_fields_are_accounted_for () =
  let declared =
    List.map (fun (name, _, _) -> name) (Validation_structural.config_block_schema "App") in
  let accounted = List.map fst app_field_dispositions in
  let missing = List.filter (fun name -> not (List.mem name accounted)) declared in
  let stale = List.filter (fun name -> not (List.mem name declared)) accounted in
  (match missing with
   | [] -> ()
   | names ->
     failf "the App schema gained %s, which nothing in the startup chain accounts for. \
            Decide what it does — read it in Desugar.lower_main_app, or add it to \
            app_field_dispositions as deliberately inert."
       (String.concat ", " names));
  (match stale with
   | [] -> ()
   | names ->
     failf "app_field_dispositions names %s, which the App schema no longer declares"
       (String.concat ", " names))

let () =
  run "Go stdlib export seam" [
    "fallthrough", [
      test_case "no stdlib export is swallowed silently" `Slow test_no_export_is_swallowed;
      test_case "the refusal names the module and the export" `Quick
        test_the_fallthrough_names_what_it_refuses;
      test_case "unavailable export is rejected by checker" `Quick
        test_unavailable_export_is_rejected_by_checker;
      test_case "import-all unavailable use is rejected by checker" `Quick
        test_import_all_rejects_unavailable_use;
    ];
    "startup-surface", [
      test_case "every App field is accounted for" `Quick test_app_fields_are_accounted_for;
    ];
  ]
