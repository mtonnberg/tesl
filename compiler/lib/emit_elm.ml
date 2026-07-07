(** Elm code generator.

    Converts a typed [Ast.module_form] to Elm source code with
    JSON decoders and HTTP client functions.

    The generated Elm client generation is experimental. *)

open Ast

(* ── String helpers ──────────────────────────────────────────────────────── *)

let lowercase_first s =
  if String.length s = 0 then s
  else String.make 1 (Char.lowercase_ascii s.[0]) ^ String.sub s 1 (String.length s - 1)

let capitalize_segment s =
  let parts = String.split_on_char '-' s in
  String.concat "" (List.map (fun p ->
    if String.length p = 0 then ""
    else String.make 1 (Char.uppercase_ascii p.[0]) ^ String.sub p 1 (String.length p - 1)
  ) parts)

let decoder_fn_name name = lowercase_first name ^ "Decoder"
let encoder_fn_name name = lowercase_first name ^ "Encoder"
let smart_constructor_name fact_name = lowercase_first fact_name
let fact_decoder_name fact_name = lowercase_first fact_name ^ "FieldDecoder"

let method_upper = function
  | GET -> "GET" | POST -> "POST" | PUT -> "PUT"
  | DELETE -> "DELETE" | PATCH -> "PATCH" | SSE -> "SSE"

let method_lower = function
  | GET -> "get" | POST -> "post" | PUT -> "put"
  | DELETE -> "delete" | PATCH -> "patch" | SSE -> "sse"

(** Derive the client function name from HTTP method + path.
    E.g. GET /todos/:todoId → "getTodos" *)
let fn_name_of_endpoint meth path =
  let segs = List.filter (fun s -> s <> "" && (String.length s = 0 || s.[0] <> ':'))
               (String.split_on_char '/' path) in
  let capitalized = List.map capitalize_segment segs in
  method_lower meth ^ String.concat "" capitalized

(* ── Type helpers ────────────────────────────────────────────────────────── *)

let rec elm_type_of_type_expr te =
  match te with
  | TName { name = "String"; _ } -> "String"
  | TName { name = "Int"; _ }
  | TName { name = "Integer"; _ } -> "Int"
  | TName { name = "Float"; _ }
  | TName { name = "Real"; _ } -> "Float"
  | TName { name = "Bool"; _ } -> "Bool"
  | TName { name = "PosixMillis"; _ } -> "Int"
  | TName { name = "Unit"; _ } -> "()"
  | TName { name = "Set"; _ } -> "List value"
  | TName { name; _ } -> name
  | TApp { head = TName { name = "List"; _ }; arg; _ } ->
    "List " ^ elm_type_arg arg
  | TApp { head = TName { name = "Maybe"; _ }; arg; _ } ->
    "Maybe " ^ elm_type_arg arg
  | TApp { head = TName { name = "Set"; _ }; arg; _ } ->
    "List " ^ elm_type_arg arg
  | TVar { name; _ } -> name
  | _ -> "value"

and elm_type_arg te =
  match te with
  | TApp _ | TFun _ | TTuple _ -> "(" ^ elm_type_of_type_expr te ^ ")"
  | _ -> elm_type_of_type_expr te

let dummy_emit_loc = Location.dummy_loc "<emit_elm>"

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' -> true
  | _ -> false

let trim_paren_wrapped text =
  let text = String.trim text in
  let enclosed_by_outer_parens s =
    let len = String.length s in
    if len < 2 || s.[0] <> '(' || s.[len - 1] <> ')' then
      None
    else
      let depth = ref 0 in
      let valid = ref true in
      for i = 0 to len - 1 do
        (match s.[i] with
         | '(' -> incr depth
         | ')' -> decr depth
         | _ -> ());
        if !depth < 0 then valid := false;
        if i < len - 1 && !depth = 0 then valid := false
      done;
      if (not !valid) || !depth <> 0 then None
      else Some (String.sub s 1 (len - 2) |> String.trim)
  in
  let rec loop s =
    match enclosed_by_outer_parens s with
    | Some inner -> loop inner
    | None -> s
  in
  loop text

let split_top_level_ands text =
  let len = String.length text in
  let depth = ref 0 in
  let start = ref 0 in
  let parts = ref [] in
  let push_part i =
    let piece = String.sub text !start (i - !start) |> String.trim in
    if piece <> "" then parts := piece :: !parts
  in
  let rec loop i =
    if i >= len then begin
      push_part len;
      List.rev !parts
    end else begin
      let ch = text.[i] in
      if ch = '(' then incr depth
      else if ch = ')' then decr depth;
      if !depth = 0 && i + 1 < len && text.[i] = '&' && text.[i + 1] = '&' then begin
        push_part i;
        start := i + 2;
        loop (i + 2)
      end else
        loop (i + 1)
    end
  in
  loop 0

let proof_pred_and_rest text =
  let text = String.trim text in
  let len = String.length text in
  let rec find_end i =
    if i < len && is_ident_char text.[i] then find_end (i + 1) else i
  in
  let end_ = find_end 0 in
  if end_ = 0 then None
  else
    let pred = String.sub text 0 end_ in
    let rest = String.sub text end_ (len - end_) |> String.trim in
    Some (pred, rest)

let rec proof_expr_of_text text =
  let text = trim_paren_wrapped text in
  match split_top_level_ands text with
  | [] -> None
  | [single] ->
    (match proof_pred_and_rest single with
     | None -> None
     | Some (pred, rest) ->
       let args =
         match pred, rest with
         | ("ForAll" | "ForAllValues" | "ForAllKeys"), rest when rest <> "" -> [rest]
         | _ -> []
       in
       Some (PredApp { pred; args; loc = dummy_emit_loc }))
  | first :: rest ->
    let rec combine left = function
      | [] -> Some left
      | part :: more ->
        (match proof_expr_of_text part with
         | None -> None
         | Some right ->
           combine (PredAnd { left; right; loc = dummy_emit_loc }) more)
    in
    (match proof_expr_of_text first with
     | None -> None
     | Some left -> combine left rest)

let simple_proof_atom_of_text text =
  proof_expr_of_text text

let rec flatten_proof = function
  | PredAnd { left; right; _ } -> flatten_proof left @ flatten_proof right
  | p -> [p]

let rebuild_proof = function
  | [] -> None
  | first :: rest ->
    Some (List.fold_left (fun left right ->
      PredAnd { left; right; loc = dummy_emit_loc }
    ) first rest)

let strip_hidden_client_proofs proof =
  rebuild_proof (List.filter (function
    | PredApp { pred = "FromDb"; _ } -> false
    | _ -> true
  ) (flatten_proof proof))

let strip_hidden_client_proofs_opt = function
  | None -> None
  | Some proof -> strip_hidden_client_proofs proof

let rec elm_proof_type = function
  | PredApp { pred = "ForAll"; args = inner :: _; _ } ->
    let inner_text = match simple_proof_atom_of_text inner with
      | Some proof -> elm_proof_arg proof
      | None -> "value"
    in
    Printf.sprintf "ForAll %s" inner_text
  | PredApp { pred = "ForAllValues"; args = inner :: _; _ } ->
    let inner_text = match simple_proof_atom_of_text inner with
      | Some proof -> elm_proof_arg proof
      | None -> "value"
    in
    Printf.sprintf "ForAllValues %s" inner_text
  | PredApp { pred = "ForAllKeys"; args = inner :: _; _ } ->
    let inner_text = match simple_proof_atom_of_text inner with
      | Some proof -> elm_proof_arg proof
      | None -> "value"
    in
    Printf.sprintf "ForAllKeys %s" inner_text
  | PredApp { pred; _ } -> pred
  | PredAnd { left; right; _ } ->
    Printf.sprintf "And %s %s" (elm_proof_arg left) (elm_proof_arg right)

and elm_proof_arg = function
  | PredApp _ as p -> elm_proof_type p
  | p -> "(" ^ elm_proof_type p ^ ")"

let elm_proof_type_annotation proof =
  match proof with
  | PredApp _ -> elm_proof_type proof
  | _ -> "(" ^ elm_proof_type proof ^ ")"

let elm_type_with_proof te proof_ann =
  match strip_hidden_client_proofs_opt proof_ann with
  | None -> elm_type_of_type_expr te
  | Some proof ->
    Printf.sprintf "Proven %s %s"
      (elm_type_arg te)
      (elm_proof_type_annotation proof)

let elm_type_application head arg =
  if String.contains arg ' ' then head ^ " (" ^ arg ^ ")" else head ^ " " ^ arg

let elm_result_type_arg ty =
  if String.contains ty ' ' then "(" ^ ty ^ ")" else ty

(* ── Decoder / encoder helpers ───────────────────────────────────────────── *)

