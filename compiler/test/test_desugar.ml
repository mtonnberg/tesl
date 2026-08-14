(** Tests for the surface-lowering pass {!Desugar}.

    The pass lowers the TEN fixed-shape, context-free, position-independent
    effect forms to the core {!Ast.ERuntimeCall} node:

      - [EEnqueue]         → [(enqueue! QUEUE <payload>)]
      - [EStartWorkers]    → [(start-workers! NAME (list CAP...)[ #:concurrency N])]
      - [EServe]           → [(serve NAME #:port <port> #:capabilities (list ...)
                               [ #:static-dir "..."] #:sse-routes NAME-sse-routes)]
      - [ECacheGet]        → [(cache-get! CACHE_REF <key>)]
      - [ECacheSet]        → [(cache-set! CACHE_REF <key> <value>[ <ttl>])]
      - [ECacheDelete]     → [(cache-delete! CACHE_REF <key>)]
      - [ECacheInvalidate] → [(cache-invalidate-prefix! CACHE_REF <prefix>)]
      - [ESendEmail]       → [(send-email! EMAIL_REF #:to <to> #:subject <s> #:body <b>)]
      - [EStartEmailWorker]→ [(start-email-worker! EMAIL_REF)]

    The queue / cache / email NAME operands are table-driven (the #41 hit/miss
    rule, {!Desugar.lower_tables}): a name declared in the SAME module emits
    the bare binding (byte-identical to the historical output); a miss emits
    the per-call registry lookup [(queue-for-job-ref J)] / [(cache-for-name 'C)]
    / [(email-for-name 'E)].
      - [ETelemetry]       → [(telemetry-event! "NAME" #:attributes ([%S v]...))]
                             (a bare-EVar value becomes the raw [*name] via the
                              {!Ast.RRawVar} segment — a context-FREE rule)

    Every OTHER {!Ast.expr} variant — including the deliberately-BLOCKED forms
    [EPublish] / [EWithDatabase] / [EWithCapabilities] /
    [EWithTransaction] / [EUnop] / [LInterp] — must pass through STRUCTURALLY
    UNCHANGED, every [loc] preserved byte-for-byte, so {!Emit_racket} still
    produces byte-identical Racket for them.

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

(* Empty resolution tables: every table-driven name takes the MISS (registry
   lookup) path.  A fresh record per call — the tables are mutable. *)
let empty_tables () : Emit_racket.lower_tables = Emit_racket.empty_tables ()

(* Builders for the three lowered effect forms — used both inside the
   all-constructors bundle and standalone for the lowering assertions. *)
let mk_enqueue () = EEnqueue { job_type = "J"; payload = int_ 35 1; loc = loc_at 36 }
let mk_workers () = EStartWorkers { workers_name = "W"; capabilities = []; concurrency = None; is_dead = false; loc = loc_at 40 }
let mk_serve   () = EServe { server_name = "Sv"; port = int_ 60 8080; capabilities = []; static_dir = None; mount_path = None; loc = loc_at 61 }

(* One expression that touches every Ast.expr constructor at least once. *)
let sample_expr : expr =
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
            arms = [ { pattern = PVar "a"; guard = Some (var 18 "g"); body = int_ 19 1; loc = loc_at 20 };
                     { pattern = PWild; guard = None; body = int_ 21 2; loc = loc_at 22 } ];
            loc = loc_at 23 } in
  let e_record = ERecord { fields = [ ("k", int_ 24 1) ]; type_hint = None; loc = loc_at 25 } in
  let e_list = EList { elems = [ int_ 26 1; int_ 27 2 ]; loc = loc_at 28 } in
  let proof = PredApp { pred = "P"; args = []; loc = loc_at 29 } in
  let e_ok = EOk { value = int_ 30 1; proof; keyword = true; loc = loc_at 31 } in
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

(* Same forest with ALL ten lowered families REMOVED — must be a strict
   structural identity through the pass (every other variant preserved). *)
let sample_expr_no_lowered : expr =
  match sample_expr with
  | ELet ({ value = EList ({ elems; _ } as l); _ } as outer) ->
    let elems' = List.filter (function
      | EEnqueue _ | EStartWorkers _ | EServe _
      | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _
      | ESendEmail _ | EStartEmailWorker _ | ETelemetry _ -> false
      | _ -> true) elems in
    ELet { outer with value = EList { l with elems = elems' } }
  | _ -> sample_expr

let sample_func : func_decl = {
  kind = FnKind; name = "f"; params = [ dummy_binding "x" 100 ];
  return_spec = RetPlain { ty = TName { name = "Int"; loc = loc_at 101 }; loc = loc_at 102 };
  capabilities = []; body = sample_expr; loc = loc_at 103;
  desugared_from = None; doc = None; http_methods = [];
}

let sample_const : const_form = { name = "K"; value = int_ 110 7; loc = loc_at 111 }

let sample_module : module_form = {
  module_name = "M"; exports = []; imports = [];
  decls = [ DFunc sample_func; DConst sample_const ];
  source_file = "test.tesl";
}

(* Expect a single-Emit_racket.RLit lowering (no RArg) with the given rendering.
   The lowering moved from the shared desugar pass into the Racket backend, because what it
   produces is Racket source text; these tests moved with it.  A `loc` argument is no longer
   part of the result — the emitter takes the position from the SURFACE node it is emitting,
   which is strictly better than carrying one through a lowered node. *)
let is_rlit_only expected = function
  | Some [ Emit_racket.RLit s ] -> s = expected
  | _ -> false

let () =
  (* 1. Non-lowered forms are a strict structural identity (loc-preserving). *)
  check "desugar_expr: every non-lowered variant passes through verbatim"
    (Desugar.desugar_expr (Desugar.empty_tables ()) sample_expr_no_lowered = sample_expr_no_lowered);
  check "the Racket lowering ignores non-effect forms"
    (Emit_racket.lower_effect (empty_tables ()) sample_expr_no_lowered = None);

  (* 2. EEnqueue → (enqueue! QUEUE <Emit_racket.RArg payload>), position now taken from the surface node. *)
  let tables = empty_tables () in
  Hashtbl.replace tables.Emit_racket.queues "J" "MyQueue";
  (match Emit_racket.lower_effect tables (mk_enqueue ()) with
   | Some [ Emit_racket.RLit "(enqueue! MyQueue "; Emit_racket.RArg p; Emit_racket.RLit ")" ] ->
     check "EEnqueue lowers to the Racket call (resolved queue, RArg payload)"
       (p = int_ 35 1)
   | _ -> check "EEnqueue lowers to the Racket call (resolved queue, RArg payload)" false);

  (* 2b. EEnqueue with no same-module queue falls back to the lazy runtime
     registry lookup (cross-module enqueue, issue #41).  The lookup is the
     NOMINAL macro form (queue-for-job-ref J) — the job-type IDENTIFIER, not a
     quoted symbol — so the runtime matches by (owner, name) type-ref and a
     same-name record from another module fails closed (DESIGN-4 Topic B). *)
  (match Emit_racket.lower_effect (empty_tables ()) (mk_enqueue ()) with
   | Some [ Emit_racket.RLit "(enqueue! (queue-for-job-ref J) "; Emit_racket.RArg _; Emit_racket.RLit ")" ] ->
     check "EEnqueue with no DQueue uses (queue-for-job-ref JobType) fallback" true
   | _ -> check "EEnqueue with no DQueue uses (queue-for-job-ref JobType) fallback" false);

  (* 3. EStartWorkers → single-Emit_racket.RLit ERuntimeCall, loc preserved. *)
  check "EStartWorkers lowers to single-Emit_racket.RLit the Racket call (start-workers!)"
    (is_rlit_only "(start-workers! W (list))"
       (Emit_racket.lower_effect (empty_tables ()) (mk_workers ())));

  (* 3b. dead workers + concurrency render variants. `numberOfWorkers` applies
     ONLY to the normal starter; dead workers are single-threaded and
     start-dead-workers! takes no #:concurrency (issue #15 — passing it crashed
     App boot). *)
  check "EStartWorkers dead + concurrency drops #:concurrency (single-threaded)"
    (is_rlit_only "(start-dead-workers! W (list ReadCap))"
       (Emit_racket.lower_effect (empty_tables ())
          (EStartWorkers { workers_name = "W"; capabilities = ["ReadCap"];
                           concurrency = Some 4; is_dead = true; loc = loc_at 40 })));
  check "EStartWorkers normal + concurrency keeps #:concurrency"
    (is_rlit_only "(start-workers! W (list ReadCap) #:concurrency 4)"
       (Emit_racket.lower_effect (empty_tables ())
          (EStartWorkers { workers_name = "W"; capabilities = ["ReadCap"];
                           concurrency = Some 4; is_dead = false; loc = loc_at 40 })));

  (* 4. EServe → (serve NAME #:port <Emit_racket.RArg port> ...sse-routes), loc preserved. *)
  (match Emit_racket.lower_effect (empty_tables ()) (mk_serve ()) with
   | Some [ Emit_racket.RLit "(serve Sv #:port "; Emit_racket.RArg port;
         Emit_racket.RLit " #:capabilities (list) #:sse-routes Sv-sse-routes)" ] ->
     check "EServe lowers to the Racket call (RArg port, sse-routes suffix)"
       (port = int_ 60 8080)
   | _ -> check "EServe lowers to the Racket call (RArg port, sse-routes suffix)" false);

  (* 4b. EServe with static_dir injects the #:static-dir keyword arg. *)
  (match Emit_racket.lower_effect (empty_tables ())
           (EServe { server_name = "Sv"; port = int_ 60 8080; capabilities = ["Cap"];
                     static_dir = Some "public"; mount_path = None; loc = loc_at 61 }) with
   | Some [ Emit_racket.RLit "(serve Sv #:port "; Emit_racket.RArg _;
         Emit_racket.RLit " #:capabilities (list Cap) #:static-dir \"public\" #:sse-routes Sv-sse-routes)" ] ->
     check "EServe with static_dir injects #:static-dir" true
   | _ -> check "EServe with static_dir injects #:static-dir" false);

  (* 4b'. EServe with mount_path injects the #:mount-path keyword arg, after
     #:static-dir and before #:sse-routes — issue #75. *)
  (match Emit_racket.lower_effect (empty_tables ())
           (EServe { server_name = "Sv"; port = int_ 60 8080; capabilities = ["Cap"];
                     static_dir = Some "public"; mount_path = Some "/api"; loc = loc_at 61 }) with
   | Some [ Emit_racket.RLit "(serve Sv #:port "; Emit_racket.RArg _;
         Emit_racket.RLit " #:capabilities (list Cap) #:static-dir \"public\" #:mount-path \"/api\" #:sse-routes Sv-sse-routes)" ] ->
     check "EServe with mount_path injects #:mount-path" true
   | _ -> check "EServe with mount_path injects #:mount-path" false);

  (* 4c. ETelemetry → (telemetry-event! "NAME" #:attributes ([%S v]...)).  A bare
     EVar field value becomes the raw [*name] (Emit_racket.RRawVar — the literal surface name,
     NOT resolve_name), every other value goes through emit_expr_simple (RArg). *)
  (match Emit_racket.lower_effect (empty_tables ())
           (ETelemetry { name = "evt";
                         fields = [ ("user.id", var 80 "userId"); ("count", int_ 81 1) ];
                         loc = loc_at 82 }) with
   | Some [ Emit_racket.RLit "(telemetry-event! \"evt\" #:attributes (";
         Emit_racket.RLit "[\"user.id\" "; Emit_racket.RRawVar "userId"; Emit_racket.RLit "]";
         Emit_racket.RLit " "; Emit_racket.RLit "[\"count\" "; Emit_racket.RArg c; Emit_racket.RLit "]";
         Emit_racket.RLit "))" ] ->
     check "ETelemetry lowers to the Racket call (RRawVar bare-var, RArg otherwise)"
       (c = int_ 81 1)
   | _ -> check "ETelemetry lowers to the Racket call (RRawVar bare-var, RArg otherwise)" false);

  (* 4d. Cache family — table HIT keeps the bare local binding (byte-identical
     to the historical output, gated by the committed lesson59-cache golden);
     table MISS (cache declared in another module — the issue-#41 name-wired
     class) splices the per-call registry lookup (cache-for-name 'NAME). *)
  let cache_tables = empty_tables () in
  Hashtbl.replace cache_tables.Emit_racket.caches "Ca" ();
  (match Emit_racket.lower_effect cache_tables
           (ECacheGet { cache_name = "Ca"; key = var 41 "k"; loc = loc_at 42 }) with
   | Some [ Emit_racket.RLit "(cache-get! Ca "; Emit_racket.RArg k; Emit_racket.RLit ")" ] ->
     check "ECacheGet HIT keeps the bare local cache binding"
       (k = var 41 "k")
   | _ -> check "ECacheGet HIT keeps the bare local cache binding" false);
  (match Emit_racket.lower_effect (empty_tables ())
           (ECacheGet { cache_name = "Ca"; key = var 41 "k"; loc = loc_at 42 }) with
   | Some [ Emit_racket.RLit "(cache-get! (cache-for-name 'Ca) "; Emit_racket.RArg _; Emit_racket.RLit ")" ] ->
     check "ECacheGet MISS lowers to (cache-for-name 'NAME)" true
   | _ -> check "ECacheGet MISS lowers to (cache-for-name 'NAME)" false);
  (match Emit_racket.lower_effect cache_tables
           (ECacheSet { cache_name = "Ca"; key = var 43 "k"; value = int_ 44 1;
                        ttl = Some (int_ 45 60); loc = loc_at 46 }) with
   | Some [ Emit_racket.RLit "(cache-set! Ca "; Emit_racket.RArg _; Emit_racket.RLit " "; Emit_racket.RArg _; Emit_racket.RLit " "; Emit_racket.RArg _; Emit_racket.RLit ")" ] ->
     check "ECacheSet HIT keeps the bare local cache binding (with ttl)" true
   | _ -> check "ECacheSet HIT keeps the bare local cache binding (with ttl)" false);
  (match Emit_racket.lower_effect (empty_tables ())
           (ECacheSet { cache_name = "Ca"; key = var 43 "k"; value = int_ 44 1;
                        ttl = None; loc = loc_at 46 }) with
   | Some [ Emit_racket.RLit "(cache-set! (cache-for-name 'Ca) "; Emit_racket.RArg _; Emit_racket.RLit " "; Emit_racket.RArg _; Emit_racket.RLit ")" ] ->
     check "ECacheSet MISS lowers to (cache-for-name 'NAME)" true
   | _ -> check "ECacheSet MISS lowers to (cache-for-name 'NAME)" false);
  (match Emit_racket.lower_effect (empty_tables ())
           (ECacheDelete { cache_name = "Ca"; key = var 47 "k"; loc = loc_at 48 }) with
   | Some [ Emit_racket.RLit "(cache-delete! (cache-for-name 'Ca) "; Emit_racket.RArg _; Emit_racket.RLit ")" ] ->
     check "ECacheDelete MISS lowers to (cache-for-name 'NAME)" true
   | _ -> check "ECacheDelete MISS lowers to (cache-for-name 'NAME)" false);
  (match Emit_racket.lower_effect (empty_tables ())
           (ECacheInvalidate { cache_name = "Ca"; prefix = var 49 "p"; loc = loc_at 50 }) with
   | Some [ Emit_racket.RLit "(cache-invalidate-prefix! (cache-for-name 'Ca) "; Emit_racket.RArg _; Emit_racket.RLit ")" ] ->
     check "ECacheInvalidate MISS lowers to (cache-for-name 'NAME)" true
   | _ -> check "ECacheInvalidate MISS lowers to (cache-for-name 'NAME)" false);

  (* 4e. Email family — same hit/miss twin rule ((email-for-name 'NAME) on a
     miss; byte-identical bare binding on a hit, gated by lesson60-email). *)
  let email_tables = empty_tables () in
  Hashtbl.replace email_tables.Emit_racket.emails "Em" ();
  (match Emit_racket.lower_effect email_tables
           (ESendEmail { email_name = "Em"; to_ = var 51 "t"; subject = var 52 "s";
                         body = var 53 "b"; loc = loc_at 54 }) with
   | Some [ Emit_racket.RLit "(send-email! Em #:to "; Emit_racket.RArg _; Emit_racket.RLit " #:subject "; Emit_racket.RArg _;
         Emit_racket.RLit " #:body "; Emit_racket.RArg _; Emit_racket.RLit ")" ] ->
     check "ESendEmail HIT keeps the bare local email binding" true
   | _ -> check "ESendEmail HIT keeps the bare local email binding" false);
  (match Emit_racket.lower_effect (empty_tables ())
           (ESendEmail { email_name = "Em"; to_ = var 51 "t"; subject = var 52 "s";
                         body = var 53 "b"; loc = loc_at 54 }) with
   | Some [ Emit_racket.RLit "(send-email! (email-for-name 'Em) #:to "; Emit_racket.RArg _; Emit_racket.RLit " #:subject "; Emit_racket.RArg _;
         Emit_racket.RLit " #:body "; Emit_racket.RArg _; Emit_racket.RLit ")" ] ->
     check "ESendEmail MISS lowers to (email-for-name 'NAME)" true
   | _ -> check "ESendEmail MISS lowers to (email-for-name 'NAME)" false);
  check "EStartEmailWorker HIT keeps the bare local email binding"
    (is_rlit_only "(start-email-worker! Em)"
       (Emit_racket.lower_effect email_tables
          (EStartEmailWorker { email_name = "Em"; loc = loc_at 53 })));
  check "EStartEmailWorker MISS lowers to (email-for-name 'NAME)"
    (is_rlit_only "(start-email-worker! (email-for-name 'Em))"
       (Emit_racket.lower_effect (empty_tables ())
          (EStartEmailWorker { email_name = "Em"; loc = loc_at 53 })));

  (* 5. The module pass now PRESERVES the effect forms: they must reach whichever backend
     emits them, since only that backend knows how to lower them.  The Racket lowering is
     what turns them into runtime calls, and it must cover every one of them. *)
  let out = Desugar.desugar_module sample_module in
  let effect_forms = ref 0 in
  let lowerable = ref 0 in
  (match out.decls with
   | DFunc fd :: _ ->
     let rec count e =
       (match e with
        | ETelemetry _ | EEnqueue _ | EStartWorkers _ | EServe _
        | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _
        | ESendEmail _ | EStartEmailWorker _ ->
          incr effect_forms;
          if Emit_racket.lower_effect (empty_tables ()) e <> None then incr lowerable
        | _ -> ());
       ignore (Ast_visitor.fold_children (fun () e -> count e; ()) () e)
     in count fd.body
   | _ -> ());
  check "desugar_module leaves all 10 fixed-shape effect forms intact"
    (!effect_forms = 10);
  check "the Racket backend lowers every one of them"
    (!lowerable = 10);

  (* 6. Provenance helper records the surface loc verbatim. *)
  let surface = loc_at 200 in
  check "provenance_from records the surface loc"
    ((Desugar.provenance_from surface).desugared_from = surface);

  (* 7. Declarations with no expr children pass through untouched. *)
  let ty_decl = DType (TypeNewtype { name = "T"; base_type = TName { name = "String"; loc = loc_at 300 }; secret = false; loc = loc_at 301 }) in
  check "non-expr declaration passes through verbatim"
    (Desugar.desugar_decl (Desugar.empty_tables ()) ty_decl = ty_decl);

  if !failed = 0 then (Printf.printf "\nALL DESUGAR TESTS PASSED\n"; exit 0)
  else (Printf.printf "\n%d DESUGAR TEST(S) FAILED\n" !failed; exit 1)
