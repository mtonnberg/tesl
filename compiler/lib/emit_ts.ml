(** TypeScript + Zod code generator.

    Converts a typed [Ast.module_form] to TypeScript source code with
    Zod schema validation.  The output is intended to be used as a
    type-safe HTTP client in a browser or Node.js application.

    Reference format: see example/frontend-ts/src/todo-api-client.ts *)

open Ast

(* ── String helpers ──────────────────────────────────────────────────────── *)

let lowercase_first s =
  if String.length s = 0 then s
  else String.make 1 (Char.lowercase_ascii s.[0]) ^ String.sub s 1 (String.length s - 1)

(** CamelCase → snake_case: "ValidPort" → "valid_port" *)
let snake_case s =
  let buf = Buffer.create (String.length s) in
  String.iteri (fun i c ->
    if i > 0 && c >= 'A' && c <= 'Z' then begin
      Buffer.add_char buf '_';
      Buffer.add_char buf (Char.lowercase_ascii c)
    end else
      Buffer.add_char buf (Char.lowercase_ascii c)
  ) s;
  Buffer.contents buf

let fact_unique_field name = "__tesl_" ^ snake_case name

(** Capitalise a path segment, handling kebab-case: "list-test" → "ListTest" *)
let capitalize_segment s =
  let parts = String.split_on_char '-' s in
  String.concat "" (List.map (fun p ->
    if String.length p = 0 then ""
    else String.make 1 (Char.uppercase_ascii p.[0]) ^ String.sub p 1 (String.length p - 1)
  ) parts)

let method_str = function
  | GET -> "GET" | POST -> "POST" | PUT -> "PUT" | DELETE -> "DELETE"
  | PATCH -> "PATCH" | SSE -> "SSE"

let method_lower = function
  | GET -> "get" | POST -> "post" | PUT -> "put" | DELETE -> "delete"
  | PATCH -> "patch" | SSE -> "sse"

(** Derive the client function name from HTTP method + path.
    E.g. GET /todos/:todoId → "getTodos" *)
let fn_name_of_endpoint meth path =
  let segs = List.filter (fun s -> s <> "" && (String.length s = 0 || s.[0] <> ':'))
               (String.split_on_char '/' path) in
  let capitalized = List.map capitalize_segment segs in
  method_lower meth ^ String.concat "" capitalized

(** Replace :param placeholders in path with ${param} template literals. *)
let path_to_template path =
  let segs = String.split_on_char '/' path in
  let replaced = List.map (fun s ->
    if String.length s > 0 && s.[0] = ':' then
      "${" ^ String.sub s 1 (String.length s - 1) ^ "}"
    else s
  ) segs in
  String.concat "/" replaced

(* ── Zod type mapping ────────────────────────────────────────────────────── *)

(* Money arrives as {"minorUnits": <int>, "currency": "<ISO>"} over bare HTTP,
   but the agent-facing boundary ADDITIONALLY includes "display".  Accept BOTH
   (optional display), normalized to the bare {minorUnits, currency} shape so
   the TS-side type stays stable (mirrors the PosixMillis tolerant decoder). *)
let money_zod_schema =
  "z.object({ minorUnits: z.number().int(), currency: z.string(), display: z.string().optional() }).transform((v) => ({ minorUnits: v.minorUnits, currency: v.currency }))"

let money_ts_type = "{ minorUnits: number; currency: string }"

(** Map a Tesl type_expr to a Zod schema expression.
    [fact_schemas] is the set of fact names that have generated Zod schemas. *)
