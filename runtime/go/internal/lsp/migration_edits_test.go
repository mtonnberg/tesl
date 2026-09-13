package lsp

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/sourceedit"
)

func previewMigrationEditPlan(t *testing.T, server *Server, doc document) *migrationEditPlan {
	t.Helper()
	migrationEditorCommand(t, server, "tesl.generateMigration", map[string]string{"entryFile": doc.Path, "projectRoot": filepath.Dir(doc.Path)}, 0)
	plan, err := server.prepareMigrationEdits(server.migrationPreview)
	if err != nil {
		t.Fatal(err)
	}
	return plan
}

func applyMigrationTestEdit(t *testing.T, source string, edit *migrationTextDocumentEdit) string {
	t.Helper()
	if edit == nil || len(edit.Edits) != 1 {
		t.Fatal("expected one versioned document edit")
	}
	index := protocol.NewLineIndex(source)
	start, err := index.Offset(edit.Edits[0].Range.Start)
	if err != nil {
		t.Fatal(err)
	}
	end, err := index.Offset(edit.Edits[0].Range.End)
	if err != nil || start != 0 || end != len(source) {
		t.Fatalf("edit did not cover exact preimage: %d..%d/%d %v", start, end, len(source), err)
	}
	return source[:start] + edit.Edits[0].NewText + source[end:]
}

func TestMigrationEditPlanPreservesExactForwardAndInverseBuffers(t *testing.T) {
	for _, example := range [][2]string{
		{"", "new\n"}, {"old\n", ""}, {"old", "new"},
		{"Å🌱\r\nold\r\n", "📚é\r\nnew\r\n"}, {"\n\nold🌱", "new\n\n🌱"},
	} {
		server, doc, created, compiler := migrationEditorSourceFixture(t, example[0], example[1])
		originalManifest := compiler.preview.Manifest().JSON()
		plan := previewMigrationEditPlan(t, server, doc)
		if len(plan.open) != 1 || len(plan.closed) != 1 || plan.closed[0] != created || !bytes.Equal(plan.manifest.JSON(), originalManifest) {
			t.Fatal("planning changed manifest guards or included closed files in buffer edits")
		}
		forward, err := plan.open[0].forward(doc)
		if err != nil || forward == nil || forward.TextDocument.Version != doc.Version || forward.TextDocument.URI != doc.URI {
			t.Fatalf("forward edit is not pinned to the exact buffer: %+v %v", forward, err)
		}
		if actual := applyMigrationTestEdit(t, doc.Text, forward); actual != example[1] {
			t.Fatalf("forward edit corrupted bytes: %q", actual)
		}
		changed := doc
		changed.Text, changed.Version = example[1], doc.Version+4
		inverse, err := plan.open[0].inverse(changed)
		if err != nil || inverse == nil || inverse.TextDocument.Version != changed.Version {
			t.Fatalf("inverse guessed an editor version: %+v %v", inverse, err)
		}
		if actual := applyMigrationTestEdit(t, changed.Text, inverse); actual != example[0] {
			t.Fatalf("inverse corrupted preimage bytes: %q", actual)
		}
		forward.Edits[0].NewText = "caller mutation"
		again, err := plan.open[0].forward(doc)
		if err != nil || applyMigrationTestEdit(t, doc.Text, again) != example[1] {
			t.Fatal("caller mutated retained plan")
		}
		if entries, err := os.ReadDir(filepath.Dir(doc.Path)); err != nil || len(entries) != 0 || server.documents[doc.URI] != doc {
			t.Fatal("planning wrote disk or changed an editor buffer")
		}
	}
}

func TestMigrationEditPlanRefusesStaleBuffersAndPreservesUserEdits(t *testing.T) {
	for _, change := range []string{"text", "version", "lifetime", "closed", "new open", "closed file opened", "duplicate URI"} {
		t.Run(change, func(t *testing.T) {
			server, doc, created, _ := migrationEditorFixture(t)
			previewMigrationEditPlan(t, server, doc)
			changed := doc
			switch change {
			case "text":
				changed.Text = "unsaved user work"
			case "version":
				changed.Version++
			case "lifetime":
				changed.openID++
			case "closed":
				delete(server.documents, doc.URI)
			case "new open", "closed file opened":
				path := filepath.Join(filepath.Dir(doc.Path), "another.tesl")
				if change == "closed file opened" {
					path = created
				}
				server.documents[protocol.PathToURI(path)] = document{URI: protocol.PathToURI(path), Path: path, Version: 1, Text: "user work"}
			case "duplicate URI":
				server.documents[doc.URI+"alias"] = doc
			}
			if change != "closed" {
				server.documents[doc.URI] = changed
			}
			if plan, err := server.prepareMigrationEdits(server.migrationPreview); err == nil || plan != nil {
				t.Fatal("stale editor snapshot produced an application plan")
			}
		})
	}
	server, doc, _, _ := migrationEditorFixture(t)
	plan := previewMigrationEditPlan(t, server, doc)
	for _, change := range []string{"text", "version", "lifetime", "URI"} {
		changed := doc
		switch change {
		case "text":
			changed.Text = "user work"
		case "version":
			changed.Version++
		case "lifetime":
			changed.openID++
		case "URI":
			changed.URI += "alias"
		}
		if edit, err := plan.open[0].forward(changed); err == nil || edit != nil {
			t.Fatalf("forward edit ignored changed %s", change)
		}
	}
	for _, change := range []string{"text", "version", "lifetime", "URI"} {
		changed := doc
		changed.Text, changed.Version = "new", doc.Version+1
		switch change {
		case "text":
			changed.Text = "user changed the proposal"
		case "version":
			changed.Version = doc.Version
		case "lifetime":
			changed.openID++
		case "URI":
			changed.URI += "alias"
		}
		if edit, err := plan.open[0].inverse(changed); err == nil || edit != nil {
			t.Fatalf("inverse overwrote changed %s", change)
		}
	}
	if inverse, err := plan.open[0].inverse(doc); err != nil || inverse != nil {
		t.Fatal("already restored buffer was edited again")
	}
}

