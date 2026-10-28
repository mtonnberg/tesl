open Ast
module I = Migration_inventory
module T = Migration_transform
module G = Migration_checked_graph
module A = Migration_abi
module C = Migration_canonical
module IR = Migration_ir
module S = Migration_sparse
module Integrity = Migration_source_integrity

type request = { queue : string; job : string; callback : expr; fixtures : expr list }
type policy = Convert | Rejected | Execution_failed | Discard
let policy_name = function Convert->"convert" | Rejected->"rejected" | Execution_failed->"execution-failed" | Discard->"unconverted"

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
  rejected : t option;
  repair_revision : int;
  policy : policy;
  discard_reason : string;
}
let semantic t = t.semantic
let digest t = t.digest
let callback t = t.callback
let fixtures t = t.fixtures
let root t = t.root
let source_texts t = T.captured_source_texts t.captured
let payload_names t = t.previous_payload,t.current_payload
let repair_revision t = t.repair_revision
let policy t = t.policy
let rec lineage t = Option.fold ~none:[] ~some:lineage t.rejected @ [t]
let conversion_semantic t = match t.semantic with
  | C.Seq [C.Bytes "checked-queue-repair-source-v1";_;_;conversion] -> conversion
  | C.Seq [C.Bytes "checked-queue-remediation-source-v1";_;_;_;_;conversion] -> conversion
  | conversion -> conversion
exception Invalid of S.error list
let reject code loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok x -> x | Error errors -> raise (Invalid errors)
let ir = function Ok x -> x | Error (e:IR.error) -> reject "MIG028" e.loc e.message
let abi = function Ok x -> x | Error (e:A.error) -> reject "MIG013" (Location.dummy_loc e.path) e.message
let protect loc run = try Ok(run ()) with
  | Invalid errors -> Error errors
  | Invalid_argument message | Sys_error message | Failure message -> Error [{S.code="MIG013";loc;message;related=[]}]
  | Unix.Unix_error(error,operation,path) -> Error [{S.code="MIG013";loc;message=operation ^ ": " ^ path ^ ": " ^ Unix.error_message error;related=[]}]

let rec with_checked t run =
  let loc = t.callback.declaration.loc in
  protect loc (fun () ->
    abi(A.verify t.abi);
    let guarded () = Migration_proof_context.without_context (fun () ->
      checked(Integrity.with_captured t.integrity (fun () ->
        checked(T.with_captured t.captured (fun () -> abi(A.with_snapshot t.abi run)))))) in
    let result=match t.rejected with None -> guarded () | Some parent -> checked(with_checked parent guarded) in
    abi(A.verify t.abi);
    result)

