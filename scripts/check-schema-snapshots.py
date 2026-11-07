#!/usr/bin/env python3
"""Checks the committed schema snapshots (docs/development/index.md, "Data model and sync").

`Packages/DokumentumCore/Tests/DokumentumCoreTests/Schema/schema-v<N>.txt` is the dump of schema version N
that `SchemaTests` writes and compares with the code. This script reads only the files, so it runs on
Linux in `lint`. It fails when:

- the versions are not 1, 2, ..., N without a gap, or a file cannot be read;
- any version breaks a CloudKit rule: an attribute that is neither optional nor defaulted, a
  relationship that is not optional, has no inverse, is ordered or has the delete rule `deny`, an entity
  with a uniqueness constraint;
- version N drops or changes anything of version N-1: every entity line and every property line of N-1
  must be in N unchanged (same type, optionality, default, delete rule, inverse). Only additions pass;
- a version listed in `production-versions.txt` (deployed to Production, step 8) differs from its file at
  the base commit (`--base <sha>`), or is missing. The listed versions are the union of the file at the
  base and at the head, so removing an entry in the same change does not lift the freeze; removing one
  fails on its own. Only a version newly listed in this change and without a file at the base is not
  compared. Without `--base`, listed versions fail the check, so CI always passes the base. A `--base`
  that is not a commit of this repository, or a file that cannot be read there, is an error.

    python3 scripts/check-schema-snapshots.py                    # from the repository root
    python3 scripts/check-schema-snapshots.py --base <base sha>  # what CI runs
    python3 scripts/check-schema-snapshots.py --self-test
"""
import os
import re
import subprocess
import sys
import tempfile

SCHEMA_DIR = "Packages/DokumentumCore/Tests/DokumentumCoreTests/Schema"
PRODUCTION_FILE = "production-versions.txt"
SNAPSHOT = re.compile(r"^schema-v(\d+)\.txt$")
REQUIRED = {
    "entity": {"uniqueness"},
    "attribute": {"type", "optional", "default"},
    "relationship": {"to", "many", "optional", "inverse", "delete", "ordered"},
}
LINE = re.compile(r"^(entity|attribute|relationship) (\S+)((?: \S+=\S+)*)$")


def parse(text: str, label: str):
    """Returns ({key: line}, {key: fields}, problems) for one snapshot."""
    lines, fields, problems = {}, {}, []
    for number, raw in enumerate(text.split("\n"), start=1):
        line = raw.rstrip()
        if not line or line.startswith("#"):
            continue
        match = LINE.match(line)
        if not match:
            problems.append(f"{label}:{number}: cannot read {line!r}")
            continue
        kind, name, rest = match.groups()
        values = dict(item.split("=", 1) for item in rest.split())
        missing = sorted(REQUIRED[kind] - values.keys())
        if missing or (kind != "entity") != ("." in name):
            problems.append(f"{label}:{number}: cannot read {line!r} (missing {', '.join(missing) or 'a name'})")
            continue
        key = f"{kind} {name}"
        if key in lines:
            problems.append(f"{label}:{number}: {key} appears twice")
        lines[key] = line
        fields[key] = values
    return lines, fields, problems


def rule_problems(fields, label: str):
    problems = []
    for key, values in sorted(fields.items()):
        kind, name = key.split(" ", 1)
        if kind == "entity" and values.get("uniqueness") != "none":
            problems.append(f"{label}: {name} has a uniqueness constraint (CloudKit has none)")
        elif kind == "attribute" and values.get("optional") != "yes" and values.get("default", "none") == "none":
            problems.append(f"{label}: {name} is neither optional nor defaulted (CloudKit needs one)")
        elif kind == "relationship":
            if values.get("optional") != "yes":
                problems.append(f"{label}: {name} is not optional (CloudKit needs optional relationships)")
            if values.get("inverse", "none") == "none":
                problems.append(f"{label}: {name} has no inverse (CloudKit needs one)")
            if values.get("delete") == "deny":
                problems.append(f"{label}: {name} has the delete rule deny (CloudKit does not support it)")
            if values.get("ordered") == "yes":
                problems.append(f"{label}: {name} is ordered (CloudKit does not support it)")
    return problems


def additive_problems(old_lines, new_lines, old_label: str, new_label: str):
    problems = []
    for key, line in sorted(old_lines.items()):
        if key not in new_lines:
            problems.append(f"{new_label}: {key} of {old_label} is gone; schema changes are additive only")
        elif new_lines[key] != line:
            problems.append(f"{new_label}: {key} changed from {old_label} ({line!r} -> {new_lines[key]!r}); "
                            "schema changes are additive only")
    return problems


