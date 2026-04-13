#!/bin/bash
# BaoLianDeng Stress Test Runner (host side)
# Starts Trojan server + HTTPS server on host, boots VM, runs parallel fetch stress test
#
# Env vars (all optional):
#   SKIP_BUILD=1       Skip framework + app build
#   FILE_COUNT=500     Number of small files to generate
#   FILE_SIZE=4096     Size of each file in bytes
#   CONCURRENCY=50     Number of parallel curl workers
#   HTTPS_PORT=18443   HTTPS server port
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VM_BASE_NAME="bld-e2e-base"
VM_NAME="bld-stress-run-$$"
TROJAN_PID=""
HTTPS_PID=""
DOH_PID=""
VM_PID=""

FILE_COUNT="${FILE_COUNT:-500}"
FILE_SIZE="${FILE_SIZE:-4096}"
CONCURRENCY="${CONCURRENCY:-50}"
HTTPS_PORT="${HTTPS_PORT:-18443}"
DOH_PORT="${DOH_PORT:-18444}"
CERT_DIR="/tmp/stress-test-cert"
TROJAN_CERT_DIR="/tmp/trojan-cert"

source "$SCRIPT_DIR/lib/vm-helpers.sh"

# --- Cleanup trap ---
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    [ -n "$DOH_PID" ] && kill "$DOH_PID" 2>/dev/null && echo "Stopped DoH server (PID $DOH_PID)"
    [ -n "$HTTPS_PID" ] && kill "$HTTPS_PID" 2>/dev/null && echo "Stopped HTTPS server (PID $HTTPS_PID)"
    [ -n "$TROJAN_PID" ] && kill "$TROJAN_PID" 2>/dev/null && echo "Stopped trojan-go (PID $TROJAN_PID)"
    vm_stop "$VM_NAME" 2>/dev/null
    [ -n "$VM_PID" ] && wait "$VM_PID" 2>/dev/null || true
    vm_delete "$VM_NAME" 2>/dev/null
    rm -rf /tmp/stress-test-data /tmp/stress-test-cert /tmp/trojan-cert
}
trap cleanup EXIT

echo "=== BaoLianDeng Stress Test ==="
echo "Project: $PROJECT_DIR"
echo "VM: $VM_NAME (cloned from $VM_BASE_NAME)"
echo "Files: $FILE_COUNT × ${FILE_SIZE}B, Concurrency: $CONCURRENCY"
echo ""

# --- Phase 1: Check prerequisites ---
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

APP_BUILD_PATH=$(find ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Debug -name "BaoLianDeng.app" -maxdepth 1 2>/dev/null | head -1)
if [ -z "$APP_BUILD_PATH" ]; then
    echo "ERROR: Could not find built BaoLianDeng.app in DerivedData"
    exit 1
fi
echo "Built app: $APP_BUILD_PATH"

# --- Phase 3: Start HTTPS server ---
echo ""
echo "--- Phase 3: Start HTTPS server ---"

python3 "$SCRIPT_DIR/https-server.py" \
    --port "$HTTPS_PORT" \
    --file-count "$FILE_COUNT" \
    --file-size "$FILE_SIZE" \
    --cert-dir "$CERT_DIR" \
    --data-dir /tmp/stress-test-data 2>/dev/null &
HTTPS_PID=$!
sleep 2

if lsof -i :"$HTTPS_PORT" -sTCP:LISTEN &>/dev/null; then
    echo "HTTPS server listening on port $HTTPS_PORT (PID $HTTPS_PID)"
else
    echo "ERROR: HTTPS server not listening on port $HTTPS_PORT"
    exit 1
fi

# Verify locally
LOCAL_CHECK=$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1:$HTTPS_PORT/file-0000.bin" 2>/dev/null || echo "000")
if [ "$LOCAL_CHECK" = "200" ]; then
    echo "Local HTTPS check passed"
else
    echo "ERROR: Local HTTPS check failed (HTTP $LOCAL_CHECK)"
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
    echo "ERROR: trojan-go not listening on port 18388"
    exit 1
fi

# --- Phase 5: Boot VM ---
echo ""
echo "--- Phase 5: Boot VM ---"

echo "Cloning base VM..."
tart clone "$VM_BASE_NAME" "$VM_NAME"

vm_start "$VM_NAME"

echo "Getting VM IP..."
VM_IP=$(vm_ip "$VM_NAME" 60)
echo "VM IP: $VM_IP"

wait_for_ssh "$VM_IP" 120
wait_for_gui "$VM_IP" 90

HOST_IP=$(host_ip_for_vm "$VM_IP")
echo "Host IP (from VM): $HOST_IP"

if [ -z "$HOST_IP" ]; then
    echo "ERROR: Could not determine host IP from VM"
    exit 1
fi

# --- Phase 6: Start DoH server (needs HOST_IP) ---
echo ""
echo "--- Phase 6: Start DoH server ---"

# Resolve all hostnames to the host IP so traffic goes through TUN→SS→host.
# Cannot use 127.0.0.1 because localhost is excluded from TUN routes.
python3 "$SCRIPT_DIR/doh-server.py" \
    --port "$DOH_PORT" \
    --resolve-to "$HOST_IP" \
    --cert "$CERT_DIR/cert.pem" \
    --key "$CERT_DIR/key.pem" 2>/dev/null &
DOH_PID=$!
sleep 1

if lsof -i :"$DOH_PORT" -sTCP:LISTEN &>/dev/null; then
    echo "DoH server listening on port $DOH_PORT, resolving to $HOST_IP (PID $DOH_PID)"
else
    echo "ERROR: DoH server not listening on port $DOH_PORT"
    exit 1
fi

# --- Phase 7: Install app and config in VM ---
echo ""
echo "--- Phase 7: Install in VM ---"


echo "Installing app in VM..."
vm_install_app "$VM_IP" "$APP_BUILD_PATH"

echo "Copying test config to VM..."
vm_copy_to "$VM_IP" "$SCRIPT_DIR/config/test-config.yaml" "/tmp/e2e-test-config.yaml"

echo "Copying self-signed cert to VM..."
vm_copy_to "$VM_IP" "$CERT_DIR/cert.pem" "/tmp/stress-test-cert.pem"

echo "Copying stress test script to VM..."
vm_copy_to "$VM_IP" "$SCRIPT_DIR/vm-stress-test.sh" "/tmp/vm-stress-test.sh"
vm_exec "$VM_IP" "chmod +x /tmp/vm-stress-test.sh"

# --- Phase 8: Run stress test ---
echo ""
echo "--- Phase 8: Run stress test ---"
echo ""

vm_exec "$VM_IP" "/tmp/vm-stress-test.sh $HOST_IP $HTTPS_PORT $FILE_COUNT $CONCURRENCY"
TEST_EXIT=$?

# --- Done ---
echo ""
if [ "$TEST_EXIT" -eq 0 ]; then
    echo "=== STRESS TEST PASSED ==="
else
    echo "=== STRESS TEST FOUND FAILURES ==="
fi

exit $TEST_EXIT