let rec decode_expr_of_type te =
  match te with
  | TName { name = "String"; _ } -> "D.string"
  | TName { name = "Int"; _ }
  | TName { name = "Integer"; _ } -> "D.int"
  | TName { name = "Float"; _ }
  | TName { name = "Real"; _ } -> "D.float"
  | TName { name = "Bool"; _ } -> "D.bool"
  (* PosixMillis arrives as a bare epoch-millis integer over HTTP, but the
     agent-facing boundary renders it as {"epochMillis": <int>, "iso": "…"}
     (types.rkt agent enrichment).  Accept BOTH so a client decoder never
     breaks on whichever shape a payload carries. *)
  | TName { name = "PosixMillis"; _ } ->
    {|(D.oneOf [ D.int, D.field "epochMillis" D.int ])|}
  | TName { name = "Unit"; _ } -> "(D.succeed ())"
  | TName { name; _ } -> decoder_fn_name name
  | TApp { head = TName { name = "List"; _ }; arg; _ } ->
    "(D.list " ^ decode_expr_arg arg ^ ")"
  | TApp { head = TName { name = "Maybe"; _ }; arg; _ } ->
    "(D.maybe " ^ decode_expr_arg arg ^ ")"
  | TApp { head = TName { name = "Set"; _ }; arg; _ } ->
    "(D.list " ^ decode_expr_arg arg ^ ")"
  | _ -> "D.value"

and decode_expr_arg te =
  match te with
  | TApp _ -> "(" ^ decode_expr_of_type te ^ ")"
  | _ -> decode_expr_of_type te

let rec encode_expr_of_type te value_expr =
  match te with
  | TName { name = "String"; _ } -> "E.string " ^ value_expr
  | TName { name = "Int"; _ }
  | TName { name = "Integer"; _ } -> "E.int " ^ value_expr
  | TName { name = "Float"; _ }
  | TName { name = "Real"; _ } -> "E.float " ^ value_expr
  | TName { name = "Bool"; _ } -> "E.bool " ^ value_expr
  | TName { name = "PosixMillis"; _ } -> "E.int " ^ value_expr
  | TName { name = "Unit"; _ } -> "E.null"
  | TName { name; _ } -> encoder_fn_name name ^ " " ^ value_expr
  | TApp { head = TName { name = "List"; _ }; arg; _ }
  | TApp { head = TName { name = "Set"; _ }; arg; _ } ->
    "(E.list " ^ encode_fn_of_type arg ^ ") " ^ value_expr
  | TApp { head = TName { name = "Maybe"; _ }; arg; _ } ->
    Printf.sprintf "(Maybe.withDefault E.null (Maybe.map %s)) %s"
      (encode_fn_of_type arg) value_expr
  | _ -> "E.null"

and encode_fn_of_type te =
  match te with
  | TName { name = "String"; _ } -> "E.string"
  | TName { name = "Int"; _ }
  | TName { name = "Integer"; _ } -> "E.int"
  | TName { name = "Float"; _ }
  | TName { name = "Real"; _ } -> "E.float"
  | TName { name = "Bool"; _ } -> "E.bool"
  | TName { name = "PosixMillis"; _ } -> "E.int"
  | TName { name = "Unit"; _ } -> "(\\_ -> E.null)"
  | TName { name; _ } -> encoder_fn_name name
  | TApp { head = TName { name = "List"; _ }; arg; _ }
  | TApp { head = TName { name = "Set"; _ }; arg; _ } ->
    "(E.list " ^ encode_fn_of_type arg ^ ")"
  | _ -> "(\\_ -> E.null)"

let encode_expr_of_annotated_type te proof_ann value_expr =
  match strip_hidden_client_proofs_opt proof_ann with
  | None -> encode_expr_of_type te value_expr
  | Some _ -> encode_expr_of_type te ("(exorcise " ^ value_expr ^ ")")

let elm_type_text_arg text =
  if String.contains text ' ' then "(" ^ text ^ ")" else text

let rec elm_type_of_ir_type (ty : Ir.ir_type) =
  match ty with
  | Ir.IRString -> "String"
  | Ir.IRInt -> "Int"
  | Ir.IRFloat -> "Float"
  | Ir.IRBool -> "Bool"
  | Ir.IRPosixMillis -> "Int"
  | Ir.IRNamed "Unit" -> "()"
  | Ir.IRNamed name -> name
  | Ir.IRVar name -> name
  | Ir.IRList arg -> elm_type_application "List" (elm_type_text_arg (elm_type_of_ir_type arg))
  | Ir.IRMaybe arg -> elm_type_application "Maybe" (elm_type_text_arg (elm_type_of_ir_type arg))
  | Ir.IRSet arg -> elm_type_application "List" (elm_type_text_arg (elm_type_of_ir_type arg))
  | Ir.IRDict (Ir.IRString, value) ->
    "Dict String " ^ elm_type_text_arg (elm_type_of_ir_type value)
  | Ir.IRDict (key, value) ->
    elm_type_application "List"
      (Printf.sprintf "( %s, %s )" (elm_type_of_ir_type key) (elm_type_of_ir_type value))
  | Ir.IRResult (ok, err) ->
    "Result " ^ elm_type_text_arg (elm_type_of_ir_type err) ^ " " ^ elm_type_text_arg (elm_type_of_ir_type ok)
  | Ir.IREither _
  | Ir.IRFun _
  | Ir.IROpaque _ -> "value"
  | Ir.IRTuple elems ->
    "(" ^ String.concat ", " (List.map elm_type_of_ir_type elems) ^ ")"

let elm_type_with_proof_ir ty proof_ann =
  match strip_hidden_client_proofs_opt proof_ann with
  | None -> elm_type_of_ir_type ty
  | Some proof ->
    Printf.sprintf "Proven %s %s"
      (elm_type_text_arg (elm_type_of_ir_type ty))
      (elm_proof_type_annotation proof)

let wrap_decoder_arg dec =
  if String.contains dec ' ' then "(" ^ dec ^ ")" else dec

let tuple2_decoder a b =
  Printf.sprintf "(D.map2 (\\x y -> ( x, y )) (D.index 0 %s) (D.index 1 %s))"
    (wrap_decoder_arg a)
    (wrap_decoder_arg b)

let tuple3_decoder a b c =
  Printf.sprintf "(D.map3 (\\x y z -> ( x, y, z )) (D.index 0 %s) (D.index 1 %s) (D.index 2 %s))"
    (wrap_decoder_arg a)
    (wrap_decoder_arg b)
    (wrap_decoder_arg c)

let result_decoder ok_decoder err_decoder =
  Printf.sprintf
    "(D.field \"tag\" D.string |> D.andThen (\\tag -> case tag of \"Ok\" -> D.map Ok (D.field \"value\" %s) ; \"Err\" -> D.map Err (D.field \"error\" %s) ; _ -> D.fail (\"Unexpected Result tag: \" ++ tag)))"
    (wrap_decoder_arg ok_decoder)
    (wrap_decoder_arg err_decoder)

let either_decoder left_decoder right_decoder =
  Printf.sprintf
    "(D.field \"tag\" D.string |> D.andThen (\\tag -> case tag of \"Left\" -> D.map Left (D.field \"value\" %s) ; \"Right\" -> D.map Right (D.field \"value\" %s) ; _ -> D.fail (\"Unexpected Either tag: \" ++ tag)))"
    (wrap_decoder_arg left_decoder)
    (wrap_decoder_arg right_decoder)

let rec decode_expr_of_ir_type (ty : Ir.ir_type) =
  match ty with
  | Ir.IRString -> "D.string"
  | Ir.IRInt -> "D.int"
  | Ir.IRFloat -> "D.float"
  | Ir.IRBool -> "D.bool"
  (* Same tolerant shape as decode_expr_of_type: bare int (HTTP) OR the
     agent-enriched {"epochMillis": <int>, …} object. *)
  | Ir.IRPosixMillis ->
    {|(D.oneOf [ D.int, D.field "epochMillis" D.int ])|}
  | Ir.IRNamed "Unit" -> "(D.succeed ())"
  | Ir.IRNamed name -> decoder_fn_name name
  | Ir.IRVar _ -> "D.value"
  | Ir.IRList arg -> "(D.list " ^ wrap_decoder_arg (decode_expr_of_ir_type arg) ^ ")"
  | Ir.IRMaybe arg -> "(D.maybe " ^ wrap_decoder_arg (decode_expr_of_ir_type arg) ^ ")"
  | Ir.IRSet arg -> "(D.list " ^ wrap_decoder_arg (decode_expr_of_ir_type arg) ^ ")"
  | Ir.IRDict (Ir.IRString, value) -> "(D.dict " ^ wrap_decoder_arg (decode_expr_of_ir_type value) ^ ")"
  | Ir.IRDict (key, value) ->
    "(D.list " ^ tuple2_decoder (decode_expr_of_ir_type key) (decode_expr_of_ir_type value) ^ ")"
  | Ir.IRResult (ok, err) -> result_decoder (decode_expr_of_ir_type ok) (decode_expr_of_ir_type err)
  | Ir.IREither (left, right) -> either_decoder (decode_expr_of_ir_type left) (decode_expr_of_ir_type right)
  | Ir.IRTuple [a; b] -> tuple2_decoder (decode_expr_of_ir_type a) (decode_expr_of_ir_type b)
  | Ir.IRTuple [a; b; c] -> tuple3_decoder (decode_expr_of_ir_type a) (decode_expr_of_ir_type b) (decode_expr_of_ir_type c)
  | Ir.IRTuple _
  | Ir.IRFun _
  | Ir.IROpaque _ -> "D.value"

