![TunnelSats Banner](/docs/assets/guide_header.webp)

# TunnelSats: Hybrid Lightning Node Setup

[![Syntax & Tests](https://github.com/Tunnelsats/tunnelsats/actions/workflows/syntax.yml/badge.svg)](https://github.com/Tunnelsats/tunnelsats/actions/workflows/syntax.yml)
[![Script Integrity](https://github.com/Tunnelsats/tunnelsats/actions/workflows/integrity.yml/badge.svg)](https://github.com/Tunnelsats/tunnelsats/actions/workflows/integrity.yml)

> **Privacy-focused VPN tunnels for Lightning nodes.** Run your node hybrid (clearnet + Tor) without exposing your home IP.

---

## ⚡ Quick Start

**New to TunnelSats?** Get up and running in 3 steps:

1. **Subscribe** at [tunnelsats.com](https://tunnelsats.com) and download your WireGuard config
2. **Run the installer** on your node:
   ```bash
   wget -O tunnelsats.sh https://github.com/tunnelsats/tunnelsats/raw/main/scripts/tunnelsats.sh
   sudo bash tunnelsats.sh install
   ```
3. **Configure your node** with the VPN settings from the installer output

👉 **[See full installation guide and compatibility matrix →](./scripts/)**

---

## Why Hybrid Mode?

The Lightning Network needs **fast, reliable, discoverable** nodes for efficient routing. While Tor provides privacy, it can be slow and unreliable. TunnelSats solves this by:

- ⚡ **Clearnet Speed** – Direct connections for faster routing
- 🔒 **VPN Privacy** – Your home IP stays hidden
- 🧅 **Tor Fallback** – Maintains .onion connectivity
- 🛡️ **Split Tunneling** – Only Lightning traffic goes through VPN

---

## Supported Platforms

| Platform                       | Type            | LND | CLN | Installation Method                                                                                                                |
| :----------------------------- | :-------------- | :-: | :-: | :--------------------------------------------------------------------------------------------------------------------------------- |
| **Umbrel** (umbrelOS 1.0+)     | Docker App      | ✅  | ✅  | **Native Umbrel App** ([Community App Store](https://github.com/Tunnelsats/ts-umbrel-app) / Official Review Pending)               |
| **StartOS** (StartOS 0.4.0+)   | Service Package | ✅  | ✅  | **Native `.s9pk` Package** ([tunnelsats-startos repo](https://github.com/Tunnelsats/tunnelsats-startos) / Community Store Pending) |
| **RaspiBlitz** (v1.11+)        | Systemd         | ✅  | ✅  | Host Script (`tunnelsats.sh`)                                                                                                      |
| **Bare Metal** (Debian/Ubuntu) | Systemd         | ✅  | ✅  | Host Script (`tunnelsats.sh`)                                                                                                      |
| **myNode** (v0.3+)             | Systemd         | ⚠️  | ⚠️  | Host Script (`tunnelsats.sh` - Experimental)                                                                                       |

> ℹ️ **Security Architecture Note**:
> The `tunnelsats.sh` bash installer is designed for bare-metal / systemd nodes (RaspiBlitz, RaspiBolt, MiniBolt, myNode).
> Due to the strict container sandboxing and security infrastructure of **Umbrel** and **StartOS**, manual host script execution is unsupported on those platforms — please use their respective native App / Service installations.

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

Your existing configuration remains valid after renewal – no changes needed!

---

## Uninstallation

To remove TunnelSats and restore your original configuration:

```bash
sudo bash tunnelsats.sh uninstall
```

---

## Development & Testing

### Running Tests Locally

All test suites can be executed locally in non-root environments:

```bash
# Verify shell script syntax
find . -name "*.sh" -print0 | xargs -0 -I {} bash -n "{}"

# Run automated test suites
bash scripts/test_check_umbrel_version.sh
bash scripts/test_ufw_check.sh
bash scripts/test_ipv6_patch.sh
bash scripts/test_sanitize_config.sh
bash scripts/test_lifecycle_idempotency.sh

# Verify script SHA256 integrity
sha256sum -c scripts/tunnelsats.sh.sha256
```

### Remote CI/CD

Automated CI status checks run on every push and pull request via [GitHub Actions](https://github.com/Tunnelsats/tunnelsats/actions):
- **[Syntax & Automated Tests](https://github.com/Tunnelsats/tunnelsats/actions/workflows/syntax.yml)**: Validates script syntax (`bash -n`) and executes all 5 automated test suites covering Umbrel version compatibility, UFW firewall handling, IPv6 route stripping, WireGuard configuration sanitization, and lifecycle/routing idempotency.
- **[Script Integrity Verification](https://github.com/Tunnelsats/tunnelsats/actions/workflows/integrity.yml)**: Asserts that `scripts/tunnelsats.sh.sha256` strictly matches the contents of `scripts/tunnelsats.sh`.

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
