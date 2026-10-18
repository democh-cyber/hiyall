// Package push wakes devices that are not connected. Payloads never carry
// message content, photos or the names of strangers: a push says "you have
// something new" and the app fetches and decrypts after waking. The server
// cannot read end-to-end encrypted chats, so it could not put their text in a
// payload even if it wanted to.
//
// Notify is the single decision point. Cheap, in-memory rules run on the request
// path (the kind allowlist, a live socket on this node, coalescing); everything
// that needs the database (mutes, blocks, age band, account state, the member's
// own notification choices) runs on a worker, so a push never slows a request.
package push

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"

	"hiyall/services/api/internal/logscrub"
	"hiyall/services/api/internal/metrics"
)

// Target is one device token.
type Target struct {
	UserID, DeviceID, Provider, Token string
}

// Message is one notification as a device receives it. Data values are strings
// because FCM requires it; CollapseKey makes a newer push replace an older one
// the device has not shown yet (FCM collapse_key, APNs apns-collapse-id).
type Message struct {
	Kind        string
	Title, Body string
	Data        map[string]string
	CollapseKey string
}

// Sender delivers one message to one device. FCM implements it (iOS goes through
// FCM as well, see docs/api/23-push-notifications.md); LogSender stands in
// locally. An error wrapping ErrUnregistered means the token is dead and should
// be forgotten; one wrapping a *TransientError is retried with backoff; anything
// else is final.
type Sender interface {
	Send(ctx context.Context, t Target, m Message) error
}

// ErrConfig marks a refusal caused by the server's own push configuration, such as FCM's
// SENDER_ID_MISMATCH (the credentials belong to another project than the device token). It is neither a
// dead token nor transient: the token is kept, the failure is counted in hiyall_push_config_errors_total and
// logged as an error.
var ErrConfig = errors.New("push provider refused the configuration")

var pushConfigErrors = metrics.NewCounter("hiyall_push_config_errors_total", "Pushes the provider refused because of this server's own configuration (alert on any).", "provider")

// ErrUnregistered reports a token the provider will never deliver to again.
var ErrUnregistered = errors.New("push token is no longer valid")

// TransientError is a failure worth retrying (rate limit, provider outage, network).
// After is the provider's own wait, when it gave one.
type TransientError struct {
	Err   error
	After time.Duration
}

func (e *TransientError) Error() string { return e.Err.Error() }
func (e *TransientError) Unwrap() error { return e.Err }

// LogSender records what would be sent, with the token reduced to a short hash.
// It is what runs while FCM is not configured.
type LogSender struct{}

func (LogSender) Send(_ context.Context, t Target, m Message) error {
	sum := sha256.Sum256([]byte(t.Token))
	slog.Info("push (local stand-in)", "provider", t.Provider, "device", t.DeviceID, "kind", m.Kind, "token", hex.EncodeToString(sum[:4]))
	return nil
}

// Notice is one thing that happened to Recipient, caused by Actor. Conversation is set for chat.
type Notice struct {
	Kind                           string
	Recipient, Actor, Conversation string
	// Device is a device that must not receive this push: for "device", the one that was just added.
	Device string
	// Targets are the devices a "deletion" notice goes to. The account is already pending deletion and its tokens are
	// cleared, so neither the eligibility check nor the token lookup would find anything: the caller reads the tokens
	// as it clears them and hands them over here (round-4 N-5). Ignored for every other kind.
	Targets []Target
}

// KindDeletion is the push that tells a member their account was just scheduled for deletion, sent once to every device
// that held a token before the deletion cleared them. It is a security push (never switched off, exempt from the live
// socket check and from the chat cap), because appleCodeUnavailable is only the client's statement: a deletion made
// with a stolen token must be visible to the owner.
const KindDeletion = "deletion"

// Category is the member's notification choice a kind falls under.
const (
	CategoryChat   = "chat"
	CategorySocial = "social"
	// CategorySecurity is never switched off by the member's notification choices: the notice that a
	// device was added to their account is the one defence against a stolen credential adding one.
	// It is also exempt from what could silence it: a live socket (the thief may hold one open), the
	// coalescing window and the chat daily cap. It has its own small cap instead, SecurityDailyCap.
	CategorySecurity = "security"
)

