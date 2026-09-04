// Package lsp contains the first Go-backed Tesl language-server slice.
package lsp

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

const (
	parseError     = -32700
	invalidRequest = -32600
	methodNotFound = -32601
	internalError  = -32603
)

type Compiler interface {
	QuerySourceJSON(context.Context, string, string, string, ...string) ([]byte, tooling.Result, error)
	QueryJSON(context.Context, ...string) (json.RawMessage, tooling.Result, error)
	FormatSource(context.Context, string, string) ([]byte, tooling.Result, error)
}

type overlayCompiler interface {
	QuerySourcesJSON(context.Context, string, string, []tooling.SourceOverlay, ...string) ([]byte, tooling.Result, error)
}

type document struct {
	URI     string
	Path    string
	Version int
	Text    string
}

type Server struct {
	compiler          Compiler
	documents         map[string]document
	semanticTokens    map[string]semanticTokenState
	nextTokenID       uint64
	shutdown          bool
	diagnosticMu      sync.Mutex
	diagnosticRuns    map[string]diagnosticRun
	diagnosticWG      sync.WaitGroup
	diagnosticSets    map[string]map[string][]map[string]any
	nextDiagnostic    uint64
	diagnosticLocksMu sync.Mutex
	diagnosticLocks   map[string]*sync.Mutex
	// beforeDiagnosticPublish is used by race tests to pause between a query and
	// its lifecycle check. Production servers leave it nil.
	beforeDiagnosticPublish func()
}

type diagnosticRun struct {
	cancel context.CancelFunc
	id     uint64
}

func NewServer(compiler Compiler) *Server {
	return &Server{
		compiler: compiler, documents: make(map[string]document), semanticTokens: make(map[string]semanticTokenState),
		diagnosticRuns: make(map[string]diagnosticRun), diagnosticSets: make(map[string]map[string][]map[string]any),
		diagnosticLocks: make(map[string]*sync.Mutex),
	}
}

func (server *Server) sourceOverlays() []tooling.SourceOverlay {
	paths := make([]string, 0, len(server.documents))
	byPath := make(map[string]string, len(server.documents))
	for _, doc := range server.documents {
		if strings.EqualFold(filepath.Ext(doc.Path), ".tesl") {
			paths = append(paths, doc.Path)
			byPath[doc.Path] = doc.Text
		}
	}
	sort.Strings(paths)
	overlays := make([]tooling.SourceOverlay, 0, len(paths))
	for _, path := range paths {
		overlays = append(overlays, tooling.SourceOverlay{Path: path, Source: byPath[path]})
	}
	return overlays
}

func (server *Server) querySourceJSON(ctx context.Context, flag string, doc document, overlays []tooling.SourceOverlay, position ...string) ([]byte, tooling.Result, error) {
	if compiler, ok := server.compiler.(overlayCompiler); ok {
		return compiler.QuerySourcesJSON(ctx, flag, doc.Path, overlays, position...)
	}
	return server.compiler.QuerySourceJSON(ctx, flag, doc.Path, doc.Text, position...)
}

func (server *Server) diagnosticLock(uri string) *sync.Mutex {
	server.diagnosticLocksMu.Lock()
	defer server.diagnosticLocksMu.Unlock()
	lock := server.diagnosticLocks[uri]
	if lock == nil {
		lock = &sync.Mutex{}
		server.diagnosticLocks[uri] = lock
	}
	return lock
}

// Run serves one LSP session. It returns the process exit status required by
// the LSP protocol: exit before shutdown is a failure.
func (server *Server) Run(ctx context.Context, input io.Reader, output io.Writer) int {
	reader := protocol.NewReader(input)
	writer := protocol.NewWriter(output)
	for {
		message, err := reader.Read()
		if errors.Is(err, io.EOF) {
			return 0
		}
		if err != nil {
			if writeErr := server.writeError(writer, nil, parseError, err.Error()); writeErr != nil {
				return 1
			}
			// A framing error can leave an unread body in the stream. Continuing
			// could interpret body bytes as a new header, so terminate safely.
			return 1
		}
		request, err := protocol.DecodeRequest(message)
		if err != nil {
			if writeErr := server.writeError(writer, nil, invalidRequest, err.Error()); writeErr != nil {
				return 1
			}
			continue
		}
		isNotification := len(request.ID) == 0
		status, err := server.handle(ctx, request, writer)
		if err != nil {
			if isNotification {
				continue
			}
			code := internalError
			var protocolErr *requestError
			if errors.As(err, &protocolErr) {
				code = protocolErr.code
			}
			if writeErr := server.writeError(writer, request.ID, code, err.Error()); writeErr != nil {
				return 1
			}
		}
		if status >= 0 {
			return status
		}
	}
}

func (server *Server) handle(ctx context.Context, request protocol.Request, writer *protocol.Writer) (int, error) {
	switch request.Method {
	case "initialize":
		return -1, server.writeResult(writer, request.ID, initializeResult())
	case "initialized":
		return -1, nil
	case "shutdown":
		server.waitDiagnostics()
		server.shutdown = true
		return -1, server.writeResult(writer, request.ID, nil)
	case "exit":
		if server.shutdown {
			return 0, nil
		}
		return 1, nil
	case "textDocument/didOpen":
		return -1, server.didOpen(ctx, request.Params, writer)
	case "textDocument/didChange":
		return -1, server.didChange(ctx, request.Params, writer)
	case "textDocument/didSave":
		return -1, server.didSave(ctx, request.Params, writer)
	case "textDocument/didClose":
		return -1, server.didClose(request.Params, writer)
	case "textDocument/hover":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeHover(ctx, request.ID, request.Params, writer)
	case "textDocument/definition":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeDefinition(ctx, request.ID, request.Params, writer)
	case "textDocument/declaration":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeDefinition(ctx, request.ID, request.Params, writer)
	case "textDocument/completion":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeCompletion(ctx, request.ID, request.Params, writer)
	case "completionItem/resolve":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeCompletionDocumentation(ctx, request.ID, request.Params, writer)
	case "textDocument/signatureHelp":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeSignatureHelp(ctx, request.ID, request.Params, writer)
	case "textDocument/typeDefinition":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeTypeDefinition(ctx, request.ID, request.Params, writer)
	case "textDocument/references":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeReferences(ctx, request.ID, request.Params, writer)
	case "textDocument/prepareRename":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writePrepareRename(ctx, request.ID, request.Params, writer)
	case "textDocument/rename":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeRename(ctx, request.ID, request.Params, writer)
	case "textDocument/codeAction":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeCodeActions(request.ID, request.Params, writer)
	case "textDocument/documentLink":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeDocumentLinks(request.ID, request.Params, writer)
	case "textDocument/linkedEditingRange":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeLinkedEditing(ctx, request.ID, request.Params, writer)
	case "textDocument/diagnostic":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writePullDiagnostics(ctx, request.ID, request.Params, writer)
	case "textDocument/formatting":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeFormatting(ctx, request.ID, request.Params, writer)
	case "textDocument/documentHighlight":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeDocumentHighlight(ctx, request.ID, request.Params, writer)
	case "textDocument/selectionRange":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeSelectionRanges(ctx, request.ID, request.Params, writer)
	case "textDocument/inlayHint":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeInlayHints(ctx, request.ID, request.Params, writer)
	case "textDocument/foldingRange":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeFoldingRanges(request.ID, request.Params, writer)
	case "textDocument/documentSymbol":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeDocumentSymbols(ctx, request.ID, request.Params, writer)
	case "textDocument/semanticTokens/full":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeSemanticTokens(ctx, request.ID, request.Params, writer)
	case "textDocument/semanticTokens/full/delta":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeSemanticTokensDelta(ctx, request.ID, request.Params, writer)
	case "textDocument/semanticTokens/range":
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, server.writeSemanticTokensRange(ctx, request.ID, request.Params, writer)
	case "workspace/didChangeConfiguration":
		return -1, nil
	case "workspace/didChangeWatchedFiles":
		return -1, server.didChangeWatchedFiles(ctx, request.Params, writer)
	default:
		if len(request.ID) == 0 {
			return -1, nil
		}
		return -1, &requestError{code: methodNotFound, message: "method not found: " + request.Method}
	}
}

