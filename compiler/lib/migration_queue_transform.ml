open Ast
module I = Migration_inventory
module T = Migration_transform
module G = Migration_checked_graph
module A = Migration_abi
module C = Migration_canonical
module IR = Migration_ir
module S = Migration_sparse
module Integrity = Migration_source_integrity

type t = {
  semantic : C.node;
  digest : string;
  callback : T.function_binding;
  fixtures : T.function_binding list;
  captured : T.captured;
  integrity : Integrity.t;
  abi : A.t;
  root : module_form;
  previous_payload : string;
  current_payload : string;
}
let semantic t = t.semantic
let digest t = t.digest
let callback t = t.callback
let fixtures t = t.fixtures
let root t = t.root
let source_texts t = T.captured_source_texts t.captured
let payload_names t = t.previous_payload,t.current_payload
exception Invalid of S.error list
let reject code loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok x -> x | Error errors -> raise (Invalid errors)
let ir = function Ok x -> x | Error (e:IR.error) -> reject "MIG028" e.loc e.message
let abi = function Ok x -> x | Error (e:A.error) -> reject "MIG013" (Location.dummy_loc e.path) e.message
let protect loc run = try Ok(run ()) with
  | Invalid errors -> Error errors
  | Invalid_argument message | Sys_error message | Failure message -> Error [{S.code="MIG013";loc;message;related=[]}]
  | Unix.Unix_error(error,operation,path) -> Error [{S.code="MIG013";loc;message=operation ^ ": " ^ path ^ ": " ^ Unix.error_message error;related=[]}]

let with_checked t run =
  let loc = t.callback.declaration.loc in
  protect loc (fun () ->
    abi(A.verify t.abi);
    let result = Migration_proof_context.without_context (fun () ->
      checked(Integrity.with_captured t.integrity (fun () ->
        checked(T.with_captured t.captured (fun () -> abi(A.with_snapshot t.abi run)))))) in
    abi(A.verify t.abi);
    result)

