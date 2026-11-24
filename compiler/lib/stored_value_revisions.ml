(* Reviewed behaviour revisions of builtins that can change stored values.

   The stored-value identity (Migration_abi.stored_value_compatibility) hashes
   the semantics of the stdlib modules written in Tesl directly. Builtins that
   are implemented in OCaml (the proof checker, the canonical storage mapping)
   or in the Go runtime (codecs, value types, string and time primitives) are
   not visible to that hash, so each family that can change how a stored value
   is encoded, decoded, compared or proved carries a revision number here. The
   revision numbers, and nothing else in this table, enter the identity.

   Bump a family's revision when a change can make an existing stored value
   decode differently, satisfy a check differently, or be written differently.
   Do not bump it for a refactor, a performance change, an error message or a
   new builtin that no existing value can reach: a bump changes the identity of
   every project and requires `tesl migrate reseal` for each sealed
   history, and databases written under the old identity refuse the new
   binaries.

   [files] records the SHA-256 of each implementation file (line endings
   normalised to LF) as last reviewed. test_stored_value_revisions fails when a
   listed file changes, so every change to these files is reviewed against this
   decision. After reviewing, either bump [revision] or leave it, and in both
   cases record the new digests the test prints. *)

type family = {
  name : string;
  revision : int;
  files : (string * string) list;  (* repository-relative path, reviewed digest *)
}

(* Revision history of proof-interpretation (formerly the single
   "tesl-stored-value-semantics-N" string):
   5 keeps optional attached evidence on the returned success payload, verifies
     input-named attached results on every returning branch, and never treats a
     fresh result or partial call as an input alias.
   4 could attach a transformed result's detached witness to the unchanged
     input when return/input binders had the same spelling, then store that
     invalid evidence. It compares complete proof applications at HTTP auth,
     capture and response boundaries, refuses unvalidated top-level request-body
     proofs and unexecuted body-via clauses.
   3 could admit reader evidence to an admin-annotated handler; it preserved
     original predicate owners through hidden forwarding, qualified imports and
     Fact-valued callbacks, and refused detached Fact storage without a subject
     contract.
   2 accepted cross-owner evidence through hidden wrappers and subject
     rebinding through raw Fact carriers. *)
