# Tunnel⚡️Sats Setup Tool

The `tunnelsats.sh` script is the unified setup tool for TunnelSats v3. It consolidates all previous scripts (`setupv2.sh`, `uninstallv2.sh`, `tunnelsats-sub-details.sh`) into a single interface with managed systemd slice mode and JSON CLI contracts.

## Usage

Run the script with `sudo` and one of the following commands:

```bash
sudo bash tunnelsats.sh [install|adopt|uninstall|status|restart|verify|pre-check|detect|version]
```

### Commands

| Command         | Description                                                                                                                        |
| :-------------- | :--------------------------------------------------------------------------------------------------------------------------------- |
| **`install`**   | Interactive wizard to install WireGuard, configure your node (LND/CLN/LIT), and set up networking (`--managed` installs managed mode). |
| **`adopt`**     | Converts an existing standard (v2 or v3) install into managed mode (`--managed baremetal`, `--managed raspiblitz` or `--managed mynode`) in one transition. |
| **`uninstall`** | Removes TunnelSats configurations, units, and routing rules (never edits node configuration files; prints clearnet lines to remove). |
| **`status`**    | Detailed diagnostics. Checks subscription validity, interface status, systemd service health, and connectivity (Ping/RTT).         |
| **`restart`**   | Smart restart helper. Re-initializes the WireGuard interface and DNS watchdog if you lose connection.                              |
| **`verify`**    | Checks a managed install from kernel state and probes inside the Lightning slice (verdict `protected`, `degraded` or `unsafe`); on a standard install it reports the tunnel and its kill switch (verdict `unmanaged`). |
| **`pre-check`** | Non-invasive verification. Checks if your system has the necessary prerequisites (WireGuard, nftables, cgroup-tools, etc.) without making changes. |
| **`detect`**    | Read-only report: platform, Lightning units, an existing TunnelSats install (v2, v3 before or after the route guard, managed) with its artifacts, config facts, capabilities and conflicts. Needs no root; anything it cannot read is reported as such. |
| **`version`**   | Prints the tool version, the CLI contract number and the sha256 of the running script.                                             |

`install --managed <baremetal|raspiblitz|mynode>`, `adopt --managed <baremetal|raspiblitz|mynode>` and `uninstall --managed` set up, convert and remove managed mode on bare-metal systemd nodes, RaspiBlitz and myNode; see [docs/managed-mode.md](../docs/managed-mode.md).

### Non-interactive use (scripts and node platforms)

Options are accepted before or after the command:

| Option | Effect |
| :----- | :----- |
| `--non-interactive` | Never prompts. A question that no option answers fails with exit code 2 (`E_INTERACTION_REQUIRED`, naming the option) before anything is changed. A piped stdin alone does not switch this mode on. |
| `--config <file>` | WireGuard config (`install`, `adopt --managed`: the config to install; `status`, `restart`: the installed config in `/etc/wireguard`); answers the config selection |
| `--platform <id>` | `raspiblitz`, `mynode` or `baremetal` (passing `umbrel` fails closed and directs to the native Umbrel app); answers the platform questions (`install`, `uninstall`) and replaces auto-detection (`status`, `restart`) |
| `--impl <id>` | `lnd`, `cln` or `lit`; same commands as `--platform`, for the Lightning implementation (`install --managed`, `adopt --managed`: the unit to tunnel) |
| `--network <chain>` | `mainnet` (default), `testnet` or `signet` (`install --managed raspiblitz` and `adopt --managed raspiblitz`) |
| `--yes` | Answers the confirmations (uninstall, restart: stop the node first, LIT, managed install, adopt and uninstall) |
| `--remove-packages`, `--keep-packages` | Answer the uninstall package question; non-interactive mode keeps the packages |
| `--keep-config` | `uninstall` and `uninstall --managed`: keep the WireGuard configuration in `/etc/wireguard` on disk |
| `--legacy-artifacts` | `uninstall --managed`: also remove leftover artifacts from earlier v2/v3 standard installs (or clean a legacy install when no managed record exists) |
| `--managed [profile]` | Managed mode for `install` and `adopt` (profile `baremetal`, `raspiblitz` or `mynode`) and `uninstall` |
| `--uid-backstop` | `install --managed` and `adopt --managed`: also routes the Lightning user's traffic into the tunnel by uid (side effects in [docs/managed-mode.md](../docs/managed-mode.md)) |
| `--no-probe` | `verify`: kernel checks only, no network probes |
| `--json` | Exactly one JSON document on stdout, logs on stderr (`version`, `detect`, `verify`, `install --managed`, `adopt --managed`, `uninstall --managed`, and usage errors of every command); implies `--non-interactive`. Other commands refuse it with `E_JSON_UNSUPPORTED`. |