type requestError struct {
	code    int
	message string
}

func (err *requestError) Error() string { return err.message }

func initializeResult() map[string]any {
	return map[string]any{
		"capabilities": map[string]any{
			"textDocumentSync": map[string]any{
				"openClose": true,
				"change":    2,
				"save":      map[string]any{"includeText": true},
			},
			"hoverProvider":              true,
			"definitionProvider":         true,
			"declarationProvider":        true,
			"typeDefinitionProvider":     true,
			"referencesProvider":         true,
			"renameProvider":             map[string]any{"prepareProvider": true},
			"documentFormattingProvider": true,
			"completionProvider":         map[string]any{"resolveProvider": true, "triggerCharacters": []string{"."}},
			"signatureHelpProvider":      map[string]any{"triggerCharacters": []string{"(", ","}},
			"codeActionProvider":         map[string]any{"codeActionKinds": []string{"quickfix"}},
			"documentLinkProvider":       map[string]any{"resolveProvider": false},
			"linkedEditingRangeProvider": true,
			"diagnosticProvider": map[string]any{
				"identifier": "tesl", "interFileDependencies": true, "workspaceDiagnostics": false,
			},
			"documentSymbolProvider":    true,
			"foldingRangeProvider":      true,
			"documentHighlightProvider": true,
			"selectionRangeProvider":    true,
			"inlayHintProvider":         true,
			"semanticTokensProvider": map[string]any{
				"legend": map[string]any{
					"tokenTypes":     []string{"function", "type", "enum", "enumMember", "property", "variable"},
					"tokenModifiers": []string{"declaration"},
				},
				"full":  map[string]any{"delta": true},
				"range": true,
			},
		},
		"serverInfo": map[string]string{
			"name":    "tesl-lsp-go",
			"version": "0.3.1",
		},
	}
}

type textDocumentParams struct {
	TextDocument struct {
		URI     string `json:"uri"`
		Version int    `json:"version"`
		Text    string `json:"text"`
	} `json:"textDocument"`
}

type changeParams struct {
	TextDocument struct {
		URI     string `json:"uri"`
		Version int    `json:"version"`
	} `json:"textDocument"`
	ContentChanges []struct {
		Text  string `json:"text"`
		Range *struct {
			Start protocol.Position `json:"start"`
			End   protocol.Position `json:"end"`
		} `json:"range"`
	} `json:"contentChanges"`
}

func (server *Server) didSave(ctx context.Context, raw json.RawMessage, writer *protocol.Writer) error {
	var params struct {
		TextDocument struct {
			URI string `json:"uri"`
		} `json:"textDocument"`
		Text *string `json:"text"`
	}
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return errors.New("textDocument/didSave: invalid params")
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return nil
	}
	if params.Text != nil {
		doc.Text = *params.Text
		server.documents[doc.URI] = doc
	}
	server.scheduleAllDiagnostics(ctx, writer)
	return nil
}

type closeParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
}

type positionParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	Position protocol.Position `json:"position"`
}

type renameParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	Position protocol.Position `json:"position"`
	NewName  string            `json:"newName"`
}

type codeActionParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	Context struct {
		Diagnostics []codeActionDiagnostic `json:"diagnostics"`
	} `json:"context"`
}

type codeActionDiagnostic struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Data    struct {
		Fix json.RawMessage `json:"fix"`
	} `json:"data"`
}

type formattingParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
}

type selectionParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	Positions []protocol.Position `json:"positions"`
}

func (server *Server) didOpen(ctx context.Context, raw json.RawMessage, writer *protocol.Writer) error {
	var params textDocumentParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return errors.New("textDocument/didOpen: invalid params")
	}
	path, err := protocol.URIToPath(params.TextDocument.URI)
	if err != nil {
		return err
	}
	server.documents[params.TextDocument.URI] = document{
		URI: params.TextDocument.URI, Path: path, Version: params.TextDocument.Version, Text: params.TextDocument.Text,
	}
	return server.publishDiagnostics(ctx, server.documents[params.TextDocument.URI], writer)
}

func (server *Server) didChange(ctx context.Context, raw json.RawMessage, writer *protocol.Writer) error {
	var params changeParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" || len(params.ContentChanges) == 0 {
		return errors.New("textDocument/didChange: invalid params")
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return errors.New("textDocument/didChange: document is not open")
	}
	if params.TextDocument.Version > 0 && params.TextDocument.Version <= doc.Version {
		return nil
	}
	doc.Version = params.TextDocument.Version
	text := doc.Text
	for _, change := range params.ContentChanges {
		if change.Range == nil {
			text = change.Text
			continue
		}
		index := protocol.NewLineIndex(text)
		start, err := index.Offset(change.Range.Start)
		if err != nil {
			return err
		}
		end, err := index.Offset(change.Range.End)
		if err != nil || end < start {
			return errors.New("textDocument/didChange: invalid range")
		}
		text = text[:start] + change.Text + text[end:]
	}
	doc.Text = text
	server.documents[doc.URI] = doc
	server.scheduleAllDiagnostics(ctx, writer)
	return nil
}

type watchedFileParams struct {
	Changes []struct {
		URI  string `json:"uri"`
		Type int    `json:"type"`
	} `json:"changes"`
}

func (server *Server) didChangeWatchedFiles(ctx context.Context, raw json.RawMessage, writer *protocol.Writer) error {
	var params watchedFileParams
	if err := json.Unmarshal(raw, &params); err != nil || len(params.Changes) == 0 {
		return errors.New("workspace/didChangeWatchedFiles: invalid params")
	}
	for _, change := range params.Changes {
		if change.URI == "" || change.Type < 1 || change.Type > 3 {
			return errors.New("workspace/didChangeWatchedFiles: invalid params")
		}
	}
	server.scheduleAllDiagnostics(ctx, writer)
	return nil
}

func (server *Server) didClose(raw json.RawMessage, writer *protocol.Writer) error {
	var params closeParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return errors.New("textDocument/didClose: invalid params")
	}
	lock := server.diagnosticLock(params.TextDocument.URI)
	lock.Lock()
	defer func() {
		server.diagnosticLocksMu.Lock()
		if server.diagnosticLocks[params.TextDocument.URI] == lock {
			delete(server.diagnosticLocks, params.TextDocument.URI)
		}
		server.diagnosticLocksMu.Unlock()
		lock.Unlock()
	}()
	delete(server.documents, params.TextDocument.URI)
	server.cancelDiagnostics(params.TextDocument.URI)
	return server.publishDiagnosticGroups(params.TextDocument.URI, nil, writer)
}

