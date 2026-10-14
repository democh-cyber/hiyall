// Package realtime delivers small wake-up events to connected clients. Events
// never carry message content: clients fetch state over HTTP after a signal, so
// a lost event costs latency, never data. Durable state stays in PostgreSQL.
package realtime

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"hiyall/services/api/internal/logscrub"
)

// Event is routed to every connection of each listed user.
type Event struct {
	Users []string          `json:"u"`
	Type  string            `json:"t"`
	Data  map[string]string `json:"d,omitempty"`
}

// wire is what a client receives.
type wire struct {
	Type string            `json:"type"`
	Data map[string]string `json:"data,omitempty"`
}

// Bus fans events out to every API node, including the publisher.
type Bus interface {
	Publish(ctx context.Context, e Event) error
	// Run delivers events until ctx ends or the bus fails. After a failure the
	// hub tells clients to resync, since events in the gap are lost.
	Run(ctx context.Context, deliver func(Event)) error
}

// Client is one live connection. Sends never block: a client whose queue is
// full is too slow to keep up and is disconnected; it resyncs on reconnect.
// Session is the session the connection authenticated with, so signing that
// session out (or the account being suspended) can end the connection.
type Client struct {
	User    string
	Session string
	Send    chan []byte
	Closed  chan struct{}
	once    sync.Once
	ended   atomic.Bool
}

func NewClient(user string, queue int) *Client {
	return &Client{User: user, Send: make(chan []byte, queue), Closed: make(chan struct{})}
}

// Close signals the connection's writer to stop. Safe to call more than once.
func (c *Client) Close() { c.once.Do(func() { close(c.Closed) }) }

// End closes the connection because its session is over (signed out, revoked,
// expired or the account suspended): the client must not just reconnect.
func (c *Client) End() {
	c.ended.Store(true)
	c.Close()
}

// Ended reports whether the connection was closed by End.
func (c *Client) Ended() bool { return c.ended.Load() }

func (c *Client) offer(msg []byte) {
	select {
	case <-c.Closed:
	case c.Send <- msg:
	default:
		c.Close()
	}
}

type Hub struct {
	bus        Bus
	maxPerUser int
	maxTotal   int64
	total      atomic.Int64
	mu         sync.RWMutex
	clients    map[string]map[*Client]struct{}
}

func NewHub(bus Bus, maxPerUser int, maxTotal int64) *Hub {
	return &Hub{bus: bus, maxPerUser: maxPerUser, maxTotal: maxTotal, clients: map[string]map[*Client]struct{}{}}
}

// Register admits a connection unless the node or the user is at its limit.
func (h *Hub) Register(c *Client) bool {
	if h.total.Add(1) > h.maxTotal {
		h.total.Add(-1)
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	set := h.clients[c.User]
	if len(set) >= h.maxPerUser {
		h.total.Add(-1)
		return false
	}
	if set == nil {
		set = map[*Client]struct{}{}
		h.clients[c.User] = set
	}
	set[c] = struct{}{}
	return true
}

func (h *Hub) Unregister(c *Client) {
	c.Close()
	h.mu.Lock()
	defer h.mu.Unlock()
	if set, ok := h.clients[c.User]; ok {
		if _, ok := set[c]; ok {
			delete(set, c)
			h.total.Add(-1)
			if len(set) == 0 {
				delete(h.clients, c.User)
			}
		}
	}
}

// Connected reports whether the user has a live connection on this node. Push
// uses it to skip waking a phone that is already listening here.
func (h *Hub) Connected(user string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients[user]) > 0
}

func (h *Hub) Count() int64 { return h.total.Load() }

// Publish is best effort: the caller's write has already committed.
func (h *Hub) Publish(ctx context.Context, typ string, data map[string]string, users ...string) {
	if len(users) == 0 {
		return
	}
	if err := h.bus.Publish(ctx, Event{Users: users, Type: typ, Data: data}); err != nil {
		slog.Warn("realtime publish failed", "type", typ, "reason", logscrub.Err(err))
	}
}