let check_conversions ~contextual_declarations ~project_root ~before ~after ~version ~source root ~requests =
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
    let old_queues=I.queue_contracts before and fresh_queues=I.queue_contracts after in
    let payload inventory contracts queue job =
      let queues=contracts |> List.filter(fun q -> Migration_queue.wire_identity inventory q.I.queue_name=queue) in
      match queues with
      | [q] -> (match List.filter(fun p -> Migration_queue.wire_identity inventory p.I.payload_name=job) q.payloads with
        | [p] -> p
        | _ -> reject "MIG028" loc "queue conversion must name an exact payload in the same queue in both versions")
      | _ -> reject "MIG028" loc "queue conversion must name an exact retained queue identity" in
    let endpoints=List.map(fun(request:request)->
      let old=payload before old_queues request.queue request.job
      and fresh=payload after fresh_queues request.queue request.job in
      if old.payload_contract=fresh.payload_contract then
        reject "MIG028" loc "unchanged queue payloads do not require a conversion";
      request,old,fresh)requests in
     let captured=checked(T.capture ~before ~after ~source root) in
     let sources=T.captured_source_texts captured in
     List.iter(fun(owner,bytes,_)->
       if not(List.exists(fun(actual,source)->actual=owner && source=bytes)sources) then
         reject "MIG013" loc "checked repair predecessor source changed before capture") contextual_declarations;
    let integrity=checked(Integrity.capture ~project_root
      ~inputs:(List.map(fun(m,source)->m.source_file,source)sources)) in
    checked(Integrity.with_captured integrity (fun () ->
    checked(T.with_captured captured (fun () -> abi(A.with_snapshot context (fun () ->
      let graph=ir(G.check sources) in
      let modules=G.modules graph in
      let scopes=C.[{family;revision=previous;role=From_role};{family;revision=current;role=To_role}] in
      let contextual=List.concat_map(fun m->List.filter_map(function
        | DConst c when List.exists(fun(owner,_,declaration)->owner=m && declaration=c)contextual_declarations -> Some(m,c)
        | _ -> None)m.decls) modules in
      (* One guarded judgment owns the common graph and adjacent inventories.
         Each request still validates its own exact callback, fixtures and codecs;
         no result leaves this scope until all source/ABI postconditions pass. *)
      let definitions=lazy(ir(G.lower_helpers ~contextual ~scopes graph)) in
      let before_snapshot=lazy(C.digest C.Snapshot (I.snapshot before))
      and after_snapshot=lazy(C.digest C.Snapshot (I.snapshot after)) in
      let before_storage=lazy(Migration_storage.digest(checked(Migration_storage.describe before)))
      and after_storage=lazy(Migration_storage.digest(checked(Migration_storage.describe after))) in
      List.map(fun((request:request),(old:I.queue_payload),(fresh:I.queue_payload))->
      let queue,job,callback,fixtures=request.queue,request.job,request.callback,request.fixtures in
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
       let definitions=Lazy.force definitions in
      let closure roots=ir(IR.closure ~scopes ~definitions ~roots) in
      let tag name children=C.Seq(C.Bytes name::children) in
       let semantic=tag "checked-queue-transform-source-v2" [
        C.Bytes(A.id context); C.Bytes(A.stored_value_compatibility context);
        C.Bytes family; C.Bytes(string_of_int version); C.Bytes queue; C.Bytes job;
        old.payload_contract; fresh.payload_contract;
        closure [IR.Codec,IR.Global old.payload_name];
        closure [IR.Codec,IR.Global fresh.payload_name];
        closure [IR.Value,IR.Global callback.identity];
         C.Seq(List.map(fun (f:T.function_binding) -> closure [IR.Value,IR.Global f.identity]) fixtures);
          C.Bytes(Lazy.force before_snapshot);C.Bytes(Lazy.force after_snapshot);
          C.Bytes(Lazy.force before_storage);C.Bytes(Lazy.force after_storage)] in
      {semantic;digest=C.digest C.Migration semantic;callback;fixtures;captured;integrity;abi=context;
        root;previous_payload=old.payload_name;current_payload=fresh.payload_name;rejected=None;repair_revision=0;policy=Convert;discard_reason=""})endpoints))))))
  )

let check_conversion ~contextual_declarations ~project_root ~before ~after ~version ~queue ~job ~source root ~callback ~fixtures =
  Result.map List.hd(check_conversions ~contextual_declarations ~project_root ~before ~after ~version ~source root
    ~requests:[{queue;job;callback;fixtures}])
let check = check_conversion ~contextual_declarations:[]
let check_many = check_conversions ~contextual_declarations:[]

(* Repairs extend an immutable conversion lineage, not the schema-version
   sequence. Every revision still consumes the original historical payload. *)
let check_repair ?(policy=Rejected) ?(discard_reason="") ~rejected ~revision replacement =
  let loc=replacement.callback.declaration.loc in
  protect loc (fun () -> checked(with_checked rejected (fun () ->
    checked(with_checked replacement (fun () ->
       if replacement.rejected<>None || revision<1 || revision>2147483646 || revision<>rejected.repair_revision+1 then
         reject "MIG028" loc "queue repair requires the next revision and an ordinary checked replacement conversion";
       if rejected.policy=Discard || policy=Convert then reject "MIG028" loc "discard is a terminal queue remediation decision";
      let endpoints t=match conversion_semantic t with
        | C.Seq parts -> List.filteri(fun i _ -> i<11 || i>=13)parts
        | _ -> assert false in
      if endpoints rejected<>endpoints replacement then
        reject "MIG028" loc "queue repair must preserve the exact frozen source and target payloads, codecs, queue and schema versions";
       if policy<>Discard && List.exists(fun ancestor->ancestor.callback.identity=replacement.callback.identity)(lineage rejected) then
        reject "MIG028" loc "queue repair requires a new callback declaration; deployed conversion history is immutable";
       let semantic=if policy=Rejected then C.Seq [C.Bytes "checked-queue-repair-source-v1";C.Bytes rejected.digest;
         C.Bytes(string_of_int revision);replacement.semantic] else
         C.Seq [C.Bytes "checked-queue-remediation-source-v1";C.Bytes rejected.digest;C.Bytes(string_of_int revision);
           C.Bytes(policy_name policy);C.Bytes discard_reason;replacement.semantic] in
       {replacement with semantic;digest=C.digest C.Migration semantic;
         rejected=Some rejected;repair_revision=revision;policy;discard_reason})))))

