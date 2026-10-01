#!/bin/bash
# Self-tests for the SpaceJudge release scripts.
#
# Unit-tests the fail-closed helpers with deterministic stubs, then verifies
# that the official distribute/verify paths reject those very stubs and fail in
# the real (credential-less, HEAD-less) environment. No real signing,
# notarization or network access happens.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spacejudge-test.XXXXXX")"
PASS=0
FAIL=0

cleanup() {
    [ -d "$TEST_DIR" ] || return 0
    case "$(basename "$TEST_DIR")" in
        spacejudge-test.*) rm -r -- "$TEST_DIR" ;;
    esac
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

expect_fail() {
    local desc="$1"
    shift
    if ( "$@" >/dev/null 2>&1 ); then
        bad "$desc (expected failure, got success)"
    else
        ok "$desc"
    fi
}

expect_pass() {
    local desc="$1"
    shift
    if ( "$@" >/dev/null 2>&1 ); then
        ok "$desc"
    else
        bad "$desc (expected success, got failure)"
    fi
}

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------

STUB_DIR="$TEST_DIR/stub"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/security" <<'STUB'
#!/bin/bash
if [ "${SJ_STUB_SECURITY_MODE:-default}" = "empty" ]; then
    exit 0
fi
if [ "${SJ_STUB_SECURITY_MODE:-default}" = "ambiguous" ]; then
    cat <<'EOF'
  1) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Example Corp (TEAMID0002)"
  2) DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD "Developer ID Application: Example Corp (TEAMID0002)"
EOF
    exit 0
fi
cat <<'EOF'
  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Distribution: Example Corp (TEAMID0001)"
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Example Corp (TEAMID0002)"
  3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Apple Development: Example Dev (TEAMID0003)"
EOF
STUB
chmod +x "$STUB_DIR/security"

cat > "$STUB_DIR/stapler" <<'STUB'
#!/bin/bash
exit "${SJ_STUB_STAPLER_RC:-0}"
STUB
chmod +x "$STUB_DIR/stapler"

cat > "$STUB_DIR/spctl" <<'STUB'
#!/bin/bash
exit "${SJ_STUB_SPCTL_RC:-0}"
STUB
chmod +x "$STUB_DIR/spctl"

cat > "$STUB_DIR/lipo" <<'STUB'
#!/bin/bash
printf '%s\n' "${SJ_STUB_LIPO_ARCHS:-arm64 x86_64}"
STUB
chmod +x "$STUB_DIR/lipo"

cat > "$STUB_DIR/notarytool" <<'STUB'
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "history" ]; then
        printf '{"history":[]}\n'
        exit 0
    fi
done
printf '{"status":"Accepted","id":"STUB-SUBMISSION"}\n'
exit 0
STUB
chmod +x "$STUB_DIR/notarytool"

cat > "$STUB_DIR/codesign-entitlements" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-d" ] && [ "${2:-}" = "--entitlements" ]; then
    if [ -n "${SJ_STUB_ENTITLEMENTS:-}" ] && [ -f "${SJ_STUB_ENTITLEMENTS:-}" ]; then
        cat "$SJ_STUB_ENTITLEMENTS"
    fi
fi
exit 0
STUB
chmod +x "$STUB_DIR/codesign-entitlements"

# ---------------------------------------------------------------------------
# 1. Output directory safety
# ---------------------------------------------------------------------------

printf '== output directory ==\n'
expect_fail "relative output dir rejected" sj_assert_new_output_dir "relative/out"
expect_fail "non-empty output dir rejected" sj_assert_new_output_dir "$SCRIPT_DIR"
expect_pass "fresh output dir accepted" sj_assert_new_output_dir "$TEST_DIR/fresh-out"

# ---------------------------------------------------------------------------
# 2. Metadata syntax validation (before any path join)
# ---------------------------------------------------------------------------

