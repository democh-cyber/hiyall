# Encryption and interception resistance

**Status:** mandatory security requirement added on 7 October 2026; design only. This supersedes the earlier server-visible direct-chat default. The profile/privacy foundation now exists; chat encryption and certificate pinning are not implemented. See [the development record](../development.md). The library evaluation and recommendation are in [E2EE library evaluation](12-e2ee-library-evaluation.md). The first implementation and its verification are recorded in [encrypted chat implementation](13-encrypted-chat-implementation.md).

## Requirement and honest boundary

Protect private chat content against network interception, proxy inspection and server/operator disclosure. Release builds must reject ordinary unauthorized interception certificates and never deliberately send plaintext private messages or attachment keys to the API. Require end-to-end encryption (E2EE) for direct chats and their attachments before the messaging MVP launches.

“No software can inspect any request or response” is not an achievable security property. A user controlling a device can modify the app or instrument it before encryption/after decryption. Recipients can capture, copy or report content they are authorized to see. TLS termination sees application requests; E2EE limits which content those requests contain. Endpoint routing, device identifiers, sizes, timing and delivery metadata are not automatically hidden by E2EE. Certificate pinning raises interception difficulty but can be bypassed on an instrumented device. [OWASP pinning bypass testing](https://mas.owasp.org/MASTG/techniques/android/MASTG-TECH-0012/).

Acceptance must use measured statements: “stock signed release rejected our proxy certificate” and “intercepted application traffic contained no private-message plaintext.” Never market the application as unhackable, fully secure or impossible to inspect.

## Encryption scope

| Surface | Protection / server visibility | Product effect |
|---|---|---|
| 1:1 message text, reply context, reactions, edits | E2EE device envelopes; server stores/delivers ciphertext | No plaintext message bodies in HTTP/socket payloads, logs, queues or search |
| Chat attachment bytes, thumbnail, filename, caption, decryption key | Encrypt on sender device before direct storage upload; key/descriptor delivered inside E2EE message | Storage/CDN gets ciphertext; server cannot transcode, virus-scan or moderate encrypted content |
| Authentication, profile, public posts/stories, graph, reports | TLS + source encryption at rest + strict authorization; server needs these fields to operate features | These are not represented as E2EE; private audience settings are access control, not a claim of server blindness |
| Sender/recipient device IDs, conversation ID, sequence, timestamps, encrypted byte count | TLS, minimized retention and access; necessary relay metadata remains server-visible | No anonymous or traffic-analysis-proof claim |
| Local chat database, drafts, session/identity keys | Encrypted storage and platform-protected key wrapping, no plaintext backup/logging | An unlocked/compromised endpoint remains outside the confidentiality guarantee |
| Push notification | Resource-only wake-up; no content/keys/previews on server | Recipient app decrypts locally; OS-visible previews off by default |
| Public/community content moderation | Server-side scanning and human review | Distinct from encrypted-message safety workflow |
| Reported private content | Reporting participant explicitly chooses selected decrypted evidence to share with safety staff | Clear disclosure and case scope; no global chat backdoor |

For future friends-only posts/stories to be server-blind, design audience key distribution, membership changes, archives and private search separately. Do not silently label all private-audience social data E2EE. The current mandatory E2EE scope is direct chat and chat media, while all other network operations require secure transport.

## Protocol, devices and key lifecycle

1. Integrate a maintained, independently reviewed established messaging protocol/library rather than custom encryption, a shared embedded AES key, or homemade RSA request wrapping. Evaluate a Signal-family implementation for 1:1 sessions with current key-agreement/ratchet and multi-device specifications. Exact suite/library version, license, native Flutter integration and test vectors must be frozen after an integration proof. Specifications are not a substitute for a maintained library. [Signal Double Ratchet specification](https://signal.org/docs/specifications/doubleratchet/).
2. Generate identity/session keys on the device using a cryptographically secure random source; wrap stored keys with device platform facilities. Do not assume every protocol key/curve can directly live in hardware-backed Keystore/Secure Enclave; use a reviewed wrapping design. No server-held private decryption keys, master recovery key or hardcoded mobile secret.
3. Bind identity keys, verified account identity, current device directory and prekeys through the chosen protocol. First-contact authenticity needs explicit trust handling; show verification codes/QR and changed-device warnings. Design signed directory versions and key transparency before claiming protection against a malicious key-directory operator. A valid TLS channel alone does not authenticate the peer's E2EE key.
4. Multi-device operation is explicit: encrypt for current recipient devices and the sender's approved linked devices, cap device fanout, rotate/revoke keys on device removal, and warn about new devices. Adding a device requires authenticated approval from an existing trusted device or a documented reset flow. An ordinary password reset cannot silently recreate E2EE identity/history access.
5. Persist outbound ciphertext and advanced ratchet state atomically with the local mutation outbox. Retry the exact original ciphertext/client ID rather than encrypting a new envelope each time. Persist successful receive/decrypt state and event cursor atomically; test duplicate, out-of-order, skipped-key, process-death and disk-full handling using the library's supported limits.
6. Encrypt attachments with an approved authenticated streaming/file construction from a reviewed library, unique random content keys and authenticated context. The descriptor/key/hash is inside the E2EE message. Never upload plaintext first and encrypt it later on the server; thumbnails and temporary files need the same private-content boundary.
7. Default backups contain no recoverable chat history outside device-controlled encryption. Cross-device history transfer requires authenticated encrypted transfer. Optional cloud backups need user-held high-entropy recovery material and reviewed cryptographic design; losing keys can mean losing history. Support/administrators cannot promise recovery through a universal secret.
8. Group/call E2EE requires separate design; assess MLS or an established group protocol for membership/key changes and insertable-frame/media encryption for SFU calls. WebRTC transport encryption alone is not a blanket guarantee that a media service cannot decrypt. Do not claim group/call E2EE until those contracts exist.

This protocol evaluation is a prerequisite for chat code, not a request to invent cryptography during repository setup. Foundation work can build identity/profile/privacy and non-content relay contracts after overall architecture approval; the encrypted-chat routes remain review contracts until suite-specific proof is complete.

## Transport and release build controls

- HTTPS/WSS only; TLS 1.3 preferred with reviewed TLS 1.2 fallback where compatibility requires. Enforce hostname/chain validation, no trust-all callback and no downgrade after validation failure. Deny cleartext for API, media and socket routes.
- First-party API/socket connections use reviewed public-key pinning with an active and independent backup pin, normal PKI checks, certificate renewal drills and a safe app-update recovery path. Treat this as an added product-specific control with maintenance cost; Android guidance cautions that pinning can cause outages during certificate changes. Never recover by accepting any certificate. [Android network security guidance](https://developer.android.com/privacy-and-security/security-ssl).
- Enforce network policies in the actual Flutter/native HTTP, WebSocket, media, background upload and SDK stacks. An Android XML file or iOS ATS setting does not prove every plugin/custom socket follows it. Test all paths; prefer native-backed adapters whose trust behavior can be verified. iOS uses ATS without broad release exceptions. [Apple secure networking](https://developer.apple.com/documentation/security/preventing-insecure-network-connections).
- Do not trust user-installed/debug proxy roots in release first-party networking. Development proxy CAs/relaxed endpoints are restricted to separate debug builds and staging data; cannot enter signed release artifacts. Android provides debug-only trust configuration. [Android network configuration](https://developer.android.com/privacy-and-security/security-config).
- Pin only controlled endpoints with an agreed rotation lifecycle. Third-party identity/system-browser/provider traffic has its own trust boundary; do not embed their private keys or pretend a first-party pin covers every provider/CDN host. Private chat media remains ciphertext even if its storage transport terminates elsewhere.
- Strip debug network inspectors, sensitive interceptor logging and production developer menus. Exclude secrets, plaintext content and complete signed URLs from logs/crash/analytics; protect build signing and obfuscate where useful. Obfuscation is not encryption.
- Add server-verified device-integrity/attestation signals and anti-replay/action binding where appropriate, with accessibility/legitimate-device recovery. Root/jailbreak/debug detection is only a risk signal; bypasses exist and detection does not establish content confidentiality.

## API and data implications

The typed MVP message request/response contract now uses ciphertext device envelopes rather than plaintext `body`. A message request before acceptance contains no private introduction. Chat reactions/edits use encrypted control payloads; clear reaction type/text must not appear in transport. Member authorization, ownership for edits/removal, monotonic receipts, retry deduplication and resource versions still apply to relay metadata.

The server may validate envelope sizes, recipient device eligibility, current membership, byte quotas, schema/protocol allow-list and dedupe identity, but cannot validate the decrypted body. Clients validate decrypted content types, targets and authorship using the reviewed protocol. They reject malformed data safely; plaintext recovery/downgrade is forbidden. The server's outbox/index never stores private-content keys or rendered message text.

Private media assets use an encrypted format, uploaded MIME `application/octet-stream`, ciphertext checksum/size and `encrypted_uploaded` state. No `scan-ready` state implies decrypted validation. Client compression/transcoding occurs before encryption; opening attachments requires local secure decoding and supported-file checks. Reports explicitly share selected evidence through a separate authorized pipeline; server-visible public media retains scan/transcode/quarantine controls.

Translation, summaries and writing assistance run on-device where feasible. Sending decrypted text to an external AI requires an explicit preview and consent; that copy leaves the chat's E2EE boundary. Automatic server-side message moderation/search/translation and raw private-content analytics are prohibited. Abuse prevention uses minimal metadata, request limits, blocks and user-selected reports instead.

Exports from servers contain ciphertext and operational records only. A readable chat export is an explicitly requested local operation with warnings about the resulting file and OS sharing. Server backups contain ciphertext; device-controlled plaintext exports are not silently uploaded.

## Required verification before encrypted messaging launch

| Test | Pass condition |
|---|---|
| Stock Android/iOS release + Reqable/Charles/mitmproxy/Burp using unauthorized installed CA | Every first-party API/socket path rejects interception; media/provider exceptions documented and private chat content remains ciphertext |
| Invalid hostname/expired certificate/untrusted chain | Connection fails; no silent insecure retry |
| Certificate/key rotation, backup pin and old supported app | Planned rotation works; obsolete trust recovers through verified update, never trust-all |
| Controlled successful TLS capture in a dedicated test build | Message text, attachment key/filename, reactions and edit text absent from captured transport/logs |
| Server/object storage/queue/backup inspection | No private-message plaintext or decryption keys; only approved minimal metadata/ciphertext |
| Library vectors and protocol interoperability | Expected authenticated decrypt; tampering/replay/identity changes handled correctly; independent review |
| Offline retries/reinstall/device removal/key change | No duplicate effects, no wrong-device delivery/history recovery, no ratchet-state reuse |
| Instrumented/rooted/jailbroken test devices | Bypass/visibility limits recorded honestly; attestation/risk response checked, not claimed impossible |
| Report/AI/export flows | Exact user-selected disclosure is visible, consent recorded, no automatic private-content exfiltration |
| Release artifact scan and physical-device storage tests | No debug CA/trust bypass/hardcoded secret/plaintext backup or sensitive network logger |

The encryption/proxy-specific tests listed here have not run. Foundation authentication, authorization and privacy tests are recorded in `docs/development.md`. A successful proxy rejection test does not prove endpoint compromise resistance. Independent mobile penetration testing and cryptographic integration review are launch requirements.
