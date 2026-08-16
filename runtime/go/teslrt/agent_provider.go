package teslrt

import (
	"encoding/json"
	"fmt"
	"strconv"
)

// The real LLM providers.
//
// Each one is a translation layer and nothing more: it renders the normalised request
// (agent.go) into a vendor's wire format, posts it through HttpPost — so the network is
// gated by `httpClient`, judged by the SSRF containment, and interceptable by the same
// `stubHttp` double every other outbound call is — and normalises the answer back. The
// agent loop never learns which vendor it is talking to.
//
// TOKEN STREAMING is not implemented against a real provider yet. `converseStreaming` and
// `agentRun` still publish every event they promise, in order, and a mock provider still
// synthesizes per-word deltas; what a real provider does not do here is emit `text-delta:`
// AS the model generates. The reply arrives complete and is published as one delta, so a UI
// renders the answer in one step instead of typing it out. Nothing is lost but the
// incremental rendering, and closing it needs a streaming HTTP body in the runtime, which
// httpclient.go does not have yet.

const anthropicVersion = "2023-06-01"

const (
	anthropicEndpoint = "https://api.anthropic.com/v1/messages"
	openaiEndpoint    = "https://api.openai.com/v1/chat/completions"
	mistralEndpoint   = "https://api.mistral.ai/v1/chat/completions"
)

// AnthropicProvider talks to the Messages API.
func AnthropicProvider(apiKey, model string) LlmProvider {
	return ProviderOf(func(request LlmRequest) LlmResponse {
		headers := []Tuple2[string, string]{
			{Tuple2First: "x-api-key", Tuple2Second: apiKey},
			{Tuple2First: "anthropic-version", Tuple2Second: anthropicVersion},
			{Tuple2First: "content-type", Tuple2Second: "application/json"},
		}
		body := anthropicRequest{
			Model:     model,
			MaxTokens: providerMaxTokens(request),
			System:    request.System,
			Messages:  anthropicMessages(request.Messages),
			Tools:     anthropicTools(request.Tools),
		}
		answer := providerPost("anthropic", anthropicEndpoint, headers, body)
		var decoded anthropicResponse
		providerDecode("anthropic", answer, &decoded)
		return anthropicNormalize(decoded, request)
	})
}

// OpenAIProvider talks to the Chat Completions API.
func OpenAIProvider(apiKey, model string) LlmProvider {
	return openAIWireProvider(apiKey, model, openaiEndpoint)
}

// MistralProvider speaks the OpenAI chat-completions format at Mistral's endpoint, which is
// what Mistral serves — the only difference is where it is posted.
func MistralProvider(apiKey, model string) LlmProvider {
	return openAIWireProvider(apiKey, model, mistralEndpoint)
}

// LocalProvider is the escape hatch for a self-hosted OpenAI-compatible server — llama.cpp,
// vLLM, Ollama's /v1. The endpoint is the program's to name, so no default applies.
func LocalProvider(endpoint, model string) LlmProvider {
	return openAIWireProvider("", model, endpoint)
}

func openAIWireProvider(apiKey, model, endpoint string) LlmProvider {
	return ProviderOf(func(request LlmRequest) LlmResponse {
		headers := []Tuple2[string, string]{
			{Tuple2First: "content-type", Tuple2Second: "application/json"},
		}
		// A local server usually wants no credential at all; sending an empty Bearer
		// would be a header it has to ignore.
		if apiKey != "" {
			headers = append(headers,
				Tuple2[string, string]{Tuple2First: "authorization", Tuple2Second: "Bearer " + apiKey})
		}
		body := openaiRequest{
			Model:     model,
			MaxTokens: providerMaxTokens(request),
			Messages:  openaiMessages(request.System, request.Messages),
			Tools:     openaiTools(request.Tools),
		}
		answer := providerPost("openai", endpoint, headers, body)
		var decoded openaiResponse
		providerDecode("openai", answer, &decoded)
		return openaiNormalize(decoded, request)
	})
}

// ── Shared plumbing ──────────────────────────────────────────────────────────

// providerMaxTokens defaults the budget the way the Racket runtime does, so an agent built
// without one is not a request with `max_tokens: 0`.
func providerMaxTokens(request LlmRequest) int64 {
	value, exact := request.MaxTokens.Int64()
	if !exact || value <= 0 {
		return 1024
	}
	return value
}

func providerPost(who, endpoint string, headers []Tuple2[string, string], body any) string {
	encoded, err := json.Marshal(body)
	if err != nil {
		panic(who + ": request could not be encoded: " + err.Error())
	}
	response := HttpPost(endpoint, headers, string(encoded))
	status, exact := response.Status.Int64()
	if !exact || status >= 400 {
		panic(fmt.Sprintf("%s: API error (HTTP %s): %s", who, response.Status.String(), response.Body))
	}
	return response.Body
}

