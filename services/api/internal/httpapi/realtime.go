package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
	"golang.org/x/time/rate"
	"kairova/services/api/internal/realtime"
)

const (
	pingEvery    = 25 * time.Second
	writeTimeout = 10 * time.Second
	clientQueue  = 64
)

// signal publishes a wake-up after a committed write. It is best effort and
// bounded, so a slow bus never holds a request open.
func (a *API) signal(ctx context.Context, typ string, data map[string]string, users ...string) {
	if a.RT == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	a.RT.Publish(ctx, typ, data, users...)
}

// wake queues a content-free push for users not connected to this node.
func (a *API) wake(kind string, users ...string) {
	if a.Push != nil {
		a.Push.Notify(kind, users...)
	}
}

// realtimeGateway upgrades GET /v1/realtime to a WebSocket. It runs outside the
// request deadline that ordinary handlers get.
//
// Server → client: {"type":"ready"|"inbox"|"activity"|"read"|"typing"|"resync", "data":{...}}
// Client → server: {"type":"typing","conversationId":"…"}
func (a *API) realtimeGateway(w http.ResponseWriter, r *http.Request) {
	if a.RT == nil || r.Method != "GET" {
		a.failure(w, r, 404, "NOT_FOUND", "Endpoint unavailable")
		return
	}
	if !a.budget.Allow() || !a.clients.allow(clientAddress(r)) {
		w.Header().Set("Retry-After", "2")
		a.failure(w, r, 429, "RATE_LIMITED", "Try again shortly")
		return
	}
	raw := r.Header.Get("Authorization")
	if !strings.HasPrefix(raw, "Bearer ") || len(raw) > 16384 {
		a.failure(w, r, 401, "UNAUTHENTICATED", "Sign in again")
		return
	}
	authCtx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	p, err := a.Verify(authCtx, strings.TrimPrefix(raw, "Bearer "))
	cancel()
	if err != nil {
		a.failure(w, r, 401, "UNAUTHENTICATED", "Sign in again")
		return
	}
	client := realtime.NewClient(p.UserID, clientQueue)
	if !a.RT.Register(client) {
		w.Header().Set("Retry-After", "10")
		a.failure(w, r, 503, "AT_CAPACITY", "Too many connections; using background sync")
		return
	}
	defer a.RT.Unregister(client)

	// Long-lived: lift the server's per-request read/write deadlines for this
	// connection only. Heartbeats below bound idle and dead peers instead.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	_ = rc.SetWriteDeadline(time.Time{})
	patterns := []string{}
	if a.Origin != "" {
		patterns = append(patterns, strings.TrimPrefix(strings.TrimPrefix(a.Origin, "https://"), "http://"))
	}
	if a.DevAuth {
		patterns = append(patterns, "127.0.0.1:49321", "localhost:49321")
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: patterns, CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(4096)
	slog.Info("realtime connected", "connections", a.RT.Count())

	ctx, stop := context.WithCancel(context.WithoutCancel(r.Context()))
	defer stop()
	go a.realtimeReader(ctx, conn, client, p.UserID)

	ready, _ := json.Marshal(map[string]string{"type": "ready"})
	client.Send <- ready
	ping := time.NewTicker(pingEvery)
	defer ping.Stop()
	for {
		select {
		case <-client.Closed:
			conn.Close(websocket.StatusTryAgainLater, "resync")
			return
		case msg := <-client.Send:
			wctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := conn.Write(wctx, websocket.MessageText, msg)
			cancel()
			if err != nil {
				return
			}
		case <-ping.C:
			pctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := conn.Ping(pctx)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

func (a *API) realtimeReader(ctx context.Context, conn *websocket.Conn, client *realtime.Client, user string) {
	defer client.Close()
	typing := rate.NewLimiter(rate.Every(2*time.Second), 2)
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var msg struct {
			Type           string `json:"type"`
			ConversationID string `json:"conversationId"`
		}
		if json.Unmarshal(data, &msg) != nil || msg.Type != "typing" || !typing.Allow() {
			continue
		}
		if _, err := uuid.Parse(msg.ConversationID); err != nil {
			continue
		}
		c, err := a.Store.Conversation(ctx, user, msg.ConversationID)
		if err != nil || c.Status != "active" {
			continue
		}
		// Typing follows the reciprocal read-receipt setting.
		if shared, err := a.Store.ReadReceiptsShared(ctx, user, c.Peer.UserID); err != nil || !shared {
			continue
		}
		a.signal(ctx, "typing", map[string]string{"conversationId": c.ConversationID, "userId": user}, c.Peer.UserID)
	}
}
