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

# Function to check Wireguard status and config file
check_wireguard_status() {
  wg_output=$(sudo wg show)
  if ! echo "$wg_output" | grep -q "interface: tunnelsatsv2"; then
    config_file="/etc/wireguard/tunnelsatsv2.conf"
    if [ ! -f "$config_file" ]; then
      echo "The wireguard tunnel seems to be offline, and no tunnelsatsv2.conf could be found in the wireguard directory."
      echo "Please try a reinstall per https://guide.tunnelsats.com"
      echo "Alternatively, visit the Tunnel⚡️Sats Telegram Chat: https://t.me/tunnelsats"
      return 1
    else
      echo "The wireguard tunnel seems to be offline. Please try restarting your node."
      return 1
    fi
  fi
  return 0
}

# Call the function to check Wireguard status
check_wireguard_status
if [ $? -ne 0 ]; then
  exit 1
fi

interface="tunnelsatsv2"
latest_handshake=$(echo "$wg_output" | grep -A 12 "interface: $interface" | grep 'latest handshake' | awk -F': ' '{print $2}')
transfer=$(echo "$wg_output" | grep -A 12 "interface: $interface" | grep 'transfer' | awk -F': ' '{print $2}')
public_key=$(echo "$wg_output" | grep -A 5 "interface: $interface" | grep 'public key' | awk -F': ' '{print $2}')

# Parse endpoint and VPN port from config file
config_file="/etc/wireguard/tunnelsatsv2.conf"
endpoint=$(sudo grep '^Endpoint =' "$config_file" | awk '{print $3}' | cut -d ':' -f 1)
VPNPort=$(sudo grep '^#VPNPort =' "$config_file" | awk '{print $3}')

# Check if parsing was successful
if [ -z "$endpoint" ]; then
  echo "Warning: Could not parse Endpoint from $config_file"
  endpoint="N/A"
fi
if [ -z "$VPNPort" ]; then
  echo "Warning: Could not parse VPNPort from $config_file"
  VPNPort="N/A"
fi

# Construct external address placeholder
external_address="Pubkey@${endpoint}:${VPNPort}"

# Display summary
echo -e "\e[1;32m=================================\e[0m"
echo -e "\e[1;32mTunnel⚡️Sats Subscription Summary\e[0m"
echo -e "\e[1;32m=================================\e[0m"
echo -e "My Wireguard Tunnel Public Key: \e[1;34m$public_key\e[0m"
echo -e "My transfer since last tunnel restart: \e[1;34m$transfer\e[0m"
echo -e "Latest handshake with the Tunnel Server: \e[1;34m$latest_handshake\e[0m"
echo ""
echo -e "Your VPN Server: \e[1;34m$endpoint\e[0m"
echo -e "Your VPN Public Port: \e[1;34m$VPNPort\e[0m"
echo -e "Your external Address: \e[1;34m$external_address\e[0m"
echo ""
echo "To validate your subscription details, copy your Wireguard Tunnel Public Key and visit 'https://tunnelsats.com/ > Renew'."
echo "Use Telegram Reminder Bot to add a secure and anon reminder when your subscription runs out: https://t.me/TunnelSatsReminderBot."
echo ""
echo "Thank you for using our Service"