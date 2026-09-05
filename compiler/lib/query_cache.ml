(** Opt-in, process-local caches for read-only workspace queries. One-shot
    compilation never enables these. The session invalidates every semantic
    cache before accepting a different complete input snapshot. *)
let enabled = ref false
let resetters : (unit -> unit) list ref = ref []
let clear () = List.iter (fun reset -> reset ()) !resetters
let set_enabled value = clear (); enabled := value

let hits = ref 0
let misses = ref 0

let memo ?(value_weight = fun _ -> 0) ~limit ~max_weight ~weight f =
  let entries = Hashtbl.create limit in
  let total = ref 0 in
  let reset () = Hashtbl.clear entries; total := 0 in
  resetters := reset :: !resetters;
  fun key ->
    if not !enabled then f key
    else match Hashtbl.find_opt entries key with
    | Some value -> incr hits; value
    | None ->
      incr misses;
      let value = f key in
      let size = weight key + value_weight value in
      if size <= max_weight then begin
        if Hashtbl.length entries >= limit || !total + size > max_weight then reset ();
        Hashtbl.replace entries key value;
        total := !total + size
      end;
      value