let rec encode_expr_of_ir_type ty value_expr =
  match ty with
  | Ir.IRString -> "E.string " ^ value_expr
  | Ir.IRInt -> "E.int " ^ value_expr
  | Ir.IRFloat -> "E.float " ^ value_expr
  | Ir.IRBool -> "E.bool " ^ value_expr
  | Ir.IRPosixMillis -> "E.int " ^ value_expr
  | Ir.IRNamed "Unit" -> "E.null"
  | Ir.IRNamed name -> encoder_fn_name name ^ " " ^ value_expr
  | Ir.IRList arg
  | Ir.IRSet arg -> "(E.list " ^ encode_fn_of_ir_type arg ^ ") " ^ value_expr
  | Ir.IRMaybe arg ->
    Printf.sprintf "(Maybe.withDefault E.null (Maybe.map %s)) %s"
      (encode_fn_of_ir_type arg)
      value_expr
  | Ir.IRDict (Ir.IRString, value) ->
    Printf.sprintf "(E.object (List.map (\\( k, v ) -> ( k, %s v )) (Dict.toList %s)))"
      (encode_fn_of_ir_type value)
      value_expr
  | Ir.IRDict (key, value) ->
    Printf.sprintf "(E.list (\\( k, v ) -> E.list identity [ %s k, %s v ]) %s)"
      (encode_fn_of_ir_type key)
      (encode_fn_of_ir_type value)
      value_expr
  | Ir.IRResult (ok, err) ->
    Printf.sprintf
      "((\\result_ -> case result_ of Ok ok_ -> E.object [ (\"tag\", E.string \"Ok\"), (\"value\", %s ok_) ] ; Err err_ -> E.object [ (\"tag\", E.string \"Err\"), (\"error\", %s err_) ]) %s)"
      (encode_fn_of_ir_type ok)
      (encode_fn_of_ir_type err)
      value_expr
  | Ir.IREither (left, right) ->
    Printf.sprintf
      "((\\either_ -> case either_ of Left left_ -> E.object [ (\"tag\", E.string \"Left\"), (\"value\", %s left_) ] ; Right right_ -> E.object [ (\"tag\", E.string \"Right\"), (\"value\", %s right_) ]) %s)"
      (encode_fn_of_ir_type left)
      (encode_fn_of_ir_type right)
      value_expr
  | Ir.IRTuple [a; b] ->
    Printf.sprintf "((\\( first, second ) -> E.list identity [ %s first, %s second ]) %s)"
      (encode_fn_of_ir_type a)
      (encode_fn_of_ir_type b)
      value_expr
  | Ir.IRTuple [a; b; c] ->
    Printf.sprintf "((\\( first, second, third ) -> E.list identity [ %s first, %s second, %s third ]) %s)"
      (encode_fn_of_ir_type a)
      (encode_fn_of_ir_type b)
      (encode_fn_of_ir_type c)
      value_expr
  | Ir.IRTuple _
  | Ir.IRVar _
  | Ir.IRFun _
  | Ir.IROpaque _ -> "E.null"

and encode_fn_of_ir_type ty =
  match ty with
  | Ir.IRString -> "E.string"
  | Ir.IRInt -> "E.int"
  | Ir.IRFloat -> "E.float"
  | Ir.IRBool -> "E.bool"
  | Ir.IRPosixMillis -> "E.int"
  | Ir.IRNamed "Unit" -> "(\\_ -> E.null)"
  | Ir.IRNamed name -> encoder_fn_name name
  | _ -> "(\\value -> " ^ (encode_expr_of_ir_type ty "value") ^ ")"

let encode_fn_of_annotated_ir_type ty proof_ann =
  match strip_hidden_client_proofs_opt proof_ann with
  | None -> encode_fn_of_ir_type ty
  | Some _ -> "(\\value -> " ^ (encode_expr_of_ir_type ty "(exorcise value)") ^ ")"

let split_ir_binding_collection_proof proof =
  let elem_proof = ref None in
  let outer_parts = ref [] in
  List.iter (function
    | PredApp { pred = "ForAll"; args = inner :: _; _ } ->
      if !elem_proof = None then
        elem_proof := strip_hidden_client_proofs_opt (simple_proof_atom_of_text inner)
    | part ->
      outer_parts := part :: !outer_parts
  ) (flatten_proof proof);
  let outer_proof =
    match rebuild_proof (List.rev !outer_parts) with
    | None -> None
    | Some outer -> strip_hidden_client_proofs outer
  in
  (!elem_proof, outer_proof)

let elm_type_of_ir_binding_surface ty proof_ann =
  match strip_hidden_client_proofs_opt proof_ann with
  | None -> elm_type_of_ir_type ty
  | Some proof ->
    let elem_proof, outer_proof = split_ir_binding_collection_proof proof in
    (match elem_proof, ty with
     | Some elem_proof, (Ir.IRList elem_ty | Ir.IRSet elem_ty) ->
       let elem_type = elm_type_with_proof_ir elem_ty (Some elem_proof) in
       let collection_type = elm_type_application "List" (elm_type_text_arg elem_type) in
       (match outer_proof with
        | None -> collection_type
        | Some outer ->
          Printf.sprintf "Proven %s %s"
            (elm_type_text_arg collection_type)
            (elm_proof_type_annotation outer))
     | _ -> elm_type_with_proof_ir ty (Some proof))

let encode_expr_of_ir_binding_surface ty proof_ann value_expr =
  match strip_hidden_client_proofs_opt proof_ann with
  | None -> encode_expr_of_ir_type ty value_expr
  | Some proof ->
    let elem_proof, outer_proof = split_ir_binding_collection_proof proof in
    (match elem_proof, ty with
     | Some elem_proof, (Ir.IRList elem_ty | Ir.IRSet elem_ty) ->
       let collection_value = match outer_proof with
         | None -> value_expr
         | Some _ -> "(exorcise " ^ value_expr ^ ")"
       in
       Printf.sprintf "(E.list %s) %s"
         (encode_fn_of_annotated_ir_type elem_ty (Some elem_proof))
         collection_value
     | _ -> encode_expr_of_ir_type ty ("(exorcise " ^ value_expr ^ ")"))

let encode_expr_of_annotated_ir_type ty proof_ann value_expr =
  match strip_hidden_client_proofs_opt proof_ann with
  | None -> encode_expr_of_ir_type ty value_expr
  | Some _ -> encode_expr_of_ir_type ty ("(exorcise " ^ value_expr ^ ")")

(* ── Fact classification ─────────────────────────────────────────────────── *)

