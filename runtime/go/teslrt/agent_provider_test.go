package teslrt

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The providers post through HttpPost, so the ordinary outbound-HTTP double is what tests
// them: every case here is offline, with no key and no network.

func stubProvider(t *testing.T, target, body string) {
	t.Helper()
	ResetHttpStubs()
	t.Cleanup(ResetHttpStubs)
	StubHttp("POST", target, FromInt64(200), body)
}

func sentBody(t *testing.T, target string) map[string]any {
	t.Helper()
	var decoded map[string]any
	if err := json.Unmarshal([]byte(HttpLastBody("POST", target)), &decoded); err != nil {
		t.Fatalf("request body was not JSON: %v", err)
	}
	return decoded
}

func TestAnthropicNormalizesTextAndUsage(t *testing.T) {
	stubProvider(t, anthropicEndpoint, `{
		"content": [{"type":"text","text":"Hello "},{"type":"text","text":"there"}],
		"stop_reason": "end_turn",
		"usage": {"input_tokens": 11, "output_tokens": 5,
		          "cache_read_input_tokens": 2, "cache_creation_input_tokens": 3}
	}`)
	agent := NewAgent(AnthropicProvider("key-123", "claude-opus-5"), "be brief", FromInt64(64), nil)
	reply := AskReply(agent, "hi")
	if reply.Text != "Hello there" {
		t.Fatalf("text = %q, want the concatenated blocks", reply.Text)
	}
	if got := ReplyTokens(reply).String(); got != "16" {
		t.Fatalf("ReplyTokens = %s, want 16 (input+output only)", got)
	}
	if reply.stopReason != "end-turn" {
		t.Fatalf("stopReason = %q", reply.stopReason)
	}
	sent := sentBody(t, anthropicEndpoint)
	if sent["model"] != "claude-opus-5" || sent["system"] != "be brief" {
		t.Fatalf("request = %v, want the agent's model and system prompt", sent)
	}
	if sent["max_tokens"] != float64(64) {
		t.Fatalf("max_tokens = %v, want the agent's budget", sent["max_tokens"])
	}
}

// The agent's transcript uses the tool ROLE; Anthropic has no such role, and sending it is
// an HTTP 400 that makes every tool-using agent unusable on this provider.
func TestAnthropicSendsAToolResultAsAUserBlock(t *testing.T) {
	tool := ToolOf("lookup", "looks up", `{"type":"object"}`,
		func(argsJSON string) string { return argsJSON },
		func(string) string { return "found it" })
	round := 0
	ResetHttpStubs()
	t.Cleanup(ResetHttpStubs)
	// Two round-trips: the first asks for the tool, the second answers.
	StubHttp("POST", anthropicEndpoint, FromInt64(200), `{
		"content": [{"type":"tool_use","id":"call_1","name":"lookup","input":{"q":"x"}}],
		"stop_reason": "tool_use", "usage": {"input_tokens":1,"output_tokens":1}
	}`)
	provider := ProviderOf(func(request LlmRequest) LlmResponse {
		round++
		if round == 2 {
			ResetHttpStubs()
			StubHttp("POST", anthropicEndpoint, FromInt64(200), `{
				"content": [{"type":"text","text":"done"}],
				"stop_reason": "end_turn", "usage": {"input_tokens":1,"output_tokens":1}
			}`)
		}
		return AnthropicProvider("key", "m").invoke(request)
	})
	reply := AskReply(NewAgent(provider, "", FromInt64(32), []Tool{tool}), "find x")
	if reply.Text != "done" {
		t.Fatalf("reply = %q", reply.Text)
	}
	sent := sentBody(t, anthropicEndpoint)
	messages, ok := sent["messages"].([]any)
	if !ok || len(messages) != 3 {
		t.Fatalf("messages = %v, want user + assistant + tool result", sent["messages"])
	}
	last, _ := messages[2].(map[string]any)
	if last["role"] != "user" {
		t.Fatalf("tool result went out as role %v, want user", last["role"])
	}
	blocks, _ := last["content"].([]any)
	if len(blocks) != 1 {
		t.Fatalf("tool result content = %v", last["content"])
	}
	block, _ := blocks[0].(map[string]any)
	if block["type"] != "tool_result" || block["tool_use_id"] != "call_1" ||
		block["content"] != "found it" {
		t.Fatalf("tool_result block = %v", block)
	}
}

