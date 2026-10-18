package store

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Data export (GET /v1/me/export, docs/api/22-account-deletion-and-export.md): one JSON document with
// what the server holds about the member, streamed from a single read-only snapshot. Each list is capped
// and the document as a whole too, and a cut is named in "truncated" at the end instead of failing.
//
// What it leaves out, on purpose: chat content (end-to-end encrypted, the server cannot read it), the
// birth date (no endpoint ever returns it, even to its owner; the age band is included) and any
// coordinates (only whether a point is being shared and when it was last updated).
const (
	exportVersion = 1
	// ExportMaxBytes caps the document; ExportListCap caps the rows of any one list.
	ExportMaxBytes = 32 << 20
	ExportListCap  = 10000
)

// ExportOptions configures ExportAccount; zero values mean the caps above.
type ExportOptions struct {
	// Sign makes a download link for an object key, valid domain.ExportURLLifetime. Nil, or a signer that
	// answers "", leaves the link out (media storage not configured).
	Sign     Signer
	MaxBytes int64
	ListCap  int
}

// exportWriter writes the document as it is produced. Rows come out of the database as ready JSON (every
// query builds its row with jsonb_build_object), so the Go side only frames and counts them.
type exportWriter struct {
	w         *bufio.Writer
	written   int64
	max       int64
	cap       int
	first     []bool
	closers   []string
	truncated []string
	err       error
}

func (e *exportWriter) raw(s string) {
	if e.err != nil {
		return
	}
	n, err := e.w.WriteString(s)
	e.written += int64(n)
	e.err = err
}

func (e *exportWriter) key(name string) {
	top := len(e.first) - 1
	if !e.first[top] {
		e.raw(",")
	}
	e.first[top] = false
	if name != "" {
		b, _ := json.Marshal(name)
		e.raw(string(b))
		e.raw(":")
	}
}

func (e *exportWriter) begin(name, open string) {
	e.key(name)
	e.raw(open)
	e.first = append(e.first, true)
	e.closers = append(e.closers, map[string]string{"[": "]", "{": "}"}[open])
}

// end closes the innermost open array or object.
func (e *exportWriter) end() {
	e.first = e.first[:len(e.first)-1]
	e.raw(e.closers[len(e.closers)-1])
	e.closers = e.closers[:len(e.closers)-1]
}

// unwind closes everything still open inside the document's own object, after a failure.
func (e *exportWriter) unwind() {
	for len(e.closers) > 0 {
		e.end()
	}
}

func (e *exportWriter) value(name string, v any) {
	b, _ := json.Marshal(v)
	e.key(name)
	e.raw(string(b))
}

// one writes the single JSON value a query returns (null when it returns nothing).
func (e *exportWriter) one(ctx context.Context, q querier, name, query string, args ...any) error {
	var raw []byte
	err := q.QueryRow(ctx, query, args...).Scan(&raw)
	if err != nil && err != pgx.ErrNoRows {
		return err
	}
	e.key(name)
	if raw == nil {
		raw = []byte("null")
	}
	e.raw(string(raw))
	return e.err
}

