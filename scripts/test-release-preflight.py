#!/usr/bin/env python3
"""Unit tests for scripts/release_preflight.py, scripts/check_env_docs.py and the other release tooling.

  python3 scripts/test-release-preflight.py

Every test runs on fixtures (strings and temporary directories); nothing touches the network, git or GitHub. The
placeholder tests contain every form the audit found the old gate-b pattern missing: [CONFIRM: ...], long upper-case
spans with a lowercase tail, and lower or mixed case keywords. Python 3.8+, standard library only.
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

# Importing scripts under test must never write scripts/__pycache__ (the release preflight's gate a would see it).
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def slurp(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


rp = load("release_preflight", "release_preflight.py")
envdocs = load("check_env_docs", "check_env_docs.py")
iossign = load("ios_signing_check", "ios_signing_check.py")


class PlaceholderTests(unittest.TestCase):
    """Gate b is an allowlist: after links with a real address, checkboxes, code spans and the DRAFT banner are taken out,
    every remaining bracket span fails. These are the strings the round-3 audit slipped past the old denylist, plus the
    older misses."""
    MUST_FLAG = [
        "[CONFIRM: operator to set a period]",
        "[CONFIRM]",
        "[DATA PROTECTION CONTACT / REPRESENTATIVE: add a data protection officer or representative for the EU or UK if one is required.]",
        "[DATA PROTECTION CONTACT / REPRESENTATIVE, if required]",
        "[COUNSEL: evidence retention period, default currently 365 days]",
        "[OPERATOR: fill in.]",
        "[LEGAL REVIEW: this section needs a lawyer.]",
        "[PRIVACY EMAIL]",
        "[PARENT/GUARDIAN CONTACT EMAIL]",
        "[GOVERNING LAW / JURISDICTION]",
        "[Operator: describe the check]",
        "[operator: describe the check]",
        "[Confirm: period]",
        "[confirm the period with counsel]",
        "[Legal review: add a section]",
        "[to be confirmed]",
        "[To be decided]",
        "[TODO]",
        "[tbd]",
        "[fill in the address]",
        "[Insert company name]",
        "[Counsel: choose]",
        "{{ company_name }}",
        # round 3
        "[CoUnSeL: mixed case]",
        "[Counsel\nscanning status at launch]",
        "[COUNSEL:\nscanning status,\ncontinued here]",
        "[COUNSEL]: x",
        "[Company name]",
        "[Effective date]",
        "[your address here]",
        "[Settings > Help & Safety]",
        "Use the [Report] button",
        "a list like [a, b, c]",
        "[1]",
        "[ref]: https://hiyall.app/ref",
        "[BRACKETS]",
        "[x] done",
        "[ ] not done",
        "[COUNSEL: x](https://hiyall.app/privacy)",
        "[see this](https://hiyall.example.com/x)",
        "[the policy](TBD)",
        "[the policy](<url>)",
        "[the policy]()",
        "[the policy](#)",
        "[a [nested] span](https://hiyall.app/x)",
        "a stray ] bracket",
        "an opening [ bracket with no end",
        "We will reply within TBD days",
        "TODO: write this",
        "FIXME later",
        "XXX",
    ]
    MUST_NOT_FLAG = [
        "see [the privacy policy](https://hiyall.app/privacy)",
        "[App Store](https://apps.apple.com/app/x)",
        "[Write to us](mailto:help@hiyall.app)",
        "[Children and teens](children-and-teens.md)",
        "[Children and teens](./children-and-teens.md#age)",
        "[Jump](#retention)",
        "- [x] done",
        "- [ ] not done",
        "1. [ ] numbered",
        "Use the `[Report]` button",
        "```\n[COUNSEL: inside a code block]\n```",
        "> **DRAFT for legal review. Not legal advice. Placeholders in [BRACKETS] must be filled by the operator.**",
        "Settings > Help & Safety",
        "",
    ]

    def test_every_known_miss_is_flagged(self):
        for text in self.MUST_FLAG:
            with self.subTest(text=text):
                self.assertTrue(rp.find_placeholders("Before " + text + " after."), "not flagged: " + text)

    def test_at_least_twenty_six_audit_strings(self):
        self.assertGreaterEqual(len(self.MUST_FLAG), 26)

    def test_allowed_markdown_is_not_flagged(self):
        for text in self.MUST_NOT_FLAG:
            with self.subTest(text=text):
                self.assertEqual(rp.find_placeholders(text), set(), "flagged by mistake: " + text)

    def test_banner_wording_alone_passes(self):
        self.assertEqual(rp.find_placeholders("> **DRAFT for legal review. Placeholders in [BRACKETS] must be filled.**"), set())

    def test_placeholder_hidden_in_a_two_line_span_is_one_finding(self):
        found = rp.find_placeholders("[COUNSEL: scanning\nstatus at launch]")
        self.assertEqual(len(found), 1)

    def test_real_legal_documents_only_fail_on_marked_placeholders(self):
        # The committed drafts must carry markers (the gate blocks the release); this guards the opposite mistake, a bracket
        # used as ordinary text, which would make the final documents impossible to pass.
        for d in ("docs/legal", "apps/mobile/assets/legal"):
            for n in sorted(os.listdir(os.path.join(ROOT, d))):
                if not n.endswith(".md"):
                    continue
                for span in rp.find_placeholders(slurp(os.path.join(d, n))):
                    with self.subTest(doc=d + "/" + n, span=span[:60]):
                        self.assertRegex(span, r"^\[[A-Z][A-Z /,.&'-]{2,}(:|\]|,)|^\[[A-Z][A-Z /,.&'-]+\]$|^\{\{")


class LegalGateTests(unittest.TestCase):
    """Runs the real gate b against a temporary tree so a regression in the wiring, not just the regex, is caught."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="preflight-legal-")
        self.old_root = rp.ROOT
        rp.ROOT = self.tmp
        for d in ("docs/legal", "apps/mobile/assets/legal", "apps/mobile/lib/core", "services/api/internal/domain"):
            os.makedirs(os.path.join(self.tmp, d))
        self.write("apps/mobile/lib/core/legal_documents.dart", "const kTermsVersion = '2026-10-01';\n")
        self.write("services/api/internal/domain/onboarding.go", 'const TermsVersion = "2026-10-01"\n')

    def tearDown(self):
        rp.ROOT = self.old_root
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, rel, text):
        with open(os.path.join(self.tmp, rel), "w", encoding="utf-8") as f:
            f.write(text)

    def doc(self, body):
        text = "# Terms\n\nVersion: 2026-10-01\n\n" + body + "\n"
        self.write("docs/legal/terms-of-service.md", text)
        self.write("apps/mobile/assets/legal/terms-of-service.md", text)

    def run_gate(self):
        g = rp.Gate("b", "legal")
        rp.gate_legal(g)
        return g

    def test_clean_documents_pass(self):
        self.doc("We are Hiyall Ltd, reach us at help@hiyall.app. See [the policy](https://hiyall.app/p).")
        self.assertEqual(self.run_gate().problems, [])

    def test_each_miss_blocks_the_release(self):
        for body in ("[CONFIRM: operator to set a period]", "[DATA PROTECTION CONTACT / REPRESENTATIVE, if required]",
                     "[operator: fill in]", "[to be confirmed]", "[Company name]", "[COUNSEL]: x", "[CoUnSeL: x]",
                     "[COUNSEL: scanning\nstatus]", "[your address here]", "[Effective date]", "TBD"):
            with self.subTest(body=body):
                self.doc("Retention: " + body)
                self.assertTrue(any("unfilled placeholder" in m for m, _ in self.run_gate().problems), body)

    def test_draft_banner_blocks(self):
        self.doc("> **DRAFT for legal review. Not legal advice.**")
        self.assertTrue(any("DRAFT banner" in m for m, _ in self.run_gate().problems))

    def test_version_drift_blocks(self):
        self.doc("Fine text.")
        self.write("services/api/internal/domain/onboarding.go", 'const TermsVersion = "2026-11-01"\n')
        self.assertTrue(any("terms version is not the same" in m for m, _ in self.run_gate().problems))


