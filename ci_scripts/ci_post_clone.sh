#!/bin/bash
# Xcode Cloud runs this after cloning (it requires the name and the folder next to the project).
# It prints the toolchain into the build log and fails when the Xcode differs from .xcode-version
# or has no SDK for the minimum OS in Config/Project.xcconfig. No secrets, no network.
set -euo pipefail

repository="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

xcode_output="$(xcodebuild -version)"
sdks_output="$(xcodebuild -showsdks)"
echo "$xcode_output"
echo "$sdks_output"
sw_vers

pinned="$(tr -d '[:space:]' < "$repository/.xcode-version")"
actual="$(awk '$1 == "Xcode" { print $2; exit }' <<< "$xcode_output")"
if [ -z "$pinned" ] || [ "$actual" != "$pinned" ]; then
    echo "error: this is Xcode '$actual', but .xcode-version pins '$pinned'." >&2
    echo "error: select the pinned version in the Xcode Cloud workflow, or change .xcode-version." >&2
    exit 1
fi

# The major version of a deployment target in the xcconfig, e.g. 27 for "27.0".
minimum_major() {
    sed -n "s/^$1 *= *\([0-9][0-9]*\).*/\1/p" "$repository/Config/Project.xcconfig" | head -n 1
}

ios_major="$(minimum_major IPHONEOS_DEPLOYMENT_TARGET)"
macos_major="$(minimum_major MACOSX_DEPLOYMENT_TARGET)"
if [ -z "$ios_major" ] || [ -z "$macos_major" ]; then
    echo "error: no deployment targets found in Config/Project.xcconfig." >&2
    exit 1
fi

missing=0
for sdk in "iphoneos$ios_major" "iphonesimulator$ios_major" "macosx$macos_major"; do
    if ! grep -Eq -- "-sdk $sdk(\.|\$)" <<< "$sdks_output"; then
        echo "error: Xcode $actual has no $sdk SDK, which the minimum OS needs (docs/development/plan.md, section 2)." >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    exit 1
fi

echo "Xcode $actual matches .xcode-version; SDKs for iOS $ios_major and macOS $macos_major are there."