func (server *Server) scheduleDiagnostics(ctx context.Context, doc document, writer *protocol.Writer) {
	lock := server.diagnosticLock(doc.URI)
	lock.Lock()
	server.diagnosticMu.Lock()
	if previous, found := server.diagnosticRuns[doc.URI]; found {
		previous.cancel()
	}
	queryContext, cancel := context.WithCancel(ctx)
	server.nextDiagnostic++
	runID := server.nextDiagnostic
	server.diagnosticRuns[doc.URI] = diagnosticRun{cancel: cancel, id: runID}
	server.diagnosticWG.Add(1)
	server.diagnosticMu.Unlock()
	lock.Unlock()
	overlays := server.sourceOverlays()
	go func() {
		defer server.diagnosticWG.Done()
		groups, err := server.diagnosticsForDocumentWithOverlays(queryContext, doc, overlays)
		lock.Lock()
		defer lock.Unlock()
		server.diagnosticMu.Lock()
		run, current := server.diagnosticRuns[doc.URI]
		fresh := current && run.id == runID
		if fresh {
			delete(server.diagnosticRuns, doc.URI)
		}
		server.diagnosticMu.Unlock()
		if !fresh {
			return
		}
		if server.beforeDiagnosticPublish != nil {
			server.beforeDiagnosticPublish()
		}
		if errors.Is(queryContext.Err(), context.Canceled) {
			return
		}
		if err != nil {
			_ = server.publishCompilerFailure(doc.URI, err, writer)
			return
		}
		_ = server.publishDiagnosticGroups(doc.URI, groups, writer)
	}()
}

func (server *Server) scheduleAllDiagnostics(ctx context.Context, writer *protocol.Writer) {
	uris := make([]string, 0, len(server.documents))
	for uri := range server.documents {
		uris = append(uris, uri)
	}
	sort.Strings(uris)
	for _, uri := range uris {
		server.scheduleDiagnostics(ctx, server.documents[uri], writer)
	}
}

func (server *Server) cancelDiagnostics(uri string) {
	server.diagnosticMu.Lock()
	if run, found := server.diagnosticRuns[uri]; found {
		run.cancel()
		delete(server.diagnosticRuns, uri)
	}
	server.diagnosticMu.Unlock()
}

func (server *Server) waitDiagnostics() {
	server.diagnosticWG.Wait()
}

func (server *Server) queryAt(ctx context.Context, raw json.RawMessage, flag string) ([]byte, document, error) {
	if server.compiler == nil {
		return nil, document{}, errors.New("compiler client is not configured")
	}
	var params positionParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return nil, document{}, errors.New("textDocument query: invalid params")
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return nil, document{}, errors.New("textDocument query: document is not open")
	}
	payload, err := server.queryDocumentPosition(ctx, doc, params.Position, flag)
	return payload, doc, err
}

func (server *Server) queryDocumentPosition(ctx context.Context, doc document, position protocol.Position, flag string) ([]byte, error) {
	index := protocol.NewLineIndex(doc.Text)
	offset, err := index.Offset(position)
	if err != nil {
		return nil, err
	}
	lineStart, err := index.Offset(protocol.Position{Line: position.Line})
	if err != nil {
		return nil, err
	}
	byteColumn := offset - lineStart
	payload, _, err := server.querySourceJSON(ctx, flag, doc, server.sourceOverlays(),
		strconv.Itoa(position.Line), strconv.Itoa(byteColumn))
	return payload, err
}

type typeAtResponse struct {
	Version int `json:"version"`
	TypeAt  *struct {
		Type string `json:"type"`
	} `json:"type_at"`
}

func (server *Server) writeHover(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	payload, _, err := server.queryAt(ctx, raw, "--type-at-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	var response typeAtResponse
	if err := decodeVersioned("--type-at-json", payload, &response); err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	if response.TypeAt == nil {
		fieldPayload, _, fieldErr := server.queryAt(ctx, raw, "--field-at-json")
		if fieldErr != nil {
			return server.writeResult(writer, id, nil)
		}
		var field fieldAtResponse
		if err := decodeVersioned("--field-at-json", fieldPayload, &field); err != nil || field.FieldAt == nil {
			return server.writeResult(writer, id, nil)
		}
		return server.writeResult(writer, id, map[string]any{
			"contents": map[string]string{
				"kind": "plaintext", "value": field.FieldAt.Field + ": " + field.FieldAt.FieldType,
			},
		})
	}
	hover := map[string]any{
		"contents": map[string]string{
			"kind":  "plaintext",
			"value": response.TypeAt.Type,
		},
	}
	return server.writeResult(writer, id, hover)
}

type fieldAtResponse struct {
	Version int `json:"version"`
	FieldAt *struct {
		Field     string `json:"field"`
		FieldType string `json:"field_type"`
	} `json:"field_at"`
}

type compilerLocation struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Col     int    `json:"col"`
	EndLine int    `json:"end_line"`
	EndCol  int    `json:"end_col"`
	Kind    string `json:"kind"`
}

type definitionResponse struct {
	Version    int               `json:"version"`
	Definition *compilerLocation `json:"definition"`
}

