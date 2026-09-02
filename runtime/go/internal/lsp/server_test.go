package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

type fakeCompiler struct {
	payload   []byte
	responses map[string][]byte
	flags     []string
	queries   int
}

func (compiler *fakeCompiler) QuerySourceJSON(_ context.Context, flag, _ string, _ string, _ ...string) ([]byte, tooling.Result, error) {
	compiler.queries++
	compiler.flags = append(compiler.flags, flag)
	if response, found := compiler.responses[flag]; found {
		return response, tooling.Result{}, nil
	}
	return compiler.payload, tooling.Result{}, nil
}

func (compiler *fakeCompiler) QueryJSON(_ context.Context, args ...string) (json.RawMessage, tooling.Result, error) {
	if len(args) > 0 {
		compiler.flags = append(compiler.flags, args[0])
	}
	if response, found := compiler.responses["--doc-json"]; found {
		return response, tooling.Result{}, nil
	}
	return compiler.payload, tooling.Result{}, nil
}

func (compiler *fakeCompiler) FormatSource(context.Context, string, string) ([]byte, tooling.Result, error) {
	return []byte("formatted"), tooling.Result{}, nil
}

type cancellableCompiler struct {
	started  chan struct{}
	canceled chan struct{}
}

func (compiler *cancellableCompiler) QuerySourceJSON(ctx context.Context, _ string, _ string, source string, _ ...string) ([]byte, tooling.Result, error) {
	if source == "old" {
		select {
		case <-compiler.started:
		default:
			close(compiler.started)
		}
		<-ctx.Done()
		close(compiler.canceled)
	}
	return []byte(`{"version":1,"diagnostics":[]}`), tooling.Result{}, nil
}

func (compiler *cancellableCompiler) QueryJSON(context.Context, ...string) (json.RawMessage, tooling.Result, error) {
	return []byte(`{"version":1,"entries":[]}`), tooling.Result{}, nil
}

func (compiler *cancellableCompiler) FormatSource(context.Context, string, string) ([]byte, tooling.Result, error) {
	return []byte("formatted"), tooling.Result{}, nil
}

func TestServerInitializesPublishesDiagnosticsAndShutsDown(t *testing.T) {
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[{"file":"/tmp/demo.tesl","start":{"line":0,"col":1},"end":{"line":0,"col":5},"severity":"warning","code":"W001","message":"careful","source":"lint","fix":null}]}`)}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "initialize", Params: json.RawMessage(`{}`)},
		protocol.Request{JSONRPC: "2.0", Method: "initialized"},
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"x = 1"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	var messages [][]byte
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		messages = append(messages, message)
	}
	if len(messages) != 3 {
		t.Fatalf("response count = %d, want 3", len(messages))
	}
	if compiler.queries != 1 {
		t.Fatalf("compiler queries = %d, want 1", compiler.queries)
	}
	var diagnostics protocol.Request
	if err := json.Unmarshal(messages[1], &diagnostics); err != nil {
		t.Fatal(err)
	}
	if diagnostics.Method != "textDocument/publishDiagnostics" {
		t.Fatalf("notification method = %q", diagnostics.Method)
	}
	var params struct {
		Diagnostics []struct {
			Severity int    `json:"severity"`
			Code     string `json:"code"`
		} `json:"diagnostics"`
	}
	if err := json.Unmarshal(diagnostics.Params, &params); err != nil {
		t.Fatal(err)
	}
	if len(params.Diagnostics) != 1 || params.Diagnostics[0].Severity != 2 || params.Diagnostics[0].Code != "W001" {
		t.Fatalf("diagnostics = %#v", params.Diagnostics)
	}
}

func TestServerAnswersHoverDefinitionAndCompletion(t *testing.T) {
	compiler := &fakeCompiler{
		payload: []byte(`{"version":1,"diagnostics":[]}`),
		responses: map[string][]byte{
			"--type-at-json":     []byte(`{"version":1,"type_at":{"type":"Int"}}`),
			"--definition-json":  []byte(`{"version":1,"definition":{"file":"/tmp/demo.tesl","line":0,"col":0,"end_line":0,"end_col":1}}`),
			"--completions-json": []byte(`{"version":1,"completions":[{"label":"double","detail":"Int -> Int","kind":"function"}]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"x = 1"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/hover", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":0,"character":0}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/definition", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":0,"character":0}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/completion", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":0,"character":0}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`5`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	responses := make([]protocol.Response, 0, 4)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
			continue
		}
		var response protocol.Response
		if err := json.Unmarshal(message, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 4 {
		t.Fatalf("response count = %d, want 4", len(responses))
	}
	if !bytes.Contains(responses[0].Result, []byte(`"Int"`)) {
		t.Fatalf("hover result = %s", responses[0].Result)
	}
	if !bytes.Contains(responses[1].Result, []byte(`"uri":"file:///tmp/demo.tesl"`)) {
		t.Fatalf("definition result = %s", responses[1].Result)
	}
	if !bytes.Contains(responses[2].Result, []byte(`"label":"double"`)) {
		t.Fatalf("completion result = %s", responses[2].Result)
	}
	if len(compiler.flags) != 4 || compiler.flags[1] != "--type-at-json" || compiler.flags[2] != "--definition-json" || compiler.flags[3] != "--completions-json" {
		t.Fatalf("compiler flags = %#v", compiler.flags)
	}
}

