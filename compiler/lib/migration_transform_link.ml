open Migration_canonical
module T = Migration_transform
module R = Migration_transform_rules
module S = Migration_sparse
module I = Migration_inventory
module G = Migration_checked_graph
module IR = Migration_ir
module P = Migration_proof_context

type t = {
  transform : T.t;
  semantic : node;
  digest : string;
  abi : Migration_abi.t;
  context : P.t;
  source_inputs : (string * string) list;
}
let checked_transform t = t.transform
let semantic t = t.semantic
let digest t = t.digest
let compiler_abi t = Migration_abi.id t.abi
let behavior t =
 match t.semantic with
 | Seq [Bytes "checked-transform-link";Bytes "1";_;rows;identities] ->
   Seq [Bytes "checked-transform-behavior";Bytes "1";
    Seq [Bytes "stored-value-compatibility";Bytes (Migration_abi.stored_value_compatibility t.abi)];rows;identities]
 | _ -> assert false
let behavior_digest t = Migration_canonical.digest Migration (behavior t)

let source_inputs t = t.source_inputs
let tag name children = Seq (Bytes name :: children)
let loc = Location.dummy_loc "<migration-transform-link>"
let reject message = raise (IR.Invalid {loc;message})
let require = function Ok value -> value | Error error -> raise (IR.Invalid error)
let protect f =
  try Ok (f ()) with
  | IR.Invalid error -> Error error
  | Invalid_argument message | Sys_error message | Failure message -> Error {IR.loc;message}
  | Unix.Unix_error (error,operation,path) ->
    Error {IR.loc;message=Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error)}
let abi_result = function
  | Ok value -> value
  | Error (error : Migration_abi.error) -> reject (error.path ^ ": " ^ error.message)

let revalidate t = protect (fun () ->
  P.revalidate t.context;
  abi_result (Migration_abi.verify t.abi))

let link transform = protect (fun () ->
  let rules = T.rules transform in
  let coverage = R.coverage rules in
  let before, after = S.inventories coverage in
  let abi = abi_result (Migration_abi.current ()) in
  List.iter (fun inventory ->
    if I.compiler_abi inventory <> Migration_abi.id abi then
      reject "transform inventories were checked under a different compiler ABI") [before;after];
  let context = T.proof_context transform in
  P.revalidate context;
  let make () =
    let scope role inventory =
      match Validation_common.schema_module_parts (I.root_module inventory) with
      | Some (family, revision, []) -> {family;revision;role}
      | _ -> reject "transform inventory has no exact schema root" in
    let scopes = [scope From_role before; scope To_role after] in
    let reference namespace name =
      match Migration_canonical.reference scopes name with
      | Ok identity -> tag "reference" [Bytes (IR.namespace namespace);identity]
      | Error message -> reject message in
    let captured = T.captured_sources transform in
    let graph = require (G.check ~context captured) in
    let owner = T.root transform in
    let declaration = match List.filter_map (function
      | Ast.DConst declaration when Migration_form.is_declaration owner declaration -> Some declaration
      | _ -> None) owner.decls with
      | [declaration] -> declaration
      | _ -> reject "checked transform root lost its unique contextual declaration" in
    let definitions = require (G.lower_transform ~scopes ~contextual:(owner,declaration) graph) in
    let closure roots = require (IR.closure ~scopes ~definitions ~roots) in
    let field (field : I.stored_field) = Bytes field.name in
    let value = function
      | R.Copy {previous;current} -> tag "copy" [field previous;field current]
      | R.Renamed {previous;current} -> tag "rename" [field previous;field current]
      | R.Retyped {previous;current} -> tag "retype" [field previous;field current]
      | R.Empty_optional current -> tag "empty-optional" [field current]
      | R.Constant (current,literal) -> tag "default" [field current;literal]
      | R.Computed current -> tag "computed" [field current] in
    let ordered nodes = List.sort_uniq (fun a b -> String.compare (encode a) (encode b)) nodes in
    let rows = T.rows transform |> List.map (fun (row : T.row) ->
      let mapping = row.mapping in
      let previous = IR.Type,IR.Global mapping.previous.entity_name in
      let current = IR.Type,IR.Global mapping.current.entity_name in
      let callback = match row.function_binding with
        | None -> tag "derived" []
        | Some binding ->
          let writes=List.map (fun (w:T.writeback_binding) -> tag "write-back" [field w.mapping.previous;field w.mapping.current;
            closure [IR.Value,IR.Global w.function_binding.identity]]) row.writebacks |> ordered in
          tag "migrate" ([closure [IR.Value,IR.Global binding.identity]] @ if writes=[] then [] else [Seq writes]) in
      let fixtures = List.map (fun (binding : T.function_binding) ->
        closure [IR.Value,IR.Global binding.identity]) row.fixtures |> ordered in
      tag "entity-transform" [
        reference IR.Type mapping.previous.entity_name;
        reference IR.Type mapping.current.entity_name;
        closure [previous;current];
        Seq (ordered (List.map value mapping.values));
        bool mapping.indexes_changed;
        callback;
        Seq fixtures]) |> ordered in
    let identities = S.identities coverage |> List.map (fun evidence ->
      let previous,current = I.same_declarations evidence in
      tag "same" [reference previous.namespace previous.qualified_name;
        reference current.namespace current.qualified_name;
        Bytes (I.same_digest evidence)]) |> ordered in
    let semantic = tag "checked-transform-link" [Bytes "1";
      tag "compiler-abi" [Bytes (Migration_abi.id abi)];Seq rows;Seq identities] in
    P.revalidate context;
    {transform;semantic;digest=Migration_canonical.digest Migration semantic;abi;context;
     source_inputs=T.source_inputs transform} in
  let linked = abi_result (Migration_abi.with_snapshot abi make) in
  require (revalidate linked);
  linked)
