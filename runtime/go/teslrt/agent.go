package teslrt

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"sync"
)

// The `Tesl.Agent` surface: an LLM provider, an agent spec, and the tool-calling loop
// that runs between them.
//
// The `aiProvider` capability that gates every inference entry point is a COMPILE-TIME
// grant, so nothing about it survives here — the same erasure every other capability
// gets. What does survive is the loop's structure, which is where the guarantees live:
//
//	bounded iteration    a provider that keeps asking for tools cannot spin forever;
//	contained tools      a tool whose arguments do not validate, or whose body traps,
//	                     becomes an is_error tool_result the model SEES, never an error
//	                     the caller has to catch — the model gets to correct itself;
//	no held connections  a tool runs, returns, and releases before the next provider
//	                     call, so a slow model never pins a database connection.
//
// A `Conversation` is an agent plus the transcript so far. Persistence is the PROGRAM's
// job: ConversationJSON and ConversationFrom round-trip the history through a string it
// stores in its own entity, so the runtime is not coupled to any schema. The JSON shape
// is this runtime's own and is not a wire format — it is what ConversationFrom reads
// back, nothing else.

// maxAgentIterations bounds the tool-calling loop. A provider that answers every
// tool_result with another tool_use would otherwise never return.
const maxAgentIterations = 16

// ── Provider protocol ────────────────────────────────────────────────────────

// LlmToolDecl is one tool as the provider sees it: a name, a description, and the
// JSON-Schema object describing its arguments. Schema is raw JSON so a provider forwards
// it verbatim rather than reparsing a shape it does not interpret.
type LlmToolDecl struct {
	Name        string
	Description string
	Schema      json.RawMessage
}

// LlmRequest is one provider round-trip's input.
//
// OnDelta is non-nil only when the caller opted into token streaming. A provider that
// cannot stream simply never calls it; a caller that did not opt in never sees partial
// text.
type LlmRequest struct {
	System    string
	MaxTokens Int
	Messages  []AgentMessage
	Tools     []LlmToolDecl
	OnDelta   func(string)
}

// LlmToolCall is one tool the model asked for. Args is the model's raw JSON — it is
// UNVALIDATED input that reaches a tool's validator, never a Tesl value directly.
type LlmToolCall struct {
	ID   string
	Name string
	Args json.RawMessage
}

// LlmUsage is the token accounting a provider reports, summed across the loop.
type LlmUsage struct {
	Input      Int
	Output     Int
	CacheRead  Int
	CacheWrite Int
}

// LlmResponse is one provider round-trip's output, normalised across providers. It is
// also the Tesl `ToolStep` type: a mock provider's script is a list of these.
type LlmResponse struct {
	Text       string
	Usage      LlmUsage
	ToolCalls  []LlmToolCall
	StopReason string
}

// LlmProvider wraps the call itself. It is a struct rather than a bare func so it is a
// named Tesl type with a zero value that fails loudly instead of a nil func that panics
// with Go's own message.
type LlmProvider struct {
	invoke func(LlmRequest) LlmResponse
}

// ProviderOf builds an LlmProvider from a round-trip function. Real providers and the
// test doubles both go through it.
func ProviderOf(invoke func(LlmRequest) LlmResponse) LlmProvider {
	return LlmProvider{invoke: invoke}
}

// DeferredProvider builds the provider on the first CALL rather than where it was written,
// once, and reuses it after.
//
// It exists for the top-level `agent X = Agent { … }` declaration, whose provider is
// typically `anthropic (requireEnv "…") "model"`: that reads configuration, and a package
// variable's initialiser runs when the program loads — so a test suite that overrides the
// provider on every call (`askWith agent prompt mock`) would still need the key to start.
// Deferring makes the read happen when the provider is actually used, which is also where
// a missing key is worth reporting. The Racket backend reaches the same place from the
// other side: `requireEnv` there answers false rather than failing, so its module-load read
// is harmless — and an empty key is then sent to the API. Failing at the first call is the
// better half of that trade.
//
// Only the top-level declaration defers. An `Agent { … }` written inside a function body is
// ordinary code and evaluates where it stands.
func DeferredProvider(build func() LlmProvider) LlmProvider {
	once := sync.OnceValue(build)
	return ProviderOf(func(request LlmRequest) LlmResponse { return once().call(request) })
}

