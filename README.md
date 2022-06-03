# Tunnel⚡Sats

## Prelude and Objective ##
The lightning network functions in rapid growing speed as infrastructure for payments across the globe between merchants, creators, consumers, institutions and investors alike. Hence the key pillars of sustained growth are their nodes, by providing _reliable_, _liquid_, _discoverable_, _trustless_ and _fast_ connection points between those parties. For fast communication establishing clearnet connections between nodes is inevitable. 

The effort of creating a valuable "clearnet over VPN" node - which we laid out [here](https://blckbx.github.io/lnd-hybrid-mode/) and [here](https://github.com/TrezorHannes/Dual-LND-Hybrid-VPS) - is quite high and intense because it touches several disciplinaries not every node runner is comfortable with. Required knowledge of the command line, firewall handling, network details, trust in and choosing of a suitable VPN provider that offers all the features we need and cares about privacy and, of course, the configuration of the lightning node itself makes it easy to just "leave it as is".

Therefore we came to the conclusion that this process has to be simplified **a lot**. In the last few weeks we put together all the pieces that we think provide the best of all worlds to make it as easy as possible to go hybrid. 

Although thinking this is a suitable way of providing a "hybrid service", we want to emphasize to carefully read through the guide below, make an educated decision by yourself if you want to go clearnet over VPN.


## Table of Content ##

- [Prelude and Objective](#prelude-and-objective)
- [Preconditions](#preconditions)
- [How this works](#how-this-works)
- [What to do](#what-to-do)
- [Deep Dive](#deep-dive)


## Preconditions: ##

- `lnd-0.14.2-beta` or later
- ability to spend some sats (the hardest part)


## How this works: ##

In order to understand the provided scripts and steps we gonna take a deep dive into our service. It is split into two parts: 

1) Setting up the node for hybrid mode (one-time installation) and
2) renting a VPN server and obtaining a corresponding WireGuard config file from [tunnelsats.com](https://www.tunnelsats.com)


## What to do: ##

WireGuard is a fast, lightweight and secure VPN software. We offer a few WireGuard servers in various countries to choose from. 
1) Go to [tunnelsats.com](https://www.tunnelsats.com), select a country of your choice (preferably close to your real location for faster connection speed) and choose how long you want to use the service (1 to 12 months).
2) Pay the lightning invoice.
3) Copy, download or send the Wireguard configuration (file) to your local computer and transfer it to your node.
4) Download the installation script for your setup: [Umbrel](https://tbd) / [other](https://github.com/blckbx/setup/blob/main/setup.sh) (RaspiBolt, RaspiBlitz, MyNode, Start9, bare metal) onto your node.
5) Start installation script.

  Download installation script and copy to `/opt`:
  ```sh
  # for Umbrel:
  $ wget <TBD> && sudo cp setup.sh /opt/
  
  # for other setups:
  $ wget https://github.com/blckbx/setup/blob/main/setup.sh && sudo cp setup.sh /opt/
  ```
  Copy your WireGuard config file (`lndHybridMode.conf`) to `/opt` directory:
  ```sh
  $ sudo cp /path/to/lndHybridMode.conf /opt/
  ```
  Start installation:
  ```sh
  $ cd /opt/
  $ sudo ./setup.sh
  ```


## Deep Dive: ##

What the script is doing in detail:

1) Checking what setup it runs on (RaspiBlitz, MyNode, Start9, RaspiBolt, bare metal or something else (manual input required)) to find out the location of the `lnd.conf` file.
2) Checks if required components are already installed and if not, installs them. These are: cgroup-tools (for split-tunneling Tor), nftables (VPN rules) and wireguard (VPN software).
3) Checks if `lndHybridMode.conf` exists in directory `/opt/`.
4) Sets up "split-tunneling" to exclude Tor from VPN usage as cronjob (this runs continuously to identify Tor restarts).
5) Backing up (`lnd.conf.bak`) and applying changes to `lnd.conf` (listen, externalip, tor.streamisolation, tor.skip-proxy-for-clearnet-targets).
6) Setting UFW rules (if available) to open up VPN forwarded port.
7) Asking user if we should autostart WireGuard (systemd.service).


## Further Help: ##

If you need further help setting up hybrid mode over VPN 
or just want to have a chat with us, join our [Tunnel⚡Sats](https://t.me/+zJfm3gFjv7I5ZTBi) Telegram group.

____________________________________________________________

This service is brought to you by [@ziggie1984](https://github.com/ziggie1984) (Ziggie), [@TrezorHannes](https://github.com/TrezorHannes) (Hakuna) and [@blckbx](https://github.com/blckbx) (osito).

Big thanks to [@LightRider5](https://github.com/LightRider5) ([lnvpn.net](https://lnvpn.net)) 
for providing this amazing frontend framework under MIT License.
