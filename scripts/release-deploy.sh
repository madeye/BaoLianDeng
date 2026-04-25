#!/bin/bash
# Build a Release configuration of BaoLianDeng, install to /Applications,
# launch, and start the VPN. Mirrors dev-deploy.sh but uses Release config.
#
# This skips Developer ID re-signing, notarization, and PKG packaging — it
# uses the Release build's default signing (whatever Xcode auto-selects with
# DEVELOPMENT_TEAM from Local.xcconfig). Suitable for verifying Release-config
# behavior locally; NOT a distribution build (use build-release-pkg.sh for
# that).
#
# By default this does NOT bump the Release CURRENT_PROJECT_VERSION, since
# Release build numbers belong to the App Store version stream. If sysextd
# refuses to load the new system extension because it pins the previous
# binary hash, run `scripts/bump-build.sh release` before re-running.
set -e

VPN_NAME="BaoLianDeng"
APP_PATH="/Applications/BaoLianDeng.app"
PROJECT_DIR="/Volumes/DATA/workspace/BaoLianDeng"
LOG_DIR="$HOME/Library/Containers/io.github.baoliandeng.macos.TransparentProxy/Data/Library/Application Support/BaoLianDeng"

cd "$PROJECT_DIR"

echo "=== Step 1: Stop VPN ==="
scutil --nc stop "$VPN_NAME" 2>/dev/null || true
sleep 2

echo "=== Step 2: Quit app ==="
osascript -e 'tell application "BaoLianDeng" to quit' 2>/dev/null || true
sleep 1

echo "=== Step 3: Build framework ==="
make framework

echo "=== Step 4: Build app (Release) ==="
rm -rf ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*
xcodebuild build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Release \
  -destination 'platform=macOS' 2>&1 | tail -3

echo "=== Step 5: Install ==="
# Use sudo because a previously PKG-installed copy is owned by root.
# This will prompt for a password the first time per sudo session.
sudo rm -rf "$APP_PATH"
sudo cp -R ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Release/BaoLianDeng.app "$APP_PATH"
sudo chown -R "$USER":staff "$APP_PATH"

echo "=== Step 6: Launch app ==="
open "$APP_PATH"
sleep 2

echo "=== Step 7: Start VPN ==="
scutil --nc start "$VPN_NAME"
for i in $(seq 1 15); do
    status=$(scutil --nc status "$VPN_NAME" 2>&1 | head -1)
    if [ "$status" = "Connected" ]; then
        echo "VPN connected after ${i}s"
        break
    fi
    sleep 1
done

echo "=== Step 8: Wait for tunnel + mihomo startup ==="
LOG_FILE="$LOG_DIR/rust_bridge.log"
for i in $(seq 1 30); do
    if grep -q "engine started successfully" "$LOG_FILE" 2>/dev/null && \
       grep -q "packet_thread: entering main loop" "$LOG_FILE" 2>/dev/null; then
        echo "Tunnel ready after ${i}s"
        sleep 3
        break
    fi
    sleep 1
done

echo "=== Step 9: Verify SOCKS5 proxy ==="
if curl -s --connect-timeout 3 --socks5 127.0.0.1:7890 http://www.baidu.com/ -o /dev/null -w "SOCKS5 proxy: HTTP %{http_code}\n"; then
    echo "SOCKS5 proxy OK"
else
    echo "SOCKS5 proxy NOT ready"
fi

echo "=== Step 10: Test curl ==="
curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" --max-time 30 http://ipinfo.io/ || echo "curl failed"

echo "=== Done ==="
