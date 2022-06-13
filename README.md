![TunnelSatsLogo](/docs/assets/tunnelsats11.png)

## Prelude and Objective ##
The lightning network functions in rapid growing speed as infrastructure for payments across the globe between merchants, creators, consumers, institutions and investors alike. Hence the key pillars of sustained growth are their nodes, by providing _reliable_, _liquid_, _discoverable_, _trustless_ and _fast_ connection points between those parties. For fast communication establishing clearnet connections between nodes is inevitable. 

The effort of creating a valuable "clearnet over VPN" node - which we laid out [here](https://blckbx.github.io/lnd-hybrid-mode/) and [here](https://github.com/TrezorHannes/Dual-LND-Hybrid-VPS) - is quite high and intense because it touches several disciplinaries not every node runner is comfortable with. Required knowledge of the command line, firewall handling, network details, trust in and choosing of a suitable VPN provider that offers all the features we need and cares about privacy and, of course, the configuration of the lightning node itself makes it easy to just "leave it as is".

Therefore we came to the conclusion that this process has to be simplified **a lot**. In the last few weeks we put together all the pieces that we think provide the best of both worlds to make it as easy as possible to go hybrid. 

Although thinking this is a suitable way of providing a "hybrid service", we want to emphasize to carefully read through the guide below, make an educated decision by yourself if you want to go clearnet over VPN.


## Table of Content ##

- [Prelude and Objective](#prelude-and-objective)
- [Preconditions](#preconditions)
- [How this works](#how-this-works)
- [What to do](#what-to-do)
- [Enabling hybrid mode in `lnd.conf`](#enabling-hybrid-mode-in-lndconf)
- [Uninstall](#uninstall)
- [Deep Dive](#deep-dive)
- [Further Help](#further-help)


## Preconditions: ##

- `lnd-0.14.2-beta` or later
- edit your node's `lnd.conf` file
- ability to spend some sats (the hardest part)


## How this works: ##

In order to understand the provided scripts and steps we gonna take a deep dive into our service. It is split into three parts: 

1) Renting a VPN server and obtaining a corresponding WireGuard config file from [tunnelsats.com](https://www.tunnelsats.com),

2) installing required software and components to make VPN connection and Tor splitting work and

3) setting up the node for hybrid mode by editing `lnd.conf` and modifying only 4 parameters within the file. 


## What to do: ##

WireGuard is a fast, lightweight and secure VPN software. We offer a few WireGuard servers in various countries to choose from. 
1) Go to [tunnelsats.com](https://www.tunnelsats.com), select a country of your choice (preferably close to your real location for faster connection speed) and choose how long you want to use the service (1 to 12 months).

2) Pay the lightning invoice.

3) Copy, download or send the Wireguard configuration (file: `tunnelsats.conf` - please do NOT rename this file) to your local computer and transfer it to your node.

4) Download the setup script, transfer wireguard config file (tunnelsats.conf) and run it.

  Download setup script:
  
  ```sh
  $ wget https://github.com/blckbx/setup/raw/main/setup.sh
  ```

  Copy your WireGuard config file (`tunnelsats.conf`) to the same directory where `setup.sh` is located. If you need to transfer it to your node, use `scp` like so:
  
  ```sh
  $ scp tunnelsats.conf <user>@<ip/hostname>:/<path-to-home-dir>
  ```
  
  e.g. for Umbrel: ` scp tunnelsats.conf umbrel@umbrel.local:/home/umbrel/ `
  

  Make sure that both files (tunnelsats.conf and setup.sh) are located in the same directory. Then start it:
  
  ```sh
  $ sudo bash setup.sh
  ```
  
  If everything went fine, your selected VPN's credentials and further instructions are shown to adjust `lnd.conf`. Copy to file or write them down for later use:
  
  ```ini
  #########################################
  [Application Options]
  listen=0.0.0.0:9735
  externalip={vpnIP}:{vpnPort}
  
  [Tor]
  tor.streamisolation=false
  tor.skip-proxy-for-clearnet-targets=true
  #########################################
  ```
  

## Enabling hybrid mode in `lnd.conf`: ##

Before applying any changes to your `lnd.conf`, please create a backup! For example:

  ```sh
  $ sudo cp /path/to/lnd.conf /path/to/lnd.conf.backup
  ```

A few parameters have to be checked and set to activate hybrid mode:

  ```ini
  [Application Options]
  listen=0.0.0.0:9735
  externalip={vpnIP}:{vpnPort} #these infos are provided at the end of the setup script
  
  [Tor]
  # set steamisolation to 'false' if it's currently set 'true'. if it's not set at all, just leave it out
  tor.streamisolation=false
  tor.skip-proxy-for-clearnet-targets=true
  ```
  
Important notice: Please uncomment or remove any other `listen=` parameters like `listen=localhost`, `externalip=` and / or `externalhosts=` settings. They can potentially interfere with VPN settings. In summary:

  ```ini
  # Uncomment any of these parameters if present:
  #listen=localhost
  #externalip=...
  #externalhosts=...
  ```

## Uninstall: ##

To restore all applied changes made to your node setup, download and run the uninstall script. Furthermode remove entries from `lnd.conf` / restore your previous settings and restart `lnd.service`.

  ```sh
  $ wget https://github.com/blckbx/setup/raw/main/uninstall.sh
  $ sudo bash uninstall.sh
  ```
Restore your `lnd.conf` with the backup file you (hopefully) created on setting up hybrid mode. 


## Deep Dive: ##

What is this script doing in detail?

1) Checking if required components are already installed and if not, installs them. These are: `cgroup-tools` (for split-tunneling Tor), `nftables` (VPN rules) and `wireguard` (VPN software).

2) Checks if `tunnelsats.conf` exists in current directory (must be the same directory where setup script is located).

3) Sets up "split-tunneling" to exclude Tor from VPN usage as systemd service to run after Tor (re)starts.

4) Enabling and starting required systemd services (wg-quick, splitting).

5) Setting UFW rules (if installed) to open up the VPN provided forwarded port.


## Further Help: ##

Please review the [FAQ](FAQ.md) for further help. 
If you need any other help setting up hybrid mode over VPN
or just want to have a chat with us, join our [Tunnel⚡Sats](https://t.me/+NJylaUom-rxjYjU6) Telegram group.

____________________________________________________________

This service is brought to you by [@ziggie1984](https://github.com/ziggie1984) (Ziggie), [@TrezorHannes](https://github.com/TrezorHannes) (Hakuna) and [@blckbx](https://github.com/blckbx) (osito).

Big thanks to [@LightRider5](https://github.com/LightRider5) ([lnvpn.net](https://lnvpn.net)) 
for providing this amazing frontend framework under MIT License.
