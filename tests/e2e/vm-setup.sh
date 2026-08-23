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

# Step 5: Configure auto-login, sudo, and SSH key
# SIP does not need to be disabled: the provider is an app extension.
echo ""
echo "--- Step 4: Configuring auto-login and SSH ---"
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

# Verify signing (the Network Extension app extension requires a team ID)
TEAM_ID=$(codesign -d --verbose=2 "$APP_BUILD_PATH" 2>&1 | grep TeamIdentifier | awk -F= '{print $2}')
if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "not set" ]; then
    echo "ERROR: App is not properly signed. The Network Extension requires code signing."
    echo "Make sure Local.xcconfig has DEVELOPMENT_TEAM set."
    exit 1
fi
if [ ! -d "$APP_BUILD_PATH/Contents/PlugIns/TransparentProxy.appex" ]; then
    echo "ERROR: TransparentProxy.appex missing from built app"
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

# Step 8: Approve the network extension in GUI
echo ""
echo "--- Step 7: Approve the network extension ---"
echo ""
echo "  The VM will open with a GUI. You need to:"
echo ""
echo "  1. BaoLianDeng.app is already installed in /Applications"
echo "  2. Open it — macOS will ask to allow the Network Extension"
echo "  3. Open System Settings > General > Login Items & Extensions"
echo "  4. Under 'Network Extensions', toggle ON BaoLianDeng"
echo "  5. You may also need to click 'Allow' in a separate dialog"
echo "  6. Verify: open Terminal and run: scutil --nc list"
echo "     It should show 'BaoLianDeng' in the list"
echo "  7. Shut down the VM from the Apple menu"
echo ""
echo "  NOTE: The provider is PlugIns/TransparentProxy.appex. There is"
echo "  no system-extension approval dialog and systemextensionsctl is"
echo "  not involved."
echo ""
echo "Press Enter to boot the VM..."
read -r

tart run "$VM_BASE_NAME"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Base VM '$VM_BASE_NAME' is ready."
echo "Run the E2E tests with: make e2e-test"