type elm_fact_kind =
  | FkElmSmart of { checker : string; base_type : type_expr; constraints : Ir.ir_constraint list }
  (* A single-value `check` whose predicate cannot be inlined into Elm (it calls a
     helper fn). Rather than SILENTLY dropping the smart constructor (issue #13 —
     which then breaks `elm make` with a confusing "does not expose fooOk"), emit
     the constructor delegating the predicate to a user-managed `ApiHelpers.<check>`
     Elm function. If the user hasn't written it, `elm make` fails LOUD and clear. *)
  | FkElmHelper of { checker : string; base_type : type_expr }
  | FkAuth of { checker : string; base_type : type_expr }
  | FkServerOnly of { checker : string option; base_type : type_expr }

let fallback_type_expr =
  TName { name = "String"; loc = Location.dummy_loc "<emit_elm>" }

let establish_fact_name (func : func_decl) : string option =
  match func.kind with
  | EstablishKind ->
    let ret_ty = match func.return_spec with
      | RetPlain { ty; _ } -> Some ty
      | _ -> None
    in
    (match ret_ty with
     | Some (TApp { head = TName { name = "Maybe"; _ };
                    arg = TApp { head = TName { name = "Fact"; _ }; arg = inner; _ }; _ }) ->
       (match inner with
        | TApp { head = TName { name; _ }; _ } -> Some name
        | TName { name; _ } -> Some name
        | _ -> None)
     | Some (TApp { head = TName { name = "Maybe"; _ };
                    arg = TApp { head = TName { name; _ }; _ }; _ })
       when name <> "List" && name <> "Maybe" -> Some name
     | _ -> None)
  | _ -> None

let collect_establish_fns (decls : top_decl list) : (string, string) Hashtbl.t =
  let tbl = Hashtbl.create 4 in
  List.iter (function
    | DFunc func when func.kind = EstablishKind ->
      (match establish_fact_name func with
       | Some fact_name -> Hashtbl.replace tbl fact_name func.name
       | None -> ())
    | _ -> ()
  ) decls;
  tbl

let fact_decl_param_count fact_name ~(fact_decls : (string, fact_form) Hashtbl.t) =
  match Hashtbl.find_opt fact_decls fact_name with
  | Some fd -> List.length fd.params
  | None -> 1

let find_fact_base_type fact_name ~(fact_decls : (string, fact_form) Hashtbl.t) ~(decls : top_decl list) =
  match Hashtbl.find_opt fact_decls fact_name with
  | Some fd ->
    (match fd.params with
     | p :: _ -> p.type_expr
     | [] -> fallback_type_expr)
  | None ->
    let producing_func = List.find_opt (function
      | DFunc func ->
        (match Ir.fact_signature_of_func func with
         | Some (fn, _, _) when fn = fact_name -> true
         | _ -> false)
      | _ -> false
    ) decls in
    match producing_func with
    | Some (DFunc func) ->
      (match func.kind, func.return_spec, func.params with
       | (CheckKind | AuthKind), RetAttached { binding; _ }, _ -> binding.type_expr
       | EstablishKind, _, p :: _ -> p.type_expr
       | _ -> fallback_type_expr)
    | _ -> fallback_type_expr

let elm_condition_of_constraint value_var (c : Ir.ir_constraint) : string option =
  match c.op, c.fn_name with
  | "gte", "String.length" ->
    Some (Printf.sprintf "String.length %s >= %s" value_var c.value_json)
  | "lte", "String.length" ->
    Some (Printf.sprintf "String.length %s <= %s" value_var c.value_json)
  | "gt", "String.length" ->
    Some (Printf.sprintf "String.length %s > %s" value_var c.value_json)
  | "lt", "String.length" ->
    Some (Printf.sprintf "String.length %s < %s" value_var c.value_json)
  | "starts_with", "String.startsWith" ->
    Some (Printf.sprintf "String.startsWith %s %s" c.value_json value_var)
  | "contains", "String.contains" ->
    Some (Printf.sprintf "String.contains %s %s" c.value_json value_var)
  | "gte", "value" -> Some (Printf.sprintf "%s >= %s" value_var c.value_json)
  | "lte", "value" -> Some (Printf.sprintf "%s <= %s" value_var c.value_json)
  | "gt", "value" -> Some (Printf.sprintf "%s > %s" value_var c.value_json)
  | "lt", "value" -> Some (Printf.sprintf "%s < %s" value_var c.value_json)
  | _ -> None

let all_elm_conditions value_var (constraints : Ir.ir_constraint list) : string list option =
  let rec go acc = function
    | [] -> Some (List.rev acc)
    | c :: rest ->
      (match elm_condition_of_constraint value_var c with
       | Some cond -> go (cond :: acc) rest
       | None -> None)
  in
  go [] constraints

let classify_fact fact_name
    ~(fact_decls : (string, fact_form) Hashtbl.t)
    ~(establish_fns : (string, string) Hashtbl.t)
    ~(decls : top_decl list) : elm_fact_kind =
  let base_type = find_fact_base_type fact_name ~fact_decls ~decls in
  if Hashtbl.mem establish_fns fact_name then
    FkServerOnly { checker = Some (Hashtbl.find establish_fns fact_name); base_type }
  else begin
    let check_or_auth = List.find_opt (function
      | DFunc func ->
        (match Ir.fact_signature_of_func func with
         | Some (fn, _, _) when fn = fact_name -> true
         | _ -> false)
      | _ -> false
    ) decls in
    match check_or_auth with
    | Some (DFunc func) ->
      (match func.kind with
       | AuthKind -> FkAuth { checker = func.name; base_type }
       | CheckKind ->
         if fact_decl_param_count fact_name ~fact_decls <> 1 then
           FkServerOnly { checker = Some func.name; base_type }
         else
           let base_name = match func.params with
             | p :: _ -> p.name
             | [] -> "value"
           in
           (match Ir.extract_simple_constraints base_name func.body with
            | Some constraints ->
              (match all_elm_conditions "input" constraints with
               | Some _ -> FkElmSmart { checker = func.name; base_type; constraints }
               (* The predicate IS visible but only PARTIALLY translatable (e.g. a
                  nested guard). Stay server-only — manufacturing a client proof
                  from the partial subset would accept values the full predicate
                  rejects (soundness). *)
               | None -> FkServerOnly { checker = Some func.name; base_type })
            (* No flat constraints extracted. Delegate to `ApiHelpers.<check>` ONLY
               when the predicate CALLS A USER-DEFINED `fn` (the issue #13 scenario:
               a validator factored into a helper). An unconditional check (`ok x`)
               or a stdlib-only nested guard has no user helper to reimplement, so it
               stays server-only — don't force an ApiHelpers module on it. *)
            | None ->
              let user_fn_names =
                List.filter_map (function
                  | DFunc f when f.kind = FnKind -> Some f.name | _ -> None) decls in
              let rec calls_user_fn e =
                let head_name e =
                  let rec go = function
                    | EApp { fn; _ } -> go fn
                    | EVar { name; _ } -> Some name
                    | _ -> None
                  in go e in
                match e with
                | EVar { name; _ } -> List.mem name user_fn_names
                | EApp { fn; arg; _ } ->
                  (match head_name fn with Some n when List.mem n user_fn_names -> true | _ -> false)
                  || calls_user_fn fn || calls_user_fn arg
                | EIf { cond; then_; else_; _ } ->
                  calls_user_fn cond || calls_user_fn then_ || calls_user_fn else_
                | EBinop { left; right; _ } -> calls_user_fn left || calls_user_fn right
                | EUnop { arg; _ } -> calls_user_fn arg
                | ELet { value; body; _ } | ELetProof { value; body; _ } ->
                  calls_user_fn value || calls_user_fn body
                | ECase { scrut; arms; _ } ->
                  calls_user_fn scrut
                  || List.exists (fun (a : case_arm) -> calls_user_fn a.body) arms
                | EOk { value; _ } -> calls_user_fn value
                | _ -> false
              in
              if calls_user_fn func.body then
                FkElmHelper { checker = func.name; base_type }
              else
                FkServerOnly { checker = Some func.name; base_type })
       | _ -> FkServerOnly { checker = Some func.name; base_type })
    | _ -> FkServerOnly { checker = None; base_type }
  end

(* ── Proof-aware decoders ────────────────────────────────────────────────── *)

let rec proof_ctor_expr = function
  | PredApp { pred = "ForAll"; _ } -> "ForAll"
  | PredApp { pred = "ForAllValues"; _ } -> "ForAllValues"
  | PredApp { pred = "ForAllKeys"; _ } -> "ForAllKeys"
  | PredApp { pred; _ } -> pred
  | PredAnd { left; right; _ } ->
    Printf.sprintf "and (%s) (%s)" (proof_ctor_expr left) (proof_ctor_expr right)

let rec validation_chain ~fact_kind_of proof_ctor facts indent =
  match facts with
  | [] -> indent ^ "D.succeed (axiom (" ^ proof_ctor ^ ") v)"
  | fact_name :: rest ->
    match fact_kind_of fact_name with
    | FkElmSmart _ | FkElmHelper _ ->
      indent ^ "case " ^ smart_constructor_name fact_name ^ " v of\n"
      ^ indent ^ "    Just _ ->\n"
      ^ validation_chain ~fact_kind_of proof_ctor rest (indent ^ "        ") ^ "\n"
      ^ indent ^ "    Nothing ->\n"
      ^ indent ^ "        D.fail " ^ Printf.sprintf "%S" ("Failed proof: " ^ fact_name)
    | _ -> validation_chain ~fact_kind_of proof_ctor rest indent

let decode_expr_of_proof_wrapped ~fact_kind_of ~has_fact_decoder base_decoder proof_ann =
  match strip_hidden_client_proofs_opt proof_ann with
  | None -> base_decoder
  | Some (PredApp { pred; _ }) when has_fact_decoder pred -> fact_decoder_name pred
  | Some proof ->
    let facts = Ir.dedupe_preserving_order (Ir.proof_names proof) in
    let simple_facts = List.filter (fun fact_name ->
      has_fact_decoder fact_name &&
      match fact_kind_of fact_name with
      | FkElmSmart _ -> true
      | _ -> false
    ) facts in
    if simple_facts = [] then
      Printf.sprintf "(%s |> D.map (axiom (%s)))" base_decoder (proof_ctor_expr proof)
    else
      Printf.sprintf "(%s
        |> D.andThen
            (\\v ->
%s
            ))"
        base_decoder
        (validation_chain ~fact_kind_of (proof_ctor_expr proof) simple_facts "                ")

let decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder ty proof_ann =
  decode_expr_of_proof_wrapped
    ~fact_kind_of
    ~has_fact_decoder
    (decode_expr_of_ir_type ty)
    proof_ann

let decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder te proof_ann =
  decode_expr_of_proof_wrapped
    ~fact_kind_of
    ~has_fact_decoder
    (decode_expr_of_type te)
    proof_ann

let decoder_for_fields ~fact_kind_of ~has_fact_decoder type_name (fields : field_def list) : string =
  let n = List.length fields in
  let field_decoders = List.map (fun (f : field_def) ->
    Printf.sprintf "        (D.field %S %s)"
      f.name
      (decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder f.type_expr f.proof_ann)
  ) fields in
  match n with
  | 0 -> Printf.sprintf "D.succeed %s" type_name
  | 1 ->
    Printf.sprintf "D.map %s\n%s" type_name (List.nth field_decoders 0)
  | n when n <= 8 ->
    Printf.sprintf "D.map%d %s\n%s" n type_name
      (String.concat "\n" field_decoders)
  | _ ->
    (* Elm's built-in D.mapN family stops at D.map8.  For 9+ fields, build the
       decoder applicatively: `D.succeed Ctor |> D.map2 (|>) dec1 |> …` — each
       step supplies the record constructor's next positional argument, so this
       handles ANY field count with no helper definition.  (GitHub #25: the old
       branch emitted D.map8 over the first 8 fields and referenced the
       remaining field names unbound, so the generated module did not compile.) *)
    let steps = List.map (fun (f : field_def) ->
      Printf.sprintf "        |> D.map2 (|>) (D.field %S %s)"
        f.name
        (decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder f.type_expr f.proof_ann)
    ) fields in
    Printf.sprintf "D.succeed %s\n%s" type_name (String.concat "\n" steps)

(* ── Return type helpers ─────────────────────────────────────────────────── *)

let combine_proofs left right =
  match left, right with
  | None, x | x, None -> x
  | Some l, Some r -> Some (PredAnd { left = l; right = r; loc = Location.dummy_loc "<emit_elm>" })

type elm_return_info = {
  type_text : string;
  decoder_text : string;
}

let rec return_info ~fact_kind_of ~has_fact_decoder (rs : return_spec) : elm_return_info =
  match rs with
  | RetPlain { ty; _ } ->
    { type_text = elm_type_of_type_expr ty; decoder_text = decode_expr_of_type ty }
  | RetAttached { binding; _ } ->
    { type_text = elm_type_with_proof binding.type_expr binding.proof_ann;
      decoder_text = decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder binding.type_expr binding.proof_ann }
  | RetNamedPack { ty; entity_proof; other_proof; _ } ->
    let proof_ann = combine_proofs entity_proof other_proof in
    { type_text = elm_type_with_proof ty proof_ann;
      decoder_text = decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder ty proof_ann }
  | RetForAll { elem_ty; proof; _ } ->
    let elem_type = elm_type_with_proof elem_ty (Some proof) in
    let elem_decoder = decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder elem_ty (Some proof) in
    { type_text = elm_type_application "List" elem_type;
      decoder_text = "(D.list " ^ elem_decoder ^ ")" }
  | RetMaybeForAll { elem_ty; proof; _ } ->
    let elem_type = elm_type_with_proof elem_ty (Some proof) in
    let list_type = elm_type_application "List" elem_type in
    let elem_decoder = decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder elem_ty (Some proof) in
    { type_text = elm_type_application "Maybe" list_type;
      decoder_text = "(D.maybe (D.list " ^ elem_decoder ^ "))" }
  | RetSetForAll { elem_ty; proof; _ } ->
    let elem_type = elm_type_with_proof elem_ty (Some proof) in
    let elem_decoder = decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder elem_ty (Some proof) in
    { type_text = elm_type_application "List" elem_type;
      decoder_text = "(D.list " ^ elem_decoder ^ ")" }
  | RetMaybeSetForAll { elem_ty; proof; _ } ->
    let elem_type = elm_type_with_proof elem_ty (Some proof) in
    let list_type = elm_type_application "List" elem_type in
    let elem_decoder = decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder elem_ty (Some proof) in
    { type_text = elm_type_application "Maybe" list_type;
      decoder_text = "(D.maybe (D.list " ^ elem_decoder ^ "))" }
  | RetForAllDictValues _
  | RetForAllDictKeys _ ->
    { type_text = "value"; decoder_text = "D.value" }
  | RetMaybeAttached { outer_ty = Some ty; _ } ->
    { type_text = elm_type_of_type_expr ty;
      decoder_text = decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder ty None }
  | RetMaybeAttached { binding; _ } ->
    let inner_type = elm_type_with_proof binding.type_expr binding.proof_ann in
    { type_text = elm_type_application "Maybe" inner_type;
      decoder_text = "(D.maybe " ^ decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder binding.type_expr binding.proof_ann ^ ")" }
  | RetExists { body; _ } -> return_info ~fact_kind_of ~has_fact_decoder body

let rec return_info_ir ~fact_kind_of ~has_fact_decoder (rs : Ir.ir_return) : elm_return_info =
  match rs with
  | Ir.IRRetPlain ty ->
    { type_text = elm_type_of_ir_type ty; decoder_text = decode_expr_of_ir_type ty }
  | Ir.IRRetAttached binding ->
    { type_text = elm_type_with_proof_ir binding.irb_type binding.irb_proof;
      decoder_text = decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder binding.irb_type binding.irb_proof }
  | Ir.IRRetNamedPack { ty; entity_proof; other_proof } ->
    let proof_ann = combine_proofs entity_proof other_proof in
    { type_text = elm_type_with_proof_ir ty proof_ann;
      decoder_text = decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder ty proof_ann }
  | Ir.IRRetForAll { elem_ty; proof } ->
    let elem_type = elm_type_with_proof_ir elem_ty (Some proof) in
    let elem_decoder = decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder elem_ty (Some proof) in
    { type_text = elm_type_application "List" elem_type;
      decoder_text = "(D.list " ^ wrap_decoder_arg elem_decoder ^ ")" }
  | Ir.IRRetMaybeForAll { elem_ty; proof } ->
    let elem_type = elm_type_with_proof_ir elem_ty (Some proof) in
    let list_type = elm_type_application "List" elem_type in
    let elem_decoder = decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder elem_ty (Some proof) in
    { type_text = elm_type_application "Maybe" list_type;
      decoder_text = "(D.maybe (D.list " ^ wrap_decoder_arg elem_decoder ^ "))" }
  | Ir.IRRetSetForAll { elem_ty; proof } ->
    let elem_type = elm_type_with_proof_ir elem_ty (Some proof) in
    let elem_decoder = decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder elem_ty (Some proof) in
    { type_text = elm_type_application "List" elem_type;
      decoder_text = "(D.list " ^ wrap_decoder_arg elem_decoder ^ ")" }
  | Ir.IRRetMaybeSetForAll { elem_ty; proof } ->
    let elem_type = elm_type_with_proof_ir elem_ty (Some proof) in
    let list_type = elm_type_application "List" elem_type in
    let elem_decoder = decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder elem_ty (Some proof) in
    { type_text = elm_type_application "Maybe" list_type;
      decoder_text = "(D.maybe (D.list " ^ wrap_decoder_arg elem_decoder ^ "))" }
  | Ir.IRRetForAllDictValues { key_ty = Ir.IRString; val_ty; proof } ->
    let value_type = elm_type_with_proof_ir val_ty (Some proof) in
    let value_decoder = decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder val_ty (Some proof) in
    { type_text = "Dict String " ^ elm_type_text_arg value_type;
      decoder_text = "(D.dict " ^ wrap_decoder_arg value_decoder ^ ")" }
  | Ir.IRRetForAllDictValues { key_ty; val_ty; proof } ->
    let key_decoder = decode_expr_of_ir_type key_ty in
    let value_decoder = decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder val_ty (Some proof) in
    { type_text = elm_type_application "List"
        (Printf.sprintf "( %s, %s )" (elm_type_of_ir_type key_ty) (elm_type_with_proof_ir val_ty (Some proof)));
      decoder_text = "(D.list " ^ tuple2_decoder key_decoder value_decoder ^ ")" }
  | Ir.IRRetForAllDictKeys { key_ty; val_ty; proof } ->
    let key_decoder = decode_expr_of_annotated_ir_type ~fact_kind_of ~has_fact_decoder key_ty (Some proof) in
    let value_decoder = decode_expr_of_ir_type val_ty in
    { type_text = elm_type_application "List"
        (Printf.sprintf "( %s, %s )" (elm_type_with_proof_ir key_ty (Some proof)) (elm_type_of_ir_type val_ty));
      decoder_text = "(D.list " ^ tuple2_decoder key_decoder value_decoder ^ ")" }
  | Ir.IRRetExists { body; _ } -> return_info_ir ~fact_kind_of ~has_fact_decoder body

let elm_url_expr_ir ?(rename_param = fun name -> name) (ep : Ir.ir_endpoint) : string =
  let capture_exprs = List.map (fun (c : Ir.ir_capture) ->
    let local_name = rename_param c.irc_binding.irb_name in
    let expr = match c.irc_binding.irb_proof with
      | None -> local_name
      | Some _ -> "exorcise " ^ local_name
    in
    (c.irc_binding.irb_name, expr)
  ) ep.ire_captures in
  let lookup_capture param =
    match List.find_opt (fun (name, _) -> name = param) capture_exprs with
    | Some (_, expr) -> expr
    | None -> "\"" ^ param ^ "\""
  in
  let segs = List.filter (fun s -> s <> "") (String.split_on_char '/' ep.ire_path) in
  let real_parts = List.map (fun seg ->
    if String.length seg > 0 && seg.[0] = ':' then
      lookup_capture (String.sub seg 1 (String.length seg - 1))
    else
      "\"" ^ seg ^ "\""
  ) segs in
  let with_slashes = List.concat_map (fun p -> ["\"/\""; p]) real_parts in
  match with_slashes with
  | [] -> "\"/\""
  | _ -> String.concat " ++ " with_slashes

(* ── URL builder ─────────────────────────────────────────────────────────── *)

let elm_url_expr (ep : api_endpoint) : string =
  let capture_exprs = List.map (fun (c : api_capture) ->
    let expr = match c.binding.proof_ann with
      | None -> c.binding.name
      | Some _ -> "exorcise " ^ c.binding.name
    in
    (c.binding.name, expr)
  ) ep.captures in
  let lookup_capture param =
    match List.find_opt (fun (name, _) -> name = param) capture_exprs with
    | Some (_, expr) -> expr
    | None -> "\"" ^ param ^ "\""
  in
  let segs = List.filter (fun s -> s <> "") (String.split_on_char '/' ep.path) in
  let real_parts = List.map (fun seg ->
    if String.length seg > 0 && seg.[0] = ':' then
      lookup_capture (String.sub seg 1 (String.length seg - 1))
    else
      "\"" ^ seg ^ "\""
  ) segs in
  let with_slashes = List.concat_map (fun p -> ["\"/\""; p]) real_parts in
  match with_slashes with
  | [] -> "\"/\""
  | _ -> String.concat " ++ " with_slashes

(* ── Proof usage scan ────────────────────────────────────────────────────── *)

let option_exists f = function
  | Some x -> f x
  | None -> false

let rec return_has_proof = function
  | RetPlain _ -> false
  | RetAttached { binding; _ } -> binding.proof_ann <> None
  | RetNamedPack { entity_proof; other_proof; _ } -> entity_proof <> None || other_proof <> None
  | RetForAll _ | RetMaybeForAll _ | RetSetForAll _ | RetMaybeSetForAll _
  | RetForAllDictValues _ | RetForAllDictKeys _ -> true
  | RetMaybeAttached { binding; _ } -> binding.proof_ann <> None
  | RetExists { body; _ } -> return_has_proof body

let decl_uses_proofs = function
  | DFact _ -> true
  | DRecord r -> List.exists (fun (f : field_def) -> f.proof_ann <> None) r.fields
  | DEntity e -> List.exists (fun (f : field_def) -> f.proof_ann <> None) e.fields
  | DType (TypeAdt { variants; _ }) ->
    List.exists (fun (v : adt_variant) -> List.exists (fun (f : field_def) -> f.proof_ann <> None) v.fields) variants
  | DApi api ->
    List.exists (fun (ep : api_endpoint) ->
      option_exists (fun (a : api_auth) -> a.binding.proof_ann <> None) ep.auth
      || option_exists (fun (b : binding) -> b.proof_ann <> None) (ep_body ep)
      || List.exists (fun (c : api_capture) -> c.binding.proof_ann <> None) ep.captures
      || return_has_proof (ep_return_spec ep)
    ) api.endpoints
  | _ -> false

let rec ir_type_uses_elm_dict = function
  | Ir.IRDict (Ir.IRString, value) -> true || ir_type_uses_elm_dict value
  | Ir.IRList ty
  | Ir.IRMaybe ty
  | Ir.IRSet ty -> ir_type_uses_elm_dict ty
  | Ir.IRDict (key, value)
  | Ir.IRResult (key, value)
  | Ir.IREither (key, value)
  | Ir.IRFun (key, value) -> ir_type_uses_elm_dict key || ir_type_uses_elm_dict value
  | Ir.IRTuple elems -> List.exists ir_type_uses_elm_dict elems
  | _ -> false

let rec ir_return_uses_elm_dict = function
  | Ir.IRRetPlain ty -> ir_type_uses_elm_dict ty
  | Ir.IRRetAttached binding -> ir_type_uses_elm_dict binding.irb_type
  | Ir.IRRetNamedPack { ty; _ } -> ir_type_uses_elm_dict ty
  | Ir.IRRetForAll { elem_ty; _ }
  | Ir.IRRetMaybeForAll { elem_ty; _ }
  | Ir.IRRetSetForAll { elem_ty; _ }
  | Ir.IRRetMaybeSetForAll { elem_ty; _ } -> ir_type_uses_elm_dict elem_ty
  | Ir.IRRetForAllDictValues { key_ty; val_ty; _ }
  | Ir.IRRetForAllDictKeys { key_ty; val_ty; _ } -> ir_type_uses_elm_dict (Ir.IRDict (key_ty, val_ty))
  | Ir.IRRetExists { binding; body } -> ir_type_uses_elm_dict binding.irb_type || ir_return_uses_elm_dict body

let ir_endpoint_uses_elm_dict (ep : Ir.ir_endpoint) =
  option_exists (fun (b : Ir.ir_binding) -> ir_type_uses_elm_dict b.irb_type) ep.ire_auth
  || option_exists (fun (b : Ir.ir_binding) -> ir_type_uses_elm_dict b.irb_type) ep.ire_body
  || List.exists (fun (c : Ir.ir_capture) -> ir_type_uses_elm_dict c.irc_binding.irb_type) ep.ire_captures
  || ir_return_uses_elm_dict ep.ire_return

let format_elm_exports items =
  match Ir.dedupe_preserving_order items with
  | [] -> "(..)"
  | xs -> "
    ( " ^ String.concat "
    , " xs ^ "
    )"

(* ── Generator ───────────────────────────────────────────────────────────── *)

let emit_elm ?module_name_override (m : module_form) : string =
  let buf = Buffer.create 4096 in
  let add s = Buffer.add_string buf s in
  let addf fmt = Printf.bprintf buf fmt in

  let fact_names_ordered = List.filter_map (function
    | DFact ff -> Some ff.name
    | _ -> None
  ) m.decls in
  let fact_decls : (string, fact_form) Hashtbl.t = Hashtbl.create 8 in
  List.iter (function DFact fd -> Hashtbl.replace fact_decls fd.name fd | _ -> ()) m.decls;
  let establish_fns = collect_establish_fns m.decls in
  let fact_kind_tbl : (string, elm_fact_kind) Hashtbl.t = Hashtbl.create 8 in
  let has_fact_decoder fact_name = Hashtbl.mem fact_decls fact_name in
  let fact_kind_of fact_name =
    match Hashtbl.find_opt fact_kind_tbl fact_name with
    | Some kind -> kind
    | None ->
      let kind = classify_fact fact_name ~fact_decls ~establish_fns ~decls:m.decls in
      Hashtbl.replace fact_kind_tbl fact_name kind;
      kind
  in
  let uses_refinement_proofs = List.exists decl_uses_proofs m.decls in
  let ir_module = Ir.module_to_ir m in
  let endpoints_use_elm_dict = List.exists ir_endpoint_uses_elm_dict ir_module.Ir.irm_endpoints in

  (* ── Module header ── *)
  let builtin_proof_exports =
    if uses_refinement_proofs then ["ForAll"; "ForAllValues"; "ForAllKeys"] else []
  in
  let newtype_exports = List.filter_map (function
    | DType (TypeNewtype { name; _ })
    | DType (TypeAlias { name; _ }) -> Some [name; decoder_fn_name name; encoder_fn_name name]
    | _ -> None
  ) m.decls |> List.concat in
  let fact_exports = List.filter_map (function
    | DFact fd ->
      let kind = fact_kind_of fd.name in
      let base = [fd.name; fact_decoder_name fd.name] in
      Some (match kind with
        | FkElmSmart _ | FkElmHelper _ -> base @ [smart_constructor_name fd.name]
        | FkAuth _ | FkServerOnly _ -> base)
    | _ -> None
  ) m.decls |> List.concat in
  let adt_exports = List.filter_map (function
    | DType (TypeAdt { name; _ }) -> Some [name ^ "(..)"; decoder_fn_name name; encoder_fn_name name]
    | _ -> None
  ) m.decls |> List.concat in
  let record_exports = List.filter_map (function
    | DRecord r -> Some [r.name; decoder_fn_name r.name; encoder_fn_name r.name]
    | _ -> None
  ) m.decls |> List.concat in
  let entity_exports = List.filter_map (function
    | DEntity e -> Some [e.name; decoder_fn_name e.name]
    | _ -> None
  ) m.decls |> List.concat in
  let endpoint_exports = List.map (fun (ep : Ir.ir_endpoint) -> fn_name_of_endpoint ep.ire_method ep.ire_path) ir_module.Ir.irm_endpoints in
  let reserved_param_names = builtin_proof_exports @ newtype_exports @ fact_exports @ record_exports @ entity_exports @ endpoint_exports in
  let elm_module_name = match module_name_override with Some name -> name | None -> m.module_name in
  addf "module %s exposing%s
" elm_module_name
    (format_elm_exports (builtin_proof_exports @ newtype_exports @ fact_exports @ adt_exports @ record_exports @ entity_exports @ endpoint_exports));
  let source_base = Filename.basename m.source_file in
  addf "{- Generated by tesl generate elm from %s — experimental client generation, do not edit by hand -}

" source_base;

  (* A check whose predicate can't be inlined delegates to a user-managed
     `ApiHelpers.<check>`. Only import ApiHelpers when at least one such check
     exists, so projects with only inlinable checks never have to create the
     module (issue #13). *)
  let uses_api_helpers =
    List.exists (function
      | DFact fd -> (match fact_kind_of fd.name with FkElmHelper _ -> true | _ -> false)
      | _ -> false) m.decls
  in
  (* ── Imports ── *)
  add "import Http\n";
  add "import Json.Decode as D\n";
  add "import Json.Encode as E\n";
  if endpoints_use_elm_dict then
    add "import Dict exposing (Dict)\n";
  if uses_refinement_proofs then
    add "import RefinementProofs.Theory exposing (Proven, axiom, exorcise, And, and)\n";
  if uses_api_helpers then begin
    add "\n";
    add "{- This client references ApiHelpers.<check> : <base> -> Bool for each `check`\n";
    add "   whose predicate calls a helper fn (not inlinable). Provide an ApiHelpers.elm\n";
    add "   module implementing them, kept in sync with the Tesl checks. The server\n";
    add "   re-validates, so ApiHelpers is a client-side convenience, not a trust point. -}\n";
    add "import ApiHelpers\n"
  end;
  add "\n\n";
  if uses_refinement_proofs then begin
    add "type ForAll p\n    = ForAll\n\n";
    add "type ForAllValues p\n    = ForAllValues\n\n";
    add "type ForAllKeys p\n    = ForAllKeys\n\n"
  end;

  (* ── Newtypes ── *)
  let newtypes = List.filter_map (function
    | DType (TypeNewtype { name; base_type; _ }) -> Some (name, base_type)
    | DType (TypeAlias  { name; base_type; _ }) -> Some (name, base_type)
    | _ -> None
  ) m.decls in

  if newtypes <> [] then begin
    add "-- ---------------------------------------------------------------------------\n";
    add "-- Newtypes\n";
    add "-- ---------------------------------------------------------------------------\n\n";
    List.iter (fun (name, base_type) ->
      let elm_base = elm_type_of_type_expr base_type in
      addf "type alias %s =\n    %s\n\n" name elm_base;
      let base_dec = decode_expr_of_type base_type in
      addf "%s : D.Decoder %s\n" (decoder_fn_name name) name;
      addf "%s =\n    %s\n\n" (decoder_fn_name name) base_dec;
      addf "%s : %s -> E.Value\n" (encoder_fn_name name) name;
      addf "%s value =\n    %s\n\n" (encoder_fn_name name) (encode_expr_of_type base_type "value")
    ) newtypes
  end;

  (* ── Facts ── *)
  if fact_names_ordered <> [] then begin
    add "-- ---------------------------------------------------------------------------\n";
    add "-- Facts\n";
    add "-- ---------------------------------------------------------------------------\n\n";
    List.iter (fun fact_name ->
      let kind = fact_kind_of fact_name in
      let base_type = match kind with
        | FkElmSmart { base_type; _ }
        | FkElmHelper { base_type; _ }
        | FkAuth { base_type; _ }
        | FkServerOnly { base_type; _ } -> base_type
      in
      let elm_base = elm_type_of_type_expr base_type in
      addf "type %s\n    = %s\n\n" fact_name fact_name;
      (match kind with
       | FkElmSmart { constraints; _ } ->
         let smart_name = smart_constructor_name fact_name in
         let conditions = match all_elm_conditions "input" constraints with
           | Some xs -> xs
           | None -> []
         in
         addf "%s : %s -> Maybe (Proven %s %s)\n" smart_name elm_base elm_base fact_name;
         addf "%s input =\n" smart_name;
         if conditions = [] then
           addf "    Just (axiom %s input)\n\n" fact_name
         else begin
           addf "    if %s then\n" (String.concat " && " conditions);
           addf "        Just (axiom %s input)\n" fact_name;
           add "    else\n";
           add "        Nothing\n\n"
         end;
         addf "%s : D.Decoder (Proven %s %s)\n" (fact_decoder_name fact_name) elm_base fact_name;
         addf "%s =\n" (fact_decoder_name fact_name);
         addf "    %s\n" (decode_expr_of_type base_type);
         add "        |> D.andThen\n";
         add "            (\\v ->\n";
         addf "                case %s v of\n" smart_name;
         add "                    Just x ->\n";
         add "                        D.succeed x\n";
         add "                    Nothing ->\n";
         addf "                        D.fail %S\n            )\n\n" ("Failed proof: " ^ fact_name)
       | FkElmHelper { checker; _ } ->
         (* The check's predicate calls a Tesl helper fn we can't inline into Elm.
            Emit the smart constructor + decoder, delegating the predicate to a
            user-provided `ApiHelpers.<check> : <base> -> Bool`. If it is missing,
            `elm make` fails loudly (issue #13) instead of the generator silently
            dropping the constructor. The user keeps ApiHelpers in sync with the
            Tesl check; the server remains authoritative, so a divergence is only a
            UX issue, never a soundness hole. *)
         let smart_name = smart_constructor_name fact_name in
         addf "%s : %s -> Maybe (Proven %s %s)\n" smart_name elm_base elm_base fact_name;
         addf "%s input =\n" smart_name;
         addf "    if ApiHelpers.%s input then\n" checker;
         addf "        Just (axiom %s input)\n" fact_name;
         add "    else\n";
         add "        Nothing\n\n";
         addf "%s : D.Decoder (Proven %s %s)\n" (fact_decoder_name fact_name) elm_base fact_name;
         addf "%s =\n" (fact_decoder_name fact_name);
         addf "    %s\n" (decode_expr_of_type base_type);
         add "        |> D.andThen\n";
         add "            (\\v ->\n";
         addf "                case %s v of\n" smart_name;
         add "                    Just x ->\n";
         add "                        D.succeed x\n";
         add "                    Nothing ->\n";
         addf "                        D.fail %S\n            )\n\n" ("Failed proof: " ^ fact_name)
       | FkAuth _ | FkServerOnly _ ->
         addf "%s : D.Decoder (Proven %s %s)\n" (fact_decoder_name fact_name) elm_base fact_name;
         addf "%s =\n" (fact_decoder_name fact_name);
         addf "    %s\n" (decode_expr_of_type base_type);
         addf "        |> D.map (axiom %s)\n\n" fact_name)
    ) fact_names_ordered
  end;

  (* ── ADTs ── *)
  let adts = List.filter_map (function
    | DType (TypeAdt { name; variants; _ }) -> Some (name, variants)
    | _ -> None
  ) m.decls in

  if adts <> [] then begin
    add "-- ---------------------------------------------------------------------------\n";
    add "-- ADTs\n";
    add "-- ---------------------------------------------------------------------------\n\n";
    List.iter (fun (name, variants) ->
      addf "type %s\n" name;
      List.iteri (fun i (v : adt_variant) ->
        let prefix = if i = 0 then "    = " else "    | " in
        if v.fields = [] then
          addf "%s%s\n" prefix v.ctor
        else begin
          let field_types = String.concat " "
            (List.map (fun (f : field_def) ->
               let ty = elm_type_with_proof f.type_expr f.proof_ann in
               if String.contains ty ' ' then "(" ^ ty ^ ")" else ty
             ) v.fields) in
          addf "%s%s %s\n" prefix v.ctor field_types
        end
      ) variants;
      add "\n";

      let dec_name = decoder_fn_name name in
      addf "%s : D.Decoder %s\n" dec_name name;
      addf "%s =\n" dec_name;
      add "    D.field \"tag\" D.string\n";
      add "        |> D.andThen\n";
      add "            (\\tag ->\n";
      add "                case tag of\n";
      List.iter (fun (v : adt_variant) ->
        addf "                    %S ->\n" v.ctor;
        if v.fields = [] then
          addf "                        D.succeed %s\n\n" v.ctor
        else begin
          let field = List.hd v.fields in
          addf "                        D.map %s (D.field \"value\" %s)\n\n"
            v.ctor (decode_expr_of_annotated_type ~fact_kind_of ~has_fact_decoder field.type_expr field.proof_ann)
        end
      ) variants;
      add "                    _ ->\n";
      addf "                        D.fail (\"Unknown %s tag: \" ++ tag)\n" name;
      add "            )\n\n";

      let enc_name = encoder_fn_name name in
      addf "%s : %s -> E.Value\n" enc_name name;
      addf "%s value =\n" enc_name;
      add "    case value of\n";
      List.iter (fun (v : adt_variant) ->
        if v.fields = [] then begin
          addf "        %s ->\n" v.ctor;
          addf "            E.object [ ( \"tag\", E.string %S ) ]\n" v.ctor
        end else begin
          let field = List.hd v.fields in
          addf "        %s f0 ->\n" v.ctor;
          addf "            E.object [ ( \"tag\", E.string %S ), ( \"value\", %s ) ]\n"
            v.ctor (encode_expr_of_annotated_type field.type_expr field.proof_ann "f0")
        end
      ) variants;
      add "\n"
    ) adts
  end;

  (* ── Records ── *)
  let records = List.filter_map (function
    | DRecord r -> Some r
    | _ -> None
  ) m.decls in

  if records <> [] then begin
    add "-- ---------------------------------------------------------------------------\n";
    add "-- Records\n";
    add "-- ---------------------------------------------------------------------------\n\n";
    List.iter (fun (r : record_form) ->
      addf "type alias %s =\n" r.name;
      List.iteri (fun i (f : field_def) ->
        let prefix = if i = 0 then "    { " else "    , " in
        addf "%s%s : %s\n" prefix f.name (elm_type_with_proof f.type_expr f.proof_ann)
      ) r.fields;
      add "    }\n\n";

      let dec_name = decoder_fn_name r.name in
      addf "%s : D.Decoder %s\n" dec_name r.name;
      addf "%s =\n    %s\n\n" dec_name (decoder_for_fields ~fact_kind_of ~has_fact_decoder r.name r.fields);

      let enc_name = encoder_fn_name r.name in
      addf "%s : %s -> E.Value\n" enc_name r.name;
      addf "%s rec =\n" enc_name;
      add "    E.object\n";
      add "        [ ";
      List.iteri (fun i (f : field_def) ->
        let prefix = if i = 0 then "" else "        , " in
        addf "%s( %S, %s )\n" prefix f.name (encode_expr_of_annotated_type f.type_expr f.proof_ann ("rec." ^ f.name))
      ) r.fields;
      add "        ]\n\n"
    ) records
  end;

  (* ── Entities ── *)
  let entities = List.filter_map (function
    | DEntity e -> Some e
    | _ -> None
  ) m.decls in

  if entities <> [] then begin
    add "-- ---------------------------------------------------------------------------\n";
    add "-- Entity types (server-sourced)\n";
    add "-- ---------------------------------------------------------------------------\n\n";
    List.iter (fun (e : entity_form) ->
      addf "type alias %s =\n" e.name;
      List.iteri (fun i (f : field_def) ->
        let prefix = if i = 0 then "    { " else "    , " in
        addf "%s%s : %s\n" prefix f.name (elm_type_with_proof f.type_expr f.proof_ann)
      ) e.fields;
      add "    }\n\n";

      let dec_name = decoder_fn_name e.name in
      addf "%s : D.Decoder %s\n" dec_name e.name;
      addf "%s =\n    %s\n\n" dec_name (decoder_for_fields ~fact_kind_of ~has_fact_decoder e.name e.fields)
    ) entities
  end;

  (* ── API ── *)
  let endpoints = ir_module.Ir.irm_endpoints in

  if endpoints <> [] then begin
    add "-- ---------------------------------------------------------------------------\n";
    add "-- API\n";
    add "-- ---------------------------------------------------------------------------\n\n";
    List.iter (fun (ep : Ir.ir_endpoint) ->
      let fn_name = fn_name_of_endpoint ep.ire_method ep.ire_path in
      let fresh_param_name =
        let used = ref [] in
        fun base ->
          let rec freshened i =
            let candidate = if i = 0 then base ^ "Arg" else Printf.sprintf "%sArg%d" base i in
            if List.mem candidate reserved_param_names || List.mem candidate !used then freshened (i + 1)
            else (used := candidate :: !used; candidate)
          in
          if List.mem base reserved_param_names || List.mem base !used then
            freshened 0
          else (used := base :: !used; base)
      in
      let ret = return_info_ir ~fact_kind_of ~has_fact_decoder ep.ire_return in

      let capture_params = List.map (fun (c : Ir.ir_capture) ->
        let local_name = fresh_param_name c.irc_binding.irb_name in
        (c.irc_binding.irb_name, local_name, elm_type_of_ir_binding_surface c.irc_binding.irb_type c.irc_binding.irb_proof)
      ) ep.ire_captures in
      let body_param = match ep.ire_body with
        | None -> None
        | Some b ->
          let local_name = fresh_param_name b.irb_name in
          Some (b.irb_name, local_name, b.irb_type, b.irb_proof)
      in
      let rename_param name =
        match List.find_opt (fun (original, _, _) -> original = name) capture_params with
        | Some (_, local_name, _) -> local_name
        | None ->
          (match body_param with
           | Some (original, local_name, _, _) when original = name -> local_name
           | _ -> name)
      in
      let url_expr = elm_url_expr_ir ~rename_param ep in

      let param_types = List.map (fun (_, _, ty) -> ty) capture_params
        @ (match body_param with Some (_, _, ty, proof_ann) -> [elm_type_of_ir_binding_surface ty proof_ann] | None -> [])
        @ [Printf.sprintf "(Result Http.Error %s -> msg) -> Cmd msg" (elm_result_type_arg ret.type_text)]
      in
      addf "%s : %s
" fn_name (String.concat " -> " param_types);

      let param_names = List.map (fun (_, local_name, _) -> local_name) capture_params
        @ (match body_param with Some (_, local_name, _, _) -> [local_name] | None -> [])
        @ ["toMsg"]
      in
      addf "%s %s =
" fn_name (String.concat " " param_names);

      (match ep.ire_method with
       | GET ->
         add "    Http.get\n";
         addf "        { url = %s\n" url_expr;
         addf "        , expect = Http.expectJson toMsg %s\n" ret.decoder_text;
         add "        }\n"
       | POST ->
         let body_enc = match body_param with
           | Some (_, bname, bty, proof_ann) -> Printf.sprintf "Http.jsonBody (%s)" (encode_expr_of_ir_binding_surface bty proof_ann bname)
           | None -> "Http.emptyBody"
         in
         add "    Http.post\n";
         addf "        { url = %s\n" url_expr;
         addf "        , body = %s\n" body_enc;
         addf "        , expect = Http.expectJson toMsg %s\n" ret.decoder_text;
         add "        }\n"
       | _ ->
         let meth = method_upper ep.ire_method in
         let body_enc = match body_param with
           | Some (_, bname, bty, proof_ann) -> Printf.sprintf "Http.jsonBody (%s)" (encode_expr_of_ir_binding_surface bty proof_ann bname)
           | None -> "Http.emptyBody"
         in
         add "    Http.request\n";
         addf "        { method = %S\n" meth;
         add "        , headers = []\n";
         addf "        , url = %s\n" url_expr;
         addf "        , body = %s\n" body_enc;
         addf "        , expect = Http.expectJson toMsg %s\n" ret.decoder_text;
         add "        , timeout = Nothing\n";
         add "        , tracker = Nothing\n";
         add "        }\n");
      add "\n"
    ) endpoints
  end;

  Buffer.contents buf