class BaseUnreadable(Exception):
    """`--base` is not a commit of this repository, or a file cannot be read there."""


def read_base(base: str, path: str):
    """The file at `path` in commit `base`; None if the commit has no such file. Raises `BaseUnreadable`
    if `base` is not a commit here or the file cannot be read, so an unknown base never reads as "absent"."""
    commit = subprocess.run(["git", "cat-file", "-e", f"{base}^{{commit}}"], capture_output=True)
    if commit.returncode != 0:
        raise BaseUnreadable(f"--base {base!r} is not a commit of this repository")
    exists = subprocess.run(["git", "cat-file", "-e", f"{base}:{path}"], capture_output=True)
    if exists.returncode != 0:
        return None
    result = subprocess.run(["git", "show", f"{base}:{path}"], capture_output=True)
    if result.returncode != 0:
        raise BaseUnreadable(f"{path} cannot be read at {base}")
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError:
        raise BaseUnreadable(f"{path} at {base} is not UTF-8")


def production_entries(text: str):
    """The entries of a `production-versions.txt`: one per line, without comments and blank lines."""
    return [line.strip() for line in text.split("\n") if line.strip() and not line.strip().startswith("#")]


def check(schema_dir: str, base=None, read_at_base=read_base):
    problems = []
    if not os.path.isdir(schema_dir):
        return [f"{schema_dir}: missing; run the script from the repository root"]
    versions = {}
    for name in os.listdir(schema_dir):
        match = SNAPSHOT.match(name)
        if match:
            versions[int(match.group(1))] = os.path.join(schema_dir, name)
    if not versions:
        return [f"{schema_dir}: no schema-v<N>.txt"]
    numbers = sorted(versions)
    if numbers != list(range(1, len(numbers) + 1)):
        problems.append(f"{schema_dir}: versions must be 1 to N without a gap, found {numbers}")
    parsed = {}
    texts = {}
    for number in numbers:
        with open(versions[number], encoding="utf-8") as handle:
            texts[number] = handle.read()
        label = f"schema-v{number}.txt"
        lines, fields, parse_problems = parse(texts[number], label)
        problems += parse_problems
        if not any(key.startswith("entity ") for key in lines):
            problems.append(f"{label}: no entity")
        problems += rule_problems(fields, label)
        parsed[number] = lines
    for number in numbers:
        if number - 1 in parsed:
            problems += additive_problems(parsed[number - 1], parsed[number],
                                          f"schema-v{number - 1}.txt", f"schema-v{number}.txt")
    production_path = os.path.join(schema_dir, PRODUCTION_FILE)
    if not os.path.isfile(production_path):
        problems.append(f"{production_path}: missing (empty until the first Production deploy)")
        return problems
    with open(production_path, encoding="utf-8") as handle:
        entries = production_entries(handle.read())
    base_entries = []
    if base is not None:
        try:
            base_production = read_at_base(base, f"{SCHEMA_DIR}/{PRODUCTION_FILE}")
        except BaseUnreadable as error:
            return problems + [str(error)]
        base_entries = production_entries(base_production or "")
    for entry in base_entries:
        if entry not in entries:
            problems.append(f"{PRODUCTION_FILE}: {entry!r} was listed at {base} and is gone; a version in "
                            "Production stays listed")
    for entry in sorted(set(entries) | set(base_entries)):
        if not entry.isdigit():
            problems.append(f"{PRODUCTION_FILE}: {entry!r} is not a version number")
            continue
        number = int(entry)
        label = f"schema-v{number}.txt"
        if number not in texts:
            problems.append(f"{PRODUCTION_FILE}: version {number} is in Production but {label} is missing")
            continue
        if base is None:
            problems.append(f"{PRODUCTION_FILE}: version {number} is in Production; pass --base <sha> to compare it")
            continue
        try:
            at_base = read_at_base(base, f"{SCHEMA_DIR}/{label}")
        except BaseUnreadable as error:
            problems.append(str(error))
            continue
        if at_base is None:
            if entry in base_entries:
                problems.append(f"{label}: missing at {base}, but version {number} was listed in Production there")
            # Otherwise listed in this change, with its file new here too: nothing to compare.
            continue
        if at_base != texts[number]:
            problems.append(f"{label}: changed against {base}, but version {number} is in Production; "
                            "add a new version instead")
    return problems


