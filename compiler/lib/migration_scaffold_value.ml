(* Typed value adapters shared by row and queue authoring. Rebuild nominal
   values explicitly; identical spelling never authorizes a cross-version cast. *)
open Ast
module I = Migration_inventory
module T = Migration_transform
module IR = Migration_ir
exception Unsupported of string
let refuse message = raise (Unsupported message)
let todo message = "todo " ^ Compile.json_encode_string message
let owner name = match String.rindex_opt name '.' with Some i -> String.sub name 0 i | None -> ""
let short name = List.hd (List.rev (String.split_on_char '.' name))
let exported (m:module_form) name = List.exists (function ExportName n | ExportAdt n -> n=name) m.exports
let modules before after = I.source_inputs before @ I.source_inputs after |> List.sort_uniq compare |> List.map (fun (file,_) ->
  match Parser.parse_module file (Source_input.read file) with Ok m -> m | Err e -> refuse e.msg)
let names (m:module_form) = List.concat_map (function
 | DFunc f->[f.name] | DConst c->[c.name] | DRecord r->[r.name] | DEntity e->[e.name]
 | DType(TypeAdt t)->t.name::List.map(fun(v:adt_variant)->v.ctor)t.variants | DType(TypeNewtype t)->[t.name] | _->[])m.decls @
 List.concat_map(fun(i:import_decl)->match i.names with ImportExposing names->names | ImportAll->[])m.imports
let allocate taken base = let rec loop n = let name=base ^ (if n=0 then "" else string_of_int n) in
 if List.mem name !taken then loop(n+1) else(taken:=name::!taken;name) in loop 0
type spec = { home:module_form; ty:type_expr; proof:proof_expr option; subject:string }
let field home (f:field_def) = {home;ty=f.type_expr;proof=f.proof_ann;subject=f.name}
let plain home ty = {home;ty;proof=None;subject=""}
type adapter = { name:string; total:bool }
type context = { forms:module_form list; taken:string list ref; imports:string list ref;
 helpers:string list ref; mutable active:(string * adapter) list;
 validator:module_form list -> module_form -> field_def -> string option }
let create ~forms ~taken ~validator =
 if List.mem "todo" taken then refuse "Rename the existing todo binding before generating migration placeholders; a placeholder must not resolve to executable user code.";
 {forms;taken=ref taken;imports=ref [];helpers=ref [];active=[];validator}
let add_import c text = if not(List.mem text !(c.imports))then c.imports:=text::!(c.imports)
let use c ns home name = match T.resolver c.forms home ns name with
 | Some(IR.Primitive full) ->
   let label=short full in
   let group=if List.mem label ["Maybe";"Bool";"Either"] then label ^ "(..)" else label in
   add_import c ("import " ^ owner full ^ " exposing [" ^ group ^ "]"); label
 | Some(IR.Global full) ->
   let m=match List.find_opt(fun(m:module_form)->m.module_name=owner full)c.forms with Some m->m|None->refuse("Missing declaration owner: " ^ full)in
   if not(exported m (short full))then refuse(match Validation_common.schema_module_parts m.module_name with
     | Some(_,"VCurrent",_)->"Export " ^ full ^ " and its required constructors/validators from the current schema, then recheck."
     | _->"The historical declaration " ^ full ^ " is private. Expose the needed API in a compatible revision before changing its representation; do not edit frozen history.");
   if ns=IR.Type && List.exists(function DType(TypeAdt a)->a.name=short full && a.params<>[]|_->false)m.decls then
     refuse("Native emission of the generic stored ADT " ^ full ^ " is not supported by this authoring route. Use a concrete record/ADT representation before starting the migration; keep frozen history unchanged.");
   add_import c ("import " ^ m.module_name);full
 | _ -> refuse("Cannot resolve " ^ name ^ " in " ^ home.module_name)
let rec ty c home = function
 | TName t -> use c IR.Type home t.name
 | TApp t -> ty c home t.head ^ " (" ^ ty c home t.arg ^ ")"
 | TTuple t -> "(" ^ String.concat ", "(List.map(ty c home)t.elems) ^ ")"
 | TVar _ | TFun _ -> refuse "Stored function or unbound generic types need a concrete conversion signature."
let rec proof c s binder = function
 | PredApp p when p.args=[s.subject] -> use c IR.Predicate s.home p.pred ^ " " ^ binder
 | PredAnd p -> proof c s binder p.left ^ " && " ^ proof c s binder p.right
 | _ -> refuse "Cross-field proof callbacks cannot be generated; use a supported staged schema change."