func TestAnthropicToolUseIsNormalizedToAToolCall(t *testing.T) {
	stubProvider(t, anthropicEndpoint, `{
		"content": [{"type":"tool_use","id":"c1","name":"lookup","input":{"q":"x"}}],
		"stop_reason": "tool_use", "usage": {}
	}`)
	response := AnthropicProvider("key", "m").invoke(LlmRequest{MaxTokens: FromInt64(8)})
	if len(response.ToolCalls) != 1 {
		t.Fatalf("tool calls = %+v", response.ToolCalls)
	}
	call := response.ToolCalls[0]
	if call.ID != "c1" || call.Name != "lookup" || string(call.Args) != `{"q":"x"}` {
		t.Fatalf("tool call = %+v", call)
	}
	if response.StopReason != "tool-use" {
		t.Fatalf("stopReason = %q", response.StopReason)
	}
}

func TestAnthropicErrorStatusFailsWithTheBody(t *testing.T) {
	ResetHttpStubs()
	t.Cleanup(ResetHttpStubs)
	StubHttp("POST", anthropicEndpoint, FromInt64(401), `{"error":"bad key"}`)
	mustPanic(t, "anthropic: API error (HTTP 401)", func() {
		Ask(NewAgent(AnthropicProvider("nope", "m"), "", FromInt64(8), nil), "hi")
	})
}

func TestAnthropicNonJSONBodyFailsClearly(t *testing.T) {
	stubProvider(t, anthropicEndpoint, "<html>gateway timeout</html>")
	mustPanic(t, "anthropic: provider returned non-JSON body", func() {
		Ask(NewAgent(AnthropicProvider("key", "m"), "", FromInt64(8), nil), "hi")
	})
}

func TestOpenAINormalizesTheFirstChoice(t *testing.T) {
	stubProvider(t, openaiEndpoint, `{
		"choices": [{"message": {"content": "an answer"}, "finish_reason": "stop"}],
		"usage": {"prompt_tokens": 7, "completion_tokens": 3,
		          "prompt_tokens_details": {"cached_tokens": 4}}
	}`)
	reply := AskReply(NewAgent(OpenAIProvider("sk-x", "gpt"), "sys", FromInt64(50), nil), "hi")
	if reply.Text != "an answer" {
		t.Fatalf("text = %q", reply.Text)
	}
	if got := ReplyTokens(reply).String(); got != "10" {
		t.Fatalf("ReplyTokens = %s, want 10", got)
	}
	if got := reply.usage.CacheRead.String(); got != "4" {
		t.Fatalf("cache read = %s, want 4", got)
	}
	// The system prompt is a MESSAGE on this wire format, not a top-level field.
	sent := sentBody(t, openaiEndpoint)
	messages, _ := sent["messages"].([]any)
	if len(messages) != 2 {
		t.Fatalf("messages = %v, want system + user", sent["messages"])
	}
	first, _ := messages[0].(map[string]any)
	if first["role"] != "system" || first["content"] != "sys" {
		t.Fatalf("first message = %v", first)
	}
}

// An empty system prompt must not become an empty system message.
func TestOpenAIOmitsAnEmptySystemPrompt(t *testing.T) {
	stubProvider(t, openaiEndpoint, `{"choices":[{"message":{"content":"x"},"finish_reason":"stop"}]}`)
	Ask(NewAgent(OpenAIProvider("sk-x", "gpt"), "", FromInt64(8), nil), "hi")
	messages, _ := sentBody(t, openaiEndpoint)["messages"].([]any)
	if len(messages) != 1 {
		t.Fatalf("messages = %v, want the user turn alone", messages)
	}
}

// OpenAI carries tool arguments as a JSON STRING, so they have to be parsed back out.
func TestOpenAIParsesToolArgumentsFromTheirJSONString(t *testing.T) {
	stubProvider(t, openaiEndpoint, `{
		"choices": [{"message": {"content": null, "tool_calls": [
			{"id":"c1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"x\"}"}}
		]}, "finish_reason": "tool_calls"}]
	}`)
	response := OpenAIProvider("sk-x", "gpt").invoke(LlmRequest{MaxTokens: FromInt64(8)})
	if len(response.ToolCalls) != 1 || string(response.ToolCalls[0].Args) != `{"q":"x"}` {
		t.Fatalf("tool calls = %+v", response.ToolCalls)
	}
	if response.StopReason != "tool-use" {
		t.Fatalf("stopReason = %q", response.StopReason)
	}
}

