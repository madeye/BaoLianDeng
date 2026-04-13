#!/bin/bash
# One-time VM setup for BaoLianDeng E2E tests
# Creates a macOS VM and guides through manual configuration steps
set -e

VM_BASE_NAME="bld-e2e-base"
DISK_SIZE_GB=60

echo "=== BaoLianDeng E2E VM Setup ==="
echo ""

# Step 1: Check dependencies
echo "--- Step 1: Checking dependencies ---"
if ! command -v tart &>/dev/null; then
    echo "Installing tart..."
    brew install cirruslabs/cli/tart
else
    echo "tart: $(tart --version 2>&1 | head -1)"
fi

if ! command -v trojan-go &>/dev/null; then
    echo "Installing trojan-go..."
    brew install trojan-go
else
    echo "trojan-go: $(trojan-go --version 2>&1 | head -1)"
fi

# Step 2: Check if base VM already exists
if tart list 2>/dev/null | grep -q "$VM_BASE_NAME"; then
    echo ""
    echo "VM '$VM_BASE_NAME' already exists."
    echo "To recreate, run: tart delete $VM_BASE_NAME"
    echo "Then re-run this script."
    exit 0
fi

# Step 3: Create VM from IPSW
echo ""
echo "--- Step 2: Creating VM from latest macOS IPSW ---"
echo "This downloads ~14GB and takes several minutes..."
echo "Note: host macOS version must be >= the IPSW version."
tart create "$VM_BASE_NAME" --from-ipsw latest --disk-size "$DISK_SIZE_GB"

# Step 4: First boot — Setup Assistant + SSH
echo ""
echo "--- Step 3: First boot (Setup Assistant + SSH) ---"
echo ""
echo "  The VM will open in a GUI window. Complete these steps:"
echo ""
echo "  1. Complete the macOS Setup Assistant"
echo "     - Username: admin"
echo "     - Password: admin"
echo "     - Skip Apple ID, Screen Time, Analytics, etc."
echo ""
echo "  2. Enable Remote Login (SSH)"
echo "     - System Settings > General > Sharing > Remote Login > ON"
echo "     - Allow access for: All users"
echo ""
echo "  3. Shut down the VM from the Apple menu"
echo ""
echo "Press Enter to boot the VM..."
read -r

tart run "$VM_BASE_NAME"

# Step 5: Disable SIP via recovery mode
echo ""
echo "--- Step 4: Disable SIP (recovery mode) ---"
echo ""
echo "  The VM will boot into recovery mode:"
echo ""
echo "  1. Utilities > Terminal"
echo "  2. Run: csrutil disable"
echo "  3. Confirm with 'y' if prompted"
echo "  4. Run: reboot"
echo ""
echo "Press Enter to boot into recovery mode..."
read -r

tart run "$VM_BASE_NAME" --recovery

# Step 6: Configure auto-login, sudo, and SSH key
echo ""
echo "--- Step 5: Configuring auto-login and SSH ---"
echo "Booting VM headlessly..."
tart run "$VM_BASE_NAME" --vnc-experimental --no-graphics &
SETUP_PID=$!

# Wait for VM IP
echo "Waiting for VM IP..."
VM_IP=""
for i in $(seq 1 60); do
    VM_IP=$(tart ip "$VM_BASE_NAME" 2>/dev/null || true)
    if [ -n "$VM_IP" ]; then
        echo "VM IP: $VM_IP"
        break
    fi
    sleep 2
done

if [ -z "$VM_IP" ]; then
    echo "ERROR: Could not get VM IP"
    kill $SETUP_PID 2>/dev/null || true
    exit 1
fi

# Wait for SSH
echo "Waiting for SSH..."
for i in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 admin@"$VM_IP" "echo ok" &>/dev/null; then
        echo "SSH ready"
        break
    fi
    sleep 2
done

# Copy SSH key
echo ""
echo "Copying SSH key... (password is 'admin')"
ssh-copy-id -o StrictHostKeyChecking=no admin@"$VM_IP"

# Enable passwordless sudo
echo "Setting up passwordless sudo..."
ssh -t -o StrictHostKeyChecking=no admin@"$VM_IP" \
    "echo 'admin' | sudo -S sh -c 'echo \"admin ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/admin && chmod 440 /etc/sudoers.d/admin' 2>/dev/null && echo 'Done'"

# Enable auto-login
echo "Enabling auto-login..."
ssh -o StrictHostKeyChecking=no admin@"$VM_IP" \
    "sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser admin"

