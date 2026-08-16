package teslrt

import (
	"encoding/json"
	"strings"
	"testing"
)

func testAgent(provider LlmProvider, tools ...Tool) Agent {
	return NewAgent(provider, "you are a test bot", FromInt64(128), tools)
}

func mustPanic(t *testing.T, want string, body func()) {
	t.Helper()
	defer func() {
		raised := recover()
		if raised == nil {
			t.Fatalf("expected a panic containing %q, got none", want)
		}
		if got := panicMessage(raised); !strings.Contains(got, want) {
			t.Fatalf("panic %q does not contain %q", got, want)
		}
	}()
	body()
}

func TestMockProviderWalksScriptByCallIndex(t *testing.T) {
	agent := testAgent(MockProvider([]string{"first", "second"}))
	if got := Ask(agent, "a"); got != "first" {
		t.Fatalf("first ask = %q, want %q", got, "first")
	}
	if got := Ask(agent, "b"); got != "second" {
		t.Fatalf("second ask = %q, want %q", got, "second")
	}
}

// The script is per-provider, not per-agent: two agents built from the SAME provider
// value share one cursor, which is what makes a BYOK override observable.
func TestMockProviderExhaustionTraps(t *testing.T) {
	agent := testAgent(MockProvider([]string{"only one"}))
	Ask(agent, "a")
	mustPanic(t, "mockProvider: exhausted", func() { Ask(agent, "b") })
}

func TestAskWithOverridesTheAgentProvider(t *testing.T) {
	agent := testAgent(MockProvider([]string{"default reply"}))
	reply := AskWith(agent, "hi", MockProvider([]string{"override reply"}))
	if reply.Text != "override reply" {
		t.Fatalf("AskWith = %q, want the override", reply.Text)
	}
	// The agent's own provider was never called, so its script is still intact.
	if got := Ask(agent, "hi"); got != "default reply" {
		t.Fatalf("agent provider = %q, want it untouched", got)
	}
}

func TestReplyTokensSumsInputAndOutputAcrossTheLoop(t *testing.T) {
	tool := ToolOf("echo", "echo", `{"type":"object"}`,
		func(argsJSON string) string { return argsJSON },
		func(args string) string { return "echoed " + args })
	provider := MockToolProvider([]LlmResponse{
		ToolUseStep("echo", "call_1", `{"x":1}`),
		TextStep("done"),
	})
	reply := AskReply(testAgent(provider, tool), "go")
	// Two round-trips, each scripted with input 1 / output 1.
	if got := ReplyTokens(reply).String(); got != "4" {
		t.Fatalf("ReplyTokens = %s, want 4", got)
	}
	if got := ReplyToolCalls(reply).String(); got != "1" {
		t.Fatalf("ReplyToolCalls = %s, want 1", got)
	}
}

func TestToolLoopDispatchesWithValidatedArgs(t *testing.T) {
	type weatherArgs struct{ City string }
	dispatched := ""
	tool := ToolOf("get_weather", "look up the weather", `{"type":"object"}`,
		func(argsJSON string) weatherArgs {
			var decoded struct {
				City string `json:"city"`
			}
			if err := json.Unmarshal([]byte(argsJSON), &decoded); err != nil {
				panic("not json: " + err.Error())
			}
			if decoded.City == "" {
				panic("missing required argument: city")
			}
			return weatherArgs{City: decoded.City}
		},
		func(args weatherArgs) string {
			dispatched = args.City
			return "weather in " + args.City
		})
	provider := MockToolProvider([]LlmResponse{
		ToolUseStep("get_weather", "call_1", `{"city":"Malmo"}`),
		TextStep("It is sunny."),
	})
	reply := AskReply(testAgent(provider, tool), "weather?")
	if dispatched != "Malmo" {
		t.Fatalf("dispatch saw %q, want the validated city", dispatched)
	}
	if reply.Text != "It is sunny." {
		t.Fatalf("reply = %q", reply.Text)
	}
	if got := ReplyToolCalls(reply).String(); got != "1" {
		t.Fatalf("ReplyToolCalls = %s, want 1", got)
	}
}

