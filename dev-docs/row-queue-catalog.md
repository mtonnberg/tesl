# Combined row and queue catalog candidate

> Audience: contributors implementing and verifying migration catalogs.

This slice changes the **unpublished row format 5 candidate**. Public format 3
and private queue format 4 retain their existing catalog, admission functions,
and refusals. It does not upgrade an installed catalog. An older private row5
catalog without the complete new tables/functions fails exact layout validation.
Every acceptance binary is generated from the new complete candidate before its
source history is frozen; original source files are removed before execution.

The compiler always embeds its complete checked queue companion in row source
artifacts, including an explicit empty inventory. Missing metadata is unknown,
never an empty inventory. The ordinary row artifact entry continues to refuse
nonempty queues. `Compile.compile_row_catalog_artifacts` is an internal installer
and test route sharing the exact captured graph, source guards, owner lookup and
codec emission. It omits all command entry files; no CLI flag selects it. Its
ordinary App preflight still refuses queue execution.

The internal catalog installer validates the actual generated database and queue
owners and all codec bindings before closing local registration. It accepts only
queue facilities. Fresh installation stores complete queue and facility
inventories, queue payload contracts, and the protected queue table/function
catalog even when empty. Empty canonical baseline inventory bytes stay unchanged;
the SQL layout nevertheless changes and is compared exactly.

`tesl_row_queue_sources` binds a canonical row-owned source inventory to each row
version. The queue source storage hash and the row physical expansion hash are
separate fields. Registration uses the stored physical document's framed header
to check family, namespace, version, schema hash and storage hash before inserting
any queue/source rows. The complete physical parser continues to validate the
rest of the descriptor and its lineage. Queue and physical source registration
share one transaction. Readers validate the contiguous installed prefix,
canonical payload inventory, source/physical binding, original creator ABI and
stored-value compatibility. Compatible recompilation preserves the creator ABI
and source-seal provenance. A seal marked `unknown` or `unrecorded` never grants
historical installation or adoption authority.

Source metadata alone does not grant queue dispatch. Installed queue operations
retain their closed format4 checks and refuse row5. Joint row/queue admission,
payload restamping, queue finality before floor changes, and public activation
remain required work. Payload removal, movement and transformation remain refused.
The fresh catalog tests are not evidence of legacy adoption or an upgrade path.

The source-deleted native fixture includes both an entity and a private-codec
queue. Original V1 creates its catalog and entity baseline; original V2 registers
its additive source inventory, and the retained V1 reader checks the complete
future binding. Negatives exercise unknown origins, exact catalog shape,
source-storage versus physical-hash substitution, and direct Worker calls with
freshly recomputed invalid source bindings. Direct Worker negatives distinguish
rollback of a physical record created in the same transaction from preservation
of a physical record committed beforehand.
