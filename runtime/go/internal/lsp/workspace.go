package lsp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

func (server *Server) workspaceQuery(ctx context.Context, raw json.RawMessage, flag string, extra ...string) (tooling.WorkspaceResponse, document, error) {
	var params positionParams
	var response tooling.WorkspaceResponse
	if err := json.Unmarshal(raw, &params); err != nil {
		return response, document{}, err
	}
	doc, found := server.documents[params.TextDocument.URI]
	if !found {
		return response, doc, errors.New("workspace query document is not open")
	}
	payload, err := server.queryDocumentPosition(ctx, doc, params.Position, flag, extra...)
	if err != nil {
		return response, doc, err
	}
	if err := decodeVersioned(flag, payload, &response); err != nil {
		return response, doc, err
	}
	if !response.Complete {
		return response, doc, fmt.Errorf("workspace index is incomplete: %s", response.Problems[0].Message)
	}
	return response, doc, nil
}

func workspaceLocation(location tooling.WorkspaceLocation, texts map[string]string) (map[string]any, error) {
	text, found := texts[location.File]
	if !found {
		return nil, errors.New("workspace location is missing its source precondition")
	}
	index := protocol.NewLineIndex(text)
	first, last, err := tooling.WorkspaceRangeOffsets(text, location)
	if err != nil {
		return nil, err
	}
	start, err := index.Position(first)
	if err != nil {
		return nil, err
	}
	end, err := index.Position(last)
	if err != nil {
		return nil, err
	}
	return map[string]any{"uri": protocol.PathToURI(location.File), "range": map[string]protocol.Position{"start": start, "end": end}}, nil
}

func (server *Server) writeDefinition(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	response, _, err := server.workspaceQuery(ctx, raw, "--workspace-definition-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	if response.Symbol == nil {
		return server.writeResult(writer, id, nil)
	}
	texts, err := tooling.WorkspaceInputTexts(ctx, response, server.sourceOverlays())
	if err != nil {
		return server.writeError(writer, id, -32801, err.Error())
	}
	location, err := workspaceLocation(response.Symbol.Definition, texts)
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	return server.writeResult(writer, id, location)
}

