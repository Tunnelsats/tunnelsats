# Tunnel⚡️Sats Setup Tool

The `tunnelsats.sh` script is the new, unified setup tool for TunnelSats v2. It consolidates all previous scripts (`setupv2.sh`, `uninstallv2.sh`, `tunnelsats-sub-details.sh`) into a single, robust interface.

## Usage

Run the script with `sudo` and one of the following commands:

```bash
sudo bash tunnelsats.sh [install|uninstall|status|restart]
```

### Commands

| Command | Description |
| :--- | :--- |
| **`install`** | Interactive wizard to install WireGuard, configure your node (LND/CLN/LIT), and set up networking. |
| **`uninstall`** | "Nuclear" uninstall. Removes all TunnelSats configurations, restores backups, and cleans up Docker networks/firewalls. |
| **`status`** | Detailed diagnostics. Checks subscription validity, interface status, Docker health, and connectivity (Ping/RTT). |
| **`restart`** | Smart restart helper. Re-initializes the WireGuard interface and DNS watchdog if you lose connection. |

## Compatibility & Testing Status

We are iteratively validating `tunnelsats.sh` across various Node OS platforms. The following table reflects the current **Verified** state.

| Hardware/Platform | Node OS | OS Version | [i]nstall | [u]ninstall | [s]tatus | [r]estart |
| :--- | :--- | :--- | :---: | :---: | :---: | :---: |
| Raspberry Pi 4 | **Umbrel** | umbrelOS 1.5 | ✅ | ✅ | ✅ | ✅ |
| Raspberry Pi | **RaspiBlitz** | v1.9.0 | ✅ | ✅ | ✅ | ✅ |
| Proxmox VM | **Umbrel** | v1.2.1 | ✅ | ✅ | ✅ | ✅ |
| PC / VPS | **Bare Metal** | Debian 12 | ⚠️ | ⚠️ | ✅ | ✅ |
| Pi / PC (x86) | **myNode** | v0.3.x | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| Any | **Start9** | Any | ❌ | ❌ | ❌ | ❌ |

**Legend:**
- ✅ **Verified**: Tested and working 100%.
- ⚠️ **Experimental**: Logic exists (ported from v2), but needs live verification.
- ❓ **Untested**: Not yet validated on this specific environment.
- ❌ **Not Supported**: Current architecture is incompatible with script installation.

---

## 🚀 Help Us Stabilize!

We want `tunnelsats.sh` to be rock-solid. If you are running on a platform marked as ⚠️ or ❓, please help us by:
1. Running `sudo bash tunnelsats.sh status` and checking the output.
2. Reporting any "Stabilization Snags" in our **[Telegram Group](https://t.me/tunnelsats)**.
3. Providing your Hardware, Node OS, and OS Version (`cat /etc/os-release`).

Your feedback directly translates into better stability for the entire community!

## Need Help?

If you run into issues or have questions:

1.  **Telegram Group**: [t.me/tunnelsats](https://t.me/tunnelsats) - Quickest way to get community help.
2.  **Guide**: [guide.tunnelsats.com](https://guide.tunnelsats.com) - Detailed manual setup instructions.
3.  **Bot**: [t.me/TunnelSatsBot](https://t.me/TunnelSatsBot) - Check your clearnet connection speed and tools.

---

## Legacy Version / Troubleshooting

If you encounter critical issues with `tunnelsats.sh` (v3.0), you can fall back to the proven v2 scripts located in the `archive/` folder.

**To use the legacy version:**
```bash
cd archive
sudo bash setupv2.sh
```

These scripts (`setupv2.sh`, `uninstallv2.sh`, etc.) are preserved for compatibility but will strictly be in maintenance mode. Please report any v3 issues so we can fix them!
