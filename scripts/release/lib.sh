#!/bin/bash
# SpaceJudge release scripting library.
#
# Shared, side-effect-free helpers for the two release pipelines:
#
#   * local-candidate.sh  — credential-free universal hardened ad-hoc DMG
#   * distribute.sh       — Developer ID + notarized, fail-closed release
#
# Conventions:
#   * Callers enable `set -euo pipefail` themselves.
#   * No dynamic command evaluation. Every expansion is quoted.
#   * External tools are resolved through `sj_<tool>` wrappers so unit tests can
#     substitute deterministic stubs. The official pipeline explicitly rejects
#     those overrides (`sj_forbid_tool_overrides`), so no environment switch can
#     make a real `--release` run accept a stub.
#   * Functions never print private keys, passwords or Keychain item contents.
#   * Helpers with side effects (temp dirs) set globals in the caller's shell;
#     they are never invoked through command substitution.
#   * Destructive helpers only remove paths proven to be task temp directories.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

sj_log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
sj_warn() { printf '[%s] WARNING: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
sj_die() { printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Tool wrappers (overridable for deterministic unit self-tests only)
# ---------------------------------------------------------------------------

# Pins the process to the trusted system tool path. User-facing entry scripts
# call this (and also set PATH before sourcing this library) so a caller PATH
# cannot substitute release-critical tools such as plutil, ditto, xcrun,
# notarytool, security or codesign. Helper/self-test scope may still use the
# SJ_*_BIN overrides, but the official entries forbid them.
sj_lock_system_path() {
    PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    export PATH
    unset CDPATH BASH_ENV ENV 2>/dev/null || true
}

sj_xcodebuild() { "${SJ_XCODEBUILD_BIN:-/usr/bin/xcodebuild}" "$@"; }
sj_codesign() { "${SJ_CODESIGN_BIN:-/usr/bin/codesign}" "$@"; }
sj_hdiutil() { "${SJ_HDIUTIL_BIN:-/usr/bin/hdiutil}" "$@"; }
sj_lipo() { "${SJ_LIPO_BIN:-/usr/bin/lipo}" "$@"; }
sj_security() { "${SJ_SECURITY_BIN:-/usr/bin/security}" "$@"; }
sj_stapler() { "${SJ_STAPLER_BIN:-/usr/bin/stapler}" "$@"; }
sj_spctl() { "${SJ_SPCTL_BIN:-/usr/sbin/spctl}" "$@"; }
sj_shasum() { "${SJ_SHASUM_BIN:-/usr/bin/shasum}" "$@"; }
sj_git() { "${SJ_GIT_BIN:-/usr/bin/git}" "$@"; }

# notarytool is an Xcode tool. The official path always uses the fixed
# /usr/bin/xcrun launcher; helpers may substitute SJ_NOTARYTOOL_BIN, but the
# official entries reject that override before doing anything.
sj_notarytool() {
    if [ -n "${SJ_NOTARYTOOL_BIN:-}" ]; then
        "$SJ_NOTARYTOOL_BIN" "$@"
    else
        /usr/bin/xcrun notarytool "$@"
    fi
}

sj_plistbuddy() { "${SJ_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}" "$@"; }

# Every override the unit self-tests rely on. The official paths call
# sj_forbid_tool_overrides so an approved-looking run cannot be forged.
SJ_TOOL_OVERRIDE_VARS="SJ_XCODEBUILD_BIN SJ_CODESIGN_BIN SJ_HDIUTIL_BIN SJ_LIPO_BIN SJ_SECURITY_BIN SJ_STAPLER_BIN SJ_SPCTL_BIN SJ_SHASUM_BIN SJ_GIT_BIN SJ_NOTARYTOOL_BIN SJ_PLISTBUDDY_BIN"

sj_forbid_tool_overrides() {
    local name value
    for name in $SJ_TOOL_OVERRIDE_VARS; do
        value="${!name:-}"
        if [ -n "$value" ]; then
            sj_die "refusing test tool override '$name' in the official release path"
        fi
    done
}

sj_require_cmd() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        sj_die "required command not found: $name"
    fi
}

sj_require_absolute() {
    local label="$1" path="$2"
    case "$path" in
        /*) : ;;
        *) sj_die "$label must be an absolute path: $path" ;;
    esac
}

# ---------------------------------------------------------------------------
# Safe temporary workspace lifecycle
# ---------------------------------------------------------------------------

SJ_TEMP_DIR=""

# Creates a task-owned temp directory under ${TMPDIR:-/tmp}. Sets SJ_TEMP_DIR in
# the *caller's* shell (no command substitution, no subshell) and prints nothing.
sj_make_temp_dir() {
    local prefix="${1:-spacejudge-release}"
    local base="${TMPDIR:-/tmp}"
    SJ_TEMP_DIR="$(mktemp -d "$base/${prefix}.XXXXXX")" || sj_die "could not create temp directory"
    [ -d "$SJ_TEMP_DIR" ] || sj_die "temp directory was not created"
    chmod 700 "$SJ_TEMP_DIR" 2>/dev/null || true
}

# Removes SJ_TEMP_DIR only when it is a real directory whose basename matches a
# task temp prefix and whose parent is a known temp root. Refuses otherwise.
sj_cleanup_temp() {
    [ -n "${SJ_TEMP_DIR:-}" ] || return 0
    [ -d "$SJ_TEMP_DIR" ] || return 0
    local base parent
    base="$(basename "$SJ_TEMP_DIR")"
    parent="$(dirname "$SJ_TEMP_DIR")"
    case "$parent" in
        /tmp|/var/folders/*|/private/var/folders/*|/var/tmp) : ;;
        "${TMPDIR%/}") : ;;
        *)
            sj_warn "refusing to remove temp dir outside known temp roots: $SJ_TEMP_DIR"
            return 0
            ;;
    esac
    case "$base" in
        spacejudge-release.*|spacejudge-localcandidate.*|spacejudge-distribute.*|spacejudge-verify.*|spacejudge-test.*) : ;;
        *)
            sj_warn "refusing to remove temp dir with unexpected name: $SJ_TEMP_DIR"
            return 0
            ;;
    esac
    rm -r -- "$SJ_TEMP_DIR"
    SJ_TEMP_DIR=""
}

# ---------------------------------------------------------------------------
# Filesystem / output safety
# ---------------------------------------------------------------------------

sj_assert_new_output_dir() {
    local dir="$1"
    sj_require_absolute "output directory" "$dir"
    if [ -e "$dir" ]; then
        if [ ! -d "$dir" ]; then
            sj_die "output path exists and is not a directory: $dir"
        fi
        local entries
        entries="$(ls -A "$dir" 2>/dev/null || true)"
        if [ -n "$entries" ]; then
            sj_die "output directory already contains files; refusing to overwrite: $dir"
        fi
    fi
}

sj_mkdirs() {
    mkdir -p -- "$1" || sj_die "could not create directory: $1"
}

sj_assert_absent() {
    local path="$1"
    if [ -e "$path" ]; then
        sj_die "refusing to overwrite existing path: $path"
    fi
}

sj_secure_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    chmod 700 "$dir" 2>/dev/null || sj_die "could not restrict directory permissions: $dir"
}

# Removes group/other write permission from files under a directory.
sj_secure_files_no_group_write() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    find "$dir" -type f -exec chmod go-w {} + 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Metadata syntax validation (before any path join)
# ---------------------------------------------------------------------------

sj_require_safe_version() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || sj_die "unsafe marketing version: '$value'"
}

sj_require_safe_build() {
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || sj_die "unsafe build number: '$value'"
}

sj_require_safe_bundle_id() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || sj_die "unsafe bundle identifier: '$value'"
    case "$value" in
        *..*) sj_die "unsafe bundle identifier contains '..': '$value'" ;;
    esac
}

sj_require_safe_min_os() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || sj_die "unsafe minimum system version: '$value'"
}

sj_pbx_setting() {
    local pbx="$1" key="$2"
    grep -m1 "^[[:space:]]*${key} = " "$pbx" 2>/dev/null \
        | sed -E "s/^[[:space:]]*${key} = (.*);.*/\1/" \
        | tr -d '"' \
        | tr -d ' '
}

sj_bundle_value() {
    local app="$1" key="$2"
    sj_plistbuddy -c "Print :$key" "$app/Contents/Info.plist" 2>/dev/null
}

# Validates source Info.plist + build settings metadata syntax before a build.
sj_validate_source_metadata() {
    local repo="$1"
    local plist="$repo/App/SpaceJudgeApp/Info.plist"
    local pbx="$repo/App/SpaceJudge.xcodeproj/project.pbxproj"
    [ -f "$plist" ] || sj_die "source Info.plist missing: $plist"
    [ -f "$pbx" ] || sj_die "Xcode project missing: $pbx"
    sj_require_safe_version "$(sj_plistbuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
    sj_require_safe_build "$(sj_plistbuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)"
    sj_require_safe_version "$(sj_pbx_setting "$pbx" MARKETING_VERSION)"
    sj_require_safe_build "$(sj_pbx_setting "$pbx" CURRENT_PROJECT_VERSION)"
    sj_require_safe_bundle_id "$(sj_pbx_setting "$pbx" PRODUCT_BUNDLE_IDENTIFIER)"
    sj_require_safe_min_os "$(sj_pbx_setting "$pbx" MACOSX_DEPLOYMENT_TARGET)"
}

SJ_VERSION=""
SJ_BUILD=""
SJ_BUNDLE_ID=""
SJ_MIN_OS=""
SJ_EXECUTABLE_NAME=""

check_pair() {
    local label="$1" expected="$2"
    shift 2
    for actual in "$@"; do
        if [ "$actual" != "$expected" ]; then
            sj_die "$label mismatch: expected '$expected', found '$actual'"
        fi
    done
}

# Validates source Info.plist, Xcode build settings and the built bundle agree,
# and that every metadata value is path-safe. Sets SJ_VERSION/SJ_BUILD/
# SJ_BUNDLE_ID/SJ_MIN_OS/SJ_EXECUTABLE_NAME.
sj_check_version_consistency() {
    local repo="$1" app="$2"
    local plist="$repo/App/SpaceJudgeApp/Info.plist"
    local pbx="$repo/App/SpaceJudge.xcodeproj/project.pbxproj"
    [ -f "$plist" ] || sj_die "source Info.plist missing: $plist"
    [ -f "$pbx" ] || sj_die "Xcode project missing: $pbx"

    local src_version src_build pbx_version pbx_build pbx_bundle pbx_min
    local bundle_version bundle_build bundle_id bundle_min
    src_version="$(sj_plistbuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
    src_build="$(sj_plistbuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)"
    pbx_version="$(sj_pbx_setting "$pbx" MARKETING_VERSION)"
    pbx_build="$(sj_pbx_setting "$pbx" CURRENT_PROJECT_VERSION)"
    pbx_bundle="$(sj_pbx_setting "$pbx" PRODUCT_BUNDLE_IDENTIFIER)"
    pbx_min="$(sj_pbx_setting "$pbx" MACOSX_DEPLOYMENT_TARGET)"

    bundle_version="$(sj_bundle_value "$app" CFBundleShortVersionString)"
    bundle_build="$(sj_bundle_value "$app" CFBundleVersion)"
    bundle_id="$(sj_bundle_value "$app" CFBundleIdentifier)"
    bundle_min="$(sj_bundle_value "$app" LSMinimumSystemVersion)"

    sj_require_safe_version "$src_version"
    sj_require_safe_version "$pbx_version"
    sj_require_safe_version "$bundle_version"
    sj_require_safe_build "$src_build"
    sj_require_safe_build "$pbx_build"
    sj_require_safe_build "$bundle_build"
    sj_require_safe_bundle_id "$pbx_bundle"
    sj_require_safe_bundle_id "$bundle_id"
    sj_require_safe_min_os "$pbx_min"
    sj_require_safe_min_os "$bundle_min"

    check_pair "version" "$src_version" "$pbx_version" "$bundle_version"
    check_pair "build" "$src_build" "$pbx_build" "$bundle_build"
    check_pair "bundle id" "$pbx_bundle" "$bundle_id"
    check_pair "minimum system" "$pbx_min" "$bundle_min"

    local executable
    executable="$(sj_bundle_value "$app" CFBundleExecutable)"
    [ -n "$executable" ] || sj_die "built bundle has no CFBundleExecutable"

    SJ_VERSION="$src_version"
    SJ_BUILD="$src_build"
    SJ_BUNDLE_ID="$pbx_bundle"
    SJ_MIN_OS="$pbx_min"
    SJ_EXECUTABLE_NAME="$executable"
}

# ---------------------------------------------------------------------------
# Git provenance
# ---------------------------------------------------------------------------

sj_git_ready() {
    local repo="$1"
    sj_require_absolute "repository" "$repo"
    [ -d "$repo/.git" ] || sj_die "not a git work tree: $repo"
    local sha
    if ! sha="$(sj_git -C "$repo" rev-parse --verify HEAD 2>/dev/null)"; then
        sj_die "release requires a git HEAD, but the repository has no commit"
    fi
    [ -n "$sha" ] || sj_die "release requires a git HEAD commit"
    if [ -n "$(sj_git -C "$repo" status --porcelain)" ]; then
        sj_die "release requires a clean working tree; commit or discard changes first"
    fi
    printf '%s\n' "$sha"
}

sj_git_state() {
    local repo="$1"
    if ! sj_git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
        printf 'no-head\n'
    elif [ -n "$(sj_git -C "$repo" status --porcelain 2>/dev/null)" ]; then
        printf 'dirty\n'
    else
        printf 'clean\n'
    fi
}

# ---------------------------------------------------------------------------
# Signing identities
# ---------------------------------------------------------------------------

sj_identity_list() {
    sj_security find-identity -v -p codesigning 2>/dev/null || true
}

sj_identity_kind() {
    local label="$1"
    case "$label" in
        "Developer ID Application"*) printf 'developer-id-application\n' ;;
        "Apple Distribution"*) printf 'apple-distribution\n' ;;
        "Apple Development"*|"Mac Developer"*|"iPhone Developer"*) printf 'apple-development\n' ;;
        "Developer ID Installer"*) printf 'developer-id-installer\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# Echoes the matching identity line for a SHA-1 or exact label; returns 1 on no
