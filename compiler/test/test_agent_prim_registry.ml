(** B4 — conformance of the single agent tool-param primitive registry
    (Validation_common: agent_prim / agent_prim_of_type_name /
     agent_prim_type_name / agent_prim_decode_tag / agent_prim_schema_prop /
     agent_prim_whitelist_english / agent_prim_of_type_expr / all_agent_prims).

    The set of parameter types an agent tool `fn` may take is restated at three
    consumer sites — the checker whitelist (checker.ml), the decode-tag emitter
    (emit_racket.ml agent_arg_type_tag), and the JSON-schema emitter
    (emit_racket.ml agent_arg_schema_prop).  Before B4 they were three
    hand-copied literals with MISMATCHED fallthroughs (reject / drop / string):
    adding a primitive to the checker without updating both emitters produced
    WRONG Racket (a param silently dropped from decode + mis-typed as a string in
    the schema) with NO compile error.

    This test binds all three sites to the ONE registry and to INDEPENDENT
    oracles written by hand here, so a wrong tag / schema on a future variant
    fails the build.  It also pins the derived diagnostic text so the checker
    message cannot drift from the registry.

    Pure OCaml, no alcotest / no Racket, so it runs in every gate:
      dune exec test/test_agent_prim_registry.exe *)

open Validation_common

let failures = ref 0
let check name ok = if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s\n" name end

let tname s = Ast.TName { name = s; loc = gen_loc }

(* independent oracle tables, written by hand — the registry must agree. *)
let tag_oracle = function
  | APString -> "string" | APInt | APPosixMillis -> "int"
  | APFloat -> "float" | APBool -> "bool"
  | APMoney -> "money"
  | APQuantity _ -> "float"
