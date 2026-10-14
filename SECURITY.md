# Security policy

Hiyall has not launched. If you find a vulnerability in this code or in a build of the app, please report it privately and do not open a public issue.

**Contact:** `<OWNER: security contact email or private reporting link; set before launch>`. GitHub private vulnerability reporting ("Security" tab, "Report a vulnerability") is the preferred route once it is enabled on the repository.

Please include what you found, how to reproduce it and the version or commit. Do not access other people's data, run denial-of-service tests against a shared environment, or publish details before there has been a reasonable time to fix them. There is no bug bounty yet. A response time is not promised until there is a staffed inbox; the owner should set one here at launch.

Scope: the API (`services/api`), the admin console (`apps/admin`), the mobile app and its Rust encryption core (`apps/mobile`). The end-to-end encryption design has had no independent review yet (`docs/security/13-encrypted-chat-implementation.md`); reports about it are especially welcome.
