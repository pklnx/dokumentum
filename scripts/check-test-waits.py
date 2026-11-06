#!/usr/bin/env python3
"""Flags tests that wait for time instead of for a signal (docs/development/index.md, "Waiting in
tests"). In the folders of FOLDERS it reports every `Task.sleep`, `Task.yield()`, `Thread.sleep`,
`sleep()`/`usleep()`, `asyncAfter`, `RunLoop.run(until:)` and fixed stub delay (`.delay = 0.3`).
XCTest's waits (`waitForExistence`, `XCTWaiter`, expectations) are not flagged: they wait for a
condition, with a timeout.

A use that is justified stays when it says why, on its line or in the comment lines directly
above it:

    try await Task.sleep(for: interval) // allow-wait: the one poll, for state without a signal

    python3 scripts/check-test-waits.py               # from the repository root
    python3 scripts/check-test-waits.py --self-test
"""
import glob
import os
import re
import sys
import tempfile

# Patterns relative to the repository root. A pattern that finds no folder is an error, so a folder
# that moves does not silently leave the check.
FOLDERS = [
    "DokumentumTests",
    "DokumentumUITests",
    "Packages/*/Tests",
    "Packages/DokumentumKit/Sources/DokumentumTestSupport",
]

PATTERNS = [
    (re.compile(r"\bTask\.sleep\b"), "Task.sleep"),
    (re.compile(r"\bTask\.yield\s*\("), "Task.yield()"),
    (re.compile(r"\bThread\.sleep\b"), "Thread.sleep"),
    (re.compile(r"(?<![\w.])u?sleep\s*\("), "sleep()"),
    (re.compile(r"\.asyncAfter\s*\("), "asyncAfter"),
    (re.compile(r"\.run\s*\(\s*(mode:[^)]*,\s*)?until\s*:"), "RunLoop.run(until:)"),
    (re.compile(r"\.delay\s*=\s*[\d.]"), "a fixed delay"),
]

ALLOW = re.compile(r"//\s*allow-wait:\s*\S")


def code_part(line: str) -> str:
    """The line without its `//` comment (a `//` inside a string literal is kept)."""
    in_string = False
    index = 0
    while index < len(line):
        char = line[index]
        if char == "\\" and in_string:
            index += 2
            continue
        if char == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", index):
            return line[:index]
        index += 1
    return line


def is_comment_line(line: str) -> bool:
    return line.strip().startswith("//")


def allowed(lines, index: int) -> bool:
    """An `allow-wait:` reason on the line, or in the comment lines directly above it."""
    if ALLOW.search(lines[index]):
        return True
    above = index - 1
    while above >= 0 and is_comment_line(lines[above]):
        if ALLOW.search(lines[above]):
            return True
        above -= 1
    return False


def check(text: str):
    """(line number, what) for every wait for time without an `allow-wait:` reason."""
    lines = text.splitlines()
    problems = []
    in_block_comment = False
    for index, line in enumerate(lines):
        code = line
        if in_block_comment:
            if "*/" not in code:
                continue
            code = code.split("*/", 1)[1]
            in_block_comment = False
        if "/*" in code_part(code):
            before, _, rest = code.partition("/*")
            if "*/" in rest:
                code = before + rest.split("*/", 1)[1]
            else:
                code = before
                in_block_comment = True
        code = code_part(code)
        for pattern, what in PATTERNS:
            if pattern.search(code) and not allowed(lines, index):
                problems.append((index + 1, what))
                break
    return problems


def check_tree(root: str):
    """One message per problem of the repository at `root`, for every folder of FOLDERS."""
    messages = []
    for pattern in FOLDERS:
        folders = sorted(glob.glob(os.path.join(root, pattern)))
        if not folders:
            messages.append(f"error: {pattern}: no such folder, so check-test-waits.py would not see its tests")
        for folder in folders:
            for directory, _, files in os.walk(folder):
                for name in sorted(files):
                    if not name.endswith(".swift"):
                        continue
                    path = os.path.join(directory, name)
                    with open(path, encoding="utf-8") as handle:
                        for line, what in check(handle.read()):
                            messages.append(
                                f"error: {os.path.relpath(path, root)}:{line}: {what} in a test: wait for a signal "
                                f"instead, or say why with `// allow-wait: <reason>` (docs/development/index.md, "
                                f"\"Waiting in tests\")")
    return messages


def write_tree(root: str, files) -> None:
    for name, text in files.items():
        path = os.path.join(root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)


