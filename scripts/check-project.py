#!/usr/bin/env python3
"""Guards the invariants of Dokumentum.xcodeproj that a reviewer cannot easily see in a .pbxproj
diff. Python only, so it also runs on Linux (the `lint` check):

- Config/Project.xcconfig is the project's base configuration, and no target has its own.
- No project or target build configuration sets a key that the xcconfig sets, or one of the keys
  that must only ever live there: a setting in the .pbxproj overrides the xcconfig without a trace,
  and Xcode's template and capability editor write exactly these. The team must not appear in the
  target attributes either.
- The entitlements files that the xcconfig names exist.
- The shared scheme exists and references both test plans; Xcode Cloud only sees shared schemes.
- The test plans hold exactly the expected test targets, and each one resolves. A plan's target in
  a local package needs a folder reference to that package in the project: without one xcodebuild
  drops the target silently and reports success.
- The Xcode Cloud scripts exist and are executable (Xcode Cloud ignores them otherwise), and
  .xcode-version holds a version.

    python3 scripts/check-project.py                 # from the repository root
    python3 scripts/check-project.py --self-test
"""
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree

PROJECT = "Dokumentum.xcodeproj/project.pbxproj"
XCCONFIG = "Config/Project.xcconfig"
SCHEME = "Dokumentum.xcodeproj/xcshareddata/xcschemes/Dokumentum.xcscheme"
XCODE_VERSION = ".xcode-version"
CI_SCRIPTS = ["ci_scripts/ci_post_clone.sh", "ci_scripts/ci_post_xcodebuild.sh"]
TEST_PLANS = {
    "TestPlans/Default.xctestplan": {"DokumentumTests", "DokumentumKitTests", "DokumentumCoreTests"},
    "TestPlans/UISmoke.xctestplan": {"DokumentumUITests"},
}
# Never in the .pbxproj, whether or not the xcconfig sets them at the moment.
XCCONFIG_ONLY = {
    "CODE_SIGN_ENTITLEMENTS",
    "DEVELOPMENT_TEAM",
    "IPHONEOS_DEPLOYMENT_TARGET",
    "MACOSX_DEPLOYMENT_TARGET",
    "PRODUCT_BUNDLE_IDENTIFIER",
    "SWIFT_VERSION",
}


def parse_plist(text):
    """Parses the old-style (OpenStep) property list format of a .pbxproj into dicts, lists and strings."""
    token = re.compile(r'\s+|//[^\n]*|/\*.*?\*/|"((?:[^"\\]|\\.)*)"|([\w$/.:\-]+)|([{}()=;,])', re.S)
    tokens = []
    position = 0
    while position < len(text):
        match = token.match(text, position)
        if not match:
            raise ValueError(f"unexpected character {text[position]!r} at offset {position}")
        position = match.end()
        if match.group(1) is not None:
            tokens.append(("string", re.sub(r"\\(.)", r"\1", match.group(1))))
        elif match.group(2) is not None:
            tokens.append(("string", match.group(2)))
        elif match.group(3) is not None:
            tokens.append((match.group(3), match.group(3)))

    index = 0

    def expect(kind):
        nonlocal index
        if index >= len(tokens) or tokens[index][0] != kind:
            found = tokens[index][1] if index < len(tokens) else "the end"
            raise ValueError(f"expected {kind!r}, found {found!r}")
        index += 1
        return tokens[index - 1][1]

    def value():
        nonlocal index
        if index >= len(tokens):
            raise ValueError("unexpected end")
        kind, text_value = tokens[index]
        if kind == "string":
            index += 1
            return text_value
        if kind == "{":
            index += 1
            result = {}
            while tokens[index][0] != "}":
                key = expect("string")
                expect("=")
                result[key] = value()
                expect(";")
            index += 1
            return result
        if kind == "(":
            index += 1
            result = []
            while tokens[index][0] != ")":
                result.append(value())
                if tokens[index][0] != ")":
                    expect(",")
            index += 1
            return result
        raise ValueError(f"unexpected {text_value!r}")

    try:
        result = value()
    except IndexError:
        raise ValueError("unexpected end") from None
    if index != len(tokens):
        raise ValueError(f"unexpected {tokens[index][1]!r} after the end")
    return result


