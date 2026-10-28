module I = Migration_inventory
module C = Migration_canonical
module IR = Migration_ir
open C

type decoder_order = Unchanged | Append_only | Removed | Reordered_or_replaced
type codec_change = {
  previous_codec : string option;
  current_codec : string option;
  encoder_syntax_changed : bool;
  decoder_alternatives_changed : bool;
  decoder_order_change : decoder_order;
  dependency_closure_changed : bool;
}
type report = { entity : string; field : string; codecs : codec_change list }
type codec_view = { identity : string; closure : C.node; encoder : C.node;
  decoder : C.node; dependencies : C.node }

let relative inventory name =
 let prefix=I.root_module inventory ^ "." in
 if String.starts_with ~prefix name then String.sub name (String.length prefix) (String.length name-String.length prefix)
 else name

let view inventory (declaration:I.declaration) =
 Result.bind (I.closure inventory [IR.Codec,declaration.qualified_name]) (function
 | Seq [semantics;contract;Seq [Bytes "closure";Seq [root];Seq definitions]] as closure ->
   (match List.filter_map (function
     | Seq [identity;Seq [Bytes "codec";_;_;encoder;decoder]] when identity=root -> Some (encoder,decoder)
     | _ -> None) definitions with
    | [encoder,decoder] ->
      let dependencies=Seq [semantics;contract;Seq (List.filter (function
        | Seq [identity;_] -> identity<>root | _ -> true) definitions)] in
      Ok {identity=declaration.qualified_name;closure;encoder;decoder;dependencies}
    | _ -> Error {IR.loc=declaration.source_loc;message="codec change inspection requires its exact canonical codec definition"})
 | _ -> Error {IR.loc=declaration.source_loc;message="codec change inspection requires a complete bound closure"})

let rec prefix previous current = match previous,current with
 | [],_ -> true
 | a::rest,b::tail when a=b -> prefix rest tail
 | _ -> false
(* The IR alternatives node is tagged directly, followed by ordered alternatives.
   Preserve both priority and repeated alternatives; sets lose decoder behavior. *)
let decoder_order previous current =
 if previous=current then Unchanged else match previous,current with
 | Seq (Bytes "alternatives"::old),Seq (Bytes "alternatives"::fresh) ->
   if List.length fresh>List.length old && prefix old fresh then Append_only
   else if List.length fresh<List.length old then Removed
   else Reordered_or_replaced
 | _ -> Reordered_or_replaced

let changed old fresh = match old,fresh with
 | Some a,Some b when a.closure=b.closure -> None
 | Some a,Some b -> Some {previous_codec=Some a.identity;current_codec=Some b.identity;
     encoder_syntax_changed=a.encoder<>b.encoder;decoder_alternatives_changed=a.decoder<>b.decoder;
     decoder_order_change=decoder_order a.decoder b.decoder;
     dependency_closure_changed=a.dependencies<>b.dependencies}
 | a,b -> Some {previous_codec=Option.map(fun c->c.identity)a;current_codec=Option.map(fun c->c.identity)b;
     encoder_syntax_changed=true;decoder_alternatives_changed=true;
     decoder_order_change=(if b=None then Removed else Reordered_or_replaced);
     dependency_closure_changed=true}

let inspect ~before ~after =
 (* Reuse the inventory's family and semantic-domain compatibility guard. *)
 Result.bind (I.field_changes ~before ~after) (fun fields ->
  let exception Invalid of IR.error in
  let get=function Ok value->value | Error error->raise(Invalid error) in
  let codecs inventory (field:I.stored_field) =
   Option.value (I.stored_dependencies inventory ~entity:field.entity ~field:field.name) ~default:[]
   |> List.filter(fun (d:I.declaration)->d.declaration_kind=I.Codec_declaration)
   |> List.map(fun (d:I.declaration)->relative inventory d.qualified_name,get(view inventory d)) in
  try Ok(List.filter_map(function
   | I.Changed_field {previous;current;_} ->
     let old=codecs before previous and fresh=codecs after current in
     let names=List.sort_uniq String.compare (List.map fst old@List.map fst fresh) in
     let codecs=List.filter_map(fun name->changed (List.assoc_opt name old) (List.assoc_opt name fresh)) names in
     if codecs=[] then None else Some {entity=relative after current.entity;field=current.name;codecs}
   | I.Added_field _ | I.Removed_field _ -> None) fields)
  with Invalid error->Error error)

let json ~quote reports =
 let array render items="[" ^ String.concat "," (List.map render items) ^ "]" in
 let optional= function None->"null" | Some s->quote s in
 let order=function Unchanged->"unchanged" | Append_only->"append-only" | Removed->"removed" | Reordered_or_replaced->"reordered-or-replaced" in
 let codec c=Printf.sprintf
  {|{"previousCodec":%s,"currentCodec":%s,"encoderSyntaxChanged":%b,"decoderAlternativesChanged":%b,"decoderOrderChange":%s,"dependencyClosureChanged":%b,"adapterOnlyEligible":false}|}
  (optional c.previous_codec) (optional c.current_codec) c.encoder_syntax_changed c.decoder_alternatives_changed
  (quote(order c.decoder_order_change)) c.dependency_closure_changed in
 array (fun r->Printf.sprintf {|{"entity":%s,"field":%s,"codecs":%s}|} (quote r.entity) (quote r.field) (array codec r.codecs)) reports
