#!/usr/bin/env python3
"""Decides the scope of the required app jobs `app-ios` and `app-macos` (.github/workflows/app.yml,
docs/development/index.md, "GitHub Actions macOS") from the files a pull request changes.

    docs   every changed file is a docs or process file: the jobs skip build and tests
    full   anything else, any file this script does not know, no files, or a diff that cannot be read:
           the jobs run the full Default plan

If in doubt, the answer is `full`. Docs and process files are `docs/**`, `*.md` anywhere,
`.github/ISSUE_TEMPLATE/**` and `.github/labels.json`.

    python3 scripts/app-scope.py --base <sha> --head <sha>   # prints docs or full, and appends
                                                             # `scope=<value>` to $GITHUB_OUTPUT if set
    python3 scripts/app-scope.py --full                      # push, schedule: always full
    python3 scripts/app-scope.py --self-test
"""
import argparse
import os
import subprocess
import sys
import tempfile

DOCS_PREFIXES = ("docs/", ".github/ISSUE_TEMPLATE/")
DOCS_FILES = (".github/labels.json",)
DOCS_SUFFIXES = (".md",)


def is_docs(path: str) -> bool:
    return path.startswith(DOCS_PREFIXES) or path in DOCS_FILES or path.endswith(DOCS_SUFFIXES)


def scope(files) -> str:
    """`docs` only for a non-empty list of docs files; everything else is `full`."""
    files = [f for f in files if f]
    if not files:
        return "full"
    return "docs" if all(is_docs(f) for f in files) else "full"


def changed_files(base: str, head: str, cwd: str = "."):
    """The files the head changed since its merge base with `base`, renames as delete and add, so
    both the old and the new path count. None when git fails."""
    result = subprocess.run(
        ["git", "diff", "--name-only", "-z", "--no-renames", f"{base}...{head}"],
        cwd=cwd, capture_output=True, check=False)
    if result.returncode != 0:
        return None
    return [p.decode("utf-8", "surrogateescape") for p in result.stdout.split(b"\0") if p]


def decide(base, head, cwd: str = ".") -> str:
    if not base or not head:
        return "full"
    files = changed_files(base, head, cwd)
    return "full" if files is None else scope(files)


def self_test() -> None:
    docs = ["docs/development/index.md", "README.md", "CLAUDE.md", ".claude/HANDOVER.md", "Packages/X/README.md",
            ".github/ISSUE_TEMPLATE/bug.yml", ".github/labels.json", "docs/img/a.png"]
    for path in docs:
        assert is_docs(path), path
    code = ["Dokumentum/App.swift", "scripts/app-scope.py", ".github/workflows/app.yml", ".github/actions/a/action.yml",
            "TestPlans/Default.xctestplan", "Config/Project.xcconfig", "Dokumentum/Localizable.xcstrings",
            "docsx/a.txt", "mydocs/a.txt", ".github/labels.jsonx", ".github/ISSUE_TEMPLATE", "a.md.swift",
            "Dokumentum.xcodeproj/project.pbxproj", "LICENSE", "something/unknown.bin"]
    for path in code:
        assert not is_docs(path), path
    assert scope(["docs/a.md"]) == "docs"
    assert scope(["docs/a.md", "README.md"]) == "docs"
    assert scope(["docs/a.md", "Dokumentum/App.swift"]) == "full"
    assert scope([]) == "full"
    assert scope([""]) == "full"
    assert decide("", "abc") == "full" and decide("abc", "") == "full"

    def git(cwd, *args):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True,
                       capture_output=True)

    def write(cwd, path, text):
        full = os.path.join(cwd, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as handle:
            handle.write(text)

    def sha(cwd):
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, capture_output=True, text=True,
                              check=True).stdout.strip()

    with tempfile.TemporaryDirectory() as root:
        git(root, "init", "-q", "-b", "main")
        write(root, "docs/a.md", "a\n")
        write(root, "Dokumentum/App.swift", "x\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "base")
        base = sha(root)
        git(root, "checkout", "-q", "-b", "docs")
        write(root, "docs/a.md", "b\n")
        write(root, "docs/new name.md", "c\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "docs")
        assert decide(base, sha(root), root) == "docs"
        git(root, "checkout", "-q", "main")
        git(root, "checkout", "-q", "-b", "code")
        write(root, "docs/a.md", "b\n")
        write(root, "Dokumentum/App.swift", "y\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "code")
        assert decide(base, sha(root), root) == "full"
        # A rename of a code file into docs counts the old path too.
        git(root, "checkout", "-q", "main")
        git(root, "checkout", "-q", "-b", "move")
        git(root, "mv", "Dokumentum/App.swift", "docs/App.md")
        git(root, "commit", "-q", "-m", "move")
        assert decide(base, sha(root), root) == "full"
        # A newer base does not count: only what the head changed since the merge base.
        git(root, "checkout", "-q", "main")
        write(root, "Dokumentum/Other.swift", "z\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "main moves on")
        newer = sha(root)
        git(root, "checkout", "-q", "docs")
        assert decide(newer, sha(root), root) == "docs"
        # An unknown commit cannot be diffed: full.
        assert decide("0" * 40, sha(root), root) == "full"
    print("app-scope self-test passed.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    result = "full" if args.full else decide(args.base, args.head)
    print(result)
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as handle:
            handle.write(f"scope={result}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
