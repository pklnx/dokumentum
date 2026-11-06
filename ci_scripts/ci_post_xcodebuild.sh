#!/bin/bash
# Xcode Cloud runs this after every xcodebuild command. After a build of the app it checks that
# every UI string the compiler saw has a German translation. No secrets, no network.
set -euo pipefail

: "${CI_XCODEBUILD_ACTION:?not set: this script runs in Xcode Cloud, see docs/development/index.md}"

case "$CI_XCODEBUILD_ACTION" in
    build | build-for-testing | archive) ;;
    *)
        echo "ci_post_xcodebuild: nothing to check after '$CI_XCODEBUILD_ACTION'."
        exit 0
        ;;
esac

# A failed build has already failed the action, and it may have written no strings.
if [ "${CI_XCODEBUILD_EXIT_CODE:-0}" -ne 0 ]; then
    echo "ci_post_xcodebuild: xcodebuild failed ($CI_XCODEBUILD_EXIT_CODE), skipping the localisation check."
    exit 0
fi

: "${CI_DERIVED_DATA_PATH:?not set: the localisation check needs the derived data}"

repository="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
python3 "$repository/scripts/check-localization.py" "$CI_DERIVED_DATA_PATH"
