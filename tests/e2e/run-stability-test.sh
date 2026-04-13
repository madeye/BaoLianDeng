#!/bin/bash
# BaoLianDeng Stability Test Runner (host side)
# Long-running test simulating human browsing behavior through the VPN tunnel.
#
# Env vars (all optional):
#   SKIP_BUILD=1        Skip framework + app build
#   DURATION=10         Test duration in minutes (default: 10)
#   HTTPS_PORT=18443    HTTPS server port
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VM_BASE_NAME="bld-e2e-base"
VM_NAME="bld-stability-run-$$"
TROJAN_PID=""
HTTPS_PID=""
VM_PID=""

DURATION="${DURATION:-10}"
HTTPS_PORT="${HTTPS_PORT:-18443}"
CERT_DIR="/tmp/stress-test-cert"
TROJAN_CERT_DIR="/tmp/trojan-cert"

source "$SCRIPT_DIR/lib/vm-helpers.sh"

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    [ -n "$HTTPS_PID" ] && kill "$HTTPS_PID" 2>/dev/null && echo "Stopped HTTPS server (PID $HTTPS_PID)"
    [ -n "$TROJAN_PID" ] && kill "$TROJAN_PID" 2>/dev/null && echo "Stopped trojan-go (PID $TROJAN_PID)"
    vm_stop "$VM_NAME" 2>/dev/null
    [ -n "$VM_PID" ] && wait "$VM_PID" 2>/dev/null || true
    vm_delete "$VM_NAME" 2>/dev/null
    rm -rf /tmp/stress-test-data /tmp/stress-test-cert /tmp/trojan-cert
}
trap cleanup EXIT

echo "=== BaoLianDeng Stability Test ==="
echo "Project: $PROJECT_DIR"
echo "VM: $VM_NAME (cloned from $VM_BASE_NAME)"
echo "Duration: ${DURATION}m"
echo ""

# --- Phase 1: Prerequisites ---
echo "--- Phase 1: Prerequisites ---"
for cmd in tart trojan-go python3 openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found"
        exit 1
    fi
done
if ! tart list 2>/dev/null | grep -q "$VM_BASE_NAME"; then
    echo "ERROR: Base VM '$VM_BASE_NAME' not found. Run: make e2e-setup"
    exit 1
fi
echo "Prerequisites OK"

# --- Phase 2: Build ---
echo ""
echo "--- Phase 2: Build ---"
cd "$PROJECT_DIR"
SKIP_BUILD="${SKIP_BUILD:-}"
if [ -z "$SKIP_BUILD" ]; then
    echo "Building framework..."
    make framework
    echo "Building app (Debug)..."
    rm -rf ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*
    xcodebuild build \
        -project BaoLianDeng.xcodeproj \
        -scheme BaoLianDeng \
        -configuration Debug \
        -destination 'platform=macOS' 2>&1 | tail -5
else
    echo "Skipping build (SKIP_BUILD set)"
fi

APP_BUILD_PATH=$(find ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Debug -name "BaoLianDeng.app" -maxdepth 1 2>/dev/null | head -1)
if [ -z "$APP_BUILD_PATH" ]; then
    echo "ERROR: Could not find built BaoLianDeng.app"
    exit 1
fi
echo "Built app: $APP_BUILD_PATH"

# --- Phase 3: Start HTTPS server ---
echo ""
echo "--- Phase 3: Start HTTPS server ---"
# 500 files of mixed sizes (1KB-64KB) to simulate real web resources
python3 "$SCRIPT_DIR/https-server.py" \
    --port "$HTTPS_PORT" \
    --file-count 500 \
    --file-size 4096 \
    --cert-dir "$CERT_DIR" \
    --data-dir /tmp/stress-test-data 2>/dev/null &
HTTPS_PID=$!
sleep 2
if lsof -i :"$HTTPS_PORT" -sTCP:LISTEN &>/dev/null; then
    echo "HTTPS server listening on port $HTTPS_PORT (PID $HTTPS_PID)"
else
    echo "ERROR: HTTPS server not listening"
    exit 1
fi

# --- Phase 4: Start Trojan server ---
echo ""
echo "--- Phase 4: Start Trojan server ---"

# Generate self-signed cert for trojan-go
mkdir -p "$TROJAN_CERT_DIR"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$TROJAN_CERT_DIR/key.pem" -out "$TROJAN_CERT_DIR/cert.pem" \
    -days 1 -nodes -subj "/CN=e2e-trojan" 2>/dev/null
echo "Generated trojan-go TLS certificate"

# Create trojan-go config (uses HTTPS server as TLS fallback)
sed -e "s|__CERT_DIR__|$TROJAN_CERT_DIR|g" -e "s|__FALLBACK_PORT__|$HTTPS_PORT|g" \
    "$SCRIPT_DIR/config/trojan-server-config.json" > /tmp/trojan-server-config.json

trojan-go -config /tmp/trojan-server-config.json &
TROJAN_PID=$!
sleep 1
if lsof -i :18388 -sTCP:LISTEN &>/dev/null; then
    echo "trojan-go listening on port 18388 (PID $TROJAN_PID)"
else
    echo "ERROR: trojan-go not listening"
    exit 1
fi

# --- Phase 5: Boot VM ---
echo ""
echo "--- Phase 5: Boot VM ---"
tart clone "$VM_BASE_NAME" "$VM_NAME"
vm_start "$VM_NAME"
VM_IP=$(vm_ip "$VM_NAME" 60)
echo "VM IP: $VM_IP"
wait_for_ssh "$VM_IP" 120
wait_for_gui "$VM_IP" 90

HOST_IP=$(host_ip_for_vm "$VM_IP")
echo "Host IP: $HOST_IP"
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Could not determine host IP"
    exit 1
fi

# --- Phase 6: Install ---
echo ""
echo "--- Phase 6: Install in VM ---"
vm_install_app "$VM_IP" "$APP_BUILD_PATH"
vm_copy_to "$VM_IP" "$SCRIPT_DIR/config/test-config.yaml" "/tmp/e2e-test-config.yaml"
vm_copy_to "$VM_IP" "$CERT_DIR/cert.pem" "/tmp/stress-test-cert.pem"
vm_copy_to "$VM_IP" "$SCRIPT_DIR/vm-stability-test.sh" "/tmp/vm-stability-test.sh"
vm_exec "$VM_IP" "chmod +x /tmp/vm-stability-test.sh"

# --- Phase 7: Run stability test ---
echo ""
echo "--- Phase 7: Run stability test (${DURATION}m) ---"
echo ""

vm_exec "$VM_IP" "/tmp/vm-stability-test.sh $HOST_IP $HTTPS_PORT $DURATION"
TEST_EXIT=$?

echo ""
if [ "$TEST_EXIT" -eq 0 ]; then
    echo "=== STABILITY TEST PASSED ==="
else
    echo "=== STABILITY TEST FOUND FAILURES ==="
fi

exit $TEST_EXIT
