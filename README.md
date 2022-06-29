![TunnelSatsLogo](/docs/assets/tunnelsats11.png)

<br/>

## Prelude and Objective ##
The lightning network functions in rapid growing speed as infrastructure for payments across the globe between merchants, creators, consumers, institutions and investors alike. Hence the key pillars of sustained growth are their nodes, by providing _reliable_, _liquid_, _discoverable_, _trustless_ and _fast_ connection points between those parties. For fast communication establishing clearnet connections between nodes is inevitable. 

The effort of creating a valuable "clearnet over VPN" node - which we laid out [here](https://blckbx.github.io/lnd-hybrid-mode/) and [here](https://github.com/TrezorHannes/Dual-LND-Hybrid-VPS) - is quite high and intense because it touches several disciplines not every node runner is comfortable with. Required knowledge of the command line, firewall handling, network details, trust in and choosing of a suitable VPN provider that offers all the features we need and cares about privacy and security and, of course, the configuration of the lightning node itself makes it easy to just "leave it as is". Therefore we came to the conclusion that this process has to be simplified **a lot**. In the last few weeks we put together all the pieces that we think provide the best of both worlds to make it as easy as possible to go hybrid. 

Although thinking this is a suitable way of providing a "hybrid service", we want to emphasize to carefully read through the guide below, make an educated decision by yourself if you want to go clearnet over VPN.

<br/>

## Table of Content ##

- [Prelude and Objective](#prelude-and-objective)
- [Preconditions](#preconditions)
- [How this works](#how-this-works)
- [Install](#install)
- [Enabling hybrid mode](#enabling-hybrid-mode)
  - [LND](#lnd)
  - [CLN](#cln)
- [Uninstall](#uninstall)
- [Deep Dive](#deep-dive)
- [Further Help](#further-help)

<br/>

## Preconditions: ##

- OS: Debian-/Ubuntu-based (apt-get required)
- LND latest (minimum requirement `0.14.2-beta`)
- CLN latest
- only **one** lightning implementation per system is supported (configured to port 9735)
- edit your lightning configuration file (`lnd.conf` / `config`)
- ability to spend some sats (the hardest part)

<br/>

## How this works: ##

In order to understand the provided scripts and steps we gonna take a deep dive into our service. It is split into three parts: 

1) Renting a VPN server and obtaining a corresponding WireGuard config file from [tunnelsats.com](https://www.tunnelsats.com),

2) installing required software and components to make VPN connection and Tor splitting work and

3) setting up the node for hybrid mode by editing the lightning configuration file as described below. 

<br/>

## Install: ##

WireGuard is a fast, lightweight and secure VPN software. We offer a few WireGuard servers and quantum-safe VPN tunnels in various countries to choose from. 

1) Go to [tunnelsats.com](https://www.tunnelsats.com), select a country of your choice (preferably close to your real location for faster connection speed) and choose how long you want to use the service (1 to 12 months).

2) Pay the lightning invoice.

3) Copy, download or send the wireguard configuration (file: `tunnelsatsv2.conf` - please do NOT rename this file) to your local computer and transfer it to your node.

4) Download the setup script onto your node.

  Download setup script:
  
  ```sh
  $ wget https://github.com/blckbx/tunnelsats/raw/main/scripts/setupv2.sh
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
  externalip={vpnIP}:{vpnPort}
  
  [Tor]
  tor.streamisolation=false
  tor.skip-proxy-for-clearnet-targets=true
  #########################################
  ```

<br/>
  
## Enabling hybrid mode ##

Before applying any changes to your config files, please __always__ create a backup! For example:

  ```sh
  $ sudo cp /path/to/lnd.conf /path/to/lnd.conf.backup
  ```

⚠️ __Important Notice__: The following parts show how to configure LND and CLN implementations for hybrid mode. Regarding the status of this project, we currently only support one lightning implementation at a time. This means: If you plan to run both LND and CLN in parallel, only one (which listens on port 9735) is routed over VPN, others default to Tor-only. Nevertheless, it is possible to choose or switch default ports on various node setups.

<br/>

### LND

Running LND only requires a few parameters to be checked and set to activate hybrid mode. Locate `lnd.conf` depending on your node setup. See the [FAQ](https://blckbx.github.io/tunnelsats/FAQ.html#where-do-i-find-my-lndconf-file) for some default path examples. Just append the lines shown at the end of the setupv2.sh process to your lnd config file:

  ```ini
  [Application Options]
  listen=0.0.0.0:9735
  externalip={vpnIP}:{vpnPort} #these infos are provided at the end of the setup.sh script
  
  [Tor]
  # set steamisolation to 'false' if it's currently set 'true'. if it's not set at all, just leave it out
  tor.streamisolation=false
  tor.skip-proxy-for-clearnet-targets=true
  ```

<br/>

### CLN

With CLN it's a bit trickier. Most node setups like Umbrel, RaspiBolt, RaspiBlitz etc. default CLN's daemon port to the number `9736`. So in order to route CLN clearnet over VPN, we need to change CLN's default port to `9735`. 

The following shows how to edit non-docker CLN configuration:

Locate the data directory of your CLN installation. By default CLN's configuration is stored in a file named `config`. Edit the file and look out for network settings section. Configured to hybrid it should look like this:

```ini
bind-addr=0.0.0.0:9735
announce-addr={vpnIP}:{vpnPort}
always-use-proxy=false
```

On docker based systems this looks very differently. The following shows how to enable hybrid on Umbrel v0.5+:

- Apps installed: Bitcoin, CLN (LND may NOT be installed at the same time)
- Working Directory: `~/umbrel/app-data/core-lightning/`
- Files to look for: `export.sh`, `docker-compose.yml`
- Changes to be made: 

export.sh: change port number from 9736 to 9735
```ini
export APP_CORE_LIGHTNING_DAEMON_PORT="9736"
```
change to
```ini
export APP_CORE_LIGHTNING_DAEMON_PORT="9735"
```

docker-compose.yml: add two new parameters to `command` section. these are `always-use-proxy=false` and `announce-addr=` and comment out `- --bind-addr=${APP_CORE_LIGHTNING_DAEMON_IP}:9735`.

```ini
  lightningd:
    image: lncm/clightning:...
    restart: on-failure
    ports:
      - ${APP_CORE_LIGHTNING_DAEMON_PORT}:9735
    command:
      - --bitcoin-rpcconnect=${APP_BITCOIN_NODE_IP}
      - --bitcoin-rpcuser=${APP_BITCOIN_RPC_USER}
      - --bitcoin-rpcpassword=${APP_BITCOIN_RPC_PASS}
      - --proxy=${TOR_PROXY_IP}:${TOR_PROXY_PORT}
      - --bind-addr=${APP_CORE_LIGHTNING_DAEMON_IP}:9735
      - --addr=statictor:${TOR_PROXY_IP}:29051
      - --tor-service-password=${TOR_PASSWORD}
      #- --grpc-port=${APP_CORE_LIGHTNING_DAEMON_GRPC_PORT}
    volumes:
      - "${APP_DATA_DIR}/data/lightningd:/data/.lightning"
    networks:
      default:
        ipv4_address: ${APP_CORE_LIGHTNING_DAEMON_IP}
```
change to (replace {vpnIP}:{vpnPort} with the VPN IP and port received running `setup.sh`)
```ini
lightningd:
    image: lncm/clightning:...
    restart: on-failure
    ports:
      - ${APP_CORE_LIGHTNING_DAEMON_PORT}:9735
    command:
      - --bitcoin-rpcconnect=${APP_BITCOIN_NODE_IP}
      - --bitcoin-rpcuser=${APP_BITCOIN_RPC_USER}
      - --bitcoin-rpcpassword=${APP_BITCOIN_RPC_PASS}
      - --proxy=${TOR_PROXY_IP}:${TOR_PROXY_PORT}
      #- --bind-addr=${APP_CORE_LIGHTNING_DAEMON_IP}:9735
      - --addr=statictor:${TOR_PROXY_IP}:29051
      - --tor-service-password=${TOR_PASSWORD}
      - --bind-addr=0.0.0.0:9735
      - --announce-addr={vpnIP}:{vpnPort}
      - --always-use-proxy=false
      #- --grpc-port=${APP_CORE_LIGHTNING_DAEMON_GRPC_PORT}
    volumes:
      - "${APP_DATA_DIR}/data/lightningd:/data/.lightning"
    networks:
      default:
        ipv4_address: ${APP_CORE_LIGHTNING_DAEMON_IP}
```

⚠️ __Important Notice:__ Especially for LND configurations, please uncomment or remove any other `externalip=` and / or `externalhosts=` settings. They can potentially interfere with VPN settings. In summary:

  ```ini
  # Uncomment any of these parameters if present:
  #externalip=...
  #externalhosts=...
  ```
  
⚠️ After enabling hybrid mode in related configuration files, restart the lightning implementation for changes to take effect! Before doing so, verify the established VPN connection with commands provided in the following part. 

<br/>


## Uninstall: ##

To restore all applied changes made to your node setup, download and run the uninstallv2 script. Furthermore remove entries from configuration files.

  ```sh
  $ wget https://github.com/blckbx/tunnelsats/raw/main/scripts/uninstallv2.sh
  $ sudo bash uninstallv2.sh
  ```
Restore your configuration from with the backup file you (hopefully) created on setting up hybrid mode. 

<br/>

## Deep Dive: ##

What is the `setupv2.sh` script doing in detail?

1) Checking if required components are already installed and if not, installing them. These are: `cgroup-tools` (for split-tunneling Tor), `nftables` (VPN rules) and `wireguard` (VPN software).

2) Checking if `tunnelsatsv2.conf` exists in current directory (must be the same directory where setup script is located).

3) Setting up "split-tunneling" to only include lightning P2P traffic in VPN usage.

4) Enabling and starting required systemd services (wg-quick@.service, splitting.service).

5) Adding nftables ruleset to client system to enable kill-switching and prevent DNS leakage.

<br/>

## Further Help: ##

Please review the [FAQ](FAQ.md) for further help. 
If you need any other help setting up hybrid mode over VPN
or just want to have a chat with us, join our [Tunnel⚡Sats](https://t.me/+NJylaUom-rxjYjU6) Telegram group.

____________________________________________________________

This service is brought to you by [@ziggie1984](https://github.com/ziggie1984) (Ziggie), [@TrezorHannes](https://github.com/TrezorHannes) (Hakuna) and [@blckbx](https://github.com/blckbx) (osito).

Special thanks to [@LightRider5](https://github.com/LightRider5) ([lnvpn.net](https://lnvpn.net)) 
for providing this amazing frontend framework and for help and support.