func (server *Server) writeDefinition(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	payload, doc, err := server.queryAt(ctx, raw, "--definition-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	var response definitionResponse
	if err := decodeVersioned("--definition-json", payload, &response); err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	if response.Definition == nil {
		return server.writeResult(writer, id, nil)
	}
	location := map[string]any{
		"uri": protocol.PathToURI(response.Definition.File),
		"range": map[string]protocol.Position{
			"start": sourceLocationPosition(doc, response.Definition.Line, response.Definition.Col),
			"end":   sourceLocationPosition(doc, response.Definition.EndLine, response.Definition.EndCol),
		},
	}
	return server.writeResult(writer, id, location)
}

type completionResponse struct {
	Version     int                  `json:"version"`
	Completions []compilerCompletion `json:"completions"`
}

type compilerCompletion struct {
	Label  string `json:"label"`
	Detail string `json:"detail"`
	Kind   string `json:"kind"`
}

func (server *Server) writeCompletion(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	payload, _, err := server.queryAt(ctx, raw, "--completions-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	var response completionResponse
	if err := decodeVersioned("--completions-json", payload, &response); err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	items := make([]map[string]any, 0, len(response.Completions))
	for _, completion := range response.Completions {
		items = append(items, map[string]any{
			"label":  completion.Label,
			"detail": completion.Detail,
			"kind":   completionKind(completion.Kind),
			"data":   map[string]string{"name": completion.Label},
		})
	}
	return server.writeResult(writer, id, map[string]any{"isIncomplete": false, "items": items})
}

func (server *Server) writeCompletionDocumentation(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var item map[string]any
	if err := json.Unmarshal(raw, &item); err != nil {
		return server.writeResult(writer, id, json.RawMessage(raw))
	}
	if item == nil {
		return server.writeResult(writer, id, json.RawMessage(raw))
	}
	label, _ := item["label"].(string)
	if label == "" || server.compiler == nil {
		return server.writeResult(writer, id, item)
	}
	payload, _, err := server.compiler.QueryJSON(ctx, "--doc-json", label)
	if err != nil {
		return server.writeResult(writer, id, item)
	}
	var docs struct {
		Entries []struct {
			Name string `json:"name"`
			Doc  string `json:"doc"`
		} `json:"entries"`
	}
	if err := decodeVersioned("--doc-json", payload, &docs); err != nil {
		return server.writeResult(writer, id, item)
	}
	for _, entry := range docs.Entries {
		if entry.Name == label && entry.Doc != "" {
			item["documentation"] = map[string]string{"kind": "markdown", "value": entry.Doc}
			break
		}
	}
	return server.writeResult(writer, id, item)
}

type signatureHelpResponse struct {
	Version   int `json:"version"`
	Signature *struct {
		Label      string `json:"label"`
		Parameters []struct {
			Label string `json:"label"`
			Type  string `json:"type"`
		} `json:"parameters"`
		ActiveParameter int `json:"active_parameter"`
	} `json:"signature"`
}

func (server *Server) writeSignatureHelp(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	payload, _, err := server.queryAt(ctx, raw, "--signature-help-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	var response signatureHelpResponse
	if err := decodeVersioned("--signature-help-json", payload, &response); err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	if response.Signature == nil {
		return server.writeResult(writer, id, nil)
	}
	parameters := make([]map[string]any, 0, len(response.Signature.Parameters))
	for _, parameter := range response.Signature.Parameters {
		entry := map[string]any{"label": parameter.Label}
		if parameter.Type != "" {
			entry["documentation"] = map[string]string{"kind": "markdown", "value": "```tesl\n" + parameter.Type + "\n```"}
		}
		parameters = append(parameters, entry)
	}
	active := maxNonNegative(response.Signature.ActiveParameter)
	return server.writeResult(writer, id, map[string]any{
		"signatures": []map[string]any{{
			"label":           response.Signature.Label,
			"parameters":      parameters,
			"activeParameter": active,
		}},
		"activeSignature": 0,
		"activeParameter": active,
	})
}

type typeDefinitionResponse struct {
	Version        int               `json:"version"`
	TypeDefinition *compilerLocation `json:"type_definition"`
}

func (server *Server) writeTypeDefinition(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	payload, doc, err := server.queryAt(ctx, raw, "--type-definition-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	var response typeDefinitionResponse
	if err := decodeVersioned("--type-definition-json", payload, &response); err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	if response.TypeDefinition == nil {
		return server.writeResult(writer, id, nil)
	}
	return server.writeResult(writer, id, compilerLocationToLSP(doc, *response.TypeDefinition))
}

type referencesResponse struct {
	Version     int                `json:"version"`
	Occurrences []compilerLocation `json:"occurrences"`
}

func (server *Server) writeReferences(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	payload, doc, err := server.queryAt(ctx, raw, "--occurrences-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	var response referencesResponse
	if err := decodeVersioned("--occurrences-json", payload, &response); err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	locations := make([]map[string]any, 0, len(response.Occurrences))
	for _, occurrence := range response.Occurrences {
		locations = append(locations, compilerLocationToLSPForDocument(doc, occurrence))
	}
	return server.writeResult(writer, id, locations)
}

func (server *Server) writePrepareRename(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	payload, doc, err := server.queryAt(ctx, raw, "--occurrences-json")
	if err != nil {
		return server.writeResult(writer, id, nil)
	}
	var response referencesResponse
	if err := decodeVersioned("--occurrences-json", payload, &response); err != nil {
		return server.writeResult(writer, id, nil)
	}
	var params positionParams
	if err := json.Unmarshal(raw, &params); err != nil {
		return server.writeResult(writer, id, nil)
	}
	for _, occurrence := range response.Occurrences {
		location := compilerLocationToLSPForDocument(doc, occurrence)
		rangeValue, ok := location["range"].(map[string]protocol.Position)
		if ok && positionInRange(params.Position, rangeValue) {
			return server.writeResult(writer, id, map[string]any{"range": rangeValue})
		}
	}
	return server.writeResult(writer, id, nil)
}

func (server *Server) writeRename(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params renameParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" || params.NewName == "" {
		return server.writeResult(writer, id, nil)
	}
	payload, doc, err := server.queryAt(ctx, raw, "--occurrences-json")
	if err != nil {
		return server.writeResult(writer, id, nil)
	}
	var response referencesResponse
	if err := decodeVersioned("--occurrences-json", payload, &response); err != nil || len(response.Occurrences) == 0 {
		return server.writeResult(writer, id, nil)
	}
	edits := make([]map[string]any, 0, len(response.Occurrences))
	for _, occurrence := range response.Occurrences {
		location := compilerLocationToLSPForDocument(doc, occurrence)
		edits = append(edits, map[string]any{"range": location["range"], "newText": params.NewName})
	}
	return server.writeResult(writer, id, map[string]any{
		"changes": map[string][]map[string]any{doc.URI: edits},
	})
}

type fixPayload struct {
	Kind        string            `json:"kind"`
	Title       string            `json:"title"`
	Line        int               `json:"line"`
	Text        string            `json:"text"`
	Replacement string            `json:"replacement"`
	StartLine   int               `json:"start_line"`
	StartCol    int               `json:"start_col"`
	EndLine     int               `json:"end_line"`
	EndCol      int               `json:"end_col"`
	Edits       []json.RawMessage `json:"edits"`
}

func (server *Server) writeCodeActions(id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params codeActionParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return server.writeResult(writer, id, []map[string]any{})
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return server.writeResult(writer, id, []map[string]any{})
	}
	actions := make([]map[string]any, 0)
	for _, diagnostic := range params.Context.Diagnostics {
		if len(diagnostic.Data.Fix) == 0 || string(diagnostic.Data.Fix) == "null" {
			continue
		}
		var fix fixPayload
		if err := json.Unmarshal(diagnostic.Data.Fix, &fix); err != nil {
			continue
		}
		edits := server.fixEdits(doc, fix)
		if len(edits) == 0 {
			continue
		}
		title := fix.Title
		if title == "" {
			title = "Apply fix for " + diagnostic.Code
		}
		actions = append(actions, map[string]any{
			"title": title,
			"kind":  "quickfix",
			"edit":  map[string]any{"changes": map[string][]map[string]any{doc.URI: edits}},
		})
	}
	return server.writeResult(writer, id, actions)
}

var documentURL = regexp.MustCompile(`https?://[^\s)<>"']+`)

func (server *Server) writeDocumentLinks(id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params formattingParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return server.writeResult(writer, id, []map[string]any{})
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return server.writeResult(writer, id, []map[string]any{})
	}
	links := make([]map[string]any, 0)
	for line, text := range strings.Split(doc.Text, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(text), "#") {
			continue
		}
		for _, match := range documentURL.FindAllStringIndex(text, -1) {
			links = append(links, map[string]any{
				"range": protocol.Range{
					Start: protocol.Position{Line: line, Character: protocol.ByteToUTF16Column(text, match[0])},
					End:   protocol.Position{Line: line, Character: protocol.ByteToUTF16Column(text, match[1])},
				},
				"target": text[match[0]:match[1]],
			})
		}
	}
	return server.writeResult(writer, id, links)
}

func (server *Server) writeLinkedEditing(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params positionParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return server.writeResult(writer, id, nil)
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return server.writeResult(writer, id, nil)
	}
	word, line, ok := wordAtPosition(doc.Text, params.Position)
	if !ok {
		return server.writeResult(writer, id, nil)
	}
	lines := strings.Split(doc.Text, "\n")
	start, end := blockBounds(lines, line)
	ranges := make([]protocol.Range, 0)
	identifier := regexp.QuoteMeta(word)
	pattern := regexp.MustCompile(`\b` + identifier + `\b`)
	for currentLine := start; currentLine < end && currentLine < len(lines); currentLine++ {
		text := lines[currentLine]
		for _, match := range pattern.FindAllStringIndex(text, -1) {
			ranges = append(ranges, protocol.Range{
				Start: protocol.Position{Line: currentLine, Character: protocol.ByteToUTF16Column(text, match[0])},
				End:   protocol.Position{Line: currentLine, Character: protocol.ByteToUTF16Column(text, match[1])},
			})
		}
	}
	if len(ranges) < 2 {
		return server.writeResult(writer, id, nil)
	}
	return server.writeResult(writer, id, map[string]any{"ranges": ranges})
}

