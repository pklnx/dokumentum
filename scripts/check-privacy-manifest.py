#!/usr/bin/env python3
"""Keeps the privacy manifests of the app and the share extension matched to the code (#9, part 1; maintainer
decision P5 of 2026-11-13). Python standard library only, so it runs in `lint` on Linux.

For each manifest in MANIFESTS:
- The file exists and is a property list with exactly the keys NSPrivacyTracking (false),
  NSPrivacyTrackingDomains (empty), NSPrivacyCollectedDataTypes (empty: P5, "no collected data") and
  NSPrivacyAccessedAPITypes.
- Every entry of NSPrivacyAccessedAPITypes names a known category once, with at least one reason, and every
  reason is one of Apple's codes for that category (REASONS).
- The declared categories and reasons are exactly the reviewed ones (DECLARED, maintainer decision P5 on #9):
  another reason, even one Apple allows for the category, or another category is a change here, on purpose.
- The Swift sources the target ships (its folder and the library sources of the packages it links; never the
  test-support targets) are searched for the required-reason APIs of SYMBOLS. A category that the code uses but
  the manifest does not declare fails, and so does one that the manifest declares but the code does not use.
  A symbol that Apple lists under two categories (the getattrlist family: file timestamp and disk space) needs
  at least one of them declared, and it counts as a use of each.

What counts as a use: the symbol as a whole word (`@AppStorage` counts as AppStorage), on a line that is not a
comment line. As in scripts/check-logging.py, comment lines (starting with `//`, doc comments included) are
skipped; a mention in a trailing comment or a block comment counts, which fails loudly and is fixed by
rewording. A folder without any Swift file fails too, so a renamed folder cannot let every rule pass.

The symbols and reason codes follow Apple's lists ("Describing use of required reason API" and
NSPrivacyAccessedAPITypeReasons) as of 2026-11-13. Apple requires the declarations for iOS, iPadOS, tvOS,
visionOS and watchOS. The app's manifest also ships in the Mac app (Contents/Resources), where it is
informational.

The binary side (which of these symbols the Release executables import) is evidence on the PR that adds a
category (`nm -u`), not part of this check: it needs a macOS build.

    python3 scripts/check-privacy-manifest.py              # from the repository root
    python3 scripts/check-privacy-manifest.py --self-test
"""
import os
import pathlib
import plistlib
import re
import sys
import tempfile
import xml.parsers.expat

FILE_TIMESTAMP = "NSPrivacyAccessedAPICategoryFileTimestamp"
SYSTEM_BOOT_TIME = "NSPrivacyAccessedAPICategorySystemBootTime"
DISK_SPACE = "NSPrivacyAccessedAPICategoryDiskSpace"
ACTIVE_KEYBOARDS = "NSPrivacyAccessedAPICategoryActiveKeyboards"
USER_DEFAULTS = "NSPrivacyAccessedAPICategoryUserDefaults"

