#!/usr/bin/env python3
"""Guards the invariants of Dokumentum.xcodeproj that a reviewer cannot easily see in a .pbxproj
diff. Python only, so it also runs on Linux (the `lint` check):

- Config/Project.xcconfig is the project's base configuration, and no target has its own.
- No project or target build configuration sets a key that the xcconfig sets, or one of the keys
  that must only ever live there: a setting in the .pbxproj overrides the xcconfig without a trace,
  and Xcode's template and capability editor write exactly these. The team must not appear in the
  target attributes either.
- Each target resolves, per SDK, to its expected bundle identifier, platforms, entitlements file and
  Info.plist file, through the $(TARGET_NAME) indirection in the xcconfig. A new target needs a row in
  TARGETS: without its own variables it would silently get the app's identifier.
- The camera's usage text (Info.plist NSCameraUsageDescription, #5, part 2) resolves non-empty for the app on
  the iPhone SDKs and empty everywhere else: the Mac app, the extension and the test bundles never ask for the
  camera.
- Every entitlements file holds exactly the reviewed keys and values, so an unreviewed capability
  fails `lint`. A signed build adds keys of its own beyond these files (for example
  application-identifier, the team identifier and get-task-allow).
- The share extension is embedded in the iOS app only (both platform filters, in either form Xcode
  and xcodebuild accept), into PlugIns. It links exactly the package product DokumentumKit, for the
  share queue's format (plan of #4, part 4, T8), and nothing else, and its Info.plist holds exactly the
  reviewed keys and activation rule.
- No .swift file under DokumentumShare/ contains the words SwiftData or DokumentumCore anywhere, as whole
  words, in code, strings or comments: the extension must never touch the store. On purpose a plain word
  search and no parser. It has no misses, where anything short of a real Swift lexer misreads raw strings,
  regex literals or interpolation above an import. A false failure is loud, and rewording fixes it.
- Signing: the team is the plan's, CODE_SIGN_IDENTITY = - does not stand next to it, SIGNING_OVERRIDES
  are not set in the project or a target, and Config/Unsigned.xcconfig holds exactly its three
  macOS-conditioned keys. Project.xcconfig includes only Local.xcconfig, which is never committed, and
  uses only the conditions in XCCONFIG_CONDITIONS: this script resolves them on the bare SDK names, and
  Xcode also honours patterns that match only versioned names, such as [sdk=macosx*.*].
- No setting of Xcode's "App Sandbox & Hardened Runtime" category is set (CAPABILITY_SETTINGS): these
  inject entitlements past the files. The one exception is ENABLE_HARDENED_RUNTIME = NO in
  Project.xcconfig, until step 8 decides hardened runtime. The App Sandbox comes from the macOS
  entitlements file; if that alone turns out not to be enough in a signed build, the fix is a later
  change, and this rule must change with it.
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
import fnmatch
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree
import xml.parsers.expat

PROJECT = "Dokumentum.xcodeproj/project.pbxproj"
XCCONFIG = "Config/Project.xcconfig"
LOCAL_XCCONFIG = "Config/Local.xcconfig"
UNSIGNED_XCCONFIG = "Config/Unsigned.xcconfig"
SCHEME = "Dokumentum.xcodeproj/xcshareddata/xcschemes/Dokumentum.xcscheme"
XCODE_VERSION = ".xcode-version"
CI_SCRIPTS = ["ci_scripts/ci_post_clone.sh", "ci_scripts/ci_post_xcodebuild.sh"]
TEST_PLANS = {
    "TestPlans/Default.xctestplan": {
        "DokumentumTests", "DokumentumKitTests", "DokumentumTestSupportTests", "DokumentumCoreTests",
    },
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
# Never in the .pbxproj either: with no signing identity, Config/Unsigned.xcconfig does this from outside.
SIGNING_OVERRIDES = {"CODE_SIGN_IDENTITY", "CODE_SIGNING_ALLOWED", "OTHER_CODE_SIGN_FLAGS"}
# Not in Project.xcconfig either. CODE_SIGN_IDENTITY may stand there, just not as "-".
XCCONFIG_SIGNING_OVERRIDES = SIGNING_OVERRIDES - {"CODE_SIGN_IDENTITY"}
# The whole category "App Sandbox & Hardened Runtime" of CoreBuildSystem.xcspec, Xcode 27.1 (25 settings).
# An explicit list, not a prefix: ENABLE_PREVIEWS and ENABLE_TESTABILITY must keep passing, and some of
# these do not start with ENABLE_. A later Xcode may add settings: compare when .xcode-version changes.
CAPABILITY_SETTINGS = {
    "AUTOMATION_APPLE_EVENTS",
    "ENABLE_APP_SANDBOX",
    "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER",
    "ENABLE_FILE_ACCESS_MOVIES_FOLDER",
    "ENABLE_FILE_ACCESS_MUSIC_FOLDER",
    "ENABLE_FILE_ACCESS_PICTURE_FOLDER",
    "ENABLE_HARDENED_RUNTIME",
    "ENABLE_INCOMING_NETWORK_CONNECTIONS",
    "ENABLE_OUTGOING_NETWORK_CONNECTIONS",
    "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT",
    "ENABLE_RESOURCE_ACCESS_BLUETOOTH",
    "ENABLE_RESOURCE_ACCESS_CALENDARS",
    "ENABLE_RESOURCE_ACCESS_CAMERA",
    "ENABLE_RESOURCE_ACCESS_CONTACTS",
    "ENABLE_RESOURCE_ACCESS_LOCATION",
    "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY",
    "ENABLE_RESOURCE_ACCESS_PRINTING",
    "ENABLE_RESOURCE_ACCESS_USB",
    "ENABLE_USER_SELECTED_FILES",
    "RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES",
    "RUNTIME_EXCEPTION_ALLOW_JIT",
    "RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY",
    "RUNTIME_EXCEPTION_DEBUGGING_TOOL",
    "RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION",
    "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION",
}
ALLOWED_INCLUDE = '#include? "Local.xcconfig"'
# Every condition Project.xcconfig may use, as a whole. A list, not a pattern: see the docstring.
XCCONFIG_CONDITIONS = {"", "[sdk=iphone*]", "[sdk=iphoneos*]", "[sdk=iphonesimulator*]", "[sdk=macosx*]"}

# Identifiers and entitlements: docs/development/plan.md, section 2.
TEAM = "88GY2V9C2A"
CONTAINER = "iCloud.space.pklnx.Dokumentum"
APP_GROUP = "group.space.pklnx.dokumentum"
IOS_APP_ENTITLEMENTS = "Config/Dokumentum-iOS.entitlements"
MAC_APP_ENTITLEMENTS = "Config/Dokumentum-macOS.entitlements"
SHARE_ENTITLEMENTS = "Config/DokumentumShare.entitlements"
IOS_APP_INFO = "Config/Info-iOS.plist"
SHARE_INFO = "Config/DokumentumShare-Info.plist"
USER_SELECTED_READ_ONLY = "com.apple.security.files.user-selected.read-only"
ENTITLEMENTS = {
    IOS_APP_ENTITLEMENTS: {
        "aps-environment": "development",
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.security.application-groups": [APP_GROUP],
    },
    MAC_APP_ENTITLEMENTS: {
        "com.apple.developer.aps-environment": "development",
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.security.app-sandbox": True,
        # Files the user picks, read only: the import never writes back (#4). A drop received as a file needs no key.
        USER_SELECTED_READ_ONLY: True,
    },
    SHARE_ENTITLEMENTS: {"com.apple.security.application-groups": [APP_GROUP]},
}
ALL_SDKS = "iphoneos iphonesimulator macosx"
IOS_SDKS = "iphoneos iphonesimulator"
APP_TARGET = "Dokumentum"
SHARE_TARGET = "DokumentumShare"
SHARE_FOLDER = "DokumentumShare"
# The store and the model stay out of the extension (CLAUDE.md, plan.md section 3.4).
SHARE_FORBIDDEN_WORDS = {"DokumentumCore", "SwiftData"}
# The only package product the extension links: the share queue's format, Foundation only (plan of #4, part 4).
SHARE_PACKAGE_PRODUCTS = ["DokumentumKit"]
# The extension's whole Info.plist file: PDFs and images only. A change of the rule is a change here, on purpose.
SHARE_INFO_CONTENT = {"NSExtension": {
    "NSExtensionAttributes": {
        "NSExtensionActivationRule": (
            "SUBQUERY(extensionItems, $item, SUBQUERY($item.attachments, $attachment, "
            'ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "com.adobe.pdf" OR '
            'ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.image").@count >= 1).@count >= 1'),
    },
    "NSExtensionPointIdentifier": "com.apple.share-services",
    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
}}


def on_ios_and_mac(ios, mac):
    return {"iphoneos": ios, "iphonesimulator": ios, "macosx": mac}


# The camera's usage text (#5, part 2, P1): any non-empty text where NON_EMPTY stands, nothing elsewhere. The
# text itself is the maintainer's; its German is in Dokumentum/InfoPlist.xcstrings.
CAMERA_USAGE = "INFOPLIST_KEY_NSCameraUsageDescription"
NON_EMPTY = object()


# What each target must resolve to, per SDK it supports.
TARGETS = {
    APP_TARGET: {
        "PRODUCT_BUNDLE_IDENTIFIER": "space.pklnx.Dokumentum",
        "SUPPORTED_PLATFORMS": ALL_SDKS,
        "CODE_SIGN_ENTITLEMENTS": on_ios_and_mac(IOS_APP_ENTITLEMENTS, MAC_APP_ENTITLEMENTS),
        "INFOPLIST_FILE": on_ios_and_mac(IOS_APP_INFO, ""),
        CAMERA_USAGE: on_ios_and_mac(NON_EMPTY, ""),
    },
    SHARE_TARGET: {
        "PRODUCT_BUNDLE_IDENTIFIER": "space.pklnx.Dokumentum.Share",
        "SUPPORTED_PLATFORMS": IOS_SDKS,
        "CODE_SIGN_ENTITLEMENTS": on_ios_and_mac(SHARE_ENTITLEMENTS, None),
        "INFOPLIST_FILE": on_ios_and_mac(SHARE_INFO, None),
        CAMERA_USAGE: on_ios_and_mac("", None),
    },
    "DokumentumTests": {
        "PRODUCT_BUNDLE_IDENTIFIER": "space.pklnx.Dokumentum.Tests",
        "SUPPORTED_PLATFORMS": ALL_SDKS,
        "CODE_SIGN_ENTITLEMENTS": on_ios_and_mac("", ""),
        "INFOPLIST_FILE": on_ios_and_mac("", ""),
        CAMERA_USAGE: on_ios_and_mac("", ""),
    },
    "DokumentumUITests": {
        "PRODUCT_BUNDLE_IDENTIFIER": "space.pklnx.Dokumentum.UITests",
        "SUPPORTED_PLATFORMS": ALL_SDKS,
        "CODE_SIGN_ENTITLEMENTS": on_ios_and_mac("", ""),
        "INFOPLIST_FILE": on_ios_and_mac("", ""),
        CAMERA_USAGE: on_ios_and_mac("", ""),
    },
}
# Config/Unsigned.xcconfig: macOS only, so the simulator keeps the real team and keys.
UNSIGNED_SETTINGS = {
    "CODE_SIGN_IDENTITY": [("[sdk=macosx*]", "-")],
    "DEVELOPMENT_TEAM": [("[sdk=macosx*]", "")],
    "CODE_SIGN_ENTITLEMENTS": [("[sdk=macosx*]", "")],
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
        # Xcode also accepts a space before a condition: `KEY [sdk=*] = value`. A space inside the bracket
        # stays, because Xcode reads it as part of the pattern, and such a condition fails check_xcconfig.
        match = re.match(r"\s*([A-Za-z_]\w*)((?:\s*\[[^\]]*\])*)\s*=\s*(.*?)\s*$", line)
        if match:
            value = re.sub(r"\s*//.*$", "", match.group(3))
            settings.setdefault(match.group(1), []).append(("".join(re.findall(r"\[[^\]]*\]", match.group(2))), value))
    return settings


def xcconfig_includes(text):
    """The #include lines of an xcconfig, stripped. Xcode also accepts `# include`."""
    return [line.strip() for line in text.splitlines() if re.match(r"\s*#\s*include", line)]


