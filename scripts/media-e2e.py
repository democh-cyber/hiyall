#!/usr/bin/env python3
"""End-to-end check of public photo upload slots (post, story, avatar) against a running API and its real bucket.

    ./scripts/dev-api.sh                       # with the media bucket configured (MEDIA_* variables)
    python3 scripts/media-e2e.py --yes         # stdlib only

What it does, as the development fixture account Anjali: asks for an upload slot for a post photo and for an
avatar, then PUTs straight to storage and proves the signed URL pins what the slot promised: a body larger than
the declared size is refused (403), so is a body smaller, so is another content type, and the exact body is
accepted (200). It then completes the post photo, posts it and deletes the post. The slot answer must list only
the Content-Type header: the size is signed into the URL but a client never sets Content-Length itself.

It refuses to run unless photo uploads are configured on the target API (MEDIA_UNAVAILABLE otherwise).

It writes to the API's database: three upload slots (of the 50 a day) and 2 declared photos (a few hundred bytes
each), one post that is deleted again, and one finished avatar photo that is never attached and is cleaned up
by the hourly media clean-up. Pass --yes to confirm. Exit status 0 means every check passed.
"""
import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

ANJALI = "019a4000-0000-7000-8000-000000000001"

# An 8x8 JPEG, so complete has something real to decode.
JPEG = base64.b64decode(
    "/9j/2wCEAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDIBCQkJDAsMGA0NGDIhHCEyMjIyMjIyMjIyMjIyMjIy"
    "MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMv/AABEIAAgACAMBIgACEQEDEQH/xAGiAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQAAIBAwMCBAMFBQQEAAAB"
    "fQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SV"
    "lpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+gEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoLEQACAQIEBAME"
    "BwUEBAABAncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SF"
    "hoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/2gAMAwEAAhEDEQA/AMrRPBP3f3X6Vv8A/CE/9Mv0rf0T"
    "+Gt+vPxOZV/aPUvJM3xP1SOp/9k="
)

PASSED = 0


def check(condition, label):
    global PASSED
    if not condition:
        fail(label)
    PASSED += 1
    print("  ok  " + label)


def fail(message):
    print("FAIL " + message, file=sys.stderr)
    sys.exit(1)


def call(base, method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            status, text = resp.status, resp.read().decode()
    except urllib.error.HTTPError as err:
        status, text = err.code, err.read().decode()
    try:
        payload = json.loads(text)
    except ValueError:
        payload = {}
    return status, (payload.get("error") or {}).get("code", ""), payload.get("data") or {}


def put_object(url, headers, body):
    """PUT straight to storage, never through the API. urllib sets Content-Length from the body, as a browser would."""
    req = urllib.request.Request(url, data=body, method="PUT")
    for name, value in headers.items():
        req.add_header(name, value)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status
    except urllib.error.HTTPError as err:
        return err.code


def expect(base, token, method, path, status, code="", body=None):
    got = call(base, method, path, token, body)
    if (got[0], got[1]) != (status, code):
        fail(f"{method} {path}: got {got[0]} {got[1]}, wanted {status} {code}")
    return got[2]


def slot_checks(base, token, purpose):
    print(f"A {purpose} slot")
    made = expect(base, token, "POST", "/v1/media/uploads", 201, body={"purpose": purpose, "contentType": "image/jpeg", "sizeBytes": len(JPEG)})
    check(made["method"] == "PUT" and made["headers"] == {"Content-Type": "image/jpeg"},
          f"{purpose}: the slot lists only Content-Type (the size is signed into the URL, never set by the client)")
    url, headers = made["uploadUrl"], made["headers"]
    check(put_object(url, headers, JPEG + b"\0") == 403, f"{purpose}: the bucket refuses a body larger than the declared size (403)")
    check(put_object(url, headers, JPEG[:-1]) == 403, f"{purpose}: the bucket refuses a body smaller than the declared size (403)")
    check(put_object(url, {"Content-Type": "image/png"}, JPEG) == 403, f"{purpose}: the bucket refuses another content type (403)")
    check(put_object(url, headers, JPEG) == 200, f"{purpose}: the exact body is accepted (200)")
    return made["mediaId"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--api", default=os.environ.get("API_BASE_URL", "http://127.0.0.1:8080"))
    parser.add_argument("--yes", action="store_true", help="confirm that this writes to the API's database")
    args = parser.parse_args()
    if not args.yes:
        fail("this writes upload slots and a post to the API's database; run again with --yes")
    base = args.api.rstrip("/")

    status, code, data = call(base, "POST", "/dev/session", body={"userId": ANJALI})
    if status != 200:
        fail(f"/dev/session: {status} {code}; start the API with ENABLE_DEV_AUTH (scripts/dev-api.sh)")
    token = data["accessToken"]

    print("Photo uploads must be configured on the target")
    status, code, _ = call(base, "POST", "/v1/media/uploads", token, {"purpose": "post", "contentType": "image/jpeg", "sizeBytes": len(JPEG)})
    if (status, code) == (503, "MEDIA_UNAVAILABLE"):
        fail("MEDIA_UNAVAILABLE: the API has no media bucket. Configure the MEDIA_* variables and restart scripts/dev-api.sh.")
    check(status == 201, f"the API hands out upload slots ({status} {code})")

    media = slot_checks(base, token, "post")
    expect(base, token, "POST", f"/v1/media/{media}/complete", 200)
    post = expect(base, token, "POST", "/v1/posts", 201, body={"body": "media-e2e", "audience": "friends", "mediaIds": [media]})["postId"]
    check(True, "the exact upload completes and can be posted")
    expect(base, token, "DELETE", f"/v1/posts/{post}", 200)

    avatar = slot_checks(base, token, "avatar")
    expect(base, token, "POST", f"/v1/media/{avatar}/complete", 200)
    check(True, "the avatar upload completes (it is left unattached)")
    print(f"\nAll {PASSED} checks passed.")


if __name__ == "__main__":
    main()
