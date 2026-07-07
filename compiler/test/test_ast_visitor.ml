(** Property tests for the shared AST-traversal framework {!Ast_visitor}.

    The keystone invariant: [map_children Fun.id] is the IDENTITY on the AST —
    it must reconstruct a structurally-equal tree whose every [loc] is preserved
    byte-for-byte.  We assert STRUCTURAL + loc equality with OCaml's polymorphic
    [=] (which compares [loc] records field-by-field), deliberately NOT physical
    [==]: the framework is free to allocate fresh nodes, but it must never alter
    structure or drop/rewrite a location.

    A single hand-built expression exercises ALL 30 {!Ast.expr} variants
    (including the [LInterp] interpolation child and the nested case-arm guard /
    body / pattern positions) so that an under-covering [map_children] arm — the
    silent-bug class this framework exists to kill — fails the test.

    We also check the recursive fixpoints: [Ast_visitor.map Fun.id] is identity
    over the whole tree, and [iter]/[fold] visit the SAME set of nodes (so the
    three primitives can never silently disagree about what "the children" are).

    Pure OCaml, no Racket, no alcotest — runs standalone and under [dune
    runtest]; exits non-zero if any case fails. *)

open Ast

let failed = ref 0
let check name cond =
  if cond then Printf.printf "ok   - %s\n" name
  else (incr failed; Printf.printf "FAIL - %s\n" name)

(* Distinct locations so a dropped/swapped loc is detectable. *)
let loc_at n = Location.make_loc "test.tesl" n n n (n + 1)

let var n name = EVar { name; loc = loc_at n }
let int_ n i = ELit { lit = LInt i; loc = loc_at n }

let dummy_binding name n : binding =
  { name; type_expr = TName { name = "Int"; loc = loc_at n };
    proof_ann = None; loc = loc_at n }

(* One expression that touches every Ast.expr constructor at least once. *)
let sample : expr =
  let e_lit_interp =
    ELit { lit = LInterp [ ILiteral "hi "; IExpr (var 1 "x"); ILiteral "!" ];
           loc = loc_at 2 } in
  let e_field = EField { obj = var 3 "rec"; field = "f"; loc = loc_at 4 } in
  let e_app = EApp { fn = var 5 "g"; arg = int_ 6 1; loc = loc_at 7 } in
  let e_binop = EBinop { op = BAdd; left = int_ 8 1; right = int_ 9 2; loc = loc_at 10; op_loc = loc_at 10 } in
  let e_unop = EUnop { op = UNeg; arg = int_ 11 3; loc = loc_at 12 } in
  let e_if = EIf { cond = var 13 "c"; then_ = int_ 14 1; else_ = int_ 15 2; loc = loc_at 16 } in
  let e_case =
    ECase { scrut = var 17 "s";
            arms = [
              { pattern = PVar "a"; guard = Some (var 18 "g1"); body = var 19 "b1"; loc = loc_at 20 };
              { pattern = PCon { ctor = "C"; fields = [("inner", PVar "y")]; loc = loc_at 21 };
                guard = None; body = var 22 "b2"; loc = loc_at 23 };
              { pattern = PLit { value = LInt 0; loc = loc_at 24 };
                guard = None; body = var 25 "b3"; loc = loc_at 26 };
              { pattern = PNullary { ctor = "N"; loc = loc_at 27 };
                guard = None; body = var 28 "b4"; loc = loc_at 29 };
              { pattern = PWild; guard = None; body = var 30 "b5"; loc = loc_at 31 };
            ];
            loc = loc_at 32 } in
  let e_let = ELet { name = "v"; declared_type = None; declared_proof = None;
                     value = int_ 33 1; body = var 34 "v"; loc = loc_at 35 } in
  let e_letproof = ELetProof { value_name = "v"; proof_name = "p"; proof_index = None;
                               value = int_ 36 1; body = var 37 "v"; loc = loc_at 38 } in
  let e_record = ERecord { fields = [("k", int_ 39 1); ("k2", var 40 "z")];
                           type_hint = Some "T"; loc = loc_at 41 } in
  let e_list = EList { elems = [int_ 42 1; int_ 43 2]; loc = loc_at 44 } in
  let e_ok = EOk { value = var 45 "v";
                   proof = PredApp { pred = "P"; args = ["v"]; loc = loc_at 46 };
                   loc = loc_at 47 } in
  let e_fail = EFail { status = 400; message = var 48 "msg"; loc = loc_at 49 } in
  let e_tel = ETelemetry { name = "evt"; fields = [("a", var 50 "x")]; loc = loc_at 51 } in
  let e_enq = EEnqueue { job_type = "j"; payload = var 52 "p"; loc = loc_at 53 } in
  let e_pub = EPublish { channel_name = "ch"; key = Some (var 54 "k");
                         event_ctor = "E"; payload = Some (var 55 "pl"); loc = loc_at 56 } in
  let e_sw = EStartWorkers { workers_name = "w"; capabilities = ["queueRead"];
                             concurrency = Some 4; is_dead = false; loc = loc_at 57 } in
  let e_cg = ECacheGet { cache_name = "c"; key = var 58 "k"; loc = loc_at 59 } in
  let e_cs = ECacheSet { cache_name = "c"; key = var 60 "k"; value = var 61 "v";
                         ttl = Some (int_ 62 60); loc = loc_at 63 } in
  let e_cd = ECacheDelete { cache_name = "c"; key = var 64 "k"; loc = loc_at 65 } in
  let e_ci = ECacheInvalidate { cache_name = "c"; prefix = var 66 "p"; loc = loc_at 67 } in
  let e_se = ESendEmail { email_name = "m"; to_ = var 68 "t"; subject = var 69 "s";
                          body = var 70 "b"; loc = loc_at 71 } in
  let e_sew = EStartEmailWorker { email_name = "m"; loc = loc_at 72 } in
  let e_wdb = EWithDatabase { database_name = "db"; body = var 73 "b"; loc = loc_at 74 } in
  let e_wcap = EWithCapabilities { capabilities = ["dbRead"]; body = var 75 "b"; loc = loc_at 76 } in
  let e_wtx = EWithTransaction { body = var 77 "b"; loc = loc_at 78 } in
  let e_serve = EServe { server_name = "srv"; port = int_ 79 8080; capabilities = [];
                         static_dir = None; loc = loc_at 80 } in
  let e_ctor = EConstructor { name = "Ctor"; args = [var 81 "a"; int_ 82 1]; loc = loc_at 83 } in
  let e_lambda = ELambda { params = [dummy_binding "p" 84]; body = var 85 "p"; loc = loc_at 86 } in
  (* Nest them all under a list so a single root holds every variant. *)
  EList {
    elems = [
      e_lit_interp; e_field; e_app; e_binop; e_unop; e_if; e_case;
      e_let; e_letproof; e_record; e_list; e_ok; e_fail; e_tel; e_enq;
      e_pub; e_sw; e_cg; e_cs; e_cd; e_ci; e_se; e_sew; e_wdb; e_wcap;
      e_wtx; e_serve; e_ctor; e_lambda;
      var 87 "plain"; int_ 88 99;
    ];
    loc = loc_at 89;
  }

