#!/usr/bin/env python3
"""Release preflight: every unmet V1 release gate, each with a one-line fix. Run through scripts/release-preflight.sh.

It only GATES. It never builds, deploys or runs the heavy test suites (scripts/check.sh does). It reads files,
runs `go vet`, builds the API binary into a temporary directory and asks it to validate the production
environment (`api check-config -release`), and checks that the generated OpenAPI contract is current.

Exit 0: every gate passed (or was skipped on purpose, loudly). Exit 1: at least one gate is unmet.

Environment:
  HIYALL_RELEASE_ENV        which config/mobile-release.<env>.local.env to read (default production)
  HIYALL_API_ENV_FILE       the production API environment file (default config/api.production.env)
  PREFLIGHT_SECRETS_DIR     where files named /secrets/... in that env file live locally (default config/secrets)
  PREFLIGHT_SKIP            comma list of gate ids to skip, e.g. "d" (printed as SKIPPED, never silent)
  PREFLIGHT_ANDROID_SIGNING_IN_CI=true
                            the release workflow sets it when the signing secrets exist, because it writes
                            key.properties only inside the Android job
  PREFLIGHT_IMAGE           a built API image; when set and docker is present, its /migrations is compared
  PREFLIGHT_WEB=1           also require the web build inputs (FIREBASE_WEB_APP_ID, FIREBASE_AUTH_DOMAIN,
                            WEB_CANONICAL_URL)
Python 3.8+, standard library only.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOBILE = os.path.join(ROOT, "apps/mobile")
API = os.path.join(ROOT, "services/api")
BUNDLE_ID = "app.hiyall.hiyall"


def p(*parts):
    return os.path.join(ROOT, *parts)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def run(cmd, cwd=ROOT, env=None, timeout=900):
    try:
        r = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=timeout)
        return r.returncode, r.stdout
    except FileNotFoundError:
        return 127, "%s: command not found" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "%s: timed out" % " ".join(cmd[:2])


def parse_env_file(path):
    values = {}
    if not os.path.isfile(path):
        return values
    for line in read(path).splitlines():
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            values[m.group(1)] = v
    return values


def is_placeholder(v):
    if v is None or v.strip() == "":
        return True
    u = v.upper()
    low = v.lower()
    return ("<" in v or ">" in v or "REPLACE_ME" in u or "CHANGE-ME" in u or "CHANGE_ME" in u or "YOUR-DOMAIN" in u
            or "TODO" in u or re.search(r"(\.example|example\.(com|org|net)|\.invalid|\.test)(\b|/|$)", low) is not None)


class Gate:
    def __init__(self, gid, title):
        self.id, self.title = gid, title
        self.problems = []  # (message, fix)
        self.notes = []
        self.skipped = None

    def bad(self, message, fix):
        self.problems.append((message, fix))

    def note(self, message):
        self.notes.append(message)


GATES = []


def gate(gid, title):
    def deco(fn):
        GATES.append((gid, title, fn))
        return fn
    return deco


def pubspec_version():
    m = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", read(os.path.join(MOBILE, "pubspec.yaml")), re.M)
    return (m.group(1), m.group(2)) if m else (None, None)


# --------------------------------------------------------------------------------------------------------------
@gate("a", "Git state is releasable")
def gate_git(g):
    rc, out = run(["git", "status", "--porcelain"])
    if rc != 0:
        g.bad("not a git checkout", "run the preflight from a clone of the repository")
        return
    changed = [l for l in out.splitlines() if l.strip()]
    if changed:
        g.bad("working tree has %d uncommitted change(s), e.g. %s" % (len(changed), changed[0].strip()),
              "commit or stash them (git status); a release is built from a commit, not a working tree")
    version, _ = pubspec_version()
    tag = "v%s" % version if version else None
    ref_type, ref_name = os.environ.get("GITHUB_REF_TYPE"), os.environ.get("GITHUB_REF_NAME", "")
    if ref_type == "tag":
        # CI on a tag: the tag must be this version and the commit must be on main.
        if tag and ref_name != tag:
            g.bad("tag %s does not match pubspec version %s (expected %s)" % (ref_name, version, tag),
                  "delete the tag and tag the right commit: git tag %s" % tag)
        rc, _ = run(["git", "merge-base", "--is-ancestor", "HEAD", "origin/main"])
        if rc != 0:
            g.bad("the tagged commit is not on origin/main", "merge to main first, then tag that commit")
        return
    rc, branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    branch = branch.strip()
    if branch == "HEAD" or not branch:
        g.bad("HEAD is detached", "git switch main")
    elif branch != "main" and not branch.startswith("release/"):
        g.bad("on branch %s; releases are tagged from main or release/*" % branch, "git switch main")
    rc, up = run(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
    if rc != 0:
        g.bad("no upstream branch: the release workflow runs on the tag pushed to GitHub",
              "add the remote and push: git remote add origin <url> && git push -u origin %s" % (branch or "main"))
    else:
        rc, ahead = run(["git", "rev-list", "--count", "@{u}..HEAD"])
        if ahead.strip() not in ("", "0"):
            g.bad("%s commit(s) are not pushed to %s" % (ahead.strip(), up.strip()), "git push")
    if tag:
        rc, existing = run(["git", "tag", "--list", tag])
        if existing.strip():
            g.bad("tag %s already exists" % tag, "bump `version:` in apps/mobile/pubspec.yaml (docs/mobile/16-release-and-reliability.md, Versions)")


# --------------------------------------------------------------------------------------------------------------
PLACEHOLDER_RE = re.compile(r"\[(?:[A-Z][A-Z0-9 _/&.,'-]*|OPERATOR:[^\]]*|LEGAL REVIEW:[^\]]*)\](?!\()")
DRAFT_RE = re.compile(r"DRAFT for legal review|^>\s*\*\*DRAFT", re.M)


@gate("b", "Legal documents are final and consistent")
def gate_legal(g):
    docs_dir, assets_dir = p("docs/legal"), p("apps/mobile/assets/legal")
    names = sorted(set(os.listdir(docs_dir)) | set(os.listdir(assets_dir)))
    names = [n for n in names if n.endswith(".md")]
    # docs/legal is the source. The app's copy is scanned only where it differs (an identical copy would repeat every line).
    for d in (docs_dir, assets_dir):
        rel = os.path.relpath(d, ROOT)
        total_tokens, drafts = {}, []
        for n in names:
            path = os.path.join(d, n)
            if not os.path.isfile(path):
                g.bad("%s/%s is missing" % (rel, n), "copy it from the other legal folder (the two must hold identical files)")
                continue
            other = os.path.join(docs_dir if d == assets_dir else assets_dir, n)
            if d == assets_dir and os.path.isfile(other) and read(path) == read(other):
                continue
            text = read(path)
            if DRAFT_RE.search(text):
                drafts.append(n)
            for t in PLACEHOLDER_RE.findall(text):
                if t != "[BRACKETS]":  # the banner's own wording
                    total_tokens.setdefault(n, set()).add(t)
        if drafts:
            g.bad("%s: DRAFT banner still present in %s%s" % (rel, ", ".join(drafts), " (identical copies in apps/mobile/assets/legal)" if d == docs_dir else ""),
                  "after legal review remove the first-line DRAFT banner from each document, in both legal folders")
        for n, tokens in sorted(total_tokens.items()):
            shown = ", ".join(t if len(t) <= 42 else t[:40] + "...]" for t in sorted(tokens)[:6])
            g.bad("%s/%s: %d unfilled placeholder(s): %s%s" % (rel, n, len(tokens), shown, " ..." if len(tokens) > 6 else ""),
                  "fill every [BRACKET] with the operator's real text (company, addresses, dates, periods); copy to apps/mobile/assets/legal; re-run")
    for n in names:
        a, b = os.path.join(docs_dir, n), os.path.join(assets_dir, n)
        if os.path.isfile(a) and os.path.isfile(b) and read(a) != read(b):
            g.bad("docs/legal/%s differs from apps/mobile/assets/legal/%s" % (n, n),
                  "cp docs/legal/%s apps/mobile/assets/legal/%s (docs/legal is the source)" % (n, n))
    versions = {}
    for d in (docs_dir, assets_dir):
        for n in names:
            path = os.path.join(d, n)
            if os.path.isfile(path):
                m = re.search(r"^Version:\s*(\S+)", read(path), re.M)
                versions["%s/%s" % (os.path.relpath(d, ROOT), n)] = m.group(1) if m else None
    dart = re.search(r"kTermsVersion\s*=\s*'([^']+)'", read(p("apps/mobile/lib/core/legal_documents.dart")))
    go = re.search(r'TermsVersion\s*=\s*"([^"]+)"', read(p("services/api/internal/domain/onboarding.go")))
    versions["dart kTermsVersion"] = dart.group(1) if dart else None
    versions["go domain.TermsVersion"] = go.group(1) if go else None
    distinct = set(versions.values())
    if len(distinct) != 1 or None in distinct:
        detail = "; ".join("%s=%s" % (k, v) for k, v in sorted(versions.items()) if v != max(distinct, key=lambda x: list(versions.values()).count(x)))
        g.bad("terms version is not the same everywhere (%s)" % (detail or "a version is missing"),
              "set one version string in every legal document, apps/mobile/lib/core/legal_documents.dart and services/api/internal/domain/onboarding.go")
    g.note("terms version is %s; when the final text is approved, bump it in all three places so existing members re-accept" % (dart.group(1) if dart else "unknown"))


# --------------------------------------------------------------------------------------------------------------
def release_inputs():
    env_name = os.environ.get("HIYALL_RELEASE_ENV", "production")
    path = p("config/mobile-release.%s.local.env" % env_name)
    values = parse_env_file(path)
    for k in list(values) + ["API_BASE_URL", "FIREBASE_PROJECT_ID", "FIREBASE_MESSAGING_SENDER_ID", "FIREBASE_API_KEY",
                             "FIREBASE_ANDROID_APP_ID", "FIREBASE_IOS_APP_ID", "FIREBASE_WEB_APP_ID", "FIREBASE_AUTH_DOMAIN",
                             "SENTRY_DSN", "SUPPORT_EMAIL", "SAFETY_EMAIL", "PRIVACY_EMAIL", "APP_STORE_URL", "PLAY_STORE_URL",
                             "WEB_CANONICAL_URL", "APP_VERSION", "FIREBASE_IOS_BUNDLE_ID", "ENABLE_DEV_LOGIN"]:
        if os.environ.get(k):  # the environment wins, as in scripts/build-release.sh
            values[k] = os.environ[k]
    return env_name, path, values


@gate("c", "Mobile release inputs (dart-defines) are complete")
def gate_mobile_env(g):
    env_name, path, v = release_inputs()
    rel = os.path.relpath(path, ROOT)
    if not os.path.isfile(path) and not v:
        g.bad("%s does not exist and no release variables are set" % rel,
              "cp config/mobile-release.example.env %s and fill it (docs/mobile/16-release-and-reliability.md, Building a release)" % rel)
    flagged = set()

    def need(name, why, fix=None, check=None):
        val = v.get(name, "")
        if not val or is_placeholder(val) or (check and not check(val)):
            flagged.add(name)
            g.bad("%s is %s (%s)" % (name, "missing" if not val else "a placeholder or invalid", why),
                  fix or "set %s in %s" % (name, rel))

    def https(val):
        return val.startswith("https://") and not re.search(r"localhost|127\.0\.0\.1|10\.0\.2\.2", val)

    need("API_BASE_URL", "the production API address", "set API_BASE_URL=https://api.<your-real-domain> in %s" % rel, https)
    if "staging" in v.get("API_BASE_URL", "") and env_name == "production":
        flagged.add("API_BASE_URL")
        g.bad("API_BASE_URL points at staging in the production release file", "use the production API address")
    need("FIREBASE_PROJECT_ID", "production Firebase project")
    need("FIREBASE_MESSAGING_SENDER_ID", "Firebase Project settings > Cloud Messaging")
    need("FIREBASE_API_KEY", "Firebase Project settings > General > Web API key")
    need("FIREBASE_ANDROID_APP_ID", "Firebase app id of the Android app", "register app.hiyall.hiyall in Firebase and copy its app id")
    need("FIREBASE_IOS_APP_ID", "Firebase app id of the iOS app", "register the iOS app app.hiyall.hiyall in Firebase and copy its app id")
    need("SENTRY_DSN", "a release without crash reporting is blind", "create the Sentry project and set its DSN (a secret in CI)",
         lambda x: x.startswith("https://") and "@" in x)
    need("APP_STORE_URL", "the Update screen opens it", "set the App Store product URL once the app record exists",
         lambda x: x.startswith("https://apps.apple.com/") and "REPLACE" not in x.upper())
    need("PLAY_STORE_URL", "the Update screen opens it", "set https://play.google.com/store/apps/details?id=%s" % BUNDLE_ID,
         lambda x: x.startswith("https://play.google.com/"))
    for name in ("SUPPORT_EMAIL", "SAFETY_EMAIL", "PRIVACY_EMAIL"):
        need(name, "shown in Help & Safety; Apple tests it", "create the mailbox and set a real address",
             lambda x: re.match(r"^[^@\s<>]+@[^@\s<>]+\.[a-z]{2,}$", x) is not None)
    if v.get("ENABLE_DEV_LOGIN", "").lower() == "true":
        g.bad("ENABLE_DEV_LOGIN=true is set", "remove it; development login must never ship")
    if os.environ.get("PREFLIGHT_WEB") == "1":
        need("FIREBASE_WEB_APP_ID", "web build")
        need("FIREBASE_AUTH_DOMAIN", "web build")
        need("WEB_CANONICAL_URL", "web build canonical URL", None, lambda x: x.startswith("https://") and x.endswith("/"))
    version, _ = pubspec_version()
    if v.get("APP_VERSION") and version and v["APP_VERSION"] != version:
        g.bad("APP_VERSION %s differs from pubspec version %s" % (v["APP_VERSION"], version), "remove APP_VERSION from the release env or bump pubspec.yaml")
    # What the build script itself refuses, so the two can never disagree.
    env = dict(os.environ)
    env.update(v)
    env.setdefault("APP_BUILD_NUMBER", "1")
    env["HIYALL_RELEASE_ENV"] = env_name
    seen = set()
    for platform in ("android", "ios"):
        rc, out = run([p("scripts/build-release.sh"), platform, "--check"], env=env)
        if rc != 0:
            for line in out.splitlines():
                m = re.match(r"^\s+- (.*)$", line)
                if m and m.group(1) not in seen and not any(n in m.group(1) for n in flagged):
                    seen.add(m.group(1))
                    g.bad("build-release.sh %s refuses: %s" % (platform, m.group(1)), "see docs/mobile/16-release-and-reliability.md, Building a release")
    g.note("config for the Android and iOS apps is checked; keep build/symbols and upload it to Sentry with every release")


# --------------------------------------------------------------------------------------------------------------
def go_env():
    env = dict(os.environ)
    if not shutil.which("go"):
        rc, out = run(["bash", "-c", 'source "%s/scripts/env.sh" >/dev/null 2>&1; printf %%s "$PATH"' % ROOT])
        if rc == 0 and out:
            env["PATH"] = out
    return env


DEV_BUCKETS = ("hiyall", "hiyall-chat", "hiyall-media")


@gate("d", "Production API environment passes the server's own validation")
def gate_api_env(g):
    path = os.environ.get("HIYALL_API_ENV_FILE") or p("config/api.production.env")
    rel = os.path.relpath(path, ROOT)
    rel = path if rel.startswith("..") else rel
    if not os.path.isfile(path):
        g.bad("%s does not exist" % rel,
              "copy config/api.production.example.env (plus the secrets listed in docs/deployment/10-deploy-guide.md section 3) to %s; it is git-ignored. "
              "Or run `api check-config -release` on the deployed machine (runbook step 3)" % rel)
        return
    values = parse_env_file(path)
    secrets_dir = os.environ.get("PREFLIGHT_SECRETS_DIR") or p("config/secrets")
    for k, val in list(values.items()):
        if k.endswith("_FILE") and val.startswith("/secrets/"):
            values[k] = os.path.join(secrets_dir, val[len("/secrets/"):])
    env = go_env()
    clean = {"PATH": env.get("PATH", ""), "HOME": env.get("HOME", ""), "GOCACHE": env.get("GOCACHE", ""), "GOFLAGS": env.get("GOFLAGS", "")}
    clean = {k: x for k, x in clean.items() if x}
    for k in ("GOPATH", "GOMODCACHE", "GOROOT", "TMPDIR"):
        if env.get(k):
            clean[k] = env[k]
    tmp = tempfile.mkdtemp(prefix="hiyall-preflight-")
    try:
        binary = os.path.join(tmp, "api")
        rc, out = run(["go", "build", "-o", binary, "./cmd/api"], cwd=API, env=env)
        if rc != 0:
            last = out.strip().splitlines()[-1] if out.strip() else "go build failed"
            g.bad("could not build the API to run its config check: %s" % last, "install the Go toolchain (source scripts/env.sh) and fix the build")
            return
        run_env = dict(clean)
        run_env.update(values)
        rc, out = run([binary, "check-config", "-release"], env=run_env)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for line in out.splitlines():
        if line.startswith("problem: "):
            g.bad(line[len("problem: "):], "set it in %s (rules: docs/deployment/10-deploy-guide.md section 3, infrastructure/docker/api.example.env)" % rel)
        elif line.startswith("warning: "):
            g.note(line[len("warning: "):])
    if rc not in (0, 1):
        g.bad("api check-config exited %d: %s" % (rc, out.strip()[-200:]), "run it by hand: go run ./cmd/api check-config -release")
    for name in ("MEDIA_BUCKET", "CHAT_MEDIA_BUCKET"):
        if values.get(name, "") in DEV_BUCKETS:
            g.bad("%s=%s is a development bucket" % (name, values[name]),
                  "create the production buckets (docs/deployment/11-environments.md) and use them; never share the development ones")
    _, _, mobile = release_inputs()
    if mobile.get("FIREBASE_PROJECT_ID") and values.get("FIREBASE_PROJECT_ID") and mobile["FIREBASE_PROJECT_ID"] != values["FIREBASE_PROJECT_ID"]:
        g.bad("FIREBASE_PROJECT_ID differs between the API (%s) and the mobile release inputs (%s)" % (values["FIREBASE_PROJECT_ID"], mobile["FIREBASE_PROJECT_ID"]),
              "make both name the same production Firebase project")


# --------------------------------------------------------------------------------------------------------------
@gate("e", "Android release signing is set up and cannot fall back to debug")
def gate_android_signing(g):
    props = p("apps/mobile/android/key.properties")
    if os.path.isfile(props):
        v = parse_properties(props)
        missing = [k for k in ("storeFile", "storePassword", "keyAlias", "keyPassword") if not v.get(k)]
        if missing:
            g.bad("android/key.properties lacks %s" % ", ".join(missing), "add them (see docs/mobile/16-release-and-reliability.md, Android signing)")
        elif not os.path.isfile(v["storeFile"]) and not os.path.isfile(os.path.join(MOBILE, "android/app", v["storeFile"])):
            g.bad("android/key.properties storeFile does not exist", "point storeFile at the upload keystore (an absolute path is safest)")
    elif os.environ.get("PREFLIGHT_ANDROID_SIGNING_IN_CI") == "true":
        g.note("signing secrets are present in CI; key.properties is written by the Android job")
    elif os.environ.get("PREFLIGHT_ANDROID_SIGNING_IN_CI") == "false":
        g.bad("ANDROID_KEYSTORE_BASE64 is not set in GitHub secrets", "add the upload keystore secrets (docs/deployment/11-environments.md item 9)")
    else:
        g.bad("apps/mobile/android/key.properties is missing",
              "create the upload keystore and key.properties (docs/mobile/16-release-and-reliability.md, Android signing); it is git-ignored")
    gradle = read(p("apps/mobile/android/app/build.gradle.kts"))
    if "Release signing is not configured" not in gradle:
        g.bad("build.gradle.kts no longer refuses a release build without key.properties", "restore the GradleException guard")
    if re.search(r'signingConfigs\.getByName\("debug"\)|signingConfig\s*=\s*signingConfigs\.debug', gradle):
        g.bad("the release build type uses the debug signing config", "remove it; releases are signed with the release key only")
    if not re.search(r"isMinifyEnabled\s*=\s*true", gradle) or not os.path.isfile(p("apps/mobile/android/app/proguard-rules.pro")):
        g.bad("R8 shrinking or proguard-rules.pro is missing", "restore isMinifyEnabled = true and apps/mobile/android/app/proguard-rules.pro")


def parse_properties(path):
    out = {}
    for line in read(path).splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, _, val = line.partition("=")
            out[k.strip()] = val.strip()
    return out


# --------------------------------------------------------------------------------------------------------------
@gate("f", "Version and bundle identifiers agree on Android and iOS")
def gate_ids(g):
    version, build = pubspec_version()
    if not version:
        g.bad("apps/mobile/pubspec.yaml has no `version: MAJOR.MINOR.PATCH+BUILD`", "set it, for example 1.0.0+1")
    elif int(version.split(".")[0]) < 1:
        g.bad("pubspec version %s is a pre-release number" % version, "set `version: 1.0.0+1` in apps/mobile/pubspec.yaml")
    gradle = read(p("apps/mobile/android/app/build.gradle.kts"))
    ns = re.search(r'namespace\s*=\s*"([^"]+)"', gradle)
    app = re.search(r'applicationId\s*=\s*"([^"]+)"', gradle)
    ids = {"gradle namespace": ns and ns.group(1), "gradle applicationId": app and app.group(1)}
    kt = glob.glob(p("apps/mobile/android/app/src/main/kotlin/**/MainActivity.kt"), recursive=True)
    if kt:
        pk = re.search(r"^package\s+(\S+)", read(kt[0]), re.M)
        ids["MainActivity package"] = pk and pk.group(1)
        rel_dir = os.path.relpath(os.path.dirname(kt[0]), p("apps/mobile/android/app/src/main/kotlin")).replace(os.sep, ".")
        ids["MainActivity directory"] = rel_dir
    pbx = read(p("apps/mobile/ios/Runner.xcodeproj/project.pbxproj"))
    runner_ids = set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", pbx))
    runner_ids = {i for i in runner_ids if not i.endswith(".RunnerTests")}
    ids["iOS PRODUCT_BUNDLE_IDENTIFIER"] = ", ".join(sorted(runner_ids)) or None
    m = re.search(r'e\.get\("FIREBASE_IOS_BUNDLE_ID", "([^"]+)"\)', read(p("scripts/build-release.sh")))
    ids["build-release.sh default FIREBASE_IOS_BUNDLE_ID"] = m.group(1) if m else None
    bad = {k: v for k, v in ids.items() if v != BUNDLE_ID}
    if bad:
        g.bad("identifier mismatch (expected %s): %s" % (BUNDLE_ID, "; ".join("%s=%s" % kv for kv in sorted(bad.items()))),
              "make every Android and iOS identifier equal; the id is permanent once published")
    mobile_id = release_inputs()[2].get("FIREBASE_IOS_BUNDLE_ID")
    if mobile_id and mobile_id != BUNDLE_ID:
        g.bad("FIREBASE_IOS_BUNDLE_ID=%s differs from %s" % (mobile_id, BUNDLE_ID), "remove it or set it to %s" % BUNDLE_ID)
    if "flutter.versionCode" not in gradle or "flutter.versionName" not in gradle:
        g.bad("Android versionCode/versionName no longer come from Flutter", "use flutter.versionCode and flutter.versionName in build.gradle.kts")
    plist = read(p("apps/mobile/ios/Runner/Info.plist"))
    for key, want in (("CFBundleShortVersionString", "$(FLUTTER_BUILD_NAME)"), ("CFBundleVersion", "$(FLUTTER_BUILD_NUMBER)"), ("CFBundleDisplayName", "Hiyall")):
        m = re.search(r"<key>%s</key>\s*<string>([^<]*)</string>" % key, plist)
        if not m or m.group(1) != want:
            g.bad("Info.plist %s is %s, expected %s" % (key, m.group(1) if m else "missing", want), "set it in apps/mobile/ios/Runner/Info.plist")
    if not re.search(r"<key>ITSAppUsesNonExemptEncryption</key>\s*<true/>", plist):
        g.bad("Info.plist ITSAppUsesNonExemptEncryption is not true", "the app ships its own end-to-end encryption; see docs/mobile/16-release-and-reliability.md, Export compliance")
    modes = re.search(r"<key>UIBackgroundModes</key>\s*<array>(.*?)</array>", plist, re.S)
    if not modes or re.findall(r"<string>([^<]*)</string>", modes.group(1)) != ["remote-notification"]:
        g.bad("UIBackgroundModes is not exactly [remote-notification]", "remove other background modes; App Review asks for a reason for each")
    for key in ("NSLocationWhenInUseUsageDescription", "NSPhotoLibraryUsageDescription", "NSCameraUsageDescription"):
        m = re.search(r"<key>%s</key>\s*<string>([^<]*)</string>" % key, plist)
        if not m or len(m.group(1).strip()) < 20:
            g.bad("Info.plist %s is missing or too short" % key, "write an honest one-sentence purpose")
    if not os.path.isfile(p("apps/mobile/ios/Runner/PrivacyInfo.xcprivacy")):
        g.bad("ios/Runner/PrivacyInfo.xcprivacy is missing", "restore it (docs/mobile/store-listing.md, Privacy manifest)")
    ent = read(p("apps/mobile/ios/Runner/Runner.entitlements"))
    if "aps-environment" not in ent:
        g.bad("Runner.entitlements has no aps-environment", "enable the Push Notifications capability in Xcode")
    g.note("aps-environment is 'development' in the repo; Xcode writes 'production' into the archive's signed entitlements (App Store distribution profile)")
    for path, label in (("apps/mobile/pubspec.yaml", "pubspec.yaml"), ("apps/mobile/ios/Runner/Info.plist", "Info.plist"), ("apps/mobile/android/app/build.gradle.kts", "build.gradle.kts")):
        if re.search(r"(?<![\d.])0\.1\.0(?![\d.])", read(p(path))):
            g.bad("%s still contains 0.1.0" % label, "remove the pre-release version")


# --------------------------------------------------------------------------------------------------------------
@gate("g", "Icons and launch assets are present")
def gate_icons(g):
    icon_dir = p("apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset")
    try:
        images = json.loads(read(os.path.join(icon_dir, "Contents.json")))["images"]
    except Exception:
        g.bad("AppIcon.appiconset/Contents.json is unreadable", "restore it from git")
        images = []
    names = [i.get("filename") for i in images]
    if not any(i.get("idiom") == "ios-marketing" for i in images):
        g.bad("AppIcon has no 1024x1024 ios-marketing entry", "add it; App Store Connect requires the 1024 icon")
    for n in names:
        f = os.path.join(icon_dir, n or "")
        if not n or not os.path.isfile(f):
            g.bad("iOS icon file %s is missing" % n, "flutter test tool/export_brand_assets_test.dart (run in apps/mobile) regenerates every size")
        elif b"\x89PNG" == open(f, "rb").read(4) and png_has_alpha(f):
            g.bad("iOS icon %s has an alpha channel (App Store rejects it)" % n, "regenerate with tool/export_brand_assets_test.dart (writes opaque RGB)")
    res = p("apps/mobile/android/app/src/main/res")
    needed = ["mipmap-%s/ic_launcher.png" % d for d in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")]
    needed += ["mipmap-anydpi-v26/ic_launcher.xml", "drawable/ic_launcher_foreground.xml", "drawable/ic_launcher_monochrome.xml",
               "drawable/ic_stat_hiyall.xml", "drawable/splash_icon.xml", "drawable/launch_background.xml", "values/colors.xml", "values-v31/styles.xml"]
    for n in needed:
        if not os.path.isfile(os.path.join(res, n)):
            g.bad("Android resource %s is missing" % n, "restore it from git (docs/mobile/16-release-and-reliability.md, Android)")
    manifest = read(p("apps/mobile/android/app/src/main/AndroidManifest.xml"))
    for ref in ("@mipmap/ic_launcher", "default_notification_icon", "ic_stat_hiyall"):
        if ref not in manifest:
            g.bad("AndroidManifest.xml does not reference %s" % ref, "restore the launcher icon and FCM notification icon entries")
    launch = p("apps/mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset")
    if not glob.glob(os.path.join(launch, "LaunchImage*.png")):
        g.bad("iOS LaunchImage PNGs are missing", "run tool/export_brand_assets_test.dart")
    for n in ("favicon.png", "icons/Icon-192.png", "icons/Icon-512.png", "icons/Icon-maskable-192.png", "icons/Icon-maskable-512.png", "hiyall.svg", "robots.txt"):
        if not os.path.isfile(p("apps/mobile/web", n)):
            g.bad("web/%s is missing" % n, "restore it from git")
    html = read(p("apps/mobile/web/index.html"))
    for marker in ('rel="canonical"', 'property="og:title"', 'name="description"', 'name="theme-color"'):
        if marker not in html:
            g.bad("web/index.html lacks %s" % marker, "restore the SEO/Open Graph block")
    g.note("Play also needs, in the console: a 512x512 icon, a 1024x500 feature graphic and phone screenshots; the App Store needs screenshots. They cannot come from the repo")


def png_has_alpha(path):
    with open(path, "rb") as f:
        head = f.read(26)
    return len(head) >= 26 and head[25] in (4, 6)  # colour type: 4 grey+alpha, 6 RGBA


# --------------------------------------------------------------------------------------------------------------
@gate("h", "Owner placeholders are gone from CODEOWNERS and SECURITY.md")
def gate_owner(g):
    for rel, fix in ((".github/CODEOWNERS", "replace @OWNER-PLACEHOLDER with the real GitHub user or team"),
                     ("SECURITY.md", "set the real security contact (email or GitHub private reporting link)")):
        text = read(p(rel))
        hits = [i + 1 for i, line in enumerate(text.splitlines()) if "OWNER-PLACEHOLDER" in line and not line.lstrip().startswith("#")]
        hits += [i + 1 for i, line in enumerate(text.splitlines()) if re.search(r"<OWNER\b", line)]
        if hits:
            g.bad("%s still has an owner placeholder (line %s)" % (rel, ", ".join(str(h) for h in sorted(set(hits))[:5])), fix)


# --------------------------------------------------------------------------------------------------------------
LISTING_MARKER_RE = re.compile(r"\bTODO\b|\bTBD\b|\bFIXME\b|PLACEHOLDER|REPLACE_ME|not built yet|<[A-Z][A-Za-z0-9 _/-]*>")


@gate("i", "Store listing document is completed")
def gate_listing(g):
    path = p("docs/mobile/store-listing.md")
    hits = []
    for i, line in enumerate(read(path).splitlines(), 1):
        if LISTING_MARKER_RE.search(line):
            hits.append((i, line.strip()))
    if hits:
        shown = "; ".join("line %d" % n for n, _ in hits[:8])
        g.bad("docs/mobile/store-listing.md has %d unfinished marker(s) (%s%s)" % (len(hits), shown, ", ..." if len(hits) > 8 else ""),
              "fill each TODO in the 'Listing fields' section and resolve every 'not built yet' item, then remove the marker")
        g.note("first: line %d: %s" % (hits[0][0], hits[0][1][:110]))


# --------------------------------------------------------------------------------------------------------------
@gate("j", "Migrations are in order and the image ships all of them")
def gate_migrations(g):
    files = sorted(os.path.basename(f) for f in glob.glob(p("database/migrations/*.sql")))
    nums = [re.match(r"^(\d{4})_", f) for f in files]
    if not files or not all(nums):
        g.bad("database/migrations has no files or a badly named one", "name files NNNN_description.sql")
        return
    numbers = [int(m.group(1)) for m in nums]
    if numbers != list(range(1, len(numbers) + 1)):
        gaps = sorted(set(range(1, max(numbers) + 1)) - set(numbers))
        g.bad("migration numbers are not contiguous from 0001 (gaps: %s; duplicates: %s)" % (gaps[:5], sorted({n for n in numbers if numbers.count(n) > 1})[:5]),
              "renumber so each file has the next free number (applied files must never be edited or renamed after release)")
    docker = read(p("services/api/Dockerfile"))
    if not re.search(r"^COPY\s+database/migrations\s+/migrations\s*$", docker, re.M):
        g.bad("services/api/Dockerfile no longer copies database/migrations to /migrations", "restore `COPY database/migrations /migrations`")
    ignore = read(p(".dockerignore")) if os.path.isfile(p(".dockerignore")) else ""
    if "!database/migrations/" not in ignore and ignore.strip():
        g.bad(".dockerignore excludes database/migrations from the build context", "add `!database/migrations/`")
    image = os.environ.get("PREFLIGHT_IMAGE")
    if image and shutil.which("docker"):
        rc, out = run(["docker", "run", "--rm", "--entrypoint", "/bin/ls", image, "/migrations"])
        # the image is distroless: it has no ls; fall back to a create+cp listing
        if rc != 0:
            cid = run(["docker", "create", image])[1].strip()
            tmp = tempfile.mkdtemp(prefix="hiyall-mig-")
            run(["docker", "cp", "%s:/migrations/." % cid, tmp])
            run(["docker", "rm", cid])
            out = "\n".join(sorted(os.listdir(tmp)))
            shutil.rmtree(tmp, ignore_errors=True)
        shipped = sorted(x for x in out.split() if x.endswith(".sql"))
        if shipped != files:
            g.bad("image %s ships %s, repository has %s" % (image, shipped[-1:] or "nothing", files[-1]), "rebuild the image from this commit")
    else:
        g.note("highest migration is %s; set PREFLIGHT_IMAGE=<built image> to compare it with the image's /migrations" % files[-1])


# --------------------------------------------------------------------------------------------------------------
@gate("k", "OpenAPI contract is up to date")
def gate_openapi(g):
    tmp = tempfile.mkdtemp(prefix="hiyall-contract-")
    try:
        os.makedirs(os.path.join(tmp, "scripts"))
        os.makedirs(os.path.join(tmp, "docs/api"))
        shutil.copy(p("scripts/build_foundation_contract.py"), os.path.join(tmp, "scripts/"))
        shutil.copy(p("docs/api/openapi-mvp.json"), os.path.join(tmp, "docs/api/"))
        rc, out = run([sys.executable, os.path.join(tmp, "scripts/build_foundation_contract.py")], cwd=tmp)
        if rc != 0:
            g.bad("build_foundation_contract.py failed: %s" % out.strip()[-160:], "run python3 scripts/build_foundation_contract.py and fix the error")
            return
        generated = os.path.join(tmp, "docs/api/openapi-foundation.json")
        if read(generated) != read(p("docs/api/openapi-foundation.json")):
            g.bad("docs/api/openapi-foundation.json is out of date with scripts/build_foundation_contract.py",
                  "npm run contracts:build, then commit docs/api/openapi-foundation.json and packages/api-contracts/foundation.d.ts")
            return
        ts = p("node_modules/.bin/openapi-typescript")
        if os.path.isfile(ts):
            out_ts = os.path.join(tmp, "foundation.d.ts")
            rc, _ = run([ts, generated, "-o", out_ts])
            if rc == 0 and read(out_ts) != read(p("packages/api-contracts/foundation.d.ts")):
                g.bad("packages/api-contracts/foundation.d.ts is out of date", "npm run contracts:build and commit the result")
        else:
            g.note("openapi-typescript is not installed (npm ci): the TypeScript contract was not compared")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------------------------------------------
@gate("l", "go vet is clean and no known vulnerabilities are reachable")
def gate_go(g):
    env = go_env()
    rc, out = run(["go", "vet", "./..."], cwd=API, env=env)
    if rc == 127:
        g.bad("go is not installed", "source scripts/env.sh (or install Go from toolchains.lock.json)")
        return
    if rc != 0:
        g.bad("go vet reports problems: %s" % " | ".join(out.strip().splitlines()[:3]), "cd services/api && go vet ./... and fix them")
    govuln = shutil.which("govulncheck", path=env.get("PATH"))
    if govuln:
        rc, out = run([govuln, "./..."], cwd=API, env=env)
        if rc != 0:
            g.bad("govulncheck found reachable vulnerabilities: %s" % " | ".join(out.strip().splitlines()[-3:]), "cd services/api && govulncheck ./... and update the module")
    else:
        g.note("govulncheck is not installed: skipped (go install golang.org/x/vuln/cmd/govulncheck@latest)")


# --------------------------------------------------------------------------------------------------------------
@gate("m", "Release workflow uses no development script or example env")
def gate_workflow(g):
    text = read(p(".github/workflows/release.yml"))
    for pattern, what in ((r"scripts/dev/", "scripts/dev"), (r"dev-(api|mobile|admin|storage)\.sh", "a dev-*.sh script"), (r"seed-demo", "a demo seed"),
                          (r"\.example\.env", "an example env file"), (r"\.local\.env", "a local env file"), (r"ENABLE_DEV", "a development switch")):
        m = re.search(pattern, "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#")))
        if m:
            g.bad("release.yml references %s (%s)" % (what, m.group(0)), "release workflows may only call scripts/build-release.sh and scripts/release-preflight.sh")
    if "release-preflight" not in text:
        g.bad("release.yml has no release-preflight job", "add the job that runs scripts/release-preflight.sh before the builds")


# --------------------------------------------------------------------------------------------------------------
def main():
    skip = {s.strip() for s in os.environ.get("PREFLIGHT_SKIP", "").split(",") if s.strip()}
    version, build = pubspec_version()
    rc, head = run(["git", "rev-parse", "--short", "HEAD"])
    print("Hiyall release preflight: version %s+%s, commit %s" % (version, build, head.strip() if rc == 0 else "unknown"))
    print("It only gates; scripts/check.sh runs the test suites. Fix every [FAIL], then run it again.\n")
    unmet, skipped = [], []
    for gid, title, fn in GATES:
        g = Gate(gid, title)
        if gid in skip:
            print("[SKIP] (%s) %s" % (gid, title))
            print("       SKIPPED on purpose (PREFLIGHT_SKIP): this gate is NOT verified by this run")
            skipped.append(gid)
            continue
        try:
            fn(g)
        except Exception as e:  # a crashing gate must fail, never pass
            g.bad("the gate crashed: %s: %s" % (type(e).__name__, e), "fix scripts/release_preflight.py")
        print("[%s] (%s) %s" % ("FAIL" if g.problems else "PASS", gid, title))
        for msg, fix in g.problems:
            print("       - %s" % msg)
            print("         fix: %s" % fix)
        for n in g.notes:
            print("       note: %s" % n)
        if g.problems:
            unmet.append(gid)
    print()
    if skipped:
        print("Skipped gates (not verified): %s" % ", ".join(skipped))
    if unmet:
        print("RELEASE BLOCKED: %d of %d gates unmet (%s)." % (len(unmet), len(GATES), ", ".join(unmet)))
        return 1
    print("All %d gates passed%s." % (len(GATES) - len(skipped), " (%d skipped)" % len(skipped) if skipped else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