class DevReuseTests(unittest.TestCase):
    def test_real_environments_file_lists_the_dev_identifiers(self):
        projects, buckets, problem = rp.dev_identifiers()
        self.assertIsNone(problem)
        self.assertIn("hiyall-prod-1", projects)
        self.assertTrue({"hiyall", "hiyall-chat"} <= buckets)

    def test_production_equal_to_dev_is_flagged(self):
        probs = rp.dev_reuse_problems({"FIREBASE_PROJECT_ID": "hiyall-prod-1", "MEDIA_BUCKET": "hiyall", "CHAT_MEDIA_BUCKET": "hiyall-chat-prod"},
                                      {"hiyall-prod-1"}, {"hiyall", "hiyall-chat"})
        text = " ".join(m for m, _ in probs)
        self.assertIn("FIREBASE_PROJECT_ID=hiyall-prod-1", text)
        self.assertIn("MEDIA_BUCKET=hiyall ", text + " ")
        self.assertNotIn("CHAT_MEDIA_BUCKET", text)

    def test_distinct_production_values_pass(self):
        self.assertEqual(rp.dev_reuse_problems({"FIREBASE_PROJECT_ID": "hiyall-live", "MEDIA_BUCKET": "hiyall-prod", "CHAT_MEDIA_BUCKET": "hiyall-chat-prod"},
                                               {"hiyall-prod-1"}, {"hiyall", "hiyall-chat"}), [])

    def test_extra_values_from_the_environment_count(self):
        os.environ["DEV_FIREBASE_PROJECT_ID"], os.environ["DEV_MEDIA_BUCKETS"] = "my-dev, other-dev", "scratch"
        try:
            projects, buckets, _ = rp.dev_identifiers()
        finally:
            del os.environ["DEV_FIREBASE_PROJECT_ID"], os.environ["DEV_MEDIA_BUCKETS"]
        self.assertTrue({"my-dev", "other-dev", "hiyall-prod-1"} <= projects)
        self.assertIn("scratch", buckets)

    def test_production_template_does_not_use_a_dev_identifier(self):
        values = rp.parse_env_file(os.path.join(ROOT, "config/api.production.example.env"))
        projects, buckets, _ = rp.dev_identifiers()
        self.assertEqual(rp.dev_reuse_problems(values, projects, buckets), [])