let check ~project_root ~before ~after ~version ~queue ~job ~source root ~callback ~fixtures =
  let loc = Location.dummy_loc root.source_file in
  protect loc (fun () ->
    let context = abi(A.current ()) in
    List.iter (fun inventory ->
      if I.compiler_abi inventory <> A.id context ||
         I.stored_value_compatibility inventory <> Some(A.stored_value_compatibility context) then
        reject "MIG013" loc "queue conversion requires exact current compiler and stored-value source inventories") [before;after];
    let parts inventory = match Validation_common.schema_module_parts(I.root_module inventory) with
      | Some(family,revision,[]) -> family,revision
      | _ -> reject "MIG028" loc "queue conversion requires exact schema roots" in
    let family,previous = parts before and target_family,current = parts after in
    if Migration_schema.migration_family root.module_name <> Some family then
      reject "MIG028" loc "queue conversion helpers must belong to their schema's migration family";
    if family<>target_family || version<2 || version>2147483646 || previous<>"V" ^ string_of_int(version-1) ||
       not(List.mem current ["VCurrent";"V" ^ string_of_int version]) then
      reject "MIG028" loc "queue conversion requires adjacent frozen/current schema versions in one family";
    let payload inventory =
      let queues=I.queue_contracts inventory |> List.filter(fun q -> Migration_queue.wire_identity inventory q.I.queue_name=queue) in
      match queues with
      | [q] -> (match List.filter(fun p -> Migration_queue.wire_identity inventory p.I.payload_name=job) q.payloads with
        | [p] -> p
        | _ -> reject "MIG028" loc "queue conversion must name an exact payload in the same queue in both versions")
      | _ -> reject "MIG028" loc "queue conversion must name an exact retained queue identity" in
    let old=payload before and fresh=payload after in
    if old.payload_contract=fresh.payload_contract then
      reject "MIG028" loc "unchanged queue payloads do not require a conversion";
    let captured=checked(T.capture ~before ~after ~source root) in
    let sources=T.captured_source_texts captured in
    let integrity=checked(Integrity.capture ~project_root
      ~inputs:(List.map(fun(m,source)->m.source_file,source)sources)) in
    checked(Integrity.with_captured integrity (fun () ->
    checked(T.with_captured captured (fun () -> abi(A.with_snapshot context (fun () ->
      let graph=ir(G.check sources) in
      let modules=G.modules graph in
      let functions=checked(T.bind_pure_functions modules root (callback::fixtures)) in
      let callback,fixtures=match functions with f::fs -> f,fs | [] -> assert false in
      let resolves owner ns spelling = G.resolve graph ~owner:owner.module_name ns spelling in
      let exact owner expected = function
        | TName n -> resolves owner IR.Type n.name=Some(IR.Global expected)
        | _ -> false in
      let result owner = function
        | RetPlain {ty=TApp {head=TName head;arg;_};_} ->
          resolves owner IR.Type head.name=Some(IR.Primitive "Tesl.Migration.Migrated") && exact owner fresh.payload_name arg
        | _ -> false in
      (match callback.declaration.params with
       | [p] when p.proof_ann=None && exact callback.owner old.payload_name p.type_expr && result callback.owner callback.declaration.return_spec -> ()
       | _ -> reject "MIG021" callback.declaration.loc
           ("queue conversion requires exactly " ^ old.payload_name ^ " -> Migrated " ^ fresh.payload_name));
      if fixtures=[] then reject "MIG003" loc "queue conversion requires a representative old-payload fixture";
      let seen=Hashtbl.create 8 in
      List.iter(fun (f:T.function_binding) ->
        if Hashtbl.mem seen f.identity then reject "MIG023" f.declaration.loc "duplicate queue conversion fixture";
        Hashtbl.add seen f.identity ();
        let valid=match f.declaration.return_spec with
          | RetPlain {ty=TApp {head=TName head;arg;_};_}
            when resolves f.owner IR.Type head.name=Some(IR.Primitive "Tesl.Maybe.Maybe") -> exact f.owner old.payload_name arg
          | RetPlain r -> exact f.owner old.payload_name r.ty
          | _ -> false in
        if f.declaration.params<>[] || not valid then reject "MIG021" f.declaration.loc
          "queue fixtures must be parameterless functions returning the exact previous payload or builtin Maybe of it") fixtures;
      let codec payload =
        let codecs=List.concat_map(fun (m:module_form) -> List.filter_map(function
          | DCodec c when m.module_name ^ "." ^ c.name=payload.I.payload_name -> Some c
          | _ -> None)m.decls) modules in
        match codecs with
        | [c] when c.to_json<>ToJsonForbidden &&
            (match c.from_json with FromJsonAlts (_::_) | FromJsonAdt -> true | _ -> false) -> ()
        | _ -> reject "MIG028" payload.payload_loc "queue conversion requires complete explicit frozen and target codecs" in
      codec old; codec fresh;
      let scopes=C.[{family;revision=previous;role=From_role};{family;revision=current;role=To_role}] in
      let definitions=ir(G.lower_helpers ~scopes graph) in
      let closure roots=ir(IR.closure ~scopes ~definitions ~roots) in
      let tag name children=C.Seq(C.Bytes name::children) in
      let semantic=tag "checked-queue-transform-source-v1" [
        C.Bytes(A.id context); C.Bytes(A.stored_value_compatibility context);
        C.Bytes family; C.Bytes(string_of_int version); C.Bytes queue; C.Bytes job;
        old.payload_contract; fresh.payload_contract;
        closure [IR.Codec,IR.Global old.payload_name];
        closure [IR.Codec,IR.Global fresh.payload_name];
        closure [IR.Value,IR.Global callback.identity];
        C.Seq(List.map(fun (f:T.function_binding) -> closure [IR.Value,IR.Global f.identity]) fixtures)] in
      {semantic;digest=C.digest C.Migration semantic;callback;fixtures;captured;integrity;abi=context;
       root;previous_payload=old.payload_name;current_payload=fresh.payload_name}))))))
  )