func wordAtPosition(source string, position protocol.Position) (string, int, bool) {
	index := protocol.NewLineIndex(source)
	offset, err := index.Offset(position)
	if err != nil {
		return "", 0, false
	}
	lineStart, err := index.Offset(protocol.Position{Line: position.Line})
	if err != nil {
		return "", 0, false
	}
	lineEnd := offset
	for lineEnd < len(source) && source[lineEnd] != '\n' {
		lineEnd++
	}
	lineText := source[lineStart:lineEnd]
	byteOffset := offset - lineStart
	if byteOffset > len(lineText) {
		byteOffset = len(lineText)
	}
	start := byteOffset
	if start == len(lineText) && start > 0 {
		start--
	}
	for start > 0 && isIdentifierByte(lineText[start-1]) {
		start--
	}
	end := byteOffset
	if end < len(lineText) && !isIdentifierByte(lineText[end]) && end > 0 {
		end--
	}
	for end < len(lineText) && isIdentifierByte(lineText[end]) {
		end++
	}
	if end <= start || !isIdentifierByte(lineText[start]) {
		return "", 0, false
	}
	return lineText[start:end], position.Line, true
}

func isIdentifierByte(value byte) bool {
	return value == '_' || value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z' || value >= '0' && value <= '9'
}

func blockBounds(lines []string, line int) (int, int) {
	if len(lines) == 0 {
		return 0, 0
	}
	if line < 0 {
		line = 0
	}
	if line >= len(lines) {
		line = len(lines) - 1
	}
	boundary := func(index int) bool {
		text := lines[index]
		return text != "" && text[0] != ' ' && text[0] != '\t' && text[0] != '#'
	}
	start := line
	for start > 0 && !boundary(start) {
		start--
	}
	end := start + 1
	for end < len(lines) && !boundary(end) {
		end++
	}
	return start, end
}

func (server *Server) fixEdits(doc document, fix fixPayload) []map[string]any {
	if fix.Kind == "multi" {
		edits := make([]map[string]any, 0)
		for _, raw := range fix.Edits {
			var nested fixPayload
			if json.Unmarshal(raw, &nested) == nil {
				edits = append(edits, server.fixEdits(doc, nested)...)
			}
		}
		return edits
	}
	var start, end protocol.Position
	switch fix.Kind {
	case "replace_line":
		start = protocol.Position{Line: fix.Line, Character: 0}
		end = lineEndPosition(doc.Text, fix.Line)
	case "insert_line":
		start = protocol.Position{Line: fix.Line, Character: 0}
		end = start
		fix.Replacement = fix.Text + "\n"
	case "replace_span":
		start = protocol.Position{Line: fix.StartLine, Character: 0}
		end = lineEndPosition(doc.Text, fix.EndLine)
	case "replace_range":
		start = sourceLocationPosition(doc, fix.StartLine, fix.StartCol)
		end = sourceLocationPosition(doc, fix.EndLine, fix.EndCol)
	default:
		return nil
	}
	if start.Line < 0 || end.Line < start.Line {
		return nil
	}
	return []map[string]any{{"range": protocol.Range{Start: start, End: end}, "newText": fix.Replacement}}
}

func lineEndPosition(source string, line int) protocol.Position {
	index := protocol.NewLineIndex(source)
	if line < 0 || line >= index.LineCount() {
		return protocol.Position{Line: maxNonNegative(line), Character: 0}
	}
	end, err := index.Offset(protocol.Position{Line: line, Character: 1000000})
	if err != nil {
		return protocol.Position{Line: line, Character: 0}
	}
	position, err := index.Position(end)
	if err != nil {
		return protocol.Position{Line: line, Character: 0}
	}
	return position
}

func positionInRange(position protocol.Position, value map[string]protocol.Position) bool {
	start, startOK := value["start"]
	end, endOK := value["end"]
	if !startOK || !endOK {
		return false
	}
	return comparePosition(start, position) <= 0 && comparePosition(position, end) <= 0
}

func comparePosition(left, right protocol.Position) int {
	if left.Line != right.Line {
		if left.Line < right.Line {
			return -1
		}
		return 1
	}
	if left.Character < right.Character {
		return -1
	}
	if left.Character > right.Character {
		return 1
	}
	return 0
}

func (server *Server) writeFormatting(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params formattingParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return server.writeResult(writer, id, []map[string]any{})
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found || server.compiler == nil {
		return server.writeResult(writer, id, []map[string]any{})
	}
	formatted, _, err := server.compiler.FormatSource(ctx, doc.Path, doc.Text)
	if err != nil || string(formatted) == doc.Text {
		return server.writeResult(writer, id, []map[string]any{})
	}
	end, err := protocol.NewLineIndex(doc.Text).Position(len(doc.Text))
	if err != nil {
		return server.writeResult(writer, id, []map[string]any{})
	}
	edit := map[string]any{
		"range": map[string]protocol.Position{
			"start": {Line: 0, Character: 0},
			"end":   end,
		},
		"newText": string(formatted),
	}
	return server.writeResult(writer, id, []map[string]any{edit})
}

func (server *Server) writeDocumentHighlight(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	payload, doc, err := server.queryAt(ctx, raw, "--occurrences-json")
	if err != nil {
		return server.writeResult(writer, id, []map[string]any{})
	}
	var response referencesResponse
	if err := decodeVersioned("--occurrences-json", payload, &response); err != nil {
		return server.writeResult(writer, id, []map[string]any{})
	}
	highlights := make([]map[string]any, 0, len(response.Occurrences))
	for _, occurrence := range response.Occurrences {
		kind := 1
		switch occurrence.Kind {
		case "read":
			kind = 2
		case "write":
			kind = 3
		}
		highlights = append(highlights, map[string]any{
			"range": compilerLocationToLSP(doc, occurrence)["range"],
			"kind":  kind,
		})
	}
	return server.writeResult(writer, id, highlights)
}

type selectionResponse struct {
	Version int                `json:"version"`
	Ranges  []compilerLocation `json:"ranges"`
}

func (server *Server) writeSelectionRanges(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params selectionParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return server.writeResult(writer, id, []map[string]any{})
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found || server.compiler == nil {
		return server.writeResult(writer, id, []map[string]any{})
	}
	result := make([]map[string]any, 0, len(params.Positions))
	for _, position := range params.Positions {
		payload, err := server.queryDocumentPosition(ctx, doc, position, "--selection-range-json")
		if err != nil {
			result = append(result, selectionFallback(position))
			continue
		}
		var response selectionResponse
		if err := decodeVersioned("--selection-range-json", payload, &response); err != nil || len(response.Ranges) == 0 {
			result = append(result, selectionFallback(position))
			continue
		}
		var parent map[string]any
		for index := len(response.Ranges) - 1; index >= 0; index-- {
			rangeLocation := response.Ranges[index]
			current := map[string]any{"range": compilerLocationToLSP(doc, rangeLocation)["range"]}
			if parent != nil {
				current["parent"] = parent
			}
			parent = current
		}
		result = append(result, parent)
	}
	return server.writeResult(writer, id, result)
}

func selectionFallback(position protocol.Position) map[string]any {
	return map[string]any{"range": protocol.Range{Start: position, End: position}}
}

type localBindingsResponse struct {
	Version  int            `json:"version"`
	Bindings []localBinding `json:"bindings"`
}

type localBinding struct {
	Line    int    `json:"line"`
	Col     int    `json:"col"`
	EndLine int    `json:"end_line"`
	EndCol  int    `json:"end_col"`
	Name    string `json:"name"`
	Type    string `json:"type"`
}