class CheckRunTests(unittest.TestCase):
    EXPECTED = ["api", "mobile", "docker"]

    def run_(self, i, name, status="completed", conclusion="success"):
        return {"id": i, "name": name, "status": status, "conclusion": conclusion}

    def test_all_green(self):
        runs = [self.run_(1, "api"), self.run_(2, "mobile"), self.run_(3, "docker"), self.run_(4, "unrelated", conclusion="failure")]
        self.assertEqual(rp.evaluate_check_runs(runs, self.EXPECTED), [])

    def test_missing_failed_and_running_are_reported(self):
        runs = [self.run_(1, "api", conclusion="failure"), self.run_(2, "mobile", status="in_progress", conclusion=None)]
        out = " | ".join(rp.evaluate_check_runs(runs, self.EXPECTED))
        self.assertIn("api concluded failure", out)
        self.assertIn("mobile is still in_progress", out)
        self.assertIn("no check run named docker", out)

    def test_a_green_rerun_replaces_a_red_run(self):
        runs = [self.run_(1, "api", conclusion="failure"), self.run_(9, "api"), self.run_(2, "mobile"), self.run_(3, "docker")]
        self.assertEqual(rp.evaluate_check_runs(runs, self.EXPECTED), [])

    def test_skipped_does_not_count_as_success(self):
        runs = [self.run_(1, "api", conclusion="skipped"), self.run_(2, "mobile"), self.run_(3, "docker")]
        self.assertEqual(len(rp.evaluate_check_runs(runs, self.EXPECTED)), 1)

    def test_job_names_come_from_the_real_workflow(self):
        names = rp.foundation_job_names()
        for n in ("api", "mobile", "contracts", "admin", "rust", "docker", "supply-chain"):
            self.assertIn(n, names)

    def test_release_job_names_do_not_collide_with_foundation(self):
        text = slurp(".github/workflows/release.yml")
        release_jobs = set(__import__("re").findall(r"(?m)^  ([a-z][a-z0-9-]*):\s*$", text.split("\njobs:\n", 1)[1]))
        self.assertEqual(release_jobs & set(rp.foundation_job_names()), set())


