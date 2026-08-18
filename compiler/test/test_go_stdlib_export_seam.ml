(** Durable seam test: no stdlib export reaches the Go emitter's fallthrough by accident.

    Each stdlib module's export list is matched name by name in [Emit_go.compile_module], and
    every match ends in

      {[ | other -> unsupported loc "Go backend does not support `Tesl.M` export `%s` yet" other ]}

    which is the right shape — an unwired name must be REFUSED, not emitted as something the
    backend guessed at — but it is silent in the direction that matters to us: adding an
    export to {!Type_system.tesl_module_exports} routes it straight to that arm, so a NEW
    stdlib feature is refused at the user's compile time with no signal at ours. The
    fallthrough would quietly eat every future addition.

    This closes that direction. Every (module, export) pair in the checker's own allowlist is
    compiled through the Go emitter, and the answer is compared against {!expected_unsupported}
    below. Both directions fail:

      - a pair that is REFUSED but not listed → a new export was swallowed; wire it, or add it
        here with a reason;
      - a pair that is LISTED but now compiles → the list has rotted; delete the row.

    So the fallthroughs stay as the fail-closed arm they are, and the list of what they
    actually catch is a fact this suite keeps true rather than a comment that drifts.

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
         d.source = "go-emitter" && contains d.message "does not support"
         && contains d.message "export") diagnostics
    then Refused message
    else Rejected message

(* Every (module, export) the Go emitter refuses TODAY, with the reason it is not wired.
   Adding a row is a decision to leave a stdlib name unavailable on this backend; removing one
   is what wiring it looks like from here. *)
let expected_unsupported = [
  (* The higher-order Dict/Set/List leaves: each takes a CALLBACK, and the emitter inlines a
     callback rather than passing a Go func value, so each needs its own emission rather than
     a table row. *)
  "Tesl.Dict", ["Dict.map"; "Dict.mapWithKey"; "Dict.filter"; "Dict.filterWithKey";
                "Dict.foldl"; "Dict.foldr"; "Dict.insertWith"; "Dict.unionWith";
                "Dict.update"; "Dict.difference"; "Dict.intersection"];
  "Tesl.Set", ["Set.map"; "Set.filter"; "Set.foldl"; "Set.all"; "Set.any"; "Set.partition"];
  "Tesl.List", ["List.zipWith"; "List.unzip"; "List.partition"; "List.groupBy";
                "List.findIndex"; "List.dedupe"; "List.intersperse"; "List.intercalate";
                "List.nth"];
  (* `Tesl.ListPrim` is the lifted list module's own primitive layer: a program imports
     `Tesl.List`, and the prim names exist for that module's implementation. *)
  "Tesl.ListPrim", ["ListPrim.head"; "ListPrim.tail"; "ListPrim.append"];
  (* Float↔Int↔String conversions and the digit/sign predicates. *)
  "Tesl.Int", ["Int.toFloat"; "Int.fromFloat"; "Int.digits"; "Int.isZero"; "Int.isPositive";
               "Int.isNegative"];
  "Tesl.String", ["String.toFloat"; "String.fromFloat"; "String.words"; "String.lines";
                  "String.trimLeft"; "String.trimRight"];
  (* The codecs for types whose wire shape is not a scalar. *)
  "Tesl.Json", ["dictCodec"; "setCodec"; "moneyCodec"; "int32Codec"];
  "Tesl.UUID", ["uuidV4Codec"; "uuidV7Codec"];
  (* Outbound email: the runtime has an outbox for tests, not a sender. *)
  "Tesl.Email", ["Email.send"; "startEmailWorker"];
  (* A `cache` DECLARATION is wired; the capability name itself is not a value here. *)
  "Tesl.Cache", ["cache"];
  (* The api-test SSE handle. *)
  "Tesl.ApiTest", ["SseStream"];
  (* `HostClass`'s constructors are reachable through `HostClass(..)`, which is how the
     surface writes them; a BARE constructor import is not wired. *)
  "Tesl.Net", ["Loopback"; "PrivateIp"; "LinkLocal"; "Cgnat"; "Multicast"; "Unspecified";
               "PublicIp"; "DomainName"; "InvalidHost"];
]

let listed module_name export =
  match List.assoc_opt module_name expected_unsupported with
  | Some names -> List.mem export names
  | None -> false

let test_no_export_is_swallowed () =
  let swallowed = ref [] and rotted = ref [] in
  List.iter (fun (module_name, exports) ->
    List.iter (fun export ->
      if probeable export then
        match probe module_name export with
        | Wired ->
          if listed module_name export then
            rotted := Printf.sprintf "%s %s" module_name export :: !rotted
        | Refused _ ->
          if not (listed module_name export) then
            swallowed := Printf.sprintf "%s %s" module_name export :: !swallowed
        (* A probe the CHECKER refuses says nothing about the Go emitter: the name needs a
           companion this probe does not know, or a capability an import cannot grant. *)
        | Rejected _ -> ())
      exports)
    Type_system.tesl_module_exports;
  if !swallowed <> [] then
    failf
      "these stdlib exports reach the Go emitter's fallthrough and are NOT in \
       expected_unsupported — wire them, or add them there with a reason:\n  %s"
      (String.concat "\n  " (List.sort compare !swallowed));
  if !rotted <> [] then
    failf
      "these stdlib exports are listed in expected_unsupported but now COMPILE — delete \
       those rows:\n  %s"
      (String.concat "\n  " (List.sort compare !rotted))

(* The fallthrough's own wording, pinned: it must name the MODULE and the EXPORT, so the
   reader knows which table to add a row to. *)
let test_the_fallthrough_names_what_it_refuses () =
  match probe "Tesl.Telemetry" "Span" with
  | Refused message ->
    check bool "names the module" true (contains message "`Tesl.Telemetry`");
    check bool "names the export" true (contains message "`Span`")
  | Wired -> fail "the probe compiled; pick a name that is still unwired"
  | Rejected message -> failf "the checker refused the probe: %s" message

let () =
  run "Go stdlib export seam" [
    "fallthrough", [
      test_case "no stdlib export is swallowed silently" `Slow test_no_export_is_swallowed;
      test_case "the refusal names the module and the export" `Quick
        test_the_fallthrough_names_what_it_refuses;
    ];
  ]
