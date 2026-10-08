// Package push wakes devices that are not connected. Payloads are content-free
// ("you have something new"); the app fetches and decrypts after waking.
package push

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"time"
)

// Target is one device token.
type Target struct {
	UserID, DeviceID, Provider, Token string
}

// Sender delivers one wake-up. FCM and APNs adapters implement it with
// credentials from the secret store; LogSender stands in locally.
type Sender interface {
	Send(ctx context.Context, t Target, kind string) error
}

// LogSender records what would be sent, with the token reduced to a short hash.
type LogSender struct{}

func (LogSender) Send(_ context.Context, t Target, kind string) error {
	sum := sha256.Sum256([]byte(t.Token))
	slog.Info("push (local stand-in)", "provider", t.Provider, "device", t.DeviceID, "kind", kind, "token", hex.EncodeToString(sum[:4]))
	return nil
}

type job struct {
	users []string
	kind  string
}

// Dispatcher looks up tokens and sends off the request path. Its queue is
// bounded: under overload wake-ups are dropped, which only delays delivery
// until the app next opens or polls.
type Dispatcher struct {
	sender  Sender
	targets func(ctx context.Context, users []string) ([]Target, error)
	online  func(user string) bool
	jobs    chan job
}

func NewDispatcher(sender Sender, targets func(context.Context, []string) ([]Target, error), online func(string) bool, queue int) *Dispatcher {
	return &Dispatcher{sender: sender, targets: targets, online: online, jobs: make(chan job, queue)}
}

// Notify queues a wake-up for users who have no live connection on this node.
func (d *Dispatcher) Notify(kind string, users ...string) {
	offline := users[:0:0]
	for _, u := range users {
		if !d.online(u) {
			offline = append(offline, u)
		}
	}
	if len(offline) == 0 {
		return
	}
	select {
	case d.jobs <- job{offline, kind}:
	default:
		slog.Warn("push queue full; wake-up dropped", "kind", kind)
	}
}

// Run sends queued wake-ups with the given number of workers until ctx ends.
func (d *Dispatcher) Run(ctx context.Context, workers int) {
	for range workers {
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case j := <-d.jobs:
					d.send(ctx, j)
				}
			}
		}()
	}
}

func (d *Dispatcher) send(ctx context.Context, j job) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	targets, err := d.targets(ctx, j.users)
	if err != nil {
		slog.Warn("push lookup failed", "reason", err.Error())
		return
	}
	for _, t := range targets {
		if err := d.sender.Send(ctx, t, j.kind); err != nil {
			slog.Warn("push send failed", "provider", t.Provider, "reason", err.Error())
		}
	}
}
