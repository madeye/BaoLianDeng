#!/bin/bash
# In-VM stress test for BaoLianDeng
# Runs parallel HTTPS fetches through VPN tunnel to reproduce connection failures
# Usage: vm-stress-test.sh <host_ip> [https_port] [file_count] [concurrency]
set -e

HOST_IP="${1:?Usage: vm-stress-test.sh <host_ip> [https_port] [file_count] [concurrency]}"
HTTPS_PORT="${2:-18443}"
FILE_COUNT="${3:-500}"
CONCURRENCY="${4:-50}"

VPN_NAME="BaoLianDeng"
APP_PATH="/Applications/BaoLianDeng.app"
CONFIG_DIR="$HOME/Library/Application Support/BaoLianDeng/mihomo"
LOG_DIR="$HOME/Library/Containers/io.github.baoliandeng.macos.TransparentProxy/Data/Library/Application Support/BaoLianDeng"
BUNDLE_ID="io.github.baoliandeng.macos"

CERT_PATH="/tmp/stress-test-cert.pem"
RESULT_DIR="/tmp/stress-test-results"

echo "=== BaoLianDeng Stress Test (in-VM) ==="
echo "Host: $HOST_IP:$HTTPS_PORT"
echo "Files: $FILE_COUNT, Concurrency: $CONCURRENCY"
echo ""

# --- Step 1: Configure ---
echo "--- Step 1: Write config ---"
mkdir -p "$CONFIG_DIR"
sed "s/__HOST_IP__/$HOST_IP/g" /tmp/e2e-test-config.yaml > "$CONFIG_DIR/config.yaml"
echo "Config written"

# --- Step 2: Set UserDefaults ---
echo "--- Step 2: Set UserDefaults ---"
defaults write "$BUNDLE_ID" proxyMode -string "global"
defaults write "$BUNDLE_ID" selectedNode -string "e2e-trojan"
echo "Proxy mode: global, node: e2e-trojan"

# --- Step 3: Launch app ---
echo "--- Step 3: Launch app ---"
open "$APP_PATH" 2>&1 || true
sleep 5
if pgrep -x BaoLianDeng >/dev/null; then
    echo "App is running"
else
    echo "ERROR: App failed to launch"
    exit 1
fi

# --- Step 4: Wait for VPN config ---
echo "--- Step 4: Wait for VPN config ---"
VPN_REGISTERED=false
for i in $(seq 1 90); do
    if scutil --nc list 2>/dev/null | grep -q "$VPN_NAME"; then
        echo "VPN config registered after ${i}s"
        VPN_REGISTERED=true
        break
    fi
    [ $((i % 15)) -eq 0 ] && echo "Still waiting... ${i}s"
    sleep 1
done
if [ "$VPN_REGISTERED" = false ]; then
    echo "ERROR: VPN configuration not found after 90s"
    exit 1
fi

# --- Step 5: Start VPN ---
echo "--- Step 5: Start VPN ---"
scutil --nc start "$VPN_NAME" || true

VPN_CONNECTED=false
for i in $(seq 1 30); do
    status=$(scutil --nc status "$VPN_NAME" 2>&1 | head -1)
    if [ "$status" = "Connected" ]; then
        echo "VPN connected after ${i}s"
        VPN_CONNECTED=true
        break
    fi
    sleep 1
done
if [ "$VPN_CONNECTED" = false ]; then
    echo "ERROR: VPN did not connect after 30s"
    exit 1
fi

# --- Step 6: Wait for engine ---
echo "--- Step 6: Wait for engine ---"
LOG_FILE="$LOG_DIR/rust_bridge.log"
ENGINE_READY=false
for i in $(seq 1 30); do
    if [ -f "$LOG_FILE" ] && \
       grep -q "meow engine started" "$LOG_FILE" 2>/dev/null || \
       grep -q "engine started successfully" "$LOG_FILE" 2>/dev/null; then
        echo "Engine ready after ${i}s"
        ENGINE_READY=true
        sleep 3
        break
    fi
    sleep 1
done
if [ "$ENGINE_READY" = false ]; then
    echo "WARNING: Engine readiness signals not found after 30s, continuing anyway"
fi