def resolve(settings, name, target, sdk, depth=0):
    """What a setting of the xcconfig resolves to for a target and an SDK, inner $(...) first. As in the
    build system the last line that applies wins. A condition that is not on the SDK counts as applying,
    so a line set for one configuration only shows up as a wrong value instead of being overlooked."""
    if name == "TARGET_NAME":
        return target
    value = ""
    for condition, candidate in settings.get(name, []):
        sdks = re.findall(r"\[sdk=([^\]]*)\]", condition)
        if all(fnmatch.fnmatch(sdk, pattern) for pattern in sdks):
            value = candidate
    return expand(settings, value, target, sdk, depth + 1)


def expand(settings, value, target, sdk, depth=0):
    """A value with its $(NAME) and $(NAME:default=x) references replaced."""
    if depth > 16:
        raise ValueError(f"{value} refers to itself")

    def replacement(match):
        name, _, default = match.group(1).partition(":default=")
        return resolve(settings, name, target, sdk, depth) or default

    while True:
        expanded = re.sub(r"\$\(([^$()]*)\)", replacement, value)
        if expanded == value:
            return value
        value = expanded


def setting_name(key):
    """A build setting's name without its condition: `KEY[sdk=macosx*]` becomes `KEY`."""
    return key.split("[", 1)[0].strip()


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


def second_base_configuration_keys(configuration):
    """baseConfigurationReferenceAnchor and ...RelativePath: the form of a base configuration that lies
    inside a synchronized folder."""
    return sorted(key for key in configuration if key.startswith("baseConfigurationReference")
                  and key != "baseConfigurationReference")


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
        for key in second_base_configuration_keys(configuration):
            problems.append(f"{where}: {key} names another base configuration; {XCCONFIG} is the only one")
        for key in sorted(configuration.get("buildSettings", {})):
            problems += check_project_setting(where, key, protected)
    for target_id in project.get("targets", []):
        target = objects.get(target_id, {})
        for configuration_id in objects.get(target.get("buildConfigurationList"), {}).get("buildConfigurations", []):
            configuration = objects.get(configuration_id, {})
            where = f"target {target.get('name')}, configuration {configuration.get('name')}"
            if "baseConfigurationReference" in configuration:
                problems.append(f"{where}: has its own base configuration; {XCCONFIG} is the only one")
            for key in second_base_configuration_keys(configuration):
                problems.append(f"{where}: {key} names its own base configuration; {XCCONFIG} is the only one")
            for key in sorted(configuration.get("buildSettings", {})):
                problems += check_project_setting(where, key, protected)
    for target_id, attributes in project.get("attributes", {}).get("TargetAttributes", {}).items():
        name = objects.get(target_id, {}).get("name", target_id)
        if "DevelopmentTeam" in attributes:
            problems.append(f"target {name}: DevelopmentTeam in its target attributes; the team belongs into {XCCONFIG}")
        if "ProvisioningStyle" in attributes:
            problems.append(f"target {name}: ProvisioningStyle in its target attributes; CODE_SIGN_STYLE belongs into {XCCONFIG}")
    return problems


def check_project_setting(where, key, protected):
    """One build setting of a project or target configuration in the .pbxproj."""
    name = setting_name(key)
    if name in CAPABILITY_SETTINGS:
        return [f"{where}: sets {key}, which injects entitlements past the entitlements files"]
    if name in SIGNING_OVERRIDES:
        return [f"{where}: sets {key}; no project or target overrides signing ({UNSIGNED_XCCONFIG} does, from outside)"]
    if name in protected:
        return [f"{where}: sets {key}, which belongs into {XCCONFIG}"]
    return []


def check_xcconfig(text, settings):
    """Signing, capability settings and includes in Project.xcconfig."""
    problems = []
    for line in xcconfig_includes(text):
        if line != ALLOWED_INCLUDE:
            problems.append(f"{XCCONFIG}: {line}; the only include allowed is {ALLOWED_INCLUDE}")
    for key in sorted(CAPABILITY_SETTINGS & set(settings)):
        for condition, value in settings[key]:
            if (key, condition, value) != ("ENABLE_HARDENED_RUNTIME", "", "NO"):
                problems.append(f"{XCCONFIG}: sets {key}{condition} = {value}, which injects entitlements past "
                                "the entitlements files")
    for key in sorted(XCCONFIG_SIGNING_OVERRIDES & set(settings)):
        problems.append(f"{XCCONFIG}: sets {key}; a build that signs differently says so on its command line")
    for key, lines in sorted(settings.items()):
        for condition, _ in lines:
            if condition not in XCCONFIG_CONDITIONS:
                problems.append(f"{XCCONFIG}: {key}{condition} uses a condition this script cannot resolve; "
                                "use [sdk=macosx*] or [sdk=iphone*]")
    if settings.get("DEVELOPMENT_TEAM") != [("", TEAM)]:
        problems.append(f"{XCCONFIG}: DEVELOPMENT_TEAM must be one line with the team {TEAM}")
    if settings.get("CODE_SIGN_STYLE") != [("", "Automatic")]:
        problems.append(f"{XCCONFIG}: CODE_SIGN_STYLE must be one line with Automatic")
    if any(value for _, value in settings.get("DEVELOPMENT_TEAM", [])):
        for condition, value in settings.get("CODE_SIGN_IDENTITY", []):
            if expand(settings, value, "", "macosx").strip("\"'") == "-":
                problems.append(f"{XCCONFIG}: CODE_SIGN_IDENTITY{condition} = - next to a team gives an ad hoc "
                                "macOS build with exit 0")
    for _, value in settings.get("SUPPORTED_PLATFORMS", []):
        if ":default=" in value:
            problems.append(f"{XCCONFIG}: SUPPORTED_PLATFORMS uses :default=, which makes a simulator build exit 70; "
                            "use one explicit variable per target")
    return problems


