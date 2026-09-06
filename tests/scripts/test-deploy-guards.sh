#!/bin/bash
# Regression test for GitHub issue #113 finding 3: a failed Xcode build must
# never remove or corrupt the installed app.
#
# Before the fix, dev-deploy.sh / release-deploy.sh piped `xcodebuild` into
# `tail -3` under `set -e` (no pipefail), so a failed build's real exit
# status (e.g. 65) was masked by tail's exit status (0) and the script
# proceeded to `rm -rf` the installed app, then `cp -R` a missing/incomplete
# replacement over it.
#
# This test calls `build_and_install_app` in scripts/lib/deploy-lib.sh —
# the *exact* function dev-deploy.sh and release-deploy.sh now call for
# their whole build+install step — against a stub `xcodebuild` and traced
# rm/cp/mv wrappers. It deliberately does not re-implement any part of the
# build/status-check/install control flow itself: if dev-deploy.sh or
# release-deploy.sh (or build_and_install_app itself) regressed back to
# `xcodebuild ... | tail -N` or dropped the exit-status check, this test
# would fail because it drives that same shared code path, not a copy of
# it. It asserts:
#
#   1. xcodebuild_logged returns xcodebuild's own exit status (65), not the
#      exit status of whatever consumed its output.
#   2. build_and_install_app itself returns non-zero on a failed build.
#   3. A previously-installed app is left completely untouched — same
#      content, never removed — when the build fails.
#   4. No rm/cp/mv invocation ever targeted the installed app path during
#      that failed run.
#   5. install_app_bundle rejects an incomplete bundle (missing appex)
#      without touching the existing install.
#   6. build_and_install_app's success path: the new bundle is swapped in,
#      the old one is gone, and no stray staging/backup directories survive.
#   7. If the final move-into-place fails, the previous install is restored
#      rather than left missing.
#
# Run with: bash tests/scripts/test-deploy-guards.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../../scripts/lib/deploy-lib.sh
source "${REPO_ROOT}/scripts/lib/deploy-lib.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/bld-deploy-guard-test.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# Fixture: a fake DerivedData tree and a fake already-installed app with a
# marker file we can check survives.
# ---------------------------------------------------------------------------

DERIVED_DATA_ROOT="${WORKDIR}/DerivedData"
APP_PATH="${WORKDIR}/Applications/BaoLianDeng.app"
TRACE_LOG="${WORKDIR}/trace.log"
BUILT_APP_GLOB="${DERIVED_DATA_ROOT}/BaoLianDeng-*/Build/Products/Debug/BaoLianDeng.app"

reset_installed_app() {
  rm -rf "$APP_PATH"
  mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/PlugIns/TransparentProxy.appex"
  echo "OLD-BINARY-MARKER" >"${APP_PATH}/Contents/MacOS/BaoLianDeng"
  echo "<plist/>" >"${APP_PATH}/Contents/Info.plist"
}

mkdir -p "$DERIVED_DATA_ROOT" "$(dirname "$APP_PATH")"
reset_installed_app

# ---------------------------------------------------------------------------
# Stub bin dir: rm/cp/mv are traced (every invocation logged) but still
# perform the real operation via their absolute path, so staging/backup dirs
# made by the code under test keep working. xcodebuild is stubbed per-test
# below (failing, succeeding, or succeeding-but-doomed-to-fail-the-final-mv).
# ---------------------------------------------------------------------------

STUB_BIN="${WORKDIR}/bin"
mkdir -p "$STUB_BIN"

for tool in rm cp mv; do
  real="/bin/${tool}"
  cat >"${STUB_BIN}/${tool}" <<EOF
#!/bin/bash
echo "${tool} \$*" >> "${TRACE_LOG}"
exec ${real} "\$@"
EOF
  chmod +x "${STUB_BIN}/${tool}"
done

export PATH="${STUB_BIN}:${PATH}"

xcodebuild_args=(build -project BaoLianDeng.xcodeproj -scheme BaoLianDeng \
  -configuration Debug -destination 'platform=macOS')

# ---------------------------------------------------------------------------
# Test 1: xcodebuild_logged propagates the real (failing) exit status.
# ---------------------------------------------------------------------------

cat >"${STUB_BIN}/xcodebuild" <<'EOF'
#!/bin/bash
echo "=== BUILD TARGET BaoLianDeng ==="
echo "CompileSwift normal arm64 SomeFile.swift"
echo "** BUILD FAILED **"
exit 65
EOF
chmod +x "${STUB_BIN}/xcodebuild"

