#!/bin/bash
# In-VM test script for BaoLianDeng E2E tests
# This script runs inside the macOS VM via SSH
# Usage: vm-test.sh <host_ip>
set -e

HOST_IP="${1:?Usage: vm-test.sh <host_ip>}"

VPN_NAME="BaoLianDeng"
APP_PATH="/Applications/BaoLianDeng.app"
CONFIG_DIR="$HOME/Library/Application Support/BaoLianDeng/mihomo"
LOG_DIR="$HOME/Library/Containers/io.github.baoliandeng.macos.TransparentProxy/Data/Library/Application Support/BaoLianDeng"
BUNDLE_ID="io.github.baoliandeng.macos"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

pass() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS: $1"
}

fail() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
}

echo "=== BaoLianDeng E2E Test (in-VM) ==="
echo "Host IP: $HOST_IP"
echo ""

# --- Step 1: Configure ---
echo "--- Step 1: Write config ---"
mkdir -p "$CONFIG_DIR"
sed "s/__HOST_IP__/$HOST_IP/g" /tmp/e2e-test-config.yaml > "$CONFIG_DIR/config.yaml"
echo "Config written to $CONFIG_DIR/config.yaml"

# --- Step 2: Set UserDefaults ---
echo "--- Step 2: Set UserDefaults ---"
defaults write "$BUNDLE_ID" proxyMode -string "global"
defaults write "$BUNDLE_ID" selectedNode -string "e2e-trojan"
echo "Proxy mode: global, node: e2e-trojan"

# --- Step 3: Launch app ---
echo "--- Step 3: Launch app ---"
# Grant accessibility permission for AppleScript (needed to click UI elements)
sudo sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' \
    "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified) VALUES ('kTCCServiceAccessibility', 'com.apple.Terminal', 0, 2, 3, 1, 0, 'UNUSED', 0, $(date +%s));" 2>/dev/null || true
sudo sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' \
    "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified) VALUES ('kTCCServiceAccessibility', '/usr/bin/osascript', 1, 2, 3, 1, 0, 'UNUSED', 0, $(date +%s));" 2>/dev/null || true

# Requires a GUI session (auto-login must be configured in the VM)
open "$APP_PATH" 2>&1 || true
sleep 5
if pgrep -x BaoLianDeng >/dev/null; then
    echo "App is running"
else
    echo "ERROR: App failed to launch. Is auto-login configured?"
    exit 1
fi

# --- Step 4: Wait for VPN manager to be ready ---
echo "--- Step 4: Wait for VPN manager ---"
# NETransparentProxyManager does NOT appear in scutil --nc list.
# Instead, poll the unified log for the app's "loadManager: manager ready" message.
VPN_READY=false
for i in $(seq 1 60); do
    if /usr/bin/log show --last 30s --style compact --predicate 'subsystem == "io.github.baoliandeng" AND category == "vpn"' 2>/dev/null | grep -q "manager ready"; then
        echo "VPN manager ready after ${i}s"
        VPN_READY=true
        break
    fi
    if [ $((i % 15)) -eq 0 ]; then
        echo "Still waiting for VPN manager... ${i}s"
        systemextensionsctl list 2>/dev/null | grep -i bao || true
    fi
    sleep 1
done
if [ "$VPN_READY" = false ]; then
    echo "ERROR: VPN manager not ready after 60s"
    echo "System extensions:"
    systemextensionsctl list 2>/dev/null || true
    echo "App VPN logs:"
    /usr/bin/log show --last 2m --style compact --predicate 'subsystem == "io.github.baoliandeng" AND category == "vpn"' 2>/dev/null | tail -20 || true
    exit 1
fi

# --- Step 5: Start VPN via AppleScript (click the connect toggle) ---
echo "--- Step 5: Start VPN ---"
# NETransparentProxyManager cannot be started via scutil --nc start.
# Use AppleScript to toggle the connection through the app's UI.
# The toggle is a SwiftUI Toggle (.switch style) in the toolbar.
osascript -e '
tell application "BaoLianDeng" to activate
delay 1
tell application "System Events"
    tell process "BaoLianDeng"
        set frontmost to true
        delay 0.5
        -- Find the toggle switch (checkbox) in the toolbar
        try
            set allCheckboxes to every checkbox of first toolbar of first window
            if (count of allCheckboxes) > 0 then
                click first item of allCheckboxes
            end if
        end try
        -- Also try: checkbox inside a group in the toolbar
        try
            repeat with g in (every group of first toolbar of first window)
                set cbs to every checkbox of g
                if (count of cbs) > 0 then
                    click first item of cbs
                    exit repeat
                end if
            end repeat
        end try
    end tell
