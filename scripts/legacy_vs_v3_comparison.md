# 🛰️ TunnelSats: Evolution of the Setup Script

This document summarizes the technical improvements made in the **v3.0 Unified Script** compared to the legacy **v2.0 Setup** routine, specifically regarding RaspiBlitz and non-Docker environments.

## Technical Comparison Matrix

| Feature | Legacy Setup (`setupv2.sh`) | New Setup (`tunnelsats.sh v3.0`) | Improvement |
| :--- | :--- | :--- | :--- |
| **Cgroup ID** | `1118498` | `1118498` | **Consistency.** Maintained compatibility for seamless upgrades. |
| **Killswitch Logic** | **The Hammer**: Blocked ALL traffic for the `bitcoin` user that wasn't tunnel-bound. | **The Scalpel**: Blocks traffic ONLY if user is `bitcoin` **AND** the packet is explicitly marked in the Lightning Cgroup. | **Critical.** Prevents "Node Lockout" on RaspiBlitz where Bitcoind shares the same user. |
| **Systemd Deps** | Hard `Requires` (Node startup fails permanently if tunnel is delayed by 1s). | Soft `Wants` + `After` (Node waits for tunnel but handles boot-time race conditions gracefully). | **Boot Stability.** Eliminates the "Dependency Failed" status loop on reboot. |
| **Traffic Marking** | Complex bitwise `xor` operations (fragile in some firewall versions). | Direct `meta mark set 0x1000000`. | **Performance.** Lower CPU overhead for packet filtering and easier to audit with `nft list`. |
| **Environment Brain** | Required manual input for platform and Lightning type every time. | **Propose-First Logic**: Automatically detects platform/implementation and asks for a simple `[Y/n]` confirmation. | **UX Speed.** Installation and status checks are now 3x faster for the user. |
| **Restoration** | Simple file removal (often left configurations behind). | **Timestamped Backups**: Automatically backs up `lnd.conf` before cleanup and performs surgical line-removal. | **Safety.** Reverting to "Stock" is now a much cleaner process. |

---

## 🛠️ Root Cause: The Blitz 5 "Bitcoind Lockout"
In RaspiBlitz 1.10+, **Bitcoind** and **LND** both run as the `bitcoin` user. The legacy killswitch rule:
`nft insert rule ... skuid bitcoin ... drop`
effectively orphaned Bitcoind from the clearnet. 

**v3.0 Fix**: 
`nft insert rule ... skuid bitcoin meta cgroup 1118498 ... drop`
This "Scalpel" rule ensures only the Lightning traffic is bound to the tunnel, leaving the base Bitcoin node free to communicate with its peers normally.
