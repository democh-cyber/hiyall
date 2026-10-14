//! Sealing of the app's own local state (the encrypted chat snapshot, see
//! docs/security/13-encrypted-chat-implementation.md): one XChaCha20-Poly1305
//! message with a random 24-byte nonce. The key is 32 random bytes the app keeps in
//! the platform keystore (this device only); `aad` binds the account and the
//! generation counter so a snapshot cannot be moved to another account.
//!
//! Output layout: `nonce (24) || ciphertext || tag (16)`. No custom cryptography:
//! this file only fixes the framing and wipes buffers.

use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce};
use flutter_rust_bridge::frb;
use rand_core::{OsRng, RngCore};
use zeroize::Zeroizing;

const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 24;
const TAG_LEN: usize = 16;

fn cipher(key: Vec<u8>) -> Result<XChaCha20Poly1305, String> {
    let key = Zeroizing::new(key);
    XChaCha20Poly1305::new_from_slice(&key).map_err(|_| "seal key must be 32 bytes".to_string())
}

/// A fresh random 256-bit key from the OS CSPRNG.
#[frb(sync)]
pub fn generate_seal_key() -> Vec<u8> {
    let mut key = Zeroizing::new([0u8; KEY_LEN]);
    OsRng.fill_bytes(&mut *key);
    key.to_vec()
}

/// Seals `plaintext` under `key`, authenticating `aad` as well.
pub fn seal_state(key: Vec<u8>, aad: Vec<u8>, plaintext: Vec<u8>) -> Result<Vec<u8>, String> {
    let cipher = cipher(key)?;
    let plain = Zeroizing::new(plaintext);
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    let xnonce = XNonce::try_from(&nonce[..]).map_err(|_| "sealing failed".to_string())?;
    let sealed = cipher.encrypt(&xnonce, Payload { msg: &plain, aad: &aad }).map_err(|_| "sealing failed".to_string())?;
    let mut out = Vec::with_capacity(NONCE_LEN + sealed.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&sealed);
    Ok(out)
}

/// Opens what [`seal_state`] made. Any change to the bytes, the key or the `aad` fails.
pub fn open_state(key: Vec<u8>, aad: Vec<u8>, sealed: Vec<u8>) -> Result<Vec<u8>, String> {
    let cipher = cipher(key)?;
    if sealed.len() < NONCE_LEN + TAG_LEN {
        return Err("sealed data is too short".into());
    }
    let (nonce, body) = sealed.split_at(NONCE_LEN);
    let xnonce = XNonce::try_from(nonce).map_err(|_| "could not open sealed data".to_string())?;
    cipher.decrypt(&xnonce, Payload { msg: body, aad: &aad }).map_err(|_| "could not open sealed data".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_binding() {
        let key = generate_seal_key();
        assert_eq!(key.len(), 32);
        let sealed = seal_state(key.clone(), b"acct|1".to_vec(), b"hello".to_vec()).unwrap();
        assert_eq!(sealed.len(), NONCE_LEN + 5 + TAG_LEN);
        assert!(!sealed.windows(5).any(|w| w == b"hello"));
        assert_eq!(open_state(key.clone(), b"acct|1".to_vec(), sealed.clone()).unwrap(), b"hello");
        // Wrong key, wrong aad, flipped bit, truncation: all fail.
        assert!(open_state(generate_seal_key(), b"acct|1".to_vec(), sealed.clone()).is_err());
        assert!(open_state(key.clone(), b"acct|2".to_vec(), sealed.clone()).is_err());
        let mut flipped = sealed.clone();
        let last = flipped.len() - 1;
        flipped[last] ^= 1;
        assert!(open_state(key.clone(), b"acct|1".to_vec(), flipped).is_err());
        assert!(open_state(key.clone(), b"acct|1".to_vec(), sealed[..sealed.len() - 1].to_vec()).is_err());
        assert!(open_state(key.clone(), b"acct|1".to_vec(), vec![0; 10]).is_err());
        assert!(seal_state(vec![1; 16], vec![], vec![]).is_err());
    }

    #[test]
    fn nonces_are_not_reused() {
        let key = generate_seal_key();
        let a = seal_state(key.clone(), vec![], b"same".to_vec()).unwrap();
        let b = seal_state(key, vec![], b"same".to_vec()).unwrap();
        assert_ne!(a[..NONCE_LEN], b[..NONCE_LEN]);
        assert_ne!(a, b);
    }

    #[test]
    fn empty_plaintext_is_allowed() {
        let key = generate_seal_key();
        let sealed = seal_state(key.clone(), vec![], vec![]).unwrap();
        assert!(open_state(key, vec![], sealed).unwrap().is_empty());
    }
}
