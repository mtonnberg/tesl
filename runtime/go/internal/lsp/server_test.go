package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
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

type dependencyCompiler struct {
	mutex          sync.Mutex
	dependencyPath string
	mainPath       string
	broken         bool
	queries        map[string]int
}

func (compiler *dependencyCompiler) QuerySourceJSON(_ context.Context, flag, path, _ string, _ ...string) ([]byte, tooling.Result, error) {
	compiler.mutex.Lock()
	compiler.queries[path]++
	broken := compiler.broken
	compiler.mutex.Unlock()
	if flag == "--check-json" && path == compiler.mainPath && broken {
		payload, err := json.Marshal(map[string]any{
			"version": 1,
			"diagnostics": []map[string]any{{
				"file": compiler.dependencyPath, "start": map[string]int{"line": 0, "col": 0},
				"end": map[string]int{"line": 0, "col": 1}, "severity": "error", "code": "T001",
				"message": "dependency failed", "source": "type-checker", "fix": nil,
			}},
		})
		return payload, tooling.Result{}, err
	}
	return []byte(`{"version":1,"diagnostics":[]}`), tooling.Result{}, nil
}

func (compiler *dependencyCompiler) QueryJSON(context.Context, ...string) (json.RawMessage, tooling.Result, error) {
	return []byte(`{"version":1,"entries":[]}`), tooling.Result{}, nil
}

func (compiler *dependencyCompiler) FormatSource(context.Context, string, string) ([]byte, tooling.Result, error) {
	return nil, tooling.Result{}, nil
}

func (compiler *dependencyCompiler) setBroken(broken bool) {
	compiler.mutex.Lock()
	compiler.broken = broken
	compiler.mutex.Unlock()
}

func (compiler *dependencyCompiler) queryCount(path string) int {
	compiler.mutex.Lock()
	defer compiler.mutex.Unlock()
	return compiler.queries[path]
}

func TestServerInitializesPublishesDiagnosticsAndShutsDown(t *testing.T) {
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[{"file":` + testFilePathJSON("demo.tesl") + `,"start":{"line":0,"col":1},"end":{"line":0,"col":5},"severity":"warning","code":"W001","message":"careful","source":"lint","fix":null}]}`)}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "initialize", Params: json.RawMessage(`{}`)},
		protocol.Request{JSONRPC: "2.0", Method: "initialized"},
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"x = 1"}}`)},
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
			"--type-at-json":     []byte(`{"version":1,"type_at":{"file":` + testFilePathJSON("demo.tesl") + `,"line":0,"col":0,"end_line":0,"end_col":1,"type":"Int"}}`),
			"--definition-json":  []byte(`{"version":1,"definition":{"file":` + testFilePathJSON("demo.tesl") + `,"line":0,"col":0,"end_line":0,"end_col":1}}`),
			"--completions-json": []byte(`{"version":1,"completions":[{"label":"double","detail":"Int -> Int","kind":"function"}]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"x = 1"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/hover", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":0,"character":0}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/definition", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":0,"character":0}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/completion", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":0,"character":0}}`)},
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
	if !bytes.Contains(responses[1].Result, []byte(`"uri":`+testFileURIJSON("demo.tesl"))) {
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
			"--type-definition-json": []byte(`{"version":1,"type_definition":{"file":` + testFilePathJSON("demo.tesl") + `,"line":0,"col":0,"end_line":0,"end_col":1}}`),
			"--occurrences-json":     []byte(`{"version":1,"occurrences":[{"file":` + testFilePathJSON("demo.tesl") + `,"line":0,"col":0,"end_line":0,"end_col":1,"kind":"write"}]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"x = 1"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/signatureHelp", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":0,"character":0}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/typeDefinition", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":0,"character":0}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/references", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":0,"character":0},"context":{"includeDeclaration":true}}`)},
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
	if !bytes.Contains(responses[2].Result, []byte(`"uri":`+testFileURIJSON("demo.tesl"))) {
		t.Fatalf("references result = %s", responses[2].Result)
	}
	if len(compiler.flags) != 4 || compiler.flags[1] != "--signature-help-json" || compiler.flags[2] != "--type-definition-json" || compiler.flags[3] != "--occurrences-json" {
		t.Fatalf("compiler flags = %#v", compiler.flags)
	}
}