class EnvironmentTests(unittest.TestCase):
    def test_required_reviewers_present(self):
        env = {"protection_rules": [{"type": "required_reviewers", "prevent_self_review": True, "reviewers": [{"type": "User"}]}],
               "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}}
        self.assertEqual(rp.evaluate_environment(env), ([], []))

    def test_no_reviewers_blocks(self):
        problems, _ = rp.evaluate_environment({"protection_rules": [{"type": "wait_timer"}]})
        self.assertEqual(len(problems), 1)
        problems, _ = rp.evaluate_environment({"protection_rules": [{"type": "required_reviewers", "reviewers": []}]})
        self.assertEqual(len(problems), 1)

    def test_unrestricted_branches_is_a_note_not_a_failure(self):
        env = {"protection_rules": [{"type": "required_reviewers", "reviewers": [{"type": "User"}]}], "deployment_branch_policy": None}
        problems, notes = rp.evaluate_environment(env)
        self.assertEqual(problems, [])
        self.assertTrue(notes)


class ScanAckTests(unittest.TestCase):
    ACK = "I_ACCEPT_UNSCANNED_PHOTOS"

    def test_scanning_on_needs_nothing(self):
        self.assertEqual(rp.scan_ack_problems(False, "", {"a.md": "Photos are scanned. <!-- claim:scanned -->"}), ([], []))

    def test_unscanned_without_ack_blocks(self):
        problems, _ = rp.scan_ack_problems(True, "", {})
        self.assertEqual(len(problems), 1)
        problems, _ = rp.scan_ack_problems(True, "yes", {})
        self.assertEqual(len(problems), 1)

    def test_unscanned_with_ack_passes_but_notes_it(self):
        problems, notes = rp.scan_ack_problems(True, self.ACK, {"a.md": "We do not scan photos."})
        self.assertEqual(problems, [])
        self.assertTrue(any("UNSCANNED" in n for n in notes))

    def test_scanned_claim_while_unscanned_blocks(self):
        problems, _ = rp.scan_ack_problems(True, self.ACK, {"docs/mobile/store-listing.md": "ok\nPhotos are scanned on upload. <!-- claim:scanned -->\n"})
        self.assertEqual(len(problems), 1)
        self.assertIn("line 2", problems[0][0])

    def test_legal_scanner_wording_outside_brackets_blocks(self):
        legal = {"docs/legal/privacy-policy.md": "# P\n\nThe photo's fingerprint (SHA-256) is kept in a case record.\n"}
        problems, _ = rp.scan_ack_problems(True, self.ACK, {}, legal)
        self.assertEqual(len(problems), 1)
        self.assertIn("docs/legal/privacy-policy.md line 3", problems[0][0])

    def test_legal_scanner_wording_inside_counsel_brackets_passes(self):
        legal = {"a.md": "[COUNSEL: scanning status at launch. Wording if live: A flagged photo is kept as evidence\nin restricted storage, with its case record.]\n"
                         "We do not currently check uploaded photos against lists of known illegal images. We rely on reports.\n"
                         "> **DRAFT: placeholders in [BRACKETS] hash list**\n"}
        self.assertEqual(rp.scan_ack_problems(True, self.ACK, {}, legal)[0], [])

    def test_legal_scanner_wording_is_free_when_scanning_is_on(self):
        legal = {"a.md": "Flagged photos are kept in restricted storage.\n"}
        self.assertEqual(rp.scan_ack_problems(False, "", {}, legal), ([], []))

    def test_legal_hidden_marker_blocks(self):
        problems, _ = rp.scan_ack_problems(True, self.ACK, {}, {"a.md": "Photos are scanned. <!-- claim:scanned -->\n"})
        self.assertEqual(len(problems), 1)

    def test_real_legal_documents_make_no_scanner_claim_outside_counsel_brackets(self):
        # An unscanned release must be able to pass once counsel has chosen the unscanned wording; until then every
        # scanner sentence sits inside a bracket that gate b refuses.
        for d in ("docs/legal", "apps/mobile/assets/legal"):
            for n in sorted(os.listdir(os.path.join(rp.ROOT, d))):
                if n.endswith(".md"):
                    self.assertEqual(rp.legal_scan_claims(slurp("%s/%s" % (d, n))), [], "%s/%s" % (d, n))

    def test_real_documents_carry_marked_claims(self):
        # The store listing is where the claim lives; the gate can only work if the marker is really there.
        text = slurp("docs/mobile/store-listing.md")
        self.assertIn("claim:scanned", text)


class EnvDocsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="preflight-env-")
        for rel in envdocs.ALL_DOCS:
            os.makedirs(os.path.dirname(os.path.join(self.tmp, rel)), exist_ok=True)
            with open(os.path.join(self.tmp, rel), "w") as f:
                f.write("")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def doc(self, rel, *names):
        with open(os.path.join(self.tmp, rel), "a") as f:
            for n in names:
                f.write("# %s=\n" % n)

    def test_agreement_passes(self):
        self.doc(envdocs.API_DOC, "DATABASE_URL", "SENTRY_DSN")
        for d in envdocs.ADMIN_DOCS:
            self.doc(d, "ADMIN_ADDR")
        self.assertEqual(envdocs.drift(self.tmp, {"DATABASE_URL", "SENTRY_DSN", "ADMIN_ADDR"}), [])

    def test_undocumented_variable_is_drift(self):
        self.doc(envdocs.API_DOC, "DATABASE_URL")
        out = envdocs.drift(self.tmp, {"DATABASE_URL", "NEW_THING_KEY"})
        self.assertTrue(any("NEW_THING_KEY" in p and envdocs.API_DOC in p for p in out))

    def test_admin_variable_must_be_in_both_admin_files(self):
        self.doc(envdocs.ADMIN_DOCS[0], "ADMIN_ADDR")
        out = envdocs.drift(self.tmp, {"ADMIN_ADDR"})
        self.assertEqual(len(out), 1)
        self.assertIn(envdocs.ADMIN_DOCS[1], out[0])

    def test_stale_example_entry_is_drift(self):
        self.doc(envdocs.API_DOC, "DATABASE_URL", "REMOVED_LONG_AGO")
        out = envdocs.drift(self.tmp, {"DATABASE_URL"})
        self.assertTrue(any("REMOVED_LONG_AGO" in p for p in out))

    def test_platform_variables_are_allowed(self):
        self.doc(envdocs.API_DOC, "DATABASE_URL", "GOMEMLIMIT")
        self.assertEqual(envdocs.drift(self.tmp, {"DATABASE_URL"}), [])

    def test_the_variable_scan_finds_real_names(self):
        names = envdocs.go_variables(ROOT)
        for n in ("DATABASE_URL", "SENTRY_DSN", "ADMIN_DATA_KEY", "TRUSTED_PROXY_CIDRS"):
            self.assertIn(n, names)
        self.assertNotIn("CHANGE_ME", names)