def check_targets(root, objects, project, settings):
    """Each target against its row in TARGETS, on every SDK it supports."""
    problems = []
    names = {objects.get(target_id, {}).get("name") for target_id in project.get("targets", [])}
    for name in sorted(set(TARGETS) - names):
        problems.append(f"{PROJECT}: target {name} is missing")
    for name in sorted(names - set(TARGETS), key=str):
        problems.append(f"{PROJECT}: target {name} has no row in TARGETS in scripts/check-project.py")
    for name in sorted(set(TARGETS) & names):
        expected = TARGETS[name]
        sdks = expected["SUPPORTED_PLATFORMS"].split()
        for key in ("PRODUCT_BUNDLE_IDENTIFIER", "SUPPORTED_PLATFORMS"):
            for sdk in sdks:
                actual = resolve(settings, key, name, sdk)
                if actual != expected[key]:
                    problems.append(f"target {name}: {key} resolves to '{actual}' on {sdk}, expected '{expected[key]}'")
        for key in ("CODE_SIGN_ENTITLEMENTS", "INFOPLIST_FILE"):
            for sdk in sdks:
                actual = resolve(settings, key, name, sdk)
                if actual != expected[key][sdk]:
                    problems.append(f"target {name}: {key} resolves to '{actual}' on {sdk}, "
                                    f"expected '{expected[key][sdk]}'")
                if actual and not (root / actual).is_file():
                    problems.append(f"target {name}: {key} on {sdk} names {actual}, which does not exist")
        for sdk in sdks:
            actual = resolve(settings, CAMERA_USAGE, name, sdk).strip()
            if expected[CAMERA_USAGE][sdk] is NON_EMPTY:
                if not actual:
                    problems.append(f"target {name}: {CAMERA_USAGE} resolves to '' on {sdk}, expected the camera text")
            elif actual:
                problems.append(f"target {name}: {CAMERA_USAGE} resolves to '{actual}' on {sdk}, expected ''")
    return problems


def read_plist(root, name):
    """A property list as (dict, problem); the dict is None when it cannot be read."""
    path = root / name
    if not path.is_file():
        return None, f"{name} is missing"
    try:
        return plistlib.loads(path.read_bytes()), None
    except (plistlib.InvalidFileException, xml.parsers.expat.ExpatError, ValueError) as error:
        return None, f"{name}: not a valid property list: {error}"


def check_entitlements(root):
    """Exactly the reviewed keys and values; an unreviewed capability fails here."""
    problems = []
    for name, expected in ENTITLEMENTS.items():
        actual, problem = read_plist(root, name)
        if problem:
            problems.append(problem)
            continue
        for key in sorted(set(actual) - set(expected)):
            problems.append(f"{name}: {key} is not a reviewed entitlement")
        for key in sorted(set(expected) - set(actual)):
            problems.append(f"{name}: {key} is missing")
        for key in sorted(set(actual) & set(expected)):
            if actual[key] != expected[key]:
                problems.append(f"{name}: {key} is {actual[key]!r}, expected {expected[key]!r}")
    for path in sorted((root / "Config").glob("*.entitlements")):
        name = f"Config/{path.name}"
        if name not in ENTITLEMENTS:
            problems.append(f"{name} is not a reviewed entitlements file")
    return problems


def check_info_plists(root):
    problems = []
    actual, problem = read_plist(root, IOS_APP_INFO)
    if problem:
        problems.append(problem)
    elif actual != {"UIBackgroundModes": ["remote-notification"]}:
        problems.append(f"{IOS_APP_INFO}: holds only UIBackgroundModes = [remote-notification], found {actual}")
    actual, problem = read_plist(root, SHARE_INFO)
    if problem:
        problems.append(problem)
    elif actual != SHARE_INFO_CONTENT:
        problems.append(f"{SHARE_INFO}: must hold exactly the reviewed keys and activation rule "
                        f"(SHARE_INFO_CONTENT in scripts/check-project.py), found {actual}")
    return problems


def check_local_xcconfig(root):
    """Config/Local.xcconfig overrides everything, so it stays personal. A file in the tree is fine; a
    committed one is not. A directory without git (the self-test's fixtures) has nothing committed."""
    try:
        result = subprocess.run(["git", "-C", str(root), "ls-files", "--", LOCAL_XCCONFIG], capture_output=True, text=True)
    except OSError as error:
        return [f"{LOCAL_XCCONFIG}: cannot ask git whether it is committed: {error}"]
    if result.returncode != 0:
        if (root / ".git").exists():
            return [f"{LOCAL_XCCONFIG}: cannot ask git whether it is committed: {result.stderr.strip()}"]
        return []
    if result.stdout.strip():
        return [f"{LOCAL_XCCONFIG} is committed; it overrides everything and stays personal"]
    return []


def check_share_sources(root):
    """The words of SHARE_FORBIDDEN_WORDS, anywhere in the extension's Swift files (see the docstring)."""
    problems = []
    pattern = re.compile(r"\b(" + "|".join(sorted(SHARE_FORBIDDEN_WORDS)) + r")\b")
    for path in sorted((root / SHARE_FOLDER).rglob("*.swift")):
        lines = path.read_bytes().decode("utf-8", errors="replace").splitlines()
        for number, line in enumerate(lines, start=1):
            for word in pattern.findall(line):
                problems.append(f"{path.relative_to(root)}:{number}: contains the word {word}; the extension never "
                                "touches the store (plan.md, section 3.4). Reword it if it is only a comment")
    return problems


def check_unsigned_xcconfig(root):
    path = root / UNSIGNED_XCCONFIG
    if not path.is_file():
        return [f"{UNSIGNED_XCCONFIG} is missing"]
    text = path.read_text(encoding="utf-8")
    problems = []
    if parse_xcconfig(text) != UNSIGNED_SETTINGS:
        problems.append(f"{UNSIGNED_XCCONFIG}: must hold exactly CODE_SIGN_IDENTITY[sdk=macosx*] = -, "
                        "DEVELOPMENT_TEAM[sdk=macosx*] = and CODE_SIGN_ENTITLEMENTS[sdk=macosx*] =")
    if xcconfig_includes(text):
        problems.append(f"{UNSIGNED_XCCONFIG}: includes another file")
    return problems


def platform_filters(entry):
    """Both forms xcodebuild accepts: `platformFilter = ios;` and `platformFilters = (ios, );`."""
    filters = set(entry.get("platformFilters", []))
    if "platformFilter" in entry:
        filters.add(entry["platformFilter"])
    return filters


def embeds_into_plugins(phase):
    """Both forms of the destination: `dstSubfolderSpec = 13;` and Xcode's newer `dstSubfolder = PlugIns;`."""
    destination = phase.get("dstSubfolderSpec") == "13" or phase.get("dstSubfolder") == "PlugIns"
    return destination and not phase.get("dstPath")


def product_names(objects, identifiers):
    """The productName of each XCSwiftPackageProductDependency, sorted (a missing one as its identifier)."""
    return sorted(str(objects.get(identifier, {}).get("productName", identifier)) for identifier in identifiers)


