open Ast
module I = Migration_inventory
module E = Migration_sparse
module R = Migration_transform_rules
module V = Migration_scaffold_value
type t = {id:string;label:string;template:string;help:string;replacement:string;
 imports:string list;helpers:string;fixture:string}
let historical_proof_help = " Historical validation uses ordinary Maybe results. Something must carry the exact historical value and proof; Nothing rejects the entire write transaction while historical columns are required. You may validate a business fallback through the old validator, handling both outcomes normally. No frozen-source edits or special literal proofs are required. After Contract retires the old storage, that historical write-back is no longer called."

let entity forms identity = match List.find_map(fun(m:module_form)->List.find_map(function
 | DEntity e when m.module_name ^ "." ^ e.name=identity ->Some(m,e)|_->None)m.decls)forms with
 | Some x->x|None->V.refuse("Cannot find " ^ identity)
let renamed_contract renames (field:I.stored_field) =
 let open Migration_canonical in
 let rename n=Option.value(List.assoc_opt n renames)~default:n in
 let rec subjects=function Seq[Bytes "field-subject";Bytes n]->Seq[Bytes "field-subject";Bytes(rename n)]
  | Seq ns->Seq(List.map subjects ns)|Bytes _ as n->n in
 match field.contract with
 | Seq[a;b;Seq[Bytes "stored-field";Seq[Bytes "field";Bytes name;ty;proof;storage];deps]] ->
   Seq[a;b;Seq[Bytes "stored-field";Seq[Bytes "field";Bytes(rename name);ty;subjects proof;storage];deps]]
 | node->node
let without_storage = function
 | Migration_canonical.Seq[a;b;Seq[Bytes "stored-field";Seq[Bytes "field";name;ty;proof;_];deps]] ->
   Migration_canonical.Seq[a;b;Seq[Bytes "stored-field";Seq[Bytes "field";name;ty;proof];deps]]
 | node->node