end tell
' 2>&1 || echo "WARNING: AppleScript toggle failed"

# Give the VPN a moment to start
sleep 3

# --- Step 6: Wait for engine (mihomo REST API) ---
echo "--- Step 6: Wait for engine ---"
ENGINE_READY=false
for i in $(seq 1 45); do
    # Check if mihomo external controller is responding
    if curl -s --connect-timeout 2 http://127.0.0.1:9090/version 2>/dev/null | grep -q "version"; then
        echo "Engine ready after ${i}s"
        ENGINE_READY=true
        sleep 2  # Extra wait for SOCKS5 listener
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then
        echo "Still waiting for engine... ${i}s"
    fi
    sleep 1
done
if [ "$ENGINE_READY" = false ]; then
    echo "WARNING: Engine not responding after 45s"
    echo "Checking SOCKS5 port..."
    lsof -i :7890 -sTCP:LISTEN 2>/dev/null || echo "SOCKS5 port 7890 not listening"
fi

# --- Step 7: Run verifications ---
echo ""
echo "=== Verification ==="

# Test 1: SOCKS5 proxy
echo "--- Test: SOCKS5 proxy ---"
SOCKS_STATUS=$(curl -s --connect-timeout 10 --max-time 15 --socks5 127.0.0.1:7890 -o /dev/null -w "%{http_code}" http://httpbin.org/ip 2>/dev/null || echo "000")
if [ "$SOCKS_STATUS" = "200" ]; then
    pass "SOCKS5 proxy (HTTP $SOCKS_STATUS)"
else
    fail "SOCKS5 proxy (HTTP $SOCKS_STATUS)"
fi

# Test 2: Transparent proxy routing (curl without explicit proxy — traffic goes through transparent proxy)
echo "--- Test: Transparent proxy routing ---"
PROXY_STATUS=$(curl -s --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" http://httpbin.org/ip 2>/dev/null || echo "000")
if [ "$PROXY_STATUS" = "200" ]; then
    pass "Transparent proxy routing (HTTP $PROXY_STATUS)"
else
    fail "Transparent proxy routing (HTTP $PROXY_STATUS)"
fi

# Test 3: Traffic stats via external controller
echo "--- Test: Traffic stats ---"
TRAFFIC=$(curl -s --connect-timeout 5 http://127.0.0.1:9090/traffic 2>/dev/null | head -1)
if [ -n "$TRAFFIC" ]; then
    pass "Traffic stats endpoint responding ($TRAFFIC)"
else
    fail "Traffic stats endpoint not responding"
fi

# Test 4: System extension is active
echo "--- Test: System extension ---"
SYSEXT=$(systemextensionsctl list 2>/dev/null | grep -c "activated enabled" || echo "0")
if [ "$SYSEXT" -gt 0 ]; then
    pass "System extension is activated and enabled"
else
    fail "System extension not active"
fi

# Test 5: DNS resolution via tunnel
echo "--- Test: DNS resolution ---"
DNS_RESULT=$(nslookup example.com 2>/dev/null || true)
if echo "$DNS_RESULT" | grep -q "Address"; then
    pass "DNS resolution works through tunnel"
else
    fail "DNS resolution failed"
fi

# --- Step 8: Stop VPN ---
echo ""
echo "--- Cleanup: Stop VPN ---"
# Use AppleScript to toggle VPN off (scutil --nc stop doesn't work for transparent proxies)
osascript -e '
tell application "System Events"
    tell process "BaoLianDeng"
        set tbGroup to first group of first toolbar of first window
        repeat with cb in (every checkbox of tbGroup)
            click cb
            exit repeat
        end repeat
    end tell
end tell
' 2>/dev/null || true
sleep 1

# --- Results ---
echo ""
echo "================================"
echo "  Results: $TESTS_PASSED/$TESTS_TOTAL passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "  $TESTS_FAILED FAILED"
    echo "================================"
    exit 1
else
    echo "  All tests passed!"
    echo "================================"
    exit 0
fi
