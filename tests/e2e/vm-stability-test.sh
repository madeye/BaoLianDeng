#!/bin/bash
# In-VM stability test for BaoLianDeng
# Simulates human browsing: periodic "page loads" with random think time.
# Each page load fetches 5-15 resources concurrently (like a browser loading a page).
# Runs for DURATION minutes, reports failures in real-time.
#
# Usage: vm-stability-test.sh <host_ip> [https_port] [duration_min]
set -e

HOST_IP="${1:?Usage: vm-stability-test.sh <host_ip> [https_port] [duration_min]}"
HTTPS_PORT="${2:-18443}"
DURATION_MIN="${3:-10}"

VPN_NAME="BaoLianDeng"
APP_PATH="/Applications/BaoLianDeng.app"
CONFIG_DIR="$HOME/Library/Application Support/BaoLianDeng/mihomo"
BUNDLE_ID="io.github.baoliandeng.macos"

RESULT_DIR="/tmp/stability-test-results"
LOG_FILE="$RESULT_DIR/timeline.log"

echo "=== BaoLianDeng Stability Test (in-VM) ==="
echo "Host: $HOST_IP:$HTTPS_PORT"
echo "Duration: ${DURATION_MIN}m"
echo ""

# --- Setup VPN (same as stress test) ---
echo "--- Setting up VPN ---"
mkdir -p "$CONFIG_DIR"
sed "s/__HOST_IP__/$HOST_IP/g" /tmp/e2e-test-config.yaml > "$CONFIG_DIR/config.yaml"
defaults write "$BUNDLE_ID" proxyMode -string "global"
# Per-group selections are scoped by subscription; the E2E config is
# hand-written with no subscription selected, hence the __none__ scope.
defaults write "$BUNDLE_ID" proxyGroupSelectionsBySubscription \
    -dict-add "__none__" '{ "GLOBAL" = "e2e-trojan"; }'

open "$APP_PATH" 2>&1 || true
sleep 5
if ! pgrep -x BaoLianDeng >/dev/null; then
    echo "ERROR: App failed to launch"
    exit 1
fi
echo "App running"

# Wait for VPN
VPN_REGISTERED=false
for i in $(seq 1 90); do
    if scutil --nc list 2>/dev/null | grep -q "$VPN_NAME"; then
        VPN_REGISTERED=true
        break
    fi
    sleep 1
done
if [ "$VPN_REGISTERED" = false ]; then
    echo "ERROR: VPN config not found after 90s"
    exit 1
fi
echo "VPN config registered"

scutil --nc start "$VPN_NAME" || true
VPN_CONNECTED=false
for i in $(seq 1 30); do
    status=$(scutil --nc status "$VPN_NAME" 2>&1 | head -1)
    if [ "$status" = "Connected" ]; then
        VPN_CONNECTED=true
        break
    fi
    sleep 1
done
if [ "$VPN_CONNECTED" = false ]; then
    echo "ERROR: VPN did not connect"
    exit 1
fi
echo "VPN connected"
sleep 5

