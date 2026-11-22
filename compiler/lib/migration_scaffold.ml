(** Compiler-owned, deliberately incomplete source scaffolds. These never grant
    migration authority: the resulting complete source must still pass all gates. *)
open Ast
module I=Migration_inventory
module E=Migration_sparse
module R=Migration_transform_rules
module T=Migration_transform

type t={id:string;label:string;template:string;help:string;replacement:string;
        imports:string list;helpers:string;fixture:string}
exception Unsupported
let require=function Some x->x|None->raise Unsupported
let modules before after =
 List.map(fun(file,_)->match Parser.parse_module file(Source_input.read file)with
  | Ok m->m|Err _->raise Unsupported)(I.source_inputs before @ I.source_inputs after)
let entity modules identity = require(List.find_map(fun (m:module_form)->
 List.find_map(function DEntity e when m.module_name ^ "." ^ e.name=identity->Some(m,e)|_->None)m.decls)modules)
let exported (m:module_form) name=List.exists(function ExportName n|ExportAdt n->n=name)m.exports
let primitive shape = List.find_opt(fun(home,_)->shape.I.type_identity=Migration_additive.primitive home)
  ["Tesl.Prelude.Int","Int";"Tesl.Float.Float","Float";"Tesl.Prelude.Bool","Bool";"Tesl.Prelude.String","String"]
let required_value previous current =
 previous.I.proof_identity=None && current.I.proof_identity=None && primitive current<>None &&
 match previous.type_identity with
 | Migration_canonical.Seq [Bytes "apply"; head; value] ->
   head=Migration_additive.primitive "Tesl.Maybe.Maybe" && value=current.type_identity
 | _->false
let owner identity = match String.rindex_opt identity '.'with
 | Some dot->String.sub identity 0 dot|None->raise Unsupported
let field_proof modules (m:module_form) (field:field_def) binder =
 let resolve=Validation_common.predicate_transport m m in
 let rec map=function
  | PredApp p when p.args=[field.name]->
    let name=resolve p.pred in
    let home=require(List.find_opt(fun(m:module_form)->m.module_name=owner name)modules)in
    let short=String.sub name(String.length home.module_name+1)(String.length name-String.length home.module_name-1)in
    if not(exported home short)then raise Unsupported;
    PredApp{p with pred=name;args=[binder]}
  | PredAnd p->PredAnd{p with left=map p.left;right=map p.right}
  | _->raise Unsupported in
 Option.map map field.proof_ann
let annotation modules home (field:field_def) shape binder =
 let module_,name=require(primitive shape)in
 let proof=field_proof modules home field binder in
 name ^ Option.fold ~none:"" ~some:(fun p->" ::: " ^ Checker.pp_proof_expr p)proof,
 "import " ^ owner module_ ^ " exposing [" ^ name ^ "]",
 Option.fold ~none:[] ~some:(fun p->
   let rec names=function PredApp p->[owner p.pred]|PredAnd p->names p.left @ names p.right in names p)proof
let names (m:module_form)=
 List.concat_map(function
  | DFunc f->[f.name]|DConst c->[c.name]|DRecord r->[r.name]|DEntity e->[e.name]
  | DType(TypeNewtype t)->[t.name]|DType(TypeAdt t)->t.name::List.map(fun(v:adt_variant)->v.ctor)t.variants
  | _->[])m.decls @ List.concat_map(fun(i:import_decl)->match i.names with ImportAll->[]|ImportExposing ns->ns)m.imports
let allocate taken base =
 let rec find n=let value=base ^ if n=0 then "" else string_of_int n in
  if List.mem value !taken then find(n+1)else(taken:=value::!taken;value)in find 0
let key identity=String.split_on_char '.' identity |> List.map String.capitalize_ascii |> String.concat ""
let todo reason="todo " ^ Compile.json_encode_string reason
let row constructor fields="Row (" ^ constructor ^ " { " ^ String.concat ", " fields ^ " })"
(* Reuse only one unambiguous, exported, pure validator of the exact field
   contract. Choosing this scaffold explicitly chooses its validation behavior;
   the completed migration still passes the normal type/proof checks. *)
