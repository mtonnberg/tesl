(** Small, effect-free compile-time evaluator. Unknown operations refuse rather
    than invoking user code in a subprocess or guessing runtime behaviour. *)
open Ast
type value = Int of string | String of string | Bool of bool | Unit | Nothing | Something of value
type reference = Primitive of string | Function of module_form * func_decl | Constant of module_form * const_form
exception Unsupported of string
exception Rejected
let refuse text = raise (Unsupported text)
let normalize s =
  let negative=String.length s>0 && s.[0]='-'in
  let start=if negative then 1 else 0 in
  let rec skip i=if i<String.length s-1 && s.[i]='0'then skip(i+1)else i in
  let first=skip start in
  let digits=String.sub s first(String.length s-first)in
  if digits="" || not(String.for_all(fun c->c>='0'&&c<='9')digits)then refuse "invalid integer literal";
  if String.length digits>4096 then refuse "integer exceeds the 4096-digit compile-time limit";
  (if negative && digits<>"0"then "-"else "") ^ digits
let integer s=Int(normalize s)
let string s=if String.length s>65536 || not(String.is_valid_utf_8 s)then refuse "string exceeds compile-time bounds or is not valid UTF-8"else String s
let negate s=if s="0"then s else if s.[0]='-'then String.sub s 1(String.length s-1)else "-" ^ s
let parts s=if s.[0]='-'then true,String.sub s 1(String.length s-1)else false,s
let abs_compare a b=let n=Int.compare(String.length a)(String.length b)in if n=0 then String.compare a b else n
let int_compare a b=let na,a=parts a and nb,b=parts b in
  if na<>nb then if na then -1 else 1 else (if na then -1 else 1)*abs_compare a b
let add_abs a b =
  let size=max(String.length a)(String.length b)in
  let out=Bytes.make(size+1)'0'and carry=ref 0 in
  for i=0 to size-1 do
    let digit s=let j=String.length s-1-i in if j<0 then 0 else Char.code s.[j]-48 in
    let n=digit a+digit b+ !carry in
    Bytes.set out(size-i)(Char.chr(48+n mod 10));carry:=n/10
  done;Bytes.set out 0(Char.chr(48+ !carry));normalize(Bytes.to_string out)
let sub_abs a b =
  let out=Bytes.of_string a and borrow=ref 0 in
  for i=0 to String.length a-1 do
    let j=String.length b-1-i in
    let n=Char.code a.[String.length a-1-i]-48- !borrow-(if j<0 then 0 else Char.code b.[j]-48)in
    borrow:=(if n<0 then 1 else 0);
    Bytes.set out(String.length a-1-i)(Char.chr(48+(if n<0 then n+10 else n)))
  done;normalize(Bytes.to_string out)
let add a b=let na,aa=parts a and nb,bb=parts b in
  if na=nb then let n=add_abs aa bb in if na then negate n else n else
  let c=abs_compare aa bb in
  if c=0 then "0"else if c>0 then let n=sub_abs aa bb in if na then negate n else n
  else let n=sub_abs bb aa in if nb then negate n else n
let multiply a b =
  let na,a=parts a and nb,b=parts b in
  let out=Array.make(String.length a+String.length b)0 in
  for i=String.length a-1 downto 0 do
    let carry=ref 0 in
    for j=String.length b-1 downto 0 do
      let n=(Char.code a.[i]-48)*(Char.code b.[j]-48)+out.(i+j+1)+ !carry in
      out.(i+j+1)<-n mod 10;carry:=n/10
    done;out.(i)<-out.(i)+ !carry
  done;
  let value=normalize(String.init(Array.length out)(fun i->Char.chr(48+out.(i))))in
  if na<>nb then negate value else value
let divide a b =
  let na,a=parts a and nb,b=parts b in
  if b="0"then raise Rejected;
  let remainder=ref "0"in
  let quotient=String.init(String.length a)(fun i->
    remainder:=normalize(!remainder ^ String.make 1 a.[i]);
    let digit=ref 0 in
    while abs_compare !remainder b>=0 do remainder:=sub_abs !remainder b;incr digit done;
    Char.chr(48+ !digit)) |> normalize in
  (if na<>nb then negate quotient else quotient),(if na then negate !remainder else !remainder)
