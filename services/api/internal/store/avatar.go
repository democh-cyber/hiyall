package store

// A profile photo is a media_assets row of purpose 'avatar' whose id the profile keeps as
// data->>'avatarMediaId' (null when there is none). Queries that show a person join it once
// per row, so a page of people costs no extra round trips. A photo that is not ready or was
// deleted joins to nothing, so the person simply renders without one.

// avatarJoin attaches the ready avatar media of profile row p as alias m. The owner check
// keeps a stale or forged id in the profile data from ever showing someone else's photo.
func avatarJoin(m, p string) string {
	return ` LEFT JOIN media_assets ` + m + ` ON ` + m + `.media_id=nullif(` + p + `.data->>'avatarMediaId','')::uuid AND ` + m + `.owner_id=` + p + `.user_id AND ` + m + `.purpose='avatar' AND ` + m + `.status='ready' `
}

// avatarThumbKey is the thumbnail's object key (NULL without a photo) for media alias m.
func avatarThumbKey(m string) string { return m + `.variants->>'thumb'` }

// avatarFullKey is the full-size object key (NULL without a photo) for media alias m.
func avatarFullKey(m string) string { return m + `.variants->>'full'` }

// avatarURL signs an object key read by avatarThumbKey or avatarFullKey. It is nil without a
// key, without a signer, or when storage is not configured (the signer then returns "").
func avatarURL(sign Signer, key *string) *string {
	if key == nil || *key == "" || sign == nil {
		return nil
	}
	if url := sign(*key); url != "" {
		return &url
	}
	return nil
}