# match or on more than one distinct matching identity (ambiguous).
sj_identity_line() {
    local identity="$1" list line sha label match_sha="" match_line="" ambiguous=0
    list="$(sj_identity_list)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        sha="$(printf '%s\n' "$line" | awk '{print $2}')"
        label="$(printf '%s\n' "$line" | sed -E 's/^[^"]*"([^"]*)"[^"]*$/\1/')"
        if [ "$sha" = "$identity" ] || [ "$label" = "$identity" ] \
            || { [ "${#identity}" -eq 40 ] && [ "${sha:0:${#identity}}" = "$identity" ]; }; then
            if [ -z "$match_sha" ]; then
                match_sha="$sha"
                match_line="$line"
            elif [ "$sha" != "$match_sha" ]; then
                ambiguous=1
            fi
        fi
    done <<< "$list"
    [ "$ambiguous" -eq 0 ] || return 1
    [ -n "$match_sha" ] || return 1
    printf '%s\n' "$match_line"
}

sj_identity_team_id() {
    local line="$1"
    printf '%s\n' "$line" | sed -E 's/.*\(([A-Z0-9]+)\)"[[:space:]]*$/\1/'
}

# Requires an identity whose kind is exactly Developer ID Application and sets
# SJ_SIGNING_TEAM_ID in the caller's shell.
sj_require_developer_id() {
    local identity="$1"
    [ -n "$identity" ] || sj_die "no signing identity supplied"
    local line label kind
    if ! line="$(sj_identity_line "$identity")"; then
        sj_die "signing identity not found or ambiguous in Keychain: $identity"
    fi
    label="$(printf '%s\n' "$line" | sed -E 's/^[^"]*"([^"]*)"[^"]*$/\1/')"
    kind="$(sj_identity_kind "$label")"
    case "$kind" in
        developer-id-application) : ;;
        apple-distribution) sj_die "refusing Apple Distribution identity; station-outside distribution requires Developer ID Application" ;;
        apple-development) sj_die "refusing Apple Development identity; it is not valid for distribution" ;;
        developer-id-installer) sj_die "refusing Developer ID Installer identity; the app must be signed with Developer ID Application" ;;
        *) sj_die "unrecognized signing identity type: $label" ;;
    esac
    SJ_SIGNING_TEAM_ID="$(sj_identity_team_id "$line")"
    [ -n "$SJ_SIGNING_TEAM_ID" ] || sj_die "could not read team identifier from identity"
    printf '%s\n' "$line"
}

