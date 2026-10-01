#!/bin/bash
# SpaceJudge local release candidate (credential-free).
#
# Builds a universal2 Release bundle, applies an ad-hoc Hardened Runtime
# signature, and produces a clearly non-distributable DMG plus manifest. This
# path never contacts Apple services and never runs notarytool.
#
# Usage:
#   scripts/release/local-candidate.sh --output-dir <absolute-dir> [--repo <path>]

set -euo pipefail

# Pin to the trusted system tool path before any external command or PATH
# lookup, so a caller PATH cannot substitute plutil/ditto/xcrun/notarytool/etc.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
unset CDPATH BASH_ENV ENV 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

OUTPUT_DIR=""
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
KEEP_WORK=0
WITH_CLI=0
EXPERIMENTAL=0
GIT_COMMIT=""

usage() {
    cat <<'USAGE'
Usage: local-candidate.sh --output-dir <absolute-dir> [--repo <path>] [--keep-work] [--with-cli] [--experimental]

  --output-dir   Absolute directory that must not exist or must be empty.
  --repo         Repository root (defaults to the parent of scripts/release).
  --keep-work    Keep the task temp build directory for inspection.
  --with-cli     Build and explicitly sign a universal SpaceJudge CLI helper.
  --experimental Opt-in test-sharing package, NOT notarized or production-ready.
                 Requires a clean Git HEAD; always includes CLI and test notice.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir)
            [ "$#" -ge 2 ] || sj_die "--output-dir requires a value"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --repo)
            [ "$#" -ge 2 ] || sj_die "--repo requires a value"
            REPO_DIR="$2"
            shift 2
            ;;
        --keep-work)
            KEEP_WORK=1
            shift
            ;;
        --with-cli)
            WITH_CLI=1
            shift
            ;;
        --experimental)
            EXPERIMENTAL=1
            WITH_CLI=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            sj_die "unknown argument: $1"
            ;;
    esac
done

[ -n "$OUTPUT_DIR" ] || { usage >&2; sj_die "--output-dir is required"; }
if [ "$EXPERIMENTAL" -eq 1 ]; then
    sj_forbid_tool_overrides
fi

sj_require_cmd xcodebuild
sj_require_cmd codesign
sj_require_cmd hdiutil
sj_require_cmd lipo
sj_require_cmd shasum
sj_require_absolute "output directory" "$OUTPUT_DIR"
sj_assert_new_output_dir "$OUTPUT_DIR"

[ -d "$REPO_DIR/App/SpaceJudge.xcodeproj" ] || sj_die "Xcode project not found under: $REPO_DIR"
sj_validate_source_metadata "$REPO_DIR"
if [ "$EXPERIMENTAL" -eq 1 ]; then
    GIT_COMMIT="$(sj_git_ready "$REPO_DIR")"
fi

MOUNT_POINT=""
cleanup() {
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        sj_detach_dmg "$MOUNT_POINT"
    fi
    if [ "${KEEP_WORK:-0}" -ne 1 ]; then
        sj_cleanup_temp
    fi
}
trap cleanup EXIT

# Direct call: sj_make_temp_dir sets SJ_TEMP_DIR in this shell so the trap can
# still reclaim the directory after a failure.
sj_make_temp_dir spacejudge-localcandidate
WORK_DIR="$SJ_TEMP_DIR"
LOG_DIR="$WORK_DIR/logs"
sj_mkdirs "$LOG_DIR"
sj_secure_dir "$LOG_DIR"

sj_mkdirs "$OUTPUT_DIR"
sj_mkdirs "$OUTPUT_DIR/logs"
sj_secure_dir "$OUTPUT_DIR/logs"

APP_NAME="SpaceJudge"
DERIVED="$WORK_DIR/DerivedData"
BUILT_APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
WORK_APP="$WORK_DIR/staging/$APP_NAME.app"

sj_log "building universal Release bundle"
if ! sj_xcodebuild \
    -project "$REPO_DIR/App/SpaceJudge.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build >"$LOG_DIR/xcodebuild-Release.log" 2>&1; then
    tail -40 "$LOG_DIR/xcodebuild-Release.log" >&2 || true
    sj_die "universal Release build failed; see $LOG_DIR/xcodebuild-Release.log"