func TestServerAnswersSignatureTypeDefinitionAndReferences(t *testing.T) {
	compiler := &fakeCompiler{
		payload: []byte(`{"version":1,"diagnostics":[]}`),
		responses: map[string][]byte{
			"--signature-help-json":  []byte(`{"version":1,"signature":{"label":"add a: Int b: Int","parameters":[{"label":"a","type":"Int"},{"label":"b","type":"Int"}],"active_parameter":1}}`),
			"--type-definition-json": []byte(`{"version":1,"type_definition":{"file":"/tmp/demo.tesl","line":0,"col":0,"end_line":0,"end_col":1}}`),
			"--occurrences-json":     []byte(`{"version":1,"occurrences":[{"file":"/tmp/demo.tesl","line":0,"col":0,"end_line":0,"end_col":1,"kind":"write"}]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"x = 1"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/signatureHelp", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":0,"character":0}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/typeDefinition", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":0,"character":0}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/references", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":0,"character":0},"context":{"includeDeclaration":true}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`5`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	responses := make([]protocol.Response, 0, 4)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
			continue
		}
		var response protocol.Response
		if err := json.Unmarshal(message, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 4 {
		t.Fatalf("response count = %d, want 4", len(responses))
	}
	if !bytes.Contains(responses[0].Result, []byte(`"activeParameter":1`)) {
		t.Fatalf("signature result = %s", responses[0].Result)
	}
	if !bytes.Contains(responses[1].Result, []byte(`"range"`)) {
		t.Fatalf("type definition result = %s", responses[1].Result)
	}
	if !bytes.Contains(responses[2].Result, []byte(`"uri":"file:///tmp/demo.tesl"`)) {
		t.Fatalf("references result = %s", responses[2].Result)
	}
	if len(compiler.flags) != 4 || compiler.flags[1] != "--signature-help-json" || compiler.flags[2] != "--type-definition-json" || compiler.flags[3] != "--occurrences-json" {
		t.Fatalf("compiler flags = %#v", compiler.flags)
	}
}

func TestServerFormatsTheWholeDocument(t *testing.T) {
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[]}`)}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"x=1"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/formatting", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"options":{"tabSize":2,"insertSpaces":true}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	if _, err := reader.Read(); err != nil {
		t.Fatal(err)
	}
	message, err := reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	var response protocol.Response
	if err := json.Unmarshal(message, &response); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(response.Result, []byte(`"newText":"formatted"`)) || !bytes.Contains(response.Result, []byte(`"start":{"line":0,"character":0}`)) {
		t.Fatalf("formatting result = %s", response.Result)
	}
}