// A validator that traps is a MODEL error, not a program error: the loop keeps going and
// the model gets to see why its arguments were rejected.
func TestMalformedToolArgsBecomeAnIsErrorResult(t *testing.T) {
	dispatched := false
	tool := ToolOf("get_weather", "look up the weather", "{}",
		func(string) string { panic("missing required argument: city") },
		func(string) string { dispatched = true; return "unreachable" })
	provider := MockToolProvider([]LlmResponse{
		ToolUseStep("get_weather", "call_1", `{"wrong":"field"}`),
		TextStep("Sorry, I could not look that up."),
	})
	agent := testAgent(provider, tool)
	reply, transcript := runLoop(agent, agent.Provider,
		[]AgentMessage{userMessage("weather?")}, nil, false)
	if dispatched {
		t.Fatal("dispatch ran despite invalid arguments")
	}
	if reply.Text != "Sorry, I could not look that up." {
		t.Fatalf("reply = %q — the loop did not continue", reply.Text)
	}
	if got := findToolResult(t, transcript); !got.IsError ||
		!strings.Contains(got.Content, "invalid arguments: missing required argument: city") {
		t.Fatalf("tool result = %+v, want an is_error carrying the validator message", got)
	}
}

// A dispatch that traps is contained the same way — one bad tool body must not lose the
// reply the model could still produce.
func TestFailingToolBodyBecomesAnIsErrorResult(t *testing.T) {
	tool := ToolOf("refund", "issue a refund", "{}",
		func(argsJSON string) string { return argsJSON },
		func(string) string { panic("refund not confirmed") })
	provider := MockToolProvider([]LlmResponse{
		ToolUseStep("refund", "call_1", "{}"),
		TextStep("I could not refund that."),
	})
	agent := testAgent(provider, tool)
	reply, transcript := runLoop(agent, agent.Provider,
		[]AgentMessage{userMessage("refund please")}, nil, false)
	if reply.Text != "I could not refund that." {
		t.Fatalf("reply = %q — the loop did not continue", reply.Text)
	}
	if got := findToolResult(t, transcript); !got.IsError ||
		!strings.Contains(got.Content, "tool failed: refund not confirmed") {
		t.Fatalf("tool result = %+v, want an is_error carrying the body's message", got)
	}
}

func TestUnknownToolIsReportedToTheModel(t *testing.T) {
	provider := MockToolProvider([]LlmResponse{
		ToolUseStep("no_such_tool", "call_1", "{}"),
		TextStep("ok"),
	})
	agent := testAgent(provider)
	_, transcript := runLoop(agent, agent.Provider,
		[]AgentMessage{userMessage("go")}, nil, false)
	if got := findToolResult(t, transcript); !got.IsError ||
		got.Content != "unknown tool: no_such_tool" {
		t.Fatalf("tool result = %+v, want the unknown-tool report", got)
	}
}

func findToolResult(t *testing.T, transcript []AgentMessage) toolResult {
	t.Helper()
	for _, message := range transcript {
		if message.Role != "tool" {
			continue
		}
		for _, block := range message.Content {
			if len(block.Results) > 0 {
				return block.Results[0]
			}
		}
	}
	t.Fatal("no tool result in the transcript")
	return toolResult{}
}

// A provider that never stops asking for tools must fail rather than spin.
func TestRunawayToolLoopIsBounded(t *testing.T) {
	tool := ToolOf("loop", "loops", "{}",
		func(argsJSON string) string { return argsJSON },
		func(string) string { return "again" })
	steps := make([]LlmResponse, 0, maxAgentIterations+1)
	for i := 0; i <= maxAgentIterations; i++ {
		steps = append(steps, ToolUseStep("loop", "call", "{}"))
	}
	agent := testAgent(MockToolProvider(steps), tool)
	mustPanic(t, "exceeded 16 iterations", func() { AskReply(agent, "go") })
}

func TestAgentRunPublishesOneEventPerStep(t *testing.T) {
	tool := ToolOf("lookup", "looks up", "{}",
		func(argsJSON string) string { return argsJSON },
		func(string) string { return "found" })
	provider := MockToolProvider([]LlmResponse{
		ToolUseStep("lookup", "call_1", "{}"),
		TextStep("all done"),
	})
	events := []string{}
	reply := AgentRun(testAgent(provider, tool), "go",
		func(event string) struct{} { events = append(events, event); return struct{}{} })
	if reply.Text != "all done" {
		t.Fatalf("reply = %q", reply.Text)
	}
	want := []string{"tool: lookup", "text: all done"}
	if len(events) != len(want) {
		t.Fatalf("events = %v, want %v", events, want)
	}
	for i, event := range want {
		if events[i] != event {
			t.Fatalf("events = %v, want %v", events, want)
		}
	}
}

