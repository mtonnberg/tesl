package teslrt

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// The real LLM providers.
//
// Each one is a translation layer and nothing more: it renders the normalised request
// (agent.go) into a vendor's wire format, posts it through providerHTTPPost — the outbound
// path of httpclient.go under the provider's own deadline, so the network is gated by
// `httpClient`, judged by the SSRF containment, and interceptable by the same `stubHttp`
// double every other outbound call is — and normalises the answer back. The agent loop
// never learns which vendor it is talking to.
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

// ── The provider round-trip ──────────────────────────────────────────────────
//
// An LLM call is not an ordinary outbound call. A Messages API response of a few thousand
// tokens routinely takes longer than TESL_HTTP_TIMEOUT_MS (30 s), and raising that knob for
// the model would widen the deadline of every other egress in the program. So the provider
// path has its own deadline, TESL_AI_TIMEOUT_MS (default 120000), and reaches the network
// through the SAME pieces httpclient.go's verbs use — URL parsing, the CR/LF header guard,
// the `stubHttp` double, the per-host transport that carries the SSRF egress judgement and
// the TLS policy, and the response-body cap. Only the deadline differs; nothing about what
// the call may reach does.
//
// A 429 or a 5xx is retried a bounded number of times with backoff: the API is stateless,
// so a repeated request has no side effect, and a transient upstream fault should not end
// a turn that already ran tools. A 4xx other than 429 is not retried — it is the request
// that is wrong, and the same request will be wrong again.

func aiTimeoutMs() int { return envPositiveInt("TESL_AI_TIMEOUT_MS", 120000) }

// providerAttempts is the total number of tries for one round-trip: the first call and
// two retries.
const providerAttempts = 3

// providerRetryBackoff is the pause before retry number `retry` (1-based). A variable so the
// runtime's tests can run the retry path without sleeping through it.
var providerRetryBackoff = func(retry int) time.Duration {
	return time.Duration(retry) * 500 * time.Millisecond
}

// maxProviderErrorBytes bounds how much of an upstream error body is echoed into the trap.
// The whole body — up to the 10 MiB response cap — went into logs, telemetry, and, when the
// agent was itself a tool, back into another model's context.
const maxProviderErrorBytes = 2048

func providerPost(who, endpoint string, headers []Tuple2[string, string], body any) string {
	encoded, err := json.Marshal(body)
	if err != nil {
		panic(who + ": request could not be encoded: " + err.Error())
	}
	for attempt := 1; ; attempt++ {
		response := providerHTTPPost(who, endpoint, headers, string(encoded))
		status, exact := response.Status.Int64()
		if exact && status < 400 {
			return response.Body
		}
		retryable := exact && (status == http.StatusTooManyRequests || status >= 500)
		if retryable && attempt < providerAttempts {
			time.Sleep(providerRetryBackoff(attempt))
			continue
		}
		attempts := ""
		if attempt > 1 {
			attempts = fmt.Sprintf(" after %d attempts", attempt)
		}
		panic(fmt.Sprintf("%s: API error (HTTP %s)%s: %s", who, response.Status.String(), attempts,
			providerErrorDetail(response.Body)))
	}
}