let options ?(on_unsupported=fun _->()) ~file ~source ~before ~after ~identity ~(previous:I.stored_entity)
    ~(current:I.stored_entity) ~missing ~validator ~constructor () = try
 let forms=V.modules before after in
 let old_home,old_entity=entity forms previous.entity_name and new_home,new_entity=entity forms current.entity_name in
 if previous.table_name<>current.table_name || previous.primary_key<>current.primary_key then V.refuse "Keep the table and primary key identity unchanged on this edge. Table/key changes require a supported staged design.";
 let parsed=match Parser.parse_module file source with Ok m->m|Err e->V.refuse e.msg in
 let shapes inventory name=I.field_shapes inventory |> List.filter(fun s->s.I.stored_field.entity=name)in
 let old=shapes before previous.entity_name and fresh=shapes after current.entity_name in
 let get shapes name=List.find(fun s->s.I.stored_field.name=name)shapes in
 if (get old previous.primary_key).stored_field.contract<>(get fresh current.primary_key).stored_field.contract then V.refuse "Primary key contracts must stay unchanged.";
 let removed=List.filter(fun s->not(List.exists(fun n->n.I.stored_field.name=s.I.stored_field.name)fresh))old
 and added=List.filter(fun s->not(List.exists(fun n->n.I.stored_field.name=s.I.stored_field.name)old))fresh in
 let changed=List.filter(fun s->List.exists(fun p->p.I.stored_field.name=s.I.stored_field.name && p.stored_field.contract<>s.stored_field.contract)old)fresh in
 if changed=[] && removed=[] && added=[] then V.refuse "No field mapping is required.";
 List.iter(fun s->let p=get old s.I.stored_field.name in
   if without_storage p.stored_field.contract=without_storage s.stored_field.contract then V.refuse "Storage-only changes cannot be represented as value Retype.")changed;
 let changed_names=List.map(fun s->s.I.stored_field.name)(changed @ added)in
 if List.exists(fun(m:E.missing_identity)->not(List.mem m.current_field.name changed_names))missing then
   V.refuse "Restore verified Same identities for unchanged copied fields before generating their adapter.";
 let compatible p n = renamed_contract [p.I.stored_field.name,n.I.stored_field.name] p.stored_field=n.stored_field.contract in
 let pairs=List.concat_map(fun p->List.filter_map(fun n->if compatible p n then Some(p.I.stored_field.name,n.I.stored_field.name)else None)added)removed in
 let bounded=let rec take n=function _ when n=0->[]|[]->[]|x::xs->x::take(n-1)xs in take 24 pairs in
 let unambiguous=List.filter(fun(a,_)->List.length(List.filter(fun(x,_)->x=a)pairs)=1)pairs |>
   List.filter(fun(_,b)->List.length(List.filter(fun(_,y)->y=b)pairs)=1)in
  let variants=([],"map-fields","Map changed fields and supply compatibility values") ::
    ([],"delete-rows","Convert retained rows and explicitly delete obsolete rows") ::
   List.map(fun(a,b)->[a,b],"rename:" ^ a ^ ":" ^ b,"Rename " ^ a ^ " to " ^ b ^ "; map other changes")bounded @
   (if List.length unambiguous>1 then [unambiguous,"rename-all","Rename " ^ String.concat ", "(List.map(fun(a,b)->a ^ " to " ^ b)unambiguous)]else[])in
  variants |> List.filter_map(fun(renames,id,label)->try
    let deleting=id="delete-rows"in
   let c=V.create ~forms ~taken:(V.names parsed) ~validator in
   let suffix=String.split_on_char '.' identity |> List.map String.capitalize_ascii |> String.concat "" in
   let forward=V.allocate c.taken("migrate" ^ suffix) and fixture=V.allocate c.taken("fixture" ^ suffix)in
   let rules=ref(List.map(fun(a,b)->"Rename " ^ a ^ " " ^ b)renames)and helpers=ref []in
   let field_fields fields name=List.find(fun(f:field_def)->f.name=name)fields in
   List.iter(fun shape->if not(List.mem_assoc shape.I.stored_field.name renames)then begin
     let f=field_fields old_entity.fields shape.stored_field.name in
     let function_=V.allocate c.taken("legacy" ^ suffix ^ String.capitalize_ascii f.name)in
     let spec=V.field old_home f in
     rules:= !rules @ ["LegacyWith " ^ f.name ^ " " ^ function_];
      (* For a removed optional field the intuitive Nothing compiles but refuses
         every old-binary write during overlap; Something Nothing (store NULL)
         is almost always meant, so it is the filled default. *)
      let optional=f.proof_ann=None && V.application c spec "Maybe"<>None in
      let comment=if optional then
          "# Old binaries still write " ^ identity ^ "." ^ f.name ^ " until the old column is retired.\n" ^
          "# Something Nothing stores NULL in the old column for their writes (the usual choice).\n" ^
          "# Nothing would instead refuse every write from old binaries during the overlap.\n"
        else
          "# Old binaries still write " ^ identity ^ "." ^ f.name ^ " until the old column is retired.\n" ^
          "# Something value stores that value in the old column for their writes.\n" ^
          "# Nothing refuses every write from old binaries during the overlap.\n" in
      let body=if optional then "Something Nothing" else
        V.todo ("Return Something with the historical value and proof for removed field " ^ identity ^ "." ^ f.name ^ ", or Nothing to refuse writes until retirement") in
      helpers:= !helpers @ [comment ^ "fn " ^ function_ ^ (if optional then "(_current: " else "(current: ") ^ current.entity_name ^ ") -> " ^ V.result c spec false ^ " =\n  " ^
        body ^ "\n"]
   end)removed;
   let entries=List.mapi(fun index(f:field_def)->
     let old_name=Option.value(List.find_map(fun(a,b)->if b=f.name then Some a else None)renames)~default:f.name in
     let variable="converted" ^ string_of_int index in
     match List.find_opt(fun s->s.I.stored_field.name=old_name)old with
     | Some p when renamed_contract renames p.stored_field=(get fresh f.name).stored_field.contract ->
       variable,"old." ^ old_name,false,f.name
     | Some _ ->
       let previous_field=field_fields old_entity.fields old_name in
       let previous_spec=V.field old_home previous_field and target=V.field new_home f in
       let adapter=V.convert c ~label:("convert" ^ suffix ^ String.capitalize_ascii f.name) ~reason:(identity ^ "." ^ f.name)previous_spec target in
        let backward=V.convert c ~label:("restore" ^ suffix ^ String.capitalize_ascii f.name) ~reason:("historical " ^ identity ^ "." ^ old_name)target previous_spec in
       let writeback=V.allocate c.taken("writeBack" ^ suffix ^ String.capitalize_ascii old_name)in
       let call=backward.name ^ " current." ^ f.name in
        let body="  " ^ call in
        helpers:= !helpers @ ["fn " ^ writeback ^ "(current: " ^ current.entity_name ^ ") -> " ^ V.result c previous_spec backward.total ^ " =\n" ^ body ^ "\n"];
       rules:= !rules @ ["Retype " ^ f.name;"WriteBack " ^ old_name ^ " " ^ f.name ^ " " ^ writeback];
       variable,adapter.name ^ " old." ^ old_name,not adapter.total,f.name
     | None ->let expr,rejects=V.input c ~label:("new" ^ suffix ^ String.capitalize_ascii f.name)
       ~reason:("Value for new field " ^ identity ^ "." ^ f.name)(V.field new_home f)in variable,expr,rejects,f.name)new_entity.fields in
   let value=current.entity_name ^ " { " ^ String.concat ", "(List.map(fun(v,e,rejects,name)->name ^ ": " ^ (if not rejects && String.starts_with ~prefix:"old." e then e else v))entries) ^ " }"in
   let conversions=entries |> List.filter(fun(_,e,rejects,_)->rejects || not(String.starts_with ~prefix:"old." e))in
   let rec body indent=function
     | []->V.pad indent ^ (if deleting then "KeepRow (" else "Row (") ^ value ^ ")"
    | (v,e,false,_)::rest->V.pad indent ^ "let " ^ v ^ " = " ^ e ^ "\n" ^ body indent rest
     | (v,e,true,name)::rest->V.pad indent ^ "case " ^ e ^ " of\n" ^ V.pad indent ^ "  Nothing -> " ^ (if deleting then "RejectRow ("else "Reject (") ^ V.todo("Reason to reject " ^ identity ^ " when " ^ name ^ " cannot be converted") ^ ")\n" ^
      V.pad indent ^ "  Something " ^ v ^ " ->\n" ^ body(indent+4)rest in
   let pure_rename=renames<>[] && conversions=[] && !helpers=[] && missing=[]in
   if not pure_rename && not(V.exported old_home old_entity.name && V.exported new_home new_entity.name)then
     V.refuse "A custom row converter needs public old/new entity types. Expose the API in a compatible revision before changing its representation; do not edit frozen history.";
   let replacement=if pure_rename then "Derived [" ^ String.concat ", " !rules ^ "]"else "Migrate " ^ forward ^ " [" ^ String.concat ", " !rules ^ "]"in
   let sample=if pure_rename then ""else V.fixture c ~home:old_home ~identity:previous.entity_name ~fields:old_entity.fields ~name:fixture ~constructor in
   V.add_import c("import " ^ old_home.module_name);V.add_import c("import " ^ new_home.module_name);
    V.add_import c (if deleting then "import Tesl.Migration exposing [RowChange(..)]" else "import Tesl.Migration exposing [Migrated(..)]");
   V.add_import c "import Tesl.Maybe exposing [Maybe(..)]";
    let forward_body=if not deleting then body 2 conversions else begin
      V.add_import c "import Tesl.Prelude exposing [Bool(..)]";
      let predicate=V.allocate c.taken("delete" ^ suffix)in
      helpers:= !helpers @ ["fn " ^ predicate ^ "(old: " ^ previous.entity_name ^ ") -> Bool =\n  " ^
        V.todo("Return True only for " ^ identity ^ " rows explicitly selected for deletion; False keeps and converts the row") ^ "\n"];
      "  if " ^ predicate ^ " old then\n    DeleteRow (" ^ V.todo("Reason for deleting obsolete " ^ identity ^ " rows") ^ ")\n  else\n" ^ body 4 conversions
    end in
    let helpers=if pure_rename then ""else
      "fn " ^ forward ^ "(old: " ^ previous.entity_name ^ ") -> " ^ (if deleting then "RowChange "else "Migrated ") ^ current.entity_name ^ " =\n" ^ forward_body ^ "\n\n" ^
     String.concat "\n"(!(c.helpers) @ !helpers) ^ "\n" ^ sample in
   Some{id;label;replacement;template=replacement ^ (if helpers=""then ""else"\n\n" ^ helpers);imports=List.sort_uniq compare !(c.imports);helpers;fixture=(if pure_rename then ""else fixture);
     help=(if pure_rename then "This explicit rename preserves the existing values and their verified contracts. Tesl fills the Rename rules; no conversion value or inverse policy is guessed. Review the physical plan and cleanup before deployment." else
      "Tesl fills the complete row mapping, nested record/ADT conversion helpers, imports, Retype/WriteBack and removed-field LegacyWith rules, and historical fixture structure. Same-named primitive fields are copied; nominal values are rebuilt with the exact target constructors and codecs. Choose new/missing values, mappings for removed or renamed variants, rejection reasons and historical compatibility values. Failed forward validations/conversions reject the row; the old data remains retained. A historical fallback can be lossy, so review old/new writers and test the policy before Contract." ^
      (if deleting then " Explicit deletion is a whole-row decision. Choose its predicate and reason. The Worker deletes only the checked source tuple; concurrent changes are retried and database constraints can refuse the transaction. Reads of pending deletions report that Worker processing is required. Old writers may recreate rows until retirement." else "") ^
      (if List.exists(fun s->(get old s.I.stored_field.name).proof_identity<>None)changed || List.exists(fun s->s.I.proof_identity<>None)removed then historical_proof_help else ""))}
 with V.Unsupported message->on_unsupported message;None | Not_found ->None)
 with V.Unsupported message->on_unsupported message;[] | Not_found ->[]

