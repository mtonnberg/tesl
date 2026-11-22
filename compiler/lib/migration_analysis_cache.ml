(* Compilation-scoped memo tables for repeated migration-history analysis.

   One compile re-derives the same history several times: the application
   check, every Contract check, the guarded capture and emission each rebuild
   discovery, every migration declaration and the whole row history. A memo here
   only lives inside [with_scope] (opened by Migration_program's compilation
   cache), so nothing outlives one command or one editor request.

   A hit requires an equal key, the identical active proof scope, and a
   caller-supplied guard that rechecks the cached value's own source guards under
   the caller's current source view. Exceptions and caller-rejected results are
   never stored, so failures are always recomputed through the ordinary checker.
   TESL_HISTORY_CACHE=0 disables every table (tests use it as the cold oracle). *)

let enabled () =
  match Sys.getenv_opt "TESL_HISTORY_CACHE" with
  | Some ("0" | "off" | "false" | "no") -> false
  | _ -> true

let depth = ref 0
let resets : (unit -> unit) list ref = ref []

let with_scope f =
  if !depth > 0 then f ()
  else begin
    incr depth;
    Fun.protect ~finally:(fun () -> decr depth; List.iter (fun reset -> reset ()) !resets) f
  end

type stats = { hits : int; misses : int }

type ('k, 'v) t = {
  limit : int;
  mutable entries : ('k * Migration_proof_context.scope_token * 'v) list;
  mutable hits : int;
  mutable misses : int;
}

let create ~limit =
  let memo = { limit; entries = []; hits = 0; misses = 0 } in
  resets := (fun () -> memo.entries <- []) :: !resets;
  memo

let stats memo = { hits = memo.hits; misses = memo.misses }
let reset_stats memo = memo.hits <- 0; memo.misses <- 0

(* [store] decides whether a computed value may be reused (for example only a
   successful result). [guard] runs only for entries whose key and scope match. *)
let find ?(store = fun _ -> true) memo ~key ~guard compute =
  if !depth = 0 || not (enabled ()) then compute ()
  else
    let matches (k, scope, _) = k = key && Migration_proof_context.same_scope scope in
    match List.find_opt (fun ((_, _, value) as entry) -> matches entry && guard value) memo.entries with
    | Some (_, _, value) -> memo.hits <- memo.hits + 1; value
    | None ->
      memo.misses <- memo.misses + 1;
      let scope = Migration_proof_context.current_scope () in
      let value = compute () in
      let others = List.filter (fun entry -> not (matches entry)) memo.entries in
      if store value then
        memo.entries <- (key, scope, value) :: List.filteri (fun index _ -> index < memo.limit - 1) others
      else memo.entries <- others;
      value
