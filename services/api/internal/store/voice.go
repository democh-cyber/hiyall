package store

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// Voice clips on posts and stories (docs/api/27-stories-notices-support.md). A clip is a media_assets row with
// purpose 'voice': the same upload slot, quota and cleanup as a photo, a different processing step (validation of
// the audio container, no re-encoding, no scanner).

// MediaReadyAudio marks a pending voice upload ready. variants.audio is the stored object, size the stored size and
// durationMs what ValidateAudio read from the file. Like a photo, an unattached clip expires after a day.
func (s *Store) MediaReadyAudio(ctx context.Context, owner, id string, durationMs int, key string, size int64) error {
	variants, _ := json.Marshal(map[string]string{"audio": key})
	tag, err := s.Pool.Exec(ctx, `UPDATE media_assets SET status='ready',duration_ms=$3,variants=$4,size_bytes=$5,expires_at=now()+interval '1 day'
 WHERE media_id=$1 AND owner_id=$2 AND status='pending' AND purpose='voice'`, id, owner, durationMs, variants, size)
	if err == nil && tag.RowsAffected() == 0 {
		err = domain.ErrNotFound
	}
	return err
}

// claimVoice attaches the author's ready, unattached voice clip to the post or story being made and returns its
// duration. A nil id is no clip. The clip must be the author's own, ready, uploaded for voice and not yet used
// (409 MEDIA_NOT_READY otherwise), and no longer than the member's entitlement (422 VOICE_TOO_LONG).
func claimVoice(ctx context.Context, tx pgx.Tx, owner string, id *string, e domain.Entitlements) (*int, error) {
	if id == nil {
		return nil, nil
	}
	var ms int
	err := tx.QueryRow(ctx, `UPDATE media_assets SET attached=true WHERE media_id=(
 SELECT media_id FROM media_assets WHERE media_id=$1 AND owner_id=$2 AND purpose='voice' AND status='ready' AND NOT attached FOR NO KEY UPDATE)
 RETURNING coalesce(duration_ms,0)`, *id, owner).Scan(&ms)
	if err == pgx.ErrNoRows {
		return nil, domain.ErrMediaNotReady
	}
	if err != nil {
		return nil, err
	}
	if ms > (e.PulseVoiceSeconds+1)*1000 {
		return nil, domain.ErrVoiceTooLong
	}
	return &ms, nil
}

// voiceView is the JSON of a post's or story's clip: nil when there is none or its object is gone.
func voiceView(sign Signer, id *string, ms *int, variants map[string]string) *domain.VoiceView {
	if id == nil || ms == nil || variants["audio"] == "" {
		return nil
	}
	return &domain.VoiceView{MediaID: *id, URL: sign(variants["audio"]), DurationMs: *ms}
}