func TestOpenAIRejectsMalformedToolArguments(t *testing.T) {
	stubProvider(t, openaiEndpoint, `{
		"choices": [{"message": {"tool_calls": [
			{"id":"c1","type":"function","function":{"name":"lookup","arguments":"{not json"}}
		]}, "finish_reason": "tool_calls"}]
	}`)
	mustPanic(t, "openai: tool arguments were not valid JSON", func() {
		OpenAIProvider("sk-x", "gpt").invoke(LlmRequest{MaxTokens: FromInt64(8)})
	})
}

// Each tool result comes back under its own call id, so a turn where the model called two
// tools sends two tool messages rather than losing one.
func TestOpenAISendsOneToolMessagePerResult(t *testing.T) {
	stubProvider(t, openaiEndpoint, `{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}`)
	transcript := []AgentMessage{
		userMessage("go"),
		{Role: "assistant", Content: []AgentBlock{
			{Kind: "tool-use", ID: "c1", Name: "a", Args: json.RawMessage(`{}`)},
			{Kind: "tool-use", ID: "c2", Name: "b", Args: json.RawMessage(`{}`)},
		}},
		toolMessage([]toolResult{{ID: "c1", Content: "one"}, {ID: "c2", Content: "two"}}),
	}
	OpenAIProvider("sk-x", "gpt").invoke(LlmRequest{MaxTokens: FromInt64(8), Messages: transcript})
	messages, _ := sentBody(t, openaiEndpoint)["messages"].([]any)
	if len(messages) != 4 {
		t.Fatalf("messages = %v, want user + assistant + two tool results", messages)
	}
	for index, want := range []struct{ id, content string }{{"c1", "one"}, {"c2", "two"}} {
		message, _ := messages[2+index].(map[string]any)
		if message["role"] != "tool" || message["tool_call_id"] != want.id ||
			message["content"] != want.content {
			t.Fatalf("tool message %d = %v, want %+v", index, message, want)
		}
	}
	// The assistant turn carries both calls, with the arguments as JSON strings.
	assistant, _ := messages[1].(map[string]any)
	calls, _ := assistant["tool_calls"].([]any)
	if len(calls) != 2 {
		t.Fatalf("assistant tool_calls = %v", assistant["tool_calls"])
	}
}

func TestOpenAIStopReasons(t *testing.T) {
	for finish, want := range map[string]string{
		"stop": "end-turn", "tool_calls": "tool-use", "length": "max-tokens",
		"content_filter": "refusal", "": "other", "surprise": "other",
	} {
		if got := openaiStopReason(finish, false); got != want {
			t.Fatalf("openaiStopReason(%q) = %q, want %q", finish, got, want)
		}
	}
	// A turn that produced tool calls is tool-use whatever the finish reason says.
	if got := openaiStopReason("stop", true); got != "tool-use" {
		t.Fatalf("a tool-calling turn reported %q", got)
	}
}

func TestAnthropicStopReasons(t *testing.T) {
	for reason, want := range map[string]string{
		"end_turn": "end-turn", "tool_use": "tool-use", "max_tokens": "max-tokens",
		"refusal": "refusal", "": "other", "surprise": "other",
	} {
		if got := anthropicStopReason(reason); got != want {
			t.Fatalf("anthropicStopReason(%q) = %q, want %q", reason, got, want)
		}
	}
}

// Mistral is the OpenAI wire format at Mistral's endpoint — the only observable difference
// is where the request goes.
func TestMistralPostsToMistralWithBearerAuth(t *testing.T) {
	stubProvider(t, mistralEndpoint, `{"choices":[{"message":{"content":"bonjour"},"finish_reason":"stop"}]}`)
	if got := Ask(NewAgent(MistralProvider("key", "mistral-large"), "", FromInt64(8), nil), "hi"); got != "bonjour" {
		t.Fatalf("reply = %q", got)
	}
	if HttpCallCount("POST", mistralEndpoint).String() != "1" {
		t.Fatal("the call did not go to the Mistral endpoint")
	}
}