func providerDecode(who, body string, into any) {
	if err := json.Unmarshal([]byte(body), into); err != nil {
		panic(who + ": provider returned non-JSON body: " + err.Error())
	}
}

// deliverWholeReply publishes a completed reply as a single delta. It is what stands in for
// per-token streaming against a real provider; see the note at the top of this file.
func deliverWholeReply(request LlmRequest, text string) {
	if request.OnDelta != nil && text != "" {
		request.OnDelta(text)
	}
}

func tokenCount(value int64) Int { return FromInt64(value) }

// ── Anthropic ────────────────────────────────────────────────────────────────

type anthropicRequest struct {
	Model     string             `json:"model"`
	MaxTokens int64              `json:"max_tokens"`
	System    string             `json:"system"`
	Messages  []anthropicMessage `json:"messages"`
	Tools     []anthropicTool    `json:"tools"`
}

type anthropicTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"input_schema"`
}

// Content is either a string (a plain user turn) or a block list, which is why it is `any`
// rather than a slice: Anthropic accepts both and the transcript carries both.
type anthropicMessage struct {
	Role    string `json:"role"`
	Content any    `json:"content"`
}

type anthropicBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text,omitempty"`
	ID        string          `json:"id,omitempty"`
	Name      string          `json:"name,omitempty"`
	Input     json.RawMessage `json:"input,omitempty"`
	ToolUseID string          `json:"tool_use_id,omitempty"`
	Content   string          `json:"content,omitempty"`
	IsError   bool            `json:"is_error,omitempty"`
}

func anthropicTools(tools []LlmToolDecl) []anthropicTool {
	decls := make([]anthropicTool, 0, len(tools))
	for _, tool := range tools {
		decls = append(decls, anthropicTool{
			Name: tool.Name, Description: tool.Description, InputSchema: tool.Schema,
		})
	}
	return decls
}

func anthropicMessages(messages []AgentMessage) []anthropicMessage {
	rendered := make([]anthropicMessage, 0, len(messages))
	for _, message := range messages {
		// Anthropic has only "user" and "assistant": a tool RESULT is a content block
		// sent back as the user. Passing "tool" through is an HTTP 400 that makes every
		// tool-using agent unusable on this provider.
		role := message.Role
		if role == "tool" {
			role = "user"
		}
		if len(message.Content) == 0 {
			rendered = append(rendered, anthropicMessage{Role: role, Content: message.Text})
			continue
		}
		blocks := []anthropicBlock{}
		for _, block := range message.Content {
			switch block.Kind {
			case "text":
				blocks = append(blocks, anthropicBlock{Type: "text", Text: block.Text})
			case "tool-use":
				blocks = append(blocks, anthropicBlock{
					Type: "tool_use", ID: block.ID, Name: block.Name, Input: block.Args,
				})
			case "tool-result":
				for _, result := range block.Results {
					blocks = append(blocks, anthropicBlock{
						Type: "tool_result", ToolUseID: result.ID,
						Content: result.Content, IsError: result.IsError,
					})
				}
			default:
				panic("anthropic: unknown content block kind " + block.Kind)
			}
		}
		rendered = append(rendered, anthropicMessage{Role: role, Content: blocks})
	}
	return rendered
}

type anthropicResponse struct {
	Content []struct {
		Type  string          `json:"type"`
		Text  string          `json:"text"`
		ID    string          `json:"id"`
		Name  string          `json:"name"`
		Input json.RawMessage `json:"input"`
	} `json:"content"`
	StopReason string `json:"stop_reason"`
	Usage      struct {
		Input      int64 `json:"input_tokens"`
		Output     int64 `json:"output_tokens"`
		CacheRead  int64 `json:"cache_read_input_tokens"`
		CacheWrite int64 `json:"cache_creation_input_tokens"`
	} `json:"usage"`
}

func anthropicNormalize(decoded anthropicResponse, request LlmRequest) LlmResponse {
	text := ""
	calls := []LlmToolCall{}
	for _, block := range decoded.Content {
		switch block.Type {
		case "text":
			text += block.Text
		case "tool_use":
			args := block.Input
			if len(args) == 0 {
				args = json.RawMessage("{}")
			}
			calls = append(calls, LlmToolCall{ID: block.ID, Name: block.Name, Args: args})
		}
	}
	deliverWholeReply(request, text)
	return LlmResponse{
		Text: text,
		Usage: LlmUsage{
			Input:      tokenCount(decoded.Usage.Input),
			Output:     tokenCount(decoded.Usage.Output),
			CacheRead:  tokenCount(decoded.Usage.CacheRead),
			CacheWrite: tokenCount(decoded.Usage.CacheWrite),
		},
		ToolCalls:  calls,
		StopReason: anthropicStopReason(decoded.StopReason),
	}
}

func anthropicStopReason(reason string) string {
	switch reason {
	case "end_turn":
		return "end-turn"
	case "tool_use":
		return "tool-use"
	case "max_tokens":
		return "max-tokens"
	case "refusal":
		return "refusal"
	default:
		return "other"
	}
}

