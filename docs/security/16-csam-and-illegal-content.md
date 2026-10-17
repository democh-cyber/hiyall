# Runbook: child sexual abuse material and other illegal content

**Status:** implemented 14 October 2026 (scanner, quarantine, console cases, audit) in `services/api/internal/media/scan.go`, `internal/store/mediascan.go`, `internal/admin/content.go`, migration `0036_moderation.sql` and `apps/admin`. **Not rehearsed, not reviewed by counsel.** Everything that names a law, a deadline or an authority below is a prompt for the owner's lawyer, marked **[counsel]**. This page is operational guidance for a small team, not legal advice.

Hiyall has members from age 13 and open Discover: public profiles, public posts and stories, and strangers can start chats. A product like that will be used to share illegal imagery of children. This page says what the system does about it, what a person on the team does, and what nobody may ever do.

## 1. What is and is not covered

| Surface | Detected how | Notes |
|---|---|---|
| Avatars, post photos, story photos (not end-to-end encrypted) | **Upload scanner** (section 2) at `POST /v1/media/{id}/complete`, before the photo can be attached or shown | Real coverage for known material (hash list or provider). Nothing for new material. |
| The same photos once served from the CDN | **Cloudflare CSAM Scanning Tool** on the zone (section 3), an owner setup step | A second, independent layer. Not configured by this repository. |
| Text of posts, comments, stories, spaces | Member reports, then the console's content preview (section 5) | No automated text scanning. |
| Chat photos and messages (end-to-end encrypted) | **Cannot be scanned.** The server only holds ciphertext | Only what the reporter chooses to share. See [encrypted chat attachments](14-encrypted-chat-attachments.md) and [reports](../api/14-safety-controls.md#reports). Do not weaken E2EE to scan: that changes the product's promise and the threat model of every member. |
| Video | Not accepted today | Needs transcoding and its own scanning before it is. |

Be honest with yourselves about the limit: **hash matching finds known images only.** A new image is found by a member report, by the Cloudflare tool if it is in its database, or not at all.

## 2. The upload scanner

Every photo upload is decoded and re-encoded (metadata, including GPS, is dropped). Then, before anything is stored under the display prefix, `Scanner.Scan` gets the exact uploaded bytes and the re-encoded JPEG and answers:

| Verdict | Meaning | What happens |
|---|---|---|
| `clean` | nothing found | the photo becomes ready as before |
| `flagged` | possible, not certain: **any perceptual-hash hit, however close**, or a provider's `flagged` | quarantined; the uploader is **not** suspended; a case opens |
| `match` | a **strong** match only: the SHA-256 of the exact file is on the list, or the provider says `match` | quarantined; the uploader is **suspended** and every session ends; a case opens |
| scan error | the scanner could not answer | `503 SCAN_UNAVAILABLE`; the upload stays pending and unseen (fail closed); the app can retry |

The member gets `422 UPLOAD_REJECTED` ("That photo can't be used") for both flagged and match, and nothing about why. The scanner never sends an image, hash or verdict anywhere on its own.

Configuration (all in the API environment, see `infrastructure/docker/api.example.env`):

| Variable | Meaning |
|---|---|
| `SCAN_HASHLIST_FILE` | Path to the operator's hash list: one entry per line, `sha256:<64 hex>` or `phash:<16 hex>` (a bare 64 or 16 digit hex string works too), `#` comments, an optional label after a space that is stored with a match. SHA-256 is compared with both the uploaded bytes and the re-encoded copy. `phash` is a 64-bit difference hash: Hamming distance up to 8 is `flagged`, **never `match`**: a 64-bit fingerprint can come close to unrelated photos, and suspending a member on it would punish the innocent (audit SAFE-1). Only an exact SHA-256 hit suspends. Perceptual entries need entropy: a hash with fewer than 12 or more than 52 bits set (all zero or all one is what a flat image produces and would flag half the internet) is **rejected at load**, counted, and logged as a warning (`perceptual entries rejected for too little entropy`). The file is re-read when it changes, so a list update needs no restart; a broken update keeps the old list. **Never commit a list.** Treat it as restricted data. |
| `SCAN_PROVIDER_URL`, `SCAN_PROVIDER_KEY_FILE` | A hosted scanning service (PhotoDNA-style). The adapter in `media/scan.go` is a **skeleton**: it POSTs the JPEG as `application/octet-stream` with `Authorization: Bearer <key>` and expects `{"verdict":"clean\|flagged\|match","reference":"..."}`. Real services have their own onboarding (**[counsel]**: PhotoDNA is by application to Microsoft and has terms about what you may do with matches) and request formats: put the translation in `HTTPProvider.Scan`. https only in production. |
| `EVIDENCE_BUCKET`, `EVIDENCE_ENDPOINT`, `EVIDENCE_ACCESS_KEY`, `EVIDENCE_SECRET_KEY`, `EVIDENCE_ALLOW_SHARED_BUCKET`, `EVIDENCE_RETENTION_DAYS` | The evidence bucket and the hold length (section 4). |
| `SCAN_ALLOW_NONE` | **Production refuses to start with photo uploads on and no scanner.** `SCAN_ALLOW_NONE=true` overrides that and logs a loud error at every start. Do not use it for real users. |

Both can be set; the strictest verdict wins. Development uses `none` and logs that it does.

Where to get a hash list is an **owner onboarding task**: NCMEC offers hash sharing to eligible providers, and industry bodies and vendors offer others. None is configured here. The perceptual hash in this repository is not PhotoDNA and does not replace a vendor list: it exists so a list you obtain can be matched at all.

## 3. Cloudflare CSAM Scanning Tool (owner setup)

Cloudflare's CSAM Scanning Tool works at the **zone** level: it scans cacheable content served through a Cloudflare-proxied hostname and notifies you on a match. It does not run inside this repository, and it does not see objects fetched directly from R2's S3 API. To use it:

1. Serve photos through a Cloudflare-proxied custom domain for the R2 bucket (for example `media.<your-domain>`) rather than only signed R2 URLs, or confirm with Cloudflare what the tool covers for your setup.
2. In the Cloudflare dashboard for that zone, enable the CSAM Scanning Tool (Caching, Configuration) and register the contact address that receives notifications. Use a shared mailbox read by at least two people, not one person's address.
3. Read Cloudflare's terms for what they report themselves and what remains your duty. **[counsel]** Do not assume Cloudflare's notice discharges your own reporting obligation.
4. Add the mailbox to the on-call list in section 7, and run a test of the notification path with Cloudflare's documented method.

The chat bucket (`hiyall-chat`) only holds ciphertext, so the tool has nothing meaningful to scan there; do not put it behind the tool.

## 4. Quarantine

On `flagged` or `match`, in this order (round-3 audit API-6/7: **the case first, the evidence objects second**, so an object in the bucket never exists without a case that names it). Step 1 is one database transaction (`Store.BeginQuarantine`):

* the photo row becomes `quarantined`: never ready, never attachable to a post, story or profile, excluded from every read path, never touched by the media cleanup;
* a **content case** (`content_cases`) is opened: uploader, purpose, scanner and its signals (a list label, a provider reference, a hash distance), **SHA-256 and size of the exact upload**, the object keys, the detection time, `hold_until` (`EVIDENCE_RETENTION_DAYS`, default 365 days) and `legal_hold`;
* on `match`, the uploader is suspended (a `moderation_actions` row with actor `system:upload-scanner`) and all their sessions and sockets end.

The case is written with status **`pending`**. Step 2: the API copies the exact upload and the re-encoded copy to `hold/<media id>/original` and `hold/<media id>/full.jpg` in the **evidence bucket** (`EVIDENCE_BUCKET`; section 9). Step 3: `activate_quarantine_case` opens the case (`open`) and the API removes the upload from `uploads/` in the media bucket. Nothing under `hold/` is ever signed for a member. Nothing is deleted.

**Pending cases and orphans (the console's hourly sweep).** If step 2 fails or the process dies, the case stays `pending` (it blocks a hold release like an open case, and a match's suspension has already happened). The API cannot read the evidence bucket; the console can, so its sweep (`admin serve`, hourly, also needs only `ADMIN_EVIDENCE_*`) takes every pending case older than an hour: **both objects present → the case is opened** (`pending_case_activated`); **an object missing in a FLAGGED case → the case is dropped** (`drop_pending_case`, audited as `pending_case_dropped`, the upload marked `deleted`) and the member's next upload starts afresh. **A case made for a scanner MATCH is never dropped** (round-4 N-7), by the sweep or by the database function: the record may be the only trace of a match, so it stays pending, is reported loudly in the log on every run and once in the audit log (`pending_match_case_stuck`), and an operator decides (the case lists where the original sits in the upload prefix, `signals.uploadKey`). **Before any of this the sweep proves it reads the bucket the API writes to** (`EvidenceProbe`): the bucket answers a listing, and the object `evidence-bucket-id` that the API writes at start (its `EVIDENCE_BUCKET`) names the bucket the console is configured with (`ADMIN_EVIDENCE_BUCKET`). A console pointed at the wrong or an empty bucket would otherwise believe every object is missing. While the probe fails the sweep and the hold purge do nothing and log an ALERT (the probe also runs at `admin serve` start); a missing marker fails it too (start the API: it writes the marker). The orphan list is stored in the database (`evidence_orphan_report`), so every console node answers the same. It also **lists `hold/` objects older than an hour that no case names** (`GET /admin/v1/evidence/orphans`, the *Evidence orphans* page, an `evidence_orphans_found` audit entry and a log warning once per change): the sweep never deletes them, a person reviews each and the holder of the delete credential removes it or keeps it. `hiyall_pending_quarantine_cases` counts pending cases.

**Alerting.** Every new case increments `hiyall_quarantine_cases_total{result}` (an alert rule is committed in `infrastructure/alerts/hiyall.rules.yml`: any increase pages), logs a `upload quarantined` warning with the case and media ids, and sends a report to the error tracker (Sentry, when `SENTRY_DSN` is set) with route `quarantine/flagged` or `quarantine/match`. The report text names the case, but the error tracker's scrubber replaces every UUID with `:id` before it is sent, so **Sentry shows the verdict and the route, not the case id**: find the case in the admin console list (newest first) or by the case and media ids in the `upload quarantined` log line. Nothing sent to Sentry holds the image, a hash or the signals. A case that opens in the night is therefore not found by chance in the morning.

Account deletion does not release a hold: the purge skips quarantined photos and still finishes, leaving the `users` tombstone, the case and the objects. **[counsel]** Confirm that keeping them after an account deletion request is lawful for you and say so in the Privacy Policy.

Preservation: the system default is **365 days** from detection (`EVIDENCE_RETENTION_DAYS`; the legal texts state it as `[COUNSEL: evidence retention period, default currently 365 days]` until counsel decides). Cases opened before the default changed keep the 90 days they were given, except that a case recorded as reported always keeps its evidence at least a year from the report (`hold_until` only ever moves later; migration 0043), so evidence is never held for less than 365 days from detection or less than a year after a report. Staff can list evidence files that have no case (`GET /admin/v1/evidence/orphans`, section 9). A case that an administrator confirms or records as reported is set to `legal_hold` automatically and does not age out. **[counsel]** US law as amended in 2024 (the REPORT Act) is generally understood to require preserving reported material for **one year** rather than 90 days; confirm the period for you and for Indian law, and change `hold_until` and the procedure to match. A hold can be released from the console (section 9) once nothing depends on the evidence; the held files are then removed by the API's maintenance job after `hold_until`.

## 5. What staff can see, and how it is logged

Roles ([console doc](15-admin-console.md)): viewers see no case. **Moderators** see the quarantine list and each case's evidence record, and the **text and photos of reported public items** (post, comment, story, space, space entry, or a reported member's avatar) after typing a reason. **Administrators** alone can load the quarantined image, and it arrives **blurred by the server** (a small, heavily blurred derivative; the original pixels are not in the browser): unblurring is a second, explicit, audited click that issues a one-minute link.

