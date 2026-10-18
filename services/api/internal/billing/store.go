package billing

import (
	"errors"
	"time"
)

// What a store verification yields, in one shape for both stores.
//
// The errors are the three things a caller must tell apart: the store does not know (or does not confirm) the purchase, the store
// could not be asked right now, and our own credentials are refused (a deployment problem, never the member's).
var (
	ErrInvalid       = errors.New("the store does not confirm this purchase")
	ErrUnavailable   = errors.New("the store could not be reached")
	ErrMisconfigured = errors.New("the store refused our credentials")
)

// Purchase states.
const (
	StateVerified = "verified"
	StatePending  = "pending"
)

// Subscription statuses (subscriptions.status).
const (
	SubActive  = "active"
	SubGrace   = "grace"
	SubOnHold  = "on_hold"
	SubPaused  = "paused"
	SubExpired = "expired"
	SubRevoked = "revoked"
)

// SubState is a subscription as a store last described it.
type SubState struct {
	Status      string
	PeriodEnd   time.Time
	GraceUntil  *time.Time
	AutoRenew   bool
	OriginalKey string // the store's stable id of the subscription (Google purchase token, Apple original transaction id)
}

// Verified is a store's answer about one purchase, already checked against our app (package or bundle id).
type Verified struct {
	Store string
	// StoreProductID is the store's product id.
	StoreProductID string
	// TxKey is the identifier that makes this purchase unique (Google purchase token, Apple transaction id). Hash it before storing.
	TxKey string
	// State is StateVerified or StatePending. A canceled or unknown purchase is an ErrInvalid, not a Verified.
	State string
	// Test is true for a license-tester purchase (Google) or a Sandbox transaction (Apple).
	Test bool
	// AccountID is the member id the app attached to the purchase (Google obfuscatedExternalAccountId, Apple appAccountToken), "" when none.
	AccountID string
	// Revoked is true when the store says the purchase was refunded or revoked (Apple revocationDate).
	Revoked bool
	// Subscription is set for a subscription.
	Subscription *SubState
	// NeedsAck is true when the store still waits for us to acknowledge the purchase (Google: refunded after 3 days otherwise).
	NeedsAck bool
}
