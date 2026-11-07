#!/usr/bin/env python3
"""Checks the app's logging rules (docs/development/index.md, "Logging").

Ported from the predecessor (pklnx/document-archive `scripts/check-logging.py`) without its API-key
rules: Dokumentum has no network service and no credentials to leak.

Searches the Swift files of the app, the share extension and the two packages' library code
(SOURCES; tests and test support are not checked) and fails on:
- `print(`, `debugPrint(`, `NSLog(` and `dump(` calls, also written as `Swift.print(`,
  `Swift.dump(` or `Foundation.NSLog(`: the app logs through `Log` (os.Logger), so messages have
  a category, a level and privacy annotations;
- a `Logger(` or `os_log(` call outside `DokumentumCore/Log.swift`: every logger comes from `Log`;
- a `fatalError(`, `preconditionFailure(` or `assertionFailure(` message, or the message of a
  `precondition(_:_:)` / `assert(_:_:)` (the second argument), with an interpolation: the
  message goes into crash reports unredacted (an error can contain the store path or a file
  name). Log the details first (`Log.<category>.fault`, with privacy annotations) and keep the
  message a fixed text.

The script also fails when it scans no Swift file at all (a wrong working directory or a
renamed folder would otherwise let every rule pass vacuously).

    python3 scripts/check-logging.py            # from the repository root
    python3 scripts/check-logging.py --self-test

What counts as a call: the name not preceded by a letter, digit, "_" or "." (so
`DocumentPrinter.print(job)` and `Self.print(document)` are other functions), and not a
declaration (`func print(`). Comment lines (starting with `//`) are skipped. A crash call is read
up to its closing parenthesis, also across lines.
"""
import os
import re
import sys
import tempfile

SOURCES = [
    "Dokumentum",
    "DokumentumShare",
    "Packages/DokumentumCore/Sources/DokumentumCore",
    "Packages/DokumentumKit/Sources/DokumentumKit",
]

# `Swift.print(` and friends are the same functions with a module prefix.
FORBIDDEN_CALL = re.compile(r"(?<![A-Za-z0-9_.])(?:(?:Swift|Foundation)\.)?(print|debugPrint|NSLog|dump)\(")
DECLARATION = re.compile(r"\bfunc\s+$")
LOGGER_CALL = re.compile(r"(?<![A-Za-z0-9_.])(?:os\.)?(Logger|os_log)\(")
LOG_FILE = os.path.join("DokumentumCore", "Log.swift")
CRASH_CALL = re.compile(r"(?<![A-Za-z0-9_.])(fatalError|preconditionFailure|assertionFailure)\(")
# precondition(_:_:) and assert(_:_:): only the message (the second argument) ends up in a report.
CONDITION_CALL = re.compile(r"(?<![A-Za-z0-9_.])(precondition|assert)\(")


def strip_comments(text: str) -> str:
    """Blanks out comment lines, keeping the line numbers."""
    return "\n".join("" if line.strip().startswith("//") else line for line in text.split("\n"))


def call_arguments(text: str, open_paren: int) -> str:
    """The text between the parenthesis at `open_paren` and its matching closing one."""
    depth = 0
    for index in range(open_paren, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:index]
    return text[open_paren + 1:]


def message_argument(arguments: str) -> str:
    """The text after the first top-level comma (the message of `precondition(_:_:)`)."""
    depth = 0
    in_string = False
    for index, char in enumerate(arguments):
        if in_string:
            if char == "\\":
                continue
            if char == '"' and arguments[index - 1] != "\\":
                in_string = False
        elif char == '"':
            in_string = True
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            return arguments[index + 1:]
    return ""


def interpolations(arguments: str):
    r"""The contents of every `\( ... )` in the arguments, with balanced parentheses."""
    found = []
    index = arguments.find("\\(")
    while index != -1:
        found.append(call_arguments(arguments, index + 1) + ")")
        index = arguments.find("\\(", index + 2)
    return found