let rec zod_of_ir_type (fact_schemas : (string, unit) Hashtbl.t) (ty : Ir.ir_type) =
  match ty with
  | Ir.IRString -> "z.string()"
  | Ir.IRInt -> "z.number().int()"
  | Ir.IRFloat -> "z.number()"
  | Ir.IRBool -> "z.boolean()"
  (* PosixMillis arrives as a bare epoch-millis integer over HTTP, but the
     agent-facing boundary renders it as {"epochMillis": <int>, "iso": "…"}
     (types.rkt agent enrichment).  Accept BOTH shapes, normalized to the bare
     integer so the TS-side type stays `number` (mirrors the Elm decoder). *)
  | Ir.IRPosixMillis ->
    "z.union([z.number().int(), z.object({ epochMillis: z.number().int() }).transform((v) => v.epochMillis)])"
  (* Money: tolerant of the agent-enriched shape (extra "display"), normalized
     to the bare {minorUnits, currency} HTTP shape. *)
  | Ir.IRMoney -> money_zod_schema
  | Ir.IRNamed name ->
    if Hashtbl.mem fact_schemas name then name ^ "Schema"
    else name ^ "Schema"
  | Ir.IRList arg ->
    "z.array(" ^ zod_of_ir_type fact_schemas arg ^ ")"
  | Ir.IRMaybe arg ->
    zod_of_ir_type fact_schemas arg ^ ".nullable()"
  | Ir.IRSet arg ->
    "z.array(" ^ zod_of_ir_type fact_schemas arg ^ ")"
  | Ir.IRDict (Ir.IRString, value) ->
    Printf.sprintf "z.record(z.string(), %s)" (zod_of_ir_type fact_schemas value)
  | Ir.IRDict (key, value) ->
    Printf.sprintf "z.array(z.tuple([%s, %s]))"
      (zod_of_ir_type fact_schemas key)
      (zod_of_ir_type fact_schemas value)
  | Ir.IRResult (ok, err) ->
    Printf.sprintf
      "z.discriminatedUnion(\"tag\", [z.object({ tag: z.literal(\"Ok\"), value: %s }), z.object({ tag: z.literal(\"Err\"), error: %s })])"
      (zod_of_ir_type fact_schemas ok)
      (zod_of_ir_type fact_schemas err)
  | Ir.IREither (left, right) ->
    Printf.sprintf
      "z.discriminatedUnion(\"tag\", [z.object({ tag: z.literal(\"Left\"), value: %s }), z.object({ tag: z.literal(\"Right\"), value: %s })])"
      (zod_of_ir_type fact_schemas left)
      (zod_of_ir_type fact_schemas right)
  | Ir.IRTuple elems ->
    "z.tuple([" ^ String.concat ", " (List.map (zod_of_ir_type fact_schemas) elems) ^ "])"
  | Ir.IRVar _
  | Ir.IRFun _
  | Ir.IROpaque _ -> "z.unknown()"

let zod_of_type_expr (fact_schemas : (string, unit) Hashtbl.t) te =
  zod_of_ir_type fact_schemas (Ir.ir_type_of_type_expr te)

(** Map a Tesl type to a TypeScript type name (not Zod). *)
let rec ts_type_of_ir_type (ty : Ir.ir_type) =
  match ty with
  | Ir.IRString -> "string"
  | Ir.IRInt -> "number"
  | Ir.IRFloat -> "number"
  | Ir.IRBool -> "boolean"
  | Ir.IRPosixMillis -> "number"
  | Ir.IRMoney -> money_ts_type
  | Ir.IRNamed name -> name
  | Ir.IRVar name -> name
  | Ir.IRList arg ->
    "Array<" ^ ts_type_of_ir_type arg ^ ">"
  | Ir.IRMaybe arg ->
    ts_type_of_ir_type arg ^ " | null"
  | Ir.IRSet arg ->
    "Array<" ^ ts_type_of_ir_type arg ^ ">"
  | Ir.IRDict (Ir.IRString, value) ->
    "Record<string, " ^ ts_type_of_ir_type value ^ ">"
  | Ir.IRDict (key, value) ->
    "Array<[" ^ ts_type_of_ir_type key ^ ", " ^ ts_type_of_ir_type value ^ "]>"
  | Ir.IRResult (ok, err) ->
    Printf.sprintf "{ tag: \"Ok\"; value: %s } | { tag: \"Err\"; error: %s }"
      (ts_type_of_ir_type ok)
      (ts_type_of_ir_type err)
  | Ir.IREither (left, right) ->
    Printf.sprintf "{ tag: \"Left\"; value: %s } | { tag: \"Right\"; value: %s }"
      (ts_type_of_ir_type left)
      (ts_type_of_ir_type right)
  | Ir.IRTuple elems ->
    "[" ^ String.concat ", " (List.map ts_type_of_ir_type elems) ^ "]"
  | Ir.IRFun _
  | Ir.IROpaque _ -> "unknown"

let ts_type_of_type_expr te =
  ts_type_of_ir_type (Ir.ir_type_of_type_expr te)

