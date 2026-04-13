#!/bin/bash
# BaoLianDeng E2E Test Runner (host side)
# Builds app, boots macOS VM with SIP disabled, installs, starts VPN, verifies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VM_BASE_NAME="bld-e2e-base"
VM_NAME="bld-e2e-run-$$"
TROJAN_PID=""
FALLBACK_PID=""
VM_PID=""
TROJAN_CERT_DIR="/tmp/trojan-cert"
FALLBACK_PORT="18080"

source "$SCRIPT_DIR/lib/vm-helpers.sh"

# --- Cleanup trap ---
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    [ -n "$TROJAN_PID" ] && kill "$TROJAN_PID" 2>/dev/null && echo "Stopped trojan-go (PID $TROJAN_PID)"
    [ -n "$FALLBACK_PID" ] && kill "$FALLBACK_PID" 2>/dev/null && echo "Stopped fallback HTTP (PID $FALLBACK_PID)"
    vm_stop "$VM_NAME" 2>/dev/null
    [ -n "$VM_PID" ] && wait "$VM_PID" 2>/dev/null || true
    vm_delete "$VM_NAME" 2>/dev/null
    rm -rf "$TROJAN_CERT_DIR"
}
trap cleanup EXIT

echo "=== BaoLianDeng E2E Test ==="
echo "Project: $PROJECT_DIR"
echo "VM: $VM_NAME (cloned from $VM_BASE_NAME)"
echo ""

# --- Phase 1: Check prerequisites ---
echo "--- Phase 1: Prerequisites ---"

if ! command -v tart &>/dev/null; then
    echo "ERROR: tart not found. Run: brew install cirruslabs/cli/tart"
    exit 1
fi

if ! command -v trojan-go &>/dev/null; then
    echo "ERROR: trojan-go not found. Run: brew install trojan-go"
    exit 1
fi

if ! tart list 2>/dev/null | grep -q "$VM_BASE_NAME"; then
    echo "ERROR: Base VM '$VM_BASE_NAME' not found."
    echo "Run the setup script first: ./tests/e2e/vm-setup.sh"
    exit 1
fi

echo "Prerequisites OK"

# --- Phase 2: Build on host ---
echo ""
echo "--- Phase 2: Build on host ---"
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

# Locate built .app
APP_BUILD_PATH=$(find ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Debug -name "BaoLianDeng.app" -maxdepth 1 2>/dev/null | head -1)
if [ -z "$APP_BUILD_PATH" ]; then
    echo "ERROR: Could not find built BaoLianDeng.app in DerivedData"
    exit 1
fi
echo "Built app: $APP_BUILD_PATH"

# --- Phase 3: Start Trojan server ---
echo ""
echo "--- Phase 3: Start Trojan server ---"

# Generate self-signed cert for trojan-go
mkdir -p "$TROJAN_CERT_DIR"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$TROJAN_CERT_DIR/key.pem" -out "$TROJAN_CERT_DIR/cert.pem" \
    -days 1 -nodes -subj "/CN=e2e-trojan" 2>/dev/null
echo "Generated trojan-go TLS certificate"

# Start a minimal fallback HTTP server (trojan-go requires a valid fallback)
python3 -m http.server "$FALLBACK_PORT" --directory /tmp &>/dev/null &
FALLBACK_PID=$!
sleep 1

sed -e "s|__CERT_DIR__|$TROJAN_CERT_DIR|g" -e "s|__FALLBACK_PORT__|$FALLBACK_PORT|g" \
    "$SCRIPT_DIR/config/trojan-server-config.json" > /tmp/trojan-server-config.json

trojan-go -config /tmp/trojan-server-config.json &
TROJAN_PID=$!
sleep 1

if lsof -i :18388 -sTCP:LISTEN &>/dev/null; then
    echo "trojan-go listening on port 18388 (PID $TROJAN_PID)"
else
    echo "ERROR: trojan-go not listening on port 18388"
    exit 1
fi

# --- Phase 4: Boot VM ---
echo ""
echo "--- Phase 4: Boot VM ---"

echo "Cloning base VM..."
tart clone "$VM_BASE_NAME" "$VM_NAME"

vm_start "$VM_NAME"

echo "Getting VM IP..."
VM_IP=$(vm_ip "$VM_NAME" 60)
echo "VM IP: $VM_IP"

wait_for_ssh "$VM_IP" 120
wait_for_gui "$VM_IP" 90

# Discover host IP from VM's perspective
HOST_IP=$(host_ip_for_vm "$VM_IP")
echo "Host IP (from VM): $HOST_IP"

if [ -z "$HOST_IP" ]; then
    echo "ERROR: Could not determine host IP from VM"
    exit 1
fi

# --- Phase 5: Install app and config in VM ---
echo ""
echo "--- Phase 5: Install in VM ---"

# Kill any auto-launched app instance from the base VM before replacing the binary
vm_exec "$VM_IP" "killall BaoLianDeng 2>/dev/null || true"

echo "Installing app in VM..."
vm_install_app "$VM_IP" "$APP_BUILD_PATH"

echo "Copying test config to VM..."
vm_copy_to "$VM_IP" "$SCRIPT_DIR/config/test-config.yaml" "/tmp/e2e-test-config.yaml"

echo "Copying test script to VM..."
vm_copy_to "$VM_IP" "$SCRIPT_DIR/vm-test.sh" "/tmp/vm-test.sh"
vm_exec "$VM_IP" "chmod +x /tmp/vm-test.sh"

# --- Phase 6: Run tests in VM ---
echo ""
echo "--- Phase 6: Run tests ---"
echo ""

vm_exec "$VM_IP" "/tmp/vm-test.sh $HOST_IP"
TEST_EXIT=$?

# --- Done ---
echo ""
if [ "$TEST_EXIT" -eq 0 ]; then
    echo "=== E2E TEST PASSED ==="
else
    echo "=== E2E TEST FAILED ==="
fi

exit $TEST_EXIT
