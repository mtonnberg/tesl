(** Tests for the surface-lowering pass {!Desugar}.

    Wave 2 (reduce_language_size, P3) lowers the three fixed-shape, context-free,
    position-independent effect forms to the core {!Ast.ERuntimeCall} node:

      - [EEnqueue]      → [(enqueue! QUEUE <payload>)]
      - [EStartWorkers] → [(start-workers! NAME (list CAP...)[ #:concurrency N])]
      - [EServe]        → [(serve NAME #:port <port> #:capabilities (list ...)
                            [ #:static-dir "..."] #:sse-routes NAME-sse-routes)]

    Every OTHER {!Ast.expr} variant — including the deliberately-BLOCKED forms
    [ETelemetry] / [EPublish] / [EWithDatabase] / [EWithCapabilities] /
    [EWithTransaction] / cache / email / [EUnop] / [LInterp] — must pass through
    STRUCTURALLY UNCHANGED, every [loc] preserved byte-for-byte, so
    {!Emit_racket} still produces byte-identical Racket for them.

    The lowered nodes MUST reuse the surface node's own [loc] verbatim (spans for
    go-to-definition / diagnostics).  We compare with OCaml's polymorphic [=]
    (which compares [loc] records field-by-field), deliberately NOT physical
    [==]: the pass is free to allocate fresh nodes.

    A hand-built module embeds an expression touching every {!Ast.expr}
    constructor so an under-covering pass — the silent-bug class — fails.

    Pure OCaml, no Racket, no alcotest — runs standalone and under [dune runtest];
    exits non-zero if any case fails. *)

open Ast

let failed = ref 0
let check name cond =
  if cond then Printf.printf "ok   - %s\n" name
  else (incr failed; Printf.printf "FAIL - %s\n" name)

let loc_at n = Location.make_loc "test.tesl" n n n (n + 1)

let var n name = EVar { name; loc = loc_at n }
let int_ n i = ELit { lit = LInt i; loc = loc_at n }

let dummy_binding name n : binding =
  { name; type_expr = TName { name = "Int"; loc = loc_at n };
    proof_ann = None; loc = loc_at n }

let empty_queues : (string, string) Hashtbl.t = Hashtbl.create 1

(* Builders for the three lowered effect forms — used both inside the
   all-constructors bundle and standalone for the lowering assertions. *)
let mk_enqueue () = EEnqueue { job_type = "J"; payload = int_ 35 1; loc = loc_at 36 }
let mk_workers () = EStartWorkers { workers_name = "W"; capabilities = []; concurrency = None; is_dead = false; loc = loc_at 40 }
let mk_serve   () = EServe { server_name = "Sv"; port = int_ 60 8080; capabilities = []; static_dir = None; loc = loc_at 61 }

(* One expression that touches every Ast.expr constructor at least once. *)
let sample_expr : expr =
  let e_lit_interp =
    ELit { lit = LInterp [ ILiteral "hi "; IExpr (var 1 "x"); ILiteral "!" ];
           loc = loc_at 2 } in
  let e_field = EField { obj = var 3 "rec"; field = "f"; loc = loc_at 4 } in
  let e_app = EApp { fn = var 5 "g"; arg = int_ 6 1; loc = loc_at 7 } in
  let e_binop = EBinop { op = BAdd; left = int_ 8 1; right = int_ 9 2; loc = loc_at 10 } in
  let e_unop = EUnop { op = UNeg; arg = int_ 11 3; loc = loc_at 12 } in
  let e_if = EIf { cond = var 13 "c"; then_ = int_ 14 1; else_ = int_ 15 2; loc = loc_at 16 } in
  let e_case =
    ECase { scrut = var 17 "s";
            arms = [ { pattern = PVar "a"; guard = Some (var 18 "g"); body = int_ 19 1; loc = loc_at 20 };
                     { pattern = PWild; guard = None; body = int_ 21 2; loc = loc_at 22 } ];
            loc = loc_at 23 } in
  let e_record = ERecord { fields = [ ("k", int_ 24 1) ]; type_hint = None; loc = loc_at 25 } in
  let e_list = EList { elems = [ int_ 26 1; int_ 27 2 ]; loc = loc_at 28 } in
  let proof = PredApp { pred = "P"; args = []; loc = loc_at 29 } in
  let e_ok = EOk { value = int_ 30 1; proof; loc = loc_at 31 } in
  let e_fail = EFail { status = 400; message = e_lit_interp; loc = loc_at 32 } in
  let e_telemetry = ETelemetry { name = "evt"; fields = [ ("n", int_ 33 1) ]; loc = loc_at 34 } in
  let e_enqueue = mk_enqueue () in
  let e_publish = EPublish { channel_name = "C"; key = Some (var 37 "k"); event_ctor = "E"; payload = Some (int_ 38 1); loc = loc_at 39 } in
  let e_workers = mk_workers () in
  let e_cache_get = ECacheGet { cache_name = "Ca"; key = var 41 "k"; loc = loc_at 42 } in
  let e_cache_set = ECacheSet { cache_name = "Ca"; key = var 43 "k"; value = int_ 44 1; ttl = Some (int_ 45 60); loc = loc_at 46 } in
  let e_cache_del = ECacheDelete { cache_name = "Ca"; key = var 47 "k"; loc = loc_at 48 } in
  let e_cache_inv = ECacheInvalidate { cache_name = "Ca"; prefix = var 49 "p"; loc = loc_at 50 } in
  let e_email = ESendEmail { email_name = "Em"; to_ = var 51 "t"; subject = e_lit_interp; body = e_lit_interp; loc = loc_at 52 } in
  let e_email_worker = EStartEmailWorker { email_name = "Em"; loc = loc_at 53 } in
  let e_with_db = EWithDatabase { database_name = "Db"; body = int_ 54 1; loc = loc_at 55 } in
  let e_with_caps = EWithCapabilities { capabilities = ["c"]; body = int_ 56 1; loc = loc_at 57 } in
  let e_with_tx = EWithTransaction { body = int_ 58 1; loc = loc_at 59 } in
  let e_serve = mk_serve () in
  let e_ctor = EConstructor { name = "Some"; args = [ int_ 62 1 ]; loc = loc_at 63 } in
  let e_lambda = ELambda { params = [ dummy_binding "z" 64 ]; body = int_ 65 1; loc = loc_at 66 } in
  let e_letproof = ELetProof { value_name = "v"; proof_name = "pr"; proof_index = None; value = int_ 67 1; body = var 68 "v"; loc = loc_at 69 } in
  (* Nest everything under an ELet chain so the whole forest is one expr. *)
  let bundle = EList { elems = [
    e_lit_interp; e_field; e_app; e_binop; e_unop; e_if; e_case; e_record;
    e_list; e_ok; e_fail; e_telemetry; e_enqueue; e_publish; e_workers;
    e_cache_get; e_cache_set; e_cache_del; e_cache_inv; e_email; e_email_worker;
    e_with_db; e_with_caps; e_with_tx; e_serve; e_ctor; e_lambda; e_letproof ];
    loc = loc_at 70 } in
  ELet { name = "all"; declared_type = None; declared_proof = None;
         value = bundle; body = var 71 "all"; loc = loc_at 72 }

(* Same forest with the three lowered families REMOVED — must be a strict
   structural identity through the pass (every other variant preserved). *)
let sample_expr_no_lowered : expr =
  match sample_expr with
  | ELet ({ value = EList ({ elems; _ } as l); _ } as outer) ->
    let elems' = List.filter (function
      | EEnqueue _ | EStartWorkers _ | EServe _ -> false | _ -> true) elems in
    ELet { outer with value = EList { l with elems = elems' } }
  | _ -> sample_expr

let sample_func : func_decl = {
  kind = FnKind; name = "f"; params = [ dummy_binding "x" 100 ];
  return_spec = RetPlain { ty = TName { name = "Int"; loc = loc_at 101 }; loc = loc_at 102 };
  capabilities = []; body = sample_expr; loc = loc_at 103;
  desugared_from = None; doc = None;
}

let sample_const : const_form = { name = "K"; value = int_ 110 7; loc = loc_at 111 }

let sample_module : module_form = {
  module_name = "M"; is_library = false; exports = []; imports = [];
  decls = [ DFunc sample_func; DConst sample_const ];
  source_file = "test.tesl";
}

(* Expect a single-RLit ERuntimeCall (no RArg) with the given loc & rendering. *)
let is_rlit_only expected loc = function
  | ERuntimeCall { segments = [ RLit s ]; loc = l } -> s = expected && l = loc
  | _ -> false

let () =
  (* 1. Non-lowered forms are a strict structural identity (loc-preserving). *)
  check "desugar_expr: every non-lowered variant passes through verbatim"
    (Desugar.desugar_expr empty_queues sample_expr_no_lowered = sample_expr_no_lowered);

  (* 2. EEnqueue → (enqueue! QUEUE <RArg payload>), surface loc preserved. *)
  let queues = Hashtbl.create 1 in
  Hashtbl.replace queues "J" "MyQueue";
  (match Desugar.desugar_expr queues (mk_enqueue ()) with
   | ERuntimeCall { segments = [ RLit "(enqueue! MyQueue "; RArg p; RLit ")" ]; loc } ->
     check "EEnqueue lowers to ERuntimeCall (resolved queue, RArg payload, loc)"
       (p = int_ 35 1 && loc = loc_at 36)
   | _ -> check "EEnqueue lowers to ERuntimeCall (resolved queue, RArg payload, loc)" false);

  (* 2b. EEnqueue with an unknown queue uses the _queue_for_ fallback. *)
  (match Desugar.desugar_expr empty_queues (mk_enqueue ()) with
   | ERuntimeCall { segments = [ RLit "(enqueue! _queue_for_J "; RArg _; RLit ")" ]; _ } ->
     check "EEnqueue with no DQueue uses _queue_for_<jobtype> fallback" true
   | _ -> check "EEnqueue with no DQueue uses _queue_for_<jobtype> fallback" false);

  (* 3. EStartWorkers → single-RLit ERuntimeCall, loc preserved. *)
  check "EStartWorkers lowers to single-RLit ERuntimeCall (start-workers!, loc)"
    (is_rlit_only "(start-workers! W (list))" (loc_at 40)
       (Desugar.desugar_expr empty_queues (mk_workers ())));

  (* 3b. dead workers + concurrency render variants. *)
  check "EStartWorkers dead + concurrency renders start-dead-workers! #:concurrency"
    (is_rlit_only "(start-dead-workers! W (list ReadCap) #:concurrency 4)" (loc_at 40)
       (Desugar.desugar_expr empty_queues
          (EStartWorkers { workers_name = "W"; capabilities = ["ReadCap"];
                           concurrency = Some 4; is_dead = true; loc = loc_at 40 })));

  (* 4. EServe → (serve NAME #:port <RArg port> ...sse-routes), loc preserved. *)
  (match Desugar.desugar_expr empty_queues (mk_serve ()) with
   | ERuntimeCall { segments =
       [ RLit "(serve Sv #:port "; RArg port;
         RLit " #:capabilities (list) #:sse-routes Sv-sse-routes)" ]; loc } ->
     check "EServe lowers to ERuntimeCall (RArg port, sse-routes suffix, loc)"
       (port = int_ 60 8080 && loc = loc_at 61)
   | _ -> check "EServe lowers to ERuntimeCall (RArg port, sse-routes suffix, loc)" false);

  (* 4b. EServe with static_dir injects the #:static-dir keyword arg. *)
  (match Desugar.desugar_expr empty_queues
           (EServe { server_name = "Sv"; port = int_ 60 8080; capabilities = ["Cap"];
                     static_dir = Some "public"; loc = loc_at 61 }) with
   | ERuntimeCall { segments =
       [ RLit "(serve Sv #:port "; RArg _;
         RLit " #:capabilities (list Cap) #:static-dir \"public\" #:sse-routes Sv-sse-routes)" ]; _ } ->
     check "EServe with static_dir injects #:static-dir" true
   | _ -> check "EServe with static_dir injects #:static-dir" false);

  (* 5. Module-level lowering threads the DQueue table and lowers in place. *)
  let out = Desugar.desugar_module sample_module in
  let lowered_count = ref 0 in
  (match out.decls with
   | DFunc fd :: _ ->
     let rec count = function
       | ERuntimeCall _ -> incr lowered_count
       | e -> ignore (Ast_visitor.fold_children (fun () e -> count e; ()) () e)
     in count fd.body
   | _ -> ());
  check "desugar_module lowers exactly the 3 fixed-shape forms in the body"
    (!lowered_count = 3);

  (* 6. Provenance helper records the surface loc verbatim. *)
  let surface = loc_at 200 in
  check "provenance_from records the surface loc"
    ((Desugar.provenance_from surface).desugared_from = surface);

  (* 7. Declarations with no expr children pass through untouched. *)
  let ty_decl = DType (TypeNewtype { name = "T"; base_type = TName { name = "String"; loc = loc_at 300 }; loc = loc_at 301 }) in
  check "non-expr declaration passes through verbatim"
    (Desugar.desugar_decl empty_queues ty_decl = ty_decl);

  if !failed = 0 then (Printf.printf "\nALL DESUGAR TESTS PASSED\n"; exit 0)
  else (Printf.printf "\n%d DESUGAR TEST(S) FAILED\n" !failed; exit 1)