func TestAgentRunRefusesANilPublisher(t *testing.T) {
	agent := testAgent(MockProvider([]string{"x"}))
	mustPanic(t, "agentRun: publisher", func() { AgentRun(agent, "go", nil) })
}

func TestAskForDecodesOnTheFirstReply(t *testing.T) {
	agent := testAgent(MockProvider([]string{`{"title":"All good"}`}))
	got := AskFor(agent, "summarize", decodeTitle, FromInt64(2))
	if got != "All good" {
		t.Fatalf("AskFor = %q", got)
	}
}

func TestAskForRetriesAfterADecodeFailure(t *testing.T) {
	agent := testAgent(MockProvider([]string{"not json at all", `{"title":"Recovered"}`}))
	got := AskFor(agent, "summarize", decodeTitle, FromInt64(2))
	if got != "Recovered" {
		t.Fatalf("AskFor = %q, want the retried reply", got)
	}
}

// Exhausting the retries fails like a body-validation failure, carrying the last decode
// error so the operator can see WHY the model never produced the shape.
func TestAskForFailsAfterExhaustingRetries(t *testing.T) {
	agent := testAgent(MockProvider([]string{"nope", "still nope"}))
	mustPanic(t, "did not decode after 1 retry", func() {
		AskFor(agent, "summarize", decodeTitle, FromInt64(1))
	})
}

// maxRetries 0 means one attempt and no retry — the plural in the message follows.
func TestAskForWithNoRetriesAsksOnce(t *testing.T) {
	agent := testAgent(MockProvider([]string{"nope"}))
	mustPanic(t, "did not decode after 0 retries", func() {
		AskFor(agent, "summarize", decodeTitle, FromInt64(0))
	})
}

// The retry prompt carries the decode error, which is what lets the model correct
// itself rather than repeating the same malformed reply.
func TestAskForFeedsTheDecodeErrorBackIntoThePrompt(t *testing.T) {
	prompts := []string{}
	provider := ProviderOf(func(request LlmRequest) LlmResponse {
		prompts = append(prompts, request.Messages[len(request.Messages)-1].Text)
		if len(prompts) == 1 {
			return TextStep("not json")
		}
		return TextStep(`{"title":"ok"}`)
	})
	AskFor(testAgent(provider), "summarize", decodeTitle, FromInt64(1))
	if len(prompts) != 2 {
		t.Fatalf("prompts = %v, want two attempts", prompts)
	}
	if !strings.Contains(prompts[1], "could not be parsed") ||
		!strings.HasPrefix(prompts[1], "summarize") {
		t.Fatalf("retry prompt = %q, want the original plus the decode error", prompts[1])
	}
}

func decodeTitle(text string) string {
	var decoded struct {
		Title string `json:"title"`
	}
	if err := json.Unmarshal([]byte(text), &decoded); err != nil {
		panic("not valid JSON: " + err.Error())
	}
	if decoded.Title == "" {
		panic("missing title")
	}
	return decoded.Title
}

// ── Conversation ─────────────────────────────────────────────────────────────

func TestConverseThreadsHistoryIntoTheNextTurn(t *testing.T) {
	seen := [][]AgentMessage{}
	provider := ProviderOf(func(request LlmRequest) LlmResponse {
		seen = append(seen, request.Messages)
		return TextStep([]string{"first reply", "second reply"}[len(seen)-1])
	})
	agent := testAgent(provider)

	turn1 := Converse(NewConversation(agent), "tell me about cats")
	if got := ReplyText(TurnReply(turn1)); got != "first reply" {
		t.Fatalf("turn 1 = %q", got)
	}
	conversation1 := TurnConversation(turn1)
	if got := ConversationLength(conversation1).String(); got != "2" {
		t.Fatalf("length after turn 1 = %s, want 2", got)
	}

	turn2 := Converse(conversation1, "what did I just ask?")
	if got := ReplyText(TurnReply(turn2)); got != "second reply" {
		t.Fatalf("turn 2 = %q", got)
	}
	if got := ConversationLength(TurnConversation(turn2)).String(); got != "4" {
		t.Fatalf("length after turn 2 = %s, want 4", got)
	}
	// Turn 2's request carried turn 1's user prompt AND its assistant reply.
	if len(seen[1]) != 3 {
		t.Fatalf("turn 2 saw %d messages, want 3", len(seen[1]))
	}
	if seen[1][0].Text != "tell me about cats" {
		t.Fatalf("turn 2 message 0 = %+v", seen[1][0])
	}
	if seen[1][1].Role != "assistant" || seen[1][1].Content[0].Text != "first reply" {
		t.Fatalf("turn 2 message 1 = %+v", seen[1][1])
	}
}

