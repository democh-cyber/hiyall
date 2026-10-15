//! Hiyall's end-to-end encryption core: a deliberately small surface over
//! vodozemac's Olm (3DH + Double Ratchet). No custom cryptography lives here;
//! this file only converts types and enforces our usage rules:
//! - sessions use Olm version 1 only (no downgrade or experimental configs);
//! - every peer Curve25519 key must be contributory (non-low-order);
//! - pickles are encrypted with a 32-byte key held by the platform keystore.
//!
//! See docs/security/12-e2ee-library-evaluation.md.

use flutter_rust_bridge::frb;
use rand_core::OsRng;
use vodozemac::olm::{Account, OlmMessage, PreKeyMessage, Session, SessionConfig};
use vodozemac::{base64_decode, base64_encode, Curve25519PublicKey, Ed25519PublicKey, Ed25519Signature};
use x25519_dalek::{PublicKey as DalekPublic, StaticSecret};
use zeroize::Zeroizing;

const CONFIG: fn() -> SessionConfig = SessionConfig::version_1;

fn pickle_key(key: Vec<u8>) -> Result<Zeroizing<[u8; 32]>, String> {
    let key = Zeroizing::new(key);
    let array: [u8; 32] = key.as_slice().try_into().map_err(|_| "pickle key must be 32 bytes".to_string())?;
    Ok(Zeroizing::new(array))
}

fn curve_key(value: &str) -> Result<Curve25519PublicKey, String> {
    let key = Curve25519PublicKey::from_base64(value).map_err(|_| "invalid Curve25519 key".to_string())?;
    if !is_contributory(&key) {
        return Err("rejected a non-contributory (low-order) key".into());
    }
    Ok(key)
}

/// Defence in depth on top of vodozemac's own check: a low-order point yields an
/// all-zero shared secret for every private key, so test it with a throwaway one.
fn is_contributory(key: &Curve25519PublicKey) -> bool {
    let probe = StaticSecret::random_from_rng(OsRng);
    probe.diffie_hellman(&DalekPublic::from(key.to_bytes())).was_contributory()
}

#[frb(sync)]
pub fn is_contributory_key(key: String) -> bool {
    Curve25519PublicKey::from_base64(&key).map(|k| is_contributory(&k)).unwrap_or(false)
}

/// Strict Ed25519 verification of a signed device or one-time-key statement.
#[frb(sync)]
pub fn verify_signature(signing_key: String, message: String, signature: String) -> bool {
    let Ok(key) = Ed25519PublicKey::from_base64(&signing_key) else { return false };
    let Ok(signature) = Ed25519Signature::from_base64(&signature) else { return false };
    key.verify(message.as_bytes(), &signature).is_ok()
}

pub struct PublicKeyEntry {
    pub key_id: String,
    pub public_key: String,
}

pub struct EncryptedMessage {
    /// 0 = pre-key message (starts a session), 1 = normal message.
    pub message_type: u8,
    pub ciphertext: String,
}

/// A device's long-term identity and one-time keys.
#[frb(opaque)]
pub struct OlmAccount {
    account: Account,
}

impl OlmAccount {
    #[frb(sync)]
    pub fn create() -> OlmAccount {
        OlmAccount { account: Account::new() }
    }

    #[frb(sync)]
    pub fn restore(pickle: String, pickle_key: Vec<u8>) -> Result<OlmAccount, String> {
        let key = self::pickle_key(pickle_key)?;
        let pickle = vodozemac::olm::AccountPickle::from_encrypted(&pickle, &key).map_err(|_| "could not unlock account".to_string())?;
        Ok(OlmAccount { account: Account::from_pickle(pickle) })
    }

    #[frb(sync)]
    pub fn pickle(&self, pickle_key: Vec<u8>) -> Result<String, String> {
        Ok(self.account.pickle().encrypt(&*self::pickle_key(pickle_key)?))
    }

    #[frb(sync)]
    pub fn identity_key(&self) -> String {
        self.account.curve25519_key().to_base64()
    }

    #[frb(sync)]
    pub fn signing_key(&self) -> String {
        self.account.ed25519_key().to_base64()
    }

    #[frb(sync)]
    pub fn sign(&self, message: String) -> String {
        self.account.sign(message.as_bytes()).to_base64()
    }