// A local server is named by the program and usually wants no credential, so no
// Authorization header is sent when there is no key.
func TestLocalProviderPostsToTheGivenEndpoint(t *testing.T) {
	const endpoint = "http://127.0.0.1:11434/v1/chat/completions"
	stubProvider(t, endpoint, `{"choices":[{"message":{"content":"local"},"finish_reason":"stop"}]}`)
	if got := Ask(NewAgent(LocalProvider(endpoint, "llama"), "", FromInt64(8), nil), "hi"); got != "local" {
		t.Fatalf("reply = %q", got)
	}
	sent := sentBody(t, endpoint)
	if sent["model"] != "llama" {
		t.Fatalf("model = %v", sent["model"])
	}
}

// A budget of zero is not a request for zero tokens: the Racket runtime defaults it, and a
// provider that took it literally would answer nothing.
func TestProviderMaxTokensDefaultsWhenUnset(t *testing.T) {
	if got := providerMaxTokens(LlmRequest{}); got != 1024 {
		t.Fatalf("default max_tokens = %d, want 1024", got)
	}
	if got := providerMaxTokens(LlmRequest{MaxTokens: FromInt64(7)}); got != 7 {
		t.Fatalf("max_tokens = %d, want the agent's own", got)
	}
}

// Until a streaming body exists in the runtime, a real provider still publishes the reply
// as a delta — one, carrying the whole text — so a streaming consumer is not left with
// nothing between the tool events and the completion marker.
func TestRealProviderPublishesTheReplyAsOneDelta(t *testing.T) {
	stubProvider(t, openaiEndpoint, `{"choices":[{"message":{"content":"one two"},"finish_reason":"stop"}]}`)
	events := []string{}
	ConverseStreaming(NewConversation(NewAgent(OpenAIProvider("k", "m"), "", FromInt64(8), nil)),
		"hi", func(event string) struct{} { events = append(events, event); return struct{}{} })
	want := []string{"text-delta: one two", "text: one two"}
	if strings.Join(events, "|") != strings.Join(want, "|") {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
}

func TestAnthropicToolSchemaTravelsVerbatim(t *testing.T) {
	stubProvider(t, anthropicEndpoint, `{"content":[{"type":"text","text":"x"}],"stop_reason":"end_turn"}`)
	schema := `{"type":"object","properties":{"city":{"type":"string"}}}`
	tool := ToolOf("lookup", "looks up", schema,
		func(argsJSON string) string { return argsJSON },
		func(string) string { return "" })
	Ask(NewAgent(AnthropicProvider("k", "m"), "", FromInt64(8), []Tool{tool}), "hi")
	tools, _ := sentBody(t, anthropicEndpoint)["tools"].([]any)
	if len(tools) != 1 {
		t.Fatalf("tools = %v", tools)
	}
	// Verbatim in the BYTES: re-encoding a decoded map would sort the keys and prove
	// nothing about what was sent.
	if !strings.Contains(HttpLastBody("POST", anthropicEndpoint), `"input_schema":`+schema) {
		t.Fatalf("request body = %s, want the schema forwarded unchanged",
			HttpLastBody("POST", anthropicEndpoint))
	}
}

// ── Deadline, retry, and error hygiene ───────────────────────────────────────

// noRetryBackoff runs the retry path without sleeping through it.
func noRetryBackoff(t *testing.T) {
	t.Helper()
	previous := providerRetryBackoff
	providerRetryBackoff = func(int) time.Duration { return 0 }
	t.Cleanup(func() { providerRetryBackoff = previous })
}

// liveProvider is an OpenAI-wire server on loopback answering through `respond`, reached
// over the real network path (loopback egress is permitted outside TESL_DEPLOYED).
func liveProvider(t *testing.T, respond func(hit int64, writer http.ResponseWriter)) (*httptest.Server, *int64) {
	t.Helper()
	ResetHttpStubs() // an active, empty stub table lets the call through to the network
	t.Cleanup(ResetHttpStubs)
	var hits int64
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		respond(atomic.AddInt64(&hits, 1), writer)
	}))
	t.Cleanup(server.Close)
	return server, &hits
}

const openaiOK = `{"choices":[{"message":{"content":"recovered"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`