// Threading must not mutate the conversation it was given: branching a thread twice from
// the same point has to produce two independent continuations, not one that clobbers the
// other's backing array.
func TestConverseDoesNotMutateTheSourceConversation(t *testing.T) {
	agent := testAgent(MockProvider([]string{"a", "b", "c"}))
	base := TurnConversation(Converse(NewConversation(agent), "one"))
	branch1 := TurnConversation(Converse(base, "two"))
	branch2 := TurnConversation(Converse(base, "three"))
	if got := ConversationLength(base).String(); got != "2" {
		t.Fatalf("base grew to %s, want 2", got)
	}
	if branch1.messages[2].Text != "two" {
		t.Fatalf("branch 1 prompt = %q, want it undisturbed", branch1.messages[2].Text)
	}
	if branch2.messages[2].Text != "three" {
		t.Fatalf("branch 2 prompt = %q", branch2.messages[2].Text)
	}
}

func TestConversationJSONRoundTripsThroughConversationFrom(t *testing.T) {
	agent := testAgent(MockProvider([]string{"reply one", "reply two"}))
	conversation := TurnConversation(Converse(NewConversation(agent), "first question"))
	saved := ConversationJSON(conversation)
	if !strings.Contains(saved, "first question") || !strings.Contains(saved, "reply one") {
		t.Fatalf("serialized history = %s, want both turns legible", saved)
	}

	reloaded := ConversationFrom(agent, saved)
	if got := ConversationLength(reloaded).String(); got != "2" {
		t.Fatalf("reloaded length = %s, want 2", got)
	}
	turn := Converse(reloaded, "second question")
	if got := ReplyText(TurnReply(turn)); got != "reply two" {
		t.Fatalf("continued turn = %q", got)
	}
	if got := ConversationLength(TurnConversation(turn)).String(); got != "4" {
		t.Fatalf("length after continuing = %s, want 4", got)
	}
}

// A tool round-trip is part of the transcript, so the round trip has to survive the
// blocks a plain text turn never produces.
func TestConversationJSONRoundTripsAToolTurn(t *testing.T) {
	tool := ToolOf("lookup", "looks up", "{}",
		func(argsJSON string) string { return argsJSON },
		func(string) string { return "found it" })
	provider := MockToolProvider([]LlmResponse{
		ToolUseStep("lookup", "call_1", `{"q":"x"}`),
		TextStep("here you go"),
	})
	conversation := TurnConversation(Converse(NewConversation(testAgent(provider, tool)), "find x"))
	restored := ConversationFrom(testAgent(provider, tool), ConversationJSON(conversation))
	if len(restored.messages) != len(conversation.messages) {
		t.Fatalf("restored %d messages, want %d", len(restored.messages), len(conversation.messages))
	}
	if got := findToolResult(t, restored.messages); got.Content != "found it" {
		t.Fatalf("restored tool result = %+v", got)
	}
	// The scripted tool-use step carries no text, so the assistant turn is the tool-use
	// block alone.
	if got := restored.messages[1].Content[0]; got.Kind != "tool-use" ||
		string(got.Args) != `{"q":"x"}` {
		t.Fatalf("restored tool-use block = %+v", got)
	}
}

func TestConversationFromRejectsMalformedHistory(t *testing.T) {
	agent := testAgent(MockProvider(nil))
	mustPanic(t, "history is not valid JSON", func() {
		ConversationFrom(agent, "{not json")
	})
}

// An empty string is a conversation that was never saved, not a corrupt one — a program
// reading a fresh row must get an empty thread rather than a trap.
func TestConversationFromAcceptsAnEmptyHistory(t *testing.T) {
	agent := testAgent(MockProvider(nil))
	if got := ConversationLength(ConversationFrom(agent, "  ")).String(); got != "0" {
		t.Fatalf("empty history length = %s, want 0", got)
	}
}