# ---------------------------------------------------------------------------
# Mach-O inventory
# ---------------------------------------------------------------------------

sj_is_macho() {
    local file="$1" magic
    [ -f "$file" ] || return 1
    magic="$(od -An -tx1 -N4 "$file" 2>/dev/null | tr -d ' \n')"
    case "$magic" in
        feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|bebafeca|bfbafeca|cafebabf) return 0 ;;
        *) return 1 ;;
    esac
}

sj_macho_paths() {
    local root="$1" file rel
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if sj_is_macho "$file"; then
            rel="${file#"$root"/}"
            printf '%s\n' "$rel"
        fi
    done < <(find "$root" -type f -print 2>/dev/null)
}

sj_check_macho_inventory() {
    local app="$1" executable="$2"
    local allowed="Contents/MacOS/$executable"
    local helper="Contents/Helpers/spacejudge-agent-cli"
    local found unexpected=""
    while IFS= read -r found; do
        [ -n "$found" ] || continue
        if [ "$found" = "$helper" ]; then
            # Fixed signing plan: native helper must already be signed, with
            # both supported architectures and no exception entitlement.
            sj_require_strict_verify "$app/$helper"
            sj_require_runtime_flag "$app/$helper"
            sj_require_no_entitlements "$app/$helper"
            [ "$(sj_lipo -archs "$app/$helper" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed -E 's/ *$//')" = "arm64 x86_64" ] \
                || sj_die "CLI helper must be universal arm64 x86_64"
        elif [ "$found" != "$allowed" ]; then
            unexpected="${unexpected}${found}"$'\n'
        fi
    done < <(sj_macho_paths "$app")
    if [ -n "$unexpected" ]; then
        sj_warn "unexpected nested Mach-O code in bundle:"
        printf '%s' "$unexpected" >&2
        sj_die "bundle contains code outside the allow-list; add it to the signing plan explicitly instead of using codesign --deep"
    fi
    printf '%s\n' "$allowed"
}