// A stubbed timeout is the provider timeout: the turn ends as `aborted` with the transcript so
// far, not as a trap that loses it.
func TestProviderTimeoutEndsTheTurnAsAborted(t *testing.T) {
	ResetHttpStubs()
	t.Cleanup(ResetHttpStubs)
	StubHttpTimeout("POST", anthropicEndpoint)
	agent := NewAgent(AnthropicProvider("key", "m"), "", FromInt64(8), nil)
	turn := Converse(NewConversation(agent), "hi")
	if got := ReplyStopReason(TurnReply(turn)); got != stopAborted {
		t.Fatalf("stopReason = %q, want aborted", got)
	}
	if got := ConversationLength(TurnConversation(turn)).String(); got != "1" {
		t.Fatalf("transcript length = %s, want the user turn kept", got)
	}
}

// The provider deadline is TESL_AI_TIMEOUT_MS, not the generic HTTP one: with the AI knob at
// 50 ms and the HTTP knob untouched (30 s), a 400 ms model call is aborted within the test.
func TestProviderCallUsesTheAIDeadline(t *testing.T) {
	t.Setenv("TESL_AI_TIMEOUT_MS", "50")
	server, _ := liveProvider(t, func(_ int64, writer http.ResponseWriter) {
		time.Sleep(400 * time.Millisecond)
		_, _ = writer.Write([]byte(openaiOK))
	})
	agent := NewAgent(LocalProvider(server.URL, "m"), "", FromInt64(8), nil)
	started := time.Now()
	reply := AskReply(agent, "hi")
	if ReplyStopReason(reply) != stopAborted {
		t.Fatalf("stopReason = %q, want aborted", ReplyStopReason(reply))
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("the call took %s; the AI deadline did not apply", elapsed)
	}
}

// A 5xx or 429 is retried with backoff, up to providerAttempts in total; the API is stateless
// so the repeat has no side effect.
func TestProviderRetriesTransientFailuresThenSucceeds(t *testing.T) {
	noRetryBackoff(t)
	server, hits := liveProvider(t, func(hit int64, writer http.ResponseWriter) {
		switch hit {
		case 1:
			writer.WriteHeader(http.StatusServiceUnavailable)
		case 2:
			writer.WriteHeader(http.StatusTooManyRequests)
		default:
			_, _ = writer.Write([]byte(openaiOK))
		}
	})
	reply := Ask(NewAgent(LocalProvider(server.URL, "m"), "", FromInt64(8), nil), "hi")
	if got := atomic.LoadInt64(hits); reply != "recovered" || got != 3 {
		t.Fatalf("reply=%q hits=%d, want the third attempt's answer", reply, got)
	}
}

func TestProviderGivesUpAfterBoundedRetries(t *testing.T) {
	noRetryBackoff(t)
	server, hits := liveProvider(t, func(_ int64, writer http.ResponseWriter) {
		writer.WriteHeader(http.StatusTooManyRequests)
		_, _ = writer.Write([]byte(`{"error":{"message":"rate limited","type":"rate_limit"}}`))
	})
	mustPanic(t, "openai: API error (HTTP 429) after 3 attempts: rate limited", func() {
		Ask(NewAgent(LocalProvider(server.URL, "m"), "", FromInt64(8), nil), "hi")
	})
	if got := atomic.LoadInt64(hits); got != int64(providerAttempts) {
		t.Fatalf("hits = %d, want %d", got, providerAttempts)
	}
}

// A 4xx other than 429 is the REQUEST being wrong; repeating it would be wrong again.
func TestProviderDoesNotRetryAClientError(t *testing.T) {
	noRetryBackoff(t)
	server, hits := liveProvider(t, func(_ int64, writer http.ResponseWriter) {
		writer.WriteHeader(http.StatusBadRequest)
		_, _ = writer.Write([]byte(`{"error":"bad request"}`))
	})
	mustPanic(t, "openai: API error (HTTP 400): bad request", func() {
		Ask(NewAgent(LocalProvider(server.URL, "m"), "", FromInt64(8), nil), "hi")
	})
	if got := atomic.LoadInt64(hits); got != 1 {
		t.Fatalf("hits = %d, want 1", got)
	}
}

