# Historical format-3 bridge under stored-value contract 2

This is an immutable historical prototype, not the current runtime. The actual
compiler built from exact Git commit `27caa305` emitted `worker-app.tar.gz` from
the three byte-identical Tesl sources in the
[`format-2 fixture`](../control-format2/README.md). No compiler, runtime, history
or generated application source was patched to manufacture compatibility.

The manifest records all 88 emitted files and the original source hashes:

- Compiler ABI: `tesl-source-abi-v1:2a00109a022a84309261ac80dc2947f5a4de32384eb5df1c790741e540228855`
- Stored-value contract: `tesl-stored-value-v1:12c05146e5164485b878df083a803b23ceedcb16b232268408b1f5de2088de4b`
- Archive SHA-256: `3bd06cae1ad38506fb3b5e0a83641dcedf0eb1732ac85cb7254cd979280a9c36`

`TestCompiledControlFormatUpgrade` builds this emission unchanged, exercises its
real 2-to-3 installer, loses the committed acknowledgement, retries, and serves
retained data through the bridge's normal request and worker binaries. The
original format-2 executable must refuse the upgraded catalog.

This prototype predates `tesl_lock_expired_index_holder`, the sixth index-recovery
API required by the current closed format-3 catalog. The current compiler also
uses stored-value contract 3 after tightening proof identity. Its executable
must refuse this prototype's precise missing function without HTTP or mutation;
that check is catalog evidence. Its request, status and installer paths exercise
exact semantic-contract refusal against the recognized format-2 catalog. Its
worker stops earlier with the explicit format-2 installer-upgrade requirement. The test never interprets a generic
startup failure as either kind of compatibility evidence.

Keep the archive, manifest and saved sources unchanged. A new baseline requires
a separate authentic fixture. Both fixture loaders validate their explicitly
expected format and file count and run the same 17 tampering cases before any
build or database connection.