// SecurityDailyCap is how many security pushes one recipient gets per rolling 24 hours, counted apart from the
// chat and social cap (Config.DailyCap), so neither can use up the other's.
const SecurityDailyCap = 20

// kindSpec is one row of the allowlist: only these kinds are ever pushed. Anything
// else, such as reactions, comments and space moderation, is dropped before it is
// queued. window is the least time between two pushes of the same kind for the
// same recipient (per conversation for chat, per actor for social); named lets
// the body use the actor's display name, but only when the recipient may already
// see who they are (the Eligibility check says so).
type kindSpec struct {
	category    string
	window      time.Duration
	body, named string
}

const title = "Hiyall"

var kinds = map[string]kindSpec{
	"chat": {CategoryChat, 30 * time.Second, "New message", ""},
	// An invite to a group (docs/api/29-group-chat.md): a chat notification that names nothing, not even the group.
	"group_invite":    {CategoryChat, 10 * time.Minute, "You have a new group invite", ""},
	"device":          {CategorySecurity, 0, "New device added to your account", ""},
	"device-revoked":  {CategorySecurity, 0, "A device was removed from your account", ""},
	KindDeletion:      {CategorySecurity, 0, "Account deletion scheduled", ""},
	"friend_request":  {CategorySocial, 10 * time.Minute, "You have a new friend request", "%s sent you a friend request"},
	"friend_accepted": {CategorySocial, 10 * time.Minute, "Your friend request was accepted", "%s accepted your friend request"},
	"follow":          {CategorySocial, 10 * time.Minute, "You have a new follower", "%s started following you"},
	"follow_request":  {CategorySocial, 10 * time.Minute, "You have a new follow request", "%s asked to follow you"},
	"follow_accepted": {CategorySocial, 10 * time.Minute, "Your follow request was accepted", "%s accepted your follow request"},
	"space_invite":    {CategorySocial, 10 * time.Minute, "You have a new space invitation", "%s invited you to a space"},
	// Wave 7 (docs/api/27-stories-notices-support.md): which member choice each falls under is store.PushPref. A visit
	// push is "visit" (the visitor's name may be used) or "visit_anon" (it may not); "support" has no actor and is
	// content-free.
	"reaction":   {CategorySocial, 30 * time.Minute, "Someone reacted to your post", "%s reacted to your post"},
	"comment":    {CategorySocial, 10 * time.Minute, "Someone commented on your post", "%s commented on your post"},
	"reply":      {CategorySocial, 10 * time.Minute, "Someone replied to your comment", "%s replied to your comment"},
	"visit":      {CategorySocial, 24 * time.Hour, "Someone visited your profile", "%s visited your profile"},
	"visit_anon": {CategorySocial, 24 * time.Hour, "Someone visited your profile", ""},
	"support":    {CategorySocial, 0, "Support replied", ""},
}

// Allowed reports whether kind may be pushed at all.
func Allowed(kind string) bool { _, ok := kinds[kind]; return ok }

// CategoryOf is the notification category of an allowed kind, "" for any other.
func CategoryOf(kind string) string { return kinds[kind].category }

// Eligibility is the database's answer for one notice: OK says the recipient may be
// pushed to at all (active, onboarded accounts that may interact, no mute, restrict or
// block, the chat open and unmuted, the category switched on); ActorName is the actor's
// display name, which may be shown because the recipient can already see them.
type Eligibility struct {
	OK        bool
	ActorName string
}

// Config wires a Dispatcher. Sender, Targets and Check are required.
type Config struct {
	Sender  Sender
	Targets func(ctx context.Context, users []string) ([]Target, error)
	// Online reports a live socket on this node; nil means nobody is online.
	Online func(user string) bool
	// Check runs the database rules; it fails closed (an error sends nothing).
	Check func(ctx context.Context, n Notice, category string) (Eligibility, error)
	// Forget clears a dead token, only if the device still holds that exact token.
	Forget func(ctx context.Context, t Target) error
	// Queue is the bounded queue length (default 1024); DailyCap the pushes one recipient
	// gets per rolling 24 hours (default 200); Attempts the tries per device (default 4).
	Queue, DailyCap, Attempts int
	// Backoff is the wait before retry number attempt (1-based); default 0.5s doubling, with jitter.
	Backoff func(attempt int) time.Duration
	Now     func() time.Time
}

