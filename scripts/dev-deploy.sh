#!/bin/bash
# Build, install, and test BaoLianDeng with VPN toggle automation
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deploy-lib.sh
source "${SCRIPT_DIR}/lib/deploy-lib.sh"

VPN_NAME="BaoLianDeng"
APP_PATH="/Applications/BaoLianDeng.app"
PROJECT_DIR="/Volumes/DATA/workspace/BaoLianDeng"
LOG_DIR="$HOME/Library/Containers/io.github.baoliandeng.macos.TransparentProxy/Data/Library/Application Support/BaoLianDeng"

cd "$PROJECT_DIR"

echo "=== Step 1: Stop VPN ==="
scutil --nc stop "$VPN_NAME" 2>/dev/null || true
# App-extension providers often do not show up in scutil --nc; quitting the
# app is not enough if the appex is still intercepting DNS (fake-ip leaks).
killall TransparentProxy 2>/dev/null || true
sleep 2

echo "=== Step 2: Quit app ==="
osascript -e 'tell application "BaoLianDeng" to quit' 2>/dev/null || true
killall BaoLianDeng 2>/dev/null || true
sleep 1

echo "=== Step 3: Bump Debug build number ==="
# Stamp a unique CFBundleVersion on each Debug install so logs and crash
# reports distinguish iterations. The provider is an app extension
# (PlugIns/TransparentProxy.appex); replacing the app bundle is enough for
# macOS to load the new provider — no sysextd hash pin.
"$PROJECT_DIR/scripts/bump-build.sh" debug

echo "=== Step 4: Build framework ==="
make framework

echo "=== Step 5: Build app ==="
rm -rf ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/BaoLianDeng-build.XXXXXX.log")"
BUILD_STATUS=0
xcodebuild_logged "$BUILD_LOG" 3 build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'platform=macOS' || BUILD_STATUS=$?
rm -f "$BUILD_LOG"
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "ERROR: xcodebuild build failed (exit ${BUILD_STATUS}); leaving installed app untouched"
    exit "$BUILD_STATUS"
fi

echo "=== Step 6: Install ==="
# Validate the freshly built bundle and stage it before touching the
# installed app — a failed or incomplete build must never remove a working
# install (issue #113 finding 3).
BUILT_APP=$(echo ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Debug/BaoLianDeng.app)
if ! install_app_bundle "$BUILT_APP" "$APP_PATH"; then
    echo "ERROR: install failed; any previously-installed app was left in place"
    exit 1
fi

echo "=== Step 7: Launch app ==="
touch /tmp/.bld-autoconnect
open "$APP_PATH"
sleep 3

echo "=== Step 8: Start VPN ==="
scutil --nc start "$VPN_NAME" 2>/dev/null || true
for i in $(seq 1 30); do
    vpnstatus=$(scutil --nc status "$VPN_NAME" 2>&1 | head -1)
    if [ "$vpnstatus" = "Connected" ]; then
        echo "VPN connected after ${i}s"
        break
    fi
    if pgrep -f 'PlugIns/TransparentProxy.appex' >/dev/null 2>&1; then
        echo "VPN connected after ${i}s (app extension running)"
        break
    fi
    sleep 1
done

echo "=== Step 9: Wait for tunnel + meow engine startup ==="
LOG_FILE="$LOG_DIR/rust_bridge.log"
for i in $(seq 1 30); do
    if grep -q "meow engine started" "$LOG_FILE" 2>/dev/null ||
       grep -q "engine started successfully" "$LOG_FILE" 2>/dev/null; then
        echo "Tunnel ready after ${i}s"
        sleep 3
        break
    fi
    sleep 1
done

# Verify mihomo SOCKS5 proxy is listening
echo "=== Step 10: Verify SOCKS5 proxy ==="
if curl -s --connect-timeout 3 --socks5 127.0.0.1:7890 http://www.baidu.com/ -o /dev/null -w "SOCKS5 proxy: HTTP %{http_code}\n"; then
    echo "SOCKS5 proxy OK"
else
    echo "SOCKS5 proxy NOT ready"
fi

echo "=== Step 11: Test curl ==="
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" --max-time 30 http://ipinfo.io/ || echo "curl failed"

echo "=== Step 12: Show logs ==="
echo "--- rust_bridge.log (STATS) ---"
grep "STATS" "$LOG_DIR/rust_bridge.log" 2>/dev/null | tail -3
echo "--- rust_bridge.log (TX DATA) ---"
grep "TX DATA" "$LOG_DIR/rust_bridge.log" 2>/dev/null | head -5
echo "--- rust_bridge.log (SOCKS5) ---"
grep "SOCKS5" "$LOG_DIR/rust_bridge.log" 2>/dev/null | tail -5
echo "--- rust_bridge.log (ERRORS) ---"
grep -i "MISS\|ORPHAN\|ERR\|FAIL\|can_send=false" "$LOG_DIR/rust_bridge.log" 2>/dev/null | head -10

echo "=== Done ==="