// list writes the rows of a query (one JSON value each) as an array, cutting it at the caps.
func (e *exportWriter) list(ctx context.Context, q querier, name, query string, args ...any) error {
	rows, err := q.Query(ctx, fmt.Sprintf("%s LIMIT %d", query, e.cap+1), args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	e.begin(name, "[")
	count := 0
	for rows.Next() {
		var raw []byte
		if err = rows.Scan(&raw); err != nil {
			return err
		}
		if count >= e.cap || e.written > e.max {
			e.truncated = append(e.truncated, name)
			break
		}
		e.key("")
		e.raw(string(raw))
		count++
		if e.err != nil {
			return e.err
		}
	}
	if err = rows.Err(); err != nil {
		return err
	}
	e.end()
	return e.err
}

// ExportAccount writes the member's data to w. It reports complete=false when a database error cut the
// document short; the document is still valid JSON, and "complete" says so at its end. An error from w
// (the client went away) is returned as is.
func (s *Store) ExportAccount(ctx context.Context, user string, w io.Writer, o ExportOptions) (complete bool, err error) {
	if o.MaxBytes <= 0 {
		o.MaxBytes = ExportMaxBytes
	}
	if o.ListCap <= 0 {
		o.ListCap = ExportListCap
	}
	tx, err := s.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	// An export reads a whole account and streams it to a client, so it gets longer limits than a request
	// (SET LOCAL ends with the transaction): the pool's 5 s statement and 15 s idle-in-transaction timeouts
	// would cut a large export or one to a slow connection.
	if _, err = tx.Exec(ctx, `SELECT set_config('statement_timeout','60000',true),set_config('idle_in_transaction_session_timeout','120000',true),set_config('lock_timeout','5000',true)`); err != nil {
		return false, err
	}
	e := &exportWriter{w: bufio.NewWriterSize(w, 32<<10), max: o.MaxBytes, cap: o.ListCap, first: []bool{true}}
	e.raw("{")
	e.value("exportVersion", exportVersion)
	e.value("generatedAt", time.Now().UTC())
	e.value("note", "Everything Hiyall holds about this account, as of the time above. Chat messages are end-to-end encrypted and live only on your devices, so they are not in this file. The date of birth you entered is never returned by any part of Hiyall; your age band is included. Links in \"media\" stop working 24 hours after generatedAt.")
	failed := e.sections(ctx, tx, user, o)
	if failed != nil && e.err == nil {
		// A database failure mid-way: close the document cleanly and say it is incomplete.
		e.unwind()
		e.value("truncated", e.truncated)
		e.value("complete", false)
		e.raw("}\n")
		_ = e.w.Flush()
		return false, failed
	}
	if e.err != nil {
		return false, e.err
	}
	trunc := e.truncated
	if trunc == nil {
		trunc = []string{}
	}
	e.value("truncated", trunc)
	e.value("complete", true)
	e.raw("}\n")
	if e.err != nil {
		return false, e.err
	}
	if err = e.w.Flush(); err != nil {
		return false, err
	}
	return true, nil
}

// sections writes every part of the document. The first error stops it.
func (e *exportWriter) sections(ctx context.Context, q querier, user string, o ExportOptions) error {
	steps := []func() error{
		func() error {
			return e.one(ctx, q, "account", `SELECT jsonb_build_object('userId',u.user_id,'username',p.username,'status',u.status,'createdAt',u.created_at,'ageBand',age_band(u.user_id),
 'profile',p.data,'profileVersion',p.version,'profileUpdatedAt',p.updated_at,
 'onboarding',jsonb_build_object('ageDeclaredAt',o.age_declared_at,'termsVersion',o.terms_version,'termsAcceptedAt',o.terms_accepted_at,'completedAt',o.completed_at),
 'lastExportAt',u.last_export_at)
 FROM users u JOIN profiles p ON p.user_id=u.user_id LEFT JOIN onboarding o ON o.user_id=u.user_id WHERE u.user_id=$1`, user)
		},
		func() error {
			return e.one(ctx, q, "settings", `SELECT jsonb_build_object('privacy',q.data,'privacyVersion',q.version,'privacyUpdatedAt',q.updated_at,
 'notifications',coalesce((SELECT jsonb_build_object('enabled',n.enabled,'chat',n.chat,'social',n.social,'follows',n.follows,'comments',n.comments,'reactions',n.reactions,'replies',n.replies,'friendRequests',n.friend_requests,'visits',n.visits,'hideNames',n.hide_names,'updatedAt',n.updated_at) FROM notification_prefs n WHERE n.user_id=$1),jsonb_build_object('enabled',true,'chat',true,'social',true,'visits',false)))
 FROM privacy_settings q WHERE q.user_id=$1`, user)
		},
		func() error {
			return e.one(ctx, q, "interests", `SELECT CASE WHEN jsonb_typeof(data->'interests')='array' THEN data->'interests' ELSE '[]'::jsonb END FROM profiles WHERE user_id=$1`, user)
		},
		func() error {
			return e.list(ctx, q, "posts", `SELECT jsonb_build_object('postId',p.post_id,'body',p.body,'audience',p.audience,'topic',p.topic,'voiceMediaId',p.voice_media_id,'voiceMs',p.voice_ms,'createdAt',p.created_at,'editedAt',p.edited_at,
 'mediaIds',coalesce((SELECT jsonb_agg(pm.media_id ORDER BY pm.position) FROM post_media pm WHERE pm.post_id=p.post_id),'[]'::jsonb),
 'reactionCount',coalesce((SELECT sum(c.reactions) FROM post_counters c WHERE c.post_id=p.post_id),0),
 'commentCount',coalesce((SELECT sum(c.comments) FROM post_counters c WHERE c.post_id=p.post_id),0))
 FROM posts p WHERE p.author_id=$1 AND p.deleted_at IS NULL ORDER BY p.created_at DESC,p.post_id DESC`, user)
		},
		func() error {
			return e.list(ctx, q, "comments", `SELECT jsonb_build_object('commentId',c.comment_id,'postId',c.post_id,'parentId',c.parent_id,'body',c.body,'createdAt',c.created_at)
 FROM comments c WHERE c.author_id=$1 AND c.deleted_at IS NULL ORDER BY c.created_at DESC,c.comment_id DESC`, user)
		},
		func() error {
			return e.list(ctx, q, "reactions", `SELECT jsonb_build_object('postId',r.post_id,'reaction',r.reaction,'createdAt',r.created_at) FROM post_reactions r WHERE r.user_id=$1 ORDER BY r.created_at DESC,r.post_id DESC`, user)
		},
		func() error {
			return e.list(ctx, q, "saves", `SELECT jsonb_build_object('postId',s.post_id,'savedAt',s.saved_at) FROM saved_posts s WHERE s.user_id=$1 ORDER BY s.saved_at DESC,s.post_id DESC`, user)
		},
		func() error {
			return e.list(ctx, q, "stories", `SELECT jsonb_build_object('storyId',st.story_id,'body',st.body,'background',st.background,'textStyle',st.text_style,'audience',st.audience,'topic',st.topic,'voiceMediaId',st.voice_media_id,'voiceMs',st.voice_ms,'mediaId',st.media_id,'createdAt',st.created_at,'expiresAt',st.expires_at)
 FROM stories st WHERE st.author_id=$1 AND st.deleted_at IS NULL ORDER BY st.created_at DESC,st.story_id DESC`, user)
		},
		// People: ids and usernames of accounts that are active and that the member may still see (not
		// blocked either way, not in the other age band), as the app's own lists do.
		func() error {
			e.begin("connections", "{")
			err := e.list(ctx, q, "following", `SELECT jsonb_build_object('userId',f.followee_id,'username',p.username,'state',f.state,'since',f.created_at)
 FROM follows f JOIN users u ON u.user_id=f.followee_id AND u.status='active' JOIN profiles p ON p.user_id=f.followee_id
 WHERE f.follower_id=$1 AND f.state<>'removed' AND NOT interaction_barred($1::uuid,f.followee_id) ORDER BY f.created_at DESC,f.followee_id DESC`, user)
			if err == nil {
				err = e.list(ctx, q, "followers", `SELECT jsonb_build_object('userId',f.follower_id,'username',p.username,'state',f.state,'since',f.created_at)
 FROM follows f JOIN users u ON u.user_id=f.follower_id AND u.status='active' JOIN profiles p ON p.user_id=f.follower_id
 WHERE f.followee_id=$1 AND f.state<>'removed' AND NOT interaction_barred($1::uuid,f.follower_id) ORDER BY f.created_at DESC,f.follower_id DESC`, user)
			}
			if err == nil {
				err = e.list(ctx, q, "friends", `SELECT jsonb_build_object('userId',o.user_id,'username',p.username,'status',f.status,'requestedByMe',f.requested_by=$1,'since',f.created_at)
 FROM friendships f CROSS JOIN LATERAL (SELECT CASE WHEN f.user_low_id=$1 THEN f.user_high_id ELSE f.user_low_id END AS user_id) o
 JOIN users u ON u.user_id=o.user_id AND u.status='active' JOIN profiles p ON p.user_id=o.user_id
 WHERE (f.user_low_id=$1 OR f.user_high_id=$1) AND f.status IN ('accepted','pending') AND NOT interaction_barred($1::uuid,o.user_id) ORDER BY f.created_at DESC,f.friendship_id DESC`, user)
			}
			if err != nil {
				return err // the document is closed by unwind
			}
			e.end()
			return nil
		},
		// Support conversations with the Hiyall team: plaintext, kept 365 days after a thread closes (docs/api/27).
		func() error {
			return e.list(ctx, q, "support", `SELECT jsonb_build_object('threadId',t.thread_id,'category',t.category,'status',t.status,'createdAt',t.created_at,'closedAt',t.closed_at,
 'messages',coalesce((SELECT jsonb_agg(jsonb_build_object('author',m.author,'body',m.body,'createdAt',m.created_at) ORDER BY m.created_at,m.message_id) FROM support_messages m WHERE m.thread_id=t.thread_id),'[]'::jsonb))
 FROM support_threads t WHERE t.user_id=$1 ORDER BY t.created_at DESC,t.thread_id DESC`, user)
		},
		// Billing (docs/api/28-billing.md): the coin balance and ledger, purchases and subscriptions. Store ids are kept only as hashes and are not exported.
		func() error {
			return e.one(ctx, q, "coins", `SELECT jsonb_build_object('balance',coalesce((SELECT balance FROM coin_balances WHERE user_id=$1),0),
 'ledger',coalesce((SELECT jsonb_agg(jsonb_build_object('reason',l.reason,'delta',l.delta,'balanceAfter',l.balance_after,'createdAt',l.created_at) ORDER BY l.entry_id DESC)
   FROM (SELECT * FROM coin_ledger WHERE user_id=$1 ORDER BY entry_id DESC LIMIT 1000) l),'[]'::jsonb),
 'purchases',coalesce((SELECT jsonb_agg(jsonb_build_object('store',p.store,'productId',p.product_id,'state',p.state,'coins',p.coins,'createdAt',p.created_at) ORDER BY p.created_at DESC)
   FROM (SELECT * FROM purchases WHERE user_id=$1 ORDER BY created_at DESC LIMIT 1000) p),'[]'::jsonb),
 'subscriptions',coalesce((SELECT jsonb_agg(jsonb_build_object('store',s.store,'productId',s.product_id,'status',s.status,'currentPeriodEnd',s.current_period_end,'autoRenew',s.auto_renew,'createdAt',s.created_at) ORDER BY s.created_at DESC)
   FROM (SELECT * FROM subscriptions WHERE user_id=$1 ORDER BY created_at DESC LIMIT 100) s),'[]'::jsonb))`, user)
		},
		func() error {
			return e.list(ctx, q, "blocks", `SELECT jsonb_build_object('userId',b.blocked_id,'username',p.username,'createdAt',b.created_at)
 FROM blocks b LEFT JOIN profiles p ON p.user_id=b.blocked_id WHERE b.blocker_id=$1 ORDER BY b.created_at DESC,b.blocked_id DESC`, user)
		},
		func() error {
			return e.list(ctx, q, "mutes", `SELECT jsonb_build_object('userId',c.target_id,'username',p.username,'until',c.until,'createdAt',c.created_at)
 FROM user_controls c LEFT JOIN profiles p ON p.user_id=c.target_id WHERE c.actor_id=$1 AND c.control='mute' ORDER BY c.created_at DESC,c.target_id DESC`, user)
		},
		func() error {
			return e.list(ctx, q, "restrictions", `SELECT jsonb_build_object('userId',c.target_id,'username',p.username,'createdAt',c.created_at)
 FROM user_controls c LEFT JOIN profiles p ON p.user_id=c.target_id WHERE c.actor_id=$1 AND c.control='restrict' ORDER BY c.created_at DESC,c.target_id DESC`, user)
		},
		func() error {
			return e.list(ctx, q, "sessions", `SELECT jsonb_build_object('sessionId',session_id,'platform',platform,'createdAt',created_at,'lastSeenAt',last_seen_at,'expiresAt',expires_at,'revokedAt',revoked_at)
 FROM sessions WHERE user_id=$1 ORDER BY created_at DESC,session_id DESC`, user)
		},
		func() error {
			return e.list(ctx, q, "devices", `SELECT jsonb_build_object('deviceId',device_id,'platform',platform,'displayName',display_name,'createdAt',created_at,'lastSeenAt',last_seen_at,'revokedAt',revoked_at,
 'identityKey',identity_key,'signingKey',signing_key,'pushRegistered',push_token IS NOT NULL)
 FROM devices WHERE user_id=$1 ORDER BY created_at DESC,device_id DESC`, user)
		},
		func() error {
			return e.list(ctx, q, "notifications", `SELECT jsonb_build_object('notificationId',n.notification_id,'event',n.event,'actorId',n.actor_id,'actorUsername',p.username,'targetId',n.target_id,'createdAt',n.created_at,'readAt',n.read_at)
 FROM notifications n JOIN users a ON a.user_id=n.actor_id AND a.status='active' JOIN profiles p ON p.user_id=n.actor_id
 WHERE n.recipient_id=$1 AND NOT interaction_barred($1::uuid,n.actor_id) ORDER BY n.created_at DESC,n.notification_id DESC`, user)
		},
		func() error {
			e.begin("visits", "{")
			err := e.list(ctx, q, "made", `SELECT jsonb_build_object('profileId',v.profile_id,'username',p.username,'firstVisitedAt',v.first_visited_at)
 FROM profile_visits v JOIN users u ON u.user_id=v.profile_id AND u.status='active' JOIN profiles p ON p.user_id=v.profile_id
 WHERE v.visitor_id=$1 AND NOT interaction_barred($1::uuid,v.profile_id) ORDER BY v.first_visited_at DESC,v.profile_id DESC`, user)
			if err == nil {
				err = e.one(ctx, q, "ownProfileVisitors", `SELECT to_jsonb(`+visitorsSQL("$1::uuid")+`)`, user)
			}
			if err != nil {
				return err // the document is closed by unwind
			}
			e.end()
			return nil
		},
		func() error {
			return e.one(ctx, q, "location", `SELECT jsonb_build_object('sharing',coalesce(l.updated_at>now()-make_interval(hours=>`+fmt.Sprint(domain.LocationFreshHours)+`),false),'updatedAt',l.updated_at)
 FROM users u LEFT JOIN user_locations l ON l.user_id=u.user_id WHERE u.user_id=$1`, user)
		},
		func() error {
			e.begin("spaces", "{")
			err := e.list(ctx, q, "memberships", `SELECT jsonb_build_object('spaceId',m.space_id,'title',s.title,'kind',s.kind,'role',m.role,'state',m.state,'rsvp',m.rsvp,'joinedAt',m.created_at)
 FROM space_members m JOIN spaces s ON s.space_id=m.space_id WHERE m.user_id=$1 ORDER BY m.created_at DESC,m.space_id DESC`, user)
			if err == nil {
				err = e.list(ctx, q, "owned", `SELECT jsonb_build_object('spaceId',s.space_id,'kind',s.kind,'title',s.title,'description',s.description,'rules',s.rules,'visibility',s.visibility,'capacity',s.capacity,
 'startsAt',s.starts_at,'endsAt',s.ends_at,'timezone',s.timezone,'location',s.location,'status',s.status,'memberCount',s.member_count,'createdAt',s.created_at)
 FROM spaces s WHERE s.owner_id=$1 ORDER BY s.created_at DESC,s.space_id DESC`, user)
			}
			if err == nil {
				err = e.list(ctx, q, "entries", `SELECT jsonb_build_object('entryId',x.entry_id,'spaceId',x.space_id,'body',x.body,'createdAt',x.created_at)
 FROM space_entries x WHERE x.author_id=$1 AND x.deleted_at IS NULL ORDER BY x.created_at DESC,x.entry_id DESC`, user)
			}
			if err != nil {
				return err // the document is closed by unwind
			}
			e.end()
			return nil
		},
		func() error {
			// The reporter's own words, never the evidence they chose to share.
			return e.list(ctx, q, "reports", `SELECT jsonb_build_object('reportId',r.report_id,'targetType',r.target_type,'targetId',r.target_id,'reasonCode',r.reason_code,'description',r.description,
 'status',r.status,'createdAt',r.created_at,'resolvedAt',r.resolved_at,'evidenceShared',r.evidence IS NOT NULL)
 FROM reports r WHERE r.reporter_id=$1 ORDER BY r.created_at DESC,r.report_id DESC`, user)
		},
		func() error { return e.media(ctx, q, user, o.Sign) },
		func() error { return e.chat(ctx, q, user) },
	}
	for _, step := range steps {
		if err := step(); err != nil {
			return err
		}
		if e.err != nil {
			return e.err
		}
	}
	return nil
}

// media lists the member's stored photos with download links that stop working after
// domain.ExportURLLifetime.
func (e *exportWriter) media(ctx context.Context, q querier, user string, sign Signer) error {
	rows, err := q.Query(ctx, fmt.Sprintf(`SELECT media_id::text,purpose,status,content_type,size_bytes,width,height,created_at,variants FROM media_assets
 WHERE owner_id=$1 AND status='ready' ORDER BY created_at DESC,media_id DESC LIMIT %d`, e.cap+1), user)
	if err != nil {
		return err
	}
	defer rows.Close()
	e.begin("media", "[")
	count := 0
	for rows.Next() {
		var id, purpose, status, contentType string
		var size int64
		var width, height *int
		var created time.Time
		var variants map[string]string
		if err = rows.Scan(&id, &purpose, &status, &contentType, &size, &width, &height, &created, &variants); err != nil {
			return err
		}
		if count >= e.cap || e.written > e.max {
			e.truncated = append(e.truncated, "media")
			break
		}
		urls := map[string]string{}
		for name, key := range variants {
			if sign != nil {
				if link := sign(key); link != "" {
					urls[name] = link
				}
			}
		}
		item := map[string]any{"mediaId": id, "purpose": purpose, "status": status, "contentType": contentType, "sizeBytes": size, "width": width, "height": height, "createdAt": created.UTC(), "urls": urls}
		b, _ := json.Marshal(item)
		e.key("")
		e.raw(string(b))
		count++
	}
	if err = rows.Err(); err != nil {
		return err
	}
	e.end()
	return e.err
}

// chat is what the server knows about conversations without being able to read them.
func (e *exportWriter) chat(ctx context.Context, q querier, user string) error {
	e.begin("chat", "{")
	e.value("note", "Message content is end-to-end encrypted and is stored only on your devices; Hiyall cannot read it and it is not in this export. This section lists which conversations exist and how many messages passed through them.")
	if err := e.one(ctx, q, "totals", `SELECT jsonb_build_object(
 'conversations',(SELECT count(*) FROM conversation_members WHERE user_id=$1),
 'messagesSent',(SELECT count(*) FROM messages WHERE sender_id=$1),
 'attachmentsUploaded',(SELECT count(*) FROM chat_blobs WHERE uploader_id=$1 AND role='full'))`, user); err != nil {
		return err
	}
	err := e.list(ctx, q, "conversations", `SELECT jsonb_build_object('conversationId',c.conversation_id,'peerId',cm.peer_id,
 'peerUsername',CASE WHEN pu.status='active' AND NOT interaction_barred($1::uuid,cm.peer_id) THEN pp.username END,
 'status',c.status,'createdAt',c.created_at,'lastMessageAt',c.last_message_at,
 'messagesSent',(SELECT count(*) FROM messages m WHERE m.conversation_id=c.conversation_id AND m.sender_id=$1),
 'messagesReceived',(SELECT count(*) FROM messages m WHERE m.conversation_id=c.conversation_id AND m.sender_id<>$1))
 FROM conversation_members cm JOIN conversations c ON c.conversation_id=cm.conversation_id JOIN users pu ON pu.user_id=cm.peer_id LEFT JOIN profiles pp ON pp.user_id=cm.peer_id
 WHERE cm.user_id=$1 ORDER BY cm.sort_at DESC,cm.conversation_id DESC`, user)
	if err != nil {
		return err
	}
	e.end()
	return nil
}
