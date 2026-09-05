(** Typed, location-free migration nodes. Name resolution and the ordinary
    type/proof/capability gates are prerequisites, not replaced by this encoder.
    Missing types, unknown symbols and unlowered forms cannot disappear from a hash. *)
open Ast
open Migration_canonical

type namespace = Value | Type | Predicate | Codec
type symbol = Global of string | Primitive of string
type reference = namespace * symbol
type error = { loc : Location.loc; message : string }
type elaborated = { node : node; references : reference list }
type resolver = namespace -> string -> symbol option
type definition = {
  key : reference;
  aliases : reference list;
  body : elaborated;
  (* Reverse semantic dependencies: fact producers support predicates; codecs
     support their target types. This inventory includes private declarations. *)
  supports : reference list;
  (* Entity field contracts are projected by the same lowering as the complete
     declaration. They retain only that field's direct references; closure adds
     nested types, codecs and fact producers in the usual way. *)
  stored_fields : (string * elaborated) list;
}
exception Invalid of error

let tag name children = Seq (Bytes name :: children)
let natural n = Bytes (string_of_int n)
let option encode = function None -> tag "none" [] | Some x -> tag "some" [encode x]
let namespace = function Value -> "value" | Type -> "type" | Predicate -> "predicate" | Codec -> "codec"
let reject loc message = raise (Invalid { loc; message })
let require loc = function Ok x -> x | Error message -> reject loc message

(* The checker allocates type variables globally. Normalize by the final tree's
   left-to-right first occurrence, independent of host argument evaluation order. *)
let normalize_variables root =
  let inferred = ref [] and declared = ref [] in
  let variable table id =
    match List.assoc_opt id !table with
    | Some n -> natural n
    | None -> let n = List.length !table in table := (id, n) :: !table; natural n in
  let rec visit = function
    | Seq [Bytes "inferred-variable"; Bytes id] -> tag "variable" [variable inferred id]
    | Seq [Bytes "declared-variable"; Bytes id] -> tag "variable" [variable declared id]
    | Seq nodes -> Seq (List.map visit nodes)
    | Bytes _ as node -> node in
  visit root