class PlatformTests(unittest.TestCase):
    def test_spaces_case_and_blanks_are_ignored(self):
        self.assertEqual(rp.parse_platforms("android, ios"), ({"android", "ios"}, []))
        self.assertEqual(rp.parse_platforms(" Android ,\tIOS\r\n"), ({"android", "ios"}, []))
        self.assertEqual(rp.parse_platforms("ios,,"), ({"ios"}, []))

    def test_unknown_platform_is_reported_not_dropped(self):
        self.assertEqual(rp.parse_platforms("andriod,ios"), ({"ios"}, ["andriod"]))

    def test_gate_e_fails_on_an_unknown_platform(self):
        os.environ["RELEASE_PLATFORMS"] = "android, andriod"
        try:
            g = rp.Gate("e", "x")
            rp.gate_android_signing(g)
        finally:
            del os.environ["RELEASE_PLATFORMS"]
        self.assertTrue(any("andriod" in m for m, _ in g.problems))

    def test_release_workflow_normalises_the_list_in_one_job(self):
        text = slurp(".github/workflows/release.yml")
        self.assertIn("platforms:", text)
        self.assertNotIn("contains(format(',{0},', vars.RELEASE_PLATFORMS", text)


class SkipPolicyTests(unittest.TestCase):
    CI = {"GITHUB_ACTIONS": "true", "GITHUB_REF_NAME": "v1.0.0"}

    def refusal(self, gid, **env):
        e = dict(self.CI)
        e.update(env)
        return rp.skip_refusal(gid, environ=e, ci=True)

    def test_anything_may_be_skipped_locally(self):
        self.assertIsNone(rp.skip_refusal("d", environ={}, ci=False))
        self.assertIsNone(rp.skip_refusal("o", environ={}, ci=False))

    def test_gate_d_in_ci_needs_the_host_check_for_this_tag(self):
        self.assertIsNotNone(self.refusal("d"))
        self.assertIsNotNone(self.refusal("d", PREFLIGHT_HOST_CHECK="v0.9.0"))
        self.assertIsNone(self.refusal("d", PREFLIGHT_HOST_CHECK="v1.0.0"))

    def test_other_gates_in_ci_need_a_reason(self):
        self.assertIsNotNone(self.refusal("o"))
        self.assertIsNone(self.refusal("o", PREFLIGHT_SKIP_REASON="no admin token on a personal repository"))

    def test_gate_o_cannot_be_skipped_while_a_token_exists(self):
        self.assertIsNotNone(self.refusal("o", PREFLIGHT_SKIP_REASON="x", GH_ADMIN_TOKEN="t"))

    def test_gate_o_in_ci_fails_when_it_cannot_look(self):
        old = rp.in_ci, rp.gh_api, rp.github_repo
        rp.in_ci, rp.gh_api, rp.github_repo = (lambda: True), (lambda a, token=None: (1, "HTTP 403: Resource not accessible")), (lambda: "o/r")
        try:
            g = rp.Gate("o", "x")
            rp.gate_environment(g)
        finally:
            rp.in_ci, rp.gh_api, rp.github_repo = old
        self.assertTrue(g.problems)
        self.assertTrue(any("could not verify" in m for m, _ in g.problems))

    def test_gate_o_locally_is_only_a_notice(self):
        old = rp.in_ci, rp.gh_api, rp.github_repo
        rp.in_ci, rp.gh_api, rp.github_repo = (lambda: False), (lambda a, token=None: (127, "gh is not installed")), (lambda: "o/r")
        try:
            g = rp.Gate("o", "x")
            rp.gate_environment(g)
        finally:
            rp.in_ci, rp.gh_api, rp.github_repo = old
        self.assertEqual(g.problems, [])
        self.assertTrue(any("NOT VERIFIED" in n for n in g.notes))

    def test_release_environment_without_reviewers_blocks(self):
        problems, _ = rp.evaluate_environment({"protection_rules": []}, "release")
        self.assertEqual(len(problems), 1)
        self.assertIn("release", problems[0])