Every one of these writes `operator_audit` **before** anything is returned: `report_content_view` (with reason), `content_media_fetch` (each photo streamed), `content_case_view`, `quarantine_media_view` (with reason), `quarantine_media_fetch`, `quarantine_media_reveal` (with reason), and the decisions `content_case_confirm`, `content_case_clear`, `content_case_reported`. Photos are streamed through the console from storage with a read-only token (`ADMIN_MEDIA_*`) behind two-minute links bound to the operator, the photo and the case; the browser never receives a storage URL or key. **Private chats have no preview at all**, and never will: staff see only what a reporter chose to share.

Review the audit log for these actions at least monthly (an administrator who is not the one who viewed). Any view without a matching open case is a reason to ask why.

## 6. Procedure when a case opens

1. **Do not look first.** The case list and detail show the uploader (age band, account status), the scanner, its signals and the SHA-256. For a `match` from a trusted list, that is often enough.
2. A second person is better than one. Prefer two administrators on every case involving a suspected minor victim.
3. Look only if you must decide: open the case, **Load image (blurred)** with a real reason, look at the server-blurred copy first, **Reveal** only if the decision needs it (the unblurred link works for one minute). Do not save, screenshot, copy, download or describe it in writing beyond what the case needs ("child, explicit, matches list L" is enough).
4. Decide:
   * **Clear** (a false positive): closes the case. The photo stays held until its date; the console does not delete anything. If the scanner had suspended the member, **restore** them on their user page, with a reason.
   * **Confirm and hold as evidence**: sets the legal hold. Keep the uploader suspended.