    /// Makes sure `count` (at most 50) one-time keys are waiting to be published, generating only the
    /// shortfall, and returns every unpublished one-time key. Keys left by an upload that failed are
    /// therefore reused, never added to: the unpublished set stays as small as the biggest `count` asked
    /// for, so a retry can never exceed the 50 keys the relay takes per request. `count: 0` makes none.
    #[frb(sync)]
    pub fn generate_one_time_keys(&mut self, count: u32) -> Vec<PublicKeyEntry> {
        let wanted = count.min(50) as usize;
        let pending = self.account.one_time_keys().len();
        if wanted > pending {
            self.account.generate_one_time_keys(wanted - pending);
        }
        let mut keys: Vec<PublicKeyEntry> = self
            .account
            .one_time_keys()
            .into_iter()
            .map(|(id, key)| PublicKeyEntry { key_id: id.to_base64(), public_key: key.to_base64() })
            .collect();
        keys.sort_by(|a, b| a.key_id.cmp(&b.key_id));
        keys
    }

    /// Rotates the fallback key and returns the unpublished one.
    #[frb(sync)]
    pub fn generate_fallback_key(&mut self) -> Option<PublicKeyEntry> {
        self.account.generate_fallback_key();
        self.account
            .fallback_key()
            .into_iter()
            .next()
            .map(|(id, key)| PublicKeyEntry { key_id: id.to_base64(), public_key: key.to_base64() })
    }

    /// The fallback key that was generated but not yet marked as published, if any.
    #[frb(sync)]
    pub fn unpublished_fallback_key(&self) -> Option<PublicKeyEntry> {
        self.account
            .fallback_key()
            .into_iter()
            .next()
            .map(|(id, key)| PublicKeyEntry { key_id: id.to_base64(), public_key: key.to_base64() })
    }

    /// Forgets the previous fallback key (the one the last [`generate_fallback_key`]
    /// replaced); true if there was one. Call it once enough time has passed that no
    /// pre-key message made for the old key can still be in flight. The account must
    /// be pickled afterwards.
    #[frb(sync)]
    pub fn forget_old_fallback_key(&mut self) -> bool {
        self.account.forget_fallback_key()
    }

    #[frb(sync)]
    pub fn mark_keys_as_published(&mut self) {
        self.account.mark_keys_as_published();
    }

    #[frb(sync)]
    pub fn create_outbound(&self, identity_key: String, one_time_key: String) -> Result<OlmSession, String> {
        let session = self
            .account
            .create_outbound_session(CONFIG(), curve_key(&identity_key)?, curve_key(&one_time_key)?)
            .map_err(|e| format!("could not start session: {e}"))?;
        Ok(OlmSession { session })
    }

    /// Starts a session from a received pre-key message and returns its plaintext.
    /// The account must be pickled afterwards: the used one-time key is consumed.
    #[frb(sync)]
    pub fn create_inbound(&mut self, their_identity_key: String, ciphertext: String) -> Result<(OlmSession, String), String> {
        let identity = curve_key(&their_identity_key)?;
        let message = PreKeyMessage::from_bytes(&base64_decode(&ciphertext).map_err(|_| "invalid ciphertext".to_string())?)
            .map_err(|_| "invalid pre-key message".to_string())?;
        if !is_contributory(&message.base_key()) {
            return Err("rejected a non-contributory (low-order) key".into());
        }
        let result =
            self.account.create_inbound_session(CONFIG(), identity, &message).map_err(|e| format!("could not accept session: {e}"))?;
        let plaintext = String::from_utf8(result.plaintext).map_err(|_| "plaintext is not UTF-8".to_string())?;
        Ok((OlmSession { session: result.session }, plaintext))
    }
}

/// A Double Ratchet session with one peer device.
#[frb(opaque)]
pub struct OlmSession {
    session: Session,
}

impl OlmSession {
    #[frb(sync)]
    pub fn restore(pickle: String, pickle_key: Vec<u8>) -> Result<OlmSession, String> {
        let key = self::pickle_key(pickle_key)?;
        let pickle = vodozemac::olm::SessionPickle::from_encrypted(&pickle, &key).map_err(|_| "could not unlock session".to_string())?;
        Ok(OlmSession { session: Session::from_pickle(pickle) })
    }

    #[frb(sync)]
    pub fn pickle(&self, pickle_key: Vec<u8>) -> Result<String, String> {
        Ok(self.session.pickle().encrypt(&*self::pickle_key(pickle_key)?))
    }

    #[frb(sync)]
    pub fn session_id(&self) -> String {
        self.session.session_id()
    }

    #[frb(sync)]
    pub fn encrypt(&mut self, plaintext: String) -> Result<EncryptedMessage, String> {
        let message = self.session.encrypt(plaintext.as_bytes()).map_err(|e| format!("could not encrypt: {e}"))?;
        let (message_type, bytes) = message.to_parts();
        Ok(EncryptedMessage { message_type: message_type as u8, ciphertext: base64_encode(bytes) })
    }