type queue_change = { key:string; previous:I.queue_payload option; current:I.queue_payload option; reason:string }
let queue_changes before after =
 let relative inventory name=Migration_queue.wire_identity inventory name in
 let old=I.queue_contracts before and fresh=I.queue_contracts after in
 List.concat_map(fun(q:I.queue_contract)->
   let queue=relative before q.queue_name in
   match List.find_opt(fun(n:I.queue_contract)->relative after n.queue_name=queue)fresh with
   | None -> [{key=queue;previous=None;current=None;reason="Queue " ^ queue ^ " was removed. Confirm that it should be retired only when empty."}]
   | Some n -> List.filter_map(fun(p:I.queue_payload)->
     let key=relative before p.payload_name in
     match List.find_opt(fun(f:I.queue_payload)->relative after f.payload_name=key)n.payloads with
     | Some f when p.payload_contract<>f.payload_contract -> Some{key;previous=Some p;current=Some f;
       reason="Queued payload " ^ key ^ " changed. Map the retained values to the new record and codec."}
     | None -> Some{key;previous=Some p;current=None;reason="Queued payload " ^ key ^ " was removed or moved. Keep its membership for a conversion; only whole empty-queue retirement is supported."}
     | _->None)q.payloads)old

type queue_plan = { option:t; writes:(string * string) list }
let queue_options ?(on_unsupported=fun _->()) ~file ~source ~before ~after ~change ~validator ~constructor () = try
 let relative inventory name=Migration_queue.wire_identity inventory name in
 let rows inv=I.stored_entities inv |>List.map(fun e->relative inv e.I.entity_name,e.entity_contract)|>List.sort compare in
 if rows before<>rows after then V.refuse "Split this change: finish the row migration and its required cleanup first, then start a queue-payload revision. Keep the complete queue contracts (including shared proofs and codecs) unchanged in the row revision.";
 let membership inv=I.queue_contracts inv |>List.map(fun q->relative inv q.I.queue_name,
   List.map(fun p->relative inv p.I.payload_name)q.payloads |>List.sort compare)|>List.sort compare in
 match change.previous,change.current with
 | None,None ->
   let inventory inv=I.queue_contracts inv |>List.map(fun q->relative inv q.I.queue_name,
     List.map(fun p->relative inv p.I.payload_name,p.payload_contract)q.payloads |>List.sort compare)|>List.sort compare in
   if List.remove_assoc change.key(inventory before)<>inventory after || List.mem_assoc change.key(inventory after)then
     V.refuse "Retire one whole empty queue at a time, keeping other queue contracts and stored rows unchanged. Queue renaming or partial payload removal has no automatic conversion route."else
   [{option={id="remove-empty-queue";label="Retire this queue only when it is empty";template="RemoveEmpty";replacement="RemoveEmpty";
     help="The compiler fills the queue retirement declaration. Runtime admission and emptiness checks must pass before retirement; this does not discard pending jobs. Keep other row/queue changes in separate revisions.";
     imports=["import Tesl.Migration exposing [RemoveEmpty]"];helpers="";fixture=""};writes=[]}]
 | Some previous,Some current ->
   if membership before<>membership after then V.refuse "Keep queue membership unchanged on a payload-conversion edge.";
   let forms=V.modules before after in
   let record name=match List.find_map(fun(m:module_form)->List.find_map(function
     | DRecord r when m.module_name ^ "." ^ r.name=name->Some(m,r)|_->None)m.decls)forms with Some v->v|None->V.refuse("Missing payload record " ^ name)in
   let old_home,old_record=record previous.payload_name and new_home,new_record=record current.payload_name in
   let root=match Parser.parse_module file source with Ok m->m|Err e->V.refuse e.msg in
   let project=Filename.dirname(Filename.dirname(Filename.dirname file))in
   let base=root.module_name ^ ".Author" ^ (String.split_on_char '.' change.key |>List.map String.capitalize_ascii |>String.concat "")in
   let rec allocate n=let name=base ^ (if n=0 then ""else string_of_int n)in
     let path=Filename.concat project (Option.get(Validation_common.schema_module_relative_path name))in
     if Source_input.exists path then allocate(n+1)else name,path in
   let home,path=allocate 0 in
   let c=V.create ~forms ~taken:["convert";"example"] ~validator in
   let make home name=V.plain home (TName{name;loc=Location.dummy_loc file})in
   let adapter=V.convert c ~label:"mapPayload" ~reason:change.key (make old_home old_record.name)(make new_home new_record.name)in
   let body=if adapter.total then "  Row (" ^ adapter.name ^ " old)"else
     "  case " ^ adapter.name ^ " old of\n    Nothing -> Reject (" ^ V.todo("Reason to reject queued " ^ change.key ^ " when conversion fails") ^ ")\n    Something converted -> Row converted"in
   let fixture=V.fixture c ~home:old_home ~identity:previous.payload_name ~fields:old_record.fields ~name:"example" ~constructor in
   V.add_import c "import Tesl.Migration exposing [Migrated(..)]";
   V.add_import c "import Tesl.Maybe exposing [Maybe(..)]";
   let helpers="fn convert(old: " ^ previous.payload_name ^ ") -> Migrated " ^ current.payload_name ^ " =\n" ^ body ^ "\n\n" ^ String.concat "\n" !(c.helpers) ^ "\n" ^ fixture in
   let contents="module " ^ home ^ " exposing [convert, example]\n" ^ String.concat "\n"(List.sort_uniq compare !(c.imports)) ^ "\n\n" ^ helpers in
   let replacement="Migrate " ^ home ^ ".convert"in
   [{option={id="map-queued-payload";label="Convert retained jobs to the new payload";replacement;template=replacement ^ "\n\n" ^ contents;
     imports=["import " ^ home];helpers="";fixture=home ^ ".example";
     help="Tesl creates a pure helper module with the exact historical/current payload types, record/ADT mapping, codec-owned reconstruction and a historical fixture. Fill added values, renamed-field or removed-variant mappings, and any rejection reason. No reverse writer is required for this queue-only transition. The compiler still checks codecs, purity, membership and rollout ordering; a rejected job is retained, not discarded."};writes=[path,contents]}]
 | _ -> V.refuse change.reason
 with V.Unsupported message->on_unsupported message;[] | Not_found | Invalid_argument _ ->[]