// Stats are cumulative counters, for logs and tests.
type Stats struct {
	Queued, Dropped, Sent, Failed, Forgotten, Retried int64
}

// Dispatcher decides, looks up tokens and sends, all off the request path. Its
// queue is bounded: under overload pushes are dropped, which only delays delivery
// until the app next opens or syncs.
//
// Coalescing and the daily cap are kept in memory per node, so they reset when the
// process restarts and are not shared between nodes. The worst case is a few
// duplicate wake-ups, never a lost message.
type Dispatcher struct {
	cfg  Config
	jobs chan Notice
	wg   sync.WaitGroup

	queued, dropped, sent, failed, forgotten, retried atomic.Int64

	mu        sync.Mutex
	last      map[string]time.Time // coalescing: key -> last push
	daily     map[string]*dayCount // recipient -> pushes in the current window
	secDaily  map[string]*dayCount // recipient -> security pushes in the current window
	lastSweep time.Time
}

type dayCount struct {
	start time.Time
	n     int
}

const (
	defaultQueue    = 1024
	defaultDailyCap = 200
	defaultAttempts = 4
	sweepEvery      = time.Minute
	sweepAbove      = 4096
)

func NewDispatcher(cfg Config) *Dispatcher {
	if cfg.Queue <= 0 {
		cfg.Queue = defaultQueue
	}
	if cfg.DailyCap <= 0 {
		cfg.DailyCap = defaultDailyCap
	}
	if cfg.Attempts <= 0 {
		cfg.Attempts = defaultAttempts
	}
	if cfg.Backoff == nil {
		cfg.Backoff = backoff
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Online == nil {
		cfg.Online = func(string) bool { return false }
	}
	return &Dispatcher{cfg: cfg, jobs: make(chan Notice, cfg.Queue), last: map[string]time.Time{}, daily: map[string]*dayCount{}, secDaily: map[string]*dayCount{}}
}

// backoff is 0.5s, 1s, 2s … with up to 50% jitter added, so retries from many
// workers do not arrive together.
func backoff(attempt int) time.Duration {
	d := 500 * time.Millisecond << min(attempt-1, 6)
	return d + time.Duration(rand.Int64N(int64(d/2)+1))
}

// Stats returns the counters so far.
func (d *Dispatcher) Stats() Stats {
	return Stats{d.queued.Load(), d.dropped.Load(), d.sent.Load(), d.failed.Load(), d.forgotten.Load(), d.retried.Load()}
}

// key is what coalescing groups by: a conversation for chat, an actor for everything else.
func (n Notice) key() string {
	if n.Kind == "chat" {
		return n.Recipient + "|chat|" + n.Conversation
	}
	return n.Recipient + "|" + n.Kind + "|" + n.Actor
}

// collapseKey is the device-side counterpart: one slot per conversation, one for all social pushes.
func (n Notice) collapseKey() string {
	switch n.Kind {
	case "chat":
		return "chat-" + n.Conversation
	case "device", "device-revoked":
		return "device"
	case KindDeletion:
		return "deletion"
	case "support":
		return "support"
	case "group_invite":
		return "group-invite"
	}
	return "social"
}

// Notify queues a push. It never blocks and never fails the caller: an unknown
// kind, the actor themselves, a recipient with a live socket on this node and a
// push still inside its coalescing window are dropped here; a full queue drops
// with a log line and a count.
func (d *Dispatcher) Notify(n Notice) {
	spec, ok := kinds[n.Kind]
	// A device notice is about the account itself, so its actor is the recipient.
	if !ok || n.Recipient == "" || (n.Recipient == n.Actor && spec.category != CategorySecurity) || (n.Kind == "chat" && n.Conversation == "") {
		return
	}
	// A security push ignores both of the rules below: whoever holds a stolen credential can keep a socket
	// open for the account, and a window or the chat cap must not be a way to swallow the notice.
	if spec.category != CategorySecurity {
		// A live socket on another node is not seen here; that costs at most one redundant wake-up.
		if d.cfg.Online(n.Recipient) {
			return
		}
		if d.coalesced(n, spec) {
			return
		}
	}
	select {
	case d.jobs <- n:
		d.queued.Add(1)
	default:
		d.dropped.Add(1)
		slog.Warn("push queue full; push dropped", "kind", n.Kind, "dropped", d.dropped.Load())
	}
}

// Run starts workers that send queued pushes until ctx ends; Wait returns once they have.
func (d *Dispatcher) Run(ctx context.Context, workers int) {
	for range workers {
		d.wg.Go(func() {
			for {
				select {
				case <-ctx.Done():
					return
				case n := <-d.jobs:
					d.process(ctx, n)
				}
			}
		})
	}
}

// Wait blocks until every worker started by Run has returned.
func (d *Dispatcher) Wait() { d.wg.Wait() }

func (d *Dispatcher) process(ctx context.Context, n Notice) {
	spec := kinds[n.Kind]
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	// The recipient may have connected while this waited in the queue (not for a security push, see Notify).
	if spec.category != CategorySecurity && d.cfg.Online(n.Recipient) {
		return
	}
	var verdict Eligibility
	var targets []Target
	if n.Kind == KindDeletion {
		// The account is pending deletion and its tokens are cleared, so the caller's own list is the only one.
		verdict, targets = Eligibility{OK: true}, n.Targets
	} else {
		var err error
		if verdict, err = d.cfg.Check(ctx, n, spec.category); err != nil {
			slog.Warn("push eligibility check failed; nothing sent", "kind", n.Kind, "reason", logscrub.Err(err))
			return
		}
		if !verdict.OK {
			return
		}
		if targets, err = d.cfg.Targets(ctx, []string{n.Recipient}); err != nil {
			slog.Warn("push lookup failed", "reason", logscrub.Err(err))
			return
		}
	}
	if len(targets) == 0 {
		return
	}
	if !d.admit(n, spec) {
		return
	}
	m := message(n, spec, verdict.ActorName)
	for _, t := range targets {
		if t.UserID != n.Recipient || (n.Device != "" && t.DeviceID == n.Device) {
			continue
		}
		d.deliver(ctx, t, m)
	}
}

// message builds the payload. The only variable text is the actor's display name,
// and only for kinds that allow it; chat is always the generic line.
func message(n Notice, spec kindSpec, actorName string) Message {
	body := spec.body
	if name := shortName(actorName); spec.named != "" && name != "" {
		body = fmt.Sprintf(spec.named, name)
	}
	data := map[string]string{"kind": n.Kind}
	if n.Kind == "chat" {
		data["conversationId"] = n.Conversation
	} else if n.Kind == KindDeletion {
		// Content-free: the app says the account is scheduled for deletion and offers to cancel.
		data["kind"] = KindDeletion
	} else if n.Kind == "group_invite" {
		// Content-free: the app opens the chat list, where the invite waits.
		data["kind"] = "group_invite"
	} else if n.Kind == "support" {
		// Content-free: the app opens the support conversations.
		data["kind"] = "support"
	} else if n.Kind == "device" || n.Kind == "device-revoked" {
		// Content-free: the app opens the chat devices screen and lists what the relay knows.
		data["kind"] = "device"
	} else {
		// The app opens Activity for anything that is not a chat.
		data["kind"] = "social"
		data["event"] = n.Kind
	}
	return Message{Kind: n.Kind, Title: title, Body: body, Data: data, CollapseKey: n.collapseKey()}
}

// shortName makes a display name safe for a lock screen: no control characters, at most 40 runes.
func shortName(s string) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return -1
		}
		return r
	}, s)
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > 40 {
		s = string(r[:40]) + "…"
	}
	return s
}