def self_test() -> None:
    v1 = (
        "# V1\n"
        "entity Document uniqueness=none\n"
        "attribute Document.title type=string optional=no default=\"\" external=no transient=no\n"
        "attribute Document.deletedAt type=date optional=yes default=none external=no transient=no\n"
        "relationship Document.tags to=Tag many=yes optional=yes inverse=documents delete=nullify ordered=no\n"
        "entity Tag uniqueness=none\n"
        "relationship Tag.documents to=Document many=yes optional=yes inverse=tags delete=nullify ordered=no\n"
    )
    UNKNOWN_BASE, UNREADABLE_SNAPSHOT = "unknown base", "unreadable snapshot"
    v2 = v1 + "attribute Document.notes type=string optional=no default=\"\" external=no transient=no\n"

    def run(files, production="", base_files=None, base="BASE"):
        with tempfile.TemporaryDirectory() as root:
            schema = os.path.join(root, "Schema")
            os.makedirs(schema)
            for name, text in files.items():
                with open(os.path.join(schema, name), "w", encoding="utf-8") as handle:
                    handle.write(text)
            if production is not None:
                with open(os.path.join(schema, PRODUCTION_FILE), "w", encoding="utf-8") as handle:
                    handle.write(production)

            def at_base(_base, path):
                if base_files == UNKNOWN_BASE:
                    raise BaseUnreadable(f"--base {_base!r} is not a commit of this repository")
                if base_files == UNREADABLE_SNAPSHOT and os.path.basename(path) != PRODUCTION_FILE:
                    raise BaseUnreadable(f"{path} cannot be read at {_base}")
                if base_files == UNREADABLE_SNAPSHOT:
                    return production
                return (base_files or {}).get(os.path.basename(path))
            return check(schema, base=base, read_at_base=at_base)

    cases = [
        # (description, files, production file, base files, base, expected substring or None)
        ("one valid version", {"schema-v1.txt": v1}, "", None, None, None),
        ("an added optional attribute", {"schema-v1.txt": v1, "schema-v2.txt": v2}, "", None, None, None),
        ("a removed attribute", {"schema-v1.txt": v1,
                                 "schema-v2.txt": v1.replace("attribute Document.deletedAt", "# gone")},
         "", None, None, "is gone"),
        ("a removed entity", {"schema-v1.txt": v1, "schema-v2.txt": v1.split("entity Tag")[0]}, "", None, None,
         "is gone"),
        ("a changed type", {"schema-v1.txt": v1, "schema-v2.txt": v1.replace("Document.deletedAt type=date",
                                                                             "Document.deletedAt type=string")},
         "", None, None, "changed from"),
        ("a changed optionality", {"schema-v1.txt": v1, "schema-v2.txt": v1.replace(
            "deletedAt type=date optional=yes default=none", "deletedAt type=date optional=no default=generated")},
         "", None, None, "changed from"),
        ("a changed delete rule", {"schema-v1.txt": v1, "schema-v2.txt": v1.replace(
            "inverse=documents delete=nullify", "inverse=documents delete=cascade")}, "", None, None, "changed from"),
        ("a new attribute without default", {"schema-v1.txt": v1, "schema-v2.txt": v1 + (
            "attribute Document.asn type=int64 optional=no default=none external=no transient=no\n")},
         "", None, None, "neither optional nor defaulted"),
        ("a required relationship", {"schema-v1.txt": v1.replace(
            "many=yes optional=yes inverse=documents", "many=yes optional=no inverse=documents")},
         "", None, None, "is not optional"),
        ("a relationship without inverse", {"schema-v1.txt": v1.replace("inverse=documents", "inverse=none")},
         "", None, None, "has no inverse"),
        ("a deny rule", {"schema-v1.txt": v1.replace("inverse=tags delete=nullify", "inverse=tags delete=deny")},
         "", None, None, "deny"),
        ("an ordered relationship", {"schema-v1.txt": v1.replace("inverse=tags delete=nullify ordered=no",
                                                                 "inverse=tags delete=nullify ordered=yes")},
         "", None, None, "is ordered"),
        ("a uniqueness constraint", {"schema-v1.txt": v1.replace("entity Tag uniqueness=none",
                                                                 "entity Tag uniqueness=id")},
         "", None, None, "uniqueness constraint"),
        ("a gap in the versions", {"schema-v1.txt": v1, "schema-v3.txt": v2}, "", None, None, "without a gap"),
        ("no version 1", {"schema-v2.txt": v1}, "", None, None, "without a gap"),
        ("no snapshot", {}, "", None, None, "no schema-v"),
        ("an unreadable line", {"schema-v1.txt": v1 + "attribute broken\n"}, "", None, None, "cannot read"),
        ("an attribute without its fields", {"schema-v1.txt": v1 + "attribute Document.x type=string\n"},
         "", None, None, "cannot read"),
        ("an entity name with a dot", {"schema-v1.txt": v1 + "entity Document.x uniqueness=none\n"},
         "", None, None, "cannot read"),
        ("a line twice", {"schema-v1.txt": v1 + "entity Tag uniqueness=none\n"}, "", None, None, "appears twice"),
        ("no production file", {"schema-v1.txt": v1}, None, None, None, "missing"),
        ("production without base", {"schema-v1.txt": v1}, "1\n", None, None, "pass --base"),
        ("production unchanged at base", {"schema-v1.txt": v1}, "1\n", {"schema-v1.txt": v1}, "BASE", None),
        ("production changed at base", {"schema-v1.txt": v2}, "1\n", {"schema-v1.txt": v1}, "BASE",
         "is in Production"),
        ("production listed in this change", {"schema-v1.txt": v1}, "1\n", {}, "BASE", None),
        ("production version without file", {"schema-v1.txt": v1}, "2\n", None, "BASE", "is missing"),
        ("production entry not a number", {"schema-v1.txt": v1}, "v1\n", None, "BASE", "not a version"),
        ("a later version may change while V1 alone is in Production",
         {"schema-v1.txt": v1, "schema-v2.txt": v2}, "1\n", {"schema-v1.txt": v1, "schema-v2.txt": v1}, "BASE",
         None),
        # The freeze holds the union of the base's and the head's list (reviews of #52).
        ("production entry removed and its version changed in one change", {"schema-v1.txt": v2}, "",
         {"schema-v1.txt": v1, PRODUCTION_FILE: "1\n"}, "BASE", "is in Production"),
        ("production entry removed", {"schema-v1.txt": v1}, "",
         {"schema-v1.txt": v1, PRODUCTION_FILE: "1\n"}, "BASE", "is gone"),
        ("production entry kept, a comment added", {"schema-v1.txt": v1}, "# deployed\n1\n",
         {"schema-v1.txt": v1, PRODUCTION_FILE: "1\n"}, "BASE", None),
        ("production listed at base, its snapshot missing there", {"schema-v1.txt": v1}, "1\n",
         {PRODUCTION_FILE: "1\n"}, "BASE", "missing at"),
        # An unknown or unreadable base is an error, never "listed in this change".
        ("production with an unknown base", {"schema-v1.txt": v2}, "1\n", UNKNOWN_BASE, "0" * 40,
         "is not a commit"),
        ("nothing in production, an unknown base", {"schema-v1.txt": v1}, "", UNKNOWN_BASE, "0" * 40,
         "is not a commit"),
        ("production with an unreadable snapshot at base", {"schema-v1.txt": v2}, "1\n", UNREADABLE_SNAPSHOT,
         "BASE", "cannot be read"),
    ]
    for description, files, production, base_files, base, expected in cases:
        problems = run(files, production, base_files, base)
        if expected is None:
            assert problems == [], f"{description}: expected no problems, got {problems}"
        else:
            assert any(expected in problem for problem in problems), \
                f"{description}: expected a problem with {expected!r}, got {problems}"
    # The committed snapshots pass on their own, so the cases above run against a format that exists.
    if os.path.isdir(SCHEMA_DIR):
        assert check(SCHEMA_DIR, base="HEAD") == [], "the committed snapshots fail the check"
        # The real reader: a commit that does not exist is an error, a file the commit lacks is None.
        try:
            read_base("0" * 40, f"{SCHEMA_DIR}/{PRODUCTION_FILE}")
            raise AssertionError("read_base accepted an unknown commit")
        except BaseUnreadable:
            pass
        assert read_base("HEAD", f"{SCHEMA_DIR}/schema-v0.txt") is None, "read_base: a missing file is not None"
        assert check(SCHEMA_DIR, base="0" * 40) != [], "an unknown --base passes the check"
    print(f"self-test passed ({len(cases)} cases)")


def main(arguments) -> int:
    base = None
    if arguments[:1] == ["--base"] and len(arguments) == 2:
        base = arguments[1] or None
    elif arguments:
        print("usage: check-schema-snapshots.py [--base <sha>] | --self-test")
        return 2
    problems = check(SCHEMA_DIR, base=base)
    for problem in problems:
        print(f"error: {problem}")
    if problems:
        return 1
    print("schema snapshots are additive and meet the CloudKit rules")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main(sys.argv[1:]))
