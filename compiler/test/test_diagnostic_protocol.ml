open Alcotest
let contains needle text = Compile.string_contains text needle
let diagnostic ?(related=[]) code =
 let loc = {Location.file="/project/schema/notes/v-current.tesl";
   start={line=2;col=4};stop={line=2;col=7}} in
 let error = {Migration_sparse.code;loc;message="a typed decision";related} in
 List.hd (Migration_declaration.diagnostics_of_errors [error])
let action_fields code class_ confirmation =
 let json = Compile.diag_to_json_v2 (diagnostic code) in
 check bool code true (contains ("\"actionClass\":" ^ class_) json);
 check bool "confirmation is explicit" true
  (contains ("\"needsConfirmation\":" ^ string_of_bool confirmation) json);
 check bool "no unguarded fix-all" true (contains "\"fixAllEligible\":false" json);
 check bool "no invented command" true (contains "\"command\":null" json)
let classes () =
 List.iter (fun code -> action_fields code "\"mechanical\"" false)
  ["MIG001";"MIG010";"MIG012";"MIG015";"MIG024";"MIG027"];
 List.iter (fun code -> action_fields code "\"decision\"" true)
  ["MIG002";"MIG003";"MIG013";"MIG016";"MIG020";"MIG026";"MIG030"];
 List.iter (fun code -> action_fields code "\"suggested\"" false)
  ["MIG004";"MIG008";"MIG009";"MIG017";"MIG018";"MIG019";"MIG021";"MIG022";"MIG023";"MIG031";"MIG032"];
 List.iter (fun code -> action_fields code "null" false) ["MIG014";"MIG025";"MIG029"]
let legacy () =
 let d = diagnostic "MIG003" in
 let expected = {|{"version":1,"diagnostics":[{"file":"/project/schema/notes/v-current.tesl","start":{"line":2,"col":4},"end":{"line":2,"col":7},"severity":"error","code":"MIG003","message":"a typed decision","fix":null,"source":"migration"}]}|} in
 check string "legacy protocol stays byte-identical" expected (Compile.diagnostics_to_json [d]);
 check bool "new endpoint explicitly reports protocol 2" true
  (contains "\"version\":2" (Compile.diagnostics_to_json_v2 [d]))
let related () =
 let loc = {Location.file="/project/å\"/old.tesl";start={line=8;col=3};stop={line=9;col=5}} in
 let d = diagnostic ~related:[loc,"old field\nquoted \"name\""] "MIG003" in
 let legacy = Compile.diag_to_json d and rich = Compile.diag_to_json_v2 d in
 check bool "legacy retains its textual related location" true (contains "old.tesl:9:4" legacy);
 check bool "rich primary message has no copied location text" true (contains "\"message\":\"a typed decision\",\"fix\":" rich);
 check bool "related source is independently addressable and escaped" true
  (contains {|"relatedInformation":[{"file":"/project/å\"/old.tesl","start":{"line":8,"col":3},"end":{"line":9,"col":5},"message":"old field\nquoted \"name\""}]|} rich);
 check bool "manual deep link" true (contains "https://github.com/mtonnberg/tesl/blob/main/manual/best-practices.md#database-access" rich)
let ordinary () =
 let source = "module App exposing []\nimport Tesl.Prelude exposing [Int]\nfn broken() -> Int = \"wrong\"\n" in
 let diagnostics = Compile.check_source "/project/app.tesl" source in
 check bool "real type failure" true (List.exists (fun (d : Compile.diagnostic) -> d.code="T001") diagnostics);
 let json = Compile.diagnostics_to_json_v2 diagnostics in
 check bool "unclassified ordinary fixes do not gain an action" true (contains "\"actionClass\":null" json);
 check bool "empty related locations remain an array" true (contains "\"relatedInformation\":[]" json)
let import_fix () =
 List.iter (fun count ->
  let source = "module App exposing []\nimport NotesSchema.V1\n" ^
    String.concat "\n" (List.init count (fun i -> Printf.sprintf "fn f%d() -> String = NotesSchema.V1.message" i)) ^ "\n" in
  let m = match Parser.parse_module "/project/app.tesl" source with Ok m -> m | Err e -> fail e.msg in
  let d = match List.find_opt (fun (d : Compile.diagnostic) -> d.code="MIG015") (Frontend_check.validation_diags_of source m) with
   | Some d -> d | None -> fail "historical import diagnostic missing" in
  check bool "current import correction exists" true (d.fix<>None);
  let json = Compile.diag_to_json_v2 d in
  check bool "bounded verified corrections carry separate fix-all eligibility" true
   (contains ("\"fixAllEligible\":" ^ string_of_bool (count<8)) json)) [0;1;7;8]
let validation_hint () =
 let error = {Validation_common.loc=Location.dummy_loc "/project/app.tesl";code="MIG015";
   message="historical import";hint="use the current schema";topic=Error_codes.TGeneric} in
 let d = Frontend_check.diag_of_validation_error error in
 check bool "existing hint survives rich rendering" true
  (contains "historical import\\nHint: use the current schema" (Compile.diag_to_json_v2 d))
let () = run "Diagnostic protocol 2" ["structured guidance",List.map (fun (name,f) -> test_case name `Quick f)
 ["producer action classes and conservative fix-all",classes;"version-1 compatibility",legacy;
  "related spans and documentation links",related;"ordinary diagnostics stay unclassified",ordinary;
  "verified bounded import corrections",import_fix;"validation hints remain visible",validation_hint]]