printf '== metadata syntax ==\n'
expect_pass "valid version accepted" sj_require_safe_version "10.2.31"
expect_fail "version with slash rejected" sj_require_safe_version "1.2.3/../../etc"
expect_fail "version with dotdot rejected" sj_require_safe_version "1.2.3..evil"
expect_fail "two-part version rejected" sj_require_safe_version "1.2"
expect_fail "non-numeric version rejected" sj_require_safe_version "1.2.x"
expect_pass "positive build accepted" sj_require_safe_build "3"
expect_fail "zero build rejected" sj_require_safe_build "0"
expect_fail "negative build rejected" sj_require_safe_build "-1"
expect_fail "non-numeric build rejected" sj_require_safe_build "3a"
expect_fail "build with slash rejected" sj_require_safe_build "3/../x"
expect_pass "valid bundle id accepted" sj_require_safe_bundle_id "com.example.App"
expect_fail "bundle id with slash rejected" sj_require_safe_bundle_id "com/evil"
expect_fail "bundle id with dotdot rejected" sj_require_safe_bundle_id "com..evil"
expect_fail "bundle id with space rejected" sj_require_safe_bundle_id "com evil"
expect_pass "valid min os accepted" sj_require_safe_min_os "14.0"
expect_fail "min os with slash rejected" sj_require_safe_min_os "14.0/x"

# ---------------------------------------------------------------------------
# 3. Version consistency fixtures
# ---------------------------------------------------------------------------

printf '== version consistency ==\n'
VREPO="$TEST_DIR/vrepo"
mkdir -p "$VREPO/App/SpaceJudgeApp" "$VREPO/App/SpaceJudge.xcodeproj"
cat > "$VREPO/App/SpaceJudgeApp/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleExecutable</key><string>SpaceJudge</string>
</dict></plist>
PLIST
cat > "$VREPO/App/SpaceJudge.xcodeproj/project.pbxproj" <<'PBX'
MARKETING_VERSION = 0.3.0;
CURRENT_PROJECT_VERSION = 3;
PRODUCT_BUNDLE_IDENTIFIER = com.hongdazhu.SpaceJudge;
MACOSX_DEPLOYMENT_TARGET = 14.0;
PBX

make_app_plist() {
    local app="$1" version="$2" build="$3" bundle="${4:-com.hongdazhu.SpaceJudge}"
    mkdir -p "$app/Contents"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleExecutable</key><string>SpaceJudge</string>
</dict></plist>
PLIST
}

GOOD_APP="$TEST_DIR/good.app"
make_app_plist "$GOOD_APP" "0.3.0" "3"
expect_pass "matching metadata passes" sj_check_version_consistency "$VREPO" "$GOOD_APP"
expect_pass "source metadata syntax passes" sj_validate_source_metadata "$VREPO"

BAD_BUILD_APP="$TEST_DIR/badbuild.app"
make_app_plist "$BAD_BUILD_APP" "0.3.0" "4"
expect_fail "build mismatch fails closed" sj_check_version_consistency "$VREPO" "$BAD_BUILD_APP"

BAD_VER_APP="$TEST_DIR/badver.app"
make_app_plist "$BAD_VER_APP" "0.3.0/evil" "3"
expect_fail "unsafe bundle version rejected" sj_check_version_consistency "$VREPO" "$BAD_VER_APP"

BAD_ID_APP="$TEST_DIR/badid.app"
make_app_plist "$BAD_ID_APP" "0.3.0" "3" "com..evil"
expect_fail "unsafe bundle id rejected" sj_check_version_consistency "$VREPO" "$BAD_ID_APP"

# ---------------------------------------------------------------------------
# 4. Git provenance
# ---------------------------------------------------------------------------

printf '== git provenance ==\n'
REPO_FIXTURE="$TEST_DIR/repo"
mkdir -p "$REPO_FIXTURE"
sj_git -C "$REPO_FIXTURE" init -q
sj_git -C "$REPO_FIXTURE" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init
expect_pass "clean repo with HEAD passes" sj_git_ready "$REPO_FIXTURE"
touch "$REPO_FIXTURE/untracked.txt"
expect_fail "dirty repo rejected" sj_git_ready "$REPO_FIXTURE"
rm -f "$REPO_FIXTURE/untracked.txt"

NOHEAD_FIXTURE="$TEST_DIR/nohead"
mkdir -p "$NOHEAD_FIXTURE"
sj_git -C "$NOHEAD_FIXTURE" init -q
expect_fail "repo without HEAD rejected" sj_git_ready "$NOHEAD_FIXTURE"

# ---------------------------------------------------------------------------
# 5. Signing identity (including parent-shell global state)
# ---------------------------------------------------------------------------

