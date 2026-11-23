(** Tesl.String reversible encodings: base64url and hex.

    `String.toBase64Url` / `String.toHex` mint `IsBase64Url` / `IsHex` on their
    result, `String.parseBase64Url` / `String.parseHex` mint the same fact on a
    validated `Something`, and `String.fromBase64Url` / `String.fromHex` accept
    ONLY a value carrying the fact — which is what lets the decoders be total.

    These tests pin the proof side at the checker: the decoders refuse an
    unproven value, the two facts do not stand in for one another, user code
    cannot mint either fact, and a plain `import Tesl.String` does not expose
    them.  The encoding behaviour itself runs end-to-end in
    tests/string-encoding-tests.tesl and in the Go runtime unit tests. *)

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

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-string-encoding" "" in
  let path = Filename.concat dir "probe.tesl" in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got (exit %d):\n%s" code out)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but it compiled clean" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let all_names =
  "IsBase64Url, IsHex, String.toBase64Url, String.parseBase64Url, String.fromBase64Url, \
   String.toHex, String.parseHex, String.fromHex"

let prog ?(string_import = "import Tesl.String exposing [" ^ all_names ^ "]") body =
  Printf.sprintf
    "module Probe exposing [f]\n\
     import Tesl.Prelude exposing [String]\n\
     import Tesl.Maybe exposing [Something, Nothing]\n\
     %s\n\
     %s\n"
    string_import body

(* ── Accepted shapes ─────────────────────────────────────────────────────── *)

let t_encoder_result_decodes () =
  should_pass (prog
    "fn f(raw: String) -> String =\n\
    \  let b = String.toBase64Url raw\n\
    \  let h = String.toHex raw\n\
    \  String.fromBase64Url b ++ String.fromHex h\n")

let t_parsed_value_decodes () =
  should_pass (prog
    "fn f(raw: String) -> String =\n\
    \  case String.parseBase64Url raw of\n\
    \    Something b -> String.fromBase64Url b\n\
    \    Nothing ->\n\
    \      case String.parseHex raw of\n\
    \        Something h -> String.fromHex h\n\
    \        Nothing -> raw\n")

let t_fact_propagates_through_signatures () =
  should_pass (prog
    "fn encode(raw: String) -> String ? IsBase64Url = String.toBase64Url raw\n\
     fn decode(c: String ::: IsBase64Url c) -> String = String.fromBase64Url c\n\
     fn f(raw: String) -> String =\n\
    \  let c = encode raw\n\
    \  decode c\n")

(* ── Refused shapes ──────────────────────────────────────────────────────── *)

let t_unproven_base64_decode_refused () =
  should_fail "does not statically satisfy declared proof `IsBase64Url raw`"
    (prog "fn f(raw: String) -> String = String.fromBase64Url raw\n")

let t_unproven_hex_decode_refused () =
  should_fail "does not statically satisfy declared proof `IsHex raw`"
    (prog "fn f(raw: String) -> String = String.fromHex raw\n")

let t_decoded_value_is_not_still_encoded () =
  should_fail "does not statically satisfy declared proof `IsBase64Url d`"
    (prog
      "fn f(raw: String) -> String =\n\
      \  let e = String.toBase64Url raw\n\
      \  let d = String.fromBase64Url e\n\
      \  String.fromBase64Url d\n")

let t_hex_fact_does_not_unlock_base64 () =
  should_fail "does not statically satisfy declared proof `IsBase64Url h`"
    (prog
      "fn f(raw: String) -> String =\n\
      \  let h = String.toHex raw\n\
      \  String.fromBase64Url h\n")

let t_base64_fact_does_not_unlock_hex () =
  should_fail "does not statically satisfy declared proof `IsHex b`"
    (prog
      "fn f(raw: String) -> String =\n\
      \  let b = String.toBase64Url raw\n\
      \  String.fromHex b\n")

let t_fn_cannot_forge_the_fact () =
  should_fail "claiming entity proof `IsBase64Url raw`"
    (prog
      "fn forge(raw: String) -> String ? IsBase64Url = raw\n\
       fn f(raw: String) -> String = raw\n")

let t_establish_cannot_mint_a_stdlib_fact () =
  should_fail "fact ownership violation"
    (prog
      "establish forge(raw: String) -> Maybe (s: String ::: IsHex s) =\n\
      \  Something (raw ::: IsHex raw)\n\
       fn f(raw: String) -> String = raw\n")

let t_check_cannot_mint_a_stdlib_fact () =
  should_fail "fact ownership violation"
    (prog
      "check forge(raw: String) -> s: String ::: IsBase64Url s =\n\
      \  let s = raw\n\
      \  ok s ::: IsBase64Url s\n\
       fn f(raw: String) -> String = raw\n")

let t_plain_import_does_not_expose_the_facts () =
  should_fail "proof predicate `IsBase64Url` is not in scope"
    (prog ~string_import:"import Tesl.String"
      "fn f(raw: String ::: IsBase64Url raw) -> String = String.fromBase64Url raw\n")

(* ── Surface tables ──────────────────────────────────────────────────────── *)

let t_every_export_has_a_scheme () =
  List.iter (fun name ->
    if not (List.mem_assoc name Type_system.stdlib_env) then
      failf "%s has no stdlib_env scheme, so it would type-check as anything" name)
    [ "String.toBase64Url"; "String.parseBase64Url"; "String.fromBase64Url";
      "String.toHex"; "String.parseHex"; "String.fromHex" ]

let () =
  run "string_encoding_surface" [
    "accepted", [
      test_case "an encoder's result decodes" `Quick t_encoder_result_decodes;
      test_case "a parsed value decodes in the Something branch" `Quick t_parsed_value_decodes;
      test_case "the fact propagates through ? and ::: signatures" `Quick
        t_fact_propagates_through_signatures;
    ];
    "refused", [
      test_case "fromBase64Url refuses an unproven String" `Quick t_unproven_base64_decode_refused;
      test_case "fromHex refuses an unproven String" `Quick t_unproven_hex_decode_refused;
      test_case "a decoded value does not keep the fact" `Quick t_decoded_value_is_not_still_encoded;
      test_case "IsHex does not unlock fromBase64Url" `Quick t_hex_fact_does_not_unlock_base64;
      test_case "IsBase64Url does not unlock fromHex" `Quick t_base64_fact_does_not_unlock_hex;
      test_case "a fn cannot forge IsBase64Url" `Quick t_fn_cannot_forge_the_fact;
      test_case "an establish cannot mint IsHex" `Quick t_establish_cannot_mint_a_stdlib_fact;
      test_case "a check cannot mint IsBase64Url" `Quick t_check_cannot_mint_a_stdlib_fact;
      test_case "a plain import does not expose the facts" `Quick
        t_plain_import_does_not_expose_the_facts;
    ];
    "surface-tables", [
      test_case "every encoding export has a stdlib_env scheme" `Quick t_every_export_has_a_scheme;
    ];
  ]
