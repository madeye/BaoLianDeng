# BaoLianDeng E2E Tests

End-to-end tests that run BaoLianDeng in a macOS VM, using a local Shadowsocks proxy to verify the full VPN tunnel works. The provider is an app extension, so SIP does not need to be disabled.

## Prerequisites

- macOS host with Apple Silicon
- [Homebrew](https://brew.sh)
- Xcode 15+ and Rust toolchain (for building the app)

## Setup (one-time)

### 1. Install dependencies

```bash
brew install cirruslabs/cli/tart shadowsocks-rust
```

### 2. Create the VM

```bash
tart create bld-e2e-base --from-ipsw latest --disk-size 60
```

Note: the host macOS version must be >= the IPSW version. The IPSW is ~14GB.

### 3. Initial boot — Setup Assistant + SSH

```bash
tart run bld-e2e-base
```

In the VM window:
- Complete Setup Assistant: username `admin`, password `admin`, skip everything else
- Enable SSH: **System Settings > General > Sharing > Remote Login > ON** (allow all users)
- Shut down from the Apple menu

### 4. Configure auto-login and passwordless sudo

```bash
tart run bld-e2e-base --vnc-experimental --no-graphics &
# Wait for boot, then:
ssh-copy-id -o StrictHostKeyChecking=no admin@$(tart ip bld-e2e-base)
# Password: admin

ssh admin@$(tart ip bld-e2e-base)
# Inside the VM:
echo 'admin' | sudo -S sh -c 'echo "admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/admin && chmod 440 /etc/sudoers.d/admin'
sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser admin
# Create /etc/kcpassword for auto-login (XOR-obfuscated "admin"):
sudo sh -c 'printf "\x1c\xed\x3f\x4a\xbc\xbc\x43\xb4\x59\x33\xb1" > /etc/kcpassword && chmod 600 /etc/kcpassword'
exit

tart stop bld-e2e-base
```

### 5. Approve the network extension

```bash
tart run bld-e2e-base
```

- Copy the built app: `scp -r path/to/BaoLianDeng.app admin@$(tart ip bld-e2e-base):/Applications/`
- Open BaoLianDeng in the VM
- When prompted, go to **System Settings > General > Login Items & Extensions > Network Extensions** and toggle ON
- Shut down the VM

The provider is `PlugIns/TransparentProxy.appex` — there is no system-extension approval dialog and `systemextensionsctl` is not involved. The base VM is now ready. All clones inherit these settings.

## Running Tests

```bash
make e2e-test
```

Or skip the build if you already have a recent `.app`:
```bash
SKIP_BUILD=1 make e2e-test
```

This takes ~1-2 minutes (with `SKIP_BUILD`) and:
1. Builds the framework and app on the host (unless `SKIP_BUILD` is set)
2. Starts a local Shadowsocks server on the host (port 18388)
3. Clones the base VM to an ephemeral copy and boots it headlessly
4. Copies the `.app` bundle and test config to the VM
5. Launches the app, starts the VPN tunnel
6. Runs 5 connectivity checks:
   - SOCKS5 proxy (curl via 127.0.0.1:7890)
   - Transparent-proxy routing (curl without explicit proxy)
   - Traffic stats (external controller API)
   - App extension is embedded (`PlugIns/TransparentProxy.appex`)
   - DNS resolution through tunnel
7. Cleans up (stops VPN, deletes ephemeral VM clone, kills ssserver)

## Architecture

```
Host                              VM (auto-login)
────                              ───────────────────────────────
ssserver :18388  <───────────────  BaoLianDeng.app
                                    └── PlugIns/TransparentProxy.appex
                                          ├── NETransparentProxyProvider
                                          └── mihomo engine
                                                └── curl http://httpbin.org/ip
```

Traffic flow: `curl → transparent proxy → SOCKS5 → mihomo → SS client → host ssserver :18388 → internet`

## Files

| File | Description |
|------|-------------|
| `run-e2e.sh` | Host-side orchestrator (main entry point) |
| `vm-setup.sh` | One-time VM provisioning (installs deps, creates VM) |
| `vm-test.sh` | Runs inside VM via SSH (configure, start VPN, verify) |
| `config/ssserver-config.json` | Shadowsocks server config |
| `config/test-config.yaml` | Mihomo config template (`__HOST_IP__` placeholder) |
| `lib/vm-helpers.sh` | Shared VM management functions |
| `lib/assertions.sh` | Test assertion helpers |

## Troubleshooting

**"Base VM not found"**: Complete the setup steps above. The base VM must be named `bld-e2e-base`.

**SSH timeout**: Ensure Remote Login is enabled in the VM. Boot manually with `tart run bld-e2e-base` and check System Settings > General > Sharing.

**"No GUI session"**: Auto-login must be configured (step 4 above). The VM boots headlessly with `--vnc-experimental --no-graphics` which provides a virtual display. Without auto-login, no GUI session starts and the app can't launch.

**Network extension "waiting for user"**: The Network Extension must be toggled on once on the base VM (step 5). The approval persists in clones.

**VPN doesn't connect**: Confirm **System Settings → General → Login Items & Extensions → Network Extensions** is on for BaoLianDeng, and that `BaoLianDeng.app/Contents/PlugIns/TransparentProxy.appex` exists.

**ssserver not found**: Run `brew install shadowsocks-rust`.

**DHCP address exhaustion**: Each ephemeral VM clone gets a new DHCP lease. If you run many tests, reduce the DHCP lease time:
```bash
sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist bootpd -dict DHCPLeaseTimeSecs -int 600
```

## Notes

- The VM runs with `--vnc-experimental --no-graphics` which provides a virtual display (needed for GUI session / auto-login) without opening a window on the host.
- GitHub Actions cannot run these tests (no nested virtualization support on hosted runners).
- The base VM image (`bld-e2e-base`) is ~30GB on disk.
- Ephemeral clones are created per test run and deleted on cleanup.