// deliver sends to one device, retrying transient failures a bounded number of times.
func (d *Dispatcher) deliver(ctx context.Context, t Target, m Message) {
	for attempt := 1; ; attempt++ {
		err := d.cfg.Sender.Send(ctx, t, m)
		if err == nil {
			d.sent.Add(1)
			return
		}
		if errors.Is(err, ErrUnregistered) {
			d.forgotten.Add(1)
			if d.cfg.Forget != nil {
				// The request context may be gone already; clearing a dead token must still happen.
				fctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
				if ferr := d.cfg.Forget(fctx, t); ferr != nil {
					slog.Warn("push token not cleared", "device", t.DeviceID, "reason", logscrub.Err(ferr))
				}
				cancel()
			}
			return
		}
		if errors.Is(err, ErrConfig) {
			// The provider refused because of OUR configuration (a token from another Firebase project, wrong
			// credentials): every token would be refused the same way, so none is a dead token and none is
			// cleared. An operator has to fix the configuration.
			d.failed.Add(1)
			pushConfigErrors.Inc(t.Provider)
			slog.Error("push refused because of the configuration; tokens are kept", "provider", t.Provider, "kind", m.Kind, "reason", logscrub.Err(err))
			return
		}
		var transient *TransientError
		if !errors.As(err, &transient) || attempt >= d.cfg.Attempts || ctx.Err() != nil {
			d.failed.Add(1)
			slog.Warn("push send failed", "provider", t.Provider, "kind", m.Kind, "attempts", attempt, "reason", logscrub.Err(err))
			return
		}
		d.retried.Add(1)
		wait := max(d.cfg.Backoff(attempt), transient.After)
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			d.failed.Add(1)
			return
		}
	}
}