def problems_in(text: str, path: str):
    text = strip_comments(text)
    problems = []
    for match in FORBIDDEN_CALL.finditer(text):
        line_start = text.rfind("\n", 0, match.start()) + 1
        if DECLARATION.search(text[line_start:match.start()]):
            continue
        number = text.count("\n", 0, match.start()) + 1
        problems.append(f"{path}:{number}: {match.group(1)}( in app code; log through Log (os.Logger) instead")
    if not path.endswith(LOG_FILE):
        for match in LOGGER_CALL.finditer(text):
            line_start = text.rfind("\n", 0, match.start()) + 1
            if DECLARATION.search(text[line_start:match.start()]):
                continue
            number = text.count("\n", 0, match.start()) + 1
            problems.append(f"{path}:{number}: {match.group(1)}( outside DokumentumCore/Log.swift; use the loggers of Log")
    for match in CRASH_CALL.finditer(text):
        if interpolations(call_arguments(text, match.end() - 1)):
            number = text.count("\n", 0, match.start()) + 1
            problems.append(f"{path}:{number}: {match.group(1)} message with an interpolation ends up in crash "
                            "reports; log the details privately (Log.<category>.fault) and keep the message fixed")
    for match in CONDITION_CALL.finditer(text):
        if interpolations(message_argument(call_arguments(text, match.end() - 1))):
            number = text.count("\n", 0, match.start()) + 1
            problems.append(f"{path}:{number}: {match.group(1)} message with an interpolation ends up in crash "
                            "reports; log the details privately (Log.<category>.fault) and keep the message fixed")
    return problems


def check(source_root: str):
    """The problems in all Swift files below `source_root`; a folder without any is a problem too."""
    problems = []
    scanned = 0
    for directory, _, files in sorted(os.walk(source_root)):
        for name in sorted(files):
            if name.endswith(".swift"):
                path = os.path.join(directory, name)
                scanned += 1
                with open(path, encoding="utf-8") as handle:
                    problems += problems_in(handle.read(), path)
    if scanned == 0:
        problems.append(f"{source_root}: no Swift files found; run the script from the repository root")
    return problems


def check_all(roots):
    problems = []
    for root in roots:
        problems += check(root)
    return problems