BUILD_LOG="${WORKDIR}/build.log"
XCB_STATUS=0
xcodebuild_logged "$BUILD_LOG" 3 "${xcodebuild_args[@]}" || XCB_STATUS=$?

if [ "$XCB_STATUS" -eq 65 ]; then
  pass "xcodebuild_logged propagated xcodebuild's real exit status (65)"
else
  fail "expected xcodebuild_logged to return 65, got ${XCB_STATUS}"
fi

# ---------------------------------------------------------------------------
# Tests 2-4: call build_and_install_app itself — the exact function
# dev-deploy.sh/release-deploy.sh call — against the failing xcodebuild stub.
# ---------------------------------------------------------------------------

: >"$TRACE_LOG"

BAI_STATUS=0
build_and_install_app "$BUILT_APP_GLOB" "$APP_PATH" 3 \
  "Contents/PlugIns/TransparentProxy.appex" -- \
  "${xcodebuild_args[@]}" || BAI_STATUS=$?

if [ "$BAI_STATUS" -ne 0 ]; then
  pass "build_and_install_app returned non-zero (${BAI_STATUS}) after a failed build"
else
  fail "build_and_install_app returned success despite a failed build"
fi

if [ -f "${APP_PATH}/Contents/MacOS/BaoLianDeng" ] &&
  [ "$(cat "${APP_PATH}/Contents/MacOS/BaoLianDeng")" = "OLD-BINARY-MARKER" ] &&
  [ -d "${APP_PATH}/Contents/PlugIns/TransparentProxy.appex" ]; then
  pass "installed app is untouched after a failed build"
else
  fail "installed app was modified or removed after a failed build"
fi

if [ -s "$TRACE_LOG" ] && grep -q -- "$APP_PATH" "$TRACE_LOG"; then
  fail "a destructive command touched the installed app path: $(grep -- "$APP_PATH" "$TRACE_LOG")"
else
  pass "no rm/cp/mv command ever referenced the installed app path during the failed run"
fi

# ---------------------------------------------------------------------------
# Test 5: install_app_bundle itself refuses an incomplete bundle (missing
# appex) and leaves the existing install in place — covers the "validate
# before touching the installed app" half of the fix independent of the
# xcodebuild status question above.
# ---------------------------------------------------------------------------

: >"$TRACE_LOG"
INCOMPLETE_APP="${WORKDIR}/incomplete/BaoLianDeng.app"
mkdir -p "${INCOMPLETE_APP}/Contents/MacOS"
echo "NEW-BINARY" >"${INCOMPLETE_APP}/Contents/MacOS/BaoLianDeng"
echo "<plist/>" >"${INCOMPLETE_APP}/Contents/Info.plist"
# Deliberately no Contents/PlugIns/TransparentProxy.appex.

INSTALL_STATUS=0
install_app_bundle "$INCOMPLETE_APP" "$APP_PATH" || INSTALL_STATUS=$?

if [ "$INSTALL_STATUS" -ne 0 ]; then
  pass "install_app_bundle rejected a bundle missing TransparentProxy.appex"
else
  fail "install_app_bundle accepted a bundle missing TransparentProxy.appex"
fi

if [ "$(cat "${APP_PATH}/Contents/MacOS/BaoLianDeng")" = "OLD-BINARY-MARKER" ]; then
  pass "installed app is untouched after a rejected (incomplete) bundle"
else
  fail "installed app was modified after a rejected (incomplete) bundle"
fi

if [ -s "$TRACE_LOG" ] && grep -q -- "$APP_PATH" "$TRACE_LOG"; then
  fail "a destructive command touched the installed app path while validating an incomplete bundle: $(grep -- "$APP_PATH" "$TRACE_LOG")"
else
  pass "no rm/cp/mv command ever referenced the installed app path while validating an incomplete bundle"
fi

# ---------------------------------------------------------------------------
# Test 6: build_and_install_app's success path — a real (stub) successful
# build must swap the new bundle into place, remove the old one, and leave
# no stray staging/backup directories behind.
# ---------------------------------------------------------------------------