func (provider LlmProvider) call(request LlmRequest) LlmResponse {
	if provider.invoke == nil {
		panic("Tesl.Agent: the agent has no provider")
	}
	return provider.invoke(request)
}

// ── Mock providers ───────────────────────────────────────────────────────────

// deltaChunks splits reply text the way a streaming provider would emit it: alternating
// runs of whitespace and non-whitespace, so concatenating the chunks reproduces the text
// exactly.
var deltaChunks = regexp.MustCompile(`\s+|\S+`)

// MockProvider scripts one text reply per call, in order. Exhausting the script is a
// trap, not an empty reply: a test that made more calls than it scripted has a bug the
// runtime must not paper over.
func MockProvider(replies []string) LlmProvider {
	steps := make([]LlmResponse, 0, len(replies))
	for _, reply := range replies {
		steps = append(steps, TextStep(reply))
	}
	return MockToolProvider(steps)
}

// MockToolProvider scripts a multi-round tool-calling sequence — one LlmResponse per
// provider round-trip.
func MockToolProvider(steps []LlmResponse) LlmProvider {
	script := make([]LlmResponse, len(steps))
	copy(script, steps)
	calls := 0
	return ProviderOf(func(request LlmRequest) LlmResponse {
		if calls >= len(script) {
			panic(fmt.Sprintf(
				"mockProvider: exhausted — %d call(s) made but only %d scripted response(s)",
				calls+1, len(script)))
		}
		response := script[calls]
		calls++
		// Synthesize deltas for a text turn so a streaming consumer exercises the same
		// path a real provider drives. A tool-use step streams no user-facing text, as
		// a real provider does not either.
		if request.OnDelta != nil && len(response.ToolCalls) == 0 {
			for _, chunk := range deltaChunks.FindAllString(response.Text, -1) {
				request.OnDelta(chunk)
			}
		}
		return response
	})
}

// ToolUseStep scripts one tool_use turn. argsJSON is parsed here so a malformed script
// fails at construction, where the test author can see it, rather than inside the loop.
func ToolUseStep(toolName, callID, argsJSON string) LlmResponse {
	var args json.RawMessage
	if err := json.Unmarshal([]byte(argsJSON), &args); err != nil {
		panic("toolUseStep: arguments are not valid JSON: " + err.Error())
	}
	return LlmResponse{
		Usage:      unitUsage(),
		ToolCalls:  []LlmToolCall{{ID: callID, Name: toolName, Args: args}},
		StopReason: "tool-use",
	}
}

// TextStep scripts a final assistant text turn.
func TextStep(text string) LlmResponse {
	return LlmResponse{Text: text, Usage: unitUsage(), StopReason: "end-turn"}
}

func unitUsage() LlmUsage {
	one := FromInt64(1)
	return LlmUsage{Input: one, Output: one}
}

// ── Tools ────────────────────────────────────────────────────────────────────

// Tool is a registered tool with its argument type ERASED. `validate` turns the model's
// raw argument JSON into that type and `dispatch` turns it back into result text; both
// are closures built by ToolOf, which is the only place the type is known.
//
// Both may panic — that is the contract, not a leak. Bad arguments and a failing body
// are ordinary outcomes of handing a tool to a model, and runToolCall turns each into an
// is_error tool_result the model reads and reacts to.
type Tool struct {
	Name        string
	Description string
	Schema      string
	validate    func(argsJSON string) any
	dispatch    func(validated any) string
}

// ToolOf builds a Tool from a typed validator/dispatch pair, erasing the argument type
// into the closures. A is the tool's validated argument type — the value that crosses
// from validate to dispatch, and the only place it is ever named.
func ToolOf[A any](name, description, schema string,
	validate func(string) A, dispatch func(A) string) Tool {
	return Tool{
		Name:        name,
		Description: description,
		Schema:      schema,
		validate:    func(argsJSON string) any { return validate(argsJSON) },
		dispatch: func(validated any) string {
			typed, ok := validated.(A)
			if !ok {
				panic("Tesl.Agent: tool argument type mismatch")
			}
			return dispatch(typed)
		},
	}
}

