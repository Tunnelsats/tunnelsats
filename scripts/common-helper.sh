#!/bin/bash

# Validate IPv4 address
function valid_ipv4() {
  local ip=$1
  local stat=1

  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    OIFS=$IFS
    IFS='.'
    ip=($ip)
    IFS=$OIFS
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 &&
      ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
    stat=$?
  fi
  return $stat
}

# Check for WireGuard config
function check_wireguard_config() {
  local directory=$(dirname -- "$(readlink -fn -- "$0")")
  echo "Looking for WireGuard config file..."
  if [ ! -f "$directory"/tunnelsatsv2.conf ] || [ $(grep -c "Endpoint" "$directory"/tunnelsatsv2.conf) -eq 0 ]; then
    echo "> ERR: tunnelsatsv2.conf not found or missing Endpoint."
    echo "> Please place it in this script's location and check original tunnelsatsv2.conf for \"Endpoint\" entry"
    exit 1
  else
    echo "> tunnelsatsv2.conf found, proceeding."
  fi
}

# Check for systemd service
function check_systemd_service() {
  local lnImplementation=$1
  if [ $isDocker -eq 0 ]; then
    echo "Looking for systemd service..."
    if [ "$lnImplementation" == "lnd" ] && [ ! -f /etc/systemd/system/lnd.service ]; then
      echo "> /etc/systemd/system/lnd.service not found. Setup aborted."
      exit 1
    fi
    if [ "$lnImplementation" == "cln" ] && [ ! -f /etc/systemd/system/lightningd.service ]; then
      echo "> /etc/systemd/system/lightningd.service not found. Setup aborted."
      exit 1
    fi
    if [ "$lnImplementation" == "lit" ] && [ ! -f /etc/systemd/system/lit.service ]; then
      echo "> /etc/systemd/system/lit.service not found. Setup aborted."
      exit 1
    fi
  fi
}

# Install necessary packages
function install_packages() {
  echo "Checking and installing requirements..."
  echo "Updating the package repositories..."
  apt-get update >/dev/null
  echo

  # Check and install nftables
  echo "Checking nftables installation..."
  checknft=$(nft -v 2>/dev/null | grep -c "nftables")
  if [ $checknft -eq 0 ]; then
    echo "Installing nftables..."
    if apt-get install -y nftables >/dev/null; then
      echo "> nftables installed"
    else
      echo "> failed to install nftables"
      exit 1
    fi
  else
    echo "> nftables found"
  fi
  echo
}

# Configure network and apply rules
function configure_network() {
  local lnImplementation=$1
  # Add network configuration logic here
  echo "Configuring network for $lnImplementation..."
}

# Display final instructions
function display_final_instructions() {
  local lnImplementation=$1
  echo "Please save this info in a file or write them down for later use."
  echo "A more detailed guide is available at: https://guide.tunnelsats.com"
  echo "Afterwards please restart $lnImplementation for changes to take effect."
  echo "VPN setup completed!"
}