open Ast
open Ir

(* OpenAPI 3.1 is intentional: it gives us JSON Schema's `type: null` and
   `const`, which represent Maybe and ADT tags without vendor conventions. *)

let js = Ir.json_string
let field = Ir.json_field
let obj = Ir.json_object
let array xs = Ir.json_array xs
let null = Ir.json_null

let rec schema_of_ir_type = function
  | Ir.IRString -> obj [field "type" (js "string")]
  | Ir.IRInt -> obj [field "type" (js "integer")]
  | Ir.IRInt32 -> obj [field "type" (js "integer"); field "minimum" "-2147483648";
                       field "maximum" "2147483647"]
  | Ir.IRFloat -> obj [field "type" (js "number")]
  | Ir.IRPosixMillis -> obj [field "type" (js "integer")]
  | Ir.IRBool -> obj [field "type" (js "boolean")]
  | Ir.IRMoney -> obj [field "type" (js "object");
      field "properties" (obj [field "minorUnits" (obj [field "type" (js "integer")]);
                                field "currency" (obj [field "type" (js "string")])]);
      field "required" (array [js "minorUnits"; js "currency"]);
      field "additionalProperties" "false"]
  | Ir.IRMoneyRate -> obj [field "type" (js "object");
      field "properties" (obj [field "minorUnits" (obj [field "type" (js "integer")]);
                                field "currency" (obj [field "type" (js "string")]);
                                field "per" (obj [field "type" (js "string")])]);
      field "required" (array [js "minorUnits"; js "currency"; js "per"]);
      field "additionalProperties" "false"]
  | Ir.IRNamed name ->
    if List.mem name ["Unit"; "Json"; "Any"] then obj []
    else obj [field "$ref" (js ("#/components/schemas/" ^ name))]
  | Ir.IRVar _ | Ir.IROpaque _ -> obj []
  | Ir.IRList ty | Ir.IRSet ty ->
    obj [field "type" (js "array"); field "items" (schema_of_ir_type ty)]
  | Ir.IRMaybe ty ->
    obj [field "anyOf" (array [schema_of_ir_type ty; obj [field "type" (js "null")]])]
  | Ir.IRDict (Ir.IRString, value) ->
    obj [field "type" (js "object"); field "additionalProperties" (schema_of_ir_type value)]
  | Ir.IRDict (key, value) ->
    schema_of_ir_type (Ir.IRList (Ir.IRTuple [key; value]))
  | Ir.IRResult (ok, error) ->
    obj [field "oneOf" (array [
      obj [field "type" (js "object");
           field "properties" (obj [field "tag" (obj [field "const" (js "Ok")]);
                                     field "value" (schema_of_ir_type ok)]);
           field "required" (array [js "tag"; js "value"]); field "additionalProperties" "false"];
      obj [field "type" (js "object");
           field "properties" (obj [field "tag" (obj [field "const" (js "Err")]);
                                     field "error" (schema_of_ir_type error)]);
           field "required" (array [js "tag"; js "error"]); field "additionalProperties" "false"]])]
  | Ir.IREither (left, right) ->
    obj [field "oneOf" (array [
      obj [field "type" (js "object");
           field "properties" (obj [field "tag" (obj [field "const" (js "Left")]);
                                     field "value" (schema_of_ir_type left)]);
           field "required" (array [js "tag"; js "value"]); field "additionalProperties" "false"];
      obj [field "type" (js "object");
           field "properties" (obj [field "tag" (obj [field "const" (js "Right")]);
                                     field "value" (schema_of_ir_type right)]);
           field "required" (array [js "tag"; js "value"]); field "additionalProperties" "false"]])]
  | Ir.IRTuple elems ->
    obj [field "type" (js "array"); field "prefixItems" (array (List.map schema_of_ir_type elems));
         field "minItems" (string_of_int (List.length elems));
         field "maxItems" (string_of_int (List.length elems))]
  | Ir.IRFun _ -> obj []

let schema_of_type_expr ty = schema_of_ir_type (Ir.ir_type_of_type_expr ty)

let proof_extension proofs =
  match proofs with
  | [] -> []
  | _ -> [field "x-tesl-proof" (array (List.map js proofs))]

let rec return_proof_names = function
  | IRRetPlain _ -> []
  | IRRetAttached binding -> binding.irb_facts
  | IRRetNamedPack { entity_proof; other_proof; _ } ->
    List.concat_map (fun p -> Ir.proof_names p) (List.filter_map Fun.id [entity_proof; other_proof])
  | IRRetForAll { proof; _ }
  | IRRetMaybeForAll { proof; _ }
  | IRRetSetForAll { proof; _ }
  | IRRetMaybeSetForAll { proof; _ }
  | IRRetForAllDictValues { proof; _ }
  | IRRetForAllDictKeys { proof; _ } -> Ir.proof_names proof
  | IRRetExists { body; _ } -> return_proof_names body