printf '== signing identity ==\n'
export SJ_SECURITY_BIN="$STUB_DIR/security"
expect_fail "Apple Distribution rejected" sj_require_developer_id "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
expect_fail "Apple Development rejected" sj_require_developer_id "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
expect_fail "unknown identity rejected" sj_require_developer_id "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"
expect_pass "Developer ID Application accepted" sj_require_developer_id "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
# Direct call (no command substitution) must set the team ID in this shell.
SJ_SIGNING_TEAM_ID=""
sj_require_developer_id "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" >/dev/null
if [ "$SJ_SIGNING_TEAM_ID" = "TEAMID0002" ]; then
    ok "team id persists to parent shell"
else
    bad "team id persists to parent shell (got '$SJ_SIGNING_TEAM_ID')"
fi
SJ_STUB_SECURITY_MODE=ambiguous expect_fail "ambiguous label rejected" sj_require_developer_id "Developer ID Application: Example Corp (TEAMID0002)"

# ---------------------------------------------------------------------------
# 6. Effective entitlements
# ---------------------------------------------------------------------------

printf '== entitlements ==\n'
ENT_STUB="$STUB_DIR/codesign-entitlements"
printf '<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>\n' > "$TEST_DIR/ent-get-task-allow.plist"
printf '<plist><dict/></plist>\n' > "$TEST_DIR/ent-empty.plist"
printf '<plist><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>\n' > "$TEST_DIR/ent-unexpected.plist"
SJ_CODESIGN_BIN="$ENT_STUB" SJ_STUB_ENTITLEMENTS="$TEST_DIR/ent-get-task-allow.plist" \
    expect_fail "get-task-allow entitlement rejected" sj_require_no_entitlements "$TEST_DIR/good.app"
SJ_CODESIGN_BIN="$ENT_STUB" SJ_STUB_ENTITLEMENTS="$TEST_DIR/ent-unexpected.plist" \
    expect_fail "unexpected entitlement rejected" sj_require_no_entitlements "$TEST_DIR/good.app"
SJ_CODESIGN_BIN="$ENT_STUB" SJ_STUB_ENTITLEMENTS="$TEST_DIR/ent-empty.plist" \
    expect_pass "empty entitlements accepted" sj_require_no_entitlements "$TEST_DIR/good.app"
SJ_CODESIGN_BIN="$ENT_STUB" SJ_STUB_ENTITLEMENTS="" \
    expect_pass "no entitlements payload accepted" sj_require_no_entitlements "$TEST_DIR/good.app"

# ---------------------------------------------------------------------------
# 7. Notarization status and log
# ---------------------------------------------------------------------------

printf '== notarization ==\n'
printf '{"status":"Invalid"}\n' > "$TEST_DIR/notary-invalid.json"
printf '{"status":"Accepted"}\n' > "$TEST_DIR/notary-accepted.json"
expect_fail "Invalid notarization rejected" sj_require_notary_accepted "$TEST_DIR/notary-invalid.json"
expect_pass "Accepted notarization accepted" sj_require_notary_accepted "$TEST_DIR/notary-accepted.json"

printf '{"status":"Accepted","issues":[]}\n' > "$TEST_DIR/log-clean.json"
printf '{"status":"Accepted","issues":[{"severity":"warning","message":"x"}]}\n' > "$TEST_DIR/log-warning.json"
printf '{"status":"Accepted","issues":[{"severity":"error","message":"x"}]}\n' > "$TEST_DIR/log-error.json"
printf '{"status":"Invalid","issues":[]}\n' > "$TEST_DIR/log-invalid-status.json"
printf 'not json at all\n' > "$TEST_DIR/log-bad.json"
: > "$TEST_DIR/log-empty.json"
expect_pass "clean notarization log accepted" sj_require_notary_log_ok "$TEST_DIR/log-clean.json"
expect_fail "notarization log with error issue rejected" sj_require_notary_log_ok "$TEST_DIR/log-error.json"
expect_fail "notarization log with non-Accepted status rejected" sj_require_notary_log_ok "$TEST_DIR/log-invalid-status.json"
expect_fail "invalid JSON notarization log rejected" sj_require_notary_log_ok "$TEST_DIR/log-bad.json"
expect_fail "empty notarization log rejected" sj_require_notary_log_ok "$TEST_DIR/log-empty.json"
SJ_NOTARY_ERROR_COUNT=""
SJ_NOTARY_WARNING_COUNT=""
sj_require_notary_log_ok "$TEST_DIR/log-warning.json" >/dev/null
if [ "$SJ_NOTARY_ERROR_COUNT" = "0" ] && [ "$SJ_NOTARY_WARNING_COUNT" = "1" ]; then
    ok "warning issue counted without blocking"