# Create kcpassword (XOR-obfuscated "admin")
ssh -o StrictHostKeyChecking=no admin@"$VM_IP" \
    'sudo sh -c "printf \"\\x1c\\xed\\x3f\\x4a\\xbc\\xbc\\x43\\xb4\\x59\\x33\\xb1\" > /etc/kcpassword && chmod 600 /etc/kcpassword"'
echo "Auto-login configured"

# Enable system extension developer mode (requires SIP disabled)
echo "Enabling system extension developer mode..."
ssh -o StrictHostKeyChecking=no admin@"$VM_IP" \
    'sudo python3 -c "
import plistlib
db = {\"version\": 1, \"developerMode\": True, \"extensions\": [], \"extensionPolicies\": []}
with open(\"/Library/SystemExtensions/db.plist\", \"wb\") as f:
    plistlib.dump(db, f, fmt=plistlib.FMT_BINARY)
print(\"Developer mode enabled\")
"'

# Stop VM
tart stop "$VM_BASE_NAME" 2>/dev/null || true
wait $SETUP_PID 2>/dev/null || true

# Step 7: Build and install app, then approve extension
echo ""
echo "--- Step 6: Build and install app ---"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "Building framework..."
cd "$PROJECT_DIR"
make framework

echo "Building app (Debug, signed)..."
xcodebuild build \
    -project BaoLianDeng.xcodeproj \
    -scheme BaoLianDeng \
    -configuration Debug \
    -destination 'platform=macOS' 2>&1 | tail -5

APP_BUILD_PATH=$(find ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Debug -name "BaoLianDeng.app" -maxdepth 1 2>/dev/null | head -1)
if [ -z "$APP_BUILD_PATH" ]; then
    echo "ERROR: Could not find built BaoLianDeng.app"
    exit 1
fi

# Verify signing (system extensions require proper code signing)
TEAM_ID=$(codesign -d --verbose=2 "$APP_BUILD_PATH" 2>&1 | grep TeamIdentifier | awk -F= '{print $2}')
if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "not set" ]; then
    echo "ERROR: App is not properly signed. System extensions require code signing."
    echo "Make sure Local.xcconfig has DEVELOPMENT_TEAM set."
    exit 1
fi
echo "Built app: $APP_BUILD_PATH (Team: $TEAM_ID)"

# Boot VM headlessly to install the app
echo ""
echo "--- Step 7: Install app in VM ---"
tart run "$VM_BASE_NAME" --vnc-experimental --no-graphics &
SETUP_PID=$!

VM_IP=""
for i in $(seq 1 60); do
    VM_IP=$(tart ip "$VM_BASE_NAME" 2>/dev/null || true)
    if [ -n "$VM_IP" ]; then break; fi
    sleep 2
done
if [ -z "$VM_IP" ]; then
    echo "ERROR: Could not get VM IP"
    kill $SETUP_PID 2>/dev/null || true
    exit 1
fi

# Wait for SSH
for i in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 admin@"$VM_IP" "echo ok" &>/dev/null; then
        break
    fi
    sleep 2
done

source "$SCRIPT_DIR/lib/vm-helpers.sh"
echo "Installing app in VM..."
vm_install_app "$VM_IP" "$APP_BUILD_PATH"

tart stop "$VM_BASE_NAME" 2>/dev/null || true
wait $SETUP_PID 2>/dev/null || true

# Step 8: Approve system extension + network extension in GUI
echo ""
echo "--- Step 8: Approve system extension + network extension ---"
echo ""
echo "  The VM will open with a GUI. You need to:"
echo ""
echo "  1. BaoLianDeng.app is already installed in /Applications"
echo "  2. Open it — it will request system extension activation"
echo "  3. A notification will appear asking to allow the extension"
echo "  4. Open System Settings > General > Login Items & Extensions"
echo "  5. Under 'Network Extensions', toggle ON BaoLianDeng"
echo "  6. You may also need to click 'Allow' in a separate dialog"
echo "  7. Verify: open Terminal and run: scutil --nc list"
echo "     It should show 'BaoLianDeng' in the list"
echo "  8. Shut down the VM from the Apple menu"
echo ""
echo "  NOTE: Both the system extension AND the network extension"
echo "  (transparent proxy filter) must be approved. These are"
echo "  separate approvals in System Settings."
echo ""
echo "Press Enter to boot the VM..."
read -r

tart run "$VM_BASE_NAME"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Base VM '$VM_BASE_NAME' is ready."
echo "Run the E2E tests with: make e2e-test"
