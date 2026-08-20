(** `asTool` JSON-schema derivation — the whole object, and the rejection.

    `compiler/test/test_agent_prim_registry.ml` already binds the PER-TYPE schema
    fragment (`agent_prim_schema_prop`) to an independent oracle across all three
    consumer sites. Two things it does not cover, and neither was covered
    anywhere:

    1. **`agent_tool_schema_json` — the assembled object.** A model receives this
       string verbatim. If `properties` and `required` disagree with the function's
       actual parameter list, or with the DECODE tag list emitted beside it, the
       model is told to send arguments the decoder will not accept. That is a
       silent runtime failure at the LLM boundary, not a compile error.

     2. **The whitelist rejection.** The Go emitter rejects a non-primitive
       parameter "can only reach here if the checker let it through, which is now
       impossible" and keeps a `{"type":"string"}` fallback for that unreachable
       case. Nothing tested that claim — so if the checker ever loosened, a
       non-primitive would be silently described to the model as a string.

    The rejection also carries a security property worth pinning explicitly: a
    `secret`-typed parameter cannot appear in a tool schema. Tool arguments are
    decoded from model-supplied JSON, so a secret parameter would mean an LLM
    choosing the value of something the language guarantees cannot become a
    String — and the schema would have published its name and type to the model.
    The guarantee here is by construction (only 6 primitives are admitted), which
    is stronger than a redaction rule, and this test is what keeps it that way.

     Pure OCaml + the compiler library:
      dune exec test/test_astool_schema.exe *)

let failures = ref 0
let check name ok =
  if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s\n" name end

let checkf name ok msg =
  if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s: %s\n" name msg end

let contains hay needle =
  let nl = String.length needle and hl = String.length hay in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* ── The rejection probes drive the real binary ────────────────────────────
   The whitelist lives in the checker, so asserting it needs a compile, not a
   library call. Same subprocess helper shape as test_fail_open_tightening.ml. *)
let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    let dir = Filename.dirname Sys.argv.(0) in
    let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let c2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl"

let check_src content =
  let dir = Filename.temp_dir "tesl-astool" "" in
  let path = Filename.concat dir "Probe.tesl" in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () ->
      let cmd = Printf.sprintf "%s --check %s 2>&1"
                  (Filename.quote compiler) (Filename.quote path) in
      let ic = Unix.open_process_in cmd in
      let out = In_channel.input_all ic in
      ignore (Unix.close_process_in ic);
      out)

let preamble = {|module Probe exposing [thing]

import Tesl.Prelude exposing [Int, String, List]
import Tesl.Agent exposing [aiProvider, Agent, Tool, asTool, mockToolProvider]

capability bot implies aiProvider
|}

(* `mockToolProvider []` rather than a real provider: this test is about the
   SCHEMA the checker will or will not accept, and a live provider would drag in
   an env read and its capability. *)
let agent_block = {|
agent Assistant requires [bot] = Agent {
  provider: mockToolProvider []
  systemPrompt: "s"
  tools: [asTool thing]
  maxTokens: 64
}
|}

let g = Validation_common.gen_loc
let tname s = Ast.TName { name = s; loc = g }
let param name ty : Ast.binding =
  { name; type_expr = tname ty; proof_ann = None; loc = g }

(* ── 1. The assembled schema object ───────────────────────────────────────── *)