# ---------------------------------------------------------------------------
# Architecture / entitlements / signature verification
# ---------------------------------------------------------------------------

# Sorted unique architecture list of the main executable.
sj_app_architectures() {
    local app="$1" executable="$2"
    sj_lipo -archs "$app/Contents/MacOS/$executable" 2>/dev/null \
        | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed -E 's/ *$//'
}

# Requires exactly `arm64 x86_64` (sorted), rejecting any extra architecture.
sj_require_universal() {
    local archs
    archs="$(sj_app_architectures "$1" "$2")"
    if [ "$archs" != "arm64 x86_64" ]; then
        sj_die "main executable must contain exactly arm64 and x86_64 (found: '${archs:-<none>}')"
    fi
    printf '%s\n' "$archs"
}

sj_signing_flags() {
    local target="$1"
    sj_codesign -d --verbose=4 "$target" 2>&1 >/dev/null || return 1
}

sj_require_runtime_flag() {
    local target="$1" info
    info="$(sj_codesign -d --verbose=4 "$target" 2>&1 || true)"
    case "$info" in
        *flags=*runtime*) : ;;
        *) sj_die "code signature does not have the hardened runtime flag: $target" ;;
    esac
}

sj_require_strict_verify() {
    local target="$1"
    sj_codesign --verify --strict --verbose=2 "$target" \
        || sj_die "codesign --verify --strict failed: $target"
}

