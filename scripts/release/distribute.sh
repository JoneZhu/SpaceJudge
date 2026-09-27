#!/bin/bash
# SpaceJudge official Developer ID distribution pipeline (fail-closed).
#
# Requires an explicit --release opt-in, a reachable clean git HEAD, a
# Developer ID Application identity and a notarytool Keychain profile. It
# builds universal2, signs with secure timestamp + Hardened Runtime, creates
# and signs the DMG, submits for notarization, staples, assesses Gatekeeper and
# only then writes distributionReady=true.
#
# This path refuses every SJ_*_BIN test override so a stub can never forge an
# approved release. Only system/Xcode tools are used.
#
# Usage:
#   scripts/release/distribute.sh --release \
#       --output-dir <absolute-dir> \
#       --identity "<label-or-sha1>" \
#       --keychain-profile <profile> \
#       [--repo <path>] [--preflight-only]

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
IDENTITY=""
KEYCHAIN_PROFILE=""
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RELEASE=0
PREFLIGHT_ONLY=0

usage() {
    cat <<'USAGE'
Usage: distribute.sh --release --output-dir <absolute-dir> \
         --identity <label-or-sha1> --keychain-profile <profile> \
         [--repo <path>] [--preflight-only]

  --release           Explicit opt-in required for the official pipeline.
  --output-dir        New/empty absolute directory for final artifacts.
  --identity          Developer ID Application label or SHA-1.
  --keychain-profile  notarytool Keychain profile name (no passwords here).
  --preflight-only    Run all side-effect-free gates and exit.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) RELEASE=1; shift ;;
        --preflight-only) PREFLIGHT_ONLY=1; shift ;;
        --output-dir) [ "$#" -ge 2 ] || sj_die "--output-dir requires a value"; OUTPUT_DIR="$2"; shift 2 ;;
        --identity) [ "$#" -ge 2 ] || sj_die "--identity requires a value"; IDENTITY="$2"; shift 2 ;;
        --keychain-profile) [ "$#" -ge 2 ] || sj_die "--keychain-profile requires a value"; KEYCHAIN_PROFILE="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || sj_die "--repo requires a value"; REPO_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) sj_die "unknown argument: $1" ;;
    esac
done

[ -n "$OUTPUT_DIR" ] || { usage >&2; sj_die "--output-dir is required"; }
[ -n "$KEYCHAIN_PROFILE" ] || { usage >&2; sj_die "--keychain-profile is required"; }
[ "$RELEASE" -eq 1 ] || sj_die "official distribution requires the explicit --release flag"

# No test environment switch may reach the official path.
sj_forbid_tool_overrides

sj_require_cmd xcodebuild
sj_require_cmd codesign
sj_require_cmd hdiutil
sj_require_cmd lipo
sj_require_cmd shasum
sj_require_cmd stapler
sj_require_cmd spctl
sj_require_absolute "output directory" "$OUTPUT_DIR"
sj_assert_new_output_dir "$OUTPUT_DIR"
[ -d "$REPO_DIR/App/SpaceJudge.xcodeproj" ] || sj_die "Xcode project not found under: $REPO_DIR"
sj_validate_source_metadata "$REPO_DIR"

if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
    set +e
    blockers="$(sj_preflight_release_blockers "$REPO_DIR" "$IDENTITY")"
    rc=$?
    set -e
    printf '%s\n' "$blockers" >&2
    if [ "$rc" -ne 0 ]; then
        sj_die "release preflight failed; this machine is not ready for Developer ID distribution"
    fi
    # Local gates passed; only now is a read-only Apple authentication check
    # attempted. This never submits anything.
    sj_check_notary_profile "$KEYCHAIN_PROFILE"
    sj_log "release preflight passed (including read-only notary profile check)"
    exit 0
fi

MOUNT_POINT=""
cleanup() {
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        sj_detach_dmg "$MOUNT_POINT"
    fi
    sj_cleanup_temp
}
trap cleanup EXIT

