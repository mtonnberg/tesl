package teslrt

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// Server endpoints as agent tools — the runtime half of `serverTools` and `humanActions`.
//
// `serverTools MyServer user` produces one tool per endpoint the user's proof covers, and
// each of those tools IS the endpoint: the same handler, called with the same authenticated
// user, so every ownership and authorization check in the handler body runs unchanged. What
// the emitter generates per endpoint is the argument decode and the call; what lives here is
// what both need to behave like the HTTP boundary — a rejection reaching the model as an
// is_error result rather than as a crash.
//
// `humanActions MyServer user` is the complement: one INERT tool per endpoint the user's
// proof does NOT cover. It is inert by construction — HumanActions takes the server's NAME,
// never the server, so there is no path from a request descriptor back to a handler.

// ToolArgDecoded reads one argument through a type's own codec — the same decode an HTTP
// request body goes through, so a tool argument can never be validated more weakly than the
// endpoint's boundary.
func ToolArgDecoded[T any](fields map[string]any, name string, decode func(any) Check[T]) T {
	return ToolChecked(name, decode(toolArgValue(fields, name)))
}

// ToolChecked unwraps a check on a tool argument, reporting a rejection with the check's own
// message. The message reaches the MODEL as the is_error result, which is what lets it
// correct the argument and try again.
func ToolChecked[T any](name string, result Check[T]) T {
	value, ok := result.Value()
	if !ok {
		panic(fmt.Sprintf("argument %s: %s", name, result.Message()))
	}
	return value
}

// ToolRejection is deferred by an emitted endpoint dispatch. A handler that rejects answers
// the HTTP client with a status; called as a tool it has no response to write, so the
// rejection becomes the tool_result text — carrying the status, because "not found (HTTP
// 404)" tells the model something "not found" alone does not.
//
// Anything else re-panics unchanged: the agent loop already contains a trapping tool body as
// an is_error result, and rewriting the message here would only hide where it came from.
func ToolRejection() {
	raised := recover()
	if raised == nil {
		return
	}
	if rejection, ok := raised.(RequestRejection); ok {
		panic(fmt.Sprintf("%s (HTTP %d)", rejection.Message, rejection.Status))
	}
	panic(raised)
}

// HumanActionSpec is one endpoint the agent may NOT perform, as the human sees it.
type HumanActionSpec struct {
	Name        string
	Description string
	Schema      string
}

func HumanActionOf(name, description, schema string) HumanActionSpec {
	return HumanActionSpec{Name: name, Description: description, Schema: schema}
}

// humanActionSuffix is appended to every human action's description. The model has to be
// told what calling the tool does, or it reports the action as done.
const humanActionSuffix = "  (You cannot perform this action yourself. Calling this tool" +
	" asks the human to perform it via a button in their app; you will be told the result" +
	" in a later turn.)"

// HumanActions builds one inert tool per excluded endpoint.
//
// The server NAME is what it takes, and all it takes: with no route table and no handler in
// reach, there is no in-process path from a request descriptor back to a call. The agent
// chooses WHICH excluded action to ask for and prefills its arguments; the human's browser
// resolves the action tag to a real URL from generated client code and performs the call
// under their own session, where the endpoint re-checks auth. So the agent can neither
// fabricate an action, relabel it, redirect it, nor perform it.
func HumanActions(serverName string, actions []HumanActionSpec) []Tool {
	tools := make([]Tool, 0, len(actions))
	for _, action := range actions {
		name := action.Name
		tools = append(tools, ToolOf(name, action.Description+humanActionSuffix, action.Schema,
			// The prefill is advisory: the human confirms the arguments and the real
			// endpoint re-validates them. Well-formedness is all that is checked, so the
			// request can be displayed.
			ToolArguments,
			func(prefill map[string]any) string {
				return humanActionRequest(serverName, name, prefill)
			}))
	}
	return tools
}

func humanActionRequest(serverName, action string, prefill map[string]any) string {
	return EncodeJSON(map[string]any{
		"kind":   "human-action-request",
		"server": serverName,
		"action": action,
		"args":   prefill,
		// An unguessable handle correlates the request with the result the human's
		// completed action produces, so it can re-enter the loop as a later turn.
		"handle": freshActionHandle(),
	})
}

func freshActionHandle() string {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		panic("humanAction: could not generate a correlation handle: " + err.Error())
	}
	return hex.EncodeToString(raw)
}
