module P = Migration_program
module C = Migration_contract
let to_json source =
 let quote=Migration_row_companion.quote in
 let array f xs="[" ^ String.concat "," (List.map f xs) ^ "]" in
 let program=P.source_program source in
 let database (d:P.database) =
  let contracts=Option.value(List.assoc_opt d.identity (P.contracts program)) ~default:[] in
  let contract c =
   Printf.sprintf {|{"contract":%s,"hash":%s,"settled":%s,"settledHash":%s}|}
    (quote(C.encoded c)) (quote(C.digest c)) (quote(C.settled_encoded c)) (quote(C.settled_hash c)) in
  Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"contracts":%s}|}
   (quote d.identity) (quote d.family) (quote d.namespace) (array contract contracts) in
 Printf.sprintf {|{"version":1,"kind":"compiled-row-contract-history","compilerAbi":%s,"databases":%s}|}
  (quote(P.compiler_abi program)) (array database(P.databases program))