    #[frb(sync)]
    pub fn decrypt(&mut self, message_type: u8, ciphertext: String) -> Result<String, String> {
        let bytes = base64_decode(&ciphertext).map_err(|_| "invalid ciphertext".to_string())?;
        let message = OlmMessage::from_parts(message_type as usize, &bytes).map_err(|_| "invalid message".to_string())?;
        let plaintext = self.session.decrypt(&message).map_err(|e| format!("could not decrypt: {e}"))?;
        String::from_utf8(plaintext).map_err(|_| "plaintext is not UTF-8".to_string())
    }

    /// Whether a received pre-key message belongs to this existing session.
    #[frb(sync)]
    pub fn matches_pre_key(&self, ciphertext: String) -> bool {
        base64_decode(&ciphertext)
            .ok()
            .and_then(|bytes| PreKeyMessage::from_bytes(&bytes).ok())
            .is_some_and(|message| message.session_id() == self.session.session_id())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: [u8; 32] = [7; 32];

    fn pair() -> (OlmAccount, OlmAccount, OlmSession) {
        let alice = OlmAccount::create();
        let mut bob = OlmAccount::create();
        let otk = bob.generate_one_time_keys(1).remove(0);
        bob.mark_keys_as_published();
        let outbound = alice.create_outbound(bob.identity_key(), otk.public_key).unwrap();
        (alice, bob, outbound)
    }

    #[test]
    fn round_trip_and_ratchet() {
        let (alice, mut bob, mut to_bob) = pair();
        let first = to_bob.encrypt("hello niko".into()).unwrap();
        assert_eq!(first.message_type, 0);
        assert!(!first.ciphertext.contains("hello"));
        let (mut to_alice, plaintext) = bob.create_inbound(alice.identity_key(), first.ciphertext.clone()).unwrap();
        assert_eq!(plaintext, "hello niko");
        assert!(to_alice.matches_pre_key(first.ciphertext.clone()));
        // The one-time key is consumed: replaying the pre-key message fails.
        assert!(bob.create_inbound(alice.identity_key(), first.ciphertext).is_err());
        let reply = to_alice.encrypt("hi anjali".into()).unwrap();
        assert_eq!(reply.message_type, 1);
        assert_eq!(to_bob.decrypt(reply.message_type, reply.ciphertext.clone()).unwrap(), "hi anjali");
        // Each message key is used once.
        assert!(to_bob.decrypt(reply.message_type, reply.ciphertext).is_err());
        let next = to_bob.encrypt("ratcheted".into()).unwrap();
        assert_eq!(next.message_type, 1);
        assert_eq!(to_alice.decrypt(1, next.ciphertext).unwrap(), "ratcheted");
    }

    #[test]
    fn tampering_and_wrong_keys_fail_closed() {
        let (alice, mut bob, mut to_bob) = pair();
        let message = to_bob.encrypt("secret".into()).unwrap();
        let mut bytes = base64_decode(&message.ciphertext).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        assert!(bob.create_inbound(alice.identity_key(), base64_encode(&bytes)).is_err());
        let stranger = OlmAccount::create();
        assert!(bob.create_inbound(stranger.identity_key(), message.ciphertext).is_err());
    }

    #[test]
    fn low_order_keys_are_rejected() {
        let alice = OlmAccount::create();
        let zero = base64_encode([0u8; 32]);
        let mut one = [0u8; 32];
        one[0] = 1;
        assert!(!is_contributory_key(zero.clone()));
        assert!(!is_contributory_key(base64_encode(one)));
        assert!(is_contributory_key(alice.identity_key()));
        assert!(alice.create_outbound(zero.clone(), alice.identity_key()).is_err());
        assert!(alice.create_outbound(alice.identity_key(), zero).is_err());
    }

    #[test]
    fn pickles_need_the_right_key() {
        let (alice, _, mut session) = pair();
        let pickle = alice.pickle(KEY.to_vec()).unwrap();
        assert!(!pickle.contains(&alice.identity_key()));
        let restored = OlmAccount::restore(pickle.clone(), KEY.to_vec()).unwrap();
        assert_eq!(restored.identity_key(), alice.identity_key());
        assert!(OlmAccount::restore(pickle, [8; 32].to_vec()).is_err());
        assert!(alice.pickle(vec![1; 16]).is_err());
        let saved = session.pickle(KEY.to_vec()).unwrap();
        let mut copy = OlmSession::restore(saved, KEY.to_vec()).unwrap();
        assert_eq!(copy.session_id(), session.session_id());
        let _ = session.encrypt("x".into()).unwrap();
        let _ = copy.encrypt("y".into()).unwrap();
    }

    #[test]
    fn signatures_are_strict() {
        let alice = OlmAccount::create();
        let statement = "hiyall-device-v1\nuser\ndevice\nkey\nsigner".to_string();
        let signature = alice.sign(statement.clone());
        assert!(verify_signature(alice.signing_key(), statement.clone(), signature.clone()));
        assert!(!verify_signature(alice.signing_key(), statement + "x", signature.clone()));
        assert!(!verify_signature(OlmAccount::create().signing_key(), "hiyall".into(), signature));
    }

    #[test]
    fn one_time_keys_are_unique_and_published_once() {
        let mut bob = OlmAccount::create();
        let keys = bob.generate_one_time_keys(5);
        assert_eq!(keys.len(), 5);
        let mut ids: Vec<_> = keys.iter().map(|k| k.key_id.clone()).collect();
        ids.dedup();
        assert_eq!(ids.len(), 5);
        bob.mark_keys_as_published();
        assert_eq!(bob.generate_one_time_keys(0).len(), 0);
        assert!(bob.generate_fallback_key().is_some());
    }

    /// Re-audit CHAT-1: the unpublished one-time keys stay bounded however many times keys are asked for
    /// without publishing (an upload that keeps failing), so a retry never has more than the relay's
    /// 50 per request. Before this, every call added `count` more and the pending set grew without bound.
    #[test]
    fn unpublished_one_time_keys_stay_bounded() {
        let mut account = OlmAccount::create();
        for _ in 0..8 {
            assert_eq!(account.generate_one_time_keys(40).len(), 40);
        }
        // Asking for more raises the set to that many, to at most 50, never beyond.
        assert_eq!(account.generate_one_time_keys(500).len(), 50);
        assert_eq!(account.generate_one_time_keys(500).len(), 50);
        // Fewer asked for than are waiting: all waiting ones come back (the caller takes what it needs).
        let waiting = account.generate_one_time_keys(0);
        assert_eq!(waiting.len(), 50);
        // The same keys on every call, so a retry offers exactly what the failed attempt offered.
        let ids = |keys: &[PublicKeyEntry]| keys.iter().map(|k| k.key_id.clone()).collect::<Vec<_>>();
        assert_eq!(ids(&waiting), ids(&account.generate_one_time_keys(50)));
        // Publishing empties the set; the next request makes exactly what it asks for.
        account.mark_keys_as_published();
        assert!(account.generate_one_time_keys(0).is_empty());
        assert_eq!(account.generate_one_time_keys(7).len(), 7);
        assert_eq!(account.generate_one_time_keys(7).len(), 7);
    }

    #[test]
    fn forgotten_fallback_key_cannot_start_a_session() {
        let alice = OlmAccount::create();
        let mut bob = OlmAccount::create();
        let old = bob.generate_fallback_key().unwrap();
        bob.mark_keys_as_published();
        // Nothing older to forget yet.
        assert!(!bob.forget_old_fallback_key());
        let new = bob.generate_fallback_key().unwrap();
        assert_ne!(old.key_id, new.key_id);
        assert_eq!(bob.unpublished_fallback_key().unwrap().key_id, new.key_id);
        bob.mark_keys_as_published();
        assert!(bob.unpublished_fallback_key().is_none());
        // Both fallback keys still work during the grace period.
        let mut to_old = alice.create_outbound(bob.identity_key(), old.public_key.clone()).unwrap();
        let first = to_old.encrypt("late".into()).unwrap();
        let pickled = bob.pickle(KEY.to_vec()).unwrap();
        assert!(bob.create_inbound(alice.identity_key(), first.ciphertext.clone()).is_ok());
        // After the grace period the old one is forgotten: the same kind of message fails.
        let mut bob = OlmAccount::restore(pickled, KEY.to_vec()).unwrap();
        assert!(bob.forget_old_fallback_key());
        assert!(bob.create_inbound(alice.identity_key(), first.ciphertext).is_err());
        let mut to_new = alice.create_outbound(bob.identity_key(), new.public_key).unwrap();
        let ok = to_new.encrypt("fresh".into()).unwrap();
        assert!(bob.create_inbound(alice.identity_key(), ok.ciphertext).is_ok());
        // Forgetting is idempotent.
        assert!(!bob.forget_old_fallback_key());
    }
}
