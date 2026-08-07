# Tunnel⚡️Sats Setup Tool

The `tunnelsats.sh` script is the new, unified setup tool for TunnelSats v2. It consolidates all previous scripts (`setupv2.sh`, `uninstallv2.sh`, `tunnelsats-sub-details.sh`) into a single, robust interface.

## Usage

Run the script with `sudo` and one of the following commands:

```bash
sudo bash tunnelsats.sh [install|uninstall|status|restart|pre-check]
```

### Commands

| Command | Description |
| :--- | :--- |
| **`install`** | Interactive wizard to install WireGuard, configure your node (LND/CLN/LIT), and set up networking. |
| **`uninstall`** | "Nuclear" uninstall. Removes all TunnelSats configurations, restores backups, and cleans up Docker networks/firewalls. |
| **`status`** | Detailed diagnostics. Checks subscription validity, interface status, Docker health, and connectivity (Ping/RTT). |
| **`restart`** | Smart restart helper. Re-initializes the WireGuard interface and DNS watchdog if you lose connection. |
| **`pre-check`** | Non-invasive verification. Checks if your system has the necessary prerequisites (WireGuard, Docker, etc.) without making changes. |

## Compatibility & Testing Status

We are iteratively validating `tunnelsats.sh` across various Node OS platforms. Note that `tunnelsats.sh` is designed for systemd / bare-metal environments, whereas **Umbrel** and **StartOS** use native containerized app packages.

| Hardware/Platform | Node OS | OS Version | Host Script (`tunnelsats.sh`) | Native App / Package |
| :--- | :--- | :--- | :---: | :---: |
| Raspberry Pi / PC | **Umbrel** | umbrelOS 1.0+ | N/A (Use Native App) | ✅ Native Umbrel App (Community Store / Official Review Pending) |
| Any Hardware | **StartOS (Start9)** | 0.3.5 & 0.4.0+ | N/A (Use Native Package) | ✅ Native `.s9pk` Package (Sideload / Official Store Pending) |
| Raspberry Pi | **RaspiBlitz** | v1.11.x | ✅ Supported | N/A |
| PC / VPS | **Bare Metal** | Debian 12 / Ubuntu | ✅ Supported | N/A |
| Pi / PC (x86) | **myNode** | v0.3.x | ⚠️ Experimental | N/A |

**Legend:**
- ✅ **Verified / Supported**: Tested and working.
- ⚠️ **Experimental**: Logic exists, but needs live community verification.
- N/A: Platform uses sandboxed container architecture — script execution bypassed in favor of native App Store packages.

> **Bare Metal / MiniBolt Note:**
> We have explicitly verified the setup on **[MiniBolt](https://github.com/MiniBoltGuide/minibolt)** (Ubuntu/Debian) environments. If following the MiniBolt guide, this script respects the standard directory structure and user permissions.

---

## 🚀 Help Us Stabilize!

We want `tunnelsats.sh` to be rock-solid. If you are running on a platform marked as ⚠️ or ❓, please help us by:
1. Running `sudo bash tunnelsats.sh status` and checking the output.
2. Reporting any "Stabilization Snags" in our **[Telegram Group](https://tunnelsats.com/join-telegram)**.
3. Providing your Hardware, Node OS, and OS Version (`cat /etc/os-release`).

Your feedback directly translates into better stability for the entire community!

## Need Help?

If you run into issues or have questions:

1.  **Telegram Group**: [tunnelsats.com/join-telegram](https://tunnelsats.com/join-telegram) - Quickest way to get community help.
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