var inferredLet = regexp.MustCompile(`^[ \t]*let[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*=`)

func (server *Server) writeInlayHints(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params formattingParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return server.writeResult(writer, id, []map[string]any{})
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found || server.compiler == nil {
		return server.writeResult(writer, id, []map[string]any{})
	}
	payload, _, err := server.querySourceJSON(ctx, "--local-bindings-json", doc, server.sourceOverlays())
	if err != nil {
		return server.writeResult(writer, id, []map[string]any{})
	}
	var response localBindingsResponse
	if err := decodeVersioned("--local-bindings-json", payload, &response); err != nil {
		return server.writeResult(writer, id, []map[string]any{})
	}
	index := protocol.NewLineIndex(doc.Text)
	hints := make([]map[string]any, 0, len(response.Bindings))
	for _, binding := range response.Bindings {
		if binding.Line < 0 || binding.Line >= index.LineCount() || binding.Type == "" {
			continue
		}
		lineStart, lineErr := index.Offset(protocol.Position{Line: binding.Line})
		if lineErr != nil {
			continue
		}
		lineEnd, lineErr := index.Offset(protocol.Position{Line: binding.Line, Character: 1000000})
		if lineErr != nil {
			continue
		}
		lineText := doc.Text[lineStart:lineEnd]
		match := inferredLet.FindStringSubmatch(lineText)
		if len(match) != 2 || match[1] != binding.Name {
			continue
		}
		nameStart := strings.Index(lineText, binding.Name)
		if nameStart < 0 {
			continue
		}
		position := protocol.Position{Line: binding.Line, Character: protocol.ByteToUTF16Column(lineText, nameStart+len(binding.Name))}
		hints = append(hints, map[string]any{
			"position": position,
			"label":    ": " + binding.Type,
			"kind":     1,
		})
	}
	return server.writeResult(writer, id, hints)
}

func (server *Server) writeFoldingRanges(id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params formattingParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return server.writeResult(writer, id, []map[string]any{})
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return server.writeResult(writer, id, []map[string]any{})
	}
	lines := strings.Split(doc.Text, "\n")
	ranges := make([]map[string]any, 0)
	for line, text := range lines {
		trimmed := strings.TrimSpace(text)
		if strings.HasSuffix(trimmed, "{") {
			depth := 0
			end := line
			for candidate := line; candidate < len(lines); candidate++ {
				depth += strings.Count(lines[candidate], "{")
				depth -= strings.Count(lines[candidate], "}")
				if depth <= 0 {
					end = candidate
					break
				}
			}
			if end > line {
				ranges = append(ranges, map[string]any{"startLine": line, "endLine": end})
			}
		}
	}
	for line := 0; line+1 < len(lines); {
		if !strings.HasPrefix(strings.TrimSpace(lines[line]), "#") {
			line++
			continue
		}
		end := line
		for end+1 < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[end+1]), "#") {
			end++
		}
		if end > line {
			ranges = append(ranges, map[string]any{"startLine": line, "endLine": end, "kind": "comment"})
		}
		line = end + 1
	}
	return server.writeResult(writer, id, ranges)
}

type semanticSnapshot struct {
	Version       int                `json:"version"`
	Records       []semanticRecord   `json:"records"`
	ADTs          []semanticADT      `json:"adts"`
	Functions     []semanticFunction `json:"functions"`
	LocalBindings []semanticBinding  `json:"local_bindings"`
}

type semanticLocation struct {
	File      string `json:"file"`
	StartLine int    `json:"start_line"`
	StartCol  int    `json:"start_col"`
	EndLine   int    `json:"end_line"`
	EndCol    int    `json:"end_col"`
}

type semanticRecord struct {
	Name   string `json:"name"`
	Fields []struct {
		Name string `json:"name"`
	} `json:"fields"`
	Loc *semanticLocation `json:"loc"`
}

type semanticADT struct {
	Name     string `json:"name"`
	Variants []struct {
		Constructor string `json:"constructor"`
	} `json:"variants"`
	Loc *semanticLocation `json:"loc"`
}

type semanticFunction struct {
	Name string            `json:"name"`
	Kind string            `json:"kind"`
	Loc  *semanticLocation `json:"loc"`
}

type semanticBinding struct {
	Name string            `json:"name"`
	Loc  *semanticLocation `json:"loc"`
}

func (server *Server) semanticSnapshot(ctx context.Context, doc document) (semanticSnapshot, error) {
	if server.compiler == nil {
		return semanticSnapshot{}, errors.New("compiler client is not configured")
	}
	payload, _, err := server.querySourceJSON(ctx, "--semantic-json", doc, server.sourceOverlays())
	if err != nil {
		return semanticSnapshot{}, err
	}
	var snapshot semanticSnapshot
	if err := decodeVersioned("--semantic-json", payload, &snapshot); err != nil {
		return semanticSnapshot{}, err
	}
	return snapshot, nil
}

func (server *Server) writeDocumentSymbols(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params formattingParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return server.writeResult(writer, id, []map[string]any{})
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return server.writeResult(writer, id, []map[string]any{})
	}
	snapshot, err := server.semanticSnapshot(ctx, doc)
	if err != nil {
		return server.writeResult(writer, id, []map[string]any{})
	}
	symbols := make([]map[string]any, 0)
	for _, function := range snapshot.Functions {
		if function.Loc != nil {
			symbols = append(symbols, symbolInfo(doc, function.Name, functionSymbolKind(function.Kind), *function.Loc, ""))
		}
	}
	for _, record := range snapshot.Records {
		location := semanticLocation{}
		if record.Loc != nil {
			location = *record.Loc
		}
		symbols = append(symbols, symbolInfo(doc, record.Name, 23, location, ""))
		for _, field := range record.Fields {
			symbols = append(symbols, symbolInfo(doc, field.Name, 8, location, record.Name))
		}
	}
	for _, adt := range snapshot.ADTs {
		location := semanticLocation{}
		if adt.Loc != nil {
			location = *adt.Loc
		}
		symbols = append(symbols, symbolInfo(doc, adt.Name, 10, location, ""))
		for _, variant := range adt.Variants {
			symbols = append(symbols, symbolInfo(doc, variant.Constructor, 22, location, adt.Name))
		}
	}
	return server.writeResult(writer, id, symbols)
}

func symbolInfo(doc document, name string, kind int, location semanticLocation, container string) map[string]any {
	file := location.File
	if file == "" {
		file = doc.Path
	}
	entry := map[string]any{
		"name": name,
		"kind": kind,
		"location": map[string]any{
			"uri":   protocol.PathToURI(file),
			"range": semanticRange(doc, location),
		},
	}
	if container != "" {
		entry["containerName"] = container
	}
	return entry
}

func semanticRange(doc document, location semanticLocation) protocol.Range {
	return protocol.Range{
		Start: sourceLocationPosition(doc, location.StartLine, location.StartCol),
		End:   sourceLocationPosition(doc, location.EndLine, location.EndCol),
	}
}

func functionSymbolKind(kind string) int {
	if kind == "const" {
		return 14
	}
	return 12
}

type semanticToken struct{ line, character, length, kind int }

type semanticTokenState struct {
	ID   string
	Data []int
}

type semanticTokenParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
}

