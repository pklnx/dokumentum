#!/usr/bin/env python3
"""Checks that every UI string has a German translation. Two modes:

    python3 scripts/check-localization.py --catalog            # Linux, no build
    python3 scripts/check-localization.py <derived data path>  # after a build of the app
    python3 scripts/check-localization.py --self-test

Two catalogs, one per target that shows text: the app's Dokumentum/Localizable.xcstrings and the
share extension's DokumentumShare/Localizable.xcstrings (plan of #4, part 4).

--catalog reads the catalogs alone: every entry needs a finished German translation (a plural needs
German `one` and `other`, otherwise German reads "1 Dokumente"), and no entry may be `stale` (the
code no longer uses it). This is the `localization` check.

The build mode also finds strings that never reached their catalog. Swift writes the strings it
localizes into `.stringsdata` files during the build, per target. Xcode's IDE adds new ones to the
String Catalog automatically, but `xcodebuild` does not, so a new UI text could ship untranslated.
This mode compares each target's strings with its own catalog; ci_scripts/ci_post_xcodebuild.sh runs
it in Xcode Cloud. The app's strings must be there. The extension is built for iOS only, so a macOS
build has none of its strings; they are required once its target was built (its build folder exists).

Exit code 1 lists the keys.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Per target: its catalog, where its .stringsdata are (the project folder <Project>.build holds one
# <Target>.build per target), and whether a build must always have produced them.
TARGETS = [
    {"name": "Dokumentum", "catalog": ROOT / "Dokumentum" / "Localizable.xcstrings",
     "build": "**/Dokumentum.build/*/Dokumentum.build", "always": True},
    {"name": "DokumentumShare", "catalog": ROOT / "DokumentumShare" / "Localizable.xcstrings",
     "build": "**/Dokumentum.build/*/DokumentumShare.build", "always": False},
]


def german_units(entry):
    """The German string units of an entry: one, or one per plural variation. A plural entry
    needs both `one` and `other`; a missing one counts as one untranslated unit."""
    german = entry.get("localizations", {}).get("de", {})
    plural = german.get("variations", {}).get("plural")
    if plural:
        if "one" not in plural or "other" not in plural:
            return [{}]
        return [variant.get("stringUnit", {}) for variant in plural.values()]
    return [german.get("stringUnit", {})]


def untranslated(used, catalog):
    """The used keys without a finished German translation, sorted."""
    return [key for key in sorted(used)
            if any(unit.get("state") != "translated" or not unit.get("value")
                   for unit in german_units(catalog.get(key, {})))]


def catalog_problems(catalog):
    """The problems of a whole catalog, for --catalog."""
    if not catalog:
        return ["the catalog has no entries"]
    problems = [f"{key!r}: no finished German translation" for key in untranslated(catalog, catalog)]
    problems += [f"{key!r}: stale, the code no longer uses it (remove it)"
                 for key, entry in sorted(catalog.items()) if entry.get("extractionState") == "stale"]
    return problems


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def self_test():
    def entry(plural=None, plain=None, **fields):
        german = {}
        if plural is not None:
            german["variations"] = {"plural": {name: unit(text) for name, text in plural.items()}}
        if plain is not None:
            german.update(unit(plain))
        return {"localizations": {"de": german}, **fields}

    catalog = {
        "plain": entry(plain="Text"),
        "plural": entry(plural={"one": "1 Dokument", "other": "%lld Dokumente"}),
        "plural without one": entry(plural={"other": "%lld Dokumente"}),
        "plural without other": entry(plural={"one": "1 Dokument"}),
        "plural with an extra zero": entry(plural={"zero": "keine", "one": "1", "other": "%lld"}),
        "untranslated": {"localizations": {"de": {"stringUnit": {"state": "new", "value": "x"}}}},
        "empty": entry(plain=""),
        "plural one not translated": {"localizations": {"de": {"variations": {"plural": {
            "one": {"stringUnit": {"state": "new", "value": "1"}}, "other": unit("%lld")}}}}},
    }
    expected = ["empty", "missing", "plural one not translated", "plural without one", "plural without other",
                "untranslated"]
    found = untranslated(list(catalog) + ["missing"], catalog)
    assert found == expected, f"expected {expected}, got {found}"

    # --catalog: each case is the number of problems of a whole catalog.
    fine = entry(plain="Text")
    cases = [
        ("all translated", {"a": fine, "b": entry(plural={"one": "1", "other": "%lld"})}, 0),
        ("no entries", {}, 1),
        ("no German at all", {"a": {}}, 1),
        ("state new", {"a": {"localizations": {"de": {"stringUnit": {"state": "new", "value": "x"}}}}}, 1),
        ("plural without one", {"a": entry(plural={"other": "%lld"})}, 1),
        ("plural without other", {"a": entry(plural={"one": "1"})}, 1),
        ("translated but stale", {"a": entry(plain="Text", extractionState="stale")}, 1),
        ("untranslated and stale", {"a": {"extractionState": "stale"}}, 2),
        ("manual is fine", {"a": entry(plain="Text", extractionState="manual")}, 0),
    ]
    for name, whole, count in cases:
        problems = catalog_problems(whole)
        assert len(problems) == count, f"{name}: expected {count} problem(s), got {problems}"
    build_cases = self_test_targets(fine)
    print(f"self-test passed ({len(catalog) + 1 + len(cases) + build_cases} cases)")


def self_test_targets(fine):
    """Both modes over two targets in a temporary folder: each target against its own catalog, and the
    extension's strings required only once it was built. Returns the number of cases."""
    import contextlib
    import io
    import tempfile

    def write_json(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def stringsdata(root, target, keys):
        write_json(root / "derived" / "Build/Intermediates.noindex/Dokumentum.build/Debug-iphonesimulator"
                   / f"{target}.build" / "Objects-normal/arm64/View.stringsdata",
                   {"source": f"/src/{target}/View.swift",
                    "tables": {"Localizable": [{"key": key} for key in keys]}})

    def run(check, *arguments):
        with contextlib.redirect_stdout(io.StringIO()):
            return check(*arguments)

    cases = 0
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        targets = [
            {"name": "App", "catalog": root / "App.xcstrings", "build": "**/Dokumentum.build/*/App.build", "always": True},
            {"name": "Share", "catalog": root / "Share.xcstrings", "build": "**/Dokumentum.build/*/Share.build",
             "always": False},
        ]
        write_json(targets[0]["catalog"], {"strings": {"Inbox": fine}})
        write_json(targets[1]["catalog"], {"strings": {"Saving": fine}})
        assert run(check_catalog, targets) == 0, "two fine catalogs pass"
        write_json(targets[1]["catalog"], {"strings": {"Saving": {}}})
        assert run(check_catalog, targets) == 1, "an untranslated entry in the second catalog fails"
        write_json(targets[1]["catalog"], {"strings": {"Saving": fine}})
        assert run(check_catalog, targets + [{**targets[1], "catalog": root / "missing.xcstrings"}]) == 1, \
            "a missing catalog fails"
        cases += 3

        derived = root / "derived"
        stringsdata(root, "App", ["Inbox"])
        assert run(check_build, derived, targets) == 0, "the extension not built (macOS) is skipped"
        stringsdata(root, "Share", ["Saving"])
        assert run(check_build, derived, targets) == 0, "each target against its own catalog"
        stringsdata(root, "Share", ["Inbox"])
        assert run(check_build, derived, targets) == 1, "the app's string does not count for the extension"
        stringsdata(root, "Share", [])
        assert run(check_build, derived, targets) == 1, "the extension built without strings fails"
        stringsdata(root, "App", [])
        stringsdata(root, "Share", ["Saving"])
        assert run(check_build, derived, targets) == 1, "the app without strings fails"
        cases += 5
    return cases


def load_catalog(path):
    return json.loads(path.read_text(encoding="utf-8"))["strings"]


def relative(path):
    return path.relative_to(ROOT) if path.is_relative_to(ROOT) else path


def check_catalog(targets=TARGETS):
    failed = False
    for target in targets:
        name = relative(target["catalog"])
        if not target["catalog"].is_file():
            print(f"error: {name} is missing")
            failed = True
            continue
        problems = catalog_problems(load_catalog(target["catalog"]))
        for problem in problems:
            print(f"error: {name}: {problem}")
        if problems:
            failed = True
        else:
            print(f"{name}: every entry has a finished German translation, none is stale.")
    if failed:
        print("Fix them in Xcode (the catalog editor) or by hand.")
        return 1
    return 0


def used_strings(derived_data, build_pattern):
    """The keys of the Localizable table in a target's .stringsdata, each with a file that uses it, and whether
    the target's build folder exists at all."""
    used = {}
    folders = list(derived_data.glob(build_pattern))
    for folder in folders:
        for path in folder.glob("**/*.stringsdata"):
            data = json.loads(path.read_text(encoding="utf-8"))
            for entry in data.get("tables", {}).get("Localizable", []):
                used.setdefault(entry["key"], data.get("source", str(path)))
    return used, bool(folders)


def check_build(derived_data, targets=TARGETS):
    failed = False
    for target in targets:
        used, built = used_strings(derived_data, target["build"])
        if not used:
            if target["always"] or built:
                print(f"error: no UI strings of {target['name']} found in .stringsdata files under {derived_data}. "
                      f"Build the app first, with -derivedDataPath {derived_data}.")
                failed = True
            else:
                print(f"{target['name']} was not built (an iOS-only target in another platform's build); skipped.")
            continue
        catalog = load_catalog(target["catalog"])
        problems = [f"  {key!r}  (used in {pathlib.Path(used[key]).name})" for key in untranslated(used, catalog)]
        if problems:
            print(f"UI strings of {target['name']} without a German translation in {relative(target['catalog'])}:")
            print("\n".join(problems))
            print("Add them in Xcode (the catalog editor lists new strings after a build) or by hand.")
            failed = True
        else:
            print(f"All {len(used)} UI strings of {target['name']} have a German translation.")
    return 1 if failed else 0


def main(arguments):
    if arguments == ["--self-test"]:
        self_test()
        return 0
    if arguments == ["--catalog"]:
        return check_catalog()
    if len(arguments) == 1 and not arguments[0].startswith("-"):
        return check_build(pathlib.Path(arguments[0]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
