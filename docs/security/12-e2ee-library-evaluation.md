# E2EE library evaluation for direct chat

**Status:** evaluation and recommendation, 8 October 2026. No chat code exists yet. This applies the requirement in [encryption and interception protections](11-encryption-and-interception.md): use a maintained, independently reviewed, established protocol library for 1:1 chat; no custom cryptography.

## Constraints from this project

- Flutter on Android and iOS first, web later. The app is proprietary (`LicenseRef-Proprietary` in the API contract).
- 1:1 chat at MVP; groups later. Users will have more than one device.
- The server relays and stores only ciphertext device envelopes, already reflected in the MVP contract.
- Keys must sit in platform-protected storage (Android Keystore / iOS Keychain wrapping).

## Candidates

| | libsignal (Signal) | vodozemac (Matrix) | OpenMLS | mls-rs (AWS Labs) |
|---|---|---|---|---|
| Protocol | Signal protocol (X3DH/PQXDH + Double Ratchet) | Olm (3DH + Double Ratchet) for 1:1/device sessions; Megolm for groups | MLS, RFC 9420 | MLS, RFC 9420 |
| Core language | Rust | Rust | Rust | Rust |
| Licence (core) | **AGPL-3.0** | Apache-2.0 | MIT | Apache-2.0 or MIT |
| Independent audit | Not stated for the library in its repo | **Yes**: Least Authority, final report 30 March 2022, co-funded by gematik | No published library audit found | README: conformance-validated, **not yet** fully third-party audited |
| Third-party use | "Use outside of Signal is unsupported"; APIs may change without notice | Default E2EE in matrix-rust-sdk; built for third-party use | Built for third-party use (Phoenix R&D, Cryspen) | Vendored in Firefox and AOSP sources |
| Flutter binding | `libsignal` on pub.dev (7.4.1): unverified uploader, AGPL-3.0, downloads prebuilt binaries at build time | `flutter_vodozemac` (0.8.1): verified publisher famedly.com, **AGPL-3.0**, no web listed | `openmls` on pub.dev (3.2.1): unverified uploader, MIT, web via dart2js | None found; would need own bindings |
| Web | No official browser build; the Dart wrapper ships wasm32 for dart2js only | Rust compiles to WASM; the Flutter binding doesn't list web | Dart wrapper supports web (dart2js, not `--wasm`) | Would need own WASM build |
| Recent issues | — | Feb 2026 public report; Matrix confirmed one defence-in-depth gap (all-zero X25519 output not rejected in Olm 3DH), fix promised in a future release; other claims disputed | Dart wrapper warns: experimental post-quantum suites, libcrux not fully audited | — |

## Assessment

**libsignal: not recommended.** It's the reference Signal implementation, but AGPL-3.0 on the client would require releasing the app's source under AGPL. Signal explicitly doesn't support third-party use, and its APIs change without notice. The only Flutter wrapper is from an unverified uploader and fetches prebuilt binaries during builds, which is a supply-chain risk for an E2EE core.

**OpenMLS / mls-rs: strong for groups and multi-device later, not yet for MVP.** MLS models every device as a group member, which handles multi-device and future group chat in one protocol, and both licences are permissive. But neither library has a published independent audit of the library itself, which the project requirement asks for. mls-rs has no Flutter binding at all. Revisit when an audit is published.

**vodozemac: recommended for the 1:1 MVP.** It's a Signal-family Double Ratchet, which matches the requirement's wording. It's Apache-2.0, independently audited, and production-proven as the default E2EE in matrix-rust-sdk, with an open security process. Megolm is available later for groups, and Olm's per-device sessions cover multi-device.

Caveats to accept explicitly:
- **Don't use `flutter_vodozemac`.** It's AGPL-3.0. Write a thin binding to the Apache-2.0 crate with `flutter_rust_bridge` (MIT/Apache) instead, exposing only Account, Session, and pickle/unpickle.
- **Audit age.** The audit is from 2022. Pin the version, track releases, and get a focused review of the integration (key storage, device lists, envelope handling) before launch.
- **Feb 2026 finding.** Use a release that rejects all-zero X25519 outputs. Until one exists, add that check in the binding.
- **Device verification.** Olm sessions trust the server's device-key directory unless users verify devices. The app needs signed device keys, a "new device" notice, and optional safety-number comparison.
- **Web.** Defer web chat. Browsers lack Keystore-grade key protection. When added, use a WASM build of the same crate, with keys wrapped by a non-extractable WebCrypto key in IndexedDB, and say clearly in the product that the web is weaker.

## Next step: integration proof

Build these before any chat UI:

1. A Rust crate `kairova_e2ee` wrapping vodozemac 0.11.x behind a minimal API, exposed to Dart with `flutter_rust_bridge`. Includes the all-zero shared-secret check and vodozemac's own test vectors in CI.
2. Pickled account and session state encrypted with a key held by Android Keystore / iOS Keychain (`flutter_secure_storage`).
3. API endpoints: upload device identity and signed one-time/fallback keys, claim a one-time key, list a user's devices, and send/fetch ciphertext envelopes addressed per device. The Go server never handles plaintext.
4. A two-device test on Android and iOS emulators. Then intercept the traffic and inspect the database to confirm no plaintext appears, the measured acceptance statements from the security requirement.
5. Licence review of the full dependency tree (Rust crates included) before shipping.

## Decisions needed

- Accept vodozemac, with your own bindings, for the 1:1 MVP.
- Accept Android and iOS first, with web chat deferred.
- Confirm the app remains proprietary. That's what rules out the AGPL options.

## Sources

- libsignal repository, licence and third-party use: https://github.com/signalapp/libsignal
- libsignal Dart wrapper: https://pub.dev/packages/libsignal
- vodozemac repository and audit link: https://github.com/matrix-org/vodozemac
- Audit announcement (May 2022): https://matrix.org/blog/2022/05/16/independent-public-audit-of-vodozemac-a-native-rust-reference-implementation-of-matrix-end-to-end-encryption/
- Least Authority report: https://leastauthority.com/static/publications/LeastAuthority-Matrix_vodozemac_Final_Audit_Report.pdf
- Feb 2026 analysis: https://matrix.org/blog/2026/02/analysis-of-reported-issues-in-vodozemac/
- flutter_vodozemac: https://pub.dev/packages/flutter_vodozemac
- OpenMLS Dart wrapper: https://pub.dev/packages/openmls
- mls-rs: https://docs.rs/crate/mls-rs/0.56.0