let annotation c s binder = ty c s.home s.ty ^ Option.fold ~none:"" ~some:(fun p->" ::: " ^ proof c s binder p)s.proof
let result c s total =
 let value=match s.proof with None->ty c s.home s.ty|Some _->"converted: " ^ annotation c s "converted"in
 if total then value else "Maybe (" ^ value ^ ")"
let primitive c s = match s.ty with TName t -> (match T.resolver c.forms s.home IR.Type t.name with Some(IR.Primitive p)->Some p|_->None)|_->None
let application c s name = match s.ty with
 | TApp t -> (match primitive c (plain s.home t.head) with Some p when short p=name ->Some(plain s.home t.arg)|_->None)
 | _->None
let equal_type c a b =
 let rec shape home = function
  | TName t -> Option.map(fun x->`Name x)(T.resolver c.forms home IR.Type t.name)
  | TApp t -> (match shape home t.head,shape home t.arg with Some h,Some a->Some(`App(h,a))|_->None)
  | _ ->None in
 match shape a.home a.ty,shape b.home b.ty with Some a,Some b->a=b|_->false
let named c s =
 let rec head=function TApp t->head t.head|TName t->T.resolver c.forms s.home IR.Type t.name|_->None in
 match head s.ty with
 | Some(IR.Global name) -> List.find_map(fun(m:module_form)->List.find_map(function
   | DRecord r when m.module_name ^ "." ^ r.name=name ->Some(m,`Record r)
   | DType(TypeAdt a) when m.module_name ^ "." ^ a.name=name ->Some(m,`Adt(a.name,a.params,a.variants))
   | DType(TypeNewtype n) when m.module_name ^ "." ^ n.name=name ->Some(m,`Newtype(n.name,n.base_type,n.secret))
   | _->None)m.decls)c.forms
 | _->None
let ctor c (home:module_form) type_name name =
 if not(List.exists(function ExportAdt n->n=type_name|ExportName n->n=name)home.exports) then
   refuse("Export the constructors of " ^ home.module_name ^ "." ^ type_name ^ " to map its variants.");
 add_import c("import " ^ home.module_name);home.module_name ^ "." ^ name
let rec sample c s reason depth =
 if depth>5 || s.proof<>None then todo(reason ^ " : " ^ annotation c s s.subject)else
 match named c s with
 | Some(home,`Record r) when r.invariant=None ->
   let name=use c IR.Type home r.name in
   name ^ " { " ^ String.concat ", "(List.map(fun(f:field_def)->f.name ^ ": " ^ sample c (field home f)(reason ^ "." ^ f.name)(depth+1))r.fields) ^ " }"
 | _ -> todo(reason ^ " : " ^ ty c s.home s.ty)
let pad n = String.make n ' '
let wrapped total value = if total then value else "Something (" ^ value ^ ")"
(* Bind optional conversion results without inventing a fallback. Failures
   propagate to the row/job's explicit rejection policy. *)
let sequence total conversions final =
 let rec loop indent = function
 | [] -> pad indent ^ wrapped total final
 | (binding,expr,false)::rest -> pad indent ^ "let " ^ binding ^ " = " ^ expr ^ "\n" ^ loop indent rest
 | (binding,expr,true)::rest -> pad indent ^ "case " ^ expr ^ " of\n" ^ pad indent ^ "  Nothing -> Nothing\n" ^
    pad indent ^ "  Something " ^ binding ^ " ->\n" ^ loop(indent+4)rest in loop 2 conversions
let rec convert c ~label ~reason old fresh =
 let old_ty=annotation c old "value" and new_ty=annotation c fresh "converted"in
  let key=old_ty ^ " -> " ^ new_ty in
 match List.assoc_opt key c.active with Some pending->pending|None->
 let name=allocate c.taken label in
  let pending={name;total=false}in c.active<-(key,pending)::c.active;
 let finish total body =
   c.active<-List.remove_assoc key c.active;
   add_import c "import Tesl.Maybe exposing [Maybe(..)]";
   c.helpers:= !(c.helpers) @ ["fn " ^ name ^ "(value: " ^ old_ty ^ ") -> " ^ result c fresh total ^ " =\n" ^ body ^ "\n"];
   {name;total} in
 let call child expression=child.name ^ " (" ^ expression ^ ")"in
  let convert_child suffix a b = convert c ~label:(label ^ suffix) ~reason:(reason ^ "." ^ suffix) a b in
 let fields old_home old_fields new_home new_fields accessor constructor =
   let converted=List.mapi(fun index(f:field_def)->
     let target=field new_home f in
     let variable="mapped" ^ string_of_int index in
     match List.find_opt(fun(p:field_def)->p.name=f.name)old_fields with
     | Some previous -> let source=field old_home previous in
       if target.proof=None && equal_type c source target then variable,accessor previous.name,false,f.name
       else let adapter=convert_child(String.capitalize_ascii f.name)source target in
         variable,call adapter(accessor previous.name),not adapter.total,f.name
     | None -> variable,sample c target ("Value for " ^ reason ^ "." ^ f.name)0,false,f.name)new_fields in
   let total=List.for_all(fun(_,_,rejects,_)->not rejects)converted in
   let value=constructor ^ " { " ^ String.concat ", "(List.map(fun(v,_,_,field)->field ^ ": " ^ v)converted) ^ " }" in
   total,(fun total->sequence total(List.map(fun(v,e,r,_)->v,e,r)converted)value) in
 if equal_type c old fresh && Option.map(proof c old "_")old.proof=Option.map(proof c fresh "_")fresh.proof then finish true "  value"
 else if fresh.proof<>None then begin
   let f={name=fresh.subject;type_expr=fresh.ty;proof_ann=fresh.proof;db_type=None;db_column=None;loc=Location.dummy_loc fresh.home.source_file}in
   match c.validator c.forms fresh.home f with
   | Some validator ->
     add_import c("import " ^ fresh.home.module_name);
     let raw=if equal_type c {old with proof=None} {fresh with proof=None}then None else
       Some(convert_child "Raw" {old with proof=None}{fresh with proof=None})in
     let validation expression=validator ^ " (" ^ expression ^ ")"in
      (match raw with
       | None->finish false("  " ^ validation "value")
       | Some adapter when adapter.total->finish false("  " ^ validation(call adapter "value"))
       | Some adapter->finish false("  case " ^ call adapter "value" ^ " of\n    Nothing -> Nothing\n    Something converted -> " ^ validation "converted"))
    | _ -> finish false("  " ^ todo("Validate " ^ reason ^ "; return Something with the target proof, or Nothing to reject"))
 end else if equal_type c old fresh then finish true "  value"
 else match application c old "Maybe",application c fresh "Maybe" with
 | Some a,Some b ->
   let inner=convert_child "Present" a b in
   let some=if inner.total then "    Something present -> Something (" ^ call inner "present" ^ ")" else
     "    Something present ->\n      case " ^ call inner "present" ^ " of\n        Nothing -> Nothing\n        Something converted -> Something (Something converted)"in
   finish inner.total("  case value of\n    Nothing -> " ^ wrapped inner.total "Nothing" ^ "\n" ^ some)
  | Some a,None ->
    let inner=convert_child "Present" a fresh in
    finish false("  case value of\n    Nothing -> Nothing\n    Something present -> " ^ wrapped (not inner.total) (call inner "present"))
 | None,Some b ->
   let inner=convert_child "Present" old b in
   if inner.total then finish true("  Something (" ^ call inner "value" ^ ")") else
   finish false("  case " ^ call inner "value" ^ " of\n    Nothing -> Nothing\n    Something converted -> Something (Something converted)")
 | None,None ->
 match application c old "List",application c fresh "List" with
 | Some a,Some b ->
   let inner=convert_child "Item" a b in
   if inner.total then begin add_import c "import Tesl.List exposing [List.map]";finish true("  List.map " ^ inner.name ^ " value")end else begin
     add_import c "import Tesl.List exposing [List.foldr, List.append]";
     let step=allocate c.taken(label ^ "Step")in
     c.helpers:= !(c.helpers) @ ["fn " ^ step ^ "(item: " ^ ty c a.home a.ty ^ ", rest: Maybe (" ^ ty c fresh.home fresh.ty ^ ")) -> Maybe (" ^ ty c fresh.home fresh.ty ^ ") =\n" ^
       "  case rest of\n    Nothing -> Nothing\n    Something values ->\n      case " ^ call inner "item" ^ " of\n        Nothing -> Nothing\n        Something converted -> Something (List.append [converted] values)\n"];
     finish false("  List.foldr " ^ step ^ " (Something []) value")
   end
 | _ ->
 match named c old,named c fresh with
 | Some(a,`Record previous),Some(b,`Record current) when previous.invariant=None && current.invariant=None ->
   let total,body=fields a previous.fields b current.fields (fun name->"value." ^ name)(use c IR.Type b current.name)in finish total(body total)
 | Some(a,`Adt(old_name,old_params,previous)),Some(b,`Adt(new_name,new_params,current)) when old_params=[] && new_params=[] ->
   let arms=List.map(fun(v:adt_variant)->
     let pattern=ctor c a old_name v.ctor ^ (if v.fields=[]then ""else" { " ^ String.concat ", "(List.mapi(fun i(f:field_def)->f.name ^ " = oldField" ^ string_of_int i)v.fields) ^ " }")in
     match List.find_opt(fun(w:adt_variant)->w.ctor=v.ctor)current with
      | None -> pattern,false,(fun _->"  " ^ todo("Map removed or renamed variant " ^ a.module_name ^ "." ^ v.ctor ^
        " to Something of " ^ ty c fresh.home fresh.ty ^ ", or Nothing to reject"))
     | Some w when w.fields=[] -> let name=ctor c b new_name w.ctor in pattern,true,(fun total->"  " ^ wrapped total name)
     | Some w -> let total,body=fields a v.fields b w.fields
       (fun name->"oldField" ^ string_of_int(fst(List.find(fun(_,(f:field_def))->f.name=name)(List.mapi(fun i(f:field_def)->i,f)v.fields)))) (ctor c b new_name w.ctor)in pattern,total,body)previous in
   let total=List.for_all(fun(_,t,_)->t)arms in
   let arms=List.map(fun(pattern,_,emit)->let body=emit total in
     "    " ^ pattern ^ " ->\n" ^ String.concat "\n"(List.map(fun line->"    " ^ line)(String.split_on_char '\n' body)))arms in
   finish total("  case value of\n" ^ String.concat "\n" arms)
 | Some(_,`Newtype(_,a,false)),Some(home,`Newtype(name,b,false)) ->
   let old_home=match named c old with Some(home,_)->home|_->assert false in
   let inner=convert_child "Value" (plain old_home a)(plain home b)in
   let constructor=use c IR.Type home name in
   if inner.total then finish true("  " ^ constructor ^ " (" ^ call inner "value.value" ^ ")") else
   finish false("  case " ^ call inner "value.value" ^ " of\n    Nothing -> Nothing\n    Something converted -> Something (" ^ constructor ^ " converted)")
  | _ -> finish false("  " ^ todo("Convert " ^ reason ^ " from " ^ old_ty ^ " to Something of " ^ ty c fresh.home fresh.ty ^ ", or Nothing to reject"))

let input c ~label ~reason spec =
 if spec.proof=None then sample c spec reason 0,false else
 let f={name=spec.subject;type_expr=spec.ty;proof_ann=spec.proof;db_type=None;db_column=None;loc=Location.dummy_loc spec.home.source_file}in
 let raw=sample c {spec with proof=None} reason 0 in
 match c.validator c.forms spec.home f with
  | Some fn -> add_import c("import " ^ spec.home.module_name);
    fn ^ " (" ^ raw ^ ")",true
  | None ->
    let name=allocate c.taken label in
    add_import c "import Tesl.Maybe exposing [Maybe(..)]";
    c.helpers:= !(c.helpers) @ ["fn " ^ name ^ "(value: " ^ ty c spec.home spec.ty ^ ") -> " ^ result c spec false ^ " =\n  " ^
      todo(reason ^ "; validate value and return Something with " ^ annotation c spec "converted" ^ ", or Nothing") ^ "\n"];
    name ^ " (" ^ raw ^ ")",true

let fixture c ~home ~identity ~fields ~name ~constructor =
 match constructor c.forms home identity name with Some text->text|None->
 let entries=List.mapi(fun index(f:field_def)->
   let variable="sample" ^ string_of_int index in
   let expression,rejects=input c ~label:(name ^ String.capitalize_ascii f.name)
     ~reason:("Historical example for " ^ identity ^ "." ^ f.name)(field home f)in
   variable,expression,rejects,f.name)fields in
 let total=List.for_all(fun(_,_,rejects,_)->not rejects)entries in
 let value=identity ^ " { " ^ String.concat ", "(List.map(fun(v,_,_,field)->field ^ ": " ^ v)entries) ^ " }"in
 add_import c("import " ^ home.module_name);
 "fn " ^ name ^ "() -> " ^ (if total then identity else "Maybe " ^ identity) ^ " =\n" ^
 sequence total(List.map(fun(v,e,r,_)->v,e,r)entries)value ^ "\n"
