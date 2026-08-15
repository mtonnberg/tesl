package teslrt

import (
	"sync"
)

// Server-Sent Events: `sseChannel C(key) = SseChannel { … }`, `publish C(key) payload`, and the
// `sse "/path" subscribe C(key)` route that streams them.
//
// Events flow server→client over ordinary HTTP on the SAME port as the API, which is why Tesl
// has no WebSocket server: a browser subscribes with EventSource and no proxy needs special
// configuration. The wire format is the one `tesl/sse.rkt` writes, byte for byte:
//
//	an event     data: {"channel":"<name>","payload":<json>}\n\n
//	a heartbeat  : heartbeat\n\n        every 10s, so a proxy does not reap an idle connection
//	on connect   : ok\n\n               so the browser fires onopen without waiting 10s
//
// PUBLISHING MUST NEVER BLOCK. A publish usually runs inside a request handler, so a listener
// that is slow — or dead but still registered — would otherwise cost that request. Each
// connection therefore has a BOUNDED buffer and a full buffer drops the event for that one
// consumer, counting it. Racket learned this the hard way (issue #32: a day of development
// left 109 stale listeners on one key, and a chat turn took over a minute).

type sseListener struct {
	events chan any
}

// SseChannel is one `sseChannel` declaration: a name, and the listeners registered under each
// channel KEY. The key is what makes a channel per-entity — `RunEvents(runId)` delivers only to
// the subscribers of that run — and a channel declared with a fixed string is the broadcast
// case of the same rule.
type SseChannel struct {
	name      string
	mutex     sync.Mutex
	listeners map[string][]*sseListener
	// active counts live connections per channel, mirroring registry membership rather than
	// being derived from it: the gauge must not drift when metrics are off for a while.
	active int
}

func NewSseChannel(name string) *SseChannel {
	return &SseChannel{name: name, listeners: map[string][]*sseListener{}}
}

func sseChannelAttribute(name string) []Tuple2[string, string] {
	return []Tuple2[string, string]{{Tuple2First: "tesl.channel", Tuple2Second: name}}
}

// Publish delivers one event to every listener on `key`. The payload is the ALREADY-ENCODED
// JSON value (what the type's codec produces), for the reason the response body is: the wire
// shape is decided by the codec, and deciding it twice is how the two ends drift.
//
// Delivery is non-blocking by construction — see the buffer note above.
func Publish(channel *SseChannel, key string, payload any) struct{} {
	channel.mutex.Lock()
	listeners := make([]*sseListener, len(channel.listeners[key]))
	copy(listeners, channel.listeners[key])
	channel.mutex.Unlock()
	for _, listener := range listeners {
		select {
		case listener.events <- payload:
		default:
			// This consumer is a whole buffer behind. The event is dropped for it alone, and
			// counted: a rising counter is the observable symptom of a stuck subscriber.
			Counter("tesl.sse.events.dropped", FromInt64(1), sseChannelAttribute(channel.name))
		}
	}
	return struct{}{}
}

// ResetChannel drops every listener, for a test block that starts from a channel nobody is on.
// It is the channel's counterpart of `TableTruncate`.
func ResetChannel(channel *SseChannel) {
	channel.mutex.Lock()
	defer channel.mutex.Unlock()
	channel.listeners = map[string][]*sseListener{}
	channel.active = 0
}