sj_dump_entitlements() {
    local target="$1" out="$2"
    if ! sj_codesign -d --entitlements :- "$target" >"$out" 2>/dev/null; then
        : > "$out"
    fi
}

sj_require_no_entitlements() {
    local target="$1" out rendered
    out="$(mktemp "${TMPDIR:-/tmp}/spacejudge-entitlements.XXXXXX")"
    sj_dump_entitlements "$target" "$out"
    if [ ! -s "$out" ]; then
        rm -f "$out"
        return 0
    fi
    rendered="$(plutil -p "$out" 2>/dev/null || true)"
    if printf '%s' "$rendered" | grep -q 'get-task-allow'; then
        rm -f "$out"
        sj_die "effective entitlements contain get-task-allow: $target"
    fi
    if printf '%s' "$rendered" | grep -q '=>'; then
        rm -f "$out"
        sj_die "unexpected entitlement present; distribution entitlements must be empty: $target"
    fi
    rm -f "$out"
}

# ---------------------------------------------------------------------------
# Notarization / stapling / Gatekeeper
# ---------------------------------------------------------------------------

sj_notary_status() {
    local json="$1"
    [ -f "$json" ] || sj_die "notarization result missing: $json"
    local status
    status="$(plutil -extract status raw -o - "$json" 2>/dev/null || true)"
    [ -n "$status" ] || sj_die "notarization result has no status field: $json"
    printf '%s\n' "$status"
}

sj_require_notary_accepted() {
    local json="$1" status
    status="$(sj_notary_status "$json")"
    if [ "$status" != "Accepted" ]; then
        sj_die "notarization status is '$status', not Accepted; keeping artifacts for inspection"
    fi
    printf '%s\n' "$status"
}

