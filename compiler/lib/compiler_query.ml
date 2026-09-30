(** Shared implementation of one-shot and retained read-only source queries.
    Payloads keep their existing version-1 schemas and exit-status semantics. *)
type response = { json : string; exit_code : int }

let position_flags = ["--definition-json"; "--occurrences-json"; "--type-at-json";
  "--field-at-json"; "--config-context-json"; "--completions-json";
  "--signature-help-json"; "--selection-range-json"; "--type-definition-json"]
let file_flags = ["--check-json"; "--agent-context-json"; "agent-context";
  "--local-bindings-json"; "--semantic-json"]
let workspace_flags = ["--workspace-definition-json"; "--workspace-references-json"; "--workspace-rename-json"]
let supports flag = List.mem flag (position_flags @ file_flags @ workspace_flags)
let valid_args flag position =
  if flag = "--workspace-rename-json" then List.length position = 4
  else if List.mem flag (position_flags @ workspace_flags) then List.length position = 2
  else List.mem flag file_flags && position = []

let run ~filename ~logical_path flag position =
  if not (valid_args flag position) then invalid_arg "invalid source query arguments";
  if List.mem flag workspace_flags then
    { json = Workspace_index.run ~filename flag position; exit_code = 0 }
  else
  let source = In_channel.with_open_bin filename In_channel.input_all in
  let line, col = match position with
    | [line; col] ->
      let line, col = int_of_string line, int_of_string col in
      if line < 0 || col < 0 then invalid_arg "negative query position";
      line, col
    | _ -> 0, 0 in
  let path = logical_path in
  let ok json = { json; exit_code = 0 } in
  match flag with
  | "--check-json" ->
    let diags = Compile.check_source path source in
    let diags = if List.exists (fun (d : Compile.diagnostic) ->
      d.source = "parser" || d.source = "lexer") diags then diags
      else diags @ Linter.lint_file ~logical_path:path filename in
    { json = Compile.diagnostics_to_json diags;
      exit_code = if List.exists (fun (d : Compile.diagnostic) -> d.severity = "error") diags then 1 else 0 }
  | "--agent-context-json" | "agent-context" ->
    let extra_diags = Linter.lint_file ~logical_path:path filename in
    let result = Compile.agent_context_result_source ~extra_diags path source in
    { json = result.json; exit_code = if result.ok then 0 else 1 }
  | "--local-bindings-json" -> ok (Compile.local_bindings_to_json (Compile.local_bindings_source path source))
  | "--semantic-json" ->
    (match Compile.semantic_json_source path source with
     | Some json -> ok json
     | None -> failwith ("could not parse " ^ path))
  | "--definition-json" -> ok (Compile.definition_response_to_json (Compile.definition_source path source line col))
  | "--occurrences-json" -> ok (Compile.occurrences_response_to_json (Compile.occurrences_source path source line col))
  | "--type-at-json" -> ok (Compile.type_at_response_to_json (Compile.type_at_source path source line col))
  | "--field-at-json" -> ok (Compile.field_at_response_to_json (Compile.field_at_source path source line col))
  | "--config-context-json" -> ok (Compile.config_context_response_to_json (Compile.config_context_source path source line col))
  | "--completions-json" -> ok (Compile.completions_response_to_json (Compile.completions_source path source line col))
  | "--signature-help-json" -> ok (Compile.signature_help_response_to_json (Compile.signature_help_source path source line col))
  | "--selection-range-json" -> ok (Compile.selection_ranges_response_to_json (Compile.selection_range_source path source line col))
  | "--type-definition-json" -> ok (Compile.type_definition_response_to_json (Compile.type_definition_source path source line col))
  | _ -> invalid_arg "unsupported source query"
