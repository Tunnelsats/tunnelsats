<p>
<img src="/docs/assets/tunnelsats_banner_1280_640.png" width="640" title="TunnelSats Banner" />
</p>

<br/>

## Prelude and Objective ##
The lightning network functions in rapid growing speed as infrastructure for payments across the globe between merchants, creators, consumers, institutions and investors alike. Hence the key pillars of sustained growth are their nodes, by providing _reliable_, _liquid_, _discoverable_, _trustless_ and _fast_ connection points between those parties. For fast communication establishing clearnet connections between nodes is inevitable. 

The effort of creating a valuable "clearnet over VPN" node - which we laid out [here](https://blckbx.github.io/lnd-hybrid-mode/) and [here](https://github.com/TrezorHannes/Dual-LND-Hybrid-VPS) - is quite high and intense because it touches several disciplines not every node runner is comfortable with. Required knowledge of the command line, firewall handling, network details, trust in and choosing of a suitable VPN provider that offers all the features we need and cares about privacy and security and, of course, the configuration of the lightning node itself makes it easy to just "leave it as is". Therefore we came to the conclusion that this process has to be simplified **a lot**. In the last few weeks we put together all the pieces that we think provide the best of both worlds to make it as easy as possible to go hybrid. 

Although thinking this is a suitable way of providing a "hybrid service", we want to emphasize to carefully read through the guide below, make an educated decision by yourself if you want to go clearnet over VPN.

<br/>

<!-- omit in toc -->
## Table of Content ##

- [Prelude and Objective](#prelude-and-objective)
- [Preconditions](#preconditions)
- [How this works](#how-this-works)
- [Install](#install)
- [Enabling hybrid mode](#enabling-hybrid-mode)
  - [LND](#lnd)
  - [CLN](#cln)
- [Renew Subscription](#renew-subscription)
- [Uninstall](#uninstall)
- [Deep Dive](#deep-dive)
- [Further Help](#further-help)

<br/>

## Preconditions ##

- OS: Debian-/Ubuntu-based (apt-get required)
- Linux kernel version: 5.10+ (`uname -srm`)
- nftables version: 0.9.7+ (`nft -v` or `apt search nftables | grep "^nftables"`)
- LND latest (minimal requirement `0.14.2-beta`)
- CLN latest
- only **one** lightning implementation per system is supported (configured to port 9735)
- edit your lightning configuration file (`lnd.conf` / `config`)
- ability to spend some sats (the hardest part)

<br/>

## How this works ##

In order to understand the provided scripts and steps we gonna take a deep dive into our service. It is split into three parts: 

1) Renting a VPN server and obtaining a corresponding WireGuard config file from [tunnelsats.com](https://www.tunnelsats.com),

2) installing required software and components to make VPN connection and Tor splitting work and

3) setting up the node for hybrid mode by editing the lightning configuration file as described below. 

<br/>

## Install ##

WireGuard is a fast, lightweight and secure VPN software. We offer a few WireGuard servers and quantum-safe VPN tunnels in various countries to choose from. 

1) Go to [tunnelsats.com](https://www.tunnelsats.com), select a country of your choice (preferably close to your real location for faster connection speed) and choose how long you want to use the service (1 to 12 months).

2) Pay the lightning invoice.

3) Copy, download or send the wireguard configuration (file: `tunnelsatsv2.conf` - please do NOT rename this file) to your local computer and transfer it to your node.

4) Backup `tunnelsatsv2.conf` to a safe place (to prevent deletion on updates, for example on RaspiBlitz create a new directory called `/tunnelsats/` and save the config file in there: `/mnt/hdd/app-data/tunnelsats/`)

5) Download the setup script onto your node.

  Download setup script:
  
  ```sh
  $ wget -O setupv2.sh https://github.com/blckbx/tunnelsats/raw/main/scripts/setupv2.sh
  ```

  Copy your WireGuard config file (`tunnelsatsv2.conf`) to the same directory where `setupv2.sh` is located. If you need to transfer it to your node, use `scp` like so:
  
  ```sh
  $ scp tunnelsatsv2.conf <user>@<ip/hostname>:/<path-to-home-dir>
  ```
  
  e.g. for Umbrel: ` scp tunnelsatsv2.conf umbrel@umbrel.local:/home/umbrel/ `
  

  Make sure that both files (tunnelsatsv2.conf and setupv2.sh) are located in the same directory. Then start it:
  
  ```sh
  $ sudo bash setupv2.sh
  ```
  
  If everything went fine, your selected VPN's credentials and further instructions are shown to adjust the lightning configuration file. Copy to file or write them down for later use (e.g. LND config):
  
  ```ini
  #########################################
  [Application Options]
  listen=0.0.0.0:9735
  externalhosts={vpnDNS}:{vpnPort}
  
  [Tor]
  tor.streamisolation=false
  tor.skip-proxy-for-clearnet-targets=true
  #########################################
  ```

<br/>
  
## Enabling hybrid mode ##

Before applying any changes to your config files, please __always__ create a backup! For example:

  ```sh
  $ cp /path/to/lnd.conf /path/to/lnd.conf.backup
  ```

⚠️ __Important Notice__: The following parts show how to configure LND and CLN implementations for hybrid mode. Regarding the status of this project, we currently only support one lightning implementation at a time. This means: If you plan to run both LND and CLN in parallel, only one (the one listening on port 9735) is routed over VPN, other ones default to Tor-only. Nevertheless, it is possible to bind or switch default ports on various node setups.

<br/>

### LND

Running LND only requires a few parameters to be checked and set to activate hybrid mode. Locate `lnd.conf` depending on your node setup. See the [FAQ](https://blckbx.github.io/tunnelsats/FAQ.html#where-do-i-find-my-lndconf-file) for some default path examples. Please edit the file and put the settings shown below into their corresponding sections. If any of these settings are already present, comment them out and add the new ones below. We need to add or modify the following settings:

  ```ini
  [Application Options]
  listen=0.0.0.0:9735
  externalhosts={vpnDNS}:{vpnPort} #these infos are provided at the end of the setupv2.sh script
  
  [Tor]
  # set streamisolation to 'false' if currently set 'true'. if not set at all, just leave it out
  tor.streamisolation=false
  tor.skip-proxy-for-clearnet-targets=true
  ```

<br/>

### CLN

With CLN it's a bit trickier. Most node setups like Umbrel, RaspiBolt, RaspiBlitz etc. default CLN's daemon port to `9736`. So in order to route CLN clearnet over VPN, we need to change CLN's default port to `9735`. The following shows how to edit non-docker CLN configuration:

Locate data directory of your CLN installation. By default CLN's configuration is stored in a file named `config`. Edit the file and look out for network settings section. Configured to hybrid it should look like this:

  ```ini
  bind-addr=0.0.0.0:9735
  announce-addr={vpnDNS}:{vpnPort}
  always-use-proxy=false
  ```

On docker-based systems this might look very different. The following shows how to enable hybrid on Umbrel v0.5+:

- Apps installed: Bitcoin, CLN (LND may NOT be installed at the same time)
- Working Directory: `~/umbrel/app-data/core-lightning/`
- File to look for: `export.sh`
- Changes to be made: 

__export.sh__: change port number from 9736 to 9735
  ```ini
  export APP_CORE_LIGHTNING_DAEMON_PORT="9736"
  ```
change to
  ```ini
  export APP_CORE_LIGHTNING_DAEMON_PORT="9735"
  ```

⚠️ __Important Notice:__ On updates of CLN app `export.sh` is getting reset. So this change has to be done after every update procedure of CLN!  

Additionally we create a persistent CLN config file (if not already provided. Umbrel 0.5+ does not initially.):

  ```sh
  $ nano ~/umbrel/app-data/core-lightning/data/lightningd/bitcoin/config
  ``` 
and enter the following settings:

  ```ini
  bind-addr=10.9.9.9:9735
  always-use-proxy=false
  announce-addr={vpnDNS}:{vpnPort}
  ```

⚠️ After enabling hybrid mode in related configuration files, restart the lightning implementation for changes to take effect!

<br/>

## Renew Subscription

Renewal of existing subscriptions has been reworked. Now it is possible to prolong your subscription by extending the current fixed term. Here is how it works:
- go to [tunnelsats.com](https://tunnelsats.com) and select "Renew Subscription" on the navigation bar
- enter the WireGuard public key (find it either commented out in your `tunnelsatsv2.conf`, look for `#myPubKey` line (new subscriptions) or in your wireguard connection details via `sudo wg show | grep peer`)
- click "Query Key Info" to fetch your current valid date
- select the desired term extension of your choice (it is appended to the current expiry)
- click "Update Subscription" and pay the lightning invoice

⚠️ No new WireGuard file will be handed over to the user. The current lightning settings persist! So there is no further lightning configuration needed. Changing server locations on renewals is not supported for now.

<br />

## Uninstall ##

To restore all applied changes made to your node setup, download and run the uninstallv2 script. Furthermore remove entries from configuration files.

  ```sh
  $ wget -O uninstallv2.sh https://github.com/blckbx/tunnelsats/raw/main/scripts/uninstallv2.sh
  $ sudo bash uninstallv2.sh
  ```
Restore your configuration from with the backup file you (hopefully) created on setting up hybrid mode. The uninstall script will take care of the most important part to prevent real IP leaks by disabling/removing hybrid settings in respective configuration files.

<br/>

## Deep Dive ##

What is the `setupv2.sh` script doing in detail?

1) Checking if required components are already installed and if not, installing them. These are: `cgroup-tools` (for split-tunneling Tor), `nftables` (VPN rules) and `wireguard` (VPN software).

2) Checking if `tunnelsatsv2.conf` exists in current directory (must be the same directory where setupv2 script is located).

3) Setting up "split-tunneling" to exclude Tor traffic from VPN usage.

4) Enabling and starting required systemd services (wg-quick@.service, splitting.service) or network container for docker-based solutions.

5) Adding client-side nftables ruleset enabling kill-switching and preventing DNS leakage.

<br/>

## Further Help ##

Please review the [FAQ](FAQ.md) for further help.
If you need help setting up hybrid mode over VPN
or just want to have a chat with us, join our [Tunnel⚡Sats](https://t.me/+NJylaUom-rxjYjU6) Telegram group.

____________________________________________________________

This service is brought to you by [@ziggie1984](https://github.com/ziggie1984) (Ziggie), [@TrezorHannes](https://github.com/TrezorHannes) (Hakuna) and [@blckbx](https://github.com/blckbx) (osito).

Special thanks to [@LightRider5](https://github.com/LightRider5) ([lnvpn.net](https://lnvpn.net)) 
for providing this amazing frontend framework and for help and support.