def parse_xcconfig(text):
    """The settings of an xcconfig: {key: [(condition, value)]}. The key has no [sdk=...] condition."""
    settings = {}
    for line in text.splitlines():
        match = re.match(r"\s*([A-Za-z_]\w*)((?:\[[^\]]*\])*)\s*=\s*(.*?)\s*$", line)
        if match:
            settings.setdefault(match.group(1), []).append((match.group(2), match.group(3)))
    return settings


def setting_name(key):
    """A build setting's name without its condition: `KEY[sdk=macosx*]` becomes `KEY`."""
    return key.split("[", 1)[0]


def file_reference_paths(objects, group_id, prefix=""):
    """{object id: path relative to the project} for everything below a group."""
    paths = {}
    group = objects.get(group_id, {})
    for child_id in group.get("children", []):
        child = objects.get(child_id, {})
        path = child.get("path", "")
        full = str(pathlib.PurePosixPath(prefix, path)) if path else prefix
        if child.get("isa") == "PBXGroup":
            paths.update(file_reference_paths(objects, child_id, full))
        elif child.get("sourceTree") == "<group>":
            paths[child_id] = full
    return paths


def check_build_configurations(objects, project, paths, xcconfig_keys):
    problems = []
    protected = xcconfig_keys | XCCONFIG_ONLY
    configurations = objects.get(project.get("buildConfigurationList"), {}).get("buildConfigurations", [])
    if not configurations:
        problems.append("the project has no build configurations")
    for configuration_id in configurations:
        configuration = objects.get(configuration_id, {})
        where = f"project configuration {configuration.get('name')}"
        if paths.get(configuration.get("baseConfigurationReference")) != XCCONFIG:
            problems.append(f"{where}: its base configuration must be {XCCONFIG}")
        for key in sorted(configuration.get("buildSettings", {})):
            if setting_name(key) in protected:
                problems.append(f"{where}: sets {key}, which belongs into {XCCONFIG}")
    for target_id in project.get("targets", []):
        target = objects.get(target_id, {})
        for configuration_id in objects.get(target.get("buildConfigurationList"), {}).get("buildConfigurations", []):
            configuration = objects.get(configuration_id, {})
            where = f"target {target.get('name')}, configuration {configuration.get('name')}"
            if "baseConfigurationReference" in configuration:
                problems.append(f"{where}: has its own base configuration; {XCCONFIG} is the only one")
            for key in sorted(configuration.get("buildSettings", {})):
                if setting_name(key) in protected:
                    problems.append(f"{where}: sets {key}, which belongs into {XCCONFIG}")
    for target_id, attributes in project.get("attributes", {}).get("TargetAttributes", {}).items():
        if "DevelopmentTeam" in attributes:
            name = objects.get(target_id, {}).get("name", target_id)
            problems.append(f"target {name}: DevelopmentTeam in its target attributes; the team belongs into {XCCONFIG}")
    return problems


def check_scheme(root, target_ids):
    path = root / SCHEME
    if not path.is_file():
        return [f"{SCHEME} is missing; Xcode Cloud only sees shared schemes"]
    try:
        scheme = xml.etree.ElementTree.fromstring(path.read_text(encoding="utf-8"))
    except xml.etree.ElementTree.ParseError as error:
        return [f"{SCHEME}: not valid XML: {error}"]
    problems = []
    references = scheme.findall("./TestAction/TestPlans/TestPlanReference")
    found = {reference.get("reference", "").replace("container:", "") for reference in references}
    for plan in sorted(set(TEST_PLANS) - found):
        problems.append(f"{SCHEME}: does not reference {plan}")
    defaults = [r.get("reference", "") for r in references if r.get("default") == "YES"]
    if defaults != ["container:TestPlans/Default.xctestplan"]:
        problems.append(f"{SCHEME}: the default test plan must be TestPlans/Default.xctestplan, found {defaults}")
    for reference in scheme.iter("BuildableReference"):
        if reference.get("BlueprintIdentifier") not in target_ids:
            problems.append(
                f"{SCHEME}: {reference.get('BlueprintName')} points at a target that does not exist "
                f"({reference.get('BlueprintIdentifier')})")
    return problems