func (server *Server) semanticTokenValues(ctx context.Context, doc document) ([]semanticToken, error) {
	snapshot, err := server.semanticSnapshot(ctx, doc)
	if err != nil {
		return nil, err
	}
	tokens := make([]semanticToken, 0)
	add := func(name string, location *semanticLocation, kind int) {
		if location == nil || name == "" {
			return
		}
		lineStart, err := protocol.NewLineIndex(doc.Text).Offset(protocol.Position{Line: location.StartLine})
		if err != nil || lineStart > len(doc.Text) {
			return
		}
		lineEnd := lineStart
		for lineEnd < len(doc.Text) && doc.Text[lineEnd] != '\n' {
			lineEnd++
		}
		lineText := doc.Text[lineStart:lineEnd]
		byteColumn := strings.Index(lineText, name)
		if byteColumn < 0 {
			return
		}
		tokens = append(tokens, semanticToken{location.StartLine, protocol.ByteToUTF16Column(lineText, byteColumn), protocol.UTF16Length(name), kind})
	}
	for _, function := range snapshot.Functions {
		add(function.Name, function.Loc, 0)
	}
	for _, binding := range snapshot.LocalBindings {
		add(binding.Name, binding.Loc, 5)
	}
	sort.Slice(tokens, func(left, right int) bool {
		if tokens[left].line == tokens[right].line {
			return tokens[left].character < tokens[right].character
		}
		return tokens[left].line < tokens[right].line
	})
	return tokens, nil
}

func encodeSemanticTokens(tokens []semanticToken, filter *protocol.Range) []int {
	filtered := tokens[:0]
	for _, token := range tokens {
		if filter != nil && (token.line < filter.Start.Line || token.line > filter.End.Line) {
			continue
		}
		filtered = append(filtered, token)
	}
	data := make([]int, 0, len(filtered)*5)
	previousLine, previousCharacter := 0, 0
	for _, current := range filtered {
		deltaLine := current.line - previousLine
		deltaCharacter := current.character
		if deltaLine == 0 {
			deltaCharacter -= previousCharacter
		}
		data = append(data, deltaLine, deltaCharacter, current.length, current.kind, 1)
		previousLine, previousCharacter = current.line, current.character
	}
	return data
}

func (server *Server) nextSemanticTokenID() string {
	server.nextTokenID++
	return strconv.FormatUint(server.nextTokenID, 10)
}

func (server *Server) semanticTokenRequest(ctx context.Context, raw json.RawMessage, filter *protocol.Range) (string, []int, error) {
	var params semanticTokenParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return "", []int{}, nil
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return "", []int{}, nil
	}
	tokens, err := server.semanticTokenValues(ctx, doc)
	if err != nil {
		return "", []int{}, err
	}
	return doc.URI, encodeSemanticTokens(tokens, filter), nil
}

func (server *Server) writeSemanticTokens(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	uri, data, err := server.semanticTokenRequest(ctx, raw, nil)
	if err != nil {
		return server.writeResult(writer, id, map[string]any{"data": []int{}})
	}
	resultID := server.nextSemanticTokenID()
	server.semanticTokens[uri] = semanticTokenState{ID: resultID, Data: append([]int(nil), data...)}
	return server.writeResult(writer, id, map[string]any{"resultId": resultID, "data": data})
}

type semanticDeltaParams struct {
	semanticTokenParams
	PreviousResultID string `json:"previousResultId"`
}

func (server *Server) writeSemanticTokensDelta(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params semanticDeltaParams
	if err := json.Unmarshal(raw, &params); err != nil {
		return server.writeResult(writer, id, map[string]any{"data": []int{}})
	}
	uri, data, err := server.semanticTokenRequest(ctx, raw, nil)
	if err != nil {
		return server.writeResult(writer, id, map[string]any{"data": []int{}})
	}
	resultID := server.nextSemanticTokenID()
	previous, found := server.semanticTokens[uri]
	server.semanticTokens[uri] = semanticTokenState{ID: resultID, Data: append([]int(nil), data...)}
	if !found || previous.ID != params.PreviousResultID {
		return server.writeResult(writer, id, map[string]any{"resultId": resultID, "data": data})
	}
	if slicesEqual(previous.Data, data) {
		return server.writeResult(writer, id, map[string]any{"resultId": resultID, "edits": []map[string]any{}})
	}
	edit := map[string]any{"start": 0, "deleteCount": len(previous.Data), "data": data}
	return server.writeResult(writer, id, map[string]any{"resultId": resultID, "edits": []map[string]any{edit}})
}

type semanticRangeParams struct {
	semanticTokenParams
	Range protocol.Range `json:"range"`
}

func (server *Server) writeSemanticTokensRange(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params semanticRangeParams
	if err := json.Unmarshal(raw, &params); err != nil {
		return server.writeResult(writer, id, map[string]any{"data": []int{}})
	}
	_, data, err := server.semanticTokenRequest(ctx, raw, &params.Range)
	if err != nil {
		return server.writeResult(writer, id, map[string]any{"data": []int{}})
	}
	return server.writeResult(writer, id, map[string]any{"data": data})
}

func slicesEqual(left, right []int) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func compilerLocationToLSP(doc document, location compilerLocation) map[string]any {
	return map[string]any{
		"uri": protocol.PathToURI(location.File),
		"range": map[string]protocol.Position{
			"start": sourceLocationPosition(doc, location.Line, location.Col),
			"end":   sourceLocationPosition(doc, location.EndLine, location.EndCol),
		},
	}
}

func compilerLocationToLSPForDocument(doc document, location compilerLocation) map[string]any {
	result := compilerLocationToLSP(doc, location)
	if location.File == "" || samePath(location.File, doc.Path) {
		result["uri"] = doc.URI
	}
	return result
}

func decodeVersioned(flag string, payload []byte, destination any) error {
	if err := tooling.ValidateCompilerJSON(flag, payload); err != nil {
		return err
	}
	if err := json.Unmarshal(payload, destination); err != nil {
		return fmt.Errorf("invalid compiler JSON: %w", err)
	}
	return nil
}

func sourceLocationPosition(doc document, line, column int) protocol.Position {
	position, err := protocol.NewLineIndex(doc.Text).PositionFromLineColumn(line, column)
	if err == nil {
		return position
	}
	return protocol.Position{Line: maxNonNegative(line), Character: maxNonNegative(column)}
}

func completionKind(kind string) int {
	switch kind {
	case "function":
		return 3
	case "field":
		return 10
	default:
		return 6
	}
}

func maxNonNegative(value int) int {
	if value < 0 {
		return 0
	}
	return value
}

type compilerResponse struct {
	Version     int                  `json:"version"`
	Diagnostics []compilerDiagnostic `json:"diagnostics"`
}

type compilerDiagnostic struct {
	File     string          `json:"file"`
	Start    sourcePosition  `json:"start"`
	End      sourcePosition  `json:"end"`
	Severity string          `json:"severity"`
	Code     string          `json:"code"`
	Message  string          `json:"message"`
	Fix      json.RawMessage `json:"fix"`
	Source   string          `json:"source"`
}

type sourcePosition struct {
	Line int `json:"line"`
	Col  int `json:"col"`
}

func (server *Server) publishDiagnostics(ctx context.Context, doc document, writer *protocol.Writer) error {
	groups, err := server.diagnosticsForDocumentWithOverlays(ctx, doc, server.sourceOverlays())
	if err != nil {
		return server.publishCompilerFailure(doc.URI, err, writer)
	}
	return server.publishDiagnosticGroups(doc.URI, groups, writer)
}

func (server *Server) diagnosticsForDocument(ctx context.Context, doc document) (map[string][]map[string]any, error) {
	return server.diagnosticsForDocumentWithOverlays(ctx, doc, server.sourceOverlays())
}

