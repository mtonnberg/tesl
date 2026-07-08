open Ast

type ir_constraint = {
  op : string;
  fn_name : string;
  value_json : string;
}

let json_string s = Printf.sprintf "%S" s
let json_bool b = if b then "true" else "false"
let json_null = "null"
let json_array items = "[" ^ String.concat "," items ^ "]"
let json_object fields = "{" ^ String.concat "," fields ^ "}"
let json_field key value = json_string key ^ ":" ^ value
let ir_loc = Location.dummy_loc "<ir>"

let rec type_expr_to_text = function
  | TName { name; _ } -> name
  | TVar { name; _ } -> name
  | TApp { head; arg; _ } ->
    type_expr_to_text head ^ " " ^ type_expr_arg_to_text arg
  | TFun { dom; cod; _ } ->
    type_expr_arg_to_text dom ^ " -> " ^ type_expr_to_text cod
  | TTuple { elems; _ } ->
    "(" ^ String.concat ", " (List.map type_expr_to_text elems) ^ ")"

and type_expr_arg_to_text = function
  | TFun _ as ty -> "(" ^ type_expr_to_text ty ^ ")"
  | TTuple _ as ty -> "(" ^ type_expr_to_text ty ^ ")"
  | ty -> type_expr_to_text ty

let rec proof_expr_to_text = function
  | PredApp { pred; args; _ } ->
    if args = [] then pred else pred ^ " " ^ String.concat " " args
  | PredAnd { left; right; _ } ->
    proof_expr_to_text left ^ " && " ^ proof_expr_to_text right

let rec proof_names = function
  | PredApp { pred; _ } -> [pred]
  | PredAnd { left; right; _ } -> proof_names left @ proof_names right

let dedupe_preserving_order xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: rest when List.mem x seen -> loop seen acc rest
    | x :: rest -> loop (x :: seen) (x :: acc) rest
  in
  loop [] [] xs

let proof_names_opt = function
  | None -> []
  | Some p -> dedupe_preserving_order (proof_names p)

let first_fact_of_binding (binding : binding) =
  match proof_names_opt binding.proof_ann with
  | fact :: _ -> Some fact
  | [] -> None

let json_string_array xs = json_array (List.map json_string xs)

let json_fact_option = function
  | None -> json_null
  | Some fact -> json_string fact

type ir_type =
  | IRString
  | IRInt
  | IRFloat
  | IRBool
  | IRPosixMillis
  | IRMoney
    (** Nominal builtin. Bare HTTP wire shape {"minorUnits": <int>, "currency": "<ISO>"};
        the agent boundary ADDITIONALLY carries "display" — client decoders tolerate
        both and normalize to {minorUnits, currency}. *)
  | IRNamed of string
  | IRVar of string
  | IRList of ir_type
  | IRMaybe of ir_type
  | IRSet of ir_type
  | IRDict of ir_type * ir_type
  | IRResult of ir_type * ir_type
  | IREither of ir_type * ir_type
  | IRTuple of ir_type list
  | IRFun of ir_type * ir_type
  | IROpaque of string

type ir_binding = {
  irb_name : string;
  irb_type : ir_type;
  irb_proof : proof_expr option;
  irb_facts : string list;
  irb_via : string option;
  irb_codec : string option;
}

type ir_capture = {
  irc_binding : ir_binding;
  irc_via_fn : string;
}

type ir_return =
  | IRRetPlain of ir_type
  | IRRetAttached of ir_binding
  | IRRetNamedPack of { ty : ir_type; entity_proof : proof_expr option; other_proof : proof_expr option }
  | IRRetForAll of { elem_ty : ir_type; proof : proof_expr }
  | IRRetMaybeForAll of { elem_ty : ir_type; proof : proof_expr }
  | IRRetSetForAll of { elem_ty : ir_type; proof : proof_expr }
  | IRRetMaybeSetForAll of { elem_ty : ir_type; proof : proof_expr }
  | IRRetForAllDictValues of { key_ty : ir_type; val_ty : ir_type; proof : proof_expr }
  | IRRetForAllDictKeys of { key_ty : ir_type; val_ty : ir_type; proof : proof_expr }
  | IRRetExists of { binding : ir_binding; body : ir_return }

type ir_endpoint = {
  ire_name : string;
  ire_method : http_method;
  ire_path : string;
  ire_auth : ir_binding option;
  ire_auth_via : string option;
  ire_body : ir_binding option;
  ire_body_wire_type : string option;
  ire_body_decoder : string option;
  ire_body_via : string option;
  ire_response_wire_type : string option;
  ire_response_encoder : string option;
  ire_captures : ir_capture list;
  ire_return : ir_return;
  ire_subscribes : string list;
  ire_loc : Location.loc;
}

type ir_module = {
  irm_module_name : string;
  irm_source_file : string;
  irm_endpoints : ir_endpoint list;
}