let families = [
  {name="proof-interpretation"; revision=5; files=[
    "compiler/lib/proof_kernel.ml","3cada1eb90e3954f2003019ed694c1e05971015a284ff630208d9a0c81d6a258";
    "compiler/lib/proof_checker.ml","5eedb19a1114d186fe970e36a47d1654dc45208f6f4fd96959c6386dd84e56b4";
    "compiler/lib/proof_discharge.ml","f9f9f14492ffa01bb3bdc0a24dbbca8e5b0c881b21d28280cdc3867563af9917";
    "compiler/lib/validation_proof.ml","457f3c7ff53e09c89347541e87f6d0d48650c2afc619a43598adb3e06f841619";
  ]};
  {name="canonical-storage-mapping"; revision=1; files=[
    "compiler/lib/migration_canonical.ml","5b529b61920c28db7f8cd3f9e735ec2c216f0f6a3f9495afe960977002b14499";
    "compiler/lib/migration_ir.ml","81b88ff91e6f5b76274a36bf2ee263a499993796695556f7aedbf24a308e9828";
    "compiler/lib/migration_storage.ml","f249f603c936ce49f1d46d39a1c804223a1f9b378fff273a8685166fe501f022";
    "compiler/lib/validation_sql_codec.ml","916e37858fcec84d3553907f7a3032a2d93a7adfc03c545fca86216533174241";
  ]};
  {name="json-codecs"; revision=1; files=[
    "runtime/go/teslrt/json.go","74689e52de6ae56692f55e6665afb5e66a30e9cb5d594ca6e1b3450e91168caa";
    "runtime/go/teslrt/jsonb_text.go","ff598945dffda4e0df1ea2d6f058deb68d8252aa37905cd4e9cdd8f25d402acc";
  ]};
  {name="database-values"; revision=1; files=[
    "runtime/go/teslrt/database.go","80cc15ebb2814b66daaaba1f6408832b480adbe056d06279d59943479220457b";
    "runtime/go/teslrt/dbquery.go","9ed48bc93d3c8ff00643c55b97d1658700e24c3f52a88abeb4fcfa42c29494dc";
    "runtime/go/teslrt/postgres.go","321e9d6e3e3c6d5d0ddc624b0a24e2e9ff48372d1114e7aaf3400dd3299c88d6";
    "runtime/go/teslrt/pgstores.go","297f9ac165f31d3609ee709ffd90692ef18bd1b646f2e59b59a83a0f8667061c";
    "runtime/go/teslrt/table.go","769fe5497f7fae55672b505b4053ac587a722f001cb780a2ab511cfe4bab8cfa";
  ]};
  {name="numbers-and-units"; revision=1; files=[
    "runtime/go/teslrt/int.go","770a7775ca379ca02334be14f5e0ce06c5db20c3319cfc7e5a0dc490f6782f9b";
    "runtime/go/teslrt/int32.go","217b63fc205cece97972b4a759ca717b903ccae5cbbfcedcfe9cf45bb213bdc9";
    "runtime/go/teslrt/float.go","88a49861b4f0db2fca69616e6fd6fb4f53fc0cb4d4144a22b8abc45bc201b50f";
    "runtime/go/teslrt/money.go","484b65c57bacd98f3eb25f54db140c8318e5967517ba08999d7986b4ff417afd";
    "runtime/go/teslrt/units.go","629973f63c3ea32d831e61668f7cf130237b61bf247831ddcf22c6e2c86c3b30";
    "runtime/go/teslrt/units_data.go","e6e7b074a43da0b9e98c50406a93a16c884bed689e354957587753d2731a52ad";
    "runtime/go/teslrt/currency_data.go","c1ea387f03c36ec51cbe5866d72412013846bdd6908f953626626dd3e22bec40";
  ]};
  {name="text-and-patterns"; revision=1; files=[
    "runtime/go/teslrt/string.go","4556bdbd8361510bfaf533c6521027ec168853c864ede73fd9f1c2d3787eed79";
    "runtime/go/teslrt/regex.go","6b7a859cbbf6a7eeec53dfc8b9096054c16434f01a2677d74fb9c5c269fe4959";
  ]};
  {name="time"; revision=1; files=[
    "runtime/go/teslrt/time.go","83b347dbe2348e5158b5f10472a92c11e3d20894ebee198accdeb47f20a3bd59";
    "runtime/go/teslrt/timetrunc.go","6f5d205a8dcb82cc757e4e07917df723999499e6d2d952c095ab5bf77ae4be10";
    "runtime/go/teslrt/timezone.go","8252b1daf49ed78270d4fbcc78fc71c083c6e4a0ef2c1dc9ad0d34905cf2ee67";
  ]};
  {name="credentials"; revision=1; files=[
    "runtime/go/teslrt/password.go","62bbf446e5c091e90043afe0be66ed4bc86eeb8875091689dd94fbe3469b1ce1";
    "runtime/go/teslrt/crypto.go","1039ab920abb36dd774e1de6f460d19ba1dd4df6b5dae9f1cfdfba05cb5a2a20";
    "runtime/go/teslrt/secret.go","d490d06734dd860fe100a34783a67e4ce4fca1cce3fc5df0bc176049ecc9b0d3";
  ]};
  {name="urls-and-hosts"; revision=1; files=[
    "runtime/go/teslrt/url.go","24991ba2ac3e6432be879e49a47ab718378d0862328d32c0d02a6897aaadc677";
    "runtime/go/teslrt/hostclass.go","354fc870f9810e7d8bc644bfb4603f0b02cb2b5613cb72130a6b9e5f08cc4589";
  ]};
  {name="collections"; revision=1; files=[
    "runtime/go/teslrt/list.go","e3ffa9503f1236806a65bdb9563fcf79d937f448723ee4742286121f62e986c4";
    "runtime/go/teslrt/collections_hof.go","87e7be22978aa7f4d9a8e581da245c01d7a637cc17ee1e5b75ad7a2dbb8477a7";
    "runtime/go/teslrt/dict.go","3b085202481feaae671b0f5b052b5c0c22f8c0dfe2599c2c795863891359590f";
    "runtime/go/teslrt/set.go","9d7f8b1b65b43283288550ee775ee13ea70d23b9b8fdc05917b3d242bbac1c81";
    "runtime/go/teslrt/maybe.go","9b1fbdf9a0099a8f600f677b82ff5fdd3c35b368ef87873ff296d7bb9dbb945d";
    "runtime/go/teslrt/either.go","474d9a830bc1c1029dd21440b199784df6367ca0bf107336e8fc63147b334ffb";
    "runtime/go/teslrt/result.go","7540ff4d35312340920b390ebb6203f7ae402ebbe8f21c9df02e650c0b9ea065";
    "runtime/go/teslrt/tuple.go","b253ee38f1d98a07804950d9789df83cbfc7550023ca048caef9ea0e80f8b883";
  ]};
  {name="checks"; revision=1; files=[
    "runtime/go/teslrt/check.go","1640d083a250f1679f237708b6128a5e070c61c2823c2ad71dbbd2e7c9ee6ca9";
  ]};
]

let revisions () = List.map (fun f -> f.name,f.revision) families

(* The digest the review table records: SHA-256 of the file with CRLF line
   endings normalised, so a Windows checkout reviews the same bytes. *)
let file_digest source =
  Migration_hash.digest (Str.global_replace (Str.regexp_string "\r\n") "\n" source)