// toolResult is one entry of the tool turn fed back to the model.
type toolResult struct {
	ID      string `json:"id"`
	Content string `json:"content"`
	IsError bool   `json:"isError,omitempty"`
}

// runToolCall validates and dispatches one tool call, containing every failure as an
// is_error result. A trap inside a tool body is the model's problem to route around, not
// the caller's to catch — killing the whole loop over one bad tool would lose the reply
// the model could still have produced.
func runToolCall(agent Agent, call LlmToolCall) (result toolResult) {
	for _, tool := range agent.Tools {
		if tool.Name == call.Name {
			return dispatchTool(tool, call)
		}
	}
	return toolResult{ID: call.ID, Content: "unknown tool: " + call.Name, IsError: true}
}

func dispatchTool(tool Tool, call LlmToolCall) (result toolResult) {
	argsJSON := string(call.Args)
	if len(argsJSON) == 0 {
		argsJSON = "{}"
	}
	validated, failure := recovered(func() any { return tool.validate(argsJSON) })
	if failure != "" {
		return toolResult{ID: call.ID, Content: "invalid arguments: " + failure, IsError: true}
	}
	text, failure := recovered(func() any { return tool.dispatch(validated) })
	if failure != "" {
		return toolResult{ID: call.ID, Content: "tool failed: " + failure, IsError: true}
	}
	answer, ok := text.(string)
	if !ok {
		return toolResult{ID: call.ID, Content: "tool failed: dispatch returned no text", IsError: true}
	}
	return toolResult{ID: call.ID, Content: answer}
}

// recovered runs body and reports a panic as a message rather than unwinding. The empty
// string means "no failure" — a tool that fails with an empty message still reports the
// panic value's rendering, which is never empty for the values the runtime raises.
func recovered(body func() any) (value any, failure string) {
	defer func() {
		if raised := recover(); raised != nil {
			value = nil
			failure = panicMessage(raised)
		}
	}()
	return body(), ""
}

func panicMessage(raised any) string {
	switch typed := raised.(type) {
	case error:
		return typed.Error()
	case string:
		if typed == "" {
			return "tool raised"
		}
		return typed
	default:
		return fmt.Sprintf("%v", typed)
	}
}

// ── Agent ────────────────────────────────────────────────────────────────────

// Agent is the spec the loop runs against: which provider to call, what to tell it, how
// much to let it say, and which tools it may reach for.
// The field names are the Tesl ones: `Agent { provider, systemPrompt, maxTokens, tools }`
// is emitted as a keyed struct literal, so a rename here is a rename of the surface.
type Agent struct {
	Provider     LlmProvider
	SystemPrompt string
	MaxTokens    Int
	Tools        []Tool
}

// NewAgent builds an Agent positionally. The emitted code uses the keyed literal; this is
// for runtime-internal construction and for tests.
func NewAgent(provider LlmProvider, systemPrompt string, maxTokens Int, tools []Tool) Agent {
	return Agent{Provider: provider, SystemPrompt: systemPrompt, MaxTokens: maxTokens, Tools: tools}
}

// AgentReply is one completed turn: the final assistant text, what it cost, and how many
// tools fired getting there.
type AgentReply struct {
	Text       string
	usage      LlmUsage
	toolCalls  Int
	stopReason string
}

func ReplyText(reply AgentReply) string { return reply.Text }

// ReplyTokens is input plus output. Cache reads and writes are accounted separately by
// the providers that report them and are not billed as either.
func ReplyTokens(reply AgentReply) Int {
	return Add(reply.usage.Input, reply.usage.Output)
}

func ReplyToolCalls(reply AgentReply) Int { return reply.toolCalls }

// ── Transcript ───────────────────────────────────────────────────────────────

