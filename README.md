# Tunnel⚡Sats

## Prelude and Objective ##
The lightning network functions in rapid growing speed as infrastructure for payments across the globe between merchants, creators, consumers, institutions and investors alike. Hence the key pillars of sustained growth are their nodes, by providing _reliable_, _liquid_, _discoverable_, _trustless_ and _fast_ connection points between those parties.

The effort of creating a valuable "clearnet over VPN" node - which we laid out [here](https://blckbx.github.io/lnd-hybrid-mode/) and [here](https://github.com/TrezorHannes/Dual-LND-Hybrid-VPS) - is quite high and intense because it touches several disciplinaries not every node runner is comfortable with. Required knowledge of the command line, firewall handling, network details, trust in and choosing of a suitable VPN provider that offers all the features we need and cares about privacy and, of course, the configuration of the lightning node itself makes it easy to just "leave it as is".

Therefore we came to the conclusion that this process has to be simplified **a lot**. In the last few weeks we put together all the pieces that we think provide the best of all worlds to make it as easy as possible to go hybrid. 

Although thinking this is a suitable way of providing a "hybrid service", we want to emphasize to carefully read through the guide below, make an educated decision by yourself if you want to go clearnet over VPN.


## Table of Content ##

- [Prelude and Objective](#prelude-and-objective)
- [Preconditions](#preconditions)
- [How this works](#how-this-works)
- [WireGuard configuration file](#wireguard-configuration-file)


## Preconditions: ##

- `lnd-0.14.2-beta` or later
- ability to spend some sats (the hardest part)


## How this works: ##

In order to understand the provided scripts and steps we gonna take a deep dive into our service. It is split into two parts: 

- Setting up the node for hybrid mode (one-time installation) and
- renting a VPN server and obtaining a corresponding WireGuard config file


## Rent a VPN, get a WireGuard configuration file: ##

- WireGuard is a fast, lightweight and secure VPN software. We offer a few WireGuard servers in various countries to choose from. 
