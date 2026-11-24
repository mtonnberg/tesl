module P = Migration_program
module C = Migration_contract
let to_json source =
 let quote=Migration_row_companion.quote in
 let array f xs="[" ^ String.concat "," (List.map f xs) ^ "]" in
 let program=P.source_program source in
 P.unresumed program;
 let database (d:P.database) =
  let nodes=Migration_canonical_nodes.create ~quote in
  let contracts=Emit_fragment.render_entries ~document:"contracts" ~database:d.identity ~revision:(fun (c:Migration_records.contract) -> c.contract_version) nodes
    (Migration_records.contract_json ~quote ~contract:(Migration_canonical_nodes.reference nodes)) (P.records source d.identity).contracts in
  Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"contracts":%s,"canonicalNodes":%s}|}
   (quote d.identity) (quote d.family) (quote d.namespace) contracts (Migration_canonical_nodes.to_json nodes) in
 Printf.sprintf {|{"version":1,"kind":"compiled-row-contract-history","contractEncoding":"tesl-canonical-nodes-v1","compilerAbi":%s,"databases":%s}|}
  (quote(P.compiler_abi program)) (array database(P.databases program))
