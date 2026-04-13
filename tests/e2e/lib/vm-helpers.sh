#!/bin/bash
# Shared helper functions for VM-based E2E tests

VM_USER="${VM_USER:-admin}"
VM_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

vm_start() {
    local vm_name="$1"
    echo "Starting VM: $vm_name (headless with virtual display)..."
    tart run "$vm_name" --vnc-experimental --no-graphics &
    VM_PID=$!
    echo "VM PID: $VM_PID"
}

vm_stop() {
    local vm_name="$1"
    echo "Stopping VM: $vm_name..."
    tart stop "$vm_name" 2>/dev/null || true
}

vm_delete() {
    local vm_name="$1"
    echo "Deleting VM: $vm_name..."
    tart delete "$vm_name" 2>/dev/null || true
}

vm_ip() {
    local vm_name="$1"
    local max_attempts="${2:-30}"
    for i in $(seq 1 "$max_attempts"); do
        local ip
        ip=$(tart ip "$vm_name" 2>/dev/null)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        sleep 2
    done
    echo "ERROR: Could not get VM IP after $max_attempts attempts" >&2
    return 1
}

vm_exec() {
    local vm_ip="$1"
    shift
    ssh $VM_SSH_OPTS "$VM_USER@$vm_ip" "$@"
}

vm_copy_to() {
    local vm_ip="$1"
    local local_path="$2"
    local remote_path="$3"
    scp $VM_SSH_OPTS -r "$local_path" "$VM_USER@$vm_ip:$remote_path"
}

# Install an .app bundle to /Applications/ via sudo (scp can't write there directly)
vm_install_app() {
    local vm_ip="$1"
    local local_app_path="$2"
    local app_name
    app_name=$(basename "$local_app_path")
    local tmp_path="/tmp/$app_name"

    # Remove any previous copy in /tmp and /Applications
    vm_exec "$vm_ip" "rm -rf '$tmp_path' && sudo rm -rf '/Applications/$app_name'"

    # scp to /tmp (user-writable), then sudo mv to /Applications
    scp $VM_SSH_OPTS -r "$local_app_path" "$VM_USER@$vm_ip:$tmp_path"
    vm_exec "$vm_ip" "sudo mv '$tmp_path' /Applications/"
}

wait_for_ssh() {
    local vm_ip="$1"
    local max_wait="${2:-120}"
    echo "Waiting for SSH on $vm_ip (up to ${max_wait}s)..."
    for i in $(seq 1 "$max_wait"); do
        if ssh $VM_SSH_OPTS "$VM_USER@$vm_ip" "echo ok" &>/dev/null; then
            echo "SSH ready after ${i}s"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: SSH not available after ${max_wait}s" >&2
    return 1
}

wait_for_gui() {
    local vm_ip="$1"
    local max_wait="${2:-90}"
    echo "Waiting for GUI session on $vm_ip (up to ${max_wait}s)..."
    for i in $(seq 1 "$max_wait"); do
        if vm_exec "$vm_ip" "pgrep -x Finder" &>/dev/null; then
            echo "GUI ready after ${i}s"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: GUI session not available after ${max_wait}s" >&2
    return 1
}

host_ip_for_vm() {
    local vm_ip="$1"
    # Get the default gateway from the VM's perspective (= host IP on vmnet bridge)
    vm_exec "$vm_ip" "route -n get default 2>/dev/null | awk '/gateway:/ {print \$2}'"
}