def check_share_extension(objects, project):
    """Embedded in the iOS app only, through both platform filters, into PlugIns; links exactly DokumentumKit."""
    by_name = {objects.get(target_id, {}).get("name"): target_id for target_id in project.get("targets", [])}
    if APP_TARGET not in by_name or SHARE_TARGET not in by_name:
        return []  # check_targets reports it.
    app, share_id = objects[by_name[APP_TARGET]], by_name[SHARE_TARGET]
    share = objects[share_id]
    problems = []

    dependencies = [objects.get(identifier, {}) for identifier in app.get("dependencies", [])]
    dependencies = [entry for entry in dependencies if entry.get("target") == share_id]
    if len(dependencies) != 1:
        problems.append(f"target {APP_TARGET}: needs one dependency on {SHARE_TARGET}, found {len(dependencies)}")
    for entry in dependencies:
        if platform_filters(entry) != {"ios"}:
            problems.append(f"target {APP_TARGET}: its dependency on {SHARE_TARGET} must be filtered to ios, "
                            f"found {sorted(platform_filters(entry))}")

    embedded = []
    for phase_id in app.get("buildPhases", []):
        phase = objects.get(phase_id, {})
        if phase.get("isa") == "PBXCopyFilesBuildPhase":
            entries = [objects.get(identifier, {}) for identifier in phase.get("files", [])]
            found = [entry for entry in entries if entry.get("fileRef") == share.get("productReference")]
            embedded += found
            if found and not embeds_into_plugins(phase):
                problems.append(f"target {APP_TARGET}: {phase.get('name')} must copy {SHARE_TARGET} into PlugIns")
    if len(embedded) != 1:
        problems.append(f"target {APP_TARGET}: needs to embed {SHARE_TARGET} once, found {len(embedded)}")
    for entry in embedded:
        if platform_filters(entry) != {"ios"}:
            problems.append(f"target {APP_TARGET}: the embedded {SHARE_TARGET} must be filtered to ios, "
                            f"found {sorted(platform_filters(entry))}")

    linked = product_names(objects, share.get("packageProductDependencies", []))
    if linked != SHARE_PACKAGE_PRODUCTS:
        problems.append(f"target {SHARE_TARGET}: must link exactly the package products {SHARE_PACKAGE_PRODUCTS}, "
                        f"found {linked}; the extension never links the store's package (plan.md, section 3.4)")
    in_phases = []
    for phase_id in share.get("buildPhases", []):
        for identifier in objects.get(phase_id, {}).get("files", []):
            entry = objects.get(identifier, {})
            if "productRef" in entry:
                in_phases.append(entry["productRef"])
    in_phases = product_names(objects, in_phases)
    if in_phases != SHARE_PACKAGE_PRODUCTS:
        problems.append(f"target {SHARE_TARGET}: its build phases must link exactly the package products "
                        f"{SHARE_PACKAGE_PRODUCTS}, found {in_phases} (plan.md, section 3.4)")
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

    xcconfig_text = xcconfig_path.read_text(encoding="utf-8")
    settings = parse_xcconfig(xcconfig_text)
    paths = file_reference_paths(objects, project.get("mainGroup"))
    problems += check_build_configurations(objects, project, paths, set(settings))
    try:
        problems += check_xcconfig(xcconfig_text, settings)
        problems += check_targets(root, objects, project, settings)
    except ValueError as error:
        problems.append(f"{XCCONFIG}: {error}")
    problems += check_share_extension(objects, project)
    problems += check_share_sources(root)
    problems += check_local_xcconfig(root)
    problems += check_entitlements(root)
    problems += check_info_plists(root)
    problems += check_unsigned_xcconfig(root)

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
			buildConfigurationList = A2; mainGroup = A3; targets = (A1 /* Dokumentum */, A7, A8, C0, );};
		A1 /* Dokumentum */ = {isa = PBXNativeTarget; buildConfigurationList = A4; name = Dokumentum;
			buildPhases = (C2, ); dependencies = (C3, );};
		A2 = {isa = XCConfigurationList; buildConfigurations = (A5, );};
		A3 = {isa = PBXGroup; children = (A6, B0, B1, ); sourceTree = "<group>";};
		A4 = {isa = XCConfigurationList; buildConfigurations = (A9, );};
		A5 = {isa = XCBuildConfiguration; baseConfigurationReference = B2; buildSettings = {
			ENABLE_TESTABILITY = YES; ONLY_ACTIVE_ARCH = YES;}; name = Debug;};
		A6 = {isa = PBXGroup; children = (B2, ); path = Config; sourceTree = "<group>";};
		A7 = {isa = PBXNativeTarget; name = DokumentumTests;};
		A8 = {isa = PBXNativeTarget; name = DokumentumUITests;};
		A9 = {isa = XCBuildConfiguration; buildSettings = {
			"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = "@executable_path/../Frameworks";}; name = Debug;};
		B0 = {isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/DokumentumKit; sourceTree = "<group>";};
		B1 = {isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/DokumentumCore; sourceTree = "<group>";};
		B2 = {isa = PBXFileReference; path = Project.xcconfig; sourceTree = "<group>";};
		C0 = {isa = PBXNativeTarget; name = DokumentumShare; buildPhases = (C5, ); packageProductDependencies = (D1, );
			productReference = C1;};
		C1 = {isa = PBXFileReference; path = DokumentumShare.appex; sourceTree = BUILT_PRODUCTS_DIR;};
		C2 = {isa = PBXCopyFilesBuildPhase; dstPath = ""; dstSubfolderSpec = 13; files = (C4, ); name = "Embed Foundation Extensions";};
		C3 = {isa = PBXTargetDependency; platformFilters = (ios, ); target = C0;};
		C4 = {isa = PBXBuildFile; fileRef = C1; platformFilters = (ios, );};
		C5 = {isa = PBXFrameworksBuildPhase; files = (C6, );};
		C6 = {isa = PBXBuildFile; productRef = D2;};
		D0 = {isa = XCSwiftPackageProductDependency; productName = DokumentumCore;};
		D1 = {isa = XCSwiftPackageProductDependency; productName = DokumentumKit;};
		D2 = {isa = XCSwiftPackageProductDependency; productName = DokumentumKit;};
	};
	rootObject = A0;
}
"""
FIXTURE_XCCONFIG = """// A comment = not a setting
IPHONEOS_DEPLOYMENT_TARGET = 27.0
TARGETED_DEVICE_FAMILY = 1
ENABLE_PREVIEWS = YES
ENABLE_HARDENED_RUNTIME = NO
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = 88GY2V9C2A
DOKUMENTUM_BUNDLE_ID_SUFFIX_Dokumentum =
DOKUMENTUM_BUNDLE_ID_SUFFIX_DokumentumShare = .Share
DOKUMENTUM_BUNDLE_ID_SUFFIX_DokumentumTests = .Tests
DOKUMENTUM_BUNDLE_ID_SUFFIX_DokumentumUITests = .UITests
PRODUCT_BUNDLE_IDENTIFIER = space.pklnx.Dokumentum$(DOKUMENTUM_BUNDLE_ID_SUFFIX_$(TARGET_NAME))
DOKUMENTUM_PLATFORMS_Dokumentum = iphoneos iphonesimulator macosx
DOKUMENTUM_PLATFORMS_DokumentumShare = iphoneos iphonesimulator
DOKUMENTUM_PLATFORMS_DokumentumTests = iphoneos iphonesimulator macosx
DOKUMENTUM_PLATFORMS_DokumentumUITests = iphoneos iphonesimulator macosx
SUPPORTED_PLATFORMS = $(DOKUMENTUM_PLATFORMS_$(TARGET_NAME))
DOKUMENTUM_ENTITLEMENTS_Dokumentum = Config/Dokumentum-iOS.entitlements
DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=macosx*] = Config/Dokumentum-macOS.entitlements
DOKUMENTUM_ENTITLEMENTS_DokumentumShare = Config/DokumentumShare.entitlements
CODE_SIGN_ENTITLEMENTS = $(DOKUMENTUM_ENTITLEMENTS_$(TARGET_NAME))
DOKUMENTUM_INFOPLIST_Dokumentum = Config/Info-iOS.plist
DOKUMENTUM_INFOPLIST_Dokumentum[sdk=macosx*] =
DOKUMENTUM_INFOPLIST_DokumentumShare = Config/DokumentumShare-Info.plist
INFOPLIST_FILE = $(DOKUMENTUM_INFOPLIST_$(TARGET_NAME))
DOKUMENTUM_CAMERA_USAGE_Dokumentum[sdk=iphone*] = Dokumentum uses the camera to scan documents.
INFOPLIST_KEY_NSCameraUsageDescription = $(DOKUMENTUM_CAMERA_USAGE_$(TARGET_NAME))
#include? "Local.xcconfig"
"""
FIXTURE_UNSIGNED = """// A comment
CODE_SIGN_IDENTITY[sdk=macosx*] = -
DEVELOPMENT_TEAM[sdk=macosx*] =
CODE_SIGN_ENTITLEMENTS[sdk=macosx*] =
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
    ("container:Packages/DokumentumKit", "DokumentumTestSupportTests", "DokumentumTestSupportTests"),
    ("container:Packages/DokumentumCore", "DokumentumCoreTests", "DokumentumCoreTests"))


def write_fixture(root):
    files = {
        PROJECT: FIXTURE_PROJECT,
        XCCONFIG: FIXTURE_XCCONFIG,
        UNSIGNED_XCCONFIG: FIXTURE_UNSIGNED,
        SCHEME: FIXTURE_SCHEME,
        f"{SHARE_FOLDER}/ShareViewController.swift": "import UIKit\n",
        "TestPlans/Default.xctestplan": FIXTURE_DEFAULT_PLAN,
        "TestPlans/UISmoke.xctestplan": fixture_plan(("container:Dokumentum.xcodeproj", "A8", "DokumentumUITests")),
        XCODE_VERSION: "27.1\n",
        "Packages/DokumentumKit/Tests/DokumentumKitTests/.gitkeep": "",
        "Packages/DokumentumKit/Tests/DokumentumTestSupportTests/.gitkeep": "",
        "Packages/DokumentumCore/Tests/DokumentumCoreTests/.gitkeep": "",
    }
    files.update({script: "#!/bin/bash\n" for script in CI_SCRIPTS})
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    for script in CI_SCRIPTS:
        os.chmod(root / script, 0o755)
    for name, content in ENTITLEMENTS.items():
        (root / name).write_bytes(plistlib.dumps(content))
    (root / IOS_APP_INFO).write_bytes(plistlib.dumps({"UIBackgroundModes": ["remote-notification"]}))
    (root / SHARE_INFO).write_bytes(plistlib.dumps(SHARE_INFO_CONTENT))