Example: `sudo bash tunnelsats.sh install --non-interactive --config tunnelsats_de2.conf --platform raspiblitz --impl lnd`

`status` and `restart` pick the installed tunnel with one rule: `--config` wins, else `/etc/wireguard/tunnelsatsv2.conf`, else the only `/etc/wireguard/tunnelsats-*.conf`. Several `tunnelsats-*.conf` without `tunnelsatsv2.conf` are never guessed: they ask which one, and non-interactive mode fails with `E_INTERACTION_REQUIRED` (pass `--config`). `detect` and `uninstall` take no `--config`: `detect` applies the same rule without the option and reports an unclear choice as `"status": "ambiguous"` with the sorted candidates, and `uninstall` stops and cleans up every TunnelSats tunnel it finds.

JSON documents follow contract 1: `contract`, `command`, `tool_version`, `ok`, `exit_code` and `errors` (`code`, `class`, `message`) plus command fields. Exit codes: `0` success, `1` failure, `2` usage error or interaction required; `verify` and managed mode also use `3` not installed, `4` unsafe, `5` degraded, `6` capability missing, `7` refused, `8` invalid config and `9` unmanaged (`verify` on a standard install). Colours are off when `NO_COLOR` is set or the output is not a terminal.

## Compatibility & Testing Status

We are iteratively validating `tunnelsats.sh` across various Node OS platforms. Note that `tunnelsats.sh` is designed for systemd / bare-metal environments, whereas **Umbrel** and **StartOS** use native containerized app packages.

| Hardware/Platform | Node OS              | OS Version         | Host Script (`tunnelsats.sh`) |                       Native App / Package                       |
| :---------------- | :------------------- | :----------------- | :---------------------------: | :--------------------------------------------------------------: |
| Raspberry Pi / PC | **Umbrel**           | umbrelOS 1.0+      |     N/A (Use Native App)      | ✅ Native Umbrel App (Community Store / Official Review Pending) |
| Any Hardware      | **StartOS (Start9)** | 0.4.0+             |   N/A (Use Native Package)    |   ✅ Native StartOS Package (Start9 Community Registry)   |
| Raspberry Pi      | **RaspiBlitz**       | v1.11.x+           |         ✅ Supported          |    ✅ Built-in SSH Menu (`SUBSCRIBE > TunnelSats` on v1.12+)     |
| PC / VPS          | **Bare Metal**       | Debian 12 / Ubuntu |         ✅ Supported          |                               N/A                                |
| Pi / PC (x86)     | **myNode**           | v0.3.x             |         ✅ Supported          |                               N/A                                |

**Legend:**

- ✅ **Verified / Supported**: Tested and working.
- ⚠️ **Experimental**: Logic exists, but needs live community verification.
- N/A: Platform uses sandboxed container architecture - script execution bypassed in favor of native App Store packages.

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

If you encounter blocking issues with `tunnelsats.sh` (v3.2), you can fall back to the v2 scripts located in the `archive/` folder.

**To use the legacy version:**

```bash
cd archive
sudo bash setupv2.sh
```

These scripts (`setupv2.sh`, `uninstallv2.sh`, etc.) are preserved for compatibility but will strictly be in maintenance mode. Please report any v3 issues so we can fix them!