# Validates a downloaded notarization log: valid JSON, status Accepted, and no
# error-severity issues. Warning issues are allowed but counted and recorded.
# Sets SJ_NOTARY_WARNING_COUNT and SJ_NOTARY_ERROR_COUNT.
sj_require_notary_log_ok() {
    local log="$1" rendered status
    [ -s "$log" ] || sj_die "notarization log is missing or empty: $log"
    plutil -p "$log" >/dev/null 2>&1 || sj_die "notarization log is not valid JSON: $log"
    status="$(plutil -extract status raw -o - "$log" 2>/dev/null || true)"
    [ "$status" = "Accepted" ] || sj_die "notarization log status is '$status', not Accepted"
    rendered="$(plutil -p "$log" 2>/dev/null || true)"
    SJ_NOTARY_ERROR_COUNT="$(printf '%s\n' "$rendered" | grep -c '"severity" => "error"' || true)"
    SJ_NOTARY_WARNING_COUNT="$(printf '%s\n' "$rendered" | grep -c '"severity" => "warning"' || true)"
    [ "${SJ_NOTARY_ERROR_COUNT:-0}" -eq 0 ] \
        || sj_die "notarization log contains ${SJ_NOTARY_ERROR_COUNT} error issue(s)"
    printf '%s\n' "$status"
}

# Read-only authentication gate. Only ever called after the local Git and
# Developer ID gates pass, so machines without credentials never contact Apple.
sj_check_notary_profile() {
    local profile="$1" out
    [ -n "$profile" ] || sj_die "no notary Keychain profile supplied"
    out="$(mktemp "${TMPDIR:-/tmp}/spacejudge-notary-profile.XXXXXX")"
    if ! sj_notarytool history --keychain-profile "$profile" --output-format json >"$out" 2>/dev/null; then
        rm -f "$out"
        sj_die "notary Keychain profile '$profile' is not usable (notarytool history failed)"
    fi
    if ! plutil -p "$out" >/dev/null 2>&1; then
        rm -f "$out"
        sj_die "notarytool history returned invalid JSON for profile '$profile'"
    fi
    rm -f "$out"
}

sj_require_stapled() {
    local dmg="$1"
    sj_stapler validate "$dmg" || sj_die "stapler validate failed: $dmg"
}

sj_require_gatekeeper() {
    local type="$1" target="$2"
    case "$type" in
        open) sj_spctl --assess --type open --context context:primary-signature -vv "$target" ;;
        execute) sj_spctl --assess --type execute -vv "$target" ;;
        install) sj_spctl --assess --type install -vv "$target" ;;
        *) sj_die "unknown spctl assessment type: $type" ;;
    esac || sj_die "Gatekeeper $type assessment failed: $target"
}

# ---------------------------------------------------------------------------
# Checksums / manifest
# ---------------------------------------------------------------------------

sj_sha256() {
    local file="$1"
    [ -f "$file" ] || sj_die "cannot checksum missing file: $file"
    sj_shasum -a 256 "$file" | awk '{print $1}'
}

# Verifies a `.sha256` sidecar: it must exist, name the same file, and match the
# actual bytes. Echoes the verified hash.
sj_verify_checksum_sidecar() {
    local dmg="$1" sidecar="$1.sha256" line hash name actual
    [ -f "$sidecar" ] || sj_die "checksum sidecar missing: $sidecar"
    line="$(head -1 "$sidecar")"
    hash="$(printf '%s\n' "$line" | awk '{print $1}')"
    name="$(printf '%s\n' "$line" | awk '{print $2}' | sed 's/^\*//')"
    [ -n "$hash" ] && [ -n "$name" ] || sj_die "malformed checksum sidecar: $sidecar"
    [ "$name" = "$(basename "$dmg")" ] || sj_die "checksum sidecar names '$name', not '$(basename "$dmg")'"
    actual="$(sj_sha256 "$dmg")"
    [ "$hash" = "$actual" ] || sj_die "checksum mismatch for $dmg"
    printf '%s\n' "$actual"
}

sj_manifest_value() {
    local manifest="$1" key="$2" value
    [ -f "$manifest" ] || sj_die "manifest missing: $manifest"
    value="$(plutil -extract "$key" raw -o - "$manifest" 2>/dev/null || true)"
    [ -n "$value" ] || sj_die "manifest is missing key '$key': $manifest"
    printf '%s\n' "$value"
}