5. **Report, outside the console.** The console sends nothing to anyone. See section 8. Then **Record that it was reported** with the report number or the authority's reference.
6. Do not tell the uploader why. **[counsel]** An authority may ask you not to notify the member, and a notice can tip off an offender. The member sees the account suspended and the generic refusal.
7. If a minor victim may be in danger now, that is an emergency: contact the police (India: 112 or the local police; US: 911) before anything else, then the reports below.

## 7. Contacts, to fill in before launch

| Role | Who | How |
|---|---|---|
| Incident owner (decides, reports) | | |
| Second reviewer | | |
| Counsel | | |
| Cloudflare notification mailbox | | |
| Staff wellbeing contact | | |

## 8. Reporting **[counsel for all of this]**

The system does not report. A trained person does, from the case record, using the authority's own process.

**United States (NCMEC).** US providers that learn of apparent child sexual abuse material are required by federal law (18 U.S.C. 2258A) to report it to NCMEC's CyberTipline "as soon as reasonably possible". Register Hiyall as a reporting provider with NCMEC. Use the case record for the report: SHA-256, upload time, the uploader's account id and profile, the detection source, and (if NCMEC's form takes it) the file. Counsel decides whether a Hiyall entity is subject to US reporting law at all.

**India.** There is no single "NCMEC for India" with the same standing. The points to confirm with counsel: the National Cyber Crime Reporting Portal (cybercrime.gov.in), which has a dedicated path for child sexual abuse material and is run by the Ministry of Home Affairs' Indian Cybercrime Coordination Centre (the NCRB's role is crime records; ask counsel whether to copy it); the POCSO Act 2012 (sections on the duty to report and on failure to report) and the Information Technology Act 2000 (section 67B) and the IT Rules 2021 (takedown and preservation duties of intermediaries; the timelines have changed more than once); and the local police and State Special Juvenile Police Unit. Record the portal acknowledgement number as the report reference.