else
    bad "warning issue counted (errors=$SJ_NOTARY_ERROR_COUNT warnings=$SJ_NOTARY_WARNING_COUNT)"
fi

# ---------------------------------------------------------------------------
# 8. Stapling and Gatekeeper
# ---------------------------------------------------------------------------

printf '== staple / gatekeeper ==\n'
touch "$TEST_DIR/fake.dmg"
SJ_STAPLER_BIN="$STUB_DIR/stapler" SJ_STUB_STAPLER_RC=1 expect_fail "stapler failure fails closed" sj_require_stapled "$TEST_DIR/fake.dmg"
SJ_STAPLER_BIN="$STUB_DIR/stapler" SJ_STUB_STAPLER_RC=0 expect_pass "stapler success passes" sj_require_stapled "$TEST_DIR/fake.dmg"
SJ_SPCTL_BIN="$STUB_DIR/spctl" SJ_STUB_SPCTL_RC=1 expect_fail "spctl failure fails closed" sj_require_gatekeeper execute "$TEST_DIR/fake.dmg"
SJ_SPCTL_BIN="$STUB_DIR/spctl" SJ_STUB_SPCTL_RC=0 expect_pass "spctl success passes" sj_require_gatekeeper execute "$TEST_DIR/fake.dmg"

# ---------------------------------------------------------------------------
# 9. Architecture and Mach-O inventory
# ---------------------------------------------------------------------------

printf '== architecture / mach-o ==\n'
ARCH_APP="$TEST_DIR/Arch.app"
mkdir -p "$ARCH_APP/Contents/MacOS"
touch "$ARCH_APP/Contents/MacOS/Arch"
SJ_LIPO_BIN="$STUB_DIR/lipo" SJ_STUB_LIPO_ARCHS="x86_64 arm64" \
    expect_pass "unsorted universal accepted and normalized" sj_require_universal "$ARCH_APP" "Arch"
SJ_LIPO_BIN="$STUB_DIR/lipo" SJ_STUB_LIPO_ARCHS="arm64" \
    expect_fail "single architecture rejected" sj_require_universal "$ARCH_APP" "Arch"
SJ_LIPO_BIN="$STUB_DIR/lipo" SJ_STUB_LIPO_ARCHS="arm64 arm64e x86_64" \
    expect_fail "extra architecture rejected" sj_require_universal "$ARCH_APP" "Arch"

MACHO_APP="$TEST_DIR/MachO.app"
mkdir -p "$MACHO_APP/Contents/MacOS" "$MACHO_APP/Contents/Frameworks"
printf '\xcf\xfa\xed\xfe' > "$MACHO_APP/Contents/MacOS/MachO"
expect_pass "single main executable accepted" sj_check_macho_inventory "$MACHO_APP" "MachO"
printf '\xcf\xfa\xed\xfe' > "$MACHO_APP/Contents/Frameworks/Evil.dylib"
expect_fail "unknown nested Mach-O rejected" sj_check_macho_inventory "$MACHO_APP" "MachO"
rm -f "$MACHO_APP/Contents/Frameworks/Evil.dylib"
mkdir -p "$MACHO_APP/Contents/Helpers"
printf '\xcf\xfa\xed\xfe' > "$MACHO_APP/Contents/Helpers/spacejudge-agent-cli"
expect_fail "allow-listed CLI still rejects unsigned nested code" sj_check_macho_inventory "$MACHO_APP" "MachO"
rm -f "$MACHO_APP/Contents/Helpers/spacejudge-agent-cli"

# ---------------------------------------------------------------------------
# 10. DMG layout
# ---------------------------------------------------------------------------

