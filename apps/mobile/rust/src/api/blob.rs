//! Encrypted chat attachments: image preparation and a chunked AEAD container.
//! See docs/security/14-encrypted-chat-attachments.md for the design.
//!
//! No custom cryptography: XChaCha20-Poly1305 in the STREAM-BE32 construction
//! (`aead-stream`), keys and nonce prefixes from HKDF-SHA256. This file only
//! fixes the framing: what is bound into the key, the AAD and the padding.
//! - one random 256-bit master key covers every blob of a message; each blob gets its
//!   own 32-byte key and 19-byte STREAM nonce prefix from HKDF with the blob id as
//!   salt and `version|role|mime|chunkSize|plainLen|conversationId` as info;
//! - the info string is also the AAD of every chunk, and the last chunk carries the
//!   STREAM last-block flag, so truncation, extension, reordering and a different
//!   context all fail authentication;
//! - the plaintext is padded to a Padme length with zeros inside the encryption;
//!   the true length is bound through the info string and the padding is verified;
//! - the receiver checks SHA-256 of the whole ciphertext before decrypting anything.
//!
//! Dependency bumps change the format: keep the test vectors below passing.

use aead_stream::{DecryptorBE32, EncryptorBE32, Key, KeyInit, Nonce, StreamBE32};
use chacha20poly1305::XChaCha20Poly1305;
use flutter_rust_bridge::frb;
use hkdf::Hkdf;
use image::imageops::FilterType;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits};
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};
use std::io::Cursor;
use zeroize::Zeroizing;

const INFO_VERSION: &str = "hiyall-chat-blob/v1";
/// Role and mime travel together: a role only ever seals its own kind of bytes. Photos (`full`, `thumb`) are
/// JPEG, a voice message is AAC in an MP4 container, a video is MP4 (the app re-encodes everything it sends).
const ROLE_MIMES: [(&str, &str); 4] = [("full", "image/jpeg"), ("thumb", "image/jpeg"), ("voice", "audio/mp4"), ("video", "video/mp4")];
const TAG_LEN: usize = 16;
const KEY_LEN: usize = 32;
const NONCE_PREFIX_LEN: usize = 19;

const MIN_CHUNK: u32 = 4 * 1024;
const MAX_CHUNK: u32 = 1024 * 1024;
/// Largest plaintext this format accepts. The server caps a video's ciphertext at 40 MiB, a voice message at
/// 8 MiB and a photo at 4 MiB (the roles' own caps are stricter than this bound).
const MAX_PLAIN_LEN: u32 = 40 * 1024 * 1024;
const MAX_ID_LEN: usize = 128;

const MAX_INPUT_BYTES: usize = 64 * 1024 * 1024;
const MAX_SIDE: u32 = 12_000;
const MAX_PIXELS: u64 = 40_000_000;
// Decoder allocation budget: enough for a 40 MP RGBA frame, not for a decompression bomb.
const MAX_DECODE_ALLOC: u64 = 200 * 1024 * 1024;
const FULL_EDGE: u32 = 2048;
const THUMB_EDGE: u32 = 320;
const FULL_QUALITY: u8 = 82;
const THUMB_QUALITY: u8 = 80;
// ThumbHash is defined for images up to 100x100.
const PREVIEW_EDGE: u32 = 100;
const MAX_PREVIEW_BYTES: usize = 64;
const MIN_PREVIEW_BYTES: usize = 5;

type Cipher = XChaCha20Poly1305;
type StreamNonce = Nonce<Cipher, StreamBE32<Cipher>>;

pub struct SealedBlob {
    /// Chunks of `chunk_size + 16` bytes; the last one may be shorter.
    pub ciphertext: Vec<u8>,
    /// SHA-256 of `ciphertext` (32 bytes). Goes in the descriptor and the upload checksum.
    pub ct_sha256: Vec<u8>,
    /// True plaintext length (before padding); the descriptor carries it as `plainLen`.
    pub plain_len: u32,
    pub chunks: u32,
}

pub struct PreparedImage {
    /// JPEG, long edge at most 2048 px, no metadata.
    pub full: Vec<u8>,
    pub full_w: u32,
    pub full_h: u32,
    /// JPEG, long edge at most 320 px, no metadata.
    pub thumb: Vec<u8>,
    pub thumb_w: u32,
    pub thumb_h: u32,
    /// ThumbHash of the thumbnail (about 25 bytes).
    pub preview: Vec<u8>,
}

pub struct RgbaPreview {
    pub w: u32,
    pub h: u32,
    /// `w * h * 4` straight (not premultiplied) RGBA bytes.
    pub rgba: Vec<u8>,
}

/// A fresh random 256-bit master key from the OS CSPRNG.
#[frb(sync)]
pub fn generate_blob_key() -> Vec<u8> {
    let mut key = Zeroizing::new([0u8; KEY_LEN]);
    OsRng.fill_bytes(&mut *key);
    key.to_vec()
}

/// Seals `plaintext` for one blob. `role` is `full`, `thumb`, `voice` or `video` with the mime that goes with it (`image/jpeg`, `image/jpeg`, `audio/mp4`, `video/mp4`),
/// `chunk_size` a power of two from 4 KiB to 1 MiB (64 KiB by default).
pub fn encrypt_blob(
    key: Vec<u8>,
    role: String,
    blob_id: String,
    conversation_id: String,
    mime: String,
    chunk_size: u32,
    plaintext: Vec<u8>,
) -> Result<SealedBlob, String> {
    let key = Zeroizing::new(key);
    let plain = Zeroizing::new(plaintext);
    let plain_len = u32::try_from(plain.len()).map_err(|_| "plaintext too large".to_string())?;
    let ctx = Context { role: &role, mime: &mime, blob_id: &blob_id, conversation_id: &conversation_id, chunk_size, plain_len };
    ctx.validate()?;
    let layout = ctx.layout();
    // Pad in place with zeros; the padding is inside the encryption, so it is authenticated too.
    let mut padded = plain;
    padded.resize(layout.padded, 0);
    let ciphertext = seal_stream(&ctx, &key, &padded)?;
    debug_assert_eq!(ciphertext.len(), layout.ct_len);
    let ct_sha256 = Sha256::digest(&ciphertext).to_vec();
    Ok(SealedBlob { ciphertext, ct_sha256, plain_len, chunks: layout.chunks as u32 })
}

/// Opens a blob. The ciphertext length and SHA-256 are checked before any decryption, every
/// chunk must authenticate, and the padding must be zeros. On any failure nothing is returned.
// The argument list is the descriptor's fields, in the order the design document fixes.
#[allow(clippy::too_many_arguments)]
pub fn decrypt_blob(
    key: Vec<u8>,
    role: String,
    blob_id: String,
    conversation_id: String,
    mime: String,
    chunk_size: u32,
    plain_len: u32,
    ct_sha256: Vec<u8>,
    ciphertext: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let key = Zeroizing::new(key);
    let ctx = Context { role: &role, mime: &mime, blob_id: &blob_id, conversation_id: &conversation_id, chunk_size, plain_len };
    ctx.validate()?;
    let layout = ctx.layout();
    if ciphertext.len() != layout.ct_len {
        return Err("ciphertext length does not match the descriptor".into());
    }
    if ct_sha256.len() != 32 || Sha256::digest(&ciphertext).as_slice() != ct_sha256.as_slice() {
        return Err("ciphertext hash mismatch".into());
    }
    let mut padded = open_stream(&ctx, &key, &ciphertext)?;
    // Authenticated already, so this only catches a sender that wrote junk padding.
    if padded[plain_len as usize..].iter().fold(0u8, |acc, b| acc | b) != 0 {
        return Err("padding is not zero".into());
    }
    // The buffer moves to the caller; only a zero-length shell is left to wipe.
    let mut out = std::mem::take(&mut *padded);
    out.truncate(plain_len as usize);
    Ok(out)
}