COMMIT="$(sj_git_ready "$REPO_DIR")"
sj_log "release commit: $COMMIT"

# Direct call: sets SJ_SIGNING_TEAM_ID in this shell.
sj_require_developer_id "$IDENTITY" >/dev/null
sj_log "signing with Developer ID Application (team $SJ_SIGNING_TEAM_ID)"
# Local gates passed; validate the notary profile read-only before building.
sj_check_notary_profile "$KEYCHAIN_PROFILE"
sj_log "notary Keychain profile is usable"

sj_make_temp_dir spacejudge-distribute
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

sj_log "building universal Release bundle from $COMMIT"
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
    sj_die "universal Release build failed"
fi
[ -d "$BUILT_APP" ] || sj_die "build succeeded but app bundle is missing"

sj_mkdirs "$WORK_DIR/staging"
ditto "$BUILT_APP" "$WORK_APP"
sj_check_version_consistency "$REPO_DIR" "$WORK_APP"

sj_log "checking Mach-O inventory"
sj_check_macho_inventory "$WORK_APP" "$SJ_EXECUTABLE_NAME" >/dev/null

sj_log "signing app with Developer ID Application"
if ! sj_codesign --force --options runtime --timestamp --sign "$IDENTITY" "$WORK_APP" >"$LOG_DIR/codesign-app.log" 2>&1; then
    cat "$LOG_DIR/codesign-app.log" >&2 || true
    sj_die "app signing failed"
fi
sj_require_strict_verify "$WORK_APP"
sj_require_runtime_flag "$WORK_APP"
sj_require_no_entitlements "$WORK_APP"
ARCHS="$(sj_require_universal "$WORK_APP" "$SJ_EXECUTABLE_NAME")"

[ -f "$WORK_APP/Contents/Resources/PrivacyInfo.xcprivacy" ] || sj_die "PrivacyInfo.xcprivacy missing from bundle"
[ -f "$WORK_APP/Contents/Resources/AppIcon.icns" ] || sj_die "AppIcon.icns missing from bundle"

sj_log "creating and signing DMG"
BASE="$APP_NAME-${SJ_VERSION}-${SJ_BUILD}-universal"
DMG="$OUTPUT_DIR/$BASE.dmg"
ln -s /Applications "$WORK_DIR/staging/Applications"
sj_create_dmg "$WORK_DIR/staging" "$DMG" "$APP_NAME"
if ! sj_codesign --force --timestamp --sign "$IDENTITY" "$DMG" >"$LOG_DIR/codesign-dmg.log" 2>&1; then
    cat "$LOG_DIR/codesign-dmg.log" >&2 || true
    sj_die "DMG signing failed"
fi
sj_require_strict_verify "$DMG"

# Re-confirm provenance immediately before any external upload: the build must
# still correspond to the same clean commit.
CURRENT_COMMIT="$(sj_git_ready "$REPO_DIR")"
[ "$CURRENT_COMMIT" = "$COMMIT" ] \
    || sj_die "working tree changed after preflight ($COMMIT -> $CURRENT_COMMIT); aborting before notarization"

sj_log "submitting DMG for notarization"
NOTARY_JSON="$OUTPUT_DIR/${BASE}-notarization.json"
sj_assert_absent "$NOTARY_JSON"
if ! sj_notarytool submit "$DMG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait --output-format json >"$NOTARY_JSON" 2>"$LOG_DIR/notarytool-submit.log"; then
    sj_warn "notarytool submit returned non-zero; keeping result and log"
fi
SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_JSON" 2>/dev/null || true)"
NOTARY_STATUS="$(sj_require_notary_accepted "$NOTARY_JSON")"
[ -n "$SUBMISSION_ID" ] || sj_die "notarization reported $NOTARY_STATUS without a submission ID"
sj_log "notarization status: $NOTARY_STATUS (submission $SUBMISSION_ID)"

