# FAQ

## Table of Contents
- [Why should I use this service?](#why-should-i-use-this-service)
- [Why choose Tunnel⚡Sats over other VPN providers?](#why-choose-tunnelsats-over-other-vpn-providers)
- [Is your service reliable?](#is-your-service-reliable)
- [What services are used?](#what-services-are-used)
- [What about data storage and privacy?](#what-about-data-storage-and-privacy)
- [Is there a data transfer limit?](#is-there-a-data-transfer-limit)
- [Which setups are supported?](#which-setups-are-supported)
- [Do you store my data? If so, which one and how do you use it?](#do-you-store-my-data-if-so-which-one-and-how-do-you-use-it)
- [What options do I have if I'm not happy?](#what-options-do-i-have-if-im-not-happy)
- [How can I extend my subscription?](#how-can-i-extend-my-subscription)
- [Are you offering any discounts?](#are-you-offering-any-discounts)
- [Is there a referral program?](#is-there-a-referral-program)
- [My payment did confirm on my wallet, but I didn't get my configuration files. What can I do?](#my-payment-did-confirm-on-my-wallet-but-i-didnt-get-my-configuration-files-what-can-i-do)
- [I'm stuck with the setup process, can you help?](#im-stuck-with-the-setup-process-can-you-help)
- [How do I know what value I got from subscribing to your service?](#how-do-i-know-what-value-i-got-from-subscribing-to-your-service)
- [Why shouldn't I just do it myself?](#why-shouldnt-i-just-do-it-myself)
- [Why are you charging fees?](#why-are-you-charging-fees)
- [Where do I find my lightning configuration file?](#where-do-i-find-my-lightning-configuration-file)
- [How to transfer `tunnelsatsv2.conf` to my node?](#how-to-transfer-tunnelsatsv2conf-to-my-node)
- [How does it actually look like, how am I connected?](#how-does-it-actually-look-like-how-am-i-connected)
- [How can I verify that my VPN connection is online and active?](#how-can-i-verify-that-my-vpn-connection-is-online-and-active)
- [Tuning Tor](#tuning-tor)
- [What does v2 stand for?](#what-does-v2-stand-for)
- [Running tunnelsatsv2 and mullvad in parallel?](#running-tunnelsatsv2-and-mullvad-in-parallel)
- [Do you offer full-service VPNs too?](#do-you-offer-full-service-vpns-too)
- [Who built this?](#who-built-this)
- [I have some ideas to make this better. Where can I provide feedback or offer help?](#i-have-some-ideas-to-make-this-better-where-can-i-provide-feedback-or-offer-help)

<br/>

## Frequently asked Questions

### Why should I use this service?
Providing Lightning ⚡ Services is about privacy, reliability, connectivity, speed and liquidity. Relying your node connectivity to a single service **Tor** is a risk regarding connectivity and network stability, as anyone running a lightning node can testify. With Hybrid[^1] connectivity, you offer your payment and routing services to be [faster](https://blog.lnrouter.app/lightning-payment-speed-2022), more reliable, and yet, there is a privacy concern when you do it with your home-IP: you both expose your _rough_ location of your node, potentially your home and your node's system to attacks from the internet. With our solution **Tunnel⚡Sats**, you get the best of both worlds. Your node and home IP stays hidden, behind Tor and our VPS public IP address, which will be your node's face to the public internet, is shared with other peers. You may see higher reliability causing not only higher uptime, fewer offline peer nodes but also greater routing numbers. This isn't a promise, but an eventually expected outcome. 

You also provide better user experience for customers actually using lightning as a payment system, which you could argue is the largest benefit.

<br/>

### Why choose Tunnel⚡Sats over other VPN providers?
Running a lightning nodes behind a VPN requires a range of features public VPN providers usually do not offer. **Tunnel⚡Sats** is specially designed for the lightning node use case in mind. So we pack up everything that's needed:
- anonymous payment method via Lightning (we don't see the sender of the payment)
- static VPN IP: no more disconnects due to changing VPN IPs and no hassle setting up Dynamic DNS
- static forwarded ports: assign VPN's port to your node config and you are good to go
- secure VPN tunnels: we provide quantum-safe VPN tunnels using pre-shared keys
- split-tunneling: we exclude everything else besides lightning p2p traffic from the VPN network. Contrary to "Tor over VPN", this enables redundancy of connectivity over Tor for your node meaning: If Tor goes down, VPN still plays nice and vice versa (which should never happen). 

<br/>

### Is your service reliable?
We use premium VPS Services with tight SLAs and proven, recorded high uptime (99,99%). We also setup servers across different service providers to allow for switching in case something out of our control happens. We also setup tight monitoring systems for our VMs, with alert mechanisms and coverage by 3 people in operations. That said, we're early in our offering and happily provide regular uptime metrics when we enter beta phase, to provide more objective reliability data here.

<br/>

### What services are used?
As payment backend we use <a href="https://legend.lnbits.com/" target="_blank" rel="noreferrer">LNBits</a> for lightning payments, to send WireGuard config files via email we use our own mailserver and to provide this frontend React and WebSockets are being imported.
As for the VPN endpoints, we make use of our own rented virtual servers from Digital Ocean (EU) and (US) with <a href="https://github.com/Mawthuq-Software/wireguard-manager-and-api" target="_blank" rel="noreferrer">WireGuard Manager and API</a> managing the WireGuard setup and accounts safely.

<br />

### What about data storage and privacy?
On the website, no cookies and only first half of IP addresses is stored in our webserver logs. For example the IP 1.12.123.234 becomes 1.12.0.0. On the VPN endpoints we store WireGuard public keys, preshared keys, forwarded ports and total amount of bandwidth used. While maintaining an active connection to a VPN endpoint, the client's IP address has to be kept in memory. We never store it on disk. As payments are only possible via lightning, we don't know where the satoshis comes from, we can only verify whether an invoice was paid or not. If you use "Send via email" feature to transfer the WireGuard configuration file, the email is sent via our own mailserver.

<br />

### Is there a data transfer limit?
Currently, 100GB per month are being offered. This should be enough traffic even for bigger nodes with lots of channels.

<br />

### Which setups are supported?
At present we successfully tested the following setups:

- RaspiBlitz (LND / CLN) v1.7.2
- Umbrel-OS (LND)
- Umbrel-OS (CLN not yet recommended or be tech-savvy)
- myNode (LND) v0.2.x
- (Raspi)Bolt (LND / CLN)

For other setups please get back to us on Telegram to discuss if it's viable to go with TunnelSats.

<br />

### Do you store my data? If so, which one and how do you use it?
We don't log IPs in our Webserver access data. We also offer an .onion website to allow for even greater anonymity: http://tunnelpasz3fpxhuw6obb5tpuqkxmcmvqh7asx5vkqfwe7ix74ry22ad.onion

We don't store packets or logfiles from or to your node once the tunnel is established. What we do store: We store the payment hash as accounting confirmation in LNBits. We do have to keep your node's IP address in memory for the tunnel connection to stay alive, which will be discarded once you disconnect. Hence it's extremely important to save your Wireguard configuration file because there is no way for us to re-retrieve that information.

<br/>

### What options do I have if I'm not happy?
This is still beta status, so please bear with us. If you experience issues, please contact us and let us know. We are approachable and can discuss whatever is bugging you and see how we can find a solution.

<br/>

### How can I extend my subscription?
Let's say you bought the 1 month for testing the services and all is going great. Now your subscription is coming to an end and you like to extend it to add another 3 months. Since we don't offer a login-service (yet), you need to remember your subscription end date (look it up in your Wireguard config file: #ValidUntil (mind this is UTC time format)) and before expiry
- buy a new subscription
- download or transfer via email the new configuration file from the website 
- redo installation procedure: place config file in same directory `with setupv2.sh` and run it again
- adjust the newly assigned {vpnExternalPort} in your lightning configuration (externalip (LND) or announce-addr (CLN))
- restart wireguard and lightning: `sudo systemctl restart wg-quick@tunnelsatsv2` and your lightning implementation

<br/>

### Are you offering any discounts?
Yes, as you can see, the longer the subscription, the more the discount. We offer 5% for 3 months, 10% for 6 months, and 20% for 12 months. You can also expect to buy cheaper today, since we do expect prices to rise further into launching.

<br/>

### Is there a referral program?
No, not yet, but we'll be happy to look into it when people raise interest to such a program via feedback.

<br/>

### My payment did confirm on my wallet, but I didn't get my configuration files. What can I do?
Please approach us on Telegram, via Email, Twitter or open an issue here. We'll ask you to confirm the timestamp of your payment, so we can check our accounting and provide a solution for you. Sorry for the inconvenience in advance.

<br/>

### I'm stuck with the setup process, can you help?
Please raise an issue in Github or simply join our [Telegram](https://t.me/+NJylaUom-rxjYjU6) group, explaining where you are stuck, but leave out any personal or sensitive information. Especially handle your configuration file with care!

<br/>

### How do I know what value I got from subscribing to your service?
Keep an eye on your latency, uptime, routing amount week-over-week, and some subjective observations like nodes offline and such. Value is a quite subjective term, but we found those attributes provide value to a routing runner.

<br/>

### Why shouldn't I just do it myself?
We offer a full-managed-service, which takes a lot of the server, library, security and operational headache away from you. If you feel you prefer the personal learning experience, we can only encourage you to do so. It is a great adventure to learn more, so please check the footnotes in case you look for ways to dive in.

<br/>

### Why are you charging fees?
We have invested significant amount of hours into building out the infrastructure, unique services, security and reliability feats, which come at a cost. We also chose a premium set of VPS providers, which come at a cost. And nodes, even without Tor traffic, are still using significant bandwidth every day, even small ones. So we need to cover both operational costs and compensate for further extending our services.

<br/>

### Where do I find my lightning configuration file?
Every node software (RaspiBlitz, RaspiBolt, Umbrel, Start9, myNode, etc.) has its own directory where it keeps data of the underlying lightning implementation. As far as we know, the current (07/2022) directories are:

LND:
```ini
RaspiBlitz: /mnt/hdd/lnd/lnd.conf
RaspiBolt: /data/lnd/lnd.conf
Umbrel: /home/umbrel/umbrel/lnd/lnd.conf
Umbrel 0.5+: /home/umbrel/umbrel/app-data/lightning/data/lnd/lnd.conf
Start9: /embassy-data/package-data/volumes/lnd/data/main/lnd.conf
myNode: /mnt/hdd/mynode/lnd/lnd.conf
```

CLN:
```ini
RaspiBlitz: /mnt/hdd/app-data/.lightning/config
RaspiBolt: /data/cln/config
Umbrel 0.5+: /home/umbrel/umbrel/app-data/core-lightning/data/lightningd/bitcoin/config (file has to be created manually)
```

<br/>

### How to transfer `tunnelsatsv2.conf` to my node?
The easiest way to transfer a file to a remote node is to use the cli command `scp`. Assuming that you run an Umbrel node and have downloaded the wireguard config file (tunnelsats.conf) to your computer, the `scp` command would look like this: 
```sh
$ scp tunnelsatsv2.conf umbrel@umbrel.local:/home/umbrel/

[ scp <local file> <user>@<ip/hostname>:<destination path> ]
```

<br/>

### How does it actually look like, how am I connected?
See the current network setup in a comparison between your Tor only setup vs the new setup as a flowchart
![Flowchart Diagram](/docs/assets/Tunnelsats-Tor-scenario.drawio.png)

<br/>

### How can I verify that my VPN connection is online and active?
On console, run the following wireguard command to see some connection statistics, especially check latest handshake for an active VPN connection: `sudo wg show`

<br/>

### Tuning Tor
Although we can speed up clearnet to clearnet connections, we still have to use the Tor network to reach out to Tor-only nodes. There have been some experiments going on to stabilize Tor connectivity and minimize its issues. Some of them might be worth trying out. These options are added at the very end of the `torrc` file:
```ini
LongLivedPorts 21,22,706,1863,5050,5190,5222,5223,6523,6667,6697,8300,9735,9736,9911
UseEntryGuards 1
NumEntryGuards 8
```

<br/>

### What does v2 stand for?
In v2 we changed the network architecture compared to v1 where all traffic was directed via the VPN except Tor and ssh. This approach resulted in a lot of exceptions for different users. For example, if you were running ThunderHub on your node with v1, you were not able to access it via the external clearnet. In v2 we are now isolating only lightning traffic via the VPN meaning that all traffic not routed via your local proxy or not destined for your local network will be directed through the tunnel. This means apps like ThunderHub which run locally on your node are not tunneled and are accessible from the external clearnet. Nothing changes for your setup except for the lightning process. You will have no problems accessing your node from the external clearnet via ssh. So keep in mind that in case you want to access the gRPC or REST interface form the external clearnet, it will not be possible. In this case services like ZeroTier are recommended which let's you access your node as if it would be in your local network. Normally accessing your nodes gRPC or REST API from the external clearnet shouldn't be a general use case, it's recommended to access the API via the local network or on the same computer resulting in better efficiency.

<br/>


### Running tunnelsatsv2 and mullvad in parallel?
Yes, this is possible, but you have to make some adjustments. First you have to make sure the startup order is first mullvad then tunnelsats leading to the following ip rules
```
0:  from all lookup local
32760:  from all lookup main suppress_prefixlength 0
32761:  from all fwmark 0xdeadbeef lookup 51820
32762:  not from all fwmark 0x6d6f6c65 lookup 1836018789
32766:  from all lookup main
32767:  from all lookup default
```
In addition you have to create an additional nftable to circumvent the mullvad firewall rules. Create a file called exclude.rules and input the following content
```
table inet excludeTraffic {
  chain allowIncoming {
    type filter hook input priority -100; policy accept;
    ip saddr  ip_of_tunnelsats_vpn ct mark set 0x00000f41 meta mark set 0x6d6f6c65
    iifname tunnelsatsv2 ct mark set 0x00000f41;
  }


  chain allowOutgoing {
    type route hook output priority -100; policy accept;
    ip daddr  ip_of_tunnelsats_vpn ct mark set 0x00000f41 meta mark set 0x6d6f6c65
    oifname tunnelsatsv2 ct mark set 0x00000f41;
  }
}

```
Replace the ip_of_tunnelsats_vpn with the ip of the related tunnelsats vpn server and flush this file with `sudo nft -f exclude.rules`. Now you should be able to run Mullvad and Tunnelsats in parallel

<br/>

### Do you offer full-service VPNs too?
In short: No. Currently we are specializing VPN usage for the sole purpose of lightning node running. If you are looking for a privacy-preserving, lightning-payment enabled VPN provider, we recommend to take a look at [LNVPN.net](https://lnvpn.net).

<br />

### Who built this?
From Node Runnners for Node Runners 🧡

<br />

### I have some ideas to make this better. Where can I provide feedback or offer help?
Great! Please do not hesitate to reach out via [Telegram](https://t.me/+NJylaUom-rxjYjU6), [Twitter](https://twitter.com/tunnelsats), eMail (info @ tunnelsats.com) or log an issue here on Github with your detailed ideas or feature requests. We always look forward to partner with great thinkers and doers.

<br/>
<br/>

[^1]: See hybrid options for [home-IP](https://github.com/blckbx/lnd-hybrid-mode) and [VPS](https://github.com/TrezorHannes/Dual-LND-Hybrid-VPS) for self-setup.