(** True for a dimensioned-quantity type name: a surface alias (Length, Mass,
    Duration, Speed, …) or the internal canonical "§Q[…]" TCon name.  These
    erase to a bare number on the wire — clients treat them as plain Float.
    ACTIVE-gated aliases: `Speed` is a quantity only when the module being
    compiled imports it from Tesl.Units (the checker sets the state before
    the client generators run); a user's own `type Speed` stays IRNamed. *)
let is_quantity_type_name name =
  Units_catalog.active_dim_of_alias name <> None
  || Units_catalog.is_quantity_name name

let rec ir_type_of_type_expr (te : type_expr) : ir_type =
  let rec collect_app head args =
    match head with
    | TApp { head; arg; _ } -> collect_app head (arg :: args)
    | other -> (other, args)
  in
  match te with
  | TName { name = "String"; _ } -> IRString
  | TName { name = "Int"; _ }
  | TName { name = "Integer"; _ } -> IRInt
  | TName { name = "Float"; _ }
  | TName { name = "Real"; _ } -> IRFloat
  | TName { name = "Bool"; _ } -> IRBool
  | TName { name = "PosixMillis"; _ } -> IRPosixMillis
  | TName { name = "Money"; _ } -> IRMoney
  (* Dimensioned quantities (Length, Speed, … and the canonical "§Q[…]" TCon
     names) ERASE to a bare number on the wire — clients see plain Float. *)
  | TName { name; _ } when is_quantity_type_name name -> IRFloat
  | TName { name; _ } -> IRNamed name
  | TVar { name; _ } -> IRVar name
  | TFun { dom; cod; _ } -> IRFun (ir_type_of_type_expr dom, ir_type_of_type_expr cod)
  | TTuple { elems; _ } -> IRTuple (List.map ir_type_of_type_expr elems)
  | TApp _ ->
    let head, args = collect_app te [] in
    match head, args with
    | TName { name = "List"; _ }, [arg] -> IRList (ir_type_of_type_expr arg)
    | TName { name = "Maybe"; _ }, [arg] -> IRMaybe (ir_type_of_type_expr arg)
    | TName { name = "Set"; _ }, [arg] -> IRSet (ir_type_of_type_expr arg)
    | TName { name = "Dict"; _ }, [k; v] -> IRDict (ir_type_of_type_expr k, ir_type_of_type_expr v)
    | TName { name = "Result"; _ }, [ok; err] -> IRResult (ir_type_of_type_expr ok, ir_type_of_type_expr err)
    | TName { name = "Either"; _ }, [left; right] -> IREither (ir_type_of_type_expr left, ir_type_of_type_expr right)
    | TName { name = "Tuple2"; _ }, [a; b] -> IRTuple [ir_type_of_type_expr a; ir_type_of_type_expr b]
    | TName { name = "Tuple3"; _ }, [a; b; c] -> IRTuple [ir_type_of_type_expr a; ir_type_of_type_expr b; ir_type_of_type_expr c]
    | _ -> IROpaque (type_expr_to_text te)

let rec ir_type_to_text = function
  | IRString -> "String"
  | IRInt -> "Int"
  | IRFloat -> "Float"
  | IRBool -> "Bool"
  | IRPosixMillis -> "PosixMillis"
  | IRMoney -> "Money"
  | IRNamed name -> name
  | IRVar name -> name
  | IRList ty -> "List " ^ ir_type_arg_to_text ty
  | IRMaybe ty -> "Maybe " ^ ir_type_arg_to_text ty
  | IRSet ty -> "Set " ^ ir_type_arg_to_text ty
  | IRDict (k, v) -> "Dict " ^ ir_type_arg_to_text k ^ " " ^ ir_type_arg_to_text v
  | IRResult (ok, err) -> "Result " ^ ir_type_arg_to_text ok ^ " " ^ ir_type_arg_to_text err
  | IREither (left, right) -> "Either " ^ ir_type_arg_to_text left ^ " " ^ ir_type_arg_to_text right
  | IRTuple elems -> "(" ^ String.concat ", " (List.map ir_type_to_text elems) ^ ")"
  | IRFun (dom, cod) -> ir_type_arg_to_text dom ^ " -> " ^ ir_type_to_text cod
  | IROpaque text -> text

and ir_type_arg_to_text = function
  | IRFun _ as ty -> "(" ^ ir_type_to_text ty ^ ")"
  | IRTuple _ as ty -> "(" ^ ir_type_to_text ty ^ ")"
  | ty -> ir_type_to_text ty

let ir_binding_of_binding ?via ?codec (binding : binding) : ir_binding =
  {
    irb_name = binding.name;
    irb_type = ir_type_of_type_expr binding.type_expr;
    irb_proof = binding.proof_ann;
    irb_facts = proof_names_opt binding.proof_ann;
    irb_via = via;
    irb_codec = codec;
  }

let first_fact_of_ir_binding (binding : ir_binding) =
  match binding.irb_facts with
  | fact :: _ -> Some fact
  | [] -> None

let rec ir_return_of_return_spec = function
  | RetPlain { ty; _ } -> IRRetPlain (ir_type_of_type_expr ty)
  | RetAttached { binding; _ } -> IRRetAttached (ir_binding_of_binding binding)
  | RetNamedPack { ty; entity_proof; other_proof; _ } ->
    IRRetNamedPack {
      ty = ir_type_of_type_expr ty;
      entity_proof;
      other_proof;
    }
  | RetForAll { elem_ty; proof; _ } -> IRRetForAll { elem_ty = ir_type_of_type_expr elem_ty; proof }
  | RetMaybeForAll { elem_ty; proof; _ } -> IRRetMaybeForAll { elem_ty = ir_type_of_type_expr elem_ty; proof }
  | RetSetForAll { elem_ty; proof; _ } -> IRRetSetForAll { elem_ty = ir_type_of_type_expr elem_ty; proof }
  | RetMaybeSetForAll { elem_ty; proof; _ } -> IRRetMaybeSetForAll { elem_ty = ir_type_of_type_expr elem_ty; proof }
  | RetForAllDictValues { key_ty; val_ty; proof; _ } ->
    IRRetForAllDictValues { key_ty = ir_type_of_type_expr key_ty; val_ty = ir_type_of_type_expr val_ty; proof }
  | RetForAllDictKeys { key_ty; val_ty; proof; _ } ->
    IRRetForAllDictKeys { key_ty = ir_type_of_type_expr key_ty; val_ty = ir_type_of_type_expr val_ty; proof }
  | RetMaybeAttached { outer_ty = Some ty; _ } ->
    IRRetPlain (ir_type_of_type_expr ty)
  | RetMaybeAttached { binding; _ } ->
    IRRetAttached (ir_binding_of_binding binding)  (* proof stripped for runtime, just the type *)
  | RetExists { binding; body; _ } ->
    IRRetExists { binding = ir_binding_of_binding binding; body = ir_return_of_return_spec body }

let ir_endpoint_of_api_endpoint (ep : api_endpoint) : ir_endpoint =
  {
    ire_name = ep.name;
    ire_method = ep.method_;
    ire_path = ep.path;
    ire_auth = Option.map (fun (auth : api_auth) -> ir_binding_of_binding ~via:auth.via_fn auth.binding) ep.auth;
    ire_auth_via = Option.map (fun (auth : api_auth) -> auth.via_fn) ep.auth;
    ire_body = Option.map (fun body -> ir_binding_of_binding ?via:(ep_body_via ep) ?codec:(ep_body_decoder ep) body) (ep_body ep);
    ire_body_wire_type = ep_body_wire_type ep;
    ire_body_decoder = ep_body_decoder ep;
    ire_body_via = ep_body_via ep;
    ire_response_wire_type = ep_response_wire_type ep;
    ire_response_encoder = ep_response_encoder ep;
    ire_captures = List.map (fun (capture : api_capture) ->
      { irc_binding = ir_binding_of_binding ~via:capture.via_fn capture.binding; irc_via_fn = capture.via_fn }
    ) ep.captures;
    (* SSE has no return spec; it defaulted to `RetPlain Unit` before S6a, so keep
       that IR shape for a byte-exact export. *)
    ire_return = ir_return_of_return_spec
      (match ep_return_spec_opt ep with
       | Some rs -> rs
       | None -> RetPlain { ty = TName { name = "Unit"; loc = ep.loc }; loc = ep.loc });
    ire_subscribes = ep_subscribes ep;
    ire_loc = ep.loc;
  }

let module_to_ir (m : module_form) : ir_module =
  let endpoints = List.concat_map (function
    | DApi api -> List.map ir_endpoint_of_api_endpoint api.endpoints
    | _ -> []
  ) m.decls in
  {
    irm_module_name = m.module_name;
    irm_source_file = m.source_file;
    irm_endpoints = endpoints;
  }

let first_field_fact (field : field_def) =
  match proof_names_opt field.proof_ann with
  | fact :: _ -> Some fact
  | [] -> None

let field_fact_names (field : field_def) = proof_names_opt field.proof_ann

let rec proof_tree_json = function
  | PredApp { pred; _ } ->
    json_object [
      json_field "kind" (json_string "predicate");
      json_field "name" (json_string pred);
    ]
  | PredAnd { left; right; _ } ->
    json_object [
      json_field "kind" (json_string "and");
      json_field "left" (proof_tree_json left);
      json_field "right" (proof_tree_json right);
    ]

let binding_json ?via ?codec (binding : binding) =
  let facts = proof_names_opt binding.proof_ann in
  let proof_tree =
    match binding.proof_ann with
    | None -> json_null
    | Some p -> proof_tree_json p
  in
  let base_fields = [
    json_field "name" (json_string binding.name);
    json_field "type" (json_string (type_expr_to_text binding.type_expr));
    json_field "fact" (json_fact_option (first_fact_of_binding binding));
    json_field "facts" (json_string_array facts);
    json_field "proof_tree" proof_tree;
  ] in
  let via_fields =
    match via with
    | None -> []
    | Some v -> [json_field "via" (json_string v)]
  in
  let codec_fields =
    match codec with
    | None -> []
    | Some c -> [json_field "codec" (json_string c)]
  in
  json_object (base_fields @ via_fields @ codec_fields)

let record_field_json (field : field_def) =
  let facts = field_fact_names field in
  let proof_tree =
    match field.proof_ann with
    | None -> json_null
    | Some p -> proof_tree_json p
  in
  json_object [
    json_field "name" (json_string field.name);
    json_field "type" (json_string (type_expr_to_text field.type_expr));
    json_field "facts" (json_string_array facts);
    json_field "proof_tree" proof_tree;
  ]

let entity_field_fact_name (field : field_def) =
  match first_field_fact field with
  | Some fact -> fact
  | None -> String.capitalize_ascii field.name

let entity_field_json (field : field_def) =
  json_object [
    json_field "name" (json_string field.name);
    json_field "type" (json_string (type_expr_to_text field.type_expr));
    json_field "fact" (json_string (entity_field_fact_name field));
  ]

let adt_field_json (field : field_def) =
  json_object [
    json_field "name" (json_string field.name);
    json_field "type" (json_string (type_expr_to_text field.type_expr));
  ]

let collection_elem_type = function
  | TApp { head = TName { name = "List"; _ }; arg; _ } -> Some arg
  | _ -> None

let response_value_json ty facts =
  let base_fields = [
    json_field "type" (json_string (type_expr_to_text ty));
    json_field "facts" (json_string_array facts);
    json_field "is_list"
      (json_bool
         (match collection_elem_type ty with
          | Some _ -> true
          | None -> false));
  ] in
  let extra_fields =
    match collection_elem_type ty with
    | None -> []
    | Some elem_ty -> [json_field "elem_type" (json_string (type_expr_to_text elem_ty))]
  in
  json_object (base_fields @ extra_fields)

let rec response_json = function
  | RetPlain { ty; _ } -> response_value_json ty []
  | RetAttached { binding; _ } -> response_value_json binding.type_expr (proof_names_opt binding.proof_ann)
  | RetNamedPack { ty; entity_proof; other_proof; _ } ->
    response_value_json ty (dedupe_preserving_order (proof_names_opt entity_proof @ proof_names_opt other_proof))
  | RetForAll { elem_ty; proof; _ } ->
    response_value_json
      (TApp { head = TName { name = "List"; loc = ir_loc }; arg = elem_ty; loc = ir_loc })
      (dedupe_preserving_order (proof_names proof))
  | RetMaybeForAll { elem_ty; proof; _ } ->
    response_value_json
      (TApp {
         head = TName { name = "Maybe"; loc = ir_loc };
         arg = TApp { head = TName { name = "List"; loc = ir_loc }; arg = elem_ty; loc = ir_loc };
         loc = ir_loc;
       })
      (dedupe_preserving_order (proof_names proof))
  | RetSetForAll { elem_ty; proof; _ } ->
    response_value_json
      (TApp { head = TName { name = "Set"; loc = ir_loc }; arg = elem_ty; loc = ir_loc })
      (dedupe_preserving_order (proof_names proof))
  | RetMaybeSetForAll { elem_ty; proof; _ } ->
    response_value_json
      (TApp {
         head = TName { name = "Maybe"; loc = ir_loc };
         arg = TApp { head = TName { name = "Set"; loc = ir_loc }; arg = elem_ty; loc = ir_loc };
         loc = ir_loc;
       })
      (dedupe_preserving_order (proof_names proof))
  | RetForAllDictValues { key_ty; val_ty; proof; _ }
  | RetForAllDictKeys   { key_ty; val_ty; proof; _ } ->
    response_value_json
      (TApp { head = TApp { head = TName { name = "Dict"; loc = ir_loc };
                            arg = key_ty; loc = ir_loc };
              arg = val_ty; loc = ir_loc })
      (dedupe_preserving_order (proof_names proof))
  | RetMaybeAttached { outer_ty = Some ty; _ } ->
    response_value_json ty []
  | RetMaybeAttached { binding = b; _ } ->
    response_value_json
      (TApp { head = TName { name = "Maybe"; loc = ir_loc }; arg = b.type_expr; loc = ir_loc })
      (proof_names_opt b.proof_ann)
  | RetExists { body; _ } -> response_json body

let rec semantic_return_json = function
  | RetPlain { ty; _ } ->
    json_object [
      json_field "kind" (json_string "plain");
      json_field "type_text" (json_string (type_expr_to_text ty));
    ]
  | RetAttached { binding; _ } ->
    json_object [
      json_field "kind" (json_string "binding");
      json_field "binding" (binding_json binding);
    ]
  | RetNamedPack { ty; entity_proof; other_proof; _ } ->
    json_object [
      json_field "kind" (json_string "named-pack");
      json_field "type_text" (json_string (type_expr_to_text ty));
      json_field "entity_proof_text"
        (match entity_proof with None -> json_null | Some p -> json_string (proof_expr_to_text p));
      json_field "other_proof_text"
        (match other_proof with None -> json_null | Some p -> json_string (proof_expr_to_text p));
    ]
  | RetForAll { elem_ty; proof; _ } ->
    json_object [
      json_field "kind" (json_string "forall");
      json_field "elem_type_text" (json_string (type_expr_to_text elem_ty));
      json_field "forall_proof_text" (json_string (proof_expr_to_text proof));
    ]
  | RetMaybeForAll { elem_ty; proof; _ } ->
    json_object [
      json_field "kind" (json_string "maybe-forall");
      json_field "elem_type_text" (json_string (type_expr_to_text elem_ty));
      json_field "forall_proof_text" (json_string (proof_expr_to_text proof));
    ]
  | RetSetForAll { elem_ty; proof; _ } ->
    json_object [
      json_field "kind" (json_string "set-forall");
      json_field "elem_type_text" (json_string (type_expr_to_text elem_ty));
      json_field "forall_proof_text" (json_string (proof_expr_to_text proof));
    ]
  | RetMaybeSetForAll { elem_ty; proof; _ } ->
    json_object [
      json_field "kind" (json_string "maybe-set-forall");
      json_field "elem_type_text" (json_string (type_expr_to_text elem_ty));
      json_field "forall_proof_text" (json_string (proof_expr_to_text proof));
    ]
  | RetForAllDictValues { key_ty; val_ty; proof; _ } ->
    json_object [
      json_field "kind" (json_string "dict-forall-values");
      json_field "key_type_text" (json_string (type_expr_to_text key_ty));
      json_field "val_type_text" (json_string (type_expr_to_text val_ty));
      json_field "forall_proof_text" (json_string (proof_expr_to_text proof));
    ]
  | RetForAllDictKeys { key_ty; val_ty; proof; _ } ->
    json_object [
      json_field "kind" (json_string "dict-forall-keys");
      json_field "key_type_text" (json_string (type_expr_to_text key_ty));
      json_field "val_type_text" (json_string (type_expr_to_text val_ty));
      json_field "forall_proof_text" (json_string (proof_expr_to_text proof));
    ]
  | RetMaybeAttached { outer_ty = Some ty; binding = b; _ } ->
    json_object [
      json_field "kind" (json_string "generic-packed");
      json_field "outer_type_text" (json_string (type_expr_to_text ty));
      json_field "binding_name" (json_string b.name);
    ]
  | RetMaybeAttached { binding = b; _ } ->
    json_object [
      json_field "kind" (json_string "maybe-attached");
      json_field "binding_name" (json_string b.name);
      json_field "type_text" (json_string (type_expr_to_text b.type_expr));
    ]
  | RetExists { binding; body; _ } ->
    json_object [
      json_field "kind" (json_string "exists");
      json_field "binding" (binding_json binding);
      json_field "body" (semantic_return_json body);
    ]

let method_json = function
  | GET -> json_string "GET"
  | POST -> json_string "POST"
  | PUT -> json_string "PUT"
  | DELETE -> json_string "DELETE"
  | PATCH -> json_string "PATCH"
  | SSE -> json_string "SSE"

let codec_encode_entry_json (entry : codec_encode_entry) =
  json_object [
    json_field "name" (json_string entry.field_name);
    json_field "json_key" (json_string entry.json_key);
    json_field "codec" (json_string entry.codec);
  ]

let codec_decode_entry_json = function
  | DecodeField { field_name; json_key; codec; via; _ } ->
    json_object [
      json_field "name" (json_string field_name);
      json_field "json_key" (json_string json_key);
      json_field "codec" (json_string codec);
      json_field "via" (json_string_array via);
    ]
  | DecodeDefault { field_name; default_expr; _ } ->
    json_object [
      json_field "name" (json_string field_name);
      json_field "default" (json_string default_expr);
    ]
  | DecodeCrossCheck { checker; _ } ->
    json_object [json_field "checker" (json_string checker)]

let codec_to_json_json = function
  | ToJsonForbidden -> json_null
  | ToJsonFields entries -> json_array (List.map codec_encode_entry_json entries)
  | ToJsonAdt -> json_string "adtJson"

let codec_from_json_json = function
  | FromJsonForbidden -> json_null
  | FromJsonAlts alts ->
    json_array (List.map (fun alt -> json_array (List.map codec_decode_entry_json alt)) alts)
  | FromJsonAdt -> json_string "adtJson"

let codec_json (codec : codec_form) =
  json_object [
    json_field "name" (json_string codec.name);
    json_field "type" (json_string codec.type_name);
    json_field "to_json" (codec_to_json_json codec.to_json);
    json_field "from_json" (codec_from_json_json codec.from_json);
  ]

let invariant_json = function
  | None -> json_null
  | Some inv ->
    json_object [
      json_field "proof_text" (json_string (proof_expr_to_text inv.proof_text));
      json_field "checker_name"
        (match inv.checker_name with None -> json_null | Some name -> json_string name);
    ]

let record_json ~(codec_names : string list) (record : record_form) =
  json_object [
    json_field "name" (json_string record.name);
    json_field "fields" (json_array (List.map record_field_json record.fields));
    json_field "invariant" (invariant_json record.invariant);
    json_field "codec"
      (if List.mem record.name codec_names then json_string record.name else json_null);
  ]

let entity_json (entity : entity_form) =
  json_object [
    json_field "name" (json_string entity.name);
    json_field "table" (json_string entity.table);
    json_field "primary_key" (json_string entity.primary_key);
    json_field "fields" (json_array (List.map entity_field_json entity.fields));
  ]

let adt_variant_json (variant : adt_variant) =
  json_object [
    json_field "tag" (json_string variant.ctor);
    json_field "fields" (json_array (List.map adt_field_json variant.fields));
  ]

let type_decl_json ~(codec_names : string list) = function
  | TypeNewtype { name; base_type; _ }
  | TypeAlias { name; base_type; _ } ->
    Some (json_object [
      json_field "name" (json_string name);
      json_field "base" (json_string (type_expr_to_text base_type));
    ])
  | TypeAdt { name; variants; _ } ->
    Some (json_object [
      json_field "name" (json_string name);
      json_field "variants" (json_array (List.map adt_variant_json variants));
      json_field "codec"
        (if List.mem name codec_names then json_string name else json_null);
    ])

let app_head_and_args expr =
  let rec aux args = function
    | EApp { fn; arg; _ } -> aux (arg :: args) fn
    | head -> (head, args)
  in
  aux [] expr

let is_var_named name = function
  | EVar { name = other; _ } -> name = other
  | _ -> false

let int_lit = function
  | ELit { lit = LInt n; _ } -> Some n
  | _ -> None

let string_lit = function
  | ELit { lit = LString s; _ } -> Some s
  | _ -> None

let is_namespace_named name = function
  | EVar { name = other; _ } -> name = other
  | EConstructor { name = other; args = []; _ } -> name = other
  | _ -> false

let numeric_subject_fn base_name expr =
  match expr with
  | EVar { name; _ } when name = base_name -> Some "value"
  | _ ->
    let head, args = app_head_and_args expr in
    match head, args with
    | EField { obj; field = "length"; _ }, [arg]
      when is_namespace_named "String" obj && is_var_named base_name arg -> Some "String.length"
    | _ -> None

let direct_compare_op = function
  | BLt -> Some "lt"
  | BLe -> Some "lte"
  | BGt -> Some "gt"
  | BGe -> Some "gte"
  | _ -> None

let reverse_compare_op = function
  | BLt -> Some "gt"
  | BLe -> Some "gte"
  | BGt -> Some "lt"
  | BGe -> Some "lte"
  | _ -> None

let string_subject_and_value base_name = function
  | [subject; value] when is_var_named base_name subject -> Some value
  | [value; subject] when is_var_named base_name subject -> Some value
  | _ -> None

let string_call_constraint base_name expr =
  let head, args = app_head_and_args expr in
  match head with
  | EField { obj; field = "startsWith"; _ } when is_namespace_named "String" obj ->
    (match string_subject_and_value base_name args with
     | Some value ->
       (match string_lit value with
        | Some s -> Some { op = "starts_with"; fn_name = "String.startsWith"; value_json = json_string s }
        | None -> None)
     | None -> None)
  | EField { obj; field = "contains"; _ } when is_namespace_named "String" obj ->
    (match string_subject_and_value base_name args with
     | Some value ->
       (match string_lit value with
        | Some s -> Some { op = "contains"; fn_name = "String.contains"; value_json = json_string s }
        | None -> None)
     | None -> None)
  | EField { obj; field = "matches"; _ } when is_namespace_named "String" obj ->
    (match string_subject_and_value base_name args with
     | Some value ->
       (match string_lit value with
        | Some s -> Some { op = "regex"; fn_name = "String.matches"; value_json = json_string s }
        | None -> None)
     | None -> None)
  | _ -> None

let comparison_constraint base_name op left right =
  match numeric_subject_fn base_name left, int_lit right with
  | Some fn_name, Some n ->
    (match direct_compare_op op with
     | Some cmp -> Some { op = cmp; fn_name; value_json = string_of_int n }
     | None -> None)
  | _ ->
    match int_lit left, numeric_subject_fn base_name right with
    | Some n, Some fn_name ->
      (match reverse_compare_op op with
       | Some cmp -> Some { op = cmp; fn_name; value_json = string_of_int n }
       | None -> None)
    | _ -> None

let rec flatten_and = function
  | EBinop { op = BAnd; left; right; _ } -> flatten_and left @ flatten_and right
  | expr -> [expr]

let extract_single_constraint base_name = function
  | EBinop { op; left; right; _ } -> comparison_constraint base_name op left right
  | expr -> string_call_constraint base_name expr

(* B1 / review §8.2 (B1-nested-if-drop): the then-branch must UNCONDITIONALLY
   reach an `ok` — no nested `if`/`case` guard that could still reject a value the
   extracted condition already admitted.  Otherwise the extracted constraints
   UNDER-approximate the real predicate and a client smart-constructor would mint
   a proof (`axiom`) for a value the server rejects. *)
let rec ok_unguarded = function
  | EOk _ -> true
  | ELet { body; _ } | ELetProof { body; _ }
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
  | EWithTransaction { body; _ } -> ok_unguarded body
  | _ -> false

(* The else-branch must never produce an `ok` (it only fails); otherwise the
   condition does not decide acceptance and the constraints are not the predicate. *)
let rec branch_no_ok = function
  | EOk _ -> false
  | EIf { then_; else_; _ } -> branch_no_ok then_ && branch_no_ok else_
  | ECase { arms; _ } -> List.for_all (fun (a : case_arm) -> branch_no_ok a.body) arms
  | ELet { body; _ } | ELetProof { body; _ }
  | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
  | EWithTransaction { body; _ } -> branch_no_ok body
  | _ -> true

(* Return [Some constraints] ONLY when the body is PROVABLY the canonical
   fully-captured shape `if <all-extractable-conjuncts> then <ok…> else <fail…>`,
   so the constraint list IS the whole predicate.  Any nested guard on the
   ok-path, an inverted branch, a disjunction, or an unhandled conjunct yields
   [None] → the caller falls back to server-only validation and never manufactures
   a client proof.  (Making this TOTAL is the fail-closed fix; it is sound for the
   server IR too — server-only merely means "the server validates it".) *)
let extract_simple_constraints base_name = function
  | EIf { cond; then_; else_; _ } when ok_unguarded then_ && branch_no_ok else_ ->
    let parts = flatten_and cond in
    let rec collect acc = function
      | [] -> Some (List.rev acc)
      | part :: rest ->
        (match extract_single_constraint base_name part with
         | Some constraint_ -> collect (constraint_ :: acc) rest
         | None -> None)
    in
    collect [] parts
  | _ -> None

let rec first_ok_result = function
  | EOk { value; proof; _ } -> Some (value, proof)
  | EIf { then_; else_; _ } ->
    (match first_ok_result then_ with
     | Some _ as result -> result
     | None -> first_ok_result else_)
  | ELet { body; _ }
  | ELetProof { body; _ }
  | EWithDatabase { body; _ }
  | EWithCapabilities { body; _ }
  | EWithTransaction { body; _ } -> first_ok_result body
  | _ -> None

let rec value_fact_name = function
  | EConstructor { name; _ } -> Some name
  | EVar { name; _ } -> Some name
  | EApp { fn; _ } -> value_fact_name fn
  | EField { field; _ } -> Some field
  | _ -> None

let func_kind_text = function
  | CheckKind -> "check"
  | AuthKind -> "auth"
  | EstablishKind -> "establish"
  | FnKind -> "fn"
  | HandlerKind -> "handler"
  | WorkerKind -> "worker"
  | DeadWorkerKind -> "dead-worker"
  | MainKind -> "main"

(** Extract the fact predicate name from a `Fact (PredName ...)` type expression.
    E.g. `TApp(TName "Fact", TApp(TName "ValidPort", ...))` -> Some "ValidPort". *)
let fact_name_of_return_type (ty : type_expr) : string option =
  match ty with
  | TApp { head = TName { name = "Fact"; _ };
           arg = TApp { head = TName { name; _ }; _ }; _ }
  | TApp { head = TName { name = "Fact"; _ };
           arg = TName { name; _ }; _ } ->
    Some name
  | _ -> None

let fact_signature_of_func (func : func_decl) =
  match func.kind, func.return_spec with
  | (CheckKind | AuthKind), RetAttached { binding; _ } ->
    (match first_fact_of_binding binding with
     | Some fact_name -> Some (fact_name, type_expr_to_text binding.type_expr, binding.name)
     | None -> None)
  | EstablishKind, _ ->
    let base_type, base_name =
      match func.params with
      | param :: _ -> (type_expr_to_text param.type_expr, param.name)
      | [] -> ("Unit", "value")
    in
    (* Extract fact name from return type `Fact (PredName ...)` *)
    let fact_name_from_return =
      match func.return_spec with
      | RetPlain { ty; _ } -> fact_name_of_return_type ty
      | _ -> None
    in
    (match fact_name_from_return with
     | Some fact_name -> Some (fact_name, base_type, base_name)
     | None ->
       (* Fallback: scan for EOk in body (legacy path) *)
       (match first_ok_result func.body with
        | Some (_value, proof) ->
          (match dedupe_preserving_order (proof_names proof) with
           | fact_name :: _ -> Some (fact_name, base_type, base_name)
           | [] -> None)
        | None -> None))
  | _ -> None

let logic_json kind constraints =
  match kind with
  | `Auth -> json_object [json_field "kind" (json_string "auth")]
  | `ServerOnly -> json_object [json_field "kind" (json_string "server_only")]
  | `Simple ->
    json_object [
      json_field "kind" (json_string "simple");
      json_field "constraints"
        (json_array
           (List.map
              (fun ({ op; fn_name; value_json } : ir_constraint) ->
                 json_object [
                   json_field "op" (json_string op);
                   json_field "fn" (json_string fn_name);
                   json_field "value" value_json;
                 ])
              constraints));
    ]

(** Serialize a single fact parameter binding as {name, type}. *)
let fact_param_json (b : binding) =
  json_object [
    json_field "name" (json_string b.name);
    json_field "type" (json_string (type_expr_to_text b.type_expr));
  ]

(** Build logic fragment and fact JSON for a checker/auth/establish function.
    [fact_decls] maps fact names to their declaration forms so that multi-param
    facts get a full [params] array in the output.  When no explicit [fact]
    declaration exists the base param (derived from the checker's return
    binding) is used as a single-element fallback so consumers always see at
    least the primary annotated type. *)
let fact_json_of_func ~(fact_decls : (string, fact_form) Hashtbl.t) (func : func_decl) =
  match fact_signature_of_func func with
  | None -> None
  | Some (fact_name, base_type, base_name) ->
    let params_json = match Hashtbl.find_opt fact_decls fact_name with
      | Some fd -> json_array (List.map fact_param_json fd.params)
      | None ->
        (* No explicit fact declaration; expose the primary param derived from
           the checker's return binding so the IR is still useful. *)
        json_array [json_object [
          json_field "name" (json_string base_name);
          json_field "type" (json_string base_type);
        ]]
    in
    let logic =
      match func.kind with
      | AuthKind -> logic_json `Auth []
      | EstablishKind -> logic_json `ServerOnly []
      | CheckKind ->
        (match extract_simple_constraints base_name func.body with
         | Some constraints -> logic_json `Simple constraints
         | None -> logic_json `ServerOnly [])
      | _ -> logic_json `ServerOnly []
    in
    Some (fact_name,
          json_object [
            json_field "name" (json_string fact_name);
            json_field "params" params_json;
            json_field "checker" (json_string func.name);
            json_field "func_kind" (json_string (func_kind_text func.kind));
            json_field "base_type" (json_string base_type);
            json_field "logic" logic;
          ])

let endpoint_json ~(codec_names : string list) (ep : api_endpoint) =
  let auth_json =
    match ep.auth with
    | None -> json_null
    | Some auth -> binding_json ~via:auth.via_fn auth.binding
  in
  let inferred_body_codec =
    match (ep_body ep) with
    | Some body ->
      let ty = type_expr_to_text body.type_expr in
      if List.mem ty codec_names then Some ty else Some ty
    | None -> None
  in
  let body_codec =
    match (ep_body_via ep) with
    | Some c -> Some c
    | None ->
      (match (ep_body_decoder ep) with
       | Some c -> Some c
       | None -> inferred_body_codec)
  in
  let body_json =
    match (ep_body ep) with
    | None -> json_null
    | Some body -> binding_json ?codec:body_codec ?via:(ep_body_via ep) body
  in
  json_object [
    json_field "name" (json_string ep.name);
    json_field "method" (method_json ep.method_);
    json_field "path" (json_string ep.path);
    json_field "auth" auth_json;
    json_field "captures" (json_array (List.map (fun c -> binding_json ~via:c.via_fn c.binding) ep.captures));
    json_field "body" body_json;
    json_field "response" (response_json (ep_return_spec ep));
    json_field "semantic_return" (semantic_return_json (ep_return_spec ep));
  ]

let module_to_json ~(source_name : string) (m : module_form) =
  let codec_names =
    List.fold_left (fun acc decl -> match decl with DCodec codec -> codec.name :: acc | _ -> acc) [] m.decls
  in
  (* Pre-collect explicit fact declarations so checkers can attach full param lists. *)
  let fact_decls : (string, fact_form) Hashtbl.t = Hashtbl.create 8 in
  List.iter (function DFact fd -> Hashtbl.replace fact_decls fd.name fd | _ -> ()) m.decls;
  let records = ref [] in
  let adts = ref [] in
  let newtypes = ref [] in
  let entities = ref [] in
  let codecs = ref [] in
  let facts = ref [] in
  let endpoints = ref [] in
  List.iter
    (function
      | DRecord record -> records := record_json ~codec_names record :: !records
      | DEntity entity -> entities := entity_json entity :: !entities
      | DCodec codec -> codecs := codec_json codec :: !codecs
      | DType type_decl ->
        (match type_decl with
         | TypeAdt _ ->
           (match type_decl_json ~codec_names type_decl with Some json -> adts := json :: !adts | None -> ())
         | TypeNewtype _ | TypeAlias _ ->
           (match type_decl_json ~codec_names type_decl with Some json -> newtypes := json :: !newtypes | None -> ()))
      | DFunc func ->
        (match fact_json_of_func ~fact_decls func with
         | Some (fact_name, json) -> facts := (fact_name, json) :: List.remove_assoc fact_name !facts
         | None -> ())
      | DApi api -> endpoints := List.rev_map (endpoint_json ~codec_names) api.endpoints @ !endpoints
      | _ -> ())
    m.decls;
  (* Add standalone DFact entries — facts declared with `fact` but without a
     corresponding check / auth / establish function.  These appear in the IR
     with checker = null so that tooling can still see the predicate name and
     its parameter types. *)
  List.iter (function
    | DFact fd when not (List.mem_assoc fd.name !facts) ->
      let base_type = match fd.params with
        | p :: _ -> type_expr_to_text p.type_expr
        | []     -> "Unit"
      in
      let json = json_object [
        json_field "name"      (json_string fd.name);
        json_field "params"    (json_array (List.map fact_param_json fd.params));
        json_field "checker"   json_null;
        json_field "func_kind" json_null;
        json_field "base_type" (json_string base_type);
        json_field "logic"     json_null;
      ] in
      facts := (fd.name, json) :: !facts
    | _ -> ()) m.decls;
  json_object [
    json_field "module" (json_string m.module_name);
    json_field "source" (json_string source_name);
    json_field "records" (json_array (List.rev !records));
    json_field "adts" (json_array (List.rev !adts));
    json_field "newtypes" (json_array (List.rev !newtypes));
    json_field "entities" (json_array (List.rev !entities));
    json_field "facts" (json_array (List.map snd (List.rev !facts)));
    json_field "codecs" (json_array (List.rev !codecs));
    json_field "endpoints" (json_array (List.rev !endpoints));
  ]
