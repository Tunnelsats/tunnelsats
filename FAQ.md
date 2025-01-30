
# FAQ

## Table of Contents


### Tunnel⚡Sats - Introduction
- [Why should I use this service?](#why-should-i-use-this-service)
- [Why choose Tunnel⚡Sats over other VPN providers?](#why-choose-tunnelsats-over-other-vpn-providers)
- [How do I know what value I got from subscribing to your service?](#how-do-i-know-what-value-i-got-from-subscribing-to-your-service)
- [How does it actually look like, how am I connected?](#how-does-it-actually-look-like-how-am-i-connected)


### Trust & Safety Measures 
- [What services are used?](#what-services-are-used)
- [What about data storage and privacy?](#what-about-data-storage-and-privacy)
- [Is your service reliable?](#is-your-service-reliable)
- [Do you store my data? If so, which one and how do you use it?](#do-you-store-my-data-if-so-which-one-and-how-do-you-use-it)

### Prerequisites & Installation
- [Which setups are supported?](#which-setups-are-supported)
- [Is there a data transfer limit?](#is-there-a-data-transfer-limit)
- [Where do I find my lightning configuration file?](#where-do-i-find-my-lightning-configuration-file)
- [How do I finalize the configuration for my ☂️ umbrel 0.5+ node?](#how-do-i-finalize-the-configuration-for-my-%EF%B8%8F-umbrel-05-node)
- [How to transfer `tunnelsatsv2.conf` to my node?](#how-to-transfer-tunnelsatsv2conf-to-my-node)
- [How can I extend my subscription?](#how-can-i-extend-my-subscription)
- [Am I still able to connect to gRPC or Rest via Tailscale/Zerotier?](#am-i-still-able-to-connect-to-grpc-or-rest-via-tailscalezerotier)
- [Running tunnelsatsv2 and mullvad in parallel?](#running-tunnelsatsv2-and-mullvad-in-parallel)
- [Is it possible to run another Wireguard Tunnel besides Tunnelsats?](#is-it-possible-to-run-another-wireguard-tunnel-besides-tunnelsats)


### Troubleshooting & Verification
- [I'm stuck with the setup process, can you help?](#im-stuck-with-the-setup-process-can-you-help)
- [My payment did confirm on my wallet, but I didn't get my configuration files. What can I do?](#my-payment-did-confirm-on-my-wallet-but-i-didnt-get-my-configuration-files-what-can-i-do)
- [How do I verify the tunnel is working?](#how-do-i-verify-the-tunnel-is-working)
- [How can I verify that my VPN connection is online and active?](#how-can-i-verify-that-my-vpn-connection-is-online-and-active)
- [What options do I have if I'm not happy?](#what-options-do-i-have-if-im-not-happy)


### Payment & Costs
- [Why are you charging fees?](#why-are-you-charging-fees)
- [Are you offering any discounts?](#are-you-offering-any-discounts)
- [Is there a referral program?](#is-there-a-referral-program)
- [Why shouldn't I just do it myself?](#why-shouldnt-i-just-do-it-myself)


### Misc
- [Tuning Tor](#tuning-tor)
- [What does v2 stand for?](#what-does-v2-stand-for)
- [Do you offer full-service VPNs too?](#do-you-offer-full-service-vpns-too)
- [I have some ideas to make this better. Where can I provide feedback or offer help?](#i-have-some-ideas-to-make-this-better-where-can-i-provide-feedback-or-offer-help)
- [Who built this?](#who-built-this)

<br/>

## Frequently asked Questions

### Why should I use this service?

Providing Lightning ⚡ Services is about privacy, reliability, connectivity, speed and liquidity. Relying your node connectivity to a single service **Tor** is a risk regarding connectivity and network stability, as anyone running a lightning node can testify. With Hybrid[^1] connectivity, you offer your payment and routing services to be [faster](https://blog.lnrouter.app/lightning-payment-speed-2022), more reliable, and yet, there is a privacy concern when you do it with your home-IP: you both expose your _rough_ location of your node, potentially your home and your node's system to attacks from the internet. With our solution **Tunnel⚡Sats**, you get the best of both worlds. Your node and home IP stays hidden, behind Tor and our VPS public IP address, which will be your node's face to the public internet, is shared with other peers. You may see higher reliability causing not only higher uptime, fewer offline peer nodes but also greater routing numbers. This isn't a promise, but an eventually expected outcome.

You also provide better user experience for customers actually using lightning as a payment system, which you could argue is the largest benefit.
<br/>
![Cost Speed Privacy Polarity](/docs/assets/Connection%20Polarity.png)
<br/>

### Why choose Tunnel⚡Sats over other VPN providers?

Running a lightning nodes behind a VPN requires a range of features public VPN providers usually do not offer. **Tunnel⚡Sats** is specially designed for the lightning node use case in mind. So we pack up everything that's needed:

- anonymous payment method via Lightning (we don't know the sender of the payment)
- static VPN IP: no more disconnects due to changing VPN IPs and no hassle setting up Dynamic DNS
- static forwarded ports: assign VPN's port to your node config and you are good to go
- secure VPN tunnels: we provide quantum-safe VPN tunnels using pre-shared keys
- split-tunneling: we exclude everything else besides lightning p2p traffic from the VPN network. Contrary to "Tor over VPN", this enables redundancy of connectivity over Tor for your node meaning: If Tor goes down, VPN still plays nice and vice versa (which should never happen).

<br/>

### How do I know what value I got from subscribing to your service?

Keep an eye on your latency, uptime, routing amount week-over-week, and some subjective observations like nodes offline and such. Value is a quite subjective term, but we found those attributes provide value to a routing runner.

<br/>

### How does it actually look like, how am I connected?

See the current network setup in a comparison between your Tor only setup vs the new setup as a flowchart

![Flowchart Diagram](/docs/assets/Tunnelsats-Tor-scenario.drawio.png)

<br/>

### What services are used?

As payment backend we use <a href="https://lnbits.com/" target="_blank" rel="noreferrer">LNbits</a> for lightning payments, for sending WireGuard config files via email we use our own mailserver and this frontend uses React and WebSockets.
As for the VPN endpoints, we make use of our own rented virtual servers from Digital Ocean (EU, Asia and NorthAmerica), Hetzner (EU) and Vultr (LatAM) with <a href="https://github.com/Mawthuq-Software/wireguard-manager-and-api" target="_blank" rel="noreferrer">WireGuard Manager and API</a> managing the WireGuard setup and accounts safely. For collecting uptime and response times of our servers, we forked <a href="https://github.com/tunnelsats/upptime" target="_blank" rel="noreferrer">upptime</a> which is running from our own repository. Response times are gathered by github based in the US.

<br />

### What about data storage and privacy?

On the website, no cookies and only first half of IP addresses is stored in our webserver logs. For example the IP 1.12.123.234 becomes 1.12.0.0. On the VPN endpoints we store WireGuard public keys, preshared keys, forwarded ports and total amount of bandwidth used. While maintaining an active connection to a VPN endpoint, the client's IP address has to be kept in memory. We never store it on disk. As payments are only possible via lightning, we don't know where the satoshis comes from, we can only verify whether an invoice was paid or not. If you use "Send via email" feature to transfer the WireGuard configuration file, the email is sent via our own mailserver.

<br />

### Is your service reliable?

We use premium VPS Services with tight SLAs and proven, recorded high uptime (99,99%). We also setup servers across different service providers to allow for switching in case something out of our control happens. We also setup tight monitoring systems for our VMs, with alert mechanisms and coverage by 3 people in operations. That said, we're early in our offering and happily provide regular uptime metrics to provide more objective reliability data here.

<br/>

### Do you store my data? If so, which one and how do you use it?

We don't log IPs in our webserver access data. We also offer an .onion website to allow for even greater anonymity: [http://tunnelpasz3fpxhuw6obb5tpuqkxmcmvqh7asx5vkqfwe7ix74ry22ad.onion](http://tunnelpasz3fpxhuw6obb5tpuqkxmcmvqh7asx5vkqfwe7ix74ry22ad.onion)

We don't store packets or logfiles from or to your node once the tunnel is established. What we do store: We store the payment hash as accounting confirmation in LNBits. We do have to keep your node's IP address in memory for the tunnel connection to stay alive, which will be discarded once you disconnect. Hence it's extremely important to save your WireGuard configuration file because there is no way for us to re-retrieve that information.

<br/>

### Which setups are supported?

At present we successfully tested the following setups:

- RaspiBlitz (LND / CLN) v1.8.0+
- Umbrel-OS (LND) on Raspberry Pi
- Umbrel-OS (CLN not yet recommended or be tech-savvy) on Raspberry Pi
- myNode (LND) v0.3+
- RaspiBolt (LND / CLN) (please see [preconditions](README.md/#preconditions) if your system or architecture differs from RaspiBolt guide)

For other setups please get back to us on Telegram to discuss if it's viable to go with TunnelSats.

<br />

### Is there a data transfer limit?

Currently, 100GB per month are being offered. This should be enough traffic even for bigger nodes with lots of channels. If you run LND below version 18.4, there might be a bug affecting your node to send more than 100GB every two weeks. Please ensure to update as soon as possible.

<br />

### Where do I find my lightning configuration file?

Every node software (RaspiBlitz, RaspiBolt, Umbrel, Start9, myNode, etc.) has its own directory where it keeps data of the underlying lightning implementation. As far as we know, the current (01/2025) directories are:

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

### How do I finalize the configuration for my ☂️ umbrel 0.5+ node?

Since umbrel brings more and more LND configuration settings into the UI, you need to do some settings there, and complement the others in your own `lnd.conf`. This is how you set it up properly:
- complete the setup guide as usual until successful completion. Make a note of **externalhost** and **externalVPNPort**
- backup and edit your custom `lnd.conf` file to add the settings you see prompted:
```sh
$ cp ~/umbrel/app-data/lightning/data/lnd/lnd.conf ~/umbrel/app-data/lightning/data/lnd/lnd.bak
$ nano ~/umbrel/app-data/lightning/data/lnd/lnd.conf
```
  - add the following two lines, then save and exit
```
[Application Options]
externalhosts=${vpnExternalDNS}:${vpnExternalPort}
```
- open your Umbrel User Interface, navigate to LND > Settings > Advanced and ensure: 
  - **Hybrid Mode** (tor.skip-proxy-for-clearnet-targets) is _activated_
  - **Separate Tor Connections** (tor.streamisolation) is _deactivated_
- finally, restart your node


### How to transfer `tunnelsatsv2.conf` to my node?

The easiest way to transfer a file to a remote node is to use the cli command `scp`. Assuming that you run an Umbrel node and have downloaded the WireGuard config file (tunnelsats.conf) to your computer, the `scp` command would look like this:

```sh
$ scp tunnelsatsv2.conf umbrel@umbrel.local:/home/umbrel/

[ scp <local file> <user>@<ip/hostname>:<destination path> ]
```

Alternatively create a new file on your node and copy/paste the content of `tunnelsatsv2.conf`, save and exit.

<br/>

### How can I extend my subscription?

Renewal of existing subscriptions has been reworked. Now it is possible to prolong your subscription by extending the current fixed term. Here is how:

- go to [tunnelsats.com](https://tunnelsats.com) and select "Renew Subscription" on the navigation bar
- enter the WireGuard public key - find the key either
  - commented out in your `tunnelsatsv2.conf`, look for `#myPubKey` line (new subscriptions only) or
  - in your wireguard connection details extracted by running `sudo wg show | grep "public key"`
- click "Query Key Info" to fetch your key's infos
- select the desired term extension of your choice (it is appended to the current expiry date)
- click "Update Subscription" and pay the lightning invoice

⚠️ No new WireGuard file will be handed over to the user. The current lightning settings persist, and we just extend your subscription with the purchased time. So there is no further lightning configuration needed. Changing server locations on renewals is not supported for now.

<br/>

### Am I still able to connect to gRPC or Rest via Tailscale/Zerotier?

As of commit [24f0f3c](https://github.com/tunnelsats/tunnelsats/commit/24f0f3c969cac04059aa8b8bfe1be3add08ae4bb) gRPC and Rest interfaces (ports 10009 and 8080) are no longer tunneled by TunnelSats. This means you can access these ports and tunnel them via ZeroTier or Tailscale additionally. This solution works for Docker (e.g. Umbrel) and non-Docker (e.g. RaspiBlitz) setups. In case you got a subscription before this change was introduced, just get and run the latest setup script again. Installation steps are any different than setting it up without TunnelSats.

<br />

### Running tunnelsatsv2 and mullvad in parallel?

Yes, this is possible, but you have to make some adjustments. First, you have to make sure the startup order is mullvad first then TunnelSats leading to the following ip rules:

```
0:  from all lookup local
32760:  from all lookup main suppress_prefixlength 0
32761:  from all fwmark 0xdeadbeef lookup 51820
32762:  not from all fwmark 0x6d6f6c65 lookup 1836018789
32766:  from all lookup main
32767:  from all lookup default
```

In addition, you have to create an additional nftable to circumvent the mullvad firewall rules. Create a file called `exclude.rules` and input the following content:

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

Replace the ip_of_tunnelsats_vpn with the ip of the related tunnelsats vpn server and flush this file with `sudo nft -f exclude.rules`. Now you should be able to run mullvad and TunnelSats in parallel.

<br/>

### Is it possible to run another Wireguard Tunnel besides Tunnelsats?

In case you also want to run another tunnel besides the tunnelsats network, that works!
Just create another wireguad configfile with new private and public keys of the respective servers.

```
[Interface]
PrivateKey = XXX
Address = XXX (Don't use 10.9.0.0/24 because this is the tunnelsats network)
Table = off
[Peer]
PublicKey = XXX
Endpoint =  XXX
AllowedIPs = 0.0.0.0/0
```

Replace the XXX-values with your own!

Then just bring the interface up with `wg-quick up NAMEOFCONFIGFILE.conf`
Now you are connected to your second wireguard network.

<br />

### I'm stuck with the setup process, can you help?

Please raise an [issue](https://github.com/tunnelsats/tunnelsats/issues) in Github or simply join our [Telegram](https://t.me/+py_KS9wv6hdjMWMy) group, explaining where you are stuck, but leave out any personal or sensitive information. Especially handle your configuration file with care!

<br/>

### My payment did confirm on my wallet, but I didn't get my configuration files. What can I do?

Please approach us on Telegram, via Email, Twitter or open an issue here. We'll ask you to confirm the timestamp of your payment, so we can check our accounting and provide a solution for you. Sorry for the inconvenience in advance.

<br/>

### How do I verify the tunnel is working?

First you can check if outbound connection go through the tunnel therefore you can use the following:

**Docker Setup**

`docker run -ti --rm --net=docker-tunnelsats curlimages/curl https://api.ipify.org `

This makes an outbound request to the api.ipify.org website through the tunnel and should show the VPN IP.

**Non-Docker Setup**

For non-docker setups you have to run the command in the specific cgroup. The equivalent command to docker setup is

`cgexec -g net_cls:splitted_processes curl --silent https://api.ipify.org`

Having verified outbound connection you have to make sure inbound connections are able to reach your lightning node.

For this you have to check whether a service runs on your VPN port and answers successfully. You can use netcat for this.

`nc -zv  de3.tunnelsats.com 32320`

This makes a tcp request to the de3 tunnelsats server port 32320 (replace with your own VPN port)

If it's successful you should see something like
`Connection to de3.tunnelsats.com port 32320 [tcp/*] succeeded!`

In addition you can chat to our hosted [Tunnel⚡Sats Bot](https://t.me/TunnelSatsBot) and connect to your new clearnet address and see whether the lightning connection works too.

<br />

### How can I verify that my VPN connection is online and active?

On console, run the following WireGuard command to see some connection statistics, especially check latest handshake for an active VPN connection: `sudo wg show`.
You can also download a helper script to check your configuration:
```
$ wget -O tunnelsats-sub-details.sh https://github.com/tunnelsats/tunnelsats/raw/main/scripts/tunnelsats-sub-details.sh
$ sudo bash tunnelsats-sub-details.sh
```

If you're on Telegram, you can chat to our hosted [Tunnel⚡Sats Bot](https://t.me/TunnelSatsBot) and send a `/ping [pubkey@tor.onion]` or `/ping [pubkey@tunnelsats-clearnetIP:port]` to check for a positive connection and speed-report.

<br/>

### What options do I have if I'm not happy?

If you experience issues, please contact us and let us know what issues you're encountering. We are approachable and can discuss whatever is bugging you and see how we can find a solution.

<br/>

### Why are you charging fees?

We have invested significant amount of hours into building out the infrastructure, unique services, security and reliability feats, which come at a cost. We also chose a premium set of VPS providers, which come at a cost. And nodes, even without Tor traffic, are still using significant bandwidth every day, even small ones. So we need to cover both operational costs and compensate for further extending our services.

<br/>

### Are you offering any discounts?

Yes, as you can see, the longer the subscription, the more the discount. We offer 5% for 3 months, 10% for 6 months, and 20% for 12 months. You can also expect to buy cheaper today, since we do expect prices to rise further into launching.

<br/>

### Is there a referral program?

No, not yet, but we'll be happy to look into it when people raise interest to such a program via feedback.

<br/>

### Why shouldn't I just do it myself?

We offer a full-managed-service which takes a lot of the server, library, security and operational headache away from you. If you feel you prefer the personal learning experience, we can only encourage you to do so. It is a great adventure to learn more, so please check the footnotes in case you look for ways to dive in.

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

In v2 we changed the network architecture compared to v1 where all traffic was directed via the VPN except Tor and ssh. This approach resulted in a lot of exceptions for different users. For example, if you were running ThunderHub on your node with v1, you were not able to access it via the external clearnet.

In v2 we are now isolating only lightning traffic via the VPN, all traffic not routed via your local proxy or not destined for your local network will be directed through the tunnel. The benefit is, apps like ThunderHub which run locally on your node are not tunneled and are accessible from the external clearnet. Nothing changes for your setup except for the lightning process. You will have no problems accessing your node from the external clearnet via ssh.

In case you want to access the gRPC or REST interface form the external clearnet, it will not be possible. In this case services like ZeroTier or Tailscale are recommended, which let you access your node as if it would be in your local network. Normally accessing your nodes gRPC or REST API from the external clearnet shouldn't be a general use case, it's recommended to access the API via the local network or on the same computer resulting in better efficiency.

<br/>

### Do you offer full-service VPNs too?

In short: No. Currently we are specializing VPN usage for the sole purpose of lightning node running. If you are looking for a privacy-preserving, lightning-payment enabled VPN provider, we recommend to take a look at [LNVPN.net](https://lnvpn.net).

<br />

### I have some ideas to make this better. Where can I provide feedback or offer help?

Great! Please do not hesitate to reach out via [Telegram](https://t.me/+py_KS9wv6hdjMWMy), [Nostr](https://snort.social/p/npub1n9z4y3xjramqes8fp9rl96x5e4nl0hff57ynw7vqnjpq370tq78sljsp8y), [X](https://x.com/tunnelsats), email (info @ tunnelsats.com) or log an issue here on github with your detailed ideas or feature requests. We always look forward to partner with great thinkers and doers.

<br/>

### Who built this?

From Node Runnners for Node Runners 🧡

<br />

[^1]: See hybrid options for [home-IP](https://github.com/blckbx/lnd-hybrid-mode) and [VPS](https://github.com/TrezorHannes/Dual-LND-Wireguard-VPS) for self-setup.
