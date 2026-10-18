package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/media"
	"hiyall/services/api/internal/store"
)

// A signed download URL only needs to outlive the request that follows it; clients cache the decrypted
// bytes by blob id, so a fresh URL is asked for whenever one is needed.
const chatDownloadLifetime = 5 * time.Minute

// chatBlobContentType is the only type a ciphertext blob is uploaded with, signed into the URL.
const chatBlobContentType = "application/octet-stream"

// chatMediaRoute serves the end-to-end encrypted attachment blobs of a chat. The server authorizes, size-checks
// and expires opaque ciphertext; it never sees a key or a plaintext byte.
//
//	POST   /v1/conversations/{id}/blobs                  {role: full|thumb|voice|video, sizeBytes, ctSha256} -> signed PUT slot
//	POST   /v1/blobs/{blobId}/complete                   verifies the stored size
//	GET    /v1/conversations/{id}/blobs/{blobId}/url     signed GET for a member
//	DELETE /v1/blobs/{blobId}                            the uploader removes it (held evidence excepted)
//
// Blobs are attached to a message through blobIds on POST /v1/conversations/{id}/messages.
func (a *API) chatMediaRoute(w http.ResponseWriter, r *http.Request, p store.Principal, parts []string) bool {
	ctx := r.Context()
	n, method := len(parts), r.Method
	if n < 3 || parts[0] != "v1" {
		return false
	}
	isSlot := n == 4 && parts[1] == "conversations" && isID(parts[2]) && parts[3] == "blobs" && method == "POST"
	isComplete := n == 4 && parts[1] == "blobs" && isID(parts[2]) && parts[3] == "complete" && method == "POST"
	isURL := n == 6 && parts[1] == "conversations" && isID(parts[2]) && parts[3] == "blobs" && isID(parts[4]) && parts[5] == "url" && method == "GET"
	isDelete := n == 3 && parts[1] == "blobs" && isID(parts[2]) && method == "DELETE"
	if !isSlot && !isComplete && !isURL && !isDelete {
		return false
	}
	if a.ChatMedia == nil {
		a.failure(w, r, 503, domain.ErrChatMediaUnavailable.Code, domain.ErrChatMediaUnavailable.Message)
		return true
	}
	limiter := a.blobSlots
	if isURL {
		limiter = a.blobURLs
	}
	if !limiter.allow(p.UserID) {
		w.Header().Set("Retry-After", "2")
		a.failure(w, r, 429, "RATE_LIMITED", "Slow down a little and try again")
		return true
	}
	switch {
	case isSlot:
		raw, err := decode(w, r)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		e := a.entitlementsFor(ctx, p.UserID)
		blob, err := domain.ParseNewBlob(raw, e)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		id, key, err := a.Store.CreateBlobSlot(ctx, p.UserID, parts[2], blob, e)
		if err != nil {
			a.error(w, r, err)
			return true
		}
		// The signature fixes the content type and the SHA-256 of the body, so the store refuses any other bytes.
		url, _, err := a.ChatMedia.PresignPutChecksum(ctx, key, chatBlobContentType, blob.CtSha256Base64(), blob.SizeBytes, uploadURLLifetime)
		if err != nil {
			a.storageFailure(w, r, "presign", err)
			a.dropBlob(ctx, p.UserID, id)
			return true
		}
		a.write(w, r, http.StatusCreated, map[string]any{"success": true, "data": map[string]any{
			"blobId": id, "uploadUrl": url, "method": "PUT",
			"headers":   map[string]string{"Content-Type": chatBlobContentType, "x-amz-checksum-sha256": blob.CtSha256Base64()},
			"expiresAt": time.Now().Add(uploadURLLifetime).UTC(),
		}})
	case isComplete:
		a.completeBlob(w, r, p.UserID, parts[2])
	case isURL:
		d, err := a.Store.BlobForDownload(ctx, p.UserID, parts[2], parts[4])
		if err != nil {
			a.error(w, r, err)
			return true
		}
		url, err := a.ChatMedia.PresignGet(ctx, d.Key, chatDownloadLifetime)
		if err != nil {
			a.storageFailure(w, r, "presign", err)
			return true
		}
		a.ok(w, r, map[string]any{"url": url, "expiresAt": time.Now().Add(chatDownloadLifetime).UTC(), "sizeBytes": d.Size})
	case isDelete:
		// Held evidence is left alone; the uploader cannot tell, and the answer is the same.
		key, _, err := a.Store.DeleteBlob(ctx, p.UserID, parts[2])
		if err != nil {
			a.error(w, r, err)
			return true
		}
		a.removeObject(ctx, parts[2], key)
		a.ok(w, r, map[string]bool{"deleted": true})
	}
	return true
}

// completeBlob verifies that the object the uploader PUT is the size they declared (the store itself already
// refused a body that did not match the signed SHA-256), then marks the blob uploaded. Completing twice is fine.
func (a *API) completeBlob(w http.ResponseWriter, r *http.Request, user, id string) {
	ctx := r.Context()
	upload, err := a.Store.PendingBlob(ctx, user, id)
	if err != nil {
		a.error(w, r, err)
		return
	}
	if upload.State == "pending" {
		size, err := a.ChatMedia.Stat(ctx, upload.Key)
		switch {
		case errors.Is(err, media.ErrNotFound):
			a.error(w, r, domain.ErrBlobNotReady)
			return
		case err != nil:
			a.storageFailure(w, r, "stat", err)
			return
		case size != upload.Size:
			// Neither side can fix a wrong-sized object: it goes, and the uploader asks for a new slot.
			a.dropBlob(ctx, user, id)
			a.error(w, r, domain.ErrBlobSizeMismatch)
			return
		}
		if done, err := a.Store.BlobUploaded(ctx, user, id); err != nil {
			a.error(w, r, err)
			return
		} else if !done {
			// A concurrent completion won, or the blob expired or was deleted meanwhile.
			if upload, err = a.Store.PendingBlob(ctx, user, id); err != nil || upload.State != "uploaded" {
				a.error(w, r, domain.ErrBlobExpired)
				return
			}
		}
	}
	a.ok(w, r, map[string]string{"blobId": id, "state": "uploaded"})
}

// dropBlob marks a blob deleted and removes its object at once. When removal fails the row keeps its key and
// the hourly clean-up retries, so nothing is left behind silently. Held evidence is never touched.
func (a *API) dropBlob(ctx context.Context, user, id string) {
	if key, _, err := a.Store.DeleteBlob(ctx, user, id); err == nil {
		a.removeObject(ctx, id, key)
	}
}

// removeObject deletes a blob's object (the key DeleteBlob returned; empty when nothing is left to remove).
func (a *API) removeObject(ctx context.Context, id, key string) {
	if key == "" || a.ChatMedia == nil {
		return
	}
	if err := a.ChatMedia.Delete(ctx, key); err != nil {
		slog.Warn("chat object not removed", "operation", "delete", "code", media.ErrorCode(err))
		return
	}
	if err := a.Store.BlobObjectRemoved(ctx, id); err != nil {
		slog.Warn("chat object removal not recorded", "reason", "database")
	}
}

// storageFailure answers 503 for a storage error and logs only the service's error code: never a URL, a key or
// the error text, which could carry either.
func (a *API) storageFailure(w http.ResponseWriter, r *http.Request, operation string, err error) {
	slog.Warn("chat media storage failed", "requestId", r.Context().Value(requestIDKey{}), "operation", operation, "code", media.ErrorCode(err))
	a.failure(w, r, 503, domain.ErrChatMediaUnavailable.Code, domain.ErrChatMediaUnavailable.Message)
}