// disconnectType is a control event that never reaches a client: it ends the
// listed users' connections on every node (Data "session": only that session;
// "except": every session but that one; neither: all of them).
const disconnectType = "_disconnect"

// DisconnectEvent is the control event that ends users' connections, for
// publishers that are not an API node (the moderation tool notifies through
// PostgreSQL directly; see Channel).
func DisconnectEvent(users ...string) Event { return Event{Users: users, Type: disconnectType} }

// Disconnect ends a user's live connections on every node: only session when it
// is set, every session except except when that is set, otherwise all of them.
// Local connections end at once, so a bus outage cannot keep them open; other
// nodes end theirs when the event arrives (a node that misses it still closes
// the connection at its next heartbeat, when the session is checked again).
func (h *Hub) Disconnect(ctx context.Context, user, session, except string) {
	data := map[string]string{}
	if session != "" {
		data["session"] = session
	}
	if except != "" {
		data["except"] = except
	}
	e := Event{Users: []string{user}, Type: disconnectType, Data: data}
	h.disconnect(e)
	if err := h.bus.Publish(ctx, e); err != nil {
		slog.Warn("realtime disconnect publish failed", "reason", logscrub.Err(err))
	}
}

func (h *Hub) disconnect(e Event) {
	session, except := e.Data["session"], e.Data["except"]
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, user := range e.Users {
		for c := range h.clients[user] {
			if (session == "" || c.Session == session) && (except == "" || c.Session != except) {
				c.End()
			}
		}
	}
}

func (h *Hub) deliver(e Event) {
	if e.Type == disconnectType {
		h.disconnect(e)
		return
	}
	msg, err := json.Marshal(wire{Type: e.Type, Data: e.Data})
	if err != nil {
		return
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, user := range e.Users {
		for c := range h.clients[user] {
			c.offer(msg)
		}
	}
}

func (h *Hub) broadcast(typ string) {
	msg, _ := json.Marshal(wire{Type: typ})
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, set := range h.clients {
		for c := range set {
			c.offer(msg)
		}
	}
}

// Run consumes the bus until ctx ends, reconnecting with backoff. Each
// reconnect asks every local client to resync what it may have missed.
func (h *Hub) Run(ctx context.Context, backoff func(attempt int) time.Duration) {
	for attempt := 0; ctx.Err() == nil; attempt++ {
		if attempt > 0 {
			h.broadcast("resync")
		}
		err := h.bus.Run(ctx, h.deliver)
		if ctx.Err() != nil {
			return
		}
		slog.Warn("realtime bus stopped; reconnecting", "reason", errString(err))
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff(attempt)):
		}
	}
}

func errString(err error) string {
	if err == nil {
		return "closed"
	}
	return err.Error()
}

// LocalBus delivers in process. It is correct for a single node and for tests.
type LocalBus struct {
	mu      sync.RWMutex
	deliver func(Event)
	ready   chan struct{}
	once    sync.Once
}

func NewLocalBus() *LocalBus { return &LocalBus{ready: make(chan struct{})} }

func (b *LocalBus) Publish(ctx context.Context, e Event) error {
	select {
	case <-b.ready:
	case <-ctx.Done():
		return ctx.Err()
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	b.deliver(e)
	return nil
}

func (b *LocalBus) Run(ctx context.Context, deliver func(Event)) error {
	b.mu.Lock()
	b.deliver = deliver
	b.mu.Unlock()
	b.once.Do(func() { close(b.ready) })
	<-ctx.Done()
	return ctx.Err()
}

// CloseAll ends every local connection, for graceful shutdown. Clients
// reconnect, usually to another node, and resync.
func (h *Hub) CloseAll() {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, set := range h.clients {
		for c := range set {
			c.Close()
		}
	}
}
