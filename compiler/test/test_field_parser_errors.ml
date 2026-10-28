open Alcotest
open Ast

let header = "module Schema.Notes.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\n"
let source kind last = header ^ kind ^ " { id: String, " ^ last ^ " }\n"
let kinds = ["record Note"; "entity Note table \"notes\" primaryKey id"]
let bad = ["title"; "title:"; "title: (String"; "title: String :::";
 "title: String ::: ("; "title: String ::: Valid title &&";
 "title: String ::: (Valid title"; "title: String @db(text";
 "title: String @db("; "title: String @db(text) @db(text)";
 "title: String @unknown(x)"]
let rejects text = match Parser.parse_module "/tmp/field-parser.tesl" text with
 | Err _ -> () | Ok _ -> fail ("malformed field silently accepted: " ^ text)
let malformed_fields () =
 List.iter (fun kind -> List.iter (fun tail ->
  rejects (source kind tail);
  rejects (source kind (tail ^ "\n# closing field after comment\n"))) bad) kinds
let malformed_indexes () =
 List.iter (fun tail -> rejects (source "entity Note table \"notes\" primaryKey id" tail))
  ["index [id"; "index [id] as"; "unique index [id"; "unique index [id] as"]
let malformed_columns () =
 List.iter (fun tail -> rejects (source "entity Note table \"notes\" primaryKey id" tail))
  ["title: String @column(\"title__v2\""; "title: String @column(";
   "title: String @column(\"title__v2\") @column(\"title__v2\")"]
let diagnostic_rejects_proof_erasure () =
 List.iter (fun kind ->
  let result=Compile.agent_context_result_source "/tmp/field-parser.tesl" (source kind "title: String :::") in
  check bool "public diagnostics reject malformed proof instead of publishing plain field" true
   (List.exists (fun (d:Compile.diagnostic) -> d.severity="error") result.diagnostics)) kinds
let complete_fields () =
 List.iter (fun kind ->
  let text=source kind "title: String ::: (Valid title && Other title) @db(text)" in
  match Parser.parse_module "/tmp/field-parser.tesl" text with
  | Err e -> fail e.msg
  | Ok m ->
    let fields=List.find_map (function DRecord r -> Some r.fields | DEntity e -> Some e.fields | _ -> None) m.decls |> Option.get in
    check (list string) "complete field sequence" ["id";"title"] (List.map (fun (f:field_def) -> f.name) fields);
    let title=List.nth fields 1 in
    check bool "complete proof preserved" true (match title.proof_ann with Some (PredAnd _) -> true | _ -> false);
    check (option string) "storage annotation preserved" (Some "text") title.db_type) kinds
let ()=run "Complete field parsing" ["boundary",[
 test_case "malformed trailing fields cannot truncate schema" `Quick malformed_fields;
 test_case "malformed indexes cannot disappear" `Quick malformed_indexes;
 test_case "malformed physical annotations cannot disappear" `Quick malformed_columns;
 test_case "public diagnostics cannot erase broken proof" `Quick diagnostic_rejects_proof_erasure;
 test_case "complete proofs and fields retain their AST" `Quick complete_fields]]