# Binds a manifest to the DMG hash, the mounted app bundle and the mode.
# mode is `local` or `release`.
sj_bind_manifest() {
    local manifest="$1" app="$2" mode="$3" expected_sha="$4" expected_archs="$5"
    [ -f "$manifest" ] || sj_die "manifest missing: $manifest"
    plutil -p "$manifest" >/dev/null 2>&1 || sj_die "manifest is not valid JSON: $manifest"

    local m_sha m_product m_version m_build m_bundle m_min m_arch
    local b_version b_build b_bundle b_min app_name
    m_sha="$(sj_manifest_value "$manifest" sha256)"
    m_product="$(sj_manifest_value "$manifest" product)"
    m_version="$(sj_manifest_value "$manifest" version)"
    m_build="$(sj_manifest_value "$manifest" build)"
    m_bundle="$(sj_manifest_value "$manifest" bundleID)"
    m_min="$(sj_manifest_value "$manifest" minimumSystemVersion)"
    m_arch="$(sj_manifest_value "$manifest" architectures)"

    b_version="$(sj_bundle_value "$app" CFBundleShortVersionString)"
    b_build="$(sj_bundle_value "$app" CFBundleVersion)"
    b_bundle="$(sj_bundle_value "$app" CFBundleIdentifier)"
    b_min="$(sj_bundle_value "$app" LSMinimumSystemVersion)"
    app_name="$(basename "$app" .app)"

    [ "$m_sha" = "$expected_sha" ] || sj_die "manifest sha256 does not match the DMG"
    [ "$m_product" = "$app_name" ] || sj_die "manifest product '$m_product' does not match app '$app_name'"
    [ "$m_version" = "$b_version" ] || sj_die "manifest version '$m_version' != bundle '$b_version'"
    [ "$m_build" = "$b_build" ] || sj_die "manifest build '$m_build' != bundle '$b_build'"
    [ "$m_bundle" = "$b_bundle" ] || sj_die "manifest bundleID '$m_bundle' != bundle '$b_bundle'"
    [ "$m_min" = "$b_min" ] || sj_die "manifest minimumSystemVersion '$m_min' != bundle '$b_min'"
    [ "$m_arch" = "$expected_archs" ] || sj_die "manifest architectures '$m_arch' != actual '$expected_archs'"

    case "$mode" in
        local)
            [ "$(sj_manifest_value "$manifest" kind)" = "local-adhoc" ] || sj_die "local manifest kind must be local-adhoc"
            [ "$(sj_manifest_value "$manifest" distributionReady)" = "false" ] || sj_die "local manifest must have distributionReady=false"
            [ "$(sj_manifest_value "$manifest" notarizationStatus)" = "not-submitted" ] || sj_die "local manifest notarizationStatus must be not-submitted"
            ;;
        release)
            [ "$(sj_manifest_value "$manifest" kind)" = "developer-id" ] || sj_die "release manifest kind must be developer-id"
            [ "$(sj_manifest_value "$manifest" distributionReady)" = "true" ] || sj_die "release manifest must have distributionReady=true"
            [ "$(sj_manifest_value "$manifest" notarizationStatus)" = "Accepted" ] || sj_die "release manifest notarizationStatus must be Accepted"
            [ -n "$(sj_manifest_value "$manifest" notarizationSubmissionID)" ] || sj_die "release manifest must carry a submission ID"
            [[ "$(sj_manifest_value "$manifest" gitCommit)" =~ ^[0-9a-f]{40}$ ]] || sj_die "release manifest must carry a 40-hex commit"
            [ -n "$(sj_manifest_value "$manifest" teamID)" ] || sj_die "release manifest must carry a team ID"
            ;;
        *) sj_die "unknown manifest mode: $mode" ;;
    esac
}

# ---------------------------------------------------------------------------
# JSON manifest writer
# ---------------------------------------------------------------------------

SJ_MANIFEST_FILE=""
SJ_MANIFEST_FIRST=1

sj_manifest_open() {
    SJ_MANIFEST_FILE="$1"
    sj_assert_absent "$SJ_MANIFEST_FILE"
    printf '{\n' > "$SJ_MANIFEST_FILE"
    SJ_MANIFEST_FIRST=1
}

sj_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

sj_manifest_add_raw() {
    local key="$1" raw="$2"
    [ -n "$SJ_MANIFEST_FILE" ] || sj_die "manifest not opened"
    if [ "$SJ_MANIFEST_FIRST" -eq 1 ]; then
        SJ_MANIFEST_FIRST=0
    else
        printf ',\n' >> "$SJ_MANIFEST_FILE"
    fi
    printf '  "%s": %s' "$key" "$raw" >> "$SJ_MANIFEST_FILE"
}

