#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${SOURCE_APP:-/private/tmp/SuperIslandWindowEnhancementDerivedData/Build/Products/Debug/SuperIsland.app}"
SIGNING_IDENTITY="${WE1_CODE_SIGN_IDENTITY:--}"
SOURCE_EXECUTABLE="${SOURCE_APP}/Contents/MacOS/SuperIsland"
SOURCE_DEBUG_DYLIB="${SOURCE_APP}/Contents/MacOS/SuperIsland.debug.dylib"
OUTPUT_DIR="${ROOT_DIR}/build/WE1-Debug"
OUTPUT_APP="${OUTPUT_DIR}/SuperIsland-WE1-Debug.app"
BACKUP_DIR="${OUTPUT_DIR}/backups"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/superisland-we1-debug.XXXXXX")"
STAGED_APP="${STAGE_DIR}/SuperIsland-WE1-Debug.app"

cleanup() {
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

if [ ! -d "${SOURCE_APP}" ]; then
  echo "ERROR: Debug app not found: ${SOURCE_APP}" >&2
  exit 1
fi
if [ ! -x "${SOURCE_EXECUTABLE}" ]; then
  echo "ERROR: Debug executable not found: ${SOURCE_EXECUTABLE}" >&2
  exit 1
fi
if [ ! -f "${SOURCE_DEBUG_DYLIB}" ]; then
  echo "ERROR: Debug code payload not found: ${SOURCE_DEBUG_DYLIB}" >&2
  exit 1
fi

# Never silently package an older DerivedData product. The Debug dylib is the
# real Swift code payload; the tiny executable is only Xcode's debug stub.
# Include compiled sources, ExtensionHost, post-compile extension inputs and
# project/package metadata so a stale resource cannot slip into the test app.
STALE_INPUT="$(find \
  "${ROOT_DIR}/SuperIsland" \
  "${ROOT_DIR}/ExtensionHost" \
  "${ROOT_DIR}/Extensions" \
  "${ROOT_DIR}/project.yml" \
  "${ROOT_DIR}/SuperIsland.xcodeproj/project.pbxproj" \
  "${ROOT_DIR}/SuperIsland.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
  "${ROOT_DIR}/prototype/assets/settings-previews" \
  "${ROOT_DIR}/prototype/assets/settings-layouts" \
  -type f ! -name '.DS_Store' -newer "${SOURCE_DEBUG_DYLIB}" -print -quit)"
if [ -n "${STALE_INPUT}" ]; then
  echo "ERROR: Debug app is stale; this input is newer than the Swift code payload:" >&2
  echo "  ${STALE_INPUT}" >&2
  echo "Run the current xcodebuild before packaging." >&2
  exit 1
fi

# A fixed DerivedData path can be reused by another checkout. Debug info embeds
# source file paths, so verify the code payload was actually built from this
# repository before changing its bundle identity and signing it.
strings "${SOURCE_DEBUG_DYLIB}" > "${STAGE_DIR}/debug-source-paths.txt"
if ! grep -Fq "${ROOT_DIR}/SuperIsland/WindowEnhancement/" "${STAGE_DIR}/debug-source-paths.txt"; then
  echo "ERROR: Debug app was not built from the current checkout: ${ROOT_DIR}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}" "${BACKUP_DIR}"

echo "==> Copying verified Debug app..."
ditto "${SOURCE_APP}" "${STAGED_APP}"

# `xcodebuild test` embeds its test bundle and XCTest runtime into the host
# application. They are not part of SuperIsland and must never ship in the
# always-running WE1 Debug app. Remove only the known test artifacts from the
# isolated staging copy before signing; the source build stays untouched.
TEST_ONLY_ARTIFACTS=(
  "Contents/PlugIns/SuperIslandWindowEnhancementTests.xctest"
  "Contents/Frameworks/XCUnit.framework"
  "Contents/Frameworks/XCTAutomationSupport.framework"
  "Contents/Frameworks/XCUIAutomation.framework"
  "Contents/Frameworks/XCTestSupport.framework"
  "Contents/Frameworks/XCTest.framework"
  "Contents/Frameworks/XCTestCore.framework"
  "Contents/Frameworks/libXCTestSwiftSupport.dylib"
  "Contents/Frameworks/Testing.framework"
  "Contents/Frameworks/libXCTestBundleInject.dylib"
)
for relative_path in "${TEST_ONLY_ARTIFACTS[@]}"; do
  rm -rf "${STAGED_APP}/${relative_path}"
done
rmdir "${STAGED_APP}/Contents/PlugIns" 2>/dev/null || true
REMAINING_TEST_ARTIFACT="$(find "${STAGED_APP}/Contents" \
  \( -name '*.xctest' -o -name 'XCTest*.framework' -o -name 'Testing.framework' \) \
  -print -quit)"
