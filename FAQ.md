# FAQ

## Table of Contents
- [Why should I use this service?](#why-should-i-use-this-service)
- [Why choose Tunnel⚡Sats over other VPN providers?](#why-choose-tunnelsats-over-other-vpn-providers)
- [Is your service reliable?](#is-your-service-reliable)
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
- [Where do I find my `lnd.conf` file?](#where-do-i-find-my-lndconf-file)
- [How to transfer `tunnelsats.conf` to my node?](#how-to-transfer-tunnelsatsconf-to-my-node)
- [How does it actually look like, how am I connected?](#how-does-it-actually-look-like-how-am-i-connected)
- [How can I verify that my connection is routed over VPN?](#how-can-i-verify-that-my-connection-is-routed-over-vpn)
- [Tuning Tor](#tuning-tor)
- [I have some ideas to make this better. Where can I provide feedback or offer help?](#i-have-some-ideas-to-make-this-better-where-can-i-provide-feedback-or-offer-help)

<br/>

## Frequently asked Questions

### Why should I use this service?
Providing Lightning ⚡ Services is about privacy, reliability, connectivity, speed and liquidity. Relying your node connectivity to a single service **Tor** is a risk, as anyone running a lightning node can testify. With Hybrid[^1] connectivity, you offer your payment and routing services to be [faster](https://blog.lnrouter.app/lightning-payment-speed-2022), more reliable, and yet, there is a privacy concern when you do it with your home-IP: you both expose your _rough_ location of your node, potentially your home and your node's system to attacks from the internet. With our solution **Tunnel⚡Sats**, you get the best of both worlds. Your node and home IP stays hidden, behind Tor and our VPS public IP address, which will be your node's face to the public internet. You may see higher reliability causing not only higher uptime, fewer peer nodes offline, but also greater routing numbers. This isn't a promise, but an eventually expected outcome. 

You also provide better user experience for customers actually using lightning as a payment system, which you could argue is the largest benefit.

<br/>

### Why choose Tunnel⚡Sats over other VPN providers?
Running a lightning nodes behind a VPN requires a range of features public VPN providers usually do not offer. **Tunnel⚡Sats** is specially designed for the lightning node use case in mind. So we pack up everything that's needed:
- static VPN IP: no more disconnects due to changing VPN IPs and no hassle setting up Dynamic DNS
- static forwarded Ports: assign VPN's port to your node config and you are good to go
- split-tunneling: we exclude Tor traffic automatically from routing through the VPN network. Contrary to "Tor over VPN", this enables redundancy of connectivity for your node meaning: If Tor goes down, VPN still plays and vice versa. 

<br/>

### Is your service reliable?
We use premium VPS Services with tight SLAs and proven, recorded high uptime. We also setup servers across different service providers to allow for switches in case something out of our control happens. We also setup tight monitoring systems for our VMs, with alert mechanisms and coverage by 3 people in operations. That said, we're early in our offering and happily provide regular uptime metrics when we enter beta phase, to provide more objective reliability data here.

<br/>

### Do you store my data? If so, which one and how do you use it?
We don't log IPs in our Webserver access data. We will soon offer an .onion website to allow for even greater anonymity. We don't store packets or logfiles from or to your node once the tunnel is established. We also store the payment hash as accounting confirmation in LNBits. We do have your node's IP address in memory to keep the tunnel connection alive, which will be discarded once you stop using our service. Hence it's extremely important to save your Wireguard configuration files, because there is no way for us to re-retrieve that information.

<br/>

### What options do I have if I'm not happy?
This depends on the service level you encountered. Happiness is quite subjective. When our service wasn't broken from a technology point of view, which means that the tunnel is working, and your node is operating in hybrid mode, we would expect you to honor your payment commitment until your subscription ends. However, we are approachable, and can discuss whatever is bugging you, and see how we can find a solution bareably for all of us.

<br/>

### How can I extend my subscription?
Let's say you bought the 1 month for testing the services, and all is going great. Now your subscription is coming to an end, and you like to extend it to add another 3 months. Since we don't offer a login-service, you'd need until shortly before your previous subscription ends, and
- buy a new subscription
- download or transfer via email the new configuration file from the website 
- copy and replace old configuration file with the new one in `/etc/wireguard`
- restart wireguard: `sudo systemctl restart wg-quick@tunnelsats`

<br/>

### Are you offering any discounts?
Yes, as you can see, the longer the subscription, the more the discount. We offer 5% for 3 months, 10% for 6 months, and 20% for 12 months. You can also expect to buy cheaper today, since we do expect prices to rise further into launching (moneyprintergobrrrrr).

<br/>

### Is there a referral program?
No, not yet, but we'll be happy to look into it when people raise interest to such a program via feedback.

<br/>

### My payment did confirm on my wallet, but I didn't get my configuration files. What can I do?
Please approach us on Telegram, via Email, Twitter or open an issue here. We'll ask you for confirming the timestamp of your payment, so we can check our accounting, and provide a solution for you. Sorry for the inconvenience in advance.

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

### Where do I find my `lnd.conf` file?
Every node software (RaspiBlitz, RaspiBolt, Umbrel, Start9, myNode, etc.) has its own directory where it keeps data of the underlying lightning implementation. As far as we know, the current (06/2022) directories are:

```ini
RaspiBlitz: /mnt/hdd/lnd/lnd.conf
RaspiBolt: /data/lnd/lnd.conf
Umbrel: /home/umbrel/umbrel/lnd/lnd.conf
Umbrel 0.5+: /home/umbrel/umbrel/app-data/lightning/data/lnd/lnd.conf
Start9: /embassy-data/package-data/volumes/lnd/data/main/lnd.conf
myNode: /mnt/hdd/mynode/lnd/lnd.conf
```

<br/>

### How to transfer `tunnelsats.conf` to my node?
The easiest way to transfer a file to a remote node is to use the cli command `scp`. Assuming that you run an Umbrel node and have downloaded the wireguard config file (tunnelsats.conf) to your computer, the `scp` command would look like this: 
```sh
$ scp tunnelsats.conf umbrel@umbrel.local:/home/umbrel/

[ scp <local file> <user>@<ip/hostname>:<destination path> ]
```

<br/>

### How does it actually look like, how am I connected?
See the current network setup in a comparison between your Tor only setup vs the new setup as a flowchart
![Flowchart Diagram](/docs/assets/Tunnelsats-Tor-scenario.drawio.png)

<br/>

### How can I verify that my connection is routed over VPN?
On console, run the following wireguard command to see some connection statistics: `sudo wg show`

<br/>

### Tuning Tor
Although we can speed up clearnet to clearnet connections, we still have to use the Tor network to reach out to Tor-only nodes. There have been some experiments going on to stabilize Tor connectivity and minimize its issues. Some of them might be worth trying out. These options are added to the `torrc` file:
```ini
LongLivedPorts 21,22,706,1863,5050,5190,5222,5223,6523,6667,6697,8300,9735,9736,9911
CircuitBuildTimeout 3
KeepalivePeriod 60
NewCircuitPeriod 20
UseEntryGuards 1
NumEntryGuards 8
```

<br/>

### I have some ideas to make this better. Where can I provide feedback or offer help?
Great! Please do not hesitate to reach out via [Telegram](https://t.me/+NJylaUom-rxjYjU6), [Twitter](https://twitter.com/tunnelsats), eMail (info @ tunnelsats.com) or log an issue here on Github with your detailed ideas or feature requests. We always look forward to partner with great thinkers and doers.

<br/>
<br/>

[^1]: See hybrid options for [home-IP](https://github.com/blckbx/lnd-hybrid-mode) and [VPS](https://github.com/TrezorHannes/Dual-LND-Hybrid-VPS) for self-setup.