// providerErrorDetail is what a failed call reports about the upstream body: the vendor's
// own `error.message` when the body has one (every provider here wraps errors that way),
// otherwise the body itself, cut to maxProviderErrorBytes.
func providerErrorDetail(body string) string {
	var envelope struct {
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal([]byte(body), &envelope) == nil && len(envelope.Error) > 0 {
		var structured struct {
			Message string `json:"message"`
		}
		if json.Unmarshal(envelope.Error, &structured) == nil && structured.Message != "" {
			return truncateProviderText(structured.Message)
		}
		var plain string
		if json.Unmarshal(envelope.Error, &plain) == nil && plain != "" {
			return truncateProviderText(plain)
		}
	}
	return truncateProviderText(body)
}

func truncateProviderText(text string) string {
	if len(text) <= maxProviderErrorBytes {
		return text
	}
	return text[:maxProviderErrorBytes] + fmt.Sprintf("… (%d bytes truncated)",
		len(text)-maxProviderErrorBytes)
}

// providerHTTPPost is one POST to the provider under the AI deadline. It mirrors
// httpRequest/httpRequestNetwork step for step so the two cannot drift in what they permit;
// the one thing it does differently is the client timeout.
func providerHTTPPost(who, endpoint string, headers []Tuple2[string, string], body string) HttpResponse {
	parsed := parseOutboundURL(endpoint)
	wire, secretHeaders := outboundHeaders(headers)
	if answer, stubbed := stubbedProviderAnswer(who, endpoint, body); stubbed {
		return answer
	}
	request, err := http.NewRequest(http.MethodPost, endpoint, strings.NewReader(body))
	if err != nil {
		panic(fmt.Sprintf("%s: HTTP POST to %s failed: %s", who, endpoint, err.Error()))
	}
	request.Header = wire
	if telemetryTraceEnabled() && request.Header.Get("traceparent") == "" {
		request.Header.Set("traceparent", "00-"+telemetryID(16)+"-"+telemetryID(8)+"-01")
	}
	client := &http.Client{
		Transport: outboundTransport(parsed.Hostname()),
		Timeout:   millisDuration(aiTimeoutMs()),
		// A vendor endpoint is a fixed URL and the API key rides in its headers, so no
		// redirect is followed at all — the same policy the SSO legs use.
		CheckRedirect: redirectCheck(redirectRefused, parsed, secretHeaders),
	}
	response, err := client.Do(request)
	if err != nil {
		// A connect timeout counts too: a vendor that cannot be reached and one that never
		// finishes answering leave the turn in the same state, worth answering as `aborted`.
		if isTimeout(err) {
			panic(providerTimeout{who: who, millis: aiTimeoutMs()})
		}
		panic(who + ": " + strings.TrimPrefix(requestFailure(http.MethodPost, endpoint, err), "HttpClient: "))
	}
	if response == nil {
		panic(fmt.Sprintf("%s: HTTP POST to %s failed: no response", who, endpoint))
	}
	defer func() { _ = response.Body.Close() }()
	limit := httpMaxResponseBytes()
	raw, err := io.ReadAll(io.LimitReader(response.Body, int64(limit)+1))
	if err != nil {
		if isTimeout(err) {
			panic(providerTimeout{who: who, millis: aiTimeoutMs()})
		}
		panic(fmt.Sprintf("%s: HTTP POST to %s failed: %s", who, endpoint, err.Error()))
	}
	if len(raw) > limit {
		panic(fmt.Sprintf("%s: response body exceeds the %d-byte cap", who, limit))
	}
	return HttpResponse{
		Status:  FromInt64(int64(response.StatusCode)),
		Body:    string(raw),
		Headers: responseHeaders(response.Header),
	}
}

// stubbedProviderAnswer consults the `stubHttp` table the way every outbound call does. A
// `stubHttpTimeout` rule raises the transport's timeout message; here that is re-raised as
// the provider timeout, so a test that stubs a slow model exercises the same `aborted` path
// a real deadline drives.
func stubbedProviderAnswer(who, endpoint, body string) (answer HttpResponse, stubbed bool) {
	defer func() {
		raised := recover()
		if raised == nil {
			return
		}
		if message, isText := raised.(string); isText && strings.Contains(message, " timed out after ") {
			panic(providerTimeout{who: who, millis: aiTimeoutMs()})
		}
		panic(raised)
	}()
	return httpStubAnswer(http.MethodPost, endpoint, &body)
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
				// Unreachable for a validated transcript: validateTranscript (agent.go) admits
				// only the three kinds above, at ConversationFrom and again at the top of
				// runLoop, so a poisoned row is rejected there with a message — it used to
				// trap HERE, on every later turn of that conversation. A block that somehow
				// still has no wire form contributes nothing rather than ending the turn.
				continue
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
			// Only a `function` call names one of OUR tools; any other type (a vendor's
			// built-in tool, say) is nothing this loop declared and nothing it may dispatch.
			// An absent type is tolerated: some OpenAI-compatible local servers omit it.
			if call.Type != "" && call.Type != "function" {
				continue
			}
			// The id is what the result is sent back under. With an empty one the tool
			// would run, and the vendor would then reject the next round-trip — the side
			// effect kept, the turn lost. Refusing before the dispatch is the fail-closed
			// order.
			if call.ID == "" {
				panic("openai: tool call " + strconv.Quote(call.Function.Name) +
					" has no id — the result could not be returned to the model")
			}
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