def self_test() -> None:
    cases = [
        ("sleep", "try await Task.sleep(for: .milliseconds(20))", 1),
        ("sleep in nanoseconds", "try await Task.sleep(nanoseconds: 1_000)", 1),
        ("yield", "await Task.yield()", 1),
        ("yield loop", "for _ in 0..<3 { await Task.yield() }", 1),
        ("Thread.sleep", "Thread.sleep(forTimeInterval: 0.25)", 1),
        ("C sleep", "sleep(1)", 1),
        ("usleep", "usleep(1000)", 1),
        ("asyncAfter", "DispatchQueue.main.asyncAfter(deadline: .now() + 1) { }", 1),
        ("run loop", "RunLoop.current.run(until: Date().addingTimeInterval(1))", 1),
        ("stub delay", "stub.delay = 0.3", 1),
        ("allowed on the line", "try await Task.sleep(for: x) // allow-wait: the safety net", 0),
        ("allowed above", "// allow-wait: a negative check\ntry await Task.sleep(for: x)", 0),
        ("allowed in a comment block above", "// allow-wait: why\n// more words\nThread.sleep(forTimeInterval: 1)", 0),
        ("allow needs a reason", "try await Task.sleep(for: x) // allow-wait:", 1),
        ("allow does not reach past code", "// allow-wait: why\nlet a = 1\nawait Task.yield()", 1),
        ("in a comment", "// no Task.sleep here", 0),
        ("in a doc comment", "/// waits instead of `Task.sleep`", 0),
        ("in a block comment", "/* Task.sleep\n Thread.sleep(1) */\nlet a = 1", 0),
        ("in a string", 'let text = "Task.sleep"', 1),
        ("comment marker in a string", 'let url = "https://x"; await Task.yield()', 1),
        ("XCTest waits are fine", "XCTAssertTrue(button.waitForExistence(timeout: 5))", 0),
        ("XCTWaiter is fine", "XCTWaiter().wait(for: [hittable], timeout: timeout)", 0),
        ("a delay variable is fine", "let delay = route.delay", 0),
        ("sleepy names are fine", "let isAsleep = deviceSleep(true)", 0),
        ("a manual debounce's sleep is fine", "try await debounce.sleep(.seconds(3600))", 0),
        ("two problems", "await Task.yield()\nThread.sleep(forTimeInterval: 1)", 2),
    ]
    for description, text, expected in cases:
        problems = check(text)
        assert len(problems) == expected, f"{description}: expected {expected} problem(s), got {problems}"

    fine = "let a = 1\n"
    wait = "try await Task.sleep(for: x)\n"
    support = "Packages/DokumentumKit/Sources/DokumentumTestSupport"
    every_folder = {
        "DokumentumTests/A.swift": fine,
        "DokumentumUITests/A.swift": fine,
        "Packages/DokumentumKit/Tests/KitTests/A.swift": fine,
        "Packages/DokumentumCore/Tests/CoreTests/A.swift": fine,
        f"{support}/A.swift": fine,
    }
    trees = [
        ("all fine", every_folder, []),
        ("app test", {**every_folder, "DokumentumTests/Sub/B.swift": wait}, ["DokumentumTests/Sub/B.swift:1"]),
        ("UI test", {**every_folder, "DokumentumUITests/B.swift": wait}, ["DokumentumUITests/B.swift:1"]),
        ("Kit test", {**every_folder, "Packages/DokumentumKit/Tests/KitTests/B.swift": wait},
         ["Packages/DokumentumKit/Tests/KitTests/B.swift:1"]),
        ("Core test", {**every_folder, "Packages/DokumentumCore/Tests/CoreTests/B.swift": wait},
         ["Packages/DokumentumCore/Tests/CoreTests/B.swift:1"]),
        ("test support", {**every_folder, f"{support}/B.swift": wait}, [f"{support}/B.swift:1"]),
        ("the app is not checked", {**every_folder, "Dokumentum/B.swift": wait}, []),
        ("a package's sources are not checked", {**every_folder, "Packages/DokumentumCore/Sources/Core/B.swift": wait},
         []),
        ("only Swift files", {**every_folder, "DokumentumTests/B.txt": wait}, []),
        ("a folder that moved",
         {name: text for name, text in every_folder.items() if not name.startswith("DokumentumUITests")},
         ["DokumentumUITests: no such folder"]),
    ]
    for description, files, expected in trees:
        with tempfile.TemporaryDirectory() as root:
            write_tree(root, files)
            messages = check_tree(root)
        assert len(messages) == len(expected), f"{description}: expected {expected}, got {messages}"
        for message, part in zip(messages, expected):
            assert part in message, f"{description}: expected {part} in {message}"
    print(f"self-test passed ({len(cases) + len(trees)} cases)")


def main() -> int:
    messages = check_tree(".")
    for message in messages:
        print(message)
    if not messages:
        print("no test waits for time")
    return 1 if messages else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main())