let schema_oracle = function
  | APInt -> {|{"type":"integer"}|}
  (* PosixMillis deliberately carries the epoch-millis semantics to the model
     (date-confusion class, issue #30 follow-up) — the description is part of
     the contract, so the oracle pins its exact bytes. *)
  | APPosixMillis ->
    {|{"type":"integer","description":"Unix epoch timestamp in MILLISECONDS since 1970-01-01T00:00:00Z (13 digits for current dates) - NOT seconds and NOT a human-readable date; never guess the calendar date from the digits"}|}
  | APFloat -> {|{"type":"number"}|}
  | APBool -> {|{"type":"boolean"}|}
  | APString -> {|{"type":"string"}|}
  (* Money carries the minor-units semantics — same anti-hallucination channel
     as PosixMillis; exact bytes pinned. *)
  | APMoney ->
    {|{"type":"object","properties":{"minorUnits":{"type":"integer"},"currency":{"type":"string"}},"required":["minorUnits","currency"],"description":"a monetary amount as integer MINOR UNITS (e.g. cents) plus an ISO-4217 currency code - never major units and never a float; $10.00 USD is {\"minorUnits\":1000,\"currency\":\"USD\"}"}|}
  | APQuantity _ ->
    (* parameterized; per-dimension checks below pin a concrete instance *)
    {|{"type":"number"}|}

let () =
  List.iter (fun p ->
    let nm = agent_prim_type_name p in
    (* 1. surface name round-trips through the sole membership test. *)
    check (nm ^ " round-trips") (agent_prim_of_type_name nm = Some p);
    (* also via a type_expr, the shape the consumers actually classify. *)
    check (nm ^ " round-trips via type_expr")
      (agent_prim_of_type_expr (tname nm) = Some p);
    (* 2. decode tag matches the independent oracle. *)
    check ("decode tag " ^ nm) (agent_prim_decode_tag p = tag_oracle p);
    (* 3. schema fragment matches the independent oracle. *)
    check ("schema " ^ nm) (agent_prim_schema_prop p = schema_oracle p);
    (* 4. decode-tag and schema AGREE on integer-ness.  TOP-LEVEL type only:
       Money's schema is an object whose minorUnits PROPERTY is an integer, so
       a substring test would misfire — the prefix is the schema's own type. *)
    let tag_is_int = agent_prim_decode_tag p = "int" in
    let schema_is_int =
      let s = agent_prim_schema_prop p in
      let prefix = {|{"type":"integer"|} in
      String.length s >= String.length prefix
      && String.sub s 0 (String.length prefix) = prefix
    in
    check ("tag/schema agree on integer-ness " ^ nm) (tag_is_int = schema_is_int);
    (* 5. the emitter derives from the SAME registry — tri-site coverage. *)
    check ("emit tag " ^ nm)
      (Emit_racket.agent_arg_type_tag (tname nm) = Some (agent_prim_decode_tag p));
    check ("emit schema " ^ nm)
      (Emit_racket.agent_arg_schema_prop (tname nm) = agent_prim_schema_prop p);
    (* positive: no primitive is silently dropped or string-defaulted. *)
    check ("nonempty tag " ^ nm) (String.length (agent_prim_decode_tag p) > 0);
    let sch = agent_prim_schema_prop p in
    check ("schema is a type-object " ^ nm)
      (String.length sch > 0 && sch.[0] = '{'))
    all_agent_prims;

  (* 6. the derived diagnostic text stays in lockstep with the registry. *)
  check "english whitelist"
    (agent_prim_whitelist_english = "String, Int, Float, Bool, PosixMillis, or Money");

  (* 6b. dimensioned quantities (First-Class Units): parameterized prims, not
     in all_agent_prims — pin one concrete instance end-to-end.  Both the
     alias ("Speed") and the canonical §Q name classify; tag is float; the
     schema is a number whose description names the SI unit.  Aliases are
     ACTIVE-gated (import-scoped) — activate them as the checker would for a
     module importing Tesl.Units, and pin the gate itself (inactive → not a
     prim). *)
  check "inactive alias is NOT a prim"
    (Units_catalog.set_active_aliases [];
     agent_prim_of_type_name "Speed" = None);
  Units_catalog.set_active_aliases (List.map fst Units_catalog.aliases);
  let speed_canon =
    Units_catalog.dim_name
      (match Units_catalog.dim_of_alias "Speed" with
       | Some d -> d | None -> Units_catalog.dimensionless)
  in
  check "Speed classifies as a quantity prim"
    (agent_prim_of_type_name "Speed" = Some (APQuantity speed_canon));
  check "canonical quantity name classifies too"
    (agent_prim_of_type_name speed_canon = Some (APQuantity speed_canon));
  check "quantity decode tag is float"
    (agent_prim_decode_tag (APQuantity speed_canon) = "float");
  (let s = agent_prim_schema_prop (APQuantity speed_canon) in
   let contains needle =
     let n = String.length needle and l = String.length s in
     let rec go i = i + n <= l && (String.sub s i n = needle || go (i + 1)) in
     go 0
   in
   check "quantity schema is a number" (contains {|"type":"number"|});
   check "quantity schema names the SI unit" (contains "m/s"));
  check "quantity emit tag is float"
    (Emit_racket.agent_arg_type_tag (tname "Speed") = Some "float");

  (* 7. all_agent_prims has no duplicate type names. *)
  let names = List.map agent_prim_type_name all_agent_prims in
  let uniq = List.sort_uniq compare names in
  check "all_agent_prims has no duplicate names"
    (List.length names = List.length uniq);

  (* 8. non-primitive names are rejected everywhere: registry AND emitter. *)
  List.iter (fun n ->
    check (Printf.sprintf "%S not a prim (registry)" n)
      (agent_prim_of_type_name n = None);
    check (Printf.sprintf "%S not a prim (emit tag)" n)
      (Emit_racket.agent_arg_type_tag (tname n) = None))
    [ "List"; "Maybe"; "UserId"; "string"; ""; "Char" ];

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
