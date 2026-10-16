#!/usr/bin/env python3
"""Proves that the manual-signing settings written by scripts/build-release.sh landed on the Runner target and nowhere else.

  xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release -showBuildSettings > settings.txt
  python3 scripts/ios_signing_check.py settings.txt <team id> <profile name>

The settings come from ios/Flutter/Signing.xcconfig, which only the Runner target includes (through Release.xcconfig).
Anything else in the build (Swift package targets, resource bundles) cannot take a provisioning profile, so a
PROVISIONING_PROFILE_SPECIFIER on any other target is an error too. Exit 0 when right, 1 with the reasons. Python 3.8+.
"""
import re
import sys


def parse_build_settings(text):
    """{target name: {setting: value}} from `xcodebuild -showBuildSettings` output."""
    targets, current = {}, None
    for line in text.splitlines():
        m = re.match(r"^Build settings for action \S+ and target (.+?):\s*$", line)
        if m:
            current = targets.setdefault(m.group(1), {})
            continue
        m = re.match(r"^\s{4}([A-Za-z0-9_\[\]=*,. -]+?) = (.*)$", line)
        if m and current is not None:
            current[m.group(1)] = m.group(2).strip()
    return targets


def problems(text, team, profile):
    targets = parse_build_settings(text)
    out = []
    runner = targets.get("Runner")
    if runner is None:
        return ["no target named Runner in the build settings (found: %s)" % (", ".join(sorted(targets)) or "none")]
    for key, want in (("CODE_SIGN_STYLE", "Manual"), ("DEVELOPMENT_TEAM", team), ("PROVISIONING_PROFILE_SPECIFIER", profile),
                      ("CODE_SIGN_IDENTITY", "Apple Distribution")):
        if runner.get(key) != want:
            out.append("Runner %s is %r, expected %r" % (key, runner.get(key), want))
    for name, settings in sorted(targets.items()):
        if name != "Runner" and settings.get("PROVISIONING_PROFILE_SPECIFIER"):
            out.append("target %s also has a provisioning profile (%s): the signing settings leaked past the Runner target" % (name, settings["PROVISIONING_PROFILE_SPECIFIER"]))
    return out


def main(argv):
    if len(argv) != 4:
        print("usage: ios_signing_check.py <build-settings-file> <team id> <profile name>", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8", errors="replace") as f:
        found = problems(f.read(), argv[2], argv[3])
    for p in found:
        print("ios signing: " + p, file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(main(sys.argv))
