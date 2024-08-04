#!/bin/bash

# Check if script is run with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash tunnelsats-sub-details.sh"
  exit 1
fi

# Help text
if [[ "$1" == "-h" ]]; then
  echo "Usage: sudo bash tunnelsats-sub-details.sh"
  echo "This script provides details about your Tunnel⚡️Sats subscription."
  echo "Beware of scammers, don't ever share your private key."
  exit 0
fi

# Parse Wireguard pubkey from config file
config_file="/etc/wireguard/tunnelsatsv2.conf"
if [ ! -f "$config_file" ]; then
  echo "Config file not found: $config_file. Confirm with sudo ls -la /etc/wireguard/"
  exit 1
fi

myPubKey=$(sudo grep '#myPubKey' "$config_file" | awk -F' = ' '{print $2}')
if [ -z "$myPubKey" ]; then
  echo "Public key not found in config file. Confirm with sudo etc /etc/wireguard/tunnelsatsv2.conf"
  exit 1
fi

# Parse Wireguard status
wg_output=$(sudo wg show)
if [ -z "$wg_output" ]; then
  echo "The tunnel seems to be offline. Try a node restart."
  echo "Please check our FAQ at https://guide.tunnelsats.com/FAQ.html#how-do-i-verify-the-tunnel-is-working"
  echo "Alternatively, visit the Tunnel⚡️Sats Telegram Chat for help: https://t.me/tunnelsats"
  exit 1
fi

interface="tunnelsatsv2"
latest_handshake=$(echo "$wg_output" | grep -A 12 "interface: $interface" | grep 'latest handshake' | awk -F': ' '{print $2}')
transfer=$(echo "$wg_output" | grep -A 12 "interface: $interface" | grep 'transfer' | awk -F': ' '{print $2}')
public_key=$(echo "$wg_output" | grep -A 5 "interface: $interface" | grep 'public key' | awk -F': ' '{print $2}')

# Display summary
echo -e "\e[1;32m=================================\e[0m"
echo -e "\e[1;32mTunnel⚡️Sats Subscription Summary\e[0m"
echo -e "\e[1;32m=================================\e[0m"
echo -e "My Wireguard Tunnel Public Key: \e[1;34m$myPubKey\e[0m"
echo -e "My transfer since last tunnel restart: \e[1;34m$transfer\e[0m"
echo -e "Latest handshake with the Tunnel Server: \e[1;34m$latest_handshake\e[0m"
echo ""
echo "To validate your subscription details, copy your Wireguard Tunnel Public Key and visit 'https://tunnelsats.com/ > Renew'."
echo "Use Telegram Reminder Bot to add a secure and anon reminder when your subscription runs out: https://t.me/TunnelSatsReminderBot."
echo ""
echo "Thank you for using our Service"