def self_test() -> None:
    cases = [
        # (description, Swift source in the app, expected problem count)
        ("print in app code", 'print("hello")\n', 1),
        ("indented print", '    if x { print(error) }\n', 1),
        ("debugPrint", "debugPrint(value)\n", 1),
        ("NSLog", 'NSLog("%@", value)\n', 1),
        ("dump", "dump(value)\n", 1),
        ("Swift.print", 'Swift.print(value)\n', 1),
        ("Swift.dump", 'Swift.dump(value)\n', 1),
        ("Foundation.NSLog", 'Foundation.NSLog("x")\n', 1),
        ("stray Logger", 'let logger = Logger(subsystem: "x", category: "y")\n', 1),
        ("stray os.Logger", 'let logger = os.Logger(subsystem: "x", category: "y")\n', 1),
        ("stray os_log", 'os_log("hello")\n', 1),
        ("Logger as a type name", "let logger: Logger = Log.store\n", 0),
        ("precondition with an interpolated message", 'precondition(x > 0, "bad \\(x)")\n', 1),
        ("assert with an interpolated message across lines", 'assert(\n    ok,\n    "failed \\(error)"\n)\n', 1),
        ("precondition with a fixed message", 'precondition(limit > 0, "A semaphore needs a slot")\n', 0),
        ("precondition without a message", 'precondition(!ids.contains("\\(x)"))\n', 0),
        ("assert with a call in the condition", 'assert(check(a, b), "fixed")\n', 0),
        ("method named assert", "XCTAssert(x, \"a \\(b)\")\n", 0),
        ("method named print", "DocumentPrinter.print(job)\nSelf.print(document)\n", 0),
        ("declaration", "static func print(_ job: PrintJob) {}\n", 0),
        ("other identifiers", "blueprint(x); reprint(y); dumpState()\n", 0),
        ("comment line", '// print("debug")\n', 0),
        ("allowed log call", 'Log.store.notice("\\(choice, privacy: .public): \\(count, privacy: .public)")\n', 0),
        ("error in a fatalError message", 'fatalError("Could not create the store: \\(error)")\n', 1),
        ("value in a precondition failure", 'preconditionFailure("bad \\(path)")\n', 1),
        ("assertion failure across lines", 'assertionFailure(\n    "failed \\(error)"\n)\n', 1),
        ("fixed fatalError message", 'fatalError("Could not create the store")\n', 0),
        ("fatalError without a message", "fatalError()\n", 0),
    ]
    for description, source, expected in cases:
        with tempfile.TemporaryDirectory() as root:
            app = os.path.join(root, "Dokumentum", "App")
            os.makedirs(app)
            with open(os.path.join(app, "File.swift"), "w", encoding="utf-8") as handle:
                handle.write(source)
            problems = check(os.path.join(root, "Dokumentum"))
            assert len(problems) == expected, f"{description}: expected {expected} problem(s), got {problems}"
    # Tests may print: only the source folders are checked.
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "Dokumentum"))
        with open(os.path.join(root, "Dokumentum", "App.swift"), "w", encoding="utf-8") as handle:
            handle.write("let x = 1\n")
        tests = os.path.join(root, "DokumentumTests")
        os.makedirs(tests)
        with open(os.path.join(tests, "SomeTests.swift"), "w", encoding="utf-8") as handle:
            handle.write('print("in a test")\n')
        problems = check(os.path.join(root, "Dokumentum"))
        assert problems == [], f"print in tests: expected no problems, got {problems}"
    # A folder without Swift files must not pass, and one such folder among several is enough.
    with tempfile.TemporaryDirectory() as root:
        problems = check(os.path.join(root, "Dokumentum"))
        assert len(problems) == 1, f"missing folder: expected one problem, got {problems}"
        os.makedirs(os.path.join(root, "Dokumentum"))
        problems = check(os.path.join(root, "Dokumentum"))
        assert len(problems) == 1, f"empty folder: expected one problem, got {problems}"
        with open(os.path.join(root, "Dokumentum", "App.swift"), "w", encoding="utf-8") as handle:
            handle.write("let x = 1\n")
        problems = check_all([os.path.join(root, "Dokumentum"), os.path.join(root, "DokumentumShare")])
        assert len(problems) == 1, f"one missing folder of two: expected one problem, got {problems}"
    # DokumentumCore/Log.swift creates the loggers; a Log.swift elsewhere does not.
    with tempfile.TemporaryDirectory() as root:
        core = os.path.join(root, "Packages", "DokumentumCore", "Sources", "DokumentumCore")
        os.makedirs(core)
        with open(os.path.join(core, "Log.swift"), "w", encoding="utf-8") as handle:
            handle.write('static let store = Logger(subsystem: subsystem, category: "store")\n')
        problems = check(os.path.join(root, "Packages", "DokumentumCore", "Sources", "DokumentumCore"))
        assert problems == [], f"Log.swift: expected no problems, got {problems}"
        app = os.path.join(root, "Dokumentum")
        os.makedirs(app)
        with open(os.path.join(app, "Log.swift"), "w", encoding="utf-8") as handle:
            handle.write('static let store = Logger(subsystem: subsystem, category: "store")\n')
        problems = check(app)
        assert len(problems) == 1, f"another Log.swift: expected one problem, got {problems}"
    print(f"self-test passed ({len(cases) + 4} cases)")


def main() -> int:
    problems = check_all(SOURCES)
    for problem in problems:
        print(f"error: {problem}")
    if problems:
        return 1
    print("logging rules hold")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main())