def check_test_plan(root, plan, expected, target_ids, paths):
    path = root / plan
    if not path.is_file():
        return [f"{plan} is missing"]
    try:
        entries = json.loads(path.read_text(encoding="utf-8")).get("testTargets", [])
    except ValueError as error:
        return [f"{plan}: not valid JSON: {error}"]
    problems = []
    names = {entry.get("target", {}).get("name") for entry in entries}
    for name in sorted(expected - names):
        problems.append(f"{plan}: {name} is missing")
    for name in sorted(names - expected, key=str):
        problems.append(f"{plan}: {name} is not expected here")
    project_folders = set(paths.values())
    for entry in entries:
        target = entry.get("target", {})
        name, identifier = target.get("name"), target.get("identifier")
        container = target.get("containerPath", "").replace("container:", "", 1).replace("\\/", "/")
        if container == "Dokumentum.xcodeproj":
            if target_ids.get(identifier) != name:
                problems.append(f"{plan}: {name} points at a target that does not exist ({identifier})")
        elif container not in project_folders:
            problems.append(f"{plan}: {name} is in {container}, which has no folder reference in the project, "
                            "so xcodebuild drops it silently")
        elif not (root / container / "Tests" / str(name)).is_dir() or identifier != name:
            problems.append(f"{plan}: {name} does not resolve to a test target in {container}")
    return problems


def check(root):
    """The problems of the repository at `root` (empty when it is fine)."""
    problems = []
    project_path = root / PROJECT
    xcconfig_path = root / XCCONFIG
    if not project_path.is_file():
        return [f"{PROJECT} is missing"]
    if not xcconfig_path.is_file():
        return [f"{XCCONFIG} is missing"]
    try:
        document = parse_plist(project_path.read_text(encoding="utf-8"))
    except ValueError as error:
        return [f"{PROJECT}: cannot be parsed: {error}"]
    objects = document.get("objects", {})
    project = objects.get(document.get("rootObject"), {})
    if project.get("isa") != "PBXProject":
        return [f"{PROJECT}: rootObject is not a PBXProject"]

    settings = parse_xcconfig(xcconfig_path.read_text(encoding="utf-8"))
    paths = file_reference_paths(objects, project.get("mainGroup"))
    problems += check_build_configurations(objects, project, paths, set(settings))

    for condition, value in settings.get("CODE_SIGN_ENTITLEMENTS", []):
        if value and not (root / value).is_file():
            problems.append(f"{XCCONFIG}: CODE_SIGN_ENTITLEMENTS{condition} names {value}, which does not exist")

    target_ids = {target_id: objects.get(target_id, {}).get("name") for target_id in project.get("targets", [])}
    problems += check_scheme(root, target_ids)
    for plan, expected in TEST_PLANS.items():
        problems += check_test_plan(root, plan, expected, target_ids, paths)

    for script in CI_SCRIPTS:
        if not (root / script).is_file():
            problems.append(f"{script} is missing")
        elif not os.access(root / script, os.X_OK):
            problems.append(f"{script} is not executable, so Xcode Cloud does not run it")
    version = root / XCODE_VERSION
    if not version.is_file() or not re.fullmatch(r"\d+\.\d+(\.\d+)?\s*", version.read_text(encoding="utf-8")):
        problems.append(f"{XCODE_VERSION} must hold one Xcode version, e.g. 27.1")
    return problems


FIXTURE_PROJECT = """// !$*UTF8*$!
{
	objects = {
		A0 = {isa = PBXProject; attributes = {TargetAttributes = {A1 = {CreatedOnToolsVersion = 27.1;};};};
			buildConfigurationList = A2; mainGroup = A3; targets = (A1 /* Dokumentum */, A7, A8, );};
		A1 /* Dokumentum */ = {isa = PBXNativeTarget; buildConfigurationList = A4; name = Dokumentum;};
		A2 = {isa = XCConfigurationList; buildConfigurations = (A5, );};
		A3 = {isa = PBXGroup; children = (A6, B0, B1, ); sourceTree = "<group>";};
		A4 = {isa = XCConfigurationList; buildConfigurations = (A9, );};
		A5 = {isa = XCBuildConfiguration; baseConfigurationReference = B2; buildSettings = {
			ONLY_ACTIVE_ARCH = YES;}; name = Debug;};
		A6 = {isa = PBXGroup; children = (B2, ); path = Config; sourceTree = "<group>";};
		A7 = {isa = PBXNativeTarget; name = DokumentumTests;};
		A8 = {isa = PBXNativeTarget; name = DokumentumUITests;};
		A9 = {isa = XCBuildConfiguration; buildSettings = {
			"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = "@executable_path/../Frameworks";}; name = Debug;};
		B0 = {isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/DokumentumKit; sourceTree = "<group>";};
		B1 = {isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/DokumentumCore; sourceTree = "<group>";};
		B2 = {isa = PBXFileReference; path = Project.xcconfig; sourceTree = "<group>";};
	};
	rootObject = A0;
}
"""
FIXTURE_XCCONFIG = """// A comment = not a setting
IPHONEOS_DEPLOYMENT_TARGET = 27.0
TARGETED_DEVICE_FAMILY = 1
DEVELOPMENT_TEAM =
#include? "Local.xcconfig"
"""
FIXTURE_SCHEME = """<Scheme><BuildAction><BuildActionEntries><BuildActionEntry>
<BuildableReference BlueprintIdentifier="A1" BlueprintName="Dokumentum"/>
</BuildActionEntry></BuildActionEntries></BuildAction><TestAction><TestPlans>
<TestPlanReference reference="container:TestPlans/Default.xctestplan" default="YES"/>
<TestPlanReference reference="container:TestPlans/UISmoke.xctestplan"/>
</TestPlans></TestAction></Scheme>
"""