func TestServerFormatsTheWholeDocument(t *testing.T) {
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[]}`)}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"x=1"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/formatting", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"options":{"tabSize":2,"insertSpaces":true}}`)},
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
			"--occurrences-json":     []byte(`{"version":1,"occurrences":[{"file":` + testFilePathJSON("demo.tesl") + `,"line":0,"col":4,"end_line":0,"end_col":9,"kind":"write"}]}`),
			"--selection-range-json": []byte(`{"version":1,"ranges":[{"line":0,"col":4,"end_line":0,"end_col":9},{"line":0,"col":0,"end_line":0,"end_col":13}]}`),
			"--local-bindings-json":  []byte(`{"version":1,"bindings":[{"file":` + testFilePathJSON("demo.tesl") + `,"line":0,"col":4,"end_line":0,"end_col":9,"name":"value","type":"Int"}]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"let value = 1"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/documentHighlight", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":0,"character":5}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/selectionRange", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"positions":[{"line":0,"character":5}]}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/inlayHint", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":13}}}`)},
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
			"--semantic-json": []byte(`{"version":1,"functions":[{"name":"foo","kind":"fn","loc":{"file":` + testFilePathJSON("demo.tesl") + `,"start_line":0,"start_col":0,"end_line":3,"end_col":1}}],"records":[],"adts":[],"local_bindings":[{"name":"value","loc":{"file":` + testFilePathJSON("demo.tesl") + `,"start_line":1,"start_col":0,"end_line":1,"end_col":9}}]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"fn foo() {\n# one\n# two\n}\n"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/foldingRange", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/documentSymbol", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/semanticTokens/full", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `}}`)},
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

func TestServerRejectsMalformedNestedSemanticMember(t *testing.T) {
	compiler := &fakeCompiler{responses: map[string][]byte{
		"--semantic-json": []byte(`{"version":1,"records":[],"adts":[],"functions":[{"name":"broken"}],"local_bindings":[]}`),
	}}
	server := NewServer(compiler)
	_, err := server.semanticSnapshot(context.Background(), document{Path: testFilePath("demo.tesl"), Text: "fn broken() = 1"})
	if err == nil || !strings.Contains(err.Error(), "kind") {
		t.Fatalf("malformed semantic member error = %v", err)
	}
}

func TestServerPreparesAndAppliesRenameAndDeclaration(t *testing.T) {
	compiler := &fakeCompiler{
		payload: []byte(`{"version":1,"diagnostics":[]}`),
		responses: map[string][]byte{
			"--occurrences-json": []byte(`{"version":1,"occurrences":[{"file":` + testFilePathJSON("demo.tesl") + `,"line":0,"col":4,"end_line":0,"end_col":9,"kind":"write"},{"file":` + testFilePathJSON("demo.tesl") + `,"line":1,"col":0,"end_line":1,"end_col":5,"kind":"read"}]}`),
			"--definition-json":  []byte(`{"version":1,"definition":{"file":` + testFilePathJSON("demo.tesl") + `,"line":0,"col":4,"end_line":0,"end_col":9}}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"let value\nvalue"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/prepareRename", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":0,"character":5}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/rename", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":1,"character":2},"newName":"renamed"}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/declaration", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":1,"character":2}}`)},
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
	if !bytes.Contains(responses[1].Result, []byte(`"newText":"renamed"`)) || !bytes.Contains(responses[1].Result, []byte(testFileURIJSON("demo.tesl"))) {
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
			"--semantic-json": []byte(`{"version":1,"functions":[{"name":"foo","kind":"fn","loc":{"file":` + testFilePathJSON("demo.tesl") + `,"start_line":0,"start_col":0,"end_line":0,"end_col":7}}],"records":[],"adts":[],"local_bindings":[]}`),
		},
	}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"fn foo()"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/semanticTokens/full", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/semanticTokens/full/delta", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"previousResultId":"1"}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`4`), Method: "textDocument/semanticTokens/range", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}}}`)},
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
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"bad\n"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/codeAction", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"context":{"diagnostics":[{"code":"E1","message":"fix me","data":{"fix":{"kind":"replace_line","line":0,"replacement":"good","title":"Use good"}}}]}}`)},
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