# --- Step 7: Quick sanity check ---
echo "--- Step 7: Sanity check ---"
SANITY=$(curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" \
    --resolve "sanity.stress-test.internal:$HTTPS_PORT:$HOST_IP" \
    "https://sanity.stress-test.internal:$HTTPS_PORT/file-0000.bin" 2>/dev/null || echo "000")
if [ "$SANITY" = "200" ]; then
    echo "Sanity check passed (hostname via --resolve through TUN)"
else
    echo "ERROR: Sanity check failed (HTTP $SANITY). Trying plain IP..."
    SANITY=$(curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" "https://$HOST_IP:$HTTPS_PORT/file-0000.bin" --cacert "$CERT_PATH" 2>/dev/null || echo "000")
    if [ "$SANITY" = "200" ]; then
        echo "Direct IP works but hostname resolve failed"
    else
        echo "ERROR: Cannot reach HTTPS server. Aborting."
        exit 1
    fi
fi

# --- Step 8: Stress test ---
echo ""
echo "=== Stress Test: $FILE_COUNT files, $CONCURRENCY concurrent ==="
echo ""

rm -rf "$RESULT_DIR"
mkdir -p "$RESULT_DIR"

START_TIME=$(date +%s)

# Write a small worker script to avoid xargs command-line length issues
# Each request uses a unique hostname resolved via --resolve to the host IP.
# This exercises unique TCP connections through TUN → tun2socks → SOCKS5 → SS.
WORKER="/tmp/stress-worker.sh"
cat > "$WORKER" <<'WORKEREOF'
#!/bin/bash
idx=$(printf "%04d" "$1")
hostname="file-${idx}.stress-test.internal"
url="https://${hostname}:${STRESS_PORT}/file-${idx}.bin"
result=$(curl -sk --connect-timeout 10 --max-time 30 -o /dev/null \
    -w "%{http_code} %{time_total} %{size_download}" \
    --resolve "${hostname}:${STRESS_PORT}:${STRESS_HOST}" \
    "$url" 2>/dev/null)
exit_code=$?
echo "${idx} ${exit_code} ${result}" >> "${STRESS_RESULT_DIR}/batch-$$.log"
WORKEREOF
chmod +x "$WORKER"

export STRESS_HOST="$HOST_IP"
export STRESS_PORT="$HTTPS_PORT"
export STRESS_RESULT_DIR="$RESULT_DIR"

seq 0 $((FILE_COUNT - 1)) | xargs -P "$CONCURRENCY" -I{} bash "$WORKER" {}

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# --- Step 9: Analyze results ---
echo ""
echo "=== Results ==="
echo "Duration: ${ELAPSED}s"

# Merge all batch logs
cat "$RESULT_DIR"/batch-*.log 2>/dev/null | sort > "$RESULT_DIR/all.log"

TOTAL=$(wc -l < "$RESULT_DIR/all.log" | tr -d ' ')
SUCCESS=$(awk '$2 == 0 && $3 == 200' "$RESULT_DIR/all.log" | wc -l | tr -d ' ')
CURL_ERRORS=$(awk '$2 != 0' "$RESULT_DIR/all.log" | wc -l | tr -d ' ')
HTTP_ERRORS=$(awk '$2 == 0 && $3 != 200' "$RESULT_DIR/all.log" | wc -l | tr -d ' ')

echo "Total requests: $TOTAL"
echo "Successful (HTTP 200): $SUCCESS"
echo "Curl errors (connection/timeout): $CURL_ERRORS"
echo "HTTP errors (non-200): $HTTP_ERRORS"

if [ "$TOTAL" -gt 0 ]; then
    SUCCESS_RATE=$(awk "BEGIN {printf \"%.1f\", ($SUCCESS / $TOTAL) * 100}")
    echo "Success rate: ${SUCCESS_RATE}%"
fi

# Show timing stats
if [ "$SUCCESS" -gt 0 ]; then
    echo ""
    echo "--- Timing (successful requests) ---"
    awk '$2 == 0 && $3 == 200 {print $4}' "$RESULT_DIR/all.log" | sort -n | awk '
    {a[NR]=$1; sum+=$1}
    END {
        printf "  Min:    %.3fs\n", a[1]
        printf "  Median: %.3fs\n", a[int(NR/2)+1]
        printf "  P95:    %.3fs\n", a[int(NR*0.95)+1]
        printf "  Max:    %.3fs\n", a[NR]
        printf "  Avg:    %.3fs\n", sum/NR
    }'
fi

# Show error details
if [ "$CURL_ERRORS" -gt 0 ]; then
    echo ""
    echo "--- Curl error breakdown ---"
    awk '$2 != 0 {print $2}' "$RESULT_DIR/all.log" | sort | uniq -c | sort -rn | while read count code; do
        case "$code" in
            7)  desc="Connection refused" ;;
            28) desc="Timeout" ;;
            35) desc="SSL connect error" ;;
            52) desc="Empty reply from server" ;;
            56) desc="Recv failure" ;;
            *)  desc="curl error $code" ;;
        esac
        echo "  $count × $desc (exit $code)"
    done
fi

if [ "$HTTP_ERRORS" -gt 0 ]; then
    echo ""
    echo "--- HTTP error breakdown ---"
    awk '$2 == 0 && $3 != 200 {print $3}' "$RESULT_DIR/all.log" | sort | uniq -c | sort -rn | while read count code; do
        echo "  $count × HTTP $code"
    done
fi

# Show sample failures
if [ "$((CURL_ERRORS + HTTP_ERRORS))" -gt 0 ]; then
    echo ""
    echo "--- First 10 failures ---"
    awk '$2 != 0 || ($2 == 0 && $3 != 200)' "$RESULT_DIR/all.log" | head -10
fi

# --- Cleanup ---
echo ""
echo "--- Cleanup: Stop VPN ---"
scutil --nc stop "$VPN_NAME" 2>/dev/null || true

echo ""
echo "================================"
if [ "$CURL_ERRORS" -gt 0 ] || [ "$HTTP_ERRORS" -gt 0 ]; then
    echo "  STRESS TEST: ${SUCCESS}/${TOTAL} succeeded (${CURL_ERRORS} conn errors, ${HTTP_ERRORS} HTTP errors)"
    echo "================================"
    exit 1
else
    echo "  STRESS TEST: ${TOTAL}/${TOTAL} all passed!"
    echo "================================"
    exit 0
fi