let openapi_path path =
  let segments = String.split_on_char '/' path in
  let segments = List.map (fun segment ->
    if String.length segment > 1 && segment.[0] = ':' then
      "{" ^ String.sub segment 1 (String.length segment - 1) ^ "}"
    else segment
  ) segments in
  String.concat "/" segments

let record_schema fields =
  let properties, required =
    List.fold_left (fun (props, req) (f : field_def) ->
      let fs = schema_of_type_expr f.type_expr in
      let fs = match f.proof_ann with
        | None -> fs
        | Some proof ->
          (* Preserve the type schema while making proof metadata machine-readable. *)
          let proof_text = Ir.proof_expr_to_text proof in
          let fields = [field "description" (js proof_text); field "x-tesl-proof" (js proof_text)] in
          (match fs with
           | _ -> obj (fields @ [field "allOf" (array [fs])]))
      in
      ((field f.name fs) :: props, (js f.name) :: req)
    ) ([], []) fields
  in
  obj [field "type" (js "object"); field "properties" (obj properties);
       field "required" (array required); field "additionalProperties" "false"]

let schemas_for_decl = function
  | DRecord ({ name; fields; _ } : record_form) ->
    Some (name, record_schema fields)
  | DEntity ({ name; fields; _ } : entity_form) ->
    Some (name, record_schema fields)
  | DType (TypeNewtype { name; base_type; _ }) ->
    Some (name, schema_of_type_expr base_type)
  | DType (TypeAdt { name; variants; _ }) ->
    let variant_schema (variant : adt_variant) =
      let tag = field "tag" (obj [field "const" (js variant.ctor)]) in
      obj [field "type" (js "object");
           field "properties" (obj (tag :: List.map (fun (f : field_def) -> field f.name (schema_of_type_expr f.type_expr)) variant.fields));
           field "required" (array (js "tag" :: List.map (fun (f : field_def) -> js f.name) variant.fields))]
    in
    Some (name, obj [field "oneOf" (array (List.map variant_schema variants))])
  | _ -> None

let type_decl_name = function
  | DRecord ({ name; _ } : record_form)
  | DEntity ({ name; _ } : entity_form)
  | DType (TypeAdt { name; _ })
  | DType (TypeNewtype { name; _ }) -> Some name
  | _ -> None

(* OpenAPI components must include the transitive type declarations used by
   route records.  A server module commonly imports handlers from one module
   and their records from another, so the normal exposing filter is too narrow
   for a self-contained wire schema.  Deduplication keeps local declarations
   authoritative and prevents repeated JSON object keys. *)
let imported_type_decls (m : module_form) : top_decl list =
  let visited_modules = Hashtbl.create 16 in
  let by_name = Hashtbl.create 32 in
  let rec visit (source_file : string) (imports : import_decl list) =
    List.iter (fun (imp : import_decl) ->
      let is_tesl_module name =
        String.length name >= 5 && String.sub name 0 5 = "Tesl."
      in
      if not (is_tesl_module imp.module_name) then
        let path = Validation_common.resolve_local_import_path source_file imp.module_name in
        if Sys.file_exists path && not (Hashtbl.mem visited_modules path) then begin
          Hashtbl.add visited_modules path ();
          let source = In_channel.with_open_text path In_channel.input_all in
          match Parser.parse_module path source with
          | Err _ -> ()
          | Ok imported ->
            List.iter (fun decl ->
              match type_decl_name decl with
              | Some name when not (Hashtbl.mem by_name name) -> Hashtbl.add by_name name decl
              | _ -> ()) imported.decls;
            visit imported.source_file imported.imports
        end
    ) imports
  in
  visit m.source_file m.imports;
  Hashtbl.to_seq_values by_name |> List.of_seq

let unique_type_decls (decls : top_decl list) : top_decl list =
  let seen = Hashtbl.create 32 in
  List.filter (fun decl ->
    match type_decl_name decl with
    | None -> false
    | Some name ->
      if Hashtbl.mem seen name then false
      else (Hashtbl.add seen name (); true)
  ) decls

let rec response_schema (ep : Ir.ir_endpoint) =
  match ep.ire_response_wire_type with
  | Some name -> schema_of_ir_type (Ir.ir_type_of_type_expr (TName { name; loc = ep.ire_loc }))
  | None -> match ep.ire_return with
  | IRRetPlain ty -> schema_of_ir_type ty
  | IRRetAttached binding -> schema_of_ir_type binding.irb_type
  | IRRetNamedPack { ty; _ } -> schema_of_ir_type ty
  | IRRetForAll { elem_ty; _ } -> schema_of_ir_type (Ir.IRList elem_ty)
  | IRRetMaybeForAll { elem_ty; _ } -> schema_of_ir_type (Ir.IRMaybe (Ir.IRList elem_ty))
  | IRRetSetForAll { elem_ty; _ } -> schema_of_ir_type (Ir.IRSet elem_ty)
  | IRRetMaybeSetForAll { elem_ty; _ } -> schema_of_ir_type (Ir.IRMaybe (Ir.IRSet elem_ty))
  | IRRetForAllDictValues { key_ty; val_ty; _ }
  | IRRetForAllDictKeys { key_ty; val_ty; _ } -> schema_of_ir_type (Ir.IRDict (key_ty, val_ty))
  | IRRetExists { body; _ } ->
    let fake = { ep with ire_return = body } in response_schema fake

