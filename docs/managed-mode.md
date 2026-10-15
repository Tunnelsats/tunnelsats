# Managed mode for bare-metal nodes and RaspiBlitz (preview)

Managed mode is an opt-in alternative for bare-metal systemd nodes (LND, CLN or LIT on Debian or Ubuntu) and for RaspiBlitz (see [RaspiBlitz](#raspiblitz)). Its kill switch stays armed across tunnel restarts, reboots and package upgrades, and `verify` checks the protection at any time. When the subscription ends or the VPN server is unreachable, Lightning keeps running over Tor and the local network; only clearnet pauses until the tunnel is back.

```bash
sudo bash tunnelsats.sh install --managed baremetal --config tunnelsats_<server>.conf
sudo tunnelsats verify
sudo tunnelsats uninstall --managed
```

## How it works

- The Lightning unit runs in its own systemd slice, `tunnelsats.slice`, set by a drop-in. The unit file itself is never edited, so package upgrades keep the setting.
- A persistent nftables table (`inet tunnelsats`) marks the connections of the slice and sends them to routing table 51820. That table always holds a blackhole route and holds the route into the tunnel only while the tunnel is up, so while the tunnel is down the slice's clearnet traffic is blocked instead of taking the regular internet connection. Your local network and Tor through the local proxy keep working.
- A oneshot unit (`tunnelsats-killswitch.service`) arms the kill switch at boot, before Lightning and the tunnel start. A verifier timer checks it every 30 seconds and re-arms it if anything removed or changed it.
- Lightning starts once the kill switch is armed or, as a fallback, the emergency block (below) is in place, and keeps running when the tunnel goes down. The drop-in makes the Lightning unit require the kill switch unit (`Requires=` and `After=`). Stopping or restarting `tunnelsats-killswitch.service` stops or restarts Lightning as well; the verifier never restarts it.
- Install records every file in `/etc/tunnelsats/managed.json` before writing it, so `uninstall --managed` removes exactly what install created, even after an interrupted install. Only one `install --managed` or `uninstall --managed` runs at a time; a second one refuses with `E_BUSY` (exit 7) and changes nothing.
- Your node configuration stays yours: install prints the hybrid settings to add, as the standard install does, and never edits the file.

## Requirements

- A bare-metal systemd node or a RaspiBlitz (Umbrel and myNode come later) with a unified cgroup v2 hierarchy and Linux 5.13 or newer.
- One Lightning unit (`lnd.service`, `lightningd.service`, `litd.service` or `lit.service`) that runs as a dedicated, non-root `User=`. If several are installed, choose one with `--impl`; the others are not tunneled. On RaspiBlitz, `--impl` and `--network` name the unit.
- perl, which `verify` uses for its datagram probes. Debian and Ubuntu always ship it (`perl-base`); without it install refuses with `E_DEPENDENCY_MISSING`.
- No other TunnelSats install: run `tunnelsats.sh uninstall` first. Taking over an existing install comes in a later version.
- No Tailscale exit node: its routing rules come before the TunnelSats rules.

## When the subscription ends or the VPN server is unreachable

- Lightning keeps running, and starts again after a reboot.
- Clearnet connections are dropped until the tunnel is back; nothing takes the regular internet connection instead.
- Onion peers, and inbound connections over your onion address, keep working.
- The local network keeps working.
- `verify` reports `degraded` (exit 5) with `clearnet_blocked: true`.

Once the tunnel is back, clearnet connections resume on their own.

## Checking it: `verify`

`verify` reads the kernel state and probes from inside the slice:

| Verdict | Exit code | Meaning |
| :------ | :-------: | :------ |
| `protected` | 0 | Every check passes, the probes included. |
| `degraded` | 5 | The kill switch holds and the slice's clearnet traffic is blocked, but the tunnel does not carry it right now (tunnel down, no handshake), or the emergency block is in effect. |
| `unsafe` | 4 | Anything else. A check that cannot run counts here. |
| `unmanaged` | 9 | A standard install. `verify` reports the tunnel handshake and its kill switch table, which is active while the tunnel is up. |

Configuration alone never gives `protected`. `--no-probe` limits `verify` to the kernel checks. The probes run from inside the slice, in this order:

1. **Kill switch probe**: one UDP datagram to the VPN server (the WireGuard endpoint, port 9). It must be stopped on this host. It needs no DNS and no reply, and if it ever got out, it would reach only the VPN server, which knows your node's address as its WireGuard peer anyway.
2. **Egress probe**: the IP echo services (api.ipify.org, ipv4.icanhazip.com) must both see the tunnel's exit address.
3. **IPv6 probe**: one UDP datagram to the IPv6 address of tunnelsats.com, which must be stopped on this host as well. Skipped when the host or tunnelsats.com has no IPv6.

Probes 2 and 3 run only after the kernel checks found the kill switch in place and the kill switch probe passed (a stopped Lightning unit does not hold them back), and only while no emergency rule is present; otherwise `verify` reports them as skipped, with the reason. So the echo services are asked only once the direct path was shown closed, and they see the tunnel's exit address at most.

The JSON document also reports `emergency_block` (true while the emergency block is in effect) and `emergency_state`: `none`, `active`, `bypassed` (its rules exist, but a routing rule of another tool comes before them) or `incomplete` (only part of its rules exist).

## Emergency block

If the kill switch cannot be armed, or the verifier cannot re-arm it, managed mode blocks the internet clearnet traffic of the Lightning user instead (policy rules at priorities 21818 and 21819, IPv4 and IPv6). The block stays until a re-arm succeeds and is read back. At boot, Lightning starts behind it. While the block is active:

- Lightning has no internet clearnet connections. Tor through the local proxy keeps working, and so does the local network: exemptions at priority 21817 keep 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, fc00::/7 and fe80::/10 reachable, but only networks the host has a specific route for (on-link, or routed explicitly). A missing exemption costs only that network; `verify` reports it as `emergency_lan`.
- Other processes that run as the same user are covered too: bitcoind under the same user keeps its local network peers but loses its internet clearnet peers.
- `verify` reports `degraded` with `emergency_block: true` and `emergency_state: active`. While the kill switch is not armed, its kill switch probe runs as the Lightning user, so it tests the block itself. Emergency rules that remain beside an armed kill switch (the verifier removes them after its re-arm) are reported as `degraded` too.

The block works through routing rules, so a routing rule of another tool that comes before it (a priority below 21818, for example from another VPN client) could route Lightning's traffic around it. Managed mode treats the block as in effect only when no such rule exists; Tailscale's rules count only while an exit node is active. Otherwise `verify` reports `unsafe` with `emergency_state: bypassed` and names the rule, `tunnelsats-killswitch.service` fails so Lightning does not start, and the verifier logs it once. If Lightning is already running when neither the kill switch nor the block holds, the verifier stops the Lightning unit, checks that it stopped, and starts it again once one of them holds. If that start fails, the verifier tries again with each check, up to ten times (about five minutes), and then logs the command to start it by hand.

## A damaged install record

If `/etc/tunnelsats/managed.json` is damaged or missing, the kill switch cannot be armed, because the record says what to arm. The kill switch unit carries the Lightning uid in its own command line (`managed-arm --fallback-uid <uid>`), so it arms the emergency block for that uid and Lightning still starts, with clearnet traffic blocked and Tor and the local network working. The verifier reads that uid from systemd or, if systemd does not answer, from the unit file. The block is never released while the record is unreadable; the verifier keeps it in place and logs the state once. If the block does not take effect, or the uid cannot be read at all, the verifier stops the Lightning unit as described above. `verify` reports `install_state: damaged` and `degraded`, with `action_required`: restore the record (for example from a backup) or reinstall. Once the record is back, the verifier re-arms the kill switch and releases the block.

## When Lightning stays stopped

Lightning stays stopped only while neither the kill switch nor the emergency block holds (the kernel refuses the block's routing rules, a routing rule of another tool comes before them, or the Lightning uid cannot be read), and after `uninstall --managed` while TunnelSats settings remain in the node configuration or on the unit's command line, or that command line cannot be checked (see Uninstall). In every other case it starts, tunneled or behind the emergency block.

## `--uid-backstop`

`install --managed baremetal --uid-backstop` additionally routes all traffic of the Lightning user into the tunnel by uid. That also covers the moments when the kill switch table is missing (see below). As a side effect, remote access to gRPC or REST through a port forward on your home connection stops working, because the replies go into the tunnel. Use Tor, Tailscale or ZeroTier, or your local network for remote access instead.

## When something removes the kill switch table

An external `nft flush ruleset`, or a firewall tool that replaces the whole ruleset, removes the kill switch table. The verifier re-arms it within its 30-second interval; in CI it took 23 to 29 seconds. Without `--uid-backstop`, new outbound connections of the node use the regular internet connection during that gap: in CI, a loop of short connections to a peer sent about 360 packets that way in 28 seconds. With `--uid-backstop`, no packet left outside the tunnel during the gap. A `verify` run during the gap reports `unsafe`: its kill switch datagram leaves the host, and the echo services are not asked.

## Uninstall

`sudo tunnelsats uninstall --managed` stops the Lightning unit, removes the managed dataplane and reads the result back. It starts Lightning again only if no TunnelSats clearnet settings remain, neither in the node configuration nor on the unit's command line (`ExecStart=`), since outside the tunnel those settings would use the regular internet connection. Otherwise Lightning stays stopped, the unit is disabled so that no boot starts it with those settings, and the exact lines to remove are printed; remove them, then run `sudo systemctl enable --now <unit>`. Lightning also stays stopped and disabled when the command line cannot be checked reliably (it runs through a shell, uses `$VARIABLES` or starts a script; for RaspiBlitz's shell command for CLN and the variable of a RaspiBlitz start guard, see [RaspiBlitz](#raspiblitz)). If the unit cannot be disabled, uninstall reports an error with the command to run.

If something cannot be removed, uninstall lists it and keeps `/etc/tunnelsats/managed.json` (state `removing`), the installed script and the emergency block records, so you can run `uninstall --managed` again once the cause is fixed. Meanwhile `detect` reports `managed_state: removing`.

## RaspiBlitz

```bash
sudo bash tunnelsats.sh install --managed raspiblitz --impl lnd --config tunnelsats_<server>.conf
sudo bash tunnelsats.sh install --managed raspiblitz --impl cln --network testnet --config tunnelsats_<server>.conf
```

The dataplane is the same as on bare metal. What differs:

- RaspiBlitz runs one unit per implementation and chain, so the profile names the unit instead of picking one. `--impl` (`lnd` or `cln`) is required; `--network` defaults to `mainnet`. The unit must be installed, otherwise install refuses with `E_LN_UNIT` (exit 7). Other RaspiBlitz Lightning units are not tunneled; install lists them in `other_ln_units`.

  | | `--network mainnet` | `--network testnet` | `--network signet` |
  | :-- | :-- | :-- | :-- |
  | `--impl lnd` | `lnd.service` | `tlnd.service` | `slnd.service` |
  | `--impl cln` | `lightningd.service` | `tlightningd.service` | `slightningd.service` |

- Install refuses on a node that is not a RaspiBlitz, and `--managed baremetal` refuses on a RaspiBlitz (`E_PLATFORM_UNSUPPORTED`).
- Node configuration: for LND the file its unit names (`/mnt/hdd/app-data/lnd/lnd.conf`, `tlnd.conf`, `slnd.conf`); for CLN `/home/bitcoin/.lightning/config` (testnet and signet: `testnet/config`, `signet/config`), which links to `/mnt/hdd/app-data/.lightning`. RaspiBlitz starts CLN through `/bin/sh -c` to pass the password of an encrypted `hsm_secret`; managed mode reads that exact command, so `uninstall --managed` can check CLN's command line. Any other shell command still counts as one that cannot be checked.
- The TunnelSats server forwards to port 9735. RaspiBlitz's testnet and signet LND listen on 19735 and 39735 by default, so install refuses them with `E_LN_PORT` until they listen on 9735.
- bitcoind runs as the same user (`bitcoin`). While the emergency block is active, bitcoind keeps only its Tor and local network peers; with `--uid-backstop`, its clearnet connections use the tunnel as well.
- RaspiBlitz rewrites the unit files, for example when an instance is reinstalled or its `hsm_secret` gets encrypted; the drop-in in `/etc/systemd/system/<unit>.d/` stays.
- Install never starts a Lightning unit that was not running. An inactive unit stays inactive, and a unit that waits for its automatic restart (`Restart=always`, every 60 seconds on RaspiBlitz) starts inside the slice at that restart. A running unit is restarted into the slice.

### SD-card updates

An SD-card update replaces the system: the managed units, the drop-in, `/etc/tunnelsats/managed.json`, the tunnel config and the installed script are gone, while the data drive keeps the node configuration. Managed mode is restored during provisioning, as root (on RaspiBlitz from `/mnt/hdd/app-data/custom-installs.sh`):

```bash
tunnelsats.sh install --managed raspiblitz --impl <lnd|cln> [--network <chain>] --config <copy on the data drive> --non-interactive --yes --json
```

This runs unattended: it never prompts, never starts a Lightning unit that was not running, and prints exactly one JSON document. A failure names its error code (for example `E_LN_UNIT`, `E_CONFIG_INVALID` for a missing or invalid `--config` file, `E_LN_PORT`, or `E_MANAGED_PRESENT` when a managed install exists already, which `verify` then checks) and exits with the documented exit code.

Until managed mode is restored, Lightning is Tor-only. Provisioning starts it before the install runs; `verify` finds no managed install then, so the start guard (below) starts Lightning without clearnet flags, over Tor and the local network. Once the install has run, it restarts a running Lightning unit into the slice, and the guard gives that start its clearnet flags; a unit that waits for its automatic restart gets them at that restart.

### The start guard contract

Managed mode never edits the Lightning unit or its clearnet settings. A start guard in the unit, such as the one of the RaspiBlitz integration in review, decides at every start whether Lightning gets clearnet flags for that start. The guard runs as root before Lightning starts (`ExecStartPre=+`) and calls

```bash
/usr/local/sbin/tunnelsats verify --json --no-probe
```

This changes no kernel state, unit or file (its comparison uses a temporary file and a throwaway network namespace) and sends no probes. It resolves the VPN server's host name once, for at most 5 seconds; a lookup that gets no answer in that time is reported as such in the `wg_endpoint` check.

- Clearnet flags only on exit code 0 (`protected`) or 5 (`degraded`: the kill switch or the emergency block holds), and only when `unit` in the JSON document is the guarded unit and `emergency_block` is `false`. Lightning then starts inside the slice, behind the armed kill switch, with the clearnet flags for this start.
- Anything else starts Lightning Tor-only, without clearnet flags: exit code 3 (no managed install, as right after an SD-card update), 4 (`unsafe`), 9 (a standard install), 1 or 2 (errors), `emergency_block: true`, another `unit`, a missing command, no document in time or one that cannot be read. Tor and the local network keep working.
- Without a managed install (no install record and no kill switch unit), `verify` exits 3, or 9 on a standard install; never 0 or 5. While the install record is damaged, `unit` is null, so Lightning starts Tor-only until the record is restored.
- The guard and the verifier agree: while no protection holds, the verifier keeps Lightning stopped (see [Emergency block](#emergency-block)) and `verify` exits 4, so no start gets clearnet flags; once a protection holds again, the verifier starts Lightning, and that start passes the guard.

**Fields of contract 1.** The guard relies on these fields of the `verify` document: `contract`, `command`, `ok`, `exit_code`, `managed`, `profile`, `install_state`, `unit`, `impl`, `emergency_block`, `verdict`, `probes`, `checks[].id`, `checks[].class`, `checks[].result`, `endpoint.host`, `endpoint.ipv4` and `endpoint.vpn_port`. They are part of contract 1: renaming one of them, or changing what its values mean, needs a contract bump.

**Flags for one start.** The guard passes the flags through one variable at the end of the Lightning command line, read from `/run/tunnelsats/hybrid-<name>.env` (for example `hybrid-tlnd.env` for `tlnd.service`). It rewrites that file before every start, with the flags or with an empty value; while the file is absent, the unit's `Environment=` line keeps the variable empty. The node configuration stays Tor-only, and the file does not survive a reboot. In the RaspiBlitz integration, the unit of mainnet LND holds these lines (CLN passes `$$TUNNELSATS_CLN_ARGS` at the end of RaspiBlitz's `sh -c` command):

```ini
Environment=TUNNELSATS_LND_ARGS=
EnvironmentFile=-/run/tunnelsats/hybrid-lnd.env
ExecStartPre=+/bin/sh -c 'if [ -x /home/admin/config.scripts/internet.tunnelsats.sh ]; then exec /home/admin/config.scripts/internet.tunnelsats.sh guard lnd mainnet; fi; echo tunnelsats-guard: internet.tunnelsats.sh is missing, Lightning starts Tor-only >&2; mkdir -p /run/tunnelsats && echo TUNNELSATS_LND_ARGS= > /run/tunnelsats/hybrid-lnd.env'
ExecStart=/usr/local/bin/lnd --configfile=/mnt/hdd/app-data/lnd/lnd.conf $TUNNELSATS_LND_ARGS
```

**When the guard script is missing.** The guard line runs the guard script only if it is there. Otherwise it writes the empty value itself and logs that Lightning starts Tor-only, for example after an update that brings back RaspiBlitz code without the integration.

**Uninstall.** `uninstall --managed` reads the variable through only when the unit carries the guard exactly in this form: no `daemon-reload` pending, no drop-in except the managed one, and the `[Service]` section of the unit file holds `Environment=<variable>=`, `EnvironmentFile=-/run/tunnelsats/hybrid-<name>.env` as its last `EnvironmentFile=`, the guard line as its last `ExecStartPre=` and the `ExecStart=` systemd runs, each once, with the variable on no other line and no empty assignment that clears one of them. The env file then decides, as it was before the removal cleared `/run/tunnelsats`. Absent or empty, no clearnet flags are in use and the command line counts as clean. With flags, TunnelSats is still on in RaspiBlitz: Lightning stays stopped and disabled, and `action_required` says to remove TunnelSats in the RaspiBlitz menu (SUBSCRIBE > TunnelSats > REMOVE), then to run `sudo systemctl enable --now <unit>`. Any other variable still makes the command line one that cannot be checked.
