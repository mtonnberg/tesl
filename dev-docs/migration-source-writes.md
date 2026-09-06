# Guarded migration source writes

> Audience: compiler, native CLI and editor contributors.

The compiler owns source selection, history validation and edit generation. The
native CLI consumes that compiler response through `internal/sourceedit`. Neither
component connects to a database. A successful source write does not establish
that the proposal compiles or that a database migration is safe to execute.

## Commands and outcomes

`tesl migrate generate app.tesl --manifest-json` returns the read-only version-1
`migration-source-preview` envelope. Plain `tesl migrate generate app.tesl` uses
the same preview and publishes its saved-file edits. Its JSON changes `kind` to
`migration-source-application` and adds `sourceTransaction`:

```json
{"outcome":"committed","manifestHash":"<sha256>","written":["/project/migrations/notes/v2.tesl"],"restored":[],"recoveryRequired":false}
```

`ok` reports source operation success; `compilable` retains the compiler's complete
application judgment. A skeleton with MIG003 holes can be written successfully.
The caller must not mistake that result for a compiling program. Failure returns
a nonzero exit, `ok: false`, and an error. A compiler selection/generation failure
retains the original preview error response without an applicable manifest.

`outcome` is `unchanged`, `prepared`, `committed`, or `restored`. `written` and
`restored` list operations observed by that invocation; a restarted recovery does
not reconstruct the previous process's entire activity log. `recoveryRequired`
means retained state needs recovery or inspection. A commit followed by cleanup
failure remains committed; recovery must not undo it.

`tesl migrate recover-source --project-root DIR` restores an unfinished source
write or completes cleanup after a durable terminal outcome. Its version-1 JSON
has `kind: migration-source-recovery`, `ok`, and `sourceTransaction`. Repeating
recovery after cleanup succeeds without changes. It never chooses a project by
searching for a journal. Path normalization checks each component before handling
`..`, so a symlink cannot disappear from the selected path spelling.

## Consumer boundary

The decoder requires the compiler's known protocol, successful preview judgment,
actual source ABI identity, and consistent application diagnostics. It rejects
unknown or duplicate keys, case aliases, invalid UTF-8, unpaired JSON surrogates,
invalid paths, inconsistent preimages, missing guards and oversized input. The
manifest's immutable canonical JSON and SHA-256 match the OCaml producer exactly,
including Unicode and control-character encoding. Accessors return copies.