// An empty conversation serialises as `[]`, not `null`: ConversationFrom accepts both,
// but a null in a database column reads as a mistake.
func TestConversationJSONOfAnEmptyThreadIsAnEmptyArray(t *testing.T) {
	if got := ConversationJSON(NewConversation(testAgent(MockProvider(nil)))); got != "[]" {
		t.Fatalf("empty history = %s, want []", got)
	}
}

func TestConverseStreamingEmitsDeltasThenTheCompleteText(t *testing.T) {
	agent := testAgent(MockProvider([]string{"hello there"}))
	events := []string{}
	turn := ConverseStreaming(NewConversation(agent), "hi",
		func(event string) struct{} { events = append(events, event); return struct{}{} })
	if got := ReplyText(TurnReply(turn)); got != "hello there" {
		t.Fatalf("reply = %q", got)
	}
	want := []string{"text-delta: hello", "text-delta:  ", "text-delta: there", "text: hello there"}
	if len(events) != len(want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
	for i, event := range want {
		if events[i] != event {
			t.Fatalf("events = %#v, want %#v", events, want)
		}
	}
}

// The deltas concatenate back to exactly the final text — a UI that renders them
// incrementally must not end up with different characters than the completion marker.
func TestStreamingDeltasReconstructTheReply(t *testing.T) {
	reply := "  leading and  doubled   spaces\ttabs\n"
	agent := testAgent(MockProvider([]string{reply}))
	rebuilt := strings.Builder{}
	ConverseStreaming(NewConversation(agent), "hi", func(event string) struct{} {
		if after, found := strings.CutPrefix(event, "text-delta: "); found {
			rebuilt.WriteString(after)
		}
		return struct{}{}
	})
	if rebuilt.String() != reply {
		t.Fatalf("deltas rebuilt %q, want %q", rebuilt.String(), reply)
	}
}

func TestConverseStreamingRefusesANilPublisher(t *testing.T) {
	agent := testAgent(MockProvider([]string{"x"}))
	mustPanic(t, "converseStreaming: third argument", func() {
		ConverseStreaming(NewConversation(agent), "hi", nil)
	})
}

// A tool-use step streams no text deltas — there is no user-facing text in it, which is
// what a real provider does too.
func TestStreamingEmitsNoDeltasForAToolStep(t *testing.T) {
	tool := ToolOf("lookup", "looks up", "{}",
		func(argsJSON string) string { return argsJSON },
		func(string) string { return "found" })
	provider := MockToolProvider([]LlmResponse{
		ToolUseStep("lookup", "call_1", "{}"),
		TextStep("done"),
	})
	events := []string{}
	ConverseStreaming(NewConversation(testAgent(provider, tool)), "go",
		func(event string) struct{} { events = append(events, event); return struct{}{} })
	want := []string{"tool: lookup", "text-delta: done", "text: done"}
	if len(events) != len(want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
	for i, event := range want {
		if events[i] != event {
			t.Fatalf("events = %#v, want %#v", events, want)
		}
	}
}

func TestAgentWithNoProviderFailsLoudly(t *testing.T) {
	mustPanic(t, "the agent has no provider", func() {
		Ask(NewAgent(LlmProvider{}, "x", FromInt64(1), nil), "hi")
	})
}

// The schema is model guidance; an unparseable one must not stop the tool being offered,
// because the validator — not the schema — is what actually rejects bad arguments.
func TestAnUnparseableToolSchemaIsOfferedAsAnOpenObject(t *testing.T) {
	tool := ToolOf("broken", "broken schema", "not json",
		func(argsJSON string) string { return argsJSON },
		func(string) string { return "ok" })
	var offered []LlmToolDecl
	provider := ProviderOf(func(request LlmRequest) LlmResponse {
		offered = request.Tools
		return TextStep("done")
	})
	AskReply(testAgent(provider, tool), "go")
	if len(offered) != 1 || string(offered[0].Schema) != `{"type":"object"}` {
		t.Fatalf("offered = %+v, want one open-object schema", offered)
	}
}

func TestToolUseStepRejectsMalformedArgumentJSON(t *testing.T) {
	mustPanic(t, "toolUseStep: arguments are not valid JSON", func() {
		ToolUseStep("t", "call_1", "{not json")
	})
}