fi
[ -d "$BUILT_APP" ] || sj_die "build succeeded but app bundle is missing: $BUILT_APP"

sj_mkdirs "$WORK_DIR/staging"
ditto "$BUILT_APP" "$WORK_APP"

if [ "$WITH_CLI" -eq 1 ]; then
    sj_log "building universal read-only CLI helper"
    for cli_arch in arm64 x86_64; do
        cli_scratch="$WORK_DIR/cli-$cli_arch"
        if ! /usr/bin/xcrun swift build --package-path "$REPO_DIR" --scratch-path "$cli_scratch" \
            -c release --arch "$cli_arch" --product spacejudge-agent-cli \
            >"$LOG_DIR/cli-$cli_arch.log" 2>&1; then
            tail -40 "$LOG_DIR/cli-$cli_arch.log" >&2 || true
            sj_die "CLI $cli_arch build failed"
        fi
    done
    sj_mkdirs "$WORK_APP/Contents/Helpers"
    CLI_HELPER="$WORK_APP/Contents/Helpers/spacejudge-agent-cli"
    /usr/bin/lipo -create "$WORK_DIR/cli-arm64/arm64-apple-macosx/release/spacejudge-agent-cli" \
        "$WORK_DIR/cli-x86_64/x86_64-apple-macosx/release/spacejudge-agent-cli" -output "$CLI_HELPER"
    chmod 755 "$CLI_HELPER"
    sj_codesign --force --options runtime --timestamp=none --sign - "$CLI_HELPER" \
        >"$LOG_DIR/codesign-cli.log" 2>&1 || sj_die "CLI signing failed"
fi

sj_log "validating version consistency"
sj_check_version_consistency "$REPO_DIR" "$WORK_APP"

if [ "$EXPERIMENTAL" -eq 1 ]; then
    # Stamp only the fresh staging bundle, before signing. Never relabel an
    # existing local candidate or modify the installed application.
    /usr/libexec/PlistBuddy -c 'Add :SpaceJudgeReleaseChannel string experimental' "$WORK_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SpaceJudgeSourceCommit string $GIT_COMMIT" "$WORK_APP/Contents/Info.plist"
    cp "$REPO_DIR/scripts/release/TESTING-README.txt" "$WORK_APP/Contents/Resources/TESTING-README.txt"
    cp "$REPO_DIR/LICENSE" "$WORK_APP/Contents/Resources/LICENSE"
    cp "$REPO_DIR/scripts/release/TESTING-README.txt" "$WORK_DIR/staging/TESTING-README.txt"
fi

sj_log "applying ad-hoc Hardened Runtime signature"
if ! sj_codesign --force --options runtime --timestamp=none --sign - "$WORK_APP" >"$LOG_DIR/codesign-adhoc.log" 2>&1; then
    cat "$LOG_DIR/codesign-adhoc.log" >&2 || true
    sj_die "ad-hoc signing failed"
fi

sj_log "verifying signature, architecture and entitlements"
sj_require_strict_verify "$WORK_APP"
sj_codesign --verify --deep --strict --verbose=2 "$WORK_APP" >>"$LOG_DIR/codesign-adhoc.log" 2>&1 \
    || sj_die "deep strict verification failed"
sj_require_runtime_flag "$WORK_APP"
sj_require_no_entitlements "$WORK_APP"
ARCHS="$(sj_require_universal "$WORK_APP" "$SJ_EXECUTABLE_NAME")"
sj_check_macho_inventory "$WORK_APP" "$SJ_EXECUTABLE_NAME" >/dev/null

[ -f "$WORK_APP/Contents/Resources/PrivacyInfo.xcprivacy" ] || sj_die "PrivacyInfo.xcprivacy missing from bundle"
[ -f "$WORK_APP/Contents/Resources/AppIcon.icns" ] || sj_die "AppIcon.icns missing from bundle"
[ -d "$WORK_APP/Contents/Resources/en.lproj" ] || sj_die "en.lproj missing from bundle"
[ -d "$WORK_APP/Contents/Resources/zh-Hans.lproj" ] || sj_die "zh-Hans.lproj missing from bundle"