# A successful submission is not enough: the downloaded log must also be valid,
# Accepted and free of error issues before a ready manifest is written.
NOTARY_LOG="$OUTPUT_DIR/${BASE}-notarization-log.json"
sj_assert_absent "$NOTARY_LOG"
if ! sj_notarytool log "$SUBMISSION_ID" --keychain-profile "$KEYCHAIN_PROFILE" \
    >"$NOTARY_LOG" 2>"$LOG_DIR/notarytool-log.log"; then
    sj_die "could not download notarization log for submission $SUBMISSION_ID"
fi
sj_require_notary_log_ok "$NOTARY_LOG" >/dev/null
sj_log "notarization log accepted (errors=${SJ_NOTARY_ERROR_COUNT}, warnings=${SJ_NOTARY_WARNING_COUNT})"

sj_log "stapling and validating"
sj_stapler staple "$DMG" || sj_die "stapler staple failed"
sj_require_stapled "$DMG"
sj_require_strict_verify "$DMG"

sj_log "Gatekeeper assessment"
sj_require_gatekeeper open "$DMG"
MOUNT_POINT="$WORK_DIR/mount"
sj_attach_dmg "$DMG" "$MOUNT_POINT" >/dev/null
sj_check_dmg_layout "$MOUNT_POINT" "$APP_NAME.app"
sj_require_gatekeeper execute "$MOUNT_POINT/$APP_NAME.app"
sj_require_strict_verify "$MOUNT_POINT/$APP_NAME.app"
sj_detach_dmg_strict "$MOUNT_POINT"
MOUNT_POINT=""

SHA256="$(sj_sha256 "$DMG")"
printf '%s  %s\n' "$SHA256" "$(basename "$DMG")" > "$DMG.sha256"

MANIFEST="$OUTPUT_DIR/${BASE}-release.json"
sj_manifest_open "$MANIFEST"
sj_manifest_add_string product "SpaceJudge"
sj_manifest_add_string version "$SJ_VERSION"
sj_manifest_add_string build "$SJ_BUILD"
sj_manifest_add_string bundleID "$SJ_BUNDLE_ID"
sj_manifest_add_string minimumSystemVersion "$SJ_MIN_OS"
sj_manifest_add_string architectures "$ARCHS"
sj_manifest_add_string kind "developer-id"
sj_manifest_add_bool distributionReady "true"
sj_manifest_add_string signingIdentityType "Developer ID Application"
sj_manifest_add_string teamID "$SJ_SIGNING_TEAM_ID"
sj_manifest_add_string notarizationStatus "$NOTARY_STATUS"
sj_manifest_add_string notarizationSubmissionID "$SUBMISSION_ID"
sj_manifest_add_string notarizationLogStatus "Accepted"
sj_manifest_add_number notarizationErrorCount "${SJ_NOTARY_ERROR_COUNT:-0}"
sj_manifest_add_number notarizationWarningCount "${SJ_NOTARY_WARNING_COUNT:-0}"
sj_manifest_add_string gitCommit "$COMMIT"
sj_manifest_add_string sha256 "$SHA256"
sj_manifest_add_string generatedAt "$(sj_now_iso8601)"
sj_manifest_add_string tool "distribute.sh"
sj_manifest_close
plutil -p "$MANIFEST" >/dev/null || sj_die "generated manifest is not valid"

cp "$LOG_DIR"/*.log "$OUTPUT_DIR/logs/" 2>/dev/null || true
sj_secure_files_no_group_write "$OUTPUT_DIR/logs"

sj_log "official distribution artifacts complete"
cat >&2 <<SUMMARY
output-dir:  $OUTPUT_DIR
dmg:         $DMG
sha256:      $SHA256
manifest:    $MANIFEST
commit:      $COMMIT
distributionReady: true
notarizationWarnings: ${SJ_NOTARY_WARNING_COUNT:-0}
SUMMARY
