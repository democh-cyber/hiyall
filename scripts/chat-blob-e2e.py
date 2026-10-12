#!/usr/bin/env python3
"""End-to-end check of encrypted chat attachments against a running API and its real chat bucket.

    ./scripts/dev-api.sh                       # with config/chat-media.local.env filled in
    python3 scripts/chat-blob-e2e.py --yes     # stdlib only

What it does, as the development fixture accounts Anjali and Niko (a friend pair or not) and Kai as an
outsider: registers throw-away devices, opens their conversation, asks for upload slots, PUTs "ciphertext"
with exactly the signed headers (and proves the bucket enforces them, the declared size included), completes, sends a message with blobIds,
downloads as the peer and verifies hash and decryption, expects 404 for the outsider, exercises the pending
cap, the size caps and the gate, and finally scans every API response for the plaintext, the key and secrets.

It refuses to run unless chat media is configured on the target API (CHAT_MEDIA_UNAVAILABLE otherwise).

It writes to the API's database: a few junk messages in the Anjali and Niko conversation, a handful of blob
slots (about 15 of the 100 a day), and two ephemeral devices that are revoked at the end. Every uploaded blob is
deleted again. Use a development database whose Anjali and Niko have no devices you care about; pass --yes to
confirm. The "ciphertext" is XOR with an HMAC-SHA256 keystream, a stand-in: the server must treat it as opaque
bytes either way. Exit status 0 means every check passed.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid

ANJALI = "019a4000-0000-7000-8000-000000000001"
NIKO = "019a4000-0000-7000-8000-000000000002"
KAI = "019a4000-0000-7000-8000-0000000000a2"

# ---------------------------------------------------------------- Ed25519 (RFC 8032, section 6), stdlib only
P = 2**255 - 19
Q = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _add(a, b):
    A, B = (a[1] - a[0]) * (b[1] - b[0]) % P, (a[1] + a[0]) * (b[1] + b[0]) % P
    C, D2 = 2 * a[3] * b[3] * D % P, 2 * a[2] * b[2] % P
    E, F, G, H = B - A, D2 - C, D2 + C, B + A
    return (E * F % P, G * H % P, F * G % P, E * H % P)


def _mul(s, point):
    result = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            result = _add(result, point)
        point = _add(point, point)
        s >>= 1
    return result


def _compress(point):
    zinv = pow(point[2], P - 2, P)
    x, y = point[0] * zinv % P, point[1] * zinv % P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _recover_x(y, sign):
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x & 1) != sign:
        x = P - x
    return x


_GY = 4 * pow(5, P - 2, P) % P
_GX = _recover_x(_GY, 0)
BASE = (_GX, _GY, 1, _GX * _GY % P)


def _expand(secret):
    h = hashlib.sha512(secret).digest()
    a = int.from_bytes(h[:32], "little") & ((1 << 254) - 8) | (1 << 254)
    return a, h[32:]


def ed25519_public(secret):
    return _compress(_mul(_expand(secret)[0], BASE))


def ed25519_sign(secret, message):
    a, prefix = _expand(secret)
    public = _compress(_mul(a, BASE))
    r = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % Q
    big_r = _compress(_mul(r, BASE))
    h = int.from_bytes(hashlib.sha512(big_r + public + message).digest(), "little") % Q
    return big_r + int.to_bytes((r + h * a) % Q, 32, "little")


def b64u(data):  # unpadded standard base64, as the API wants for keys and ciphertext
    return base64.b64encode(data).decode().rstrip("=")


# ---------------------------------------------------------------- the stand-in cipher
def keystream_xor(key, blob_id, data):
    out = bytearray(len(data))
    for block in range(0, len(data), 32):
        pad = hmac.new(key, blob_id.encode() + block.to_bytes(8, "big"), hashlib.sha256).digest()
        chunk = data[block:block + 32]
        out[block:block + len(chunk)] = bytes(x ^ y for x, y in zip(chunk, pad))
    return bytes(out)


# ---------------------------------------------------------------- HTTP
class Api:
    def __init__(self, base):
        self.base = base.rstrip("/")
        self.transcript = []  # every API response body and header block, for the final scan

    def request(self, method, path, token=None, body=None, expect=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", "Bearer " + token)
        for attempt in range(6):
            try:
                with urllib.request.urlopen(req, timeout=20) as resp:
                    status, text, headers = resp.status, resp.read().decode(), resp.headers
            except urllib.error.HTTPError as err:
                status, text, headers = err.code, err.read().decode(), err.headers
            # The per-account limiter is a burst bucket; a check that does not expect a 429 waits it out.
            if status == 429 and expect is not None and expect[0] != 429 and attempt < 5:
                time.sleep(min(float(headers.get("Retry-After", "2")), 3))
                continue
            break
        self.transcript.append(text + "\n" + str(headers))
        try:
            payload = json.loads(text)
        except ValueError:
            payload = {}
        code = (payload.get("error") or {}).get("code", "")
        if expect is not None and (status, code) != (expect[0], expect[1] if len(expect) > 1 else code):
            fail(f"{method} {path}: got {status} {code}, wanted {expect[0]} {expect[1] if len(expect) > 1 else ''}\n{text}")
        return status, code, payload.get("data") or {}, headers


def put_object(url, headers, body):
    """PUT straight to storage (never through the API) and return the status."""
    req = urllib.request.Request(url, data=body, method="PUT")
    for name, value in headers.items():
        req.add_header(name, value)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status
    except urllib.error.HTTPError as err:
        return err.code


def get_object(url):
    with urllib.request.urlopen(url, timeout=60) as resp:
        return resp.read()


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


def sha256_b64(data):
    return base64.b64encode(hashlib.sha256(data).digest()).decode()


# ---------------------------------------------------------------- the run
def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--api", default=os.environ.get("API_BASE_URL", "http://127.0.0.1:8080"))
    parser.add_argument("--yes", action="store_true", help="confirm that this writes to the API's database")
    parser.add_argument("--skip-enforcement", action="store_true", help="skip the checks that PUT bad bodies to storage (for a fake store)")
    args = parser.parse_args()
    if not args.yes:
        fail("this writes junk messages, blob slots and two devices to the API's database; run again with --yes")
    api = Api(args.api)

    print("Sessions")
    tokens = {}
    for name, user in (("anjali", ANJALI), ("niko", NIKO), ("kai", KAI)):
        status, code, data, _ = api.request("POST", "/dev/session", body={"userId": user})
        if status != 200:
            fail(f"/dev/session for {name}: {status} {code}; start the API with ENABLE_DEV_AUTH (scripts/dev-api.sh)")
        tokens[user] = data["accessToken"]
    anjali, niko, kai = tokens[ANJALI], tokens[NIKO], tokens[KAI]

    print("Chat media must be configured on the target")
    status, code, _, _ = api.request("POST", f"/v1/conversations/{uuid.uuid4()}/blobs", anjali, {})
    if status == 503 and code == "CHAT_MEDIA_UNAVAILABLE":
        fail("CHAT_MEDIA_UNAVAILABLE: the API has no chat bucket. Fill config/chat-media.local.env and restart scripts/dev-api.sh.")
    check(status != 503, f"the API answers the blob routes ({status} {code} for a random conversation)")

    devices = {}  # user -> (device id)
    try:
        run(api, anjali, niko, kai, devices, args)
    finally:
        for user, token in ((ANJALI, anjali), (NIKO, niko)):
            if user in devices:
                api.request("DELETE", f"/v1/devices/{devices[user]}", token)
    print(f"\nAll {PASSED} checks passed.")


def register(api, user, token):
    secret = os.urandom(32)
    signing, identity, device = b64u(ed25519_public(secret)), b64u(os.urandom(32)), str(uuid.uuid4())
    statement = "\n".join(["hiyall-device-v1", user, device, identity, signing]).encode()
    api.request("POST", "/v1/devices", token, {"deviceId": device, "identityKey": identity, "signingKey": signing,
                                               "platform": "linux", "displayName": "chat-blob-e2e",
                                               "signature": b64u(ed25519_sign(secret, statement))}, expect=(200,))
    return device


def envelopes(api, sender_token, sender_user, sender_device, peer):
    """One envelope per device of the peer and per other device of the sender, as the relay requires."""
    _, _, mine, _ = api.request("GET", "/v1/me/devices", sender_token, expect=(200,))
    _, _, theirs, _ = api.request("GET", f"/v1/users/{peer}/devices", sender_token, expect=(200,))
    ids = [d["deviceId"] for d in mine["items"] if d["deviceId"] != sender_device] + [d["deviceId"] for d in theirs["items"]]
    return [{"deviceId": i, "type": 0, "ciphertext": b64u(os.urandom(64))} for i in ids]


def run(api, anjali, niko, kai, devices, args):
    print("Devices and a conversation")
    devices[ANJALI], devices[NIKO] = register(api, ANJALI, anjali), register(api, NIKO, niko)
    _, _, convo, _ = api.request("POST", "/v1/conversations", anjali, {"userId": NIKO}, expect=(200,))
    cid = convo["conversationId"]
    blobs = f"/v1/conversations/{cid}/blobs"

    def send(token, user, peer, ids=None):
        message = {"messageId": str(uuid.uuid4()), "senderDeviceId": devices[user], "envelopes": envelopes(api, token, user, devices[user], peer)}
        if ids is not None:
            message["blobIds"] = ids
        return api.request("POST", f"/v1/conversations/{cid}/messages", token, message)

    marker = "PLAINTEXT-MARKER-" + uuid.uuid4().hex
    plain_full = (marker + " ").encode() * 400 + os.urandom(2000)
    plain_thumb = (marker + " ").encode() * 4
    key = os.urandom(32)

    def seal(role, plain):
        # The real client derives a key per blob from the message key and the blob id; the stand-in only needs distinct streams.
        return keystream_xor(key, role, plain)

    full_ct, thumb_ct = seal("full", plain_full), seal("thumb", plain_thumb)

    print("The gate: images only after a reply, or between friends")
    status, code, probe, _ = api.request("POST", blobs, anjali, {"role": "full", "sizeBytes": len(full_ct), "ctSha256": sha256_b64(full_ct)})
    if (status, code) == (403, "ATTACHMENTS_NOT_ALLOWED"):
        check(True, "strangers cannot send images (403 ATTACHMENTS_NOT_ALLOWED)")
        check(send(anjali, ANJALI, NIKO)[0] == 200, "Anjali's opening message is relayed")
        check(send(niko, NIKO, ANJALI)[0] == 200, "after the peer replies the gate opens")
    else:
        check(status == 201, "Anjali and Niko may already send images (friends or an earlier reply); the stranger gate is not exercised")
        api.request("DELETE", f"/v1/blobs/{probe['blobId']}", anjali, expect=(200,))

    print("Validation and size caps")
    sha = sha256_b64(full_ct)
    api.request("POST", blobs, anjali, {"role": "full", "sizeBytes": 4 * 1024 * 1024 + 1, "ctSha256": sha}, expect=(413, "TOO_LARGE"))
    api.request("POST", blobs, anjali, {"role": "thumb", "sizeBytes": 256 * 1024 + 1, "ctSha256": sha}, expect=(413, "TOO_LARGE"))
    api.request("POST", blobs, anjali, {"role": "full", "sizeBytes": 10, "ctSha256": sha}, expect=(422, "VALIDATION"))
    api.request("POST", blobs, anjali, {"role": "full", "sizeBytes": 1000, "ctSha256": sha.rstrip("=")}, expect=(422, "VALIDATION"))
    check(True, "oversize is 413, a tiny size or a malformed hash is 422")

    print("Upload: signed PUT, then complete")
    uploaded = {}
    for role, ct in (("full", full_ct), ("thumb", thumb_ct)):
        _, _, slot, _ = api.request("POST", blobs, anjali, {"role": role, "sizeBytes": len(ct), "ctSha256": sha256_b64(ct)}, expect=(201,))
        check(slot["method"] == "PUT" and slot["headers"].get("x-amz-checksum-sha256") == sha256_b64(ct) and slot["headers"].get("Content-Type") == "application/octet-stream"
              and len(slot["headers"]) == 2, f"{role}: the slot signs the content type and the checksum (Content-Length is signed, not listed)")
        if not args.skip_enforcement:
            wrong = bytes([ct[0] ^ 1]) + ct[1:]
            check(put_object(slot["uploadUrl"], slot["headers"], wrong) == 400, f"{role}: the bucket refuses a body that does not match the signed SHA-256 (400)")
            no_sum = {k: v for k, v in slot["headers"].items() if k.lower() != "x-amz-checksum-sha256"}
            check(put_object(slot["uploadUrl"], no_sum, ct) == 403, f"{role}: the bucket refuses a PUT without the checksum header (403)")
            check(put_object(slot["uploadUrl"], dict(slot["headers"], **{"Content-Type": "image/jpeg"}), ct) == 403, f"{role}: the bucket refuses another content type (403)")
            # The signature pins the exact size too: a body larger or smaller than declared is refused, whatever its hash.
            check(put_object(slot["uploadUrl"], slot["headers"], ct + b"\0") == 403, f"{role}: the bucket refuses a body larger than the declared size (403)")
            check(put_object(slot["uploadUrl"], slot["headers"], ct[:-1]) == 403, f"{role}: the bucket refuses a body smaller than the declared size (403)")
        api.request("POST", f"/v1/blobs/{slot['blobId']}/complete", anjali, expect=(409, "BLOB_NOT_READY"))
        check(put_object(slot["uploadUrl"], slot["headers"], ct) == 200, f"{role}: the signed PUT stores the ciphertext")
        _, _, done, _ = api.request("POST", f"/v1/blobs/{slot['blobId']}/complete", anjali, expect=(200,))
        check(done == {"blobId": slot["blobId"], "state": "uploaded"}, f"{role}: complete verifies the stored size")
        api.request("POST", f"/v1/blobs/{slot['blobId']}/complete", anjali, expect=(200,))
        uploaded[role] = slot["blobId"]
        api.request("POST", f"/v1/blobs/{slot['blobId']}/complete", niko, expect=(404, "NOT_FOUND"))
        api.request("GET", f"{blobs}/{slot['blobId']}/url", niko, expect=(404, "NOT_FOUND"))  # nobody but the uploader sees a blob before it is sent
    check(True, "complete is idempotent, and the peer cannot complete or see an unsent blob")

    print("A body that is not the declared size never reaches the bucket")
    # The signed URL pins Content-Length, so storage itself refuses it. The size check in `complete`
    # (409 BLOB_SIZE_MISMATCH) is only a backstop for an object written some other way; the Go tests cover it.
    wrong_size = os.urandom(1000)
    _, _, slot, _ = api.request("POST", blobs, anjali, {"role": "full", "sizeBytes": 999, "ctSha256": sha256_b64(wrong_size)}, expect=(201,))
    check(put_object(slot["uploadUrl"], slot["headers"], wrong_size) == 403, "the bucket refuses a body whose size differs from the declared size (403)")
    api.request("POST", f"/v1/blobs/{slot['blobId']}/complete", anjali, expect=(409, "BLOB_NOT_READY"))
    api.request("DELETE", f"/v1/blobs/{slot['blobId']}", anjali, expect=(200,))
    check(True, "nothing was stored, so complete answers 409 BLOB_NOT_READY and the slot can be deleted")

    print("Send a message that claims the blobs")
    api.request("POST", f"/v1/conversations/{cid}/messages", anjali, {"messageId": str(uuid.uuid4()), "senderDeviceId": devices[ANJALI],
                "envelopes": envelopes(api, anjali, ANJALI, devices[ANJALI], NIKO), "blobIds": [str(uuid.uuid4())]}, expect=(409, "BLOB_NOT_READY"))
    status, code, sent, _ = send(anjali, ANJALI, NIKO, [uploaded["full"], uploaded["thumb"]])
    check(status == 200, "the message with blobIds is accepted")
    status, code, _, _ = send(anjali, ANJALI, NIKO, [uploaded["full"]])
    check((status, code) == (409, "BLOB_NOT_READY"), "a blob cannot be claimed twice")
    status, code, _, _ = send(niko, NIKO, ANJALI, [uploaded["full"]])
    check((status, code) == (409, "BLOB_NOT_READY"), "the peer cannot claim Anjali's blob")

    print("Download as the peer")
    urls = {}
    for role, ct in (("full", full_ct), ("thumb", thumb_ct)):
        _, _, link, headers = api.request("GET", f"{blobs}/{uploaded[role]}/url", niko, expect=(200,))
        urls[role] = link["url"]
        check(link["sizeBytes"] == len(ct) and headers.get("Cache-Control") == "no-store", f"{role}: signed GET with the ciphertext size, no-store")
        body = get_object(link["url"])
        check(body == ct and sha256_b64(body) == sha256_b64(ct), f"{role}: the peer downloads exactly the ciphertext and its SHA-256 matches")
        check(marker.encode() not in body, f"{role}: the stored bytes contain no plaintext")
        check(keystream_xor(key, role, body) == (plain_full if role == "full" else plain_thumb), f"{role}: the peer decrypts it with the key from the message")
    api.request("GET", f"{blobs}/{uploaded['full']}/url", anjali, expect=(200,))

    print("An outsider")
    api.request("GET", f"{blobs}/{uploaded['full']}/url", kai, expect=(404, "NOT_FOUND"))
    api.request("POST", blobs, kai, {"role": "full", "sizeBytes": 100, "ctSha256": sha}, expect=(404, "NOT_FOUND"))
    api.request("DELETE", f"/v1/blobs/{uploaded['full']}", kai, expect=(404, "NOT_FOUND"))
    api.request("DELETE", f"/v1/blobs/{uploaded['full']}", niko, expect=(404, "NOT_FOUND"))
    check(True, "a non-member gets 404 for the URL, a slot and a delete; the peer cannot delete either")

    print("Pending cap")
    pending = []
    for i in range(10):
        _, _, slot, _ = api.request("POST", blobs, anjali, {"role": "thumb", "sizeBytes": 100 + i, "ctSha256": sha256_b64(os.urandom(8))}, expect=(201,))
        pending.append(slot["blobId"])
    status, code, _, headers = api.request("POST", blobs, anjali, {"role": "thumb", "sizeBytes": 100, "ctSha256": sha})
    check((status, code) == (429, "RATE_LIMITED") and int(headers.get("Retry-After", "0")) > 0, "the 11th pending slot is 429 RATE_LIMITED with Retry-After")
    for blob in pending:
        api.request("DELETE", f"/v1/blobs/{blob}", anjali, expect=(200,))
    _, _, extra, _ = api.request("POST", blobs, anjali, {"role": "thumb", "sizeBytes": 100, "ctSha256": sha}, expect=(201,))
    api.request("DELETE", f"/v1/blobs/{extra['blobId']}", anjali, expect=(200,))
    check(True, "deleting the pending slots frees the cap (a deleted blob still counts towards the daily 100)")

    print("Delete")
    api.request("DELETE", f"/v1/blobs/{uploaded['full']}", anjali, expect=(200,))
    api.request("DELETE", f"/v1/blobs/{uploaded['thumb']}", anjali, expect=(200,))
    api.request("GET", f"{blobs}/{uploaded['full']}/url", niko, expect=(410, "BLOB_EXPIRED"))
    check(True, "after the uploader deletes, the peer gets 410 BLOB_EXPIRED")
    for role, url in urls.items():
        try:
            get_object(url)
            gone = False
        except urllib.error.HTTPError as err:
            gone = err.code == 404
        check(gone, f"{role}: the object is gone from the bucket (the earlier signed GET now answers 404)")

    print("Nothing the API said contains the plaintext or the key")
    everything = "\n".join(api.transcript)
    for label, needle in (("plaintext marker", marker), ("key (base64)", base64.b64encode(key).decode()), ("key (hex)", key.hex()),
                          ("key (unpadded)", b64u(key)), ("plaintext bytes", plain_thumb.decode())):
        check(needle not in everything, f"no {label} in any API response or header")
    check(not re.search(r"BEGIN [A-Z ]*PRIVATE KEY", everything), "no private key material in any response")


if __name__ == "__main__":
    main()