# Apple's reason codes per category (NSPrivacyAccessedAPITypeReasons, as of 2026-11-13).
REASONS = {
    FILE_TIMESTAMP: {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    SYSTEM_BOOT_TIME: {"35F9.1", "8FFB.1", "3D61.1"},
    DISK_SPACE: {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    ACTIVE_KEYBOARDS: {"3EC4.1", "54BD.1"},
    USER_DEFAULTS: {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}

# The required-reason APIs per category, Swift and C names (Apple's list as of 2026-11-13).
_CATEGORY_SYMBOLS = {
    FILE_TIMESTAMP: [
        "creationDate", "modificationDate", "fileModificationDate", "contentModificationDateKey", "creationDateKey",
        "getattrlist", "getattrlistbulk", "fgetattrlist", "getattrlistat", "stat", "fstat", "fstatat", "lstat",
    ],
    SYSTEM_BOOT_TIME: ["systemUptime", "mach_absolute_time"],
    DISK_SPACE: [
        "volumeAvailableCapacityKey", "volumeAvailableCapacityForImportantUsageKey",
        "volumeAvailableCapacityForOpportunisticUsageKey", "volumeTotalCapacityKey", "systemFreeSize", "systemSize",
        "statfs", "statvfs", "fstatfs", "fstatvfs", "getattrlist", "fgetattrlist", "getattrlistat",
    ],
    ACTIVE_KEYBOARDS: ["activeInputModes"],
    USER_DEFAULTS: ["UserDefaults", "NSUserDefaults", "AppStorage"],
}
# symbol -> the categories that list it (the getattrlist family is in two).
SYMBOLS = {}
for _category, _names in _CATEGORY_SYMBOLS.items():
    for _name in _names:
        SYMBOLS.setdefault(_name, set()).add(_category)
SYMBOL_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_])(" + "|".join(sorted(SYMBOLS, key=len, reverse=True)) + r")(?![A-Za-z0-9_])")

KIT = "Packages/DokumentumKit/Sources/DokumentumKit"
CORE = "Packages/DokumentumCore/Sources/DokumentumCore"
# Each manifest and the Swift sources its target ships. The app links DokumentumCore and DokumentumKit, the
# extension DokumentumKit only (scripts/check-project.py pins that). DokumentumTestSupport and
# DokumentumCoreTestSupport ship in no product.
MANIFESTS = {
    "Dokumentum/PrivacyInfo.xcprivacy": ["Dokumentum", CORE, KIT],
    "DokumentumShare/PrivacyInfo.xcprivacy": ["DokumentumShare", KIT],
}
# P5 on #9: each manifest's categories and reasons, exactly. A change is a change here, on purpose.
DECLARED = {
    "Dokumentum/PrivacyInfo.xcprivacy": {FILE_TIMESTAMP: ["C617.1"], USER_DEFAULTS: ["CA92.1"]},
    "DokumentumShare/PrivacyInfo.xcprivacy": {FILE_TIMESTAMP: ["C617.1"]},
}
assert set(DECLARED) == set(MANIFESTS)
# P5: no tracking, no tracking domains, no collected data. A change is a change here, on purpose.
EXPECTED_FIXED = {
    "NSPrivacyTracking": False,
    "NSPrivacyTrackingDomains": [],
    "NSPrivacyCollectedDataTypes": [],
}
ACCESSED = "NSPrivacyAccessedAPITypes"
TYPE_KEY = "NSPrivacyAccessedAPIType"
REASONS_KEY = "NSPrivacyAccessedAPITypeReasons"


def code_lines(text):
    """(line number, line) for every line that is not a comment line."""
    for number, line in enumerate(text.split("\n"), start=1):
        if not line.strip().startswith("//"):
            yield number, line


def uses(root, folders):
    """({category: [where]}, problems): the required-reason APIs in the Swift files below `folders`."""
    found = {}
    problems = []
    for folder in folders:
        scanned = 0
        for directory, subfolders, files in os.walk(root / folder):
            subfolders.sort()
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                scanned += 1
                path = pathlib.Path(directory) / name
                relative = path.relative_to(root).as_posix()
                text = path.read_bytes().decode("utf-8", errors="replace")
                for number, line in code_lines(text):
                    for match in SYMBOL_PATTERN.finditer(line):
                        symbol = match.group(1)
                        found.setdefault(frozenset(SYMBOLS[symbol]), []).append(f"{relative}:{number} ({symbol})")
        if scanned == 0:
            problems.append(f"{folder}: no Swift files found; run the script from the repository root")
    return found, problems


def read_manifest(root, name):
    """({category: [reasons]}, problems)."""
    path = root / name
    if not path.is_file():
        return None, [f"{name} is missing"]
    try:
        manifest = plistlib.loads(path.read_bytes())
    except (plistlib.InvalidFileException, xml.parsers.expat.ExpatError, ValueError) as error:
        return None, [f"{name}: not a valid property list: {error}"]
    if not isinstance(manifest, dict):
        return None, [f"{name}: the top level must be a dictionary"]
    problems = []
    for key in sorted(set(manifest) - set(EXPECTED_FIXED) - {ACCESSED}):
        problems.append(f"{name}: {key} is not a reviewed key")
    for key, expected in EXPECTED_FIXED.items():
        if key not in manifest:
            problems.append(f"{name}: {key} is missing")
        elif manifest[key] != expected or type(manifest[key]) is not type(expected):
            problems.append(f"{name}: {key} is {manifest[key]!r}, expected {expected!r} (maintainer decision P5 on #9)")
    entries = manifest.get(ACCESSED)
    if not isinstance(entries, list):
        problems.append(f"{name}: {ACCESSED} must be a list")
        return {}, problems
    declared = {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {TYPE_KEY, REASONS_KEY}:
            problems.append(f"{name}: each {ACCESSED} entry holds exactly {TYPE_KEY} and {REASONS_KEY}, found {entry!r}")
            continue
        category, reasons = entry[TYPE_KEY], entry[REASONS_KEY]
        if category not in REASONS:
            problems.append(f"{name}: {category!r} is not a known required-reason category")
            continue
        if category in declared:
            problems.append(f"{name}: {category} is declared twice")
        if not isinstance(reasons, list) or not reasons:
            problems.append(f"{name}: {category} needs at least one reason")
            continue
        for reason in reasons:
            if reason not in REASONS[category]:
                problems.append(f"{name}: {reason!r} is not a reason code of {category} "
                                f"(allowed: {', '.join(sorted(REASONS[category]))})")
        declared[category] = reasons
    return declared, problems


def check_manifest(root, name, folders, reviewed):
    """(problems, report lines) for one manifest; `reviewed` is its row of DECLARED."""
    declared, problems = read_manifest(root, name)
    found, scan_problems = uses(root, folders)
    problems += scan_problems
    if declared is None:
        return problems, []
    for category in sorted(set(declared) | set(reviewed)):
        if declared.get(category) != reviewed.get(category):
            problems.append(f"{name}: {category} declares {declared.get(category)}, the reviewed reasons are "
                            f"{reviewed.get(category)} (DECLARED, maintainer decision P5 on #9)")
    used = set()
    for categories, where in sorted(found.items(), key=lambda item: sorted(item[0])):
        used |= categories
        if not categories & set(declared):
            names = " or ".join(sorted(categories))
            problems.append(f"{name}: the code uses {names} but the manifest does not declare it: {where[0]}"
                            + (f" and {len(where) - 1} more" if len(where) > 1 else ""))
    for category in sorted(set(declared) - used):
        problems.append(f"{name}: declares {category}, which no shipped source uses ({', '.join(folders)})")
    report = []
    for category in sorted(declared):
        hits = [hit for categories, where in found.items() if category in categories for hit in where]
        report.append(f"{name}: {category} {', '.join(declared[category])}: {len(hits)} use(s), first {hits[0]}"
                      if hits else f"{name}: {category}: no use")
    return problems, report


def check(root, declared_rows=None):
    """(problems, report lines). `declared_rows` replaces DECLARED in the self-test only."""
    problems, report = [], []
    for name, folders in MANIFESTS.items():
        more, lines = check_manifest(root, name, folders, (declared_rows or DECLARED)[name])
        problems += more
        report += lines
    return problems, report


def manifest_bytes(categories, **overrides):
    content = {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyCollectedDataTypes": [],
        ACCESSED: [{TYPE_KEY: category, REASONS_KEY: reasons} for category, reasons in categories.items()],
    }
    content.update(overrides)
    return plistlib.dumps(content)


APP_FIXTURE = DECLARED["Dokumentum/PrivacyInfo.xcprivacy"]
SHARE_FIXTURE = DECLARED["DokumentumShare/PrivacyInfo.xcprivacy"]


def write_fixture(root):
    files = {
        "Dokumentum/App.swift": "let defaults = UserDefaults.standard\n",
        "DokumentumShare/Share.swift": "import UIKit\n",
        f"{CORE}/Core.swift": "/// Kept in UserDefaults.\nlet x = 1\n",
        f"{KIT}/Queue.swift": "var status = stat()\nlet found = fstat(descriptor, &status)\n",
        # Ships in no product, so its use does not count.
        "Packages/DokumentumCore/Sources/DokumentumCoreTestSupport/Log.swift": "let up = ProcessInfo().systemUptime\n",
    }
    for name, text in files.items():
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_text(text, encoding="utf-8")
    (root / "Dokumentum/PrivacyInfo.xcprivacy").write_bytes(manifest_bytes(APP_FIXTURE))
    (root / "DokumentumShare/PrivacyInfo.xcprivacy").write_bytes(manifest_bytes(SHARE_FIXTURE))


def self_test():
    app, share = list(MANIFESTS)

    def write(name, text):
        def apply(root):
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(text, encoding="utf-8")
        return apply

    def manifest(name, categories, **overrides):
        return lambda root: (root / name).write_bytes(manifest_bytes(categories, **overrides))

    def remove(name):
        return lambda root: (root / name).unlink()

    def both(*steps):
        def apply(root):
            for step in steps:
                step(root)
        return apply

    cases = [
        ("the fixture is fine", lambda root: None, None),
        ("a missing manifest", remove(share), f"{share} is missing"),
        ("not a property list", write(app, "<plist"), "not a valid property list"),
        ("tracking true", manifest(app, APP_FIXTURE, NSPrivacyTracking=True), "NSPrivacyTracking is True"),
        ("tracking as the number 0", manifest(app, APP_FIXTURE, NSPrivacyTracking=0), "NSPrivacyTracking is 0"),
        ("tracking missing", lambda root: (root / app).write_bytes(plistlib.dumps(
            {k: v for k, v in plistlib.loads(manifest_bytes(APP_FIXTURE)).items() if k != "NSPrivacyTracking"})),
         "NSPrivacyTracking is missing"),
        ("a tracking domain", manifest(app, APP_FIXTURE, NSPrivacyTrackingDomains=["example.com"]),
         "NSPrivacyTrackingDomains is ['example.com']"),
        ("collected data", manifest(share, SHARE_FIXTURE, NSPrivacyCollectedDataTypes=[
            {"NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeOtherUserContent"}]),
         "NSPrivacyCollectedDataTypes is"),
        ("an unreviewed key", manifest(app, APP_FIXTURE, Extra=True), "Extra is not a reviewed key"),
        ("a used category that is not declared: fstat in Kit, for the extension",
         manifest(share, {}), f"{share}: the code uses {FILE_TIMESTAMP} but the manifest does not declare it: "
                              f"{KIT}/Queue.swift:1 (stat)"),
        ("a used category that is not declared: fstat in Kit, for the app",
         manifest(app, {USER_DEFAULTS: ["CA92.1"]}), f"{app}: the code uses {FILE_TIMESTAMP}"),
        ("UserDefaults in the extension", write("DokumentumShare/Settings.swift", "let d = UserDefaults.standard\n"),
         f"{share}: the code uses {USER_DEFAULTS}"),
        ("@AppStorage in the app, nothing else", both(
            write("Dokumentum/App.swift", "@AppStorage(\"x\") var x = false\n"),
            manifest(app, {FILE_TIMESTAMP: ["C617.1"]})), f"{app}: the code uses {USER_DEFAULTS}"),
        ("NSUserDefaults", both(write("Dokumentum/App.swift", "let d = NSUserDefaults()\n"),
                                manifest(app, {FILE_TIMESTAMP: ["C617.1"]})), f"the code uses {USER_DEFAULTS}"),
        ("a declared category that is not used", manifest(share, {**SHARE_FIXTURE, USER_DEFAULTS: ["CA92.1"]}),
         f"{share}: declares {USER_DEFAULTS}, which no shipped source uses"),
        ("an unknown reason code", manifest(app, {FILE_TIMESTAMP: ["C617.1"], USER_DEFAULTS: ["C617.1"]}),
         f"'C617.1' is not a reason code of {USER_DEFAULTS}"),
        ("a reason code that does not exist", manifest(share, {FILE_TIMESTAMP: ["XXXX.1"]}), "'XXXX.1' is not a reason"),
        ("no reason", manifest(share, {FILE_TIMESTAMP: []}), "needs at least one reason"),
        ("an unknown category", manifest(share, {**SHARE_FIXTURE, "NSPrivacyAccessedAPICategoryOther": ["C617.1"]}),
         "'NSPrivacyAccessedAPICategoryOther' is not a known required-reason category"),
        ("a category declared twice", lambda root: (root / share).write_bytes(plistlib.dumps({
            **EXPECTED_FIXED, ACCESSED: [{TYPE_KEY: FILE_TIMESTAMP, REASONS_KEY: ["C617.1"]}] * 2})), "declared twice"),
        ("an entry with an extra key", lambda root: (root / share).write_bytes(plistlib.dumps({
            **EXPECTED_FIXED, ACCESSED: [{TYPE_KEY: FILE_TIMESTAMP, REASONS_KEY: ["C617.1"], "X": 1}]})),
         "each NSPrivacyAccessedAPITypes entry holds exactly"),
        ("a getattrlist hit with neither category declared", both(
            write(f"{KIT}/Queue.swift", "let r = getattrlist(path, &list, &buffer, size, 0)\n"), manifest(share, {})),
         f"the code uses {DISK_SPACE} or {FILE_TIMESTAMP} but the manifest does not declare it"),
        ("a getattrlist hit with disk space declared", both(
            write(f"{KIT}/Queue.swift", "let r = getattrlist(path, &list, &buffer, size, 0)\n"),
            manifest(share, {DISK_SPACE: ["E174.1"]}),
            manifest(app, {DISK_SPACE: ["E174.1"], USER_DEFAULTS: ["CA92.1"]})), None,
         {share: {DISK_SPACE: ["E174.1"]}, app: {DISK_SPACE: ["E174.1"], USER_DEFAULTS: ["CA92.1"]}}),
        # The reviewed reasons (P5): another code Apple allows for the category fails too.
        ("DDA9.1 instead of C617.1 in the extension", manifest(share, {FILE_TIMESTAMP: ["DDA9.1"]}),
         f"{share}: {FILE_TIMESTAMP} declares ['DDA9.1'], the reviewed reasons are ['C617.1']"),
        ("DDA9.1 instead of C617.1 in the app", manifest(app, {FILE_TIMESTAMP: ["DDA9.1"], USER_DEFAULTS: ["CA92.1"]}),
         f"{app}: {FILE_TIMESTAMP} declares ['DDA9.1'], the reviewed reasons are ['C617.1']"),
        ("a second reason", manifest(app, {FILE_TIMESTAMP: ["C617.1", "3B52.1"], USER_DEFAULTS: ["CA92.1"]}),
         "declares ['C617.1', '3B52.1'], the reviewed reasons are ['C617.1']"),
        ("the app group's UserDefaults reason", manifest(app, {FILE_TIMESTAMP: ["C617.1"], USER_DEFAULTS: ["1C8F.1"]}),
         f"{USER_DEFAULTS} declares ['1C8F.1'], the reviewed reasons are ['CA92.1']"),
        ("an unreviewed category that the code uses", both(
            write(f"{CORE}/Clock.swift", "let t = ProcessInfo.processInfo.systemUptime\n"),
            manifest(app, {**APP_FIXTURE, SYSTEM_BOOT_TIME: ["35F9.1"]})),
         f"{app}: {SYSTEM_BOOT_TIME} declares ['35F9.1'], the reviewed reasons are None"),
        ("fileModificationDate", both(write(f"{KIT}/Queue.swift", "let d = attributes.fileModificationDate()\n"),
                                      manifest(share, {})), f"the code uses {FILE_TIMESTAMP}"),
        ("a disk-space key", write("Dokumentum/Space.swift", "let k = URLResourceKey.volumeAvailableCapacityKey\n"),
         f"{app}: the code uses {DISK_SPACE}"),
        ("boot time", write(f"{CORE}/Clock.swift", "let t = mach_absolute_time()\n"), f"the code uses {SYSTEM_BOOT_TIME}"),
        ("keyboards", write("Dokumentum/Keys.swift", "let m = UITextInputMode.activeInputModes\n"),
         f"the code uses {ACTIVE_KEYBOARDS}"),
        ("a mention inside a comment does not count", both(
            write("DokumentumShare/Share.swift", "// UserDefaults.standard is not used here\n  /// nor mach_absolute_time\n"),
            write(f"{KIT}/Queue.swift", "/// fstat, as the docs say\nvar status = stat()\n")), None),
        ("a trailing comment counts", write("DokumentumShare/Share.swift", "let x = 1 // not UserDefaults\n"),
         f"{share}: the code uses {USER_DEFAULTS}"),
        ("a longer identifier is not the symbol", write("DokumentumShare/Share.swift",
                                                        "let statistics = myUserDefaultsStore\nlet stat_x = 1\n"), None),
        ("the test-support targets do not count", write(
            "Packages/DokumentumKit/Sources/DokumentumTestSupport/A.swift", "let d = UserDefaults.standard\n"), None),
        ("only fstat in the comment: declared but unused", write(f"{KIT}/Queue.swift", "// fstat\nlet x = 1\n"),
         f"declares {FILE_TIMESTAMP}, which no shipped source uses"),
        ("a folder without Swift files", remove("DokumentumShare/Share.swift"),
         "DokumentumShare: no Swift files found"),
    ]
    for description, mutate, expected, *rows in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_fixture(root)
            mutate(root)
            problems, _ = check(root, rows[0] if rows else None)
            if expected is None:
                assert not problems, f"{description}: expected no problem, got {problems}"
            else:
                assert any(expected in problem for problem in problems), \
                    f"{description}: expected {expected!r}, got {problems}"
    assert SYMBOLS["getattrlist"] == {FILE_TIMESTAMP, DISK_SPACE}
    assert SYMBOLS["getattrlistbulk"] == {FILE_TIMESTAMP}
    print(f"self-test passed ({len(cases) + 2} cases)")


def main():
    problems, report = check(pathlib.Path.cwd())
    for problem in problems:
        print(f"error: {problem}")
    if problems:
        return 1
    for line in report:
        print(line)
    print("the privacy manifests match the code")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main())