sj_manifest_add_string() { sj_manifest_add_raw "$1" "\"$(sj_json_escape "$2")\""; }
sj_manifest_add_bool() { sj_manifest_add_raw "$1" "$2"; }
sj_manifest_add_number() { sj_manifest_add_raw "$1" "$2"; }

sj_manifest_close() {
    [ -n "$SJ_MANIFEST_FILE" ] || sj_die "manifest not opened"
    printf '\n}\n' >> "$SJ_MANIFEST_FILE"
    [ -s "$SJ_MANIFEST_FILE" ] || sj_die "manifest is empty"
}

# ---------------------------------------------------------------------------
# Timestamp / DMG helpers
# ---------------------------------------------------------------------------

sj_now_iso8601() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

sj_create_dmg() {
    local staging="$1" out="$2" volname="$3"
    sj_assert_absent "$out"
    sj_hdiutil create \
        -volname "$volname" \
        -srcfolder "$staging" \
        -format UDZO \
        -fs HFS+ \
        "$out" >/dev/null \
        || sj_die "hdiutil create failed: $out"
}

# Mounts read-only at a private mountpoint, with image verification enabled.
sj_attach_dmg() {
    local dmg="$1" mountpoint="$2"
    mkdir -p -- "$mountpoint"
    sj_hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$dmg" >/dev/null \
        || sj_die "hdiutil attach failed: $dmg"
    printf '%s\n' "$mountpoint"
}

# Best-effort detach for trap cleanup only.
sj_detach_dmg() {
    local mountpoint="$1"
    [ -d "$mountpoint" ] || return 0
    sj_hdiutil detach "$mountpoint" >/dev/null 2>&1 || true
}

# Strict detach for normal verification paths; failure is fatal.
sj_detach_dmg_strict() {
    local mountpoint="$1"
    [ -d "$mountpoint" ] || return 0
    sj_hdiutil detach "$mountpoint" >/dev/null 2>&1 \
        || sj_die "hdiutil detach failed: $mountpoint"
}

# Requires a DMG root containing exactly the app bundle (a real directory, not a
# symlink) and the Applications symlink pointing precisely at /Applications.
# No other (including hidden) payload is accepted.
sj_check_dmg_layout() {
    local mountpoint="$1" app_name="$2"
    local entry base unexpected=""
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        base="$(basename "$entry")"
        case "$base" in
            "$app_name"|"Applications") : ;;
            *) unexpected="${unexpected}${base}"$'\n' ;;
        esac
    done < <(find "$mountpoint" -mindepth 1 -maxdepth 1 -print 2>/dev/null)

    [ -d "$mountpoint/$app_name" ] || sj_die "DMG root does not contain $app_name"
    [ ! -L "$mountpoint/$app_name" ] || sj_die "DMG app bundle must be a real directory, not a symlink"
    [ -L "$mountpoint/Applications" ] || sj_die "DMG root does not contain an Applications symlink"
    [ "$(readlink "$mountpoint/Applications")" = "/Applications" ] \
        || sj_die "DMG Applications symlink must point exactly at /Applications"
    if [ -n "$unexpected" ]; then
        sj_warn "unexpected DMG root entries:"
        printf '%s' "$unexpected" >&2
        sj_die "DMG layout check failed"
    fi
}

# ---------------------------------------------------------------------------
# Preflight report
# ---------------------------------------------------------------------------

sj_preflight_release_blockers() {
    local repo="$1" identity="${2:-}" blockers=0
    if ! sj_git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
        printf 'no-git-head\n'
        blockers=$((blockers + 1))
    elif [ -n "$(sj_git -C "$repo" status --porcelain 2>/dev/null)" ]; then
        printf 'dirty-working-tree\n'
        blockers=$((blockers + 1))
    fi
    if [ -z "$identity" ]; then
        printf 'no-signing-identity-supplied\n'
        blockers=$((blockers + 1))
    elif ! sj_identity_line "$identity" >/dev/null 2>&1; then
        printf 'signing-identity-not-found\n'
        blockers=$((blockers + 1))
    else
        local line label kind
        line="$(sj_identity_line "$identity")"
        label="$(printf '%s\n' "$line" | sed -E 's/^[^"]*"([^"]*)"[^"]*$/\1/')"
        kind="$(sj_identity_kind "$label")"
        if [ "$kind" != "developer-id-application" ]; then
            printf 'signing-identity-wrong-type:%s\n' "$kind"
            blockers=$((blockers + 1))
        fi
    fi
    printf 'blockers=%d\n' "$blockers"
    [ "$blockers" -eq 0 ]
}