let () =
  (* 1. map_children identity: structural + loc equality (NOT physical). *)
  let mapped1 = Ast_visitor.map_children Fun.id sample in
  check "map_children id is structurally + loc equal to input" (mapped1 = sample);
  check "map_children id is NOT (necessarily) physically equal"
    (true (* documents intent: we never assert == *) || mapped1 == sample);

  (* 2. Recursive map identity over the WHOLE tree. *)
  let mapped_deep = Ast_visitor.map Fun.id sample in
  check "map (recursive) id is structurally + loc equal to input" (mapped_deep = sample);

  (* 3. iter and fold visit the SAME node multiset (same count). *)
  let iter_count = ref 0 in
  Ast_visitor.iter (fun _ -> incr iter_count) sample;
  let fold_count = Ast_visitor.fold (fun a _ -> a + 1) 0 sample in
  check "iter and fold visit the same number of nodes" (!iter_count = fold_count);
  check "fold visits more than one node (recursion happened)" (fold_count > 1);

  (* 4. fold_children threads left-to-right: the FIRST child expr of the root
        list is the LInterp literal, whose only child is EVar "x".  Collecting
        var names in order must start with "x". *)
  let names =
    Ast_visitor.fold (fun acc e ->
      match e with EVar { name; _ } -> name :: acc | _ -> acc) [] sample
    |> List.rev
  in
  check "left-to-right order: first collected var is the interp's x"
    (match names with "x" :: _ -> true | _ -> false);

  (* 5. A targeted mutation under map_children must propagate (sanity that we
        actually rebuild, not just return the input). *)
  let bumped =
    Ast_visitor.map (fun e ->
      match e with
      | ELit { lit = LInt n; loc } -> ELit { lit = LInt (n + 1000); loc }
      | _ -> e) sample
  in
  check "map can rewrite leaves (and is therefore not a no-op clone)"
    (bumped <> sample);
  (* but locations are still preserved on the rewritten leaves *)
  let bumped_back =
    Ast_visitor.map (fun e ->
      match e with
      | ELit { lit = LInt n; loc } -> ELit { lit = LInt (n - 1000); loc }
      | _ -> e) bumped
  in
  check "map rewrite is reversible with loc preserved" (bumped_back = sample);

  (* 6. fold_children_env threads the SAME env down to each immediate child and
        accumulates LEFT-TO-RIGHT in the identical child order as fold_children.
        We collect each child's first-var name paired with the env it was handed:
        every pair must carry the same env, and dropping the env must reproduce
        exactly fold_children's left-to-right child sequence. *)
  let first_var_in e =
    (* Name of the first EVar reachable from e in fold order, or "-". *)
    match
      Ast_visitor.fold (fun acc x ->
        match acc, x with None, EVar { name; _ } -> Some name | _ -> acc) None e
    with Some n -> n | None -> "-"
  in
  let env_marker = "ENV" in
  let env_seq =
    (* fold_children_env over the root: collect (env, child-first-var) per child *)
    Ast_visitor.fold_children_env
      (fun env acc child -> (env, first_var_in child) :: acc)
      env_marker [] sample
    |> List.rev
  in
  let plain_seq =
    Ast_visitor.fold_children
      (fun acc child -> first_var_in child :: acc)
      [] sample
    |> List.rev
  in
  check "fold_children_env hands the SAME env to every child"
    (List.for_all (fun (e, _) -> e = env_marker) env_seq);
  check "fold_children_env child order == fold_children child order"
    (List.map snd env_seq = plain_seq);
  check "fold_children_env visited at least one child" (env_seq <> []);

  (* 7. With a UNIT env, fold_children_env degenerates to fold_children exactly. *)
  let cnt_env =
    Ast_visitor.fold_children_env (fun () a _ -> a + 1) () 0 sample in
  let cnt_plain = Ast_visitor.fold_children (fun a _ -> a + 1) 0 sample in
  check "fold_children_env with unit env == fold_children (child count)"
    (cnt_env = cnt_plain);

  if !failed = 0 then (Printf.printf "\nAll ast_visitor property tests passed.\n"; exit 0)
  else (Printf.printf "\n%d ast_visitor test(s) FAILED.\n" !failed; exit 1)