(** Base Zod schema string for a type name (primitive, not full expression). *)
let base_zod_schema_for_type name =
  match name with
  | "String" -> "z.string()"
  | "Int" | "Integer" -> "z.number().int()"
  | "Float" | "Real" -> "z.number()"
  | "Bool" -> "z.boolean()"
  (* Same tolerant shape as zod_of_ir_type: bare int (HTTP) OR the
     agent-enriched {"epochMillis": <int>, …} object. *)
  | "PosixMillis" ->
    "z.union([z.number().int(), z.object({ epochMillis: z.number().int() }).transform((v) => v.epochMillis)])"
  | "Money" -> money_zod_schema
  (* Dimensioned quantities (Length, Speed, … / canonical "§Q[…]") are a bare
     number on the wire. *)
  | name when Ir.is_quantity_type_name name -> "z.number()"
  | _ -> "z.string()"  (* fallback for unknown custom types *)

(* ── Constraint → Zod method ─────────────────────────────────────────────── *)

(** Try to map an ir_constraint to a Zod method string.
    Returns [None] if the constraint cannot be expressed in Zod. *)
let zod_of_constraint (c : Ir.ir_constraint) : string option =
  match c.op, c.fn_name with
  | "gte", "String.length" ->
    Some (Printf.sprintf ".min(%s)" c.value_json)
  | "lte", "String.length" ->
    Some (Printf.sprintf ".max(%s)" c.value_json)
  | "gt", "String.length" ->
    (try Some (Printf.sprintf ".min(%d)" (int_of_string c.value_json + 1))
     with Failure _ -> None)
  | "lt", "String.length" ->
    (try Some (Printf.sprintf ".max(%d)" (int_of_string c.value_json - 1))
     with Failure _ -> None)
  | "starts_with", "String.startsWith" ->
    Some (Printf.sprintf ".startsWith(%s)" c.value_json)
  | "gte", "value" ->
    Some (Printf.sprintf ".gte(%s)" c.value_json)
  | "lte", "value" ->
    Some (Printf.sprintf ".lte(%s)" c.value_json)
  | "gt", "value" ->
    Some (Printf.sprintf ".gt(%s)" c.value_json)
  | "lt", "value" ->
    Some (Printf.sprintf ".lt(%s)" c.value_json)
  | _ -> None  (* contains, regex, etc. → server-side only *)

(** Try to convert all constraints to Zod methods.
    Returns [Some methods] if ALL constraints are expressible, [None] otherwise. *)
let all_zod_constraints (constraints : Ir.ir_constraint list) : string list option =
  let rec go acc = function
    | [] -> Some (List.rev acc)
    | c :: rest ->
      (match zod_of_constraint c with
       | Some m -> go (m :: acc) rest
       | None -> None)
  in
  go [] constraints

(* ── Fact classification ─────────────────────────────────────────────────── *)

type fact_kind =
  | FkZodSchema of { checker : string; base_type : string; methods : string list }
    (** Check function with fully expressible constraints *)
  | FkAuth of { checker : string }
    (** Auth function — server-side *)
  | FkServerOnly of { checker : string option }
    (** Establish, complex check, or no function — server-side *)

(** Detect which fact an EstablishKind function establishes.
    Looks for return type [Maybe (Fact (FactName ...))] or
    [Maybe (FactName ...)] in the return spec. *)
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

(** Build a map: fact_name → establish_func_name, from EstablishKind functions. *)
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

(** Classify a fact by looking at the module declarations. *)
let classify_fact (fact_name : string)
    ~(establish_fns : (string, string) Hashtbl.t)
    ~(decls : top_decl list) : fact_kind =
  (* Priority: establish > auth > check with Zod > check without Zod > no checker *)
  if Hashtbl.mem establish_fns fact_name then
    FkServerOnly { checker = Some (Hashtbl.find establish_fns fact_name) }
  else begin
    (* Look for check/auth functions that produce this fact *)
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
       | AuthKind -> FkAuth { checker = func.name }
       | CheckKind ->
         let base_name = match func.params with
           | p :: _ -> p.name
           | [] -> "value"
         in
         (match Ir.extract_simple_constraints base_name func.body with
          | Some constraints ->
            (match all_zod_constraints constraints with
             | Some methods ->
               let base_type = match func.params with
                 | p :: _ -> Ir.type_expr_to_text p.type_expr
                 | [] -> "String"
               in
               FkZodSchema { checker = func.name; base_type; methods }
             | None -> FkServerOnly { checker = Some func.name })
          | None -> FkServerOnly { checker = Some func.name })
       | _ -> FkServerOnly { checker = Some func.name })
    | _ -> FkServerOnly { checker = None }
  end