// AgentBlock is one piece of an assistant or tool turn. The variants are distinguished
// by Kind rather than by a sum type because this shape is also the persisted JSON, and a
// tagged struct round-trips through encoding/json without a custom unmarshaller.
type AgentBlock struct {
	Kind    string          `json:"kind"`
	Text    string          `json:"text,omitempty"`
	ID      string          `json:"id,omitempty"`
	Name    string          `json:"name,omitempty"`
	Args    json.RawMessage `json:"args,omitempty"`
	Results []toolResult    `json:"results,omitempty"`
}

// AgentMessage is one turn of the transcript. A user turn carries Text; assistant and
// tool turns carry Content blocks.
type AgentMessage struct {
	Role    string       `json:"role"`
	Text    string       `json:"text,omitempty"`
	Content []AgentBlock `json:"content,omitempty"`
}

func userMessage(prompt string) AgentMessage {
	return AgentMessage{Role: "user", Text: prompt}
}

// assistantMessage reconstructs the model's turn for the transcript: its text, then one
// block per tool it asked for. An empty text with no tool calls produces no blocks, and
// the caller drops the turn rather than recording an empty one.
func assistantMessage(response LlmResponse) AgentMessage {
	blocks := make([]AgentBlock, 0, 1+len(response.ToolCalls))
	if response.Text != "" {
		blocks = append(blocks, AgentBlock{Kind: "text", Text: response.Text})
	}
	for _, call := range response.ToolCalls {
		blocks = append(blocks, AgentBlock{
			Kind: "tool-use", ID: call.ID, Name: call.Name, Args: call.Args,
		})
	}
	return AgentMessage{Role: "assistant", Content: blocks}
}

func toolMessage(results []toolResult) AgentMessage {
	return AgentMessage{
		Role:    "tool",
		Content: []AgentBlock{{Kind: "tool-result", Results: results}},
	}
}

func mergeUsage(into, from LlmUsage) LlmUsage {
	return LlmUsage{
		Input:      Add(into.Input, from.Input),
		Output:     Add(into.Output, from.Output),
		CacheRead:  Add(into.CacheRead, from.CacheRead),
		CacheWrite: Add(into.CacheWrite, from.CacheWrite),
	}
}

// ── The loop ─────────────────────────────────────────────────────────────────

// runLoop drives provider round-trips until the model stops asking for tools, and
// answers the final reply plus the FULL transcript — the transcript is what a
// conversation threads into its next turn.
//
// onStep, when non-nil, is called once per loop step: as each tool is dispatched, and
// once with the final text. It never runs while a database connection is held.
func runLoop(agent Agent, provider LlmProvider, messages []AgentMessage,
	onStep func(string), streamTokens bool) (AgentReply, []AgentMessage) {
	usage := LlmUsage{}
	toolCalls := 0
	step := func(event string) {
		if onStep != nil {
			onStep(event)
		}
	}
	for iteration := 0; ; iteration++ {
		if iteration >= maxAgentIterations {
			panic(fmt.Sprintf("askReply: tool-calling loop exceeded %d iterations",
				maxAgentIterations))
		}
		request := LlmRequest{
			System:    agent.SystemPrompt,
			MaxTokens: agent.MaxTokens,
			Messages:  messages,
			Tools:     toolDecls(agent),
		}
		if onStep != nil && streamTokens {
			request.OnDelta = func(partial string) { step("text-delta: " + partial) }
		}
		response := provider.call(request)
		usage = mergeUsage(usage, response.Usage)
		if len(response.ToolCalls) == 0 {
			if response.Text != "" {
				messages = append(messages, assistantMessage(response))
			}
			step("text: " + response.Text)
			return AgentReply{
				Text:       response.Text,
				usage:      usage,
				toolCalls:  FromInt64(int64(toolCalls)),
				stopReason: response.StopReason,
			}, messages
		}
		for _, call := range response.ToolCalls {
			step("tool: " + call.Name)
		}
		results := make([]toolResult, 0, len(response.ToolCalls))
		for _, call := range response.ToolCalls {
			results = append(results, runToolCall(agent, call))
		}
		messages = append(messages, assistantMessage(response), toolMessage(results))
		toolCalls += len(response.ToolCalls)
	}
}