/// Decodes an inlined ThumbHash (see `PreparedImage.preview`) to a small RGBA image
/// (at most 32 px per side) for a blurred placeholder. The hash comes from the sender,
/// so malformed input is an error, never a panic.
pub fn preview_to_rgba(preview: Vec<u8>) -> Result<RgbaPreview, String> {
    if preview.len() < MIN_PREVIEW_BYTES || preview.len() > MAX_PREVIEW_BYTES {
        return Err("invalid preview".into());
    }
    // thumbhash has no unsafe code but also no fuzzing history; turn any panic into an error.
    let decoded = std::panic::catch_unwind(|| thumbhash::thumb_hash_to_rgba(&preview)).map_err(|_| "invalid preview".to_string())?;
    let (w, h, rgba) = decoded.map_err(|_| "invalid preview".to_string())?;
    if w == 0 || h == 0 || w > 32 || h > 32 || rgba.len() != w * h * 4 {
        return Err("invalid preview".into());
    }
    Ok(RgbaPreview { w: w as u32, h: h as u32, rgba })
}

/// Decodes a JPEG, PNG or WebP photo with strict limits, applies its EXIF orientation and
/// re-encodes it from pixels as a full image (long edge at most 2048 px) and a thumbnail
/// (at most 320 px) plus a tiny ThumbHash preview. Nothing is upscaled, transparency is
/// flattened onto white, and no EXIF, GPS or ICC data survives. The output is not
/// colour-managed: the source profile is dropped and pixels are treated as sRGB.
pub fn prepare_chat_image(input: Vec<u8>) -> Result<PreparedImage, String> {
    if input.is_empty() || input.len() > MAX_INPUT_BYTES {
        return Err("image file is empty or too large".into());
    }
    let mut reader = ImageReader::new(Cursor::new(&input)).with_guessed_format().map_err(|_| "unreadable image".to_string())?;
    if !matches!(reader.format(), Some(ImageFormat::Jpeg | ImageFormat::Png | ImageFormat::WebP)) {
        return Err("unsupported image format (use JPEG, PNG or WebP)".into());
    }
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_SIDE);
    limits.max_image_height = Some(MAX_SIDE);
    limits.max_alloc = Some(MAX_DECODE_ALLOC);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().map_err(|_| "could not read the image".to_string())?;
    let (w, h) = decoder.dimensions();
    if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
        return Err("image dimensions are too large".into());
    }
    let orientation = decoder.orientation().map_err(|_| "could not read the image".to_string())?;
    let decoded = DynamicImage::from_decoder(decoder).map_err(|_| "could not decode the image".to_string())?;
    drop(input);

    // Order keeps the peak low for a 12 MP photo: flatten in place, shrink, then rotate the
    // already small image, and drop each big buffer as soon as the next stage owns the data.
    let mut full = fit(flatten_on_white(decoded), FULL_EDGE);
    full = DynamicImage::ImageRgb8(full.into_rgb8());
    full.apply_orientation(orientation);
    let thumb = fit(full.clone(), THUMB_EDGE);
    let preview_src = fit(thumb.clone(), PREVIEW_EDGE).into_rgba8();
    let preview = thumbhash::rgba_to_thumb_hash(preview_src.width() as usize, preview_src.height() as usize, preview_src.as_raw());
    Ok(PreparedImage {
        full: encode_jpeg(&full, FULL_QUALITY)?,
        full_w: full.width(),
        full_h: full.height(),
        thumb: encode_jpeg(&thumb, THUMB_QUALITY)?,
        thumb_w: thumb.width(),
        thumb_h: thumb.height(),
        preview,
    })
}

/// Never upscales: an image already within `edge` is returned untouched.
fn fit(img: DynamicImage, edge: u32) -> DynamicImage {
    if img.width().max(img.height()) <= edge {
        img
    } else {
        img.resize(edge, edge, FilterType::Lanczos3)
    }
}

/// Composites onto white in place (straight alpha), so no transparent pixel turns black and
/// the later resize cannot bleed colour from invisible pixels. Opaque inputs pass through.
fn flatten_on_white(img: DynamicImage) -> DynamicImage {
    if !img.color().has_alpha() {
        return img;
    }
    let mut rgba = img.into_rgba8();
    for p in rgba.pixels_mut() {
        let a = u32::from(p[3]);
        if a != 255 {
            for c in &mut p.0[..3] {
                *c = ((u32::from(*c) * a + 255 * (255 - a) + 127) / 255) as u8;
            }
            p[3] = 255;
        }
    }
    DynamicImage::ImageRgba8(rgba)
}

/// The encoder writes pixels only: no EXIF, GPS, ICC or comment segments.
fn encode_jpeg(img: &DynamicImage, quality: u8) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality)
        .encode_image(img)
        .map_err(|_| "could not encode the image".to_string())?;
    Ok(out)
}

/// Everything that is bound into the key, the nonce prefix and the AAD of a blob.
struct Context<'a> {
    role: &'a str,
    mime: &'a str,
    blob_id: &'a str,
    conversation_id: &'a str,
    chunk_size: u32,
    plain_len: u32,
}

struct Layout {
    /// Plaintext length after Padme padding.
    padded: usize,
    chunk: usize,
    chunks: usize,
    ct_len: usize,
}