sj_log "building local DMG"
BASE="SpaceJudge-${SJ_VERSION}-${SJ_BUILD}-universal-LOCAL-ADHOC-NOT-FOR-DISTRIBUTION"
VERIFY_MODE="local"
VOLUME_NAME="$APP_NAME"
if [ "$EXPERIMENTAL" -eq 1 ]; then
    BASE="SpaceJudge-${SJ_VERSION}-${SJ_BUILD}-universal-EXPERIMENTAL-ADHOC-NOT-NOTARIZED"
    VERIFY_MODE="experimental"
    VOLUME_NAME="SpaceJudge TEST ONLY"
    [ "$(sj_git_ready "$REPO_DIR")" = "$GIT_COMMIT" ] || sj_die "source changed during experimental build"
fi
DMG="$OUTPUT_DIR/$BASE.dmg"
ln -s /Applications "$WORK_DIR/staging/Applications"
sj_create_dmg "$WORK_DIR/staging" "$DMG" "$VOLUME_NAME"

sj_log "inspecting mounted DMG layout"
MOUNT_POINT="$WORK_DIR/mount"
sj_attach_dmg "$DMG" "$MOUNT_POINT" >/dev/null
sj_check_dmg_layout "$MOUNT_POINT" "$APP_NAME.app" "$VERIFY_MODE"
sj_require_strict_verify "$MOUNT_POINT/$APP_NAME.app"
sj_require_runtime_flag "$MOUNT_POINT/$APP_NAME.app"
sj_detach_dmg_strict "$MOUNT_POINT"
MOUNT_POINT=""

sj_log "writing checksum and manifest"
SHA256="$(sj_sha256 "$DMG")"
printf '%s  %s\n' "$SHA256" "$(basename "$DMG")" > "$DMG.sha256"

MANIFEST="$OUTPUT_DIR/$BASE.json"
sj_manifest_open "$MANIFEST"
sj_manifest_add_string product "SpaceJudge"
sj_manifest_add_string version "$SJ_VERSION"
sj_manifest_add_string build "$SJ_BUILD"
sj_manifest_add_string bundleID "$SJ_BUNDLE_ID"
sj_manifest_add_string minimumSystemVersion "$SJ_MIN_OS"
sj_manifest_add_string architectures "$ARCHS"
if [ "$EXPERIMENTAL" -eq 1 ]; then
    sj_manifest_add_string kind "experimental-adhoc"
    sj_manifest_add_string audience "opt-in-testers"
    sj_manifest_add_string gitCommit "$GIT_COMMIT"
    sj_manifest_add_string testingNoticeSHA256 "$(sj_sha256 "$WORK_DIR/staging/TESTING-README.txt")"
else
    sj_manifest_add_string kind "local-adhoc"
fi
sj_manifest_add_bool distributionReady "false"
sj_manifest_add_string signingIdentity "ad-hoc"
sj_manifest_add_string notarizationStatus "not-submitted"
sj_manifest_add_string gitState "$(sj_git_state "$REPO_DIR")"
sj_manifest_add_string sha256 "$SHA256"
sj_manifest_add_string generatedAt "$(sj_now_iso8601)"
sj_manifest_add_string tool "local-candidate.sh"
if [ "$WITH_CLI" -eq 1 ]; then
    sj_manifest_add_string bundledCLI "Contents/Helpers/spacejudge-agent-cli"
    sj_manifest_add_string bundledCLISHA256 "$(sj_sha256 "$CLI_HELPER")"
fi
sj_manifest_close
plutil -p "$MANIFEST" >/dev/null || sj_die "generated manifest is not valid"

cp "$LOG_DIR"/*.log "$OUTPUT_DIR/logs/" 2>/dev/null || true
sj_secure_files_no_group_write "$OUTPUT_DIR/logs"

sj_log "local candidate complete"
if [ "$EXPERIMENTAL" -eq 1 ]; then
    sj_warn "OPT-IN TESTING ONLY: not notarized; default Gatekeeper acceptance is NOT claimed"
fi
cat >&2 <<SUMMARY
output-dir:  $OUTPUT_DIR
dmg:         $DMG
sha256:      $SHA256
manifest:    $MANIFEST
architectures: $ARCHS
distributionReady: false
SUMMARY
