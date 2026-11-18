#!/bin/bash
# Runs the UI tests: builds Archipel as a separate app ("Archipel UI Tests", bundle id
# <bundle id>.uitests) and drives it through its real window, against a throwaway
# workspace and git repositories under /private/tmp.
#
#   ./scripts/ui-tests.sh                                    # everything
#   ./scripts/ui-tests.sh WorktreeTests                      # one class
#   ./scripts/ui-tests.sh TabTests/testRenamingASession      # one test
#
# The tests take over the keyboard and the pointer while they run, so leave the Mac
# alone until they are done. Copies of Archipel that are already running, installed
# or Debug, are not touched: the app under test has its own bundle id, settings,
# support folder and hook socket.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# Separate from Xcode's own DerivedData, so a test run never rebuilds the Debug app
# you may have running from Xcode.
derived="${ARCHIPEL_UI_TESTS_DERIVED_DATA:-$root/.build/ui-tests}"

if [[ ! -d "$root/Packages/TerminalKit/Frameworks/GhosttyKit.xcframework" ]]; then
  echo "error: GhosttyKit is missing. Run ./scripts/build-ghostty.sh first." >&2
  exit 1
fi

only=()
for test in "$@"; do
  only+=("-only-testing:ArchipelUITests/$test")
done

# xcodebuild refuses to overwrite a result bundle, and the newest one is what a
# failed run is debugged with.
results="$derived/ArchipelUITests.xcresult"
rm -rf "$results"

# No test needs anywhere near 5 minutes. A stuck one fails with a spindump in the result bundle
# instead of holding the CI job until it times out.
# ${only[@]+...}: an empty array counts as unset under `set -u` in the bash that macOS ships.
xcodebuild test \
  -project "$root/Archipel.xcodeproj" \
  -scheme ArchipelUITests \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived" \
  -resultBundlePath "$results" \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 300 \
  -maximum-test-execution-time-allowance 300 \
  ${only[@]+"${only[@]}"}
