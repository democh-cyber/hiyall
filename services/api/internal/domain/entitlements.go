package domain

import "time"

// Plan names what a member is entitled to. Hiyall has no paid plans yet, so PlanFree is the only
// one and every member resolves to it. The limits below are data resolved per member, never read
// from package constants, so a later Pro tier is a new case in EntitlementsFor and a new answer
// from the API's resolver (docs/architecture/11-plans-and-entitlements.md). Nothing about plans is
// stored or shown to members yet.
type Plan string

const PlanFree Plan = "free"

// Entitlements are the per-member limits that may differ by plan. Store and handler code takes one
// as a parameter, as it takes a Signer. Limits that protect the protocol or every member alike
// (text length caps, the 15 MB upload cap, the 20 MP decode cap, chat crypto sizes, the in-memory
// rate limiters) are not here: they are listed as candidate knobs in the design note.
type Entitlements struct {
	// Pulse photos: upload slots and declared bytes per rolling 24 hours (all purposes), counted at
	// slot creation whatever became of the upload, and uploads handed out but not completed.
	UploadsPerDay     int
	UploadBytesPerDay int64
	PendingUploads    int
	// Posts and stories per rolling 24 hours, counted by creation time including deleted ones.
	PostsPerDay   int
	StoriesPerDay int
	// StoryLifetimes are the hours a story may be set to stay up (the app offers these as choices). A
	// story sent without one lives StoryLifetime whatever this says.
	StoryLifetimes []int
	// StorageBytes caps a member's live photos: the sum of size_bytes of their ready media.
	StorageBytes int64
	// VisitorListLimit is how many of the most recent visitors of a member's own profile the visitor
	// list returns (the visit count stat is not limited).
	VisitorListLimit int
	// Encrypted chat attachments (docs/api/21-chat-attachments.md): blobs and ciphertext bytes per
	// rolling 24 hours, slots not yet completed, and how long a linked blob is kept after its message.
	BlobsPerDay         int
	BlobBytesPerDay     int64
	PendingBlobs        int
	LinkedBlobRetention time.Duration
	// NewConversationsPerDay caps the conversations a member may START (be the first opener of) per
	// rolling 24 hours, counted by creation time and never refunded. Reopening one does not count.
	NewConversationsPerDay int
	// Daily caps on social actions and on reading the member base (docs/architecture/11-plans-and-entitlements.md#daily-caps).
	// Each counts actions per UTC calendar day in member_daily_counts, behind the member's quota lock, in the
	// transaction that creates the thing; nothing is refunded by undoing it (an unfollow, a cancelled
	// request or a deleted comment still counts). Search pages, profile views and Nearby queries count
	// every request that reaches the database.
	FollowsPerDay         int
	FriendRequestsPerDay  int
	CommentsPerDay        int
	SpacesPerDay          int
	SpaceEntriesPerDay    int
	SearchPagesPerDay     int
	ProfileViewsPerDay    int
	NearbyQueriesPerDay   int
	LocationChangesPerDay int
	// Encrypted chat relay (re-audit CHAT-4). ChatMessagesPerConversationPerDay caps what one member may send
	// in one conversation per rolling 24 hours (every message, reactions included, counted by creation time and
	// never refunded). ChatBacklogPerDevice caps the undelivered envelopes one device may hold on the relay;
	// a send that would push any recipient device past it is refused with 429 RECIPIENT_BACKLOG.
	ChatMessagesPerConversationPerDay int
	ChatBacklogPerDevice              int
	// ChatBacklogPerSenderPerDevice caps how many of those one sender may have waiting on one recipient device
	// (429 RECIPIENT_BACKLOG for that sender only), so one account cannot fill a victim's device alone. It does
	// not apply to the sender's own other devices.
	ChatBacklogPerSenderPerDevice int
}

// EntitlementsFor returns the limits of a plan. An unknown plan gets Free, so a bad value can only
// ever restrict, never grant. A Pro tier would add a case that starts from free and raises numbers.
func EntitlementsFor(plan Plan) Entitlements {
	free := Entitlements{
		UploadsPerDay:          50,
		UploadBytesPerDay:      300 << 20,
		PendingUploads:         50,
		PostsPerDay:            20,
		StoriesPerDay:          30,
		StoryLifetimes:         []int{6, 12, 24},
		StorageBytes:           2 << 30,
		VisitorListLimit:       200,
		BlobsPerDay:            100,
		BlobBytesPerDay:        300 << 20,
		PendingBlobs:           10,
		LinkedBlobRetention:    30 * 24 * time.Hour,
		NewConversationsPerDay: 40,
		FollowsPerDay:          200,
		FriendRequestsPerDay:   50,
		CommentsPerDay:         300,
		SpacesPerDay:           3,
		SpaceEntriesPerDay:     100,
		SearchPagesPerDay:      300,
		ProfileViewsPerDay:     500,
		NearbyQueriesPerDay:    200,
		LocationChangesPerDay:  5,

		ChatMessagesPerConversationPerDay: 2000,
		ChatBacklogPerDevice:              2000,
		ChatBacklogPerSenderPerDevice:     300,
	}
	switch plan {
	case PlanFree:
		return free
	}
	return free
}

// AllowsStoryLifetime says whether hours is one of the lifetimes a story may be given.
func (e Entitlements) AllowsStoryLifetime(hours int) bool {
	for _, h := range e.StoryLifetimes {
		if h == hours {
			return true
		}
	}
	return false
}

// Free is the entitlement set of PlanFree.
func Free() Entitlements { return EntitlementsFor(PlanFree) }
