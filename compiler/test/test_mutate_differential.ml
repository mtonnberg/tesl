(** One-off differential check: the migrated {!Mutate.collect_sites} /
    {!Mutate.replace_at} (now built on {!Ast_visitor}) must produce
    byte-identical BINOP site indices and replacements to a reference
    re-implementation of the ORIGINAL hand-rolled pre-order walks.  Guards the
    load-bearing invariant that delegating recursion to the shared visitor did
    not perturb the deterministic mutation-site indexing.  [collect_sites] now
    also returns boolean- and integer-literal sites (each in its OWN per-kind
    index space), so we project onto the [KBinop] sites before comparing —
    per-kind counters guarantee the binop indices are unchanged.  Pure OCaml;
    no Racket. *)

open Ast

(* Reference: the original hand-rolled collect (pre-order, left-to-right),
   returning (index, op) for each mutable binop. *)
let ref_collect body =
  let counter = ref 0 in
  let acc = ref [] in
  let rec walk = function
    | EBinop { op; left; right; _ } ->
      let idx = !counter in incr counter;
      (match Mutate.mutation_alternatives op with
       | [] -> () | _ -> acc := (idx, op) :: !acc);
      walk left; walk right
    | EApp { fn; arg; _ } -> walk fn; walk arg
    | EUnop { arg; _ } -> walk arg
    | EIf { cond; then_; else_; _ } -> walk cond; walk then_; walk else_
    | ECase { scrut; arms; _ } ->
      walk scrut;
      List.iter (fun (a : case_arm) -> Option.iter walk a.guard; walk a.body) arms
    | ELet { value; body; _ } -> walk value; walk body
    | ELetProof { value; body; _ } -> walk value; walk body
    | ERecord { fields; _ } -> List.iter (fun (_, e) -> walk e) fields
    | EList { elems; _ } -> List.iter walk elems
    | EOk { value; _ } -> walk value
    | EFail { message; _ } -> walk message
    | ETelemetry { fields; _ } -> List.iter (fun (_, e) -> walk e) fields
    | EEnqueue { payload; _ } -> walk payload
    | EPublish { key; payload; _ } -> Option.iter walk key; Option.iter walk payload
    | EWithDatabase { body; _ } | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> walk body
    | EField { obj; _ } -> walk obj
    | EConstructor { args; _ } -> List.iter walk args
    | ELambda { body; _ } -> walk body
    | EServe { port; _ } -> walk port
    | ELit { lit = LInterp segs; _ } ->
      List.iter (function IExpr e -> walk e | ILiteral _ -> ()) segs
    | ERuntimeCall { segments; _ } ->
      List.iter (function RLit _ | RRawVar _ -> () | RArg e -> walk e) segments
    | ELit _ | EVar _ | EStartWorkers _
    | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _
    | ESendEmail _ | EStartEmailWorker _ -> ()
  in
  walk body; List.rev !acc

let failed = ref 0
let check name c = if c then Printf.printf "ok   - %s\n" name
  else (incr failed; Printf.printf "FAIL - %s\n" name)

let () =
  let dir = "../example/learn" in
  let files =
    (try Sys.readdir dir with _ -> [||]) |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".tesl")
    |> List.map (fun f -> Filename.concat dir f)
    |> List.sort compare in
  let total_sites = ref 0 in
  List.iter (fun path ->
    match (try Compile.parse_module_file path with _ -> None) with
    | None -> ()
    | Some m ->
      List.iter (function
        | DFunc fd ->
          (* Project onto the binop sites: keep only sites whose original value
             is a [MOBinop], recovering the [binop] for comparison. *)
          let binop_sites =
            Mutate.collect_sites fd.name fd.kind fd.body
            |> List.filter_map (fun ((s : Mutate.mutation_site), _alts) ->
                 match s.original with
                 | Mutate.MOBinop op -> Some (s, op)
                 | _ -> None)
          in
          let new_pairs =
            List.map (fun ((s : Mutate.mutation_site), op) -> (s.site_index, op))
              binop_sites in
          let ref_pairs = ref_collect fd.body in
          if new_pairs <> ref_pairs then begin
            incr failed;
            Printf.printf "FAIL - sites differ in %s:%s\n" path fd.name
          end;
          total_sites := !total_sites + List.length binop_sites;
          (* replacement lands on the right node: replace a site's op then
             re-collect and confirm exactly that index now carries new_op. *)
          List.iter (fun ((s : Mutate.mutation_site), op) ->
            match Mutate.mutation_alternatives op with
            | new_op :: _ ->
              let body' =
                Mutate.replace_at ~kind:Mutate.KBinop ~target_index:s.site_index
                  ~op:(Mutate.MOBinop new_op) fd.body in
              let after = Mutate.collect_sites fd.name fd.kind body' in
              (match List.find_opt (fun ((s2 : Mutate.mutation_site), _alts) ->
                       s2.kind = Mutate.KBinop && s2.site_index = s.site_index)
                       after with
               | Some ({ Mutate.original = Mutate.MOBinop op2; _ }, _) when op2 <> new_op ->
                 incr failed;
                 Printf.printf "FAIL - replace wrong op at %s:%s idx %d\n"
                   path fd.name s.site_index
               | _ -> ())
            | [] -> ()
          ) binop_sites
        | _ -> ()
      ) m.decls
  ) files;
  check (Printf.sprintf "collected %d sites across corpus (>0)" !total_sites)
    (!total_sites > 0);
  if !failed = 0 then (Printf.printf "\nMutate differential PASSED.\n"; exit 0)
  else (Printf.printf "\n%d differential failure(s).\n" !failed; exit 1)