func TestSchemaImportActionKeepsQualifiedEditsTogetherAndUsesUTF16(t *testing.T) {
	uri := testFileURI("migration-app.tesl")
	const source = "import NotesSchema.V7\r\n\t\"å 🌱 ${NotesSchema.V7.describe note}\" # NotesSchema.V7\r\n"
	const title = "Use VCurrent for this schema import and its qualified references"
	server := NewServer(&fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[]}`)})
	server.documents[uri] = document{URI: uri, Path: testFilePath("migration-app.tesl"), Version: 4, Text: source}
	var replacements []map[string]any
	for line, text := range strings.Split(source, "\n") {
		if line == 2 {
			break
		}
		column := strings.Index(text, "V7")
		replacements = append(replacements, map[string]any{
			"kind": "replace_range", "start_line": line, "start_col": column,
			"end_line": line, "end_col": column + 2, "replacement": "VCurrent",
		})
	}
	params, err := json.Marshal(map[string]any{
		"textDocument": map[string]string{"uri": uri},
		"context": map[string]any{"diagnostics": []map[string]any{{
			"code": "MIG015", "message": "Application code uses the current schema",
			"data": map[string]any{"fix": map[string]any{"kind": "multi", "title": title, "edits": replacements}},
		}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := server.writeCodeActions(json.RawMessage(`1`), params, protocol.NewWriter(&output)); err != nil {
		t.Fatal(err)
	}
	message, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	var response struct {
		Result []struct {
			Title string `json:"title"`
			Edit  struct {
				Changes map[string][]struct {
					Range   protocol.Range `json:"range"`
					NewText string         `json:"newText"`
				} `json:"changes"`
			} `json:"edit"`
		} `json:"result"`
	}
	if err := json.Unmarshal(message, &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Result) != 1 || response.Result[0].Title != title || len(response.Result[0].Edit.Changes) != 1 {
		t.Fatalf("schema action split, lost its title or edited another document: %s", message)
	}
	edits := response.Result[0].Edit.Changes[uri]
	if len(edits) != 2 || edits[0].Range.Start.Character != 19 || edits[1].Range.Start.Character != 21 {
		t.Fatalf("byte columns were not converted to UTF-16: %+v", edits)
	}
	index := protocol.NewLineIndex(source)
	actual := source
	for i := len(edits) - 1; i >= 0; i-- {
		start, startErr := index.Offset(edits[i].Range.Start)
		end, endErr := index.Offset(edits[i].Range.End)
		if startErr != nil || endErr != nil {
			t.Fatalf("invalid edit range: %+v, %v, %v", edits[i], startErr, endErr)
		}
		actual = actual[:start] + edits[i].NewText + actual[end:]
	}
	const expected = "import NotesSchema.VCurrent\r\n\t\"å 🌱 ${NotesSchema.VCurrent.describe note}\" # NotesSchema.V7\r\n"
	if actual != expected {
		t.Fatalf("schema action changed surrounding source: %q", actual)
	}
}

func TestServerHoverFallsBackToRecordFieldQuery(t *testing.T) {
	compiler := &fakeCompiler{responses: map[string][]byte{
		"--type-at-json":  []byte(`{"version":1,"type_at":null}`),
		"--field-at-json": []byte(`{"version":1,"field_at":{"file":` + testFilePathJSON("demo.tesl") + `,"line":0,"col":5,"end_line":0,"end_col":7,"field":"x","record_type":"Point","field_type":"Int"}}`),
	}}
	server := NewServer(compiler)
	server.documents[testFileURI("demo.tesl")] = document{
		URI: testFileURI("demo.tesl"), Path: testFilePath("demo.tesl"), Text: "p.x\n", Version: 1,
	}
	var output bytes.Buffer
	_, err := server.handle(context.Background(), protocol.Request{
		JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "textDocument/hover",
		Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":0,"character":2}}`),
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
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"fn demo() {\n  # see https://example.com/docs\n  let value = value\n}\n"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/documentLink", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/linkedEditingRange", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `},"position":{"line":2,"character":7}}`)},
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
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[{"file":` + testFilePathJSON("demo.tesl") + `,"start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"warning","code":"W1","message":"warn","source":"lint","fix":null}]}`)}
	previous := diagnosticResultID("x", map[string][]map[string]any{
		testFileURI("demo.tesl"): {{
			"range":    map[string]protocol.Position{"start": {Line: 0, Character: 0}, "end": {Line: 0, Character: 1}},
			"severity": 2, "code": "W1", "message": "warn", "source": "lint",
		}},
	})
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1,"text":"x"}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`2`), Method: "textDocument/diagnostic", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `}}`)},
		protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`3`), Method: "textDocument/diagnostic", Params: json.RawMessage(fmt.Sprintf(`{"textDocument":{"uri":%s},"previousResultId":%q}`, testFileURIJSON("demo.tesl"), previous))},
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
	compiler := &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[{"file":` + testFilePathJSON("demo.tesl") + `,"start":{"line":0,"col":4},"end":{"line":0,"col":8},"severity":"error","code":"T001","message":"bad","source":"type-checker","fix":null}]}`)}
	input := frames(t,
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":2,"text":"😀 = 1"}}`)},
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didChange", Params: json.RawMessage(`{"textDocument":{"uri":` + testFileURIJSON("demo.tesl") + `,"version":1},"contentChanges":[{"text":"stale"}]}`)},
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
	server.documents[testFileURI("demo.tesl")] = document{URI: testFileURI("demo.tesl"), Path: testFilePath("demo.tesl"), Version: 1, Text: "initial"}
	var output bytes.Buffer
	writer := protocol.NewWriter(&output)
	if err := server.didChange(context.Background(), json.RawMessage(`{"textDocument":{"uri":`+testFileURIJSON("demo.tesl")+`,"version":2},"contentChanges":[{"text":"old"}]}`), writer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-compiler.started:
	case <-time.After(time.Second):
		t.Fatal("old diagnostic query did not start")
	}
	if err := server.didChange(context.Background(), json.RawMessage(`{"textDocument":{"uri":`+testFileURIJSON("demo.tesl")+`,"version":3},"contentChanges":[{"text":"new"}]}`), writer); err != nil {
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
	server.documents[testFileURI("demo.tesl")] = document{
		URI: testFileURI("demo.tesl"), Path: testFilePath("demo.tesl"), Version: 1, Text: "a😀c\ndef",
	}
	var output bytes.Buffer
	if err := server.didChange(context.Background(), json.RawMessage(`{"textDocument":{"uri":`+testFileURIJSON("demo.tesl")+`,"version":2},"contentChanges":[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":3}},"text":"X"},{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"text":"DEF"}]}`), protocol.NewWriter(&output)); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	if got := server.documents[testFileURI("demo.tesl")].Text; got != "aXc\nDEF" {
		t.Fatalf("document text = %q", got)
	}
}