let () =
  print_endline "# asTool schema derivation";

  (* Order is preserved, every parameter appears in BOTH properties and required,
     and the primitive fragments come from the shared registry. *)
  let schema =
     Emit_go.agent_tool_schema_json
      [ param "city" "String"; param "days" "Int"; param "precise" "Bool" ]
  in
  check "object shape" (contains schema {|"type":"object"|});
  check "properties in declaration order"
    (contains schema
       {|"properties":{"city":{"type":"string"},"days":{"type":"integer"},"precise":{"type":"boolean"}}|});
  check "required lists every parameter, in order"
    (contains schema {|"required":["city","days","precise"]|});

  (* A tool with no parameters must still be a well-formed object — a model that
     receives `"properties":` with nothing after it cannot parse the schema. *)
   let empty = Emit_go.agent_tool_schema_json [] in
  check "zero-parameter tool is still valid JSON-shaped"
    (contains empty {|"properties":{}|} && contains empty {|"required":[]|});

  (* ── 2. Schema keys and DECODE tags must agree ───────────────────────────
     This is the bug the registry's own header describes: "a param silently
     dropped from decode + mis-typed as a string in the schema with NO compile
     error". The schema is what the model is told; the tag list is what the
     runtime will accept. A parameter present in one and absent from the other is
     a live mismatch at the LLM boundary. *)
  let params =
    List.map (fun (n, t) -> param n t)
      [ ("s", "String"); ("i", "Int"); ("f", "Float");
        ("b", "Bool"); ("t", "PosixMillis"); ("m", "Money") ]
  in
   let full = Emit_go.agent_tool_schema_json params in
  List.iter (fun (p : Ast.binding) ->
    check (Printf.sprintf "schema names parameter %s" p.name)
      (contains full (Printf.sprintf "%S:" p.name));
    checkf (Printf.sprintf "decode tag exists for parameter %s" p.name)
       (Emit_go.agent_arg_type_tag p.type_expr <> None)
      "present in the schema but dropped from the decode list")
    params;

  (* Every admitted primitive must produce a schema fragment AND a tag — asserted
     over the registry itself, so a future variant cannot be added to the
     whitelist while missing one of the two emitters. *)
  List.iter (fun p ->
    let nm = Validation_common.agent_prim_type_name p in
    check (Printf.sprintf "%s: schema fragment is non-empty" nm)
       (String.length (Emit_go.agent_arg_schema_prop (tname nm)) > 2);
    check (Printf.sprintf "%s: decode tag present" nm)
       (Emit_go.agent_arg_type_tag (tname nm) <> None))
    Validation_common.all_agent_prims;

  (* ── 3. The whitelist rejection ─────────────────────────────────────────
      The Go emitter keeps a `{"type":"string"}` fallback for the
     "unreachable post-checker" case. These probes are what make it unreachable.

     The SECRET case is the security-relevant one: tool arguments are decoded
     from model-supplied JSON, so a secret-typed parameter would mean an LLM
     choosing the value of something the language guarantees cannot become a
     String — and the schema would have published its name to the model. The
     guarantee is by construction (only the 6 primitives are admitted), which is
     stronger than any redaction rule. *)
  print_endline "";
  print_endline "# whitelist rejection (the schema cannot describe a non-primitive)";

  let whitelist_msg = "must be String, Int, Float, Bool, PosixMillis, or Money" in

  let reject label decls =
    let out = check_src (preamble ^ decls ^ agent_block) in
    checkf label (contains out whitelist_msg)
      (Printf.sprintf "expected the tool-parameter whitelist error, got:\n%s" out)
  in

  reject "a `secret` parameter is rejected"
    "\nsecret ApiKey = String\nfn thing(key: ApiKey, n: Int) -> String = \"x\"\n";
  reject "a user newtype parameter is rejected"
    "\ntype UserId = String\nfn thing(u: UserId, n: Int) -> String = \"x\"\n";
  reject "a record parameter is rejected"
    "\nrecord Box { n: Int }\nfn thing(b: Box) -> String = \"x\"\n";
  reject "a List parameter is rejected"
    "\nfn thing(xs: List Int) -> String = \"x\"\n";

  (* Positive control: the tightening is scoped to non-primitives. Without this,
     a future change could reject everything and the four probes above would
     still pass. *)
  let ok_out =
    check_src (preamble
               ^ "\nfn thing(city: String, days: Int) -> String = city\n"
               ^ agent_block) in
  checkf "an all-primitive tool function still compiles"
    (not (contains ok_out "error"))
    (Printf.sprintf "expected a clean check, got:\n%s" ok_out);

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
