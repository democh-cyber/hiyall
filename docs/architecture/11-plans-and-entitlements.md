# Plans and entitlements

**Status:** structure only. Hiyall has no paid plans yet, and **nothing about plans is user-visible**: no billing, no plan column in the database, no plan field in any API response, no plan screen or upsell in the app. Every member is on the Free plan, which is today's behaviour.

## Principle

Limits and capabilities are data, resolved per member, never constants spread through the code. Code that enforces a per-member limit receives the member's `domain.Entitlements` (as the Signer is passed to store methods) and reads the number from it. When a Pro tier arrives it is a new set of numbers and a new answer from one resolver, not a rewrite of the quota code.

## The structure

`services/api/internal/domain/entitlements.go`:

```go
type Plan string
const PlanFree Plan = "free"

type Entitlements struct {
	UploadsPerDay       int           // Pulse photo upload slots per rolling 24 h, all purposes
	UploadBytesPerDay   int64         // declared bytes of those slots
	PendingUploads      int           // slots handed out and not completed
	PostsPerDay         int
	StoriesPerDay       int
	StoryLifetimes      []int         // hours a story may be set to stay up (the app offers these)
	StorageBytes        int64         // live stored photos (sum of size_bytes of ready media)
	VisitorListLimit    int           // most recent visitors the owner's visitor list returns
	BlobsPerDay         int           // encrypted chat attachments per rolling 24 h
	BlobBytesPerDay     int64
	PendingBlobs        int
	LinkedBlobRetention time.Duration // how long a blob is kept after its message
	NewConversationsPerDay int        // conversations the member may start per rolling 24 h
}

func EntitlementsFor(plan Plan) Entitlements // unknown plan -> Free; never grants more
func Free() Entitlements
```

Free values (today's limits, for every member including minors):

| Field | Free |
|---|---|
| `UploadsPerDay` / `UploadBytesPerDay` / `PendingUploads` | 50 / 300 MiB / 50 |
| `PostsPerDay` / `StoriesPerDay` | 20 / 30 |
| `StoryLifetimes` | 6, 12, 24 hours |
| `StorageBytes` | 2 GiB |
| `VisitorListLimit` | 200 |
| `BlobsPerDay` / `BlobBytesPerDay` / `PendingBlobs` | 100 / 300 MiB / 10 |
| `LinkedBlobRetention` | 30 days |
| `NewConversationsPerDay` | 40 |

## Where the resolver lives

`httpapi/entitlements.go`: `(*API).entitlementsFor(ctx, userID) domain.Entitlements`. It returns `EntitlementsFor(PlanFree)` for everyone, or the result of the `API.Entitlements` function field when one is set (tests set it to prove limits come from the value: a larger tier lets the 21st post and 51st upload through and a 48 hour story, a smaller one stops earlier). Handlers call it once per request and pass the value into the store: `CreateUpload`, `CreatePost`, `CreateStory`, `CreateBlobSlot`, `OpenConversation` and `SendMessage` (message links start the retention). The store never reads limits from constants.

## How a Pro tier would plug in

1. Add a `subscriptions` table (user, plan, status, period end) and a store lookup, cached for a short time per member.
2. Make the resolver return `domain.EntitlementsFor(plan)` for the member's active plan (free when none, lapsed or unknown), and add `PlanPro` with its numbers in `EntitlementsFor`.
3. Add `GET /v1/me/entitlements` so the app can read its limits (see the open point below).
4. Only then add billing, plan names in the UI and upsell copy.

Downgrades need a rule for what happens above a smaller limit: this design makes them harmless for rolling counts (nothing is deleted, new items are refused until the count falls) but a smaller storage cap leaves a member over it until they delete something, which is the same refusal the cap gives today.

## Knobs

Tiered now means the value is already an `Entitlements` field. Candidate later means it is a candidate for a free-versus-Pro split but is a plain constant or an app value today.

| Knob | Where it is today | Status |
|---|---|---|
| Posts per day (20) | `Entitlements.PostsPerDay` | tiered now |
| Stories per day (30) | `Entitlements.StoriesPerDay` | tiered now |
| Story lifetime choices (6, 12, 24 h; default 24 h) | `Entitlements.StoryLifetimes` (`AllowsStoryLifetime`); the default stays `domain.StoryLifetime` | tiered now |
| Pulse upload slots per day (50), declared bytes per day (300 MiB), pending uploads (50) | `Entitlements` | tiered now |
| Live photo storage (2 GiB) | `Entitlements.StorageBytes` | tiered now |
| Visitor list length (200 most recent) | `Entitlements.VisitorListLimit` | tiered now |
| Chat blobs per day (100), chat bytes per day (300 MiB), pending slots (10) | `Entitlements` | tiered now |
| Linked chat blob retention (30 days) | `Entitlements.LinkedBlobRetention` | tiered now |
| New conversations started per day (40) | `Entitlements.NewConversationsPerDay` | tiered now |
| Photos per post (10) | `domain.MaxPostMedia` | candidate later |
| Post, story and comment length (2200, 280, 1000) | `domain` constants | candidate later |
| One photo upload size (15 MB) | `media.MaxUploadBytes`, app `maxPhotoBytes` | candidate later (the app copy must come from the server first) |
| Chat photo size (4 MiB full, 256 KiB thumb) and picker size (4096 px) | `domain/chatmedia.go`, app `chat_attachment.dart`, `chat_photo.dart` | candidate later (hardcoded in the app) |
| Future video length and size | not accepted yet | candidate later |
| Nearby radius (default 25 km, up to 100 km) and Nearby or discovery filters | `domain/nearby.go`, `domain/discovery.go` | candidate later |
| Number of circles or lists | not built | candidate later |
| Chat history retention | not built (messages are kept) | candidate later |
| Space capacity (members per space) | `domain/spaces.go` | candidate later |
| Per-account rate limiters (uploads, content, messages, search) | in-memory limiters in `httpapi/server.go` | candidate later |

Not knobs, and not meant to differ by plan: protocol and safety constants (crypto chunk sizes and the four blobs per message, the 40 megapixel decode cap, the 15 minute upload URL lifetime, age-band rules, text validity rules). Some of them appear in the candidate list because a plan could still raise a user-facing number such as a text length.

## Open point: the app hardcodes some caps

The app carries its own copies of some limits (the 15 MB photo cap, the 4 MiB chat photo cap, the 4096 px picker size, the 10 photos per post). The server enforces every one of them, so a modified app gains nothing, but the app cannot show or use a larger limit by itself. Before any of them can differ per plan the server must tell the client its limits, for example `GET /v1/me/entitlements` returning the member's numbers, and the app must read them instead of its constants (falling back to the Free values when the call fails). Until then, raising one of these limits for a plan needs an app release, so do not sell one.