func TestServerPublishesDependencyDiagnosticsAtActualURI(t *testing.T) {
	directory := t.TempDir()
	mainPath := filepath.Join(directory, "main.tesl")
	dependencyPath := filepath.Join(directory, "lib.tesl")
	if err := os.WriteFile(dependencyPath, []byte("😀bad\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	mainURI := protocol.PathToURI(mainPath)
	dependencyURI := protocol.PathToURI(dependencyPath)
	payload, err := json.Marshal(map[string]any{
		"version": 1,
		"diagnostics": []map[string]any{{
			"file": dependencyPath, "start": map[string]int{"line": 0, "col": 4},
			"end": map[string]int{"line": 0, "col": 7}, "severity": "error", "code": "T001",
			"message": "dependency failed", "source": "type-checker", "fix": nil,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(&fakeCompiler{payload: payload})
	server.documents[mainURI] = document{URI: mainURI, Path: mainPath, Version: 1, Text: "module Main\n"}
	var output bytes.Buffer
	if err := server.publishDiagnostics(context.Background(), server.documents[mainURI], protocol.NewWriter(&output)); err != nil {
		t.Fatal(err)
	}
	reader := protocol.NewReader(&output)
	publications := make(map[string][]struct {
		Code  string         `json:"code"`
		Range protocol.Range `json:"range"`
	})
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if err := json.Unmarshal(message, &notification); err != nil {
			t.Fatal(err)
		}
		var params struct {
			URI         string `json:"uri"`
			Diagnostics []struct {
				Code  string         `json:"code"`
				Range protocol.Range `json:"range"`
			} `json:"diagnostics"`
		}
		if err := json.Unmarshal(notification.Params, &params); err != nil {
			t.Fatal(err)
		}
		publications[params.URI] = params.Diagnostics
	}
	if diagnostics, ok := publications[mainURI]; !ok || len(diagnostics) != 0 {
		t.Fatalf("entry diagnostics = %#v, published=%#v", diagnostics, publications)
	}
	dependency := publications[dependencyURI]
	if len(dependency) != 1 || dependency[0].Code != "T001" || dependency[0].Range.Start.Character != 2 {
		t.Fatalf("dependency diagnostics = %#v", dependency)
	}
}

func TestDependencyDiagnosticPublicationAggregatesEntryOwnership(t *testing.T) {
	server := NewServer(&fakeCompiler{})
	dependencyURI := testFileURI("lib.tesl")
	diagnostic := map[string]any{"code": "T001", "message": "bad dependency"}
	groups := map[string][]map[string]any{dependencyURI: {diagnostic}}
	var output bytes.Buffer
	writer := protocol.NewWriter(&output)
	if err := server.publishDiagnosticGroups(testFileURI("main-a.tesl"), groups, writer); err != nil {
		t.Fatal(err)
	}
	if err := server.publishDiagnosticGroups(testFileURI("main-b.tesl"), groups, writer); err != nil {
		t.Fatal(err)
	}
	if err := server.publishDiagnosticGroups(testFileURI("main-a.tesl"), nil, writer); err != nil {
		t.Fatal(err)
	}
	if err := server.publishDiagnosticGroups(testFileURI("main-b.tesl"), nil, writer); err != nil {
		t.Fatal(err)
	}
	reader := protocol.NewReader(&output)
	counts := make([]int, 0, 4)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if err := json.Unmarshal(message, &notification); err != nil {
			t.Fatal(err)
		}
		var params struct {
			URI         string            `json:"uri"`
			Diagnostics []json.RawMessage `json:"diagnostics"`
		}
		if err := json.Unmarshal(notification.Params, &params); err != nil {
			t.Fatal(err)
		}
		if params.URI != dependencyURI {
			t.Fatalf("publication URI = %q", params.URI)
		}
		counts = append(counts, len(params.Diagnostics))
	}
	if got, want := fmt.Sprint(counts), "[1 1 1 0]"; got != want {
		t.Fatalf("diagnostic ownership counts = %s, want %s", got, want)
	}
}

func TestDependencyChangesRecheckImportersAndClearStaleOwnedGroups(t *testing.T) {
	directory := t.TempDir()
	mainPath := filepath.Join(directory, "main.tesl")
	dependencyPath := filepath.Join(directory, "lib.tesl")
	if err := os.WriteFile(dependencyPath, []byte("lib\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	mainURI := protocol.PathToURI(mainPath)
	dependencyURI := protocol.PathToURI(dependencyPath)
	compiler := &dependencyCompiler{
		dependencyPath: dependencyPath, mainPath: mainPath, queries: make(map[string]int),
	}
	server := NewServer(compiler)
	server.documents[mainURI] = document{URI: mainURI, Path: mainPath, Version: 1, Text: "module Main\n"}
	server.documents[dependencyURI] = document{URI: dependencyURI, Path: dependencyPath, Version: 1, Text: "lib\n"}
	var output bytes.Buffer
	writer := protocol.NewWriter(&output)

	compiler.setBroken(true)
	change := fmt.Sprintf(`{"textDocument":{"uri":%q,"version":2},"contentChanges":[{"text":"broken"}]}`, dependencyURI)
	if err := server.didChange(context.Background(), json.RawMessage(change), writer); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	if got := len(server.diagnosticSets[mainURI][dependencyURI]); got != 1 {
		t.Fatalf("importer dependency diagnostics after break = %d", got)
	}
	if compiler.queryCount(mainPath) != 1 || compiler.queryCount(dependencyPath) != 1 {
		t.Fatalf("didChange query counts: main=%d dependency=%d", compiler.queryCount(mainPath), compiler.queryCount(dependencyPath))
	}

	compiler.setBroken(false)
	save := fmt.Sprintf(`{"textDocument":{"uri":%q},"text":"fixed"}`, dependencyURI)
	if err := server.didSave(context.Background(), json.RawMessage(save), writer); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	if _, stale := server.diagnosticSets[mainURI][dependencyURI]; stale {
		t.Fatalf("fixed dependency left stale importer-owned group: %#v", server.diagnosticSets[mainURI])
	}
	if compiler.queryCount(mainPath) != 2 || compiler.queryCount(dependencyPath) != 2 {
		t.Fatalf("didSave query counts: main=%d dependency=%d", compiler.queryCount(mainPath), compiler.queryCount(dependencyPath))
	}

	compiler.setBroken(true)
	watched := fmt.Sprintf(`{"changes":[{"uri":%q,"type":2}]}`, dependencyURI)
	if err := server.didChangeWatchedFiles(context.Background(), json.RawMessage(watched), writer); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	if got := len(server.diagnosticSets[mainURI][dependencyURI]); got != 1 {
		t.Fatalf("importer dependency diagnostics after watched change = %d", got)
	}
	if compiler.queryCount(mainPath) != 3 || compiler.queryCount(dependencyPath) != 3 {
		t.Fatalf("watched-file query counts: main=%d dependency=%d", compiler.queryCount(mainPath), compiler.queryCount(dependencyPath))
	}
}

func TestServerInvalidCompilerSchemaPublishesFailure(t *testing.T) {
	server := NewServer(&fakeCompiler{payload: []byte(`{"version":1}`)})
	doc := document{URI: testFileURI("demo.tesl"), Path: testFilePath("demo.tesl"), Text: "x"}
	var output bytes.Buffer
	if err := server.publishDiagnostics(context.Background(), doc, protocol.NewWriter(&output)); err != nil {
		t.Fatal(err)
	}
	message, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(message, []byte(`"code":"TESL-COMPILER"`)) || !bytes.Contains(message, []byte(`missing required field`)) {
		t.Fatalf("compiler schema failure = %s", message)
	}
}

func TestServerMalformedNestedFixPublishesCompilerFailure(t *testing.T) {
	payload := []byte(`{"version":1,"diagnostics":[{"file":` + testFilePathJSON("demo.tesl") + `,"start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":{"kind":"multi","title":"Fix all","edits":[{"kind":"replace_line","line":0}]},"source":"parser"}]}`)
	server := NewServer(&fakeCompiler{payload: payload})
	doc := document{URI: testFileURI("demo.tesl"), Path: testFilePath("demo.tesl"), Text: "x"}
	var output bytes.Buffer
	if err := server.publishDiagnostics(context.Background(), doc, protocol.NewWriter(&output)); err != nil {
		t.Fatal(err)
	}
	message, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(message, []byte(`"code":"TESL-COMPILER"`)) || bytes.Contains(message, []byte(`"data"`)) {
		t.Fatalf("malformed fix publication = %s", message)
	}
}

func TestDidCloseCannotBeOvertakenByDiagnosticPublication(t *testing.T) {
	uri := testFileURI("close-race.tesl")
	payload := []byte(`{"version":1,"diagnostics":[{"file":` + testFilePathJSON("close-race.tesl") + `,"start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":null,"source":"parser"}]}`)
	server := NewServer(&fakeCompiler{payload: payload})
	doc := document{URI: uri, Path: testFilePath("close-race.tesl"), Version: 1, Text: "x"}
	server.documents[uri] = doc
	ready := make(chan struct{})
	release := make(chan struct{})
	server.beforeDiagnosticPublish = func() {
		close(ready)
		<-release
	}
	var output bytes.Buffer
	writer := protocol.NewWriter(&output)
	server.scheduleDiagnostics(context.Background(), doc, writer)
	select {
	case <-ready:
	case <-time.After(time.Second):
		t.Fatal("diagnostic worker did not reach publication boundary")
	}
	closed := make(chan error, 1)
	go func() {
		closed <- server.didClose(context.Background(), json.RawMessage(`{"textDocument":{"uri":`+testFileURIJSON("close-race.tesl")+`}}`), writer)
	}()
	select {
	case err := <-closed:
		t.Fatalf("didClose bypassed in-flight publication lock: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	if err := <-closed; err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()

	reader := protocol.NewReader(&output)
	counts := make([]int, 0, 2)
	for {
		message, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var notification protocol.Request
		if err := json.Unmarshal(message, &notification); err != nil {
			t.Fatal(err)
		}
		var params struct {
			Diagnostics []json.RawMessage `json:"diagnostics"`
		}
		if err := json.Unmarshal(notification.Params, &params); err != nil {
			t.Fatal(err)
		}
		counts = append(counts, len(params.Diagnostics))
	}
	if got := fmt.Sprint(counts); got != "[1 0]" {
		t.Fatalf("diagnostic publication counts = %s, want [1 0]", got)
	}
}

func TestBuiltCompilerUsesUnsavedDependencyOverlays(t *testing.T) {
	_, testFile, _, _ := runtime.Caller(0)
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(testFile), "../../../.."))
	compilerPath := filepath.Join(repoRoot, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compilerPath); err != nil {
		t.Skip("compiler build unavailable")
	}
	project := t.TempDir()
	mainPath := filepath.Join(project, "A.tesl")
	dependencyPath := filepath.Join(project, "B.tesl")
	mainSource := "module A exposing [use]\nimport Tesl.Prelude exposing [Int]\nimport B exposing [value]\nfn use() -> Int = value()\n"
	validDependency := "module B exposing [value]\nimport Tesl.Prelude exposing [Int]\nfn value() -> Int = 1\n"
	brokenDependency := "module B exposing [value]\nimport Tesl.Prelude exposing [String]\nfn value() -> String = \"bad\"\n"
	if err := os.WriteFile(mainPath, []byte(mainSource), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dependencyPath, []byte(validDependency), 0o600); err != nil {
		t.Fatal(err)
	}
	mainURI := protocol.PathToURI(mainPath)
	dependencyURI := protocol.PathToURI(dependencyPath)
	client := tooling.Client{Executable: compilerPath, Environment: append(os.Environ(), "TESL_REPO_ROOT="+repoRoot)}
	server := NewServer(client)
	server.documents[mainURI] = document{URI: mainURI, Path: mainPath, Version: 1, Text: mainSource}
	server.documents[dependencyURI] = document{URI: dependencyURI, Path: dependencyPath, Version: 1, Text: validDependency}
	var output bytes.Buffer
	writer := protocol.NewWriter(&output)

	breakChange := fmt.Sprintf(`{"textDocument":{"uri":%q,"version":2},"contentChanges":[{"text":%q}]}`, dependencyURI, brokenDependency)
	if err := server.didChange(context.Background(), json.RawMessage(breakChange), writer); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	brokenCount := 0
	for _, diagnostics := range server.diagnosticSets[mainURI] {
		brokenCount += len(diagnostics)
	}
	if brokenCount == 0 {
		t.Fatalf("unsaved dependency break did not update importer diagnostics: %#v", server.diagnosticSets[mainURI])
	}

	fixChange := fmt.Sprintf(`{"textDocument":{"uri":%q,"version":3},"contentChanges":[{"text":%q}]}`, dependencyURI, validDependency)
	if err := server.didChange(context.Background(), json.RawMessage(fixChange), writer); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	for uri, diagnostics := range server.diagnosticSets[mainURI] {
		if len(diagnostics) != 0 {
			t.Fatalf("fixed unsaved dependency left importer diagnostics for %s: %#v", uri, diagnostics)
		}
	}
}

func TestBuiltCompilerOpenAndCloseDependencyRechecksImporter(t *testing.T) {
	_, testFile, _, _ := runtime.Caller(0)
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(testFile), "../../../.."))
	compilerPath := filepath.Join(repoRoot, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compilerPath); err != nil {
		t.Skip("compiler build unavailable")
	}
	project := t.TempDir()
	mainPath := filepath.Join(project, "A.tesl")
	dependencyPath := filepath.Join(project, "B.tesl")
	mainSource := "module A exposing [use]\nimport Tesl.Prelude exposing [Int]\nimport B exposing [value]\nfn use() -> Int = value()\n"
	diskDependency := "module B exposing [value]\nimport Tesl.Prelude exposing [String]\nfn value() -> String = \"bad\"\n"
	openDependency := "module B exposing [value]\nimport Tesl.Prelude exposing [Int]\nfn value() -> Int = 1\n"
	if err := os.WriteFile(mainPath, []byte(mainSource), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dependencyPath, []byte(diskDependency), 0o600); err != nil {
		t.Fatal(err)
	}
	mainURI := protocol.PathToURI(mainPath)
	dependencyURI := protocol.PathToURI(dependencyPath)
	client := tooling.Client{Executable: compilerPath, Environment: append(os.Environ(), "TESL_REPO_ROOT="+repoRoot)}
	server := NewServer(client)
	var output bytes.Buffer
	writer := protocol.NewWriter(&output)
	ownedCount := func() int {
		count := 0
		for _, diagnostics := range server.diagnosticSets[mainURI] {
			count += len(diagnostics)
		}
		return count
	}

	openMain := fmt.Sprintf(`{"textDocument":{"uri":%q,"version":1,"text":%q}}`, mainURI, mainSource)
	if err := server.didOpen(context.Background(), json.RawMessage(openMain), writer); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	if count := ownedCount(); count == 0 {
		t.Fatalf("disk dependency did not produce importer diagnostics: %#v", server.diagnosticSets[mainURI])
	}

	openDependencyParams := fmt.Sprintf(`{"textDocument":{"uri":%q,"version":1,"text":%q}}`, dependencyURI, openDependency)
	if err := server.didOpen(context.Background(), json.RawMessage(openDependencyParams), writer); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	if count := ownedCount(); count != 0 {
		t.Fatalf("opening fixed unsaved dependency left %d importer diagnostics: %#v", count, server.diagnosticSets[mainURI])
	}

	closeDependency := fmt.Sprintf(`{"textDocument":{"uri":%q}}`, dependencyURI)
	if err := server.didClose(context.Background(), json.RawMessage(closeDependency), writer); err != nil {
		t.Fatal(err)
	}
	server.waitDiagnostics()
	if count := ownedCount(); count == 0 {
		t.Fatalf("closing dependency did not restore importer diagnostics from disk: %#v", server.diagnosticSets[mainURI])
	}
}

func TestInitializeCapabilitiesMatchImplementedLSP317Handlers(t *testing.T) {
	result := initializeResult()
	capabilities := result["capabilities"].(map[string]any)
	for _, name := range []string{
		"declarationProvider", "typeDefinitionProvider", "documentLinkProvider",
		"linkedEditingRangeProvider", "diagnosticProvider",
	} {
		if capabilities[name] == nil {
			t.Fatalf("missing capability %s", name)
		}
	}
	documentLinks, ok := capabilities["documentLinkProvider"].(map[string]any)
	if !ok || documentLinks["resolveProvider"] != false {
		t.Fatalf("document link capability = %#v", capabilities["documentLinkProvider"])
	}
	for _, name := range []string{"documentRangeFormattingProvider", "documentOnTypeFormattingProvider", "executeCommandProvider"} {
		if _, advertised := capabilities[name]; advertised {
			t.Fatalf("unsupported capability %s is advertised", name)
		}
	}
	codeActions := capabilities["codeActionProvider"].(map[string]any)["codeActionKinds"].([]string)
	if len(codeActions) != 1 || codeActions[0] != "quickfix" {
		t.Fatalf("code action kinds = %#v", codeActions)
	}
	semantic := capabilities["semanticTokensProvider"].(map[string]any)
	full, ok := semantic["full"].(map[string]any)
	if !ok || full["delta"] != true || semantic["range"] != true {
		t.Fatalf("semantic token capability = %#v", semantic)
	}
	if capabilities["inlayHintProvider"] != true {
		t.Fatalf("inlay hint capability = %#v", capabilities["inlayHintProvider"])
	}
}

func TestServerTerminatesAfterMalformedFrameWithUnreadBody(t *testing.T) {
	input := strings.NewReader("Content-Length: nope\r\n\r\n{}Content-Length: 2\r\n\r\n{}")
	var output bytes.Buffer
	if status := NewServer(&fakeCompiler{}).Run(context.Background(), input, &output); status != 1 {
		t.Fatalf("Run() status = %d, want 1", status)
	}
	reader := protocol.NewReader(&output)
	if _, err := reader.Read(); err != nil {
		t.Fatalf("missing framing error response: %v", err)
	}
	if _, err := reader.Read(); err != io.EOF {
		t.Fatalf("server continued after malformed framing: %v", err)
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
