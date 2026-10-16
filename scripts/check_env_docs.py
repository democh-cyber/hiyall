#!/usr/bin/env python3
"""Env-completeness check: every environment variable the Go code reads is documented in an example env file, and
no example file names a variable the code does not read.

  python3 scripts/check_env_docs.py        exit 0 when they agree, 1 with a list of the drift

How the code's variables are found (no Go toolchain needed):
  * the string literals that look like variable names (UPPER_SNAKE, at least one underscore) in the configuration
    loaders (services/api/internal/config, services/api/internal/admin/config.go, services/api/cmd/*/*.go that
    read the environment), and
  * every Getenv("X") / getenv("X") / LookupEnv("X") call anywhere in non-test Go code.
Where each must be documented:
  * ADMIN_*                      infrastructure/docker/admin.example.env (the full list) and config/admin.production.example.env
  * every other variable         infrastructure/docker/api.example.env (also covers cmd/migrate and cmd/moderate)
A variable is "documented" when a line `NAME=` or `# NAME=` exists in the file. The reverse direction: a variable
named that way in any example env under config/ or infrastructure/docker/ must be read by the code, or be one of
NON_GO (platform variables that the Go code does not read, such as GOMEMLIMIT).
Python 3.8+, standard library only. Used by scripts/release_preflight.py (gate p) and the Foundation workflow.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Literals that look like variable names but are not.
# TEST_DATABASE_URL is read by internal/dbtest, the helper of the Go tests; it is never part of a deployed environment.
NOT_ENV = {"CHANGE_ME", "REPLACE_ME", "TEST_DATABASE_URL"}
# Read by the Go runtime or the platform, not by our code, but legitimately in the example files.
NON_GO = {"GOMEMLIMIT", "GOGC"}
LITERAL = re.compile(r'"([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)"')
CALL = re.compile(r'(?:Getenv|getenv|LookupEnv)\("([A-Z][A-Z0-9_]+)"\)')
CONFIG_FILE = re.compile(r"(^|/)(internal/config/[^/]+|internal/admin/config|cmd/[a-z]+/(main|ops|checkconfig|retention|trust))\.go$")
DECL = re.compile(r"(?m)^\s*#?\s*([A-Z][A-Z0-9_]{2,})=")

API_DOC = "infrastructure/docker/api.example.env"
ADMIN_DOCS = ("infrastructure/docker/admin.example.env", "config/admin.production.example.env")
ALL_DOCS = ("infrastructure/docker/api.example.env", "infrastructure/docker/admin.example.env", "config/admin.production.example.env",
            "config/api.production.example.env", "config/api.staging.example.env", "config/migrate.production.example.env", "config/migrate.staging.example.env",
            "config/chat-media.example.env", "config/media.example.env")


def read(rel, root=ROOT):
    try:
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def go_variables(root=ROOT):
    names = set()
    for path in glob.glob(os.path.join(root, "services/api/**/*.go"), recursive=True):
        if path.endswith("_test.go"):
            continue
        rel = os.path.relpath(path, root).replace(os.sep, "/")[len("services/api/"):]
        text = read(os.path.relpath(path, root), root) or ""
        names |= set(CALL.findall(text))
        if CONFIG_FILE.search(rel):
            names |= set(LITERAL.findall(text))
    return names - NOT_ENV


def drift(root=ROOT, names=None):
    """Return a list of human-readable problems (empty when documentation and code agree)."""
    problems = []
    names = go_variables(root) if names is None else names
    declared = {}
    for rel in ALL_DOCS:
        text = read(rel, root)
        if text is None:
            problems.append("%s is missing" % rel)
            declared[rel] = set()
        else:
            declared[rel] = set(DECL.findall(text))
    for n in sorted(names):
        homes = ADMIN_DOCS if n.startswith("ADMIN_") else (API_DOC,)
        for rel in homes:
            if n not in declared.get(rel, set()):
                problems.append("%s is read by the code but not documented in %s (add a `# %s=` line with its rule)" % (n, rel, n))
    for rel, found in sorted(declared.items()):
        for n in sorted(found - names - NON_GO):
            problems.append("%s names %s, which no Go code reads (stale or misspelled)" % (rel, n))
    return problems


def main():
    problems = drift()
    if problems:
        print("environment variable drift between the Go code and the example env files:")
        for p in problems:
            print("  - " + p)
        return 1
    print("env docs agree with the code (%d variables)" % len(go_variables()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