(* ── Fact Zod schema set ─────────────────────────────────────────────────── *)

(** Build the set of fact names that will have a Zod schema generated. *)
let build_fact_schema_set
    ~(establish_fns : (string, string) Hashtbl.t)
    ~(decls : top_decl list)
    (fact_names : string list) : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 8 in
  List.iter (fun name ->
    match classify_fact name ~establish_fns ~decls with
    | FkZodSchema _ -> Hashtbl.replace tbl name ()
    | _ -> ()
  ) fact_names;
  tbl

(* ── Field Zod expression ────────────────────────────────────────────────── *)

(** Generate Zod schema expression for a record field. *)
let field_zod_expr
    ~(fact_schema_set : (string, unit) Hashtbl.t)
    ~(all_schema_set : (string, unit) Hashtbl.t)
    (field : field_def) : string =
  let proof_facts = Ir.proof_names_opt field.proof_ann in
  let zod_facts = List.filter (fun n -> Hashtbl.mem fact_schema_set n) proof_facts in
  match zod_facts with
  | [] ->
    (* No fact schemas — use base type *)
    zod_of_type_expr all_schema_set field.type_expr
  | first :: rest ->
    let first_schema = first ^ "Schema" in
    List.fold_left (fun acc n -> acc ^ ".and(" ^ n ^ "Schema)") first_schema rest

(* ── Return type helpers ─────────────────────────────────────────────────── *)

