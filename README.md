![TunnelSats Banner](/docs/assets/guide_header.webp)

# TunnelSats: Hybrid Lightning Node Setup

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

| Platform | LND | CLN | Status |
|----------|-----|-----|--------|
| **Umbrel** (umbrelOS 1.5+) | ✅ | ✅ | Verified |
| **RaspiBlitz** (v1.11+) | ✅ | ✅ | Verified |
| **Bare Metal** (Debian/Ubuntu) | ✅ | ✅ | Verified |
| **myNode** (v0.3+) | ⚠️ | ⚠️ | Experimental |
| **Start9** | ❌ | ❌ | Not Supported |

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

## Support

- 💬 **Telegram**: [Tunnel⚡Sats Group](https://t.me/+aIyeTSEStCQxYmRi)
- 📖 **Guide**: [tunnelsats.com/guide](https://tunnelsats.com/guide)
- ❓ **FAQ**: [tunnelsats.com/faq](https://tunnelsats.com/faq)
- 🐛 **Issues**: [GitHub Issues](https://github.com/tunnelsats/tunnelsats/issues)

---

## Credits

Built with ⚡ by [@ziggie1984](https://github.com/ziggie1984), [@TrezorHannes](https://github.com/TrezorHannes), and [@blckbx](https://github.com/blckbx).

Special thanks to [@LightRider5](https://github.com/LightRider5) ([lnvpn.net](https://lnvpn.net)) for inspiration and support.
