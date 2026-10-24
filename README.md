![TunnelSats Banner](/docs/assets/guide_header.webp)

# TunnelSats: Hybrid Lightning Node Setup

[![Syntax & Tests](https://github.com/Tunnelsats/tunnelsats/actions/workflows/syntax.yml/badge.svg)](https://github.com/Tunnelsats/tunnelsats/actions/workflows/syntax.yml)
[![Script Integrity](https://github.com/Tunnelsats/tunnelsats/actions/workflows/integrity.yml/badge.svg)](https://github.com/Tunnelsats/tunnelsats/actions/workflows/integrity.yml)

> **Privacy-focused VPN tunnels for Lightning nodes.** Run your node hybrid (clearnet + Tor) while keeping your home IP private.

---

## ⚡ Quick Start

**New to TunnelSats?** Get up and running in 3 steps:

1. **Subscribe** at [tunnelsats.com](https://tunnelsats.com) and download your WireGuard config (or on RaspiBlitz v1.12+, open **SSH menu > SUBSCRIBE > TunnelSats > BUY** directly on the node)
2. **Download and verify the installer** on your node:
   ```bash
   wget -O tunnelsats.sh https://github.com/Tunnelsats/tunnelsats/raw/main/scripts/tunnelsats.sh
   wget -O tunnelsats.sh.sha256 https://github.com/Tunnelsats/tunnelsats/raw/main/scripts/tunnelsats.sh.sha256
   sha256sum -c <(sed 's|scripts/tunnelsats.sh|tunnelsats.sh|' tunnelsats.sh.sha256)
   ```
3. **Run the installer** (managed mode is recommended for bare-metal Debian/Ubuntu systemd nodes and RaspiBlitz):
   ```bash
   # Bare-metal systemd node (managed mode, persistent kill switch + slice):
   sudo bash tunnelsats.sh install --managed baremetal --config tunnelsats_<server>.conf

   # Or interactive wizard:
   sudo bash tunnelsats.sh install
   ```
4. **Configure your node** with the VPN settings from the installer output (on RaspiBlitz with the SSH Subscriptions menu, the start guard manages the runtime flags automatically while keeping your node configuration Tor-only at rest)

👉 **[See full installation guide and compatibility matrix →](./scripts/)**

Scripts and node platforms can run the installer without prompts (`--non-interactive`, `--platform`, `--impl`, `--yes`), convert legacy installs with `adopt --managed`, and inspect a node read-only with `detect --json`; see [scripts/README.md](./scripts/README.md#non-interactive-use-scripts-and-node-platforms) and [docs/managed-mode.md](docs/managed-mode.md).

---

## Why Hybrid Mode?

The Lightning Network needs **fast, reliable, discoverable** nodes for efficient routing. While Tor provides privacy, it can be slow and unreliable. TunnelSats solves this by:

- ⚡ **Clearnet Speed** - Direct connections for faster routing
- 🔒 **VPN Privacy** - Your home IP stays hidden
- 🧅 **Tor Fallback** - Maintains .onion connectivity
- 🛡️ **Split Tunneling** - Only Lightning traffic goes through VPN

---

## Supported Platforms

| Platform                       | Type            | LND | CLN | Installation Method                                                                                                                |
| :----------------------------- | :-------------- | :-: | :-: | :--------------------------------------------------------------------------------------------------------------------------------- |
| **Umbrel** (umbrelOS 1.0+)     | Docker App      | ✅  | ✅  | **Native Umbrel App** ([Community App Store](https://github.com/Tunnelsats/ts-umbrel-app) / Official Review Pending)               |
| **StartOS** (StartOS 0.4.0+)   | Service Package | ✅  | ✅  | **Native StartOS Package** ([Start9 Community Registry](https://marketplace.start9.com/?registry=https%3A%2F%2Fcommunity-registry.start9.com%2F) / [package source](https://github.com/Start9-Community/tunnelsats-startos); also supports Eclair) |
| **RaspiBlitz** (v1.11+)        | Systemd         | ✅  | ✅  | **SSH Menu** (`SUBSCRIBE > TunnelSats` on v1.12+) / Host Script (`tunnelsats.sh --managed raspiblitz`)                             |
| **Bare Metal** (Debian/Ubuntu) | Systemd         | ✅  | ✅  | Host Script (`tunnelsats.sh --managed baremetal`)                                                                                  |
| **myNode** (v0.3+)             | Systemd         | ✅  | ➖  | Host Script (`tunnelsats.sh --managed mynode`)                                                                                     |

> ℹ️ **Security Architecture Note**:
> The `tunnelsats.sh` bash installer is designed for bare-metal / systemd nodes (RaspiBlitz, RaspiBolt, MiniBolt, myNode).
> Due to the strict container sandboxing and security infrastructure of **Umbrel** and **StartOS**, manual host script execution is unsupported on those platforms - please use their respective native App / Service installations.
> On StartOS, install the native TunnelSats package from the [Start9 Community Registry](https://marketplace.start9.com/?registry=https%3A%2F%2Fcommunity-registry.start9.com%2F) ([package source](https://github.com/Start9-Community/tunnelsats-startos)). The earlier gateway-based StartOS setup (**System > Gateways**) is end-of-life; see the [migration steps](https://tunnelsats.com/faq#how-do-i-move-from-the-system-gateways-setup-to-the-startos-package).

See [scripts/README.md](./scripts/) for detailed compatibility info.

---

## Subscription & Renewal

### New Subscription

1. Visit [tunnelsats.com](https://tunnelsats.com)
2. Select a server location close to you
3. Choose duration (1-12 months)
4. Pay the Lightning invoice
5. Download your WireGuard config

### Renewal

- **Web**: [tunnelsats.com](https://tunnelsats.com) → Renew Subscription
- **Dashboard**: Log in → My Dashboard → Renew
- **API**: [api.tunnelsats.com](https://api.tunnelsats.com)

Your existing configuration remains valid after renewal - no changes needed!

---

## Uninstallation

To remove TunnelSats and restore your original configuration:

```bash
sudo bash tunnelsats.sh uninstall
```

LND 0.20 and later keeps announcing the addresses it saved, the former VPN address too. Once LND runs again, remove that address with `lncli peers updatenodeannouncement --address_remove <ip>:<port>`; uninstall prints the exact command (`uninstall --managed` runs it itself when LND answers). The same command removes an older clearnet address that `lncli getinfo` still lists under `uris`.

---

## Managed mode for bare-metal nodes, RaspiBlitz, and myNode

Managed mode runs the Lightning service in a dedicated cgroup v2 slice (`tunnelsats.slice`) behind a persistent `inet` nftables kill switch and policy routing table 51820. Its kill switch stays armed across tunnel restarts, reboots and package upgrades. When the subscription ends or the VPN server is unreachable, Lightning keeps running over Tor and the local network; only clearnet pauses until the tunnel is back.

```bash
# Install managed mode on a bare-metal systemd node (or use --managed mynode on myNode):
sudo bash tunnelsats.sh install --managed baremetal --config tunnelsats_<server>.conf

# Or convert an existing v2/v3 standard install to managed mode in one step:
sudo bash tunnelsats.sh adopt --managed baremetal

# Verify protection (kernel state + in-slice probes) or remove:
sudo tunnelsats verify
sudo tunnelsats uninstall --managed
```

On RaspiBlitz, use the built-in SSH Subscriptions menu (**MAIN MENU > SUBSCRIBE > TunnelSats**) or run `--managed raspiblitz --impl lnd` (or `--impl cln`; testnet and signet instances add `--network testnet|signet`). On myNode, run `--managed mynode` and store your hybrid settings in `/mnt/hdd/mynode/settings/lnd_extra_config.conf` so they persist across `mynode-regenerate-files` runs.
Requirements, how it works and what `verify` reports: [docs/managed-mode.md](docs/managed-mode.md).

---

## Development & Testing

### Running Tests Locally

All test suites can be executed locally in non-root environments:

```bash
# Verify shell script syntax
find . -name "*.sh" -print0 | xargs -0 -I {} bash -n "{}"

# Run automated test suites
bash scripts/test_ufw_check.sh
bash scripts/test_ipv6_patch.sh
bash scripts/test_sanitize_config.sh
bash scripts/test_lifecycle_idempotency.sh
bash scripts/test_cli_contract.sh        # needs python3 to validate JSON output
bash scripts/test_managed_dataplane.sh   # managed mode against fixture trees and stubs

# Verify script SHA256 integrity
sha256sum -c scripts/tunnelsats.sh.sha256
```

`scripts/test_dataplane_kernel.sh` runs managed mode against a real kernel (nftables, policy routing, WireGuard, cgroups, systemd). It changes the host, so it only runs as root with `TS_KERNEL_TEST=1` on a disposable VM; CI runs it on GitHub's runners.

### Remote CI/CD

Automated CI status checks run on every push and pull request via [GitHub Actions](https://github.com/Tunnelsats/tunnelsats/actions):
- **[Syntax & Automated Tests](https://github.com/Tunnelsats/tunnelsats/actions/workflows/syntax.yml)**: Validates script syntax (`bash -n`) and executes all 6 automated test suites covering UFW firewall handling, IPv6 route stripping, WireGuard configuration sanitization, lifecycle/routing idempotency, the non-interactive/JSON CLI contract (including `detect` on fixture trees), and managed mode.
- **[Kernel Dataplane Tests](https://github.com/Tunnelsats/tunnelsats/actions/workflows/kernel.yml)**: Runs managed mode on Ubuntu 22.04 and 24.04 runners against the real kernel: install, verify, tunnel loss, boot order, package upgrades, child processes, a removed kill switch table, failed arming behind the emergency block (with the local network kept, and a routing rule that bypasses it), a damaged install record, ruleset flushes, strict reverse-path filtering and uninstall.
- **[Script Integrity Verification](https://github.com/Tunnelsats/tunnelsats/actions/workflows/integrity.yml)**: Asserts that `scripts/tunnelsats.sh.sha256` strictly matches the contents of `scripts/tunnelsats.sh`.
- **[Release Tagging](https://github.com/Tunnelsats/tunnelsats/actions/workflows/release.yml)**: Automatically tags `v<VERSION>` and publishes a GitHub Release with `scripts/tunnelsats.sh` and `scripts/tunnelsats.sh.sha256` attached whenever `VERSION` in `scripts/tunnelsats.sh` is bumped on `main`.

### Local Setup & Git Hooks

This repository uses Git hooks to keep the SHA256 checksum in sync:

1. **Initialize hooks**:
   ```bash
   chmod +x scripts/hooks-install.sh
   ./scripts/hooks-install.sh
   ```
   This will automatically configure the `pre-commit` and `post-rewrite` hooks to keep the `scripts/tunnelsats.sh.sha256` file in sync.

---

## Support

- 💬 **Telegram**: [Tunnel⚡Sats Group](https://tunnelsats.com/join-telegram)
- 📖 **Guide**: [tunnelsats.com/guide](https://tunnelsats.com/guide)
- ❓ **FAQ**: [tunnelsats.com/faq](https://tunnelsats.com/faq)
- 🐛 **Issues**: [GitHub Issues](https://github.com/tunnelsats/tunnelsats/issues)

---

## Credits

Built with ⚡ by [@ziggie1984](https://github.com/ziggie1984), [@TrezorHannes](https://github.com/TrezorHannes), and [@blckbx](https://github.com/blckbx).

Special thanks to [@LightRider5](https://github.com/LightRider5) ([lnvpn.net](https://lnvpn.net)) for inspiration and support.
