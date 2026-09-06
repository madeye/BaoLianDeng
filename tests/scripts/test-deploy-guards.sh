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
# This test exercises the shared helpers in scripts/lib/deploy-lib.sh
# (`xcodebuild_logged` and `install_app_bundle`) that scripts/dev-deploy.sh
# and scripts/release-deploy.sh now use for their build+install step,
# against a stub `xcodebuild` that always fails, and traced rm/cp/mv
# wrappers, then asserts:
#
#   1. xcodebuild_logged returns xcodebuild's own exit status (65), not the
#      exit status of whatever consumed its output.
#   2. A previously-installed app is left completely untouched — same
#      content, never removed — when the build fails.
#   3. No rm/cp/mv invocation ever targeted the installed app path during
#      that failed run.
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
# Fixture: a fake DerivedData tree, a fake project dir, and a fake
# already-installed app with a marker file we can check survives.
# ---------------------------------------------------------------------------

DERIVED_DATA_ROOT="${WORKDIR}/DerivedData"
PROJECT_DIR="${WORKDIR}/project"
APP_PATH="${WORKDIR}/Applications/BaoLianDeng.app"
TRACE_LOG="${WORKDIR}/trace.log"

mkdir -p "$DERIVED_DATA_ROOT" "$PROJECT_DIR" "$(dirname "$APP_PATH")"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/PlugIns/TransparentProxy.appex"
echo "OLD-BINARY-MARKER" > "${APP_PATH}/Contents/MacOS/BaoLianDeng"
echo "<plist/>" > "${APP_PATH}/Contents/Info.plist"

# ---------------------------------------------------------------------------
# Stub bin dir: xcodebuild always fails like a real build error (exit 65);
# rm/cp/mv are traced (every invocation logged) but still perform the real
# operation via their absolute path, so staging/backup dirs made by the code
# under test keep working.
# ---------------------------------------------------------------------------

STUB_BIN="${WORKDIR}/bin"
mkdir -p "$STUB_BIN"

cat > "${STUB_BIN}/xcodebuild" <<'EOF'
#!/bin/bash
echo "=== BUILD TARGET BaoLianDeng ==="
echo "CompileSwift normal arm64 SomeFile.swift"
echo "** BUILD FAILED **"
exit 65
EOF
chmod +x "${STUB_BIN}/xcodebuild"

for tool in rm cp mv; do
  real="/bin/${tool}"
  cat > "${STUB_BIN}/${tool}" <<EOF
#!/bin/bash
echo "${tool} \$*" >> "${TRACE_LOG}"
exec ${real} "\$@"
EOF
  chmod +x "${STUB_BIN}/${tool}"
done

export PATH="${STUB_BIN}:${PATH}"

# ---------------------------------------------------------------------------
# Test 1: xcodebuild_logged propagates the real (failing) exit status.
# ---------------------------------------------------------------------------

BUILD_LOG="${WORKDIR}/build.log"
XCB_STATUS=0
xcodebuild_logged "$BUILD_LOG" 3 build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'platform=macOS' || XCB_STATUS=$?

if [ "$XCB_STATUS" -eq 65 ]; then
  pass "xcodebuild_logged propagated xcodebuild's real exit status (65)"
else
  fail "expected xcodebuild_logged to return 65, got ${XCB_STATUS}"
fi

# ---------------------------------------------------------------------------
# Test 2/3: the dev-deploy.sh/release-deploy.sh build+install sequence,
# reproduced exactly as those scripts now call it, must leave the installed
# app untouched when the build fails, and must never call rm/cp/mv on it
# before that point.
# ---------------------------------------------------------------------------

: > "$TRACE_LOG"

BUILD_STATUS=0
xcodebuild_logged "$BUILD_LOG" 3 build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'platform=macOS' || BUILD_STATUS=$?

INSTALL_RAN=0
if [ "$BUILD_STATUS" -eq 0 ]; then
  # Would only run on a successful build — must not happen in this test.
  INSTALL_RAN=1
  BUILT_APP="${DERIVED_DATA_ROOT}/BaoLianDeng-x/Build/Products/Debug/BaoLianDeng.app"
  install_app_bundle "$BUILT_APP" "$APP_PATH" || true
fi

if [ "$BUILD_STATUS" -ne 0 ] && [ "$INSTALL_RAN" -eq 0 ]; then
  pass "install step was skipped after the build failed (matches dev-deploy.sh/release-deploy.sh control flow)"
else
  fail "install step ran despite a failed build"
fi

if [ -f "${APP_PATH}/Contents/MacOS/BaoLianDeng" ] && \
   [ "$(cat "${APP_PATH}/Contents/MacOS/BaoLianDeng")" = "OLD-BINARY-MARKER" ] && \
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
# Test 4: install_app_bundle itself refuses an incomplete bundle (missing
# appex) and leaves the existing install in place — covers the "validate
# before touching the installed app" half of the fix independent of the
# xcodebuild status question above.
# ---------------------------------------------------------------------------

: > "$TRACE_LOG"
INCOMPLETE_APP="${WORKDIR}/incomplete/BaoLianDeng.app"
mkdir -p "${INCOMPLETE_APP}/Contents/MacOS"
echo "NEW-BINARY" > "${INCOMPLETE_APP}/Contents/MacOS/BaoLianDeng"
echo "<plist/>" > "${INCOMPLETE_APP}/Contents/Info.plist"
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

echo ""
if [ "$FAILURES" -ne 0 ]; then
  echo "=== test-deploy-guards.sh: ${FAILURES} check(s) FAILED ==="
  exit 1
fi

echo "=== test-deploy-guards.sh: all checks passed ==="