func TestServerAnswersHighlightsSelectionRangesAndInlayHints(t *testing.T) {
	compiler := &fakeCompiler{
		payload: []byte(`{"version":1,"diagnostics":[]}`),
		responses: map[string][]byte{
			"--occurrences-json":     []byte(`{"version":1,"occurrences":[{"file":"/tmp/demo.tesl","line":0,"col":4,"end_line":0,"end_col":9,"kind":"write"}]}`),
			"--selection-range-json": []byte(`{"version":1,"ranges":[{"line":0,"col":4,"end_line":0,"end_col":9},{"line":0,"col":0,"end_line":0,"end_col":13}]}`),
			"--local-bindings-json":  []byte(`{"version":1,"bindings":[{"file":"/tmp/demo.tesl","line":0,"col":4,"end_line":0,"end_col":9,"name":"value","type":"Int"}]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"let value = 1"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/documentHighlight", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":0,"character":5}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/selectionRange", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"positions":[{"line":0,"character":5}]}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/inlayHint", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":13}}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`5`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	responses := make([]protocol.Response, 0, 4)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
			continue
		}
		var response protocol.Response
		if err := json.Unmarshal(message, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 4 {
		t.Fatalf("response count = %d, want 4", len(responses))
	}
	if !bytes.Contains(responses[0].Result, []byte(`"kind":3`)) {
		t.Fatalf("highlight result = %s", responses[0].Result)
	}
	if !bytes.Contains(responses[1].Result, []byte(`"parent"`)) {
		t.Fatalf("selection result = %s", responses[1].Result)
	}
	if !bytes.Contains(responses[2].Result, []byte(`"label":": Int"`)) || !bytes.Contains(responses[2].Result, []byte(`"character":9`)) {
		t.Fatalf("inlay result = %s", responses[2].Result)
	}
}

func TestServerAnswersFoldingSymbolsAndSemanticTokens(t *testing.T) {
	compiler := &fakeCompiler{
		payload: []byte(`{"version":1,"diagnostics":[]}`),
		responses: map[string][]byte{
			"--semantic-json": []byte(`{"version":1,"functions":[{"name":"foo","kind":"fn","loc":{"file":"/tmp/demo.tesl","start_line":0,"start_col":0,"end_line":3,"end_col":1}}],"records":[],"adts":[],"local_bindings":[{"name":"value","loc":{"file":"/tmp/demo.tesl","start_line":1,"start_col":0,"end_line":1,"end_col":9}}]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"fn foo() {\n# one\n# two\n}\n"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/foldingRange", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/documentSymbol", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/semanticTokens/full", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`5`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	responses := make([]protocol.Response, 0, 4)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
			continue
		}
		var response protocol.Response
		if err := json.Unmarshal(message, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 4 {
		t.Fatalf("response count = %d, want 4", len(responses))
	}
	if !bytes.Contains(responses[0].Result, []byte(`"startLine":0`)) || !bytes.Contains(responses[0].Result, []byte(`"kind":"comment"`)) {
		t.Fatalf("folding result = %s", responses[0].Result)
	}
	if !bytes.Contains(responses[1].Result, []byte(`"name":"foo"`)) || !bytes.Contains(responses[1].Result, []byte(`"kind":12`)) {
		t.Fatalf("symbol result = %s", responses[1].Result)
	}
	if !bytes.Contains(responses[2].Result, []byte(`"data":[0,3,3,0,1`)) {
		t.Fatalf("semantic token result = %s", responses[2].Result)
	}
}

func TestServerPreparesAndAppliesRenameAndDeclaration(t *testing.T) {
	compiler := &fakeCompiler{
		payload: []byte(`{"version":1,"diagnostics":[]}`),
		responses: map[string][]byte{
			"--occurrences-json": []byte(`{"version":1,"occurrences":[{"file":"/tmp/demo.tesl","line":0,"col":4,"end_line":0,"end_col":9,"kind":"write"},{"file":"/tmp/demo.tesl","line":1,"col":0,"end_line":1,"end_col":5,"kind":"read"}]}`),
			"--definition-json":  []byte(`{"version":1,"definition":{"file":"/tmp/demo.tesl","line":0,"col":4,"end_line":0,"end_col":9}}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"let value\nvalue"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/prepareRename", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":0,"character":5}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/rename", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":1,"character":2},"newName":"renamed"}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/declaration", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":1,"character":2}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`5`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	responses := make([]protocol.Response, 0, 4)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
			continue
		}
		var response protocol.Response
		if err := json.Unmarshal(message, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 4 {
		t.Fatalf("response count = %d, want 4", len(responses))
	}
	if !bytes.Contains(responses[0].Result, []byte(`"start":{"line":0,"character":4}`)) {
		t.Fatalf("prepare rename result = %s", responses[0].Result)
	}
	if !bytes.Contains(responses[1].Result, []byte(`"newText":"renamed"`)) || !bytes.Contains(responses[1].Result, []byte(`"file:///tmp/demo.tesl"`)) {
		t.Fatalf("rename result = %s", responses[1].Result)
	}
	if !bytes.Contains(responses[2].Result, []byte(`"range"`)) {
		t.Fatalf("declaration result = %s", responses[2].Result)
	}
}

func TestServerSemanticTokenDeltaAndRange(t *testing.T) {
	compiler := &fakeCompiler{
		payload: []byte(`{"version":1,"diagnostics":[]}`),
		responses: map[string][]byte{
			"--semantic-json": []byte(`{"version":1,"functions":[{"name":"foo","kind":"fn","loc":{"file":"/tmp/demo.tesl","start_line":0,"start_col":0,"end_line":0,"end_col":7}}],"records":[],"adts":[],"local_bindings":[]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"fn foo()"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/semanticTokens/full", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/semanticTokens/full/delta", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"previousResultId":"1"}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/semanticTokens/range", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`5`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	responses := make([]protocol.Response, 0, 4)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
			continue
		}
		var response protocol.Response
		if err := json.Unmarshal(message, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 4 {
		t.Fatalf("response count = %d, want 4", len(responses))
	}
	if !bytes.Contains(responses[0].Result, []byte(`"resultId":"1"`)) || !bytes.Contains(responses[0].Result, []byte(`"data":[0,3,3,0,1]`)) {
		t.Fatalf("full result = %s", responses[0].Result)
	}
	if !bytes.Contains(responses[1].Result, []byte(`"edits":[]`)) {
		t.Fatalf("delta result = %s", responses[1].Result)
	}
	if !bytes.Contains(responses[2].Result, []byte(`"data":[0,3,3,0,1]`)) {
		t.Fatalf("range result = %s", responses[2].Result)
	}
}

func TestServerReturnsCodeActionsAndResolvesCompletionItems(t *testing.T) {
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[]}`)}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"bad\n"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/codeAction", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"context":{"diagnostics":[{"code":"E1","message":"fix me","data":{"fix":{"kind":"replace_line","line":0,"replacement":"good","title":"Use good"}}}]}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "completionItem/resolve", Params: json.RawMessage(`{"label":"double","detail":"Int -> Int"}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	responses := make([]protocol.Response, 0, 3)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
			continue
		}
		var response protocol.Response
		if err := json.Unmarshal(message, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 3 {
		t.Fatalf("response count = %d, want 3", len(responses))
	}
	if !bytes.Contains(responses[0].Result, []byte(`"title":"Use good"`)) || !bytes.Contains(responses[0].Result, []byte(`"newText":"good"`)) {
		t.Fatalf("code action result = %s", responses[0].Result)
	}
	if !bytes.Contains(responses[1].Result, []byte(`"label":"double"`)) {
		t.Fatalf("resolve result = %s", responses[1].Result)
	}
}

func TestServerHoverFallsBackToRecordFieldQuery(t *testing.T) {
	compiler := &fakeCompiler{responses: map[string][]byte{
		"--type-at-json":  []byte(`{"version":1,"type_at":null}`),
		"--field-at-json": []byte(`{"version":1,"field_at":{"field":"x","field_type":"Int"}}`),
	}}
	server := NewServer(compiler)
	server.documents["file:///tmp/demo.tesl"] = document{
		URI: "file:///tmp/demo.tesl", Path: "/tmp/demo.tesl", Text: "p.x\n", Version: 1,
	}
	var output bytes.Buffer
	_, err := server.handle(context.Background(), protocol.Request{
		JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "textDocument/hover",
		Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":0,"character":2}}`),
	}, protocol.NewWriter(&output))
	if err != nil {
		t.Fatal(err)
	}
	message, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	var response protocol.Response
	if err := json.Unmarshal(message, &response); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(response.Result, []byte(`"value":"x: Int"`)) {
		t.Fatalf("hover = %s", response.Result)
	}
}

func TestServerCompletionResolveLoadsCompilerDocumentation(t *testing.T) {
	compiler := &fakeCompiler{responses: map[string][]byte{
		"--doc-json": []byte(`{"version":1,"entries":[{"name":"Int","doc":"arbitrary precision integer"}]}`),
	}}
	server := NewServer(compiler)
	var output bytes.Buffer
	_, err := server.handle(context.Background(), protocol.Request{
		JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "completionItem/resolve",
		Params: json.RawMessage(`{"label":"Int"}`),
	}, protocol.NewWriter(&output))
	if err != nil {
		t.Fatal(err)
	}
	message, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	var response protocol.Response
	if err := json.Unmarshal(message, &response); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(response.Result, []byte(`arbitrary precision integer`)) {
		t.Fatalf("resolved completion = %s", response.Result)
	}
}

func TestServerReturnsDocumentLinksAndLinkedEditingRanges(t *testing.T) {
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[]}`)}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"fn demo() {\n  # see https://example.com/docs\n  let value = value\n}\n"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/documentLink", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/linkedEditingRange", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"position":{"line":2,"character":7}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	responses := make([]protocol.Response, 0, 3)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
			continue
		}
		var response protocol.Response
		if err := json.Unmarshal(message, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 3 {
		t.Fatalf("response count = %d, want 3", len(responses))
	}
	if !bytes.Contains(responses[0].Result, []byte(`"target":"https://example.com/docs"`)) {
		t.Fatalf("link result = %s", responses[0].Result)
	}
	if !bytes.Contains(responses[1].Result, []byte(`"ranges"`)) || !bytes.Contains(responses[1].Result, []byte(`"character":6`)) {
		t.Fatalf("linked editing result = %s", responses[1].Result)
	}
}

func TestServerPullDiagnosticsReturnsUnchangedReport(t *testing.T) {
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[{"file":"/tmp/demo.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"warning","code":"W1","message":"warn","source":"lint"}]}`)}
	previous := contentResultID("x")
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1,"text":"x"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/diagnostic", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/diagnostic", Params: json.RawMessage(fmt.Sprintf(`{"textDocument":{"uri":"file:///tmp/demo.tesl"},"previousResultId":%q}`, previous))},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "shutdown", Params: json.RawMessage(`null`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 0 {
		t.Fatalf("Run() status = %d", status)
	}
	reader := protocol.NewReader(&output)
	responses := make([]protocol.Response, 0, 3)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
			continue
		}
		var response protocol.Response
		if err := json.Unmarshal(message, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 3 {
		t.Fatalf("response count = %d, want 3", len(responses))
	}
	if !bytes.Contains(responses[0].Result, []byte(`"kind":"full"`)) || !bytes.Contains(responses[0].Result, []byte(`"code":"W1"`)) {
		t.Fatalf("pull result = %s", responses[0].Result)
	}
	var first struct {
		ResultID string `json:"resultId"`
	}
	if err := json.Unmarshal(responses[0].Result, &first); err != nil || first.ResultID == "" {
		t.Fatalf("pull result id = %s", responses[0].Result)
	}
	if !bytes.Contains(responses[1].Result, []byte(`"kind":"unchanged"`)) || !bytes.Contains(responses[1].Result, []byte(previous)) {
		t.Fatalf("unchanged result = %s", responses[1].Result)
	}
}

func TestServerRejectsStaleChangesAndUsesUTF16Ranges(t *testing.T) {
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[{"file":"/tmp/demo.tesl","start":{"line":0,"col":4},"end":{"line":0,"col":8},"severity":"error","code":"T001","message":"bad","source":"type-checker"}]}`)}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":2,"text":"😀 = 1"}}`)},
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didChange", Params: json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":1},"contentChanges":[{"text":"stale"}]}`)},
		protocol.Request{JSONRPC: "2.0", Method: "exit"},
	)
	var output bytes.Buffer
	if status := NewServer(compiler).Run(context.Background(), bytes.NewReader(input), &output); status != 1 {
		t.Fatalf("Run() status = %d, want 1 for exit before shutdown", status)
	}
	reader := protocol.NewReader(&output)
	message, err := reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	var notification protocol.Request
	if err := json.Unmarshal(message, &notification); err != nil {
		t.Fatal(err)
	}
	var params struct {
		Diagnostics []struct {
			Range protocol.Range `json:"range"`
		} `json:"diagnostics"`
	}
	if err := json.Unmarshal(notification.Params, &params); err != nil {
		t.Fatal(err)
	}
	if got := params.Diagnostics[0].Range.Start.Character; got != 2 {
		t.Fatalf("UTF-16 start character = %d, want 2", got)
	}
}

func TestServerCancelsStaleDiagnosticQueries(t *testing.T) {
	compiler := &cancellableCompiler{started: make(chan struct{}), canceled: make(chan struct{})}
	server := NewServer(compiler)
	server.documents["file:///tmp/demo.tesl"] = document{URI: "file:///tmp/demo.tesl", Path: "/tmp/demo.tesl", Version: 1, Text: "initial"}
	var output bytes.Buffer
	writer := protocol.NewWriter(&output)
	if err := server.didChange(context.Background(), json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":2},"contentChanges":[{"text":"old"}]}`), writer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-compiler.started:
	case <-time.After(time.Second):
		t.Fatal("old diagnostic query did not start")
	}
	if err := server.didChange(context.Background(), json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":3},"contentChanges":[{"text":"new"}]}`), writer); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	select {
	case <-compiler.canceled:
	case <-time.After(time.Second):
		t.Fatal("old diagnostic query was not canceled")
	}
	reader := protocol.NewReader(&output)
	message, err := reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	var notification protocol.Request
	if err := json.Unmarshal(message, &notification); err != nil || notification.Method != "textDocument/publishDiagnostics" {
		t.Fatalf("notification = %s", message)
	}
	if _, err := reader.Read(); err != io.EOF {
		t.Fatalf("stale diagnostics emitted: %v", err)
	}
}

func TestServerAppliesUTF16RangedAndMultipleChanges(t *testing.T) {
	server := NewServer(&fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[]}`)})
	server.documents["file:///tmp/demo.tesl"] = document{
		URI: "file:///tmp/demo.tesl", Path: "/tmp/demo.tesl", Version: 1, Text: "a😀c\ndef",
	}
	var output bytes.Buffer
	if err := server.didChange(context.Background(), json.RawMessage(`{"textDocument":{"uri":"file:///tmp/demo.tesl","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":3}},"text":"X"},{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"text":"DEF"}]}`), protocol.NewWriter(&output)); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	if got := server.documents["file:///tmp/demo.tesl"].Text; got != "aXc\nDEF" {
		t.Fatalf("document text = %q", got)
	}
}

func frames(t *testing.T, requests ...protocol.Request) []byte {
	t.Helper()
	var output bytes.Buffer
	writer := protocol.NewWriter(&output)
	for _, request := range requests {
		if err := writer.WriteJSON(request); err != nil {
			t.Fatal(err)
		}
	}
	return output.Bytes()
}