let literal = function
 | ELit{lit=LInt n;_}->integer(string_of_int n) | ELit{lit=LBigInt n;_}->integer n
 | ELit{lit=LString s;_}->string s | ELit{lit=LBool b;_}->Bool b
 | EUnop{op=UNeg;arg=ELit{lit=LInt n;_};_}->integer(negate(normalize(string_of_int n)))
 | EUnop{op=UNeg;arg=ELit{lit=LBigInt n;_};_}->integer(negate(normalize n))
 | EConstructor{name="True";args=[];_}->Bool true
 | EConstructor{name="False";args=[];_}->Bool false
 | _->refuse "literal proofs currently require an Int, String or Bool literal"
let bool=function Bool b->b|_->refuse "expected a Bool during literal validation"
let name=function EVar n->Some n.name|EConstructor{name;args=[];_}->Some name
 | EField{obj=EConstructor{name;args=[];_};field;_}->Some(name ^ "." ^ field)|_->None
let rec application args=function EApp e->application(e.arg::args)e.fn
 | EConstructor c when c.args<>[]->EConstructor{c with args=[]},c.args @ args|fn->fn,args
let points s=let rec loop i acc=if i=String.length s then List.rev acc else
 let d=String.get_utf_8_uchar s i in let n=Uchar.utf_decode_length d in
 loop(i+n)((i,n,Uchar.to_int(Uchar.utf_decode_uchar d))::acc)in loop 0 []
let space n=(n>=9&&n<=13)||(n>=0x2000&&n<=0x200a)||List.mem n [0x20;0x85;0xa0;0x1680;0x2028;0x2029;0x202f;0x205f;0x3000]
let trim s=let rec drop=function (_,_,n)::xs when space n->drop xs|xs->xs in
 match points s |> drop |> List.rev |> drop |> List.rev with
 | []->""|(first,_,_)::_ as ps->let last,n,_=List.hd(List.rev ps)in String.sub s first(last+n-first)