let validator forms (home:module_form) (field:field_def) =
 let resolve=T.resolver forms in
 let rec same_type a b=match a,b with
  | TName a,TName b->(match resolve home Migration_ir.Type a.name,resolve home Migration_ir.Type b.name with
    | Some a,Some b->a=b|_->false)
  | TApp a,TApp b->same_type a.head b.head && same_type a.arg b.arg
  | TTuple a,TTuple b->List.length a.elems=List.length b.elems && List.for_all2 same_type a.elems b.elems
  | _->false in
 let rec same_proof binder actual expected=match actual,expected with
  | PredApp a,PredApp b->a.args=[binder] && b.args=[field.name] &&
    Option.is_some(resolve home Migration_ir.Predicate b.pred) &&
    resolve home Migration_ir.Predicate a.pred=resolve home Migration_ir.Predicate b.pred
  | PredAnd a,PredAnd b->same_proof binder a.left b.left && same_proof binder a.right b.right
  | _->false in
 let candidates=List.filter_map(function
  | DFunc f when f.kind=EstablishKind && exported home f.name && f.capabilities=[] && f.http_methods=[]->
    (match f.params,f.return_spec,field.proof_ann with
     | [p],RetMaybeAttached{outer_ty=None;binding=r;_},Some proof when p.proof_ann=None &&
       same_type p.type_expr field.type_expr && same_type r.type_expr field.type_expr &&
       Option.fold ~none:false ~some:(fun actual->same_proof r.name actual proof)r.proof_ann->
       Some(home.module_name ^ "." ^ f.name)
     | _->None)
  | _->None)home.decls in
 match candidates with [one]->Some one|_->None
(* A schema-owned constructor already supplies unrelated fields. Reuse it for
   representative fixtures when its exact signature is unambiguous; only sample
   inputs remain holes. Proof-bearing parameters go through the old validator. *)
let constructor_fixture forms (home:module_form) identity fixture = try
 let resolve=T.resolver forms in
 let candidates=List.filter_map(function
  | DFunc f when f.kind=FnKind && exported home f.name && f.capabilities=[] && f.http_methods=[]->
    (match f.return_spec with RetPlain{ty=TName t;_} when resolve home Migration_ir.Type t.name=Some(Migration_ir.Global identity)->Some f|_->None)
  | _->None)home.decls in
 let fn=match candidates with [one]->one|_->raise Unsupported in
 let args=List.mapi(fun i(p:binding)->
   let ty=match p.type_expr with TName t->require(List.find_opt(fun name->resolve home Migration_ir.Type t.name=Some(Migration_ir.Primitive name))
     ["Tesl.Prelude.Int";"Tesl.Float.Float";"Tesl.Prelude.Bool";"Tesl.Prelude.String"])|_->raise Unsupported in
   let field={name=p.name;type_expr=p.type_expr;proof_ann=p.proof_ann;db_type=None;db_column=None;loc=p.loc}in
   let check=match p.proof_ann with None->None|Some _->Some(require(validator forms home field))in
   let input=todo("Historical example for " ^ identity ^ "." ^ p.name ^ " (" ^ List.hd(List.rev(String.split_on_char '.' ty)) ^ ")")in
   "fixtureValue" ^ string_of_int i,input,check)fn.params in
 let call="Something (" ^ home.module_name ^ "." ^ fn.name ^ (if args=[]then "()" else " " ^ String.concat " "(List.map(fun(binder,input,check)->match check with Some _->binder|None->"(" ^ input ^ ")")args)) ^ ")"in
 let rec body indent=function
  | []->String.make indent ' ' ^ call
  | (_,_,None)::rest->body indent rest
  | (binder,input,Some check)::rest->let pad=String.make indent ' 'in
    pad ^ "case " ^ check ^ " (" ^ input ^ ") of\n" ^ pad ^ "  Nothing -> Nothing\n" ^
    pad ^ "  Something " ^ binder ^ " ->\n" ^ body(indent+4)rest in
 Some("fn " ^ fixture ^ "() -> Maybe " ^ identity ^ " =\n" ^ body 2 args ^ "\n")
 with Unsupported->None
let coverage requirements identity loc =
 let entries=E.requirement_entities requirements |> List.filter_map(fun(name,e)->match e with
  | E.Added _->Some{E.entity=name;kind=E.New;loc}
  | E.Removed _->Some{E.entity=name;kind=E.Drop;loc}
  | E.Paired p when p.contract_changed || p.missing_identities<>[]->
    Some{E.entity=name;kind=(if name=identity then E.Transform else E.Additive);loc}
  | _->None)in
 match E.check_requirements requirements ~entries ~loc with Ok c->c|Error _->raise Unsupported