func (server *Server) writeReferences(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	response, _, err := server.workspaceQuery(ctx, raw, "--workspace-references-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	texts, err := tooling.WorkspaceInputTexts(ctx, response, server.sourceOverlays())
	if err != nil {
		return server.writeError(writer, id, -32801, err.Error())
	}
	var params struct {
		Context struct {
			IncludeDeclaration bool `json:"includeDeclaration"`
		} `json:"context"`
	}
	if err := json.Unmarshal(raw, &params); err != nil {
		return server.writeError(writer, id, invalidRequest, err.Error())
	}
	locations := make([]map[string]any, 0, len(response.References))
	for _, ref := range response.References {
		if !params.Context.IncludeDeclaration && ref.Role == "declaration" {
			continue
		}
		location, err := workspaceLocation(ref.Location, texts)
		if err != nil {
			return server.writeError(writer, id, internalError, err.Error())
		}
		locations = append(locations, location)
	}
	return server.writeResult(writer, id, locations)
}

func (server *Server) writePrepareRename(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	if !server.workspaceEditsSupported {
		return server.writeError(writer, id, invalidRequest, "checked rename requires transactional documentChanges support")
	}
	response, doc, err := server.workspaceQuery(ctx, raw, "--workspace-references-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	if response.Symbol == nil || response.Symbol.ReadOnly {
		return server.writeResult(writer, id, nil)
	}
	texts, err := tooling.WorkspaceInputTexts(ctx, response, server.sourceOverlays())
	if err != nil {
		return server.writeError(writer, id, -32801, err.Error())
	}
	var params positionParams
	if err := json.Unmarshal(raw, &params); err != nil {
		return server.writeError(writer, id, invalidRequest, err.Error())
	}
	for _, ref := range response.References {
		if !samePath(ref.Location.File, doc.Path) {
			continue
		}
		location, err := workspaceLocation(ref.Location, texts)
		if err != nil {
			return server.writeError(writer, id, internalError, err.Error())
		}
		rangeValue := location["range"].(map[string]protocol.Position)
		if positionInRange(params.Position, rangeValue) {
			return server.writeResult(writer, id, map[string]any{"range": rangeValue, "placeholder": response.Symbol.Name})
		}
	}
	return server.writeResult(writer, id, nil)
}

func (server *Server) writeRename(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	if !server.workspaceEditsSupported {
		return server.writeError(writer, id, invalidRequest, "checked rename requires transactional documentChanges support")
	}
	var params renameParams
	if err := json.Unmarshal(raw, &params); err != nil || params.NewName == "" {
		return server.writeError(writer, id, invalidRequest, "rename requires a new name")
	}
	before, _, err := server.workspaceQuery(ctx, raw, "--workspace-references-json")
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	if before.Symbol == nil {
		return server.writeError(writer, id, invalidRequest, "no semantic symbol at rename position")
	}
	proposal, _, err := server.workspaceQuery(ctx, raw, "--workspace-rename-json", params.NewName, before.Snapshot)
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	if proposal.Rename == nil || !proposal.Rename.Safe {
		reason := "compiler did not return a safe rename proposal"
		if proposal.Rename != nil && proposal.Rename.Reason != nil {
			reason = *proposal.Rename.Reason
		}
		return server.writeError(writer, id, invalidRequest, reason)
	}
	if proposal.Snapshot != before.Snapshot || proposal.Symbol == nil || proposal.Symbol.ID != before.Symbol.ID || proposal.Rename.NewName != params.NewName {
		return server.writeError(writer, id, -32801, "workspace changed while preparing rename")
	}
	texts, err := tooling.WorkspaceInputTexts(ctx, proposal, server.sourceOverlays())
	if err != nil {
		return server.writeError(writer, id, -32801, err.Error())
	}
	// A fresh query discovers newly created/deleted files as well as changes to
	// existing unopened inputs. No request notification can mutate open documents
	// while this request owns the LSP dispatcher.
	current, _, err := server.workspaceQuery(ctx, raw, "--workspace-references-json")
	if err != nil || current.Snapshot != proposal.Snapshot {
		return server.writeError(writer, id, -32801, "workspace changed while checking rename inputs")
	}
	changes := make([]map[string]any, 0, len(proposal.Rename.Files))
	for _, file := range proposal.Rename.Files {
		var version any
		for _, doc := range server.documents {
			if samePath(doc.Path, file.File) {
				version = doc.Version
				break
			}
		}
		edits := make([]map[string]any, 0, len(file.Edits))
		for _, edit := range file.Edits {
			location, err := workspaceLocation(edit.Location, texts)
			if err != nil {
				return server.writeError(writer, id, internalError, err.Error())
			}
			edits = append(edits, map[string]any{"range": location["range"], "newText": edit.NewText})
		}
		changes = append(changes, map[string]any{"textDocument": map[string]any{"uri": protocol.PathToURI(file.File), "version": version}, "edits": edits})
	}
	return server.writeResult(writer, id, map[string]any{"documentChanges": changes})
}

// LSP SymbolKind values for the compiler's three declaration namespaces.
var workspaceSymbolKinds = map[string]int{"term": 12, "type": 23, "constructor": 9}

// writeWorkspaceSymbols answers workspace/symbol from the compiler's project
// index. The index needs one file to locate the project root (tesl.toml); any
// open document works, so with no document open the result is empty.
func (server *Server) writeWorkspaceSymbols(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params struct {
		Query string `json:"query"`
	}
	if err := json.Unmarshal(raw, &params); err != nil {
		return server.writeError(writer, id, invalidRequest, "workspace/symbol: invalid params")
	}
	if len(params.Query) > tooling.MaxWorkspaceSymbolQuery {
		return server.writeResult(writer, id, []any{})
	}
	if server.compiler == nil {
		return server.writeError(writer, id, internalError, "compiler client is not configured")
	}
	uris := make([]string, 0, len(server.documents))
	for uri := range server.documents {
		uris = append(uris, uri)
	}
	if len(uris) == 0 {
		return server.writeResult(writer, id, []any{})
	}
	sort.Strings(uris)
	payload, _, err := server.querySourceJSON(ctx, "--workspace-symbols-json", server.documents[uris[0]], server.sourceOverlays(), params.Query)
	if err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	var response tooling.WorkspaceSymbolsResponse
	if err := decodeVersioned("--workspace-symbols-json", payload, &response); err != nil {
		return server.writeError(writer, id, internalError, err.Error())
	}
	texts, err := tooling.WorkspaceInputTexts(ctx, response.Response(), server.sourceOverlays())
	if err != nil {
		return server.writeError(writer, id, -32801, err.Error())
	}
	result := make([]map[string]any, 0, len(response.Symbols))
	for _, symbol := range response.Symbols {
		location, err := workspaceLocation(symbol.Definition, texts)
		if err != nil {
			return server.writeError(writer, id, internalError, err.Error())
		}
		result = append(result, map[string]any{"name": symbol.Name, "kind": workspaceSymbolKinds[symbol.Kind],
			"containerName": symbol.Container, "location": location})
	}
	return server.writeResult(writer, id, result)
}