class HygieneTests(unittest.TestCase):
    def test_importing_the_scripts_leaves_no_bytecode(self):
        self.assertFalse(os.path.isdir(os.path.join(HERE, "__pycache__")), "scripts/__pycache__ exists after the imports above")

    def test_bytecode_is_git_ignored_and_the_workflow_disables_it(self):
        gi = slurp(".gitignore")
        for line in ("scripts/__pycache__/", "*.pyc", "__pycache__/", "config/admin.production.env", "config/r2.local.env", "*.env.local",
                     "apps/mobile/ios/Flutter/Signing.xcconfig"):
            self.assertIn(line, gi.splitlines(), line)
        self.assertIn("PYTHONDONTWRITEBYTECODE", slurp(".github/workflows/release.yml"))

    def test_foundation_never_cancels_a_run_on_main(self):
        text = slurp(".github/workflows/foundation.yml")
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", text)


class AlertRuleTests(unittest.TestCase):
    def run_validator(self, text):
        import subprocess
        d = tempfile.mkdtemp(prefix="alerts-")
        try:
            path = os.path.join(d, "rules.yml")
            with open(path, "w") as f:
                f.write(text)
            r = subprocess.run([os.path.join(HERE, "validate-alerts.sh"), path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
            return r.returncode, r.stdout
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_committed_rules_pass(self):
        rc, out = self.run_validator(slurp("infrastructure/alerts/hiyall.rules.yml"))
        self.assertEqual(rc, 0, out)

    def test_a_rule_on_a_metric_no_code_defines_fails(self):
        rc, out = self.run_validator(slurp("infrastructure/alerts/hiyall.rules.yml").replace("hiyall_media_busy_total", "hiyall_made_up_total"))
        self.assertNotEqual(rc, 0)
        self.assertIn("hiyall_made_up_total", out)

    def test_counter_rules_cover_the_first_event(self):
        text = slurp("infrastructure/alerts/hiyall.rules.yml")
        for metric in ("hiyall_http_panics_total", "hiyall_quarantine_cases_total", "hiyall_push_config_errors_total", "hiyall_scan_upstream_errors_total"):
            self.assertIn("unless sum by", text)
            self.assertRegex(text, r"(?s)%s\[[0-9a-z]+\]\)\) > 0\s+or \(sum by \(\w+\) \(%s\) > 0 unless" % (metric, metric))


class CodeownersTests(unittest.TestCase):
    def test_every_path_in_the_real_file_exists(self):
        self.assertEqual(rp.codeowners_missing_paths(slurp(".github/CODEOWNERS")), [])

    def test_a_dead_path_is_found(self):
        self.assertEqual(rp.codeowners_missing_paths("* @o\n/services/api/internal/auth/ @o\n/docs/legal/ @o\n"), ["/services/api/internal/auth/"])


class IosSigningTests(unittest.TestCase):
    GOOD = """Build settings for action build and target Runner:
    CODE_SIGN_IDENTITY = Apple Distribution
    CODE_SIGN_STYLE = Manual
    DEVELOPMENT_TEAM = ABCDE12345
    PROVISIONING_PROFILE_SPECIFIER = Hiyall App Store

Build settings for action build and target FlutterGeneratedPluginSwiftPackage:
    CODE_SIGN_STYLE = Automatic
"""

    def test_runner_only_passes(self):
        self.assertEqual(iossign.problems(self.GOOD, "ABCDE12345", "Hiyall App Store"), [])

    def test_wrong_target_is_reported(self):
        text = self.GOOD.replace("target Runner:", "target RunnerTests:")
        self.assertTrue(any("no target named Runner" in x for x in iossign.problems(text, "ABCDE12345", "Hiyall App Store")))

    def test_automatic_style_on_runner_fails(self):
        text = self.GOOD.replace("CODE_SIGN_STYLE = Manual", "CODE_SIGN_STYLE = Automatic")
        self.assertTrue(any("CODE_SIGN_STYLE" in x for x in iossign.problems(text, "ABCDE12345", "Hiyall App Store")))

    def test_profile_leaking_to_another_target_fails(self):
        text = self.GOOD + "\nBuild settings for action build and target SomePackage:\n    PROVISIONING_PROFILE_SPECIFIER = Hiyall App Store\n"
        self.assertTrue(any("leaked" in x for x in iossign.problems(text, "ABCDE12345", "Hiyall App Store")))


class RealTreeTests(unittest.TestCase):
    """Gates that must be clean on the committed tree whatever the owner has or has not supplied."""

    def gate(self, fn):
        g = rp.Gate("x", "x")
        fn(g)
        return g

    def test_release_workflow_gate_is_clean(self):
        self.assertEqual(self.gate(rp.gate_workflow).problems, [])

    def test_identifier_gate_is_clean(self):
        self.assertEqual(self.gate(rp.gate_ids).problems, [])

    def test_migration_gate_is_clean(self):
        self.assertEqual(self.gate(rp.gate_migrations).problems, [])

    def test_gate_letters_are_unique_and_ordered(self):
        letters = [gid for gid, _, _ in rp.GATES]
        self.assertEqual(letters, sorted(set(letters)))

    def test_environments_file_is_valid_json(self):
        json.loads(slurp("config/environments.json"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