**Other places.** Members may be anywhere. Counsel advises which other regimes apply (UK, EU, others) once there are members there.

What to preserve for a report: the held objects under `hold/`, the case row (hash, size, times, signals), the uploader's account record (never edited), `operator_audit` for the case, and any member report that preceded it. Do not make copies elsewhere.

## 9. Evidence storage, two-person control, and what is not built

* **Evidence bucket: built (audit SAFE-1).** Quarantined originals are copied to a bucket of their own (`EVIDENCE_BUCKET`, with `EVIDENCE_ACCESS_KEY` / `EVIDENCE_SECRET_KEY`). The API's token there is meant to be **write-only**: it can keep evidence and cannot read or delete it, so a compromised or buggy API could not destroy what it just preserved, **but only while the token really has no read or delete right, or the bucket lock below is in place** (the canary checks the first; the lock is the owner's). The console reads with a different, read-only token (`ADMIN_EVIDENCE_*`), and a third credential, held only by the console's purge job (`ADMIN_EVIDENCE_DELETE_*`), deletes. Production refuses to start without `EVIDENCE_BUCKET` unless `EVIDENCE_ALLOW_SHARED_BUCKET=true` (development keeps the simple shared bucket: the original stays under `hold/` in the media bucket and the API's own hourly job still does the purge). **R2 caveat (the token is probably not write-only; the API now proves what it can do):**  Cloudflare R2 API tokens are scoped as admin or object *read and write* or object *read only*; an object read-and-write token includes delete, so a strictly write-only token may not be expressible. If it is not, protect the bucket another way: turn on R2 bucket locks (a retention rule on the evidence bucket) so R2 itself refuses to delete an object younger than the retention period whatever token asks, and keep the API's token the only one with write. **The canary (round-3 audit API-2, round-4 N-6).** `api check-config -release -net` (and, optionally, `EVIDENCE_CANARY=true` at every start) writes a tiny probe object (`canary/<UTC date>`, so starts on one day reuse one key and, where the token can delete, nothing is left behind) with the API's own evidence credential, then tries to read it and to delete it. **`EVIDENCE_ALLOW_API_DELETE=true` is now a declaration the canary verifies**: it says "a bucket lock exists", so the probe must SURVIVE a delete by the API's credential. If the probe **can be deleted**, nothing protects the evidence and production **refuses** (the check fails; the start refuses), whatever `EVIDENCE_ALLOW_API_DELETE` says, unless `EVIDENCE_CANARY_ACCEPT_UNLOCKED=true`, the explicit accepted-risk override (then a warning). If the delete is refused but the probe can be read, production refuses unless `EVIDENCE_ALLOW_API_DELETE=true` (the canary then says "bucket lock verified" and names the probe object). A probe that **cannot be written** at all (an R2 outage) never takes the API down: it warns and retries in the background (twelve attempts, growing pauses), and only `check-config -release -net` fails on it; a verdict found later is logged as an ALERT and exported as `hiyall_evidence_canary_state` (2 = failed). Run the check once from the release step and again after any change to the token or the bucket rules; probes are not evidence and the sweep ignores them. The lock rule must cover `canary/` as well as `hold/`. The API also writes `evidence-bucket-id` (its bucket name) at every start, best effort (a lock that refuses overwrites keeps the first one). Owner action: set the bucket-lock rule on the evidence bucket **before launch** (retention at least `EVIDENCE_RETENTION_DAYS`).
* **What the API role can do to a case (round-4 N-1, migration 0046).** It can open one and nothing more. `hiyall_api` has `INSERT` only on the columns the upload scanner fills (`case_id, media_id, user_id, purpose, result, scanner, signals, original_sha256, original_bytes, content_type, original_key, full_key, suspended_user, hold_until`); status, release, report and legal-hold columns cannot be named, and a `BEFORE INSERT` trigger forces `status='pending'`, no release or report and no legal hold for that role even if a column were granted by mistake (and a `hold_until` of at least 30 days). `CHECK` constraints pin the keys to `hold/<media id>/original` and `hold/<media id>/full.jpg`, and `media_id` is unique, so a compromised API cannot insert a pre-released case that points at real evidence for the console's purge to delete. `TestAPIRoleCannotInsertAPreReleasedOrForeignCase` is the restricted-role test. The purge itself takes a `FOR SHARE` lock on the case row (`hold_lock_for_purge`) from before the first object delete until the case is marked purged, so a legal hold or a report, which update the row, wait for it; the check is also repeated before each object (an open member report does not touch the row).
* **Quarantined originals in the upload prefix (round-4 N-7).** Opening a case replaces the media row's upload key with the evidence key, so the original in the media bucket's upload prefix is named by nothing. It is removed after the evidence is stored (one retry); if that fails it is recorded in `quarantine_upload_leftovers` and removed by the API's hourly job (`quarantine upload leftovers`; never anything under `hold/`). If the evidence write fails for a FLAGGED photo its upload object is recorded the same way; for a MATCH it is kept, since it may be the only copy, and the case's `signals.uploadKey` says where it is.
* **Releasing a hold: built, two people.** Releasing is a *proposal* (`POST /admin/v1/content-cases/{id}/proposals`, kind `release`, a reason) that a **different** administrator approves (`POST /admin/v1/approvals/{id}/approve`, a reason) within 24 hours; both are audited in the transaction that releases (`evidence_proposed`, `evidence_approved`, `hold_release`). It is refused while: the case is open (`HOLD_CASE_OPEN`), a legal hold is set (`HOLD_LEGAL_HOLD`), an open member report is about the same uploader (`HOLD_REPORT_OPEN`), or another open case of the same uploader exists (`HOLD_OTHER_CASE_OPEN`); the blockers are checked when proposing and **again when approving**. The old single-step `POST /admin/v1/holds/{id}/release` answers `409 APPROVAL_REQUIRED`. Releasing deletes nothing at once: the **console's purge job** (`admin purge-holds`, hourly inside `admin serve`, with the delete credential only it holds; with evidence in the shared media bucket, the API's hourly "released hold cleanup" job as before) removes `hold/<media id>/original` and `full.jpg` once `hold_until` has passed and **re-checks the hold in the database immediately before each object delete** (`hold_still_releasable`: a report or second case opened, or a legal hold set, since the list was read stops the purge at the next object and keeps the rest; counted in `hiyall_evidence_purge_kept_total`), then marks `objects_purged_at` and writes `hold_objects_purged` to the audit log. The case row (hash, size, times, signals, who proposed, who approved and why) stays as the record, and the `media_assets` row stays `quarantined`. The database role does this through two `SECURITY DEFINER` functions (`held_objects_due`, `mark_hold_purged`) and still cannot read or change a case.
* **Clearing a case: two people.** A scanner match is never dismissed by one person: kind `clear`, same flow. **Lifting a legal hold: two people and counsel's reference** (kind `legal_hold_lift`; the reference is mandatory in the API and as a table constraint); a `reported` or `confirmed` resolution can never set `legalHold:false` (`422 LEGAL_HOLD_APPROVAL_REQUIRED`). **Retention:** `EVIDENCE_RETENTION_DAYS` (default 365, one year, pending counsel; **production refuses less than 365**) is applied to **new** cases, and migration 0041 changes the column default the same way; existing cases keep the `hold_until` they have. Marking a case `reported` moves `hold_until` to **at least a year from the report** (`greatest(hold_until, now() + 365 days)`), however late the report is made, and never earlier. The clear, release and lift transitions are SQL functions that enforce the two-person and legal-hold rules in the database ([admin console](15-admin-console.md), Two-person control); the console role has no direct `UPDATE` on cases. Not built: an expiry report (list the holds due to lapse).
* Chat evidence holds (`chat_blobs.held_report_id`, held for a chat report) are not touched by this, and nothing releases them: no code clears `held_report_id`, so the held blob stays until counsel sets a release rule (open item, [COUNSEL: chat evidence release rule]). The legal texts say exactly that (privacy policy section 6, data retention), not "released by staff".
* Case assignment and SLA timers. (A second approver and alerts on a new case are built: see above, and the section 4 alerting paragraph.)
* A `ban` that is distinct from suspension, and appeals.
* Scanning of anything that is not a photo upload; video.
* Automatic reporting. Deliberately: a person decides and reports.