impl Context<'_> {
    fn validate(&self) -> Result<(), String> {
        let Some((_, mime)) = ROLE_MIMES.iter().find(|(role, _)| *role == self.role) else {
            return Err("unknown blob role".into());
        };
        if self.mime != *mime {
            return Err("unsupported blob mime type".into());
        }
        valid_id(self.blob_id, "blob id")?;
        valid_id(self.conversation_id, "conversation id")?;
        if !(MIN_CHUNK..=MAX_CHUNK).contains(&self.chunk_size) || !self.chunk_size.is_power_of_two() {
            return Err("chunk size must be a power of two from 4 KiB to 1 MiB".into());
        }
        if self.plain_len > MAX_PLAIN_LEN {
            return Err("plaintext too large".into());
        }
        Ok(())
    }

    /// `version|role|mime|chunkSize|plainLen|conversationId`. Role and mime come from fixed
    /// allow-lists and the numbers are decimal, so with the free-form id last the encoding is
    /// unambiguous. It is both the HKDF info and the AAD of every chunk.
    fn info(&self) -> String {
        format!("{INFO_VERSION}|{}|{}|{}|{}|{}", self.role, self.mime, self.chunk_size, self.plain_len, self.conversation_id)
    }

    fn layout(&self) -> Layout {
        let padded = padme(self.plain_len) as usize;
        let chunk = self.chunk_size as usize;
        // An empty blob is one chunk holding only a tag, so every blob has a last chunk.
        let chunks = padded.div_ceil(chunk).max(1);
        Layout { padded, chunk, chunks, ct_len: padded + chunks * TAG_LEN }
    }

    /// 32-byte AEAD key plus 19-byte STREAM nonce prefix for this blob.
    fn derive(&self, master: &[u8]) -> Result<(Cipher, StreamNonce), String> {
        if master.len() != KEY_LEN {
            return Err("blob key must be 32 bytes".into());
        }
        let mut okm = Zeroizing::new([0u8; KEY_LEN + NONCE_PREFIX_LEN]);
        Hkdf::<Sha256>::new(Some(self.blob_id.as_bytes()), master)
            .expand(self.info().as_bytes(), &mut *okm)
            .map_err(|_| "key derivation failed".to_string())?;
        let key = Key::<Cipher>::try_from(&okm[..KEY_LEN]).map_err(|_| "key derivation failed".to_string())?;
        let nonce = StreamNonce::try_from(&okm[KEY_LEN..]).map_err(|_| "key derivation failed".to_string())?;
        Ok((Cipher::new(&key), nonce))
    }
}

/// Ids are random UUIDs; accept any short printable ASCII so the info string stays one line.
fn valid_id(id: &str, what: &str) -> Result<(), String> {
    if id.is_empty() || id.len() > MAX_ID_LEN || !id.bytes().all(|b| b.is_ascii_graphic()) {
        return Err(format!("invalid {what}"));
    }
    Ok(())
}

/// Padme (Nikitin et al.): rounds up so at most about 12% of the length is added, and the
/// leaked size class shrinks as files grow. Lengths 0 and 1 are unchanged.
fn padme(len: u32) -> u32 {
    if len < 2 {
        return len;
    }
    let e = 31 - len.leading_zeros();
    let s = (31 - e.leading_zeros()) + 1;
    let mask = (1u64 << (e - s)) - 1;
    ((u64::from(len) + mask) & !mask) as u32
}

/// Encrypts already padded data chunk by chunk.
fn seal_stream(ctx: &Context, master: &[u8], padded: &[u8]) -> Result<Vec<u8>, String> {
    let layout = ctx.layout();
    if padded.len() != layout.padded {
        return Err("padding does not match the plaintext length".into());
    }
    let aad = ctx.info();
    let (cipher, nonce) = ctx.derive(master)?;
    let mut stream = EncryptorBE32::from_aead(cipher, &nonce);
    let mut out = Vec::with_capacity(layout.ct_len);
    let mut buf = Zeroizing::new(Vec::with_capacity(layout.chunk + TAG_LEN));
    let fail = |_| "encryption failed".to_string();
    for piece in padded.chunks(layout.chunk).take(layout.chunks - 1) {
        buf.clear();
        buf.extend_from_slice(piece);
        stream.encrypt_next_in_place(aad.as_bytes(), &mut *buf).map_err(fail)?;
        out.extend_from_slice(&buf);
    }
    buf.clear();
    buf.extend_from_slice(&padded[(layout.chunks - 1) * layout.chunk..]);
    stream.encrypt_last_in_place(aad.as_bytes(), &mut *buf).map_err(fail)?;
    out.extend_from_slice(&buf);
    Ok(out)
}