let queue_job t = match conversion_semantic t with
  | C.Seq (_::_::_::_::_::C.Bytes queue::C.Bytes job::_) -> queue,job
  | _ -> assert false

let check_repair_source ?(policy=Rejected) ~project_root ~contextual_declarations ~rejected ~revision ~source root ~callback ~fixtures =
  let loc=Location.dummy_loc root.source_file in
  protect loc (fun () -> checked(with_checked rejected (fun () ->
    let context=abi(A.current()) in
    let load payload =
      let name=match Validation_common.schema_module_parts payload with
        | Some(family,version,_) -> family ^ "." ^ version
        | _ -> assert false in
      let root_file=Validation_common.resolve_local_import_path root.source_file name in
      match I.load_with_compatibility ~compiler_abi:(A.id context)
        ~stored_value_compatibility:(Some(A.stored_value_compatibility context)) ~root_file with
      | Ok inventory -> inventory
      | Error error -> reject "MIG013" error.loc error.message in
    let version=match conversion_semantic rejected with
      | C.Seq (_::_::_::_::C.Bytes version::_) -> int_of_string version
      | _ -> assert false in
    let queue,job=queue_job rejected in
    let replacement=checked(check_conversion ~contextual_declarations ~project_root ~before:(load rejected.previous_payload)
      ~after:(load rejected.current_payload) ~version ~queue ~job ~source root ~callback ~fixtures) in
    checked(check_repair ~policy ~rejected ~revision replacement))))

let check_discard_source ~project_root ~contextual_declarations ~rejected ~revision ~reason ~source root =
  let loc=Location.dummy_loc root.source_file in
  protect loc(fun()->checked(with_checked rejected(fun()->
    if reason="" || String.length reason>256 || not(String.is_valid_utf_8 reason) || String.contains reason '\000' then reject "MIG028" loc "discard requires a nonempty PostgreSQL text reason of at most 256 UTF-8 bytes";
    let context=abi(A.current()) in
    let load payload =
      let name=match Validation_common.schema_module_parts payload with Some(f,v,_)->f ^ "." ^ v | _->assert false in
      let root_file=Validation_common.resolve_local_import_path root.source_file name in
      match I.load_with_compatibility ~compiler_abi:(A.id context) ~stored_value_compatibility:(Some(A.stored_value_compatibility context)) ~root_file with
      | Ok inventory->inventory | Error e->reject "MIG013" e.loc e.message in
    let captured=checked(T.capture ~before:(load rejected.previous_payload) ~after:(load rejected.current_payload) ~source root) in
    let sources=T.captured_source_texts captured in
    List.iter(fun(owner,bytes,_)->if not(List.exists(fun(actual,text)->actual=owner && text=bytes)sources) then
      reject "MIG013" loc "discard predecessor source changed before capture")contextual_declarations;
    let integrity=checked(Integrity.capture ~project_root ~inputs:(List.map(fun(m,text)->m.source_file,text)sources)) in
    checked(Integrity.with_captured integrity(fun()->checked(T.with_captured captured(fun()->
      ignore(ir(G.check sources));
      let semantic=conversion_semantic rejected in
      let replacement={rejected with semantic;digest=C.digest C.Migration semantic;captured;integrity;abi=context;root;
        fixtures=[];rejected=None;repair_revision=0;policy=Convert;discard_reason=""} in
      checked(check_repair ~policy:Discard ~discard_reason:reason ~rejected ~revision replacement))))))))