printf '== dmg layout ==\n'
LAYOUT="$TEST_DIR/layout"
mkdir -p "$LAYOUT/SpaceJudge.app"
ln -s /Applications "$LAYOUT/Applications"
expect_pass "valid DMG layout passes" sj_check_dmg_layout "$LAYOUT" "SpaceJudge.app"
touch "$LAYOUT/stray-file.txt"
expect_fail "unexpected DMG root entry rejected" sj_check_dmg_layout "$LAYOUT" "SpaceJudge.app"
rm -f "$LAYOUT/stray-file.txt"
ln -s /Applications "$LAYOUT/evil"
rm -f "$LAYOUT/Applications"
ln -s /tmp "$LAYOUT/Applications"
expect_fail "Applications symlink to wrong target rejected" sj_check_dmg_layout "$LAYOUT" "SpaceJudge.app"
rm -f "$LAYOUT/Applications" "$LAYOUT/evil"
ln -s /Applications "$LAYOUT/Applications"

# ---------------------------------------------------------------------------
# 11. Checksum sidecar binding
# ---------------------------------------------------------------------------

printf '== checksum sidecar ==\n'
SIDECAR_DMG="$TEST_DIR/sample.dmg"
printf 'payload' > "$SIDECAR_DMG"
H="$(sj_sha256 "$SIDECAR_DMG")"
printf '%s  %s\n' "$H" "sample.dmg" > "$SIDECAR_DMG.sha256"
expect_pass "matching checksum sidecar passes" sj_verify_checksum_sidecar "$SIDECAR_DMG"
printf '%s  %s\n' "deadbeef" "sample.dmg" > "$SIDECAR_DMG.sha256"
expect_fail "wrong checksum hash rejected" sj_verify_checksum_sidecar "$SIDECAR_DMG"
printf '%s  %s\n' "$H" "other.dmg" > "$SIDECAR_DMG.sha256"
expect_fail "checksum filename mismatch rejected" sj_verify_checksum_sidecar "$SIDECAR_DMG"
rm -f "$SIDECAR_DMG.sha256"
expect_fail "missing checksum sidecar rejected" sj_verify_checksum_sidecar "$SIDECAR_DMG"

# ---------------------------------------------------------------------------
# 12. Manifest binding
# ---------------------------------------------------------------------------

printf '== manifest binding ==\n'
BIND_APP="$TEST_DIR/Bind.app"
make_app_plist "$BIND_APP" "0.3.0" "3"
LOCAL_MANIFEST="$TEST_DIR/local.json"
cat > "$LOCAL_MANIFEST" <<'JSON'
{
  "product": "Bind", "version": "0.3.0", "build": "3",
  "bundleID": "com.hongdazhu.SpaceJudge", "minimumSystemVersion": "14.0",
  "architectures": "arm64 x86_64", "kind": "local-adhoc",
  "distributionReady": false, "notarizationStatus": "not-submitted",
  "sha256": "abc123"
}
JSON
expect_pass "local manifest binding passes" sj_bind_manifest "$LOCAL_MANIFEST" "$BIND_APP" local "abc123" "arm64 x86_64"
expect_fail "manifest sha mismatch rejected" sj_bind_manifest "$LOCAL_MANIFEST" "$BIND_APP" local "different" "arm64 x86_64"
expect_fail "manifest ready=true in local mode rejected" sj_bind_manifest "$LOCAL_MANIFEST" "$BIND_APP" release "abc123" "arm64 x86_64"

RELEASE_MANIFEST="$TEST_DIR/release.json"
cat > "$RELEASE_MANIFEST" <<'JSON'
{
  "product": "Bind", "version": "0.3.0", "build": "3",
  "bundleID": "com.hongdazhu.SpaceJudge", "minimumSystemVersion": "14.0",
  "architectures": "arm64 x86_64", "kind": "developer-id",
  "distributionReady": true, "notarizationStatus": "Accepted",
  "notarizationSubmissionID": "SUB-1", "gitCommit": "0123456789abcdef0123456789abcdef01234567",
  "teamID": "TEAMID0002", "sha256": "abc123"
}
JSON
expect_pass "release manifest binding passes" sj_bind_manifest "$RELEASE_MANIFEST" "$BIND_APP" release "abc123" "arm64 x86_64"
sed 's/"SUB-1"/""/' "$RELEASE_MANIFEST" > "$TEST_DIR/release-nosub.json"
expect_fail "release manifest without submission id rejected" sj_bind_manifest "$TEST_DIR/release-nosub.json" "$BIND_APP" release "abc123" "arm64 x86_64"
sed 's/"0123456789abcdef0123456789abcdef01234567"/"short"/' "$RELEASE_MANIFEST" > "$TEST_DIR/release-badcommit.json"
expect_fail "release manifest with bad commit rejected" sj_bind_manifest "$TEST_DIR/release-badcommit.json" "$BIND_APP" release "abc123" "arm64 x86_64"