let lower_declaration ~scopes ~(resolve : resolver) ~typed_nodes ~module_name decl =
  let loc = top_decl_loc decl in
  let binding_variables bs = List.concat_map (fun (b : binding) -> Checker.collect_tvar_names b.type_expr) bs in
  let abstract_types = match decl with
    | DFunc f ->
      let names = ref (binding_variables f.params @ Checker.collect_ret_spec_tvar_names f.return_spec) in
      Ast_visitor.iter (function
        | ELambda l -> names := binding_variables l.params @ !names
        | ELet {declared_type=Some t; _} -> names := Checker.collect_tvar_names t @ !names
        | _ -> ()) f.body;
      !names
    | DType (TypeAdt t) -> t.params
    | _ -> [] in
  let references = ref [] in
  let stored_fields = ref [] in
  let global ns symbol =
    references := (ns, symbol) :: !references;
    let identity = match symbol with
      | Global name -> require loc (Migration_canonical.reference scopes name)
      | Primitive name ->
        if name = "" then reject loc "empty primitive ABI tag";
        tag "primitive" [Bytes name] in
    tag "reference" [Bytes (namespace ns); identity] in
  let lookup ns name = match resolve ns name with
    | Some symbol -> global ns symbol
    | None -> reject loc ("unresolved " ^ namespace ns ^ " `" ^ name ^ "` in migration IR") in
  let own ns name = global ns (Global (module_name ^ "." ^ name)) in
  (* Lexical depth identifies binders; spelling and source positions do not. *)
  let bind env name = let id = List.length env in (name, id) :: env, tag "local" [natural id] in
  let local env name = Option.map (fun id -> tag "local" [natural id]) (List.assoc_opt name env) in
  let rec inferred_type = function
    | Type_system.TVar id -> tag "inferred-variable" [natural id]
    | Type_system.TCon name when List.mem name abstract_types -> tag "declared-variable" [Bytes name]
    | Type_system.TCon name -> tag "named" [lookup Type name]
    | Type_system.TApp (head, arg) -> tag "apply" [inferred_type head; inferred_type arg]
    | Type_system.TFun (dom, cod) -> tag "arrow" [inferred_type dom; inferred_type cod] in
  let rec surface_type env = function
    | TName n ->
      (match local env n.name with
       | Some subject -> tag "subject-type" [subject]
       | None -> tag "named" [lookup Type n.name])
    | TVar n -> tag "declared-variable" [Bytes n.name]
    | TApp t -> tag "apply" [surface_type env t.head; surface_type env t.arg]
    | TFun t ->
      if t.caps <> [] then reject t.loc "capability-bearing arrow in migration IR";
      tag "arrow" [surface_type env t.dom; surface_type env t.cod]
    | TTuple t -> tag "tuple" (List.map (surface_type env) t.elems) in
  let proof_argument env name =
    let raw = String.starts_with ~prefix:"*" name in
    let name = if raw then String.sub name 1 (String.length name - 1) else name in
    let parts = String.split_on_char '.' name in
    let result = match parts with
      | first :: fields when List.for_all Migration_canonical.identifier parts ->
        (match local env first with
         | Some subject -> tag "subject" [subject; Seq (List.map bytes fields)]
         | None -> lookup Predicate name)
      | _ -> reject loc ("proof argument requires structural lowering: `" ^ name ^ "`") in
    if raw then tag "raw" [result] else result in
  let rec proof env = function
    | PredApp p ->
      let predicate = match local env p.pred with Some local -> local | None -> lookup Predicate p.pred in
      tag "predicate" [predicate; Seq (List.map (proof_argument env) p.args)]
    | PredAnd p -> tag "and" [proof env p.left; proof env p.right] in
  let binding env (b : binding) =
    let env, id = bind env b.name in
    env, tag "binding" [id; surface_type env b.type_expr; option (proof env) b.proof_ann] in
  let bindings env bs =
    List.fold_left (fun (env, nodes) b -> let env, node = binding env b in env, nodes @ [node]) (env, []) bs in
  let rec return_spec env = function
    | RetPlain r -> tag "plain" [surface_type env r.ty]
    | RetAttached r -> let _, b = binding env r.binding in tag "attached" [b]
    | RetNamedPack r -> tag "pack" [surface_type env r.ty; option (proof env) r.entity_proof; option (proof env) r.other_proof]
    | RetForAll r -> tag "list-forall" [surface_type env r.elem_ty; proof env r.proof]
    | RetMaybeForAll r -> tag "maybe-list-forall" [surface_type env r.elem_ty; proof env r.proof]
    | RetSetForAll r -> tag "set-forall" [surface_type env r.elem_ty; proof env r.proof]
    | RetMaybeSetForAll r -> tag "maybe-set-forall" [surface_type env r.elem_ty; proof env r.proof]
    | RetForAllDictValues r -> tag "dict-values-forall" [surface_type env r.key_ty; surface_type env r.val_ty; proof env r.proof]
    | RetForAllDictKeys r -> tag "dict-keys-forall" [surface_type env r.key_ty; surface_type env r.val_ty; proof env r.proof]
    | RetMaybeAttached r -> let outer = option (surface_type env) r.outer_ty in
      let _, b = binding env r.binding in tag "maybe-attached" [outer; b]
    | RetExists r -> let env, b = binding env r.binding in tag "exists" [b; return_spec env r.body] in
  let binop = function
    | BAdd -> "add" | BSub -> "subtract" | BMul -> "multiply" | BDiv -> "divide" | BMod -> "modulo"
    | BConcat -> "concat" | BAnd -> "and" | BOr -> "or" | BEq -> "equal" | BNeq -> "not-equal"
    | BLt -> "less" | BLe -> "less-equal" | BGt -> "greater" | BGe -> "greater-equal" in
  let checked_type expression =
    let found = List.filter_map (fun (node, ty) -> if node == expression then Some ty else None) typed_nodes in
    match found with
    | [] -> reject (Checker.expr_loc expression) "expression is missing its checked type in migration IR"
    | first :: rest ->
      if not (List.for_all ((=) first) rest) then reject (Checker.expr_loc expression) "expression has conflicting checked types in migration IR";
      first in
  let type_of expression = inferred_type (checked_type expression) in
  let rec call_parts args = function
    | EApp a -> call_parts (a.arg :: args) a.fn
    | fn -> fn, args in
  let rec literal env = function
    | LInt n -> require loc (integer (string_of_int n))
    | LBigInt n -> require loc (integer n)
    | LFloat n -> require loc (float n)
    | LString s -> string s
    | LBool b -> bool b
    | LInterp segments -> tag "interpolate" (List.map (function
        | ILiteral s -> tag "text" [Bytes s]
        | IExpr e -> tag "value" [expression env e]) segments)
  and pattern env = function
    | PVar name -> let env, id = bind env name in env, tag "bind" [id]
    | PWild -> env, tag "wild" []
    | PNullary p -> env, tag "constructor" [lookup Value p.ctor; Seq []]
    | PLit p -> env, tag "literal" [literal env p.value]
    | PCon p ->
      let ctor = lookup Value p.ctor in
      (* PCon keys also contain positional binders' spellings. Both the checker
         and Go runtime consume these slots positionally, including brace syntax. *)
      let env, fields = List.fold_left (fun (env, fields) (_, p) ->
        let env, node = pattern env p in env, fields @ [node]) (env, []) p.fields in
      env, tag "constructor" [ctor; Seq fields]
  and expression env e =
    let ty = type_of e in
    let body = match e with
      | ELit l -> tag "literal" [literal env l.lit]
      | EVar v -> (match local env v.name with Some id -> tag "bound" [id] | None -> tag "global" [lookup Value v.name])
      | EField f ->
        let qualified = match f.obj with
          | EConstructor { name; args = []; _ } | EVar { name; _ } when local env name = None -> resolve Value (name ^ "." ^ f.field)
          | _ -> None in
        (match qualified with Some symbol -> tag "global" [global Value symbol]
         | None -> tag "field" [expression env f.obj; Bytes f.field])
      | EApp {fn=EConstructor {name; args=[]; _}; arg=ERecord r; _} ->
        (* The constructor and inline record are syntax, not separately evaluated
           values. Their checked fields and the complete result carry the types. *)
        tag "construct-fields" [lookup Value name;
          Seq (List.map (fun (name, value) -> Seq [Bytes name; expression env value]) r.fields)]
      | EApp {fn; arg=EList {elems=[]; _}; _}
        when (match checked_type fn with Type_system.TFun _ | TVar _ -> false | _ -> true) ->
        tag "call-zero" [expression env fn]
      | EApp _ ->
        (* Inference checks an application spine together. Intermediate EApp
           nodes have no independent instantiation; retain ordered arguments. *)
        let fn, args = call_parts [] e in
        (match fn, args with
         | EVar {name="check"; _}, check_fn :: arguments ->
           tag "checked-call" [expression env check_fn; Seq (List.map (expression env) arguments)]
         | _ -> tag "call" [expression env fn; Seq (List.map (expression env) args)])
      | EBinop b -> tag "binary" [Bytes (binop b.op); expression env b.left; expression env b.right]
      | EUnop u -> tag "unary" [Bytes (match u.op with UNeg -> "negate" | UNot -> "not"); expression env u.arg]
      | EIf i -> tag "if" [expression env i.cond; expression env i.then_; expression env i.else_]
      | ECase c ->
        let scrutinee = expression env c.scrut in
        let arms = List.map (fun (arm : case_arm) -> let env, p = pattern env arm.pattern in
          tag "arm" [p; option (expression env) arm.guard; expression env arm.body]) c.arms in
        tag "case" [scrutinee; Seq arms]
      | ELet l ->
        let value = expression env l.value in let env, id = bind env l.name in
        tag "let" [id; option (surface_type env) l.declared_type; option (proof env) l.declared_proof; value; expression env l.body]
      | ELetProof l ->
        let value = expression env l.value in
        let env, value_id = bind env l.value_name in let env, proof_id = bind env l.proof_name in
        tag "let-proof" [value_id; proof_id; option (fun (index, count) -> Seq [natural index; natural count]) l.proof_index; value; expression env l.body]
      | ERecord r -> tag "record" [Seq (List.map (fun (name, value) -> Seq [Bytes name; expression env value]) r.fields)]
      | EList l -> tag "list" (List.map (expression env) l.elems)
      | EOk o -> tag "attach" [bool o.keyword; expression env o.value; proof env o.proof]
      | EFail f -> tag "fail" [natural f.status; expression env f.message]
      | EConstructor c -> tag "construct" [lookup Value c.name; Seq (List.map (expression env) c.args)]
      | ELambda l -> let env, bs = bindings env l.params in tag "lambda" [Seq bs; expression env l.body]
      | ETelemetry _ | EEnqueue _ | EPublish _ | EStartWorkers _ | ECacheGet _ | ECacheSet _
      | ECacheDelete _ | ECacheInvalidate _ | ESendEmail _ | EStartEmailWorker _ | EWithDatabase _
      | EWithCapabilities _ | EWithTransaction _ | EServe _ | ESqlQuery _ -> reject loc "effectful expression is forbidden in migration IR" in
    tag "expr" [ty; body] in
  let fields ?(stored=false) env fs =
    let env = List.fold_left (fun env (f : field_def) -> fst (bind env f.name)) env fs in
    (* A field's standalone contract names sibling subjects, rather than their
       declaration-order slots. Inserting an unrelated field must not change the
       identity of an existing proof subject. The complete declaration retains
       its existing canonical encoding. *)
    let rec field_subjects = function
      | Seq [Bytes "local"; Bytes index] ->
        let name = match List.find_opt (fun (_, i) -> string_of_int i = index) env with
          | Some (name, _) -> name
          | None -> reject loc "unresolved entity field subject in migration IR" in
        tag "field-subject" [Bytes name]
      | Seq nodes -> Seq (List.map field_subjects nodes)
      | Bytes _ as node -> node in
    env, List.map (fun (f : field_def) ->
      let previous = !references in
      references := [];
      let node = tag "field" [Bytes f.name; surface_type env f.type_expr;
        option (proof env) f.proof_ann; option bytes f.db_type] in
      let field_references = !references in
      references := field_references @ previous;
      if stored then stored_fields := (f.name, {
        node = normalize_variables (field_subjects node);
        references = List.sort_uniq compare field_references;
      }) :: !stored_fields;
      node) fs in
  let invariant env (i : record_invariant) = tag "invariant" [proof env i.proof_text; option (lookup Value) i.checker_name] in
  try
    let node = match decl with
      | DFunc f ->
        let kind = match f.kind with FnKind -> "fn" | CheckKind -> "check" | EstablishKind -> "establish"
          | AuthKind | HandlerKind | WorkerKind | DeadWorkerKind | MainKind -> reject f.loc "application function in migration IR" in
        if f.capabilities <> [] || f.http_methods <> [] then reject f.loc "effectful function in migration IR";
        let identity = own Value f.name in let env, params = bindings [] f.params in
        let result = return_spec env f.return_spec in
        tag "function" [identity; Bytes kind; Seq params; result; expression env f.body]
      | DType (TypeNewtype t) -> tag "newtype" [own Type t.name; bool t.secret; surface_type [] t.base_type]
      | DType (TypeAdt t) ->
        let identity = own Type t.name in
        let params = List.map (fun name -> tag "declared-variable" [Bytes name]) t.params in
        let variants = List.map (fun (v : adt_variant) -> let _, fs = fields [] v.fields in tag "variant" [own Value v.ctor; Seq fs]) t.variants in
        tag "adt" [identity; Seq params; Seq variants]
      | DRecord r -> let identity = own Type r.name in let env, fs = fields [] r.fields in
        tag "record-declaration" [identity; Seq fs; option (invariant env) r.invariant]
      | DEntity e ->
        let identity = own Type e.name in let _, fs = fields ~stored:true [] e.fields in
        let indexes = List.map (fun (i : entity_index) -> tag "index" [bool i.ix_unique; Seq (List.map bytes i.ix_fields); option bytes i.ix_name]) e.indexes in
        tag "entity" [identity; Bytes e.table; Bytes e.primary_key; Seq fs; Seq indexes]
      | DFact f -> let identity = own Predicate f.name in let _, bs = bindings [] f.params in tag "fact" [identity; Seq bs]
      | DCodec c ->
        let identity = own Codec c.name in let target = lookup Type c.type_name in
        let to_json = match c.to_json with
          | ToJsonForbidden -> tag "forbidden" [] | ToJsonAdt -> tag "adt" []
          | ToJsonFields fields -> tag "fields" (List.map (fun (f : codec_encode_entry) -> tag "field" [Bytes f.field_name; Bytes f.json_key; lookup Codec f.codec]) fields) in
        let from_json = match c.from_json with
          | FromJsonForbidden -> tag "forbidden" [] | FromJsonAdt -> tag "adt" []
          | FromJsonAlts alts -> tag "alternatives" (List.map (fun alt -> Seq (List.map (function
              | DecodeField f -> tag "field" [Bytes f.field_name; Bytes f.json_key; lookup Codec f.codec; Seq (List.map (lookup Value) f.via)]
              | DecodeDefault d -> tag "default" [Bytes d.field_name; literal [] d.default_lit]
              | DecodeCrossCheck c -> tag "check" [lookup Value c.checker]) alt)) alts) in
        tag "codec" [identity; target; to_json; from_json]
      | DDatabase _ | DCapability _ | DConst _ | DQueue _ | DChannel _ | DWorkers _ | DCache _
      | DAgent _ | DEmail _ | DCapture _ | DApi _ | DServer _ | DTest _ | DApiTest _ | DLoadTest _ -> reject loc "application declaration is forbidden in migration IR" in
    Ok ({ node = normalize_variables node; references = List.sort_uniq compare !references },
        List.rev !stored_fields)
  with Invalid error -> Error error

