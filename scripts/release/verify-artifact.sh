#!/bin/bash
# SpaceJudge artifact verifier.
#
# Mounts a DMG read-only and re-checks layout, signature, Hardened Runtime,
# architectures, entitlements, version consistency and privacy/icon resources.
# It also verifies that the DMG, its `.sha256` sidecar and the manifest all
# describe the same bytes and bundle before trusting either. For official
# builds it additionally checks stapling and Gatekeeper.
#
# This path refuses every SJ_*_BIN test override.
#
# Usage:
#   scripts/release/verify-artifact.sh --dmg <path> --manifest <path> \
#       [--mode local|release] [--repo <path>] [--app-name SpaceJudge]

set -euo pipefail

# Pin to the trusted system tool path before any external command or PATH
# lookup, so a caller PATH cannot substitute plutil/ditto/xcrun/notarytool/etc.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
unset CDPATH BASH_ENV ENV 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DMG=""
MODE="local"
MANIFEST=""
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_NAME="SpaceJudge"

usage() {
    cat <<'USAGE'
Usage: verify-artifact.sh --dmg <path> --manifest <path> [--mode local|release]
                          [--repo <path>] [--app-name SpaceJudge]
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dmg) [ "$#" -ge 2 ] || sj_die "--dmg requires a value"; DMG="$2"; shift 2 ;;
        --mode) [ "$#" -ge 2 ] || sj_die "--mode requires a value"; MODE="$2"; shift 2 ;;
        --manifest) [ "$#" -ge 2 ] || sj_die "--manifest requires a value"; MANIFEST="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || sj_die "--repo requires a value"; REPO_DIR="$2"; shift 2 ;;
        --app-name) [ "$#" -ge 2 ] || sj_die "--app-name requires a value"; APP_NAME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) sj_die "unknown argument: $1" ;;
    esac
done

[ -n "$DMG" ] || { usage >&2; sj_die "--dmg is required"; }
[ -n "$MANIFEST" ] || { usage >&2; sj_die "--manifest is required"; }
case "$MODE" in local|release) : ;; *) sj_die "--mode must be local or release" ;; esac
sj_forbid_tool_overrides
sj_require_absolute "dmg" "$DMG"
[ -f "$DMG" ] || sj_die "DMG not found: $DMG"
sj_require_cmd hdiutil
sj_require_cmd codesign
sj_require_cmd lipo
sj_require_cmd shasum

MOUNT_POINT=""
cleanup() {
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        sj_detach_dmg "$MOUNT_POINT"
    fi
    sj_cleanup_temp
}
trap cleanup EXIT

# Bind DMG bytes <-> checksum sidecar <-> manifest before anything else.
ACTUAL_SHA="$(sj_verify_checksum_sidecar "$DMG")"
sj_log "checksum verified: $ACTUAL_SHA"

sj_make_temp_dir spacejudge-verify
MOUNT_POINT="$SJ_TEMP_DIR/mount"
sj_attach_dmg "$DMG" "$MOUNT_POINT" >/dev/null
sj_log "mounted $DMG at $MOUNT_POINT"

sj_check_dmg_layout "$MOUNT_POINT" "$APP_NAME.app"
APP="$MOUNT_POINT/$APP_NAME.app"
[ -d "$APP" ] || sj_die "app bundle missing after mount"

sj_require_strict_verify "$APP"
sj_require_runtime_flag "$APP"
sj_require_no_entitlements "$APP"
EXECUTABLE="$(sj_bundle_value "$APP" CFBundleExecutable)"
[ -n "$EXECUTABLE" ] || sj_die "app bundle has no CFBundleExecutable"
ARCHS="$(sj_require_universal "$APP" "$EXECUTABLE")"
sj_check_macho_inventory "$APP" "$EXECUTABLE" >/dev/null

sj_bind_manifest "$MANIFEST" "$APP" "$MODE" "$ACTUAL_SHA" "$ARCHS"
sj_log "manifest bound to DMG and bundle"

if [ -d "$REPO_DIR/App/SpaceJudge.xcodeproj" ]; then
    sj_check_version_consistency "$REPO_DIR" "$APP"
fi

[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ] || sj_die "PrivacyInfo.xcprivacy missing"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || sj_die "AppIcon.icns missing"
[ -d "$APP/Contents/Resources/en.lproj" ] || sj_die "en.lproj missing"
[ -d "$APP/Contents/Resources/zh-Hans.lproj" ] || sj_die "zh-Hans.lproj missing"

if [ "$MODE" = "release" ]; then
    sj_require_stapled "$DMG"
    sj_require_strict_verify "$DMG"
    sj_require_gatekeeper open "$DMG"
    sj_require_gatekeeper execute "$APP"
fi

sj_detach_dmg_strict "$MOUNT_POINT"
MOUNT_POINT=""

sj_log "artifact verification passed (mode=$MODE, architectures=$ARCHS)"