# ---------------------------------------------------------------------------
# 13. Official pipeline rejects test overrides and real blockers
# ---------------------------------------------------------------------------

printf '== official pipeline gates ==\n'
unset SJ_SECURITY_BIN SJ_STAPLER_BIN SJ_SPCTL_BIN SJ_NOTARYTOOL_BIN SJ_LIPO_BIN SJ_CODESIGN_BIN || true
DIST="$SCRIPT_DIR/distribute.sh"
VERIFY="$SCRIPT_DIR/verify-artifact.sh"
REAL_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

expect_fail "missing --release rejected" "$DIST" --output-dir "$TEST_DIR/preflight-out" \
    --identity "Developer ID Application: Nobody (NONE000000)" --keychain-profile test
SJ_SECURITY_BIN="$STUB_DIR/security" expect_fail "distribute rejects tool override" "$DIST" --release --preflight-only \
    --repo "$REAL_REPO" --output-dir "$TEST_DIR/preflight-ovr" \
    --identity "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" --keychain-profile test
# Real environment: no HEAD and no Developer ID. Must fail without touching Apple.
expect_fail "real environment preflight rejected" "$DIST" --release --preflight-only \
    --repo "$REAL_REPO" --output-dir "$TEST_DIR/preflight-real" \
    --identity "Developer ID Application: Nobody (NONE000000)" --keychain-profile test

# Helper preflight report still unit-testable with stubs (no process spawn).
BLOCK_REPO="$TEST_DIR/blockrepo"
mkdir -p "$BLOCK_REPO/App/SpaceJudge.xcodeproj"
sj_git -C "$BLOCK_REPO" init -q
sj_git -C "$BLOCK_REPO" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m init
if ( SJ_SECURITY_BIN="$STUB_DIR/security" sj_preflight_release_blockers "$BLOCK_REPO" "Developer ID Application: Example Corp (TEAMID0002)" >/dev/null ); then
    ok "clean repo + Developer ID has no blockers (stub)"
else
    bad "clean repo + Developer ID has no blockers (stub)"