func (server *Server) diagnosticsForDocumentWithOverlays(ctx context.Context, doc document, overlays []tooling.SourceOverlay) (map[string][]map[string]any, error) {
	if server.compiler == nil {
		return nil, errors.New("compiler client is not configured")
	}
	payload, _, err := server.querySourceJSON(ctx, "--check-json", doc, overlays)
	if err != nil {
		return nil, err
	}
	if err := tooling.ValidateCompilerJSON("--check-json", payload); err != nil {
		return nil, err
	}
	var response compilerResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		return nil, fmt.Errorf("invalid compiler JSON: %w", err)
	}
	groups := map[string][]map[string]any{doc.URI: {}}
	for _, diagnostic := range response.Diagnostics {
		uri := doc.URI
		source := doc.Text
		if !samePath(diagnostic.File, doc.Path) {
			uri = protocol.PathToURI(diagnostic.File)
			var found bool
			for _, overlay := range overlays {
				if samePath(diagnostic.File, overlay.Path) {
					source = overlay.Source
					found = true
					break
				}
			}
			if !found {
				contents, readErr := os.ReadFile(diagnostic.File) // #nosec G304 -- compiler returned a local source path.
				if readErr != nil {
					return nil, fmt.Errorf("read diagnostic source %s: %w", diagnostic.File, readErr)
				}
				source = string(contents)
			}
		}
		index := protocol.NewLineIndex(source)
		start, startErr := index.PositionFromLineColumn(diagnostic.Start.Line, diagnostic.Start.Col)
		end, endErr := index.PositionFromLineColumn(diagnostic.End.Line, diagnostic.End.Col)
		if startErr != nil || endErr != nil {
			return nil, errors.New("compiler diagnostic range is outside document")
		}
		entry := map[string]any{
			"range": map[string]protocol.Position{
				"start": start,
				"end":   end,
			},
			"severity": lspSeverity(diagnostic.Severity),
			"code":     diagnostic.Code,
			"message":  diagnostic.Message,
			"source":   diagnostic.Source,
		}
		if len(diagnostic.Fix) > 0 && string(diagnostic.Fix) != "null" {
			entry["data"] = map[string]json.RawMessage{"fix": diagnostic.Fix}
		}
		groups[uri] = append(groups[uri], entry)
	}
	return groups, nil
}

type pullDiagnosticParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	PreviousResultID string `json:"previousResultId"`
}

func (server *Server) writePullDiagnostics(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params pullDiagnosticParams
	if err := json.Unmarshal(raw, &params); err != nil || params.TextDocument.URI == "" {
		return server.writeResult(writer, id, map[string]any{"kind": "full", "resultId": "", "items": []map[string]any{}})
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return server.writeResult(writer, id, map[string]any{"kind": "full", "resultId": contentResultID(""), "items": []map[string]any{}})
	}
	groups, err := server.diagnosticsForDocument(ctx, doc)
	if err != nil {
		groups = map[string][]map[string]any{doc.URI: {compilerFailureDiagnostic(err)}}
	}
	resultID := diagnosticResultID(doc.Text, groups)
	if params.PreviousResultID != "" && params.PreviousResultID == resultID {
		return server.writeResult(writer, id, map[string]any{"kind": "unchanged", "resultId": resultID})
	}
	related := make(map[string]any)
	for uri, diagnostics := range groups {
		if uri != doc.URI {
			related[uri] = map[string]any{"kind": "full", "items": diagnostics}
		}
	}
	result := map[string]any{"kind": "full", "resultId": resultID, "items": groups[doc.URI]}
	if len(related) > 0 {
		result["relatedDocuments"] = related
	}
	return server.writeResult(writer, id, result)
}

func contentResultID(text string) string {
	digest := sha256.Sum256([]byte(text))
	return fmt.Sprintf("%x", digest[:])
}

func diagnosticResultID(text string, groups map[string][]map[string]any) string {
	encoded, _ := json.Marshal(groups)
	return contentResultID(text + "\x00" + string(encoded))
}

func (server *Server) publishCompilerFailure(uri string, err error, writer *protocol.Writer) error {
	return server.publishDiagnosticGroups(uri, map[string][]map[string]any{uri: {compilerFailureDiagnostic(err)}}, writer)
}

func compilerFailureDiagnostic(err error) map[string]any {
	return map[string]any{
		"range": map[string]protocol.Position{
			"start": {Line: 0, Character: 0},
			"end":   {Line: 0, Character: 0},
		},
		"severity": 2,
		"code":     "TESL-COMPILER",
		"message":  err.Error(),
		"source":   "tesl-lsp-go",
	}
}

func (server *Server) publishDiagnosticGroups(entryURI string, groups map[string][]map[string]any, writer *protocol.Writer) error {
	server.diagnosticMu.Lock()
	affected := make(map[string]struct{})
	for uri := range server.diagnosticSets[entryURI] {
		affected[uri] = struct{}{}
	}
	if groups == nil {
		delete(server.diagnosticSets, entryURI)
	} else {
		server.diagnosticSets[entryURI] = groups
		for uri := range groups {
			affected[uri] = struct{}{}
		}
	}
	aggregated := make(map[string][]map[string]any, len(affected))
	for uri := range affected {
		seen := make(map[string]struct{})
		for _, entryGroups := range server.diagnosticSets {
			for _, diagnostic := range entryGroups[uri] {
				encoded, _ := json.Marshal(diagnostic)
				key := string(encoded)
				if _, duplicate := seen[key]; duplicate {
					continue
				}
				seen[key] = struct{}{}
				aggregated[uri] = append(aggregated[uri], diagnostic)
			}
		}
	}
	server.diagnosticMu.Unlock()

	uris := make([]string, 0, len(affected))
	for uri := range affected {
		uris = append(uris, uri)
	}
	sort.Strings(uris)
	for _, uri := range uris {
		if err := server.publish(uri, aggregated[uri], writer); err != nil {
			return err
		}
	}
	return nil
}

func (server *Server) publish(uri string, diagnostics []map[string]any, writer *protocol.Writer) error {
	params := map[string]any{"uri": uri, "diagnostics": diagnostics}
	encoded, err := json.Marshal(params)
	if err != nil {
		return err
	}
	return writer.WriteJSON(protocol.Request{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: encoded})
}

func (server *Server) writeResult(writer *protocol.Writer, id json.RawMessage, result any) error {
	response, err := protocol.NewResultResponse(id, result)
	if err != nil {
		return err
	}
	return writer.WriteJSON(response)
}

func (server *Server) writeError(writer *protocol.Writer, id json.RawMessage, code int, message string) error {
	response, err := protocol.NewErrorResponse(id, code, message, nil)
	if err != nil {
		return err
	}
	return writer.WriteJSON(response)
}

func lspSeverity(severity string) int {
	switch severity {
	case "error":
		return 1
	case "warning":
		return 2
	default:
		return 3
	}
}

func samePath(left, right string) bool {
	leftAbsolute, leftErr := filepath.Abs(left)
	rightAbsolute, rightErr := filepath.Abs(right)
	if leftErr != nil || rightErr != nil {
		return filepath.Clean(left) == filepath.Clean(right)
	}
	return filepath.Clean(leftAbsolute) == filepath.Clean(rightAbsolute)
}

// CompilerFromEnvironment builds the shipped command's default compiler
// client. Keeping discovery here avoids Racket-specific path logic in the LSP.
func CompilerFromEnvironment() tooling.Client {
	executable := os.Getenv("TESL_COMPILER")
	if executable == "" {
		executable = "tesl"
	}
	return tooling.Client{Executable: executable}
}
