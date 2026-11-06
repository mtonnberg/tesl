(* Component benchmark: repeated loads model the repeated history inspections in
   one emission. This is not an end-to-end compilation or database benchmark. *)
let () =
  if Array.length Sys.argv <> 3 then failwith "usage: bench_migration_inventory SCHEMA_FILE ITERATIONS";
  let root_file = Unix.realpath Sys.argv.(1) in
  let iterations = int_of_string Sys.argv.(2) in
  if iterations < 1 then invalid_arg "iterations must be positive";
  let abi = match Migration_abi.current () with
    | Ok abi -> abi | Error error -> failwith error.message in
  let load () = match Migration_inventory.load_with_compatibility
      ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility abi))
      ~compiler_abi:(Migration_abi.id abi) ~root_file with
    | Ok inventory -> inventory | Error error -> failwith error.message in
  let hash inventory = Migration_canonical.digest Migration_canonical.Snapshot
      (Migration_inventory.snapshot inventory) in
  let expected = hash (load ()) in
  List.iter (fun cached ->
    let work () =
      let last = ref None in
      for _ = 1 to iterations do last := Some (load ()) done;
      Option.get !last in
    let started = Unix.gettimeofday () in
    let result = if cached then Migration_inventory.with_cache work else work () in
    let seconds = Unix.gettimeofday () -. started in
    if hash result <> expected then failwith "cached inventory differs";
    Printf.printf "{\"cached\":%b,\"iterations\":%d,\"seconds\":%.6f,\"inventoryEqual\":true}\n%!"
      cached iterations seconds) [false;true;true;false]