let evaluate ~resolve ~visit owner declaration input =
 let budget=ref 100000 in
 let charge n=budget:= !budget-n;if !budget<0 then refuse "literal validation exceeded its compile-time work budget"in
  let rec call depth (home:module_form) (fn:func_decl) args =
  charge 1;if depth>128 then refuse "literal validation exceeded its call-depth limit";
  if not(List.mem fn.kind [FnKind;EstablishKind;CheckKind]) || fn.capabilities<>[] || fn.http_methods<>[] then refuse "literal validation requires pure functions";
  let args=if fn.params=[] && args=[Unit]then []else args in
  if List.length fn.params<>List.length args then refuse "literal validator arity mismatch";
  visit home (DFunc fn);
  expr(depth+1)home(List.map2(fun(p:binding)v->p.name,v)fn.params args)fn.body
 and expr depth home env value =
  charge 1;
  let depth=depth+1 in
  if depth>512 then refuse "literal validation exceeded its expression-depth limit";
  let run=expr depth home env in
  let primitive name args=match name,args with
   | "Tesl.Maybe.Something",[v]->Something v|"Tesl.Maybe.Nothing",[]->Nothing
   | "Tesl.Prelude.True",[]->Bool true|"Tesl.Prelude.False",[]->Bool false
   | "Tesl.Prelude.Unit",[]->Unit
   | "Tesl.String.String.trim",[String s]->charge(String.length s);string(trim s)
   | "Tesl.String.String.length",[String s]->charge(String.length s);integer(string_of_int(List.length(points s)))
   | _->refuse("unsupported compile-time primitive: " ^ name)in
  let invoke head args=match name head with
   | Some n when not(List.mem_assoc n env)->(match resolve home n with
      | Some(Primitive n)->primitive n args|Some(Function(m,f))->call depth m f args
      | Some(Constant(m,c)) when args=[]->visit m (DConst c);expr depth m [] c.value
      | Some(Constant _)->refuse "a literal validator cannot call a constant as a function"
      | None->refuse("unresolved compile-time function: " ^ n))
   | _->refuse "literal validation does not support dynamic function calls"in
  match value with
  | ELit{lit=LString s;_}->charge(String.length s);literal value
  | ELit{lit=(LInt _|LBigInt _|LBool _);_}->literal value
  | EVar n->(match List.assoc_opt n.name env with Some v->v|None->invoke value [])
  | EApp _|EConstructor _|EField _->
    let fn,args=application [] value in
    (match name fn,args with Some "check",fn::args->let fn,initial=application [] fn in invoke fn(List.map run(initial @ args))
     | _->invoke fn(List.map run args))
  | ELet e ->let value=run e.value in expr depth home((e.name,value)::env)e.body
  | EIf e->run(if bool(run e.cond)then e.then_ else e.else_)
  | EOk e->run e.value
  | EFail _->raise Rejected
  | EUnop{op=UNot;arg;_}->Bool(not(bool(run arg)))
  | EUnop{op=UNeg;arg;_}->(match run arg with Int n->integer(negate n)|_->refuse "unsupported compile-time negation")
  | EBinop{op=BAnd;left;right;_}->Bool(bool(run left)&&bool(run right))
  | EBinop{op=BOr;left;right;_}->Bool(bool(run left)||bool(run right))
  | EBinop e->let a=run e.left and b=run e.right in
    (match e.op,a,b with
     | BConcat,String a,String b->charge(String.length a+String.length b);string(a ^ b)
     | (BAdd|BSub|BMul),Int a,Int b->
       charge(if e.op=BMul then String.length a*String.length b else String.length a+String.length b);
       integer(match e.op with BAdd->add a b|BSub->add a(negate b)|_->multiply a b)
     | (BDiv|BMod),Int a,Int b->
       charge(10*String.length a*String.length b);
       let quotient,remainder=divide a b in integer(if e.op=BDiv then quotient else remainder)
     | (BEq|BNeq|BLt|BLe|BGt|BGe),_,_->
       let c=match a,b with Int a,Int b->charge(String.length a+String.length b);int_compare a b
        | String a,String b->charge(String.length a+String.length b);String.compare a b
        | Bool a,Bool b->Bool.compare a b|_->refuse "unsupported compile-time comparison"in
       Bool(match e.op with BEq->c=0|BNeq->c<>0|BLt->c<0|BLe->c<=0|BGt->c>0|_->c>=0)
     | _->refuse "unsupported compile-time operator")
  | ECase e->
    let value=run e.scrut in
    let rec matches pattern value=match pattern,value with
     | PVar n,v->Some[n,v]|PWild,_->Some[]
     | PNullary p,_->(match resolve home p.ctor,value with
       | Some(Primitive "Tesl.Maybe.Nothing"),Nothing->Some[]
       | Some(Primitive "Tesl.Prelude.True"),Bool true|Some(Primitive "Tesl.Prelude.False"),Bool false->Some[]
       | Some(Primitive _),_->None|_->refuse "unsupported compile-time pattern")
     | PCon p,_->(match resolve home p.ctor,p.fields,value with
       | Some(Primitive "Tesl.Maybe.Something"),[_,pattern],Something value->matches pattern value
       | Some(Primitive "Tesl.Maybe.Something"),_,Nothing->None|_->refuse "unsupported compile-time pattern")
     | PLit p,_->if literal(ELit{lit=p.value;loc=p.loc})=value then Some[]else None in
    let rec arms=function []->refuse "non-exhaustive compile-time evaluation"|arm::rest->
     match matches arm.pattern value with None->arms rest|Some bindings->
       let run=expr depth home(bindings @ env)in
       if Option.fold ~none:true ~some:(fun g->bool(run g))arm.guard then run arm.body else arms rest in arms e.arms
  | _->refuse "unsupported expression in literal validation"in
 call 0 owner declaration [input]