(** Extract the leaf return type and whether it's a list, from a return_spec. *)
let rec return_info (rs : return_spec) : type_expr * bool =
  match rs with
  | RetPlain { ty; _ } -> (ty, false)
  | RetAttached { binding; _ } -> (binding.type_expr, false)
  | RetNamedPack { ty; _ } -> (ty, false)
  | RetForAll { elem_ty; _ } ->
    (TApp { head = TName { name = "List"; loc = Location.dummy_loc "" };
            arg = elem_ty; loc = Location.dummy_loc "" }, true)
  | RetMaybeForAll { elem_ty; _ } ->
    (TApp { head = TName { name = "List"; loc = Location.dummy_loc "" };
            arg = elem_ty; loc = Location.dummy_loc "" }, true)
  | RetSetForAll { elem_ty; _ } ->
    (TApp { head = TName { name = "List"; loc = Location.dummy_loc "" };
            arg = elem_ty; loc = Location.dummy_loc "" }, true)
  | RetMaybeSetForAll { elem_ty; _ } ->
    (TApp { head = TName { name = "List"; loc = Location.dummy_loc "" };
            arg = elem_ty; loc = Location.dummy_loc "" }, true)
  | RetForAllDictValues { key_ty; val_ty; _ }
  | RetForAllDictKeys   { key_ty; val_ty; _ } ->
    (TApp { head = TApp { head = TName { name = "Dict"; loc = Location.dummy_loc "" };
                          arg = key_ty; loc = Location.dummy_loc "" };
            arg = val_ty; loc = Location.dummy_loc "" }, false)
  | RetMaybeAttached { outer_ty = Some ty; _ } -> (ty, false)
  | RetMaybeAttached { binding; _ } ->
    (TApp { head = TName { name = "Maybe"; loc = Location.dummy_loc "" };
            arg = binding.type_expr; loc = Location.dummy_loc "" }, false)
  | RetExists { body; _ } -> return_info body

(** Zod parse expression for a return type. *)
let zod_of_ir_binding_type ~(fact_schema_set : (string, unit) Hashtbl.t) (binding : Ir.ir_binding) =
  match Ir.first_fact_of_ir_binding binding with
  | Some fact when Hashtbl.mem fact_schema_set fact -> fact ^ "Schema"
  | _ -> zod_of_ir_type fact_schema_set binding.irb_type

let ts_type_of_ir_binding ~(fact_schema_set : (string, unit) Hashtbl.t) (binding : Ir.ir_binding) =
  match Ir.first_fact_of_ir_binding binding with
  | Some fact when Hashtbl.mem fact_schema_set fact -> Printf.sprintf "z.infer<typeof %sSchema>" fact
  | _ -> ts_type_of_ir_type binding.irb_type

let rec surface_ir_type_of_return = function
  | Ir.IRRetPlain ty -> Some ty
  | Ir.IRRetAttached _ -> None
  | Ir.IRRetNamedPack { ty; _ } -> Some ty
  | Ir.IRRetForAll { elem_ty; _ } -> Some (Ir.IRList elem_ty)
  | Ir.IRRetMaybeForAll { elem_ty; _ } -> Some (Ir.IRMaybe (Ir.IRList elem_ty))
  | Ir.IRRetSetForAll { elem_ty; _ } -> Some (Ir.IRSet elem_ty)
  | Ir.IRRetMaybeSetForAll { elem_ty; _ } -> Some (Ir.IRMaybe (Ir.IRSet elem_ty))
  | Ir.IRRetForAllDictValues { key_ty; val_ty; _ }
  | Ir.IRRetForAllDictKeys { key_ty; val_ty; _ } -> Some (Ir.IRDict (key_ty, val_ty))
  | Ir.IRRetExists { body; _ } -> surface_ir_type_of_return body

let ts_return_type_of_ir_return ~(fact_schema_set : (string, unit) Hashtbl.t) = function
  | Ir.IRRetAttached binding -> ts_type_of_ir_binding ~fact_schema_set binding
  | ret ->
    (match surface_ir_type_of_return ret with
     | Some ty -> ts_type_of_ir_type ty
     | None -> "unknown")

let parse_expr_for_schema schema ty_text =
  Printf.sprintf "%s.parse(await res.json()) as %s" schema ty_text

(** Zod parse expression for a return type. *)
let rec return_parse_expr_of_ir_return ~(fact_schema_set : (string, unit) Hashtbl.t) = function
  | Ir.IRRetAttached binding ->
    parse_expr_for_schema
      (zod_of_ir_binding_type ~fact_schema_set binding)
      (ts_type_of_ir_binding ~fact_schema_set binding)
  | Ir.IRRetExists { body; _ } ->
    return_parse_expr_of_ir_return ~fact_schema_set body
  | ret ->
    (match surface_ir_type_of_return ret with
     | Some ty -> parse_expr_for_schema (zod_of_ir_type fact_schema_set ty) (ts_type_of_ir_type ty)
     | None -> "await res.json()")

(* ── Generator ───────────────────────────────────────────────────────────── *)

let emit_ts (m : module_form) : string =
  let buf = Buffer.create 4096 in
  let add s = Buffer.add_string buf s in
  let addf fmt = Printf.bprintf buf fmt in

  (* ── Collect all fact names (in declaration order from DFact) ── *)
  let fact_names_ordered = List.filter_map (function
    | DFact ff -> Some ff.name
    | _ -> None
  ) m.decls in

  let establish_fns = collect_establish_fns m.decls in

  let fact_schema_set = build_fact_schema_set ~establish_fns ~decls:m.decls fact_names_ordered in

  (* all_schema_set: everything that has a schema (facts with Zod + all other types) *)
  let all_schema_set : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  Hashtbl.iter (fun k v -> Hashtbl.replace all_schema_set k v) fact_schema_set;

  (* ── Header ── *)
  let source_base = Filename.basename m.source_file in
  addf "// Generated by tesl generate ts from %s — experimental client generation, do not edit by hand\n" source_base;
  addf "// Module: %s\n" m.module_name;
  add "import { z } from \"zod\";\n";
  add "\n";

  (* ── Newtypes ── *)
  let newtypes = List.filter_map (function
    | DType (TypeNewtype { name; base_type; _ }) -> Some (name, base_type)
    | DType (TypeAlias  { name; base_type; _ }) -> Some (name, base_type)
    | _ -> None
  ) m.decls in

  if newtypes <> [] then begin
    add "// --- Newtypes ---\n\n";
    List.iter (fun (name, base_type) ->
      let base_schema = match base_type with
        | TName { name = "String"; _ } -> "z.string()"
        | TName { name = "Int" | "Integer"; _ } -> "z.number().int()"
        | TName { name = "Float" | "Real"; _ } -> "z.number()"
        | TName { name = "Bool"; _ } -> "z.boolean()"
        | TName { name = "Money"; _ } -> money_zod_schema
        | TName { name; _ } when Ir.is_quantity_type_name name -> "z.number()"
        | _ -> "z.string()"
      in
      addf "export const %sSchema = %s.brand<%S>();\n" name base_schema name;
      addf "export type %s = z.infer<typeof %sSchema>;\n\n" name name
    ) newtypes
  end;

  (* ── Facts ── *)
  if fact_names_ordered <> [] then begin
    add "// --- Facts ---\n\n";
    List.iter (fun fact_name ->
      let kind = classify_fact fact_name ~establish_fns ~decls:m.decls in
      (match kind with
       | FkZodSchema { checker; base_type; methods } ->
         addf "// Fact: %s — validated by `%s`\n" fact_name checker;
         let base_schema = base_zod_schema_for_type base_type in
         let methods_str = String.concat "" methods in
         addf "export const %sSchema = %s%s.brand<%S>();\n"
           fact_name base_schema methods_str fact_name;
         addf "export type %s = z.infer<typeof %sSchema>;\n\n" fact_name fact_name
       | FkAuth { checker } ->
         addf "// Fact: %s — set by auth `%s` (server-side only)\n" fact_name checker;
         addf "export type %s = { readonly %s: unique symbol };\n\n"
           fact_name (fact_unique_field fact_name)
       | FkServerOnly { checker = Some c } ->
         addf "// Fact: %s — established by `%s` (server-side only)\n" fact_name c;
         addf "export type %s = { readonly %s: unique symbol };\n\n"
           fact_name (fact_unique_field fact_name)
       | FkServerOnly { checker = None } ->
         addf "// Fact: %s (server-side only)\n" fact_name;
         addf "export type %s = { readonly %s: unique symbol };\n\n"
           fact_name (fact_unique_field fact_name))
    ) fact_names_ordered;
    add "\n"
  end;

  (* ── ADTs ── *)
  let adts = List.filter_map (function
    | DType (TypeAdt { name; variants; _ }) -> Some (name, variants)
    | _ -> None
  ) m.decls in

  if adts <> [] then begin
    add "// --- ADTs ---\n\n";
    List.iter (fun (name, variants) ->
      List.iter (fun (v : adt_variant) ->
        let fields_str =
          if v.fields = [] then ""
          else
            let field_parts = List.map (fun (f : field_def) ->
              Printf.sprintf ", %s: %s" f.name (zod_of_type_expr all_schema_set f.type_expr)
            ) v.fields in
            String.concat "" field_parts
        in
        addf "const _%s_%sSchema = z.object({ tag: z.literal(%S)%s });\n"
          name v.ctor v.ctor fields_str
      ) variants;
      let schema_list = String.concat ", "
        (List.map (fun (v : adt_variant) ->
           Printf.sprintf "_%s_%sSchema" name v.ctor) variants) in
      addf "export const %sSchema = z.discriminatedUnion(\"tag\", [%s]);\n" name schema_list;
      addf "export type %s = z.infer<typeof %sSchema>;\n\n" name name
    ) adts;
    add "\n"
  end;

  (* ── Human actions (agent → human handoff) ── *)
  (* Per server, a zod schema for the `human-action-request` descriptor the agent
     loop emits when it calls a `humanActions` tool it may NOT perform.  The
     discriminant `action` is a COMPILE-TIME allowlist (one literal per server
     endpoint tool name): an `action` the agent never had fails to parse, and the
     real endpoint URL comes from the generated client function the app calls per
     case — never from the wire.  `args` is the model's advisory prefill (pass it
     to the matching client fn, which validates it; the server re-checks auth).
     `handle` correlates the completed action to a resume-after turn. *)
  let ts_servers = List.filter_map (function
    | DServer (sv : server_form) -> Some sv
    | _ -> None
  ) m.decls in
  if ts_servers <> [] then begin
    add "// --- Human actions (agent -> human handoff) ---\n\n";
    List.iter (fun (sv : server_form) ->
      let tools = List.map fst sv.bindings in
      List.iter (fun tool ->
        addf "const _%sHumanAction_%sSchema = z.object({ action: z.literal(%S), handle: z.string(), args: z.unknown() });\n"
          sv.name tool tool
      ) tools;
      let schema_list = String.concat ", "
        (List.map (fun tool ->
           Printf.sprintf "_%sHumanAction_%sSchema" sv.name tool) tools) in
      addf "export const %sHumanActionRequestSchema = z.discriminatedUnion(\"action\", [%s]);\n"
        sv.name schema_list;
      addf "export type %sHumanActionRequest = z.infer<typeof %sHumanActionRequestSchema>;\n\n"
        sv.name sv.name
    ) ts_servers;
    add "\n"
  end;

  (* ── Records ── *)
  let records = List.filter_map (function
    | DRecord r -> Some r
    | _ -> None
  ) m.decls in

  if records <> [] then begin
    add "// --- Records ---\n\n";
    List.iter (fun (r : record_form) ->
      addf "export const %sSchema = z.object({\n" r.name;
      List.iter (fun (f : field_def) ->
        let schema = field_zod_expr ~fact_schema_set ~all_schema_set f in
        addf "  %s: %s,\n" f.name schema
      ) r.fields;
      add "});\n";
      addf "export type %s = z.infer<typeof %sSchema>;\n\n" r.name r.name
    ) records;
    add "\n"
  end;

  (* ── Entities ── *)
  let entities = List.filter_map (function
    | DEntity e -> Some e
    | _ -> None
  ) m.decls in

  if entities <> [] then begin
    add "// --- Entity response types ---\n\n";
    List.iter (fun (e : entity_form) ->
      addf "export const %sSchema = z.object({\n" e.name;
      List.iter (fun (f : field_def) ->
        let schema = zod_of_type_expr all_schema_set f.type_expr in
        addf "  %s: %s,\n" f.name schema
      ) e.fields;
      add "});\n";
      addf "export type %s = z.infer<typeof %sSchema>;\n\n" e.name e.name
    ) entities;
    add "\n"
  end;

  (* ── API client ── *)
  let ir_module = Ir.module_to_ir m in
  let endpoints = ir_module.Ir.irm_endpoints in

  if endpoints <> [] then begin
    add "// --- API client ---\n\n";
    add "let _teslBase = \"\";\n";
    add "export function configure(base: string): void { _teslBase = base; }\n\n";
    List.iter (fun (ep : Ir.ir_endpoint) ->
      let fn_name = fn_name_of_endpoint ep.ire_method ep.ire_path in
      let tmpl_path = path_to_template ep.ire_path in
      let use_template = String.contains tmpl_path '$' in

      (* Parameters: captures + body *)
      let param_parts = ref [] in
      List.iter (fun (cap : Ir.ir_capture) ->
        let ty = ts_type_of_ir_binding ~fact_schema_set cap.irc_binding in
        param_parts := Printf.sprintf "%s: %s" cap.irc_binding.irb_name ty :: !param_parts
      ) ep.ire_captures;
      let body_param = match ep.ire_body with
        | None -> None
        | Some b ->
          let ty = ts_type_of_ir_binding ~fact_schema_set b in
          Some (Printf.sprintf "%s: %s" b.irb_name ty)
      in
      (match body_param with Some p -> param_parts := !param_parts @ [p] | None -> ());

      let params_str = String.concat ", " (List.rev !param_parts) in
      let ts_ret = ts_return_type_of_ir_return ~fact_schema_set ep.ire_return in

      addf "export async function %s(%s): Promise<%s> {\n" fn_name params_str ts_ret;

      (* URL *)
      let url_expr =
        if use_template then
          Printf.sprintf "`${_teslBase}%s`" tmpl_path
        else
          Printf.sprintf "`${_teslBase}%s`" ep.ire_path
      in

      (* Fetch call *)
      let has_body = ep.ire_body <> None in
      let meth = method_str ep.ire_method in
      addf "  const res = await fetch(%s, {\n" url_expr;
      addf "    method: %S,\n" meth;
      add  "    credentials: \"include\",\n";
      if has_body then begin
        add "    headers: { \"Content-Type\": \"application/json\" },\n";
        let body_name = match ep.ire_body with Some b -> b.irb_name | None -> "body" in
        addf "    body: JSON.stringify(%s),\n" body_name
      end;
      add  "  });\n";
      addf "  if (!res.ok) throw new Error(`%s %s failed: ${res.status}`);\n"
        meth ep.ire_path;

      (* Parse response *)
      let parse_expr = return_parse_expr_of_ir_return ~fact_schema_set ep.ire_return in
      addf "  return %s;\n" parse_expr;
      add "}\n\n"
    ) endpoints
  end;

  Buffer.contents buf