def fixture_plan(*targets):
    return json.dumps({"testTargets": [
        {"target": {"containerPath": container, "identifier": identifier, "name": name}}
        for container, identifier, name in targets]})


FIXTURE_DEFAULT_PLAN = fixture_plan(
    ("container:Dokumentum.xcodeproj", "A7", "DokumentumTests"),
    ("container:Packages/DokumentumKit", "DokumentumKitTests", "DokumentumKitTests"),
    ("container:Packages/DokumentumCore", "DokumentumCoreTests", "DokumentumCoreTests"))


def write_fixture(root):
    files = {
        PROJECT: FIXTURE_PROJECT,
        XCCONFIG: FIXTURE_XCCONFIG,
        SCHEME: FIXTURE_SCHEME,
        "TestPlans/Default.xctestplan": FIXTURE_DEFAULT_PLAN,
        "TestPlans/UISmoke.xctestplan": fixture_plan(("container:Dokumentum.xcodeproj", "A8", "DokumentumUITests")),
        XCODE_VERSION: "27.1\n",
        "Packages/DokumentumKit/Tests/DokumentumKitTests/.gitkeep": "",
        "Packages/DokumentumCore/Tests/DokumentumCoreTests/.gitkeep": "",
    }
    files.update({script: "#!/bin/bash\n" for script in CI_SCRIPTS})
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    for script in CI_SCRIPTS:
        os.chmod(root / script, 0o755)