// ── OpenAI wire format ───────────────────────────────────────────────────────

type openaiRequest struct {
	Model     string          `json:"model"`
	MaxTokens int64           `json:"max_tokens"`
	Messages  []openaiMessage `json:"messages"`
	Tools     []openaiTool    `json:"tools"`
}

type openaiTool struct {
	Type     string           `json:"type"`
	Function openaiToolSchema `json:"function"`
}

type openaiToolSchema struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Strict      bool            `json:"strict"`
	Parameters  json.RawMessage `json:"parameters"`
}

type openaiMessage struct {
	Role       string           `json:"role"`
	Content    string           `json:"content"`
	ToolCallID string           `json:"tool_call_id,omitempty"`
	ToolCalls  []openaiToolCall `json:"tool_calls,omitempty"`
}

type openaiToolCall struct {
	ID       string             `json:"id"`
	Type     string             `json:"type"`
	Function openaiToolCallBody `json:"function"`
}

type openaiToolCallBody struct {
	Name string `json:"name"`
	// OpenAI carries the arguments as a JSON STRING, not as an object.
	Arguments string `json:"arguments"`
}

func openaiTools(tools []LlmToolDecl) []openaiTool {
	decls := make([]openaiTool, 0, len(tools))
	for _, tool := range tools {
		decls = append(decls, openaiTool{
			Type: "function",
			Function: openaiToolSchema{
				Name: tool.Name, Description: tool.Description,
				Strict: true, Parameters: tool.Schema,
			},
		})
	}
	return decls
}

func openaiMessages(system string, messages []AgentMessage) []openaiMessage {
	rendered := []openaiMessage{}
	if system != "" {
		rendered = append(rendered, openaiMessage{Role: "system", Content: system})
	}
	for _, message := range messages {
		if len(message.Content) == 0 {
			rendered = append(rendered, openaiMessage{Role: message.Role, Content: message.Text})
			continue
		}
		if message.Role == "tool" {
			// One message per result. A turn where the model called several tools has
			// several results, and every one has to come back under its own call id.
			for _, block := range message.Content {
				for _, result := range block.Results {
					rendered = append(rendered, openaiMessage{
						Role: "tool", ToolCallID: result.ID, Content: result.Content,
					})
				}
			}
			continue
		}
		text := ""
		calls := []openaiToolCall{}
		for _, block := range message.Content {
			switch block.Kind {
			case "text":
				text += block.Text
			case "tool-use":
				arguments := string(block.Args)
				if arguments == "" {
					arguments = "{}"
				}
				calls = append(calls, openaiToolCall{
					ID: block.ID, Type: "function",
					Function: openaiToolCallBody{Name: block.Name, Arguments: arguments},
				})
			}
		}
		rendered = append(rendered, openaiMessage{
			Role: message.Role, Content: text, ToolCalls: calls,
		})
	}
	return rendered
}

type openaiResponse struct {
	Choices []struct {
		Message struct {
			Content   string           `json:"content"`
			ToolCalls []openaiToolCall `json:"tool_calls"`
		} `json:"message"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage struct {
		Prompt       int64 `json:"prompt_tokens"`
		Completion   int64 `json:"completion_tokens"`
		PromptDetail struct {
			Cached int64 `json:"cached_tokens"`
		} `json:"prompt_tokens_details"`
	} `json:"usage"`
}

func openaiNormalize(decoded openaiResponse, request LlmRequest) LlmResponse {
	text := ""
	finish := ""
	calls := []LlmToolCall{}
	if len(decoded.Choices) > 0 {
		choice := decoded.Choices[0]
		text = choice.Message.Content
		finish = choice.FinishReason
		for _, call := range choice.Message.ToolCalls {
			arguments := call.Function.Arguments
			if arguments == "" {
				arguments = "{}"
			}
			if !json.Valid([]byte(arguments)) {
				panic("openai: tool arguments were not valid JSON: " + strconv.Quote(arguments))
			}
			calls = append(calls, LlmToolCall{
				ID: call.ID, Name: call.Function.Name, Args: json.RawMessage(arguments),
			})
		}
	}
	deliverWholeReply(request, text)
	return LlmResponse{
		Text: text,
		Usage: LlmUsage{
			Input:     tokenCount(decoded.Usage.Prompt),
			Output:    tokenCount(decoded.Usage.Completion),
			CacheRead: tokenCount(decoded.Usage.PromptDetail.Cached),
		},
		ToolCalls:  calls,
		StopReason: openaiStopReason(finish, len(calls) > 0),
	}
}

func openaiStopReason(finish string, hasTools bool) string {
	if hasTools {
		return "tool-use"
	}
	switch finish {
	case "stop":
		return "end-turn"
	case "tool_calls":
		return "tool-use"
	case "length":
		return "max-tokens"
	case "content_filter":
		return "refusal"
	default:
		return "other"
	}
}