// toolDecls renders the agent's tools as the provider sees them. A tool whose schema is
// not parseable JSON is still offered, described as an open object — the schema is model
// GUIDANCE, and the validator remains authoritative either way.
func toolDecls(agent Agent) []LlmToolDecl {
	if len(agent.Tools) == 0 {
		return nil
	}
	decls := make([]LlmToolDecl, 0, len(agent.Tools))
	for _, tool := range agent.Tools {
		schema := json.RawMessage(tool.Schema)
		if !json.Valid(schema) {
			schema = json.RawMessage(`{"type":"object"}`)
		}
		decls = append(decls, LlmToolDecl{
			Name: tool.Name, Description: tool.Description, Schema: schema,
		})
	}
	return decls
}

// ── Inference entry points ───────────────────────────────────────────────────

// Ask runs the full loop and answers the final text. A tool-augmented agent still works
// through it; the tools just do not show up in the answer.
func Ask(agent Agent, prompt string) string {
	return AskReply(agent, prompt).Text
}

// AskReply runs the full loop and answers text, usage, and tool count.
func AskReply(agent Agent, prompt string) AgentReply {
	reply, _ := runLoop(agent, agent.Provider, []AgentMessage{userMessage(prompt)}, nil, false)
	return reply
}

// AskWith overrides the provider for THIS call only — the BYOK path. The agent's own
// binding, its system prompt, and its tools are untouched.
func AskWith(agent Agent, prompt string, provider LlmProvider) AgentReply {
	reply, _ := runLoop(agent, provider, []AgentMessage{userMessage(prompt)}, nil, false)
	return reply
}

// AgentPublisher is a Tesl `String -> Unit`. The empty struct is what Unit erases to, so
// this is the type an emitted lambda and an emitted `fn … -> Unit` both already have —
// naming it here is what lets either be passed straight through with no adapter.
type AgentPublisher = func(string) struct{}

// stepCallback adapts a Tesl publisher to the loop's own callback, discarding the Unit.
func stepCallback(publisher AgentPublisher) func(string) {
	return func(event string) { _ = publisher(event) }
}

// AgentRun runs the loop to completion, calling publisher once per step. It is what a
// worker job body calls: the publisher closes over a channel publish, so the SAME
// channel/SSE path streams the agent's progress.
func AgentRun(agent Agent, prompt string, publisher AgentPublisher) AgentReply {
	if publisher == nil {
		panic("agentRun: publisher must be a function String -> Unit")
	}
	reply, _ := runLoop(agent, agent.Provider,
		[]AgentMessage{userMessage(prompt)}, stepCallback(publisher), false)
	return reply
}

// AskFor asks for a typed value: run the loop, hand the final text to decode, and on
// failure append the error to the prompt and re-ask, up to maxRetries extra times.
//
// decode reports failure by trapping — which is what a codec decode does — so the retry
// is driven by recovering it here rather than by a second error channel the emitted
// decoder would have to thread.
func AskFor[A any](agent Agent, prompt string, decode func(string) A, maxRetries Int) A {
	retries, exact := maxRetries.Int64()
	if !exact || retries < 0 {
		retries = 0
	}
	attempt := prompt
	for left := retries; ; left-- {
		reply := AskReply(agent, attempt)
		decoded, failure := recovered(func() any { return decode(reply.Text) })
		if failure == "" {
			typed, ok := decoded.(A)
			if !ok {
				panic("askFor: decoder returned an unexpected type")
			}
			return typed
		}
		if left <= 0 {
			plural := "ies"
			if retries == 1 {
				plural = "y"
			}
			panic(fmt.Sprintf("askFor: structured output did not decode after %d retr%s: %s",
				retries, plural, failure))
		}
		attempt = prompt +
			"\n\nYour previous reply could not be parsed: " + failure +
			"\nReturn ONLY valid JSON matching the requested shape."
	}
}

// ── Conversation ─────────────────────────────────────────────────────────────

// Conversation is an agent bound to the transcript so far. Turn N sees turns 1..N-1
// because Converse threads the whole transcript into the loop.
type Conversation struct {
	agent    Agent
	messages []AgentMessage
}

