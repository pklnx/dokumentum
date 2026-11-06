#!/usr/bin/env python3
"""Checks that every UI string has a German translation. Two modes:

    python3 scripts/check-localization.py --catalog            # Linux, no build
    python3 scripts/check-localization.py <derived data path>  # after a build of the app
    python3 scripts/check-localization.py --self-test

--catalog reads Dokumentum/Localizable.xcstrings alone: every entry needs a finished German
translation (a plural needs German `one` and `other`, otherwise German reads "1 Dokumente"), and no
entry may be `stale` (the code no longer uses it). This is the `localization` check.

The build mode also finds strings that never reached the catalog. Swift writes the strings it
localizes into `.stringsdata` files during the build. Xcode's IDE adds new ones to the String
Catalog automatically, but `xcodebuild` does not, so a new UI text could ship untranslated. This
mode compares the two; ci_scripts/ci_post_xcodebuild.sh runs it in Xcode Cloud.

Exit code 1 lists the keys.
"""
import json
import pathlib
import sys

CATALOG = pathlib.Path(__file__).resolve().parent.parent / "Dokumentum" / "Localizable.xcstrings"
# The app target only: the project folder <Project>.build holds one <Target>.build per target.
STRINGSDATA = "**/Dokumentum.build/*/Dokumentum.build/**/*.stringsdata"


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
    print(f"self-test passed ({len(catalog) + 1 + len(cases)} cases)")


def load_catalog():
    return json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]


def check_catalog():
    problems = catalog_problems(load_catalog())
    for problem in problems:
        print(f"error: {CATALOG.name}: {problem}")
    if problems:
        print("Fix them in Xcode (the catalog editor) or by hand.")
        return 1
    print(f"{CATALOG.name}: every entry has a finished German translation, none is stale.")
    return 0


def check_build(derived_data):
    used = {}
    for path in derived_data.glob(STRINGSDATA):
        data = json.loads(path.read_text(encoding="utf-8"))
        for entry in data.get("tables", {}).get("Localizable", []):
            used.setdefault(entry["key"], data.get("source", str(path)))
    if not used:
        print(f"error: no UI strings found in .stringsdata files under {derived_data}. "
              f"Build the app first, with -derivedDataPath {derived_data}.")
        return 1
    catalog = load_catalog()
    problems = [f"  {key!r}  (used in {pathlib.Path(used[key]).name})" for key in untranslated(used, catalog)]
    if problems:
        print(f"UI strings without a German translation in {CATALOG.name}:")
        print("\n".join(problems))
        print("Add them in Xcode (the catalog editor lists new strings after a build) or by hand.")
        return 1
    print(f"All {len(used)} UI strings have a German translation.")
    return 0


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