fi
if ( SJ_SECURITY_BIN="$STUB_DIR/security" sj_preflight_release_blockers "$BLOCK_REPO" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" >/dev/null ); then
    bad "Apple Distribution reported as blocker (stub)"
else
    ok "Apple Distribution reported as blocker (stub)"
fi

# Non-existent fail-closed paths for verifier.
SJ_CODESIGN_BIN="$STUB_DIR/codesign-entitlements" expect_fail "verify rejects tool override" "$VERIFY" \
    --dmg "$TEST_DIR/fake.dmg" --manifest "$TEST_DIR/local.json" --mode release
expect_fail "verify requires manifest" "$VERIFY" --dmg "$TEST_DIR/fake.dmg"
expect_fail "verify requires checksum sidecar" "$VERIFY" --dmg "$TEST_DIR/fake.dmg" --manifest "$TEST_DIR/local.json"

# ---------------------------------------------------------------------------
# 14. Temp directory lifecycle (parent-shell global, cleanup)
# ---------------------------------------------------------------------------

printf '== temp lifecycle ==\n'
SJ_TEMP_DIR=""
sj_make_temp_dir spacejudge-test
CREATED="$SJ_TEMP_DIR"
if [ -n "$CREATED" ] && [ -d "$CREATED" ]; then
    ok "temp dir created in parent shell"
else
    bad "temp dir created in parent shell (got '$CREATED')"
fi
sj_cleanup_temp
if [ -z "$SJ_TEMP_DIR" ] && [ ! -e "$CREATED" ]; then
    ok "temp dir reclaimed by cleanup"
else
    bad "temp dir reclaimed by cleanup"
fi

# ---------------------------------------------------------------------------
# 15. Static boundaries
# ---------------------------------------------------------------------------

printf '== static boundaries ==\n'
if grep -qE 'notarytool (submit|log)|sj_notarytool' "$SCRIPT_DIR/local-candidate.sh"; then
    bad "local-candidate must not reference notarytool"
else
    ok "local-candidate does not invoke notarytool"
fi
for script in "$SCRIPT_DIR"/*.sh; do
    base="$(basename "$script")"
    if bash -n "$script"; then ok "bash -n $base"; else bad "bash -n $base"; fi
    if grep -vE '^[[:space:]]*#' "$script" | grep -qE '(^|[^[:alnum:]_])eval([[:space:]]|$)'; then
        bad "$base uses eval"
    else
        ok "$base has no eval"
    fi
    rm_rf_pattern='rm'" -rf"
    if grep -q -- "$rm_rf_pattern" "$script"; then
        bad "$base uses forced recursive remove"
    else
        ok "$base has no forced recursive remove"
    fi
    if grep -vE '^[[:space:]]*#' "$script" | grep -qE '\-\-(apple-id|password)[= ]'; then
        bad "$base accepts plaintext credentials"
    else
        ok "$base has no plaintext credential args"
    fi
    temp_sub_pattern='$'"(sj_make_temp_dir"
    if grep -q -- "$temp_sub_pattern" "$script"; then
        bad "$base calls sj_make_temp_dir through command substitution"
    else
        ok "$base calls sj_make_temp_dir directly"
    fi
done

# ---------------------------------------------------------------------------
# 16. Caller PATH hardening
# ---------------------------------------------------------------------------

printf '== caller PATH hardening ==\n'
restore_path="$PATH"
if [ "$(sj_lock_system_path; printf '%s' "$PATH")" = "/usr/bin:/bin:/usr/sbin:/sbin" ]; then
    ok "sj_lock_system_path pins the system path"
else
    bad "sj_lock_system_path pins the system path"
fi
MAL_DIR="$TEST_DIR/malicious"
MAL_MARKER="$TEST_DIR/malicious.marker"
mkdir -p "$MAL_DIR"
# Each substitute records that it ran, then delegates to the real absolute tool.
# With a correct PATH lock the marker stays empty; if the lock regressed the
# entry still behaves correctly but the marker exposes the substitution.
for tool in plutil xcrun notarytool ditto security git hdiutil codesign shasum dirname basename sed awk grep find mktemp; do
    if [ "$tool" = "notarytool" ]; then
        real='/usr/bin/xcrun notarytool'
    else
        real="/usr/bin/$tool"
    fi
    cat > "$MAL_DIR/$tool" <<STUB
#!/bin/bash
printf '%s\n' "$tool" >> "\${SJ_MALICIOUS_MARKER:-/dev/null}"
exec $real "\$@"
STUB
    chmod +x "$MAL_DIR/$tool"
done
: > "$MAL_MARKER"

# distribute.sh must ignore a malicious caller PATH and fail on the real gates.
PATH="$MAL_DIR:$restore_path" SJ_MALICIOUS_MARKER="$MAL_MARKER" \
    expect_fail "distribute ignores malicious caller PATH and still fails" "$DIST" --release --preflight-only \
    --repo "$REAL_REPO" --output-dir "$TEST_DIR/mal-preflight" \
    --identity "Developer ID Application: Evil Corp (EVILTEAM01)" --keychain-profile test
# local-candidate must also reject before any build under a malicious PATH.
PATH="$MAL_DIR:$restore_path" SJ_MALICIOUS_MARKER="$MAL_MARKER" \
    expect_fail "local-candidate ignores malicious caller PATH" "$SCRIPT_DIR/local-candidate.sh" --output-dir "$SCRIPT_DIR"
# verify-artifact must reject under a malicious PATH before touching its inputs.
PATH="$MAL_DIR:$restore_path" SJ_MALICIOUS_MARKER="$MAL_MARKER" \
    expect_fail "verify-artifact ignores malicious caller PATH" "$VERIFY" \
    --dmg "$TEST_DIR/missing.dmg" --manifest "$TEST_DIR/missing.json"
if [ -s "$MAL_MARKER" ]; then
    bad "malicious PATH substitutes were executed: $(sort -u "$MAL_MARKER" | tr '\n' ' ')"
else
    ok "no malicious PATH substitute was executed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\nself-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