// ConversationTurn is one turn's outcome: the reply, and the conversation advanced by
// this turn for the caller to thread into the next one.
type ConversationTurn struct {
	reply        AgentReply
	conversation Conversation
}

func NewConversation(agent Agent) Conversation {
	return Conversation{agent: agent}
}

func Converse(conversation Conversation, prompt string) ConversationTurn {
	return converseWith(conversation, prompt, nil, false)
}

// ConverseStreaming is Converse with progress: publish is called with "tool: <name>" as
// each tool fires, "text-delta: <part>" as the model generates, and "text: <reply>" once
// the turn completes. A consumer that only reads "text:" keeps working — it ignores the
// prefixes it does not know.
func ConverseStreaming(conversation Conversation, prompt string,
	publish AgentPublisher) ConversationTurn {
	if publish == nil {
		panic("converseStreaming: third argument must be a function String -> Unit")
	}
	return converseWith(conversation, prompt, stepCallback(publish), true)
}

func converseWith(conversation Conversation, prompt string,
	onStep func(string), streamTokens bool) ConversationTurn {
	history := make([]AgentMessage, 0, len(conversation.messages)+2)
	history = append(history, conversation.messages...)
	history = append(history, userMessage(prompt))
	reply, transcript := runLoop(conversation.agent, conversation.agent.Provider,
		history, onStep, streamTokens)
	return ConversationTurn{
		reply:        reply,
		conversation: Conversation{agent: conversation.agent, messages: transcript},
	}
}

func TurnReply(turn ConversationTurn) AgentReply { return turn.reply }

func TurnConversation(turn ConversationTurn) Conversation { return turn.conversation }

func ConversationLength(conversation Conversation) Int {
	return FromInt64(int64(len(conversation.messages)))
}

// ConversationJSON serialises the transcript for the program to persist. The shape is
// this runtime's own — ConversationFrom is its only reader — but it is deliberately
// legible: the prompts and replies appear as themselves, so a stored row can be read.
func ConversationJSON(conversation Conversation) string {
	messages := conversation.messages
	if messages == nil {
		messages = []AgentMessage{}
	}
	encoded, err := json.Marshal(messages)
	if err != nil {
		panic("conversationJson: history could not be serialized: " + err.Error())
	}
	return string(encoded)
}

// ConversationFrom restores a transcript previously produced by ConversationJSON and
// binds it to agent.
func ConversationFrom(agent Agent, history string) Conversation {
	if strings.TrimSpace(history) == "" {
		return Conversation{agent: agent}
	}
	var messages []AgentMessage
	if err := json.Unmarshal([]byte(history), &messages); err != nil {
		panic("conversationFrom: history is not valid JSON: " + err.Error())
	}
	return Conversation{agent: agent, messages: messages}
}

// ── Typed decoding at the model boundary ─────────────────────────────────────
//
// Everything a model produces is UNTRUSTED text. The two entry points below are where it
// becomes a typed value, and both go through the program's own codec — the same decode an
// HTTP request body gets — so a proof a type carries is established here or not at all.
// Neither returns an error: a failure TRAPS, which is what lets AskFor retry and what
// turns a bad tool argument into an is_error result the model reads.

// DecodeAs decodes a JSON string as the named type. typeName appears only in the failure
// message; which decoder runs was decided at compile time, from the literal type name at
// the call site.
func DecodeAs[T any](typeName, jsonText string, decode func(any) Check[T]) T {
	// ParseJSON, not json.Unmarshal: it reads numbers as json.Number, which is what an
	// arbitrary-precision Int decodes from. Unmarshalling into `any` would hand the codec a
	// float64 and quietly round anything above 2^53 — the same reason the HTTP body path
	// goes through it.
	raw, err := ParseJSON([]byte(jsonText))
	if err != nil {
		panic("decodeAs: not valid JSON: " + err.Error())
	}
	result := decode(raw)
	value, ok := result.Value()
	if !ok {
		panic("decodeAs: decoded value failed validation: " + result.Message())
	}
	_ = typeName
	return value
}