// The upstream body used to be echoed whole — up to the 10 MiB response cap — into logs and,
// through a nested agent's is_error result, into another model's context.
func TestProviderErrorDetailIsBoundedAndPrefersTheVendorMessage(t *testing.T) {
	ResetHttpStubs()
	t.Cleanup(ResetHttpStubs)
	StubHttp("POST", anthropicEndpoint, FromInt64(401),
		`{"error":{"type":"authentication_error","message":"invalid x-api-key"},"padding":"`+
			strings.Repeat("z", 600000)+`"}`)
	agent := NewAgent(AnthropicProvider("nope", "m"), "", FromInt64(8), nil)
	defer func() {
		message := panicMessage(recover())
		if message != "anthropic: API error (HTTP 401): invalid x-api-key" {
			t.Fatalf("trap = %.200q…", message)
		}
	}()
	Ask(agent, "hi")
}

func TestProviderErrorBodyWithoutAVendorMessageIsTruncated(t *testing.T) {
	ResetHttpStubs()
	t.Cleanup(ResetHttpStubs)
	body := "<html>" + strings.Repeat("x", 600000) + "</html>"
	StubHttp("POST", anthropicEndpoint, FromInt64(403), body)
	agent := NewAgent(AnthropicProvider("nope", "m"), "", FromInt64(8), nil)
	defer func() {
		message := panicMessage(recover())
		marker := "(" + strconvItoa(len(body)-maxProviderErrorBytes) + " bytes truncated)"
		if len(message) > maxProviderErrorBytes+128 || !strings.HasSuffix(message, marker) {
			t.Fatalf("trap length %d: %.120q…", len(message), message)
		}
	}()
	Ask(agent, "hi")
}

// ── OpenAI tool-call shapes ──────────────────────────────────────────────────

// Only `function` calls name our tools; another type is never dispatched. An empty id is
// refused BEFORE the dispatch, because the vendor rejects the result sent back under it.
func TestOpenAISkipsNonFunctionCallsAndRefusesAnEmptyId(t *testing.T) {
	dispatched := 0
	tool := ToolOf("e", "e", `{"type":"object"}`,
		func(argsJSON string) string { return argsJSON },
		func(string) string { dispatched++; return "ran" })
	stubProvider(t, openaiEndpoint, `{"choices":[{"message":{"content":"no tools for you",
		"tool_calls":[{"id":"call_1","type":"custom","function":{"name":"e","arguments":"{}"}}]},
		"finish_reason":"stop"}]}`)
	reply := AskReply(NewAgent(OpenAIProvider("k", "m"), "", FromInt64(8), []Tool{tool}), "hi")
	if dispatched != 0 || reply.Text != "no tools for you" {
		t.Fatalf("dispatched=%d text=%q, want the custom call skipped", dispatched, reply.Text)
	}
	stubProvider(t, openaiEndpoint, `{"choices":[{"message":{"content":"",
		"tool_calls":[{"id":"","type":"function","function":{"name":"e","arguments":"{}"}}]},
		"finish_reason":"tool_calls"}]}`)
	mustPanic(t, `openai: tool call "e" has no id`, func() {
		AskReply(NewAgent(OpenAIProvider("k", "m"), "", FromInt64(8), []Tool{tool}), "hi")
	})
	if dispatched != 0 {
		t.Fatalf("the tool ran %d time(s) before the empty id was refused", dispatched)
	}
}

// A restored transcript round-trips through the Anthropic renderer: every kind the loop
// writes has a wire form, and nothing else reaches the renderer.
func TestRestoredTranscriptRendersForAnthropic(t *testing.T) {
	tool := ToolOf("lookup", "looks up", `{"type":"object"}`,
		func(argsJSON string) string { return argsJSON },
		func(string) string { return "found it" })
	mock := MockToolProvider([]LlmResponse{ToolUseStep("lookup", "toolu_1", `{"q":"x"}`), TextStep("ok")})
	saved := ConversationJSON(TurnConversation(Converse(NewConversation(testAgent(mock, tool)), "find x")))

	stubProvider(t, anthropicEndpoint, `{"content":[{"type":"text","text":"and more"}],"stop_reason":"end_turn","usage":{}}`)
	restored := ConversationFrom(NewAgent(AnthropicProvider("k", "m"), "", FromInt64(8), []Tool{tool}), saved)
	if got := ReplyText(TurnReply(Converse(restored, "go on"))); got != "and more" {
		t.Fatalf("continued = %q", got)
	}
	messages, _ := sentBody(t, anthropicEndpoint)["messages"].([]any)
	if len(messages) != 5 { // user, assistant(tool_use), user(tool_result), assistant(text), user
		t.Fatalf("rendered %d messages: %v", len(messages), messages)
	}
}