# --- Sanity check ---
SANITY=$(curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" \
    --resolve "sanity.test:$HTTPS_PORT:$HOST_IP" \
    "https://sanity.test:$HTTPS_PORT/file-0000.bin" 2>/dev/null || echo "000")
if [ "$SANITY" != "200" ]; then
    echo "ERROR: Sanity check failed (HTTP $SANITY)"
    exit 1
fi
echo "Sanity check passed"
echo ""

# --- Stability test ---
rm -rf "$RESULT_DIR"
mkdir -p "$RESULT_DIR"

# Worker script for a single request
cat > /tmp/stability-worker.sh <<'WORKEREOF'
idx=$1
host_ip=$2
port=$3
result_dir=$4
# Pick a random "site" name to simulate different hostnames
sites=("news" "shop" "blog" "mail" "maps" "docs" "video" "images" "social" "search")
site_idx=$((RANDOM % ${#sites[@]}))
hostname="${sites[$site_idx]}-${idx}.example.com"
file_idx=$(printf "%04d" $((RANDOM % 500)))
url="https://${hostname}:${port}/file-${file_idx}.bin"

start_ms=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")
result=$(curl -sk --connect-timeout 10 --max-time 30 -o /dev/null \
    -w "%{http_code} %{time_total} %{size_download}" \
    --resolve "${hostname}:${port}:${host_ip}" \
    "$url" 2>/dev/null)
exit_code=$?
end_ms=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")

echo "${start_ms} ${exit_code} ${result} ${hostname}" >> "${result_dir}/batch-$$.log"
WORKEREOF
chmod +x /tmp/stability-worker.sh

END_TIME=$(($(date +%s) + DURATION_MIN * 60))
PAGE_LOADS=0
TOTAL_REQUESTS=0
TOTAL_FAILURES=0
REQUEST_ID=0

echo "=== Running for ${DURATION_MIN} minutes ==="
echo "    Simulating browser: page loads every 1-5s, 5-15 resources each"
echo ""

while [ "$(date +%s)" -lt "$END_TIME" ]; do
    PAGE_LOADS=$((PAGE_LOADS + 1))
    REMAINING=$(( (END_TIME - $(date +%s)) / 60 ))

    # Simulate a page load: 5-15 concurrent resource fetches
    RESOURCES=$((5 + RANDOM % 11))
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + RESOURCES))

    # Fire all resources for this "page" concurrently
    for i in $(seq 1 $RESOURCES); do
        REQUEST_ID=$((REQUEST_ID + 1))
        bash /tmp/stability-worker.sh "$REQUEST_ID" "$HOST_IP" "$HTTPS_PORT" "$RESULT_DIR" &
    done
    wait

    # Check for failures in this batch
    BATCH_FAILURES=0
    if ls "$RESULT_DIR"/batch-*.log &>/dev/null; then
        BATCH_FAILURES=$(cat "$RESULT_DIR"/batch-*.log | awk '$2 != 0 || $3 != 200' | wc -l | tr -d ' ')
    fi

    if [ "$BATCH_FAILURES" -gt 0 ]; then
        TOTAL_FAILURES=$((TOTAL_FAILURES + BATCH_FAILURES))
        NOW=$(date "+%H:%M:%S")
        echo "[$NOW] Page $PAGE_LOADS: $BATCH_FAILURES/$RESOURCES FAILED (total failures: $TOTAL_FAILURES/$TOTAL_REQUESTS)"
        # Show the failures
        cat "$RESULT_DIR"/batch-*.log | awk '$2 != 0 || $3 != 200 {
            if ($2 == 28) err="TIMEOUT"
            else if ($2 == 7) err="CONN_REFUSED"
            else if ($2 == 35) err="SSL_ERROR"
            else if ($2 == 56) err="RECV_FAIL"
            else err="curl_" $2
            print "  " err " " $NF
        }'
    else
        # Print progress every 10 page loads
        if [ $((PAGE_LOADS % 10)) -eq 0 ]; then
            NOW=$(date "+%H:%M:%S")
            echo "[$NOW] Page $PAGE_LOADS: all OK (${REMAINING}m left, $TOTAL_REQUESTS total, $TOTAL_FAILURES failures)"
        fi
    fi

    # Merge batch logs into timeline
    cat "$RESULT_DIR"/batch-*.log >> "$LOG_FILE" 2>/dev/null
    rm -f "$RESULT_DIR"/batch-*.log

    # Think time: 1-5 seconds (simulate human reading the page)
    THINK=$((1 + RANDOM % 5))
    sleep "$THINK"
done

# --- Final results ---
echo ""
echo "=== Stability Test Results ==="

# Parse timeline log
if [ -f "$LOG_FILE" ]; then
    TOTAL=$(wc -l < "$LOG_FILE" | tr -d ' ')
    SUCCESS=$(awk '$2 == 0 && $3 == 200' "$LOG_FILE" | wc -l | tr -d ' ')
    FAILURES=$((TOTAL - SUCCESS))

    echo "Duration: ${DURATION_MIN} minutes"
    echo "Page loads: $PAGE_LOADS"
    echo "Total requests: $TOTAL"
    echo "Successful: $SUCCESS"
    echo "Failed: $FAILURES"

    if [ "$TOTAL" -gt 0 ]; then
        RATE=$(awk "BEGIN {printf \"%.2f\", ($SUCCESS / $TOTAL) * 100}")
        echo "Success rate: ${RATE}%"
    fi

    # Timing stats for successful requests
    if [ "$SUCCESS" -gt 0 ]; then
        echo ""
        echo "--- Timing (successful requests) ---"
        awk '$2 == 0 && $3 == 200 {print $4}' "$LOG_FILE" | sort -n | awk '
        {a[NR]=$1; sum+=$1}
        END {
            printf "  Min:    %.3fs\n", a[1]
            printf "  Median: %.3fs\n", a[int(NR/2)+1]
            printf "  P95:    %.3fs\n", a[int(NR*0.95)+1]
            printf "  Max:    %.3fs\n", a[NR]
            printf "  Avg:    %.3fs\n", sum/NR
        }'
    fi

    # Error breakdown
    if [ "$FAILURES" -gt 0 ]; then
        echo ""
        echo "--- Failure breakdown ---"
        awk '$2 != 0 {print $2}' "$LOG_FILE" | sort | uniq -c | sort -rn | while read count code; do
            case "$code" in
                7)  desc="Connection refused" ;;
                28) desc="Timeout" ;;
                35) desc="SSL connect error" ;;
                52) desc="Empty reply" ;;
                56) desc="Recv failure" ;;
                *)  desc="curl error $code" ;;
            esac
            echo "  $count × $desc (exit $code)"
        done
        awk '$2 == 0 && $3 != 200 {print $3}' "$LOG_FILE" | sort | uniq -c | sort -rn | while read count code; do
            echo "  $count × HTTP $code"
        done
    fi
fi

# --- Cleanup ---
echo ""
echo "--- Cleanup: Stop VPN ---"
scutil --nc stop "$VPN_NAME" 2>/dev/null || true

echo ""
echo "================================"
if [ "$TOTAL_FAILURES" -eq 0 ]; then
    echo "  STABILITY TEST PASSED: ${TOTAL_REQUESTS} requests, 0 failures"
    echo "================================"
    exit 0
else
    echo "  STABILITY TEST: ${TOTAL_FAILURES}/${TOTAL_REQUESTS} failures over ${DURATION_MIN}m"
    echo "================================"
    exit 1
fi