def self_test_post_clone():
    """The real ci_post_clone.sh under Xcode Cloud's variables, with stand-ins for xcodebuild and sw_vers."""
    script = pathlib.Path(__file__).resolve().parent.parent / CI_SCRIPTS[0]
    copied, error, left = "copied Config/Unsigned.xcconfig", "error: ", "left Config/ alone"
    cases = [
        ("the workflow PR", {"CI_XCODE_CLOUD": "TRUE", "CI_WORKFLOW": "PR"}, False, 0, copied, True),
        ("the workflow Main", {"CI_XCODE_CLOUD": "TRUE", "CI_WORKFLOW": "Main"}, False, 0, copied, True),
        ("the workflow main", {"CI_XCODE_CLOUD": "TRUE", "CI_WORKFLOW": "main"}, False, 0, copied, True),
        ("the workflow Release", {"CI_XCODE_CLOUD": "TRUE", "CI_WORKFLOW": "Release"}, False, 0, left, False),
        ("a similar name", {"CI_XCODE_CLOUD": "TRUE", "CI_WORKFLOW": "PR-Release"}, False, 0, left, False),
        ("no workflow under Xcode Cloud", {"CI_XCODE_CLOUD": "TRUE"}, False, 1, "CI_WORKFLOW is not set", False),
        ("outside Xcode Cloud", {}, False, 0, left, False),
        ("a Local.xcconfig already there", {"CI_XCODE_CLOUD": "TRUE", "CI_WORKFLOW": "PR"}, True, 1, error, True),
    ]
    for description, variables, local_exists, code, output, local_afterwards in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tools = root / "tools"
            tools.mkdir()
            (tools / "xcodebuild").write_text(
                '#!/bin/sh\ncase "$1" in\n-version) echo "Xcode 27.1";;\n'
                '*) echo "-sdk iphoneos27.1"; echo "-sdk iphonesimulator27.1"; echo "-sdk macosx27.0";;\nesac\n')
            (tools / "sw_vers").write_text("#!/bin/sh\nexit 0\n")
            os.chmod(tools / "xcodebuild", 0o755)
            os.chmod(tools / "sw_vers", 0o755)
            (root / "Config").mkdir()
            (root / XCODE_VERSION).write_text("27.1\n")
            (root / XCCONFIG).write_text("IPHONEOS_DEPLOYMENT_TARGET = 27.0\nMACOSX_DEPLOYMENT_TARGET = 27.0\n")
            (root / UNSIGNED_XCCONFIG).write_text(FIXTURE_UNSIGNED)
            if local_exists:
                (root / LOCAL_XCCONFIG).write_text("// personal\n")
            environment = {key: value for key, value in os.environ.items() if not key.startswith("CI_")}
            environment.update(variables, CI_PRIMARY_REPOSITORY_PATH=str(root),
                               PATH=f"{tools}{os.pathsep}{os.environ['PATH']}")
            result = subprocess.run(["bash", str(script)], env=environment, capture_output=True, text=True)
            combined = result.stdout + result.stderr
            assert result.returncode == code, f"{description}: exit {result.returncode}, expected {code}: {combined}"
            assert output in combined, f"{description}: expected {output!r} in {combined}"
            local = root / LOCAL_XCCONFIG
            assert local.exists() == local_afterwards, f"{description}: Local.xcconfig exists: {local.exists()}"
            if local_afterwards and not local_exists:
                assert local.read_text() == FIXTURE_UNSIGNED, f"{description}: not a copy of the unsigned file"
    return len(cases)


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

    def in_xcconfig(line):
        return edit(XCCONFIG, "ENABLE_PREVIEWS = YES", f"ENABLE_PREVIEWS = YES\n{line}")

    def in_xcconfig_last(line):
        return edit(XCCONFIG, '#include? "Local.xcconfig"', f'{line}\n#include? "Local.xcconfig"')

    def in_subfolder(root):
        (root / SHARE_FOLDER / "Sub").mkdir()
        (root / SHARE_FOLDER / "Sub" / "Store.swift").write_text("import SwiftData\n", encoding="utf-8")

    def committed_local(root):
        (root / LOCAL_XCCONFIG).write_text("// committed\n")
        for arguments in (["init", "-q"], ["add", "-f", LOCAL_XCCONFIG]):
            subprocess.run(["git", "-C", str(root), *arguments], check=True, capture_output=True)

    def set_entitlement(name, key, value):
        def apply(root):
            content = plistlib.loads((root / name).read_bytes())
            content[key] = value
            (root / name).write_bytes(plistlib.dumps(content))
        return apply

    def replace_entitlement(name, key, new_key):
        def apply(root):
            content = plistlib.loads((root / name).read_bytes())
            value = content.pop(key)
            if new_key:
                content[new_key] = value
            (root / name).write_bytes(plistlib.dumps(content))
        return apply

    def write(name, text):
        return lambda root: (root / name).write_text(text, encoding="utf-8")

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
        ("the singular filter form is fine too", edit(PROJECT, "platformFilters = (ios, );", "platformFilter = ios;"), None),
        ("one filter in each form is fine", edit(PROJECT, "fileRef = C1; platformFilters = (ios, );",
                                                 "fileRef = C1; platformFilter = ios;"), None),
        ("entitlements file missing", edit(XCCONFIG, "DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=macosx*] = Config/Dokumentum-macOS.entitlements",
                                           "DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=macosx*] = Config/None.entitlements"),
         "which does not exist"),
        # Target mapping.
        ("literal entitlements give every target the app's", edit(XCCONFIG, "$(DOKUMENTUM_ENTITLEMENTS_$(TARGET_NAME))",
                                                                  "Config/Dokumentum-iOS.entitlements"),
         "target DokumentumShare: CODE_SIGN_ENTITLEMENTS resolves to 'Config/Dokumentum-iOS.entitlements'"),
        ("literal entitlements reach the test targets", edit(XCCONFIG, "$(DOKUMENTUM_ENTITLEMENTS_$(TARGET_NAME))",
                                                             "Config/Dokumentum-iOS.entitlements"),
         "target DokumentumTests: CODE_SIGN_ENTITLEMENTS resolves to"),
        ("the extension gets the app's entitlements", edit(XCCONFIG, "DokumentumShare = Config/DokumentumShare.entitlements",
                                                           "DokumentumShare = Config/Dokumentum-iOS.entitlements"),
         "target DokumentumShare: CODE_SIGN_ENTITLEMENTS"),
        ("the extension has no entitlements", edit(XCCONFIG, "DOKUMENTUM_ENTITLEMENTS_DokumentumShare = Config/DokumentumShare.entitlements\n", ""),
         "target DokumentumShare: CODE_SIGN_ENTITLEMENTS resolves to ''"),
        ("the Mac app gets the iOS entitlements", edit(XCCONFIG, "[sdk=macosx*] = Config/Dokumentum-macOS.entitlements",
                                                       "[sdk=macosx*] = Config/Dokumentum-iOS.entitlements"),
         "resolves to 'Config/Dokumentum-iOS.entitlements' on macosx"),
        ("a test target gets entitlements", in_xcconfig("DOKUMENTUM_ENTITLEMENTS_DokumentumTests = Config/DokumentumShare.entitlements"),
         "target DokumentumTests: CODE_SIGN_ENTITLEMENTS"),
        ("entitlements for a configuration only", edit(
            XCCONFIG, "CODE_SIGN_ENTITLEMENTS = $(DOKUMENTUM",
            "DOKUMENTUM_ENTITLEMENTS_Dokumentum[config=Release] = Config/DokumentumShare.entitlements\nCODE_SIGN_ENTITLEMENTS = $(DOKUMENTUM"),
         "target Dokumentum: CODE_SIGN_ENTITLEMENTS"),
        ("the extension has no bundle ID suffix", edit(XCCONFIG, "DOKUMENTUM_BUNDLE_ID_SUFFIX_DokumentumShare = .Share\n", ""),
         "target DokumentumShare: PRODUCT_BUNDLE_IDENTIFIER resolves to 'space.pklnx.Dokumentum'"),
        ("another bundle identifier", edit(XCCONFIG, "space.pklnx.Dokumentum$(", "space.pklnx.Other$("),
         "PRODUCT_BUNDLE_IDENTIFIER resolves to"),
        ("the extension on macOS", edit(XCCONFIG, "DOKUMENTUM_PLATFORMS_DokumentumShare = iphoneos iphonesimulator",
                                        "DOKUMENTUM_PLATFORMS_DokumentumShare = iphoneos iphonesimulator macosx"),
         "target DokumentumShare: SUPPORTED_PLATFORMS"),
        ("a target without a platform variable", edit(XCCONFIG, "DOKUMENTUM_PLATFORMS_DokumentumTests = iphoneos iphonesimulator macosx\n", ""),
         "target DokumentumTests: SUPPORTED_PLATFORMS"),
        ("platforms through :default=", edit(XCCONFIG, "$(DOKUMENTUM_PLATFORMS_$(TARGET_NAME))",
                                             "$(DOKUMENTUM_PLATFORMS_$(TARGET_NAME):default=iphoneos iphonesimulator macosx)"),
         "uses :default="),
        ("the app's Info.plist reaches macOS", edit(XCCONFIG, "DOKUMENTUM_INFOPLIST_Dokumentum[sdk=macosx*] =\n", ""),
         "target Dokumentum: INFOPLIST_FILE resolves to 'Config/Info-iOS.plist' on macosx"),
        ("the app has no Info.plist", edit(XCCONFIG, "DOKUMENTUM_INFOPLIST_Dokumentum = Config/Info-iOS.plist\n", ""),
         "target Dokumentum: INFOPLIST_FILE resolves to '' on iphoneos"),
        ("literal Info.plist", edit(XCCONFIG, "$(DOKUMENTUM_INFOPLIST_$(TARGET_NAME))", "Config/Info-iOS.plist"),
         "target DokumentumShare: INFOPLIST_FILE"),
        ("an unconditional line after the condition wins", edit(
            XCCONFIG, "INFOPLIST_FILE = $(DOKUMENTUM_INFOPLIST_$(TARGET_NAME))",
            "DOKUMENTUM_INFOPLIST_Dokumentum = Config/Info-iOS.plist\nINFOPLIST_FILE = $(DOKUMENTUM_INFOPLIST_$(TARGET_NAME))"),
         "resolves to 'Config/Info-iOS.plist' on macosx"),
        ("the camera text missing on iOS", edit(
            XCCONFIG, "DOKUMENTUM_CAMERA_USAGE_Dokumentum[sdk=iphone*] = Dokumentum uses the camera to scan documents.\n", ""),
         "target Dokumentum: INFOPLIST_KEY_NSCameraUsageDescription resolves to '' on iphoneos"),
        ("the camera text empty on iOS", edit(
            XCCONFIG, "[sdk=iphone*] = Dokumentum uses the camera to scan documents.", "[sdk=iphone*] ="),
         "target Dokumentum: INFOPLIST_KEY_NSCameraUsageDescription resolves to '' on iphonesimulator"),
        ("the camera text on macOS", edit(XCCONFIG, "DOKUMENTUM_CAMERA_USAGE_Dokumentum[sdk=iphone*]",
                                          "DOKUMENTUM_CAMERA_USAGE_Dokumentum"),
         "target Dokumentum: INFOPLIST_KEY_NSCameraUsageDescription resolves to 'Dokumentum uses the camera to scan "
         "documents.' on macosx"),
        ("the camera text for every target", edit(XCCONFIG, "$(DOKUMENTUM_CAMERA_USAGE_$(TARGET_NAME))", "Camera."),
         "target DokumentumShare: INFOPLIST_KEY_NSCameraUsageDescription resolves to 'Camera.' on iphoneos"),
        ("a self-referring setting", edit(XCCONFIG, "DOKUMENTUM_BUNDLE_ID_SUFFIX_Dokumentum =\n",
                                          "DOKUMENTUM_BUNDLE_ID_SUFFIX_Dokumentum = $(DOKUMENTUM_BUNDLE_ID_SUFFIX_Dokumentum)\n"),
         "refers to itself"),
        ("a self-referring identity", in_xcconfig("CODE_SIGN_IDENTITY = $(CODE_SIGN_IDENTITY)"), "refers to itself"),
        ("a target without a row", edit(PROJECT, "C0 = {isa = PBXNativeTarget; name = DokumentumShare;",
                                        "C0 = {isa = PBXNativeTarget; name = DokumentumOther;"),
         "DokumentumOther has no row in TARGETS"),
        ("the extension target is gone", edit(PROJECT, "A7, A8, C0, )", "A7, A8, )"), "target DokumentumShare is missing"),
        # Platform filters and embedding.
        ("dependency without a filter", edit(PROJECT, "isa = PBXTargetDependency; platformFilters = (ios, );", "isa = PBXTargetDependency;"),
         "its dependency on DokumentumShare must be filtered to ios"),
        ("embed without a filter", edit(PROJECT, "fileRef = C1; platformFilters = (ios, );", "fileRef = C1;"),
         "the embedded DokumentumShare must be filtered to ios"),
        ("dependency with another filter", edit(PROJECT, "isa = PBXTargetDependency; platformFilters = (ios, );",
                                                "isa = PBXTargetDependency; platformFilter = macos;"),
         "must be filtered to ios"),
        ("embed for two platforms", edit(PROJECT, "fileRef = C1; platformFilters = (ios, );",
                                         "fileRef = C1; platformFilters = (ios, macos, );"),
         "must be filtered to ios"),
        ("both forms that disagree", edit(PROJECT, "fileRef = C1; platformFilters = (ios, );",
                                          "fileRef = C1; platformFilter = macos; platformFilters = (ios, );"),
         "must be filtered to ios"),
        ("no dependency on the extension", edit(PROJECT, "dependencies = (C3, );", "dependencies = ();"),
         "needs one dependency on DokumentumShare"),
        ("the extension not embedded", edit(PROJECT, "files = (C4, );", "files = ();"), "needs to embed DokumentumShare once"),
        ("the extension links DokumentumCore instead", edit(PROJECT, "packageProductDependencies = (D1, );",
                                                            "packageProductDependencies = (D0, );"),
         "must link exactly the package products ['DokumentumKit'], found ['DokumentumCore']"),
        ("the extension links DokumentumCore too", edit(PROJECT, "packageProductDependencies = (D1, );",
                                                        "packageProductDependencies = (D1, D0, );"),
         "found ['DokumentumCore', 'DokumentumKit']"),
        ("the extension links no package", edit(PROJECT, "packageProductDependencies = (D1, );", ""),
         "must link exactly the package products ['DokumentumKit'], found []"),
        # Signing.
        ("target identity", in_target("CODE_SIGN_IDENTITY"), "sets CODE_SIGN_IDENTITY"),
        ("target identity with a condition", in_target('"CODE_SIGN_IDENTITY[sdk=macosx*]"'), "sets CODE_SIGN_IDENTITY[sdk=macosx*]"),
        ("project identity", in_project("CODE_SIGN_IDENTITY"), "sets CODE_SIGN_IDENTITY"),
        ("target CODE_SIGNING_ALLOWED", in_target("CODE_SIGNING_ALLOWED"), "sets CODE_SIGNING_ALLOWED"),
        ("project CODE_SIGNING_ALLOWED", in_project("CODE_SIGNING_ALLOWED"), "sets CODE_SIGNING_ALLOWED"),
        ("xcconfig CODE_SIGNING_ALLOWED", in_xcconfig("CODE_SIGNING_ALLOWED = NO"), "sets CODE_SIGNING_ALLOWED"),
        ("ad hoc next to a team", in_xcconfig("CODE_SIGN_IDENTITY = -"), "next to a team"),
        ("ad hoc on macOS next to a team", in_xcconfig("CODE_SIGN_IDENTITY[sdk=macosx*] = -"), "next to a team"),
        ("ad hoc in quotes", in_xcconfig('CODE_SIGN_IDENTITY = "-"'), "next to a team"),
        ("ad hoc with a comment", in_xcconfig("CODE_SIGN_IDENTITY = - // for now"), "next to a team"),
        ("ad hoc through a variable", in_xcconfig("MY_IDENTITY = -\nCODE_SIGN_IDENTITY = $(MY_IDENTITY)"), "next to a team"),
        ("a real identity next to the team is fine", in_xcconfig("CODE_SIGN_IDENTITY = Apple Development"), None),
        ("no team", edit(XCCONFIG, "DEVELOPMENT_TEAM = 88GY2V9C2A", "DEVELOPMENT_TEAM ="), "must be one line with the team"),
        ("another team", edit(XCCONFIG, "DEVELOPMENT_TEAM = 88GY2V9C2A", "DEVELOPMENT_TEAM = AAAAAAAAAA"), "must be one line with the team"),
        ("the team cleared on macOS", in_xcconfig("DEVELOPMENT_TEAM[sdk=macosx*] ="), "must be one line with the team"),
        ("manual signing", edit(XCCONFIG, "CODE_SIGN_STYLE = Automatic", "CODE_SIGN_STYLE = Manual"), "CODE_SIGN_STYLE must be"),
        ("provisioning style in the target attributes", edit(PROJECT, "CreatedOnToolsVersion = 27.1;", "ProvisioningStyle = Manual;"),
         "ProvisioningStyle"),
        # Includes.
        ("xcconfig includes the unsigned file", edit(XCCONFIG, '#include? "Local.xcconfig"', '#include "Unsigned.xcconfig"'),
         '#include "Unsigned.xcconfig"; the only include allowed'),
        ("xcconfig includes the unsigned file, optionally", in_xcconfig('#include? "Unsigned.xcconfig"'), "the only include allowed"),
        ("xcconfig requires Local.xcconfig", edit(XCCONFIG, '#include? "Local.xcconfig"', '#include "Local.xcconfig"'),
         "the only include allowed"),
        # Capability settings.
        ("hardened runtime on", edit(XCCONFIG, "ENABLE_HARDENED_RUNTIME = NO", "ENABLE_HARDENED_RUNTIME = YES"), "ENABLE_HARDENED_RUNTIME = YES"),
        ("hardened runtime with a condition", edit(XCCONFIG, "ENABLE_HARDENED_RUNTIME = NO", "ENABLE_HARDENED_RUNTIME[sdk=macosx*] = NO"),
         "ENABLE_HARDENED_RUNTIME[sdk=macosx*] = NO"),
        ("hardened runtime off plus on", in_xcconfig("ENABLE_HARDENED_RUNTIME[sdk=macosx*] = YES"), "ENABLE_HARDENED_RUNTIME[sdk=macosx*] = YES"),
        ("target hardened runtime off", in_target("ENABLE_HARDENED_RUNTIME"), "sets ENABLE_HARDENED_RUNTIME"),
        ("project hardened runtime off", in_project("ENABLE_HARDENED_RUNTIME"), "sets ENABLE_HARDENED_RUNTIME"),
        ("capability setting NO", in_xcconfig("ENABLE_APP_SANDBOX = NO"), "ENABLE_APP_SANDBOX = NO"),
        ("capability setting with a condition", in_target('"ENABLE_OUTGOING_NETWORK_CONNECTIONS[sdk=macosx*]"'),
         "sets ENABLE_OUTGOING_NETWORK_CONNECTIONS[sdk=macosx*], which injects"),
        # Entitlements files.
        ("an extra entitlement", set_entitlement(MAC_APP_ENTITLEMENTS, "com.apple.security.network.client", True),
         "com.apple.security.network.client is not a reviewed entitlement"),
        ("an extra entitlement in the extension", set_entitlement(SHARE_ENTITLEMENTS, "aps-environment", "development"),
         "aps-environment is not a reviewed entitlement"),
        ("an app group on the Mac", set_entitlement(MAC_APP_ENTITLEMENTS, "com.apple.security.application-groups", [APP_GROUP]),
         "com.apple.security.application-groups is not a reviewed entitlement"),
        ("another container", set_entitlement(IOS_APP_ENTITLEMENTS, "com.apple.developer.icloud-container-identifiers", ["iCloud.other"]),
         "icloud-container-identifiers is ['iCloud.other']"),
        ("another group", set_entitlement(SHARE_ENTITLEMENTS, "com.apple.security.application-groups", ["group.other"]),
         "application-groups is ['group.other']"),
        ("the sandbox off", set_entitlement(MAC_APP_ENTITLEMENTS, "com.apple.security.app-sandbox", False), "app-sandbox is False"),
        ("no user-selected files on the Mac", replace_entitlement(MAC_APP_ENTITLEMENTS, USER_SELECTED_READ_ONLY, None),
         f"{USER_SELECTED_READ_ONLY} is missing"),
        ("user-selected files read-write", replace_entitlement(MAC_APP_ENTITLEMENTS, USER_SELECTED_READ_ONLY,
                                                               "com.apple.security.files.user-selected.read-write"),
         "com.apple.security.files.user-selected.read-write is not a reviewed entitlement"),
        ("user-selected files off", set_entitlement(MAC_APP_ENTITLEMENTS, USER_SELECTED_READ_ONLY, False), "read-only is False"),
        ("user-selected files on iOS", set_entitlement(IOS_APP_ENTITLEMENTS, USER_SELECTED_READ_ONLY, True),
         f"{IOS_APP_ENTITLEMENTS}: {USER_SELECTED_READ_ONLY} is not a reviewed entitlement"),
        ("a missing entitlement", write(SHARE_ENTITLEMENTS, plistlib.dumps({}).decode()), "application-groups is missing"),
        ("an entitlements file is gone", remove(MAC_APP_ENTITLEMENTS), f"{MAC_APP_ENTITLEMENTS} is missing"),
        ("an entitlements file is not a plist", write(IOS_APP_ENTITLEMENTS, "<plist"), "not a valid property list"),
        ("an unknown entitlements file", write("Config/Other.entitlements", ""), "Config/Other.entitlements is not a reviewed"),
        # Info.plist files.
        ("an extra key in the app's Info.plist", write(IOS_APP_INFO, plistlib.dumps({"UIBackgroundModes": ["remote-notification"], "X": "y"}).decode()),
         "holds only UIBackgroundModes"),
        ("another background mode", write(IOS_APP_INFO, plistlib.dumps({"UIBackgroundModes": ["audio"]}).decode()), "holds only UIBackgroundModes"),
        ("another extension point", write(SHARE_INFO, plistlib.dumps({"NSExtension": {
            **SHARE_INFO_CONTENT["NSExtension"], "NSExtensionPointIdentifier": "x"}}).decode()),
         "must hold exactly the reviewed keys"),
        ("an activation rule that offers everything", write(SHARE_INFO, plistlib.dumps({"NSExtension": {
            **SHARE_INFO_CONTENT["NSExtension"],
            "NSExtensionAttributes": {"NSExtensionActivationRule": "TRUEPREDICATE"}}}).decode()),
         "must hold exactly the reviewed keys"),
        ("a background mode in the extension", write(SHARE_INFO, plistlib.dumps(
            {**SHARE_INFO_CONTENT, "UIBackgroundModes": ["remote-notification"]}).decode()),
         "must hold exactly the reviewed keys"),
        # Forms Xcode accepts that a plain parser overlooks.
        ("capability with a space before the condition", in_xcconfig("ENABLE_OUTGOING_NETWORK_CONNECTIONS [sdk=*] = YES"),
         "sets ENABLE_OUTGOING_NETWORK_CONNECTIONS[sdk=*] = YES"),
        ("capability with a space on a target", in_target('"ENABLE_OUTGOING_NETWORK_CONNECTIONS [sdk=*]"'), "which injects"),
        ("identity with a space before the condition", in_xcconfig("CODE_SIGN_IDENTITY [sdk=macosx*] = -"), "next to a team"),
        ("entitlements with a space before the condition", in_xcconfig_last("CODE_SIGN_ENTITLEMENTS [sdk=macosx*] = Config/x.plist"),
         "target Dokumentum: CODE_SIGN_ENTITLEMENTS resolves to 'Config/x.plist' on macosx"),
        ("unsigned file with a spaced extra key", edit(UNSIGNED_XCCONFIG, "// A comment", "ENABLE_OUTGOING_NETWORK_CONNECTIONS [sdk=*] = YES"),
         "must hold exactly"),
        ("target base configuration by anchor", edit(PROJECT, "A9 = {isa = XCBuildConfiguration;",
                                                     "A9 = {isa = XCBuildConfiguration; baseConfigurationReferenceAnchor = A6;"),
         "target Dokumentum, configuration Debug: baseConfigurationReferenceAnchor names its own"),
        ("target base configuration by path", edit(PROJECT, "A9 = {isa = XCBuildConfiguration;",
                                                   "A9 = {isa = XCBuildConfiguration; baseConfigurationReferenceRelativePath = x.xcconfig;"),
         "baseConfigurationReferenceRelativePath names its own"),
        ("project base configuration by path", edit(PROJECT, "baseConfigurationReference = B2;",
                                                    "baseConfigurationReference = B2; baseConfigurationReferenceRelativePath = x.xcconfig;"),
         "project configuration Debug: baseConfigurationReferenceRelativePath names another"),
        ("xcconfig with # include", in_xcconfig('# include "Unsigned.xcconfig"'), "the only include allowed"),
        ("xcconfig with #  include?", in_xcconfig('#  include? "Unsigned.xcconfig"'), "the only include allowed"),
        ("unsigned file with # include", edit(UNSIGNED_XCCONFIG, "// A comment", '# include "Sneaky.xcconfig"'), "includes another file"),
        ("entitlements for one SDK version pattern", in_xcconfig_last("DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=macosx27*] = Config/x.plist"),
         "DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=macosx27*] uses a condition"),
        ("entitlements for one exact SDK", in_xcconfig_last("DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=macosx27.0] = Config/x.plist"),
         "uses a condition"),
        ("identity for one SDK version", in_xcconfig("CODE_SIGN_IDENTITY[sdk=macosx27*] = Apple Development"), "uses a condition"),
        ("a pattern for versioned names only", in_xcconfig_last("DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=macosx*.*] = Config/x.plist"),
         "[sdk=macosx*.*] uses a condition"),
        ("the same on the key itself", in_xcconfig_last("CODE_SIGN_ENTITLEMENTS[sdk=*.*] = Config/x.plist"), "[sdk=*.*] uses a condition"),
        ("a pattern with a question mark", in_xcconfig_last("CODE_SIGN_ENTITLEMENTS[sdk=macosx?*] = Config/x.plist"),
         "[sdk=macosx?*] uses a condition"),
        ("the same with a space", in_xcconfig_last("CODE_SIGN_ENTITLEMENTS [sdk=macosx*.*] = Config/x.plist"), "[sdk=macosx*.*] uses a condition"),
        ("a condition for every SDK", in_xcconfig_last("MY_SETTING[sdk=*] = x"), "[sdk=*] uses a condition"),
        ("two conditions in one bracket", in_xcconfig_last("CODE_SIGN_ENTITLEMENTS[arch=arm64,sdk=macosx*.*] = Config/x.plist"), "uses a condition"),
        ("a condition on the architecture", in_xcconfig_last("CODE_SIGN_ENTITLEMENTS[arch=arm64] = Config/x.plist"), "uses a condition"),
        ("a condition on the configuration", in_xcconfig_last("MY_SETTING[config=Debug] = x"), "uses a condition"),
        ("iphone* is fine", in_xcconfig_last("MY_SETTING[sdk=iphone*] = x"), None),
        ("iphoneos* is fine", in_xcconfig_last("MY_SETTING[sdk=iphoneos*] = x"), None),
        ("iphonesimulator* is fine", in_xcconfig_last("MY_SETTING[sdk=iphonesimulator*] = x"), None),
        ("macosx* is fine", in_xcconfig_last("MY_SETTING[sdk=macosx*] = x"), None),
        # What Xcode writes keeps passing.
        ("$(inherited) in the xcconfig is fine", in_xcconfig_last("OTHER_SWIFT_FLAGS = $(inherited) -DSHARE"), None),
        ("$(inherited) on a target is fine", edit(PROJECT, "A9 = {isa = XCBuildConfiguration; buildSettings = {",
                                                  'A9 = {isa = XCBuildConfiguration; buildSettings = {\n\t\t\tOTHER_SWIFT_FLAGS = "$(inherited) -DSHARE";'),
         None),
        ("$(inherited) in a list on a target is fine", edit(PROJECT, "A9 = {isa = XCBuildConfiguration; buildSettings = {",
                                                            'A9 = {isa = XCBuildConfiguration; buildSettings = {\n\t\t\tOTHER_LDFLAGS = ("$(inherited)", "-ObjC", );'),
         None),
        ("Xcode's forms together are fine", lambda root: (
            edit(PROJECT, "dstSubfolderSpec = 13;", "dstSubfolder = PlugIns;")(root),
            edit(PROJECT, 'dstPath = "";', "")(root),
            edit(PROJECT, "platformFilters = (ios, );", "platformFilter = ios;")(root)), None),
        ("xcconfig OTHER_CODE_SIGN_FLAGS", in_xcconfig("OTHER_CODE_SIGN_FLAGS = --options runtime"), "sets OTHER_CODE_SIGN_FLAGS"),
        ("xcconfig OTHER_CODE_SIGN_FLAGS with a condition", in_xcconfig("OTHER_CODE_SIGN_FLAGS[sdk=macosx*] = --options runtime"),
         "sets OTHER_CODE_SIGN_FLAGS"),
        ("target OTHER_CODE_SIGN_FLAGS", in_target("OTHER_CODE_SIGN_FLAGS"), "sets OTHER_CODE_SIGN_FLAGS"),
        ("project OTHER_CODE_SIGN_FLAGS", in_project("OTHER_CODE_SIGN_FLAGS"), "sets OTHER_CODE_SIGN_FLAGS"),
        ("a committed Local.xcconfig", committed_local, f"{LOCAL_XCCONFIG} is committed"),
        ("a personal Local.xcconfig is fine", write(LOCAL_XCCONFIG, "// personal\n"), None),
        # The extension.
        ("DokumentumCore linked in the extension's phase only", edit(PROJECT, "C6 = {isa = PBXBuildFile; productRef = D2;};",
                                                                     "C6 = {isa = PBXBuildFile; productRef = D0;};"),
         "its build phases must link exactly the package products ['DokumentumKit'], found ['DokumentumCore']"),
        ("DokumentumCore linked in the extension's phase too", edit(PROJECT, "files = (C6, );",
                                                                    "files = (C6, C7, );};\n\t\tC7 = {isa = PBXBuildFile; productRef = D0;"),
         "found ['DokumentumCore', 'DokumentumKit']"),
        ("Kit not linked in the extension's phase", edit(PROJECT, "files = (C6, );", "files = ();"),
         "its build phases must link exactly the package products ['DokumentumKit'], found []"),
        ("embedded into another folder", edit(PROJECT, "dstSubfolderSpec = 13;", "dstSubfolderSpec = 10;"), "must copy DokumentumShare into PlugIns"),
        ("embedded without a destination", edit(PROJECT, "dstSubfolderSpec = 13;", ""), "must copy DokumentumShare into PlugIns"),
        ("embedded into a subfolder", edit(PROJECT, 'dstPath = "";', "dstPath = x;"), "must copy DokumentumShare into PlugIns"),
        ("the newer form of the destination is fine", edit(PROJECT, "dstSubfolderSpec = 13;", "dstSubfolder = PlugIns;"), None),
        ("the newer form with another folder", edit(PROJECT, "dstSubfolderSpec = 13;", "dstSubfolder = Frameworks;"),
         "must copy DokumentumShare into PlugIns"),
        ("the extension's Info.plist is gone", remove(SHARE_INFO), f"{SHARE_INFO} is missing"),
        # The unsigned path.
        ("unsigned file missing", remove(UNSIGNED_XCCONFIG), f"{UNSIGNED_XCCONFIG} is missing"),
        ("unsigned file with an extra key", edit(UNSIGNED_XCCONFIG, "// A comment", "CODE_SIGNING_ALLOWED = NO"), "must hold exactly"),
        ("unsigned file without a key", edit(UNSIGNED_XCCONFIG, "DEVELOPMENT_TEAM[sdk=macosx*] =\n", ""), "must hold exactly"),
        ("unsigned entitlements for every SDK", edit(UNSIGNED_XCCONFIG, "CODE_SIGN_ENTITLEMENTS[sdk=macosx*] =", "CODE_SIGN_ENTITLEMENTS ="),
         "must hold exactly"),
        ("unsigned with another identity", edit(UNSIGNED_XCCONFIG, "IDENTITY[sdk=macosx*] = -", "IDENTITY[sdk=macosx*] = Apple Development"),
         "must hold exactly"),
        ("unsigned with an include", edit(UNSIGNED_XCCONFIG, "// A comment", '#include "Project.xcconfig"'), "includes another file"),
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
    # The words of the extension's rule: anywhere, for both, including what a lexer short of Swift's misreads.
    # Written out, not read from the constant, so that dropping a word from the constant fails here.
    for word in ("DokumentumCore", "SwiftData"):
        for form in ("import {}", "internal import {}", "@_spi(Foo) import {}", "import UIKit; import {}",
                     "import struct {}.X", "import `{}`", "#if canImport({})\n#endif", "let a = {}.self",
                     "// {}", "/* {} */", "/// {}", 'let a = "{}"', 'let a = """\n{}\n"""',
                     'let p = #"a"b/*c"#\nimport {}', 'let p = #"use "/*" here"#\nimport {}',
                     '"""\nx \\""" y\n"""\nimport {}', '##"""\n"""#\n"""##\nimport {}',
                     'let p = "\\(c ? "/*" : "")"\nimport {}', 'let p = "\\(b ?? "image/*")"\nimport {}',
                     "func g() {{ _ = #/a/*b/# }}\nimport {}"):
            source = form.format(word) + "\n"
            cases.append((f"the extension: {source!r}", write(f"{SHARE_FOLDER}/Store.swift", source), f"contains the word {word}"))
    for source in ("let importantValue = 1\n", "let SwiftDataX = 1\n", "let xSwiftData = 1\n", "let SwiftData_x = 1\n",
                   "let DokumentumCoreTests = 1\n", "let swiftData = 1\n", "// the store and the model stay out\n",
                   "import UIKit\nimport UniformTypeIdentifiers\n\nfinal class ShareViewController: UIViewController {\n"
                   "    override func viewDidAppear(_ animated: Bool) {\n        super.viewDidAppear(animated)\n"
                   "        extensionContext?.completeRequest(returningItems: nil)\n    }\n}\n"):
        cases.append((f"the extension, no such word: {source[:30]!r}", write(f"{SHARE_FOLDER}/Store.swift", source), None))
    cases += [
        ("the message names the line", write(f"{SHARE_FOLDER}/Store.swift", "import UIKit\n// SwiftData\n"),
         f"{SHARE_FOLDER}/Store.swift:2: contains the word SwiftData"),
        ("a Swift file in a subfolder", in_subfolder, "Sub/Store.swift:1: contains the word SwiftData"),
        ("a file that is not UTF-8", lambda root: (root / f"{SHARE_FOLDER}/Store.swift").write_bytes(b"// \xff\nimport SwiftData\n"),
         "Store.swift:2: contains the word SwiftData"),
        ("another kind of file is fine", write(f"{SHARE_FOLDER}/notes.txt", "SwiftData\n"), None),
        # Xcode reads a space inside the bracket as part of the pattern, so these conditions match no SDK.
        ("a space in a condition", in_xcconfig_last("DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=macosx *] = Config/x.plist"),
         "[sdk=macosx *] uses a condition"),
        ("a space after a pattern", in_xcconfig_last("DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=macosx* ] = Config/x.plist"),
         "[sdk=macosx* ] uses a condition"),
        ("a space before a pattern", in_xcconfig_last("DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk= macosx*] = Config/x.plist"),
         "[sdk= macosx*] uses a condition"),
        ("a tab in a condition", in_xcconfig_last("DOKUMENTUM_ENTITLEMENTS_Dokumentum[sdk=\tmacosx*] = Config/x.plist"), "uses a condition"),
        ("a space around the name", in_xcconfig_last("MY_SETTING[ sdk=macosx*] = x"), "[ sdk=macosx*] uses a condition"),
        ("a space in the unsigned file's condition", edit(UNSIGNED_XCCONFIG, "IDENTITY[sdk=macosx*] = -", "IDENTITY[sdk=macosx *] = -"),
         "must hold exactly"),
    ]
    # Every setting of the category fails in the xcconfig, on a target and on the project.
    for name in sorted(CAPABILITY_SETTINGS - {"ENABLE_HARDENED_RUNTIME"}):
        cases += [
            (f"xcconfig {name}", in_xcconfig(f"{name} = YES"), f"sets {name} = YES, which injects"),
            (f"target {name}", in_target(name), f"sets {name}, which injects"),
            (f"project {name}", in_project(name), f"sets {name}, which injects"),
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
    assert parse_xcconfig("A[sdk=x*][arch=y] = 1\n// B = 2\n#include? \"C\"\nD =\nE = f // g\n") == \
        {"A": [("[sdk=x*][arch=y]", "1")], "D": [("", "")], "E": [("", "f")]}
    assert len(CAPABILITY_SETTINGS) == 25
    post_clone_cases = self_test_post_clone()
    print(f"self-test passed ({len(cases) + 3 + post_clone_cases} cases)")


def main():
    problems = check(pathlib.Path.cwd())
    for problem in problems:
        print(f"error: {problem}")
    if not problems:
        print(f"{PROJECT}, {XCCONFIG}, the targets, the entitlements, the scheme, the test plans and the Xcode Cloud "
              "scripts are fine")
    return 1 if problems else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main())
