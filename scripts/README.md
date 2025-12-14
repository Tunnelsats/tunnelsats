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

We are actively validating the script across the most popular Lightning node platforms.

| Platform | Implementation | Status | Notes |
| :--- | :--- | :--- | :--- |
| **Umbrel** | CLN | ✅ Verified | Full support (Docker). |
| **Umbrel** | LND | ✅ Verified | Full support (Docker). |
| **RaspiBlitz** | LND | ✅ Verified | Full support (Systemd). |
| **RaspiBlitz** | CLN | ✅ Verified | Full support (Systemd). |
| **RaspiBolt** | LND/CLN | ✅ Verified | Uses standard systemd paths. |
| **Barel Metal** | LND/CLN | ✅ Verified | Standard Debian/Ubuntu support. |
| **myNode** | Any | ⚠️ Experimental | Detection logic behaves as "Systemd". If your myNode uses Docker, this may fail. |

> **Note**: While we strive for universal support, "Experimental" platforms should be tested with caution. Always backup your config!

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
