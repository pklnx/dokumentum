#!/usr/bin/env python3
"""Checks .github/labels.json before it is merged, so a mistake fails on the pull request and not
only in the label sync on main (.github/workflows/labels.yml): the file must be valid JSON, a
list of labels with a name, a six-digit hex color and a description of at most 100 characters
(GitHub rejects longer ones), and names must be unique.

    python3 scripts/check-labels.py                 # from the repository root
    python3 scripts/check-labels.py --self-test
"""
import json
import re
import sys

LABELS = ".github/labels.json"
MAX_DESCRIPTION = 100


def check(text: str):
    """The problems of a labels.json text (empty when it is fine)."""
    try:
        labels = json.loads(text)
    except ValueError as error:
        return [f"not valid JSON: {error}"]
    if not isinstance(labels, list):
        return ["the top level must be a list of labels"]
    problems = []
    names = set()
    for index, label in enumerate(labels):
        if not isinstance(label, dict) or not isinstance(label.get("name"), str) or not label["name"]:
            problems.append(f"entry {index}: no name")
            continue
        name = label["name"]
        if name in names:
            problems.append(f"{name}: defined twice")
        names.add(name)
        if not re.fullmatch(r"[0-9a-fA-F]{6}", str(label.get("color", ""))):
            problems.append(f"{name}: color must be six hex digits")
        description = label.get("description", "")
        if not isinstance(description, str):
            problems.append(f"{name}: description must be a string")
        elif len(description) > MAX_DESCRIPTION:
            problems.append(f"{name}: description has {len(description)} characters (limit {MAX_DESCRIPTION})")
    return problems


def self_test() -> None:
    def label(name="bug", color="d73a4a", description="Something is not working"):
        return {"name": name, "color": color, "description": description}

    cases = [
        ("valid", json.dumps([label(), label("docs")]), 0),
        ("exactly 100 characters", json.dumps([label(description="x" * 100)]), 0),
        ("101 characters", json.dumps([label(description="x" * 101)]), 1),
        ("no description", json.dumps([{"name": "bug", "color": "d73a4a"}]), 0),
        ("invalid JSON", '[{"name": "bug",]', 1),
        ("not a list", json.dumps({"name": "bug"}), 1),
        ("duplicate name", json.dumps([label(), label()]), 1),
        ("bad color", json.dumps([label(color="red")]), 1),
        ("no name", json.dumps([{"color": "d73a4a"}]), 1),
    ]
    for description, text, expected in cases:
        problems = check(text)
        assert len(problems) == expected, f"{description}: expected {expected} problem(s), got {problems}"
    print(f"self-test passed ({len(cases)} cases)")


def main() -> int:
    with open(LABELS, encoding="utf-8") as handle:
        problems = check(handle.read())
    for problem in problems:
        print(f"error: {LABELS}: {problem}")
    if not problems:
        print(f"{LABELS} is fine")
    return 1 if problems else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main())