// ToolArguments parses a tool call's argument JSON into its fields. A payload that is not
// a JSON object is a trap: the schema asked for an object, and reading a scalar as one
// would silently give every argument its zero value.
func ToolArguments(argsJSON string) map[string]any {
	// Through ParseJSON for the reason DecodeAs is: an Int-typed tool parameter reads its
	// digits, and a float64 would round the large ones.
	parsed, err := ParseJSON([]byte(argsJSON))
	if err != nil {
		panic("tool: arguments were not valid JSON: " + err.Error())
	}
	fields, ok := parsed.(map[string]any)
	if !ok {
		panic("tool: expected a JSON object of arguments")
	}
	return fields
}

func toolArgValue(fields map[string]any, name string) any {
	value, present := fields[name]
	if !present {
		panic("tool: missing required argument: " + name)
	}
	return value
}

func ToolArgString(fields map[string]any, name string) string {
	text, err := DecodeStringValue(toolArgValue(fields, name))
	if err != nil {
		panic("tool: argument " + name + " must be a string")
	}
	return text
}

// ToolArgInt refuses a fractional number rather than truncating it. A model that answered
// 2.5 for a count did not mean 2, and silently agreeing with it is how a wrong quantity
// reaches a tool body. DecodeIntValue is the same reader a codec uses, so the digits — not
// a float64 — are what the value comes from.
func ToolArgInt(fields map[string]any, name string) Int {
	value, err := DecodeIntValue(toolArgValue(fields, name))
	if err != nil {
		panic("tool: argument " + name + " must be an integer")
	}
	return value
}

func ToolArgFloat(fields map[string]any, name string) float64 {
	number, err := DecodeFloatValue(toolArgValue(fields, name))
	if err != nil {
		panic("tool: argument " + name + " must be a number")
	}
	return number
}

func ToolArgBool(fields map[string]any, name string) bool {
	value, err := DecodeBoolValue(toolArgValue(fields, name))
	if err != nil {
		panic("tool: argument " + name + " must be a boolean")
	}
	return value
}

// ToolArgPosixMillis reads the epoch-millisecond integer the schema describes. The
// description is what keeps a model from sending seconds or a formatted date; this is
// what refuses one that did anyway.
func ToolArgPosixMillis(fields map[string]any, name string) PosixMillis {
	return PosixMillis{Value: ToolArgInt(fields, name)}
}

// ToolArgMoney reads `{minorUnits, currency}`. Extra keys are tolerated — a model that
// echoes back the enriched `display` field a Money tool RESULT carries is being helpful,
// not wrong — but minor units are never inferred from a major-unit amount.
func ToolArgMoney(fields map[string]any, name string) Money {
	object, ok := toolArgValue(fields, name).(map[string]any)
	if !ok {
		panic("tool: argument " + name + " must be an object {minorUnits, currency}")
	}
	minorUnits, present := object["minorUnits"]
	if !present {
		panic("tool: argument " + name + " is missing minorUnits")
	}
	units, err := DecodeIntValue(minorUnits)
	if err != nil {
		panic("tool: argument " + name + " must have integer minorUnits")
	}
	code, present := object["currency"]
	if !present {
		panic("tool: argument " + name + " is missing currency")
	}
	text, isText := code.(string)
	if !isText {
		panic("tool: argument " + name + " has unknown currency code")
	}
	currency, known := CurrencyFromCode(text).Value()
	if !known {
		panic("tool: argument " + name + " has unknown currency code: " + text)
	}
	return Money{MinorUnits: units, Currency: currency}
}

// ToolDispatchWith captures a tool dispatch's leading argument, leaving the model to supply
// only the validated one. A partial application in the surface — `tool … validateSpec
// (dispatchReport conversationId)` — is what makes a tool PER-TURN: the captured value is
// the program's, so the model chooses what the report is about and cannot choose whose
// conversation it lands in.
func ToolDispatchWith[Captured, Argument any](
	dispatch func(Captured, Argument) string, captured Captured) func(Argument) string {
	return func(argument Argument) string { return dispatch(captured, argument) }
}