if [ -n "${REMAINING_TEST_ARTIFACT}" ]; then
  echo "ERROR: staged app still contains a test runtime artifact:" >&2
  echo "  ${REMAINING_TEST_ARTIFACT}" >&2
  exit 1
fi

INFO_PLIST="${STAGED_APP}/Contents/Info.plist"
DEBUG_BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
SOURCE_EXECUTABLE_SHA256="$(shasum -a 256 "${SOURCE_EXECUTABLE}" | awk '{print $1}')"
SOURCE_DEBUG_DYLIB_SHA256="$(shasum -a 256 "${SOURCE_DEBUG_DYLIB}" | awk '{print $1}')"
SOURCE_CODE_SHA256="$(printf '%s\n%s\n' \
  "${SOURCE_EXECUTABLE_SHA256}" \
  "${SOURCE_DEBUG_DYLIB_SHA256}" | shasum -a 256 | awk '{print $1}')"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.workview.SuperIsland.WE1Debug" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SuperIsland WE1 Debug" "${INFO_PLIST}" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'SuperIsland WE1 Debug'" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleName SuperIsland-WE1-Debug" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${DEBUG_BUILD_NUMBER}" "${INFO_PLIST}"
# The local test bundle must never register or take ownership of production's
# superisland:// OAuth/deep-link scheme.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "${INFO_PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :WE1DebugSourceExecutableSHA256 ${SOURCE_EXECUTABLE_SHA256}" "${INFO_PLIST}" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :WE1DebugSourceExecutableSHA256 string ${SOURCE_EXECUTABLE_SHA256}" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :WE1DebugSourceCodeSHA256 ${SOURCE_CODE_SHA256}" "${INFO_PLIST}" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :WE1DebugSourceCodeSHA256 string ${SOURCE_CODE_SHA256}" "${INFO_PLIST}"

if [ "${SIGNING_IDENTITY}" = "-" ]; then
  echo "==> Applying local ad-hoc signature..."
  echo "WARNING: ad-hoc designated requirements are code hashes; macOS privacy permissions may reset after each rebuild." >&2
  SIGNING_ARGUMENTS=(--force --deep --sign -)
else
  echo "==> Applying stable local signature: ${SIGNING_IDENTITY}"
  # Keep the local Debug build's existing non-hardened runtime mode. Enabling
  # runtime here is not a signing-only change: a self-signed identity has no
  # Apple Team ID, so library validation rejects even its own debug dylib.
  # Production/notarized packaging uses the separate release scripts.
  SIGNING_ARGUMENTS=(
    --force
    --deep
    --sign "${SIGNING_IDENTITY}"
    --timestamp=none
  )
fi
codesign "${SIGNING_ARGUMENTS[@]}" \
  --entitlements "${ROOT_DIR}/SuperIsland/SuperIsland.entitlements" \
  "${STAGED_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"
# Ad-hoc requirements are printed as "# designated =>", whereas certificate
# signatures can print "designated =>" without the comment prefix.
DESIGNATED_REQUIREMENT="$(codesign -d -r- "${STAGED_APP}" 2>&1 | sed -nE 's/^(# )?designated => //p')"
if [ -z "${DESIGNATED_REQUIREMENT}" ]; then
  echo "ERROR: packaged app has no readable designated requirement" >&2
  exit 1
fi
if [ "${SIGNING_IDENTITY}" != "-" ]; then
  if [[ "${DESIGNATED_REQUIREMENT}" == *cdhash* ]] || \
    ! printf '%s\n' "${DESIGNATED_REQUIREMENT}" | grep -Eq 'anchor|certificate'; then
    echo "ERROR: certificate signing did not produce a stable certificate-based requirement" >&2
    exit 1
  fi
fi

if [ -d "${OUTPUT_APP}" ]; then
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  mv "${OUTPUT_APP}" "${BACKUP_DIR}/SuperIsland-WE1-Debug-${TIMESTAMP}.app"
fi

mv "${STAGED_APP}" "${OUTPUT_APP}"

echo ""
echo "SUCCESS: ${OUTPUT_APP}"
echo "Bundle ID: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${OUTPUT_APP}/Contents/Info.plist")"
echo "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${OUTPUT_APP}/Contents/Info.plist")"
echo "Test build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${OUTPUT_APP}/Contents/Info.plist")"
echo "Source executable SHA-256: ${SOURCE_EXECUTABLE_SHA256}"
echo "Source debug dylib SHA-256: ${SOURCE_DEBUG_DYLIB_SHA256}"
echo "Source code payload SHA-256: ${SOURCE_CODE_SHA256}"
echo "Signing identity: ${SIGNING_IDENTITY}"
echo "Designated requirement: ${DESIGNATED_REQUIREMENT}"