let method_name = function
  | GET -> "get" | POST -> "post" | PUT -> "put" | DELETE -> "delete"
  | PATCH -> "patch" | SSE -> "get"

let operation_for_endpoint (ep : Ir.ir_endpoint) =
  let proof_names =
    match ep.ire_auth with
    | None -> []
    | Some b -> b.irb_facts
  in
  let proof_names = proof_names
    @ (match ep.ire_body with None -> [] | Some b -> b.irb_facts)
    @ return_proof_names ep.ire_return in
  let parameters = List.map (fun (capture : Ir.ir_capture) ->
    obj [field "name" (js capture.irc_binding.irb_name); field "in" (js "path");
         field "required" "true"; field "schema" (schema_of_ir_type capture.irc_binding.irb_type);
         field "x-tesl-via" (js capture.irc_via_fn)]
  ) ep.ire_captures in
  let request_body = match ep.ire_body with
    | None -> []
    | Some body ->
       let body_type = match ep.ire_body_wire_type with
         | Some name -> Ir.ir_type_of_type_expr (TName { name; loc = ep.ire_loc })
         | None -> body.irb_type in
       [field "requestBody" (obj [field "required" "true";
         field "content" (obj [field "application/json"
          (obj [field "schema" (schema_of_ir_type body_type)])])])]
  in
  let responses = [
    field "200" (obj [field "description" (js "Successful response");
                       field "content" (obj [field "application/json"
                         (obj [field "schema" (response_schema ep)])])]);
  ] @ (if ep.ire_auth <> None then
         [field "401" (obj [field "description" (js "Authentication required")])]
       else [])
    @ (if ep.ire_captures <> [] then
         [field "404" (obj [field "description" (js "Resource not found")])]
       else [])
  in
  let security = if ep.ire_auth = None then [] else [field "security" (array [obj [field "session" (array [])]])] in
  let description = match proof_names with
    | [] -> []
    | _ -> [field "description" (js ("Proof requirements: " ^ String.concat ", " proof_names))]
  in
  obj ([field "operationId" (js ep.ire_name); field "responses" (obj responses)]
       @ description @ proof_extension proof_names @ security
       @ (if parameters = [] then [] else [field "parameters" (array parameters)])
       @ request_body
       @ (if ep.ire_method = SSE then [field "x-tesl-sse" "true"] else []))

let emit (m : module_form) ~(server_name : string) =
  let server = List.find_opt (function DServer s -> s.name = server_name | _ -> false) m.decls in
  let api_name = match server with
    | Some (DServer s) -> s.api_name
    | _ -> invalid_arg (Printf.sprintf "unknown server `%s`" server_name)
  in
  let api = List.find_opt (function DApi a -> a.name = api_name | _ -> false) m.decls in
  let endpoints = match api with
    | Some (DApi a) ->
      a.endpoints
      |> List.filter (fun ep -> ep.method_ <> SSE)
      |> List.map Ir.ir_endpoint_of_api_endpoint
    | _ -> invalid_arg (Printf.sprintf "server `%s` references unknown api `%s`" server_name api_name)
  in
  let paths = List.fold_left (fun acc (ep : Ir.ir_endpoint) ->
    let path = openapi_path ep.ire_path in
    let existing = match List.assoc_opt path acc with Some x -> x | None -> [] in
    (path, existing @ [field (method_name ep.ire_method) (operation_for_endpoint ep)])
      :: List.remove_assoc path acc
  ) [] endpoints in
  (* Route types may be imported from domain modules.  Keep the exported
     specification self-contained, otherwise ZAP rejects every $ref even
     though the checked program has the declarations in scope. *)
  let declarations = unique_type_decls (m.decls @ imported_type_decls m) in
  let schemas = List.filter_map schemas_for_decl declarations in
  let schema_json = List.map (fun (name, schema) -> field name schema) schemas in
  obj [field "openapi" (js "3.1.0");
       field "info" (obj [field "title" (js (m.module_name ^ " API"));
                           field "version" (js "1.0.0");
                           field "description" (js "Proof annotations are informational in OpenAPI; Tesl enforces them at compile time and at the real server boundary.")]);
       field "paths" (obj (List.map (fun (path, operations) -> field path (obj operations)) (List.rev paths)));
       field "components" (obj [field "securitySchemes" (obj [field "session"
         (obj [field "type" (js "apiKey"); field "in" (js "cookie"); field "name" (js "__Host-session")])]);
                              field "schemas" (obj schema_json)])]
