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

# Function to check if Docker is running and relevant containers exist
check_docker_setup() {
  if systemctl is-active --quiet docker; then
    if docker ps --filter name=cln -q | grep -q . || docker ps --filter name=lnd -q | grep -q .; then
      echo "docker" # Docker is running with cln or lnd container
      return 0
    fi
  fi
  echo "manual" # Docker not running or no cln/lnd container found
  return 1
}

# Function to perform outbound connectivity check
perform_outbound_check() {
  local setup_type=$1
  local ip_address=""

  echo "Performing outbound check..." >&2 # Redirect to stderr
  if [[ "$setup_type" == "docker" ]]; then
    # Check if docker-tunnelsats network exists
    if ! docker network inspect docker-tunnelsats > /dev/null 2>&1; then
        echo "Warning: Docker network 'docker-tunnelsats' not found. Cannot perform Docker outbound check." >&2 # Redirect to stderr
        ip_address="Error: Docker network missing"
    else
        # Use timeout to prevent hanging indefinitely
        ip_address=$(timeout 10s docker run --rm --net=docker-tunnelsats curlimages/curl -s https://api.ipify.org)
        if [ $? -ne 0 ]; then
             echo "Warning: Docker outbound check failed or timed out." >&2 # Redirect to stderr
             ip_address="Error: Docker check failed"
        fi
    fi
  else
    # Manual setup check
    if command -v cgexec &> /dev/null; then
      # Use timeout to prevent hanging indefinitely
      ip_address=$(timeout 10s cgexec -g net_cls:splitted_processes curl --silent https://api.ipify.org)
       if [ $? -ne 0 ]; then
             echo "Warning: cgexec outbound check failed or timed out." >&2 # Redirect to stderr
             ip_address="Error: cgexec check failed"
        fi
    else
      echo "Warning: 'cgexec' command not found. Falling back to standard curl. Outbound check might use the wrong interface." >&2 # Redirect to stderr
      # Use timeout to prevent hanging indefinitely
      ip_address=$(timeout 10s curl --silent https://api.ipify.org)
       if [ $? -ne 0 ]; then
             echo "Warning: Standard curl outbound check failed or timed out." >&2 # Redirect to stderr
             ip_address="Error: curl check failed"
        fi
    fi
  fi
  # Basic validation if it looks like an IP
  if [[ "$ip_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Outbound check completed." >&2 # Redirect to stderr
      echo "$ip_address" # Print final IP to stdout
  else
      echo "Outbound check could not retrieve a valid IP." >&2 # Redirect to stderr
      echo "$ip_address" # Print error message to stdout
  fi
}

# Function to perform inbound connectivity check
perform_inbound_check() {
  local target_endpoint=$1
  local target_port=$2
  local result_ip=""
  local status="failed" # Assume failed initially

  echo "Performing inbound check for $target_endpoint:$target_port..." >&2 # Redirect to stderr
  # Use timeout for nc command
  nc_output=$(timeout 10s nc -zv "$target_endpoint" "$target_port" 2>&1)
  nc_exit_code=$?

  if [ $nc_exit_code -eq 0 ]; then
    # Success, try to parse IP
    result_ip=$(echo "$nc_output" | grep -oP '\(\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?=\))')
    if [[ -n "$result_ip" ]]; then
        echo "Inbound check successful. Server IP: $result_ip" >&2 # Redirect to stderr
        status="success"
    else
        # Succeeded but couldn't parse IP (unlikely with -zv)
        echo "Warning: Inbound check succeeded but could not parse server IP from output." >&2 # Redirect to stderr
        echo "Output: $nc_output" >&2 # Redirect to stderr
        result_ip="Unknown (Success)" # Mark as success but unknown IP
        status="success_no_ip"
    fi
  else
    # Failed
    echo "Inbound check failed." >&2 # Redirect to stderr
    echo "Output: $nc_output" >&2 # Redirect to stderr
    result_ip="Error: Failed ($nc_exit_code)"
  fi

  # Return status and IP on a single line to stdout, space-separated
  echo "$status $result_ip"
}

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

# Determine setup type
setup_method=$(check_docker_setup)
echo "Detected setup: $setup_method"

# Perform checks only if endpoint and VPNPort were successfully parsed
VPNIPoutbound="N/A"
VPNIPinbound="N/A"
inbound_status="N/A"
connectivity_ok=false
outbound_ok=false
inbound_ok=false

if [[ "$endpoint" != "N/A" && "$VPNPort" != "N/A" ]]; then
    VPNIPoutbound=$(perform_outbound_check "$setup_method")
    read -r inbound_status VPNIPinbound <<< "$(perform_inbound_check "$endpoint" "$VPNPort")"

    # Validate IPs and statuses
    if [[ "$VPNIPoutbound" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        outbound_ok=true
    fi
    if [[ "$inbound_status" == "success" || "$inbound_status" == "success_no_ip" ]]; then
        inbound_ok=true
    fi

    # Check overall connectivity
    if $outbound_ok && $inbound_ok && [[ "$VPNIPoutbound" == "$VPNIPinbound" ]]; then
        connectivity_ok=true
    elif $outbound_ok && $inbound_ok && [[ "$inbound_status" == "success_no_ip" ]]; then
        # Handle case where inbound succeeded but IP couldn't be parsed - assume OK if outbound IP looks valid
         echo "Warning: Inbound IP could not be parsed from nc output, but check succeeded. Assuming OK based on outbound check."
         connectivity_ok=true # Consider it OK for the summary message
    fi
else
    echo "Skipping connectivity checks because Endpoint or VPNPort could not be determined."
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
echo -e "\e[1;32m--- Connectivity Check ---\e[0m"
echo -e "Outbound IP via Tunnel: \e[1;34m$VPNIPoutbound\e[0m"
echo -e "Inbound Check Status: \e[1;34m$inbound_status\e[0m"
echo -e "Inbound Check Server IP: \e[1;34m$VPNIPinbound\e[0m"
echo ""

if $connectivity_ok; then
  echo -e "\e[1;32m✅ Both inbound and outbound connections via the tunnel seem to be working correctly!\e[0m"
elif $outbound_ok && ! $inbound_ok; then
  echo -e "\e[1;31m⚠️ Outbound connection seems OK, but the inbound check failed.\e[0m"
  echo -e "\e[1;31m   Please check firewall settings and ensure port $VPNPort is reachable on $endpoint.\e[0m"
  echo -e "\e[1;31m   See: https://guide.tunnelsats.com/ and https://guide.tunnelsats.com/FAQ.html\e[0m"
elif ! $outbound_ok && $inbound_ok; then
   echo -e "\e[1;31m⚠️ Inbound connection seems OK, but the outbound check failed or reported a different IP.\e[0m"
   echo -e "\e[1;31m   Ensure services are configured to use the tunnel (e.g., Docker network, cgexec).\e[0m"
   echo -e "\e[1;31m   See: https://guide.tunnelsats.com/ and https://guide.tunnelsats.com/FAQ.html\e[0m"
elif $outbound_ok && $inbound_ok && [[ "$VPNIPoutbound" != "$VPNIPinbound" ]]; then
    echo -e "\e[1;31m⚠️ Both checks reported an IP, but they don't match ($VPNIPoutbound vs $VPNIPinbound).\e[0m"
    echo -e "\e[1;31m   This might indicate a configuration issue or network problem.\e[0m"
    echo -e "\e[1;31m   See: https://guide.tunnelsats.com/ and https://guide.tunnelsats.com/FAQ.html\e[0m"
else # Both failed or couldn't run
  echo -e "\e[1;31m❌ Both inbound and outbound checks failed or could not be completed.\e[0m"
  echo -e "\e[1;31m   Please review the warnings above and check your configuration.\e[0m"
  echo -e "\e[1;31m   See: https://guide.tunnelsats.com/ and https://guide.tunnelsats.com/FAQ.html\e[0m"
fi
echo ""
echo "To validate your subscription details, copy your Wireguard Tunnel Public Key and visit 'https://tunnelsats.com/ > Renew'."
echo "Use Telegram Reminder Bot to add a secure and anon reminder when your subscription runs out: https://t.me/TunnelSatsReminderBot."
echo ""
echo "Thank you for using our Service"