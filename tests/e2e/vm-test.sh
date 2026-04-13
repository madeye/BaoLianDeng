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

# --- Step 2: Set autoConnect sentinel ---
echo "--- Step 2: Create autoConnect sentinel ---"
# Use /tmp which is accessible outside the sandbox
touch /tmp/.bld-autoconnect
echo "Sentinel file at /tmp/.bld-autoconnect"

# --- Step 3: Launch app ---
echo "--- Step 3: Launch app ---"
# Kill any previously running instance (may auto-launch from Login Items in base VM)
killall BaoLianDeng 2>/dev/null && echo "Killed stale instance" && sleep 2
# Record the launch time so we can filter out stale logs from the base VM
LAUNCH_TIME=$(date -u '+%Y-%m-%d %H:%M:%S')
open "$APP_PATH" 2>&1 || true
sleep 5
if pgrep -x BaoLianDeng >/dev/null; then
    APP_PID=$(pgrep -x BaoLianDeng)
    echo "App is running (PID $APP_PID)"
else
    echo "ERROR: App failed to launch. Is auto-login configured?"
    exit 1
fi

# --- Step 4: Wait for VPN manager to be ready ---
echo "--- Step 4: Wait for VPN manager ---"
# Poll the unified log for THIS app instance's "manager ready" message.
# Filter by PID to avoid stale logs from previous runs in the base VM.
VPN_READY=false
for i in $(seq 1 60); do
    if /usr/bin/log show --start "$LAUNCH_TIME" --style compact --predicate "subsystem == 'io.github.baoliandeng' AND category == 'vpn' AND processIdentifier == $APP_PID" 2>/dev/null | grep -q "manager ready"; then
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
    echo "App VPN logs (since launch):"
    /usr/bin/log show --start "$LAUNCH_TIME" --style compact --predicate "subsystem == 'io.github.baoliandeng'" 2>/dev/null | tail -20 || true
    exit 1
fi

# --- Step 5: Wait for autoConnect ---
echo "--- Step 5: Start VPN ---"
# autoConnect triggers after manager ready — check logs
sleep 3
echo "VPN logs since launch:"
/usr/bin/log show --start "$LAUNCH_TIME" --style compact --predicate "subsystem == 'io.github.baoliandeng'" 2>/dev/null | tail -15 || true

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
TRAFFIC=$(curl -s --connect-timeout 5 --max-time 3 http://127.0.0.1:9090/traffic 2>/dev/null | head -1)
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
killall BaoLianDeng 2>/dev/null || true
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