def self_test():
    def edit(name, old, new):
        def apply(root):
            path = root / name
            text = path.read_text(encoding="utf-8")
            assert old in text, f"the fixture has no {old!r}"
            path.write_text(text.replace(old, new), encoding="utf-8")
        return apply

    def in_target(line):
        return edit(PROJECT, '"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]"', f'{line} = x;\n\t\t\t"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]"')

    def in_project(line):
        return edit(PROJECT, "ONLY_ACTIVE_ARCH = YES;", f"ONLY_ACTIVE_ARCH = YES; {line} = x;")

    def remove(name):
        return lambda root: (root / name).unlink()

    def not_executable(name):
        return lambda root: os.chmod(root / name, 0o644)

    cases = [
        ("the fixture is fine", lambda root: None, None),
        ("target IPHONEOS_DEPLOYMENT_TARGET", in_target("IPHONEOS_DEPLOYMENT_TARGET"), "sets IPHONEOS_DEPLOYMENT_TARGET"),
        ("target MACOSX_DEPLOYMENT_TARGET", in_target("MACOSX_DEPLOYMENT_TARGET"), "sets MACOSX_DEPLOYMENT_TARGET"),
        ("target SWIFT_VERSION", in_target("SWIFT_VERSION"), "sets SWIFT_VERSION"),
        ("target bundle identifier", in_target("PRODUCT_BUNDLE_IDENTIFIER"), "sets PRODUCT_BUNDLE_IDENTIFIER"),
        ("target team", in_target("DEVELOPMENT_TEAM"), "sets DEVELOPMENT_TEAM"),
        ("target entitlements", in_target("CODE_SIGN_ENTITLEMENTS"), "sets CODE_SIGN_ENTITLEMENTS"),
        ("target entitlements with a condition", in_target('"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"'),
         "sets CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"),
        ("target key from the xcconfig", in_target("TARGETED_DEVICE_FAMILY"), "sets TARGETED_DEVICE_FAMILY"),
        ("project key from the xcconfig", in_project("TARGETED_DEVICE_FAMILY"), "sets TARGETED_DEVICE_FAMILY"),
        ("project deployment target", in_project("IPHONEOS_DEPLOYMENT_TARGET"), "sets IPHONEOS_DEPLOYMENT_TARGET"),
        ("target's own base configuration", edit(PROJECT, "A9 = {isa = XCBuildConfiguration;",
                                                 "A9 = {isa = XCBuildConfiguration; baseConfigurationReference = B2;"),
         "has its own base configuration"),
        ("no base configuration", edit(PROJECT, "baseConfigurationReference = B2;", ""), "base configuration must be"),
        ("another base configuration", edit(PROJECT, "path = Project.xcconfig", "path = Other.xcconfig"),
         "base configuration must be"),
        ("team in the target attributes", edit(PROJECT, "CreatedOnToolsVersion = 27.1;", "DevelopmentTeam = X;"),
         "DevelopmentTeam"),
        ("project cannot be parsed", edit(PROJECT, "rootObject = A0;", "rootObject = ;"), "cannot be parsed"),
        ("project cut off", edit(PROJECT, "\t};\n\trootObject = A0;\n}\n", ""), "cannot be parsed"),
        ("project file missing", remove(PROJECT), "is missing"),
        ("xcconfig missing", remove(XCCONFIG), "is missing"),
        ("entitlements file missing", edit(XCCONFIG, "DEVELOPMENT_TEAM =",
                                           "CODE_SIGN_ENTITLEMENTS[sdk=macosx*] = Config/None.entitlements"),
         "which does not exist"),
        ("scheme missing", remove(SCHEME), "only sees shared schemes"),
        ("scheme without a plan", edit(SCHEME, '<TestPlanReference reference="container:TestPlans/UISmoke.xctestplan"/>', ""),
         "does not reference TestPlans/UISmoke.xctestplan"),
        ("scheme without a default plan", edit(SCHEME, ' default="YES"', ""), "default test plan"),
        ("scheme with a stale target", edit(SCHEME, 'BlueprintIdentifier="A1"', 'BlueprintIdentifier="FF"'),
         "does not exist"),
        ("test plan missing", remove("TestPlans/UISmoke.xctestplan"), "is missing"),
        ("test plan not JSON", edit("TestPlans/UISmoke.xctestplan", "testTargets", '"'), "not valid JSON"),
        ("test plan without a target", edit("TestPlans/Default.xctestplan", "DokumentumKitTests", "OtherTests"),
         "DokumentumKitTests is missing"),
        ("test plan with a stale target id", edit("TestPlans/Default.xctestplan", '"A7"', '"FF"'), "does not exist"),
        ("package without a folder reference", edit(PROJECT, "children = (A6, B0, B1, )", "children = (A6, B1, )"),
         "drops it silently"),
        ("package test target gone", lambda root: shutil.rmtree(root / "Packages/DokumentumKit/Tests"), "does not resolve"),
        ("ci script missing", remove(CI_SCRIPTS[0]), "is missing"),
        ("ci script not executable", not_executable(CI_SCRIPTS[1]), "not executable"),
        (".xcode-version empty", edit(XCODE_VERSION, "27.1\n", "\n"), XCODE_VERSION),
        (".xcode-version missing", remove(XCODE_VERSION), XCODE_VERSION),
    ]
    for description, mutate, expected in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_fixture(root)
            mutate(root)
            problems = check(root)
            if expected is None:
                assert not problems, f"{description}: expected no problem, got {problems}"
            else:
                assert any(expected in problem for problem in problems), \
                    f"{description}: expected {expected!r}, got {problems}"

    assert parse_plist('{a = "b \\" c"; d = (e, f, ); /* c */ g = {h = i;}; // end\n}') == \
        {"a": 'b " c', "d": ["e", "f"], "g": {"h": "i"}}
    assert parse_xcconfig("A[sdk=x*][arch=y] = 1\n// B = 2\n#include? \"C\"\nD =\n") == \
        {"A": [("[sdk=x*][arch=y]", "1")], "D": [("", "")]}
    print(f"self-test passed ({len(cases) + 2} cases)")


def main():
    problems = check(pathlib.Path.cwd())
    for problem in problems:
        print(f"error: {problem}")
    if not problems:
        print(f"{PROJECT}, {XCCONFIG}, the scheme, the test plans and the Xcode Cloud scripts are fine")
    return 1 if problems else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main())