cat >"${STUB_BIN}/xcodebuild" <<EOF
#!/bin/bash
echo "=== BUILD TARGET BaoLianDeng ==="
mkdir -p "${DERIVED_DATA_ROOT}/BaoLianDeng-abc123/Build/Products/Debug/BaoLianDeng.app/Contents/MacOS"
mkdir -p "${DERIVED_DATA_ROOT}/BaoLianDeng-abc123/Build/Products/Debug/BaoLianDeng.app/Contents/PlugIns/TransparentProxy.appex"
echo "NEW-BINARY-MARKER" > "${DERIVED_DATA_ROOT}/BaoLianDeng-abc123/Build/Products/Debug/BaoLianDeng.app/Contents/MacOS/BaoLianDeng"
echo "<plist/>" > "${DERIVED_DATA_ROOT}/BaoLianDeng-abc123/Build/Products/Debug/BaoLianDeng.app/Contents/Info.plist"
echo "** BUILD SUCCEEDED **"
exit 0
EOF
chmod +x "${STUB_BIN}/xcodebuild"

: >"$TRACE_LOG"
BAI_STATUS=0
build_and_install_app "$BUILT_APP_GLOB" "$APP_PATH" 3 \
  "Contents/PlugIns/TransparentProxy.appex" -- \
  "${xcodebuild_args[@]}" || BAI_STATUS=$?

if [ "$BAI_STATUS" -eq 0 ]; then
  pass "build_and_install_app returned success after a successful build"
else
  fail "build_and_install_app returned ${BAI_STATUS} after a successful build"
fi

if [ -f "${APP_PATH}/Contents/MacOS/BaoLianDeng" ] &&
  [ "$(cat "${APP_PATH}/Contents/MacOS/BaoLianDeng")" = "NEW-BINARY-MARKER" ]; then
  pass "installed app was swapped for the newly built bundle"
else
  fail "installed app was not updated to the newly built bundle"
fi

STRAY=$(find "$(dirname "$APP_PATH")" -maxdepth 1 \( -name "*.bak.*" -o -name "*-stage.*" \) 2>/dev/null || true)
if [ -z "$STRAY" ]; then
  pass "no stray backup/staging directories survive a successful swap"
else
  fail "stray backup/staging directories left behind: ${STRAY}"
fi

# ---------------------------------------------------------------------------
# Test 7: install_app_bundle restores the previous install if the final
# move-into-place fails (e.g. destination briefly unwritable).
# ---------------------------------------------------------------------------

reset_installed_app
GOOD_APP="${WORKDIR}/good/BaoLianDeng.app"
mkdir -p "${GOOD_APP}/Contents/MacOS" "${GOOD_APP}/Contents/PlugIns/TransparentProxy.appex"
echo "SHOULD-NOT-INSTALL" >"${GOOD_APP}/Contents/MacOS/BaoLianDeng"
echo "<plist/>" >"${GOOD_APP}/Contents/Info.plist"

cat >"${STUB_BIN}/mv" <<EOF
#!/bin/bash
echo "mv \$*" >> "${TRACE_LOG}"
# Fail only the final "staged app -> install path" move (the one whose
# source path contains "-stage."); the "install path -> backup" move must
# still succeed so this test exercises the restore branch specifically.
for arg in "\$@"; do
  case "\$arg" in
    *-stage.*) exit 1 ;;
  esac
done
exec /bin/mv "\$@"
EOF
chmod +x "${STUB_BIN}/mv"

: >"$TRACE_LOG"
INSTALL_STATUS=0
install_app_bundle "$GOOD_APP" "$APP_PATH" || INSTALL_STATUS=$?

if [ "$INSTALL_STATUS" -ne 0 ]; then
  pass "install_app_bundle reported failure when the final move failed"
else
  fail "install_app_bundle reported success despite the final move failing"
fi

if [ -f "${APP_PATH}/Contents/MacOS/BaoLianDeng" ] &&
  [ "$(cat "${APP_PATH}/Contents/MacOS/BaoLianDeng")" = "OLD-BINARY-MARKER" ]; then
  pass "previous install was restored after the final move failed"
else
  fail "previous install was NOT restored after the final move failed (install path: $([ -e "$APP_PATH" ] && echo present || echo MISSING))"
fi

# restore the real mv stub for anything after this point
cat >"${STUB_BIN}/mv" <<EOF
#!/bin/bash
echo "mv \$*" >> "${TRACE_LOG}"
exec /bin/mv "\$@"
EOF
chmod +x "${STUB_BIN}/mv"

# ---------------------------------------------------------------------------

echo ""
if [ "$FAILURES" -ne 0 ]; then
  echo "=== test-deploy-guards.sh: ${FAILURES} check(s) FAILED ==="
  exit 1
fi

echo "=== test-deploy-guards.sh: all checks passed ==="