## 10. Staff wellbeing

Reviewing this material harms people. Rules:

* Minimum necessary exposure: hash and signals first, blurred next, revealed last, shortest time. Never as casual browsing. Never on a phone or personal device; a locked-down work machine.
* Nobody is required to view it. Anyone may decline a case without explanation; make sure someone else can take it.
* Limits: no more than a few cases in a sitting, breaks after any, no viewing late at night or alone if it can be avoided.
* The business pays for confidential counselling for anyone who views, available without asking permission from a manager, and checks in after a hard case.
* The audit log is for accountability, not blame: view logs must not be used to punish someone for looking at a case they were assigned.

## 11. Never

* Never forward, email, chat, upload, attach to a ticket, paste into a spreadsheet or otherwise share an image or a description of it, internally or externally, except in a report to the authority through its own channel.
* Never test with real illegal material. Tests use synthetic images and made-up hashes. Never put a real list in the repository, an environment file in version control, a screenshot, or a chat.
* Never delete a held object, an audit row or a case to "clean up".
* Never use the break-glass `moderate` command or direct database access to look at imagery.
* Never decide alone and silently to clear a `match` from a trusted list.

## 12. Setting it up, in order

1. Counsel review of this page and the reporting section; the Privacy Policy line about retention of reported material.
2. Register with NCMEC (and decide the Indian reporting path); fill in section 7.
3. Obtain a hash list or a provider; set `SCAN_HASHLIST_FILE` or the provider variables; confirm the startup log says `upload scanner: hash list` or `provider`, and that production starts without `SCAN_ALLOW_NONE`.
4. Cloudflare CSAM Scanning Tool on the media zone (section 3), notification test.
5. `ADMIN_MEDIA_*` read-only token for the console, `ADMIN_DATABASE_URL` and the database roles ([deploy guide](../deployment/10-deploy-guide.md#11-admin-console-database-roles-and-upload-scanning)).
6. A table-top exercise with synthetic data: a fake `match` end to end (case opens, admin views blurred, reveals, confirms, records a fake reference), then check the audit log shows each step.