/// Decrypts every chunk of `ct` (whose length need not match the descriptor: the public
/// path checks that first). The result is padded plaintext, wiped on drop; on any error
/// nothing is returned.
fn open_stream(ctx: &Context, master: &[u8], ct: &[u8]) -> Result<Zeroizing<Vec<u8>>, String> {
    let full = ctx.chunk_size as usize + TAG_LEN;
    if ct.len() < TAG_LEN {
        return Err("decryption failed".into());
    }
    let chunks = ct.len().div_ceil(full);
    let aad = ctx.info();
    let (cipher, nonce) = ctx.derive(master)?;
    let mut stream = DecryptorBE32::from_aead(cipher, &nonce);
    let mut out = Zeroizing::new(Vec::with_capacity(ct.len()));
    let mut buf = Zeroizing::new(Vec::with_capacity(full));
    let fail = |_| "decryption failed".to_string();
    for piece in ct.chunks(full).take(chunks - 1) {
        buf.clear();
        buf.extend_from_slice(piece);
        stream.decrypt_next_in_place(aad.as_bytes(), &mut *buf).map_err(fail)?;
        out.extend_from_slice(&buf);
    }
    buf.clear();
    buf.extend_from_slice(&ct[(chunks - 1) * full..]);
    stream.decrypt_last_in_place(aad.as_bytes(), &mut *buf).map_err(fail)?;
    out.extend_from_slice(&buf);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgb, RgbImage, Rgba, RgbaImage};

    const CHUNK: u32 = 4096;
    const BLOB: &str = "00000000-0000-4000-8000-000000000001";
    const CONV: &str = "00000000-0000-4000-8000-0000000000c1";

    fn key() -> Vec<u8> {
        (0u8..32).collect()
    }

    fn data(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 7 + 3) as u8).collect()
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn seal(role: &str, chunk: u32, plain: &[u8]) -> SealedBlob {
        encrypt_blob(key(), role.into(), BLOB.into(), CONV.into(), "image/jpeg".into(), chunk, plain.to_vec()).unwrap()
    }

    fn open(role: &str, chunk: u32, plain_len: u32, hash: &[u8], ct: &[u8]) -> Result<Vec<u8>, String> {
        decrypt_blob(key(), role.into(), BLOB.into(), CONV.into(), "image/jpeg".into(), chunk, plain_len, hash.to_vec(), ct.to_vec())
    }

    /// Opens `ct` after recomputing its hash, so the tests reach the AEAD layer.
    fn open_rehashed(plain_len: u32, ct: &[u8]) -> Result<Vec<u8>, String> {
        open("full", CHUNK, plain_len, &Sha256::digest(ct), ct)
    }

    fn ctx(role: &'static str, plain_len: u32) -> Context<'static> {
        Context { role, mime: "image/jpeg", blob_id: BLOB, conversation_id: CONV, chunk_size: CHUNK, plain_len }
    }

    // ---- format -------------------------------------------------------------------------

    #[test]
    fn padme_matches_the_published_definition() {
        for (len, want) in [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (9, 10), (100, 104), (1000, 1024), (65_536, 65_536), (412_000, 417_792)]
        {
            assert_eq!(padme(len), want, "padme({len})");
        }
        for len in (0..5000).chain([65_535, 65_537, 4_000_000, MAX_PLAIN_LEN]) {
            let p = padme(len);
            assert!(p >= len && u64::from(p) * 100 <= u64::from(len) * 112 + 100, "padme({len}) = {p}");
            assert_eq!(padme(p), p, "idempotent at {len}");
        }
    }

    #[test]
    fn size_formula_is_exact() {
        for chunk in [CHUNK, 65_536, MAX_CHUNK] {
            for len in [0usize, 1, 2, 100, chunk as usize - 1, chunk as usize, chunk as usize + 1, 3 * chunk as usize + 17] {
                let sealed = seal("full", chunk, &data(len));
                let padded = padme(len as u32) as usize;
                let chunks = padded.div_ceil(chunk as usize).max(1);
                assert_eq!(sealed.chunks as usize, chunks);
                assert_eq!(sealed.ciphertext.len(), padded + chunks * 16, "len {len} chunk {chunk}");
                assert_eq!(sealed.plain_len as usize, len);
                assert_eq!(sealed.ct_sha256, Sha256::digest(&sealed.ciphertext).to_vec());
            }
        }
        // The documented formula for lengths Padme leaves alone (powers of two).
        let sealed = seal("full", CHUNK, &data(8192));
        assert_eq!(sealed.ciphertext.len(), 8192 + 2 * 16);
        // Chunk i starts at i * (chunk + 16).
        assert_eq!(seal("full", CHUNK, &[]).ciphertext.len(), 16);
    }

    #[test]
    fn round_trips() {
        for chunk in [CHUNK, 65_536] {
            let c = chunk as usize;
            for len in [0, 1, c - 1, c, c + 1, 2 * c, 3 * c + 17] {
                let plain = data(len);
                let sealed = seal("full", chunk, &plain);
                let back = open("full", chunk, len as u32, &sealed.ct_sha256, &sealed.ciphertext).unwrap();
                assert_eq!(back, plain, "len {len} chunk {chunk}");
                assert!(len < 32 || !contains(&sealed.ciphertext, &plain[..32]), "ciphertext must not contain plaintext");
            }
        }
    }

    #[test]
    fn encryption_is_deterministic_per_blob_and_key() {
        let a = seal("full", CHUNK, &data(5000));
        let b = seal("full", CHUNK, &data(5000));
        assert_eq!(a.ciphertext, b.ciphertext);
        let other = encrypt_blob(key(), "full".into(), "other-blob".into(), CONV.into(), "image/jpeg".into(), CHUNK, data(5000)).unwrap();
        assert_ne!(a.ciphertext, other.ciphertext, "a different blob id must give a different keystream");
    }

    #[test]
    fn generated_keys_are_32_random_bytes() {
        let (a, b) = (generate_blob_key(), generate_blob_key());
        assert_eq!((a.len(), b.len()), (32, 32));
        assert_ne!(a, b);
        assert_ne!(a, vec![0u8; 32]);
    }

    // Fixed vectors: a dependency bump that changes HKDF, ChaCha20-Poly1305 or STREAM output fails
    // here. They were also reproduced with an independent pure-Python implementation of
    // HKDF-SHA256, XChaCha20-Poly1305 and the STREAM-BE32 nonce layout.
    #[test]
    fn vectors() {
        let mut okm = [0u8; 51];
        Hkdf::<Sha256>::new(Some(BLOB.as_bytes()), &key()).expand(ctx("full", 0).info().as_bytes(), &mut okm).unwrap();
        assert_eq!(hex(&okm[..32]), "b199e0e38c75daba8c7a9bc2483fddba7e601090a7d0bc5521c52876a505f11c");
        assert_eq!(hex(&okm[32..]), "d1741428c27a82d06d17f228e87b4cf245356f");
        assert_eq!(hex(&seal("full", CHUNK, &[]).ciphertext), "2e2915987e1e2955aced165a79c95ab6");
        assert_eq!(hex(&seal("full", CHUNK, &[0x42]).ciphertext), "99da1c20105adcb1d79ba9ce90805d7160");
        for (role, chunk, len, want) in [
            ("full", CHUNK, 1000usize, "3652e70353c758290c13a8b3766619de4376b515a5829126e296aaf71cfb7934"),
            ("thumb", CHUNK, 10_000, "571d9764b5a54a56912e8f582466250ae27cde3181157aea8bda3d5fb147415b"),
            ("full", 65_536, 70_000, "60e73830e91635f50815dda7e1f7760a8f06373567a8183dcbe52c895e992a5a"),
        ] {
            let sealed = seal(role, chunk, &data(len));
            assert_eq!(hex(&sealed.ct_sha256), want, "{role} {chunk} {len}");
        }
    }

    // ---- tampering ----------------------------------------------------------------------

    const FULL: usize = CHUNK as usize + 16;

    /// Three chunks (two full, one short); returns the true plain length too.
    fn multi() -> (SealedBlob, usize) {
        let len = 2 * CHUNK as usize + 700;
        (seal("full", CHUNK, &data(len)), len)
    }

    #[test]
    fn a_flipped_bit_in_any_chunk_or_the_last_tag_fails() {
        let (sealed, len) = multi();
        assert_eq!(sealed.chunks, 3);
        let mut positions: Vec<usize> = vec![0, FULL / 2, FULL, FULL + 5, 2 * FULL, 2 * FULL + 100, sealed.ciphertext.len() - 1];
        positions.push(FULL - 1); // the tag of the first chunk
        for pos in positions {
            let mut ct = sealed.ciphertext.clone();
            ct[pos] ^= 0x01;
            assert!(open_rehashed(len as u32, &ct).is_err(), "flip at {pos}");
            // With the original hash the container is rejected before any decryption.
            assert_eq!(open("full", CHUNK, len as u32, &sealed.ct_sha256, &ct).unwrap_err(), "ciphertext hash mismatch");
        }
    }

    #[test]
    fn truncation_extension_duplication_and_reordering_fail() {
        let (sealed, len) = multi();
        let ct = &sealed.ciphertext;
        let c = |i: usize| ct[i * FULL..((i + 1) * FULL).min(ct.len())].to_vec();
        let ctx = ctx("full", len as u32);

        // Truncated: drop the last chunk, or only its final byte.
        assert!(open_stream(&ctx, &key(), &ct[..2 * FULL]).is_err(), "dropped last chunk");
        assert!(open_stream(&ctx, &key(), &ct[..ct.len() - 1]).is_err());
        assert!(open_rehashed(len as u32, &ct[..2 * FULL]).is_err());
        // Appended: junk, a whole chunk, or a second copy of the stream.
        for extra in [vec![0u8; 1], vec![0u8; 16], vec![7u8; FULL]] {
            let longer = [ct.clone(), extra].concat();
            assert!(open_stream(&ctx, &key(), &longer).is_err());
            assert!(open_rehashed(len as u32, &longer).is_err());
        }
        // Duplicated: a chunk repeated in place of its neighbour (same length) or inserted.
        let dup = [c(0), c(0), c(2)].concat();
        assert_eq!(dup.len(), ct.len());
        assert!(open_stream(&ctx, &key(), &dup).is_err());
        let inserted = [c(0), c(1), c(1), c(2)].concat();
        assert!(open_stream(&ctx, &key(), &inserted).is_err());
        assert!(open_rehashed(len as u32, &inserted).is_err());
        // Reordered: swap the first two chunks.
        let swapped = [c(1), c(0), c(2)].concat();
        assert_eq!(swapped.len(), ct.len());
        assert!(open_rehashed(len as u32, &swapped).is_err());
        // The last chunk cannot be moved to the front or reused as a middle chunk.
        let rotated = [c(2), c(0), c(1)].concat();
        assert!(open_stream(&ctx, &key(), &rotated).is_err());
        // Sanity: the untouched stream opens.
        assert_eq!(open_rehashed(len as u32, ct).unwrap(), data(len));
    }

    #[test]
    fn a_shorter_claimed_length_cannot_hide_truncation() {
        // The attacker cuts at a chunk boundary and adjusts plainLen and the hash to match.
        let (sealed, _) = multi();
        let cut = &sealed.ciphertext[..2 * FULL];
        for claimed in [CHUNK, 2 * CHUNK, 2 * CHUNK - 100] {
            assert!(open("full", CHUNK, claimed, &Sha256::digest(cut), cut).is_err(), "claimed {claimed}");
        }
    }

    #[test]
    fn wrong_key_or_context_fails() {
        let sealed = seal("full", CHUNK, &data(1000));
        let (h, ct) = (&sealed.ct_sha256, &sealed.ciphertext);
        assert_eq!(open("full", CHUNK, 1000, h, ct).unwrap(), data(1000));
        let go = |key: Vec<u8>, role: &str, blob: &str, conv: &str, mime: &str, chunk: u32, plain_len: u32| {
            decrypt_blob(key, role.into(), blob.into(), conv.into(), mime.into(), chunk, plain_len, h.clone(), ct.clone())
        };
        let mut wrong_key = key();
        wrong_key[0] ^= 1;
        assert!(go(wrong_key, "full", BLOB, CONV, "image/jpeg", CHUNK, 1000).is_err(), "key");
        assert!(go(key(), "thumb", BLOB, CONV, "image/jpeg", CHUNK, 1000).is_err(), "role");
        assert!(go(key(), "full", "00000000-0000-4000-8000-000000000002", CONV, "image/jpeg", CHUNK, 1000).is_err(), "blob id");
        assert!(go(key(), "full", BLOB, "00000000-0000-4000-8000-0000000000c2", "image/jpeg", CHUNK, 1000).is_err(), "conversation");
        assert!(go(key(), "full", BLOB, CONV, "image/png", CHUNK, 1000).is_err(), "mime");
        assert!(go(key(), "full", BLOB, CONV, "image/jpeg", 2 * CHUNK, 1000).is_err(), "chunk size");
        // 1001 pads to the same 1024 bytes, so only the AAD and key binding can catch it.
        assert_eq!(padme(1000), padme(1001));
        assert!(go(key(), "full", BLOB, CONV, "image/jpeg", CHUNK, 1001).is_err(), "plain len");
        assert!(go(key(), "full", BLOB, CONV, "image/jpeg", CHUNK, 999).is_err(), "plain len down");
        assert!(go(vec![0; 31], "full", BLOB, CONV, "image/jpeg", CHUNK, 1000).is_err(), "short key");
    }

    #[test]
    fn every_context_field_changes_the_derived_key_material() {
        let derive = |c: &Context| {
            let mut okm = [0u8; 51];
            Hkdf::<Sha256>::new(Some(c.blob_id.as_bytes()), &key()).expand(c.info().as_bytes(), &mut okm).unwrap();
            okm
        };
        let base = ctx("full", 10);
        let reference = derive(&base);
        let variants = [
            Context { role: "thumb", ..ctx("full", 10) },
            Context { mime: "image/png", ..ctx("full", 10) },
            Context { blob_id: "other", ..ctx("full", 10) },
            Context { conversation_id: "other", ..ctx("full", 10) },
            Context { chunk_size: CHUNK * 2, ..ctx("full", 10) },
            ctx("full", 11),
        ];
        for v in &variants {
            let okm = derive(v);
            assert_ne!(okm[..32], reference[..32]);
            assert_ne!(okm[32..], reference[32..]);
        }
        // Full and thumb of the same message never share a key or a nonce prefix.
        assert_ne!(derive(&ctx("full", 10))[..32], derive(&ctx("thumb", 10))[..32]);
        assert!(base.info().starts_with("hiyall-chat-blob/v1|full|image/jpeg|4096|10|"));
    }

    #[test]
    fn nonzero_padding_is_rejected() {
        let c = ctx("full", 1000);
        let mut padded = data(1000);
        padded.resize(padme(1000) as usize, 0);
        let good = seal_stream(&c, &key(), &padded).unwrap();
        assert!(open_rehashed(1000, &good).is_ok());
        *padded.last_mut().unwrap() = 1;
        let bad = seal_stream(&c, &key(), &padded).unwrap();
        assert_eq!(open_rehashed(1000, &bad).unwrap_err(), "padding is not zero");
        // The padding is authenticated, not just checked: flipping it in the ciphertext fails too.
        let mut flipped = good.clone();
        flipped[1010] ^= 1;
        assert!(open_rehashed(1000, &flipped).is_err());
        // seal_stream refuses an unpadded or over-padded buffer.
        assert!(seal_stream(&c, &key(), &data(1000)).is_err());
    }

    #[test]
    fn a_wrong_hash_is_rejected_before_decryption() {
        let sealed = seal("full", CHUNK, &data(500));
        let mut wrong = sealed.ct_sha256.clone();
        wrong[31] ^= 1;
        assert_eq!(open("full", CHUNK, 500, &wrong, &sealed.ciphertext).unwrap_err(), "ciphertext hash mismatch");
        assert!(open("full", CHUNK, 500, &wrong[..31], &sealed.ciphertext).is_err());
        assert!(open("full", CHUNK, 500, &[], &sealed.ciphertext).is_err());
        // Wrong length is reported even when the hash is right for what was supplied.
        let longer = [sealed.ciphertext.clone(), vec![0]].concat();
        assert_eq!(
            open("full", CHUNK, 500, &Sha256::digest(&longer), &longer).unwrap_err(),
            "ciphertext length does not match the descriptor"
        );
    }

    // ---- limits and validation ----------------------------------------------------------

    /// Voice and video blobs: each role only seals its own mime, the whole format round trips, and the
    /// size bound that holds the 40 MiB video cap is enforced.
    #[test]
    fn voice_and_video_roles_round_trip_and_pair_with_their_mime() {
        let seal_as = |role: &str, mime: &str, chunk: u32, plain: Vec<u8>| {
            encrypt_blob(key(), role.into(), BLOB.into(), CONV.into(), mime.into(), chunk, plain)
        };
        for (role, mime, len) in [("voice", "audio/mp4", 100_000usize), ("video", "video/mp4", 3_000_000)] {
            let plain = data(len);
            let sealed = seal_as(role, mime, 65_536, plain.clone()).unwrap();
            let back = decrypt_blob(
                key(),
                role.into(),
                BLOB.into(),
                CONV.into(),
                mime.into(),
                65_536,
                len as u32,
                sealed.ct_sha256.clone(),
                sealed.ciphertext.clone(),
            )
            .unwrap();
            assert_eq!(back, plain, "{role}");
            // A different role (even with its own right mime) cannot open it.
            let other = if role == "voice" { ("video", "video/mp4") } else { ("voice", "audio/mp4") };
            assert!(decrypt_blob(
                key(),
                other.0.into(),
                BLOB.into(),
                CONV.into(),
                other.1.into(),
                65_536,
                len as u32,
                sealed.ct_sha256.clone(),
                sealed.ciphertext.clone(),
            )
            .is_err());
        }
        // Role and mime must pair.
        assert!(seal_as("voice", "video/mp4", CHUNK, vec![1]).is_err());
        assert!(seal_as("video", "audio/mp4", CHUNK, vec![1]).is_err());
        assert!(seal_as("video", "image/jpeg", CHUNK, vec![1]).is_err());
        assert!(seal_as("full", "video/mp4", CHUNK, vec![1]).is_err());
        assert!(seal_as("thumb", "audio/mp4", CHUNK, vec![1]).is_err());
        // The video cap: 40 MiB of plaintext is accepted, one byte more is refused.
        assert!(seal_as("video", "video/mp4", MAX_CHUNK, vec![0; MAX_PLAIN_LEN as usize + 1]).is_err());
    }

    #[test]
    fn parameters_are_validated() {
        let enc = |key: Vec<u8>, role: &str, blob: &str, conv: &str, mime: &str, chunk: u32, plain: Vec<u8>| {
            encrypt_blob(key, role.into(), blob.into(), conv.into(), mime.into(), chunk, plain)
        };
        let ok = |chunk: u32| enc(key(), "full", BLOB, CONV, "image/jpeg", chunk, vec![1]);
        assert!(ok(CHUNK).is_ok() && ok(65_536).is_ok() && ok(MAX_CHUNK).is_ok());
        for bad in [0, 1, 2048, 4095, 5000, 65_535, 3 * 4096, MAX_CHUNK * 2, u32::MAX] {
            assert!(ok(bad).is_err(), "chunk size {bad}");
        }
        for role in ["", "poster", "audio", "FULL", "full ", "VIDEO", "voice "] {
            assert!(enc(key(), role, BLOB, CONV, "image/jpeg", CHUNK, vec![]).is_err(), "role {role:?}");
        }
        for mime in ["", "image/png", "image/webp", "video/mp4", "audio/mp4", "IMAGE/JPEG", "image/jpeg; x=1"] {
            assert!(enc(key(), "full", BLOB, CONV, mime, CHUNK, vec![]).is_err(), "mime {mime:?}");
        }
        for id in ["", "a b", "a|b\n", "é", &"x".repeat(129)] {
            assert!(enc(key(), "full", id, CONV, "image/jpeg", CHUNK, vec![]).is_err(), "blob id {id:?}");
            assert!(enc(key(), "full", BLOB, id, "image/jpeg", CHUNK, vec![]).is_err(), "conversation id {id:?}");
        }
        for len in [0, 16, 31, 33, 64] {
            assert!(enc(vec![0; len], "full", BLOB, CONV, "image/jpeg", CHUNK, vec![]).is_err(), "key length {len}");
        }
        // The size cap applies to encryption and to claims made while decrypting.
        assert!(enc(key(), "full", BLOB, CONV, "image/jpeg", MAX_CHUNK, vec![0; MAX_PLAIN_LEN as usize + 1]).is_err());
        let err = decrypt_blob(
            key(),
            "full".into(),
            BLOB.into(),
            CONV.into(),
            "image/jpeg".into(),
            CHUNK,
            MAX_PLAIN_LEN + 1,
            vec![0; 32],
            vec![0; 100],
        )
        .unwrap_err();
        assert_eq!(err, "plaintext too large");
        let sealed = enc(key(), "full", BLOB, CONV, "image/jpeg", MAX_CHUNK, vec![9; MAX_PLAIN_LEN as usize]).unwrap();
        assert_eq!(sealed.plain_len, MAX_PLAIN_LEN);
        assert_eq!(open("full", MAX_CHUNK, MAX_PLAIN_LEN, &sealed.ct_sha256, &sealed.ciphertext).unwrap().len(), MAX_PLAIN_LEN as usize);
    }

    #[test]
    fn errors_do_not_contain_key_material() {
        let k = key();
        let e = decrypt_blob(k.clone(), "full".into(), BLOB.into(), CONV.into(), "image/jpeg".into(), CHUNK, 10, vec![0; 32], vec![0; 26])
            .unwrap_err();
        assert!(!e.contains(&hex(&k)) && !e.contains(BLOB));
    }

    // ---- fuzz-style ---------------------------------------------------------------------

    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }
        fn bytes_upto(&mut self, max: u64) -> Vec<u8> {
            let n = (self.next() % max) as usize;
            self.bytes(n)
        }
        fn bytes(&mut self, n: usize) -> Vec<u8> {
            (0..n).map(|_| self.next() as u8).collect()
        }
    }

    #[test]
    fn garbage_never_panics_or_decrypts() {
        let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
        for _ in 0..400 {
            let chunk = 4096u32 << (rng.next() % 3);
            let plain_len = (rng.next() % 20_000) as u32;
            let layout = ctx("full", plain_len).layout();
            // Right length, random bytes, correct hash: only the AEAD can reject it.
            let ct = rng.bytes(layout.ct_len);
            let c = Context { chunk_size: chunk, ..ctx("full", plain_len) };
            let ct = if chunk == CHUNK { ct } else { rng.bytes(c.layout().ct_len) };
            assert!(open("full", chunk, plain_len, &Sha256::digest(&ct), &ct).is_err());
            // Arbitrary length, arbitrary parameters, arbitrary hash.
            let ct = rng.bytes_upto(300);
            let res = decrypt_blob(
                rng.bytes(32),
                "full".into(),
                BLOB.into(),
                CONV.into(),
                "image/jpeg".into(),
                rng.next() as u32,
                rng.next() as u32,
                rng.bytes(32),
                ct.clone(),
            );
            assert!(res.is_err());
            assert!(open_stream(&ctx("full", 0), &key(), &ct).is_err());
        }
        // Truncations of a real blob at every length never panic and never open.
        let sealed = seal("full", CHUNK, &data(2 * CHUNK as usize + 3));
        for cut in 0..sealed.ciphertext.len().min(300) {
            assert!(open_stream(&ctx("full", 2 * CHUNK + 3), &key(), &sealed.ciphertext[..cut]).is_err());
        }
    }

    #[test]
    fn malformed_previews_never_panic() {
        let mut rng = Rng(0x1234_5678_9abc_def1);
        for _ in 0..4000 {
            let bytes = rng.bytes_upto(70);
            // Call the decoder directly too, so a panic inside it is a test failure, not a swallowed error.
            if (MIN_PREVIEW_BYTES..=MAX_PREVIEW_BYTES).contains(&bytes.len()) {
                let direct = bytes.clone();
                assert!(
                    std::panic::catch_unwind(|| {
                        let _ = thumbhash::thumb_hash_to_rgba(&direct);
                    })
                    .is_ok(),
                    "thumbhash panicked on {}",
                    hex(&direct)
                );
            }
            if let Ok(p) = preview_to_rgba(bytes) {
                assert_eq!(p.rgba.len(), (p.w * p.h * 4) as usize);
                assert!(p.w <= 32 && p.h <= 32 && p.w > 0 && p.h > 0);
            }
        }
        for bad in [vec![], vec![0; 4], vec![0xff; 5], vec![0xff; 65], vec![0; 30]] {
            let _ = preview_to_rgba(bad);
        }
    }

    // ---- images -------------------------------------------------------------------------

    fn jpeg(img: &RgbImage) -> Vec<u8> {
        encode_jpeg(&DynamicImage::ImageRgb8(img.clone()), 90).unwrap()
    }

    /// Splits left half red, right half blue.
    fn two_tone(w: u32, h: u32) -> RgbImage {
        RgbImage::from_fn(w, h, |x, _| if x < w / 2 { Rgb([230, 20, 20]) } else { Rgb([20, 20, 230]) })
    }

    /// Inserts an Exif APP1 segment (orientation tag plus a GPS-like marker) after the SOI.
    fn with_exif(jpg: &[u8], orientation: u8) -> Vec<u8> {
        let mut tiff = vec![b'M', b'M', 0, 42, 0, 0, 0, 8];
        tiff.extend([0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation, 0, 0, 0, 0, 0, 0, 0, 0]);
        let mut body = b"Exif\0\0".to_vec();
        body.extend(&tiff);
        body.extend(b"GPS-LAT-12.97");
        let mut out = vec![0xFF, 0xD8, 0xFF, 0xE1];
        out.extend(((body.len() + 2) as u16).to_be_bytes());
        out.extend(body);
        out.extend(&jpg[2..]);
        out
    }

    /// Marker bytes of every JPEG segment before the scan data.
    fn jpeg_markers(jpg: &[u8]) -> Vec<u8> {
        let mut markers = Vec::new();
        let mut i = 2;
        while i + 4 <= jpg.len() && jpg[i] == 0xFF {
            let m = jpg[i + 1];
            markers.push(m);
            if m == 0xDA {
                break;
            }
            i += 2 + u16::from_be_bytes([jpg[i + 2], jpg[i + 3]]) as usize;
        }
        markers
    }

    fn decode(jpg: &[u8]) -> RgbImage {
        image::load_from_memory_with_format(jpg, ImageFormat::Jpeg).unwrap().to_rgb8()
    }

    fn crc32(bytes: &[u8]) -> u32 {
        let mut crc = !0u32;
        for &b in bytes {
            crc ^= u32::from(b);
            for _ in 0..8 {
                crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
            }
        }
        !crc
    }

    /// A PNG with a valid IHDR and a stub IDAT (so the decoder reaches the size checks) but no pixel data.
    fn png_header(w: u32, h: u32) -> Vec<u8> {
        png_header_with(w, h, 8, 2)
    }

    fn png_header_with(w: u32, h: u32, depth: u8, color: u8) -> Vec<u8> {
        let mut ihdr = b"IHDR".to_vec();
        ihdr.extend(w.to_be_bytes());
        ihdr.extend(h.to_be_bytes());
        ihdr.extend([depth, color, 0, 0, 0]);
        let mut out = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
        out.extend(&ihdr);
        out.extend(crc32(&ihdr).to_be_bytes());
        // The decoder reads up to the first IDAT before it reports the image size.
        let idat = b"IDAT\x78\x9c".to_vec();
        out.extend(2u32.to_be_bytes());
        out.extend(&idat);
        out.extend(crc32(&idat).to_be_bytes());
        out
    }

    #[test]
    fn exif_and_gps_are_stripped_and_orientation_is_applied() {
        let tagged = with_exif(&jpeg(&two_tone(300, 200)), 6);
        assert!(contains(&tagged, b"Exif") && contains(&tagged, b"GPS-LAT"), "fixture carries metadata");
        assert!(jpeg_markers(&tagged).contains(&0xE1));
        let out = prepare_chat_image(tagged).unwrap();
        assert_eq!((out.full_w, out.full_h), (200, 300), "orientation 6 turns 300x200 into 200x300");
        for jpg in [&out.full, &out.thumb] {
            assert!(!contains(jpg, b"Exif") && !contains(jpg, b"GPS-LAT") && !contains(jpg, b"ICC_PROFILE"));
            assert!(
                jpeg_markers(jpg).iter().all(|m| !(0xE1..=0xEF).contains(m) && *m != 0xFE),
                "only pixel segments: {:02x?}",
                jpeg_markers(jpg)
            );
        }
        // Rotated 90 degrees clockwise: the red left half is now the top half.
        let img = decode(&out.full);
        assert_eq!(img.dimensions(), (200, 300));
        let top = img.get_pixel(100, 30);
        let bottom = img.get_pixel(100, 270);
        assert!(top[0] > 180 && top[2] < 90, "top {top:?}");
        assert!(bottom[2] > 180 && bottom[0] < 90, "bottom {bottom:?}");
    }

    #[test]
    fn other_orientations_are_applied() {
        let base = jpeg(&two_tone(300, 200));
        // 3 = rotated 180: red moves to the right; 1 = unchanged; 8 = 90 counter-clockwise: red at the bottom.
        let right_pixel = |orientation: u8| {
            let out = prepare_chat_image(with_exif(&base, orientation)).unwrap();
            let img = decode(&out.full);
            (img.dimensions(), *img.get_pixel(img.width() - 10, img.height() - 10), *img.get_pixel(10, 10))
        };
        let (dims, br, tl) = right_pixel(3);
        assert_eq!(dims, (300, 200));
        assert!(br[0] > 180 && tl[2] > 180);
        let (dims, br, tl) = right_pixel(1);
        assert_eq!(dims, (300, 200));
        assert!(br[2] > 180 && tl[0] > 180);
        let (dims, br, tl) = right_pixel(8);
        assert_eq!(dims, (200, 300));
        assert!(br[0] > 180 && tl[2] > 180, "tl {tl:?} br {br:?}");
    }

    #[test]
    fn large_images_are_downscaled_and_small_ones_are_not_upscaled() {
        let big = jpeg(&RgbImage::from_fn(2600, 1300, |x, y| Rgb([(x / 11) as u8, (y / 5) as u8, 90])));
        let out = prepare_chat_image(big).unwrap();
        assert_eq!((out.full_w, out.full_h), (2048, 1024));
        assert_eq!((out.thumb_w, out.thumb_h), (320, 160));
        assert_eq!(decode(&out.full).dimensions(), (2048, 1024));
        assert_eq!(decode(&out.thumb).dimensions(), (320, 160));
        assert!(out.thumb.len() < out.full.len());

        let tall = prepare_chat_image(jpeg(&RgbImage::new(900, 2400))).unwrap();
        assert_eq!((tall.full_w, tall.full_h), (768, 2048));
        assert_eq!((tall.thumb_w, tall.thumb_h), (120, 320));

        let small = prepare_chat_image(jpeg(&RgbImage::new(100, 50))).unwrap();
        assert_eq!((small.full_w, small.full_h, small.thumb_w, small.thumb_h), (100, 50, 100, 50));

        let medium = prepare_chat_image(jpeg(&RgbImage::new(1000, 600))).unwrap();
        assert_eq!((medium.full_w, medium.full_h), (1000, 600), "within 2048: kept as is");
        assert_eq!((medium.thumb_w, medium.thumb_h), (320, 192));
        // Extreme aspect ratios keep at least one pixel on the short side.
        let strip = prepare_chat_image(jpeg(&RgbImage::new(4000, 3))).unwrap();
        assert_eq!((strip.full_w, strip.full_h), (2048, 2));
        assert!(strip.thumb_h >= 1);
    }

    #[test]
    fn png_and_webp_inputs_work_and_transparency_is_flattened_onto_white() {
        let mut rgba = RgbaImage::from_pixel(64, 48, Rgba([200, 30, 30, 255]));
        for x in 0..32 {
            for y in 0..48 {
                rgba.put_pixel(x, y, Rgba([0, 0, 0, 0]));
            }
        }
        let mut png = Vec::new();
        DynamicImage::ImageRgba8(rgba.clone()).write_to(&mut Cursor::new(&mut png), ImageFormat::Png).unwrap();
        let out = prepare_chat_image(png).unwrap();
        let img = decode(&out.full);
        assert_eq!(img.dimensions(), (64, 48));
        let clear = img.get_pixel(8, 24);
        assert!(clear.0.iter().all(|c| *c > 240), "transparent pixels become white, got {clear:?}");
        let solid = img.get_pixel(56, 24);
        assert!(solid[0] > 170 && solid[1] < 70, "opaque pixels keep their colour, got {solid:?}");

        let mut webp = Vec::new();
        DynamicImage::ImageRgba8(rgba).write_to(&mut Cursor::new(&mut webp), ImageFormat::WebP).unwrap();
        let out = prepare_chat_image(webp).unwrap();
        assert_eq!((out.full_w, out.full_h), (64, 48));
        assert!(decode(&out.full).get_pixel(8, 24).0.iter().all(|c| *c > 240));

        // Half transparent black over white is mid grey.
        let half = RgbaImage::from_pixel(8, 8, Rgba([0, 0, 0, 128]));
        let flat = flatten_on_white(DynamicImage::ImageRgba8(half)).to_rgb8();
        assert!((flat.get_pixel(0, 0)[0] as i32 - 127).abs() <= 1);
    }

    #[test]
    fn junk_unsupported_and_oversized_input_is_refused() {
        for junk in [
            vec![],
            b"not an image".to_vec(),
            vec![0u8; 1000],
            b"GIF89a\x01\x00\x01\x00\x00\x00\x00;".to_vec(),
            b"BM\x1e\0\0\0\0\0\0\0\x1a\0\0\0".to_vec(),
            b"%PDF-1.7 \n".to_vec(),
            b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00".to_vec(),
        ] {
            let err = prepare_chat_image(junk).err().unwrap();
            assert!(!err.is_empty());
        }
        assert!(prepare_chat_image(b"GIF89a\x01\x00\x01\x00\x00\x00\x00;".to_vec()).err().unwrap().contains("unsupported"));
        // Valid headers claiming more than 40 MP (the decoder budget or our pixel cap refuses them) or a huge canvas.
        assert!(prepare_chat_image(png_header(11_000, 11_000)).is_err());
        // 1-bit greyscale is cheap enough for the decoder budget, so only our own pixel cap stops it.
        assert_eq!(prepare_chat_image(png_header_with(7_000, 6_000, 1, 0)).err().unwrap(), "image dimensions are too large");
        assert!(prepare_chat_image(png_header_with(5_000, 6_000, 1, 0)).is_err(), "30 MP passes the cap but has no pixel data");
        assert_ne!(prepare_chat_image(png_header_with(5_000, 6_000, 1, 0)).err().unwrap(), "image dimensions are too large");
        assert!(prepare_chat_image(png_header(20_000, 100)).is_err());
        assert!(prepare_chat_image(png_header(u32::MAX, u32::MAX)).is_err());
        // A header within the limits but with no pixel data fails to decode instead of panicking.
        assert!(prepare_chat_image(png_header(100, 100)).is_err());
        // Truncated real JPEG.
        let jpg = jpeg(&two_tone(300, 200));
        assert!(prepare_chat_image(jpg[..20].to_vec()).is_err());
    }

    #[test]
    fn corrupted_images_never_panic() {
        let jpg = with_exif(&jpeg(&two_tone(120, 80)), 6);
        let mut rng = Rng(0xdead_beef_cafe_f00d);
        for _ in 0..150 {
            let mut bytes = jpg.clone();
            for _ in 0..(1 + rng.next() % 8) {
                let at = (rng.next() as usize) % bytes.len();
                bytes[at] = rng.next() as u8;
            }
            if rng.next().is_multiple_of(3) {
                bytes.truncate((rng.next() as usize) % bytes.len());
            }
            let _ = prepare_chat_image(bytes);
        }
        for _ in 0..100 {
            let _ = prepare_chat_image(rng.bytes_upto(400));
        }
    }

    #[test]
    fn preview_is_tiny_and_round_trips_to_rgba() {
        let out = prepare_chat_image(jpeg(&two_tone(300, 200))).unwrap();
        assert!((10..=40).contains(&out.preview.len()), "preview is {} bytes", out.preview.len());
        let p = preview_to_rgba(out.preview.clone()).unwrap();
        assert_eq!(p.rgba.len(), (p.w * p.h * 4) as usize);
        assert!(p.w > p.h, "landscape source gives a landscape preview ({}x{})", p.w, p.h);
        let px = |x: u32, y: u32| {
            let i = ((y * p.w + x) * 4) as usize;
            [p.rgba[i], p.rgba[i + 1], p.rgba[i + 2], p.rgba[i + 3]]
        };
        let (left, right) = (px(2, p.h / 2), px(p.w - 3, p.h / 2));
        assert!(left[0] > left[2] + 40, "left leans red: {left:?}");
        assert!(right[2] > right[0] + 40, "right leans blue: {right:?}");
        assert_eq!(left[3], 255);
        // The preview is derived from the thumbnail: oriented images give a portrait preview.
        let rotated = prepare_chat_image(with_exif(&jpeg(&two_tone(300, 200)), 6)).unwrap();
        let q = preview_to_rgba(rotated.preview).unwrap();
        assert!(q.h > q.w, "{}x{}", q.w, q.h);
        assert!(preview_to_rgba(vec![1, 2, 3]).is_err());
    }

    // Manual timing and memory check for a 12 MP photo: cargo test --release -- --ignored twelve
    #[test]
    #[ignore]
    fn twelve_megapixel_photo() {
        let photo = jpeg(&RgbImage::from_fn(4032, 3024, |x, y| Rgb([(x / 16) as u8, (y / 12) as u8, ((x ^ y) / 8) as u8])));
        let start = std::time::Instant::now();
        let out = prepare_chat_image(with_exif(&photo, 6)).unwrap();
        println!(
            "12 MP in {:?}: full {}x{} {} B, thumb {} B, preview {} B",
            start.elapsed(),
            out.full_w,
            out.full_h,
            out.full.len(),
            out.thumb.len(),
            out.preview.len()
        );
        assert_eq!((out.full_w, out.full_h), (1536, 2048));
    }

    fn contains(hay: &[u8], needle: &[u8]) -> bool {
        hay.windows(needle.len()).any(|w| w == needle)
    }
}