func TestMigrationEditPlanGuardsUneditedDependencies(t *testing.T) {
	server, doc, _, compiler := migrationEditorFixture(t)
	path := filepath.Join(filepath.Dir(doc.Path), "zhelper.tesl")
	dependency := document{URI: protocol.PathToURI(path), Path: path, Version: -4, Text: "helper"}
	server.documents[dependency.URI] = dependency
	fields := map[string]json.RawMessage{}
	if err := json.Unmarshal(compiler.preview.JSON(), &fields); err != nil {
		t.Fatal(err)
	}
	manifest := map[string]json.RawMessage{}
	if err := json.Unmarshal(fields["manifest"], &manifest); err != nil {
		t.Fatal(err)
	}
	var documents, inputs []map[string]any
	if err := json.Unmarshal(manifest["documents"], &documents); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(manifest["inputs"], &inputs); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256([]byte(dependency.Text))
	digest := hex.EncodeToString(hash[:])
	documents = append(documents, map[string]any{"path": path, "version": dependency.Version})
	inputs = append(inputs, map[string]any{"path": path, "sourceHash": digest, "diskHash": digest})
	manifest["documents"], _ = json.Marshal(documents)
	manifest["inputs"], _ = json.Marshal(inputs)
	fields["manifest"], _ = json.Marshal(manifest)
	raw, _ := json.Marshal(fields)
	preview, err := sourceedit.DecodePreview(raw)
	if err != nil || preview == nil {
		t.Fatal(err)
	}
	compiler.preview = preview
	plan := previewMigrationEditPlan(t, server, doc)
	if len(plan.open) != 1 || plan.open[0].before.Path == path {
		t.Fatal("unedited dependency acquired an edit")
	}
	dependency.Text = "changed helper implementation"
	server.documents[dependency.URI] = dependency
	if plan, err := server.prepareMigrationEdits(server.migrationPreview); err == nil || plan != nil {
		t.Fatal("unchanged target document hid a changed dependency")
	}
}

func TestMigrationEditPlanRefusesMalformedTextAndReopenedBuffer(t *testing.T) {
	for _, source := range []string{"line\r", "one\rtwo", "\xff"} {
		if _, err := migrationDocumentRange(source); err == nil {
			t.Fatalf("unsupported source received a clamped range: %q", source)
		}
	}
	server, doc, _, compiler := migrationEditorFixture(t)
	compiler.payload = []byte(`{"version":1,"diagnostics":[]}`)
	ctx, cancel := context.WithCancel(context.Background())
	defer func() { cancel(); server.waitDiagnostics() }()
	writer := protocol.NewWriter(io.Discard)
	open, _ := json.Marshal(map[string]any{"textDocument": map[string]any{"uri": doc.URI, "version": doc.Version, "text": doc.Text}})
	if err := server.didOpen(ctx, open, writer); err != nil {
		t.Fatal(err)
	}
	plan := previewMigrationEditPlan(t, server, server.documents[doc.URI])
	closeParams, _ := json.Marshal(map[string]any{"textDocument": map[string]string{"uri": doc.URI}})
	if err := server.didClose(ctx, closeParams, writer); err != nil {
		t.Fatal(err)
	}
	if err := server.didOpen(ctx, open, writer); err != nil {
		t.Fatal(err)
	}
	if _, err := server.prepareMigrationEdits(server.migrationPreview); err == nil {
		t.Fatal("same bytes and version concealed a reopened buffer")
	}
	if _, err := plan.open[0].inverse(server.documents[doc.URI]); err == nil || !strings.Contains(err.Error(), "reopened") {
		t.Fatal("inverse failed to preserve new buffer lifetime")
	}
}