let primitive_options ~file ~source ~before ~after ~requirements ~identity ~(previous:I.stored_entity)
    ~(current:I.stored_entity) ~missing ~loc = try
 let forms=modules before after in
 let old_home,old_entity=entity forms previous.entity_name and new_home,new_entity=entity forms current.entity_name in
 if not(exported old_home old_entity.name && exported new_home new_entity.name) ||
    previous.table_name<>current.table_name || previous.primary_key<>current.primary_key ||
    I.entity_indexes before ~entity:previous.entity_name<>I.entity_indexes after ~entity:current.entity_name then raise Unsupported;
  let parsed=match Parser.parse_module file source with Ok m->m|Err _->raise Unsupported in
  if List.mem "todo" (names parsed)then raise Unsupported;
 let taken=ref(names parsed)in
 let suffix=key identity in
 let convert=allocate taken("migrate" ^ suffix)and fixture=allocate taken("fixture" ^ suffix)in
 let shapes inv entity=I.field_shapes inv |> List.filter(fun s->s.I.stored_field.entity=entity)in
 let old=shapes before previous.entity_name and fresh=shapes after current.entity_name in
 let by_name shape=require(List.find_opt(fun s->s.I.stored_field.name=shape.I.stored_field.name)old)in
 let same_names=(List.map(fun s->s.I.stored_field.name)old |> List.sort compare) =
   (List.map(fun s->s.I.stored_field.name)fresh |> List.sort compare)in
 if not same_names then raise Unsupported;
 let changed=List.filter(fun s->(by_name s).I.stored_field.contract<>s.I.stored_field.contract)fresh in
  if changed=[] || List.exists(fun s->s.I.stored_field.name=current.primary_key ||
     not(primitive s<>None && primitive(by_name s)<>None || required_value(by_name s)s))changed then raise Unsupported;
  if List.exists(fun s->Migration_scaffold_general.without_storage (by_name s).stored_field.contract =
    Migration_scaffold_general.without_storage s.I.stored_field.contract)changed then raise Unsupported;
 let changed_name name=List.exists(fun s->s.I.stored_field.name=name)changed in
 if List.exists(fun(m:E.missing_identity)->not(changed_name m.current_field.name))missing then raise Unsupported;
 (* All field proofs must stay local. This deliberately refuses cross-field
    reverse evidence and hidden proof/type owners instead of guessing a route. *)
 List.iter(fun s->let f=require(List.find_opt(fun(f:field_def)->f.name=s.I.stored_field.name)old_entity.fields)in
  ignore(field_proof forms old_home f "previousValue"))old;
 List.iter(fun s->let f=require(List.find_opt(fun(f:field_def)->f.name=s.I.stored_field.name)new_entity.fields)in
  ignore(field_proof forms new_home f "convertedValue"))fresh;
  let fixture_context=Migration_scaffold_value.create ~forms ~taken:!taken ~validator in
  let fixture_body=Migration_scaffold_value.fixture fixture_context ~home:old_home ~identity:previous.entity_name
    ~fields:old_entity.fields ~name:fixture ~constructor:constructor_fixture in
  taken:= !(fixture_context.taken);
  let fixture_body=String.concat "\n" !(fixture_context.helpers) ^ fixture_body in
 let common_imports=["import Tesl.Migration exposing [Migrated(..)]";"import Tesl.Maybe exposing [Maybe(..)]";
  "import " ^ old_home.module_name;"import " ^ new_home.module_name] @ !(fixture_context.imports)in
 let copied=List.map(fun(f:field_def)->f.name ^ ": " ^ (if changed_name f.name then "converted" ^ String.capitalize_ascii f.name else "old." ^ f.name))new_entity.fields in
  let make ?(sample=fixture_body) id label rules body helpers imports help =
  let replacement="Migrate " ^ convert ^ " [" ^ String.concat ", " rules ^ "]"in
  let forward="fn " ^ convert ^ "(old: " ^ previous.entity_name ^ ") -> Migrated " ^ current.entity_name ^ " =\n" ^ body ^ "\n"in
  {id;label;replacement;imports=List.sort_uniq compare(common_imports @ imports);
    helpers=forward ^ "\n" ^ helpers ^ "\n" ^ sample;fixture;
    template=replacement ^ "\n\n" ^ forward ^ "\n" ^ helpers ^ "\n" ^ sample;help}in
  let required=try
   if not(List.for_all(fun s->required_value(by_name s)s)changed)then raise Unsupported;
   let taken=ref !taken in
   let rules=ref [] and helpers=ref [] and imports=ref [] in
   let body=List.map(fun shape->
    let field=shape.I.stored_field.name in
    let home,ty=require(primitive shape)in
    imports:=("import " ^ owner home ^ " exposing [" ^ ty ^ "]")::!imports;
    let reverse=allocate taken("writeBack" ^ suffix ^ String.capitalize_ascii field)in
    helpers:= !helpers @ ["fn " ^ reverse ^ "(current: " ^ current.entity_name ^ ") -> Maybe " ^ ty ^ " =\n  Something current." ^ field ^ "\n"];
    rules:= !rules @ ["Retype " ^ field;"WriteBack " ^ field ^ " " ^ field ^ " " ^ reverse];
    "  let converted" ^ String.capitalize_ascii field ^ " = case old." ^ field ^ " of\n" ^
    "    Nothing -> " ^ todo("Value to use when " ^ identity ^ "." ^ field ^ " is missing (" ^ ty ^ ")") ^
    "\n    Something value -> value\n")changed |> String.concat ""in
   let sample=Option.value(constructor_fixture forms old_home previous.entity_name fixture)~default:fixture_body in
   [make ~sample "require-value" "Keep existing values; choose a value for missing fields" !rules
     (body ^ "  " ^ row current.entity_name copied) (String.concat "\n" !helpers) !imports
     "These optional fields are now required. Existing Something values are kept exactly; you choose the value for Nothing. Tesl generates the row copies, Maybe handling, historical write-back, storage rules, imports and fixture structure. Fill the missing-value placeholders and representative historical fixture values. Historical writes still use Maybe, so Nothing written by an old application is converted using your chosen value."]
   with Unsupported->[]in
 let retype automatic=try
  let taken=ref !taken in
  let imports=ref [] and helpers=ref [] and rules=ref [] in
  let conversions=List.map(fun shape->
   let field=shape.I.stored_field.name and old_shape=by_name shape in
   let old_field=require(List.find_opt(fun(f:field_def)->f.name=field)old_entity.fields)
   and new_field=require(List.find_opt(fun(f:field_def)->f.name=field)new_entity.fields)in
   let old_ann,old_import,old_proofs=annotation forms old_home old_field old_shape "value" in
   let target_ann,target_import,target_proofs=annotation forms new_home new_field shape "convertedValue"in
   let reverse_ann,_,_=annotation forms old_home old_field old_shape "previousValue"in
   imports:=old_import::target_import::List.map(fun name->"import " ^ name)(old_proofs @ target_proofs) @ !imports;
    let function_=allocate taken("convert" ^ suffix ^ String.capitalize_ascii field)
    and reverse=allocate taken("writeBack" ^ suffix ^ String.capitalize_ascii field)in
    let forward_body,reverse_body=if automatic then begin
      if primitive shape<>primitive old_shape then raise Unsupported;
      let forward=if new_field.proof_ann=None then "Something value"else require(validator forms new_home new_field) ^ " value"in
      let backward=if old_field.proof_ann=None then "Something current." ^ field else
        require(validator forms old_home old_field) ^ " current." ^ field in
      forward,backward
    end else
      todo("Convert the exact historical value; return Something with the target type/proof, or Nothing"),
      todo("Return Something with the exact historical type and proof for " ^ previous.entity_name ^ "." ^ field ^ ", or Nothing to refuse incompatible writes" ^
        (match old_field.type_expr with
         | TApp {head=TName {name="Maybe";_};_} -> " (Something Nothing stores NULL in the old column; Nothing refuses the old binary's write)"
         | _ -> "")) in
    let forward_total=automatic && new_field.proof_ann=None in
    helpers:= !helpers @ (if forward_total then []else["fn " ^ function_ ^ "(value: " ^ old_ann ^ ") -> Maybe (" ^
     (if shape.proof_identity=None then snd(require(primitive shape)) else "convertedValue: " ^ target_ann) ^ ") =\n  " ^
     forward_body ^ "\n"]) @ [
    "fn " ^ reverse ^ "(current: " ^ current.entity_name ^ ") -> Maybe (" ^
    (if old_shape.proof_identity=None then reverse_ann else "previousValue: " ^ reverse_ann) ^ ") =\n  " ^
     reverse_body ^ "\n"];
   rules:= !rules @ ["Retype " ^ field;"WriteBack " ^ field ^ " " ^ field ^ " " ^ reverse];
    field,function_,forward_total)changed in
  let rec body indent=function
   | []->String.make indent ' ' ^ row current.entity_name copied
    | (field,_,true)::rest->String.make indent ' ' ^ "let converted" ^ String.capitalize_ascii field ^ " = old." ^ field ^ "\n" ^ body indent rest
    | (field,function_,false)::rest->let pad=String.make indent ' 'in
     pad ^ "case " ^ function_ ^ " old." ^ field ^ " of\n" ^
     pad ^ "  Nothing -> " ^ todo("Choose an explicit Reject reason or other reviewed conversion policy for " ^ identity ^ "." ^ field) ^ "\n" ^
     pad ^ "  Something converted" ^ String.capitalize_ascii field ^ " ->\n" ^ body(indent+4)rest in
   [make (if automatic then "migrate-validators" else "migrate-retype")
     (if automatic then "Reuse existing validators for changed field proofs" else "Convert changed primitive fields with an explicit historical write-back") !rules (body 2 conversions)
     (String.concat "\n" !helpers) !imports
      ((if automatic then "Reuse the uniquely matching exported establish functions for the new and historical field proofs. The compiler fills validator calls, Maybe handling, row copies, Retype/WriteBack rules, imports and fixture structure. Choose rejection reasons and representative fixture values. Nothing from historical write-back refuses an incompatible application write until the old columns are retired. Validators may normalize values: review their behavior and test both directions. This is Retype, not Same or same-column Revalidate."
       else "The compiler filled the row mapping, changed-field rules, exact forward/reverse signatures, historical fixture and required imports. Implement each conversion, rejected-row policy, historical write-back policy and fixture value. No values, rejection/discard policy, Same proof or inverse behavior has been guessed. Cross-field proofs, hidden owners, key changes, renamed/removed fields and index changes are deliberately not scaffolded. The complete source remains blocked until every custom hole is implemented and all compiler checks pass.") ^
       (if List.exists(fun s->(by_name s).I.proof_identity<>None)changed then Migration_scaffold_general.historical_proof_help else ""))]
  with Unsupported->[]in
 let revalidate=try match changed with
  | [shape]->
    let field=shape.I.stored_field.name in
    let coverage=coverage requirements identity loc in
    let candidates=List.filter_map(function
     | DFunc f when f.kind=EstablishKind && exported new_home f.name->Some f|_->None)new_home.decls in
    candidates |> List.filter_map(fun (establish:func_decl)->try
     let reference=new_home.module_name ^ "." ^ establish.name in
     let rules=[R.Revalidate{field;function_ref=EVar{name=reference;loc};loc}]in
     let mapped=match R.check coverage ~entries:[{R.entity=identity;mode=R.Migrate;rules;loc}]with
      | Ok r->require(List.find_opt(fun(r:R.entity)->r.identity=identity)(R.entities r))|Error _->raise Unsupported in
     let values=List.map(fun(f:field_def)->f.name ^ ": " ^ (if f.name=field then "validated" else "old." ^ f.name))new_entity.fields in
     let body rejection="  case " ^ reference ^ " old." ^ field ^ " of\n    Nothing -> " ^ rejection ^
      "\n    Something validated -> " ^ row current.entity_name values in
     let probe="fn " ^ convert ^ "(old: " ^ previous.entity_name ^ ") -> Migrated " ^ current.entity_name ^ " =\n" ^ body "Reject \"classification probe only\"" ^ "\n"in
     let probe_module=match Parser.parse_module file(source ^ "\n" ^ probe)with Ok m->m|Err _->raise Unsupported in
     let declaration=require(List.find_map(function DFunc f when f.name=convert->Some f|_->None)probe_module.decls)in
     let root={probe_module with imports=probe_module.imports @
       [{module_name="Tesl.Maybe";names=ImportExposing["Maybe(..)"];loc};
        {module_name="Tesl.Migration";names=ImportExposing["Migrated(..)"];loc};
        {module_name=new_home.module_name;names=ImportAll;loc}]}in
     let resolve owner ns name=T.resolver(forms @ [root])owner ns name in
     (match Migration_revalidate.check ~resolve ~modules:forms ~root ~owner:root ~declaration ~mapping:mapped with
      | Ok()->()|Error _->raise Unsupported);
     Some(make ("revalidate:" ^ reference) ("Revalidate using " ^ reference)
       ["Revalidate " ^ field ^ " " ^ reference]
       (body(todo("Choose the explicit Reject reason or reviewed policy when " ^ reference ^ " returns Nothing"))) "" []
       "This existing target-owned establish was checked for the exact primitive field proof and original-value preservation, including all historical Same evidence. The scaffold fills the call, result handling, copied fields, rule and historical fixture. Choose the rejected-row policy and fixture values; these holes remain compile-blocking. Revalidate does not replace changed historical proof meaning.")
    with Unsupported->None)
   | _::_::_->
     let coverage=coverage requirements identity loc in
     let selected=List.map(fun shape->
       let field=shape.I.stored_field.name in
       let definition=require(List.find_opt(fun(f:field_def)->f.name=field)new_entity.fields)in
       field,require(validator forms new_home definition))changed in
     let rules=List.map(fun(field,function_)->R.Revalidate{field;function_ref=EVar{name=function_;loc};loc})selected in
     let mapped=match R.check coverage ~entries:[{R.entity=identity;mode=R.Migrate;rules;loc}]with
       | Ok r->require(List.find_opt(fun(r:R.entity)->r.identity=identity)(R.entities r))|Error _->raise Unsupported in
     let values=List.map(fun(f:field_def)->f.name ^ ": " ^ (if List.mem_assoc f.name selected then "validated" ^ String.capitalize_ascii f.name else "old." ^ f.name))new_entity.fields in
     let rec body reject indent=function
       | []->String.make indent ' ' ^ row current.entity_name values
       | (field,function_)::rest->let pad=String.make indent ' 'in
         pad ^ "case " ^ function_ ^ " old." ^ field ^ " of\n" ^ pad ^ "  Nothing -> " ^ reject field ^ "\n" ^
         pad ^ "  Something validated" ^ String.capitalize_ascii field ^ " ->\n" ^ body reject (indent+4) rest in
     let probe="fn " ^ convert ^ "(old: " ^ previous.entity_name ^ ") -> Migrated " ^ current.entity_name ^ " =\n" ^ body(fun _->"Reject \"classification probe only\"")2 selected ^ "\n"in
     let probe_module=match Parser.parse_module file(source ^ "\n" ^ probe)with Ok m->m|Err _->raise Unsupported in
     let declaration=require(List.find_map(function DFunc f when f.name=convert->Some f|_->None)probe_module.decls)in
     let root={probe_module with imports=probe_module.imports @
       [{module_name="Tesl.Maybe";names=ImportExposing["Maybe(..)"];loc};{module_name="Tesl.Migration";names=ImportExposing["Migrated(..)"];loc};
        {module_name=new_home.module_name;names=ImportAll;loc}]}in
     let resolve owner ns name=T.resolver(forms @ [root])owner ns name in
     (match Migration_revalidate.check ~resolve ~modules:forms ~root ~owner:root ~declaration ~mapping:mapped with Ok()->()|Error _->raise Unsupported);
     [make "revalidate-fields" "Validate all changed fields without changing their stored values"
       (List.map(fun(field,function_)->"Revalidate " ^ field ^ " " ^ function_)selected)
       (body(fun field->todo("Choose a Reject reason or reviewed policy when " ^ identity ^ "." ^ field ^ " fails validation"))2 selected) "" []
       "Each target-owned validator was checked for the exact field proof and preservation of its original input. Tesl fills all validator calls, result branches, copied fields, rules and fixture structure. Supply rejected-row policies and historical examples. Changed historical proof meaning still requires a conversion rather than this same-column route."]
   | _->[] with Unsupported->[]in
  required @ revalidate @ retype true @ retype false
  with Unsupported | Migration_scaffold_value.Unsupported _->[]

let options ~file ~source ~before ~after ~requirements ~identity ~previous ~current ~missing ~loc =
 let specialized=primitive_options ~file ~source ~before ~after ~requirements ~identity ~previous ~current ~missing ~loc in
 let general=Migration_scaffold_general.options ~file ~source ~before ~after ~identity ~previous ~current ~missing
   ~validator ~constructor:constructor_fixture ()
 |> List.map(fun(p:Migration_scaffold_general.t)->
   {id=p.id;label=p.label;template=p.template;help=p.help;replacement=p.replacement;imports=p.imports;helpers=p.helpers;fixture=p.fixture})in
 if specialized<>[] then specialized @ List.filter(fun p->p.id="delete-rows")general else general