let declaration ~scopes ~resolve ~typed_nodes ~module_name decl =
  Result.map fst (lower_declaration ~scopes ~resolve ~typed_nodes ~module_name decl)

let define ~scopes ~resolve ~typed_nodes (m : module_form) decl =
  match lower_declaration ~scopes ~resolve ~typed_nodes ~module_name:m.module_name decl with
  | Error _ as error -> error
  | Ok (body, stored_fields) ->
    let ref ns name = ns, Global (m.module_name ^ "." ^ name) in
    let named ns name aliases supports =
      Ok {key=ref ns name; aliases; body; supports; stored_fields} in
    match decl with
    | DFunc f ->
      let supports = match f.kind with
        | CheckKind | EstablishKind -> List.filter (fun (ns,_) -> ns = Predicate) body.references
        | FnKind | AuthKind | HandlerKind | WorkerKind | DeadWorkerKind | MainKind -> [] in
      named Value f.name [] supports
    | DType (TypeNewtype t) -> named Type t.name [ref Value t.name] []
    | DType (TypeAdt t) -> named Type t.name (List.map (fun (v : adt_variant) -> ref Value v.ctor) t.variants) []
    | DRecord r -> named Type r.name [ref Value r.name] []
    | DEntity e -> named Type e.name [ref Value e.name] []
    | DFact f -> named Predicate f.name [] []
    | DCodec c ->
      let target = match resolve Type c.type_name with
        | Some symbol -> [Type, symbol] | None -> [] in
      named Codec c.name [] target
    | DDatabase _ | DCapability _ | DConst _ | DQueue _ | DChannel _ | DWorkers _ | DCache _
    | DAgent _ | DEmail _ | DCapture _ | DApi _ | DServer _ | DTest _ | DApiTest _ | DLoadTest _ ->
      Error {loc=top_decl_loc decl; message="application declaration in migration closure"}

