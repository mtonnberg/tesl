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
let schema_oracle = function
  | APInt | APPosixMillis -> {|{"type":"integer"}|}
  | APFloat -> {|{"type":"number"}|}
  | APBool -> {|{"type":"boolean"}|}
  | APString -> {|{"type":"string"}|}

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
    (* 4. decode-tag and schema AGREE on integer-ness. *)
    let tag_is_int = agent_prim_decode_tag p = "int" in
    let schema_is_int =
      let s = agent_prim_schema_prop p in
      let needle = "integer" in
      let rec contains i =
        i + String.length needle <= String.length s
        && (String.sub s i (String.length needle) = needle || contains (i + 1))
      in contains 0
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

  (* 6. the derived diagnostic text is byte-identical to the pre-B4 message. *)
  check "english whitelist"
    (agent_prim_whitelist_english = "String, Int, Float, Bool, or PosixMillis");

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
