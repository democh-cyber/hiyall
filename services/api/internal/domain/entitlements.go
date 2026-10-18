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
	// Wave 7 social (docs/api/27-stories-notices-support.md). PulseSearchPagesPerDay caps the pages of post and story
	// search a member reads per UTC day; SupportMessagesPerDay the messages they send to support per UTC day;
	// PulseVoiceSeconds the length of a voice clip on a post or story.
	PulseSearchPagesPerDay int
	SupportMessagesPerDay  int
	PulseVoiceSeconds      int
	// Group chat (docs/api/29-group-chat.md). GroupMembersMax is the people in one group, pending invites included;
	// GroupsPerMemberMax the groups a member is in or invited to; GroupsCreatedPerDay and GroupInvitesPerDay count per UTC
	// calendar day (member_daily_counts), nothing refunded. Each is enforced by the API, never by the app.
	GroupMembersMax     int
	GroupsPerMemberMax  int
	GroupsCreatedPerDay int
	GroupInvitesPerDay  int
	// ChatPinsMax is how many conversations a member may pin in their chat list (409 PIN_LIMIT past it).
	ChatPinsMax int
	// Voice messages and videos in chat (docs/api/26-chat-voice-video-and-list.md). The server only ever sees
	// ciphertext: it enforces the BYTE caps (VoiceMaxBlobBytes, VideoMaxBlobBytes: the largest ciphertext of one
	// voice or video blob, 413 TOO_LARGE past it), and the member's blob quotas count those bytes. The *Seconds
	// values CANNOT be enforced by the server, because the duration lives inside the encrypted descriptor; they
	// are the policy the apps apply from their copy of the Free value (the open point "the app hardcodes some
	// caps" in docs/architecture/11-plans-and-entitlements.md), so a modified app can exceed them as far as the
	// byte cap allows.
	VoiceMaxSeconds   int
	VoiceMaxBlobBytes int64
	VideoMaxSeconds   int
	VideoMaxBlobBytes int64
	// Profile v2 (docs/api/25-profile-and-discovery-v2.md): how many languages (each with a level), interests,
	// personality tags and gallery photos a profile may hold. Gallery photos are ordinary photo uploads and also
	// count towards the upload and storage limits above.
	LanguagesMax       int
	InterestsMax       int
	PersonalityTagsMax int
	ProfilePhotosMax   int

	// Plans and coins (plans.go, docs/api/28-billing.md). Plan is the plan the numbers above belong to. Enforced says
	// whether Features and the coin prices below apply: false in the beta (PLANS_ENFORCED off), for members who cannot
	// buy anything and for Free() / EntitlementsFor, so code that reads them is a no-op until the resolver
	// (Resolve) turns them on. FreeNewChatsPerDay is the conversations a member may start per rolling 24 hours before
	// each further one costs ChatSlotCoinCost coins (0: no such limit). Premium features are checked with Allows.
	Plan                  Plan
	Enforced              bool
	Features              Features
	FreeNewChatsPerDay    int
	ChatSlotCoinCost      int
	ProfileDetailCoinCost int
	ProfileDetailDays     int
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
		PulseSearchPagesPerDay:            300,
		SupportMessagesPerDay:             20,
		PulseVoiceSeconds:                 MaxVoiceSeconds,
		ChatPinsMax:                       5,
		GroupMembersMax:                   10,
		GroupsPerMemberMax:                30,
		GroupsCreatedPerDay:               5,
		GroupInvitesPerDay:                30,
		VoiceMaxSeconds:                   300,
		VoiceMaxBlobBytes:                 8 << 20,
		VideoMaxSeconds:                   60,
		VideoMaxBlobBytes:                 40 << 20,

		LanguagesMax:       5,
		InterestsMax:       10,
		PersonalityTagsMax: 5,
		ProfilePhotosMax:   8,
	}
	free.Plan = PlanFree
	free.Features = AllFeaturesOn()
	switch plan {
	case PlanPremium:
		return premiumFrom(free)
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