// coalesced reports whether a push of this kind to this recipient went out inside its window.
func (d *Dispatcher) coalesced(n Notice, spec kindSpec) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	at, ok := d.last[n.key()]
	return ok && d.cfg.Now().Sub(at) < spec.window
}

// admit reserves the coalescing slot and one unit of the recipient's daily cap
// atomically, so concurrent workers cannot both pass the same window.
func (d *Dispatcher) admit(n Notice, spec kindSpec) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	now := d.cfg.Now()
	d.sweepLocked(now)
	if spec.category == CategorySecurity {
		// Its own small cap, separate from chat and social; no window.
		c := d.secDaily[n.Recipient]
		if c == nil || now.Sub(c.start) >= 24*time.Hour {
			c = &dayCount{start: now}
			d.secDaily[n.Recipient] = c
		}
		if c.n >= SecurityDailyCap {
			slog.Warn("security push daily cap reached", "kind", n.Kind)
			return false
		}
		c.n++
		return true
	}
	if at, ok := d.last[n.key()]; ok && now.Sub(at) < spec.window {
		return false
	}
	c := d.daily[n.Recipient]
	if c == nil || now.Sub(c.start) >= 24*time.Hour {
		c = &dayCount{start: now}
		d.daily[n.Recipient] = c
	}
	if c.n >= d.cfg.DailyCap {
		slog.Warn("push daily cap reached", "kind", n.Kind)
		return false
	}
	c.n++
	d.last[n.key()] = now
	return true
}

// sweepLocked forgets expired entries, at most once a minute and only when the maps are large.
func (d *Dispatcher) sweepLocked(now time.Time) {
	if len(d.last)+len(d.daily)+len(d.secDaily) < sweepAbove || now.Sub(d.lastSweep) < sweepEvery {
		return
	}
	d.lastSweep = now
	longest := time.Duration(0)
	for _, s := range kinds {
		longest = max(longest, s.window)
	}
	for k, at := range d.last {
		if now.Sub(at) >= longest {
			delete(d.last, k)
		}
	}
	for u, c := range d.daily {
		if now.Sub(c.start) >= 24*time.Hour {
			delete(d.daily, u)
		}
	}
	for u, c := range d.secDaily {
		if now.Sub(c.start) >= 24*time.Hour {
			delete(d.secDaily, u)
		}
	}
}