(** [definitions] must be the complete checked schema-owned inventory, including
    private modules and every fact owner. Reachability alone cannot discover an
    additional owner of a fact. Callers may not supply only exported definitions. *)
let closure ~scopes ~definitions ~roots =
  let loc = Location.dummy_loc "<migration-closure>" in
  let reference (ns, symbol) =
    let identity = match symbol with
      | Global name -> require loc (Migration_canonical.reference scopes name)
      | Primitive name ->
        if name = "" then reject loc "empty primitive ABI tag";
        tag "primitive" [Bytes name] in
    tag "reference" [Bytes (namespace ns); identity] in
  let describe (ns, symbol) = namespace ns ^ " " ^ (match symbol with Global n | Primitive n -> n) in
  try
    let by_reference = Hashtbl.create 32 and owners = Hashtbl.create 16 in
    List.iter (fun definition ->
      List.iter (fun key ->
        if Hashtbl.mem by_reference key then reject loc ("duplicate semantic definition for " ^ describe key);
        Hashtbl.add by_reference key definition) (definition.key :: definition.aliases);
      List.iter (fun predicate ->
        let previous = Option.value (Hashtbl.find_opt owners predicate) ~default:[] in
        Hashtbl.replace owners predicate (definition.key :: previous)) definition.supports
    ) definitions;
    let visited = Hashtbl.create 32 in
    let rec visit key =
      ignore (reference key);
      (match snd key with
       | Primitive _ -> ()
       | Global _ ->
         let definition = match Hashtbl.find_opt by_reference key with
           | Some d -> d
           | None -> reject loc ("missing semantic definition for " ^ describe key) in
         if not (Hashtbl.mem visited definition.key) then begin
           Hashtbl.add visited definition.key definition;
           List.iter visit definition.body.references
         end);
      (* Mark the declaration before traversing its producers: checks and their
         predicates naturally form cycles, as do recursive helper functions. *)
      List.iter (fun owner ->
          if not (Hashtbl.mem visited owner) then visit owner)
          (Option.value (Hashtbl.find_opt owners key) ~default:[]) in
    List.iter visit roots;
    let ordered nodes = List.sort_uniq (fun a b -> String.compare (encode a) (encode b)) nodes in
    let reached = Hashtbl.fold (fun key definition nodes ->
      Seq [reference key; definition.body.node] :: nodes) visited [] |> ordered in
    Ok (tag "closure" [Seq (ordered (List.map reference roots)); Seq reached])
  with Invalid error -> Error error
