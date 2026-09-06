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
# Release build numbers belong to the App Store version stream. The provider
# ships as an app extension (`PlugIns/TransparentProxy.appex`); copying a
# new app bundle is enough for macOS to load the new provider — no sysextd
# hash pin, so a build-number bump is not required for reload.
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

echo "=== Step 3: Build framework ==="
make framework

echo "=== Step 4: Build and install app (Release) ==="
rm -rf ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*
# build_and_install_app validates and stages the freshly built bundle before
# touching the installed app — a failed or incomplete build must never
# remove a working install (issue #113 finding 3).
if ! build_and_install_app \
  '$HOME/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Release/BaoLianDeng.app' \
  "$APP_PATH" 3 "Contents/PlugIns/TransparentProxy.appex" -- \
  build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Release \
  -destination 'platform=macOS'; then
    exit 1
fi

echo "=== Step 5: Launch app ==="
# Sentinel makes VPNManager.start() after the NE manager is ready — more
# reliable for an app-extension provider than scutil --nc, which can race
# before the configuration is registered.
touch /tmp/.bld-autoconnect
open "$APP_PATH"
sleep 3

echo "=== Step 6: Start VPN ==="
scutil --nc start "$VPN_NAME" 2>/dev/null || true
CONNECTED=0
for i in $(seq 1 30); do
    vpnstatus=$(scutil --nc status "$VPN_NAME" 2>&1 | head -1)
    if [ "$vpnstatus" = "Connected" ]; then
        echo "VPN connected after ${i}s"
        CONNECTED=1
        break
    fi
    if pgrep -f 'PlugIns/TransparentProxy.appex' >/dev/null 2>&1; then
        echo "VPN connected after ${i}s (app extension running)"
        CONNECTED=1
        break
    fi
    sleep 1
done
if [ "$CONNECTED" -eq 0 ]; then
    echo "WARNING: VPN did not report connected within 30s"
fi

echo "=== Step 7: Wait for tunnel + meow engine startup ==="
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

echo "=== Step 8: Verify SOCKS5 proxy ==="
if curl -s --connect-timeout 3 --socks5 127.0.0.1:7890 http://www.baidu.com/ -o /dev/null -w "SOCKS5 proxy: HTTP %{http_code}\n"; then
    echo "SOCKS5 proxy OK"
else
    echo "SOCKS5 proxy NOT ready"
fi

echo "=== Step 9: Test curl ==="
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 http://ipinfo.io/ || echo "000")
if ! [ "$HTTP" -ge 200 ] 2>/dev/null || [ "$HTTP" -ge 300 ]; then
    ADDR=$(defaults read io.github.baoliandeng.macos externalControllerAddr 2>/dev/null || true)
    SECRET=$(defaults read io.github.baoliandeng.macos externalControllerSecret 2>/dev/null || true)
    if [ -n "$ADDR" ]; then
        echo "Transparent fetch HTTP $HTTP; retrying in direct mode"
        curl -s --max-time 5 -X PATCH \
            -H "Authorization: Bearer $SECRET" \
            -H "Content-Type: application/json" \
            -d '{"mode":"direct"}' "http://${ADDR}/configs" >/dev/null || true
        sleep 1
    fi
    curl -s -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" --max-time 30 http://ipinfo.io/ || echo "curl failed"
else
    echo "HTTP ${HTTP}"
fi

echo "=== Done ==="