The tooling client's `QueryMigrationPreview` passes open buffers and signed
document versions through the compiler's explicit overlay endpoint. It uses real
logical project paths, not a remapped shadow manifest. It verifies the returned
project, entry, selected database, requested new-revision operation and every
buffer's version **and source hash**. Open-document guards cannot claim absent
source. Compiler failure, cancellation and timeout never yield an applicable
preview, even if stdout contains JSON. Private overlay contents files are removed
after the process exits. The LSP exposes this transport through the read-only
`tesl.generateMigration` command and retains one immutable preview per session.
Its summary lists every edited file, the selected database, operation and proposed
application diagnostics; `tesl.migrationPreviewFile` retrieves original/proposed
bytes for one listed file without reading disk again. A new generation attempt
expires the previous handle, including refusal, invalid selection and cancellation.
Late compiler success after cancellation cannot retain a preview. Summary and
file responses are bounded below the editor transport's message limit. See
[the editor protocol](../editor/protocol.md#migration-source-preview-commands)
for arguments and responses. The UI and mixed open/closed apply protocol remain
pending; neither preview command changes source.

Saved-file application rejects open document versions, source/disk byte or
membership differences, and differing import resolution. Even a no-op refresh
refuses an existing transaction. The editor's mixed open/closed document protocol
is a separate pending consumer; this writer never silently saves a buffer.

The editor's read-only application planner retains that full manifest and checks
all open inputs again, including dependencies with no generated edits. A close/
reopen invalidates the preview even if the replacement buffer has the same bytes
and document version. Forward edits bind exact versions and source; inverse edits
bind the observed post-edit version and restore the exact original buffer. An
inverse refuses changed user contents or a different buffer lifetime. LF and CRLF
sources are supported; bare CR is refused because the shared position index cannot
describe those complete replacements exactly. This planner does not yet apply
buffers or publish closed files. The filesystem writer's saved-only restriction
remains in place until the shared journal and client acknowledgement lifecycle are
implemented.

Each input file, directory membership and import resolution is checked again
against disk. Checks continue as publication progresses, ignoring only this
transaction's own new entries. Root and control-directory identity are pinned;
reads reject symlinks and special files. Nonblocking no-follow opens prevent a
FIFO substituted after a path check from hanging the operation.

## Publication and inverse

A private `.tesl-source-edit` directory contains an exclusively locked owner file,
a versioned journal, and staged/captured inodes. The journal records the manifest,
its hash, a random operation identity, original permissions, required new
directories and phase. It is durable before any source file or directory changes.
Existing source files are replaced with Linux atomic exchange, retaining the
actual displaced inode. New files use atomic no-replace hard-link publication.
A save racing the last preimage check therefore remains recoverable. Permissions
are preserved on replacements; new files and directories are private to the user.

New directories are prepared privately with a durable ownership marker before
no-replace publication. Rollback removes only its own directories. An unrelated
empty directory created at the same path survives. User files arriving during
directory capture are returned to their original directory and block cleanup.

A failure before commit applies the guarded inverse in reverse order. It captures
published output before restoring a retained original inode with no-replace
publication. Unexpected user bytes are retained, not overwritten with a journal
preimage. If a user edited a published source, recovery reports the conflict and
leaves the source and journal for inspection. After the conflict is resolved,
recovery can resume; it can itself be interrupted at any boundary.

The `committed` or `restored` journal phase is durable before backup cleanup. A
restart in either terminal phase only finishes cleanup. A torn unpublished
`journal.tmp` cannot authorize commit. If no journal was published, recovery only
cleans recognized preparation files; retained source slots without a journal
require inspection. Unknown metadata or changed retained bytes also block cleanup.

These are individually atomic file operations with a durable guarded inverse,
not a filesystem-wide atomic replacement of the whole project. Other processes
may observe intermediate files. Editors must coordinate their own document/index
updates around the eventual shared apply protocol.

## Verification and remaining scope

Formatting preserves the same frozen-source boundary. `Migration_format_guard`
protects canonical numbered schema snapshots and completed migration namespaces,
including their private helpers and symlink aliases. Completion comes from a
frozen sibling snapshot or the existing leading-comment closure protocol; a
marker-shaped comment in ordinary code is not completion. CLI formatting refuses
a changed frozen file with MIG013, while `fmt-check` exempts frozen bytes from
style drift. Current source remains editable and can be refreshed normally.
The editor's read-only `--format-json` query sees all open buffers in a bounded
snapshot, including unsaved completion metadata. It returns no edit for protected
source and never writes or saves a workspace file. This prevents accidental
formatting changes; seals and persisted history remain independent integrity
checks. See [the editor protocol](../editor/protocol.md#formatting-response-shape).

Regressions consume real compiler manifests and check every resulting Tesl file
with the current compiler. They cover start/refresh/next revision, complete app
judgments, unchanged connection/application source, staleness, overlays, imports,
malformed protocols, permissions, cancellation, concurrent saves and creations,
live-owner exclusion, and interrupted publication/inverse/cleanup. Crash tests
use separate processes that exit at private test callbacks; no production command
or environment variable enables fault injection. Directory tests include user
writes after capture and foreign empty directories racing publication. Additional
cases cover failure before journal preparation, writes through displaced open file
handles, saves racing the inverse's last comparison, occupied capture destinations
and symlink redirection during recovery. The manifest fuzzer runs in `ci.sh`.
Aggregate statement coverage is recorded in the implementation ledger; it does not
stand in for testing every filesystem failure.

The decoder is portable. Atomic publication/recovery currently require Linux
`renameat2` and `flock`; other hosts refuse before writing. Windows/macOS mutation,
the editor lifecycle, rebase/repair/contract/prune source commands, live catalog
planning, and PostgreSQL execution remain pending. Read-only source expansion
plans are described in [migration planning](migration-planning.md). Source ABI records also do not
settle the separate persisted execution ABI or cross-ABI proof-admission design.
